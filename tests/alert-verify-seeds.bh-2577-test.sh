#!/bin/bash
# tests/alert-verify-seeds.bh-2577-test.sh — the ten seed rows of
# alert_family_scripts and their verify scripts (BH-2577, slice 4 of BH-2544).
#
# Each REAL bin/alert-verify/<id>.sh is run in a scratch harness, fed the
# emitter's own beat shape on stdin (source<TAB>epoch<TAB>beat-json, the
# protocol in bin/triage-family-scripts.sh), and must answer:
#   0 + a non-empty first line naming the subject   cleared
#   1                                               still reproduces
#   75                                              any doubt (rate limit, 404,
#                                                   absent row, missing file)
# gh-pr-state.sh, jobs-client.sh, verdicts.sh and `gh` are stubs; bin/lib/
# gh-rest.sh and bin/lib/alert-verify.sh are the real ones. Every run is also
# checked to write nothing under the harness or TMPDIR.
#
# R1 applies worker/jobs/schema.sql twice and pins the ten rows; R2 runs each
# row's matcher over its family's positive line and the adversarial negatives
# of the plan's System invariants (c).
#   bash tests/alert-verify-seeds.bh-2577-test.sh     exit 0 = all pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SCRIPTS=(
  "$DIR/bin/alert-verify/mc-state-note.sh"
  "$DIR/bin/alert-verify/pipeline-health-clean-open.sh"
  "$DIR/bin/alert-verify/merge-queue-pr.sh"
  "$DIR/bin/alert-verify/main-red.sh"
  "$DIR/bin/alert-verify/ghdefault-visibility.sh"
  "$DIR/bin/alert-verify/hb-db-silent.sh"
  "$DIR/bin/alert-verify/lane-silent.sh"
  "$DIR/bin/alert-verify/deferral-backlog.sh"
  "$DIR/bin/alert-verify/fleet-propagate-partial.sh"
  "$DIR/bin/alert-verify/pr-url-reconcile-verdict.sh"
)
HELPER="$DIR/bin/lib/alert-verify.sh"

H="$T/h"; export GHF="$T/fx" CALLS="$T/calls"
mkdir -p "$H/bin/alert-verify" "$H/bin/lib" "$H/logs" "$H/state" "$GHF" "$CALLS" "$T/stub" "$T/tmp"
for s in "${SCRIPTS[@]}"; do cp "$s" "$H/bin/alert-verify/" 2>/dev/null; done
cp "$HELPER" "$H/bin/lib/alert-verify.sh" 2>/dev/null
# gh-rest.sh alone: the ledger/ETag siblings are gh_rest's own accounting and
# would write under the scratch harness, which the no-write check reads.
cp "$DIR/bin/lib/gh-rest.sh" "$H/bin/lib/gh-rest.sh"

# --- stubs --------------------------------------------------------------------
cat > "$H/bin/gh-pr-state.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CALLS/prstate.argv"
rc=$(cat "$GHF/prs-rc" 2>/dev/null || echo 0)
[ "$rc" = 0 ] || exit "$rc"
cat "$GHF/prs-state"
STUB
cat > "$H/bin/jobs-client.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CALLS/jobs.argv"
rc=$(cat "$GHF/jobs-rc" 2>/dev/null || echo 0)
[ "$rc" = 0 ] || exit "$rc"
case "${1:-}" in
  lane-procs) cat "$GHF/procs.tsv" ;;
  lanes)      cat "$GHF/lanes.tsv" ;;
  *)          exit 2 ;;
esac
STUB
cat > "$H/bin/lib/verdicts.sh" <<'STUB'
vd_standing() {
  printf '%s\n' "$*" >> "$CALLS/vd.argv"
  local rc; rc=$(cat "$GHF/vd-rc" 2>/dev/null || echo 0)
  [ "$rc" = 0 ] && cat "$GHF/vd.tsv"
  return "$rc"
}
STUB
cat > "$T/stub/gh" <<STUB
#!/bin/bash
printf '%s\t%s\n' "\${GH_TOKEN:-}" "\$*" >> "\$CALLS/gh.argv"
send() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "\$1" "\${2:-}"; }
case "\$*" in
  *"-X GET "*"/check-runs"*)
    send "\$(cat "\$GHF/st-checks" 2>/dev/null || echo 200)" "\$(cat "\$GHF/checks.json" 2>/dev/null)" ;;
  *"-X GET "*"/pulls/"*)
    GHT="\$GHF"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"-X GET repos/"*)
    st=\$(cat "\$GHF/st-repo" 2>/dev/null || echo 200)
    case "\$st" in 2*) send "\$st" '{"full_name":"x"}' ;; *) send "\$st" '{"message":"API rate limit exceeded (stub)"}' ;; esac ;;
  *) send 200 '' ;;
