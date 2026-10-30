# >>> warmup note (BH-7215)
# pool_warmup_note <mid> <key> <launch-epoch> <push-epoch> <wait-s>
# One log line per spawn: the seconds from `fly machine run` to the first env
# push, against the machine's warmup wait. Over POOL_WARMUP_ALERT_PCT (lane knob,
# default 80, 0 = off) of the wait, ONE ALERTS line per project per UTC day: a
# slower hub setup would lose the spawn (#7174). Spawns run in parallel
# subshells; only the first writer of the day flag alerts.
# The day flag goes through bin/lib/flags.sh (flag_has --cached /
# flag_set, the file flags/alerted-pool-warmup-<P>-<YYYYMMDD>); bin/alerts-groom.sh
# prunes old alerted-* days. The alert carries --id pool-warmup-<P>, so two
# parallel spawns that both pass flag_has open one alerts row, not two.
pool_warmup_note() {
  local mid="${1:-}" key="${2:-}" t0="${3:-0}" t1="${4:-0}" w="${5:-0}" sp pct flag
  case "$t0" in ''|*[!0-9]*) t0=0 ;; esac
  case "$t1" in ''|*[!0-9]*) t1=0 ;; esac
  case "$w" in ''|*[!0-9]*) w=0 ;; esac
  sp=$(( t1 - t0 )); [ "$sp" -ge 0 ] || sp=0
  say "$mid: launch→first push ${sp}s (warmup wait ${w}s)"
  pct="${POOL_WARMUP_ALERT_PCT:-80}"; case "$pct" in ''|*[!0-9]*) pct=80 ;; esac
  [ "$pct" -gt 0 ] && [ "$w" -gt 0 ] || return 0
  [ $(( sp * 100 )) -gt $(( w * pct )) ] || return 0
  # shellcheck source=bin/lib/flags.sh
  command -v flag_set >/dev/null 2>&1 || . "$HARNESS/bin/lib/flags.sh" 2>/dev/null || return 0
  flag="alerted-pool-warmup-$P-$(date -u +%Y%m%d)"
  flag_has --cached "$flag" 2>/dev/null && return 0
  flag_set "$flag" on "fly-pool: warmup alert sent" >/dev/null 2>&1
  HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" --id "pool-warmup-$P" "[pool/$P] $key: launch→first push ${sp}s on $mid is over ${pct}% of the ${w}s warmup wait (WARMUP_WAIT_S). A slower hub setup loses the spawn: the machine exits before its job. Raise lane.fly-pool.$P.warmup_wait_s or find the slow setup step in logs/fly-pool.log." >/dev/null 2>&1 || true
  return 0
}
# <<< warmup note

