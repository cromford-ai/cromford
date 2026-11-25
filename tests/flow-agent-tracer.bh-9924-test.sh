#!/bin/bash
# tests/flow-agent-tracer.bh-9924-test.sh — BH-9924 (tracer slice BH-9956): the
# SHIPPED bin/flow-agent.sh, from a scratch $HARNESS (scratch_install_closure),
# against the fake world (tests/lib/fake-flow-world.bh-9924.sh): the REAL jobs
# worker on node:sqlite, a fake gh, a fake in-app board, 0 network calls and 0
# model calls. Each case has its own project (and its own harness tree when it
# replaces a lib file), so no case reads another's rows.
#
#   C1-C6   the client rc map: 200 -> 0, 409 -> 9, 500 -> 1, a timeout -> 1
#           with stdout empty; fa_mode; fa_nudge's dedupe
#   D1-D14  the decision table (plan BH-9956 Failure modes), through the real
#           flow_collect and flow_cause
#   K1-K7   collect: one waiting/state read, a failed board read, an in-app
#           board, collect.d, the round trip, truncated, a full issue list
#   L1-L8   the lane: switches, lock, failed read, log lines, tick, usage
#   A1-A8   act: would, already, decision key (A4w: the would key and a flip
#           to act), held, refused, unknown, no write
#   S1-S2   the seam files and the fake-world fragments
#   B1      no network call outside 127.0.0.1, no model call
#   O1      the observable outcome of the ticket
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/flow-agent-tracer.bh-9924-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/fake-flow-world.bh-9924.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$3', got '$2'"; fi; }
has() { if grep -qE -- "$2" <<<"$3"; then ok "$1"; else bad "$1: no /$2/ in [$3]"; fi; }
hasnt() { if grep -qE -- "$2" <<<"$3"; then bad "$1: /$2/ found in [$3]"; else ok "$1"; fi; }
for c in node jq curl python3 flock sha256sum; do
  command -v "$c" >/dev/null 2>&1 || { echo "SKIP: $c missing"; exit 0; }
done
# The worker imports these git-ignored renders; a fresh checkout has none.
HARNESS_TEST_SANDBOX=1 "$REPO/bin/lanes-build.sh" --root "$REPO" --write >/dev/null || { echo "FAIL: cannot write catalog/lanes.json"; exit 1; }
"$REPO/bin/llm-sites-build.sh" --compose --repo "$REPO" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }

NOW=$(( $(date -u +%s) / 60 * 60 ))  # determinism: ok the single anchor; the worker clock and FLOW_AGENT_NOW are pinned to it
iso_ago() { date -u -d "@$((NOW - $1 * 60))" '+%Y-%m-%dT%H:%M:%SZ'; }
export FFW_NOW_ISO; FFW_NOW_ISO=$(iso_ago 0)

# ── the scratch harness ─────────────────────────────────────────────────────
H0="$T/h"
mkdir -p "$H0/env" "$H0/logs" "$H0/locks" "$H0/state" "$H0/flags" "$H0/prompts"
: > "$H0/env/global.env"; : > "$H0/fleet.conf"
for L in bin/flow-agent.sh bin/jobs-client.sh bin/fleet-conf.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$H0" ) >/dev/null || bad "setup: could not install $L"
done
chmod +x "$H0/bin/"*.sh 2>/dev/null
ffw_start "$NOW"; rc=$?
trap 'ffw_stop; __scratch_exit_trap' EXIT
if [ -z "${FFW_BASE:-}" ]; then
  [ "$rc" = 3 ] && { echo "SKIP: node:sqlite unavailable"; exit 0; }
  echo "setup: worker did not start: $(cat "$T/ffw-worker.err")"; exit 1
fi
ffw_gh; ffw_net_guard; ffw_board
# B1: a model call would be a `claude` (or agent-call) binary run; both log here.
for b in claude agent-call; do printf '#!/bin/bash\necho "%s $*" >> "%s/ffw-model.log"\nexit 1\n' "$b" "$T" > "$T/ffw-stub/$b"; chmod +x "$T/ffw-stub/$b"; done
: > "$T/ffw-model.log"
export HARNESS="$H0" BOX_NAME=fixture-box JOBS_BOX=fixture-box JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 JOBS_TIMEOUT=10
export JOBS_SETTINGS_CACHE_S=0 FLOW_AGENT_NOW="$NOW" ETC_HARNESS_ENV="$T/no-etc" GH_ETAG=0
SQL() { ffw_sql "$@" | jq -r '.rows'; }
setrow() { ffw_sql "INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'fixture','fixture',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value" "$1" "$2" "$FFW_NOW_ISO" >/dev/null; }

