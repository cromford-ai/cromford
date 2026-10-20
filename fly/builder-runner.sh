#!/bin/bash
# fly/builder-runner.sh — the one process a builder machine runs (Phase 1).
#
# Job contract (per plan "Phase 1 > fly/builder-runner.sh"):
#   1. Wait up to WARMUP_WAIT_S (default 30 min, BH-7215) for the hub to push
#      env + a job file. No job => exit 0
#      (machine autostops; covers a spurious start).
#   2. First-boot warm-up if the repo is missing: clone, install deps
#      (pnpm store on the volume), codegraph init + telemetry off.
#   3. Per job: 60s heartbeat; PR-adopt preflight; else run run-build.sh with
#      BUILDER_EXEC=1 BUILDER_NO_MERGE=1 (no merge, no board writes on a builder).
#   4. Write RESULT (build's RESULT line + TIER + PR URL + artifact paths); post
#      a `build` beat so the console shows builder stages live.
#   5. Loop; 10 min idle with no push => clear /run/harness-env and exit 0 =>
#      machine autostops (restart policy `no`).
#
# Open-detail decisions (simplest robust option, per task brief):
#   - IDLE_TIMEOUT is a constant here; a builder is single-job, single-project,
#     so no config surface is warranted for Phase 1. The WARMUP wait is not
#     (BH-7215): the hub passes WARMUP_WAIT_S on `fly machine run`, from the knob
#     lane.fly-pool.<project>.warmup_wait_s.
#   - Job file is /run/harness/job.json {ticket_id,key,attempt}, with an
#     optional rebase:{kind,slug,url,pr,branch,head,base} member (BH-486) that
#     makes the job a POOL REBASE and not a build at all — see run_rebase_job.
#     We poll the tmpfs rather than run an inbound listener — the hub PUSHES
#     (scp) the file, matching the push-model design (builder initiates nothing
#     on the tailnet).
#   - RESULT is written to /run/harness/RESULT (tmpfs); the dispatcher pulls it.
#     We copy the run-build BUILD dir's RESULT verbatim and append TIER/PR/paths.
#   - SMOKE job (key=SMOKE) is a self-contained health probe (the plan's Phase-1
#     verify): it runs the claude CLI directly and writes RESULT, exercising the
#     env bundle + cost.csv host tagging without needing a real ticket/repo.
#   - We resolve the repo slug from fleet.conf if present (synced onto the
#     volume), else from the pushed <project>.env REPO_SLUG, so the warm-up clone
#     has no hardcoded owner.
set -uo pipefail

HARNESS=/data/harness
ENVDIR=/run/harness-env
JOBDIR=/run/harness
JOB="$JOBDIR/job.json"
RESULT_FILE="$JOBDIR/RESULT"
HEARTBEAT="$JOBDIR/heartbeat"
PROJECT="${PROJECT:?PROJECT must be set by entrypoint}"
REPO="/data/repos/$PROJECT"
IDLE_TIMEOUT=600          # 10 min with no pushed job -> autostop
# BH-7215: the hub passes WARMUP_WAIT_S (lane knob lane.fly-pool.<p>.warmup_wait_s).
# A fixed 600 s lost spawns whose hub setup took longer (#7174).
WARMUP_WAIT="${WARMUP_WAIT_S:-1800}"
case "$WARMUP_WAIT" in ''|*[!0-9]*|0) WARMUP_WAIT=1800 ;; esac
POLL=5

STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
log()   { echo "[$(STAMP)] [runner/$PROJECT] $*"; }

mkdir -p "$JOBDIR"

# BH-1574: the GitHub-call ledger shim first on PATH, so every raw `gh` a build
# stage or its agent runs is ledgered (bin/gh-ledger/gh). fly/Dockerfile carries
# the same ENV for images built after this; this line covers the images already
# in the pool, because this file rides every harness sync and the image does not.
# Only when the directory is there: a volume that has not synced it yet keeps
# the PATH it had.
if [ -x "$HARNESS/bin/gh-ledger/gh" ]; then
  case ":$PATH:" in
    *":$HARNESS/bin/gh-ledger:"*) ;;
    *) export PATH="$HARNESS/bin/gh-ledger:$PATH" ;;
  esac
fi

# Which url on a build record is that record's OWN pr, and which is its parent's
# (BH-848). Guarded: an older volume without the lib keeps the first-url grep the
# assemble block below falls back to.
# shellcheck source=bin/lib/result-pr-url.sh
[ -r "$HARNESS/bin/lib/result-pr-url.sh" ] && . "$HARNESS/bin/lib/result-pr-url.sh"

