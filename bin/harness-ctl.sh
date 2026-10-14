#!/bin/bash
# bin/harness-ctl.sh — the operator's hand on the harness control plane
# (BH-1132). One command to see every automatic lane in the fleet, stop or
# start one, change one of its numbers, or stop all of them.
#
# WHY. the operator, 2026-09-20: "stop any automatic mechanisms on the harness for now
# … add hot fixes so we can have control on all those harness mechanisms and be
# able to stop or start them or change their values min max etc." Until this
# file the answer to "turn off alert-triage" was: work out which of ~40
# `flags/*` names that lane happens to read, ssh to the box that runs it, and
# touch the file. alert-triage burned $793 in 12 hours (#1039) behind that.
#
# usage:
#   bin/harness-ctl.sh status [project]          every lane, on/off, spend, knobs
#   bin/harness-ctl.sh show <lane> [project]     one lane in full
#   bin/harness-ctl.sh off <lane> [project] "<reason>"   (reason = ONE argument)
#   bin/harness-ctl.sh on  <lane> [project] "<reason>"   (same grammar as off)
#   bin/harness-ctl.sh off <hub-lane> --project <p> "<reason>"   hold ONE project on a hub lane (per_project_hold in catalog/lanes.d)
#   bin/harness-ctl.sh on  <hub-lane> --project <p> "<reason>"   clear that one row (lane-wide and all-off still hold)
#   bin/harness-ctl.sh set <lane> <ENV> <value> [project]   (project = one fleet.conf lists)
#   bin/harness-ctl.sh seed [--dry-run] [project]   this box's env -> settings rows
#       (no project = the LANE-WIDE row for every settable knob, from global.env)
#   bin/harness-ctl.sh seed-registry [--dry-run] [--exclude-box <box>]...   the registry's defaults -> settings rows
#       (POST /api/settings/seed-registry; idempotent, never overwrites a row
#       anyone but the seed wrote; REFUSES until every box that ticked a lane
#       in the last SEED_GATE_TICK_WINDOW_S seconds (default 86400) reports a
#       harness commit that contains the contract — BH-1511.1. --dry-run runs
#       the same gate, prints every insert/update/prune, and writes nothing)
#   bin/harness-ctl.sh all-off <reason>          stop every registered lane
#   bin/harness-ctl.sh all-on "<reason>"         clear the master switch only
#   bin/harness-ctl.sh review <owner/repo> <pr> <head-sha> [--notes <text>]   nudge the lead to review that head (bin/lead-verdict.sh request)
#
# IT WRITES THROUGH THE ROUTES THAT ALREADY EXIST. A single lane's switch is a
# pause_flags row (PUT /api/flags, via jobs-client's flag_set, which touches the
# FILE first so the box is right even if the next line never runs) and a knob is
# a settings row (PUT /api/settings). Only the fleet stop has a route of its
# own, because it is one row and not 77.
#
# ALL-ON IS NOT "TURN EVERYTHING ON". It clears the master switch and nothing
# else: a lane somebody stopped last week stays stopped, because resuming the
# fleet must not silently undo a decision nobody revisited. `status` shows what
# is still held.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
if [ -f "$HENV/global.env" ]; then set -a; # shellcheck disable=SC1091
  . "$HENV/global.env"; set +a; fi
# --help answers BEFORE anything is sourced. A tool whose usage text needs a
# reachable API client cannot tell you how to use it on the machine where the
# client is missing, which is exactly when you are reading it.
case "${1:-}" in
  -h|--help|help)
    sed -n '/^# usage:/,/^# IT WRITES/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'
    exit 0 ;;
esac

# shellcheck disable=SC1091
. "$HARNESS/bin/jobs-client.sh" 2>/dev/null || { echo "harness-ctl: bin/jobs-client.sh is not readable — nothing to talk to" >&2; exit 2; }
# catalog/lanes.json is GENERATED from catalog/lanes.d/ and no longer committed
# (BH-1247), so it is resolved through the ONE loader, which renders it when it
# is missing or stale. LANE_REGISTRY still wins, unchanged: every suite that
# drives this CLI against a fixture registry sets it.
# shellcheck disable=SC1091
. "$HARNESS/bin/lib/lanes-registry.sh" 2>/dev/null || true
if command -v lanes_json_path >/dev/null 2>&1; then
  REG=$(lanes_json_path "$HARNESS" 2>/dev/null) || REG=""
fi
REG="${REG:-${LANE_REGISTRY:-$HARNESS/catalog/lanes.json}}"