esac
STUB
chmod +x "$H/bin/gh-pr-state.sh" "$H/bin/jobs-client.sh" "$T/stub/gh"
export HARNESS="$H" TMPDIR="$T/tmp" PATH="$T/stub:$PATH"
unset GH_ADMIN_TOKEN GITHUB_TOKEN TRIAGE_SPOOL_ALERT JOBS_URL HARNESS_SECRET
export GH_TOKEN=tok-default

reset() { scratch_rm "$GHF" && scratch_rm "$CALLS" && mkdir -p "$GHF" "$CALLS" || exit 1; rm -f "$H/state/alert-triage-deferred.tsv" "$H/logs/fleet-propagate.log"; }
# q <akey> <line> — one quarantine line, the shape bin/alert-triage.sh hands over.
q() { printf 'box-hub\t1790000000\t%s\n' "$(jq -nc --arg a "$1" --arg l "$2" '{kind:"fleet_alert",project:"fleet",akey:$a,line:$l}')"; }
# expect <label> <id> <want-rc> [text the proof line must contain]
expect() {
  local rc=0 first w
  touch "$T/mark"
  "$H/bin/alert-verify/$2.sh" < "$T/in" > "$T/out" 2>"$T/err" || rc=$?
  w=$( { find "$H" -type f -newer "$T/mark"; find "$T/tmp" -mindepth 1; } 2>/dev/null)
  [ -z "$w" ] || { bad "$1: the verify wrote files: $w"; return; }
  [ "$rc" = "$3" ] || { bad "$1: rc $rc, want $3 (out: $(head -c 200 "$T/out"); err: $(head -c 200 "$T/err"))"; return; }
  if [ "$3" = 0 ]; then
    first=$(head -n1 "$T/out")
    [ -n "$first" ] && [[ "$first" == *"$4"* ]] || { bad "$1: proof line '$first' does not name '$4'"; return; }
  fi
  ok
}
calls() { if [ -f "$CALLS/$1" ]; then wc -l < "$CALLS/$1" | tr -d ' '; else echo 0; fi; }

# ---------- H1-H3: the shared stdin reading, through merge-queue-pr ----------
MQ_LINE='Merge queue: #2703 head is not the sha the review approved — commits landed after the approval, so nobody has read the code that would merge: https://github.com/example-org/cromford/pull/2703'
reset; echo MERGED > "$GHF/prs-state"
printf 'hub\t1790000000\tnot json at all\n' > "$T/in"
expect "H1 non-JSON payload" merge-queue-pr 75
{ q mq-headbound:cromford:2703 "$MQ_LINE"; q mq-headbound:cromford:2704 "${MQ_LINE//2703/2704}"; } > "$T/in"
expect "H2 two distinct PRs in one family" merge-queue-pr 75
: > "$T/in"
expect "H3 empty stdin" merge-queue-pr 75
printf 'hub\t1790000000\t{"kind":"fleet_alert","akey":"x"}\n' > "$T/in"
expect "H4 a beat with no .line" merge-queue-pr 75
[ "$(calls prstate.argv)" = 0 ] && ok || bad "H: gh-pr-state was called on a doubt path"

# ---------- S1 mc-state-note ----------
MC_LINE='[orchestrator/merge-conductor] conductor: example-org/cromford#2701 WAIT_CI — CI_FLAKE_TWICE: e2e cancelled/timed out again on abcd1234 after one full rerun — check the runner: https://github.com/example-org/cromford/pull/2701'
q orclane:merge-conductor-a1 "$MC_LINE" > "$T/in"
reset; echo MERGED > "$GHF/prs-state"
expect "S1 merged" mc-state-note 0 "https://github.com/example-org/cromford/pull/2701"
[ "$(cat "$CALLS/prstate.argv" 2>/dev/null)" = "https://github.com/example-org/cromford/pull/2701" ] \
  && ok || bad "S1: gh-pr-state.sh argv was '$(cat "$CALLS/prstate.argv" 2>/dev/null)'"
