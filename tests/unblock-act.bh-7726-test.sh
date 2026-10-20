#!/bin/bash
# tests/unblock-act.bh-7726-test.sh — BH-7726 (UNB-4): the unblock lane's one
# writer, bin/lib/unblock/act.sh (ub_act), and its warn-only tripwires,
# bin/lib/unblock/tripwire.sh (ub_tripwire_scan).
#
# Sources the REAL libs and drives the two production entry points. It stubs
# only what they call: `gh` on PATH (answers from a per-case store, appends
# one line per call to $CALLS), the bin/ scripts under a scratch $HARNESS/bin
# (lead-verdict.sh, jobs-client.sh, lane-alert.sh, box-for.sh, box-ops.sh) and
# the shell functions the caller loads (mc_*, fix_round_enqueue, _jobs_req).
# Every case builds its own scratch $HARNESS with its own decision key. The
# clock is pinned with UB_NOW.
#
#   A1-A2    bad input and no root: rc 1, nothing read or written
#   A3-A7    refusal gates: never-auto, unknown action, the mode row
#   A8-A9    the verdict source `agent` preflight
#   A10-A13  head and marker gates
#   A14-A18  the queue and review arms (A14 = the #7699 fixture, in order)
#   A19-A22  fix round, lead re-request, box restart and its hour limit
#   A23-A27  the knob arm and its allowlist
#   A28-A30  the card through the critical DM
#   A31-A32  the corpus replay at the act layer, then a second pass
#   B1-B10   the tripwires; B10 = an alert never stops the next action
#
# Run from anywhere: bash tests/unblock-act.bh-7726-test.sh   (exit 0 = all pass)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
FX="$DIR/tests/fixtures/unblock-act.bh-7726"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SLUG=example-org/cromford
H42=4242f1c74242f1c74242f1c74242f1c74242f1c7
HOLD=0000f1c70000f1c70000f1c70000f1c70000f1c7
NOW0=1792512000          # 2026-10-20T16:00:00Z
export UB_NOW=$NOW0

# ── the gh stub (REST only: `gh api [-X M] <path> [--input f]`) ──────────────
mkdir -p "$T/pathbin"
cat > "$T/pathbin/gh" <<'EOF'
#!/bin/bash
[ "${1:-}" = api ] || { echo "gh stub: only gh api" >&2; exit 2; }
shift
m=GET path="" input=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m="$2"; shift 2 ;;
    --input) input="$2"; shift 2 ;;
    -*) echo "gh stub: unknown flag $1" >&2; exit 2 ;;
    *) path="$1"; shift ;;
  esac
done
echo "gh $m $path" >> "$CALLS"
[ -n "$input" ] && { jq -c . "$input" >> "$GHF/inputs.log" 2>/dev/null || echo "bad-json" >> "$GHF/inputs.log"; }
p="${path%%\?*}"
page=$(printf '%s' "$path" | sed -n 's/.*[?&]page=\([0-9]*\).*/\1/p'); page="${page:-1}"
slice() { jq -c --argjson pg "$page" '.[(($pg - 1) * 100):($pg * 100)]' "$1"; }
store() { [ -f "$1" ] || echo '[]' > "$1"; }
if [[ "$m $p" =~ ^GET\ repos/[^/]+/[^/]+/pulls/([0-9]+)$ ]]; then
  n="${BASH_REMATCH[1]}"; [ -f "$GHF/fail-head" ] && exit 1
  jq -nc --arg s "$(cat "$GHF/head-$n" 2>/dev/null)" '{number: 1, head: {sha: $s}}'
elif [[ "$m $p" =~ ^GET\ repos/[^/]+/[^/]+/issues/([0-9]+)/comments$ ]]; then
  n="${BASH_REMATCH[1]}"; [ -f "$GHF/fail-comments" ] && exit 1
  store "$GHF/comments-$n.json"; slice "$GHF/comments-$n.json"
elif [[ "$m $p" =~ ^GET\ repos/[^/]+/[^/]+/pulls/([0-9]+)/reviews$ ]]; then
  n="${BASH_REMATCH[1]}"; [ -f "$GHF/fail-reviews" ] && exit 1
  store "$GHF/reviews-$n.json"; slice "$GHF/reviews-$n.json"
elif [[ "$m $p" =~ ^GET\ repos/[^/]+/[^/]+/pulls/[0-9]+/reviews/([0-9]+)$ ]]; then
  cat "$GHF/review-${BASH_REMATCH[1]}.json" 2>/dev/null || exit 1
elif [[ "$m $p" =~ ^POST\ repos/[^/]+/[^/]+/issues/([0-9]+)/comments$ ]]; then
  n="${BASH_REMATCH[1]}"; [ -f "$GHF/fail-post-comment" ] && exit 1
  store "$GHF/comments-$n.json"
  jq -c --slurpfile i "$input" '. + [{body: $i[0].body}]' "$GHF/comments-$n.json" > "$GHF/c.tmp" && mv "$GHF/c.tmp" "$GHF/comments-$n.json"
  echo '{"id": 1}'
elif [[ "$m $p" =~ ^POST\ repos/[^/]+/[^/]+/pulls/([0-9]+)/reviews$ ]]; then
  n="${BASH_REMATCH[1]}"; [ -f "$GHF/fail-post-review" ] && exit 1
  store "$GHF/reviews-$n.json"
  jq -c --slurpfile i "$input" '. + [{body: $i[0].body, commit_id: $i[0].commit_id}]' "$GHF/reviews-$n.json" > "$GHF/r.tmp" && mv "$GHF/r.tmp" "$GHF/reviews-$n.json"
  echo '{"id": 2}'
elif [[ "$m $p" =~ ^PUT\ repos/[^/]+/[^/]+/pulls/[0-9]+/reviews/[0-9]+/dismissals$ ]]; then
  [ -f "$GHF/fail-dismiss" ] && exit 1
  echo '{"id": 3}'
else
  echo "gh stub: no route for $m $path" >&2; exit 1
fi
EOF
chmod +x "$T/pathbin/gh"
export PATH="$T/pathbin:$PATH"

