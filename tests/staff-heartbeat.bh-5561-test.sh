#!/bin/bash
# tests/staff-heartbeat.bh-5561-test.sh — BH-5561 (BH-5556.4): the generic
# staff heartbeat, driven through the SHIPPED bin/staff.sh tick.
#
#   H1-H2   a set kill flag (staff-off-all, staff-off-<name>) exits before any
#           read: no collector, no /api/staff request, no gh, no agent-call
#   H3-H4   no new items (all claimed elsewhere or suppressed, or an empty
#           collect) makes 0 agent-calls
#   H5      automation: one agent-call (stage staff-tick, budget env
#           folded), one digest line, no gh write, no beat, record digested
#   H6      augmentation: exactly one REST issue create labelled staff:watchman
#           with the fingerprint marker and no em dash; record filed, mode ask
#   H7      a NEVER-list action is refused with exactly one beat, at both levels
#   H8-H9   a re-run is quiet; a lost record replays from the acted file with
#           no model call and no second issue
#   H10     STAFF_MAX_ITEMS caps the claims and the prompt; the rest deferred
#   H11     an empty answer (rc 0) is billed and terminal: failed, no retry
#   H12     a soul that fails the agent-core parser stops the tick with one beat
#   H13     no model route: no call, nothing guessed
#   H14     agent-call's _budget_for reads AGENT_CALL_BUDGET_USD_STAFF_TICK for
#           the staff-tick stage
#   H15     every seeded agent has a soul that parses and may file a ticket
#   H16     tick-all reads the roster and runs each active agent once
#   H17     a bad agent name is rc 2 with no read
#   H18     agent_not_active stops the tick; malformed and staff-labelled lines
#           are skipped; an unreadable issue list or a non-201 create files
#           nothing; an unsupported action is a digest line; allow files with
#           mode auto; a level above its cap refuses
#   H19     a decided filing that GitHub refused is HELD: the next ticks retry
#           the filing only, with no model call and no attempt count, until
#           it files (autopilot review of 623ae9adc, finding 2)
#
# MUTATIONS (D1), each tried by hand once against bin/staff.sh: remove the
# kill check -> H1/H2 red; drop the NEW-empty exit -> H3 red; map an `ask`
# verdict to a digest line -> H6 red; skip the NEVER branch -> H7 red.
#
# The worker, gh and the model are stubs in the STAFF_FIXTURE file (sourced by
# bin/staff.sh after its libs, sandbox only). curl and gh on PATH log and fail,
# so nothing here reaches the network.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/staff-heartbeat.bh-5561-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "staff-heartbeat: jq is required"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "staff-heartbeat: node is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
lines() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }

for SRC in "$DIR/bin/staff.sh" "$DIR/bin/staff-core.mjs" "$DIR/catalog/prompts/staff-tick.md" \
           "$DIR/catalog/lanes.d/staff.json" "$DIR/cron/lanes/729-staff.cron"; do
  [ -r "$SRC" ] || bad "missing $SRC"
done

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"; FXT="$T/fx"
mkdir -p "$H/catalog/prompts" "$H/prompts" "$H/env" "$T/fakebin"
cp -rs "$DIR/bin" "$H/bin"
cp -rs "$DIR/agent-core" "$H/agent-core"
cp -r "$DIR/catalog/lanes.d" "$H/catalog/"
[ -d "$DIR/catalog/switches.d" ] && cp -r "$DIR/catalog/switches.d" "$H/catalog/"
cp "$DIR/catalog/prompts/staff-tick.md" "$H/catalog/prompts/" 2>/dev/null
cp -r "$DIR/prompts/staff" "$H/prompts/" 2>/dev/null
: > "$H/env/global.env"
# cp -rs made these symlinks into the checkout: remove them BEFORE writing a stub.
rm -f "$H/bin/agent-call.sh" "$H/bin/lane-alert.sh"
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
n=$(( $(cat "$FXT/ac.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FXT/ac.n"
printf '%s|%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "${AGENT_CALL_LANE:-}" "${AGENT_CALL_FP:-}" \
  "${AGENT_CALL_BUDGET_USD_STAFF_TICK:-}" >> "$FXT/ac.log"
pf="${6#@}"; cp "$pf" "$FXT/prompt-$n.md"
printf '{"type":"result","subtype":"success","total_cost_usd":0.1}' > "$5.json"
if [ -f "$FXT/answer.raw" ]; then cat "$FXT/answer.raw" > "$5"
else
  # One decision per item in the prompt, with the case's action.
  sed -n '/^## Items$/,$p' "$pf" | sed 1d \
    | jq -c --arg a "$(cat "$FXT/action")" '{decisions: [.[] | {fingerprint, action: $a,
        title: "Fixture finding title", body: "Seen at the fixture source — a human must decide."}]}' \
    | { printf 'Here is my answer.\n```json\n'; cat; printf '```\n'; } > "$5"
