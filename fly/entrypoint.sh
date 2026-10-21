#!/bin/bash
# fly/entrypoint.sh — builder machine boot (Phase 1 of the Fly builder trial).
#
# Runs as PID-1 child of tini. Order (per plan "Phase 1 > fly/entrypoint.sh"):
#   1. tmpfs at /run/harness-env (mode 700) — secrets live in RAM only; a
#      stopped/crashed machine's volume never holds a client token.
#   2. tailscaled (state on the volume so node identity survives stop/start) +
#      `tailscale up` with TS_AUTHKEY (the machine's ONLY Fly secret).
#   3. Volume layout + compat symlinks so run-build.sh runs UNMODIFIED /root
#      paths against /data.
#   4. Volume health check — repo git broken => wipe + mark for re-warm (the
#      runner re-clones once env arrives; the volume is pure cache).
#   5. exec fly/builder-runner.sh.
#
# Open-detail decisions (simplest robust option, per task brief):
#   - PROJECT is derived from Fly's injected FLY_APP_NAME ("builder-<project>")
#     with a PROJECT env override for hand-runs. Fail loudly if neither yields a
#     project — a builder with no project identity must not proceed.
#   - The volume harness/env symlink points at the tmpfs so run-build.sh's
#     `. env/global.env` reads the RAM copy; nothing durable ever holds tokens.
#   - We set the OS hostname to builder-<project> so agent-call.sh's cost.csv
#     `$(hostname)` column tags rows host=builder-<project> (the plan's smoke
#     verify checks for exactly this).
#   - We prefer the volume copy of the runner scripts (/data/harness/fly, kept
#     fresh by harness sync) but fall back to the image copy at /opt/fly-boot so
#     a machine is bootable before its first sync.
set -uo pipefail

log() { echo "[entrypoint $(date -u '+%H:%M:%SZ')] $*"; }

# --- 0. identity --------------------------------------------------------------
PROJECT="${PROJECT:-}"
if [ -z "$PROJECT" ] && [ -n "${FLY_APP_NAME:-}" ]; then
  PROJECT="${FLY_APP_NAME#builder-}"
fi
if [ -z "$PROJECT" ]; then
  log "FATAL: no PROJECT (set PROJECT env or run as Fly app builder-<project>)"
  exit 1
fi
export PROJECT
# ONE BOX NAME PER MACHINE, not per pool (2026-09-11). bin/jobs-client.sh takes
# the box it reports to the ledger from $BOX_NAME, then state/box-name, then
# `hostname` — and a pool machine has neither of the first two (the hub's
# harness tarball carries bin/prompts/rules/fleet.conf, never state/), so this
# line IS the box column. Every pool machine answering "pool-<project>" made the
# ledger's `box * build 1` concurrency rule count the WHOLE POOL as one box:
# while one machine built, every other machine's claim came back "REFUSED box ::
# box max 1 already running" (project-5 TK-268/TK-270, project-4 TK-1515/1566/1571/
# 1576, all on 2026-09-11). The machine id makes the rule mean what it says —
# one build per MACHINE. Nothing keys on the exact old string: the box column is
# carried as DATA everywhere it is read (the worker's concurrency rules and its
# paused-box-<box> flag, the console's BOX column and its per-box grouping), and
# the `pool-<project>` build-dir and Fly-app names are a different namespace
# that this line never touched — grep over bin/, fly/, worker/ and console-ui/
# finds no match on the box string itself. An operator pausing a pool now pauses
# a MACHINE, which is the same shape as every other box in the fleet.
if [ "${POOL_MODE:-}" = "1" ]; then HOST="pool-$PROJECT-${FLY_MACHINE_ID:-$(hostname | tail -c 8)}"; else HOST="builder-$PROJECT"; fi
hostname "$HOST" 2>/dev/null || true
# THE COST-ROW IDENTITY, DECIDED ONCE, HERE (2026-09-14). fly/builder-runner.sh
# pushes this machine's logs/cost.csv into cost_rows under a box id, and
# bin/fly-pool.sh's reap pushes the reaped copy of the same rows under one too.
# They MUST be the same string or the PK dedupes nothing and the pool's bill is
# counted twice. Exported rather than re-derived so there is one expression in
# the tree that computes it; the runner falls back to `hostname` (which the line
# above just set to the same value) for a machine booted by an older image.
export COST_ROWS_BOX="$HOST"
log "boot for project=$PROJECT host=$HOST"

