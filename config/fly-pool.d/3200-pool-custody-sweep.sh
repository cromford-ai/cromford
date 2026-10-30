# >>> pool custody sweep (BH-5006)
# pool_custody_sweep — give every finished pool build on this hub an owner.
#   Three reap paths leave builds/pool-<p>-* with a RESULT and NO custody
#   marker, and nothing ever revisits it: pool_push_full failing at reap, the
#   rc-1 arm of pool_relay_retry above (RELAY_DEFERRED comes off whether or not
#   the push landed), and a project with no tailnet_ip ("parked hub-side").
#   pipeline-health check 4 then counts the dir as "no board close-out" every
#   10 minutes for ever (pool-cromford-BH-4583-202610050404). For a dir
#   older than POOL_CUSTODY_SWEEP_S, oldest RESULT first, one of:
#     SUPERSEDED     a newer exact-key result already has RELAYED or COMMENTED
#                    (no network; bin/lib/closeout-terminal.sh honours it)
#     RELAYED        the ledger carries this build's row
#     one push       the ledger answered and has no row: pool_push_full, once in
#                    the dir's lifetime (RELAY_RETRIED)
#     one page       still no owner after that, or nothing can push it:
#                    CUSTODY_ALERTED, never repeated
#   An unreadable ledger (rc 2+) does nothing: unknown is not absent. BOUNDED:
#   at most POOL_CUSTODY_SWEEP_MAX dirs acted on per tick, one ledger read
#   each. Runs inside the per-project flock, after pool_relay_retry, and a
#   reap writes RESULT and its marker under that same flock, so the sweep
#   never sees a dir half-written.
pool_custody_sweep() {
  [ "$POOL_CUSTODY_SWEEP_S" -gt 0 ] && [ "$POOL_CUSTODY_SWEEP_MAX" -gt 0 ] || return 0
  local now d m mt bn k n nk own line mbd rc rbox t pr tier why ledger=0 acted=0 cands="" ceil
  now=$(date -u +%s)
  # AGED OUT (review of 72b69292): a RESULT older than check 4's ceiling
  # (CLOSEOUT_AGE_OUT_H, default 168h) is not chased. Its box has long since
  # rebuilt or merged that ticket, and a push would close out a stale result.
  # It is marked SUPERSEDED "aged out" with no network, no ledger read and no
  # page, so the sweep and check 4 agree about it.
  ceil=$(closeout_age_out_s 2>/dev/null) || ceil=604800
  case "$ceil" in ''|*[!0-9]*) ceil=604800 ;; esac
  command -v bd_result_in_ledger >/dev/null 2>&1 && command -v job_artifact_feed >/dev/null 2>&1 && ledger=1
  for d in "$HARNESS/builds/pool-$P-"*; do
    [ -s "$d/RESULT" ] || continue
    for m in RELAYED RELAY_DEFERRED COMMENTED DEFERRED TERMINAL SUPERSEDED; do
      [ -f "$d/$m" ] && continue 2
    done
    head -1 "$d/RESULT" 2>/dev/null | grep -q '^BUILD_DEFERRED' && continue
    mt=$(stat -c %Y "$d/RESULT" 2>/dev/null) || continue
    [ $((now - mt)) -gt "$POOL_CUSTODY_SWEEP_S" ] || continue
    if [ $((now - mt)) -gt "$ceil" ]; then
      printf 'aged out: RESULT %sh old, past CLOSEOUT_AGE_OUT_H (BH-5006 custody sweep)\n' "$(( (now - mt) / 3600 ))" > "$d/SUPERSEDED"
      say "custody: $(basename "$d") aged out ($(( (now - mt) / 3600 ))h), SUPERSEDED with no push or page"
      continue
    fi
    cands="$cands$mt $d