fi
exit "$(cat "$FXT/ac.rc" 2>/dev/null || echo 0)"
SH
cat > "$H/bin/lane-alert.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/beats.log"
exit 0
SH
chmod +x "$H/bin/agent-call.sh" "$H/bin/lane-alert.sh"
for b in curl gh; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/net.log"\nexit 7\n' "$b" "$T" > "$T/fakebin/$b"
  chmod +x "$T/fakebin/$b"
done
mkdir -p "$H/bin/staff"
cat > "$H/bin/staff/watchman-collect.sh" <<'SH'
#!/bin/bash
touch "$FXT/collected"
cat "$FXT/items.jsonl" 2>/dev/null
exit "$(cat "$FXT/collect.rc" 2>/dev/null || echo 0)"
SH
chmod +x "$H/bin/staff/watchman-collect.sh"

# The fixture: the worker (_jobs_req, _jobs_req_file), gh and the route.
# Claim answers by item id: $FXT/claim/<id> holds a mode word, else
# $FXT/claim.mode, else `new`. Modes: new | other | suppressed |
# same:<status>. The fingerprint is sha256 of the id, a 64-hex value.
cat > "$T/fx.sh" <<'SH'
fx_fp() { printf '%s' "$1" | sha256sum | cut -c1-64; }
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$FXT/req.log"
  case "$1 $2" in
    "GET /api/staff/agent?name="*)
      [ -f "$FXT/agent.json" ] || return 2
      cat "$FXT/agent.json"; return 0 ;;
    "GET /api/staff/agents") cat "$FXT/agents.json"; return 0 ;;
  esac
  return 1
}
_jobs_req_file() {
  printf '%s %s %s\n' "$1" "$2" "$(jq -c . "$3")" >> "$FXT/req.log"
  local id fp mode
  case "$2" in
    /api/staff/findings/claim)
      id=$(jq -r .item.id "$3"); fp=$(fx_fp "$id")
      mode=$(cat "$FXT/claim/$id" 2>/dev/null || cat "$FXT/claim.mode" 2>/dev/null || echo new)
      case "$mode" in
        new) printf '{"claimed":true,"fingerprint":"%s","finding":{"id":1,"agent":"watchman","status":"claimed"}}' "$fp"; return 0 ;;
        other) printf '{"claimed":false,"error":"already_claimed","fingerprint":"%s","finding":{"id":1,"agent":"inspector","status":"claimed"}}' "$fp"; return 9 ;;
        suppressed) printf '{"claimed":false,"error":"suppressed","fingerprint":"%s"}' "$fp"; return 9 ;;
        inactive) printf '{"claimed":false,"error":"agent_not_active","status":"paused"}'; return 9 ;;
        same:*) printf '{"claimed":false,"error":"already_claimed","fingerprint":"%s","finding":{"id":1,"agent":"watchman","status":"%s"}}' "$fp" "${mode#same:}"; return 9 ;;
      esac ;;
    # BH-6823: every tick past the soul check takes its chat notes; none here.
    /api/staff/chat/take) printf '{"notes":[],"failed":[]}'; return 0 ;;
    /api/staff/findings/record)
      [ -f "$FXT/record.fail" ] && return 1
      printf '{"ok":true}'; return 0 ;;
  esac
  return 1
}
gh_rest() {
  local m=$1 p=$2; shift 2
  printf '%s %s\n' "$m" "$p" >> "$FXT/gh.log"
  [ "${1:-}" = --input ] && cp "$2" "$FXT/gh-payload.json"
  GH_REST_STATUS=$(cat "$FXT/create.status" 2>/dev/null || echo 201)
  case "$GH_REST_STATUS" in 2*) ;; *) return 75 ;; esac   # gh_rest's own rc contract
  printf '{"number":7,"html_url":"https://github.com/example-org/cromford/issues/7"}\n'
  return 0
}
gh_rest_issue_list() {
  printf 'LIST %s %s %s\n' "$1" "$2" "${3:-}" >> "$FXT/gh.log"
  [ -f "$FXT/list.fail" ] && { GH_REST_STATUS=502; return 75; }
  GH_REST_STATUS=200
  cat "$FXT/issues.json" 2>/dev/null || echo '[]'
  return 0
}
lane_role_model() {
  printf 'ROUTE %s\n' "$1" >> "$FXT/req.log"
  [ -f "$FXT/route.rc" ] && return "$(cat "$FXT/route.rc")"
  printf 'stub-model\n'
}
SH

