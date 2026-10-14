#!/bin/bash
# tests/blocked-resolver-lane-exhausted-test.sh — the resolver does not rebuild
# a ticket whose only fault was the runner lane, and an ABANDONED outcome is
# written where a watcher can read it (2026-09-23 pool loop).
#
#   A  br_from_queue skips a parked row whose reason is the lane's own verdict
#      (RUNNER_EXHAUSTED, class=auth): a fresh rebuild meets the same exhausted
#      lane. Ordinary deferred-max and died-twice rows are still offered.
#   B  br_abandon writes the fleet ledger row `abandoned "<project> <KEY>"`,
#      which bin/run-build.sh reads before a watcher enqueues (BH-1681 was
#      rebuilt twice after its ABANDONED, requested_by box-small).
#
# HOW IT DRIVES: both functions are EXTRACTED from the real script and executed
# with their collaborators stubbed (the tests/blocked-resolver.bh-614-test.sh
# seam). No network, no clock, no LLM.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
BR="$DIR/bin/blocked-resolver.sh"
H="$T/h"; mkdir -p "$H/state/build-queue" "$H/logs" "$H/bin"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
# BH-6517: br_from_queue moved to bin/lib/br/discovery.sh; the corpus is the
# driver first, then every module (tests/lib/br-corpus.sh).
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$DIR" "$T/br-corpus.sh" || exit 1

fn() { awk -v f="$1" '$0 ~ "^"f"\\(\\) \\{" {p=1} p{print} p&&/^}$/{exit}' "$T/br-corpus.sh"; }

# ── A. br_from_queue ────────────────────────────────────────────────────────
{ fn br_rkey; fn br_from_queue; } > "$T/q.sh"
grep -q '^br_from_queue() {' "$T/q.sh" && ok || bad "A: could not extract br_from_queue"
cat > "$T/rows.tsv" <<'EOF'
tproj	BH-1	1	failed	fly	1	-	-	deferred 6 times (BUILD_DEFERRED plan session ended RUNNER_EXHAUSTED class=real-failure(agent) seen=account-exhausted,real-failure) — parked for the blocked-resolver	-
tproj	BH-2	2	failed	fly	1	-	-	deferred 6 times (BUILD_DEFERRED plan session ended RUNNER_ERROR class=auth(credential) seen=auth runner=openrouter rc=1) — parked	-
tproj	BH-3	3	failed	fly	1	-	-	deferred 6 times (BUILD_DEFERRED wip-limit 2 reached) — parked for the blocked-resolver	-
tproj	BH-4	4	failed	fly	2	-	-	pool machine died 2 times	-
EOF
OUT=$(H="$H" ONLY="" ROWS="$T/rows.tsv" bash -c '
  queue_list() { cat "$ROWS"; }
  . "$0"; br_from_queue' "$T/q.sh" 2>/dev/null)
grep -qx 'BH-1' <<<"$(cut -f7 <<<"$OUT")" && bad "A: a RUNNER_EXHAUSTED park was offered for a rebuild" || ok
grep -qx 'BH-2' <<<"$(cut -f7 <<<"$OUT")" && bad "A: a class=auth park was offered for a rebuild" || ok
grep -q "pool-deferred-max	-	-	BH-3" <<<"$OUT" && ok || bad "A: an ordinary deferred-max park is no longer offered: $OUT"
grep -q "pool-died-twice	-	-	BH-4" <<<"$OUT" && ok || bad "A: a died-twice park is no longer offered: $OUT"

# ── B. br_abandon writes the ledger row ─────────────────────────────────────
fn br_abandon > "$T/a.sh"
grep -q '^br_abandon() {' "$T/a.sh" && ok || bad "B: could not extract br_abandon"
: > "$T/calls"
H="$H" CALLS="$T/calls" OBSERVE=0 bash -c '
  STAMP() { echo 2026-09-23T13:00:00Z; }
  say() { :; }
  br_load() { echo "{\"attempts\":[]}"; }
  br_close_pr() { return 0; }
  br_record() { :; }
  br_set_outcome() { echo "outcome $*" >> "$CALLS"; }
  br_event() { :; }
  mc_contested_list() { :; }
  mc_slug_of_url() { :; }
  queue_done() { echo "queue_done $*" >> "$CALLS"; }
  job_ledger_put() { printf "ledger|%s|%s|%s\n" "$1" "$2" "$3" >> "$CALLS"; }
  . "$0"
  br_abandon tproj tproj-BH-1681 pool-deferred-max - - "rebuilt fresh 3 times and the ladder is exhausted" BH-1681' "$T/a.sh" 2>/dev/null
grep -qx 'ledger|abandoned|tproj BH-1681|abandoned' "$T/calls" && ok \
  || bad "B: br_abandon did not write the abandoned ledger row: $(tr '\n' ';' < "$T/calls")"
grep -q '^queue_done tproj BH-1681 failed ABANDONED' "$T/calls" && ok || bad "B: the queue row is no longer failed ABANDONED"
# A record with no ticket key has nothing to key a ledger row on.
: > "$T/calls"
H="$H" CALLS="$T/calls" OBSERVE=0 bash -c '
  STAMP() { echo x; }; say() { :; }; br_load() { echo "{}"; }; br_close_pr() { return 0; }
  br_record() { :; }; br_set_outcome() { :; }; br_event() { :; }; mc_contested_list() { :; }; mc_slug_of_url() { :; }
  queue_done() { :; }; job_ledger_put() { echo "ledger $*" >> "$CALLS"; }
  . "$0"; br_abandon tproj tproj-x r - - why -' "$T/a.sh" 2>/dev/null
[ -s "$T/calls" ] && bad "B: a keyless abandon wrote a ledger row: $(cat "$T/calls")" || ok

echo "blocked-resolver-lane-exhausted: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
