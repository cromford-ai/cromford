#!/bin/bash
# bin/lib/pool-account.sh — WHICH Claude account a Fly pool machine spends.
#
# Sourced by bin/fly-pool.sh; sourceable standalone (tests, operators):
#
#   . bin/lib/pool-account.sh
#   pool_account_lease <project> <ticket-key> <bundle-global.env> <machine-id>
#   pool_account_release <machine-id>
#   pool_account_rebind <old-id> <new-id> <account> [project] [key]
#   pool_account_prune
#   pool_account_leases <account>
#   pool_account_cooldown <account> <why>
#
# WHY THIS EXISTS (the operator, 2026-09-14: "find a way to use them for the builder
# lanes, the fly boxes"). bin/fly-envbundle.sh ships ONE CLAUDE_CODE_OAUTH_TOKEN
# — the owning box's project-6 setup-token — to every machine in a project's Fly
# pool. Forty machines were therefore forty heavy sessions on ONE account
# (fly/account-capacity.conf says the useful ceiling is ~4), and every cost row
# those machines wrote carried the project-6 fingerprint, so per-account spend on
# the console was one undifferentiated blob. The hub now holds seven real
# accounts (env/accounts.d/max1..max7) whose SHIPPABLE 1-year setup tokens live
# in env/tokens.d/<name>-setup-token.env — so a machine can be handed an account
# of its own instead.
#
# THE SHAPE IS THE GH_TOKEN SWAP'S, DELIBERATELY. bin/fly-pool.sh already
# REPLACES the bundle's GH_TOKEN= line with a per-machine App token, records the
# expiry on the machine json and says so in the log. This does the same thing one
# line lower: replace CLAUDE_CODE_OAUTH_TOKEN=, record `auth_account`, say so. A
# second CLAUDE_CODE_OAUTH_TOKEN= appended after the first is what the builder's
# `set -a; . global.env` would actually use, so an append would silently keep the
# project-6 token — hence grep -v + append + mv, never >>.
#
# FAIL-OPEN, ALWAYS. Every path returns 0 and every failure ships the bundle
# exactly as it arrived (the project-6 token), because a launch refused for lack
# of an account is a build that does not happen. Unarmed, this touches nothing at
# all and returns a reason string the caller can `say`.
#
# LEASE ACCOUNTING — the part bin/account-pick.sh does not have. The hub's picker
# ranks on a meter bin/quota-poll.sh refreshes every 10 minutes, which is right
# for a lane that makes one call and wrong for a pool: a tick launches ten
# machines inside a minute, every one of them reads the SAME stale meter, and
# every one of them picks the same lowest-5h account. So a pick writes a lease
# file — state/quota/leases/<account>/<machine-id> — and the rank is
# `5h pct + live_leases * ACCOUNT_LEASE_WEIGHT_PCT`. The weight is a measured
# number, not a feeling: one Fable review-sized call is ~3.5% of a 5-hour window
# (measured 2026-09-14) and a build is several stages, so 8 is roughly "what this
# machine is about to spend", expressed in the unit the meter already reports.
#
# A STOPPED POLLER IS SKIPPED HERE, and that INVERTS account-pick.sh's fail-open
# rule on purpose. There, "no numbers" must count as available or a broken poller
# takes the whole fleet down. Here the fallback is the project-6 token the pool
# ships today, so an account whose meter has gone STALE or missing costs nothing
# to skip and could cost a 40-minute build to guess at.
#
# An `unreadable` meter is NOT that case (2026-09-16). bin/quota-poll.sh writes
# that status for every claude account with no CLAUDE_CONFIG_DIR — i.e. for every
# account this file can ship — because a setup token gets 403 on the usage
# endpoint and there is nothing honest to write. Skipping it ranked ZERO accounts
# and put every pool machine back on the one capped project-6 token. Both pickers
# now read a quota file through ONE classifier, account-pick.sh's
# account_reading_class, and differ only where they mean to; see _pa_metered.
#
# SECRETS. The token is read from env/tokens.d (hub only, chmod 600, outside
# accounts.d precisely because accounts.d holds LOGINS that cannot ship) into a
# variable, written into the bundle, and cleared. It is never printed, never
# logged, never passed as an argument, and lands in no file this writes except
# the bundle itself. What IS written is the account NAME (machine json, routing
# log) and the account LABEL (the fingerprint overlay) — neither is a secret, and
# both are what the console needs to attribute spend.

# The picker's library half — accounts_load, account_cooling, account_headroom,
# account_quota_read, _acct_models_allow, _acct_pin_key, _acct_log — and the
# fingerprint library. Both are function-only when sourced, and both are sourced
# only when their functions are not already present, so a caller that sourced
# them first (bin/quota-status.sh does) does not pay twice.
_pa_bindir() { ( cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd ); }
if ! command -v accounts_load >/dev/null 2>&1; then
  _PA_BIN=$(_pa_bindir)
  # shellcheck source=bin/account-pick.sh
  [ -r "$_PA_BIN/account-pick.sh" ] && . "$_PA_BIN/account-pick.sh"
  unset _PA_BIN
fi
if ! command -v auth_fp_for_runner >/dev/null 2>&1; then
  _PA_BIN=$(_pa_bindir)
  # shellcheck source=bin/auth-fingerprint.sh
  [ -r "$_PA_BIN/auth-fingerprint.sh" ] && . "$_PA_BIN/auth-fingerprint.sh"
  unset _PA_BIN
fi
# The shared-fact client (BH-1043). bin/fly-pool.sh already sources it — it
# calls queue_claim — so on the real path this is a no-op; the guard is what
# lets an operator or a test source this library alone and still reach the
# account_leases table instead of silently falling back to per-box files.
if ! command -v account_lease_claim >/dev/null 2>&1; then
  _PA_BIN=$(_pa_bindir)
  # shellcheck source=bin/jobs-client.sh
  [ -r "$_PA_BIN/jobs-client.sh" ] && . "$_PA_BIN/jobs-client.sh"
  unset _PA_BIN
