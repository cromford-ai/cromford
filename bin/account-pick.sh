#!/bin/bash
# bin/account-pick.sh <stage> <vendor> <model> | --overage-ok <account> — WHICH ACCOUNT pays for this call.
#
# Quota-aware account routing (the operator, 2026-09-06). A box can hold N accounts of a
# vendor — env/accounts.d/<name>.env, one file per account — and this script says
# which one a given stage call should run on: the one with headroom, sticky to the
# build so the prompt cache stays warm. Full runbook: docs/ACCOUNT-ROUTING.md.
#
# DEFAULT OFF, AND THE OFF PATH IS THE POINT. bin/agent-call.sh only calls this
# when ACCOUNT_ROUTING=1, and with no registry at all this answers `name=default`
# with ZERO export/unset lines — so turning the flag on before any account exists
# changes nothing about the env the CLI runs with. Nothing here chooses a MODEL;
# it chooses which account pays for the model the stage already asked for.
#
# Sourced as a library too (quota-poll.sh, quota-status.sh) for accounts_load();
# the main body below only runs when this file is executed directly.
#
# State it reads and writes, under state/quota/:
#   <account>.json                  the meter bin/quota-poll.sh writes
#   pins/<key>                      the sticky per-build pin
#   cooldown/<vendor>/<account>     "this VENDOR's account refused us at <epoch>"
#   cooldown/.legacy/<account>      an unscoped cooldown from before BH-940,
#                                   moved aside once and never read again
#
# stdout on exit 0, in order:
#   name=<account>            the pick ("default" = today's global.env credentials)
#   reason=pinned|priority|tie_5h|only|default
#   label=<human label>       omitted for default and for accounts with no ACCOUNT_LABEL
#   export VAR=<%q-quoted>    the account's credential vars ...
#   unset VAR                 ... and every OTHER credential var of that vendor
# The export/unset pair is deliberate: the claude CLI prefers an env
# CLAUDE_CODE_OAUTH_TOKEN over a CLAUDE_CONFIG_DIR login (that shadowing is what
# killed extra-usage-track.sh for five days), so "the child's credential env for
# this vendor is exactly what the account file says" is the only safe contract.
# The caller eval's these inside a SUBSHELL around the child; the parent env is
# never touched.
#
# Exit codes: 0 pick made · 2 no account of this vendor has headroom (the caller
# steps down its survival ladder immediately rather than burning a failed call)
# · 3 usage error.
set -uo pipefail

HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
# The fleet cooldown seam (BH-2355). Guarded: a half-synced box or a scratch
# tree without the lib keeps today's box-local cooldowns exactly.
. "$(dirname "${BASH_SOURCE[0]}")/lib/fleet-cooldown.sh" 2>/dev/null || . "$HARNESS/bin/lib/fleet-cooldown.sh" 2>/dev/null || true
ACCOUNTS_DIR="${ACCOUNTS_DIR:-$HENV/accounts.d}"
QUOTA_DIR="${QUOTA_DIR:-$HARNESS/state/quota}"
ROUTING_LOG="${ACCOUNT_ROUTING_LOG:-$HARNESS/logs/account-routing.log}"

# Every threshold and window is env-driven with a documented default; none of
# them is a bare constant in the logic below (iron law: DB/config-driven
# assumptions — on this box "config" is env/global.env).
ACCOUNT_5H_MAX="${ACCOUNT_5H_MAX:-85}"
ACCOUNT_WEEK_MAX="${ACCOUNT_WEEK_MAX:-90}"
ACCOUNT_MODEL_MAX="${ACCOUNT_MODEL_MAX:-90}"
# The overage meter's own ceiling (BH-1456). An account billing extra usage is
# not capped by its SUBSCRIPTION windows any more — it is capped by its extra
# usage spend limit, and this is how close to that limit we still route to it.
# 97 rather than 100: the endpoint's number is minutes stale by construction.
ACCOUNT_EXTRA_MAX="${ACCOUNT_EXTRA_MAX:-97}"
# How long an account that refused us WHILE IN OVERAGE is skipped for. Short on
# purpose: a 6-hour park is right for "this subscription is spent until it
# resets", and wrong for "something transient happened to the one account that
# can still bill", which is what an overage refusal usually is.
ACCOUNT_OVERAGE_COOLDOWN_SECS="${ACCOUNT_OVERAGE_COOLDOWN_SECS:-900}"
ACCOUNT_POLL_STALE_SECS="${ACCOUNT_POLL_STALE_SECS:-10800}"
ACCOUNT_COOLDOWN_SECS="${ACCOUNT_COOLDOWN_SECS:-${MODEL_COOLDOWN_SECS:-21600}}"
ACCOUNT_DEFAULT_PRIORITY="${ACCOUNT_DEFAULT_PRIORITY:-100}"

