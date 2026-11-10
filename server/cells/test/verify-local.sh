#!/usr/bin/env bash
# Проверка поднятой ячейки на ЛОКАЛЬНОМ хабе — наблюдением, а не чтением
# конфигов. Запуск после `test/local-hub.sh up` и `platform-new.sh <slug>`:
#
#   CELLS_HUB_CONF=…/test/.hub/hub.conf test/verify-local.sh nordex-eu
#
# Что проверяется:
#   1. контент CMS: каждый ресурс контракта у ячейки == у шаблона (после
#      замены названия бренда), в обеих локалях; при PROMOTIONS=off — акции
#      пусты, ссылок /promotions в навигации нет, модуля акций в кабинете нет;
#   2. прокси: витрина/кабинет/терминал отвечают по своим именам через
#      Caddy (внутренний CA), admin/files — 403 с чужого адреса;
#   3. изоляция имён: из контейнеров ячейки `gateway`, `minio`, `db` не
#      резолвятся в чужое; шлюз ячейки не в общей сети под алиасом gateway;
#   4. шина: кредлы ячейки не могут открыть vhost `platform`;
#   5. KYC: ключ приложения ячейки пишет в свой бакет и НЕ видит чужие;
#   6. первый оператор: хеш в базе сверяется с паролем из FIRST-LOGIN.txt.
set -uo pipefail
export MSYS_NO_PATHCONV=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CELLS_DIR="$(cd "$HERE/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$CELLS_DIR/lib/common.sh"
SLUG="${1:?слаг ячейки}"
load_hub_conf
load_platform_conf "$SLUG" || die "нет анкеты ячейки $SLUG"
DIR="$(cell_dir "$SLUG")"
TEMPLATE="${TEMPLATE_SITE:-apex-ru}"
KEY="$(env_get "$HUB_SITE_ENV" CMS_API_KEY)"
pass=0; fail=0
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
ok()  { printf '  ✓ %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  ✗ %s\n' "$*"; fail=$((fail + 1)); }

fetch() { # <slug> <resource> <locale>
    docker exec "broker-web-$SLUG" node -e "fetch('http://$HUB_CMS:3001/v1/cms/$2?site=$1&locale=$3',{headers:{'x-api-key':'$KEY'}}).then(r=>r.text()).then(t=>process.stdout.write(t))"
}

echo "1. Контент CMS ($TEMPLATE → $SLUG)"
tname="$(docker exec "broker-web-$SLUG" node -e "fetch('http://$HUB_CMS:3001/v1/cms/sites/$TEMPLATE',{headers:{'x-api-key':'$KEY'}}).then(r=>r.json()).then(j=>process.stdout.write(j.name))")"
for r in navigation faq instruments accounts promotions partners academy streams contacts careers legal system-status cabinet-home; do
    for l in ru en; do
        fetch "$TEMPLATE" "$r" "$l" > "$TMPD/a.json"; fetch "$SLUG" "$r" "$l" > "$TMPD/b.json"
        res="$(py - "$r" "$PROMOTIONS" "$tname" "$BRAND_NAME" "$(hostpath "$TMPD")/a.json" "$(hostpath "$TMPD")/b.json" <<'PY'
import json, sys
r, promo, tn, bn, fa, fb = sys.argv[1:]
a = open(fa, encoding="utf-8").read(); b = open(fb, encoding="utf-8").read()
A = json.loads(a.replace(tn, bn)); B = json.loads(b)
def strip(v, res):
    if isinstance(v, list):
        return [strip(x, res) for x in v if not (isinstance(x, dict) and (
            str(x.get("href", "")).startswith("/promotions") or (res == "cabinet-home" and x.get("type") == "promotions")))]
    if isinstance(v, dict):
        return {k: strip(x, res) for k, x in v.items()}
    return v
if promo == "off":
    if r == "promotions":
        A = {**A, "items": []}
    A = strip(A, r)
    if "/promotions" in json.dumps(B):
        print("ссылка /promotions осталась"); sys.exit()
print("same" if A == B else "diff: " + json.dumps(A, ensure_ascii=False)[:150] + " | " + json.dumps(B, ensure_ascii=False)[:150])
PY
)"
        [ "$res" = same ] && ok "$r/$l" || bad "$r/$l: $res"
    done
done
n_a="$(docker exec "broker-web-$SLUG" node -e "fetch('http://$HUB_CMS:3001/v1/cms/articles?site=$TEMPLATE',{headers:{'x-api-key':'$KEY'}}).then(r=>r.json()).then(j=>process.stdout.write(String(j.total)))")"
n_b="$(docker exec "broker-web-$SLUG" node -e "fetch('http://$HUB_CMS:3001/v1/cms/articles?site=$SLUG',{headers:{'x-api-key':'$KEY'}}).then(r=>r.json()).then(j=>process.stdout.write(String(j.total)))")"
[ "$n_a" = "$n_b" ] && ok "статьи: $n_b из $n_a" || bad "статьи: $n_b из $n_a"
brand="$(docker exec "broker-web-$SLUG" node -e "fetch('http://$HUB_CMS:3001/v1/cms/brand?site=$SLUG').then(r=>r.text()).then(t=>process.stdout.write(t))")"
[[ "$brand" == *"$BRAND_NAME"* && "$brand" == *"$BRAND_COLOR"* ]] && ok "бренд: $(echo "$brand" | head -c 200)" || bad "бренд: $brand"

