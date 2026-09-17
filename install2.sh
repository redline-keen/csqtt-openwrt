#!/bin/sh
# -*- coding: utf-8 -*-
# CSQTT — установка клиентского бинарника с GitHub на роутер
# (Keenetic/Entware, OpenWrt 24/25) с Авторежимом ВК (auto_js), пулом хешей
# и суточной ротацией (1 хеш/сутки, окно 09:30–15:10, случайный порядок).
#
# ВЕРСИЯ v2 (2026-09-17), changelog:
#   - fix curl(23)/ETXTBSY: загрузка в .new, остановка службы, атомарный mv
#   - ретраи: 5 попыток на csqtt-ссылку и VK-токен, после 5 — сброс счётчика
#   - нормализация ввода (кавычки/пробелы, URL/JSON с access_token)
#   - валидация ссылки (host/peer/password, порт 1..65535) и токена (>=20 симв.)
#   v1: пул хешей, ротация, watchdog, mihomo-конфиг, деинсталлятор
#
# Использование:
#   sh csqtt-github-install_v2_retry5_20260917.sh 'csqtt://connect?...' [опции]
#
# Опции:
#   --repo OWNER/REPO     GitHub-репозиторий с бинарниками (по умолч. amurcanov/csqtt)
#   --tag TAG             тег релиза (по умолч. последний)
#   --local-bin ПУТЬ      не скачивать, использовать локальный файл
#   --vk-token ТОКЕН      VK access token (иначе спросит интерактивно)
#   --hashes N            хеши 1..6 (по умолч. спрашивает, стандарт 4)
#   --workers N           воркеры 9..162 (потолок хеши×27, кратно 9)
#   --no-start            установить, но не запускать
#   --no-rotate           не ставить cron-ротацию хешей
#   --no-watchdog         не ставить cron-watchdog
#   --mihomo-conf         скачать csqtt-config.yaml для mihomo
#   --mihomo-conf-url URL скачать конфиг mihomo со своего URL
#   --no-mihomo           не спрашивать про mihomo config
#
# Бинарник в релизе: csqtt-client-aarch64 (для MT7621 — csqtt-client-mipsel).
# Повторная установка поверх работающей службы поддерживается.

set -u

CSQTT_REPO="redline-keen/csqtt-openwrt"
CSQTT_TAG="0.1"
CSQTT_LOCAL_BIN=""
CSQTT_VK_TOKEN=""
CSQTT_HASHES=""
CSQTT_WORKERS=""
CSQTT_START=1
CSQTT_ROTATE=1
CSQTT_WATCHDOG=1
CSQTT_MIHOMO_CONF=""
CSQTT_MIHOMO_CONF_URL=""
CSQTT_LINK=""
WORKERS_PER_HASH=27
WORKERS_STEP=9
MAX_HASHES=6
MAX_TRY=5

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)       CSQTT_REPO="$2"; shift 2 ;;
        --tag)        CSQTT_TAG="$2"; shift 2 ;;
        --local-bin)  CSQTT_LOCAL_BIN="$2"; shift 2 ;;
        --vk-token)   CSQTT_VK_TOKEN="$2"; shift 2 ;;
        --hashes)     CSQTT_HASHES="$2"; shift 2 ;;
        --workers)    CSQTT_WORKERS="$2"; shift 2 ;;
        --mihomo-conf) CSQTT_MIHOMO_CONF="yes"; shift ;;
        --mihomo-conf-url) CSQTT_MIHOMO_CONF_URL="$2"; shift 2 ;;
        --no-mihomo)  CSQTT_MIHOMO_CONF="no"; shift ;;
        --no-start)   CSQTT_START=0; shift ;;
        --no-rotate)  CSQTT_ROTATE=0; shift ;;
        --no-watchdog) CSQTT_WATCHDOG=0; shift ;;
        -h|--help)    sed -n '2,44p' "$0"; exit 0 ;;
        csqtt://*)    CSQTT_LINK="$1"; shift ;;
        *)            echo "Неизвестный аргумент: $1"; exit 1 ;;
    esac
done

log()  { printf '\033[1;32m[CSQTT]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[CSQTT]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[CSQTT ОШИБКА]\033[0m %s\n' "$*"; exit 1; }

# ── 1. каталог установки (Entware → /opt, OpenWrt → /etc) ──────────
if [ -d /opt/entware ] || [ -d /opt/etc/init.d ]; then
    CSQTT_DIR="/opt/etc/csqtt"
    INIT_DIR="/opt/etc/init.d"
    INIT_STYLE="entware"
else
    CSQTT_DIR="/etc/csqtt"
    INIT_DIR="/etc/init.d"
    INIT_STYLE="openwrt"
fi
mkdir -p "$CSQTT_DIR" "$INIT_DIR" 2>/dev/null || die "нет прав на запись (запускайте под root)"
LOG_FILE="$CSQTT_DIR/csqtt.log"
PID_FILE="/var/run/csqtt.pid"
if [ "$INIT_STYLE" = "openwrt" ]; then
    INIT_SCRIPT="$INIT_DIR/csqtt"
    INIT_SCRIPT_NAME="service csqtt"
