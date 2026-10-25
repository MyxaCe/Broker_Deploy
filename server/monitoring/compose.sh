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
# Свидетелю нужны кредлы ОБЕИХ баз. Берём их там, где они лежат, —
# копия здесь была бы третьей правдой о каждом пароле.
SITE_ENV="$HERE/../site/.env"
TERM_ENV="$HERE/../terminal/.env"
OWN_ENV="$HERE/.env"

for f in "$PROXY_ENV" "$BUS_ENV" "$SITE_ENV" "$TERM_ENV" "$OWN_ENV"; do
    [ -f "$f" ] || { echo "нет $f — без него подставлять нечего" >&2; exit 1; }
done

# НИКОГДА не удалять каталог conf перед заменой: он примонтирован в
# контейнеры, а bind-mount каталога держится за ЕГО inode так же, как
# у файла. `rm -rf` + распаковка = контейнер смотрит в несуществующий
# каталог, Prometheus теряет ВСЕ правила и молчит, отчитываясь
# успехом перезагрузки. Поймано на себе 24.10, B-OPS-034.
# Пути к .env вычисляются, файлов в репозитории нет и быть не должно —
# это секреты. Подавление названо здесь и только здесь: глобальное
# скрыло бы будущий `source`, который действительно стоит прочитать.
#
# Группа в скобках не для красоты: директива действует на СЛЕДУЮЩУЮ
# команду, а в строке `set -a; . ...` следующая — это `set -a`, и
# подавление не доставало до `.` вовсе.
# shellcheck disable=SC1090
{ set -a; . "$PROXY_ENV"; . "$BUS_ENV"; . "$SITE_ENV"; . "$TERM_ENV"; . "$OWN_ENV"; set +a; }

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

exec env SITE_DB_PASSWORD="$SITE_DB_PASSWORD" TERMINAL_DB_USER="$TERMINAL_DB_USER" TERMINAL_DB_PASSWORD="$TERMINAL_DB_PASSWORD" TERMINAL_DB_NAME="$TERMINAL_DB_NAME" docker compose --env-file "$OWN_ENV" "$@"
