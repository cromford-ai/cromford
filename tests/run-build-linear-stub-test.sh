#!/bin/bash
# tests/run-build-linear-stub-test.sh — BH-7921 (slice C0 of #7921): the
# run-build pipeline reads and writes a LINEAR ticket through the tracker
# contract (bin/lib/rb-tracker.sh onto bin/lib/tracker.sh).
#
# WHY DRIVEN. Each site fails open, so a pipeline that never reads the ticket
# looks the same as one that does from the outside. The real blocks are lifted
# out of the flattened pipeline (tests/lib/rb-all.sh) and run in a scratch
# harness against a Linear GraphQL stub (tests/lib/trk-linear-stub.bh-8450.sh,
# fixtures tests/fixtures/run-build-tracker.bh-7921/linear/). One wrapper curl
# in front of the stub adds the failure arms this suite needs and models the
# thread after a post: when a TrkComment takes, it copies the fixture named in
# $LS/on-comment over the case's issue-CRO-12.json (CRO-12 -> CRO-12-blocked).
# No network, no real key (a fixture sentinel), no real worker.
#
#   L1  the rbt_kind decision table
#   L2  TICKET_FP: trk:<64 hex>; a body edit and a new comment change it; a
#       status move does not; a comment in own-comments.sha256 is left out
#   L3  TICKET_META from the same read; bin/kind-gate.sh reads the file
#   L4  the ambiguity rule: linear assumption-forward, board BLOCKED
#   L5  CRO-13 (completed): BUILD_REFUSED SKIP_CLOSED, exit 3
#   L6  Todo, In Review, a rate-limited read: no refusal, 0 gh calls
#   L7  escalate_block posts one TrkComment; a second call posts nothing
#   L8  resume after escalate_block: no PLAN_STALE; ticket-fp is the new fp
#   L9  a human comment before the notice: the resume goes PLAN_STALE
#   L10 a failed notice post: ticket-fp unchanged, no mark
#   L11 the PR block: TrkAttach, then TrkUpdate to In Review; no Closes #
#   L12 the close-out: TrkComment, then TrkUpdate to Done; a retry moves only
#   L13 a REFUTED claim keeps the ticket open
#   L14 a SLICE plan keeps the ticket open
#   L15 a github-issues project: every block byte-identical with the lib absent
#
#   HARNESS_TEST_SANDBOX=1 bash tests/run-build-linear-stub-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/trk-linear-stub.bh-8450.sh" || exit 1
. "$(dirname "$0")/lib/rb-all.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
has() { if grep -qF -- "$3" "$2" 2>/dev/null; then ok; else bad "$1: no line '$3' in $(basename "$2"): $(tail -3 "$2" 2>/dev/null)"; fi; }

FIX="$REPO/tests/fixtures/run-build-tracker.bh-7921/linear"
KEYV=lin-FIXTURE-SENTINEL-7921
RBALL=$(rb_all "$REPO" "$T/rb-all.txt") || { echo "FAIL: rb_all could not flatten the pipeline"; exit 1; }

# ---- the lifted blocks ------------------------------------------------------
fn_of() { awk -v f="$2" '$0 == f"() {" || index($0, f"() { #") == 1 {p=1} p {print} p && /^}/ {exit}' "$1"; }
blk()   { awk -v a="$2" -v b="$3" 'index($0, a) == 1 {f=1} f {print} f && index($0, b) == 1 {exit}' "$1"; }
fn_of "$RBALL" TICKET_FP > "$T/fp.sh"
fn_of "$RBALL" TICKET_META > "$T/meta.sh"
fn_of "$RBALL" TICKET_THREAD_SIG > "$T/sig.sh"
fn_of "$RBALL" escalate_block > "$T/esc.sh"
fn_of "$RBALL" CLOSE_ISSUE_AFTER_MERGE > "$T/close.sh"
blk "$RBALL" 'if [ ! -s "$BUILD/ticket-meta.json" ]; then' 'fi' > "$T/promote.sh"
blk "$RBALL" '# >>> plan ambiguity rule' '# <<< plan ambiguity rule' > "$T/amb.sh"
blk "$RBALL" '# >>> closed issue skip' '# <<< closed issue skip' > "$T/skip.sh"
blk "$RBALL" '# >>> tracker link pr (BH-7921)' '# <<< tracker link pr' > "$T/link.sh"
blk "$RBALL" 'CLOSES_LINE=""; _CL_ISSUE=""' '# <<< partial build refs' > "$T/closes.sh"
blk "$RBALL" '# >>> ticket fingerprint write' '# <<< ticket fingerprint write' > "$T/fpw.sh"
blk "$RBALL" '  # >>> resume stale gate' '  # <<< resume stale gate' > "$T/gate.sh"
for f in fp meta sig esc close promote amb skip link closes fpw gate; do
  [ -s "$T/$f.sh" ] && ok || bad "extract: $f is missing from the pipeline — its rows would test nothing"
