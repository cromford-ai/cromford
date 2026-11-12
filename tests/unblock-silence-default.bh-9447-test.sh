#!/bin/bash
# tests/unblock-silence-default.bh-9447-test.sh — BH-9447: a safe recommended
# lever runs when nobody answers a Tackler card.
#
# WHAT RUNS. The SHIPPED bin/lib/unblock/card.sh and bin/lib/unblock/silence.sh,
# through the production entry unblock_card_sweep (bin/unblock.sh calls it in
# act mode) over ledger rows whose cards come from the SHIPPED composer
# (unblock_card_compose with a ctx). S12 runs the SHIPPED bin/lib/unblock/act.sh.
#
# WHAT IS STUBBED, each one logged: bin/lane-alert.sh (argv to alerts.log),
# bin/agent-call.sh (must stay unused), bin/jobs-client.sh (act.sh's mode
# read), `gh` and `curl` on PATH (net.log), setting_get ($FXT/settings/<key>),
# _jobs_req (the open rows list, a claim ledger with a day count, the result
# POST; every request in req.log) and ub_act (records its record; the outcome
# from $FXT/ubact.outcome). Clock: the sweep's now argument and UB_NOW.
#
# Cases: S0 no vendor call, S1-S14 the decision rule and its exits, M1 the
# mutation row for the never-auto drop.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/unblock-silence-default.bh-9447-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "unblock-silence-default: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
cnt() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }

CARD="$DIR/bin/lib/unblock/card.sh"
SIL="$DIR/bin/lib/unblock/silence.sh"
ACT="$DIR/bin/lib/unblock/act.sh"
for f in "$CARD" "$SIL" "$ACT"; do [ -f "$f" ] || { echo "FAIL: missing $f"; echo "unblock-silence-default: 0 passed, 1 failed"; exit 1; }; done

H="$T/h"; FXT="$T/fx"; FB="$T/fakebin"
mkdir -p "$H/bin" "$H/logs" "$FB"
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
echo "agent-call $*" >> "$FXT/../ac.log"; exit 1
SH
cat > "$H/bin/lane-alert.sh" <<'SH'
#!/bin/bash
a="$*"; printf '%s\n' "${a//$'\n'/\\n}" >> "$FXT/alerts.log"
SH
# act.sh's mode read: the row unblock.project.<p>.mode from $FXT/settings.
cat > "$H/bin/jobs-client.sh" <<'SH'
#!/bin/bash
[ "$1" = setting-get ] || exit 1
[ -f "$FXT/settings/$2" ] || exit 2
cat "$FXT/settings/$2"
SH
# gh: the PR read answers $FXT/gh.head as the current head; every call logged.
cat > "$FB/gh" <<'SH'
#!/bin/bash
echo "gh $*" >> "$FXT/../net.log"
case "$*" in
  "api repos/example-org/cromford/pulls/9001") printf '{"head":{"sha":"%s"}}' "$(cat "$FXT/gh.head")" ;;
  *) echo '[]' ;;
esac
SH
printf '#!/bin/bash\necho "curl $*" >> "$FXT/../net.log"; exit 7\n' > "$FB/curl"
chmod +x "$H/bin/"*.sh "$FB/"*

NOW=1792508400                                  # 2026-10-20T15:00:00Z
DAY=2026-10-20
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
HEAD="$(printf 'c%.0s' $(seq 40))"
key() { printf '%s%s' "$1" "$(printf '0%.0s' $(seq $((64 - ${#1}))))"; }   # key <hex prefix> — 64 hex

reset() {
  scratch_rm "$FXT" || exit 1
  mkdir -p "$FXT/settings" "$FXT/claimed"
  : > "$FXT/rows.jsonl"; : > "$FXT/req.log"; : > "$FXT/ubact.log"; : > "$FXT/alerts.log"; : > "$H/logs/card.log"
  echo on > "$FXT/settings/unblock.silence_auto.cromford"
  echo done > "$FXT/ubact.outcome"
}
: > "$T/net.log"; : > "$T/ac.log"

