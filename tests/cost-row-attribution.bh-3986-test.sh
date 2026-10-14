#!/bin/bash
# tests/cost-row-attribution.bh-3986-test.sh — BH-3986, one canonical
# auth_account per account and the SERVED model on every cost row.
#
# Two defects in the ledger, both read off live cost_rows (plan probe,
# 2026-10-03): the hub wrote `acct:max1` where the pool wrote
# `max1@example.com` for the same account, and the script-level refusals in
# bin/agent-call.sh paired runner=grok with the REQUESTED claude model.
#
#   AC1  every label source gives the same auth_account (field 16): the pool's
#        fp overlay, agent-call's routed pick (with and without the picker's
#        label=), claude-cost.sh's orchestrator turn (with and without
#        ORC_ACCOUNT_LABEL). Negatives: no label, an unsafe name, an fp label
#        beating a picker label, a pinned account verbatim, no token leak.
#   AC2  field 6 is the served model and `requested_model=` rides in the note
#        (field 24): grok fall-through, call-guard and tripwire refusals with a
#        grok primary, no token for claude, an honest route miss.
#   AC3  bin/cost-rows-acct-backfill.sh, the dry-run SQL a human applies.
#   AC4  a box whose sync has not landed the new cost-row.sh: both writers
#        still write the row the old rule wrote, never abort after the call.
#
# Everything DRIVES the real bin/agent-call.sh / bin/claude-cost.sh /
# bin/cost-rows-acct-backfill.sh against fake CLIs and reads the artifacts
# (logs/cost.csv, the emitted SQL applied to a scratch SQLite). The pinned and
# no-acct-note negatives also call the lib function, which is what both
# writers call.
# Run from anywhere: tests/cost-row-attribution.bh-3986-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset HARNESS_ENV_DIR ACCOUNTS_DIR

mkdir -p "$T/bin/lib/jobs" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state" "$T/env/accounts.d" "$T/builds/b1"
mrs_fixture "$T" testproj
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
cp "$DIR/bin/lib/jobs/"*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/lib/env-path.sh" "$T/bin/lib/env-path.sh"
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
printf '#!/bin/bash\necho "test rules"\n' > "$T/bin/sync-agent-rules.sh"

# THE REGISTRY. max1 and max5 carry an ACCOUNT_LABEL, max9 does not. A token
# sits in max1's file so a read that sources it (or copies it) is visible.
cat > "$T/env/accounts.d/max1.env" <<'EOF'
ACCOUNT_NAME=max1
ACCOUNT_VENDOR=claude
ACCOUNT_LABEL=max1@example.com
CLAUDE_CODE_OAUTH_TOKEN=tok-max1-fixture
EOF
cat > "$T/env/accounts.d/max5.env" <<'EOF'
ACCOUNT_NAME=max5
ACCOUNT_VENDOR=claude
ACCOUNT_LABEL="max5@example.com"
EOF
cat > "$T/env/accounts.d/max9.env" <<'EOF'
ACCOUNT_NAME=max9
ACCOUNT_VENDOR=claude
EOF
# The file `accounts.d/../x.env` would hit. A name that escapes the dir must
# never read it.
echo 'ACCOUNT_LABEL=SENTINEL-OUTSIDE-ACCOUNTS-D' > "$T/env/x.env"
echo '{}' > "$T/empty-catalog.json"
FP1=$(printf '%s' tok-max1-fixture | sha256sum | cut -c1-12)

cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
case "${CLAUDE_RESULT:-ok}" in
  fail) echo "vendor error" >&2; exit 1 ;;
  *)    echo '{"result":"the text","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}'; exit 0 ;;
