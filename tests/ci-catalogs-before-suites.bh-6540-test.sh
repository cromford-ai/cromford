#!/bin/bash
# tests/ci-catalogs-before-suites.bh-6540-test.sh — BH-6540: the traced test
# shards build catalog/lanes.json and catalog/llm-sites.json before any suite.
#
# Both files are git-ignored and composed (lanes.json since BH-1175/BH-1178,
# llm-sites.json since BH-4987). worker/jobs/src/lib/core.js imports lanes.json
# and worker/jobs/src/lib/llm-sites-catalog.js imports llm-sites.json, so a
# suite that loads worker/jobs/src/index.js on a fresh checkout dies with
# ERR_MODULE_NOT_FOUND. Only the lint and worker-jobs jobs built them, so in a
# traced shard such a suite passed only when an earlier suite in the same shard
# had built them (merge-queue batches #6452, #6465, #6532, #6534).
#
# Cases:
#   C1  harness-ci.yml tests-shard: a step runs `bin/lanes-build.sh --write` and
#       `bin/llm-sites-build.sh --compose` (non-comment lines) before the line
#       that runs `bin/test-trace-safety.sh --gate`, with no `if:` and no
#       `continue-on-error`.
#   C2  harness-nightly.yml shard: the same, and its run body equals C1's.
#   C3  the check is red on four fixture copies of harness-ci.yml: N1 step
#       deleted, N2 step after the suite step, N3 commands only as comments,
#       N4 `lanes-build.sh --check` instead of `--write`.
#   R1  a fresh copy of the tree has no catalogs, and importing index.js fails
#       with ERR_MODULE_NOT_FOUND.
#   R2  the workflow's own step body, run in that copy, exits 0, writes both
#       catalogs, and the import then succeeds.
#   R3  dequeue-watch-contract.bh-3719 and blocked-resolver-offhub.bh-6128 exit
#       0 in that copy, with no SKIP and no ERR_MODULE_NOT_FOUND. A SKIP is a
#       FAIL here: a skipped suite proves nothing about the catalogs.
#
# The two replayed suites are named by path only. This suite must not glob
# tests/*.sh: that would put it in bin/test-impact.sh's always set, and R3
# takes about two minutes.
#
# Env: BH6540_CI_WF and BH6540_NIGHTLY_WF override the two workflow paths.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/ci-catalogs-before-suites.bh-6540-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
WF="${BH6540_CI_WF:-$DIR/.github/workflows/harness-ci.yml}"
NWF="${BH6540_NIGHTLY_WF:-$DIR/.github/workflows/harness-nightly.yml}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

STEP="render the lane registry and the llm-sites catalog the worker imports"

# job_steps <wf> <job>: "<step#>\t<line#>\t<text>" for each non-comment line of
# the job's steps. A job runs from `^  <job>:` to the next key at that indent.
job_steps() {
  awk -v want="$2" '
    /^  [a-zA-Z0-9_-]+:/ { inblk = ($0 ~ "^  "want":[[:space:]]*$"); next }
    !inblk { next }
    /^[[:space:]]*#/ { next }
    /^      - / { n++ }
    n { printf "%d\t%d\t%s\n", n, NR, $0 }
  ' "$1"
}

# step_run <wf> <job> <step-name>: the `run: |` body of that step in that job,
# dedented, comments kept (bash ignores them).
step_run() {
  awk -v want="$2" -v name="$3" '
    /^  [a-zA-Z0-9_-]+:/ { inblk = ($0 ~ "^  "want":[[:space:]]*$"); s = 0; r = 0; next }
    !inblk { next }
    /^      - / { s = (index($0, "- name: " name) > 0); r = 0; next }
    s && /^        run: \|[[:space:]]*$/ { r = 1; next }
    r && /^[[:space:]]*$/ { print ""; next }
    r && !/^          / { r = 0; next }
    r { print substr($0, 11) }
  ' "$1"
}

