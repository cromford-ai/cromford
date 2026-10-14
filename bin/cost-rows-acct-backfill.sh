#!/bin/bash
# bin/cost-rows-acct-backfill.sh [--accounts-dir <dir>] [--out <file.sql>]
#
# BH-3986 one-shot, DRY-RUN ONLY: prints the SQL that rewrites historic
# cost_rows whose auth_account is `acct:<name>` to that account's canonical
# label, the registry's ACCOUNT_LABEL. Until BH-3986 the hub wrote `acct:max1`
# where the pool wrote `max1@example.com` for the same account, so the console
# split one account in two. New rows agree at write time
# (bin/lib/cost-row.sh cost_row_auth_account); this is for the rows before it.
#
# It sends nothing and has no --apply. A human reviews the file and applies it
# from the hub, where the registry lives:
#   bin/cost-rows-acct-backfill.sh --out /tmp/acct-backfill.sql
#   wrangler d1 execute harness-jobs --remote --file=/tmp/acct-backfill.sql
# Runbook: docs/notes/2026-10-03-BH-3986-cost-row-attribution.md.
#
# Per labelled account it emits a before_ COUNT, one UPDATE of the column AND
# of field 16 inside `raw` (cost_rows_fetch re-emits raw verbatim, so the
# rollup and cost-report would keep reading acct:<name> from it), and an
# after_ COUNT that must read 0. The UPDATE matches only acct:<name>, so a
# rerun changes nothing.
#
# The registry files hold tokens: each is read with grep for ACCOUNT_LABEL /
# ACCOUNT_NAME only, never sourced, and nothing else from it is printed. A file
# whose stem fails the picker's name rule, or whose ACCOUNT_NAME disagrees with
# its stem, is skipped with a note on stderr.
#
# Default --accounts-dir: <env dir>/accounts.d (bin/lib/env-path.sh).
# Exit: 0 SQL printed (or written to --out), 1 no account has a label (nothing
# to emit), 2 usage, an unreadable dir, or a label carrying a comma, a double
# quote or a CR (it would not match the row the writer wrote; fix the registry).
set -uo pipefail

HARNESS="${HARNESS:-/root/harness}"
DIR="" OUTF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --accounts-dir) DIR="${2:-}"; shift 2 || { echo "--accounts-dir needs a value" >&2; exit 2; } ;;
    --out)          OUTF="${2:-}"; shift 2 || { echo "--out needs a value" >&2; exit 2; } ;;
    -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$DIR" ]; then
  # shellcheck source=/dev/null
  . "$(dirname "$0")/lib/env-path.sh" 2>/dev/null || . "$HARNESS/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "$HARNESS/env"; }
  DIR="$(harness_env_dir "$HARNESS")/accounts.d"
fi
[ -d "$DIR" ] && [ -r "$DIR" ] || { echo "accounts dir not readable: $DIR" >&2; exit 2; }

# _val <file> <KEY> — the first KEY= value, one surrounding quote pair removed.
_val() {
  local v; v=$(grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2-)
  case "$v" in \"*\") v="${v#\"}"; v="${v%\"}" ;; \'*\') v="${v#\'}"; v="${v%\'}" ;; esac
  printf '%s' "$v"
}

SQL="" N=0
for f in "$DIR"/*.env; do
  [ -f "$f" ] || continue
  name=$(basename "$f" .env)
  if ! grep -qE '^[a-z0-9][a-z0-9._-]{0,39}$' <<<"$name" || [ "$name" = default ]; then
    echo "skip $f: not an account name" >&2; continue
  fi
  an=$(_val "$f" ACCOUNT_NAME)
  [ -z "$an" ] || [ "$an" = "$name" ] || { echo "skip $f: ACCOUNT_NAME '$an' is not the file's stem" >&2; continue; }
  label=$(_val "$f" ACCOUNT_LABEL)
  [ -n "$label" ] || continue
  case "$label" in
    *,*|*\"*|*$'\r'*) echo "refused: $name's ACCOUNT_LABEL carries a comma, quote or CR; fix $f first" >&2; exit 2 ;;
  esac
  [ "${#label}" -le 128 ] || { echo "refused: $name's ACCOUNT_LABEL is longer than 128 chars" >&2; exit 2; }
  ql=${label//\'/\'\'}
  id=${name//[.-]/_}
  SQL+="-- $name -> $ql"$'\n'
  SQL+="SELECT COUNT(*) AS before_$id FROM cost_rows WHERE auth_account = 'acct:$name';"$'\n'
  SQL+="UPDATE cost_rows SET auth_account = '$ql',"$'\n'
  SQL+="       raw = REPLACE(raw, ',acct:$name,', ',$ql,')"$'\n'
  SQL+=" WHERE auth_account = 'acct:$name';"$'\n'
  SQL+="SELECT COUNT(*) AS after_$id FROM cost_rows WHERE auth_account = 'acct:$name';"$'\n'
  N=$((N+1))
done
[ "$N" -gt 0 ] || { echo "no account in $DIR has an ACCOUNT_LABEL: nothing to rewrite" >&2; exit 1; }
if [ -n "$OUTF" ]; then
  printf '%s' "$SQL" > "$OUTF" || { echo "cannot write $OUTF" >&2; exit 2; }
  echo "wrote $N account block(s) to $OUTF; review it, then: wrangler d1 execute harness-jobs --remote --file=$OUTF" >&2
else
  printf '%s' "$SQL"
fi
exit 0
