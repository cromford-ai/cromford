#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# tests/dispatch-no-open-parent.bh-6389-test.sh — BH-6389. A child ticket that
# is launched onto its parent's OPEN branch (STACK_BASE) no longer stacks by
# default. Under STACK_WAIT_PARENT_MERGE=plan (the new default) the child:
#   * is planned once on the parent branch, then DEFERRED unless its plan has a
#     `## Stack` section whose files are disjoint from the parent's diff and the
#     parent's plan files. The deferral writes a `stack-wait` ledger row and one
#     `Blocked-by #<parent>` comment on the child issue;
#   * defers BEFORE planning on later ticks while the row is under the cap;
#   * builds from main once the parent branch is gone (the parent merged);
#   * builds from main without the parent at STACK_WAIT_CAP_H;
#   * stacks as before when it is a hotfix.
# The two run-build blocks (`stacked child builds` and `stack plan check
# (BH-6389)`) are extracted from the flattened pipeline and DRIVEN against a
# real bare origin, in the order run-build runs them, with the plan stage
# replaced by a fixture plan.md.
# Run from anywhere: tests/dispatch-no-open-parent.bh-6389-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
unset STACK_WAIT_PARENT_MERGE STACK_WAIT_CAP_H HOTFIX STACKED_BUILDS
NOW=1760000000

# ---------------------------------------------------------------- scratch harness
mkdir -p "$T/b/flags" "$T/b/logs"
scratch_install_closure bin/fleet-conf.sh "$T/b" >/dev/null || bad "could not install bin/fleet-conf.sh into the scratch harness"
scratch_install_closure bin/lib/stale-parent.sh "$T/b" >/dev/null || bad "could not install bin/lib/stale-parent.sh into the scratch harness"
# Before BH-6389 there is no lib: that is a red, never a skip.
scratch_install_closure bin/lib/stack-wait.sh "$T/b" >/dev/null 2>&1 || bad "could not install bin/lib/stack-wait.sh into the scratch harness"
cat > "$T/b/fleet.conf" <<'CONF'
# project repo prod board_prefix offset box tailnet_ip
demo-os example-org/demo-os https://demo.example.com - 0 box1 192.0.2.1
demo-board example-org/demo-board https://board.example.com /api/boards/b1 0 box1 192.0.2.1
CONF
export FLEET_CONF="$T/b/fleet.conf"
[ "$("$T/b/bin/fleet-conf.sh" demo-os board_prefix)" = "-" ] && ok || bad "fixture: demo-os must read as an issues project"

# ---------------------------------------------------------------- origin
# main has f.txt. The parent ticket/xx-41 edits bin/p.sh and commits its plan,
# which names worker/p.js (a file only the PLAN claims, not the diff yet).
git init -q --bare "$T/origin.git"
git init -q "$T/seed" && ( cd "$T/seed"
  git config user.email t@t; git config user.name t
  echo base > f.txt; mkdir -p bin; echo 'echo p' > bin/p.sh; git add .; git commit -qm base
  git branch -M main; git remote add origin "$T/origin.git"; git push -q origin main
  git checkout -qb ticket/xx-41
  echo 'echo parent' >> bin/p.sh
  mkdir -p .harness/specs/XX-41
  printf '# XX-41 parent\n\n## Files to touch\n\n- `bin/p.sh`\n- `worker/p.js` (new)\n\n## Verify (run, not edited)\n\n- `tests/verify-only.sh`\n' > .harness/specs/XX-41/plan.md
  git add .; git commit -qm parent; git push -q origin ticket/xx-41 ) >/dev/null 2>&1
git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
git -C "$T/repo" ls-remote --exit-code origin ticket/xx-41 >/dev/null 2>&1 && ok || bad "fixture: origin must carry the parent branch"

