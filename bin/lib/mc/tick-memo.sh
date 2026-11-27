# shellcheck shell=bash
# bin/lib/mc/tick-memo.sh — THE TICK MEMO (BH-10316, slice 3 of BH-10257).
# Sourced by the conductor fragment bin/merge-conductor.d/bh-10316-tick-memo.sh,
# never executed, no side effect at source time. A lib file and not the
# fragment itself because mc_tm_arm wraps gh_rest and gh, and a fragment may not
# define a name the driver's libs define (tests/merge-conductor-frags.bh-7453-test.sh).
# Not a module of bin/lib/mc/MODULES: nothing but that fragment loads it.
#
# WHY. On the hub (2026-11-27 00:00-00:30Z) one PR visit made about 7.7 GitHub
# calls, and 3.8 of them read the SAME review list (`pulls/<n>/reviews`): the
# block gate's thread read (bg_read), its CHANGES_REQUESTED check
# (bg_cr_standing, also run by mc_cr_dequeue) and the READY arm's CI-block body
# read (_mc_bci_head_review_body). `pulls/<n>` was read about 2 times
# (mc_rest_pr_json under mc_pr_view, bg_cr_standing's base read).
#
# WHAT. Two reads keep their answer for the rest of ONE tick:
#   mc_tm_reviews <outfile> <slug> <num> <head|->
#       The whole review list of the PR as ONE JSON array (every page, through
#       _gh_rest_list of bin/lib/gh-rest-list.sh, so the rc is gh_rest's 0, 44
#       or 75 and a failed page fails the whole read). A list cut at that
#       reader's ten-page stop (1000 rows) is 75: the newest reviews would be
#       missing, and `--paginate` had no stop. One entry per head
#       (reviews.<head>, one file written by rename): a call with another head
#       reads GitHub. "-" = the caller has no head; it takes an entry of any
#       head.
#   mc_tm_pull <outfile> <slug> <num>
#       The `pulls/<n>` body, through gh_rest GET (mc_rest_pr_json's call).
#   GH_REST_STATUS/GH_REST_REASON are gh_rest's on a miss. On a hit they are
#   200/memo, and GH_REST_MESSAGE and the GH_REST_QUOTA_* globals are empty (no
#   call was made, so no quota was read: readmemo.sh's rule).
#   Both return the read's rc. ONLY an rc 0 answer with a parseable body is
#   stored (the reviews body a JSON array, the pulls body an object with a
#   head object). A failed, rate-limited, empty or unparseable read is never
#   stored: the next step reads GitHub again. Slice 2's PR-record reads stay in
#   front of these; the memo sits under them, on the GitHub side.
#
# CLEARED BY EVERY CONDUCTOR WRITE. mc_tm_arm wraps gh_rest and gh in this
# process (the readmemo pattern of bin/lib/br/opt/readmemo.sh). A gh_rest call
# that is not a GET, and a gh call that is not a read (`api` with a method other
# than GET or with a body; `pr`/`issue` verbs other than view, list, status,
# diff and checks), clears after the call:
#   repos/<o>/<r>/(pulls|issues)/<n>[/...], or a PR url / `-R <o>/<r> <n>` -> that PR
#   any other repos/<o>/<r>/... path                                 -> that repo
#   anything it cannot bind                                          -> every entry
# gh is wrapped only when it is already a function (bin/lib/gh-limit-logger.sh,
# which the driver loads whenever a gh binary exists): a new gh function would
# turn off gh_rest's GH_REST_TIMEOUT_S bound (bin/lib/gh-rest.sh). gh_rest is
# wrapped in every case.
# A write in flight beside a read (another worker writes to this PR while its
# read runs): every forget bumps a generation counter (the size of
# <dir>/.gen), and a read stores its answer only when the counter did not move
# during the read.
# A push is a write that gh does not see: mc_rebase and mc_restack call
# mc_tm_forget after hold_push (bin/lib/mc/rebase.sh). A head move the
# conductor detects clears too: a `pulls/<n>` answer at another head than the
# PR's last one, and mc_tm_note_head (mc_pr_live_head's live read).
#
# READS BEFORE A WRITE ARE LIVE. A step that decides a merge, an enqueue or an
# un-park calls mc_tm_forget for the PR first, so it reads GitHub, never an
# answer from earlier in the tick: the pre-merge state guard (`mc_step
# state-guard`, so the block gate after it too), the re-queue CHANGES_REQUESTED
# check of a dequeued READY row (bin/merge-conductor.sh) and the self-enqueue's
# block gate (bin/lib/autoenqueue.sh). The memo saves the reads of the steps
# before them.
#
# WHERE. A dir made by mc_tm_arm with mktemp -d under ${TMPDIR:-/tmp}
# (mc-tick-memo.XXXXXX), never under state/ or flags/. _mc_tm_dir is a
# plain shell variable, NOT exported: every project subshell, PR worker and
# `$( )` of this tick inherits it, and no child process (a detached lane runs a
# new bash) ever sees it, so nothing outside this tick reads or writes the dir.
# The memo is FILES, not shell variables, because most of the reads run inside
# `$( )` (mc_pr_view, bg_scan's reads) and a variable set there dies with the
# subshell. One dir per PR (<slug>#<n>) under it; each worker owns its PR's
# dir, and an entry is written to a temp name and moved into place. The
# driver's EXIT trap removes the dir. On a tick killed with SIGKILL the dir
# stays; mc_tm_arm removes such dirs over a day old.
#
# ONE LINE PER TICK. mc_tm_report logs `TICK-MEMO tick=<id> hits=<n>
# misses=<n>` after the fan-out. No line per call.
#
# OFF. MC_TICK_MEMO=0 (settings row lane.merge-conductor.mc_tick_memo,
# catalog/lanes.d/merge-conductor.knobs.d/MC_TICK_MEMO.json; default 1):
# mc_tm_arm makes no dir and wraps nothing, mc_tm_on is false, and every
# caller makes the read of today. A lane other than the conductor never arms
# it, so the shared libs (bin/lib/block-gate.sh) read as before there.