# proj <name> — a GitHub-issues project (key prefix FX) with no issue yet.
proj() {
  printf '%s fixture-org/%s - - 0 fixture-box\n' "$1" "$1" >> "$H0/fleet.conf"
  printf 'run-build.sh %s <issue-number> FX-<issue-number>\n' "$1" > "$H0/prompts/$1.md"
  mkdir -p "$T/ffw-gh/$1"; echo '[]' > "$T/ffw-gh/$1/issues.1.json"
}
# issues <p> <n...> — the open ai-build issues of <p>, updated 60 min ago.
issues() {
  jq -nc --arg at "$(iso_ago 60)" --arg r "$1" '[$ARGS.positional[] | {number: tonumber, title: ("ticket " + .),
      html_url: ("https://github.example/" + $r + "/issues/" + .), state: "open", updated_at: $at, created_at: $at}]' \
    --args "${@:2}" > "$T/ffw-gh/$1/issues.1.json"
}
# prs <p> <head...> — the open PRs of <p>, numbered from 900.
prs() {
  jq -nc '[$ARGS.positional | to_entries[] | {number: (900 + .key), head: {ref: .value}}]' --args "${@:2}" > "$T/ffw-gh/$1/pulls.1.json"
}
run_lane() { local h="$1"; shift; HARNESS="$h" bash "$h/bin/flow-agent.sh" "$@"; }
summary() { grep -E " tick $2 mode=" "$1/logs/flow-agent.log" 2>/dev/null | tail -1; }
actline() { grep -E " act $2 $3 " "$1/logs/flow-agent.log" 2>/dev/null | tail -1; }
actions_of() { SQL "SELECT ticket_key, code, outcome, detail, decision_key, episode FROM flow_actions WHERE project=? ORDER BY id" "$1"; }
wcalls() { grep -cE "^$1 " "$FFW_WLOG"; }
# lib <h> <code> — a shell with the lane's libs loaded, running <code>.
lib() {
  local h="$1"; shift
  HARNESS="$h" H="$h" bash -c '
    . "$H/bin/jobs-client.sh" >/dev/null 2>&1
    for f in gh-rest gh-rest-list tracker preplan-lib board-creds jobs/flow-agent flow-agent/collect flow-agent/cause flow-agent/trigger flow-agent/gates flow-agent/diagnose flow-agent/act; do
      . "$H/bin/lib/$f.sh" 2>/dev/null
    done
    __c="$1"; shift; eval "$__c"' _ "$@"
}
# clone <name> — a copy of the scratch harness, for a case that replaces a lib file.
clone() { cp -a "$H0" "$T/$1" && printf '%s\n' "$T/$1"; }
# counting_arm <h> — arms/ready_not_queued.sh counts its calls and answers done.
counting_arm() {
  printf '#!/bin/bash\n# owner: fixture\nflow_arm_ready_not_queued() { echo call >> "%s/arm.calls"; FLOW_ARM_AFTER="verdict:ready,queue:queued,job:0,pr:none"; echo nudged; return 0; }\n' "$1" \
    > "$1/bin/lib/flow-agent/arms/ready_not_queued.sh"
  : > "$1/arm.calls"
}

# Every project, registered before any clone is taken.
for p in p-o1 p-dt p-d12 p-d13 p-k1 p-k2 p-k4 p-k6 p-k7 p-l1 p-l2 p-l3 p-l4 p-l5 p-l7 p-a1 p-a2 p-a4 p-a5 p-a6 p-a7; do proj "$p"; done
printf 'kthree fixture-org/kthree https://board.example /x 0 fixture-box\n' >> "$H0/fleet.conf"
mkdir -p "$T/ffw-gh/kthree"
printf 'KTHREE_API_BASE=%s\nKTHREE_INTERNAL_API_TOKEN=tok-fixture-kthree\n' "$FFW_BOARD_BASE" > "$H0/env/kthree.env"

# ── S1 S2: the seams and the fragments ──────────────────────────────────────
echo "S: seams"
S_MISS=""
while read -r f fn; do
  [ -f "$REPO/$f" ] || { S_MISS="$S_MISS $f(missing)"; continue; }
  bash -n "$REPO/$f" 2>/dev/null || S_MISS="$S_MISS $f(syntax)"
  grep -q '^# owner: BH-9924\.[0-9]' "$REPO/$f" || S_MISS="$S_MISS $f(owner)"
  ( . "$REPO/$f" >/dev/null 2>&1; declare -F "$fn" >/dev/null ) || S_MISS="$S_MISS $f($fn)"
done <<'EOF'
bin/lib/flow-agent/trigger.sh flow_trigger
bin/lib/flow-agent/gates.sh flow_gates
bin/lib/flow-agent/rules/answered_not_retriaged.sh flow_rule_answered_not_retriaged
bin/lib/flow-agent/arms/answered_not_retriaged.sh flow_arm_answered_not_retriaged
bin/lib/flow-agent/arms/ready_not_queued.sh flow_arm_ready_not_queued
bin/lib/flow-agent/collect.d/comments.sh flow_collect_comments
bin/lib/flow-agent/rules/row_for_archived_ticket.sh flow_rule_row_for_archived_ticket
bin/lib/flow-agent/arms/row_for_archived_ticket.sh flow_arm_row_for_archived_ticket
bin/lib/flow-agent/collect.d/archived.sh flow_collect_archived
bin/lib/flow-agent/rules/waits_behind_green_pr.sh flow_rule_waits_behind_green_pr
bin/lib/flow-agent/rules/waits_behind_dead_blocker.sh flow_rule_waits_behind_dead_blocker
bin/lib/flow-agent/rules/dependency_not_done_but_on_staging.sh flow_rule_dependency_not_done_but_on_staging
bin/lib/flow-agent/arms/waits_behind_green_pr.sh flow_arm_waits_behind_green_pr
bin/lib/flow-agent/arms/waits_behind_dead_blocker.sh flow_arm_waits_behind_dead_blocker
bin/lib/flow-agent/collect.d/blockers.sh flow_collect_blockers
bin/lib/flow-agent/rules/parent_slices_not_filed.sh flow_rule_parent_slices_not_filed
bin/lib/flow-agent/arms/parent_slices_not_filed.sh flow_arm_parent_slices_not_filed
bin/lib/flow-agent/collect.d/slices.sh flow_collect_slices
bin/lib/flow-agent/rules/pr_conflict.sh flow_rule_pr_conflict
bin/lib/flow-agent/rules/pr_red_same_test_as_main.sh flow_rule_pr_red_same_test_as_main
bin/lib/flow-agent/arms/pr_conflict.sh flow_arm_pr_conflict
bin/lib/flow-agent/arms/pr_red_same_test_as_main.sh flow_arm_pr_red_same_test_as_main
bin/lib/flow-agent/collect.d/pr.sh flow_collect_pr
bin/lib/flow-agent/diagnose.sh flow_diagnose
EOF
eq "S1 every CONTRACT seam exists, parses, defines its function, has # owner:" "${S_MISS:-none}" none
grep -q 'export const routes = \[\]; // owner: BH-9924.10' "$REPO/worker/jobs/src/routes/flow-agent-panel.js" \
  && ok "S1 flow-agent-panel.js is the empty seam" || bad "S1 flow-agent-panel.js is not the empty seam"