# ---------------------------------------------------------------- plan fixtures
mkdir -p "$T/plans"
printf '# XX-42\n\n## Files to touch\n\n- `bin/c.sh`\n\n## Acceptance tests\n\n- t\n' > "$T/plans/none.md"
printf '# XX-42\n\n## Stack\n\n- `bin/c.sh`\n- `tests/c-test.sh` (new)\n- `.harness/specs/XX-42/plan.md`\n\n## Tasks\n\nedit `bin/p.sh` is NOT ours\n' > "$T/plans/disjoint.md"
printf '# XX-42\n\n## Stack\n\n- `bin/c.sh`\n- `bin/p.sh`\n\n## Tasks\n' > "$T/plans/shared.md"
printf '# XX-42\n\n## Stack\n\n- `worker/p.js`\n' > "$T/plans/planfile.md"
printf '# XX-42\n\n## Stack\n\n- `bin/`\n' > "$T/plans/dir.md"
printf '# XX-42\n\n## Stack\n\n- `bin/p.sh.bak`\n- `bin/lib2/x.sh`\n' > "$T/plans/bak.md"
printf '# XX-42\n\n### Stack trace\n\n- `bin/c.sh`\n\n## Stacked builds\n\n- `bin/d.sh`\n\n## Stack trace\n\n- `bin/e.sh`\n\nThe Stack is fine: `bin/f.sh`\n' > "$T/plans/notstack.md"
printf '# XX-42\n\n## Stack\n\nnothing here\n\n## Tasks\n\n- `bin/c.sh`\n' > "$T/plans/empty.md"
printf '# XX-42\n\n```\n## Stack\n- `bin/c.sh`\n```\n\n## Tasks\n' > "$T/plans/fenced.md"

# ---------------------------------------------------------------- blocks
awk '/^# >>> stacked child builds/{f=1;next} /^# <<< stacked child builds/{exit} f' "$RB_ALL" > "$T/stack.sh"
[ -s "$T/stack.sh" ] && ok || bad "could not extract the stacked child builds block"
awk '/^# >>> stack plan check \(BH-6389\)/{f=1;next} /^# <<< stack plan check \(BH-6389\)/{exit} f' "$RB_ALL" > "$T/check.sh"
[ -s "$T/check.sh" ] && ok || bad "could not extract the stack plan check (BH-6389) block from rb_gate_overlap"
# The post-plan check runs after the plan and before every other overlap gate.
awk '/^rb_gate_overlap\(\) \{/{getline; print; exit}' "$DIR/bin/lib/rb/gates.sh" | grep -q '^# >>> stack plan check (BH-6389)' \
  && ok || bad "the stack plan check must be the first block of rb_gate_overlap"
[ "$(grep -c 'sw_plan_note' "$DIR/bin/lib/rb/plan.sh")" = 1 ] \
  && ok || bad "N1: bin/lib/rb/plan.sh must call sw_plan_note exactly once"

# The driver: run-build's names at that point, the pipeline's RESULT/STAMP, and
# stubs for gh_rest (the issue body), gh_rest_comment and the jobs ledger.
cat > "$T/driver.sh" <<'SH'
set -uo pipefail
STAMP() { echo TS; }
RESULT() { printf '%s\n' "$*" > "$T/result"; }
gh_rest() {
  printf '%s\n' "$*" >> "$T/rest-calls.txt"
  # BH-6537: the gate reads the parent PR state first; ticket/xx-41 is an open PR.
  case "$*" in *pulls*head=example-org:ticket/xx-41*) jq -nc '[{number:900,state:"open",merged_at:null,html_url:"https://github.com/example-org/demo-os/pull/900"}]'; return 0 ;; esac
  case "$*" in *issues/42*) ;; *) return 1 ;; esac
  case "${BODY_MODE:-plain}" in
    rollout) jq -nc '{number:42, body:"Blocked-by: #41 (hard)\nRollout wave 2 of 3: planned by its author"}' ;;
    *)       jq -nc '{number:42, body:"Blocked-by: #41 (hard)"}' ;;
  esac
}
gh_rest_comment() {
  printf '%s %s\n' "$1" "$2" >> "$T/comment-calls.txt"
  cat "$3" >> "$T/comment-bodies.txt"
  return "${COMMENT_RC:-0}"
}
job_ledger_row() {
  [ "${LEDGER_DOWN:-0}" = 1 ] && return 1
  local line
  line=$(awk -F'\t' -v k="$1" -v v="$2" '$1==k && $2==v' "$T/ledger.tsv" 2>/dev/null | tail -1)
  [ -n "$line" ] || return 2
  jq -nc --arg s "$(cut -f3 <<<"$line")" --arg d "$(cut -f4 <<<"$line")" '{status:$s, detail:$d}'
}
job_ledger_put() {
  [ "${LEDGER_DOWN:-0}" = 1 ] && return 1
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >> "$T/ledger.tsv"
}
if [ "${SKIP_STACK:-0}" = 1 ]; then
  BASE_MAIN=main; STACK_ON="$STACK_BASE"; BASE="$STACK_ON"
