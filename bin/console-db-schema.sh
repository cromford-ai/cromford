#!/bin/bash
# bin/console-db-schema.sh [--root DIR] [--dry-run] — apply every
# <root>/console-ui/schema.d/*.sql to harness-console-db through the Cloudflare
# D1 query API (BH-9308).
#
# WHY. The console's log screens read runs by started_at and commands by
# created_at over a date range. harness-console-db had no index for either, and
# this repo had no apply path for that database: bin/console-pages-deploy.sh
# ships Pages code only, and bin/lib/alerts-open-read.sh and
# bin/builds-merged-sweep.sh only read it. This is the apply path. The deployer
# runs it after its stamp and its probes, so it never stops or delays a deploy.
#
# WHAT IT ACCEPTS. Only `CREATE INDEX IF NOT EXISTS <name> ON <table>(...)`.
# Every file is read and every statement checked BEFORE any POST: one other
# statement (a DROP, a CREATE TABLE, a DELETE) prints the statement and its
# file, raises the warn alert, and exits 2 with nothing applied. `--` comments
# and blank lines are dropped; statements split on `;`.
#
# HOW. One POST per statement to
#   accounts/<account>/d1/database/<CONSOLE_D1_ID>/query
# with the account, the D1 id fallback and the token read exactly as
# bin/lib/alerts-open-read.sh reads them (cloudflare.env under harness_env_dir;
# the token reaches curl on stdin from a subshell, never argv, never a log).
# curl --max-time is the settings row console_db.schema_apply_timeout_s
# (fallback 30, range 1..300). Success = HTTP 2xx AND "success":true.
#
# RESULT (exit 0 on every apply outcome):
#   all applied -> resolve alert console-db-schema and print
#                  "console-db-schema: applied N index statements to harness-console-db"
#   any failure -> ONE warn alert console-db-schema naming each index not
#                  applied and why (no token, HTTP code, success != true)
#   no fragments -> one line, nothing else
# exit 2 = a refused statement or a bad argument. --dry-run checks and prints
# the statements, then stops: no credential read, no POST, no alert.
# It never writes the deploy stamp and takes no lock: CREATE INDEX IF NOT EXISTS
# is idempotent, so two runs at once do no harm.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
DRY=0
usage() { echo "usage: bin/console-db-schema.sh [--root DIR] [--dry-run]" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] && [ -n "$2" ] || usage; ROOT="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    *) usage ;;
  esac
done
command -v jq >/dev/null 2>&1 || { echo "console-db-schema: jq missing" >&2; exit 2; }

. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF_DIR/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
. "$H/bin/lib/console-pages.sh" 2>/dev/null || . "$SELF_DIR/lib/console-pages.sh" 2>/dev/null || true
JC="$H/bin/jobs-client.sh"
LA="$H/bin/lane-alert.sh"
alert() { [ -x "$LA" ] && "$LA" "$@" >/dev/null 2>&1 || true; }
HOST=$(hostname 2>/dev/null || echo unknown)
TOKMSG="the hub's CLOUDFLARE_API_TOKEN needs D1 edit on harness-console-db"

# ── read and check every statement before any POST ───────────────────────────
STMTS=(); SRCS=()
shopt -s nullglob
FILES=("$ROOT"/console-ui/schema.d/*.sql)
shopt -u nullglob
ACCEPT='^[Cc][Rr][Ee][Aa][Tt][Ee][[:space:]]+[Ii][Nn][Dd][Ee][Xx][[:space:]]+[Ii][Ff][[:space:]]+[Nn][Oo][Tt][[:space:]]+[Ee][Xx][Ii][Ss][Tt][Ss][[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+[Oo][Nn][[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\('
REFUSED=0
for f in "${FILES[@]}"; do
  while IFS= read -r -d $'\x1e' s; do
    s=$(printf '%s' "$s" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g')
    [ -n "$s" ] || continue
    if [[ "$s" =~ $ACCEPT ]]; then
      STMTS+=("$s"); SRCS+=("${f##*/}")
    else
      echo "console-db-schema: REFUSED (not CREATE INDEX IF NOT EXISTS) in ${f##*/}: $s"
      REFUSED=$((REFUSED + 1))
    fi
  # Drop `--` comments, then split on `;` (record separator 0x1e between statements).
  done < <(sed 's/--.*$//' "$f" | tr '\n' ' ' | tr ';' '\036'; printf '\036')
done
if [ "$REFUSED" -gt 0 ]; then
  [ "$DRY" = 1 ] || alert --severity warn --id console-db-schema fleet-propagate \
    "[$HOST] console-db-schema: $REFUSED statement(s) in console-ui/schema.d are not CREATE INDEX IF NOT EXISTS - nothing applied to harness-console-db (see logs/console-pages-deploy.log)"
  exit 2
