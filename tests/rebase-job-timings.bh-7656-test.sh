#!/bin/bash
# tests/rebase-job-timings.bh-7656-test.sh — the TIMINGS line of a pool rebase
# RESULT (BH-7656, T3).
#
# rebase_job_run (bin/lib/rebase-job.sh) ends every RESULT with
#   TIMINGS: setup=<s> merge=<s> gates=<s> push=<s>
# The step that decided the RESULT carries its time; a step never reached is
# `-`. rebase_setup_result (fly/builder-runner.sh) writes the same line with
# merge/gates/push `-`. The suite runs the REAL rebase_job_run on scratch git
# repos (bare origin + depth-1 machine clone, the bh-543 fixture) and asserts
# the SHAPE of the line, never the whole file (D56).
#
# Cases:
#   1. REBASED: TIMINGS is the LAST line, all four steps are numbers.
#      1b. a pinned REBASE_JOB_T0 of NOW-100 gives setup >= 100.
#   2. CONFLICT: merge a number, gates and push `-`.
#   3. GATE_RED typecheck: gates a number, push `-`.
#   4. setup failure: rebase_setup_result with REBASE_JOB_T0 set -> setup a
#      number; unset -> setup=-. A REBASE_SETUP_FAILED from inside the body
#      (empty branch) -> setup a number, the rest `-`.
#   5. the REAL mc_pool_rebase_apply reads a RESULT that ends in TIMINGS:
#      rc 0 for REBASED (job_verdict_rebind stubbed to 0), job file done, rc 0.
#
# MUTATIONS THAT TURN THIS SUITE RED (checked 2026-10-20):
#   - drop the `TIMINGS:` part of rebase_job_run's printf      -> case 1 red
#   - drop the `_rj_mark ""` after _rebase_job_body             -> cases 2/3 red
#
# Run from anywhere: bash tests/rebase-job-timings.bh-7656-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
command -v jq  >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read: the pin for case 1b and case 4.
NOW=$(date -u +%s)

SLUG=o/tproj
LIB="$DIR/bin/lib/rebase-job.sh"
TRE='^TIMINGS: setup=[0-9]+ merge=[0-9]+ gates=[0-9]+ push=[0-9]+$'

export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global protocol.file.allow always
git config --global advice.detachedHead false

mkdir -p "$T/fakebin" "$T/wt" "$T/h/logs" "$T/h/state"
# The machine's harness: rebase-job.sh's whole source closure (the conductor
# lib it sources for the resolver, hold-push.sh for the push).
scratch_install_closure bin/lib/rebase-job.sh "$T/h" >/dev/null || { echo "closure install failed"; exit 1; }
scratch_install_closure bin/lib/merge-conductor-lib.sh "$T/h" >/dev/null || { echo "closure install failed"; exit 1; }

# --- the faked binaries: npm runs the package.json script --------------------
cat > "$T/fakebin/npm" <<'NPMEOF'
#!/bin/bash
[ "${1:-}" = run ] || exit 0
S=$(jq -r --arg s "$2" '.scripts[$s] // ""' package.json 2>/dev/null)
[ -n "$S" ] || exit 1
bash -c "$S"
NPMEOF
# gh: the BH-2504 hold read answers "an unheld ticket", and nothing else.
. "$DIR/tests/lib/hold-fixture.sh" || exit 1
hold_fixture_gh "$T/fakebin" || exit 1
chmod +x "$T/fakebin/npm"
export PATH="$T/fakebin:$PATH"

export GATE_TC_FILE="$T/tc-rc" GATE_UNIT_FILE="$T/unit-rc"
export REBASE_WT_DIR="$T/wt"
gates() { printf '%s' "${1:-0}" > "$GATE_TC_FILE"; printf '%s' "${2:-0}" > "$GATE_UNIT_FILE"; }
gates 0 0

