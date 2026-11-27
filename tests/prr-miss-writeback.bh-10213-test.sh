#!/bin/bash
# tests/prr-miss-writeback.bh-10213-test.sh — BH-10213: after a PR-record miss
# in step `record`, lanes pipeline-health and dequeue-watch write the GitHub
# answer back into the record (POST /api/pr-record-notes), so the next tick is
# a record hit. An empty GitHub answer is a "checked, empty" marker
# (pr_records.gh_empty) that the readers serve for at most
# PR_RECORD_FIELD_MAX_AGE_S.
#
# The REAL libs run: bin/lib/prr-shadow.sh (prr_read), bin/lib/pr-record.sh
# (readers + pr_record_gh_note), bin/lib/mc-stale-dequeue.sh
# (sdq_payload_last), the two seams in bin/lib/prr-shadow.d/ and
# bin/lib/dequeue-watch/gather.sh (dqw_gather_pr). `gh` is a PATH shim and
# gh_rest a function double; both log each call and read fixture files.
# _jobs_req is a double that serves rec/<n>.json for the row GET and APPLIES
# a POST /api/pr-record-notes to that file (a small jq emulation of the
# worker; the worker's own SQL is pinned by
# worker/jobs/test/pr-record-notes.bh-10213.test.js). 0 network calls.
#
#   S1  prr_read step record: a record fn that prints `hit-rc:1` -> rc 1,
#       PRR_SOURCE=record, 0 GitHub calls, 0 note calls
#   S1b a record miss: 1 GitHub call with PRR_NOTE=1, then ONE <prefix>_note
#       call `<out> <grc> <why> [args]`, PRR_READ_AT set; rc = GitHub's
#   S2  hit-rc:0, hit-rc:10, `hit-rc:1 extra`, two lines -> rc 0 as today
#   S3  step shadow: 0 note calls; hit-rc:1 vs GitHub rc 0 -> one
#       `rc_record=1 rc_github=0` PRR_SHADOW line; equal rc -> no line; the
#       real status seam in shadow: 0 POST
#   S4  step off: 0 record reads, 0 note calls; the real seam: 0 POST
#   R1-R7 the readers' `empty` word on fixture rows
#   C1  sdq_payload_last on the #3396 fixture: same stdout and rc with and
#       without SDQ_PAYLOAD_COMMENT_OUT; the file holds the chosen comment
#   A1  case 1, pipeline-health `:status`, a head with no statuses
#   A2  case 2, dequeue-watch `:payload`, a PR with no Mergify comment
#   A3  case 3, dequeue-watch `:payload`, a row with no updated_at
#   A4  dequeue-watch `:status` with 2 GitHub statuses: 1 POST with both
#   A5  pipeline-health `:payload`, no Mergify comment
#   E1  GitHub rc 75 on the payload read: 0 POST; tick 2 reads GitHub again
#   E2  status `gh api` rc 1 (403): 0 POST; tick 2 reads again; rc 0 with a
#       body that is not JSON: 0 POST
#   E3  payload rc 2 (an unparsable payload), and the note fns with rc 2/3/4/75
#   F1  the jobs POST fails: one `gh-note … put=failed` line, the lane answer
#       is GitHub's
#   F2  no *.comment file stays behind after any case
#
#   N1  the worker half is in the tree: the route table fragment, the route
#       module and the gh_empty column fragment (they parse)
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/prr-miss-writeback.bh-10213-test.sh
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $CASE: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2', wanted '$3'"; fi; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }
CASE=setup

H="$T/h"; F="$T/fix"
mkdir -p "$H/logs" "$F/rec" "$T/shim" "$T/tmp" "$T/dqw"
export HARNESS="$H" TMPDIR="$T/tmp" DQW_TMP="$T/dqw" FX_DIR="$F"
unset JOBS_URL GH_TOKEN GH_SOURCE GH_SOURCE_LANE PRR_NOTE PRR_READ_AT SDQ_PAYLOAD_COMMENT_OUT LEAD_VERDICT_CONTEXT
export PR_RECORD_FIELD_MAX_AGE_S=600
NOW=1795700000                        # a fixed clock (2026-11-25T12:13:20Z); D60
export PR_RECORD_NOW="$NOW"
CALLS="$F/calls.log"; PRLOG="$H/logs/pr-record.log"; SHLOG="$H/logs/prr-shadow.log"; DQLOG="$H/logs/dequeue-watch.log"
: > "$CALLS"

