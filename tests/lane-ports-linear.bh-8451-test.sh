#!/bin/bash
# tests/lane-ports-linear.bh-8451-test.sh — BH-8451 (slice C3 of #7920): the
# lane ports read a Linear (and a Jira) project through the tracker contract,
# and every other project keeps its own path. The SHIPPED scripts run in a
# scratch tree (scratch_install_closure). Linear's GraphQL API and the settings
# worker are tests/lib/linear-stub.bh-7920.sh, which serves
# tests/fixtures/lane-ports.bh-8451/linear/issues.json for every list:
#   CRO-12 Todo, ai-build+hotfix, 0 comments    CRO-13 Done
#   CRO-14 Todo, no label                       CRO-15 In Progress, 1 comment
#   CRO-16 Todo, comments over the list cap     CRO-17 Todo, updated 5 min ago
#   CRO-18 Todo, updated before the cutoff      CRO-19 Todo, no updatedAt
#   CRO-20 In Review, 1 comment
# The Jira cases use tests/lib/tracker-jira-stub.sh with
# tests/fixtures/lane-ports.bh-8451/jira/ (SCRUM-12 hotfix, SCRUM-15 waiting
# on the client + needs_clarification, SCRUM-16 In Progress, SCRUM-17 To Do).
#
#   K1-K4  bin/lib/trk-lane.sh: the trigger, the kind, a list that fails
#   U1-U2  bin/unblocked-children.sh
#   H1-H3  bin/lib/triage-hotfix-lib.sh triage_hot_load / triage_hot_mark
#   S1-S5  bin/hotfix-seen.sh
#   A1-A3  the AND: a hotfix ticket without ai-build is seen by no lane
#   P1-P5  bin/preplan-candidates.sh
#   F1-F2  bin/run-preplan.sh TICKET_FP
#   L1-L2  bin/launch-fastpath.sh gate 1
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lane-ports-linear.bh-8451-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/linear-stub.bh-7920.sh" || exit 1
. "$(dirname "$0")/lib/tracker-jira-stub.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || { echo "jq or python3 missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
unset HARNESS_ENV_DIR GH_ISSUES_REPO

KEY=lin-api-fixture-sentinel-8451
FIX="$REPO/tests/fixtures/lane-ports.bh-8451/linear"
H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$H/state" "$H/logs" "$H/flags" "$H/prompts" "$H/builds" "$H/plans"
for L in bin/unblocked-children.sh bin/hotfix-seen.sh bin/preplan-candidates.sh bin/run-preplan.sh \
         bin/launch-fastpath.sh bin/lib/triage-hotfix-lib.sh bin/lib/triage-shards-lib.sh bin/lib/trk-lane.sh \
         bin/jobs-client.sh bin/fleet-conf.sh bin/internal-token-for.sh bin/project-of.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
cat > "$H/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset>
crolin  o/crolin  https://x.example  -           2
ghp     o/ghp     -                  -           2
bproj   o/bproj   https://b.example  /api/board  2
CONF
echo 'setsid /root/harness/bin/run-build.sh ghp <issue-number> GP-<issue-number> > x' > "$H/prompts/ghp.md"
: > "$H/env/global.env"
printf 'INTERNAL_API_TOKEN=tok-fixture-board-8451\n' > "$H/env/bproj.env"
linear_stub_setup "$T" "$FIX" || { echo "stub setup failed"; exit 1; }
export HARNESS="$H" FLEET_CONF="$H/fleet.conf" GH_ETAG=0 LS_KEY_EXPECT="$KEY" JOBS_SETTINGS_CACHE_S=0
envfile() { printf 'LINEAR_API_KEY=%s\nLINEAR_TEAM=CRO\n' "$KEY" > "$H/env/crolin.env"; }
envfile
linear_set tracker_adapter.crolin linear
linear_set tracker_linear.crolin.team CRO
fresh() { linear_reset_log; rm -f "$LS_STATE/issues.json"; : > "$H/logs/ALERTS.log"; : > "$H/logs/crolin.log"; }
lane() { ( . "$H/bin/lib/trk-lane.sh"; trk_lane_kind "$H" "$1"; printf '%s' "$TRK_LANE_KIND" ); }
fail_linear() { echo '{"errors":[{"message":"fixture failure"}]}' > "$LS_STATE/issues.json"; }

