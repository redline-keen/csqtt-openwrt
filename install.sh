#!/bin/sh
# CSQTT — установка клиента на OpenWrt (procd + UCI + busybox ash)
# Авторежим ВК (auto_js), пул хешей, суточная ротация (окно 09:30–15:10).
#
# Использование:
#   sh csqtt-openwrt-install.sh 'csqtt://connect?...' [опции]
#
# Опции:
#   --repo OWNER/REPO    GitHub-репозиторий с бинарниками (по умолч. amurcanov/csqtt)
#   --tag TAG            тег релиза (по умолч. последний)
#   --mirror URL/        префикс-зеркало для GitHub (напр. https://gh-proxy.com/)
#   --local-bin ПУТЬ     не скачивать, взять локальный файл
#   --bin-dir ПУТЬ       куда класть бинарник (по умолч. /usr/bin; для USB — /mnt/sda1/csqtt)
#   --vk-token ТОКЕН     VK access token (иначе спросит интерактивно)
#   --hashes N           хешей в пуле 1..6 (по умолч. спросит, стандарт 4)
#   --workers N          воркеры 9..162 (урезается до хеши×27, кратно 9)
#   --uci-net            создать network-интерфейс + firewall-зону для csqtt0
#   --no-start           установить, но не запускать
#   --no-rotate          не ставить cron-ротацию
#   --uninstall          снести всё (init, cron, uci, файлы)
#
# СООТНОШЕНИЕ: 1 хеш = 27 воркеров (3 группы × 9). 4 хеша → максимум 108.
# РОТАЦИЯ: 1 хеш в сутки, случайный момент окна 09:30–15:10, случайный порядок.
#          Клиент перезапускается, простой ~10–15 с.

set -u

CSQTT_REPO="amurcanov/csqtt"
CSQTT_TAG=""
CSQTT_MIRROR=""
CSQTT_LOCAL_BIN=""
CSQTT_BIN_DIR="/usr/bin"
CSQTT_VK_TOKEN=""
CSQTT_HASHES=""
CSQTT_WORKERS=""
CSQTT_START=1
CSQTT_ROTATE=1
CSQTT_UCINET=0
CSQTT_UNINSTALL=0
CSQTT_LINK=""
WORKERS_PER_HASH=27
WORKERS_STEP=9
MAX_HASHES=6

CSQTT_DIR="/etc/csqtt"
INIT_SCRIPT="/etc/init.d/csqtt"
TUN_NAME="csqtt0"

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)       CSQTT_REPO="$2"; shift 2 ;;
        --tag)        CSQTT_TAG="$2"; shift 2 ;;
        --mirror)     CSQTT_MIRROR="$2"; shift 2 ;;
        --local-bin)  CSQTT_LOCAL_BIN="$2"; shift 2 ;;
        --bin-dir)    CSQTT_BIN_DIR="$2"; shift 2 ;;
        --vk-token)   CSQTT_VK_TOKEN="$2"; shift 2 ;;
        --hashes)     CSQTT_HASHES="$2"; shift 2 ;;
        --workers)    CSQTT_WORKERS="$2"; shift 2 ;;
        --uci-net)    CSQTT_UCINET=1; shift ;;
        --no-start)   CSQTT_START=0; shift ;;
        --no-rotate)  CSQTT_ROTATE=0; shift ;;
        --uninstall)  CSQTT_UNINSTALL=1; shift ;;
        -h|--help)    sed -n '2,27p' "$0"; exit 0 ;;
        csqtt://*)    CSQTT_LINK="$1"; shift ;;
        *)            echo "Неизвестный аргумент: $1"; exit 1 ;;
    esac
done

log()  { printf '\033[1;32m[CSQTT]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[CSQTT]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[CSQTT ОШИБКА]\033[0m %s\n' "$*"; exit 1; }

[ -f /etc/openwrt_release ] || warn "Это не похоже на OpenWrt (/etc/openwrt_release нет) — продолжаю"
[ "$(id -u)" = "0" ] || die "нужен root"

