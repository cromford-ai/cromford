#!/bin/bash
# bin/fly-pool-rollout.sh — one-shot wave-3 rollout (the operator go via Telegram,
# 2026-08-13: "deploy wave 3 on the other machines"). For each project not yet
# on the pool: mint an org token if missing, ensure builder-<p> (registry) and
# pool-<p> apps, rebuild the builder image so it carries the POOL_MODE
# entrypoint, run a full spawn->push->SMOKE->reap-shaped probe on a REAL pool
# machine, and only on SMOKE_OK flip the routing flags (pool cap 2). A project
# that fails any step is logged and skipped — its current build lane is left
# exactly as it was. Safe to re-run; each step is idempotent or guarded.
#
# HARNESS / FLYCTL_DIR / ROLLOUT_BOOT_WAIT / ROLLOUT_POLL_WAIT are overridable
# for the same reason bin/fly-pool-tick.sh took that seam (BH-662): a suite that
# cannot point this script at a scratch tree, a fake flyctl and a zero wait
# cannot drive it at all, and bin/fly-onboard.sh wraps it — a wrapper whose
# wrapped script is undrivable is a wrapper tested against nothing. Cron and the
# hub shell set none of them, so production is byte-identical to before.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
LOG="$H/logs/fly-pool-rollout.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
say() { echo "$(STAMP) $*" >> "$LOG"; }
# A project this pass did not enable is a FAILURE, not a footnote (BH-666).
# skip() is the quiet half — the step's own line already says what happened, and
# the counter makes the pass exit non-zero at the end so bin/fly-onboard.sh and
# an operator's shell can tell "three enabled" from "three skipped". fail() is
# the loud half: a stop that needs authority or a hand this box does not have
# gets ONE actionable ALERTS line naming the project and the real error, because
# a question asked into your own run log is indistinguishable from silence.
FAILED=0
skip() { say "[$P] $1"; FAILED=$((FAILED+1)); }
fail() { skip "$1"; echo "$(STAMP) [rollout/$P] $1" >> "$H/logs/ALERTS.log"; }
export PATH="${FLYCTL_DIR:-/root/.fly/bin}:$PATH"
set -a; . "$HENV/fly.env"; set +a
FLY=$(command -v flyctl || command -v fly)
# Same guard as bin/fly-pool.sh: cron's PATH can miss /usr/local/bin/flyctl,
# and an empty FLY would make the wrapper below `exec ''` (2026-10-21).
if [ -z "$FLY" ]; then
  # shellcheck source=bin/lib/fly-bin.sh
  [ -r "$H/bin/lib/fly-bin.sh" ] && . "$H/bin/lib/fly-bin.sh" && FLY=$(fly_bin) || FLY=""
fi
[ -n "$FLY" ] || { P=all; fail "no flyctl on this host — rollout skipped"; exit 1; }
# Start the flyctl agent BEFORE any lock, and wrap flyctl so the agent never
# inherits the per-project lock fd — same reasoning as bin/fly-pool.sh:83-95
# (an agent auto-spawned inside the locked section holds the lock forever).
# fd 7 here, because fd 8 is the token block's harden-state.lock below.
"$FLY" agent start >/dev/null 2>&1 || true
_FLY_BIN=$FLY
FLY=$(mktemp "${TMPDIR:-/tmp}/fly-noleak.XXXXXX") || exit 1
printf '#!/bin/bash\nexec %q "$@" 7>&-\n' "$_FLY_BIN" > "$FLY"
chmod +x "$FLY"
trap 'rm -f -- "$FLY"' EXIT

# Owning watcher boxes that need the enqueue-shim flag (run-build.sh routes to
# the queue only where this flag exists). project-1' watcher IS the hub.
# fleet.conf's tailnet_ip (2026-09-11). Prints nothing when unknown, which every
# caller here already treats as "skip this project".
box_ip() { "${HARNESS:-/root/harness}/bin/fleet-conf.sh" --tailnet-ip "$1" 2>/dev/null; }