# >>> machine pull (BH-7430)
# THE MACHINE TAKES ITS OWN HARNESS, ENV AND JOB (BH-6896 S3). On the push path
# every spawn costs the hub an ssh to the owning box (fly-envbundle.sh), a fixed
# `sleep 20`, a 6.49 MB tarball over `ssh sftp` and 4 to 9 `ssh console` pushes.
# On the pull path the spawn ends at ONE `fly machine run`:
#   harness  the machine fetches HARNESS_SHA of HARNESS_SLUG itself
#            (fly/harness-fetch.sh), with a read token from the seed;
#   env      the static bundle is in the pool app's Fly secrets (HBUNDLE_*,
#            written by bin/fly-pool-secrets-sync.sh); the per-machine lines
#            (App token, leased account, OPENROUTER_FALLBACK, read tokens) go in
#            the seed as global.override.env, computed here BEFORE the launch;
#   job      job.json and every relay (pre-plan, reroute, build note, bake
#            evidence, deploy snapshot) go in the seed: `--file-local
#            /run/harness-seed/<push path>=<file>`. mput's seed mode stages them,
#            so the relay functions are the same ones the push path runs.
# fly/entrypoint.sh moves the seed to the push paths, composes the env and
# fetches the harness. POOL_MACHINE_PULL (lane knob, default 0) is the switch;
# at 0 nothing here runs and the spawn is byte-identical to the push path. Any
# precondition missing for one spawn sends that spawn down the push path, with
# one `<key>: push path (<why>)` line.
POOL_PULL_PRIMED=0; POOL_PULL_ON=0; POOL_PULL_WHY=""; POOL_PULL_SHA=""; POOL_PULL_SLUG=""
POOL_PULL_BASE=__HBUNDLE_BASE__
# pool_pull_prime: once per tick, in the tick's own shell, before the first
# spawn (spawns run in background subshells and cannot share a memo). ONE
# `fly secrets list` per tick, never per spawn.
pool_pull_prime() {
  [ "$POOL_PULL_PRIMED" = 0 ] || return 0
  POOL_PULL_PRIMED=1
  local k="${POOL_MACHINE_PULL:-0}" names
  k="${k//[[:space:]]/}"
  [ "$k" = 1 ] || return 0
  POOL_PULL_ON=1
  POOL_PULL_SLUG=$( . "$HARNESS/bin/lib/deployment.sh" 2>/dev/null && printf '%s' "${HARNESS_REPO:-}" )
  if ! [[ "$POOL_PULL_SLUG" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]]; then
    POOL_PULL_WHY="no harness repo slug (bin/lib/deployment.sh HARNESS_REPO)"; return 0
  fi
  # The checkout beside the harness: /root/harness-checkout in production, the
  # tree harness_tarball ships on the push path.
  POOL_PULL_SHA=$(git -C "${HARNESS%/}-checkout" rev-parse HEAD 2>/dev/null)
  if ! [[ "$POOL_PULL_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    POOL_PULL_SHA=""; POOL_PULL_WHY="no git HEAD in the harness checkout"; return 0
  fi
  # Names only: `fly secrets list` prints a digest, never a value. A hung call
  # costs ONE 10 s wait: the marker below sends every spawn of the next 5
  # minutes down the push path without calling it again.
  local hang="$POOL/.secrets-list-hang" out rc
  if [ -n "$(find "$hang" -mmin -5 2>/dev/null)" ]; then
    POOL_PULL_WHY="fly secrets list timed out in the last 5 minutes"; return 0
  fi
  out=$(timeout 10 "$FLY" secrets list -a "$APP" --json 2>/dev/null); rc=$?
  if [ "$rc" = 124 ]; then
    : > "$hang" 2>/dev/null
    POOL_PULL_WHY="fly secrets list timed out (10 s)"; return 0
  fi
  names=$(jq -r '.[]? | (.Name // .name // empty)' 2>/dev/null <<<"$out")
  pool_pull_sweep "$names"
  if ! grep -qx HBUNDLE_SYNCED_AT <<<"$names"; then
    POOL_PULL_WHY="no HBUNDLE_SYNCED_AT in the $APP secrets"; return 0
  fi
  say "machine pull: on (harness ${POOL_PULL_SHA:0:12} of $POOL_PULL_SLUG, $APP secrets synced)"
}
# pool_pull_sweep <secret names>: a per-machine SEED_<epoch>_<hex> secret
# (pool_pull_seal) has done its job once its machine has booted. Unset every one
# older than POOL_SEED_SECRET_TTL_S, staged, in one call, from the names the
# prime already listed (no extra list call). A failed unset is one line; the
# next tick tries again.
POOL_SEED_SECRET_TTL_S=900
pool_pull_sweep() {
  local now n t stale=()
  now=$(date +%s)
  while IFS= read -r n; do
    [[ "$n" =~ ^SEED_([0-9]{10})_[0-9a-f]{12}$ ]] || continue
    t="${BASH_REMATCH[1]}"
    [ $((now - 10#$t)) -gt "$POOL_SEED_SECRET_TTL_S" ] && stale+=("$n")
  done <<<"${1:-}"
  [ "${#stale[@]}" -gt 0 ] || return 0
  if timeout 60 "$FLY" secrets unset --stage -a "$APP" "${stale[@]}" >/dev/null 2>&1; then
    say "seed secrets: unset ${#stale[@]} spent SEED_ secret(s) from $APP"
  else
    say "seed secrets: could not unset ${#stale[@]} spent SEED_ secret(s) on $APP, retried next tick"
  fi
}
# pool_pull_decide <key> <job-file> <tmp> -> rc 0 pull, rc 1 push (after one
# `<key>: push path (<why>)` line). Called before the env bundle, so a push
# answer still runs fly-envbundle.sh exactly as today. On rc 0 the seed dir
# $tmp/seed holds the job and the relays; the env lines join it at launch.
pool_pull_decide() {
  local k="$1" jf="$2" tmp="$3" why="${POOL_PULL_WHY:-}" exp ht max bytes
  # BH-8030: a console preview row pushes the Pages token after the launch,
  # never in a seed.
  [ -n "$why" ] || case "$k" in CP-*) why="a console preview row carries the Pages token" ;; esac
  if [ -z "$why" ]; then
    if ! { command -v gh_auth_armed >/dev/null 2>&1 && gh_auth_armed && [ -x "$HARNESS/bin/gh-token.sh" ]; }; then
      why="App tokens are not armed"
    elif [ -z "${POOL_SLUG:-}" ]; then
      why="no repo slug for $P in fleet.conf"
    fi
  fi
  # The App token must be MINTED (an expiry), never the PAT fallback: the pull
  # bundle has no PAT. The swap block mints again below and gets the cache.
  if [ -z "$why" ]; then
    pool_gh_token --min-life "$POOL_GH_TOKEN_MIN_LIFE" "$POOL_SLUG" >/dev/null 2>&1
    exp=$(pool_gh_token --min-life "$POOL_GH_TOKEN_MIN_LIFE" --expires-at "$POOL_SLUG" 2>/dev/null) || exp=""
    [ -n "$exp" ] || why="no App token"
  fi
  if [ -z "$why" ]; then
    if [ "${POOL_PULL_SLUG,,}" = "${POOL_SLUG,,}" ]; then
      ht=$(pool_gh_token --min-life "$POOL_GH_TOKEN_MIN_LIFE" "$POOL_SLUG" 2>/dev/null) || ht=""
    else
      ht=$(pool_gh_token --extra-read "$POOL_PULL_SLUG" --min-life "$POOL_GH_TOKEN_MIN_LIFE" "$POOL_SLUG" 2>/dev/null) || ht=""
    fi
    ht="${ht%%$'\n'*}"
    if [ -n "$ht" ]; then ( umask 077; printf '%s\n' "$ht" > "$tmp/gh-token-harness" ); else why="no harness read token"; fi
    ht=""
  fi
  if [ -z "$why" ]; then
    local POOL_SEED_DIR="$tmp/seed"
    mkdir -p "$POOL_SEED_DIR" && chmod 700 "$POOL_SEED_DIR"
    push_preplan "the seed" "$k"
    push_reroute "the seed" "$k"
    PULL_NOTE=$(push_build_note_file "the seed" "$k")
    [ -z "$PULL_NOTE" ] || mput "the seed" "$PULL_NOTE" "/run/harness/build-note-$P-$k.md" || why="seed copy failed"
    push_bake_evidence "the seed"
    if [ -s "$HARNESS/state/vercel-deploys/$P.json" ]; then
      mput "the seed" "$HARNESS/state/vercel-deploys/$P.json" "/data/harness/state/vercel-deploys/$P.json" || why="seed copy failed"
    fi
    if [ -s "${POOL_MR_BUNDLE:-}" ]; then
      mput "the seed" "$POOL_MR_BUNDLE" /run/harness-env/model-routes.tsv || why="seed copy failed"
    fi
    mput "the seed" "$tmp/gh-token-harness" /run/harness-env/gh-token-harness || why="seed copy failed"
    mput "the seed" "$jf" /run/harness/job.json || why="seed copy failed"
    # The env lines and tokens join at launch: 8 KB covers them.
    max="${POOL_SEED_MAX_BYTES:-262144}"; case "$max" in ''|*[!0-9]*) max=262144 ;; esac
    bytes=$(find "$POOL_SEED_DIR" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s+8192}')
    [ -n "$why" ] || [ "$bytes" -le "$max" ] || why="seed too big: $bytes bytes over POOL_SEED_MAX_BYTES=$max"
  fi
  [ -z "$why" ] && return 0
  say "$k: push path ($why)"
  rm -rf "$tmp/seed" "$tmp/gh-token-harness"; PULL_NOTE=""
  return 1
}
# pool_pull_skeleton <tmp>: the bundle the swap and lease blocks edit on the
# pull path. global.env carries ONE placeholder line, so the blocks below run
# unchanged and only what they write becomes an override; <p>.env carries the
# slug they read. The machine's base lines come from the HBUNDLE_* secrets.
pool_pull_skeleton() {
  ( umask 077
    printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$POOL_PULL_BASE" > "$1/global.env"
    printf 'REPO_SLUG=%s\n' "$POOL_SLUG" > "$1/$P.env" )
}
# pool_pull_override <global.env> -> the override lines fly/entrypoint.sh
# applies over the base: every line the blocks wrote replaces its key; the
# untouched placeholder means "keep the base token"; a token line the lease
# STRIPPED (a pinned project whose token is missing, bin/lib/pool-account.sh)
# becomes `-CLAUDE_CODE_OAUTH_TOKEN`, which removes the base line.
pool_pull_override() {
  awk -v b="CLAUDE_CODE_OAUTH_TOKEN=$POOL_PULL_BASE" '
    /^CLAUDE_CODE_OAUTH_TOKEN=/ { c = 1; if ($0 == b) next }
    { print }
    END { if (!c) print "-CLAUDE_CODE_OAUTH_TOKEN" }' "$1"
}
# pool_pull_seal <tmp>: NO TOKEN GOES IN THE MACHINE CONFIG. flyctl stores a
# --file-local file as config.files[].raw_value, which `machines list --json`
# returns to anyone with the app's Fly token, also after the machine is gone
# (and bin/fly-idle-reaper.sh, bin/lane-fleet.sh and this file write that
# listing to hub files). So the files that hold a token travel as ONE Fly
# secret-backed file instead: they are tarred, gzipped and base64'd into a
# per-machine app secret SEED_<epoch>_<hex> (imported by stdin, staged, so no
# live machine restarts), and the launch carries `--file-secret
# /run/harness-seed-secret/bundle.b64=SEED_...`; the config then holds only the
# secret's name. fly/entrypoint.sh unpacks it into the RAM-only tmpfs.
# pool_pull_prime's sweep unsets the secret after POOL_SEED_SECRET_TTL_S.
# Sets PULL_SECRET (empty when no file holds a token).
POOL_SEED_SECRET_PATHS="/run/harness-env/global.override.env /run/harness-env/gh-token /run/harness-env/gh-token-read /run/harness-env/gh-token-harness /data/harness/state/auth-accounts.local.json"
POOL_SEED_SECRET_MAX_B64=20000
pool_pull_seal() {
  local sd="$1/seed" rel list=() name bytes
  PULL_SECRET=""
  for rel in $POOL_SEED_SECRET_PATHS; do [ -f "$sd$rel" ] && list+=(".$rel"); done
  [ "${#list[@]}" -gt 0 ] || return 0
  ( umask 077
    tar -C "$sd" -czf "$1/seed-secret.tgz" "${list[@]}" && base64 -w0 "$1/seed-secret.tgz" > "$1/seed-secret.b64" ) || return 1
  bytes=$(stat -c %s "$1/seed-secret.b64" 2>/dev/null) || bytes=0
  if [ "$bytes" -le 0 ] || [ "$bytes" -gt "$POOL_SEED_SECRET_MAX_B64" ]; then
    say "seed secret staging FAILED: the token bundle is $bytes bytes (limit $POOL_SEED_SECRET_MAX_B64)"; return 1
  fi
  name="SEED_$(date +%s)_$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
  # The value goes by stdin (never argv: ps shows argv) and is never echoed.
  if ! { printf '%s=' "$name"; cat "$1/seed-secret.b64"; printf '\n'; } \
       | timeout 60 "$FLY" secrets import --stage -a "$APP" >/dev/null 2>&1; then
    say "seed secret staging FAILED: fly secrets import for $name exited non-zero"; return 1
  fi
  for rel in $POOL_SEED_SECRET_PATHS; do rm -f "$sd$rel"; done
  rm -f "$1/seed-secret.tgz" "$1/seed-secret.b64"
  PULL_SECRET="$name"
}
# pool_pull_args <tmp>: stage the env lines and tokens, then fill PULL_ARGS
# (spawn_one's array) with the -e pins, one --file-local per seed file that
# holds no token and one --file-secret for the files that do.
pool_pull_args() {
  local tmp="$1" POOL_SEED_DIR="$1/seed" f
  ( umask 077; pool_pull_override "$tmp/global.env" > "$tmp/global.override.env" ) || return 1
  mput "the seed" "$tmp/global.override.env" /run/harness-env/global.override.env || return 1
  if [ -s "$tmp/gh-token" ]; then mput "the seed" "$tmp/gh-token" /run/harness-env/gh-token || return 1; fi
  if [ -s "$tmp/gh-token-read" ]; then mput "the seed" "$tmp/gh-token-read" /run/harness-env/gh-token-read || return 1; fi
  if [ -s "$tmp/auth-accounts.local.json" ]; then
    mput "the seed" "$tmp/auth-accounts.local.json" /data/harness/state/auth-accounts.local.json || return 1
  fi
  pool_pull_seal "$tmp" || return 1
  PULL_ARGS=(-e "HARNESS_SHA=$POOL_PULL_SHA" -e "HARNESS_SLUG=$POOL_PULL_SLUG")
  [ -z "${PULL_SECRET:-}" ] || PULL_ARGS+=(--file-secret "/run/harness-seed-secret/bundle.b64=$PULL_SECRET")
  # The row stamp moves to the machine (fly/entrypoint.sh), only where the hub
  # would have made it.
  [ "${ROWS_ONLY:-0}" = 1 ] && PULL_ARGS+=(-e POOL_CLAIM_MACHINE=1)
  while IFS= read -r -d '' f; do
    PULL_ARGS+=(--file-local "/run/harness-seed${f#"$POOL_SEED_DIR"}=$f")
  done < <(find "$POOL_SEED_DIR" -type f -print0 2>/dev/null | sort -z)
  return 0
}
# pool_pull_landed <mid> <key> <tmp>: what the push path does after its pushes,
# for a seeded machine: the snapshot mtime for the reap, the build note consumed.
pool_pull_landed() {
  local n
  n=$(find "$3/seed" -type f 2>/dev/null | grep -c .)
  if [ -e "$3/seed/data/harness/state/vercel-deploys/$P.json" ]; then
    stat -c %Y "$HARNESS/state/vercel-deploys/$P.json" > "$POOL/.$1.snapmt" 2>/dev/null || true
  fi
  [ -z "${PULL_NOTE:-}" ] || build_note_relayed "$1" "$2" "$PULL_NOTE"
  say "$1: seeded $n file(s) for $2 at launch; the machine fetches harness ${POOL_PULL_SHA:0:12} itself"
}
# <<< machine pull

