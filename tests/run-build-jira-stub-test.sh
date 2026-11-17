#!/bin/bash
# tests/run-build-jira-stub-test.sh — BH-7921 (slice C0 of #7921): the
# run-build pipeline reads and writes a JIRA ticket through the tracker
# contract (bin/lib/rb-tracker.sh onto bin/lib/tracker.sh).
#
# The real blocks are lifted out of the flattened pipeline (tests/lib/rb-all.sh)
# and run in a scratch harness against the Jira gateway stub
# (tests/lib/tracker-jira-stub.sh), played from
# tests/fixtures/run-build-tracker.bh-7921/jira/. The stub reads every issue's
# transitions from `transitions-CROM-1.json`, so this suite's fixture dir
# carries its own copy under that name. A wrapper curl in front of the stub
# models the thread after a post: when a comment POST takes, it copies the
# fixture named in $S/on-comment to $S/comments-SCRUM-12.json (the stub serves
# its state copy over the fixture). No network, no real token, no real worker.
#
#   J1  the jira rows of the kind table
#   J2  TICKET_FP and TICKET_META from SCRUM-12; no Closes # line
#   J3  the plan ambiguity rule for jira is assumption-forward
#   J4  SCRUM-13 (category done) refuses; SCRUM-12 indeterminate and a 429 build
#   J5  escalate_block + resume: no PLAN_STALE, although Jira's ADF copy of
#       the notice is not the text that was posted
#   J6  the PR block posts one `PR: <url>` comment
#   J7  a resume after that comment: no PLAN_STALE
#   J8  close-out: transitions read first, then the comment, then the move to
#       the done-category transition from the issue's own list
#   J9  a key outside write_projects (CROM-1): refused, nothing posted
#   J10 a board project: every block byte-identical with the lib absent
#
#   HARNESS_TEST_SANDBOX=1 bash tests/run-build-jira-stub-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/tracker-jira-stub.sh" || exit 1
. "$(dirname "$0")/lib/rb-all.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
has() { if grep -qF -- "$3" "$2" 2>/dev/null; then ok; else bad "$1: no line '$3' in $(basename "$2"): $(tail -3 "$2" 2>/dev/null)"; fi; }

FIX="$REPO/tests/fixtures/run-build-tracker.bh-7921/jira"
RBALL=$(rb_all "$REPO" "$T/rb-all.txt") || { echo "FAIL: rb_all could not flatten the pipeline"; exit 1; }
fn_of() { awk -v f="$2" '$0 == f"() {" || index($0, f"() { #") == 1 {p=1} p {print} p && /^}/ {exit}' "$1"; }
blk()   { awk -v a="$2" -v b="$3" 'index($0, a) == 1 {f=1} f {print} f && index($0, b) == 1 {exit}' "$1"; }
fn_of "$RBALL" TICKET_FP > "$T/fp.sh"
fn_of "$RBALL" TICKET_META > "$T/meta.sh"
fn_of "$RBALL" escalate_block > "$T/esc.sh"
fn_of "$RBALL" CLOSE_ISSUE_AFTER_MERGE > "$T/close.sh"
blk "$RBALL" 'if [ ! -s "$BUILD/ticket-meta.json" ]; then' 'fi' > "$T/promote.sh"
blk "$RBALL" '# >>> plan ambiguity rule' '# <<< plan ambiguity rule' > "$T/amb.sh"
blk "$RBALL" '# >>> closed issue skip' '# <<< closed issue skip' > "$T/skip.sh"
blk "$RBALL" '# >>> tracker link pr (BH-7921)' '# <<< tracker link pr' > "$T/link.sh"
blk "$RBALL" 'CLOSES_LINE=""; _CL_ISSUE=""' '# <<< partial build refs' > "$T/closes.sh"
blk "$RBALL" '# >>> ticket fingerprint write' '# <<< ticket fingerprint write' > "$T/fpw.sh"
blk "$RBALL" '  # >>> resume stale gate' '  # <<< resume stale gate' > "$T/gate.sh"
for f in fp meta esc close promote amb skip link closes fpw gate; do
  [ -s "$T/$f.sh" ] && ok || bad "extract: $f is missing from the pipeline — its rows would test nothing"
done