# The paged reader mc_tm_reviews uses. The conductor has it already
# (bin/lib/mc/queue.sh sources it); a fragment sourced alone loads it here.
# shellcheck source=bin/lib/gh-rest-list.sh
command -v _gh_rest_list >/dev/null 2>&1 || { [ -r "${BASH_SOURCE[0]%/*}/../gh-rest-list.sh" ] && . "${BASH_SOURCE[0]%/*}/../gh-rest-list.sh"; }

# mc_tm_on — rc 0 when the memo is armed for this tick.
mc_tm_on() {
  [ "${MC_TICK_MEMO:-1}" != 0 ] && [ -n "${_mc_tm_dir:-}" ] && [ -d "$_mc_tm_dir" ]
}

# _mc_tm_pr_dir <slug> <num> — the PR's entry dir (lower case slug).
_mc_tm_pr_dir() {
  local s="${1,,}"
  printf '%s/%s#%s' "$_mc_tm_dir" "${s//[^a-z0-9._-]/_}" "${2//[^0-9]/}"
}

# _mc_tm_count <h|m> — one hit or miss, for mc_tm_report.
_mc_tm_count() { printf '%s\n' "$1" >> "$_mc_tm_dir/.count" 2>/dev/null; return 0; }

# _mc_tm_gen — the generation: the byte size of <dir>/.gen, one byte a forget.
# An O_APPEND write of one byte is atomic across the tick's workers.
_mc_tm_gen() { local n; n=$(wc -c < "$_mc_tm_dir/.gen" 2>/dev/null) || n=0; echo "${n//[^0-9]/}"; }
_mc_tm_bump() { printf 'x' >> "$_mc_tm_dir/.gen" 2>/dev/null; return 0; }

# _mc_tm_hit_status — a hit made no call: 200/memo, no message, no quota.
_mc_tm_hit_status() {
  GH_REST_STATUS=200; GH_REST_REASON=memo; GH_REST_MESSAGE=
  GH_REST_QUOTA_REMAINING=; GH_REST_QUOTA_LIMIT=; GH_REST_QUOTA_RESET=; GH_REST_QUOTA_RETRY_AFTER=
}

# mc_tm_forget <slug> <num> — drop every entry of the PR.
mc_tm_forget() {
  mc_tm_on || return 0
  _mc_tm_bump
  rm -rf -- "$(_mc_tm_pr_dir "$1" "$2")" 2>/dev/null
  return 0
}

# _mc_tm_forget_repo <slug> / _mc_tm_forget_all — drop a repo's entries / all.
_mc_tm_forget_repo() {
  local s="${1,,}"
  mc_tm_on || return 0
  _mc_tm_bump
  rm -rf -- "$_mc_tm_dir/${s//[^a-z0-9._-]/_}#"* 2>/dev/null
  return 0
}
_mc_tm_forget_all() {
  mc_tm_on || return 0
  _mc_tm_bump
  rm -rf -- "$_mc_tm_dir/"*'#'* 2>/dev/null
  return 0
}

# mc_tm_note_head <slug> <num> <head> — a head the conductor read live. Another
# head than the PR's recorded one is a head move: the PR's entries go.
mc_tm_note_head() {
  local d old
  mc_tm_on || return 0
  [ -n "${3:-}" ] || return 0
  d=$(_mc_tm_pr_dir "$1" "$2")
  old=$(cat "$d/head" 2>/dev/null) || old=""
  if [ -n "$old" ] && [ "$old" != "$3" ]; then mc_tm_forget "$1" "$2"; fi
  return 0
}