# gh: the comment list (sdq_payload_last) and the combined status
# (ph_status_github). gh-rc-<n> / gh-rc-status hold an rc to answer instead.
cat > "$T/shim/gh" <<'EOF'
#!/bin/bash
printf 'gh %s\n' "$*" >> "$FX_DIR/calls.log"
case "$1 $2" in
  "api --paginate")
    n=$(printf '%s' "$3" | sed -n 's#.*/issues/\([0-9]*\)/comments.*#\1#p')
    [ -r "$FX_DIR/gh-rc-$n" ] && exit "$(cat "$FX_DIR/gh-rc-$n")"
    [ -r "$FX_DIR/comments-$n.json" ] && exec cat "$FX_DIR/comments-$n.json" ;;
  "api repos/"*)
    s=$(printf '%s' "$2" | sed -n 's#.*/commits/\([0-9a-fA-F]*\)/status$#\1#p')
    [ -n "$s" ] || exit 1
    [ -r "$FX_DIR/gh-rc-status" ] && exit "$(cat "$FX_DIR/gh-rc-status")"
    [ -r "$FX_DIR/status-$s.json" ] && exec cat "$FX_DIR/status-$s.json" ;;
esac
exit 1
EOF
chmod +x "$T/shim/gh"
PATH="$T/shim:$PATH"

# The REAL libs, installed with their closures into the scratch root.
for L in bin/lib/prr-shadow.sh bin/lib/pr-record.sh bin/lib/mc-stale-dequeue.sh bin/lib/dequeue-watch/gather.sh \
         bin/lib/prr-shadow.d/pipeline-health.sh bin/lib/prr-shadow.d/dequeue-watch.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || { echo "setup: could not install $L"; exit 1; }
done
# shellcheck source=bin/lib/prr-shadow.sh
. "$H/bin/lib/prr-shadow.sh" || { echo "setup: prr-shadow.sh"; exit 1; }
# shellcheck source=bin/lib/pr-record.sh
. "$H/bin/lib/pr-record.sh" || { echo "setup: pr-record.sh"; exit 1; }
# shellcheck source=bin/lib/mc-stale-dequeue.sh
. "$H/bin/lib/mc-stale-dequeue.sh" || { echo "setup: mc-stale-dequeue.sh"; exit 1; }
# shellcheck source=bin/lib/dequeue-watch/gather.sh
. "$H/bin/lib/dequeue-watch/gather.sh" || { echo "setup: gather.sh"; exit 1; }
prr_seam_load pipeline-health || { echo "setup: pipeline-health seam"; exit 1; }
prr_seam_load dequeue-watch || { echo "setup: dequeue-watch seam"; exit 1; }

# gh_rest double (dqw_status_github, dqw_gh_comment).
gh_rest() {
  local s
  printf 'gh_rest %s\n' "$*" >> "$CALLS"
  case "$2" in
    */commits/*/status)
      s=${2#*/commits/}; s=${s%/status}
      [ -r "$F/gh-rc-status" ] && return "$(cat "$F/gh-rc-status")"
      [ -r "$F/status-$s.json" ] && { cat "$F/status-$s.json"; return 0; } ;;
  esac
  return 75
}

# The jobs double. A POST /api/pr-record-notes is applied to rec/<n>.json the
# way the worker writes it: gh_empty as JSON TEXT (the column), statuses per
# context for the row's head, a Mergify comment as the parsed value.
APPLY='def ge: (.gh_empty | if type == "string" then fromjson else (. // {}) end);
  if $b.kind == "statuses" then
    if .head_sha != $b.head then .
    elif ($b.statuses | length) == 0 then .gh_empty = ((ge + {statuses: {sha: $b.head, at: $b.at}}) | tojson)
    else .statuses = ((.statuses // {}) + ([$b.statuses[] | {key: .context, value: {state, description, sha: $b.head, at: .updated_at}}] | from_entries))
    end
  elif $b.comment == null then .gh_empty = ((ge + {mergify_queue: {sha: .head_sha, at: $b.at}}) | tojson)
  else .mergify_queue = {state: ($b.comment.body | capture("-\\*- Mergify Payload -\\*-(?<p>[\\s\\S]*?)-\\*- Mergify Payload End -\\*-").p | fromjson | .state),
       code: null, draft_pr: null, failing_checks: [], left_sha: null, comment_id: $b.comment.id,
       at: $b.comment.created_at, updated_at: $b.comment.updated_at, run_id: null}
  end'
_jobs_req() {
  local m="$1" path="$2" body="${3:-}" route n f
  printf 'JOBS %s %s %s\n' "$m" "$path" "$body" >> "$CALLS"
  [ -e "$F/JOBS_FAIL_$m" ] && return 1
  route=${path%%\?*}
  case "$m $route" in
    "GET /api/pr-records")
      n=$(printf '%s' "$path" | sed -n 's/.*[?&]number=\([0-9]*\).*/\1/p'); f="$F/rec/$n.json"
      if [ -r "$f" ]; then jq -c '{row: del(._age), age_s: (._age // 0)}' "$f"; else echo '{"row":null,"age_s":null}'; fi ;;
    "POST /api/pr-record-notes")
      n=$(jq -r .number <<<"$body"); f="$F/rec/$n.json"
      [ -r "$f" ] || { echo '{"written":0,"parsed":true}'; return 0; }
      jq -c --argjson b "$body" "$APPLY" "$f" > "$f.new" && mv "$f.new" "$f"
      echo '{"written":1,"parsed":true}' ;;
    *) return 1 ;;
  esac
}

