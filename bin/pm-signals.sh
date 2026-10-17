#!/bin/bash
# pm-signals.sh <project> <out.json> — the PM agent's read-only product data
# snapshot (BH-7244). bin/run-product.sh runs it before SIGNALS and gives the
# file to that stage as DATA_SIGNALS=, so a data signal cites a counted row.
#
# Registry: $PM_SIGNALS_DIR (default: pm-signals.d beside this script). It runs
# every common-*.sh (C glob order), then <project>.sh if it exists. Each file
# defines exactly ONE function pms_<name>; it is called with <project> and
# prints evidence rows as JSON lines:
#   {id, source, metric, value, window, link, status}
# status is "ok", "not-configured" (no read path) or "error".
#
# Each file runs in its own child under timeout ${PM_SIGNALS_ADAPTER_TIMEOUT_S:-30}s.
# A file that fails drops its own rows and gives ONE row instead:
#   {id:"adapter.<name>", source:"<name>", metric:"adapter_rc", value:<rc>,
#    window:"", link:"bin/pm-signals.d/<file>", status:"error"}
# <name> is the file name without "common-" and ".sh". <rc> is the function's
# rc, 124 for a timeout, 97 for a file that does not source, 98 for a file
# without exactly one pms_ function, 96 for a line that is not a JSON object
# with string id, source and status. The other adapters still run.
#
# Output: {snapshot_hash, generated_at, evidence:[...]}, evidence sorted by
# (id, source). snapshot_hash = sha256 of the sorted evidence array only, so the
# same inputs give the same hash. generated_at is ${PM_SIGNALS_NOW:-now}.
# The file is written to <out>.tmp.<pid> and moved into place.
#
# Exit: 0 a file written (error rows possible), 1 <out> cannot be written,
# 2 usage. Read-only: it writes <out> and its tmp files, nothing else.
set -uo pipefail
export HARNESS="${HARNESS:-/root/harness}"

usage() { echo "usage: pm-signals.sh <project> <out.json>" >&2; exit 2; }
[ $# -eq 2 ] || usage
PROJECT=$1; OUT=$2
[[ $PROJECT =~ ^[A-Za-z0-9._-]+$ ]] && [ "$PROJECT" != . ] && [ "$PROJECT" != .. ] || usage
[ -n "$OUT" ] || usage

REG="${PM_SIGNALS_DIR:-$(dirname "$(readlink -f "$0")")/pm-signals.d}"
TIMEOUT_S="${PM_SIGNALS_ADAPTER_TIMEOUT_S:-30}"
NOW="${PM_SIGNALS_NOW:-$(date +%s)}"
export PM_SIGNALS_NOW="$NOW"

TMP="$OUT.tmp.$$"
trap 'rm -f "$TMP" "$TMP.rows" "$TMP.one"' EXIT
: 2>/dev/null > "$TMP" || { echo "pm-signals: cannot write $OUT" >&2; exit 1; }
: > "$TMP.rows"

FILES=()
for f in "$REG"/common-*.sh; do [ -f "$f" ] && FILES+=("$f"); done
case "$PROJECT" in common-*) ;; *) [ -f "$REG/$PROJECT.sh" ] && FILES+=("$REG/$PROJECT.sh") ;; esac

for f in "${FILES[@]}"; do
  file=${f##*/}; name=${file%.sh}; name=${name#common-}
  # The child's stdout goes to a file, not a pipe: a killed adapter's own
  # children cannot hold the runner open past the timeout.
  # shellcheck disable=SC2016  # $1/$2 belong to the child shell
  timeout "$TIMEOUT_S" bash -c '. "$1" || exit 97
    fns=$(compgen -A function pms_)
    [ "$(wc -w <<<"$fns")" = 1 ] || exit 98
    "$fns" "$2"' _ "$f" "$PROJECT" > "$TMP.one" < /dev/null
  rc=$?
  if [ "$rc" = 0 ]; then
    rows=$(jq -Rsc '[split("\n")[] | select(test("\\S")) | (fromjson? // "bad")]
      | if all(type == "object" and (.id|type) == "string" and (.source|type) == "string" and (.status|type) == "string")
        then .[] else error("bad") end' "$TMP.one" 2>/dev/null) || rc=96
  fi
  if [ "$rc" = 0 ]; then
    [ -n "$rows" ] && printf '%s\n' "$rows" >> "$TMP.rows"
  else
    echo "pm-signals: adapter $file rc=$rc" >&2
    jq -nc --arg n "$name" --arg f "$file" --argjson rc "$rc" \
      '{id:("adapter."+$n), source:$n, metric:"adapter_rc", value:$rc, window:"", link:("bin/pm-signals.d/"+$f), status:"error"}' >> "$TMP.rows"
  fi
done

EVIDENCE=$(jq -sc 'sort_by(.id, .source)' "$TMP.rows") || { echo "pm-signals: cannot sort the rows" >&2; exit 1; }
HASH=$(jq -cS . <<<"$EVIDENCE" | sha256sum | cut -d' ' -f1)
GEN=$(date -u -d "@$NOW" '+%Y-%m-%dT%H:%M:%SZ')
jq -n --arg h "$HASH" --arg g "$GEN" --argjson e "$EVIDENCE" \
  '{snapshot_hash:$h, generated_at:$g, evidence:$e}' > "$TMP" \
  && mv "$TMP" "$OUT" || { echo "pm-signals: cannot write $OUT" >&2; exit 1; }
exit 0
