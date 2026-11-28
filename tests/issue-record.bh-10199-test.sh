#!/bin/bash
# tests/issue-record.bh-10199-test.sh — BH-10199 (slice 1): the issue record
# helper (bin/lib/issue-record.sh) and the two hold readers that read through
# it: hold_read (bin/lib/hold-push.sh, the resolver's br_hold_gate) and
# hold_check_thread (bin/lib/hold.sh, pr-state-reconcile's held fact).
#
#   S1  record, a ready record: hold_read makes 0 GitHub calls, the verdict is
#       the record's (held)
#   S2  record, no backfill stamp: a miss, 1 issue read + 1 comment page, then
#       1 PUT with the base rev the record read saw
#   S3  shadow, the record differs: the same 2 GitHub calls and the same
#       verdict as off, 1 PRR_SHADOW line, 1 PUT (write-back)
#   S3b shadow, the record is equal: no PRR_SHADOW line, no PUT
#   S4  off: 0 jobs calls, 2 GitHub calls
#   S5  shadow and record, the jobs read fails (unknown): no PUT, the verdict
#       is GitHub's
#   S6  record miss, GitHub fails: no PUT, the verdict is unreadable (rc 2)
#   S7  hold_check_thread, record hit: 0 GitHub calls, the same verdict
#   S7b hold_check_thread, record miss: 1 comment page, a PUT with issue null
#   S8  issue_record_sync: not due = 0 GitHub calls; due = 1 list read and 1
#       POST with the claim's started; a failed list read = 0 POST
#   S9  the resolver fragment: GH_SOURCE_ISSUES=record sets IRR_LANE and the
#       step; off, or the lane's GH_SOURCE off, sets nothing; no libs on the
#       box sets no variable (blocked-resolver-frags F1)
#   S10 the record answer is in the hold shape: labels as objects, a bot
#       author is user.type Bot (and the classifier skips it)
#   S11 a truncated record is a miss (1 GitHub read)
#   S12 no IRR_LANE: today's calls, 0 jobs calls
#   S13 the fixture tick: 10 tickets, GitHub calls per step (the PR body table)
#   S14 (review of #10343) the box-local claim skip: no claim POST for a repo
#       inside the worker's every_s after this box's last claim (IRR_NOW, a
#       fixture epoch); a failed claim writes no marker
#
# No vendor is called (BH-7563): gh_rest is a local stub that answers fixture
# JSON and logs every call; the jobs worker is a stub _jobs_req; gh is a stub
# that fails. Fixture times only; no clock read, no sleep.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/issue-record.bh-10199-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$3] got [$2]"; fi; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; mkdir -p "$H/logs" "$H/bin" "$T/fakebin" "$T/tmp"
export HARNESS="$H" TMPDIR="$T/tmp"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ghcli.txt"\nexit 1\n' "$T" > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"; export PATH="$T/fakebin:$PATH"

# The libs under test, from the checkout.
# shellcheck source=bin/lib/hold.sh
. "$DIR/bin/lib/hold.sh" || exit 1
# shellcheck source=bin/lib/hold-push.sh
. "$DIR/bin/lib/hold-push.sh" || exit 1
# shellcheck source=bin/lib/prr-shadow.sh
. "$DIR/bin/lib/prr-shadow.sh" || exit 1
# shellcheck source=bin/lib/issue-record.sh
. "$DIR/bin/lib/issue-record.sh" || exit 1

# THE GITHUB STUB. $T/gh-fail = every read fails (rc 75, status 502).
gh_rest() {
  printf '%s %s\n' "$1" "$2" >> "$T/gh.txt"
  [ -f "$T/gh-fail" ] && { GH_REST_STATUS=502; return 75; }
  GH_REST_STATUS=200
  case "$2" in
    repos/o/r/issues/*/comments*) cat "$T/gh-comments.json" ;;
    repos/o/r/issues/[0-9]*) jq -c --argjson n "${2##*/}" '. + {number: $n}' "$T/gh-issue.json" ;;
    "repos/o/r/issues?"*) cat "$T/gh-list.json" ;;
    *) GH_REST_STATUS=404; return 44 ;;
  esac
  return 0
}
# THE JOBS STUB. $T/rec.json answers the GET (absent = a failed read);
# $T/claim.json the claim. PUT and POST bodies land in put.json / sync.json.
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$T/jobs.txt"
  case "$1 $2" in
    "GET /api/issue-records?"*) [ -f "$T/rec.json" ] && { cat "$T/rec.json"; return 0; }; return 1 ;;
    "PUT /api/issue-records") printf '%s\n' "$3" >> "$T/put.json"; echo '{"applied":true,"rev":9}'; return 0 ;;
    "POST /api/issue-record-syncs/claim") [ -f "$T/claim.json" ] && { cat "$T/claim.json"; return 0; }; return 1 ;;
    "POST /api/issue-record-syncs") printf '%s\n' "$3" > "$T/sync.json"; echo '{"written":0}'; return 0 ;;
  esac
  return 1
}