# ---- the scratch harness: the stub's root is $T/h ----------------------------
jira_stub_setup "$T" || { echo "FAIL: jira_stub_setup"; exit 1; }
export JIRA_STUB_FIX="$FIX"
H="$HARNESS"
mkdir -p "$H/bin/lib" "$T/b" "$T/tmp" "$T/fb"
# mkh <dir> — the closures, fleet.conf and beat.sh (the env file is the stub's).
mkh() {
  local s
  mkdir -p "$1/bin/lib" "$1/env" "$1/state" "$1/logs" || exit 1
  for s in bin/lib/rb-tracker.sh bin/jobs-client.sh bin/fleet-conf.sh bin/lib/plan-thread.sh; do
    scratch_install_closure "$s" "$1" >/dev/null || exit 1
  done
  cat > "$1/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset>
jproj  o/jp  https://jp.example  -           9
jbd    o/bd  https://bd.example  /api/board  7
CONF
  printf '#!/bin/bash\nexit 0\n' > "$1/bin/beat.sh"; chmod +x "$1/bin/beat.sh"
}
mkh "$H"
for f in bin/lib/tracker.sh bin/lib/tracker/jira.sh bin/lib/comment-mark.sh; do
  [ -r "$H/$f" ] && ok || bad "closure: $f was not installed"
done
# H0: the same harness without bin/lib/rb-tracker.sh (J10's "lib absent" run).
H0="$T/h0"; mkh "$H0"; rm -f "$H0/bin/lib/rb-tracker.sh"
cp "$H/env/jproj.env" "$H0/env/jproj.env"
S="$JIRA_STUB_STATE"

# The wrapper curl: the thread after a comment POST that took.
cat > "$T/fb/curl" <<'SH'
#!/bin/bash
m=GET; url=""; a=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m="$2"; shift ;;
    --data-binary|-d|-o|-w|-m|--max-time|--connect-timeout|-u|-H) shift ;;
    http*) url="$1" ;;
  esac
  shift
done
"$JSTUB_CURL" "${a[@]}"; rc=$?
S="$JIRA_STUB_STATE"
case "$m $url" in
  "POST "*/rest/api/3/issue/SCRUM-12/comment)
    if [ -s "$S/on-comment" ] && [ "$(cat "$S/arm" 2>/dev/null)" != comment_fail ]; then
      cp "$(cat "$S/on-comment")" "$S/comments-SCRUM-12.json"; rm -f "$S/on-comment"
    fi ;;
esac
exit "$rc"
SH
chmod +x "$T/fb/curl"