# card <key> <levers-json> [rec] [compose-epoch] [ctx-filter] — the shipped composer's card.
card() {
  jq -nc --arg k "$1" '{kind: "pr-verdict-old-head", family: "queue", project: "cromford",
    subject: "example-org/cromford#9001", decision_key: $k, idle_min: 30}' > "$T/stall.json"
  jq -nc --argjson l "$2" --argjson r "${3:-2}" '{what: "PR 9001 has a verdict on an old head.",
    options: ["hold: keep it parked", "ask the lead for a new review on the current head", "run one fix round"],
    recommendation: $r, reason: "A new review is cheap.", levers: $l}' > "$T/decide.json"
  ( export HARNESS="$H" FXT HARNESS_TEST_SANDBOX=1 UNBLOCK_CARD_LOG="$H/logs/card.log"
    setting_get() { [ -f "$FXT/settings/$1" ] || return 2; cat "$FXT/settings/$1"; }
    . "$CARD" || exit 9
    unblock_card_compose "$T/stall.json" "$T/decide.json" "$1" "${4:-$NOW}" \
      "$(jq -nc --arg h "$HEAD" '{project: "cromford", subject_kind: "pr", subject: "example-org/cromford#9001",
          repo: "example-org/cromford", head: $h, class: null}' | jq -c "${5:-.}")" )
}
# seed <id> <key-prefix> <age-min> [levers] [row-filter] [rec] — one escalated row,
# created <age-min> before NOW, its card composed at that time, sent to the operator direct.
seed() {
  local c t k
  t=$((NOW - $3 * 60)); k=$(key "$2")
  c=$(card "$k" "${4:-[\"none\",\"lead_rerequest\",\"fix_round\"]}" "${6:-2}" "$t") || { bad "seed $1: compose failed"; return 1; }
  jq -nc --argjson i "$1" --arg k "$k" --arg h "$HEAD" --arg t "$(iso "$t")" --argjson c "$c" '{id: $i, decision_key: $k,
    project: "cromford", repo: "example-org/cromford", subject_kind: "pr", subject: "example-org/cromford#9001",
    head: $h, stall_class: "pr-verdict-old-head", decision: "escalate", outcome: "escalated", created_at: $t,
    routed_to: null, paged_at: null, archie_claimed_at: null, card: ($c + {route: "operator", class: null})}' \
    | jq -c "${5:-.}" >> "$FXT/rows.jsonl"
}
# sweep [now] [real-act] [silence-file] — the production entry: unblock_card_sweep.
sweep() {
  ( export HARNESS="$H" FXT HARNESS_TEST_SANDBOX=1 UNBLOCK_CARD_LOG="$H/logs/card.log" PATH="$FB:$PATH" \
      UB_NOW="${1:-$NOW}" UNBLOCK_ACT=1
    setting_get() { [ -f "$FXT/settings/$1" ] || return 2; cat "$FXT/settings/$1"; }
    . "$CARD" || exit 9
    [ -z "${3:-}" ] || { . "$3" || exit 9; }
    _jobs_req() {
      local id n cap code
      printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$FXT/req.log"
      case "$1 $2" in
        "GET /api/unblock/decisions?"*) jq -sc '{decisions: .}' "$FXT/rows.jsonl"; return 0 ;;
        "POST /api/unblock/silence/"*/claim)
          id=${2#/api/unblock/silence/}; id=${id%/claim}
          code=$(cat "$FXT/claim.code" 2>/dev/null)
          case "$code" in 404) return 2 ;; 500) return 1 ;; esac
          [ -f "$FXT/claimed/$id" ] && { printf '{"error":"claimed"}'; return 9; }
          n=$(cat "$FXT/claims.today" 2>/dev/null || echo 0); cap=$(jq -r .cap <<<"$3")
          [ "$n" -ge "$cap" ] && { printf '{"error":"day_cap","count":%s,"cap":%s}' "$n" "$cap"; return 9; }
          touch "$FXT/claimed/$id"; echo $((n + 1)) > "$FXT/claims.today"; printf '{"ok":true,"claimed":true}'; return 0 ;;
        "POST /api/unblock/silence/"*/result) printf '{"ok":true}'; return 0 ;;
        "POST /api/unblock/decisions/"*/paged) printf '{"ok":true}'; return 0 ;;
      esac
      return 1
    }
    if [ "${2:-}" = real-act ]; then
      . "$ACT" || exit 9
    else
      ub_act() {
        printf '%s\n' "$1" >> "$FXT/ubact.log"
        UB_ACT_OUTCOME=$(cat "$FXT/ubact.outcome"); UB_ACT_DETAIL="$UB_ACT_OUTCOME-detail"
        printf '%s\t%s\n' "$UB_ACT_OUTCOME" "$UB_ACT_DETAIL"; return 0
      }
    fi
    unblock_card_sweep cromford "${1:-$NOW}" )
}
runs()    { cnt . "$FXT/ubact.log"; }
claims()  { cnt '^POST /api/unblock/silence/[0-9]*/claim ' "$FXT/req.log"; }
silreqs() { cnt '/api/unblock/silence/' "$FXT/req.log"; }
crit()    { cnt '--critical' "$FXT/alerts.log"; }
info()    { cnt '--severity info' "$FXT/alerts.log"; }
warns()   { cnt '--severity warn' "$FXT/alerts.log"; }
resbody() { grep "^POST /api/unblock/silence/$1/result " "$FXT/req.log" | tail -1 | sed 's/^[^{]*//'; }
cid()     { jq -r --argjson i "$1" 'select(.id == $i) | .card.id' "$FXT/rows.jsonl"; }