SLUG=example-org/cromford; LSLUG=example-org/cromford
mk_sha() { printf '%040x' "$1"; }
HEAD=$(mk_sha 4242); OTHER=$(mk_sha 77)
iso() { date -u -d "@$1" +%FT%TZ; }
# row <n> <head> [extra-json] — a fresh record row (age 0).
row() {
  jq -nc --arg r "$LSLUG" --argjson n "$1" --arg h "$2" --argjson x "${3:-null}" \
    '{repo: $r, number: $n, state: "open", head_sha: $h, statuses: null, mergify_queue: null, gh_empty: null, _age: 0} + ($x // {})' > "$F/rec/$1.json"
}
ngh()   { grep -cE '^(gh|gh_rest) ' "$CALLS" || true; }
npost() { grep -c '^JOBS POST /api/pr-record-notes' "$CALLS" || true; }
reset() { : > "$CALLS"; }
lastpost() { grep '^JOBS POST /api/pr-record-notes' "$CALLS" | tail -1 | cut -d' ' -f4-; }
step() { GH_SOURCE="$1"; GH_SOURCE_LANE=""; export GH_SOURCE GH_SOURCE_LANE; }

# ── S: prr_read ───────────────────────────────────────────────────────────────
t_record() { echo rec >> "$F/t.log"; [ -n "${T_REC_OUT:-}" ] && printf '%s\n' "$T_REC_OUT"; return "${T_REC_RC:-0}"; }
t_github() { echo "gh note=${PRR_NOTE:-}" >> "$F/t.log"; printf 'G\n' > "$1"; return "${T_GH_RC:-0}"; }
t_norm()   { echo '[]'; }
t_note()   { echo "note $* at=${PRR_READ_AT:-}" >> "$F/t.log"; echo "NOTE-STDOUT"; }
tlog() { grep -c "^$1" "$F/t.log" || true; }

CASE=S1; step record; : > "$F/t.log"
T_REC_OUT=hit-rc:1 T_REC_RC=0
prr_read tl k1 "$T/s.out" t_record t_github t_norm a b; RC=$?
eq "rc" "$RC" 1
eq "source" "$PRR_SOURCE" record
eq "github calls" "$(tlog gh)" 0
eq "note calls" "$(tlog note)" 0

CASE=S1b; : > "$F/t.log"
T_REC_OUT=none T_REC_RC=1 T_GH_RC=0
OUT=$(prr_read tl k1 "$T/s.out" t_record t_github t_norm a b; echo "rc=$?")
eq "rc, and no note stdout leaks" "$OUT" "rc=0"
eq "github calls, with PRR_NOTE=1" "$(grep -c '^gh note=1$' "$F/t.log")" 1
eq "one note call: out grc why args" "$(grep '^note' "$F/t.log" | sed 's/ at=.*//')" "note $T/s.out 0 none a b"
eq "PRR_READ_AT is an ISO time" "$(grep -cE '^note .* at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$F/t.log")" 1
: > "$F/t.log"; T_GH_RC=75
prr_read tl k1 "$T/s.out" t_record t_github t_norm a b; RC=$?
eq "a GitHub rc 75 is returned" "$RC" 75
eq "the note gets grc 75" "$(grep -c '^note .* 75 none a b' "$F/t.log")" 1
eq "PRR_NOTE does not stay set" "${PRR_NOTE-unset}" unset
# A seam with no _note fn: no call, no error.
t2_record() { echo none; return 1; }
prr_read tl k1 "$T/s.out" t2_record t_github t_norm; RC=$?
eq "no _note fn: rc is GitHub's" "$RC" 75

CASE=S2; T_GH_RC=0
for v in 'hit-rc:0' 'hit-rc:10' 'hit-rc:1 extra' $'hit-rc:1\nhit-rc:1' 'hit-rc:x'; do
  : > "$F/t.log"; T_REC_OUT=$v T_REC_RC=0
  prr_read tl k1 "$T/s.out" t_record t_github t_norm; RC=$?
  eq "'$v' rc" "$RC" 0
  eq "'$v' github calls" "$(tlog gh)" 0
done

CASE=S3; step shadow; : > "$F/t.log"; : > "$SHLOG"
T_REC_OUT=hit-rc:1 T_REC_RC=0 T_GH_RC=0
prr_read tl k3 "$T/s.out" t_record t_github t_norm; RC=$?
eq "rc is GitHub's" "$RC" 0
eq "note calls" "$(tlog note)" 0
eq "PRR_NOTE is not set for the GitHub fn" "$(grep -c '^gh note=$' "$F/t.log")" 1
eq "one rc line" "$(grep -c 'PRR_SHADOW lane=tl key=k3 rc_record=1 rc_github=0$' "$SHLOG")" 1
T_GH_RC=1; : > "$SHLOG"
prr_read tl k3 "$T/s.out" t_record t_github t_norm; RC=$?
eq "equal rc: rc" "$RC" 1
eq "equal rc: no PRR_SHADOW line" "$(grep -c PRR_SHADOW "$SHLOG")" 0
T_REC_OUT=none T_REC_RC=1; : > "$F/t.log"
prr_read tl k3 "$T/s.out" t_record t_github t_norm
eq "shadow miss: note calls" "$(tlog note)" 0
# The real status seam, shadow, a head with no statuses: 0 POST.
S3H=$(mk_sha 3003); row 31 "$S3H"; echo '{"state":"pending","statuses":[]}' > "$F/status-$S3H.json"; reset
ph_prr "$SLUG#31@${S3H:0:12}:status" status "$SLUG" 31 "$S3H" >/dev/null
eq "shadow seam: 1 GitHub read" "$(ngh)" 1
eq "shadow seam: 0 POST" "$(npost)" 0

