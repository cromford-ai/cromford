#!/bin/bash
# tests/fixround-closure-lint.bh-5064-test.sh — BH-5064. A blocked-resolver fix
# round verified only npm typecheck + unit, so on cromford (no package.json)
# it pushed after checking nothing; a round on a PR whose suite hand-copies
# bin/lib files went straight back to the merge queue and sank the batch, as
# #4189 and #4680 did on 2026-10-06. bin/lib/fixround-closure-lint.sh runs the
# scratch-closure rules-pack component in the round, before the agent (findings
# join the brief) and after it (red = not pushed).
#
#   L1  frcl_scan on the REAL pack: a branch adding a hand-copying suite is red,
#       with the lint's file:line finding
#   L2  the same suite on scratch_install_closure is clean
#   L3  a tree with no pack, or no scratch-closure row, is skipped
#   L4  FIXROUND_CLOSURE_LINT=0 is off and runs nothing; unset and 7 are on
#   L5  the builder's pre-push gate (prepr_scan) refuses L1's branch with the
#       same file:line line
#   F1  the real bin/blocked-resolver.sh --fix-here: a round whose head is red
#       on the lint is NOT pushed, and fix-verify.txt says why
#   F2  the lint's findings are in the round's brief
#   F3  a round that fixes the suite is pushed
#   F4  a repo with no pack pushes, and its prompt is byte-identical to
#       origin/main's copy of the script
#   F5  FIXROUND_CLOSURE_LINT=0 pushes and never runs the pack
#   F6  a pack that could not run does not refuse the round
#   M1  mutants: CLOSURE_LINT dropped from the red grep fails F1; the brief
#       block deleted fails F2
# Run from anywhere: tests/fixround-closure-lint.bh-5064-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null || { echo "fixround-closure-lint: git is required"; exit 2; }
command -v jq >/dev/null || { echo "fixround-closure-lint: jq is required"; exit 2; }
unset RATCHET_BASE TI_BASE FIXROUND_CLOSURE_LINT
# Fixture text naming the lib dir is built from pieces so this suite's own
# lines never count against the lint it tests.
L='bin/''lib'
LIB=bin/lib/fixround-closure-lint.sh
[ -f "$DIR/$LIB" ] || bad "setup: $LIB is missing"

# ============================================================================
# L. the lib, on the real pack, in a clone of this checkout
# ============================================================================
R="$T/r"
git clone -q --shared "$DIR" "$R" || { echo "FAIL: clone"; exit 1; }
{ git -C "$DIR" diff --name-only HEAD; git -C "$DIR" ls-files -o --exclude-standard -- bin catalog prompts tests .github; } | sort -u \
  | while IFS= read -r f; do
      if [ -f "$DIR/$f" ]; then mkdir -p "$R/$(dirname "$f")" && cp -p "$DIR/$f" "$R/$f"
      else rm -f "$R/$f"; fi
    done
g() { git -C "$R" -c user.name=t -c user.email=t@t "$@"; }
g add -A >/dev/null 2>&1
g commit -q --allow-empty -m base || { echo "FAIL: base commit"; exit 1; }
g branch -f base HEAD
g update-ref refs/remotes/origin/main HEAD
branch() { # branch <name> <step> — a fresh branch off base, the step, one commit
  g checkout -q -B "$1" base || return 1
  "$2"
  g add -A >/dev/null 2>&1
  g commit -q -m "$1" || return 1
}
hand()   { printf '%s\n' '#!/bin/bash' "for f in a.sh b.sh; do cp \"\$DIR/$L/\$f\" \"\$T/$L/\"; done" > "$R/tests/new.bh-2-test.sh"; }
helper() { printf '%s\n' '#!/bin/bash' "scratch_install_closure bin/env-diff.sh \"\$T\" >/dev/null || exit 1" > "$R/tests/new.bh-2-test.sh"; }
# frcl <tree> <out-name> [env...] — frcl_scan from the clone's lib, a local
# runner (no harness root beside it), printing "<word> <rc>".
frcl() {
  local tree="$1" o="$2"; shift 2
  env HARNESS="$T/lh" H="$T/lh" HARNESS_ROOT_OVERRIDE="$T/no-harness" "$@" \
    bash -c '. "$0/'"$LIB"'" || exit 9; w=$(frcl_scan "$1" origin/main "$2"); rc=$?; echo "$w $rc"' \
    "$R" "$tree" "$T/$o"
}

