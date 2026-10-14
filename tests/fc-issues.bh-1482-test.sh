#!/bin/bash
# tests/fc-issues.bh-1482-test.sh — the issues-lane RECORD READER.
#
# WHY. children.txt is the only evidence that a child issue exists on the
# client's repo, and bin/lib/fc-issues.sh read it with a bare
# `while IFS= read -r`. That loop drops a final line with no newline, so a
# hand-edited record read SHORT: a one-line record read as EMPTY and the rerun
# re-filed every child on someone's repo and reported success. A blank line read
# as "no child at this ordinal", so a rerun filed a duplicate for it and
# appended it after the real lines, leaving every later rerun's ordinal map
# wrong. A non-blank malformed line failed closed, but named an empty issue
# number ("cannot read issue #").
#
# This suite drives the real production entry point (bin/run-decompose.sh) with
# the same gh stub tests/run-decompose.bh-1341-test.sh uses, and asserts on gh
# call counts, children.txt BYTES and the operator-facing text — never on source.
#
# No network, no model, no secrets. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/fc-issues.bh-1482-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export GH_CLI_REST_ADAPTER="$DIR/tests/lib/gh-cli-rest-adapter.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

DEC="$DIR/bin/run-decompose.sh"
[ -x "$DEC" ] && ok || bad "bin/run-decompose.sh is missing or not executable"

mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/env" "$T/h/prompts" "$T/fakebin"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T/h" scoutish || exit 1  # BH-1510.2: lanes read models from model_routes
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset> [box] [ip]
scoutish   example-org/scoutish   https://scoutish.example  -  9 box-1 10.0.0.9
CONF
export FLEET_CONF="$T/h/fleet.conf"

cat > "$T/h/bin/agent-call.sh" <<'SH'
#!/bin/bash
echo "AGENT CALL: $*" >> "$AGENT_LOG"
exit 0
SH
chmod +x "$T/h/bin/agent-call.sh"

SPEC='[
 {"title":"metrics table + read API","contract":"src/db/metrics.ts: MetricRow; src/api/metrics.ts: GET /api/metrics","after":[],"body":"Create the table and the read endpoint.\n\nFiles: src/db/metrics.ts, src/api/metrics.ts\nTests: tests/metrics.test.ts\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"dashboard tile","after":[1],"body":"Render the tile against the read API.\n\nFiles: src/app/dashboard/MetricTile.tsx\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"weekly digest email","after":[],"body":"Send the digest.\n\nFiles: src/jobs/digest.ts\n\n## Observable outcome\nThe slice acceptance test passes end to end."}
]'

export TITLE0='TK-552.0: contract — metrics table + read API'
export TITLE1='TK-552.1: dashboard tile'
export TITLE2='TK-552.2: weekly digest email'

cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
. "${GH_CLI_REST_ADAPTER:?}" || exit 1; gh_cli_rest "$0" post "$@" && exit 0
echo "$*" >> "$GH_CALLS"
case "$1 $2" in
  "issue view")
    ISSUE="$3"
    # The parent's labels — both the inheritance read (BH-637) and the
    # complete-rerun re-park read (BH-1482) ask for this shape.
    if grep -qF -- '--json labels' <<<"$*"; then
      PLJ="${PARENT_LABELS_JSON:-}"
      [ -n "$PLJ" ] || PLJ='{"labels":[]}'
      printf '%s\n' "$PLJ"
      exit 0
    fi
    # The real gh -q flag extracts a field from the JSON; simulate it.
    if grep -qF '.title' <<<"$*"; then
      case "$ISSUE" in
        701) printf '%s\n' "$TITLE0" ;;
        702) printf '%s\n' "$TITLE1" ;;
        703) printf '%s\n' "$TITLE2" ;;
        *)   printf 'unknown\n' ;;
      esac
    fi
    ;;
  "issue create")
    TITLE=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --title) TITLE="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    case "$TITLE" in
      "$TITLE0") echo "https://github.com/example-org/scoutish/issues/701" ;;
      "$TITLE1")
        if [ "${GH_FAIL_MODE:-}" = "fail-child2" ]; then
          echo "gh: HTTP 401: Bad credentials"; exit 1
        else
          echo "https://github.com/example-org/scoutish/issues/702"
        fi ;;
      "$TITLE2") echo "https://github.com/example-org/scoutish/issues/703" ;;
    esac ;;
  "issue comment"|"issue edit") echo "ok" ;;
esac
exit 0
SH
chmod +x "$T/fakebin/gh"

