#!/bin/bash
# tests/prequeue-fast-lints-runner.bh-8473-test.sh — BH-8473: the runner
# bin/prequeue-fast-lints.sh, the catalog catalog/prequeue-fast-lints.tsv it
# reads, and the opt-in LANES_REGISTRY_SECTIONS=static run of
# tests/lanes-registry-test.sh that the catalog's lanes-registry row uses.
#
#   L1  --list on the real catalog: 10 ids; an unknown --set id is a stderr
#       note and is skipped; a set with no known id is rc 2
#   V1  rc 0 → green                    V2  red merged, green base → red
#   V3  red on both → preexisting       V4  rc 0 with FAIL text → green
#   V5  a missing script → could-not-run
#   V6  past the budget → unfinished, wall ≤ budget + 5 s
#   V7  a cached baseline: the base is not run again
#   V8  4 jobs run 4 slow items at once
#   V9  the trace item gets exactly the tests/*.sh the diff adds or edits
#   V10 a red whose base run the budget cut → unfinished, never red
#   R1  a tree with a prose zero_means: the static run is rc 1 and names it
#   R2  the same tree, clean: the static run is rc 0
#   R4  a tree with a knob fragment a wired script reads removed (the #8344
#       class, blocked-resolver/MC_LOG): the static run is rc 1 and §7 names it
#   R3  results.tsv holds the five states and the hook reads it back
#   P1  the real tree plus a 50-file commit, the default set, budget 60: the
#       runner returns within 65 s. With PREQUEUE_FAST_LINTS_TIMING=1 (by hand
#       on the hub) it also asserts no unfinished item and a total under 60 s.
#
# Every case builds its own fixture trees under $T. No network.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prequeue-fast-lints-runner.bh-8473-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
command -v timeout >/dev/null || { echo "timeout missing — skipping"; exit 0; }
RUNNER="$DIR/bin/prequeue-fast-lints.sh"
CATALOG="$DIR/catalog/prequeue-fast-lints.tsv"
[ -f "$RUNNER" ] || { echo "FAIL: $RUNNER does not exist"; exit 1; }
[ -f "$CATALOG" ] || { echo "FAIL: $CATALOG does not exist"; exit 1; }
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.invalid
git config --global user.name t
git config --global init.defaultBranch main
git config --global commit.gpgsign false

# ── L1: the real catalog ──
out=$(bash "$RUNNER" --list 2>"$T/l1.err"); rc=$?
[ "$rc" = 0 ] && [ "$(grep -c . <<<"$out")" = 10 ] && ok || bad "L1 --list prints 10 ids, got rc $rc and $(grep -c . <<<"$out") lines"
for id in lanes-registry llm-lane-knobs llm-lane-id context-budget-manifest mc-split-layout br-split-layout worker-node-lanes-build rules-pack list-file-lint trace; do
  grep -q "^$id"$'\t' <<<"$out" && ok || bad "L1 the catalog has no $id row"
done
grep -q 'lanes-registry.bh-2205' <<<"$(grep -v '^#' "$CATALOG")" && bad "L1 the meta-suite tests/lanes-registry.bh-2205-test.sh is not a row" || ok
out=$(bash "$RUNNER" --list --set lanes-registry,nope 2>"$T/l1.err"); rc=$?
[ "$rc" = 0 ] && [ "$(grep -c . <<<"$out")" = 1 ] && grep -q "nope" "$T/l1.err" && ok \
  || bad "L1 an unknown id is a stderr note and is skipped (rc $rc, out '$out', err '$(cat "$T/l1.err")')"
bash "$RUNNER" --list --set nope >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok || bad "L1 a set with no known id is rc 2, got $rc"
bash "$RUNNER" --run --out "$T/x" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok || bad "L1 --run with no --tree is rc 2, got $rc"