CASE=S4; step off; : > "$F/t.log"; T_REC_OUT=hit-rc:1 T_REC_RC=0 T_GH_RC=0
prr_read tl k4 "$T/s.out" t_record t_github t_norm
eq "record reads" "$(tlog rec)" 0
eq "note calls" "$(tlog note)" 0
eq "PRR_NOTE is not set" "$(grep -c '^gh note=$' "$F/t.log")" 1
reset
ph_prr "$SLUG#31@${S3H:0:12}:status" status "$SLUG" 31 "$S3H" >/dev/null
eq "off seam: 0 jobs calls" "$(grep -c '^JOBS' "$CALLS" || true)" 0

# ── R: the readers' `empty` word ──────────────────────────────────────────────
mark() { jq -nc --arg k "$1" --arg s "$2" --arg a "$3" '{($k): {sha: $s, at: $a}}'; }
rd_st() { PRR_MISS_WHY=""; pr_record_statuses "$SLUG" "$1" "$2" row-head > "$T/rd.out"; RC=$?; }
rd_mq() { PRR_MISS_WHY=""; pr_record_mergify "$SLUG" "$1" > "$T/rd.out"; RC=$?; }

CASE=R1; : > "$PRLOG"
row 11 "$HEAD" "$(jq -nc --arg g "$(mark statuses "$HEAD" "$(iso $((NOW - 5)))")" '{gh_empty: $g}')"
rd_st 11 "$HEAD"
eq "rc" "$RC" 1
eq "why" "$PRR_MISS_WHY" empty
eq "log line" "$(grep -c "statuses $LSLUG#11 miss=empty" "$PRLOG")" 1

CASE=R2
row 12 "$HEAD" "$(jq -nc --arg g "$(mark statuses "$HEAD" "$(iso $((NOW - 590)))")" '{gh_empty: $g}')"
rd_st 12 "$HEAD"; eq "knob - 10: why" "$PRR_MISS_WHY" empty
row 12 "$HEAD" "$(jq -nc --arg g "$(mark statuses "$(tr a-f A-F <<<"$HEAD")" "$(iso $((NOW - 5)))")" '{gh_empty: $g}')"
rd_st 12 "$HEAD"; eq "an upper-case marker sha is the same head" "$PRR_MISS_WHY" empty

CASE=R3
row 13 "$HEAD" "$(jq -nc --arg g "$(mark statuses "$HEAD" "$(iso $((NOW - 605)))")" '{gh_empty: $g}')"
rd_st 13 "$HEAD"; eq "knob + 5: rc" "$RC" 1; eq "knob + 5: why" "$PRR_MISS_WHY" none

CASE=R4
row 14 "$HEAD" "$(jq -nc --arg g "$(mark statuses "$OTHER" "$(iso $((NOW - 5)))")" '{gh_empty: $g}')"
rd_st 14 "$HEAD"; eq "another head: why" "$PRR_MISS_WHY" none

CASE=R5
row 15 "$HEAD" "$(jq -nc --arg g "$(mark statuses "$HEAD" "$(iso $((NOW - 5)))")" --arg h "$HEAD" \
  '{gh_empty: $g, statuses: {"lead-verdict": {state: "success", description: "ok", sha: $h, at: "2026-11-26T10:00:00Z"}}}')"
rd_st 15 "$HEAD"
eq "an entry beats the marker: rc" "$RC" 0
eq "an entry beats the marker: value" "$(jq -r '."lead-verdict".state' "$T/rd.out")" success

CASE=R6
row 16 "$HEAD" "$(jq -nc --arg g "$(mark statuses "$HEAD" "$(iso $((NOW + 60)))")" '{gh_empty: $g}')"
rd_st 16 "$HEAD"; eq "a future at: why" "$PRR_MISS_WHY" none
row 16 "$HEAD" "$(jq -nc --arg g "$(mark statuses "$HEAD" "$(iso $((NOW - 5)))")" '{gh_empty: $g}')"
PR_RECORD_FIELD_MAX_AGE_S=0 rd_st 16 "$HEAD"
eq "knob 0: rc" "$RC" 1
[ "$PRR_MISS_WHY" != empty ] && ok || bad "knob 0 trusts no marker: got $PRR_MISS_WHY"
row 16 "$HEAD" "$(jq -nc --arg g "$(mark mergify_queue "$HEAD" "$(iso $((NOW - 5)))")" '{gh_empty: $g}')"
rd_st 16 "$HEAD"; eq "only a Mergify marker, statuses asked: why" "$PRR_MISS_WHY" none
row 16 "$HEAD" '{"gh_empty":"not json"}'
rd_st 16 "$HEAD"; eq "gh_empty not JSON: why" "$PRR_MISS_WHY" none

