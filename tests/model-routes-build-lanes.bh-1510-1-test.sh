#!/bin/bash
# tests/model-routes-build-lanes.bh-1510-1-test.sh — the build lanes read their
# models from model_routes (BH-1510.1), never from a literal.
#
# WHY. the operator, 2026-09-22: "We shouldn't have hardcodes anywhere; all of that
# should be DB values." #1510.0 built the table and bin/lib/model-route.sh;
# this slice points the build lanes at it and deletes their literal defaults:
# bin/agent-call.sh's own ladders (the claude lane's failover rungs, the codex /
# grok / fireworks defaults, the OpenRouter and Fireworks floors), run-build and
# its rb/gates copy, the fly builder, blocked-resolver, review-prs/-rescue/
# -autopilot, postmerge-qa, cost-readout and bin/lib/review-model.sh.
#
# WHAT IS PROVEN, every lane driven through the REAL resolver against a stubbed
# worker (tests/lib/model-route-stub.sh):
#   A. agent-call's ladders ARE the table: with the table answering #1507's
#      values, every stage runs exactly the ladder main's literals ran after
#      #1523; change a row and the lane follows it; the CLI floor advances along
#      the RESOLVED ladder with one alert; only a real API 400 is a floor; worker
#      down -> the box cache; both empty -> the argv model alone, one ALERTS
#      line, never a guessed rung; a non-claude rung with no route is not run
#      (rc 75, nothing billed).
#   B. every lane's model resolves from the table to main's post-#1523 value,
#      honours an env override and a project override, survives the worker
#      going away through the box cache, and FAILS CLOSED with no route.
#   C. the literal defaults are gone from every file this slice owns.
#
# Run from anywhere: tests/model-routes-build-lanes.bh-1510-1-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
O55=claude-opus-5-5; O5=claude-opus-5; FB=claude-fable-5-1; SN=claude-sonnet-5

mrs_install "$T/fakebin"
reset_routes() { rm -rf "$T/routes"; mrs_table_1523 "$T/routes"; }
reset_routes

# =============================================================================
# A. bin/agent-call.sh — the ladder is the table
# =============================================================================
H="$T/h"
mkdir -p "$H/bin/lib" "$H/flags" "$H/locks" "$H/logs" "$H/state" "$T/.codex" "$T/.grok/bin"
echo '{}' > "$T/.codex/auth.json"
STALE_JSON='{"type":"result","subtype":"success","is_error":true,"api_error_status":400,"result":"API Error: 400 Claude Code 2.1.278 does not support this model; version 2.1.280 or newer is required. Run '"'"'claude update'"'"', or pick a different model with --model.","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0}}'
# The same sentence in an is_error envelope that is NOT an API 400: a session
# that ran, failed, and quoted the refusal in its own result (#1523 review F5).
QUOTE500_JSON='{"type":"result","is_error":true,"api_error_status":500,"result":"The grep I added matches: does not support this model; version 2.1.280 or newer is required","usage":{"input_tokens":5,"output_tokens":1}}'
QUOTENONE_JSON='{"type":"result","is_error":true,"result":"I quoted: does not support this model; version 2.1.280 or newer is required","usage":{"input_tokens":5,"output_tokens":1}}'
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
case " $* " in
  *" --help "*) printf -- '  --resume <sessionId>\n  --session-id <uuid>\n'; exit 0 ;;
  *" --version "*) echo "2.1.277 (Claude Code)"; exit 0 ;;
esac
m=""; prev=""
for a in "$@"; do [ "$prev" = --model ] && m="$a"; prev="$a"; done
echo "$m" >> "$ORDER_SINK"
v="MODE_$(printf '%s' "$m" | tr -c 'A-Za-z0-9\n' '_')"
case "${!v:-ok}" in
  ok)        printf '{"result":"ok","usage":{"input_tokens":5,"output_tokens":1},"total_cost_usd":0.01}\n'; exit 0 ;;
  stale)     printf '%s\n' "$STALE_JSON"; exit 1 ;;
  quote500)  printf '%s\n' "$QUOTE500_JSON"; exit 1 ;;
  quotenone) printf '%s\n' "$QUOTENONE_JSON"; exit 1 ;;
  *)         printf '{"result":"I could not do it","is_error":true,"usage":{"input_tokens":5,"output_tokens":1}}\n'; exit 1 ;;