# fresh — no request yet, no write, no arm, the SCRUM allowlists, no marks.
fresh() {
  rm -f "$S/requests" "$S/writes" "$S/arm" "$S"/body-* "$S/gh.log" "$S/on-comment" "$S"/comments-*.json "$S"/issue-*.json
  jira_set tracker_adapter.jproj jira
  jira_set tracker_jira.jproj.write_projects SCRUM
  jira_set tracker_jira.jproj.comment_projects CMNT
  jira_set tracker_jira.jproj.read_projects "SCRUM CMNT"
  jira_unset tracker_jira.jproj.status_map
  jira_unset tracker_jira.jproj.waiting_on_field
  jira_unset tracker_jira.jproj.triage_verdict_field
  scratch_rm "$T/b" || exit 1; mkdir -p "$T/b"; rm -f "$H/state"/* "$H0/state"/*; : > "$T/sink"
}
ngh() { cat "$S/gh.log" 2>/dev/null | grep -c .; }
nlog() { cat "$T/b/pipeline.log" 2>/dev/null | grep -cF -- "$1"; }
reqs() { grep -vE '^GET /rest/api/3/myself' "$S/requests" 2>/dev/null; }

drive() { # drive <project> <key> <snippet> [<harness>] — stdout in $T/out, rc in RC
  RC=0
  env -u TRK_LOG -u TRK_DRY -u TRK_ERR -u HARNESS_ENV_DIR -u H \
    PATH="$T/fb:$PATH" JSTUB_CURL="$T/jstub/curl" HARNESS="${4:-$H}" \
    FLEET_CONF="${4:-$H}/fleet.conf" HENV="${4:-$H}/env" TMPDIR="$T/tmp" GH_ETAG=0 \
    PROJECT="$1" KEY="$2" TICKET="$2" BUILD="$T/b" T="$T" SINK="$T/sink" SLUG=o/jp \
    bash -c '
      STAMP() { echo TS; }
      RESULT() { printf "%s\n" "$1" > "$BUILD/RESULT"; }
      BB() { echo "BB $1" >> "$SINK"; }
      gh_rest() { echo "gh_rest $*" >> "$SINK"; return 1; }
      gh_rest_comment() { echo "gh_rest_comment $*" >> "$SINK"; }
      gh_rest_close() { echo "gh_rest_close $*" >> "$SINK"; }
      '"$3" > "$T/out" 2>"$T/err" || RC=$?
}
RESUME='. "$T/fp.sh"; FP_BEFORE=$(TICKET_FP); FP_PLAN=$(cat "$BUILD/ticket-fp" 2>/dev/null); . "$T/gate.sh"; echo resumed'
PLANNED='. "$T/fp.sh"; FP_BEFORE=$(TICKET_FP); . "$T/fpw.sh"'

# ═══ J1: the kind table, jira rows ═════════════════════════════════════════
kind() { drive jproj x '. "$HARNESS/bin/lib/rb-tracker.sh"; o=$(rbt_kind jproj); echo "$o rc=$?"'; cat "$T/out"; }
fresh
eq "J1 row jira, column 4 -" "$(kind)" "jira rc=0"
jira_set tracker_adapter.jproj JIRA
eq "J1 row JIRA (a typo) refused" "$(kind)" " rc=1"
jira_unset tracker_adapter.jproj
eq "J1 no row, column 4 -: github-issues" "$(kind)" "github-issues rc=0"
drive jproj SCRUM-12 '. "$HARNESS/bin/lib/rb-tracker.sh"; rbt_read jproj SCRUM-12 >/dev/null; echo "rc=$?"'
eq "J1 rbt_read on github-issues is rc 3 (the caller keeps its own code)" "$(cat "$T/out")" "rc=3"

# ═══ J2-J3: the plan reads ═════════════════════════════════════════════════
fresh
drive jproj SCRUM-12 '. "$T/fp.sh"; TICKET_FP'
[[ "$(cat "$T/out")" =~ ^trk:[0-9a-f]{64}$ ]] && ok || bad "J2 TICKET_FP prints trk:<hex>, got '$(cat "$T/out")' ($(cat "$T/err"))"
eq "J2 the gateway reads" "$(reqs | sed 's/?.*//' | paste -sd'|' -)" \
  "GET /rest/api/3/issue/SCRUM-12|GET /rest/api/3/issue/SCRUM-12/comment"
eq "J2 the thread was read" "$(jq -c '[.comments[].body]' "$T/b/tracker-ticket.json" 2>/dev/null)" '["Use the billing address.","Small grey text."]'
[ ! -s "$S/authbad" ] && ok || bad "J2 the stub saw a wrong credential"
drive jproj SCRUM-12 '. "$T/meta.sh"; . "$T/promote.sh"'
eq "J2 ticket-meta title" "$(jq -r .title "$T/b/ticket-meta.json" 2>/dev/null)" "Invoice PDF footer"
eq "J2 ticket-meta labels" "$(jq -c .labels "$T/b/ticket-meta.json" 2>/dev/null)" '["ai-build"]'
eq "J2 ticket-meta body" "$(jq -r .body "$T/b/ticket-meta.json" 2>/dev/null)" "Add the company address to the invoice PDF footer."
eq "J2 served from tracker-ticket.json: still two gateway reads" "$(reqs | grep -c .)" 2
drive jproj SCRUM-12 '. "$T/closes.sh"; printf "[%s]" "$CLOSES_LINE"'
eq "J2 no Closes # line" "$(cat "$T/out")" "[]"
eq "J2 0 gh calls" "$(ngh)/$(grep -c . "$T/sink")" "0/0"
drive jproj SCRUM-12 '. "$T/amb.sh"; printf "%s" "$PLAN_AMBIGUITY_RULE"'
grep -q 'AMBIGUITY IS NOT A STOP' "$T/out" && ok || bad "J3 jira is assumption-forward: $(head -c 120 "$T/out")"

# ═══ J4: the closed-ticket skip ════════════════════════════════════════════
fresh
drive jproj SCRUM-13 '. "$T/skip.sh"; echo fell-through'
eq "J4 a done-category ticket exits 3" "$RC" 3
has "J4 RESULT" "$T/b/RESULT" "BUILD_REFUSED SKIP_CLOSED SCRUM-13 — the ticket is closed on jira"
fresh
jq '.fields.status = {"name":"In Progress","id":"3","statusCategory":{"id":4,"key":"indeterminate","name":"In Progress"}}' "$FIX/issue-SCRUM-12.json" > "$S/issue-SCRUM-12.json"
drive jproj SCRUM-12 '. "$T/skip.sh"; echo fell-through'
eq "J4 an indeterminate ticket builds" "$RC/$(cat "$T/out")" "0/fell-through"
fresh; printf ratelimit > "$S/arm"
drive jproj SCRUM-12 '. "$T/skip.sh"; echo fell-through'
eq "J4 a 429 builds" "$RC/$(cat "$T/out")" "0/fell-through"
has "J4 a 429 logs the unavailable line" "$T/b/pipeline.log" "closed-ticket check unavailable (rc 75)"
eq "J4 0 gh calls" "$(ngh)/$(grep -c . "$T/sink")" "0/0"

# ═══ J5: the BLOCKED notice, then a resume ═════════════════════════════════
fresh
drive jproj SCRUM-12 "$PLANNED"
FPP=$(cat "$T/b/ticket-fp" 2>/dev/null)
[[ "$FPP" =~ ^trk: ]] && ok || bad "J5 the plan stage writes ticket-fp: '$FPP'"
echo "$FIX/comments-SCRUM-12-blocked.json" > "$S/on-comment"
drive jproj SCRUM-12 '. "$T/esc.sh"; escalate_block test-tamper "the detail line"'
eq "J5 one comment" "$(grep -c '^comment SCRUM-12$' "$S/writes" 2>/dev/null)" 1
grep -q 'This build is blocked' "$S/body-1" 2>/dev/null && ok || bad "J5 the comment is the notice: $(head -2 "$S/body-1" 2>/dev/null)"
[ "$(cat "$T/b/ticket-fp")" != "$FPP" ] && ok || bad "J5 ticket-fp is refreshed"
drive jproj SCRUM-12 "$RESUME"
eq "J5 the resume is not PLAN_STALE" "$RC/$(cat "$T/out")" "0/resumed"
eq "J5 0 gh calls" "$(ngh)/$(grep -c . "$T/sink")" "0/0"

# ═══ J6-J7: link the PR, then a resume ═════════════════════════════════════
PRU=https://github.com/o/jp/pull/52
fresh
drive jproj SCRUM-12 "$PLANNED"
FPP=$(cat "$T/b/ticket-fp" 2>/dev/null)
echo "$FIX/comments-SCRUM-12-pr.json" > "$S/on-comment"
drive jproj SCRUM-12 'PR_URL='"$PRU"'; . "$T/link.sh"; echo rc=$?'
eq "J6 the block returns" "$(cat "$T/out")" "rc=0"
eq "J6 one comment" "$(grep -c '^comment SCRUM-12$' "$S/writes" 2>/dev/null)" 1
eq "J6 its text is PR: <url>" "$(cat "$S/body-1" 2>/dev/null)" "PR: $PRU"
has "J6 the linked line" "$T/b/pipeline.log" "linked PR $PRU on SCRUM-12 (jira)"
has "J6 no review alias: one line, the build goes on" "$T/b/pipeline.log" "could not move SCRUM-12 to review"
grep -q 'JIRA_API_TOKEN' "$T/b/tracker.log" && ! grep -q "$JIRA_TOKEN_FX" "$T/b/tracker.log" "$T/b/pipeline.log" && ok \
  || bad "J6 the tracker log names the token variable, never the token"
[ "$(cat "$T/b/ticket-fp")" != "$FPP" ] && ok || bad "J7 ticket-fp is refreshed after the PR: comment"
drive jproj SCRUM-12 "$RESUME"
eq "J7 the resume is not PLAN_STALE" "$RC/$(cat "$T/out")" "0/resumed"
fresh; jira_set tracker_jira.jproj.status_map 'review=In Review'
drive jproj SCRUM-12 'PR_URL='"$PRU"'; . "$T/link.sh"'
eq "J6 review=In Review: moved" "$(grep -c '^status SCRUM-12 In Review$' "$S/writes" 2>/dev/null)" 1
has "J6 the moved line" "$T/b/pipeline.log" "moved SCRUM-12 to review"

# ═══ J8: close out after merge ═════════════════════════════════════════════
MU=https://github.com/o/jp/pull/52
CLOSE='CLOSES_LINE=""; . "$T/close.sh"; CLOSE_ISSUE_AFTER_MERGE '"$MU"'; echo rc=$?'
fresh
drive jproj SCRUM-12 "$CLOSE"
eq "J8 the block returns 0" "$(cat "$T/out")" "rc=0"
eq "J8 the order: transitions read, comment, transition" \
  "$(reqs | grep -E '/transitions|/comment$' | paste -sd'|' -)" \
  "GET /rest/api/3/issue/SCRUM-12/transitions|POST /rest/api/3/issue/SCRUM-12/comment|POST /rest/api/3/issue/SCRUM-12/transitions"
case "$(cat "$S/body-1" 2>/dev/null)" in "Merged in $MU "*) ok ;; *) bad "J8 the comment starts 'Merged in $MU': $(cat "$S/body-1" 2>/dev/null)" ;; esac
eq "J8 moved to Done (the done-category transition)" "$(grep -c '^status SCRUM-12 Done$' "$S/writes" 2>/dev/null)" 1
has "J8 the closed-out line" "$T/b/pipeline.log" "closed out SCRUM-12 after merge"
fresh; printf '# plan\nSLICE: C1 of SCRUM-12\n' > "$T/b/plan.md"
drive jproj SCRUM-12 "$CLOSE"
eq "J8 a SLICE plan sends nothing" "$(reqs | grep -c .)" 0