else
    INIT_SCRIPT="$INIT_DIR/S99csqtt"
    INIT_SCRIPT_NAME="$INIT_DIR/S99csqtt"
fi

# ── 2. архитектура ────────────────────────────────
ARCH_KEY=""
case "$(uname -m)" in
    aarch64|arm64) ARCH_KEY="aarch64" ;;
    mips)          ARCH_KEY="mipsel" ;;
    *) die "Архитектура $(uname -m) не поддерживается (собраны aarch64 и mipsel)" ;;
esac
log "Архитектура: $ARCH_KEY ($(uname -m)) · стиль инициализации: $INIT_STYLE"

# ── 3. получение бинарника (csqtt-client-<arch>; .new + атомарный mv) ───────
BIN_PATH="$CSQTT_DIR/csqtt-client"

fetch() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$1" -o "$2"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1"
    else
        die "Нужен curl или wget"
    fi
}

hexdump_bin() {
    if command -v hexdump >/dev/null 2>&1; then
        hexdump -n 1 -e '1/1 "%02x"'
    elif command -v od >/dev/null 2>&1 && od -An -tx1 -N1 </dev/null >/dev/null 2>&1; then
        od -An -tx1 -N1 | tr -d ' \n'
    else
        b=$(dd bs=1 count=1 2>/dev/null | tr -d '\n')
        case "$b" in
            $'\x7f') printf '7f' ;;
            $'\x45') printf '45' ;;
            $'\x4c') printf '4c' ;;
            $'\x46') printf '46' ;;
            $'\x02') printf '02' ;;
            $'\x01') printf '01' ;;
            *) printf '??' ;;
        esac
    fi
}

verify_bin() {
    [ -s "$1" ] || die "Файл $1 пуст/отсутствует"
    magic=""
    i=0
    while [ $i -lt 6 ]; do
        b=$(dd if="$1" bs=1 skip=$i count=1 2>/dev/null | hexdump_bin)
        magic="$magic$b"
        i=$((i + 1))
    done
    [ -n "$magic" ] || die "не удалось прочитать заголовок $1 (dd недоступен?)"
    case "$ARCH_KEY" in
        aarch64) want="7f454c460201" ;;
        mipsel)  want="7f454c460101" ;;
    esac
    [ "$magic" = "$want" ] \
        || die "$1 не является корректным ELF для $ARCH_KEY (получено: ${magic:-пусто}; ожидалось $want)"
    chmod +x "$1"
}

if [ -n "$CSQTT_LOCAL_BIN" ]; then
    [ -f "$CSQTT_LOCAL_BIN" ] || die "локальный файл не найден: $CSQTT_LOCAL_BIN"
    cp "$CSQTT_LOCAL_BIN" "$BIN_PATH.new" || die "не удалось скопировать бинарник"
    log "Бинарник скопирован из $CSQTT_LOCAL_BIN"
else
    [ -n "$CSQTT_REPO" ] || die "не задан --repo"
    if [ -z "$CSQTT_TAG" ]; then
        page=$(curl -fsSL -w '%{url_effective}' -o /dev/null \
               "https://github.com/$CSQTT_REPO/releases/latest" 2>/dev/null) \
            || die "не удалось узнать последний релиз $CSQTT_REPO (нет curl или нет сети?)"
        CSQTT_TAG=$(printf '%s' "$page" | sed 's|.*/tag/||')
        [ -n "$CSQTT_TAG" ] || die "в $CSQTT_REPO не найдено ни одного релиза"
    fi
    asset_name="csqtt-client-$ARCH_KEY"
    asset_url="https://github.com/$CSQTT_REPO/releases/download/$CSQTT_TAG/$asset_name"
    log "Релиз: $CSQTT_REPO $CSQTT_TAG"
    log "Скачиваю: $asset_url"
    if ! fetch "$asset_url" "$BIN_PATH.new"; then
        rm -f "$BIN_PATH.new"
        die "скачивание не удалось: в релизе $CSQTT_TAG нет файла $asset_name? (либо wget не умеет https: opkg install curl)"
    fi
fi

verify_bin "$BIN_PATH.new"

if [ -x "$INIT_SCRIPT" ] && pgrep csqtt-client >/dev/null 2>&1; then
    log "Останавливаю работающую службу перед заменой бинарника..."
    "$INIT_SCRIPT" stop >/dev/null 2>&1 || true
    sleep 1
    killall -9 csqtt-client 2>/dev/null || true
fi
mv "$BIN_PATH.new" "$BIN_PATH" || die "не удалось заменить бинарник"
log "Бинарник установлен: $BIN_PATH"

