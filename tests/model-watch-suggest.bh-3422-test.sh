#!/bin/bash
# tests/model-watch-suggest.bh-3422-test.sh — BH-3427 (BH-3422.2): the
# model-watch suggestion, probe and message library bin/lib/model-watch-suggest.sh.
#   F1-F3  mw_family / mw_version / _mws_ver_gt over fixture ids (base, dotted,
#          vendor-prefixed, suffix variant, dated snapshot, no numeric run).
#   A3     mw_match_routes maps the sonnet-5 rungs, and only them, to a new
#          sonnet-5-5 (jq equality against the expected array).
#   N1-N5  no match for another family, an equal/lower version, a dated
#          snapshot, a suffix variant, another vendor, an openrouter rung;
#          unparseable routes are rc 1 with nothing printed.
#   A3b    mw_delta_per_day to the cent; no spend; a missing price is
#          `unknown`, never $0; unreadable usage. A3c: the usage route's real
#          flat shape.
#   V1-V5, A4  mw_probe_verdict live / fallback / failed / not-run and its
#          rendered line.
#   A7     mw_probe_run through a recording agent-call shim: env prefix, argv,
#          stamp PUT before the call, cap 0, stamp failure, vendor, verdict PUT
#          failure. D1-D6: the row is read before any spend and a probed row
#          is not probed again (a not-run verdict may be). A7r runs the REAL bin/agent-call.sh with a fake claude.
#   A8     mw_cli_lag.
#   M1-M7  mw_message: line order, approve line only on live + routes + script,
#          lost probe, source link, no em dash.
#   L1-L2  the lib parses under set -u, no root literal on a code line, no
#          model id shape anywhere in the file.
#   HARNESS_TEST_SANDBOX=1 bash tests/model-watch-suggest.bh-3422-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

MWLIB="$DIR/bin/lib/model-watch.sh"
LIB="$DIR/bin/lib/model-watch-suggest.sh"
FX="$DIR/tests/fixtures/model-watch"
STUBS="$T/stubs.sh"
: > "$STUBS"

# mws <fn> [args...]: one lib call in a fresh shell (contract lib, this lib,
# then $STUBS), stdout only. The caller's env passes through.
mws() { bash -c 'set -u; . "$1"; . "$2"; . "$3"; shift 3; "$@"' _ "$MWLIB" "$LIB" "$STUBS" "$@" 2>/dev/null; }

# --- L1 / L2 ------------------------------------------------------------------
[ -f "$LIB" ] && bash -n "$LIB" && ok || bad "L1 bash -n $LIB"
bash -c 'set -u; . "$1"; . "$2"' _ "$MWLIB" "$LIB" 2>/dev/null && ok || bad "L1 set -u source $LIB"
n=$(grep -v '^[[:space:]]*#' "$LIB" 2>/dev/null | grep -c /root/harness)
[ -f "$LIB" ] && [ "$n" = 0 ] && ok || bad "L1 /root/harness on $n code line(s) of the lib (D43)"
hits=$(grep -En 'claude-[a-z]+-[0-9]|gpt-|accounts/fireworks/models' "$LIB" 2>/dev/null)
[ -f "$LIB" ] && [ -z "$hits" ] && ok || bad "L2 model id shape in the lib (R6): $hits"
# Without the contract lib every mw_* dependent refuses rather than guessing.
got=$(bash -c 'set -u; . "$1"; mw_family acme-5' _ "$LIB" 2>/dev/null); rc=$?
[ "$rc" = 1 ] && [ -z "$got" ] && ok || bad "L1 mw_family without model-watch.sh rc=$rc out=[$got], want rc 1"

# --- F1-F3 --------------------------------------------------------------------
for c in 'claude-sonnet-5-5|claude-sonnet-#|5.5' \
         'anthropic/claude-sonnet-5.5|claude-sonnet-#|5.5' \
         'claude-sonnet-5|claude-sonnet-#|5' \
         'claude-sonnet-5-5-mini|claude-sonnet-#-mini|5.5' \
         'claude-sonnet-5-5-20260101|claude-sonnet-#|5.5' \
         'claude-3-5-sonnet|claude-#-sonnet|3.5' \
         'claude-sonnet-5-2507|claude-sonnet-#-2507|5' \
         'acme-lyric|acme-lyric|'; do
  IFS='|' read -r id wf wv <<<"$c"
  gf=$(mws mw_family "$id"); gv=$(mws mw_version "$id")
  [ "$gf" = "$wf" ] && ok || bad "F1 mw_family $id -> [$gf], want [$wf]"
  [ "$gv" = "$wv" ] && ok || bad "F2 mw_version $id -> [$gv], want [$wv]"
done
for c in '5.5 5 0' '5 5.0 1' '5.0 5 1' '5.10 5.9 0' '4 5 1' '5.5.1 5.5 0' '5 4.9 0'; do
  read -r a b want <<<"$c"
  mws _mws_ver_gt "$a" "$b"; rc=$?
  [ "$rc" = "$want" ] && ok || bad "F3 _mws_ver_gt $a $b rc=$rc, want $want"
done