# ── fixture trees: merged M and base B. t/<name>.sh differs between them. ──
# mk_trees: each tree is a git repo whose origin/main is its first commit.
mk_tree() {  # mk_tree <dir> — a repo with one commit and origin/main on it
  mkdir -p "$1/t"; git -C "$1" init -q
  printf '#!/bin/bash\nexit 0\n' > "$1/t/ok.sh"
  printf '#!/bin/bash\necho "FAIL: looks red" >&2\necho "FAIL: on stdout"\nexit 0\n' > "$1/t/failtext.sh"
  printf '#!/bin/bash\necho x >> "%s"\nexit 1\n' "$T/base-runs" > "$1/t/both.sh"
  printf '#!/bin/bash\nsleep 30\n' > "$1/t/slow.sh"
  printf '#!/bin/bash\nsleep 2\n' > "$1/t/two.sh"
  git -C "$1" add -A; git -C "$1" commit -qm base; git -C "$1" update-ref refs/remotes/origin/main HEAD
}
MT="$T/merged"; BT="$T/base"
mk_tree "$MT"; mk_tree "$BT"
printf '#!/bin/bash\nexit 1\n' > "$MT/t/redm.sh"
printf '#!/bin/bash\necho x >> "%s"\nexit 0\n' "$T/base-runs" > "$BT/t/redm.sh"
printf '#!/bin/bash\nsleep 30\n' > "$BT/t/redslowbase.sh"; printf '#!/bin/bash\nexit 1\n' > "$MT/t/redslowbase.sh"
FCAT="$T/cat.tsv"
{
  printf 'ok\tbash t/ok.sh\tt/ok.sh\tfixture\n'
  printf 'redm\tbash t/redm.sh\tt/redm.sh\tfixture\n'
  printf 'both\tbash t/both.sh\tt/both.sh\tfixture\n'
  printf 'failtext\tbash t/failtext.sh\tt/failtext.sh\tfixture\n'
  printf 'missing\tbash t/missing.sh\tt/missing.sh\tfixture\n'
  printf 'slow\tbash t/slow.sh\tt/slow.sh\tfixture\n'
  printf 'two1\tbash t/two.sh\tt/two1.sh\tfixture\n'
  printf 'two2\tbash t/two.sh\tt/two2.sh\tfixture\n'
  printf 'two3\tbash t/two.sh\tt/two3.sh\tfixture\n'
  printf 'two4\tbash t/two.sh\tt/two4.sh\tfixture\n'
  printf 'redslowbase\tbash t/redslowbase.sh\tt/redslowbase.sh\tfixture\n'
  printf 'trace\t@trace\tbin/test-trace-safety.sh\tfixture\n'
} > "$FCAT"
# run <case> <set> [extra args] — one run; RC, SECS, OUT, RES (results.tsv)
run() {
  local c="$1" s="$2" t0; shift 2
  scratch_rm "$T/out.$c" 2>/dev/null; : > "$T/base-runs"
  t0=$SECONDS
  OUT=$(bash "$RUNNER" --run --catalog "$FCAT" --tree "$MT" --base-tree "$BT" --out "$T/out.$c" --set "$s" --budget-s "${BUDGET:-20}" --jobs "${JOBS:-4}" "$@" 2>"$T/err.$c"); RC=$?
  SECS=$((SECONDS - t0)); RES="$T/out.$c/results.tsv"
}
state_of() { awk -F'\t' -v i="$1" '$1==i {print $5}' "$RES" 2>/dev/null; }

run v1 ok
[ "$RC" = 0 ] && [ "$(state_of ok)" = green ] && ok || bad "V1 rc 0 is green (rc $RC, state '$(state_of ok)', err $(cat "$T/err.v1"))"
grep -qx 'prequeue-fast-lints: 1 items, [0-9]*s, red=none unfinished=none preexisting=none could-not-run=none' <<<"$OUT" \
  && ok || bad "V1 the summary line (got '$OUT')"
[ "$(awk -F'\t' '$1=="ok"{print $2"|"$3}' "$RES")" = "t/ok.sh|0" ] && ok || bad "V1 the row carries the suite and the rc"