fi

# ---- knobs, every one env-driven with a documented default ------------------
# ACCOUNT_LEASE_WEIGHT_PCT  8      a live lease is worth this many 5h-percent in the rank
# ACCOUNT_LEASE_TTL_SECS    10800  a lease older than this is stale: ignored, then pruned
# ACCOUNT_POOL_MAX_LEASES   -      per-account lease cap; default = fly/account-capacity.conf's
#                                  claude sessions-per-account (4). 0 = no cap.
# POOL_ACCOUNT_ROUTING      1      0 turns the whole thing off (so does the row
#                                  switch.pool-account-routing-off[.<box>]=1; no row: flags/pool-account-routing-off)
# POOL_TOKENS_DIR           tokens.d inside the dir harness_env_dir resolves
# ACCOUNT_RESET_MAX_S       691200 the furthest-off vendor reset time a cooldown will run to
#                                  (8 days: a weekly limit plus a day); anything later is not
#                                  believed and the normal window is used
# The thresholds (ACCOUNT_5H_MAX, ACCOUNT_WEEK_MAX, ACCOUNT_POLL_STALE_SECS,
# ACCOUNT_COOLDOWN_SECS) are account-pick.sh's own and are read through its
# functions, so the pool and the hub can never disagree about what "exhausted"
# means.
# The root is HARNESS, then the caller's H, else none (BH-2613.4): with no root
# there is no quota, lease, pin or tokens dir, so nothing is written and the
# pool answers unarmed (no_tokens_dir), the same as a box with no tokens.d.
_pa_h()        { printf '%s' "${HARNESS:-${H:-}}"; }
{ [ -n "$(_pa_h)" ] && . "$(_pa_h)/bin/lib/env-path.sh"; } 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/env-path.sh" 2>/dev/null || harness_env_dir() { local r="${1:-${HARNESS:-${H:-}}}"; [ -n "$r" ] || return 0; printf '%s\n' "$r/env"; }
# The fleet cooldown seam (BH-2355), guarded: without it the cooldown stays box-local.
. "$(dirname "${BASH_SOURCE[0]}")/fleet-cooldown.sh" 2>/dev/null || { [ -n "$(_pa_h)" ] && . "$(_pa_h)/bin/lib/fleet-cooldown.sh"; } 2>/dev/null || true
_pa_quotadir() {
  if [ -n "${QUOTA_DIR:-}" ]; then printf '%s' "$QUOTA_DIR"; return 0; fi
  [ -n "$(_pa_h)" ] || return 0
  printf '%s' "$(_pa_h)/state/quota"
}
_pa_num()      { case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }

# Both print "" with no root. harness_env_dir is never called with an empty
# root: env-path.sh would answer with its own default.
pool_account_tokens_dir() {
  if [ -n "${POOL_TOKENS_DIR:-}" ]; then printf '%s' "$POOL_TOKENS_DIR"; return 0; fi
  [ -n "$(_pa_h)" ] || return 0
  printf '%s' "$(harness_env_dir "$(_pa_h)")/tokens.d"
}
pool_account_lease_dir()  { local q; q=$(_pa_quotadir); [ -n "$q" ] || return 0; printf '%s' "$q/leases"; }
_pa_ttl()    { _pa_num "${ACCOUNT_LEASE_TTL_SECS:-}" 10800; }
_pa_weight() { _pa_num "${ACCOUNT_LEASE_WEIGHT_PCT:-}" 8; }

# The per-account lease cap, from the SAME file and the same reader
# bin/account-capacity.sh uses — one reviewed number, never two.
pool_account_max_leases() {
  local n h
  n=$(_pa_num "${ACCOUNT_POOL_MAX_LEASES:-}" "")
  if [ -z "$n" ]; then
    h=$(_pa_h)
    [ -n "$h" ] && [ -r "$h/fly/account-capacity.conf" ] && n=$(grep -vE '^[[:space:]]*#' "$h/fly/account-capacity.conf" 2>/dev/null \
        | awk '$1 == "claude" { print $2; exit }' | tr -dc '0-9')
  fi
  _pa_num "$n" 4
}

_pa_token_file() { printf '%s/%s-setup-token.env' "$(pool_account_tokens_dir)" "${1:-}"; }

# The shippable token for an account, or rc 1. The VALUE never leaves the
# caller's variable: no log line, no argv, no state file.
_pa_token_read() {
  local f v
  [ -n "$(pool_account_tokens_dir)" ] || return 1
  f=$(_pa_token_file "${1:-}")
  [ -r "$f" ] || return 1
  v=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}CLAUDE_CODE_OAUTH_TOKEN=//p' "$f" 2>/dev/null | head -1)
  v="${v%$'\r'}"; v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

# ---- leases -----------------------------------------------------------------
# One file per machine, so "how many builds is this account carrying right now"
# is a directory listing rather than a counter something can lose. mtime is the
# clock: a lease is live while it is younger than the TTL, which means a machine
# that vanished without a reap — the case a counter would get permanently wrong —
# releases its own account within ACCOUNT_LEASE_TTL_SECS.
# ── THE SHARED HALF (BH-1043) ────────────────────────────────────────────────
# The lease files below are per BOX, and the cap they enforce is per ACCOUNT.
# Two boxes each counting their own directory each saw a free account and each
# filled it to the cap: eight heavy sessions on an account
# fly/account-capacity.conf rates at ~4. The count now comes from the
# account_leases table when the worker can answer, and the CLAIM is a
# compare-and-swap there, so two boxes racing for the last slot cannot both be
# told they won. The files stay: they are what an operator reads on the box and
# what the release path walks, and they are the fallback when the worker is
# unreachable — which must behave exactly as this library did before.
#
# A worker that failed once is not asked again in this process. A pick ranks
# every account, so without this memo a down worker would cost one 8-second
# timeout PER ACCOUNT on a path whose whole job is to launch a machine quickly.
# POOL_ACCOUNT_DB_LEASES=0 turns the shared half off entirely.
_PA_DB_DOWN=""
_pa_db_off() {
  [ "${POOL_ACCOUNT_DB_LEASES:-1}" = 0 ] && return 0
  [ -n "${_PA_DB_DOWN:-}" ] && return 0
  return 1
}