# --- A3 / N1-N5 ---------------------------------------------------------------
R="$FX/routes.json"
ROUTES=$(cat "$R")
want='[{"project":null,"role":"triage","position":0,"runner":"claude","from":"claude-sonnet-5"},
       {"project":"project-3","role":"build","position":1,"runner":"claude","from":"claude-sonnet-5"}]'
got=$(mws mw_match_routes anthropic claude-sonnet-5-5 "$ROUTES"); rc=$?
[ "$rc" = 0 ] && jq -e --argjson w "$want" '. == $w' <<<"$got" >/dev/null 2>&1 && ok || bad "A3 sonnet-5-5 -> [$got] rc=$rc"
got=$(mws mw_match_routes Anthropic anthropic/claude-sonnet-5.5 "$ROUTES")
jq -e --argjson w "$want" '. == $w' <<<"$got" >/dev/null 2>&1 && ok || bad "A3 vendor-prefixed dotted id -> [$got]"
# Controls: the other families DO match their own rungs, so the [] below is not vacuous.
got=$(mws mw_match_routes anthropic claude-opus-6 "$ROUTES")
jq -e '. == [{"project":"project-4","role":"review","position":0,"runner":"claude","from":"claude-opus-5"}]' <<<"$got" >/dev/null 2>&1 \
  && ok || bad "A3 control opus-6 -> only the opus rung, got [$got]"
got=$(mws mw_match_routes openai gpt-5-5 "$ROUTES")
jq -e '. == [{"project":null,"role":"build","position":1,"runner":"codex","from":"gpt-5"}]' <<<"$got" >/dev/null 2>&1 \
  && ok || bad "A3 control openai gpt-5-5 -> the codex rung, got [$got]"
for c in 'anthropic claude-lyric-9' 'anthropic claude-sonnet-5' 'anthropic claude-sonnet-5-0' \
         'anthropic claude-sonnet-4-5' 'anthropic claude-sonnet-5-20260101' 'anthropic claude-sonnet-5-2507' \
         'anthropic claude-sonnet-5-5-mini' 'anthropic claude-sonnet-5-5-fast' 'anthropic claude-sonnet-5-5-thinking' \
         'openai claude-sonnet-5-5' 'openrouter claude-sonnet-5-5' 'anthropic acme-lyric'; do
  read -r v id <<<"$c"
  got=$(mws mw_match_routes "$v" "$id" "$ROUTES"); rc=$?
  [ "$rc" = 0 ] && [ "$(jq -c . <<<"$got" 2>/dev/null)" = '[]' ] && ok || bad "N1-N4 $v $id -> [$got] rc=$rc, want []"
done
# An openrouter rung of the same family never matches (its vendor is ambiguous).
got=$(mws mw_match_routes anthropic claude-sonnet-5-5 '[{"project":"project-3","role":"triage","position":2,"model":"anthropic/claude-sonnet-5","runner":"openrouter"}]')
[ "$(jq -c . <<<"$got" 2>/dev/null)" = '[]' ] && ok || bad "N4 openrouter rung -> [$got], want []"
for r in 'not json' '{"a":1}' ''; do
  got=$(mws mw_match_routes anthropic claude-sonnet-5-5 "$r"); rc=$?
  [ "$rc" = 1 ] && [ -z "$got" ] && ok || bad "N5 routes [$r] rc=$rc out=[$got], want rc 1 and nothing"
done
# A non-object rung part-way through (or first) is unreadable, never the matches before it.
for r in "$(jq -c '. + [5]' <<<"$ROUTES")" "$(jq -c '[5] + .' <<<"$ROUTES")"; do
  got=$(mws mw_match_routes anthropic claude-sonnet-5-5 "$r"); rc=$?
  [ "$rc" = 1 ] && [ -z "$got" ] && ok || bad "N5 mixed routes rc=$rc out=[$got], want rc 1 and nothing"
done