item() { # item <id> -> one collector JSONL line
  jq -cn --arg id "$1" '{item: {id: $id}, title: ("Fixture finding " + $id),
    source: {kind: "fixture", url: ("https://example.com/fx/" + $id), labels: []},
    observedAt: "2026-10-10T00:00:00Z"}'
}
fp() { printf '%s' "$1" | sha256sum | cut -c1-64; }
agent() { # agent <autonomy> [status] [cap]
  jq -cn --arg l "$1" --arg s "${2:-active}" --arg c "${3:-augmentation}" '{agent: {name: "watchman", role: "security",
    autonomy: $l, cap: $c, status: $s, soul: "prompts/staff/watchman-soul.md", lanes: []}}' \
    > "$FXT/agent.json"
}
reset() {
  local d
  for d in "$H/state" "$H/logs" "$H/flags" "$H/locks" "$FXT" "$T/net.log"; do scratch_rm "$d" || exit 1; done
  mkdir -p "$FXT/claim" "$H/flags"
  : > "$FXT/req.log"; : > "$FXT/gh.log"; : > "$FXT/ac.log"; : > "$FXT/beats.log"
  echo "file a ticket" > "$FXT/action"
  cp "$DIR/prompts/staff/watchman-soul.md" "$H/prompts/staff/watchman-soul.md" 2>/dev/null
}
tick() { # tick [mode] [agent] — the shipped entry point, sandboxed
  env HARNESS="$H" FXT="$FXT" STAFF_FIXTURE="$T/fx.sh" HARNESS_TEST_SANDBOX=1 \
    LANE_GATE_DISABLE=1 STAFF_TIMED=1 JOBS_URL= PATH="$T/fakebin:$PATH" \
    bash "$H/bin/staff.sh" "${1:-tick}" "${2:-watchman}" >"$T/out.txt" 2>&1
}
staffreq() { grep -c '/api/staff' "$FXT/req.log"; }
posts() { grep -c '^POST repos/' "$FXT/gh.log"; }
records() { grep '^POST /api/staff/findings/record ' "$FXT/req.log"; }

# ═════ H1/H2: kill flags exit before any read ════════════════════════════════
for F in staff-off-all staff-off-watchman; do
  reset; agent augmentation; item a1 > "$FXT/items.jsonl"
  touch "$H/flags/$F"
  tick; rc=$?
  eq "H kill $F rc" "$rc" 0
  [ ! -e "$FXT/collected" ] && ok || bad "H kill $F: the collector ran"
  eq "H kill $F staff requests" "$(staffreq)" 0
  eq "H kill $F gh calls" "$(lines "$FXT/gh.log")" 0
  eq "H kill $F agent-calls" "$(lines "$FXT/ac.log")" 0
  grep -q "killed by $F" "$H/logs/staff.log" 2>/dev/null && ok || bad "H kill $F: no 'killed by $F' log line"
done
# tick-all with staff-off-all reads no roster.
reset; touch "$H/flags/staff-off-all"
echo '{"agents":[{"name":"watchman","status":"active"}]}' > "$FXT/agents.json"
tick tick-all; rc=$?
eq "H2 tick-all killed rc" "$rc" 0
eq "H2 tick-all killed: no roster read" "$(staffreq)" 0

# ═════ H3: every item claimed elsewhere or suppressed -> 0 calls ═════════════
reset; agent augmentation
{ item a1; item a2; } > "$FXT/items.jsonl"
echo other > "$FXT/claim/a1"; echo suppressed > "$FXT/claim/a2"
tick; rc=$?
eq "H3 rc" "$rc" 0
eq "H3 claims" "$(grep -c 'findings/claim' "$FXT/req.log")" 2
eq "H3 agent-calls" "$(lines "$FXT/ac.log")" 0
eq "H3 gh calls" "$(lines "$FXT/gh.log")" 0
eq "H3 beats" "$(lines "$FXT/beats.log")" 0
eq "H3 records" "$(records | grep -c .)" 0

