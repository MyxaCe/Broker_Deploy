#!/usr/bin/env bash
# Проверка восстановления. OPS-04.
#
# Разворачивает дамп на ЧИСТОЙ базе во временном контейнере и сверяет число
# строк с живой базой. Плюс восстанавливает git-бандл в пустой каталог и
# проверяет, что незапушенная ветка на месте.
#
# Ничего в контуре не трогает: временный контейнер и временный каталог.

set -euo pipefail

DEST="${1:-$(ls -1d /d/Broker-backups/*/ 2>/dev/null | sort -r | head -1)}"
[ -n "$DEST" ] && [ -d "$DEST" ] || { echo "ПРОВАЛ: не найден каталог бэкапа"; exit 1; }
echo "=== проверяю: $DEST ==="

TMPPG=verify-restore-pg
cleanup() { docker rm -f "$TMPPG" >/dev/null 2>&1 || true; rm -rf /tmp/verify-repo; }
trap cleanup EXIT
cleanup

# --- 0. Целостность файлов -------------------------------------------------
( cd "$DEST" && sha256sum -c manifest.sha256 --quiet ) \
  && echo "  контрольные суммы: сходятся" \
  || { echo "  ПРОВАЛ: контрольные суммы не сходятся"; exit 1; }

# --- 1. Чистая Postgres ----------------------------------------------------
docker run -d --name "$TMPPG" -e POSTGRES_PASSWORD=verify -e POSTGRES_USER=broker \
  -e POSTGRES_DB=verify_target postgres:16-alpine >/dev/null
until docker exec "$TMPPG" pg_isready -U broker -d verify_target >/dev/null 2>&1; do sleep 1; done
echo "  чистая база поднята"

# --- 2. Восстановление -----------------------------------------------------
docker exec -i "$TMPPG" pg_restore -U broker -d verify_target --no-owner --no-acl \
  < "$DEST/db/broker_site.dump" 2>/dev/null || true   # NOTICE на пустой базе — норма
echo "  дамп развёрнут"

# --- 3. Сверка с живой базой ----------------------------------------------
# Не «база не пустая», а построчное совпадение по каждой таблице.
FAIL=0
for t in users leads outbox processed_events demo_accounts demo_positions demo_trades sessions documents notifications; do
  live=$(docker exec broker-local-site-db-1 psql -U broker -d broker_site -tAc "SELECT count(*) FROM $t;" 2>/dev/null | tr -d '\r ')
  rest=$(docker exec "$TMPPG"          psql -U broker -d verify_target -tAc "SELECT count(*) FROM $t;" 2>/dev/null | tr -d '\r ')
  if [ "$live" = "$rest" ]; then
    printf "  %-18s живая=%-5s восстановленная=%-5s совпало\n" "$t" "$live" "$rest"
  else
    printf "  %-18s живая=%-5s восстановленная=%-5s РАСХОЖДЕНИЕ\n" "$t" "$live" "$rest"; FAIL=1
  fi
done

# --- 4. Содержимое, а не только счётчики -----------------------------------
# Счётчик совпадает и у двух пустых таблиц. Проверяем конкретную строку.
acc=$(docker exec "$TMPPG" psql -U broker -d verify_target -tAc \
  "SELECT balance_cents FROM demo_accounts LIMIT 1;" 2>/dev/null | tr -d '\r ')
[ "$acc" = "250000" ] && echo "  содержимое: счёт из BUS-01 на месте (balance_cents=250000)" \
                      || { echo "  ПРОВАЛ: счёт из BUS-01 не восстановился (получено: '$acc')"; FAIL=1; }

# --- 5. Git-бандл: восстанавливается ли незапушенная ветка ------------------
git clone -q "$DEST/repos/site-platform.bundle" /tmp/verify-repo 2>/dev/null || true
if [ -d /tmp/verify-repo ]; then
  br=$(cd /tmp/verify-repo && git branch -a --format='%(refname:short)' | tr '\n' ' ')
  case "$br" in
    *web-01-local-run*) echo "  git-бандл: незапушенная ветка web-01-local-run восстановилась" ;;
    *) echo "  ПРОВАЛ: незапушенной ветки нет в восстановленном репозитории ($br)"; FAIL=1 ;;
  esac
else
  echo "  ПРОВАЛ: бандл не клонируется"; FAIL=1
fi

echo
[ "$FAIL" = 0 ] && echo "=== ВОССТАНОВЛЕНИЕ ПРОВЕРЕНО ===" || { echo "=== ЕСТЬ РАСХОЖДЕНИЯ ==="; exit 1; }
