#!/bin/bash
# tests/model-route-other-lanes.bh-1510-2-test.sh — BH-1510.2: every NON-build
# lane learns its model from model_routes (bin/lib/model-route.sh, through
# bin/lib/lane-model.sh), never from a literal of its own.
#
# HOW A LANE IS DRIVEN. Each converted lane carries its resolution between
# `# >>> model-route` and `# <<< model-route` markers. This file cuts that block
# out of the REAL script and runs it against a stubbed worker (a fake curl that
# answers GET /api/model-routes/<role>[?project=<p>] with a two-rung ladder
# whose model names encode the role and project), so what is asserted is the
# lane's own code, not a re-implementation of it. For every lane, three worlds:
#   up      the worker answers  -> each variable is the ROLE's model (and the
#           project's, where the lane is project-scoped);
#   cached  the worker is down, this box cached the last good answer -> the
#           same values, from the cache;
#   none    the worker is down and nothing is cached -> rc 75 and an ALERTS.log
#           line naming the role, never a guessed model. Two lanes answer a
#           human in real time (the orchestrator's Telegram turn and the box
#           chat pane) and must never go silent: for those "none" is rc 0 with
#           the model EMPTY, which sends the turn to their deterministic floor.
# Plus: lane_model's env override, the no-project-cache outage (fail closed), its options hygiene, triage_model's gate
# split, prompt-eval's model_for_gate, and a literal scan of every file here.
#
# Run from anywhere: tests/model-route-other-lanes.bh-1510-2-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin/lib/jobs" "$T/logs" "$T/state" "$T/flags" "$T/env" "$T/fakebin" "$T/build"
cp "$DIR/bin/jobs-client.sh" "$T/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/lib/model-route.sh" "$DIR/bin/lib/lane-model.sh" "$DIR/bin/lib/triage-shards-lib.sh" "$T/bin/lib/"
echo "HARNESS_SECRET=test-secret" > "$T/env/global.env"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"
[ -n "${REQ_SINK:-}" ] && printf '%s\n' "$URL" >> "$REQ_SINK"
[ "${CURL_MODE:-up}" = down ] && exit 7
[ "${CURL_MODE:-up}" = junk ] && { printf '{"ok":true}\n200\n'; exit 0; }
case "$URL" in
  */api/model-routes/*)
    rest="${URL##*/api/model-routes/}"; role="${rest%%\?*}"; proj=""
    case "$rest" in *\?project=*) proj="@${rest##*\?project=}" ;; esac
    if [ "${CURL_NOROUTE:-0}" = 1 ] && [ -n "$proj" ]; then
      # the worker's "no route" for this project: nothing at project OR hub scope
      printf '{"role":"%s","project":"%s","ladder":[],"source":"none"}\n200\n' "$role" "${proj#@}"
    elif [ "${CURL_GAPPED:-0}" = 1 ] && [ -n "$proj" ]; then
      # THE DEPLOYED WORKER'S shape for a project override with no rung 0
      # (core.js resolveModelLadder): the project scope is ignored, the HUB
      # ladder answers with source=hub, and the gapped rows ride beside it
      printf '{"role":"%s","ladder":[{"position":0,"model":"m-%s","runner":"r-%s"},{"position":1,"model":"m1-%s","runner":"claude"}],"source":"hub","gapped":{"rows":[{"position":1,"model":"m-override","runner":"claude"}]}}\n200\n' \
        "$role" "$role" "$role" "$role"
    elif [ "${CURL_RUNGS:-2}" = 1 ]; then
      printf '{"role":"%s","ladder":[{"position":0,"model":"m-%s%s","runner":"r-%s"}],"source":"%s"}\n200\n' \
        "$role" "$role" "$proj" "$role" "${CURL_SOURCE:-hub}"
    else
      printf '{"role":"%s","ladder":[{"position":0,"model":"m-%s%s","runner":"r-%s"},{"position":1,"model":"m1-%s%s","runner":"claude"}],"source":"%s"}\n200\n' \
        "$role" "$role" "$proj" "$role" "$role" "$proj" "${CURL_SOURCE:-hub}"
    fi ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

# block <file> <n> -> the n-th (1-based) model-route block of <file>
block() {
  awk -v want="$2" '/# >>> model-route/{n++; on=(n==want)} on{print} /# <<< model-route/{on=0}' "$DIR/$1"
}