esac
EOF
cat > "$T/fakebin/grok" <<'EOF'
#!/bin/bash
echo "grok answered"
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
# The fake call-guard worker (tests/agent-call-call-guard.k3-test.sh's, cut to
# claim/settle). Every other URL is a transport failure, so the model-route
# resolver answers from the box cache mrs_fixture wrote.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
url="" data=""
while [ $# -gt 0 ]; do
  case "$1" in
    --data-binary) data="$2"; shift 2 ;;
    -X|-m|--connect-timeout|-w|-H) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$data" in @*) data=$(cat "${data#@}") ;; esac
case "$url" in */api/call-guard/*) ;; *) exit 7 ;; esac
touch "$CG_ROWS"
case "$url" in
  */claim)
    id=$(jq -r .call_id <<<"$data"); p=$(jq -r .project <<<"$data"); s=$(jq -r .stage <<<"$data")
    f=$(jq -r .fp <<<"$data"); m=$(jq -r .max <<<"$data")
    n=$(awk -F'\t' -v p="$p" -v s="$s" -v f="$f" '$2==p && $3==s && $4==f && $5!="refused"{c++} END{print c+0}' "$CG_ROWS")
    if [ "$n" -lt "$m" ]; then
      printf '%s\t%s\t%s\t%s\tclaimed\n' "$id" "$p" "$s" "$f" >> "$CG_ROWS"
      printf '{"allowed":true,"count":%s,"max":%s,"call_id":"%s"}\n200' "$((n+1))" "$m" "$id"
    else
      printf '%s\t%s\t%s\t%s\trefused\n' "$id" "$p" "$s" "$f" >> "$CG_ROWS"
      printf '{"allowed":false,"count":%s,"max":%s,"call_id":"%s","top":[]}\n200' "$n" "$m" "$id"
    fi ;;
  */settle)
    id=$(jq -r .call_id <<<"$data"); o=$(jq -r .outcome <<<"$data")
    awk -F'\t' -v OFS='\t' -v id="$id" -v o="$o" '$1==id && $5=="claimed"{$5=o} {print}' "$CG_ROWS" > "$CG_ROWS.tmp" && mv "$CG_ROWS.tmp" "$CG_ROWS"
    printf '{"settled":true}\n200' ;;
  *) printf '{"error":"unknown endpoint"}\n404' ;;
esac
EOF
# The picker the ladder runs: answers $PICK_OUT verbatim (newline-escaped).
cat > "$T/bin/account-pick.sh" <<'EOF'
#!/bin/bash
printf '%b\n' "${PICK_OUT:-name=default\nreason=default}"
EOF
chmod +x "$T/fakebin/"* "$T/bin/"*.sh

reset() {
  rm -rf "$T/logs/cost.csv" "$T/cg.rows" "$T/state/agent-call-ledger" "$T/state/auth-accounts.local.json" "$T/builds/b1/"*
}

# call <out-path> <stage> <prompt> [VAR=VAL ...] -> prints the rc. Defaults:
# a subscription claude primary on the fixture token, no routing, guard off.
call() {
  local out="$1" stage="$2" prompt="$3"; shift 3
  ( unset AGENT_CALL_FP AGENT_CALL_GUARD_STAGE AGENT_CALL_TICKET AGENT_CALL_GUARD_FORCE HARNESS_TICKET JOB_ID \
          CALL_GUARD_STAGES CALL_GUARD_MAX_MAP GROK_MODEL CODEX_MODEL FIREWORKS_MODEL
    export CG_ROWS="$T/cg.rows" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           JOBS_URL="https://jobs.test" HARNESS_SECRET="test-secret" JOBS_RETRIES=0 JOBS_BOX=testbox \
           CLAUDE_CODE_OAUTH_TOKEN=tok-max1-fixture ANTHROPIC_API_KEY= \
           OPENROUTER_API_KEY= FIREWORKS_API_KEY= CODEX_API_KEY= OPENAI_API_KEY= ACCOUNT_ROUTING=0 \
           AUTH_ACCOUNTS_CATALOG="$T/empty-catalog.json" AUTH_ACCOUNTS_LOCAL="$T/state/auth-accounts.local.json" \
           LADDER_TIER2_GROK=0 LADDER_BACKOFF_SECS=0 LADDER_SAME_RETRIES=0 CLAUDE_RESULT=ok \
           AGENT_CALL_RUNNERS= AGENT_CALL_LEDGER=0 CALL_GUARD=0 \
           RUNNER_TRIAGE=claude RUNNER_TRIAGE_FALLBACK= RUNNER_EXECUTE=claude RUNNER_EXECUTE_FALLBACK= \
           LANE_GATE_DISABLE=1 LLM_GATE_DISABLE=1 \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" "$@"
    cd "$T" && bash "${AC_BIN:-$DIR/bin}/agent-call.sh" "$stage" testproj claude-opus-5-5 60 "$out" "$prompt" \
      >/dev/null 2>&1 )
  echo $?
}
# lastrow <runner> -> the last cost.csv row written for that runner
lastrow() { awk -F, -v r="$1" 'NR>1 && $5==r {l=$0} END{print l}' "$T/logs/cost.csv" 2>/dev/null; }
fld() { printf '%s' "$1" | cut -d, -f"$2"; }