# --- A3b ----------------------------------------------------------------------
NEWP=$(jq -c '.["claude-sonnet-5-5"]' "$FX/prices.json")
OLDP=$(jq -c '.["claude-sonnet-5"]' "$FX/prices.json")
USAGE=$(cat "$FX/usage.json")
# (8642000*1e-6 + 1000000*5e-6 + 20000000*1e-7 + 0*n/a) / 7 = 15.642/7 = 2.2346 -> +$2.23
got=$(mws mw_delta_per_day claude-sonnet-5 "$NEWP" "$OLDP" "$USAGE" claude-sonnet-5-5)
[ "$got" = '+$2.23/day' ] && ok || bad "A3b delta [$got], want +\$2.23/day"
got=$(mws mw_delta_per_day claude-sonnet-5-5 "$OLDP" "$NEWP" "$(jq -c '.tokens.cache_write=0' <<<"$USAGE")")
[ "$got" = '-$2.23/day' ] && ok || bad "A3b reverse delta [$got], want -\$2.23/day"
got=$(mws mw_delta_per_day claude-sonnet-5 "$NEWP" "$NEWP" "$USAGE")
[ "$got" = '$0.00/day' ] && ok || bad "A3b same price [$got], want \$0.00/day"
got=$(mws mw_delta_per_day claude-sonnet-5 "$NEWP" "$OLDP" "$(cat "$FX/usage-empty.json")")
[ "$got" = 'no spend on claude-sonnet-5 in 7 days' ] && ok || bad "A3b empty usage [$got]"
got=$(mws mw_delta_per_day claude-sonnet-5 "$NEWP" "$(jq -c '.["no-prompt"]' "$FX/prices.json")" "$USAGE")
[ "$got" = 'unknown (no list price for claude-sonnet-5)' ] && ok || bad "A3b old price w/o prompt [$got]"
got=$(mws mw_delta_per_day claude-sonnet-5 null "$OLDP" "$USAGE" claude-sonnet-5-5)
[ "$got" = 'unknown (no list price for claude-sonnet-5-5)' ] && ok || bad "A3b null new price [$got]"
got=$(mws mw_delta_per_day claude-sonnet-5 '' "$OLDP" "$USAGE")
[ "$got" = 'unknown (no list price for new model)' ] && ok || bad "A3b empty new price, no id [$got]"
# cache_write tokens > 0 against the old side's null cache_write price: unknown, not $0 for that kind.
got=$(mws mw_delta_per_day claude-sonnet-5 "$NEWP" "$OLDP" "$(jq -c '.tokens.cache_write=100' <<<"$USAGE")")
[ "$got" = 'unknown (no list price for claude-sonnet-5)' ] && ok || bad "A3b cache tokens vs null cache price [$got]"
for u in 'not json' '{"rows":"3"}' '[]' '{"rows":3,"tokens":{"prompt":1}}'; do
  got=$(mws mw_delta_per_day claude-sonnet-5 "$NEWP" "$OLDP" "$u"); rc=$?
  [ "$rc" = 0 ] && [ "$got" = 'unknown (usage unreadable)' ] && ok || bad "A3b usage [$u] -> [$got] rc=$rc"
done
# A3c: the shape GET /api/model-watch/usage really returns (BH-3426): flat
# input_toks / output_toks / cache_read / cache_write beside rows.
ROUTEU=$(jq -c '{model:"claude-sonnet-5", since:"2026-01-01", rows, input_toks:.tokens.prompt,
  output_toks:.tokens.completion, cache_read:.tokens.cache_read, cache_write:.tokens.cache_write}' <<<"$USAGE")
got=$(mws mw_delta_per_day claude-sonnet-5 "$NEWP" "$OLDP" "$ROUTEU" claude-sonnet-5-5)
[ "$got" = '+$2.23/day' ] && ok || bad "A3c route-shaped usage [$got], want +\$2.23/day"
got=$(mws mw_delta_per_day claude-sonnet-5 "$NEWP" "$OLDP" "$(jq -c '.rows=0' <<<"$ROUTEU")")
[ "$got" = 'no spend on claude-sonnet-5 in 7 days' ] && ok || bad "A3c route-shaped no spend [$got]"
got=$(mws mw_delta_per_day claude-sonnet-5 "$NEWP" "$OLDP" "$(jq -c 'del(.output_toks)' <<<"$ROUTEU")")
[ "$got" = 'unknown (usage unreadable)' ] && ok || bad "A3c route-shaped, a token sum missing [$got]"
# rows as a float zero is still no spend, not $0.00/day.
got=$(mws mw_delta_per_day claude-sonnet-5 "$NEWP" "$OLDP" "$(jq -c '.rows=0.0' "$FX/usage-empty.json")")
[ "$got" = 'no spend on claude-sonnet-5 in 7 days' ] && ok || bad "A3b rows 0.0 [$got]"

# --- V1-V5, A4 ----------------------------------------------------------------
v() { mws mw_probe_verdict "$@"; }
got=$(MWS_CLI_VERSION=2.1.284 v 0 "$FX/envelope-live.json" claude-sonnet-5-5)
jq -e '.verdict=="live" and .served=="claude-sonnet-5-5" and .rc==0 and .cost_usd==0.0123 and .cli=="2.1.284"' <<<"$got" >/dev/null 2>&1 \
  && ok || bad "V1 live [$got]"
got=$(v 0 "$FX/envelope-live.json" anthropic/claude-sonnet-5.5)
jq -e '.verdict=="live" and .cli==null' <<<"$got" >/dev/null 2>&1 && ok || bad "V1 normalized requested id [$got]"
line=$(mws mw_probe_line "$(v 0 "$FX/envelope-live.json" claude-sonnet-5-5)")
[ "$line" = 'Probe: live (served by claude-sonnet-5-5, $0.0123)' ] && ok || bad "V1 line [$line]"
got=$(v 0 "$FX/envelope-fallback.json" claude-sonnet-5-5)
jq -e '.verdict=="fallback" and .served=="claude-sonnet-5"' <<<"$got" >/dev/null 2>&1 && ok || bad "A4 fallback [$got]"
line=$(mws mw_probe_line "$got")
case "$line" in *'NOT live (silent fallback: served by claude-sonnet-5)'*) ok ;; *) bad "A4 line [$line]" ;; esac
got=$(v 1 "$FX/envelope-fallback.json" claude-sonnet-5-5)
jq -e '.verdict=="fallback"' <<<"$got" >/dev/null 2>&1 && ok || bad "A4 fallback whatever the rc [$got]"
got=$(v 0 "$FX/envelope-empty.json" claude-sonnet-5-5)
jq -e '.verdict=="failed" and .served==null and .cost_usd==0.001' <<<"$got" >/dev/null 2>&1 && ok || bad "V2 empty modelUsage [$got]"
got=$(v 1 "$FX/envelope-live.json" claude-sonnet-5-5)
jq -e '.verdict=="failed" and .rc==1' <<<"$got" >/dev/null 2>&1 && ok || bad "V2 matching key but rc 1 [$got]"
[ "$(mws mw_probe_line "$got")" = 'Probe: failed (rc 1)' ] && ok || bad "V2 line [$(mws mw_probe_line "$got")]"
for rc in 74 79; do
  got=$(v "$rc" "$FX/envelope-live.json" claude-sonnet-5-5)
  jq -e --argjson r "$rc" '.verdict=="not-run" and .served==null and .rc==$r' <<<"$got" >/dev/null 2>&1 && ok || bad "V3 rc $rc [$got]"