smoke=$("$BIN_PATH" 2>&1 | head -n 1)
case "$smoke" in
    *peer*)  log "Бинарник отвечает: $smoke" ;;
    *"Exec format error"*|*"not found"*|*"Syntax error"*|*"syntax error"*)
        warn "ELF-заголовок корректен, но запустить здесь не удалось: $smoke" ;;
    *)
        [ -n "$smoke" ] || smoke="(пустой вывод)"
        warn "Неожиданный ответ бинарника: $smoke (продолжаем)" ;;
esac

# ── 4. ссылка подключения (5 попыток, после 5 — сброс счётчика) ─────────
urldecode() {
    s="$1"; out=""; i=0; n=${#s}
    while [ "$i" -lt "$n" ]; do
        c=${s:$i:1}
        if [ "$c" = "%" ] && [ $((i + 2)) -lt "$n" ]; then
            out="$out$(printf '\\x'${s:$((i+1)):2})"
            i=$((i + 3))
        else
            out="$out$c"; i=$((i + 1))
        fi
    done
    printf '%s' "$out"
}

parse_link() { # на stdout: host, port, password (3 строки); ошибки — на stderr
    printf '%s' "$1" | grep -q '^csqtt://' \
        || { echo "ссылка должна начинаться с csqtt://" >&2; return 1; }
    query=$(printf '%s' "$1" | sed 's|^csqtt://[^?]*?||')
    [ -n "$query" ] || { echo "в ссылке нет параметров после ?" >&2; return 1; }
    ph=""; pp=""; pw=""
    oldIFS="$IFS"; IFS='&'
    for kv in $query; do
        k=${kv%%=*}; v=${kv#*=}
        case "$k" in
            host)     ph=$(urldecode "$v") ;;
            peer)     pp=$(urldecode "$v") ;;
            password) pw=$(urldecode "$v") ;;
        esac
    done
    IFS="$oldIFS"
    [ -n "$ph" ] || { echo "нет параметра host" >&2; return 1; }
    [ -n "$pp" ] || { echo "нет параметра peer (порт)" >&2; return 1; }
    [ -n "$pw" ] || { echo "нет параметра password" >&2; return 1; }
    case "$pp" in
        *[!0-9]*) echo "порт peer должен быть числом: '$pp'" >&2; return 1 ;;
    esac
    [ "$pp" -ge 1 ] && [ "$pp" -le 65535 ] \
        || { echo "порт peer вне диапазона 1..65535: $pp" >&2; return 1; }
    printf '%s\n%s\n' "$ph" "$pp" "$pw"
}

PEER_HOST=""; PEER_PORT=""; PASSWORD=""
try_n=1
while :; do
    if [ -n "$CSQTT_LINK" ]; then
        LINK_INPUT="$CSQTT_LINK"          # из аргумента CLI
        CSQTT_LINK=""                     # дальше — только интерактивный ввод
    else
        printf 'Вставьте ссылку подключения (csqtt://connect?host=...&peer=...&password=...), попытка %d/5: ' "$try_n"
        read -r LINK_INPUT || die "ввод прерван (EOF)"
    fi
    LINK_INPUT=$(printf '%s' "$LINK_INPUT" \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"$.*$"$/\1/; s/^\x27$.*$\x27$/\1/')
    if [ -z "$LINK_INPUT" ]; then
        warn "Пустой ввод."
    elif parsed=$(parse_link "$LINK_INPUT"); then
        PEER_HOST=$(printf '%s' "$parsed" | sed -n 1p)
        PEER_PORT=$(printf '%s' "$parsed" | sed -n 2p)
        PASSWORD=$(printf '%s' "$parsed" | sed -n 3p)
        break
    else
        warn "Некорректная ссылка: $parsed"
        warn "Ожидаемый вид: csqtt://connect?host=IP&peer=ПОРТ&password=ПАРОЛЬ"
    fi
    if [ "$try_n" -ge "$MAX_TRY" ]; then
        warn "5 неудачных попыток — счётчик сброшен, можно начать сначала (Ctrl+C — выход)."
        try_n=1
    else
        try_n=$((try_n + 1))
    fi
done
PEER="$PEER_HOST:$PEER_PORT"
log "Пир: $PEER"

# ── 5. VK-токен (5 попыток, после 5 — сброс счётчика) ───────────────────────
VK_TOKEN_FILE="$CSQTT_DIR/vk_token"
if [ -z "$CSQTT_VK_TOKEN" ] && [ -t 0 ] && [ -f "$VK_TOKEN_FILE" ]; then
    CSQTT_VK_TOKEN=$(cat "$VK_TOKEN_FILE")
    warn "Использован сохранённый VK-токен из $VK_TOKEN_FILE"
fi

validate_token() { # на stdout — нормализованный токен; ошибки — на stderr
    t=$(printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    case "$t" in
        *access_token=*) t=$(printf '%s' "$t" | sed 's/.*access_token=//; s/&.*//') ;;
    esac
    case "$t" in
        *'"access_token"'*)
            t=$(printf '%s' "$t" | sed 's/.*"access_token"[[:space:]]*:[[:space:]]*"//; s/".*//') ;;
    esac
    [ -n "$t" ] || { echo "пустой токен" >&2; return 1; }
    case "$t" in
        *" "*) echo "токен содержит пробел — скопируйте только значение access_token" >&2; return 1 ;;
    esac
    case "$t" in
        *[!A-Za-z0-9_.\-]*) echo "токен содержит недопустимые символы (нужны латиница/цифры/_-. )" >&2; return 1 ;;
    esac
    [ "${#t}" -ge 20 ] || { echo "токен слишком короткий (${#t} симв.) — нужен полный access_token из VK ID" >&2; return 1; }
    printf '%s' "$t"
}