CASE=R7
row 17 "$HEAD" "$(jq -nc --argjson g "$(mark statuses "$HEAD" "$(iso $((NOW - 5)))")" '{gh_empty: $g}')"
rd_st 17 "$HEAD"; eq "gh_empty as an object: why" "$PRR_MISS_WHY" empty
row 18 "$HEAD" "$(jq -nc --arg g "$(mark mergify_queue "$HEAD" "$(iso $((NOW - 5)))")" '{gh_empty: $g}')"
rd_mq 18; eq "mergify marker on the row head: rc" "$RC" 1; eq "mergify marker on the row head: why" "$PRR_MISS_WHY" empty
row 18 "$HEAD" "$(jq -nc --argjson g "$(mark mergify_queue "$HEAD" "$(iso $((NOW - 5)))")" '{gh_empty: $g}')"
rd_mq 18; eq "mergify marker as an object: why" "$PRR_MISS_WHY" empty
row 18 "$HEAD" "$(jq -nc --arg g "$(mark mergify_queue "$OTHER" "$(iso $((NOW - 5)))")" '{gh_empty: $g}')"
rd_mq 18; eq "mergify marker of an older head (a push since): why" "$PRR_MISS_WHY" none
row 18 "$HEAD" "$(jq -nc --arg g "$(mark mergify_queue "$HEAD" "$(iso $((NOW - 605)))")" '{gh_empty: $g}')"
rd_mq 18; eq "mergify marker older than the knob: why" "$PRR_MISS_WHY" none
row 18 "$HEAD" "$(jq -nc --arg g "$(mark mergify_queue "$HEAD" "$(iso $((NOW - 5)))")" \
  '{gh_empty: $g, mergify_queue: {state: "queued", comment_id: 5, at: "2026-11-26T10:00:00Z"}}')"
rd_mq 18; eq "a stored payload beats the marker: rc" "$RC" 0

# ── C1: sdq_payload_last and the chosen comment ─────────────────────────────────
CASE=C1
FIX="$REPO/tests/fixtures/bh-3480-pr3396-mergify-comments.json"
jq -c '[.[] | select(.id == 5882216652 or .id == 5882237379)]' "$FIX" > "$F/comments-3396.json"
O1=$(sdq_payload_last "$SLUG" 3396); R1=$?
O2=$(SDQ_PAYLOAD_COMMENT_OUT="$T/c1.comment" sdq_payload_last "$SLUG" 3396); R2=$?
eq "rc equal" "$R2" "$R1"
eq "stdout equal" "$O2" "$O1"
eq "stdout is the dequeued line" "$O1" "dequeued	$(date -u -d 2026-09-29T03:45:49Z +%s)	5882237379"
eq "the file holds the chosen comment" "$(jq -c '[.id, .created_at, .updated_at, .login, (.body | test("Mergify Payload"))]' "$T/c1.comment" 2>/dev/null)" \
  '[5882237379,"2026-09-29T02:03:02Z","2026-09-29T03:45:49Z","mergify[bot]",true]'
eq "the file has exactly the 5 keys" "$(jq -c 'keys' "$T/c1.comment" 2>/dev/null)" '["body","created_at","id","login","updated_at"]'
cp "$FIX" "$F/comments-3396.json"
O3=$(SDQ_PAYLOAD_COMMENT_OUT="$T/c1b.comment" sdq_payload_last "$SLUG" 3396)
eq "the whole fixture: the file id = the stdout cid" "$(jq -r .id "$T/c1b.comment" 2>/dev/null)" "$(cut -f3 <<<"$O3")"
echo '[]' > "$F/comments-3396.json"
O4=$(SDQ_PAYLOAD_COMMENT_OUT="$T/c1c.comment" sdq_payload_last "$SLUG" 3396); R4=$?
eq "no payload comment: rc 1" "$R4" 1
eq "no payload comment: no file" "$([ -e "$T/c1c.comment" ] && echo yes || echo no)" no
rm -f "$T"/c1*.comment