reset; echo OPEN > "$GHF/prs-state";  expect "S1 open" mc-state-note 1
reset; echo 75 > "$GHF/prs-rc";       expect "S1 unverifiable" mc-state-note 75
reset; echo 44 > "$GHF/prs-rc";       expect "S1 no such PR is doubt" mc-state-note 75
q orclane:merge-conductor-a2 "${MC_LINE/WAIT_CI/CLOSED}" > "$T/in"
reset; echo CLOSED > "$GHF/prs-state"; expect "S1 a terminal-state line is not this row's subject" mc-state-note 75
[ "$(calls prstate.argv)" = 0 ] && ok || bad "S1: gh-pr-state called for a terminal-state line"

# ---------- S2 pipeline-health-clean-open ----------
PH_LINE='[pipeline-health] https://github.com/example-org/cromford/pull/2702 is APPROVE (record cromford-BH-2600-202609261200), OPEN and CLEAN for 45m and the merge sweep has not landed it. Last merge-sweep.log line about it: 2026-09-27 00:10:00Z https://github.com/example-org/other/pull/9 skipped'
q 'health:sweepstall:example-org/cromford#2702' "$PH_LINE" > "$T/in"
reset; echo CLOSED > "$GHF/prs-state"
expect "S2 closed" pipeline-health-clean-open 0 "https://github.com/example-org/cromford/pull/2702"
[ "$(cat "$CALLS/prstate.argv" 2>/dev/null)" = "https://github.com/example-org/cromford/pull/2702" ] \
  && ok || bad "S2: the PR must come from the akey, got '$(cat "$CALLS/prstate.argv" 2>/dev/null)'"
reset; echo OPEN > "$GHF/prs-state"; expect "S2 open" pipeline-health-clean-open 1
reset; echo 75 > "$GHF/prs-rc";      expect "S2 unverifiable" pipeline-health-clean-open 75
printf 'hub\t1790000000\t%s\n' "$(jq -nc --arg l "$PH_LINE" '{kind:"fleet_alert",line:$l}')" > "$T/in"
reset; echo CLOSED > "$GHF/prs-state"; expect "S2 a beat with no akey" pipeline-health-clean-open 75

# ---------- S3 merge-queue-pr ----------
q mq-headbound:cromford:2703 "$MQ_LINE" > "$T/in"
reset; echo MERGED > "$GHF/prs-state"
expect "S3 merged" merge-queue-pr 0 "https://github.com/example-org/cromford/pull/2703"
[ "$(cat "$CALLS/prstate.argv" 2>/dev/null)" = "https://github.com/example-org/cromford/pull/2703" ] \
  && ok || bad "S3: gh-pr-state.sh argv was '$(cat "$CALLS/prstate.argv" 2>/dev/null)'"
reset; echo OPEN > "$GHF/prs-state"; expect "S3 open" merge-queue-pr 1
reset; echo 75 > "$GHF/prs-rc";      expect "S3 unverifiable" merge-queue-pr 75
q mq-headbound:cromford:2703 "${MQ_LINE/pull\/2703/pull/9999}" > "$T/in"
reset; echo MERGED > "$GHF/prs-state"; expect "S3 #N and the URL disagree" merge-queue-pr 75

# ---------- S4 main-red ----------
MR_LINE='[orchestrator/main-red] example-org/cromford main is RED: "harness-ci" failed (job: test; sha abcd1234; red since 2026-09-27 00:00Z). Every open PR on this repo inherits it. https://github.com/example-org/cromford/actions/runs/1'
q orclane:main-red-example-org_cromford "$MR_LINE" > "$T/in"
run_json() { jq -nc --argjson n "$1" --argjson r "$2" '{total_count:$n,check_runs:$r}'; }
R_OK='{"status":"completed","conclusion":"success","head_sha":"0123456789abcdef0123456789abcdef01234567"}'
R_SKIP='{"status":"completed","conclusion":"skipped","head_sha":"0123456789abcdef0123456789abcdef01234567"}'
R_FAIL='{"status":"completed","conclusion":"failure","head_sha":"0123456789abcdef0123456789abcdef01234567"}'
R_RUN='{"status":"in_progress","conclusion":null,"head_sha":"0123456789abcdef0123456789abcdef01234567"}'
reset; run_json 3 "[$R_OK,$R_OK,$R_SKIP]" > "$GHF/checks.json"
expect "S4 green" main-red 0 "example-org/cromford"
grep -q 'repos/example-org/cromford/commits/main/check-runs' "$CALLS/gh.argv" 2>/dev/null \
  && ok || bad "S4: the check-runs read went elsewhere: $(cat "$CALLS/gh.argv" 2>/dev/null)"
