#!/bin/bash
# tests/prr-read-on-change.bh-10351-test.sh — BH-10351: in step record, a lane
# reads a PR from GitHub only after a change. Each case drives prr_read
# (bin/lib/prr-shadow.sh) with the lane's real seam and a stub jobs client and
# a stub GitHub side that count their calls. Fixture clock: PR_RECORD_NOW and
# fixed ISO times; no case compares the box clock with the worker clock.
#
#   R1-R4 tickets-snapshot-push, tsp_ref_states: 140 refs and a worker max of
#         50 -> 1 refused GET + 3 chunk GETs, all rows joined (before: the
#         refused GET was `unreadable`, and every branch read GitHub); 20 refs
#         -> 1 GET; a chunk that fails -> unreadable, empty file; a 400 that is
#         not too_many -> unreadable
#   S1-S7 scheduler parent lookup: tick 1 reads GitHub once and writes the
#         memo; quiet ticks 2-3 read 0; a new closed/merged record row of the
#         branch (a change) reads again; an open record row answers `open`
#         with 0 reads; an `open` GitHub answer writes no memo; a failed
#         GitHub read writes nothing; step off reads GitHub on every tick,
#         writes no memo and no PRR line; memo GC keeps this tick's branches
#   M1-M5 merge-conductor open list: a `stale` miss whose GitHub read
#         answered writes the list back once (POST /api/pr-record-lists, at =
#         the read's start); `field:cross`, a failed read, a page of 100 on
#         the external key, and step off write nothing; an older snapshot
#         time is the `at`
#   W1-W6 wake-loop sha lookup (wck_sha_prs): an open record row at that
#         head answers with 0 GitHub reads and names only that PR; the tip of
#         a base branch answers "none" (rc 1) with 0 reads; a sha the record
#         does not know reads GitHub once; a stale list reads GitHub; step
#         off reads GitHub and writes no PRR line
#   Z1    no real host: every jobs and GitHub call went to a stub
#
# Run from anywhere: bash tests/prr-read-on-change.bh-10351-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2', wanted '$3'"; fi; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; W="$T/w"; mkdir -p "$H/logs" "$H/state" "$W"
hd() { printf '%040x' "$((0xabc000 + $1))"; }
cnt() { [ -s "$1" ] && grep -c "${2:-.}" "$1" || echo 0; }

