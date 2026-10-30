# >>> pool relay retry (BH-1041)
# pool_relay_retry — re-ask the ledger about every result this hub PARKED rather
#   than pushed. Runs once per tick, before the reap, inside the per-project
#   flock the tick already holds.
#
#   WHY IT EXISTS. A reap that could not read the ledger now pushes nothing
#   (unknown is not "absent"), which is only safe because this asks again two
#   minutes later. Without it a blink of the coordination DB would strand a
#   finished build hub-side for ever, which is the TK-124 class the row path was
#   built to end.
#
#   BOUNDED BY CONSTRUCTION: one iteration per RELAY_DEFERRED marker on this
#   hub, one ledger read each, no network call for a dir that has none. Nothing
#   waits: a dir the ledger still cannot answer for is silently left for the
#   next tick, and bin/pipeline-health.sh pages if it never resolves.
pool_relay_retry() {
  command -v bd_result_in_ledger >/dev/null 2>&1 || return 0
  command -v job_artifact_feed  >/dev/null 2>&1 || return 0
  local d k t line pr tier rc rbox mbd
  for d in "$HARNESS/builds/pool-$P-"*; do
    [ -f "$d/RELAY_DEFERRED" ] || continue
    # A dir that got its custody some other way (a re-reap, a hand delivery) is
    # done: drop the marker and make no call.
    [ -f "$d/RELAYED" ] && { rm -f "$d/RELAY_DEFERRED"; continue; }
    [ -s "$d/RESULT" ] || continue
    # The reap names the dir pool-<project>-<key>-<ts>; the key is what is left
    # once its own prefix and the timestamp come off. `%-*` takes ONE trailing
    # -field, which is right only because the timestamp is `date +%Y%m%d%H%M`
    # with no hyphen in it (the reap, below). Change that format and this
    # derivation has to change with it — there is no other copy of the key in
    # the parked dir, and the hub json this function reads for ticket_id is
    # itself named by the key.
    k=$(basename "$d"); k=${k#"pool-$P-"}; k=${k%-*}
    [ -n "$k" ] || continue
    line=$(head -1 "$d/RESULT")
    # The parked RESULT still carries the machine's own BUILD_DIR: line, so the
    # retry asks about THIS BUILD's row exactly as the reap did (BH-1041).
    mbd=$(grep -oE '^BUILD_DIR: .*' "$d/RESULT" | sed 's/^BUILD_DIR: //' | head -1)
    bd_result_in_ledger "$P" "$k" "$line" "${mbd:-}"; rc=$?
    case "$rc" in
      0)
        # The row turned up. Custody moved through the ledger exactly as it does
        # on the reap's own row path: the hub json stays (the box has not read
        # the row yet, so this is still the only other copy) and RELAYED marks
        # the close-out checks.
        touch "$d/RELAYED"; rm -f "$d/RELAY_DEFERRED"
        say "$k: the ledger now carries the deferred result — no ssh push; the box pulls it"
        ;;
      1)
        # Answered, and the row is genuinely not there. Push it, once. The
        # marker comes off either way: a failed push leaves the hub json, the
        # RELAY FAILED alert and today's hand-delivery story, and re-trying that
        # every two minutes would page every two minutes without changing it.
        rbox=$("$HARNESS/bin/fleet-conf.sh" --tailnet-ip "$P" 2>/dev/null) || rbox=""
        if [ -z "$rbox" ]; then
          say "$k: the ledger has no row for the deferred result and $P has no tailnet_ip in fleet.conf — still parked hub-side in $d"
          continue
        fi
        t=$(jq -r '.ticket_id // ""' "$HARNESS/state/remote-results/$P/$k.json" 2>/dev/null)
        if command -v result_own_pr_url >/dev/null 2>&1; then
          pr=$(result_own_pr_url "$d/RESULT" || true)
        else
          pr=$(grep -oE 'https://github.com/[^ ]+/pull/[0-9]+' "$d/RESULT" | head -1)
        fi
        tier=$(grep -oE '^TIER: [12]' "$d/RESULT" | grep -oE '[12]' | head -1)
        pool_push_full "$P" "$k" "${t:-}" "$d" "$rbox" "${pr:-}" "${tier:-}"
        rm -f "$d/RELAY_DEFERRED"
        ;;
      *)
        # Still cannot ask. Nothing is pushed and nothing is said: the reap
        # already wrote the one line this outage gets.
        ;;
    esac
  done
}
# <<< pool relay retry

