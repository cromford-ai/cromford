#!/bin/bash
# tests/rebase-train-caller-check.bh-6718-test.sh — the rebase train runs the
# BH-5791 caller check on the rebased head before it rebinds the approval
# (BH-6718).
#
# HOW IT DRIVES. bin/rebase-train.sh writes under /root/worktrees and runs npx,
# so the whole script cannot run here. The suite lifts the code VERBATIM from
# `# >>> caller check (BH-6718)` through `# <<< head-bound approval` (which
# takes in the real hold_push call between them) and the `# >>> train final
# line (BH-6718)` block, and runs them under `set -euo pipefail` in a real
# clone of a bare origin, after the rebase the train does. The real
# bin/caller-check.sh and its libs come from scratch_install_closure. Stubs:
# hold_push (pushes to the bare origin), bin/lead-verdict.sh (records argv) and
# job_verdict_rebind (records PR and sha). This is the verdict-single-home §1
# technique.
#
#   R0        the slice extracts, in order: check, push, rebind
#   R1-R7     the decision cases (rebind, request, could-not-run, off)
#   R8        every case reaches the end marker, no STRIKE line
#   R9        the final log line follows TRAIN_REBIND
#   R10       a mutant that always rebinds goes red on R1
# Run: HARNESS_TEST_SANDBOX=1 bash tests/rebase-train-caller-check.bh-6718-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
marked() { awk -v s="$1" -v e="$2" 'index($0,s){f=1} f{print} f && index($0,e){exit}' "$3"; }
TRAIN_SRC="$DIR/bin/rebase-train.sh"
PRURL=https://github.com/example-org/proj/pull/7

# ── R0: the slice ────────────────────────────────────────────────────────────
SLICE="$T/slice.sh"
marked '# >>> caller check (BH-6718)' '# <<< head-bound approval' "$TRAIN_SRC" > "$SLICE"
FINAL="$T/final.sh"
marked '# >>> train final line (BH-6718)' '# <<< train final line' "$TRAIN_SRC" > "$FINAL"
if [ -s "$SLICE" ] && grep -q '# <<< head-bound approval' "$SLICE"; then
  ok
  L_CK=$(grep -n 'caller-check.sh' "$SLICE" | head -1 | cut -d: -f1)
  L_PUSH=$(grep -n 'hold_push "$PROJECT"' "$SLICE" | head -1 | cut -d: -f1)
  L_RB=$(grep -n 'job_verdict_rebind "$PR"' "$SLICE" | head -1 | cut -d: -f1)
  { [ -n "$L_CK" ] && [ -n "$L_PUSH" ] && [ -n "$L_RB" ] && [ "$L_CK" -lt "$L_PUSH" ] && [ "$L_PUSH" -lt "$L_RB" ]; } \
    && ok || bad "R0: the slice must run caller-check.sh, then hold_push, then job_verdict_rebind (lines ck=$L_CK push=$L_PUSH rebind=$L_RB)"
else
  bad "R0: bin/rebase-train.sh has no '# >>> caller check (BH-6718)' block that runs through '# <<< head-bound approval'"
  echo "rebase-train-caller-check: $PASS passed, $FAIL failed"; exit 1
fi
[ -s "$FINAL" ] && ok || bad "R0: bin/rebase-train.sh has no '# >>> train final line (BH-6718)' block"

# ── the harness tree (shared, copied per case) ───────────────────────────────
H0="$T/h0"
mkdir -p "$H0/bin/lib"
scratch_install_closure bin/caller-check.sh "$H0" >/dev/null || bad "setup: closure install failed for bin/caller-check.sh"
cat > "$H0/bin/lib/hold-push.sh" <<'SH'
# stub hold_push: record argv, push HEAD to the bare origin
hold_push() {
  printf '%s\n' "$*" >> "$SINKDIR/push.txt"
  git -C "$3" push -q --force "$4" "$5:refs/heads/$6"
}
SH
cat > "$H0/bin/lead-verdict.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$SINKDIR/lv.txt"
exit "${STUB_LV_RC:-0}"
SH
chmod +x "$H0/bin/lead-verdict.sh"

# ── the git fixture ──────────────────────────────────────────────────────────
G() { git -c user.email=t@example.com -c user.name=tester -c commit.gpgsign=false "$@"; }
ORIGIN="$T/origin.git"
git init -q --bare -b main "$ORIGIN"
SEED="$T/seed"
git init -q -b main "$SEED"
mkdir -p "$SEED/bin/lib"
printf '#!/bin/bash\nold_name() { # old_name <a>\n  echo "$1"\n}\n' > "$SEED/bin/lib/x.sh"
printf '#!/bin/bash\n. bin/lib/x.sh\nold_name a\n' > "$SEED/bin/a.sh"
( cd "$SEED" && G add -A && G commit -qm base && git remote add origin "$ORIGIN" ) || bad "setup: seed commit failed"
BASE0=$(git -C "$SEED" rev-parse HEAD)

