#!/bin/bash
set -eu
c="$1"; u="${2:-postgres}"; ok=0
for _ in $(seq 1 60); do
  if docker exec "$c" psql -U "$u" -tAc "select 1" >/dev/null 2>&1; then
    ok=$((ok+1)); [ "$ok" -ge 2 ] && exit 0
  else
    ok=0
  fi
  sleep 2
done
echo "база $c не поднялась за 120 с" >&2; exit 1
