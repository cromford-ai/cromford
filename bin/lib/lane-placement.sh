# shellcheck shell=bash
# bin/lib/lane-placement.sh — BH-6124 (BH-6047 part 1 of 5): where a lane runs.
#
# A lane runs on the hub (pl_dispatch starts one local process per project) or
# on Fly (pl_dispatch enqueues one lane_runs row per project, and a machine
# running bin/lane-run-worker.sh claims and runs it). The answer is a settings
# row, so an operator moves a lane without a deploy:
#
#   lane_placement.<lane>.<project> fly | hub | box:<name>
#                                   (one project of a lane, BH-6890; read only
#                                   when the caller names a project. box:<name>,
#                                   BH-7636: the box <name> runs the lane for
#                                   the project from its own cron; only on this
#                                   row and only for a lane in LP_BOX_LANES)
#   lane_placement.<lane>           fly | hub | fly-dedicated (the exact lane name)
#   lane_placement.default          fly | hub   (seeded hub)
#   lane_dedicated.lanes            comma list: the lanes a lane or project row
#                                   may place `fly-dedicated` (BH-7716; no row
#                                   = LP_DEDICATED_LANES, seeded the same)
#   lane_placement.<lane>.hub_only  free text: the lane reads something that is
#                                   only on the hub, so it stays there
#
# The value is trimmed and lowercased. Only `fly` is fly, and only a valid
# `box:<name>` on a project row of a LP_BOX_LANES lane is box (LP_BOX = the
# name). Every other value (a box: value on a lane or default row, or for
# another lane, included), no row, a settings outage, no jobs client, or a lane
# name that is not a legal settings key is hub, and LP_WHY names which. Hub is
# today's behaviour, so every failure here falls back to it. A caller that
# tests `"$LP_PLACE" = fly` reads box as hub.
#
# `fly-dedicated` (BH-7716) is the box `fly-dedicated`: the dedicated Fly
# machine of lane_fleet.group.dedicated (bin/lane-fleet.sh), whose worker
# loops claim with --box fly-dedicated. It is valid on the lane row and on a
# project row, only for a lane in lane_dedicated.lanes (trimmed, lowercased),
# and it is LP_PLACE=box, LP_BOX=fly-dedicated. For any other lane, on the
# default row, with an empty list, or when the list read fails, it is hub.
#
#   lp_decide <lane> [project]   sets LP_PLACE (fly|hub|box), LP_BOX and
#                                LP_WHY; at most 5 settings reads
#   lp_box_parse <value>         prints the box name of a `box:<name>` value
#                                (whitespace deleted, A-Z lowercased, name
#                                [a-z0-9][a-z0-9._-]{0,63}), rc 0; else rc 1.
#                                The jobs worker parses by the same rule
#                                (worker/jobs/src/lib/lane-box-placement.js)
#   lp_placement <lane> [project]
#                                prints fly|hub|box, sets LP_PLACE, LP_BOX and
#                                LP_WHY. With a
#                                project, its row wins when it exists; no row
#                                reads the lane row, then the default row. The
#                                project `hub_only` is never a project row (that
#                                key is the lane's hub_only text).
#   lp_hub_only_reason <lane>    prints the hub_only text (rc 0), or rc 1
#   lp_rel_cmd <cmd>             prints bin/<rest> for a <cmd> under
#                                $root/bin/, else rc 1
#   lp_enqueue <lane> <project> <cmd> [args...]
#                                POST /api/lane-runs with args = [bin/<rest>,
#                                args...]. rc 0 = 201 enqueued, rc 3 = 409
#                                already_live, any other rc = not enqueued
#   lp_enqueue_batch <lane> <projects> <cmd> [args...]
#                                <projects> is a newline list. POST
#                                /api/lane-runs/batch, one call per LP_BATCH_MAX
#                                projects, with two jq forks in all. Sets
#                                LP_B_ENQ and LP_B_LIVE (the projects an answer
#                                names enqueued with an id, or already_live),
#                                LP_B_CALLS, and LP_B_LEFT: a newline list of
#                                every other project. rc 0 = every batch
#                                answered 2xx, rc 2 = the worker answered 404
#                                (no batch route; no more batches are sent),
#                                rc 1 = a batch failed or the call could not
#                                start. A 2xx answer that does not parse, or
#                                that leaves a project out, leaves it in
#                                LP_B_LEFT: only an answer makes a project fly.
#
# The root is ${HARNESS:-${H:-}}. Defines functions only. Nothing runs on
# source; the jobs client is loaded on the first call that needs it.

_lp_root() { printf '%s' "${HARNESS:-${H:-}}"; }

# The route's BATCH_MAX (worker/jobs/src/routes/lane-runs-batch.js).
LP_BATCH_MAX=500
# The lanes a project row may place on a named box (BH-7636).
LP_BOX_LANES="merge-conductor fly-pool"
# The dedicated lane host (BH-7716): the placement value, its box, and the
# documented fallback of the settings row lane_dedicated.lanes.
LP_DEDICATED=fly-dedicated
LP_DEDICATED_LANES="merge-conductor,blocked-resolver"