for f in bin/lib/flow-agent/rules/ready_not_queued.sh bin/lib/flow-agent/collect.sh bin/lib/flow-agent/cause.sh bin/lib/flow-agent/act.sh bin/lib/jobs/flow-agent.sh; do
  [ -f "$H0/$f" ] || bad "S1 the closure of bin/flow-agent.sh holds no $f"
done
eq "S2 the fake world sourced the fragments 2..9 in order" "${FFW_FRAGMENTS:-}" "2 3 4 5 6 7 8 9"

# ── C1-C6: the client rc map ────────────────────────────────────────────────
echo "C: client"
DK=$(printf 'p-c|FX-1|ready_not_queued|ep' | sha256sum | cut -d' ' -f1)
OUT=$(lib "$H0" 'fa_claim "$1" p-c FX-1 ready_not_queued ready_not_queued ep claimed ""; echo " rc=$?"' "$DK")
has "C1 a 200 claim is rc 0" ' rc=0$' "$OUT"
OUT=$(lib "$H0" 'fa_claim "$1" p-c FX-1 ready_not_queued ready_not_queued ep claimed ""; echo " rc=$?"' "$DK")
has "C2 a 409 claim is rc 9" ' rc=9$' "$OUT"
has "C2 the 409 body names the outcome" '"outcome":"claimed"' "$OUT"
OUT=$(lib "$H0" 'fa_count24h p-c FX-1; echo "rc=$?"')
eq "C1 fa_count24h on 200 prints the count (a claimed row is not counted)" "$OUT" $'0\nrc=0'
S500=$(ffw_stub_http 500); SHANG=$(ffw_stub_http hang); S409=$(ffw_stub_http 409)
OUT=$(JOBS_URL="$S409" lib "$H0" 'fa_record "$1" done "" ""; echo " rc=$?"' "$DK")
has "C2 a 409 record is rc 9" ' rc=9$' "$OUT"
for f in 'fa_claim "$1" p-c FX-1 ready_not_queued ready_not_queued ep claimed ""' 'fa_record "$1" done "" ""' 'fa_count24h p-c FX-1' 'fa_mode p-c'; do
  OUT=$(JOBS_URL="$S500" lib "$H0" "$f"' >"$HARNESS/c.out"; echo "rc=$?"' "$DK"); OUTS=$(cat "$H0/c.out")
  eq "C3 500: ${f%% *} rc 1" "$OUT" "rc=1"; eq "C3 500: ${f%% *} prints nothing" "$OUTS" ""
done
for f in 'fa_claim "$1" p-c FX-1 ready_not_queued ready_not_queued ep claimed ""' 'fa_count24h p-c FX-1'; do
  OUT=$(JOBS_URL="$SHANG" JOBS_TIMEOUT=1 lib "$H0" "$f"' >"$HARNESS/c.out"; echo "rc=$?"' "$DK"); OUTS=$(cat "$H0/c.out")
  eq "C4 timeout: ${f%% *} rc 1" "$OUT" "rc=1"; eq "C4 timeout: ${f%% *} prints nothing" "$OUTS" ""
done
eq "C5 fa_mode with no row prints log" "$(lib "$H0" 'fa_mode p-c-none')" log
setrow flow_agent.project.p-c-act.mode act; setrow flow_agent.project.p-c-junk.mode Act
eq "C5 fa_mode with act prints act" "$(lib "$H0" 'fa_mode p-c-act')" act
eq "C5 fa_mode with junk prints log" "$(lib "$H0" 'fa_mode p-c-junk')" log
OUT=$(lib "$H0" 'fa_nudge fixture-org/p-c FX-77 "$1" untriaged; echo "rc=$?"' "$(iso_ago 30)")
eq "C6 a first nudge is rc 0" "$OUT" "rc=0"
EP12=$(printf '%s' "$(iso_ago 30)" | sha256sum | cut -c1-12)
MIN=$(SQL "SELECT minute, key FROM wakes WHERE repo='fixture-org/p-c'" | jq -r '.[0].minute')
eq "C6 the dedupe is flow:<key lowercased>:<episode12>" "$MIN" "nudge:flow:fx-77:$EP12"
[ "${#MIN}" -le 70 ] && ok "C6 the dedupe is at most 64 chars" || bad "C6 dedupe too long: $MIN"
OUT=$(lib "$H0" 'fa_nudge fixture-org/p-c FX-77 "$1" untriaged; echo "rc=$?"' "$(iso_ago 30)")
eq "C6 the same nudge again is rc 9 (inserted 0)" "$OUT" "rc=9"
OUT=$(JOBS_URL="$S409" lib "$H0" 'fa_nudge fixture-org/p-c FX-77 ep untriaged; echo "rc=$?"')
eq "C6 a 409 nudge is rc 9" "$OUT" "rc=9"
eq "C decision key formula" "$(lib "$H0" 'fa_decision_key p-c FX-1 ready_not_queued ep')" "$DK"

