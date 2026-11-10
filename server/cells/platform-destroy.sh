#!/usr/bin/env bash
# УДАЛЕНИЕ ПЛАТФОРМЫ (ячейки). Только из консоли хоста — в вебе такой кнопки
# нет и до показа не будет: это потеря данных клиентов.
#
#   ./platform-destroy.sh <slug>               — спросит слаг ещё раз
#   ./platform-destroy.sh <slug> --dry-run     — показать, что было бы удалено
#   ./platform-destroy.sh <slug> --keep-cms    — сайт и контент в CMS оставить
#   ./platform-destroy.sh <slug> --confirm <slug>   — без вопроса (репетиции)
#
# Порядок: КОПИЯ → снять с прокси → остановить и удалить контейнеры и тома →
# vhost и кредлы шины → сайт в CMS → каталог ячейки в архив.
# Копия перед удалением: pg_dump базы сайта и базы терминала (денежный
# журнал), архив тома KYC-хранилища, .env/анкета ячейки — в
# cells/_destroyed/<slug>-<время>/ (700). Без копии удаление не идёт.
#
# Apex (apex-ru) этим скриптом не удаляется НИКОГДА: слаг в списке запретных.
set -euo pipefail
export MSYS_NO_PATHCONV=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # читается в lib/common.sh
CELLS_DIR="$HERE"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=lib/bus.sh
. "$HERE/lib/bus.sh"
# shellcheck source=lib/proxy.sh
. "$HERE/lib/proxy.sh"

[ $# -ge 1 ] || { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
CELL_SLUG="$1"; shift
KEEP_CMS=0; CONFIRM=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --keep-cms) KEEP_CMS=1 ;;
        --confirm) CONFIRM="${2:-}"; shift ;;
        *) die "неизвестный ключ: $1" ;;
    esac
    shift
done
valid_slug "$CELL_SLUG" || die "«$CELL_SLUG» — не слаг ячейки (или запретное имя)"
load_hub_conf
DIR="$(cell_dir "$CELL_SLUG")"
[ -d "$DIR" ] || die "ячейки $CELL_SLUG нет ($DIR)"
load_platform_conf "$CELL_SLUG" || true
# shellcheck disable=SC2034  # читается в step() из lib/common.sh
STEP_TOTAL=6

say "${C_ERR}${C_B}УДАЛЕНИЕ ПЛАТФОРМЫ $CELL_SLUG${C_0} «${BRAND_NAME:-?}» $([ "$DRY_RUN" = 1 ] && echo '(СУХОЙ ПРОГОН)')"
say "  Будут удалены: контейнеры broker-*-$CELL_SLUG, базы сайта и терминала, KYC-хранилище,"
say "  vhost шины cell-$CELL_SLUG, адреса ${SITE_HOST:-?} и др. в прокси$([ $KEEP_CMS = 0 ] && echo ', сайт в CMS')."
if [ "$DRY_RUN" = 0 ]; then
    if [ -z "$CONFIRM" ]; then
        printf '  Для подтверждения введите слаг платформы: '
        read -r CONFIRM
    fi
    [ "$CONFIRM" = "$CELL_SLUG" ] || die "подтверждение не совпало — ничего не удалено"
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
ARCH="$(cell_dir _destroyed)/$CELL_SLUG-$TS"

step "Копия перед удалением"
run mkdir -p "$ARCH"
[ "$DRY_RUN" = 1 ] || chmod 700 "$(cell_dir _destroyed)" "$ARCH"
dumped=0
for pair in "broker-db-site-$CELL_SLUG:broker:broker_site:site" "broker-db-terminal-$CELL_SLUG:terminal:terminal:terminal"; do
    IFS=: read -r c u d name <<<"$pair"
    if container_running "$c"; then
        if [ "$DRY_RUN" = 1 ]; then run docker exec "$c" pg_dump -U "$u" -d "$d" ">" "$ARCH/$name.sql.gz"
        else
            docker exec "$c" pg_dump -U "$u" -d "$d" | gzip > "$ARCH/$name.sql.gz" || step_fail "pg_dump $c не удался — удаление остановлено"
            [ -s "$ARCH/$name.sql.gz" ] || step_fail "пустая копия $name — удаление остановлено"
            info "база $name → $ARCH/$name.sql.gz ($(du -h "$ARCH/$name.sql.gz" | cut -f1))"
        fi
        dumped=$((dumped + 1))
    else
        warn "$c не запущен — копию базы $name снять нельзя"
    fi
