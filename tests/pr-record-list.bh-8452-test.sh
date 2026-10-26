#!/bin/bash
# tests/pr-record-list.bh-8452-test.sh — BH-8452 (C0): the PR record list.
# bin/lib/pr-record.sh pr_record_list / pr_record_list_sync, and the record
# tier of bin/orphan-reconcile.sh in front of its BH-8271 file copy.
#
# The REAL lib and lane run on the BH-8271 fixture board: open ai-build issues
# #11, #12, #13 and open PRs #101 (head ticket/TK-11, owns #11), #102 (body
# `Closes #12`, owns #12) and #103 (unrelated); #13 has no owner. gh and curl
# are PATH shims that log every call. curl answers GET /api/pr-records?state=
# from $HARNESS/rec.json (the list answer shape of GET /api/pr-records, see
# worker/jobs/test/pr-record-lists.bh-8452.test.js) and saves each POST body
# to $HARNESS/post-<n>.json. prs_wake_seen is an exported table double (the
# BH-8271 suite's), quiet by default. Each case has its own $HARNESS; no network.
#
#   C1  a fresh sync: rc 0, the rows in the file, the stamp in <file>.sync, no log line
#   C2  PR_RECORD_LIST_MAX_AGE_S=0: off, 0 curl calls
#   C3  the jobs read fails: unreadable       C4  {"ok":true}: malformed
#   C5  sync null: no-sync                    C6  age 901: stale
#   C6b age 900, knob unset (default 900): hit  C6c age -5: stale
#   C7  truncated: truncated                  C8  missing title: field:title
#   C9  body "" on a row and 0 rows with a fresh sync: hits
#   C10 unknown 1 (the last sync marked a record unknown): unknown
#   C4b a list answer with no `unknown` key (an older worker): malformed
#   R1  orphan-reconcile with a fresh record list: 0 pulls calls, pl=record,
#       the same verdicts and launches as the GitHub-read run
#   R2  record no-sync: 1 pulls read, 1 PRR_MISS why=no-row, pl=read, and one
#       POST /api/pr-record-lists of the 3 PRs with the read's start time
#   R3  the sync POST answers 500: the same launches, rc 0, one list-sync log line
#   R5  a fresh record and a `pr` wake since its stamp: 1 pulls read, the
#       record is not used; the feed cannot tell: 1 read; an `issue` wake only: 0
#   R4  pr_record_list_sync on the REST fixture posts exactly the body the
#       worker suite's S6 posts to the real route (one shared fixture pair)
#   B1  no call to a real host in any case
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pr-record-list.bh-8452-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
# ONE clock read for the file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
FX="$DIR/worker/jobs/test/fixtures"

TPL="$T/tpl"
mkdir -p "$TPL/bin/lib" "$TPL/logs" "$TPL/state" "$TPL/locks" "$TPL/flags" "$TPL/env" \
         "$TPL/prompts" "$TPL/builds" "$TPL/fixture" "$T/fakebin"
P=project-5
for L in bin/orphan-reconcile.sh bin/jobs-client.sh bin/lib/preplan-lib.sh bin/lib/gh-budget.sh bin/lib/hold.sh \
         bin/lib/closeout-overdue.sh bin/lib/gh-rest.sh bin/lib/gh-rest-var.sh bin/lib/gh-rest-list.sh \
         bin/lib/wake-backstop.sh bin/lib/pr-record.sh bin/fleet-conf.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$TPL" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
