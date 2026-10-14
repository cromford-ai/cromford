#!/bin/bash
# tests/prequeue-gate-learned-suites.bh-6335-test.sh — BH-6335: the pre-queue
# gate runs the suites that failed merge-queue batches lately and the
# whole-tree lints, runs its suites under the trace of `Tests cannot touch a
# real harness`, and a verdict counts only on a main at most K commits old.
#
# THE DEFECT THIS PINS. On 2026-10-12, 106 of 148 merge-queue batches failed a
# check. A PR broke a whole-tree suite (flag-callsites-pool G1 on #5920, four
# batches), or its suite wrote to the live harness (#6039, the trace check), or
# a reused green verdict was many commits behind main. The pre-queue gate ran
# only the impact selection, bare, and reused any verdict under 30 minutes old.
#
#   P1   a raw `[ -f flags/fly-pool-... ]` in bin/pool-cap.sh: the selector
#        picks flag-callsites-pool (since BH-6688, a bin/ row); the real catalog
#        row also does, and goes red
#   P2   25 recorded batch failures for one suite, 3 for another: the list, the
#        conductor hook and the workflow carry only the first to the gate
#   P3a  the REAL gate, --runner traced: a suite whose argument redirects into
#        the live harness is red and named in --trace-hits
#   P3b  the workflow with trace=1: `red ... why=trace`, parsed back by the
#        conductor; once with a stub gate, once with the REAL gate
#   P3c  adversarial negatives: a printed redirect and a temp-dir write: green
#   P4   an ejection voids an older green (needs PR #6182's PQ_MIN_AT; skipped
#        with a note until that code is on this tree)
#   P5a-g  the reuse loop counts a non-red verdict only K commits behind main
#   G1-G4  bin/test-impact-gate.sh --also, --runner traced, --trace-hits
#   W1-W5  the workflow inputs and the conductor's dispatch argv
#   K1   the knobs are registered with their defaults
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prequeue-gate-learned-suites.bh-6335-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { [[ "$1" == *"$2"* ]]; }
for c in jq git python3 flock; do command -v "$c" >/dev/null || { echo "$c missing — skipping"; exit 0; }; done
[ -f "$DIR/bin/lib/mc-prequeue.d/dispatch.sh" ] && [ -f "$DIR/bin/lib/mc-prequeue.d/learned.sh" ] && [ -f "$DIR/bin/test-impact-gate.sh" ] || exit 1   # impact: bin/lib/mc-prequeue.d/learned.sh bin/lib/mc-prequeue.d/dispatch.sh bin/test-impact-gate.sh .github/workflows/prequeue-gate.yml

# pq_resolve ages a verdict against the wall clock, so the fixtures do too.
NOW=$(date +%s)
CATALOG="$DIR/catalog/prequeue-invariants.tsv"
WF="$DIR/.github/workflows/prequeue-gate.yml"
DISPATCH_LIB="$DIR/bin/lib/mc-prequeue.d/dispatch.sh"
LEARNED="$DIR/bin/prequeue-learned.sh"
export GIT_AUTHOR_DATE="@$NOW +0000" GIT_COMMITTER_DATE="@$NOW +0000"
export TEST_IMPACT_DURATIONS_FILE="$T/state/test-impact-durations.tsv"
# The live harness path, assembled at run time so no text scan reads it here.
LIVE="/root/""harness/logs"

# ============================================================================
# P1. A raw flag test in bin/pool-cap.sh is caught by the real catalog row.
# ============================================================================
C="$T/copy"; mkdir -p "$C"
git -C "$DIR" ls-files -z --cached --others --exclude-standard | tar -C "$DIR" --null -T - -cf - 2>/dev/null | tar -C "$C" -xf -
awk -F'\t' '$1 == "flag-callsites-pool"' "$CATALOG" > "$T/p1.tsv"
p1run() {
  ( cd "$C" && env -u PQ_MAIN -u RATCHET_BASE bash bin/prequeue-invariants.sh --run --catalog "$T/p1.tsv" --out "$T/$1.d" ) > "$T/$1.out" 2>&1
  echo $? > "$T/$1.rc"
}
p1run p1c
[ "$(cat "$T/p1c.rc")" = 0 ] && ok || bad "P1c: the clean copy is green on the flag-callsites-pool row (rc $(cat "$T/p1c.rc"): $(tail -3 "$T/p1c.out"))"
sed -i '/^n=\$(cat "\$HARNESS\/flags\/fly-pool-\$P"/a [ -f "$HARNESS/flags/fly-pool-$P" ] \&\& :' "$C/bin/pool-cap.sh"
grep -qF '[ -f "$HARNESS/flags/fly-pool-$P" ] && :' "$C/bin/pool-cap.sh" || bad "P1 setup: the raw flag line is in the copy's bin/pool-cap.sh"
printf 'bin/pool-cap.sh\n' > "$T/p1.changed"
( cd "$C" && bin/test-impact.sh select --changed "$T/p1.changed" --map-only ) > "$T/p1a.out" 2>/dev/null
# TEST-CHANGE (BH-6688 fix round): this case pinned the selector's gap, and
# BH-6688 closed it. flag-callsites-pool greps bin/ cron fly from the checkout,
# and bin/test-impact.sh ti_treedir_rows now gives it a bin/ row, so the
# selector picks it for bin/pool-cap.sh. The invariant row below stays a guard.
grep -qxF tests/flag-callsites-pool.bh-5635-test.sh "$T/p1a.out" && ok \
  || bad "P1a: the selector picks flag-callsites-pool for bin/pool-cap.sh (BH-6688: a whole-bin scanner has a bin/ row): $(head -3 "$T/p1a.out" | tr '\n' ' ')"