done
grep -q 'rbt_link_pr' "$T/link.sh" && ok || bad "extract: the tracker link pr block does not call rbt_link_pr"

# ---- the scratch harness -----------------------------------------------------
H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$H/logs" "$H/state" "$T/b" "$T/fb" "$T/tmp"
# mkh <dir> — a scratch harness: the closures, fleet.conf, env and beat.sh.
mkh() {
  local s
  mkdir -p "$1/bin/lib" "$1/env" "$1/logs" "$1/state" || exit 1
  for s in bin/lib/rb-tracker.sh bin/jobs-client.sh bin/fleet-conf.sh bin/kind-gate.sh bin/lib/plan-thread.sh; do
    scratch_install_closure "$s" "$1" >/dev/null || exit 1
  done
  cat > "$1/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset>
rbt-lin  o/lin  https://lin.example  -           9
rbt-gh   o/r    https://gh.example   -           8
rbt-bd   o/bd   https://bd.example   /api/board  7
CONF
  printf 'LINEAR_API_KEY=%s\nLINEAR_TEAM=CRO\n' "$KEYV" > "$1/env/rbt-lin.env"
  printf '#!/bin/bash\nexit 0\n' > "$1/bin/beat.sh"; chmod +x "$1/bin/beat.sh"
}
mkh "$H"
for f in bin/lib/tracker.sh bin/lib/tracker/linear.sh bin/lib/comment-mark.sh bin/lib/plan-thread.sh; do
  [ -r "$H/$f" ] && ok || bad "closure: $f was not installed"
done
# H0: the same harness without bin/lib/rb-tracker.sh (L15's "lib absent" run).
H0="$T/h0"; mkh "$H0"; rm -f "$H0/bin/lib/rb-tracker.sh"
trk_stub_install "$T/stub" || { echo "FAIL: could not install the Linear stub"; exit 1; }

# The wrapper curl: arms attach_fail and update_fail_once ($TL_STATE/arm7921),
# and the thread after a post ($TL_STATE/on-comment). Everything else is the
# shared stub.
cat > "$T/fb/curl" <<'SH'
#!/bin/bash
S="$TL_STATE"; data=""; out=""; fmt=""; url=""
a=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    --data-binary|-d) data="${2#@}"; shift ;;
    -o) out="$2"; shift ;;
    -w) fmt="$2"; shift ;;
    -X|-m|--max-time|--connect-timeout|-H) shift ;;
    http*) url="$1" ;;
  esac
  shift
done
case "$url" in https://jobs.example/*) exec "$STUB_CURL" "${a[@]}" ;; esac
op=$(jq -r '.query // ""' "$data" 2>/dev/null | sed -nE '1s/^(query|mutation) ([A-Za-z]+).*/\2/p')
arm=$(cat "$S/arm7921" 2>/dev/null)
fake() { # fake <code> <body> — answered here, counted like the stub counts
  local seq; seq=$(( $(cat "$S/seq" 2>/dev/null || echo 0) + 1 )); echo "$seq" > "$S/seq"
  printf '%s %s\n' "$seq" "$op" >> "$S/reqs"; printf '%s %s\n' "$seq" "$op" >> "$S/mutations"
  printf '%s' "$2" > "$out"; printf '%s' "$fmt" | sed "s/%{http_code}/$1/g"; exit 0
}
case "$arm:$op" in
  attach_fail:TrkAttach) fake 200 '{"data":{"attachmentLinkURL":{"success":false,"attachment":null}}}' ;;
  update_fail_once:TrkUpdate) rm -f "$S/arm7921"; fake 200 '{"data":{"issueUpdate":{"success":false,"issue":null}}}' ;;
esac
"$STUB_CURL" "${a[@]}"; rc=$?
if [ "$op" = TrkComment ] && [ -s "$S/on-comment" ] && jq -e '.data.commentCreate.success == true' "$out" >/dev/null 2>&1; then
  cp "$(cat "$S/on-comment")" "$TL_FIX/issue-CRO-12.json"; rm -f "$S/on-comment"
fi
exit "$rc"
SH
chmod +x "$T/fb/curl"

