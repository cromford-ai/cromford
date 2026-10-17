#!/bin/bash
# tests/ci-local.bh-6897-test.sh — BH-6897: bin/ci-local.sh runs the steps of
# CI's lint jobs, read from the workflow, and the rules pack, on a tree.
#
#   L1  --list on the real repo names every step of both jobs in file order;
#       every catalog/ci-local-skip.d row names a real step and lists `skip`
#       with its reason; actions/checkout is `skip uses:`; the durations step
#       runs
#   L2  an expression the plan cannot evaluate is `unsupported`, rc 2
#   L3  `if: github.event_name == 'push'` is `skip`
#   L4  no PyYAML: rc 2, never clean
#   T   the step-state table on a fixture workflow: PASS, RED (green on the
#       base), PREEXISTING (red on the base), COULD-NOT-RUN (rc 2+ on head
#       and base), NOTE (continue-on-error),
#       SKIP, UNSUPPORTED, COULD-NOT-RUN (timeout), RED (command missing on
#       the base), RED (a step edits a tracked file), the CI env and no
#       caller HARNESS or GH_TOKEN in a step; run rc 0/1/2; no step matched is rc 2
#   C1  AT 1: a TOKEN= literal, a printf|head pipe and a new state/pool writer
#       are three named findings, rc 1
#   C2  the same clone with no extra commit is clean, rc 0
#   P   the pack is SKIP after a PASS step that runs bin/rules-pack.sh, and
#       still runs after a PREEXISTING one
#   X1  AT 2: a step appended to the lint job runs with no edit to ci-local
#   X2  a run leaves no temp dir, no extra worktree and no temporary ref
#   X3  the steps judge the committed HEAD on a fresh worktree; an uncommitted
#       edit in <tree> changes nothing (M3: steps run on <tree> fails it)
#   X4  a TERM mid-step stops the step and leaves nothing behind (M4: a trap
#       that does not stop the step fails it)
#   K1  cl_on / cl_budget defaults; CI_LOCAL_GATE=0 is off
#   T1c rc 1 here and rc 2 on the base is COULD-NOT-RUN, not PREEXISTING
#   M5  mutation (D9): a copy whose rc-2-on-both arm answers PREEXISTING
#       reads PREEXISTING rc 0, which T rejects
#   M1  mutation (D1): a copy of ci-local.sh whose RED branch answers PASS
#       fails C1's assertion
# Run from anywhere: tests/ci-local.bh-6897-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
CL="$DIR/bin/ci-local.sh"
PLAN="$DIR/bin/ci-local-plan.py"
LIB="$DIR/bin/lib/ci-local-verify.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"
export XDG_CACHE_HOME="$T/cache"
export GIT_AUTHOR_DATE="2026-10-15T12:00:00Z" GIT_COMMITTER_DATE="2026-10-15T12:00:00Z"
LINT_JOB="Syntax + shellcheck + config integrity"
DET_JOB="Test determinism lint"

[ -x "$CL" ] && [ -x "$PLAN" ] && [ -r "$LIB" ] && ok || bad "missing $CL, $PLAN or $LIB"

# state <out> <step> — the recorded state of a step in steps.tsv.
state() { awk -F'\t' -v s="$2" '$3 == s {print $4}' "$1/steps.tsv" 2>/dev/null; }

# A clone of this repo's committed HEAD: L1, C1, C2 and X1 run on it. (A run
# on "$DIR" itself would read to bin/test-impact.sh as a whole-tree suite.)
C="$T/clone"
git clone -q --local --no-hardlinks "$DIR" "$C" >/dev/null 2>&1 && ok || bad "setup: could not clone $DIR"
git -C "$C" config user.email t@example.com; git -C "$C" config user.name t; git -C "$C" config commit.gpgsign false
# A clone of a linked worktree path checks out the main checkout's HEAD, which
# moves: pin it to this checkout's own HEAD.
DHEAD=$(git -C "$DIR" rev-parse HEAD)
git -C "$C" fetch -q "$DIR" "$DHEAD" 2>/dev/null; git -C "$C" checkout -q --detach "$DHEAD" 2>/dev/null
CBASE=$(git -C "$C" rev-parse HEAD)
[ "$CBASE" = "$DHEAD" ] && ok || bad "setup: the clone is at $CBASE, not $DHEAD"

