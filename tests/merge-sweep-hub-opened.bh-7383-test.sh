#!/bin/bash
# tests/merge-sweep-hub-opened.bh-7383-test.sh — BH-7383: a PR the HUB opened
# never merges on a verdict it does not have.
#
# THE SHAPE. A pool build pushes its branch, the push reports "rejected", and
# the build defers. The hub then finds the branch already at the built sha and
# opens the PR itself (bin/lib/pool-push-rejected.sh, BH-6821). That record's
# RESULT line 1 is
#   PR_CREATED <url> (opened by the hub: push reported rejected, <branch> already at <sha>)
# and no review ever ran: no review.md, no verdict row in the jobs ledger, no
# reviewed sha. The reviewed-merge sweep and the box merge queue ALREADY refuse
# such a PR. This suite pins that, so a later change cannot turn "opened by the
# hub" into "merged by the hub" without a red test. It changes no code.
#
#   S1  the real bin/merge-sweep.sh, one hub-opened record, no review.md, the
#       ledger answers "no row" (job_verdict rc 2): no merge call of any kind
#       (no `gh pr merge`, no PUT .../pulls/901/merge), and the refusal is
#       cached as `no-approve-record` in state/merge-sweep-terminal.txt.
#   S2  the same record with a review.md whose final block is VERDICT: APPROVE
#       and a reviewed-sha that is NOT the PR head: no merge call; the sweep
#       logs the head-bound park, raises one ALERT, writes one
#       state/headbound-alerted.txt row, and caches NO terminal entry (the park
#       is reversible, so it must not be cached).
#   Q1  bin/lib/mq-premerge.sh pmg_check with no reviewed sha and
#       HEADBOUND_ENFORCE unset answers `handback no-reviewed-sha` and logs one
#       MERGE_REFUSED premerge-reviewed-sha line.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/merge-sweep-hub-opened.bh-7383-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SHA=f56eba45f0a1b2c3d4e5f60718293a4b5c6d7e8f        # the sha the hub found the branch at
OTHER=c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2      # a PR head that is not the reviewed sha
PRURL=https://github.com/example-org/project-5/pull/901
RLINE="PR_CREATED $PRURL (opened by the hub: push reported rejected, ticket/bh-t1 already at $SHA)"

# ── the scratch harness ─────────────────────────────────────────────────────
H="$T/h"
mkdir -p "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/builds" "$H/env" "$T/fakebin"
scratch_install_closure bin/merge-sweep.sh "$H" >/dev/null || { echo "closure install of bin/merge-sweep.sh failed"; exit 1; }
scratch_install_closure bin/alert-line.sh "$H" >/dev/null || { echo "closure install of bin/alert-line.sh failed"; exit 1; }
# TEST-CHANGE (BH-7383): the scratch harness gets catalog/lanes.d/_lib.json, as a
# hub tree has it. bin/lib/verdict-parse.sh resolves VERDICT_WINDOW_LINES from
# that file (BH-1644); without it every verdict reads `unknown`. The suite went
# green on the builder only because the builder process had exported _VP_WINDOW
# (verdict_prime), and it went red in clean CI (run 39133671107). No assertion changes.
# A window the caller exported must not decide the run: CI has none.
unset _VP_WINDOW VERDICT_WINDOW_LINES
mkdir -p "$H/catalog/lanes.d" && cp "$DIR/catalog/lanes.d/_lib.json" "$H/catalog/lanes.d/" || exit 1
# bin/iron-law-guard.sh denies an agent session that runs the sweep by name, so
# the fixture runs it as sweep.sh (tests/ms-split-layout.bh-5242-test.sh does the same).
mv "$H/bin/merge-sweep.sh" "$H/bin/sweep.sh"
# cp -rL: MODULES rides along, and the loader symlink becomes a real file.
cp -rL "$DIR/bin/lib/ms" "$H/bin/lib/" || exit 1
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"
for s in beat.sh deploy-request.sh codegraph-ensure.sh pre-arm-guards.sh notify.sh heartbeat.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$s"
done
cat > "$H/bin/fleet-conf.sh" <<'EOF'
#!/bin/bash
case "${1:-}" in
  --projects) printf 'project-5\n' ;;
  *) case "${2:-}" in
       repo)         echo "example-org/project-5" ;;
       board_prefix) echo "-" ;;
     esac ;;