else
  BASE=main
  . "$1"
fi
# the plan stage
[ -n "${PLAN_FIXTURE:-}" ] && cp "$PLAN_FIXTURE" "$BUILD/plan.md"
. "$2"
printf '%s|%s|%s\n' "$BASE" "$STACK_ON" "$BASE_MAIN"
SH

reset_state() { rm -f "$T/ledger.tsv" "$T/comment-calls.txt" "$T/comment-bodies.txt" "$T/b/logs/stack-wait.log"; scratch_rm "$T/b/state"; }
BLD="$T/b/builds/b"
# run_sw <plan-fixture> [VAR=val...] — prints "rc|BASE|STACK_ON|BASE_MAIN"
run_sw() {
  local pf="$1" out rc; shift
  rm -f "$T/result"; : > "$T/rest-calls.txt"
  case " $* " in *" KEEP_BUILD=1 "*) ;; *) scratch_rm "$BLD" ;; esac
  mkdir -p "$BLD"; touch "$BLD/pipeline.log"
  out=$( export T HARNESS="$T/b" PROJECT=demo-os KEY=XX-42 TICKET=42 GH_AUTH_SLUG=example-org/demo-os \
           BUILD="$BLD" REPO="$T/repo" STACK_BASE=ticket/xx-41 SW_NOW="$NOW" PLAN_FIXTURE="$pf" \
           STACK_PARENT_PR=https://github.com/example-org/demo-os/pull/900
         [ $# -gt 0 ] && { export "$@" 2>/dev/null || true; }
         bash "$T/driver.sh" "$T/stack.sh" "$T/check.sh" 2>/dev/null ); rc=$?
  printf '%s|%s\n' "$rc" "$out"
}
row()      { awk -F'\t' -v v="$1" '$1=="stack-wait" && $2==v' "$T/ledger.tsv" 2>/dev/null | tail -1; }
row_st()   { row "$1" | cut -f3; }
row_since(){ row "$1" | cut -f4 | sed -n 's/^since=\([0-9]*\).*/\1/p'; }
ncalls()   { [ -f "$T/comment-calls.txt" ] && grep -c . "$T/comment-calls.txt" || echo 0; }
res()      { cat "$T/result" 2>/dev/null; }
plog()     { cat "$BLD/pipeline.log" 2>/dev/null; }
put_row()  { printf 'stack-wait\t%s\t%s\tsince=%s why=fixture\n' "$1" "$2" "$3" >> "$T/ledger.tsv"; }
RK='demo-os XX-42 ticket/xx-41'

# ============================================================================
# P1 — open parent, plan with no ## Stack: deferred, row waiting, one comment.
# ============================================================================
reset_state
R=$(run_sw "$T/plans/none.md")
[ "${R%%|*}" = 3 ] && ok || bad "P1: an open parent and a plan with no Stack section must exit 3 (got '$R')"
grep -q '^BUILD_DEFERRED stack-wait:' <<<"$(res)" && grep -q 'Blocked-by #41' <<<"$(res)" \
  && ok || bad "P1: expected BUILD_DEFERRED stack-wait naming Blocked-by #41 (got: $(res))"
grep -q 'no Stack section' <<<"$(res)" && ok || bad "P1: the RESULT must give the reason (got: $(res))"
[ "$(row_st "$RK")" = waiting ] && ok || bad "P1: ledger row stack-wait '$RK' must be waiting (got: $(row "$RK"))"
[ "$(row_since "$RK")" = "$NOW" ] && ok || bad "P1: the row's since must be now on the first deferral (got: $(row "$RK"))"
[ "$(ncalls)" = 1 ] && ok || bad "P1: exactly one gh_rest_comment call (got $(ncalls))"
grep -qx 'example-org/demo-os 42' "$T/comment-calls.txt" 2>/dev/null && ok || bad "P1: the comment goes on the child issue #42 (got: $(cat "$T/comment-calls.txt" 2>/dev/null))"
grep -qx 'Blocked-by #41' "$T/comment-bodies.txt" 2>/dev/null && ok || bad "P1: the comment carries a 'Blocked-by #41' line (got: $(cat "$T/comment-bodies.txt" 2>/dev/null))"
grep -q '—' "$T/comment-bodies.txt" 2>/dev/null && bad "P1: the client-facing comment must carry no em dash" || ok
[ -e "$T/b/state/stack-wait/demo-os/XX-42.ticket_xx-41" ] && ok || bad "P1: the file twin of the row must be written"
grep -q 'STACKED on' <<<"$(plog)" && ok || bad "P1: the first attempt is planned on the parent branch (STACKED on)"