_drive() {
  local mode="$1"; shift
  mkdir -p "$T/b"
  printf '%s\n' "$SPEC" > "$T/b/children.json"
  printf 'SIZE_DECLARED: files=18 lines=1900\nSIZE_OVER: lines=1900>300; files=18>12\nSIZE_VERDICT: over\n' > "$T/b/size-gate.txt"
  # Every artifact this run is judged on starts empty, so a later assertion can
  # never pass on a line an earlier section wrote.
  : > "$T/agent.log"; : > "$T/gh.calls"
  : > "$T/b/pipeline.log"; : > "$T/b/decompose-run.txt"
  env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" AGENT_LOG="$T/agent.log" GH_CALLS="$T/gh.calls" \
      GH_FAIL_MODE="$mode" PARENT_LABELS_JSON="${PARENT_LABELS_JSON:-}" PATH="$T/fakebin:$PATH" "$@" \
      "$DEC" scoutish 552 TK-552 "$T/b" 300 12 2>&1
}

# _creates — how many `gh issue create` calls the run under test made.
_creates() { grep -c '^issue create' "$T/gh.calls"; }
# _views — how many `gh issue view` calls it made (0 is the claim for a record
# refused before any GitHub call).
_views() { grep -c '^issue view' "$T/gh.calls"; }
# _record — children.txt as the sweep would read it.
_record() { paste -sd, "$T/b/children.txt" 2>/dev/null; }
# _run — the operator-facing failure line the sweep SOP reads.
_run() { cat "$T/b/decompose-run.txt" 2>/dev/null; }

# ===========================================================================
# 1. a COMPLETE record whose last line has no newline: read it, file nothing
# ===========================================================================
mkdir -p "$T/b"
printf 'TK-701\nTS-702\nTS-703' > "$T/b/children.txt"
cp "$T/b/children.txt" "$T/ref.txt"
OUT=$(_drive succeed); RC=$?
[ "$RC" -eq 0 ] && ok || bad "1: an unterminated complete record must exit 0 (rc=$RC): $OUT"
[ "$(_creates)" -eq 0 ] \
  && ok || bad "1: an unterminated complete record must file nothing (creates=$(_creates), record='$(_record)')"
cmp -s "$T/b/children.txt" "$T/ref.txt" \
  && ok || bad "1: an unterminated complete record must stay byte-identical (got: '$(_record)')"
grep -q 'nothing re-filed' "$T/b/pipeline.log" \
  && ok || bad "1: a complete rerun must log that it re-filed nothing"

# ===========================================================================
# 2. a BLANK first line is not "no child at ordinal 1" — fail closed, no calls
# ===========================================================================
printf '\nTS-702\n' > "$T/b/children.txt"
cp "$T/b/children.txt" "$T/ref.txt"
OUT=$(_drive succeed); RC=$?
[ "$RC" -ne 0 ] && ok || bad "2: a blank record line must exit non-zero (rc=$RC)"
[ "$(_creates)" -eq 0 ] \
  && ok || bad "2: a blank record line must file nothing (creates=$(_creates))"
[ "$(_views)" -eq 0 ] \
  && ok || bad "2: a malformed record must be refused before any GitHub call (views=$(_views))"
cmp -s "$T/b/children.txt" "$T/ref.txt" \
  && ok || bad "2: a refused record must be left as it was (got: '$(_record)')"
_run | grep -q 'children.txt line 1 is not a child key' \
  && ok || bad "2: the failure must name the line (got: $(_run))"

# ===========================================================================
# 3. a TRAILING blank line is refused too, and named by its own line number
# ===========================================================================
printf 'TK-701\n\n' > "$T/b/children.txt"
cp "$T/b/children.txt" "$T/ref.txt"
OUT=$(_drive succeed); RC=$?
[ "$RC" -ne 0 ] && ok || bad "3: a trailing blank record line must exit non-zero (rc=$RC)"
[ "$(_creates)" -eq 0 ] \
  && ok || bad "3: a trailing blank line must file nothing (creates=$(_creates))"
[ "$(_views)" -eq 0 ] \
  && ok || bad "3: a trailing blank line must be refused before any GitHub call (views=$(_views))"
cmp -s "$T/b/children.txt" "$T/ref.txt" \
  && ok || bad "3: a refused record must be left as it was (got: '$(_record)')"
_run | grep -q 'children.txt line 2 is not a child key' \
  && ok || bad "3: the failure must name line 2 (got: $(_run))"

# ===========================================================================
# 4. a non-blank malformed line: named verbatim, never "cannot read issue #"
# ===========================================================================
printf 'garbage\n' > "$T/b/children.txt"
cp "$T/b/children.txt" "$T/ref.txt"
OUT=$(_drive succeed); RC=$?
[ "$RC" -ne 0 ] && ok || bad "4: a malformed record line must exit non-zero (rc=$RC)"
[ "$(_creates)" -eq 0 ] \
  && ok || bad "4: a malformed record line must file nothing (creates=$(_creates))"
