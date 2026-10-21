#!/bin/bash
# fly/lane-run-entrypoint.sh — the boot of a machine in the Fly app `lane-run`
# (BH-6126, BH-6047 part 3 of 5). bin/lane-fleet.sh starts these machines; each
# one runs bin/lane-run-worker.sh, which claims lane_runs rows and runs them.
#
# The image carries no secret. HARNESS_SECRET, JOBS_URL, the GitHub App
# variables and the agent CLI credentials (step 4) are Fly secrets
# (`flyctl secrets set ... -a lane-run`), and Fly sets FLY_MACHINE_ID. This script:
#   1. exits 78 with one stderr line naming the variable (never its value)
#      when HARNESS_SECRET, JOBS_URL or FLY_MACHINE_ID is not set;
#   2. writes global.env (JOBS_URL, HARNESS_SECRET, and
#      CLAUDE_CODE_OAUTH_TOKEN when set) into the env dir
#      bin/lib/env-path.sh resolves, mode 600;
#   3. when GH_APP_ID and GH_APP_PRIVATE_KEY (the PEM text) are set, writes the
#      key to github-app.pem and github-app.env (GH_APP_ID,
#      GH_APP_PRIVATE_KEY_FILE, every GH_APP_INSTALLATION_* variable), mode 600,
#      the file bin/gh-token.sh reads;
#   4. BH-6260 (the operator, 2026-10-17: "definitely let the fly machines have
#      credentials"): the agent CLI credentials, the same ones a Fly pool
#      build machine gets (bin/fly-envbundle.sh ships CLAUDE_CODE_OAUTH_TOKEN
#      in global.env; bin/fly-dispatch.sh pushes /root/.codex/auth.json and
#      config.toml). Here they are Fly secrets: CLAUDE_CODE_OAUTH_TOKEN, when
#      set, is one more global.env line; CODEX_AUTH_JSON and CODEX_CONFIG_TOML
#      (the file texts), when set, become $HOME/.codex/auth.json and
#      config.toml, mode 600. The two file variables are then unset. A
#      machine without them still boots, and an agent call there has no
#      credential (bin/agent-call.sh skips codex without auth.json; claude
#      fails its call), the same as on a box with no account;
#   5. exports LANE_RUN_CODE_SYNC=1, so the worker pulls main of the harness
#      repo before a claim (bin/lib/lane-run-code.sh), and execs
#      bin/lane-run-worker.sh --machine "$FLY_MACHINE_ID" (plus
#      --box "$LANE_RUN_BOX" when LANE_RUN_BOX is set);
#   6. BH-7716, the dedicated machine: when LANE_RUN_WORKERS is an integer
#      2..16 it does NOT exec. It starts N worker loops,
#      `bin/lane-run-worker.sh --machine "$FLY_MACHINE_ID-w<i>"` for i = 1..N
#      (plus --box "$LANE_RUN_BOX" when set), and supervises them:
#      - TERM or INT: TERM to every loop (each one releases its row within
#        lane_run.term_grace_s), wait for all, exit 0. INT is sent on as TERM:
#        a background job of a script starts with INT ignored, and the worker
#        treats the two the same.
#      - a loop that exits non-zero is started again after 5 s, at most 10
#        restarts an hour over all loops. Past that cap: one stderr line, TERM
#        to the other loops, wait, exit 1, so Fly's restart policy restarts
#        the machine. LANE_RUN_RESTART_SLEEP_S replaces the 5 s only with
#        HARNESS_TEST_SANDBOX=1 (a test seam).
#      - a loop that exits 0 is not started again; when no loop is left the
#        entrypoint exits 0.
#      Any other value (unset, 1, 0, 17, 08, text) is step 5's single exec.
set -u
H="${HARNESS:-/opt/harness}"
for v in HARNESS_SECRET JOBS_URL FLY_MACHINE_ID; do
  [ -n "${!v:-}" ] || { echo "lane-run-entrypoint: $v is not set; refusing to start" >&2; exit 78; }