try_n=1
while :; do
    if [ -n "$CSQTT_VK_TOKEN" ]; then
        TOKEN_INPUT="$CSQTT_VK_TOKEN"     # из аргумента CLI / сохранённого файла
        CSQTT_VK_TOKEN=""
    else
        printf 'Вставьте ВЕЧНЫЙ VK access token (или URL с access_token=...), попытка %d/5: ' "$try_n"
        read -r TOKEN_INPUT || die "ввод прерван (EOF)"
    fi
    if [ -z "$TOKEN_INPUT" ]; then
        warn "Пустой ввод."
    elif cleaned=$(validate_token "$TOKEN_INPUT"); then
        CSQTT_VK_TOKEN="$cleaned"
        break
    else
        warn "Некорректный токен: $cleaned"
        warn "Как взять: браузер → ссылка из INSTALL-*.md → вход VK → скопируйте access_token из адресной строки"
    fi
    if [ "$try_n" -ge "$MAX_TRY" ]; then
        warn "5 неудачных попыток — счётчик сброшен, можно начать сначала (Ctrl+C — выход)."
        try_n=1
    else
        try_n=$((try_n + 1))
    fi
done

umask 077
printf '%s' "$CSQTT_VK_TOKEN" > "$VK_TOKEN_FILE"
log "VK-токен сохранён в $VK_TOKEN_FILE (права 600; менять — там же)"

# ── 6. параметры пула: хеши и воркеры ──────────────────────────────
if [ -z "$CSQTT_HASHES" ]; then
    printf 'Хешей в пуле [1..6] (Enter = 4): '
    read -r CSQTT_HASHES
fi
case "$CSQTT_HASHES" in
    "") CSQTT_HASHES=4 ;;
    *[!0-9]*) die "число хешей должно быть целым 1..6: '$CSQTT_HASHES'" ;;
    *) [ "$CSQTT_HASHES" -ge 1 ] && [ "$CSQTT_HASHES" -le $MAX_HASHES ] \
        || die "число хешей должно быть 1..$MAX_HASHES: $CSQTT_HASHES" ;;
esac

hash_cap=$((CSQTT_HASHES * WORKERS_PER_HASH))
if [ -z "$CSQTT_WORKERS" ]; then
    printf 'Воркеров [9..162, максимум %d для %d хешей] (Enter = максимум): ' "$hash_cap" "$CSQTT_HASHES"
    read -r CSQTT_WORKERS
fi
case "$CSQTT_WORKERS" in
    "") CSQTT_WORKERS=$hash_cap ;;
    *[!0-9]*) die "число воркеров должно быть целым: '$CSQTT_WORKERS'" ;;
esac
[ "$CSQTT_WORKERS" -ge 9 ] || die "минимум 9 воркеров"
if [ "$CSQTT_WORKERS" -gt "$hash_cap" ]; then
    warn "Воркеров $CSQTT_WORKERS → $hash_cap: правило 27 на хеш ($CSQTT_HASHES хешей)"
    CSQTT_WORKERS=$hash_cap
fi
CSQTT_WORKERS=$((CSQTT_WORKERS / WORKERS_STEP * WORKERS_STEP))
[ "$CSQTT_WORKERS" -ge 9 ] || CSQTT_WORKERS=$WORKERS_STEP
log "Хешей: $CSQTT_HASHES · воркеров: $CSQTT_WORKERS ($((CSQTT_WORKERS / WORKERS_PER_HASH)) на хеш, $((CSQTT_WORKERS / WORKERS_STEP)) групп)"

# ── 6а. конфиг mihomo ─────────────────────────────────
if [ "$INIT_STYLE" = "openwrt" ]; then
    MIHOMO_DIR="/etc/mihomo"
else
    MIHOMO_DIR="/opt/etc/mihomo"
fi
MIHOMO_CONF_FILE="$MIHOMO_DIR/config.yaml"
[ -n "$CSQTT_MIHOMO_CONF_URL" ] && CSQTT_MIHOMO_CONF="yes"
CSQTT_CONFIG_URL="https://raw.githubusercontent.com/$CSQTT_REPO/main/csqtt-config.yaml"

