# shellcheck shell=bash
# bin/lib/triage-state.d/bh-9555-3-cnr.sh — SOURCED by bin/lib/triage-state.sh.
# A could-not-read seam of the BH-9555 contract (BH-9594). # owner: BH-9555.3
# (BH-10453)
#
# _ts_cnr_skip <session-out> <key>
#   Called first in _ts_record_run, for a triage shard only (one key), inside
#   ts_after_session's scope ($h, $p, $gh). rc 0 means "this session's verdict
#   is a could-not-read skip": the caller writes no decision row and no hash
#   stamp, so the next tick asks again. rc 1 means "a decision": record it as
#   today.
#
#   rc 0 only when the LAST `DECISION:` line of <session-out> that names <key>
#   has the verdict `skip` and cnr_classify_text (bin/lib/could-not-read.sh)
#   calls its reason could-not-read, and the kill row CNR_ENFORCE
#   (lib.could-not-read.cnr_enforce) is not 0. A `build` verdict that says 401
#   stays a decision. A missing or empty out file, no line for <key>, no
#   classifier: rc 1.
#
#   Key match: spaces and a leading `#` are dropped; on a GitHub board ($gh=1)
#   a `<LETTERS>-` prefix is dropped too, so BH-9472, #9472 and 9472 all name
#   key 9472 (canon_key in bin/triage-state.py). A pr-<n> key also matches
#   pr-<n>, #<n> and <n>.
#
#   On rc 0, in this order (the stamp goes back BEFORE the POST, so a hung POST
#   cannot leave a stamp that hides the key):
#     1. triage_shard_fp_clear — the fp stamp bin/lib/rt/shards.sh wrote before
#        the launch;
#     2. triage_shard_rearm — the key leaves the consumed board fingerprint, so
#        the next tick's board diff offers it again;
#     3. cnr_record <cnr_box> <p> gh-app <status> <reason> — one
#        box_read_failures row; its one line goes to logs/<p>.log. <status> is
#        the first 401/403/429/5xx in the reason, else 401 for "bad
#        credentials", 429 for "rate limit", 000 otherwise (a timeout).
_ts_cnr_skip() {
  local f="${1:-}" k="${2:-}" line body who act why last_act="" last_why="" st lc lib
  [ -n "$k" ] && [ -r "$f" ] && [ -s "$f" ] || return 1
  lib="$(dirname "${BASH_SOURCE[0]}")/.."
  if ! command -v cnr_classify_text >/dev/null 2>&1; then
    # shellcheck source=bin/lib/could-not-read.sh
    . "$lib/could-not-read.sh" 2>/dev/null || return 1
  fi
  command -v cnr_classify_text >/dev/null 2>&1 || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in DECISION:*) ;; *) continue ;; esac
    body="${line#DECISION:}"
    case "$body" in *::*) ;; *) continue ;; esac
    who="${body%%::*}"; body="${body#*::}"
    act="${body%%::*}"
    if [ "$act" = "$body" ]; then why=""; else why="${body#*::}"; fi
    who=$(printf '%s' "$who" | tr -d '[:space:]'); who="${who#\#}"
    _ts_cnr_key_is "$who" "$k" "${gh:-0}" || continue
    last_act=$(printf '%s' "$act" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    last_why=$(printf '%s' "$why" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  done < "$f"
  [ "$last_act" = skip ] || return 1
  [ "$(cnr_classify_text "$last_why")" = could-not-read ] || return 1
  # The kill row, read only now: a normal verdict costs no settings read.
  if command -v cnr_enforce_resolve >/dev/null 2>&1 || . "$lib/cnr-retry.sh" 2>/dev/null; then
    cnr_enforce_resolve "${p:-}" >/dev/null 2>&1
  fi
  [ "${CNR_ENFORCE:-1}" = 0 ] && return 1
  command -v triage_shard_fp_clear >/dev/null 2>&1 && triage_shard_fp_clear "${h:-}" "${p:-}" "$k"
  command -v triage_shard_rearm >/dev/null 2>&1 && triage_shard_rearm "${h:-}" "${p:-}" "$k" "${gh:-0}" >/dev/null 2>&1
  lc=$(printf '%s' "$last_why" | tr '[:upper:]' '[:lower:]')
  st=$(printf '%s' "$lc" | grep -oE '(^|[^0-9])(401|403|429|5[0-9][0-9])([^0-9]|$)' | head -1 | grep -oE '[0-9]{3}')
  if [ -z "$st" ]; then
    case "$lc" in
      *"bad credentials"*) st=401 ;;
      *"rate limit"*) st=429 ;;
      *) st=000 ;;
    esac
  fi
  if command -v cnr_record >/dev/null 2>&1 && [ -n "${h:-}" ] && [ -n "${p:-}" ]; then
    cnr_record "$(cnr_box)" "$p" gh-app "$st" "${last_why:0:200}" >> "$h/logs/$p.log" 2>/dev/null || true
  fi
  return 0
}

# _ts_cnr_key_is <said> <key> <gh> — does the DECISION key <said> name <key>?
_ts_cnr_key_is() {
  local s="${1:-}" k="${2:-}" gh="${3:-0}"
  [ -n "$s" ] || return 1
  [ "$s" = "$k" ] && return 0
  case "$k" in
    pr-*)
      case "$s" in pr-*|PR-*|Pr-*) s="${s#*-}" ;; esac
      [ "$s" = "${k#pr-}" ] && return 0 ;;
  esac
  if [ "$gh" = 1 ] && [[ "$s" =~ ^[A-Za-z]+-([0-9]+)$ ]]; then
    [ "${BASH_REMATCH[1]}" = "$k" ] && return 0
  fi
  return 1
}
