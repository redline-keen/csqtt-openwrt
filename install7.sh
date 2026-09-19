#!/bin/sh
# -*- coding: utf-8 -*-

set -u

CSQTT_REPO="redline-keen/csqtt-openwrt"[cite: 2]
CSQTT_TAG="0.1"[cite: 2]
CSQTT_LOCAL_BIN=""[cite: 2]
CSQTT_VK_TOKEN=""[cite: 2]
CSQTT_MODE="auto_js"[cite: 2]
CSQTT_WORKERS="54"[cite: 2]
CSQTT_START=1[cite: 2]
CSQTT_LINK=""[cite: 2]

# ── разбор аргументов ────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --repo)         CSQTT_REPO="$2"; shift 2 ;;[cite: 2]
        --tag)          CSQTT_TAG="$2"; shift 2 ;;[cite: 2]
        --local-bin)    CSQTT_LOCAL_BIN="$2"; shift 2 ;;[cite: 2]
        --vk-token)     CSQTT_VK_TOKEN="$2"; shift 2 ;;[cite: 2]
        --mode)         CSQTT_MODE="$2"; shift 2 ;;[cite: 2]
        --workers)      CSQTT_WORKERS="$2"; shift 2 ;;[cite: 2]
        --no-start)     CSQTT_START=0; shift ;;[cite: 2]
        -h|--help)      sed -n '2,25p' "$0"; exit 0 ;;[cite: 2]
        csqtt://*)      CSQTT_LINK="$1"; shift ;;[cite: 2]
        *)              echo "Неизвестный аргумент: $1"; exit 1 ;;[cite: 2]
    esac
done

log()  { printf '\033[1;32m[CSQTT]\033[0m %s\n' "$*"; }[cite: 2]
warn() { printf '\033[1;33m[CSQTT]\033[0m %s\n' "$*"; }[cite: 2]
die()  { printf '\033[1;31m[CSQTT ОШИБКА]\033[0m %s\n' "$*"; exit 1; }[cite: 2]

# ── 1. каталог установки ───────────────────────────────────────────────────
if [ -d /opt/entware ] || [ -d /opt/etc/init.d ]; then[cite: 2]
    CSQTT_DIR="/opt/etc/csqtt"[cite: 2]
    INIT_DIR="/opt/etc/init.d"[cite: 2]
    INIT_STYLE="entware"[cite: 2]
else
    CSQTT_DIR="/etc/csqtt"[cite: 2]
    INIT_DIR="/etc/init.d"[cite: 2]
    INIT_STYLE="openwrt"[cite: 2]
fi
mkdir -p "$CSQTT_DIR" "$INIT_DIR" 2>/dev/null || die "нет прав на запись (запускайте под root)"[cite: 2]
CLIENT_LOG_FILE="$CSQTT_DIR/csqtt-client.log"

# ── 2. архитектура ───────────────────────────────────────────────────────────
ARCH_KEY=""[cite: 2]
case "$(uname -m)" in
    aarch64|arm64)[cite: 2]
        ARCH_KEY="aarch64" ;;[cite: 2]
    mips)[cite: 2]
        ARCH_KEY="mipsel" ;;[cite: 2]
    *)
        die "Архитектура $(uname -m) не поддерживается" ;;[cite: 2]
esac
log "Архитектура: $ARCH_KEY ($(uname -m)) · стиль инициализации: $INIT_STYLE"[cite: 2]

# ── 3. получение бинарника ──────────────────────────────────────────────────
BIN_PATH="$CSQTT_DIR/csqtt-client"[cite: 2]

fetch() {[cite: 2]
    if command -v curl >/dev/null 2>&1; then[cite: 2]
        curl -fsSL "$1" -o "$2"[cite: 2]
    elif command -v wget >/dev/null 2>&1; then[cite: 2]
        wget -q -O "$2" "$1"[cite: 2]
    else
        die "Нужен curl или wget"[cite: 2]
    fi
}

verify_bin() {[cite: 2]
    [ -s "$1" ] || die "Файл $1 пуст/отсутствует"[cite: 2]
    chmod +x "$1"[cite: 2]
}

if [ -n "$CSQTT_LOCAL_BIN" ]; then[cite: 2]
    [ -f "$CSQTT_LOCAL_BIN" ] || die "локальный файл не найден: $CSQTT_LOCAL_BIN"[cite: 2]
    cp "$CSQTT_LOCAL_BIN" "$BIN_PATH" || die "не удалось скопировать бинарник"[cite: 2]
    log "Бинарник скопирован из $CSQTT_LOCAL_BIN"[cite: 2]