# ═════ S1 the happy path ═════════════════════════════════════════════════════
reset; seed 11 a1a1a1 121
out=$(sweep)
eq "S1 the sweep's printed count (pages) is unchanged" "$out" 0
eq "S1 ub_act ran once" "$(runs)" 1
eq "S1 the record: lead_rerequest, decision_key silence:<card id>, rule silence-default" \
  "$(jq -c '[.action.name, .decision_key, .rule_id, .pr, .head == "'"$HEAD"'", .repo, .action.args.request_id, .action.args.priority]' "$FXT/ubact.log")" \
  "[\"lead_rerequest\",\"silence:$(cid 11)\",\"silence-default\",9001,true,\"example-org/cromford\",\"none\",5]"
eq "S1 the claim body" "$(grep '^POST /api/unblock/silence/11/claim ' "$FXT/req.log" | sed 's/^[^{]*//' | jq -c .)" '{"lever":"lead_rerequest","cap":10}'
eq "S1 the result POST says done" "$(resbody 11 | jq -r .outcome)" done
eq "S1 the claim came before the result" "$(grep -oE '/silence/11/(claim|result)' "$FXT/req.log" | tr '\n' ' ')" "/silence/11/claim /silence/11/result "
eq "S1 one info line, 0 critical" "$(info) $(crit) $(warns)" "1 0 0"
check "S1 the info text" 'grep -qF "unblock Tackler $(cid 11): no answer in 121 min, ran lead_rerequest: done" "$FXT/alerts.log"'
check "S1 the info id is unblock-silence-<key12>" 'grep -qF -- "--id unblock-silence-a1a1a1000000 --severity info" "$FXT/alerts.log"'
check "S1 the log line silence_ran=1" 'grep -qF "sweep cromford: silence_ran=1" "$H/logs/card.log"'

# ═════ S2 too young; lever none ══════════════════════════════════════════════
reset; seed 12 b2b2b2 119; sweep >/dev/null
eq "S2 119 min: 0 ub_act, 0 claims" "$(runs) $(claims)" "0 0"
reset; seed 13 b2b2b3 121 '["none","none","fix_round"]'; seed 14 b2b2b4 4000 '["none","none","fix_round"]'
sweep >/dev/null
eq "S2b lever none at 121 and 4000 min: 0 runs, 0 silence requests" "$(runs) $(silreqs)" "0 0"
check "S2b the card text holds 'nothing runs on silence'" '[ "$(jq -r ".card.text" "$FXT/rows.jsonl" | grep -c "nothing runs on silence")" = 2 ]'

