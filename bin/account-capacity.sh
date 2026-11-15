#!/bin/bash
# bin/account-capacity.sh [vendor] [project] — how many heavy sessions of a vendor this
# fleet can actually run at once, and why.
#
#   usage:  account-capacity.sh [claude|codex|grok|openrouter|fireworks] [project]
#   stdout: "<n> (<why>)"  or  "unlimited (<why>)"
#
# THE CEILING NOBODY WROTE DOWN. Every other cap in the build path is about
# machines — pool machines, box slots, wip limits — and none of them is the one
# that actually stalls. docs/LESSONS.md #6: "MODEL CAPACITY IS THE THROUGHPUT
# CEILING, NOT HARDWARE. 2-core boxes build fine; every stall was account
# weather (session caps, org spend caps, 429s). Parallel lanes multiply burn
# against one account (~3-4 heavy sessions max)."
#
# That matters most exactly where it is least visible: bin/fly-envbundle.sh
# builds the bundle with ONE CLAUDE_CODE_OAUTH_TOKEN, and until 2026-09-14 every
# machine in a project's Fly pool got that same one — so a pool cap of 20 was 20
# sessions on one account, not 20 accounts.
#
# SINCE 2026-09-14 THAT IS CONDITIONAL, so the count is too. bin/lib/pool-account.sh
# leases a per-machine account at launch, and the accounts it can lease are the
# ones with a SHIPPABLE token in env/tokens.d — a login-only registry entry
# (CLAUDE_CONFIG_DIR, no tokens.d file) can pay for a call on the box itself but
# cannot be handed to a Fly machine. So when that directory exists and holds at
# least one token, the claude count below is the accounts that can actually ship
# (plus `default`, which is what an unarmed or saturated launch still uses); with
# no env/tokens.d — every box except the hub — the count is exactly what it was.
#
# DATA FIRST, CONSTANT LAST, and it says which it used:
#   1. state/quota/<account>.json (bin/quota-poll.sh) — accounts of this vendor
#      that are enabled, not cooling down, and not already at 100%.
#   2. env/accounts.d/*.env — the registry, when no quota has been polled yet.
#   3. the implicit `default` account alone, which is what every non-routed call
#      on a box already uses (docs/ACCOUNT-ROUTING.md; ACCOUNT_ROUTING defaults
#      off, and an unrouted fleet has exactly one account).
# multiplied by fly/account-capacity.conf's per-account number, else 4.
#
# API KEY PROJECTS (BH-9719). With vendor claude and a project whose settings
# row claude_auth.<project> is `api-key`, the answer is `unlimited (...)`: that
# project is billed per token and has no subscription session meter to count.
# Its brake is a spend cap (bin/lib/budget-stop.sh). No quota or registry read
# happens for it, and one line per project per UTC day goes to
# logs/account-capacity.log (bin/lib/meter-skip.sh). bin/concurrency-apply.sh
# passes the project.
#
# Read-only: never calls out, never reads a credential, never prints a label
# that is not already in the registry. With a project argument it reads the
# settings cache through lane-gate (which can refresh it from the jobs worker),
# and it writes one log line a day per skipped project. Always exits 0 — a planner that cannot
# read this must fall back to its own judgement, never to a stack trace (the
# bin/free-slots.sh contract).
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
V="${1:-claude}"

# Metered API vendors have no session ceiling — their ceiling is a spend cap.
# Inventing a concurrency number for them would be worse than having none.
case "$V" in
  grok|openrouter|fireworks)
    echo "unlimited ($V is billed per token with no session ceiling — its limit is a spend cap, not concurrency)"
    exit 0 ;;
esac

# An api-key claude project has no session meter: say so, once a day in the log.
if [ "$V" = claude ] && [ -n "${2:-}" ]; then
  # shellcheck source=bin/lib/meter-skip.sh
  if . "$(dirname "${BASH_SOURCE[0]}")/lib/meter-skip.sh" 2>/dev/null && meter_skip_api_key "$2"; then
    echo "unlimited ($2 pays for claude with its own API key (claude_auth.$2=api-key): billed per token, no subscription session meter; its brake is a spend cap, budget.project.$2.day_usd / cost_ceiling.$2)"
    meter_skip_log_once account-capacity "$2" "$H/logs/account-capacity.log" \
      "account-capacity: skipped $2: claude_auth.$2=api-key, no subscription meter to count"
    exit 0
  fi
fi

num() { case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }

