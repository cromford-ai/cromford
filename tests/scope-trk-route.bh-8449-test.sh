#!/bin/bash
# tests/scope-trk-route.bh-8449-test.sh — BH-8449 (C1 of #7920): the tick
# scope routes on tracker_kind, and a Jira or Linear wake key's closed state
# is read through tracker_read.
#
#   S1  a Linear project (env LINEAR_API_KEY, row linear, column 4 `-`) with a
#       changed fingerprint: board_section sets BOARD_OK=1 and BOARD_SEC holds
#       the gate diff line
#   S2  in S1 no GitHub or in-app reader runs: unblocked-children.sh,
#       stack-launch.sh, merged-ticket-advance.sh, decompose-parent-close.sh
#       and triage_hot_load are each called 0 times
#   S3  a Linear project with an unchanged fingerprint (gate-diff rc 2):
#       BOARD_OK=1, BOARD_SEC empty, 0 recorder calls
#   S4  a GitHub project (column 4 `-`, no env key): unblocked-children.sh
#       runs once, as today, and 0 settings requests are made
#   S5  an in-app board project (column 4 a prefix, no env key):
#       merged-ticket-advance.sh runs as today, 0 settings requests
#   S6  a Jira project whose column 4 is NOT `-` (env JIRA_BASE, row jira):
#       inapp_released_lines prints nothing and runs no in-app lane; the same
#       files on the board project print the UNBLOCKED line (the control)
#   S7  the settings worker is down for a Linear project: tracker_kind takes
#       the column-4 fallback (github-issues), so board_section takes the
#       GitHub path, the same answer the gate gives (C0's I12)
#   K1  issue_closures crolin CRO-13 with a completed CRO-13 prints CRO-13
#   K2  an open CRO-12 prints nothing, rc 0
#   K3  a bare 12 and a lower-case cro-12 are skipped with 0 Linear requests
#   K4  a failed read is skipped and the loop goes on: CRO-404 CRO-13 -> CRO-13
#   K5  the read's `state`: Linear completed/canceled read closed, started/
#       unstarted/no type read open; Jira category done reads closed,
#       indeterminate reads open
#   K6  a board-kind project is rc 1 with 0 reads; RD_ON=0 is rc 1 with 0 reads
#
# Settings are a stub bin/jobs-client.sh over files ($ROWS/<key>); Linear is
# tests/lib/linear-stub.bh-7920.sh, Jira tests/lib/tracker-jira-stub.sh. No
# network.
#   HARNESS_TEST_SANDBOX=1 bash tests/scope-trk-route.bh-8449-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/linear-stub.bh-7920.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

KEY=lin-api-fixture-sentinel-8449
H="$T/h"; ROWS="$T/rows"; FIX="$T/fix"
mkdir -p "$H/bin/lib/rt" "$H/env" "$H/state" "$H/logs" "$H/calls" "$ROWS" "$FIX"
export FLEET_CONF="$H/fleet.conf"
scratch_install_closure bin/lib/rt/scope.sh "$H" >/dev/null || exit 1
scratch_install_closure bin/lib/tracker.sh "$H" >/dev/null || exit 1
scratch_install_closure bin/fleet-conf.sh "$H" >/dev/null || exit 1
cat > "$H/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset>
crolin  o/crolin  https://cl.example  -           2
jproj   o/jproj   https://jp.example  /api/board  3
ghp     o/ghp     https://gh.example  -           4
bdp     o/bdp     https://bd.example  /api/board  5
CONF
# The settings worker: setting_get <key> -> $ROWS/<key>; rc 2 no row; rc 1 with
# $T/settings-down. Every call is one line in $T/settings.log.
cat > "$H/bin/jobs-client.sh" <<'SH'
setting_get() {
  echo "$1" >> "$SETLOG"
  [ -e "$SETDOWN" ] && return 1
  [ -r "$ROWS/$1" ] || return 2
  cat "$ROWS/$1"
}
SH
export ROWS SETLOG="$T/settings.log" SETDOWN="$T/settings-down"
printf 'linear' > "$ROWS/tracker_adapter.crolin"
printf 'jira'   > "$ROWS/tracker_adapter.jproj"
printf 'LINEAR_API_KEY=%s\nLINEAR_TEAM=CRO\n' "$KEY" > "$H/env/crolin.env"