done
# shellcheck source=bin/lib/env-path.sh
. "$H/bin/lib/env-path.sh" || { echo "lane-run-entrypoint: $H/bin/lib/env-path.sh did not load" >&2; exit 78; }
ENVD=$(harness_env_dir "$H")
umask 077
mkdir -p "$ENVD" "$H/logs" || { echo "lane-run-entrypoint: cannot create $ENVD" >&2; exit 78; }
{
  printf 'JOBS_URL=%s\nHARNESS_SECRET=%s\n' "$JOBS_URL" "$HARNESS_SECRET"
  [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$CLAUDE_CODE_OAUTH_TOKEN"
} > "$ENVD/global.env" \
  && chmod 600 "$ENVD/global.env" || { echo "lane-run-entrypoint: cannot write $ENVD/global.env" >&2; exit 78; }
if [ -n "${CODEX_AUTH_JSON:-}" ]; then
  CDX="${HOME:-/root}/.codex"
  mkdir -p "$CDX" && printf '%s\n' "$CODEX_AUTH_JSON" > "$CDX/auth.json" && chmod 600 "$CDX/auth.json" \
    || { echo "lane-run-entrypoint: cannot write $CDX/auth.json" >&2; exit 78; }
  if [ -n "${CODEX_CONFIG_TOML:-}" ]; then
    printf '%s\n' "$CODEX_CONFIG_TOML" > "$CDX/config.toml" && chmod 600 "$CDX/config.toml" \
      || { echo "lane-run-entrypoint: cannot write $CDX/config.toml" >&2; exit 78; }
  fi
fi
unset CODEX_AUTH_JSON CODEX_CONFIG_TOML
if [ -n "${GH_APP_ID:-}" ] && [ -n "${GH_APP_PRIVATE_KEY:-}" ]; then
  printf '%s\n' "$GH_APP_PRIVATE_KEY" > "$ENVD/github-app.pem" && chmod 600 "$ENVD/github-app.pem" \
    || { echo "lane-run-entrypoint: cannot write $ENVD/github-app.pem" >&2; exit 78; }
  {
    printf 'GH_APP_ID=%s\nGH_APP_PRIVATE_KEY_FILE=%s\n' "$GH_APP_ID" "$ENVD/github-app.pem"
    env | grep -E '^GH_APP_INSTALLATION_[A-Za-z0-9_]+=' || true
  } > "$ENVD/github-app.env" && chmod 600 "$ENVD/github-app.env" \
    || { echo "lane-run-entrypoint: cannot write $ENVD/github-app.env" >&2; exit 78; }
fi
unset GH_APP_PRIVATE_KEY
export HARNESS="$H" LANE_RUN_CODE_SYNC=1
LRE_BOX=(); [ -z "${LANE_RUN_BOX:-}" ] || LRE_BOX=(--box "$LANE_RUN_BOX")
[[ ${LANE_RUN_WORKERS:-} =~ ^([2-9]|1[0-6])$ ]] \
  || exec "$H/bin/lane-run-worker.sh" --machine "$FLY_MACHINE_ID" ${LRE_BOX[@]+"${LRE_BOX[@]}"}

# Step 6: the supervisor of N loops.
LRE_N="$LANE_RUN_WORKERS"
LRE_SLEEP=5
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${LANE_RUN_RESTART_SLEEP_S:-} =~ ^[0-9]{1,2}$ ]]; then LRE_SLEEP="$LANE_RUN_RESTART_SLEEP_S"; fi
declare -A LRE_PID=()      # loop index -> pid
LRE_RESTARTS=()            # epoch of each restart in the last hour

lre_start() {
  "$H/bin/lane-run-worker.sh" --machine "$FLY_MACHINE_ID-w$1" ${LRE_BOX[@]+"${LRE_BOX[@]}"} &
  LRE_PID[$1]=$!
}

# lre_stop_all — TERM to every loop still listed, then wait for each.
lre_stop_all() {
  local i
  for i in "${!LRE_PID[@]}"; do kill -TERM "${LRE_PID[$i]}" 2>/dev/null; done
  for i in "${!LRE_PID[@]}"; do wait "${LRE_PID[$i]}" 2>/dev/null; done
}

lre_on_signal() {
  trap '' TERM INT
  lre_stop_all
  exit 0
}
trap lre_on_signal TERM INT

for ((i = 1; i <= LRE_N; i++)); do lre_start "$i"; done
while [ "${#LRE_PID[@]}" -gt 0 ]; do
  wait -n -p LRE_DONE "${LRE_PID[@]}"; rc=$?
  # rc 127 with no pid: no child is left to wait for.
  [ -n "${LRE_DONE:-}" ] || { [ "$rc" = 127 ] && break; continue; }
  for i in "${!LRE_PID[@]}"; do [ "${LRE_PID[$i]}" = "$LRE_DONE" ] && break; done
  [ "${LRE_PID[$i]}" = "$LRE_DONE" ] || continue
  unset "LRE_PID[$i]"; LRE_DONE=""
  [ "$rc" = 0 ] && continue
  now=$(date -u +%s); kept=()
  for t in ${LRE_RESTARTS[@]+"${LRE_RESTARTS[@]}"}; do [ $((now - t)) -lt 3600 ] && kept+=("$t"); done
  LRE_RESTARTS=(${kept[@]+"${kept[@]}"})
  if [ "${#LRE_RESTARTS[@]}" -ge 10 ]; then
    echo "lane-run-entrypoint: loop w$i exited $rc after 10 restarts in the last hour; stopping all loops, exit 1" >&2
    trap '' TERM INT
    lre_stop_all
    exit 1
  fi
  echo "lane-run-entrypoint: loop w$i exited $rc; restart $(( ${#LRE_RESTARTS[@]} + 1 )) of 10 this hour in ${LRE_SLEEP}s" >&2
  LRE_RESTARTS+=("$now")
  # In the background and waited for, so a TERM during the wait runs the trap.
  sleep "$LRE_SLEEP" & wait "$!"
  lre_start "$i"
done
exit 0
