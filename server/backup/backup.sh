#!/bin/bash
# Снимок состояния платформы. Штаб, 23.10.2026.
#
# Правило, ради которого это написано до появления данных: бэкап, с которого
# ни разу не восстанавливались, бэкапом не является. Рядом лежит
# restore-check.sh, и он прогоняется по расписанию, а не «когда понадобится».
#
# Две вещи здесь написаны не сразу, а после того как сломались на проверке:
#
# 1. Имя пользователя базы читается ИЗ КОНТЕЙНЕРА, а не угадывается. Первая
#    редакция подставляла «postgres» и падала на базе, где пользователь другой.
#
# 2. Снимок собирается во ВРЕМЕННОМ каталоге и переименовывается только при
#    полном успехе. Иначе оборванный снимок становится «последним», проверка
#    восстановления берёт именно его, и последний хороший уходит из виду —
#    то есть отказ прячет сам себя.
#
# ДОБАВЛЕНО OPS-04/веха5 (01.11): тома с файлами и охват томов числом.
# Причина — ниже, у своих разделов. Коротко: KYC-документы (MinIO) жили ВНЕ
# бэкапа, а фильтр баз молча ронял все три дампа, когда тег образа отвязывался.
set -euo pipefail

DEST="${DEST:-/var/backups/broker}"
KEEP="${KEEP:-7}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TMP="$DEST/.nezavershyon-$STAMP"
OUT="$DEST/$STAMP"

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
mkdir -p "$TMP"
# Незавершённый каталог убираем при любом выходе: он не должен пережить отказ.
trap 'rm -rf "$TMP"' EXIT

found_db=0
# Базы ищем ПО РЕАЛЬНОМУ ОБРАЗУ контейнера, а не по колонке `docker ps`.
#
# Первая редакция читала `docker ps --format '{{.Image}}'` и фильтровала по
# подстроке `postgres`. Эта колонка печатает ИД-ХЕШ, когда тег образа отвязан
# от запущенного контейнера (перекачали тег — старый образ повис, но контейнер
# держит его по ид). 01.11 это и случилось: три базы на `postgres:16-alpine`
# показались как `f461079…`, фильтр их не нашёл, и снимок 02:30 ушёл БЕЗ
# единого дампа — restore-check в 03:30 именно поэтому вышел с кодом 2.
# `Config.Image` хранит ссылку, с которой контейнер создан, и ид в неё не
# подставляется: образ там не врёт, а колонка `docker ps` — может.
for c in $(docker ps --format '{{.Names}}'); do
    img="$(docker inspect -f '{{.Config.Image}}' "$c" 2>/dev/null || true)"
    case "$img" in *postgres*) ;; *) continue ;; esac
    found_db=1
    u="$(docker exec "$c" printenv POSTGRES_USER 2>/dev/null || true)"
    u="${u:-postgres}"
    log "база: $c (образ $img, пользователь $u)"
    docker exec "$c" pg_dumpall -U "$u" | gzip > "$TMP/db-$c.sql.gz"

    # Опись строк НА МОМЕНТ СНИМКА. Без неё проверка восстановления умеет
    # сказать только «таблицы есть» — и дамп, в котором одна структура без
    # единой строки, прошёл бы её молча. Сверка с этой описью превращает
    # проверку из «что-то восстановилось» в «восстановилось то же самое».
    # -d postgres обязателен. Без него psql идёт в базу, ОДНОИМЁННУЮ
    # пользователю: у терминала `terminal`/`terminal` совпало, у витрины
    # `broker`/`broker_site` и у CMS `cms`/`broker_cms` — нет, и перепись
    # строк для них молча не создавалась. Отказ внутри $( ) в заголовке
    # for не ловится ни set -e, ни pipefail: пустой список — законный цикл.
    # Совпадение имён скрывало отсутствие параметра до дня второй базы.
    for b in $(docker exec "$c" psql -U "$u" -d postgres -tAc \
        'select datname from pg_database where not datistemplate'); do
        for tb in $(docker exec "$c" psql -U "$u" -d "$b" -tAc \
            "select schemaname||'.'||tablename from pg_tables \
             where schemaname not in ('pg_catalog','information_schema')"); do
            n=$(docker exec "$c" psql -U "$u" -d "$b" -tAc "select count(*) from $tb" 2>/dev/null || echo "?")
            printf '%s\t%s\t%s\n' "$b" "$tb" "$n" >> "$TMP/rows-$c.tsv"
        done
    done
done
[ "$found_db" = 0 ] && log 'баз не найдено (машина ещё пустая — это не ошибка)'

