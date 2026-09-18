#!/bin/sh
# shellcheck disable=SC2086,SC2154,SC2183,SC2236,SC3044,SC3051,SC3028,SC3010,SC3006,SC1091
# csqtt-github-install-11092026-0200-slim-conf-an7581.sh
#
# CSQTT — установщик клиента на роутер (Keenetic / OpenWrt 25 / Airoha AN7581).
# Сборка: 11092026-0200 «slim-conf» (функционально = 10092026-2350 mihomo-conf
# + slim csqtt.conf). Бинарники: pool-rotate-линейка (10092026-1341 и новее).
# Совместимость по arch: aarch64 → MT7981 / Airoha AN7581, mips/mipsel → MT7621.
#
# Кумулятивные фичи из 5 приложенных INSTALL-*.md:
#   0636  — авторежим VK (auto_js), разбор csqtt://, TUN csqtt0, init-сервис
#   1341  — пул хешей vk_pool, воркеры 9–162, хеши 1–6, правило 27:1, суточная ротация cron */5
#   1946  — watchdog cron */2 (процесс + TUN + пинг), uninstaller csqtt-uninstall
#   2350  — лог в $CSQTT_DIR/csqtt.log ≤1 МБ с сохранением inode, mihomo config.yaml download
#   0200  — slim csqtt.conf (PEER/PASSWORD/HASHES/WORKERS/TUN_*), device_id отдельным файлом
#
# Лицензия исходников: PolyForm-Noncommercial-1.0.0 (amurcanov/csqtt).
# Этот установочный скрипт распространяется как есть, без гарантий.

set -u  # не set -e: хотим дойти до конца даже при нефатальных ошибках

# ────────────────────────── НИЗ: КОНСТАНТЫ ──────────────────────────

SCRIPT_VERSION="11092026-0200-slim-conf-an7581"
DEFAULT_TAG="${CSQTT_TAG:-v2.1.9-router}"
DEFAULT_REPO="${CSQTT_REPO:-amurcanov/csqtt-router}"
DEFAULT_HASHES=4
DEFAULT_TUN_IFACE="csqtt0"
DEFAULT_TUN_MTU=1300
DEFAULT_PING_HOST=77.88.8.8
MAX_WORKERS_PER_HASH=27
WORKER_STEP=9
MAX_HASHES=6
MIN_HASHES=1
MAX_WORKERS=$((MAX_HASHES * MAX_WORKERS_PER_HASH))  # 162
MIN_WORKERS=9
LOG_MAX_BYTES=$((1024 * 1024))
LOG_TAIL_LINES=500
MIHOMO_CONF_DEFAULT_BRANCH="main"
MIHOMO_CONF_FILENAME="csqtt-config.yaml"

# Платформа-зависимые пути выставляются в detect_platform()
CSQTT_DIR=""
INIT_SCRIPT=""
CRON_DIR=""
BIN_DIR=""
DOWNLOAD_TOOL=""
DEVICE_ID_SRC=""
HAVE_PROCD=0
IS_OPENWRT=0

# Параметры из CLI / интерактива
CSQTT_URL=""
REPO="$DEFAULT_REPO"
TAG="$DEFAULT_TAG"
LOCAL_BIN=""
VK_TOKEN=""
HASHES_INPUT=""
WORKERS_INPUT=""
MODE="auto_js"  # только auto_js в этом билде
TUN_IFACE_INPUT=""
TUN_MTU_INPUT=""
FINGERPRINT_INPUT=""
NO_START=0
NO_ROTATE=0
NO_WATCHDOG=0
NO_MIHOMO_ASK=0
MIHOMO_CONF_URL=""
LOCAL_BIN_FORCED=0

# ────────────────────────── НИЗ: УТИЛИТЫ ──────────────────────────────

log() { printf '%s\n' "$*" >&2; }
die() { printf 'ошибка: %s\n' "$*" >&2; exit 2; }
warn() { printf 'предупреждение: %s\n' "$*" >&2; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Простой percent-decoder (без perl/python — чистый sh). Работает в busybox ash и dash.
# Заменяет %XX (hex) на символ. Поддерживает также %XXXX (UTF-8) — но для csqtt://
# URL чаще всего встречаются ASCII-безопасные символы, поэтому декодер не требуется;
# однако VK-хеш может содержать _ и URL-unsafe символы — на всякий случай декодируем.
url_decode() {
  _s=$1
  _out=""
  while :; do
    case "$_s" in
      "") break ;;
      %)
        # одинокий % в конце — не валидный %XX, выведем буквально
        _out="${_out}%"
        break
        ;;
      %*)
        # _s начинается с % — берём 2 hex символа
        _rest=${_s#%}
        if [ ${#_rest} -ge 2 ]; then
          _hex=${_rest%"${_rest#??}"}
          # валидный 2-hex? тогда hex→dec→oct→char через `printf "\OOO"`
          case "$_hex" in
            [0-9a-fA-F][0-9a-fA-F])
              _dec=$((0x$_hex))
              _oct=$(printf '%o' "$_dec" 2>/dev/null)
              _c=$(printf "\\$_oct" 2>/dev/null)
              ;;
            *)
              # невалидный hex — выведем % + _hex буквально, не теряем данные
              _c="%$_hex"
              ;;
          esac
          _out="${_out}${_c}"
          _s=${_rest#??}
        else
          # только % + 1 символ — невалидно, выведем % буквально
          _out="${_out}%"
          _s=$_rest
        fi
        ;;
      *%*)
        # _s содержит % в середине — берём всё до %, оставляем %XXX в _s
        _pre=${_s%%\%*}
        _out="${_out}${_pre}"
        # удаляем ТОЛЬКО префикс, не %. Тогда след. итерация пойдёт в `%*).
        _s=${_s#"$_pre"}
        ;;
      *)
        # нет % — добавляем всё остальное и выходим
        _out="${_out}${_s}"
        break
        ;;
    esac
  done
  printf '%s' "$_out"
}

# Очень компактный hexdump-заменитель: печатает первые 4 байта в hex.
# Если есть hexdump, используем; иначе — od; иначе — ручной цикл.
elf_magic_check() {
  # $1 = путь к файлу. Возвращает 0 если первые 4 байта = 7f 45 4c 46 ("ELF")
  _f=$1
  [ -f "$_f" ] || return 1
  if have_cmd hexdump; then
    _h=$(hexdump -C -n 4 "$_f" 2>/dev/null | head -1)
    case "$_h" in
      *"7f 45 4c 46"*) return 0 ;;
    esac
  fi
  if have_cmd od; then
    _h=$(od -A n -t x1 -N 4 "$_f" 2>/dev/null | tr -d ' \t\n')
    case "$_h" in
      7f454c46) return 0 ;;
    esac
  fi
  # фолбэк на sh + head/dd (busybox умеет в dd bs=1 count=4)
  if have_cmd head && have_cmd od 2>/dev/null; then :; fi
  _b1=$(dd if="$_f" bs=1 count=1 skip=0 2>/dev/null | od -An -tx1 | tr -d ' \n')
  _b2=$(dd if="$_f" bs=1 count=1 skip=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
  _b3=$(dd if="$_f" bs=1 count=1 skip=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
  _b4=$(dd if="$_f" bs=1 count=1 skip=3 2>/dev/null | od -An -tx1 | tr -d ' \n')
  [ "$_b1$_b2$_b3$_b4" = "7f454c46" ]
}

elf_class_check() {
  # $1 = путь. Печатает "32"/"64"/"". 0 если файл не ELF.
  _f=$1
  [ -f "$_f" ] || return 1
  if have_cmd od; then
    _c=$(od -An -tu1 -N1 -j4 "$_f" 2>/dev/null | tr -d ' \t\n')
    case "$_c" in
      1) printf '32' ;;
      2) printf '64' ;;
    esac
  fi
}