# ── A: the three measured cases, tick 1 and tick 2 against step off ────────────
# lu_decide — the pipeline-health lead-unqueued judgment of a status answer.
lu_decide() {
  jq -r 'if type == "object" then . else error("not a status") end
    | ([.statuses[]? | select(.context == "lead-verdict")] | first) as $l
    | ([.statuses[]? | select(.context == "harness-verdict")] | first) as $b
    | if $l != null and ($l.state == "failure" or $l.state == "error") then ""
      elif $l != null and $l.state == "success" then ($l.updated_at // $l.created_at // "")
      elif $b != null and $b.state == "success" then ($b.updated_at // $b.created_at // "")
      else "" end' 2>/dev/null
  echo "rc=$?"
}

CASE=A1
A1H=$(mk_sha 1001); row 21 "$A1H"; echo '{"state":"pending","statuses":[],"sha":"x"}' > "$F/status-$A1H.json"
step off; OFF=$(ph_prr "$SLUG#21@${A1H:0:12}:status" status "$SLUG" 21 "$A1H"); ROFF=$?
step record; reset; : > "$SHLOG"
T1=$(ph_prr "$SLUG#21@${A1H:0:12}:status" status "$SLUG" 21 "$A1H"); RT1=$?
eq "tick 1: 1 GitHub read" "$(ngh)" 1
eq "tick 1: 1 record write" "$(npost)" 1
eq "tick 1: the write is the empty marker of the head" "$(lastpost | jq -c '[.repo, .number, .kind, .head, .statuses, (.at | test("^[0-9-]{10}T[0-9:]{8}Z$"))]')" \
  "[\"$LSLUG\",21,\"statuses\",\"$A1H\",[],true]"
eq "tick 1: PRR_MISS why=none" "$(grep -c "PRR_MISS lane=pipeline-health key=$SLUG#21@${A1H:0:12}:status why=none" "$SHLOG")" 1
reset
T2=$(ph_prr "$SLUG#21@${A1H:0:12}:status" status "$SLUG" 21 "$A1H"); RT2=$?
eq "tick 2: 0 GitHub reads" "$(ngh)" 0
eq "tick 2: 0 writes" "$(npost)" 0
eq "rc: off = tick 1 = tick 2" "$ROFF $RT1 $RT2" "0 0 0"
eq "tick 1 decision = off" "$(lu_decide <<<"$T1")" "$(lu_decide <<<"$OFF")"
eq "tick 2 decision = off" "$(lu_decide <<<"$T2")" "$(lu_decide <<<"$OFF")"

CASE=A2
A2H=$(mk_sha 2002); row 22 "$A2H"; echo '[]' > "$F/comments-22.json"
dq_last() { tail -1 "$DQLOG" 2>/dev/null | sed 's/^[^ ]* [^ ]* //'; }
step off; dqw_gather_pr P "$SLUG" 22 >/dev/null; ROFF=$?; LOFF=$(dq_last)
eq "off: the skip line" "$LOFF" "gather: $SLUG#22 no Mergify payload, skipped"
step record; reset
dqw_gather_pr P "$SLUG" 22 >/dev/null; RT1=$?; LT1=$(dq_last)
eq "tick 1: 1 GitHub read" "$(ngh)" 1
eq "tick 1: 1 record write" "$(npost)" 1
eq "tick 1: comment null" "$(lastpost | jq -c '[.kind, .comment, (.at | type)]')" '["mergify",null,"string"]'
reset
dqw_gather_pr P "$SLUG" 22 >/dev/null; RT2=$?; LT2=$(dq_last)
eq "tick 2: 0 GitHub reads" "$(ngh)" 0
eq "tick 2: 0 writes" "$(npost)" 0
eq "rc: off = tick 1 = tick 2" "$ROFF $RT1 $RT2" "1 1 1"
eq "tick 1 line = off" "$LT1" "$LOFF"
eq "tick 2 line = off" "$LT2" "$LOFF"

CASE=A3
A3H=$(mk_sha 3003); QB=$'-*- Mergify Payload -*-\n{"state":"queued"}\n-*- Mergify Payload End -*-\nQueued'
jq -n --arg b "$QB" '[{id: 9023, user: {login: "mergify[bot]"}, body: $b, created_at: "2026-11-26T09:00:00Z", updated_at: "2026-11-26T09:30:00Z"}]' > "$F/comments-23.json"
row 23 "$A3H" '{"mergify_queue":{"state":"queued","code":null,"draft_pr":null,"failing_checks":[],"left_sha":null,"comment_id":9023,"at":"2026-11-26T09:00:00Z","run_id":null}}'
TSV="$DQW_TMP/payload-${SLUG//\//_}-23.tsv"
step off; dqw_gather_pr P "$SLUG" 23 >/dev/null; ROFF=$?; LOFF=$(dq_last); TOFF=$(cat "$TSV")
eq "off: the skip line" "$LOFF" "gather: $SLUG#23 payload says 'queued', not dequeued"
step record; reset; : > "$SHLOG"
dqw_gather_pr P "$SLUG" 23 >/dev/null; RT1=$?; LT1=$(dq_last); TT1=$(cat "$TSV")
eq "tick 1: PRR_MISS why=field:updated_at" "$(grep -c "key=$SLUG#23:payload why=field:updated_at" "$SHLOG")" 1
eq "tick 1: 1 GitHub read" "$(ngh)" 1
eq "tick 1: 1 record write" "$(npost)" 1
eq "tick 1: the chosen comment" "$(lastpost | jq -c '[.kind, .comment.id, .comment.updated_at, .comment.login]')" '["mergify",9023,"2026-11-26T09:30:00Z","mergify[bot]"]'
reset
dqw_gather_pr P "$SLUG" 23 >/dev/null; RT2=$?; LT2=$(dq_last); TT2=$(cat "$TSV")
eq "tick 2: 0 GitHub reads" "$(ngh)" 0
eq "rc: off = tick 1 = tick 2" "$ROFF $RT1 $RT2" "1 1 1"
eq "tick 1 TSV = off" "$TT1" "$TOFF"
eq "tick 2 TSV = off" "$TT2" "$TOFF"
eq "tick 2 line = off" "$LT2" "$LOFF"

CASE=A4
A4H=$(mk_sha 4004); row 24 "$A4H"
jq -nc '{state: "failure", statuses: [
  {context: "lead-verdict", state: "success", description: "MERGE", updated_at: "2026-11-26T09:10:00Z", created_at: "2026-11-26T09:10:00Z", id: 1},
  {context: "ci/x", state: "failure", description: "red", updated_at: "2026-11-26T09:20:00Z", created_at: "2026-11-26T09:20:00Z", id: 2}]}' > "$F/status-$A4H.json"
