#!/bin/bash
# tests/prequeue-restamp-body.bh-7120-test.sh — BH-7120: after the merge
# conductor's restamp push is confirmed (pq_restamp, bin/lib/mc-prequeue.d/restamp.sh,
# through pq_gate in bin/lib/mc-prequeue.sh), it rewrites the old fragment name
# in the PR body (the "Files outside the plan" reason line) with one gh_rest
# GET and at most one PATCH, so pr-self-check plan-files passes on the new head.
#
#   B1  the body names the old path: one GET, one PATCH; the PATCHed body names
#       the new path only; psc_plan_missing on the pushed head with it is empty;
#       one `SCHEMA_RESTAMP body patched` line
#   B2  the body does not name the old path: one GET, no PATCH, `body unchanged`
#   B3  the GET fails: still hold (pushed), no PATCH, `body failed`, no alert
#   B4  the PATCH fails: still hold (pushed), no `patched` line, no alert
#   B5  ACTIONS=0: proceed, no gh_rest call at all
#   M1  mutation: pq_restamp without the _pq_rs_body call makes no PATCH on B1
# Real git: a local origin, the conductor's clone of it, the real
# bin/lib/hold-push.sh push (its hold read stubbed). The mc_* conductor helpers
# are stubs (the tests/prequeue-restamp.bh-6842-test.sh shape); gh_rest is a
# stub that records each call.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prequeue-restamp-body.bh-7120-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export SR_NOW_EPOCH
SR_NOW_EPOCH=$(date -u -d '2026-10-16 06:44' +%s)

# shellcheck source=bin/lib/mc-prequeue.sh
. "$DIR/bin/lib/mc-prequeue.sh" || { echo "FAIL: cannot source bin/lib/mc-prequeue.sh"; exit 1; }
# shellcheck source=bin/lib/hold-push.sh
. "$DIR/bin/lib/hold-push.sh" || { echo "FAIL: cannot source bin/lib/hold-push.sh"; exit 1; }
# shellcheck source=bin/lib/schema-restamp.sh
. "$DIR/bin/lib/schema-restamp.sh" || { echo "FAIL: cannot source bin/lib/schema-restamp.sh"; exit 1; }
# shellcheck source=bin/lib/pr-self-check.sh
. "$DIR/bin/lib/pr-self-check.sh" || { echo "FAIL: cannot source bin/lib/pr-self-check.sh"; exit 1; }

SLUG=o/r; NUM=7055; SD=worker/jobs/schema.d
OLD=202610160227-bh-6889-alert-lines.sql
NEW=202610160644-bh-6889-alert-lines.sql
PLAN=.harness/specs/BH-6889/plan.md
O="$T/origin.git"; W="$T/work"; CL="$T/repos/proj"
export MC_STATE_DIR="$T/state" MC_REPOS="$T/repos"
ATT="$T/att"; LOG="$T/log"; ALERTS="$T/alerts"; GHCALLS="$T/ghcalls"

# ── the gh_rest stub: GET serves $T/body-in as {"body": …}, PATCH -F body=@<f>
#    copies <f> to $T/patched; every call is one line in $GHCALLS ──
gh_rest() {
  printf '%s\n' "$*" >> "$GHCALLS"
  local a
  case "${1:-}" in
    PATCH) [ -e "$T/patch-fail" ] && return 75
           for a in "$@"; do case "$a" in body=@*) cp "${a#body=@}" "$T/patched" || return 75 ;; esac; done
           echo '{}' ;;
    GET) [ -e "$T/get-fail" ] && return 75
         jq -Rs '{body: .}' "$T/body-in" ;;
  esac
}