esac
EOF
# codex and grok record the model they were handed (-m), and succeed.
cat > "$T/fakebin/codex" <<'EOF'
#!/bin/bash
m=""; prev=""; out=""
for a in "$@"; do [ "$prev" = -m ] && m="$a"; [ "$prev" = --output-last-message ] && out="$a"; prev="$a"; done
echo "codex:$m" >> "$ORDER_SINK"
[ -n "$out" ] && echo ok > "$out"
exit 0
EOF
cat > "$T/.grok/bin/grok" <<'EOF'
#!/bin/bash
m=""; prev=""
for a in "$@"; do [ "$prev" = -m ] && m="$a"; prev="$a"; done
echo "grok:$m" >> "$ORDER_SINK"
echo ok
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*|-k) shift ;; esac
shift
exec "$@"
EOF
printf '#!/bin/bash\necho subscription\n' > "$H/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\necho "test rules"\n' > "$H/bin/sync-agent-rules.sh"
cp "$DIR/bin/account-pick.sh" "$H/bin/account-pick.sh"
chmod +x "$T/fakebin/"* "$T/.grok/bin/grok" "$H/bin/"*.sh

# call <stage> <model> [ENV=VAL...] — one real agent-call run; prints its rc.
call() {
  local stage="$1" model="$2"; shift 2
  : > "$T/order"; : > "$H/logs/ALERTS.log"; : > "$H/logs/failovers.log"; : > "$T/sink"
  rm -f "$H/flags/alerted-"* 2>/dev/null
  [ "${KEEP_CACHE:-0}" = 1 ] || scratch_rm "$H/state/model-routes"
  ( export ORDER_SINK="$T/order" STALE_JSON QUOTE500_JSON QUOTENONE_JSON PATH="$T/fakebin:$PATH" HARNESS="$H" HOME="$T" \
           HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid MRS_ROUTES="$T/routes" MRS_SINK="$T/sink" \
           LADDER_BACKOFF_SECS=0 LADDER_SAME_RETRIES=0 LADDER_TIER2_GROK=0 \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json"
    env -u ACCOUNT_ROUTING -u OPENROUTER_API_KEY -u FIREWORKS_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY \
      -u CODEX_MODEL -u CODEX_DEFAULT_MODEL -u GROK_MODEL -u FIREWORKS_MODEL -u AGENT_CALL_ROLE \
      "RUNNER_$(printf '%s' "$stage" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9\n' '_')=claude" \
      "$@" bash "$DIR/bin/agent-call.sh" "$stage" testproj "$model" 600 "$T/out.txt" "hello" >/dev/null 2>&1 )
  echo $?
}
order() { paste -sd, "$T/order"; }
floor_alerts() { grep -c 'CLI FLOOR' "$H/logs/ALERTS.log" 2>/dev/null; }
route_alerts() { grep -c "no model route for role '$1'" "$H/logs/ALERTS.log" 2>/dev/null; }

# A1. A call that succeeds on the model it was given never reads a model
# ladder. Since BH-1765 every call reads its stage.<stage> route once, for the
# runner (and the env-override alert), so that read is pinned to exactly one.
RC=$(call execute "$O55")
{ [ "$(order)" = "$O55" ] && [ "$RC" = 0 ] && [ "$(grep -vc '/api/model-routes/stage\.' "$T/sink")" = 0 ] \
  && [ "$(grep -c '/api/model-routes/stage\.execute' "$T/sink")" = 1 ]; } \
  && ok || bad "A1 a healthy call must be one call, no ladder lookup and one stage-route read, ran: $(order) rc=$RC lookups: $(paste -sd' ' "$T/sink")"