# ============================================================================
# AC1 — one account, one auth_account, whatever wrote the label
# ============================================================================
PICK1='name=max1\nreason=picked\nlabel=max1@example.com\nexport CLAUDE_CODE_OAUTH_TOKEN=tok-max1-fixture'
PICK1_NOLABEL='name=max1\nreason=picked\nexport CLAUDE_CODE_OAUTH_TOKEN=tok-max1-fixture'

# (a) the pool overlay path: the token's fp is mapped, no routing. Green today;
# it pins the reference spelling every other path must match.
reset
printf '{"%s":"max1@example.com"}\n' "$FP1" > "$T/state/auth-accounts.local.json"
rc=$(call "$T/o-a" triage "a1")
RA=$(lastrow claude)
[ "$rc" = 0 ] && [ "$(fld "$RA" 16)" = max1@example.com ] && ok || bad "AC1(a) overlay row field 16 '$(fld "$RA" 16)' (rc $rc): $RA"

# (b) agent-call routed, the picker hands back label=
reset
rc=$(call "$T/o-b" triage "a1" ACCOUNT_ROUTING=1 PICK_OUT="$PICK1")
RB=$(lastrow claude)
[ "$(fld "$RB" 16)" = max1@example.com ] && ok || bad "AC1(b) routed+label field 16 '$(fld "$RB" 16)', want max1@example.com: $RB"
case ";$(fld "$RB" 24);" in *";acct=max1;"*) ok ;; *) bad "AC1(b) the raw account name is not kept in the note: '$(fld "$RB" 24)'" ;; esac
[ "$(printf '%s' "$RB" | awk -F, '{print NF}')" = 26 ] && ok || bad "AC1(b) the routed row is not 26 fields: $RB"

# (b2) the picker's label= is used on its own: max7 has no registry file here,
# so only the pick's line can name it
reset
rc=$(call "$T/o-b2" triage "a1" ACCOUNT_ROUTING=1 PICK_OUT='name=max7\nreason=picked\nlabel=max7@example.com\nexport CLAUDE_CODE_OAUTH_TOKEN=tok-max7-fixture')
[ "$(fld "$(lastrow claude)" 16)" = max7@example.com ] && ok || bad "AC1(b2) the picker's label= was not used: $(lastrow claude)"

# (c) agent-call routed, no label= line: the registry's ACCOUNT_LABEL
reset
rc=$(call "$T/o-c" triage "a1" ACCOUNT_ROUTING=1 PICK_OUT="$PICK1_NOLABEL")
RC_=$(lastrow claude)
[ "$(fld "$RC_" 16)" = max1@example.com ] && ok || bad "AC1(c) routed, registry label: field 16 '$(fld "$RC_" 16)', want max1@example.com: $RC_"

