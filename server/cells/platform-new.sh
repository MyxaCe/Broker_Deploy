#!/usr/bin/env bash
# НОВАЯ ПЛАТФОРМА = НОВАЯ ЯЧЕЙКА. Одна команда, десять шагов, каждый можно
# повторить (повторный запуск ничего не ломает и доделывает недоделанное).
#
#   ./platform-new.sh <slug>              — создать / доделать платформу
#   ./platform-new.sh <slug> --dry-run    — показать, что было бы сделано
#   ./platform-new.sh <slug> --json       — + строки прогресса JSON в stderr
#   ./platform-new.sh <slug> --recopy-content   — перезалить контент из шаблона
#   ./platform-new.sh <slug> --rebrand          — перезаписать бренд в CMS
#
# Анкета — cells/<slug>/platform.conf (первый запуск создаёт её из образца и
# останавливается: заполните и запустите снова). Секреты рождаются ЗДЕСЬ, на
# хосте, в cells/<slug>/.env (600), и хост не покидают.
#
# Шаги: 1 проверка анкеты, хаба и памяти · 2 DNS · 3 секреты · 4 шина (свой
# vhost) · 5 CMS: сайт и контент из шаблона · 6 базы, миграции, KYC-хранилище,
# плечо · 7 сервисы · 8 первый оператор · 9 прокси и сертификаты · 10 здоровье.
#
# Apex (apex-ru) этот скрипт НЕ трогает: ни его compose, ни его имена, ни
# его базу. Общие объекты хаба он только дополняет: vhost шины, сайт в CMS,
# файл proxy/sites/<slug>.caddy.
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

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -ge 1 ] || usage
CELL_SLUG="$1"; shift
RECOPY=0; REBRAND=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --json) export JSON_PROGRESS=1 ;;
        --recopy-content) RECOPY=1 ;;
        --rebrand) REBRAND=1 ;;
        -h|--help) usage ;;
        *) die "неизвестный ключ: $1" ;;
    esac
    shift
done
valid_slug "$CELL_SLUG" || die "«$CELL_SLUG» — не годится как слаг: строчные латинские, цифры, дефис, 2–32 символа; не: $RESERVED_SLUGS"
load_hub_conf
DIR="$(cell_dir "$CELL_SLUG")"
T_START=$(date +%s)

say "${C_B}Новая платформа: $CELL_SLUG${C_0}$([ "$DRY_RUN" = 1 ] && echo '   (СУХОЙ ПРОГОН — ничего не меняется)')"

# --- анкета ------------------------------------------------------------------
if ! load_platform_conf "$CELL_SLUG"; then
    if [ "$DRY_RUN" = 1 ]; then die "нет анкеты $DIR/platform.conf"; fi
    mkdir -p "$DIR"; chmod 700 "$DIR"
    cp "$HERE/platform.conf.example" "$DIR/platform.conf"
    say ""
    say "Создана анкета: $DIR/platform.conf"
    say "Заполните её (название, цвет, пять адресов, кошелёк) и запустите команду ещё раз:"
    say "    $0 $CELL_SLUG"
    exit 0
fi
# Пустой TEMPLATE_SITE в анкете = значение из hub.conf (load_platform_conf его не затирает).
TEMPLATE_SITE="${TEMPLATE_SITE:-apex-ru}"

# =============================================================================
step "Проверка анкеты, хаба и памяти"
validate_platform_conf
info "бренд «$BRAND_NAME» $BRAND_COLOR · шаблон контента: $TEMPLATE_SITE"
for c in "$HUB_CMS" "$HUB_BUS" "$HUB_PROXY"; do
    container_running "$c" || step_fail "контейнер хаба $c не запущен"
done
container_running "$HUB_MDS" || warn "MDS ($HUB_MDS) не запущен — котировок не будет"
for n in "$EDGE_NET" "$BACK_NET"; do
    docker network inspect "$n" >/dev/null 2>&1 || step_fail "нет docker-сети $n"
