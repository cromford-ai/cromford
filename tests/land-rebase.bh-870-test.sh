#!/bin/bash
# tests/land-rebase.bh-870-test.sh — the LAND-TRIGGERED REBASE (BH-870).
#
# WHAT IT PINS. A merge to a project's main used to be an event nothing acted
# on: the conductor only rebases a PR GitHub has already marked DIRTY, and
# merge_tree_clean then declines even that when the head still merges clean. So
# an open PR sat on the base it was cut from until it CONFLICTED, and the
# conflict is the expensive way to find out main moved. BH-870 adds one arm:
# when `git ls-remote` says this project's base has a sha we have not handled,
# every open PR of that repo whose row this lane may move is offered a
# mechanical rebase in that same tick.
#
# WHY DRIVEN AND NOT GREPPED. Every claim below is read off what the run DID —
# logs/merge-conductor.log, pr-state.tsv, attempts.txt, the job files under
# state/merge-conductor/rebase, the fake git's argv log and the fake pool
# queue. A regex over bin/merge-conductor.sh would pass on an arm that is
# defined and never called, which is exactly the shape D27 exists to catch.
#
# Run from anywhere: tests/land-rebase.bh-870-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq    >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh): every age a
# fixture needs is derived from it, so nothing here depends on the wall clock.
NOW=$(date -u +%s)

MAIN1=a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1
MAIN2=b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2
H21=2121212121212121212121212121212121212121
NEW21=9999999999999999999999999999999999999999
H22=2222222222222222222222222222222222222222
H23=2323232323232323232323232323232323232323
H24=2424242424242424242424242424242424242424
H25=2525252525252525252525252525252525252525
H26=2626262626262626262626262626262626262626
H27=2727272727272727272727272727272727272727
SLUG=example-org/demo-os
U21="https://github.com/$SLUG/pull/21"

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" \
         "$T/h/env" "$T/h/tmp" "$T/fakebin" "$T/repos"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$T/h/bin/lib/"
# BH-1586: mc_ci_state reads the run list through gh_rest, so the fixture carries
# the library and the stub answers that read as a whole HTTP response.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
# BH-2504: the conductor pushes only through bin/lib/hold-push.sh (+ hold.sh).
cp "$DIR/bin/lib/hold-push.sh" "$DIR/bin/lib/hold.sh" "$T/h/bin/lib/"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/deploy-request.sh" "$T/h/bin/"
printf 'demo-os %s https://demo.example /api/board 2 box-demo\n' "$SLUG" > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf 'job_verdict_rebind() { return 0; }\n' > "$T/h/bin/jobs-client.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$T/lane-alerts.txt" > "$T/h/bin/lane-alert.sh"
chmod +x "$T/h/bin/lane-alert.sh"
printf '#!/bin/bash\nprintf "VERDICT: APPROVE\\n" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"
chmod +x "$T/h/bin/agent-call.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/deploy-verify.sh"; chmod +x "$T/h/bin/deploy-verify.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/prod-url.sh"; chmod +x "$T/h/bin/prod-url.sh"
touch "$T/h/flags/merge-conductor-actions"

# --- the controllable fake git ----------------------------------------------
# Three answers this lane needs and no other fixture has: what `ls-remote` says
# the base sha is, whether `merge-tree` finds a conflict, and whether the head
# already contains main. Each is a control FILE so a section sets it without
# rewriting the script.
echo "$MAIN1" > "$T/ctl-main-sha"
echo 0        > "$T/ctl-lsremote-rc"
echo 0        > "$T/ctl-mergetree-rc"
echo 1        > "$T/ctl-ancestor-rc"    # 1 = the head does NOT contain main yet
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
A="\$*"
printf '%s\n' "\$A" >> "$T/git-argv.txt"
case "\$A" in
  *--version*) echo "git version 2.45.0"; exit 0 ;;
  # mc_git_auth probes with \`ls-remote <url> HEAD\` and must keep working even
  # while the base-ref read is being failed on purpose.
  *ls-remote*"refs/heads/"*)
      RC=\$(cat "$T/ctl-lsremote-rc" 2>/dev/null || echo 0)
      [ "\$RC" = 0 ] || exit "\$RC"
      printf '%s\trefs/heads/main\n' "\$(cat "$T/ctl-main-sha")"; exit 0 ;;
  *ls-remote*) echo "0000000000000000000000000000000000000000	HEAD"; exit 0 ;;
  *merge-tree*)
      RC=\$(cat "$T/ctl-mergetree-rc" 2>/dev/null || echo 0)
      [ "\$RC" = 1 ] && { printf 'tree0000\n\nsrc/x.ts\n'; exit 1; }
      exit "\$RC" ;;
  *"merge-base --is-ancestor"*) exit "\$(cat "$T/ctl-ancestor-rc" 2>/dev/null || echo 1)" ;;
  *merge-base*) echo base0000base0000; exit 0 ;;
  *" merge "*)  sleep "\${FAKE_GIT_MERGE_SLEEP:-0}"; exit 0 ;;
  *rev-parse*)  if [ -f "$T/rev2" ]; then printf '%s\n' "$NEW21"; else touch "$T/rev2"; printf '%s\n' "$H21"; fi; exit 0 ;;
  *patch-id*)   md5sum | cut -d' ' -f1; exit 0 ;;
  *" diff "*)   printf 'a stable patch\n'; exit 0 ;;
  *push*)       touch "$T/pushed"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/git"