# --- the fixture: origin with main, branches off FORK, then main moves -------
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
mkdir -p "$T/seed/tools"
printf '#!/bin/sh\nexit "$(cat "$GATE_TC_FILE")"\n'   > "$T/seed/tools/tc.sh"
printf '#!/bin/sh\nexit "$(cat "$GATE_UNIT_FILE")"\n' > "$T/seed/tools/unit.sh"
cat > "$T/seed/package.json" <<'EOF'
{
  "name": "tproj",
  "version": "1.0.0",
  "scripts": {
    "typecheck": "sh tools/tc.sh",
    "test:unit": "sh tools/unit.sh"
  }
}
EOF
printf 'a1\na2\na3\n' > "$T/seed/a.txt"
git -C "$T/seed" add -A && git -C "$T/seed" commit -qm base1
git -C "$T/seed" push -q origin main
FORK=$(git -C "$T/seed" rev-parse HEAD)

mkbranch() { # mkbranch <name> <file> <content> -> the pushed head
  git -C "$T/seed" checkout -q -B "$1" "$FORK"
  printf '%s' "$3" > "$T/seed/$2"
  git -C "$T/seed" add -A && git -C "$T/seed" commit -qm "$1" >/dev/null
  git -C "$T/seed" push -q -f origin "$1"
  git -C "$T/seed" rev-parse HEAD
}
BR_CLEAN=ticket/bh-21; H_CLEAN=$(mkbranch "$BR_CLEAN" d.txt 'clean')
BR_PIN=ticket/bh-22;   H_PIN=$(mkbranch   "$BR_PIN"   e.txt 'pinned')
BR_CONF=ticket/bh-23;  H_CONF=$(mkbranch  "$BR_CONF"  a.txt 'a1-branch
a2
a3
')
BR_GATE=ticket/bh-24;  H_GATE=$(mkbranch  "$BR_GATE"  f.txt 'gate')

git -C "$T/seed" checkout -q main
printf 'a1-main\na2\na3\n' > "$T/seed/a.txt"
git -C "$T/seed" add -A && git -C "$T/seed" commit -qm main2 >/dev/null
git -C "$T/seed" push -q origin main

mkmachine() {
  rm -rf "$T/machine"
  git clone -q --depth 1 --single-branch "file://$T/origin.git" "$T/machine" 2>/dev/null
  mkdir -p "$T/machine/node_modules"; : > "$T/machine/node_modules/.keep"
}

RUNJOB() { # RUNJOB <branch> <head> — env REBASE_JOB_T0 / REBASE_JOB_URL pass through
  rm -f "$T/RESULT"
  ( # shellcheck source=/dev/null
    . "$LIB"
    rebase_job_run "$T/machine" "$SLUG" "$1" "$2" main "$T/RESULT" "$T/h" ) >/dev/null 2>&1
}
R1()    { head -1 "$T/RESULT" 2>/dev/null; }
LAST()  { tail -n 1 "$1" 2>/dev/null; }
TLINE() { grep '^TIMINGS:' "$1" 2>/dev/null; }
tfield() { # tfield <file> <name> -> the value of <name>= on the TIMINGS line
  TLINE "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"
}

# ============================================================================
# 1. REBASED: TIMINGS last, every step a number
# ============================================================================
gates 0 0; mkmachine
( unset REBASE_JOB_T0; export REBASE_JOB_URL="https://github.com/$SLUG/pull/21"
  RUNJOB "$BR_CLEAN" "$H_CLEAN" ); RC=$?
[ "$RC" = 0 ] && ok || bad "1: a clean rebase must return 0 (got $RC, RESULT '$(R1)')"
case "$(R1)" in REBASED\ *) ok ;; *) bad "1: first line must be REBASED (got '$(R1)')" ;; esac
LAST "$T/RESULT" | grep -Eq "$TRE" \
  && ok || bad "1: the LAST line must match $TRE (got '$(LAST "$T/RESULT")')"
[ "$(grep -c '^TIMINGS:' "$T/RESULT")" = 1 ] && ok || bad "1: exactly one TIMINGS line"
cp "$T/RESULT" "$T/RESULT.rebased"