# A2. EVERY STAGE RUNS MAIN'S LADDER (post-#1523), read from the table. An
# ordinary failure crosses a family (Fable <-> Opus); an older release of the
# same family (Opus 5.5 -> Opus 5) is reached only on a CLI refusal.
lane() { # lane <label> <stage> <model> <expected-order> [ENV=VAL...]
  local label="$1" st="$2" m="$3" want="$4"; shift 4
  local rc; rc=$(call "$st" "$m" "$@")
  [ "$(order)" = "$want" ] && ok || bad "A2 $label ran '$(order)' (rc=$rc), main's ladder is '$want'"
}
F55=MODE_claude_opus_5_5=fail; FFB=MODE_claude_fable_5_1=fail
lane "execute, 5.5 fails"          execute "$O55" "$O55"                "$F55"
lane "execute, 5.5 refused"        execute "$O55" "$O55,$O5"            MODE_claude_opus_5_5=stale
lane "fix, 5.5 fails"              fix     "$O55" "$O55"                "$F55"
lane "fix, 5.5 refused"            fix     "$O55" "$O55,$O5"            MODE_claude_opus_5_5=stale
lane "qa, 5.5 fails"               qa      "$O55" "$O55"                "$F55"
lane "qa, 5.5 refused"             qa      "$O55" "$O55,$O5"            MODE_claude_opus_5_5=stale
lane "review, 5.5 fails"           review  "$O55" "$O55,$FB"            "$F55"
lane "review, 5.5 refused"         review  "$O55" "$O55,$FB"            MODE_claude_opus_5_5=stale
lane "plan (one-rung role), fable fails, 5.5 fails" plan "$FB" "$FB,$O55" "$FFB" "$F55"
lane "plan, fable fails, 5.5 refused"   plan "$FB" "$FB,$O55,$O5" "$FFB" MODE_claude_opus_5_5=stale
lane "rescue.review, 5.5 fails"    review  "$O55" "$O55,$FB"            "$F55" AGENT_CALL_ROLE=rescue.review
lane "postmerge.qa, 5.5 refused"   prodqa  "$O55" "$O55,$O5"            MODE_claude_opus_5_5=stale AGENT_CALL_ROLE=postmerge.qa
lane "blocked-resolver fix, 5.5 fails" execute "$O55" "$O55"            "$F55" AGENT_CALL_ROLE=build.execute.fallback
lane "an unconverted stage, fable fails, 5.5 refused" triage "$FB" "$FB,$O55,$O5" "$FFB" MODE_claude_opus_5_5=stale
lane "an env-pinned Fable review walks claude.ladder" review "$FB" "$FB,$O55" "$FFB" "$F55"

# A3. CHANGE THE ROW, THE LANE FOLLOWS — hub, then one project's override.
mrs_route "$T/routes" build.review "$O55:claude" "$SN:claude"
lane "review with the hub row moved to sonnet" review "$O55" "$O55,$SN" "$F55"
grep -q "retrying as $SN" "$H/logs/failovers.log" && ok || bad "A3 failovers.log does not name the table's rung: $(cat "$H/logs/failovers.log")"
mrs_route "$T/routes" build.execute testproj "$O55:claude" "$SN:claude"
lane "execute with a project override" execute "$O55" "$O55,$SN" "$F55"
reset_routes

# A4. THE CLI FLOOR WALKS THE RESOLVED LADDER, with one alert naming the rung.
mrs_route "$T/routes" build.execute "$O55:claude" "$SN:claude"
RC=$(call execute "$O55" MODE_claude_opus_5_5=stale)
{ [ "$(order)" = "$O55,$SN" ] && [ "$RC" = 0 ] && [ "$(floor_alerts)" = 1 ]; } \
  && ok || bad "A4 a refused rung must hand over to the table's next rung with one alert, ran: $(order) rc=$RC alerts=$(floor_alerts)"
grep 'CLI FLOOR' "$H/logs/ALERTS.log" | grep -q "does not support $O55 — failing over to $SN" \
  && ok || bad "A4 the alert must name the table's next rung: $(grep 'CLI FLOOR' "$H/logs/ALERTS.log")"
reset_routes