p1run p1b
[ "$(cat "$T/p1b.rc")" = 1 ] && ok || bad "P1b: the real catalog row runs flag-callsites-pool and goes red (rc $(cat "$T/p1b.rc"): $(tail -3 "$T/p1b.out"))"
[ "$(cat "$T/p1b.d/failed.txt" 2>/dev/null)" = flag-callsites-pool ] && ok || bad "P1b: failed.txt names flag-callsites-pool (got '$(cat "$T/p1b.d/failed.txt" 2>/dev/null)')"

# ============================================================================
# The REAL gate in a scratch repo (P3a, P3c, G1-G4).
# ============================================================================
R="$T/repo"; mkdir -p "$R/tests"
for s in bin/test-impact-gate.sh bin/test-impact.sh bin/test-suite-run.sh bin/test-trace-safety.sh; do
  scratch_install_closure "$s" "$R" >/dev/null || bad "setup: install $s"
done
printf '#!/bin/bash\necho "fast: 1 passed, 0 failed"\n' > "$R/tests/fast.sh"
printf '#!/bin/bash\necho "FAIL: on purpose"\nexit 1\n' > "$R/tests/red.sh"
# The child exits before its redirect runs: nothing is written, the tracer
# still reads the literal redirect in the argument handed to bash -c.
printf '#!/bin/bash\nbash -c %q\necho "leak: 1 passed, 0 failed"\n' "exit 0; echo x >> $LIVE/bh-6335.log" > "$R/tests/leak.sh"
printf '#!/bin/bash\necho %q\n' "cat >$LIVE/x" > "$R/tests/echo-only.sh"
printf '#!/bin/bash\nd=$(mktemp -d)\nbash -c "echo x > $d/x"\nrm -rf "$d"\n' > "$R/tests/tmp-write.sh"
# The real selector answers the whole corpus when the map picks nothing, so
# every fixture suite would run in every case. A stub selector prints the rows
# in $SEL (none by default): each case names exactly what the map picked.
cat > "$R/bin/test-impact.sh" <<'SH'
#!/bin/bash
cat "$SEL" 2>/dev/null
echo "${SEL_REASON:-impact: stub selection}" >&2
SH
export SEL="$T/sel"; : > "$SEL"
gr() { git -C "$R" -c user.email=t@example.com -c user.name=t "$@"; }
gr init -q; gr add -A; gr commit -qm base; RB=$(git -C "$R" rev-parse HEAD)
echo notes > "$R/notes.txt"; gr add -A; gr commit -qm notes
gate() { ( cd "$R" && bash bin/test-impact-gate.sh --base "$RB" --cap 80 --budget 600 "$@" ); }
also() { printf '%s\n' "$@" > "$T/also.txt"; }

# G2. An empty map selection: rc 2 alone, and the --also suite runs with it.
gate --runner local > "$T/g2n.out" 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "G2 setup: an empty selection is rc 2 without --also (rc $RC: $(tail -2 "$T/g2n.out"))"
also tests/fast.sh
gate --runner local --also "$T/also.txt" > "$T/g2.out" 2>&1; RC=$?
[ "$RC" = 0 ] && grep -q 'impact-gate: done tests/fast.sh rc=0' "$T/g2.out" && ok \
  || bad "G2: an empty selection plus one --also suite runs it, rc 0 (rc $RC: $(tail -3 "$T/g2.out"))"
SEL_REASON="impact: 0 of 4 suites (full: cannot diff no-such-ref)" gate --runner local --also "$T/also.txt" > "$T/g2b.out" 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "G2: a range that cannot be diffed is still rc 2 with --also (rc $RC)"