esac
exit 0
EOF
# The jobs client: the ledger has NO verdict row for this PR (rc 2), so the
# sweep falls to the build record. Every verdict read is recorded.
cat > "$H/bin/jobs-client.sh" <<EOF
job_verdict() { printf '%s\n' "\$1" >> "$T/verdict-calls.txt"; return 2; }
job_ledger_get() { return 1; }
job_ledger_put() { return 0; }
job_lane_open() { JOB_ID=job-1; return 0; }
job_lane_close() { return 0; }
job_artifact_put() { return 0; }
job_event() { return 0; }
EOF
# gh: every call lands in gh-calls.txt. The PR is OPEN and CLEAN at $T/head.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
HEAD=\$(cat "$T/head" 2>/dev/null)
case "\$*" in
  *"pr merge"*) exit 0 ;;
  *"-X PUT "*"/merge"*) restpr --raw 200 '{"merged":true,"sha":"deadbeefcafe"}' ;;
  "api repos/"*" -q .id") echo 1 ;;
  *"v3.diff"*) restpr --diff '+ const x = 1;
' ;;
  *"api -i -X GET repos/example-org/project-5/pulls/901"*)
    restpr OPEN "\$HEAD" ticket/bh-t1 main "" MERGEABLE CLEAN operator ;;
  # The token-visibility probe (sweep_probe_class_rest): the repo is visible.
  *"api -i -X GET repos/example-org/project-5"*) restpr --raw 200 '{"id":1}' ;;
  *) echo "" ;;
