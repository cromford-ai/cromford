#!/bin/bash
# tests/unblock-change-gate.bh-10197-test.sh — BH-10197: the unblock lane reads
# a PR from GitHub only after a change. Driven through the SHIPPED entry point
# `bin/unblock.sh tick --project cromford` with the REAL collectors and
# the real change gate (bin/lib/unblock/change-gate.sh). The two jobs worker
# routes are the file-backed fake tests/lib/unblock-gate-fake.bh-10197.sh (the
# real routes are proven in worker/jobs/test/unblock-change-marks.bh-10197.test.js).
#
#   G1  step record, 50 open PRs: tick 1 (first seen) reads every gated PR and
#       commits 50 queue + 50 review rows; tick 2 (UNBLOCK_NOW + 600, no wake)
#       makes 0 GitHub calls that name a PR; the gate log lines carry the counts
#   G2  one new pr wake for #7: tick 3's PR-naming GitHub calls all name #7,
#       and there is at least 1; G2b an issue wake for 900 reads #12 (branch
#       ticket/bh-900) and only #12
#   G3  the records of tick 2 (gate on, record, served from the rows) equal
#       tick 1's on every field but the clock ones, and equal an off-step tick
#       at the same UNBLOCK_NOW on every field (idle_min included)
#   G4  step shadow: the GitHub calls and the records equal step off's; 1
#       check and 1 commit per collector; a stored field changed under an
#       unchanged mark gives exactly 1 GATE_SHADOW line
#   G5  rule 1, record: the check answers rc 75 (and, a second run, rc 1 as an
#       http 500): no PR-naming GitHub call, no pr-approved-idle,
#       pr-verdict-old-head or review record, one queue-unreadable record with
#       input change-gate, change-gate#<pr> in the review line, 0 commit calls
#       and no file under state/unblock-prr/
#   G6  the commit fails: the next tick reads every PR again
#   G7  backstop: 3599 s after the commit 0 PR calls; 3600 s every gated read
#   G8  unsettled: a wake in the current minute reads that PR on this tick and
#       on the next; then it is quiet
#   G9  a needed field missing from the row (#35 was MERGE with a CR, now a
#       lead BLOCK): only the comments read of #35 runs
#   G10 step off: 0 calls to /api/unblock/change-marks/*
#   G11 the file cache under UBP_FRESH=<mark> (prr.sh ubp_cached): served only
#       when it was read in this tick under the same mark
#   B   budget (BH-7563): 0 curl, 0 gh CLI calls, no bin/lane-alert.sh call
#
# FIXTURE: 50 open PRs. #1-#20 MERGE, idle (U4); #21-#30 a standing lead BLOCK
# (R4); #31-#40 MERGE with a CR in the change-requested set (U4 and R5);
# #41-#50 nothing stands on the head, a lead MERGE on an older head
# (U13-RESTAMP). #12's branch is ticket/bh-900. Clocks: UNBLOCK_NOW (the
# lane) and GATE_NOW (the fake worker); no wall clock, no sleep.
#
# MUTATIONS (D1), each tried once by hand: ubg_skip always rc 1 -> G1 red;
# _ubg_fail writes unreadable in step record (a failed check read as off) ->
# G5 red; ubg_put merges the stored fields of a due PR -> G9b red;
# _ubp_this_tick always rc 0 (prr.sh) -> G11 red.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/unblock-change-gate.bh-10197-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
cnt() { if [ -f "$2" ]; then grep -c -- "$1" "$2"; else echo 0; fi; }

[ -r "$REPO/bin/unblock.sh" ] && [ -r "$REPO/bin/lib/unblock/change-gate.sh" ] \
  || { echo "FAIL: missing bin/unblock.sh or bin/lib/unblock/change-gate.sh"; echo "unblock-change-gate.bh-10197: 0 passed, 1 failed"; exit 1; }

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
[ -f "$H/bin/lib/unblock/change-gate.sh" ] && ok || bad "setup: the closure lacks bin/lib/unblock/change-gate.sh"
rm -f "$H/bin/lane-alert.sh"
printf '#!/bin/bash\nprintf "ALERT %%s\\n" "$*" >> "%s/alerts.log"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
for b in curl gh; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/net.log"\nexit 7\n' "$b" "$T" > "$FB/$b"
  chmod +x "$FB/$b"
