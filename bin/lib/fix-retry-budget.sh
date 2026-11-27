# shellcheck shell=bash
# bin/lib/fix-retry-budget.sh — BH-10057: the agent budget of a fix round that
# BH-9404 retries after a timeout (agent rc 124). Pure functions, no I/O.
#
# The retry round gets FIX_AGENT_TIMEOUT * BR_FIX_TIMEOUT_RETRY_PCT / 100
# seconds. The percent is clamped to 110..400, so the retry is always larger
# than the round that ran out. Readers: bin/blocked-resolver.d/
# bh-10057-timeout-budget.sh (the round's agent call, br_fix_bound on the hub)
# and bin/fix-round-claim.sh frc_bound (the box's round bound and the claim's
# stale cutoff).

# frb_pct <raw> — prints a usable percent.
#   Empty: 150, rc 0 (no registry row and no env: the documented fallback).
#   Not a whole number (abc, 1.5, -1): 150 and rc 3, so the caller can say one line.
#   Below 110: 110. Above 400: 400.
frb_pct() {
  local v="${1:-}"
  # fallback 150; row lane.blocked-resolver.BR_FIX_TIMEOUT_RETRY_PCT
  [ -n "$v" ] || { printf '150'; return 0; }
  case "$v" in *[!0-9]*) printf '150'; return 3 ;; esac
  v=$((10#$v))
  [ "$v" -lt 110 ] && v=110
  [ "$v" -gt 400 ] && v=400
  printf '%s' "$v"
}

# frb_retry_s <agent_s> <pct> — prints agent_s * pct / 100 (integer).
#   agent_s or pct not a whole number: rc 1, nothing printed.
frb_retry_s() {
  local a="${1:-}" pc="${2:-}"
  [[ "$a" =~ ^[0-9]+$ ]] && [[ "$pc" =~ ^[0-9]+$ ]] || return 1
  printf '%s' $(( 10#$a * 10#$pc / 100 ))
}

# frb_agent_max <agent_s> <retries> <pct> — the longest agent call of any round:
#   the retry budget when retries are on, else agent_s. retries empty or not a
#   whole number reads as 1, the fallback brtr_knob uses (the writer takes a
#   retry then, so the bound must admit it). rc 1 when agent_s is not a whole number.
frb_agent_max() {
  local a="${1:-}" r="${2:-}" pc="${3:-}"
  [[ "$a" =~ ^[0-9]+$ ]] || return 1
  [[ "$r" =~ ^[0-9]+$ ]] || r=1
  if [ "$((10#$r))" -gt 0 ]; then
    frb_retry_s "$a" "$pc" || printf '%s' "$((10#$a))"
  else
    printf '%s' "$((10#$a))"
  fi
}