# ═════ H4: an empty collect -> 0 claims, 0 calls, no log line ════════════════
reset; agent augmentation; : > "$FXT/items.jsonl"
tick; rc=$?
eq "H4 rc" "$rc" 0
[ -e "$FXT/collected" ] && ok || bad "H4: the collector did not run"
eq "H4 claims" "$(grep -c 'findings/claim' "$FXT/req.log")" 0
eq "H4 agent-calls" "$(lines "$FXT/ac.log")" 0
eq "H4 staff.log lines" "$(lines "$H/logs/staff.log")" 0

# A collector that fails is unreadable, never clean: nothing claimed.
reset; agent augmentation; item a1 > "$FXT/items.jsonl"; echo 3 > "$FXT/collect.rc"
tick
eq "H4b failed collector claims" "$(grep -c 'findings/claim' "$FXT/req.log")" 0
grep -q 'collector rc=3' "$H/logs/staff.log" 2>/dev/null && ok || bad "H4b: no 'collector rc=3' line"

# ═════ H5: automation writes a digest line only ══════════════════════════════
# TEST-CHANGE (#5985 gate check): the call's stage is the one literal staff-tick
# (stage-route-seed R2, lane-stage-ratchet); the agent rides in AGENT_CALL_FP.
reset; agent automation; item a1 > "$FXT/items.jsonl"
tick; rc=$?
FP=$(fp a1)
eq "H5 rc" "$rc" 0
eq "H5 agent-calls" "$(lines "$FXT/ac.log")" 1
IFS='|' read -r st pj md to ln afp usd < "$FXT/ac.log"
eq "H5 stage" "$st" staff-tick
eq "H5 project" "$pj" fleet
eq "H5 model from the route" "$md" stub-model
eq "H5 lane" "$ln" staff
eq "H5 budget env" "$usd" 0.60
eq "H5 call fp" "$afp" "staff:watchman:$(printf '%s\n' "$FP" | sha256sum | cut -c1-64)"
grep -q "\"$FP\"" "$FXT/prompt-1.md" && ok || bad "H5: the prompt does not carry the fingerprint"
grep -q '^NEVER' "$FXT/prompt-1.md" && ok || bad "H5: the prompt does not carry the soul"
eq "H5 digest lines" "$(lines "$H/logs/staff-digest.log")" 1
grep -q "agent=watchman level=automation verdict=refuse action=\"file a ticket\" fp=${FP:0:12} " "$H/logs/staff-digest.log" \
  && ok || bad "H5 digest line shape: $(cat "$H/logs/staff-digest.log" 2>/dev/null)"
eq "H5 gh posts" "$(posts)" 0
eq "H5 beats" "$(lines "$FXT/beats.log")" 0
eq "H5 records" "$(records | grep -c .)" 1
eq "H5 record outcome" "$(records | sed 's/^[^{]*//' | jq -r .outcome)" digested
eq "H5 record fp" "$(records | sed 's/^[^{]*//' | jq -r .fingerprint)" "$FP"
grep -q 'model_calls=1 digested=1 filed=0' "$H/logs/staff.log" && ok || bad "H5 summary: $(cat "$H/logs/staff.log")"

# ═════ H6: augmentation makes one REST issue create ═════════════════════════
reset; agent augmentation; item a1 > "$FXT/items.jsonl"
tick; rc=$?
eq "H6 rc" "$rc" 0
eq "H6 agent-calls" "$(lines "$FXT/ac.log")" 1
eq "H6 issue creates" "$(posts)" 1
grep -q '^POST repos/example-org/cromford/issues$' "$FXT/gh.log" && ok || bad "H6 create path: $(cat "$FXT/gh.log")"
grep -q '^LIST example-org/cromford open staff:watchman$' "$FXT/gh.log" && ok || bad "H6: no marker search before the create"
eq "H6 labels" "$(jq -c .labels "$FXT/gh-payload.json" 2>/dev/null)" '["staff:watchman"]'
jq -r .body "$FXT/gh-payload.json" 2>/dev/null | grep -qF "<!-- staff-fp:$FP -->" && ok || bad "H6: no fingerprint marker in the body"
grep -q '—' <<<"$(jq -r .body "$FXT/gh-payload.json" 2>/dev/null)" && bad "H6: an em dash reached the issue body" || ok
eq "H6 title" "$(jq -r .title "$FXT/gh-payload.json" 2>/dev/null)" "Fixture finding title"
eq "H6 records" "$(records | grep -c .)" 1
R=$(records | sed 's/^[^{]*//')
eq "H6 record outcome" "$(jq -r .outcome <<<"$R")" filed
eq "H6 record mode" "$(jq -r .mode <<<"$R")" ask
eq "H6 record url" "$(jq -r .ticket_url <<<"$R")" "https://github.com/example-org/cromford/issues/7"
eq "H6 digest lines" "$(lines "$H/logs/staff-digest.log")" 0
eq "H6 beats" "$(lines "$FXT/beats.log")" 0

