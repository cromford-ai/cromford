#!/bin/bash
# tests/ci-plan-batch-member-label.bh-4969-test.sh — a merge-queue batch runs
# the whole corpus when any PR it carries is labelled `full`, and when it cannot
# tell (BH-4969, C1 of BH-4964).
#
# WHY. Mergify does not copy a member's labels onto the batch draft, so after
# BH-4968 a PR labelled `full` was batch-selected with the rest of its batch.
# bin/ci-plan.sh now reads the label of every #<n> in the draft's title and
# body with the job's own token. A read that fails is never "no label": it
# escalates as `member labels unreadable`. The shards take the plan job's
# answer through CI_PLAN_ESCALATION and never read GitHub themselves, so
# --expect-n keeps agreeing.
#
#   M1  a member labelled full escalates and names it
#   M2  a gh that fails escalates as unreadable
#   M3  non-JSON, no #<n>, no repo, no gh, >40 refs: each escalates as unreadable
#   M4  members with other labels stay batch-selected, every ref read once
#   M5  a shard with the plan's reason is full and makes no gh call
#   M6  a shard with `-` skips the read, even with a failing gh
#   M7  the plan job and a shard agree on n under --expect-n
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PLAN="$DIR/bin/ci-plan.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

mklist() { local i; : > "$1"; for ((i = 1; i <= $2; i++)); do printf 'tests/s%04d-test.sh\n' "$i" >> "$1"; done; }
mklist "$T/all.txt" 300; mklist "$T/sel.txt" 3
# REGN: the `*` rows of the REAL catalog/ci-batch-regression.d/ (BH-9439). The
# planner's regression union reads the real bin/test-impact.sh, never the fake,
# so an escalated batch runs the 300 plus these; the count stays exact.
printf 'docs/x.md\n' > "$T/reg.changed"
REGN=$( ( cd "$DIR" && bin/test-impact.sh regression --changed "$T/reg.changed" ) 2>/dev/null | awk -F'\t' '$2 == "*" { print $1 }' \
  | LC_ALL=C sort -u | while read -r r; do [ -f "$DIR/$r" ] && echo "$r"; done | grep -c .)
cat > "$T/fake.sh" <<'FAKE'
#!/bin/bash
OUT=""; CMD=""
while [ $# -gt 0 ]; do case "$1" in --out) OUT="$2"; shift ;; --changed) shift ;; *) CMD="${CMD:-$1}" ;; esac; shift; done
case "$CMD" in
  select)    cat "$FAKE_SELECT" > "$OUT"; echo "impact: 3 of 300 suites (selected)" >&2 ;;
  ci-select) cat "$FAKE_ALL" > "$OUT"; echo "impact: 300 of 300 suites (full: fake)" >&2 ;;
esac
FAKE
chmod +x "$T/fake.sh"
# The fake gh: `api repos/o/r/pulls/<n>` answers $FAKE_GH_DIR/<n>.json, logs
# every call to $GH_SINK, and exits FAKE_GH_RC when set. GH_MODE=junk prints
# a line that is not JSON.
cat > "$T/gh" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
[ -z "${FAKE_GH_RC:-}" ] || exit "$FAKE_GH_RC"
[ "${GH_MODE:-}" = junk ] && { echo "not json"; exit 0; }
n="${2##*/}"
[ -f "$FAKE_GH_DIR/$n.json" ] && cat "$FAKE_GH_DIR/$n.json" || echo '{"number":'"$n"',"labels":[]}'
FAKE
chmod +x "$T/gh"
mkdir -p "$T/prs"
echo '{"number":11,"labels":[{"name":"ai-build"}]}' > "$T/prs/11.json"
echo '{"number":12,"labels":[{"name":"ai-build"},{"name":"full"}]}' > "$T/prs/12.json"
echo '{"number":13,"labels":[{"name":"fullish"},{"name":"ai-build"}]}' > "$T/prs/13.json"
: > "$T/notiers.tsv"
printf 'console-ui/src/screens/Jobs.js\n' > "$T/changed"
HEADSHA=$(git -C "$DIR" rev-parse HEAD)
TITLE='merge queue: checking #11 on main (abc1234), stacked on #13'

