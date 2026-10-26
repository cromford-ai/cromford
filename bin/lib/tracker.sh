#!/bin/bash
# bin/lib/tracker.sh — the tracker contract (BH-4075, wave 2 of BH-3979). One
# set of verbs every ticket tracker answers the same way, so a lane that reads
# or writes a ticket does not need to know whether the project's tickets live
# on GitHub Issues or on the client's in-app board. Each tracker is one adapter
# file under bin/lib/tracker/, and this file only resolves and dispatches.
#
# Sourced, never executed: no `set -e`, no `exit`, no output and no write at
# source time, safe under the caller's `set -u`. Sourcing it twice is inert.
#
#   tracker_adapter <project>           github-issues | board | jira | linear, or rc 1
#   tracker_kind <project>              tracker_adapter, cached per process (below)
#   tracker_load <adapter>              sources bin/lib/tracker/<adapter>.sh, sets TRK_ADAPTER
#   tracker_context <project> [<lane>]  tracker_load + that adapter's TRK_* context
#   tracker_key_prefix <project>        jira/linear only: the ticket key prefix
#   trk_gh_issue_number <project> <key> the GitHub issue number of a KEY, or rc 1/3
#   tracker_list                        JSON array of open tickets (no body/comments)
#   tracker_read <id>                   one normalized ticket (below)
#   tracker_comment <id> <bodyfile>
#   tracker_transition <id> <status>
#   tracker_label_add <id> <label>
#   tracker_label_remove <id> <label>
#   tracker_link_pr <id> <pr-url>
#   tracker_close_out <id> <bodyfile> [<status>]   comment, THEN the terminal status
#   tracker_waiting_on <project> <id>   OK | BLOCKED <reason>, from bin/triage-gate.sh
#
# RETURN CODES, the same table for every adapter:
#   0   ok
#   1   failed (absent ticket, refused write, a 200 that did not take)
#   3   UNSUPPORTED by this tracker; nothing was sent
#   44  label_remove only: the label was not there. Success, kept distinct
#       because bin/lib/fc-issues.sh and bin/lib/rollout-refusal.sh branch on it
#   75  rate-limited / unverifiable, passed through from gh_rest. Retry later;
#       never read it as "absent" (docs/GH-REST.md)
#
# CONTEXT IS VARIABLES THE CALLER SETS, never arguments:
#   TRK_ADAPTER          set by tracker_load
#   TRK_SLUG             github-issues: owner/repo
#   TRK_BOARD_BASE       board: <API base><board prefix>
#   TRK_BOARD_TOKEN      board: the bearer token (only ever on curl's argv)
#   TRK_BOARD_TOKEN_VAR  board: its variable NAME, which is what a log shows
#   TRK_LOG              command log file; empty = no log
#   TRK_ERR              board, linear: where curl's stderr goes; empty = /dev/null
#   TRK_DRY              1 = every WRITE prints `DRYRUN <line>` and sends
#                        nothing, rc 0. Reads (list/read) are always sent.
#   TRK_REQ_FILE         board, linear: where a request body is written;
#                        empty = a temp file removed after the call
#   TRK_LINEAR_TOKEN     linear: the API key (only ever on curl's argv)
#   TRK_LINEAR_TOKEN_VAR linear: its variable NAME, which is what a log shows
#   TRK_LINEAR_TEAM      linear: the team key the list reads
#   TRK_LINEAR_API / TRK_LINEAR_LABEL / TRK_LINEAR_STATES
#                        linear: see bin/lib/tracker/linear.sh; every
#                        TRK_LINEAR_* but the API is what trk_linear_context
#                        <project> sets
#   TRK_STRICT           1 = tracker_waiting_on asks --buildable-strict
#   TRK_JIRA_*           jira: set ONLY by trk_jira_context <project> (the
#                        gateway base, credentials from the project's env file,
#                        the allowlists and mappings from settings rows); see
#                        bin/lib/tracker/jira.sh
#
# THE NORMALIZED TICKET tracker_read prints is one JSON object:
#   {id, key, title, body, status, labels:[names], waitingOn, triageVerdict,
#    url, comments:[{author, body, createdAt, internal}]}
# waitingOn/triageVerdict are a string or JSON null, never "": GitHub has no
# turn and no verdict, so it answers null for both. tracker_list prints an
# array of the same objects without body and comments.
#
# WHICH TRACKER. The D1 settings row `tracker_adapter.<project>` (value
# github-issues|board|jira|linear) wins. No row, or a worker that did not
# answer, falls back to fleet.conf column 4, today's rule: `-` is
# github-issues, any prefix is board. Column 4 never yields jira or linear;
# only a row does. A row naming anything else is refused (rc 1): a typo must
# not route a board project's writes to GitHub.
#
# THE KIND SEAM. A lane asks tracker_kind, never fleet.conf column 4 itself:
# column 4 says `-` for a Linear or Jira project too, and a lane that reads `-`
# as "GitHub" writes `Closes #12` for CRO-12. The answer is cached per process
# in _TRK_KIND_CACHE, one `<live|dry> <project> <kind>` line each, so a dry
# answer never serves a live call. A call in the CURRENT shell warms the cache;
# a call inside `$( … )` reads it but cannot write it back, so a caller that
# loops calls `tracker_kind <p> >/dev/null` once first.
#
# tracker_context <project> [<lane>] prints nothing. rc 0: the adapter is
# loaded and its context is set (github-issues TRK_SLUG; board TRK_BOARD_BASE,
# TRK_BOARD_TOKEN, TRK_BOARD_TOKEN_VAR; jira trk_jira_context; linear
# trk_linear_context). rc 1: TRK_CTX_MISSING is one word, kind | adapter | slug
# | base | token | context. A board with a base and no token keeps
# TRK_BOARD_BASE set, so a dry-run caller can go on. It never sets TRK_LOG,
# TRK_ERR, TRK_DRY or TRK_REQ_FILE: each caller owns those. <lane> names the
# caller on the board-creds ALERTS line.
#
# trk_gh_issue_number <project> <key> is the ONLY place a KEY becomes a GitHub
# issue number. rc 3 and nothing printed unless tracker_kind is github-issues;
# on github-issues, `12` or `<letters>-12` prints 12 (rc 0) and any other
# shape is rc 1. A site that gets rc 1 or 3 posts nothing to GitHub.