branch hand hand || bad "L1: branch"
got=$(frcl "$R" o1)
[ "$got" = "red 1" ] && ok "L1: frcl_scan on a hand-copying suite is red rc 1" \
  || bad "L1: frcl_scan said '$got', want 'red 1' ($(cat "$T/o1/closure-lint.err" 2>/dev/null | tail -3))"
fl=$( (. "$R/$LIB"; frcl_findings "$T/o1") )
case "$fl" in *"tests/new.bh-2-test.sh:2:"*scratch_install_closure*) ok "L1: the finding names tests/new.bh-2-test.sh:2: and the fix" ;;
  *) bad "L1: frcl_findings has no tests/new.bh-2-test.sh:2: line [$fl]" ;; esac
case "$fl" in "scratch-closure: "*) bad "L1: frcl_findings kept the component prefix" ;; *) ok "L1: frcl_findings strips the prefix" ;; esac

branch helper helper || bad "L2: branch"
got=$(frcl "$R" o2)
[ "$got" = "clean 0" ] && ok "L2: the same suite on scratch_install_closure is clean rc 0" \
  || bad "L2: frcl_scan said '$got', want 'clean 0' ($(tail -3 "$T/o2/closure-lint.err" 2>/dev/null))"
[ -f "$T/o2/closure-lint.findings" ] && [ ! -s "$T/o2/closure-lint.findings" ] && ok "L2: the findings file is empty" \
  || bad "L2: the findings file is missing or not empty"

E="$T/empty"; git init -q "$E"; git -C "$E" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
git -C "$E" update-ref refs/remotes/origin/main HEAD
got=$(frcl "$E" o3)
[ "$got" = "skipped 3" ] && ok "L3: a tree without bin/rules-pack.sh is skipped rc 3" || bad "L3: no pack said '$got', want 'skipped 3'"
norow() { grep -v '^scratch-closure' "$R/catalog/rules-pack.tsv" > "$T/tsv" && cat "$T/tsv" > "$R/catalog/rules-pack.tsv"; }
branch norow norow || bad "L3: branch"
got=$(frcl "$R" o4)
[ "$got" = "skipped 3" ] && ok "L3: a catalog with no scratch-closure row is skipped rc 3" || bad "L3: no row said '$got', want 'skipped 3'"

g checkout -q hand
got=$(frcl "$R" o5 FIXROUND_CLOSURE_LINT=0)
[ "$got" = "off 4" ] && ok "L4: FIXROUND_CLOSURE_LINT=0 is off rc 4" || bad "L4: knob 0 said '$got', want 'off 4'"
[ ! -e "$T/o5" ] && ok "L4: off runs no pack (no out dir)" || bad "L4: off still created $T/o5"
on() { env HARNESS="$T/lh" H="$T/lh" "$@" bash -c '. "$0/'"$LIB"'" || exit 9; frcl_on' "$R"; echo $?; }
[ "$(on)" = 0 ] && ok "L4: an unset knob resolves on from the fragment default" || bad "L4: an unset knob is not on"
[ "$(on FIXROUND_CLOSURE_LINT=7)" = 0 ] && ok "L4: FIXROUND_CLOSURE_LINT=7 resolves to the default (on)" || bad "L4: knob 7 is not on"
[ "$(on FIXROUND_CLOSURE_LINT=0)" = 1 ] && ok "L4: frcl_on rc 1 at 0" || bad "L4: frcl_on is not off at 0"