for L in $(cd "$DIR" && printf '%s ' bin/lib/jobs/*.sh); do
  ( cd "$DIR" && scratch_install_closure "$L" "$TPL" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
export FLEET_CONF="$DIR/fleet.conf"
echo 'setsid /root/harness/bin/run-build.sh project-5 <issue-number> TK-<issue-number> > x' > "$TPL/prompts/$P.md"
printf 'HARNESS_SECRET=fixture-secret\nJOBS_URL=https://jobs.test\n' > "$TPL/env/global.env"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$*" >> "$HARNESS/launches.log"' > "$TPL/bin/run-build.sh"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$TPL/bin/lane-alert.sh"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$TPL/bin/pr-owner-sweep.sh"
chmod +x "$TPL/bin/"*.sh

ISO() { date -u -d "@$(( NOW - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }
jq -n --arg u "$(ISO 86400)" '[11,12,13] | map({number: ., title: "TK-\(.) ticket \(.)", body: "## Scope", comments: 0, updated_at: $u})' \
  > "$TPL/fixture/open.json"
# The open PRs as GitHub's REST pulls list returns them.
jq -n --arg u "$(ISO 3600)" '[{number:101, title:"wip", head:{ref:"ticket/TK-11", sha:("a"*40)}, base:{ref:"main", sha:("c"*40)}, body:null},
        {number:102, title:"a fix", head:{ref:"feature/x", sha:("b"*40)}, base:{ref:"main", sha:("c"*40)}, body:"Closes #12"},
        {number:103, title:"chore: deps", head:{ref:"deps/bump", sha:("c"*40)}, base:{ref:"main", sha:("c"*40)}, body:""}]
       | map(. + {state:"open", draft:false, user:{login:"operator"}, labels:[], created_at:$u, updated_at:$u,
                  html_url:"https://github.com/example-org/project-5/pull/\(.number)"})' > "$TPL/fixture/prs.json"
# The same PRs as the record's list answer holds them (GET /api/pr-records?state=open).
# rec <age_s|null> [jq filter] — the answer, written to $HARNESS/rec.json.
rec() {
  local sa=""; [ "$1" = null ] || sa=$(ISO "$1")
  jq --argjson age "$1" --arg sa "$sa" '{rows: [ .[] | {number, title, head_ref: .head.ref, head_sha: .head.sha, base_ref: .base.ref,
      author: .user.login, labels: [], body: (.body // ""), mergeable_state: null, updated_at, created_at,
      url: .html_url, draft: 0} ], truncated: false, missing: null, unknown: 0,
     sync: (if $age == null then null else {synced_at: $sa, age_s: $age, rows: 3} end)} | '"${2:-.}" \
    "$H/fixture/prs.json" > "$H/rec.json"
}

# gh: the open board, the all-states list, the PR list. Every call is logged.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
ARGS="$*"
printf '%s\n' "$ARGS" >> "$HARNESS/gh-calls.log"
SEND() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "$2"; exit 0; }
PAGE=$(printf '%s' "$ARGS" | sed -nE 's/.*[ ?&]page=([0-9]+).*/\1/p'); PAGE="${PAGE:-1}"
case "$ARGS" in
  "api repos/example-org/project-5 -q .id") echo 1; exit 0 ;;
  *"api rate_limit"*) exit 1 ;;
  *"/pulls"*) SEND 200 "$(jq -c --argjson p "$PAGE" '.[(($p - 1) * 100):($p * 100)]' "$HARNESS/fixture/prs.json")" ;;
  *"/issues/"*) SEND 404 '{"message":"Not Found"}' ;;
  *"/issues"*"state=all"*)
    [ "$PAGE" = 1 ] || SEND 200 '[]'
    SEND 200 "$(jq -c '[ .[] | {number, state:"open", closed_at:null} ]' "$HARNESS/fixture/open.json")" ;;
  *"/issues"*)
    [ "$PAGE" = 1 ] || SEND 200 '[]'
    SEND 200 "$(cat "$HARNESS/fixture/open.json")" ;;
  *) exit 1 ;;
esac
SH
# curl: the jobs worker. Logs `<METHOD> <url>`; a POST body is saved.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}" M=GET DATA=""
while [ $# -gt 0 ]; do
  case "$1" in -X) M="$2"; shift ;; --data-binary) DATA="$2"; shift ;; esac
  shift
done
printf '%s %s\n' "$M" "$URL" >> "$HARNESS/curl.log"
case "$URL" in
  */api/pr-records\?*state=*)
    [ -f "$HARNESS/curl-fail" ] && exit 7
    printf '%s\n200\n' "$(cat "$HARNESS/rec.json" 2>/dev/null || echo '{"ok":true}')" ;;
  */api/pr-record-lists)
    N=$(ls "$HARNESS"/post-*.json 2>/dev/null | wc -l)
    case "$DATA" in @*) cp "${DATA#@}" "$HARNESS/post-$N.json" ;; *) printf '%s' "$DATA" > "$HARNESS/post-$N.json" ;; esac
    if [ -f "$HARNESS/post-status" ]; then printf '{"error":"x"}\n%s\n' "$(cat "$HARNESS/post-status")"
    else printf '{"written":3,"absent":0,"synced_at":"2026-10-26T12:00:00Z"}\n200\n'; fi ;;
  */api/queue*) printf '{"queue":[]}\n200\n' ;;
  */api/jobs*)  printf '{"jobs":[]}\n200\n' ;;
  *)            printf '{"ok":true}\n200\n' ;;