else
    [ -n "$CSQTT_REPO" ] || die "не задан --repo"[cite: 2]
    if [ -z "$CSQTT_TAG" ]; then[cite: 2]
        page=$(curl -fsSL -w '%{url_effective}' -o /dev/null \
               "https://github.com/$CSQTT_REPO/releases/latest" 2>/dev/null) \
            || die "не удалось узнать последний релиз $CSQTT_REPO"[cite: 2]
        CSQTT_TAG=$(printf '%s' "$page" | sed 's|.*/tag/||')[cite: 2]
        [ -n "$CSQTT_TAG" ] || die "в $CSQTT_REPO не найдено ни одного релиза"[cite: 2]
    fi
    log "Релиз: $CSQTT_REPO $CSQTT_TAG"[cite: 2]
    assets_html=$(curl -fsSL "https://github.com/$CSQTT_REPO/releases/expanded_assets/$CSQTT_TAG" 2>/dev/null) \
        || die "не удалось получить список файлов релиза"[cite: 2]
    asset_url=$(printf '%s' "$assets_html" \
        | grep -o 'href="[^"]*releases/download/[^"]*"' \
        | sed 's/^href="//; s/"$//' \
        | grep "csqtt-client-$ARCH_KEY" \
        | tail -n 1)[cite: 2]
    case "$asset_url" in
        /*) asset_url="https://github.com$asset_url" ;;[cite: 2]
    esac
    [ -n "$asset_url" ] || die "Файл csqtt-client-$ARCH_KEY не найден в релизе"
    log "Скачиваю: $asset_url"[cite: 2]
    fetch "$asset_url" "$BIN_PATH" || die "скачивание не удалось"[cite: 2]
fi
verify_bin "$BIN_PATH"[cite: 2]

# ── 4. ссылка подключения ────────────────────────────────────────────────────
urldecode() {[cite: 2]
    s="$1"; out=""; i=0; n=${#s}[cite: 2]
    while [ "$i" -lt "$n" ]; do[cite: 2]
        c=${s:$i:1}[cite: 2]
        if [ "$c" = "%" ] && [ $((i + 2)) -lt "$n" ]; then[cite: 2]
            out="$out$(printf '\\x'${s:$((i+1)):2})"[cite: 2]
            i=$((i + 3))[cite: 2]
        else
            out="$out$c"; i=$((i + 1))[cite: 2]
        fi
    done
    printf '%s' "$out"[cite: 2]
}

if [ -z "$CSQTT_LINK" ]; then[cite: 2]
    printf 'Вставьте ссылку подключения (csqtt://connect?...): '[cite: 2]
    read -r CSQTT_LINK[cite: 2]
fi
[ -n "$CSQTT_LINK" ] || die "ссылка подключения не указана"[cite: 2]

query=$(printf '%s' "$CSQTT_LINK" | sed 's|^csqtt://[^?]*?||')[cite: 2]
PEER_HOST=""; PEER_PORT=""; PASSWORD=""; HASHES=""[cite: 2]
oldIFS="$IFS"; IFS='&'[cite: 2]
for kv in $query; do[cite: 2]
    k=${kv%%=*}; v=${kv#*=}[cite: 2]
    case "$k" in
        host)     PEER_HOST=$(urldecode "$v") ;;[cite: 2]
        peer)     PEER_PORT=$(urldecode "$v") ;;[cite: 2]
        password) PASSWORD=$(urldecode "$v") ;;[cite: 2]
        hashes)   HASHES=$(urldecode "$v") ;;[cite: 2]
    esac
done
IFS="$oldIFS"[cite: 2]
[ -n "$PEER_HOST" ] && [ -n "$PEER_PORT" ] && [ -n "$PASSWORD" ] \
    || die "в ссылке не найдены host / peer / password"[cite: 2]
PEER="$PEER_HOST:$PEER_PORT"[cite: 2]

# ── 5. VK-токен ──────────────────────────────────────────────────────────────
VK_TOKEN_FILE="$CSQTT_DIR/vk_token"[cite: 2]
if [ "$CSQTT_MODE" = "auto_js" ]; then[cite: 2]
    if [ -z "$CSQTT_VK_TOKEN" ] && [ -t 0 ] && [ -f "$VK_TOKEN_FILE" ]; then[cite: 2]
        CSQTT_VK_TOKEN=$(cat "$VK_TOKEN_FILE")[cite: 2]
    fi
    if [ -z "$CSQTT_VK_TOKEN" ]; then[cite: 2]
        printf 'Вставьте ВЕЧНЫЙ VK access token: '[cite: 2]
        read -r CSQTT_VK_TOKEN[cite: 2]
    fi
    [ -n "$CSQTT_VK_TOKEN" ] || die "нужен VK access token"[cite: 2]
    umask 077[cite: 2]
    printf '%s' "$CSQTT_VK_TOKEN" > "$VK_TOKEN_FILE"[cite: 2]
fi

# ── 6. device-id ─────────────────────────────────────────────────────────────
DEVICE_ID=""[cite: 2]
if [ -f "$CSQTT_DIR/device_id" ]; then[cite: 2]
    DEVICE_ID=$(cat "$CSQTT_DIR/device_id" 2>/dev/null)[cite: 2]
fi
if [ -z "$DEVICE_ID" ]; then[cite: 2]
    DEVICE_ID=$(cat /sys/firmware/devicetree/base/serial-number 2>/dev/null | tr -d '\0')[cite: 2]
    [ -n "$DEVICE_ID" ] || DEVICE_ID=$(cat /etc/serial 2>/dev/null)[cite: 2]
    [ -n "$DEVICE_ID" ] || DEVICE_ID=$(hostname)-$(head -c 4 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' || hostname)[cite: 2]
    printf '%s' "$DEVICE_ID" > "$CSQTT_DIR/device_id"[cite: 2]
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
chmod 600 "$CSQTT_DIR/csqtt.conf"[cite: 2]

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
chmod +x "$CSQTT_DIR/csqtt-run.sh"[cite: 2]

# ── 9. скрипт watchdog ──────────────────────────────────────────────────────
cat > "$CSQTT_DIR/csqtt-watchdog.sh" <<EOF
#!/bin/sh
DIR="$CSQTT_DIR"
LOG="$CLIENT_LOG_FILE"
TARGET="77.88.8.8"
IFACE="csqtt0"
MAX_SIZE=1048576

# 1. Резка лога если > 1 МБ
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

# Добавление ватчдога в cron (раз в 2 минуты)
CRON_JOB="*/2 * * * * $CSQTT_DIR/csqtt-watchdog.sh"
( crontab -l 2>/dev/null | grep -v "csqtt-watchdog.sh" ; echo "$CRON_JOB" ) | crontab -