# An open issue that already carries the marker is reused, never created twice.
reset; agent augmentation; item a1 > "$FXT/items.jsonl"
jq -cn --arg b "x <!-- staff-fp:$FP -->" '[{number: 5, html_url: "https://github.com/example-org/cromford/issues/5", body: $b}]' > "$FXT/issues.json"
tick
eq "H6b creates with a marker hit" "$(posts)" 0
eq "H6b record url" "$(records | sed 's/^[^{]*//' | jq -r .ticket_url)" "https://github.com/example-org/cromford/issues/5"

# ═════ H7: a NEVER action is refused and makes one beat ═════════════════════
for L in augmentation automation; do
  reset; agent "$L"; item a1 > "$FXT/items.jsonl"
  echo "Print a secret value." > "$FXT/action"
  tick; rc=$?
  eq "H7 $L rc" "$rc" 0
  eq "H7 $L beats" "$(lines "$FXT/beats.log")" 1
  grep -q -- "--id staff-never-watchman-${FP:0:12} --severity warn staff " "$FXT/beats.log" \
    && ok || bad "H7 $L beat shape: $(cat "$FXT/beats.log")"
  eq "H7 $L gh posts" "$(posts)" 0
  eq "H7 $L record outcome" "$(records | sed 's/^[^{]*//' | jq -r .outcome)" refused
  eq "H7 $L digest lines" "$(lines "$H/logs/staff-digest.log")" 0
done

# ═════ H8: a re-run after a filing is quiet ═════════════════════════════════
reset; agent augmentation; item a1 > "$FXT/items.jsonl"
tick
eq "H8 first run creates" "$(posts)" 1
: > "$FXT/ac.log"; : > "$FXT/gh.log"; : > "$FXT/req.log"
echo same:filed > "$FXT/claim.mode"
tick
eq "H8 agent-calls" "$(lines "$FXT/ac.log")" 0
eq "H8 gh posts" "$(posts)" 0
eq "H8 beats" "$(lines "$FXT/beats.log")" 0
eq "H8 records" "$(records | grep -c .)" 0

# ═════ H9: a lost record replays from the acted file, no spend ══════════════
reset; agent augmentation; item a1 > "$FXT/items.jsonl"
touch "$FXT/record.fail"
tick
eq "H9 first run creates" "$(posts)" 1
[ -f "$H/state/staff/watchman/acted/$FP.json" ] && ok || bad "H9: no acted file after the filing"
rm -f "$FXT/record.fail"
: > "$FXT/ac.log"; : > "$FXT/gh.log"; : > "$FXT/req.log"
echo same:claimed > "$FXT/claim.mode"
tick
eq "H9 agent-calls" "$(lines "$FXT/ac.log")" 0
eq "H9 gh calls" "$(lines "$FXT/gh.log")" 0
eq "H9 records" "$(records | grep -c .)" 1
R=$(records | sed 's/^[^{]*//')
eq "H9 record outcome" "$(jq -r .outcome <<<"$R")" filed
eq "H9 record url" "$(jq -r .ticket_url <<<"$R")" "https://github.com/example-org/cromford/issues/7"

# ═════ H10: the item cap ════════════════════════════════════════════════════
reset; agent automation
for i in $(seq 1 25); do item "c$i"; done > "$FXT/items.jsonl"
STAFF_MAX_ITEMS=20 tick
eq "H10 claims" "$(grep -c 'findings/claim' "$FXT/req.log")" 20
eq "H10 prompt items" "$(sed -n '/^## Items$/,$p' "$FXT/prompt-1.md" | sed 1d | jq length)" 20
grep -q 'deferred=5' "$H/logs/staff.log" && ok || bad "H10: no deferred=5 line: $(cat "$H/logs/staff.log")"