# G1. Front of the list, the reason, the drops. The map picked red.sh too.
printf 'tests/fast.sh\n' > "$T/g1.skip"
printf 'tests/red.sh\tself\ttests/red.sh\n' > "$SEL"
also tests/red.sh tests/fast.sh "tests/../x.sh" tests/no-such.sh tests/red.sh
gate --runner plan --also "$T/also.txt" --skip-suites "$T/g1.skip" --list "$T/g1.list" > "$T/g1.out" 2>&1; RC=$?
[ "$RC" = 0 ] && [ "$(head -n1 "$T/g1.list" 2>/dev/null)" = tests/red.sh ] && ok \
  || bad "G1: the learned suite is first in --list (rc $RC, list '$(tr '\n' ' ' < "$T/g1.list" 2>/dev/null)': $(tail -3 "$T/g1.out"))"
[ "$(grep -cxF tests/red.sh "$T/g1.list" 2>/dev/null)" = 1 ] && ok || bad "G1: a suite named twice runs once"
grep -qE '^plan: tests/red\.sh +learned \(failed merge-queue batches\); self tests/red\.sh$' "$T/g1.out" && ok \
  || bad "G1: the plan line gives the learned reason, then the map's ($(grep 'plan:' "$T/g1.out"))"
: > "$SEL"
[ "$(grep -c 'impact-gate: also: dropped tests/fast.sh (in --skip-suites)' "$T/g1.out")" = 1 ] && ok || bad "G1: one drop line for a --skip-suites suite"
grep -q 'impact-gate: also: dropped tests/../x.sh' "$T/g1.out" && ok || bad "G1: a path with .. is dropped"
grep -q 'impact-gate: also: dropped tests/no-such.sh (not in this checkout)' "$T/g1.out" && ok || bad "G1: a suite the checkout lacks is dropped"
grep -q 'running up to 1 of 1 selected suites (cap 80 + 1 learned suite(s) outside it' "$T/g1.out" && ok || bad "G1: the learned suite counts in N ($(grep 'running up to' "$T/g1.out"))"

# G3. traced: a clean suite, and a red suite with no hit.
also tests/fast.sh
gate --runner traced --also "$T/also.txt" --trace-hits "$T/g3a.hits" --failed "$T/g3a.failed" > "$T/g3a.out" 2>&1; RC=$?
[ "$RC" = 0 ] && [ -e "$T/g3a.hits" ] && [ ! -s "$T/g3a.hits" ] && ok || bad "G3: a clean suite under the trace is rc 0, no hit (rc $RC, hits '$(cat "$T/g3a.hits" 2>/dev/null)': $(tail -3 "$T/g3a.out"))"
also tests/red.sh
gate --runner traced --also "$T/also.txt" --trace-hits "$T/g3b.hits" --failed "$T/g3b.failed" > "$T/g3b.out" 2>&1; RC=$?
[ "$RC" = 1 ] && [ "$(cat "$T/g3b.failed" 2>/dev/null)" = tests/red.sh ] && [ ! -s "$T/g3b.hits" ] && ok \
  || bad "G3: a red suite with no hit is rc 1, failed, no hit (rc $RC, failed '$(cat "$T/g3b.failed" 2>/dev/null)', hits '$(cat "$T/g3b.hits" 2>/dev/null)')"
echo stale > "$T/g3c.hits"
gate --runner local --also "$T/also.txt" --trace-hits "$T/g3c.hits" > /dev/null 2>&1
[ -e "$T/g3c.hits" ] && [ ! -s "$T/g3c.hits" ] && ok || bad "G3: --trace-hits is emptied at start and stays empty with another runner"

# P3a. A redirect into the live harness: red, named in --trace-hits.
also tests/leak.sh
gate --runner traced --also "$T/also.txt" --trace-hits "$T/p3a.hits" --failed "$T/p3a.failed" > "$T/p3a.out" 2>&1; RC=$?
[ "$RC" = 1 ] && ok || bad "P3a: a trace hit is rc 1 (rc $RC: $(tail -5 "$T/p3a.out"))"
[ "$(cat "$T/p3a.hits" 2>/dev/null)" = tests/leak.sh ] && ok || bad "P3a: --trace-hits names the suite (got '$(cat "$T/p3a.hits" 2>/dev/null)')"
[ ! -e "$LIVE/bh-6335.log" ] && ok || bad "P3a: the fixture wrote nothing into the live harness"

# P3c. Adversarial negatives: no hit, green.
also tests/echo-only.sh tests/tmp-write.sh
gate --runner traced --also "$T/also.txt" --trace-hits "$T/p3c.hits" > "$T/p3c.out" 2>&1; RC=$?
[ "$RC" = 0 ] && [ ! -s "$T/p3c.hits" ] && ok || bad "P3c: a printed redirect and a temp-dir write are no hit (rc $RC, hits '$(cat "$T/p3c.hits" 2>/dev/null)': $(tail -4 "$T/p3c.out"))"