fi
N=${#STMTS[@]}
if [ "$N" = 0 ]; then
  echo "console-db-schema: no statements in $ROOT/console-ui/schema.d - nothing to apply"
  exit 0
fi
# idx_name <statement> — the index name (the 6th word).
idx_name() { printf '%s\n' "$1" | awk '{ print ($6 != "" ? $6 : "?") }'; }
if [ "$DRY" = 1 ]; then
  for s in "${STMTS[@]}"; do echo "console-db-schema: would apply: $s"; done
  exit 0
fi

# ── timeout: settings row console_db.schema_apply_timeout_s ──────────────────
# Fallback 30 is the documented fallback of row console_db.schema_apply_timeout_s.
TMO=30
if [ -x "$JC" ]; then
  v=$("$JC" setting-get console_db.schema_apply_timeout_s 2>/dev/null) && v=$(printf '%s' "$v" | tr -d '[:space:]') || v=""
  if [[ "$v" =~ ^[0-9]+$ ]] && [ "$((10#$v))" -ge 1 ] && [ "$((10#$v))" -le 300 ]; then
    TMO=$((10#$v))
  elif [ -n "$v" ]; then
    echo "console-db-schema: console_db.schema_apply_timeout_s=$v is not a whole number in 1..300 - using 30" >&2
  fi
fi

# ── apply ────────────────────────────────────────────────────────────────────
fail_all() { # fail_all <why> — every index not applied, one alert, exit 0.
  local s names=""
  for s in "${STMTS[@]}"; do names="${names:+$names, }$(idx_name "$s")"; done
  alert --severity warn --id console-db-schema fleet-propagate \
    "[$HOST] console-db-schema: $N index statement(s) not applied to harness-console-db ($1): $names - $TOKMSG"
  echo "console-db-schema: nothing applied ($1): $names"
  exit 0
}
CFENV="$(harness_env_dir "$H")/cloudflare.env"
[ -r "$CFENV" ] || fail_all "no cloudflare.env"
ACCT=""; command -v console_pages_account_id >/dev/null 2>&1 && ACCT=$(console_pages_account_id "$ROOT" 2>/dev/null)
[ -n "$ACCT" ] || fail_all "no Cloudflare account id"
# The console's D1 id, the same id and fallback bin/lib/alerts-open-read.sh reads.
D1="${CONSOLE_D1_ID:-00000000-0000-0000-0000-000000000001}"
( set -a; . "$CFENV" >/dev/null 2>&1; set +a; [ -n "${CLOUDFLARE_API_TOKEN:-}" ] ) || fail_all "no CLOUDFLARE_API_TOKEN"

W=$(mktemp -d "${TMPDIR:-/tmp}/cdbs.XXXXXX") || fail_all "no temp dir"
trap 'rm -rf "$W"' EXIT
BAD=""; OK=0
for s in "${STMTS[@]}"; do
  jq -nc --arg s "$s" '{sql:$s}' > "$W/q.json" || { BAD="${BAD:+$BAD, }$(idx_name "$s") (query unwritable)"; continue; }
  rm -f "$W/r.json"
  code=$( set -a; . "$CFENV" >/dev/null 2>&1; set +a
    printf 'Authorization: Bearer %s\n' "${CLOUDFLARE_API_TOKEN:-}" \
      | curl -s --max-time "$TMO" -X POST -H @- -H 'Content-Type: application/json' \
          --data-binary "@$W/q.json" -o "$W/r.json" -w '%{http_code}' \
          "https://api.cloudflare.com/client/v4/accounts/$ACCT/d1/database/$D1/query" 2>/dev/null
  ) || code="${code:-000}"
  code=${code:-000}
  case "$code" in
    2??) if jq -e '.success == true and ((.result[0].success // true) == true)' "$W/r.json" >/dev/null 2>&1; then
           OK=$((OK + 1)); echo "console-db-schema: applied $(idx_name "$s")"
         else
           BAD="${BAD:+$BAD, }$(idx_name "$s") (HTTP $code, success != true)"
         fi ;;
    *) BAD="${BAD:+$BAD, }$(idx_name "$s") (HTTP $code)" ;;
  esac
done
if [ -n "$BAD" ]; then
  alert --severity warn --id console-db-schema fleet-propagate \
    "[$HOST] console-db-schema: $((N - OK)) of $N index statement(s) not applied to harness-console-db: $BAD - $TOKMSG"
  echo "console-db-schema: $((N - OK)) of $N not applied: $BAD"
  exit 0
fi
alert --resolve --id console-db-schema fleet-propagate "applied $N index statements to harness-console-db"
echo "console-db-schema: applied $N index statements to harness-console-db"
exit 0