# ═════ H11: an empty answer is billed and terminal ══════════════════════════
reset; agent augmentation; item a1 > "$FXT/items.jsonl"
: > "$FXT/answer.raw"
tick
eq "H11 agent-calls" "$(lines "$FXT/ac.log")" 1
eq "H11 record outcome" "$(records | sed 's/^[^{]*//' | jq -r .outcome)" failed
eq "H11 gh posts" "$(posts)" 0
: > "$FXT/ac.log"; : > "$FXT/req.log"
echo same:failed > "$FXT/claim.mode"
tick
eq "H11 rerun agent-calls" "$(lines "$FXT/ac.log")" 0

# A failed call (rc != 0) records nothing; the item comes back PENDING and is
# retried until STAFF_MAX_ATTEMPTS, then recorded failed with no call.
reset; agent augmentation; item a1 > "$FXT/items.jsonl"; echo 1 > "$FXT/ac.rc"
tick
eq "H11b records after a failed call" "$(records | grep -c .)" 0
echo same:claimed > "$FXT/claim.mode"
tick
eq "H11b retry agent-calls" "$(lines "$FXT/ac.log")" 2
: > "$FXT/req.log"
tick
eq "H11b at the cap: no third call" "$(lines "$FXT/ac.log")" 2
eq "H11b at the cap: recorded failed" "$(records | sed 's/^[^{]*//' | jq -r .outcome)" failed

# ═════ H12: a soul that fails the parser ════════════════════════════════════
reset; agent augmentation; item a1 > "$FXT/items.jsonl"
printf '# Watchman\n\nMAY:\n- file a ticket\n\nREPORT:\n- keys\n' > "$H/prompts/staff/watchman-soul.md"
tick
eq "H12 claims" "$(grep -c 'findings/claim' "$FXT/req.log")" 0
eq "H12 agent-calls" "$(lines "$FXT/ac.log")" 0
eq "H12 beats" "$(lines "$FXT/beats.log")" 1
grep -q -- '--id staff-soul-watchman ' "$FXT/beats.log" && ok || bad "H12 beat: $(cat "$FXT/beats.log")"

# ═════ H13: no model route ══════════════════════════════════════════════════
reset; agent augmentation; item a1 > "$FXT/items.jsonl"; echo 75 > "$FXT/route.rc"
tick
grep -q '^ROUTE stage.staff-tick$' "$FXT/req.log" && ok || bad "H13: the route stage.staff-tick was not asked"
eq "H13 agent-calls" "$(lines "$FXT/ac.log")" 0
grep -q 'no model route stage.staff-tick' "$H/logs/staff.log" && ok || bad "H13: no 'no model route' line"
eq "H13 records" "$(records | grep -c .)" 0

# A paused agent never collects.
reset; agent augmentation paused; item a1 > "$FXT/items.jsonl"
tick
[ ! -e "$FXT/collected" ] && ok || bad "H13b: a paused agent collected"

# ═════ H14: the staff-tick budget env ═══════════════════════════════════════
# TEST-CHANGE (lead review lr-5985 of 623ae9adc): H14 pinned a dot fold in
# _budget_for for `staff.<name>` stages. One staff-tick stage is the decision
# (the operator, 2026-10-12), so the fold had no caller and is reverted. H14 now pins
# the name the code sets: staff-tick -> AGENT_CALL_BUDGET_USD_STAFF_TICK.
BF=$(awk '/^_budget_for\(\)/{f=1} f{print} f&&/^}/{exit}' "$DIR/bin/agent-call.sh")
[ -n "$BF" ] && ok || bad "H14: _budget_for not found in bin/agent-call.sh"
eq "H14 staff-tick" "$(AGENT_CALL_BUDGET_USD_STAFF_TICK=0.42 bash -c "$BF"$'\n''_budget_for staff-tick; echo " rc=$?"' 2>&1)" "0.42 rc=0"
eq "H14 archie unchanged" "$(AGENT_CALL_BUDGET_USD_ARCHIE=0.60 bash -c "$BF"$'\n''_budget_for archie; echo " rc=$?"' 2>&1)" "0.60 rc=0"

# ═════ H15: every seeded agent has a soul that parses ═══════════════════════
SEED="$DIR/worker/jobs/schema.d/0010-bh-5559-staff-charter.sql"
NAMES=$(sed -n "/INSERT OR IGNORE INTO staff_agents/,/;/s/^  ('\([a-z][a-z0-9-]*\)','.*/\1/p" "$SEED")
eq "H15 seeded agents" "$(wc -w <<<"$NAMES" | tr -d ' ')" 7
for N in $NAMES; do
  S=$(node "$DIR/bin/staff-core.mjs" soul "$DIR/prompts/staff/$N-soul.md" 2>&1)
  jq -e '.ok == true and (.may | index("file a ticket")) != null and (.never | length) >= 7' <<<"$S" >/dev/null 2>&1 \
    && ok || bad "H15 $N soul: $S"