# (d) claude-cost.sh, the orchestrator's turn
mkdir -p "$T/cc/bin/lib" "$T/cc/logs" "$T/cc/flags" "$T/cc/env" "$T/cc/work" "$T/cc/cfg"
cp "$DIR/bin/claude-cost.sh" "$DIR/bin/transcript-cost.sh" "$DIR/bin/auth-fingerprint.sh" "$T/cc/bin/"
cp "$DIR/bin/lib/cost-row.sh" "$DIR/bin/lib/env-path.sh" "$T/cc/bin/lib/"
cp -r "$T/env/accounts.d" "$T/cc/env/accounts.d"
printf '#!/bin/bash\necho subscription\n' > "$T/cc/bin/billing-mode.sh"
chmod +x "$T/cc/bin/"*.sh
cat > "$T/fakebin/claude-cc" <<'EOF'
#!/bin/bash
cat >/dev/null 2>&1
echo "CC-OUT"
EOF
chmod +x "$T/fakebin/claude-cc"
mkdir -p "$T/cc/fake"; cp "$T/fakebin/claude-cc" "$T/cc/fake/claude"
cc() {
  rm -f "$T/cc/logs/cost.csv"
  ( cd "$T/cc/work" && env -u HARNESS_ENV_DIR -u ACCOUNTS_DIR -u JOB_ID -u HARNESS_TICKET HARNESS="$T/cc" PATH="$T/cc/fake:$PATH" HOME="$T/cc" \
      CLAUDE_CONFIG_DIR="$T/cc/cfg" CLAUDE_CODE_OAUTH_TOKEN=tok-max1-fixture ANTHROPIC_API_KEY= \
      AUTH_ACCOUNTS_CATALOG="$T/empty-catalog.json" AUTH_ACCOUNTS_LOCAL="$T/cc/state-none.json" \
      LLM_GATE_DISABLE=1 CALL_GUARD=0 "$@" "$T/cc/bin/claude-cost.sh" -p --model claude-opus-5-5 "hi" </dev/null >/dev/null 2>&1 )
}
ccrow() { tail -n +2 "$T/cc/logs/cost.csv" 2>/dev/null | tail -1; }
cc env COST_ACCT_NAME=max1 ORC_ACCOUNT_LABEL=max1@example.com
RD1=$(ccrow)
[ "$(fld "$RD1" 16)" = max1@example.com ] && ok || bad "AC1(d) claude-cost with ORC_ACCOUNT_LABEL: field 16 '$(fld "$RD1" 16)': $RD1"
case ";$(fld "$RD1" 24);" in *";acct=max1;"*) ok ;; *) bad "AC1(d) claude-cost note lacks acct=max1: '$(fld "$RD1" 24)'" ;; esac
cc env COST_ACCT_NAME=max1
RD2=$(ccrow)
[ "$(fld "$RD2" 16)" = max1@example.com ] && ok || bad "AC1(d) claude-cost, registry only: field 16 '$(fld "$RD2" 16)': $RD2"

# (e) the ticket's literal AC: all four rows carry one identical field 16
U=$(printf '%s\n%s\n%s\n%s\n%s\n' "$(fld "$RA" 16)" "$(fld "$RB" 16)" "$(fld "$RC_" 16)" "$(fld "$RD1" 16)" "$(fld "$RD2" 16)" | sort -u)
[ "$U" = max1@example.com ] && ok || bad "AC1(e) one account wrote $(printf '%s' "$U" | grep -c .) spellings: $(printf '%s' "$U" | tr '\n' ' ')"

# (f) negatives
reset
rc=$(call "$T/o-f1" triage "a1" ACCOUNT_ROUTING=1 PICK_OUT='name=max9\nreason=picked\nexport CLAUDE_CODE_OAUTH_TOKEN=tok-max9-fixture')
[ "$(fld "$(lastrow claude)" 16)" = acct:max9 ] && ok || bad "AC1(f) an unlabelled account must stay acct:max9: $(lastrow claude)"
reset
rc=$(call "$T/o-f2" triage "a1" ACCOUNT_ROUTING=1 PICK_OUT='name=../x\nreason=picked\nexport CLAUDE_CODE_OAUTH_TOKEN=tok-x-fixture')
RF2=$(lastrow claude)
[ "$(fld "$RF2" 16)" = "acct:../x" ] && ok || bad "AC1(f) an unsafe name must fall back to acct:../x: $RF2"
grep -q SENTINEL "$T/logs/cost.csv" && bad "AC1(f) a name outside accounts.d read $T/env/x.env: $RF2" || ok
reset
printf '{"%s":"claude:operator@example.com"}\n' "$FP1" > "$T/state/auth-accounts.local.json"
rc=$(call "$T/o-f3" triage "a1" ACCOUNT_ROUTING=1 PICK_OUT="$PICK1")
RF3=$(lastrow claude)
[ "$(fld "$RF3" 16)" = claude:operator@example.com ] && ok || bad "AC1(f) a live fp label must beat the picker's label: $RF3"
case ";$(fld "$RF3" 24);" in *";acct="*) bad "AC1(f) an fp-labelled row carries an acct= note: '$(fld "$RF3" 24)'" ;; *) ok ;; esac
# The pinned own account (BH-1657) and the lib contract both writers call.
LIBOUT=$( unset HARNESS_ENV_DIR ACCOUNTS_DIR; HARNESS="$T"; . "$DIR/bin/lib/cost-row.sh" 2>/dev/null
  command -v cost_row_auth_account >/dev/null || { echo missing; exit 0; }
  cost_row_auth_account unknown "own:project-3" "" 1;  printf 'pin=%s/%s\n' "$COST_ROW_AUTH_ACCOUNT" "$COST_ROW_ACCT_FROM"
  cost_row_auth_account unknown max5 "" 0;        printf 'reg=%s/%s\n' "$COST_ROW_AUTH_ACCOUNT" "$COST_ROW_ACCT_FROM"
  cost_row_auth_account unknown default "x@y" 0;  printf 'def=%s/%s\n' "$COST_ROW_AUTH_ACCOUNT" "$COST_ROW_ACCT_FROM"
  cost_row_auth_account unknown max1 $'a,b\n"c' 0; printf 'san=%s/%s\n' "$COST_ROW_AUTH_ACCOUNT" "$COST_ROW_ACCT_FROM"
  cost_row_auth_account "fp@x" max1 "max1@example.com" 0; printf 'fp=%s/%s\n' "$COST_ROW_AUTH_ACCOUNT" "$COST_ROW_ACCT_FROM" )