die() { echo "harness-ctl: $*" >&2; exit 2; }
have_lane() { jq -e --arg i "$1" '.lanes[]|select(.id==$i)' "$REG" >/dev/null 2>&1; }
lane_scope() { jq -r --arg i "$1" '.lanes[]|select(.id==$i)|.scope' "$REG" 2>/dev/null; }

# A HUB LANE THAT CAN BE HELD FOR ONE PROJECT declares it in catalog/lanes.d/
# (BH-1463), and bin/lib/lane-gate.sh's lane_project_held is the only thing that
# reads lane-off-<id>-<project>. A hub lane WITHOUT the field has no reader for
# that name, so minting one here would write a file nothing consults and report
# a stop that stops nothing. The list is read from the registry at call time, so
# a lane that gains the field tomorrow needs no edit here.
lane_hold_ok() { jq -e --arg i "$1" '.lanes[]|select(.id==$i)|select(.per_project_hold==true)' "$REG" >/dev/null 2>&1; }
hold_lanes()   { jq -r '[.lanes[]|select(.per_project_hold==true)|.id]|join(", ")' "$REG" 2>/dev/null; }

# A lane id that is not in the registry is a TYPO, and the worst thing this
# script could do with one is cheerfully write flags/lane-off-merge-condcutor
# and report success while the lane kept spending.
need_lane() {
  have_lane "$1" || die "no lane '$1' in $REG. bin/harness-ctl.sh status lists them."
}

api_status() { # api_status [project]
  local q=""
  [ -n "${1:-}" ] && q="?project=$1"
  _jobs_req GET "/api/lanes/status$q"
}