# Every vendor this script knows, in the enumerable form the case below cannot
# be read in — bin/quota-status.sh walks it to find an account's cooldowns. Keep
# the two together: a name here that the case does not answer is a bug the
# BH-940 suite catches.
ACCOUNT_VENDORS="claude codex grok openrouter fireworks"

# The credential variables that BELONG to each vendor. The pick exports the ones
# the account file defines and unsets the rest, so no parent credential can leak
# into a routed child.
_acct_vendor_vars() { # <vendor> -> the vendor's credential var names
  case "${1:-}" in
    claude)     printf 'CLAUDE_CONFIG_DIR CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY\n' ;;
    codex)      printf 'CODEX_HOME CODEX_API_KEY OPENAI_API_KEY\n' ;;
    grok)       printf 'XAI_API_KEY\n' ;;
    openrouter) printf 'OPENROUTER_API_KEY\n' ;;
    fireworks)  printf 'FIREWORKS_API_KEY\n' ;;
    *)          return 1 ;;
  esac
}

_acct_log() { # <project> <stage> <model> <account> <reason>
  mkdir -p "$(dirname "$ROUTING_LOG")" 2>/dev/null
  printf '%s,%s,%s,%s,%s,%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" "$2" "$3" "$4" "$5" \
    >> "$ROUTING_LOG" 2>/dev/null || true
}

# accounts_load — read env/accounts.d/*.env into the ACCT_* associative arrays.
#
# Sourced in a SUBSHELL with the recognised names unset first, so a value the
# parent already carries (the box's own CLAUDE_CODE_OAUTH_TOKEN, say) can never
# be mistaken for something the account file declared. `set +u` around the source
# for the same reason extra-usage-track.sh uses it: an unbound reference inside a
# config file must not be fatal to the script reading it.
_ACCT_KEYS='ACCOUNT_NAME ACCOUNT_VENDOR ACCOUNT_ENABLED ACCOUNT_PRIORITY ACCOUNT_MODELS ACCOUNT_LABEL
CLAUDE_CONFIG_DIR CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY CODEX_HOME CODEX_API_KEY OPENAI_API_KEY
XAI_API_KEY OPENROUTER_API_KEY FIREWORKS_API_KEY'

_acct_read_file() { # <file> -> `KEY=<%q>` lines for the recognised keys it sets
  ( # shellcheck disable=SC2086
    unset $_ACCT_KEYS
    set -a +u
    # shellcheck disable=SC1090
    . "$1" >/dev/null 2>&1
    set +a -u
    for _k in $_ACCT_KEYS; do
      _v="${!_k-}"
      [ -n "${_v:-}" ] && printf '%s=%q\n' "$_k" "$_v"
    done
    true )
}

