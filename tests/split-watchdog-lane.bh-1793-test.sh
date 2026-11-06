#!/bin/bash
# tests/split-watchdog-lane.bh-1793-test.sh — BH-1808 (BH-1793.3): the
# split-watchdog lane, driven through the REAL bin/split-watchdog.sh.
#
# WHAT IS STUBBED. At PATH: `curl` (the in-app board and the jobs worker, every
# request recorded to $T/calls), `gh` (the `gh api -i` REST envelope, answered
# from fixture files, every call recorded), and `claude`/`git`/`gh pr merge`
# tripwires that write $T/forbidden. In the scratch bin/ (a symlink tree of the
# repo's bin/): lane-alert.sh, as a recorder. Everything else is the real code:
# lane-gate, jobs-client, gh-rest, fleet-conf, internal-token-for, and the
# contract libs bin/lib/split-watchdog.sh / split-watchdog-act.sh.
#
# THE FIXTURE SEAM. The wiring cases source $T/fixture.sh through
# SPLIT_WATCHDOG_FIXTURE (sandbox only). It replaces sw_next_step with a
# recorder that saves each family's TSV under $T/dec/<first child key>.tsv and
# prints $T/decide/<first child key> when that file exists, and sw_act with a
# recorder of argv ($T/acts) and stdin ($T/act-stdin-<n>).
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/split-watchdog-lane.bh-1793-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/wait-for.sh" || exit 1  # BH-6049: wait_holder, not a fixed sleep
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "split-watchdog-lane: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

H="$T/h"
mkdir -p "$H" "$T/fakebin" "$T/gh"
cp -rs "$DIR/bin" "$H/bin"
cp -r "$DIR/catalog" "$H/catalog"
rm -f "$H/catalog/lanes.json"
rm -f "$H/bin/lane-alert.sh"
printf '#!/bin/bash\necho "lane-alert $*" >> "%s/lane-alert.calls"\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
[ -x "$DIR/bin/split-watchdog.sh" ] || { echo "split-watchdog-lane: $DIR/bin/split-watchdog.sh is missing"; exit 1; }
LANE="$H/bin/split-watchdog.sh"

cat > "$H/fleet.conf" <<'CONF'
ghp  example-org/ghp  -                 -           5  local
iap  example-org/iap  https://iap.test  /api/board  3  local
CONF

export HARNESS="$H" FLEET_CONF="$H/fleet.conf" FXT="$T" GH_ETAG=0
export JOBS_URL="http://jobs.test" HARNESS_SECRET="test-secret" JOBS_RETRIES=0 JOBS_TIMEOUT=5
export PATH="$T/fakebin:$PATH"
unset SPLIT_WATCHDOG_PROJECTS SPLIT_WATCHDOG_TICK_CAP SPLIT_WATCHDOG_MAX_FAMILIES SPLIT_WATCHDOG_FIXTURE 2>/dev/null || true

# ── curl: the in-app board and the jobs worker ─────────────────────────────
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
OUT=""; METHOD=GET; URL=""; WF=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="$2"; shift ;;
    -X) METHOD="$2"; shift ;;
    -w) WF="$2"; shift ;;
    -m|-H|--data-binary|--connect-timeout|-d) shift ;;
    http*) URL="$1" ;;
  esac
  shift
done
echo "$METHOD $URL" >> "$FXT/calls"
CODE=200; BODY='{}'
case "$URL" in
  http://jobs.test/api/queue*)
    [ -e "$FXT/q-down" ] && exit 7
    BODY=$(cat "$FXT/queue.json" 2>/dev/null || echo '{"queue":[]}') ;;
  http://jobs.test/*) CODE=404 ;;
  https://iap.test/api/board/boards)
    BODY=$(cat "$FXT/boards.json"); [ -e "$FXT/st-board" ] && CODE=$(cat "$FXT/st-board") ;;
  https://iap.test/api/board/boards/*/tickets) BODY=$(cat "$FXT/tickets.json") ;;
  *) CODE=404 ;;
esac
if [ -n "$OUT" ]; then printf '%s' "$BODY" > "$OUT"; printf '%s' "$CODE"
else printf '%s\n%s' "$BODY" "$CODE"; fi
exit 0
SH

