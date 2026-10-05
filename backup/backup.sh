#!/usr/bin/env bash
# Бэкап того, чего нет на GitHub. OPS-04.
#
# Резервируем ровно то, что существует в одном экземпляре:
#   1. базы контура (дампы, не копии файлов тома)
#   2. тома медиа и загрузок
#   3. ВСЕ локальные ветки репозиториев, включая незапушенные (git bundle)
#   4. незакоммиченную работу (патч + неотслеживаемые файлы)
#   5. папки БЕЗ git вообще: deploy, _brain, _reference
#
# Пункт 5 — причина, по которой этот скрипт вообще написан: там лежат правила,
# контракты, решения и задачи всех команд, и до сегодня они не были нигде, кроме
# этой машины. Ровно так был потерян вейлт MDS (решение Р-008).
#
# Назначение — D:, это физически другой диск (Samsung 970 EVO против Kingston на
# C:). Отказ одного диска бэкап переживёт. Потерю доступа к машине — НЕТ.
# Внешняя копия остаётся незакрытой задачей, см. docs/Бэкапы.md.

set -euo pipefail

ROOT="/c/Users/Billie/Desktop/Broker"
DEST_BASE="/d/Broker-backups"
KEEP=7                       # сколько последних прогонов держать
STAMP="$(date +%Y-%m-%d_%H%M%S)"
DEST="$DEST_BASE/$STAMP"
LOG="$DEST/backup.log"

REPOS="site-platform cms cms-legacy mds terminal"
PLAIN="deploy _brain _reference"
EXCLUDES="--exclude=node_modules --exclude=.next --exclude=dist --exclude=target --exclude=.turbo --exclude=coverage"

fail() { echo "ПРОВАЛ: $*" | tee -a "$LOG" >&2; exit 1; }
say()  { echo "$*" | tee -a "$LOG"; }

mkdir -p "$DEST" || { echo "ПРОВАЛ: не создать $DEST" >&2; exit 1; }
say "=== бэкап $STAMP ==="

# --- 1. Базы контура: дампы, а не файлы тома -------------------------------
# Копировать каталог работающей Postgres нельзя: получится нецелостный снимок.
mkdir -p "$DEST/db"
dump_db() {
  local container="$1" user="$2" db="$3"
  docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null | grep -q true \
    || { say "  ПРОПУСК $db: контейнер $container не запущен"; return 0; }
  docker exec "$container" pg_dump -U "$user" -d "$db" -Fc \
    > "$DEST/db/$db.dump" 2>>"$LOG" || fail "pg_dump $db"
  local sz; sz=$(stat -c%s "$DEST/db/$db.dump")
  [ "$sz" -gt 1000 ] || fail "дамп $db подозрительно мал: $sz байт"
  say "  база $db: $sz байт"
}
dump_db broker-local-site-db-1 broker broker_site
dump_db broker-local-cms-db-1  cms    broker_cms

# --- 2. Тома медиа и загрузок ----------------------------------------------
mkdir -p "$DEST/volumes"
dump_vol() {
  local vol="$1"
  docker volume inspect "$vol" >/dev/null 2>&1 || { say "  ПРОПУСК тома $vol: нет"; return 0; }
  MSYS_NO_PATHCONV=1 docker run --rm -v "$vol":/src:ro -v "$DEST/volumes":/out alpine \
    tar czf "/out/$vol.tar.gz" -C /src . 2>>"$LOG" || fail "том $vol"
  say "  том $vol: $(stat -c%s "$DEST/volumes/$vol.tar.gz") байт"
}
dump_vol broker-local_cms-media
dump_vol broker-local_cabinet-uploads

# --- 3. Репозитории: ВСЕ ветки, включая незапушенные ------------------------
# git bundle --all кладёт в один файл всю историю и все локальные ветки, не
# спрашивая, есть ли они на remote. Именно это и нужно: сегодня ветки
# site-platform/web-01-local-run и mds/mds-волна-1 существуют ТОЛЬКО здесь.
mkdir -p "$DEST/repos"
for r in $REPOS; do
  [ -d "$ROOT/$r/.git" ] || { say "  ПРОПУСК $r: не git"; continue; }
  ( cd "$ROOT/$r" && git bundle create "$DEST/repos/$r.bundle" --all ) >>"$LOG" 2>&1 \
    || fail "bundle $r"
  ( cd "$ROOT/$r" && git bundle verify "$DEST/repos/$r.bundle" ) >>"$LOG" 2>&1 \
    || fail "bundle $r не проходит verify"
  ( cd "$ROOT/$r" && git branch --format='%(refname:short) %(upstream:short)' ) \
    > "$DEST/repos/$r.branches.txt" 2>/dev/null || true
  say "  репозиторий $r: $(stat -c%s "$DEST/repos/$r.bundle") байт, веток $(wc -l < "$DEST/repos/$r.branches.txt")"
done

# --- 4. Незакоммиченная работа ---------------------------------------------
# bundle берёт только коммиты. Правки в рабочем дереве в него не попадают, а
# сегодня их 49 в cms и 22 в terminal.
mkdir -p "$DEST/uncommitted"
for r in $REPOS; do
  [ -d "$ROOT/$r/.git" ] || continue
  ( cd "$ROOT/$r" && git diff HEAD ) > "$DEST/uncommitted/$r.tracked.patch" 2>/dev/null || true
  ( cd "$ROOT/$r" && git ls-files --others --exclude-standard -z 2>/dev/null \
      | tar czf "$DEST/uncommitted/$r.untracked.tar.gz" --null -T - 2>/dev/null ) || true
  local_p=$(stat -c%s "$DEST/uncommitted/$r.tracked.patch" 2>/dev/null || echo 0)
  [ "$local_p" -gt 0 ] && say "  незакоммичено $r: патч $local_p байт"
done

# --- 5. Папки без git ------------------------------------------------------
# Единственная копия правил, контрактов, решений и задач платформы.
mkdir -p "$DEST/plain"
for p in $PLAIN; do
  [ -d "$ROOT/$p" ] || continue
  tar czf "$DEST/plain/$p.tar.gz" $EXCLUDES --exclude=.env --exclude='.env.*' \
      -C "$ROOT" "$p" 2>>"$LOG" || fail "архив $p"
  say "  папка $p: $(stat -c%s "$DEST/plain/$p.tar.gz") байт (секреты .env исключены)"
done

# --- 6. Манифест с контрольными суммами ------------------------------------
( cd "$DEST" && find . -type f ! -name manifest.sha256 ! -name backup.log \
    -exec sha256sum {} + | sort -k2 ) > "$DEST/manifest.sha256"
say "  файлов в бэкапе: $(wc -l < "$DEST/manifest.sha256")"

# --- 7. Ротация ------------------------------------------------------------
ls -1d "$DEST_BASE"/*/ 2>/dev/null | sort -r | tail -n +$((KEEP+1)) | while read -r old; do
  say "  ротация: удаляю $old"
  rm -rf "$old"
done

say "=== готово: $DEST ==="
say "ВНИМАНИЕ: бэкап на этой же машине. От потери доступа к машине не спасает."