run v2 redm
[ "$RC" = 1 ] && [ "$(state_of redm)" = red ] && ok || bad "V2 red merged, green base is red (rc $RC, state '$(state_of redm)')"
[ "$(grep -c . "$T/base-runs")" = 1 ] && ok || bad "V2 the base ran once (got $(grep -c . "$T/base-runs"))"
grep -q 'red=redm ' <<<"$OUT" && ok || bad "V2 the summary names redm (got '$OUT')"
[ -e "$T/out.v2/log/redm.log" ] && [ -e "$T/out.v2/log/redm.base.log" ] && ok || bad "V2 log/redm.log and log/redm.base.log are written"

run v3 both
[ "$RC" = 0 ] && [ "$(state_of both)" = preexisting ] && ok || bad "V3 red on both is preexisting (rc $RC, state '$(state_of both)')"

run v4 failtext
[ "$RC" = 0 ] && [ "$(state_of failtext)" = green ] && ok || bad "V4 rc 0 with FAIL text is green (state '$(state_of failtext)')"

run v5 missing
[ "$RC" = 0 ] && [ "$(state_of missing)" = could-not-run ] && ok || bad "V5 a missing script is could-not-run (rc $RC, state '$(state_of missing)')"

BUDGET=3 run v6 slow
[ "$(state_of slow)" = unfinished ] && ok || bad "V6 past the budget is unfinished (state '$(state_of slow)')"
[ "$SECS" -le 8 ] && ok || bad "V6 the wall is within budget + 5 s (took ${SECS}s)"
[ "$RC" = 0 ] && grep -q 'unfinished=slow ' <<<"$OUT" && ok || bad "V6 the summary names it unfinished, rc 0 (rc $RC, '$OUT')"

mkdir -p "$T/cache"
run v7a redm --cache-dir "$T/cache"
[ "$(cat "$T/cache/redm.rc" 2>/dev/null)" = 0 ] && ok || bad "V7 the base rc is written to the cache (got '$(cat "$T/cache/redm.rc" 2>/dev/null)')"
run v7b redm --cache-dir "$T/cache"
[ "$(state_of redm)" = red ] && [ ! -s "$T/base-runs" ] && ok || bad "V7 the second run reads the cache and runs no base (state '$(state_of redm)', base runs $(grep -c . "$T/base-runs"))"
echo 1 > "$T/cache/redm.rc"; run v7c redm --cache-dir "$T/cache"
[ "$(state_of redm)" = preexisting ] && ok || bad "V7 a cached red baseline is preexisting (state '$(state_of redm)')"

JOBS=4 run v8 two1,two2,two3,two4
[ "$RC" = 0 ] && [ "$(awk -F'\t' '$5=="green"' "$RES" | wc -l)" = 4 ] && ok || bad "V8 four green items (rc $RC: $(cat "$RES" 2>/dev/null))"
[ "$SECS" -le 6 ] && ok || bad "V8 4 jobs × 2 s run at once (took ${SECS}s; serial is 8 s)"
JOBS=1 run v8b two1,two2,two3
[ "$SECS" -ge 6 ] && ok || bad "V8 --jobs 1 runs them one at a time (took ${SECS}s)"

BUDGET=4 run v10 redslowbase
[ "$(state_of redslowbase)" = unfinished ] && [ "$RC" = 0 ] && ok || bad "V10 a red whose base run the budget cut is unfinished (state '$(state_of redslowbase)', rc $RC)"