grep -qx 'pin=own:project-3/pinned' <<<"$LIBOUT" && ok || bad "AC1(f) a pinned account must ride verbatim as 'pinned': $LIBOUT"
grep -qx 'reg=max5@example.com/registry' <<<"$LIBOUT" && ok || bad "AC1(f) a quoted registry label must be unquoted: $LIBOUT"
grep -qx 'def=unknown/none' <<<"$LIBOUT" && ok || bad "AC1(f) the default account stays unknown: $LIBOUT"
grep -qx 'san=abc/label' <<<"$LIBOUT" && ok || bad "AC1(f) a picker label must be stripped of , \" and newlines: $LIBOUT"
grep -qx 'fp=fp@x/fp' <<<"$LIBOUT" && ok || bad "AC1(f) the fp label wins in the lib: $LIBOUT"

# (g) no token anywhere a row lands
if grep -rq tok-max1-fixture "$T/logs" "$T/cc/logs" 2>/dev/null; then bad "AC1(g) the fixture token leaked into a log"; else ok; fi

# ============================================================================
# AC2 — the served model in field 6, the requested one in the note
# ============================================================================
# (a) claude fails, the call falls through to the tier-2 grok rung
reset
rc=$(call "$T/o-2a" triage "a2" LADDER_TIER2_GROK=1 CLAUDE_RESULT=fail)
G=$(lastrow grok)
[ "$(fld "$G" 5)" = grok ] && [ "$(fld "$G" 6)" = grok-4.6 ] && ok || bad "AC2(a) the grok row must say grok/grok-4.6 (rc $rc): $G"
case ";$(fld "$G" 24);" in *";requested_model=claude-opus-5-5;"*) ok ;; *) bad "AC2(a) the grok row's note lacks requested_model=claude-opus-5-5: '$(fld "$G" 24)'" ;; esac

# (b) the prod shape: a grok primary refused by the call guard
reset
r1=$(call "$T/o-2b" triage "same work" RUNNER_TRIAGE=grok CALL_GUARD=1 CALL_GUARD_STAGES=triage CALL_GUARD_MAX_MAP=triage=1)
r2=$(call "$T/o-2b2" triage "same work" RUNNER_TRIAGE=grok CALL_GUARD=1 CALL_GUARD_STAGES=triage CALL_GUARD_MAX_MAP=triage=1)
RR=$(awk -F, 'NR>1 && $18=="refused" {l=$0} END{print l}' "$T/logs/cost.csv")
[ "$r1" = 0 ] && [ "$r2" = 74 ] && [ -n "$RR" ] && ok || bad "AC2(b) setup: rcs $r1/$r2, refused row '$RR'"
[ "$(fld "$RR" 5)" = grok ] && [ "$(fld "$RR" 6)" = grok-4.6 ] && ok || bad "AC2(b) the refused grok row must carry grok-4.6, got '$(fld "$RR" 6)': $RR"
case "$(fld "$RR" 24)" in refused:call-guard:repeat*) ok ;; *) bad "AC2(b) the note must still START with refused:call-guard:repeat: '$(fld "$RR" 24)'" ;; esac
case "$(fld "$RR" 24)" in *requested_model=claude-opus-5-5*) ok ;; *) bad "AC2(b) the refused note lacks requested_model=claude-opus-5-5: '$(fld "$RR" 24)'" ;; esac