# P8 — the same build resumed after its plan: one comment total, since kept.
R=$(run_sw "$T/plans/none.md" KEEP_BUILD=1 SKIP_STACK=1 SW_NOW=$((NOW + 600)))
[ "${R%%|*}" = 3 ] && ok || bad "P8: a resumed deferral must exit 3 again (got '$R')"
[ "$(ncalls)" = 1 ] && ok || bad "P8: the deferral twice must post ONE comment (got $(ncalls))"
[ "$(row_since "$RK")" = "$NOW" ] && ok || bad "P8/M3: a re-defer must keep the first since (got: $(row "$RK"))"

# P8b / P9 — the next tick (a new build dir): deferred BEFORE the plan.
R=$(run_sw "$T/plans/none.md" SW_NOW=$((NOW + 7200)))
[ "${R%%|*}" = 3 ] && ok || bad "P9: a waiting row under the cap must exit 3 (got '$R')"
grep -q '^BUILD_DEFERRED stack-wait: parent branch ticket/xx-41 is still open and XX-42 has waited 2h of STACK_WAIT_CAP_H=24h' <<<"$(res)" \
  && ok || bad "P9: RESULT must name the wait and the cap (got: $(res))"
grep -q 'Blocked-by #41' <<<"$(res)" && ok || bad "P9: RESULT must name Blocked-by #41 (got: $(res))"
[ -e "$BLD/stack-wait-pending" ] && bad "P9: a pre-plan deferral must not leave a stack-wait-pending file" || ok
grep -q 'STACKED on' <<<"$(plog)" && bad "P9: a pre-plan deferral must not stack" || ok
[ "$(ncalls)" = 1 ] && ok || bad "P8: the next tick must not post again (got $(ncalls))"

# ============================================================================
# P2 — the parent merged (its branch is gone) with a waiting row: main, no RESULT.
# ============================================================================
reset_state; put_row 'demo-os XX-42 ticket/xx-40' waiting $((NOW - 3600))
R=$(run_sw "$T/plans/none.md" STACK_BASE=ticket/xx-40)
[ "$R" = "0|main||main" ] && ok || bad "P2: a deleted parent branch builds on main (got '$R')"
[ -e "$T/result" ] && bad "P2: no RESULT (got: $(res))" || ok
grep -q 'could not be fetched' <<<"$(plog)" && ok || bad "P2: the fetch fallback must be logged"

# ============================================================================
# P3 — disjoint Stack section: stacks at once.
# ============================================================================
reset_state
R=$(run_sw "$T/plans/disjoint.md")
[ "$R" = "0|ticket/xx-41|ticket/xx-41|main" ] && ok || bad "P3: a disjoint Stack section stacks on the parent (got '$R')"
grep -q 'stack-wait: Stack section approved — 2 child files disjoint from' <<<"$(plog)" && ok || bad "P3: the approval must be logged (got: $(plog))"
[ "$(row_st "$RK")" = stacked ] && ok || bad "P3: row must be stacked (got: $(row "$RK"))"
[ "$(ncalls)" = 0 ] && ok || bad "P3: no comment on a stack (got $(ncalls))"
[ -e "$T/result" ] && bad "P3: no RESULT on a stack (got: $(res))" || ok
[ -e "$BLD/stack-wait-pending" ] && bad "P3: the pending file is removed once the stack is approved" || ok

# ============================================================================
# P4 — Stack shares bin/p.sh with the parent's diff: deferred.
# ============================================================================
reset_state
R=$(run_sw "$T/plans/shared.md")
[ "${R%%|*}" = 3 ] && ok || bad "P4: a shared file must defer (got '$R')"
grep -q 'bin/p.sh is in the parent' <<<"$(res)" && ok || bad "P4: the reason must name bin/p.sh (got: $(res))"
[ "$(row_st "$RK")" = waiting ] && ok || bad "P4: row must be waiting (got: $(row "$RK"))"

