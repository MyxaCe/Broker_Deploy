#!/usr/bin/env bash

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$HERE/.env"
BUS="${BUS_CONTAINER:-broker-local-bus-1}"
VHOST=platform

[ -f "$ENV_FILE" ] || { echo "нет $ENV_FILE — без него паролей взять негде"; exit 1; }

pass_from_url() { sed -E 's#^[a-z]+://[^:]+:([^@]+)@.*$#\1#' <<<"$1"; }
val() { grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2-; }

SITE_WEB_PASS="$(val BUS_PASSWORD)"
CABINET_PASS="$(pass_from_url "$(val CABINET_BUS_URL)")"

ctl() { docker exec "$BUS" rabbitmqctl "$@"; }

echo "=== ПРАВА ДО ==="
ctl list_permissions -p "$VHOST" 2>/dev/null | tail -n +2
echo

for pair in "site-web:$SITE_WEB_PASS" "cabinet:$CABINET_PASS"; do
  user="${pair%%:*}"; pw="${pair#*:}"
  if [ -z "$pw" ]; then echo "ПРОПУЩЕН $user: пароля в .env нет"; continue; fi
  ctl list_users 2>/dev/null | awk '{print $1}' | grep -qx "$user" \
    || ctl add_user "$user" "$pw" >/dev/null
  ctl change_password "$user" "$pw" >/dev/null
  ctl set_user_tags "$user" >/dev/null
done

if ctl list_users 2>/dev/null | awk '{print $1}' | grep -qx bus-admin; then
  ctl set_user_tags bus-admin administrator >/dev/null
  ctl set_permissions -p "$VHOST" bus-admin ".*" ".*" ".*" >/dev/null
else
  echo "НЕ СДЕЛАНО: пользователя bus-admin нет, а пароля для него в .env тоже"
  echo "            нет. Завести вручную: rabbitmqctl add_user bus-admin <пароль>"
fi

ctl set_permissions -p "$VHOST" site-web "" '^platform\.events$' "" >/dev/null

ctl set_permissions -p "$VHOST" cabinet \
  '^cabinet\.terminal-projection$' \
  '^(cabinet\.terminal-projection|platform\.events\.dlx)$' \
  '^(platform\.events|cabinet\.terminal-projection(\.dlq)?)$' >/dev/null

decl() { docker exec "$BUS" rabbitmqadmin -V "$VHOST" "$@" 2>/dev/null; }
if docker exec "$BUS" sh -c 'command -v rabbitmqadmin' >/dev/null 2>&1; then
  decl declare exchange name=platform.events type=topic durable=true
  decl declare exchange name=platform.events.dlx type=topic durable=true
  decl declare queue name=cabinet.terminal-projection.dlq durable=true
  decl declare binding source=platform.events.dlx \
       destination=cabinet.terminal-projection.dlq routing_key='#'
else
  echo "НЕ СДЕЛАНО: rabbitmqadmin в контейнере нет — топология не объявлена."
  echo "            Включить плагин: rabbitmq-plugins enable rabbitmq_management"
fi

echo
echo "=== ПРАВА ПОСЛЕ ==="
ctl list_permissions -p "$VHOST" 2>/dev/null | tail -n +2
echo
echo "=== ТЕГИ ==="
ctl list_users 2>/dev/null | tail -n +2
echo
echo "Проверять права следует ПОПЫТКОЙ, а не этим выводом: список прав"
echo "показывает, что записано, а не что разрешено на самом деле."