# ── удаление ────────────────────────────────────────────────────────────────
if [ "$CSQTT_UNINSTALL" = "1" ]; then
    [ -x "$INIT_SCRIPT" ] && { "$INIT_SCRIPT" stop 2>/dev/null; "$INIT_SCRIPT" disable 2>/dev/null; }
    rm -f "$INIT_SCRIPT"
    sed -i '/csqtt-rotate-hashes/d' /etc/crontabs/root 2>/dev/null
    /etc/init.d/cron restart >/dev/null 2>&1
    if uci -q get network.csqtt >/dev/null 2>&1; then
        uci -q delete network.csqtt
        uci -q delete firewall.csqtt
        # удалить forwarding lan→csqtt
        i=0
        while uci -q get firewall.@forwarding[$i] >/dev/null 2>&1; do
            [ "$(uci -q get firewall.@forwarding[$i].dest)" = "csqtt" ] \
                && { uci -q delete firewall.@forwarding[$i]; continue; }
            i=$((i + 1))
        done
        uci commit network; uci commit firewall
        /etc/init.d/network reload >/dev/null 2>&1
        /etc/init.d/firewall reload >/dev/null 2>&1
    fi
    sed -i '\|/etc/csqtt|d' /etc/sysupgrade.conf 2>/dev/null
    rm -rf "$CSQTT_DIR"
    rm -f "$CSQTT_BIN_DIR/csqtt-client"
    log "CSQTT удалён"
    exit 0
fi

mkdir -p "$CSQTT_DIR" "$CSQTT_BIN_DIR" || die "не удалось создать каталоги"
BIN_PATH="$CSQTT_BIN_DIR/csqtt-client"

# ── 1. архитектура (uname -m на mips не различает endianness) ────────────────
ei_data() { # EI_DATA из ELF-заголовка файла: 01 = LE, 02 = BE
    dd if="$1" bs=1 skip=5 count=1 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n'
}
ARCH_KEY=""
HOST_ENDIAN=$(ei_data /bin/busybox)
case "$(uname -m)" in
    aarch64|arm64)  ARCH_KEY="aarch64" ;;
    armv7l|armv7)   ARCH_KEY="armv7" ;;
    x86_64|amd64)   ARCH_KEY="x86_64" ;;
    mips|mips64)
        case "$HOST_ENDIAN" in
            01) ARCH_KEY="mipsel" ;;
            02) die "MIPS big-endian (ath79/lantiq) — бинарников нет, нужна своя сборка" ;;
            *)  warn "endianness не определён, считаю mipsel"; ARCH_KEY="mipsel" ;;
        esac ;;
    *) die "Архитектура $(uname -m) не поддерживается" ;;
esac
log "Архитектура: $ARCH_KEY ($(uname -m), EI_DATA=$HOST_ENDIAN)"

# ── 2. зависимости ──────────────────────────────────────────────────────────
PKG=""
command -v apk   >/dev/null 2>&1 && PKG="apk"
[ -z "$PKG" ] && command -v opkg >/dev/null 2>&1 && PKG="opkg"

pkg_install() { # pkg_install имя ...
    [ -n "$PKG" ] || { warn "нет opkg/apk — поставьте вручную: $*"; return 1; }
    case "$PKG" in
        apk)  apk add --quiet "$@" >/dev/null 2>&1 ;;
        opkg) opkg install "$@" >/dev/null 2>&1 ;;
    esac
}
pkg_update_once() {
    [ -n "${PKG_UPDATED:-}" ] && return 0
    case "$PKG" in
        apk)  apk update >/dev/null 2>&1 ;;
        opkg) opkg update >/dev/null 2>&1 ;;
    esac
    PKG_UPDATED=1
}

need_pkgs=""
command -v curl >/dev/null 2>&1 || need_pkgs="$need_pkgs curl ca-bundle"
[ -c /dev/net/tun ] || need_pkgs="$need_pkgs kmod-tun"
if [ -n "$need_pkgs" ]; then
    log "Ставлю пакеты:$need_pkgs"
    pkg_update_once
    # shellcheck disable=SC2086
    pkg_install $need_pkgs || warn "установка не удалась — продолжаю, проверьте вручную"