# _mc_tm_write_path <api path> — clear what a write to <api path> can change.
_mc_tm_write_path() {
  local p="${1#/}"
  p="${p%%\?*}"
  if [[ "$p" =~ ^repos/([^/]+/[^/]+)/(pulls|issues)/([0-9]+)(/|$) ]]; then
    mc_tm_forget "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
  elif [[ "$p" =~ ^repos/([^/]+/[^/]+)(/|$) ]]; then
    _mc_tm_forget_repo "${BASH_REMATCH[1]}"
  else
    _mc_tm_forget_all
  fi
}

# _mc_tm_gh_write <gh argv...> — after a gh call: clear what a write changed.
# A read (the list below) clears nothing.
_mc_tm_gh_write() {
  local a m="" body=0 path="" skip=0 repo="" num="" verb
  mc_tm_on || return 0
  case "${1:-}" in
    api)
      shift
      for a in "$@"; do
        if [ "$skip" = m ]; then m="$a"; skip=0; continue; fi
        if [ "$skip" = 1 ]; then skip=0; continue; fi
        case "$a" in
          -X|--method) skip=m ;;
          -X*) m="${a#-X}" ;;
          --method=*) m="${a#--method=}" ;;
          -f|-F|--field|--raw-field|--input) body=1; skip=1 ;;
          -H|--header|-q|--jq|-t|--template|--hostname|-p|--preview|--cache) skip=1 ;;
          -*) ;;
          *) [ -n "$path" ] || path="$a" ;;
        esac
      done
      [ -n "$m" ] || { if [ "$body" = 1 ]; then m=POST; else m=GET; fi; }
      [ "${m^^}" = GET ] && return 0
      _mc_tm_write_path "$path" ;;
    pr|issue)
      verb="${2:-}"
      case "$verb" in view|list|status|diff|checks) return 0 ;; esac
      shift 2 2>/dev/null
      for a in "$@"; do
        if [ "$skip" = 1 ]; then repo="$a"; skip=0; continue; fi
        case "$a" in
          https://github.com/*/*/pull/[0-9]*|https://github.com/*/*/issues/[0-9]*)
            [[ "$a" =~ ^https://github\.com/([^/]+/[^/]+)/(pull|issues)/([0-9]+) ]] \
              && { mc_tm_forget "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"; return 0; } ;;
          -R|--repo) skip=1 ;;
          --repo=*) repo="${a#--repo=}" ;;
          [0-9]*) [ -n "$num" ] || num="${a//[^0-9]/}" ;;
        esac
      done
      if [ -n "$repo" ] && [ -n "$num" ]; then mc_tm_forget "$repo" "$num"; else _mc_tm_forget_all; fi ;;
    auth|search|status|version|--version|help) ;;
    run|workflow)
      case "${2:-}" in view|list|watch) ;; *) _mc_tm_forget_all ;; esac ;;
    *) _mc_tm_forget_all ;;
  esac
  return 0
}

# mc_tm_arm — make the tick's dir and wrap gh_rest and gh. Once per tick, in
# the driver's main shell before the fan-out.
mc_tm_arm() {
  local t="${TMPDIR:-/tmp}"
  [ "${MC_TICK_MEMO:-1}" != 0 ] || return 0
  [ -z "${_mc_tm_dir:-}" ] || return 0
  find "$t" -mindepth 1 -maxdepth 1 -type d -name 'mc-tick-memo.*' -mmin +1440 -exec rm -rf {} + 2>/dev/null
  _mc_tm_dir=$(mktemp -d "$t/mc-tick-memo.XXXXXX" 2>/dev/null) || { _mc_tm_dir=""; return 0; }
  if declare -F gh_rest >/dev/null && ! declare -F _mc_tm_gh_rest >/dev/null; then
    eval "$(declare -f gh_rest | sed '1s/^gh_rest /_mc_tm_gh_rest /')"
    gh_rest() {
      local _mtr=0
      _mc_tm_gh_rest "$@" || _mtr=$?
      [ "${1:-}" = GET ] || _mc_tm_write_path "${2:-}"
      return "$_mtr"
    }
  fi
  if ! declare -F _mc_tm_gh_inner >/dev/null && declare -F gh >/dev/null; then
    eval "$(declare -f gh | sed '1s/^gh /_mc_tm_gh_inner /')"
    if declare -F _mc_tm_gh_inner >/dev/null; then
      gh() {
        local _mtg=0
        _mc_tm_gh_inner "$@" || _mtg=$?
        _mc_tm_gh_write "$@"
        return "$_mtg"
      }
    fi
  fi
  return 0
}