: "${TRACKER_ADAPTERS:=github-issues board jira linear}"

# The directory this library was sourced from. BASH_SOURCE[0] inside a
# function is the file that defined it.
_trk_dir() { dirname "${BASH_SOURCE[0]}"; }

# _trk_sq <s> — single-quote for a command log (same as fc_sq in file-children.sh).
_trk_sq() { printf "'%s'" "$(printf '%s' "${1:-}" | sed "s/'/'\\\\''/g")"; }

_trk_registered() {
  local a
  for a in $TRACKER_ADAPTERS; do [ "$a" = "${1:-}" ] && return 0; done
  return 1
}

# _trk_pre — the function prefix of the loaded adapter (trk_<pre>_<verb>).
_trk_pre() {
  case "${TRK_ADAPTER:-}" in
    github-issues) printf gh ;;
    board) printf board ;;
    jira) printf jira ;;
    linear) printf linear ;;
    *) return 1 ;;
  esac
}

# _trk_call <verb> [args…] — dispatch to the loaded adapter. rc 1 with one
# stderr line when no adapter is loaded.
_trk_call() {
  local verb="$1" pre
  shift
  pre=$(_trk_pre) && declare -F "trk_${pre}_$verb" >/dev/null 2>&1 \
    || { printf 'tracker: no adapter loaded for %s (TRK_ADAPTER=%s)\n' "$verb" "${TRK_ADAPTER:-}" >&2; return 1; }
  "trk_${pre}_$verb" "$@"
}

# _trk_logw <line> — every write is logged first (TRK_LOG) and, in a dry run,
# printed as `DRYRUN <line>`. The caller then returns 0 when _trk_dry says so.
_trk_logw() {
  [ -n "${TRK_LOG:-}" ] && printf '%s\n' "$1" >> "$TRK_LOG"
  [ "${TRK_DRY:-0}" = 1 ] && printf 'DRYRUN %s\n' "$1"
  return 0
}
_trk_dry() { [ "${TRK_DRY:-0}" = 1 ]; }