[ "$(calls gh.argv)" = 1 ] && ok || bad "S4: $(calls gh.argv) REST reads, want 1"
reset; run_json 2 "[$R_OK,$R_FAIL]" > "$GHF/checks.json"; expect "S4 one failure" main-red 1
reset; run_json 2 "[$R_OK,$R_OK]" > "$GHF/checks.json"; echo 403 > "$GHF/st-checks"
expect "S4 rate limited" main-red 75
reset; run_json 2 "[$R_OK,$R_RUN]" > "$GHF/checks.json"; expect "S4 a run in progress" main-red 75
reset; run_json 2 "[$R_FAIL,$R_RUN]" > "$GHF/checks.json"; expect "S4 a failure beside a run still going" main-red 75
reset; run_json 0 "[]" > "$GHF/checks.json";             expect "S4 zero runs" main-red 75
reset; run_json 150 "[$R_OK]" > "$GHF/checks.json";      expect "S4 an incomplete page" main-red 75

# ---------- S5 ghdefault-visibility ----------
GD_LINE='DEFAULT GH TOKEN CANNOT SEE example-org/project-3 (project-3) (new): the admin token cannot see it either (or is absent) — every gh consumer is blind to this repo. Grant the default PAT access or keep the admin token current.'
q ghinvisible:example-org/project-3 "$GD_LINE" > "$T/in"
reset; expect "S5 visible" ghdefault-visibility 0 "example-org/project-3"
reset; GH_ADMIN_TOKEN=tok-admin expect "S5 visible, admin token in env" ghdefault-visibility 0 "example-org/project-3"
[ "$(cut -f1 "$CALLS/gh.argv" 2>/dev/null)" = tok-default ] \
  && ok || bad "S5: the read ran on '$(cut -f1 "$CALLS/gh.argv" 2>/dev/null)', not the default token"
grep -q -- '-X GET repos/example-org/project-3$' "$CALLS/gh.argv" 2>/dev/null && ok || bad "S5: argv $(cat "$CALLS/gh.argv" 2>/dev/null)"
grep -q tok- "$T/out" && bad "S5: the token reached stdout" || ok
reset; echo 404 > "$GHF/st-repo"; expect "S5 still invisible" ghdefault-visibility 1
reset; echo 429 > "$GHF/st-repo"; expect "S5 rate limited" ghdefault-visibility 75
reset; GH_TOKEN= expect "S5 no default token" ghdefault-visibility 75
[ "$(calls gh.argv)" = 0 ] && ok || bad "S5: gh was called with no default token"

# ---------- S6 hb-db-silent ----------
HB_LINE='[orchestrator/heartbeat-reaper] alert-triage on box-hub is silent: its last beat was 42m ago (threshold 15m), pid 123, started -, note: -. This is the ROW talking, not a file on this box.'
q orclane:heartbeat-reaper-1 "$HB_LINE" > "$T/in"
procs() { printf 'other-lane\tbox-hub\tsilent\t9000\t1\t900\t1\t-\t-\nalert-triage\t%s\t%s\t60\t123\t900\t1\t-\t-\n' "$1" "$2" > "$GHF/procs.tsv"; }
reset; procs box-hub fresh;   expect "S6 fresh" hb-db-silent 0 "alert-triage on box-hub"
[ "$(cat "$CALLS/jobs.argv" 2>/dev/null)" = lane-procs ] && ok || bad "S6: jobs argv $(cat "$CALLS/jobs.argv" 2>/dev/null)"
reset; procs box-hub ended;   expect "S6 ended cleanly" hb-db-silent 0 "ended"
reset; procs box-hub silent;  expect "S6 still silent" hb-db-silent 1
reset; procs box-hub overdue; expect "S6 overdue" hb-db-silent 1
reset; procs box-hub none;    expect "S6 never beat" hb-db-silent 75
reset; procs box-other fresh; expect "S6 no row for the box" hb-db-silent 75
reset; procs box-hub fresh; echo 1 > "$GHF/jobs-rc"; expect "S6 worker unreachable" hb-db-silent 75

