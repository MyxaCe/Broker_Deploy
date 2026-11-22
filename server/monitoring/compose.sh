#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROXY_ENV="$HERE/../proxy/.env"
BUS_ENV="$HERE/../bus/.env"
SITE_ENV="$HERE/../site/.env"
TERM_ENV="$HERE/../terminal/.env"
OWN_ENV="$HERE/.env"

BEZ_KAVYCHEK='^[A-Za-z_][A-Za-z0-9_]*=[^"'"'"'#]*[[:space:]]+[^#[:space:]]'

for f in "$PROXY_ENV" "$BUS_ENV" "$SITE_ENV" "$TERM_ENV" "$OWN_ENV"; do
    [ -f "$f" ] || { echo "нет $f — без него подставлять нечего" >&2; exit 1; }
    if grep -nE "$BEZ_KAVYCHEK" "$f" >/dev/null 2>&1; then
        echo "в $f значение с пробелом записано БЕЗ КАВЫЧЕК:" >&2
        grep -nE "$BEZ_KAVYCHEK" "$f" | sed 's/=.*/=<значение скрыто>/' >&2
        echo "  Compose такой файл прочтёт, а source — нет: для shell это команда." >&2
        echo "  Возьмите значение в кавычки: ИМЯ=\"a b\"" >&2
        exit 1
    fi
done

# shellcheck disable=SC1090
{ set -a; . "$PROXY_ENV"; . "$BUS_ENV"; . "$SITE_ENV"; . "$TERM_ENV"; . "$OWN_ENV"; set +a; }

BUS_BASIC="$(printf '%s:%s' "$BUS_ADMIN_USER" "$BUS_ADMIN_PASSWORD" | base64 -w0)"
export BUS_BASIC

mkdir -p "$HERE/rendered"
chmod 755 "$HERE/rendered"
for f in prometheus json-exporter alertmanager; do
    envsubst < "$HERE/conf/$f.yml.shablon" > "$HERE/rendered/$f.yml"
done
chown 65534:65534 "$HERE/rendered/json-exporter.yml" "$HERE/rendered/alertmanager.yml"
chmod 600 "$HERE/rendered/json-exporter.yml" "$HERE/rendered/alertmanager.yml"
chmod 644 "$HERE/rendered/prometheus.yml"

for v in CI_REPO CI_VETKA; do
    eval "z=\${$v:-}"
    [ -n "$z" ] || { echo "в $OWN_ENV нет $v — неизвестно, чей прогон сторожить" >&2; exit 1; }
done

if grep -q '\${' "$HERE/rendered/prometheus.yml" "$HERE/rendered/alertmanager.yml"; then
    echo "в отрендеренных конфигах осталась неподставленная переменная:" >&2
    grep -n '\${' "$HERE/rendered/"*.yml >&2
    exit 1
fi

exec env SITE_DB_PASSWORD="$SITE_DB_PASSWORD" TERMINAL_DB_USER="$TERMINAL_DB_USER" TERMINAL_DB_PASSWORD="$TERMINAL_DB_PASSWORD" TERMINAL_DB_NAME="$TERMINAL_DB_NAME" docker compose --env-file "$OWN_ENV" "$@"
