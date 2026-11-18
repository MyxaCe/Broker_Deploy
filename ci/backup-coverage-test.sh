#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILED=0
ok()   { echo "  OK    $*"; }
bad()  { echo "  ПРОВАЛ $*" >&2; FAILED=$((FAILED + 1)); }

ZONES_GIT="site-platform cms cms-legacy mds terminal deploy"
ZONES_PLAIN="_brain _reference"

make_root() {
  local root="$1" extra_git="${2:-}" extra_plain="${3:-}"
  local z
  mkdir -p "$root"
  for z in $ZONES_GIT ${extra_git:+$extra_git}; do
    mkdir -p "$root/$z"
    git -C "$root/$z" init -q
    git -C "$root/$z" config user.email ci@local
    git -C "$root/$z" config user.name CI
    echo "$z" > "$root/$z/README.md"
    git -C "$root/$z" add -A
    git -C "$root/$z" commit -qm "зона $z"
  done
  for z in $ZONES_PLAIN ${extra_plain:+$extra_plain}; do
    mkdir -p "$root/$z"
    echo "$z" > "$root/$z/заметка.md"
  done
}

run_backup() {
  BROKER_ROOT="$1" DEST_BASE="$2" bash "$ROOT/backup/backup.sh" 2>&1 || true
}

echo "=== А · на диске ровно то, что в списках ==="
make_root "$WORK/a-root"
OUT_A="$(run_backup "$WORK/a-root" "$WORK/a-dest")"

grep -q -- '--- охват: списки против того, что есть на машине ---' <<<"$OUT_A" \
  && ok "прогон дошёл до раздела охвата" \
  || bad "раздел охвата не выполнялся — всё дальнейшее недействительно"

grep -q 'репозиториев на диске 6, в списке 6' <<<"$OUT_A" \
  && ok "охват объявлен числом: 6 из 6" \
  || bad "охват числом не объявлен или число не 6: $(grep 'репозиториев на диске' <<<"$OUT_A" || echo 'строки нет')"

grep -q 'папок без git на диске 2, в списке 3' <<<"$OUT_A" \
  && ok "папки без git: 2 на диске против 3 в списке (deploy лежит с git)" \
  || bad "строка про папки без git не та: $(grep 'папок без git' <<<"$OUT_A" || echo 'строки нет')"

N_A=$(grep -cE 'НЕ В БЭКАПЕ: (репозиторий|папка)' <<<"$OUT_A" || true)
[ "$N_A" = 0 ] \
  && ok "пропусков охвата по репозиториям и папкам нет — списки и диск сошлись" \
  || bad "на согласованном корне найдено $N_A строк НЕ В БЭКАПЕ: $(grep 'НЕ В БЭКАПЕ' <<<"$OUT_A")"

VOL_A=$(grep -cE 'НЕ В БЭКАПЕ: том' <<<"$OUT_A" || true)
echo "  ОБЛАСТЬ: строк про тома — $VOL_A; в проверку НЕ входят (docker смотрит на машину, а не на подставной корень)"

echo "=== Б · на диске появилась зона, которой нет в списках ==="
make_root "$WORK/b-root" "новая-зона" "новые-документы"
OUT_B="$(run_backup "$WORK/b-root" "$WORK/b-dest")"

grep -q 'НЕ В БЭКАПЕ: репозиторий новая-зона' <<<"$OUT_B" \
  && ok "репозиторий вне списка назван поимённо" \
  || bad "репозиторий вне списка НЕ замечен"

grep -q 'НЕ В БЭКАПЕ: папка без git новые-документы' <<<"$OUT_B" \
  && ok "папка без git вне списка названа поимённо" \
  || bad "папка без git вне списка НЕ замечена"

grep -q 'репозиториев на диске 7, в списке 6' <<<"$OUT_B" \
  && ok "число выросло: 7 против 6" \
  || bad "число не выросло: $(grep 'репозиториев на диске' <<<"$OUT_B" || echo 'строки нет')"

grep -q 'ротация ОТМЕНЕНА' <<<"$OUT_B" \
  && ok "ротация отменена — неполный бэкап не вытеснит полный" \
  || bad "ротация НЕ отменена при неполном прогоне"

grep -q 'БЭКАП НЕПОЛОН' <<<"$OUT_B" \
  && ok "итог назван неполным" \
  || bad "итог не назван неполным"

echo
if [ "$FAILED" -gt 0 ]; then
  echo "=== ОХВАТ БЭКАПА: ПРОВАЛОВ $FAILED ===" >&2
  exit 1
fi
echo "=== охват бэкапа: проверено на двух синтетических корнях, провалов 0 ==="
echo "    Зелёный путь «бэкап полон» здесь НЕ проверялся: нужен живой контур."