fi
[ -c /dev/net/tun ] || { modprobe tun 2>/dev/null; }
[ -c /dev/net/tun ] || warn "/dev/net/tun отсутствует — TUN-режим работать не будет (нужен kmod-tun)"

# ── 3. место на overlay ─────────────────────────────────────────────────────
free_kb=$(df -k "$CSQTT_BIN_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
case "$free_kb" in
    ''|*[!0-9]*) : ;;
    *) [ "$free_kb" -lt 12000 ] && warn "Свободно ${free_kb}K в $CSQTT_BIN_DIR — бинарник может не влезть. Используйте --bin-dir /mnt/sda1/csqtt" ;;
esac

# ── 4. получение бинарника ──────────────────────────────────────────────────
gh() { # gh URL → URL с учётом зеркала
    [ -n "$CSQTT_MIRROR" ] && printf '%s%s' "${CSQTT_MIRROR%/}/" "$1" || printf '%s' "$1"
}
fetch() { curl -fsSL "$(gh "$1")" -o "$2"; }

verify_bin() {
    [ -s "$1" ] || die "файл $1 пуст"
    magic=$(dd if="$1" bs=1 count=6 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
    case "$ARCH_KEY" in
        aarch64|x86_64) want="7f454c460201" ;;
        armv7|mipsel)   want="7f454c460101" ;;
    esac
    [ "$magic" = "$want" ] \
        || die "$1 — не ELF для $ARCH_KEY (получено ${magic:-пусто}, ожидалось $want)"
    chmod +x "$1"
}

if [ -n "$CSQTT_LOCAL_BIN" ]; then
    [ -f "$CSQTT_LOCAL_BIN" ] || die "файл не найден: $CSQTT_LOCAL_BIN"
    cp "$CSQTT_LOCAL_BIN" "$BIN_PATH" || die "копирование не удалось"
    log "Бинарник взят из $CSQTT_LOCAL_BIN"