# _lp_dedicated_ok <lane> — rc 0 when <lane> is in lane_dedicated.lanes (no row
# = LP_DEDICATED_LANES), rc 1 when it is not, rc 3 when the read failed.
_lp_dedicated_ok() {
  local raw rc
  raw=$(setting_get lane_dedicated.lanes); rc=$?
  case "$rc" in 0) ;; 2) raw="$LP_DEDICATED_LANES" ;; *) return 3 ;; esac
  raw=$(printf '%s' "$raw" | tr -d '[:space:]' | tr 'A-Z' 'a-z')
  [[ ",$raw," == *",$1,"* ]]
}

lp_box_parse() {
  local v
  v=$(printf '%s' "${1:-}" | tr -d '[:space:]' | tr 'A-Z' 'a-z')
  [[ $v =~ ^box:[a-z0-9][a-z0-9._-]{0,63}$ ]] || return 1
  printf '%s' "${v#box:}"
}

# _lp_client — rc 0 when setting_get and _jobs_req are defined. Sources
# bin/jobs-client.sh when they are not, and restores pipefail, which the client
# switches on (the lib/lane-gate.sh _lg_ensure_client pattern).
_lp_client() {
  local root pf
  command -v setting_get >/dev/null 2>&1 && command -v _jobs_req >/dev/null 2>&1 && return 0
  if command -v _lg_ensure_client >/dev/null 2>&1; then
    _lg_ensure_client >/dev/null 2>&1 || true
  else
    root=$(_lp_root)
    [ -n "$root" ] && [ -r "$root/bin/jobs-client.sh" ] || return 1
    pf=$(set -o 2>/dev/null | awk '$1=="pipefail"{print $2}')
    # shellcheck source=bin/jobs-client.sh
    . "$root/bin/jobs-client.sh" >/dev/null 2>&1 || true
    [ "$pf" = off ] && set +o pipefail
  fi
  command -v setting_get >/dev/null 2>&1 && command -v _jobs_req >/dev/null 2>&1
}

lp_placement() {
  local lane="${1:-}" proj="${2:-}" key raw v b rc=2
  LP_PLACE=hub; LP_BOX=""
  if ! _lp_client; then LP_WHY="no jobs client"; printf 'hub'; return 0; fi
  key="lane_placement.$lane"
  if [ -z "$lane" ] || ! _setting_key_ok "$key.hub_only"; then
    LP_WHY="lane name not a settings key"; printf 'hub'; return 0
  fi
  # The project row first (BH-6890). A project name that is not a legal key
  # part reads as "no project row", never as a failure.
  if [ -n "$proj" ] && [ "$proj" != hub_only ] && _setting_key_ok "$key.$proj"; then
    key="$key.$proj"
    raw=$(setting_get "$key"); rc=$?
    [ "$rc" = 2 ] && key="lane_placement.$lane"
  fi
  [ "$rc" = 2 ] && { raw=$(setting_get "$key"); rc=$?; }
  if [ "$rc" = 2 ]; then
    key="lane_placement.default"
    raw=$(setting_get "$key"); rc=$?
  fi
  case "$rc" in
    0) ;;
    2) LP_WHY="no lane_placement row"; printf 'hub'; return 0 ;;
    *) LP_WHY="settings unreadable"; printf 'hub'; return 0 ;;
  esac
  v=$(printf '%s' "$raw" | tr -d '[:space:]' | tr 'A-Z' 'a-z')
  if [ "$v" = fly ]; then
    LP_PLACE=fly; LP_WHY="$key=fly"
  elif [ "$v" = "$LP_DEDICATED" ]; then
    if [ "$key" = lane_placement.default ]; then
      LP_WHY="$key='$raw' fly-dedicated only on a lane or project row"
    else
      _lp_dedicated_ok "$lane"; rc=$?
      case "$rc" in
        0) LP_PLACE=box; LP_BOX="$LP_DEDICATED"; LP_WHY="$key=$LP_DEDICATED" ;;
        3) LP_WHY="$key=$LP_DEDICATED, lane_dedicated.lanes: settings unreadable" ;;
        *) LP_WHY="$key: fly-dedicated not allowed for $lane (lane_dedicated.lanes)" ;;
      esac
    fi
  elif b=$(lp_box_parse "$raw"); then
    if [ -n "$proj" ] && [ "$key" = "lane_placement.$lane.$proj" ] && [[ " $LP_BOX_LANES " == *" $lane "* ]]; then
      LP_PLACE=box; LP_BOX="$b"; LP_WHY="$key=box:$b"
    else
      LP_WHY="$key='$raw' box: only on a project row of merge-conductor or fly-pool"
    fi
  else
    LP_WHY="$key='$raw' is not fly"
  fi
  printf '%s' "$LP_PLACE"
}

