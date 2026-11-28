#!/bin/bash
# bin/fleet-fly-block.sh — print the `fly` section of the fleet-status snapshot:
# what each project currently has running on Fly, keyed by project.
#
#   {"<project>": {"pool_app": "pool-x-os" | "",
#                  "builder":  {"app":..,"machine_id":..} | null,
#                  "machines": [{machine,key,ticket_id,attempt,spawned_at}, ...],
#                  # the five below only when a sweep has run (BH-660):
#                  "orphan_jobs": [{machine,key,ticket_id}, ...],
#                  "stopped_machines": N, "destroy_failed": [...],
#                  "sweep_at": "...", "sweep_listing": "ok"|"saved"|"failed"}}
#
# Sources (all optional — a project with none of them is reported with empty
# arrays, never omitted): state/fly-pool/<project>/*.json is one file per live
# pool machine, state/fly/<project>.json is the persistent builder,
# flags/fly-pool-app-<project> names the dedicated pool app, and
# state/fly-pool/<project>/.sweep.json is what bin/fly-pool.sh's dead-machine
# sweep observed on its last tick.
#
# Every read is defensive on purpose. fly-pool.sh writes .<machine>.snapmt
# sidecars into the same directory and a machine file can be caught mid-write,
# so one unparseable file must never take the whole snapshot down — Mission
# Control going blank looks exactly like the fleet going dark.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
CONF_SH="$(dirname "$0")/fleet-conf.sh"
# BH-1372: a row-only pool app materialises flags/fly-pool-app-<p> before the loop.
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh" 2>/dev/null
command -v routing_sync_all >/dev/null 2>&1 && { routing_sync_all >/dev/null 2>&1 || true; }

OUT='{}'
for P in $("$CONF_SH" --projects 2>/dev/null); do
  POOL_APP=$(cat "$HARNESS/flags/fly-pool-app-$P" 2>/dev/null | head -1 | tr -d '\r')
  # A RETIRED BUILDER RECORD IS NOT A BUILDER (BH-660). bin/fly-pool-tick.sh
  # nests the machine_id of a pool-routed project's persistent builder under
  # `builder_retired` once, and a record with no machine_id left would otherwise
  # be reported as a builder with a blank id — a machine the console invites
  # someone to look for and nobody owns.
  BUILDER=$(jq -c 'select(type=="object") | select((.machine_id // "") != "")
                   | {app:(.app // ""),machine_id:.machine_id}' \
    "$HARNESS/state/fly/$P.json" 2>/dev/null | head -1)
  [ -n "$BUILDER" ] || BUILDER=null
  # The pool's last dead-machine sweep (BH-660), when there is one. Absent or
  # unparseable = exactly the shape this block emitted before the sweep existed:
  # an unknown is not a zero, and a project with no sweep must not report one.
  SWEEP=$(jq -c 'select(type=="object")
                 | {orphan_jobs:(.orphan_jobs // []),
                    stopped_machines:(((.stopped // []) | length) + ((.unaged // []) | length)),
                    destroy_failed:(.destroy_failed // []),
                    sweep_at:(.at // ""),
                    sweep_listing:(.listing // "")}' \
    "$HARNESS/state/fly-pool/$P/.sweep.json" 2>/dev/null | head -1)
  [ -n "$SWEEP" ] || SWEEP='{}'
  MACHINES='[]'
  for MF in "$HARNESS/state/fly-pool/$P"/*.json; do
    [ -f "$MF" ] || continue
    M=$(jq -c 'select(type=="object") | select(.machine != null)
               | {machine,key:(.key // ""),ticket_id:(.ticket_id // ""),
                  attempt:(.attempt // 0),spawned_at:(.spawned_at // "")}' \
        "$MF" 2>/dev/null | head -1)
    [ -n "$M" ] || continue
    MACHINES=$(jq -c --argjson m "$M" '. + [$m]' <<<"$MACHINES")
  done
  MACHINES=$(jq -c 'sort_by(.machine)' <<<"$MACHINES")
  OUT=$(jq -c --arg p "$P" --arg pa "${POOL_APP:-}" --argjson b "$BUILDER" --argjson ms "$MACHINES" \
    --argjson sw "$SWEEP" '.[$p]={pool_app:$pa,builder:$b,machines:$ms} + $sw' <<<"$OUT")
done
echo "$OUT"