# --- Тома с файлами: данных нет ни в одном дампе и ни в одном репозитории ----
#
# KYC-документы живут в MinIO (том `broker-site_minio-data`), срок хранения
# пять лет — это критичные данные, и до 01.11 они были ВНЕ бэкапа вовсе:
# дамп их не видит (это не Postgres), а `config.tar.gz` берёт только
# `/srv/broker`, а не тома Docker. Рядом по той же причине — загрузки кабинета
# и медиа CMS: файлы, которых нет ни в репозитории, ни в базе.
#
# Снимается одноразовым alpine, том смонтирован ТОЛЬКО НА ЧТЕНИЕ: контейнер
# бэкапа не может испортить данные. Опись (число файлов + свёртка) снимается
# тем же монтированием — её сверяет restore-check, превращая «архив есть» в
# «из архива восстанавливается тот же том».
#
# Горячий снимок MinIO допустим: объекты MinIO пишет во временный файл с
# переименованием, поэтому tar на лету целостен по объектам. Останавливать
# MinIO ради снимка не требуется. Это согласуется с тем, как зона уже
# бэкапит media/uploads локального контура.
#
# `broker-vault_vault-data` — том OpenBao (raft/BoltDB). Добавлен сюда при
# сведении с живым стендом (OPS-24): правка жила на машине со времён Р-456 B,
# а в репозитории её не было. Данные в томе зашифрованы барьером Vault, но
# горячий tar BoltDB может быть не полностью согласован — честнее `bao operator
# raft snapshot` отдельным шагом; вынесено в долг (см. proposed/vault/README.md).
VOL_ARCHIVE="broker-site_minio-data broker-site_cabinet-uploads broker-cms_media broker-vault_vault-data"
for v in $VOL_ARCHIVE; do
    docker volume inspect "$v" >/dev/null 2>&1 \
        || { log "  том $v: на машине нет — пропуск"; continue; }
    docker run --rm -v "$v":/src:ro -v "$TMP":/out alpine sh -c \
        'cd /src && tar czf "/out/vol-'"$v"'.tar.gz" . && \
         { find . -type f | sort | xargs -r md5sum | md5sum | cut -d" " -f1; \
           find . -type f | wc -l; } > "/out/vol-'"$v"'.census"'
    log "  том $v: $(du -h "$TMP/vol-$v.tar.gz" | cut -f1), файлов $(tail -1 "$TMP/vol-$v.census" | tr -d ' ')"
done

log 'конфигурация'
tar czf "$TMP/config.tar.gz" -C /srv broker

# Контрольные суммы: «файл есть» не значит «файл цел».
( cd "$TMP" && sha256sum ./* > SHA256SUMS )

{
    echo "снимок: $STAMP"
    echo "хост:   $(hostname)"
    ls -lh "$TMP" | tail -n +2
} > "$TMP/MANIFEST.txt"

# Переименование — последнее действие. До него снимка «не существует».
mv "$TMP" "$OUT"
trap - EXIT
log "готово: $OUT ($(du -sh "$OUT" | cut -f1))"

ls -1dt "$DEST"/*/ 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -rf
log "снимков хранится: $(ls -1d "$DEST"/*/ 2>/dev/null | wc -l)"

# --- Охват томов объявлен ЧИСЛОМ --------------------------------------------
#
# Списки томов ведутся руками. Новый том не даёт ни ошибки, ни пустого файла:
# он просто не попадает в снимок молча — ровно тот отказ, против которого
# написан и этот скрипт, и restore-check. Поэтому перечень берётся из Docker и
# сверяется со списками. Том, не попавший ни в архив (VOL_ARCHIVE), ни в дамп
# БД (VOL_BY_DUMP), ни в список «восстановимо иначе» (VOL_COVERED_OTHERWISE),
# называется вслух — и снимок при этом считается НЕПОЛНЫМ (код возврата ≠ 0),
# хотя сам каталог уже создан: частичный снимок лучше никакого, но зелёным
# не зовётся. Снимок уже на месте — наблюдателю видно расхождение, а не пустота.
VOL_BY_DUMP="broker-site_db-data broker-cms_db-data broker-terminal_pgdata"
# Почему эти восстановимы без архива:
#   bus_data        — топология шины провижинится кодом (bus/bus-setup.sh)
#   cache_data      — Redis-кеш, по смыслу эфемерен, отстраивается заново
#   mds_registry    — реестр MDS, сегодня пуст; появятся данные — в VOL_ARCHIVE
#   monitoring_*    — TSDB Prometheus, дашборды Grafana, состояние Alertmanager
#                     и журнал оповещений: наблюдательское состояние, конфиг в
#                     репозитории, история восстанавливается самим наблюдением
#   caddy-data/-config — сертификаты (переполучаются у Let's Encrypt) и конфиг
#                     (в репозитории)
VOL_COVERED_OTHERWISE="broker-bus_data broker-cache_data broker-mds_registry \
broker-monitoring_prometheus-data broker-monitoring_grafana-data \
broker-monitoring_alertmanager-data broker-monitoring_alert-log \
proxy_caddy-data proxy_caddy-config"
nepokryto=0
for v in $(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E '^(broker-|proxy_)' || true); do
    case " $VOL_ARCHIVE $VOL_BY_DUMP $VOL_COVERED_OTHERWISE " in
        *" $v "*) continue ;;
    esac
    nepokryto=$((nepokryto + 1))
    log "  ТОМ ВНЕ ОХВАТА: $v — ни в архиве, ни в дампе, ни в списке восстановимых."
done
log "охват томов: архивом $(echo $VOL_ARCHIVE | wc -w), дампом БД $(echo $VOL_BY_DUMP | wc -w), восстановимо иначе $(echo $VOL_COVERED_OTHERWISE | wc -w), ВНЕ ОХВАТА $nepokryto"
if [ "$nepokryto" -gt 0 ]; then
    log "СНИМОК НЕПОЛОН: томов вне охвата $nepokryto — внести их в список выше и решить, как резервировать."
    exit 1
fi