# The stage scripts board_section can reach: the gate and its diff are
# answered from files, every reader is a recorder.
printf '#!/bin/bash\nexit 0\n' > "$H/bin/triage-gate.sh"
cat > "$H/bin/gate-diff.sh" <<'SH'
#!/bin/bash
cat "$HARNESS/gd.out" 2>/dev/null
exit "$(cat "$HARNESS/gd.rc" 2>/dev/null || echo 1)"
SH
for s in unblocked-children stack-launch merged-ticket-advance decompose-parent-close; do
  printf '#!/bin/bash\necho "$*" >> "$HARNESS/calls/%s"\n' "$s" > "$H/bin/$s.sh"
done
chmod +x "$H/bin/"*.sh
calls() { cat "$H/calls/"* 2>/dev/null | grep -c .; }
ncall() { cat "$H/calls/$1" 2>/dev/null | grep -c .; }
reset() { rm -f "$H/calls/"* "$SETLOG" "$SETDOWN" "$H/gd.out" "$H/gd.rc"; }

# bs <project> [VAR=value...] — board_section in a fresh shell, as run-triage
# runs it after sourcing the project's env file. Prints OK=<BOARD_OK>, then
# BOARD_SEC.
bs() {
  local p="$1"; shift
  ( export HARNESS="$H" PROJECT="$p"; unset JIRA_BASE LINEAR_API_KEY
    for a in "$@"; do export "${a?}"; done
    triage_hot_load() { echo load >> "$HARNESS/calls/hot-load"; }
    triage_hot_mark() { cat; }
    # shellcheck source=/dev/null
    . "$H/bin/lib/rt/scope.sh" || exit 9
    board_section; printf 'OK=%s\n%s' "$BOARD_OK" "$BOARD_SEC" )
}

# ---- S1-S3: Linear ------------------------------------------------------------------
reset; printf 'board linear: CHANGED CRO-12 "Ledger export" (commentCount: 2 -> 3)\n' > "$H/gd.out"; echo 0 > "$H/gd.rc"
out=$(bs crolin LINEAR_API_KEY="$KEY")
eq "S1 BOARD_OK" "$(head -1 <<<"$out")" "OK=1"
grep -qF 'CHANGED CRO-12' <<<"$out" && ok || bad "S1 BOARD_SEC holds the gate diff: $out"
grep -qF 'ALSO changed on the board since the last consumed tick' <<<"$out" && ok || bad "S1 BOARD_SEC header: $out"
eq "S2 unblocked-children calls" "$(ncall unblocked-children)" 0
eq "S2 stack-launch calls" "$(ncall stack-launch)" 0
eq "S2 merged-ticket-advance calls" "$(ncall merged-ticket-advance)" 0
eq "S2 decompose-parent-close calls" "$(ncall decompose-parent-close)" 0
eq "S2 triage_hot_load calls" "$(ncall hot-load)" 0
eq "S1 one settings read (tracker_adapter.crolin)" "$(paste -sd' ' "$SETLOG" 2>/dev/null)" "tracker_adapter.crolin"

reset; echo 2 > "$H/gd.rc"
out=$(bs crolin LINEAR_API_KEY="$KEY")
eq "S3 BOARD_OK" "$(head -1 <<<"$out")" "OK=1"
eq "S3 BOARD_SEC empty" "$(tail -n +2 <<<"$out")" ""
eq "S3 recorder calls" "$(calls)" 0

# A gate-diff failure (rc 1) stays BOARD_OK=0 on the contract branch too.
reset; echo 1 > "$H/gd.rc"
out=$(bs crolin LINEAR_API_KEY="$KEY")
eq "S3 gate-diff rc 1 keeps BOARD_OK=0" "$(head -1 <<<"$out")" "OK=0"
eq "S3 gate-diff rc 1 recorder calls" "$(calls)" 0

# ---- S4: GitHub ---------------------------------------------------------------------
reset; printf 'board issues: CHANGED 12 "x" (state: open -> closed)\n' > "$H/gd.out"; echo 0 > "$H/gd.rc"
out=$(bs ghp)
eq "S4 BOARD_OK" "$(head -1 <<<"$out")" "OK=1"
eq "S4 unblocked-children runs once" "$(ncall unblocked-children)" 1
eq "S4 0 settings requests" "$(cat "$SETLOG" 2>/dev/null | grep -c .)" 0
# The same project with LINEAR_API_KEY but no row is still GitHub (near miss).
reset; printf 'board issues: CHANGED 12 "x"\n' > "$H/gd.out"; echo 0 > "$H/gd.rc"
bs ghp LINEAR_API_KEY="$KEY" >/dev/null
eq "S4 env key with no row: GitHub path" "$(ncall unblocked-children)" 1

