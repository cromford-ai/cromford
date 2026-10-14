#!/bin/bash
# tests/race-sigpipe-echo-bin.bh-6654-test.sh — the 17 C3 bin/ files hold no
# race-sigpipe-echo hit, and the two hits that were live defects stay fixed
# (BH-6654, slice C3 of BH-6109; recipe in
# docs/notes/2026-10-12-BH-6109-sigpipe-echo-rule.md).
#
# The rule does not scan bin/ until slice C6 adds its scope line, so case A
# runs the lint with a scratch copy of the conf that carries that line. The
# real conf is never edited.
#   A  the scoped lint on the 17 files reports 0 race-sigpipe-echo lines.
#   B  pipefail: mc_lane_account_fact on `usage limit` + 900 KB is rc 0.
#   C  MC_LANE_EXHAUST_RE='zzz|': an empty reason is rc 1 (R2a, no added line).
#   D  mc_lane_account_fact "all good" is rc 1 (default regex).
#   E  pipefail: _pr_drive_md with a 900 KB observed is rc 0 and writes a
#      2000-byte prebuild-repro.md that starts `REPRO_ROLE: r`.
#   F  _pr_drive_md with short fields writes the exact old bytes.
#   G  _llm_is_num: 12 and 1.5 are rc 0; '', abc and -1 are rc 1.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/race-sigpipe-echo-bin.bh-6654-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

C3_FILES="bin/lib/lane-gate.sh bin/lib/lead-delta.sh bin/lib/llm-gate.sh
bin/lib/main-red-queue-dispatch.sh bin/lib/mc/locks.sh bin/lib/mc/rebase.sh
bin/lib/migrations-glob.sh bin/lib/observe-report.sh bin/lib/orc-account.sh
bin/lib/pr-dep-gate.sh bin/lib/pr-health.sh bin/lib/pr-owner/stale.sh
bin/lib/pr-self-check.sh bin/lib/prebuild-repro/drive.sh bin/lib/preplan-lib.sh
bin/lib/queue-batch-only.sh bin/lib/rb/execute.sh"

# run <lib> <script> — a fresh bash that sources one lib, then runs script.
run() {
  HARNESS_TEST_SANDBOX=1 HARNESS='' H='' bash -c '. "$1" >/dev/null 2>&1 || exit 97; set -o pipefail; eval "$2"' _ "$REPO/bin/lib/$1" "$2"
}
# BIG: 900 KB of `a`, built in the child. ${x// /a} on 900 KB takes minutes.
BIG='big=$(tr "\0" a < <(head -c 900000 /dev/zero))'

# --- A ------------------------------------------------------------------------
cp "$REPO/catalog/determinism-lint.conf" "$T/scope.conf"
printf 'scope race-sigpipe-echo  (^|/)bin/.*\\.sh$\n' >> "$T/scope.conf"
# shellcheck disable=SC2086 # C3_FILES is a word list on purpose
out=$(cd "$REPO" && DETERMINISM_LINT_CONF="$T/scope.conf" bin/test-determinism-lint.sh $C3_FILES 2>&1)
n=$(grep -c ': race-sigpipe-echo:' <<<"$out")
# The scope line must reach the lint, or A is vacuous: a known hit is reported.
# The pipe char is a variable so this suite's own line is not the shape.
mkdir -p "$T/bin"; bar='|'
printf '#!/bin/bash\nx=1\nprintf "%%s\\n" "$x" %s grep -q 1\n' "$bar" > "$T/bin/probe.sh"
probe=$(cd "$REPO" && DETERMINISM_LINT_CONF="$T/scope.conf" bin/test-determinism-lint.sh "$T/bin/probe.sh" 2>&1)
if [ "$n" = 0 ] && grep -q ': race-sigpipe-echo:' <<<"$probe"; then ok
else bad "A: $n race-sigpipe-echo lines in the C3 files (probe seen: $(grep -c ': race-sigpipe-echo:' <<<"$probe"))"; grep ': race-sigpipe-echo:' <<<"$out"; fi

# --- B, C, D: mc_lane_account_fact ---------------------------------------------
run mc/locks.sh "$BIG"'; mc_lane_account_fact "usage limit
$big"'; rc=$?
[ "$rc" = 0 ] && ok || bad "B: a true match on a 900 KB reason is rc $rc, want 0"
MC_LANE_EXHAUST_RE='zzz|' run mc/locks.sh 'mc_lane_account_fact ""'; rc=$?
[ "$rc" = 1 ] && ok || bad "C: an empty reason with an empty-matching regex is rc $rc, want 1"
run mc/locks.sh 'mc_lane_account_fact "all good"'; rc=$?
[ "$rc" = 1 ] && ok || bad "D: \"all good\" is rc $rc, want 1"

# --- E, F: _pr_drive_md --------------------------------------------------------
mkdir -p "$T/e" "$T/f"
run prebuild-repro/drive.sh "$BIG"'; _pr_drive_md "'"$T/e"'" r u s "$big"'; rc=$?
sz=$({ wc -c < "$T/e/prebuild-repro.md"; } 2>/dev/null || echo none)
head13=$(head -c 13 "$T/e/prebuild-repro.md" 2>/dev/null)
if [ "$rc" = 0 ] && [ "$sz" = 2000 ] && [ "$head13" = 'REPRO_ROLE: r' ]; then ok
else bad "E: rc=$rc size=$sz head='$head13', want rc 0, 2000 bytes, 'REPRO_ROLE: r'"; fi
run prebuild-repro/drive.sh '_pr_drive_md "'"$T/f"'" r u s short'
printf 'REPRO_ROLE: r\nREPRO_URL: u\nREPRO_STEPS: s\nREPRO_OBSERVED: short\n' > "$T/f.want"
if cmp -s "$T/f.want" "$T/f/prebuild-repro.md"; then ok
else bad "F: short fields do not give the old bytes"; fi
leftover=$(find "$T/e" "$T/f" -name '.prebuild-repro-md.*' | wc -l)
[ "$leftover" = 0 ] && ok || bad "E/F: $leftover tmp files left behind"

# --- G: _llm_is_num ------------------------------------------------------------
for v in 12 1.5; do
  run llm-gate.sh "_llm_is_num '$v'"; rc=$?
  [ "$rc" = 0 ] && ok || bad "G: _llm_is_num '$v' is rc $rc, want 0"
done
for v in '' abc -1; do
  run llm-gate.sh "_llm_is_num '$v'"; rc=$?
  [ "$rc" = 1 ] && ok || bad "G: _llm_is_num '$v' is rc $rc, want 1"
done

echo "race-sigpipe-echo-bin.bh-6654: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
