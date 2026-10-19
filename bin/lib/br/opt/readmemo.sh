#!/bin/bash
# bin/lib/br/opt/readmemo.sh — the per-run read memo of bin/blocked-resolver.sh
# (BH-5946). Optional module of the BH-1468 seam; see bin/lib/br/opt/README.md.
#
# WHY. Every candidate row runs br_one in its own subshell, so a shell memo dies
# with the row. One keyless head-not-reapproved row read the same
# `repos/<slug>/pulls/<n>` five times before any rung (discovery, the key
# derivation, the merged guard, the human-verdict check), two rows of one
# ticket made the same two merged-PR searches, and a held row read its issue
# thread at the hold recheck and again at the hold gate. A 304 from the ETag
# cache (bin/lib/gh-rest-etag.sh) is still a full HTTP round trip.
#
# WHAT. gh_rest is wrapped. A GET is answered from a file memo for the same run
# when ALL of these hold:
#   - the path is `repos/<slug>/(pulls|issues)/<n>`, `…/issues/<n>/comments[?…]`
#     or `search/issues`, and the extra args carry no `-H` (the iron-law diff
#     read sends an Accept header and stays live);
#   - BR_READMEMO_LIVE is not 0 (br_one sets it to 0 at its dispatch line, so
#     every read a rung makes is live) and GH_ETAG is not 0;
#   - the entry is younger than BR_READMEMO_MAX_AGE_S (default 300 s).
# A hit prints the stored body, sets GH_REST_STATUS to the stored status and
# GH_REST_REASON=memo, and counts `memo-hit`. A miss calls through and stores
# ONLY an rc 0 answer: a 404 or a 75 is asked again. Any other method on
# `repos/<slug>/(pulls|issues)/<n>…` (a comment, a close) drops that PR's
# entries. `pulls/<n>/files`, `/reviews`, `/commits` and `compare` are not
# memoised.
#
# WHERE. ${TMPDIR:-/tmp}/br-read-memo.<pid>: `$$` is the lane's pid inside every
# row subshell, so every row of one run shares it and another run has its own.
# The lane's EXIT trap removes it.
#
# Off: BR_READMEMO=0, BR_READMEMO_MAX_AGE_S=0 or the br-readmemo-off switch
# (lane_switch: a switch.br-readmemo-off row, else flags/br-readmemo-off). Then
# nothing is defined and every hook is a `command -v` miss.

command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply br-repeat-cuts >/dev/null 2>&1
if [ "${BR_READMEMO:-1}" = 0 ] || [ "${BR_READMEMO_MAX_AGE_S:-300}" = 0 ] || [ "${BR_FIX_HERE:-0}" = 1 ] \
   || { command -v lane_switch >/dev/null 2>&1 && lane_switch br-readmemo-off file; }; then
  return 0
fi
if ! declare -F gh_rest >/dev/null 2>&1; then
  declare -F say >/dev/null 2>&1 && say "optional module readmemo: gh_rest is not defined on this box — the read memo is off this run"
  return 0
fi

_br_memo_dir() { printf '%s/br-read-memo.%s' "${TMPDIR:-/tmp}" "$$"; }

# _br_memo_pr_dir <path> — the memo dir of the PR/issue a REST path names, or
# rc 1 when the path names none.
_br_memo_pr_dir() {
  local p="${1%%\?*}" slug n
  [[ "$p" =~ ^repos/([^/]+)/([^/]+)/(pulls|issues)/([0-9]+)(/.*)?$ ]] || return 1
  slug="${BASH_REMATCH[1]}_${BASH_REMATCH[2]}"; n="${BASH_REMATCH[4]}"
  printf '%s/%s#%s' "$(_br_memo_dir)" "${slug//[^A-Za-z0-9._-]/_}" "$n"
}