# ── K: the seam ──────────────────────────────────────────────────────────────
fresh
[ "$(lane crolin)" = linear ] && ok || bad "K1 env key + row linear must be linear: '$(lane crolin)'"
fresh
[ "$(lane ghp)" = "" ] && [ "$(linear_settings_count)" = 0 ] && ok \
  || bad "K2 no env file: '' and 0 settings calls (settings=$(linear_settings_count))"
for body in 'LINEAR_API_KEY=' '# LINEAR_API_KEY=x' 'LINEAR_API_KEY=""'; do
  fresh; printf '%s\nLINEAR_TEAM=CRO\n' "$body" > "$H/env/crolin.env"
  [ "$(lane crolin)" = "" ] && [ "$(linear_settings_count)" = 0 ] && ok \
    || bad "K3 env line '$body' is no trigger: '$(lane crolin)' settings=$(linear_settings_count)"
done
envfile
fresh; linear_unset tracker_adapter.crolin
[ "$(lane crolin)" = github-issues ] && ok || bad "K3 no row: column 4 '-' is github-issues: '$(lane crolin)'"
linear_set tracker_adapter.crolin linaer
[ "$(lane crolin)" = "" ] && ok || bad "K3 a typo row is no kind: '$(lane crolin)'"
linear_set tracker_adapter.crolin linear
fresh; linear_settings_down
[ "$(lane crolin)" = github-issues ] && ok || bad "K3 a down worker falls back to column 4: '$(lane crolin)'"
rm -f "$LS_STATE/settings-down"
fresh; linear_set tracker_linear.crolin.team OPS
out=$( ( . "$H/bin/lib/trk-lane.sh"; trk_lane_list "$H" crolin k4 --state open ) 2>"$T/k4.err"); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && [ "$(linear_req_count)" = 0 ] && ok || bad "K4 a context that does not load: rc 1, nothing (rc=$rc out=$out)"
grep -q '^trk-lane: k4 crolin: context' "$T/k4.err" && ok || bad "K4 one stderr line names the lane: $(cat "$T/k4.err")"
grep -q "$KEY" "$T/k4.err" && bad "K4 the key reached stderr" || ok
linear_set tracker_linear.crolin.team CRO
fresh
out=$( ( . "$H/bin/lib/trk-lane.sh"; trk_lane_list "$H" crolin k5 --state open ) ); rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -c '[.[].key]')" = '["CRO-12","CRO-15","CRO-16","CRO-17","CRO-18","CRO-19","CRO-20"]' ] \
  && ok || bad "K5 the open list keeps the build-labelled open rows only (rc=$rc): $(printf '%s' "$out" | jq -c '[.[].key]' 2>/dev/null)"

# ── U: unblocked-children ───────────────────────────────────────────────────
fresh
out=$(printf 'board issues: CHANGED 13 "" (state: open -> closed)\n' | "$H/bin/unblocked-children.sh" crolin 2>/dev/null); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && [ ! -s "$LS_STATE/gh.log" ] && ok \
  || bad "U1 a Linear project gets no line and no GitHub read (rc=$rc out=$out gh=$(cat "$LS_STATE/gh.log" 2>/dev/null))"
fresh
printf 'board issues: CHANGED 13 "" (state: open -> closed)\n' | "$H/bin/unblocked-children.sh" ghp >/dev/null 2>&1
grep -q 'o/ghp' "$LS_STATE/gh.log" 2>/dev/null && [ "$(linear_settings_count)" = 0 ] && ok \
  || bad "U2 a column-4 project with no env file reads GitHub as today (gh=$(cat "$LS_STATE/gh.log" 2>/dev/null) settings=$(linear_settings_count))"

# ── H: triage_hot_load ───────────────────────────────────────────────────────
hot() { ( export HARNESS="$H" PROJECT="$1"; . "$H/bin/lib/triage-shards-lib.sh"; . "$H/bin/lib/triage-hotfix-lib.sh"
          triage_hot_load; printf '[%s]\n' "$TRIAGE_HOT"; printf 'CRO-15 y\nCRO-12 x\n' | triage_hot_mark queue ) 2>/dev/null; }
