#!/bin/bash
# tests/unblock-record.bh-10158-test.sh — BH-10158 (BH-9926 wave 5, slice C2
# of #9937): the unblock lane on the PR record, driven through the SHIPPED
# entry point `bin/unblock.sh tick --project cromford` with the REAL
# collectors (bin/lib/unblock/collectors/*.sh), the real ticket PR resolve
# (bin/lib/unblock/ticket-pr.sh), the real seam and the real wake gate.
#
#   L1   step record: tick 1 fills the caches; tick 2, one minute later, no
#        wake: 0 GitHub calls, and the records equal tick 1's
#   L2   one pr wake for #3 (a lead BLOCK PR): tick 3's GitHub calls all name
#        #3, and there is at least 1; L2b the same wake again: the same reads
#        and records (a repeated wake gives the same result)
#   L3   step shadow, the record's CR set adds #5 (GitHub's search lacks it):
#        exactly 1 PRR_SHADOW lane=unblock key=<repo>#cr line, and no
#        stale-change-request record for #5 (the lane acted on GitHub)
#   L4   step off: 0 /api/pr-records calls; the GitHub calls equal shadow's
#   L5   step record, a stale record list: PRR_MISS ...#open@review why=stale
#        fallback=github and ...#open@queue..., 1 open-list GitHub read per site
#   L6   step record, the comments read of #3 fails on tick 1: no cache file
#        for it, and tick 2 reads issues/3/comments again
#   L7   step record, caches older than UNBLOCK_PRR_BACKSTOP_S: every gated
#        read runs again
#   L8   step record: the lifecycle ticket's PR and the ticket branch PR are in
#        the record: 0 pulls/<n> and 0 pulls?state=open&head= GitHub calls,
#        and the plan_blocked ticket's record carries has_pr true with the
#        record's head
#   L9   no GH_SOURCE and no settings row: the tick runs shadow (/api/pr-records
#        calls > 0) and its GitHub calls equal L4's
#   L10  step record, a pr wake for #99 (not open): the closed list is read
#        again and every per-PR cache is served
#   EQ   the records of a record-step tick equal an off-step tick's on the
#        fields the rules read
#   B    budget (BH-7563): 0 curl and 0 gh CLI calls; no bin/lane-alert.sh call
#
# STUBS (UNBLOCK_FIXTURE, sourced by the tick in the sandbox): gh_rest logs
# each call to $FXT/gh-calls.txt and answers from $FXT/prs.json; _jobs_req is
# the jobs worker (settings, /api/pr-records list and rows, verdicts,
# lead-reviews, artifacts, lifecycle history) and logs to $FXT/jobs.log;
# vd_standing, lifecycle_stuck, setting_get, the lane gate and lane_env_apply
# are functions; ub_rules_eval captures the records the collectors printed
# and decides nothing. The wake feed is the real prs_wake_seen on a seeded
# changed.tsv and wakes.state; the gate clock is WAKE_BACKSTOP_NOW.
#
# FIXTURE: 10 open PRs. #3 #4 a standing lead BLOCK; #5 #6 MERGE with a CR in
# the change-requested set; #7 #8 MERGE, approved idle with green checks; #1
# #2 #9 #10 plain (nothing stands). #10's branch is ticket/bh-20. Lifecycle:
# BH-7 ejected with PR #7, BH-20 plan_blocked with no PR. No failed batch.
#
# MUTATIONS (D1), each tried once by hand: ubp_cached always runs the cmd ->
# L1 red; ubp_cached writes the cache before the cmd -> L6 red; prr_read acts
# on the record in shadow -> L3 red.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/unblock-record.bh-10158-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
cnt() { if [ -f "$2" ]; then grep -c -- "$1" "$2"; else echo 0; fi; }