done
[ "$(mws mw_probe_line "$(v 74 "$FX/envelope-live.json" x)")" = 'Probe: not run (rc 74)' ] && ok || bad "V3 line"
: > "$T/empty.json"; echo 'not json' > "$T/garbage.json"
for f in "$T/missing.json" "$T/empty.json" "$T/garbage.json"; do
  got=$(v 0 "$f" claude-sonnet-5-5)
  jq -e '.verdict=="not-run" and .served==null' <<<"$got" >/dev/null 2>&1 && ok || bad "V4 envelope $f [$got]"
done
jq 'del(.total_cost_usd)' "$FX/envelope-live.json" > "$T/nocost.json"
got=$(v 0 "$T/nocost.json" claude-sonnet-5-5)
jq -e '.verdict=="live" and .cost_usd==null' <<<"$got" >/dev/null 2>&1 && ok || bad "V5 cost absent -> null [$got]"
line=$(mws mw_probe_line "$got")
case "$line" in *'$0'*) bad "V5 line prints a dollar figure for an absent cost [$line]" ;; 'Probe: live (served by claude-sonnet-5-5, cost unknown)') ok ;; *) bad "V5 line [$line]" ;; esac

# --- A7 -----------------------------------------------------------------------
H="$T/h"; PB="$T/pbin"; LOG="$T/a7.log"
mkdir -p "$H/bin" "$PB" "$T/out"
cat > "$H/bin/agent-call.sh" <<'EOF'
#!/bin/bash
{ echo "CALL $*"
  env | grep -E '^(AGENT_CALL_[A-Z_]*|RUNNER_PROBE)=' | sort | sed 's/^/ENV /'; } >> "$A7LOG"
[ -n "${SHIM_FIXTURE:-}" ] && cp "$SHIM_FIXTURE" "$5.json"
exit "${SHIM_RC:-0}"
EOF
printf '#!/bin/bash\necho "2.1.284 (Claude Code)"\n' > "$PB/claude"
chmod +x "$H/bin/agent-call.sh" "$PB/claude"
cat > "$STUBS" <<'EOF'
mw_get() {
  echo "GET $*" >> "$A7LOG"
  [ "${GET_FAIL:-0}" = 1 ] && return 1
  local b=${MWGET_BODY:-}
  [ -n "$b" ] || b='{"rows":[{"vendor":"anthropic","model_id":"claude-sonnet-5-5"}],"truncated":false}'
  printf '%s\n' "$b"
}
mw_set_state() {
  local n; n=$(grep -c '^STATE' "$A7LOG" 2>/dev/null)
  echo "STATE $1" >> "$A7LOG"
  [ "$((n+1))" = "${STATE_FAIL_ON:-0}" ] && return 1
  echo '{"ok":true}'
}
EOF
a7() { : > "$LOG"; A7LOG="$LOG" HARNESS="$H" PATH="$PB:$PATH" mws mw_probe_run "$@"; }

got=$(SHIM_FIXTURE="$FX/envelope-live.json" a7 anthropic claude-sonnet-5-5 "$T/out"); rc=$?
[ "$rc" = 0 ] && jq -e '.verdict=="live" and .cli=="2.1.284"' <<<"$got" >/dev/null 2>&1 && ok || bad "A7 live verdict rc=$rc [$got]"
grep -qx 'ENV AGENT_CALL_BUDGET_USD_PROBE=1' "$LOG" && ok || bad "A7 cap env: $(cat "$LOG")"
grep -qx 'ENV AGENT_CALL_RUNNERS=claude' "$LOG" && ok || bad "A7 runners env"
grep -qx 'ENV RUNNER_PROBE=claude' "$LOG" && ok || bad "A7 RUNNER_PROBE env"
grep -qx 'ENV AGENT_CALL_LEDGER=0' "$LOG" && ok || bad "A7 ledger off"
grep -qx 'ENV AGENT_CALL_FP=model-watch:anthropic:claude-sonnet-5-5' "$LOG" && ok || bad "A7 fingerprint"
grep -q "^CALL probe model-watch claude-sonnet-5-5 120 $T/out/out " "$LOG" && ok || bad "A7 argv: $(grep '^CALL' "$LOG")"
order=$(grep -oE '^(STATE|CALL)' "$LOG" | paste -sd, -)
[ "$order" = 'STATE,CALL,STATE' ] && ok || bad "A7 order [$order], want STATE,CALL,STATE"
order=$(grep -oE '^(GET|STATE|CALL)' "$LOG" | paste -sd, -)
[ "$order" = 'GET,STATE,CALL,STATE' ] && ok || bad "A7 dedup read first [$order], want GET,STATE,CALL,STATE"
grep '^STATE' "$LOG" | sed -n 1p | grep -q '"probe_attempted_at":"20' && ok || bad "A7 first PUT is the attempt stamp: $(sed -n 1p "$LOG")"
last=$(grep '^STATE' "$LOG" | tail -1 | cut -c7-)
jq -e '.vendor=="anthropic" and .model_id=="claude-sonnet-5-5" and ((.probe|fromjson).verdict=="live")' <<<"$last" >/dev/null 2>&1 \
  && ok || bad "A7 verdict PUT [$last]"
