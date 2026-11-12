#!/bin/bash
# tests/unblock-card-default-line.bh-9447-test.sh — BH-9447: the DEFAULT line
# of a Tackler card tells the truth. A safe recommended lever on a project
# whose row unblock.silence_auto.<p> is `on` names the option and the UTC time
# it runs; every other card keeps "nothing runs on silence".
#
# WHAT RUNS. The SHIPPED bin/lib/unblock/card.sh (sourced in a subshell), which
# loads the SHIPPED bin/lib/unblock/silence.sh. unblock_card_compose with the
# new <ctx-json> argument, and the L5 round trip through unblock_silence_sweep.
#
# WHAT IS STUBBED, each one logged: bin/agent-call.sh (the LLM seam, must stay
# unused), bin/lane-alert.sh, setting_get ($FXT/settings/<key>), _jobs_req (a
# claim and result ledger in $FXT), ub_act (records its record). Nothing here
# reaches a network.
#
# Cases: L0 no model call, L1 the promise line, L2 the old line, L3 the lever
# validation, L4 a lever that does not fit the subject, L5 the round trip, L6
# the 900-char fit.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/unblock-card-default-line.bh-9447-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "unblock-card-default-line: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

CARD="$DIR/bin/lib/unblock/card.sh"
[ -f "$CARD" ] || { echo "FAIL: missing $CARD"; exit 1; }
H="$T/h"; FXT="$T/fx"
mkdir -p "$H/bin" "$H/logs" "$FXT/settings" "$FXT/claimed"
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
echo "agent-call $*" >> "$FXT/ac.log"; exit 1
SH
cat > "$H/bin/lane-alert.sh" <<'SH'
#!/bin/bash
a="$*"; printf '%s\n' "${a//$'\n'/\\n}" >> "$FXT/alerts.log"
SH
chmod +x "$H/bin/"*.sh
: > "$FXT/ac.log"

NOW=1792508400   # 2026-10-20T15:00:00Z
# Fixture keys and heads built at run time (no hex token in the file).
KEY="5e1a9c$(printf '0%.0s' $(seq 58))"
HEAD="$(printf 'c%.0s' $(seq 40))"
PRCTX=$(jq -nc --arg h "$HEAD" '{project: "cromford", subject_kind: "pr", subject: "example-org/cromford#9001",
  repo: "example-org/cromford", head: $h, class: null}')
TKCTX='{"project":"cromford","subject_kind":"build","subject":"cromford:BH-9001","repo":"example-org/cromford","head":null,"class":null}'
jq -nc --arg k "$KEY" '{kind: "pr-verdict-old-head", family: "queue", project: "cromford", subject: "example-org/cromford#9001",
  decision_key: $k, idle_min: 30}' > "$T/stall.json"
decide() { # decide <levers-json|-> [recommendation]
  jq -nc --argjson l "${1/#-/null}" --argjson r "${2:-2}" '{what: "PR 9001 has a verdict on an old head.",
    options: ["hold: keep it parked", "ask the lead for a new review on the current head", "run one fix round"],
    recommendation: $r, reason: "A new review is cheap."} + (if $l == null then {} else {levers: $l} end)' > "$T/decide.json"
}
# compose [ctx] — the card JSON from the shipped composer.
compose() {
  ( export HARNESS="$H" FXT HARNESS_TEST_SANDBOX=1 UNBLOCK_CARD_LOG="$H/logs/card.log"
    setting_get() { [ -f "$FXT/settings/$1" ] || return 2; cat "$FXT/settings/$1"; }
    . "$CARD" || exit 9
    unblock_card_compose "$T/stall.json" "$T/decide.json" "$KEY" "$NOW" ${1:+"$1"} )
}
defline() { jq -r '.text | split("\n")[] | select(startswith("DEFAULT:"))' <<<"$1"; }
OLD='DEFAULT: it stays as it is now; nothing runs on silence.'
on()  { echo "${1:-on}" > "$FXT/settings/unblock.silence_auto.cromford"; }
off() { rm -f "$FXT/settings/unblock.silence_auto.cromford"; }

