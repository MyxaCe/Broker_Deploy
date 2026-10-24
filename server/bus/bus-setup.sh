#!/usr/bin/env bash
# Топология и права шины — в виде кода, а не только в томе. Серверная
# редакция `local/bus-setup.sh`; расхождение между ними — сам контейнер и
# источник паролей, разбор прав один и тот же и списан оттуда дословно.
#
# ЗАЧЕМ. Кредлы, права, обменники и DLQ жили бы ТОЛЬКО внутри тома. Том пропал
# или пересоздан — и RabbitMQ поднимается заново с администратором из
# переменной и правами `.*` на всё, БЕЗ ЕДИНОЙ ОШИБКИ В ЛОГЕ. Защита,
# державшаяся на том, что том ещё жив, отваливается молча.
#
# Идемпотентен: гоняется сколько угодно раз, печатает права ДО и ПОСЛЕ.
# Пароли читаются из .env рядом и в вывод НЕ попадают.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$HERE/.env"
BUS="${BUS_CONTAINER:-broker-bus}"
VHOST=platform

[ -f "$ENV_FILE" ] || { echo "нет $ENV_FILE — без него паролей взять негде"; exit 1; }

val() { grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2-; }

SITE_WEB_PASS="$(val BUS_SITE_WEB_PASSWORD)"
CABINET_PASS="$(val BUS_CABINET_PASSWORD)"
TERMINAL_PASS="$(val BUS_TERMINAL_PASSWORD)"

ctl() { docker exec "$BUS" rabbitmqctl "$@"; }

docker ps --format '{{.Names}}' | grep -qx "$BUS" || {
    echo "контейнер $BUS не запущен — настраивать нечего"; exit 1; }

echo "=== ПРАВА ДО ==="
ctl list_permissions -p "$VHOST" 2>/dev/null | tail -n +2
echo

# --- 1. Кредлы -------------------------------------------------------------
# Теги СНИМАЮТСЯ явно. Пользователь, заведённый переменной контейнера,
# получает `administrator` по построению — то есть продюсер, умеющий
# переписать права самому себе. Здесь оба кредла заводятся скриптом, но
# снятие тегов оставлено безусловным: оно обязано пережить любой способ
# появления пользователя.
rc=0
for pair in "site-web:$SITE_WEB_PASS" "cabinet:$CABINET_PASS" "terminal:$TERMINAL_PASS"; do
    user="${pair%%:*}"; pw="${pair#*:}"
    if [ -z "$pw" ]; then
        echo "НЕ СДЕЛАНО: пароля для $user в .env нет — кредл не заведён"
        rc=1
        continue
    fi
    ctl list_users 2>/dev/null | awk '{print $1}' | grep -qx "$user" \
        || ctl add_user "$user" "$pw" >/dev/null
    ctl change_password "$user" "$pw" >/dev/null
    ctl set_user_tags "$user" >/dev/null          # тегов нет — это и есть правка
done

# --- 2. Права --------------------------------------------------------------
# site-web — честный publish-only (OPS-13). configure ПУСТ: релей объявляет
# обменник пассивно (REL-03), а пассивное объявление прав не требует.
ctl set_permissions -p "$VHOST" site-web "" '^platform\.events$' "" >/dev/null

# terminal — издатель событий счёта и сделок (TRM-40, OPS-34).
#
# `configure` ПУСТ, и это не экономия: обменник терминал объявляет
# ПАССИВНО, а пассивное объявление прав не требует. Выданный `configure`
# позволил бы издателю пересоздать обменник — то есть молча подменить
# топологию, на которой висит чужой потребитель.
#
# `read` ПУСТ тоже: издателю нечего читать. Права выводятся из вызовов, а
# не выдаются про запас — ровно по этому правилу у `site-web` когда-то
# убрали `administrator`.
ctl set_permissions -p "$VHOST" terminal "" '^platform\.events$' "" >/dev/null

# cabinet — выведено из того, что делает консюмер, а не выдано про запас
# (Р-051). `cabinet.terminal-projection` в configure ОСТАЁТСЯ сознательно:
# очередь объявляется активно, её владелец — сам консюмер, потерянную очередь
# пересоздать больше некому.
#   write cabinet.terminal-projection — bindQueue требует write на очередь
#   write platform.events.dlx         — DLX проверяется при queue.declare
#   read  platform.events             — bindQueue требует read на обменник
#   read  cabinet.terminal-projection — consume
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
# rabbitmqadmin БЕЗ КРЕДЛА ходит под guest — пользователя, которого здесь нет.
# Первая редакция этого не передавала, получала «Access refused» по каждому
# объявлению И ВЫХОДИЛА НУЛЁМ: отказ превратился в успех ровно тем способом,
# против которого написан весь этот файл. Поймано на себе, B-OPS-014.
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

# ГЕЙТ ПО НАБЛЮДЕНИЮ, А НЕ ПО КОДУ ВОЗВРАТА КОМАНДЫ. Спрашиваем у брокера, что
# у него есть, и сверяем с тем, что обязано быть. Код возврата `rabbitmqadmin`
# однажды уже соврал; список обменников соврать не может.
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