# ═════ S3 / S4 the project row ═══════════════════════════════════════════════
for v in off On yes '' ; do
  reset; seed 15 c3c3c3 121; printf '%s' "$v" > "$FXT/settings/unblock.silence_auto.cromford"; sweep >/dev/null
  eq "S3 row [$v]: 0 runs, 0 silence requests" "$(runs) $(silreqs)" "0 0"
done
reset; seed 16 c4c4c4 121; rm -f "$FXT/settings/unblock.silence_auto.cromford"; sweep >/dev/null
eq "S4 no row (rc 2): 0 runs, 0 silence requests" "$(runs) $(silreqs)" "0 0"
reset; seed 17 c4c4c5 121; printf ' on \n' > "$FXT/settings/unblock.silence_auto.cromford"; sweep >/dev/null
eq "S4 row ' on ' (trimmed): 1 run" "$(runs)" 1

# ═════ S5 a hold answer at minute 30 ═════════════════════════════════════════
# The answer moves the row to answered, so the escalated list does not carry it.
reset; seed 18 d5d5d5 121 '["none","lead_rerequest","fix_round"]' '.outcome = "answered" | .answer = "hold"'
: > "$FXT/rows.jsonl"; sweep >/dev/null
eq "S5 held card (not in the escalated rows): 0 runs" "$(runs) $(silreqs)" "0 0"
reset; seed 19 d5d5d6 121 '["none","lead_rerequest","fix_round"]' '.outcome = "answered" | .answer = "hold"'
sweep >/dev/null
eq "S5 a row whose outcome is answered: 0 runs" "$(runs) $(silreqs)" "0 0"

# ═════ S6 the never-auto drop ════════════════════════════════════════════════
s6() {
  reset; echo "lead_rerequest,merge" > "$FXT/settings/unblock.silence_safe_levers"
  seed 21 e6e6e6 125 '["none","lead_rerequest","fix_round"]' '.card.levers[1] = "merge"'
  seed 22 e6e6e7 121
  sweep "$NOW" "" "${1:-}" >/dev/null
}
s6
eq "S6 the merge card: no claim; the safe card runs" "$(claims) $(runs) $(jq -r .action.name "$FXT/ubact.log")" "1 1 lead_rerequest"
eq "S6 exactly 1 warn alert" "$(warns)" 1
check "S6 the warn id and text" 'grep -qF -- "--id unblock-silence-never-auto --severity warn unblock merge dropped from unblock.silence_safe_levers: never-auto" "$FXT/alerts.log"'
eq "S6 nothing merges, 0 critical" "$(cnt merge "$FXT/ubact.log") $(crit)" "0 0"
reset; echo "lead_rerequest , Merge,update_branch" > "$FXT/settings/unblock.silence_safe_levers"; seed 23 e6e6e8 121; sweep >/dev/null
eq "S6 'Merge' (case) is dropped too, spaces trimmed: 1 warn, the safe lever runs" "$(warns) $(runs)" "1 1"
reset
echo "lead_rerequest,force_push,deploy,pause_project,spend,governance,production,client-board,live-probe" > "$FXT/settings/unblock.silence_safe_levers"
seed 24 e6e6e9 121; sweep >/dev/null
eq "S6 every never-auto name dropped in ONE warn" "$(warns)" 1
check "S6 the warn names them all" 'grep -F -- "unblock-silence-never-auto" "$FXT/alerts.log" | grep -qF "force_push deploy pause_project spend governance production client-board live-probe dropped"'

