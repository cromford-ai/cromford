#!/bin/bash
# bin/cmd-run-script.sh <project> <payload-json> <command_id> — the console's
# run_script command (BH-6737). Runs on the box that owns <project> (the hub
# for `hub`), through bcx_run in bin/lib/box-cmd-exec.sh.
#
# payload {script: "<name>.sh", args: [<string>, ...]}. It runs bin/<script>
# ONLY when <script> is an exact entry of the allowlist: the union of
# catalog/run-script-allowlist.json and every catalog/run-script-allowlist.d/*.json
# (the same {about, scripts} shape; a ticket adds its own fragment). Adding a
# script is a reviewed PR. Every check passes before anything runs:
#   - script matches ^[A-Za-z0-9][A-Za-z0-9._-]*\.sh$ (no `/`, no `..`), is a
#     list entry, and bin/<script> is an executable file;
#   - args is absent or an array of at most 16 strings, each at most 512
#     chars, with no NUL.
# A missing or unparseable main file or fragment refuses everything (fail closed).
#
# Args reach the script as argv elements only: no eval, no sh -c, no word
# splitting. The run is bounded by CMD_RUN_SCRIPT_TIMEOUT_S (default 300 s).
# stdout+stderr are appended to logs/run-script.log between
#   === run_script id=<id> box=<host> script=<s> argc=<n> at=<ts>
#   === end id=<id> rc=<rc>
# (arg VALUES are not logged), and bin/fetch-log.sh serves that log as
# which=run_script. A log over 1 MB keeps its last 256 KB before the append.
#
# Prints ONE JSON line: {result, script, rc, log, which, tail, reason}. The
# script's own exit code is reported in rc: a script that ran is result ok,
# whatever its rc. A timeout is result failed (rc 124).
# Exit 0 ran, 3 refused, 1 failed (timeout, or the log could not be written).
set -uo pipefail
H="${HARNESS:-/root/harness}"
PROJECT="${1:-}"; PAYLOAD="${2:-}"; CID="${3:-}"
AL="$H/catalog/run-script-allowlist.json"
LOG="$H/logs/run-script.log"
SCRIPT=""

emit() { # emit <rc> <result> <reason> [script-rc] [tail]
  jq -nc --arg r "$2" --arg s "$SCRIPT" --arg src "${4:-}" --arg t "${5:-}" --arg why "${3:0:200}" \
    '{result:$r, script:$s}
     + (if $src == "" then {} else {rc:($src|tonumber), log:"logs/run-script.log", which:"run_script", tail:$t} end)
     + {reason:$why}'
  exit "$1"
}

if [ "$PROJECT" != hub ]; then
  [[ "$PROJECT" =~ ^[A-Za-z0-9._-]{1,64}$ ]] && "$H/bin/fleet-conf.sh" --projects 2>/dev/null | grep -qxF -- "$PROJECT" \
    || emit 3 refused "'$PROJECT' is neither hub nor a fleet.conf project"
fi
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$PAYLOAD" || emit 3 refused "payload is not a JSON object"
al_names() { # al_names <file> — its scripts, one per line; rc 1 when the shape is wrong
  jq -r 'if type == "object" and (.scripts|type) == "array" and all(.scripts[]; type == "string")
         then .scripts[] else error("bad") end' "$1" 2>/dev/null
}
NAMES=$(al_names "$AL") || emit 3 refused "allowlist unreadable (catalog/run-script-allowlist.json); nothing runs"
for f in "$H/catalog/run-script-allowlist.d/"*.json; do
  [ -e "$f" ] || continue
  FN=$(al_names "$f") || emit 3 refused "allowlist fragment ${f##*/} unreadable; nothing runs"
  NAMES+=$'\n'"$FN"
done
LIST=$(printf '%s\n' "$NAMES" | grep -v '^$' | tr '\n' ' '); LIST="${LIST% }"
S=$(jq -r 'if (.script|type) == "string" then .script else "" end' <<<"$PAYLOAD")
[[ "$S" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.sh$ ]] && [[ "$S" != *..* ]] \
  || emit 3 refused "script must be a plain <name>.sh on the allowlist: $LIST"
grep -qxF -- "$S" <<<"$NAMES" || emit 3 refused "$S is not on the allowlist: $LIST"
SCRIPT="$S"
[ -f "$H/bin/$S" ] && [ -x "$H/bin/$S" ] || emit 3 refused "bin/$S is listed but is not an executable file on this box"
jq -e '(has("args") | not) or .args == null
       or ((.args|type) == "array" and (.args|length) <= 16
           and all(.args[]; type == "string" and length <= 512 and (contains("\u0000") | not)))' \
  >/dev/null 2>&1 <<<"$PAYLOAD" || emit 3 refused "args must be an array of at most 16 strings of at most 512 chars"

ARGS=()
mapfile -d '' ARGS < <(jq -j '.args[]? | . + "\u0000"' <<<"$PAYLOAD")

mkdir -p "$H/logs" || emit 1 failed "cannot create logs/"
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 1048576 ]; then
  { tail -c 262144 "$LOG" > "$LOG.trim.$$" && mv "$LOG.trim.$$" "$LOG"; } || rm -f "$LOG.trim.$$"
fi
SID=$(printf '%s' "$CID" | tr -dc 'A-Za-z0-9_.:-' | head -c 64)
OUTF=$(mktemp "${TMPDIR:-/tmp}/run-script.XXXXXX") || emit 1 failed "no temp file"
TO="${CMD_RUN_SCRIPT_TIMEOUT_S:-300}"
case "$TO" in ''|*[!0-9]*) TO=300 ;; esac
timeout "$TO" "$H/bin/$S" "${ARGS[@]}" </dev/null >"$OUTF" 2>&1 7>&- 9>&-; RC=$?
TAIL=$(tail -c 300 "$OUTF")
{ printf '=== run_script id=%s box=%s script=%s argc=%s at=%s\n' \
    "$SID" "$(hostname 2>/dev/null || echo unknown)" "$S" "${#ARGS[@]}" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  cat "$OUTF"
  [ -s "$OUTF" ] && [ -n "$(tail -c 1 "$OUTF")" ] && echo
  printf '=== end id=%s rc=%s\n' "$SID" "$RC"
} >> "$LOG"; LRC=$?
rm -f "$OUTF"
[ "$RC" = 124 ] && emit 1 failed "bin/$S timed out after ${TO}s" "$RC" "$TAIL"
[ "$LRC" = 0 ] || emit 1 failed "bin/$S ran (rc $RC), but logs/run-script.log could not be written" "$RC" "$TAIL"
emit 0 ok "bin/$S ran with $(( ${#ARGS[@]} )) arg(s), rc $RC" "$RC" "$TAIL"