# The env prefix is per command: nothing leaks into the caller's shell.
leak=$(A7LOG="$LOG" HARNESS="$H" PATH="$PB:$PATH" bash -c '. "$1"; . "$2"; . "$3"; mw_probe_run anthropic claude-sonnet-5-5 "$4" >/dev/null; echo "${AGENT_CALL_RUNNERS-unset}${AGENT_CALL_BUDGET_USD_PROBE-unset}"' _ "$MWLIB" "$LIB" "$STUBS" "$T/out" 2>/dev/null)
[ "$leak" = unsetunset ] && ok || bad "A7 env leaked into the caller [$leak]"
got=$(MODEL_WATCH_PROBE_USD_CAP=0.1 SHIM_FIXTURE="$FX/envelope-live.json" a7 anthropic claude-sonnet-5-5 "$T/out")
grep -qx 'ENV AGENT_CALL_BUDGET_USD_PROBE=0.1' "$LOG" && ok || bad "A7 cap knob honoured"
got=$(SHIM_FIXTURE="$FX/envelope-fallback.json" a7 anthropic claude-sonnet-5-5 "$T/out")
jq -e '.verdict=="fallback"' <<<"$got" >/dev/null 2>&1 && ok || bad "A7 fallback through the shim [$got]"
# A stale out.json from an earlier probe is never read as this probe's envelope.
cp "$FX/envelope-live.json" "$T/out/out.json"
got=$(SHIM_RC=74 a7 anthropic claude-sonnet-5-5 "$T/out")
jq -e '.verdict=="not-run" and .rc==74' <<<"$got" >/dev/null 2>&1 && ok || bad "A7 rc 74 -> not-run [$got]"
cp "$FX/envelope-live.json" "$T/out/out.json"
got=$(a7 anthropic claude-sonnet-5-5 "$T/out")
jq -e '.verdict=="not-run"' <<<"$got" >/dev/null 2>&1 && ok || bad "A7 stale out.json read as live [$got]"
for cap in 0 0.0; do
  got=$(MODEL_WATCH_PROBE_USD_CAP=$cap a7 anthropic claude-sonnet-5-5 "$T/out"); rc=$?
  [ "$rc" = 0 ] && jq -e '.verdict=="not-run" and .reason=="probe disabled"' <<<"$got" >/dev/null 2>&1 && ok || bad "A7 cap $cap rc=$rc [$got]"
  [ ! -s "$LOG" ] && ok || bad "A7 cap $cap made a PUT or a call: $(cat "$LOG")"
done
for cap in abc -1 '0.25x'; do
  got=$(MODEL_WATCH_PROBE_USD_CAP=$cap a7 anthropic claude-sonnet-5-5 "$T/out"); rc=$?
  [ "$rc" = 1 ] && [ -z "$got" ] && [ ! -s "$LOG" ] && ok || bad "A7 cap [$cap] rc=$rc out=[$got] log=$(cat "$LOG")"
done
got=$(STATE_FAIL_ON=1 a7 anthropic claude-sonnet-5-5 "$T/out"); rc=$?
[ "$rc" = 1 ] && [ -z "$got" ] && ok || bad "A7 stamp PUT failure rc=$rc out=[$got], want rc 1 and nothing"
! grep -q '^CALL' "$LOG" && ok || bad "A7 stamp PUT failed but agent-call ran"
got=$(a7 openai gpt-5-5 "$T/out"); rc=$?
[ "$rc" = 0 ] && jq -e '.verdict=="not-run" and .reason=="no probe runner for openai"' <<<"$got" >/dev/null 2>&1 && ok || bad "A7 vendor openai rc=$rc [$got]"
[ ! -s "$LOG" ] && ok || bad "A7 vendor openai made a PUT or a call"
got=$(SHIM_FIXTURE="$FX/envelope-live.json" STATE_FAIL_ON=2 a7 anthropic claude-sonnet-5-5 "$T/out"); rc=$?
[ "$rc" = 2 ] && jq -e '.verdict=="live"' <<<"$got" >/dev/null 2>&1 && ok || bad "A7 verdict PUT failure rc=$rc [$got], want rc 2 and the verdict"
# D1-D6: dedup before spend. A row that already carries an attempt stamp is
# never probed again unless its recorded verdict is not-run (nothing billed).
mwrow() { jq -nc --argjson r "$1" --argjson t "${2:-false}" '{rows:[{vendor:"anthropic", model_id:"claude-sonnet-5-5"} + $r], truncated:$t}'; }
LIVEP=$(jq -c '{probe:({verdict:"live", served:"claude-sonnet-5-5", rc:0} | tojson), probe_attempted_at:"2026-01-01T00:00:00Z"}' <<<null)
got=$(MWGET_BODY=$(mwrow "$LIVEP") SHIM_FIXTURE="$FX/envelope-live.json" a7 anthropic claude-sonnet-5-5 "$T/out"); rc=$?
[ "$rc" = 0 ] && jq -e '.verdict=="not-run" and (.reason | startswith("already probed"))' <<<"$got" >/dev/null 2>&1 && ok || bad "D1 probed row rc=$rc [$got]"
! grep -qE '^(STATE|CALL)' "$LOG" && ok || bad "D1 probed row made a PUT or a call: $(cat "$LOG")"
got=$(MWGET_BODY=$(mwrow '{"probe_attempted_at":"2026-01-01T00:00:00Z"}') a7 anthropic claude-sonnet-5-5 "$T/out"); rc=$?
[ "$rc" = 0 ] && jq -e '.verdict=="not-run" and (.reason | startswith("already probed"))' <<<"$got" >/dev/null 2>&1 \
  && ! grep -qE '^(STATE|CALL)' "$LOG" && ok || bad "D2 lost probe (stamp, no verdict) is not re-bought rc=$rc [$got] $(cat "$LOG")"