# 1b. REBASE_JOB_T0 is honored: a pin 100 s in the past is in setup
gates 0 0; mkmachine
( export REBASE_JOB_T0=$((NOW - 100)); RUNJOB "$BR_PIN" "$H_PIN" ); RC=$?
[ "$RC" = 0 ] && ok || bad "1b: rc must be 0 (got $RC, RESULT '$(R1)')"
LAST "$T/RESULT" | grep -Eq "$TRE" && ok || bad "1b: TIMINGS shape (got '$(LAST "$T/RESULT")')"
S=$(tfield "$T/RESULT" setup)
[ -n "$S" ] && [ "$S" -ge 100 ] 2>/dev/null \
  && ok || bad "1b: REBASE_JOB_T0=NOW-100 must give setup >= 100 (got '$S')"
# a non-integer T0 falls back to the start of rebase_job_run (setup is small)
gates 0 0; mkmachine
git -C "$T/seed" checkout -q "$BR_PIN" && printf 'x\n' >> "$T/seed/e.txt" \
  && git -C "$T/seed" commit -qam pin2 && git -C "$T/seed" push -q -f origin "$BR_PIN"
H_PIN2=$(git -C "$T/seed" rev-parse HEAD)
( export REBASE_JOB_T0=notanumber; RUNJOB "$BR_PIN" "$H_PIN2" ); RC=$?
S=$(tfield "$T/RESULT" setup)
LAST "$T/RESULT" | grep -Eq "$TRE" && [ "$S" -lt 100 ] 2>/dev/null \
  && ok || bad "1b: a non-integer REBASE_JOB_T0 must fall back to the run start (got '$(LAST "$T/RESULT")', rc $RC)"

# ============================================================================
# 2. CONFLICT: merge decided; gates and push never reached
# ============================================================================
gates 0 0; mkmachine
( export REBASE_JOB_URL="https://github.com/$SLUG/pull/23"; RUNJOB "$BR_CONF" "$H_CONF" ); RC=$?
[ "$RC" = 1 ] && ok || bad "2: a conflict must return 1 (got $RC)"
case "$(R1)" in CONFLICT\ *) ok ;; *) bad "2: first line must be CONFLICT (got '$(R1)')" ;; esac
LAST "$T/RESULT" | grep -Eq '^TIMINGS: setup=[0-9]+ merge=[0-9]+ gates=- push=-$' \
  && ok || bad "2: CONFLICT must be 'setup=N merge=N gates=- push=-' as the last line (got '$(LAST "$T/RESULT")')"
cp "$T/RESULT" "$T/RESULT.conflict"

# ============================================================================
# 3. GATE_RED typecheck: gates decided; push never reached
# ============================================================================
gates 1 0; mkmachine
RUNJOB "$BR_GATE" "$H_GATE"; RC=$?
[ "$RC" = 1 ] && ok || bad "3: a red gate must return 1 (got $RC)"
[ "$(R1)" = "GATE_RED typecheck" ] && ok || bad "3: first line must be GATE_RED typecheck (got '$(R1)')"
LAST "$T/RESULT" | grep -Eq '^TIMINGS: setup=[0-9]+ merge=[0-9]+ gates=[0-9]+ push=-$' \
  && ok || bad "3: GATE_RED must be 'setup=N merge=N gates=N push=-' as the last line (got '$(LAST "$T/RESULT")')"

# ============================================================================
# 4. setup failure
# ============================================================================
FN=$(awk '/^rebase_setup_result\(\) \{/,/^\}/' "$DIR/fly/builder-runner.sh")
[ -n "$FN" ] && ok || bad "4: rebase_setup_result() must exist in fly/builder-runner.sh"
setup_run() { # setup_run <out> — env REBASE_JOB_T0 passes through
  ( log() { :; }; RESULT_FILE="$1"
    eval "$FN"
    rebase_setup_result "warm-up failed" "https://github.com/$SLUG/pull/21" "$H_CLEAN" "$BR_CLEAN" main ) >/dev/null 2>&1
}
( export REBASE_JOB_T0=$((NOW - 5)); setup_run "$T/RESULT.s1" )
LAST "$T/RESULT.s1" | grep -Eq '^TIMINGS: setup=[0-9]+ merge=- gates=- push=-$' \
  && ok || bad "4: rebase_setup_result with REBASE_JOB_T0 set must be 'setup=N merge=- gates=- push=-' (got '$(LAST "$T/RESULT.s1")')"