elf_machine_check() {
  # $1 = путь. Печатает "aarch64"/"x86_64"/"mips"/"mipsel"/"".
  _f=$1
  [ -f "$_f" ] || return 1
  if have_cmd od; then
    # e_machine — u16 @ offset 18 (0x12). На LE — два байта, байты обратны.
    _m=$(od -An -tu2 -N2 -j18 "$_f" 2>/dev/null | tr -d ' \t\n')
    case "$_m" in
      183) printf 'aarch64' ;;   # EM_AARCH64
      62)  printf 'x86_64' ;;    # EM_X86_64
      8)   printf 'mips' ;;      # EM_MIPS (BE)
    esac
    # Для LE надо ещё глянуть Data Encoding @ offset 5: 1=LE 2=BE
    _d=$(od -An -tu1 -N1 -j5 "$_f" 2>/dev/null | tr -d ' \t\n')
    if [ "$_m" = "8" ]; then
      case "$_d" in
        1) printf 'mipsel' ;;
        2) printf 'mips' ;;
      esac
    fi
  fi
}

# ────────────────────────── ПЛАТФОРМА ────────────────────────────────

detect_platform() {
  # Определяем: Entware (Keenetic, /opt/...) vs OpenWrt (/etc/init.d + procd)
  if [ -d /opt/etc/init.d ] && have_cmd opkg 2>/dev/null && [ -e /opt/etc/opkg.conf ] 2>/dev/null; then
    CSQTT_DIR="/opt/etc/csqtt"
    INIT_SCRIPT="/opt/etc/init.d/S99csqtt"
    CRON_DIR="/opt/etc/cron.d"
    BIN_DIR="/opt/bin"
    IS_OPENWRT=0
  elif [ -d /etc/init.d ] && [ -e /etc/openwrt_release ] 2>/dev/null; then
    CSQTT_DIR="/etc/csqtt"
    INIT_SCRIPT="/etc/init.d/csqtt"
    CRON_DIR="/etc/cron.d"
    BIN_DIR="/usr/bin"
    IS_OPENWRT=1
    HAVE_PROCD=1
  elif [ -d /etc/init.d ] && have_cmd procd 2>/dev/null; then
    # OpenWrt без /etc/openwrt_release — на новых релизах нет этого файла
    CSQTT_DIR="/etc/csqtt"
    INIT_SCRIPT="/etc/init.d/csqtt"
    CRON_DIR="/etc/cron.d"
    BIN_DIR="/usr/bin"
    IS_OPENWRT=1
    HAVE_PROCD=1
  elif [ -d /etc/init.d ]; then
    # Фолбэк: OpenWrt-подобный init.d (в т.ч. OpenWRT 25 post-23.05 layout)
    CSQTT_DIR="/etc/csqtt"
    INIT_SCRIPT="/etc/init.d/csqtt"
    CRON_DIR="/etc/cron.d"
    BIN_DIR="/usr/bin"
    IS_OPENWRT=1
    HAVE_PROCD=1
  else
    CSQTT_DIR="/etc/csqtt"
    INIT_SCRIPT="/etc/init.d/csqtt"
    CRON_DIR="/etc/cron.d"
    BIN_DIR="/usr/bin"
    IS_OPENWRT=1
    HAVE_PROCD=1
    warn "не удалось определить платформу — предполагаем OpenWrt"
  fi

  # Инструмент скачивания
  if have_cmd curl; then
    DOWNLOAD_TOOL="curl"
  elif have_cmd wget; then
    DOWNLOAD_TOOL="wget"
  else
    DOWNLOAD_TOOL=""
  fi

  # Источник device_id
  for _p in /proc/sys/dev/nvram/serial_number \
            /proc/nvram/SerialNumber \
            /sys/class/net/eth0/address \
            /sys/class/net/eth0.1/address \
            /etc/hostname; do
    if [ -r "$_p" ]; then
      DEVICE_ID_SRC="$_p"
      break
    fi
  done
  [ -z "$DEVICE_ID_SRC" ] && DEVICE_ID_SRC="/etc/hostname"

  log "платформа: ${IS_OPENWRT:-0} (OpenWrt=1), CSQTT_DIR=$CSQTT_DIR, BIN_DIR=$BIN_DIR"
}

# ────────────────────────── ARCH ────────────────────────────────────

detect_arch() {
  ARCH_RAW=$(uname -m 2>/dev/null || echo unknown)
  case "$ARCH_RAW" in
    aarch64|arm64)  CSQTT_ARCH="aarch64"; ASSET_PREFIX="csqtt-client-aarch64-" ;;
    mips|mipsel)   CSQTT_ARCH="mipsel";  ASSET_PREFIX="csqtt-client-mipsel-" ;;
    armv7l|armv6l)  CSQTT_ARCH="armv7";   ASSET_PREFIX="csqtt-client-armv7-"  ;;
    x86_64)         CSQTT_ARCH="x86_64"; ASSET_PREFIX="csqtt-client-x86_64-" ;;
    *)              CSQTT_ARCH="";        ASSET_PREFIX="" ;;
  esac
  log "архитектура: uname=$ARCH_RAW → csqtt_arch=${CSQTT_ARCH:-НЕИЗВЕСТНА}"
  if [ -z "$CSQTT_ARCH" ]; then
    die "неподдерживаемая архитектура: $ARCH_RAW. Скрипт поддерживает aarch64 / mips / mipsel."
  fi
}

# ────────────────────────── PARSE csqtt:// ───────────────────────────

parse_csqtt_url() {
  # $1 = "csqtt://connect?v=2&host=...&peer=...&password=...&hashes=...&..."
  # Заносит PEER, PASSWORD, HASHES_URL (если есть) в глобальные PEER_URL / PASSWORD_URL / ...
  _u=$1
  case "$_u" in
    csqtt://*) ;;
    *) die "ссылка должна начинаться с csqtt:// — получено: $_u" ;;
  esac
  # отбрасываем csqtt://connect? или csqtt://...?
  _q=${_u#csqtt://}
  # отбрасываем хост-часть до ?
  case "$_q" in
    *\?*) _q=${_q#*\?} ;;
    *) _q="" ;;
  esac
  PEER_INPUT=""
  PASSWORD_INPUT=""
  HASHES_URL_INPUT=""
  # делим по & (просто sh-циклом)
  _oldifs=${IFS:-}
  IFS='&'
  for kv in $_q; do
    IFS='='
    set -- $kv
    _k=$1
    _v=$2
    IFS='&'
    case "$_k" in
      peer)     PEER_INPUT=$(url_decode "$_v") ;;
      password) PASSWORD_INPUT=$(url_decode "$_v") ;;
      hashes)   HASHES_URL_INPUT=$(url_decode "$_v") ;;
      host)     PEER_INPUT="${_v}" ;;  # если указан только host — брутфорсим дефолт порт 46000
      *) : ;;
    esac
  done
  IFS="$_oldifs"
  # Если host указан без peer, добавляем :46000
  if [ -z "$PEER_INPUT" ]; then :; fi
  if [ -n "$PEER_INPUT" ]; then
    case "$PEER_INPUT" in
      *:*) : ;;
      *) PEER_INPUT="$PEER_INPUT:46000" ;;
    esac
  fi
  [ -z "$PEER_INPUT" ]   && die "в ссылке csqtt:// нет параметра peer (или host)"
  [ -z "$PASSWORD_INPUT" ] && die "в ссылке csqtt:// нет параметра password"
  log "parse: peer=$PEER_INPUT password=<скрыт> ${HASHES_URL_INPUT:+hashes=$HASHES_URL_INPUT}"
}

# ────────────────────────── СКАЧИВАНИЕ БИНАРЯ ─────────────────────────

