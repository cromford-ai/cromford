#!/bin/bash
# tests/nightly-ticket-refuse.bh-8272-test.sh — with no harness App token the
# nightly-red filer opens no issue (BH-8272). An issue it opened as the
# workflow token was labelled `ai-build` by github-actions[bot], which the
# trigger-actor gate refuses, so the ticket waited for nobody (#8139).
#
# Drives the real bin/nightly-ticket.sh against a stub gh that records the
# GH_TOKEN of every call (`<token><TAB><argv>`, the BH-6957 stub shape):
#   N1  NT_APP_TOKEN empty, one red suite, no open issue: rc != 0, 0 creates,
#       the exact refusal line on stderr
#   N2  NT_APP_TOKEN absent from the environment: the same as N1
#   N3  empty token, two red suites plus a run-level ticket, under Actions:
#       the refusal line once, one ::error::, no ::warning::, 0 creates
#   N4  empty token, the suite has an open issue: the comment POST is made as
#       the workflow token, no create, no refusal line
#   N5  NT_APP_TOKEN set: one create per new suite, each as the App token,
#       rc 0, no refusal line
# Run from anywhere: tests/nightly-ticket-refuse.bh-8272-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
NT="$DIR/bin/nightly-ticket.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "nightly-ticket-refuse: jq missing — skipping"; exit 0; }

WF_TOK=wf-tok-fixture
APP_TOK=app-tok-fixture
REFUSE='nightly-ticket: no App token; refusing to file a ticket the trigger-actor gate would ignore'

cat > "$T/gh" <<'GH'
#!/bin/bash
printf '%s\t%s\n' "${GH_TOKEN:-}" "$*" >> "$FAKE_SINK"
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
    */labels) printf '[{"name":"ai-build"}]\n' | jq -r "${JQ:-.}"; exit 0 ;;
    */comments) printf '{"id":1}\n' | jq -r "${JQ:-.}"; exit 0 ;;
  esac
  N=$(( $(cat "$FAKE_N" 2>/dev/null || echo 100) + 1 )); echo "$N" > "$FAKE_N"
  jq -n --argjson n "$N" '{number:$n, labels:[{name:"ai-build"}]}' | jq -r "${JQ:-.}"
  exit 0
fi
jq -r "$JQ" "$FAKE_OPEN"
GH
chmod +x "$T/gh"

# every fixture lives in this run's own $T, so parallel runs share nothing
mkdir -p "$T/v1" "$T/v2"
printf 'tests=1\nfailed=1\n' > "$T/v1/shard-0.txt"
printf -- '--- tests/a-test.sh rc=1 1s\n' > "$T/v1/shard-0.log"
printf 'tests=2\nfailed=2\n' > "$T/v2/shard-0.txt"
printf -- '--- tests/a-test.sh rc=1 1s\n--- tests/b-test.sh rc=1 1s\n' > "$T/v2/shard-0.log"
printf '[]\n' > "$T/none.json"
jq -n --arg m '<!-- harness-nightly-red:tests/a-test.sh -->' '[{number:77,body:("old " + $m)}]' > "$T/open.json"

run() { # run <verdict-dir> <open.json> [env args ...] — env args may start with -u NAME
  local v="$1" open="$2"; shift 2
  : > "$T/sink"; rm -f "$T/n"
  OUT=$(env "$@" GH_TOKEN="$WF_TOK" NT_GH="$T/gh" FAKE_SINK="$T/sink" FAKE_N="$T/n" FAKE_OPEN="$open" \
          NT_REPO=o/r NT_SHA=abc NT_PLAN_RESULT=success \
          bash "$NT" "$v" 2>"$T/err"); RC=$?
  ERR=$(cat "$T/err")
}
creates() { grep -cP '\tapi -X POST repos/o/r/issues -f' "$T/sink"; }
refusals() { grep -cxF "$REFUSE" "$T/err"; }