# ═════ L1 the promise line ═══════════════════════════════════════════════════
on; decide '["none","lead_rerequest","fix_round"]'
C=$(compose "$PRCTX"); rc=$?
eq "L1 compose rc" "$rc" 0
ID=$(jq -r .id <<<"$C")
L=$(defline "$C")
check "L1 the DEFAULT line names the option, a UTC time and the hold reply [$L]" \
  '[[ $L =~ ^DEFAULT:\ option\ 2\ runs\ at\ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}Z\ if\ you\ do\ not\ answer\.\ Reply\ \"Tackler\ u-[0-9a-f]{6}\ hold\"\ to\ stop\ it\.$ ]]'
WANT_AT=$(date -u -d "@$((NOW + 7200))" +%Y-%m-%dT%H:%MZ)
eq "L1 the time is now + 120 min (the fallback)" "$L" "DEFAULT: option 2 runs at $WANT_AT if you do not answer. Reply \"Tackler $ID hold\" to stop it."
eq "L1 card silence_at and silence_option" "$(jq -c '[.silence_at, .silence_option]' <<<"$C")" "[\"$(date -u -d "@$((NOW + 7200))" +%Y-%m-%dT%H:%M:%SZ)\",2]"
eq "L1 card levers" "$(jq -c .levers <<<"$C")" '["none","lead_rerequest","fix_round"]'
echo 30 > "$FXT/settings/unblock.silence_auto_after_min"
eq "L1 the row unblock.silence_auto_after_min 30 moves the time" "$(defline "$(compose "$PRCTX")")" \
  "DEFAULT: option 2 runs at $(date -u -d "@$((NOW + 1800))" +%Y-%m-%dT%H:%MZ) if you do not answer. Reply \"Tackler $ID hold\" to stop it."
rm -f "$FXT/settings/unblock.silence_auto_after_min"
on ' on '
check "L1 a row ' on ' (trimmed) promises" '[[ $(defline "$(compose "$PRCTX")") == "DEFAULT: option 2 runs at"* ]]'

# ═════ L2 the old line ═══════════════════════════════════════════════════════
for case_ in "lever none" "project off" "project On" "no row" "no ctx" "rec 1" "class merge" "lever not safe"; do
  on; decide '["none","lead_rerequest","fix_round"]'; ctx=$PRCTX
  case "$case_" in
    "lever none") decide '["none","none","fix_round"]' ;;
    "project off") on off ;;
    "project On") on On ;;
    "no row") off ;;
    "no ctx") ctx="" ;;
    "rec 1") decide '["none","lead_rerequest","fix_round"]' 1 ;;
    "class merge") ctx=$(jq -c '.class = "merge"' <<<"$PRCTX") ;;
    "lever not safe") echo "fix_round,requeue" > "$FXT/settings/unblock.silence_safe_levers" ;;
  esac
  C=$(compose "$ctx")
  eq "L2 $case_: the old DEFAULT line" "$(defline "$C")" "$OLD"
  eq "L2 $case_: no silence_at" "$(jq -c '[.silence_at, .silence_option]' <<<"$C")" "[null,null]"
  rm -f "$FXT/settings/unblock.silence_safe_levers"
done
eq "L2 the card default field is the old sentence" "$(jq -r .default <<<"$C")" "it stays as it is now; nothing runs on silence"

# ═════ L3 the lever validation ═══════════════════════════════════════════════
on; decide '["lead_rerequest","merge","bogus"]'
C=$(compose "$PRCTX")
eq "L3 merge and bogus become none; index 0 is forced none" "$(jq -c .levers <<<"$C")" '["none","none","none"]'
eq "L3 the model's options stay (no fallback)" "$(jq -r '.options[1]' <<<"$C")" "ask the lead for a new review on the current head"
eq "L3 a never-auto lever is no promise" "$(defline "$C")" "$OLD"
decide '["none","lead_rerequest"]'
C=$(compose "$PRCTX")
eq "L3 a levers array of the wrong length: all none" "$(jq -c .levers <<<"$C")" '["none","none","none"]'
eq "L3 the wrong length keeps the model's options" "$(jq -r '.options | length' <<<"$C")" 3
decide '"lead_rerequest"'
eq "L3 levers not an array: all none" "$(jq -c .levers <<<"$(compose "$PRCTX")")" '["none","none","none"]'
decide '["none",7,"fix_round"]'
eq "L3 a non-string lever: none, the rest kept" "$(jq -c .levers <<<"$(compose "$PRCTX")")" '["none","none","fix_round"]'
decide -
eq "L3 no levers key: all none" "$(jq -c .levers <<<"$(compose "$PRCTX")")" '["none","none","none"]'

