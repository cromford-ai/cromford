#!/bin/bash
# tests/merge-settle-slice.bh-2477-test.sh — BH-2477 through the production
# entry point: bin/lib/mc/settle.sh:mc_settle_merged, the function that closed
# #2320 after PR #2390 merged a single slice of it.
#
# mc_settle_merged is what bin/merge-conductor.sh runs for every PR it lands. It
# derives the issue from the build KEY and hands the close-out to
# mc_close_shipped. This suite drives it against a routed REST stub and asserts
# the argv (was the issue PATCHed?) and the conductor's own log line (does it say
# "closed" about an issue it left open?), never the source text.
#
#   HARNESS_TEST_SANDBOX=1 bash tests/merge-settle-slice.bh-2477-test.sh   exit 0 = pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/gh-rest-fx.sh
. "$DIR/tests/lib/gh-rest-fx.sh" || exit 1
# The sweep (section W) reads the record's verdict through bin/lib/verdict-parse.sh,
# which needs the catalog's VERDICT_WINDOW_LINES exported (BH-1625).
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
[ -r "$DIR/bin/lib/mc/settle.sh" ] || exit 1   # impact: this suite drives bin/lib/mc/settle.sh

mkdir -p "$T/h/bin/lib/mc" "$T/h/logs" "$T/h/state" "$T/h/env" "$T/h/flags" "$T/h/builds" "$T/tmp"
cp "$DIR/bin/lib/issue-state-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" \
   "$DIR/bin/lib/merge-conductor-lib.sh" "$T/h/bin/lib/"
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
for s in beat.sh deploy-request.sh; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s"; chmod +x "$T/h/bin/$s"; done
: > "$T/h/env/global.env"
# An issue-driven project (board prefix "-"): the close-out applies.
printf 'proj example-org/proj - - - box-proj\n' > "$T/h/fleet.conf"
ghfx_init
export HARNESS="$T/h" TMPDIR="$T/tmp" PATH="$T/fakebin:$PATH" FLEET_CONF="$T/h/fleet.conf" MC_DETACHED_DEPLOY_VERIFY=0
ghfx_extra <<'SH'
case "$A" in *"-X POST"*"/comments"*)
  for a in "$@"; do case "$a" in body=@*) { cat "${a#body=@}"; printf '\n----\n'; } >> "$GHFX/posted.txt" ;; esac; done ;;
esac
SH
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh" || { echo "FAIL: cannot source the lib"; exit 1; }
mc_init

S=example-org/proj
PRURL=https://github.com/example-org/proj/pull/2390
H1=aaaaaaaa1111; MSHA=cccccccc3333
LOG="$T/h/logs/merge-conductor.log"
REFS_BODY=$'## Summary\nRefs #2320\n\nharness build'
CLOSES_BODY=$'## Summary\nCloses #2320\n\nharness build'

setup() { # setup <record-stamp> <pr-body> <timeline-json>
  REC="$T/h/builds/pool-proj-BH-2320-$1"; mkdir -p "$REC"
  echo "PR_CREATED $PRURL" > "$REC/RESULT"
  ghfx_routes_reset; ghfx_log_reset; : > "$LOG"; : > "$T/posted.txt"
  ghfx_route GET    "repos/$S/pulls/2390" 200 "$(jq -nc --arg b "$2" --arg m "$MSHA" '{number:2390,state:"closed",merged_at:"2026-09-25T17:56:00Z",merge_commit_sha:$m,body:$b}')"
  ghfx_route GET    "repos/$S/issues/2320/timeline*" 200 "$3"
  ghfx_route POST   "repos/$S/issues/2320/comments" 201 '{"id":1}'
  ghfx_route PATCH  "repos/$S/issues/2320" 200 '{"state":"closed"}'
  ghfx_route GET    "repos/$S/issues/2320" 200 '{"state":"closed","body":"master","labels":[{"name":"ai-build"}]}'
  ghfx_route DELETE "repos/$S/issues/2320/labels/ai-build" 200 '[]'
}
settle() { mc_settle_merged "example-org/proj#2390" "$PRURL" proj "$S" ticket/bh-2320 "$REC" - "$H1" "$MSHA" >/dev/null 2>&1; }
n_patch() { grep -c -- "-X PATCH repos/$S/issues/2320" "$T/gh-argv.log"; }

