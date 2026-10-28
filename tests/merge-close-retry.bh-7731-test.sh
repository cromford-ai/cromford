#!/bin/bash
# tests/merge-close-retry.bh-7731-test.sh — BH-7731: a merged build PR whose
# issue close fails once is retried, not forgotten.
#
# THE DEFECT. mc_settle_merged (bin/lib/mc/settle.sh) writes the PR url to
# state/merge-sweep-done.txt and THEN runs the issue close-out. When that close
# failed (a 502 on the PR read, a 403 on the PATCH), nothing owed it: no
# issue-close-owed marker was written, and bin/merge-sweep.sh skipped the record
# for ever because sweep_seen found the url in the done-file. TK-1364 (#1936)
# and TK-1741 (#2004) stayed open after their merge.
#
# This suite drives the two production entry points: mc_settle_merged (what the
# merge conductor runs for every landing) and bin/merge-sweep.sh as a process.
# It asserts the REST argv (comment POSTs, close PATCHes, PR reads), the marker
# file and the log lines.
#
#   HARNESS_TEST_SANDBOX=1 bash tests/merge-close-retry.bh-7731-test.sh   exit 0 = pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/gh-rest-fx.sh
. "$DIR/tests/lib/gh-rest-fx.sh" || exit 1
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
[ -r "$DIR/bin/lib/mc/settle.sh" ] && [ -r "$DIR/bin/merge-sweep.sh" ] || exit 1

mkdir -p "$T/h/logs" "$T/h/state" "$T/h/env" "$T/h/flags" "$T/h/builds" "$T/h/locks" "$T/tmp"
scratch_install_closure bin/merge-sweep.sh "$T/h" >/dev/null || { echo "FAIL: closure install"; exit 1; }
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
for s in beat.sh deploy-request.sh codegraph-ensure.sh pre-arm-guards.sh lane-alert.sh alert-line.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s"; chmod +x "$T/h/bin/$s"
done
: > "$T/h/env/global.env"
# An issue-driven project (board prefix "-"): the close-out applies.
printf 'mk mk-org/project-6 - - - box-mk\n' > "$T/h/fleet.conf"
ghfx_init
# Tripwire: no suite here may reach the network. curl records every call.
printf '#!/bin/bash\necho "$*" >> "%s/curl-calls"\nprintf '"'"'{"error":"not found"}\\n404\\n'"'"'\n' "$T" > "$T/fakebin/curl"
chmod +x "$T/fakebin/curl"; : > "$T/curl-calls"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
export HARNESS="$T/h" TMPDIR="$T/tmp" PATH="$T/fakebin:$PATH" FLEET_CONF="$T/h/fleet.conf" MC_DETACHED_DEPLOY_VERIFY=0
ghfx_extra <<'SH'
case "$A" in *"-X POST"*"/comments"*)
  for a in "$@"; do case "$a" in body=@*) { cat "${a#body=@}"; printf '\n----\n'; } >> "$GHFX/posted.txt" ;; esac; done ;;
esac
SH
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh" || { echo "FAIL: cannot source the lib"; exit 1; }
mc_init

S=mk-org/project-6
PRURL=https://github.com/mk-org/project-6/pull/1936
H1=aaaaaaaa1111; MSHA=cccccccc3333
CLOG="$T/h/logs/merge-conductor.log"
SLOG="$T/h/logs/merge-sweep.log"
DONE="$T/h/state/merge-sweep-done.txt"
BODY=$'## Summary\nCloses #1364\n\nharness build'
PR_MERGED=$(jq -nc --arg b "$BODY" --arg m "$MSHA" --arg h "$H1" \
  '{number:1936,state:"closed",merged:true,merged_at:"2026-10-20T06:09:00Z",merge_commit_sha:$m,body:$b,user:{login:"cromford-builders[bot]"},head:{sha:$h,ref:"ticket/TK-1364"},base:{ref:"main"},closed_at:"2026-10-20T06:09:00Z"}')

# routes <pr-read-status>: the PR read answers <status>; the issue writes answer.
routes() {
  ghfx_routes_reset
  if [ "$1" = 200 ]; then ghfx_route GET "repos/$S/pulls/1936" 200 "$PR_MERGED"
  else ghfx_route GET "repos/$S/pulls/1936" "$1" '{"message":"Bad Gateway"}'; fi
  ghfx_route GET    "repos/$S/issues/1364/timeline*" 200 '[]'
  ghfx_route GET    "repos/$S" 200 '{"id":1}'   # the sweep's token probe
  ghfx_route POST   "repos/$S/issues/1364/comments" 201 '{"id":1}'
  ghfx_route PATCH  "repos/$S/issues/1364" 200 '{"state":"closed"}'
  ghfx_route GET    "repos/$S/issues/1364" 200 '{"state":"closed","body":"x","labels":[{"name":"ai-build"}]}'
  ghfx_route DELETE "repos/$S/issues/1364/labels/ai-build" 200 '[]'
}
newrec() { # newrec <stamp>: a fresh build record for TK-1364 with an APPROVE review
  rm -rf "$T/h/builds/"*; : > "$DONE"; : > "$T/h/state/merge-sweep-terminal.txt"
  REC="$T/h/builds/pool-mk-TK-1364-$1"; mkdir -p "$REC"
  echo "PR_CREATED $PRURL" > "$REC/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"; echo "$H1" > "$REC/reviewed-sha"
}
resetlogs() { ghfx_log_reset; : > "$CLOG"; : > "$SLOG"; : > "$T/posted.txt"; }
settle() { mc_settle_merged "mk-org/project-6#1936" "$PRURL" mk "$S" ticket/TK-1364 "$REC" - "$H1" "$MSHA" >/dev/null 2>&1; }
sweep_tick() { ( cd "$T" && HARNESS="$T/h" SWEEP_MERGE_SETTLE=0 bash "$T/h/bin/merge-sweep.sh" >/dev/null 2>&1 ) || true; }
n_post()  { grep -c -- "-X POST repos/$S/issues/1364/comments" "$T/gh-argv.log"; }
n_patch() { grep -c -- "-X PATCH repos/$S/issues/1364" "$T/gh-argv.log"; }
n_prread(){ grep -c -- "-X GET repos/$S/pulls/1936" "$T/gh-argv.log"; }

