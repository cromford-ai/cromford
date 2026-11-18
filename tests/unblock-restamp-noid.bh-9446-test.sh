#!/bin/bash
# tests/unblock-restamp-noid.bh-9446-test.sh — BH-9446 (scope 5): an open lead
# request with no id is read as not open. The queue collector carries the
# matched request's id as lead_request_id (null: no match, unread, or no id);
# U13-RESTAMP also matches lead_request_open true with lead_request_id null;
# the tick logs `lead-request-noid` once, on the new claim.
#
#   N1  the record {pr-verdict-old-head, MERGE, lead_request_open true,
#       lead_request_id null, request_id "none", idle 30 of 20} through the
#       real rules: act U13-RESTAMP lead_rerequest, request_id none.
#   N2  the real queue collector (#8136 fixture) with an open request for the
#       head that has no id, an id "" or an id "none": the record has
#       lead_request_open true, lead_request_id null, and the decision is
#       U13-RESTAMP.
#   N3  negatives: an id lr-1 (the record carries it) -> no RESTAMP; open
#       null -> no RESTAMP; a record with no lead_request_id key and open true
#       (a record from before this change) -> escalate U12, as on main.
#   N4  the SHIPPED tick: 2 ticks over the N1 record (claim 200, then 409):
#       exactly one lead-request-noid line, with the subject and head12; an
#       open request WITH an id logs nothing.
#   B   0 non-GET gh calls, 0 model or network calls.
#
# MUTATIONS (D1), each tried once by hand: keep U13-RESTAMP's old predicate
# -> N1, N2 red; read any open request as id-less -> N3 red; log on every
# tick, not only on the new claim -> N4 red; drop lead_request_id from the
# collector -> N2 red.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/unblock-restamp-noid.bh-9446-test.sh
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
RULES="$SRC/catalog/unblock-rules.d"
FX="$SRC/tests/fixtures/unblock-rules-u13/review-stalls.json"
H8136="c7ace3fb$(printf '1%.0s' $(seq 1 32))"
NOW=$(date -u -d '2026-11-10T12:00:00Z' +%s)

mkdir -p "$T/pathbin"
# gh: answers GETs from $GH_FX (the u13 fixture's .gh map), logs every call,
# refuses writes. Never the network.
cat > "$T/pathbin/gh" <<'SH'
#!/bin/bash
m=GET; p=; hdr=0
while [ $# -gt 0 ]; do
  case "$1" in api) ;; -i) hdr=1 ;; -X) m="$2"; shift ;; -H|--input|-F|-f) shift ;; *) p="$1" ;; esac
  shift
done
echo "$m $p" >> "$GH_LOG"
if [ "$m" != GET ] || [ -z "${GH_FX:-}" ]; then [ "$hdr" = 1 ] && printf 'HTTP/2 405\r\n\r\n'; echo '{"message":"fixture: refused"}'; exit 1; fi
if jq -e --arg p "$p" '.gh | has($p)' "$GH_FX" >/dev/null; then
  [ "$hdr" = 1 ] && printf 'HTTP/2 200\r\ncontent-type: application/json\r\n\r\n'; jq -c --arg p "$p" '.gh[$p]' "$GH_FX"; exit 0
fi
[ "$hdr" = 1 ] && printf 'HTTP/2 404\r\ncontent-type: application/json\r\n\r\n'; echo '{"message":"Not Found"}'; exit 1
SH
for s in claude curl flyctl; do printf '#!/bin/bash\necho "%s $*" >> "%s/vendor.log"\nexit 7\n' "$s" "$T" > "$T/pathbin/$s"; done
chmod +x "$T/pathbin/"*
: > "$T/vendor.log"; : > "$T/gh.log"

ev() { (export PATH="$T/pathbin:$PATH"; . "$SRC/bin/lib/unblock/rules.sh"; HARNESS="$SRC" ub_rules_eval "$RULES"); }
dr() { jq -c "$1" <<<"$REC" | ev | jq -r '"\(.decision) \(.rule_id)"'; }
REC=$(jq -nc --arg r "$R" --arg h "$H8136" '{kind: "pr-verdict-old-head", family: "queue", project: "cromford", repo: $r,
  pr: 9345, subject: ($r + "#9345"), subject_kind: "pr", head: $h, verdict_on_head: "none", old_head: ("0" * 40),
  old_verdict: "MERGE", lead_request_open: true, lead_request_id: null, idle_min: 30, restamp_idle_min: 20,
  request_id: "none", priority: 900, labels: [], truncated: false, inputs_unreadable: []}')