accounts_load() { # populates ACCOUNT_NAMES + ACCT_* ; always returns 0
  ACCOUNT_NAMES=()
  declare -gA ACCT_VENDOR=() ACCT_ENABLED=() ACCT_PRIORITY=() ACCT_MODELS=() ACCT_LABEL=() ACCT_CREDS=() ACCT_FILE=()
  [ -d "$ACCOUNTS_DIR" ] || return 0
  local f stem raw line k v name vendor skip vars ok creds
  for f in "$ACCOUNTS_DIR"/*.env; do
    [ -f "$f" ] || continue
    stem=$(basename "$f" .env)
    # `default` is the reserved name of the implicit account (today's global.env
    # credentials). A registry file claiming it would make the fallback
    # unreachable, so it is refused rather than merged.
    if [ "$stem" = default ]; then
      _acct_log - - - - "registry_skip:$stem:reserved_name"; continue
    fi
    raw=$(_acct_read_file "$f")
    name=""; vendor=""; creds=$'\n'
    local a_enabled=1 a_priority=50 a_models="" a_label=""
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      k="${line%%=*}"; v=""
      eval "v=${line#*=}" 2>/dev/null || continue
      case "$k" in
        ACCOUNT_NAME)     name="$v" ;;
        ACCOUNT_VENDOR)   vendor="$v" ;;
        ACCOUNT_ENABLED)  a_enabled="$v" ;;
        ACCOUNT_PRIORITY) a_priority="$v" ;;
        ACCOUNT_MODELS)   a_models="$v" ;;
        ACCOUNT_LABEL)    a_label="$v" ;;
        *)                creds="$creds$k=$(printf '%q' "$v")"$'\n' ;;
      esac
    done <<< "$raw"
    # The name becomes a path under state/quota/, so it is validated as a name
    # and not merely trusted; and it must equal the filename stem, or two files
    # could claim one account and the last one read would silently win.
    skip=""
    case "$name" in
      '') skip=no_account_name ;;
      *[!a-z0-9._-]*) skip=bad_name ;;
      [!a-z0-9]*) skip=bad_name ;;
    esac
    [ -z "$skip" ] && [ "${#name}" -gt 40 ] && skip=bad_name
    [ -z "$skip" ] && [ "$name" != "$stem" ] && skip=name_stem_mismatch
    if [ -z "$skip" ]; then
      vars=$(_acct_vendor_vars "$vendor") || skip=bad_vendor
    fi
    if [ -z "$skip" ]; then
      ok=0
      for k in $vars; do case "$creds" in *$'\n'"$k="*) ok=1 ;; esac; done
      [ "$ok" = 1 ] || skip=no_credential
    fi
    if [ -n "$skip" ]; then
      _acct_log - - - - "registry_skip:$stem:$skip"; continue
    fi
    case "$a_enabled" in ''|*[!01]*) a_enabled=1 ;; esac
    case "$a_priority" in ''|*[!0-9]*) a_priority=50 ;; esac
    ACCOUNT_NAMES+=("$name")
    ACCT_VENDOR["$name"]="$vendor"
    ACCT_ENABLED["$name"]="$a_enabled"
    ACCT_PRIORITY["$name"]="$a_priority"
    ACCT_MODELS["$name"]="$a_models"
    ACCT_LABEL["$name"]="$a_label"
    ACCT_CREDS["$name"]="$creds"
    ACCT_FILE["$name"]="$f"
  done
  return 0
}

# account_cred_get <account> <VAR> — the value the account file gave that
# credential variable, or empty. Used by quota-poll.sh (which config dir to read
# a token from) and quota-status.sh (which accounts are even pollable). The value
# is a secret for the token/key forms: callers pass it through env, never argv,
# and never log it.
account_cred_get() {
  local line
  line=$(printf '%s\n' "${ACCT_CREDS[$1]:-}" | sed -n "s/^$2=//p" | head -1)
  [ -n "$line" ] || return 1
  eval "printf '%s\\n' $line"
}

# Does this box have a usable DEFAULT credential for <vendor>? Informational:
# see the candidate rule in account_pick() — with no registry account for the
# vendor the default is a candidate regardless, because "unconfigured box" must
# stay a byte-for-byte no-op.
account_default_present() { # <vendor>
  case "${1:-}" in
    claude) [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || [ -n "${ANTHROPIC_API_KEY:-}" ] \
              || [ -r "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" ] ;;
    codex)  [ -r "${CODEX_HOME:-$HOME/.codex}/auth.json" ] || [ -n "${CODEX_API_KEY:-}" ] \
              || [ -n "${OPENAI_API_KEY:-}" ] ;;
    grok)       [ -n "${XAI_API_KEY:-}" ] ;;
    openrouter) [ -n "${OPENROUTER_API_KEY:-}" ] ;;
    fireworks)  [ -n "${FIREWORKS_API_KEY:-}" ] ;;
    *) return 1 ;;
  esac
}

# The per-model quota family the endpoint reports for a model slug: the second
# dash-token of a claude-* slug (claude-<family>-<version> -> <family>), otherwise the slug
# itself — so a codex/grok model simply never matches a per_model key.
account_model_family() { # <model>
  local m="${1:-}"
  case "$m" in
    claude-*) m="${m#claude-}"; printf '%s\n' "${m%%-*}" ;;
    *) printf '%s\n' "$m" ;;
  esac
}

_acct_epoch() { # <iso8601> -> epoch seconds, 0 when unparseable
  # GNU `date -u -d ""` answers today's 00:00Z with rc 0 (#1815): empty is unparseable.
  [ -n "${1:-}" ] || { printf '0\n'; return 0; }
  local e; e=$(date -u -d "${1:-}" +%s 2>/dev/null) || e=0
  case "$e" in ''|*[!0-9]*) e=0 ;; esac
  printf '%s\n' "$e"
}

# `a >= b` for possibly-fractional percentages, without bc.
_acct_ge() { awk -v a="${1:-}" -v b="${2:-}" 'BEGIN{exit !(a+0 >= b+0)}'; }

# THE FIELDS ARE POSITIONAL AND THE LAST FIVE ARE NEW (BH-1456): the overage
# reading bin/quota-poll.sh now carries. A null in the json becomes the EMPTY
# STRING here, which every caller below reads as "no reading" — distinct from
# the literal `false`, which means the toggle is off. Both readers of this
# function (account_reading_class and account_pick's rank loop) name all ten
# fields; a `read` that names five would silently swallow the rest into $mpct.
account_quota_read() { # <account> <family> -> "status|polled_at|5h|week|model|x_enabled|x_slr|x_reason|x_userdis|x_pct"
  local f="$QUOTA_DIR/$1.json"
  if [ -r "$f" ] && command -v jq >/dev/null 2>&1; then
    jq -r --arg fam "$2" '[ (.status // "unknown"), (.polled_at // ""),
        (.five_hour.pct // ""), (.seven_day.pct // ""),
        ((.per_model // {})[$fam].pct // ""),
        (.extra_usage.is_enabled // ""), (.extra_usage.spend_limit_reached // ""),
        (.extra_usage.disabled_reason // ""), (.extra_usage.user_disabled // ""),
        (.extra_usage.pct // "") ] | map(tostring) | join("|")' "$f" 2>/dev/null && return 0
  fi
  printf 'none|||||||||\n'
}

# account_status_is_known <status> -> 0 when the reading is enough to route on.
# `ok` and `unreadable` are both real readings from the quota endpoint: we have
# a poll we can act on. `unknown`, `unmetered`, `error`, `none` and the empty
# case are not; they keep the account available (headroom unknown is not zero)
# but cannot be ranked for the pool.
account_status_is_known() {
  case "${1:-}" in ok|unreadable) return 0 ;; esac
  return 1
}

# account_reading_class <account> <model> -> "<class>|<rank pct>|<detail>"
#
# THE ONE READING OF A QUOTA FILE, for every picker there is. Both this file's
# account_headroom and bin/lib/pool-account.sh's _pa_metered judge an account
# through this function and nothing else, because when they judged separately
# they drifted: on 2026-09-16 the hub read `unreadable` as "no evidence against"
# and used the account while the pool read it as "not ok" and dropped it, so the
# pool ranked zero accounts and shipped one capped default token to every
# machine it launched for hours. One classifier, two callers, no drift.
#
# The classes, and what each one MEANS rather than what it looks like:
#   metered     a fresh `ok` poll under every threshold, OR a fresh `ok` poll
#               whose account is billing extra usage with its spend limit
#               intact — rank on the pct in field 2
#   capped      a fresh `ok` poll at or over one — the ONLY class that is
#               evidence the account must not be used
#   unreadable  bin/quota-poll.sh reached the account and honestly has no
#               numbers for it: a claude account with no CLAUDE_CONFIG_DIR gets
#               403 on the usage endpoint, and that is EVERY shippable pool
#               account. Not evidence of anything; cooldowns route it.
#   stale       an `ok` poll older than ACCOUNT_POLL_STALE_SECS, or a poller
#               that said so itself — a poller that STOPPED, which is a
#               different failure from one that answered
#   none        no file, unknown, unmetered, errored
#
# account_status_is_known is the status gate: a status it does not recognise is
# `none`, except the poller's own `stale`, which names its class. `unreadable`
# answers before the age check on purpose — quota-poll.sh rewrites that status
# every run, so an aged one means the POLLER stopped, and calling it `stale`
# would drop every shippable account exactly as 2026-09-16 did.
#
# Callers decide what to do with stale/none, and they deliberately differ: see
# account_headroom below and the header of bin/lib/pool-account.sh.
#
# THE THIRD FIELD, AND THE OVERAGE BRANCH (BH-1456).
#
# Field 3 is the DETAIL: which rule produced the class (`5h`, `week`, `model`,
# `spend_limit`, `disabled`, `extra_cap`, `overage`, empty for a plain metered
# account). The class WORD is unchanged, because every reader in the repo
# branches on `capped`/`metered`/`stale`/`unreadable`/`none` and moving the word
# would break all of them; the detail is what turned five different refusals
# into one unattributable `capped` in the routing log.
#
# The overage branch answers BEFORE the subscription thresholds, because once an
# account is billing extra usage those windows no longer describe whether it can
# serve: weekly 100% with overage on is a normal, healthy, working account, and
# on the hub it is the account every stage bills to. What still refuses, and
# must keep refusing — these were the CORRECT refusals of 2026-09-18/19:
#   spend_limit_reached  the extra usage budget itself is spent
#   disabled_reason      Anthropic turned it off (payment failed, and kin)
#   user_disabled        a human turned it off
#   extra_cap            the overage meter is at ACCOUNT_EXTRA_MAX
# And `is_enabled` empty or false takes NONE of these paths: empty is "no
# reading" (a poll from before this change, or a response with no extra_usage
# object) and false is "overage is off". Both fall through to the thresholds
# exactly as they did before, which is what keeps every other box unchanged.
account_reading_class() {
  local n="${1:-}" model="${2:-}" fam st polled five week mpct now age window
  local xen xslr xrsn xud xpct
  fam=$(account_model_family "$model")
  IFS='|' read -r st polled five week mpct xen xslr xrsn xud xpct <<< "$(account_quota_read "$n" "$fam")"
  account_status_is_known "${st:-}" || {
    [ "${st:-}" = stale ] && printf 'stale||\n' || printf 'none||\n'; return 0; }
  [ "$st" = unreadable ] && { printf 'unreadable||\n'; return 0; }
  window="${ACCOUNT_POLL_STALE_SECS:-10800}"; case "$window" in ''|*[!0-9]*) window=10800 ;; esac
  now=$(date -u +%s); age=$(( now - $(_acct_epoch "$polled") ))
  [ "$age" -ge "$window" ] && { printf 'stale||\n'; return 0; }
  if [ "${xen:-}" = true ]; then
    [ "${xslr:-}" = true ] && { printf 'capped|%s|spend_limit\n' "$five"; return 0; }
    [ -n "${xrsn:-}" ]     && { printf 'capped|%s|disabled\n'    "$five"; return 0; }
    [ "${xud:-}" = true ]  && { printf 'capped|%s|disabled\n'    "$five"; return 0; }
    if [ -n "${xpct:-}" ] && _acct_ge "$xpct" "$ACCOUNT_EXTRA_MAX"; then
      printf 'capped|%s|extra_cap\n' "$xpct"; return 0
    fi
    # Ranked on the overage meter when we have one, because that is the number
    # that now says how much this account has left. No reading -> the 5h pct,
    # so the sort still has something monotonic to work with.
    printf 'metered|%s|overage\n' "${xpct:-$five}"; return 0
  fi
  [ -n "${five:-}" ] && _acct_ge "$five" "$ACCOUNT_5H_MAX"    && { printf 'capped|%s|5h\n'    "$five"; return 0; }
  [ -n "${week:-}" ] && _acct_ge "$week" "$ACCOUNT_WEEK_MAX"  && { printf 'capped|%s|week\n'  "$five"; return 0; }
  [ -n "${mpct:-}" ] && _acct_ge "$mpct" "$ACCOUNT_MODEL_MAX" && { printf 'capped|%s|model\n' "$five"; return 0; }
  printf 'metered|%s|\n' "$five"
  return 0
}

# account_overage_ok <account> -> 0 when this account is billing extra usage and
# that billing is intact: enabled, spend limit not reached, not disabled by
# Anthropic or by the user. A stale or unreadable poll is NOT overage-ok — the
# whole point of the flag is that we have a fresh reading saying "this account
# can still bill", and an old one does not say that.
#
# It exists for bin/agent-call.sh, which EXECUTES this file rather than sourcing
# it, so the CLI form `account-pick.sh --overage-ok <account>` is the entry point
# that matters (see the dispatcher at the bottom of this file).
account_overage_ok() { # <account>
  local n="${1:-}" cls detail
  [ -n "$n" ] || return 1
  IFS='|' read -r cls _ detail <<< "$(account_reading_class "$n" "${2:-}")"
  [ "$cls" = metered ] && [ "$detail" = overage ]
}

# account_headroom <account> <model> -> 0 = usable, 1 = over a threshold.
# A missing, stale, unreadable, unknown, unmetered or errored poll counts as
# AVAILABLE: headroom unknown is not headroom zero, and refusing to call an
# account we simply have no numbers for would take the whole fleet down the day
# the poller breaks. So `capped` is the only class that excludes anything here.
account_headroom() {
  local cls
  IFS='|' read -r cls _ _ <<< "$(account_reading_class "$1" "$2")"
  [ "$cls" = capped ] && return 1
  return 0
}

# ---- cooldowns, keyed by VENDOR AND ACCOUNT ---------------------------------
# state/quota/cooldown/<vendor>/<account>, epoch seconds. The vendor is in the
# key because `default` is ONE name every vendor shares: on 2026-09-18 codex's
# default ran out of credits, the writer stamped cooldown/default, and this
# reader refused the box's perfectly healthy CLAUDE default for six hours while
# state/quota/default.json still said `ok`. A cooldown is evidence about one
# vendor's account and about nothing else.
#
# The old unscoped key is never read again for any vendor: the first library
# call that sees one moves it to cooldown/.legacy/<name> and logs one row. A
# dot-directory cannot collide with an account or a vendor (registry names must
# start [a-z0-9], see accounts_load above).
account_cooldown_file() { # <vendor> <account> -> the path of that cooldown
  printf '%s/cooldown/%s/%s\n' "$QUOTA_DIR" "$1" "$2"
}

# Once per process — a pick walks several candidates and an operator reading the
# routing log wants one row per legacy file, not one per candidate. A sweep that
# cannot write (read-only state/) leaves the file alone and logs nothing: it is
# still never READ as a cooldown, so the fail direction is "account available".
account_cooldown_sweep_legacy() {
  [ -n "${_ACCT_LEGACY_SWEPT:-}" ] && return 0
  _ACCT_LEGACY_SWEPT=1
  local f n
  for f in "$QUOTA_DIR"/cooldown/*; do
    [ -f "$f" ] || continue          # vendor dirs are directories; only files are legacy
    n=$(basename "$f")
    mkdir -p "$QUOTA_DIR/cooldown/.legacy" 2>/dev/null \
      && mv -f "$f" "$QUOTA_DIR/cooldown/.legacy/$n" 2>/dev/null \
      && _acct_log - - - "$n" legacy_cooldown_ignored
  done
  return 0
}

# Stamp <vendor> <account> as cooling NOW. Always 0: routing is never fatal, and
# a stamp that could not be written leaves the caller's own loop bound (the
# `tried` list in bin/agent-call.sh's ladder_recover) doing the stopping.
account_cooldown_stamp() { # <vendor> <account>
  account_cooldown_sweep_legacy
  _acct_cooldown_write "$1" "$2" "$(date -u +%s)"
  return 0
}

# _acct_cooldown_write <vendor> <account> <epoch> — the later stamp wins
# (BH-1853): a write no later than the stamp already there is skipped, file and
# mtime untouched, so a routine stamp never shortens a reset-dated cooldown.
# A non-numeric old stamp counts as 0.
# File first, fleet row second (BH-2355): the row's until is stamp + window, and
# it is put even when the file write was skipped, because the store keeps the
# later until too, so a replay never shortens anything.
_acct_cooldown_write() {
  local d="$QUOTA_DIR/cooldown/$1" old rc=0 win="$ACCOUNT_COOLDOWN_SECS"
  old=$(cat "$d/$2" 2>/dev/null); case "$old" in ''|*[!0-9]*) old=0 ;; esac
  if [ "$3" -gt "$old" ]; then
    mkdir -p "$d" 2>/dev/null && printf '%s\n' "$3" > "$d/$2" 2>/dev/null || rc=$?
  fi
  case "$win" in ''|*[!0-9]*) win=21600 ;; esac
  command -v fcd_put >/dev/null 2>&1 && fcd_put account "$1" "$2" "$(( $3 + win ))" "$3" cooldown
  return "$rc"
}

# account_cooldown_stamp_short <vendor> <account> [secs] — cool this account for
# SECS instead of the full ACCOUNT_COOLDOWN_SECS window.
#
# IMPLEMENTED AS A BACKDATED STAMP, deliberately. The stamp file holds one epoch
# and `account_cooling` compares `now - at` against one window; a second field or
# a second file would mean changing that reader, `cooldowns_json` in
# bin/quota-status.sh, and bin/quota-poll.sh's expiry sweep — three readers and
# their BH-940 tests — to express something the existing shape can already say.
# So the stamp is written (ACCOUNT_COOLDOWN_SECS - secs) in the past and every
# reader keeps its single window: the account comes back in `secs`, the status
# table's "would have run to" line is right, and the sweep still collects it.
#
# A `secs` at or above the window is just a normal stamp (there is no such thing
# as a cooldown longer than the window here), and a non-numeric one falls back to
# the same, because a guessed backdate is worse than the documented default.
account_cooldown_stamp_short() { # <vendor> <account> [secs]
  local secs="${3:-$ACCOUNT_OVERAGE_COOLDOWN_SECS}" win="$ACCOUNT_COOLDOWN_SECS" back
  case "$secs" in ''|*[!0-9]*) secs="$win" ;; esac
  case "$win"  in ''|*[!0-9]*) win=21600 ;; esac
  [ "$secs" -ge "$win" ] && { account_cooldown_stamp "$1" "$2"; return 0; }
  back=$(( win - secs ))
  account_cooldown_sweep_legacy
  _acct_cooldown_write "$1" "$2" "$(( $(date -u +%s) - back ))"
  return 0
}

# account_cooling <vendor> <account> -> 0 when this box's file OR the fleet row
# (BH-2355) says the account is cooling. The fleet answers 0 live, 1 none, 2
# unknown; only 0 cools, so an unreachable fleet degrades to the file alone. A
# fleet-only cooldown is never written back into the file: this only reads.
account_cooling() {
  _acct_cooling_file "$@" && return 0
  [ $# -ge 2 ] || return 1
  command -v fcd_live >/dev/null 2>&1 && fcd_live account "$1" "$2" && return 0 # fleet-or (BH-2355)
  return 1
}

_acct_cooling_file() { # <vendor> <account> -> 0 when this box's cooldown file is in window
  # A caller that cannot name a vendor cannot be answered: fail open (not
  # cooling) rather than refuse a healthy account on a guess.
  [ $# -ge 2 ] || return 1
  account_cooldown_sweep_legacy
  local f at now; f=$(account_cooldown_file "$1" "$2")
  [ -r "$f" ] || return 1
  at=$(cat "$f" 2>/dev/null); case "$at" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date -u +%s)
  [ $(( now - at )) -lt "$ACCOUNT_COOLDOWN_SECS" ]
}

_acct_models_allow() { # <allowlist> <model>
  local list="${1:-}" model="${2:-}"
  [ -n "$list" ] || return 0
  case ",$list," in *",$model,"*) return 0 ;; esac
  return 1
}

_acct_pin_key() { # sanitise: the key becomes a filename under state/quota/pins
  # No trailing newline through `tr`: a newline is not in the keep-set, so a
  # printf '%s\n' of an EMPTY key came back as "_" and every unpinned call
  # silently shared one pin file.
  [ -n "${1:-}" ] || return 0
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-64
}

# account_pick <stage> <vendor> <model> — prints the block documented in the
# header. Returns 0 / 2 / 3.
account_pick() {
  local stage="${1:-}" vendor="${2:-}" model="${3:-}"
  local vars n cands=() ranked pick reason pinkey pinfile pinned=""
  vars=$(_acct_vendor_vars "$vendor") || {
    echo "account-pick.sh: unknown vendor '$vendor'" >&2; return 3; }
  accounts_load

  # (1) enabled accounts of this vendor whose ACCOUNT_MODELS allows the model.
  local vendor_registry=0
  for n in "${ACCOUNT_NAMES[@]+"${ACCOUNT_NAMES[@]}"}"; do
    [ "${ACCT_VENDOR[$n]}" = "$vendor" ] || continue
    vendor_registry=$(( vendor_registry + 1 ))
    [ "${ACCT_ENABLED[$n]}" = 1 ] || continue
    _acct_models_allow "${ACCT_MODELS[$n]}" "$model" || continue
    cands+=("$n")
  done
  # The implicit `default` account — today's credentials, priority 100. It is a
  # candidate whenever this vendor has NO registry account (so an unconfigured
  # box is a pure no-op) or when a default credential is actually detectable.
  if [ "$vendor_registry" -eq 0 ] || account_default_present "$vendor"; then
    cands+=(default)
  fi

  # (2)+(3) drop accounts in cooldown, then accounts over a headroom threshold.
  # Ranked as `priority \t 5h-pct \t name`: lowest priority number first, ties
  # broken by the lower fresh 5-hour utilisation, then by name so the order is
  # stable across boxes.
  ranked=$(for n in "${cands[@]+"${cands[@]}"}"; do
    account_cooling "$vendor" "$n" && continue
    local p f cls detail
    # ONE read of the classifier per candidate, for both the drop decision and
    # the rank: it already computed the number this loop wants, and asking
    # account_quota_read again for the 5h pct is how an account in overage got
    # ranked on the subscription meter it is no longer bounded by.
    IFS='|' read -r cls f detail <<< "$(account_reading_class "$n" "$model")"
    if [ "$cls" = capped ]; then
      # WHICH rule refused, in the log an operator actually tails. `capped` on
      # its own meant five different things — a spent week, a spent 5h window, a
      # spent model family, a spend limit, a disabled overage account — and an
      # operator reading it could not tell a quota problem from a billing one.
      _acct_log "$stage" - "$model" "$n" "drop:capped:${detail:-unknown}"
      continue
    fi
    if [ "$n" = default ]; then p="$ACCOUNT_DEFAULT_PRIORITY"; else p="${ACCT_PRIORITY[$n]}"; fi
    [ "$cls" = metered ] && [ -n "${f:-}" ] || f=999
    printf '%s\t%s\t%s\n' "$p" "$f" "$n"
  done | sort -t$'\t' -k1,1n -k2,2n -k3,3)

  [ -n "$ranked" ] || return 2

  # (4) sticky: a pin that still points at an eligible account wins, so a build's
  # follow-up stages keep hitting the same warm prompt cache.
  pinkey=$(_acct_pin_key "${ACCOUNT_PIN_KEY:-}")
  if [ -n "$pinkey" ]; then
    pinfile="$QUOTA_DIR/pins/$pinkey"
    pinned=$(cat "$pinfile" 2>/dev/null | head -1)
    if [ -n "$pinned" ] && printf '%s\n' "$ranked" | cut -f3 | grep -qxF "$pinned"; then
      pick="$pinned"; reason=pinned
    fi
  fi
  if [ -z "${pick:-}" ]; then
    pick=$(head -1 <<<"$ranked" | cut -f3)
    if [ "$pick" = default ] && [ "${vendor_registry:-0}" -eq 0 ]; then reason=default
    elif [ "$(grep -c '' <<<"$ranked")" -eq 1 ]; then reason=only
    elif [ "$(head -2 <<<"$ranked" | cut -f1 | sort -u | grep -c '')" -eq 1 ]; then reason=tie_5h
    else reason=priority
    fi
  fi
  # (5) refresh the pin, so the next stage of this build lands on the same account.
  if [ -n "$pinkey" ]; then
    mkdir -p "$QUOTA_DIR/pins" 2>/dev/null && printf '%s\n' "$pick" > "$QUOTA_DIR/pins/$pinkey" 2>/dev/null || true
  fi

  printf 'name=%s\n' "$pick"
  printf 'reason=%s\n' "$reason"
  if [ "$pick" != default ]; then
    [ -n "${ACCT_LABEL[$pick]:-}" ] && printf 'label=%s\n' "${ACCT_LABEL[$pick]}"
    # export what the file declares, unset every other credential var of the
    # vendor — see the shadowing note in the header.
    for n in $vars; do
      case "${ACCT_CREDS[$pick]}" in
        *$'\n'"$n="*) printf 'export %s=%s\n' "$n" "$(printf '%s\n' "${ACCT_CREDS[$pick]}" | sed -n "s/^$n=//p" | head -1)" ;;
        *)       printf 'unset %s\n' "$n" ;;
      esac
    done
  fi
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  # `--overage-ok <account>`: rc only, nothing on stdout. bin/agent-call.sh EXECS
  # this file (it does not source it), so the ladder's cooldown arm needs a CLI
  # form of account_overage_ok to decide between the short and the long window.
  if [ "${1:-}" = --overage-ok ]; then
    [ -n "${2:-}" ] || { echo "usage: account-pick.sh --overage-ok <account>" >&2; exit 3; }
    account_overage_ok "$2" "${3:-}"
    exit $?
  fi
  if [ "$#" -lt 3 ]; then
    echo "usage: account-pick.sh <stage> <vendor> <model>" >&2; exit 3
  fi
  account_pick "$1" "$2" "$3"
  exit $?
fi