# check_step <wf> <job>: rc 0 when one step of the job has both commands as
# non-comment lines, sits before the suite's `bin/test-trace-safety.sh --gate`
# line, and carries no `if:` and no `continue-on-error`. Prints why on red.
check_step() {
  local rows cat gate cat_line
  rows=$(job_steps "$1" "$2")
  [ -n "$rows" ] || { echo "no job '$2' in $1"; return 1; }
  cat=$(printf '%s\n' "$rows" | awk -F'\t' '
    { t = $3; sub(/^[[:space:]]+/, "", t); sub(/[[:space:]]+$/, "", t) }
    t == "bin/lanes-build.sh --write" { l[$1] = 1 }
    t == "bin/llm-sites-build.sh --compose" { c[$1] = 1 }
    END { for (s in l) if (s in c) { print s; exit } }')
  [ -n "$cat" ] || { echo "job '$2' has no step that runs both bin/lanes-build.sh --write and bin/llm-sites-build.sh --compose"; return 1; }
  gate=$(printf '%s\n' "$rows" | awk -F'\t' 'index($3, "bin/test-trace-safety.sh --gate") { print $2; exit }')
  [ -n "$gate" ] || { echo "job '$2' has no bin/test-trace-safety.sh --gate line"; return 1; }
  cat_line=$(printf '%s\n' "$rows" | awk -F'\t' -v s="$cat" '$1 == s { print $2; exit }')
  [ "$cat_line" -lt "$gate" ] || { echo "the catalog step (line $cat_line) runs after the suite gate (line $gate) in job '$2'"; return 1; }
  if grep -qE '^ *(- )?(if|continue-on-error):' <<<"$(printf '%s\n' "$rows" | awk -F'\t' -v s="$cat" '$1 == s' | cut -f3-)"; then
    echo "the catalog step in job '$2' carries if: or continue-on-error"; return 1
  fi
  return 0
}

for f in "$WF" "$NWF"; do [ -f "$f" ] || { echo "FAIL: workflow not found at $f"; exit 1; }; done

# --- C1: harness-ci.yml tests-shard -------------------------------------------
if why=$(check_step "$WF" tests-shard); then ok "C1 tests-shard builds both catalogs before the suite step"
else bad "C1 tests-shard: $why"; fi
CI_BODY=$(step_run "$WF" tests-shard "$STEP")

# --- C2: harness-nightly.yml shard ---------------------------------------------
if why=$(check_step "$NWF" shard); then ok "C2 nightly shard builds both catalogs before the suite step"
else bad "C2 nightly shard: $why"; fi
N_BODY=$(step_run "$NWF" shard "$STEP")
if [ -n "$CI_BODY" ] && [ "$CI_BODY" = "$N_BODY" ]; then ok "C2 nightly step run body equals the tests-shard one"
else bad "C2 nightly step run body differs from tests-shard (or is empty): [$N_BODY] vs [$CI_BODY]"; fi

# --- C3: the check is red on four broken fixtures --------------------------------
# step_span <wf>: "<first>,<last>" line numbers of the catalog step in tests-shard
# (from its `- name:` line to the line before the next step or comment block).
step_span() {
  awk -v name="$STEP" '
    /^  [a-zA-Z0-9_-]+:/ { inblk = ($0 ~ "^  tests-shard:[[:space:]]*$") }
    inblk && first && !last && (/^      [-#]/ || /^  [a-zA-Z0-9_-]+:/) { last = NR - 1 }
    inblk && !first && index($0, "- name: " name) { first = NR }
    END { if (first) print first "," (last ? last : NR) }
  ' "$1"
}
SPAN=$(step_span "$WF")
if [ -z "$SPAN" ]; then
  bad "C3 premise: no '$STEP' step in tests-shard of $WF to break"
else
  F1="$T/n1.yml"; sed "${SPAN}d" "$WF" > "$F1"
  if why=$(check_step "$F1" tests-shard); then bad "C3 N1 step deleted: check stayed green"; else ok "C3 N1 step deleted: red ($why)"; fi

  F2="$T/n2.yml"; sed -n "${SPAN}p" "$WF" > "$T/step.txt"
  # Re-insert the step right before the first step that follows the suite step.
  sed "${SPAN}d" "$WF" | awk -v stepfile="$T/step.txt" '
    BEGIN { while ((getline l < stepfile) > 0) step = step l "\n" }
    /^  [a-zA-Z0-9_-]+:/ { if (seen && !done) { printf "%s", step; done = 1 } inblk = ($0 ~ "^  tests-shard:[[:space:]]*$") }
    inblk && seen && !done && /^      - / { printf "%s", step; done = 1 }
    inblk && index($0, "- name: tests/ suite, traced") { seen = 1 }
    { print }
    END { if (seen && !done) printf "%s", step }
  ' > "$F2"
  if [ "$(grep -c "name: $STEP" "$F2")" = "$(grep -c "name: $STEP" "$WF")" ]; then
    if why=$(check_step "$F2" tests-shard); then bad "C3 N2 step after the suite: check stayed green"; else ok "C3 N2 step after the suite: red ($why)"; fi
  else
    bad "C3 N2 fixture premise: the moved step did not land once"
  fi

  F3="$T/n3.yml"
  awk -v span="$SPAN" 'BEGIN { split(span, s, ",") }
    NR >= s[1] && NR <= s[2] && /^ *bin\/(lanes|llm-sites)-build\.sh/ { sub(/bin\//, "# bin/") } { print }' "$WF" > "$F3"
  if why=$(check_step "$F3" tests-shard); then bad "C3 N3 commands only as comments: check stayed green"; else ok "C3 N3 commands only as comments: red ($why)"; fi

  F4="$T/n4.yml"
  awk -v span="$SPAN" 'BEGIN { split(span, s, ",") }
    NR >= s[1] && NR <= s[2] { sub(/lanes-build\.sh --write/, "lanes-build.sh --check") } { print }' "$WF" > "$F4"
  if grep -q 'lanes-build.sh --check' "$F4"; then
    if why=$(check_step "$F4" tests-shard); then bad "C3 N4 --check instead of --write: check stayed green"; else ok "C3 N4 --check instead of --write: red ($why)"; fi
  else
    bad "C3 N4 fixture premise: no lanes-build.sh --write line to swap"
  fi
fi

# --- R1: a fresh copy has no catalogs and cannot load the worker ---------------
CO="$T/co"; mkdir -p "$CO"
git -C "$DIR" ls-files -z --cached --others --exclude-standard \
  | (cd "$DIR" && while IFS= read -r -d '' p; do [ -e "$p" ] || [ -L "$p" ] && printf '%s\0' "$p"; done) \
  | (cd "$DIR" && tar --null -T - -cf -) | tar -xf - -C "$CO"
# The path is split so this line is no signal A for the BH-6452 and BH-6540
# ratchets: R1 must load the worker with no catalog on disk, and R2 builds them
# through the workflow's own step, not a per-suite line.
IDX=jobs/src/index.js
IMPORT="await import(\"./worker/$IDX\")"
if [ -e "$CO/catalog/lanes.json" ] || [ -e "$CO/catalog/llm-sites.json" ]; then
  bad "R1 premise: the fresh copy already has a catalog (lanes.json or llm-sites.json is tracked again?)"
else
  OUT=$(cd "$CO" && node --input-type=module -e "$IMPORT" 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && grep -q ERR_MODULE_NOT_FOUND <<<"$OUT"; then
    ok "R1 fresh copy: no catalogs, and importing index.js fails with ERR_MODULE_NOT_FOUND"
  else
    bad "R1 fresh copy: want rc!=0 and ERR_MODULE_NOT_FOUND, got rc=$rc: $(head -3 <<<"$OUT")"
  fi
fi

# --- R2: the workflow's own step, run in the copy -------------------------------
OUT=$(cd "$CO" && printf '%s\n' "$CI_BODY" | bash 2>&1); rc=$?
if [ -n "$CI_BODY" ] && [ "$rc" -eq 0 ] && [ -s "$CO/catalog/lanes.json" ] && [ -s "$CO/catalog/llm-sites.json" ]; then
  ok "R2 the tests-shard step exits 0 and writes both catalogs"
else
  bad "R2 the tests-shard step: want a non-empty body, rc 0 and both catalogs, got rc=$rc body=[${CI_BODY:0:60}]: $(printf '%s' "$OUT" | tail -3)"
fi
OUT=$(cd "$CO" && node --input-type=module -e "$IMPORT" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "R2 index.js imports after the step" || bad "R2 index.js import after the step: rc=$rc: $(head -3 <<<"$OUT")"

# --- R3: the two suites that failed in a shard, replayed in the copy ------------
for s in tests/dequeue-watch-contract.bh-3719-test.sh tests/blocked-resolver-offhub.bh-6128-test.sh; do
  OUT=$(cd "$CO" && HARNESS_TEST_SANDBOX=1 bash "$s" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && ! grep -qE '^SKIP|ERR_MODULE_NOT_FOUND' <<<"$OUT"; then
    ok "R3 $s passes in the fresh copy"
  else
    bad "R3 $s in the fresh copy: rc=$rc"
    printf '%s\n' "$OUT" | grep -E 'SKIP|FAIL|ERR_MODULE_NOT_FOUND' | head -5 | sed 's/^/         /'
  fi
done

echo "ci-catalogs-before-suites: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