# ---------- S7 lane-silent ----------
LS_LINE='2026-09-27 00:40:00Z [jobs-watchdog] LANE SILENT: project-1@box-project-1-1 last ticked 45m ago (a cron tick at 2026-09-26T23:55:00Z) and should tick every 10m. Threshold 30m. Nothing is triaging this project.'
q orclane:alerts-log-1 "$LS_LINE" > "$T/in"
lanes() { printf 'project-1\t%s\t%s\t60\t60\tcron\t1\t1800\t2026-09-27T00:39:00Z\t1\n' "$1" "$2" > "$GHF/lanes.tsv"; }
reset; lanes box-project-1-1 live;    expect "S7 live" lane-silent 0 "project-1@box-project-1-1"
[ "$(cat "$CALLS/jobs.argv" 2>/dev/null)" = lanes ] && ok || bad "S7: jobs argv $(cat "$CALLS/jobs.argv" 2>/dev/null)"
reset; lanes box-project-1-1 stale;   expect "S7 stale" lane-silent 1
reset; lanes box-project-1-1 pending; expect "S7 not ticked since" lane-silent 1
reset; lanes box-project-1-1 retired; expect "S7 retired" lane-silent 75
reset; lanes box-other live;       expect "S7 no row for the box" lane-silent 75
reset; lanes box-project-1-1 live; echo 1 > "$GHF/jobs-rc"; expect "S7 worker unreachable" lane-silent 75

# ---------- S8 deferral-backlog ----------
DB_LINE='[alert-triage] DEFERRAL BACKLOG: 45 lines spooled — arrivals exceed 6 families/tick; oldest alert is not being triaged'
SPOOL="$H/state/alert-triage-deferred.tsv"
q orclane:alerts-log-2 "$DB_LINE" > "$T/in"
reset; seq 3 > "$SPOOL";  expect "S8 drained" deferral-backlog 0 "3 lines"
reset; seq 45 > "$SPOOL"; expect "S8 still deep" deferral-backlog 1
reset; seq 40 > "$SPOOL"; expect "S8 at the threshold: the lane pages only above it" deferral-backlog 0 "40 lines"
reset; seq 41 > "$SPOOL"; expect "S8 one over the threshold" deferral-backlog 1
# Mid-tick: bin/alert-triage.sh holds its lock on fd 9 (inherited by the verify,
# as in the real call) and has drained the spool into its own temp file, so the
# 300-line backlog is not in the file. A clear here would settle a live page.
LOCKF="$H/locks/alert-triage.lock"; mkdir -p "$H/locks"; : > "$LOCKF"
reset; : > "$SPOOL"
exec 9>"$LOCKF"; flock -n 9 || bad "S8: could not take the lane lock"
expect "S8 drained mid-tick is doubt, not a clear" deferral-backlog 75
seq 3 > "$SPOOL"; expect "S8 a few new arrivals mid-tick is doubt" deferral-backlog 75
seq 45 > "$SPOOL"; expect "S8 over the cap mid-tick is still a repro" deferral-backlog 1
exec 9>&-
reset; seq 3 > "$SPOOL"; expect "S8 the lock file present and free" deferral-backlog 0 "3 lines"
rm -f "$LOCKF"
reset;                    expect "S8 no spool" deferral-backlog 75
reset; seq 3 > "$SPOOL"; TRIAGE_SPOOL_ALERT=abc expect "S8 non-integer threshold" deferral-backlog 75
reset; seq 3 > "$SPOOL"; TRIAGE_SPOOL_ALERT=0 expect "S8 zero threshold" deferral-backlog 75
reset; seq 3 > "$SPOOL"; TRIAGE_SPOOL_ALERT=2 expect "S8 the knob is read" deferral-backlog 1
q orclane:alerts-log-3 '[alerts-medic] DEFERRAL BACKLOG: 9 families still open and unexamined after this pass' > "$T/in"
reset; seq 3 > "$SPOOL";  expect "S8 the medic line is not this row" deferral-backlog 75
# BH-5942: a page that names its project reads THAT project's spool and lock.
PSPOOL="$H/state/alert-triage/projfix-a/deferred.tsv"; PLOCKF="$H/locks/alert-triage-projfix-a.lock"
q orclane:alerts-log-4 '[alert-triage] DEFERRAL BACKLOG: 45 lines spooled for project projfix-a — arrivals exceed 6 families/tick; oldest alert is not being triaged' > "$T/in"
mkdir -p "${PSPOOL%/*}"
reset; seq 3 > "$PSPOOL"; seq 45 > "$SPOOL"; expect "S8p the project's spool drained" deferral-backlog 0 "3 lines"
reset; seq 45 > "$PSPOOL"; seq 3 > "$SPOOL"; expect "S8p the project's spool still deep" deferral-backlog 1
reset; rm -f "$PSPOOL"; seq 3 > "$SPOOL"; expect "S8p no project spool is doubt, not the shared spool" deferral-backlog 75
: > "$PLOCKF"; exec 9>"$PLOCKF"; flock -n 9 || bad "S8p: could not take the project's run lock"
reset; seq 3 > "$PSPOOL"; expect "S8p drained while the project's run holds its lock is doubt" deferral-backlog 75
exec 9>&-
reset; seq 3 > "$PSPOOL"; expect "S8p the project's lock present and free" deferral-backlog 0 "3 lines"
rm -f "$PLOCKF" "$PSPOOL"
q orclane:alerts-log-5 '[alert-triage] DEFERRAL BACKLOG: 45 lines spooled for project ..x — arrivals exceed 6 families/tick' > "$T/in"
reset; seq 3 > "$SPOOL"; expect "S8p a project that is not a name is doubt" deferral-backlog 75