# ── script stubs, copied into each case's $HARNESS/bin ───────────────────────
mkdir -p "$T/stubbin"
cat > "$T/stubbin/lead-verdict.sh" <<'EOF'
#!/bin/bash
#   bin/lead-verdict.sh post <owner/repo> <pr> <head-sha> <MERGE|MERGE-WITH-NOTES|BLOCK>
#                            [--source lead|human|box|risk-tier|agent] [--model <id>] [--reviewer <name>]
echo "lead-verdict $*" >> "$CALLS"
s="$HARNESS/stub/lv-$1"
[ -f "$s.err" ] && cat "$s.err" >&2
[ -f "$s.rc" ] && exit "$(cat "$s.rc")"
exit 0
EOF
cat > "$T/stubbin/jobs-client.sh" <<'EOF'
#!/bin/bash
case "$1" in
  setting-get)
    echo "jobs-client setting-get $2" >> "$CALLS"
    f="$HARNESS/stub/setting/$2"
    [ -f "$f.rc" ] && exit "$(cat "$f.rc")"
    [ -f "$f" ] || exit 2
    cat "$f"; echo ;;
  setting-set)
    echo "jobs-client setting-set $2 $3 actor=${JOBS_BOX:-} note=$4" >> "$CALLS"
    [ -f "$HARNESS/stub/setting-set.rc" ] && exit "$(cat "$HARNESS/stub/setting-set.rc")"
    exit 0 ;;
  *) echo "jobs-client stub: no verb $1" >&2; exit 2 ;;
esac
EOF
cat > "$T/stubbin/lane-alert.sh" <<'EOF'
#!/bin/bash
echo "lane-alert $*" >> "$CALLS"
exit 0
EOF
cat > "$T/stubbin/box-for.sh" <<'EOF'
#!/bin/bash
echo "box-for $*" >> "$CALLS"
cat "$HARNESS/stub/box" 2>/dev/null
exit 0
EOF
cat > "$T/stubbin/box-ops.sh" <<'EOF'
#!/bin/bash
echo "box-ops $*" >> "$CALLS"
[ -f "$HARNESS/stub/box-ops.rc" ] && exit "$(cat "$HARNESS/stub/box-ops.rc")"
exit 0
EOF
chmod +x "$T/stubbin/"*.sh

# ── the libs under test ─────────────────────────────────────────────────────
# shellcheck source=../bin/lib/unblock/act.sh
. "$DIR/bin/lib/unblock/act.sh" || { echo "FAIL: bin/lib/unblock/act.sh could not be sourced"; exit 1; }
# shellcheck source=../bin/lib/unblock/tripwire.sh
. "$DIR/bin/lib/unblock/tripwire.sh" || { echo "FAIL: bin/lib/unblock/tripwire.sh could not be sourced"; exit 1; }
declare -F ub_act >/dev/null || { echo "FAIL: ub_act is not defined by bin/lib/unblock/act.sh"; exit 1; }
declare -F ub_tripwire_scan >/dev/null || { echo "FAIL: ub_tripwire_scan is not defined by bin/lib/unblock/tripwire.sh"; exit 1; }

# ── function stubs: what the caller (the S0 tick) loads ─────────────────────
mc_requeued_mark() { echo "mc_requeued_mark $*" >> "$CALLS"; grep -m1 -F -x -- "$1 $2" "$HARNESS/requeued.txt" 2>/dev/null; return 0; }
mc_requeued_record() { echo "mc_requeued_record $*" >> "$CALLS"; echo "$1 $2" >> "$HARNESS/requeued.txt"; }
mc_requeue_mergify() { echo "mc_requeue_mergify $*" >> "$CALLS"; return "${STUB_REQUEUE_RC:-0}"; }
mc_dequeue_label() { echo "mc_dequeue_label $*" >> "$CALLS"; return 0; }
mc_enqueue_mergify() { echo "mc_enqueue_mergify $*" >> "$CALLS"; return "${STUB_ENQUEUE_RC:-0}"; }
fix_round_enqueue() {
  echo "fix_round_enqueue $*" >> "$CALLS"
  [ -n "${STUB_FR_RC:-}" ] && return "$STUB_FR_RC"
  echo "${STUB_FR_OUT:-{\"id\":\"job-fixture-1\",\"status\":\"queued\"\}}"
}
_jobs_req() {
  echo "_jobs_req $*" >> "$CALLS"
  local f="$HARNESS/stub/row/${2#/api/settings/}"
  [ -f "$f.rc" ] && return "$(cat "$f.rc")"
  if [ -f "$f.json" ]; then cat "$f.json"; else echo '{"setting":null}'; fi
}

# newcase <name> — a fresh $HARNESS for one case. Mode row `act`, UNBLOCK_ACT=1.
newcase() {
  CASE="$1"
  export HARNESS="$T/c-$1"
  CALLS="$HARNESS/calls.txt"; GHF="$HARNESS/gh"; export CALLS GHF
  mkdir -p "$HARNESS/bin" "$HARNESS/logs" "$HARNESS/stub/setting" "$HARNESS/stub/row" "$GHF"
  cp -p "$T/stubbin/"*.sh "$HARNESS/bin/"
  : > "$CALLS"
  printf 'act' > "$HARNESS/stub/setting/unblock.project.cromford.mode"
  printf '%s' "$H42" > "$GHF/head-42"
  export UNBLOCK_ACT=1 UB_NOW=$NOW0
  unset STUB_REQUEUE_RC STUB_ENQUEUE_RC STUB_FR_RC STUB_FR_OUT
}
key() { printf 'k-%s' "$CASE"; }
key12() { key | cut -c1-12; }
# mk <action> [args-json] [jq filter] — one decision record for PR 42.
mk() {
  local name="$1" args="${2:-}" extra="${3:-.}"
  [ -n "$args" ] || args='{}'
  jq -nc --arg k "$(key)" --arg n "$name" --argjson a "$args" --arg s "$SLUG" --arg h "$H42" \
    "{decision_key:\$k, project:\"cromford\", repo:\$s, subject_kind:\"pr\", subject:(\$s + \"#42\"),
      pr:42, head:\$h, rule_id:\"U9\", class:\"queue-requeue\", cites:[\"fixture cite\"],
      action:{name:\$n, args:\$a}} | $extra"
}
# run <record> — ub_act in THIS shell (it sets UB_ACT_OUTCOME/UB_ACT_DETAIL).
run() { ub_act "$1" > "$HARNESS/out.txt" 2>"$HARNESS/err.txt"; RC=$?; OUT=$(cat "$HARNESS/out.txt"); }
# writes — every stub call that changes something outside ub_act, alerts aside.
writes() { grep -v -e '^gh GET ' -e '^mc_requeued_mark ' -e '^jobs-client setting-get ' -e '^_jobs_req GET ' -e '^box-for ' -e '^lane-alert ' "$CALLS"; }
nwrites() { writes | grep -c .; }
n() { grep -c -- "$1" "$CALLS"; }
expect() {  # expect <label> <outcome> <detail-prefix>
  if [ "$RC" = 0 ] && [ "${UB_ACT_OUTCOME:-}" = "$2" ] && [ "${UB_ACT_DETAIL#"$3"}" != "${UB_ACT_DETAIL:-}" -o "$3" = "${UB_ACT_DETAIL:-}" ]; then ok
  else bad "$1: want rc 0 '$2' '$3*', got rc $RC '${UB_ACT_OUTCOME:-}' '${UB_ACT_DETAIL:-}' calls: $(tr '\n' '|' < "$CALLS")"; fi
}
zero_writes() { [ "$(nwrites)" = 0 ] && ok || bad "$1: want 0 writes, got: $(writes | tr '\n' '|')"; }
marker() { printf '<!-- tackler:%s -->' "$1"; }