# ── stubs: the conductor helpers pq_gate and the hook read ──
mc_rest_var() { printf -v "$1" '{"sha":"%s"}' "$MAINSHA"; }
mc_log() { echo "$*" >> "$LOG"; }
mc_attempt_has() { grep -qxF "$1" "$ATT" 2>/dev/null; }
mc_attempt_put() { echo "$1" >> "$ATT"; }
mc_alert() { printf 'key=%s st=%s line=%s\n' "$1" "$2" "$3" >> "$ALERTS"; }
mc_git_locked() { shift; "$@"; }
mc_funnel_repo() { MC_REMOTE="$O"; MC_FUNNEL_WT="$CL"; return 0; }
mc_git_auth_clear() { return 0; }
mc_pool_rebase_enabled() { return 1; }
lane_knob() { return 0; }
pq_resolve() { :; }
pq_status_gate() { :; }
hold_push_verdict() { printf 'clear\tfixture\n'; return 0; }

# seed <body-text> — origin: main forks with 202610140000, the PR branch `pr`
#   adds $OLD and a plan whose Files to touch does NOT name it (the body
#   reason line carries it), main then gains 202610160500.
seed() {
  scratch_rm "$O" 2>/dev/null; scratch_rm "$W" 2>/dev/null; scratch_rm "$CL" 2>/dev/null
  : > "$ATT"; : > "$LOG"; : > "$ALERTS"; : > "$GHCALLS"; rm -f "$T/patched" "$T/get-fail" "$T/patch-fail"
  scratch_rm "$MC_STATE_DIR" 2>/dev/null
  printf '%s\n' "$1" > "$T/body-in"
  git init -q --bare -b main "$O"; mkdir -p "$W/$SD" "$W/${PLAN%/*}"; git -C "$W" init -q -b main
  printf 'CREATE TABLE z (id INTEGER);\n' > "$W/$SD/202610140000-bh-0-z.sql"
  git -C "$W" add -A; git -C "$W" commit -qm base
  git -C "$W" checkout -qb pr
  printf 'CREATE TABLE t (id INTEGER);\n' > "$W/$SD/$OLD"
  printf '# plan\n\n## Files to touch\n- `%s` — this plan.\n' "$PLAN" > "$W/$PLAN"
  git -C "$W" add -A; git -C "$W" commit -qm pr; HEADSHA=$(git -C "$W" rev-parse HEAD)
  git -C "$W" checkout -q main
  printf 'CREATE TABLE a (id INTEGER);\n' > "$W/$SD/202610160500-bh-1-a.sql"
  git -C "$W" add -A; git -C "$W" commit -qm main-a
  git -C "$W" push -q "$O" main pr; MAINSHA=$(git -C "$W" rev-parse main)
  mkdir -p "$MC_REPOS"; git clone -q "$O" "$CL"
  export ACTIONS=1 P=proj BR=pr KEY="$SLUG#$NUM"
}
gate() { pq_gate "$SLUG" "$NUM" "https://github.com/$SLUG/pull/$NUM" "$HEADSHA" main > "$T/word"; WORD=$(cat "$T/word"); }
ohead() { git -C "$O" rev-parse refs/heads/pr; }
patches() { grep -c "^PATCH repos/$SLUG/pulls/$NUM " "$GHCALLS"; }
gets() { grep -cx "GET repos/$SLUG/pulls/$NUM" "$GHCALLS"; }

BODY_OLD="## Why
x