# ── V9: the trace item's list ──
TT="$T/trace"; mkdir -p "$TT/tests/mc" "$TT/bin" "$TT/tests/lib"; git -C "$TT" init -q
printf '#!/bin/bash\nexit 0\n' > "$TT/tests/b-test.sh"; printf '#!/bin/bash\nexit 0\n' > "$TT/tests/c-test.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" > "%s/trace-args"; cp "$3" "%s/trace-list"; exit "${TRACE_RC:-0}"\n' "$T" "$T" > "$TT/bin/test-trace-safety.sh"
git -C "$TT" add -A; git -C "$TT" commit -qm base; git -C "$TT" update-ref refs/remotes/origin/main HEAD
run_trace() {
  rm -f "$T/trace-args" "$T/trace-list"; scratch_rm "$T/out.tr" 2>/dev/null
  OUT=$(bash "$RUNNER" --run --catalog "$FCAT" --tree "$TT" --out "$T/out.tr" --set trace --budget-s 20 2>"$T/err.tr"); RC=$?
  RES="$T/out.tr/results.tsv"
}
run_trace
[ "$RC" = 0 ] && [ "$(state_of trace)" = green ] && [ ! -e "$T/trace-args" ] && ok || bad "V9 no changed suite: green, the trace does not run (rc $RC, state '$(state_of trace)')"
printf '#!/bin/bash\nexit 0\n' > "$TT/tests/a-test.sh"; printf '#!/bin/bash\nexit 0\n' > "$TT/tests/mc/m-test.sh"
echo '# edited' >> "$TT/tests/b-test.sh"; git -C "$TT" rm -q tests/c-test.sh
printf 'x\n' > "$TT/bin/x.sh"; printf 'x\n' > "$TT/tests/lib/h.sh"
git -C "$TT" add -A; git -C "$TT" commit -qm pr
run_trace
[ "$(sort "$T/trace-list" 2>/dev/null | tr '\n' ' ')" = "tests/a-test.sh tests/b-test.sh tests/mc/m-test.sh " ] && ok \
  || bad "V9 the trace list is exactly the added and edited suites (got: $(cat "$T/trace-list" 2>/dev/null))"
grep -q -- '--gate --only-file ' "$T/trace-args" 2>/dev/null && ok || bad "V9 the trace runs --gate --only-file (args: $(cat "$T/trace-args" 2>/dev/null))"
[ "$(state_of trace)" = green ] && ok || bad "V9 a clean trace is green"

# ── R3: the five states in one results.tsv, read back by the hook ──
BUDGET=4 run r3 ok,redm,both,slow,missing
for s in "ok green" "redm red" "both preexisting" "slow unfinished" "missing could-not-run"; do
  set -- $s; [ "$(state_of "$1")" = "$2" ] && ok || bad "R3 $1 must be $2, got '$(state_of "$1")'"
done
[ "$(grep -c . "$RES")" = 5 ] && ok || bad "R3 one row per item"
grep -q 'red=redm unfinished=slow preexisting=both could-not-run=missing' <<<"$OUT" && ok || bad "R3 the summary counts are the rows (got '$OUT')"
# shellcheck source=bin/lib/mc-prequeue.d/fast-lints.sh
if ( . "$DIR/bin/lib/mc-prequeue.d/fast-lints.sh" && declare -F _pq_fl_read >/dev/null ); then
  w=$( . "$DIR/bin/lib/mc-prequeue.d/fast-lints.sh"; _pq_fl_read "$RES"; echo "$_PQ_FL_RED|$_PQ_FL_SUITES|$_PQ_FL_UNF|$_PQ_FL_PRE|$_PQ_FL_CNR" )
  [ "$w" = "redm|t/redm.sh|slow|both|missing" ] && ok || bad "R3 the hook reads the rows back (got '$w')"
else bad "R3 bin/lib/mc-prequeue.d/fast-lints.sh has no _pq_fl_read"; fi

