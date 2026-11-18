#!/bin/bash
# tests/unblock-inputs-unreadable.bh-9446-test.sh — BH-9446 (scope 3): a U12
# escalation whose record has an unread GitHub input waits (no claim, no card)
# and is read again on the next tick. After UNBLOCK_UNREADABLE_CARD_AFTER_TICKS
# ticks in a row (default 3) the tick makes ONE card per repo, with the source
# as its subject (bin/lib/unblock/unreadable.sh ubu_fold, wired in
# bin/unblock.sh after the rules).
#
# Every case runs the SHIPPED bin/unblock.sh tick (shadow mode) over the
# shipped rules, with one fixture collector. The fixture is #8908: a
# pr-approved-idle record whose mergeable_state, checks,
# changes_requested_open and touches_tests are null, standing approval 1.
#   U1  tick 1: 0 claims, the tick line has unreadable_wait=1, the counter
#       file says 1.
#   U2  tick 2: 0 claims; one `wait inputs-unreadable` line per tick.
#   U3  tick 3: exactly 1 claim, subject source:pr-inputs:example-org/cromford,
#       stall_class inputs-unreadable, rule U12; tick 4: the same decision key
#       (the claim answers 409: one card per source).
#   U4  3 PRs on one repo and 1 on another: tick 3 makes 2 claims, not 4.
#   U5  tick 1 unread, tick 2 readable: the U4 act decision is claimed, 0
#       escalations, the counter file is deleted.
#   U6  the negative list: mergeable_state "unknown", checks "none", a ticket
#       subject with head null, a queue-unreadable record: each is still an
#       escalation claimed on tick 1.
#   U7  the counter cannot be written: the decision is kept (1 claim) and one
#       log line says so.
#   U8  UNBLOCK_UNREADABLE_CARD_AFTER_TICKS=1: the source card on tick 1.
#   B   0 gh, curl or model CLI calls.
#
# MUTATIONS (D1), each tried once by hand: drop the ubu_fold call -> U1, U4
# red; never reset the counter -> U5 red; card on ticks < N -> U1 red; one card
# per PR -> U4 red; treat "unknown" as unread -> U6 red; drop the counter write
# check -> U7 red.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/unblock-inputs-unreadable.bh-9446-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
no() { FAIL=$((FAIL + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '     %s\n' "${2:0:1500}"; return 0; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want '$3' got '$2'"; fi; }
cnt() { if [ -f "$2" ]; then grep -c -- "$1" "$2"; else echo 0; fi; }

R=example-org/cromford
NOW=$(date -u -d '2026-11-10T12:00:00Z' +%s)
mkdir -p "$T/pathbin"
for s in gh curl claude flyctl; do printf '#!/bin/bash\necho "%s $*" >> "%s/vendor.log"\nexit 7\n' "$s" "$T" > "$T/pathbin/$s"; done
chmod +x "$T/pathbin/"*
: > "$T/vendor.log"

# rec <pr> [repo] — the #8908 record: 4 null inputs.
rec() {
  jq -nc --argjson n "$1" --arg r "${2:-$R}" '{family: "queue", kind: "pr-approved-idle", project: "cromford", repo: $r,
    pr: $n, subject: "\($r)#\($n)", subject_kind: "pr", head: ("\($n)" + ("0" * (40 - ("\($n)" | length)))),
    verdict_on_head: "MERGE", verdict_at: "2026-11-10T10:00:00Z", verdict_has_notes: false, idle_min: 120,
    approved_idle_min: 20, standing_approval: "1", mergeable_state: null, checks: null, changes_requested_open: null,
    touches_tests: null, labels: [], stall_at: "2026-11-10T10:00:00Z", truncated: false,
    inputs_unreadable: ["pull", "checks", "reviews", "files"]}'
}
readable() { jq -c '.mergeable_state = "clean" | .checks = "green" | .changes_requested_open = false | .touches_tests = false | .inputs_unreadable = []'; }

# mktick <name> — the shipped tick by its closure, the shipped rules, a claim
# stub that answers 409 for a key it has seen, one fixture collector.
mktick() {
  local C="$T/$1" S
  mkdir -p "$C/h/env" "$C/h/state" "$C/h/logs" "$C/h/catalog/unblock-rules.d" "$C/h/catalog/prompts" "$C/fx" "$C/col"
  for S in bin/unblock.sh bin/fleet-conf.sh bin/jobs-client.sh bin/lib/unblock/rules.sh bin/lib/unblock/judge.sh bin/lib/unblock/card.sh; do
    ( cd "$SRC" && scratch_install_closure "$S" "$C/h" ) >/dev/null || { echo "setup: closure $S" >&2; return 1; }
  done
  cp "$SRC"/catalog/unblock-rules.d/*.json "$C/h/catalog/unblock-rules.d/"
  cp "$SRC/catalog/prompts/unblock-decide.md" "$SRC/catalog/prompts/unblock-judge.md" "$C/h/catalog/prompts/"
  : > "$C/h/env/global.env"
  printf 'cromford example-org/cromford - - 3 hub 192.0.2.10\n' > "$C/h/fleet.conf"
  rm -f "$C/h/bin/lane-alert.sh" "$C/h/bin/agent-call.sh"
  printf '#!/bin/bash\necho "ALERT $*" >> "$FXT/seq.log"\nexit 0\n' > "$C/h/bin/lane-alert.sh"
  printf '#!/bin/bash\necho "AGENTCALL $1" >> "$FXT/seq.log"\n: > "$5"\nexit 0\n' > "$C/h/bin/agent-call.sh"
  chmod +x "$C/h/bin/lane-alert.sh" "$C/h/bin/agent-call.sh"
  cat > "$C/fx.sh" <<'SH'
setting_get() { case "$1" in unblock.enabled) printf 1; return 0 ;; esac; return 2; }
lane_gate_or_exit() { return 0; }
lane_env_apply() { return 0; }
lane_role_model() { printf 'model-fixture\n'; }
gh_rest() { printf 'GHREST %s\n' "$*" >> "$FXT/seq.log"; return 75; }
job_artifact_feed() { return 1; }
_jobs_req() {
  local k n
  printf 'JOBS %s %s %s\n' "$1" "$2" "${3:-}" >> "$FXT/seq.log"
  case "$1 $2" in
    "POST /api/unblock/decisions/claim")
      k=$(jq -r .decision_key <<<"$3"); mkdir -p "$FXT/seen"
      if [ -f "$FXT/seen/$k" ]; then printf '{"claimed":false,"id":%s,"outcome":"would"}' "$(cat "$FXT/seen/$k")"; return 9; fi
      n=$(( $(cat "$FXT/id.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FXT/id.n"; echo "$n" > "$FXT/seen/$k"
      printf '{"claimed":true,"id":%s}' "$n"; return 0 ;;
    "POST /api/unblock/decisions/record") printf '{"ok":true}'; return 0 ;;
  esac
  return 1
}
SH
  printf 'ub_collect_fixture() { cat "$FXT/lines.jsonl"; }\n' > "$C/col/fixture.sh"
  jq -nc --argjson fa "$NOW" '{fetched_at: $fa, values: {"unblock.project.cromford.mode": "shadow", "unblock.enabled": "1"}, seeded: {}}' \
    > "$C/h/state/settings-cache.json"
  printf '%s' "$C"
}
# tick <case> [env...] — one shipped tick; the claim lines of THIS tick go to <case>/claims.
tick() {
  local C="$1"; shift
  : > "$C/fx/seq.log"
  ( env HARNESS="$C/h" FXT="$C/fx" UNBLOCK_FIXTURE="$C/fx.sh" FLEET_CONF="$C/h/fleet.conf" REGISTRY_SOURCE=file \
      UNBLOCK_COLLECTORS_DIR="$C/col" HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 LANE_GATE_NOW=$NOW LANE_GATE_CACHE_S=60 \
      UNBLOCK_TIMED=1 JOBS_URL= HARNESS_SECRET= PATH="$T/pathbin:$PATH" GH_ETAG=0 TMPDIR="$C" \
      UNBLOCK_NOW="$NOW" UB_NOW="$NOW" "$@" bash "$C/h/bin/unblock.sh" tick --project cromford ) > "$C/tick.out" 2>&1
  grep '^JOBS POST /api/unblock/decisions/claim ' "$C/fx/seq.log" | sed 's/^JOBS POST [^ ]* //' > "$C/claims"
}
nclaims() { grep -c . "$1/claims"; }
tickline() { grep ' tick cromford mode=' "$1/h/logs/unblock.log" | tail -n 1; }
counter() { cat "$1/h/state/unblock-unreadable/cromford-${2//\//__}" 2>/dev/null | cut -d' ' -f1; }

# ═════ U1-U3: the #8908 fixture over 4 ticks ═════════════════════════════════
C=$(mktick u1) || { echo "FAIL: tick setup"; exit 1; }
rec 8908 > "$C/fx/lines.jsonl"
tick "$C"
check "U1 tick 1: 0 claims" "$(nclaims "$C")" 0
case "$(tickline "$C")" in *" claimed=0 "*"unreadable_wait=1"*) ok "U1 the tick line: claimed=0 unreadable_wait=1" ;;
  *) no "U1 the tick line: claimed=0 unreadable_wait=1" "$(tickline "$C"); $(head -c 600 "$C/tick.out")" ;; esac
check "U1 the counter file says 1" "$(counter "$C" "$R")" 1
tick "$C"
check "U2 tick 2: 0 claims, the counter says 2" "$(nclaims "$C") $(counter "$C" "$R")" "0 2"
check "U2 one wait line per tick, with the fields and the tick" \
  "$(grep -c "wait inputs-unreadable $R: 1 PR(s) (changes_requested_open,checks,mergeable_state) unread, tick [12] of 3; no card" "$C/h/logs/unblock.log")" 2
tick "$C"
check "U3 tick 3: exactly 1 claim" "$(nclaims "$C")" 1
check "U3 the claim: the source subject, kind inputs-unreadable, U12, escalate, the PR named" \
  "$(jq -c '[.subject, .stall_class, .decision, .subject_kind, .evidence.prs, .evidence.ticks]' "$C/claims")" \
  "[\"source:pr-inputs:$R\",\"inputs-unreadable\",\"escalate\",\"lane\",[8908],3]"
K3=$(jq -r .decision_key "$C/claims")
tick "$C"
check "U3 tick 4: the same decision key, and the claim is not new (409)" \
  "$(jq -r .decision_key "$C/claims") $(tickline "$C" | grep -o 'claimed=[0-9]*')" "$K3 claimed=0"

# ═════ U4: one card per repo, not per PR ═════════════════════════════════════
C=$(mktick u4) || { echo "FAIL: tick setup"; exit 1; }
{ rec 8901; rec 8902; rec 8903; rec 77 example-org/project-3; } > "$C/fx/lines.jsonl"
tick "$C"; check "U4 tick 1: 0 claims, unreadable_wait=4" "$(nclaims "$C") $(tickline "$C" | grep -o 'unreadable_wait=[0-9]*')" "0 unreadable_wait=4"
tick "$C"; tick "$C"
check "U4 tick 3: 2 claims, one per repo" "$(nclaims "$C")" 2
check "U4 the two subjects" "$(jq -r .subject "$C/claims" | sort | tr '\n' ' ')" "source:pr-inputs:example-org/cromford source:pr-inputs:example-org/project-3 "
check "U4 the cromford card names its 3 PRs" "$(jq -c "select(.subject == \"source:pr-inputs:$R\") | .evidence.prs" "$C/claims")" '[8901,8902,8903]'

# ═════ U5: readable on tick 2 ════════════════════════════════════════════════
C=$(mktick u5) || { echo "FAIL: tick setup"; exit 1; }
rec 8908 > "$C/fx/lines.jsonl"; tick "$C"
check "U5 tick 1: held, counter 1" "$(nclaims "$C") $(counter "$C" "$R")" "0 1"
rec 8908 | readable > "$C/fx/lines.jsonl"; tick "$C"
check "U5 tick 2 readable: 1 claim, U4-standing-approval act queue_approve" \
  "$(jq -c '[.rule_id, .decision, .action]' "$C/claims" | tr '\n' ' ')" '["U4-standing-approval","act","queue_approve"] '
check "U5 the counter file is deleted" "$( [ -e "$C/h/state/unblock-unreadable/cromford-example-org__cromford" ] && echo kept || echo gone)" gone

# ═════ U6: the negative list ═════════════════════════════════════════════════
C=$(mktick u6) || { echo "FAIL: tick setup"; exit 1; }
{ rec 8911 | readable | jq -c '.mergeable_state = "unknown"'
  rec 8912 | readable | jq -c '.checks = "none"'
  jq -nc '{family: "infra", kind: "ticket-starved", project: "cromford", subject: "ticket:cromford:BH-9001",
    subject_kind: "build", ticket: "BH-9001", queued_min: 10, passes: 1, starve_min: 120, starve_passes: 3, triage_out: true,
    has_pr: false, head: null, day: "2026-11-10"}'
  jq -nc --arg r "$R" '{family: "queue", kind: "queue-unreadable", project: "cromford", repo: $r, input: "verdicts",
    subject: "queue:\($r):verdicts", subject_kind: "lane", mergeable_state: null, prs: [1, 2]}'; } > "$C/fx/lines.jsonl"
tick "$C"
check "U6 4 escalations claimed on tick 1, none held" "$(nclaims "$C") $(tickline "$C" | grep -c unreadable_wait)" "4 0"
check "U6 each claim is the record's own subject" "$(jq -r .subject "$C/claims" | sort | tr '\n' ' ')" \
  "$R#8911 $R#8912 queue:$R:verdicts ticket:cromford:BH-9001 "
check "U6 no counter file" "$(ls "$C/h/state/unblock-unreadable" 2>/dev/null | grep -c .)" 0

# ═════ U7: the counter cannot be written ═════════════════════════════════════
C=$(mktick u7) || { echo "FAIL: tick setup"; exit 1; }
rec 8908 > "$C/fx/lines.jsonl"; printf 'not a dir\n' > "$C/h/state/unblock-unreadable"
tick "$C"
check "U7 the decision is kept: 1 claim, the PR subject" "$(nclaims "$C") $(jq -r .subject "$C/claims")" "1 $R#8908"
check "U7 one log line says the counter was not written" "$(cnt "inputs-unreadable $R: counter not written" "$C/h/logs/unblock.log")" 1

# ═════ U8: the knob ══════════════════════════════════════════════════════════
C=$(mktick u8) || { echo "FAIL: tick setup"; exit 1; }
rec 8908 > "$C/fx/lines.jsonl"; tick "$C" UNBLOCK_UNREADABLE_CARD_AFTER_TICKS=1
check "U8 UNBLOCK_UNREADABLE_CARD_AFTER_TICKS=1: the source card on tick 1" "$(nclaims "$C") $(jq -r .subject "$C/claims")" "1 source:pr-inputs:$R"
C=$(mktick u8b) || { echo "FAIL: tick setup"; exit 1; }
rec 8908 > "$C/fx/lines.jsonl"; tick "$C" UNBLOCK_UNREADABLE_CARD_AFTER_TICKS=abc
check "U8 a bad knob value is the fallback 3 (no card on tick 1)" "$(nclaims "$C") $(grep -c 'tick 1 of 3' "$C/h/logs/unblock.log")" "0 1"

check "B 0 gh, curl or model CLI calls" "$(grep -c . "$T/vendor.log")" 0
echo "unblock-inputs-unreadable.bh-9446: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
