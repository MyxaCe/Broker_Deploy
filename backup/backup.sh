#!/usr/bin/env bash

set -euo pipefail

ROOT="${BROKER_ROOT:-/c/Users/Billie/Desktop/Broker}"
DEST_BASE="${DEST_BASE:-/d/Broker-backups}"
case "$DEST_BASE" in
  *:*) echo "ПРОВАЛ: DEST_BASE='$DEST_BASE' содержит двоеточие — tar примет его за имя хоста." >&2
       echo "        Нужен POSIX-путь, например /d/Broker-backups" >&2; exit 1;;
esac
KEEP=7
STAMP="$(date +%Y-%m-%d_%H%M%S)"
DEST="$DEST_BASE/$STAMP"
LOG="$DEST/backup.log"

REPOS="site-platform cms cms-legacy mds terminal deploy"
PLAIN="deploy _brain _reference"
EXCLUDES="--exclude=node_modules --exclude=.next --exclude=dist --exclude=target --exclude=.turbo --exclude=coverage"

VOL_COVERED_OTHERWISE="broker-local_site-db-data broker-local_cms-db-data broker-local_bus-data"

SKIPPED=0
fail() { echo "ПРОВАЛ: $*" | tee -a "$LOG" >&2; exit 1; }
say()  { echo "$*" | tee -a "$LOG"; }
skip() { SKIPPED=$((SKIPPED+1)); say "  ПРОПУСК: $*"; }

mkdir -p "$DEST" || { echo "ПРОВАЛ: не создать $DEST" >&2; exit 1; }
say "=== бэкап $STAMP ==="

mkdir -p "$DEST/db"
dump_db() {
  local container="$1" user="$2" db="$3"
  docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null | grep -q true \
    || { skip "база $db — контейнер $container не запущен, дампа в бэкапе НЕТ"; return 0; }
  docker exec "$container" pg_dump -U "$user" -d "$db" -Fc \
    > "$DEST/db/$db.dump" 2>>"$LOG" || fail "pg_dump $db"
  local sz; sz=$(stat -c%s "$DEST/db/$db.dump")
  [ "$sz" -gt 1000 ] || fail "дамп $db подозрительно мал: $sz байт"
  say "  база $db: $sz байт"
}
dump_db broker-local-site-db-1 broker broker_site
dump_db broker-local-cms-db-1  cms    broker_cms

mkdir -p "$DEST/volumes"
dump_vol() {
  local vol="$1"
  docker volume inspect "$vol" >/dev/null 2>&1 || { skip "том $vol — на машине его нет"; return 0; }
  MSYS_NO_PATHCONV=1 docker run --rm -v "$vol":/src:ro -v "$DEST/volumes":/out alpine \
    tar czf "/out/$vol.tar.gz" -C /src . 2>>"$LOG" || fail "том $vol"
  say "  том $vol: $(stat -c%s "$DEST/volumes/$vol.tar.gz") байт"
}
dump_vol broker-local_cms-media
dump_vol broker-local_cabinet-uploads

mkdir -p "$DEST/repos"
for r in $REPOS; do
  [ -d "$ROOT/$r/.git" ] || { skip "репозиторий $r — в списке есть, на диске git нет"; continue; }
  ( cd "$ROOT/$r" && git bundle create "$DEST/repos/$r.bundle" --all ) >>"$LOG" 2>&1 \
    || fail "bundle $r"
  ( cd "$ROOT/$r" && git bundle verify "$DEST/repos/$r.bundle" ) >>"$LOG" 2>&1 \
    || fail "bundle $r не проходит verify"
  ( cd "$ROOT/$r" && git for-each-ref --format='%(refname:short)' refs/heads \
      | while read -r b; do
          printf '%s %s %s\n' "$b" \
            "$(git rev-parse --abbrev-ref "$b@{upstream}" 2>/dev/null || echo -)" \
            "$(git rev-list --count "$b" --not --remotes 2>/dev/null || echo '?')"
        done ) > "$DEST/repos/$r.branches.txt" 2>/dev/null || true
  only=$(awk '$3 ~ /^[0-9]+$/ && $3 > 0' "$DEST/repos/$r.branches.txt" | wc -l | tr -d ' ')
  say "  репозиторий $r: $(stat -c%s "$DEST/repos/$r.bundle") байт, веток $(wc -l < "$DEST/repos/$r.branches.txt"), из них только здесь: $only"
done