# ── A1: bad input is rc 1 with nothing read ─────────────────────────────────
newcase a1
for r in 'not json' '{}' "$(mk requeue '' 'del(.decision_key)')" "$(mk requeue '' 'del(.project)')" \
         "$(mk requeue '' 'del(.action.name)')" "$(mk requeue '' 'del(.head)')" "$(mk requeue '' '.decision_key="bad key"')"; do
  : > "$CALLS"; UB_ACT_OUTCOME=stale; run "$r"
  [ "$RC" = 1 ] && [ -z "$UB_ACT_OUTCOME" ] && [ ! -s "$CALLS" ] && ok \
    || bad "A1: bad input must be rc 1, empty outcome, 0 calls; got rc $RC '$UB_ACT_OUTCOME' for $r"
done

# ── A2: no $HARNESS and no $H: rc 1, no path built ──────────────────────────
newcase a2
mkdir -p "$T/a2cwd"; r=$(mk requeue)
out=$(cd "$T/a2cwd" && unset HARNESS H && ub_act "$r" >/dev/null 2>&1; echo "rc=$?")
[ "$out" = rc=1 ] && [ -z "$(ls -A "$T/a2cwd")" ] && [ ! -s "$CALLS" ] && ok \
  || bad "A2: no root must be rc 1 and write nothing; got $out, cwd: $(ls -A "$T/a2cwd")"

# ── A3: never-auto classes and actions are refused before anything ──────────
for c in spend governance production live-probe client-board merge deploy; do
  newcase "a3-$c"; run "$(mk requeue '' ".class=\"$c\"")"
  expect "A3 class $c" refused "never-auto:$c"
  zero_writes "A3 class $c"
  [ "$(n "^lane-alert --severity warn --id unblock-never-$(key12) ")" = 1 ] && [ "$(n '^lane-alert')" = 1 ] && ok \
    || bad "A3 class $c: want exactly one warn alert id unblock-never-$(key12), calls: $(tr '\n' '|' < "$CALLS")"
  [ "$(n '^jobs-client setting-get')" = 0 ] && ok || bad "A3 class $c: the mode row must not be read"
done
for a in merge force_push deploy pause_project; do
  newcase "a3c-$a"; run "$(mk "$a")"
  expect "A3c action $a" refused "never-auto:$a"
  zero_writes "A3c action $a"
done
newcase a3d; run "$(mk requeue '' '.class="spend-report"')"
expect "A3d spend-report is not spend" done requeued

# ── A4-A7: the mode gate ────────────────────────────────────────────────────
newcase a4; printf shadow > "$HARNESS/stub/setting/unblock.project.cromford.mode"
run "$(mk requeue)"; expect A4 would WOULD_REQUEUE; zero_writes A4
grep -q " act cromford $SLUG#42 U9 WOULD_REQUEUE would " "$HARNESS/logs/unblock.log" && ok \
  || bad "A4: no WOULD_REQUEUE line in unblock.log: $(cat "$HARNESS/logs/unblock.log" 2>/dev/null)"
newcase a5; export UNBLOCK_ACT=0; run "$(mk post_block '{"lines":["x"]}')"; expect A5 would WOULD_POST_BLOCK; zero_writes A5
newcase a5b; unset UNBLOCK_ACT; run "$(mk requeue)"; expect "A5b UNBLOCK_ACT unset" would WOULD_REQUEUE; zero_writes A5b
newcase a6; rm -f "$HARNESS/stub/setting/unblock.project.cromford.mode"
run "$(mk requeue)"; expect "A6 row absent" refused no-opt-in; zero_writes A6
newcase a6b; printf ' act ' > "$HARNESS/stub/setting/unblock.project.cromford.mode"
run "$(mk requeue)"; expect "A6b ' act ' is trimmed" done requeued
newcase a6c; printf off > "$HARNESS/stub/setting/unblock.project.cromford.mode"
run "$(mk requeue)"; expect "A6c off" refused no-opt-in; zero_writes A6c
newcase a6d; printf ACT > "$HARNESS/stub/setting/unblock.project.cromford.mode"
run "$(mk requeue)"; expect "A6d ACT is not act" refused no-opt-in; zero_writes A6d
newcase a6e; run "$(mk frobnicate)"; expect "A6e unknown action" refused unknown-action; zero_writes A6e
newcase a7; echo 1 > "$HARNESS/stub/setting/unblock.project.cromford.mode.rc"
run "$(mk requeue)"; expect "A7 mode unreadable" failed mode-unreadable; zero_writes A7