# (c) the tripwire refusal, a grok execute primary
reset
echo "rule-x fired" > "$T/builds/b1/TRIPWIRE"
rc=$(call "$T/builds/b1/out" execute "a2c" RUNNER_EXECUTE=grok)
RT=$(awk -F, 'NR>1 && $18=="refused" {l=$0} END{print l}' "$T/logs/cost.csv")
[ "$rc" = 74 ] && [ "$(fld "$RT" 5)" = grok ] && [ "$(fld "$RT" 6)" = grok-4.6 ] && ok || bad "AC2(c) tripwire row must carry grok-4.6 (rc $rc): $RT"
case "$(fld "$RT" 24)" in refused:tripwire*requested_model=claude-opus-5-5*) ok ;; *) bad "AC2(c) tripwire note '$(fld "$RT" 24)'" ;; esac

# (d) claude: a guard refusal and a served call carry no token
reset
call "$T/o-2d" triage "claude work" CALL_GUARD=1 CALL_GUARD_STAGES=triage CALL_GUARD_MAX_MAP=triage=1 >/dev/null
call "$T/o-2d2" triage "claude work" CALL_GUARD=1 CALL_GUARD_STAGES=triage CALL_GUARD_MAX_MAP=triage=1 >/dev/null
RCR=$(awk -F, 'NR>1 && $18=="refused" {l=$0} END{print l}' "$T/logs/cost.csv")
RCS=$(awk -F, 'NR>1 && $18!="refused" && $5=="claude" {l=$0} END{print l}' "$T/logs/cost.csv")
[ "$(fld "$RCR" 6)" = claude-opus-5-5 ] && ok || bad "AC2(d) a refused claude row keeps claude-opus-5-5: $RCR"
[ "$(fld "$RCR" 24)" = "refused:call-guard:repeat" ] && ok || bad "AC2(d) a refused claude row's note must be unchanged: '$(fld "$RCR" 24)'"
[ "$(fld "$RCS" 6)" = claude-opus-5-5 ] && ok || bad "AC2(d) the served claude row: $RCS"
grep -q requested_model= "$T/logs/cost.csv" && bad "AC2(d) a claude row that served what was asked carries requested_model=: $(grep requested_model= "$T/logs/cost.csv")" || ok

# (e) no grok.default route: the honest fallback, still a row, still the note
reset
rm -f "$T/state/model-routes/grok.default.tsv" "$T/state/model-routes/grok.default@testproj.tsv"
echo "rule-x fired" > "$T/builds/b1/TRIPWIRE"
rc=$(call "$T/builds/b1/out" execute "a2e" RUNNER_EXECUTE=grok)
RM=$(awk -F, 'NR>1 && $18=="refused" {l=$0} END{print l}' "$T/logs/cost.csv")
[ "$rc" = 74 ] && [ "$(fld "$RM" 6)" = claude-opus-5-5 ] && ok || bad "AC2(e) a route miss keeps the requested model (rc $rc): $RM"
case "$(fld "$RM" 24)" in refused:tripwire*requested_model=claude-opus-5-5*) ok ;; *) bad "AC2(e) route-miss note '$(fld "$RM" 24)'" ;; esac
mrs_fixture "$T" testproj