# The stub jobs client. Answers by path:
#   /api/pr-records?...&state=open    $W/list.json
#   /api/pr-record-refs?...           rows of $W/refs.json whose head_ref is
#                                     asked; more refs than $W/refs-max is a
#                                     400 too_many {max}; $W/refs-fail.<n>
#                                     fails the n-th refs GET; $W/refs-400
#                                     answers a 400 that is not too_many
#   POST /api/pr-record-lists         logs the body to $W/sync.log
# Every call is a line in $W/jobs.log.
stubs() {
  _prr_client() { return 0; }
  _jobs_req() {
    printf '%s %s\n' "$1" "$2" >> "$W/jobs.log"
    case "$1 $2" in
      "GET /api/pr-records?"*"state=open"*) cat "$W/list.json"; return 0 ;;
      "GET /api/pr-record-refs?"*)
        local k q js n max
        k=$(( $(cnt "$W/jobs.log" 'pr-record-refs') ))
        [ -e "$W/refs-fail.$k" ] && return 1
        if [ -e "$W/refs-400" ]; then
          [ -n "${JOBS_BODY_FILE:-}" ] && echo '{"error":"invalid_field","field":"refs"}' > "$JOBS_BODY_FILE"; return 1
        fi
        q=${2#*refs=}; q=${q%%&*}; js=$(printf '%b' "${q//%/\\x}")
        n=$(jq 'length' <<<"$js"); max=$(cat "$W/refs-max" 2>/dev/null || echo 50)
        if [ "$n" -gt "$max" ]; then
          [ -n "${JOBS_BODY_FILE:-}" ] && printf '{"error":"too_many","field":"refs","max":%s}' "$max" > "$JOBS_BODY_FILE"
          return 1
        fi
        jq -c --argjson refs "$js" '{rows: [.[] | select(.head_ref as $h | any($refs[]; . == $h))], truncated: false}' "$W/refs.json"
        return 0 ;;
      "POST /api/pr-record-lists") printf '%s\n' "$3" >> "$W/sync.log"; echo '{"written":1,"absent":0,"synced_at":"2026-11-27T10:00:00Z"}'; return 0 ;;
    esac
    return 1
  }
}
list() {   # list <age> <rows-json-array>
  jq -nc --argjson a "$1" --argjson r "$2" '{rows: $r, truncated: false, sync: {synced_at: "2026-11-27T09:00:00Z", age_s: $a}, missing: null, unknown: 0}' > "$W/list.json"
}
lrow() {   # lrow <n> [head_ref] [head_sha]
  jq -nc --argjson n "$1" --arg r "${2:-ticket/bh-$1}" --arg h "${3:-$(hd "$1")}" \
    '{number:$n, title:"t", head_ref:$r, head_sha:$h, base_ref:"main", author:"operator", labels:[],
      body:"", mergeable_state:null, updated_at:"2026-11-27T08:00:00Z", created_at:"2026-11-27T07:00:00Z",
      url:("https://github.com/example-org/demo-os/pull/"+($n|tostring)), draft:0, merged_at:null}'
}
reset() { rm -f "$W"/*.log "$W"/refs-fail.* "$W/refs-400"; }

# ── R1-R4: tsp_ref_states chunks at the worker's max ──────────────────────────
tsp() {
  ( export HARNESS="$H"
    . "$DIR/bin/lib/pr-record.sh" || exit 9
    stubs
    . "$DIR/bin/lib/prr-shadow.d/tickets-snapshot-push.sh" || exit 8
    "$@" > "$T/out" 2>/dev/null; echo $? > "$T/rc" )
}
REFS=(); for i in $(seq 1 140); do REFS+=("ticket/so-$i"); done
jq -nc '[range(1; 141) | select(. % 10 == 0) | {number: (1000 + .), state: "merged", head_ref: "ticket/so-\(.)", merged_at: "2026-11-20T00:00:00Z"}]' > "$W/refs.json"
echo 50 > "$W/refs-max"; reset
tsp tsp_ref_states "$T/r1.json" example-org/project-9 "${REFS[@]}"
eq "R1 rc" "$(cat "$T/rc")" 0
eq "R1 refs GETs: 1 refused + 3 chunks" "$(cnt "$W/jobs.log" pr-record-refs)" 4
eq "R1 every row joined" "$(jq 'length' "$T/r1.json")" 14
reset
tsp tsp_ref_states "$T/r2.json" example-org/project-9 "${REFS[@]:0:20}"
eq "R2 within the max: one GET" "$(cat "$T/rc"):$(cnt "$W/jobs.log" pr-record-refs):$(jq 'length' "$T/r2.json")" "0:1:2"
reset; touch "$W/refs-fail.3"
tsp tsp_ref_states "$T/r3.json" example-org/project-9 "${REFS[@]}"
eq "R3 a failed chunk" "$(cat "$T/rc"):$(cat "$T/out")" "1:unreadable"
[ ! -s "$T/r3.json" ] && ok || bad "R3 a failed chunk must leave the file empty"
reset; touch "$W/refs-400"
tsp tsp_ref_states "$T/r4.json" example-org/project-9 "${REFS[@]}"
eq "R4 another 400" "$(cat "$T/rc"):$(cat "$T/out"):$(cnt "$W/jobs.log" pr-record-refs)" "1:unreadable:1"

# ── S1-S7: the scheduler parent memo ──────────────────────────────────────────
# sched <step> <branch> -> runs prr_read scheduler once; the stub sw_parent_pr
# (the GitHub read) answers $W/gh-parent and logs to $W/gh.log.
sched() {
  ( export HARNESS="$H" GH_SOURCE="$1" GH_SOURCE_LANE=scheduler PR_RECORD_NOW=1795770000
    . "$DIR/bin/lib/pr-record.sh" || exit 9
    stubs
    sw_parent_pr() { printf '%s %s\n' "$1" "$2" >> "$W/gh.log"; cat "$W/gh-parent"; }
    . "$DIR/bin/lib/prr-shadow.sh" || exit 9
    prr_seam_load scheduler || exit 8
    prr_read scheduler "example-org/demo-os#$2" "$T/sp.out" sched_parent_record sched_parent_github sched_parent_norm example-org/demo-os "$2"
    echo $? > "$T/rc"; cat "$T/sp.out" > "$T/out" )
}
MEMOF="$H/state/prr-memo/scheduler-parents.tsv"
list 10 "[$(lrow 5)]"; echo '[]' > "$W/refs.json"; reset; rm -f "$MEMOF"
echo none > "$W/gh-parent"
sched record ticket/bh-7
eq "S1 tick 1 reads GitHub once" "$(cnt "$W/gh.log"):$(cat "$T/out")" "1:none"
eq "S1 the memo row" "$(cat "$MEMOF" 2>/dev/null)" "$(printf 'example-org/demo-os\tticket/bh-7\t-\tnone')"
sched record ticket/bh-7; sched record ticket/bh-7
eq "S2 quiet ticks 2-3: 0 GitHub reads, the memo answers" "$(cnt "$W/gh.log"):$(cat "$T/rc"):$(cat "$T/out")" "1:0:none"
eq "S2 no miss line on a memo hit" "$(cnt "$H/logs/prr-shadow.log" 'key=example-org/demo-os#ticket/bh-7')" 1
# A change: the branch's PR merged (a merged record row). GitHub answers merged.
echo '[{"number":77,"state":"merged","head_ref":"ticket/bh-7","merged_at":"2026-11-27T09:30:00Z"}]' > "$W/refs.json"
echo 'merged 77 https://github.com/example-org/demo-os/pull/77' > "$W/gh-parent"
sched record ticket/bh-7
eq "S3 a new merged row is a change: one read" "$(cnt "$W/gh.log"):$(cat "$T/out")" "2:merged 77 https://github.com/example-org/demo-os/pull/77"
sched record ticket/bh-7
eq "S3 then quiet again" "$(cnt "$W/gh.log"):$(cat "$T/out")" "2:merged 77 https://github.com/example-org/demo-os/pull/77"
# An open PR of a parent branch is in the record's open list: 0 reads.
list 10 "[$(lrow 9 ticket/bh-9)]"; reset
sched record ticket/bh-9
eq "S4 an open record row answers open" "$(cnt "$W/gh.log"):$(cat "$T/out")" "0:open 9 https://github.com/example-org/demo-os/pull/9"
# GitHub says open but the record has no open row: no memo row.
echo 'open 8 https://github.com/example-org/demo-os/pull/8' > "$W/gh-parent"
sched record ticket/bh-8; sched record ticket/bh-8
eq "S5 an open GitHub answer is not kept" "$(cnt "$W/gh.log"):$(grep -c 'ticket/bh-8' "$MEMOF")" "2:0"
echo 'unreadable 75' > "$W/gh-parent"
sched record ticket/bh-6; sched record ticket/bh-6
eq "S5 a failed read writes nothing" "$(cnt "$W/gh.log"):$(grep -c 'ticket/bh-6' "$MEMOF")" "4:0"
# Step off: today's read every tick, no memo, no PRR line.
reset; rm -f "$MEMOF" "$H/logs/prr-shadow.log"; echo none > "$W/gh-parent"; list 10 "[$(lrow 5)]"
sched off ticket/bh-3; sched off ticket/bh-3
eq "S6 step off: every tick reads, nothing else" "$(cnt "$W/gh.log"):$([ -e "$MEMOF" ] && echo memo || echo -):$([ -e "$H/logs/prr-shadow.log" ] && echo log || echo -):$(cnt "$W/jobs.log")" "2:-:-:0"
# GC: this tick's parent branches only, other repos untouched.
mkdir -p "${MEMOF%/*}"
printf 'example-org/demo-os\tticket/bh-1\t-\tnone\nexample-org/demo-os\tticket/bh-2\t-\tnone\nexample-org/other\tticket/bh-1\t-\tnone\n' > "$MEMOF"
printf 'ticket/bh-2\n' > "$T/brs"
( export HARNESS="$H"; . "$DIR/bin/lib/pr-record.sh"; . "$DIR/bin/lib/prr-shadow.d/scheduler.sh"; sched_parent_memo_gc example-org/demo-os "$T/brs" )
eq "S7 gc keeps this tick's branches and other repos" "$(cut -f1,2 "$MEMOF" | tr '\t\n' ' ,')" "example-org/demo-os ticket/bh-2,example-org/other ticket/bh-1,"
: > "$T/brs"
( export HARNESS="$H"; . "$DIR/bin/lib/pr-record.sh"; . "$DIR/bin/lib/prr-shadow.d/scheduler.sh"; sched_parent_memo_gc example-org/demo-os "$T/brs" )
eq "S7 no parents: only this repo's rows leave" "$(cut -f1,2 "$MEMOF" | tr '\t\n' ' ,')" "example-org/other ticket/bh-1,"

# ── M1-M5: the conductor's open list write-back ───────────────────────────────
# mcl <step> <key-suffix> <record-fn> <github-fn-body-file> <rc>: prr_read
# merge-conductor with the real mc_* record and note functions; the GitHub
# side is a stub that copies <file> and returns <rc>, and logs to $W/gh.log.
mcl() {
  ( export HARNESS="$H" GH_SOURCE="$1" GH_SOURCE_LANE=merge-conductor PR_RECORD_NOW=1795770000 PR_RECORD_LIST_MAX_AGE_S=900
    . "$DIR/bin/lib/pr-record.sh" || exit 9
    stubs
    . "$DIR/bin/lib/prr-shadow.sh" || exit 9
    prr_seam_load merge-conductor || exit 8
    [ -n "${SNAP_ON:-}" ] && { _prs_on() { return 0; }; _prs_dir() { printf '%s/state/pr-snapshot/example-org_demo-os' "$HARNESS"; }; }
    gh_side() { echo gh >> "$W/gh.log"; cp "$3" "$1"; return "$4"; }
    prr_read merge-conductor "example-org/demo-os#$2" "$T/mo.out" "$3" gh_side mc_open_norm example-org/demo-os "$4" "$5"
    echo $? > "$T/rc" )
}
mkdir -p "$H/state/prr-default-branch"; echo main > "$H/state/prr-default-branch/example-org_demo-os"
printf '1\tfalse\n' > "$H/state/prr-default-branch/example-org_demo-os.cross"
jq -nc --arg h "$(hd 1)" '[{number:1, title:"t", html_url:"https://github.com/example-org/demo-os/pull/1", draft:false, body:"",
  created_at:"2026-11-27T07:00:00Z", updated_at:"2026-11-27T08:00:00Z", user:{login:"operator"},
  head:{ref:"ticket/bh-1", sha:$h, repo:{full_name:"example-org/demo-os"}}, base:{ref:"main", sha:$h, repo:{full_name:"example-org/demo-os"}}, labels:[]}]' > "$W/gh-open.json"
list 5000 "[$(lrow 1)]"; reset
mcl record open mc_open_record "$W/gh-open.json" 0
eq "M1 a stale list reads GitHub once" "$(cnt "$W/gh.log"):$(cat "$T/rc")" "1:0"
eq "M1 one list write-back" "$(cnt "$W/sync.log")" 1
eq "M1 at = the read's start" "$(jq -r '.at' "$W/sync.log" 2>/dev/null)" "$(date -u -d @1795770000 '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r 1795770000 '+%Y-%m-%dT%H:%M:%SZ')"
eq "M1 the rows" "$(jq -c '[.rows[].number] + [.state, .repo]' "$W/sync.log")" '[1,"open","example-org/demo-os"]'
list 10 "[$(lrow 1), $(lrow 4)]"; reset
mcl record open mc_open_record "$W/gh-open.json" 0
eq "M2 field:cross reads but writes no list" "$(cnt "$W/gh.log"):$(cnt "$W/sync.log")" "1:0"
list 5000 "[$(lrow 1)]"; reset
mcl record open mc_open_record "$W/gh-open.json" 1
eq "M3 a failed GitHub read writes nothing" "$(cnt "$W/sync.log")" 0
jq -c '[range(0; 100) as $i | .[0] | .number = (1 + $i)]' "$W/gh-open.json" > "$W/gh-100.json"; reset
mcl record open:100 mc_xe_record "$W/gh-100.json" 0
eq "M4 a full page of 100 is not the whole list" "$(cnt "$W/gh.log"):$(cnt "$W/sync.log")" "1:0"
reset
mcl record open:100 mc_xe_record "$W/gh-open.json" 0
eq "M4 a page of fewer than 100 is" "$(cnt "$W/sync.log")" 1
reset
mcl off open mc_open_record "$W/gh-open.json" 0
eq "M5 step off: one read, no write" "$(cnt "$W/gh.log"):$(cnt "$W/sync.log"):$(cnt "$W/jobs.log")" "1:0:0"
mkdir -p "$H/state/pr-snapshot/example-org_demo-os"; echo 1795769000 > "$H/state/pr-snapshot/example-org_demo-os/open.meta"; reset
SNAP_ON=1 mcl record open mc_open_record "$W/gh-open.json" 0
eq "M5 an older snapshot time is the at" "$(jq -r '.at' "$W/sync.log" 2>/dev/null)" "$(date -u -d @1795769000 '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r 1795769000 '+%Y-%m-%dT%H:%M:%SZ')"

# ── W1-W6: the wake sha lookup ────────────────────────────────────────────────
# wck <step> <lrepo> <sha>: wck_sha_prs once; the stub gh_rest_var answers
# $W/gh-commit-pulls.json and logs to $W/gh.log.
wck() {
  ( export HARNESS="$H" GH_SOURCE="$1" GH_SOURCE_LANE=wake-loop PR_RECORD_NOW=1795770000 PR_RECORD_LIST_MAX_AGE_S=900
    . "$DIR/bin/lib/pr-record.sh" || exit 9
    stubs
    gh_rest_var() { printf '%s\n' "$3" >> "$W/gh.log"; printf -v "$1" '%s' "$(cat "$W/gh-commit-pulls.json")"; }
    . "$DIR/bin/lib/wake-conductor-keys.sh" || exit 9
    wck_sha_prs "$2" "$3" > "$T/out"; echo $? > "$T/rc" )
}
SHA7=$(hd 7); SHA8=$(hd 8)
list 10 "[$(lrow 7), $(lrow 8)]"; reset; rm -f "$H/logs/prr-shadow.log"
wck record example-org/demo-os "$SHA7"
eq "W1 a PR event: the record names that PR only, 0 reads" "$(cat "$T/rc"):$(cat "$T/out"):$(cnt "$W/gh.log")" "0:example-org/demo-os#7:0"
MAIN=$(printf '%040x' 0xfeed)
mkdir -p "$H/state/pr-snapshot/example-org_demo-os"; printf '1795769000\t%s\n' "$MAIN" > "$H/state/pr-snapshot/example-org_demo-os/base-main"
wck record example-org/demo-os "$MAIN"
eq "W2 the base tip: none, 0 reads" "$(cat "$T/rc"):$(cat "$T/out"):$(cnt "$W/gh.log")" "1::0"
eq "W1-W2 quiet: no miss line" "$(cnt "$H/logs/prr-shadow.log")" 0
NEW=$(printf '%040x' 0xbeef)
jq -nc --arg h "$NEW" '[{number:12, state:"open", head:{sha:$h}}]' > "$W/gh-commit-pulls.json"
wck record example-org/demo-os "$NEW"
eq "W3 an unknown head reads GitHub once" "$(cat "$T/rc"):$(cat "$T/out"):$(cnt "$W/gh.log")" "0:example-org/demo-os#12:1"
eq "W3 its miss line" "$(cnt "$H/logs/prr-shadow.log" 'lane=wake-loop key=example-org/demo-os@[0-9a-f]*:sha why=field:head')" 1
list 5000 "[$(lrow 7)]"; reset
wck record example-org/demo-os "$SHA7"
eq "W4 a stale list reads GitHub" "$(cnt "$W/gh.log")" 1
echo '[]' > "$W/gh-commit-pulls.json"; reset; rm -f "$H/logs/prr-shadow.log"
wck record example-org/demo-os "$NEW"
eq "W5 GitHub none is rc 1" "$(cat "$T/rc"):$(cnt "$W/gh.log")" "1:1"
reset; rm -f "$H/logs/prr-shadow.log"; list 10 "[$(lrow 7)]"
jq -nc --arg h "$SHA7" '[{number:7, state:"open", head:{sha:$h}}]' > "$W/gh-commit-pulls.json"
wck off example-org/demo-os "$SHA7"
eq "W6 step off: today's read, no jobs call, no PRR line" "$(cat "$T/out"):$(cnt "$W/gh.log"):$(cnt "$W/jobs.log"):$([ -e "$H/logs/prr-shadow.log" ] && echo log || echo -)" "example-org/demo-os#7:1:0:-"

# ── Z1: no real host ──────────────────────────────────────────────────────────
eq "Z1 no real host" "$(grep -rhoE 'https?://[a-z0-9.-]+' "$W"/*.log 2>/dev/null | grep -v 'github.com/example-org/demo-os' | sort -u | tr '\n' ' ')" ""

echo "prr-read-on-change.bh-10351: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
