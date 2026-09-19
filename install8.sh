#!/bin/sh
# -*- coding: utf-8 -*-

set -u

CSQTT_REPO="redline-keen/csqtt-openwrt"
CSQTT_TAG="0.1"
CSQTT_LOCAL_BIN=""
CSQTT_VK_TOKEN=""
CSQTT_MODE="auto_js"
CSQTT_WORKERS="54"
CSQTT_START=1
CSQTT_LINK=""

# ── разбор аргументов ────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --repo)         CSQTT_REPO="$2"; shift 2 ;;
        --tag)          CSQTT_TAG="$2"; shift 2 ;;
        --local-bin)    CSQTT_LOCAL_BIN="$2"; shift 2 ;;
        --vk-token)     CSQTT_VK_TOKEN="$2"; shift 2 ;;
        --mode)         CSQTT_MODE="$2"; shift 2 ;;
        --workers)      CSQTT_WORKERS="$2"; shift 2 ;;
        --no-start)     CSQTT_START=0; shift ;;
        -h|--help)      sed -n '2,25p' "$0"; exit 0 ;;
        csqtt://*)      CSQTT_LINK="$1"; shift ;;
        *)              echo "Неизвестный аргумент: $1"; exit 1 ;;
    esac
done

log()  { printf '\033[1;32m[CSQTT]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[CSQTT]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[CSQTT ОШИБКА]\033[0m %s\n' "$*"; exit 1; }

# ── 1. каталог установки ───────────────────────────────────────────────────
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
CLIENT_LOG_FILE="$CSQTT_DIR/csqtt-client.log"

# ── 2. архитектура ───────────────────────────────────────────────────────────
ARCH_KEY=""
case "$(uname -m)" in
    aarch64|arm64)
        ARCH_KEY="aarch64" ;;
    mips)
        ARCH_KEY="mipsel" ;;
    *)
        die "Архитектура $(uname -m) не поддерживается" ;;
esac
log "Архитектура: $ARCH_KEY ($(uname -m)) · стиль инициализации: $INIT_STYLE"

# ── 3. получение бинарника ──────────────────────────────────────────────────
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

verify_bin() {
    [ -s "$1" ] || die "Файл $1 пуст/отсутствует"
    chmod +x "$1"
}

if [ -n "$CSQTT_LOCAL_BIN" ]; then
    [ -f "$CSQTT_LOCAL_BIN" ] || die "локальный файл не найден: $CSQTT_LOCAL_BIN"
    cp "$CSQTT_LOCAL_BIN" "$BIN_PATH" || die "не удалось скопировать бинарник"
    log "Бинарник скопирован из $CSQTT_LOCAL_BIN"