# fresh [<variant>] — a new stub state and a writable fixture copy whose
# issue-CRO-12.json is issue-CRO-12<variant>.json; the build dir and the marks
# of earlier cases gone.
LS="$T/ls"; FX="$T/fx"
fresh() {
  scratch_rm "$LS" || exit 1; mkdir -p "$LS"
  scratch_rm "$FX" || exit 1; cp -r "$FIX" "$FX"
  cp "$FIX/issue-CRO-12${1:-}.json" "$FX/issue-CRO-12.json"
  : > "$LS/reqs"; : > "$LS/mutations"
  printf '200\n{"setting":{"key":"tracker_adapter.rbt-lin","value":"linear"}}\n' > "$LS/setting-tracker_adapter.rbt-lin"
  printf '200\n{"setting":{"key":"tracker_linear.rbt-lin.team","value":"CRO"}}\n' > "$LS/setting-tracker_linear.rbt-lin.team"
  scratch_rm "$T/b" || exit 1; mkdir -p "$T/b"; rm -f "$H/state"/* "$H0/state"/*; : > "$T/sink"
}
nreq() { cat "$LS/reqs" 2>/dev/null | grep -c " ${1}\$"; }
nmut() { cat "$LS/mutations" 2>/dev/null | grep -c .; }
ngh()  { cat "$LS/gh.log" 2>/dev/null | grep -c .; }
nlog() { cat "$T/b/pipeline.log" 2>/dev/null | grep -cF -- "$1"; }
muts() { awk '{print $2}' "$LS/mutations" | paste -sd' ' -; }

# drive <project> <key> <snippet> [<harness>] — a fresh bash with the stubs on
# PATH and the pipeline's own STAMP/RESULT/BB. The tracker libs are NOT
# pre-sourced: each site loads bin/lib/rb-tracker.sh itself, as in production.
# stdout in $T/out, the true rc in RC.
drive() {
  RC=0
  env -u TRK_LOG -u TRK_DRY -u TRK_ERR -u HARNESS_ENV_DIR -u H \
    PATH="$T/fb:$T/stub:$PATH" STUB_CURL="$T/stub/curl" HARNESS="${4:-$H}" HENV="${4:-$H}/env" FLEET_CONF="${4:-$H}/fleet.conf" \
    TL_STATE="$LS" TL_FIX="$FX" TL_KEY_EXPECT="$KEYV" HARNESS_SECRET=hs-fixture-7921 \
    JOBS_URL=https://jobs.example JOBS_RETRIES=0 TMPDIR="$T/tmp" GH_ETAG=0 \
    PROJECT="$1" KEY="$2" TICKET="$2" BUILD="$T/b" SINK="$T/sink" T="$T" SLUG=o/r \
    bash -c '
      STAMP() { echo TS; }
      RESULT() { printf "%s\n" "$1" > "$BUILD/RESULT"; }
      BB() { echo "BB $1" >> "$SINK"; }
      gh_rest() { echo "gh_rest $*" >> "$SINK"; echo "{\"title\":\"G\",\"labels\":[],\"body\":\"B\",\"state\":\"open\"}"; }
      gh_rest_comment() { echo "gh_rest_comment $1 $2" >> "$SINK"; }
      gh_rest_close() { echo "gh_rest_close $1 $2" >> "$SINK"; }
      '"$3" > "$T/out" 2>"$T/err" || RC=$?
}
# The resume, as the pipeline runs it: FP_BEFORE from a fresh read, FP_PLAN
# from the record, then the lifted resume stale gate.
RESUME='. "$T/fp.sh"; FP_BEFORE=$(TICKET_FP); FP_PLAN=$(cat "$BUILD/ticket-fp" 2>/dev/null); . "$T/gate.sh"; echo resumed'
# The first attempt's plan stage: FP_BEFORE, then the ticket-fp writer.
PLANNED='. "$T/fp.sh"; FP_BEFORE=$(TICKET_FP); . "$T/fpw.sh"'
ESC='. "$T/esc.sh"; escalate_block test-tamper "the detail line"'

# ═══ L1: the rbt_kind table ═══════════════════════════════════════════════
kind() { # kind <project> [<row value>] -> "<answer> rc=<rc>"
  fresh
  if [ -n "${2:-}" ]; then printf '200\n{"setting":{"key":"tracker_adapter.%s","value":"%s"}}\n' "$1" "$2" > "$LS/setting-tracker_adapter.$1"
  else rm -f "$LS/setting-tracker_adapter.$1"; fi
  drive "$1" x '. "$HARNESS/bin/lib/rb-tracker.sh"; out=$(rbt_kind "$PROJECT"); echo "$out rc=$?"'
  cat "$T/out"
}
eq "L1 no row, column 4 -"          "$(kind rbt-gh)" "github-issues rc=0"
eq "L1 row github-issues"           "$(kind rbt-gh github-issues)" "github-issues rc=0"
eq "L1 column 4 a prefix, no row"   "$(kind rbt-bd)" "board rc=0"
eq "L1 row board"                   "$(kind rbt-gh board)" "board rc=0"
eq "L1 row linear, column 4 -"      "$(kind rbt-lin linear)" "linear rc=0"
eq "L1 row jira, column 4 -"        "$(kind rbt-lin jira)" "jira rc=0"
eq "L1 row Linear (a typo) refused" "$(kind rbt-lin Linear)" " rc=1"
eq "L1 unknown project"             "$(kind nope)" " rc=1"
fresh
drive rbt-gh CRO-12 '. "$HARNESS/bin/lib/rb-tracker.sh"; rbt_kind "$PROJECT" >/dev/null; trk_gh_issue_number "$PROJECT" "$KEY"'
eq "L1 CRO-12 on a github-issues project is still issue 12" "$(cat "$T/out")" 12
# A bin/ with rb-tracker.sh but no tracker.sh: no kind, and every site runs
# its own column-4 code.
H2="$T/h2"; mkh "$H2"; rm -f "$H2/bin/lib/tracker.sh"
fresh
drive rbt-lin CRO-12 '. "$HARNESS/bin/lib/rb-tracker.sh"; o=$(rbt_kind "$PROJECT"); echo "$o rc=$?"' "$H2"
eq "L1 no tracker.sh: no kind" "$(cat "$T/out")" " rc=1"
drive rbt-lin CRO-12 '. "$T/amb.sh"; printf "%s" "$PLAN_AMBIGUITY_RULE"' "$H2"
grep -q 'AMBIGUITY IS NOT A STOP' "$T/out" && ok || bad "L1 no tracker.sh: the ambiguity rule takes column 4 '-' as today: $(head -c 80 "$T/out")"
eq "L1 no tracker.sh: 0 Linear requests" "$(grep -c . "$LS/reqs")" 0

# ═══ L2: TICKET_FP ═════════════════════════════════════════════════════════
fresh
drive rbt-lin CRO-12 '. "$T/fp.sh"; TICKET_FP'
FP1=$(cat "$T/out")
[[ "$FP1" =~ ^trk:[0-9a-f]{64}$ ]] && ok || bad "L2 TICKET_FP prints trk:<64 hex>, got '$FP1' ($(cat "$T/err"))"
eq "L2 one TrkIssue request" "$(nreq TrkIssue)" 1
eq "L2 0 gh calls" "$(ngh)" 0
eq "L2 the read is kept in the build dir" "$(jq -r .key "$T/b/tracker-ticket.json" 2>/dev/null)" CRO-12
[ ! -s "$LS/authbad" ] && ok || bad "L2 the stub saw a wrong key"
drive rbt-lin CRO-12 '. "$T/fp.sh"; TICKET_FP'
eq "L2 the same thread gives the same FP" "$(cat "$T/out")" "$FP1"
eq "L2 a fresh read each call" "$(nreq TrkIssue)" 2
fp_of() { # fp_of <jq edit of CRO-12> -> the FP of the edited ticket
  jq "$1" "$FIX/issue-CRO-12.json" > "$FX/issue-CRO-12.json"
  drive rbt-lin CRO-12 '. "$T/fp.sh"; TICKET_FP'; cat "$T/out"
}
FPB=$(fp_of '.data.issue.description = "Export the ledger as a CSV and an XLSX file."')
[[ "$FPB" =~ ^trk: ]] && [ "$FPB" != "$FP1" ] && ok || bad "L2 a body edit must change the FP: '$FP1' -> '$FPB'"
eq "L2 a status move does not change the FP" \
  "$(fp_of '.data.issue.state = {"id":"00000000-0000-0000-0000-500000000004","name":"In Review","type":"started"}')" "$FP1"
cp "$FIX/issue-CRO-12-human.json" "$FX/issue-CRO-12.json"
drive rbt-lin CRO-12 '. "$T/fp.sh"; TICKET_FP'
FPH=$(cat "$T/out")
[[ "$FPH" =~ ^trk: ]] && [ "$FPH" != "$FP1" ] && ok || bad "L2 a new comment must change the FP: '$FP1' -> '$FPH'"
# A comment whose normalized body is in this build's own-post ledger is left out.
jq -j '.data.issue.comments.nodes[-1].body' "$FIX/issue-CRO-12-human.json" > "$T/own.md"
drive rbt-lin CRO-12 '. "$HARNESS/bin/lib/plan-thread.sh"; ptg_own_post "$BUILD" "$T/own.md"; . "$T/fp.sh"; TICKET_FP'
eq "L2 a comment in own-comments.sha256 is left out of the FP" "$(cat "$T/out")" "$FP1"
rm -f "$T/b/own-comments.sha256"
drive rbt-lin CRO-12 'FP_BEFORE="'"$FP1"'"; . "$T/sig.sh"; TICKET_THREAD_SIG'
eq "L2 TICKET_THREAD_SIG prints FP_BEFORE" "$(cat "$T/out")" "$FP1"

# ═══ L3: TICKET_META ═══════════════════════════════════════════════════════
fresh
drive rbt-lin CRO-12 '. "$T/fp.sh"; FP_BEFORE=$(TICKET_FP); . "$T/meta.sh"; . "$T/promote.sh"'
eq "L3 ticket-meta title" "$(jq -r .title "$T/b/ticket-meta.json" 2>/dev/null)" "Ledger export as CSV"
eq "L3 ticket-meta type" "$(jq -r .type "$T/b/ticket-meta.json" 2>/dev/null)" ""
eq "L3 ticket-meta labels" "$(jq -c .labels "$T/b/ticket-meta.json" 2>/dev/null)" '["ai-build"]'
eq "L3 ticket-meta body" "$(jq -r .body "$T/b/ticket-meta.json" 2>/dev/null)" "Export the ledger as a CSV file from the reports page."
eq "L3 served from the FP read: one TrkIssue in all" "$(nreq TrkIssue)" 1
fresh
jq '.data.issue.labels.nodes += [{"id":"00000000-0000-0000-0000-b00000000002","name":"bug"}]' "$FIX/issue-CRO-12.json" > "$FX/issue-CRO-12.json"
drive rbt-lin CRO-12 '. "$T/meta.sh"; . "$T/promote.sh"; "$HARNESS/bin/kind-gate.sh" "$BUILD"'
eq "L3 no FP read first: TICKET_META reads once" "$(nreq TrkIssue)" 1
grep -q '^KIND_HINT: bug' "$T/out" && ok || bad "L3 kind-gate.sh reads the Linear labels from ticket-meta.json: $(head -3 "$T/out")"
eq "L3 0 gh calls" "$(ngh)" 0

# ═══ L4: the ambiguity rule ════════════════════════════════════════════════
drive rbt-lin CRO-12 '. "$T/amb.sh"; printf "%s" "$PLAN_AMBIGUITY_RULE"'
grep -q 'AMBIGUITY IS NOT A STOP' "$T/out" && ok || bad "L4 linear is assumption-forward: $(head -c 120 "$T/out")"
drive rbt-bd 7 '. "$T/amb.sh"; printf "%s" "$PLAN_AMBIGUITY_RULE"'
grep -q 'BLOCKED-NEEDS-CLARIFICATION as the first line' "$T/out" && ! grep -q 'AMBIGUITY IS NOT A STOP' "$T/out" && ok \
  || bad "L4 a board asks: $(head -c 120 "$T/out")"
fresh; printf '200\n{"setting":{"key":"tracker_adapter.rbt-gh","value":"board"}}\n' > "$LS/setting-tracker_adapter.rbt-gh"
drive rbt-gh 7 '. "$T/amb.sh"; printf "%s" "$PLAN_AMBIGUITY_RULE"'
grep -q 'BLOCKED-NEEDS-CLARIFICATION as the first line' "$T/out" && ok || bad "L4 a board row over column 4 '-' asks (the rule keys on tracker_kind): $(head -c 120 "$T/out")"

# ═══ L5-L6: the closed-ticket skip ═════════════════════════════════════════
fresh
drive rbt-lin CRO-13 '. "$T/skip.sh"; echo fell-through'
eq "L5 a completed ticket exits 3" "$RC" 3
has "L5 RESULT" "$T/b/RESULT" "BUILD_REFUSED SKIP_CLOSED CRO-13 — the ticket is closed on linear"
has "L5 pipeline.log" "$T/b/pipeline.log" "SKIP_CLOSED CRO-13"
eq "L5 0 gh calls" "$(ngh)" 0
fresh
echo '{"id":"CRO-13","key":"CRO-13","title":"Old export","body":"","status":"Todo","state":"open","labels":[],"comments":[]}' > "$T/b/tracker-ticket.json"
drive rbt-lin CRO-13 '. "$T/skip.sh"; echo fell-through'
eq "L5 an old open copy in the build dir does not hide the close" "$RC" 3
skip_case() { # skip_case <label> <jq edit of CRO-12> [stub arm]
  fresh
  jq "$2" "$FIX/issue-CRO-12.json" > "$FX/issue-CRO-12.json"
  [ -n "${3:-}" ] && printf '%s' "$3" > "$LS/arm"
  drive rbt-lin CRO-12 '. "$T/skip.sh"; echo fell-through'
  eq "L6 $1: builds" "$RC/$(cat "$T/out")" "0/fell-through"
  [ ! -e "$T/b/RESULT" ] && ok || bad "L6 $1: wrote a RESULT: $(cat "$T/b/RESULT")"
  eq "L6 $1: 0 gh calls" "$(ngh)/$(grep -c . "$T/sink")" "0/0"
}
skip_case "Todo" '.'
skip_case "In Review (our own move)" '.data.issue.state = {"id":"00000000-0000-0000-0000-500000000004","name":"In Review","type":"started"}'
skip_case "a rate-limited read" '.' ratelimit
has "L6 a rate-limited read logs the unavailable line" "$T/b/pipeline.log" "closed-ticket check unavailable (rc 75)"

# ═══ L7: the BUILD BLOCKED notice ══════════════════════════════════════════
fresh
drive rbt-lin CRO-12 "$ESC"
eq "L7 one TrkComment" "$(nreq TrkComment)" 1
B=$(awk '$2 == "TrkComment" {print $1; exit}' "$LS/reqs")
grep -q '^\*\*This build is blocked' "$LS/body-$B" 2>/dev/null && grep -q 'the detail line' "$LS/body-$B" && ok \
  || bad "L7 the comment body is the blocked notice: $(head -2 "$LS/body-$B" 2>/dev/null)"
eq "L7 0 gh calls" "$(ngh)/$(grep -c . "$T/sink")" "0/0"
eq "L7 the notice is in the own-post ledger" "$(grep -c . "$T/b/own-comments.sha256" 2>/dev/null)" 1
drive rbt-lin CRO-12 "$ESC"
eq "L7 a second notice for the same build posts nothing" "$(nreq TrkComment)" 1

# ═══ L8-L10: a resume after the notice ═════════════════════════════════════
fresh
drive rbt-lin CRO-12 "$PLANNED"
FPP=$(cat "$T/b/ticket-fp" 2>/dev/null)
[[ "$FPP" =~ ^trk: ]] && ok || bad "L8 the plan stage writes ticket-fp: '$FPP'"
echo "$FIX/issue-CRO-12-blocked.json" > "$LS/on-comment"
drive rbt-lin CRO-12 "$ESC"
eq "L8 the notice posts" "$(nreq TrkComment)" 1
FPN=$(cat "$T/b/ticket-fp" 2>/dev/null)
[ "$FPN" != "$FPP" ] && ok || bad "L8 ticket-fp is refreshed to the thread with the notice"
has "L8 the refresh is logged" "$T/b/pipeline.log" "ticket-fp refreshed after own write"
drive rbt-lin CRO-12 "$RESUME"
eq "L8 the resume is not PLAN_STALE" "$RC/$(cat "$T/out")" "0/resumed"
[ ! -e "$T/b/RESULT" ] && ok || bad "L8 the resume wrote a RESULT: $(cat "$T/b/RESULT")"
drive rbt-lin CRO-12 '. "$T/fp.sh"; TICKET_FP'
eq "L8 ticket-fp equals the FP of the thread with the notice" "$FPN" "$(cat "$T/out")"

fresh
drive rbt-lin CRO-12 "$PLANNED"
FPP=$(cat "$T/b/ticket-fp" 2>/dev/null)
cp "$FIX/issue-CRO-12-human.json" "$FX/issue-CRO-12.json"
echo "$FIX/issue-CRO-12-human-blocked.json" > "$LS/on-comment"
drive rbt-lin CRO-12 "$ESC"
eq "L9 the notice posts" "$(nreq TrkComment)" 1
eq "L9 ticket-fp is kept: a person moved the thread first" "$(cat "$T/b/ticket-fp" 2>/dev/null)" "$FPP"
has "L9 the keep is logged" "$T/b/pipeline.log" "ticket-fp kept"
drive rbt-lin CRO-12 "$RESUME"
eq "L9 the resume is PLAN_STALE" "$RC" 3
has "L9 RESULT" "$T/b/RESULT" "PLAN_STALE thread moved since the reused plan was written"

fresh
drive rbt-lin CRO-12 "$PLANNED"
FPP=$(cat "$T/b/ticket-fp" 2>/dev/null)
printf comment_fail > "$LS/arm"
drive rbt-lin CRO-12 "$ESC"
eq "L10 the post was tried" "$(nreq TrkComment)" 1
eq "L10 a failed post: ticket-fp unchanged" "$(cat "$T/b/ticket-fp" 2>/dev/null)" "$FPP"
eq "L10 a failed post: no mark" "$(find "$H/state" -name 'blocked-commented-*' | grep -c .)" 0
[ ! -s "$T/b/own-comments.sha256" ] && ok || bad "L10 a failed post is not in the own-post ledger"
rm -f "$LS/arm"
drive rbt-lin CRO-12 "$ESC"
eq "L10 the next attempt posts it" "$(nreq TrkComment)" 2

# ═══ L11: link the PR, move to review ══════════════════════════════════════
PRU=https://github.com/o/lin/pull/41
fresh
drive rbt-lin CRO-12 '. "$T/closes.sh"; printf "[%s]" "$CLOSES_LINE"'
eq "L11 the PR body has no Closes/Refs line" "$(cat "$T/out")" "[]"
drive rbt-lin CRO-12 'PR_URL='"$PRU"'; . "$T/link.sh"; echo rc=$?'
eq "L11 the block returns" "$(cat "$T/out")" "rc=0"
eq "L11 mutations, in order" "$(muts)" "TrkAttach TrkUpdate"
A=$(awk '$2 == "TrkAttach" {print $1; exit}' "$LS/reqs")
eq "L11 the attachment url is the PR url" "$(cat "$LS/body-$A" 2>/dev/null)" "$PRU"
has "L11 the linked line" "$T/b/pipeline.log" "linked PR $PRU on CRO-12 (linear)"
has "L11 the review line" "$T/b/pipeline.log" "moved CRO-12 to review"
grep -q 'issueUpdate issue=CRO-12 stateId=00000000-0000-0000-0000-500000000004 status=review' "$T/b/tracker.log" 2>/dev/null && ok \
  || bad "L11 the TrkUpdate carries the In Review state id: $(cat "$T/b/tracker.log" 2>/dev/null)"
grep -q "$KEYV" "$T/b/tracker.log" "$T/b/pipeline.log" 2>/dev/null && bad "L11 the key leaked into a log" || ok
drive rbt-lin CRO-12 'PR_URL='"$PRU"'; . "$T/link.sh"'
eq "L11 a second run sends no second TrkAttach" "$(nreq TrkAttach)" 1
eq "L11 0 gh calls" "$(ngh)/$(grep -c . "$T/sink")" "0/0"
fresh; printf attach_fail > "$LS/arm7921"
drive rbt-lin CRO-12 'PR_URL='"$PRU"'; . "$T/link.sh"; echo rc=$?'
eq "L11 a failed link: the block still returns 0" "$(cat "$T/out")" "rc=0"
eq "L11 a failed link: no TrkUpdate" "$(nreq TrkUpdate)" 0
eq "L11 a failed link: one failure line" "$(nlog "could not link PR $PRU on CRO-12")" 1
eq "L11 a failed link: no mark" "$(find "$H/state" -name 'link-pr-*' | grep -c .)" 0
fresh
drive rbt-lin CRO-12 'PR_URL=""; . "$T/link.sh"'
eq "L11 no PR url: no request" "$(grep -c . "$LS/reqs")" 0

# ═══ L12-L14: close out after merge ════════════════════════════════════════
MU=https://github.com/o/lin/pull/41
CLOSE='CLOSES_LINE=""; . "$T/close.sh"; CLOSE_ISSUE_AFTER_MERGE '"$MU"'; echo rc=$?'
fresh
drive rbt-lin CRO-12 "$CLOSE"
eq "L12 the block returns 0" "$(cat "$T/out")" "rc=0"
eq "L12 TrkComment THEN TrkUpdate" "$(muts)" "TrkComment TrkUpdate"
C=$(awk '$2 == "TrkComment" {print $1; exit}' "$LS/reqs")
case "$(cat "$LS/body-$C" 2>/dev/null)" in "Merged in $MU "*) ok ;; *) bad "L12 the comment starts 'Merged in $MU': $(cat "$LS/body-$C" 2>/dev/null)" ;; esac
grep -q 'issueUpdate issue=CRO-12 stateId=00000000-0000-0000-0000-500000000007 status=done' "$T/b/tracker.log" 2>/dev/null && ok \
  || bad "L12 the TrkUpdate goes to the completed Done state: $(cat "$T/b/tracker.log" 2>/dev/null)"
has "L12 the closed-out line" "$T/b/pipeline.log" "closed out CRO-12 after merge"
eq "L12 0 gh calls" "$(ngh)/$(grep -c . "$T/sink")" "0/0"
# The mark follows a full close-out too: a re-run sends no second comment.
drive rbt-lin CRO-12 "$CLOSE"
eq "L12 a re-run after a full close-out sends no second TrkComment" "$(nreq TrkComment)" 1
fresh; printf update_fail_once > "$LS/arm7921"
# The thread after the merge comment, as Linear shows it on the next read.
jq --arg b "Merged in $MU (tier-1, reviewed and gated in this build). Closing this ticket." \
  '.data.issue.comments.nodes += [{body: $b, createdAt: "2026-10-22T09:00:00.000Z", user: {name: "Harness", displayName: "harness"}, botActor: null}]' \
  "$FIX/issue-CRO-12.json" > "$T/merged.json"
echo "$T/merged.json" > "$LS/on-comment"
drive rbt-lin CRO-12 "$CLOSE"
eq "L12 a failed move: one comment" "$(nreq TrkComment)" 1
eq "L12 a failed move: rc 0 to the caller" "$(cat "$T/out")" "rc=0"
has "L12 a failed move names the C2 lanes" "$T/b/pipeline.log" "C2"
drive rbt-lin CRO-12 "$CLOSE"
eq "L12 the retry sends no second TrkComment" "$(nreq TrkComment)" 1
eq "L12 the retry sends one more TrkUpdate" "$(nreq TrkUpdate)" 2
has "L12 the retry closes it out" "$T/b/pipeline.log" "closed out CRO-12 after merge"

fresh; echo '{"claims":[{"n":1,"verdict":"REFUTED","claim":"x"}]}' > "$T/b/evidence.json"
drive rbt-lin CRO-12 "$CLOSE"
eq "L13 a REFUTED claim sends nothing" "$(grep -c . "$LS/reqs")" 0
eq "L13 a REFUTED claim logs one line" "$(nlog 'left CRO-12 open after merge')" 1
fresh; echo '{"claims":[{"n":1,"verdict":"INCONCLUSIVE","claim":"x"}]}' > "$T/b/evidence.json"
drive rbt-lin CRO-12 "$CLOSE"
eq "L13 INCONCLUSIVE closes" "$(muts)" "TrkComment TrkUpdate"

fresh; printf '# plan\n\nSLICE: C0 of #12\n' > "$T/b/plan.md"
drive rbt-lin CRO-12 "$CLOSE"
eq "L14 a SLICE plan sends nothing" "$(grep -c . "$LS/reqs")" 0
eq "L14 a SLICE plan logs one line" "$(nlog 'left CRO-12 open after merge')" 1
fresh; printf 'The work is a slice of the parent.\n' > "$T/b/plan.md"
drive rbt-lin CRO-12 "$CLOSE"
eq "L14 slice in prose closes" "$(muts)" "TrkComment TrkUpdate"

# ═══ L15: a github-issues project, byte-identical with the lib absent ═════
GHRUN='. "$T/fp.sh"; FP_BEFORE=$(TICKET_FP); printf "fp[%s]\n" "$FP_BEFORE"
  . "$T/meta.sh"; . "$T/promote.sh"; . "$T/amb.sh"; printf "amb[%s]\n" "${PLAN_AMBIGUITY_RULE:0:40}"
  . "$T/skip.sh"; . "$T/esc.sh"; escalate_block test-tamper detail
  . "$T/closes.sh"; printf "closes[%s]\n" "$CLOSES_LINE"
  PR_URL=https://github.com/o/r/pull/9; . "$T/link.sh"
  . "$T/close.sh"; CLOSE_ISSUE_AFTER_MERGE https://github.com/o/r/pull/9; echo done'
gh_run() { # gh_run <harness> <tag>
  fresh
  drive rbt-gh 7 "$GHRUN" "$1"
  { echo "rc=$RC"; cat "$T/out"; echo "-- sink"; cat "$T/sink"; echo "-- pipeline.log"; cat "$T/b/pipeline.log" 2>/dev/null
    echo "-- files"; (cd "$T/b" && ls); } > "$T/l15-$2.txt"
}
gh_run "$H0" absent
gh_run "$H" present
eq "L15 0 Linear requests with the lib present" "$(grep -c . "$LS/reqs")" 0
if cmp -s "$T/l15-absent.txt" "$T/l15-present.txt"; then ok; else bad "L15 github-issues differs with the lib present: $(diff "$T/l15-absent.txt" "$T/l15-present.txt" | head -5)"; fi
grep -q '^gh_rest_comment o/r 7$' "$T/l15-present.txt" && grep -q '^closes\[Closes #7\]$' "$T/l15-present.txt" && grep -q '^gh_rest_close o/r 7$' "$T/l15-present.txt" && ok \
  || bad "L15 the GitHub notice, Closes line and close pair still run: $(cat "$T/l15-present.txt")"

echo "run-build-linear-stub-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
