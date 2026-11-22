#!/bin/bash
set -euo pipefail

DEST="${DEST:-/var/backups/broker}"
KEEP="${KEEP:-7}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TMP="$DEST/.nezavershyon-$STAMP"
OUT="$DEST/$STAMP"

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

found_db=0
for c in $(docker ps --format '{{.Names}}'); do
    img="$(docker inspect -f '{{.Config.Image}}' "$c" 2>/dev/null || true)"
    case "$img" in *postgres*) ;; *) continue ;; esac
    found_db=1
    u="$(docker exec "$c" printenv POSTGRES_USER 2>/dev/null || true)"
    u="${u:-postgres}"
    log "база: $c (образ $img, пользователь $u)"
    docker exec "$c" pg_dumpall -U "$u" | gzip > "$TMP/db-$c.sql.gz"

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

( cd "$TMP" && sha256sum ./* > SHA256SUMS )

{
    echo "снимок: $STAMP"
    echo "хост:   $(hostname)"
    ls -lh "$TMP" | tail -n +2
} > "$TMP/MANIFEST.txt"

mv "$TMP" "$OUT"
trap - EXIT
log "готово: $OUT ($(du -sh "$OUT" | cut -f1))"

ls -1dt "$DEST"/*/ 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -rf
log "снимков хранится: $(ls -1d "$DEST"/*/ 2>/dev/null | wc -l)"

VOL_BY_DUMP="broker-site_db-data broker-cms_db-data broker-terminal_pgdata"
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
