#!/usr/bin/env bash
# Обёртка над `docker compose` для ОДНОЙ ячейки платформы — по образцу
# site/compose.sh. Голым `docker compose` ячейку не поднимать.
#
#   ./cell.sh <slug> ps
#   ./cell.sh <slug> logs -f cell-web
#   ./cell.sh <slug> up -d
#   ./cell.sh <slug> --profile chain up -d cell-chain-watcher
#
# ЧТО ОНА СКЛАДЫВАЕТ:
#   1. общие ключи хаба (CMS_API_KEY, PREVIEW_SECRET, TRONGRID_API_KEY) —
#      ЧИТАЮТСЯ из site/.env Apex и экспортируются в окружение. Именно эти
#      три ключа, а не весь файл: подключи `--env-file site/.env` целиком —
#      и любая переменная, которой не хватило ячейке (SITE_DB_PASSWORD…),
#      молча взялась бы у Apex. Тихая подмена хуже отказа;
#   2. cells/<slug>/cell.env — параметры ячейки (адреса, слаг, сети), его
#      пишет platform-new.sh из анкеты, секретов в нём нет;
#   3. cells/<slug>/.env — секреты ячейки (600), рождены на хосте;
#   4. ревизии образов — cells/<slug>/.revision (сайт) и .revision-terminal.
#      Ячейка живёт СВОЕЙ ревизией: выкат Apex её не трогает.
#   Файл compose — cells/<slug>/compose.yml (копия шаблона на момент
#   создания), чтобы правка шаблона не меняла уже живые ячейки.
set -euo pipefail
export MSYS_NO_PATHCONV=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # читается в lib/common.sh
CELLS_DIR="$HERE"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

[ $# -ge 1 ] || { echo "использование: $0 <slug> <аргументы docker compose…>" >&2; exit 2; }
SLUG="$1"; shift
valid_slug "$SLUG" || die "«$SLUG» — не слаг ячейки"
load_hub_conf

DIR="$(cell_dir "$SLUG")"
for f in "$DIR/cell.env" "$DIR/.env" "$DIR/compose.yml"; do
    [ -f "$f" ] || die "нет $f — ячейка $SLUG не создана (platform-new.sh $SLUG)"
done

read_rev() {
    local f="$1" rev
    [ -f "$f" ] || die "нет $f — какую ревизию катим, неизвестно"
    rev="$(tr -d ' \n\r' < "$f")"
    [[ "$rev" =~ ^[0-9a-f]{40}$ ]] || die "в $f не полный хеш коммита: «$rev»"
    printf '%s' "$rev"
}
SITE_REVISION="$(read_rev "$DIR/.revision")"
TERMINAL_REVISION="$(read_rev "$DIR/.revision-terminal")"
export SITE_REVISION TERMINAL_REVISION

for k in CMS_API_KEY PREVIEW_SECRET TRONGRID_API_KEY; do
    v="$(env_get "$HUB_SITE_ENV" "$k")"
    export "$k=$v"
done

exec docker compose \
    --project-directory "$(hostpath "$DIR")" \
    -f "$(hostpath "$DIR/compose.yml")" \
    --env-file "$(hostpath "$DIR/cell.env")" \
    --env-file "$(hostpath "$DIR/.env")" \
    "$@"
