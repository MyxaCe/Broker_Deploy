#!/usr/bin/env bash
# ОДНОРАЗОВАЯ подготовка прокси хаба к ячейкам. Делает штаб, не владелец,
# и ровно один раз на хост (повторный запуск ничего не меняет).
#
#   ./hub-prepare.sh [--dry-run] [--yes] [--no-restart] [--proxy-dir DIR]
#
# ЧТО МЕНЯЕТ (и только это):
#   1. proxy/compose.yml — монтирует каталог proxy/sites в контейнер прокси
#      (`./sites:/etc/caddy/sites:ro`). Сегодня в контейнер смонтирован ОДИН
#      файл Caddyfile, и фрагменту ячейки положить себя некуда;
#   2. proxy/Caddyfile — ОДНА строка в конце: `import sites/*.caddy`. Блоки
#      Apex не трогаются. Пустой каталог sites/ Caddy принимает (предупреждение
#      в логе, не ошибка);
#   3. пересоздаёт контейнер прокси (`docker compose up -d`) — новый том
#      монтируется только так. ПРОСТОЙ ВСЕХ ИМЁН ≈ 2–5 СЕКУНД. Том
#      caddy-data (сертификаты) сохраняется, перевыпуска нет.
#
# Перед правкой — копии `*.bak-cells-<время>`, затем `caddy validate` нового
# конфига во временном контейнере: невалиден → копии возвращаются, прокси
# не перезапускается.
set -euo pipefail
export MSYS_NO_PATHCONV=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # читается в lib/common.sh
CELLS_DIR="$HERE"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

YES=0; RESTART=1; PDIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --yes) YES=1 ;;
        --no-restart) RESTART=0 ;;
        --proxy-dir) PDIR="$2"; shift ;;
        *) die "неизвестный ключ: $1" ;;
    esac
    shift
done
if [ -z "$PDIR" ]; then load_hub_conf; PDIR="$PROXY_DIR"; fi
CADDYFILE="$PDIR/Caddyfile"; PCOMPOSE="$PDIR/compose.yml"
[ -f "$CADDYFILE" ] || die "нет $CADDYFILE"
[ -f "$PCOMPOSE" ] || die "нет $PCOMPOSE"

MOUNT_LINE='./sites:/etc/caddy/sites:ro'
IMPORT_LINE='import sites/*.caddy'
need_mount=1; need_import=1
grep -qF "$MOUNT_LINE" "$PCOMPOSE" && need_mount=0
grep -qxF "$IMPORT_LINE" "$CADDYFILE" && need_import=0

say "Подготовка прокси хаба к ячейкам ($PDIR)"
[ -d "$PDIR/sites" ] || run mkdir -p "$PDIR/sites"
if [ $need_mount = 0 ] && [ $need_import = 0 ]; then
    say "  уже подготовлен: том sites/ смонтирован, строка import есть — менять нечего"
    exit 0
fi
say "  нужно: $([ $need_mount = 1 ] && echo 'том sites/ в compose.yml; ')$([ $need_import = 1 ] && echo 'строка import в Caddyfile; ')перезапуск прокси"
if [ $YES = 0 ] && [ "$DRY_RUN" = 0 ]; then
    printf '  Прокси перезапустится, все сайты недоступны ~5 секунд. Продолжить? [yes/N] '
    read -r ans; [ "$ans" = yes ] || die "отменено"
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
run cp -p "$CADDYFILE" "$CADDYFILE.bak-cells-$TS"
run cp -p "$PCOMPOSE" "$PCOMPOSE.bak-cells-$TS"

if [ $need_mount = 1 ]; then
    # Вставить строку тома сразу после строки с Caddyfile, с тем же отступом.
    grep -q '\./Caddyfile:/etc/caddy/Caddyfile' "$PCOMPOSE" || die "в $PCOMPOSE не найден том Caddyfile — правьте руками"
    if [ "$DRY_RUN" = 1 ]; then
        info "[dry-run] в $PCOMPOSE после тома Caddyfile: - $MOUNT_LINE"
    else
        # Перезапись ТЕМ ЖЕ inode (cat >), не sed -i: файл может быть смонтирован.
        tmp="$(mktemp)"
        awk -v add="$MOUNT_LINE" '{print} /\.\/Caddyfile:\/etc\/caddy\/Caddyfile/ {match($0,/^ */); printf "%s- %s\n", substr($0,1,RLENGTH), add}' "$PCOMPOSE" > "$tmp"
        cat "$tmp" > "$PCOMPOSE"; rm -f "$tmp"
    fi
fi
if [ $need_import = 1 ]; then
    if [ "$DRY_RUN" = 1 ]; then
        info "[dry-run] в конец $CADDYFILE: $IMPORT_LINE"
    else
        cat >> "$CADDYFILE" <<EOF

# ЯЧЕЙКИ ПЛАТФОРМ (вариант B). Каждая ячейка — файл proxy/sites/<slug>.caddy,
# его пишет cells/platform-new.sh и удаляет cells/platform-destroy.sh.
# Строка ПОСЛЕДНЯЯ: сниппет (adminonly) выше уже объявлен и виден фрагментам.
$IMPORT_LINE
EOF
    fi
fi

restore() {
    warn "возвращаю копии $TS"
    cp -p "$CADDYFILE.bak-cells-$TS" "$CADDYFILE.tmp" && cat "$CADDYFILE.tmp" > "$CADDYFILE" && rm -f "$CADDYFILE.tmp"
    cp -p "$PCOMPOSE.bak-cells-$TS" "$PCOMPOSE"
}

if [ "$DRY_RUN" = 0 ]; then
    domain="$(env_get "$PDIR/.env" DOMAIN)"; adminip="$(env_get "$PDIR/.env" ADMIN_IP)"
    if ! docker run --rm \
        -v "$(hostpath "$CADDYFILE"):/etc/caddy/Caddyfile:ro" \
        -v "$(hostpath "$PDIR/sites"):/etc/caddy/sites:ro" \
        -e DOMAIN="${domain:-example.com}" -e ADMIN_IP="${adminip:-127.0.0.1}" \
        caddy:2.10-alpine caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
        restore
        die "новый Caddyfile не прошёл caddy validate — ничего не применено"
    fi
    say "  caddy validate: ok"
fi

if [ $RESTART = 1 ]; then
    run docker compose --project-directory "$(hostpath "$PDIR")" -f "$(hostpath "$PCOMPOSE")" up -d
    if [ "$DRY_RUN" = 0 ]; then
        load_hub_conf 2>/dev/null || HUB_PROXY=broker-proxy
        sleep 2
        docker exec "$HUB_PROXY" test -d /etc/caddy/sites || die "в $HUB_PROXY нет /etc/caddy/sites — проверьте compose.yml"
        say "  прокси перезапущен, каталог sites/ виден внутри"
    fi
else
    say "  перезапуск пропущен (--no-restart)"
fi
say "Готово. Копии: *.bak-cells-$TS. После — обновить зеркало server/proxy/ в deploy."
