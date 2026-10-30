# >>> machine destroy (BH-660)
# EVERY DESTROY ANSWERS FOR ITSELF (BH-660). Until now all six destroy sites in
# this file were `timeout 60 "$FLY" machine destroy … >/dev/null 2>&1` with the
# exit code dropped on the floor, and the two tracked ones then `rm -f`'d the
# machine's json whatever had happened. ONE refused destroy — API weather, a 60s
# timeout, a machine still `stopping` — turned a tracked machine into an
# untracked one, and nothing in this script could ever see it again: the REAP
# loop below only visits machines that have a file. It idled out, stopped, and
# stayed in the app for good. That is the shape of the leaked machines BH-660
# counted.
#
# Idempotent against Fly: "not found" means the machine is already in the state
# this call was asking for, so it is a success and pages nobody. Anything else is
# a FAILURE and says so — flyctl's own error body goes to fly-pool.log and, once
# per machine per UTC day, to ALERTS.log. The machine is not lost either way: the
# sweep re-lists the app every tick and retries it.
#
# DESTROY_RC / DESTROY_ERR are left set for the sweep's .sweep.json row.
destroy_machine() { # destroy_machine <machine-id> <why>   rc 0 = gone, 1 = still there
  local MID="${1:-}" WHY="${2:-}" OUT AF
  DESTROY_RC=0; DESTROY_ERR=""; DESTROY_GONE=0
  [ -n "$MID" ] || { DESTROY_RC=2; DESTROY_ERR="no machine id"; return 1; }
  # BH-7505: a destroy ends somebody's build, so it needs the lease too. No alert:
  # the run that holds the lease now owns the machine, and the sweep retries.
  if command -v pp_fence_ok >/dev/null 2>&1 && ! pp_fence_ok; then
    DESTROY_RC=99; DESTROY_ERR="project lease lost"
    say "destroy $MID skipped: the project lease is lost ($WHY)"
    return 1
  fi
  OUT=$(timeout 60 "$FLY" machine destroy "$MID" -a "$APP" --force 2>&1); DESTROY_RC=$?
  if [ "$DESTROY_RC" = 0 ]; then say "destroyed $MID ($WHY)"; return 0; fi
  case "$OUT" in
    *"was not found in app"*|*"not found"*|*"Could not find"*)
      DESTROY_GONE=1; say "destroy $MID: already gone ($WHY)"; DESTROY_RC=0; return 0 ;;
  esac
  # rc 124 is `timeout` killing flyctl, and flyctl then prints nothing at all —
  # an empty error body would read as "no reason given" rather than as the one
  # reason we actually know.
  [ "$DESTROY_RC" = 124 ] && OUT="timeout after 60s"
  DESTROY_ERR=$(printf '%s' "$OUT" | tr '\n\r\t' '   ' | cut -c1-300)
  say "destroy $MID FAILED rc=$DESTROY_RC: $DESTROY_ERR ($WHY)"
  AF="$HARNESS/flags/alerted-pool-destroy-$P-$MID-$(date -u +%Y%m%d)"
  if [ ! -f "$AF" ]; then
    mkdir -p "$HARNESS/flags" 2>/dev/null && touch "$AF" 2>/dev/null
    HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] machine destroy $MID FAILED rc=$DESTROY_RC: $DESTROY_ERR — still in $APP; the sweep retries it next tick"
  fi
  return 1
}
# <<< machine destroy

