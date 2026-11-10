# shellcheck shell=bash
# Прокси ячейки: фрагмент proxy/sites/<slug>.caddy + validate + reload.
#
# Блоки — копия блоков Apex (Caddyfile стенда) с именами ячейки:
#   витрина  — публичные ручки MDS (тот же список РАЗРЕШЁННОГО) + сайт;
#   кабинет, терминал — как у Apex;
#   админка  — фильтр источника: CELL_ADMIN_ALLOW (как у Apex — три адреса),
#              пусто → общий ADMIN_IP (сниппет adminonly);
#   files    — KYC-документы оператору, за ADMIN_IP (как files. у Apex).

proxy_fragment() { # печатает фрагмент в stdout
    local s="$CELL_SLUG" admin_guard
    if [ -n "${CELL_ADMIN_ALLOW:-}" ]; then
        admin_guard="	@blocked not remote_ip ${CELL_ADMIN_ALLOW}
	respond @blocked \"Dostup ogranichen\" 403"
    else
        admin_guard="	import adminonly"
    fi
    cat <<EOF
# Ячейка ${s} — «${BRAND_NAME}». Файл пишет cells/platform-new.sh; править
# руками бесполезно — следующий прогон перезапишет. Удаляет platform-destroy.sh.

${SITE_HOST} {
	@mds_dannye path /v1/quotes /v1/instruments
	handle @mds_dannye {
		reverse_proxy ${HUB_MDS}:3003
	}
	@mds_ikonki path_regexp ^/icons/[A-Z0-9]{1,20}\\.svg\$
	handle @mds_ikonki {
		reverse_proxy ${HUB_MDS}:3003
	}
	@mds_potok path /socket.io /socket.io/*
	handle @mds_potok {
		reverse_proxy ${HUB_MDS}:3003
	}
	handle {
		reverse_proxy broker-web-${s}:3000
	}
}

${CABINET_HOST} {
	reverse_proxy broker-cabinet-${s}:3002
}

${TERMINAL_HOST} {
	reverse_proxy broker-terminal-web-${s}:80
}

# Центр управления ячейки — денежный control plane: фильтр источника.
${ADMIN_HOST} {
${admin_guard}
	reverse_proxy broker-admin-${s}:3005
}

# KYC-документы ячейки для оператора — за ADMIN_IP, как files. у Apex.
${FILES_HOST} {
	import adminonly
	reverse_proxy broker-minio-${s}:9000
}
EOF
}

proxy_hub_ready() {
    grep -qxF 'import sites/*.caddy' "$PROXY_DIR/Caddyfile" 2>/dev/null \
        && grep -qF './sites:/etc/caddy/sites' "$PROXY_DIR/compose.yml" 2>/dev/null
}

proxy_apply() {
    local f="$PROXY_DIR/sites/$CELL_SLUG.caddy" new old=""
    new="$(proxy_fragment)"
    [ -f "$f" ] && old="$(cat "$f")"
    if [ "$new" = "$old" ]; then
        info "фрагмент $f не изменился"
        PROXY_CHANGED=0
    else
        [ -n "$old" ] && run cp -p "$f" "$f.prev"
        printf '%s\n' "$new" | write_file "$f" 644
        PROXY_CHANGED=1
    fi
    [ "$DRY_RUN" = 1 ] && { run docker exec "$HUB_PROXY" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile; run docker exec "$HUB_PROXY" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile; return 0; }

    if ! docker exec "$HUB_PROXY" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/tmp/cell-caddy-validate.$$ 2>&1; then
        tail -5 /tmp/cell-caddy-validate.$$ >&2; rm -f /tmp/cell-caddy-validate.$$
        if [ -f "$f.prev" ]; then mv -f "$f.prev" "$f"; else rm -f "$f"; fi
        echo "caddy validate отказал — фрагмент ячейки убран, прокси не перезагружался"
        return 1
    fi
    rm -f /tmp/cell-caddy-validate.$$ "$f.prev"
    if [ "$PROXY_CHANGED" = 1 ]; then
        docker exec "$HUB_PROXY" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 \
            || { echo "caddy reload отказал"; return 1; }
        info "прокси перечитал конфигурацию (reload без простоя)"
    fi
}

# Ждать, пока имя ответит по HTTPS настоящим сертификатом. Запрос — с хоста
# на свой же 443 (--resolve), чтобы не зависеть от кешей DNS у клиента.
proxy_wait_cert() { # <host> <path>
    local host="$1" path="$2" t=0 code
    while [ $t -lt "${CERT_WAIT_SEC:-180}" ]; do
        code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
            --resolve "$host:443:127.0.0.1" "https://$host$path" 2>/dev/null || true)"
        case "$code" in 2??|3??|401|403) echo "$code"; return 0 ;; esac
        sleep 5; t=$((t + 5))
    done
    echo "${code:-нет ответа}"
    return 1
}

proxy_remove() {
    local f="$PROXY_DIR/sites/$1.caddy"
    [ -f "$f" ] || { info "фрагмента прокси нет"; return 0; }
    run rm -f "$f"
    if [ "$DRY_RUN" = 0 ] && container_running "$HUB_PROXY"; then
        docker exec "$HUB_PROXY" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 \
            || warn "caddy reload после удаления фрагмента отказал — проверьте прокси"
    fi
}