# --- the fake gh: the open-PR list comes from a control file ----------------
# No write verb is expected anywhere in this file; one is a failure.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"auth token"*) echo faketoken ;;
  *"pr merge"*|*"issue close"*|*"pr review"*) echo "WRITE VERB: \$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"pr list -R $SLUG --state open"*) cat "$T/prlist.json" ;;
  *"pr list"*) echo "" ;;
  *"pulls/22"*"v3.diff"*) restpr --diff $'+++ b/src/x.ts\n+if (window.confirm("sure?")) go();\n' ;;
  *"actions/runs"*)
      case "\$*" in
        *"$H23"*) restpr --runs 'completed|failure' ;;
        *) restpr --runs 'completed|success' ;;
      esac ;;
  *"pr view"*"--json mergeCommit"*) printf '%s\n' "$NEW21" ;;
  *"pr view"*"--json body"*) echo "plain body" ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
: > "$T/gh-writes.txt"; : > "$T/git-argv.txt"

# PR <num> <head> <mergeState> <mergeable> <labels-json> <baseRefName>
PR() {
  jq -nc --argjson n "$1" --arg u "https://github.com/$SLUG/pull/$1" --arg h "$2" \
     --arg b "ticket/pb-$1" --arg ms "$3" --arg mg "$4" --argjson l "$5" --arg base "$6" \
     '{number:$n,url:$u,headRefOid:$h,headRefName:$b,isDraft:false,mergeStateStatus:$ms,
       mergeable:$mg,state:"OPEN",labels:$l,baseRefName:$base}'
}
PRLIST() { local IFS=","; printf '[%s]\n' "$*" > "$T/prlist.json"; }
# REC <num> <head> — the build record that makes a PR the harness's and approved
# at exactly that head.
REC() {
  local d="$T/h/builds/demo-os-TK-$1-20260912002$1"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/$SLUG/pull/$1" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  echo "$2" > "$d/reviewed-sha"
  printf '%s' "$d"
}
R21=$(REC 21 "$H21"); REC 22 "$H22" >/dev/null; REC 23 "$H23" >/dev/null
REC 24 "$H24" >/dev/null; REC 25 "$H25" >/dev/null; REC 26 "$H26" >/dev/null
REC 27 "$H27" >/dev/null

export PATH="$T/fakebin:$PATH"
# shellcheck source=/dev/null
# TEST-CHANGE (BH-8035): every conductor rebase spawn asks mc_rebase_gate, which
# loads bin/lib/migration-hold.sh and reads the hold rows, and defers when it
# cannot. This suite has no hold rows: the lib is installed, setting_get says "no row".
scratch_install_closure bin/lib/migration-hold.sh "$T/h" >/dev/null || { echo "closure install failed"; exit 1; }
setting_get() { return 2; }; export -f setting_get
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init

ST="$T/h/state/merge-conductor"
LANDF="$ST/land/demo-os"
LOG="$T/h/logs/merge-conductor.log"
tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" MC_REPOS="$T/repos" \
            MC_RR_PATH="$T/fakebin:$PATH" "$@" bash "$T/h/bin/merge-conductor.sh" \
            >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
