#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROXY_ENV="$HERE/../proxy/.env"
BUS_ENV="$HERE/../bus/.env"
OWN_ENV="$HERE/.env"
VAULT_KYC_ENV="$HERE/../vault/rendered/.env.kyc"

for f in "$PROXY_ENV" "$BUS_ENV" "$OWN_ENV"; do
    [ -f "$f" ] || { echo "нет $f — без него подставлять нечего" >&2; exit 1; }
done

[ -f "$HERE/.revision" ] || { echo "нет $HERE/.revision — какую ревизию катим, неизвестно" >&2; exit 1; }
REV="$(tr -d ' \n\r' < "$HERE/.revision")"
case "$REV" in
    [0-9a-f]*) [ ${#REV} -eq 40 ] || { echo "в .revision не полный хеш коммита: «$REV»" >&2; exit 1; } ;;
    *) echo "в .revision не хеш коммита: «$REV»" >&2; exit 1 ;;
esac

ENV_ARGS=(--env-file "$PROXY_ENV" --env-file "$BUS_ENV" --env-file "$OWN_ENV")
if [ -f "$VAULT_KYC_ENV" ]; then
    ENV_ARGS+=(--env-file "$VAULT_KYC_ENV")
else
    echo "примечание: $VAULT_KYC_ENV нет — KYC-ключи берутся из .env (fallback OpenBao)" >&2
fi

exec env SITE_REVISION="$REV" docker compose "${ENV_ARGS[@]}" "$@"