# A5. ONLY A REAL API 400 IS A FLOOR (#1523 review, F5): the refusal sentence
# in an is_error envelope with another status, or none, is the session's own
# text — an ordinary failure, no Opus 5 run, no alert.
for mode in quote500 quotenone; do
  RC=$(call execute "$O55" MODE_claude_opus_5_5=$mode)
  { [ "$(order)" = "$O55" ] && [ "$(floor_alerts)" = 0 ]; } \
    && ok || bad "A5 ($mode) a quoted refusal without api_error_status 400 must not read as a CLI floor, ran: $(order) alerts=$(floor_alerts)"
done
RC=$(call execute "$O55" MODE_claude_opus_5_5=stale)
[ "$(order)" = "$O55,$O5" ] && ok || bad "A5 the real 400 refusal must still floor, ran: $(order)"

# A6. WORKER DOWN -> THE BOX CACHE. The first failure warms it; with the
# worker gone the same ladder comes back from state/model-routes/.
RC=$(call review "$O55" "$F55")
RC=$(KEEP_CACHE=1 call review "$O55" "$F55" MRS_MODE=down)
{ [ "$(order)" = "$O55,$FB" ] && [ "$RC" = 0 ]; } \
  && ok || bad "A6 worker down must be served by the cached ladder, ran: $(order) rc=$RC"
grep -q "served from cache" "$H/logs/model-route.log" 2>/dev/null \
  && ok || bad "A6 no 'served from cache' line in logs/model-route.log"

# A7. WORKER DOWN, NO CACHE -> NO GUESSED RUNG. The argv model runs (the caller
# resolved it); nothing below it is invented; the resolver alerts once per role.
RC=$(call review "$O55" "$F55" MRS_MODE=down)
{ [ "$(order)" = "$O55" ] && [ "$RC" != 0 ]; } \
  && ok || bad "A7 with no route anywhere only the argv model may run, ran: $(order) rc=$RC"
{ [ "$(route_alerts build.review)" = 1 ] && [ "$(route_alerts claude.ladder)" = 1 ]; } \
  && ok || bad "A7 expected exactly one ALERTS line per role asked: $(cat "$H/logs/ALERTS.log")"

# A8. THE CODEX RUNG'S MODEL IS codex.default — and with no route it is not run.
RC=$(call eval "$O55" RUNNER_EVAL=codex)
{ [ "$(order)" = "codex:gpt-6-astra" ] && [ "$RC" = 0 ]; } \
  && ok || bad "A8 codex must run the codex.default row, ran: $(order) rc=$RC"
mrs_route "$T/routes" codex.default gpt-5.6-sol:codex
RC=$(call eval "$O55" RUNNER_EVAL=codex)
[ "$(order)" = "codex:gpt-5.6-sol" ] && ok || bad "A8 codex must follow the row when it changes, ran: $(order)"
RC=$(call eval "$O55" RUNNER_EVAL=codex CODEX_MODEL=gpt-5.2-codex)
[ "$(order)" = "codex:gpt-5.2-codex" ] && ok || bad "A8 CODEX_MODEL must still override the row, ran: $(order)"
rm -f "$T/routes/codex.default.json"
# AGENT_CALL_RUNNERS=codex: no claude fallback behind it, so the refusal is the answer.
RC=$(call eval "$O55" RUNNER_EVAL=codex AGENT_CALL_RUNNERS=codex)
{ [ ! -s "$T/order" ] && [ "$RC" = 75 ] && head -1 "$T/out.txt" | grep -q '^AGENT_CALL_NO_MODEL_ROUTE codex.default' \
  && [ "$(route_alerts codex.default)" = 1 ]; } \
  && ok || bad "A8 a codex rung with no route must not run (rc 75, marker, one alert), ran: '$(order)' rc=$RC out=$(head -c 80 "$T/out.txt") alerts=$(cat "$H/logs/ALERTS.log")"
reset_routes

# A9. THE GROK RUNG'S MODEL IS grok.default.
RC=$(call eval "$O55" RUNNER_EVAL=grok)
[ "$(order)" = "grok:grok-4.6" ] && ok || bad "A9 grok must run the grok.default row, ran: $(order) rc=$RC"
mrs_route "$T/routes" grok.default grok-4.6-fast:grok
RC=$(call eval "$O55" RUNNER_EVAL=grok)
[ "$(order)" = "grok:grok-4.6-fast" ] && ok || bad "A9 grok must follow the row, ran: $(order)"
reset_routes

