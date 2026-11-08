#!/bin/bash
# bin/lib/sg-prime-relay.sh — sourced by bin/fly-pool.sh (BH-9094). Defines
# sg_prime_relay and nothing else.
#
# bin/selection-gate-prime.sh primes the selection gate's base-run cache on the
# hub and writes state/selection-gate/prime.tsv. Every cromford gate runs
# on a pool machine, where bin/selection-gate.sh baseline_pass reads
# /data/harness/state/selection-gate/prime.tsv as cached answers. This relay
# puts the hub copy there, in the live-machine refresh block of each tick.
#
# sg_prime_relay <machine-id> — one mput of prime.tsv to the machine, only when:
#   - the pool's repo (POOL_SLUG) is the harness's own repo (HARNESS_REPO,
#     bin/lib/deployment.sh), compared case-insensitively, as push_bake_evidence
#     does: no other project runs the selection gate;
#   - $HARNESS/state/selection-gate/prime.tsv is not empty;
#   - its mtime differs from the one in the sidecar $POOL/.<mid>.sgprimemt.
# The sidecar is written only after mput returned 0, so a failed put is tried
# again on the next tick (mput writes its own `push FAILED` note). Always rc 0:
# a lost relay costs a cold cache, never the tick.
# The root is ${HARNESS:-${H:-}} only (D43); with no root it does nothing.
sg_prime_relay() {
  local mid="${1:-}" root="${HARNESS:-${H:-}}" src mt last hrepo
  [ -n "$mid" ] && [ -n "$root" ] && [ -n "${POOL:-}" ] && [ -n "${POOL_SLUG:-}" ] || return 0
  hrepo=$( . "$root/bin/lib/deployment.sh" 2>/dev/null && printf '%s' "${HARNESS_REPO:-}" )
  [ -n "$hrepo" ] && [ "${POOL_SLUG,,}" = "${hrepo,,}" ] || return 0
  src="$root/state/selection-gate/prime.tsv"
  [ -s "$src" ] || return 0
  mt=$(stat -c %Y "$src" 2>/dev/null) || return 0
  last=$(cat "$POOL/.$mid.sgprimemt" 2>/dev/null || echo 0)
  [ "$mt" != "$last" ] || return 0
  if mput "$mid" "$src" /data/harness/state/selection-gate/prime.tsv; then
    echo "$mt" > "$POOL/.$mid.sgprimemt"
    declare -F say >/dev/null 2>&1 && say "relayed the selection-gate prime (mtime $mt) to $mid"
  fi
  return 0
}