# run_block <file> <n> <print-vars> [VAR=value ...] -> prints VAR=value lines, rc = the block's
run_block() {
  local f="$1" n="$2" vars="$3"; shift 3
  local code; code=$(block "$f" "$n")
  [ -n "$code" ] || { echo "NO_BLOCK"; return 99; }
  env -i PATH="$T/fakebin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" HOME="$T" \
    HARNESS="$T" JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 CURL_MODE="${CURL_MODE:-up}" \
    CURL_RUNGS="${CURL_RUNGS:-2}" CURL_SOURCE="${CURL_SOURCE:-hub}" CURL_GAPPED="${CURL_GAPPED:-0}" CURL_NOROUTE="${CURL_NOROUTE:-0}" \
    REQ_SINK="$T/req.log" "$@" bash -c '
      set -uo pipefail
      H="$HARNESS"; BIN="$HARNESS/bin"; SELF="$HARNESS/bin"; HERE="$HARNESS"
      PROJECT="${PROJECT:-proj-x}"; P="$PROJECT"; KEY=K-1; NUM=1; SLUG=s; BOX=box
      LOG="$HARNESS/logs/lane.log"; ALERTS="$HARNESS/logs/ALERTS.log"; BUILD="$HARNESS/build"
      STAMP() { date -u "+%Y-%m-%d %H:%M:%SZ"; }; STAMP=now
      alog() { :; }
      DISPATCH="$HARNESS/nx"; CANDIDATES="$HARNESS/nx"; ESCFILE="$HARNESS/nx"; PARKLOG="$HARNESS/nx"
      SPLITERR="$HARNESS/nx"; ROWMAP="$HARNESS/nx"; DBFAMS="$HARNESS/nx"
      . "$HARNESS/bin/lib/triage-shards-lib.sh"
      eval "$1"
      for v in $2; do printf "%s=%s\n" "$v" "${!v:-}"; done' _ "$code" "$vars"
}

reset_world() { rm -rf "$T/state/model-routes" "$T/flags"/alerted-* "$T/logs/ALERTS.log" "$T/req.log"; }

# lane_case <file> <n> <first-role> <noroute: 75 | empty:VAR> <expect "VAR=val ..."> [VAR=value ...]
lane_case() {
  local f="$1" n="$2" role="$3" none="$4" expect="$5"; shift 5
  local vars="" e out rc
  for e in $expect; do vars="$vars ${e%%=*}"; done
  local want; want=$(printf '%s\n' $expect)
  reset_world
  out=$(run_block "$f" "$n" "$vars" "$@"); rc=$?
  [ "$rc" = 0 ] && [ "$out" = "$want" ] && ok || bad "$f#$n up: rc=$rc got [$(echo $out)] want [$(echo $want)]"
  out=$(CURL_MODE=down run_block "$f" "$n" "$vars" "$@"); rc=$?
  [ "$rc" = 0 ] && [ "$out" = "$want" ] && ok || bad "$f#$n cached: rc=$rc got [$(echo $out)] want [$(echo $want)]"
  reset_world
  out=$(CURL_MODE=down run_block "$f" "$n" "$vars" "$@"); rc=$?
  case "$none" in
    75) [ "$rc" = 75 ] && ok || bad "$f#$n none: rc=$rc (want 75) out=[$(echo $out)]" ;;
    empty:*) v="${none#empty:}"
      [ "$rc" = 0 ] && grep -qx "$v=" <<<"$out" && ok \
        || bad "$f#$n none: rc=$rc, want rc 0 with $v empty; out=[$(echo $out)]" ;;
  esac
  grep -q "no model route for role '$role'" "$T/logs/ALERTS.log" 2>/dev/null && ok \
    || bad "$f#$n none: ALERTS.log does not name role '$role': $(cat "$T/logs/ALERTS.log" 2>/dev/null)"
  if grep -qE 'claude-|gpt-|grok-4|kimi|deepseek' <<<"$out"; then bad "$f#$n none: a model literal came out: $out"; else ok; fi
}