# G4. A tracer that cannot run (rc 2) is could-not-run, rc 125.
R4="$T/repo4"; cp -a "$R" "$R4"
printf '#!/bin/bash\necho "trace: refused" >&2\nexit 2\n' > "$R4/bin/test-trace-safety.sh"
also tests/fast.sh
( cd "$R4" && bash bin/test-impact-gate.sh --base "$RB" --cap 80 --budget 600 --runner traced --also "$T/also.txt" ) > "$T/g4.out" 2>&1; RC=$?
[ "$RC" = 125 ] && ok || bad "G4: a tracer rc 2 is gate rc 125 (rc $RC: $(tail -3 "$T/g4.out"))"
gate --runner bogus > "$T/g4b.out" 2>&1; RC=$?
[ "$RC" = 2 ] && grep -q 'plan or traced' "$T/g4b.out" && ok || bad "G4: an unknown runner names traced in its refusal (rc $RC)"

# ============================================================================
# The workflow's real verdict step, dry (the BH-4548 W shape).
# ============================================================================
python3 - "$WF" "$T/w" <<'PY' || bad "W: the workflow must parse and carry its verdict step"
import sys, yaml, os
wf = yaml.safe_load(open(sys.argv[1]))
os.makedirs(sys.argv[2], exist_ok=True)
step = [s for s in wf["jobs"]["gate"]["steps"] if s.get("id") == "verdict"][0]
open(sys.argv[2] + "/run.sh", "w").write(step["run"])
PY
# mkorigin <name> — a bare origin with main and pull/41/head (a head adding y.txt)
# pushed from the seed dir $T/<name>; prints "<main> <head>".
mkorigin() {
  local s="$T/$1" m h
  git -C "$s" init -q; git -C "$s" -c user.email=t@example.com -c user.name=t add -A
  git -C "$s" -c user.email=t@example.com -c user.name=t commit -qm base; m=$(git -C "$s" rev-parse HEAD)
  echo y > "$s/y.txt"; git -C "$s" add -A; git -C "$s" -c user.email=t@example.com -c user.name=t commit -qm head; h=$(git -C "$s" rev-parse HEAD)
  git init -q --bare "$T/$1.git"; git -C "$s" push -q "$T/$1.git" "$m:refs/heads/main" "$h:refs/pull/41/head"
  echo "$m $h"
}
# Seed 1: a stub gate that records its argv, copies its --also file and writes
# the --failed and --trace-hits files it is told to.
mkdir -p "$T/stub/bin" "$T/stub/tests"
scratch_install_closure bin/test-suite-run.sh "$T/stub" >/dev/null || bad "W setup: install test-suite-run"
cat > "$T/stub/bin/test-impact-gate.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" > "$GATE_ARGV"
f=""; a=""; h=""
while [ $# -gt 0 ]; do case "$1" in --failed) f="$2" ;; --also) a="$2" ;; --trace-hits) h="$2" ;; esac; shift; done
[ -n "$a" ] && cp "$a" "$GATE_ARGV.also"
[ -n "$f" ] && printf '%s' "${STUB_FAILED:-}" > "$f"
[ -n "$h" ] && printf '%s' "${STUB_HITS:-}" > "$h"
exit "${STUB_RC:-0}"
SH
printf '#!/bin/bash\necho "fast: 1 passed, 0 failed"\n' > "$T/stub/tests/fast.sh"
read -r MS HS <<<"$(mkorigin stub)"
# Seed 2: the REAL gate, selector, runner and tracer, and the leaking suite.
mkdir -p "$T/real/tests"
for s in bin/test-impact-gate.sh bin/test-impact.sh bin/test-suite-run.sh bin/test-trace-safety.sh; do
  scratch_install_closure "$s" "$T/real" >/dev/null || bad "W setup: install $s"
done
cp "$R/tests/leak.sh" "$R/tests/fast.sh" "$T/real/tests/"
read -r MR HR <<<"$(mkorigin real)"
# Seed 3: the same, without the leaking suite (the real selector runs every suite).
mkdir -p "$T/real2/tests"
for s in bin/test-impact-gate.sh bin/test-impact.sh bin/test-suite-run.sh bin/test-trace-safety.sh; do
  scratch_install_closure "$s" "$T/real2" >/dev/null || bad "W setup: install $s"
done
cp "$R/tests/fast.sh" "$T/real2/tests/"
read -r MR2 HR2 <<<"$(mkorigin real2)"
# dry <case> <origin> <main> <head> [VAR=value ...] — the verdict step in a fresh clone at <main>.
dry() {
  local c="$1" o="$2" m="$3" h="$4"; shift 4
  git clone -q "$T/$o.git" "$T/wd-$c" 2>/dev/null; git -C "$T/wd-$c" checkout -q "$m"
  mkdir -p "$T/rt-$c"
  ( cd "$T/wd-$c" && env PQ_PR=41 PQ_HEAD="$h" PQ_MAIN="$m" PQ_SUITES_IN="" PQ_INVARIANTS_IN="" PQ_LEARNED_IN="" PQ_TRACE_IN="" \
      RUNNER_TEMP="$T/rt-$c" GATE_ARGV="$T/gate-$c" "$@" bash "$T/w/run.sh" ) > "$T/out-$c" 2>&1
  echo "rc=$?" >> "$T/out-$c"
}
verdict() {
  awk '/^::stop-commands::/ { tok = substr($0, 18); off = 1; next }
       off && $0 == "::" tok "::" { off = 0; next }
       !off { print }' "$T/out-$1" | sed -n 's/^::notice title=prequeue-verdict:://p'
}
parse() { ( . "$DISPATCH_LIB" >/dev/null 2>&1; pq_parse_verdict "$@" ); }

# W1. Both new inputs empty: today's exact gate argv.
dry w1 stub "$MS" "$HS"
[ "$(verdict w1)" = "green main=$MS head=$HS suites=" ] && ok || bad "W1: green (got '$(verdict w1)')"
[ "$(cat "$T/gate-w1" 2>/dev/null)" = "--base $MS --head HEAD --runner local --failed $T/rt-w1/failed" ] && ok \
  || bad "W1: today's exact gate argv (got '$(cat "$T/gate-w1" 2>/dev/null)')"
# P2c. learned reaches the gate as an --also file, one suite per line.
dry p2c stub "$MS" "$HS" PQ_LEARNED_IN=tests/a.sh,tests/mc/b.sh
[ "$(cat "$T/gate-p2c" 2>/dev/null)" = "--base $MS --head HEAD --runner local --failed $T/rt-p2c/failed --also $T/rt-p2c/learned" ] && ok \
  || bad "P2c: the gate argv ends --also <rt>/learned (got '$(cat "$T/gate-p2c" 2>/dev/null)')"
[ "$(cat "$T/gate-p2c.also" 2>/dev/null)" = "tests/a.sh${IFS:2:1}tests/mc/b.sh" ] && ok || bad "P2c: the --also file holds one suite per line (got '$(cat "$T/gate-p2c.also" 2>/dev/null)')"
# W2/W3. Malformed inputs: could-not-run, the gate never ran.
dry w2 stub "$MS" "$HS" "PQ_LEARNED_IN=tests/a.sh;rm"
[ "$(verdict w2)" = "could-not-run main=$MS head=$HS suites= why=bad-learned" ] && [ ! -e "$T/gate-w2" ] && ok || bad "W2: a bad learned list is bad-learned (got '$(verdict w2)')"
dry w2b stub "$MS" "$HS" "PQ_LEARNED_IN=tests/..sh"
[ "$(verdict w2b)" = "could-not-run main=$MS head=$HS suites= why=bad-learned" ] && ok || bad "W2: a learned path with .. is bad-learned (got '$(verdict w2b)')"
dry w3 stub "$MS" "$HS" PQ_TRACE_IN=yes
[ "$(verdict w3)" = "could-not-run main=$MS head=$HS suites= why=bad-trace" ] && [ ! -e "$T/gate-w3" ] && ok || bad "W3: a bad trace input is bad-trace (got '$(verdict w3)')"
# W4. Named suites: the named branch, no --also, no traced.
dry w4 stub "$MS" "$HS" PQ_SUITES_IN=tests/fast.sh PQ_LEARNED_IN=tests/a.sh PQ_TRACE_IN=1
[ "$(verdict w4)" = "green main=$MS head=$HS suites=" ] && [ ! -e "$T/gate-w4" ] && ok || bad "W4: named suites run as today (got '$(verdict w4)', gate argv '$(cat "$T/gate-w4" 2>/dev/null)')"
# P3b (stub gate). trace=1: --runner traced last, the hit suites first, why=trace.
dry p3s stub "$MS" "$HS" PQ_TRACE_IN=1 STUB_RC=1 STUB_HITS=tests/leak.sh STUB_FAILED=tests/other.sh$'\n'tests/leak.sh
[ "$(cat "$T/gate-p3s" 2>/dev/null)" = "--base $MS --head HEAD --runner local --failed $T/rt-p3s/failed --trace-hits $T/rt-p3s/hits --runner traced" ] && ok \
  || bad "P3b: the gate argv ends --trace-hits <rt>/hits --runner traced (got '$(cat "$T/gate-p3s" 2>/dev/null)')"
[ "$(verdict p3s)" = "red main=$MS head=$HS suites=tests/leak.sh,tests/other.sh why=trace" ] && ok || bad "P3b: red why=trace, the hit first (got '$(verdict p3s)')"
[ "$(parse "$(verdict p3s)" "$HS" "$MS")" = "red tests/leak.sh,tests/other.sh trace" ] && ok || bad "P3b: the conductor parses it (got '$(parse "$(verdict p3s)" "$HS" "$MS")')"
dry p3n stub "$MS" "$HS" PQ_TRACE_IN=1 STUB_RC=1 STUB_FAILED=tests/other.sh
[ "$(verdict p3n)" = "red main=$MS head=$HS suites=tests/other.sh" ] && ok || bad "P3b: a red with no hit carries no why=trace (got '$(verdict p3n)')"
# P3b (REAL gate). The leaking suite, learned and traced: red why=trace.
dry p3r real "$MR" "$HR" PQ_TRACE_IN=1 PQ_LEARNED_IN=tests/leak.sh
[ "$(verdict p3r)" = "red main=$MR head=$HR suites=tests/leak.sh why=trace" ] && ok \
  || bad "P3b: the real gate under the workflow names the leak, why=trace (got '$(verdict p3r)': $(tail -6 "$T/out-p3r"))"
dry p3g real2 "$MR2" "$HR2" PQ_TRACE_IN=1 PQ_LEARNED_IN=tests/fast.sh
[ "$(verdict p3g)" = "green main=$MR2 head=$HR2 suites=" ] && ok || bad "P3b: a clean learned suite under the trace is green (got '$(verdict p3g)')"

# ============================================================================
# The conductor: source the real tracer and hooks with stubbed reads.
# ============================================================================
PS_=example-org/demo-os; PH=$(printf 'a%.0s' $(seq 40)); M2=$(printf 'c%.0s' $(seq 40)); M1=$(printf 'd%.0s' $(seq 40))
# pq <name> <body> — $T/pq-<name>/{gh.argv,compare.calls,log}; COMPARE / COMPARE_RC answer the compare read.
pq() {
  ( export MC_STATE_DIR="$T/pq-$1/state" MC_H="${PQ_H:-$T/pq-$1/h}" GH_ARGV="$T/pq-$1/gh.argv" W="$T/pq-$1"
    mkdir -p "$MC_STATE_DIR" "$MC_H/locks" "$W/bin"
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$GH_ARGV"\n' > "$W/bin/gh"; chmod +x "$W/bin/gh"
    PATH="$W/bin:$PATH"
    mc_rest_var() {
      case "$*" in
        *"/commits/"*) printf -v "$1" '{"sha":"%s"}' "$M2" ;;
        *"/compare/"*) echo "$*" >> "$W/compare.calls"; [ "${COMPARE_RC:-0}" = 0 ] || return "$COMPARE_RC"; printf -v "$1" '%s' "${COMPARE:-}" ;;
        *) printf -v "$1" '{}' ;;
      esac; return 0; }
    mc_log() { printf '%s\n' "$*" >> "$W/log"; }; mc_use_token() { :; }; mc_safe_name() { printf '%s' "${1//[^A-Za-z0-9._-]/_}"; }
    . "$DIR/bin/lib/mc-prequeue.sh" >/dev/null 2>&1 || exit 9
    PQ_MAIN=""; PQ_SUITES=""; PQ_WHY=""; PQ_PATH=""
    eval "$2" ) > "$T/pq-$1.out" 2>&1
}
word() { tail -n1 "$T/pq-$1.out"; }
ndisp() { cat "$T/pq-$1/gh.argv" 2>/dev/null | grep -c '^workflow run prequeue-gate.yml'; }
ncmp() { cat "$T/pq-$1/compare.calls" 2>/dev/null | grep -c .; }
# A green for (head, M1) read a minute ago, then pq_resolve on current main M2.
RESOLVE='pq_resolve "$PS_" 7 u "$PH" "$M2" "$(pq_key "$PS_" 7 "$PH" "$M2")"'
SEED='pq_cache_put "$(pq_key "$PS_" 7 "$PH" "$M1")" green $(( $(date +%s) - 60 )) 55 ""'
export PS_ PH M1 M2 DIR