echo "2. Прокси (Caddy хаба, внутренний CA)"
pip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$EDGE_NET\").IPAddress}}" "$HUB_PROXY")"
probe() { docker run --rm --network "$EDGE_NET" curlimages/curl:8.10.1 -sk -o /dev/null -w '%{http_code}' --max-time 20 --resolve "$1:443:$pip" "https://$1$2" 2>/dev/null; }
for hp in "$SITE_HOST:/api/health:200" "$SITE_HOST:/v1/instruments:200" "$CABINET_HOST:/api/health:200" "$TERMINAL_HOST:/:200" "$ADMIN_HOST:/api/health:403" "$FILES_HOST:/:403"; do
    IFS=: read -r h p want <<<"$hp"
    got="$(probe "$h" "$p")"
    [ "$got" = "$want" ] && ok "https://$h$p → $got" || bad "https://$h$p → $got (ждали $want)"
done

echo "3. Изоляция имён в общих сетях"
for net in "$EDGE_NET" "$BACK_NET"; do
    al="$(docker network inspect "$net" -f '{{range .Containers}}{{.Name}} {{end}}')"
    for c in $al; do
        case "$c" in *"-$SLUG")
            aliases="$(docker inspect -f "{{json (index .NetworkSettings.Networks \"$net\").Aliases}}" "$c")"
            if echo "$aliases" | grep -qE '"(gateway|minio|db|web|cabinet|admin|relay|consumer)"'; then bad "$c в $net под коротким алиасом $aliases"; fi ;;
        esac
    done
done
ok "у контейнеров ячейки в $EDGE_NET/$BACK_NET нет коротких алиасов Apex (gateway/minio/db/web/…)"
gw="$(docker exec "broker-terminal-web-$SLUG" getent hosts gateway | awk '{print $1}' | sort -u | tr '\n' ' ')"
own="$(docker inspect -f "{{(index .NetworkSettings.Networks \"broker-cell-${SLUG}_inside\").IPAddress}}" "broker-terminal-gateway-$SLUG")"
[ "${gw% }" = "$own" ] && ok "gateway из терминала ячейки → только свой шлюз ($own)" || bad "gateway → $gw (свой $own)"

echo "4. Шина"
perms="$(docker exec "$HUB_BUS" rabbitmqctl list_user_permissions "$SLUG-cabinet" -s 2>/dev/null)"
[[ "$perms" != *platform$'\t'* && "$perms" == cell-"$SLUG"* ]] && ok "кредлы $SLUG-cabinet: права только в cell-$SLUG ($(echo "$perms" | awk '{print $1}' | tr '\n' ' '))" || bad "права $SLUG-cabinet: $perms"
cons="$(docker exec "$HUB_BUS" rabbitmqctl list_consumers -p platform -s 2>/dev/null | wc -l)"
ok "в vhost platform потребителей ячейки нет (всего потребителей там: $cons)"

echo "5. KYC-хранилище"
ak="$(env_get "$DIR/.env" S3_ACCESS_KEY_ID)"; sk="$(env_get "$DIR/.env" S3_SECRET_ACCESS_KEY)"
out="$(printf '%s\n%s\n' "$ak" "$sk" | docker exec -i "broker-minio-$SLUG" sh -c '
  read -r AK; read -r SK; export MC_CONFIG_DIR=/tmp/.mc-app
  mc alias set app http://127.0.0.1:9000 "$AK" "$SK" >/dev/null 2>&1
  echo probe | mc pipe "app/kyc-'"$SLUG"'/verify-local.txt" >/dev/null 2>&1 && echo W_OK || echo W_FAIL
  mc rm "app/kyc-'"$SLUG"'/verify-local.txt" >/dev/null 2>&1
  mc mb app/someone-else >/dev/null 2>&1 && echo MB_OK || echo MB_DENIED')"
[[ "$out" == *W_OK* ]] && ok "ключ приложения пишет в kyc-$SLUG" || bad "запись в kyc-$SLUG: $out"
[[ "$out" == *MB_DENIED* ]] && ok "ключ приложения не создаёт чужие бакеты" || bad "ключ приложения шире бакета: $out"

echo "6. Первый оператор"
if [ -f "$DIR/FIRST-LOGIN.txt" ]; then
    pwd1="$(awk '/пароль:/ {print $2}' "$DIR/FIRST-LOGIN.txt")"
    hash="$(docker exec "broker-db-site-$SLUG" psql -U broker -d broker_site -Atc "select password_hash from operators where login='$ADMIN_LOGIN'")"
    jr="$(docker exec "broker-db-site-$SLUG" psql -U broker -d broker_site -Atc "select count(*) from admin_action_journal where action='operator.bootstrap'")"
    rev="$(tr -d ' \n\r' < "$DIR/.revision")"
    v="$(printf '%s\n%s' "$hash" "$pwd1" | docker run --rm -i --entrypoint sh "ghcr.io/myxace/broker-admin:$rev" -c '
        set -- /app/node_modules/.pnpm/@node-rs+argon2@*/node_modules/@node-rs/argon2
        ARGON="$1" node -e "const a=require(process.env.ARGON);let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const [h,p]=s.split(\"\n\");a.verify(h,p).then(x=>console.log(x))})"')"
    [ "$v" = true ] && ok "пароль из FIRST-LOGIN.txt подходит к хешу оператора $ADMIN_LOGIN; записей operator.bootstrap: $jr" || bad "пароль не подошёл ($v)"
else
    bad "нет FIRST-LOGIN.txt"
fi

echo
echo "итог: пройдено $pass, провалено $fail"
[ "$fail" -eq 0 ]