done
proxy_hub_ready || step_fail "прокси хаба не подготовлен к ячейкам. Один раз (делает штаб): $HERE/hub-prepare.sh"
# Чужие ячейки с теми же адресами — отказ: два сайта на одном имени.
for f in "$PROXY_DIR"/sites/*.caddy; do
    [ -e "$f" ] || continue
    [ "$(basename "$f" .caddy)" = "$CELL_SLUG" ] && continue
    for h in "$SITE_HOST" "$CABINET_HOST" "$TERMINAL_HOST" "$ADMIN_HOST" "$FILES_HOST"; do
        grep -qE "^${h//./\\.} \{" "$f" && step_fail "адрес $h уже занят ячейкой $(basename "$f" .caddy)"
    done
done
apex_domain="$(env_get "$PROXY_DIR/.env" DOMAIN)"
for h in "$SITE_HOST" "$CABINET_HOST" "$TERMINAL_HOST" "$ADMIN_HOST" "$FILES_HOST"; do
    case "$h" in "$apex_domain"|cabinet."$apex_domain"|terminal."$apex_domain"|admin."$apex_domain"|files."$apex_domain"|cms."$apex_domain")
        step_fail "адрес $h принадлежит Apex — выберите другой" ;; esac
done
# Память: ячейка ≈ 700 МиБ. Уже работающую ячейку не считаем второй раз.
if ! container_running "broker-web-$CELL_SLUG"; then
    avail_mb="$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || true)"
    # Нет MemAvailable (не Linux: локальная проверка) — память ВМ docker.
    [ -n "$avail_mb" ] || avail_mb="$(docker run --rm postgres:16-alpine awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
    if [ "${avail_mb:-0}" -lt "${MIN_FREE_MB:-1200}" ]; then
        step_fail "свободной памяти ${avail_mb} МиБ, нужно не меньше ${MIN_FREE_MB} (ячейка ≈700 МиБ). Нужен второй хост или удаление ненужной ячейки"
    fi
    info "свободно памяти: ${avail_mb} МиБ (порог ${MIN_FREE_MB})"
else
    info "ячейка уже запущена — проверка памяти не нужна"
fi
step_ok "анкета в порядке, хаб на месте"

# =============================================================================
step "DNS: пять адресов смотрят на сервер"
if [ "${DNS_CHECK:-1}" = 0 ]; then
    step_skip "сверка DNS выключена в hub.conf (локальная проверка)"
else
    bad=()
    for h in "$SITE_HOST" "$CABINET_HOST" "$TERMINAL_HOST" "$ADMIN_HOST" "$FILES_HOST"; do
        if command -v dig >/dev/null; then
            got="$(dig +short +time=3 +tries=2 A "$h" @1.1.1.1 | grep -E '^[0-9.]+$' | sort -u | tr '\n' ' ')"
            v6="$(dig +short +time=3 +tries=2 AAAA "$h" @1.1.1.1 | grep ':' | tr '\n' ' ')"
        else
            got="$(getent ahostsv4 "$h" | awk '{print $1}' | sort -u | tr '\n' ' ')"; v6=""
        fi
        got="${got% }"
        if [ "$got" = "$PUBLIC_IP" ]; then
            info "✓ $h → $got"
        else
            bad+=("$h → ${got:-нет записи} (нужно $PUBLIC_IP)")
        fi
        [ -z "$v6" ] || warn "$h имеет запись AAAA ($v6) — сертификат может не выпуститься: удалите AAAA в DNS"
    done
    if [ ${#bad[@]} -gt 0 ]; then
        printf '      ✗ %s\n' "${bad[@]}" >&2
        step_fail "не все адреса смотрят на сервер. В панели DNS (GoDaddy) добавьте A-записи на $PUBLIC_IP и подождите 5–30 минут (см. docs/НОВАЯ-ПЛАТФОРМА.md)"
    fi
    step_ok "все пять адресов → $PUBLIC_IP"
fi

# =============================================================================
step "Секреты ячейки (рождаются здесь и сервер не покидают)"
[ -d "$DIR" ] || run mkdir -p "$DIR"
ENVF="$DIR/.env"
declare -A NEWSEC=()
have() { [ -f "$ENVF" ] && grep -qE "^$1=." "$ENVF"; }
for k in SITE_DB_PASSWORD TERMINAL_DB_PASSWORD CMS_WEBHOOK_SECRET ADMIN_SESSION_SECRET \
         INTERNAL_MONEY_TOKEN MINIO_ROOT_PASSWORD S3_SECRET_ACCESS_KEY \
         BUS_SITE_WEB_PASSWORD BUS_CABINET_PASSWORD BUS_TERMINAL_PASSWORD; do
    have "$k" || NEWSEC[$k]="$(gen_secret 24)"
done
have MINIO_ROOT_USER || NEWSEC[MINIO_ROOT_USER]="root-$(gen_secret 6)"
have S3_ACCESS_KEY_ID || NEWSEC[S3_ACCESS_KEY_ID]="kyc-$(gen_secret 8)"
if ! have SSO_PRIVATE_KEY_B64; then
    NEWSEC[SSO_PRIVATE_KEY_B64]="$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null \
        | openssl pkcs8 -topk8 -nocrypt -outform PEM | base64 | tr -d '\n')"
    [ -n "${NEWSEC[SSO_PRIVATE_KEY_B64]}" ] || step_fail "openssl не сгенерировал ключ SSO"
fi
if [ ${#NEWSEC[@]} -gt 0 ]; then
    {
        [ -f "$ENVF" ] && cat "$ENVF"
        [ -f "$ENVF" ] || printf '# Секреты ячейки %s. Сгенерированы на хосте platform-new.sh. 600, в git не едут.\n' "$CELL_SLUG"
        for k in "${!NEWSEC[@]}"; do printf '%s=%s\n' "$k" "${NEWSEC[$k]}"; done
    } | write_file "$ENVF" 600
    info "добавлено ключей: ${#NEWSEC[@]} (${!NEWSEC[*]})"
else
    info "все секреты уже на месте — ничего не перегенерировано"
fi
[ "$DRY_RUN" = 1 ] || chmod 600 "$ENVF"

# Параметры ячейки (не секреты) — пересобираются из анкеты каждый прогон.
{
    cat <<EOF
# Параметры ячейки $CELL_SLUG. ГЕНЕРИРУЕТСЯ platform-new.sh из platform.conf и
# hub.conf — правьте анкету, не этот файл. Секретов здесь нет.
CELL_SLUG=$CELL_SLUG
SITE_HOST=$SITE_HOST
CABINET_HOST=$CABINET_HOST
TERMINAL_HOST=$TERMINAL_HOST
ADMIN_HOST=$ADMIN_HOST
FILES_HOST=$FILES_HOST
EDGE_NET=$EDGE_NET
BACK_NET=$BACK_NET
HUB_CMS=$HUB_CMS
HUB_MDS=$HUB_MDS
HUB_BUS=$HUB_BUS
BUS_VHOST=cell-$CELL_SLUG
BUS_SITE_WEB_USER=$CELL_SLUG-site-web
BUS_CABINET_USER=$CELL_SLUG-cabinet
BUS_TERMINAL_USER=$CELL_SLUG-terminal
S3_BUCKET=kyc-$CELL_SLUG
DEMO_START_BALANCE_CENTS=$DEMO_START_BALANCE_CENTS
MARGIN_CALL_LEVEL_PERCENT=$MARGIN_CALL_LEVEL_PERCENT
MARGIN_STOP_OUT_LEVEL_PERCENT=$MARGIN_STOP_OUT_LEVEL_PERCENT
NEGATIVE_BALANCE_PROTECTION=$NEGATIVE_BALANCE_PROTECTION
PLATFORM_LEVERAGE=$PLATFORM_LEVERAGE
REAL_TRADING_ENABLED=$REAL_TRADING_ENABLED
EXCHANGE_TRON_ADDRESS=$EXCHANGE_TRON_ADDRESS
EOF
} | write_file "$DIR/cell.env" 644

# Compose и ревизии: КОПИЯ на момент создания, дальше у ячейки свои.
if [ ! -f "$DIR/compose.yml" ]; then
    run cp "$HERE/template/compose.yml" "$DIR/compose.yml"
elif ! cmp -s "$HERE/template/compose.yml" "$DIR/compose.yml"; then
    warn "шаблон compose новее копии ячейки — ячейка живёт своей копией (обновление — отдельной операцией)"
fi
for pair in ".revision:$HUB_SITE_REVISION_FILE" ".revision-terminal:$HUB_TERMINAL_REVISION_FILE"; do
    f="$DIR/${pair%%:*}"; src="${pair#*:}"
    if [ ! -f "$f" ]; then
        [ -f "$src" ] || step_fail "нет $src — ревизию взять неоткуда"
        run cp "$src" "$f"
        info "${pair%%:*} ← $(tr -d ' \n\r' < "$src" | cut -c1-12) (ревизия хаба на момент создания)"
    fi
done
step_ok "секреты в $ENVF (600), параметры в cell.env"

CELL=("$HERE/cell.sh" "$CELL_SLUG")
REV_SITE="$(cat "$DIR/.revision" 2>/dev/null || cat "$HUB_SITE_REVISION_FILE")"
REV_SITE="$(printf '%s' "$REV_SITE" | tr -cd '0-9a-f')"

# =============================================================================
step "Шина: свой vhost и кредлы ячейки"
bus_setup "$CELL_SLUG" || step_fail "шина не настроена"
step_ok "vhost cell-$CELL_SLUG, кредлы $CELL_SLUG-{site-web,cabinet,terminal}; события Apex сюда не попадают"

# =============================================================================
step "CMS: сайт-тенант и контент из шаблона «$TEMPLATE_SITE»"
CMS_ADMIN_EMAIL="$(env_get "$HUB_CMS_ENV" SEED_ADMIN_EMAIL)"
CMS_ADMIN_PASSWORD="$(env_get "$HUB_CMS_ENV" SEED_ADMIN_PASSWORD)"
CELL_WEBHOOK_SECRET="$(env_get "$ENVF" CMS_WEBHOOK_SECRET)"
[ -n "$CMS_ADMIN_EMAIL" ] && [ -n "$CMS_ADMIN_PASSWORD" ] || step_fail "нет SEED_ADMIN_EMAIL/SEED_ADMIN_PASSWORD в $HUB_CMS_ENV"
[ -n "$CELL_WEBHOOK_SECRET" ] || CELL_WEBHOOK_SECRET="dry-run"
export CMS_ADMIN_EMAIL CMS_ADMIN_PASSWORD CELL_WEBHOOK_SECRET
mounts=(-v "$(hostpath "$HERE/lib/cms-clone.py"):/w/cms-clone.py:ro")
args=(create --slug "$CELL_SLUG" --name "$BRAND_NAME" --color "$BRAND_COLOR" --template "$TEMPLATE_SITE"
      --webhook-url "http://broker-web-$CELL_SLUG:3000/api/revalidate"
      --demo-balance "$DEMO_START_BALANCE_CENTS" --exclude-categories "$EXCLUDE_CATEGORIES"
      --mds-url "http://$HUB_MDS:3003" --promotions "$PROMOTIONS" --replace "$CONTENT_REPLACE")
if [ -n "$BRAND_LOGO" ]; then mounts+=(-v "$(hostpath "$BRAND_LOGO"):/in/$(basename "$BRAND_LOGO"):ro"); args+=(--logo "/in/$(basename "$BRAND_LOGO")"); fi
if [ -n "$BRAND_FAVICON" ]; then mounts+=(-v "$(hostpath "$BRAND_FAVICON"):/in/$(basename "$BRAND_FAVICON"):ro"); args+=(--favicon "/in/$(basename "$BRAND_FAVICON")"); fi
[ "$RECOPY" = 1 ] && args+=(--recopy)
[ "$REBRAND" = 1 ] && args+=(--rebrand)
dry=(); [ "$DRY_RUN" = 1 ] && dry=(--dry-run)
# Скрипт сам читает (поиск сайта и разделов) и в сухом прогоне только печатает записи.
docker run --rm --network "$BACK_NET" -e CMS_ADMIN_EMAIL -e CMS_ADMIN_PASSWORD -e CELL_WEBHOOK_SECRET \
    "${mounts[@]}" "$PYTHON_IMAGE" python -I /w/cms-clone.py --base "http://$HUB_CMS:3001" "${dry[@]}" "${args[@]}" \
    | sed '/^RESULT /d' || step_fail "CMS: сайт или контент не созданы (вывод выше)"
unset CMS_ADMIN_PASSWORD
step_ok "сайт «$CELL_SLUG» в CMS, разделы опубликованы"

# =============================================================================
step "Базы, миграции, KYC-хранилище, плечо"
if [ "$DRY_RUN" = 1 ]; then run "${CELL[@]}" up -d cell-site-db cell-term-db cell-kyc-store
else "${CELL[@]}" up -d cell-site-db cell-term-db cell-kyc-store >"$DIR/last-up.log" 2>&1     || { tail -15 "$DIR/last-up.log" >&2; step_fail "базы не поднялись (лог: $DIR/last-up.log)"; }; fi
if [ "$DRY_RUN" = 0 ]; then
    wait_healthy "broker-db-site-$CELL_SLUG" 120 || step_fail "база сайта не стала healthy"
    wait_healthy "broker-db-terminal-$CELL_SLUG" 120 || step_fail "база терминала не стала healthy"
fi
# Миграция ПЕРВОЙ — тем же путём, что при деплое витрины (consumer-образ несёт
# миграции и node-pg-migrate). Повтор безопасен: применённое пропускается.
if [ "$DRY_RUN" = 1 ]; then
    run "${CELL[@]}" run --rm --no-deps cell-consumer pnpm --filter @broker/db migrate
else
    "${CELL[@]}" run --rm --no-deps -T cell-consumer pnpm --filter @broker/db migrate >"$DIR/last-migrate.log" 2>&1 \
        || { tail -20 "$DIR/last-migrate.log" >&2; step_fail "миграции базы сайта упали (лог: $DIR/last-migrate.log)"; }
    applied="$(docker exec "broker-db-site-$CELL_SLUG" psql -U broker -d broker_site -Atc 'select count(*) from pgmigrations' 2>/dev/null || echo '?')"
    info "миграции применены: $applied"
fi

# KYC: ключ приложения с правами ТОЛЬКО на бакет ячейки (как у Apex — не root).
if [ "$DRY_RUN" = 1 ]; then
    run docker exec "broker-minio-$CELL_SLUG" mc admin user add / policy attach "kyc-$CELL_SLUG"
else
    wait_healthy "broker-minio-$CELL_SLUG" 60 || step_fail "MinIO ячейки не запустился"
    printf '%s\n%s\n' "$(env_get "$ENVF" S3_ACCESS_KEY_ID)" "$(env_get "$ENVF" S3_SECRET_ACCESS_KEY)" \
    | docker exec -i -e B="kyc-$CELL_SLUG" "broker-minio-$CELL_SLUG" sh -c '
        set -e; read -r AK; read -r SK
        export MC_CONFIG_DIR=/tmp/.mc
        for i in $(seq 1 30); do mc alias set loc http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1 && break; sleep 2; done
        mc mb --ignore-existing "loc/$B" >/dev/null
        printf "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:*\"],\"Resource\":[\"arn:aws:s3:::%s\",\"arn:aws:s3:::%s/*\"]}]}" "$B" "$B" > /tmp/p.json
        mc admin policy create loc "$B-rw" /tmp/p.json >/dev/null
        mc admin user add loc "$AK" "$SK" >/dev/null
        mc admin policy attach loc "$B-rw" --user "$AK" >/dev/null 2>&1 || true
        mc admin user info loc "$AK" | grep -q "$B-rw"
      ' || step_fail "KYC-хранилище: ключ приложения не заведён"
    info "KYC: бакет kyc-$CELL_SLUG, ключ приложения с правами только на него"
fi

# Плечо: стартовая конфигурация новой площадки. Пишется, ПОКА КЛИЕНТОВ НЕТ
# (как сид портфелей в миграции). Дальше плечо меняется только в админке —
# с журналом и доставкой в терминал.
if [ -n "$CRYPTO_LEVERAGE" ]; then
    if [ "$DRY_RUN" = 1 ]; then
        run psql "crypto override = $CRYPTO_LEVERAGE во всех портфелях"
    else
        out="$(docker exec -i "broker-db-site-$CELL_SLUG" psql -q -U broker -d broker_site -v ON_ERROR_STOP=1 -At 2>"$DIR/last-leverage.log" <<SQL
DO \$\$
BEGIN
  IF (SELECT count(*) FROM users) = 0 THEN
    INSERT INTO leverage_portfolio_class_overrides (portfolio_key, instrument_class, leverage)
    SELECT key, 'crypto', LEAST($CRYPTO_LEVERAGE, base_leverage) FROM leverage_portfolios
    ON CONFLICT (portfolio_key, instrument_class) DO UPDATE SET leverage = EXCLUDED.leverage;
    RAISE NOTICE 'applied';
  ELSE
    RAISE NOTICE 'skipped-has-clients';
  END IF;
END \$\$;
SELECT string_agg(portfolio_key || '=1:' || leverage, ' ' ORDER BY portfolio_key)
  FROM leverage_portfolio_class_overrides WHERE instrument_class = 'crypto';
SQL
)" || step_fail "плечо не записано (лог: $DIR/last-leverage.log)"
        grep -q skipped-has-clients "$DIR/last-leverage.log" && warn "в платформе уже есть клиенты — плечо меняйте в админке (журнал)"
        info "плечо крипто по портфелям: $out"
    fi
fi
step_ok "базы сайта и терминала, схема, KYC-хранилище, плечо"

# =============================================================================
step "Сервисы ячейки (образы ревизии ${REV_SITE:0:12})"
profile=()
if [ -n "$EXCHANGE_TRON_ADDRESS" ]; then profile=(--profile chain); else info "кошелёк не задан — наблюдатель TRON не запускается"; fi
if [ "$DRY_RUN" = 1 ]; then
    run "${CELL[@]}" "${profile[@]}" pull -q
    run "${CELL[@]}" "${profile[@]}" up -d
else
    { "${CELL[@]}" "${profile[@]}" pull -q && "${CELL[@]}" "${profile[@]}" up -d; } >"$DIR/last-up.log" 2>&1         || { tail -15 "$DIR/last-up.log" >&2; step_fail "compose up не прошёл (лог: $DIR/last-up.log)"; }
fi
if [ "$DRY_RUN" = 0 ]; then
    svc=(web cabinet admin relay consumer terminal-gateway terminal-web)
    [ -n "$EXCHANGE_TRON_ADDRESS" ] && svc+=(chain-watcher)
    sleep 8
    for s in "${svc[@]}"; do
        c="broker-$s-$CELL_SLUG"
        wait_healthy "$c" 60 || { docker logs --tail 15 "$c" >&2 || true; step_fail "$c не запущен"; }
        rc="$(docker inspect -f '{{.RestartCount}}' "$c")"
        [ "$rc" -le 1 ] || { docker logs --tail 15 "$c" >&2; step_fail "$c перезапускается ($rc раз) — смотрите лог выше"; }
    done
fi
step_ok "11 контейнеров ячейки запущены"

# =============================================================================
step "Первый оператор админки"
FIRST="$DIR/FIRST-LOGIN.txt"
if [ "$DRY_RUN" = 1 ]; then
    run echo "оператор $ADMIN_LOGIN (admin) с одноразовым паролем → $FIRST"
    step_ok "(сухой прогон)"
else
    PW="$(gen_secret 10)"
    HASH="$(printf '%s' "$PW" | docker run --rm -i --entrypoint sh "ghcr.io/myxace/broker-admin:$REV_SITE" -c '
        set -- /app/node_modules/.pnpm/@node-rs+argon2@*/node_modules/@node-rs/argon2
        ARGON="$1" node -e "const a=require(process.env.ARGON);let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>a.hash(s,{memoryCost:65536,timeCost:3,parallelism:4}).then(h=>console.log(h)))"')"
    [[ "$HASH" == \$argon2id\$* ]] || step_fail "не удалось посчитать хеш пароля в образе админки"
    set +e
    res="$(printf '%s' "$HASH" | "${CELL[@]}" --profile chain run --rm --no-deps -T \
        -v "$(hostpath "$HERE/lib/bootstrap-operator.ts"):/repo/apps/chain-watcher/cell-bootstrap.ts:ro" \
        -e ADMIN_BOOTSTRAP_LOGIN="$ADMIN_LOGIN" -e ADMIN_BOOTSTRAP_NAME="$ADMIN_NAME" \
        cell-chain-watcher node --import tsx cell-bootstrap.ts 2>&1)"
    code=$?
    set -e
    unset HASH
    case "$code" in
        0)  printf 'Вход в админку платформы %s\n  адрес:  https://%s/login\n  логин:  %s\n  пароль: %s  (одноразовый: при первом входе админка потребует включить 2FA)\nУдалите этот файл после первого входа.\n' \
                "$BRAND_NAME" "$ADMIN_HOST" "$ADMIN_LOGIN" "$PW" | write_file "$FIRST" 600
            step_ok "оператор $ADMIN_LOGIN создан (роль admin, запись в журнале operator.bootstrap)" ;;
        10) step_ok "оператор уже заведён ($(echo "$res" | awk '/^ALREADY/ {print $2}')) — второй сидом не создаётся" ;;
        *)  echo "$res" | tail -10 >&2; step_fail "первый оператор не создан" ;;
    esac
    unset PW
