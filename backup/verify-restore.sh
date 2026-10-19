#!/usr/bin/env bash
# Проверка восстановления. OPS-04.
#
# Разворачивает дампы на ЧИСТЫХ базах во временном контейнере и сверяет с
# живыми — не «база не пустая», а содержимое каждой таблицы. Плюс медиа-тома
# и git-бандлы. Ничего в контуре не трогает: временный контейнер, временные
# тома, временные каталоги, всё удаляется в trap.
#
# ЧТО ИЗМЕНИЛОСЬ 06.10 и почему (три дыры прежней версии):
#
#  1. Проверялась ОДНА база из двух. `broker_cms.dump` снимался и не
#     разворачивался никогда — а именно в нём живёт тенант `apex-ru` и весь
#     контент, посаженный в OPS-11. Отчёт при этом заканчивался строкой
#     «ВОССТАНОВЛЕНИЕ ПРОВЕРЕНО»: непроверенное было неотличимо от
#     проверенного.
#  2. Сверялись СЧЁТЧИКИ по списку таблиц, вбитому руками. Счётчик совпадает
#     и у двух пустых таблиц, а список, вбитый руками, молча отстаёт от схемы.
#     Теперь список берётся из живой базы (охват объявляется числом), а
#     сравнивается контрольная сумма СОДЕРЖИМОГО каждой таблицы.
#  3. Медиа-тома снимались и не проверялись вовсе.
#
# И правило охвата: пустой материал даёт «нечего было проверять», а не
# «расхождений нет». Такие строки помечены словом ПУСТО и считаются отдельно.

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
NOTCHECKED=0        # пункты, которые НЕ выполнились — первой строкой резюме
NOTES=""
note_skip() { NOTCHECKED=$((NOTCHECKED+1)); NOTES="$NOTES\n  - $1"; }

# --- 0. Целостность файлов -------------------------------------------------
( cd "$DEST" && sha256sum -c manifest.sha256 --quiet ) \
  && echo "  контрольные суммы: сходятся" \
  || { echo "  ПРОВАЛ: контрольные суммы не сходятся"; exit 1; }

# --- 1. Чистая Postgres ----------------------------------------------------
docker run -d --name "$TMPPG" -e POSTGRES_PASSWORD=verify -e POSTGRES_USER=verify \
  -e POSTGRES_DB=postgres postgres:16-alpine >/dev/null
until docker exec "$TMPPG" pg_isready -U verify -d postgres >/dev/null 2>&1; do sleep 1; done
echo "  чистая Postgres поднята"