# ── A8-A9: the verdict source `agent` ───────────────────────────────────────
for a in post_block queue_approve; do
  newcase "a8-$a"; sed -i 's/|risk-tier|agent\]/|risk-tier]/' "$HARNESS/bin/lead-verdict.sh"
  run "$(mk "$a" '{"lines":["x"],"verdict":"MERGE"}')"
  expect "A8 $a" refused verdict-source-agent-unavailable; zero_writes "A8 $a"
  [ "$(n '^gh POST')" = 0 ] && ok || bad "A8 $a: a GitHub write went out"
done
newcase a8b; sed -i 's/|risk-tier|agent\]/|risk-tier] [--agent-mode x]/' "$HARNESS/bin/lead-verdict.sh"
run "$(mk post_block '{"lines":["x"]}')"; expect "A8b agent outside the --source set" refused verdict-source-agent-unavailable
newcase a9; run "$(mk post_block '{"lines":["x"]}')"; expect A9 done posted
[ "$(n "^lead-verdict post $SLUG 42 $H42 BLOCK --source agent --reviewer tackler:$(key12) --note U9\$")" = 1 ] && ok \
  || bad "A9: the BLOCK row must use --source agent --reviewer tackler:$(key12): $(grep lead-verdict "$CALLS")"

# ── A10-A13: head and marker gates ──────────────────────────────────────────
newcase a10; printf '%s' "$HOLD" > "$GHF/head-42"
run "$(mk post_block '{"lines":["x"]}')"; expect "A10 head moved" refused head-moved; zero_writes A10
newcase a11; jq -nc --arg m "seen. $(marker "k-a11")" '[{body:"other"},{body:$m}]' > "$GHF/comments-42.json"
run "$(mk post_block '{"lines":["x"]}')"; expect "A11 marker in a comment" done marker-found; zero_writes A11
newcase a11b; jq -nc --arg m "$(marker "k-a11b")" '[{body:$m, commit_id:"x"}]' > "$GHF/reviews-42.json"
run "$(mk requeue)"; expect "A11b marker in a review" done marker-found; zero_writes A11b
newcase a11c; jq -nc --arg m "$(marker "k-other")" '[{body:$m}]' > "$GHF/comments-42.json"
run "$(mk requeue)"; expect "A11c another key's marker" done requeued
newcase a11d; jq -nc '[{body:"the bot wrote tackler:k-a11d in prose"}]' > "$GHF/comments-42.json"
run "$(mk requeue)"; expect "A11d prose is not the marker" done requeued
newcase a11e; jq -nc --arg m "$(marker "k-a11e2")" '[{body:$m}]' > "$GHF/comments-42.json"
run "$(mk requeue)"; expect "A11e a key that only starts with ours" done requeued
newcase a12; jq -nc --arg m "$(marker "k-a12")" '[range(100) | {body:"noise"}] + [{body:$m}]' > "$GHF/comments-42.json"
run "$(mk requeue)"; expect "A12 marker on page 2" done marker-found; zero_writes A12
grep -q "^gh GET repos/$SLUG/issues/42/comments?per_page=100&page=2\$" "$CALLS" && ok || bad "A12: page 2 was not read"
newcase a12b; jq -nc '[range(500) | {body:"noise"}]' > "$GHF/comments-42.json"
run "$(mk requeue)"; expect "A12b 5 full pages" failed marker-search-truncated; zero_writes A12b
newcase a12c; jq -nc '[range(499) | {body:"noise"}]' > "$GHF/comments-42.json"
run "$(mk requeue)"; expect "A12c 499 comments is a full read" done requeued
newcase a13; touch "$GHF/fail-head"
run "$(mk post_block '{"lines":["x"]}')"; expect "A13 head unreadable" failed head-unreadable; zero_writes A13
newcase a13b; touch "$GHF/fail-comments"
run "$(mk requeue)"; expect "A13b comments unreadable" failed marker-unreadable; zero_writes A13b
newcase a13c; touch "$GHF/fail-reviews"
run "$(mk requeue)"; expect "A13c reviews unreadable" failed marker-unreadable; zero_writes A13c

# ── A14: the #7699 fixture, act mode, in order, exact counts ────────────────
newcase a14
jq -r '.[] | "\(.pr) \(.head)"' "$FX/batch-7699.json" | while read -r pr h; do printf '%s' "$h" > "$GHF/head-$pr"; done
jq -c '.[]' "$FX/batch-7699.json" > "$HARNESS/recs.txt"
a14ok=1
while IFS= read -r r; do
  run "$r"
  [ "$RC" = 0 ] && [ "$UB_ACT_OUTCOME" = done ] || a14ok=0
  [ "$OUT" = "$(printf '%s\t%s' "$UB_ACT_OUTCOME" "$UB_ACT_DETAIL")" ] || a14ok=0
done < "$HARNESS/recs.txt"
[ "$a14ok" = 1 ] && ok || bad "A14: every record must be done and its stdout line must equal the two variables"
if diff <(writes) <(head -12 "$FX/expected-calls.txt") > "$HARNESS/a14.diff"; then ok
else bad "A14: the #7699 write list differs from the expected list: $(cat "$HARNESS/a14.diff")"; fi
[ "$(n '^gh POST')" = 2 ] && [ "$(n '^lead-verdict post')" = 1 ] && [ "$(n '^mc_dequeue_label')" = 1 ] && [ "$(n '^mc_requeue_mergify')" = 4 ] && ok \
  || bad "A14: counts must be 2 GitHub posts, 1 verdict, 1 dequeue, 4 requeues"
jq -e --arg h "$(jq -r '.[0].head' "$FX/batch-7699.json")" 'select(.event == "REQUEST_CHANGES") | .commit_id == $h and (.body | contains("<!-- tackler:k7617u1block -->"))' \
  "$GHF/inputs.log" >/dev/null && ok || bad "A14: the review must be REQUEST_CHANGES on the head with the marker: $(cat "$GHF/inputs.log")"
jq -se '.[0].body | contains("[BLOCK red-build] tests/fixture-a-test.sh") and contains("<!-- tackler:k7617u1block -->")' "$GHF/inputs.log" >/dev/null && ok \
  || bad "A14: the comment must carry the BLOCK line and the marker"
[ "$(n '^lane-alert')" = 0 ] && ok || bad "A14: the batch must fire no alert"