fi

# =============================================================================
step "Прокси: адреса ячейки и сертификаты"
proxy_apply || step_fail "прокси не принял конфигурацию ячейки"
if [ "${CERT_CHECK:-1}" = 1 ] && [ "$DRY_RUN" = 0 ]; then
    for hp in "$SITE_HOST:/api/health" "$CABINET_HOST:/api/health" "$TERMINAL_HOST:/" "$ADMIN_HOST:/api/health" "$FILES_HOST:/"; do
        h="${hp%%:*}"; p="${hp#*:}"
        if code="$(proxy_wait_cert "$h" "$p")"; then info "✓ https://$h  (HTTP $code)"
        else step_fail "https://$h не ответил за ${CERT_WAIT_SEC} с (последний ответ: $code). Проверьте DNS и лог: docker logs $HUB_PROXY | grep -i $h"; fi
    done
    step_ok "сертификаты выпущены, все пять имён отвечают по HTTPS"
else
    step_ok "фрагмент принят прокси$([ "${CERT_CHECK:-1}" = 0 ] && echo ' (ожидание сертификатов выключено в hub.conf)')"
fi

# =============================================================================
step "Проверка здоровья"
if [ "$DRY_RUN" = 1 ]; then
    run echo "health: web/cabinet/admin /api/health, терминал /health, бренд CMS, консюмер на шине"
    step_ok "(сухой прогон)"
