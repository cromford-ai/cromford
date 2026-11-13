#!/bin/bash
# bin/lib/gh-session-token.sh — the decisions behind bin/gh-session/gh, the gh
# a triage session reaches first on PATH (BH-9354). Sourced, never executed;
# defines functions and runs nothing on source.
#
# WHY. A triage tick mints ONE App token (bin/run-triage.sh, `# >>> triage
# github auth`) and exports it. Every shard and every agent session inherits
# it, and bin/gh-ledger/gh only picks an identity when GH_TOKEN is EMPTY. So a
# token that went bad after the tick started stayed in the session to the end:
# on 2026-11-09 four triage sessions on box-small got `HTTP 401 Bad
# credentials` from gh and gh-rest-shim while the box's own App token and PAT
# answered 200, and the lead reported a dead box token that was not dead.
#
# THE DECISIONS HERE:
#   gh_session_is_401 <rc> <stderr-file>   rc 0 = this gh call got a 401: rc
#       is not 0 AND gh's STDERR (never stdout: an issue body can quote the
#       words) carries `HTTP 401` (not 4010) or `Bad credentials` — the text
#       bin/lib/gh-limit-logger.sh already reads as an auth refusal.
#   gh_session_retry_ok <gh argv…>   rc 0 = the call may run twice. A 401 is
#       a refusal before GitHub did anything, so a write is safe to retry. Not
#       safe: a call that reads stdin (`-`, `@-`, `=-`, `/dev/stdin`), a watch,
#       and `auth` (local, and `gh auth token` is a PAT-ladder rung).
#   gh_session_tok_fp / gh_session_tok_desc   a sha256 prefix to compare
#       tokens, and `<prefix> len <n>` to name one. Never the value.
#   gh_session_knobs   the knobs (catalog/lanes.d/_lib.gh-session.json), read
#       from env with their code defaults. The arming exports them once.
#   gh_session_mint <slug> <min-life|fresh|plain>   one bin/gh-token.sh call,
#       bounded by GH_SESSION_MINT_TIMEOUT_S, with no GH_TOKEN in its env (the
#       minter reads GH_TOKEN as its PAT rung, and that is the bad token).
#   gh_session_pat   env/gh-pat, when GH_SESSION_PAT_FALLBACK is 1.
#   gh_session_probe <real-gh> <slug>   `app=<code> pat=<code>`: GET
#       repos/<slug> on a box App token and on env/gh-pat. 000 = no answer,
#       none = no such credential.
#   gh_session_alert <slug> <chain> <probe>   ONE [gh-session] ALERTS line
#       per slug per GH_SESSION_ALERT_EVERY_S, through gh_app_default_alert.
#
# THE OFF SWITCH is the knob row lib.gh-session.gh_session_remint = 0 (read
# once by the arm, and again by the wrapper from env). There is no flags/ file.
#   gh_session_log_recovered <slug> <bad-desc> <armed-at> <expires-at> <rung>
#       one line in logs/<project>.log after a retry got rc 0.

_gss_h() { printf '%s' "${HARNESS:-${H:-}}"; }
_gss_stamp() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
_gss_host() { hostname 2>/dev/null || uname -n 2>/dev/null || echo box; }

gh_session_is_401() {
  local rc="${1:-1}" err="${2:-}"
  [ "$rc" != 0 ] || return 1
  [ -r "$err" ] || return 1
  grep -Eq 'HTTP 401([^0-9]|$)|Bad credentials' "$err" 2>/dev/null
}

gh_session_retry_ok() {
  local a
  case "${1:-}" in auth|'') return 1 ;; esac
  [ "${1:-} ${2:-}" = "run watch" ] && return 1
  for a in "$@"; do
    case "$a" in
      -|@-|*=-|*=@-|/dev/stdin|*=/dev/stdin|*=@/dev/stdin|--watch|--watch=*) return 1 ;;
    esac
  done
  return 0
}

gh_session_tok_fp() {
  [ -n "${1:-}" ] || { printf 'none'; return 0; }
  printf '%s' "$1" | sha256sum 2>/dev/null | cut -c1-16
}

gh_session_tok_desc() {
  local t="${1:-}" p
  [ -n "$t" ] || { printf 'none'; return 0; }
  case "$t" in *_*) p="${t%%_*}_" ;; *) p="?" ;; esac
  printf '%s len %s' "${p:0:12}" "${#t}"
}