# ═════ L4 a lever that does not fit the subject ══════════════════════════════
on; decide '["none","lead_rerequest","rebuild"]'
eq "L4 lead_rerequest on a ticket subject: no promise" "$(defline "$(compose "$TKCTX")")" "$OLD"
decide '["none","rebuild","lead_rerequest"]'
check "L4 rebuild on a ticket subject: a promise (control)" '[[ $(defline "$(compose "$TKCTX")") == "DEFAULT: option 2 runs at"* ]]'
eq "L4 rebuild on a PR subject: no promise" "$(defline "$(compose "$PRCTX")")" "$OLD"

# ═════ L5 the round trip: the composed card is the row the sweep reads ═══════
on; decide '["none","lead_rerequest","fix_round"]'
C=$(compose "$PRCTX")
SAT=$(jq -r '.silence_at | fromdateiso8601' <<<"$C")
jq -c --arg h "$HEAD" --arg t "$(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)" --arg k "$KEY" '{id: 41, decision_key: $k,
  project: "cromford", repo: "example-org/cromford", subject_kind: "pr", subject: "example-org/cromford#9001",
  head: $h, stall_class: "pr-verdict-old-head", outcome: "escalated", created_at: $t, routed_to: null, paged_at: null,
  card: (. + {route: "operator", class: null})}' <<<"$C" > "$T/row.json"
sweep_at() {
  ( export HARNESS="$H" FXT HARNESS_TEST_SANDBOX=1 UNBLOCK_CARD_LOG="$H/logs/card.log"
    setting_get() { [ -f "$FXT/settings/$1" ] || return 2; cat "$FXT/settings/$1"; }
    . "$CARD" || exit 9
    . "$DIR/bin/lib/unblock/silence.sh" || exit 9
    _jobs_req() {
      printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$FXT/req.log"
      case "$1 $2" in
        "POST /api/unblock/silence/"*/claim) printf '{"ok":true,"claimed":true}'; return 0 ;;
        "POST /api/unblock/silence/"*/result) printf '{"ok":true}'; return 0 ;;
      esac
      return 1
    }
    ub_act() { printf '%s\n' "$1" >> "$FXT/ubact.log"; UB_ACT_OUTCOME=done UB_ACT_DETAIL=requested; printf 'done\trequested\n'; }
    unblock_silence_sweep cromford "$1" "$(cat "$T/row.json")" )
}
: > "$FXT/ubact.log"; : > "$FXT/req.log"
eq "L5 at silence_at - 60 s: 0 runs" "$(sweep_at $((SAT - 60)))" 0
eq "L5 at silence_at - 60 s: 0 ub_act, 0 requests" "$(grep -c . "$FXT/ubact.log") $(grep -c . "$FXT/req.log")" "0 0"
eq "L5 at silence_at + 60 s: 1 run" "$(sweep_at $((SAT + 60)))" 1
eq "L5 the run is the promised option's lever" "$(jq -r '.action.name' "$FXT/ubact.log")" lead_rerequest

# ═════ L6 the 900-char fit ═══════════════════════════════════════════════════
on; decide '["none","lead_rerequest","fix_round"]'
jq -c --arg l "$(printf 'e%.0s' $(seq 2000))" '. + {log_excerpt: $l}' "$T/stall.json" > "$T/stall-long.json"
cp "$T/stall.json" "$T/stall-short.json"; cp "$T/stall-long.json" "$T/stall.json"
C=$(compose "$PRCTX"); rc=$?
cp "$T/stall-short.json" "$T/stall.json"
eq "L6 long evidence: rc 0" "$rc" 0
check "L6 the text is at most 900 chars" '[ "$(jq -r ".text | length" <<<"$C")" -le 900 ]'
check "L6 the full promise line survives the trim" '[[ $(defline "$C") =~ ^DEFAULT:\ option\ 2\ runs\ at\ .*\ to\ stop\ it\.$ ]]'
check "L6 the evidence was trimmed" 'jq -e ".evidence | endswith(\"…\")" <<<"$C" >/dev/null'

# ═════ L0 no model call, no alert ════════════════════════════════════════════
eq "L0 agent-call.sh was never called" "$(grep -c . "$FXT/ac.log")" 0
eq "L0 lane-alert.sh: only the L5 info line" "$(grep -c . "$FXT/alerts.log" 2>/dev/null || echo 0)" 1

echo "unblock-card-default-line: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
