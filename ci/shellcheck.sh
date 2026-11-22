#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SEVERITY="${SHELLCHECK_SEVERITY:-warning}"

command -v shellcheck >/dev/null 2>&1 || {
  echo "ПРОВАЛ: shellcheck не установлен — проверка НЕ ВЫПОЛНЕНА, результат неизвестен" >&2
  exit 1
}

mapfile -t SCRIPTS < <(find . -path ./.git -prune -o -type f -name '*.sh' -print | sort)
N=${#SCRIPTS[@]}

if [ "$N" -eq 0 ]; then
  echo "ПРОВАЛ: не найдено ни одного файла *.sh — проверять нечего, а должно быть что" >&2
  exit 1
fi

echo "=== shellcheck: порог $SEVERITY ==="
echo "осмотрено файлов *.sh (найдены обходом дерева, не списком): $N"
printf '  %s\n' "${SCRIPTS[@]}"
echo

CRLF=0
for f in "${SCRIPTS[@]}"; do
  if LC_ALL=C grep -qU $'\r' "$f"; then
    echo "ПРОВАЛ: $f содержит CR — на Linux такой скрипт не запустится" >&2
    CRLF=$((CRLF + 1))
  fi
done
if [ "$CRLF" -gt 0 ]; then
  echo "файлов с CRLF: $CRLF из $N" >&2
  exit 1
fi
echo "перевод строки: LF во всех $N файлах"
echo

BELOW=$(shellcheck -f gcc "${SCRIPTS[@]}" 2>/dev/null | grep -c . || true)
echo "замечаний всех уровней (note/style тоже): $BELOW — ниже порога, не блокируют"
echo

if shellcheck -S "$SEVERITY" "${SCRIPTS[@]}"; then
  echo "=== shellcheck чисто: $N файлов, порог $SEVERITY ==="
else
  echo "=== shellcheck: НАЙДЕНЫ ЗАМЕЧАНИЯ уровня $SEVERITY и выше ===" >&2
  exit 1
fi