# ── A15: requeue ────────────────────────────────────────────────────────────
newcase a15; echo "$SLUG#42 $H42" > "$HARNESS/requeued.txt"
run "$(mk requeue)"; expect "A15 already requeued" done already-requeued
[ "$(n '^mc_requeue_mergify')" = 0 ] && [ "$(n '^mc_requeued_record')" = 0 ] && ok || bad "A15: no requeue call may go out"
newcase a15b; export STUB_REQUEUE_RC=3; run "$(mk requeue)"; expect "A15b rc 3" failed requeue-unacknowledged
newcase a15c; export STUB_REQUEUE_RC=4; run "$(mk requeue)"; expect "A15c rc 4" refused human-verdict-required
newcase a15d; export STUB_REQUEUE_RC=2; run "$(mk requeue)"; expect "A15d rc 2" done merged-meanwhile
newcase a15e; export STUB_REQUEUE_RC=1; run "$(mk requeue)"; expect "A15e rc 1" failed "requeue rc 1"
newcase a15f
out=$(unset -f mc_requeue_mergify; ub_act "$(mk requeue)" >/dev/null 2>&1; echo "$UB_ACT_OUTCOME $UB_ACT_DETAIL")
[ "$out" = "failed conductor-libs-not-loaded" ] && ok || bad "A15f: want 'failed conductor-libs-not-loaded', got '$out'"
[ "$(nwrites)" = 0 ] && ok || bad "A15f: no write without the conductor libs"

# ── A16: post_block partial failures; post_findings ─────────────────────────
newcase a16; touch "$GHF/fail-post-review"
run "$(mk post_block '{"lines":["x"]}')"; expect "A16 review fails" failed "review-failed after comment"
[ "$(n '^lead-verdict')" = 0 ] && [ "$(n '^mc_dequeue_label')" = 0 ] && ok || bad "A16: no verdict and no dequeue after a failed review"
newcase a16b; echo 3 > "$HARNESS/stub/lv-post.rc"
run "$(mk post_block '{"lines":["x"]}')"; expect "A16b verdict exit 3" refused "head-moved after comment,review"
[ "$(n '^mc_dequeue_label')" = 0 ] && ok || bad "A16b: no dequeue after a refused verdict"
newcase a16c; touch "$GHF/fail-post-comment"
run "$(mk post_block '{"lines":["x"]}')"; expect "A16c comment fails" failed comment-failed
[ "$(nwrites)" = 1 ] && ok || bad "A16c: only the failed comment call: $(writes | tr '\n' '|')"
newcase a16d; echo 1 > "$HARNESS/stub/lv-post.rc"
run "$(mk post_block '{"lines":["x"]}')"; expect "A16d verdict exit 1" failed "verdict-failed rc 1 after comment,review"
newcase a16e; run "$(mk post_findings '{"lines":["[NOTE] fixture note"]}')"; expect "A16e post_findings" done posted
[ "$(n '^gh POST')" = 2 ] && [ "$(n '^lead-verdict')" = 0 ] && [ "$(n '^mc_dequeue_label')" = 0 ] && ok \
  || bad "A16e: post_findings is a comment and a review only: $(writes | tr '\n' '|')"
newcase a16f; run "$(mk post_block '{"lines":[]}')"
[ "$RC" = 1 ] && [ ! -s "$CALLS" ] && ok || bad "A16f: post_block with no lines is bad input, rc $RC"

# ── A17: dismiss_review ─────────────────────────────────────────────────────
newcase a17; jq -nc --arg h "$H42" '{id: 77, commit_id: $h, state: "CHANGES_REQUESTED"}' > "$GHF/review-77.json"
run "$(mk dismiss_review '{"review_id":77}')"; expect "A17 review binds the head" refused review-binds-head
[ "$(n '^gh PUT')" = 0 ] && ok || bad "A17: no dismissal may go out"
newcase a17b; jq -nc --arg h "$HOLD" '{id: 77, commit_id: $h, state: "CHANGES_REQUESTED"}' > "$GHF/review-77.json"
run "$(mk dismiss_review '{"review_id":77}')"; expect "A17b old review" done dismissed
grep -qx "gh PUT repos/$SLUG/pulls/42/reviews/77/dismissals" "$CALLS" && ok || bad "A17b: no dismissal call"
jq -e '.message | contains("<!-- tackler:k-a17b -->")' "$GHF/inputs.log" >/dev/null && ok || bad "A17b: the dismissal message must carry the marker"
newcase a17c; run "$(mk dismiss_review '{"review_id":78}')"; expect "A17c review unreadable" failed review-unreadable; zero_writes A17c

# ── A18: queue_approve ──────────────────────────────────────────────────────
newcase a18; run "$(mk queue_approve '{"verdict":"MERGE-WITH-NOTES"}')"; expect A18 done queued
[ "$(writes | tr '\n' '|')" = "lead-verdict post $SLUG 42 $H42 MERGE-WITH-NOTES --source agent --reviewer tackler:$(key12) --note U9|mc_enqueue_mergify $SLUG https://github.com/$SLUG/pull/42 $H42|" ] && ok \
  || bad "A18: want the MWN verdict then the enqueue, got $(writes | tr '\n' '|')"
[ "$(grep -c 'the operator standing approval.*k-a18' "$HARNESS/logs/merge-conductor-backstop.log" 2>/dev/null)" = 1 ] && ok \
  || bad "A18: want one backstop line naming the standing approval and the key"
newcase a18b; run "$(mk queue_approve '{"verdict":"BLOCK"}')"
[ "$RC" = 1 ] && [ ! -s "$CALLS" ] && ok || bad "A18b: verdict BLOCK on queue_approve is bad input, rc $RC"
newcase a18c; export STUB_ENQUEUE_RC=1; run "$(mk queue_approve '{"verdict":"MERGE"}')"; expect "A18c enqueue fails" failed "enqueue rc 1"
[ ! -s "$HARNESS/logs/merge-conductor-backstop.log" ] && ok || bad "A18c: no backstop line on a failed enqueue"