AT1='2026-11-27T04:00:00Z'; AT2='2026-11-27T05:00:00Z'
printf '{"state":"open","title":"T","body":"b","labels":[{"name":"ai-build"}],"updated_at":"%s"}\n' "$AT2" > "$T/gh-issue.json"
gh_comments() { # <body> — one comment by a person
  jq -nc --arg b "$1" --arg a "$AT1" '[{id: 11, body: $b, created_at: $a, updated_at: $a, user: {login: "operator", type: "User"}}]' > "$T/gh-comments.json"
}
rec() { # <why|null> <comment body> [author_type] [rev]
  jq -nc --arg w "$1" --arg b "$2" --arg ty "${3:-User}" --argjson rv "${4:-3}" --arg a1 "$AT1" --arg a2 "$AT2" '{
    row: {rev: $rv, state: "open", title: "T", body: "b", labels: ["ai-build"], gh_updated_at: $a2},
    comments: [{comment_id: 11, author: "operator", author_type: $ty, gh_created_at: $a1, gh_updated_at: $a1, body: $b, truncated: 0}],
    why: (if $w == "null" then null else $w end), sync: {synced_at: $a2, mark: $a2, age_s: 10}}' > "$T/rec.json"
}
reset() { scratch_rm "$H/state/issue-record-claim"; rm -f "$T"/gh.txt "$T"/jobs.txt "$T"/put.json "$T"/sync.json "$T"/gh-fail "$T"/ghcli.txt "$H/logs/prr-shadow.log"
  echo '{"due":false}' > "$T/claim.json"; gh_comments HOLD; rec null HOLD; }
cnt()    { if [ -f "$2" ]; then grep -cF -- "$1" "$2"; else echo 0; fi; }
n_gh()   { cnt '' "$T/gh.txt"; }
n_jobs() { cnt "${1:-}" "$T/jobs.txt"; }
n_put()  { cnt '' "$T/put.json"; }
n_log()  { cnt "$1" "$H/logs/prr-shadow.log"; }
verdict() { cut -f1 <<<"$1"; }

# ── S1 record hit ──────────────────────────────────────────────────────────
reset; IRR_LANE=blocked-resolver; IRR_STEP=record
out=$(hold_read o/r 5); rc=$?
eq "S1 rc" "$rc" 1; eq "S1 verdict" "$(verdict "$out")" held
eq "S1 GitHub calls" "$(n_gh)" 0
eq "S1 jobs GET" "$(n_jobs 'GET /api/issue-records')" 1
eq "S1 no PUT" "$(n_put)" 0

# ── S2 record miss: no backfill ────────────────────────────────────────────
reset; rec no-backfill HOLD 1 3; IRR_STEP=record
out=$(hold_read o/r 5); rc=$?
eq "S2 verdict" "$(verdict "$out")" held
eq "S2 GitHub calls" "$(n_gh)" 2
eq "S2 PRR_MISS" "$(n_log 'PRR_MISS lane=blocked-resolver key=o/r#5@thread why=no-backfill fallback=github')" 1
eq "S2 PUT count" "$(n_put)" 1
eq "S2 PUT base rev" "$(jq -r '.base_rev' "$T/put.json" 2>/dev/null)" 3
eq "S2 PUT shape" "$(jq -c '[.number, .issue.state, (.comments | length), .comments[0].user.type]' "$T/put.json" 2>/dev/null)" '[5,"open",1,"User"]'

# ── S3 shadow, the record differs ──────────────────────────────────────────
reset; rec null "all good"; IRR_STEP=shadow
out=$(hold_read o/r 5); rc=$?
IRR_STEP=off; reset; off_out=$(hold_read o/r 5); off_rc=$?; off_gh=$(n_gh)
reset; rec null "all good"; IRR_STEP=shadow
out=$(hold_read o/r 5); rc=$?
eq "S3 verdict = off" "$out|$rc" "$off_out|$off_rc"
eq "S3 GitHub calls = off" "$(n_gh)" "$off_gh"
eq "S3 PRR_SHADOW" "$(n_log 'PRR_SHADOW lane=blocked-resolver key=o/r#5@thread')" 1
eq "S3 write-back" "$(n_put)" 1

# ── S3b shadow, the record is equal ────────────────────────────────────────
reset; IRR_STEP=shadow
out=$(hold_read o/r 5)
eq "S3b verdict" "$(verdict "$out")" held
eq "S3b PRR_SHADOW" "$(n_log PRR_SHADOW)" 0
eq "S3b no PUT" "$(n_put)" 0
eq "S3b GitHub calls" "$(n_gh)" 2