# --- 1. every converted lane ----------------------------------------------------
lane_case bin/run-triage.sh 1 triage 75 "TRIAGE_MODEL=m-triage@proj-x" 'GATE_DECISION=RUN board-changed'
lane_case bin/run-triage.sh 1 triage.light 75 "TRIAGE_MODEL=m-triage.light@proj-x" 'GATE_DECISION=RUN results-sweep'
lane_case bin/triage-shard.sh 1 triage 75 "SHARD_MODEL=m-triage@proj-x" TSH_GATE=board-changed
lane_case bin/run-preplan.sh 1 plan 75 "PLAN_MODEL=m-plan@proj-x"
lane_case bin/run-decompose.sh 1 decompose 75 "DECOMPOSE_M=m-decompose@proj-x"
lane_case bin/orchestrate.sh 1 orchestrate empty:ORC_MODEL "ORC_MODEL=m-orchestrate ORC_FALLBACK=m1-orchestrate"
lane_case bin/box-chat.sh 1 orchestrate empty:CHAT_MODEL "CHAT_MODEL=m-orchestrate"
lane_case bin/product-cmd.sh 1 product 75 "CHAT_MODEL=m-product@proj-x"
lane_case bin/product-cmd.sh 2 product.revise 75 "REVISE_MODEL=m-product.revise@proj-x"
lane_case bin/run-product.sh 1 product.map 75 \
  "MAP_MODEL=m-product.map@proj-x SIGNALS_MODEL=m-product.signals@proj-x IDEATE_MODEL=m-product.ideate@proj-x SYNTH_MODEL=m-product.synth@proj-x"
lane_case bin/draft-proposal.sh 1 product.prd 75 "PRD_MODEL=m-product.prd@proj-x MOCKUP_MODEL=m-product.mockup@proj-x"
lane_case bin/greenfield.sh 1 greenfield 75 \
  "GF_MAP_MODEL=m-greenfield GF_SIGNALS_MODEL=m-greenfield.signals GF_IDEATE_MODEL=m-greenfield.ideate GF_SYNTH_MODEL=m-greenfield.synth GF_MOCKUP_MODEL=m-greenfield.mockup GF_DECK_MODEL=m-greenfield.deck"
lane_case bin/alert-triage.sh 1 alert.triage 75 \
  "ALERT_MODEL=m-alert.triage FLOOR_MODEL=m-housekeeping.floor FLOOR_RUNNER=r-housekeeping.floor FLOOR_FALLBACK=m1-housekeeping.floor"
lane_case bin/alerts-medic.sh 1 housekeeping.floor 75 \
  "FLOOR_MODEL=m-housekeeping.floor FLOOR_RUNNER=r-housekeeping.floor FLOOR_FALLBACK=m1-housekeeping.floor"
lane_case bin/watchdog-responder.sh 1 responder 75 "RESPONDER_M=m-responder"
lane_case bin/remediate-agent.sh 1 remediate 75 "MODEL=m-remediate@proj-x"
lane_case bin/rule-miner.sh 1 rule.miner 75 "MINER_MODEL=m-rule.miner"
lane_case bin/lander.sh 1 lander 75 "LANDER_M=m-lander@proj-x"
lane_case bin/runner-bench.sh 1 bench 75 "BENCH_MODEL=m-bench"
lane_case bin/claude-auth-check.sh 1 triage 75 "PROBE_M=m-triage PROBE_F=m-auth.fallback"
for l in codex openrouter fireworks grok; do
  lane_case bin/lane-probe.sh 1 "$l.default" 75 "PROBE_MODEL=m-$l.default" LANE="$l"
done

# --- 2. an explicitly set env var still wins, and costs no worker call ----------
reset_world
out=$(run_block bin/rule-miner.sh 1 MINER_MODEL MINER_MODEL=operator-pick); rc=$?
[ "$rc" = 0 ] && [ "$out" = "MINER_MODEL=operator-pick" ] && ok || bad "env override: rc=$rc out=$out"
[ ! -s "$T/req.log" ] && ok || bad "env override still called the worker: $(cat "$T/req.log")"
# ...including a floor ladder's rung-0 overrides (rung 1 still from the DB)
reset_world
out=$(run_block bin/alerts-medic.sh 1 "FLOOR_MODEL FLOOR_RUNNER FLOOR_FALLBACK" \
  HOUSEKEEPING_FLOOR_MODEL=floor-pick HOUSEKEEPING_RUNNER=runner-pick)
