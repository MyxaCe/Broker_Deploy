# shellcheck shell=bash
# Общие функции скриптов ячеек: загрузка параметров, проверка, вывод шагов,
# сухой прогон. Подключается через `. lib/common.sh`, сам не запускается.

# Git Bash на Windows (локальная проверка) переписывает аргументы вида
# `/path` в `C:/Program Files/Git/path` — docker exec получал бы мусор.
# На Linux переменная ничего не делает.
export MSYS_NO_PATHCONV=1

CELLS_DIR="${CELLS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DRY_RUN="${DRY_RUN:-0}"
JSON_PROGRESS="${JSON_PROGRESS:-0}"

# Имена, которые нельзя занять слагом: это каталоги самого инструмента.
RESERVED_SLUGS="template lib docs test _destroyed apex-ru"

# --- Вывод -------------------------------------------------------------------
if [ -t 1 ]; then
    C_OK=$'\e[32m'; C_ERR=$'\e[31m'; C_DIM=$'\e[2m'; C_B=$'\e[1m'; C_WARN=$'\e[33m'; C_0=$'\e[0m'
else
    C_OK=; C_ERR=; C_DIM=; C_B=; C_WARN=; C_0=
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s      %s%s\n' "$C_DIM" "$*" "$C_0"; }
warn() { printf '%s      ! %s%s\n' "$C_WARN" "$*" "$C_0" >&2; }
die()  { printf '%s  ОШИБКА: %s%s\n' "$C_ERR" "$*" "$C_0" >&2; exit 1; }

# JSON-строка прогресса для будущей «консоли холдинга» (агент читает stdout).
json_line() {
    [ "$JSON_PROGRESS" = 1 ] || return 0
    printf '{"slug":"%s","step":%s,"total":%s,"name":"%s","status":"%s","sec":%s}\n' \
        "${CELL_SLUG:-}" "$1" "$2" "$3" "$4" "${5:-0}" >&2
}

STEP_NO=0
STEP_TOTAL=10
STEP_NAME=""
STEP_T0=0
step() {
    STEP_NO=$((STEP_NO + 1)); STEP_NAME="$1"; STEP_T0=$(date +%s)
    printf '\n%s[%2d/%d] %s%s\n' "$C_B" "$STEP_NO" "$STEP_TOTAL" "$1" "$C_0"
    json_line "$STEP_NO" "$STEP_TOTAL" "$1" running
}
step_ok() {
    local dt=$(( $(date +%s) - STEP_T0 ))
    printf '%s      ✓ %s%s %s(%s с)%s\n' "$C_OK" "${1:-готово}" "$C_0" "$C_DIM" "$dt" "$C_0"
    json_line "$STEP_NO" "$STEP_TOTAL" "$STEP_NAME" ok "$dt"
}
step_skip() {
    printf '%s      – %s%s\n' "$C_DIM" "${1:-пропущено}" "$C_0"
    json_line "$STEP_NO" "$STEP_TOTAL" "$STEP_NAME" skipped 0
}
step_fail() {
    json_line "$STEP_NO" "$STEP_TOTAL" "$STEP_NAME" failed "$(( $(date +%s) - STEP_T0 ))"
    die "$1
         Шаг можно повторить: запустите ту же команду ещё раз — все шаги идемпотентны."
}

# --- Сухой прогон -------------------------------------------------------------
# Всё, что МЕНЯЕТ мир, идёт через `run`. Чтение (проверки) выполняется всегда.
run() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '%s      [dry-run] %s%s\n' "$C_DIM" "$*" "$C_0"
        return 0
    fi
    "$@"
}
# Запись файла: `write_file <path> <mode>` читает содержимое со stdin.
write_file() {
    local path="$1" mode="${2:-644}"
    if [ "$DRY_RUN" = 1 ]; then
        printf '%s      [dry-run] записал бы %s (%s):%s\n' "$C_DIM" "$path" "$mode" "$C_0"
        sed 's/^/                 | /' | sed -E 's/(PASSWORD|SECRET|TOKEN|KEY[A-Z_]*|_B64)=.*/\1=<скрыто>/'
        return 0
    fi
    local tmp; tmp="$(mktemp "${path}.XXXXXX")"
    cat > "$tmp"
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$path"
}