esac
SH
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"
export HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.test JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 JOBS_ALERT=0
unset PR_RECORD_LIST_MAX_AGE_S PR_RECORD_MAX_AGE_S

# The wake feed double, exported so the lane's own shell inherits it. $H/wake
# rows are `<kind> <key> <rc>`; no file is rc 2 (the feed cannot tell).
prs_wake_seen() {
  local r
  [ -f "$HARNESS/wake" ] || return 2
  r=$(awk -v k="$2" -v key="$3" '($1 == k || $1 == "*") && ($2 == key || $2 == "*" || key == "-") { print $3; exit }' "$HARNESS/wake")
  return "${r:-1}"
}
export -f prs_wake_seen

# fresh <case> — a new $H copied from the template, feed quiet.
fresh() {
  H="$T/$1"
  cp -a "$TPL" "$H" || { echo "setup: could not copy the template for $1"; exit 1; }
  export HARNESS="$H"
  printf '* * 1\n' > "$H/wake"
}
# list [VAR=val...] — pr_record_list in its own shell; sets RC, WORD, ROWS.
list() {
  WORD=$(env "$@" bash -c '. "$HARNESS/bin/lib/pr-record.sh"; pr_record_list example-org/project-5 open "$HARNESS/out.json" title,head_ref,body')
  RC=$?
  ROWS=$(jq -c 'map(.number)' "$H/out.json" 2>/dev/null)
}
curls()  { cat "$H/curl.log" 2>/dev/null | grep -c 'api/pr-records'; }
logl()   { cat "$H/logs/pr-record.log" 2>/dev/null; }

# ── C1-C9: pr_record_list ────────────────────────────────────────────────────
fresh c1; rec 0; list
eq "C1 rc" "$RC" 0; eq "C1 rows" "$ROWS" '[101,102,103]'; eq "C1 stdout" "$WORD" ""; eq "C1 log" "$(logl)" ""
eq "C1 the stamp file" "$(cat "$H/out.json.sync" 2>/dev/null)" "$(ISO 0)"
grep -q 'GET https://jobs.test/api/pr-records?repo=example-org/project-5&state=open&need=title,head_ref,body$' "$H/curl.log" \
  && ok || bad "C1 the request: $(cat "$H/curl.log")"
fresh c2; rec 0; list PR_RECORD_LIST_MAX_AGE_S=0
eq "C2 rc" "$RC" 1; eq "C2 word" "$WORD" off; eq "C2 curl calls" "$(curls)" 0
grep -q ' list example-org/project-5 state=open miss=off$' <<<"$(logl)" && ok || bad "C2 log: $(logl)"
miss_case() { # miss_case <case> <word> [list args...] — after rec/setup
  local c="$1" w="$2"; shift 2
  list "$@"
  eq "$c rc" "$RC" 1; eq "$c word" "$WORD" "$w"; eq "$c rows file empty" "$(wc -c < "$H/out.json")" 0
  eq "$c stamp file empty" "$(wc -c < "$H/out.json.sync")" 0
  [ "$(grep -c " list example-org/project-5 state=open miss=$w\$" "$H/logs/pr-record.log" 2>/dev/null)" = 1 ] && ok || bad "$c log: $(logl)"
}
fresh c3; rec 0; touch "$H/curl-fail"; miss_case C3 unreadable
fresh c4; printf '{"ok":true}' > "$H/rec.json"; miss_case C4 malformed
fresh c4b; rec 0 'del(.unknown)'; miss_case C4b malformed
fresh c5; rec null; miss_case C5 no-sync
fresh c6; rec 901; miss_case C6 stale
fresh c6b; rec 900; list
eq "C6b age 900 at the default knob rc" "$RC" 0; eq "C6b rows" "$ROWS" '[101,102,103]'
fresh c6c; rec -5; miss_case C6c stale
fresh c6d; rec 30; miss_case C6d stale PR_RECORD_LIST_MAX_AGE_S=29
fresh c7; rec 0 '.truncated = true'; miss_case C7 truncated
fresh c8; rec 0 '.missing = "title"'; miss_case C8 field:title
fresh c9; rec 0 '.rows[0].body = ""'; list
eq "C9 body \"\" rc" "$RC" 0
fresh c9b; rec 0 '.rows = [] | .sync.rows = 0'; list
eq "C9b 0 rows rc" "$RC" 0; eq "C9b rows" "$ROWS" '[]'
fresh c10; rec 0 '.unknown = 1'; miss_case C10 unknown

