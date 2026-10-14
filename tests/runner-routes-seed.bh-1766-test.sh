#!/bin/bash
# tests/runner-routes-seed.bh-1766-test.sh — bin/runner-routes-seed.sh, the
# one-shot that writes a box's live RUNNER_* / RUNNER_*_FALLBACK values as hub
# stage.<stage> ladders (BH-1766, BH-1749.4). Driven for real: the script is
# copied into a scratch harness with the jobs client beside it, and curl is a
# stub on PATH that answers GETs from files and records every request.
#
# THE PROPERTIES UNDER TEST:
#   R1 RUNNER_TRIAGE=grok (env), fallback codex in global.env, no --apply ->
#      prints the grok -> codex ladder and "would write", sends no PUT;
#   R2 the same with --apply -> exactly one PUT, grok first, actor = box name,
#      expected_version = the scope_version read; "written", rc 0;
#   R3 the worker already holds that ladder -> "unchanged", no PUT, rc 0;
#   R4 one invalid runner anywhere -> rc 1, "refused: …", and NO request at
#      all (it is refused before the worker is asked anything), not even for
#      a valid stage in the same run;
#   R5 global.env values are normalised (quotes, spaces, case) and a runner
#      that is merely close ("claude-code") is refused;
#   R5b a trailing "# comment" on a global.env line is stripped (the hub's own lines)
#   R6 no RUNNER_* anywhere -> every stage "no box value", no request, rc 0;
#      a worker that answers 500 on the read -> rc 2, "worker read failed".
#
# Run from anywhere: bash tests/runner-routes-seed.bh-1766-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

mkdir -p "$T/bin/lib/jobs" "$T/env" "$T/fakebin" "$T/routes" "$T/logs"
cp "$DIR/bin/runner-routes-seed.sh" "$T/bin/runner-routes-seed.sh" 2>/dev/null
chmod +x "$T/bin/runner-routes-seed.sh" 2>/dev/null
cp "$DIR/bin/jobs-client.sh"     "$T/bin/jobs-client.sh"
cp "$DIR/bin/lib/env-path.sh"    "$T/bin/lib/env-path.sh"
cp "$DIR/bin/lib/model-route.sh" "$T/bin/lib/model-route.sh"
cp "$DIR"/bin/lib/jobs/*.sh      "$T/bin/lib/jobs/"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# GET /api/model-routes/<role> answers $T/routes/<role>.json when it exists, and
# otherwise the worker's real "no route" answer (200, empty ladder). A PUT is
# recorded (its body to $T/puts) and answered 200. CURL_MODE=get500 makes every
# GET a 500. Output shape is `<body>\n<status>`, what _jobs_req parses.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
METHOD=GET; BODY=""
while [ $# -gt 1 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2 ;;
    --data-binary) BODY="$2"; shift 2 ;;
    *) shift ;;
  esac
done
URL="$1"
printf '%s %s\n' "$METHOD" "$URL" >> "$REQ_SINK"
if [ "$METHOD" = PUT ]; then
  printf '%s\n' "$BODY" >> "$PUT_SINK"
  printf '{"changed":true}\n200\n'; exit 0
fi
[ "${CURL_MODE:-ok}" = get500 ] && { printf '{"error":"boom"}\n500\n'; exit 0; }
ROLE="${URL##*/api/model-routes/}"
if [ -s "$ROUTES/$ROLE.json" ]; then cat "$ROUTES/$ROLE.json"; printf '\n200\n'
else printf '{"role":"%s","ladder":[],"source":"none","scope_version":0}\n200\n' "$ROLE"; fi
EOF
chmod +x "$T/fakebin/curl"