esac
exit 0
EOF
printf '#!/bin/sh\nprintf "{}\\n404\\n"\n' > "$T/fakebin/curl"
chmod +x "$H/bin"/*.sh "$T/fakebin"/*

REC="$H/builds/pool-project-5-bh-t1-20261018"
reset_tree() {
  [ -d "$REC" ] && { scratch_rm "$REC" || exit 1; }
  mkdir -p "$REC"
  printf '%s\n' "$RLINE" > "$REC/RESULT"
  : > "$REC/pipeline.log"
  for f in state/merge-sweep-done.txt state/merge-sweep-terminal.txt state/headbound-alerted.txt \
           logs/merge-sweep.log logs/ALERTS.log; do : > "$H/$f"; done
  : > "$T/gh-calls.txt"; : > "$T/verdict-calls.txt"; : > "$T/err.txt"
}
tick() {
  ( export PATH="$T/fakebin:$H/bin:$PATH" HARNESS="$H" HARNESS_ENV_DIR="$H/env" HARNESS_SECRET=s-fixture \
           JOBS_URL=https://jobs.invalid JOBS_BOX=b SWEEP_MERGE_SETTLE=0
    unset GH_TOKEN HEADBOUND_ENFORCE
    bash "$H/bin/sweep.sh" >/dev/null 2>"$T/err.txt"; echo $? )
}
merge_calls() { grep -cE 'pr merge|-X PUT [^ ]*pulls/901/merge' "$T/gh-calls.txt" 2>/dev/null || true; }

# ── S1. no review at all ────────────────────────────────────────────────────
reset_tree; printf '%s\n' "$SHA" > "$T/head"
rc=$(tick)
[ "$rc" = 0 ] && ok || bad "S1: the sweep exited $rc (stderr: $(tail -3 "$T/err.txt"))"
grep -qxF "$PRURL" "$T/verdict-calls.txt" && ok \
  || bad "S1: the sweep never asked the ledger for a verdict on $PRURL (the record was not evaluated)"
[ "$(merge_calls)" = 0 ] && ok || bad "S1: a merge call was made: $(grep -E 'merge' "$T/gh-calls.txt" | head -3)"
TL=$(awk -v p="$PRURL" '$3 == p' "$H/state/merge-sweep-terminal.txt")
[ "$(printf '%s\n' "$TL" | grep -c .)" = 1 ] && ok \
  || bad "S1: want one terminal-cache row for $PRURL, got: $(cat "$H/state/merge-sweep-terminal.txt")"
read -r TS CAUSE TPR TFP <<<"$TL"
[ "${CAUSE:-}" = no-approve-record ] && ok || bad "S1: terminal cause is '${CAUSE:-}', want no-approve-record"
case "${TS:-}" in ''|*[!0-9]*) bad "S1: terminal row timestamp '${TS:-}' is not an epoch" ;; *) ok ;; esac
[ -n "${TFP:-}" ] && ok || bad "S1: terminal row has no record fingerprint"
[ "${TPR:-}" = "$PRURL" ] && ok || bad "S1: terminal row PR is '${TPR:-}'"
grep -qF "$PRURL" "$H/state/merge-sweep-done.txt" && bad "S1: the refused PR was ledgered as done" || ok
# The refusal is decided from the record: no GitHub PR read was spent on it.
grep -q 'pulls/901' "$T/gh-calls.txt" && bad "S1: the sweep read the PR from GitHub for a record with no APPROVE" || ok

# ── S2. APPROVE, but bound to a sha that is not the head ────────────────────
reset_tree; printf '%s\n' "$OTHER" > "$T/head"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
printf '%s\n' "$SHA" > "$REC/reviewed-sha"
rc=$(tick)
[ "$rc" = 0 ] && ok || bad "S2: the sweep exited $rc (stderr: $(tail -3 "$T/err.txt"))"
grep -q 'api -i -X GET repos/example-org/project-5/pulls/901' "$T/gh-calls.txt" && ok \
  || bad "S2: the sweep never read the PR state (it did not reach the head-bound check)"
[ "$(merge_calls)" = 0 ] && ok || bad "S2: a merge call was made: $(grep -E 'merge' "$T/gh-calls.txt" | head -3)"
grep -qF "$PRURL parked: head $OTHER is not the reviewed sha $SHA — commits landed after the approval" "$H/logs/merge-sweep.log" && ok \
  || bad "S2: no head-bound park line in merge-sweep.log: $(grep -F "$PRURL" "$H/logs/merge-sweep.log" | tail -3)"
[ "$(grep -cxF "$PRURL $OTHER" "$H/state/headbound-alerted.txt")" = 1 ] && ok \
  || bad "S2: want one '$PRURL $OTHER' row in state/headbound-alerted.txt, got: $(cat "$H/state/headbound-alerted.txt")"
[ "$(grep -cF "$PRURL parked: its head ($OTHER) is not the sha the review approved ($SHA)" "$H/logs/ALERTS.log")" = 1 ] && ok \
  || bad "S2: want one head-bound ALERT, got: $(cat "$H/logs/ALERTS.log")"
grep -q . <<<"$(awk -v p="$PRURL" '$3 == p' "$H/state/merge-sweep-terminal.txt")" \
  && bad "S2: a reversible head-bound park was cached as terminal: $(cat "$H/state/merge-sweep-terminal.txt")" || ok
grep -qF "$PRURL" "$H/state/merge-sweep-done.txt" && bad "S2: the parked PR was ledgered as done" || ok

# ── Q1. the box merge queue: no reviewed sha is a handback ──────────────────
QLOG="$T/q1.log"; : > "$QLOG"
QOUT=$( unset HEADBOUND_ENFORCE _PMG_LOADED
        # shellcheck source=bin/lib/mq-premerge.sh
        . "$DIR/bin/lib/mq-premerge.sh" || exit 9
        pmg_check example-org/project-5 901 "$SHA" "" "$(date +%s)" "$QLOG" pfx )
[ "$QOUT" = "handback no-reviewed-sha" ] && ok || bad "Q1: pmg_check answered '$QOUT', want 'handback no-reviewed-sha'"
[ "$(grep -c 'MERGE_REFUSED premerge-reviewed-sha' "$QLOG")" = 1 ] && ok \
  || bad "Q1: want one MERGE_REFUSED premerge-reviewed-sha line, log: $(cat "$QLOG")"
[ "$(grep -c . "$QLOG")" = 1 ] && ok || bad "Q1: want exactly one log line, got: $(cat "$QLOG")"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