if [ -z "$CSQTT_MIHOMO_CONF" ]; then
    while true; do
        printf 'Скачать config.yaml для mihomo (%s)? 1) да  2) пропустить: ' "$MIHOMO_DIR"
        read -r MIHOMO_CHOICE || MIHOMO_CHOICE=""
        case "$MIHOMO_CHOICE" in
            1)  CSQTT_MIHOMO_CONF="yes"; break ;;
            2|"") CSQTT_MIHOMO_CONF="no"; break ;;
            *)  warn "Введите 1 или 2." ;;
        esac
    done
fi

if [ "$CSQTT_MIHOMO_CONF" = "yes" ]; then
    [ -n "$CSQTT_MIHOMO_CONF_URL" ] || CSQTT_MIHOMO_CONF_URL="$CSQTT_CONFIG_URL"
    log "mihomo config.yaml ← $CSQTT_MIHOMO_CONF_URL"
    mkdir -p "$MIHOMO_DIR"
    if [ -f "$MIHOMO_CONF_FILE" ] && [ ! -f "$MIHOMO_CONF_FILE.csqtt-bak" ]; then
        cp "$MIHOMO_CONF_FILE" "$MIHOMO_CONF_FILE.csqtt-bak"
        log "Прежний конфиг mihomo сохранён: $MIHOMO_CONF_FILE.csqtt-bak"
    fi
    if fetch "$CSQTT_MIHOMO_CONF_URL" "$MIHOMO_CONF_FILE.new"; then
        mv "$MIHOMO_CONF_FILE.new" "$MIHOMO_CONF_FILE"
        log "mihomo config.yaml обновлён: $MIHOMO_CONF_FILE (перезапустите mihomo/clash)"
    else
        rm -f "$MIHOMO_CONF_FILE.new"
        warn "Не удалось скачать config.yaml — прежний конфиг mihomo не тронут"
    fi
fi

# ── 7. device-id ────────────────────────────────
DEVICE_ID=""
if [ -f "$CSQTT_DIR/device_id" ]; then
    DEVICE_ID=$(cat "$CSQTT_DIR/device_id" 2>/dev/null)