mkdir -p "$DEST/uncommitted"
for r in $REPOS; do
  [ -d "$ROOT/$r/.git" ] || continue
  ( cd "$ROOT/$r" && git diff HEAD ) > "$DEST/uncommitted/$r.tracked.patch" 2>/dev/null || true
  ( cd "$ROOT/$r" && git ls-files --others --exclude-standard -z 2>/dev/null \
      | tar czf "$DEST/uncommitted/$r.untracked.tar.gz" --null -T - 2>/dev/null ) || true
  local_p=$(stat -c%s "$DEST/uncommitted/$r.tracked.patch" 2>/dev/null || echo 0)
  [ "$local_p" -gt 0 ] && say "  незакоммичено $r: патч $local_p байт"
done

mkdir -p "$DEST/plain"
for p in $PLAIN; do
  [ -d "$ROOT/$p" ] || { skip "папка $p — в списке есть, на диске нет"; continue; }
  tar czf "$DEST/plain/$p.tar.gz" $EXCLUDES --exclude=.env --exclude='.env.*' \
      -C "$ROOT" "$p" 2>>"$LOG" || fail "архив $p"
  say "  папка $p: $(stat -c%s "$DEST/plain/$p.tar.gz") байт (секреты .env исключены)"
done

say ""
say "--- охват: списки против того, что есть на машине ---"
disk_git=""; disk_plain=""
for d in "$ROOT"/*/; do
  n="$(basename "$d")"
  case "$n" in node_modules|.*) continue;; esac
  if [ -d "$d/.git" ]; then disk_git="$disk_git $n"; else disk_plain="$disk_plain $n"; fi
done
for n in $disk_git; do
  printf '%s\n' $REPOS | grep -qx "$n" \
    || { SKIPPED=$((SKIPPED+1)); say "  НЕ В БЭКАПЕ: репозиторий $n есть на диске, в REPOS его нет"; }
done
for n in $disk_plain; do
  printf '%s\n' $PLAIN | grep -qx "$n" \
    || { SKIPPED=$((SKIPPED+1)); say "  НЕ В БЭКАПЕ: папка без git $n есть на диске, в PLAIN её нет"; }
done
say "  репозиториев на диске $(printf '%s\n' $disk_git | sed '/^$/d' | wc -l | tr -d ' '), в списке $(printf '%s\n' $REPOS | wc -l | tr -d ' ')"
say "  папок без git на диске $(printf '%s\n' $disk_plain | sed '/^$/d' | wc -l | tr -d ' '), в списке $(printf '%s\n' $PLAIN | wc -l | tr -d ' ')"

vols="$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep '^broker-local_' || true)"
if [ -z "$vols" ]; then
  SKIPPED=$((SKIPPED+1)); say "  ОХВАТ ТОМОВ НЕ ПРОВЕРЕН: docker volume ls ничего не вернул"
else
  nv=0
  for v in $vols; do
    nv=$((nv+1))
    [ -f "$DEST/volumes/$v.tar.gz" ] && continue
    printf '%s\n' $VOL_COVERED_OTHERWISE | grep -qx "$v" && continue
    SKIPPED=$((SKIPPED+1)); say "  НЕ В БЭКАПЕ: том $v — ни архива, ни записанной причины"
  done
  say "  томов контура $nv; архивами покрыто $(ls -1 "$DEST/volumes"/*.tar.gz 2>/dev/null | wc -l | tr -d ' '), иначе покрыто $(printf '%s\n' $VOL_COVERED_OTHERWISE | wc -l | tr -d ' ')"
fi

( cd "$DEST" && find . -type f ! -name manifest.sha256 ! -name backup.log \
    -exec sha256sum {} + | sort -k2 ) > "$DEST/manifest.sha256"
say "  файлов в бэкапе: $(wc -l < "$DEST/manifest.sha256")"

if [ "$SKIPPED" -gt 0 ]; then
  say "  ротация ОТМЕНЕНА: прогон неполон ($SKIPPED пропуск(ов)) — старые бэкапы целы"
else
  ls -1d "$DEST_BASE"/*/ 2>/dev/null | sort -r | tail -n +$((KEEP+1)) | while read -r old; do
    say "  ротация: удаляю $old"
    rm -rf "$old"
  done
fi

say ""
if [ "$SKIPPED" -gt 0 ]; then
  say "=== БЭКАП НЕПОЛОН: пропусков $SKIPPED (строки ПРОПУСК и НЕ В БЭКАПЕ выше) ==="
  say "    Каталог $DEST оставлен: частичный бэкап лучше никакого, но полным не считается."
  say "ВНИМАНИЕ: бэкап на этой же машине. От потери доступа к машине не спасает."
  exit 1
fi
say "=== готово: $DEST ==="
say "ВНИМАНИЕ: бэкап на этой же машине. От потери доступа к машине не спасает."