# ── R1 / R2: the static lanes-registry run on a copy of this tree ──
RT="$T/real"; mkdir -p "$RT"
( cd "$DIR" && git ls-files -co --exclude-standard -z | tar --null -T - -cf - 2>/dev/null ) | tar -C "$RT" -xf - || bad "R setup: could not copy the tree"
t0=$SECONDS
( cd "$RT" && LANES_REGISTRY_SECTIONS=static bash tests/lanes-registry-test.sh ) > "$T/r2.out" 2>&1; rc=$?
R2S=$((SECONDS - t0))
[ "$rc" = 0 ] && ok || bad "R2 the clean tree's static run is rc 0 (got $rc: $(tail -3 "$T/r2.out"))"
grep -q '^lanes-registry: .* (static sections' "$T/r2.out" && ok || bad "R2 the summary says the run was static (got: $(tail -1 "$T/r2.out"))"
echo "R2 static lanes-registry run: ${R2S}s"
K="$RT/catalog/lanes.d/merge-conductor.knobs.d/MC_PREQUEUE_TRACE.json"
sed -i 's/"zero_means": "off"/"zero_means": "only when idle"/' "$K"
grep -q 'only when idle' "$K" || bad "R1 setup: the fixture edit did not apply"
( cd "$RT" && LANES_REGISTRY_SECTIONS=static bash tests/lanes-registry-test.sh ) > "$T/r1.out" 2>&1; rc=$?
[ "$rc" = 1 ] && ok || bad "R1 a prose zero_means makes the static run rc 1 (got $rc)"
grep -q '^FAIL: 8 knobs with a bad schema: .*merge-conductor/MC_PREQUEUE_TRACE' "$T/r1.out" && ok || bad "R1 the §8 line names the knob (got: $(grep FAIL "$T/r1.out"))"
git -C "$DIR" diff --quiet -- catalog/lanes.d || bad "R1 the fixture edit leaked into the checkout"
sed -i 's/"zero_means": "only when idle"/"zero_means": "off"/' "$K"

# ── R4: the #8344 class — a wired script reads a knob the registry lost ──
K4="$RT/catalog/lanes.d/blocked-resolver.knobs.d/MC_LOG.json"
[ -f "$K4" ] || bad "R4 setup: $K4 is not in the tree"
grep -q 'MC_LOG:-' "$RT/bin/blocked-resolver.sh" || bad "R4 setup: bin/blocked-resolver.sh no longer reads \${MC_LOG:-}"
cp "$K4" "$T/MC_LOG.json.keep"; rm -f "$K4"
( cd "$RT" && LANES_REGISTRY_SECTIONS=static bash tests/lanes-registry-test.sh ) > "$T/r4.out" 2>&1; rc=$?
[ "$rc" = 1 ] && ok || bad "R4 a missing knob fragment makes the static run rc 1 (got $rc)"
grep -q '^FAIL: 7 wired lanes read env knobs the registry does not carry: .*blocked-resolver/MC_LOG' "$T/r4.out" && ok \
  || bad "R4 the §7 line names blocked-resolver/MC_LOG (got: $(grep FAIL "$T/r4.out"))"
cp "$T/MC_LOG.json.keep" "$K4"
git -C "$DIR" diff --quiet -- catalog/lanes.d || bad "R4 the fixture edit leaked into the checkout"

# ── P1: the real tree plus a 50-file commit, the default set, budget 60 ──
git -C "$RT" init -q; git -C "$RT" add -A; git -C "$RT" commit -qm base; git -C "$RT" update-ref refs/remotes/origin/main HEAD
mkdir -p "$RT/docs/bh8473-p1"; for i in $(seq 1 50); do echo "fixture $i" > "$RT/docs/bh8473-p1/f$i.txt"; done
git -C "$RT" add -A; git -C "$RT" commit -qm p1-50-files
t0=$SECONDS
POUT=$(bash "$RT/bin/prequeue-fast-lints.sh" --run --tree "$RT" --out "$T/out.p1" --budget-s 60 --jobs 4 2>"$T/err.p1"); rc=$?
P1S=$((SECONDS - t0))
echo "P1 timing: ${P1S}s rc=$rc :: $POUT"
awk -F'\t' '{printf "P1 item %s %ss %s\n", $1, $4, $5}' "$T/out.p1/results.tsv" 2>/dev/null
[ "$P1S" -le 65 ] && ok || bad "P1 the runner returns within 65 s (took ${P1S}s)"
[ "$(grep -c . "$T/out.p1/results.tsv" 2>/dev/null)" = 10 ] && ok || bad "P1 one row per catalog item"
if [ "${PREQUEUE_FAST_LINTS_TIMING:-0}" = 1 ]; then
  grep -q 'unfinished=none ' <<<"$POUT" && ok || bad "P1 timing: no item unfinished ($POUT)"
  [ "$P1S" -lt 60 ] && ok || bad "P1 timing: total under 60 s (took ${P1S}s)"
fi

echo "prequeue-fast-lints-runner: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