[ "$(_views)" -eq 0 ] \
  && ok || bad "4: a malformed record must be refused before any GitHub call (views=$(_views))"
cmp -s "$T/b/children.txt" "$T/ref.txt" \
  && ok || bad "4: a refused record must be left as it was (got: '$(_record)')"
_run | grep -q "children.txt line 1 is not a child key ('garbage')" \
  && ok || bad "4: the failure must quote the line it refused (got: $(_run))"
grep -q 'cannot read issue #' <<<"$(_run)" \
  && bad "4: a malformed line must never be reported as an unreadable issue with an empty number (got: $(_run))" || ok

# ===========================================================================
# 5. a PARTIAL record with an unterminated last line: file exactly the missing
#    two, on their own lines — never glued onto the hand-edited one
# ===========================================================================
printf 'TK-701' > "$T/b/children.txt"
OUT=$(_drive succeed); RC=$?
[ "$RC" -eq 0 ] && ok || bad "5: a partial unterminated record must complete and exit 0 (rc=$RC): $OUT"
[ "$(_creates)" -eq 2 ] \
  && ok || bad "5: only the two missing children may be filed (creates=$(_creates))"
grep -qF -- "--title $TITLE0" "$T/gh.calls" \
  && bad "5: the recorded contract child must never be re-filed" || ok
[ "$(_record)" = "TK-701,TK-702,TK-703" ] \
  && ok || bad "5: the completed record must hold each child exactly once (got: '$(_record)')"
[ "$(grep -c '' "$T/b/children.txt")" -eq 3 ] \
  && ok || bad "5: the completed record must be three lines (got: $(grep -c '' "$T/b/children.txt"))"
grep -q 'TK-701TS-702' "$T/b/children.txt" \
  && bad "5: a new key must never be appended onto an unterminated last line (got: '$(_record)')" || ok

# ===========================================================================
# 6. the missing list starts at the child that FAILED, not the one after it
# ===========================================================================
: > "$T/b/children.txt"
OUT=$(_drive fail-child2); RC=$?
[ "$RC" -ne 0 ] && ok || bad "6: a failed create must exit non-zero (rc=$RC)"
_run | grep -q 'missing children: child 2, child 3' \
  && ok || bad "6: the missing list must start at the child that failed (got: $(_run))"

# ===========================================================================
# 7. a complete rerun re-parks a parent that still carries ai-build, and does
#    NOT re-post the split comment
# ===========================================================================
printf 'TK-701\nTS-702\nTS-703\n' > "$T/b/children.txt"
cp "$T/b/children.txt" "$T/ref.txt"
PARENT_LABELS_JSON='{"labels":[{"name":"ai-build"},{"name":"hotfix"}]}'
OUT=$(_drive succeed); RC=$?
[ "$RC" -eq 0 ] && ok || bad "7: a complete rerun must exit 0 (rc=$RC): $OUT"
[ "$(_creates)" -eq 0 ] \
  && ok || bad "7: a complete rerun must file nothing (creates=$(_creates))"
grep -q '^issue comment' "$T/gh.calls" \
  && bad "7: a complete rerun must never re-post the split comment" || ok
[ "$(grep -c 'remove-label' "$T/gh.calls")" -eq 1 ] \
  && ok || bad "7: a still-labelled parent must be unlabelled exactly once (got: $(grep -c 'remove-label' "$T/gh.calls"))"
cmp -s "$T/b/children.txt" "$T/ref.txt" \
  && ok || bad "7: re-parking the parent must not touch the record (got: '$(_record)')"
grep -q 'unlabelled now' "$T/b/pipeline.log" \
  && ok || bad "7: the re-park must be logged"

# ===========================================================================
# 8. a parent that no longer carries ai-build is left alone
# ===========================================================================
printf 'TK-701\nTS-702\nTS-703\n' > "$T/b/children.txt"
PARENT_LABELS_JSON='{"labels":[{"name":"hotfix"}]}'
OUT=$(_drive succeed); RC=$?
[ "$RC" -eq 0 ] && ok || bad "8: a complete rerun must exit 0 (rc=$RC): $OUT"
grep -q 'remove-label' "$T/gh.calls" \
  && bad "8: a parent that is already unlabelled must not be edited (calls: $(grep 'issue edit' "$T/gh.calls"))" || ok
PARENT_LABELS_JSON=''

echo "fc-issues.bh-1482: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