fetch_binary() {
  if [ "$LOCAL_BIN_FORCED" -eq 1 ]; then
    [ -f "$LOCAL_BIN" ] || die "локальный бинарник не найден: $LOCAL_BIN"
    log "используем локальный бинарник: $LOCAL_BIN"
    return 0
  fi
  [ -n "$CSQTT_ARCH" ] || die "архитектура не определена"
  [ -n "$DOWNLOAD_TOOL" ] || die "нужен curl или wget для скачивания из GitHub-релиза (или --local-bin)"

  BIN_DST_PATH="$CSQTT_DIR/csqtt-client"
  TMP_PATH="$CSQTT_DIR/.csqtt-client.download"
  API_URL="https://api.github.com/repos/${REPO}/releases/tags/${TAG}"

  log "получаем список ассетов релиза $REPO@$TAG ..."
  if [ "$DOWNLOAD_TOOL" = "curl" ]; then
    API_JSON=$(curl -fsSL -H 'Accept: application/vnd.github+json' "$API_URL" 2>/dev/null) || API_JSON=""
  else
    API_JSON=$(wget -qO- --header='Accept: application/vnd.github+json' "$API_URL" 2>/dev/null) || API_JSON=""
  fi
  if [ -z "$API_JSON" ]; then
    die "не удалось получить список ассетов из $API_URL (нет сети / невалидный тег). Используйте --local-bin."
  fi

  # Грепаем browser_download_url, фильтруем по префиксу арха.
  # Не парсим JSON (нет jq в роутере), просто grep + sed.
  if have_cmd grep && have_cmd sed; then
    ASSETS=$(printf '%s\n' "$API_JSON" | grep -o '"browser_download_url": *"[^"]*"' | sed 's/.*": *"\([^"]*\)"/\1/')
  else
    ASSETS=""
  fi

  [ -z "$ASSETS" ] && die "в релизе $REPO@$TAG нет ассетов с browser_download_url"

  MATCH=""
  for url in $ASSETS; do
    case "$(basename "$url")" in
      "${ASSET_PREFIX}"*)
        MATCH="$url"
        break
        ;;
    esac
  done

  [ -z "$MATCH" ] && die "в релизе $REPO@$TAG нет файла с префиксом ${ASSET_PREFIX} (нужен, например, ${ASSET_PREFIX}an7581-…)"

  log "скачиваем: $MATCH"
  if [ "$DOWNLOAD_TOOL" = "curl" ]; then
    curl -fsSL -o "$TMP_PATH" "$MATCH" || die "curl не смог скачать $MATCH"
  else
    wget -qO "$TMP_PATH" "$MATCH" || die "wget не смог скачать $MATCH"
  fi
  chmod +x "$TMP_PATH"
  mv "$TMP_PATH" "$BIN_DST_PATH"
  log "бинарник сохранён в $BIN_DST_PATH"
}

# ────────────────────────── ПРОВЕРКА БИНАРЯ ───────────────────────────

verify_binary() {
  BIN="$CSQTT_DIR/csqtt-client"
  [ -f "$BIN" ] || die "бинарник не найден: $BIN"
  elf_magic_check "$BIN" || die "файл $BIN не является корректным ELF (ожидался magic 7f 45 4c 46). Возможно, файл скачался не полностью — повторите установку."
  _cls=$(elf_class_check "$BIN")
  case "$_cls" in
    32|64) ;;
    *) die "не удалось определить разрядность ELF (получено: $_cls). Возможно, busybox без od." ;;
  esac
  if [ "$_cls" = "32" ] && [ "$CSQTT_ARCH" = "aarch64" ]; then
    warn "бинарник 32-битный, а ваша архитектура aarch64 — это нецелевая сборка, но должно работать на 32-битной подсистеме."
  fi
  _mach=$(elf_machine_check "$BIN")
  if [ -n "$_mach" ]; then
    if [ "$_mach" = "$CSQTT_ARCH" ]; then
      log "ELF-машина совпадает с arch (=$_mach)"
    else
      warn "ELF-машина: $_mach, а uname -m: $ARCH_RAW. Возможно, скачался не тот файл."
    fi
  fi
  # Запуск не делаем — мы на сборщике не знаем, что целевой роутер.
  log "ELF-заголовок корректен. Запустите на целевом роутере, чтобы убедиться."
}

# ────────────────────────── DEVICE ID ─────────────────────────────────