# ── 10. деинсталлятор csqtt-uninstall ─────────────────────────────────────────
cat > /usr/bin/csqtt-uninstall <<EOF
#!/bin/sh
echo "Удаление CSQTT..."

# Остановка сервиса
if [ -f /etc/init.d/csqtt ]; then
    /etc/init.d/csqtt stop
    /etc/init.d/csqtt disable 2>/dev/null
    rm -f /etc/init.d/csqtt
fi
if [ -f /opt/etc/init.d/S99csqtt ]; then
    /opt/etc/init.d/S99csqtt stop
    rm -f /opt/etc/init.d/S99csqtt
fi

# Удаление из cron
crontab -l 2>/dev/null | grep -v "csqtt-watchdog.sh" | crontab -

# Удаление файлов
rm -rf "$CSQTT_DIR"
rm -f /usr/bin/csqtt-uninstall

echo "CSQTT успешно удалён."
EOF
chmod +x /usr/bin/csqtt-uninstall

# ── 11. init-скрипт ───────────────────────────────────────────────────────────
if [ "$INIT_STYLE" = "openwrt" ]; then[cite: 2]
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
[ "$INIT_STYLE" = "openwrt" ] && INIT_SCRIPT="$INIT_DIR/csqtt" || INIT_SCRIPT="$INIT_DIR/S99csqtt"[cite: 2]
chmod +x "$INIT_SCRIPT"[cite: 2]

# ── 12. запуск ──────────────────────────────────────────────────────────────
if [ "$CSQTT_START" = "1" ]; then[cite: 2]
    "$INIT_SCRIPT" restart[cite: 2]
fi

log "Готово! Ватчдог каждые 2 мин. Деинсталлятор: csqtt-uninstall"
exit 0
```<FollowUp>

<ElicitationsGroup>
Запустился ли у вас csqtt-client через обновленный скрипт и добавилась ли задача в `crontab -l`?
</ElicitationsGroup>
</FollowUp>