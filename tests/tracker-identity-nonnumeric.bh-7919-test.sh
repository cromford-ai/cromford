#!/bin/bash
# tests/tracker-identity-nonnumeric.bh-7919-test.sh — BH-7919: a Linear or
# Jira key is never read as a GitHub issue number, and identity accepts it.
#
#   G1-G12  trk_gh_issue_number (bin/lib/tracker.sh): the decision table
#   I1-I8   ticket_identity (bin/lib/ticket-identity.sh): the identity table
#   I9-I10  preplan_key_prefix: the tracker's prefix for jira/linear, never
#           the prompt's; the prompt grep for GitHub
#   I11     ticket_identity_conflict source (a2) derives nothing for a linear
#           project, and still derives TK-2487 for a GitHub one
#   B1-B2   ticket_branch_key parses ticket/cro-12 and ticket/cro-12-r2
#   P1-P6   the ported sites, each the real function: a project with column 4
#           `-` AND a tracker_adapter=linear row makes 0 GitHub calls; the same
#           sites on a GitHub project make the call on issue 12. (The PR body,
#           bin/lib/rb/pr.sh, is tests/pr-body-no-closes-nongh.bh-7919-test.sh.)
#   P7      the replan comment block (rb/plan.sh, RPC_N) with an App token:
#           a linear project writes replan-comment-skipped, no
#           replan-commented, and makes 0 gh_rest_comment calls; the same
#           project with no row posts on issue 12
#
# The settings worker is a stub bin/jobs-client.sh (setting_get reads
# $ROWS/<key>). Every GitHub call is a stub function or a stub script that logs
# one line to $SINK. No network.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; ROWS="$T/rows"; SINK="$T/sink"
export FLEET_CONF="$H/fleet.conf"  # fleet-conf.sh reads /root/harness/fleet.conf before its own dir
mkdir -p "$H/bin/lib" "$H/env" "$H/logs" "$H/prompts" "$H/builds" "$H/state" "$ROWS" "$T/fb"
cat > "$H/bin/jobs-client.sh" <<'SH'
# stub jobs client: setting_get <key> -> $ROWS/<key>; rc 2 no row
setting_get() { [ -r "$ROWS/$1" ] || return 2; cat "$ROWS/$1"; }
SH
scratch_install_closure bin/fleet-conf.sh "$H" >/dev/null || exit 1
scratch_install_closure bin/lib/tracker.sh "$H" >/dev/null || exit 1
scratch_install_closure bin/lib/ticket-identity.sh "$H" >/dev/null || exit 1
scratch_install_closure bin/lib/preplan-lib.sh "$H" >/dev/null || exit 1
scratch_install_closure bin/lib/ticket-branch.sh "$H" >/dev/null || exit 1
scratch_install_closure bin/lib/execute-empty.sh "$H" >/dev/null || exit 1
cat > "$H/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset> [box] [ip]
gh  o/gh  https://gh.example  -           1 box-1 192.0.2.1
bd  o/bd  https://bd.example  /api/board  2 box-1 192.0.2.1
jr  o/jr  https://jr.example  -           5 box-1 192.0.2.1
ln  o/ln  https://ln.example  -           6 box-1 192.0.2.1
lx  o/lx  https://lx.example  -           7 box-1 192.0.2.1
ty  o/ty  https://ty.example  -           8 box-1 192.0.2.1
CONF
printf 'JIRA_BASE=https://api.atlassian.com/ex/jira/33333333-3333-3333-3333-333333333333\nJIRA_EMAIL=bot@example.com\nJIRA_API_TOKEN=tok-fixture-jr\n' > "$H/env/jr.env"
printf 'LINEAR_API_KEY=tok-fixture-ln\nLINEAR_TEAM=CRO\n' > "$H/env/ln.env"
printf 'LINEAR_TEAM=CRO\n' > "$H/env/lx.env"
printf 'jira' > "$ROWS/tracker_adapter.jr"
printf 'SCRUM' > "$ROWS/tracker_jira.jr.write_projects"
printf 'linaer' > "$ROWS/tracker_adapter.ty"
linear_on()  { printf 'linear' > "$ROWS/tracker_adapter.ln"; printf 'linear' > "$ROWS/tracker_adapter.lx"; }
linear_off() { rm -f "$ROWS/tracker_adapter.ln" "$ROWS/tracker_adapter.lx"; }
linear_on
# The rendered launch lines preplan_key_prefix greps. The linear project's says
# another prefix on purpose (I10): it must never be read.
echo 'setsid /root/harness/bin/run-build.sh gh <issue-number> TK-<issue-number> > x' > "$H/prompts/gh.md"
echo 'setsid /root/harness/bin/run-build.sh ln <issue-number> XX-<issue-number> > x' > "$H/prompts/ln.md"
echo 'setsid /root/harness/bin/run-build.sh lx <issue-number> XX-<issue-number> > x' > "$H/prompts/lx.md"