# --- 1. secrets tmpfs (RAM only) ---------------------------------------------
mkdir -p /run/harness-env /run/harness
if ! mountpoint -q /run/harness-env; then
  mount -t tmpfs -o size=16m,mode=700 tmpfs /run/harness-env \
    || { log "FATAL: could not mount tmpfs at /run/harness-env"; exit 1; }
fi
chmod 700 /run/harness-env
log "tmpfs mounted at /run/harness-env (RAM-only secrets)"

# --- 2. tailscale -------------------------------------------------------------
# POOL_MODE machines (wave 3) are ephemeral and volume-less: the hub pushes
# env + job and pulls RESULT over the Fly console, so they never join the
# tailnet and carry no TS_AUTHKEY. Skipping this block entirely is what lets
# a pool machine boot at all — the FATAL below is correct for builders.
if [ "${POOL_MODE:-}" = "1" ]; then
  log "POOL_MODE=1 — skipping tailscale (console push/pull only)"
else
if [ -z "${TS_AUTHKEY:-}" ]; then
  # A tagged node's state persists on the volume, so on a restart TS_AUTHKEY may
  # legitimately be absent while an existing state file re-authenticates. Only
  # fail if there is ALSO no prior state to fall back on.
  if [ ! -s /data/tailscaled.state ]; then
    log "FATAL: TS_AUTHKEY unset and no /data/tailscaled.state to resume from"
    exit 1
  fi
  log "TS_AUTHKEY unset; resuming from persisted /data/tailscaled.state"
fi

mkdir -p /data
# userspace-networking avoids needing a TUN device / NET_ADMIN on the Fly VM;
# hub->builder ssh works over it. --state on the volume => stable node identity.
tailscaled \
  --state=/data/tailscaled.state \
  --socket=/var/run/tailscale/tailscaled.sock \
  --tun=userspace-networking \
  >/var/log/tailscaled.log 2>&1 &
TAILSCALED_PID=$!
log "tailscaled started (pid $TAILSCALED_PID)"

# give the daemon a moment to open its socket
for _ in $(seq 1 20); do
  [ -S /var/run/tailscale/tailscaled.sock ] && break
  sleep 0.5
done

TS_UP_ARGS=(--hostname="$HOST" --ssh --accept-dns=false)
[ -n "${TS_AUTHKEY:-}" ] && TS_UP_ARGS+=(--authkey="$TS_AUTHKEY")
if tailscale up "${TS_UP_ARGS[@]}"; then
  log "tailscale up OK: $(tailscale ip -4 2>/dev/null | head -1)"
