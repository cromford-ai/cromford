#!/bin/bash
# fly/lane-run-entrypoint.sh — the boot of a machine in the Fly app `lane-run`
# (BH-6126, BH-6047 part 3 of 5). bin/lane-fleet.sh starts these machines; each
# one runs bin/lane-run-worker.sh, which claims lane_runs rows and runs them.
#
# The image carries no secret. HARNESS_SECRET, JOBS_URL and the GitHub App
# variables are Fly secrets (`flyctl secrets set ... -a lane-run`), and Fly
# sets FLY_MACHINE_ID. This script:
#   1. exits 78 with one stderr line naming the variable (never its value)
#      when HARNESS_SECRET, JOBS_URL or FLY_MACHINE_ID is not set;
#   2. writes global.env (JOBS_URL, HARNESS_SECRET) into the env dir
#      bin/lib/env-path.sh resolves, mode 600;
#   3. when GH_APP_ID and GH_APP_PRIVATE_KEY (the PEM text) are set, writes the
#      key to github-app.pem and github-app.env (GH_APP_ID,
#      GH_APP_PRIVATE_KEY_FILE, every GH_APP_INSTALLATION_* variable), mode 600,
#      the file bin/gh-token.sh reads;
#   4. execs bin/lane-run-worker.sh --machine "$FLY_MACHINE_ID".
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
printf 'JOBS_URL=%s\nHARNESS_SECRET=%s\n' "$JOBS_URL" "$HARNESS_SECRET" > "$ENVD/global.env" \
  && chmod 600 "$ENVD/global.env" || { echo "lane-run-entrypoint: cannot write $ENVD/global.env" >&2; exit 78; }
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
export HARNESS="$H"
exec "$H/bin/lane-run-worker.sh" --machine "$FLY_MACHINE_ID"