done
eq "H15 missing soul" "$(node "$DIR/bin/staff-core.mjs" soul "$T/nope.md" | jq -c '[.ok, .errors]')" '[false,["soul file missing"]]'
D=$(printf '%s' '{"level":"augmentation","cap":"augmentation","never":["deploy"],"decisions":[{"fingerprint":"a","action":"Deploy."},{"fingerprint":"b","action":"File a ticket"},{"fingerprint":"c","action":"sing"}]}' \
  | node "$DIR/bin/staff-core.mjs" decide)
eq "H15 decide never" "$(jq -c '[.items[] | .never]' <<<"$D")" '[true,false,false]'
eq "H15 decide verdict" "$(jq -c '[.items[] | .verdict]' <<<"$D")" '["refuse","ask","ask"]'
eq "H15 decide executable" "$(jq -c '[.items[] | .executable]' <<<"$D")" '[false,true,false]'
echo 'not json' | node "$DIR/bin/staff-core.mjs" decide >/dev/null 2>&1
eq "H15 decide bad stdin rc" "$?" 2

# ═════ H16: tick-all runs each active agent ═════════════════════════════════
reset; agent automation; item a1 > "$FXT/items.jsonl"
echo '{"agents":[{"name":"watchman","status":"active"},{"name":"clerk","status":"paused"}]}' > "$FXT/agents.json"
tick tick-all; rc=$?
eq "H16 rc" "$rc" 0
eq "H16 roster reads" "$(grep -c '^GET /api/staff/agents$' "$FXT/req.log")" 1
eq "H16 agent reads" "$(grep -c '^GET /api/staff/agent?name=' "$FXT/req.log")" 1
eq "H16 watchman agent-calls" "$(lines "$FXT/ac.log")" 1

# Bad agent name: rc 2, nothing read.
reset
tick tick 'Bad Name'; rc=$?
eq "H17 bad name rc" "$rc" 2
eq "H17 bad name requests" "$(lines "$FXT/req.log")" 0

# ═════ H18: the other branches of a tick ════════════════════════════════════
# A 409 agent_not_active stops the tick: the item claimed before it never
# reaches the model.
reset; agent augmentation; { item a1; item a2; } > "$FXT/items.jsonl"; echo inactive > "$FXT/claim/a2"
tick
eq "H18 inactive agent-calls" "$(lines "$FXT/ac.log")" 0
grep -q 'not active; tick stopped' "$H/logs/staff.log" && ok || bad "H18 inactive: no stop line"

# Malformed lines are counted and skipped; a staff:* label is dropped before
# the claim; the good line is still judged.
reset; agent automation
{ echo 'not json'; echo '{"title":"no item"}'
  jq -cn '{item: {id: "s1"}, title: "Staff-filed", source: {kind: "fixture", url: "https://example.com/fx/s1", labels: ["Staff:Watchman"]}, observedAt: "2026-10-10T00:00:00Z"}'
  item a1; } > "$FXT/items.jsonl"
tick
eq "H18 bad lines: claims" "$(grep -c 'findings/claim' "$FXT/req.log")" 1
grep -q '"id":"a1"' <<<"$(grep 'findings/claim' "$FXT/req.log")" && ok || bad "H18 bad lines: a1 was not the claim"
grep -q 'collector printed 2 malformed line(s)' "$H/logs/staff.log" && ok || bad "H18: no malformed count line"
grep -q 'dropped 1 staff-filed item(s)' "$H/logs/staff.log" && ok || bad "H18: no staff-filed drop line"
eq "H18 bad lines: agent-calls" "$(lines "$FXT/ac.log")" 1

# An open-issue list that cannot be read files nothing, and the finding stays
# claimed (no record).
reset; agent augmentation; item a1 > "$FXT/items.jsonl"; touch "$FXT/list.fail"
tick
eq "H18 list unreadable: creates" "$(posts)" 0
eq "H18 list unreadable: records" "$(records | grep -c .)" 0
grep -q 'open issue list unreadable' "$H/logs/staff.log" && ok || bad "H18: no list-unreadable line"
grep -q 'held=1' "$H/logs/staff.log" && ok || bad "H18 list unreadable: not counted held"