else
    [ -n "$CSQTT_REPO" ] || die "не задан --repo"
    if [ -z "$CSQTT_TAG" ]; then
        page=$(curl -fsSL -w '%{url_effective}' -o /dev/null \
               "https://github.com/$CSQTT_REPO/releases/latest" 2>/dev/null) \
            || die "не удалось узнать последний релиз $CSQTT_REPO"
        CSQTT_TAG=$(printf '%s' "$page" | sed 's|.*/tag/||')
        [ -n "$CSQTT_TAG" ] || die "в $CSQTT_REPO не найдено ни одного релиза"
    fi
    log "Релиз: $CSQTT_REPO $CSQTT_TAG"
    assets_html=$(curl -fsSL "https://github.com/$CSQTT_REPO/releases/expanded_assets/$CSQTT_TAG" 2>/dev/null) \
        || die "не удалось получить список файлов релиза"
    asset_url=$(printf '%s' "$assets_html" \
        | grep -o 'href="[^"]*releases/download/[^"]*"' \
        | sed 's/^href="//; s/"$//' \
        | grep "csqtt-client-$ARCH_KEY" \
        | tail -n 1)
    case "$asset_url" in
        /*) asset_url="https://github.com$asset_url" ;;
    esac
    [ -n "$asset_url" ] || die "Файл csqtt-client-$ARCH_KEY не найден в релизе"
    log "Скачиваю: $asset_url"
    fetch "$asset_url" "$BIN_PATH" || die "скачивание не удалось"
fi
verify_bin "$BIN_PATH"

# ── 4. ссылка подключения ────────────────────────────────────────────────────
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

if [ -z "$CSQTT_LINK" ]; then
    printf 'Вставьте ссылку подключения (csqtt://connect?...): '
    read -r CSQTT_LINK
fi
[ -n "$CSQTT_LINK" ] || die "ссылка подключения не указана"

query=$(printf '%s' "$CSQTT_LINK" | sed 's|^csqtt://[^?]*?||')
PEER_HOST=""; PEER_PORT=""; PASSWORD=""; HASHES=""
oldIFS="$IFS"; IFS='&'
for kv in $query; do
    k=${kv%%=*}; v=${kv#*=}
    case "$k" in
        host)     PEER_HOST=$(urldecode "$v") ;;
        peer)     PEER_PORT=$(urldecode "$v") ;;
        password) PASSWORD=$(urldecode "$v") ;;
        hashes)   HASHES=$(urldecode "$v") ;;
    esac
done
IFS="$oldIFS"
[ -n "$PEER_HOST" ] && [ -n "$PEER_PORT" ] && [ -n "$PASSWORD" ] \
    || die "в ссылке не найдены host / peer / password"
PEER="$PEER_HOST:$PEER_PORT"

# ── 5. VK-токен ──────────────────────────────────────────────────────────────
VK_TOKEN_FILE="$CSQTT_DIR/vk_token"
if [ "$CSQTT_MODE" = "auto_js" ]; then
    if [ -z "$CSQTT_VK_TOKEN" ] && [ -t 0 ] && [ -f "$VK_TOKEN_FILE" ]; then
        CSQTT_VK_TOKEN=$(cat "$VK_TOKEN_FILE")
    fi
    if [ -z "$CSQTT_VK_TOKEN" ]; then
        printf 'Вставьте ВЕЧНЫЙ VK access token: '
        read -r CSQTT_VK_TOKEN
    fi
    [ -n "$CSQTT_VK_TOKEN" ] || die "нужен VK access token"
    umask 077
    printf '%s' "$CSQTT_VK_TOKEN" > "$VK_TOKEN_FILE"
fi

# ── 6. device-id ─────────────────────────────────────────────────────────────
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

# ── 7. конфиг ───────────────────────────────────────────────────────────────
cat > "$CSQTT_DIR/csqtt.conf" <<EOF
PEER="$PEER"
PASSWORD="$PASSWORD"
HASHES="$HASHES"
VK_MODE="$CSQTT_MODE"
WORKERS="$CSQTT_WORKERS"
DEVICE_ID="$DEVICE_ID"
LISTEN="127.0.0.1:9000"
FINGERPRINT="firefox"
CLIENT_IDS="8202606,6287487"
OBFS="video"
TURN_TRANSPORT="udp"
CAPTCHA_MODE="auto"
TUN_IFACE="csqtt0"
TUN_MTU="1300"
LOG_FILE="$CLIENT_LOG_FILE"
EOF
chmod 600 "$CSQTT_DIR/csqtt.conf"

# ── 8. обёртка запуска ───────────────────────────────────────────────────────
cat > "$CSQTT_DIR/csqtt-run.sh" <<'EOF'
#!/bin/sh
DIR=$(dirname "$0")
. "$DIR/csqtt.conf"

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
    --captcha-mode "$CAPTCHA_MODE"

if [ -n "$TUN_IFACE" ]; then
    set -- "$@" --tun "$TUN_IFACE" --tun-mtu "$TUN_MTU"
fi

if [ "$VK_MODE" = "auto_js" ]; then
    TOKEN=$(cat "$DIR/vk_token" 2>/dev/null) || { echo "нет vk_token"; exit 1; }
    BOOTSTRAP=$(printf '{"token":"%s"}' "$TOKEN" | base64 | tr -d '\n')
    set -- "$@" --vk-hash-mode auto_js --vk-auth-mode auto_js --allow-hash-redistribution
    FIFO="$DIR/bootstrap.fifo"
    [ -p "$FIFO" ] || mkfifo "$FIFO" || { echo "не удалось создать fifo"; exit 1; }
    printf 'VK_JS_BOOTSTRAP:%s\n' "$BOOTSTRAP" > "$FIFO" &
    exec "$@" < "$FIFO" >> "$LOG_FILE" 2>&1
else
    [ -n "$HASHES" ] || { echo "нет хешей VK"; exit 1; }
    set -- "$@" --vk "$HASHES"
    exec "$@" < /dev/null >> "$LOG_FILE" 2>&1
fi
EOF
chmod +x "$CSQTT_DIR/csqtt-run.sh"

# ── 9. скрипт watchdog ──────────────────────────────────────────────────────
cat > "$CSQTT_DIR/csqtt-watchdog.sh" <<EOF
#!/bin/sh
DIR="$CSQTT_DIR"
LOG="$CLIENT_LOG_FILE"
TARGET="77.88.8.8"
IFACE="csqtt0"
MAX_SIZE=1048576

# 1. Резка лога если > 1 МБ (оставляет последние 512 КБ)
if [ -f "\$LOG" ]; then
    SIZE=\$(wc -c < "\$LOG")
    if [ "\$SIZE" -gt "\$MAX_SIZE" ]; then
        tail -c 524288 "\$LOG" > "\$LOG.tmp" && mv "\$LOG.tmp" "\$LOG"
    fi
fi

# 2. Проверка процесса
if ! pidof csqtt-client >/dev/null 2>&1; then
    if [ "$INIT_STYLE" = "openwrt" ]; then
        /etc/init.d/csqtt restart
    else
        /opt/etc/init.d/S99csqtt restart
    fi
    exit 0
fi

# 3. Проверка пинга через csqtt0
if [ -d "/sys/class/net/\$IFACE" ]; then
    if ! ping -c 2 -W 3 -I "\$IFACE" "\$TARGET" >/dev/null 2>&1; then
        if [ "$INIT_STYLE" = "openwrt" ]; then
            /etc/init.d/csqtt restart
        else
            /opt/etc/init.d/S99csqtt restart
        fi
    fi
fi
EOF
chmod +x "$CSQTT_DIR/csqtt-watchdog.sh"

# Добавление ватчдога в cron (каждые 2 минуты)
CRON_JOB="*/2 * * * * $CSQTT_DIR/csqtt-watchdog.sh"
( crontab -l 2>/dev/null | grep -v "csqtt-watchdog.sh" ; echo "$CRON_JOB" ) | crontab -