done
"$REPO/bin/lanes-build.sh" --root "$REPO" --to "$T/lanes.json" >/dev/null 2>&1 && [ -s "$T/lanes.json" ] \
  || { echo "FAIL: bin/lanes-build.sh could not compose the registry"; echo "unblock-change-gate.bh-10197: 0 passed, 1 failed"; exit 1; }

SLUG=example-org/cromford
# The PRs: number, head, branch, standing verdict ("" = none), CR in the set, old head.
mkprs() {
  jq -n '[range(1; 51) | . as $n | {n: $n, head: ("\($n)" + ("c" * 40))[0:40],
      ref: (if $n == 12 then "ticket/bh-900" else "feature/pr-\($n)" end),
      verdict: (if $n <= 20 or ($n >= 31 and $n <= 40) then "MERGE" elif $n <= 30 then "BLOCK" else "" end),
      cr: ($n >= 31 and $n <= 40), old: ($n >= 41)}]' > "$FXT/prs.json"
}

cat > "$T/fx.sh" <<'SH'
. "$GATE_FAKE"
_fx_pr() { jq -c --argjson n "$1" '.[] | select(.n == $n)' "$FXT/prs.json"; }
setting_get() {
  case "$1" in
    unblock.enabled) echo 1 ;;
    *) return 2 ;;
  esac
}
lane_gate_or_exit() { return 0; }
lane_env_apply() { return 0; }
lane_role_model() { return 1; }
ub_rules_eval() { cat >> "$FXT/records.jsonl"; }
vd_standing() { # <slug> <n> <head>: word \t source \t - \t created_at; rc 1 none
  local v; v=$(_fx_pr "$2" | jq -r .verdict)
  [ -n "$v" ] || return 1
  printf '%s\tlead\t-\t2026-11-25T10:00:00Z\n' "$v"
}
lifecycle_stuck() { echo '{"rows":[]}'; }
_jobs_req() {
  local q="$2" n age
  printf '%s %s\n' "$1" "$2" >> "$FXT/jobs.log"
  case "$1 $q" in
    "POST /api/unblock/change-marks/"*) fxg_req "$1" "$2" "${3:-}"; return ;;
    "GET /api/pr-records?"*number=*)
      n=${q##*number=}
      _fx_pr "$n" | jq -c '{row: {repo: "example-org/cromford", number: .n, state: "open", draft: 0, head_sha: .head,
          head_ref: .ref, base_ref: "main", labels: [], mergeable_state: "clean", url: "https://github.com/example-org/cromford/pull/\(.n)",
          checks: {"ci / test": {status: "completed", conclusion: "success", sha: .head, at: "2026-11-25T09:00:00Z"}},
          files: {sha: .head, paths: ["bin/x-\(.n).sh"]}, head_commit: {sha: .head, at: "2026-11-25T08:00:00Z"}}, age_s: 30}' ;;
    "GET /api/pr-records?"*state=open*)
      jq -c '{rows: [.[] | {number: .n, title: "t", head_ref: .ref, head_sha: .head, base_ref: "main", author: "u", labels: [], body: "",
          mergeable_state: "clean", updated_at: "2026-11-25T00:00:00Z", created_at: ("2026-11-\(10 + (.n % 15))T00:00:\(10 + .n)Z"),
          url: "https://github.com/example-org/cromford/pull/\(.n)", draft: 0, merged_at: null,
          reviews: (if .cr then {lead: {state: "CHANGES_REQUESTED"}} else {} end)}],
         truncated: false, sync: {age_s: 10, synced_at: "2026-11-25T23:59:00Z"}, missing: null, unknown: 0}' "$FXT/prs.json" ;;
    "GET /api/verdicts?"*head=*)
      n=${q#*&pr=}; n=${n%%&*}
      _fx_pr "$n" | jq -c 'if .verdict == "" then {standing: null}
        else {standing: {verdict: .verdict, source: "lead", note: "lead-job:job-\(.n)", id: (100 + .n), created_at: "2026-11-25T10:00:00Z"}} end' ;;
    "GET /api/verdicts?"*)
      n=${q#*&pr=}; n=${n%%&*}
      _fx_pr "$n" | jq -c 'if .old then {rows: [{source: "lead", verdict: "MERGE", head_sha: ("f" * 40), id: (500 + .n), created_at: "2026-11-24T10:00:00Z"}]} else {rows: []} end' ;;
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
      jq -c '[.[] | {number: .n, state: "open", draft: false, head: {sha: .head, ref: .ref}, labels: [], html_url: "https://github.com/example-org/cromford/pull/\(.n)", updated_at: "x", created_at: ("2026-11-\(10 + (.n % 15))T00:00:\(10 + .n)Z")}] | sort_by(.created_at) | reverse' "$FXT/prs.json" ;;
    repos/*/pulls\?state=open\&head=*) echo '[]' ;;
    repos/*/pulls\?state=closed*) echo '[]' ;;
    search/issues*) jq -c '{incomplete_results: false, items: [.[] | select(.cr) | {number: .n}]}' "$FXT/prs.json" ;;
    repos/*/pulls/*/reviews*)
      n=${p#repos/*/pulls/}; n=${n%%/*}
      _fx_pr "$n" | jq -c 'if .cr then [{id: (900 + .n), state: "CHANGES_REQUESTED", commit_id: ("0" * 40), body: "x <!-- review-verdict:block y --> z", user: {login: "lead"}, submitted_at: "2026-11-24T00:00:00Z"},
          {id: (950 + .n), state: "COMMENTED", commit_id: .head, body: "nit", user: {login: "someone"}, submitted_at: "2026-11-24T01:00:00Z"}] else [] end' ;;
    repos/*/issues/*/comments*) echo '[]' ;;
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