# tracker_adapter <project> — github-issues, board, jira or linear on stdout, rc 0. rc 1 and
# nothing printed for an unknown project, an unreadable fleet.conf, or a row
# whose value is not a registered adapter (one stderr line names the row).
tracker_adapter() {
  local p="${1:-}" root="${HARNESS:-${H:-}}" dir jc v rc=0 a fcs prefix
  [ -n "$p" ] || return 1
  dir=$(_trk_dir)
  jc="$dir/../jobs-client.sh"
  [ -r "$jc" ] || jc="${root:+$root/bin/jobs-client.sh}"
  # In a subshell: the client runs `set -uo pipefail` and exports
  # HARNESS_SECRET, and neither may leak into the caller. A client that
  # refuses to load is the same answer as a worker that is down. NO ROOT, NO
  # ROW: the client's own default root is the live /root/harness, which a lib
  # never reaches (docs/notes/2026-09-26-BH-2613-lib-root-resolution.md), so it
  # is handed this lib's root and not asked at all without one.
  # A DRY RUN READS NO ROW: it makes no call at all (the bh-3494 D1 contract),
  # so it takes the same fleet.conf column-4 answer a down worker gets.
  if _trk_dry; then
    rc=1
  elif [ -n "$root" ] && [ -n "$jc" ] && [ -r "$jc" ]; then
    # shellcheck source=/dev/null
    v=$( HARNESS="$root"; . "$jc" >/dev/null 2>&1 || exit 1; JOBS_ALERT=0 setting_get "tracker_adapter.$p" 2>/dev/null ) || rc=$?
  else
    rc=1
  fi
  if [ "$rc" = 0 ]; then
    for a in $TRACKER_ADAPTERS; do
      [ "$v" = "$a" ] && { printf '%s\n' "$a"; return 0; }
    done
    printf 'tracker: settings row tracker_adapter.%s is %s, not one of: %s\n' "$p" "$(_trk_sq "$v")" "$TRACKER_ADAPTERS" >&2
    return 1
  fi
  # rc 2 (no row) and rc 1 (worker down, no secret, no client) both take the
  # documented fallback: fleet.conf column 4.
  fcs="$dir/../fleet-conf.sh"
  [ -x "$fcs" ] || fcs="${root:+$root/bin/fleet-conf.sh}"
  [ -n "$fcs" ] && [ -x "$fcs" ] || return 1
  prefix=$("$fcs" "$p" board_prefix 2>/dev/null) || prefix=""
  [ -n "$prefix" ] || return 1
  if [ "$prefix" = "-" ]; then printf 'github-issues\n'; else printf 'board\n'; fi
  return 0
}

# tracker_load <adapter> — the adapter beside this file wins, $HARNESS/bin/lib
# is the fallback. rc 1 for an unregistered name or a missing file.
tracker_load() {
  local a="${1:-}" root="${HARNESS:-${H:-}}" f=""
  _trk_registered "$a" || return 1
  if [ -r "$(_trk_dir)/tracker/$a.sh" ]; then f="$(_trk_dir)/tracker/$a.sh"
  elif [ -n "$root" ] && [ -r "$root/bin/lib/tracker/$a.sh" ]; then f="$root/bin/lib/tracker/$a.sh"
  else return 1; fi
  # shellcheck source=/dev/null
  . "$f" || return 1
  TRK_ADAPTER="$a"
  return 0
}

# tracker_kind <project> — tracker_adapter's answer, cached per process (see
# THE KIND SEAM above). rc 1 and nothing printed when tracker_adapter is rc 1;
# a refusal is not cached.
tracker_kind() {
  local p="${1:-}" mode=live m q k
  [ -n "$p" ] || return 1
  _trk_dry && mode=dry
  while read -r m q k; do
    [ "$m" = "$mode" ] && [ "$q" = "$p" ] && [ -n "$k" ] && { printf '%s\n' "$k"; return 0; }
  done <<<"${_TRK_KIND_CACHE:-}"
  k=$(tracker_adapter "$p") || return 1
  _TRK_KIND_CACHE="${_TRK_KIND_CACHE:-}${_TRK_KIND_CACHE:+$'\n'}$mode $p $k"
  printf '%s\n' "$k"
}

# _trk_kind_now <project> — tracker_kind in this shell (so the cache is
# warmed), its answer in _TRK_KIND_NOW. rc 1 when it does not resolve.
_trk_kind_now() {
  _TRK_KIND_NOW=""
  tracker_kind "${1:-}" >/dev/null || return 1
  _TRK_KIND_NOW=$(tracker_kind "${1:-}" 2>/dev/null)
  [ -n "$_TRK_KIND_NOW" ]
}

