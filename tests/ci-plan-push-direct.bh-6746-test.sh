#!/bin/bash
# tests/ci-plan-push-direct.bh-6746-test.sh — BH-6746 (wave 3 of #6541): the
# `push-direct` event class of bin/ci-plan.sh (bin/lib/ci-push-direct.sh).
#
# A push to main that the merge conductor landed DIRECTLY carries the commit
# status `landing-path=success` / `path=direct` (bin/lib/mc/landing.sh
# landing_path_publish). With CI_PLAN_LANDING=1 the plan then runs the merge's
# impact set plus the always set, not the full corpus and not fast-only. A push
# with no mark stays full (fail closed); a green Mergify batch push stays
# queue-tested.
#
#   C1  mark -> mode=push-direct, corpus=1, push_class=push-direct; the list is
#       the select list plus the always list, count < total; the summary names
#       the sha8; select ran with TI_NAMED_BASE and no ci-select ran
#   C1b the mark appears on the 2nd read -> push-direct
#   C1c a mark, but the diff names .mergify.yml -> full, the reason names it
#   C2  mergify[bot] + green batch tree + mark -> queue-tested, corpus=0,
#       push_class=queue-tested, and no statuses read
#   C3  no mark -> full after the wait; the reason says `no direct-landing mark`
#   C3b description path=queue -> full (near miss); also `path=direct ` and
#       context landing-path-x / lead-verdict saying path=direct
#   C3c newest failure above an older success -> full
#   C3d the gh read fails -> full at once (one read, no poll)
#   C3e CI_PLAN_LANDING unset + mark -> full, and no statuses read
#   S1  a shard: CI_PLAN_PUSH_CLASS=push-direct --expect-n <plan n> with a gh
#       that fails -> rc 0, the same list, no gh call; =full -> full
#   M1  a copy of the lib with the always union removed drops the always suites
#   N1  a non-push run writes push_class=-
#
# The real bin/ci-plan.sh is driven; bin/test-impact.sh and gh are recording
# fakes (the tests/ci-plan-test.sh shape), the diff comes from
# CI_PLAN_CHANGED_FILE.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PLAN="$DIR/bin/ci-plan.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

cat > "$T/fake-impact.sh" <<'FAKE'
#!/bin/bash
printf '%s TI_EVENT=%s TI_NAMED_BASE=%s\n' "$*" "${TI_EVENT:-}" "${TI_NAMED_BASE:-}" >> "$FAKE_SINK"
OUT=""
while [ $# -gt 0 ]; do case "$1" in --out) OUT="$2"; shift ;; --changed) shift ;; *) CMD="$1" ;; esac; shift; done
case "$CMD" in
  always)    SRC="$FAKE_ALWAYS" ;;
  ci-select) SRC="$FAKE_ALL"; echo "impact: $(grep -c . "$SRC") of $(grep -c . "$FAKE_ALL") suites (full: event '${TI_EVENT:-}' is not a pull request)" >&2 ;;
  select)    SRC="$FAKE_SELECT"
             echo "impact: $(grep -c . "$SRC") of $(grep -c . "$FAKE_ALL") suites (${FAKE_REASON:-selected: 1 changed path(s)})" >&2 ;;
esac
if [ -n "$OUT" ]; then cat "$SRC" > "$OUT"; else cat "$SRC"; fi
FAKE
chmod +x "$T/fake-impact.sh"

mklist() { # <file> <prefix> <count>
  local i; : > "$1"
  for ((i = 1; i <= $3; i++)); do printf 'tests/%s%04d-test.sh\n' "$2" "$i" >> "$1"; done
}
mklist "$T/all.txt" s 980
mklist "$T/always.txt" a 3
cat "$T/always.txt" >> "$T/all.txt"
mklist "$T/sel30.txt" s 30
printf 'bin/x.sh\n' > "$T/changed-bin.txt"
printf 'bin/x.sh\n.mergify.yml\n' > "$T/changed-mergify.txt"