# PR sides
pr_rename()   { sed -i 's/^old_name() { # old_name <a>$/new_name() { # new_name <a>/' bin/lib/x.sh; sed -i 's/^old_name a$/new_name a/' bin/a.sh; }
pr_resig()    { sed -i 's/^old_name() { # old_name <a>$/old_name() { # old_name <a> <b>/' bin/lib/x.sh; }
pr_unrelated(){ mkdir -p docs; echo 'pr notes' > docs/pr.md; }
# main sides
main_caller() { printf '#!/bin/bash\n. bin/lib/x.sh\nold_name c\n' > bin/c.sh; }
main_unrelated(){ mkdir -p docs; echo 'main notes' > docs/main.md; }

# run_case <name> <pr-fn> <main-fn> [plan-text] [extra env...]
# Leaves: CH (harness), CS (sink dir), CW (worktree), OLD (pre-rebase head),
# NEW (rebased head), REC (build record), CLOG (log).
setup_case() {
  local c="$1" prfn="$2" mainfn="$3" plan="${4:-}"
  CH="$T/h-$c"; CS="$T/sink-$c"; CW="$T/wt-$c"; REC="$T/rec-$c"; CLOG="$T/log-$c"
  cp -a "$H0" "$CH"; mkdir -p "$CS" "$REC"; : > "$CS/lv.txt"; : > "$CS/rebind.txt"; : > "$CS/push.txt"
  ( cd "$SEED" && G checkout -q -B main "$BASE0" && "$mainfn" && G add -A && G commit -qm "main $c" \
      && git push -q --force origin main \
      && G checkout -q -B br7 "$BASE0" && "$prfn" && G add -A && G commit -qm "pr $c" \
      && git push -q --force origin br7 ) || bad "$c: fixture commit failed"
  git clone -q "$ORIGIN" "$CW" 2>/dev/null || bad "$c: clone failed"
  ( cd "$CW" && G checkout -q -B br7 origin/br7 && G rebase -q origin/main >/dev/null 2>&1 ) || bad "$c: the rebase failed"
  OLD=$(git -C "$CW" rev-parse origin/br7); NEW=$(git -C "$CW" rev-parse HEAD)
  echo "$OLD" > "$REC/reviewed-sha"
  printf 'VERDICT: APPROVE\n' > "$REC/review.md"
  [ -z "$plan" ] || printf '%s\n' "$plan" > "$REC/plan.md"
}
# run_slice <name> [slice] [env assignments...]
run_slice() {
  local c="$1" sl="${2:-$SLICE}"; shift 2 2>/dev/null || shift $#
  cp "$sl" "$CH/bin/train-slice.sh"
  ( cd "$CW" && env -i PATH="$PATH" HOME="$T" TMPDIR="$T" \
      H="$CH" HARNESS="$CH" D="$REC" PR="$PRURL" LOG="$CLOG" PROJECT=proj BASE=main BR=br7 \
      TRAIN_LEASE="$OLD" WT="$CW" SINKDIR="$CS" "$@" \
      bash -c '
        STAMP(){ echo "2026-10-14 00:00:00Z"; }
        job_verdict_rebind(){ printf "%s\t%s\n" "$1" "$2" >> "$SINKDIR/rebind.txt"; return 0; }
        set -euo pipefail
        . "$1"
        echo end > "$SINKDIR/end"' _ "$CH/bin/train-slice.sh" ) >/dev/null 2>&1
}
pushed()   { [ "$(git -C "$ORIGIN" rev-parse br7)" = "$NEW" ]; }
nlines()   { local n; n=$(grep -c . "$1" 2>/dev/null) || true; echo "${n:-0}"; }
common() { # common <name> : R8 + pushed
  [ -f "$CS/end" ] && ok || bad "$1 (R8): the set -e slice died before its end marker. Log: $(cat "$CLOG" 2>/dev/null)"
  grep -q STRIKE "$CLOG" 2>/dev/null && bad "$1 (R8): a STRIKE line was written" || ok
  pushed && ok || bad "$1: the rebased head must be pushed (origin br7=$(git -C "$ORIGIN" rev-parse br7), want $NEW)"
}
no_rebind() { # no_rebind <name>
  [ "$(nlines "$CS/rebind.txt")" = 0 ] && ok || bad "$1: no rebind expected, got: $(cat "$CS/rebind.txt")"
  [ "$(cat "$REC/reviewed-sha")" = "$OLD" ] && ok || bad "$1: reviewed-sha must stay the old head"
  grep -q "approval NOT rebound to $NEW (caller check)" "$CLOG" && ok || bad "$1: no 'approval NOT rebound' line. Log: $(cat "$CLOG")"
}
one_rebind() { # one_rebind <name>
  [ "$(cat "$CS/rebind.txt")" = "$PRURL"$'\t'"$NEW" ] && ok || bad "$1: exactly one rebind (PR, new sha) expected, got: $(cat "$CS/rebind.txt")"
  [ "$(cat "$REC/reviewed-sha")" = "$NEW" ] && ok || bad "$1: reviewed-sha must move to the rebased head"
}

# ── R1: the #4332 class — PR renames old_name, main adds a caller of it ─────
setup_case r1 pr_rename main_caller
run_slice r1
common R1; no_rebind R1
[ "$(nlines "$CS/lv.txt")" = 1 ] && ok || bad "R1: exactly one lead review request expected, got: $(cat "$CS/lv.txt")"
[ "$(cat "$CS/lv.txt")" = "request example-org/proj 7 $NEW --notes rebase-train: caller check found 1 callers (old_name)" ] \
  && ok || bad "R1: request argv wrong: $(cat "$CS/lv.txt")"
grep -q 'caller check: .*gone=1 on old_name' "$CLOG" && ok || bad "R1: the caller check line must carry gone=1 and old_name. Log: $(cat "$CLOG")"
grep -q "lead review requested on ${NEW:0:12}" "$CLOG" && ok || bad "R1: no 'lead review requested' line"
case "$(head -n 1 "$REC/callers-rebase-train.txt" 2>/dev/null)" in "CALLERS: "*) ok ;; *) bad "R1: callers-rebase-train.txt line 1 must start 'CALLERS: '" ;; esac
R1_CW="$CW"; R1_CH="$CH"; R1_REC="$REC"