cmd_status() {
  local p="${1:-}" resp
  resp=$(api_status "$p") || die "the worker did not answer (the fleet keeps running; this is a read)"
  # The fields are the payload's own — cost_today / cost_7d at the lane's top
  # level, not under .stats. Reading .stats.usd_today printed $0.00 for every
  # lane including the one burning $793 a night, which is the most reassuring
  # possible shape for the exact incident this tool exists for.
  printf '%s' "$resp" | jq -r '
    (if .all_off then "FLEET STOP is ON since \(.all_off_at) — every registered lane is gated\n" else "" end),
    (if ((.all_off_flag_boxes // []) | length) > 0 then
       "FLEET STOP as a FILE on \((.all_off_flag_boxes|join(", "))) — a hand-touched flags/all-off this page cannot clear; every lane on those boxes is gated (ssh there and rm it)\n"
     else "" end),
    "lane                      scope    on/off  cadence          $today   $7d      held by / note",
    "------------------------- -------- ------- ---------------- -------- -------- --------------",
    (.lanes[] | [
       (.id            | .[0:25] | . + (" " * (25 - length))),
       (.scope         | .[0:8]  | . + (" " * (8  - length))),
       (if .off then "OFF    " elif .off == null then "?      " else "on     " end),
       ((.cadence // "-") | .[0:16] | . + (" " * (16 - length))),
       ((if .cost_today == null then "-" else "$\(.cost_today * 100 | round / 100)" end) | .[0:8] | . + (" " * (8 - length))),
       ((if .cost_7d   == null then "-" else "$\(.cost_7d   * 100 | round / 100)" end) | .[0:8] | . + (" " * (8 - length))),
       ((.held_by // []) | join(","))
         + (if .cost_attribution == "shared" then "  [spend shared with " + ((.cost_shared_with // []) | join(",")) + "]" else "" end)
     ] | join(" "))' 2>/dev/null
}

cmd_show() {
  local id="${1:-}" p="${2:-}" resp
  [ -n "$id" ] || die "usage: harness-ctl.sh show <lane> [project]"
  need_lane "$id"
  resp=$(api_status "$p") || die "the worker did not answer"
  printf '%s' "$resp" | jq --arg i "$id" '.lanes[]|select(.id==$i)' 2>/dev/null
}

# A switch name is built HERE, from the registry's id and what it declares, so a
# project suffix can never be pasted onto a lane that has no reader for it
# (flags/lane-off-alert-triage-project-3 would be a file nothing ever reads). The
# exception is a hub lane with per_project_hold: lane_project_held reads exactly
# this name for it (BH-1463).
switch_name() { # switch_name <id> [project]
  local id="$1" p="${2:-}"
  if [ -n "$p" ]; then
    [ "$(lane_scope "$id")" = project ] || lane_hold_ok "$id" \
      || die "lane '$id' is not project-scoped and declares no per_project_hold — drop the project argument"
    case "$p" in *[!A-Za-z0-9._-]*) die "'$p' is not a legal project name" ;; esac
    printf 'lane-off-%s-%s' "$id" "$p"
  else
    printf 'lane-off-%s' "$id"
  fi
}

# THE REASON IS ONE ARGUMENT, and that is not pedantry. With a free-form
# trailing reason, `off merge-conductor project-3 "spend"` on a HUB lane read the
# project as the first word of the reason and stopped the conductor FLEET-WIDE
# while printing a line the operator would read as "I stopped project-3". A stop
# button whose blast radius depends on how you spaced the sentence is not a
# stop button. So: a hub lane takes exactly one argument after the id, and a
# project lane takes one or two.
cmd_off() {
  local id="${1:-}" p="" reason="" name hint=""
  [ -n "$id" ] || die "usage: harness-ctl.sh off <lane> [project] \"<reason>\""
  need_lane "$id"; shift
  lane_hold_ok "$id" && hint=" (to hold ONE project instead: off $id --project <p> \"<reason>\")"
  # THE PROJECT ARRIVES AS A FLAG on a hub lane, before the reason, because that
  # is the one form no spacing can make ambiguous — the whole reason the
  # positional project stayed refused above.
  if [ "${1:-}" = --project ]; then
    [ -n "${2:-}" ] || die "usage: harness-ctl.sh off $id --project <p> \"<reason>\""
    p="$2"; shift 2
    [ "$(lane_scope "$id")" = project ] || lane_hold_ok "$id" \
      || die "lane '$id' does not take --project. The hub lanes that can be held for ONE project: $(hold_lanes). Without it, off $id \"<reason>\" stops the lane fleet-wide."
    case $# in
      1) reason="$1" ;;
      *) die "usage: harness-ctl.sh off $id --project $p \"<reason>\" — quote the reason as ONE argument" ;;
    esac
  elif [ "$(lane_scope "$id")" = project ]; then
    case $# in
      1) reason="$1" ;;
      2) p="$1"; reason="$2" ;;
      *) die "usage: harness-ctl.sh off $id [project] \"<reason>\" — quote the reason as ONE argument" ;;
    esac
  else
    case $# in
      1) reason="$1" ;;
      *) die "lane '$id' is $(lane_scope "$id")-scoped: it takes no project, and the reason is ONE quoted argument. usage: harness-ctl.sh off $id \"<reason>\"$hint" ;;
    esac
  fi
  [ -n "$reason" ] || die "a stop needs a reason — it is what the next person reads on the page"
  name=$(switch_name "$id" "$p") || exit 2
  flag_set "$name" on "$reason" || die "the flag file was written but the row was not — the box is stopped, the page is not; retry when the worker answers"
  echo "OFF $id${p:+/$p} (flags/$name) — $reason"
}

# ON TAKES THE SAME ARGUMENTS AS OFF (BH-1165). Until this, `on <lane>
# "<reason>"` read the reason as a PROJECT and died with "lane is not
# project-scoped — drop the project argument" (the operator, on the hub, the evening
# phase A landed). Two grammars for the two halves of one switch is a switch
# nobody can use under pressure, and the resume — a decision taken during an
# incident — recorded nothing about who took it or why.
#
# THE ONE-ARGUMENT CASE ON A PROJECT LANE IS REFUSED WHEN IT NAMES A PROJECT.
# `off` reads a single trailing argument as the reason; doing the same here
# would make `on review-prs project-2` (which worked yesterday) clear the
# FLEET-WIDE switch while printing a line an operator reads as "I resumed
# project-2". An ambiguity that changes which switch is written is refused, not
# guessed.
cmd_on() {
  local id="${1:-}" p="" reason="" name hint=""
  [ -n "$id" ] || die "usage: harness-ctl.sh on <lane> [project] \"<reason>\""
  need_lane "$id"; shift
  lane_hold_ok "$id" && hint=" (to clear ONE project's hold instead: on $id --project <p> \"<reason>\")"
  # The same flag as `off`, for the same reason: the two halves of one switch
  # take the same arguments (BH-1165). With the project explicit there is no
  # reason/project ambiguity to resolve, so fleet.conf is not consulted here.
  if [ "${1:-}" = --project ]; then
    [ -n "${2:-}" ] || die "usage: harness-ctl.sh on $id --project <p> \"<reason>\""
    p="$2"; shift 2
    [ "$(lane_scope "$id")" = project ] || lane_hold_ok "$id" \
      || die "lane '$id' does not take --project. The hub lanes that can be held for ONE project: $(hold_lanes). Without it, on $id \"<reason>\" clears the fleet-wide switch."
    case $# in
      0) ;;
      1) reason="$1" ;;
      *) die "usage: harness-ctl.sh on $id --project $p \"<reason>\" — quote the reason as ONE argument" ;;
    esac
  elif [ "$(lane_scope "$id")" = project ]; then
    case $# in
      0) ;;
      1) if awk 'NF && $1!~/^#/{print $1}' "$HARNESS/fleet.conf" 2>/dev/null | grep -qx -- "$1"; then
           die "'$1' is a project: say which and why — harness-ctl.sh on $id $1 \"<reason>\""
         fi
         reason="$1" ;;
      2) p="$1"; reason="$2" ;;
      *) die "usage: harness-ctl.sh on $id [project] \"<reason>\" — quote the reason as ONE argument" ;;
    esac
  else
    case $# in
      0) ;;
      1) reason="$1" ;;
      *) die "lane '$id' is $(lane_scope "$id")-scoped: it takes no project, and the reason is ONE quoted argument. usage: harness-ctl.sh on $id \"<reason>\"$hint" ;;
    esac
  fi
  name=$(switch_name "$id" "$p") || exit 2
  flag_set "$name" off "${reason:-resumed via harness-ctl}" || die "the flag file was cleared but the row was not; retry when the worker answers"
  echo "ON $id${p:+/$p} (flags/$name cleared)${reason:+ — $reason}"
  # Saying so is the point: `on` clears ONE switch, and the lane can still be
  # held by the master switch or by a pre-BH-1132 alias.
  echo "note: other switches may still hold it — bin/harness-ctl.sh show $id${p:+ $p}"
}