# ONE REQUEST PER PICK, NOT ONE PER CANDIDATE. The rank below reads a count for
# every account in the registry, and bin/fly-pool.sh spawns up to ten machines a
# tick: a per-account GET would be seventy round trips every two minutes, each
# one in front of a machine that is waiting to launch. The whole fleet's counts
# come back in one call and the rank reads them out of an array. Loaded fresh at
# the top of every pool_account_lease, because a spawn loop in one process must
# not rank its tenth machine on the count its first machine saw.
declare -A _PA_DB_COUNT 2>/dev/null || true
_PA_DB_COUNTS_LOADED=""
_pa_db_counts_load() {
  local resp a n
  local JOBS_RETRIES=0 JOBS_TIMEOUT="${POOL_ACCOUNT_DB_TIMEOUT_S:-4}"
  _PA_DB_COUNTS_LOADED=""
  _pa_db_off && return 1
  command -v account_lease_counts >/dev/null 2>&1 || return 1
  resp=$(account_lease_counts 2>/dev/null) || { _PA_DB_DOWN=1; return 1; }
  _PA_DB_COUNT=()
  while IFS=$'\t' read -r a n; do
    case "$a" in '') continue ;; esac
    case "$n" in ''|*[!0-9]*) continue ;; esac
    _PA_DB_COUNT["$a"]="$n"
  done <<< "$resp"
  # An EMPTY answer is a real answer — no account is leased right now — and it
  # is the state a healthy quiet fleet is in most of the time. Only a failed
  # request leaves the map unloaded and the rank on files.
  _PA_DB_COUNTS_LOADED=1
  return 0
}

# _pa_db_count <account> -> the fleet-wide live count on stdout, rc 0; rc 1 when
# there is no answer. rc 1 is NOT zero: "no numbers" and "no leases" send the
# rank in opposite directions, and only one of them is a free account. An
# account the batch did not mention has no live lease, which IS zero.
_pa_db_count() {
  # A SIDE CHANNEL PAYS SIDE-CHANNEL LATENCY. bash's dynamic scoping makes these
  # locals visible inside _jobs_req, so a worker that is simply DOWN costs this
  # pick about four seconds rather than the client's default 8s timeout plus a
  # retry — on a */2 tick whose whole job is to get a machine launched.
  local n
  local JOBS_RETRIES=0 JOBS_TIMEOUT="${POOL_ACCOUNT_DB_TIMEOUT_S:-4}"
  _pa_db_off && return 1
  if [ -n "${_PA_DB_COUNTS_LOADED:-}" ]; then
    printf '%s' "${_PA_DB_COUNT[${1:-}]:-0}"
    return 0
  fi
  command -v account_lease_count >/dev/null 2>&1 || return 1
  n=$(account_lease_count "${1:-}" 2>/dev/null) || { _PA_DB_DOWN=1; return 1; }
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$n"
}

# _pa_db_claim <account> <machine-id> <project> <key> <cap>
#   rc 0 the slot is OURS, rc 1 REFUSED (the account is at cap fleet-wide),
#   rc 2 nobody knows — and rc 2 is a TAKE, not a refusal, because a launch that
#   does not happen is worse than a launch on a busy account.
_pa_db_claim() {
  local rc
  local JOBS_RETRIES=0 JOBS_TIMEOUT="${POOL_ACCOUNT_DB_TIMEOUT_S:-4}"
  _pa_db_off && return 2
  command -v account_lease_claim >/dev/null 2>&1 || return 2
  account_lease_claim "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" "$(_pa_ttl)" >/dev/null 2>&1
  rc=$?
  [ "$rc" = 2 ] && _PA_DB_DOWN=1
  return "$rc"
}

pool_account_leases() { # <account> -> live lease count
  local d f mt ttl now n=0
  if n=$(_pa_db_count "${1:-}"); then printf '%s\n' "$n"; return 0; fi
  n=0
  d=$(pool_account_lease_dir)
  [ -n "$d" ] || { printf '0\n'; return 0; }
  d="$d/${1:-}"
  ttl=$(_pa_ttl); now=$(date -u +%s)
  if [ -d "$d" ]; then
    for f in "$d"/*; do
      [ -f "$f" ] || continue
      mt=$(stat -c %Y "$f" 2>/dev/null) || continue
      case "$mt" in ''|*[!0-9]*) continue ;; esac
      [ "$(( now - mt ))" -lt "$ttl" ] && n=$((n+1))
    done
  fi
  printf '%s\n' "$n"
}

pool_account_prune() { # drop every lease older than the TTL. Cheap; runs per tick.
  local d f mt ttl now
  d=$(pool_account_lease_dir); [ -n "$d" ] && [ -d "$d" ] || return 0
  ttl=$(_pa_ttl); now=$(date -u +%s)
  for f in "$d"/*/*; do
    [ -f "$f" ] || continue
    mt=$(stat -c %Y "$f" 2>/dev/null) || continue
    case "$mt" in ''|*[!0-9]*) continue ;; esac
    [ "$(( now - mt ))" -ge "$ttl" ] && rm -f "$f"
  done
  return 0
}