SHA=abcdef12aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
TREE=$(git -C "$DIR" rev-parse 'HEAD^{tree}')
# The fake gh: statuses answer $FAKE_ST from the $FAKE_ST_FROM-th read on
# (earlier reads answer []); the merge-queue runs answer the ci-plan-test shape.
cat > "$T/fake-gh" <<FAKEGH
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-sink"
[ -n "\${FAKE_GH_FAIL:-}" ] && exit 1
case "\$*" in
  *"/statuses"*)
    n=\$(( \$(cat "$T/gh-n" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$T/gh-n"
    if [ "\$n" -ge "\${FAKE_ST_FROM:-1}" ] && [ -n "\${FAKE_ST:-}" ]; then cat "\$FAKE_ST"; else echo '[]'; fi ;;
  *"actions/runs?event=pull_request&status=success"*)
    printf '{"workflow_runs":[{"name":"Harness CI","conclusion":"success","head_sha":"b1","head_branch":"mergify/merge-queue/x"}]}\n' ;;
  *"git/commits/b1"*) echo "\${FAKE_TREE_B1:-deadbeef}" ;;
  *) exit 1 ;;
esac
FAKEGH
chmod +x "$T/fake-gh"

st() { # st <file> <context> <state> <description> [<context> <state> <description> ...] — newest first
  local f="$1"; shift
  local j='[]'
  while [ $# -ge 3 ]; do
    j=$(jq -c --arg c "$1" --arg s "$2" --arg d "$3" '. + [{context:$c, state:$s, description:$d, target_url:null}]' <<<"$j")
    shift 3
  done
  printf '%s\n' "$j" > "$f"
}
st "$T/st-direct.json"  landing-path success "path=direct" lead-verdict success "lead ok"
st "$T/st-none.json"    lead-verdict success "lead ok"
st "$T/st-queue.json"   landing-path success "path=queue"
st "$T/st-space.json"   landing-path success "path=direct "
st "$T/st-ctx.json"     landing-path-x success "path=direct" lead-verdict success "path=direct"
st "$T/st-inherit.json" landing-path failure "path=direct" landing-path success "path=direct"

BASEENV=(CI_PLAN_IMPACT="$T/fake-impact.sh" FAKE_SINK="$T/sink" FAKE_ALL="$T/all.txt" FAKE_ALWAYS="$T/always.txt"
         FAKE_SELECT="$T/sel30.txt" CI_PLAN_CHANGED_FILE="$T/changed-bin.txt" CI_PLAN_GH="$T/fake-gh"
         CI_REPO=o/r CI_SHA="$SHA" CI_PLAN_SETTLE_S=0 CI_PLAN_MAIN_HEAD_CMD="echo $SHA"
         CI_PLAN_DIRECT_POLL_S=1 CI_PLAN_DIRECT_WAIT_S=2)
plan() { # plan <event> [VAR=value ...] — one run; sets RC, OUT, GO; PLAN_ARGS adds flags
  local ev="$1"; shift
  : > "$T/sink"; : > "$T/gh-sink"; rm -f "$T/go" "$T/list" "$T/gh-n"
  OUT=$(env -u CI_PLAN_LANDING -u CI_PLAN_PUSH_CLASS -u CI_ACTOR CI_EVENT="$ev" "${BASEENV[@]}" \
          GITHUB_OUTPUT="$T/go" "$@" "${PLAN_BIN:-$PLAN}" --out "$T/list" ${PLAN_ARGS[@]+"${PLAN_ARGS[@]}"} 2>&1); RC=$?
  GO=$(cat "$T/go" 2>/dev/null)
}
out() { printf '%s\n' "$GO" | sed -n "s/^$1=//p" | tail -1; }
st_reads() { grep -c '/statuses' "$T/gh-sink" 2>/dev/null; }
DIRECT=(CI_PLAN_LANDING=1 CI_ACTOR='example-org-harness[bot]')
PLAN_ARGS=()

# ── C1. a direct-landed push: impact + always, not full, not fast-only.
plan push "${DIRECT[@]}" FAKE_ST="$T/st-direct.json"
[ "$RC" -eq 0 ] && ok || bad "C1: rc=$RC [$OUT]"
{ [ "$(out mode)" = push-direct ] && [ "$(out corpus)" = 1 ] && [ "$(out push_class)" = push-direct ]; } && ok \
  || bad "C1: mode=$(out mode) corpus=$(out corpus) push_class=$(out push_class) [$OUT]"
EXP=$(LC_ALL=C sort -u "$T/sel30.txt" "$T/always.txt")
[ "$(LC_ALL=C sort "$T/list" 2>/dev/null)" = "$EXP" ] && ok || bad "C1: the list must be select ∪ always ($(grep -c . "$T/list" 2>/dev/null) rows)"
{ [ "$(out count)" = 33 ] && [ "$(out total)" = 983 ] && [ "$(out count)" -lt "$(out total)" ]; } && ok \
  || bad "C1: count=$(out count) total=$(out total), want 33 of 983"
has "${SHA:0:8}" "$(out summary)" && has "push-direct" "$(out summary)" && ok || bad "C1: the summary must name the sha8 and the class: '$(out summary)'"
grep -q "^select .*TI_NAMED_BASE=[0-9a-f]\{40\}" "$T/sink" && ok || bad "C1: select must run with the first parent as TI_NAMED_BASE: $(cat "$T/sink")"
grep -q '^always' "$T/sink" && ok || bad "C1: the always set must be read: $(cat "$T/sink")"
grep -q 'ci-select' "$T/sink" && bad "C1: a push-direct plan must not run the full ci-select: $(cat "$T/sink")" || ok
C1N=$(out n); cp "$T/list" "$T/c1.list"

# ── C1b. the mark lands a second after the push: the poll finds it.
plan push "${DIRECT[@]}" FAKE_ST="$T/st-direct.json" FAKE_ST_FROM=2
{ [ "$RC" -eq 0 ] && [ "$(out mode)" = push-direct ] && [ "$(st_reads)" = 2 ]; } && ok \
  || bad "C1b: mode=$(out mode) reads=$(st_reads) rc=$RC [$OUT]"

# ── C1c. a mark, but the merge changes an escalating path: full, with the path.
plan push "${DIRECT[@]}" FAKE_ST="$T/st-direct.json" CI_PLAN_CHANGED_FILE="$T/changed-mergify.txt"
{ [ "$RC" -eq 0 ] && [ "$(out mode)" = full ] && [ "$(out count)" = 983 ] && [ "$(out push_class)" = full ]; } && ok \
  || bad "C1c: mode=$(out mode) count=$(out count) push_class=$(out push_class) rc=$RC [$OUT]"
has ".mergify.yml" "$(out summary)" && ok || bad "C1c: the reason must name the escalating path: '$(out summary)'"

# ── C2. a green Mergify batch push stays queue-tested, mark or not.
plan push CI_PLAN_LANDING=1 CI_ACTOR='mergify[bot]' FAKE_TREE_B1="$TREE" FAKE_ST="$T/st-direct.json"
{ [ "$RC" -eq 0 ] && [ "$(out mode)" = queue-tested ] && [ "$(out corpus)" = 0 ] && [ "$(out push_class)" = queue-tested ]; } && ok \
  || bad "C2: mode=$(out mode) corpus=$(out corpus) push_class=$(out push_class) rc=$RC [$OUT]"
[ "$(st_reads)" = 0 ] && ok || bad "C2: a queue-tested push must not read the landing mark ($(st_reads) reads)"

# ── C3. no mark: full after the bounded wait, said in the reason.
plan push "${DIRECT[@]}" FAKE_ST="$T/st-none.json"
{ [ "$RC" -eq 0 ] && [ "$(out mode)" = full ] && [ "$(out count)" = 983 ] && [ "$(out push_class)" = full ]; } && ok \
  || bad "C3: mode=$(out mode) count=$(out count) push_class=$(out push_class) rc=$RC [$OUT]"
has "no direct-landing mark on ${SHA:0:8} after 2s" "$(out summary)" && ok || bad "C3: the reason must say no mark after the wait: '$(out summary)'"
[ "$(grep -c . "$T/list")" = 983 ] && ok || bad "C3: the full list must be written"
[ "$(st_reads)" = 3 ] && ok || bad "C3: wait 2s at 1s polls is 3 reads, got $(st_reads)"

# ── C3b. near misses: not success path=direct on context landing-path.
for f in st-queue st-space st-ctx; do
  plan push "${DIRECT[@]}" FAKE_ST="$T/$f.json"
  [ "$(out mode)" = full ] && ok || bad "C3b: $f must plan full, got mode=$(out mode) [$OUT]"
done

# ── C3c. the newest landing-path wins: a failure above an older success is full.
plan push "${DIRECT[@]}" FAKE_ST="$T/st-inherit.json"
{ [ "$(out mode)" = full ] && [ "$(st_reads)" = 1 ]; } && ok || bad "C3c: mode=$(out mode) reads=$(st_reads) [$OUT]"

# ── C3d. the read fails: full at once, no poll (one read, not a 30 s wait).
plan push "${DIRECT[@]}" FAKE_ST="$T/st-direct.json" FAKE_GH_FAIL=1 CI_PLAN_DIRECT_WAIT_S=30
{ [ "$RC" -eq 0 ] && [ "$(out mode)" = full ] && [ "$(grep -c '/statuses' "$T/gh-sink")" = 1 ]; } && ok \
  || bad "C3d: mode=$(out mode) reads=$(grep -c '/statuses' "$T/gh-sink") rc=$RC [$OUT]"
has "landing mark unreadable" "$(out summary)" && ok || bad "C3d: the reason must say unreadable: '$(out summary)'"

# ── C3e. the switch: CI_PLAN_LANDING unset is today's answer, with no read.
plan push CI_ACTOR='example-org-harness[bot]' FAKE_ST="$T/st-direct.json"
{ [ "$(out mode)" = full ] && [ "$(st_reads)" = 0 ] && [ "$(out count)" = 983 ]; } && ok \
  || bad "C3e: mode=$(out mode) reads=$(st_reads) [$OUT]"

# ── S1. a shard re-plans the class with no network and agrees on n and list.
PLAN_ARGS=(--expect-n "$C1N")
plan push CI_PLAN_PUSH_CLASS=push-direct FAKE_GH_FAIL=1
{ [ "$RC" -eq 0 ] && [ "$(out mode)" = push-direct ] && [ "$(out n)" = "$C1N" ]; } && ok \
  || bad "S1: rc=$RC mode=$(out mode) n=$(out n) want $C1N [$OUT]"
cmp -s "$T/list" "$T/c1.list" && ok || bad "S1: the shard list must equal the plan job's"
[ ! -s "$T/gh-sink" ] && ok || bad "S1: a shard must not call gh: $(cat "$T/gh-sink")"
PLAN_ARGS=()
plan push CI_PLAN_PUSH_CLASS=full CI_PLAN_LANDING=1 FAKE_ST="$T/st-direct.json"
{ [ "$(out mode)" = full ] && [ "$(st_reads)" = 0 ]; } && ok || bad "S1: CI_PLAN_PUSH_CLASS=full is full with no read (mode=$(out mode) reads=$(st_reads))"

# ── N1. a non-push run says push_class=-.
plan workflow_dispatch
[ "$(out push_class)" = - ] && ok || bad "N1: a dispatch must write push_class=-, got '$(out push_class)'"

# ── M1. mutation: the lib without the always union drops the always suites.
mkdir -p "$T/mut" && cp -r "$DIR/bin" "$DIR/catalog" "$T/mut/" || exit 1
sed -i 's|LC_ALL=C sort -u "\$LIST" "\$TMP/cpd.always"|LC_ALL=C sort -u "$LIST"|' "$T/mut/bin/lib/ci-push-direct.sh"
if cmp -s "$DIR/bin/lib/ci-push-direct.sh" "$T/mut/bin/lib/ci-push-direct.sh"; then
  bad "M1: the mutation did not apply"
else
  PLAN_BIN="$T/mut/bin/ci-plan.sh" plan push "${DIRECT[@]}" FAKE_ST="$T/st-direct.json"
  [ "$(LC_ALL=C sort "$T/list" 2>/dev/null)" = "$EXP" ] && bad "M1: C1's list check stays green under the mutation" || ok
fi

echo "ci-plan-push-direct: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