[ -r "$REPO/bin/unblock.sh" ] || { echo "FAIL: missing bin/unblock.sh"; echo "unblock-record.bh-10158: 0 passed, 1 failed"; exit 1; }

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"; FXT="$T/fx"; FB="$T/fakebin"
mkdir -p "$H/bin" "$H/env" "$FB" "$FXT" || exit 1
: > "$H/env/global.env"
printf 'cromford example-org/cromford - - 3 hub 192.0.2.10\n' > "$H/fleet.conf"
for S in bin/unblock.sh bin/fleet-conf.sh bin/jobs-client.sh bin/lib/unblock/collectors/queue.sh \
         bin/lib/unblock/collectors/review.sh bin/lib/unblock/collectors/lifecycle.sh \
         bin/lib/unblock/collectors/infra.sh bin/lib/wake-backstop.sh bin/lib/pr-snapshot.sh; do
  ( cd "$REPO" && scratch_install_closure "$S" "$H" ) >/dev/null || { echo "setup: closure $S"; exit 1; }
done
for f in bin/lib/unblock/prr.sh bin/lib/prr-shadow.sh bin/lib/prr-shadow.d/unblock.sh bin/lib/pr-record.sh \
         bin/lib/prr-ci-state.sh bin/lib/pr-snapshot-wakes.sh bin/lib/unblock/ticket-pr.sh; do
  [ -f "$H/$f" ] || bad "setup: the closure lacks $f"
done
rm -f "$H/bin/lane-alert.sh"
printf '#!/bin/bash\nprintf "ALERT %%s\\n" "$*" >> "%s/alerts.log"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
for b in curl gh; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/net.log"\nexit 7\n' "$b" "$T" > "$FB/$b"
  chmod +x "$FB/$b"
done
"$REPO/bin/lanes-build.sh" --root "$REPO" --to "$T/lanes.json" >/dev/null 2>&1 && [ -s "$T/lanes.json" ] \
  || { echo "FAIL: bin/lanes-build.sh could not compose the registry"; echo "unblock-record.bh-10158: 0 passed, 1 failed"; exit 1; }

SLUG=example-org/cromford
SD="$H/state/pr-snapshot/example-org_cromford"
CACHE="$H/state/unblock-prr/example-org_cromford"
# The PRs: number, head, branch, standing verdict ("" = none), CR in the set.
jq -n '
  [range(1; 11) | . as $n | {n: $n, head: ("0123456789abcdef"[($n % 16):($n % 16 + 1)] * 40),
    ref: (if $n == 10 then "ticket/bh-20" else "feature/pr-\($n)" end),
    verdict: (if $n == 3 or $n == 4 then "BLOCK" elif $n >= 5 and $n <= 8 then "MERGE" else "" end),
    cr: ($n == 5 or $n == 6)}]' > "$FXT/prs.json"
# GitHub's change-requested search; L3 removes #5 from it.
jq -c '{incomplete_results: false, items: [.[] | select(.cr) | {number: .n}]}' "$FXT/prs.json" > "$FXT/search.base.json"