# --- 2. Сверка базы: содержимое каждой таблицы, охват объявлен --------------
#
# Эталон берётся из ЖИВОЙ базы, список таблиц — оттуда же. Сравнивается не
# счётчик, а md5 от всех строк таблицы в стабильном порядке.
table_digest() {   # контейнер юзер база таблица -> "строк|md5содержимого"
  { docker exec "$1" psql -U "$2" -d "$3" -tAc \
    "SELECT count(*)||'|'||coalesce(md5(string_agg(x, E'\n' ORDER BY x)), '-')
     FROM (SELECT t::text AS x FROM \"$4\" t) s;" 2>/dev/null || true; } | tr -d '\r '
}

verify_db() {   # имя_дампа живой_контейнер живой_юзер живая_база
  local dump="$DEST/db/$1.dump" live_c="$2" live_u="$3" live_db="$4"
  local target="verify_$1"
  echo
  echo "  --- база $1 ---"
  if [ ! -f "$dump" ]; then
    echo "  НЕ ПРОВЕРЕНО: дампа $1.dump нет в бэкапе"
    note_skip "база $1: дампа нет в бэкапе"; FAIL=1; return
  fi
  if ! docker inspect -f '{{.State.Running}}' "$live_c" 2>/dev/null | grep -q true; then
    echo "  НЕ ПРОВЕРЕНО: живой контейнер $live_c не запущен, сверять не с чем"
    note_skip "база $1: живая база недоступна, результат сверки неизвестен"
    return
  fi
  docker exec "$TMPPG" psql -U verify -d postgres -q -c "CREATE DATABASE $target;" >/dev/null
  docker exec -i "$TMPPG" pg_restore -U verify -d "$target" --no-owner --no-acl \
    < "$dump" 2>"$TMPDIR/$1.restore.err" || true   # NOTICE на чистой базе — норма
  echo "  дамп развёрнут на чистой базе $target"

  local tables t a b checked=0 empty=0 mism=0
  tables=$(docker exec "$live_c" psql -U "$live_u" -d "$live_db" -tAc \
    "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY 1;" | tr -d '\r')
  if [ -z "$tables" ]; then
    echo "  НЕ ПРОВЕРЕНО: в живой базе нет таблиц — проверять было нечего"
    note_skip "база $1: в живой базе нет ни одной таблицы"; FAIL=1; return
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

# --- 3. Именованные опоры: конкретные строки, а не только суммы -------------
#
# Суммы скажут «совпало», но не скажут, ЧТО восстановилось. Опора отвечает на
# это и падает, если дамп снят с пустой базы.
#
# Ожидание НЕ зашито числом. Прежняя версия требовала `balance_cents=250000`,
# и 06.10 проверка покраснела на исправном бэкапе: живой счёт к тому времени
# стал 777123. Эталон, снятый с данных одного дня, устаревает молча и затем
# краснеет не по делу — а красный результат не по делу перестают читать.
# Эталон здесь — ЖИВАЯ база (её же восстанавливали), а утверждение, которое
# проверяется, — «значение восстановилось и оно не пустое».
echo
echo "  --- содержимое по именам ---"
anchor() {   # описание живой_контейнер живой_юзер живая_база восст_база запрос
  local live rest
  # `|| true`: отсутствующая таблица или колонка — это «проверять нечего», а
  # не аварийный выход всего прогона. Без него `set -e` оборвал отчёт на
  # первой же опоре с опечаткой в запросе, и остальные проверки не
  # выполнились — молча, без единой строки о том, что их не было.
  live=$({ docker exec "$2" psql -U "$3" -d "$4" -tAc "$6" 2>/dev/null || true; } | tr -d '\r' | sed 's/[[:space:]]*$//')
  rest=$({ docker exec "$TMPPG" psql -U verify -d "$5" -tAc "$6" 2>/dev/null || true; } | tr -d '\r' | sed 's/[[:space:]]*$//')
  if [ -z "$live" ] || [ "$live" = "0" ]; then
    echo "  НЕ ПРОВЕРЕНО: $1 — в живой базе этого нет, проверять было нечего"
    note_skip "опора «$1»: в живой базе пусто"
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

# --- 4. Медиа-тома ---------------------------------------------------------
# Снимались и не проверялись ни разу. Пустой том — законное состояние, но оно
# обязано называться ПУСТО, а не «совпало»: иначе архив несуществующих данных
# неотличим от архива, который не восстановился.
echo
echo "  --- тома ---"
verify_vol() {
  local vol="$1" arc="$DEST/volumes/$1.tar.gz" live rest n
  if [ ! -f "$arc" ]; then
    echo "  НЕ ПРОВЕРЕНО: архива $1.tar.gz нет в бэкапе"; note_skip "том $1: архива нет"; return
  fi
  if ! docker volume inspect "$vol" >/dev/null 2>&1; then
    echo "  НЕ ПРОВЕРЕНО: живого тома $vol нет, сверять не с чем"
    note_skip "том $1: живого тома нет, результат сверки неизвестен"; return
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
    note_skip "том $1: пуст, восстановление непустого тома не проверено"
  else
    echo "  том $1: $n файлов, содержимое совпало"
  fi
  docker volume rm -f "$TMPVOL" >/dev/null 2>&1 || true
}
verify_vol broker-local_cms-media
verify_vol broker-local_cabinet-uploads

# Оба тома контура сегодня пусты, то есть дорога «том → архив → том» на
# настоящих данных не проходилась НИ РАЗУ. Пустой результат — не
# доказательство, поэтому тот же путь прогоняется на заведомо непустом
# синтетическом томе: он проверяет механизм, а не данные, и это сказано
# вслух. Когда в медиа появятся файлы, проверка выше станет настоящей.
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

# --- 5. Git-бандлы ---------------------------------------------------------
# Смысл не в том, что бандл создался, а в том, что из него восстанавливается
# ветка, которой больше нигде нет. Ветка выбирается ПО СВОЙСТВУ (нет
# upstream), а не по имени: `web-01-local-run` с тех пор запушена, и проверка
# по имени осталась бы зелёной, перестав проверять то, ради чего написана.
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
  # Свойство, ради которого бандлы и нужны: коммиты ветки не достижимы НИ С
  # ОДНОГО remote. Третье поле в <repo>.branches.txt — их число.
  #
  # Раньше здесь стояло «ветка без upstream» (строка в один столбец), и это
  # был не тот признак: ветка задачи, слитая в main через --no-ff и
  # запушенная вместе с ним, upstream не имеет, а её коммиты на remote уже
  # лежат. Проверка печатала «существовала только на этой машине» о ветке,
  # которая существует и на GitHub, — утверждение сильнее, чем она знала.
  if [ -s "$DEST/repos/$r.branches.txt" ] && ! awk 'NF>=3' "$DEST/repos/$r.branches.txt" | grep -q .; then
    echo "  ВНИМАНИЕ: $r — бэкап старого формата, в branches.txt нет числа «только здесь»;"
    echo "            беру слабый признак (нет upstream), он завышает риск"
    want=$(awk 'NF==1 {print $1}' "$DEST/repos/$r.branches.txt" 2>/dev/null || true)
    note_skip "репозиторий $r: бэкап старого формата, свойство «существует только здесь» не проверялось"
  else
    want=$(awk 'NF>=3 && $3 ~ /^[0-9]+$/ && $3 > 0 {print $1}' "$DEST/repos/$r.branches.txt" 2>/dev/null || true)
  fi
  if [ -z "$want" ]; then
    echo "  $r: восстановился; веток, существующих только здесь, на момент бэкапа не было — проверять нечего"
  else
    for w in $want; do
      # в клоне бандла ветка приходит либо локальной (HEAD), либо как
      # origin/<имя> — восстановилась она в обоих случаях
      if echo "$have" | grep -qxF "$w" || echo "$have" | grep -qxF "origin/$w"; then
        echo "  $r: восстановилась ветка $w — её коммитов нет ни на одном remote"
        unpushed_checked=$((unpushed_checked+1))
      else
        echo "  ПРОВАЛ: $r — ветки '$w' (есть только здесь) нет в восстановленном репозитории"; FAIL=1
      fi
    done
  fi
done
[ "$bundles" -gt 0 ] || { echo "  НЕ ПРОВЕРЕНО: бандлов в бэкапе нет"; note_skip "git-бандлы: в бэкапе нет ни одного"; FAIL=1; }
if [ "$unpushed_checked" = 0 ] && [ "$bundles" -gt 0 ]; then
  echo "  ВНИМАНИЕ: ни одного коммита, которого нет на remote — проверено, что бандлы"
  echo "            клонируются, но не то, ради чего они нужны"
  note_skip "git-бандлы: нечего было спасать (всё есть на remote), главное свойство не проверено"
fi

# --- 6. Охват: источник против артефакта -----------------------------------
#
# QA-01 (19.10). Цикл выше перебирает то, что ЛЕЖИТ В БЭКАПЕ. Репозиторий, не
# попавший в бэкап вовсе, в этот перебор не войдёт — и проверка о нём
# промолчит: её входом служит артефакт, а не источник. Ровно тот же класс, что
# у соседей, где каталог ручек не входил в прогон тестов: вопрос не «есть ли
# проверка», а «входит ли материал в прогон».
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
    note_skip "репозиторий $n: в бэкап не попал — его история существует в одном экземпляре"
    FAIL=1
  done
  echo "  репозиториев на машине: $ondisk · бандлов в бэкапе: $bundles · без бандла: $nobundle"
else
  echo "  ОХВАТ НЕ ПРОВЕРЕН: каталога $ROOT_SRC нет — сверять список не с чем"
  note_skip "охват бандлов: исходный каталог недоступен, полнота бэкапа неизвестна"
fi

# --- Резюме ----------------------------------------------------------------
# Невыполненные проверки — первой строкой и ДО чисел: резюме читают вместо отчёта.
echo
if [ "$NOTCHECKED" -gt 0 ]; then
  echo "НЕ ПРОВЕРЕНО ($NOTCHECKED):"; printf "$NOTES\n"
fi
[ "$FAIL" = 0 ] && echo "=== ВОССТАНОВЛЕНИЕ ПРОВЕРЕНО ===" || { echo "=== ЕСТЬ РАСХОЖДЕНИЯ ==="; exit 1; }
