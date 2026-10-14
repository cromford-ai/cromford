#!/bin/bash
# tests/flaky-quarantine-test.sh — bin/flaky-quarantine.sh.
#
# THE CLAIM WORTH TESTING IS THE ONE ABOUT NOT WRITING. Quarantining a test
# makes it stop failing the build, so this script is a machine that can switch
# off a client repo's own alarms. It must therefore:
#   * write NOTHING without --apply — no branch, no contents PUT, no PR
#   * propose only tests at or above the threshold, counted in DISTINCT heads
#   * never propose a name already in the file, and never propose a job:/
#     workflow: fallback row (no runner can match one, so it would be a
#     quarantine that quarantines nothing while looking like it worked)
#   * open a PULL REQUEST under --apply, never push the default branch
#
# gh is stubbed and FAILS THE RUN on any write verb during a dry run.
# Run from anywhere: tests/flaky-quarantine-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/fakebin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

cp "$DIR/bin/flaky-quarantine.sh" "$T/h/bin/" 2>/dev/null
cp "$DIR/bin/lib/flaky.sh" "$DIR/bin/lib/gh-repo-token.sh" "$T/h/bin/lib/" 2>/dev/null
[ -s "$T/h/bin/flaky-quarantine.sh" ] && ok || bad "bin/flaky-quarantine.sh missing"
cat > "$T/h/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1 $2" in "demo repo") echo "example-org/demo-os" ;; esac
SH
chmod +x "$T/h/bin/fleet-conf.sh"
cat > "$T/h/bin/jobs-client.sh" <<'SH'
metric_flakes_list() { cat "${FLAKE_LEDGER:-/dev/null}" 2>/dev/null; }
SH
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
case "$*" in
  *"-X POST"*|*"-X PUT"*|*"-X PATCH"*|*"pr create"*|*"pr merge"*) printf '%s\n' "$*" >> "$GH_WRITES"
     case "$*" in *"pr create"*) echo "https://github.com/example-org/demo-os/pull/99" ;; esac
     exit 0 ;;
  "api repos/"*" -q .id") exit 0 ;;
  *"contents/ci/flaky.txt"*) [ -f "$T/have.txt" ] || exit 1
     printf '%s\t%s\n' filesha "$(base64 < "$T/have.txt" | tr -d '\n')" ;;
  *"repos/example-org/demo-os -q .default_branch"*) echo main ;;
  *"git/ref/heads/main"*) echo "basesha1234" ;;
  *) echo "" ;;
esac
SH
chmod +x "$T/fakebin/gh"

D=$(date -u +%Y-%m-%d)
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" example-org/demo-os .github/workflows/ci.yml "$2" "$3" "$4" >> "$T/ledger.tsv"; }
run() {
  : > "$T/gh.txt"; : > "$T/writes.txt"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" T="$T" GH_SINK="$T/gh.txt" GH_WRITES="$T/writes.txt" \
           FLAKE_LEDGER="$T/ledger.tsv" HARNESS_SECRET=x
    bash "$T/h/bin/flaky-quarantine.sh" "$@" ) > "$T/out.txt" 2> "$T/err.txt"
}

# ── 1. a test on three distinct heads is proposed; one on two is not ────────
: > "$T/ledger.tsv"; rm -f "$T/have.txt"
row "$D" "queue > drains"        h1 flake
row "$D" "queue > drains"        h2 flake
row "$D" "queue > drains"        h3 flake
row "$D" "auth > expires"        h1 flake
row "$D" "auth > expires"        h2 flake
run demo
grep -q '^  + queue > drains$' "$T/out.txt" \
  && ok || bad "3 distinct flaky heads must be proposed: $(cat "$T/out.txt") $(cat "$T/err.txt")"
grep -q 'auth > expires' "$T/out.txt" \
  && bad "2 heads is below the threshold and must NOT be proposed" || ok
[ -s "$T/writes.txt" ] && bad "a dry run used a write verb: $(cat "$T/writes.txt")" || ok
grep -q 'dry run' "$T/out.txt" && ok || bad "a dry run must say so"

# ── 2. the same head nine times is still ONE piece of evidence ──────────────
: > "$T/ledger.tsv"
for _ in 1 2 3 4 5 6 7 8 9; do row "$D" "noisy > test" h1 flake; done
run demo
grep -q 'noisy > test' "$T/out.txt" \
  && bad "nine rows on ONE head must not reach a 3-head threshold" || ok

# ── 3. red rows are not flakes, and job:/workflow: rows are never proposed ──
: > "$T/ledger.tsv"
row "$D" "real > break" h1 red
row "$D" "real > break" h2 red
row "$D" "real > break" h3 red
row "$D" "job:unit"     h1 flake
row "$D" "job:unit"     h2 flake
row "$D" "job:unit"     h3 flake
run demo
grep -q 'real > break' "$T/out.txt" && bad "a REAL red must never be quarantined" || ok
grep -q 'job:unit' "$T/out.txt" \
  && bad "job:<name> is a red we could not read, not a test a runner can match" || ok

# ── 4. already listed = nothing to propose ──────────────────────────────────
: > "$T/ledger.tsv"
row "$D" "queue > drains" h1 flake
row "$D" "queue > drains" h2 flake
row "$D" "queue > drains" h3 flake
printf '# quarantined\nqueue > drains\n' > "$T/have.txt"
run demo
grep -q 'already in' "$T/out.txt" \
  && ok || bad "a name already in the file must not be re-proposed: $(cat "$T/out.txt")"
[ -s "$T/writes.txt" ] && bad "nothing to do must write nothing" || ok

# ── 5. --apply opens a PR on a NEW branch, and never touches main ───────────
rm -f "$T/have.txt"
run demo --apply
grep -q 'POST repos/example-org/demo-os/git/refs' "$T/writes.txt" \
  && ok || bad "--apply must create a branch: $(cat "$T/writes.txt")"
grep -qE 'ref=refs/heads/chore/quarantine-flaky-' "$T/writes.txt" \
  && ok || bad "the branch must be a chore/quarantine-flaky-* branch"
grep -q 'PUT repos/example-org/demo-os/contents/ci/flaky.txt' "$T/writes.txt" \
  && ok || bad "--apply must write ci/flaky.txt"
grep -q 'branch=chore/quarantine-flaky-' "$T/writes.txt" \
  && ok || bad "the contents write must be scoped to the branch, never the default"
grep -q 'pr create' "$T/writes.txt" \
  && ok || bad "--apply must open a PR, not merge anything"
grep -qE 'pr merge|git/refs/heads/main|-X PATCH' "$T/writes.txt" \
  && bad "--apply must never merge or move main: $(cat "$T/writes.txt")" || ok
grep -q 'pull/99' "$T/out.txt" && ok || bad "the PR url must be printed"

echo "flaky-quarantine-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
