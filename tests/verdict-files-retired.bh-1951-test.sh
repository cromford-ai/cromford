#!/bin/bash
# tests/verdict-files-retired.bh-1951-test.sh — BH-1951 (BH-1525.3): no merge
# lane reads a verdict from a box FILE any more.
#
#   A  bin/review-autopilot.sh, run WHOLE (the bh-1066 rig: gh, agent-call and
#      beat stubbed) against a stubbed STATEFUL jobs worker, POSTs a
#      `source=box` verdict row for the head it reviewed BEFORE its key reaches
#      `reviewed`, on all three paths that write that line: the first post, the
#      promote-without-posting retry, and the BH-2310 verdict replay. A failed
#      row POST settles nothing and never buys a second review.
#   R  mc_autopilot_verdict reads rows (vd_clear_word, then vd_box_word), then
#      the PR comment — never state/review-autopilot/<key>. vd_box_word keeps
#      vd_standing's fail-closed rc contract, and a box row never STANDS.
#   G  no file a merge lane sources names state/review-autopilot on a code line.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/verdict-files-retired.bh-1951-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date -u +%s)
CREATED=$(date -u -d "@$((NOW - 86400))" '+%Y-%m-%dT%H:%M:%SZ')
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/bin/lib/mc" "$H/logs" "$H/locks" "$H/env" "$H/state" "$T/fakebin"
cp "$DIR/bin/review-autopilot.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$H/bin/"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" \
   "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/verdicts.sh" "$DIR/bin/lib/review-model.sh" \
   "$DIR/bin/lib/patch-same.sh" "$DIR/bin/lib/block-gate.sh" "$H/bin/lib/"
cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
chmod +x "$H/bin/"*.sh
printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n' > "$H/fleet.conf"
printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" p1

SHA=aaaaaaaaaaaabbbbbbbbbbbbccccccccccccdddd
SHA2=ffffffffffffbbbbbbbbbbbbccccccccccccdddd
STATE="$H/state/review-autopilot"
KEY="$STATE/o-p1-7-${SHA:0:12}"
RLOG="$H/logs/review-autopilot.log"
pulls_for() { jq -n --arg sha "$1" --arg c "$CREATED" \
  '[{number:7,html_url:"https://github.com/o/p1/pull/7",title:"BH-x: a thing",
     body:"Closes #7",head:{sha:$sha,ref:"ticket/x"},base:{ref:"main"},
     draft:false,user:{login:"operator",type:"User"},created_at:$c,updated_at:$c,
     merged_at:null,closed_at:null,labels:[],state:"open"}]' > "$T/pulls.json"; }

# --- gh: the bh-1066 rig, trimmed to what these ticks reach ------------------
{ printf '#!/bin/bash\nT=%q\n' "$T"; cat <<'EOF'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
if [ "${1:-}" = pr ] && [ "${2:-}" = comment ]; then
  BF=""
  while [ $# -gt 0 ]; do [ "$1" = --body-file ] && BF="${2:-}"; shift; done
  cat "$BF" >> "$T/posted.txt"; echo post >> "$T/post-count.txt"; exit 0
fi
case "$*" in
  api\ repos/o/p1/issues/7/comments*)
    if [ -f "$T/comments.json" ]; then cat "$T/comments.json"; else printf '[]\n'; fi ;;
  *repos/o/p1/pulls/7) printf 'HTTP/2.0 200 OK\r\n\r\n{"number":7,"state":"open","merged_at":null}\n' ;;
  api\ repos/o/p1/pulls*|*repos/o/p1/pulls\?*)
    case "$*" in *" -i "*) printf 'HTTP/2.0 200 OK\r\n\r\n' ;; esac
    cat "$T/pulls.json" ;;
  *"pr diff"*--name-only*)  printf 'bin/x.sh\n' ;;
  *"pr diff"*)              printf 'diff --git a/bin/x.sh b/bin/x.sh\n+echo hi\n' ;;
  *"pr view"*--json\ body*) printf 'Closes #7\n' ;;
  *"pr view"*)              printf 'mergeable=MERGEABLE mergeState=CLEAN checks=ci=SUCCESS\n' ;;
  *)                        : ;;