# The clamp lives in the REGISTRY and is applied at both ends: here, so an
# operator is told no, and in bin/lib/lane-gate.sh, so a row written by anything
# else still cannot hand a lane a number outside its range.
cmd_set() {
  local id="${1:-}" env="${2:-}" val="${3:-}" p="${4:-}" key mn mx z
  [ -n "$id" ] && [ -n "$env" ] && [ -n "$val" ] || die "usage: harness-ctl.sh set <lane> <ENV> <value> [project]"
  need_lane "$id"
  jq -e --arg i "$id" --arg e "$env" '.lanes[]|select(.id==$i)|.knobs[]?|select(.env==$e)' "$REG" >/dev/null 2>&1 \
    || die "lane '$id' has no knob '$env'. bin/harness-ctl.sh show $id lists them."
  # NOT EVERY REGISTERED NAME IS SETTABLE (BH-1165 review). Wiring all 78 lanes
  # registered every `${X:-...}` an automatic script reads, and about eighty of
  # those are the command a lane runs, the host it sends its bearer to, the path
  # it deletes under, the identity it claims or a test seam. A settings row is
  # exported into a lane cron runs as ROOT, so those names are refused at every
  # write surface — here, `seed`, the console, and the worker's PUT — and the
  # gate ignores a row for one even if it somehow exists.
  jq -e --arg i "$id" --arg e "$env" \
    '.lanes[]|select(.id==$i)|.knobs[]?|select(.env==$e)|select(.settable==false)' "$REG" >/dev/null 2>&1 \
    && die "'$env' is not settable: it is a command/host/path/identity this lane runs as root, registered so it is visible, not so it can be written from a page (catalog/lanes.json: settable:false). Change it in env/global.env on the box."
  mn=$(jq -r --arg i "$id" --arg e "$env" '.lanes[]|select(.id==$i)|.knobs[]?|select(.env==$e)|.min // empty' "$REG")
  mx=$(jq -r --arg i "$id" --arg e "$env" '.lanes[]|select(.id==$i)|.knobs[]?|select(.env==$e)|.max // empty' "$REG")
  if grep -qE '^-?[0-9]+(\.[0-9]+)?$' <<<"$val"; then
    [ -n "$mn" ] && awk -v v="$val" -v m="$mn" 'BEGIN{exit !(v<m)}' && die "$env min is $mn"
    [ -n "$mx" ] && awk -v v="$val" -v m="$mx" 'BEGIN{exit !(v>m)}' && die "$env max is $mx"
  fi
  if [ "$val" = 0 ]; then
    z=$(jq -r --arg i "$id" --arg e "$env" '.lanes[]|select(.id==$i)|.knobs[]?|select(.env==$e)|.zero_means // empty' "$REG")
    # 0 does not mean the same thing twice in this fleet (off for
    # TRIAGE_MAX_FAMILIES, unlimited for the autopilot daily cap). Saying which
    # one this is, at the moment of the write, is the whole point of the field.
    [ -n "$z" ] && echo "note: 0 means $z for $id/$env"
  fi
  # `lane.<id>[.<project>].<env lowercased>` — the form the published contract
  # names and the console writes. Not a registry alias: one knob, one key, or a
  # value set on the page lands on a row the lane never reads.
  if [ -n "$p" ]; then
    # THE PROJECT IS ONE FLEET.CONF NAMES (BH-1985). The key is built from it
    # verbatim, so a typo was written as lane.<id>.<typo>.<env>, a row no lane
    # reads, and printed as SET. Exact match on the first column, comments
    # skipped — the list cmd_on already reads. No fleet.conf to check against
    # is a refusal, not a pass: nothing can say the name is real.
    local fc="${FLEET_CONF:-$HARNESS/fleet.conf}" projects
    [ -r "$fc" ] || die "cannot check project '$p': $fc is not readable — nothing was written"
    projects=$(awk 'NF && $1!~/^#/{print $1}' "$fc")
    grep -qxF -- "$p" <<<"$projects" \
      || die "no project '$p' in $fc — nothing was written. Projects: $(printf '%s' "$projects" | paste -sd, - | sed 's/,/, /g')"
    # A knob that declares `project_scoped: true` takes a project row on ANY
    # lane (BH-1770): lane-reaper runs on every box, but its deadline is per
    # BUILD lane, and the build's project is what lane_knob is asked with.
    [ "$(lane_scope "$id")" = project ] \
      || jq -e --arg i "$id" --arg e "$env" \
           '.lanes[]|select(.id==$i)|.knobs[]?|select(.env==$e)|select(.project_scoped==true)' "$REG" >/dev/null 2>&1 \
      || die "lane '$id' is not project-scoped — drop the project argument"
    key="lane.$id.$p.$env"
  else
    key="lane.$id.$env"
  fi
  key=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')
  [ "${#key}" -le 64 ] || die "the settings key for that lane and knob is longer than the 64 chars the API allows ($key)"
  setting_set "$key" "$val" "harness-ctl" || die "the worker refused or did not answer — nothing was changed"
  echo "SET $key = $val"
}