else
  # Per plan Failure-modes: on tailscale failure the builder can't be pushed a
  # job, but it CAN reach the console (outbound HTTPS) — post a fleet_alert and
  # exit so the machine autostops rather than hanging unreachable.
  log "FATAL: tailscale up failed — posting fleet_alert and exiting"
  if [ -n "${CONSOLE_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ]; then
    curl -s --max-time 15 -X POST -H "Authorization: Bearer $HARNESS_SECRET" \
      -H 'Content-Type: application/json' \
      -d "{\"kind\":\"fleet_alert\",\"host\":\"$HOST\",\"detail\":\"tailscale up failed on builder $PROJECT\"}" \
      "$CONSOLE_URL/api/beat" >/dev/null 2>&1 || true
  fi
  exit 1
fi
fi # end non-POOL_MODE tailscale block

# --- 3. volume layout + compat symlinks --------------------------------------
# run-build.sh and its helpers hardcode /root paths; symlink them onto /data so
# the pipeline runs byte-identically. harness/env points at the tmpfs (RAM).
mkdir -p /data/repos /data/worktrees /data/harness \
         /data/pnpm-store /data/pw-cache
mkdir -p /data/harness/logs /data/harness/locks /data/harness/flags \
         /data/harness/builds /data/harness/state /data/harness/state/claims

ln_force() { # ln_force <target> <linkpath>
  local target="$1" link="$2"
  rm -rf "$link" 2>/dev/null || true
  ln -s "$target" "$link"
}
mkdir -p /root
ln_force /data/repos      /root/repos
ln_force /data/worktrees  /root/worktrees
ln_force /data/harness    /root/harness
# harness/env -> tmpfs (secrets never touch the durable volume)
ln_force /run/harness-env /data/harness/env
# Resolver override (rule 1 of bin/lib/env-path.sh): every child of the runner
# resolves the env dir to the tmpfs directly; the symlink above is only for
# readers not yet ported.
export HARNESS_ENV_DIR=/run/harness-env
# build-slots=1 (single machine = single slot, wip=1 per the plan)
echo 1 > /data/harness/flags/build-slots

# >>> seed (BH-7430)
# THE PULL PATH'S SEED (bin/fly-pool.sh, `machine pull`). Two carriers:
#   /run/harness-seed/<push path>  --file-local files: the job, the relays, the
#       model routes, the deploy snapshot. Nothing secret. Fly writes them on
#       the ROOTFS (not tmpfs) before this script starts; they move to their
#       push paths below. The rootfs is ephemeral and holds no token.
#   /run/harness-seed-secret/bundle.b64  ONE --file-secret file: the files that
#       hold a token (global.override.env, gh-token*, auth-accounts.local.json),
#       as a base64 tar.gz. A token never goes in the machine config
#       (`machines list --json` shows --file-local content to anyone with the
#       app's Fly token), so Fly gives the file from an app secret SEED_*.
#       Fly writes that file on the rootfs too, so it is unpacked straight into
#       the tmpfs mounted above ($ENV_DIR/.sealed) and the rootfs copy is
#       deleted in the same step. The tokens then live in RAM only, as on the
#       push path. A failed unpack is not fatal here: the harness-pull block
#       writes the BUILD_DEFERRED row for it.
# Each file moves to its push path (mode 600), job.json LAST, because the runner
# starts on it. Then the static env: the pool app's Fly secrets
# HBUNDLE_G_<VAR> / HBUNDLE_P_<VAR> (bin/fly-pool-secrets-sync.sh) become
# global.env / <project>.env, and global.override.env (the per-machine lines the
# hub computed) replaces their keys: `KEY=VAL` drops the base KEY and adds the
# line, `-KEY` drops the base KEY. No HBUNDLE_* var reaches the runner.
# No seed and no HBUNDLE_SYNCED_AT (a persistent builder, a push-path machine)
# changes nothing. BOOT_ROOT is the test seam; production leaves it "".
BOOT_ROOT="${BOOT_ROOT:-}"
SEED_DIR="$BOOT_ROOT/run/harness-seed"
SECRET_B64="$BOOT_ROOT/run/harness-seed-secret/bundle.b64"
ENV_DIR="$BOOT_ROOT/run/harness-env"
SEALED_DIR="$ENV_DIR/.sealed"
SEED_UNSEAL_FAIL=""
seed_place() { # seed_place <root>: move each seed file under <root> to its push path
  local root="$1" sf rel
  while IFS= read -r -d '' sf; do
    rel="${sf#"$root"}"
    case "$rel" in
      /run/harness/job.json) continue ;;
      *..*) log "seed: skipped $rel (not a push path)"; continue ;;
      /run/harness/*|/run/harness-env/*|/data/harness/state/*) ;;
      *) log "seed: skipped $rel (not a push path)"; continue ;;
    esac
    mkdir -p "$BOOT_ROOT$(dirname "$rel")" && mv -f "$sf" "$BOOT_ROOT$rel" \
      && chmod 600 "$BOOT_ROOT$rel" && seed_n=$((seed_n + 1))
  done < <(find "$root" -type f -print0 2>/dev/null)
}
seed_n=0; seed_seen=0
if [ -f "$SECRET_B64" ]; then
  seed_seen=1
  # Fly base64-decodes a --file-secret value before it writes the file, so on a
  # real machine the file is the raw tar.gz (gzip magic 1f 8b). A base64 file
  # (an older writer, the suites) still unpacks through base64 -d.
  if [ "$(head -c 2 "$SECRET_B64" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = 1f8b ]; then
    unseal() { tar -xzf "$SECRET_B64" -C "$SEALED_DIR" --no-same-owner; }
  else
    unseal() { base64 -d < "$SECRET_B64" | tar -xzf - -C "$SEALED_DIR" --no-same-owner; }
  fi
  if ( umask 077; mkdir -p "$SEALED_DIR" && unseal ) 2>/dev/null; then
    seed_place "$SEALED_DIR"
  else
    SEED_UNSEAL_FAIL="the token bundle did not unpack"
    log "seed: the token bundle $SECRET_B64 did not unpack"
  fi
  rm -rf "$SEALED_DIR"; rm -f "$SECRET_B64"
fi
if [ -d "$SEED_DIR" ]; then
  seed_seen=1
  seed_place "$SEED_DIR"
  if [ -f "$SEED_DIR/run/harness/job.json" ]; then
    mkdir -p "$BOOT_ROOT/run/harness" && mv -f "$SEED_DIR/run/harness/job.json" "$BOOT_ROOT/run/harness/job.json" \
      && chmod 600 "$BOOT_ROOT/run/harness/job.json" && seed_n=$((seed_n + 1))
  fi
  rm -rf "$SEED_DIR"
fi
[ "$seed_seen" = 0 ] || log "seed: placed $seed_n file(s) at their push paths"
if [ -n "${HBUNDLE_SYNCED_AT:-}" ]; then
  ( umask 077
    G="$ENV_DIR/global.env.new"; PE="$ENV_DIR/$PROJECT.env.new"; OV="$ENV_DIR/global.override.env"
    : > "$G"; : > "$PE"
    while IFS= read -r v; do
      case "$v" in
        HBUNDLE_G_?*) printf '%s=%s\n' "${v#HBUNDLE_G_}" "${!v}" >> "$G" ;;
        HBUNDLE_P_?*) printf '%s=%s\n' "${v#HBUNDLE_P_}" "${!v}" >> "$PE" ;;
      esac
    done < <(compgen -e | sort)
    if [ -s "$OV" ]; then
      while IFS= read -r l; do
        k="${l%%=*}"; k="${k#-}"
        [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        grep -v "^$k=" "$G" > "$G.x"; mv -f "$G.x" "$G"
        case "$l" in -*) ;; *) printf '%s\n' "$l" >> "$G" ;; esac
      done < "$OV"
    fi
    mv -f "$G" "$ENV_DIR/global.env" && mv -f "$PE" "$ENV_DIR/$PROJECT.env" )
  rm -f "$ENV_DIR/global.override.env"
  log "env: composed global.env and $PROJECT.env from the app secrets (synced $HBUNDLE_SYNCED_AT)"
fi
# SEED_<epoch>_<hex> too (lead BLOCK #3155 on #7556): Fly puts every app
# secret in every machine's env, so each SEED_ is another machine's token
# bundle. The runner must start with none of them.
while IFS= read -r v; do
  case "$v" in HBUNDLE_*|SEED_*) unset "$v" ;; esac
done < <(compgen -e)
# <<< seed (BH-7430)

# >>> harness pull (BH-7430)
# HARNESS_SHA set (the pull path): fetch that exact harness commit now. A failed
# fetch writes the pool-result row `BUILD_DEFERRED harness-fetch: <why>` (the
# key of bin/lib/pool-result-row.sh; the hub reap requeues a deferral, never a
# death) and exits; there is no harness to run, so this is a raw curl.
# HARNESS_SHA unset (the push path, a persistent builder): prefer the tarball's
# runner — and WAIT for it. On volume-less pool machines the hub pushes the
# tarball ~20s after boot; exec-ing the image floor first meant every runner
# improvement shipped nowhere until an image rebuild (the 2026-08-15
# HARNESS_CHECKOUT/TARGET_BRANCH class). Wait up to 120s for the sync to land,
# then fall back to the image floor — which stays only a floor.
seed_deferred() { # seed_deferred <why> — rc 0 when the row was written
  local key
  key=$(jq -r '.key // ""' "$BOOT_ROOT/run/harness/job.json" 2>/dev/null)
  ( set -a; . "$ENV_DIR/global.env" 2>/dev/null; set +a
    [ -n "${JOBS_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ] && [ -n "$key" ] || exit 1
    detail=$(jq -nc --arg r "BUILD_DEFERRED $1" --arg m "${FLY_MACHINE_ID:-}" --argjson a "$(date -u +%s)" \
      '{rline:$r,machine:$m,at:$a}') || exit 1
    body=$(jq -nc --arg v "$PROJECT/$key" --arg a "$HOST" --arg d "$detail" \
      '{kind:"pool-result",key:$v,status:"result",actor:$a,detail:$d}') || exit 1
    curl -sS -m 15 -o /dev/null -X PUT -H "Authorization: Bearer $HARNESS_SECRET" \
      -H 'Content-Type: application/json' --data-binary "$body" "$JOBS_URL/api/ledger" )
}
mkdir -p "$BOOT_ROOT/data/harness/bin" "$BOOT_ROOT/data/harness/fly"
if [ -n "$SEED_UNSEAL_FAIL" ]; then
  log "FATAL: $SEED_UNSEAL_FAIL — deferring the job and exiting"
  seed_deferred "seed-unseal: $SEED_UNSEAL_FAIL" || log "the pool-result row was not written — the hub reap finds no RESULT"
  exit 1
fi
if [ -n "${HARNESS_SHA:-}" ]; then
  if HF_OUT=$("$BOOT_ROOT/opt/fly-boot/harness-fetch.sh" "$HARNESS_SHA" "${HARNESS_SLUG:-}" \
                "$ENV_DIR/gh-token-harness" "$BOOT_ROOT/data/harness" 2>&1); then
    log "$HF_OUT"
  else
    HF_WHY=$(printf '%s\n' "$HF_OUT" | grep 'FATAL:' | tail -n 1 | sed 's/^.*FATAL: //' | tr -d '\000-\037' | cut -c1-200)
    log "FATAL: harness fetch failed: ${HF_WHY:-no reason} — deferring the job and exiting"
    seed_deferred "harness-fetch: ${HF_WHY:-no reason}" || log "the pool-result row was not written — the hub reap finds no RESULT"
    exit 1
  fi
else
WAITED=0
while [ ! -x "$BOOT_ROOT/data/harness/fly/builder-runner.sh" ] && [ "$WAITED" -lt 120 ]; do
  sleep 5; WAITED=$((WAITED + 5))
done
if [ ! -x "$BOOT_ROOT/data/harness/fly/builder-runner.sh" ]; then
  log "no tarball runner after ${WAITED}s — using image floor"
  cp "$BOOT_ROOT/opt/fly-boot/builder-runner.sh" "$BOOT_ROOT/data/harness/fly/builder-runner.sh"
  chmod +x "$BOOT_ROOT/data/harness/fly/builder-runner.sh"
else
  log "tarball runner arrived after ${WAITED}s"
fi
fi
# The row stamp the hub makes on the push path (psr_claim_machine, BH-5001):
# here the machine names itself once its harness is in place. Fail-open.
if [ "${POOL_CLAIM_MACHINE:-0}" = 1 ] && [ -s "$BOOT_ROOT/run/harness/job.json" ]; then
  CK=$(jq -r '.key // ""' "$BOOT_ROOT/run/harness/job.json" 2>/dev/null)
  if [ -n "$CK" ] && ( set -a; . "$ENV_DIR/global.env" 2>/dev/null; set +a
       export HARNESS="$BOOT_ROOT/data/harness" HARNESS_ENV_DIR="$ENV_DIR" JOBS_BOX="$HOST"
       . "$HARNESS/bin/jobs-client.sh" && . "$HARNESS/bin/lib/pool-state-rows.sh" \
         && psr_claim_machine "$PROJECT" "$CK" "${FLY_MACHINE_ID:-}" ) >/dev/null 2>&1; then
    log "row $PROJECT/$CK stamped with machine ${FLY_MACHINE_ID:-?}"
  else
    log "row $PROJECT/${CK:-?} could not be stamped with machine ${FLY_MACHINE_ID:-?} — the build goes ahead"
  fi
fi
# <<< harness pull (BH-7430)
RUNNER=/data/harness/fly/builder-runner.sh
log "volume layout ready; runner=$RUNNER"

# --- 4. volume health check ---------------------------------------------------
REPO_DIR="/data/repos/$PROJECT"
if [ -e "$REPO_DIR/.git" ]; then
  if git -C "$REPO_DIR" rev-parse HEAD >/dev/null 2>&1; then
    log "repo cache healthy at $REPO_DIR ($(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null))"
  else
    log "repo cache CORRUPT at $REPO_DIR — wiping for re-warm"
    rm -rf "$REPO_DIR"
  fi
else
  log "no warm repo at $REPO_DIR — runner will clone on first job (cold start)"
fi

# --- 5. hand off to the runner ------------------------------------------------
log "exec builder-runner"
exec "$RUNNER"
