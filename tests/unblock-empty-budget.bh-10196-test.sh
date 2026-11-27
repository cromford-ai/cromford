#!/bin/bash
# tests/unblock-empty-budget.bh-10196-test.sh — BH-10196: bin/unblock.sh stops
# its tick at the first empty-budget refusal. When the persisted reading of the
# GitHub bucket says remaining 0 with a future reset, a timed tick reads,
# decides and records nothing more: no rule, no unreadable-tick count, no
# decision, no card sweep. rc 0.
#
# Every case runs the SHIPPED bin/unblock.sh tick (mode act) with the real
# gh_rest (no gh_rest stub) and a PATH `gh` stub that logs every call.
#   Z1  reading 0 before the tick: rc 0, 0 gh calls, 0 jobs calls past the
#       kill-flag reads, the
#       "stopped before collect" line, no tick line.
#   N1  after Z1, $H/state (minus the gh-rest ledger, lane-gate and the
#       settings cache) is byte-equal to the snapshot before.
#   M1  healthy at start; the first PR read by branch answers 403 with
#       X-RateLimit-Remaining 0: exactly 1 gh call, the "stopped after collect"
#       line, no claim, no unreadable-tick counter, no tick line, rc 0.
#   G1  the same records with a healthy bucket (remaining 1 on file): the tick
#       runs (tick line, counter 1), no stop line.
#   W1  reading 0 and WAKE_LAUNCH=1: the tick runs, no stop line.
#   L1  reading 0 and the settings row lane.unblock.gh_rest_empty_budget_gate=0:
#       the tick runs, no stop line.
#   B   0 curl or model CLI calls.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/unblock-empty-budget.bh-10196-test.sh
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
RESET=$((NOW + 600))
TOK=tok-fixture-unblock-10196
BKT="pat-$(printf '%s' "$TOK" | sha1sum | awk '{print $1}' | cut -c1-12)"
mkdir -p "$T/pathbin"
for s in curl claude flyctl; do printf '#!/bin/bash\necho "%s $*" >> "%s/vendor.log"\nexit 7\n' "$s" "$T" > "$T/pathbin/$s"; done
# gh: log the call; answer from $FXT/gh-answer (403 = rate limited, else 200 []).
cat > "$T/pathbin/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/gh-calls.log"
if [ "$(cat "$FXT/gh-answer" 2>/dev/null)" = 403 ]; then
  printf 'HTTP/2.0 403 Forbidden\r\nX-RateLimit-Remaining: 0\r\nX-RateLimit-Limit: 5000\r\nX-RateLimit-Reset: %s\r\n\r\n{"message":"API rate limit exceeded"}' "$GH_FX_RESET"
  exit 1
fi
printf 'HTTP/2.0 200 OK\r\n\r\n[]'
exit 0
STUB
chmod +x "$T/pathbin/"*
: > "$T/vendor.log"

# The #8908 record (a U12 escalation with unread inputs) and two ticket records
# with no PR yet (each one GitHub read by branch).
rec8908() {
  jq -nc --arg r "$R" '{family: "queue", kind: "pr-approved-idle", project: "cromford", repo: $r,
    pr: 8908, subject: "\($r)#8908", subject_kind: "pr", head: ("8908" + ("0" * 36)),
    verdict_on_head: "MERGE", verdict_at: "2026-11-10T10:00:00Z", verdict_has_notes: false, idle_min: 120,
    approved_idle_min: 20, standing_approval: "1", mergeable_state: null, checks: null, changes_requested_open: null,
    touches_tests: null, labels: [], stall_at: "2026-11-10T10:00:00Z", truncated: false,
    inputs_unreadable: ["pull", "checks", "reviews", "files"]}'
}
recticket() {
  jq -nc --arg k "$1" '{family: "infra", kind: "ticket-starved", project: "cromford", subject: "ticket:cromford:\($k)",
    subject_kind: "build", ticket: $k, queued_min: 10, passes: 1, starve_min: 120, starve_passes: 3, triage_out: true,
    head: null, day: "2026-11-10"}'
}

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
  # No gh_rest stub: the real gh_rest runs against the PATH gh stub.
  cat > "$C/fx.sh" <<'SH'