fresh
out=$(hot crolin)
[ "$(head -1 <<<"$out")" = "[ 12 ]" ] && ok || bad "H1 TRIAGE_HOT must be ' 12 ': $(head -1 <<<"$out")"
[ "$(linear_req_count TrkIssues)" = 1 ] && [ "$(linear_req_count)" = 1 ] && [ ! -s "$LS_STATE/gh.log" ] && ok \
  || bad "H1 one TrkIssues request and no gh call: $(cat "$LS_STATE/reqs" 2>/dev/null) gh=$(cat "$LS_STATE/gh.log" 2>/dev/null)"
[ "$(linear_req_of TrkIssues | jq -r .variables.label)" = hotfix ] && ok || bad "H1 the list asked for the hotfix label: $(linear_req_of TrkIssues | jq -c .variables)"
[ "$(sed -n 2p <<<"$out")" = "[HOTFIX] CRO-12 x" ] && [ "$(sed -n 3p <<<"$out")" = "CRO-15 y" ] && ok \
  || bad "H2 CRO-12 is marked and sorted first, CRO-15 is not: $(tail -n +2 <<<"$out" | tr '\n' '|')"
fresh; fail_linear
out=$(hot crolin)
[ "$(head -1 <<<"$out")" = "[]" ] && [ "$(tail -n +2 <<<"$out" | tr '\n' '|')" = "CRO-15 y|CRO-12 x|" ] && ok \
  || bad "H3 a failed list is no hotfixes and a plain passthrough: $(tr '\n' '|' <<<"$out")"

# ── S: hotfix-seen ───────────────────────────────────────────────────────────
fresh; scratch_rm "$H/state/hotfix-announced"
"$H/bin/hotfix-seen.sh" crolin; rc=$?
[ "$rc" = 0 ] && [ -f "$H/state/hotfix-announced/crolin/CRO-12.seen" ] && ok || bad "S1 the CRO-12 marker (rc=$rc): $(ls -R "$H/state/hotfix-announced" 2>/dev/null)"
grep -q '\[crolin/CRO-12\] HOTFIX seen: CRO-12 — Ledger export to CSV' "$H/logs/ALERTS.log" && ok || bad "S1 the announce line: $(cat "$H/logs/ALERTS.log")"
[ "$(grep -c HOTFIX "$H/logs/ALERTS.log")" = 1 ] && ok || bad "S1 exactly one announce: $(cat "$H/logs/ALERTS.log")"
[ "$(linear_req_count TrkIssues)" = 1 ] && [ "$(linear_req_count)" = 1 ] && [ ! -s "$LS_STATE/gh.log" ] && ok \
  || bad "S1 only TrkIssues requests, no gh: $(cat "$LS_STATE/reqs" 2>/dev/null)"
fresh; scratch_rm "$H/state/hotfix-announced"
"$H/bin/hotfix-seen.sh" crolin --paused
grep -q 'hotfix CRO-12 is waiting on flags/paused-crolin' "$H/logs/crolin.log" && [ ! -s "$H/logs/ALERTS.log" ] && ok \
  || bad "S2 --paused writes the waiting line and announces nothing: $(cat "$H/logs/crolin.log")"
fresh; fail_linear
"$H/bin/hotfix-seen.sh" crolin; rc=$?
[ "$rc" = 0 ] && grep -q 'hotfix listing UNVERIFIABLE (linear list)' "$H/logs/crolin.log" && [ ! -s "$H/logs/ALERTS.log" ] \
  && [ ! -e "$H/state/hotfix-announced/crolin" ] && ok || bad "S3 a failed list: the UNVERIFIABLE line, rc 0, no announce (rc=$rc): $(cat "$H/logs/crolin.log")"
fresh
"$H/bin/hotfix-seen.sh" ghp
grep -q 'labels=ai-build,hotfix' "$LS_STATE/gh.log" 2>/dev/null && [ "$(linear_req_count)" = 0 ] && ok \
  || bad "S4 a column-4 project with no env file lists GitHub as today: $(cat "$LS_STATE/gh.log" 2>/dev/null)"

