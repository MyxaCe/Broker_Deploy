#!/usr/bin/env bash
# Топология и права шины — в виде кода, а не только в томе.
#
# ЗАЧЕМ. Кредлы, права, обменники и DLQ жили ТОЛЬКО внутри тома
# `broker-local_bus-data`. Том пропал или пересоздан — и RabbitMQ поднимается
# заново с `RABBITMQ_DEFAULT_USER=site-web`, у которого по построению тег
# `administrator` и права `.*` на всё. То есть вся работа BUS-01 и OPS-13
# снимается молча, без единой ошибки в логе: защита, державшаяся на побочном
# свойстве (на том, что том ещё жив), отваливается тихо.
#
# Скрипт идемпотентен: гоняется сколько угодно раз, печатает права ДО и ПОСЛЕ.
#
# Запуск:  bash deploy/local/bus-setup.sh
# Пароли берутся из deploy/local/.env и в вывод НЕ попадают.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$HERE/.env"
BUS="${BUS_CONTAINER:-broker-local-bus-1}"
VHOST=platform

[ -f "$ENV_FILE" ] || { echo "нет $ENV_FILE — без него паролей взять негде"; exit 1; }

# из URL вида amqp://user:pass@host:5672/vhost
pass_from_url() { sed -E 's#^[a-z]+://[^:]+:([^@]+)@.*$#\1#' <<<"$1"; }
val() { grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2-; }

SITE_WEB_PASS="$(val BUS_PASSWORD)"
CABINET_PASS="$(pass_from_url "$(val CABINET_BUS_URL)")"

ctl() { docker exec "$BUS" rabbitmqctl "$@"; }

echo "=== ПРАВА ДО ==="
ctl list_permissions -p "$VHOST" 2>/dev/null | tail -n +2
echo

# --- 1. Кредлы -------------------------------------------------------------
# Теги СНИМАЮТСЯ явно: site-web заводится контейнером и получает
# `administrator` — продюсер, умеющий переписать права самому себе.
for pair in "site-web:$SITE_WEB_PASS" "cabinet:$CABINET_PASS"; do
  user="${pair%%:*}"; pw="${pair#*:}"
  if [ -z "$pw" ]; then echo "ПРОПУЩЕН $user: пароля в .env нет"; continue; fi
  ctl list_users 2>/dev/null | awk '{print $1}' | grep -qx "$user" \
    || ctl add_user "$user" "$pw" >/dev/null
  ctl change_password "$user" "$pw" >/dev/null
  ctl set_user_tags "$user" >/dev/null          # тегов нет — это и есть правка
done

# bus-admin паролем здесь НЕ управляется: его пароля в .env нет, и выдумать
# его значило бы молча сменить рабочий кредл. Пропуск назван вслух, а не скрыт.
if ctl list_users 2>/dev/null | awk '{print $1}' | grep -qx bus-admin; then
  ctl set_user_tags bus-admin administrator >/dev/null
  ctl set_permissions -p "$VHOST" bus-admin ".*" ".*" ".*" >/dev/null
else
  echo "НЕ СДЕЛАНО: пользователя bus-admin нет, а пароля для него в .env тоже"
  echo "            нет. Завести вручную: rabbitmqctl add_user bus-admin <пароль>"
fi

# --- 2. Права --------------------------------------------------------------
# site-web — честный publish-only (OPS-13). configure ПУСТ: релей объявляет
# обменник пассивно (REL-03), а пассивное объявление прав не требует.
ctl set_permissions -p "$VHOST" site-web "" '^platform\.events$' "" >/dev/null

# cabinet — выведено из того, что делает консюмер, а не выдано про запас.
#
# СУЖЕНО 19.10 по решению Р-051. Зеркальный REL-03 сделан (CON-04): консюмер
# объявляет обменник ПАССИВНО (`checkExchange`), а пассивное объявление
# `configure` не требует — значит `platform.events` ушёл из configure.
#
# `cabinet.terminal-projection` в configure ОСТАЁТСЯ, и это решение, а не
# упущение: очередь объявляется активно сознательно, её владелец — сам
# консюмер, и потерянную очередь пересоздать больше некому. Пассивной её
# делать нечему. Р-051; у `site-platform` закреплено тестом-растяжкой.
#
# Остальные поля выведены по одному вызову в subscriber.ts:
#   write cabinet.terminal-projection — `bindQueue` требует write на очередь
#   write platform.events.dlx         — DLX проверяется при queue.declare
#   read  platform.events             — `bindQueue` требует read на обменник
#   read  cabinet.terminal-projection — `consume`
#   read  ...dlq                      — разбор отбракованного руками
ctl set_permissions -p "$VHOST" cabinet \
  '^cabinet\.terminal-projection$' \
  '^(cabinet\.terminal-projection|platform\.events\.dlx)$' \
  '^(platform\.events|cabinet\.terminal-projection(\.dlq)?)$' >/dev/null

# --- 3. Топология ----------------------------------------------------------
# Обменники и DLQ объявляет ВЛАДЕЛЕЦ шины, а не приложения: релей требует
# обменник пассивно и не создаёт его, консюмер только ссылается на DLX
# параметром очереди. Без DLX отбракованные сообщения исчезают молча —
# брокер не считает это ошибкой.
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