# L5: the builder pre-push gate on the same branch.
( cd "$R" && env HARNESS="$T/lh" HARNESS_ROOT_OVERRIDE="$T/no-harness" \
    bash -c '. bin/lib/prepr-gate.sh || exit 9; prepr_scan "$0" origin/main "$1"' "$R" "$T/pp" ) >/dev/null 2>&1; prc=$?
[ "$prc" = 1 ] && ok "L5: prepr_scan returns 1 on the hand-copying branch" || bad "L5: prepr_scan rc $prc, want 1 ($(cat "$T/pp/prepr-scan.txt" 2>/dev/null | tr '\n' ' '))"
grep -q '^RULES-PACK scratch-closure: .*tests/new.bh-2-test.sh:2:' "$T/pp/prepr-findings.txt" 2>/dev/null \
  && ok "L5: prepr-findings.txt carries the RULES-PACK scratch-closure file:line" \
  || bad "L5: no RULES-PACK scratch-closure line in prepr-findings.txt [$(cat "$T/pp/prepr-findings.txt" 2>/dev/null)]"

# ============================================================================
# F. the real bin/blocked-resolver.sh --fix-here
# ============================================================================
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin"
# The scripts the round drives; the lane's lib closure comes with the first.
scratch_install_closure bin/blocked-resolver.sh "$H" >/dev/null || exit 1
for s in bin/fly-pool.sh bin/merge-sweep.sh bin/merge-conductor.sh bin/fleet-conf.sh bin/project-of.sh bin/box-for.sh "$LIB"; do
  scratch_install_closure "$s" "$H" >/dev/null || exit 1
done
fx_br_harness "$DIR" "$T" || exit 1
mkdir -p "$H/catalog/lanes.d" && cp "$DIR/catalog/lanes.d/_lib.fixround-closure-lint.json" "$H/catalog/lanes.d/" || exit 1
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
fx_br_ladder_git "$DIR" "$T" || exit 1

# The agent records its prompt and, per $T/agent-mode, commits in its cwd.
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s' "\$6" > "$T/prompt.txt"
case "\$(cat "$T/agent-mode" 2>/dev/null)" in
  unrelated) printf 'u\n' > u.txt; git add u.txt; git commit -q -m "fix round: unrelated" ;;
  fix) printf '%s\n' '#!/bin/bash' '# suite' 'scratch_install_closure bin/x.sh "\$T" >/dev/null || exit 1' > tests/x.bh-1-test.sh
       git add -A; git commit -q -m "fix round: scratch_install_closure" ;;
esac
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
git -C "$DIR" show origin/main:bin/blocked-resolver.sh > "$H/bin/blocked-resolver.main.sh" 2>/dev/null \
  || bad "setup: origin/main:bin/blocked-resolver.sh would not read"

# A branch of the fixture repo: f.txt, a suite, and (unless nopack) a STUB pack
# that records its argv and is red while the suite has a `cp` line, or exits
# 2 when $T/pack-mode says broken.
ROOTC=$(git -C "$SEED" rev-list --max-parents=0 main)
mkfr() { # mkfr <branch> hand|nopack
  git -C "$SEED" checkout -q -B "$1" "$ROOTC" || return 1
  printf '%s\n' "$1" > "$SEED/f.txt"
  mkdir -p "$SEED/tests"
  printf '%s\n' '#!/bin/bash' '# suite' "cp \"\$DIR/$L/a.sh\" \"\$T/$L/\"" > "$SEED/tests/x.bh-1-test.sh"
  if [ "$2" != nopack ]; then
    mkdir -p "$SEED/bin" "$SEED/catalog"
    cat > "$SEED/bin/rules-pack.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/pack.argv"
[ "\$(cat "$T/pack-mode" 2>/dev/null)" = broken ] && { echo "rules-pack: no base" >&2; exit 2; }
if grep -q '^cp ' tests/x.bh-1-test.sh 2>/dev/null; then
  echo "scratch-closure: FAIL: real (delta): tests/x.bh-1-test.sh:3: hand-copies $L files; use scratch_install_closure"
  exit 1
fi
exit 0
EOF
    chmod +x "$SEED/bin/rules-pack.sh"
    printf 'scratch-closure\tdelta\tsuite\ttests/scratch-closure-lint.bh-4552-test.sh\t-\thand copies\n' > "$SEED/catalog/rules-pack.tsv"
  fi
  git -C "$SEED" add -A && git -C "$SEED" commit -qm "work on $1" && git -C "$SEED" push -q -f origin "$1"
}
for b in f1 f3 f4 f5 f6 m1 m2; do mkfr "ticket/ts-$b" "$([ $b = f4 ] && echo nopack || echo hand)" || bad "setup: branch ts-$b"; done
git -C "$T/repos/tproj" fetch -q origin