# ── A: the AND (BH-8451, BLOCK row 4515) ─────────────────────────────────────
# CRO-31 is an open Todo labelled hotfix WITHOUT ai-build: it is outside the
# build queue, so hotfix-seen and triage_hot_load must not see it. GitHub's arm
# sends labels=ai-build,hotfix (S4); the tracker arm must be the same AND.
and_fix() { jq -e '.data.issues.nodes += [{"identifier":"CRO-31","title":"Hotfix outside the queue","url":"https://linear.app/crosstest/issue/CRO-31/x","updatedAt":"2026-10-21T10:30:00.000Z","state":{"name":"Todo","type":"unstarted"},"labels":{"nodes":[{"name":"hotfix"}]},"comments":{"nodes":[],"pageInfo":{"hasNextPage":false}}}]' \
  "$FIX/issues.json" > "$LS_STATE/issues.json" || bad "A0 the CRO-31 fixture did not build"; }
fresh; and_fix
out=$( ( . "$H/bin/lib/trk-lane.sh"; trk_lane_list "$H" crolin a1 --state open --label hotfix ) ); rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -c '[.[].key]')" = '["CRO-12"]' ] && ok \
  || bad "A1 --label hotfix is an AND with ai-build: only CRO-12 (rc=$rc): $(printf '%s' "$out" | jq -c '[.[].key]' 2>/dev/null)"
fresh; and_fix
out=$(hot crolin)
[ "$(head -1 <<<"$out")" = "[ 12 ]" ] && ok || bad "A2 a hotfix ticket without ai-build is not in TRIAGE_HOT: $(head -1 <<<"$out")"
keys=$( ( export HARNESS="$H" PROJECT=crolin; . "$H/bin/lib/triage-shards-lib.sh"; . "$H/bin/lib/triage-hotfix-lib.sh"
          triage_hot_load; printf '%s' "$TRIAGE_HOT_KEYS" ) 2>/dev/null)
[ "$keys" = "CRO-12" ] || [ "$keys" = "CRO-12 " ] && ok || bad "A2 TRIAGE_HOT_KEYS is CRO-12 only: '$keys'"
fresh; and_fix; scratch_rm "$H/state/hotfix-announced"
"$H/bin/hotfix-seen.sh" crolin
[ ! -e "$H/state/hotfix-announced/crolin/CRO-31.seen" ] && ! grep -q 'CRO-31' "$H/logs/ALERTS.log" && ok \
  || bad "A3 a hotfix ticket without ai-build gets no marker and no announce: $(cat "$H/logs/ALERTS.log")"
[ -f "$H/state/hotfix-announced/crolin/CRO-12.seen" ] && [ "$(grep -c HOTFIX "$H/logs/ALERTS.log")" = 1 ] && ok \
  || bad "A3 CRO-12 (ai-build AND hotfix) is still the one announce: $(cat "$H/logs/ALERTS.log")"
rm -f "$LS_STATE/issues.json"

# ── F: run-preplan TICKET_FP ─────────────────────────────────────────────────
FP=$(sed -n '/^TICKET_FP() {/,/^}/p' "$H/bin/run-preplan.sh")
[ -n "$FP" ] || bad "F0 TICKET_FP not found in bin/run-preplan.sh"
fp() { ( export HARNESS="$H"; PROJECT="$1"; TICKET="$2"; HENV="$H/env"; . "$H/bin/lib/trk-lane.sh"; eval "$FP"; TICKET_FP ) 2>/dev/null; }
# A token in the env file is what makes today's code read the ticket.
fresh; printf 'INTERNAL_API_TOKEN=tok-fixture-crolin-8451\n' >> "$H/env/crolin.env"
out=$(fp crolin CRO-12)
[ -z "$out" ] && ! grep -q '/tickets/' "$LS_STATE/reqs" 2>/dev/null && ok || bad "F1 a Linear project: no fingerprint, no ticket read (out=$out): $(cat "$LS_STATE/reqs" 2>/dev/null)"
envfile
fresh
fp bproj TK-3 >/dev/null
grep -q 'https://b.example/api/board/tickets/TK-3' "$LS_STATE/reqs" 2>/dev/null && ok || bad "F2 a board project still reads its ticket: $(cat "$LS_STATE/reqs" 2>/dev/null)"

