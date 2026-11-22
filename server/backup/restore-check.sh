#!/bin/bash
set -euo pipefail

DEST="${DEST:-/var/backups/broker}"
LAST="$(ls -1dt "$DEST"/*/ 2>/dev/null | head -1 || true)"
fail() { echo "ПРОВЕРКА НЕ ПРОЙДЕНА: $*" >&2; exit 1; }

[ -n "$LAST" ] || fail 'снимков нет вовсе'
echo "проверяю снимок: $LAST"

( cd "$LAST" && sha256sum -c SHA256SUMS --quiet ) || fail 'контрольные суммы не сошлись'
echo '  суммы сошлись'

dumps=$(ls -1 "$LAST"/db-*.sql.gz 2>/dev/null | wc -l)
if [ "$dumps" = 0 ]; then
    echo '  ДАМПОВ БАЗ НЕТ — восстанавливать не на чем.'
    echo '  Это НЕ успех: появится первая база — проверка обязана начать'
    echo '  восстанавливать. Выхожу с кодом 2, чтобы это было видно.'
    exit 2
fi

NAME="restore-check-$$"
TMPVOL="restore-check-vol-$$"
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true; docker volume rm -f "$TMPVOL" >/dev/null 2>&1 || true' EXIT
docker run -d --name "$NAME" -e POSTGRES_PASSWORD=checkonly postgres:16-alpine >/dev/null
/srv/broker/backup/wait-pg.sh "$NAME" postgres || fail 'временная база не поднялась'

for d in "$LAST"/db-*.sql.gz; do
    echo "  вливаю: $(basename "$d")"
    gunzip -c "$d" | docker exec -i "$NAME" psql -U postgres -q >/dev/null 2>&1 \
        || fail "дамп $(basename "$d") не влился"
done

vsego=0
for b in $(docker exec "$NAME" psql -U postgres -tAc \
    'select datname from pg_database where not datistemplate'); do
    n=$(docker exec "$NAME" psql -U postgres -d "$b" -tAc \
        "select count(*) from pg_tables where schemaname not in ('pg_catalog','information_schema')")
    [ "${n:-0}" -gt 0 ] && echo "    база $b: таблиц $n"
    vsego=$((vsego + ${n:-0}))
done

[ "$vsego" -gt 0 ] || fail 'дампы влились, но ни в одной базе нет таблиц'

rashod=0
for opis in "$LAST"/rows-*.tsv; do
    [ -e "$opis" ] || continue
    while IFS=$'\t' read -r b tb bylo; do
        [ "$bylo" = '?' ] && continue
        stalo=$(docker exec "$NAME" psql -U postgres -d "$b" -tAc "select count(*) from $tb" 2>/dev/null || echo 'НЕТ')
        if [ "$stalo" != "$bylo" ]; then
            echo "    расхождение: $b $tb — было $bylo, стало $stalo" >&2
            rashod=$((rashod + 1))
        fi
    done < "$opis"
done
[ "$rashod" = 0 ] || fail "строки не сошлись в $rashod таблицах"

tomov=0; tom_pusto=0
for arc in "$LAST"/vol-*.tar.gz; do
    [ -e "$arc" ] || continue
    tomov=$((tomov + 1))
    v="$(basename "$arc" .tar.gz)"; v="${v#vol-}"
    opis="$LAST/vol-$v.census"
    [ -e "$opis" ] || fail "том $v: архив есть, описи vol-$v.census нет — сверять не с чем"
    docker volume rm -f "$TMPVOL" >/dev/null 2>&1 || true
    docker volume create "$TMPVOL" >/dev/null
    docker run --rm -v "$TMPVOL":/dst -v "$LAST":/in:ro alpine \
        tar xzf "/in/vol-$v.tar.gz" -C /dst 2>/dev/null \
        || fail "том $v не распаковался из архива"
    stalo=$(docker run --rm -v "$TMPVOL":/m:ro alpine sh -c \
        'cd /m && { find . -type f | sort | xargs -r md5sum | md5sum | cut -d" " -f1; find . -type f | wc -l; }')
    bylo="$(cat "$opis")"
    if [ "$(echo "$stalo" | tr -s ' ' | tr -d ' ')" != "$(echo "$bylo" | tr -s ' ' | tr -d ' ')" ]; then
        echo "    расхождение тома $v: опись '$(echo $bylo)' против восстановленного '$(echo $stalo)'" >&2
        rashod=$((rashod + 1))
    else
        chislo=$(echo "$stalo" | tail -1 | tr -d ' ')
        if [ "$chislo" = 0 ]; then
            echo "  том $v: ПУСТО — файлов нет; восстановление непустого тома не проверено"
            tom_pusto=$((tom_pusto + 1))
        else
            echo "  том $v: $chislo файлов, содержимое совпало с описью снимка"
        fi
    fi
    docker volume rm -f "$TMPVOL" >/dev/null 2>&1 || true
done
[ "$rashod" = 0 ] || fail "тома не сошлись с описью снимка"

strok=$(cat "$LAST"/rows-*.tsv 2>/dev/null | awk -F'\t' '$3 != "?" {s += $3} END {print s + 0}')
echo "ВОССТАНОВЛЕНИЕ ПРОВЕРЕНО: дампов $dumps, таблиц $vsego, строк сошлось $strok, томов $tomov (из них пустых $tom_pusto)"