# ---- S5: in-app board ---------------------------------------------------------------
reset; printf 'board b1: CHANGED t1 "x"\n' > "$H/gd.out"; echo 0 > "$H/gd.rc"
out=$(bs bdp)
eq "S5 BOARD_OK" "$(head -1 <<<"$out")" "OK=1"
eq "S5 merged-ticket-advance runs" "$(ncall merged-ticket-advance)" 1
eq "S5 0 settings requests" "$(cat "$SETLOG" 2>/dev/null | grep -c .)" 0

# ---- S6: Jira with a board prefix in column 4 -------------------------------------
# A blocked true -> false flip between the consumed and live fingerprints: the
# in-app reader prints UNBLOCKED for a board project (control) and must stay
# silent for a Jira one.
for p in jproj bdp; do
  printf '{"b1":[{"id":"t1","key":"AB-1","title":"x","blocked":true}]}' > "$H/state/$p.gate.json"
  printf '{"b1":[{"id":"t1","key":"AB-1","title":"x","blocked":false}]}' > "$H/state/$p.gate.pending"
done
iar() { ( export HARNESS="$H" PROJECT="$1"; unset JIRA_BASE LINEAR_API_KEY; shift
          for a in "$@"; do export "${a?}"; done
          # shellcheck source=/dev/null
          . "$H/bin/lib/rt/scope.sh" || exit 9; inapp_released_lines ); }