# ── S4 off ─────────────────────────────────────────────────────────────────
reset; IRR_STEP=off
out=$(hold_read o/r 5)
eq "S4 jobs calls" "$(n_jobs)" 0; eq "S4 GitHub calls" "$(n_gh)" 2; eq "S4 verdict" "$(verdict "$out")" held

# ── S5 the jobs read fails: unknown, no write ──────────────────────────────
for step in shadow record; do
  reset; rm -f "$T/rec.json"; IRR_STEP=$step
  out=$(hold_read o/r 5)
  eq "S5 $step verdict" "$(verdict "$out")" held
  eq "S5 $step no PUT" "$(n_put)" 0
  eq "S5 $step GitHub calls" "$(n_gh)" 2
  eq "S5 $step PRR_MISS unreadable" "$(n_log 'why=unreadable')" 1
done

# ── S6 record miss, GitHub fails ───────────────────────────────────────────
reset; rec no-backfill HOLD; : > "$T/gh-fail"; IRR_STEP=record
out=$(hold_read o/r 5); rc=$?
eq "S6 rc" "$rc" 2; eq "S6 verdict" "$(verdict "$out")" unreadable; eq "S6 no PUT" "$(n_put)" 0

# ── S7 hold_check_thread through the record ────────────────────────────────
reset; IRR_LANE=pr-state-reconcile; IRR_STEP=record
out=$(hold_check_thread o/r 7); rc=$?
eq "S7 verdict" "$(verdict "$out")|$rc" "held|1"; eq "S7 GitHub calls" "$(n_gh)" 0
IRR_STEP=off; reset; off_out=$(hold_check_thread o/r 7); off_rc=$?
eq "S7 = off" "$out|$rc" "$off_out|$off_rc"
reset; rec stale HOLD 1 4; IRR_STEP=record
out=$(hold_check_thread o/r 7)
eq "S7b GitHub calls" "$(n_gh)" 1
eq "S7b PUT" "$(jq -c '[.base_rev, .issue, (.comments | length)]' "$T/put.json" 2>/dev/null)" '[4,null,1]'
eq "S7b PRR_MISS" "$(n_log 'key=o/r#7@comments why=stale')" 1

# ── S8 the list backstop ───────────────────────────────────────────────────
reset
issue_record_sync o/r; eq "S8 not due rc" "$?" 0; eq "S8 not due GitHub" "$(n_gh)" 0
scratch_rm "$H/state/issue-record-claim"
printf '{"due":true,"since":"%s","started":"%s","pages_max":5}\n' "$AT1" "$AT2" > "$T/claim.json"
jq -nc --arg a "$AT2" '[{number: 5, state: "open", title: "T", body: "b", labels: [{name: "hold"}], updated_at: $a},
                        {number: 6, state: "closed", title: "P", body: null, labels: [], updated_at: $a, pull_request: {url: "x"}}]' > "$T/gh-list.json"
issue_record_sync o/r; eq "S8 due rc" "$?" 0
Q="issues?state=all&since=$AT1&sort=updated&direction=asc&per_page=100&page=1"  # determinism: ok since= is a fixture GitHub mark, not a clock window
eq "S8 one list read" "$(grep -cF "$Q" "$T/gh.txt")" 1
eq "S8 POST" "$(jq -c '[.repo, .started, .mark, .complete, (.items | length), .items[1].pull_request, .items[0].labels[0].name]' "$T/sync.json" 2>/dev/null)" "[\"o/r\",\"$AT2\",\"$AT2\",true,2,{},\"hold\"]"
reset; printf '{"due":true,"since":"%s","started":"%s","pages_max":5}\n' "$AT1" "$AT2" > "$T/claim.json"; : > "$T/gh-fail"
issue_record_sync o/r; eq "S8 failed rc" "$?" 1; eq "S8 failed no POST" "$([ -f "$T/sync.json" ] && echo yes || echo no)" no

# ── S14 the box-local claim skip (review of #10343) ────────────────────────
reset; export IRR_NOW=1800000000
echo '{"due":false,"every_s":600}' > "$T/claim.json"
issue_record_sync o/r
eq "S14 first claim" "$(n_jobs 'POST /api/issue-record-syncs/claim')" 1
eq "S14 marker" "$(cat "$H/state/issue-record-claim/o_r" 2>/dev/null)" "1800000000	600"
IRR_NOW=1800000599 issue_record_sync o/r
eq "S14 inside every_s: no claim" "$(n_jobs 'POST /api/issue-record-syncs/claim')" 1
IRR_NOW=1800000600 issue_record_sync o/r
eq "S14 at every_s: claims again" "$(n_jobs 'POST /api/issue-record-syncs/claim')" 2
IRR_NOW=1800000601; IRR_LANE=blocked-resolver; IRR_STEP=shadow
hold_read o/r 5 >/dev/null; hold_read o/r 5 >/dev/null
eq "S14 two reads, no new claim" "$(n_jobs 'POST /api/issue-record-syncs/claim')" 2
reset; rm -f "$T/claim.json"
issue_record_sync o/r
eq "S14 a failed claim writes no marker" "$([ -e "$H/state/issue-record-claim/o_r" ] && echo yes || echo no)" no
unset IRR_NOW