lp_hub_only_reason() {
  local lane="${1:-}" v
  _lp_client || return 1
  _setting_key_ok "lane_placement.$lane.hub_only" || return 1
  v=$(setting_get "lane_placement.$lane.hub_only") || return 1
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

lp_decide() {
  local lane="${1:-}" reason
  lp_placement "$lane" "${2:-}" >/dev/null
  if { [ "$LP_PLACE" = fly ] || [ "$LP_PLACE" = box ]; } && reason=$(lp_hub_only_reason "$lane"); then
    LP_PLACE=hub; LP_BOX=""; LP_WHY="hub_only: $reason"
  fi
  return 0
}

lp_rel_cmd() {
  local root rest
  root=$(_lp_root)
  [ -n "$root" ] || return 1
  case "${1:-}" in "$root/bin/"?*) rest="${1#"$root/bin/"}" ;; *) return 1 ;; esac
  case "/$rest/" in */../*|*[!A-Za-z0-9._/-]*) return 1 ;; esac
  printf 'bin/%s' "$rest"
}

lp_enqueue() {
  local lane="${1:-}" p="${2:-}" rel args body rc
  [ "$#" -ge 3 ] || return 1
  rel=$(lp_rel_cmd "$3") || return 1
  shift 3
  _lp_client || return 1
  # NUL-joined, so a space or a newline inside an arg stays inside it.
  args=$(printf '%s\0' "$rel" "$@" | jq -Rsc 'split("\u0000") | .[:-1]') || return 1
  body=$(jq -nc --arg l "$lane" --arg p "$p" --argjson a "$args" --arg b "$(_jobs_box_name 2>/dev/null)" \
    '{lane:$l, project:$p, args:$a} + (if $b == "" then {} else {box:$b} end)') || return 1
  _jobs_req POST /api/lane-runs "$body" >/dev/null; rc=$?
  [ "$rc" = 0 ] && return 0
  if [ "$rc" = 9 ] && [ "$(printf '%s' "$JOBS_BODY" | jq -r '.error // empty' 2>/dev/null)" = already_live ]; then
    return 3
  fi
  return 1
}

lp_enqueue_batch() {
  local lane="${1:-}" projects="${2:-}" rel batches line rc res=0 answers="" out first
  LP_B_ENQ=0; LP_B_LIVE=0; LP_B_CALLS=0; LP_B_LEFT="$projects"
  [ "$#" -ge 3 ] || return 1
  rel=$(lp_rel_cmd "$3") || return 1
  shift 3
  _lp_client || return 1
  # One line per chunk: the projects deduplicated in order, empty lines
  # dropped. The args reach jq NUL-joined on stdin, as in lp_enqueue, so a
  # space or a newline inside an arg stays inside it and an arg that starts
  # with -- is never read as a jq option.
  batches=$(printf '%s\0' "$rel" "$@" | jq -Rsc --arg l "$lane" --arg b "${JOBS_BOX:-}" --arg p "$projects" --argjson n "$LP_BATCH_MAX" '
    (split("\u0000") | .[:-1]) as $a
    | (reduce ($p | split("\n")[] | select(. != "")) as $x ({s: {}, o: []};
        if .s[$x] then . else .s[$x] = true | .o += [$x] end) | .o) as $ps
    | range(0; $ps | length; $n) as $i
    | {lane: $l, rows: [$ps[$i:$i + $n][] | {project: ., args: $a}]}
      + (if $b == "" then {} else {box: $b} end)') || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    LP_B_CALLS=$((LP_B_CALLS + 1))
    _jobs_req POST /api/lane-runs/batch "$line" >/dev/null; rc=$?
    case "$rc" in
      0) answers+="$JOBS_BODY"$'\n' ;;
      2) res=2; break ;;
      *) res=1 ;;
    esac
  done <<<"$batches"
  # Line 1: <enqueued> <already_live>. Then every sent project no answer names
  # enqueued (with an integer id) or already_live, by its exact name.
  out=$(jq -nrR --arg p "$projects" '
    (reduce ($p | split("\n")[] | select(. != "")) as $x ({s: {}, o: []};
      if .s[$x] then . else .s[$x] = true | .o += [$x] end)) as $sent
    | (reduce (inputs | fromjson? | objects | .rows? | arrays | .[] | objects
         | select((.project | type) == "string" and $sent.s[.project])
         | select((.status == "enqueued" and (.id | type) == "number" and .id == (.id | floor))
                  or .status == "already_live")) as $r ({};
         if has($r.project) then . else .[$r.project] = $r.status end)) as $got
    | "\([$got[] | select(. == "enqueued")] | length) \([$got[] | select(. == "already_live")] | length)",
      ($sent.o[] | select($got[.] == null))' <<<"$answers") || return 1
  first=${out%%$'\n'*}
  read -r LP_B_ENQ LP_B_LIVE <<<"$first"
  LP_B_LEFT=${out#"$first"}; LP_B_LEFT=${LP_B_LEFT#$'\n'}
  return "$res"
}
