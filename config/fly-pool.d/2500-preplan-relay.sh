# >>> preplan relay (the operator, 2026-09-14)
# A pool builder has NO hub state: it runs bin/run-build.sh out of a baked image
# against a tarball of bin/, so plans/<project>-<KEY>/ — where bin/run-preplan.sh
# leaves the plan it already paid for — does not exist on it. Without this push,
# speculative pre-planning would be a hub-only optimisation and every pool build
# (which is every build on project-5 and project-4) would re-plan from scratch.
#
# It rides the SAME console push as the env bundle and job.json rather than the
# queue row, because the row's meta column is capped at 4000 chars in the worker
# and a plan is an order of magnitude longer — a truncated plan is the one
# failure mode worse than no plan at all.
#
# `key` is written LAST and it is the gate: bin/lib/preplan-lib.sh:preplan_find
# refuses a relay directory whose key does not match the job, so a half-pushed
# pre-plan is simply not adopted instead of being adopted in pieces. That same
# check is what stops a REUSED machine (next_job_or_destroy below) from handing
# job B the plan for job A — the TK-493 shape, where a reused machine's leftover
# artifacts were relayed home under the wrong ticket.
#
# THE HUB HAS NO plans/ DIRECTORY (BH-658, 2026-09-17). This function runs on
# the hub, and the hub is forbidden to pre-plan (bin/run-preplan.sh's
# hub-no-build block via bin/lib/hub-box.sh), so the local read below has ALWAYS
# missed here: every Fly build re-planned from scratch and no log line said so.
# The box that wrote the plan now publishes it to the coordination DB, and this
# is where it is read back — into a temp dir of exactly the same shape, so the
# push loop underneath is unchanged and one layout means one set of bugs.
#
# Never fatal: every path returns 0. A failed relay costs one PLAN stage — and
# now SAYS so, because a relay that quietly ships nothing is indistinguishable
# from a relay that was never called.
push_preplan() { # push_preplan <machine-id> <key>
  local mid="${1:-}" k="${2:-}" d="$HARNESS/plans/$P-${2:-}" kf f tmp="" src=local rc why
  command -v preplan_speculative >/dev/null 2>&1 || return 0
  [ "$(preplan_speculative "$HARNESS")" = 1 ] || return 0
  [ -n "$mid" ] && [ -n "$k" ] || return 0
  if [ ! -s "$d/plan.md" ]; then
    command -v preplan_fetch >/dev/null 2>&1 \
      || { say "no pre-plan for $k (db: no client on this host) — builder will PREPLAN_MISS"; return 0; }
    tmp=$(mktemp -d /tmp/preplan-relay.XXXXXX) \
      || { say "no pre-plan for $k (relay: mktemp failed) — builder will PREPLAN_MISS"; return 0; }
    preplan_fetch "$HARNESS" "$P" "$k" "$tmp"; rc=$?
    if [ "$rc" != 0 ]; then
      case "$rc" in 1) why=miss ;; *) why=outage ;; esac
      say "no pre-plan for $k (db: $why) — builder will PREPLAN_MISS"
      case "$tmp" in /tmp/preplan-relay.*) rm -rf "$tmp" ;; esac
      return 0
    fi
    d="$tmp"; src=db
  fi
  # A `once` block, so every exit from the push has the SAME cleanup after it:
  # the fetched directory is temporary and must not outlive the attempt.
  while :; do
    mput "$mid" "$d/plan.md" /run/harness/preplan/plan.md || break
    for f in base-sha planned-files.txt ticket-fp plan-thread-at; do
      [ -s "$d/$f" ] || continue
      mput "$mid" "$d/$f" "/run/harness/preplan/$f" || break 2
    done
    kf=$(mktemp) || break
    printf '%s\n' "$k" > "$kf"
    mput "$mid" "$kf" /run/harness/preplan/key && say "relayed pre-plan for $k to $mid (source: $src)"
    rm -f "$kf"
    break
  done
  case "$tmp" in /tmp/preplan-relay.*) rm -rf "$tmp" ;; esac
  return 0
}
# <<< preplan relay