# ============================================================================
# AC4 — a stale bin/lib/cost-row.sh (no cost_row_auth_account, no
# cost_row_model_note) still writes the pre-BH-3986 row. Under set -u the
# missing function used to leave COST_ROW_AUTH_ACCOUNT unbound and kill the
# writer AFTER the paid call: rc 127 and no row.
# ============================================================================
stale_lib() {
  awk '/^cost_row_auth_account\(\) \{/ || /^cost_row_model_note\(\) \{/ {skip=1; next}
       skip && /^\}/ {skip=0; next} !skip' "$DIR/bin/lib/cost-row.sh" > "$1"
}
mkdir -p "$T/stale"; cp -r "$DIR/bin/." "$T/stale/"; stale_lib "$T/stale/lib/cost-row.sh"
grep -q 'cost_row_auth_account()\|cost_row_model_note()' "$T/stale/lib/cost-row.sh" && bad "AC4 setup: the stale lib still defines the new functions" || ok
reset
rc=$(call "$T/o-s1" triage "a1" AC_BIN="$T/stale" ACCOUNT_ROUTING=1 PICK_OUT="$PICK1")
RS1=$(lastrow claude)
[ "$rc" = 0 ] && [ "$(fld "$RS1" 16)" = acct:max1 ] && ok || bad "AC4 agent-call on a stale lib must write acct:max1 and rc 0 (rc $rc): $RS1"
reset
printf '{"%s":"max1@example.com"}\n' "$FP1" > "$T/state/auth-accounts.local.json"
rc=$(call "$T/o-s3" triage "a1" AC_BIN="$T/stale")
[ "$rc" = 0 ] && [ "$(fld "$(lastrow claude)" 16)" = max1@example.com ] && ok || bad "AC4 agent-call on a stale lib must keep the fp label (rc $rc): $(lastrow claude)"
mkdir -p "$T/cc/stale"; cp -r "$T/cc/bin/." "$T/cc/stale/"; stale_lib "$T/cc/stale/lib/cost-row.sh"
mv "$T/cc/bin" "$T/cc/bin.new"; mv "$T/cc/stale" "$T/cc/bin"
cc env COST_ACCT_NAME=max1 ORC_ACCOUNT_LABEL=max1@example.com
RS4=$(ccrow)
mv "$T/cc/bin" "$T/cc/stale"; mv "$T/cc/bin.new" "$T/cc/bin"
[ "$(fld "$RS4" 16)" = acct:max1 ] && ok || bad "AC4 claude-cost on a stale lib must write acct:max1: '$RS4'"
LIBSTUB=$( unset HARNESS_ENV_DIR ACCOUNTS_DIR; set -u; HARNESS="$T"; . "$T/stale/lib/cost-row.sh" 2>/dev/null
  eval "$(sed -n '/^command -v cost_row_auth_account /,/^}/p; /^command -v cost_row_model_note /p' "$DIR/bin/agent-call.sh")"
  cost_row_auth_account unknown "own:project-3" "" 1;  printf 'pin=%s/%s\n' "$COST_ROW_AUTH_ACCOUNT" "$COST_ROW_ACCT_FROM"
  cost_row_auth_account unknown default "" 0;     printf 'def=%s/%s\n' "$COST_ROW_AUTH_ACCOUNT" "$COST_ROW_ACCT_FROM"
  cost_row_auth_account "fp@x" max1 "" 0;         printf 'fp=%s/%s\n' "$COST_ROW_AUTH_ACCOUNT" "$COST_ROW_ACCT_FROM"
  printf 'note=[%s]\n' "$(cost_row_model_note grok-4.6 claude-opus-5-5)" )
grep -qx 'pin=own:project-3/pinned' <<<"$LIBSTUB" && grep -qx 'def=unknown/none' <<<"$LIBSTUB" && grep -qx 'fp=fp@x/fp' <<<"$LIBSTUB" \
  && grep -qx 'note=\[\]' <<<"$LIBSTUB" && ok || bad "AC4 the agent-call stubs must reproduce the pre-BH-3986 rule: $LIBSTUB"
cmp -s <(sed -n '/^command -v cost_row_auth_account /,/^command -v cost_row_model_note /p' "$DIR/bin/agent-call.sh") \
       <(sed -n '/^command -v cost_row_auth_account /,/^command -v cost_row_model_note /p' "$DIR/bin/claude-cost.sh") \
  && ok || bad "AC4 agent-call.sh and claude-cost.sh carry different stale-lib stubs"

# ============================================================================
# AC3 — the backfill generator, dry-run only
# ============================================================================
BF="$DIR/bin/cost-rows-acct-backfill.sh"
if [ ! -x "$BF" ]; then
  bad "AC3 bin/cost-rows-acct-backfill.sh is missing or not executable"