fi
if [ -z "$DEVICE_ID" ]; then
    DEVICE_ID=$(cat /sys/firmware/devicetree/base/serial-number 2>/dev/null | tr -d '\0')
    [ -n "$DEVICE_ID" ] || DEVICE_ID=$(cat /etc/serial 2>/dev/null)
    [ -n "$DEVICE_ID" ] || DEVICE_ID=$(hostname)-$(head -c 4 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' || hostname)
    printf '%s' "$DEVICE_ID" > "$CSQTT_DIR/device_id"
fi
log "Device ID: $DEVICE_ID"

# ── 8. конфиг ─────────────────────────────────
cat > "$CSQTT_DIR/csqtt.conf" <<EOF
# CSQTT client config — правьте и перезапускайте: $INIT_SCRIPT_NAME restart
PEER="$PEER"
PASSWORD="$PASSWORD"
HASHES="$CSQTT_HASHES"      # хешей в пуле, 1..6
WORKERS="$CSQTT_WORKERS"     # воркеров, 9..162 (потолок: HASHES x 27)
TUN_IFACE="csqtt0"           # TUN-интерфейс; пусто = UDP-режим (порт LISTEN)
TUN_MTU="1300"
# Продвинутые — дефолты в csqtt-run.sh; раскомментируйте для override:
#LISTEN="127.0.0.1:9000"
#FINGERPRINT="firefox"
#CLIENT_IDS="8202606,6287487"
#OBFS="video"
#TURN_TRANSPORT="udp"
#CAPTCHA_MODE="auto"
EOF
chmod 600 "$CSQTT_DIR/csqtt.conf"
log "Конфиг: $CSQTT_DIR/csqtt.conf (HASHES=$CSQTT_HASHES · WORKERS=$CSQTT_WORKERS)"

# ── 9. обёртка запуска ────────────────────────────────
cat > "$CSQTT_DIR/csqtt-run.sh" <<'EOF'
#!/bin/sh
DIR=$(dirname "$0")
. "$DIR/csqtt.conf"
umask 077

: "${LISTEN:=127.0.0.1:9000}"
: "${FINGERPRINT:=firefox}"
: "${CLIENT_IDS:=8202606,6287487}"
: "${OBFS:=video}"
: "${TURN_TRANSPORT:=udp}"
: "${CAPTCHA_MODE:=auto}"

if [ -z "${DEVICE_ID:-}" ]; then
    DEVICE_ID=$(cat "$DIR/device_id" 2>/dev/null)
fi
[ -n "$DEVICE_ID" ] || { echo "нет device_id ($DIR/device_id)"; exit 1; }

set -- "$DIR/csqtt-client" \
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

if [ -n "$TUN_IFACE" ]; then
    set -- "$@" --tun "$TUN_IFACE" --tun-mtu "$TUN_MTU"
fi

TOKEN=$(cat "$DIR/vk_token" 2>/dev/null) || { echo "нет vk_token"; exit 1; }
BOOTSTRAP=$(printf '{"token":"%s"}' "$TOKEN" | base64 | tr -d '\n')
set -- "$@" --vk-hash-mode auto_js --vk-auth-mode auto_js
FIFO="$DIR/bootstrap.fifo"
[ -p "$FIFO" ] || mkfifo "$FIFO" || { echo "не удалось создать fifo"; exit 1; }
printf 'VK_JS_BOOTSTRAP:%s\n' "$BOOTSTRAP" > "$FIFO" &
exec "$@" < "$FIFO"
EOF
chmod +x "$CSQTT_DIR/csqtt-run.sh"

# ── 10. скрипт ротации хешей ────────────────────────────────
cat > "$CSQTT_DIR/csqtt-rotate-hashes.sh" <<'ROTATE'
#!/bin/sh
# Ротация хешей CSQTT: 1 хеш в сутки, окно 09:30–15:10, случайный порядок.
# Аргумент «force» — ротировать немедленно (ручной режим).
DIR=$(dirname "$0")
CONF="$DIR/csqtt.conf"
POOL="$DIR/vk_pool"
STATE="$DIR/rotate.state"
[ -f "$CONF" ] || exit 0
. "$CONF"
umask 077

FORCE=0
[ "${1:-}" = "force" ] && FORCE=1

LOG="$DIR/rotate.log"
log() { printf '[%s] [CSQTT-ROTATE] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

: "${FINGERPRINT:=firefox}"
if [ -z "${DEVICE_ID:-}" ]; then
    DEVICE_ID=$(cat "$DIR/device_id" 2>/dev/null)
fi
[ -n "$DEVICE_ID" ] || DEVICE_ID="unknown"

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

gen_perm() {
    awk -v N="$1" 'BEGIN {
        srand()
        for (i = 0; i < N; i++) p[i] = i
        for (j = N - 1; j > 0; j--) {
            k = int(rand() * (j + 1))
            t = p[j]; p[j] = p[k]; p[k] = t
        }
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
    log "пул пуст — ротация нечего менять (клиент создаст пул при старте)"
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
    | "$DIR/csqtt-client" --vk-regen-call \
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
log "новый звонок: хеш $new_hash id $new_id → строка пула №$((target + 1))"

old_id=""
if [ "$pool_lines" -gt "$target" ]; then
    old_id=$(sed -n "$((target + 1))p" "$POOL" | cut -d: -f2)
fi
awk -v line=$((target + 1)) -v new="$new_hash:$new_id" '
    NR == line { print new; replaced = 1; next }
    { print }
    END { if (!replaced) print new }
' "$POOL" > "$POOL.tmp" && mv "$POOL.tmp" "$POOL"

if [ -x "__INIT_CMD__" ]; then
    touch "$DIR/restarting"
    "__INIT_CMD__" restart >>"$LOG" 2>&1
    rm -f "$DIR/restarting"
    log "клиент перезапущен на обновлённом пуле"
else
    log "init-скрипт __INIT_CMD__ не найден — перезапустите клиент вручную"
fi

if [ -n "$old_id" ]; then
    out=$(printf 'VK_JS_BOOTSTRAP:%s\n' "$BOOTSTRAP" \
        | "$DIR/csqtt-client" --vk-drop-call "$old_id" \
            --fingerprint "$FINGERPRINT" --device-id "$DEVICE_ID" 2>>"$LOG")
    case "$out" in
        *CALL_DROPPED*) log "старый звонок $old_id завершён" ;;
        *) log "drop $old_id не удался (не критично): $out" ;;
    esac
fi

state_write "$today" "$minute" "$rest" "1"
log "ротация завершена (строка №$((target + 1)) обновлена)"
ROTATE
chmod +x "$CSQTT_DIR/csqtt-rotate-hashes.sh"

sed -i "s|__INIT_CMD__|$INIT_SCRIPT|g" "$CSQTT_DIR/csqtt-rotate-hashes.sh" 2>/dev/null \
    || die "не удалось подставить init-путь в скрипт ротации (sed -i недоступен?)"

# ── 11. cron ──────────────────────────────────
CRON_FILE=""
if [ "$INIT_STYLE" = "entware" ]; then
    CRON_FILE="/opt/var/spool/cron/crontabs/root"
else
    CRON_FILE="/etc/crontabs/root"
fi
mkdir -p "$(dirname "$CRON_FILE")"
touch "$CRON_FILE"

if [ "$CSQTT_ROTATE" = "1" ]; then
    CRON_LINE="*/5 * * $CSQTT_DIR/csqtt-rotate-hashes.sh"
    grep -q "csqtt-rotate-hashes" "$CRON_FILE" 2>/dev/null \
        || echo "$CRON_LINE" >> "$CRON_FILE"
    log "Cron: $CRON_LINE"
fi

# ── 11а. watchdog ───────────────────────────────────
if [ "$CSQTT_WATCHDOG" = "1" ]; then
cat > "$CSQTT_DIR/csqtt-watchdog.sh" <<'WATCHDOG'
#!/bin/sh
# CSQTT watchdog: процесс жив, TUN UP, пинг через TUN. Сбой → restart.
DIR=$(dirname "$0")
CONF="$DIR/csqtt.conf"
[ -f "$CONF" ] || exit 0
. "$CONF"
umask 077

LOG="$DIR/watchdog.log"
MAX_SIZE_KB=1024
TUN_IFACE="${TUN_IFACE:-}"
INIT_CMD="__INIT_CMD__"
PING_TARGET="77.88.8.8"

stamp() { date '+%Y-%m-%d %H:%M:%S'; }

for log in "$LOG" __LOG_FILE__; do
    [ -f "$log" ] || continue
    FILE_SIZE=$(du -k "$log" 2>/dev/null | awk '{print $1}')
    if [ -n "$FILE_SIZE" ] && [ "$FILE_SIZE" -gt "$MAX_SIZE_KB" ]; then
        tail -n 500 "$log" > "${log}.cut" 2>/dev/null \
            && cat "${log}.cut" > "$log" \
            && rm -f "${log}.cut" \
            && echo "$(stamp) [WATCHDOG] Лог $log обрезан до 500 строк." >> "$LOG"
    fi
done

[ -f "$DIR/stopped" ] && exit 0
[ -f "$DIR/restarting" ] && exit 0

IS_RUNNING=0
if pgrep csqtt-client >/dev/null 2>&1 || pidof csqtt-client >/dev/null 2>&1; then
    IS_RUNNING=1
fi

IS_UP=1
if [ -n "$TUN_IFACE" ]; then
    IS_UP=0
    if ip link show "$TUN_IFACE" 2>/dev/null | grep -q "UP"; then
        IS_UP=1
    fi
fi

if [ "$IS_RUNNING" -eq 0 ] || [ "$IS_UP" -eq 0 ]; then
    echo "$(stamp) [WATCHDOG] Сбой службы (процесс=$IS_RUNNING, $TUN_IFACE=$IS_UP). Перезапуск..." >> "$LOG"
    rm -f "$DIR/stopped"
    "$INIT_CMD" restart >> "$LOG" 2>&1
    exit 0
fi

if [ -n "$TUN_IFACE" ] && command -v ping >/dev/null 2>&1; then
    if ! ping -c 2 -W 3 -I "$TUN_IFACE" "$PING_TARGET" >/dev/null 2>&1; then
        echo "$(stamp) [WATCHDOG] Пинг через $TUN_IFACE не прошел. Перезапуск..." >> "$LOG"
        rm -f "$DIR/stopped"
        "$INIT_CMD" restart >> "$LOG" 2>&1
    fi
fi
WATCHDOG
chmod +x "$CSQTT_DIR/csqtt-watchdog.sh"

sed -i -e "s|__INIT_CMD__|$INIT_SCRIPT|g" -e "s|__LOG_FILE__|$LOG_FILE|g" \
    "$CSQTT_DIR/csqtt-watchdog.sh" 2>/dev/null \
    || die "не удалось подставить пути в watchdog (sed -i недоступен?)"

CRON_LINE="*/2 * * * * $CSQTT_DIR/csqtt-watchdog.sh"
grep -q "csqtt-watchdog" "$CRON_FILE" 2>/dev/null \
    || echo "$CRON_LINE" >> "$CRON_FILE"
log "Cron: $CRON_LINE"
fi

if [ "$INIT_STYLE" = "entware" ]; then
    for c in /opt/etc/init.d/S10cron /opt/etc/init.d/crond; do
        [ -x "$c" ] && "$c" restart >/dev/null 2>&1 && break
    done
else
    [ -x /etc/init.d/cron ] && /etc/init.d/cron restart >/dev/null 2>&1
fi

# ── 12. init-скрипт ────────────────────────────────
if [ "$INIT_STYLE" = "openwrt" ]; then
cat > "$INIT_DIR/csqtt" <<EOF
#!/bin/sh /etc/rc.common
# CSQTT client (Авторежим ВК, пул хешей)
USE_PROCD=1
START=99
STOP=10

start_service() {
    rm -f "$CSQTT_DIR/stopped" "$CSQTT_DIR/restarting"
    procd_open_instance
    procd_set_param command /bin/sh "$CSQTT_DIR/csqtt-run.sh"
    procd_set_param respawn "\${threshold:-60}" "\${timeout:-5}" "\${retry:-0}"
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param file "$CSQTT_DIR/csqtt.conf"
    procd_close_instance
}

stop_service() {
    touch "$CSQTT_DIR/stopped"
}
EOF
else
cat > "$INIT_DIR/S99csqtt" <<EOF
#!/bin/sh
# CSQTT client (Авторежим ВК, пул хешей)
DIR="$CSQTT_DIR"
case "\$1" in
    start)
        printf 'Starting CSQTT: '
        rm -f "\$DIR/stopped"
        if [ -f "$PID_FILE" ] && kill -0 "\$(cat "$PID_FILE")" 2>/dev/null; then
            echo "уже запущен"; exit 0
        fi
        nohup "\$DIR/csqtt-run.sh" >>"$LOG_FILE" 2>&1 &
        echo \$! > "$PID_FILE"
        echo "OK (PID \$(cat "$PID_FILE"))"
        ;;
    stop)
        printf 'Stopping CSQTT: '
        touch "\$DIR/stopped"
        if [ -f "$PID_FILE" ]; then
            PID=\$(cat "$PID_FILE")
            kill -INT "\$PID" 2>/dev/null
            n=0
            while kill -0 "\$PID" 2>/dev/null && [ \$n -lt 10 ]; do
                sleep 1; n=\$((n+1))
            done
            kill -9 "\$PID" 2>/dev/null
            rm -f "$PID_FILE"
        fi
        echo "OK"
        ;;
    restart)
        touch "\$DIR/restarting"
        \$0 stop; sleep 1; \$0 start
        rm -f "\$DIR/restarting"
        ;;
    status)
        if [ -f "$PID_FILE" ] && kill -0 "\$(cat "$PID_FILE")" 2>/dev/null; then
            echo "CSQTT работает (PID \$(cat "$PID_FILE"))"
        else
            echo "CSQTT остановлен"
        fi
        ;;
    log)
        tail -n 100 "$LOG_FILE"
        ;;
    *)
        echo "Usage: \$0 start|stop|restart|status|log"
        ;;