sh() { local s="$1"; shift; HARNESS="$H" ROWS="$ROWS" bash -c '. "$HARNESS/bin/lib/tracker.sh" || exit 9; '"$s" "$@"; }

# ---- G: trk_gh_issue_number --------------------------------------------------------
g() { sh 'out=$(trk_gh_issue_number "$1" "$2"); rc=$?; echo "$out rc=$rc"' _ "$1" "$2" 2>/dev/null; }
eq G1  "$(g gh BH-12)"      "12 rc=0"
eq G2  "$(g gh 12)"         "12 rc=0"
eq G3  "$(g gh bh-12)"      "12 rc=0"
eq G4  "$(g gh BH-7916.1)"  " rc=1"
eq G5  "$(g gh 'CRO 12')"   " rc=1"
eq G6  "$(g gh TS2-12)"     " rc=1"
eq G7  "$(g gh '')"         " rc=1"
eq G8  "$(g ln CRO-12)"     " rc=3"
eq G9  "$(g jr SCRUM-3)"    " rc=3"
eq G10 "$(g bd AB-12)"      " rc=3"
eq G11 "$(g ty BH-12)"      " rc=3"
eq G12 "$(g nope BH-12)"    " rc=3"

# ---- I: ticket_identity ---------------------------------------------------------------
ti() { sh '. "$HARNESS/bin/lib/ticket-identity.sh" || exit 9; out=$(ticket_identity "$HARNESS" "$1" "$2" 2>"$ERRF"); echo "$out rc=$?"' _ "$1" "$2"; }
export ERRF="$T/ti.err"
eq I1 "$(ti ln CRO-12)" "CRO-12 rc=0"
eq I2 "$(ti ln cro-12)" "cro-12 rc=0"
eq I3 "$(ti ln ENG-12)" " rc=1"
eq "I3 one stderr line" "$(grep -c . "$ERRF")" 1
eq I4 "$(ti ln 12)"     " rc=1"
eq I5 "$(ti ln CRO-0)"  " rc=1"
eq I6 "$(ti gh CRO-12)" " rc=1"
eq I7 "$(ti gh 12)"     "12 rc=0"
eq "I8 jira key" "$(ti jr SCRUM-3)" "SCRUM-3 rc=0"
eq "I8 jira other project" "$(ti jr CROM-3)" " rc=1"
eq "I8 board id" "$(ti bd cmXyz01)" "cmXyz01 rc=0"
eq "I8 board bad id" "$(ti bd 'a b')" " rc=1"
eq "I8 linear with no context" "$(ti lx CRO-12)" " rc=1"
eq "I8 unresolved tracker" "$(ti ty 12)" " rc=1"

# ---- I9-I10: preplan_key_prefix ------------------------------------------------------
pk() { sh '. "$HARNESS/bin/lib/preplan-lib.sh" || exit 9; out=$(preplan_key_prefix "$HARNESS" "$1" 2>/dev/null); echo "$out rc=$?"' _ "$1"; }
eq "I9 linear answers the team" "$(pk ln)" "CRO rc=0"
eq "I9 jira answers the project" "$(pk jr)" "SCRUM rc=0"
eq "I9 github answers the prompt" "$(pk gh)" "TS rc=0"
eq "I10 linear with no context never falls back to the prompt" "$(pk lx)" " rc=1"
linear_off
eq "I10 control: the same prompt without the row answers XX" "$(pk ln)" "XX rc=0"
linear_on