# SEED — this box's env values become the rows the page shows (BH-1165).
#
# WHY. A knob with no settings row renders as "unset" on the settings screen
# while the lane runs on a number from env/global.env behind `chattr +i`. An
# operator reading "unset" next to a lane spending $700 a day is being told the
# fleet has no opinion, which is the opposite of true.
#
# IT NEVER OVERWRITES. The rows are fleet-wide and the env files are per box, so
# the second box to seed would otherwise replace the first box's value with its
# own and change what every box does — a migration that silently re-tunes the
# fleet. A knob that already has a row is left alone, and a DIFFERENT value on
# this box is printed as a MISMATCH so the divergence is visible instead of
# resolved by whoever ran this last.
#
# NO CREDENTIALS, ever: env/global.env is full of tokens and a settings row is
# readable on a web page. The registry does not carry them (that is
# tests/lanes-registry-test.sh section 13) and this refuses them again here,
# because the cost of the two rules disagreeing is a leaked token.
#
# THE SUFFIX RULE WAS TOO NARROW (BH-1165 review). `(^|_)(TOKEN|SECRET|...)$`
# does not match DEPLOY_HOOK_URL — a Vercel deploy hook is a bearer token inside
# a URL — nor WATCHDOG_URL or LOCKS_URL, so those would have been copied out of
# env/global.env into web-visible rows. A `*_URL`, a `*HOOK*` and a `*WEBHOOK*`
# are credentials for this purpose. Those three are also `settable: false` now,
# and this skips every non-settable knob before it even looks at the name —
# belt and braces, because the two rules failing together is a leaked secret.
#
# PROJECT-SCOPED KNOBS WITH NO PROJECT ARGUMENT are written as LANE-WIDE rows,
# from this box's global.env. That is deliberate: it is what the box is running
# for every project today. Pass a project to seed that project's own env file
# into its own rows instead.
cmd_seed() {
  local dry=0 proj="" resp rows id env key cur val n=0 skip=0 mism=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1 ;;
      -*) die "usage: harness-ctl.sh seed [--dry-run] [project]" ;;
      *) proj="$1" ;;
    esac
    shift
  done
  if [ -n "$proj" ] && [ -f "$HENV/$proj.env" ]; then
    set -a; # shellcheck disable=SC1091
    . "$HENV/$proj.env"; set +a
  fi
  # The rows that already exist. A worker that does not answer means we cannot
  # tell "no row" from "cannot read", so nothing is written at all.
  resp=$(_jobs_req GET /api/settings) || die "the worker did not answer — nothing was seeded"
  # A registry-seed row (BH-1511.1) is the DB's copy of the DEFAULT, not a value
  # anybody chose, so it does not count as "already set": this box's env value
  # is what the lane runs on, and it is written over the mirror.
  rows=$(printf '%s' "$resp" | jq -r '.settings[]?|select(.actor != "registry-seed")|.key' 2>/dev/null | tr '\n' ' ')
  while IFS=$'\t' read -r id env scope; do
    [ -n "$env" ] || continue
    grep -qE '(^|_)(TOKEN|SECRET|PASSWORD|CREDENTIALS?|KEY|URL|HOOK|WEBHOOK)$|HOOK' <<<"$env" && continue
    val="${!env:-}"
    [ -n "$val" ] || continue
    if [ "$scope" = project ] && [ -n "$proj" ]; then key="lane.$id.$proj.$env"; else key="lane.$id.$env"; fi
    key=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')
    [ "${#key}" -le 64 ] || continue
    case " $rows " in
      *" $key "*)
        cur=$(printf '%s' "$resp" | jq -r --arg k "$key" '.settings[]?|select(.key==$k)|.value' 2>/dev/null)
        if [ "$cur" != "$val" ]; then
          echo "MISMATCH $key: the row says '$cur', this box's env says '$val' — left alone"
          mism=$((mism+1))
        else
          skip=$((skip+1))
        fi
        continue ;;
    esac
    if [ "$dry" = 1 ]; then
      echo "would seed $key = $val   ($env)"
    else
      setting_set "$key" "$val" "${JOBS_BOX:-cli}-seed" || die "the worker refused at $key — $n rows were written before it"
      echo "seeded $key = $val"
    fi
    n=$((n+1))
  done < <(jq -r '.lanes[]|.id as $i|.scope as $s|.knobs[]?|select(.env)|select(.settable!=false)|select(.project_scoped!=false or $s!="project")|[$i,.env,$s]|@tsv' "$REG")
  echo "seed: $n $([ "$dry" = 1 ] && echo would-be) row(s), $skip already matching, $mism mismatched"
}