# ---------- S9 fleet-propagate-partial ----------
FP_LINE='[orchestrator/fleet-propagate] propagating def5678 to the fleet FAILED in part — hub=ok, 5/6 boxes synced, failed:box-project-3-1, 10/10 pool images rebaked, crontab ok. Those targets are still running the OLD harness.'
FPLOG="$H/logs/fleet-propagate.log"
PARTIAL='2026-09-27 00:05:00Z abc1234..def5678 hub=ok boxes=5/6 images=10/10 cron=ok paths=bin/x.sh,'
FULL='2026-09-27 00:10:00Z abc1234..def5678 hub=ok boxes=6/6 images=10/10 cron=ok paths=bin/x.sh,'
q orclane:fleet-propagate-1 "$FP_LINE" > "$T/in"
reset; printf '%s\n%s\n' "$PARTIAL" "$FULL" > "$FPLOG"
expect "S9 a later full sync" fleet-propagate-partial 0 "def5678 hub=ok boxes=6/6"
reset; printf '%s\n' "$PARTIAL" > "$FPLOG";            expect "S9 only the partial" fleet-propagate-partial 1
reset; printf '%s\n%s\n' "$FULL" "$PARTIAL" > "$FPLOG"; expect "S9 the partial came after" fleet-propagate-partial 1
reset; printf '%s\n%s\n' "$PARTIAL" "${FULL/def5678/9999999}" > "$FPLOG"; expect "S9 full sync of a different sha" fleet-propagate-partial 1
reset; printf '%s\n%s\n' "$PARTIAL" "${FULL/cron=ok/failed=pool-a cron=ok}" > "$FPLOG"; expect "S9 boxes N/N but a pool failed" fleet-propagate-partial 1
reset;                                                   expect "S9 no log" fleet-propagate-partial 75
reset; { printf '%s\n' "$PARTIAL" "$FULL"; for i in $(seq 700); do printf '2026-09-27 01:%02d:00Z 1111111..2222222 hub=ok boxes=6/6 images=10/10 cron=ok paths=x%s\n' $((i % 60)) "$i"; done; } > "$FPLOG"
[ "$(wc -c < "$FPLOG")" -gt 60000 ] && ok || bad "S9: the bound fixture is only $(wc -c < "$FPLOG") bytes"
expect "S9 a full sync older than the last 20 KB is not read" fleet-propagate-partial 1

# ---------- S10 pr-url-reconcile-verdict ----------
PU_LINE='[pr-url-reconcile] cromford/BH-2600: https://github.com/example-org/cromford/pull/2710 owes a verdict and nothing can produce one — the merge conductor is not armed (flags/merge-conductor-actions absent, or MC_REREVIEW_ON_MOVE=0), so no lane will re-review it.'
HEAD=0123456789abcdef0123456789abcdef01234567
q prurlreconcile:verdict:cromford-BH-2600-202609261200 "$PU_LINE" > "$T/in"
pu() { reset; echo "$1" > "$GHF/prstate"; echo "$HEAD" > "$GHF/prhead"; printf 'APPROVE\treview\t77\t2026-09-27T00:00:00Z\t-\t-\n' > "$GHF/vd.tsv"; }
pu OPEN; expect "S10 open with a standing verdict" pr-url-reconcile-verdict 0 "APPROVE"
[ "$(cat "$CALLS/vd.argv" 2>/dev/null)" = "example-org/cromford 2710 $HEAD" ] && ok || bad "S10: vd_standing argv '$(cat "$CALLS/vd.argv" 2>/dev/null)'"
[ "$(calls gh.argv)" = 1 ] && [ "$(calls vd.argv)" = 1 ] && ok || bad "S10: $(calls gh.argv) GitHub + $(calls vd.argv) verdict reads, want 1+1"
pu OPEN; echo 1 > "$GHF/vd-rc"; expect "S10 open, nothing stands" pr-url-reconcile-verdict 1
pu OPEN; echo 2 > "$GHF/vd-rc"; expect "S10 open, verdict unverifiable" pr-url-reconcile-verdict 75
pu MERGED; expect "S10 closed" pr-url-reconcile-verdict 0 "https://github.com/example-org/cromford/pull/2710"
[ "$(calls vd.argv)" = 0 ] && ok || bad "S10: vd_standing read for a closed PR"
pu OPEN; echo 403 > "$GHF/st-pr"; expect "S10 rate limited" pr-url-reconcile-verdict 75
pu OPEN; echo 404 > "$GHF/st-pr"; expect "S10 no such PR is doubt" pr-url-reconcile-verdict 75