# A create that does not answer 201 is not a filing.
reset; agent augmentation; item a1 > "$FXT/items.jsonl"; echo 422 > "$FXT/create.status"
tick
eq "H18 create 422: creates tried" "$(posts)" 1
eq "H18 create 422: records" "$(records | grep -c .)" 0
[ ! -e "$H/state/staff/watchman/acted/$FP.json" ] && ok || bad "H18 create 422: an acted file was written"

# A 2xx that is not 201 is not a filing either: only a 201 counts.
reset; agent augmentation; item a1 > "$FXT/items.jsonl"; echo 200 > "$FXT/create.status"
tick
eq "H18 create 200: records" "$(records | grep -c .)" 0
grep -q 'issue create for .* failed (rc=0 HTTP 200)' "$H/logs/staff.log" && ok || bad "H18 create 200: no failed-create line"

# ask on an action this wave cannot run: a digest line, verdict=unsupported.
reset; agent augmentation; item a1 > "$FXT/items.jsonl"; echo "claim a finding" > "$FXT/action"
tick
eq "H18 unsupported: creates" "$(posts)" 0
grep -q 'verdict=unsupported action="claim a finding"' "$H/logs/staff-digest.log" && ok || bad "H18 unsupported digest: $(cat "$H/logs/staff-digest.log" 2>/dev/null)"
eq "H18 unsupported: record" "$(records | sed 's/^[^{]*//' | jq -r .outcome)" unsupported

# autonomy under an autonomy cap: decide() allows, the filing is mode auto.
reset; agent autonomy active autonomy; item a1 > "$FXT/items.jsonl"
tick
eq "H18 allow: creates" "$(posts)" 1
eq "H18 allow: mode" "$(records | sed 's/^[^{]*//' | jq -r .mode)" auto
# autonomy ABOVE its cap refuses: a digest line, no filing.
reset; agent autonomy active augmentation; item a1 > "$FXT/items.jsonl"
tick
eq "H18 above cap: creates" "$(posts)" 0
eq "H18 above cap: record" "$(records | sed 's/^[^{]*//' | jq -r .outcome)" digested

# ═════ H19: a held filing is retried with no model call ═════════════════════
# The model decided `file a ticket`, and the issue list could not be read.
HELDF="$H/state/staff/watchman/held/$FP.json"
reset; agent augmentation; item a1 > "$FXT/items.jsonl"; touch "$FXT/list.fail"
tick
eq "H19 first tick: agent-calls" "$(lines "$FXT/ac.log")" 1
eq "H19 first tick: creates" "$(posts)" 0
[ -s "$HELDF" ] && ok || bad "H19: the decided filing was not kept in held/"
eq "H19 first tick: attempts" "$(cat "$H/state/staff/watchman/attempts/$FP" 2>/dev/null)" 1
# Three more ticks with GitHub still down: no model call, no attempt, no failed record.
echo same:claimed > "$FXT/claim.mode"
: > "$FXT/ac.log"; : > "$FXT/req.log"
tick; tick; tick
eq "H19 outage: agent-calls" "$(lines "$FXT/ac.log")" 0
eq "H19 outage: attempts" "$(cat "$H/state/staff/watchman/attempts/$FP" 2>/dev/null)" 1
eq "H19 outage: records" "$(records | grep -c .)" 0
[ -s "$HELDF" ] && ok || bad "H19 outage: the held filing was dropped"
grep -q 'held=1' <<<"$(tail -1 "$H/logs/staff.log")" && ok || bad "H19 outage: the tick does not count it held: $(tail -1 "$H/logs/staff.log")"
# GitHub is back: the filing is made from the held decision, still no model call.
rm -f "$FXT/list.fail"; : > "$FXT/gh.log"
tick
eq "H19 retry: agent-calls" "$(lines "$FXT/ac.log")" 0
eq "H19 retry: creates" "$(posts)" 1
eq "H19 retry: title" "$(jq -r .title "$FXT/gh-payload.json" 2>/dev/null)" "Fixture finding title"
R=$(records | sed 's/^[^{]*//')
eq "H19 retry: record outcome" "$(jq -r .outcome <<<"$R")" filed
eq "H19 retry: record mode" "$(jq -r .mode <<<"$R")" ask
[ ! -e "$HELDF" ] && ok || bad "H19 retry: the held file stays after the filing"
[ -s "$H/state/staff/watchman/acted/$FP.json" ] && ok || bad "H19 retry: no acted file"

[ -e "$T/net.log" ] && bad "a stub let a real curl/gh run: $(cat "$T/net.log")" || ok

echo "staff-heartbeat.bh-5561: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
