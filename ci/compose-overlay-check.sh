#!/usr/bin/env bash
# Разбор НАДСТРОЙКИ компоуза и порты контура. OPS-18.
#
# ОБЛАСТЬ НАЗВАНА СРАЗУ, потому что без неё проверка утверждала бы больше, чем
# знает. Контур описан ДВУМЯ файлами в ДВУХ репозиториях:
#
#   база      ../../site-platform/deploy/vps/docker-compose.yml   (чужая зона)
#   надстройка local/docker-compose.local.yml                     (наша)
#
# Полный `docker compose config` без базы невозможен — в одиночку надстройка
# не собирается вовсе («service site-db has neither an image nor a build
# context»). Значит в CI зоны `deploy`, где лежит только эта папка, контур
# целиком НЕ проверяется, и делать вид, что проверяется, нельзя.
#
# Здесь проверяется ровно то, что выводится из одной надстройки:
#   1. она разбирается как YAML (с тегами compose вроде !override);
#   2. хостовые порты — те самые 3100-3103, а не спорный диапазон 3000-3003.
#
# Пункт 2 — не формальность. `MDS_HTTP_URL` в .env.example указывал на 3003,
# когда MDS контура слушает 3103; переменную объявили на вырост, по ней никто
# ни разу не сходил, и расхождение не проявлялось. Дрейф порта между
# документом и компоузом — наш повторяющийся класс, и он ловится статически.
#
# Чего здесь НЕТ и почему: правило «у унаследованного сервиса `ports:` обязан
# стоять !override, иначе compose ДОБАВИТ порт к базовому» проверить отсюда
# нельзя — чтобы отличить унаследованный сервис от заведённого здесь, нужна
# база. Это записано техдолгом, а не проверено наполовину.
#
# Запуск:  bash ci/compose-overlay-check.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OVERLAY="local/docker-compose.local.yml"
[ -f "$OVERLAY" ] || { echo "ПРОВАЛ: нет $OVERLAY — проверять нечего, а должно быть что" >&2; exit 1; }

# Интерпретатор выбирается по СПОСОБНОСТИ выполнить работу, а не по имени:
# на раннере это python3, на машине владельца python3 есть тоже, но yaml
# стоит у другого. Выбор по имени дал бы отказ там, где инструмент есть.
PY_BIN=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "import yaml" >/dev/null 2>&1; then
    PY_BIN="$c"; break
  fi
done
# Нет инструмента — это НЕ «проверка пройдена». Молчаливый пропуск здесь и
# есть способ, которым проверка перестаёт существовать.
[ -n "$PY_BIN" ] || {
  echo "ПРОВАЛ: нет python с модулем yaml — проверка НЕ ВЫПОЛНЕНА, результат неизвестен" >&2
  exit 1
}
echo "интерпретатор: $("$PY_BIN" -c 'import sys,yaml;print(sys.executable,"pyyaml",yaml.__version__)')"

"$PY_BIN" - "$OVERLAY" <<'PY'
import sys, yaml

# compose-теги (!override, !reset) обычному загрузчику неизвестны. Пропускаем
# их как значение, а не падаем: падение здесь означало бы «файл сломан» там,
# где он исправен, — ложная тревога дороже, чем кажется.
class L(yaml.SafeLoader): pass
L.add_multi_constructor('!', lambda loader, suffix, node:
                        loader.construct_sequence(node) if isinstance(node, yaml.SequenceNode)
                        else loader.construct_scalar(node))

path = sys.argv[1]
with open(path, encoding='utf-8') as f:
    doc = yaml.load(f, Loader=L)

services = (doc or {}).get('services') or {}
if not services:
    print("ПРОВАЛ: в надстройке ноль сервисов — разбор прошёл, а смысла в нём нет", file=sys.stderr)
    sys.exit(1)

print("=== надстройка компоуза ===")
print("сервисов в надстройке (единица — сервис, НЕ весь контур): %d" % len(services))
print("  " + ", ".join(sorted(services)))

# Ожидание записано СВОЙСТВОМ, а не перечнем «как сегодня»: хостовой порт
# любого сервиса контура лежит в 3100-3103, либо это порт шины. Перечень
# «как сегодня» пришлось бы править при каждом добавлении сервиса, и его
# правили бы не глядя.
ALLOWED_BUS = {5672, 15672}
bad, seen = [], []
for name, body in sorted(services.items()):
    for p in (body or {}).get('ports') or []:
        if not isinstance(p, str):
            continue
        host = p.split(':')[0].strip("'\"")
        if not host.isdigit():
            continue
        host = int(host)
        seen.append((name, host))
        if host in ALLOWED_BUS:
            continue
        if not (3100 <= host <= 3103):
            bad.append((name, host))

print("хостовых портов объявлено: %d" % len(seen))
for n, h in seen:
    print("  %-10s %d" % (n, h))

if bad:
    print("", file=sys.stderr)
    for n, h in bad:
        print("ПРОВАЛ: сервис %s слушает на хосте %d — вне 3100-3103." % (n, h), file=sys.stderr)
        print("        Диапазон 3000-3003 занят dev-серверами соседей и дрейфует;"
              " контур, поднятый там, слушает не там, где записано.", file=sys.stderr)
    sys.exit(1)

print("=== надстройка разобрана, порты в диапазоне контура ===")
print("    Контур ЦЕЛИКОМ здесь не проверен: база компоуза — в site-platform.")
PY