generate_device_id() {
  # Стабильный идентификатор устройства. Серийник роутера если есть, иначе hostname+mac.
  _id=""
  if [ -r "$DEVICE_ID_SRC" ]; then
    _id=$(cat "$DEVICE_ID_SRC" 2>/dev/null | tr -d '\n')
    # обрезаем спецсимволы
    _id=$(printf '%s' "$_id" | tr -c -d 'A-Za-z0-9-' | head -c 32)
  fi
  if [ -z "$_id" ]; then
    # фолбэк: hostname + первый MAC-адрес
    _hn=$(cat /etc/hostname 2>/dev/null | tr -c -d 'A-Za-z0-9-' | head -c 16)
    _mac=$(cat /sys/class/net/*/address 2>/dev/null | head -1 | tr -d ':' | head -c 12)
    _id="${_hn}-${_mac}"
  fi
  [ -z "$_id" ] && _id="router-$$"
  DEVICE_ID="$_id"
  log "device-id: $DEVICE_ID"
}

# ────────────────────────── VK ТОКЕН ─────────────────────────────────

ensure_vk_token() {
  TOKEN_FILE="$CSQTT_DIR/vk_token"
  # 1) --vk-token
  if [ -n "$VK_TOKEN" ]; then
    printf '%s' "$VK_TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    log "VK-токен сохранён в $TOKEN_FILE (из --vk-token)"
    return 0
  fi
  # 2) уже есть в файле
  if [ -s "$TOKEN_FILE" ]; then
    log "VK-токен уже есть в $TOKEN_FILE — оставляем как есть"
    return 0
  fi
  # 3) интерактивный prompt
  if [ -t 0 ] || [ -t 1 ]; then
    printf 'Вставьте ВЕЧНЫЙ VK access token (получается по ссылке из INSTALL.md, шаг 1):\n' >&2
    printf '> ' >&2
    read -r _tk
    [ -n "$_tk" ] || die "пустой токен. Без токена авторежим ВК работать не будет."
    printf '%s' "$_tk" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    log "VK-токен сохранён в $TOKEN_FILE"
    return 0
  fi
  die "VK-токен не найден. Передайте --vk-token 'vk1.a.…' или запустите скрипт в интерактивной сессии."
}

# ────────────────────────── ХЕШИ / ВОРКЕРЫ ───────────────────────────

ask_hashes_workers() {
  # HASHES
  if [ -z "$HASHES_INPUT" ]; then
    if [ -t 0 ] || [ -t 1 ]; then
      printf 'Число хешей (1–6, Enter = %d): ' "$DEFAULT_HASHES" >&2
      read -r _h
      HASHES_INPUT=${_h:-$DEFAULT_HASHES}
    else
      HASHES_INPUT=$DEFAULT_HASHES
    fi
  fi
  case "$HASHES_INPUT" in
    ''|*[!0-9]*) die "хеши должны быть числом 1–6, получено: '$HASHES_INPUT'" ;;
  esac
  [ "$HASHES_INPUT" -ge "$MIN_HASHES" ] && [ "$HASHES_INPUT" -le "$MAX_HASHES" ] \
    || die "хеши вне диапазона 1–6: $HASHES_INPUT"
  HASHES=$HASHES_INPUT
  # если в ссылке был параметр hashes=, он игнорируется (правило пула — задаёт пользователь/конфиг)
  MAX_W_FOR_POOL=$((HASHES * MAX_WORKERS_PER_HASH))

  # WORKERS
  if [ -z "$WORKERS_INPUT" ]; then
    if [ -t 0 ] || [ -t 1 ]; then
      printf 'Число воркеров (9–%d, Enter = максимум для пула = %d): ' "$MAX_W_FOR_POOL" "$MAX_W_FOR_POOL" >&2
      read -r _w
      WORKERS_INPUT=${_w:-$MAX_W_FOR_POOL}
    else
      WORKERS_INPUT=$MAX_W_FOR_POOL
    fi
  fi
  case "$WORKERS_INPUT" in
    ''|*[!0-9]*) die "воркеры должны быть числом 9–$MAX_WORKERS, получено: '$WORKERS_INPUT'" ;;
  esac
  [ "$WORKERS_INPUT" -ge "$MIN_WORKERS" ] && [ "$WORKERS_INPUT" -le "$MAX_WORKERS" ] \
    || die "воркеры вне диапазона 9–$MAX_WORKERS: $WORKERS_INPUT"

  # правило 27:1 — урезаем до HASHES*27
  if [ "$WORKERS_INPUT" -gt "$MAX_W_FOR_POOL" ]; then
    log "Воркеров $WORKERS_INPUT → $MAX_W_FOR_POOL: правило 27 воркеров на хеш"
    WORKERS_INPUT=$MAX_W_FOR_POOL
  fi
  # шаг 9
  WORKERS_REM=$((WORKERS_INPUT % WORKER_STEP))
  if [ "$WORKERS_REM" -ne 0 ]; then
    WORKERS_INPUT=$((WORKERS_INPUT - WORKERS_REM))
    [ "$WORKERS_INPUT" -lt "$MIN_WORKERS" ] && WORKERS_INPUT=$MIN_WORKERS
    log "Округляем воркеры по шагу 9 → $WORKERS_INPUT"
  fi
  WORKERS=$WORKERS_INPUT
}

# ────────────────────────── SLIM КОНФИГ ───────────────────────────────

write_slim_config() {
  CONF="$CSQTT_DIR/csqtt.conf"
  cat > "$CONF" <<EOF
# CSQTT — slim-конфиг (сборка 11092026-0200-slim-conf-an7581)
# Редактируйте и перезапускайте службу: OpenWrt: service csqtt restart; Keenetic: /opt/etc/init.d/S99csqtt restart
# Конфиг источникится обёрткой csqtt-run.sh ДО дефолтов, раскомментируйте строку (снимите #), чтобы override.
PEER="$PEER_INPUT"
PASSWORD="$PASSWORD_INPUT"
HASHES=$HASHES
WORKERS=$WORKERS
TUN_IFACE="${TUN_IFACE_INPUT:-$DEFAULT_TUN_IFACE}"
TUN_MTU="${TUN_MTU_INPUT:-$DEFAULT_TUN_MTU}"

# — — — — — — — — продвинутые настройки (раскомментируйте, чтобы override) — — — — — — — —
#LISTEN="127.0.0.1:9000"
#FINGERPRINT="firefox"             # firefox|chrome|edge|safari|opera — эмиссия JA3/JA4 TLS-клиента
#CLIENT_IDS=""                     # id сессий через запятую (для auto_js не нужно)
#OBFS="wrap"                       # wrap|none — обфускация UDP пакетов
#TURN_TRANSPORT="udp"              # udp|tls — транспорт к TURN-релеям
#CAPTCHA_MODE="auto"               # auto|manual|skip
EOF
  chmod 600 "$CONF"
  log "slim-конфиг записан в $CONF"

  # device_id — отдельным файлом
  DID="$CSQTT_DIR/device_id"
  printf '%s' "$DEVICE_ID" > "$DID"
  chmod 600 "$DID"
  log "device_id записан в $DID"
}

# ────────────────────────── ОБЁРТКА csqtt-run.sh ──────────────────────

write_run_wrapper() {
  RUN="$CSQTT_DIR/csqtt-run.sh"
  cat > "$RUN" <<'EOF_RUN'
#!/bin/sh
# csqtt-run.sh — обёртка запуска csqtt-client.
# Источник csqtt.conf (slim) → собирает CLI → подаёт VK_JS_BOOTSTRAP в stdin.
set -u

CONF_DIR="${CSQTT_CONF_DIR:-$(dirname "$0")}"
. "$CONF_DIR/csqtt.conf"

# device_id: из файла если есть, иначе из DEVICE_ID в конфиге (legacy)
DEVICE_ID_VAL=""
if [ -s "$CONF_DIR/device_id" ]; then
  DEVICE_ID_VAL=$(cat "$CONF_DIR/device_id" | tr -d '\n')
elif [ -n "${DEVICE_ID:-}" ]; then
  DEVICE_ID_VAL="$DEVICE_ID"
fi
[ -z "$DEVICE_ID_VAL" ] && DEVICE_ID_VAL="router-unknown"

# дефолты продвинутых настроек
LISTEN_D="${LISTEN:-127.0.0.1:9000}"
FINGERPRINT_D="${FINGERPRINT:-firefox}"
CLIENT_IDS_D="${CLIENT_IDS:-}"
OBFS_D="${OBFS:-wrap}"
TURN_TRANSPORT_D="${TURN_TRANSPORT:-udp}"
CAPTCHA_MODE_D="${CAPTCHA_MODE:-auto}"

CLI_ARGS="--peer $PEER"
CLI_ARGS="$CLI_ARGS --password $PASSWORD"
CLI_ARGS="$CLI_ARGS --vk-hash-mode auto_js --vk-auth-mode auto_js"
CLI_ARGS="$CLI_ARGS --allow-hash-redistribution"
CLI_ARGS="$CLI_ARGS --device-id $DEVICE_ID_VAL"
CLI_ARGS="$CLI_ARGS -n $WORKERS"
CLI_ARGS="$CLI_ARGS --hashes $HASHES"
CLI_ARGS="$CLI_ARGS --listen $LISTEN_D"
CLI_ARGS="$CLI_ARGS --fingerprint $FINGERPRINT_D"
CLI_ARGS="$CLI_ARGS --obfs $OBFS_D"
CLI_ARGS="$CLI_ARGS --turn-transport $TURN_TRANSPORT_D"
CLI_ARGS="$CLI_ARGS --captcha-mode $CAPTCHA_MODE_D"
[ -n "$CLIENT_IDS_D" ] && CLI_ARGS="$CLI_ARGS --client-ids $CLIENT_IDS_D"
[ -n "$TUN_IFACE" ] && CLI_ARGS="$CLI_ARGS --tun-iface $TUN_IFACE"
[ -n "$TUN_MTU" ] && CLI_ARGS="$CLI_ARGS --tun-mtu $TUN_MTU"

# VK-токен — в stdin как VK_JS_BOOTSTRAP:base64(json). Клиент ждёт 15 сек, иначе тайм-аут.
TOKEN_FILE="$CONF_DIR/vk_token"
BOOTSTRAP=""
if [ -s "$TOKEN_FILE" ]; then
  _TK=$(cat "$TOKEN_FILE")
  # printf '{"token":"%s"}' "$_TK" | base64 -w0 2>/dev/null || printf '{"token":"%s"}' "$_TK" | base64 | tr -d '\n'
  # busybox base64 не знает -w0, используем tr -d '\n'
  if have_b64=$(command -v base64); then
    BOOTSTRAP=$(printf '{"token":"%s"}' "$_TK" | base64 | tr -d '\n')
  fi
fi

# Стоп-файлы для watchdog
RUN_DIR="$CONF_DIR"
[ -e "$RUN_DIR/stopped" ] && rm -f "$RUN_DIR/stopped"

# Запуск с логированием в csqtt.log (watchdog режет ≤1 МБ без подмены файла).
LOG_FILE="$CONF_DIR/csqtt.log"
{
  if [ -n "$BOOTSTRAP" ]; then
    printf 'VK_JS_BOOTSTRAP:%s\n' "$BOOTSTRAP"
  fi
} | "$CONF_DIR/csqtt-client" $CLI_ARGS >> "$LOG_FILE" 2>&1
EOF_RUN
  chmod +x "$RUN"
  log "обёртка csqtt-run.sh записана в $RUN"
}

# ────────────────────────── INIT-СЕРВИС ─────────────────────────────

write_init_service() {
  if [ "$IS_OPENWRT" -eq 1 ]; then
    write_procd_init
  else
    write_entware_init
  fi
}

write_procd_init() {
  cat > "$INIT_SCRIPT" <<'EOF_INIT'
#!/bin/sh /etc/rc.common
# procd init для OpenWrt 25 / Airoha AN7581
START=99
USE_PROCD=1

CSQTT_DIR=/etc/csqtt

start_service() {
  procd_open_instance
  procd_set_param command "$CSQTT_DIR/csqtt-run.sh"
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_set_param pidfile /var/run/csqtt.pid
  procd_set_param respawn 3600 5 10   # restart if died after 1h, 5 sec threshold, max 10 retries
  procd_set_param limits nproc=4096 nofile=65535
  procd_set_param env CSQTT_CONF_DIR="$CSQTT_DIR"
  procd_close_instance
}

stop_service() {
  rm -f "$CSQTT_DIR/restarting"
  rm -f "$CSQTT_DIR/stopped"
}

reload_service() {
  restart "$@"
}

EOF_INIT
  chmod +x "$INIT_SCRIPT"
  # включаем сервис в автозагрузку
  if have_cmd rc-update 2>/dev/null; then
    rc-update add csqtt 2>/dev/null || true
  elif [ -x /etc/init.d/csqtt ] && have_cmd /etc/init.d/csqtt 2>/dev/null; then
    /etc/init.d/csqtt enable 2>/dev/null || true
  fi
  log "procd-init записан в $INIT_SCRIPT"
}

write_entware_init() {
  cat > "$INIT_SCRIPT" <<'EOF_INIT'
#!/bin/sh
# S99csqtt init для Entware / Keenetic
DAEMON=/opt/etc/csqtt/csqtt-run.sh
PIDFILE=/var/run/csqtt.pid
CSQTT_DIR=/opt/etc/csqtt

start() {
  rm -f "$CSQTT_DIR/stopped" "$CSQTT_DIR/restarting"
  echo "Starting csqtt..."
  start-stop-daemon -S -b -m -p "$PIDFILE" -x "$DAEMON" || return 1
}

stop() {
  echo "Stopping csqtt..."
  touch "$CSQTT_DIR/stopped"
  start-stop-daemon -K -p "$PIDFILE" -s INT 2>/dev/null || \
    start-stop-daemon -K -p "$PIDFILE" -s TERM 2>/dev/null || true
  rm -f "$PIDFILE"
}

status() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat $PIDFILE)" 2>/dev/null; then
    echo "csqtt is running (pid $(cat $PIDFILE))"
    return 0
  else
    echo "csqtt is stopped"
    return 3
  fi
}

log() {
  tail -n 100 "$CSQTT_DIR/csqtt.log" 2>/dev/null
}

case "$1" in
  start)   start ;;
  stop)    stop ;;
  restart) stop; sleep 1; start ;;
  status)  status ;;
  log)     log ;;
  *) echo "Usage: $0 {start|stop|restart|status|log}"; exit 1 ;;
esac
EOF_INIT
  chmod +x "$INIT_SCRIPT"
  log "Entware-init записан в $INIT_SCRIPT"
}

# ────────────────────────── РОТАЦИЯ ХЕШЕЙ ────────────────────────────

write_rotate_script() {
  ROT="$CSQTT_DIR/csqtt-rotate-hashes.sh"
  cat > "$ROT" <<'EOF_ROT'
#!/bin/sh
# csqtt-rotate-hashes.sh — суточная ротация хешей пула vk_pool.
# Окно: 09:30–15:10. Раз в сутки, в случайную минуту окна, один хеш пула заменяется
# свежим (новый VK-звонок), клиент перезапускается (~10–15 с простоя), старый звонок
# корректно завершается (--vk-drop-call).
# Вызывается cron'ом каждые 5 минут. Аргумент 'force' — немедленная ротация.
set -u

CONF_DIR="${CSQTT_CONF_DIR:-$(dirname "$0")}"
[ -r "$CONF_DIR/csqtt.conf" ] && . "$CONF_DIR/csqtt.conf"
STATE="$CONF_DIR/rotate.state"
LOG="$CONF_DIR/rotate.log"
POOL="$CONF_DIR/vk_pool"
TOKEN_FILE="$CONF_DIR/vk_token"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

# пермутация: новая случайная перестановка 1..N
gen_perm() {
  N=$1
  out=""
  remaining=""
  i=1
  while [ "$i" -le "$N" ]; do remaining="$remaining $i"; i=$((i+1)); done
  while [ -n "$remaining" ]; do
    # выбираем случайный элемент
    cnt=$(echo "$remaining" | wc -w)
    rnd=$(head -c2 /dev/urandom | od -An -tu2 | tr -d ' \n')
    idx=$((rnd % cnt + 1))
    picked=$(echo "$remaining" | cut -d' ' -f$idx)
    out="$out $picked"
    # удаляем picked из remaining
    remaining=$(echo "$remaining" | sed "s/ $picked / /; s/^$picked //; s/ $picked$//; s/^$picked$//")
    remaining=$(echo "$remaining" | tr -s ' ' | sed 's/^ //;s/ $//')
  done
  echo "$out" | tr -s ' ' ' ' | sed 's/^ //;s/ $//'
}

# перевод даты → "today" в формате YYYY-MM-DD
today() { date '+%Y-%m-%d'; }
now_minute_of_day() {
  # сколько минут с 00:00
  _h=$(date '+%H'); _m=$(date '+%M')
  echo $((_h * 60 + _m))
}

# нужно ли сегодня ротировать?
should_rotate_today() {
  # сравниваем дату из state с today
  [ -f "$STATE" ] || return 0  # первый запуск — нужно
  _sd=$(grep -E '^date=' "$STATE" | head -1 | cut -d= -f2)
  _td=$(today)
  [ "$_sd" != "$_td" ]
}

# в окне ли мы?
in_window() {
  _n=$(now_minute_of_day)
  [ "$_n" -ge $((9*60+30)) ] && [ "$_n" -le $((15*60+10)) ]
}

# пришло ли время (минута дня == случайной минуте из state)
is_time_for_today() {
  _n=$(now_minute_of_day)
  _r=$(grep -E '^minute=' "$STATE" | head -1 | cut -d= -f2)
  [ -n "$_r" ] && [ "$_n" -ge "$_r" ] && grep -qE '^done=0$' "$STATE" 2>/dev/null
}

# следующая позиция в пермутации для ротации
next_pos() {
  _idx=$(grep -E '^next=' "$STATE" | head -1 | cut -d= -f2)
  [ -z "$_idx" ] && _idx=1
  _perm=$(grep -E '^perm=' "$STATE" | head -1 | cut -d= -f2)
  _len=$(echo "$_perm" | wc -w)
  _pos=$(echo "$_perm" | cut -d' ' -f"$_idx")
  echo "$_pos"
  # в случае успешной ротации увеличим next
  if [ "$_idx" -ge "$_len" ]; then
    # перестановка исчерпана — пометим что нужна новая
    sed -i 's/^next=.*/next=0/' "$STATE" 2>/dev/null
  else
    sed -i "s/^next=.*/next=$((_idx+1))/" "$STATE" 2>/dev/null
  fi
}

# ротируем один хеш из пула
rotate_one_hash() {
  [ -s "$POOL" ] || { log "pool пустой — нечего ротировать"; return 1; }
  _pos=$(echo "$(gen_perm_active_pos)" | head -1)
  # берём строку пула по позиции _pos
  _line=$(sed -n "${_pos}p" "$POOL")
  _hash=$(echo "$_line" | cut -d: -f1)
  _cid=$(echo "$_line" | cut -d: -f2)
  log "ротируем позицию $_pos: hash=$_hash cid=$_cid"

  # закрываем старый звонок VK (--vk-drop-call), если есть id
  if [ -n "$_cid" ] && [ -s "$TOKEN_FILE" ]; then
    _TK=$(cat "$TOKEN_FILE")
    _BS=$(printf '{"token":"%s"}' "$_TK" | base64 | tr -d '\n')
    printf 'VK_JS_BOOTSTRAP:%s\n' "$_BS" | "$CONF_DIR/csqtt-client" --vk-drop-call "$_cid" >> "$LOG" 2>&1 || \
      log "warning: vk-drop-call для $_cid завершился не-нулём"
  fi

  # ставим флаг restarting — watchdog не вмешивается
  touch "$CONF_DIR/restarting"
  # перезапуск службы
  if [ -x /opt/etc/init.d/S99csqtt ]; then
    /opt/etc/init.d/S99csqtt restart >> "$LOG" 2>&1 || true
  elif have_cmd service 2>/dev/null; then
    service csqtt restart >> "$LOG" 2>&1 || true
  fi
  rm -f "$CONF_DIR/restarting"

  # помечаем done на сегодня
  sed -i 's/^done=.*/done=1/' "$STATE" 2>/dev/null
  log "ротация завершена, клиент перезапущен"
}

gen_perm_active_pos() {
  # возвращает 1..HASHES позицию для следующей ротации
  _idx=$(grep -E '^next=' "$STATE" | head -1 | cut -d= -f2)
  [ -z "$_idx" ] && _idx=1
  _perm=$(grep -E '^perm=' "$STATE" | head -1 | cut -d= -f2)
  if [ -z "$_perm" ]; then
    # нет пермутации — берём позицию по idx
    echo "$_idx"
  else
    echo "$_perm" | cut -d' ' -f"$_idx"
  fi
}

# инициализация state на новый день
init_today_state() {
  _H=${HASHES:-4}
  _perm=$(gen_perm "$_H")
  # случайная минута в окне 09:30–15:10 = 570..910
  rnd=$(head -c2 /dev/urandom | od -An -tu2 | tr -d ' \n')
  _min=$((rnd % (910-570+1) + 570))
  cat > "$STATE" <<EOF
date=$(today)
minute=$_min
perm=$_perm
next=1
done=0
EOF
  log "новый план: perm='$_perm', minute=$_min"
}

# ТЕЛО
[ "$1" = "force" ] && { log "force-ротация"; rotate_one_hash; exit 0; }

if ! should_rotate_today; then
  # тот же день — проверяем время
  if grep -qE '^done=1$' "$STATE" 2>/dev/null; then
    exit 0  # сегодня уже ротировали
  fi
  if ! in_window; then exit 0; fi
  if ! is_time_for_today; then exit 0; fi
  rotate_one_hash
  exit 0
fi

# новый день
init_today_state
# если время уже прошло — нужно ли сразу ротировать сегодня?
_n=$(now_minute_of_day)
_r=$(grep -E '^minute=' "$STATE" | head -1 | cut -d= -f2)
if [ "$_n" -ge "$_r" ] && in_window; then
  rotate_one_hash
fi
EOF_ROT
  chmod +x "$ROT"
  log "скрипт ротации записан в $ROT"
}

