# shellcheck shell=bash
# bin/lib/docker-pool-host.sh — the functions of the docker-pool host runner
# (bin/docker-pool-runner.sh, BH-7347). The runner runs ON a Docker host (a
# Mac with Docker Desktop), claims ONE queued target='fly' row through the
# docker-pool lease (bin/lib/docker-pool.sh), builds the core of the file set
# bin/fly-pool.sh spawn_one pushes, and runs the builder image in local
# Docker. Contract, knobs and go-live steps:
# docs/notes/2026-10-18-BH-7347-docker-pool-runner.md.
#
#   dph_knob <NAME>                       one knob: settings row > env > default
#   dph_key_ok <key>                      rc 0 for a plain ticket key
#   dph_image <project>                   the builder image ref, or rc 1
#   dph_preflight <project> <key>         rc 0 prints the queued row (TSV);
#                                         rc 1 docker, image or key; rc 2 not queued
#   dph_job_file <p> <key> <dest> <ticket> <attempt> <meta>
#   dph_fileset <p> <key> <work> <tag>    sets DPH_ACCT and DPH_SLUG
#   dph_hold_gate <slug> <ticket> <env>   rc 0 build, rc 9 refuse
#   dph_container_start <p> <key> <work> <tag> <image>   prints the id
#   dph_beat_loop <p> <key> <cid> <work> <lease_until>   sets DPH_OUTCOME
#   dph_finish <p> <key> <cid> <work> <outcome>          rc 0 / 1
#   dph_drop <p> <key> <cid> <work> <outcome>            lost|killed|fenced
#   dph_handoff <rc>                      the TERM/INT trap body, exits <rc>
#   dph_reap_orphans                      prints `<stopped> <kept>`
#   dph_retention                         removes old work dirs
#
# Root: ${HARNESS:-${H:-}}, nothing else. An empty root fails the function.
# Defines functions only. Nothing runs on source.

_DPH_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The string fly/builder-runner.sh logs after run_job, so the cost flush is
# done when it appears (tests/docker-pool-runner.bh-7347-test.sh R12 pins it).
DPH_DONE_LINE='job cycle complete'

_dph_h() { printf '%s' "${HARNESS:-${H:-}}"; }

# _dph_log <text> — one line to logs/docker-pool-runner.log and to stderr.
_dph_log() {
  local h line
  line="$(date -u '+%F %TZ') docker-pool-runner: $*"
  printf '%s\n' "$line" >&2
  h=$(_dph_h); [ -n "$h" ] || return 0
  mkdir -p "$h/logs" 2>/dev/null && printf '%s\n' "$line" >> "$h/logs/docker-pool-runner.log"
}

