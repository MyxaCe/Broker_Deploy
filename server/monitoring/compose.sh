#!/usr/bin/env bash
# Обёртка над `docker compose` для стека наблюдения.
#
# ЗАЧЕМ ОНА. Конфиги Prometheus, json-exporter и Alertmanager должны знать
# домен и кредл шины — а те живут в ОДНОМ месте каждый: домен в
# `proxy/.env`, кредл у шины. Копировать их в конфиги наблюдения значило
# бы завести третью правду о каждом значении, и разъехались бы они молча.
#
# Поэтому конфиги РЕНДЕРЯТСЯ из шаблонов при каждом подъёме, а готовые
# файлы в git не едут (в них подставлены секреты).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROXY_ENV="$HERE/../proxy/.env"
BUS_ENV="$HERE/../bus/.env"
OWN_ENV="$HERE/.env"

for f in "$PROXY_ENV" "$BUS_ENV" "$OWN_ENV"; do
    [ -f "$f" ] || { echo "нет $f — без него подставлять нечего" >&2; exit 1; }
done

set -a; . "$PROXY_ENV"; . "$BUS_ENV"; . "$OWN_ENV"; set +a

# Кредл management-API шины — в заголовок Basic. Пароль не печатается.
BUS_BASIC="$(printf '%s:%s' "$BUS_ADMIN_USER" "$BUS_ADMIN_PASSWORD" | base64 -w0)"
export BUS_BASIC

mkdir -p "$HERE/rendered"
# Каталог обязан быть ПРОХОДИМЫМ: защита лежит на файлах внутри.
# Первый прогон создал его при umask 077, унаследованном от
# генерации секретов, — и все три службы, работающие не от root,
# получили «permission denied» на вполне читаемых файлах.
chmod 755 "$HERE/rendered"
for f in prometheus json-exporter alertmanager; do
    envsubst < "$HERE/conf/$f.yml.shablon" > "$HERE/rendered/$f.yml"
done
# В отрендеренных лежат секреты: права сужаем сразу, а не «потом».
# ВЛАДЕЛЕЦ — nobody, а не root: обе службы работают не от root, и файл с
# правами 600 у root они прочитать не могут. Первая редакция этого не
# учла, и обе падали с «permission denied» — защита, закрывшая доступ
# тому, кого защищает.
chown 65534:65534 "$HERE/rendered/json-exporter.yml" "$HERE/rendered/alertmanager.yml"
chmod 600 "$HERE/rendered/json-exporter.yml" "$HERE/rendered/alertmanager.yml"
chmod 644 "$HERE/rendered/prometheus.yml"

# Гейт: незаполненный шаблон не должен уехать в работу молча.
if grep -q '\${' "$HERE/rendered/prometheus.yml" "$HERE/rendered/alertmanager.yml"; then
    echo "в отрендеренных конфигах осталась неподставленная переменная:" >&2
    grep -n '\${' "$HERE/rendered/"*.yml >&2
    exit 1
fi

exec docker compose --env-file "$OWN_ENV" "$@"
