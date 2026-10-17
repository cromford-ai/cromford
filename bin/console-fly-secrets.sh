#!/bin/bash
# bin/console-fly-secrets.sh — put the per-project Fly tokens on the console
# worker, so its `machines` view can read each pool (BH-7196).
#
#   bin/console-fly-secrets.sh                 # dry run (default): list missing names, put nothing
#   bin/console-fly-secrets.sh --apply         # put each missing name
#   bin/console-fly-secrets.sh --project <p>   # put FLY_API_TOKEN_<P> (bin/fly-onboard.sh calls this)
#
# "Missing" = the FLY_API_TOKEN_<P> names in env/fly.env (the bare org token
# FLY_API_TOKEN excluded) minus the names `wrangler secret list` returns for the
# worker, by exact name. There is no local ledger: the worker is asked each run.
#
# Config rows, read from <envdir>/global.env ONLY, never the process env (a test
# runner's exported value must never point a run at a real account):
#   CONSOLE_CF_ACCOUNT_ID  32 hex, required. No fallback: a guess at the account
#                          is the "More than one account available" error.
#   CONSOLE_WORKER_NAME    default harness-console.
# CLOUDFLARE_API_TOKEN comes from <envdir>/cloudflare.env, into the wrangler
# child only. A token value lives in a shell variable and goes to wrangler on
# stdin; it is never exported, never on argv, and scrubbed from every error body.
#
# Output: `MISSING <NAME>` per missing name (dry run), `PUT <NAME> ok|FAILED`
# per put, then `console-fly-secrets: <n> missing of <m> on <worker> …`.
# Errors go to stderr. This script writes no ALERTS line; the caller owns that.
# Exit: 0 ok; 1 a wrangler call failed or the project has no token;
#       2 usage or env/fly.env unreadable; 3 not configured.
set -uo pipefail
H="${HARNESS:-/root/harness}"