# ── L1: the real workflow ───────────────────────────────────────────────────
WF="$C/.github/workflows/harness-ci.yml"
"$CL" --tree "$C" --base "$CBASE" --list > "$T/l1.tsv" 2> "$T/l1.err"; RC=$?
[ "$RC" = 0 ] && ok || bad "L1: --list rc $RC: $(cat "$T/l1.err")"
# The named steps of the two jobs, read from the YAML text with awk, not with
# the plan's parser.
names_of() { # <job id>
  awk -v j="  $1:" '$0 == j {f = 1; next} f && /^  [A-Za-z0-9_-]+:$/ {f = 0}
    f && /^      - name: / {sub(/^      - name: /, ""); print}' "$WF"
}
{ names_of lint; names_of determinism; } > "$T/l1.want"
awk -F'\t' '$3 !~ /^uses / {print $3}' "$T/l1.tsv" > "$T/l1.got"
[ "$(grep -c . "$T/l1.want")" -ge 20 ] && ok || bad "L1: the awk read found only $(grep -c . "$T/l1.want") named steps"
diff "$T/l1.want" "$T/l1.got" > "$T/l1.diff" && ok || bad "L1: the plan's named steps differ from the workflow's: $(head -10 "$T/l1.diff")"
awk -F'\t' -v j="$LINT_JOB" '$2 == j' "$T/l1.tsv" | grep -q $'\tuses actions/checkout@v4\tskip\tuses: actions/checkout@v4$' && ok \
  || bad "L1: actions/checkout is not 'skip uses:' in the lint job"
grep -q $'\tthe suite durations fast-lints reads (BH-5518)\trun\t' "$T/l1.tsv" && ok || bad "L1: the durations step does not run"
grep -q $'\tTest determinism lint\tno clock or dice in the test suite (warn-only)\trun\t' "$T/l1.tsv" && ok \
  || bad "L1: the determinism job's step is not listed as run"
nskip=0
while IFS=$'\t' read -r job step why; do
  case "$job" in ''|\#*) continue ;; esac
  nskip=$((nskip + 1))
  grep -qxF "$(printf '%s\t%s\tskip\t%s' "$job" "$step" "$why")" <(cut -f2- "$T/l1.tsv") && ok \
    || bad "L1: skip row '$step' does not list as skip with its reason (a renamed step leaves a stale row)"