# ═════ N1 ════════════════════════════════════════════════════════════════════
D=$(ev <<<"$REC")
check "N1 open with no id: act U13-RESTAMP lead_rerequest, request_id none" \
  "$(jq -c '[.decision, .rule_id, .action.name, .action.args.request_id]' <<<"$D")" '["act","U13-RESTAMP","lead_rerequest","none"]'

# ═════ N2: the real queue collector ══════════════════════════════════════════
# run_queue <name> <requests json> — ub_collect_queue | ub_rules_eval over
# the #8136 fixture, with the lead-open list replaced.
run_queue() {
  local C="$T/$1"
  mkdir -p "$C/h/logs" "$C/h/state"
  for f in bin/lib/unblock/collectors/queue.sh bin/lib/unblock/rules.sh bin/lib/unblock/signals.sh bin/lib/gh-rest.sh; do
    ( cd "$SRC" && scratch_install_closure "$f" "$C/h" ) >/dev/null || { echo "setup: closure $f" >&2; return 1; }
  done
  mkdir -p "$C/h/catalog"; cp -R "$RULES" "$C/h/catalog/unblock-rules.d"
  jq --argjson q "$2" '.lead_open.requests = $q' "$FX" > "$C/fx.json"
  (
    export HARNESS="$C/h" GH_FX="$C/fx.json" GH_LOG="$T/gh.log" PATH="$T/pathbin:$PATH" GH_ETAG=0 TMPDIR="$C"
    UNBLOCK_NOW=$(date -u -d "$(jq -r .now "$GH_FX")" +%s); export UNBLOCK_NOW
    . "$HARNESS/bin/lib/gh-rest.sh" || exit 9
    . "$HARNESS/bin/lib/unblock/collectors/queue.sh" || exit 9
    . "$HARNESS/bin/lib/unblock/rules.sh" || exit 9
    ubq_batch_drafts() { jq -c '.drafts[]' "$GH_FX"; }
    ubq_batch_failure() { jq -ce --arg d "$2" '.batch_failure[$d]' "$GH_FX"; }
    vd_standing() { local l; l=$(jq -r --arg k "$1#$2 $3" '.verdicts[$k] // empty' "$GH_FX"); [ -n "$l" ] || return 1; printf '%s\n' "$l"; }
    mc_attempt_has() { jq -e --arg l "$1" '.attempts | index($l) != null' "$GH_FX" >/dev/null; }
    mc_requeued_mark() { jq -r --arg k "$1 $2" '.requeued[$k] // empty' "$GH_FX"; }
    setting_get() { return 2; }
    pr_attempt_count() { printf '0'; return 0; }
    ubq_verdict_rows() { jq -ce --arg n "$2" '.verdict_rows[$n]' "$GH_FX"; }
    ubq_lead_open() { jq -ce '.lead_open' "$GH_FX"; }
    ub_collect_queue cromford "$R" > "$C/records.jsonl"
    HARNESS="$C/h" ub_rules_eval < "$C/records.jsonl" > "$C/decisions.jsonl"
  )
  printf '%s' "$C"
}
rec8136() { jq -c "select(.pr == 8136 and .kind == \"pr-verdict-old-head\") | $2" "$1/records.jsonl"; }
dec8136() { jq -r 'select(.pr == 8136) | "\(.decision) \(.rule_id)"' "$1/decisions.jsonl" | sort | tr '\n' ';'; }
for ID in absent '""' '"none"'; do
  if [ "$ID" = absent ]; then Q="[{\"pr\": 8136, \"head_sha\": \"$H8136\", \"status\": \"requested\"}]"
  else Q="[{\"id\": $ID, \"pr\": 8136, \"head_sha\": \"$H8136\", \"status\": \"requested\"}]"; fi
  C=$(run_queue "n2-$(printf '%s' "$ID" | tr -c 'a-z' 'x')" "$Q") || { echo "FAIL: case setup"; exit 1; }
  check "N2 [id $ID]: the record has lead_request_open true, lead_request_id null" \
    "$(rec8136 "$C" '[.lead_request_open, (has("lead_request_id")), .lead_request_id]')" '[true,true,null]'
  check "N2 [id $ID]: act U13-RESTAMP" "$(dec8136 "$C")" "act U13-RESTAMP;"
done