# cmd_seed_registry [--dry-run] [--exclude-box <box>]... — the worker mirrors
# the registry the deploy baked in (lanes + libs) into settings rows under actor
# `registry-seed`. The list is the worker's, never this CLI's, so the route
# cannot be handed an arbitrary key. Those rows rank below the env and the
# registry on a box running the contract (bin/lib/lane-gate.sh), so seeding
# changes no lane THERE.
#
# IT REFUSES UNTIL EVERY BOX RUNS THE CONTRACT (BH-1511.1 review, I2). A box on
# the old lane-gate reads a registry-seed row as an operator value and exports
# it — and for the knobs whose read disagrees with the registry default
# (docs/config-inventory/registry-drift.tsv) that moves a running lane. So:
# find the commit that introduced the seed actor in this box's own checkout,
# and require every box that RUNS LANE-GATE to report a harness_commit (the NEW
# lane-gate's hourly liveness post, stored in box_status under the same name)
# that descends from it, reported within SEED_GATE_MAX_AGE_S.
#
# WHICH BOXES (review round 2, B1): the distinct lane_ticks.box that ticked a
# lane in the last SEED_GATE_TICK_WINDOW_S seconds (GET /api/lanes/tick-boxes)
# — NOT box_status. box_status also holds the CLI sweep's cron_box_id_for
# aliases (box-hub -> hub), which can never carry a commit and made
# this refuse forever, and it has no row for a box that ticks lanes but never
# reported a backup or CLI version, which this used to pass unseen. Every
# lane-gate, old or new, writes lane_ticks. A box_status row with no tick in
# the window is listed as not checked, never silently.
#
# Unreadable, empty, silent, stale, unknown or behind is a refusal naming the
# box, and nothing is POSTed. A retired box is passed over only by naming it
# (`--exclude-box`), and the exclusion is printed. `--dry-run` runs the same
# gate, prints what the seed would insert/update/prune (GET
# /api/settings/seed-registry/plan, which writes nothing), and exits 1 when the
# real run would be refused.
SEED_GATE_MAX_AGE_S=7200
SEED_GATE_TICK_WINDOW_S="${SEED_GATE_TICK_WINDOW_S:-86400}"
SEED_USAGE="usage: harness-ctl.sh seed-registry [--dry-run] [--exclude-box <box>]..."
cmd_seed_registry() {
  local dry=0 excl=" " co seedc
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1 ;;
      --exclude-box) [ -n "${2:-}" ] || die "$SEED_USAGE"; excl="$excl$2 "; shift ;;
      *) die "$SEED_USAGE" ;;
    esac
    shift
  done
  case "$SEED_GATE_TICK_WINDOW_S" in ''|*[!0-9]*) die "SEED_GATE_TICK_WINDOW_S must be whole seconds (got '$SEED_GATE_TICK_WINDOW_S') — nothing was seeded" ;; esac
  co="${HARNESS_CHECKOUT:-/root/harness-checkout}"
  seedc=$(git -C "$co" log --format=%H -S'_LG_SEED_ACTOR=registry-seed' -- bin/lib/lane-gate.sh 2>/dev/null | tail -1)
  [ -n "$seedc" ] || die "cannot find the commit that introduced the settings contract in $co — nothing was seeded"
  _seed_gate "$co" "$seedc" "$excl"
  [ "$excl" = " " ] || echo "seed-registry: excluded by request:$excl"
  if [ "$dry" = 1 ]; then _seed_dry_run; return; fi
  _seed_refuse_if_bad
  _seed_post
}