# P5a. 4 behind, K=3: dispatch for M2 and hold; a second ask does not dispatch again.
COMPARE='{"status":"ahead","ahead_by":4}' pq p5a "$SEED; $RESOLVE; $RESOLVE"
[ "$(word p5a)" = hold ] && ok || bad "P5a: 4 commits behind with K=3 holds (got $(tail -n3 "$T/pq-p5a.out" | tr '\n' '|'))"
[ "$(ndisp p5a)" = 1 ] && grep -q -- "-f main=$M2" "$T/pq-p5a/gh.argv" && ok || bad "P5a: one dispatch for the current main over two asks (got $(cat "$T/pq-p5a/gh.argv" 2>/dev/null))"
# P5b. 3 behind: proceed, no dispatch, no stale line; 4 behind logs the stale line.
COMPARE='{"status":"ahead","ahead_by":3}' pq p5b "$SEED; $RESOLVE"
[ "$(word p5b)" = proceed ] && [ "$(ndisp p5b)" = 0 ] && ok || bad "P5b: 3 commits behind with K=3 proceeds, no dispatch (word $(word p5b), dispatches $(ndisp p5b))"
grep -q stale-commits "$T/pq-p5b/log" 2>/dev/null && bad "P5b: no stale-commits line when the verdict counts" || ok
grep -q "stale-commits behind=4 k=3" "$T/pq-p5a/log" 2>/dev/null && ok || bad "P5b: 4 behind logs stale-commits behind=4 k=3 (log: $(cat "$T/pq-p5a/log" 2>/dev/null))"
# P5c. diverged; P5d. the compare read fails (rc 75); P5e. K=0 and 1 behind.
COMPARE='{"status":"diverged","ahead_by":1,"behind_by":2}' pq p5c "$SEED; $RESOLVE"
[ "$(word p5c)" = hold ] && [ "$(ndisp p5c)" = 1 ] && ok || bad "P5c: a diverged pair dispatches (word $(word p5c), dispatches $(ndisp p5c))"
COMPARE_RC=75 pq p5d "$SEED; $RESOLVE"
[ "$(word p5d)" = hold ] && [ "$(ndisp p5d)" = 1 ] && ok || bad "P5d: an unreadable compare dispatches (word $(word p5d), dispatches $(ndisp p5d))"
grep -q "stale-commits behind=unreadable k=3" "$T/pq-p5d/log" 2>/dev/null && ok || bad "P5d: the log says unreadable"
MC_PREQUEUE_FRESH_COMMITS=0 COMPARE='{"status":"ahead","ahead_by":1}' pq p5e "$SEED; $RESOLVE"
[ "$(word p5e)" = hold ] && [ "$(ndisp p5e)" = 1 ] && ok || bad "P5e: K=0 and 1 behind dispatches (word $(word p5e), dispatches $(ndisp p5e))"
# P5f. A red 10 commits behind still parks, and costs no compare read.
COMPARE='{"status":"ahead","ahead_by":10}' pq p5f 'pq_cache_put "$(pq_key "$PS_" 7 "$PH" "$M1")" red $(( $(date +%s) - 60 )) 55 tests/a.sh; '"$RESOLVE"
[ "$(word p5f)" = red ] && [ "$(ndisp p5f)" = 0 ] && [ "$(ncmp p5f)" = 0 ] && ok || bad "P5f: a red parks at any distance, no compare read (word $(word p5f), compares $(ncmp p5f))"
# P5g. The same sha is 0 behind with no read; one read per pair in a resolve.
pq p5g 'pq_main_behind "$PS_" "$M2" "$M2"'
[ "$(word p5g)" = 0 ] && [ "$(ncmp p5g)" = 0 ] && ok || bad "P5g: the same main is 0 behind, no read (got '$(word p5g)', compares $(ncmp p5g))"
[ "$(ncmp p5a)" = 1 ] && ok || bad "P5g: one compare read per (verdict main, main) pair in one resolve (got $(ncmp p5a))"
# P5h. One stale-commits line per stale candidate in one resolve (the
#   dispatch-time and the read-time pass see the same candidate).
COMPARE='{"status":"ahead","ahead_by":4}' pq p5h "$SEED; $RESOLVE"
[ "$(grep -c stale-commits "$T/pq-p5h/log" 2>/dev/null)" = 1 ] && ok || bad "P5h: one stale-commits line for one candidate in one resolve (got $(grep -c stale-commits "$T/pq-p5h/log" 2>/dev/null))"