else
    fails=()
    jget() { docker exec "$1" node -e "fetch('$2').then(async r=>{const t=await r.text();console.log(r.status+' '+t.slice(0,600))}).catch(e=>{console.log('ERR '+e.message)})" 2>/dev/null; }
    r="$(jget "broker-web-$CELL_SLUG" http://127.0.0.1:3000/api/health)";      [[ "$r" == 200* ]] && info "✓ витрина: $(echo "$r" | grep -o '"status":"[a-z]*"')" || fails+=("витрина: $r")
    r="$(jget "broker-cabinet-$CELL_SLUG" http://127.0.0.1:3002/api/health)";  [[ "$r" == 200* ]] && info "✓ кабинет" || fails+=("кабинет: $r")
    r="$(jget "broker-admin-$CELL_SLUG" http://127.0.0.1:3005/api/health)";    [[ "$r" == *'"sessionSecret":"set"'* ]] && info "✓ админка (секрет сессии задан)" || fails+=("админка: $r")
    r="$(docker exec "broker-terminal-web-$CELL_SLUG" wget -qO- http://gateway:8080/health 2>&1 || true)"
    [[ "$r" == *ok* || "$r" == *'"status"'* ]] && info "✓ терминал: $(echo "$r" | head -c 160)" || fails+=("терминал: $r")
    r="$(jget "broker-web-$CELL_SLUG" "http://$HUB_CMS:3001/v1/cms/brand?site=$CELL_SLUG")"
    [[ "$r" == 200* && "$r" == *"$BRAND_NAME"* ]] && info "✓ CMS отдаёт бренд «$BRAND_NAME»" || fails+=("бренд в CMS: $r")
    if docker exec "$HUB_BUS" rabbitmqctl list_consumers -p "cell-$CELL_SLUG" -s 2>/dev/null | grep -q cabinet.terminal-projection; then
        info "✓ консюмер ячейки слушает свою очередь в vhost cell-$CELL_SLUG"
    else fails+=("консюмер не подписан на cell-$CELL_SLUG/cabinet.terminal-projection"); fi
    # СБРОС КЕША ВИТРИНЫ. Страницы витрины пререндерены при сборке образа (без
    # CMS — с запасным золотым цветом) и кешируются по тегам `cms:<ресурс>`.
    # CMS же шлёт сайту НЕ по умолчанию теги со слагом (`cms:brand:<slug>`) —
    # витрина их не слушает, и бренд с контентом проявились бы только через
    # час (страховочный revalidate). Поэтому скрипт сам, ключом вебхука ЭТОЙ
    # ячейки, шлёт её витрине теги без слага. Чинится в коде (см. отчёт OPS),
    # после починки шаг станет лишним, но не вредным.
    r="$(docker exec -i "broker-web-$CELL_SLUG" sh -c 'read -r S; S="$S" node -e "