# ── O1: the observable outcome ──────────────────────────────────────────────
echo "O: observable outcome"
issues p-o1 11
ffw_seed_ticket p-o1 FX-11 ready "$(iso_ago 30)"
run_lane "$H0" run --project p-o1; RC=$?
eq "O1 run rc" "$RC" 0
W=$(SQL "SELECT ticket_key, cause_code, episode, since, evidence FROM flow_waiting WHERE project='p-o1'")
eq "O1 one flow_waiting row" "$(jq 'length' <<<"$W")" 1
eq "O1 its cause_code is ready_not_queued" "$(jq -r '.[0].cause_code' <<<"$W")" ready_not_queued
A=$(actions_of p-o1)
eq "O1 one flow_actions row" "$(jq 'length' <<<"$A")" 1
eq "O1 its outcome is would" "$(jq -r '.[0].outcome' <<<"$A")" would
has "O1 the act line" 'code=ready_not_queued action=ready_not_queued outcome=would before=[^ ]+ after=[^ ]+' "$(actline "$H0" p-o1 FX-11)"

# ── K5: the round trip (O1's record, read back) ─────────────────────────────
eq "K5 the waiting row's key" "$(jq -r '.[0].ticket_key' <<<"$W")" FX-11
eq "K5 the episode is the verdict's triaged_at" "$(jq -r '.[0].episode' <<<"$W")" "$(iso_ago 30)"
eq "K5 since is the verdict's triaged_at" "$(jq -r '.[0].since' <<<"$W")" "$(iso_ago 30)"
eq "K5 the evidence is the state string" "$(jq -r '.[0].evidence' <<<"$W")" "verdict:ready,queue:none,job:0,pr:none"
eq "K5 the claim carried the same episode" "$(jq -r '.[0].episode' <<<"$A")" "$(iso_ago 30)"

# ── L6: the two log lines, field by field ───────────────────────────────────
S=$(summary "$H0" p-o1)
has "L6 the summary line" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z tick p-o1 mode=log trigger=manual tickets=1 codes=ready_not_queued:1 actions=0 refused=0 truncated=0$' "$S"
has "L6 the act line" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z act p-o1 FX-11 code=ready_not_queued action=ready_not_queued outcome=would before=verdict:ready,queue:none,job:0,pr:none after=verdict:ready,queue:none,job:0,pr:none$' "$(actline "$H0" p-o1 FX-11)"