# ═════ N3: the negatives ═════════════════════════════════════════════════════
C=$(run_queue n3a "[{\"id\": \"lr-1\", \"pr\": 8136, \"head_sha\": \"$H8136\", \"status\": \"requested\"}]") || { echo "FAIL: case setup"; exit 1; }
check "N3 an open request with id lr-1: the record carries it" "$(rec8136 "$C" '[.lead_request_open, .lead_request_id]')" '[true,"lr-1"]'
case "$(dec8136 "$C")" in *U13-RESTAMP*) no "N3 id lr-1: no U13-RESTAMP" "$(dec8136 "$C")" ;; *) ok "N3 id lr-1: no U13-RESTAMP" ;; esac
C=$(run_queue n3b '[]') || { echo "FAIL: case setup"; exit 1; }
check "N3 no open request: open false, id null, U13-RESTAMP (as on main)" \
  "$(rec8136 "$C" '[.lead_request_open, .lead_request_id]') $(dec8136 "$C")" '[false,null] act U13-RESTAMP;'
check "N3 open null (unread): no RESTAMP, escalate U12" "$(dr '.lead_request_open = null')" "escalate U12"
check "N3 a record with no lead_request_id key, open true: escalate U12 (W8 kept)" "$(dr 'del(.lead_request_id)')" "escalate U12"
check "N3 lead_request_id lr-1, open true: escalate U12" "$(dr '.lead_request_id = "lr-1"')" "escalate U12"

# ═════ N4: the SHIPPED tick logs it once ═════════════════════════════════════
mktick() {
  local C="$T/$1" S
  mkdir -p "$C/h/env" "$C/h/state" "$C/h/logs" "$C/h/catalog/unblock-rules.d" "$C/h/catalog/prompts" "$C/fx" "$C/col"
  for S in bin/unblock.sh bin/fleet-conf.sh bin/jobs-client.sh bin/lib/unblock/rules.sh bin/lib/unblock/judge.sh bin/lib/unblock/card.sh; do
    ( cd "$SRC" && scratch_install_closure "$S" "$C/h" ) >/dev/null || { echo "setup: closure $S" >&2; return 1; }
  done
  cp "$RULES"/*.json "$C/h/catalog/unblock-rules.d/"
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
_jobs_req() {
  local k
  printf 'JOBS %s %s\n' "$1" "$2" >> "$FXT/seq.log"
  case "$1 $2" in
    "POST /api/unblock/decisions/claim")
      k=$(jq -r .decision_key <<<"$3"); mkdir -p "$FXT/seen"
      if [ -f "$FXT/seen/$k" ]; then printf '{"claimed":false,"id":1,"outcome":"would"}'; return 9; fi
      touch "$FXT/seen/$k"; printf '{"claimed":true,"id":1}'; return 0 ;;
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
tick() {
  ( env HARNESS="$1/h" FXT="$1/fx" UNBLOCK_FIXTURE="$1/fx.sh" FLEET_CONF="$1/h/fleet.conf" REGISTRY_SOURCE=file \
      UNBLOCK_COLLECTORS_DIR="$1/col" HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 LANE_GATE_NOW=$NOW LANE_GATE_CACHE_S=60 \
      UNBLOCK_TIMED=1 JOBS_URL= HARNESS_SECRET= PATH="$T/pathbin:$PATH" GH_LOG="$T/gh.log" GH_ETAG=0 TMPDIR="$1" \
      UNBLOCK_NOW="$NOW" UB_NOW="$NOW" bash "$1/h/bin/unblock.sh" tick --project cromford ) > "$1/tick.out" 2>&1
}
C=$(mktick n4) || { echo "FAIL: tick setup"; exit 1; }
printf '%s\n' "$REC" > "$C/fx/lines.jsonl"
tick "$C"; tick "$C"
check "N4 2 ticks: 2 claim POSTs (200, then 409)" "$(cnt '^JOBS POST /api/unblock/decisions/claim' "$C/fx/seq.log")" 2
check "N4 exactly one lead-request-noid line, with the subject and head12" \
  "$(grep -c " lead-request-noid $R#9345 ${H8136:0:12}: an open lead request with no id read as not open\$" "$C/h/logs/unblock.log")" 1
C=$(mktick n4b) || { echo "FAIL: tick setup"; exit 1; }
jq -c '.lead_request_id = "lr-1" | .lead_request_open = false' <<<"$REC" > "$C/fx/lines.jsonl"
tick "$C"
check "N4 a request with an id: 1 claim, 0 lead-request-noid lines" \
  "$(cnt '^JOBS POST /api/unblock/decisions/claim' "$C/fx/seq.log") $(cnt 'lead-request-noid' "$C/h/logs/unblock.log")" "1 0"

check "B 0 non-GET gh calls" "$(grep -vc '^GET ' "$T/gh.log")" 0
check "B 0 model or network calls" "$(grep -c . "$T/vendor.log")" 0
echo "unblock-restamp-noid.bh-9446: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