# ── gh: the REST envelope, plus the merge tripwire ─────────────────────────
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
case "$*" in *"pr merge"*) echo "gh $*" >> "$FXT/forbidden"; exit 1 ;; esac
[ "${1:-}" = api ] || { echo "gh $*" >> "$FXT/forbidden"; exit 1; }
P=""; prev=""
for a in "$@"; do
  [ "$prev" = "-X" ] && { shift_next=1; }
  case "$a" in repos/*) P="$a" ;; esac
  prev="$a"
done
echo "GH $*" >> "$FXT/calls"
send() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "$2"; exit 0; }
st() { cat "$FXT/gh/st-$1" 2>/dev/null || printf 200; }
# open-full: an open list that fills every page, i.e. reaches the page cap.
case "$P $*" in
  "repos/example-org/ghp/issues "*state=open*)
    [ -e "$FXT/gh/open-full" ] && send 200 "$(jq -nc '[range(100) | {number: ., pull_request: {}}]')" ;;
esac
case "$*" in *"page=2"*|*"page=3"*) send 200 '[]' ;; esac
case "$P" in
  repos/example-org/ghp/issues)
    case "$*" in
      *state=open*) send "$(st open)" "$(jq -c '[.[] | select(.state == "open")]' "$FXT/gh/issues.json")" ;;
      *) send "$(st issues)" "$(cat "$FXT/gh/recent.json" 2>/dev/null || cat "$FXT/gh/issues.json")" ;;
    esac ;;
  repos/example-org/*/issues/*/timeline)
    # Real GitHub: every issue whose body MENTIONS #n is a cross-reference,
    # carrying the whole issue (body, current state, labels, repository).
    n=${P%/timeline}; n=${n##*/}
    send "$(st timeline-$n)" "$(cat "$FXT/gh/timeline-$n.json" 2>/dev/null || jq -c --arg n "$n" '[.[]
      | select((.number|tostring) != $n and ((.body // "") | test("#" + $n + "\\b")))
      | {event: "cross-referenced", source: {type: "issue",
          issue: (. + {repository: {full_name: "example-org/ghp"}})}}]' "$FXT/gh/issues.json")" ;;
  repos/example-org/*/collaborators/*/permission)
    l=${P%/permission}; l=${l##*/}
    send "$(st perm-$l)" "$(cat "$FXT/gh/perm-$l.json" 2>/dev/null || echo '{"permission":"read"}')" ;;
  repos/example-org/*/issues/*/comments)
    n=${P%/comments}; n=${n##*/}
    send "$(st comments-$n)" "$(cat "$FXT/gh/comments-$n.json" 2>/dev/null || echo '[]')" ;;
  repos/example-org/*/issues/*)
    n=${P##*/}
    send "$(st issue-$n)" "$(cat "$FXT/gh/issue-$n.json" 2>/dev/null || echo '{"state":"open"}')" ;;
  repos/example-org/*/pulls/*)
    n=${P##*/}
    send "$(st pull-$n)" "$(cat "$FXT/gh/pull-$n.json" 2>/dev/null || echo '{}')" ;;
  repos/example-org/*/pulls)
    send "$(st prlist)" "$(cat "$FXT/gh/prlist.json" 2>/dev/null || echo '[]')" ;;
esac
send 404 '{}'
SH
for t in claude git; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/forbidden"\nexit 1\n' "$t" "$T" > "$T/fakebin/$t"
done
chmod +x "$T/fakebin/"*

# ── the fixture seam ───────────────────────────────────────────────────────
cat > "$T/fixture.sh" <<'SH'
touch "$FXT/fixture-loaded"
# $FXT/die: the per-project settings apply (called directly in the project's
# walk, not in a $( )) kills that walk before it prints its count line.
if [ -f "$FXT/die" ]; then lane_env_apply() { [ -z "${2:-}" ] || exit 3; }; fi
sw_next_step() {
  local t k
  t=$(mktemp "$FXT/dec.XXXXXX"); cat > "$t"
  k=$(head -1 "$t" | cut -f1)
  mkdir -p "$FXT/dec"; mv "$t" "$FXT/dec/$k.tsv"
  echo "$*" > "$FXT/dec/$k.argv"
  [ -f "$FXT/decide/$k" ] && printf '%s\n' "$(cat "$FXT/decide/$k")"
  return 0
}
sw_act() {
  local n
  n=$(( $(wc -l < "$FXT/acts" 2>/dev/null || echo 0) + 1 ))
  cat > "$FXT/act-stdin-$n"
  (IFS=$'\t'; printf '%s\n' "$*") >> "$FXT/acts"
  cat "$FXT/act-word" 2>/dev/null || echo acted
  return "$(cat "$FXT/act-rc" 2>/dev/null || echo 0)"
}
SH

# ── the boards ─────────────────────────────────────────────────────────────
reset() {
  scratch_rm "$H/logs"; scratch_rm "$H/flags"; scratch_rm "$H/builds"; scratch_rm "$H/locks"
  scratch_rm "$H/state"; scratch_rm "$H/env"; scratch_rm "$H/prompts"
  mkdir -p "$H/logs" "$H/flags" "$H/builds" "$H/locks" "$H/state" "$H/env" "$H/prompts"
  rm -rf "$T/dec" "$T/decide" "$T/gh"; mkdir -p "$T/decide" "$T/gh"
  rm -f "$T/calls" "$T/acts" "$T"/act-stdin-* "$T/act-word" "$T/act-rc" "$T/q-down" "$T/queue.json" \
        "$T/st-board" "$T/fixture-loaded" "$T/lane-alert.calls" "$T/die"
  : > "$H/env/global.env"
  printf 'IAP_API_BASE=https://iap.test\nIAP_INTERNAL_API_TOKEN=tok-never-logged\n' > "$H/env/iap.env"
  printf 'run-build.sh ghp <issue-number> GP-<issue-number>\n' > "$H/prompts/ghp.md"
  # GitHub: #500 is the parent (no ai-build, no Part of). #501/#502 are its
  # children; #503 only mentions it, #504 is Blocked-by it and #505 says
  # "part of … #500" mid-sentence (a line-anchored parse must not take it). #600 is a second
  # family whose one child #601 lost ai-build.
  jq -n '[
    {number:500, state:"open", labels:[], body:"The master."},
    {number:501, state:"closed", labels:[{name:"ai-build"}], body:"Part of #500\nOrder: 1 of 2\nBlocked-by: #499"},
    {number:502, state:"open", labels:[{name:"ai-build"}], body:"Part of #500\nOrder: 2 of 2\nBlocked-by: #501"},
    {number:503, state:"open", labels:[{name:"ai-build"}], body:"Follow-up, see #500 for context."},
    {number:504, state:"open", labels:[{name:"ai-build"}], body:"Blocked-by: #500"},
    {number:505, state:"open", labels:[{name:"ai-build"}], body:"This is part of the cleanup after #500."},
    {number:600, state:"open", labels:[], body:"Another master."},
    {number:601, state:"open", labels:[], body:"> **Part of #600**\nOrder: 1 of 1"}
  ]' > "$T/gh/issues.json"
  echo '{"state":"open"}' > "$T/gh/issue-500.json"
  echo '{"state":"open"}' > "$T/gh/issue-600.json"
  # #501 shipped through PR 77, named by its build record.
  mkdir -p "$H/builds/ghp-GP-501-20260920"
  echo 'PR_CREATED https://github.com/example-org/ghp/pull/77 | QUEUED: merge-queue' > "$H/builds/ghp-GP-501-20260920/RESULT"
  jq -n '{state:"closed", merged_at:"2026-09-20T00:00:00Z", mergeable_state:"unknown",
          html_url:"https://github.com/example-org/ghp/pull/77", head:{sha:"abc123"}}' > "$T/gh/pull-77.json"
  # In-app: T-9 is the parent of T-11 (done) and T-12 (waiting on the client).
  echo '[{"id":"b1","name":"Product Board","keyPrefix":"T"}]' > "$T/boards.json"
  jq -n '{tickets:[
    {id:9,  key:"T-9",  status:"todo", waitingOn:"team", triageVerdict:"ready",
     children:[{id:11,key:"T-11",status:"done"},{id:12,key:"T-12",status:"todo"}]},
    {id:11, key:"T-11", status:"done", waitingOn:"team", triageVerdict:"ready", children:[]},
    {id:12, key:"T-12", status:"todo", waitingOn:"client", triageVerdict:"needs_clarification", children:[]},
    {id:13, key:"T-13", status:"done", children:[{id:14,key:"T-14",status:"done"}]},
    {id:15, key:"T-15", status:"todo", children:[]}
  ]}' > "$T/tickets.json"
}
lines()   { awk 'END{print NR}' "$1" 2>/dev/null || echo 0; }
summary() { tail -1 "$H/logs/split-watchdog.log" 2>/dev/null; }
field()   { sed -n "$2p" "$1" 2>/dev/null | cut -f"$3"; }
run()     { "$LANE" "$@" 2>"$T/err.txt"; }
runfx()   { SPLIT_WATCHDOG_FIXTURE="$T/fixture.sh" HARNESS_TEST_SANDBOX=1 "$LANE" "$@" 2>"$T/err.txt"; }
lane_calls() { grep -cE 'iap\.test|^GH |jobs\.test/api/queue' "$T/calls" 2>/dev/null || true; }

# 1. AT-7: enabled, no fixture, the REAL decider/act/ledger libs (BH-1806/7/9
# merged) against a jobs stub that serves no /api/split-watchdog route.
# TEST-CHANGE (lead merge of main): this case was written against the BH-1805
# contract stubs, whose sw_next_step decided nothing, so it pinned deferred=0.
# With the real libs the first due family asks the ledger (sw_seen), the stub
# worker cannot answer, and the lane does what the contract says for that:
# nothing acted for the project, `worker-unreachable`, the rest deferred. The
# no-write, no-ALERTS and read-the-boards checks below are unchanged.
reset
SPLIT_WATCHDOG_PROJECTS="ghp iap" run; rc=$?
check "AT-7 rc 0" '[ "$rc" = 0 ]'
check "AT-7 exactly one log line" '[ "$(lines "$H/logs/split-watchdog.log")" = 1 ]'
check "AT-7 summary shape ($(summary))" 'summary | grep -qE "^[0-9TZ:-]+ projects=2 families=3 acted=0 skipped=0 deferred=2 worker-unreachable$"'
# The lane gate's own liveness tick is every lane's baseline; the LANE makes no write.
check "AT-7 no worker POST from the lane" '! grep -E "^POST" "$T/calls" | grep -v "/api/lanes/" | grep -q .'
check "AT-7 no board write" '! grep -qE "^(POST|PATCH|PUT|DELETE) https://iap" "$T/calls"'
check "AT-7 no ALERTS" '[ ! -e "$H/logs/ALERTS.log" ]'
check "AT-7 lane-alert not called" '[ ! -e "$T/lane-alert.calls" ]'
check "AT-7 it did read the boards" '[ "$(lane_calls)" -gt 0 ]'

# 2. AT-9: the off switch.
reset
touch "$H/flags/lane-off-split-watchdog"
SPLIT_WATCHDOG_PROJECTS="ghp iap" run; rc=$?
check "AT-9 rc 0" '[ "$rc" = 0 ]'
check "AT-9 zero board/gh/queue calls" '[ "$(lane_calls)" = 0 ]'
check "AT-9 no summary" '[ ! -s "$H/logs/split-watchdog.log" ]'

# 3. Default off: SPLIT_WATCHDOG_PROJECTS unset walks nothing.
reset
run; rc=$?
check "default-off rc 0" '[ "$rc" = 0 ]'
check "default-off zero board/gh/queue calls" '[ "$(lane_calls)" = 0 ]'
check "default-off summary ($(summary))" 'summary | grep -qE " projects=0 families=0 acted=0 skipped=0 deferred=0$"'

# 4. AT-11: discovery and the contract TSV.
reset
SPLIT_WATCHDOG_PROJECTS="ghp iap" runfx
G="$T/dec/GP-501.tsv"; I="$T/dec/T-11.tsv"
check "AT-11 GitHub family found" '[ -f "$G" ]'
check "AT-11 GitHub family has 2 children" '[ "$(lines "$G")" = 2 ]'
check "AT-11 land order #501 then #502" '[ "$(cut -f1 "$G" | paste -sd,)" = "GP-501,GP-502" ]'
check "AT-11 every row has 14 fields" '[ "$(awk -F"\t" "NF!=14" "$G" "$I" | wc -l)" = 0 ] && [ -s "$I" ]'
check "AT-11 mention-only, Blocked-by and mid-line part-of are not children" '! grep -qE "GP-50[345]" "$T"/dec/*.tsv'
check "AT-11 #501 row in contract order" '[ "$(sed -n 1p "$G")" = "GP-501	501	closed	0	merged	https://github.com/example-org/ghp/pull/77	1789862400	unknown	abc123	0	none	-	-	unknown" ]'
check "AT-11 #502 has no PR (none)" '[ "$(field "$G" 2 5)" = none ]'
check "AT-11 in-app children[] order" '[ "$(cut -f1 "$I" | paste -sd,)" = "T-11,T-12" ]'
check "AT-11 in-app waiting from waitingOn=client" '[ "$(field "$I" 2 4)" = 1 ] && [ "$(field "$I" 1 4)" = 0 ]'
check "AT-11 in-app ticket id and status" '[ "$(field "$I" 1 2)" = 11 ] && [ "$(field "$I" 1 3)" = done ]'
check "AT-11 done parent and childless ticket are not families" '[ ! -e "$T/dec/T-14.tsv" ] && [ "$(ls "$T/dec" | grep -c "\.tsv$")" = 3 ]'
check "AT-11 GitHub open child without ai-build is waiting" '[ "$(field "$T/dec/GP-601.tsv" 1 4)" = 1 ]'
check "AT-11 decider argv are the knob defaults" '[ "$(cut -d" " -f2- "$T/dec/GP-501.argv")" = "10 30 plan session produced no output|PLAN_STALE" ]'
check "AT-11 fixture was loaded" '[ -e "$T/fixture-loaded" ]'

# 4b. MAX_FAMILIES=1: one family per project; the other GitHub one is deferred.
reset
SPLIT_WATCHDOG_PROJECTS="ghp" SPLIT_WATCHDOG_MAX_FAMILIES=1 runfx
check "max-families: only #500 walked" '[ -f "$T/dec/GP-501.tsv" ] && [ ! -e "$T/dec/GP-601.tsv" ]'
check "max-families: deferred=1 ($(summary))" 'summary | grep -q " families=1 acted=0 skipped=0 deferred=1$"'

# 4c. Owner HOLD comment, and an unreadable comments read, both mean waiting.
# The shapes are the real ones on example-org/cromford: the owner (operator)
# comments as CONTRIBUTOR on the org repo and holds admin; the builders App
# comments as a Bot with NONE.
hold() { jq -n --arg l "$1" --arg t "$2" --arg a "$3" \
  '[{user:{login:$l, type:$t}, author_association:$a, body:"HOLD until the client answers"}]' > "$T/gh/comments-502.json"; }
reset
hold operator User CONTRIBUTOR; echo '{"permission":"admin"}' > "$T/gh/perm-operator.json"
SPLIT_WATCHDOG_PROJECTS="ghp" runfx
check "owner HOLD (CONTRIBUTOR, admin) -> waiting 1" '[ "$(field "$T/dec/GP-501.tsv" 2 4)" = 1 ]'
check "owner HOLD: permission was read" 'grep -q "collaborators/operator/permission" "$T/calls"'
reset
hold operator User CONTRIBUTOR; echo 503 > "$T/gh/st-perm-operator"
SPLIT_WATCHDOG_PROJECTS="ghp" runfx
check "HOLD, permission read fails -> waiting 1" '[ "$(field "$T/dec/GP-501.tsv" 2 4)" = 1 ]'
reset
hold drive-by User CONTRIBUTOR
SPLIT_WATCHDOG_PROJECTS="ghp" runfx
check "HOLD by a read-only contributor -> waiting 0" '[ "$(field "$T/dec/GP-501.tsv" 2 4)" = 0 ]'
reset
hold teammate User MEMBER
SPLIT_WATCHDOG_PROJECTS="ghp" runfx
check "HOLD by an org MEMBER -> waiting 1, no permission read" '[ "$(field "$T/dec/GP-501.tsv" 2 4)" = 1 ] && ! grep -q "/permission" "$T/calls"'
reset
hold 'cromford-builders[bot]' Bot NONE
SPLIT_WATCHDOG_PROJECTS="ghp" runfx
check "a bot's HOLD -> waiting 0" '[ "$(field "$T/dec/GP-501.tsv" 2 4)" = 0 ]'
reset
hold 'cromford-builders[bot]' Bot OWNER
SPLIT_WATCHDOG_PROJECTS="ghp" runfx
check "a bot's HOLD, even as OWNER -> waiting 0" '[ "$(field "$T/dec/GP-501.tsv" 2 4)" = 0 ]'
reset
hold someone User NONE
SPLIT_WATCHDOG_PROJECTS="ghp" runfx
check "a stranger's HOLD -> waiting 0" '[ "$(field "$T/dec/GP-501.tsv" 2 4)" = 0 ]'
reset
echo 503 > "$T/gh/st-comments-502"
SPLIT_WATCHDOG_PROJECTS="ghp" runfx
check "comments read fails -> waiting 1" '[ "$(field "$T/dec/GP-501.tsv" 2 4)" = 1 ]'

# 4d. A family older than the all-states window is still found whole: its open
# child names the parent, and the members come from the parent's timeline.
reset
jq '[.[] | select(.number >= 600)]' "$T/gh/issues.json" > "$T/gh/recent.json"
SPLIT_WATCHDOG_PROJECTS="ghp" runfx
check "old family: found through its open child" '[ -f "$T/dec/GP-501.tsv" ]'
check "old family: the closed first child is there" '[ "$(cut -f1 "$T/dec/GP-501.tsv" | paste -sd,)" = "GP-501,GP-502" ]'
check "old family: timeline read" 'grep -q "issues/500/timeline" "$T/calls"'

# 4e. A family missing a child (orders not exactly 1..n) is deferred, never walked.
reset
jq '[.[] | select(.number != 501)]' "$T/gh/issues.json" > "$T/gh/tl-src.json"
jq -c '[.[] | select((.body // "") | test("#500\\b"))
  | {event:"cross-referenced", source:{type:"issue", issue:(. + {repository:{full_name:"example-org/ghp"}})}}]' \
  "$T/gh/tl-src.json" > "$T/gh/timeline-500.json"
printf 'enqueue\tGP-502\tpredecessor merged' > "$T/decide/GP-502"
SPLIT_WATCHDOG_PROJECTS="ghp" runfx
check "partial family: not handed to the decider" '[ ! -e "$T/dec/GP-501.tsv" ] && [ ! -e "$T/dec/GP-502.tsv" ] && [ ! -e "$T/acts" ]'
check "partial family: deferred=1 ($(summary))" 'summary | grep -q " families=1 acted=0 skipped=0 deferred=1$"'
check "partial family: logged" 'grep -q " PARTIAL_FAMILY ghp 500$" "$H/logs/split-watchdog.log"'
reset
jq '[.[] | if .number == 502 then .body = "Part of #500\nBlocked-by: #501" else . end]' "$T/gh/issues.json" > "$T/gh/i2.json"
mv "$T/gh/i2.json" "$T/gh/issues.json"
SPLIT_WATCHDOG_PROJECTS="ghp" runfx
check "child without an Order line: family deferred" '[ ! -e "$T/dec/GP-501.tsv" ] && summary | grep -q " deferred=1$"'
reset
echo 503 > "$T/gh/st-timeline-500"
SPLIT_WATCHDOG_PROJECTS="ghp" runfx
check "timeline read fails: family deferred" '[ ! -e "$T/dec/GP-501.tsv" ] && [ -e "$T/dec/GP-601.tsv" ] && summary | grep -q " families=1 acted=0 skipped=0 deferred=1$"'

# 4f. An open list that reaches the page cap may be truncated: the project defers.
reset
touch "$T/gh/open-full"
SPLIT_WATCHDOG_PROJECTS="ghp" runfx
check "open list at the page cap: no family, deferred=1 ($(summary))" '[ ! -d "$T/dec" ] && summary | grep -q " families=0 acted=0 skipped=0 deferred=1$"'

# 5. Land order from the newest DECOMPOSED record.
reset
mkdir -p "$H/builds/iap-T-9-x"; echo 'DECOMPOSED T-12,T-11' > "$H/builds/iap-T-9-x/RESULT"
SPLIT_WATCHDOG_PROJECTS="iap" runfx
check "DECOMPOSED land order T-12,T-11" '[ "$(cut -f1 "$T/dec/T-12.tsv" 2>/dev/null | paste -sd,)" = "T-12,T-11" ]'

# 5b. An in-app board that does not answer defers the project.
reset
echo 500 > "$T/st-board"
SPLIT_WATCHDOG_PROJECTS="iap" runfx
check "board 500 -> no family, deferred=1 ($(summary))" '[ ! -d "$T/dec" ] && summary | grep -q " families=0 acted=0 skipped=0 deferred=1$"'

# 6. Closed parent drops the family; an unreadable parent defers it.
reset
echo '{"state":"closed"}' > "$T/gh/issue-500.json"
SPLIT_WATCHDOG_PROJECTS="ghp" runfx
check "closed parent: no #500 family" '[ ! -e "$T/dec/GP-501.tsv" ] && [ -e "$T/dec/GP-601.tsv" ]'
check "closed parent: not deferred ($(summary))" 'summary | grep -q " families=1 acted=0 skipped=0 deferred=0$"'
reset
echo 503 > "$T/gh/st-issue-500"
SPLIT_WATCHDOG_PROJECTS="ghp" runfx
check "parent rc 75: no #500 family" '[ ! -e "$T/dec/GP-501.tsv" ]'
check "parent rc 75: deferred=1 ($(summary))" 'summary | grep -q " deferred=1$"'

# 7. Wiring: one decision -> one sw_act with that step and the family TSV.
reset
printf 'enqueue\tGP-502\tpredecessor merged' > "$T/decide/GP-501"
SPLIT_WATCHDOG_PROJECTS="ghp iap" runfx
check "wiring: exactly one sw_act" '[ "$(lines "$T/acts")" = 1 ]'
check "wiring: sw_act argv" '[ "$(cat "$T/acts")" = "ghp	500	box	enqueue	GP-502	predecessor merged" ]'
check "wiring: sw_act stdin is the decider stdin" 'cmp -s "$T/act-stdin-1" "$T/dec/GP-501.tsv"'
check "wiring: acted=1 ($(summary))" 'summary | grep -qE " projects=2 families=3 acted=1 skipped=0 deferred=0$"'
reset
printf 'enqueue\tGP-502\tpredecessor merged' > "$T/decide/GP-501"
echo stalled > "$T/act-word"
SPLIT_WATCHDOG_PROJECTS="ghp" runfx
check "wiring: stalled counts skipped ($(summary))" 'summary | grep -q " acted=0 skipped=1 deferred=0$"'
reset
printf 'enqueue GP-502' > "$T/decide/GP-501"
SPLIT_WATCHDOG_PROJECTS="ghp" runfx
check "bad decision: no sw_act, logged" '[ ! -e "$T/acts" ] && grep -q " BAD_DECISION ghp 500 " "$H/logs/split-watchdog.log"'

# 8. Tick cap 1 with two due families.
reset
printf 'enqueue\tGP-502\tpredecessor merged' > "$T/decide/GP-501"
printf 'owed-completion\tGP-601\tmerged, no comment' > "$T/decide/GP-601"
SPLIT_WATCHDOG_PROJECTS="ghp" SPLIT_WATCHDOG_TICK_CAP=1 runfx
check "tick cap: one sw_act" '[ "$(lines "$T/acts")" = 1 ]'
check "tick cap: deferred=1 ($(summary))" 'summary | grep -q " acted=1 skipped=0 deferred=1$"'
reset
printf 'enqueue\tGP-502\tpredecessor merged' > "$T/decide/GP-501"
printf 'close-parent\TK-12\tall merged' > "$T/decide/T-11"
SPLIT_WATCHDOG_PROJECTS="ghp iap" SPLIT_WATCHDOG_TICK_CAP=1 runfx
check "tick cap spans projects: one sw_act" '[ "$(lines "$T/acts")" = 1 ]'

# 9. OBSERVE under automerge-disabled.
reset
touch "$H/flags/automerge-disabled"
printf 'enqueue\tGP-502\tpredecessor merged' > "$T/decide/GP-501"
SPLIT_WATCHDOG_PROJECTS="ghp" runfx
check "observe: zero sw_act" '[ ! -e "$T/acts" ]'
check "observe: OBSERVE line" 'grep -qE " OBSERVE ghp 500 enqueue GP-502 predecessor merged$" "$H/logs/split-watchdog.log"'
check "observe: counted skipped, summary last ($(summary))" 'summary | grep -q " acted=0 skipped=1 deferred=0$"'

# 10. AT-14: sw_act rc 1 stops the project.
reset
printf 'enqueue\tGP-502\tpredecessor merged' > "$T/decide/GP-501"
printf 'owed-completion\tGP-601\tmerged, no comment' > "$T/decide/GP-601"
echo 1 > "$T/act-rc"
SPLIT_WATCHDOG_PROJECTS="ghp" runfx
check "AT-14 one sw_act only" '[ "$(lines "$T/acts")" = 1 ]'
# Both due families are deferred: the one sw_act failed on and the one after it.
check "AT-14 worker-unreachable ($(summary))" 'summary | grep -qE " families=2 acted=0 skipped=0 deferred=2 worker-unreachable$"'

# 10b. A project whose walk dies before its count line is deferred, not zero.
reset
touch "$T/die"
SPLIT_WATCHDOG_PROJECTS="ghp" runfx; rc=$?
check "died project: rc 0, deferred=1 ($(summary))" '[ "$rc" = 0 ] && summary | grep -qE " projects=1 families=0 acted=0 skipped=0 deferred=1$"'

# 11. Unknown is never none.
reset
echo 503 > "$T/gh/st-pull-77"
SPLIT_WATCHDOG_PROJECTS="ghp" runfx
check "PR read 75 -> pr_state unknown" '[ "$(field "$T/dec/GP-501.tsv" 1 5)" = unknown ]'
check "PR read 75 -> mergeable unknown" '[ "$(field "$T/dec/GP-501.tsv" 1 8)" = unknown ]'
check "PR read 75 -> head_sha unknown" '[ "$(field "$T/dec/GP-501.tsv" 1 9)" = unknown ]'
check "PR read 75 -> merged_at unknown" '[ "$(field "$T/dec/GP-501.tsv" 1 7)" = unknown ]'
reset
echo 503 > "$T/gh/st-prlist"
SPLIT_WATCHDOG_PROJECTS="ghp" runfx
check "PR search 75 -> unknown, not none" '[ "$(field "$T/dec/GP-501.tsv" 2 5)" = unknown ]'
reset
touch "$T/q-down"
SPLIT_WATCHDOG_PROJECTS="ghp" runfx
check "queue outage -> unknown" '[ "$(field "$T/dec/GP-501.tsv" 1 11)" = unknown ] && [ "$(field "$T/dec/GP-501.tsv" 1 13)" = unknown ]'
reset
echo '{"queue":[]}' > "$T/queue.json"
SPLIT_WATCHDOG_PROJECTS="ghp" runfx
check "queue empty -> none" '[ "$(field "$T/dec/GP-501.tsv" 1 11)" = none ]'
reset
echo '{"queue":[{"status":"failed","reason":"plan session\tproduced no output","finished_at":"2026-09-28T10:00:00Z"}]}' > "$T/queue.json"
SPLIT_WATCHDOG_PROJECTS="ghp" runfx
check "queue row -> status, flat reason, epoch" '[ "$(field "$T/dec/GP-501.tsv" 1 11)" = failed ] && [ "$(field "$T/dec/GP-501.tsv" 1 12)" = "plan session produced no output" ] && [ "$(field "$T/dec/GP-501.tsv" 1 13)" = 1790589600 ]'
reset
( flock 8; exec sleep 5 ) 8>"$H/locks/build-key-ghp-GP-502.lock" &
LP=$!; wait_holder "$LP"
SPLIT_WATCHDOG_PROJECTS="ghp" runfx
kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null
check "held build-key lock -> lock_held 1" '[ "$(field "$T/dec/GP-501.tsv" 2 10)" = 1 ] && [ "$(field "$T/dec/GP-501.tsv" 1 10)" = 0 ]'

# 12. The fixture is sandbox only.
reset
env -u HARNESS_TEST_SANDBOX SPLIT_WATCHDOG_FIXTURE="$T/fixture.sh" SPLIT_WATCHDOG_PROJECTS="ghp" "$LANE" 2>/dev/null
check "no sandbox -> fixture not sourced" '[ ! -e "$T/fixture-loaded" ]'

# 12b. Single flight: a held lane lock skips the tick.
reset
( flock 8; exec sleep 5 ) 8>"$H/locks/split-watchdog.lock" &
LP=$!; wait_holder "$LP"
SPLIT_WATCHDOG_PROJECTS="ghp iap" run; rc=$?
kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null
check "lock held -> rc 0" '[ "$rc" = 0 ]'
check "lock held -> no summary, no calls" '[ ! -s "$H/logs/split-watchdog.log" ] && [ "$(lane_calls)" = 0 ]'

# 12c. A per-project hold skips that project.
reset
touch "$H/flags/lane-off-split-watchdog-ghp"
SPLIT_WATCHDOG_PROJECTS="ghp iap" run
check "project hold -> projects=1 ($(summary))" 'summary | grep -q " projects=1 families=1 "'
check "project hold -> no read of the held project" '! grep -q "example-org/ghp" "$T/calls"'

# 13. AT-13: never merges, pushes, rebases or calls a model.
check "AT-13 no forbidden call" '[ ! -e "$T/forbidden" ]'

# 14. AT-10: the registry, the cron render and the map. `bin/render-cron.sh
# --check` renders all ten boxes (~45 s) and CI runs it directly (the repo
# CLAUDE.md verification contract), so this suite renders only the hub.
( cd "$DIR" && HARNESS_TEST_SANDBOX=1 bin/lanes-build.sh --check >/dev/null 2>&1 ); r1=$?
( cd "$DIR" && HARNESS_TEST_SANDBOX=1 bin/verification-map-build.sh --check >/dev/null 2>&1 ); r3=$?
check "AT-10 lanes-build --check" '[ "$r1" = 0 ]'
check "AT-10 verification-map --check" '[ "$r3" = 0 ]'
"$DIR/bin/lanes-build.sh" --to "$T/lanes.json" >/dev/null 2>&1
L=$(jq -c '.lanes[] | select(.id == "split-watchdog")' "$T/lanes.json" 2>/dev/null)
check "AT-10 composed: scope hub, */10" '[ "$(printf "%s" "$L" | jq -r "[.scope, .cadence, (.boxes|join(\",\")), .switch.name] | join(\"|\")")" = "hub|*/10 * * * *|hub|lane-off-split-watchdog" ]'
for k in PROJECTS N_MIN RETRY_M_MIN TICK_CAP FAMILY_DAY_CAP STALL_K MAX_FAMILIES RETRY_REASONS; do
  check "AT-10 knob SPLIT_WATCHDOG_$k" 'printf "%s" "$L" | jq -e --arg e "SPLIT_WATCHDOG_$k" "any(.knobs[]; .env == \$e)" >/dev/null'
done
check "AT-10 the fixture knob is not settable" 'printf "%s" "$L" | jq -e "any(.knobs[]; .env == \"SPLIT_WATCHDOG_FIXTURE\" and .settable == false)" >/dev/null'
n=$( cd "$DIR" && bin/render-cron.sh hub 2>/dev/null | grep -c 'split-watchdog\.sh' )
check "AT-10 hub render has one split-watchdog line" '[ "$n" = 1 ]'

echo "split-watchdog-lane: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