# ── S9 the resolver fragment ───────────────────────────────────────────────
for L in bin/lib/issue-record.sh bin/lib/prr-shadow.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
FR="$DIR/bin/blocked-resolver.d/bh-10199-issue-record.sh"
got=$(H="$H" GH_SOURCE_ISSUES=record bash -c '. "$1"; printf "%s|%s" "$IRR_LANE" "$IRR_STEP"' _ "$FR")
eq "S9 record" "$got" "blocked-resolver|record"
got=$(H="$H" GH_SOURCE_ISSUES=off bash -c '. "$1"; printf "%s|%s" "$IRR_LANE" "$IRR_STEP"' _ "$FR")
eq "S9 off" "$got" "|"
got=$(H="$H" GH_SOURCE=off GH_SOURCE_ISSUES=record bash -c '. "$1"; printf "%s|%s" "$IRR_LANE" "$IRR_STEP"' _ "$FR")
eq "S9 GH_SOURCE off turns it off" "$got" "|"
got=$(H="$T/nolibs" GH_SOURCE_ISSUES=record bash -c 'before=$(compgen -v | sort); . "$1"; comm -13 <(printf "%s\n" "$before") <(compgen -v | grep -vx before | sort) | grep -vE "^(BASH_.*|PIPESTATUS|_)$" | paste -sd" " -' _ "$FR")
eq "S9 no libs: no variable set" "$got" ""
got=$(H="$H" bash -c 'unset GH_SOURCE_ISSUES; . "$1"; printf "%s|%s" "$IRR_LANE" "$(irr_step)"' _ "$FR")
eq "S9 default shadow" "$got" "blocked-resolver|shadow"

# ── S10 the record answer is in the hold shape ─────────────────────────────
reset; rec null HOLD Bot
issue_record_peek o/r 5 "$T/peek.json" >/dev/null; eq "S10 rc" "$?" 0
eq "S10 shape" "$(jq -c '[.issue.labels, .comments[0].user.type, .comments[0].id]' "$T/peek.json")" '[[{"name":"ai-build"}],"Bot",11]'
IRR_LANE=blocked-resolver; IRR_STEP=record
out=$(hold_read o/r 5)
eq "S10 a bot's HOLD is not a hold" "$(verdict "$out")" clear

# ── S11 truncated is a miss ────────────────────────────────────────────────
reset; rec truncated HOLD; IRR_STEP=record
out=$(hold_read o/r 5)
eq "S11 GitHub calls" "$(n_gh)" 2; eq "S11 PRR_MISS" "$(n_log 'why=truncated')" 1

# ── S12 no IRR_LANE: today's reads ─────────────────────────────────────────
reset; IRR_LANE=""; IRR_STEP=record
out=$(hold_read o/r 5); out2=$(hold_check_thread o/r 7)
eq "S12 jobs calls" "$(n_jobs)" 0; eq "S12 GitHub calls" "$(n_gh)" 3
eq "S12 verdicts" "$(verdict "$out")|$(verdict "$out2")" "held|held"

# ── S13 the fixture tick: 10 tickets, one sync due ─────────────────────────
tick() { # <step> <why> — GitHub calls of 10 hold_read calls with one due sync
  reset; rec "$2" HOLD; IRR_LANE=blocked-resolver; IRR_STEP=$1
  printf '{"due":true,"since":"%s","started":"%s","pages_max":5}\n' "$AT1" "$AT2" > "$T/claim.json"
  echo '[]' > "$T/gh-list.json"
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do
    hold_read o/r "$i" >/dev/null
    echo '{"due":false}' > "$T/claim.json"
  done
  n_gh
}
OFF=$(tick off null); SH=$(tick shadow null); RH=$(tick record null); RM=$(tick record no-backfill)
eq "S13 off" "$OFF" 20; eq "S13 shadow" "$SH" 21; eq "S13 record, all hits" "$RH" 1; eq "S13 record, all misses" "$RM" 21
echo "S13 fixture tick, 10 tickets: GitHub calls off=$OFF shadow=$SH record-hit=$RH record-miss=$RM"

echo "issue-record.bh-10199: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