# ── D1-D14: the decision table ──────────────────────────────────────────────
echo "D: decision table"
# key -> case: 101 D1, 102 D2, 103 D3, 9956 D4, 105 D5, 106 D6, 107 D7, 108 D8,
# 109 D9, 110 D10, 111 D11, 114 D14.
issues p-dt 101 102 103 9956 105 106 107 108 109 110 111 114
prs p-dt ticket/fx-99560 ticket/fx-108-r2 ticket/fx-1080
ffw_seed_ticket p-dt FX-101 ready "$(iso_ago 30)"
ffw_seed_ticket p-dt FX-102 buildable "$(iso_ago 21)"
ffw_seed_ticket p-dt FX-103 ready "$(iso_ago 20)"
ffw_seed_ticket p-dt FX-9956 ready "$(iso_ago 30)"
ffw_seed_ticket p-dt FX-105 ready "$(iso_ago 30)" queued
ffw_seed_ticket p-dt FX-106 ready "$(iso_ago 10)"
ffw_seed_ticket p-dt FX-107 ready "$(iso_ago 30)" done
ffw_seed_ticket p-dt FX-108 ready "$(iso_ago 30)"
ffw_sql "INSERT INTO triage_state (project, ticket_key, input_hash, verdict, waiting_on, verdict_hash, triaged_at, updated_at) VALUES ('p-dt','FX-109','h2','ready','team','h1',?,?)" "$(iso_ago 30)" "$(iso_ago 30)" >/dev/null
ffw_sql "INSERT INTO triage_state (project, ticket_key, input_hash, verdict, waiting_on, verdict_hash, triaged_at, updated_at) VALUES ('p-dt','FX-110','h1','needs_clarification','client','h1',?,?)" "$(iso_ago 30)" "$(iso_ago 30)" >/dev/null
ffw_seed_ticket p-dt FX-111 'READY ' "$(iso_ago 30)"
ffw_seed_ticket p-dt FX-114 ready "$(iso_ago 30)" - running
CAUSES=$(lib "$H0" 'flow_collect p-dt > "$HARNESS/dt.jsonl" || echo "collect-rc=$?"; while IFS= read -r l; do printf "%s %s\n" "$(jq -r .key <<<"$l")" "$(flow_cause <<<"$l")"; done < "$HARNESS/dt.jsonl"')
code_of() { awk -v k="$1" '$1 == k {print $2}' <<<"$CAUSES"; }
eq "D1 (O4) ready 30 min, no queue row, job or PR" "$(code_of FX-101)" ready_not_queued
eq "D2 buildable 21 min" "$(code_of FX-102)" ready_not_queued
eq "D3 exactly 20 min" "$(code_of FX-103)" ready_not_queued
eq "D4 a PR ticket/fx-99560 is not FX-9956's" "$(code_of FX-9956)" ready_not_queued
eq "D5 (N3) a queued row" "$(code_of FX-105)" not_stalled
eq "D6 (N4) triaged 10 min ago" "$(code_of FX-106)" not_stalled
eq "D7 a done queue row" "$(code_of FX-107)" unknown
eq "D8 an open PR ticket/fx-108-r2" "$(code_of FX-108)" not_stalled
eq "D9 a stale verdict (verdict_hash != input_hash)" "$(code_of FX-109)" not_stalled
eq "D10 waiting on the client: no record" "$(code_of FX-110)" ""
eq "D11 verdict 'READY ' is normalized" "$(code_of FX-111)" ready_not_queued
eq "D14 a running job: no record" "$(code_of FX-114)" ""
eq "D the record count (12 issues, 2 not records)" "$(wc -l < "$H0/dt.jsonl" | tr -d ' ')" 10
REC=$(grep '"key":"FX-108"' "$H0/dt.jsonl")
eq "D8 the record names the PR" "$(jq -r '.open_pr.head' <<<"$REC")" ticket/fx-108-r2
eq "D4 the record has no PR" "$(jq -r '.open_pr' <<<"$(grep '"key":"FX-9956"' "$H0/dt.jsonl")")" null
GH=$(cat "$T/ffw-gh.log")
has "D the issue read asks for open ai-build issues only (a closed one is never read)" 'repos/fixture-org/p-dt/issues .*state=open.*labels=ai-build|repos/fixture-org/p-dt/issues .*labels=ai-build.*state=open' "$GH"
# D12: the PR list is full on its last page.
issues p-d12 121
ffw_seed_ticket p-d12 FX-121 ready "$(iso_ago 30)"
setrow flow_agent.pr_list_pages 1
jq -nc '[range(0;100) | {number: (1000 + .), head: {ref: ("ticket/other-" + (. | tostring))}}]' > "$T/ffw-gh/p-d12/pulls.1.json"
OUT=$(lib "$H0" 'flow_collect p-d12 | while IFS= read -r l; do flow_cause <<<"$l"; done')
eq "D12 a full last PR page gives inputs_unreadable" "$OUT" inputs_unreadable
setrow flow_agent.pr_list_pages 3
# D13: the PR read fails.
issues p-d13 131
ffw_seed_ticket p-d13 FX-131 ready "$(iso_ago 30)"
echo 500 > "$T/ffw-gh/p-d13/pulls.status"
OUT=$(lib "$H0" 'flow_collect p-d13 > "$HARNESS/d13.jsonl"; echo "rc=$?"; while IFS= read -r l; do flow_cause <<<"$l"; done < "$HARNESS/d13.jsonl"')
eq "D13 pr unread gives inputs_unreadable (the pass goes on)" "$OUT" $'rc=0\ninputs_unreadable'
eq "D13 the record marks pr unread" "$(jq -c '.unread' "$H0/d13.jsonl")" '["pr"]'
# A ready verdict with a queued row and an unreadable PR list: not a ready_not_queued, never unreadable.
issues p-d13 131 132
ffw_seed_ticket p-d13 FX-132 ready "$(iso_ago 30)" queued
OUT=$(lib "$H0" 'flow_collect p-d13 | while IFS= read -r l; do printf "%s %s\n" "$(jq -r .key <<<"$l")" "$(flow_cause <<<"$l")"; done')
has "D13 a queued ticket is not_stalled even with the PR list unread" '^FX-132 not_stalled$' "$OUT"

# ── K1-K4, K6: collect ──────────────────────────────────────────────────────
echo "K: collect"
issues p-k1 1 2 3
ffw_seed_ticket p-k1 FX-1 ready "$(iso_ago 30)"
: > "$FFW_WLOG"
run_lane "$H0" run --project p-k1
eq "K1 one pass sends exactly 1 POST /api/waiting/state" "$(grep -c '^POST /api/waiting/state ' "$FFW_WLOG")" 1
eq "K1 and exactly 1 PUT /api/flow-agent/waiting" "$(grep -c '^PUT /api/flow-agent/waiting 200' "$FFW_WLOG")" 1
issues p-k2 5
echo 500 > "$T/ffw-gh/p-k2/issues.status"
OUT=$(lib "$H0" 'flow_collect p-k2; echo "rc=$? why=$FA_COLLECT_WHY"')
eq "K2 a failed issues read: rc 1, 0 records" "$OUT" "rc=1 why=board-read"
# K3: an in-app board.
cat > "$T/ffw-board/boards.json" <<'EOF'
[{"id":"board-1","keyPrefix":"KT","name":"Product"}]
EOF
jq -nc --arg at "$(iso_ago 60)" '[
  {id:"t-1", number:1, title:"one", status:"todo", triageVerdict:"ready", waitingOn:"team", updatedAt:$at},
  {id:"t-2", number:2, title:"two", status:"done", triageVerdict:"ready", updatedAt:$at},
  {id:"t-3", number:3, title:"three", status:"todo", triageVerdict:"ready", waitingOn:"team", updatedAt:$at},
  {id:"t-4", number:4, title:"four", status:"todo", triageVerdict:"ready", waitingOn:"client", updatedAt:$at}]' > "$T/ffw-board/tickets.json"