# --- console beat (outbound HTTPS; env bundle carries CONSOLE_URL/HARNESS_SECRET)
beat() { # beat '<json>'
  [ -n "${CONSOLE_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ] || return 0
  curl -s --max-time 15 -X POST -H "Authorization: Bearer $HARNESS_SECRET" \
    -H 'Content-Type: application/json' -d "$1" "$CONSOLE_URL/api/beat" >/dev/null 2>&1 || true
}

# --- model prices: the pool prices a row the way the hub does ----------------
# (BH-1032) A pool machine's rootfs is built from the repo, so until now it
# priced every row it wrote from catalog/model-prices.json — the COMMITTED
# fallback, which moves only when a human lands a PR — while the hub priced the
# same call from state/model-prices.json, refreshed daily. One call, two prices,
# decided by which machine ran it, and the pool is the fleet's largest execute
# lane. One pull at machine start puts the hub's own rates on this disk, at the
# path bin/lib/cost-row.sh already prefers.
#
# FAIL-OPEN, ONCE, AND NEVER BLOCKING: the script exits 0 whenever the machine
# still has a usable table, the catalog fallback is right there either way, and
# a build must never wait on a price refresh.
model_prices_pull() {
  [ -x "$HARNESS/bin/model-prices-sync.sh" ] || return 0
  ( export HARNESS="$HARNESS"
    timeout "${MODEL_PRICES_SYNC_TIMEOUT_S:-30}" \
      "$HARNESS/bin/model-prices-sync.sh" ) >/dev/null 2>&1 || true
  [ -s "$HARNESS/state/model-prices.json" ] \
    && log "model prices: pulled the model_prices table into state/model-prices.json" \
    || log "model prices: no table on this machine — rows price from catalog/model-prices.json"
  return 0
}

# --- cost rows: the machine pushes its OWN bill while it runs ----------------
# (2026-09-14) A pool machine is volume-less — rootfs, and with it
# /data/harness/logs/cost.csv, dies with the machine. Every watcher box has
# mirrored its rows into the harness-jobs cost_rows table every 10 minutes since
# 2026-09-02; pool machines had no such loop, so a day of pool spend ($1,456 on
# 2026-09-13, $1,366 of it project-5) existed only as jobs.spent_usd per-job
# totals: no per-stage row, no per-model row, no account label, nothing to
# answer "what did this account spend this week" with.
#
# So the machine runs the SAME bin/cost-rows-push.sh every box runs, under the
# box id fly/entrypoint.sh decided (pool-<project>-<machine-id>) — the id
# bin/fly-pool.sh's reap uses for the reaped copy too, so the (box, row_hash) PK
# makes the overlap a no-op instead of a double count.
#
# FAIL-OPEN, ALWAYS. Every call is `timeout ... || true`: a push that fails, or
# a worker that is down, costs a delay and never a build. The push holds
# locks/cost-rows-push.lock, so a final flush that lands while the periodic loop
# is mid-push simply skips — that push is already doing the work, and anything
# it does not finish the hub's reap picks up.
# ONE ID FOR BOTH WRITERS (BH-1032 review). This is the id the periodic flush
# pushes under, and since bin/lib/cost-row.sh's cost_row_box_id now reads
# $COST_ROWS_BOX FIRST, it is also the id the at-source write inside the build
# files its rows under. fly/entrypoint.sh exports it; the fallback below is for
# a machine started without it. Two resolvers here would split one call across
# two PK rows and double the pool's share of every fleet total.
COST_ROWS_BOX="${COST_ROWS_BOX:-$(hostname -s 2>/dev/null || echo "pool-$PROJECT")}"
export COST_ROWS_BOX

# cost_rows_on — rc 0 when the machine pushes. Off, CR_OFF names why, for the
# log line. The kill switch is the settings row switch.cost-rows-push-off[.<box>]
# before flags/cost-rows-push-off (BH-2433); lane-switch.sh loads here, on the
# first read, because tests/pool-cost-rows-test.sh runs this block on its own.
cost_rows_on() {
  CR_OFF=""
  [ "${COST_ROWS_PUSH:-1}" = 0 ] && { CR_OFF="COST_ROWS_PUSH=0"; return 1; }
  if ! command -v lane_switch >/dev/null 2>&1; then
    # shellcheck source=bin/lib/lane-switch.sh
    . "$HARNESS/bin/lib/lane-switch.sh" 2>/dev/null || true
    command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "$HARNESS/flags/$1" ]; }   # no lib: the file, as before
  fi
  if lane_switch cost-rows-push-off file; then
    case "${LANE_SWITCH_SRC:-legacy}" in
      box-row)   CR_OFF="settings $(_ls_box_key cost-rows-push-off)" ;;
      fleet-row) CR_OFF="settings switch.cost-rows-push-off" ;;
      *)         CR_OFF="flags/cost-rows-push-off" ;;
    esac
    return 1
  fi
  [ -x "$HARNESS/bin/cost-rows-push.sh" ] || { CR_OFF="no bin/cost-rows-push.sh on this machine"; return 1; }
  return 0
}

# BH-1574: the machine's GitHub-call ledger (state/gh-rest-ledger/) rides the
# same flushes as its cost rows — the periodic loop and every terminal path —
# under the SAME box id, so the fleet report names the pool machine that spent
# the hub App's bucket. Its own switch (flags/gh-ledger-push-off, read by the
# script), fail-open, and never a reason a build waits.
gh_ledger_flush() {
  [ -x "$HARNESS/bin/gh-ledger-push.sh" ] || return 0
  ( export HARNESS="$HARNESS"
    timeout "${COST_ROWS_PUSH_TIMEOUT_S:-60}" \
      "$HARNESS/bin/gh-ledger-push.sh" "$COST_ROWS_BOX" ) >/dev/null 2>&1 || true
  return 0
}

cost_rows_flush() { # one push, now; never blocks and never fails a build
  gh_ledger_flush
  cost_rows_on || return 0
  # HARNESS is exported into the subshell only: bin/cost-rows-push.sh reads it
  # to find logs/, state/ and env/, and exporting it in THIS shell would hand a
  # variable run-build.sh resolves for itself to every stage of the build.
  ( export HARNESS="$HARNESS"
    timeout "${COST_ROWS_PUSH_TIMEOUT_S:-60}" \
      "$HARNESS/bin/cost-rows-push.sh" "$COST_ROWS_BOX" ) >/dev/null 2>&1 || true
  return 0
}

start_cost_rows_loop() {
  # Pulled here rather than in its own call site: this runs once, early, on
  # every machine, before the first stage makes a billable call and therefore
  # before the first row needs a price.
  model_prices_pull
  if ! cost_rows_on; then
    log "cost rows: push OFF ($CR_OFF)"
    return 0
  fi
  # `trap - EXIT` inside the subshell: the parent's EXIT trap is a final flush,
  # and a background loop that inherits it would fire one more push every time
  # the subshell is torn down.
  ( trap - EXIT
    while true; do sleep "${COST_ROWS_PUSH_S:-300}"; cost_rows_flush; done ) &
  CR_PID=$!
  log "cost rows: mirroring every ${COST_ROWS_PUSH_S:-300}s as box $COST_ROWS_BOX (pid $CR_PID)"
}

# --- model routes: this machine's own cache, warmed at every job start -------
# (BH-1510.1) Every model a build runs is a model_routes row, read through
# bin/lib/model-route.sh, and a pool machine can reach the worker that serves
# them — it pushes its cost rows and pulls its prices from the same place. So it
# resolves its own ladders rather than being handed them: at each job start,
# once the bundle has put HARNESS_SECRET/JOBS_URL in the environment, every role
# a build can ask for is read once. Each answer lands in the resolver's box
# cache (state/model-routes/), which is what serves the rest of the build — and
# every later job on a reused machine — if the worker then goes away. A machine
# that has NEVER reached the worker has nothing to fall back on and its build
# defers (run-build's no-route stop), rather than run on a guessed model.
#
# FAIL-OPEN AND BOUNDED, like the price pull: a lookup that fails costs a log
# line here, never a job; the build's own lookups decide what happens next.
#
# THE DISPATCHER'S ANSWERS COME FIRST (BH-1572). A machine that has never
# reached the worker had nothing to fall back on, so a short worker blip
# deferred every freshly spawned builder. The dispatcher now ships the ladders
# it resolved for this project as $ENVDIR/model-routes.tsv, each stamped with
# its resolution time (bin/lib/model-route.sh model_routes_bundle). They go
# into the cache before the warm, only where this machine holds nothing newer,
# and the warm then replaces every one the worker answers — a live answer still
# wins. The file is consumed: a reused machine's next job must not re-install a
# ladder the worker has since told this machine is gone.
#
# The role list is MODEL_ROUTE_BUILD_ROLES, in the resolver, so the dispatcher
# bundles exactly what this warms.
model_routes_warm() {
  [ -r "$HARNESS/bin/lib/model-route.sh" ] || { log "model routes: bin/lib/model-route.sh not on this machine — nothing warmed"; return 0; }
  local out bundle="$ENVDIR/model-routes.tsv"
  # One short try per role, no transport retry: a worker that is down answers
  # every role the same way, and the job should not wait twelve timeouts on it.
  out=$( export HARNESS="$HARNESS" JOBS_TIMEOUT="${MODEL_ROUTES_WARM_TIMEOUT_S:-5}" JOBS_RETRIES=0
    # shellcheck source=/dev/null
    . "$HARNESS/bin/lib/model-route.sh"
    b=""
    [ -s "$bundle" ] && b="$(model_routes_bundle_install "$bundle" "$PROJECT") from the dispatcher's bundle; "
    n=0; miss=""
    for r in $MODEL_ROUTE_BUILD_ROLES; do
      if model_ladder "$r" "$PROJECT" >/dev/null 2>&1; then n=$((n+1)); else miss="$miss $r"; fi
    done
    printf '%s%s resolved%s' "$b" "$n" "${miss:+; no route or cache for:$miss}" )
  rm -f "$bundle" 2>/dev/null
  log "model routes: $out"
  return 0
}