else
  SQL=$(bash "$BF" --accounts-dir "$T/env/accounts.d" 2>"$T/bf.err"); brc=$?
  [ "$brc" = 0 ] && ok || bad "AC3(a) rc $brc: $(cat "$T/bf.err")"
  [ "$(grep -c '^UPDATE cost_rows' <<<"$SQL")" = 2 ] && ok || bad "AC3(a) want exactly 2 UPDATE blocks: $SQL"
  grep -qF "SET auth_account = 'max1@example.com'" <<<"$SQL" && grep -qF "SET auth_account = 'max5@example.com'" <<<"$SQL" \
    && ok || bad "AC3(a) max1/max5 targets missing: $SQL"
  grep -qF "raw = REPLACE(raw, ',acct:max1,', ',max1@example.com,')" <<<"$SQL" && ok || bad "AC3(a) the raw REPLACE clause is missing: $SQL"
  grep -qF "before_max1" <<<"$SQL" && grep -qF "after_max1" <<<"$SQL" && ok || bad "AC3(a) before_/after_ SELECTs missing"
  grep -q max9 <<<"$SQL" && bad "AC3(a) an unlabelled account got a block: $SQL" || ok
  grep -q tok-max1-fixture <<<"$SQL" && bad "AC3(e) the fixture token is in the SQL" || ok
  # (b) quoting and refusal
  mkdir -p "$T/bfq" "$T/bfc" "$T/bfe"
  printf 'ACCOUNT_NAME=max2\nACCOUNT_LABEL=o'"'"'neil@x.test\n' > "$T/bfq/max2.env"
  SQLQ=$(bash "$BF" --accounts-dir "$T/bfq" 2>/dev/null)
  grep -qF "'o''neil@x.test'" <<<"$SQLQ" && ok || bad "AC3(b) a quote in the label must be doubled: $SQLQ"
  printf 'ACCOUNT_NAME=max3\nACCOUNT_LABEL=a,b@x.test\n' > "$T/bfc/max3.env"
  SQLC=$(bash "$BF" --accounts-dir "$T/bfc" 2>/dev/null); crc=$?
  [ "$crc" = 2 ] && [ -z "$SQLC" ] && ok || bad "AC3(b) a comma label must be rc 2 with no SQL (rc $crc): $SQLC"
  # (c) nothing to emit
  bash "$BF" --accounts-dir "$T/bfe" >"$T/bfe.out" 2>&1; erc=$?
  [ "$erc" = 1 ] && grep -qi 'no account' "$T/bfe.out" && ok || bad "AC3(c) an empty dir must be rc 1 with a message (rc $erc): $(cat "$T/bfe.out")"
  # --out writes the same SQL to a file
  bash "$BF" --accounts-dir "$T/env/accounts.d" --out "$T/bf.sql" >/dev/null 2>&1
  [ "$(cat "$T/bf.sql" 2>/dev/null)" = "$SQL" ] && ok || bad "AC3 --out did not write the printed SQL"
  # (d) apply it to a scratch table built from the worker's own schema
  if command -v python3 >/dev/null && python3 -c 'import sqlite3' 2>/dev/null; then
    DOUT=$(python3 - "$DIR/worker/jobs/schema.sql" "$T/bf.sql" <<'PY'
import sqlite3, sys
db = sqlite3.connect(':memory:')
db.executescript(open(sys.argv[1]).read())
def line(acct, i):
    return ','.join(['2026-10-01T00:00:0%dZ' % i, 'orgo-desktop', 'p', 'triage', 'claude', 'm', '0', '1',
                     '1', '1', '0', '0', '0.01', 'subscription', 'fp', acct, 's', 'transcript', '', '', '', '', '', 'acct=max1', '', ''])
rows = [('acct:max1', 1), ('acct:max1', 2), ('acct:max1', 3), ('max1@example.com', 4), ('acct:max10', 5)]
for a, i in rows:
    db.execute("INSERT INTO cost_rows (box,row_hash,line_no,auth_account,raw,inserted_at) VALUES ('b',?,?,?,?,'2026-10-01T00:00:00Z')", ('h%d' % i, i, a, line(a, i)))
sql = open(sys.argv[2]).read()
db.executescript(sql)
left = db.execute("SELECT COUNT(*) FROM cost_rows WHERE auth_account='acct:max1'").fetchone()[0]
same = db.execute("SELECT COUNT(DISTINCT auth_account), COUNT(*) FROM cost_rows WHERE row_hash IN ('h1','h2','h3','h4')").fetchone()
raw_ok = all(r.split(',')[15] == a for a, r in db.execute("SELECT auth_account, raw FROM cost_rows"))
ten = db.execute("SELECT auth_account FROM cost_rows WHERE row_hash='h5'").fetchone()[0]
before = db.total_changes
db.executescript(sql)
print('left=%d distinct=%d n=%d raw=%s ten=%s rerun=%d' % (left, same[0], same[1], raw_ok, ten, db.total_changes - before))
PY
)
    [ "$DOUT" = "left=0 distinct=1 n=4 raw=True ten=acct:max10 rerun=0" ] && ok || bad "AC3(d) applied SQL result: $DOUT"
  else
    echo "AC3(d) skipped: no python3 sqlite3 module on this box"
  fi
fi

echo "cost-row-attribution.bh-3986: $PASS pass, $FAIL fail"; [ "$FAIL" -eq 0 ]