# --- can this account be handed to a Fly builder? ----------------------------
# Only for claude, and only when env/tokens.d exists with at least one token in
# it: everywhere else this answers "yes" for every account and the counts below
# are byte-identical to what they were before per-machine leasing existed.
TOKENS_DIR="${POOL_TOKENS_DIR:-$HENV/tokens.d}"
SHIP_FILTER=0
if [ "$V" = claude ] && [ -d "$TOKENS_DIR" ]; then
  for f in "$TOKENS_DIR"/*-setup-token.env; do
    [ -r "$f" ] && { SHIP_FILTER=1; break; }
  done
fi
shippable() { # <account>
  [ "$SHIP_FILTER" = 1 ] || return 0
  # `default` is the project-6 token the bundle already carries: always shippable.
  [ "$1" = default ] && return 0
  [ -r "$TOKENS_DIR/$1-setup-token.env" ]
}

# Per-account heavy sessions: the reviewed line, else the documented default.
PER=""
if [ -r "$H/fly/account-capacity.conf" ]; then
  PER=$(grep -vE '^[[:space:]]*#' "$H/fly/account-capacity.conf" 2>/dev/null \
        | awk -v v="$V" '$1 == v { print $2; exit }' | tr -dc '0-9')
fi
PERSRC="fly/account-capacity.conf"
if [ -z "$PER" ]; then PER=4; PERSRC="the docs/LESSONS.md#6 default"; fi

# --- 1. quota data, if any account of this vendor has been polled -------------
# The JSON shape is bin/quota-status.sh --json: one object per account with
# .vendor, .enabled, .status, .cooldown_until and .five_hour.pct. An account
# that is cooling down or already at 100% is not headroom, and counting it would
# promise parallelism the vendor will refuse.
QUOTA_DIR="${QUOTA_DIR:-$H/state/quota}"
ACC=""; SRC=""
if [ -d "$QUOTA_DIR" ] && [ -x "$H/bin/quota-status.sh" ] && command -v jq >/dev/null 2>&1; then
  J=$("$H/bin/quota-status.sh" --json 2>/dev/null) || J=""
  if [ -n "$J" ]; then
    # NAMES, not a length: with per-machine leasing armed the ones that cannot
    # ship have to be dropped, and that is a file test this jq cannot make.
    NAMES=$(printf '%s' "$J" | jq -r --arg v "$V" '
      .[]? | select(.vendor == $v) | select(.enabled == true)
           | select(.cooldown_until == null)
           | select((.five_hour.pct // 0) < 100) | .account' 2>/dev/null)
    N=0
    for a in $NAMES; do shippable "$a" && N=$((N+1)); done
    ACC="$N"
    [ -n "$ACC" ] && [ "$ACC" != 0 ] && SRC="$ACC polled $V account(s) with headroom$( [ "$SHIP_FILTER" = 1 ] && printf ' that can ship to a Fly machine')"
    [ "$ACC" = 0 ] && { ACC=""; }   # every account exhausted is a weather report,
                                    # not a ceiling — fall through and say so below
  fi
fi

# --- 2. the registry, when nothing has been polled ----------------------------
if [ -z "$ACC" ] && [ -d "$HENV/accounts.d" ]; then
  N=0
  for f in "$HENV/accounts.d"/*.env; do
    [ -f "$f" ] || continue
    ven=$(grep -m1 '^ACCOUNT_VENDOR=' "$f" 2>/dev/null | cut -d= -f2- | tr -d '"'"'"' \r')
    en=$(grep -m1 '^ACCOUNT_ENABLED=' "$f" 2>/dev/null | cut -d= -f2- | tr -d '"'"'"' \r')
    [ "$ven" = "$V" ] || continue
    [ "${en:-1}" = 0 ] && continue
    shippable "$(basename "$f" .env)" || continue
    N=$((N+1))
  done
  if [ "$N" -gt 0 ]; then
    # Plus the implicit `default` account, which every non-routed call still
    # uses — a registry does not replace it, it adds to it.
    if [ "$V" = claude ]; then N=$((N+1)); fi
    ACC="$N"; SRC="$N registered $V account(s) in env/accounts.d (unpolled)$( [ "$SHIP_FILTER" = 1 ] && printf ', shippable to a Fly machine')"
  fi
fi

# --- 3. the implicit default account, alone -----------------------------------
if [ -z "$ACC" ]; then
  ACC=1
  SRC="1 account (the implicit 'default' — no accounts.d registry and no quota poll on this machine)"
fi

echo "$(( ACC * PER )) ($SRC x $PER heavy session(s) each, per $PERSRC)"