"
  done
  [ -n "$cands" ] || return 0
  while read -r mt d; do
    [ -n "${d:-}" ] || continue
    [ "$acted" -lt "$POOL_CUSTODY_SWEEP_MAX" ] || break
    bn=$(basename "$d")
    # The key, derived exactly as pool_relay_retry derives it (read its comment:
    # the timestamp field has no hyphen, so ONE trailing -field comes off).
    k=${bn#"pool-$P-"}; k=${k%-*}
    [ -n "$k" ] || continue
    own=""
    for n in "$HARNESS/builds/pool-$P-$k-"*; do
      [ -d "$n" ] && [ "$n" != "$d" ] || continue
      nk=$(basename "$n"); nk=${nk#"pool-$P-"}; nk=${nk%-*}
      [ "$nk" = "$k" ] && [ "$n/RESULT" -nt "$d/RESULT" ] || continue
      { [ -f "$n/RELAYED" ] || [ -f "$n/COMMENTED" ]; } && own=$(basename "$n")
    done
    if [ -n "$own" ]; then
      printf 'superseded by %s (BH-5006 custody sweep)\n' "$own" > "$d/SUPERSEDED"
      say "custody: $bn superseded by $own"
      acted=$((acted + 1)); continue
    fi
    [ -f "$d/CUSTODY_ALERTED" ] && continue
    acted=$((acted + 1))
    line=$(head -1 "$d/RESULT")
    why="the ledger could not be asked from this hub (no jobs client)"
    if [ "$ledger" = 1 ]; then
      mbd=$(grep -oE '^BUILD_DIR: .*' "$d/RESULT" | sed 's/^BUILD_DIR: //' | head -1)
      bd_result_in_ledger "$P" "$k" "$line" "${mbd:-}"; rc=$?
      case "$rc" in
        0)
          touch "$d/RELAYED"
          say "custody: $bn — the ledger carries it, stamped RELAYED"
          continue ;;
        1)
          rbox=$("$HARNESS/bin/fleet-conf.sh" --tailnet-ip "$P" 2>/dev/null) || rbox=""
          if [ ! -f "$d/RELAY_RETRIED" ] && [ -n "$rbox" ]; then
            : > "$d/RELAY_RETRIED"
            t=$(jq -r '.ticket_id // ""' "$HARNESS/state/remote-results/$P/$k.json" 2>/dev/null)
            if command -v result_own_pr_url >/dev/null 2>&1; then
              pr=$(result_own_pr_url "$d/RESULT" || true)
            else
              pr=$(grep -oE 'https://github.com/[^ ]+/pull/[0-9]+' "$d/RESULT" | head -1)
            fi
            tier=$(grep -oE '^TIER: [12]' "$d/RESULT" | grep -oE '[12]' | head -1)
            if pool_push_full "$P" "$k" "${t:-}" "$d" "$rbox" "${pr:-}" "${tier:-}"; then
              say "custody: $bn — the ledger had no row; pushed once to $rbox"
            else
              say "custody: $bn — the ledger had no row and the one push to $rbox failed; paged next tick if nothing else takes it"
            fi
            continue
          fi
          if [ -f "$d/RELAY_RETRIED" ]; then
            why="the ledger still has no row for this build after one ssh push to ${rbox:-a box with no tailnet_ip}"
          else
            why="the ledger has no row for this build and this project has no tailnet_ip to push it to"
          fi ;;
        *)
          say "custody: $bn — ledger unreadable, left for the next tick"
          continue ;;
      esac
    fi
    HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $bn: finished $(( (now - mt) / 3600 ))h ago (RESULT: $(printf '%s' "$line" | cut -c1-120)) and no box has it — $why. Nothing else retries this dir. Hand-deliver state/remote-results/$P/$k.json + $d, or touch $d/SUPERSEDED if a later build replaced it."
    : > "$d/CUSTODY_ALERTED"
    say "custody: $bn — no owner, paged once"
  done <<CUSTODY
$(printf '%s' "$cands" | sort -n)
CUSTODY
}
# <<< pool custody sweep (BH-5006)