# --- fly_result: the RESULT as a row, so the hub can skip sftp (BH-2625) ----
# fly_result_put <build-dir> <key>, called right after $RESULT_FILE is written.
# ONE `fly_result` artifact on the build's job: ref = RESULT line 1 verbatim,
# detail = {key, build_dir, result, pipeline_tail, evidence, truncated}.
# bin/fly-results-ingest.sh reads it before it reaches for flyctl.
#
# THE FILE IS THE TRUTH, THE ROW IS A SHORTCUT. It is written after the file, and
# no job id or a failed PUT is one log line: the hub then pulls over sftp as it
# always has. Always returns 0.
#
# THE CAP IS THE WORKER'S: detail is sliced to 4000 JS chars
# (worker/jobs/src/routes/job-artifacts.js), and UTF-8 bytes are never fewer
# than UTF-16 units, so 4000 bytes can never be cut there. pipeline_tail is
# every `] GATES ` line plus the last N lines, N the first of 80 40 20 10 5 0
# that fits: a tail is the design, not truncation. truncated:true means the
# GATES line or the evidence did not fit, and the hub then refuses the row.
fly_result_put() {
  local bdir="$1" key="${2:-}" job rline detail="" n tl evf plog
  evf="$bdir/evidence.md"; plog="$bdir/pipeline.log"
  [ -s "$RESULT_FILE" ] || return 0
  job=$(jq -r '.job_id // ""' "$bdir/job.json" 2>/dev/null)
  [ -n "$job" ] || { log "fly_result: no job id in $bdir/job.json, not recorded (hub pulls over sftp)"; return 0; }
  rline=$(head -1 "$RESULT_FILE")
  [ -f "$evf" ] || evf=/dev/null
  # _fr_detail <tail> <evidence-file> <truncated> -> the detail json, or "" when over the cap
  _fr_detail() {
    local d
    d=$(jq -nc --arg key "$key" --arg build_dir "$(basename "$bdir")" --rawfile result "$RESULT_FILE" \
          --arg pipeline_tail "$1" --rawfile evidence "$2" --argjson truncated "$3" \
          '{key:$key,build_dir:$build_dir,result:$result,pipeline_tail:$pipeline_tail,evidence:$evidence,truncated:$truncated}' 2>/dev/null) || return 0
    [ "$(printf '%s' "$d" | LC_ALL=C wc -c)" -le 4000 ] && printf '%s' "$d"
  }
  for n in 80 40 20 10 5 0; do
    tl=""
    [ -f "$plog" ] && tl=$(awk -v n="$n" 'NR==FNR{t=NR;next} /\] GATES / || FNR>t-n' "$plog" "$plog")
    detail=$(_fr_detail "$tl" "$evf" false)
    [ -n "$detail" ] && break
  done
  [ -n "$detail" ] || detail=$(_fr_detail "" "$evf" true)
  [ -n "$detail" ] || detail=$(_fr_detail "" /dev/null true)
  [ -n "$detail" ] || { log "fly_result: RESULT alone is over the 4000-byte cap for job $job, not recorded (hub pulls over sftp)"; return 0; }
  if timeout 30 "$HARNESS/bin/jobs-client.sh" artifact-put fly_result "$rline" "$detail" "$job" >/dev/null 2>&1; then
    log "fly_result: recorded on job $job"
  else
    log "fly_result: PUT failed for job $job (hub pulls over sftp)"
  fi
  return 0
}

load_env() {
  # BH-5025: the bundle's GH_TOKEN= dies an hour after spawn; the rotated file beside it does not.
  if [ -r "$HARNESS/bin/lib/gh-token-live.sh" ] && . "$HARNESS/bin/lib/gh-token-live.sh" 2>/dev/null \
     && command -v gh_token_live_sync_env >/dev/null 2>&1; then
    gh_token_live_sync_env "$ENVDIR/global.env" >/dev/null 2>&1 \
      && log "load_env: GH_TOKEN in global.env synced from the rotated token file"
  fi
  set -a
  [ -f "$ENVDIR/global.env" ]      && . "$ENVDIR/global.env"
  [ -f "$ENVDIR/$PROJECT.env" ]    && . "$ENVDIR/$PROJECT.env"
  set +a
  # git plumbing (2026-07-31 e2e finding): plain git has no credential helper on
  # a fresh builder — wire gh (which honors $GH_TOKEN) and the fleet identity so
  # run-build's pull/commit/push work exactly as on a watcher box.
  if [ -n "${GH_TOKEN:-}" ]; then
    gh auth setup-git >/dev/null 2>&1 || true
    # BH-4080: the fallback identity is the deployment defaults home's, on the
    # synced volume like every other lib this runner reads.
    # shellcheck source=bin/lib/deployment.sh
    . "${HARNESS_DEPLOYMENT_FILE-$HARNESS/bin/lib/deployment.sh}" 2>/dev/null \
      || echo "builder-runner: no $HARNESS/bin/lib/deployment.sh — a missing git identity stays unset" >&2
    [ -z "${HARNESS_GIT_NAME:-}" ]  || git config --global user.name  >/dev/null 2>&1 || git config --global user.name  "$HARNESS_GIT_NAME"
    [ -z "${HARNESS_GIT_EMAIL:-}" ] || git config --global user.email >/dev/null 2>&1 || git config --global user.email "$HARNESS_GIT_EMAIL"
  fi
  live_git_credentials
}