# ── L: launch-fastpath ───────────────────────────────────────────────────────
fresh
out=$("$H/bin/launch-fastpath.sh" crolin CRO-12 2>/dev/null); rc=$?
[ "$rc" = 1 ] && [ "$out" = CRO-12 ] && grep -q 'FASTPATH-DECLINED CRO-12 :: not a GitHub-Issues board (linear)$' "$H/logs/crolin.log" && ok \
  || bad "L1 a Linear key is declined (rc=$rc out=$out): $(cat "$H/logs/crolin.log")"
[ ! -s "$LS_STATE/gh.log" ] && ok || bad "L1 no gh call: $(cat "$LS_STATE/gh.log")"
fresh; : > "$H/logs/bproj.log"
"$H/bin/launch-fastpath.sh" bproj 7 >/dev/null 2>&1
grep -q 'FASTPATH-DECLINED 7 :: not a GitHub-Issues board$' "$H/logs/bproj.log" && ok || bad "L2 a board project keeps the old reason: $(cat "$H/logs/bproj.log")"

# ── P: preplan-candidates ────────────────────────────────────────────────────
fresh
printf 'CRO-7 CRO-7 — queued fixture project=crolin\n' > "$H/logs/READY-QUEUE.log"
mkdir -p "$H/builds/crolin-CRO-16-202610211000" "$H/plans/crolin-CRO-17"
echo empty > "$H/plans/crolin-CRO-17/outcome"
out=$("$H/bin/preplan-candidates.sh" crolin 2>/dev/null); rc=$?
printf '%s\n' "$out" > "$T/p1.out"
[ "$rc" = 0 ] && [ "$(head -1 <<<"$out")" = "$(printf 'CRO-7\tCRO-7\tqueued')" ] && ok || bad "P1 the queued line first (rc=$rc): $(tr '\t\n' ' |' <<<"$out")"
grep -qxF "$(printf 'CRO-12\tCRO-12\tahead')" "$T/p1.out" && ok || bad "P1 CRO-12 is offered ahead: $(tr '\t\n' ' |' <<<"$out")"
grep -qE '^(CRO-15|CRO-20)[[:space:]]' "$T/p1.out" \
  && bad "P2 In Progress (CRO-15) or In Review (CRO-20) was offered: $(tr '\t\n' ' |' <<<"$out")" || ok
grep -qE '^(CRO-13|CRO-14)[[:space:]]' "$T/p1.out" && bad "P2 a Done or unlabelled ticket was offered" || ok
grep -qE '^CRO-16[[:space:]]' "$T/p1.out" && bad "P4 a mid-build key (CRO-16) was offered" || ok
grep -qE '^CRO-17[[:space:]]' "$T/p1.out" && bad "P4 a TERMINAL key (CRO-17) was offered" || ok
grep -qE '^CRO-18[[:space:]]' "$T/p1.out" && ok || bad "P4 an unbusy ticket that is not mid-build or terminal (CRO-18) is offered: $(tr '\t\n' ' |' <<<"$out")"
[ ! -s "$LS_STATE/gh.log" ] && ! grep -q 'b.example\|x.example' "$LS_STATE/reqs" 2>/dev/null && ok || bad "P1 no GitHub or board read"
fresh; fail_linear
out=$("$H/bin/preplan-candidates.sh" crolin 2>/dev/null); rc=$?
[ "$rc" = 0 ] && [ "$out" = "$(printf 'CRO-7\tCRO-7\tqueued')" ] && grep -q 'launch gate UNKNOWN (linear list unreadable)' "$H/logs/crolin.log" && ok \
  || bad "P5 a failed list: the queued line only and the UNKNOWN log line (rc=$rc out=$out): $(cat "$H/logs/crolin.log")"
rm -f "$H/logs/READY-QUEUE.log"

LEAK=$(grep -rl "$KEY" "$H/state" "$H/logs" "$LS_STATE" 2>/dev/null)
[ -n "$LEAK" ] && bad "K the Linear key reached a state, log or stub file" || ok