eval "$(declare -f gh_rest | sed '1s/^gh_rest /_br_memo_gh_rest /')"
gh_rest() {
  local m="${1:-}" p="${2:-}" d a key f age now mt rc
  if [ "$m" != GET ]; then
    d=$(_br_memo_pr_dir "$p") && rm -rf "$d" 2>/dev/null
    _br_memo_gh_rest "$@"; return $?
  fi
  if [ "${BR_READMEMO_LIVE:-1}" = 0 ] || [ "${GH_ETAG:-1}" = 0 ]; then
    _br_memo_gh_rest "$@"; return $?
  fi
  for a in "${@:3}"; do
    [ "$a" = -H ] && { _br_memo_gh_rest "$@"; return $?; }
  done
  if [[ "$p" =~ ^repos/[^/]+/[^/]+/(pulls|issues)/[0-9]+(/comments(\?.*)?)?$ ]]; then
    [[ "$p" =~ ^repos/[^/]+/[^/]+/pulls/[0-9]+/comments ]] && { _br_memo_gh_rest "$@"; return $?; }
    d=$(_br_memo_pr_dir "$p") || { _br_memo_gh_rest "$@"; return $?; }
  elif [ "$p" = search/issues ]; then
    d="$(_br_memo_dir)/search"
  else
    _br_memo_gh_rest "$@"; return $?
  fi
  key=$(printf '%s\0' "$@" | sha1sum 2>/dev/null) || { _br_memo_gh_rest "$@"; return $?; }
  key="${key%% *}"; f="$d/$key"
  if [ -f "$f" ] && [ -f "$f.st" ]; then
    now="${EPOCHSECONDS:-$(date -u +%s)}"
    mt=$(stat -c %Y "$f" 2>/dev/null) || mt=0
    age=$(( now - mt ))
    if [ "$age" -ge 0 ] && [ "$age" -lt "${BR_READMEMO_MAX_AGE_S:-300}" ]; then
      GH_REST_STATUS=$(cat "$f.st" 2>/dev/null); GH_REST_REASON=memo
      # A memo hit made no call, so it has no quota headers: the quota globals
      # read empty (unknown), never the previous live call's values.
      GH_REST_QUOTA_REMAINING=; GH_REST_QUOTA_LIMIT=; GH_REST_QUOTA_RESET=; GH_REST_QUOTA_RETRY_AFTER=
      cat "$f"
      br_count memo-hit
      return 0
    fi
  fi
  rc=0
  mkdir -p "$d" 2>/dev/null || { _br_memo_gh_rest "$@"; return $?; }
  _br_memo_gh_rest "$@" > "$f.tmp.$BASHPID" || rc=$?
  if [ "$rc" = 0 ]; then
    printf '%s' "$GH_REST_STATUS" > "$f.st.tmp.$BASHPID" 2>/dev/null \
      && mv -f "$f.st.tmp.$BASHPID" "$f.st" 2>/dev/null \
      && cp -f "$f.tmp.$BASHPID" "$f" 2>/dev/null
  fi
  cat "$f.tmp.$BASHPID" 2>/dev/null
  rm -f "$f.tmp.$BASHPID" "$f.st.tmp.$BASHPID" 2>/dev/null
  return "$rc"
}

# br_opt_readmemo_drop <pr-url> — forget the PR's entries and every search.
# br_one calls it at its dispatch line and br_close_pr after a close, so a later
# row of the same run reads the PR again.
br_opt_readmemo_drop() {
  local u="${1:-}" d
  if [[ "$u" =~ ^https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
    d=$(_br_memo_pr_dir "repos/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/pulls/${BASH_REMATCH[3]}") && rm -rf "$d" 2>/dev/null
  fi
  rm -rf "$(_br_memo_dir)/search" 2>/dev/null
  return 0
}

# br_opt_readmemo_pr_ref <slug> <num> — "<head sha> <head ref>" through the
# memo, for br_pr_ref. rc 1 when the read did not answer: br_pr_ref then runs
# its own raw two-try read and keeps its own error text.
br_opt_readmemo_pr_ref() {
  local f out
  f=$(mktemp "${TMPDIR:-/tmp}/br-pr-ref.XXXXXX" 2>/dev/null) || return 1
  if gh_rest GET "repos/$1/pulls/$2" > "$f" 2>/dev/null; then
    out=$(jq -r '"\(.head.sha) \(.head.ref)"' "$f" 2>/dev/null) || out=""
  fi
  rm -f "$f"
  [ -n "${out:-}" ] || return 1
  printf '%s\n' "$out"
}
