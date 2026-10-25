#!/usr/bin/env bash
# Сторож примонтированного умеет краснеть — и умеет НЕ краснеть. B-OPS-034.
#
# Обе стороны проверяются порознь и на синтетическом дереве, а не порчей
# настоящего файла. Односторонний показ бесполезен в обе стороны сразу:
# сторож, который ловит запрещённое и заодно красит предупреждение о нём,
# будет отключён первым же человеком, которому он помешает, — а запрет
# при этом исчезнет вместе с ним.
#
# Запуск:  bash ci/ohrana-montirovannogo-test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STOROZH="$ROOT/ci/ohrana-montirovannogo.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v python3 >/dev/null 2>&1 || {
    echo "ПРОВАЛ: нет python3 — проверка НЕ ВЫПОЛНЕНА, результат неизвестен" >&2
    exit 1
}

provalov=0

# Синтетическое дерево: каталог службы с compose.yml, монтирующим ./conf,
# и скриптом, содержимое которого подставляется стендом.
stend() {
    local imya="$1" telo="$2" kat
    kat="$WORK/$imya/server/sluzhba"
    mkdir -p "$kat"
    cat > "$kat/compose.yml" <<'YML'
services:
  demo:
    image: busybox
    volumes:
      - ./conf:/etc/demo:ro
      - ./rendered:/etc/demo/rendered:ro
YML
    printf '%s\n' "$telo" > "$kat/compose.sh"
    echo "$WORK/$imya"
}

ozhidayu() {
    local imya="$1" zhdu="$2" telo="$3" koren vyhod kod
    koren="$(stend "$imya" "$telo")"
    vyhod="$(python3 "$STOROZH" "$koren" 2>&1)" && kod=0 || kod=$?
    if [ "$kod" -ne "$zhdu" ]; then
        echo "ПРОВАЛ [$imya]: ждали код $zhdu, получили $kod" >&2
        echo "$vyhod" | sed 's/^/    /' >&2
        provalov=$((provalov + 1))
    else
        echo "ок [$imya]: код $kod"
    fi
}

echo "=== УПОМИНАНИЕ — НЕ НАРУШЕНИЕ ==============================="
# Ровно тот текст, которым запрет записан в настоящем compose.sh.
ozhidayu 'zapret-v-proze' 0 '#!/usr/bin/env bash
# НИКОГДА не удалять каталог conf перед заменой: он примонтирован, и
# `rm -rf` + распаковка = контейнер смотрит в несуществующий каталог.
mkdir -p "$HERE/rendered"'

ozhidayu 'rm-v-kavychkah' 0 '#!/usr/bin/env bash
echo "не делайте rm -rf conf — каталог примонтирован"'

ozhidayu 'rm-v-hvostovom-kommentarii' 0 '#!/usr/bin/env bash
mkdir -p conf   # не rm -rf conf, а mkdir: каталог должен уцелеть'

echo "=== УПОТРЕБЛЕНИЕ — НАРУШЕНИЕ, В ЛЮБОЙ ОГРАНКЕ ==============="
ozhidayu 'golyj-vyzov'      1 '#!/usr/bin/env bash
rm -rf conf'
ozhidayu 'cherez-peremennuyu' 1 '#!/usr/bin/env bash
rm -rf "$HERE/conf"'
ozhidayu 'posle-i-i'        1 '#!/usr/bin/env bash
cd "$HERE" && rm -rf conf && tar xzf -'
ozhidayu 'flagi-naoborot'   1 '#!/usr/bin/env bash
rm -fr "$HERE/conf"'
ozhidayu 'cherez-sudo'      1 '#!/usr/bin/env bash
sudo rm -r "$HERE/rendered"'
ozhidayu 'v-uslovii'        1 '#!/usr/bin/env bash
if [ -d conf ]; then rm -rf conf; fi'

echo "=== СОСЕДНЕЕ ИМЯ — НЕ НАРУШЕНИЕ ============================="
# `conf` не должен ловиться в `conf.bak` и в `configs`: сторож, который
# красит лишнее, обучает читать красное как фон.
ozhidayu 'pohozhee-imya' 0 '#!/usr/bin/env bash
rm -rf "$HERE/conf.bak"
rm -rf "$HERE/configs"'

echo "=== ОХВАТ: ПРОВЕРЯТЬ НЕЧЕГО — ЭТО НЕ ЗЕЛЕНЬ =================="
mkdir -p "$WORK/pusto/server"
if python3 "$STOROZH" "$WORK/pusto" >/dev/null 2>&1; then
    echo "ПРОВАЛ [pustoj-koren]: пустое дерево прошло как «нарушений нет»" >&2
    provalov=$((provalov + 1))
else
    echo "ок [pustoj-koren]: код 1"
fi

echo
if [ "$provalov" -ne 0 ]; then
    echo "ПРОВАЛ: $provalov случаев из перечисленных разошлись с ожиданием" >&2
    exit 1
fi
echo "ОБЕ СТОРОНЫ ПОКАЗАНЫ: проза проходит, вызов ловится"