esac
exit 0
EOF
} > "$T/fakebin/gh"
{ printf '#!/bin/bash\nT=%q\n' "$T"; cat <<'EOF'
printf '%s\n' "$*" >> "$T/agent-calls.txt"
cat "$T/model-out" > "$5"
exit 0
EOF
} > "$H/bin/agent-call.sh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"

# --- curl: a STATEFUL /api/verdicts, the worker's GET shape ------------------
# POST appends to $T/vrows.json (unless $T/v500 or $T/v404own), and at that
# moment records the first line of every review-autopilot key, so the ORDER
# (row before `reviewed`) is a fact about the run. GET answers rows id DESC and
# `standing` = the newest lead/human row on the head. $T/vget503 fails every GET.
# model-routes is a 404 (the resolver then serves the box cache mrs_fixture
# wrote); anything else is {"ok":true}.
{ printf '#!/bin/bash\nT=%q\nSTATE=%q\n' "$T" "$STATE"; cat <<'EOF'
m=GET; body=""; url=""; prev=""; hdrs=""
for a in "$@"; do
  case "$prev" in
    -X) m="$a" ;; --data-binary) body="$a" ;;
    -H) case "$a" in @*) hdrs="$hdrs$(cat "${a#@}")"$'\n' ;; *) hdrs="$hdrs$a"$'\n' ;; esac ;;
  esac
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
case "$body" in @*) body=$(cat "${body#@}") ;; esac
p="${url#https://jobs.test}"
[ -f "$T/vrows.json" ] || echo '[]' > "$T/vrows.json"
qp() { printf '%s' "${p#*\?}" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1; }
case "$m $p" in
  "POST /api/verdicts")
    lead=0; grep -qi '^x-lead-verdict-token:' <<<"$hdrs" && lead=1
    printf 'POST %s lead=%s\n' "$body" "$lead" >> "$T/vposts.txt"
    for k in "$STATE"/o-p1-7-*; do [ -f "$k" ] && case "$k" in *.body) ;; *) printf '%s %s\n' "${k##*-}" "$(head -1 "$k")" >> "$T/order.txt" ;; esac; done
    if [ -e "$T/v500" ]; then printf '{"error":"boom"}\n500'; exit 0; fi
    if [ -e "$T/v404own" ]; then printf '{"error":"unknown endpoint","worker":"harness-jobs"}\n404'; exit 0; fi
    n=$(jq length "$T/vrows.json")
    row=$(jq -c --argjson id "$((n + 1))" '. + {id:$id, created_at:"2026-09-26T00:00:00Z"}' <<<"$body")
    jq -c --argjson r "$row" '. + [$r]' "$T/vrows.json" > "$T/vrows.tmp" && mv "$T/vrows.tmp" "$T/vrows.json"
    printf '%s\n201' "$(jq -c '{verdict:.}' <<<"$row")" ;;
  "GET /api/verdicts?"*)
    printf 'GET %s\n' "$p" >> "$T/vgets.txt"
    if [ -e "$T/vget503" ]; then printf '{"error":"d1 down"}\n503'; exit 0; fi
    if [ -e "$T/vget404own" ]; then printf '{"error":"unknown endpoint","worker":"harness-jobs"}\n404'; exit 0; fi
    jq -c --arg r "$(qp repo)" --argjson pr "$(qp pr)" --arg h "$(qp head)" '
      [.[] | select(.repo == $r and .pr == $pr)] | sort_by(-.id) as $rows
      | {repo:$r, pr:$pr, head:$h,
         standing:([$rows[] | select(.head_sha == $h and (.source == "lead" or .source == "human"))] | first),
         rows:$rows, truncated:false}' "$T/vrows.json"
    printf '\n200' ;;
  "GET /api/model-routes/"*) printf '{"error":"not found"}\n404' ;;
  *) printf '{"ok":true}\n200' ;;