# ---------- R1 the ten seed-bh-2544 rows, applied twice ----------
# SPEC CHANGE (BH-4608): only this ticket's rows; other families add rows without editing this suite.
python3 - "$DIR/worker/jobs/schema.sql" "$DIR/bin/alert-verify" > "$T/r1.out" 2>&1 <<'PY'
import os, re, sqlite3, sys
sql = open(sys.argv[1]).read()
db = sqlite3.connect(":memory:")
db.executescript(sql); db.executescript(sql)
rows = db.execute("SELECT id,match_kind,match,verify,on_clear,on_repro,enabled,priority,actor FROM alert_family_scripts WHERE actor='seed-bh-2544' ORDER BY priority").fetchall()
errs = []
if len(rows) != 10: errs.append(f"{len(rows)} rows, want 10")
if len({r[7] for r in rows}) != len(rows): errs.append("priorities are not unique")
for r in rows:
    i, kind, m, verify, oc, orp, en, pri, actor = r
    if not re.fullmatch(r"[a-z0-9-]{1,48}", i or ""): errs.append(f"{i}: bad id")
    if verify != i: errs.append(f"{i}: verify {verify!r} is not the row id")
    p = os.path.join(sys.argv[2], f"{verify}.sh")
    if not os.access(p, os.X_OK): errs.append(f"{i}: {p} is not executable")
    if (oc, orp, en, actor) != ("settle", "model", 1, "seed-bh-2544"): errs.append(f"{i}: {(oc, orp, en, actor)}")
    if kind == "line_regex":
        try: re.compile(m)
        except re.error as e: errs.append(f"{i}: regex does not compile: {e}")
print("\n".join(errs) if errs else "OK")
PY
[ "$(cat "$T/r1.out")" = OK ] && ok || bad "R1: $(cat "$T/r1.out")"

# ---------- R2 each matcher: its own positive, none of its negatives ----------
# id <TAB> pos|neg <TAB> text (an akey for akey_prefix rows, a line otherwise)
{
  printf 'mc-state-note\tpos\t%s\n' "$MC_LINE"
  printf 'mc-state-note\tneg\t%s\n' '[merge-conductor] conductor mode is kill-switch' 'conductor: paused'
  printf 'pipeline-health-clean-open\tpos\t%s\n' 'health:sweepstall:example-org/cromford#2702'
  printf 'pipeline-health-clean-open\tneg\t%s\n' 'health:stalepr:example-org/cromford#2702' 'sweepstall:x'
  printf 'merge-queue-pr\tpos\t%s\n' "$MQ_LINE"
  printf 'merge-queue-pr\tneg\t%s\n' '[merge-sweep] queue empty' 'Merge queue drained 3 PRs'
  printf 'main-red\tpos\t%s\n' "$MR_LINE" "${MR_LINE/main is RED/main is STILL RED}"
  printf 'main-red\tneg\t%s\n' '[orchestrator/main-red] RESOLVED example-org/cromford main is green' \
    '[main-red-pr-pair] example-org/x: 2 open PRs share the same fail job' \
    'RESOLVED [orchestrator/main-red]: example-org/cromford main is RED: "x" failed (was firing n=3 for 40m)'
  printf 'ghdefault-visibility\tpos\t%s\n' "$GD_LINE"
  printf 'ghdefault-visibility\tneg\t%s\n' '[auth] ghdefault-example-org_x RECOVERED — the default gh token sees example-org/x again'
  printf 'hb-db-silent\tpos\t%s\n' "$HB_LINE" "${HB_LINE/is silent/is overdue}"
  printf 'hb-db-silent\tneg\t%s\n' 'alert-triage on hub is running' 'alert-triage on box-hub is beating again (fresh, last beat 1m ago)'
  printf 'lane-silent\tpos\t%s\n' "$LS_LINE"
  printf 'lane-silent\tneg\t%s\n' '[jobs-watchdog] LANE RESUMED: project-1@box-project-1-1 ticked again' 'lane-silent cromford@hub 40m (threshold 30m)'
  printf 'deferral-backlog\tpos\t%s\n' "$DB_LINE"
  printf 'deferral-backlog\tneg\t%s\n' '[alerts-medic] DEFERRAL BACKLOG: 9 families still open and unexamined after this pass'
  printf 'fleet-propagate-partial\tpos\t%s\n' "$FP_LINE"
  printf 'fleet-propagate-partial\tneg\t%s\n' '[orchestrator/fleet-propagate] propagated abc1234 to the fleet: 6/6 boxes synced'
  printf 'pr-url-reconcile-verdict\tpos\t%s\n' 'prurlreconcile:verdict:cromford-BH-2600-202609261200'
  printf 'pr-url-reconcile-verdict\tneg\t%s\n' 'prurlreconcile:other:x' 'orclane:review-rescue-1'
} > "$T/r2.tsv"
python3 - "$DIR/worker/jobs/schema.sql" "$T/r2.tsv" > "$T/r2.out" 2>&1 <<'PY'
import re, sqlite3, sys
db = sqlite3.connect(":memory:")
db.executescript(open(sys.argv[1]).read())
rows = db.execute("SELECT id,match_kind,match FROM alert_family_scripts WHERE enabled=1 ORDER BY priority").fetchall()
kind = {r[0]: r[1] for r in rows}
def hit(r, text):
    return text.startswith(r[2]) if r[1] == "akey_prefix" else re.search(r[2], text) is not None