# ═══ J9: the allowlist guard ═══════════════════════════════════════════════
fresh
drive jproj CROM-1 'PR_URL='"$PRU"'; . "$T/link.sh"; echo rc=$?'
eq "J9 the block returns" "$(cat "$T/out")" "rc=0"
eq "J9 no gateway request at all" "$(reqs | grep -c .)" 0
eq "J9 one failure line" "$(nlog "could not link PR $PRU on CROM-1")" 1
drive jproj CROM-1 '. "$T/esc.sh"; escalate_block test-tamper detail'
drive jproj CROM-1 "$CLOSE"
eq "J9 a notice and a close-out of CROM-1 send no write" "$(reqs | grep -c '^POST ')" 0

# ═══ J10: a board project, byte-identical with the lib absent ══════════════
BDRUN='. "$T/fp.sh"; FP_BEFORE=$(TICKET_FP); printf "fp[%s]\n" "$FP_BEFORE"
  . "$T/meta.sh"; . "$T/promote.sh"; . "$T/amb.sh"; printf "amb[%s]\n" "${PLAN_AMBIGUITY_RULE:0:40}"
  . "$T/skip.sh"; . "$T/esc.sh"; escalate_block test-tamper detail
  . "$T/closes.sh"; printf "closes[%s]\n" "$CLOSES_LINE"
  PR_URL=https://github.com/o/bd/pull/9; . "$T/link.sh"
  . "$T/close.sh"; CLOSE_ISSUE_AFTER_MERGE https://github.com/o/bd/pull/9; echo done'
bd_run() { # bd_run <harness> <tag>
  fresh
  drive jbd BD-7 "$BDRUN" "$1"
  { echo "rc=$RC"; cat "$T/out"; echo "-- sink"; cat "$T/sink"; echo "-- pipeline.log"; cat "$T/b/pipeline.log" 2>/dev/null
    echo "-- files"; (cd "$T/b" && ls); } > "$T/j10-$2.txt"
}
bd_run "$H0" absent
bd_run "$H" present
eq "J10 0 gateway requests with the lib present" "$(reqs | grep -c .)" 0
if cmp -s "$T/j10-absent.txt" "$T/j10-present.txt"; then ok; else bad "J10 board differs with the lib present: $(diff "$T/j10-absent.txt" "$T/j10-present.txt" | head -5)"; fi
grep -q 'BLOCKED-NEEDS-CLARIFICATION' "$T/j10-present.txt" || grep -q '^amb\[If the thread does NOT' "$T/j10-present.txt" && ok \
  || bad "J10 a board asks: $(grep '^amb' "$T/j10-present.txt")"

echo "run-build-jira-stub-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