state_of()  { awk -F'\t' -v k="$1" '$1==k {print $2}' "$ST/pr-state.tsv"; }
rev_of()    { awk -F'\t' -v k="$1" '$1==k {print $5}' "$ST/pr-state.tsv"; }
head_of()   { awk -F'\t' -v k="$1" '$1==k {print $4}' "$ST/pr-state.tsv"; }
jobs_n()    { ls "$ST"/rebase/*.json 2>/dev/null | wc -l | tr -d ' '; }
merges_n()  { grep -c -- ' merge -q --no-edit ' "$T/git-argv.txt" 2>/dev/null || true; }
logn()      { grep -c -- "$1" "$LOG" 2>/dev/null || true; }
wait_status() {
  local f="$1" want="$2" i
  for i in $(seq 1 200); do [ "$(jq -r .status "$f" 2>/dev/null)" = "$want" ] && return 0; sleep 0.2; done
  return 1
}
# RESET — back to "one eligible PR 21, nothing handled, nothing spawned".
RESET() {
  scratch_rm "$ST/land"; scratch_rm "$ST/rebase"; mkdir -p "$ST/rebase"
  : > "$ST/pr-state.tsv"; : > "$ST/attempts.txt"; : > "$LOG"
  : > "$T/git-argv.txt"; rm -f "$T/rev2" "$T/pushed"
  echo "$H21" > "$R21/reviewed-sha"
  echo "$MAIN1" > "$T/ctl-main-sha"; echo 0 > "$T/ctl-lsremote-rc"
  echo 0 > "$T/ctl-mergetree-rc"; echo 1 > "$T/ctl-ancestor-rc"
  PRLIST "$(PR 21 "$H21" BEHIND MERGEABLE '[]' main)"
}

# ============================================================================
# 0. THE HELPERS, driven directly as the pure functions they are
# ============================================================================
mkdir -p "$ST/land"
[ "$(MC_REPOS="$T/repos" mc_land_main_sha "$SLUG" main)" = "$MAIN1" ] && ok \
  || bad "mc_land_main_sha must print the sha ls-remote serves (got '$(MC_REPOS="$T/repos" mc_land_main_sha "$SLUG" main)')"
echo "not-a-sha" > "$T/ctl-main-sha"
OUT=$(MC_REPOS="$T/repos" mc_land_main_sha "$SLUG" main); RC=$?
{ [ "$RC" = 1 ] && [ -z "$OUT" ]; } && ok || bad "a non-sha ls-remote answer must be rc 1 with empty stdout (rc $RC out '$OUT')"
echo "$MAIN1" > "$T/ctl-main-sha"; echo 2 > "$T/ctl-lsremote-rc"
OUT=$(MC_REPOS="$T/repos" mc_land_main_sha "$SLUG" main); RC=$?
{ [ "$RC" = 1 ] && [ -z "$OUT" ]; } && ok || bad "an ls-remote that exits nonzero must be rc 1 with empty stdout (rc $RC out '$OUT')"
echo 0 > "$T/ctl-lsremote-rc"
OUT=$(mc_land_main_sha "$SLUG" 'evil;rm -rf /'); RC=$?
{ [ "$RC" = 1 ] && [ -z "$OUT" ]; } && ok || bad "an unsafe base name must never reach git (rc $RC out '$OUT')"
[ -z "$(mc_land_prev demo-os)" ] && ok || bad "mc_land_prev on a missing file must print nothing"
if mc_land_prev demo-os >/dev/null; then ok; else bad "mc_land_prev on a missing file must still be rc 0"; fi
mc_land_record demo-os "$MAIN1"
[ "$(mc_land_prev demo-os)" = "$MAIN1" ] && ok || bad "mc_land_record/mc_land_prev must round-trip (got '$(mc_land_prev demo-os)')"
mc_land_record demo-os "$MAIN2"
[ "$(mc_land_prev demo-os)" = "$MAIN2" ] && ok || bad "mc_land_record must overwrite, not append (got '$(mc_land_prev demo-os)')"
rm -f "$LANDF"

MC_REPOS="$T/repos" mc_land_needed "$SLUG" demo-os "$H21" 21 "$MAIN2" >/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "a clean head that lacks main must be rc 0 (rebase it), got $RC"
echo 0 > "$T/ctl-ancestor-rc"
MC_REPOS="$T/repos" mc_land_needed "$SLUG" demo-os "$H21" 21 "$MAIN2" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "a head that already contains main must be rc 1 (nothing to do), got $RC"
echo 1 > "$T/ctl-ancestor-rc"; echo 1 > "$T/ctl-mergetree-rc"
OUT=$(MC_REPOS="$T/repos" mc_land_needed "$SLUG" demo-os "$H21" 21 "$MAIN2"); RC=$?
{ [ "$RC" = 2 ] && [ -n "$OUT" ]; } && ok || bad "a conflicting head must be rc 2 with the paths on stdout (rc $RC out '$OUT')"
echo 4 > "$T/ctl-mergetree-rc"
OUT=$(MC_REPOS="$T/repos" mc_land_needed "$SLUG" demo-os "$H21" 21 "$MAIN2"); RC=$?
{ [ "$RC" = 3 ] && [ -n "$OUT" ]; } && ok || bad "a merge-tree that could not tell must be rc 3 with a reason (rc $RC out '$OUT')"
echo 0 > "$T/ctl-mergetree-rc"
OUT=$(MC_REPOS="$T/repos" mc_land_needed "$SLUG" demo-os - 21 "$MAIN2"); RC=$?
[ "$RC" = 3 ] && ok || bad "no head sha must be rc 3, never rc 0 (got $RC)"

# the 7th argument of mc_rebase_spawn: the land lane's own ceiling
mc_rb_write "$ST/rebase/other.json" running "$$" "$NOW" 0 - deadbeef - /dev/null
mc_rebase_spawn "$SLUG" 91 demo-os ticket/TK-91 "$H21" "https://github.com/$SLUG/pull/91" 1; RC=$?
[ "$RC" = 3 ] && ok || bad "mc_rebase_spawn with a cap of 1 and one job running must answer rc 3 (got $RC)"
[ -f "$(mc_rb_file "$SLUG" 91 "$H21")" ] && bad "a refused spawn must write no job file" || ok
mc_rebase_spawn "$SLUG" 91 demo-os ticket/TK-91 "$H21" "https://github.com/$SLUG/pull/91" 0; RC=$?
[ "$RC" = 0 ] && ok || bad "mc_rebase_spawn with a cap of 0 (unlimited) must spawn (got $RC)"
# Waited out rather than killed: a job still writing its file would recreate it
# under the next section's feet and every job-count assertion below would be
# about this one.
wait_status "$(mc_rb_file "$SLUG" 91 "$H21")" done >/dev/null
scratch_rm "$ST/rebase"; mkdir -p "$ST/rebase"

# ============================================================================
# 1. THE FIRST TICK IS A BASELINE, never a fan-out
#    Seven repos rolling this out at once must not all rebase every open PR on
#    the first */5 after the deploy.
# ============================================================================
RESET
tick
[ "$(cat "$LANDF" 2>/dev/null)" = "$MAIN1" ] && ok \
  || bad "the first tick must record the base sha (got '$(cat "$LANDF" 2>/dev/null)')"
grep -q "demo-os LAND baseline" "$LOG" && ok || bad "the baseline must say so in the log"
[ "$(jobs_n)" = 0 ] && ok || bad "the baseline tick must spawn no rebase ($(jobs_n) job files)"
[ "$(merges_n)" = 0 ] && ok || bad "the baseline tick must run no git merge"
grep -q "LAND main moved" "$LOG" && bad "a baseline is not a landing" || ok

# ============================================================================
# 2. A MERGE TO MAIN REBASES EVERY OPEN main-BASED PR, IN THAT TICK
#    spawn -> job -> the existing rebase_consume -> WAIT_CI on the pushed head
#    with the approval rebound. That last half is R8: nothing here invents a
#    rebind, it reuses mc_rebase's.
# ============================================================================
echo "$MAIN2" > "$T/ctl-main-sha"
tick env FAKE_GIT_MERGE_SLEEP=6
RBJ=$(mc_rb_file "$SLUG" 21 "$H21")
grep -q "demo-os LAND main moved ${MAIN1:0:8} -> ${MAIN2:0:8}" "$LOG" && ok \
  || bad "the landing must be logged with both shas: $(grep LAND "$LOG" | tail -3)"
grep -q "$SLUG#21 LAND_REBASE_SPAWNED main ${MAIN2:0:8}" "$LOG" && ok \
  || bad "the spawn must name the triggering sha (R11): $(grep LAND "$LOG" | tail -5)"
[ -f "$RBJ" ] && ok || bad "a WAIT_CI PR behind main must get a rebase job ($RBJ)"
[ "$(mc_rb_state "$RBJ")" = running ] && ok || bad "the land rebase must be detached and still running (got $(mc_rb_state "$RBJ"))"
[ "$(state_of "$SLUG#21")" = REBASING ] && ok || bad "the row must move to REBASING (got $(state_of "$SLUG#21"))"
grep -qxF "landrebase $SLUG#21 $MAIN2" "$ST/attempts.txt" && ok \
  || bad "the per-(PR, sha) marker must be written after the spawn"
[ "$(cat "$LANDF")" = "$MAIN2" ] && ok \
  || bad "every PR got its answer this tick, so the sha is handled and recorded (got '$(cat "$LANDF")')"
wait_status "$RBJ" done && ok || bad "the land rebase never finished (status $(jq -r .status "$RBJ" 2>/dev/null))"
[ "$(jq -r .rc "$RBJ")" = 0 ] && ok || bad "the job must record mc_rebase's rc (got $(jq -r .rc "$RBJ"))"
tick
[ "$(state_of "$SLUG#21")" = WAIT_CI ] && ok || bad "the consumed rc-0 rebase must land WAIT_CI (got $(state_of "$SLUG#21"))"
[ "$(head_of "$SLUG#21")" = "$NEW21" ] && ok || bad "…on the pushed head (got $(head_of "$SLUG#21"))"
[ "$(rev_of "$SLUG#21")" = "$NEW21" ] && ok || bad "…with the approval rebound to it (got $(rev_of "$SLUG#21"))"
[ "$(cat "$LANDF")" = "$MAIN2" ] && ok || bad "once nothing is deferred the handled sha must be recorded (got '$(cat "$LANDF")')"
grep -q "demo-os LAND main ${MAIN2:0:8} handled:" "$LOG" && ok || bad "a completed fan-out must log its counts"
[ -s "$T/gh-writes.txt" ] && bad "a write verb ran: $(cat "$T/gh-writes.txt")" || ok

# ============================================================================
# 3. IDEMPOTENT: the same sha again is no rebase work at all
# ============================================================================
NJ=$(jobs_n); NM=$(merges_n); NMOVED=$(logn "LAND main moved")
tick
[ "$(logn "LAND main moved")" = "$NMOVED" ] && ok || bad "an unchanged main must log no second landing"
[ "$(jobs_n)" = "$NJ" ] && ok || bad "an unchanged main must spawn no rebase"
[ "$(merges_n)" = "$NM" ] && ok || bad "an unchanged main must run no git merge"

# ============================================================================
# 4. THE SKIPS. Every row this lane may NOT move, in one tick.
#    22 parked on a reason the resolver owns, 23 RED_TWICE, 24 carrying
#    Mergify's terminal `dequeued` label, 25 carrying `predequeued` (which is
#    NOT that label), 26 based on a feature branch, 27 READY.
# ============================================================================
RESET
PRLIST "$(PR 22 "$H22" CLEAN MERGEABLE '[]' main)" \
       "$(PR 23 "$H23" BEHIND MERGEABLE '[]' main)" \
       "$(PR 24 "$H24" BEHIND MERGEABLE '[{"name":"dequeued"}]' main)" \
       "$(PR 25 "$H25" BEHIND MERGEABLE '[{"name":"predequeued"}]' main)" \
       "$(PR 26 "$H26" BEHIND MERGEABLE '[]' feature/x)" \
       "$(PR 27 "$H27" CLEAN MERGEABLE '[]' main)"
# 22: its diff carries an iron-law hit = BLOCKED_HUMAN iron-law, a reason
# mc_resolver_owns, so it displays as BLOCKED_AGENT. CLEAN and green, because the
# scan only runs on a head everything cheaper already calls READY.
# TEST-CHANGE (BH-1671): this fixture used to reach the park as `red-ci-twice`
# (red on two earlier heads). That park counted reds ACROSS heads and is gone:
# red on earlier heads now leaves this head on its own rerun ladder (WAIT_CI).
# iron-law is the park the classifier still gives that is resolver-owned and NOT
# a sticky hand-off (a sticky one never reaches the land arm), so what this case
# pins is unchanged: such a park is named and skipped, never land-rebased.
# 23: its one rerun was dispatched long enough ago to have reported = RED_TWICE.
printf 'cirerun %s#23 %s %s\n' "$SLUG" "$H23" "$((NOW - 4000))" >> "$ST/attempts.txt"
tick   # baseline
echo "$MAIN2" > "$T/ctl-main-sha"
: > "$T/git-argv.txt"
tick
[ "$(state_of "$SLUG#22")" = BLOCKED_HUMAN ] && ok || bad "fixture: PR 22 must classify BLOCKED_HUMAN (got $(state_of "$SLUG#22"))"
awk -F'\t' -v k="$SLUG#22" '$1==k {print $7}' "$ST/pr-state.tsv" | grep -q '^iron-law' && ok \
  || bad "fixture: PR 22's park must be iron-law (got $(awk -F'\t' -v k="$SLUG#22" '$1==k {print $7}' "$ST/pr-state.tsv"))"
grep -q "$SLUG#22 LAND_SKIP parked BLOCKED_AGENT" "$LOG" && ok \
  || bad "a park the resolver owns must be named and skipped: $(grep 'LAND' "$LOG" | tail -8)"
[ -f "$(mc_rb_file "$SLUG" 22 "$H22")" ] && bad "a parked PR must get no land rebase" || ok
[ "$(state_of "$SLUG#23")" = RED_TWICE ] && ok || bad "fixture: PR 23 must classify RED_TWICE (got $(state_of "$SLUG#23"))"
grep -q "$SLUG#23 LAND_SKIP parked RED_TWICE" "$LOG" && ok || bad "RED_TWICE must be named and skipped"
[ -f "$(mc_rb_file "$SLUG" 23 "$H23")" ] && bad "a RED_TWICE PR must get no land rebase" || ok
grep -q "$SLUG#24 LAND_SKIP Mergify dequeued" "$LOG" && ok \
  || bad "the dequeued label must be named and skipped: $(grep 'LAND' "$LOG" | tail -8)"
[ -f "$(mc_rb_file "$SLUG" 24 "$H24")" ] && bad "a dequeued-labelled PR must get no land rebase" || ok
[ -f "$(mc_rb_file "$SLUG" 25 "$H25")" ] && ok \
  || bad "predequeued is not the dequeued label — PR 25 must still be rebased"
[ -f "$(mc_rb_file "$SLUG" 26 "$H26")" ] && bad "a PR based on a feature branch must get no land rebase" || ok
[ "$(logn "$SLUG#26 LAND_")" = 0 ] && ok || bad "a stacked child must be skipped silently, not narrated"
[ "$(state_of "$SLUG#27")" = READY ] && ok || bad "fixture: PR 27 must classify READY (got $(state_of "$SLUG#27"))"
[ -f "$(mc_rb_file "$SLUG" 27 "$H27")" ] && bad "a READY PR is one merge away — it must not be rebased" || ok
[ "$(logn "$SLUG#27 LAND_")" = 0 ] && ok || bad "a READY PR must be skipped silently"
[ "$(cat "$LANDF")" = "$MAIN2" ] && ok \
  || bad "skips are answers, not deferrals: the sha must be recorded (got '$(cat "$LANDF")')"
[ -s "$T/gh-writes.txt" ] && bad "a write verb ran: $(cat "$T/gh-writes.txt")" || ok
for J in "$ST"/rebase/*.json; do [ -f "$J" ] && kill "$(jq -r .pid "$J" 2>/dev/null)" 2>/dev/null; done

# ============================================================================
# 5. A CONFLICT IS HANDED TO THE EXISTING PATH, UNCHANGED (R7)
# ============================================================================
RESET
tick
echo "$MAIN2" > "$T/ctl-main-sha"; echo 1 > "$T/ctl-mergetree-rc"
: > "$T/git-argv.txt"
tick
grep -q "$SLUG#21 LAND_CONFLICT" "$LOG" && ok || bad "a conflicting head must log LAND_CONFLICT: $(grep LAND "$LOG" | tail -4)"
[ "$(jobs_n)" = 0 ] && ok || bad "a conflicting head must not be rebased by THIS lane"
[ "$(merges_n)" = 0 ] && ok || bad "a conflicting head must cost no git merge"
[ "$(state_of "$SLUG#21")" = WAIT_CI ] && ok || bad "the row must be left exactly where it was (got $(state_of "$SLUG#21"))"
grep -qxF "landrebase $SLUG#21 $MAIN2" "$ST/attempts.txt" && ok || bad "a conflict is an answer for this sha and is marked"
[ "$(cat "$LANDF")" = "$MAIN2" ] && ok || bad "a conflict is not a deferral — the sha must be recorded"
grep -q "conflict=1" "$LOG" && ok || bad "the handled line must count the conflict: $(grep 'handled:' "$LOG" | tail -1)"

# ============================================================================
# 6. A HEAD THAT ALREADY CONTAINS MAIN IS NOT REBASED
# ============================================================================
RESET
tick
echo "$MAIN2" > "$T/ctl-main-sha"; echo 0 > "$T/ctl-ancestor-rc"
: > "$T/git-argv.txt"
tick
[ "$(jobs_n)" = 0 ] && ok || bad "a head that already contains main must not be rebased"
[ "$(merges_n)" = 0 ] && ok || bad "…and must cost no git merge"
grep -qxF "landrebase $SLUG#21 $MAIN2" "$ST/attempts.txt" && ok || bad "…and is marked, so the next tick does not ask again"
grep -q "current=1" "$LOG" && ok || bad "the handled line must count it as current: $(grep 'handled:' "$LOG" | tail -1)"
[ "$(logn "$SLUG#21 LAND_")" = 0 ] && ok || bad "a PR that is already current must be silent"

# ============================================================================
# 7. THE HUB CEILING: a 40-PR fan-out must not put 40 worktrees on this box.
#    Over the cap a PR is DEFERRED — the sha is NOT recorded, so the next tick
#    re-offers exactly the PRs this one could not reach (D12).
# ============================================================================
RESET
PRLIST "$(PR 21 "$H21" BEHIND MERGEABLE '[]' main)" \
       "$(PR 25 "$H25" BEHIND MERGEABLE '[]' main)"
tick
echo "$MAIN2" > "$T/ctl-main-sha"
tick env MC_LAND_REBASE_PARALLEL=1 FAKE_GIT_MERGE_SLEEP=10
[ "$(logn "LAND_REBASE_SPAWNED")" = 1 ] && ok \
  || bad "at MC_LAND_REBASE_PARALLEL=1 exactly one land rebase may spawn (got $(logn "LAND_REBASE_SPAWNED"))"
grep -q "LAND_DEFER .*rebases already running (MC_LAND_REBASE_PARALLEL=1)" "$LOG" && ok \
  || bad "the refused spawn must say WHY it was refused: $(grep LAND "$LOG" | tail -4)"
grep -q "demo-os LAND main ${MAIN2:0:8} PARTIAL" "$LOG" && ok \
  || bad "a partial fan-out must say so: $(grep LAND "$LOG" | tail -3)"
[ "$(cat "$LANDF")" = "$MAIN1" ] && ok \
  || bad "a PARTIAL fan-out must NOT record the sha, or the deferred PR is dropped (got '$(cat "$LANDF")')"
[ "$(grep -c "landrebase" "$ST/attempts.txt")" = 1 ] && ok \
  || bad "only the PR that actually spawned may be marked (got $(grep -c landrebase "$ST/attempts.txt"))"
for J in "$ST"/rebase/*.json; do wait_status "$J" done >/dev/null; done
tick
[ "$(logn "LAND_REBASE_SPAWNED")" = 2 ] && ok \
  || bad "the next tick must spawn the PR the cap deferred (got $(logn "LAND_REBASE_SPAWNED"))"
[ "$(cat "$LANDF")" = "$MAIN2" ] && ok \
  || bad "…and only then is the sha recorded (got '$(cat "$LANDF")')"
for J in "$ST"/rebase/*.json; do [ -f "$J" ] && wait_status "$J" done >/dev/null; done

# ============================================================================
# 8. UNDER REBASE_ON_POOL THE WORK LEAVES THE HUB (R9)
# ============================================================================
RESET
touch "$T/h/flags/fly-pool-app-demo-os"
echo 'REBASE_ON_POOL=1' > "$T/h/env/demo-os.env"
cat > "$T/h/bin/jobs-client.sh" <<EOF
job_verdict_rebind() { return 0; }
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
EOF
: > "$T/queue.txt"
tick
echo "$MAIN2" > "$T/ctl-main-sha"
: > "$T/git-argv.txt"
tick
grep -q "$SLUG#21 LAND_REBASE_QUEUED main ${MAIN2:0:8}" "$LOG" && ok \
  || bad "under the pool flag the land rebase must be QUEUED, not spawned: $(grep LAND "$LOG" | tail -4)"
[ "$(wc -l < "$T/queue.txt")" = 1 ] && ok || bad "exactly one queue row (got $(cat "$T/queue.txt"))"
grep -q "RB-21-${H21:0:8}" "$T/queue.txt" && ok || bad "the row must carry the pool rebase key (got $(cat "$T/queue.txt"))"
[ "$(merges_n)" = 0 ] && ok || bad "the hub must run no git merge under the pool flag"
[ "$(state_of "$SLUG#21")" = REBASING ] && ok || bad "the row must be REBASING (got $(state_of "$SLUG#21"))"
grep -qxF "landrebase $SLUG#21 $MAIN2" "$ST/attempts.txt" && ok || bad "a queued pool rebase is spent and is marked"
rm -f "$T/h/flags/fly-pool-app-demo-os" "$T/h/env/demo-os.env"
printf 'job_verdict_rebind() { return 0; }\n' > "$T/h/bin/jobs-client.sh"

# ============================================================================
# 9. THE LANDING IS NOT RATIONED BY THE NEEDS_REBASE TICK BUDGET
#    That budget is the steady-state spend; the whole point of BH-870 is that
#    a merge to main is not metered by it.
# ============================================================================
RESET
tick
echo "$MAIN2" > "$T/ctl-main-sha"
tick env MC_REBASE_BUDGET=0
grep -q "$SLUG#21 LAND_REBASE_SPAWNED" "$LOG" && ok \
  || bad "MC_REBASE_BUDGET=0 must not stop a land rebase: $(grep LAND "$LOG" | tail -4)"
for J in "$ST"/rebase/*.json; do [ -f "$J" ] && wait_status "$J" done >/dev/null; done

# ============================================================================
# 10. THE KILL FLAG. MC_LAND_REBASE=0 is byte-for-byte today's conductor.
# ============================================================================
RESET
tick env MC_LAND_REBASE=0
echo "$MAIN2" > "$T/ctl-main-sha"
: > "$T/git-argv.txt"
tick env MC_LAND_REBASE=0
[ "$(logn " LAND")" = 0 ] && ok || bad "MC_LAND_REBASE=0 must write no LAND line at all: $(grep LAND "$LOG" | tail -3)"
[ -e "$LANDF" ] && bad "MC_LAND_REBASE=0 must write no land state file" || ok
[ "$(jobs_n)" = 0 ] && ok || bad "MC_LAND_REBASE=0 must spawn no rebase"
[ "$(merges_n)" = 0 ] && ok || bad "MC_LAND_REBASE=0 must run no git merge"
grep -q 'ls-remote.*refs/heads/main' "$T/git-argv.txt" && bad "MC_LAND_REBASE=0 must not even read the base sha" || ok

# ============================================================================
# 11. OBSERVE MODE says what it would do, records nothing, re-offers later
# ============================================================================
RESET
rm -f "$T/h/flags/merge-conductor-actions"
tick
echo "$MAIN2" > "$T/ctl-main-sha"
tick
grep -q "$SLUG#21 would land-rebase" "$LOG" && ok \
  || bad "observe mode must say what it would do: $(grep LAND "$LOG" | tail -4)"
[ "$(jobs_n)" = 0 ] && ok || bad "observe mode must spawn nothing"
[ "$(cat "$LANDF")" = "$MAIN1" ] && ok \
  || bad "observe mode must not record the sha, or the first landing after the flag flips is dropped (got '$(cat "$LANDF")')"
grep -qxF "landrebase $SLUG#21 $MAIN2" "$ST/attempts.txt" && bad "observe mode must write no marker" || ok
touch "$T/h/flags/merge-conductor-actions"
tick
grep -q "$SLUG#21 LAND_REBASE_SPAWNED main ${MAIN2:0:8}" "$LOG" && ok \
  || bad "with actions back on, the landing observe mode saw must still fire"
for J in "$ST"/rebase/*.json; do [ -f "$J" ] && wait_status "$J" done >/dev/null; done

# ============================================================================
# 12. THE BASE SHA COULD NOT BE READ: nothing fires, the recorded sha stands
# ============================================================================
RESET
tick
echo 2 > "$T/ctl-lsremote-rc"; echo "$MAIN2" > "$T/ctl-main-sha"
tick
grep -q "demo-os LAND: main sha unreadable this tick" "$LOG" && ok \
  || bad "an unreadable base must say so once: $(grep LAND "$LOG" | tail -3)"
[ "$(jobs_n)" = 0 ] && ok || bad "an unreadable base must fire no rebase"
[ "$(cat "$LANDF")" = "$MAIN1" ] && ok || bad "the recorded sha must stand (got '$(cat "$LANDF")')"
echo 0 > "$T/ctl-lsremote-rc"

echo "land-rebase.bh-870: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