# ── A19: fix_round ──────────────────────────────────────────────────────────
newcase a19; echo box-fixture-2 > "$HARNESS/stub/box"
run "$(mk fix_round '{"brief":"fix the fixture suite"}')"; expect A19 done "queued job-fixture-1"
line=$(grep '^fix_round_enqueue ' "$CALLS")
case "$line" in
  "fix_round_enqueue cromford unblock-42-${H42:0:12}-U9 box-fixture-2 0 "*'"brief":"fix the fixture suite"'*" cromford unblock-42-${H42:0:12} unblock https://github.com/$SLUG/pull/42 - -") ok ;;
  *) bad "A19: fix_round_enqueue argv wrong: $line" ;;
esac
newcase a19b; run "$(mk fix_round '{"brief":"b"}')"; expect "A19b no box" failed no-box; zero_writes A19b
newcase a19c; echo local > "$HARNESS/stub/box"; run "$(mk fix_round '{"brief":"b"}')"; expect "A19c box local" failed no-box
newcase a19d; echo box-fixture-2 > "$HARNESS/stub/box"; export STUB_FR_OUT='{"id":"job-fixture-1","duplicate":true}'
run "$(mk fix_round '{"brief":"b"}')"; expect "A19d duplicate" done duplicate
newcase a19e; echo box-fixture-2 > "$HARNESS/stub/box"; export STUB_FR_RC=1
run "$(mk fix_round '{"brief":"b"}')"; expect "A19e enqueue fails" failed fix-round-enqueue-failed
newcase a19f; echo box-fixture-2 > "$HARNESS/stub/box"
out=$(unset -f fix_round_enqueue; ub_act "$(mk fix_round '{"brief":"b"}')" >/dev/null 2>&1; echo "$UB_ACT_OUTCOME $UB_ACT_DETAIL")
[ "$out" = "failed fix-round-libs-not-loaded" ] && ok || bad "A19f: got '$out'"

# ── A20: lead_rerequest ─────────────────────────────────────────────────────
newcase a20; run "$(mk lead_rerequest '{"request_id":"901","priority":50}')"; expect A20 done requested
[ "$(writes | tr '\n' '|')" = "lead-verdict reset 901|lead-verdict request $SLUG 42 $H42 --priority 50|" ] && ok \
  || bad "A20: want reset then request, got $(writes | tr '\n' '|')"
newcase a20b; echo 1 > "$HARNESS/stub/lv-reset.rc"; run "$(mk lead_rerequest '{"request_id":"901","priority":50}')"
expect "A20b reset fails" failed "reset rc 1"
[ "$(n '^lead-verdict request')" = 0 ] && ok || bad "A20b: no request after a failed reset"
newcase a20c; echo 1 > "$HARNESS/stub/lv-request.rc"; echo 'lead-verdict: HTTP 409 a request is open' > "$HARNESS/stub/lv-request.err"
run "$(mk lead_rerequest '{"request_id":"901","priority":50}')"; expect "A20c 409" done already-requested

# ── A21-A22: box restart, no card, one critical alert, one per hour ─────────
box() { mk box_restart '{"box_id":"box-fixture-7","account":"acct-fixture"}' '.subject_kind="box" | .subject="box-fixture-7" | del(.pr, .head)'; }
newcase a21; run "$(box)"; expect A21 done restarted
[ "$(writes | tr '\n' '|')" = "box-ops restart box-fixture-7 --account acct-fixture --apply|" ] && ok || bad "A21: want one box-ops restart --apply, got $(writes | tr '\n' '|')"
[ "$(n '^lane-alert --critical --severity critical --id unblock-restart-box-fixture-7 unblock ')" = 1 ] && [ "$(n '^lane-alert')" = 1 ] && ok \
  || bad "A21: want exactly one --critical alert after the restart: $(grep lane-alert "$CALLS")"
grep -q '^lane-alert .*k-a21' "$CALLS" && ok || bad "A21: the alert must name the decision key"
[ "$(n 'card')" = 0 ] && ok || bad "A21: no card on a box restart"
: > "$CALLS"; export UB_NOW=$((NOW0 + 1800)); run "$(box)"
expect "A22 second restart in 30 min" refused restart-within-hour
[ "$(n '^box-ops')" = 0 ] && [ "$(n '^lane-alert')" = 0 ] && ok || bad "A22: no box-ops and no alert within the hour"
: > "$CALLS"; export UB_NOW=$((NOW0 + 3601)); run "$(box)"; expect "A22b after the hour" done restarted
newcase a21b; echo 1 > "$HARNESS/stub/box-ops.rc"; run "$(box)"; expect "A21b box-ops rc 1" failed "box-ops rc 1"
[ "$(n '^lane-alert --critical')" = 1 ] && ok || bad "A21b: the critical alert goes out on a failed restart too"

# ── A23-A27: the knob arm ───────────────────────────────────────────────────
knob() { mk setting_set "$(jq -nc --arg k "$1" --arg v "$2" --arg mn "${3-1}" --arg mx "${4-16}" \
  '{key:$k, value:$v, old:"4", min:$mn, max:$mx, why:"fixture pool is short"}')" '.subject_kind="knob" | .subject="knob" | del(.pr, .head)'; }
newcase a23; run "$(knob lane.fly-pool-tick.pool_tick_max_parallel 12)"; expect A23 done set
[ "$(writes | tr '\n' '|')" = "jobs-client setting-set lane.fly-pool-tick.pool_tick_max_parallel 12 actor=tackler:$(key12) note=fixture pool is short; roll back by setting 4|" ] && ok \
  || bad "A23: want one setting-set as tackler with the old value, got $(writes | tr '\n' '|')"
for k in CI_MAX_SHARDS lane.fly-pool-tick.pool_tick_max_parallel_x hub_load.shed_extra lane.fly-pool.a.b.pool_record_read \
         unblock.project.cromford.mode lane.unblock.unblock_act xlane_placement.p; do
  newcase "a24-$k"; run "$(knob "$k" 2)"; expect "A24 $k" refused knob-not-allowed; zero_writes "A24 $k"