const c=require(\"crypto\");
const tags=[\"brand\",\"navigation\",\"faq\",\"instruments\",\"accounts\",\"promotions\",\"partners\",\"academy\",\"streams\",\"contacts\",\"careers\",\"legal\",\"system-status\",\"articles\"].map(x=>\"cms:\"+x);
const body=JSON.stringify({event_id:c.randomUUID(),occurred_at:new Date().toISOString(),tags});
const sig=\"sha256=\"+c.createHmac(\"sha256\",process.env.S).update(body,\"utf8\").digest(\"hex\");
fetch(\"http://127.0.0.1:3000/api/revalidate\",{method:\"POST\",headers:{\"Content-Type\":\"application/json\",\"X-Signature\":sig},body}).then(r=>console.log(r.status))"' \
        <<<"$(env_get "$ENVF" CMS_WEBHOOK_SECRET)" 2>&1 || true)"
    [ "$r" = 202 ] && info "✓ кеш витрины сброшен (бренд и разделы из CMS)" || fails+=("сброс кеша витрины: $r")
    sleep 2
    html="$(docker exec "broker-web-$CELL_SLUG" node -e "fetch('http://127.0.0.1:3000/ru').then(r=>r.text()).then(t=>console.log(t))" 2>/dev/null || true)"
    accent="$(printf '%d %d %d' "0x${BRAND_COLOR:1:2}" "0x${BRAND_COLOR:3:2}" "0x${BRAND_COLOR:5:2}")"
    if [[ "$html" == *"--accent:$accent;"* ]]; then info "✓ витрина в фирменном цвете $BRAND_COLOR"
    else fails+=("витрина не в фирменном цвете (ждали --accent:$accent)"); fi
    tmpl_name="$(docker exec "broker-web-$CELL_SLUG" node -e "fetch('http://$HUB_CMS:3001/v1/cms/sites/$TEMPLATE_SITE',{headers:{'x-api-key':process.env.CMS_API_KEY}}).then(r=>r.json()).then(j=>console.log(j.name||''))" 2>/dev/null || true)"
    left="$(grep -o "${tmpl_name:-Apex Capital}" <<<"$html" | wc -l | tr -d ' ')"
    if [ "${left:-0}" -gt 0 ]; then
        warn "в HTML витрины ещё ${left} раз «${tmpl_name:-Apex Capital}» — это строки, зашитые в коде сайта (задача «бренд из CMS» в site-platform), не контент CMS"
    else info "✓ в HTML витрины нет названия шаблонного бренда"; fi
    if [ "${CERT_CHECK:-1}" = 1 ]; then
        code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$SITE_HOST:443:127.0.0.1" "https://$SITE_HOST/api/health" || true)"
        [ "$code" = 200 ] && info "✓ https://$SITE_HOST/api/health снаружи → 200" || fails+=("https://$SITE_HOST → $code")
    fi
    if [ ${#fails[@]} -gt 0 ]; then printf '      ✗ %s\n' "${fails[@]}" >&2; step_fail "проверка здоровья не пройдена"; fi
    step_ok "платформа отвечает"
fi

# =============================================================================
dt=$(( $(date +%s) - T_START ))
say ""
if [ "$DRY_RUN" = 1 ]; then
    say "${C_B}Сухой прогон завершён${C_0} (${dt} с): ничего не изменено. Адреса будущей платформы:"
else
    say "${C_OK}${C_B}Платформа «$BRAND_NAME» готова${C_0} (${dt} с)"
fi
say "  Витрина:   https://$SITE_HOST"
say "  Кабинет:   https://$CABINET_HOST"
say "  Терминал:  https://$TERMINAL_HOST"
say "  Админка:   https://$ADMIN_HOST   (только с разрешённых адресов)"
say "  CMS:       раздел сайта «$CELL_SLUG» в общей CMS"
if [ -f "$DIR/FIRST-LOGIN.txt" ] && [ "$DRY_RUN" = 0 ]; then
    say ""
    sed 's/^/  /' "$DIR/FIRST-LOGIN.txt"
fi
say ""
say "  Секреты: $DIR/.env (600) · анкета: $DIR/platform.conf"
say "  Управление: $HERE/cell.sh $CELL_SLUG ps | logs -f cell-web | restart"
say "  Удаление (репетиция): $HERE/platform-destroy.sh $CELL_SLUG"
json_line "$STEP_TOTAL" "$STEP_TOTAL" "done" ok "$dt"
