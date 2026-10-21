# shellcheck shell=bash
# bin/lib/lane-run-warm.sh — the warm clones of a dedicated lane machine
# (BH-7716). Sourced by bin/lane-run-worker.sh when LANE_RUN_WARM_CLONES=1,
# never run. Defines functions only.
#
# The dedicated machine keeps a clone of every fleet repo under
# ${REPOS_ROOT:-/root/repos}/<project> on its volume, so a fix round never
# fails for "no local clone".
#
#   lw_warm_ensure <project>
#       The repo is `bin/fleet-conf.sh <project> repo`. Under
#       `flock -w 120 locks/warm-<project>.lock`, one of:
#         fleet-conf.sh fails (no such project)  rc 75
#         repo `-` or empty                      rc 0, log `no repo`
#         the dir is a symlink                   rc 75, nothing changed
#         the dir is missing                     clone, log `cloned`
#         the dir has no .git (a half clone)     moved to <dir>.broken-<epoch>,
#                                                then clone
#         the dir has .git                       `git fetch -q --prune origin`,
#                                                log `fetched`; a failed fetch
#                                                is rc 0 and logs `kept-stale
#                                                (<first error line>)`: a stale
#                                                clone is not a missing clone
#         the clone or the lock fails            rc 75
#       The clone is `git clone -q --filter=blob:none
#       https://github.com/<slug>.git`. The token is `bin/gh-token.sh --read
#       <slug>`, sent as an http.extraHeader through exported GIT_CONFIG_* env
#       of a subshell (the lrc_sync pattern): never in argv, the URL or a log.
#       GIT_TERMINAL_PROMPT=0. Test seam: LANE_RUN_WARM_URL_BASE replaces
#       `https://github.com` and no token is read. On rc 75, LW_WARM_WHY holds
#       one line that says why. Log lines are `warm ensure <p>: <what>`.
#   lw_warm_refresh
#       lw_warm_ensure for every project of `fleet-conf.sh --projects` that
#       has a repo (<n> counts those), at
#       most once per lane_run.warm_refresh_s (60..3600, fallback 300). The
#       epoch of the last refresh is in state/lane-run-worker/warm-refresh.at
#       (the clock is LANE_RUN_NOW when set). Only one loop of the machine
#       refreshes at a time (flock -n locks/warm-refresh.lock; a busy lock
#       skips). One summary line `warm refresh: <n> repos in <s>s` (plus
#       `, <f> failed` when one failed). Always rc 0.
#
# Log lines go through lw_log (bin/lane-run-worker.sh) when it is defined,
# else to logs/lane-run-worker.log. The root is ${HARNESS:-${H:-}}.

_lw_warm_root() { printf '%s' "${HARNESS:-${H:-}}"; }

_lw_warm_now() {
  if [[ ${LANE_RUN_NOW:-} =~ ^[0-9]+$ ]]; then printf '%s' "$LANE_RUN_NOW"; else date -u +%s; fi
}

_lw_warm_log() {
  if declare -F lw_log >/dev/null; then lw_log "$*"; return 0; fi
  local root; root=$(_lw_warm_root)
  mkdir -p "$root/logs" 2>/dev/null
  echo "$(date -u '+%F %TZ') [lane-run-worker] ${MACHINE:-${FLY_MACHINE_ID:-machine}}: $*" >> "$root/logs/lane-run-worker.log"
}

# _lw_warm_git <slug> <git args...> — git with the repo's token as a header.
_lw_warm_git() {
  local slug="$1" tok=""
  shift
  if [ -z "${LANE_RUN_WARM_URL_BASE:-}" ]; then
    tok=$("$(_lw_warm_root)/bin/gh-token.sh" --read "$slug" 2>/dev/null)
  fi
  (
    if [ -n "$tok" ]; then
      export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader
      GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'x-access-token:%s' "$tok" | base64 -w 0)"
      export GIT_CONFIG_VALUE_0
    fi
    GIT_TERMINAL_PROMPT=0 git "$@"
  )
}

# _lw_warm_err <file> — the first non-empty line of a git stderr file, at most
# 200 bytes, with any URL credential part cut.
_lw_warm_err() {
  grep -m 1 -v '^[[:space:]]*$' "$1" 2>/dev/null | tr -d '\r' | sed -E 's#://[^/@ ]*@#://#g' | head -c 200
}