# mc_tm_reviews <outfile> <slug> <num> <head|-> — the review list (WHAT).
mc_tm_reviews() {
  local out="$1" slug="$2" num="$3" head="${4:--}" d="" f="" e tmp rc=0 g0="" n
  head="${head,,}"; head="${head//[^a-z0-9-]/}"; [ -n "$head" ] || head=-
  [ -n "$out" ] || return 75
  if mc_tm_on; then
    d=$(_mc_tm_pr_dir "$slug" "$num"); f="$d/reviews.$head"
    if [ "$head" = - ]; then
      for e in "$d"/reviews.*; do [ -f "$e" ] && { f="$e"; break; }; done
    fi
    if [ -f "$f" ] && cp -f "$f" "$out" 2>/dev/null; then
      _mc_tm_hit_status; _mc_tm_count h; return 0
    fi
    f="$d/reviews.$head"
    _mc_tm_count m
    g0=$(_mc_tm_gen)
  fi
  command -v _gh_rest_list >/dev/null 2>&1 || return 75
  tmp=$(mktemp "${TMPDIR:-/tmp}/mc-tm-rv.XXXXXX" 2>/dev/null) || return 75
  # Every page, through bin/lib/gh-rest-list.sh: a failed page is the whole
  # read's rc. 1000 is that reader's own ten-page stop; a list that reaches it
  # may be cut, so it is unreadable here (75), never a whole list.
  _gh_rest_list "$slug" "pulls/$num/reviews" 1000 '.' > "$tmp" || rc=$?
  if [ "$rc" != 0 ]; then rm -f "$tmp"; return "$rc"; fi
  n=$(jq -e 'if type == "array" then length else error("not a list") end' "$tmp" 2>/dev/null) || { rm -f "$tmp"; return 75; }
  if [ "${n:-0}" -ge 1000 ]; then rm -f "$tmp"; GH_REST_REASON=empty; return 75; fi
  cp -f "$tmp" "$out" 2>/dev/null || { rm -f "$tmp"; return 75; }
  if [ -n "$g0" ] && mc_tm_on && [ "$(_mc_tm_gen)" = "$g0" ] && mkdir -p "$d" 2>/dev/null; then
    mv -f "$tmp" "$f" 2>/dev/null
  fi
  rm -f "$tmp" 2>/dev/null
  return 0
}

# mc_tm_pull <outfile> <slug> <num> — the pulls/<n> body (WHAT).
mc_tm_pull() {
  local out="$1" slug="$2" num="$3" d="" f="" tmp rc=0 sha g0=""
  [ -n "$out" ] || return 75
  if mc_tm_on; then
    d=$(_mc_tm_pr_dir "$slug" "$num"); f="$d/pull"
    if [ -f "$f" ] && cp -f "$f" "$out" 2>/dev/null; then
      _mc_tm_hit_status; _mc_tm_count h; return 0
    fi
    _mc_tm_count m
    g0=$(_mc_tm_gen)
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/mc-tm-pr.XXXXXX" 2>/dev/null) || return 75
  gh_rest GET "repos/$slug/pulls/$num" > "$tmp" || rc=$?
  cat "$tmp" > "$out" 2>/dev/null
  if [ "$rc" = 0 ] && [ -n "$g0" ] && mc_tm_on && [ "$(_mc_tm_gen)" = "$g0" ] \
     && sha=$(jq -er 'select(type == "object" and (.head | type) == "object") | .head.sha // ""' "$tmp" 2>/dev/null); then
    mc_tm_note_head "$slug" "$num" "$sha"
    if mkdir -p "$d" 2>/dev/null; then
      [ -n "$sha" ] && printf '%s' "$sha" > "$d/head.$BASHPID" 2>/dev/null && mv -f "$d/head.$BASHPID" "$d/head" 2>/dev/null
      mv -f "$tmp" "$f" 2>/dev/null
    fi
  fi
  rm -f "$tmp" 2>/dev/null
  return "$rc"
}

# mc_tm_report — the tick's one line (ONE LINE PER TICK). Main shell, after
# the fan-out.
mc_tm_report() {
  local h=0 m=0
  mc_tm_on || return 0
  if [ -f "$_mc_tm_dir/.count" ]; then
    h=$(grep -cx h "$_mc_tm_dir/.count" 2>/dev/null); m=$(grep -cx m "$_mc_tm_dir/.count" 2>/dev/null)
  fi
  mc_log "TICK-MEMO tick=${MC_TICK_ID:-notick} hits=${h:-0} misses=${m:-0}"
  return 0
}