# ---- I11: ticket_identity_conflict source (a2) ----------------------------------------
tic() { sh '. "$HARNESS/bin/lib/ticket-identity.sh" || exit 9; out=$(ticket_identity_conflict "$HARNESS" "$1" "$2" "$3" 2>/dev/null); echo "$out rc=$?"' _ "$1" "$2" "$3"; }
out=$(tic gh 2487 TK-2411.2)
eq "I11 github still derives the issues key" "$out" "TK-2487	issues-key	board-key rc=0"
out=$(tic ln 2487 CRO-2411)
case "$out" in *issues-key*) bad "I11 a linear project must derive no issues key: $out" ;; *) ok ;; esac
eq "I11 linear same id and key" "$(tic ln CRO-12 CRO-12)" " rc=1"
linear_off
out=$(tic ln 2487 CRO-2411)
eq "I11 control: without the row the same launch derives XX-2487" "$out" "XX-2487	issues-key	board-key rc=0"
linear_on

# ---- B: ticket_branch_key --------------------------------------------------------------
tb() { bash -c '. "$1/bin/lib/ticket-branch.sh"; ticket_branch_key "$2"' _ "$H" "$1"; }
eq B1 "$(tb ticket/cro-12)" CRO-12
eq B2 "$(tb ticket/cro-12-r2)" CRO-12