# ═════ S7 an unknown name in the safe list ═══════════════════════════════════
reset; echo "lead_rerequest,merge_queue_x" > "$FXT/settings/unblock.silence_safe_levers"; seed 25 f7f7f7 121
: > "$H/logs/card.log"; sweep >/dev/null
eq "S7 unknown name dropped: 0 alerts besides the info line, the safe lever runs" "$(warns) $(runs)" "0 1"
eq "S7 one log line in the sweep names it" "$(cnt 'merge_queue_x' "$H/logs/card.log")" 1

# ═════ S8 a lever that ends failed ═══════════════════════════════════════════
reset; seed 26 a8a8a8 121; echo failed > "$FXT/ubact.outcome"; sweep >/dev/null
eq "S8 failed: result POST failed" "$(resbody 26 | jq -r .outcome)" failed
eq "S8 failed: 0 critical, 1 info" "$(crit) $(info)" "0 1"
check "S8 the info line says failed" 'grep -qF "ran lead_rerequest: failed" "$FXT/alerts.log"'
: > "$FXT/ubact.log"; : > "$FXT/alerts.log"; sweep $((NOW + 600)) >/dev/null
eq "S8 a second sweep at 131 min: claim 409 claimed, 0 ub_act, 0 alerts" "$(claims) $(runs) $(cnt . "$FXT/alerts.log")" "2 0 0"
reset; seed 27 a8a8a9 121; echo refused > "$FXT/ubact.outcome"; sweep >/dev/null
eq "S8 refused: result refused, 0 critical" "$(resbody 27 | jq -r .outcome) $(crit)" "refused 0"

# ═════ S9 the day cap ════════════════════════════════════════════════════════
reset; echo 10 > "$FXT/claims.today"; seed 28 b9b9b9 121; seed 29 b9b9ba 122; sweep >/dev/null
eq "S9 the 11th claim: 409 day_cap, 0 ub_act" "$(runs)" 0
eq "S9 one claim, then the loop stops" "$(claims)" 1
eq "S9 1 warn alert" "$(warns)" 1
check "S9 the warn id is per project and day" 'grep -qF -- "--id unblock-silence-cap-cromford-$DAY --severity warn" "$FXT/alerts.log"'
reset; echo 2 > "$FXT/settings/unblock.silence_auto_day_cap"; echo 2 > "$FXT/claims.today"; seed 30 b9b9bb 121; sweep >/dev/null
check "S9 the cap row is sent to the worker" 'grep -qF "\"cap\":2" "$FXT/req.log"'

# ═════ S10 claim 404; S11 not shown to the operator ══════════════════════════════════
reset; echo 404 > "$FXT/claim.code"; seed 31 c0c0c0 121; seed 32 c0c0c1 122; sweep >/dev/null
eq "S10 claim 404: 0 ub_act, 1 claim (stop)" "$(runs) $(claims)" "0 1"
eq "S10 one log line" "$(cnt 'no silence route on the worker' "$H/logs/card.log")" 1
reset; echo 500 > "$FXT/claim.code"; seed 33 c0c0c2 121; sweep >/dev/null
eq "S10 claim 500: 0 ub_act" "$(runs)" 0
reset; seed 34 c1c1c1 121 '["none","lead_rerequest","fix_round"]' '.card.route = "archie"'; sweep >/dev/null
eq "S11 route archie, routed_to null (Archie's): 0 runs, 0 silence requests" "$(runs) $(silreqs)" "0 0"
reset; seed 35 c1c1c2 121 '["none","lead_rerequest","fix_round"]' '.card.route = "archie" | .routed_to = "operator"'; sweep >/dev/null
eq "S11 routed_to operator, paged_at null: 0 runs" "$(runs) $(silreqs)" "0 0"
reset; seed 36 c1c1c3 121 '["none","lead_rerequest","fix_round"]' '.card.route = "archie" | .routed_to = "operator" | .paged_at = "2026-10-20T13:30:00Z"'
sweep >/dev/null
eq "S11 routed_to operator and paged: 1 run" "$(runs)" 1