# ── 10. деинсталлятор csqtt-uninstall ─────────────────────────────────────────
cat > /usr/bin/csqtt-uninstall <<EOF
#!/bin/sh
echo "Удаление CSQTT..."

if [ -f /etc/init.d/csqtt ]; then
    /etc/init.d/csqtt stop
    /etc/init.d/csqtt disable 2>/dev/null
    rm -f /etc/init.d/csqtt
fi
if [ -f /opt/etc/init.d/S99csqtt ]; then
    /opt/etc/init.d/S99csqtt stop
    rm -f /opt/etc/init.d/S99csqtt
fi

crontab -l 2>/dev/null | grep -v "csqtt-watchdog.sh" | crontab -

rm -rf "$CSQTT_DIR"
rm -f /usr/bin/csqtt-uninstall

echo "CSQTT успешно удалён."
EOF
chmod +x /usr/bin/csqtt-uninstall

# ── 11. init-скрипт ───────────────────────────────────────────────────────────
if [ "$INIT_STYLE" = "openwrt" ]; then
cat > "$INIT_DIR/csqtt" <<EOF
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99
STOP=10

start_service() {
    procd_open_instance
    procd_set_param command /bin/sh "$CSQTT_DIR/csqtt-run.sh"
    procd_set_param respawn "\${threshold:-60}" "\${timeout:-5}" "\${retry:-0}"
    procd_set_param stdout 0
    procd_set_param stderr 0
    procd_set_param file "$CSQTT_DIR/csqtt.conf"
    procd_close_instance
}
EOF
else
cat > "$INIT_DIR/S99csqtt" <<EOF
#!/bin/sh
case "\$1" in
    start)
        "$CSQTT_DIR/csqtt-run.sh" &
        ;;
    stop)
        killall csqtt-client 2>/dev/null
        ;;
    restart)
        \$0 stop; sleep 1; \$0 start
        ;;
    *)
        echo "Usage: \$0 start|stop|restart"
        ;;
esac
EOF
fi
[ "$INIT_STYLE" = "openwrt" ] && INIT_SCRIPT="$INIT_DIR/csqtt" || INIT_SCRIPT="$INIT_DIR/S99csqtt"
chmod +x "$INIT_SCRIPT"

# ── 12. запуск ──────────────────────────────────────────────────────────────
if [ "$CSQTT_START" = "1" ]; then
    "$INIT_SCRIPT" restart
fi

log "Готово! Ватчдог работает каждые 2 мин. Деинсталлятор доступен по команде: csqtt-uninstall"
exit 0
```<FollowUp>

<ElicitationsGroup>
Удалось ли успешно установить и запустить скрипт?
</ElicitationsGroup>
</FollowUp>