cat > "$T/fx.sh" <<'SH'
_fx_pr() { jq -c --argjson n "$1" '.[] | select(.n == $n)' "$FXT/prs.json"; }
setting_get() {
  printf 'SETTING %s\n' "$1" >> "$FXT/seq.log"
  case "$1" in
    unblock.enabled) echo 1 ;;
    *) [ -f "$FXT/settings/$1" ] && { cat "$FXT/settings/$1"; return 0; }; return 2 ;;
  esac
}
lane_gate_or_exit() { return 0; }
lane_env_apply() { return 0; }
lane_role_model() { return 1; }
ub_rules_eval() { cat >> "$FXT/records.jsonl"; }
vd_standing() { # <slug> <n> <head>: word \t - \t - \t created_at; rc 1 none
  local v; v=$(_fx_pr "$2" | jq -r .verdict)
  [ -n "$v" ] || return 1
  printf '%s\tlead\t-\t2026-11-25T10:00:00Z\n' "$v"
}
lifecycle_stuck() {
  printf '%s\n' '{"rows":[{"project":"cromford","ticket_key":"BH-7","phase":"ejected","phase_at":"2026-11-25T09:00:00Z","age_min":300,"threshold_min":60,"phase_actor":"merge-queue","pr":7},
    {"project":"cromford","ticket_key":"BH-20","phase":"plan_blocked","phase_at":"2026-11-25T09:30:00Z","age_min":2000,"threshold_min":1440,"phase_actor":"plan","question":"which?"}]}'
}
_jobs_req() {
  local q="$2" n age
  printf '%s %s\n' "$1" "$2" >> "$FXT/jobs.log"
  case "$1 $q" in
    "GET /api/pr-records?"*number=*)
      n=${q##*number=}
      _fx_pr "$n" | jq -c '{row: {repo: "example-org/cromford", number: .n, state: "open", draft: 0, head_sha: .head,
          head_ref: .ref, base_ref: "main", labels: [], mergeable_state: "clean", url: "https://github.com/example-org/cromford/pull/\(.n)",
          checks: {"ci / test": {status: "completed", conclusion: "success", sha: .head, at: "2026-11-25T09:00:00Z"}},
          files: {sha: .head, paths: ["bin/x-\(.n).sh"]}, head_commit: {sha: .head, at: "2026-11-25T08:00:00Z"}}, age_s: 30}' ;;
    "GET /api/pr-records?"*state=open*)
      age=10; [ -f "$FXT/list-stale" ] && age=99999
      jq -c --argjson age "$age" --slurpfile s "$FXT/search.record.json" '
        {rows: [.[] | {number: .n, title: "t", head_ref: .ref, head_sha: .head, base_ref: "main", author: "u", labels: [], body: "",
          mergeable_state: "clean", updated_at: "2026-11-25T00:00:00Z", created_at: ("2026-11-\(10 + .n)T00:00:00Z"),
          url: "https://github.com/example-org/cromford/pull/\(.n)", draft: 0, merged_at: null,
          reviews: (.n as $n | if any($s[0].items[]; .number == $n) then {lead: {state: "CHANGES_REQUESTED"}} else {} end)}],
         truncated: false, sync: {age_s: $age, synced_at: "2026-11-25T23:59:00Z"}, missing: null, unknown: 0}' "$FXT/prs.json" ;;
    "GET /api/verdicts?"*head=*)
      n=${q#*&pr=}; n=${n%%&*}
      _fx_pr "$n" | jq -c 'if .verdict == "" then {standing: null}
        else {standing: {verdict: .verdict, source: "lead", note: "lead-job:job-\(.n)", id: (100 + .n), created_at: "2026-11-25T10:00:00Z"}} end' ;;
    "GET /api/verdicts?"*) echo '{"rows":[]}' ;;
    "GET /api/jobs/"*/artifacts)
      jq -nc '{artifacts: [{artifact_kind: "lead_review_report", detail: ({body: "## Review\n- [BLOCK wrong-data] a value is wrong\n", truncated: false} | tojson)}]}' ;;
    "GET /api/lead-reviews?"*) echo '{"requests":[],"truncated":false}' ;;
    "GET /api/lifecycle/history"*) echo '{"events":[]}' ;;
    "GET /api/settings"*) echo '{"settings":[]}' ;;
    *) return 1 ;;
  esac
}
gh_rest() {
  local p="$2" n
  printf '%s\n' "$*" >> "$FXT/gh-calls.txt"
  GH_REST_STATUS=200
  case "$p" in
    repos/*/pulls\?state=open\&per_page=100)
      jq -c '[.[] | {number: .n, state: "open", draft: false, head: {sha: .head, ref: .ref}, labels: [], html_url: "https://github.com/example-org/cromford/pull/\(.n)", updated_at: "x"}]' "$FXT/prs.json" ;;
    repos/*/pulls\?state=open\&head=*)
      n=${p#*head=*:}; n=${n%%&*}
      jq -c --arg b "$n" '[.[] | select(.ref == $b) | {number: .n, head: {sha: .head, ref: .ref}, html_url: "https://github.com/example-org/cromford/pull/\(.n)", updated_at: "x"}]' "$FXT/prs.json" ;;
    repos/*/pulls\?state=closed*) echo '[]' ;;
    search/issues*) cat "$FXT/search.json" ;;
    repos/*/pulls/*/reviews*)
      n=${p#repos/*/pulls/}; n=${n%%/*}
      _fx_pr "$n" | jq -c 'if .cr then [{id: 9, state: "CHANGES_REQUESTED", commit_id: ("0" * 40), body: "<!-- review-verdict:block x -->", user: {login: "lead"}, submitted_at: "2026-11-24T00:00:00Z"}] else [] end' ;;
    repos/*/issues/*/comments*)
      n=${p#repos/*/issues/}; n=${n%%/*}
      [ -f "$FXT/comments-fail-$n" ] && { rm -f "$FXT/comments-fail-$n"; GH_REST_STATUS=502; return 75; }
      echo '[]' ;;
    repos/*/pulls/*/files*) n=${p#repos/*/pulls/}; n=${n%%/*}; printf '[{"filename":"bin/x-%s.sh"}]\n' "$n" ;;
    repos/*/commits/*/check-runs*) echo '{"total_count":1,"check_runs":[{"status":"completed","conclusion":"success"}]}' ;;
    repos/*/commits/*) echo '{"commit":{"committer":{"date":"2026-11-25T08:00:00Z"}}}' ;;
    repos/*/pulls/*)
      n=${p##*/}
      _fx_pr "$n" | jq -c '{number: .n, state: "open", merged: false, merge_commit_sha: null, head: {sha: .head, ref: .ref}, base: {ref: "main"}, labels: [], mergeable_state: "clean", html_url: "https://github.com/example-org/cromford/pull/\(.n)", draft: false}' \
        || { GH_REST_STATUS=404; return 44; } ;;
    *) GH_REST_STATUS=404; return 44 ;;
  esac
}
SH