PR91="https://github.com/o/tproj/pull/91"
LOGF="$H/logs/blocked-resolver.log"
FIXHERE() { # FIXHERE <script> [env...]
  local s="$1"; shift
  ( env HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" BOX_NAME=box-tproj "$@" \
      bash "$s" --fix-here tproj dqw-1-abc queue-dequeued "$PR91" - - < "$T/rec-in.json" ) >>"$T/run.log" 2>&1
}
RESET() { # RESET <branch> <agent-mode> [pack-mode]
  scratch_rm "$H/state/blocked-resolver"
  scratch_rm "$H/state/lane-gate"
  scratch_rm "$H/state/heartbeat"
  scratch_rm "$H/tmp/brfix"
  rm -f "$H/flags/all-off" "$H/flags/lane-off-"* "$H/flags/blocked-resolver-"* "$H/locks/blocked-resolver-cron.lock"
  : > "$LOGF"; : > "$H/logs/ALERTS.log"
  rm -f "$T/prompt.txt" "$T/pack.argv" "$T/pack-mode"
  git -C "$T/repos/tproj" worktree prune >/dev/null 2>&1
  git -C "$T/repos/tproj" for-each-ref --format='%(refname:short)' refs/heads/brfix/ \
    | while read -r b; do git -C "$T/repos/tproj" branch -D "$b" >/dev/null 2>&1; done
  printf '%s\n' "$1" > "$T/prbranch"; osha "$1" | tr -d '\n' > "$T/prhead"
  printf '%s\n' "$2" > "$T/agent-mode"
  [ $# -ge 3 ] && printf '%s\n' "$3" > "$T/pack-mode"
  printf 'Head-bound harness re-review: BLOCK. Finding: the route is unauthenticated.\n' > "$T/findings"
  jq -nc '{project:"tproj",rkey:"dqw-1-abc",fixrounds:0,rebuilds:0,mechanicals:0,outcome:"",attempts:[]}' > "$T/rec-in.json"
}
VERIFY() { cat "$H"/state/blocked-resolver/tproj/*.fix-verify.txt 2>/dev/null; }
# F1CHECK — rc 0 when the round left ticket/ts-<b> where it was ($1 = before sha).
F1CHECK() { [ "$(osha "$2")" = "$1" ]; }

# ---- F1 / F2 -----------------------------------------------------------------
RESET ticket/ts-f1 unrelated; before=$(osha ticket/ts-f1)
FIXHERE "$H/bin/blocked-resolver.sh"
[ -s "$T/prompt.txt" ] && ok "F1: the round reached the agent" || bad "F1: the agent never ran ($(tail -3 "$LOGF"))"
F1CHECK "$before" ticket/ts-f1 && ok "F1: a head red on the lint is NOT pushed (origin branch unchanged)" \
  || bad "F1: the round pushed a head red on the scratch-closure lint ($(grep -o 'FIX ROUND pushed.*' "$LOGF" | head -1))"
VERIFY | grep -qx 'CLOSURE_LINT_EXIT: 1' && ok "F1: fix-verify.txt has CLOSURE_LINT_EXIT: 1" \
  || bad "F1: fix-verify.txt has no CLOSURE_LINT_EXIT: 1 [$(VERIFY | tr '\n' '|')]"
VERIFY | grep -q 'tests/x.bh-1-test.sh:3: hand-copies' && ok "F1: fix-verify.txt names tests/x.bh-1-test.sh:3:" \
  || bad "F1: fix-verify.txt does not name the finding"
grep -q 'the scratch-closure lint is red .* not pushed' "$LOGF" && ok "F1: the log says the lint is why" \
  || bad "F1: no 'scratch-closure lint is red … not pushed' log line"
grep -q -- '--only scratch-closure' "$T/pack.argv" 2>/dev/null && grep -q -- '--base origin/main' "$T/pack.argv" \
  && ok "F1: the pack ran as --only scratch-closure --base origin/main" || bad "F1: pack argv [$(cat "$T/pack.argv" 2>/dev/null)]"
grep -qF 'THE SCRATCH-CLOSURE LINT IS RED ON THIS BRANCH' "$T/prompt.txt" 2>/dev/null \
  && grep -qF 'tests/x.bh-1-test.sh:3:' "$T/prompt.txt" && ok "F2: the brief carries the lint's findings" \
  || bad "F2: the prompt has no scratch-closure brief"

# ---- F3 ----------------------------------------------------------------------
RESET ticket/ts-f3 fix; before=$(osha ticket/ts-f3)
FIXHERE "$H/bin/blocked-resolver.sh"
[ "$(osha ticket/ts-f3)" != "$before" ] && ok "F3: a round that fixes the suite is pushed" \
  || bad "F3: the fixed round was not pushed ($(tail -3 "$LOGF"))"
VERIFY | grep -qx 'CLOSURE_LINT_EXIT: 0' && ok "F3: CLOSURE_LINT_EXIT: 0" || bad "F3: [$(VERIFY | tr '\n' '|')]"
grep -q 'FIX ROUND pushed' "$LOGF" && ok "F3: the log says FIX ROUND pushed" || bad "F3: no FIX ROUND pushed line"

# ---- F4 ----------------------------------------------------------------------
RESET ticket/ts-f4 none; before=$(osha ticket/ts-f4)
FIXHERE "$H/bin/blocked-resolver.sh"
cp "$T/prompt.txt" "$T/prompt-head.txt" 2>/dev/null || : > "$T/prompt-head.txt"
[ "$(osha ticket/ts-f4)" != "$before" ] && ok "F4: a repo with no pack pushes" || bad "F4: not pushed ($(tail -3 "$LOGF"))"
VERIFY | grep -q '^CLOSURE_LINT_EXIT: skipped' && ok "F4: CLOSURE_LINT_EXIT: skipped" || bad "F4: [$(VERIFY | tr '\n' '|')]"
# The same head for origin/main's copy: the prompt's live block names it.
git -C "$ORIGIN" update-ref refs/heads/ticket/ts-f4 "$before"
RESET ticket/ts-f4 none
FIXHERE "$H/bin/blocked-resolver.main.sh"
# TEST-CHANGE (BH-7042): BH-7042 adds ONE sentence to the fix-round prompt on
# purpose (do not merge origin/main unless the branch conflicts). The byte
# comparison below removes exactly that sentence from BOTH sides and compares
# the rest, so any other drift still fails. It holds before and after BH-7042
# is on main. tests/main-merge-need.bh-7042-test.sh asserts the sentence itself.
BH7042_SENTENCE=' The harness has already merged what it needs; do not merge origin/main again unless this branch still conflicts with main: the merge queue tests every PR on current main, and a clean merge only makes a new head that loses its review and restarts CI.'
bh7042_strip() { local s; s=$(cat "$1" 2>/dev/null; printf x); s=${s%x}; printf '%s' "${s//"$BH7042_SENTENCE"/}" > "$2"; }
bh7042_strip "$T/prompt-head.txt" "$T/prompt-head.cmp"; bh7042_strip "$T/prompt.txt" "$T/prompt-main.cmp"
[ -s "$T/prompt.txt" ] && cmp -s "$T/prompt-head.cmp" "$T/prompt-main.cmp" \
  && ok "F4: the prompt is byte-identical to origin/main's" \
  || bad "F4: the prompt differs from origin/main's ($(diff "$T/prompt-main.cmp" "$T/prompt-head.cmp" 2>&1 | head -5))"

# ---- F5 ----------------------------------------------------------------------
RESET ticket/ts-f5 none; before=$(osha ticket/ts-f5)
FIXHERE "$H/bin/blocked-resolver.sh" FIXROUND_CLOSURE_LINT=0
[ "$(osha ticket/ts-f5)" != "$before" ] && ok "F5: off pushes" || bad "F5: not pushed ($(tail -3 "$LOGF"))"
VERIFY | grep -qx 'CLOSURE_LINT_EXIT: off' && ok "F5: CLOSURE_LINT_EXIT: off" || bad "F5: [$(VERIFY | tr '\n' '|')]"
[ ! -e "$T/pack.argv" ] && ok "F5: the pack never ran" || bad "F5: the pack ran with the knob at 0"

# ---- F6 ----------------------------------------------------------------------
RESET ticket/ts-f6 none broken; before=$(osha ticket/ts-f6)
FIXHERE "$H/bin/blocked-resolver.sh"
[ "$(osha ticket/ts-f6)" != "$before" ] && ok "F6: could-not-run does not refuse the round" || bad "F6: not pushed ($(tail -3 "$LOGF"))"
VERIFY | grep -qx 'CLOSURE_LINT_EXIT: could-not-run' && ok "F6: CLOSURE_LINT_EXIT: could-not-run" || bad "F6: [$(VERIFY | tr '\n' '|')]"

# ---- M1 ----------------------------------------------------------------------
sed 's/(TYPECHECK|UNIT|CLOSURE_LINT)_EXIT/(TYPECHECK|UNIT)_EXIT/' "$H/bin/blocked-resolver.sh" > "$H/bin/blocked-resolver.mut1.sh"
if cmp -s "$H/bin/blocked-resolver.sh" "$H/bin/blocked-resolver.mut1.sh"; then
  bad "M1: the grep mutation changed nothing — CLOSURE_LINT is not in the red grep"
else
  RESET ticket/ts-m1 unrelated; before=$(osha ticket/ts-m1)
  FIXHERE "$H/bin/blocked-resolver.mut1.sh"
  F1CHECK "$before" ticket/ts-m1 && bad "M1: F1 still passes with CLOSURE_LINT out of the red grep" \
    || ok "M1: dropping CLOSURE_LINT from the red grep turns F1 red"
fi
sed '/# >>> br closure-lint brief/,/# <<< br closure-lint brief/d' "$H/bin/blocked-resolver.sh" > "$H/bin/blocked-resolver.mut2.sh"
if cmp -s "$H/bin/blocked-resolver.sh" "$H/bin/blocked-resolver.mut2.sh"; then
  bad "M1: the brief mutation changed nothing — no closure-lint brief block"
else
  RESET ticket/ts-m2 unrelated
  FIXHERE "$H/bin/blocked-resolver.mut2.sh"
  [ -s "$T/prompt.txt" ] || bad "M1: the brief mutant never reached the agent — the kill would be vacuous"
  grep -qF 'THE SCRATCH-CLOSURE LINT IS RED ON THIS BRANCH' "$T/prompt.txt" 2>/dev/null \
    && bad "M1: F2 still passes with the brief block deleted" || ok "M1: deleting the brief block turns F2 red"
fi

echo "fixround-closure-lint.bh-5064: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