reset
out=$(iar jproj JIRA_BASE=https://api.atlassian.example/ex/jira/fixture)
eq "S6 jira prints nothing" "$out" ""
eq "S6 jira runs no in-app lane" "$(calls)" 0
reset
out=$(iar bdp)
grep -q 'UNBLOCKED t1' <<<"$out" && ok || bad "S6 control: the board project prints the release: $out"
eq "S6 control: the board project runs merged-ticket-advance" "$(ncall merged-ticket-advance)" 1
# And JIRA_BASE without a jira row on that board project is the board path.
reset
out=$(iar bdp JIRA_BASE=https://api.atlassian.example/ex/jira/fixture)
grep -q 'UNBLOCKED t1' <<<"$out" && ok || bad "S6 env key on a board row: the board path: $out"

# ---- S7: the worker is down -----------------------------------------------------------
reset; printf 'board issues: CHANGED 12 "x"\n' > "$H/gd.out"; echo 0 > "$H/gd.rc"; : > "$SETDOWN"
out=$(bs crolin LINEAR_API_KEY="$KEY")
eq "S7 BOARD_OK" "$(head -1 <<<"$out")" "OK=1"
eq "S7 the GitHub path: unblocked-children runs once" "$(ncall unblocked-children)" 1

# ---- K: issue_closures ------------------------------------------------------------------
# The fixtures: CRO-12 open (unstarted), CRO-13 completed, CRO-14 canceled,
# CRO-15 started, CRO-16 no state type; anything else is not-found.
SRC="$DIR/tests/fixtures/triage-intake.bh-7920/linear"
cp "$SRC/not-found.json" "$FIX/"
mk() { jq --arg id "$1" --arg ty "$2" '.data.issue.identifier = $id
         | if $ty == "" then .data.issue.state = {name: "Odd"} else .data.issue.state = {name: $ty, type: $ty} end' \
         "$SRC/issue-CRO-12.json" > "$FIX/issue-$1.json"; }
mk CRO-12 unstarted; mk CRO-13 completed; mk CRO-14 canceled; mk CRO-15 started; mk CRO-16 ""
linear_stub_setup "$T" "$FIX" || { echo "stub setup failed"; exit 1; }
export LS_KEY_EXPECT="$KEY"
awk '$0 ~ "^issue_closures\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$DIR/bin/wake-loop.sh" > "$T/closures.sh"
[ -s "$T/closures.sh" ] && ok || bad "K: could not extract issue_closures from bin/wake-loop.sh"
# ic <RD_ON> <project> <key>... — the shipped function in a fresh shell, the
# tracker lib not pre-sourced (it loads it itself, as in production).
ic() {
  local rd="$1"; shift
  linear_reset_log
  ( export HARNESS="$H"; SELF="$H/bin"; RD_ON="$rd"
    revdep_issue_state() { echo "gh-state $*" >> "$T/calls/gh-state"; echo OPEN; }
    # shellcheck source=/dev/null
    . "$T/closures.sh"; issue_closures "$@"; echo "rc=$?" )
}
lreads() { linear_req_count TrkIssue; }
lids()   { awk '$4 == "TrkIssue" {print $1}' "$LS_STATE/reqs" 2>/dev/null | while read -r n; do jq -r .variables.id "$LS_STATE/req-$n.json"; done | paste -sd' ' -; }

reset
eq "K1 completed CRO-13 is a closure" "$(ic 1 crolin CRO-13 | paste -sd' ' -)" "CRO-13 rc=0"
eq "K1 one Linear read for CRO-13" "$(lids)" "CRO-13"
eq "K2 open CRO-12 prints nothing" "$(ic 1 crolin CRO-12 | paste -sd' ' -)" "rc=0"
eq "K2 one Linear read" "$(lreads)" 1
eq "K3 a bare 12 and cro-12 are skipped" "$(ic 1 crolin 12 cro-12 | paste -sd' ' -)" "rc=0"
eq "K3 0 Linear requests" "$(lreads)" 0
eq "K4 a failed read is skipped" "$(ic 1 crolin CRO-404 CRO-13 | paste -sd' ' -)" "CRO-13 rc=0"
eq "K4 both keys were read" "$(lids)" "CRO-404 CRO-13"
eq "K1 canceled CRO-14 is a closure, started CRO-15 is not" "$(ic 1 crolin CRO-14 CRO-15 CRO-16 | paste -sd' ' -)" "CRO-14 rc=0"
eq "K no GitHub state read for a Linear project" "$(cat "$T/calls/gh-state" 2>/dev/null | grep -c .)" 0
[ ! -e "$LS_STATE/authbad" ] && ok || bad "K a Linear call carried the wrong key"
eq "K6 board project: rc 1" "$(ic 1 bdp AB-1 | paste -sd' ' -)" "rc=1"
eq "K6 board project: 0 reads" "$(lreads)" 0
eq "K6 RD_ON=0: rc 1" "$(ic 0 crolin CRO-13 | paste -sd' ' -)" "rc=1"
eq "K6 RD_ON=0: 0 reads" "$(lreads)" 0
# A Linear project whose context does not load (no env file key) is rc 1.
printf 'LINEAR_TEAM=CRO\n' > "$H/env/crolin.env"
eq "K6 no Linear context: rc 1" "$(ic 1 crolin CRO-13 | paste -sd' ' -)" "rc=1"
eq "K6 no Linear context: 0 reads" "$(lreads)" 0
printf 'LINEAR_API_KEY=%s\nLINEAR_TEAM=CRO\n' "$KEY" > "$H/env/crolin.env"

# ---- K5: the read's state -------------------------------------------------------------
rs() { ( export HARNESS="$H"; . "$H/bin/lib/tracker.sh"; TRK_ERR=/dev/null tracker_context crolin k5 || exit 9
         tracker_read "$1" | jq -r '.state // "absent"' ); }
eq "K5 linear completed"  "$(rs CRO-13)" closed
eq "K5 linear canceled"   "$(rs CRO-14)" closed
eq "K5 linear started"    "$(rs CRO-15)" open
eq "K5 linear unstarted"  "$(rs CRO-12)" open
eq "K5 linear no type"    "$(rs CRO-16)" open
linear_req_of TrkIssue | jq -r .query | grep -qF 'state { name type }' \
  && ok || bad "K5 the TrkIssue query asks state { name type }: $(linear_req_of TrkIssue | jq -r .query)"

# Jira, in its own shell: the Jira stub owns curl there.
jk5() {
  ( . "$DIR/tests/lib/tracker-jira-stub.sh" || exit 9
    jira_stub_setup "$T/j" || exit 9
    jq --arg k "$1" '.fields.status.statusCategory.key = $k' "$DIR/tests/fixtures/tracker-jira/issue-CROM-1.json" \
      > "$JIRA_STUB_STATE/issue-CROM-1.json"
    . "$DIR/bin/lib/tracker.sh" || exit 9
    tracker_load jira || exit 9
    TRK_ERR=/dev/null trk_jira_context jproj || exit 9
    tracker_read CROM-1 | jq -r '.state // "absent"' )
}
eq "K5 jira done"          "$(jk5 done)" closed
eq "K5 jira indeterminate" "$(jk5 indeterminate)" open

# The key reached nothing it should not.
LEAK=$(grep -rlF -- "$KEY" "$H/state" "$H/logs" "$H/calls" "$LS_STATE" 2>/dev/null)
[ -z "$LEAK" ] && ok || bad "the Linear key reached: $LEAK"

echo "scope-trk-route.bh-8449: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