NRP=$(jq -c '{probe:({verdict:"not-run", reason:"rc 74", rc:74} | tojson), probe_attempted_at:"2026-01-01T00:00:00Z"}' <<<null)
got=$(MWGET_BODY=$(mwrow "$NRP") SHIM_FIXTURE="$FX/envelope-live.json" a7 anthropic claude-sonnet-5-5 "$T/out"); rc=$?
[ "$rc" = 0 ] && jq -e '.verdict=="live"' <<<"$got" >/dev/null 2>&1 && grep -q '^CALL' "$LOG" && ok || bad "D3 not-run verdict re-probes rc=$rc [$got]"
got=$(GET_FAIL=1 a7 anthropic claude-sonnet-5-5 "$T/out"); rc=$?
[ "$rc" = 1 ] && [ -z "$got" ] && ! grep -qE '^(STATE|CALL)' "$LOG" && ok || bad "D4 unreadable row: rc=$rc [$got] $(cat "$LOG")"
got=$(MWGET_BODY='{"rows":[],"truncated":false}' a7 anthropic claude-sonnet-5-5 "$T/out"); rc=$?
[ "$rc" = 1 ] && [ -z "$got" ] && ! grep -qE '^(STATE|CALL)' "$LOG" && ok || bad "D5 no row: rc=$rc [$got] $(cat "$LOG")"
got=$(MWGET_BODY='{"rows":[{"vendor":"anthropic","model_id":"other"}],"truncated":true}' a7 anthropic claude-sonnet-5-5 "$T/out"); rc=$?
[ "$rc" = 1 ] && ! grep -qE '^(STATE|CALL)' "$LOG" && ok || bad "D6 truncated list without the row: rc=$rc [$got]"
got=$(MWGET_BODY='not json' a7 anthropic claude-sonnet-5-5 "$T/out"); rc=$?
[ "$rc" = 1 ] && ! grep -qE '^(STATE|CALL)' "$LOG" && ok || bad "D6 garbage list: rc=$rc [$got]"
got=$(: > "$LOG"; A7LOG="$LOG" HARNESS="$T/nowhere" PATH="$PB:$PATH" mws mw_probe_run anthropic claude-sonnet-5-5 "$T/out"); rc=$?
[ "$rc" = 1 ] && jq -e '.reason=="no agent-call"' <<<"$got" >/dev/null 2>&1 && [ ! -s "$LOG" ] && ok || bad "A7 no agent-call rc=$rc [$got]"
got=$(: > "$LOG"; A7LOG="$LOG" PATH="$PB:$PATH" mws mw_probe_run anthropic claude-sonnet-5-5 "$T/out"); rc=$?
[ "$rc" = 1 ] && [ ! -s "$LOG" ] && ok || bad "A7 empty root rc=$rc [$got]"

# --- A7r: the REAL bin/agent-call.sh, a fake claude CLI -----------------------
# Proves the envelope lands where mw_probe_verdict reads it ($outdir/out.json)
# and the model id reaches the CLI.
A="$T/ac"
mkdir -p "$A/bin" "$A/fakebin" "$A/flags" "$A/locks" "$A/logs" "$A/state" "$T/rout"
ln -s "$DIR/bin/agent-call.sh" "$A/bin/agent-call.sh"
cat > "$A/fakebin/claude" <<EOF
#!/bin/bash
[ "\${1:-}" = --version ] && { echo "2.1.284 (Claude Code)"; exit 0; }
echo "\$*" >> "$T/claude-argv"
cat >/dev/null
cat "$FX/envelope-live.json"
EOF
cat > "$A/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
printf '#!/bin/bash\necho subscription\n' > "$A/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$A/bin/beat.sh"
printf '#!/bin/bash\necho "test rules"\n' > "$A/bin/sync-agent-rules.sh"
chmod +x "$A/fakebin/"* "$A/bin/"*.sh
cat > "$T/stubs-real.sh" <<'EOF'
mw_get() { echo '{"rows":[{"vendor":"anthropic","model_id":"claude-sonnet-5-5"}],"truncated":false}'; }
mw_set_state() { echo '{"ok":true}'; }
EOF
got=$( unset HARNESS_SECRET JOBS_URL CONSOLE_URL
  export PATH="$A/fakebin:$PATH" HARNESS="$A" HOME="$A" LADDER_BACKOFF_SECS=0 CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json"
  bash -c 'set -u; . "$1"; . "$2"; . "$3"; mw_probe_run anthropic claude-sonnet-5-5 "$4"' _ "$MWLIB" "$LIB" "$T/stubs-real.sh" "$T/rout" 2>"$T/a7r.err" ); rc=$?