done
newcase a24e; printf 'unblock.*,lane.unblock.*,*' > "$HARNESS/stub/setting/unblock.knob_allowlist"
run "$(knob unblock.project.cromford.mode act)"; expect "A24e the lane never flips itself" refused knob-not-allowed; zero_writes A24e
newcase a24f; echo 1 > "$HARNESS/stub/setting/unblock.knob_allowlist.rc"
run "$(knob hub_load.shed 1)"; expect "A24f allowlist unreadable" failed allowlist-unreadable; zero_writes A24f
newcase a24g; printf 'hub_load.shed' > "$HARNESS/stub/setting/unblock.knob_allowlist"
run "$(knob lane.fly-pool-tick.pool_tick_max_parallel 3)"; expect "A24g the row wins" refused knob-not-allowed
: > "$CALLS"; run "$(knob hub_load.shed 1)"; expect "A24g the row allows its own key" done set
newcase a25; run "$(knob lane.fly-pool-tick.pool_tick_max_parallel 99)"; expect "A25 over max" refused out-of-range; zero_writes A25
newcase a25b; run "$(knob lane.fly-pool-tick.pool_tick_max_parallel 0)"; expect "A25b under min" refused out-of-range
newcase a25c; run "$(knob lane.fly-pool-tick.pool_tick_max_parallel twelve)"; expect "A25c not a number" refused out-of-range
newcase a25d; run "$(knob lane.fly-pool-tick.pool_tick_max_parallel 12 '' '')"
[ "$RC" = 1 ] && [ ! -s "$CALLS" ] && ok || bad "A25d: a knob record with no [min,max] is bad input, rc $RC"
newcase a25e; run "$(knob lane.fly-pool-tick.pool_tick_max_parallel 16)"; expect "A25e max is inside" done set
newcase a26; run "$(knob lane.fly-pool.project-6-os.pool_record_read 1 0 1)"; expect "A26 <p> glob" done set
newcase a26b; run "$(knob lane_placement.cromford 2)"; expect "A26b lane_placement.*" done set
newcase a26c; run "$(knob conductor_remote_spawn.cromford 1 0 1)"; expect "A26c conductor_remote_spawn.*" done set
row() { jq -nc --arg a "$1" --arg u "$2" '{setting:{key:"k", value:"4", actor:$a, updated_at:$u}}' > "$HARNESS/stub/row/lane.fly-pool-tick.pool_tick_max_parallel.json"; }
newcase a27; row tackler:k-other 2026-10-20T14:00:00Z
run "$(knob lane.fly-pool-tick.pool_tick_max_parallel 12)"; expect "A27 tackler set it 2 h ago" refused knob-changed-today; zero_writes A27
newcase a27b; row tackler:k-other 2026-10-19T14:59:59Z
run "$(knob lane.fly-pool-tick.pool_tick_max_parallel 12)"; expect "A27b 25 h ago" done set
newcase a27c; row operator 2026-10-20T14:00:00Z
run "$(knob lane.fly-pool-tick.pool_tick_max_parallel 12)"; expect "A27c a person set it" done set
newcase a27d; echo 1 > "$HARNESS/stub/row/lane.fly-pool-tick.pool_tick_max_parallel.rc"
run "$(knob lane.fly-pool-tick.pool_tick_max_parallel 12)"; expect "A27d row unreadable" failed setting-row-unreadable; zero_writes A27d
newcase a27e; row tackler:k-other not-a-date
run "$(knob lane.fly-pool-tick.pool_tick_max_parallel 12)"; expect "A27e bad updated_at" failed setting-row-unreadable
newcase a27h; row tackler:k-other ""
run "$(knob lane.fly-pool-tick.pool_tick_max_parallel 12)"; expect "A27h tackler row with no updated_at" failed setting-row-unreadable; zero_writes A27h
newcase a27f
out=$(unset -f _jobs_req; ub_act "$(knob lane.fly-pool-tick.pool_tick_max_parallel 12)" >/dev/null 2>&1; echo "$UB_ACT_OUTCOME $UB_ACT_DETAIL")
[ "$out" = "failed jobs-libs-not-loaded" ] && ok || bad "A27f: got '$out'"
newcase a27g; echo 1 > "$HARNESS/stub/setting-set.rc"
run "$(knob lane.fly-pool-tick.pool_tick_max_parallel 12)"; expect "A27g setting-set fails" failed "setting-set rc 1"

# ── A28-A30: the card through the critical DM ───────────────────────────────
card() { mk send_card "$(jq -nc --arg t "$1" '{card_id:"u-3f9a2c", text:$t}')" '.subject_kind="card" | .class="ask" | del(.pr, .head)'; }
newcase a28; run "$(card 'PR #42 needs a decision (fixture)')"; expect A28 done sent
[ "$(n '^lane-alert --critical --severity critical --id unblock-u-3f9a2c unblock PR #42 needs a decision (fixture)$')" = 1 ] && [ "$(n '^lane-alert')" = 1 ] && ok \
  || bad "A28: want one --critical alert id unblock-u-3f9a2c: $(cat "$CALLS")"
newcase a29; printf shadow > "$HARNESS/stub/setting/unblock.project.cromford.mode"
run "$(card 'PR #42 needs a decision (fixture)')"; expect "A29 shadow" would WOULD_SEND_CARD
[ "$(n '^lane-alert')" = 0 ] && ok || bad "A29: no alert in shadow"
newcase a30; run "$(card "$(printf 'x%.0s' $(seq 901))")"; expect "A30 901 chars" failed card-invalid
[ "$(n '^lane-alert')" = 0 ] && ok || bad "A30: nothing sent for an invalid card"
newcase a30b; run "$(card "$(printf 'x%.0s' $(seq 900))")"; expect "A30b 900 chars" done sent