# ---- P: the ported sites ------------------------------------------------------------------
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
fn_of() { awk -v f="$2" '$0 ~ "^"f"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$1"; }
fn_of "$RB_ALL" TICKET_META > "$T/meta.sh"
fn_of "$RB_ALL" TICKET_THREAD_SIG > "$T/sig.sh"
fn_of "$RB_ALL" escalate_block > "$T/esc.sh"
fn_of "$DIR/bin/wake-loop.sh" issue_closures > "$T/closures.sh"
awk 'index($0,"# >>> replan comment (BH-3955)"){f=1;next} index($0,"# <<< replan comment (BH-3955)"){f=0} f' "$RB_ALL" > "$T/rpc.sh"
for f in meta sig esc closures rpc; do [ -s "$T/$f.sh" ] && ok || bad "P: could not extract $f from the shipped code"; done
printf '#!/bin/bash\nexit 0\n' > "$T/fb/gh"; chmod +x "$T/fb/gh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
printf '#!/bin/bash\necho "hold $1 $2" >> "$SINK"\n' > "$H/bin/needs-human-hold.sh"; chmod +x "$H/bin/needs-human-hold.sh"
# drive <project> <key> <snippet> — a fresh bash with the GitHub stubs, the
# tracker lib NOT pre-sourced (each site loads it itself, as in production).
drive() {
  : > "$SINK"
  PATH="$T/fb:$PATH" HARNESS="$H" ROWS="$ROWS" SINK="$SINK" PROJECT="$1" KEY="$2" TICKET=x HENV="$H/env" \
    BUILD="$T/b" FP_BEFORE="" T="$T" bash -c '
      gh_rest() { echo "gh_rest $*" >> "$SINK"; echo "[]"; }
      gh_rest_comment() { echo "comment $1 $2" >> "$SINK"; }
      revdep_issue_state() { echo "state $1 $2" >> "$SINK"; echo CLOSED; }
      hold_check() { echo "hold_check $1 $2" >> "$SINK"; printf "held\n"; }
      cm_has() { return 1; }; cm_put() { return 0; }; ptg_own_post() { return 0; }
      STAMP() { echo TS; }
      '"$3" >/dev/null 2>&1
}
sink() { paste -sd'|' "$SINK"; }
mkdir -p "$T/b"

drive ln CRO-12 '. "$T/meta.sh"; TICKET_META'
eq "P1 TICKET_META linear: no GitHub call" "$(sink)" ""
drive gh TK-12 '. "$T/meta.sh"; TICKET_META'
eq "P1 TICKET_META github: reads issue 12" "$(sink)" "gh_rest GET repos/o/gh/issues/12"

drive ln CRO-12 '. "$T/sig.sh"; TICKET_THREAD_SIG'
eq "P2 TICKET_THREAD_SIG linear: no GitHub call" "$(sink)" ""
drive gh TK-12 '. "$T/sig.sh"; TICKET_THREAD_SIG'
eq "P2 TICKET_THREAD_SIG github: reads issue 12's thread" "$(sink)" "gh_rest GET repos/o/gh/issues/12/comments?per_page=100&page=1"

drive ln CRO-12 '. "$T/esc.sh"; escalate_block test-tamper detail'
eq "P4 escalate_block linear: no issue comment" "$(sink)" ""
drive gh TK-12 '. "$T/esc.sh"; escalate_block test-tamper detail'
eq "P4 escalate_block github: comments on issue 12" "$(sink)" "comment o/gh 12"

drive ln CRO-12 'SELF="$HARNESS/bin"; RD_ON=1; . "$T/closures.sh"; issue_closures ln CRO-12 12; echo "rc=$?" >> "$SINK"'
eq "P5 issue_closures linear: no GitHub read, rc 1 (not an issues board)" "$(sink)" "rc=1"
drive gh TK-12 'SELF="$HARNESS/bin"; RD_ON=1; . "$T/closures.sh"; issue_closures gh TK-12 TS2-13'
eq "P5 issue_closures github: reads issue 12 only" "$(sink)" "state o/gh 12"

drive ln CRO-12 '. "$HARNESS/bin/lib/execute-empty.sh"; _ee_post_human ln CRO-12 fp body /dev/null'
eq "P6 _ee_post_human linear: no hold" "$(sink)" ""
drive gh TK-12 '. "$HARNESS/bin/lib/execute-empty.sh"; _ee_post_human gh 12 fp body /dev/null'
eq "P6 _ee_post_human github: holds issue 12" "$(sink)" "hold gh 12"
drive ln CRO-12 '. "$HARNESS/bin/lib/execute-empty.sh"; _ee_lift_epoch ln CRO-12 0'
eq "P6 _ee_lift_epoch linear: no thread read" "$(sink)" ""
drive gh TK-12 '. "$HARNESS/bin/lib/execute-empty.sh"; _ee_lift_epoch gh 12 0'
eq "P6 _ee_lift_epoch github: reads issue 12" "$(sink)" "hold_check o/gh 12"
drive gh BH-7916.1 '. "$HARNESS/bin/lib/execute-empty.sh"; _ee_post_human gh BH-7916.1 fp body /dev/null'
eq "P6 _ee_post_human github, a dotted label: no hold" "$(sink)" ""
drive gh TS2-12 '. "$HARNESS/bin/lib/execute-empty.sh"; _ee_lift_epoch gh TS2-12 0'
eq "P6 _ee_lift_epoch github, a near-miss key: no thread read" "$(sink)" ""
out=$(HARNESS="$H" ROWS="$ROWS" bash -c '. "$HARNESS/bin/lib/execute-empty.sh"; _ee_board_ctx ln; echo "rc=$? adapter=${TRK_ADAPTER:-} log=${TRK_LOG:-}"' 2>/dev/null)
eq "P6 _ee_board_ctx refuses a linear project" "$out" "rc=1 adapter=linear log="

# P7: the replan comment, App identity. rpc <project> <key> runs the block in a
# fresh build dir and prints the markers it left.
rpc() {
  scratch_rm "$T/b" || exit 1; mkdir -p "$T/b"; echo amendment > "$T/b/replan-comment.md"
  drive "$1" "$2" 'GH_TOKEN=ghs_fixture; . "$T/rpc.sh"'
  ls "$T/b" | grep -E '^replan-comment(ed|-skipped)$' | paste -sd' ' -
}
eq "P7 replan comment linear: skipped" "$(rpc ln CRO-12)" replan-comment-skipped
eq "P7 replan comment linear: no GitHub post" "$(sink)" ""
grep -q 'replan comment skipped: not a GitHub issue' "$T/b/pipeline.log" 2>/dev/null && ok \
  || bad "P7 linear: one 'not a GitHub issue' log line: $(cat "$T/b/pipeline.log" 2>/dev/null)"
eq "P7 replan comment github: posted" "$(rpc gh TK-12)" replan-commented
eq "P7 replan comment github: posts on issue 12" "$(sink)" "comment o/gh 12"

# The control for every linear P case: the same project without the row is a
# GitHub project, and each site makes its call on issue 12.
linear_off
eq "P7 control: no row posts" "$(rpc ln CRO-12)" replan-commented
eq "P7 control: no row posts on issue 12" "$(sink)" "comment o/ln 12"
drive ln CRO-12 '. "$T/meta.sh"; TICKET_META'
eq "P1 control: no row reads issue 12" "$(sink)" "gh_rest GET repos/o/ln/issues/12"
drive ln CRO-12 '. "$T/esc.sh"; escalate_block test-tamper detail'
eq "P4 control: no row comments on issue 12" "$(sink)" "comment o/ln 12"
drive ln CRO-12 'SELF="$HARNESS/bin"; RD_ON=1; . "$T/closures.sh"; issue_closures ln CRO-12'
eq "P5 control: no row reads issue 12" "$(sink)" "state o/ln 12"
linear_on

echo "tracker-identity-nonnumeric.bh-7919: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