# ============================================================================
# P5 — the cap: a 25h-old waiting row builds from main without the parent.
# ============================================================================
for age in 25 24; do
  reset_state; put_row "$RK" waiting $((NOW - age * 3600))
  R=$(run_sw "$T/plans/none.md")
  [ "$R" = "0|main||main" ] && ok || bad "P5($age h): at the cap the child builds from main (got '$R')"
  grep -q "stack-wait: STACK_WAIT_CAP_H=24h reached (waited ${age}h) for parent ticket/xx-41 — building XX-42 from main without the parent" <<<"$(plog)" \
    && ok || bad "P5($age h): the log must name the cap (got: $(plog))"
  [ "$(row_st "$RK")" = capped ] && ok || bad "P5($age h): row must be capped (got: $(row "$RK"))"
  [ -e "$T/result" ] && bad "P5($age h): no RESULT at the cap (got: $(res))" || ok
  grep -q 'STACKED on' <<<"$(plog)" && bad "P5($age h): a capped child must not stack" || ok
done
# 23h is under the cap; a lowered cap knob applies.
reset_state; put_row "$RK" waiting $((NOW - 23 * 3600))
R=$(run_sw "$T/plans/none.md")
[ "${R%%|*}" = 3 ] && ok || bad "P5: 23h is under the 24h cap and waits (got '$R')"
R=$(run_sw "$T/plans/none.md" STACK_WAIT_CAP_H=12)
[ "$R" = "0|main||main" ] && grep -q 'STACK_WAIT_CAP_H=12h reached' <<<"$(plog)" \
  && ok || bad "P5: STACK_WAIT_CAP_H=12 must cap a 23h wait (got '$R' / $(plog))"
# a capped row stays capped on the next tick
R=$(run_sw "$T/plans/none.md")
[ "$R" = "0|main||main" ] && ok || bad "P5: a capped row builds from main again (got '$R')"

# ============================================================================
# P6 — hotfix exempt: stacks as today, no row, no comment.
# ============================================================================
reset_state
R=$(run_sw "$T/plans/none.md" HOTFIX=1)
[ "$R" = "0|ticket/xx-41|ticket/xx-41|main" ] && ok || bad "P6: a hotfix child stacks as today (got '$R')"
grep -q 'stack-wait: hotfix exempt — stacking on ticket/xx-41' <<<"$(plog)" && ok || bad "P6: hotfix exempt must be logged"
[ -z "$(row "$RK")" ] && ok || bad "P6: no row for a hotfix (got: $(row "$RK"))"
[ "$(ncalls)" = 0 ] && ok || bad "P6: no comment for a hotfix (got $(ncalls))"

# ============================================================================
# P10 — a board project: deferred, no comment, one stack-wait.log line.
# ============================================================================
reset_state
R=$(run_sw "$T/plans/none.md" PROJECT=demo-board GH_AUTH_SLUG=example-org/demo-board)
[ "${R%%|*}" = 3 ] && ok || bad "P10: a board project defers too (got '$R')"
[ "$(ncalls)" = 0 ] && ok || bad "P10: no GitHub comment on a board project (got $(ncalls))"
[ "$(grep -c . "$T/b/logs/stack-wait.log" 2>/dev/null)" = 1 ] && ok || bad "P10: one logs/stack-wait.log line (got: $(cat "$T/b/logs/stack-wait.log" 2>/dev/null))"

# A failed post: still deferred, the marker is not written, the next one retries.
reset_state
R=$(run_sw "$T/plans/none.md" COMMENT_RC=75)
[ "${R%%|*}" = 3 ] && ok || bad "a failed comment post must still defer (got '$R')"
[ -e "$T/b/state/comment-marks/stack-wait/demo-os/XX-42.ticket_xx-41" ] && bad "a failed post must not write the comment marker" || ok
grep -q 'comment=failed' "$T/b/logs/stack-wait.log" 2>/dev/null && ok || bad "a failed post is logged (got: $(cat "$T/b/logs/stack-wait.log" 2>/dev/null))"

# A rollout wave under plan defers exactly as under rollouts.
reset_state
R=$(run_sw "$T/plans/none.md" BODY_MODE=rollout)
[ "${R%%|*}" = 3 ] && grep -q '^BUILD_DEFERRED stack-wait: parent branch ticket/xx-41 is still open and STACK_WAIT_PARENT_MERGE=rollouts (#42 is a rollout wave)' <<<"$(res)" \
  && ok || bad "a rollout wave under plan defers with the rollouts text (got '$R' / $(res))"