done < <(cat "$DIR"/catalog/ci-local-skip.d/*.tsv)
[ "$nskip" -ge 4 ] && ok || bad "L1: $nskip skip rows, want at least 4"

# ── a fixture repo: base has state.txt=green, head has state.txt=red ─────────
F="$T/fx"; mkdir -p "$F"
( cd "$F" && git init -q -b main && git config user.email t@example.com && git config user.name t \
    && git config commit.gpgsign false && echo green > state.txt && git add -A && git commit -qm base \
    && echo red > state.txt && printf 'exit 1\n' > new-tool.sh && git add -A && git commit -qm head ) >/dev/null 2>&1
FBASE=$(git -C "$F" rev-parse HEAD~1)
cat > "$T/wf.yml" <<'YML'
name: Fixture CI
on: pull_request
jobs:
  j:
    name: Fixture job
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: passes
        run: "true"
      - name: red here only
        run: grep -q green state.txt
      - name: red on both
        run: exit 1
      - name: cannot judge on both
        run: echo "no pinned binary"; exit 2
      - name: red here, base cannot judge
        run: if grep -q green state.txt; then echo "no pinned binary"; exit 2; else echo "a real finding"; exit 1; fi
      - name: runs the pack
        run: "true # bin/rules-pack.sh"
      - name: runs the pack, red on both
        run: "exit 1 # bin/rules-pack.sh"
      - name: report only
        continue-on-error: true
        run: exit 1
      - name: push only
        if: github.event_name == 'push'
        run: exit 1
      - name: unknown expression
        run: echo ${{ foo.bar }}
      - name: slow
        run: exec -a bh6897-slow-step tail -f /dev/null
      - name: new command
        run: bash ./new-tool.sh
      - name: edits a tracked file
        run: echo more >> state.txt
      - name: ci env
        env:
          WANT_BASE: ${{ github.base_ref }}
          WANT_EVENT: ${{ github.event_name }}
          WANT_TOKEN: ${{ github.token }}
        run: |
          test -z "$WANT_TOKEN" && test -z "${GH_TOKEN:-}"
          echo "base=$WANT_BASE event=$WANT_EVENT ci=$CI ghb=$GITHUB_BASE_REF harness=${HARNESS:-unset} sandbox=${HARNESS_TEST_SANDBOX:-}"
          test "$WANT_EVENT" = pull_request && test "$CI" = true && test -z "${HARNESS:-}"
          test -n "$WANT_BASE" && test "$WANT_BASE" = "$GITHUB_BASE_REF"
          git rev-parse --verify -q "origin/$WANT_BASE" >/dev/null
YML
# one <case> <budget> <step>... — run the fixture with only the named steps.
one() {
  local c="$1" b="$2"; shift 2
  local a=() s
  for s in "$@"; do a+=(--step "$s"); done
  HARNESS="$T/not-a-harness" GH_TOKEN=tok-fixture-bh6897 "$CL" --tree "$F" --base "$FBASE" --workflow "$T/wf.yml" --jobs "Fixture job" \
    --skip-rules-pack --budget "$b" --out "$T/$c" "${a[@]}" > "$T/$c.stdout" 2>&1
}

# ── L2 / L3 ─────────────────────────────────────────────────────────────────
"$CL" --tree "$F" --base "$FBASE" --workflow "$T/wf.yml" --jobs "Fixture job" --list > "$T/l2.tsv" 2>&1
grep -q $'\tunknown expression\tunsupported\tunknown foo.bar$' "$T/l2.tsv" && ok || bad "L2: $(grep unknown "$T/l2.tsv")"
grep -q $'\tpush only\tskip\tif: github.event_name == \'push\'$' "$T/l2.tsv" && ok || bad "L3: $(grep 'push only' "$T/l2.tsv")"
one l2 60 "unknown expression"; RC=$?
[ "$RC" = 2 ] && [ "$(state "$T/l2" "unknown expression")" = UNSUPPORTED ] && ok || bad "L2: rc $RC, state '$(state "$T/l2" "unknown expression")'"
one l3 60 "push only"; RC=$?
[ "$(state "$T/l3" "push only")" = SKIP ] && ok || bad "L3: state '$(state "$T/l3" "push only")'"
[ "$RC" = 2 ] && grep -q 'no step ran' "$T/l3/summary.txt" && ok || bad "L3: a run of only skipped steps is rc $RC, want 2 (never clean)"

# ── L4: no PyYAML ───────────────────────────────────────────────────────────
mkdir -p "$T/noyaml"; printf 'raise ImportError("hidden by the test")\n' > "$T/noyaml/yaml.py"
PYTHONPATH="$T/noyaml" "$CL" --tree "$F" --base "$FBASE" --workflow "$T/wf.yml" --jobs "Fixture job" --skip-rules-pack --budget 60 > "$T/l4.out" 2>&1; RC=$?
[ "$RC" = 2 ] && grep -q 'PyYAML' "$T/l4.out" && ok || bad "L4: rc $RC: $(cat "$T/l4.out")"
"$CL" --tree "$F" --base "$FBASE" --workflow "$T/wf.yml" --jobs "No such job" --skip-rules-pack --budget 60 > "$T/l4b.out" 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "L4: a job name not in the workflow is rc $RC, want 2"

# ── T: the step-state table ─────────────────────────────────────────────────
one t1 60 passes "red on both" "report only" "push only" "ci env"; RC=$?
[ "$(state "$T/t1" passes)" = PASS ] && ok || bad "T: passes is '$(state "$T/t1" passes)'"
[ "$(state "$T/t1" "red on both")" = PREEXISTING ] && ok || bad "T: red on both is '$(state "$T/t1" "red on both")'"
grep -q '^CI-LOCAL Fixture job / red on both: ' "$T/t1/preexisting.txt" && ok || bad "T: preexisting.txt lacks the step"
[ "$(state "$T/t1" "report only")" = NOTE ] && ok || bad "T: report only is '$(state "$T/t1" "report only")'"
[ "$(state "$T/t1" "ci env")" = PASS ] && ok || bad "T: the CI env step is '$(state "$T/t1" "ci env")': $(cat "$T"/t1/step-*.log | grep base=)"
[ "$RC" = 0 ] && grep -q '^ci-local: clean — 0 red, 2 pass, 1 note, 1 preexisting, 1 skipped, 0 could-not-run' "$T/t1/summary.txt" && ok \
  || bad "T: rc $RC summary '$(cat "$T/t1/summary.txt" 2>/dev/null)', want rc 0 clean"
[ ! -s "$T/t1/findings.txt" ] && ok || bad "T: a clean run wrote findings"

# rc 2+ on head and base is a step that could not judge (finding 3 of the
# review: shellcheck with no pinned binary read PREEXISTING and the run said
# clean). It is COULD-NOT-RUN, rc 2, never clean and never preexisting.
one t1b 60 passes "cannot judge on both"; RC=$?
[ "$(state "$T/t1b" "cannot judge on both")" = COULD-NOT-RUN ] && [ "$RC" = 2 ] && ok \
  || bad "T: rc 2 on both sides is '$(state "$T/t1b" "cannot judge on both")' rc $RC, want COULD-NOT-RUN rc 2"
grep -q 'cannot judge on both' "$T/t1b/preexisting.txt" && bad "T: a step that could not judge is listed preexisting" || ok
# Red here (rc 1) and rc 2 on the base: the base judged nothing, so the head's
# finding is not preexisting. COULD-NOT-RUN, rc 2 (lead review lr-7005).
one t1c 60 passes "red here, base cannot judge"; RC=$?
[ "$(state "$T/t1c" "red here, base cannot judge")" = COULD-NOT-RUN ] && [ "$RC" = 2 ] && ok \
  || bad "T: rc 1 here, rc 2 on the base is '$(state "$T/t1c" "red here, base cannot judge")' rc $RC, want COULD-NOT-RUN rc 2"
grep -q 'red here, base cannot judge' "$T/t1c/preexisting.txt" && bad "T: a finding over a base that could not judge is listed preexisting" || ok
# M5 (D9): a copy whose rc-2-on-both arm answers PREEXISTING fails T above.
sed 's/if \[ "\$rc" -ge 2 \] && \[ "\$b" -ge 2 \]; then/if false; then/' "$CL" > "$T/m5-ci-local.sh"
if cmp -s "$CL" "$T/m5-ci-local.sh"; then bad "M5: the mutation did not apply"
else
  mkdir -p "$T/m5/bin/lib" "$T/m5/catalog"; cp "$T/m5-ci-local.sh" "$T/m5/bin/ci-local.sh"; chmod +x "$T/m5/bin/ci-local.sh"
  cp "$PLAN" "$T/m5/bin/"; cp "$LIB" "$T/m5/bin/lib/"; cp -r "$DIR/catalog/ci-local-skip.d" "$T/m5/catalog/"
  "$T/m5/bin/ci-local.sh" --tree "$F" --base "$FBASE" --workflow "$T/wf.yml" --jobs "Fixture job" --skip-rules-pack --budget 60 \
    --out "$T/m5o" --step "cannot judge on both" > /dev/null 2>&1; RC=$?
  [ "$(state "$T/m5o" "cannot judge on both")" = PREEXISTING ] && [ "$RC" = 0 ] && ok \
    || bad "M5: the mutant did not read PREEXISTING rc 0 ('$(state "$T/m5o" "cannot judge on both")' rc $RC), so T cannot catch it"
fi

# P: a step that runs bin/rules-pack.sh itself and ended PASS (CI's "fast
# always-lints") makes the trailing pack run SKIP (review finding 4: the pack
# ran twice). A PREEXISTING one did not judge the pack, so it still runs.
# Their own TMPDIR: the real pack's temp files are not ci-local's (X2).
mkdir -p "$T/pktmp"
TMPDIR="$T/pktmp" "$CL" --tree "$F" --base "$FBASE" --workflow "$T/wf.yml" --jobs "Fixture job" --budget 60 --out "$T/pk1" \
  --step "runs the pack" > "$T/pk1.stdout" 2>&1
[ "$(state "$T/pk1" bin/rules-pack.sh)" = SKIP ] && grep -q "SKIP rules-pack / bin/rules-pack.sh (0s) — the step Fixture job / runs the pack ran it" "$T/pk1.stdout" && ok \
  || bad "P: the pack after a PASS step that ran it is '$(state "$T/pk1" bin/rules-pack.sh)': $(tail -3 "$T/pk1.stdout")"
TMPDIR="$T/pktmp" "$CL" --tree "$F" --base "$FBASE" --workflow "$T/wf.yml" --jobs "Fixture job" --budget 60 --out "$T/pk2" \
  --step "runs the pack, red on both" > "$T/pk2.stdout" 2>&1
[ "$(state "$T/pk2" "runs the pack, red on both")" = PREEXISTING ] && [ -n "$(state "$T/pk2" bin/rules-pack.sh)" ] \
  && [ "$(state "$T/pk2" bin/rules-pack.sh)" != SKIP ] && ok \
  || bad "P: the pack after a PREEXISTING step is '$(state "$T/pk2" bin/rules-pack.sh)', want it run: $(tail -3 "$T/pk2.stdout")"

one t2 60 passes "red here only"; RC=$?
[ "$(state "$T/t2" "red here only")" = RED ] && [ "$RC" = 1 ] && ok || bad "T: red here only is '$(state "$T/t2" "red here only")' rc $RC"
grep -qx 'CI-LOCAL Fixture job / red here only: .*' "$T/t2/findings.txt" && ok || bad "T: findings.txt: $(cat "$T/t2/findings.txt")"
grep -q '^ci-local: RED Fixture job / red here only' "$T/t2.stdout" && ok || bad "T: no stdout line for the RED step"
tail -n 1 "$T/t2.stdout" | grep -q '^ci-local: red — 1 red, 1 pass' && ok || bad "T: last stdout line '$(tail -n 1 "$T/t2.stdout")'"

one t3 2 slow; RC=$?
[ "$(state "$T/t3" slow)" = COULD-NOT-RUN ] && [ "$RC" = 2 ] && ok || bad "T: slow is '$(state "$T/t3" slow)' rc $RC, want COULD-NOT-RUN rc 2"
one t3b 2 slow "new command"; RC=$?
[ "$(state "$T/t3b" "new command")" = COULD-NOT-RUN ] && ok || bad "T: a step after the budget is spent is '$(state "$T/t3b" "new command")'"

one t4 60 "new command"; RC=$?
[ "$(state "$T/t4" "new command")" = RED ] && [ "$RC" = 1 ] && grep -q 'missing on the base' "$T/t4.stdout" && ok \
  || bad "T: a red step whose command is new is '$(state "$T/t4" "new command")' rc $RC"

one t5 60 "edits a tracked file"; RC=$?
[ "$(state "$T/t5" "edits a tracked file")" = RED ] && [ "$RC" = 1 ] && grep -q 'changed tracked files: state.txt' "$T/t5/findings.txt" && ok \
  || bad "T: a step that edits a tracked file is '$(state "$T/t5" "edits a tracked file")' rc $RC: $(cat "$T/t5/findings.txt")"
git -C "$F" checkout -q -- state.txt

one t6 60 "no such step"; RC=$?
[ "$RC" = 2 ] && grep -q 'no step matched' "$T/t6.stdout" && ok || bad "T: no step matched is rc $RC, want 2"
"$CL" --tree "$F" --base no-such-ref-bh6897 --workflow "$T/wf.yml" --jobs "Fixture job" --skip-rules-pack --budget 60 > "$T/t7.out" 2>&1; RC=$?
[ "$RC" = 2 ] && grep -q 'does not resolve' "$T/t7.out" && ok || bad "T: an unresolvable base is rc $RC, want 2"

# ── X3: the steps judge the committed HEAD, never <tree>'s working files ────
echo green > "$F/state.txt"
one x3 60 "red here only"; RC=$?
[ "$(state "$T/x3" "red here only")" = RED ] && [ "$RC" = 1 ] && grep -q 'uncommitted tracked changes; the steps judge the committed HEAD' "$T/x3.stdout" && ok \
  || bad "X3: an uncommitted edit changed the verdict: '$(state "$T/x3" "red here only")' rc $RC"
[ "$(cat "$F/state.txt")" = green ] && ok || bad "X3: the run touched <tree>'s working file"
# M3 (D1): the same run with steps pointed at <tree> instead goes green.
mkdir -p "$T/mutx/bin/lib" "$T/mutx/catalog"; cp "$PLAN" "$T/mutx/bin/"; cp "$LIB" "$T/mutx/bin/lib/"; cp -r "$DIR/catalog/ci-local-skip.d" "$T/mutx/catalog/"
sed 's/^  run_step "\$HEAD_WT" "\$n" "\$OUT\/step-\$n.log"; rc=\$?$/  run_step "$TREE" "$n" "$OUT\/step-$n.log"; rc=$?/' "$CL" > "$T/mutx/bin/ci-local.sh"; chmod +x "$T/mutx/bin/ci-local.sh"
cmp -s "$CL" "$T/mutx/bin/ci-local.sh" && bad "M3: the mutation did not apply" || ok
"$T/mutx/bin/ci-local.sh" --tree "$F" --base "$FBASE" --workflow "$T/wf.yml" --jobs "Fixture job" --skip-rules-pack --budget 60 \
  --out "$T/m3" --step "red here only" > "$T/m3.stdout" 2>&1
[ "$(state "$T/m3" "red here only")" = RED ] && bad "M3: X3 still passes with the steps run on <tree>" || ok
git -C "$F" checkout -q -- state.txt

# ── X4: a TERM mid-step stops the step and cleans up ────────────────────────
timeout -s TERM 3 "$CL" --tree "$F" --base "$FBASE" --workflow "$T/wf.yml" --jobs "Fixture job" --skip-rules-pack \
  --budget 60 --out "$T/x4" --step slow > "$T/x4.stdout" 2>&1; RC=$?
[ "$RC" = 124 ] && ok || bad "X4: the run under timeout exited $RC, want 124"
pgrep -f '^bh6897-slow-step' >/dev/null && bad "X4: the step outlived the run" || ok
# M4 (D1): a TERM trap that does not stop the step leaves it running.
sed "s/^trap '\[ -n \"\$CHILD\" \] \&\& kill \"\$CHILD\" 2>\/dev\/null; exit 2' INT TERM$/trap 'exit 2' INT TERM/" "$CL" > "$T/mutx/bin/ci-local.sh"
cmp -s "$CL" "$T/mutx/bin/ci-local.sh" && bad "M4: the mutation did not apply" || ok
timeout -s TERM 3 "$T/mutx/bin/ci-local.sh" --tree "$F" --base "$FBASE" --workflow "$T/wf.yml" --jobs "Fixture job" --skip-rules-pack \
  --budget 60 --out "$T/m4" --step slow > "$T/m4.stdout" 2>&1
pgrep -f '^bh6897-slow-step' >/dev/null && ok || bad "M4: X4 still passes with the step left running"
pkill -f '^bh6897-slow-step' 2>/dev/null
git -C "$F" worktree prune

# ── X2: nothing left behind ─────────────────────────────────────────────────
[ -z "$(ls -A "$TMPDIR" 2>/dev/null)" ] && ok || bad "X2: temp dirs left: $(ls "$TMPDIR")"
[ "$(git -C "$F" worktree list | grep -c .)" = 1 ] && ok || bad "X2: worktrees left: $(git -C "$F" worktree list)"
[ -z "$(git -C "$F" for-each-ref refs/remotes/origin/)" ] && ok || bad "X2: refs left: $(git -C "$F" for-each-ref refs/remotes/origin/)"

# ── C1 / C2 / X1: the clone ─────────────────────────────────────────────────
STEP_SP="new scripts do not write row-backed state paths"
PACKARGS="--only fixture-hygiene,determinism --runner local"

# C2 first, on the clone as cloned.
HARNESS_TEST_SANDBOX=1 "$CL" --tree "$C" --base "$CBASE" --step "$STEP_SP" --pack-args "$PACKARGS" --budget 600 --out "$T/c2" > "$T/c2.stdout" 2>&1; RC=$?
[ "$RC" = 0 ] && grep -q '^ci-local: clean' "$T/c2/summary.txt" && ok || bad "C2: rc $RC: $(tail -5 "$T/c2.stdout")"

HEX=$(printf 'a1%.0s' $(seq 1 32))
PIPE='|'
mkdir -p "$C/tests"
printf '#!/bin/bash\n# a realistic-looking literal\nTOKEN=%s\n' "$HEX" > "$C/tests/x-bh6897-test.sh"
# race-sigpipe-echo is scoped to test files (catalog/determinism-lint.conf).
printf '#!/bin/bash\nset -o pipefail\na=$(seq 1 5)\nprintf %s "$a" %s head -1\n' "'%s\\n'" "$PIPE" > "$C/tests/y-bh6897-test.sh"
printf '#!/bin/bash\nH="${HARNESS:-/tmp}"\necho x > "$H/state/pool/x"\n' > "$C/bin/y-bh6897.sh"
chmod +x "$C/bin/y-bh6897.sh" "$C/tests/x-bh6897-test.sh" "$C/tests/y-bh6897-test.sh"
git -C "$C" add -A && git -C "$C" commit -qm "bh6897 fixture: three CI reds" >/dev/null 2>&1
HARNESS_TEST_SANDBOX=1 "$CL" --tree "$C" --base "$CBASE" --step "$STEP_SP" --pack-args "$PACKARGS" --budget 600 --out "$T/c1" > "$T/c1.stdout" 2>&1; RC=$?
c1_assert() { # <out> <rc> <label>
  local o="$1" rc="$2" l="$3" bad1=""
  [ "$rc" = 1 ] || bad1="rc $rc"
  # Three sources and nothing else (fixture-hygiene adds its own count line).
  grep -v -e '^CI-LOCAL rules-pack: fixture-hygiene: ' -e '^CI-LOCAL rules-pack: determinism: ' \
    -e "^CI-LOCAL $LINT_JOB / $STEP_SP: " "$o/findings.txt" 2>/dev/null | grep -q . && bad1="$bad1 other-findings"
  grep -q '^CI-LOCAL rules-pack: fixture-hygiene: ' "$o/findings.txt" 2>/dev/null || bad1="$bad1 no-fixture-hygiene"
  grep -q '^CI-LOCAL rules-pack: determinism: tests/y-bh6897-test.sh:4: race-sigpipe-echo' "$o/findings.txt" 2>/dev/null || bad1="$bad1 no-race-sigpipe"
  grep -q "^CI-LOCAL $LINT_JOB / $STEP_SP: STATE-PATHS-GUARD: bin/y-bh6897.sh:3: writes state/pool " "$o/findings.txt" 2>/dev/null || bad1="$bad1 no-state-paths"
  [ -z "$bad1" ] || { echo "$l: $bad1"; cat "$o/findings.txt" 2>/dev/null; return 1; }
}
c1_assert "$T/c1" "$RC" C1 > "$T/c1.why" && ok || bad "C1: $(cat "$T/c1.why") :: $(tail -5 "$T/c1.stdout")"

# X1: one step appended to the lint job of a copy of the real workflow, red
# only on this clone's head commit. ci-local.sh and its plan are not edited.
sed -n '1,/^  determinism:$/p' "$C/.github/workflows/harness-ci.yml" | sed '$d' > "$T/x1.yml"
cat >> "$T/x1.yml" <<'YML'
      - name: bh6897 extra step
        run: echo extra-ran; test ! -f tests/y-bh6897-test.sh

YML
sed -n '/^  determinism:$/,$p' "$C/.github/workflows/harness-ci.yml" >> "$T/x1.yml"
git -C "$DIR" diff --quiet HEAD -- bin/ci-local.sh bin/ci-local-plan.py 2>/dev/null; before_rc=$?
"$CL" --tree "$C" --base "$CBASE" --workflow "$T/x1.yml" --step 'bh6897 extra step' --skip-rules-pack --budget 120 --out "$T/x1" > "$T/x1.stdout" 2>&1; RC=$?
[ "$RC" = 1 ] && [ "$(state "$T/x1" 'bh6897 extra step')" = RED ] && ok || bad "X1: rc $RC state '$(state "$T/x1" 'bh6897 extra step')': $(cat "$T/x1.stdout")"
grep -q '^extra-ran$' "$T"/x1/step-*.log 2>/dev/null && ok || bad "X1: the appended step did not run"
grep -q "^CI-LOCAL $LINT_JOB / bh6897 extra step: " "$T/x1/findings.txt" && ok || bad "X1: no finding names the new step"
git -C "$DIR" diff --quiet HEAD -- bin/ci-local.sh bin/ci-local-plan.py 2>/dev/null; after_rc=$?
[ "$before_rc" = "$after_rc" ] && ok || bad "X1: the run edited ci-local.sh or its plan"
[ "$(git -C "$C" worktree list | grep -c .)" = 1 ] && ok || bad "X2: the clone keeps a worktree: $(git -C "$C" worktree list)"
[ -z "$(git -C "$C" for-each-ref 'refs/remotes/origin/ci-local-base-*')" ] && ok || bad "X2: the clone keeps a temporary ref"

# ── M1/M2: mutation (D1) — break each verdict branch, C1's assertion fails ──
# The mutant runs from the clone's own bin/, beside the clone's real pack.
mutant() { # <name> <sed-expr>
  mkdir -p "$C/bin/lib" "$C/catalog"
  cp "$PLAN" "$C/bin/"; cp "$LIB" "$C/bin/lib/"; scratch_rm "$C/catalog/ci-local-skip.d"; cp -r "$DIR/catalog/ci-local-skip.d" "$C/catalog/"
  sed "$2" "$CL" > "$C/bin/ci-local.sh"; chmod +x "$C/bin/ci-local.sh"
  cmp -s "$CL" "$C/bin/ci-local.sh" && { bad "$1: the mutation did not apply"; return; }
  HARNESS_TEST_SANDBOX=1 "$C/bin/ci-local.sh" --tree "$C" --base "$CBASE" --step "$STEP_SP" --pack-args "$PACKARGS" \
    --budget 600 --out "$T/$1" > "$T/$1.stdout" 2>&1
  c1_assert "$T/$1" "$?" "$1" > /dev/null && bad "$1: C1's assertion still passes with the branch mutated" || ok
}
# M1: a step green on the base and red here is recorded PASS, with no finding.
mutant m1 's/^    0) n_red=\$((n_red + 1)); record "\$n" "\$job" "\$step" RED /    0) n_pass=$((n_pass + 1)); record "$n" "$job" "$step" PASS /; s/^       printf .CI-LOCAL %s \/ %s: %s\\n. "\$job" "\$step" "\$why" >> "\$OUT\/findings.txt" ;;$/       ;;/'
# M2: the pack's red lines are not findings.
mutant m2 's/^    elif \[ "\$prc" = 1 \] && grep -q/    elif false \&\& grep -q/'

# ── K1: the knobs ───────────────────────────────────────────────────────────
K=$(env -u CI_LOCAL_GATE -u CI_LOCAL_BUDGET_S bash -c '. "$1"; cl_on && echo on || echo off; cl_budget' _ "$LIB")
[ "$K" = $'on\n900' ] && ok || bad "K1: defaults '$K', want on/900"
K=$(CI_LOCAL_GATE=0 bash -c '. "$1"; cl_on && echo on || echo off' _ "$LIB")
[ "$K" = off ] && ok || bad "K1: CI_LOCAL_GATE=0 answers '$K'"
K=$(CI_LOCAL_BUDGET_S=5 bash -c '. "$1"; cl_budget' _ "$LIB")
[ "$K" = 900 ] && ok || bad "K1: an out-of-range budget answers '$K', want the default 900"
K=$(CI_LOCAL_GATE=0 bash -c '. "$1"; w=$(cl_run "$2" "$3" HEAD "$4"); echo "$w rc=$?"' _ "$LIB" "$CL" "$F" "$T/k1")
[ "$K" = "off rc=4" ] && ok || bad "K1: cl_run with the knob off answers '$K'"

echo "ci-local.bh-6897: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