ffw_seed_ticket kthree KT-1 ready "$(iso_ago 30)"
ffw_seed_ticket kthree KT-3 needs_clarification "$(iso_ago 25)"
OUT=$(lib "$H0" 'flow_collect kthree > "$HARNESS/k3.jsonl"; echo "rc=$?"; while IFS= read -r l; do printf "%s %s %s\n" "$(jq -r .key <<<"$l")" "$(jq -r .id <<<"$l")" "$(flow_cause <<<"$l")"; done < "$HARNESS/k3.jsonl"')
eq "K3 the in-app board: board keys and ids; done and client tickets dropped" "$OUT" $'rc=0\nKT-1 t-1 ready_not_queued\nKT-3 t-3 unknown'
has "K3 the board read carried the board token" '/x/boards/board-1/tickets Bearer tok-fixture-kthree' "$(cat "$T/ffw-board/requests.log")"
# K4: a collect.d collector is called; a failing one marks its area unread.
HK4=$(clone hk4)
issues p-k4 41
printf '#!/bin/bash\n# owner: fixture\nflow_collect_zz() { local t; t=$(mktemp); jq -c ".zz = 1" "$1" > "$t" && mv "$t" "$1"; }\n' > "$HK4/bin/lib/flow-agent/collect.d/zz.sh"
OUT=$(lib "$HK4" 'flow_collect p-k4 | jq -c "[.zz, .unread]"')
eq "K4 flow_collect_zz ran on the record" "$OUT" '[1,[]]'
printf '#!/bin/bash\n# owner: fixture\nflow_collect_zz() { return 1; }\n' > "$HK4/bin/lib/flow-agent/collect.d/zz.sh"
OUT=$(lib "$HK4" 'flow_collect p-k4 | jq -c ".unread"')
eq "K4 a failing collector adds its area to unread" "$OUT" '["zz"]'
# K6: more open tickets than waiting_max.
HK6=$(clone hk6)
issues p-k6 61 62 63
setrow flow_agent.waiting_max 2
run_lane "$HK6" run --project p-k6
has "K6 three open tickets, waiting_max 2: truncated=1" ' tick p-k6 .*tickets=2 .*truncated=1$' "$(summary "$HK6" p-k6)"
setrow flow_agent.waiting_max 500
# K7: an open-issue list that fills all of its pages is flagged, never silent.
issues p-k7 71
run_lane "$H0" run --project p-k7
hasnt "K7 a short issue list: no board-truncated line" ' board-truncated p-k7 ' "$(cat "$H0/logs/flow-agent.log")"
setrow flow_agent.issue_list_pages 1
jq -nc --arg at "$(iso_ago 60)" '[range(1;101) | {number: ., title: "t", html_url: null, state: "open", updated_at: $at}]' > "$T/ffw-gh/p-k7/issues.1.json"
run_lane "$H0" run --project p-k7
setrow flow_agent.issue_list_pages 5
has "K7 a full issue list (1 page of 100): a board-truncated line" ' board-truncated p-k7 the open-issue list filled flow_agent.issue_list_pages$' "$(cat "$H0/logs/flow-agent.log")"