# P4. A green dispatched before the newest ejection is not reused (BH-6161's
#   PQ_MIN_AT filter in pq_resolve, on main since #6182). No skip: with the
#   filter gone, P4 must go red.
COMPARE='{"status":"ahead","ahead_by":1}' pq p4 'pq_cache_put "$(pq_key "$PS_" 7 "$PH" "$M1")" green $(( $(date +%s) - 300 )) 55 ""
  PQ_MIN_AT=$(( $(date +%s) - 200 )); '"$RESOLVE"
[ "$(word p4)" = hold ] && [ "$(ndisp p4)" = 1 ] && ok || bad "P4: a green older than the ejection is not used to enqueue (word $(word p4), dispatches $(ndisp p4))"
COMPARE='{"status":"ahead","ahead_by":1}' pq p4c 'pq_cache_put "$(pq_key "$PS_" 7 "$PH" "$M1")" green $(( $(date +%s) - 100 )) 55 ""
  PQ_MIN_AT=$(( $(date +%s) - 200 )); '"$RESOLVE"
[ "$(word p4c)" = proceed ] && [ "$(ndisp p4c)" = 0 ] && ok || bad "P4: a green newer than the ejection proceeds (word $(word p4c), dispatches $(ndisp p4c))"

# W5. pq_dispatch carries the learned list and the trace switch.
WH="$T/w5h"; mkdir -p "$WH/bin"
printf '#!/bin/bash\n[ "$1" = --list ] && echo "${W5_LIST-tests/a.sh}"\nexit 0\n' > "$WH/bin/prequeue-learned.sh"
: > "$WH/bin/test-trace-safety.sh"
DISP='pq_dispatch "$PS_" 7 "$PH" "$M2"'
PQ_H="$WH" pq w5a "$DISP"
has "$(cat "$T/pq-w5a/gh.argv" 2>/dev/null)" "-f main=$M2 -f learned=tests/a.sh -f trace=1" && ok || bad "W5: the argv ends -f learned=tests/a.sh -f trace=1 (got '$(cat "$T/pq-w5a/gh.argv" 2>/dev/null)')"
scratch_rm "$WH/locks"
PQ_H="$WH" MC_PREQUEUE_TRACE=0 pq w5b "$DISP"
A=$(cat "$T/pq-w5b/gh.argv" 2>/dev/null); has "$A" "-f learned=tests/a.sh" && ! has "$A" trace= && ok || bad "W5: MC_PREQUEUE_TRACE=0 sends no trace (got '$A')"
PQ_H="$WH" pq w5c 'pq_dispatch "$PS_" 7 "$PH" "$M2" tests/x.sh fp1'
A=$(cat "$T/pq-w5c/gh.argv" 2>/dev/null); [ -n "$A" ] && ! has "$A" learned= && ! has "$A" trace= && ok || bad "W5: named suites carry neither (got '$A')"
PQ_H="$WH" W5_LIST='tests/a.sh;rm -rf x' MC_PREQUEUE_TRACE=0 pq w5d "$DISP"
[ "$(cat "$T/pq-w5d/gh.argv" 2>/dev/null)" = "workflow run prequeue-gate.yml -R $PS_ --ref main -f pr=7 -f head=$PH -f main=$M2" ] && ok \
  || bad "W5: a malformed list adds nothing (got '$(cat "$T/pq-w5d/gh.argv" 2>/dev/null)')"