KID="[$(jq -nc '{event:"cross-referenced",source:{type:"issue",issue:{number:2407,state:"open",body:"Scope.\nPart of #2320"}}}')]"  # TEST-CHANGE BH-4662: the open child the strip cases now need
# E1 the #2390 shape: the PR says Refs #2320
setup 202609251756 "$REFS_BODY" "$KID"  # TEST-CHANGE BH-4662: one open child, so this case still pins the strip path it was written for (no child now keeps the label)
settle
[ "$(n_patch)" = 0 ] && ok || bad "E1: a Refs PR must never PATCH issue #2320 ($(n_patch) PATCHes)"
# TEST-CHANGE BH-2508: a slice now strips ai-build, so the logged word gains +stripped.
grep -q 'left issue #2320 open, slice delivered (kept-slice:no-keyword+stripped)' "$LOG" && ok \
  || bad "E1: the conductor must log the slice (log: $(cat "$LOG"))"
grep -q 'closed issue #2320' "$LOG" && bad "E1: the conductor must not log 'closed issue #2320' for a slice" || ok
head -1 "$T/posted.txt" | grep -q '^Slice delivered: #2390' && ok || bad "E1: the thread gets 'Slice delivered: #2390' (got $(head -1 "$T/posted.txt"))"
grep -q 'Closing this issue' "$T/posted.txt" && bad "E1: the thread must not be told 'Closing this issue'" || ok

# E2 the plan marks the build as C0, even though the PR says Closes
setup 202609251757 "$CLOSES_BODY" "$KID"  # TEST-CHANGE BH-4662: one open child, so this case still pins the strip path it was written for (no child now keeps the label)
printf '# BH-2320\n\n**The build for THIS ticket is C0.** C1 to C6 are filed as children by the decomposer.\n' > "$REC/plan.md"
settle
[ "$(n_patch)" = 0 ] && ok || bad "E2: a C0 slice must never PATCH the master ($(n_patch) PATCHes)"
grep -q 'left issue #2320 open, slice delivered (kept-slice:plan+stripped)' "$LOG" && ok || bad "E2: the conductor must log the plan slice (log: $(cat "$LOG"))"  # TEST-CHANGE BH-2508: a slice now strips ai-build

# E3 Closes, no children, no marker: the issue closes, as today
setup 202609251758 "$CLOSES_BODY" '[]'
settle
# ≥1, not =1: mc_close_shipped PATCHes, then its strip call re-closes (today's
# behaviour, idempotent, not this ticket's).
[ "$(n_patch)" -ge 1 ] && ok || bad "E3: a Closes PR must PATCH issue #2320 (got $(n_patch))"
grep -q 'closed issue #2320 (ai-build: stripped)' "$LOG" && ok || bad "E3: the conductor must log the close (log: $(cat "$LOG"))"
head -1 "$T/posted.txt" | grep -q '^Merged in' && ok || bad "E3: the close comment is today's 'Merged in' line"

# E4 an open child keeps it open even though the PR says Closes
setup 202609251759 "$CLOSES_BODY" "[$(jq -nc '{event:"cross-referenced",source:{type:"issue",issue:{number:2407,state:"open",body:"Child **C1** of #2320"}}}')]"
settle
[ "$(n_patch)" = 0 ] && ok || bad "E4: an open child must keep the master open ($(n_patch) PATCHes)"
grep -q 'left issue #2320 open, slice delivered (kept-slice:open-children:#2407+stripped)' "$LOG" && ok || bad "E4: log names the child (log: $(cat "$LOG"))"  # TEST-CHANGE BH-2508: a slice now strips ai-build