# state/fly/<p>.image is published BEFORE the probe runs (step 3) and
# bin/fly-pool.sh dispatches from it as soon as its tag is newer, so a probe
# that did not pass must not leave the pointer preferring the bits that failed
# (BH-666). It only ever writes back the value THIS pass read before the build,
# and only while the file still holds the ref we built — anyone who moved it
# since owns it now. A first-ever rollout (no file, no fly_images row) has no
# previous ref and keeps the fresh one: bin/fly-provision.sh boots from it,
# and nothing dispatches from it until flags/fly-pool-<p> exists.
# The fly_images row needs no restore (BH-2743): step 3 wrote the candidate
# `baked`, never active, so the row every hub reads never left the previous
# proven ref. It only records the failure on the candidate.
unpublish_img() {
  local CUR
  mark_smoke_failed
  CUR=$(cat "$H/state/fly/$P.image" 2>/dev/null)
  if [ -n "$PREV_IMG" ] && [ "$CUR" = "$IMG" ] && [ "$PREV_IMG" != "$IMG" ]; then
    printf '%s\n' "$PREV_IMG" > "$H/state/fly/$P.image"
    say "[$P] image pointer restored to $PREV_IMG — SMOKE did not pass on $IMG, so the dispatcher must not prefer it"
  fi
}

# BH-2743: `smoke_failed` on the candidate row. No ALERT when it does not land:
# the active row never moved, so nothing unsafe is left behind (fir_put logs it
# and leaves the row-stale marker, so this hub reads its files).
mark_smoke_failed() {
  declare -F fir_put >/dev/null 2>&1 || return 0
  fir_put "$P" "builder-$P" "$IMG" "" "" "" "" smoke_failed || true
}

# BH-2743: the candidate becomes the row EVERY hub dispatches from only here,
# after SMOKE_OK on the ref the pointer still names; the worker demotes the
# previous row in the same batch. An activation that does not land (fir_put rc
# 3, after one more try) is one actionable ALERTS line: this hub reads
# state/fly/<p>.image through the row-stale marker, and every other hub keeps
# the previous proven ref, so the pool enable goes on.
activate_row() {
  declare -F fir_put >/dev/null 2>&1 || return 0
  local rc=0
  fir_put "$P" "builder-$P" "$IMG" "" "" "" 1 || rc=$?
  [ "$rc" = 3 ] || return 0
  sleep "${ROLLOUT_ROW_RETRY_WAIT:-5}"
  rc=0; fir_put "$P" "builder-$P" "$IMG" "" "" "" 1 || rc=$?
  [ "$rc" = 3 ] || return 0
  echo "$(STAMP) [rollout/$P] fly_images row NOT moved to $IMG after SMOKE_OK (activation PUT not recorded twice; see logs/fly-image-build.log). This hub reads state/fly/$P.image (row-stale marker); other hubs keep dispatching ${PREV_IMG:-no row} (proven) until PUT /api/fly-images {\"project\":\"$P\",\"app\":\"builder-$P\",\"digest\":\"$IMG\",\"active\":1} lands." >> "$H/logs/ALERTS.log"
}

# BH-2523: the fly_images row follows the pointer file. BH-2743: as a `baked`
# candidate before SMOKE, and active only after it passes.
# From the harness root, as fly-pool.sh and fly-provision.sh load it: the seam
# finds its jobs client beside itself, so it must be the harness's own copy.
# shellcheck source=bin/lib/fly-image-row.sh
[ -r "$H/bin/lib/fly-image-row.sh" ] && . "$H/bin/lib/fly-image-row.sh"

mexec() { timeout 90 "$FLY" ssh console -a "$2" --machine "$1" -C "/bin/sh -c $(printf '%q' "$3")" 2>/dev/null; }
mput()  { local B64; B64=$(base64 -w0 "$2"); mexec "$1" "$4" "mkdir -p $(dirname "$3") && echo $B64 | base64 -d > $3 && chmod 600 $3" >/dev/null; }