# ── L1-L8: the lane ─────────────────────────────────────────────────────────
echo "L: lane"
HL1=$(clone hl1)
issues p-l1 1
ffw_seed_ticket p-l1 FX-1 ready "$(iso_ago 30)"
setrow flow_agent.enabled 0
: > "$FFW_WLOG"; : > "$T/ffw-gh.log"
run_lane "$HL1" run --project p-l1; RC=$?
eq "L1 enabled=0: rc 0" "$RC" 0
has "L1 enabled=0: an off line" ' off p-l1 flow_agent.enabled=0$' "$(cat "$HL1/logs/flow-agent.log")"
eq "L1 enabled=0: no flow-agent or waiting call" "$(grep -cE '/api/(flow-agent|waiting)/' "$FFW_WLOG")" 0
eq "L1 enabled=0: no gh call" "$(wc -l < "$T/ffw-gh.log" | tr -d ' ')" 0
ffw_sql "DELETE FROM settings WHERE key='flow_agent.enabled'" >/dev/null
run_lane "$HL1" run --project p-l1
has "L1 no enabled row is off too" ' off p-l1 flow_agent.enabled has no row$' "$(cat "$HL1/logs/flow-agent.log")"
setrow flow_agent.enabled 1
HL2=$(clone hl2)
issues p-l2 1
: > "$HL2/flags/lane-off-flow-agent"; : > "$T/ffw-gh.log"
run_lane "$HL2" run --project p-l2; RC=$?
eq "L2 flags/lane-off-flow-agent: rc 0" "$RC" 0
eq "L2 the flag stops the lane before any read (0 gh calls)" "$(wc -l < "$T/ffw-gh.log" | tr -d ' ')" 0
eq "L2 no tick line" "$(summary "$HL2" p-l2)" ""
HL3=$(clone hl3)
issues p-l3 1
: > "$T/ffw-gh.log"
JOBS_URL="$S500" run_lane "$HL3" run --project p-l3; RC=$?
eq "L3 unreadable settings: rc 0" "$RC" 0
has "L3 unreadable settings: could-not-run settings" ' could-not-run settings p-l3$' "$(cat "$HL3/logs/flow-agent.log")"
eq "L3 no collect (0 gh calls)" "$(wc -l < "$T/ffw-gh.log" | tr -d ' ')" 0
issues p-l4 1
ffw_seed_ticket p-l4 FX-1 ready "$(iso_ago 30)"
exec 8>"$H0/locks/flow-agent-p-l4.lock"; flock -n 8
run_lane "$H0" run --project p-l4
exec 8>&-
has "L4 a held lock: skip p-l4 locked" ' skip p-l4 locked$' "$(cat "$H0/logs/flow-agent.log")"
eq "L4 a held lock: 0 claims" "$(actions_of p-l4 | jq 'length')" 0
run_lane "$H0" run --project p-l4
eq "L4 the lock is released after the holder: the next pass claims" "$(actions_of p-l4 | jq 'length')" 1
issues p-l5 1
ffw_seed_ticket p-l5 FX-1 ready "$(iso_ago 30)"
echo 503 > "$T/ffw-gh/p-l5/issues.status"
: > "$FFW_WLOG"
run_lane "$H0" run --project p-l5; RC=$?
eq "L5 a failed board read: rc 0" "$RC" 0
has "L5 a failed board read: could-not-run" ' could-not-run p-l5 board-read$' "$(cat "$H0/logs/flow-agent.log")"
eq "L5 no PUT /api/flow-agent/waiting" "$(grep -c '^PUT /api/flow-agent/waiting' "$FFW_WLOG")" 0
eq "L5 no claim" "$(actions_of p-l5 | jq 'length')" 0
issues p-l7 1
ffw_seed_ticket p-l7 FX-1 ready "$(iso_ago 30)"
: > "$FFW_WLOG"; : > "$T/ffw-gh.log"
run_lane "$H0" tick --project p-l7; RC=$?
eq "L7 tick rc" "$RC" 0
has "L7 tick writes trigger=none" ' tick p-l7 trigger=none$' "$(cat "$H0/logs/flow-agent.log")"
eq "L7 tick runs no pass (0 flow-agent or waiting calls)" "$(grep -cE '/api/(flow-agent|waiting)/' "$FFW_WLOG")" 0
eq "L7 tick runs no pass (0 gh calls)" "$(wc -l < "$T/ffw-gh.log" | tr -d ' ')" 0
project-10-c=$(clone project-10-c)
printf 'p-l7 fixture-org/p-l7 - - 0 fixture-box\np-l7-other fixture-org/p-l7-other - - 0 other-box\n' > "$project-10-c/fleet.conf"
: > "$T/ffw-gh.log"
FLEET_CONF="$project-10-c/fleet.conf" run_lane "$project-10-c" tick; RC=$?
eq "L7 tick with no --project: rc 0" "$RC" 0
eq "L7 tick with no --project reads this box's projects only" "$(grep -c ' tick p-l7 trigger=none$' "$project-10-c/logs/flow-agent.log")|$(grep -c 'p-l7-other' "$project-10-c/logs/flow-agent.log")" '1|0'
run_lane "$H0" run 2>/dev/null; eq "L8 run with no --project exits 2" "$?" 2
run_lane "$H0" bogus 2>/dev/null; eq "L8 an unknown verb exits 2" "$?" 2