esac
EOF
fi
chmod +x "$INIT_SCRIPT"
log "Init-скрипт: $INIT_SCRIPT"

# ── 12а. деинсталлятор ────────────────────────────────
if [ "$INIT_STYLE" = "openwrt" ]; then
    UNINST_BIN="/usr/bin/csqtt-uninstall"
else
    UNINST_BIN="/opt/bin/csqtt-uninstall"
fi
mkdir -p "$(dirname "$UNINST_BIN")"
cat > "$CSQTT_DIR/uninstall.sh" <<'UNINSTALL'
#!/bin/sh
DIR=$(dirname "$0")
echo "=== Удаление csqtt-client ==="

CRON_FILE="/opt/var/spool/cron/crontabs/root"
[ -f "$CRON_FILE" ] || CRON_FILE="/etc/crontabs/root"
if [ -f "$CRON_FILE" ]; then
    sed -i '/csqtt-rotate-hashes\.sh/d; /csqtt-watchdog\.sh/d' "$CRON_FILE" 2>/dev/null || true
    for c in /opt/etc/init.d/S10cron /opt/etc/init.d/crond /etc/init.d/cron; do
        [ -x "$c" ] && "$c" restart >/dev/null 2>&1 && break
    done
fi

for init in /opt/etc/init.d/S99csqtt /etc/init.d/csqtt; do
    if [ -x "$init" ]; then
        "$init" stop >/dev/null 2>&1 || true
        rm -f "$init"
    fi