# THE TOKEN GIT USES IS READ AT CALL TIME (2026-09-14, TK-680/681/682). `gh auth
# setup-git`'s helper answers with the GH_TOKEN this process started with, and a
# GitHub App installation token dies in an hour while a pool build runs 40-75
# minutes — so the pre-PR push of three finished builds answered "Invalid username
# or token" and all three were thrown away. fly/gh-credential.sh reads
# /run/harness-env/gh-token on every credential request instead, which is the file
# bin/fly-pool.sh rotates under a live build.
#
# THE GATE IS THE FILE ITSELF: bin/fly-pool.sh writes it only when App tokens are
# armed, so with GH_APP_TOKENS=0 or flags/gh-app-tokens-off there is nothing here
# and git keeps exactly the helper it has today. The fallback inside the helper is
# $GH_TOKEN, so even a machine whose file goes missing mid-build pushes with what
# the bundle gave it.
#
# CALLED AFTER EVERY `gh auth setup-git`, not once: that command REPLACES this key,
# so warm_up's clone paths would quietly hand the static helper back for the rest
# of the build if this only ran in load_env.
live_git_credentials() {
  [ -s "$ENVDIR/gh-token" ] && [ -f "$HARNESS/fly/gh-credential.sh" ] || return 0
  chmod +x "$HARNESS/fly/gh-credential.sh" 2>/dev/null || true
  git config --global --replace-all credential.https://github.com.helper \
    "!$HARNESS/fly/gh-credential.sh" >/dev/null 2>&1 || true
  # BH-5910: the helper picks the read-only token by repo path, and git sends
  # the path only with useHttpPath. No read file, no change.
  if [ -s "$ENVDIR/gh-token-read" ]; then
    git config --global credential.https://github.com.useHttpPath true >/dev/null 2>&1 || true
  fi
  return 0
}