# ── A1-A8: act ──────────────────────────────────────────────────────────────
echo "A: act"
HA1=$(clone ha1); counting_arm "$HA1"
issues p-a1 1
ffw_seed_ticket p-a1 FX-1 ready "$(iso_ago 30)"
run_lane "$HA1" run --project p-a1
A=$(actions_of p-a1)
eq "A1 no mode row runs log: one row, outcome would" "$(jq -c '[.[].outcome]' <<<"$A")" '["would"]'
eq "A1 log mode: 0 arm calls" "$(wc -l < "$HA1/arm.calls" | tr -d ' ')" 0
has "A1 the summary says mode=log actions=0" ' tick p-a1 mode=log .*actions=0 refused=0' "$(summary "$HA1" p-a1)"
run_lane "$HA1" run --project p-a1
eq "A3 a second log pass: still one would row" "$(actions_of p-a1 | jq -c '[.[].outcome]')" '["would"]'
has "A3 the second pass logs already" 'act p-a1 FX-1 code=ready_not_queued action=ready_not_queued outcome=already ' "$(actline "$HA1" p-a1 FX-1)"
eq "A3 and still 0 arm calls" "$(wc -l < "$HA1/arm.calls" | tr -d ' ')" 0
# A4w: the would row is claimed on its own key (plan ASSUMPTIONS A4), so a
# flip from log to act still acts on the same episode.
eq "A4w the would key is sha256(p|KEY|code|episode|would)" "$(actions_of p-a1 | jq -r '.[0].decision_key')" "$(printf 'p-a1|FX-1|ready_not_queued|%s|would' "$(iso_ago 30)" | sha256sum | cut -d' ' -f1)"
setrow flow_agent.project.p-a1.mode act
run_lane "$HA1" run --project p-a1
eq "A4w a flip to act on the same episode: the would row plus a done row, 1 arm call" "$(actions_of p-a1 | jq -c '[.[].outcome]')|$(wc -l < "$HA1/arm.calls" | tr -d ' ')" '["would","done"]|1'
HA2=$(clone ha2); counting_arm "$HA2"
issues p-a2 1
ffw_seed_ticket p-a2 FX-1 ready "$(iso_ago 30)"
setrow flow_agent.project.p-a2.mode act
# The action row is per code, not per project: it is set to 0 for this one
# pass and back to its seed value 1 right after it.
setrow flow_agent.action.ready_not_queued 0
run_lane "$HA2" run --project p-a2
setrow flow_agent.action.ready_not_queued 1
eq "A2 mode act + action row 0: outcome would" "$(actions_of p-a2 | jq -c '[.[].outcome]')" '["would"]'
eq "A2 and 0 arm calls" "$(wc -l < "$HA2/arm.calls" | tr -d ' ')" 0
HA4=$(clone ha4); counting_arm "$HA4"
issues p-a4 1
ffw_seed_ticket p-a4 FX-1 ready "$(iso_ago 30)"
setrow flow_agent.project.p-a4.mode act
run_lane "$HA4" run --project p-a4
A=$(actions_of p-a4)
eq "A4 the decision key is sha256(p|KEY|code|episode)" "$(jq -r '.[0].decision_key' <<<"$A")" "$(printf 'p-a4|FX-1|ready_not_queued|%s' "$(iso_ago 30)" | sha256sum | cut -d' ' -f1)"
eq "A4 act mode: the arm ran once, outcome done" "$(jq -c '[.[].outcome]' <<<"$A")|$(wc -l < "$HA4/arm.calls" | tr -d ' ')" '["done"]|1'
has "A4 the act line has the arm's after state" 'outcome=done before=verdict:ready,queue:none,job:0,pr:none after=verdict:ready,queue:queued,job:0,pr:none$' "$(actline "$HA4" p-a4 FX-1)"
has "A4 the summary counts the action" ' tick p-a4 mode=act .*actions=1 refused=0' "$(summary "$HA4" p-a4)"
run_lane "$HA4" run --project p-a4
eq "A4 a second act pass: claim 409, 0 more arm calls" "$(actions_of p-a4 | jq 'length')|$(wc -l < "$HA4/arm.calls" | tr -d ' ')" '1|1'
has "A4 the second pass logs already" 'outcome=already ' "$(actline "$HA4" p-a4 FX-1)"
HA5=$(clone ha5); counting_arm "$HA5"
printf '#!/bin/bash\n# owner: fixture\nflow_gates() { echo "held paused"; }\n' > "$HA5/bin/lib/flow-agent/gates.sh"
issues p-a5 1
ffw_seed_ticket p-a5 FX-1 ready "$(iso_ago 30)"
setrow flow_agent.project.p-a5.mode act
run_lane "$HA5" run --project p-a5
has "A5 a held gate: outcome held, gate named" 'outcome=held .* gate=held_paused$' "$(actline "$HA5" p-a5 FX-1)"
eq "A5 no claim, no arm" "$(actions_of p-a5 | jq 'length')|$(wc -l < "$HA5/arm.calls" | tr -d ' ')" '0|0'
issues p-a6 1
ffw_seed_ticket p-a6 FX-1 ready "$(iso_ago 30)"
setrow flow_agent.project.p-a6.mode act
run_lane "$H0" run --project p-a6
eq "A6 the placeholder arm: refused not-built" "$(actions_of p-a6 | jq -c '[.[] | [.outcome, .detail]]')" '[["refused","not-built"]]'
has "A6 the summary counts it refused" ' tick p-a6 mode=act .*actions=1 refused=1' "$(summary "$H0" p-a6)"
HA7=$(clone ha7); counting_arm "$HA7"
issues p-a7 1
ffw_seed_ticket p-a7 FX-1 ready "$(iso_ago 30)" done
setrow flow_agent.project.p-a7.mode act
run_lane "$HA7" run --project p-a7
eq "A7 unknown: one diagnose line" "$(grep -c ' diagnose p-a7 FX-1 not-built$' "$HA7/logs/flow-agent.log")" 1
eq "A7 unknown: 0 claims, 0 arms" "$(actions_of p-a7 | jq 'length')|$(wc -l < "$HA7/arm.calls" | tr -d ' ')" '0|0'
eq "A7 the waiting row says unknown" "$(SQL "SELECT cause_code FROM flow_waiting WHERE project='p-a7'" | jq -r '.[0].cause_code')" unknown
eq "A8 the fake gh saw no write (POST/PATCH/PUT/DELETE)" "$(grep -cE -- '-X (POST|PATCH|PUT|DELETE)' "$T/ffw-gh.log")" 0
eq "A8 ticket_edges is unchanged (0 rows)" "$(SQL "SELECT COUNT(*) AS n FROM ticket_edges" | jq -r '.[0].n')" 0

# ── B1 ──────────────────────────────────────────────────────────────────────
eq "B1 no network call outside 127.0.0.1" "$(cat "$T/ffw-net.log")" ""
eq "B1 no model call" "$(cat "$T/ffw-model.log")" ""

echo "flow-agent-tracer: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