errs = []
for ln in open(sys.argv[2], encoding="utf-8"):
    i, pn, text = ln.rstrip("\n").split("\t", 2)
    own = [r for r in rows if r[0] == i]
    if not own: errs.append(f"{i}: no row"); continue
    if pn == "pos":
        if not hit(own[0], text): errs.append(f"{i}: misses its own line: {text[:80]}")
        # the first row (by priority) of the same kind that takes it must be its own
        first = next((r[0] for r in rows if r[1] == kind[i] and hit(r, text)), None)
        if first != i: errs.append(f"{i}: its line is taken first by {first}")
    elif hit(own[0], text):
        errs.append(f"{i}: matches the negative: {text[:80]}")
print("\n".join(errs) if errs else "OK")
PY
[ "$(cat "$T/r2.out")" = OK ] && ok || bad "R2: $(cat "$T/r2.out")"

# ---------- B1/B2 the ticket's two static checks ----------
B1=$(grep -rnE 'claude-|grok-|gpt-|deepseek' "$DIR/bin/alert-verify/" "$HELPER" 2>&1)
[ -d "$DIR/bin/alert-verify" ] && [ -z "$B1" ] && ok || bad "B1: model ids in the verify scripts (or no scripts): $B1"
# SPEC CHANGE (BH-4608): count this ticket's seed statements by their actor and
# stamp (each VALUES line ends in it), not every alert_family_scripts INSERT.
B2=$(grep -c "'seed-bh-2544','2026-09-27T00:00:00Z');\$" "$DIR/worker/jobs/schema.sql")
[ "$B2" = 10 ] && ok || bad "B2: $B2 seed statements, want 10"

# NR: BH-2613 root contract (docs/notes/2026-09-26-BH-2613-lib-root-resolution.md).
# The lib resolves its root as ${HARNESS:-${H:-}}, never a /root/harness literal
# (the bin/alert-verify/ entry points own that default). Sourced with no root,
# the root-free helpers still work and av_pr_verdict is doubt (75) without
# running anything: no path is built from an empty root.
NR=$( unset HARNESS H; cd "$T" && . "$DIR/bin/lib/alert-verify.sh" || exit 9
      printf '%s' "[$AV_HARNESS]"; av_pr_verdict row https://github.com/o/r/pull/1; printf ' pr=%s' "$?"
      printf 'x y\n' | av_one 'x'; printf ' one=%s' "$?" ) 2>&1
[ "$NR" = "[] pr=75x
 one=0" ] && ok || bad "NR: a lib with no root must resolve to empty and answer doubt: [$NR]"
H2=$( HARNESS= H="$T/hh"; . "$DIR/bin/lib/alert-verify.sh"; printf '%s' "$AV_HARNESS" )
[ "$H2" = "$T/hh" ] && ok || bad "NR: the caller's H is the root when HARNESS is empty: [$H2]"
! grep -nE '\$\{HARNESS:-/root/harness' "$DIR/bin/lib/alert-verify.sh" >/dev/null && ok || bad "NR: bin/lib/alert-verify.sh falls back to the /root/harness literal"

echo "alert-verify-seeds.bh-2577-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