# ============================================================================
# K1-K3 — the knobs.
# ============================================================================
reset_state
R=$(run_sw "$T/plans/none.md" STACK_WAIT_PARENT_MERGE=rollouts)
[ "$R" = "0|ticket/xx-41|ticket/xx-41|main" ] && ok || bad "K1: =rollouts stacks an ordinary child as today (got '$R')"
[ -e "$BLD/stack-wait-pending" ] && bad "K1: =rollouts writes no pending file" || ok
[ -z "$(row "$RK")" ] && [ "$(ncalls)" = 0 ] && ok || bad "K1: =rollouts writes no row and no comment"
R=$(run_sw "$T/plans/none.md" STACK_WAIT_PARENT_MERGE=off)
[ "$R" = "0|ticket/xx-41|ticket/xx-41|main" ] && ok || bad "K1: =off stacks as today (got '$R')"

K=$( unset STACK_WAIT_PARENT_MERGE; export HARNESS="$T/b"; . "$T/b/bin/lib/stale-parent.sh"; sp_wait_mode demo-os )
[ "$K" = plan ] && ok || bad "K2: an unset STACK_WAIT_PARENT_MERGE is plan (got '$K')"
K=$( export HARNESS="$T/b" STACK_WAIT_PARENT_MERGE=plan; . "$T/b/bin/lib/stale-parent.sh"; sp_wait_mode demo-os )
[ "$K" = plan ] && ok || bad "K2: plan is a valid STACK_WAIT_PARENT_MERGE (got '$K')"
for pair in ':24' '0:24' 'x:24' '6:6' '999:336' '336:336'; do
  K=$( export HARNESS="$T/b" STACK_WAIT_CAP_H="${pair%%:*}"; . "$T/b/bin/lib/stale-parent.sh"; sp_knob STACK_WAIT_CAP_H )
  [ "$K" = "${pair##*:}" ] && ok || bad "K3: STACK_WAIT_CAP_H='${pair%%:*}' must read ${pair##*:} (got '$K')"
done

# ============================================================================
# M — the lib's seams.
# ============================================================================
SW="$T/b/bin/lib/stack-wait.sh"
swl() { ( export HARNESS="$T/b" SW_NOW="$NOW"; . "$SW" 2>/dev/null || exit 9; "$@" ); }
for pair in 'ticket/xx-41:41' 'ticket/bh-5366-r2:5366' 'feature/foo:' 'ticket/xx-:'; do
  [ "$(swl sw_pkey "${pair%%:*}")" = "${pair##*:}" ] && ok || bad "sw_pkey ${pair%%:*} must be '${pair##*:}' (got '$(swl sw_pkey "${pair%%:*}")')"
done
# M1 — ledger round trip; M2 — the file twin alone when the ledger is down.
reset_state
lstub='job_ledger_row() { [ "${LEDGER_DOWN:-0}" = 1 ] && return 1; local l; l=$(awk -F"\t" -v k="$1" -v v="$2" "\$1==k && \$2==v" "$T/ledger.tsv" 2>/dev/null | tail -1); [ -n "$l" ] || return 2; jq -nc --arg s "$(cut -f3 <<<"$l")" --arg d "$(cut -f4 <<<"$l")" "{status:\$s, detail:\$d}"; }; job_ledger_put() { [ "${LEDGER_DOWN:-0}" = 1 ] && return 1; printf "%s\t%s\t%s\t%s\n" "$1" "$2" "$3" "${4:-}" >> "$T/ledger.tsv"; }'
M=$( export T HARNESS="$T/b"; eval "$lstub"; . "$SW"; sw_row_put demo-os XX-50 ticket/xx-41 waiting 1000 "why x"; scratch_rm "$T/b/state"; sw_row_get demo-os XX-50 ticket/xx-41 )
[ "$M" = "waiting 1000" ] && ok || bad "M1: the ledger row round-trips (got '$M')"
M=$( export T HARNESS="$T/b" LEDGER_DOWN=1; eval "$lstub"; . "$SW"; sw_row_put demo-os XX-51 ticket/xx-41 waiting 2000 "why y" && sw_row_get demo-os XX-51 ticket/xx-41 )
[ "$M" = "waiting 2000" ] && ok || bad "M2: the file twin round-trips with the ledger down (got '$M')"
M=$( export T HARNESS="$T/b"; eval "$lstub"; . "$SW"; sw_row_get demo-os XX-52 ticket/xx-41; echo "rc=$?" )
[ "$M" = "rc=1" ] && ok || bad "M1: no row anywhere is rc 1 (got '$M')"