# bplan <VAR=val ...> [-- --expect-n N] — one batch plan; sets RC OUT GO, gh calls in $T/sink
bplan() {
  local vars=() args=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do vars+=("$1"); shift; done
  [ "${1:-}" = -- ] && { shift; args=("$@"); }
  rm -f "$T/go" "$T/list"; : > "$T/sink"
  OUT=$(env -u GITHUB_ACTIONS -u GITHUB_STEP_SUMMARY -u CI_PLAN_ESCALATION CI_EVENT=pull_request \
          TI_PR_HEAD_REF=mergify/merge-queue/t TI_BASE="$HEADSHA" TI_PR_LABELS= CI_QUARANTINE= \
          TI_PR_TITLE="$TITLE" CI_PR_BODY= CI_REPO=o/r CI_PLAN_GH="$T/gh" GH_SINK="$T/sink" FAKE_GH_DIR="$T/prs" \
          CI_PLAN_IMPACT="$T/fake.sh" FAKE_ALL="$T/all.txt" FAKE_SELECT="$T/sel.txt" CI_PLAN_CHANGED_FILE="$T/changed" \
          CI_PLAN_TIER_FILE="$T/notiers.tsv" GITHUB_OUTPUT="$T/go" \
          "${vars[@]}" "$PLAN" --out "$T/list" ${args[@]+"${args[@]}"} 2>&1); RC=$?
  GO=$(cat "$T/go" 2>/dev/null)
}
out() { printf '%s\n' "$GO" | sed -n "s/^$1=//p" | tail -1; }
unreadable() { # unreadable <tag> — the last plan escalated as unreadable
  { [ "$RC" = 0 ] && [ "$(out mode)" = full ] && has "member labels unreadable" "$(out escalation)" \
      && [ "$(grep -c . "$T/list")" = $((300 + REGN)) ]; } && ok \
    || bad "$1: must be mode=full, escalation 'member labels unreadable…', 300 + $REGN regression * suites (rc=$RC mode=$(out mode) escalation='$(out escalation)' list=$(grep -c . "$T/list")) [$OUT]"
}
BODY12='This batch carries [#11](https://github.com/o/r/pull/11) and [#12](https://github.com/o/r/pull/12).'
BODY_OK='This batch carries [#11](https://github.com/o/r/pull/11) and [#13](https://github.com/o/r/pull/13), #11 again.'

# ── M1. a member labelled full.
bplan CI_PR_BODY="$BODY12" GITHUB_STEP_SUMMARY="$T/sum"
{ [ "$RC" = 0 ] && [ "$(out mode)" = full ] && [ "$(out escalation)" = "the 'full' label on #12" ]; } && ok \
  || bad "M1: #12 labelled full must escalate (rc=$RC mode=$(out mode) escalation='$(out escalation)') [$OUT]"
has "full: the 'full' label on #12" "$(out summary)" && ok || bad "M1: summary must say 'full: the 'full' label on #12': '$(out summary)'"
[ "$(grep -c . "$T/list")" = $((300 + REGN)) ] && ok || bad "M1: the corpus runs, 300 + $REGN regression *, got $(grep -c . "$T/list")"
grep -qx 'api repos/o/r/pulls/12' "$T/sink" && ok || bad "M1: #12 must be read as repos/o/r/pulls/12: $(cat "$T/sink")"

# ── M2. a gh that fails.
bplan CI_PR_BODY="$BODY_OK" FAKE_GH_RC=1
unreadable M2
has "#11" "$(out escalation)" && ok || bad "M2: the reason names the ref that failed: '$(out escalation)'"