# Projects come from the command line (2026-09-11, the operator: "enable that for
# project-5, as much parallel as possible"); the original wave-3 trio remains the
# default so the one-shot history still reads true. POOL_CAP is the per-project
# pool ceiling written to flags/fly-pool-<p> (was a literal 2, then a default 2).
# UNSET IS NOW THE DEFAULT AND MEANS AUTOSCALE (the operator, 2026-09-14): the flag file
# is written EMPTY, so its presence still enables the pool while bin/pool-cap.sh
# reads no ceiling out of it and bin/fly-pool.sh sizes the pool to the queue.
# Set POOL_CAP=<n> to bake a hard ceiling in for cost safety; with
# POOL_AUTOSCALE=0 the old default 2 comes back, written as a number exactly as
# before. bin/pool-cap.sh is the one reader of both knobs.
if [ "$("$H/bin/pool-cap.sh" --autoscale 2>/dev/null)" = 0 ]
then POOL_CAP="${POOL_CAP:-2}"
else POOL_CAP="${POOL_CAP:-}"
fi
if [ "$#" -gt 0 ]; then PROJECTS="$*"; else PROJECTS="project-2 project-4 project-1"; fi
for P in $PROJECTS; do
  say "[$P] rollout start"

  # --- 0. dedupe, then preflight — both BEFORE anything that spends ----------
  # DEDUPE, NEVER A QUEUE (the operator, 2026-09-13): a pass whose project is already
  # being rolled out skips and is re-offered next time, it does not wait. Two
  # overlapping passes ran `fly deploy --build-only --push` against the same
  # builder app on 2026-09-17 and collided (image build FAILED 17:44:30 and
  # 17:44:39, image built 17:44:41 — one sequential pass cannot do that).
  # Re-`exec 7>` on the next project releases the previous one's lock.
  mkdir -p "$H/locks" 2>/dev/null
  exec 7>"$H/locks/fly-pool-rollout-$P.lock"
  flock -n 7 || { skip "a rollout pass for $P is already running (locks/fly-pool-rollout-$P.lock held) — skipping this pass, not queueing behind it"; continue; }

  # The env bundle is pulled off the owning box over ssh and the step-5 enqueue
  # flag is pushed to it, so with no address there is nothing to push to and
  # nothing to flag. Answer that BEFORE minting a token and BEFORE a 30-minute
  # image build, and name the gap: BH-668 burned six image builds on a
  # harness-console row that had no tailnet_ip, reporting only push_ok=0.
  IP=$(box_ip "$P")
  if [ -z "$IP" ]; then
    skip "no tailnet_ip for $P in fleet.conf (bin/fleet-conf.sh --tailnet-ip $P is empty) — the env bundle and the box flag both need it, nothing to push to; skipping project BEFORE the image build"
    continue
  fi

  TV="FLY_API_TOKEN_$(echo "$P" | tr '[:lower:].-' '[:upper:]__')"

  # --- 1. token (org-scoped, matching the project-3/project-2 pattern) --------------------
  if [ -z "${!TV:-}" ]; then
    # Minting needs the hub's flyctl SESSION auth (config.yml, operator@) — the
    # env tokens are limited and cannot createLimitedAccessToken (2026-08-13).
    # BOTH names have to go (BH-666): flyctl reads FLY_ACCESS_TOKEN first and
    # falls back to FLY_API_TOKEN, so dropping only the first left the limited
    # bootstrap token doing the mint and every new project came back "Not
    # authorized to access this createlimitedaccesstoken". AUDIT of every other
    # flyctl call in this file: all of them run AFTER the export below, so the
    # project token wins that same precedence; FLY_API_TOKEN deliberately stays
    # exported, because bin/fly-image-build.sh needs it for the registry push.
    ERRF=$(mktemp)
    T=$(env -u FLY_ACCESS_TOKEN -u FLY_API_TOKEN timeout 60 "$FLY" tokens create org -o "$FLY_ORG" --name "wave3-$P" --expiry 8760h 2>"$ERRF" | grep -oE 'FlyV1 .*' | head -1)
    if [ -z "$T" ]; then
      # flyctl's own sentence, flattened to one line and capped. Never $T — an
      # ALERT that echoed the credential would be the next incident.
      ERR=$(tr -s '[:space:]' ' ' < "$ERRF" | head -c 400 | sed 's/^ //; s/ $//')
      rm -f "$ERRF"
      fail "org token mint FAILED — flyctl: ${ERR:-flyctl printed no token and no stderr}"
      continue
    fi
    rm -f "$ERRF"
    # env/fly.env is +i once the box is armed: release, append, rearm, under
    # harden-state.lock (fd 8) and nothing else inside it.
    #
    # And the append is VERIFIED WHERE IT IS WRITTEN (BH-666). A value the
    # quoted form cannot carry — an embedded quote, a `$`, a newline — does not
    # fail here; it fails hours later in whichever of the dozen scripts that
    # source this file reads it next, as a syntax error with no author. So: back
    # the file up, append, source it in a clean process, compare what comes back,
    # and put the original bytes back when it does not match. The restore is
    # `cat "$BAK" >` because the file is +i-managed and has to keep its inode —
    # which is also why a backup that never landed must stop the append outright:
    # `cat >` truncates before it reads, so rolling back to nothing would empty
    # env/fly.env for every reader on the box.
    mkdir -p "$H/locks" 2>/dev/null
    BAK=$(mktemp /dev/shm/flyenv.XXXX 2>/dev/null)
    ENV_BAD=0
    {
      flock -w 30 8 || true
      [ -x "$H/bin/harden-state.sh" ] && "$H"/bin/harden-state.sh --release "$HENV/fly.env"
      if [ -n "$BAK" ] && cp "$HENV/fly.env" "$BAK" && cmp -s "$HENV/fly.env" "$BAK"; then
        printf '%s="%s"\n' "$TV" "$T" >> "$HENV/fly.env"   # QUOTED: the token value contains a space (FlyV1 fm2_...)
        env -i bash -c 'set -a; . "$1" >/dev/null 2>&1 || exit 1; [ "${!2}" = "$3" ]' _ "$HENV/fly.env" "$TV" "$T" \
          || { cat "$BAK" > "$HENV/fly.env"; ENV_BAD=1; }
      else
        ENV_BAD=2
      fi
      [ -x "$H/bin/harden-state.sh" ] && "$H"/bin/harden-state.sh --rearm "$HENV/fly.env"
      [ -n "$BAK" ] && rm -f "$BAK"
    } 8>"$H/locks/harden-state.lock"
    if [ "$ENV_BAD" = 2 ]; then
      fail "could not back up env/fly.env before appending $TV (mktemp/cp in /dev/shm failed) — nothing written, token NOT saved; skipping project"
      continue
    fi
    if [ "$ENV_BAD" = 1 ]; then
      fail "env/fly.env REJECTED the appended $TV line (value does not round-trip through source) — file restored, token NOT saved; skipping project"
      continue
    fi
    # Export only after the file a later reader will source has been proven to
    # hold it: the pass must never run on a credential the next process cannot
    # find.
    export "$TV=$T"
    say "[$P] org token minted + appended to env/fly.env"
  fi
  export FLY_ACCESS_TOKEN="${!TV}"

  # --- 2. apps (idempotent: create failure is fine if it already exists) -------
  timeout 60 "$FLY" apps create "builder-$P" -o "$FLY_ORG" >/dev/null 2>&1 || true
  timeout 60 "$FLY" apps create "pool-$P"    -o "$FLY_ORG" >/dev/null 2>&1 || true
  timeout 30 "$FLY" status -a "pool-$P" >/dev/null 2>&1 || { skip "pool-$P app missing after create — skipping"; continue; }

  # --- 3. image with the POOL_MODE entrypoint ----------------------------------
  # Where the dispatch pointer stands BEFORE this pass moves it, so a probe that
  # fails can put it back. Empty = this project has never had an image.
  PREV_IMG=$(cat "$H/state/fly/$P.image" 2>/dev/null)
  # BH-2523: a fresh hub has no file, but the fleet's row may name a good ref;
  # without it a failed smoke here would leave the row on the failed bits.
  if [ -z "$PREV_IMG" ] && declare -F fir_digest >/dev/null 2>&1; then
    PREV_IMG=$(fir_digest "$P" 2>/dev/null) || PREV_IMG=""
  fi
  say "[$P] building image (depot)"
  # FLY_IMAGE_CANDIDATE=1 (BH-2743): the build records its row `baked`, not
  # active; activate_row flips it after SMOKE_OK.
  if ! FLY_IMAGE_CANDIDATE=1 timeout 1800 "$H/bin/fly-image-build.sh" "$P" >> "$H/logs/fly-image-build.log" 2>&1; then
    skip "image build FAILED — skipping project"; continue
  fi
  IMG=$(grep -oE "image: registry\.fly\.io/builder-$P:[^ ]+" "$H/logs/fly-image-build.log" | tail -1 | cut -d' ' -f2)
  [ -n "$IMG" ] || IMG=$(cat "$H/state/fly/$P.image" 2>/dev/null)
  if [ -z "$IMG" ]; then skip "no image ref recorded — skipping project"; continue; fi
  echo "$IMG" > "$H/state/fly/$P.image"
  # The build already wrote bake and baked_at; the worker keeps them on a resend.
  # `baked`, never active (BH-2743): no hub dispatches the candidate before its
  # SMOKE passes. rc 3 (not recorded) is never fatal: fir_put left the row-stale
  # marker.
  if declare -F fir_put >/dev/null 2>&1; then fir_put "$P" "builder-$P" "$IMG" "" "" "" "" baked || true; fi
  [ -s "$H/state/fly/$P.json" ] || printf '{"app":"builder-%s"}\n' "$P" > "$H/state/fly/$P.json"
  say "[$P] image: $IMG"

  # --- 4. live SMOKE through a real pool machine -------------------------------
  # --region is REQUIRED non-interactively (2026-09-11: every smoke launch failed
  # in one second with no machine id because flyctl prompts for a region on a
  # tty and errors without one; the pool's raw-API spawn always passes it).
  MID=$(timeout 180 "$FLY" machine run "$IMG" -a "pool-$P" --detach --region "${FLY_REGION:-iad}" --vm-size performance-4x --vm-memory 16384 \
        -e PROJECT="$P" -e POOL_MODE=1 2>/dev/null | grep -i 'machine id' | grep -oE "[0-9a-f]{14}" | head -1)
  if [ -z "$MID" ]; then skip "smoke machine run FAILED — skipping project"; unpublish_img; continue; fi
  sleep "${ROLLOUT_BOOT_WAIT:-30}"
  ST=$(timeout 30 "$FLY" machines list -a "pool-$P" --json 2>/dev/null | jq -r ".[] | select(.id==\"$MID\") | .state")
  if [ "$ST" != "started" ]; then
    skip "smoke machine state=$ST (not started) — destroying, skipping project"
    timeout 60 "$FLY" machine destroy "$MID" -a "pool-$P" --force >/dev/null 2>&1
    unpublish_img; continue
  fi
  TMP=$(mktemp -d /dev/shm/rollout.XXXX); chmod 700 "$TMP"
  OK=1
  # WHICH step failed, and WHY. push_ok=0 alone covers four different failures
  # and reads like a machine that never reported back (BH-668). EB_ERR is the
  # bundler's own `fly-envbundle/<p> FATAL: …` line, which names paths and hosts
  # only — never env contents, and it must stay that way. --pool (BH-4798): the
  # smoke machine is a pool machine and a SMOKE job never reads GH_TOKEN, so a
  # box with no PAT warns here (rc 0) instead of failing every rollout.
  STEP=""; EB_ERR=""
  # The smoke machine is a volume-less pool machine, so it gets the harness tree
  # the same way bin/fly-pool.sh gives one to every pool build. Without it the
  # SMOKE job finds no bin/lib/cred-probe.sh and answers "SMOKE_FAIL harness not
  # synced" (BH-2559, 2026-09-27): no rollout smoke passed after that date.
  if [ -r "$H/bin/lib/harness-tarball.sh" ] && . "$H/bin/lib/harness-tarball.sh"; then
    HTB=$(mktemp /tmp/rollout-hsync-XXXX.tgz)
    harness_tarball "$HTB" "${HARNESS_CHECKOUT:-/root/harness-checkout}" bin prompts rules catalog fleet.conf fly
    timeout 120 "$FLY" ssh sftp put -a "pool-$P" --machine "$MID" "$HTB" /run/harness/.hsync.tgz >/dev/null 2>&1 \
      && mexec "$MID" "pool-$P" "mkdir -p /data/harness && tar xzf /run/harness/.hsync.tgz -C /data/harness && mkdir -p /data/harness/logs /data/harness/state /data/harness/locks /data/harness/builds && rm -f /run/harness/.hsync.tgz" >/dev/null \
      || { OK=0; STEP=harness-sync; }
    rm -f "$HTB"
  else
    # Same as bin/fly-pool.sh: say it and go on. The SMOKE then fails with its
    # own "harness not synced" line, which names the cause.
    say "[$P] bin/lib/harness-tarball.sh missing under $H — the smoke machine gets no harness tree"
  fi
  [ "$OK" = 1 ] && { EB_ERR=$("$H/bin/fly-envbundle.sh" "$P" "$TMP" --pool 2>&1 >/dev/null) || { OK=0; STEP=envbundle; }; }
  EB_ERR=$(printf '%s' "$EB_ERR" | tr '\n' ' ')
  jq -nc '{ticket_id:"SMOKE",key:"SMOKE",attempt:0}' > "$TMP/job.json"
  [ "$OK" = 1 ] && { mput "$MID" "$TMP/global.env" /run/harness-env/global.env "pool-$P" || { OK=0; STEP=push:global.env; }; }
  [ "$OK" = 1 ] && { mput "$MID" "$TMP/$P.env" "/run/harness-env/$P.env" "pool-$P" || { OK=0; STEP=push:project.env; }; }
  [ "$OK" = 1 ] && { mput "$MID" "$TMP/job.json" /run/harness/job.json "pool-$P" || { OK=0; STEP=push:job.json; }; }
  rm -rf "$TMP"
  RES=""
  if [ "$OK" = 1 ]; then
    for i in $(seq 1 10); do
      sleep "${ROLLOUT_POLL_WAIT:-20}"
      RES=$(mexec "$MID" "pool-$P" "cat /run/harness/RESULT 2>/dev/null")
      # Same mexec-miss gate as fly-pool.sh (MEDIC 4467): a flyctl panic on
      # stdout must not be mistaken for a smoke result.
      [ -n "$RES" ] && ! "$H/bin/result-prefix-ok.sh" "$RES" && RES=""
      case "$RES" in SMOKE*) break;; esac
    done
  fi
  timeout 60 "$FLY" machine destroy "$MID" -a "pool-$P" --force >/dev/null 2>&1
  case "$RES" in
    SMOKE_OK*) say "[$P] SMOKE_OK on pool machine $MID" ;;
    *) skip "smoke FAILED (push_ok=$OK step=${STEP:-none} reason='${EB_ERR:-}' result='${RES:-none}') — skipping project"; unpublish_img; continue ;;
  esac

  # --- 5. flip routing (pool flags first, then the enqueue shim) ---------------
  # Only ever onto the ref the probe actually ran. bin/fly-image-refresh.sh
  # rewrites this pointer nightly for enabled projects and could have moved it
  # while step 4 was waiting on a machine; a probe that does not test the bits
  # you ship is not a probe. The pointer is NOT touched here — it belongs to
  # whoever moved it — and "skipping project" is load-bearing for the step name
  # bin/fly-onboard.sh reads out of this log.
  CUR_IMG=$(cat "$H/state/fly/$P.image" 2>/dev/null)
  if [ "$CUR_IMG" != "$IMG" ]; then
    fail "image pointer moved during smoke (probed $IMG, pointer now ${CUR_IMG:-empty}) — REFUSING to enable the pool on unproven bits; skipping project, re-run the rollout to probe the current image"
    continue
  fi
  activate_row
  echo "pool-$P" > "$H/flags/fly-pool-app-$P"
  # An empty flag file is the enable switch ALONE — the cap resolution then
  # falls through to fly/pool-caps.conf and POOL_CAP_MAX, which is what
  # "unlimited by default" means in a file every other reader treats as a
  # presence test.
  if [ -n "$POOL_CAP" ]; then echo "$POOL_CAP" > "$H/flags/fly-pool-$P"; else : > "$H/flags/fly-pool-$P"; fi
  touch "$H/flags/builder-fly-$P"
  # ONE WRITE, NOT TWO BOXES (BH-1373). With the routing_rows knob on, the row
  # is the enrollment (routing_sync derives a box's four files from it), so
  # nobody ssh-es the owning box. The halt rides along from the file: enabling
  # a halted project must not lift its halt. A refused PUT is a WARNING, never
  # a skip: the hub flags above are written and the wave stays enabled (BH-666).
  _h=0; [ -f "$H/flags/pool-halt-$P" ] && _h=1
  if [ -x "$H/bin/jobs-client.sh" ] && HARNESS="$H" "$H/bin/jobs-client.sh" routing-rows-on >/dev/null 2>&1; then
    HARNESS="$H" "$H/bin/jobs-client.sh" routing-set "$P" pool "pool-$P" "$_h" >/dev/null 2>&1 \
      && say "[$P] routing row set: builder=pool app=pool-$P (routing_rows is on, so the row is the enrollment; the owning box was not ssh'd)" \
      || say "[$P] WARNING: routing row for $P not written (jobs API refused or unreachable). The hub flags are set and the owning box was not ssh'd; re-run the rollout once the jobs API answers"
  else
    IP=$(box_ip "$P")
    if [ -n "$IP" ]; then
      timeout 25 ssh -n -o BatchMode=yes -o ConnectTimeout=8 "root@$IP" "touch /root/harness/flags/builder-fly-$P" \
        && say "[$P] enqueue flag set on owning box $IP" \
        || say "[$P] WARNING: could not set builder-fly-$P on box $IP — its locally-launched builds keep building locally until set"
    fi
  fi
  # Report the cap that RESOLVES, not the one we meant to write: with an empty
  # flag file the answer comes from the conf or from POOL_CAP_MAX, and a
  # rollout line that said "cap " would be the reader's problem for a month.
  CAPTXT=$("$H/bin/pool-cap.sh" "$P" 2>/dev/null | tr -dc '0-9'); [ "${CAPTXT:-0}" = 0 ] && CAPTXT=unlimited
  say "[$P] WAVE3 ENABLED (pool cap $CAPTXT) image $IMG"
  "$H/bin/beat.sh" "$(jq -nc --arg p "$P" --arg akey "wave3-rollout:$P" --arg l "Wave-3 pool enabled for $P (cap $CAPTXT) after live SMOKE_OK" '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1 || true
done
# The exit status IS the outcome (BH-666): any requested project this pass did
# not enable makes the pass non-zero, so a caller that checks rc stops reading
# "skipped everything" as "done".
say "rollout pass complete ($FAILED project(s) skipped)"
[ "$FAILED" = 0 ]