[ "$rc" = 0 ] && jq -e '.verdict=="live" and .served=="claude-sonnet-5-5" and .cost_usd==0.0123' <<<"$got" >/dev/null 2>&1 \
  && ok || bad "A7r real agent-call rc=$rc [$got] err: $(tail -5 "$T/a7r.err")"
grep -q -- 'claude-sonnet-5-5' "$T/claude-argv" 2>/dev/null && ok || bad "A7r the CLI never saw the model id: $(cat "$T/claude-argv" 2>/dev/null)"

# --- A8 -----------------------------------------------------------------------
CV=$(cat "$FX/cli-versions.json")
got=$(mws mw_cli_lag 2.1.284 "$CV")
[ "$got" = 'CLI behind on: project-3 (2.1.280)' ] && ok || bad "A8 lag [$got]"
got=$(mws mw_cli_lag 2.1.300 "$CV")
[ "$got" = $'CLI behind on: project-4 (2.1.290)\nCLI behind on: hub (2.1.284)\nCLI behind on: project-3 (2.1.280)' ] && ok || bad "A8 all behind, sorted [$got]"
got=$(mws mw_cli_lag 2.1.200 "$CV")
[ "$got" = 'CLI versions: every box at 2.1.200 or newer' ] && ok || bad "A8 current [$got]"
for in_ in 'garbage' '{"cli_versions":{}}' '' \
    '{"cli_versions":[{"box":"a","cli":"claude","version_after":"2.1.1","at":"x"},5]}' \
    '{"cli_versions":[5,{"box":"a","cli":"claude","version_after":"2.1.1","at":"x"}]}'; do
  got=$(mws mw_cli_lag 2.1.284 "$in_")
  [ "$got" = 'CLI versions: unreadable' ] && ok || bad "A8 [$in_] -> [$got]"
done
got=$(mws mw_cli_lag 2.1.284 '{"cli_versions":[{"box":"project-3","cli":"codex","version_after":"0.1","at":"x"}]}')
[ "$got" = 'CLI versions: no rows' ] && ok || bad "A8 no claude rows [$got]"
got=$(mws mw_cli_lag '' "$CV")
[ "$got" = 'CLI versions: unknown (probe CLI version not read)' ] && ok || bad "A8 no probed version [$got]"

# --- M1-M7 --------------------------------------------------------------------
: > "$STUBS"
ROW=$(jq -nc '{vendor:"anthropic", model_id:"claude-sonnet-5-5", slug:"anthropic/claude-sonnet-5.5", source:"anthropic",
               released_at:"2026-09-28", prompt:0.000004, completion:0.00002, cache_read:4e-7, cache_write:0.000005}')
MATCH=$(mws mw_match_routes anthropic claude-sonnet-5-5 "$ROUTES")
SUG=$(jq -nc --argjson r "$MATCH" --slurpfile p "$FX/prices.json" '{routes:$r, prices:{"claude-sonnet-5":$p[0]["claude-sonnet-5"]}}')
LIVE=$(v 0 "$FX/envelope-live.json" claude-sonnet-5-5)
FALLBACK=$(v 0 "$FX/envelope-fallback.json" claude-sonnet-5-5)
LAG='CLI behind on: project-3 (2.1.280)'
mkdir -p "$T/mh/bin"
printf '#!/bin/bash\nexit 0\n' > "$T/mh/bin/model-watch-approve.sh"; chmod +x "$T/mh/bin/model-watch-approve.sh"
msg() { HARNESS="$T/mh" mws mw_message "$@"; }