# ────────────────────────── WATCHDOG ────────────────────────────────

write_watchdog_script() {
  WDG="$CSQTT_DIR/csqtt-watchdog.sh"
  cat > "$WDG" <<'EOF_WDG'
#!/bin/sh
# csqtt-watchdog.sh — проверка здоровья службы.
# 1) процесс запущен (по pid-файлу или pgrep),
# 2) TUN-интерфейс UP (если TUN_IFACE задан),
# 3) пинг через туннель проходит (если TUN_IFACE задан).
# Любой сбой → restart. Уважает флаги stopped / restarting.
# Cron каждые 2 минуты.
set -u

CONF_DIR="${CSQTT_CONF_DIR:-$(dirname "$0")}"
[ -r "$CONF_DIR/csqtt.conf" ] && . "$CONF_DIR/csqtt.conf"
LOG="$CONF_DIR/watchdog.log"
PING_HOST="${WATCHDOG_PING:-77.88.8.8}"
LOG_MAX_BYTES=$((1024 * 1024))
LOG_TAIL_LINES=500

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

# — ограничение лога клиента ≤1 МБ (truncate в том же inode — без подмены файла) —
trim_client_log() {
  _lf="$CONF_DIR/csqtt.log"
  [ -f "$_lf" ] || return 0
  _sz=$(wc -c < "$_lf" 2>/dev/null || echo 0)
  [ "$_sz" -lt "$LOG_MAX_BYTES" ] && return 0
  # оставляем последние 500 строк, копируем во временный (не тот же inode!), потом через cp + truncate
  _tmp=$(mktemp 2>/dev/null || echo /tmp/.csqtt.log.tmp)
  tail -n "$LOG_TAIL_LINES" "$_lf" > "$_tmp" 2>/dev/null
  # пишем truncated контент в ОРИГИНАЛЬНЫЙ файл (тот же inode)
  _newsz=$(wc -c < "$_tmp")
  : > "$_lf"
  cat "$_tmp" >> "$_lf"
  rm -f "$_tmp"
  log "csqtt.log обрезан до $LOG_TAIL_LINES строк ($_newsz байт)"
}

# — проверки —
check_process() {
  # OpenWrt procd: /var/run/csqtt.pid ; Entware: /var/run/csqtt.pid
  if [ -f /var/run/csqtt.pid ]; then
    _pid=$(cat /var/run/csqtt.pid 2>/dev/null)
    if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
      return 0
    fi
  fi
  # фолбэк: pgrep
  if have_cmd pgrep; then
    pgrep -f 'csqtt-client' >/dev/null 2>&1 && return 0
  fi
  # фолбэк2: ps | grep
  ps w 2>/dev/null | grep -v grep | grep -q 'csqtt-client' && return 0
  return 1
}

check_tun_up() {
  [ -n "${TUN_IFACE:-}" ] || return 0   # UDP-режим — TUN не нужен
  # проверяем что интерфейс существует и UP
  if have_cmd ip; then
    ip -o link show "$TUN_IFACE" 2>/dev/null | grep -q 'state UP\|UP,' && return 0
  fi
  if [ -e /sys/class/net/"$TUN_IFACE"/operstate ]; then
    _st=$(cat /sys/class/net/"$TUN_IFACE"/operstate 2>/dev/null)
    [ "$_st" = "up" ] && return 0
  fi
  if have_cmd ifconfig; then
    ifconfig "$TUN_IFACE" 2>/dev/null | grep -q 'UP' && return 0
  fi
  return 1
}

check_ping() {
  [ -n "${TUN_IFACE:-}" ] || return 0   # UDP-режим — не проверяем
  # пинг через TUN_IFACE
  if have_cmd ping; then
    # busybox ping vs iputils — пробуем по очереди
    ping -I "$TUN_IFACE" -c 1 -W 3 "$PING_HOST" >/dev/null 2>&1 && return 0
    ping -I "$TUN_IFACE" -c 1 -W 3 "$PING_HOST" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# — рестарт службы —
restart_service() {
  if [ -x /opt/etc/init.d/S99csqtt ]; then
    touch "$CONF_DIR/restarting"
    /opt/etc/init.d/S99csqtt restart >> "$LOG" 2>&1 || true
    rm -f "$CONF_DIR/restarting"
  elif have_cmd service 2>/dev/null; then
    touch "$CONF_DIR/restarting"
    service csqtt restart >> "$LOG" 2>&1 || true
    rm -f "$CONF_DIR/restarting"
  fi
}

# — тело —
[ -e "$CONF_DIR/stopped" ] && { log "skip: stopped-флаг — служба остановлена вручную"; exit 0; }
[ -e "$CONF_DIR/restarting" ] && { log "skip: restarting-флаг — идёт рестарт"; exit 0; }

trim_client_log

_reason=""
if ! check_process; then _reason="процесс не запущен"; fi
if [ -z "$_reason" ] && ! check_tun_up; then _reason="TUN $TUN_IFACE не UP"; fi
if [ -z "$_reason" ] && ! check_ping; then _reason="пинг через $TUN_IFACE на $PING_HOST не проходит"; fi

if [ -n "$_reason" ]; then
  log "сбой: $_reason — рестарт службы"
  restart_service
  exit 0
fi
EOF_WDG
  chmod +x "$WDG"
  log "watchdog записан в $WDG"
}

# ────────────────────────── UNINSTALL ────────────────────────────────

write_uninstall_script() {
  UNINST="$BIN_DIR/csqtt-uninstall"
  cat > "$UNINST" <<'EOF_UN'
#!/bin/sh
# csqtt-uninstall — полное удаление csqtt с роутера.
# Останавливает службу, чистит cron-строки, init-скрипт, pid-файл, каталог установки.
# Конфиг mihomo НЕ трогается (config.yaml.csqtt-bak восстанавливается отдельно).

set -u
CSQTT_DIR=/etc/csqtt
INIT_SCRIPT=/etc/init.d/csqtt
[ -d /opt/etc/init.d ] && [ -e /opt/etc/opkg.conf ] && {
  CSQTT_DIR=/opt/etc/csqtt
  INIT_SCRIPT=/opt/etc/init.d/S99csqtt
}

echo "Останавливаю службу..."
if [ -x "$INIT_SCRIPT" ]; then
  "$INIT_SCRIPT" stop 2>/dev/null || true
fi
if [ -x "$INIT_SCRIPT" ]; then
  rm -f "$INIT_SCRIPT"
fi
rm -f /var/run/csqtt.pid

echo "Чищу crontab..."
if [ -d /etc/cron.d ]; then
  rm -f /etc/cron.d/csqtt-rotate /etc/cron.d/csqtt-watchdog
fi
# фолбэк — user crontab
if have_cmd crontab; then
  crontab -l 2>/dev/null | grep -v 'csqtt-rotate-hashes\|csqtt-watchdog' | crontab - 2>/dev/null || true
fi

echo "Удаляю каталог установки $CSQTT_DIR..."
[ -d "$CSQTT_DIR" ] && rm -rf "$CSQTT_DIR"

echo "Удаляю csqtt-uninstall (само-удаляющийся шаг)..."
rm -f "$0"

echo "Готово. VK-звонки пула закроет сам VK по таймауту (id потеряны с vk_pool)."
echo "Конфиг mihomo (если ставился через --mihomo-conf) НЕ удалён — он принадлежит mihomo."
EOF_UN
  chmod +x "$UNINST"
  log "uninstaller записан в $UNINST"
}

# ────────────────────────── MIHOMO CONF ───────────────────────────────

maybe_mihomo_conf() {
  [ "$NO_MIHOMO_ASK" -eq 1 ] && return 0
  # дефолтный путь mihomo
  if [ "$IS_OPENWRT" -eq 1 ]; then
    MIHOMO_CONF_PATH=/etc/mihomo/config.yaml
  else
    MIHOMO_CONF_PATH=/opt/etc/mihomo/config.yaml
  fi
  # спрашиваем, если интерактив
  _ans=""
  if [ -z "$MIHOMO_CONF_URL" ]; then
    if [ -t 0 ] || [ -t 1 ]; then
      printf 'Скачать config.yaml для mihomo из репозитория %s (ветка %s)? 1) да 2) пропустить [1]: ' "$REPO" "$MIHOMO_CONF_DEFAULT_BRANCH" >&2
      read -r _a
      _ans=${_a:-1}
    else
      return 0  # не интерактивно и не задан URL — пропускаем
    fi
  else
    _ans=1
  fi
  case "$_ans" in
    1) : ;;
    *) log "mihomo-conf: пропущен пользователем"; return 0 ;;
  esac

  URL="${MIHOMO_CONF_URL:-https://raw.githubusercontent.com/${REPO}/${MIHOMO_CONF_DEFAULT_BRANCH}/${MIHOMO_CONF_FILENAME}}"

  # каталог mihomo может не существовать — это норма для свежей системы
  _mdir=$(dirname "$MIHOMO_CONF_PATH")
  mkdir -p "$_mdir" 2>/dev/null || true

  TMP="$CSQTT_DIR/.mihomo-config.yaml.download"
  log "скачиваем mihomo config.yaml: $URL"
  if [ "$DOWNLOAD_TOOL" = "curl" ]; then
    curl -fsSL -o "$TMP" "$URL" 2>/dev/null || { warn "не удалось скачать mihomo-conf (сеть или 404) — пропускаем"; return 0; }
  else
    wget -qO "$TMP" "$URL" 2>/dev/null || { warn "не удалось скачать mihomo-conf (сеть или 404) — пропускаем"; return 0; }
  fi

  # атомарно: бэкап старого (если есть), tmp+mv в новое место
  if [ -f "$MIHOMO_CONF_PATH" ]; then
    cp -p "$MIHOMO_CONF_PATH" "$MIHOMO_CONF_PATH.csqtt-bak" 2>/dev/null || true
  fi
  mv "$TMP" "$MIHOMO_CONF_PATH"
  log "mihomo config.yaml установлен в $MIHOMO_CONF_PATH (бэкап: $MIHOMO_CONF_PATH.csqtt-bak)"
  warn "перезапустите mihomo/clash, чтобы новый конфиг применился."
}