# ═════ S12 the real act.sh: the head moved ═══════════════════════════════════
reset; NET0=$(cnt . "$T/net.log"); echo act > "$FXT/settings/unblock.project.cromford.mode"
printf 'd%.0s' $(seq 40) > "$FXT/gh.head"
seed 37 d2d2d2 121; sweep "$NOW" real-act >/dev/null
eq "S12 real ub_act: result refused" "$(resbody 37 | jq -r .outcome)" refused
eq "S12 the detail is head-moved" "$(resbody 37 | jq -r .detail)" head-moved
eq "S12 the card stays open: no done result, 0 critical" "$(cnt '"outcome":"done"' "$FXT/req.log") $(crit)" "0 0"
check "S12 the info line says refused" 'grep -qF "ran lead_rerequest: refused" "$FXT/alerts.log"'
eq "S12 gh: only the PR head read" "$(tail -n +$((NET0 + 1)) "$T/net.log")" "gh api repos/example-org/cromford/pulls/9001"

# ═════ S13 a pre-change card; S14 silence_at in the future ═══════════════════
reset; seed 38 e3e3e3 300 '["none","lead_rerequest","fix_round"]' '.card |= del(.silence_at, .silence_option, .levers)'; sweep >/dev/null
eq "S13 a card with no silence_at: 0 runs" "$(runs) $(silreqs)" "0 0"
reset; echo 600 > "$FXT/settings/unblock.silence_auto_after_min"; seed 39 e4e4e4 121
echo 30 > "$FXT/settings/unblock.silence_auto_after_min"; sweep >/dev/null
eq "S14 silence_at in the future, age >= after_min: 0 runs" "$(runs) $(silreqs)" "0 0"
reset; seed 40 e4e4e5 121 '["none","lead_rerequest","fix_round"]' '.card.silence_option = 3'; sweep >/dev/null
eq "S14 silence_option is not the recommendation: 0 runs" "$(runs)" 0
reset; seed 41 e4e4e6 121 '["none","lead_rerequest","fix_round"]' '.card.class = "merge"'; sweep >/dev/null
eq "S14 class merge: 0 runs" "$(runs) $(silreqs)" "0 0"
reset; echo "lead_rerequest,launch_fastpath" > "$FXT/settings/unblock.silence_safe_levers"
seed 42 e4e4e7 121 '["none","lead_rerequest","fix_round"]' '.card.levers[1] = "launch_fastpath"'; sweep >/dev/null
eq "S14 a safe lever with no builder: 0 runs" "$(runs) $(silreqs)" "0 0"
reset; seed 43 e4e4e8 121 '["none","lead_rerequest","fix_round"]' '.subject = "cromford:BH-9001" | .subject_kind = "build"'; sweep >/dev/null
eq "S14 lead_rerequest on a ticket subject: 0 runs" "$(runs) $(silreqs)" "0 0"
reset; seed 44 e4e4e9 121 '["none","lead_rerequest","fix_round"]' '.silence_claimed_at = "2026-10-20T14:00:00Z"'; sweep >/dev/null
eq "S14 a row already claimed: 0 runs" "$(runs)" 0

# ═════ M1 the mutation row: remove the never-auto drop ═══════════════════════
MUT="$T/silence-mutant.sh"
grep -v '# never-auto-drop' "$SIL" > "$MUT"
check "M1 the mutant differs from the shipped file by the drop line" '[ "$(diff "$SIL" "$MUT" | grep -c "^<")" = 1 ]'
s6 "$MUT"
eq "M1 the mutant sends 0 never-auto warn alerts (S6 would be red)" "$(cnt 'unblock-silence-never-auto' "$FXT/alerts.log")" 0
s6
eq "M1 restored: the shipped file sends the warn again" "$(cnt 'unblock-silence-never-auto' "$FXT/alerts.log")" 1

# ═════ S0 no vendor call ═════════════════════════════════════════════════════
eq "S0 agent-call.sh was never called" "$(cnt . "$T/ac.log")" 0
eq "S0 curl was never called; gh only in S12 (a stub)" "$(cnt curl "$T/net.log") $(cnt . "$T/net.log")" "0 1"

echo "unblock-silence-default: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