# _gss_int <value> <default> <min> <max> — a whole number in range, else the default.
_gss_int() {
  local v="${1:-}"
  case "$v" in ''|*[!0-9]*) printf '%s' "$2"; return 0 ;; esac
  v=$((10#$v))
  if [ "$v" -lt "$3" ] || [ "$v" -gt "$4" ]; then printf '%s' "$2"; return 0; fi
  printf '%s' "$v"
}

# gh_session_knobs — sets _GSS_REMINT _GSS_MIN_LIFE _GSS_MINT_TO _GSS_PROBE_TO
# _GSS_ALERT_EVERY _GSS_PAT_FB. Each default is the code fallback of its row in
# catalog/lanes.d/_lib.gh-session.json (settings lib.gh-session.<env lowercased>).
gh_session_knobs() {
  # lib.gh-session.gh_session_remint (default 1; 0 = no arming, no re-mint)
  _GSS_REMINT=$(_gss_int "${GH_SESSION_REMINT:-1}" 1 0 1)
  # lib.gh-session.gh_session_min_life_s (default 600)
  _GSS_MIN_LIFE=$(_gss_int "${GH_SESSION_MIN_LIFE_S:-600}" 600 300 3300)
  # lib.gh-session.gh_session_mint_timeout_s (default 15)
  _GSS_MINT_TO=$(_gss_int "${GH_SESSION_MINT_TIMEOUT_S:-15}" 15 1 60)
  # lib.gh-session.gh_session_probe_timeout_s (default 10)
  _GSS_PROBE_TO=$(_gss_int "${GH_SESSION_PROBE_TIMEOUT_S:-10}" 10 1 60)
  # lib.gh-session.gh_session_alert_every_s (default 3600; 0 = every all-401 call)
  _GSS_ALERT_EVERY=$(_gss_int "${GH_SESSION_ALERT_EVERY_S:-3600}" 3600 0 86400)
  # lib.gh-session.gh_session_pat_fallback (default 1; 0 = no env/gh-pat rung)
  _GSS_PAT_FB=$(_gss_int "${GH_SESSION_PAT_FALLBACK:-1}" 1 0 1)
  return 0
}

# gh_session_mint <slug> <min-life|fresh|plain|expires-at> — prints what
# bin/gh-token.sh printed (one line). rc 1 and nothing printed when it printed
# nothing, failed or timed out. GH_SESSION_DEPTH=1 rides the call, so a gh the
# minter runs goes straight past the session wrapper.
gh_session_mint() {
  local slug="${1:-}" how="${2:-min-life}" h out to
  local -a args=()
  h=$(_gss_h)
  [ -n "$slug" ] && [ -n "$h" ] && [ -x "$h/bin/gh-token.sh" ] || return 1
  [ -n "${_GSS_MINT_TO:-}" ] || gh_session_knobs
  case "$how" in
    fresh)      args=(--fresh "$slug") ;;
    plain)      args=("$slug") ;;
    expires-at) args=(--expires-at "$slug") ;;
    *)          args=(--min-life "$_GSS_MIN_LIFE" "$slug") ;;
  esac
  to="$_GSS_MINT_TO"
  [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || export DBUS_SESSION_BUS_ADDRESS=disabled:
  out=$(env -u GH_TOKEN -u GITHUB_TOKEN GH_SESSION_DEPTH=1 GH_LEDGER_NO_APP=1 \
          timeout -k 2 "$to" "$h/bin/gh-token.sh" "${args[@]}" 2>/dev/null) || out=""
  out="${out%%$'\n'*}"
  out="${out//[[:space:]]/}"
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# gh_session_pat — env/gh-pat (bin/lib/gh-app-default.sh's reader), or rc 1.
gh_session_pat() {
  local h
  [ -n "${_GSS_PAT_FB:-}" ] || gh_session_knobs
  [ "$_GSS_PAT_FB" = 1 ] || return 1
  h=$(_gss_h)
  if ! command -v gh_pat_from_file >/dev/null 2>&1; then
    # shellcheck source=bin/lib/gh-app-default.sh
    . "${BASH_SOURCE[0]%/*}/gh-app-default.sh" 2>/dev/null || { [ -n "$h" ] && . "$h/bin/lib/gh-app-default.sh" 2>/dev/null; } || return 1
  fi
  command -v gh_pat_from_file >/dev/null 2>&1 || return 1
  HARNESS="$h" gh_pat_from_file
}

# _gss_status <real-gh> <token> <slug> — the HTTP status of GET repos/<slug> on
# <token>: the status line of `gh api -i`, else 401 when stderr says so, else 000.
_gss_status() {
  local real="$1" tok="$2" slug="$3" out code
  [ -n "${_GSS_PROBE_TO:-}" ] || gh_session_knobs
  out=$(GH_TOKEN="$tok" GH_SESSION_DEPTH=1 GH_LEDGER_DEPTH=1 timeout -k 2 "$_GSS_PROBE_TO" \
          "$real" api -i "repos/$slug" 2>&1 </dev/null) || true
  code=$(sed -n 's/^HTTP\/[0-9.]* \([0-9][0-9][0-9]\).*/\1/p' <<<"$out")
  code="${code%%$'\n'*}"
  if [ -z "$code" ]; then
    if grep -Eq 'HTTP 401([^0-9]|$)|Bad credentials' <<<"$out"; then code=401; else code=000; fi
  fi
  printf '%s' "$code"
}

gh_session_probe() {
  local real="${1:-}" slug="${2:-}" app="none" pat="none" t
  [ -n "$real" ] && [ -n "$slug" ] || { printf 'app=000 pat=000'; return 0; }
  [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || export DBUS_SESSION_BUS_ADDRESS=disabled:
  # an App probe only on an App token: gh-token.sh prints the PAT when a mint fails
  if t=$(gh_session_mint "$slug" plain); then
    case "$t" in ghs_*) app=$(_gss_status "$real" "$t" "$slug") ;; esac
  fi
  t=$(_GSS_PAT_FB=1 gh_session_pat) && pat=$(_gss_status "$real" "$t" "$slug")
  printf 'app=%s pat=%s' "$app" "$pat"
}

# gh_session_verdict <probe> — the sentence the alert and the agent read.
gh_session_verdict() {
  local p=" ${1:-} "
  case "$p" in
    *=200\ *) printf 'The box credentials are valid; the fault is in this session'"'"'s token path. Do not replace the PAT.' ;;
    *=401\ *|*=403\ *|*=404\ *) printf 'The box credentials are also refused.' ;;
    *) printf 'The box probe could not run.' ;;
  esac
}

