#!/usr/bin/env bash

set -euo pipefail

DEST="${1:-$(ls -1d /d/Broker-backups/*/ 2>/dev/null | sort -r | head -1)}"
[ -n "$DEST" ] && [ -d "$DEST" ] || { echo "ПРОВАЛ: не найден каталог бэкапа"; exit 1; }
DEST="${DEST%/}"
echo "=== проверяю: $DEST ==="

TMPPG=verify-restore-pg
TMPVOL=verify-restore-vol
TMPDIR=/tmp/verify-restore
cleanup() {
  docker rm -f "$TMPPG" >/dev/null 2>&1 || true
  docker volume rm -f "$TMPVOL" >/dev/null 2>&1 || true
  rm -rf "$TMPDIR"
}
trap cleanup EXIT
cleanup
mkdir -p "$TMPDIR"

FAIL=0

UNKNOWN=0
EMPTY=0
UNKNOWN_NOTES=""
EMPTY_NOTES=""
note_unknown() { UNKNOWN=$((UNKNOWN+1)); UNKNOWN_NOTES="${UNKNOWN_NOTES}  - $1"$'
'; }
note_empty()   { EMPTY=$((EMPTY+1));     EMPTY_NOTES="${EMPTY_NOTES}  - $1"$'
'; }

( cd "$DEST" && sha256sum -c manifest.sha256 --quiet ) \
  && echo "  контрольные суммы: сходятся" \
  || { echo "  ПРОВАЛ: контрольные суммы не сходятся"; exit 1; }

docker run -d --name "$TMPPG" -e POSTGRES_PASSWORD=verify -e POSTGRES_USER=verify \
  -e POSTGRES_DB=postgres postgres:16-alpine >/dev/null
until docker exec "$TMPPG" pg_isready -U verify -d postgres >/dev/null 2>&1; do sleep 1; done
echo "  чистая Postgres поднята"

table_digest() {
  { docker exec "$1" psql -U "$2" -d "$3" -tAc \
    "SELECT count(*)||'|'||coalesce(md5(string_agg(x, E'\n' ORDER BY x)), '-')
     FROM (SELECT t::text AS x FROM \"$4\" t) s;" 2>/dev/null || true; } | tr -d '\r '
}

verify_db() {
  local dump="$DEST/db/$1.dump" live_c="$2" live_u="$3" live_db="$4"
  local target="verify_$1"
  echo
  echo "  --- база $1 ---"
  if [ ! -f "$dump" ]; then
    echo "  НЕ ПРОВЕРЕНО: дампа $1.dump нет в бэкапе"
    note_unknown "база $1: дампа нет в бэкапе"; FAIL=1; return
  fi
  if ! docker inspect -f '{{.State.Running}}' "$live_c" 2>/dev/null | grep -q true; then
    echo "  НЕ ПРОВЕРЕНО: живой контейнер $live_c не запущен, сверять не с чем"
    note_unknown "база $1: живая база недоступна, результат сверки неизвестен"
    return
  fi
  docker exec "$TMPPG" psql -U verify -d postgres -q -c "CREATE DATABASE $target;" >/dev/null
  docker exec -i "$TMPPG" pg_restore -U verify -d "$target" --no-owner --no-acl \
    < "$dump" 2>"$TMPDIR/$1.restore.err" || true
  echo "  дамп развёрнут на чистой базе $target"

  local tables t a b checked=0 empty=0 mism=0
  tables=$(docker exec "$live_c" psql -U "$live_u" -d "$live_db" -tAc \
    "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY 1;" | tr -d '\r')
  if [ -z "$tables" ]; then
    echo "  НЕ ПРОВЕРЕНО: в живой базе нет таблиц — проверять было нечего"
    note_unknown "база $1: в живой базе нет ни одной таблицы"; FAIL=1; return
  fi
  for t in $tables; do
    checked=$((checked+1))
    a=$(table_digest "$live_c" "$live_u" "$live_db" "$t")
    b=$(table_digest "$TMPPG" verify "$target" "$t")
    if [ "$a" != "$b" ]; then
      printf "  РАСХОЖДЕНИЕ %-44s живая=%s восстановленная=%s\n" "$t" "$a" "$b"
      mism=$((mism+1)); FAIL=1
    elif [ "${a%%|*}" = "0" ]; then
      empty=$((empty+1))
    fi
  done
  echo "  таблиц осмотрено: $checked · расхождений: $mism · пустых с обеих сторон: $empty (ПУСТО — не доказательство)"
}

verify_db broker_site broker-local-site-db-1 broker broker_site
verify_db broker_cms  broker-local-cms-db-1  cms    broker_cms

echo
echo "  --- содержимое по именам ---"
anchor() {
  local live rest
  live=$({ docker exec "$2" psql -U "$3" -d "$4" -tAc "$6" 2>/dev/null || true; } | tr -d '\r' | sed 's/[[:space:]]*$//')
  rest=$({ docker exec "$TMPPG" psql -U verify -d "$5" -tAc "$6" 2>/dev/null || true; } | tr -d '\r' | sed 's/[[:space:]]*$//')
  if [ -z "$live" ] || [ "$live" = "0" ]; then
    echo "  НЕ ПРОВЕРЕНО: $1 — в живой базе этого нет, проверять было нечего"
    note_empty "опора «$1»: в живой базе пусто"
  elif [ "$live" = "$rest" ]; then
    echo "  $1: $rest"
  else
    echo "  ПРОВАЛ: $1 — живая '$live', восстановленная '$rest'"; FAIL=1
  fi
}
CMSDB=(broker-local-cms-db-1 cms broker_cms verify_broker_cms)
SITEDB=(broker-local-site-db-1 broker broker_site verify_broker_site)
anchor "тенант CMS" "${CMSDB[@]}" \
  "SELECT slug||' / '||name||' / demo='||demo_start_balance_cents FROM sites ORDER BY id LIMIT 1;"
anchor "статей CMS" "${CMSDB[@]}" "SELECT count(*) FROM articles;"
anchor "инструментов каталога CMS" "${CMSDB[@]}" "SELECT count(*) FROM site_instruments_items;"
anchor "демо-счёт (BUS-01)" "${SITEDB[@]}" \
  "SELECT user_id||' balance='||balance_cents FROM demo_accounts ORDER BY user_id LIMIT 1;"

echo
echo "  --- тома ---"
verify_vol() {
  local vol="$1" arc="$DEST/volumes/$1.tar.gz" live rest n
  if [ ! -f "$arc" ]; then
    echo "  НЕ ПРОВЕРЕНО: архива $1.tar.gz нет в бэкапе"; note_unknown "том $1: архива нет"; return
  fi
  if ! docker volume inspect "$vol" >/dev/null 2>&1; then
    echo "  НЕ ПРОВЕРЕНО: живого тома $vol нет, сверять не с чем"
    note_unknown "том $1: живого тома нет, результат сверки неизвестен"; return
  fi
  docker volume rm -f "$TMPVOL" >/dev/null 2>&1 || true
  docker volume create "$TMPVOL" >/dev/null
  MSYS_NO_PATHCONV=1 docker run --rm -v "$TMPVOL":/dst -v "$DEST/volumes":/in:ro alpine \
    tar xzf "/in/$1.tar.gz" -C /dst 2>/dev/null \
    || { echo "  ПРОВАЛ: том $1 не распаковался"; FAIL=1; return; }
  live=$(MSYS_NO_PATHCONV=1 docker run --rm -v "$vol":/m:ro alpine sh -c \
    'cd /m && find . -type f | sort | xargs -r md5sum | md5sum; find . -type f | wc -l')
  rest=$(MSYS_NO_PATHCONV=1 docker run --rm -v "$TMPVOL":/m:ro alpine sh -c \
    'cd /m && find . -type f | sort | xargs -r md5sum | md5sum; find . -type f | wc -l')
  n=$(echo "$live" | tail -1 | tr -d ' ')
  if [ "$live" != "$rest" ]; then
    echo "  ПРОВАЛ: том $1 — содержимое восстановленного не совпало с живым"; FAIL=1
  elif [ "$n" = "0" ]; then
    echo "  ПУСТО: том $1 — файлов нет ни в живом, ни в восстановленном; проверять было нечего"
    note_empty "том $1: пуст, восстановление непустого тома не проверено"
  else
    echo "  том $1: $n файлов, содержимое совпало"
  fi
  docker volume rm -f "$TMPVOL" >/dev/null 2>&1 || true
}
verify_vol broker-local_cms-media
verify_vol broker-local_cabinet-uploads

echo "  --- тот же путь на непустом томе (механизм, не данные) ---"
SRCVOL=verify-restore-src
docker volume rm -f "$SRCVOL" >/dev/null 2>&1 || true
docker volume create "$SRCVOL" >/dev/null
MSYS_NO_PATHCONV=1 docker run --rm -v "$SRCVOL":/m alpine sh -c \
  'mkdir -p /m/вложенная && head -c 4096 /dev/urandom > /m/вложенная/файл.bin && echo текст > /m/readme.txt' >/dev/null
MSYS_NO_PATHCONV=1 docker run --rm -v "$SRCVOL":/src:ro -v "$TMPDIR":/out alpine \
  tar czf /out/synthetic.tar.gz -C /src . 2>/dev/null
docker volume rm -f "$TMPVOL" >/dev/null 2>&1 || true
docker volume create "$TMPVOL" >/dev/null
MSYS_NO_PATHCONV=1 docker run --rm -v "$TMPVOL":/dst -v "$TMPDIR":/in:ro alpine \
  tar xzf /in/synthetic.tar.gz -C /dst 2>/dev/null
sa=$(MSYS_NO_PATHCONV=1 docker run --rm -v "$SRCVOL":/m:ro alpine sh -c \
  'cd /m && find . -type f | sort | xargs -r md5sum | md5sum; find . -type f | wc -l')
sb=$(MSYS_NO_PATHCONV=1 docker run --rm -v "$TMPVOL":/m:ro alpine sh -c \
  'cd /m && find . -type f | sort | xargs -r md5sum | md5sum; find . -type f | wc -l')
if [ "$sa" = "$sb" ] && [ "$(echo "$sa" | tail -1 | tr -d ' ')" = "2" ]; then
  echo "  механизм том→архив→том: 2 файла, включая вложенный каталог и не-ASCII имена, совпали"
else
  echo "  ПРОВАЛ: механизм том→архив→том не воспроизводит содержимое"; FAIL=1
fi
docker volume rm -f "$SRCVOL" "$TMPVOL" >/dev/null 2>&1 || true

echo
echo "  --- git-бандлы ---"
bundles=0; unpushed_checked=0
for b in "$DEST"/repos/*.bundle; do
  [ -f "$b" ] || continue
  bundles=$((bundles+1))
  r=$(basename "$b" .bundle)
  git clone -q "$b" "$TMPDIR/$r" 2>/dev/null \
    || { echo "  ПРОВАЛ: $r не клонируется"; FAIL=1; continue; }
  have=$(cd "$TMPDIR/$r" && git branch -a --format='%(refname:short)')
  if [ -s "$DEST/repos/$r.branches.txt" ] && ! awk 'NF>=3' "$DEST/repos/$r.branches.txt" | grep -q .; then
    echo "  ВНИМАНИЕ: $r — бэкап старого формата, в branches.txt нет числа «только здесь»;"
    echo "            беру слабый признак (нет upstream), он завышает риск"
    want=$(awk 'NF==1 {print $1}' "$DEST/repos/$r.branches.txt" 2>/dev/null || true)
    note_unknown "репозиторий $r: бэкап старого формата, свойство «существует только здесь» не проверялось"
  else
    want=$(awk 'NF>=3 && $3 ~ /^[0-9]+$/ && $3 > 0 {print $1}' "$DEST/repos/$r.branches.txt" 2>/dev/null || true)
  fi
  if [ -z "$want" ]; then
    echo "  $r: восстановился; веток, существующих только здесь, на момент бэкапа не было — проверять нечего"
  else
    for w in $want; do
      if echo "$have" | grep -qxF "$w" || echo "$have" | grep -qxF "origin/$w"; then
        echo "  $r: восстановилась ветка $w — её коммитов нет ни на одном remote"
        unpushed_checked=$((unpushed_checked+1))
      else
        echo "  ПРОВАЛ: $r — ветки '$w' (есть только здесь) нет в восстановленном репозитории"; FAIL=1
      fi
    done
  fi
done
[ "$bundles" -gt 0 ] || { echo "  НЕ ПРОВЕРЕНО: бандлов в бэкапе нет"; note_unknown "git-бандлы: в бэкапе нет ни одного"; FAIL=1; }
if [ "$unpushed_checked" = 0 ] && [ "$bundles" -gt 0 ]; then
  echo "  ВНИМАНИЕ: ни одного коммита, которого нет на remote — проверено, что бандлы"
  echo "            клонируются, но не то, ради чего они нужны"
  note_empty "git-бандлы: нечего было спасать (всё есть на remote), главное свойство не проверено"
fi

echo
echo "  --- охват: что есть на машине против того, что в бэкапе ---"
ROOT_SRC="${BROKER_ROOT:-/c/Users/Billie/Desktop/Broker}"
if [ -d "$ROOT_SRC" ]; then
  ondisk=0; nobundle=0
  for d in "$ROOT_SRC"/*/; do
    [ -d "$d/.git" ] || continue
    ondisk=$((ondisk+1))
    n="$(basename "$d")"
    [ -f "$DEST/repos/$n.bundle" ] && continue
    nobundle=$((nobundle+1))
    echo "  НЕ ПРОВЕРЕНО: репозиторий $n есть на машине, бандла в бэкапе нет"
    note_unknown "репозиторий $n: в бэкап не попал — его история существует в одном экземпляре"
    FAIL=1
  done
  echo "  репозиториев на машине: $ondisk · бандлов в бэкапе: $bundles · без бандла: $nobundle"
else
  echo "  ОХВАТ НЕ ПРОВЕРЕН: каталога $ROOT_SRC нет — сверять список не с чем"
  note_unknown "охват бандлов: исходный каталог недоступен, полнота бэкапа неизвестна"
fi

echo
if [ "$UNKNOWN" -gt 0 ]; then
  echo "НЕ ПРОВЕРЕНО — РЕЗУЛЬТАТ НЕИЗВЕСТЕН ($UNKNOWN):"
  printf '%s' "$UNKNOWN_NOTES"
fi
if [ "$EMPTY" -gt 0 ]; then
  echo "ПУСТО — проверять было нечего ($EMPTY):"
  printf '%s' "$EMPTY_NOTES"
fi

if [ "$FAIL" != 0 ]; then
  echo "=== ЕСТЬ РАСХОЖДЕНИЯ ==="
  exit 1
fi
if [ "$UNKNOWN" -gt 0 ]; then
  echo "=== РЕЗУЛЬТАТ НЕИЗВЕСТЕН: не выполнено проверок — $UNKNOWN ==="
  echo "    Это НЕ «восстановление проверено»: материала не было, см. список выше."
  exit 2
fi
echo "=== ВОССТАНОВЛЕНИЕ ПРОВЕРЕНО · пусто (проверять было нечего): $EMPTY ==="
