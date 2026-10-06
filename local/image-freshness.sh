#!/usr/bin/env bash
# Сверка «образ против исходника»: что работает в контуре — собранное из
# сегодняшнего кода или из вчерашнего.
#
# Зачем. Контейнер может быть старше кода, и тогда контур проверяет не то:
# проверка «контракт исполняется» даёт разный ответ на коде и в контуре
# (OPS-05, урок B-OPS-003). Проверяется не статус контейнера, а дата сборки
# образа против истории репозитория, из которого он собран.
#
# Это сверка, а не замена OPS-05. Она отвечает «образ отстал или нет» по
# времени; «из какого коммита собрано» ответит только метка
# org.opencontainers.image.revision, которую ставит OPS-05. До неё дата —
# единственное, что у нас есть, и у неё есть предел: пересборка без изменений
# делает образ «свежим», а коммит с одной правкой в README — «устаревшим».
#
# Запуск:  bash deploy/local/image-freshness.sh

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# сервис : образ : контекст сборки (репозиторий)
MAP="
mds:broker-local-mds:mds
cms:broker-local-cms:cms-legacy
cms-migrate:broker-local-cms-migrate:cms-legacy
web:broker-local-web:site-platform
cabinet:broker-local-cabinet:site-platform
relay:broker-local-relay:site-platform
consumer:broker-local-consumer:site-platform
"

printf '%-12s %-20s %-25s %-6s %s\n' СЕРВИС ОБРАЗ-СОБРАН КОД-ПОСЛЕДНИЙ-КОММИТ ПОЗАДИ ВЕРДИКТ
printf '%s\n' "------------------------------------------------------------------------------------------"

for row in $MAP; do
  [ -z "$row" ] && continue
  svc="${row%%:*}"; rest="${row#*:}"; img="${rest%%:*}"; ctx="${rest#*:}"
  created="$(docker image inspect "$img" --format '{{.Created}}' 2>/dev/null)"
  if [ -z "$created" ]; then
    printf '%-12s %-20s %-25s %-6s %s\n' "$svc" "ОБРАЗА НЕТ" "-" "-" "не собран"
    continue
  fi
  head_date="$(git -C "$ROOT/$ctx" log -1 --format=%cI 2>/dev/null)"
  behind="$(git -C "$ROOT/$ctx" log --since="$created" --oneline 2>/dev/null | wc -l | tr -d ' ')"
  # незакоммиченные правки в контексте — отдельный сигнал: их в образе нет
  dirty="$(git -C "$ROOT/$ctx" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$behind" -gt 0 ]; then verdict="ОБРАЗ СТАРШЕ КОДА на $behind коммит(ов)"
  else verdict="образ не старше кода"; fi
  [ "$dirty" -gt 0 ] && verdict="$verdict; +$dirty незакоммиченных файлов в $ctx"
  printf '%-12s %-20s %-25s %-6s %s\n' "$svc" "${created:0:19}" "${head_date:0:19}" "$behind" "$verdict"
done

echo
echo "Образ старше кода → пересобрать и проверить СОДЕРЖИМЫМ ответа, а не статусом."