dq_stale() { jq -e --arg c lead-verdict '(.statuses | type == "array") and (any(.statuses[]; .context == $c and .state == "success") | not)' "$1" >/dev/null 2>&1 && echo 1 || echo 0; }
step off; prr_read dequeue-watch "$SLUG#24@${A4H:0:12}:status" "$T/a4.json" dqw_status_record dqw_status_github dqw_status_norm "$SLUG" 24 "$A4H"; ROFF=$?; SOFF=$(dq_stale "$T/a4.json")
step record; reset
prr_read dequeue-watch "$SLUG#24@${A4H:0:12}:status" "$T/a4.json" dqw_status_record dqw_status_github dqw_status_norm "$SLUG" 24 "$A4H"; RT1=$?; ST1=$(dq_stale "$T/a4.json")
eq "tick 1: 1 GitHub read" "$(ngh)" 1
eq "tick 1: 1 POST carrying both statuses" "$(npost) $(lastpost | jq -c '[.statuses[] | [.context, .state, .updated_at]]')" \
  '1 [["lead-verdict","success","2026-11-26T09:10:00Z"],["ci/x","failure","2026-11-26T09:20:00Z"]]'
reset
prr_read dequeue-watch "$SLUG#24@${A4H:0:12}:status" "$T/a4.json" dqw_status_record dqw_status_github dqw_status_norm "$SLUG" 24 "$A4H"; RT2=$?; ST2=$(dq_stale "$T/a4.json")
eq "tick 2: 0 GitHub reads, a record hit" "$(ngh) $PRR_SOURCE" "0 record"
eq "rc and stale decision: off = tick 1 = tick 2" "$ROFF$SOFF $RT1$ST1 $RT2$ST2" "00 00 00"

CASE=A5
A5H=$(mk_sha 5005); row 25 "$A5H"; echo '[]' > "$F/comments-25.json"
step off; ph_prr "$SLUG#25:payload" payload "$SLUG" 25 >/dev/null; ROFF=$?
step record; reset
OUT1=$(ph_prr "$SLUG#25:payload" payload "$SLUG" 25); RT1=$?
eq "tick 1: 1 GitHub read, 1 write" "$(ngh) $(npost)" "1 1"
reset
OUT2=$(ph_prr "$SLUG#25:payload" payload "$SLUG" 25); RT2=$?
eq "tick 2: 0 GitHub reads" "$(ngh)" 0
eq "rc: off = tick 1 = tick 2" "$ROFF $RT1 $RT2" "1 1 1"
eq "no value printed" "$OUT1|$OUT2" "|"

# ── E: a failed or refused GitHub read writes nothing ─────────────────────────
CASE=E1
E1H=$(mk_sha 6006); row 26 "$E1H"; echo 75 > "$F/gh-rc-26"
step record; reset
dqw_gather_pr P "$SLUG" 26 >/dev/null; R1=$?
eq "tick 1: 1 GitHub read, 0 POST" "$(ngh) $(npost)" "1 0"
eq "tick 1: the item is unread" "$R1 $(dq_last)" "1 gather: $SLUG#26 payload-unread, skipped"
reset
dqw_gather_pr P "$SLUG" 26 >/dev/null
eq "tick 2 reads GitHub again" "$(ngh) $(npost)" "1 0"
reset
ph_prr "$SLUG#26:payload" payload "$SLUG" 26 >/dev/null; R1=$?
eq "pipeline-health: rc 2, 1 read, 0 POST" "$R1 $(ngh) $(npost)" "2 1 0"
rm -f "$F/gh-rc-26"