# _seed_gate <checkout> <contract-sha> <excluded> — sets SEED_BAD (one "\n  box:
# reason" per unproven box). Dies, nothing seeded, when either list is unreadable.
_seed_gate() {
  local co="$1" seedc="$2" excl="$3" ticks boxes now b row c at unchecked
  ticks=$(_jobs_req GET "/api/lanes/tick-boxes?within_s=$SEED_GATE_TICK_WINDOW_S") \
    || die "the worker did not answer GET /api/lanes/tick-boxes (or predates it) — cannot tell which boxes run lane-gate, nothing was seeded"
  ticks=$(printf '%s' "$ticks" | jq -r '.boxes[]?.box // empty' 2>/dev/null)
  [ -n "$ticks" ] || die "no box ticked a lane in the last ${SEED_GATE_TICK_WINDOW_S}s — cannot prove every box runs the contract, nothing was seeded"
  boxes=$(_jobs_req GET /api/boxes) || die "the worker did not answer GET /api/boxes — cannot prove every box runs the contract, nothing was seeded"
  printf '%s' "$boxes" | jq -e '.boxes|type=="array"' >/dev/null 2>&1 \
    || die "GET /api/boxes answered no box list — cannot prove every box runs the contract, nothing was seeded"
  now="${HARNESS_CTL_NOW:-$(date -u +%s)}"; SEED_BAD=""
  for b in $ticks; do
    case "$excl" in *" $b "*) continue ;; esac
    # '|' not a tab: IFS whitespace would collapse an empty commit field.
    row=$(printf '%s' "$boxes" | jq -r --arg b "$b" 'first(.boxes[] | select(.box==$b) | "\(.harness_commit // "")|\(.harness_reported_at // "")") // "|"' 2>/dev/null)
    IFS='|' read -r c at <<< "$row"
    SEED_BAD="$SEED_BAD$(_seed_gate_box "$b" "$c" "$at" "$co" "$seedc" "$now")"
  done
  unchecked=$(printf '%s' "$boxes" | jq -r --arg t "$ticks" '($t | split("\n")) as $k | [.boxes[]?.box | strings | select(. as $x | any($k[]; . == $x) | not)] | join(" ")' 2>/dev/null)
  [ -z "$unchecked" ] || echo "seed-registry: not checked, no lane tick in ${SEED_GATE_TICK_WINDOW_S}s (CLI-sweep alias or retired): $unchecked"
}

# _seed_gate_box <box> <commit> <reported_at> <checkout> <contract> <now> —
# prints "\n  box: reason" when the box does not provably run the contract.
_seed_gate_box() {
  local b="$1" c="$2" at="$3" co="$4" seedc="$5" now="$6" age
  if [ -z "$c" ] || [ -z "$at" ]; then printf '\\n  %s: ticks lanes but never reported a harness commit (no .git and no HARNESS_COMMIT stamp in its checkout, or its lane-gate predates the contract)' "$b"; return; fi
  age=$(jq -rn --arg t "$at" '$t | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601' 2>/dev/null)
  case "$age" in ''|*[!0-9]*) printf "\\\\n  %s: unreadable report time '%s'" "$b" "$at"; return ;; esac
  age=$(( now - age ))
  if [ "$age" -gt "$SEED_GATE_MAX_AGE_S" ]; then printf '\\n  %s: last reported %ss ago (stale, limit %ss)' "$b" "$age" "$SEED_GATE_MAX_AGE_S"; return; fi
  # I-a: a sha this checkout lacks is unknown, not behind. Still a refusal.
  if ! git -C "$co" cat-file -e "$c^{commit}" 2>/dev/null; then
    printf '\\n  %s: runs %s, which this checkout (%s) does not have — fetch it (git -C %s fetch origin) and retry' "$b" "${c:0:10}" "$co" "$co"; return
  fi
  git -C "$co" merge-base --is-ancestor "$seedc" "$c" 2>/dev/null \
    || printf '\\n  %s: runs %s, which does not contain the contract %s' "$b" "${c:0:10}" "${seedc:0:10}"
}