pool_account_release() { # <machine-id> — the machine is gone; its account is free
  local mid="${1:-}" d f
  [ -n "$mid" ] || return 0
  case "$mid" in *[!A-Za-z0-9._-]*) return 0 ;; esac
  # The shared row first, and never gated on the file walk below: a machine
  # whose lease file was already swept must still free the slot the rest of the
  # fleet is counting. Fail-open — the TTL frees the row regardless, which is
  # what a machine that vanished without a release has always relied on.
  if ! _pa_db_off && command -v account_lease_release >/dev/null 2>&1; then
    account_lease_release "$mid" >/dev/null 2>&1 || true
  fi
  d=$(pool_account_lease_dir)
  [ -n "$d" ] && [ -d "$d" ] || return 0
  # File by file, never a glob delete: this runs beside `machine destroy` and the
  # blast radius of a mistyped variable here would be every account's leases.
  for f in "$d"/*/"$mid"; do
    [ -f "$f" ] && rm -f "$f"
  done
  return 0
}

# pool_account_rebind <old-id> <new-id> <account> [project] [key]  (BH-7215)
# spawn_one leases the account BEFORE `fly machine run`, so the lease is taken
# under a pre-launch id. Once the machine exists, this moves the lease to its
# machine id, and every reap path frees it with pool_account_release "$MID" as
# before. The shared row: claim the new id first (cap 0 = no cap check, the
# slot is already ours), then release the old id. A claim that does not answer
# rc 0 keeps the old row: it frees at its TTL, which over-counts the account by
# one (the safe side). A live machine with no row would under-count it.
# rc 0 = moved or nothing to do; rc 1 = the shared row did not move.
pool_account_rebind() {
  local old="${1:-}" new="${2:-}" acct="${3:-}" project="${4:-}" key="${5:-}" d rc
  [ -n "$acct" ] || return 0
  case "$old" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  case "$new" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  case "$acct" in *[!A-Za-z0-9._-]*) return 0 ;; esac
  [ "${#old}" -le 64 ] && [ "${#new}" -le 64 ] || return 0
  d=$(pool_account_lease_dir)
  if [ -n "$d" ] && [ -f "$d/$acct/$old" ]; then
    mv -f "$d/$acct/$old" "$d/$acct/$new" 2>/dev/null || true
  fi
  _pa_db_off && return 0
  command -v account_lease_claim >/dev/null 2>&1 || return 0
  local JOBS_RETRIES=0 JOBS_TIMEOUT="${POOL_ACCOUNT_DB_TIMEOUT_S:-4}"
  account_lease_claim "$acct" "$new" "$project" "$key" 0 "$(_pa_ttl)" >/dev/null 2>&1
  rc=$?
  [ "$rc" = 0 ] || return 1
  command -v account_lease_release >/dev/null 2>&1 \
    && account_lease_release "$old" "$acct" >/dev/null 2>&1
  return 0
}

# The same cooldown marker bin/agent-call.sh writes when an account refuses
# (state/quota/cooldown/<vendor>/<name>, epoch seconds), so account-pick.sh and
# this picker both skip the account for ACCOUNT_COOLDOWN_SECS. Written on the HUB
# from the reap, because the refusal happened on a machine that is about to not
# exist. The vendor is always `claude` here: this pool leases claude accounts and
# nothing else (the ACCT_VENDOR filter in pool_account_lease below).
#
# [reset-epoch] (2026-09-23 pool loop): the vendor said when this account comes
# back ("resets Sep 25, 5pm"), and a weekly limit does not reset in six hours —
# the fixed window put the account back in the rank long before it could serve,
# and the next launch spent a machine finding that out. So the cooldown runs to
# the reset instead. The stamp stays ONE epoch read against ONE window, the
# shape every reader already has (account_cooling, quota-status's
# cooldowns_json, quota-poll's sweep): it is written as reset - window, which
# is in the future for a reset further off than the window, and the file's
# mtime is set to that same epoch so quota-poll's mtime sweep does not collect
# it before the account is back. A reset in the past, unparseable, or further
# off than ACCOUNT_RESET_MAX_S is not believed: the normal stamp is written.
#
# THE LATER STAMP WINS (BH-1853). A write lower than the stamp already there is
# skipped, file and mtime untouched: a 6 h stamp must not shorten a week-long
# reset cooldown. Only deletion (operator, quota-poll's sweep) lowers one.
pool_account_cooldown() { # <account> <why> [reset-epoch]
  local a="${1:-}" d reset="${3:-}" now win max at f old
  case "$a" in ''|default|*[!a-z0-9._-]*) return 0 ;; esac
  now=$(date -u +%s)
  win=$(_pa_num "${ACCOUNT_COOLDOWN_SECS:-}" 21600)
  max=$(_pa_num "${ACCOUNT_RESET_MAX_S:-}" 691200)
  d=$(_pa_quotadir); [ -n "$d" ] || return 0
  d="$d/cooldown/claude"; f="$d/$a"
  old=$(_pa_num "$(cat "$f" 2>/dev/null)" 0)
  case "$reset" in ''|*[!0-9]*) reset="" ;; esac
  if [ -n "$reset" ] && [ "$reset" -gt "$now" ] && [ $(( reset - now )) -le "$max" ]; then
    at=$(( reset - win ))
    [ "$at" -gt "$old" ] || return 0
    if mkdir -p "$d" 2>/dev/null && printf '%s\n' "$at" > "$f.$$" 2>/dev/null && mv "$f.$$" "$f" 2>/dev/null; then
      touch -d "@$at" "$f" 2>/dev/null || true
      command -v fcd_put >/dev/null 2>&1 && fcd_put account claude "$a" "$reset" "$now" "pool:${2:-refusal}"
      command -v _acct_log >/dev/null 2>&1 && _acct_log - pool-execute - "$a" "cooldown:${2:-refusal}:until:$reset"
      return 0
    fi
  fi
  # The picker's own stamp when this lib was sourced beside it (same QUOTA_DIR
  # the reader uses), the inline write when it was sourced alone — both land on
  # the same file.
  [ "$(date -u +%s)" -gt "$old" ] || return 0
  if command -v account_cooldown_stamp >/dev/null 2>&1; then
    account_cooldown_stamp claude "$a"
  else
    mkdir -p "$d" 2>/dev/null || return 0
    date +%s > "$f" 2>/dev/null || return 0
    # The picker's stamp above puts its own fleet row; this inline write does not.
    command -v fcd_put >/dev/null 2>&1 && fcd_put account claude "$a" "$(( now + win ))" "$now" "pool:${2:-refusal}"
  fi
  command -v _acct_log >/dev/null 2>&1 && _acct_log - pool-execute - "$a" "cooldown:${2:-refusal}"
  return 0
}

# pool_account_others_ok <account> — 0 when at least one OTHER claude account
# could take a machine right now: registered, enabled, shippable (a tokens.d
# file), not cooling and with headroom — the same filters the lease rank applies.
# bin/fly-pool.sh asks it after a lease, to decide whether a machine may fall to
# OpenRouter when its own account runs out (it may not, while another account
# can serve: the operator, 2026-09-24). No registry, no picker: rc 1, nothing changes.
pool_account_others_ok() {
  local picked="${1:-}" a
  command -v accounts_load >/dev/null 2>&1 || return 1
  accounts_load
  for a in "${ACCOUNT_NAMES[@]+"${ACCOUNT_NAMES[@]}"}"; do
    [ "$a" = "$picked" ] && continue
    [ "${ACCT_VENDOR[$a]:-}" = claude ] || continue
    [ "${ACCT_ENABLED[$a]:-1}" = 1 ] || continue
    [ -r "$(_pa_token_file "$a")" ] || continue
    account_cooling claude "$a" && continue
    account_headroom "$a" "" || continue
    return 0
  done
  return 1
}

# pool_account_unpin <project> <ticket-key> <account> — drop the ticket's sticky
# pin when it names this account. The pin is what sends a relaunched ticket back
# to the account whose cache already holds it; for an account that just ran out
# that is the one place it must not go (2026-09-23). Keyed exactly as
# pool_account_lease writes it, and only a pin naming THIS account is removed.
pool_account_unpin() {
  local key f
  key=$(_acct_pin_key "${ACCOUNT_PIN_KEY:-${1:-}-${2:-}}" 2>/dev/null)
  [ -n "$key" ] && [ -n "${3:-}" ] && [ -n "$(_pa_quotadir)" ] || return 0
  f="$(_pa_quotadir)/pins/$key"
  [ "$(head -1 "$f" 2>/dev/null)" = "$3" ] && rm -f "$f"
  return 0
}

# ---- arming -----------------------------------------------------------------
# _pa_switch — rc 0 when switch.pool-account-routing-off[.<box>] (no row: the
# file flags/pool-account-routing-off) is ON, 1 when not, 2 when
# bin/lib/lane-switch.sh could not load. A subshell, so the resolver and the
# jobs client it loads never reach the caller; its output goes nowhere, so
# nothing but a reason reaches pool_account_armed's stdout.
_pa_switch() {
  ( HARNESS="$(_pa_h)"; . "$(dirname "${BASH_SOURCE[0]}")/lane-switch.sh" >/dev/null 2>&1 || exit 2; lane_switch pool-account-routing-off file ) >/dev/null 2>&1
}

# Prints the reason when it is NOT armed and returns 1. Armed prints nothing.
# kill_flag = switch.pool-account-routing-off[.<box>] is ON (see _pa_switch);
# when the resolver cannot load, the file alone answers, as it did before.
pool_account_armed() {
  local h td f stem rc=0
  h=$(_pa_h)
  [ "${POOL_ACCOUNT_ROUTING:-1}" = 0 ] && { printf 'routing_off'; return 1; }
  # No root and no POOL_TOKENS_DIR: unarmed whatever the switch says, so the
  # switch (whose resolver would be handed an empty root) is not asked.
  [ -n "$h" ] || [ -n "${POOL_TOKENS_DIR:-}" ] || { printf 'no_tokens_dir'; return 1; }
  if _pa_switch; then printf 'kill_flag'; return 1; else rc=$?; fi
  [ "$rc" = 2 ] && [ -n "$h" ] && [ -f "$h/flags/pool-account-routing-off" ] && { printf 'kill_flag'; return 1; }
  td=$(pool_account_tokens_dir)
  [ -n "$td" ] && [ -d "$td" ] || { printf 'no_tokens_dir'; return 1; }
  command -v accounts_load >/dev/null 2>&1 || { printf 'no_picker'; return 1; }
  accounts_load
  for f in "$td"/*-setup-token.env; do
    [ -r "$f" ] || continue
    stem=$(basename "$f" -setup-token.env)
    [ "${ACCT_VENDOR[$stem]:-}" = claude ] || continue
    [ "${ACCT_ENABLED[$stem]:-1}" = 1 ] || continue
    return 0
  done
  printf 'no_shippable_account'
  return 1
}

# ---- the pick ---------------------------------------------------------------
_pa_answer() { # <name> <reason> <label> <leases> <five_h>
  printf 'name=%s reason=%s label=%s leases=%s five_h=%s\n' \
    "${1:-default}" "${2:-}" "${3:-}" "${4:-0}" "${5:-}"
}

# The execute model, when the bundle happens to name it. Only two things read it
# — the ACCOUNT_MODELS allowlist and the per-model quota family — and both treat
# an empty model as "no opinion", so this stays a cheap grep and never a guess.
_pa_model() { # <bundle-global.env>
  local d="${1%/*}" m=""
  m=$(cat "$1" "$d"/*.env 2>/dev/null \
      | sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}EXECUTE_MODEL=//p' | head -1)
  m="${m%\"}"; m="${m#\"}"; m="${m%\'}"; m="${m#\'}"
  case "$m" in *[!A-Za-z0-9._-]*) m="" ;; esac
  printf '%s' "$m"
}

# The pool's half of account-pick.sh's account_reading_class — the SAME reading,
# a different verdict on two of the classes, and the difference is the point:
#
#   metered     rankable, on the pct it just read
#   unreadable  RANKABLE, with an EMPTY meter (2026-09-16). quota-poll.sh writes
#               `unreadable` for every claude account that has no
#               CLAUDE_CONFIG_DIR, which is every account this picker can ship —
#               a setup token gets 403 on the usage endpoint, so there is nothing
#               honest to write. Reading that as "no headroom" ranked ZERO
#               accounts and shipped the capped default token to every machine
#               for hours. It is not evidence of anything: cooldowns route these.
#   stale/none  still skipped. A poller that STOPPED is a different failure from
#               a poller that answered, and the header's inversion holds for it —
#               the fallback here is a token that works, so guessing at numbers
#               we have no fresh evidence for can cost a 40-minute build.
#   capped      skipped, same as the hub.
#
# Prints the 5-hour pct (possibly empty) and returns 0 when the account is
# rankable. On a refusal it prints the DROP CLASS instead and returns 1, so the
# caller can say which class left the pool on the default token rather than
# logging one word for every cause.
# BH-1456: the classifier now prints THREE fields, and the third is WHICH rule
# refused. Reading two would fold `overage` into the meter and rank the account
# on the string "84|overage", so the third name is not optional here. A capped
# drop carries its detail (`capped:spend_limit`) so the pool's log says which
# billing fact parked the account, and an overage account ranks on the extra
# meter the classifier chose — the subscription window it is past no longer
# bounds it.
_pa_metered() { # <account> <model>
  local cls five detail
  IFS='|' read -r cls five detail <<< "$(account_reading_class "$1" "${2:-}")"
  case "$cls" in
    metered)    printf '%s' "${five:-}"; return 0 ;;
    unreadable) return 0 ;;
    capped)     printf 'capped%s' "${detail:+:$detail}"; return 1 ;;
    *)          printf 'no_meter'; return 1 ;;
  esac
}

# Which CLASS of refusal left the pool on the default token, from the drop
# classes the rank loop collected. `default_saturated` meant both "every account
# is exhausted" and "we cannot read any account", and an operator reading the
# 2026-09-16 log could not tell which — one is a quota problem, the other is an
# instrumentation problem, and they have nothing to do with each other.
# Structural non-candidates (no shippable token, model not allowed) are not
# counted: those are not saturation.
_pa_saturated_reason() { # <drop classes, one per line>
  local d="${1:-}"
  [ -n "$d" ] || { printf 'default_saturated'; return 0; }
  # The `:detail` suffix _pa_metered now adds (BH-1456) is stripped before the
  # sort: `capped:spend_limit` and `capped:week` are both the CLASS `capped`, and
  # a set of two details is still all_capped, not a mixed set. The detail belongs
  # in the per-account drop row, which is where it is; this line is the one-word
  # answer to "why is the pool on the default token".
  d=$(printf '%s\n' "$d" | sed 's/:.*//')
  case "$(printf '%s\n' "$d" | sort -u)" in
    capped)    printf 'all_capped' ;;
    # `all_stale`, NOT `all_unreadable`: after this change the `unreadable`
    # status is the one that RANKS, so it can never reach here. The only way
    # every account loses its meter is a poll that stopped or never happened,
    # and an operator who read `all_unreadable` would go looking at quota-poll's
    # `unreadable` status and find accounts that are perfectly rankable.
    no_meter)  printf 'all_stale' ;;
    cooling)   printf 'all_cooling' ;;
    lease_cap) printf 'all_leased' ;;
    *)         printf 'default_saturated' ;;
  esac
}