# --- Параметры -----------------------------------------------------------------
load_hub_conf() {
    local f="${CELLS_HUB_CONF:-$CELLS_DIR/hub.conf}"
    [ -f "$f" ] || die "нет $f — параметры хаба неизвестны"
    # shellcheck disable=SC1090
    . "$f"
    : "${EDGE_NET:?}" "${BACK_NET:?}" "${HUB_CMS:?}" "${HUB_MDS:?}" "${HUB_BUS:?}" "${HUB_PROXY:?}"
    : "${HUB_SITE_ENV:?}" "${HUB_BUS_ENV:?}" "${HUB_CMS_ENV:?}" "${PROXY_DIR:?}"
}

valid_slug() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,30}[a-z0-9]$ ]] || return 1
    case " $RESERVED_SLUGS " in *" $1 "*) return 1 ;; esac
    return 0
}

valid_host() {
    [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

# Значение ключа из env-файла, без исполнения файла (значения могут содержать
# что угодно; `source` чужого .env — это исполнение чужого текста).
env_get() {
    local file="$1" key="$2"
    [ -f "$file" ] || return 0
    grep -E "^${key}=" "$file" | tail -1 | cut -d= -f2- | sed -E 's/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/'
}

# Каталог экземпляров ячеек: на хосте = каталог скриптов (/srv/broker/cells),
# локально — отдельный (CELLS_HOME в тестовом hub.conf), чтобы не мусорить в git.
cell_dir() { printf '%s/%s' "${CELLS_HOME:-$CELLS_DIR}" "$1"; }

load_platform_conf() {
    local slug="$1" f
    f="$(cell_dir "$slug")/platform.conf"
    [ -f "$f" ] || return 1
    # platform.conf пишет владелец, это не секрет и не чужой файл; но всё
    # равно читаем ТОЛЬКО известные ключи, а не исполняем файл целиком.
    local k
    for k in BRAND_NAME BRAND_COLOR BRAND_LOGO BRAND_FAVICON SITE_HOST CABINET_HOST \
             TERMINAL_HOST ADMIN_HOST FILES_HOST PROMOTIONS EXCLUDE_CATEGORIES \
             CRYPTO_LEVERAGE PLATFORM_LEVERAGE DEMO_START_BALANCE_CENTS \
             MARGIN_CALL_LEVEL_PERCENT MARGIN_STOP_OUT_LEVEL_PERCENT \
             NEGATIVE_BALANCE_PROTECTION REAL_TRADING_ENABLED EXCHANGE_TRON_ADDRESS \
             ADMIN_LOGIN ADMIN_NAME TEMPLATE_SITE CONTENT_REPLACE; do
        local v; v="$(env_get "$f" "$k")"
        if [ -n "$v" ] || [ -z "${!k:-}" ]; then printf -v "$k" '%s' "$v"; fi
    done
    PLATFORM_CONF_FILE="$f"
    return 0
}

# Проверка анкеты: строгие правила, как у будущего агента консоли (данные, не шелл).
validate_platform_conf() {
    local errs=() h
    [ -n "$BRAND_NAME" ] || errs+=("BRAND_NAME пуст")
    [ "${#BRAND_NAME}" -le 64 ] || errs+=("BRAND_NAME длиннее 64 символов")
    case "$BRAND_NAME" in *'"'*|*'`'*|*'$'*|*'\'*) errs+=("BRAND_NAME: без кавычек, \$, \\ и \`") ;; esac
    [[ "$BRAND_COLOR" =~ ^#[0-9a-fA-F]{6}$ ]] || errs+=("BRAND_COLOR: нужен hex вида #2f6fed")
    for h in SITE_HOST CABINET_HOST TERMINAL_HOST ADMIN_HOST FILES_HOST; do
        valid_host "${!h}" || errs+=("$h: «${!h}» — не доменное имя (строчные буквы, точки)")
    done
    local all; all="$(printf '%s\n' "$SITE_HOST" "$CABINET_HOST" "$TERMINAL_HOST" "$ADMIN_HOST" "$FILES_HOST" | sort | uniq -d)"
    [ -z "$all" ] || errs+=("адреса повторяются: $all")
    case "$PROMOTIONS" in on|off) ;; *) errs+=("PROMOTIONS: on или off") ;; esac
    [[ -z "$CRYPTO_LEVERAGE" || "$CRYPTO_LEVERAGE" =~ ^[1-9][0-9]{0,3}$ ]] || errs+=("CRYPTO_LEVERAGE: целое ≥1")
    [[ "$PLATFORM_LEVERAGE" =~ ^[1-9][0-9]{0,3}$ ]] || errs+=("PLATFORM_LEVERAGE: целое ≥1")
    [[ "$DEMO_START_BALANCE_CENTS" =~ ^[0-9]{1,12}$ ]] || errs+=("DEMO_START_BALANCE_CENTS: целое")
    [[ "$MARGIN_CALL_LEVEL_PERCENT" =~ ^[0-9]{1,4}$ ]] || errs+=("MARGIN_CALL_LEVEL_PERCENT: целое")
    [[ "$MARGIN_STOP_OUT_LEVEL_PERCENT" =~ ^[0-9]{1,4}$ ]] || errs+=("MARGIN_STOP_OUT_LEVEL_PERCENT: целое")
    [[ "$NEGATIVE_BALANCE_PROTECTION" =~ ^[01]$ ]] || errs+=("NEGATIVE_BALANCE_PROTECTION: 0 или 1")
    [[ "$REAL_TRADING_ENABLED" =~ ^[01]$ ]] || errs+=("REAL_TRADING_ENABLED: 0 или 1")
    local c
    for c in $EXCLUDE_CATEGORIES; do [[ "$c" =~ ^[a-z_-]{2,20}$ ]] || errs+=("EXCLUDE_CATEGORIES: «$c»"); done
    if [ -n "$EXCHANGE_TRON_ADDRESS" ]; then
        tron_address_ok "$EXCHANGE_TRON_ADDRESS" || errs+=("EXCHANGE_TRON_ADDRESS: не адрес TRON (base58check) или это контракт USDT")
    fi
    [[ "$ADMIN_LOGIN" =~ ^[a-z0-9._-]{3,32}$ ]] || errs+=("ADMIN_LOGIN: 3–32 символа a-z 0-9 . _ -")
    [ -n "$ADMIN_NAME" ] || ADMIN_NAME="$ADMIN_LOGIN"
    case "$ADMIN_NAME" in *"'"*|*'"'*|*'`'*|*'$'*|*'\'*) errs+=("ADMIN_NAME: без кавычек, \$, \\ и \`") ;; esac
    for f in BRAND_LOGO BRAND_FAVICON; do
        [ -z "${!f}" ] || [ -f "${!f}" ] || errs+=("$f: файла «${!f}» нет")
    done
    if [ "${#errs[@]}" -gt 0 ]; then
        printf '%s  В анкете %s ошибки:%s\n' "$C_ERR" "$PLATFORM_CONF_FILE" "$C_0" >&2
        printf '    - %s\n' "${errs[@]}" >&2
        exit 1
    fi
}

# base58check TRON-адреса + запрет адреса контракта USDT (та же проверка, что
# у chain-watcher: USDT, отправленные на контракт, сгорают).
tron_address_ok() {
    local a="$1"
    [ "$a" != "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t" ] || return 1
    [[ "$a" =~ ^T[1-9A-HJ-NP-Za-km-z]{33}$ ]] || return 1
    py - "$a" <<'PY' 2>/dev/null
import hashlib, sys
A = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
s = sys.argv[1]; n = 0
for ch in s: n = n * 58 + A.index(ch)
b = n.to_bytes(25, 'big')
ok = b[0] == 0x41 and hashlib.sha256(hashlib.sha256(b[:21]).digest()).digest()[:4] == b[21:]
sys.exit(0 if ok else 1)
PY
}

# --- Docker -----------------------------------------------------------------
container_running() { docker ps --format '{{.Names}}' | grep -qx "$1"; }

wait_healthy() { # <container> <секунд>: healthy, а без healthcheck — running
    local c="$1" t="${2:-90}" i=0 st
    while [ $i -lt "$t" ]; do
        st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}-nohc{{end}}' "$c" 2>/dev/null || true)"
        case "$st" in healthy|running-nohc) return 0 ;; esac
        sleep 2; i=$((i + 2))
    done
    return 1
}

# python3 на хосте; в Git Bash (локальная проверка) он называется python.
py() { if command -v python3 >/dev/null 2>&1 && python3 -c 1 >/dev/null 2>&1; then python3 "$@"; else python "$@"; fi; }

# Путь для docker CLI. На Linux — как есть; в Git Bash (локальная проверка)
# `/c/Users/…` превращается в `C:/Users/…`, иначе docker его не поймёт.
hostpath() {
    local p="$1" d b
    if [ -d "$p" ]; then (cd "$p" && { pwd -W 2>/dev/null || pwd; })
    else d="$(dirname "$p")"; b="$(basename "$p")"; printf '%s/%s' "$(cd "$d" && { pwd -W 2>/dev/null || pwd; })" "$b"; fi
}

gen_secret() { openssl rand -hex "${1:-24}"; }
