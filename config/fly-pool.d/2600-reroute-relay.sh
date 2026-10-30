# >>> reroute relay (BH-584)
# The same reason as the pre-plan above, for a different file: a pool machine has
# no hub state, so the record bin/overlap-guard.sh just wrote — "this ticket's
# test cases go to <per-ticket>, a sibling is holding <shared>" — has to ride
# with the job or the builder never sees it. Every project-5 and project-4 build is a
# pool build, so without this the reroute would be a hub-only rule.
#
# NOT gated on preplan_speculative: the record exists whenever the guard
# rerouted, with or without a speculative pre-plan, and dropping it on boxes
# with pre-planning off would send them to build on the file they were routed
# away from.
#
# Never fatal: every path returns 0. A failed relay costs the shared-file
# conflict this ticket would have had before the reroute existed.
push_reroute() { # push_reroute <machine-id> <key>
  local mid="${1:-}" k="${2:-}" rec
  [ -n "$mid" ] && [ -n "$k" ] || return 0
  command -v th_record_path >/dev/null 2>&1 || return 0
  rec=$(th_record_path "$HARNESS" "$P" "$k")
  [ -r "$rec" ] && [ -s "$rec" ] || return 0
  if mput "$mid" "$rec" "$(th_relay_path "$P" "$k")"; then
    say "relayed test reroute for $k to $mid"
  else
    say "test reroute relay for $k to $mid failed — machine builds without it"
  fi
  return 0
}
# <<< reroute relay
