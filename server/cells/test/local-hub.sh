#!/usr/bin/env bash
# Локальный хаб для проверки ячейки без стенда (Docker Desktop / любой docker).
#
#   test/local-hub.sh up      — сгенерировать секреты хаба, поднять cellt-*
#   test/local-hub.sh down    — снести хаб (ячейки сносить platform-destroy.sh)
#   test/local-hub.sh env     — напечатать export CELLS_HUB_CONF=… для скриптов
#
# Каталог хаба — test/.hub (в .gitignore). Там же лежат экземпляры ячеек
# (CELLS_HOME), чтобы локальный прогон не мусорил в server/cells/.
# Портов наружу хаб не открывает.
set -euo pipefail
export MSYS_NO_PATHCONV=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && { pwd -W 2>/dev/null || pwd; })"
CELLS_DIR="$(cd "$HERE/.." && pwd)"
HUB_DIR="${HUB_DIR:-$HERE/.hub}"
COMPOSE=(docker compose -p cellt-hub -f "$HERE/local-hub.compose.yml")

rand() { openssl rand -hex "${1:-16}"; }

gen_hub() {
    mkdir -p "$HUB_DIR"/{site,terminal,bus,cms,proxy/sites,cells}
    [ -f "$HUB_DIR/site/.env" ] || cat > "$HUB_DIR/site/.env" <<EOF
CMS_API_KEY=$(rand)
PREVIEW_SECRET=$(rand)
CMS_WEBHOOK_SECRET=$(rand)
TRONGRID_API_KEY=
EOF
    [ -f "$HUB_DIR/bus/.env" ] || cat > "$HUB_DIR/bus/.env" <<EOF
BUS_ADMIN_USER=bus-admin
BUS_ADMIN_PASSWORD=$(rand)
EOF
    [ -f "$HUB_DIR/cms/.env" ] || cat > "$HUB_DIR/cms/.env" <<EOF
CMS_DB_PASSWORD=$(rand)
PAYLOAD_SECRET=$(rand 32)
SEED_ADMIN_EMAIL=admin@cellt.example.com
SEED_ADMIN_PASSWORD=$(rand)
EOF
    # ADMIN_IP — заведомо НЕ адрес клиента-проверки: admin/files обязаны дать 403.
    [ -f "$HUB_DIR/proxy/.env" ] || printf 'DOMAIN=cellt.test\nADMIN_IP=203.0.113.7\n' > "$HUB_DIR/proxy/.env"
    echo de62e7b9fd72ea4faff1a8b2ec1e00d748e4ee20 > "$HUB_DIR/site/.revision"
    echo 77501e01904054219e1c5bac54e2731b901354ae > "$HUB_DIR/terminal/.revision"

    # Caddyfile = боевой Caddyfile стенда (зеркало OPS-24) + подготовка хаба
    # (hub-prepare.sh: строка import) + внутренний CA вместо ACME.
    if [ ! -f "$HUB_DIR/proxy/Caddyfile" ]; then
        tr -d '\r' < "$CELLS_DIR/../proxy/Caddyfile" > "$HUB_DIR/proxy/Caddyfile"
        tr -d '\r' < "$CELLS_DIR/../proxy/compose.yml" > "$HUB_DIR/proxy/compose.yml"
        "$CELLS_DIR/hub-prepare.sh" --proxy-dir "$HUB_DIR/proxy" --no-restart --yes
        sed -i 's/^\temail admin@{\$DOMAIN}$/\temail admin@{$DOMAIN}\n\tlocal_certs/' "$HUB_DIR/proxy/Caddyfile"
    fi

    cat > "$HUB_DIR/hub.conf" <<EOF
# ЛОКАЛЬНЫЙ hub.conf (генерирует test/local-hub.sh). Не для стенда.
HUB_ROOT=$HUB_DIR
PUBLIC_IP=127.0.0.1
EDGE_NET=cellt-edge
BACK_NET=cellt-back
HUB_CMS=cellt-cms
HUB_MDS=cellt-mds
HUB_BUS=cellt-bus
HUB_PROXY=cellt-proxy
HUB_SITE_ENV=$HUB_DIR/site/.env
HUB_BUS_ENV=$HUB_DIR/bus/.env
HUB_CMS_ENV=$HUB_DIR/cms/.env
PROXY_DIR=$HUB_DIR/proxy
HUB_SITE_REVISION_FILE=$HUB_DIR/site/.revision
HUB_TERMINAL_REVISION_FILE=$HUB_DIR/terminal/.revision
TEMPLATE_SITE=apex-ru
CELL_ADMIN_ALLOW=""
PYTHON_IMAGE=python:3.12-slim
DNS_CHECK=0
CERT_CHECK=0
CERT_WAIT_SEC=30
MIN_FREE_MB=500
CELLS_HOME=$HUB_DIR/cells
EOF
}

envs() {
    set -a
    # shellcheck disable=SC1091
    . "$HUB_DIR/cms/.env"; . "$HUB_DIR/site/.env"; . "$HUB_DIR/bus/.env"; . "$HUB_DIR/proxy/.env"
    set +a
    export HUB_DIR
}

case "${1:-}" in
    up)
        gen_hub
        for n in cellt-edge cellt-back; do
            docker network inspect "$n" >/dev/null 2>&1 || docker network create "$n" >/dev/null
        done
        envs
        "${COMPOSE[@]}" up -d
        echo "хаб поднят. Для скриптов ячейки:"
        echo "  export CELLS_HUB_CONF=$HUB_DIR/hub.conf"
        ;;
    down)
        if [ -f "$HUB_DIR/cms/.env" ]; then envs; "${COMPOSE[@]}" down -v; fi
        for n in cellt-edge cellt-back; do docker network rm "$n" >/dev/null 2>&1 || true; done
        ;;
    env) echo "export CELLS_HUB_CONF=$HUB_DIR/hub.conf" ;;
    *) echo "использование: $0 up|down|env" >&2; exit 2 ;;
esac