else
    if [ -z "$CSQTT_TAG" ]; then
        page=$(curl -fsSL -w '%{url_effective}' -o /dev/null \
               "$(gh "https://github.com/$CSQTT_REPO/releases/latest")" 2>/dev/null) \
            || die "не узнать последний релиз $CSQTT_REPO (нет сети / GitHub заблокирован? попробуйте --mirror)"
        CSQTT_TAG=$(printf '%s' "$page" | sed 's|.*/tag/||')
        [ -n "$CSQTT_TAG" ] || die "в $CSQTT_REPO нет релизов"
    fi
    log "Релиз: $CSQTT_REPO $CSQTT_TAG"
    assets=$(curl -fsSL "$(gh "https://github.com/$CSQTT_REPO/releases/expanded_assets/$CSQTT_TAG")" 2>/dev/null) \
        || die "не получить список файлов релиза"
    asset_url=$(printf '%s' "$assets" \
        | grep -o 'href="[^"]*releases/download/[^"]*"' \
        | sed 's/^href="//; s/"$//' \
        | grep "csqtt-client-$ARCH_KEY" | tail -n 1)
    case "$asset_url" in /*) asset_url="https://github.com$asset_url" ;; esac
    [ -n "$asset_url" ] || die "в релизе $CSQTT_TAG нет csqtt-client-$ARCH_KEY-* (соберите сами и --local-bin)"
    log "Скачиваю: $asset_url"
    fetch "$asset_url" "$BIN_PATH" || die "скачивание не удалось"
fi
verify_bin "$BIN_PATH"

smoke=$("$BIN_PATH" 2>&1 | head -n 1)
case "$smoke" in
    *peer*) log "Бинарник отвечает: $smoke" ;;
    *) warn "Неожиданный ответ бинарника: ${smoke:-пусто} (продолжаю)" ;;
esac

# ── 5. ссылка подключения (POSIX urldecode, без bash-подстрок) ──────────────
urldecode() {
    printf '%s' "$1" | awk '
        BEGIN { for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i }
        {
            s = $0; out = ""
            while (length(s) > 0) {
                c = substr(s, 1, 1)
                if (c == "%" && length(s) >= 3) {
                    out = out sprintf("%c", strtonum("0x" substr(s, 2, 2)))
                    s = substr(s, 4)
                } else if (c == "+") { out = out " "; s = substr(s, 2) }
                else { out = out c; s = substr(s, 2) }
            }
            printf "%s", out
        }'
}

if [ -z "$CSQTT_LINK" ]; then
    printf 'Вставьте ссылку подключения (csqtt://connect?...): '
    read -r CSQTT_LINK
fi
[ -n "$CSQTT_LINK" ] || die "ссылка не указана"

query=$(printf '%s' "$CSQTT_LINK" | sed 's|^csqtt://[^?]*?||')
PEER_HOST=""; PEER_PORT=""; PASSWORD=""
oldIFS="$IFS"; IFS='&'
for kv in $query; do
    k=${kv%%=*}; v=${kv#*=}
    case "$k" in
        host)     PEER_HOST=$(urldecode "$v") ;;
        peer)     PEER_PORT=$(urldecode "$v") ;;
        password) PASSWORD=$(urldecode "$v") ;;
    esac
done
IFS="$oldIFS"
[ -n "$PEER_HOST" ] && [ -n "$PEER_PORT" ] && [ -n "$PASSWORD" ] \
    || die "в ссылке нет host / peer / password"
PEER="$PEER_HOST:$PEER_PORT"
log "Пир: $PEER"

# ── 6. VK-токен ─────────────────────────────────────────────────────────────
VK_TOKEN_FILE="$CSQTT_DIR/vk_token"
if [ -z "$CSQTT_VK_TOKEN" ] && [ -f "$VK_TOKEN_FILE" ]; then
    CSQTT_VK_TOKEN=$(cat "$VK_TOKEN_FILE")
    warn "Использован сохранённый VK-токен из $VK_TOKEN_FILE"
fi
if [ -z "$CSQTT_VK_TOKEN" ]; then
    printf 'Вставьте ВЕЧНЫЙ VK access token: '
    read -r CSQTT_VK_TOKEN
fi
[ -n "$CSQTT_VK_TOKEN" ] || die "нужен VK access token"
case "$CSQTT_VK_TOKEN" in
    *'"'*|*"'"*) die "токен содержит недопустимые символы" ;;
esac
umask 077
printf '%s' "$CSQTT_VK_TOKEN" > "$VK_TOKEN_FILE"
chmod 600 "$VK_TOKEN_FILE"
log "VK-токен сохранён (600): $VK_TOKEN_FILE"

# ── 7. хеши и воркеры ───────────────────────────────────────────────────────
if [ -z "$CSQTT_HASHES" ]; then
    printf 'Хешей в пуле [1..6] (Enter = 4): '
    read -r CSQTT_HASHES
fi
case "$CSQTT_HASHES" in
    "") CSQTT_HASHES=4 ;;
    *[!0-9]*) die "хеши — целое 1..6: '$CSQTT_HASHES'" ;;
    *) [ "$CSQTT_HASHES" -ge 1 ] && [ "$CSQTT_HASHES" -le $MAX_HASHES ] \
        || die "хеши должны быть 1..$MAX_HASHES" ;;
esac
hash_cap=$((CSQTT_HASHES * WORKERS_PER_HASH))
if [ -z "$CSQTT_WORKERS" ]; then
    printf 'Воркеров [9..%d] (Enter = максимум): ' "$hash_cap"
    read -r CSQTT_WORKERS
fi
case "$CSQTT_WORKERS" in
    "") CSQTT_WORKERS=$hash_cap ;;
    *[!0-9]*) die "воркеры — целое: '$CSQTT_WORKERS'" ;;
esac
[ "$CSQTT_WORKERS" -ge 9 ] || die "минимум 9 воркеров"
if [ "$CSQTT_WORKERS" -gt "$hash_cap" ]; then
    warn "Воркеров $CSQTT_WORKERS → $hash_cap (правило 27 на хеш)"
    CSQTT_WORKERS=$hash_cap
fi
CSQTT_WORKERS=$((CSQTT_WORKERS / WORKERS_STEP * WORKERS_STEP))
[ "$CSQTT_WORKERS" -ge 9 ] || CSQTT_WORKERS=$WORKERS_STEP
log "Хешей: $CSQTT_HASHES · воркеров: $CSQTT_WORKERS"

# ── 8. device-id (OpenWrt: board_name + MAC eth0 → стабильно) ───────────────
DEVICE_ID=""
[ -f "$CSQTT_DIR/device_id" ] && DEVICE_ID=$(cat "$CSQTT_DIR/device_id" 2>/dev/null)
if [ -z "$DEVICE_ID" ]; then
    board=$(cat /tmp/sysinfo/board_name 2>/dev/null || hostname)
    mac=$(cat /sys/class/net/eth0/address 2>/dev/null | tr -d ':')
    [ -n "$mac" ] || mac=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
    DEVICE_ID="$(printf '%s' "$board" | tr -c 'a-zA-Z0-9_-' '-')-$mac"
    printf '%s' "$DEVICE_ID" > "$CSQTT_DIR/device_id"
fi
log "Device ID: $DEVICE_ID"

# ── 9. конфиг ───────────────────────────────────────────────────────────────
cat > "$CSQTT_DIR/csqtt.conf" <<EOF
# CSQTT client config — правьте и: service csqtt restart
BIN="$BIN_PATH"
PEER="$PEER"
PASSWORD="$PASSWORD"
HASHES="$CSQTT_HASHES"
WORKERS="$CSQTT_WORKERS"
VK_MODE="auto_js"
DEVICE_ID="$DEVICE_ID"
LISTEN="127.0.0.1:9000"
FINGERPRINT="firefox"
CLIENT_IDS="8202606,6287487"
OBFS="video"
TURN_TRANSPORT="udp"
CAPTCHA_MODE="auto"
# Пусто = UDP-режим 127.0.0.1:9000 без интерфейса.
TUN_IFACE="$TUN_NAME"
TUN_MTU="1300"
EOF
chmod 600 "$CSQTT_DIR/csqtt.conf"
log "Конфиг: $CSQTT_DIR/csqtt.conf"

# ── 10. обёртка запуска ─────────────────────────────────────────────────────
cat > "$CSQTT_DIR/csqtt-run.sh" <<'EOF'
#!/bin/sh
# Читает csqtt.conf, подаёт VK_JS_BOOTSTRAP в stdin через fifo, exec клиента.
DIR=$(dirname "$0")
. "$DIR/csqtt.conf"
umask 077

set -- "$BIN" \
    --peer "$PEER" \
    --password "$PASSWORD" \
    --device-id "$DEVICE_ID" \
    -n "$WORKERS" \
    --listen "$LISTEN" \
    --fingerprint "$FINGERPRINT" \
    --client-ids "$CLIENT_IDS" \
    --obfs "$OBFS" \
    --turn-transport "$TURN_TRANSPORT" \
    --captcha-mode "$CAPTCHA_MODE" \
    --vk-pool "$DIR/vk_pool" \
    --vk-calls "$HASHES"

[ -n "$TUN_IFACE" ] && set -- "$@" --tun "$TUN_IFACE" --tun-mtu "$TUN_MTU"

TOKEN=$(cat "$DIR/vk_token" 2>/dev/null) || { echo "нет vk_token"; exit 1; }
BOOTSTRAP=$(printf '{"token":"%s"}' "$TOKEN" | base64 | tr -d '\n')
set -- "$@" --vk-hash-mode auto_js --vk-auth-mode auto_js

FIFO="$DIR/bootstrap.fifo"
rm -f "$FIFO"
mkfifo "$FIFO" || { echo "не удалось создать fifo"; exit 1; }
printf 'VK_JS_BOOTSTRAP:%s\n' "$BOOTSTRAP" > "$FIFO" &
exec "$@" < "$FIFO"
EOF
chmod +x "$CSQTT_DIR/csqtt-run.sh"

# ── 11. procd init ──────────────────────────────────────────────────────────
cat > "$INIT_SCRIPT" <<EOF
#!/bin/sh /etc/rc.common
# CSQTT client (Авторежим ВК, пул хешей)
USE_PROCD=1
START=99
STOP=10

start_service() {
    procd_open_instance csqtt
    procd_set_param command /bin/sh "$CSQTT_DIR/csqtt-run.sh"
    procd_set_param respawn 60 5 0
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param file "$CSQTT_DIR/csqtt.conf"
    procd_set_param pidfile /var/run/csqtt.pid
    procd_close_instance
}

stop_service() {
    # SIGINT = graceful: клиент корректно завершит звонок VK
    pid=\$(pgrep -f csqtt-client 2>/dev/null | head -n 1)
    [ -n "\$pid" ] && kill -INT "\$pid" 2>/dev/null
    sleep 2
}

reload_service() {
    stop
    sleep 1
    start
}

service_triggers() {
    procd_add_reload_trigger "csqtt"
}
EOF
chmod +x "$INIT_SCRIPT"
"$INIT_SCRIPT" enable 2>/dev/null && log "Автозапуск включён (procd)"
log "Init: $INIT_SCRIPT"

# ── 12. персистентность через sysupgrade ────────────────────────────────────
touch /etc/sysupgrade.conf
grep -q '^/etc/csqtt' /etc/sysupgrade.conf 2>/dev/null || {
    echo "/etc/csqtt/" >> /etc/sysupgrade.conf
    log "Конфиг добавлен в /etc/sysupgrade.conf (переживёт обновление прошивки)"
}
case "$CSQTT_BIN_DIR" in
    /usr/bin) warn "Бинарник в /usr/bin — sysupgrade его сотрёт, переустановите после обновления" ;;
esac

# ── 13. UCI: интерфейс + firewall-зона ──────────────────────────────────────
if [ "$CSQTT_UCINET" = "1" ]; then
    uci -q set network.csqtt=interface
    uci -q set network.csqtt.proto='none'
    uci -q set network.csqtt.device="$TUN_NAME"
    uci -q set network.csqtt.auto='0'
    uci -q commit network

    uci -q set firewall.csqtt=zone
    uci -q set firewall.csqtt.name='csqtt'
    uci -q set firewall.csqtt.input='REJECT'
    uci -q set firewall.csqtt.output='ACCEPT'
    uci -q set firewall.csqtt.forward='REJECT'
    uci -q set firewall.csqtt.masq='1'
    uci -q set firewall.csqtt.mtu_fix='1'
    uci -q set firewall.csqtt.network='csqtt'
    # forwarding lan → csqtt (без дублей)
    have_fw=0; i=0
    while uci -q get firewall.@forwarding[$i] >/dev/null 2>&1; do
        [ "$(uci -q get firewall.@forwarding[$i].dest)" = "csqtt" ] && have_fw=1
        i=$((i + 1))
    done
    if [ "$have_fw" = "0" ]; then
        fw=$(uci add firewall forwarding)
        uci -q set firewall."$fw".src='lan'
        uci -q set firewall."$fw".dest='csqtt'
    fi
    uci -q commit firewall
    /etc/init.d/network reload >/dev/null 2>&1
    /etc/init.d/firewall reload >/dev/null 2>&1
    log "UCI: интерфейс csqtt ($TUN_NAME) + firewall-зона с masq, forwarding lan→csqtt"
    warn "Маршрутизация трафика в туннель — отдельно (ip rule / fwmark или route в зоне csqtt)"
fi

# ── 14. скрипт ротации хешей ────────────────────────────────────────────────
cat > "$CSQTT_DIR/csqtt-rotate-hashes.sh" <<'ROTATE'
#!/bin/sh
# Ротация хешей CSQTT: 1 хеш/сутки, окно 09:30–15:10, случайный порядок.
# Аргумент «force» — ротировать немедленно.
DIR=$(dirname "$0")
CONF="$DIR/csqtt.conf"
POOL="$DIR/vk_pool"
STATE="$DIR/rotate.state"
INIT="/etc/init.d/csqtt"
[ -f "$CONF" ] || exit 0
. "$CONF"
umask 077

FORCE=0
[ "${1:-}" = "force" ] && FORCE=1

LOG="$DIR/rotate.log"
log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
    logger -t csqtt-rotate "$*" 2>/dev/null
}
# лог не должен пухнуть на overlay
[ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 65536 ] && { tail -n 200 "$LOG" > "$LOG.tmp"; mv "$LOG.tmp" "$LOG"; }

window_start=$((9 * 60 + 30))
window_end=$((15 * 60 + 10))

LOCK="$DIR/rotate.lock"
STAMP="$DIR/rotate.lock.stamp"
if ! mkdir "$LOCK" 2>/dev/null; then
    lock_age=$(( $(date +%s) - $(cat "$STAMP" 2>/dev/null || echo 0) ))
    if [ "$lock_age" -gt 1800 ]; then
        rm -rf "$LOCK" "$STAMP"
        mkdir "$LOCK" 2>/dev/null || exit 0
    else
        exit 0
    fi
fi
date +%s > "$STAMP"
trap 'rm -f "$STAMP" 2>/dev/null; rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

state_get() { grep "^$1=" "$STATE" 2>/dev/null | tail -n 1 | cut -d= -f2; }
state_write() {
    printf 'day=%s\nminute=%s\nperm=%s\ndone=%s\n' "$1" "$2" "$3" "$4" > "$STATE.tmp" \
        && mv "$STATE.tmp" "$STATE"
}

gen_perm() { # Фишер–Йетс 0..N-1
    awk -v N="$1" 'BEGIN {
        srand()
        for (i = 0; i < N; i++) p[i] = i
        for (j = N - 1; j > 0; j--) { k = int(rand() * (j + 1)); t = p[j]; p[j] = p[k]; p[k] = t }
        out = p[0]
        for (i = 1; i < N; i++) out = out "," p[i]
        print out
    }'
}

today=$(date +%Y-%m-%d)
now_min=$(( $(date +%H) * 60 + $(date +%M) ))

day=$(state_get day)
minute=$(state_get minute)
perm=$(state_get perm)
done_flag=$(state_get done)
if [ "$day" != "$today" ] || [ -z "$minute" ]; then
    minute=$(awk -v lo=$window_start -v hi=$((window_end - 4)) \
        'BEGIN { srand(); print lo + int(rand() * (hi - lo + 1)) }')
    [ -n "$perm" ] || perm=$(gen_perm "${HASHES:-4}")
    state_write "$today" "$minute" "$perm" "0"
    log "план на $today: ротация в $(printf '%02d:%02d' $((minute / 60)) $((minute % 60))), порядок $perm"
    done_flag=0
fi

if [ "$FORCE" = "0" ]; then
    [ "$done_flag" = "1" ] && exit 0
    [ "$now_min" -lt "$minute" ] && exit 0
    [ "$now_min" -gt $window_end ] && exit 0
fi

pool_lines=0
[ -f "$POOL" ] && pool_lines=$(wc -l < "$POOL")
if [ "$pool_lines" -eq 0 ]; then
    log "пул пуст — нечего ротировать"
    exit 0
fi
[ -n "$perm" ] || perm=$(gen_perm "$pool_lines")
target=$(printf '%s' "$perm" | cut -d, -f1)
rest=$(printf '%s' "$perm" | cut -d, -f2-)
[ "$rest" = "$perm" ] && rest=""
[ "$target" -ge "$pool_lines" ] && target=$((target % pool_lines))

TOKEN=$(cat "$DIR/vk_token" 2>/dev/null) || { log "нет vk_token"; exit 1; }
BOOTSTRAP=$(printf '{"token":"%s"}' "$TOKEN" | base64 | tr -d '\n')
new_hash=""; new_id=""
out=$(printf 'VK_JS_BOOTSTRAP:%s\n' "$BOOTSTRAP" \
    | "$BIN" --vk-regen-call \
        --fingerprint "$FINGERPRINT" --device-id "$DEVICE_ID" 2>>"$LOG")
for line in $out; do
    case "$line" in
        CALL_HASH:*) new_hash=${line#CALL_HASH:} ;;
        CALL_ID:*)   new_id=${line#CALL_ID:} ;;
    esac
done
if [ -z "$new_hash" ] || [ -z "$new_id" ]; then
    log "regen не дал хеш: $out"
    exit 1
fi
log "новый звонок: хеш $new_hash id $new_id → строка №$((target + 1))"

old_id=""
[ "$pool_lines" -gt "$target" ] && old_id=$(sed -n "$((target + 1))p" "$POOL" | cut -d: -f2)
awk -v line=$((target + 1)) -v new="$new_hash:$new_id" '
    NR == line { print new; replaced = 1; next }
    { print }
    END { if (!replaced) print new }
' "$POOL" > "$POOL.tmp" && mv "$POOL.tmp" "$POOL"

if [ -x "$INIT" ]; then
    "$INIT" restart >>"$LOG" 2>&1
    log "клиент перезапущен"
else
    log "$INIT не найден — перезапустите вручную"
fi

if [ -n "$old_id" ]; then
    out=$(printf 'VK_JS_BOOTSTRAP:%s\n' "$BOOTSTRAP" \
        | "$BIN" --vk-drop-call "$old_id" \
            --fingerprint "$FINGERPRINT" --device-id "$DEVICE_ID" 2>>"$LOG")
    case "$out" in
        *CALL_DROPPED*) log "старый звонок $old_id завершён" ;;
        *) log "drop $old_id не удался (не критично): $out" ;;
    esac
fi

state_write "$today" "$minute" "$rest" "1"
log "ротация завершена (строка №$((target + 1)))"
ROTATE
chmod +x "$CSQTT_DIR/csqtt-rotate-hashes.sh"

# ── 15. cron ────────────────────────────────────────────────────────────────
if [ "$CSQTT_ROTATE" = "1" ]; then
    CRON_FILE="/etc/crontabs/root"
    CRON_LINE="*/5 * * * * $CSQTT_DIR/csqtt-rotate-hashes.sh"
    mkdir -p /etc/crontabs
    touch "$CRON_FILE"
    grep -q "csqtt-rotate-hashes" "$CRON_FILE" 2>/dev/null || echo "$CRON_LINE" >> "$CRON_FILE"
    /etc/init.d/cron enable >/dev/null 2>&1
    /etc/init.d/cron restart >/dev/null 2>&1
    log "Cron: $CRON_LINE"
fi

# ── 16. запуск ──────────────────────────────────────────────────────────────
if [ "$CSQTT_START" = "1" ]; then
    "$INIT_SCRIPT" restart
    sleep 5
    if logread -e csqtt 2>/dev/null | tail -n 20 | grep -qi 'пул\|pool'; then
        log "Пул хешей создан, воркеры поднимаются"
    else
        warn "Проверьте журнал: logread -e csqtt -f"
        logread -e csqtt 2>/dev/null | tail -n 10
    fi
fi

log "Готово."
log "Управление:  service csqtt start|stop|restart|status"
log "Журнал:      logread -e csqtt -f"
log "Ротация:     $CSQTT_DIR/csqtt-rotate-hashes.sh force   (вручную)"
log "Файлы:       $CSQTT_DIR (conf, vk_token, vk_pool, rotate.state)"
log "Снести:      sh $0 --uninstall"
exit 0