# _trk_board_context <project> <lane> — the board arm of tracker_context:
# <API base><board prefix> from env/<project>.env (bin/lib/board-creds.sh) and
# fleet.conf column 4, and the token from bin/internal-token-for.sh.
_trk_board_context() {
  local p="$1" lane="$2" root="${HARNESS:-${H:-}}" d fcs itf envd="" envf prefix bvar base=""
  TRK_BOARD_BASE=""; TRK_BOARD_TOKEN=""; TRK_BOARD_TOKEN_VAR=""
  d=$(_trk_dir)
  [ -n "$root" ] || { TRK_CTX_MISSING=base; return 1; }
  if ! command -v harness_env_dir >/dev/null 2>&1; then
    # shellcheck source=bin/lib/env-path.sh
    . "$d/env-path.sh" 2>/dev/null || . "$root/bin/lib/env-path.sh" 2>/dev/null || true
  fi
  command -v harness_env_dir >/dev/null 2>&1 && envd=$(harness_env_dir "$root" 2>/dev/null)
  [ -n "$envd" ] || envd="$root/env"
  envf="$envd/$p.env"
  if ! command -v board_base_var >/dev/null 2>&1; then
    # shellcheck source=bin/lib/board-creds.sh
    . "$d/board-creds.sh" 2>/dev/null || . "$root/bin/lib/board-creds.sh" 2>/dev/null || true
  fi
  # $HARNESS/bin first, as the three board callers this replaces read it; the
  # copy beside this lib is the fallback.
  fcs="$root/bin/fleet-conf.sh"; [ -x "$fcs" ] || fcs="$d/../fleet-conf.sh"
  prefix=$("$fcs" "$p" board_prefix 2>/dev/null) || prefix=""
  if [ -n "$prefix" ] && [ "$prefix" != "-" ] && command -v board_base_var >/dev/null 2>&1 \
     && bvar=$(board_base_var "$p" "$envf" "$lane" 2>/dev/null); then
    base=$(board_env_value "$bvar" "$envf" 2>/dev/null)
    while [ "${base%/}" != "$base" ]; do base="${base%/}"; done
  fi
  [ -n "$base" ] || { TRK_CTX_MISSING=base; return 1; }
  TRK_BOARD_BASE="$base$prefix"
  TRK_BOARD_TOKEN_VAR=$(internal_token_var "$envf" 2>/dev/null) || TRK_BOARD_TOKEN_VAR=""
  # A dry run with no token variable at all asks no one: internal-token-for.sh
  # would write an ALERTS line for a run that sends nothing.
  if [ -n "$TRK_BOARD_TOKEN_VAR" ] || ! _trk_dry; then
    # HARNESS="$root": the token script reads only HARNESS, else its own
    # directory. A caller that set only H would have it read the env and write
    # its ALERTS flag next to this lib, not under the caller's root (BH-7919).
    itf="$root/bin/internal-token-for.sh"; [ -x "$itf" ] || itf="$d/../internal-token-for.sh"
    TRK_BOARD_TOKEN=$(HARNESS="$root" "$itf" "$p" 2>/dev/null) || TRK_BOARD_TOKEN=""
  fi
  [ -n "$TRK_BOARD_TOKEN" ] || { TRK_CTX_MISSING=token; return 1; }
  return 0
}

# tracker_context <project> [<lane>] — see the header. Prints nothing on stdout.
tracker_context() {
  local p="${1:-}" lane="${2:-tracker-context}" root="${HARNESS:-${H:-}}" kind fcs
  TRK_CTX_MISSING=""
  _trk_kind_now "$p" 2>/dev/null || { TRK_CTX_MISSING=kind; return 1; }
  kind="$_TRK_KIND_NOW"
  tracker_load "$kind" || { TRK_CTX_MISSING=adapter; return 1; }
  case "$kind" in
    github-issues)
      TRK_SLUG=""
      fcs="${root:+$root/bin/fleet-conf.sh}"; [ -n "$fcs" ] && [ -x "$fcs" ] || fcs="$(_trk_dir)/../fleet-conf.sh"
      [ -x "$fcs" ] && TRK_SLUG=$("$fcs" "$p" repo 2>/dev/null)
      [ -n "$TRK_SLUG" ] || { TRK_SLUG=""; TRK_CTX_MISSING=slug; return 1; } ;;
    board)
      _trk_board_context "$p" "$lane" || return 1 ;;
    jira)
      trk_jira_context "$p" >/dev/null || { TRK_CTX_MISSING=context; return 1; } ;;
    linear)
      trk_linear_context "$p" >/dev/null || { TRK_CTX_MISSING=context; return 1; } ;;
    *) TRK_CTX_MISSING=kind; return 1 ;;
  esac
  return 0
}