mkb() { scratch_rm "$T/mb"; mkdir -p "$T/mb"; cp "$1" "$T/mb/plan.md"; }
post() { mkb "$1"; swl sw_post "$T/mb" "$T/repo" main ticket/xx-41; }
M=$(post "$T/plans/planfile.md"); grep -q '^defer worker/p.js is in the parent' <<<"$M" && ok || bad "M5: a file only in the parent's plan defers (got '$M')"
M=$(post "$T/plans/dir.md");      grep -q '^defer bin/ is in the parent' <<<"$M" && ok || bad "M6: a directory over a parent file defers (got '$M')"
M=$(post "$T/plans/bak.md");      [ "$M" = "stack 2 3" ] && ok || bad "M7: bin/p.sh.bak and bin/lib2/x.sh are not the parent's files (got '$M')"
M=$(post "$T/plans/notstack.md"); [ "$M" = "defer the plan has no Stack section" ] && ok || bad "M8: ### Stack trace / ## Stacked builds / ## Stack trace are not a Stack section (got '$M')"
M=$(post "$T/plans/empty.md");    [ "$M" = "defer the Stack section lists no files" ] && ok || bad "M9: an empty Stack section defers (got '$M')"
M=$(post "$T/plans/fenced.md");   [ "$M" = "defer the plan has no Stack section" ] && ok || bad "M9: a Stack heading inside a fence is not a section (got '$M')"
M=$(post "$T/plans/disjoint.md"); [ "$M" = "stack 2 3" ] && ok || bad "M: the child's own .harness/specs plan is not counted (got '$M')"
M=$(mkb "$T/plans/disjoint.md"; swl sw_post "$T/mb" "$T/repo" main ticket/no-such-branch)
[ "$M" = "defer the parent's diff could not be read" ] && ok || bad "M: an unreadable parent diff defers (got '$M')"
M=$(swl sw_parent_files "$T/repo" main ticket/xx-41 | sort | tr '\n' ' ')
[ "$M" = ".harness/specs/XX-41/plan.md bin/p.sh worker/p.js " ] && ok || bad "M: the parent's files are its diff plus its plan files, Verify section skipped (got '$M')"
M=$(swl sw_overlap $'bin/lib/' $'bin/lib2/x.sh'); [ -z "$M" ] && ok || bad "M7: bin/lib/ is not a prefix of bin/lib2/x.sh (got '$M')"
M=$(swl sw_overlap $'bin/c.sh\nbin/lib/a.sh' $'bin/lib/'); [ "$M" = "bin/lib/a.sh" ] && ok || bad "M6: a parent directory covers a child file (got '$M')"

# N1 — the planner note.
scratch_rm "$T/mb"; mkdir -p "$T/mb"
[ -z "$(swl sw_plan_note "$T/mb")" ] && ok || bad "N1: no pending file, no note"
printf 'ticket/xx-41\nbin/p.sh\nworker/p.js\n' > "$T/mb/stack-wait-pending"
M=$(swl sw_plan_note "$T/mb")
grep -q 'ticket/xx-41' <<<"$M" && grep -q '## Stack' <<<"$M" && grep -q 'bin/p.sh' <<<"$M" \
  && ok || bad "N1: the note names the parent branch, ## Stack and the parent's files (got '$M')"
# N2 — the plan stage's own block puts that note on UI_PLAN_NOTE, and only then.
awk '/^# >>> stack section note \(BH-6389\)/{f=1;next} /^# <<< stack section note \(BH-6389\)/{exit} f' "$RB_ALL" > "$T/note.sh"
[ -s "$T/note.sh" ] && ok || bad "N2: could not extract the stack section note (BH-6389) block from the plan stage"
note_ui() { ( export HARNESS="$T/b"; . "$SW"; BUILD="$T/mb"; UI_PLAN_NOTE="before "; . "$T/note.sh"; printf '%s' "$UI_PLAN_NOTE" ); }
M=$(note_ui)
grep -q '^before THIS CHILD IS PLANNED ON THE OPEN PARENT BRANCH ticket/xx-41' <<<"$M" \
  && ok || bad "N2: with the pending file the plan prompt note carries the Stack rule (got '$M')"
rm -f "$T/mb/stack-wait-pending"
M=$(note_ui)
[ "$M" = "before " ] && ok || bad "N2: without the pending file UI_PLAN_NOTE is unchanged (got '$M')"

echo "dispatch-no-open-parent: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