# pool_account_lease <project> <ticket-key> <bundle-global.env> <machine-id>
#
# Swaps the bundle's CLAUDE_CODE_OAUTH_TOKEN for a leased account's, writes the
# lease, drops a one-entry fingerprint overlay beside the bundle for the caller to
# push, and prints one line for the caller's log. ALWAYS exits 0.
pool_account_lease() {
  local project="${1:-}" key="${2:-}" bundle="${3:-}" mid="${4:-}"
  local why pick reason label model cap weight scanned ranked pinkey pinfile pinned
  local a lv five fnum score tok fp dir lease_dir now
  local cands crc nranked refused

  [ -s "$bundle" ] || { _pa_answer default no_bundle "" 0 ""; return 0; }
  case "$mid" in ''|*[!A-Za-z0-9._-]*) _pa_answer default bad_machine_id "" 0 ""; return 0 ;; esac
  # BH-1657: a project pinned to its own account never spends a pool account. No
  # lease, no DB claim; the bundle's token is REPLACED by the pinned label's. A
  # pinned project whose token file is missing fails closed: the token line is
  # STRIPPED, so the machine has no claude credential and its ladder descends to
  # the non-claude rung instead of spending project-6 (rc 3 from the resolver).
  # Checked before arming on purpose: an unarmed pool would otherwise ship the
  # project-6 token to a project that owns its own account.
  if [ -r "$(dirname "${BASH_SOURCE[0]}")/project-account.sh" ]; then
    . "$(dirname "${BASH_SOURCE[0]}")/project-account.sh"
    local own_label own_exp
    own_label=$(account_label_for_project "$project")
    if [ -n "$own_label" ]; then
      own_exp=$(project_account_exports "$project")
      tok="${own_exp#*=\'}"; tok="${tok%\'}"; own_exp=""
      if [ -n "$tok" ]; then
        ( umask 077
          grep -v '^CLAUDE_CODE_OAUTH_TOKEN=' "$bundle" > "$bundle.new" 2>/dev/null
          printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$tok" >> "$bundle.new" )
        fp=$( export CLAUDE_CODE_OAUTH_TOKEN="$tok"
              if command -v auth_fp_for_runner >/dev/null 2>&1; then auth_fp_for_runner claude
              else printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN" | sha256sum | cut -c1-12; fi )
        tok=""
        if [ -s "$bundle.new" ] && mv "$bundle.new" "$bundle" 2>/dev/null; then
          chmod 600 "$bundle" 2>/dev/null || true
          [ -n "$fp" ] && [ "$fp" != none ] && command -v jq >/dev/null 2>&1 && \
            ( umask 077; jq -nc --arg fp "$fp" --arg l "$own_label" '{($fp):$l}' > "${bundle%/*}/auth-accounts.local.json" ) 2>/dev/null
          command -v _acct_log >/dev/null 2>&1 && _acct_log "$project" pool-execute "" "$own_label" own_account
          _pa_answer default own_account "$own_label" 0 ""; return 0
        fi
        rm -f "$bundle.new"
      fi
      ( umask 077; grep -v '^CLAUDE_CODE_OAUTH_TOKEN=' "$bundle" > "$bundle.new" 2>/dev/null )
      mv "$bundle.new" "$bundle" 2>/dev/null || { rm -f "$bundle.new"; : > "$bundle"; }
      command -v _acct_log >/dev/null 2>&1 && _acct_log "$project" pool-execute "" "$own_label" own_account_unavailable
      _pa_answer default own_account_unavailable "$own_label" 0 ""; return 0
    fi
  fi
  why=$(pool_account_armed) || { _pa_answer default "$why" "" 0 ""; return 0; }
  # The arming check ran in a command substitution, so ITS accounts_load populated
  # a subshell's arrays and not ours. Load the registry here, in this shell, or the
  # rank below iterates an empty ACCOUNT_NAMES and every launch reads as saturated.
  accounts_load

  model=$(_pa_model "$bundle")
  cap=$(pool_account_max_leases); weight=$(_pa_weight)
  # The fleet's lease counts, once, before the rank reads them per account.
  # A failed load leaves the rank on this box's own files, exactly as before.
  _pa_db_counts_load || true

  # Two kinds of line come out of one pass: `r` = a ranked candidate, `x` = the
  # class of a refusal. The refusals are what names the fallback below, and they
  # have to be collected in the same loop that makes them or the answer is a
  # second guess at state that has already moved.
  #
  # An `r` line is priority \t score \t name \t leases \t 5h — lowest priority
  # number first (the registry's own order), then the lease-weighted meter, then
  # the name so two readers of the same state answer the same thing. The score is
  # zero-padded so a plain string sort orders it correctly, and an account with no
  # meter at all (the `unreadable` class) scores on the 999 default, which leaves
  # priority and live leases doing the ranking.
  scanned=$(for a in "${ACCOUNT_NAMES[@]+"${ACCOUNT_NAMES[@]}"}"; do
    [ "${ACCT_VENDOR[$a]:-}" = claude ] || continue
    [ "${ACCT_ENABLED[$a]:-1}" = 1 ] || continue
    # a login-only account cannot ship: no tokens.d file, no pool lease
    [ -r "$(_pa_token_file "$a")" ] || continue
    _acct_models_allow "${ACCT_MODELS[$a]:-}" "$model" || continue
    account_cooling claude "$a" && { printf 'x\tcooling\n'; continue; }
    account_headroom "$a" "$model" || { printf 'x\tcapped\n'; continue; }
    # on a refusal $five carries the drop class, not a meter
    five=$(_pa_metered "$a" "$model") || { printf 'x\t%s\n' "${five:-no_meter}"; continue; }
    lv=$(pool_account_leases "$a")
    [ "$cap" -gt 0 ] && [ "$lv" -ge "$cap" ] && { printf 'x\tlease_cap\n'; continue; }
    fnum=$(_pa_num "${five%%.*}" 999)
    score=$(awk -v f="$fnum" -v l="$lv" -v w="$weight" 'BEGIN{ printf "%09.3f", f + l * w }')
    printf 'r\t%s\t%s\t%s\t%s\t%s\n' "${ACCT_PRIORITY[$a]:-50}" "$score" "$a" "$lv" "${five:-}"
  done)
  ranked=$(awk -F'\t' '$1 == "r" { sub(/^r\t/, ""); print }' <<<"$scanned" \
           | sort -t$'\t' -k1,1n -k2,2 -k3,3)

  if [ -z "$ranked" ]; then
    # Never a refused launch: the bundle ships as it arrived and the build runs on
    # the project-6 token exactly as it did before this change. The reason NAMES
    # the class, so bin/fly-pool.sh's "ships the default project-6 token (...)"
    # line tells the next operator whether the fleet is exhausted or blind.
    reason=$(_pa_saturated_reason "$(awk -F'\t' '$1 == "x" { print $2 }' <<<"$scanned")")
    command -v _acct_log >/dev/null 2>&1 && _acct_log "$project" pool-execute "$model" default "$reason"
    _pa_answer default "$reason" "" 0 ""
    return 0
  fi

  # Sticky per ticket, for the reason the hub's picker is sticky: a rebuilt or
  # re-launched ticket lands on the account whose prompt cache already has it.
  pick=""; reason=""; refused=0
  pinkey=$(_acct_pin_key "${ACCOUNT_PIN_KEY:-$project-$key}")
  if [ -n "$pinkey" ] && [ -n "$(_pa_quotadir)" ]; then
    pinfile="$(_pa_quotadir)/pins/$pinkey"
    pinned=$(head -1 "$pinfile" 2>/dev/null)
    printf '%s\n' "$ranked" | cut -f3 | grep -qxF "${pinned:-}" || pinned=""
  fi

  # THE RANK PROPOSES; THE CAS DISPOSES (BH-1043). The meter and the lease count
  # are both readings of a world that moves while this function runs — ten
  # machines launch inside a minute, and two boxes can rank the same account as
  # the best free one in the same second. So the head of the rank is a CANDIDATE
  # and the claim is what decides: the worker checks the cap inside one INSERT,
  # and a box that loses that race walks on to the next candidate instead of
  # ranking itself a second heavy session onto an account that is already full.
  #
  # An UNKNOWN answer takes the candidate and stops asking. That is the same
  # fail-open inversion the rest of this file keeps: the fallback for "we could
  # not coordinate" is the behaviour this library had before the table existed,
  # never a refused launch.
  nranked=$(printf '%s\n' "$ranked" | grep -c '')
  cands=$(printf '%s\n%s\n' "${pinned:-}" "$(printf '%s\n' "$ranked" | cut -f3)" \
          | awk 'NF && !seen[$0]++')
  for a in $cands; do
    _pa_db_claim "$a" "$mid" "$project" "$key" "$cap"; crc=$?
    [ "$crc" = 1 ] && { refused=$((refused+1)); continue; }
    pick="$a"
    if [ -n "${pinned:-}" ] && [ "$a" = "$pinned" ]; then reason=pinned
    elif [ "$nranked" -eq 1 ]; then reason=only
    else reason=lease_rank
    fi
    break
  done

  if [ -z "$pick" ]; then
    # Every candidate was refused by the shared cap — the fleet really is full,
    # and this is the one refusal class the ranked path can produce. Same
    # answer shape as a saturated rank: the bundle ships as it arrived.
    command -v _acct_log >/dev/null 2>&1 && _acct_log "$project" pool-execute "$model" default all_leased
    _pa_answer default all_leased "" 0 ""
    return 0
  fi
  lv=$(printf '%s\n' "$ranked" | awk -F'\t' -v a="$pick" '$3 == a { print $4; exit }')
  five=$(printf '%s\n' "$ranked" | awk -F'\t' -v a="$pick" '$3 == a { print $5; exit }')
  label="${ACCT_LABEL[$pick]:-}"

  # The claim above is already in the shared table, so every path that gives the
  # account back has to say so — a slot held for the TTL by a launch that never
  # happened is a slot the rest of the fleet cannot have.
  _pa_give_back() { command -v account_lease_release >/dev/null 2>&1 && ! _pa_db_off \
                    && account_lease_release "${1:-}" "${2:-}" >/dev/null 2>&1; return 0; }
  tok=$(_pa_token_read "$pick") || {
    _pa_give_back "$mid" "$pick"
    command -v _acct_log >/dev/null 2>&1 && _acct_log "$project" pool-execute "$model" default "token_unreadable:$pick"
    _pa_answer default token_unreadable "" 0 ""; return 0; }

  # REPLACED, not appended — a later CLAUDE_CODE_OAUTH_TOKEN= is what the
  # builder's `set -a; . global.env` would use, so an append would ship the
  # project-6 token under a lease claiming otherwise. The original is only
  # replaced once the new file is non-empty, so a failed rewrite ships the bundle
  # it arrived with.
  ( umask 077
    grep -v '^CLAUDE_CODE_OAUTH_TOKEN=' "$bundle" > "$bundle.new" 2>/dev/null
    printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$tok" >> "$bundle.new" )
  if [ ! -s "$bundle.new" ] || ! grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' "$bundle.new" 2>/dev/null; then
    rm -f "$bundle.new"; tok=""
    _pa_give_back "$mid" "$pick"
    command -v _acct_log >/dev/null 2>&1 && _acct_log "$project" pool-execute "$model" default "swap_empty:$pick"
    _pa_answer default swap_empty "" 0 ""; return 0
  fi
  if ! mv "$bundle.new" "$bundle" 2>/dev/null; then
    rm -f "$bundle.new"; tok=""
    _pa_give_back "$mid" "$pick"
    _pa_answer default swap_failed "" 0 ""; return 0
  fi
  chmod 600 "$bundle" 2>/dev/null || true

  # THE COST ROW HAS TO CARRY THE ACCOUNT, and on a pool machine nothing else can
  # make it: ACCOUNT_ROUTING and the registry never ride the bundle, so
  # agent-call.sh's `acct:<name>` fallback is unreachable there and every row would
  # land under whatever the fingerprint resolves to — today, unlabelled. So the
  # machine is handed the one thing that DOES resolve: the fp->label overlay
  # bin/auth-fingerprint.sh reads at row-write time (state/auth-accounts.local.json,
  # which on a machine is /data/harness/state). Same fingerprint function
  # agent-call.sh will run there, computed here over the token we just shipped, in a
  # subshell so this process's own env is untouched.
  dir="${bundle%/*}"
  fp=$( export CLAUDE_CODE_OAUTH_TOKEN="$tok"
        if command -v auth_fp_for_runner >/dev/null 2>&1; then auth_fp_for_runner claude
        else printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN" | sha256sum | cut -c1-12; fi )
  tok=""
  if [ -n "$fp" ] && [ "$fp" != none ] && [ -n "$label" ] && command -v jq >/dev/null 2>&1; then
    ( umask 077; jq -nc --arg fp "$fp" --arg l "$label" '{($fp):$l}' > "$dir/auth-accounts.local.json" ) 2>/dev/null || true
  fi

  lease_dir=$(pool_account_lease_dir)
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  if [ -n "$lease_dir" ] && lease_dir="$lease_dir/$pick" && mkdir -p "$lease_dir" 2>/dev/null; then
    if command -v jq >/dev/null 2>&1 \
       && jq -nc --arg p "$project" --arg k "$key" --arg t "$now" \
            '{project:$p,ticket_key:$k,started_at:$t}' > "$lease_dir/$mid" 2>/dev/null; then
      :
    else
      printf '%s %s %s\n' "$project" "$key" "$now" > "$lease_dir/$mid" 2>/dev/null || true
    fi
  fi
  if [ -n "$pinkey" ] && [ -n "$(_pa_quotadir)" ] && mkdir -p "$(_pa_quotadir)/pins" 2>/dev/null; then
    printf '%s\n' "$pick" > "$(_pa_quotadir)/pins/$pinkey" 2>/dev/null || true
  fi

  command -v _acct_log >/dev/null 2>&1 && _acct_log "$project" pool-execute "$model" "$pick" "$reason"
  # The lease this machine just took counts from here on, so the number the caller
  # logs is the one the NEXT pick will see.
  _pa_answer "$pick" "$reason" "$label" "$(( lv + 1 ))" "${five:-}"
  return 0
}