NOWR=$(date +%s)  # determinism: ok the real prs_wake_seen reads the box clock; the gate clock is pinned to it
UNOW=1795000000
# feed [kind:key:at]... — the mirror the real prs_wake_seen reads
feed() {
  local r k y a i=100
  scratch_rm "$SD"; mkdir -p "$SD"
  printf '%s\t1\t1\t%s\n' "$NOWR" "$((NOWR - 7200))" > "$SD/wakes.state"
  echo 500 > "$SD/wakes.wm"; : > "$SD/changed.tsv"
  for r in "$@"; do
    IFS=: read -r k y a <<<"$r"; i=$((i + 1))
    printf '%s\t%s\t%s\t%s\n' "$k" "$y" "$i" "$a" >> "$SD/changed.tsv"
  done
}
modes() {
  mkdir -p "$H/state"
  jq -nc --argjson fa "$UNOW" '{fetched_at: $fa, values: {"unblock.project.cromford.mode": "shadow"}, seeded: {}}' > "$H/state/settings-cache.json"
}
reset() {
  local d
  for d in "$H/state" "$H/logs" "$H/locks" "$T/net.log" "$T/alerts.log"; do scratch_rm "$d" || exit 1; done
  rm -f "$FXT"/*.log "$FXT"/*.txt "$FXT"/records.jsonl "$FXT"/list-stale "$FXT"/comments-fail-*
  cp "$FXT/search.base.json" "$FXT/search.json"; cp "$FXT/search.base.json" "$FXT/search.record.json"
  modes; feed
}
# tick <offset-s> [VAR=val...] — the shipped entry point; the gate clock is NOWR + offset.
# Each tick starts with empty call logs.
tick() {
  local off="$1"; shift
  rm -f "$FXT/gh-calls.txt" "$FXT/jobs.log" "$FXT/records.jsonl" "$FXT/seq.log"
  env -u GH_SOURCE HARNESS="$H" FXT="$FXT" UNBLOCK_FIXTURE="$T/fx.sh" HARNESS_TEST_SANDBOX=1 \
    LANE_GATE_DISABLE=1 LANE_GATE_NOW=$UNOW LANE_GATE_CACHE_S=60 UNBLOCK_TIMED=1 JOBS_URL= HARNESS_SECRET= \
    UNBLOCK_NOW=$UNOW WAKE_BACKSTOP_NOW=$((NOWR + off)) PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=600 \
    LANE_REGISTRY="$T/lanes.json" PATH="$FB:$PATH" "$@" \
    bash "$H/bin/unblock.sh" tick --project cromford >"$T/out.txt" 2>&1
  echo $? > "$T/rc"
}
gh_calls() { if [ -f "$FXT/gh-calls.txt" ]; then grep -cvE 'rate_limit|auth token' "$FXT/gh-calls.txt"; else echo 0; fi; }
recs() { jq -cS 'select(.kind != null)' "$FXT/records.jsonl" 2>/dev/null | sort; }
# The fields the rules read, per record.
proj() { jq -cS '{kind, subject, pr, head, mergeable_state, checks, changes_requested_open, touches_tests, labels,
  has_pr, cr_on_head, findings_comment_on_head, block_lines, pr_state, merged, review_id}' "$FXT/records.jsonl" 2>/dev/null | sort; }
shadow_log="$H/logs/prr-shadow.log"

# ═════ L1: record, a quiet tick makes 0 GitHub calls ══════════════════════════
reset
tick 0 GH_SOURCE=record
eq "L1 tick 1 rc" "$(cat "$T/rc")" 0
grep -q 'tick cromford mode=shadow collectors=4 ' "$H/logs/unblock.log" && ok || bad "L1 tick 1 runs the 4 real collectors: $(tail -3 "$H/logs/unblock.log" 2>/dev/null) $(head -c 600 "$T/out.txt")"
R1=$(recs); G1=$(gh_calls)
[ "$G1" -gt 0 ] && ok || bad "L1 tick 1 must read the gated inputs from GitHub (got $G1 calls)"
eq "L1 tick 1 kinds" "$(jq -r .kind "$FXT/records.jsonl" | sort | uniq -c | awk '{print $2"="$1}' | grep -E '^(lead-block-unrouted|stale-change-request|pr-approved-idle|ticket-)' | tr '\n' ' ')" \
  "lead-block-unrouted=2 pr-approved-idle=4 stale-change-request=2 ticket-ejected=1 ticket-plan-blocked=1 "
[ -s "$CACHE/3-reviews.json" ] && [ -s "$CACHE/3-comments.json" ] && [ -s "$CACHE/repo-closed-list.json" ] && ok \
  || bad "L1 tick 1 fills the caches: $(ls "$CACHE" 2>/dev/null | tr '\n' ' ')"
cp "$FXT/records.jsonl" "$T/rec-record.jsonl"
tick 60 GH_SOURCE=record
eq "L1 tick 2 rc" "$(cat "$T/rc")" 0
eq "L1 tick 2, no wake: GitHub calls" "$(gh_calls)" 0
[ "$(gh_calls)" = 0 ] || sed 's/^/  gh: /' "$FXT/gh-calls.txt"
eq "L1 tick 2 records equal tick 1's" "$(recs)" "$R1"
eq "L1 no alert" "$(cnt . "$T/alerts.log")" 0

# ═════ L2: one pr wake for #3 reads only #3 ═══════════════════════════════════
feed "pr:3:$((NOWR + 90))"
tick 120 GH_SOURCE=record
G=$(gh_calls)
[ "$G" -ge 1 ] && ok || bad "L2 the wake of #3 reads #3 (got 0 calls)"
eq "L2 every per-PR GitHub call names #3" "$(grep -vE 'pulls\?state=closed' "$FXT/gh-calls.txt" | grep -cvE 'pulls/3/|issues/3/')" 0
eq "L2 plus the one repo-wide closed list (a pr wake of any PR makes it due)" "$(cnt 'pulls?state=closed' "$FXT/gh-calls.txt")" 1
grep -q 'pulls/3/reviews' "$FXT/gh-calls.txt" && grep -q 'issues/3/comments' "$FXT/gh-calls.txt" && ok \
  || bad "L2 #3's reviews and comments are read: $(cat "$FXT/gh-calls.txt")"
eq "L2 records unchanged" "$(recs)" "$R1"
cp "$FXT/gh-calls.txt" "$T/l2-calls.txt"
# L2b the same wake replayed onto a fresh per-PR cache: the same reads, the same
# records (the closed list was read after the wake, so it is served now)
rm -f "$CACHE"/3-*
tick 120 GH_SOURCE=record
eq "L2b a repeated wake: the same per-PR GitHub reads" "$(grep -v 'state=closed' "$FXT/gh-calls.txt" | sort)" "$(grep -v 'state=closed' "$T/l2-calls.txt" | sort)"
eq "L2b a repeated wake: the same records" "$(recs)" "$R1"

# ═════ L3: shadow, a forced mismatch on the CR set ════════════════════════════
reset
jq -c '.items |= map(select(.number != 5))' "$FXT/search.base.json" > "$FXT/search.json"
tick 0 GH_SOURCE=shadow
eq "L3 rc" "$(cat "$T/rc")" 0
eq "L3 exactly 1 PRR_SHADOW line for the CR set" "$(cnt "PRR_SHADOW lane=unblock key=$SLUG#cr " "$shadow_log")" 1
eq "L3 the only PRR_SHADOW line" "$(cnt 'PRR_SHADOW' "$shadow_log")" 1
[ "$(cnt PRR_SHADOW "$shadow_log")" = 1 ] || cat "$shadow_log"
eq "L3 the lane acted on GitHub: no stale-change-request for #5" \
  "$(jq -r 'select(.kind == "stale-change-request") | .pr' "$FXT/records.jsonl" | sort -n | tr '\n' ' ')" "6 "
[ ! -d "$CACHE" ] && ok || bad "L3 shadow writes no cache"

# ═════ L4 off / L9 default: the same GitHub reads, record reads only in shadow ═
reset
tick 0 GH_SOURCE=off
eq "L4 off: 0 /api/pr-records calls" "$(cnt '/api/pr-records' "$FXT/jobs.log")" 0
sort "$FXT/gh-calls.txt" > "$T/off-calls.txt"; cp "$FXT/records.jsonl" "$T/rec-off.jsonl"
reset
tick 0 GH_SOURCE=shadow
eq "L4 off and shadow make the same GitHub calls" "$(sort "$FXT/gh-calls.txt")" "$(cat "$T/off-calls.txt")"
eq "L4 shadow over agreeing sources: 0 PRR_SHADOW lines" "$(cnt PRR_SHADOW "$shadow_log")" 0
[ "$(cnt PRR_SHADOW "$shadow_log")" = 0 ] || cat "$shadow_log"
reset
tick 0
N=$(cnt '/api/pr-records' "$FXT/jobs.log")
[ "$N" -gt 0 ] && ok || bad "L9 no GH_SOURCE, no row: shadow reads the record (got $N)"
eq "L9 the step was read from the settings row" "$(cnt '^SETTING lane.unblock.gh_source$' "$FXT/seq.log")" 1
eq "L9 the GitHub calls equal L4's" "$(sort "$FXT/gh-calls.txt")" "$(cat "$T/off-calls.txt")"
mkdir -p "$FXT/settings"; echo recordx > "$FXT/settings/lane.unblock.gh_source"
reset; tick 0
eq "L9b a bad row value: one PRR_STEP line per tick" "$(cnt 'PRR_STEP lane=unblock bad=recordx' "$shadow_log")" 1
eq "L9b and the tick runs shadow (GitHub calls as off)" "$(sort "$FXT/gh-calls.txt")" "$(cat "$T/off-calls.txt")"
scratch_rm "$FXT/settings" || exit 1

# ═════ EQ: record-step records equal off-step records ═════════════════════════
eq "EQ the fields the rules read: record == off" \
  "$(cp "$T/rec-record.jsonl" "$FXT/records.jsonl"; proj)" "$(cp "$T/rec-off.jsonl" "$FXT/records.jsonl"; proj)"

# ═════ L5: a stale record list falls back to GitHub, per site ═════════════════
reset; touch "$FXT/list-stale"
tick 0 GH_SOURCE=record
eq "L5 PRR_MISS for the review site" "$(cnt "PRR_MISS lane=unblock key=$SLUG#open@review why=stale fallback=github" "$shadow_log")" 1
eq "L5 PRR_MISS for the queue site" "$(cnt "PRR_MISS lane=unblock key=$SLUG#open@queue why=stale fallback=github" "$shadow_log")" 1
eq "L5 one open-list GitHub read per site" "$(cnt 'pulls?state=open&per_page=100' "$FXT/gh-calls.txt")" 2
eq "L5 the records still match" "$(recs)" "$R1"

# ═════ L6: a failed gated read writes no cache, and reads again ═══════════════
reset; touch "$FXT/comments-fail-3"
tick 0 GH_SOURCE=record
[ ! -e "$CACHE/3-comments.json" ] && [ ! -e "$CACHE/3-comments.meta" ] && ok || bad "L6 a failed comments read must write no cache file"
[ -e "$CACHE/3-reviews.json" ] && ok || bad "L6 the reviews read of #3 still caches"
tick 60 GH_SOURCE=record
eq "L6 tick 2 reads issues/3/comments again" "$(cnt 'issues/3/comments' "$FXT/gh-calls.txt")" 1
eq "L6 and only that" "$(gh_calls)" 1

# ═════ L7: past the backstop every gated read runs again ═════════════════════
reset
tick 0 GH_SOURCE=record
cp "$FXT/gh-calls.txt" "$T/l7-first.txt"
tick 1900 GH_SOURCE=record
eq "L7 caches older than 1800 s: every gated read again" \
  "$(grep -E 'reviews|comments|state=closed' "$FXT/gh-calls.txt" | sort)" "$(grep -E 'reviews|comments|state=closed' "$T/l7-first.txt" | sort)"
tick 1960 GH_SOURCE=record UNBLOCK_PRR_BACKSTOP_S=86400
eq "L7 near miss: the knob 86400, 60 s later: 0 calls" "$(gh_calls)" 0

# ═════ L8: the PR reads come from the record ══════════════════════════════════
reset
tick 0 GH_SOURCE=record
eq "L8 0 pulls/<n> GitHub reads" "$(grep -cE 'pulls/[0-9]+( |$)' "$FXT/gh-calls.txt")" 0
eq "L8 0 branch GitHub reads" "$(cnt 'state=open&head=' "$FXT/gh-calls.txt")" 0
eq "L8 BH-20 has its ticket branch PR #10 from the record" \
  "$(jq -c 'select(.ticket_key == "BH-20") | [.has_pr, .pr, .head, .pr_source]' "$FXT/records.jsonl")" "[true,10,\"$(jq -r '.[9].head' "$FXT/prs.json")\",\"rest\"]"
eq "L8 BH-7's ejected PR #7 from the record" \
  "$(jq -c 'select(.ticket_key == "BH-7") | [.pr, .pr_state, .merged, .head == null]' "$FXT/records.jsonl")" '[7,"open",false,false]'
eq "L8 the per-tick memo: one branch list read" "$(cnt 'state=open&need=head_sha,head_ref$' "$FXT/jobs.log")" 1

# ═════ L10: a pr wake for #99 makes the closed list due, nothing else ════════
feed "pr:99:$((NOWR + 30))"
tick 60 GH_SOURCE=record
eq "L10 the closed list is read" "$(cnt 'pulls?state=closed' "$FXT/gh-calls.txt")" 1
eq "L10 every per-PR cache is served" "$(gh_calls)" 1

# ═════ B: budget ═════════════════════════════════════════════════════════════
eq "B 0 curl or gh CLI calls" "$(cnt . "$T/net.log")" 0
eq "B 0 alerts" "$(cnt . "$T/alerts.log")" 0

echo "unblock-record.bh-10158: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
