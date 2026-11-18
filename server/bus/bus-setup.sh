#!/usr/bin/env bash
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$HERE/.env"
BUS="${BUS_CONTAINER:-broker-bus}"
VHOST=platform

[ -f "$ENV_FILE" ] || { echo "нет $ENV_FILE — без него паролей взять негде"; exit 1; }

val() { grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2-; }

SITE_WEB_PASS="$(val BUS_SITE_WEB_PASSWORD)"
CABINET_PASS="$(val BUS_CABINET_PASSWORD)"

ctl() { docker exec "$BUS" rabbitmqctl "$@"; }

docker ps --format '{{.Names}}' | grep -qx "$BUS" || {
    echo "контейнер $BUS не запущен — настраивать нечего"; exit 1; }

echo "=== ПРАВА ДО ==="
ctl list_permissions -p "$VHOST" 2>/dev/null | tail -n +2
echo

rc=0
for pair in "site-web:$SITE_WEB_PASS" "cabinet:$CABINET_PASS"; do
    user="${pair%%:*}"; pw="${pair#*:}"
    if [ -z "$pw" ]; then
        echo "НЕ СДЕЛАНО: пароля для $user в .env нет — кредл не заведён"
        rc=1
        continue
    fi
    ctl list_users 2>/dev/null | awk '{print $1}' | grep -qx "$user" \
        || ctl add_user "$user" "$pw" >/dev/null
    ctl change_password "$user" "$pw" >/dev/null
    ctl set_user_tags "$user" >/dev/null
done

ctl set_permissions -p "$VHOST" site-web "" '^platform\.events$' "" >/dev/null

ctl set_permissions -p "$VHOST" cabinet \
    '^cabinet\.terminal-projection$' \
    '^(cabinet\.terminal-projection|platform\.events\.dlx)$' \
    '^(platform\.events|cabinet\.terminal-projection(\.dlq)?)$' >/dev/null

ADMIN_USER="$(val BUS_ADMIN_USER)"
ADMIN_PASS="$(val BUS_ADMIN_PASSWORD)"
decl() { docker exec "$BUS" rabbitmqadmin -V "$VHOST" -u "$ADMIN_USER" -p "$ADMIN_PASS" "$@"; }

if ! docker exec "$BUS" sh -c 'command -v rabbitmqadmin' >/dev/null 2>&1; then
    echo "НЕ СДЕЛАНО: rabbitmqadmin в контейнере нет — топология НЕ объявлена."
    rc=1
elif [ -z "$ADMIN_USER" ] || [ -z "$ADMIN_PASS" ]; then
    echo "НЕ СДЕЛАНО: кредла администратора в .env нет — топология НЕ объявлена."
    rc=1
else
    decl declare exchange name=platform.events type=topic durable=true || rc=1
    decl declare exchange name=platform.events.dlx type=topic durable=true || rc=1
    decl declare queue name=cabinet.terminal-projection.dlq durable=true || rc=1
    decl declare binding source=platform.events.dlx          destination=cabinet.terminal-projection.dlq routing_key='#' || rc=1
fi

for want in platform.events platform.events.dlx; do
    if ctl list_exchanges -p "$VHOST" name 2>/dev/null | awk '{print $1}' | grep -qx "$want"; then
        echo "обменник есть: $want"
    else
        echo "НЕТ ОБМЕННИКА: $want — топология неполна"
        rc=1
    fi
done
if ctl list_queues -p "$VHOST" name 2>/dev/null | awk '{print $1}' | grep -qx cabinet.terminal-projection.dlq; then
    echo "очередь есть: cabinet.terminal-projection.dlq"
else
    echo "НЕТ ОЧЕРЕДИ: cabinet.terminal-projection.dlq — отбракованное исчезало бы молча"
    rc=1
fi

echo
echo "=== ПРАВА ПОСЛЕ ==="
ctl list_permissions -p "$VHOST" 2>/dev/null | tail -n +2
echo
echo "=== ТЕГИ (пусто у кредлов приложений — это и есть цель) ==="
ctl list_users 2>/dev/null | tail -n +2
echo
echo "=== ОБМЕННИКИ ==="
ctl list_exchanges -p "$VHOST" name type durable 2>/dev/null | tail -n +2 | grep -v '^amq\.' | grep -v '^\s'
echo
echo "Проверять права следует ПОПЫТКОЙ, а не этим выводом: список прав"
echo "показывает, что записано, а не что разрешено на самом деле."
exit "$rc"