UNOW=1795000000
T0=1795000000
export FXG_DIR="$FXT/gate"
. "$REPO/tests/lib/unblock-gate-fake.bh-10197.sh" || exit 1
reset() {
  local d
  for d in "$H/state" "$H/logs" "$H/locks" "$T/net.log" "$T/alerts.log"; do scratch_rm "$d" || exit 1; done
  rm -f "$FXT"/*.log "$FXT"/*.txt "$FXT"/records.jsonl
  mkprs; fxg_reset
  mkdir -p "$H/state"
  jq -nc --argjson fa "$UNOW" '{fetched_at: $fa, values: {"unblock.project.cromford.mode": "shadow"}, seeded: {}}' > "$H/state/settings-cache.json"
}
# tick <lane-offset-s> <gate-offset-s> [VAR=val...] — the shipped entry point.
# Each tick starts with empty call logs.
tick() {
  local off="$1" goff="$2"; shift 2
  rm -f "$FXT/gh-calls.txt" "$FXT/jobs.log" "$FXT/records.jsonl" "$FXG_DIR/calls.log"
  scratch_rm "$H/logs" || exit 1
  env -u GH_SOURCE -u UNBLOCK_GATE_BACKSTOP_S HARNESS="$H" FXT="$FXT" FXG_DIR="$FXG_DIR" GATE_NOW=$((T0 + goff)) \
    GATE_FAKE="$REPO/tests/lib/unblock-gate-fake.bh-10197.sh" UNBLOCK_FIXTURE="$T/fx.sh" HARNESS_TEST_SANDBOX=1 \
    LANE_GATE_DISABLE=1 LANE_GATE_NOW=$UNOW LANE_GATE_CACHE_S=60 UNBLOCK_TIMED=1 JOBS_URL= HARNESS_SECRET= \
    UNBLOCK_NOW=$((UNOW + off)) WAKE_BACKSTOP_NOW=$((T0 + goff)) PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=600 \
    LANE_REGISTRY="$T/lanes.json" PATH="$FB:$PATH" "$@" \
    bash "$H/bin/unblock.sh" tick --project cromford >"$T/out.txt" 2>&1
  echo $? > "$T/rc"
}
# The GitHub calls that name one PR.
PRCALL='pulls/[0-9]+|issues/[0-9]+/comments|commits/[0-9a-f]{7,}|check-runs'
prcalls() { if [ -f "$FXT/gh-calls.txt" ]; then grep -cE "$PRCALL" "$FXT/gh-calls.txt"; else echo 0; fi; }
prnums() { grep -oE '(pulls|issues)/[0-9]+' "$FXT/gh-calls.txt" 2>/dev/null | sed 's/.*\///' | sort -un | tr '\n' ' '; }
recs() { jq -cS 'select(.kind != null)' "$FXT/records.jsonl" 2>/dev/null | sort; }
# The gated families' records (queue records carry no family), every field
# but the clock-derived ones (idle_min, heartbeat_age_s).
noclock() { jq -cS 'select(.kind != null and ((.family // "queue") | IN("queue", "review"))) | del(.idle_min, .heartbeat_age_s)' "$FXT/records.jsonl" 2>/dev/null | sort; }
gatelog() { grep -h " gate $1 $SLUG step=" "$H/logs/unblock.log" 2>/dev/null | sed 's/^[^ ]* //'; }
rows() { jq -r --arg s "$1" '[keys[] | select(startswith($s + ":"))] | length' "$FXG_DIR/rows.json"; }

# ═════ G1: record, a quiet tick makes 0 PR calls ═════════════════════════════
reset
tick 0 0 GH_SOURCE=record
eq "G1 tick 1 rc" "$(cat "$T/rc")" 0
[ "$(cat "$T/rc")" = 0 ] || head -c 1500 "$T/out.txt"
G1=$(prcalls)
[ "$G1" -ge 60 ] && ok || bad "G1 tick 1 reads every gated PR (got $G1 PR calls)"
echo "info: G1 tick 1 (first seen) GitHub calls that name a PR: $G1; all GitHub calls: $(grep -c . "$FXT/gh-calls.txt")"
eq "G1 tick 1 kinds" "$(jq -r .kind "$FXT/records.jsonl" | sort | uniq -c | awk '{print $2"="$1}' | grep -E '^(lead-block|stale-change|pr-approved|pr-verdict-old)' | tr '\n' ' ')" \
  "lead-block-unrouted=10 pr-approved-idle=30 pr-verdict-old-head=10 stale-change-request=10 "
eq "G1 tick 1 queue rows" "$(rows queue)" 50
eq "G1 tick 1 review rows" "$(rows review)" 50
eq "G1 tick 1 queue gate line" "$(gatelog queue)" "gate queue $SLUG step=record checked=50 due=50 skipped=0 would_skip=0 unknown=0 stored=50"
eq "G1 tick 1 review gate line" "$(gatelog review)" "gate review $SLUG step=record checked=50 due=50 skipped=0 would_skip=0 unknown=0 stored=50"
eq "G1 the stored fields of #31 (queue)" "$(jq -c '."queue:31".fields' "$FXG_DIR/rows.json")" '{"cr":true,"tt":false}'
eq "G1 the stored fields of #45 (queue)" "$(jq -c '."queue:45".fields' "$FXG_DIR/rows.json")" '{"cdate":"2026-11-25T08:00:00Z"}'
eq "G1 the stored fc of #22 (review)" "$(jq -c '."review:22".fields.fc' "$FXG_DIR/rows.json")" 'false'
eq "G1 the stored rv of #33 is compact (CR only, marker body)" "$(jq -c '."review:33".fields.rv | [length, .[0].body, .[0].id]' "$FXG_DIR/rows.json")" '[1,"<!-- review-verdict:block ",933]'
cp "$FXT/records.jsonl" "$T/rec-t1.jsonl"; NC1=$(noclock)
cp "$FXT/gh-calls.txt" "$T/g1-calls.txt"
tick 600 600 GH_SOURCE=record
eq "G1 tick 2 rc" "$(cat "$T/rc")" 0
eq "G1 tick 2, no wake: GitHub calls that name a PR" "$(prcalls)" 0
echo "info: G1 tick 2 (gate on, no wake) GitHub calls that name a PR: $(prcalls); all GitHub calls: $(grep -c . "$FXT/gh-calls.txt" 2>/dev/null || echo 0)"
[ "$(prcalls)" = 0 ] || grep -E "$PRCALL" "$FXT/gh-calls.txt" | head -5 | sed 's/^/  gh: /'
eq "G1 tick 2 queue gate line" "$(gatelog queue)" "gate queue $SLUG step=record checked=50 due=0 skipped=40 would_skip=0 unknown=0 stored=0"
eq "G1 tick 2 review gate line" "$(gatelog review)" "gate review $SLUG step=record checked=50 due=0 skipped=20 would_skip=0 unknown=0 stored=0"
eq "G1 tick 2: no commit call (nothing read)" "$(cnt '^commit ' "$FXG_DIR/calls.log")" 0
grep -q "review: $SLUG prs=50 .* gate=50/20\$" "$H/logs/unblock.log" && ok || bad "G1 the review line ends gate=50/20: $(grep ' review: ' "$H/logs/unblock.log")"
cp "$FXT/records.jsonl" "$T/rec-t2.jsonl"

# ═════ G7: the backstop ═══════════════════════════════════════════════════════
tick 3599 3599 GH_SOURCE=record
eq "G7 3599 s: 0 PR calls" "$(prcalls)" 0
tick 3600 3600 GH_SOURCE=record
eq "G7 3600 s: every gated read again" "$(grep -E "$PRCALL" "$FXT/gh-calls.txt" | sort)" "$(grep -E "$PRCALL" "$T/g1-calls.txt" | sort)"
eq "G7 the reason is the backstop: 50 due" "$(gatelog queue | grep -o 'due=[0-9]*')" "due=50"
tick 3700 3700 GH_SOURCE=record UNBLOCK_GATE_BACKSTOP_S=0
echo "info: G7 the same quiet fixture with UNBLOCK_GATE_BACKSTOP_S=0 (the gate off): GitHub calls that name a PR: $(prcalls); all GitHub calls: $(grep -c . "$FXT/gh-calls.txt")"
eq "G7 the knob 0 = off: every gated read" "$(grep -E "$PRCALL" "$FXT/gh-calls.txt" | sort)" "$(grep -E "$PRCALL" "$T/g1-calls.txt" | sort)"

# ═════ G3: decisions equal ════════════════════════════════════════════════════
cp "$T/rec-t2.jsonl" "$FXT/records.jsonl"
eq "G3 tick 2 (rows) == tick 1 (GitHub) on every non-clock field" "$(noclock)" "$NC1"
eq "G3 idle_min moved with the lane clock (+10 min on #1)" \
  "$(jq -r 'select(.pr == 1 and .kind == "pr-approved-idle") | .idle_min' "$FXT/records.jsonl")" \
  "$(( $(jq -r 'select(.pr == 1 and .kind == "pr-approved-idle") | .idle_min' "$T/rec-t1.jsonl") + 10 ))"
R2=$(recs)
reset
tick 600 600 GH_SOURCE=off
eq "G3 tick 2 (gate on, record) == an off tick at the same UNBLOCK_NOW, every field" "$(recs)" "$R2"
cp "$FXT/gh-calls.txt" "$T/off-calls.txt"; ROFF=$(recs)
# ═════ G10: step off makes no gate call ═══════════════════════════════════════
eq "G10 off: 0 change-marks calls" "$(cnt '/api/unblock/change-marks/' "$FXT/jobs.log")" 0
eq "G10 off: no gate line" "$(grep -c ' gate ' "$H/logs/unblock.log")" 0


# ═════ G2: one wake reads one PR ══════════════════════════════════════════════
reset
tick 0 0 GH_SOURCE=record
fxg_wake pr 7 $((T0 + 100))
tick 300 300 GH_SOURCE=record
[ "$(prcalls)" -ge 1 ] && ok || bad "G2 the wake of #7 reads #7 (got 0 PR calls)"
eq "G2 every PR-naming call names #7" "$(prnums)" "7 "
grep -q 'pulls/7/reviews' "$FXT/gh-calls.txt" && ok || bad "G2 #7's reviews are read: $(cat "$FXT/gh-calls.txt" 2>/dev/null)"
eq "G2 the queue line: 1 due" "$(gatelog queue | grep -o 'due=[0-9]*')" "due=1"
tick 400 400 GH_SOURCE=record
eq "G2 the next tick is quiet again" "$(prcalls)" 0
# G2b an issue wake: #12's branch is ticket/bh-900
fxg_wake issue 900 $((T0 + 450))
tick 500 500 GH_SOURCE=record
eq "G2b the issue wake of 900 reads #12 and only #12" "$(prnums)" "12 "
fxg_wake pr 9999 $((T0 + 550))
tick 600 600 GH_SOURCE=record
eq "G2b a wake for a PR that is not open reads nothing" "$(prcalls)" 0

# ═════ G8: a wake in the current minute ═══════════════════════════════════════
fxg_wake pr 2 $((T0 + 720))
tick 720 725 GH_SOURCE=record
eq "G8 the wake reads #2" "$(prnums)" "2 "
eq "G8 stored unsettled" "$(jq -c '."queue:2".settled' "$FXG_DIR/rows.json")" 0
tick 800 800 GH_SOURCE=record
eq "G8 the next tick reads #2 again (unsettled)" "$(prnums)" "2 "
tick 900 900 GH_SOURCE=record
eq "G8 then it is quiet" "$(prcalls)" 0

# ═════ G9: a missing field is read alone ══════════════════════════════════════
jq 'map(if .n == 35 then .verdict = "BLOCK" | .cr = false else . end)' "$FXT/prs.json" > "$T/prs.tmp" && cp "$T/prs.tmp" "$FXT/prs.json"
tick 1000 1000 GH_SOURCE=record
eq "G9 only the missing comments read of #35 runs" "$(grep -E "$PRCALL" "$FXT/gh-calls.txt" | sed 's/?.*//')" "GET repos/$SLUG/issues/35/comments"
eq "G9 #35 is a lead BLOCK record now" "$(jq -c 'select(.pr == 35) | [.kind, .cr_on_head, .findings_comment_on_head]' "$FXT/records.jsonl")" '["lead-block-unrouted",false,false]'
eq "G9 the row keeps rv and adds fc" "$(jq -c '."review:35".fields | keys' "$FXG_DIR/rows.json")" '["fc","rv"]'
# G9b a due PR stores only its fresh fields: a head change drops the old ones
jq 'map(if .n == 41 then .verdict = "MERGE" | .old = false | .head = ("d" * 40) else . end)' "$FXT/prs.json" > "$T/prs.tmp" && cp "$T/prs.tmp" "$FXT/prs.json"
tick 1100 1100 GH_SOURCE=record
eq "G9b a head change stores only the fields read for it" "$(jq -c '."queue:41" | [.head[0:4], (.fields | keys)]' "$FXG_DIR/rows.json")" '["dddd",["cr","tt"]]'

# ═════ G4: shadow == off ══════════════════════════════════════════════════════
reset
tick 600 600 GH_SOURCE=shadow
eq "G4 shadow tick rc" "$(cat "$T/rc")" 0
eq "G4 shadow makes the GitHub calls of off" "$(sort "$FXT/gh-calls.txt")" "$(sort "$T/off-calls.txt")"
eq "G4 shadow's records equal off's" "$(recs)" "$ROFF"
eq "G4 1 check per collector" "$(cnt '^check ' "$FXG_DIR/calls.log")" 2
eq "G4 1 commit per collector" "$(cnt '^commit ' "$FXG_DIR/calls.log")" 2
jq '."queue:31".fields.cr = false' "$FXG_DIR/rows.json" > "$T/rows.tmp" && cp "$T/rows.tmp" "$FXG_DIR/rows.json"
tick 700 700 GH_SOURCE=shadow
eq "G4 shadow tick 2 makes the GitHub calls of off" "$(sort "$FXT/gh-calls.txt")" "$(sort "$T/off-calls.txt")"
eq "G4 exactly 1 GATE_SHADOW line" "$(cnt 'GATE_SHADOW' "$H/logs/unblock.log")" 1
eq "G4 the line names #31 and its field" "$(grep -o 'GATE_SHADOW .*' "$H/logs/unblock.log")" "GATE_SHADOW queue $SLUG#31 field=cr"
eq "G4 the shadow queue line counts would_skip" "$(gatelog queue)" "gate queue $SLUG step=shadow checked=50 due=0 skipped=0 would_skip=50 unknown=0 stored=40"

# ═════ G5: rule 1, a failed check in record is unknown ═══════════════════════
for frc in 75 1; do
  reset
  echo "$frc" > "$FXG_DIR/check-fail"
  tick 0 0 GH_SOURCE=record
  eq "G5[$frc] rc" "$(cat "$T/rc")" 0
  eq "G5[$frc] no PR-naming GitHub call" "$(prcalls)" 0
  eq "G5[$frc] no record built from the gated reads" \
    "$(jq -r 'select(.kind | IN("pr-approved-idle", "pr-verdict-old-head", "lead-block-unrouted", "lead-block-cap-only", "stale-change-request")) | .kind' "$FXT/records.jsonl" | grep -c .)" 0
  eq "G5[$frc] one queue-unreadable record, input change-gate" \
    "$(jq -c 'select(.kind == "queue-unreadable") | .input' "$FXT/records.jsonl" | tr '\n' ' ')" '"change-gate" '
  L=$(grep " review: $SLUG " "$H/logs/unblock.log")
  grep -q 'change-gate#21' <<<"$L" && grep -q 'change-gate#50' <<<"$L" && ok || bad "G5[$frc] the review line names change-gate#<pr>: $L"
  eq "G5[$frc] 0 commit calls" "$(cnt '^commit ' "$FXG_DIR/calls.log")" 0
  eq "G5[$frc] no row written" "$(jq 'length' "$FXG_DIR/rows.json")" 0
  eq "G5[$frc] the unknown count" "$(gatelog queue | grep -o 'unknown=[0-9]*')" "unknown=50"
  [ ! -d "$H/state/unblock-prr" ] || [ -z "$(find "$H/state/unblock-prr" -name '*-reviews.json' -o -name '*-comments.json')" ] && ok \
    || bad "G5[$frc] no file under state/unblock-prr/ for the PRs: $(find "$H/state/unblock-prr" -type f | head -3)"
done

# ═════ G6: a failed commit moves no mark ══════════════════════════════════════
reset
echo 1 > "$FXG_DIR/commit-fail"
tick 0 0 GH_SOURCE=record
eq "G6 the commit was tried" "$(cnt '^commit ' "$FXG_DIR/calls.log")" 2
grep -q "gate queue $SLUG commit failed" "$H/logs/unblock.log" && ok || bad "G6 the failed commit is logged"
rm -f "$FXG_DIR/commit-fail"
tick 600 600 GH_SOURCE=record
eq "G6 the next tick reads every PR again" "$(grep -E "$PRCALL" "$FXT/gh-calls.txt" | sort)" "$(grep -E "$PRCALL" "$T/g1-calls.txt" | sort)"

# ═════ G11: UBP_FRESH serves only this tick's file under the same mark ══════
# The file cache of bin/lib/unblock/prr.sh, driven directly. The real
# prs_wake_seen reads a seeded mirror with no wake, so a plain read is served.
NOWR=$(date +%s)  # determinism: ok the real prs_wake_seen reads the box clock; the gate clock is pinned to it
SD="$H/state/pr-snapshot/example-org_cromford"
reset
mkdir -p "$SD"
printf '%s\t1\t1\t%s\n' "$NOWR" "$((NOWR - 7200))" > "$SD/wakes.state"
echo 500 > "$SD/wakes.wm"; : > "$SD/changed.tsv"
# gread <gate-clock> [UBP_FRESH] — one reviews read of #5 in a new shell (a new tick)
gread() {
  env HARNESS="$H" HARNESS_TEST_SANDBOX=1 GH_SOURCE=record WAKE_BACKSTOP_NOW="$1" PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=600 \
    UBP_FRESH="${2:-}" T="$T" bash -c '. "$HARNESS/bin/lib/unblock/prr.sh" || exit 9
      _jobs_req() { return 1; }  # the mirror is fresh: prs_wake_seen needs no worker read
      rd() { echo read >> "$T/g11.log"; echo "[{\"id\":$(grep -c . "$T/g11.log")}]" > "$1"; }
      ubp_cached example-org/cromford 5 "$(printf "5%.0s" {1..40})" reviews "$T/g11.json" rd "$T/g11.json"'
}
rm -f "$T/g11.log"
gread "$((NOWR + 10))"; gread "$((NOWR + 15))"
eq "G11 a plain read runs once and is served the next tick" "$(cnt read "$T/g11.log")" 1
rm -f "$T/g11.log"
gread "$((NOWR + 20))" 7
eq "G11 UBP_FRESH=7: the plain-key file is not served (1 read)" "$(cnt read "$T/g11.log")" 1
rm -f "$T/g11.log"
env HARNESS="$H" HARNESS_TEST_SANDBOX=1 GH_SOURCE=record WAKE_BACKSTOP_NOW="$((NOWR + 20))" PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=600 \
  UBP_FRESH=7 T="$T" bash -c '. "$HARNESS/bin/lib/unblock/prr.sh" || exit 9
      _jobs_req() { return 1; }  # the mirror is fresh: prs_wake_seen needs no worker read
    rd() { echo read >> "$T/g11.log"; echo "[]" > "$1"; }
    ubp_cached example-org/cromford 5 "$(printf "5%.0s" {1..40})" reviews "$T/g11.json" rd "$T/g11.json"'
eq "G11 the same tick, the same mark: served (0 reads)" "$(cnt read "$T/g11.log")" 0
rm -f "$T/g11.log"
env HARNESS="$H" HARNESS_TEST_SANDBOX=1 GH_SOURCE=record WAKE_BACKSTOP_NOW="$((NOWR + 80))" PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=600 \
  UBP_FRESH=7 T="$T" bash -c '. "$HARNESS/bin/lib/unblock/prr.sh" || exit 9
      _jobs_req() { return 1; }  # the mirror is fresh: prs_wake_seen needs no worker read
    rd() { echo read >> "$T/g11.log"; echo "[]" > "$1"; }
    ubp_cached example-org/cromford 5 "$(printf "5%.0s" {1..40})" reviews "$T/g11.json" rd "$T/g11.json"'
eq "G11 a later tick, the same mark: a file from an older tick is not served (1 read)" "$(cnt read "$T/g11.log")" 1
rm -f "$T/g11.log"
env HARNESS="$H" HARNESS_TEST_SANDBOX=1 GH_SOURCE=record WAKE_BACKSTOP_NOW="$((NOWR + 80))" PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=600 \
  UBP_FRESH=8 T="$T" bash -c '. "$HARNESS/bin/lib/unblock/prr.sh" || exit 9
      _jobs_req() { return 1; }  # the mirror is fresh: prs_wake_seen needs no worker read
    rd() { echo read >> "$T/g11.log"; echo "[]" > "$1"; }
    ubp_cached example-org/cromford 5 "$(printf "5%.0s" {1..40})" reviews "$T/g11.json" rd "$T/g11.json"'
eq "G11 the same tick, a newer mark: not served (1 read)" "$(cnt read "$T/g11.log")" 1

# ═════ B: budget ═════════════════════════════════════════════════════════════
eq "B 0 curl or gh CLI calls" "$(cnt . "$T/net.log")" 0
eq "B 0 alerts" "$(cnt . "$T/alerts.log")" 0

echo "unblock-change-gate.bh-10197: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