# ── Jira: S5, P3 (a second scratch root) ─────────────────────────────────────
J="$T/j"
(
  jira_stub_setup "$J" >/dev/null || exit 1
  # The shipped fixture plus SCRUM-31: To Do, labelled hotfix WITHOUT ai-build
  # (the AND, BLOCK row 4515). The JQL asks for hotfix; the lane seam drops it.
  JF="$J/jfix"; mkdir -p "$JF"; cp "$REPO/tests/fixtures/lane-ports.bh-8451/jira/"*.json "$JF/" || exit 1
  jq '.issues += [(.issues[] | select(.key == "SCRUM-12")) | .key = "SCRUM-31" | .id = "10031" | .fields.summary = "Hotfix outside the queue" | .fields.labels = ["hotfix"]]' \
    "$REPO/tests/fixtures/lane-ports.bh-8451/jira/search-page1.json" > "$JF/search-page1.json" || exit 1
  export JIRA_STUB_FIX="$JF"
  JH="$J/h"; mkdir -p "$JH/flags" "$JH/prompts" "$JH/builds" "$JH/plans"
  for L in bin/hotfix-seen.sh bin/preplan-candidates.sh bin/jobs-client.sh bin/fleet-conf.sh bin/project-of.sh bin/internal-token-for.sh; do
    ( cd "$REPO" && scratch_install_closure "$L" "$JH" ) >/dev/null || exit 1
  done
  echo 'jproj  o/j  https://j.example  -  9' > "$JH/fleet.conf"
  : > "$JH/env/global.env"
  export HARNESS="$JH" FLEET_CONF="$JH/fleet.conf"
  jira_unset tracker_jira.jproj.write_projects; jira_unset tracker_jira.jproj.comment_projects
  jira_set tracker_jira.jproj.read_projects SCRUM
  "$JH/bin/hotfix-seen.sh" jproj
  [ -f "$JH/state/hotfix-announced/jproj/SCRUM-12.seen" ] && grep -q '\[jproj/SCRUM-12\] HOTFIX seen: SCRUM-12 — Ledger export to CSV' "$JH/logs/ALERTS.log" \
    && echo "S5 ok" || echo "S5 bad: $(cat "$JH/logs/ALERTS.log" 2>/dev/null)"
  [ "$(jq -r .jql "$JIRA_STUB_STATE/search-req-1.json" 2>/dev/null)" = 'project in ("SCRUM") AND labels = "hotfix" AND statusCategory != Done ORDER BY updated DESC' ] \
    && echo "S5 ok" || echo "S5 bad jql: $(jq -r .jql "$JIRA_STUB_STATE/search-req-1.json" 2>/dev/null)"
  [ ! -e "$JH/state/hotfix-announced/jproj/SCRUM-31.seen" ] && ! grep -q 'SCRUM-31' "$JH/logs/ALERTS.log" && [ "$(grep -c HOTFIX "$JH/logs/ALERTS.log")" = 1 ] \
    && echo "S5 ok" || echo "S5 bad: a hotfix ticket without ai-build was announced: $(cat "$JH/logs/ALERTS.log" 2>/dev/null)"
  out=$("$JH/bin/preplan-candidates.sh" jproj 2>/dev/null)
  grep -qxF "$(printf 'SCRUM-17\tSCRUM-17\tahead')" <<<"$out" && echo "P3 ok" || echo "P3 bad: SCRUM-17 not offered: $(tr '\t\n' ' |' <<<"$out")"
  grep -qE '^SCRUM-15[[:space:]]' <<<"$out" && echo "P3 bad: needs_clarification + client was offered" || echo "P3 ok"
  grep -qE '^SCRUM-16[[:space:]]' <<<"$out" && echo "P3 bad: In Progress was offered" || echo "P3 ok"
  grep -qE '^SCRUM-31[[:space:]]' <<<"$out" && echo "P3 bad: a ticket without ai-build was offered" || echo "P3 ok"
  [ ! -s "$JIRA_STUB_STATE/gh.log" ] && echo "S5 ok" || echo "S5 bad: gh was called: $(cat "$JIRA_STUB_STATE/gh.log")"
) > "$T/jira.out" 2>/dev/null || echo "J setup bad" >> "$T/jira.out"
while IFS= read -r l; do
  case "$l" in *" ok") ok ;; *) bad "$l" ;; esac
done < "$T/jira.out"
[ "$(grep -c ' ok$' "$T/jira.out")" = 8 ] && ok || bad "J expected 8 Jira checks to pass: $(tr '\n' '|' < "$T/jira.out")"

echo "lane-ports-linear: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