# The worker's seeded state: stage.* on claude/codex, and the per-runner default roles.
route() { # route <role> <scope_version> <runner:model>...
  local role="$1" v="$2" i=0 rungs="" r; shift 2
  for r in "$@"; do
    rungs="$rungs${rungs:+,}{\"position\":$i,\"runner\":\"${r%%:*}\",\"model\":\"${r#*:}\"}"; i=$((i+1))
  done
  printf '{"role":"%s","ladder":[%s],"source":"hub","scope_version":%s}' "$role" "$rungs" "$v" > "$T/routes/$role.json"
}
reset_routes() {
  rm -f "$T/routes"/*.json
  for s in triage plan preplan execute review fix; do
    route "stage.$s" 40 "claude:m-claude-stage" "codex:m-codex"
  done
  route codex.default 3 "codex:m-codex"
  route grok.default 4 "grok:m-grok"
  route claude.ladder 5 "claude:m-claude-ladder"
}

run() { # run [args...] -> stdout+stderr in $T/out, rc in RC
  : > "$T/req.log"; : > "$T/puts"
  ( env -i PATH="$T/fakebin:$PATH" HOME="$T" HARNESS="$T" HARNESS_ENV_DIR="$T/env" \
      HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 BOX_NAME=hub \
      REQ_SINK="$T/req.log" PUT_SINK="$T/puts" ROUTES="$T/routes" ${EXTRA_ENV:-} \
      bash "$T/bin/runner-routes-seed.sh" "$@" ) > "$T/out" 2>&1
  RC=$?
}
puts() { grep -c . "$T/puts" 2>/dev/null || true; }
reqs() { grep -c . "$T/req.log" 2>/dev/null || true; }

# ── R1 ──────────────────────────────────────────────────────────────────────
echo "R1: RUNNER_TRIAGE=grok, no --apply -> prints the ladder, would write, no PUT"
reset_routes
printf 'HARNESS_SECRET=x\nRUNNER_TRIAGE_FALLBACK=codex\n' > "$T/env/global.env"
EXTRA_ENV="RUNNER_TRIAGE=grok" run
if [ "$RC" = 0 ] && grep -q 'stage.triage: grok(m-grok) -> codex(m-codex)' "$T/out" \
   && grep 'stage.triage:' "$T/out" | grep -q 'would write' && [ "$(puts)" = 0 ] \
   && ! grep -q '^PUT' "$T/req.log"; then ok
else bad "R1 rc=$RC puts=$(puts) out=$(cat "$T/out")"; fi

# ── R2 ──────────────────────────────────────────────────────────────────────
echo "R2: --apply -> exactly one PUT, grok first, actor=hub, expected_version=40"
EXTRA_ENV="RUNNER_TRIAGE=grok" run --apply
B=$(head -1 "$T/puts")
if [ "$RC" = 0 ] && [ "$(puts)" = 1 ] \
   && [ "$(printf '%s' "$B" | jq -r '.role')" = stage.triage ] \
   && [ "$(printf '%s' "$B" | jq -r '.ladder[0].runner + "/" + .ladder[0].model')" = grok/m-grok ] \
   && [ "$(printf '%s' "$B" | jq -r '.ladder[1].runner')" = codex ] \
   && [ "$(printf '%s' "$B" | jq -r '.ladder | length')" = 2 ] \
   && [ "$(printf '%s' "$B" | jq -r '.actor')" = hub ] \
   && [ "$(printf '%s' "$B" | jq -r '.project')" = null ] \
   && [ "$(printf '%s' "$B" | jq -r '.expected_version')" = 40 ] \
   && grep 'stage.triage:' "$T/out" | grep -q 'written'; then ok
else bad "R2 rc=$RC puts=$(puts) body=$B out=$(cat "$T/out")"; fi

# ── R3 ──────────────────────────────────────────────────────────────────────
echo "R3: the worker already holds grok -> codex -> unchanged, no PUT"
route stage.triage 41 "grok:m-grok" "codex:m-codex"
EXTRA_ENV="RUNNER_TRIAGE=grok" run --apply
if [ "$RC" = 0 ] && [ "$(puts)" = 0 ] && grep 'stage.triage:' "$T/out" | grep -q 'unchanged'; then ok
else bad "R3 rc=$RC puts=$(puts) out=$(cat "$T/out")"; fi

# ── R4 ──────────────────────────────────────────────────────────────────────
echo "R4: RUNNER_PLAN=openai -> rc 1, refused before any request, no PUT even for a valid stage"
reset_routes
EXTRA_ENV="RUNNER_TRIAGE=grok RUNNER_PLAN=openai" run --apply
if [ "$RC" = 1 ] && grep -q 'refused: RUNNER_PLAN=openai' "$T/out" && [ "$(puts)" = 0 ] \
   && [ "$(reqs)" = 0 ]; then ok
else bad "R4 rc=$RC puts=$(puts) reqs=$(reqs) out=$(cat "$T/out")"; fi

# ── R5 ──────────────────────────────────────────────────────────────────────
echo "R5: global.env quotes/space/case normalised; claude-code refused"
printf 'RUNNER_REVIEW_FALLBACK="Codex "\nRUNNER_REVIEW=Grok\n' > "$T/env/global.env"
EXTRA_ENV="" run
R5A_RC=$RC; R5A_OUT=$(cat "$T/out")
printf 'RUNNER_REVIEW_FALLBACK="Codex "\nRUNNER_FIX=claude-code\n' > "$T/env/global.env"
run --apply
if [ "$R5A_RC" = 0 ] && grep -q 'stage.review: grok(m-grok) -> codex(m-codex)' <<<"$R5A_OUT" \
   && [ "$RC" = 1 ] && grep -q 'refused: RUNNER_FIX=claude-code' "$T/out" && [ "$(puts)" = 0 ]; then ok
else bad "R5 first rc=$R5A_RC out=$R5A_OUT / second rc=$RC out=$(cat "$T/out")"; fi

# ── R5b ─────────────────────────────────────────────────────────────────────
echo "R5b: a trailing '# comment' on a global.env line is not part of the value"
# The hub's own lines (the operator 2026-09-15) carry one: RUNNER_PLAN_FALLBACK=openrouter  # ...
printf 'RUNNER_REVIEW=grok  # note: caps -> project-6, not codex\nRUNNER_REVIEW_FALLBACK="codex" # x\n' > "$T/env/global.env"
EXTRA_ENV="" run
if [ "$RC" = 0 ] && grep -q 'stage.review: grok(m-grok) -> codex(m-codex)' "$T/out" \
   && ! grep -q refused "$T/out"; then ok
else bad "R5b rc=$RC out=$(cat "$T/out")"; fi

# ── R6 ──────────────────────────────────────────────────────────────────────
echo "R6: no RUNNER_* -> no box value for all six, no request; a 500 read -> rc 2"
printf 'HARNESS_SECRET=x\n' > "$T/env/global.env"
run --apply
N=$(grep -c 'no box value' "$T/out")
if [ "$RC" = 0 ] && [ "$N" = 6 ] && [ "$(reqs)" = 0 ]; then ok
else bad "R6a rc=$RC n=$N reqs=$(reqs) out=$(cat "$T/out")"; fi
EXTRA_ENV="RUNNER_TRIAGE=grok CURL_MODE=get500" run --apply
if [ "$RC" = 2 ] && grep -q 'worker read failed for stage.triage: http=500' "$T/out" && [ "$(puts)" = 0 ] \
   && ! grep -q 'unchanged' "$T/out"; then ok
else bad "R6b rc=$RC out=$(cat "$T/out")"; fi

# ── the claude rung's model ─────────────────────────────────────────────────
echo "R7: a claude rung takes the hub ladder's claude model, else claude.ladder rung 0"
printf 'RUNNER_EXECUTE=codex\nRUNNER_EXECUTE_FALLBACK=claude\n' > "$T/env/global.env"
run
A=$(grep 'stage.execute:' "$T/out")
route stage.execute 7 "codex:m-codex"
run
B=$(grep 'stage.execute:' "$T/out")
if grep -q 'codex(m-codex) -> claude(m-claude-stage)' <<<"$A" \
   && grep -q 'codex(m-codex) -> claude(m-claude-ladder)' <<<"$B"; then ok
else bad "R7 a=$A b=$B"; fi

echo "R8: a runner with no <runner>.default model is refused, not guessed"
printf 'RUNNER_FIX=fireworks\n' > "$T/env/global.env"
run --apply
if [ "$RC" = 1 ] && grep -q 'fireworks.default' "$T/out" && [ "$(puts)" = 0 ]; then ok
else bad "R8 rc=$RC out=$(cat "$T/out")"; fi

echo
echo "runner-routes-seed: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