out=$(msg "$ROW" "$SUG" '+$2.23/day' "$LIVE" "$LAG"); rc=$?
mapfile -t L <<<"$out"
[ "$rc" = 0 ] && ok || bad "M1 rc=$rc"
[ "${L[0]:-}" = 'New model: anthropic/claude-sonnet-5.5 (claude-sonnet-5-5)' ] && ok || bad "M1 line 1 [${L[0]:-}]"
[ "${L[1]:-}" = 'Released 2026-09-28. Source: Anthropic Models API' ] && ok || bad "M1 line 2 [${L[1]:-}]"
[ "${L[2]:-}" = 'List price per 1M in/out: $4.00 / $20.00' ] && ok || bad "M1 line 3 [${L[2]:-}]"
[ "${L[3]:-}" = 'vs claude-sonnet-5: $3.00 / $15.00' ] && ok || bad "M1 line 4 [${L[3]:-}]"
[ "${L[4]:-}" = 'Routes: hub triage#0, project-3 build#1' ] && ok || bad "M1 line 5 [${L[4]:-}]"
[ "${L[5]:-}" = 'Cost delta: +$2.23/day' ] && ok || bad "M1 line 6 [${L[5]:-}]"
[ "${L[6]:-}" = 'Probe: live (served by claude-sonnet-5-5, $0.0123)' ] && ok || bad "M1 line 7 [${L[6]:-}]"
[ "${L[7]:-}" = "$LAG" ] && ok || bad "M1 line 8 [${L[7]:-}]"
[ "${L[8]:-}" = "Approve: $T/mh/bin/model-watch-approve.sh anthropic claude-sonnet-5-5" ] && ok || bad "M1 approve line [${L[8]:-}]"
[ "${#L[@]}" = 9 ] && ok || bad "M1 line count ${#L[@]}, want 9"
# M7: no em dash, no markdown emphasis.
[ "$(grep -c '—' <<<"$out")" = 0 ] && ok || bad "M7 em dash in the message"
! grep -qE '\*\*|__|^#' <<<"$out" && ok || bad "M7 markdown in the message"
# M2: the approve script absent -> no approve line.
out=$(HARNESS="$T/nowhere" mws mw_message "$ROW" "$SUG" '+$2.23/day' "$LIVE" "$LAG")
! grep -q model-watch-approve <<<"$out" && ok || bad "M2 approve line without the script"
out=$(mws mw_message "$ROW" "$SUG" '+$2.23/day' "$LIVE" "$LAG")
! grep -q model-watch-approve <<<"$out" && ok || bad "M2 approve line with no root"
# A4: a silent fallback never offers approve.
out=$(msg "$ROW" "$SUG" '+$2.23/day' "$FALLBACK" "$LAG")
grep -q 'NOT live (silent fallback' <<<"$out" && ok || bad "A4 message probe line: $out"
! grep -q model-watch-approve <<<"$out" && ok || bad "A4 approve offered on a fallback"
# M3: failed (empty modelUsage) and not-run (rc 74) never offer approve.
for p in "$(v 0 "$FX/envelope-empty.json" claude-sonnet-5-5)" "$(v 74 "$FX/envelope-live.json" claude-sonnet-5-5)"; do
  out=$(msg "$ROW" "$SUG" '+$2.23/day' "$p" "$LAG")
  ! grep -q model-watch-approve <<<"$out" && ok || bad "M3 approve offered on [$p]"
done
# M4: live with no routes.
out=$(msg "$ROW" '{"routes":[],"prices":{}}' 'no spend on x in 7 days' "$LIVE" "$LAG")
grep -qx 'Routes: none match' <<<"$out" && ok || bad "M4 routes line: $out"
! grep -q model-watch-approve <<<"$out" && ok || bad "M4 approve offered with no route"
out=$(msg "$ROW" '{"prices":{}}' 'x' "$LIVE" "$LAG")
grep -qx 'Routes: unreadable' <<<"$out" && ok || bad "M4 routes unreadable: $out"
! grep -q model-watch-approve <<<"$out" && ok || bad "M4 approve offered on unreadable routes"
out=$(msg "$ROW" '{"routes":[{"project":null,"role":"triage","position":0,"runner":"claude","from":"claude-opus-5"}],"prices":{}}' 'x' "$LIVE" "$LAG")
grep -qx 'vs claude-opus-5: no list price' <<<"$out" && ok || bad "M4 no list price for from: $out"
# M5: probe result lost / not run.
out=$(msg "$(jq -c '.probe_attempted_at="2026-09-29T06:00:00Z"' <<<"$ROW")" "$SUG" 'x' '' "$LAG")
grep -qx 'Probe: probe result lost (attempted 2026-09-29T06:00:00Z)' <<<"$out" && ok || bad "M5 lost: $out"
! grep -q model-watch-approve <<<"$out" && ok || bad "M5 approve offered on a lost probe"
out=$(msg "$ROW" "$SUG" 'x' '' "$LAG")
grep -qx 'Probe: not run' <<<"$out" && ok || bad "M5 not run: $out"
# M6: source links.
ORROW=$(jq -c '.source="openrouter" | .released_at=null | .prompt=null' <<<"$ROW")
out=$(OR_BASE=https://example.test msg "$ORROW" "$SUG" 'x' "$LIVE" "$LAG")
grep -qx 'Released date unknown. Source: https://example.test/anthropic/claude-sonnet-5.5' <<<"$out" && ok || bad "M6 openrouter link: $out"
grep -qx 'List price per 1M in/out: n/a / $20.00' <<<"$out" && ok || bad "M6 null price is n/a: $out"
out=$(OR_BASE='' msg "$ORROW" "$SUG" 'x' "$LIVE" "$LAG")
grep -q 'Source: OpenRouter (no base URL configured)' <<<"$out" && ok || bad "M6 openrouter without OR_BASE: $out"
out=$(OR_BASE=https://example.test msg "$ROW" "$SUG" 'x' "$LIVE" "$LAG")
! grep -q http <<<"$out" && ok || bad "M6 invented a URL for an anthropic row: $out"
out=$(msg 'not json' "$SUG" 'x' "$LIVE" "$LAG"); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "M row unparseable rc=$rc out=[$out]"

echo "model-watch-suggest: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