# ────────────────────────── CRON ──────────────────────────────────────

install_cron_entries() {
  # Каждые 5 минут — ротация
  # Каждые 2 минуты — watchdog
  # Стратегия 1: /etc/cron.d/ (OpenWrt, Entware cron.d)
  # Стратегия 2: user crontab (если нет cron.d)
  if [ -d "$CRON_DIR" ]; then
    cat > "$CRON_DIR/csqtt-rotate" <<EOF
*/5 * * * * root $CSQTT_DIR/csqtt-rotate-hashes.sh >> $CSQTT_DIR/rotate.log 2>&1
EOF
    cat > "$CRON_DIR/csqtt-watchdog" <<EOF
*/2 * * * * root $CSQTT_DIR/csqtt-watchdog.sh >> $CSQTT_DIR/watchdog.log 2>&1
EOF
    log "cron.d-задачи поставлены в $CRON_DIR"
    # перезапуск crond если он есть
    if have_cmd /etc/init.d/cron; then
      /etc/init.d/cron restart 2>/dev/null || /etc/init.d/crond restart 2>/dev/null || true
    elif have_cmd service; then
      service cron restart 2>/dev/null || service crond restart 2>/dev/null || true
    fi
    return 0
  fi

  # фолбэк — user crontab root
  if have_cmd crontab; then
    _ct=$(crontab -l 2>/dev/null | grep -v 'csqtt-rotate-hashes\|csqtt-watchdog')
    _new=$_ct"
*/5 * * * * $CSQTT_DIR/csqtt-rotate-hashes.sh >> $CSQTT_DIR/rotate.log 2>&1
*/2 * * * * $CSQTT_DIR/csqtt-watchdog.sh >> $CSQTT_DIR/watchdog.log 2>&1"
    printf '%s\n' "$_new" | crontab - 2>/dev/null || warn "не удалось поставить crontab"
    log "crontab-задачи поставлены в user crontab"
    return 0
  fi

  warn "не найдено ни cron.d, ни crontab — ротация и watchdog НЕ установлены. Поставьте cron вручную."
}

