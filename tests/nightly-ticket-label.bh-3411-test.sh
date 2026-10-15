#!/bin/bash
# tests/nightly-ticket-label.bh-3411-test.sh — the nightly ticket is opened
# labelled `ai-build` (BH-3411), so a red nightly reaches a builder.
#
# Drives the real bin/nightly-ticket.sh against a stub gh:
#   L1  no open ticket, create answers with ai-build: rc 0, the create call
#       carries labels[]=ai-build, stdout `opened #101`
#   L2  an open ticket with the marker: `updated #77`, no call mentions labels
#       (a ticket someone unlabelled stays unlabelled)
#   L3  the create answer has no labels (GitHub dropped them): exactly one
#       POST repos/o/r/issues/101/labels with labels[]=ai-build, rc 0
#   L4  the create answer already carries ai-build: no /labels POST
#   L5  labels dropped AND the labels endpoint refuses: rc 1, stderr names it
# Run from anywhere: tests/nightly-ticket-label.bh-3411-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
NT="$DIR/bin/nightly-ticket.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "nightly-ticket-label: jq missing — skipping"; exit 0; }

# The stub gh records every argv. A GET answers $FAKE_OPEN through --jq; the
# create POST answers $FAKE_CREATE_JSON through --jq; a POST to .../labels is
# refused when FAKE_FAIL_LABELS is set.
cat > "$T/gh" <<'GH'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_SINK"
JQ=""; POST=0; P=""
while [ $# -gt 0 ]; do
  case "$1" in
    api) ;;
    --jq) JQ="$2"; shift ;;
    -X) [ "$2" = POST ] && POST=1; shift ;;
    -F|-f) shift ;;
    --paginate) ;;
    *) P="$1" ;;
  esac
  shift
done
if [ "$POST" = 1 ]; then
  case "$P" in
    */labels) [ -n "${FAKE_FAIL_LABELS:-}" ] && exit 1
              printf '[{"name":"ai-build"}]\n' | jq -r "${JQ:-.}"; exit 0 ;;
    */comments) printf '{"id":1}\n' | jq -r "${JQ:-.}"; exit 0 ;;
  esac
  printf '%s\n' "$FAKE_CREATE_JSON" | jq -r "${JQ:-.}"
  exit 0
fi
jq -r "$JQ" "$FAKE_OPEN"
GH
chmod +x "$T/gh"

mkdir -p "$T/v"
printf 'tests=1\nfailed=1\n' > "$T/v/shard-0.txt"
printf -- '--- tests/a-test.sh rc=1 1s\n' > "$T/v/shard-0.log"
MARK='<!-- harness-nightly-red:tests/a-test.sh -->'
printf '[]\n' > "$T/none.json"
jq -n --arg m "$MARK" '[{number:77,body:("old " + $m)}]' > "$T/open.json"
LABELLED='{"number":101,"labels":[{"name":"ai-build"}]}'
DROPPED='{"number":101,"labels":[]}'

run() { # run <open.json> <create-json> [VAR=value ...]
  local open="$1" create="$2"; shift 2
  : > "$T/sink"
  OUT=$(env NT_GH="$T/gh" FAKE_SINK="$T/sink" FAKE_OPEN="$open" FAKE_CREATE_JSON="$create" \
          NT_REPO=o/r NT_SHA=abc NT_PLAN_RESULT=success NT_PLAN_N=1 "$@" \
          bash "$NT" "$T/v" 2>"$T/err"); RC=$?
  ERR=$(cat "$T/err")
}
labels_posts() { grep -c '^api -X POST repos/o/r/issues/101/labels ' "$T/sink"; }

# L1
run "$T/none.json" "$LABELLED"
[ "$RC" = 0 ] && ok || bad "L1: rc $RC (err: $ERR)"
grep '^api -X POST repos/o/r/issues ' "$T/sink" | grep -q 'labels\[\]=ai-build' \
  && ok || bad "L1: the create call must carry labels[]=ai-build ($(cat "$T/sink"))"
[ "$OUT" = "nightly-ticket: opened #101" ] && ok || bad "L1: stdout was '$OUT'"

# L2
run "$T/open.json" "$LABELLED"
[ "$RC" = 0 ] && ok || bad "L2: rc $RC"
[ "$OUT" = "nightly-ticket: updated #77" ] && ok || bad "L2: stdout was '$OUT'"
grep -q labels "$T/sink" && bad "L2: updating an existing ticket must not touch labels ($(cat "$T/sink"))" || ok

# L3
run "$T/none.json" "$DROPPED"
[ "$RC" = 0 ] && ok || bad "L3: rc $RC (err: $ERR)"
[ "$(labels_posts)" = 1 ] && ok || bad "L3: expected exactly one labels POST, got $(labels_posts)"
grep '^api -X POST repos/o/r/issues/101/labels ' "$T/sink" | grep -q 'labels\[\]=ai-build' \
  && ok || bad "L3: the fallback must add ai-build"
[ "$OUT" = "nightly-ticket: opened #101" ] && ok || bad "L3: stdout was '$OUT'"

# L3b: a create answer with no labels key at all is "not labelled", not a jq error
run "$T/none.json" '{"number":101}'
[ "$RC" = 0 ] && [ "$(labels_posts)" = 1 ] && ok || bad "L3b: rc $RC, labels POSTs $(labels_posts)"

# L4
run "$T/none.json" "$LABELLED"
[ "$(labels_posts)" = 0 ] && ok || bad "L4: a labelled create must not POST labels again"

# L5
run "$T/none.json" "$DROPPED" FAKE_FAIL_LABELS=1
[ "$RC" = 1 ] && ok || bad "L5: rc must be 1 when the label cannot be applied (got $RC)"
case "$ERR" in *"opened #101 but could not label it ai-build"*) ok ;; *) bad "L5: stderr was '$ERR'" ;; esac
case "$OUT" in *"opened #101"*) bad "L5: must not report a clean open (stdout '$OUT')" ;; *) ok ;; esac

echo "nightly-ticket-label: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