[ "$out" = $'FLOOR_MODEL=floor-pick\nFLOOR_RUNNER=runner-pick\nFLOOR_FALLBACK=m1-housekeeping.floor' ] && ok \
  || bad "floor overrides: $out"

# ...and a 2xx that is not a model-routes answer (a stub, a proxy page) is an
# unreachable worker — the cache answers — never an authoritative "no route".
reset_world
run_block bin/rule-miner.sh 1 MINER_MODEL >/dev/null
out=$(CURL_MODE=junk run_block bin/rule-miner.sh 1 MINER_MODEL); rc=$?
[ "$rc" = 0 ] && [ "$out" = "MINER_MODEL=m-rule.miner" ] && ok || bad "junk 2xx with a warm cache: rc=$rc out=$out"
reset_world
CURL_MODE=junk run_block bin/rule-miner.sh 1 MINER_MODEL >/dev/null; rc=$?
[ "$rc" = 75 ] && ok || bad "junk 2xx with no cache must fail closed, rc=$rc"

# ...and a project-scoped lane in an outage, with only the HUB's answer cached,
# FAILS CLOSED: the project may carry an override this box has never seen, and
# precedence is per role, whole ladder — the hub rungs would be a guess for it.
reset_world
mkdir -p "$T/state/model-routes"
printf '0\tm-lander\tclaude\n' > "$T/state/model-routes/lander.tsv"
out=$(CURL_MODE=down run_block bin/lander.sh 1 LANDER_M); rc=$?
[ "$rc" = 75 ] && ok || bad "a project with only a hub cache must fail closed in an outage, rc=$rc out=$out"

# ...but a project whose LAST answer came from the hub (source=hub) carries the
# box's evidence that it has no override: in an outage it is served the hub's
# cached ladder, even with its own copy gone.
reset_world
run_block bin/lander.sh 1 LANDER_M >/dev/null                    # source=hub -> marker
[ -e "$T/state/model-routes/lander@proj-x.tsv.hub" ] && ok || bad "a source=hub answer must leave the hub marker"
printf '0\tm-lander-newer\tclaude\n' > "$T/state/model-routes/lander.tsv"
rm -f "$T/state/model-routes/lander@proj-x.tsv"
out=$(CURL_MODE=down run_block bin/lander.sh 1 LANDER_M); rc=$?
[ "$rc" = 0 ] && [ "$out" = "LANDER_M=m-lander-newer" ] && ok || bad "marked project in an outage must get the hub cache: rc=$rc out=$out"
# an override answering (source=project) removes the marker: the hub is never
# served to it again, only its own cached ladder
CURL_SOURCE=project run_block bin/lander.sh 1 LANDER_M >/dev/null
[ ! -e "$T/state/model-routes/lander@proj-x.tsv.hub" ] && ok || bad "a project override must clear the hub marker"
out=$(CURL_MODE=down run_block bin/lander.sh 1 LANDER_M); rc=$?
[ "$rc" = 0 ] && [ "$out" = "LANDER_M=m-lander@proj-x" ] && ok || bad "an overridden project in an outage must get ITS cache, never the hub's: rc=$rc out=$out"
rm -f "$T/state/model-routes/lander@proj-x.tsv"
CURL_MODE=down run_block bin/lander.sh 1 LANDER_M >/dev/null; rc=$?
[ "$rc" = 75 ] && ok || bad "an overridden project with no cache of its own must fail closed, not take the hub's (rc=$rc)"

# ...a project whose route has since gone ("no route": source=none, empty) keeps
# NOTHING from its hub era: the marker AND its own hub-era cache are dropped by
# that very answer, so the next outage fails closed. No manual cache rm here —
# the rc 75 has to come from the resolver.
reset_world
run_block bin/lander.sh 1 LANDER_M >/dev/null                    # source=hub -> marker + cache
[ -e "$T/state/model-routes/lander@proj-x.tsv.hub" ] && [ -s "$T/state/model-routes/lander@proj-x.tsv" ] \
  && ok || bad "setup: the source=hub answer must leave the marker and the project cache"