# gh_session_alert <slug> <chain> <probe> — through gh_app_default_alert
# (bin/lib/gh-app-default.sh), source `gh-session`: one `[gh-session]` ALERTS
# line per slug per GH_SESSION_ALERT_EVERY_S, the stamp in that lib's own
# state/gh-app-default.alerted/gh-session-<slug>. No new state path, no new
# ALERTS writer. Never a token value: <chain> carries prefixes and lengths.
gh_session_alert() {
  local slug="${1:-}" chain="${2:-}" probe="${3:-}" h text
  h=$(_gss_h); [ -n "$h" ] && [ -n "$slug" ] || return 0
  [ -n "${_GSS_ALERT_EVERY:-}" ] || gh_session_knobs
  if ! command -v gh_app_default_alert >/dev/null 2>&1; then
    # shellcheck source=bin/lib/gh-app-default.sh
    . "${BASH_SOURCE[0]%/*}/gh-app-default.sh" 2>/dev/null || . "$h/bin/lib/gh-app-default.sh" 2>/dev/null || return 0
  fi
  command -v gh_app_default_alert >/dev/null 2>&1 || return 0
  text="$(_gss_host) ${GH_SESSION_PROJECT:--} gh 401 on every credential for $slug: tried $chain. Box probe: $probe. $(gh_session_verdict "$probe")"
  # The window is this lib's knob, not GH_APP_DEFAULT_ALERT_EVERY_S.
  HARNESS="$h" _GHAD_ALERT_EVERY="$_GSS_ALERT_EVERY" gh_app_default_alert "$slug" gh-session "$text"
  return 0
}

gh_session_log_recovered() {
  local slug="${1:-}" bad="${2:-}" armed="${3:-}" exp="${4:-}" rung="${5:-}" h p
  h=$(_gss_h); [ -n "$h" ] || return 0
  p="${GH_SESSION_PROJECT:-gh-session}"; p=$(printf '%s' "$p" | tr -c 'A-Za-z0-9._-' '_')
  mkdir -p "$h/logs" 2>/dev/null
  printf '%s [%s] gh-session: recovered 401 for %s on rung %s (refused token %s, armed at %s, expires %s)\n' \
    "$(_gss_stamp)" "${GH_SESSION_PROJECT:--}" "$slug" "$rung" "$bad" "${armed:--}" "${exp:--}" \
    >> "$h/logs/$p.log" 2>/dev/null
  return 0
}