# ════════════════════════════════════════════════════════════════════════════
# W. bin/merge-sweep.sh, driven: the owed-close retry (sweep_close_issue)
# ════════════════════════════════════════════════════════════════════════════
# A record that owes its issue close, a PR that reads MERGED: the sweep's retry
# branch runs mc_close_shipped with the PR url. A slice settles the debt (owed
# marker cleared, merge recorded) without closing the issue.
cp "$DIR/bin/merge-sweep.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib" && cp -rL "$DIR/bin/lib/ms" "$T/h/bin/lib/" || exit 1   # BH-5242: the sweep loads bin/lib/ms/
cp "$DIR/bin/lib/gh-pr-list.sh" "$T/h/bin/lib/"
cp "$DIR/bin/lib/gh-budget.sh" "$T/h/bin/lib/" 2>/dev/null || true
mkdir -p "$T/h/bin/lib/jobs" "$T/h/locks" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
[ -r "$DIR/bin/lib/verdict-parse.sh" ] && cp "$DIR/bin/lib/verdict-parse.sh" "$T/h/bin/lib/"
for s in codegraph-ensure.sh pre-arm-guards.sh lane-alert.sh; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s"; chmod +x "$T/h/bin/$s"; done
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nprintf '"'"'{"error":"not found"}\\n404\\n'"'"'\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
SLOG="$T/h/logs/merge-sweep.log"
sweep_tick() { ( cd "$T" && HARNESS="$T/h" SWEEP_MERGE_SETTLE=0 bash "$T/h/bin/merge-sweep.sh" >/dev/null 2>&1 ) || true; }
wsetup() { # wsetup <record-stamp> <pr-body> [timeline-json]
  rm -rf "$T/h/builds/"*; : > "$T/h/state/merge-sweep-done.txt"; : > "$T/h/state/merge-sweep-terminal.txt"; : > "$SLOG"
  setup "$1" "$2" "${3:-[]}"  # TEST-CHANGE BH-4662: the timeline is now a parameter (default unchanged) so W1 can carry a child
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"; echo "$H1" > "$REC/reviewed-sha"
  touch "$REC/issue-close-owed"
}

# W1 Refs: the retry leaves the issue open, settles the debt, records the merge
wsetup 202609251800 "$REFS_BODY" "$KID"  # TEST-CHANGE BH-4662: one open child, so this case still pins the strip path it was written for (no child now keeps the label)
sweep_tick
[ "$(n_patch)" = 0 ] && ok || bad "W1: the sweep retry must never PATCH a Refs PR's issue ($(n_patch))"
# TEST-CHANGE BH-2508: a slice now strips ai-build, so the logged word gains +stripped.
grep -q 'left issue #2320 on example-org/proj open on retry, slice delivered (kept-slice:no-keyword+stripped)' "$SLOG" && ok \
  || bad "W1: the sweep must log the slice (log: $(cat "$SLOG"))"
grep -q 'closed issue #2320' "$SLOG" && bad "W1: the sweep must not log 'closed issue' for a slice" || ok
[ ! -f "$REC/issue-close-owed" ] && ok || bad "W1: a slice settles the close-out, so the owed marker is cleared"
grep -qxF "$PRURL" "$T/h/state/merge-sweep-done.txt" && ok || bad "W1: a settled slice records the merge"
head -1 "$T/posted.txt" | grep -q '^Slice delivered: #2390' && ok || bad "W1: the thread gets 'Slice delivered: #2390' (got $(head -1 "$T/posted.txt"))"

# W2 Closes: the retry closes, as today (the positive control for W1)
wsetup 202609251801 "$CLOSES_BODY"
sweep_tick
[ "$(n_patch)" -ge 1 ] && ok || bad "W2: the sweep retry must close a Closes PR's issue (log: $(cat "$SLOG"))"
grep -q 'closed issue #2320 on example-org/proj on retry' "$SLOG" && ok || bad "W2: the sweep must log the close (log: $(cat "$SLOG"))"

echo "merge-settle-slice (BH-2477): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