# ── M3. every other way the read can fail.
bplan CI_PR_BODY="$BODY_OK" GH_MODE=junk;                        unreadable "M3 not json"
echo '{"message":"Not Found"}' > "$T/prs/14.json"
bplan CI_PR_BODY='[#14](x)' TI_PR_TITLE=t;                         unreadable "M3 a reply with no labels array"
bplan CI_PR_BODY='no refs here' TI_PR_TITLE='merge queue';       unreadable "M3 no #<n>"
[ ! -s "$T/sink" ] && ok || bad "M3: no refs means no gh call: $(cat "$T/sink")"
bplan CI_PR_BODY="$BODY_OK" CI_REPO=;                             unreadable "M3 no CI_REPO"
bplan CI_PR_BODY="$BODY_OK" CI_PLAN_GH="$T/no-such-gh";          unreadable "M3 no gh"
MANY=$(for i in $(seq 100 141); do printf '#%s ' "$i"; done)
bplan CI_PR_BODY="$MANY" TI_PR_TITLE=t;                            unreadable "M3 more than 40 refs"

# ── M4. no full anywhere: batch-selected, each distinct ref read once.
bplan CI_PR_BODY="$BODY_OK"
{ [ "$RC" = 0 ] && [ "$(out mode)" = batch-selected ] && [ "$(out escalation)" = - ]; } && ok \
  || bad "M4: no member full stays batch-selected (rc=$RC mode=$(out mode) escalation='$(out escalation)') [$OUT]"
[ "$(sort "$T/sink" | tr '\n' ' ')" = "api repos/o/r/pulls/11 api repos/o/r/pulls/13 " ] && ok \
  || bad "M4: #11 and #13 read once each: $(tr '\n' ' ' < "$T/sink")"
MOST=$(for i in $(seq 100 139); do printf '#%s ' "$i"; done)
bplan CI_PR_BODY="$MOST" TI_PR_TITLE=t
{ [ "$(out mode)" = batch-selected ] && [ "$(grep -c . "$T/sink")" = 40 ]; } && ok \
  || bad "M4: exactly 40 refs are read (mode=$(out mode) calls=$(grep -c . "$T/sink"))"

# ── M5. a shard handed the plan's reason: full, no gh call.
bplan CI_PR_BODY="$BODY12" CI_PLAN_ESCALATION="the 'full' label on #12"
{ [ "$RC" = 0 ] && [ "$(out mode)" = full ] && [ "$(out escalation)" = "the 'full' label on #12" ]; } && ok \
  || bad "M5: a forced reason is full with that reason (rc=$RC mode=$(out mode) escalation='$(out escalation)')"
[ ! -s "$T/sink" ] && ok || bad "M5: a shard must not call gh: $(cat "$T/sink")"

# ── M6. a shard with `-`: no read, still batch-selected, even when gh would fail.
bplan CI_PR_BODY="$BODY12" CI_PLAN_ESCALATION=- FAKE_GH_RC=1
{ [ "$RC" = 0 ] && [ "$(out mode)" = batch-selected ]; } && ok || bad "M6: '-' skips the member read (rc=$RC mode=$(out mode) escalation='$(out escalation)')"
[ ! -s "$T/sink" ] && ok || bad "M6: a shard must not call gh: $(cat "$T/sink")"
# ...but '-' does not switch off the other checks.
bplan CI_PLAN_ESCALATION=- TI_PR_LABELS=full
[ "$(out escalation)" = "the 'full' label" ] && ok || bad "M6: '-' still honours the draft's own label: '$(out escalation)'"

# ── M7. plan job then shard, the way the workflow wires them.
bplan CI_PR_BODY="$BODY12"
PN=$(out n); PE=$(out escalation)
bplan CI_PLAN_ESCALATION="$PE" FAKE_GH_RC=1 -- --expect-n "$PN"
{ [ "$RC" = 0 ] && [ "$(out n)" = "$PN" ] && [ ! -s "$T/sink" ]; } && ok \
  || bad "M7: the shard must agree with n=$PN (rc=$RC n=$(out n)) [$OUT]"
bplan CI_PR_BODY="$BODY_OK"
PN=$(out n); PE=$(out escalation)
bplan CI_PLAN_ESCALATION="$PE" FAKE_GH_RC=1 -- --expect-n "$PN"
{ [ "$RC" = 0 ] && [ "$(out mode)" = batch-selected ] && [ ! -s "$T/sink" ]; } && ok \
  || bad "M7: an unescalated plan's shard agrees too (rc=$RC mode=$(out mode)) [$OUT]"

echo "ci-plan-batch-member-label.bh-4969-test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