_seed_refuse_if_bad() {
  [ -n "$SEED_BAD" ] || return 0
  printf 'seed-registry REFUSED — these boxes do not provably run the settings contract:%b\n' "$SEED_BAD" >&2
  die "nothing was seeded. Wait for fleet-propagate, or name a retired box with --exclude-box"
}

# _seed_dry_run — the plan, key by key, and the gate's verdict. Never POSTs.
_seed_dry_run() {
  local plan
  plan=$(_jobs_req GET /api/settings/seed-registry/plan) \
    || die "the worker did not answer GET /api/settings/seed-registry/plan (or predates it) — nothing was written"
  printf '%s' "$plan" | jq -r '
    "seed-registry --dry-run: \(.rows) registry default(s): \(.insert|length) to insert, \(.update|length) to update, \(.prune|length) orphan(s) to prune, \(.operator_owned // 0) operator-owned (never touched), \(.unchanged // 0) unchanged",
    (.insert[]? | "  insert  \(.)"),
    (.update[]? | "  update  \(.key)  \(.from) -> \(.to)"),
    (.prune[]?  | "  prune   \(.)")' 2>/dev/null || printf '%s\n' "$plan"
  if [ -n "$SEED_BAD" ]; then
    printf 'seed-registry --dry-run: the real seed would be REFUSED — these boxes do not provably run the settings contract:%b\n' "$SEED_BAD" >&2
    die "dry run: nothing was written"
  fi
  echo "seed-registry --dry-run: the fleet gate passes; nothing was written"
}

_seed_post() {
  local resp line
  resp=$(_jobs_req POST /api/settings/seed-registry '{}') \
    || die "the worker did not answer (or predates POST /api/settings/seed-registry) — nothing was seeded"
  line=$(printf '%s' "$resp" | jq -r '
    "seed-registry: \(.rows) registry default(s), \(.changed) row(s) written or updated, \(.pruned // 0) orphan(s) pruned (actor \(.actor))",
    (.changed_keys[]? | "  wrote   \(.)"),
    (.pruned_keys[]?  | "  pruned  \(.)")' 2>/dev/null) || line="$resp"
  printf '%s\n' "$line"
}

cmd_all_off() {
  local reason="$*" resp
  [ -n "$reason" ] || die "a fleet stop needs a reason"
  resp=$(_jobs_req POST /api/lanes/all-off \
    "$(jq -nc --arg a "${JOBS_BOX:-cli}" --arg r "$reason" '{actor:$a,reason:$r}')") \
    || die "the worker did not answer — the fleet is NOT stopped"
  # The file too, on this box, for the same reason flag_set writes it first: the
  # row is what the fleet reads, the file is what THIS box reads when it cannot.
  mkdir -p "$HARNESS/flags" 2>/dev/null && touch "$HARNESS/flags/all-off" 2>/dev/null
  printf '%s' "$resp" | jq -r '"FLEET STOP is ON since \(.flag.updated_at) — \(.flag.reason)"' 2>/dev/null
  echo "note: every box picks this up within 60s (bin/lib/lane-gate.sh's cache). In-flight ticks finish."
}

cmd_all_on() {
  local reason="$*" resp
  # A resume names a human and says why, the same as the stop. Resuming during
  # an incident is a decision, and the row is where the next person reads it.
  [ -n "$reason" ] || die "a fleet resume needs a reason"
  resp=$(_jobs_req POST /api/lanes/all-on \
    "$(jq -nc --arg a "${JOBS_BOX:-cli}" --arg r "$reason" '{actor:$a,reason:$r}')") \
    || die "the worker did not answer — the fleet stop is still ON"
  rm -f "$HARNESS/flags/all-off" 2>/dev/null
  echo "FLEET STOP cleared."
  echo "note: lanes stopped individually are still stopped — bin/harness-ctl.sh status"
  printf '%s' "$resp" >/dev/null
}

cmd_review() { exec "$HARNESS/bin/lead-verdict.sh" request "$@"; }

case "${1:-status}" in
  status)  shift || true; cmd_status "${1:-}" ;;
  show)    shift || true; cmd_show "$@" ;;
  off)     shift || true; cmd_off "$@" ;;
  on)      shift || true; cmd_on "$@" ;;
  set)     shift || true; cmd_set "$@" ;;
  seed)    shift || true; cmd_seed "$@" ;;
  seed-registry) shift || true; cmd_seed_registry "$@" ;;
  all-off) shift || true; cmd_all_off "$@" ;;
  all-on)  shift || true; cmd_all_on "$@" ;;
  review)  shift || true; cmd_review "$@" ;;
  *) die "unknown verb '${1:-}' — try: status show off on set seed seed-registry all-off all-on review" ;;
esac