# ── N1 ──────────────────────────────────────────────────────────────────────
run "$T/v1" "$T/none.json" NT_APP_TOKEN= NT_PLAN_N=1
[ "$RC" != 0 ] && ok || bad "N1: rc must be non-zero with no App token (got $RC; err: $ERR)"
[ "$(creates)" = 0 ] && ok || bad "N1: no create may be made: $(cat "$T/sink")"
[ "$(refusals)" = 1 ] && ok || bad "N1: the exact refusal line once on stderr: $ERR"
grep -q "	new	" "$T/v1/ticket-requests.tsv" && bad "N1: a refused create writes no new row" || ok

# ── N2 ──────────────────────────────────────────────────────────────────────
run "$T/v1" "$T/none.json" -u NT_APP_TOKEN NT_PLAN_N=1
[ "$RC" != 0 ] && ok || bad "N2: rc must be non-zero with NT_APP_TOKEN unset (got $RC)"
[ "$(creates)" = 0 ] && ok || bad "N2: no create may be made: $(cat "$T/sink")"
[ "$(refusals)" = 1 ] && ok || bad "N2: the exact refusal line once: $ERR"

# ── N3 ──────────────────────────────────────────────────────────────────────
# NT_PLAN_N=2 with one shard: shard 1 left no verdict, so a run-level ticket is
# needed too. Three creates asked, three refused, one line.
run "$T/v2" "$T/none.json" NT_APP_TOKEN= NT_PLAN_N=2 GITHUB_ACTIONS=true
[ "$RC" != 0 ] && ok || bad "N3: rc must be non-zero (got $RC)"
[ "$(creates)" = 0 ] && ok || bad "N3: no create may be made: $(cat "$T/sink")"
[ "$(refusals)" = 1 ] && ok || bad "N3: two suites and a run-level ticket give ONE refusal line: $ERR"
[ "$(grep -c '^::error::' "$T/err")" = 1 ] && ok || bad "N3: exactly one ::error:: under Actions: $ERR"
grep -qxF "::error::$REFUSE" "$T/err" && ok || bad "N3: the ::error:: carries the refusal text: $ERR"
grep -q '::warning::' "$T/err" && bad "N3: the warning path is gone: $ERR" || ok
grep -q 'could not open an issue on o/r$' "$T/err" && ok || bad "N3: the run-level create is refused too: $ERR"

# ── N4 ──────────────────────────────────────────────────────────────────────
run "$T/v1" "$T/open.json" NT_APP_TOKEN= NT_PLAN_N=1
CMT='api -X POST repos/o/r/issues/77/comments'
[ "$(grep -cP "\t$CMT" "$T/sink")" = 1 ] && ok || bad "N4: the comment on the open issue still posts: $(cat "$T/sink")"
[ "$(grep -P "\t$CMT" "$T/sink" | cut -f1)" = "$WF_TOK" ] && ok || bad "N4: the comment is made as the workflow token"
[ "$(creates)" = 0 ] && ok || bad "N4: no create for an open issue"
[ "$(refusals)" = 0 ] && ok || bad "N4: a comment is not a file, no refusal line: $ERR"
[ "$RC" = 0 ] && ok || bad "N4: a comment-only night is rc 0 (got $RC; err: $ERR)"

# ── N5 ──────────────────────────────────────────────────────────────────────
run "$T/v2" "$T/none.json" NT_APP_TOKEN="$APP_TOK" NT_PLAN_N=1
[ "$RC" = 0 ] && ok || bad "N5: rc 0 with the App token (got $RC; err: $ERR)"
[ "$(creates)" = 2 ] && ok || bad "N5: one create per new suite: $(cat "$T/sink")"
[ "$(grep -P '\tapi -X POST repos/o/r/issues -f' "$T/sink" | cut -f1 | sort -u)" = "$APP_TOK" ] && ok \
  || bad "N5: every create carries the App token: $(cat "$T/sink")"
[ "$(refusals)" = 0 ] && ok || bad "N5: no refusal line with the token: $ERR"
[ "$(grep -c '	new	' "$T/v2/ticket-requests.tsv")" = 2 ] && ok || bad "N5: two new rows: $(cat "$T/v2/ticket-requests.tsv")"

echo "nightly-ticket-refuse: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