CURL_NOROUTE=1 run_block bin/lander.sh 1 LANDER_M >/dev/null; rc=$?  # the route is gone
[ "$rc" = 75 ] && ok || bad "a source=none answer is no route: rc 75, got $rc"
[ ! -e "$T/state/model-routes/lander@proj-x.tsv.hub" ] && ok || bad "a source=none answer must clear the hub marker"
# The hub cache is present, so the rc 75 below can only come from the marker being gone (BH-1588).
printf '0\tm-lander\tclaude\n' > "$T/state/model-routes/lander.tsv"
CURL_MODE=down run_block bin/lander.sh 1 LANDER_M >/dev/null; rc=$?
[ "$rc" = 75 ] && ok || bad "after the worker said no route, an outage must fail closed, not replay hub-era rungs (rc=$rc)"

# ...while a GAPPED project override (no rung 0) is, on the deployed worker, the
# hub: source=hub with the gapped rows beside it. Online and in an outage alike
# the project runs the hub ladder — outage behaviour matches online behaviour.
reset_world
CURL_GAPPED=1 run_block bin/lander.sh 1 LANDER_M >/dev/null
[ -e "$T/state/model-routes/lander@proj-x.tsv.hub" ] && ok || bad "a gapped override answered source=hub: the marker must be written"
out=$(CURL_GAPPED=1 run_block bin/lander.sh 1 LANDER_M); [ "$out" = "LANDER_M=m-lander" ] && ok || bad "online, a gapped override runs the hub ladder: $out"
out=$(CURL_MODE=down run_block bin/lander.sh 1 LANDER_M); rc=$?
[ "$rc" = 0 ] && [ "$out" = "LANDER_M=m-lander" ] && ok || bad "in an outage, a gapped override runs the hub ladder, as online: rc=$rc out=$out"

# --- 2b. a ONE-rung housekeeping floor runs on that rung alone ------------------
reset_world
out=$(CURL_RUNGS=1 run_block bin/alerts-medic.sh 1 "FLOOR_MODEL FLOOR_RUNNER FLOOR_FALLBACK FLOOR_RUNNERS_ONLY"); rc=$?
[ "$rc" = 0 ] && [ "$out" = $'FLOOR_MODEL=m-housekeeping.floor\nFLOOR_RUNNER=r-housekeeping.floor\nFLOOR_FALLBACK=m-housekeeping.floor\nFLOOR_RUNNERS_ONLY=r-housekeeping.floor' ] \
  && ok || bad "one-rung floor must run on rung 0 only (runners pinned): rc=$rc out=$(echo $out)"
# SPEC CHANGE (BH-2570): alert-triage's two floor calls now hand agent-call
# FLOOR_ALLOW, which is FLOOR_RUNNERS_ONLY narrowed by the lane's TRIAGE_RUNNERS
# allowlist (FLOOR_RUNNERS_ONLY unchanged when the knob is empty). The medic
# has no such knob and still hands FLOOR_RUNNERS_ONLY itself. The behaviour
# (one-rung floor, no knob -> AGENT_CALL_RUNNERS=<rung-0 runner>) is driven
# through the real lane in tests/alert-triage-runners.bh-2544-test.sh R4.
grep -q 'AGENT_CALL_RUNNERS="\$FLOOR_RUNNERS_ONLY"' "$DIR/bin/alerts-medic.sh" && [ "$(grep -c 'AGENT_CALL_RUNNERS="\$FLOOR_ALLOW"' "$DIR/bin/alert-triage.sh")" = 2 ] \
  && grep -q 'FLOOR_ONLY=$(_norm_runners "${FLOOR_RUNNERS_ONLY:-}")' "$DIR/bin/alert-triage.sh" \
  && ok || bad "every floor call must hand FLOOR_RUNNERS_ONLY (alert-triage: narrowed to FLOOR_ALLOW) to agent-call as AGENT_CALL_RUNNERS"
# a floor with no usable rung 0 stops the lane LOUDLY — the alert is written from
# the caller's shell (the resolver loaded there), never swallowed in a subshell
reset_world
out=$(CURL_MODE=down run_block bin/alerts-medic.sh 1 FLOOR_MODEL HOUSEKEEPING_RUNNER= ); rc=$?
[ "$rc" = 75 ] && grep -q "housekeeping.floor" "$T/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "a floor with no route must stop with rc 75 AND an ALERTS line: rc=$rc alerts=$(cat "$T/logs/ALERTS.log" 2>/dev/null)"
reset_world; mkdir -p "$T/state/model-routes"
printf '0\t\tfireworks\n' > "$T/state/model-routes/housekeeping.floor.tsv"
CURL_MODE=down run_block bin/alerts-medic.sh 1 FLOOR_MODEL >/dev/null; rc=$?
[ "$rc" = 75 ] && grep -q "no usable rung 0" "$T/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "a rung 0 with no model must stop with rc 75 AND an ALERTS line: rc=$rc alerts=$(cat "$T/logs/ALERTS.log" 2>/dev/null)"