# ────────────────────────── СТАРТ И ПРОВЕРКА ─────────────────────────

start_and_verify() {
  [ "$NO_START" -eq 1 ] && { log "--no-start — службу не запускаем"; return 0; }
  if [ "$IS_OPENWRT" -eq 1 ]; then
    /etc/init.d/csqtt start 2>/dev/null || service csqtt start 2>/dev/null || true
  else
    /opt/etc/init.d/S99csqtt start 2>/dev/null || true
  fi
  log "служба запущена. Проверяю лог..."
  sleep 5
  # проверяем последние строки лога на наличие метки «Звонок создан» или «Tunnel IP»
  if [ -f "$CSQTT_DIR/csqtt.log" ]; then
    _t=$(tail -n 30 "$CSQTT_DIR/csqtt.log" 2>/dev/null)
    if echo "$_t" | grep -q 'Звонок создан\|Tunnel IP\|csqtt0\|КЛИЕНТ.*Воркеров'; then
      log "✓ в логе найдена метка успешного старта"
    else
      warn "служба стартовала, но в логе нет явной метки «Звонок создан». Подождите ещё минуту и проверьте вручную: tail -n 50 $CSQTT_DIR/csqtt.log"
    fi
  fi
}

# ────────────────────────── USAGE ─────────────────────────────────────