CASE=E2
E2H=$(mk_sha 7007); row 27 "$E2H"; echo 1 > "$F/gh-rc-status"
reset
ph_prr "$SLUG#27@${E2H:0:12}:status" status "$SLUG" 27 "$E2H" >/dev/null; R1=$?
eq "403: rc 1, 1 read, 0 POST" "$R1 $(ngh) $(npost)" "1 1 0"
reset
ph_prr "$SLUG#27@${E2H:0:12}:status" status "$SLUG" 27 "$E2H" >/dev/null
eq "403: tick 2 reads GitHub again" "$(ngh) $(npost)" "1 0"
echo 75 > "$F/gh-rc-status"; reset
prr_read dequeue-watch "$SLUG#27@${E2H:0:12}:status" "$T/e2.json" dqw_status_record dqw_status_github dqw_status_norm "$SLUG" 27 "$E2H"; R1=$?
eq "dequeue-watch rc 75: 0 POST" "$R1 $(ngh) $(npost)" "75 1 0"
rm -f "$F/gh-rc-status"
echo 'not json' > "$F/status-$E2H.json"; reset
ph_prr "$SLUG#27@${E2H:0:12}:status" status "$SLUG" 27 "$E2H" >/dev/null
eq "rc 0, a body that is not JSON: 0 POST" "$(ngh) $(npost)" "1 0"
echo '{"statuses":"x"}' > "$F/status-$E2H.json"; reset
ph_prr "$SLUG#27@${E2H:0:12}:status" status "$SLUG" 27 "$E2H" >/dev/null
eq "rc 0, .statuses not an array: 0 POST" "$(ngh) $(npost)" "1 0"
eq "the record row is unchanged" "$(jq -c '[.statuses, .gh_empty]' "$F/rec/27.json")" '[null,null]'

CASE=E3
E3H=$(mk_sha 8008); row 28 "$E3H"
jq -n '[{id: 9028, user: {login: "mergify[bot]"}, body: "-*- Mergify Payload -*-\n{\"x\":1}\n-*- Mergify Payload End -*-", created_at: "2026-11-26T09:00:00Z", updated_at: "2026-11-26T09:00:00Z"}]' > "$F/comments-28.json"
reset
dqw_gather_pr P "$SLUG" 28 >/dev/null
eq "an unparsable payload (rc 2): 1 read, 0 POST" "$(ngh) $(npost)" "1 0"
reset; : > "$T/e3.out.comment"
for r in 2 3 4 75; do
  echo '{"id":1}' > "$T/e3.out.comment"
  dqw_payload_note "$T/e3.out" "$r" none "$SLUG" 28
  ph_payload_note "$T/e3.out" "$r" none "$SLUG" 28
  dqw_status_note "$T/e3.out" "$r" none "$SLUG" 28 "$E3H"
  ph_status_note "$T/e3.out" "$r" none "$SLUG" 28 "$E3H"
done
eq "note fns with rc 2/3/4/75: 0 POST" "$(npost)" 0
eq "note fns remove the comment file" "$([ -e "$T/e3.out.comment" ] && echo yes || echo no)" no

# ── F: the write-back fails ───────────────────────────────────────────────────
CASE=F1
F1H=$(mk_sha 9009); row 29 "$F1H"; echo '{"state":"pending","statuses":[]}' > "$F/status-$F1H.json"
touch "$F/JOBS_FAIL_POST"; : > "$PRLOG"; reset
OUT=$(ph_prr "$SLUG#29@${F1H:0:12}:status" status "$SLUG" 29 "$F1H"); R1=$?
eq "rc and the answer are GitHub's" "$R1 $OUT" "0 $(cat "$F/status-$F1H.json")"
eq "one put=failed line" "$(grep -c "gh-note $LSLUG#29 kind=statuses put=failed" "$PRLOG")" 1
eq "1 POST tried" "$(npost)" 1
reset
ph_prr "$SLUG#29@${F1H:0:12}:status" status "$SLUG" 29 "$F1H" >/dev/null
eq "the next tick reads GitHub again" "$(ngh)" 1
rm -f "$F/JOBS_FAIL_POST"

CASE=F2
eq "no *.comment file is left" "$(find "$T" -name '*.comment' | wc -l)" 0

# ── N: the worker half (its own suite: worker/jobs/test/pr-record-notes.bh-10213.test.js)
CASE=N1
NOTES_JS="$REPO/worker/jobs/src/routes/pr-record-notes.js"
GHE_JS="$REPO/worker/jobs/src/lib/core.d/bh-10213-pr-records-gh-empty.js"
ROUTE_TXT="$REPO/worker/jobs/test/route-table.d/bh-10213-pr-record-notes.txt"
eq "the route table fragment names the route" "$(grep -cx 'POST /api/pr-record-notes' "$ROUTE_TXT")" 1
eq "the route module answers that path" "$(grep -c '"POST", "/api/pr-record-notes"' "$NOTES_JS")" 1
eq "the column fragment adds gh_empty to pr_records" "$(grep -c 'pr_records: \[\["gh_empty", "TEXT"\]\]' "$GHE_JS")" 1
if command -v node >/dev/null 2>&1; then
  node --check "$NOTES_JS" && node --check "$GHE_JS"; eq "both modules parse" "$?" 0
fi

echo "prr-miss-writeback: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