# ── R2: no interface change ──────────────────────────────────────────────────
setup_case r2 pr_unrelated main_unrelated
run_slice r2
common R2; one_rebind R2
[ "$(nlines "$CS/lv.txt")" = 0 ] && ok || bad "R2: no request expected, got: $(cat "$CS/lv.txt")"
grep -q 'caller check: interfaces=0 .* the approval carries over' "$CLOG" && ok || bad "R2: no 'carries over' line. Log: $(cat "$CLOG")"
grep -q "approval rebound to the rebased head $NEW" "$CLOG" && ok || bad "R2: no 'approval rebound' line"

# ── R3: the CLI could not run (rc 3) ─────────────────────────────────────────
setup_case r3 pr_rename main_caller
cat > "$CH/bin/caller-check.sh" <<'SH'
#!/bin/bash
while [ $# -gt 0 ]; do [ "$1" = --out ] && OUT="$2"; shift; done
echo 'CALLERS: could-not-run stub' > "$OUT"; exit 3
SH
chmod +x "$CH/bin/caller-check.sh"
run_slice r3
common R3; no_rebind R3
[ "$(nlines "$CS/lv.txt")" = 0 ] && ok || bad "R3: no request expected on could-not-run"
grep -q 'caller check: could-not-run (rc=3' "$CLOG" && ok || bad "R3: no could-not-run line. Log: $(cat "$CLOG")"

# ── R3b: rc 0 with an unreadable CALLERS line ───────────────────────────────
setup_case r3b pr_rename main_caller
cat > "$CH/bin/caller-check.sh" <<'SH'
#!/bin/bash
while [ $# -gt 0 ]; do [ "$1" = --out ] && OUT="$2"; shift; done
echo garbage > "$OUT"; exit 0
SH
chmod +x "$CH/bin/caller-check.sh"
run_slice r3b
common R3b; no_rebind R3b
[ "$(nlines "$CS/lv.txt")" = 0 ] && ok || bad "R3b: no request expected"
grep -q 'caller check: could-not-run (rc=0' "$CLOG" && ok || bad "R3b: an unreadable summary must be could-not-run. Log: $(cat "$CLOG")"

# ── R3d: the CLI dies before it writes, over a clean file from an earlier run
setup_case r3d pr_rename main_caller
printf 'CALLERS: interfaces=0 ported=0 left=0 noreason=0 gone=0\n' > "$REC/callers-rebase-train.txt"
printf '#!/bin/bash\nexit 137\n' > "$CH/bin/caller-check.sh"
chmod +x "$CH/bin/caller-check.sh"
run_slice r3d
common R3d; no_rebind R3d
[ "$(nlines "$CS/lv.txt")" = 0 ] && ok || bad "R3d: no request expected"
grep -q 'caller check: could-not-run (rc=137' "$CLOG" && ok || bad "R3d: a non-zero rc must be could-not-run even over a clean stale file. Log: $(cat "$CLOG")"

# ── R3c: the lib is missing ──────────────────────────────────────────────────
setup_case r3c pr_rename main_caller
rm -f "$CH/bin/lib/caller-check.sh"
run_slice r3c
common R3c; no_rebind R3c
[ "$(nlines "$CS/lv.txt")" = 0 ] && ok || bad "R3c: no request expected"
grep -q 'caller check: could-not-run (the caller-check lib or CLI is missing' "$CLOG" && ok || bad "R3c: the missing lib must be named. Log: $(cat "$CLOG")"

# ── R4: CALLER_CHECK_MAX_LINES=0 is the old path ────────────────────────────
setup_case r4 pr_rename main_caller
run_slice r4 "$SLICE" CALLER_CHECK_MAX_LINES=0
common R4; one_rebind R4
[ "$(nlines "$CS/lv.txt")" = 0 ] && ok || bad "R4: no request expected when off"
grep -q 'caller check: off (CALLER_CHECK_MAX_LINES=0)' "$CLOG" && ok || bad "R4: no 'off' line. Log: $(cat "$CLOG")"
[ ! -e "$REC/callers-rebase-train.txt" ] && ok || bad "R4: off must not run the CLI"

# ── R5: a changed signature, a caller left alone with no reason ─────────────
PLAN5='# plan

## Changed symbols

- function `old_name`: signature changes'
setup_case r5 pr_resig main_unrelated "$PLAN5"
run_slice r5
common R5; no_rebind R5
grep -q 'caller check: .*noreason=1 gone=0' "$CLOG" && ok || bad "R5: expected noreason=1 gone=0. Log: $(cat "$CLOG")"
[ "$(nlines "$CS/lv.txt")" = 1 ] && ok || bad "R5: exactly one request expected, got: $(cat "$CS/lv.txt")"

# ── R6: rename with every caller ported ──────────────────────────────────────
setup_case r6 pr_rename main_unrelated
run_slice r6
common R6; one_rebind R6
[ "$(nlines "$CS/lv.txt")" = 0 ] && ok || bad "R6: no request expected"

# ── R6b: a left-alone caller WITH the plan's reason ─────────────────────────
PLAN6='# plan

## Changed symbols

- function `old_name` — signature changes; callers: left alone: a.sh keeps the old arity on purpose'
setup_case r6b pr_resig main_unrelated "$PLAN6"
run_slice r6b
common R6b; one_rebind R6b
grep -q 'caller check: .*left=1 noreason=0 gone=0' "$CLOG" && ok || bad "R6b: expected left=1 noreason=0 gone=0. Log: $(cat "$CLOG")"
[ "$(nlines "$CS/lv.txt")" = 0 ] && ok || bad "R6b: no request expected"

# ── R7: the lead request fails ───────────────────────────────────────────────
setup_case r7 pr_rename main_caller
run_slice r7 "$SLICE" STUB_LV_RC=1
common R7; no_rebind R7
[ "$(nlines "$CS/lv.txt")" = 1 ] && ok || bad "R7: one request attempt expected"
grep -q 'lead review request failed (rc=1)' "$CLOG" && ok || bad "R7: no 'request failed (rc=1)' line. Log: $(cat "$CLOG")"

# ── R9: the final line follows TRAIN_REBIND ──────────────────────────────────
for tr in 1 0 unset; do
  FL="$T/final-$tr.log"; : > "$FL"
  ( env -i PATH="$PATH" PROJECT=proj PR="$PRURL" LOG="$FL" TR="$tr" bash -c '
      STAMP(){ echo "2026-10-14 00:00:00Z"; }
      [ "$TR" = unset ] || TRAIN_REBIND=$TR
      set -euo pipefail; . "$1"' _ "$FINAL" ) >/dev/null 2>&1
  case "$tr" in
    0) grep -q 'pushed — NOT rebound, the sweep waits for a review of the new head' "$FL" && ! grep -q 'sweep takes it next tick' "$FL" \
         && ok || bad "R9: TRAIN_REBIND=0 must log the NOT rebound line only. Got: $(cat "$FL")" ;;
    *) grep -q 'pushed — sweep takes it next tick' "$FL" && ! grep -q 'NOT rebound' "$FL" \
         && ok || bad "R9: TRAIN_REBIND=$tr must log the sweep line only. Got: $(cat "$FL")" ;;
  esac
done

# ── R10: a mutant that always rebinds goes red on R1 ────────────────────────
MUT="$T/slice-mutant.sh"
sed 's/"${TRAIN_REBIND:-1}" = 1/1 = 1/' "$SLICE" > "$MUT"
cmp -s "$SLICE" "$MUT" && bad "R10: the mutation did not apply (no TRAIN_REBIND condition in the slice)" || ok
setup_case r10 pr_rename main_caller
run_slice r10 "$MUT"
[ "$(nlines "$CS/rebind.txt")" = 1 ] && ok || bad "R10: the always-rebind mutant must record a rebind on the R1 fixture (the R1 no-rebind check is what catches it)"

echo "rebase-train-caller-check: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