usage() {
  cat <<EOF
Использование:
  sh $0 [CSQTT_URL] [options]

Обязательный аргумент:
  CSQTT_URL            csqtt://connect?... ссылка (содержит peer/password/hashes)
                       если не указана — спрошу интерактивно

Опции:
  --repo REPO           GitHub репозиторий (default: $DEFAULT_REPO)
  --tag TAG             тег релиза (default: $DEFAULT_TAG)
  --local-bin PATH      использовать локальный бинарник вместо GitHub-релиза
  --vk-token TOKEN      вечный VK access token (иначе спрошу интерактивно)
  --hashes N            число хешей пула 1–6 (default: $DEFAULT_HASHES)
  --workers N           число воркеров 9–162 (default: max=HASHES×27)
  --tun-iface NAME      имя TUN-интерфейса (default: $DEFAULT_TUN_IFACE; пусто = UDP-режим 127.0.0.1:9000)
  --tun-mtu N           MTU TUN-интерфейса (default: $DEFAULT_TUN_MTU)
  --fingerprint NAME    firefox|chrome|edge|safari|opera (default: firefox)
  --mode MODE           только auto_js в этом билде
  --no-start            не запускать службу после установки
  --no-rotate           не ставить cron-задачу ротации
  --no-watchdog         не ставить cron-задачу watchdog
  --no-mihomo           не спрашивать про скачивание config.yaml для mihomo
  --mihomo-conf         скачать config.yaml для mihomo из --repo main (по умолчанию)
  --mihomo-conf-url U   свой URL config.yaml для mihomo
  -h, --help            это сообщение

Примеры:
  sh $0 'csqtt://connect?peer=2.27.16.91:46000&password=...'
  sh $0 'csqtt://connect?...' --repo я/csqtt-router --vk-token vk1.a.abc --hashes 4 --workers 108
  sh $0 'csqtt://connect?...' --local-bin /tmp/csqtt-client-aarch64-...

Совместимость по архитектуре:
  aarch64 (uname -m) → Airoha AN7581 / MediaTek MT7981 (OpenWrt 25, Keenetic)
  mips / mipsel      → MediaTek MT7621 (Keenetic, OpenWrt)

Сборка: $SCRIPT_VERSION (кумулятивно: 0636 + 1341 + 1946 + 2350 + 0200)
EOF
}

# ────────────────────────── ARGC / ARGV ────────────────────────────────

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --repo)         REPO="$2"; shift 2 ;;
      --tag)          TAG="$2"; shift 2 ;;
      --local-bin)    LOCAL_BIN="$2"; LOCAL_BIN_FORCED=1; shift 2 ;;
      --vk-token)     VK_TOKEN="$2"; shift 2 ;;
      --hashes)       HASHES_INPUT="$2"; shift 2 ;;
      --workers)      WORKERS_INPUT="$2"; shift 2 ;;
      --tun-iface)    TUN_IFACE_INPUT="$2"; shift 2 ;;
      --tun-mtu)      TUN_MTU_INPUT="$2"; shift 2 ;;
      --fingerprint)  FINGERPRINT_INPUT="$2"; shift 2 ;;
      --mode)         MODE="$2"; shift 2 ;;
      --no-start)     NO_START=1; shift ;;
      --no-rotate)    NO_ROTATE=1; shift ;;
      --no-watchdog)  NO_WATCHDOG=1; shift ;;
      --no-mihomo)    NO_MIHOMO_ASK=1; shift ;;
      --mihomo-conf)  MIHOMO_CONF_URL="${MIHOMO_CONF_URL:-__default__}"; shift ;;
      --mihomo-conf-url) MIHOMO_CONF_URL="$2"; shift 2 ;;
      csqtt://*)      CSQTT_URL="$1"; shift ;;
      -*)             die "неизвестный флаг: $1 (см. --help)" ;;
      *)
        if [ -z "$CSQTT_URL" ]; then
          CSQTT_URL="$1"
          shift
        else
          die "лишний аргумент: $1"
        fi
        ;;
    esac
  done

  if [ -z "$CSQTT_URL" ]; then
    if [ -t 0 ] || [ -t 1 ]; then
      printf 'Вставьте ссылку подключения csqtt://connect?...:\n> ' >&2
      read -r CSQTT_URL
      [ -n "$CSQTT_URL" ] || die "ссылка не указана"
    else
      usage >&2
      die "ссылка csqtt:// не указана. Запустите интерактивно или передайте первым аргументом."
    fi
  fi
}

# ────────────────────────── MAIN ────────────────────────────────────────

main() {
  parse_args "$@"
  log "=== CSQTT install $SCRIPT_VERSION ==="
  detect_platform
  detect_arch
  parse_csqtt_url "$CSQTT_URL"
  ask_hashes_workers

  mkdir -p "$CSQTT_DIR" "$BIN_DIR" 2>/dev/null || true
  chmod 700 "$CSQTT_DIR"

  if [ "$LOCAL_BIN_FORCED" -eq 1 ]; then
    BIN_DST_PATH="$CSQTT_DIR/csqtt-client"
    cp "$LOCAL_BIN" "$BIN_DST_PATH"
    chmod +x "$BIN_DST_PATH"
  else
    fetch_binary
  fi

  verify_binary
  generate_device_id
  ensure_vk_token

  write_slim_config
  write_run_wrapper
  write_init_service
  [ "$NO_ROTATE" -eq 0 ]   && write_rotate_script
  [ "$NO_WATCHDOG" -eq 0 ] && write_watchdog_script
  write_uninstall_script
  [ "$NO_ROTATE" -eq 0 ] || [ "$NO_WATCHDOG" -eq 0 ] || { log "--no-rotate и --no-watchdog: cron не ставится"; }
  if [ "$NO_ROTATE" -eq 0 ] || [ "$NO_WATCHDOG" -eq 0 ]; then
    # если хотя бы один из них включён — ставим только нужные cron-задачи
    # но install_cron_entries ставит обе; частично вынесем фильтр
    install_cron_entries_filtered
  fi

  maybe_mihomo_conf
  start_and_verify

  log "=== установка завершена ==="
  log "конфиг:       $CSQTT_DIR/csqtt.conf"
  log "лог:          $CSQTT_DIR/csqtt.log"
  log "деинсталлятор: $BIN_DIR/csqtt-uninstall"
  if [ "$IS_OPENWRT" -eq 1 ]; then
    log "управление:   service csqtt start|stop|restart"
    log "журнал:       logread | grep csqtt"
  else
    log "управление:   $INIT_SCRIPT start|stop|restart|status|log"
  fi
  log "текущий лог:"
  [ -f "$CSQTT_DIR/csqtt.log" ] && tail -n 10 "$CSQTT_DIR/csqtt.log"
}

# — — — частичный cron-installer (уважает --no-rotate / --no-watchdog) — — —
install_cron_entries_filtered() {
  if [ "$NO_ROTATE" -eq 1 ] && [ "$NO_WATCHDOG" -eq 1 ]; then
    return 0
  fi
  if [ -d "$CRON_DIR" ]; then
    if [ "$NO_ROTATE" -eq 0 ]; then
      cat > "$CRON_DIR/csqtt-rotate" <<EOF
*/5 * * * * root $CSQTT_DIR/csqtt-rotate-hashes.sh >> $CSQTT_DIR/rotate.log 2>&1
EOF
    else
      rm -f "$CRON_DIR/csqtt-rotate" 2>/dev/null
    fi
    if [ "$NO_WATCHDOG" -eq 0 ]; then
      cat > "$CRON_DIR/csqtt-watchdog" <<EOF
*/2 * * * * root $CSQTT_DIR/csqtt-watchdog.sh >> $CSQTT_DIR/watchdog.log 2>&1
EOF
    else
      rm -f "$CRON_DIR/csqtt-watchdog" 2>/dev/null
    fi
    log "cron.d-задачи поставлены в $CRON_DIR"
    if have_cmd /etc/init.d/cron; then
      /etc/init.d/cron restart 2>/dev/null || /etc/init.d/crond restart 2>/dev/null || true
    elif have_cmd service; then
      service cron restart 2>/dev/null || service crond restart 2>/dev/null || true
    fi
    return 0
  fi
  if have_cmd crontab; then
    _ct=$(crontab -l 2>/dev/null | grep -v 'csqtt-rotate-hashes\|csqtt-watchdog')
    _new="$_ct"
    if [ "$NO_ROTATE" -eq 0 ]; then
      _new="$_new
*/5 * * * * $CSQTT_DIR/csqtt-rotate-hashes.sh >> $CSQTT_DIR/rotate.log 2>&1"
    fi
    if [ "$NO_WATCHDOG" -eq 0 ]; then
      _new="$_new
*/2 * * * * $CSQTT_DIR/csqtt-watchdog.sh >> $CSQTT_DIR/watchdog.log 2>&1"
    fi
    printf '%s\n' "$_new" | crontab - 2>/dev/null || warn "не удалось поставить crontab"
    log "crontab-задачи поставлены в user crontab"
  fi
}

main "$@"