# tracker_key_prefix <project> — the ticket key prefix a jira or linear project
# uses: the Linear team key, or the first write_projects (else read_projects)
# Jira key. rc 1 for any other kind, so a GitHub project keeps its own
# prefix source. Runs the context in a subshell: no TRK_* reaches the caller.
tracker_key_prefix() {
  local p="${1:-}" kind
  _trk_kind_now "$p" 2>/dev/null || return 1
  kind="$_TRK_KIND_NOW"
  case "$kind" in jira|linear) ;; *) return 1 ;; esac
  (
    tracker_context "$p" tracker-key-prefix || exit 1
    if [ "$kind" = linear ]; then
      [ -n "${TRK_LINEAR_TEAM:-}" ] || exit 1
      printf '%s\n' "$TRK_LINEAR_TEAM"
    else
      # shellcheck disable=SC2086 # the lists are validated Jira keys, space-separated
      set -- ${TRK_JIRA_WRITE_PROJECTS:-}
      # shellcheck disable=SC2086 # the same: validated Jira keys, split on purpose
      [ $# -gt 0 ] || set -- ${TRK_JIRA_READ_PROJECTS:-}
      [ $# -gt 0 ] || exit 1
      printf '%s\n' "$1"
    fi
  )
}

# trk_gh_issue_number <project> <key> — see the header.
trk_gh_issue_number() {
  local p="${1:-}" key="${2:-}"
  _trk_kind_now "$p" 2>/dev/null || return 3
  [ "$_TRK_KIND_NOW" = github-issues ] || return 3
  if [[ "$key" =~ ^[0-9]+$ ]]; then printf '%s\n' "$key"; return 0; fi
  if [[ "$key" =~ ^[A-Za-z]+-([0-9]+)$ ]]; then printf '%s\n' "${BASH_REMATCH[1]}"; return 0; fi
  return 1
}

tracker_list()         { _trk_call list "$@"; }
tracker_read()         { _trk_call read "$@"; }
tracker_comment()      { _trk_call comment "$@"; }
tracker_transition()   { _trk_call transition "$@"; }
tracker_label_add()    { _trk_call label_add "$@"; }
tracker_label_remove() { _trk_call label_remove "$@"; }
tracker_link_pr()      { _trk_call link_pr "$@"; }
tracker_close_out()    { _trk_call close_out "$@"; }

# tracker_waiting_on <project> <id> — ONE implementation for every adapter: the
# answer bin/triage-gate.sh --buildable gives (--buildable-strict when
# TRK_STRICT=1), printed verbatim. Never a second copy of buildable_gate: that
# is how the "needs_clarification + waiting on the client" rule drifts. rc 1
# when the gate is missing or answered anything but OK / BLOCKED <reason>.
tracker_waiting_on() {
  local p="${1:-}" id="${2:-}" root="${HARNESS:-${H:-}}" gate mode=--buildable line
  [ -n "$p" ] && [ -n "$id" ] || return 1
  gate="$(_trk_dir)/../triage-gate.sh"
  [ -x "$gate" ] || gate="${root:+$root/bin/triage-gate.sh}"
  [ -n "$gate" ] && [ -x "$gate" ] || return 1
  [ "${TRK_STRICT:-0}" = 1 ] && mode=--buildable-strict
  line=$("$gate" "$p" "$mode" "$id" 2>/dev/null)
  line="${line%%$'\n'*}"
  case "$line" in
    OK|"BLOCKED "*) printf '%s\n' "$line"; return 0 ;;
  esac
  [ -n "$line" ] && printf 'tracker: triage-gate answered %s, not OK/BLOCKED\n' "$(_trk_sq "$line")" >&2
  return 1
}