# R1 the conductor's close-out fails (the PR read answers 502): the record owes
# the close, the merge is still recorded, and the log names the lane that retries.
newrec 202610200609; routes 502; resetlogs
settle
[ -f "$REC/issue-close-owed" ] && ok || bad "R1: a failed conductor close must leave $REC/issue-close-owed"
grep -qxF "$PRURL" "$DONE" && ok || bad "R1: the merge is still written to the done-file"
grep -q 'merged but issue #1364 could not be closed (close-deferred:pr-read' "$CLOG" && ok || bad "R1: the conductor logs the failed close (log: $(cat "$CLOG"))"
grep -q 'merge-sweep retries it' "$CLOG" && ok || bad "R1: the log must name merge-sweep as the retry (log: $(cat "$CLOG"))"
grep -q 'reconcile-prs' "$CLOG" && bad "R1: the log must not name bin/reconcile-prs.sh, which never closes an issue" || ok
[ "$(n_patch)" = 0 ] && ok || bad "R1: nothing is closed off an unreadable PR ($(n_patch) PATCHes)"

# R2 the next sweep tick reads the PR as MERGED and retries the owed close:
# one comment, the close, the marker removed.
routes 200; resetlogs
sweep_tick
[ "$(n_post)" = 1 ] && ok || bad "R2: the retry posts exactly one comment (got $(n_post); log: $(cat "$SLOG"))"
[ "$(n_patch)" -ge 1 ] && ok || bad "R2: the retry closes issue #1364 (got $(n_patch) PATCHes)"
[ ! -f "$REC/issue-close-owed" ] && ok || bad "R2: a landed close removes the owed marker"
grep -q "$PRURL closed issue #1364 on $S on retry" "$SLOG" && ok || bad "R2: the sweep logs the close (log: $(cat "$SLOG"))"
grep -c '^Merged in' "$T/posted.txt" | grep -qx 1 && ok || bad "R2: one 'Merged in' comment (posted: $(cat "$T/posted.txt"))"

# R3 a third pass: the debt is paid, so nothing is read and nothing is written.
resetlogs
sweep_tick
[ "$(n_post)" = 0 ] && ok || bad "R3: a third pass posts nothing (got $(n_post))"
[ "$(n_patch)" = 0 ] && ok || bad "R3: a third pass closes nothing (got $(n_patch))"
[ "$(n_prread)" = 0 ] && ok || bad "R3: a third pass reads the PR 0 times (got $(n_prread))"

# R3b a retry that fails again keeps the marker for the next pass.
newrec 202610200610; routes 502; resetlogs
settle
routes 502; resetlogs
sweep_tick
[ -f "$REC/issue-close-owed" ] && ok || bad "R3b: a retry that cannot read the PR keeps the owed marker"
[ "$(n_patch)" = 0 ] && ok || bad "R3b: a retry that cannot read the PR closes nothing"

# R4 a done record with no owed marker is still skipped with 0 PR reads.
newrec 202610200611; routes 200; resetlogs
echo "$PRURL" >> "$DONE"
sweep_tick
[ "$(n_prread)" = 0 ] && ok || bad "R4: a done record with no owed marker reads the PR 0 times (got $(n_prread))"
[ "$(n_post)" = 0 ] && ok || bad "R4: a done record with no owed marker posts nothing"

# R5 a conductor close that succeeds leaves no marker and closes once.
newrec 202610200612; routes 200; resetlogs
settle
[ ! -f "$REC/issue-close-owed" ] && ok || bad "R5: a landed conductor close leaves no owed marker"
grep -q 'closed issue #1364' "$CLOG" && ok || bad "R5: the conductor logs the close (log: $(cat "$CLOG"))"
[ "$(n_post)" = 1 ] && ok || bad "R5: one comment (got $(n_post))"

# Budget: no call left the box.
[ ! -s "$T/curl-calls" ] && ok || bad "budget: curl was called ($(head -3 "$T/curl-calls"))"

echo "merge-close-retry (BH-7731): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