done
vol="broker-cell-${CELL_SLUG}_minio-data"
if docker volume inspect "$vol" >/dev/null 2>&1; then
    run docker run --rm -v "$vol:/d:ro" -v "$(hostpath "$ARCH"):/out" postgres:16-alpine tar czf /out/kyc-store.tgz -C /d .
    info "том KYC → $ARCH/kyc-store.tgz"
fi
for f in .env platform.conf cell.env .revision .revision-terminal; do
    [ -f "$DIR/$f" ] && run cp -p "$DIR/$f" "$ARCH/$f"
done
if [ $dumped -eq 0 ] && [ "$DRY_RUN" = 0 ] && docker volume inspect "broker-cell-${CELL_SLUG}_site-db-data" >/dev/null 2>&1; then
    step_fail "тома баз есть, а контейнеры баз не запущены — копию снять нельзя. Поднимите базы: $HERE/cell.sh $CELL_SLUG up -d cell-site-db cell-term-db — и повторите"
fi
step_ok "копия в $ARCH"

step "Снять адреса с прокси"
proxy_remove "$CELL_SLUG"
step_ok "фрагмент прокси удалён, прокси перечитал конфигурацию"

step "Контейнеры и тома ячейки"
if [ -f "$DIR/compose.yml" ] && [ -f "$DIR/cell.env" ] && [ -f "$DIR/.env" ]; then
    run "$HERE/cell.sh" "$CELL_SLUG" --profile chain down -v --remove-orphans
else
    warn "нет compose/env ячейки — удаляю контейнеры по имени"
    for c in $(docker ps -a --format '{{.Names}}' | grep -E -- "-$CELL_SLUG\$" | grep '^broker-' || true); do run docker rm -f "$c"; done
fi
step_ok "контейнеры и тома удалены"

step "Шина"
bus_destroy "$CELL_SLUG"
step_ok "vhost cell-$CELL_SLUG и кредлы удалены"

step "CMS"
if [ $KEEP_CMS = 1 ]; then
    step_skip "сайт в CMS оставлен (--keep-cms): повторный platform-new.sh подхватит его и не перезальёт опубликованное"
else
    CMS_ADMIN_EMAIL="$(env_get "$HUB_CMS_ENV" SEED_ADMIN_EMAIL)"; CMS_ADMIN_PASSWORD="$(env_get "$HUB_CMS_ENV" SEED_ADMIN_PASSWORD)"
    export CMS_ADMIN_EMAIL CMS_ADMIN_PASSWORD
    dry=(); [ "$DRY_RUN" = 1 ] && dry=(--dry-run)
    docker run --rm --network "$BACK_NET" -e CMS_ADMIN_EMAIL -e CMS_ADMIN_PASSWORD \
        -v "$(hostpath "$HERE/lib/cms-clone.py"):/w/cms-clone.py:ro" "$PYTHON_IMAGE" \
        python -I /w/cms-clone.py --base "http://$HUB_CMS:3001" "${dry[@]}" delete --slug "$CELL_SLUG" \
        | sed '/^RESULT /d' || step_fail "сайт в CMS не удалён"
    step_ok "сайт $CELL_SLUG и его контент удалены из CMS"
fi

step "Каталог ячейки"
run mv "$DIR" "$ARCH/cell-dir"
# Анкету (секретов в ней нет) оставляем на месте: репетиция «удалить и
# создать заново» = один повторный platform-new.sh. Секреты новые.
if [ -f "$ARCH/platform.conf" ]; then
    run mkdir -p "$DIR"
    run cp -p "$ARCH/platform.conf" "$DIR/platform.conf"
fi
step_ok "каталог перенесён в $ARCH/cell-dir; анкета оставлена в $DIR/platform.conf"

say ""
if [ "$DRY_RUN" = 1 ]; then say "${C_B}Сухой прогон: ничего не удалено.${C_0}"; exit 0; fi
say "${C_OK}Платформа $CELL_SLUG удалена.${C_0} Копия: $ARCH"
say "  Записи DNS в GoDaddy можно оставить — без блока в прокси они никуда не ведут."