# --- 1. wait for the first pushed job ----------------------------------------
# >>> warmup wait (BH-7215)
log "waiting up to ${WARMUP_WAIT}s for hub to push env + job"
waited=0
while [ ! -f "$JOB" ]; do
  if [ "$waited" -ge "$WARMUP_WAIT" ]; then
    log "no job pushed within ${WARMUP_WAIT}s — exiting 0 (machine autostops)"
    rm -f "$ENVDIR"/*.env 2>/dev/null || true
    exit 0
  fi
  sleep "$POLL"; waited=$((waited + POLL))
done
# <<< warmup wait

# Started here and not before: the hub pushes the env bundle and job.json
# together, and a pusher that runs before global.env lands has no
# HARNESS_SECRET to authenticate with. From this point the loop covers every
# job this machine goes on to serve, reuse included.
#
# The traps are the crash path. An EXIT trap catches the idle-timeout exit and
# any abnormal end of this script; TERM/INT are trapped so a `fly machine stop`
# or a kill runs the same final flush instead of dying with the rows unsent.
# Nothing here can be reached by SIGKILL, and that case is exactly what the
# hub's reap push (bin/fly-pool.sh) exists to cover.
# `trap - EXIT` first on the signal paths: `exit` from a TERM/INT handler runs
# the EXIT trap too, and a second flush during a `fly machine stop` spends the
# shutdown grace period taking the lock for a push that has nothing left to send.
# Exactly one flush per death, and SIGKILL after the grace period is the hub
# reap's job either way.
trap 'cost_rows_flush' EXIT
trap 'trap - EXIT; cost_rows_flush; exit 143' TERM
trap 'trap - EXIT; cost_rows_flush; exit 130' INT
start_cost_rows_loop

# --- repo slug resolution (no hardcoded owner) -------------------------------
resolve_slug() {
  # 1) fleet.conf on the volume (synced): "<project> <slug> ..."
  local s
  if [ -f "$HARNESS/fleet.conf" ]; then
    s=$(awk -v p="$PROJECT" '$1==p {print $2; exit}' "$HARNESS/fleet.conf")
    [ -n "$s" ] && [ "$s" != "-" ] && { echo "$s"; return 0; }
  fi
  # 2) REPO_SLUG from the pushed project env
  [ -n "${REPO_SLUG:-}" ] && { echo "$REPO_SLUG"; return 0; }
  return 1
}

# --- 2. first-boot warm-up ----------------------------------------------------
warm_up() {
  local slug cold=0 seeded=0 t0 t1 base wt
  load_env
  base="${BASE_BRANCH:-main}"
  # Baked warm checkout (build speed pass 2, 2026-08-13): the image carries a
  # <=24h-stale checkout + node_modules + build caches at /opt/warm/repo (see
  # fly/Dockerfile). Seed /data/repos from it and do an incremental
  # fetch+install instead of the ~5 min cold clone+install. Any failure falls
  # through to the cold path below — the baked copy is pure cache.
  if [ ! -e "$REPO/.git" ] && [ -e /opt/warm/repo/.git ]; then
    t0=$(date +%s)
    log "seeding $REPO from baked /opt/warm/repo"
    mkdir -p /data/repos
    gh auth setup-git 2>/dev/null || true; live_git_credentials
    rm -rf "$REPO.warmtmp"
    # hardlink copy when same filesystem (instant on volume-less pool machines),
    # full copy across devices (volume builders).
    if cp -al /opt/warm/repo "$REPO.warmtmp" 2>/dev/null \
       || { rm -rf "$REPO.warmtmp"; cp -a /opt/warm/repo "$REPO.warmtmp"; }; then
      mv "$REPO.warmtmp" "$REPO"
      if ( cd "$REPO" \
           && git fetch --quiet origin "$base" \
           && git checkout --quiet -B "$base" FETCH_HEAD ); then
        ( cd "$REPO"
          # NOTE: no PNPM_STORE_DIR here — the baked node_modules were linked
          # against the image's default store; pointing pnpm at a different
          # store would force a full relink and erase the warmth.
          if [ -f pnpm-lock.yaml ]; then
            corepack pnpm install --frozen-lockfile || corepack pnpm install || true
          else
            npm install || true
          fi
          if command -v codegraph >/dev/null 2>&1; then
            codegraph telemetry off >/dev/null 2>&1 || true
            [ -d .codegraph ] || codegraph init >/dev/null 2>&1 || true
          fi )
        seeded=1
        t1=$(date +%s)
        log "warm seed ready in $((t1 - t0))s (incremental install; baked build cache: $([ -f "$REPO/.warm-build-failed" ] && echo absent || echo present))"
      else
        log "baked checkout unusable (fetch/checkout failed) — falling back to cold clone"
        rm -rf "$REPO"
      fi
    else
      rm -rf "$REPO.warmtmp"
      log "warm copy failed — falling back to cold clone"
    fi
  fi
  if [ ! -e "$REPO/.git" ]; then
    cold=1
    slug=$(resolve_slug) || { log "cannot resolve repo slug for $PROJECT"; return 1; }
    log "cold start: cloning $slug -> $REPO"
    t0=$(date +%s)
    mkdir -p /data/repos
    # GH_TOKEN from the env bundle authenticates gh; set up git credential helper.
    gh auth setup-git 2>/dev/null || true; live_git_credentials
    gh repo clone "$slug" "$REPO" -- --quiet || { log "clone failed"; return 1; }
    # dependency install: pnpm store on the volume, npm fallback for non-pnpm repos
    ( cd "$REPO"
      export PNPM_STORE_DIR=/data/pnpm-store
      if [ -f pnpm-lock.yaml ]; then
        log "pnpm install (store=/data/pnpm-store)"
        corepack pnpm install --frozen-lockfile || corepack pnpm install || true
      else
        log "npm install"
        npm install || true
      fi
      if command -v codegraph >/dev/null 2>&1; then
        codegraph telemetry off >/dev/null 2>&1 || true
        [ -d .codegraph ] || codegraph init >/dev/null 2>&1 || true
      fi
    )
    t1=$(date +%s)
    log "warm-up complete (cold clone+install ${t1}-${t0}=$((t1 - t0))s)"
  elif [ "$seeded" = 0 ]; then
    log "warm repo present at $REPO ($(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)) — skipping clone"
  fi
  # Pre-seed the slot-1 worktree: run-build.sh installs and builds INSIDE
  # /data/worktrees/<project>-slot1 (pool machines are single-slot) and reuses
  # the dir when it already exists — so the warmth must reach the worktree, not
  # just the repo. Hardlink node_modules + .next/cache in before the pipeline
  # ever runs; run-build's `git clean -fd -e node_modules -e .next` keeps them.
  wt="/data/worktrees/$PROJECT-slot1"
  if [ ! -d "$wt" ] && [ -d "$REPO/node_modules" ]; then
    if git -C "$REPO" worktree add --detach "$wt" "$base" >/dev/null 2>&1; then
      log "pre-seeding worktree $wt with node_modules + .next/cache"
      cp -al "$REPO/node_modules" "$wt/node_modules" 2>/dev/null \
        || cp -a "$REPO/node_modules" "$wt/node_modules" 2>/dev/null || true
      if [ -d "$REPO/.next/cache" ]; then
        mkdir -p "$wt/.next"
        cp -al "$REPO/.next/cache" "$wt/.next/cache" 2>/dev/null \
          || cp -a "$REPO/.next/cache" "$wt/.next/cache" 2>/dev/null || true
      fi
    fi
  fi
  if [ "$seeded" = 1 ]; then WARM_STATE=seeded
  elif [ "$cold" -eq 1 ]; then WARM_STATE=cold
  else WARM_STATE=warm; fi
  return 0
}

# --- heartbeat (background) ---------------------------------------------------
start_heartbeat() {
  ( while true; do : > "$HEARTBEAT"; sleep 60; done ) &
  HB_PID=$!
}
stop_heartbeat() { [ -n "${HB_PID:-}" ] && kill "$HB_PID" 2>/dev/null || true; }

# --- run one job --------------------------------------------------------------
# run_job is the wrapper; _run_job is the job. EVERY terminal path of a job —
# RESULT written, BUILD_DEFERRED from warm-up or the disk guard, a malformed
# job.json, an adopted PR, SMOKE — returns through here, so the flush is one
# line instead of six easily-forgotten ones, and it lands BEFORE the loop idles
# and before anything else reads /run/harness/RESULT.
run_job() {
  _run_job; local rc=$?
  # Guarded: tests/pool-cost-rows-test.sh lifts this wrapper out on its own.
  command -v pool_result_row_write >/dev/null 2>&1 && pool_result_row_write
  cost_rows_flush
  return "$rc"
}

# --- the result, off the machine (BH-2643) -------------------------------------
# /run/harness/RESULT is tmpfs. After the idle window below this machine
# autostops and the RESULT goes with it, and a hub reap that arrives late then
# finds only a `stopped` machine it cannot ssh into, which it used to count as a
# death. The row is the copy that survives (bin/lib/pool-result-row.sh). Pool
# machines only; never an RB- rebase or RR- re-review (each dead path is its
# own, BH-542, BH-7635). An
# older synced tree without the lib writes nothing, and a failed write is one
# log line, never a job failure.
pool_result_row_write() {
  [ "${POOL_MODE:-}" = 1 ] || return 0
  local key
  key=$(jq -r '.key // ""' "$JOB" 2>/dev/null)
  case "$key" in ''|RB-*|RR-*) return 0 ;; esac
  # shellcheck source=bin/lib/pool-result-row.sh
  . "$HARNESS/bin/lib/pool-result-row.sh" 2>/dev/null || return 0
  command -v pool_result_row_put >/dev/null 2>&1 || return 0
  ( export HARNESS="$HARNESS"
    pool_result_row_put "$PROJECT" "$key" "${FLY_MACHINE_ID:-}" "$RESULT_FILE" ) \
    || log "pool-result row for $key not written — the hub reap falls back to ssh"
  return 0
}

# >>> run_job
# --- a POOL REBASE job (BH-486) ------------------------------------------------
# Not a build: no run-build.sh, no PR-adopt preflight, no preplan, no disk guard
# beyond the warm-up. The hub read a head, leased it, and wants the branch merged
# with its base and pushed back. bin/lib/rebase-job.sh is the whole body; this
# function only finds it, hands it the job, and beats the answer.
#
# WARM-UP FAILURE IS REBASE_SETUP_FAILED, NOT BUILD_DEFERRED. Nothing re-offers a
# rebase job — the hub reads the word and fails the job — so a deferred-looking
# RESULT would park the PR on a word no rebase reader handles.
rebase_setup_result() { # rebase_setup_result <why> <url> <head> <branch> <base>
  local why="$1" url="${2:-}" head="${3:-}" br="${4:-}" base="${5:-}"
  [ -n "$url" ] || url="-"
  printf 'REBASE_SETUP_FAILED %s\nPR: %s\nHEAD: %s\nBRANCH: %s\nBASE: %s\nGATE: typecheck=skipped unit=skipped\n' \
    "$why" "$url" "$head" "$br" "$base" > "$RESULT_FILE"
  log "rebase job setup failed: $why"
}

run_rebase_job() { # run_rebase_job <job key>
  local key="$1" slug branch head base url rc lib="$HARNESS/bin/lib/rebase-job.sh"
  slug=$(jq -r   '.rebase.slug   // ""'     "$JOB" 2>/dev/null)
  branch=$(jq -r '.rebase.branch // ""'     "$JOB" 2>/dev/null)
  head=$(jq -r   '.rebase.head   // ""'     "$JOB" 2>/dev/null)
  base=$(jq -r   '.rebase.base   // "main"' "$JOB" 2>/dev/null)
  url=$(jq -r    '.rebase.url    // ""'     "$JOB" 2>/dev/null)
  [ -n "$base" ] || base=main
  log "rebase job key=$key $slug $branch onto $base (leased head ${head:0:8})"
  # warm_up is what puts the repo (and node_modules, hence the gates) on disk.
  warm_up || { rebase_setup_result "warm-up failed" "$url" "$head" "$branch" "$base"; return 1; }
  if [ ! -r "$lib" ]; then
    rebase_setup_result "no rebase lib at $lib" "$url" "$head" "$branch" "$base"; return 1
  fi
  # shellcheck source=bin/lib/rebase-job.sh
  . "$lib"
  if ! type rebase_job_run >/dev/null 2>&1; then
    rebase_setup_result "no rebase lib at $lib" "$url" "$head" "$branch" "$base"; return 1
  fi
  REBASE_JOB_URL="$url" rebase_job_run "$REPO" "$slug" "$branch" "$head" "$base" \
    "$RESULT_FILE" "$HARNESS"
  rc=$?
  log "rebase job done: $(head -1 "$RESULT_FILE" 2>/dev/null)"
  beat "$(jq -nc --arg p "$PROJECT" --arg k "$key" --arg r "$(head -1 "$RESULT_FILE" 2>/dev/null)" --arg u "$url" \
    '{kind:"build",project:$p,ticket_key:$k,stage:"rebase_done",detail:$r,pr_url:$u,host:("builder-"+$p)}')"
  return "$rc"
}

# --- a POOL RE-REVIEW job (BH-7635) --------------------------------------------
# Not a build either: the conductor's head-bound re-review of one PR at one head,
# as an `RR-<pr>-<head8>` row. (The producer, a lane-run machine that cannot run
# the re-review detached, is BH-7635 slice C2; no row is queued before it.) bin/lib/rereview-job.sh
# is the whole body; it writes one REREVIEW* RESULT and nothing to GitHub. A
# setup failure is REREVIEW_SETUP_FAILED, never BUILD_DEFERRED: nothing re-offers
# this row, and the hub reap reads the word into a lane-failed job file.
rereview_setup_result() { # rereview_setup_result <why> <url> <head>
  printf 'REREVIEW_SETUP_FAILED %s\nPR: %s\nHEAD: %s\n' "$1" "${2:--}" "${3:--}" > "$RESULT_FILE"
  log "rereview job setup failed: $1"
}

run_rereview_job() { # run_rereview_job <job key>
  local key="$1" slug num url rev head reason rc lib="$HARNESS/bin/lib/rereview-job.sh"
  slug=$(jq -r   '.rereview.slug     // ""'  "$JOB" 2>/dev/null)
  num=$(jq -r    '.rereview.pr       // ""'  "$JOB" 2>/dev/null)
  url=$(jq -r    '.rereview.url      // ""'  "$JOB" 2>/dev/null)
  rev=$(jq -r    '.rereview.reviewed // "-"' "$JOB" 2>/dev/null)
  head=$(jq -r   '.rereview.head     // ""'  "$JOB" 2>/dev/null)
  reason=$(jq -r '.rereview.reason   // ""'  "$JOB" 2>/dev/null)
  log "rereview job key=$key $slug#$num at ${head:0:8} (reason ${reason:-none})"
  warm_up || { rereview_setup_result "warm-up failed" "$url" "$head"; return 1; }
  if [ ! -r "$lib" ]; then rereview_setup_result "no rereview lib at $lib" "$url" "$head"; return 1; fi
  # shellcheck source=bin/lib/rereview-job.sh
  . "$lib"
  if ! type rereview_job_run >/dev/null 2>&1; then
    rereview_setup_result "no rereview lib at $lib" "$url" "$head"; return 1
  fi
  rereview_job_run "$slug" "$num" "$PROJECT" "$url" "$rev" "$head" "$reason" "$RESULT_FILE" "$HARNESS"
  rc=$?
  log "rereview job done: $(head -1 "$RESULT_FILE" 2>/dev/null)"
  beat "$(jq -nc --arg p "$PROJECT" --arg k "$key" --arg r "$(head -1 "$RESULT_FILE" 2>/dev/null)" --arg u "$url" \
    '{kind:"build",project:$p,ticket_key:$k,stage:"rereview_done",detail:$r,pr_url:$u,host:("builder-"+$p)}')"
  return "$rc"
}

# --- slot preflight (BH-5021) --------------------------------------------------
# A pool machine runs one job at a time, so between jobs nothing may hold a
# build slot. Something did on BH-4973's three reused machines (a stray from the
# previous build that inherited fd 8), and every build there paid warm-up and
# the gh reads before run-build's own slot gate refused it. So the slot is
# checked HERE, before warm_up: bin/pool-slot-clean.sh kills a stray holder and
# answers one SLOTCLEAN line. Still held -> a plain build defers at once, with
# wording the hub reap reads as "this machine is dirty" (it destroys the machine
# and does not count the deferral against the ticket). A hotfix goes on to
# run-build, whose slot gate gives it the one extra slot. An older tree without
# the cleaner, or an unreadable answer, proceeds exactly as before.
slot_preflight() { # slot_preflight <key> <hotfix 1|""> -> 0 go on, 1 deferred (RESULT written)
  local key="$1" hotfix="${2:-}" cl="$HARNESS/bin/pool-slot-clean.sh" out rc=0
  if [ ! -x "$cl" ]; then log "slot preflight: cleaner absent"; return 0; fi
  out=$("$cl" --harness "$HARNESS" 2>/dev/null) || rc=$?
  log "slot preflight: ${out:-no answer} (rc=$rc)"
  [ "$rc" = 1 ] || return 0
  if [ -n "$hotfix" ]; then
    log "slot preflight: a slot is still held, but $key is a hotfix — run-build takes the extra slot"
    return 0
  fi
  echo "BUILD_DEFERRED all 1 slots busy — slot held on this machine by ${out#SLOTCLEAN held } after cleanup" > "$RESULT_FILE"
  beat "$(jq -nc --arg p "$PROJECT" --arg k "$key" --arg r "$(head -1 "$RESULT_FILE")" '{kind:"build",project:$p,ticket_key:$k,stage:"builder_done",detail:$r,host:("builder-"+$p)}')"
  stop_heartbeat
  return 1
}

_run_job() {
  local ticket key attempt
  ticket=$(jq -r '.ticket_id // ""' "$JOB" 2>/dev/null)
  key=$(jq -r '.key // ""'         "$JOB" 2>/dev/null)
  attempt=$(jq -r '.attempt // 0'  "$JOB" 2>/dev/null)
  [ -n "$key" ] || { log "job.json missing key"; echo "BUILD_ERROR malformed job.json" > "$RESULT_FILE"; return 1; }
  LAST_KEY="$key"   # the idle loop detects pool reuse by key change

  load_env
  model_routes_warm
  rm -f "$RESULT_FILE"
  start_heartbeat
  log "job start key=$key ticket=$ticket attempt=$attempt"
  beat "$(jq -nc --arg p "$PROJECT" --arg k "$key" '{kind:"build",project:$p,ticket_key:$k,stage:"builder_start",host:("builder-"+$p)}')"

  # --- SMOKE health probe (plan Phase-1 verify): no repo/board needed ---------
  if [ "$key" = "SMOKE" ]; then
    log "SMOKE job: probing the claude credential (no inference)"
    # BH-2559: a free credential GET through cred_probe, never a model call.
    # Auth is what SMOKE verifies; a probe spends no tokens and writes no cost
    # row. No harness on the volume yet is a failed smoke, not a bare CLI call.
    local cls lib="${CRED_PROBE_LIB:-$HARNESS/bin/lib/cred-probe.sh}"
    if [ ! -r "$lib" ]; then
      echo "SMOKE_FAIL harness not synced" > "$RESULT_FILE"
    else
      cls=$( export HARNESS; . "$lib" && cred_probe claude 2>/dev/null )
      case "$cls" in
        ALIVE*) echo "SMOKE_OK claude credential alive host=builder-$PROJECT" > "$RESULT_FILE" ;;
        *)      echo "SMOKE_FAIL ${cls:-no probe answer}" > "$RESULT_FILE" ;;
      esac
    fi
    beat "$(jq -nc --arg p "$PROJECT" --arg k "$key" --arg r "$(head -1 "$RESULT_FILE")" '{kind:"build",project:$p,ticket_key:$k,stage:"builder_done",detail:$r,host:("builder-"+$p)}')"
    stop_heartbeat
    return 0
  fi

  # --- pool REBASE job: a different job entirely, and it ends here ------------
  if [ "$(jq -r '.rebase.kind // ""' "$JOB" 2>/dev/null)" = rebase ]; then
    local rrc
    run_rebase_job "$key"; rrc=$?
    stop_heartbeat
    return "$rrc"
  fi
  # --- pool RE-REVIEW job (BH-7635): a conductor read, never a build ----------
  if [ "$(jq -r '.rereview.kind // ""' "$JOB" 2>/dev/null)" = rereview ]; then
    local rrrc
    run_rereview_job "$key"; rrrc=$?
    stop_heartbeat
    return "$rrrc"
  fi

  # HOTFIX (#368): the watcher read the label off the issue and put the answer
  # on the job, so the machine does not ask GitHub a second time — and cannot
  # get a different answer than the watcher did. Empty is today's invocation,
  # variable for variable. Read here, before the slot preflight, which lets a
  # hotfix through to the extra slot (BH-5021).
  local hotfix=""
  [ "$(jq -r '.hotfix // false' "$JOB" 2>/dev/null)" = true ] && hotfix=1

  # --- a held build slot refuses before anything is spent (BH-5021) ----------
  slot_preflight "$key" "$hotfix" || return 1

  # --- warm-up (clone/install) for real builds --------------------------------
  warm_up || { echo "BUILD_DEFERRED warm-up failed" > "$RESULT_FILE"; stop_heartbeat; return 1; }

  # --- disk guard (plan Failure-modes: >90% -> defer) -------------------------
  local usepct
  usepct=$(df --output=pcent /data 2>/dev/null | tr -dc '0-9' )
  if [ -n "$usepct" ] && [ "$usepct" -ge 90 ]; then
    log "disk ${usepct}% on /data — deferring"
    echo "BUILD_DEFERRED disk ${usepct}% used on /data" > "$RESULT_FILE"
    beat "$(jq -nc --arg p "$PROJECT" --arg k "$key" '{kind:"fleet_alert",project:$p,ticket_key:$k,detail:"builder disk >90%",host:("builder-"+$p)}')"
    stop_heartbeat; return 1
  fi

  # --- PR-adopt preflight: retry of a build that already opened its PR ---------
  local branch open_pr
  branch="ticket/$(echo "$key" | tr '[:upper:]' '[:lower:]')"
  if [ "$attempt" -gt 0 ]; then
    open_pr=$( cd "$REPO" && gh pr list --head "$branch" --state open --json url -q '.[0].url' 2>/dev/null )
    if [ -n "$open_pr" ]; then
      log "adopting existing open PR $open_pr for $branch (retry)"
      echo "PR_CREATED $open_pr (adopted on retry)" > "$RESULT_FILE"
      beat "$(jq -nc --arg p "$PROJECT" --arg k "$key" --arg u "$open_pr" '{kind:"build",project:$p,ticket_key:$k,stage:"pr_adopted",pr_url:$u,host:("builder-"+$p)}')"
      stop_heartbeat; return 0
    fi
  fi

  # --- run the real pipeline: no merge, no board writes -----------------------
  # Review-fix adoption (TK-700, 2026-08-15): if an OPEN PR's title carries this
  # exact ticket key, new work for the key belongs on that PR's head, whatever
  # the branch is named — a fix pushed to a fresh ticket/<key> branch strands
  # with no PR (this happened twice: TK-662 R2, TK-700 R2).
  local adopt_head
  adopt_head=$( cd "$REPO" && gh pr list --state open --limit 50 --json headRefName,title 2>/dev/null | jq -r --arg k "$key" '[.[]|select(.title|test("(^|[^A-Za-z0-9-])" + $k + "([^0-9]|$)"))][0].headRefName // empty' )
  if [ -n "$adopt_head" ]; then
    log "open PR titled with $key found — building on its head $adopt_head (continue-mode)"
  else
    # A requeue after a push rejected on a diverged remote (BH-6821) starts
    # from the remote head. An open PR's head above still wins.
    local continue_branch
    continue_branch=$(jq -r '.continue_branch // ""' "$JOB" 2>/dev/null)
    case "$continue_branch" in *[!A-Za-z0-9._/-]*) continue_branch="" ;; esac
    if [ -n "$continue_branch" ]; then
      log "job carries continue_branch=$continue_branch — building on the remote head (continue-mode)"
      adopt_head="$continue_branch"
    fi
  fi
  # Machine rules for the claude CLI: boxes render ~/.claude/CLAUDE.md via
  # update-runners; builders only got them via the context-gate's one-shot
  # self-heal. Copy explicitly per job — and RTK.md beside it, so the rules'
  # @RTK.md include resolves (rtk ships in the image since 2026-08-23).
  mkdir -p /root/.claude
  [ -f "$HARNESS/rules/CLAUDE.md" ] && cp "$HARNESS/rules/CLAUDE.md" /root/.claude/CLAUDE.md
  [ -f "$HARNESS/rules/RTK.md" ] && cp "$HARNESS/rules/RTK.md" /root/.claude/RTK.md
  # settings.json too (repo-managed since 2026-08-23): the image bakes a boot
  # default, but the synced repo copy wins so hook changes reach builders on
  # the next job, not the next image build.
  [ -f "$HARNESS/rules/settings.json" ] && cp "$HARNESS/rules/settings.json" /root/.claude/settings.json
  # BH-3689: the canon points the secret-read guard at /root/harness/bin; here
  # the harness is $HARNESS, so repoint it or the hook is exit 127 (ignored).
  # --no-backup: the file is a fresh copy of canon, so a .bak per job is debris.
  [ -x "$HARNESS/bin/secret-read-guard-install.sh" ] && "$HARNESS/bin/secret-read-guard-install.sh" --settings /root/.claude/settings.json --no-backup >/dev/null 2>&1
  # STACKED CHILD BUILDS (2026-09-14): the job carries the parent PR's branch
  # when the watcher decided this ticket is buildable on top of an open parent.
  # run-build.sh validates it (and falls back to the project base if the branch
  # has since been deleted), so an empty value is exactly today's invocation.
  local stack_base
  stack_base=$(jq -r '.stack_base // ""' "$JOB" 2>/dev/null)
  [ -n "$stack_base" ] && log "job carries STACK_BASE=$stack_base — building on top of the parent's branch"
  # The line says what THIS script did. What run-build.sh then does with the
  # variable — skip the WIP cap by one, label the PR, open its body with
  # `HOTFIX:`, announce pr_open — is BH-417's half and reads `HOTFIX=1`; a box
  # whose harness predates it simply ignores the variable.
  [ -n "$hotfix" ] && log "job is a HOTFIX — passing HOTFIX=1 to run-build.sh"
  log "invoking run-build.sh (BUILDER_EXEC=1 BUILDER_NO_MERGE=1)"
  BUILDER_EXEC=1 BUILDER_NO_MERGE=1 HARNESS_CHECKOUT="$HARNESS" TARGET_BRANCH="$adopt_head" STACK_BASE="$stack_base" HOTFIX="$hotfix" "$HARNESS/bin/run-build.sh" "$PROJECT" "$ticket" "$key"

  # --- assemble RESULT from the newest matching BUILD dir ---------------------
  local bdir rline pr_url parent_pr tier
  # >>> result assemble
  # THE FIRST URL ON THE RECORD IS NOT THE RECORD'S PR (BH-848). This used to be
  # `grep -oE '…/pull/[0-9]+' RESULT | head -1`, and when `gh pr create` died on
  # the App GraphQL cap the ratchet's failed line carried the notes — which for a
  # stacked child read `STACKED on ticket/bh-776 (…/pull/803)`, the PARENT's PR.
  # So the pool record was published as `PR: …/pull/803` and the merge sweep went
  # and evaluated somebody else's PR. bin/lib/result-pr-url.sh answers the two
  # questions separately; the parent is recorded, under its own key, where no
  # link-hunting reader will mistake it for this build's.
  bdir=$(ls -1dt "$HARNESS/builds/$PROJECT-$key-"* 2>/dev/null | head -1)
  if [ -n "$bdir" ] && [ -f "$bdir/RESULT" ]; then
    rline=$(head -1 "$bdir/RESULT")
    if command -v result_own_pr_url >/dev/null 2>&1; then
      pr_url=$(result_own_pr_url "$bdir/RESULT" || true)
      parent_pr=$(result_parent_pr_url "$bdir/RESULT" || true)
    else
      # Older tree, lib not propagated yet: byte for byte what this did before.
      pr_url=$(grep -oE 'https://github.com/[^ ]+/pull/[0-9]+' "$bdir/RESULT" | head -1)
      parent_pr=""
    fi
    tier=$(tail -2 "$bdir/review.md" 2>/dev/null | grep -oE 'TIER: [12]' | head -1 | grep -oE '[12]')
    {
      echo "$rline"
      [ -n "$tier" ] && echo "TIER: $tier"
      [ -n "$pr_url" ] && echo "PR: $pr_url"
      [ -n "$parent_pr" ] && echo "PARENT_PR: $parent_pr"
      echo "BUILD_DIR: $(basename "$bdir")"
      echo "WARM: ${WARM_STATE:-unknown}"
      for a in plan.md review.md security-review.md qa.md pipeline.log; do
        [ -f "$bdir/$a" ] && echo "ARTIFACT: $bdir/$a"
      done
    } > "$RESULT_FILE"
    fly_result_put "$bdir" "$key"
  else
    echo "BUILD_ERROR no build dir/RESULT produced for $key" > "$RESULT_FILE"
  fi
  # <<< result assemble

  log "job done: $(head -1 "$RESULT_FILE")"
  beat "$(jq -nc --arg p "$PROJECT" --arg k "$key" --arg r "$(head -1 "$RESULT_FILE")" --arg u "${pr_url:-}" \
    '{kind:"build",project:$p,ticket_key:$k,stage:"builder_done",detail:$r,pr_url:$u,host:("builder-"+$p)}')"
  stop_heartbeat
  return 0
}
# <<< run_job

# --- main loop ----------------------------------------------------------------
while true; do
  run_job || log "run_job returned nonzero (RESULT written)"

  # job consumed; wait for the hub to pull RESULT and push the next job.
  # Two push styles land here:
  #   - dispatcher (persistent builders): removes job.json after claiming the
  #     RESULT, then pushes a fresh one — detected by mtime change.
  #   - pool reuse (fly-pool.sh REAP, 2026-08-13): clears RESULT and overwrites
  #     job.json with a DIFFERENT key (tmp+mv) — detected by key change even if
  #     the overwrite raced our mtime capture below.
  # No new job within IDLE_TIMEOUT (10 min) => clear secrets and exit 0. That
  # stops the machine (tini reaps us as PID 1's child); a stopped pool machine
  # is then destroyed by fly-pool.sh's dead-machine sweep, so an idle machine
  # never bills compute past the 10-minute window.
  log "job cycle complete; idling up to ${IDLE_TIMEOUT}s for next push"
  prev_mtime=$(stat -c %Y "$JOB" 2>/dev/null || echo 0)
  idle=0
  while true; do
    sleep "$POLL"; idle=$((idle + POLL))
    cur_mtime=$(stat -c %Y "$JOB" 2>/dev/null || echo 0)
    cur_key=$(jq -r '.key // ""' "$JOB" 2>/dev/null)
    if [ -f "$JOB" ] && [ -n "$cur_key" ] \
       && { [ "$cur_mtime" != "$prev_mtime" ] || [ "$cur_key" != "${LAST_KEY:-}" ]; }; then
      log "new job detected (key=$cur_key) — processing"
      break
    fi
    if [ "$idle" -ge "$IDLE_TIMEOUT" ]; then
      log "idle ${IDLE_TIMEOUT}s with no new job — clearing secrets and exiting 0 (autostop)"
      rm -f "$ENVDIR"/*.env "$JOB" 2>/dev/null || true
      exit 0
    fi
  done
done