lw_warm_ensure() {
  local p="${1:-}" root slug dir url ef rc fd
  LW_WARM_WHY=""
  root=$(_lw_warm_root)
  [ -n "$root" ] || { LW_WARM_WHY="no harness root"; return 75; }
  [[ $p =~ ^[A-Za-z0-9._-]{1,64}$ ]] && [[ $p != .* ]] || { LW_WARM_WHY="bad project name"; return 75; }
  if ! slug=$("$root/bin/fleet-conf.sh" "$p" repo 2>/dev/null); then
    LW_WARM_WHY="$p is not in fleet.conf"; _lw_warm_log "warm ensure $p: $LW_WARM_WHY"; return 75
  fi
  case "$slug" in ''|-) _lw_warm_log "warm ensure $p: no repo"; return 0 ;; esac
  [[ $slug =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { LW_WARM_WHY="bad repo '$slug' in fleet.conf"; _lw_warm_log "warm ensure $p: $LW_WARM_WHY"; return 75; }
  dir="${REPOS_ROOT:-/root/repos}/$p"
  url="${LANE_RUN_WARM_URL_BASE:-https://github.com}/$slug.git"
  mkdir -p "$root/locks" "${dir%/*}" 2>/dev/null
  ef=$(mktemp "${TMPDIR:-/tmp}/lw-warm.XXXXXX") || { LW_WARM_WHY="mktemp failed"; return 75; }
  exec {fd}>>"$root/locks/warm-$p.lock" || { rm -f "$ef"; LW_WARM_WHY="cannot open locks/warm-$p.lock"; return 75; }
  if ! flock -w 120 "$fd"; then
    exec {fd}>&-; rm -f "$ef"
    LW_WARM_WHY="locks/warm-$p.lock busy for 120 s"; _lw_warm_log "warm ensure $p: $LW_WARM_WHY"; return 75
  fi
  _lw_warm_ensure_locked "$p" "$slug" "$dir" "$url" "$ef"; rc=$?
  exec {fd}>&-
  rm -f "$ef"
  return "$rc"
}

# _lw_warm_ensure_locked <p> <slug> <dir> <url> <errfile> — the cases, with
# the lock held.
_lw_warm_ensure_locked() {
  local p="$1" slug="$2" dir="$3" url="$4" ef="$5" b
  if [ -L "$dir" ]; then
    LW_WARM_WHY="$dir is a symlink; refused"; _lw_warm_log "warm ensure $p: $LW_WARM_WHY"; return 75
  fi
  if [ -e "$dir/.git" ]; then
    if _lw_warm_git "$slug" -C "$dir" fetch -q --prune origin > /dev/null 2> "$ef"; then
      _lw_warm_log "warm ensure $p: fetched"
    else
      _lw_warm_log "warm ensure $p: kept-stale ($(_lw_warm_err "$ef"))"
    fi
    return 0
  fi
  if [ -e "$dir" ]; then
    b="$dir.broken-$(_lw_warm_now)"
    if ! mv -- "$dir" "$b" 2>/dev/null; then
      LW_WARM_WHY="cannot move the half clone $dir aside"; _lw_warm_log "warm ensure $p: $LW_WARM_WHY"; return 75
    fi
    _lw_warm_log "warm ensure $p: half clone moved to ${b##*/}"
  fi
  if _lw_warm_git "$slug" clone -q --filter=blob:none "$url" "$dir" > /dev/null 2> "$ef" && [ -e "$dir/.git" ]; then
    _lw_warm_log "warm ensure $p: cloned"
    return 0
  fi
  LW_WARM_WHY=$(_lw_warm_err "$ef"); [ -n "$LW_WARM_WHY" ] || LW_WARM_WHY="git clone of $slug failed"
  rm -rf --one-file-system -- "$dir" 2>/dev/null
  _lw_warm_log "warm ensure $p: clone failed ($LW_WARM_WHY)"
  return 75
}

# _lw_warm_refresh_s — lane_run.warm_refresh_s, 60..3600, else 300.
_lw_warm_refresh_s() {
  local v=""
  command -v setting_get >/dev/null 2>&1 && v=$(setting_get lane_run.warm_refresh_s 2>/dev/null | tr -d '[:space:]')
  case "$v" in ''|*[!0-9]*) v=300 ;; esac
  [ "${#v}" -le 4 ] && [ "$((10#$v))" -ge 60 ] && [ "$((10#$v))" -le 3600 ] || v=300
  printf '%s' "$((10#$v))"
}

lw_warm_refresh() {
  local root stamp now last projects p n=0 f=0 t0 fd
  root=$(_lw_warm_root); [ -n "$root" ] || return 0
  stamp="$root/state/lane-run-worker/warm-refresh.at"
  now=$(_lw_warm_now)
  last=$(head -n 1 "$stamp" 2>/dev/null)
  if [[ $last =~ ^[0-9]+$ ]] && [ $((now - last)) -lt "$(_lw_warm_refresh_s)" ]; then return 0; fi
  mkdir -p "$root/locks" "${stamp%/*}" 2>/dev/null
  exec {fd}>>"$root/locks/warm-refresh.lock" || return 0
  if ! flock -n "$fd"; then exec {fd}>&-; return 0; fi
  if ! projects=$("$root/bin/fleet-conf.sh" --projects 2>/dev/null); then
    _lw_warm_log "warm refresh: fleet-conf.sh --projects failed"
    exec {fd}>&-; return 0
  fi
  t0=$(date -u +%s)
  for p in $projects; do
    case "$("$root/bin/fleet-conf.sh" "$p" repo 2>/dev/null)" in ''|-) continue ;; esac
    n=$((n + 1))
    lw_warm_ensure "$p" || f=$((f + 1))
  done
  printf '%s\n' "$now" > "$stamp" 2>/dev/null
  _lw_warm_log "warm refresh: $n repos in $(( $(date -u +%s) - t0 ))s$([ "$f" = 0 ] || printf ', %s failed' "$f")"
  exec {fd}>&-
  return 0
}