# ── R1-R3: orphan-reconcile ───────────────────────────────────────────────────
run() {
  cat "$H/gh-calls.log" >> "$H/gh-calls.all" 2>/dev/null
  rm -f "$H/state/orphan-reconcile/$P"/*.enqueued "$H/gh-calls.log" "$H/launches.log"
  OUT=$(env HARNESS_TEST_SANDBOX=1 "$@" "$H/bin/orphan-reconcile.sh" "$P" --explain 2>/dev/null)
  RRC=$?
  LOGS=$(cat "$H/logs/$P.log" 2>/dev/null)
  : > "$H/logs/$P.log"
  LAUNCH=$(sort "$H/launches.log" 2>/dev/null)
}
pulls()    { grep -c -- 'repos/example-org/project-5/pulls' "$H/gh-calls.log" 2>/dev/null; }
summary()  { grep -o 'reconcile: open=.*' <<<"$LOGS" | tail -1; }
verdicts() { awk -F'\t' '$1 ~ /^TK-/ {print $1"\t"$3"\t"$4}' <<<"$OUT" | sort; }
posts()    { ls "$H"/post-*.json 2>/dev/null | wc -l; }

fresh r2; rec null
run
eq "R2 pulls reads" "$(pulls)" 1
eq "R2 PRR_MISS lines" "$(grep -c 'PRR_MISS' <<<"$LOGS")" 1
eq "R2 PRR_MISS why" "$(grep -c 'PRR_MISS example-org/project-5#list why=no-row$' <<<"$LOGS")" 1
grep -q ' pl=read ' <<<"$(summary)" && ok || bad "R2 summary '$(summary)', wanted pl=read"
eq "R2 one sync POST" "$(posts)" 1
eq "R2 the POST rows" "$(jq -c '[.repo, .state, (.rows | map(.number))]' "$H/post-0.json" 2>/dev/null)" '["example-org/project-5","open",[101,102,103]]'
jq -e '.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$H/post-0.json" >/dev/null 2>&1 \
  && ok || bad "R2 the POST has no read time: $(jq -c .at "$H/post-0.json" 2>&1)"
V1=$(verdicts); L1=$LAUNCH
grep -q $'^TK-11\tOWNED\tpr:#101' <<<"$V1" && grep -q $'^TK-12\tOWNED\tpr:#102' <<<"$V1" \
  && grep -q $'^TK-13\tORPHAN' <<<"$V1" && ok || bad "R2 verdicts: $V1"
grep -q 'TK-13' <<<"$L1" && ok || bad "R2 TK-13 was not launched: $L1"
eq "R2 rc" "$RRC" 0

fresh r1; rec 0
run
eq "R1 pulls reads" "$(pulls)" 0
grep -q ' pl=record ' <<<"$(summary)" && ok || bad "R1 summary '$(summary)', wanted pl=record"
eq "R1 PRR_MISS lines" "$(grep -c 'PRR_MISS' <<<"$LOGS")" 0
eq "R1 verdicts" "$(verdicts)" "$V1"
eq "R1 launches" "$LAUNCH" "$L1"
eq "R1 no sync POST on a hit" "$(posts)" 0
# The record keeps working when the BH-8271 copy is stale (the feed is quiet).
fresh r1b; rec 0
mkdir -p "$H/state/orphan-reconcile/example-org_project-5"
printf -- '-\t%s\n' "$((NOW - 5000))" > "$H/state/orphan-reconcile/example-org_project-5/prlist.meta"
echo '[]' > "$H/state/orphan-reconcile/example-org_project-5/prlist.json"
run
eq "R1b pulls reads with a stale copy" "$(pulls)" 0
eq "R1b verdicts" "$(verdicts)" "$V1"
# The record miss words the lane can meet each fall back to GitHub.
for M in 'stale:901' 'trunc:0:.truncated = true' 'field:0:.rows[1].title = null | .missing = "title"'; do
  fresh "r1-${M%%:*}"; A=${M#*:}; rec "${A%%:*}" "$( [ "$A" = "${A#*:}" ] && echo . || echo "${A#*:}")"
  run
  eq "R1 ${M%%:*} falls back: pulls reads" "$(pulls)" 1
  eq "R1 ${M%%:*} verdicts" "$(verdicts)" "$V1"
done

# R5: the BH-8271 wake guard holds for the record too. A `pr` wake since the
# stamp (a PR opened whose record write failed) forces the GitHub read.
fresh r5; rec 0; printf 'pr 104 0\n* * 1\n' > "$H/wake"
run
eq "R5 a pr wake: pulls reads" "$(pulls)" 1
grep -q ' pl=read ' <<<"$(summary)" && ok || bad "R5 summary '$(summary)', wanted pl=read"
eq "R5 verdicts" "$(verdicts)" "$V1"
fresh r5b; rec 0; rm -f "$H/wake"
run
eq "R5b the feed cannot tell: pulls reads" "$(pulls)" 1
fresh r5c; rec 0; printf 'issue 11 0\n* * 1\n' > "$H/wake"
run
eq "R5c an issue wake only: pulls reads" "$(pulls)" 0
grep -q ' pl=record ' <<<"$(summary)" && ok || bad "R5c summary '$(summary)', wanted pl=record"
fresh r5d; rec 0 '.unknown = 1'
run
eq "R5d a record marked unknown: pulls reads" "$(pulls)" 1
eq "R5d verdicts" "$(verdicts)" "$V1"

fresh r3; rec null; echo 500 > "$H/post-status"
run
eq "R3 rc" "$RRC" 0
eq "R3 launches" "$LAUNCH" "$L1"
eq "R3 verdicts" "$(verdicts)" "$V1"
eq "R3 list-sync log line" "$(grep -c ' list-sync example-org/project-5 failed$' "$H/logs/pr-record.log" 2>/dev/null)" 1

# A list at the read cap (200) may be cut: no sync.
fresh r3b; rec null
jq -n '[range(1001; 1201) | {number: ., title: "pr \(.)", head:{ref:"b/\(.)", sha:("a"*40)}, base:{ref:"main", sha:("c"*40)},
        body:"", state:"open", draft:false, user:{login:"operator"}, labels:[], created_at:"2026-10-26T00:00:00Z",
        updated_at:"2026-10-26T00:00:00Z", html_url:"https://github.com/example-org/project-5/pull/\(.)"}]' > "$H/fixture/prs.json"
run
eq "R3b a 200-row list is not synced" "$(posts)" 0

# ── R4: the writer side of the round trip ─────────────────────────────────────
fresh r4
( . "$H/bin/lib/pr-record.sh"; pr_record_list_sync example-org/project-5 open "$FX/bh-8452-rest-pulls.json" 2026-10-26T11:30:00Z )
eq "R4 rc" "$?" 0
eq "R4 the body equals the worker suite fixture" "$(jq -S -c . "$H/post-0.json" 2>/dev/null)" "$(jq -S -c . "$FX/bh-8452-list-sync-body.json")"
eq "R4 13 fields per row" "$(jq -c '[.rows[].fields | length] | unique' "$H/post-0.json" 2>/dev/null)" '[13]'

# ── B1 ───────────────────────────────────────────────────────────────────────
ALLC=$(cat "$T"/*/curl.log 2>/dev/null)
[ -n "$ALLC" ] && ok || bad "B1 no curl log at all"
OTHER=$(grep -v ' https://jobs.test/' <<<"$ALLC")
[ -z "$OTHER" ] && ok || bad "B1 a curl call to another host: $(head -3 <<<"$OTHER")"

echo "pr-record-list: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
