#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OVERLAY="local/docker-compose.local.yml"
[ -f "$OVERLAY" ] || { echo "ПРОВАЛ: нет $OVERLAY — проверять нечего, а должно быть что" >&2; exit 1; }

PY_BIN=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "import yaml" >/dev/null 2>&1; then
    PY_BIN="$c"; break
  fi
done
[ -n "$PY_BIN" ] || {
  echo "ПРОВАЛ: нет python с модулем yaml — проверка НЕ ВЫПОЛНЕНА, результат неизвестен" >&2
  exit 1
}
echo "интерпретатор: $("$PY_BIN" -c 'import sys,yaml;print(sys.executable,"pyyaml",yaml.__version__)')"

"$PY_BIN" - "$OVERLAY" <<'PY'
import sys, yaml

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