setting_get() { case "$1" in unblock.enabled) printf 1; return 0 ;; esac; return 2; }
lane_gate_or_exit() { return 0; }
lane_env_apply() { return 0; }
lane_role_model() { printf 'model-fixture\n'; }
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
  jq -nc --argjson fa "$NOW" '{fetched_at: $fa, values: {"unblock.project.cromford.mode": "act", "unblock.enabled": "1"}, seeded: {}}' \
    > "$C/h/state/settings-cache.json"
  { rec8908; recticket BH-9001; recticket BH-9002; } > "$C/fx/lines.jsonl"
  printf '%s' "$C"
}
# reading <case> <remaining> — the line _gh_quota_persist writes, for the tick's token.
reading() { mkdir -p "$1/h/state/gh-rest-ledger"; printf '%s 5000 %s %s\n' "$2" "$RESET" "$((NOW - 60))" > "$1/h/state/gh-rest-ledger/.quota-$BKT"; }
tick() {
  local C="$1"; shift
  : > "$C/fx/seq.log"; : > "$C/fx/gh-calls.log"
  RC=0
  ( env HARNESS="$C/h" FXT="$C/fx" UNBLOCK_FIXTURE="$C/fx.sh" FLEET_CONF="$C/h/fleet.conf" REGISTRY_SOURCE=file \
      UNBLOCK_COLLECTORS_DIR="$C/col" HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 LANE_GATE_NOW=$NOW LANE_GATE_CACHE_S=60 \
      LANE_GATE_RUN=unblock/cromford GH_TOKEN="$TOK" GH_FX_RESET="$RESET" GH_REST_EMPTY_NOW="$NOW" \
      UNBLOCK_TIMED=1 JOBS_URL= HARNESS_SECRET= PATH="$T/pathbin:$PATH" GH_ETAG=0 TMPDIR="$C" \
      UNBLOCK_NOW="$NOW" UB_NOW="$NOW" "$@" bash "$C/h/bin/unblock.sh" tick --project cromford ) > "$C/tick.out" 2>&1 || RC=$?
}
ghcalls() { grep -c . "$1/fx/gh-calls.log"; }
tickline() { cnt ' tick cromford mode=' "$1/h/logs/unblock.log"; }
counter() { cat "$1/h/state/unblock-unreadable/cromford-${R//\//__}" 2>/dev/null | cut -d' ' -f1; }
snap() { ( cd "$1/h/state" && find . -path ./gh-rest-ledger -prune -o -path ./lane-gate -prune -o -name settings-cache.json -prune \
  -o -type f -print0 | sort -z | xargs -0 -r sha1sum ); }
STOP0="tick cromford: GitHub core budget empty — tick stopped before collect; nothing read, decided or recorded"
STOP1="tick cromford: GitHub core budget empty — tick stopped after collect; no rule, decision, unreadable count or card sweep this tick"

# ═════ Z1 / N1: empty before the tick ═════════════════════════════════════════
C=$(mktick z1) || { echo "FAIL: tick setup"; exit 1; }
reading "$C" 0
BEFORE=$(snap "$C")
tick "$C"
check "Z1 rc 0" "$RC" 0
check "Z1 0 gh calls" "$(ghcalls "$C")" 0
check "Z1 0 jobs calls past the kill-flag reads (nothing read, decided or recorded)" "$(grep -vc '^JOBS GET /api/flags/' "$C/fx/seq.log")" 0
check "Z1 the stop-before-collect line" "$(cnt "$STOP0" "$C/h/logs/unblock.log")" 1
check "Z1 no tick line" "$(tickline "$C")" 0
check "N1 state is byte-equal before and after" "$(snap "$C")" "$BEFORE"

# ═════ M1: the first read flips the bucket to 0 ═════════════════════════════
C=$(mktick m1) || { echo "FAIL: tick setup"; exit 1; }
echo 403 > "$C/fx/gh-answer"
tick "$C"
check "M1 rc 0" "$RC" 0
check "M1 exactly 1 gh call (the first branch read)" "$(ghcalls "$C")" 1
check "M1 the stop-after-collect line" "$(cnt "$STOP1" "$C/h/logs/unblock.log")" 1
check "M1 no claim" "$(cnt 'JOBS POST /api/unblock/decisions/claim' "$C/fx/seq.log")" 0
check "M1 the unreadable-tick counter did not move" "$(counter "$C")" ""
check "M1 no tick line" "$(tickline "$C")" 0
check "M1 one [gh-empty-budget] line for the refused second read" "$(cnt '\[gh-empty-budget\] lane=unblock ' "$C/h/logs/gh-rate.log")" 1

# ═════ G1: a healthy bucket runs the tick ═══════════════════════════════════
C=$(mktick g1) || { echo "FAIL: tick setup"; exit 1; }
reading "$C" 1
tick "$C"
check "G1 rc 0, the tick line, 2 branch reads" "$RC $(tickline "$C") $(ghcalls "$C")" "0 1 2"
check "G1 the counter moved to 1" "$(counter "$C")" 1
check "G1 no stop line" "$(cnt 'GitHub core budget empty' "$C/h/logs/unblock.log")" 0

# ═════ W1: a wake-started run is never stopped ═════════════════════════════
C=$(mktick w1) || { echo "FAIL: tick setup"; exit 1; }
reading "$C" 0
tick "$C" WAKE_LAUNCH=1
check "W1 rc 0, the tick line, 2 branch reads" "$RC $(tickline "$C") $(ghcalls "$C")" "0 1 2"
check "W1 no stop line" "$(cnt 'GitHub core budget empty' "$C/h/logs/unblock.log")" 0

# ═════ L1: the lane row turns the rule off ═════════════════════════════════
C=$(mktick l1) || { echo "FAIL: tick setup"; exit 1; }
reading "$C" 0
jq -c '.values["lane.unblock.gh_rest_empty_budget_gate"] = "0"' "$C/h/state/settings-cache.json" > "$C/sc" && mv "$C/sc" "$C/h/state/settings-cache.json"
tick "$C"
check "L1 rc 0, the tick line, 2 branch reads" "$RC $(tickline "$C") $(ghcalls "$C")" "0 1 2"
check "L1 no stop line" "$(cnt 'GitHub core budget empty' "$C/h/logs/unblock.log")" 0

check "B 0 curl or model CLI calls" "$(grep -c . "$T/vendor.log")" 0
echo "unblock-empty-budget.bh-10196: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