S=$(tfield "$T/RESULT.s1" setup)
[ -n "$S" ] && [ "$S" -ge 5 ] 2>/dev/null && ok || bad "4: setup must count from REBASE_JOB_T0 (got '$S')"
( unset REBASE_JOB_T0; setup_run "$T/RESULT.s2" )
LAST "$T/RESULT.s2" | grep -Eq '^TIMINGS: setup=- merge=- gates=- push=-$' \
  && ok || bad "4: rebase_setup_result with REBASE_JOB_T0 unset must be 'setup=-' (got '$(LAST "$T/RESULT.s2")')"
head -1 "$T/RESULT.s2" | grep -q '^REBASE_SETUP_FAILED warm-up failed$' \
  && ok || bad "4: line 1 must stay REBASE_SETUP_FAILED (got '$(head -1 "$T/RESULT.s2")')"

# from inside the body: a job with an empty branch
mkmachine
( export REBASE_JOB_T0=$((NOW - 3)); RUNJOB "" "$H_CLEAN" ); RC=$?
[ "$RC" = 1 ] && ok || bad "4: an empty branch must return 1 (got $RC)"
case "$(R1)" in REBASE_SETUP_FAILED\ *) ok ;; *) bad "4: first line must be REBASE_SETUP_FAILED (got '$(R1)')" ;; esac
LAST "$T/RESULT" | grep -Eq '^TIMINGS: setup=[0-9]+ merge=- gates=- push=-$' \
  && ok || bad "4: a body setup failure must be 'setup=N merge=- gates=- push=-' (got '$(LAST "$T/RESULT")')"

# ============================================================================
# 5. the REAL mc_pool_rebase_apply reads a RESULT that ends in TIMINGS
# ============================================================================
mkdir -p "$T/hub/logs" "$T/hub/state" "$T/hub/flags" "$T/hub/locks" "$T/hub/builds" "$T/hub/env"
scratch_install_closure bin/lib/merge-conductor-lib.sh "$T/hub" >/dev/null || { echo "closure install failed"; exit 1; }
: > "$T/hub/env/global.env"
apply_n() { # apply_n <num> <head> <result>
  ( export HARNESS="$T/hub" MC_REPOS="$T/repos"
    # shellcheck source=/dev/null
    . "$T/hub/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1; mc_init >/dev/null 2>&1
    job_verdict_rebind() { return 0; }
    mc_pool_rebase_apply tproj "RB-$1-${2:0:8}" "$3" >/dev/null 2>&1; arc=$?
    jf=$(mc_rb_file "$SLUG" "$1" "$2" 2>/dev/null)
    printf '%s %s %s\n' "$arc" "$(jq -r .status "$jf" 2>/dev/null)" "$(jq -r .rc "$jf" 2>/dev/null)" )
}
LAST "$T/RESULT.rebased" | grep -q '^TIMINGS:' && ok || bad "5: the fixture RESULT must end in TIMINGS"
OUT=$(apply_n 21 "$H_CLEAN" "$T/RESULT.rebased")
[ "$OUT" = "0 done 0" ] && ok \
  || bad "5: apply of a REBASED RESULT ending in TIMINGS must be rc 0, job done, job rc 0 (got '$OUT')"
OUT=$(apply_n 23 "$H_CONF" "$T/RESULT.conflict")
[ "$OUT" = "0 done 1" ] && ok \
  || bad "5: apply of a CONFLICT RESULT ending in TIMINGS must be rc 0, job done, job rc 1 (got '$OUT')"

echo "rebase-job-timings.bh-7656-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
