# shellcheck shell=bash
# Шина ячейки: СВОЙ vhost `cell-<slug>` на общем брокере хаба.
#
# ПОЧЕМУ VHOST, А НЕ «СВОЯ ОЧЕРЕДЬ В ОБЩЕМ `platform`». Консюмер Apex читает
# очередь `cabinet.terminal-projection` с привязкой `terminal.#` в vhost
# `platform`. Опубликуй терминал ячейки туда же — события ячейки попадут в
# проекцию Apex (фильтр по SITE_SLUG в консюмере есть, но это одна строка
# кода между двумя юрлицами). Отдельный vhost — это физическая граница
# брокера: обменник `platform.events` ячейки — другой объект, кредлы ячейки
# в `platform` не имеют прав вовсе. Имена очереди и обменника внутри — те же,
# что у Apex, поэтому приложениям ничего не надо знать.
#
# Права — ДОСЛОВНО как в bus/bus-setup.sh (выведены из вызовов, Р-051), только
# на vhost ячейки. Пароли — из .env ячейки, в вывод не попадают.

bus_ctl() { docker exec "$HUB_BUS" rabbitmqctl "$@"; }

bus_setup() { # <slug>
    local slug="$1" vhost="cell-$1" envf
    envf="$(cell_dir "$slug")/.env"
    local admin_user admin_pass
    admin_user="$(env_get "$HUB_BUS_ENV" BUS_ADMIN_USER)"
    admin_pass="$(env_get "$HUB_BUS_ENV" BUS_ADMIN_PASSWORD)"

    if [ "$DRY_RUN" = 1 ]; then
        if container_running "$HUB_BUS" && bus_ctl list_vhosts -s 2>/dev/null | grep -qx "$vhost"; then
            info "vhost $vhost уже есть — повтор сверит кредлы и права"
        fi
        run bus_ctl add_vhost "$vhost"
        run bus_ctl set_permissions -p "$vhost" "<admin>" '.*' '.*' '.*'
        local u; for u in site-web cabinet terminal; do run bus_ctl add_user "$slug-$u" '<пароль из .env ячейки>'; done
        run bus_ctl set_permissions -p "$vhost" "$slug-site-web" '' '^platform\.events$' ''
        run bus_ctl set_permissions -p "$vhost" "$slug-terminal" '' '^platform\.events$' ''
        run bus_ctl set_permissions -p "$vhost" "$slug-cabinet" '^cabinet\.terminal-projection$' '^(cabinet\.terminal-projection|platform\.events\.dlx)$' '^(platform\.events|cabinet\.terminal-projection(\.dlq)?)$'
        run echo "rabbitmqadmin -V $vhost declare exchange platform.events/topic, platform.events.dlx/topic, queue cabinet.terminal-projection.dlq, binding dlx→dlq #"
        return 0
    fi

    container_running "$HUB_BUS" || { echo "брокер $HUB_BUS не запущен"; return 1; }
    [ -n "$admin_user" ] && [ -n "$admin_pass" ] || { echo "нет BUS_ADMIN_USER/BUS_ADMIN_PASSWORD в $HUB_BUS_ENV"; return 1; }

    # 1. vhost
    if bus_ctl list_vhosts -s 2>/dev/null | grep -qx "$vhost"; then
        info "vhost $vhost уже есть"
    else
        run bus_ctl add_vhost "$vhost" >/dev/null
        info "vhost $vhost создан"
    fi
    # Админ шины объявляет топологию в новом vhost (как в platform).
    run bus_ctl set_permissions -p "$vhost" "$admin_user" '.*' '.*' '.*' >/dev/null

    # 2. Кредлы ячейки. Теги снимаются безусловно (см. bus-setup.sh).
    local pair user pw
    for pair in "site-web:BUS_SITE_WEB_PASSWORD" "cabinet:BUS_CABINET_PASSWORD" "terminal:BUS_TERMINAL_PASSWORD"; do
        user="$slug-${pair%%:*}"
        pw="$(env_get "$envf" "${pair#*:}")"
        [ -n "$pw" ] || { echo "нет ${pair#*:} в $envf"; return 1; }
        if ! bus_ctl list_users -s 2>/dev/null | awk '{print $1}' | grep -qx "$user"; then
            run bus_ctl add_user "$user" "$pw" >/dev/null
        fi
        run bus_ctl change_password "$user" "$pw" >/dev/null
        run bus_ctl set_user_tags "$user" >/dev/null
    done

    # 3. Права — только в vhost ячейки.
    run bus_ctl set_permissions -p "$vhost" "$slug-site-web" "" '^platform\.events$' "" >/dev/null
    run bus_ctl set_permissions -p "$vhost" "$slug-terminal" "" '^platform\.events$' "" >/dev/null
    run bus_ctl set_permissions -p "$vhost" "$slug-cabinet" \
        '^cabinet\.terminal-projection$' \
        '^(cabinet\.terminal-projection|platform\.events\.dlx)$' \
        '^(platform\.events|cabinet\.terminal-projection(\.dlq)?)$' >/dev/null

    # 4. Топология: обменники и DLQ объявляет владелец шины, не приложения.
    local decl=(docker exec "$HUB_BUS" rabbitmqadmin -V "$vhost" -u "$admin_user" -p "$admin_pass")
    run "${decl[@]}" declare exchange name=platform.events type=topic durable=true >/dev/null
    run "${decl[@]}" declare exchange name=platform.events.dlx type=topic durable=true >/dev/null
    run "${decl[@]}" declare queue name=cabinet.terminal-projection.dlq durable=true >/dev/null
    run "${decl[@]}" declare binding source=platform.events.dlx destination=cabinet.terminal-projection.dlq routing_key='#' >/dev/null

    # 5. Гейт по НАБЛЮДЕНИЮ (код возврата rabbitmqadmin однажды соврал, B-OPS-014).
    [ "$DRY_RUN" = 1 ] && return 0
    local want rc=0
    for want in platform.events platform.events.dlx; do
        bus_ctl list_exchanges -p "$vhost" name 2>/dev/null | awk '{print $1}' | grep -qx "$want" \
            || { echo "нет обменника $want в $vhost"; rc=1; }
    done
    bus_ctl list_queues -p "$vhost" name 2>/dev/null | awk '{print $1}' | grep -qx cabinet.terminal-projection.dlq \
        || { echo "нет очереди cabinet.terminal-projection.dlq в $vhost"; rc=1; }
    # Кредлы ячейки НЕ должны иметь прав в общем vhost `platform`.
    if bus_ctl list_permissions -p platform 2>/dev/null | awk '{print $1}' | grep -q "^$slug-"; then
        echo "у кредлов ячейки есть права в vhost platform — изоляция нарушена"; rc=1
    fi
    [ $rc -eq 0 ] && info "vhost $vhost: обменники, DLQ и права на месте; в platform прав нет"
    return $rc
}

bus_destroy() { # <slug>
    local slug="$1" vhost="cell-$1" u
    container_running "$HUB_BUS" || { warn "брокер $HUB_BUS не запущен — vhost не удалён"; return 0; }
    for u in site-web cabinet terminal; do
        if bus_ctl list_users -s 2>/dev/null | awk '{print $1}' | grep -qx "$slug-$u"; then
            run bus_ctl delete_user "$slug-$u" >/dev/null
        fi
    done
    if bus_ctl list_vhosts -s 2>/dev/null | grep -qx "$vhost"; then
        run bus_ctl delete_vhost "$vhost" >/dev/null
    fi
}