## Files outside the plan
- \`$SD/$OLD\`: changed in this build"

# ── B1: the body names the old path ──
seed "$BODY_OLD"
gate
NEWSHA=$(ohead)
[ "$WORD" = hold ] && [ "$NEWSHA" != "$HEADSHA" ] && ok || bad "B1 a stale head must be restamped and held, got '$WORD' ($(cat "$LOG"))"
[ "$(gets)" = 1 ] && [ "$(patches)" = 1 ] && ok || bad "B1 want one GET and one PATCH: $(cat "$GHCALLS")"
grep -qF "$SD/$NEW" "$T/patched" 2>/dev/null && ! grep -qF "$OLD" "$T/patched" && ok || bad "B1 the PATCHed body must name the new path only: $(cat "$T/patched" 2>/dev/null)"
m=$(psc_plan_missing "$O" main "$NEWSHA" "$T/patched"); rc=$?
[ "$rc" = 0 ] && [ -z "$m" ] && ok || bad "B1 psc_plan_missing with the PATCHed body: rc=$rc '$m'"
m=$(psc_plan_missing "$O" main "$NEWSHA" "$T/body-in")
[ "$m" = "$SD/$NEW" ] && ok || bad "B1 setup: the old body must miss the new path, got '$m'"
grep -qx "$SLUG#$NUM SCHEMA_RESTAMP body patched pr=$NUM reason=.*" "$LOG" && ok || bad "B1 want one body patched line: $(cat "$LOG")"
grep -q 'SCHEMA_RESTAMP pushed' "$LOG" && ok || bad "B1 the pushed line must stay"
[ ! -s "$ALERTS" ] && ok || bad "B1 no alert: $(cat "$ALERTS")"

# ── B2: the body does not name the old path ──
seed "## Why
nothing about fragments"
gate
[ "$WORD" = hold ] && [ "$(gets)" = 1 ] && [ "$(patches)" = 0 ] && ok || bad "B2 want hold, one GET, no PATCH: '$WORD' $(cat "$GHCALLS")"
grep -q "SCHEMA_RESTAMP body unchanged pr=$NUM" "$LOG" && ok || bad "B2 want a body unchanged line: $(cat "$LOG")"

# ── B3: the GET fails ──
seed "$BODY_OLD"; : > "$T/get-fail"
gate
[ "$WORD" = hold ] && [ "$(ohead)" != "$HEADSHA" ] && [ "$(patches)" = 0 ] && ok || bad "B3 a failed GET: want hold after the push, no PATCH: '$WORD' $(cat "$GHCALLS")"
grep -q "SCHEMA_RESTAMP body failed pr=$NUM reason=.*read" "$LOG" && ok || bad "B3 want a body failed line naming the read: $(cat "$LOG")"
[ ! -s "$ALERTS" ] && ok || bad "B3 no alert: $(cat "$ALERTS")"

# ── B4: the PATCH fails ──
seed "$BODY_OLD"; : > "$T/patch-fail"
gate
[ "$WORD" = hold ] && [ "$(patches)" = 1 ] && ok || bad "B4 a failed PATCH: want hold, one PATCH try: '$WORD' $(cat "$GHCALLS")"
grep -q 'SCHEMA_RESTAMP body patched' "$LOG" && bad "B4 a failed PATCH must never log patched: $(cat "$LOG")" || ok
grep -q "SCHEMA_RESTAMP body failed pr=$NUM reason=.*patch" "$LOG" && ok || bad "B4 want a body failed line naming the patch: $(cat "$LOG")"
[ ! -s "$ALERTS" ] && ok || bad "B4 no alert: $(cat "$ALERTS")"

# ── B5: ACTIONS=0 makes no gh_rest call ──
seed "$BODY_OLD"; export ACTIONS=0
gate
[ "$WORD" = proceed ] && [ ! -s "$GHCALLS" ] && [ "$(ohead)" = "$HEADSHA" ] && ok || bad "B5 ACTIONS=0: want proceed and no gh_rest call: '$WORD' $(cat "$GHCALLS")"

# ── M1: pq_restamp without the body call makes no PATCH ──
sed 's/^\( *\)_pq_rs_body /\1: _pq_rs_body /' "$DIR/bin/lib/mc-prequeue.d/restamp.sh" > "$T/mut-rs.sh"
if cmp -s "$T/mut-rs.sh" "$DIR/bin/lib/mc-prequeue.d/restamp.sh"; then
  bad "M1 the mutation anchor '_pq_rs_body ' at a line start is missing from bin/lib/mc-prequeue.d/restamp.sh"
else
  (
    # shellcheck source=/dev/null
    . "$T/mut-rs.sh"
    seed "$BODY_OLD"; gate; echo "word=$WORD patches=$(patches)"
  ) > "$T/m1.out" 2>&1
  grep -qx 'word=hold patches=0' "$T/m1.out" && ok || bad "M1 without the call B1 must see no PATCH (B1 would go red), got: $(cat "$T/m1.out")"
fi

echo "prequeue-restamp-body: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