# dph_knob <NAME> — resolved through the lane gate in a subshell (the sp_knob
# shape, bin/lib/stale-parent.sh): settings row
# lib.docker-pool-host.<name lowercased> > env > the default below, which
# mirrors catalog/lanes.d/_lib.docker-pool-host.json. A value that is not
# valid for its knob is its default.
dph_knob() {
  local name="${1:-}" v
  v=$(
    exec 3>&1
    # shellcheck disable=SC2016 # expanded by the trap, at exit
    trap 'printf "%s" "${!name:-}" >&3' EXIT
    command -v lib_env_apply >/dev/null 2>&1 || . "$_DPH_LIB/lane-gate.sh" >/dev/null 2>&1 || exit 0
    lib_env_apply docker-pool-host >/dev/null 2>&1) || true
  _dph_int() { case "$v" in ''|*[!0-9]*) printf '%s\n' "$1" ;; *) [ "$v" -ge 1 ] && printf '%s\n' "$v" || printf '%s\n' "$1" ;; esac; }
  case "$name" in
    DOCKER_POOL_IMAGE) case "$v" in *[!A-Za-z0-9._/:@-]*) printf '\n' ;; *) printf '%s\n' "$v" ;; esac ;;
    DOCKER_POOL_PLATFORM) case "$v" in ''|*[!A-Za-z0-9/_-]*) printf 'linux/amd64\n' ;; *) printf '%s\n' "$v" ;; esac ;;
    DOCKER_POOL_CPUS) _dph_int 8 ;;
    DOCKER_POOL_MEMORY) [[ $v =~ ^[0-9]+[bkmgBKMG]?$ ]] && printf '%s\n' "$v" || printf '16g\n' ;;
    DOCKER_POOL_ROOT) case "$v" in /*) printf '%s\n' "$v" ;; *) [ -n "$(_dph_h)" ] && printf '%s/state/docker-pool\n' "$(_dph_h)" ;; esac ;;
    DOCKER_POOL_BEAT_S) _dph_int 60 ;;
    DOCKER_POOL_FENCE_S) _dph_int 30 ;;
    DOCKER_POOL_STOP_S) _dph_int 60 ;;
    DOCKER_POOL_MAX_BUILD_S) _dph_int 21600 ;;
    DOCKER_POOL_SMOKE_S) _dph_int 900 ;;
    DOCKER_POOL_KEEP_DAYS) _dph_int 7 ;;
    *) printf '%s\n' "$v" ;;
  esac
}

# dph_key_ok <key> — a plain ticket key. RB-* rows belong to
# bin/merge-conductor.sh (their rebase meta and timeout), SMOKE is the smoke
# verb's own job, and anything outside [A-Za-z0-9._-] never reaches a path.
dph_key_ok() {
  case "${1:-}" in ''|RB-*|SMOKE|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

# dph_image <project> — DOCKER_POOL_IMAGE, else the fly_images row
# (fir_digest), else state/fly/<project>.image. rc 1 when none resolves.
dph_image() {
  local p="${1:-}" h img=""
  h=$(_dph_h)
  img=$(dph_knob DOCKER_POOL_IMAGE)
  if [ -z "$img" ] && [ -n "$h" ]; then
    { declare -F fir_digest >/dev/null || . "$_DPH_LIB/fly-image-row.sh" >/dev/null 2>&1; } \
      && img=$(fir_digest "$p" 2>/dev/null) || img=""
    [ -n "$img" ] || img=$(head -n 1 "$h/state/fly/$p.image" 2>/dev/null)
  fi
  case "$img" in ''|*[!A-Za-z0-9._/:@-]*) return 1 ;; esac
  printf '%s\n' "$img"
}

# dph_preflight <project> <key> — every check before a claim request.
# rc 0 prints the queued row as queue_list prints it (project key ticket
# status target attempt claimed_by enqueued_at reason meta, TSV); rc 1 a bad
# key, docker not answering, no image or no jobs client; rc 2 no queued
# target='fly' row for the key. The key check runs first and sends nothing.
dph_preflight() {
  local p="${1:-}" key="${2:-}" resp line
  case "$p" in ''|*[!A-Za-z0-9._-]*) _dph_log "refused: project '$p' is not a project name"; return 1 ;; esac
  dph_key_ok "$key" || { _dph_log "refused: key '$key' is not a plain ticket key (RB-*, SMOKE and odd characters are refused)"; return 1; }
  docker info >/dev/null 2>&1 || { _dph_log "refused: docker info does not answer on this host"; return 1; }
  dph_image "$p" >/dev/null || { _dph_log "refused: no builder image for $p (DOCKER_POOL_IMAGE, the fly_images row, state/fly/$p.image)"; return 1; }
  declare -F _jobs_req >/dev/null || { _dph_log "refused: no jobs client"; return 1; }
  # The keyed form of queue_list <p> queued fly: the same filters, one row.
  resp=$(_jobs_req GET "/api/queue?project=$p&key=$key&status=queued&target=fly&limit=1") \
    || { _dph_log "$p $key: the queue did not answer"; return 1; }
  line=$(printf '%s' "$resp" | jq -r --arg k "$key" '.queue[]? | select(.ticket_key == $k and .status == "queued" and .target == "fly")
    | [ .project, .ticket_key, (.ticket_id // "-"), .status, .target, (.attempt // 0), (.claimed_by // "-"), (.enqueued_at // "-"),
        ((.reason // "-") | gsub("[\n\t\r]+"; " ")),
        (if (.meta // null) == null then "-" else (if (.meta | type) == "string" then .meta else (.meta | tojson) end | gsub("[\n\t\r]+"; " ")) end) ] | @tsv' 2>/dev/null | head -n 1)
  [ -n "$line" ] || { _dph_log "$p $key: no queued target=fly row"; return 2; }
  printf '%s\n' "$line"
}

# dph_job_file <project> <key> <dest> <ticket> <attempt> <meta> — the pool's
# own row -> job.json mapping (bin/lib/queue-row-job.sh), with the claimed
# ticket and attempt. rc as queue_row_job_file.
dph_job_file() {
  declare -F queue_row_job_file >/dev/null || . "$_DPH_LIB/queue-row-job.sh" || return 1
  QRJ_TAG="docker-pool/${1:-}" queue_row_job_file "${1:-}" "${3:-}" "${2:-}" "${4:-}" "${5:-0}" "${6:-}"
}

# _dph_c2 — source the C2 libs (#7348: cost rows, result rows, token
# rotation) when this tree has them. Their functions are then called behind
# declare -F; absent, the runner says so and goes on.
_dph_c2() {
  local f
  for f in reap token; do
    [ -r "$_DPH_LIB/docker-pool-$f.sh" ] && . "$_DPH_LIB/docker-pool-$f.sh" >/dev/null 2>&1
  done
  return 0
}

# _dph_env_set <file> <NAME> <value> — replace the NAME= line (never append a
# second one: `set -a; . global.env` would use the last). printf builtins
# only, so the value never reaches argv.
_dph_env_set() {
  ( umask 077
    grep -v "^$2=" "$1" 2>/dev/null > "$1.new"
    printf '%s=%s\n' "$2" "$3" >> "$1.new" ) && mv "$1.new" "$1"
}

# dph_fileset <project> <key> <work> <tag> — the core of spawn_one's file set
# (bin/fly-pool.sh, the env bundle through the harness tarball):
#   <work>/env   global.env, <p>.env, gh-token (the container's /run/harness-env)
#   <work>/data/harness   the harness tree, with state/auth-accounts.local.json
#   <work>/gh-token.state expires_at=<ISO> of the App token (C2's rotation)
# Sets DPH_ACCT (the leased account, `default` when none) and DPH_SLUG.
# rc 1: no bundle, no GitHub credential, or no fly/builder-runner.sh shipped.
dph_fileset() {
  local p="${1:-}" key="${2:-}" work="${3:-}" tag="${4:-}" h env ck tgz tok inst exp line kv rc
  local -a app=() paths=()
  h=$(_dph_h); [ -n "$h" ] && [ -n "$work" ] || return 1
  env="$work/env"; DPH_ACCT=default; DPH_SLUG=""
  ( umask 077; mkdir -p "$env" ) && chmod 700 "$env" || return 1
  mkdir -p "$work/run" "$work/data/harness" || return 1
  "$h/bin/fly-envbundle.sh" "$p" "$env" --pool >/dev/null 2>>"$h/logs/docker-pool-runner.log" \
    || { _dph_log "$p $key: env bundle FAILED"; return 1; }
  DPH_SLUG=$(sed -n 's/^REPO_SLUG=//p' "$env/$p.env" 2>/dev/null | head -n 1)
  # A repo-scoped App token instead of the fleet PAT, as spawn_one does.
  { declare -F gh_auth_armed >/dev/null || . "$_DPH_LIB/gh-app-auth.sh" >/dev/null 2>&1; } || true
  if [ -n "$DPH_SLUG" ] && declare -F gh_auth_armed >/dev/null && gh_auth_armed; then
    case "${POOL_GH_APP_PROFILE:-}" in
      ''|hub) ;;
      *) [ -r "$h/env/github-app-$POOL_GH_APP_PROFILE.env" ] && app=(--app "$POOL_GH_APP_PROFILE") ;;
    esac
    tok=$("$h/bin/gh-token.sh" ${app[@]+"${app[@]}"} --min-life 3300 "$DPH_SLUG" 2>/dev/null) || tok=""
    if [ -n "$tok" ]; then
      inst=$("$h/bin/gh-token.sh" ${app[@]+"${app[@]}"} --min-life 3300 --installation-id "$DPH_SLUG" 2>/dev/null) || inst=""
      case "$inst" in *[!0-9]*) inst="" ;; esac
      _dph_env_set "$env/global.env" GH_TOKEN "$tok" || return 1
      if [ -n "$inst" ]; then _dph_env_set "$env/global.env" GH_TOKEN_INSTALLATION_ID "$inst" || return 1; fi
      ( umask 077; printf '%s\n' "$tok" > "$env/gh-token" ) || return 1
      exp=$("$h/bin/gh-token.sh" ${app[@]+"${app[@]}"} --min-life 3300 --expires-at "$DPH_SLUG" 2>/dev/null) || exp=""
      printf 'expires_at=%s\n' "$exp" > "$work/gh-token.state"
      _dph_log "$p $key: repo-scoped App token for $DPH_SLUG (expires ${exp:-?})"
    fi
    tok=""
  fi
  grep -q '^GH_TOKEN=.' "$env/global.env" 2>/dev/null \
    || { _dph_log "$p $key: no App token and no PAT in the bundle: no GitHub credential"; return 1; }
  # The leased claude account (pool_account_lease always exits 0; `default`
  # when unarmed or saturated).
  if { declare -F pool_account_lease >/dev/null || . "$_DPH_LIB/pool-account.sh" >/dev/null 2>&1; } \
     && declare -F pool_account_lease >/dev/null; then
    line=$(pool_account_lease "$p" "$key" "$env/global.env" "$tag" 2>/dev/null)
    for kv in $line; do case "$kv" in name=*) DPH_ACCT="${kv#name=}" ;; esac; done
    [ -n "$DPH_ACCT" ] || DPH_ACCT=default
  fi
  # The account-label overlay: the lease's own, else the hub's.
  mkdir -p "$work/data/harness/state" "$work/data/harness/logs" "$work/data/harness/locks" "$work/data/harness/builds" || return 1
  if [ -s "$env/auth-accounts.local.json" ]; then
    mv "$env/auth-accounts.local.json" "$work/data/harness/state/auth-accounts.local.json"
  elif [ -s "$h/state/auth-accounts.local.json" ]; then
    cp "$h/state/auth-accounts.local.json" "$work/data/harness/state/auth-accounts.local.json"
  fi
  # The harness tree, the paths spawn_one ships, from this host's checkout.
  ck=$(dph_knob DOCKER_POOL_CHECKOUT); [ -n "$ck" ] || ck="${DPH_CHECKOUT_DEFAULT:-}"
  [ -n "$ck" ] && [ -d "$ck" ] || { _dph_log "$p $key: no harness checkout to ship"; return 1; }
  for kv in bin prompts rules catalog fleet.conf fly; do [ -e "$ck/$kv" ] && paths+=("$kv"); done
  { declare -F harness_tarball >/dev/null || . "$_DPH_LIB/harness-tarball.sh"; } || return 1
  tgz="$work/harness.tgz"
  harness_tarball "$tgz" "$ck" "${paths[@]}"; rc=$?
  [ "$rc" = 1 ] && { rm -f "$tgz"; _dph_log "$p $key: harness tarball FAILED"; return 1; }
  [ "$rc" = 2 ] && _dph_log "$p $key: no git HEAD in $ck: the tree ships with no HARNESS_COMMIT stamp"
  tar xzf "$tgz" -C "$work/data/harness" 2>/dev/null; rc=$?
  rm -f "$tgz"
  [ "$rc" = 0 ] && [ -x "$work/data/harness/fly/builder-runner.sh" ] \
    || { _dph_log "$p $key: the harness tree has no fly/builder-runner.sh"; return 1; }
  return 0
}

# dph_hold_gate <slug> <ticket> <env-dir> — the HOLD gate of the pool. A
# numeric ticket is a GitHub issue: hold_check reads it with the minted token.
# clear -> rc 0; held -> rc 9; unreadable -> rc 9 (fail closed). A ticket id
# that is not a number (a board project's row id) has no issue: rc 0.
# Prints the verdict line.
dph_hold_gate() {
  local slug="${1:-}" t="${2:-}" envd="${3:-}" lib v
  case "$t" in ''|-|*[!0-9]*) printf 'clear\tnot a GitHub issue (%s)\n' "${t:--}"; return 0 ;; esac
  lib="${DOCKER_POOL_HOLD_LIB:-$(_dph_h)/bin/lib/hold.sh}"
  v=$( [ -r "$lib" ] && . "$lib" >/dev/null 2>&1 && declare -F hold_check >/dev/null || { printf 'unreadable\tno hold library\n'; exit 0; }
       GH_TOKEN=$(cat "$envd/gh-token" 2>/dev/null)
       [ -n "$GH_TOKEN" ] || GH_TOKEN=$(sed -n 's/^GH_TOKEN=//p' "$envd/global.env" 2>/dev/null | tail -n 1)
       export GH_TOKEN
       hold_check "$slug" "$t" 2>/dev/null | head -n 1 )
  printf '%s\n' "${v:-unreadable	no answer}"
  case "$v" in clear*) return 0 ;; esac
  return 9
}

# dph_container_start <project> <key> <work> <tag> <image> — `docker run -d`
# of the builder image. FLY_MACHINE_ID=<tag> and the hostname make
# fly/entrypoint.sh name the box pool-<p>-<tag>, the same cost-row box C2
# reads. Prints the container id; rc 1 when docker gives none.
dph_container_start() {
  local p="$1" key="$2" work="$3" tag="$4" img="$5" cid
  cid=$(docker run -d --platform "$(dph_knob DOCKER_POOL_PLATFORM)" \
    --name "harness-dpool-$p-$tag" --hostname "pool-$p-$tag" \
    --cpus "$(dph_knob DOCKER_POOL_CPUS)" --memory "$(dph_knob DOCKER_POOL_MEMORY)" \
    -e POOL_MODE=1 -e "PROJECT=$p" -e "FLY_MACHINE_ID=$tag" -e HARNESS_CHECKOUT=/data/harness -e WARMUP_WAIT_S=300 \
    -v "$work/env:/run/harness-env" -v "$work/run:/run/harness" -v "$work/data:/data" \
    --label harness.docker-pool=1 --label "harness.docker-pool.lease=$work/lease" --label "harness.docker-pool.key=$key" \
    "$img" 2>>"$(_dph_h)/logs/docker-pool-runner.log" | tail -n 1)
  [[ $cid =~ ^[0-9a-f]{12,64}$ ]] || return 1
  printf '%s\n' "$cid"
}

# _dph_epoch <iso> — seconds since the epoch, or rc 1 (jq, so it is the same
# on GNU and BSD date).
_dph_epoch() {
  local v
  v=$(jq -rn --arg t "${1%%.*}" '($t | sub("Z$"; "") + "Z") | fromdateiso8601' 2>/dev/null) || return 1
  [[ $v =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$v"
}

# _dph_lease_write <work> <epoch> — tmp + mv, so the work dir's mtime moves
# with every beat (dph_retention never takes a live dir).
_dph_lease_write() { printf '%s\n' "$2" > "$1/.lease.new" && mv "$1/.lease.new" "$1/lease"; }

# dph_state <cid> <work> — the finish check. Prints:
#   done     RESULT non-empty and the done line in the container's log
#   exited   the container is not running (RESULT decides the release)
#   running  anything else, RESULT without the done line included
#   unknown  docker inspect failed (counts toward the fence only)
dph_state() {
  local st n
  st=$(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null) || { echo unknown; return 0; }
  case "$st" in
    exited|dead|removed) echo exited; return 0 ;;
  esac
  if [ -s "$2/run/RESULT" ]; then
    n=$(docker logs --tail 500 "$1" 2>&1 | grep -c "$DPH_DONE_LINE")
    [ "${n:-0}" -gt 0 ] && { echo "done"; return 0; }
  fi
  echo running
}

# dph_beat_loop <project> <key> <cid> <work> <lease_until ISO> — beat until
# the container finishes. Sets DPH_OUTCOME to done | exited | lost | killed |
# fenced | walltime. Not run in $( ): the TERM trap must fire mid-sleep.
dph_beat_loop() {
  local p="$1" key="$2" cid="$3" work="$4" lu beat fence maxs start now left hb rc why st
  DPH_OUTCOME=""
  lu=$(_dph_epoch "$5") || lu=$(( $(date +%s) + 60 ))
  beat=$(dph_knob DOCKER_POOL_BEAT_S); fence=$(dph_knob DOCKER_POOL_FENCE_S); maxs=$(dph_knob DOCKER_POOL_MAX_BUILD_S)
  start=$(date +%s)
  left=$(( (lu - start) / 3 )); [ "$left" -ge 1 ] || left=1
  [ "$beat" -gt "$left" ] && beat=$left
  _dph_lease_write "$work" "$lu"
  _dph_c2
  while :; do
    sleep "$beat" & DPH_SLEEP=$!; wait "$DPH_SLEEP"; DPH_SLEEP=""
    st=$(dph_state "$cid" "$work")
    case "$st" in done|exited) DPH_OUTCOME=$st; return 0 ;; esac
    now=$(date +%s)
    [ $(( now - start )) -ge "$maxs" ] && { DPH_OUTCOME=walltime; return 0; }
    hb=$(docker_pool_heartbeat "$p" "$key" 2>"$work/.hb.err"); rc=$?
    case "$rc" in
      0) if now=$(_dph_epoch "$hb"); then lu=$now; _dph_lease_write "$work" "$lu"; fi ;;
      9) why=$(cat "$work/.hb.err" 2>/dev/null); cat "$work/.hb.err" >&2 2>/dev/null
         case "$why" in *killed*) DPH_OUTCOME=killed ;; *) DPH_OUTCOME=lost ;; esac
         rm -f "$work/.hb.err"; return 0 ;;
      *) now=$(date +%s)
         _dph_log "$p $key: heartbeat failed (rc $rc); the fence is at $(( lu - fence ))"
         [ "$now" -ge $(( lu - fence )) ] && { rm -f "$work/.hb.err"; DPH_OUTCOME=fenced; return 0; } ;;
    esac
    rm -f "$work/.hb.err"
    if [ -n "$DPH_SLUG" ] && declare -F docker_pool_token_rotate >/dev/null; then
      docker_pool_token_rotate "$DPH_SLUG" "$work/env" "$work/gh-token.state" >/dev/null 2>&1 \
        || _dph_log "$p $key: token rotate failed"
    fi
  done
}

# _dph_stop <cid> — docker stop (builder-runner's TERM trap flushes its cost
# rows inside DOCKER_POOL_STOP_S), quiet.
_dph_stop() { [ -n "${1:-}" ] && docker stop -t "$(dph_knob DOCKER_POOL_STOP_S)" "$1" >/dev/null 2>&1; }

# _dph_cleanup <cid> <work> <tag> — docker rm, the account lease back, env/
# and data/ removed (the reap/ dir, lease and gh-token.state stay).
_dph_cleanup() {
  [ -n "${1:-}" ] && docker rm -f "$1" >/dev/null 2>&1
  declare -F pool_account_release >/dev/null && [ -n "${3:-}" ] && pool_account_release "$3" >/dev/null 2>&1
  [ -n "${2:-}" ] && rm -rf "$2/env" "$2/data"
  return 0
}

# dph_finish <project> <key> <cid> <work> <outcome> — stop, copy RESULT,
# job.json and cost.csv to <work>/reap, then with a RESULT: C2's reap and
# release done; with none: release queued. The finish line is written after
# the release returns. rc 0 = RESULT reaped and released done; rc 1 otherwise.
dph_finish() {
  local p="$1" key="$2" cid="$3" work="$4" out="$5" res="-" reap=absent rel rrc cb
  _dph_stop "$cid"
  mkdir -p "$work/reap"
  [ -s "$work/run/RESULT" ] && cp "$work/run/RESULT" "$work/reap/RESULT"
  [ -s "$work/run/job.json" ] && cp "$work/run/job.json" "$work/reap/job.json"
  [ -s "$work/data/harness/logs/cost.csv" ] && cp "$work/data/harness/logs/cost.csv" "$work/reap/cost.csv"
  if [ -s "$work/reap/RESULT" ]; then
    res=$(head -n 1 "$work/reap/RESULT" | awk '{print $1}')
    _dph_c2
    if declare -F docker_pool_reap >/dev/null; then
      cb="${DPH_COST_BOX:-pool-$p-${DPH_TAG:-}}"
      if [ "${DPH_ACCT:-default}" = default ]; then docker_pool_reap "$p" "$key" "$work/reap" "$cb" >/dev/null 2>&1
      else docker_pool_reap "$p" "$key" "$work/reap" "$cb" "$DPH_ACCT" >/dev/null 2>&1; fi
      reap=$?
    else
      _dph_log "$p $key: reap: absent (C2 not on this tree)"
    fi
    rel="done"
    docker_pool_release "$p" "$key" "done" >/dev/null; rrc=$?
  else
    rel=queued
    docker_pool_release "$p" "$key" queued "no RESULT (container $out)" >/dev/null; rrc=$?
  fi
  _dph_cleanup "$cid" "$work" "${DPH_TAG:-}"
  _dph_log "$p $key $out result=$res reap=$reap release=$rel:$rrc"
  [ "$rel" = "done" ] && [ "$rrc" = 0 ] && return 0
  return 1
}

# dph_drop <project> <key> <cid> <work> <outcome> — the lease is gone (lost,
# killed) or cannot be kept (fenced): stop the container and send no release
# (the worker already ended the lease, or cannot be reached). lost and fenced
# write one ALERTS line; killed is an operator's choice and writes none.
dph_drop() {
  local p="$1" key="$2" cid="$3" work="$4" out="$5" h
  _dph_stop "$cid"
  _dph_cleanup "$cid" "$work" "${DPH_TAG:-}"
  _dph_log "$p $key $out: container stopped, no release sent"
  h=$(_dph_h)
  case "$out" in
    lost|fenced)
      [ -x "$h/bin/alert-line.sh" ] && HARNESS="$h" "$h/bin/alert-line.sh" --id "docker-pool-fence-$p-$key" \
        "DOCKER POOL FENCE $p $key on ${JOBS_BOX:-?}: the lease is $out, so the runner stopped the container. The hub sweep puts the row back on the queue." ;;
  esac
  return 0
}

# dph_handoff <rc> — the TERM/INT trap of a run. Stops the beat and the
# container, then releases: done (after the reap) with a RESULT, queued with
# none. Before a claim it only cleans up. Exits <rc>.
dph_handoff() {
  trap - TERM INT
  [ -n "${DPH_SLEEP:-}" ] && kill "$DPH_SLEEP" 2>/dev/null
  if [ -n "${DPH_CLAIMED:-}" ]; then
    _dph_log "${DPH_P:-?} ${DPH_KEY:-?}: signal, hand-off"
    dph_finish "$DPH_P" "$DPH_KEY" "${DPH_CID:-}" "$DPH_WORK" handoff >/dev/null 2>&1
  else
    _dph_cleanup "${DPH_CID:-}" "${DPH_WORK:-}" "${DPH_TAG:-}"
  fi
  exit "${1:-143}"
}

# dph_reap_orphans — stop each running container labeled
# harness.docker-pool=1 whose lease file is past due or missing (its runner
# died). A container without the label is never touched. Prints
# `<stopped> <kept>`.
dph_reap_orphans() {
  local id lf ep now stopped=0 kept=0
  now=$(date +%s)
  while IFS=$'\t' read -r id lf; do
    [ -n "$id" ] || continue
    ep=$(head -n 1 "$lf" 2>/dev/null)
    if [[ $ep =~ ^[0-9]+$ ]] && [ "$ep" -ge "$now" ]; then kept=$((kept + 1)); continue; fi
    _dph_stop "$id"; docker rm -f "$id" >/dev/null 2>&1
    _dph_log "reap-orphans: stopped $id (lease ${ep:-missing})"
    stopped=$((stopped + 1))
  done < <(docker ps --filter label=harness.docker-pool=1 --format '{{.ID}}	{{.Label "harness.docker-pool.lease"}}' 2>/dev/null)
  printf '%s %s\n' "$stopped" "$kept"
}

# dph_retention — the work dirs <root>/<project>/<key>-<tag> older than
# DOCKER_POOL_KEEP_DAYS go. They hold no money row (C2's result row is the
# record); a live dir's lease file moves its mtime on every beat.
dph_retention() {
  local base days
  base=$(dph_knob DOCKER_POOL_ROOT); days=$(dph_knob DOCKER_POOL_KEEP_DAYS)
  [ -n "$base" ] && [ -d "$base" ] || return 0
  find "$base" -mindepth 2 -maxdepth 2 -type d -name '*-dk-*' -mtime +"$days" -exec rm -rf {} + 2>/dev/null
  return 0
}