# =============================================================================
# B. every lane's model comes from the table
# =============================================================================
# A harness with the resolver and its transport where a lane expects them.
LH="$T/lh"
mkdir -p "$LH/bin/lib/jobs" "$LH/logs" "$LH/state" "$LH/flags" "$LH/env"
cp "$DIR/bin/jobs-client.sh" "$LH/bin/"; cp "$DIR"/bin/lib/jobs/*.sh "$LH/bin/lib/jobs/"
cp "$DIR/bin/lib/model-route.sh" "$DIR/bin/lib/review-model.sh" "$DIR/bin/lib/env-path.sh" "$LH/bin/lib/"
lenv() { # lenv <cmd...> — run a snippet as a lane would, against the stub worker
  env -u EXECUTE_MODEL -u REVIEW_MODEL -u REVIEW_MODEL_T0 -u FIX_MODEL -u QA_MODEL -u PLAN_MODEL \
      -u POSTMERGE_QA_MODEL PATH="$T/fakebin:$PATH" HARNESS="$LH" HARNESS_SECRET=test-secret \
      JOBS_URL=https://jobs.invalid MRS_ROUTES="$T/routes" JOBS_RETRIES=0 "$@"
}

# --- B1. run-build (the pipeline as ONE text, like every reader suite) -------
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
sed -n '/^# >>> model tiering$/,/^# <<< model tiering$/p' "$RB_ALL" > "$T/tiering.sh"
[ -s "$T/tiering.sh" ] && ok || bad "B1 no '>>> model tiering' block in bin/run-build.sh"
tiering() { # tiering [ENV=VAL...] -> 'PLAN EXECUTE REVIEW T0 FIX QA' on stdout; rc = the block's exit
  mkdir -p "$T/b"; rm -f "$T/b/RESULT"
  lenv "$@" bash -c '
    set -uo pipefail
    PROJECT=testproj KEY=K-1 BUILD="$1" ALERTS="$HARNESS/logs/ALERTS.log"
    STAMP() { date -u "+%Y-%m-%d %H:%M:%SZ"; }
    RESULT() { echo "$1" > "$BUILD/RESULT"; }
    . "$2"
    echo "$PLAN_MODEL $EXECUTE_MODEL $REVIEW_MODEL $REVIEW_MODEL_T0 $FIX_MODEL $QA_MODEL"' _ "$T/b" "$T/tiering.sh"
}
scratch_rm "$LH/state/model-routes"
OUT=$(tiering); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "$FB $O55 $O55 $O55 $O55 $O55" ] \
  && ok || bad "B1 run-build must resolve main's post-#1523 models from the table, got '$OUT' rc=$RC"
OUT=$(tiering EXECUTE_MODEL=pinned-x REVIEW_MODEL=pinned-y)
[ "$OUT" = "$FB pinned-x pinned-y pinned-y pinned-x $O55" ] \
  && ok || bad "B1 an env EXECUTE_MODEL/REVIEW_MODEL must still win, and still carry into FIX/T0: '$OUT'"
mrs_route "$T/routes" build.plan testproj "$SN:claude"
OUT=$(tiering)
[ "${OUT%% *}" = "$SN" ] && ok || bad "B1 a project's build.plan override must reach PLAN_MODEL: '$OUT'"
reset_routes
OUT=$(tiering)   # the last good answer, per (role, project), is what the cache keeps
OUT=$(tiering MRS_MODE=down)
[ "$OUT" = "$FB $O55 $O55 $O55 $O55 $O55" ] \
  && ok || bad "B1 worker down must be served from the box cache the last call warmed: '$OUT'"
rm -f "$T/routes/build.qa.json"; : > "$LH/logs/ALERTS.log"; rm -f "$LH/flags/alerted-"*
OUT=$(tiering); RC=$?
{ [ "$RC" = 3 ] && grep -q '^BUILD_DEFERRED no model route for build.qa' "$T/b/RESULT" \
  && [ "$(grep -c "no model route for role 'build.qa'" "$LH/logs/ALERTS.log")" = 1 ] && [ -z "$OUT" ]; } \
  && ok || bad "B1 no build.qa row must defer the build (exit 3, one alert), never guess: rc=$RC result=$(cat "$T/b/RESULT" 2>/dev/null) out='$OUT'"
reset_routes
scratch_rm "$LH/state/model-routes"
OUT=$(tiering MRS_MODE=down); RC=$?
[ "$RC" = 3 ] && ok || bad "B1 worker down with no cache must defer, not guess: rc=$RC out='$OUT'"

# --- B2. rb/gates.sh carries the same block, verbatim ------------------------
sed -n '/^# >>> model tiering$/,/^# <<< model tiering$/p' "$DIR/bin/lib/rb/gates.sh" > "$T/tiering-gates.sh"
cmp -s "$T/tiering.sh" "$T/tiering-gates.sh" && ok || bad "B2 bin/lib/rb/gates.sh's model tiering block is not the driver's, verbatim"

# --- B3. review_model: review-prs, review-autopilot, the conductor
scratch_rm "$LH/state/model-routes"
rm_ask() { lenv "$@" bash -c '. "$HARNESS/bin/lib/review-model.sh"; review_model "$HARNESS" "$1"; echo "rc=$?"' _ "${RM_PROJ:-}"; }
[ "$(rm_ask | paste -sd' ')" = "$O55 rc=0" ] && ok || bad "B3 review_model must answer build.review from the table: $(rm_ask)"
mrs_route "$T/routes" build.review testproj "$SN:claude"
[ "$(RM_PROJ=testproj rm_ask | paste -sd' ')" = "$SN rc=0" ] && ok || bad "B3 review_model must honour a project override: $(RM_PROJ=testproj rm_ask)"
[ "$(rm_ask REVIEW_MODEL=pinned | paste -sd' ')" = "pinned rc=0" ] && ok || bad "B3 REVIEW_MODEL must still win"
rm -f "$T/routes/build.review.json" "$T/routes/build.review@testproj.json"
[ "$(rm_ask | paste -sd' ')" = "rc=75" ] && ok || bad "B3 review_model with no route must answer nothing, rc 75: $(rm_ask)"
reset_routes

# --- B4. blocked-resolver: per project, per call ----------------------------
sed -n '/^br_model() {$/,/^}$/p' "$DIR/bin/blocked-resolver.sh" > "$T/br_model.sh"
br_ask() { lenv bash -c '. "$HARNESS/bin/lib/model-route.sh"; . "$1"; m=$(br_model "$2" "$3" testproj); echo "$m rc=$?"' _ "$T/br_model.sh" "$@"; }
[ "$(br_ask "" build.execute.fallback)" = "$O55 rc=0" ] && ok || bad "B4 fix-round model: $(br_ask "" build.execute.fallback)"
[ "$(br_ask "" build.review)" = "$O55 rc=0" ] && ok || bad "B4 adjudication model: $(br_ask "" build.review)"
[ "$(br_ask pinned build.review)" = "pinned rc=0" ] && ok || bad "B4 an env model must win"
[ "$(br_ask "" no.such.role)" = " rc=75" ] && ok || bad "B4 no route must be rc 75 and no model: $(br_ask "" no.such.role)"
grep -qE 'AGENT_CALL_ROLE=build\.execute\.fallback .*agent-call\.sh" execute "\$p" "\$fix_model"' "$DIR/bin/blocked-resolver.sh" \
  && ok || bad "B4 the fix round must run \$fix_model under its own role"
grep -qE 'agent-call\.sh" review "\$p" "\$adj_model"' "$DIR/bin/blocked-resolver.sh" \
  && ok || bad "B4 the adjudication must run \$adj_model"

# --- B5. postmerge-qa --------------------------------------------------------
sed -n '/^QA_MODEL="\${POSTMERGE_QA_MODEL:-\${QA_MODEL:-}}"$/,/^fi$/p' "$DIR/bin/postmerge-qa.sh" > "$T/pmqa.sh"
pm_ask() { lenv "$@" bash -c 'H="$HARNESS" P=testproj; say() { :; }; . "$1"; echo "$QA_MODEL"' _ "$T/pmqa.sh"; echo "rc=$?"; }
[ "$(pm_ask | paste -sd' ')" = "$O55 rc=0" ] && ok || bad "B5 postmerge-qa must resolve postmerge.qa: $(pm_ask | paste -sd' ')"
[ "$(pm_ask POSTMERGE_QA_MODEL=pinned | paste -sd' ')" = "pinned rc=0" ] && ok || bad "B5 POSTMERGE_QA_MODEL must still win"
rm -f "$T/routes/postmerge.qa.json"
[ "$(pm_ask | paste -sd' ')" = "rc=75" ] && ok || bad "B5 no route must exit 75 with nothing driven: $(pm_ask | paste -sd' ')"
reset_routes
grep -qE 'AGENT_CALL_ROLE=postmerge\.qa "\$SELF/agent-call\.sh" prodqa "\$P" "\$QA_MODEL"' "$DIR/bin/postmerge-qa.sh" \
  && ok || bad "B5 the QA agent must run under the postmerge.qa role"

# --- B6. review-rescue: the model is asked before an attempt is spent --------
sed -n '/^  RMODEL="\${REVIEW_MODEL:-}"$/,/^  fi$/p' "$DIR/bin/review-rescue.sh" > "$T/rescue.sh"
rs_ask() { lenv "$@" bash -c '. "$HARNESS/bin/lib/model-route.sh"; f() { local RMODEL BN=x PROJECT=testproj; say() { :; }; . "$1"; echo "$RMODEL"; }; f "$1"' _ "$T/rescue.sh"; }
[ "$(rs_ask)" = "$O55" ] && ok || bad "B6 review-rescue must resolve rescue.review: '$(rs_ask)'"
rm -f "$T/routes/rescue.review.json"
[ -z "$(rs_ask)" ] && ok || bad "B6 no rescue.review route must stop the rescue before the review"
reset_routes
awk '/RMODEL="\$\{REVIEW_MODEL:-\}"/{m=NR} /echo "\$ATT" > "\$CAND\/.rescue-attempts"/{a=NR} END{exit !(m && a && m < a)}' "$DIR/bin/review-rescue.sh" \
  && ok || bad "B6 the model must be resolved BEFORE an attempt is counted"
grep -qE 'AGENT_CALL_ROLE=rescue\.review timeout .*agent-call\.sh" review "\$PROJECT" "\$RMODEL"' "$DIR/bin/review-rescue.sh" \
  && ok || bad "B6 the rescue review must run \$RMODEL under the rescue.review role"

# --- B7. review-prs, review-autopilot: review_model, guarded; cost-readout: none
grep -qE '^command -v review_model .* && RP_MODEL=\$\(review_model "\$HARNESS" "\$PROJECT"\)$' "$DIR/bin/review-prs.sh" \
  && grep -qE 'agent-call\.sh" review "\$PROJECT" "\$RP_MODEL"' "$DIR/bin/review-prs.sh" \
  && awk '/if \[ -z "\$RP_MODEL" \]; then/{g=NR} /IF_SHA=\$\(jq/{m=NR} END{exit !(g && m && g < m)}' "$DIR/bin/review-prs.sh" \
  && ok || bad "B7 review-prs must review on review_model's per-project answer, checked before the in-flight marker"
grep -qE 'RA_MODEL=\$\(review_model "\$H" "\$P"\)' "$DIR/bin/review-autopilot.sh" \
  && grep -qE 'agent-call\.sh" review "\$P" "\$RA_MODEL"' "$DIR/bin/review-autopilot.sh" \
  && ok || bad "B7 review-autopilot must review on review_model's per-project answer"
# BH-2550: cost-readout renders summary.json with no model at all, so it makes
# no review_model lookup and no agent-call (guarded: the file must exist).
[ -f "$DIR/bin/cost-readout.sh" ] \
  && ! grep -qE 'agent-call|review_model' "$DIR/bin/cost-readout.sh" \
  && ok || bad "B7 cost-readout must make no model call (BH-2550)"

# --- B8. the fly builder: it warms its own cache, which then serves the build -
sed -n '/^model_routes_warm() {$/,/^}$/p' "$DIR/fly/builder-runner.sh" > "$T/warm.sh"
FH="$T/fh"; mkdir -p "$FH/bin/lib/jobs" "$FH/logs"
cp "$DIR/bin/jobs-client.sh" "$FH/bin/"; cp "$DIR"/bin/lib/jobs/*.sh "$FH/bin/lib/jobs/"; cp "$DIR/bin/lib/model-route.sh" "$DIR/bin/lib/env-path.sh" "$FH/bin/lib/"
WLOG=$(lenv bash -c 'HARNESS="$1" PROJECT=testproj ENVDIR="$1/env"; log() { echo "$*"; }; . "$2"; model_routes_warm' _ "$FH" "$T/warm.sh")
case "$WLOG" in *"12 resolved") ok ;; *) bad "B8 the builder must warm every build role, logged: $WLOG" ;; esac
[ "$(cut -f2 "$FH/state/model-routes/build.execute@testproj.tsv" 2>/dev/null | paste -sd,)" = "$O55,$O5" ] \
  && ok || bad "B8 the warmed cache must hold the table's build.execute ladder"
# ...and with the worker gone, the build's own lookups are served from it.
cp "$DIR/bin/lib/review-model.sh" "$FH/bin/lib/"; mkdir -p "$FH/flags" "$FH/state"
OUT=$(env -u EXECUTE_MODEL -u REVIEW_MODEL -u QA_MODEL -u PLAN_MODEL PATH="$T/fakebin:$PATH" HARNESS="$FH" HARNESS_SECRET=test-secret \
      JOBS_URL=https://jobs.invalid MRS_MODE=down JOBS_RETRIES=0 bash -c '
    mkdir -p "$HARNESS/b"; PROJECT=testproj KEY=K BUILD="$HARNESS/b" ALERTS="$HARNESS/logs/ALERTS.log"
    STAMP() { date -u; }; RESULT() { echo "$1" > "$BUILD/RESULT"; }
    . "$1"; echo "$PLAN_MODEL $EXECUTE_MODEL $REVIEW_MODEL $REVIEW_MODEL_T0 $FIX_MODEL $QA_MODEL"' _ "$T/tiering.sh")
[ "$OUT" = "$FB $O55 $O55 $O55 $O55 $O55" ] && ok || bad "B8 a builder whose worker went away must build from its warmed cache: '$OUT'"
# BH-2559: SMOKE is a free credential probe now, so it resolves no model at all.
SMOKE_BLOCK=$(sed -n '/if \[ "\$key" = "SMOKE" \]; then/,/return 0/p' "$DIR/fly/builder-runner.sh")
if [ -z "$SMOKE_BLOCK" ]; then bad "B8 the SMOKE block was not found in fly/builder-runner.sh"
elif grep -q 'model_for' <<<"$SMOKE_BLOCK"; then bad "B8 the SMOKE probe must resolve no model (BH-2559)"
else ok; fi

# =============================================================================
# C. the literal defaults are gone from every file this slice owns
# =============================================================================
VOCAB=$(jq -r '(.per_token // {}) | keys[]' "$DIR/catalog/model-prices.json"; jq -r 'keys[]' "$DIR/catalog/model-slugs.json")
for f in bin/agent-call.sh bin/run-build.sh bin/lib/rb/gates.sh fly/builder-runner.sh bin/blocked-resolver.sh \
         bin/review-prs.sh bin/review-rescue.sh bin/review-autopilot.sh bin/postmerge-qa.sh bin/cost-readout.sh \
         bin/lib/review-model.sh bin/lib/model-route.sh; do
  hits=$(grep -nFf <(printf '%s\n' "$VOCAB" | sort -u) "$DIR/$f" | head -3)
  [ -z "$hits" ] && ok || bad "C $f still carries a model-id literal: $hits"
done

echo "model-routes-build-lanes.bh-1510-1: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