esac
EOF
} > "$T/fakebin/curl"
chmod +x "$T/fakebin/gh" "$T/fakebin/curl" "$H/bin/agent-call.sh" "$H/bin/beat.sh"

printf 'Nothing load-bearing was deferred.\n\nVERDICT: MERGE — reads fine\n' > "$T/model-out"
RUN() { ( PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" GH_TOKEN="" JOBS_RETRIES=0 \
          REVIEW_AUTOPILOT_POST_TRIES="${PT:-6}" bash "$H/bin/review-autopilot.sh" >>"$T/run.log" 2>&1 ) || true; }
CALLS() { wc -l < "$T/agent-calls.txt" 2>/dev/null | tr -d ' '; }
POSTS() { wc -l < "$T/post-count.txt" 2>/dev/null | tr -d ' '; }
VPOSTS() { [ -f "$T/vposts.txt" ] && wc -l < "$T/vposts.txt" | tr -d ' ' || echo 0; }
ROWS() { [ -f "$T/vrows.json" ] && jq length "$T/vrows.json" || echo 0; }
K1() { head -1 "${1:-$KEY}" 2>/dev/null; }
RESET() { scratch_rm "$STATE"; scratch_rm "$H/state/merge-conductor"; rm -f "$T"/{vrows.json,vposts.txt,vgets.txt,order.txt,v500,v404own,vget503,vget404own,comments.json}
          : > "$T/agent-calls.txt"; : > "$T/posted.txt"; : > "$T/post-count.txt"; : > "$T/gh-calls.txt"; : > "$RLOG"
          pulls_for "$SHA"; }
# The conductor's read, with the real jobs client and the harness author set loaded.
APV() { ( PATH="$T/fakebin:$PATH" HARNESS="$H" JOBS_RETRIES=0 HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test
          . "$H/bin/jobs-client.sh"; . "$H/bin/lib/gh-pr-list.sh"
          . "$H/bin/lib/merge-conductor-lib.sh"; mc_init
          mc_autopilot_verdict o/p1 7 'o/p1#7' "${1:-$SHA}" ) 2>/dev/null; }
VD() { ( PATH="$T/fakebin:$PATH" HARNESS="$H" JOBS_RETRIES=0 HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test
         . "$H/bin/jobs-client.sh"; . "$H/bin/lib/verdicts.sh"; "$@" ); }
# row <head> <verdict> <source> [note] — append one row as the worker would hold it
row() { [ -f "$T/vrows.json" ] || echo '[]' > "$T/vrows.json"
        jq -c --arg h "$1" --arg v "$2" --arg s "$3" --arg n "${4:-}" \
          '. + [{id:(length + 1), repo:"o/p1", pr:7, head_sha:$h, verdict:$v, source:$s, note:$n, created_at:"2026-09-26T00:00:00Z"}]' \
          "$T/vrows.json" > "$T/vrows.tmp" && mv "$T/vrows.tmp" "$T/vrows.json"; }
COMMENT_READS() { grep -c 'issues/7/comments' "$T/gh-calls.txt" 2>/dev/null || true; }

# ============================================================================
# A1. First post: one source=box row for the head, BEFORE the key says reviewed
# ============================================================================
RESET; RUN
[ "$(CALLS)" = 1 ] && [ "$(POSTS)" = 1 ] && ok || bad "A1 calls=$(CALLS) posts=$(POSTS) log: $(cat "$RLOG")"
[ "$(ROWS)" = 1 ] && ok || bad "A1 want one verdict row, got $(ROWS): $(cat "$T/vposts.txt" 2>/dev/null)"
R1=$(jq -c '.[0]' "$T/vrows.json" 2>/dev/null)
[ "$(jq -r '.source + " " + .verdict + " " + .head_sha' <<<"$R1")" = "box MERGE $SHA" ] && ok || bad "A1 the row must be source=box MERGE on the full head: $R1"
jq -r .reviewer <<<"$R1" | grep -q '^review-autopilot@' && ok || bad "A1 reviewer: $R1"
[ "$(jq -r .note <<<"$R1")" = "review-autopilot ${SHA:0:12}" ] && ok || bad "A1 note: $R1"
grep -q 'lead=1' "$T/vposts.txt" && bad "A1 a box row must never carry the lead token" || ok
grep -q "^${SHA:0:12} reviewed " "$T/order.txt" && bad "A1 the key said reviewed BEFORE the row POST: $(cat "$T/order.txt")" || ok
grep -q "^${SHA:0:12} status=reviewed-unposted " "$T/order.txt" && ok || bad "A1 at POST time the key must still be reviewed-unposted: $(cat "$T/order.txt" 2>/dev/null)"
K1 | grep -qE '^reviewed .* verdict=MERGE$' && ok || bad "A1 key after the tick: '$(K1)'"
: > "$T/gh-calls.txt"
[ "$(APV)" = MERGE ] && ok || bad "A1 the conductor must read MERGE from the row (got '$(APV)')"
[ "$(COMMENT_READS)" = 0 ] && ok || bad "A1 a row hit must cost no comments read"
# ...and the row is what answers: with the key gone the answer is unchanged,
scratch_rm "$STATE"
[ "$(APV)" = MERGE ] && ok || bad "A1 the row alone (no key file) must still answer MERGE (got '$(APV)')"

# ============================================================================
# A2. The row POST fails: no `reviewed`, the paid body kept, ONE model call
# ============================================================================
RESET; : > "$T/v500"; RUN
[ "$(CALLS)" = 1 ] && ok || bad "A2 exactly one model call (calls=$(CALLS))"
[ "$(POSTS)" = 1 ] && ok || bad "A2 the comment went up once (posts=$(POSTS))"
K1 | grep -qE '^status=reviewed-unposted .* verdict=MERGE tries=1$' && ok || bad "A2 the key must stay reviewed-unposted tries=1: '$(K1)'"
[ -s "$KEY.body" ] && ok || bad "A2 the paid-for body must be kept"
grep -q 'box row POST failed (HTTP 500)' "$RLOG" && ok || bad "A2 the failed row is not logged with its code: $(cat "$RLOG")"
grep -q 'did NOT record' "$RLOG" && ok || bad "A2 the tick must say the comment is up but the row did not record"

# ============================================================================
# A3. Next tick, worker up: own marker found -> no second comment, no model
#     call, the row posted, the key reviewed
# ============================================================================
# BH-8419: the harness's own marker comment is the hub App's; the operator login is a person.
jq -Rs '[{body:.,user:{login:"cromford[bot]",type:"Bot"}}]' < "$T/posted.txt" > "$T/comments.json"
rm -f "$T/v500"; RUN
[ "$(CALLS)" = 1 ] && ok || bad "A3 the retry must buy no model call (calls=$(CALLS))"
[ "$(POSTS)" = 1 ] && ok || bad "A3 no second comment (posts=$(POSTS))"
[ "$(ROWS)" = 1 ] && ok || bad "A3 one row recorded (rows=$(ROWS))"
K1 | grep -qE '^reviewed .* verdict=MERGE$' && ok || bad "A3 the key must settle reviewed: '$(K1)'"
[ -e "$KEY.body" ] && bad "A3 the settled key must drop the body" || ok
tail -1 "$T/order.txt" | grep -q "^${SHA:0:12} status=reviewed-unposted " && ok || bad "A3 the row must go before the reviewed write: $(cat "$T/order.txt")"
[ "$(APV)" = MERGE ] && ok || bad "A3 the conductor reads MERGE from the promoted head's row (got '$(APV)')"

# A2' the cap: a row that keeps failing parks the head like a post that does,
# and no model call is ever bought for it.
RESET; : > "$T/v500"; PT=2 RUN
# BH-8419: the harness's own marker comment is the hub App's; the operator login is a person.
jq -Rs '[{body:.,user:{login:"cromford[bot]",type:"Bot"}}]' < "$T/posted.txt" > "$T/comments.json"
PT=2 RUN
K1 | grep -qE '^unposted-terminal .* tries=2$' && ok || bad "A2' a row that fails POST_TRIES times goes terminal: '$(K1)'"
[ "$(CALLS)" = 1 ] && [ "$(POSTS)" = 1 ] && ok || bad "A2' calls=$(CALLS) posts=$(POSTS)"

# NOT CONFIGURED: the worker's own 404 on the POST, or an UNPARSED verdict ->
# the key is written as it always was, with one log line, and no row.
RESET; : > "$T/v404own"; RUN
K1 | grep -qE '^reviewed .* verdict=MERGE$' && ok || bad "not-configured (own 404): the key must settle as before: '$(K1)'"
grep -q 'not deployed on this worker' "$RLOG" && ok || bad "not-configured (own 404) must be logged"
RESET; printf 'no verdict line here\n' > "$T/model-out"; RUN
K1 | grep -qE '^reviewed .* verdict=UNPARSED$' && ok || bad "UNPARSED: key '$(K1)'"
[ "$(VPOSTS)" = 0 ] && ok || bad "UNPARSED has no row vocabulary: no POST ($(VPOSTS))"
printf 'Nothing load-bearing was deferred.\n\nVERDICT: MERGE — reads fine\n' > "$T/model-out"

# ============================================================================
# A4. The BH-2310 replay posts a row for the NEW head; a failed row writes no
#     key and never falls through to a paid review
# ============================================================================
W="$T/work"; w() { git -C "$W" "$@"; }
edit() { sed -i.bak "${1}s/.*/$2/" "$W/f.txt" && rm -f "$W/f.txt.bak"; }
commit() { w add -A; w commit -qm "$1"; w rev-parse HEAD; }
push() { w push -q -f origin "$@" >/dev/null 2>&1; }
git init -q --bare -b main "$T/remote.git"; git init -q -b main "$W"; w remote add origin "$T/remote.git"
seq 1 30 | sed 's/^/line /' > "$W/f.txt"; commit base >/dev/null; push main
w checkout -qb pr; edit 10 'line 10 CHANGED BY PR'; R=$(commit pr-change); push pr
mkdir -p "$T/repos"; git clone -q "$T/remote.git" "$T/repos/p1"
RESET; pulls_for "$R"; REPOS_ROOT="$T/repos" RUN
[ "$(CALLS)" = 1 ] && [ "$(ROWS)" = 1 ] && ok || bad "A4 first head: calls=$(CALLS) rows=$(ROWS)"
w checkout -q main; edit 13 'line 13 EDITED ON MAIN'; commit m >/dev/null; push main
w checkout -q pr; w merge -q --no-edit main >/dev/null 2>&1; push pr; H1=$(w rev-parse HEAD)
KH1="$STATE/o-p1-7-${H1:0:12}"
pulls_for "$H1"; : > "$T/v500"; REPOS_ROOT="$T/repos" RUN
[ "$(CALLS)" = 1 ] && ok || bad "A4 a failed replay row must buy NO review (calls=$(CALLS))"
[ -e "$KH1" ] && bad "A4 a failed replay row must write no key: '$(K1 "$KH1")'" || ok
grep -q 'verdict replay from .* held: its box row did not record' "$RLOG" && ok || bad "A4 the held replay is not logged: $(tail -3 "$RLOG")"
rm -f "$T/v500"; REPOS_ROOT="$T/repos" RUN
[ "$(CALLS)" = 1 ] && ok || bad "A4 the replay retry buys nothing either (calls=$(CALLS))"
K1 "$KH1" | grep -qE '^reviewed .* verdict=MERGE$' && ok || bad "A4 the replayed key: '$(K1 "$KH1")'"
RH1=$(jq -c --arg h "$H1" '[.[] | select(.head_sha == $h)] | last' "$T/vrows.json")
[ "$(jq -r '.source + " " + .verdict' <<<"$RH1")" = "box MERGE" ] && ok || bad "A4 no box MERGE row on the replayed head: $(cat "$T/vrows.json")"
jq -r .note <<<"$RH1" | grep -q "replayed_from=${R:0:12}" && ok || bad "A4 the replay row's note must name its source head: $RH1"
[ "$(APV "$H1")" = MERGE ] && ok || bad "A4 the conductor reads MERGE for the replayed head from its row (got '$(APV "$H1")')"

# ============================================================================
# R. mc_autopilot_verdict: rows, then the comment; never the file
# ============================================================================
RESET; mkdir -p "$STATE"
# R1: a lone key file saying MERGE, no row -> nothing (red on main)
printf 'reviewed 2026-09-26 00:00:00Z verdict=MERGE\nsha=%s\n' "$SHA" > "$KEY"
[ -z "$(APV)" ] && ok || bad "R1 a lone state/review-autopilot file must not answer (got '$(APV)')"
# R2: a box row MERGE on the head -> MERGE, no comments read
RESET; row "$SHA" MERGE box
[ "$(APV)" = MERGE ] && ok || bad "R2 a box MERGE row on the head must answer MERGE (got '$(APV)')"
[ "$(COMMENT_READS)" = 0 ] && ok || bad "R2 a row hit must cost no comments read"
# R3: a box row on ANOTHER head -> nothing
RESET; row "$SHA2" MERGE box
[ -z "$(APV)" ] && ok || bad "R3 a box row on another head must not answer (got '$(APV)')"
VD vd_box_word o/p1 7 "$SHA" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "R3 vd_box_word on a head with no box row is rc 1 (got $RC)"
# R4: the worker answers 503 -> vd_box_word rc 2, the comment read runs, never the file
RESET; mkdir -p "$STATE"; row "$SHA" MERGE box; : > "$T/vget503"
printf 'reviewed 2026-09-26 00:00:00Z verdict=MERGE\n' > "$KEY"
VD vd_box_word o/p1 7 "$SHA" >/dev/null; RC=$?
[ "$RC" = 2 ] && ok || bad "R4 a 503 is unreadable, rc 2 (got $RC)"
: > "$T/gh-calls.txt"
[ -z "$(APV)" ] && ok || bad "R4 an unreadable table with a MERGE file must still print nothing (got '$(APV)')"
[ "$(COMMENT_READS)" -ge 1 ] && ok || bad "R4 the comment read must run when the rows are unreadable"
# R5: the worker's own 404 -> rc 1 (not deployed)
RESET; row "$SHA" MERGE box; : > "$T/vget404own"
VD vd_box_word o/p1 7 "$SHA" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "R5 the worker's own 404 is rc 1 (got $RC)"
# rc 0 with the word, and the NEWEST box row on the head wins
RESET; row "$SHA" BLOCK box; row "$SHA2" MERGE box; row "$SHA" MERGE-WITH-NOTES box
OUT=$(VD vd_box_word o/p1 7 "$SHA"); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = MERGE-WITH-NOTES ] && ok || bad "vd_box_word must print the newest box row on the head (rc $RC, '$OUT')"
OUT=$(VD vd_box_word o/p1 7 "${SHA:0:12}"); RC=$?
[ "$RC" = 2 ] && [ -z "$OUT" ] && ok || bad "vd_box_word on a short head is rc 2 (got $RC '$OUT')"
# R6: a lead MERGE standing beats a box BLOCK
RESET; row "$SHA" BLOCK box; row "$SHA" MERGE lead
[ "$(APV)" = MERGE ] && ok || bad "R6 a lead MERGE row must win over a box BLOCK (got '$(APV)')"
# a box BLOCK alone IS printed (the file's BLOCK was too; the conductor parks it)
RESET; row "$SHA" BLOCK box
[ "$(APV)" = BLOCK ] && ok || bad "a box BLOCK row must print BLOCK (got '$(APV)')"
# R7: ...and it never STANDS, so the block gate does not answer from it
VD vd_block_line o/p1 7 https://github.com/o/p1/pull/7 "$SHA" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "R7 a box BLOCK row must not make vd_block_line answer (got $RC)"
# the negative control: a lead BLOCK does
row "$SHA" BLOCK lead
VD vd_block_line o/p1 7 https://github.com/o/p1/pull/7 "$SHA" >/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "R7 control: a lead BLOCK must stand (got $RC)"

# ============================================================================
# G. No file a merge lane sources reads state/review-autopilot
# ============================================================================
# The closure of `. "…"` / `source "…"` lines from each merge lane, resolved
# against bin/ (and bin/lib/mc/*.sh for the conductor lib's module loop).
closure() {
  local queue=("$@") seen="" f p
  while [ "${#queue[@]}" -gt 0 ]; do
    f="${queue[0]}"; queue=("${queue[@]:1}")
    case " $seen " in *" $f "*) continue ;; esac
    [ -f "$DIR/$f" ] || continue
    seen="$seen $f"; printf '%s\n' "$f"
    # `${BASH_SOURCE[0]%/*}/x.sh` is a sibling of the sourcing file.
    while IFS= read -r p; do queue+=("$p"); done < <(
      grep -E '^[^#]*(^|[;&|{( ])(\.|source) +"' "$DIR/$f" \
        | grep -oE '(bin/lib/[A-Za-z0-9_./-]+\.sh|bin/[A-Za-z0-9_-]+\.sh|/lib/[A-Za-z0-9_-]+\.sh|%/\*\}/[A-Za-z0-9_-]+\.sh)' \
        | sed -E -e 's#^/lib/#bin/lib/#' -e "s#^%/\\*\\}/#${f%/*}/#" | sort -u)
    if grep -qE 'MC_LIB_DIR/(\$_mc_m|load)\.sh' "$DIR/$f"; then
      for p in "$DIR"/bin/lib/mc/*.sh; do queue+=("bin/lib/mc/${p##*/}"); done
    fi
  done
}
# The tier-2 sweep only enqueues (bin/lib/autoenqueue.sh, reached from
# these), and run-build.sh / review-prs.sh carry the tier-1 and review-prs merges.
LANES="bin/merge-conductor.sh bin/merge-sweep.sh bin/merge-queue.sh bin/batch-resolve.sh bin/run-build.sh bin/review-prs.sh"
# shellcheck disable=SC2086
FILES=$(closure $LANES | sort -u)
[ "$(grep -c . <<<"$FILES")" -ge 10 ] && ok || bad "G2 the resolved merge-lane source list is empty or tiny: '$FILES'"
grep -qx 'bin/lib/mc/classify.sh' <<<"$FILES" && grep -qx 'bin/lib/verdicts.sh' <<<"$FILES" \
  && ok || bad "G2 the closure must reach bin/lib/mc/classify.sh and bin/lib/verdicts.sh: $FILES"
HITS=""
while IFS= read -r f; do
  [ "$f" = bin/review-autopilot.sh ] && continue
  h=$(grep -nE 'state/review-autopilot' "$DIR/$f" | grep -vE '^[0-9]+:[[:space:]]*#') && HITS="$HITS
$f: $h"
done <<<"$FILES"
[ -z "$HITS" ] && ok || bad "G1 a merge-lane source reads state/review-autopilot on a code line:$HITS"

echo "verdict-files-retired.bh-1951: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