# ── A31-A32: the corpus replay at the act layer ─────────────────────────────
newcase a31
jq -r '.[] | "\(.pr) \(.head)"' "$FX/corpus-20261019.json" | while read -r pr h; do printf '%s' "$h" > "$GHF/head-$pr"; done
jq -c '.[]' "$FX/corpus-20261019.json" > "$HARNESS/recs.txt"
a31ok=1
while IFS= read -r r; do run "$r"; [ "$RC" = 0 ] && [ "$UB_ACT_OUTCOME" = done ] || a31ok=0; done < "$HARNESS/recs.txt"
[ "$a31ok" = 1 ] && ok || bad "A31: every corpus record must be done in act mode"
if diff <(writes) "$FX/expected-calls.txt" > "$HARNESS/a31.diff"; then ok
else bad "A31: the corpus write list differs from expected-calls.txt: $(cat "$HARNESS/a31.diff")"; fi
[ "$(n '^lane-alert')" = 0 ] && ok || bad "A31b: the corpus first pass must fire no alert"
[ "$(grep -c 'the operator standing approval' "$HARNESS/logs/merge-conductor-backstop.log")" = 7 ] && ok || bad "A31: want 7 backstop lines"
# A32: every marker present (pass 1 wrote #7617's; the rest are seeded) -> 0 writes.
jq -r '.[] | select(.action.name != "post_block") | "\(.pr) \(.decision_key)"' "$FX/corpus-20261019.json" | while read -r pr k; do
  jq -nc --arg m "$(marker "$k")" '[{body:$m}]' > "$GHF/comments-$pr.json"
done
: > "$CALLS"
while IFS= read -r r; do run "$r"; [ "$UB_ACT_OUTCOME $UB_ACT_DETAIL" = "done marker-found" ] || bad "A32: $(jq -r .decision_key <<<"$r") got $UB_ACT_OUTCOME $UB_ACT_DETAIL"; done < "$HARNESS/recs.txt"
zero_writes "A32 second pass"

# ── A33: the App token is armed before the first gh call and reset after ────
newcase a33
gh_auth_for() { echo "gh_auth_for $*" >> "$CALLS"; }
gh_auth_reset() { echo "gh_auth_reset" >> "$CALLS"; }
run "$(mk post_block '{"lines":["x"]}')"; expect "A33 post_block under the App token" done posted
[ "$(head -1 < <(grep -e '^gh ' -e '^gh_auth' "$CALLS"))" = "gh_auth_for $SLUG" ] && [ "$(tail -1 "$CALLS")" = gh_auth_reset ] && ok \
  || bad "A33: want gh_auth_for first and gh_auth_reset last: $(tr '\n' '|' < "$CALLS")"
: > "$CALLS"; printf '%s' "$HOLD" > "$GHF/head-42"; run "$(mk requeue)"; expect "A33b refused under the token" refused head-moved
[ "$(n '^gh_auth_reset')" = 1 ] && ok || bad "A33b: the token is reset on a gate stop too"
unset -f gh_auth_for gh_auth_reset

# ── B: tripwires ────────────────────────────────────────────────────────────
counts() { jq -nc "{day:\"2026-10-20\", class_today:{}, class_baseline7d:{}, subject_heads:{}, judge_calls:0, card_redeclares:{}} | $1"; }
sha12() { printf '%s' "$1" | sha256sum | cut -c1-12; }
trip() { : > "$CALLS"; ub_tripwire_scan "$1" >/dev/null 2>&1; TRC=$?; }
fires() {  # fires <label> <kind> <subject> — exactly one warn alert with the id
  local id="unblock-tripwire-$2-$(sha12 "$3")-2026-10-20"
  [ "$TRC" = 0 ] && [ "$(n "^lane-alert --severity warn --id $id unblock ")" = 1 ] && [ "$(n '^lane-alert')" = 1 ] && ok \
    || bad "$1: want rc 0 and one warn alert $id, got rc $TRC: $(cat "$CALLS")"
}
quiet() { [ "$TRC" = 0 ] && [ "$(n '^lane-alert')" = 0 ] && ok || bad "$1: want rc 0 and no alert, got rc $TRC: $(cat "$CALLS")"; }
newcase b
trip "$(counts '.class_today={"queue-requeue":13} | .class_baseline7d={"queue-requeue":3}')"; fires "B1 13 vs 3" class-burst queue-requeue
trip "$(counts '.class_today={"queue-requeue":4}')"; fires "B2 4 vs no baseline" class-burst queue-requeue
trip "$(counts ".subject_heads={\"$SLUG#42\":3}")"; fires "B3 3 heads" subject-heads "$SLUG#42"
trip "$(counts '.judge_calls=21')"; fires "B4 21 judge calls" judge-calls judge
trip "$(counts '.card_redeclares={"u-3f9a2c":4}')"; fires "B5 4 re-declares" card-redeclare u-3f9a2c
trip "$(counts '.class_today={"queue-requeue":9} | .class_baseline7d={"queue-requeue":3}')"; quiet "B6 exactly 3x"
trip "$(counts ".subject_heads={\"$SLUG#42\":2}")"; quiet "B7 2 heads"
trip "$(counts '.judge_calls=20')"; quiet "B8 20 judge calls"
trip "$(counts 'del(.judge_calls) | .card_redeclares={"u-3f9a2c":"n/a"} | .class_today={"queue-requeue":"n/a"}')"; quiet "B9 missing and n/a"
grep -q 'tripwire: judge-calls unread' "$HARNESS/logs/unblock.log" && grep -q 'tripwire: card-redeclare unread' "$HARNESS/logs/unblock.log" \
  && grep -q 'tripwire: class-burst unread' "$HARNESS/logs/unblock.log" && ok || bad "B9: an unread field must log 'tripwire: <kind> unread'"
trip 'not json'; quiet "B9b not json"
UNBLOCK_TRIPWIRE_JUDGE_MAX=30 trip "$(counts '.judge_calls=21')"; quiet "B8b the knob raises the bound"
trip "$(counts '.class_today={"queue-requeue":13} | .class_baseline7d={"queue-requeue":3} | .judge_calls=21')"
[ "$(n '^lane-alert --severity warn --id unblock-tripwire-')" = 2 ] && ok || bad "B: two tripwires in one scan fire two alerts"
# B10: 4x the baseline fires one warn alert AND the next action still writes.
newcase b10
trip "$(counts '.class_today={"queue-requeue":4} | .class_baseline7d={"queue-requeue":1}')"; fires "B10 4x" class-burst queue-requeue
run "$(mk requeue)"; expect "B10 the next action still runs" done requeued
[ "$(n '^mc_requeue_mergify')" = 1 ] && ok || bad "B10: the requeue after the tripwire must go out"

echo "unblock-act.bh-7726: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