# --- 3. lane_model leaves the caller's shell options alone --------------------------
reset_world
OPTS=$(env -i PATH="$T/fakebin:/usr/bin:/bin" HOME="$T" HARNESS="$T" JOBS_URL=https://jobs.invalid bash -c '
  set +u; set +o pipefail
  . "$HARNESS/bin/lib/lane-model.sh"
  m=$(lane_model NOPE_MODEL triage) || exit 9
  lane_role_model triage >/dev/null || exit 9
  echo "$m"; set -o | awk "\$1==\"nounset\"||\$1==\"pipefail\"{print \$1\"=\"\$2}"')
[ "$OPTS" = $'m-triage\nnounset=off\npipefail=off' ] && ok || bad "lane_model changed the caller's options or failed: $OPTS"
# a malformed env name is a caller bug: rc 1, no call
out=$(env -i PATH="$T/fakebin:/usr/bin:/bin" HARNESS="$T" bash -c '. "$HARNESS/bin/lib/lane-model.sh"; lane_model "bad name" triage'); rc=$?
[ "$rc" = 1 ] && ok || bad "malformed env name gave rc=$rc"

# --- 4. prompt-eval grades on the lane's own roles, per project -----------------
FN=$(sed -n '/^model_for_gate() {/,/^}/p' "$DIR/bin/prompt-eval.sh")
[ -n "$FN" ] && ok || bad "prompt-eval.sh: model_for_gate not found"
pe() { env -i PATH="$T/fakebin:/usr/bin:/bin" HOME="$T" HARNESS="$T" JOBS_URL=https://jobs.invalid \
  CURL_MODE="${CURL_MODE:-up}" "${@:3}" bash -c 'SELF="$HARNESS/bin"; eval "$1"; model_for_gate "$2" proj-x' _ "$FN" "$1"; }
reset_world
[ "$(pe results-sweep x)" = "m-triage.light@proj-x" ] && ok || bad "prompt-eval sweep gate: $(pe results-sweep x)"
[ "$(pe board-changed x)" = "m-triage@proj-x" ] && ok || bad "prompt-eval judgment gate: $(pe board-changed x)"
[ "$(pe board-changed x PROMPT_EVAL_MODEL=eval-pick)" = "eval-pick" ] && ok || bad "PROMPT_EVAL_MODEL override lost"
reset_world
CURL_MODE=down pe board-changed x >/dev/null; rc=$?
[ "$rc" = 75 ] && ok || bad "prompt-eval with no route gave rc=$rc (want 75)"

# --- 5. no model literal is left in any file this slice converted ------------------
LINT=$("$DIR/tests/model-literal-lint.sh" "$DIR" 2>/dev/null)
for f in bin/run-triage.sh bin/triage-shard.sh bin/lib/triage-shards-lib.sh bin/lib/lane-model.sh \
         bin/run-preplan.sh bin/run-decompose.sh bin/orchestrate.sh bin/product-cmd.sh bin/run-product.sh \
         bin/greenfield.sh bin/draft-proposal.sh bin/alert-triage.sh bin/alerts-medic.sh \
         bin/watchdog-responder.sh bin/remediate-agent.sh bin/rule-miner.sh bin/transcript-cost.sh \
         bin/lane-probe.sh bin/runner-bench.sh bin/prompt-eval.sh bin/claude-auth-check.sh \
         bin/update-runners.sh bin/lander.sh bin/box-chat.sh \
         catalog/lanes.d/alert-triage.json catalog/lanes.d/alerts-medic.json \
         catalog/lanes.d/claude-auth-check.json catalog/lanes.d/prompt-eval.json catalog/lanes.d/run-triage.json; do
  hits=$(printf '%s\n' "$LINT" | grep -F "$f:" )
  [ -z "$hits" ] && ok || bad "model literal(s) left in $f: $hits"
done

echo "model-route-other-lanes: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