# ============================================================================
# P2. The learned list: 25 failures in, 3 out, through the list, hook and gate.
# ============================================================================
P2H="$T/p2h"; mkdir -p "$P2H/state/prequeue-learned/runs"
if [ -f "$LEARNED" ]; then scratch_install_closure bin/prequeue-learned.sh "$P2H" >/dev/null || bad "P2 setup: install bin/prequeue-learned.sh"
else bad "P2: bin/prequeue-learned.sh is missing"; fi
for i in $(seq 1 25); do printf 'run %s created %s attempt 1\ntests/a.sh\n' "$((1000 + i))" "$((NOW - 3600))" > "$P2H/state/prequeue-learned/runs/$((1000 + i))"; done
for i in 1 2 3; do printf 'run %s created %s attempt 1\ntests/b.sh\n' "$((2000 + i))" "$((NOW - 3600))" > "$P2H/state/prequeue-learned/runs/$((2000 + i))"; done
L=$(env -u PREQUEUE_LEARNED_MIN NOW="$NOW" bash "$P2H/bin/prequeue-learned.sh" --list --harness "$P2H" 2>/dev/null)
[ "$L" = tests/a.sh ] && ok || bad "P2a: 25 failures are in the list, 3 are not (got '$L')"
PQ_H="$P2H" NOW="$NOW" MC_PREQUEUE_TRACE=0 pq p2b 'pq_learned_args'
[ "$(cat "$T/pq-p2b.out")" = "-f learned=tests/a.sh" ] && ok || bad "P2b: pq_learned_args prints -f learned=tests/a.sh (got '$(cat "$T/pq-p2b.out")')"

# ============================================================================
# K1. The knobs.
# ============================================================================
# The knobs are fragment files of the merge-conductor lane (BH-4987: a new knob is its own file).
MCK="$DIR/catalog/lanes.d/merge-conductor.knobs.d"
[ "$(jq -r 'select(.env == "MC_PREQUEUE_FRESH_COMMITS") | .default' "$MCK/MC_PREQUEUE_FRESH_COMMITS.json" 2>/dev/null)" = 3 ] && ok || bad "K1: MC_PREQUEUE_FRESH_COMMITS is registered, default 3"
[ "$(jq -r 'select(.env == "MC_PREQUEUE_TRACE") | .default' "$MCK/MC_PREQUEUE_TRACE.json" 2>/dev/null)" = 1 ] && ok || bad "K1: MC_PREQUEUE_TRACE is registered, default 1"
pq k1 'echo "$(pq_knob MC_PREQUEUE_FRESH_COMMITS) $(pq_knob MC_PREQUEUE_TRACE)"'
[ "$(word k1)" = "3 1" ] && ok || bad "K1: the code fallbacks are 3 and 1 (got '$(word k1)')"

echo "prequeue-gate-learned-suites.bh-6335: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