done

killall -9 csqtt-client 2>/dev/null || true
rm -f /var/run/csqtt.pid /opt/var/run/csqtt-client.pid

rm -f /opt/bin/csqtt-uninstall /usr/bin/csqtt-uninstall
rm -rf "$DIR"

echo "Удаление завершено. (VK-звонки пула закроет сам VK по таймауту.)"
UNINSTALL
chmod +x "$CSQTT_DIR/uninstall.sh"

printf '#!/bin/sh\nexec "%s/uninstall.sh"\n' "$CSQTT_DIR" > "$UNINST_BIN"
chmod +x "$UNINST_BIN"
log "Деинсталлятор: $UNINST_BIN (или $CSQTT_DIR/uninstall.sh)"

# ── 13. запуск ────────────────────────────────────
if [ "$CSQTT_START" = "1" ]; then
    "$INIT_SCRIPT" restart
    if [ "$INIT_STYLE" = "openwrt" ]; then
        log "Журнал: logread | grep csqtt"
    else
        sleep 4
        if grep -q "Пул" "$LOG_FILE" 2>/dev/null; then
            log "Пул хешей создан, воркеры поднимаются"
        else
            warn "Проверьте журнал: $INIT_SCRIPT log"
            tail -n 10 "$LOG_FILE" 2>/dev/null
        fi
    fi
fi

log "Готово. Управление: $INIT_SCRIPT start|stop|restart|status|log"
[ "$INIT_STYLE" = "openwrt" ] && log "Управление (OpenWrt): service csqtt start|stop|restart"
log "VK-токен: $VK_TOKEN_FILE · конфиг: $CSQTT_DIR/csqtt.conf · пул: $CSQTT_DIR/vk_pool"
log "Ротация: $CSQTT_DIR/csqtt-rotate-hashes.sh (cron */5; 1 хеш/сутки в 09:30–15:10)"
[ "$CSQTT_WATCHDOG" = "1" ] && log "Watchdog: $CSQTT_DIR/csqtt-watchdog.sh (cron */2)"
log "Удаление: csqtt-uninstall"
exit 0