usage() { echo "usage: console-fly-secrets.sh [--apply | --project <p>]" >&2; exit 2; }
MODE=dry; P=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) MODE=apply; shift ;;
    --project) [ $# -ge 2 ] || usage; MODE=project; P="$2"; shift 2 ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) usage ;;
  esac
done
if [ "$MODE" = project ]; then
  [ -n "$P" ] && [ "$P" = "$(printf %s "$P" | tr -dc 'A-Za-z0-9._-')" ] || usage
fi

# shellcheck source=bin/lib/env-path.sh
. "$H/bin/lib/env-path.sh" 2>/dev/null
command -v harness_env_dir >/dev/null 2>&1 || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
ENVD=$(harness_env_dir "$H")
FLYENV="$ENVD/fly.env"
CFENV="$ENVD/cloudflare.env"
[ -r "$FLYENV" ] || { echo "console-fly-secrets: env/fly.env not readable ($FLYENV)" >&2; exit 2; }

row() { # row <NAME> — last value in global.env, quotes stripped
  local f="$ENVD/global.env"
  [ -r "$f" ] || return 0
  sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1=//p" "$f" | tail -1 | tr -d "\"'" | tr -d '[:space:]'
}
ACCT=$(row CONSOLE_CF_ACCOUNT_ID)
WORKER=$(row CONSOLE_WORKER_NAME); WORKER="${WORKER:-harness-console}"
if ! [[ "$ACCT" =~ ^[0-9a-f]{32}$ ]]; then
  echo "console-fly-secrets: not configured: CONSOLE_CF_ACCOUNT_ID in $ENVD/global.env is unset or not 32 hex" >&2; exit 3
fi
if ! [[ "$WORKER" =~ ^[a-z0-9-]{1,63}$ ]]; then
  echo "console-fly-secrets: not configured: CONSOLE_WORKER_NAME '$WORKER' is not a worker name" >&2; exit 3
fi
envval() { # envval <file> <NAME> — the value as `source` reads it, in a clean shell
  env -i bash -c 'set -a; . "$1" >/dev/null 2>&1; printf %s "${!2:-}"' _ "$1" "$2"
}
CFTOK=""
[ -r "$CFENV" ] && CFTOK=$(envval "$CFENV" CLOUDFLARE_API_TOKEN)
[ -n "$CFTOK" ] || { echo "console-fly-secrets: not configured: no CLOUDFLARE_API_TOKEN in $CFENV" >&2; exit 3; }

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/console-fly-secrets.XXXXXX") || exit 1
trap 'rm -rf "$TMPD"' EXIT

wr() { # wr <args…> — wrangler from an empty dir (no wrangler.jsonc); stdin passes through
  ( cd "$TMPD" && CLOUDFLARE_API_TOKEN="$CFTOK" CLOUDFLARE_ACCOUNT_ID="$ACCT" WRANGLER_SEND_METRICS=false \
      timeout 120 npx --yes wrangler@3 "$@" ) > "$TMPD/out" 2>&1
}
body() { # body [token] — the scrubbed one-line output of the last call
  S1="${1:-}" S2="$CFTOK" awk '{
    n=split(ENVIRON["S1"] "\n" ENVIRON["S2"], s, "\n")
    for (k=1; k<=n; k++) { t=s[k]; if (t!="") while ((i=index($0,t))>0) $0=substr($0,1,i-1) "***" substr($0,i+length(t)) }
    gsub(/Bearer[ \t]+[^ \t]+/,"Bearer ***"); print }' "$TMPD/out" | tr '\n' ' ' | cut -c1-400
}
put() { # put <NAME> — read the token, send it on stdin; 0 = wrangler rc 0
  local n="$1" tok rc
  tok=$(envval "$FLYENV" "$n")
  [ -n "$tok" ] || { echo "console-fly-secrets: no $n in env/fly.env" >&2; return 1; }
  printf '%s' "$tok" | wr secret put "$n" --name "$WORKER"; rc=$?
  if [ "$rc" = 0 ]; then echo "PUT $n ok"; return 0; fi
  echo "wrangler put $n failed (rc $rc): $(body "$tok")" >&2
  return 1
}

if [ "$MODE" = project ]; then
  N="FLY_API_TOKEN_$(printf %s "$P" | tr '[:lower:].-' '[:upper:]__')"
  put "$N"; exit $?
fi

WANT=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}\(FLY_API_TOKEN_[A-Z0-9_]\{1,\}\)=.*/\2/p' "$FLYENV" | LC_ALL=C sort -u)
wr secret list --name "$WORKER" </dev/null; RC=$?
if [ "$RC" != 0 ]; then
  echo "console-fly-secrets: wrangler list on $WORKER failed (rc $RC): $(body)" >&2; exit 1
fi
# A list we cannot parse is an error, never "0 present": no JSON array, or jq refused it.
LJ=$(sed -n '/^\[/,$p' "$TMPD/out")
if [ -z "$LJ" ] || ! HAVE=$(printf '%s\n' "$LJ" | jq -r 'if type == "array" then .[].name else error("not an array") end' 2>/dev/null); then
  echo "console-fly-secrets: could not read the secret list for $WORKER: $(body)" >&2; exit 1
fi
MISS=$(LC_ALL=C comm -23 <(printf '%s\n' "$WANT" | grep -v '^$') <(printf '%s\n' "$HAVE" | LC_ALL=C sort -u))
M=$(printf '%s\n' "$WANT" | grep -c .)
NM=$(printf '%s\n' "$MISS" | grep -c .)

if [ "$MODE" = dry ]; then
  [ -n "$MISS" ] && printf 'MISSING %s\n' $MISS
  echo "console-fly-secrets: $NM missing of $M on $WORKER (dry run; --apply to put)"
  exit 0
fi
RCX=0
for n in $MISS; do
  put "$n" || { echo "PUT $n FAILED"; RCX=1; }
done
echo "console-fly-secrets: $NM missing of $M on $WORKER (applied)"
exit "$RCX"
