#!/bin/bash
# bin/lib/cron-lines.sh — the ONE definition of what a project's cron lanes are.
#
# WHY THIS FILE EXISTS (project-7, 2026-08-30). The crontab had two writers:
# bootstrap-machine.sh generated a project's lines live from fleet.conf, and
# update-runners.sh applied a hand-maintained cron/<box-id>.cron. Onboarding
# project-7 installed seven lines the repo file had never heard of, and the next
# 05:17 tick copied the file back over them. The lane was dead for ten hours;
# nothing errored, because from each writer's point of view nothing was wrong.
#
# So the lines are DERIVED, once, here — and both writers call this. A box's
# crontab is now: its own box-specific lines, kept verbatim, plus one generated
# block per project fleet.conf assigns to that box. See bin/render-crontab.sh.
#
# Sourced, not executed. Every function writes to stdout and touches nothing.

# cron_box_id_for <fleet.conf box value> -> the cron/<id>.cron file's id
#
# fleet.conf's box column holds HOSTNAMES (box-project-3-2) because that is
# what `ssh root@...` needs; the crontab files are named by the short box id
# (project-3) because that is what /root/harness/state/box-id carries. Nothing else
# in the fleet writes the relationship down, so it lives here and only here — a
# second spelling of it is exactly how the two planes drifted apart before.
#
# A trailing "-<number>" is a machine GENERATION, not a different box:
# box-project-3-2 is the project-3 box's second VM and still runs cron/project-3.cron.
# BH-4080: the hub's fleet name (HUB_BOX_NAME, else HARNESS_HUB_BOX) and the box
# naming prefix (HARNESS_BOX_PREFIX) live in the deployment defaults home.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$(dirname "${BASH_SOURCE[0]}")/deployment.sh}" || return 1

cron_box_id_for() {
  local B="${1:-}"
  # "local" is fleet.conf's word for "the hub runs this itself"; the hub's fleet
  # name is its watchdog ping name. Both mean cron/hub.cron.
  case "$B" in
    ''|local|"${HUB_BOX_NAME:-$HARNESS_HUB_BOX}") printf 'hub\n'; return 0 ;;
  esac
  B="${B#"$HARNESS_BOX_PREFIX"}"
  case "$B" in *-[0-9]|*-[0-9][0-9]) B="${B%-*}" ;; esac
  printf '%s\n' "$B"
}

# cron_watchdog_name_for <box id> -> the name that box pings the watchdog with
#
# The INVERSE of cron_box_id_for, and string surgery cannot compute it:
# cron_box_id_for DROPS a machine generation, so a hostname ending in "-2"
# and the bare id both answer the same box, and re-prefixing the id would
# produce a name that box has never pinged under. A ping under the wrong name
# is indistinguishable, at the watchdog, from a box that is down.
#
# So the answer is READ BACK OUT OF THE REGISTRY: the fleet.conf box column of
# the first project whose box resolves to this id, suffix and all. FLEET_CONF is
# honoured (bin/fleet-conf.sh reads it first), so a caller pointed at a fixture
# or at a box's own /root/harness copy gets that registry's answer.
#
# "hub" is the one literal, and it is not a second spelling of anything: no
# fleet.conf row points at the hub, and cron_box_id_for already writes down
# box-hub as the hub's ping name.
#
# A box the registry cannot name prints NOTHING and returns 1. Every caller MUST
# refuse on that rather than fall back to a plausible name — bin/render-cron.sh
# does, by refusing the whole render with an empty stdout.
cron_watchdog_name_for() {
  local ID="${1:-}" LIB_HERE P B
  [ -n "$ID" ] || return 1
  [ "$ID" != hub ] || { printf '%s\n' "${HUB_BOX_NAME:-$HARNESS_HUB_BOX}"; return 0; }
  LIB_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || return 1
  while read -r P; do
    [ -n "$P" ] || continue
    B=$("$LIB_HERE/box-for.sh" "$P" 2>/dev/null) || continue
    [ -n "$B" ] || continue
    [ "$(cron_box_id_for "$B")" = "$ID" ] || continue
    printf '%s\n' "$B"
    return 0
  done < <("$LIB_HERE/fleet-conf.sh" --projects 2>/dev/null)
  return 1
}

# cron_managed_scripts -> the bin/ scripts whose per-project lines this library
# owns, as an alternation for a regex. A line invoking one of these WITH a
# project this box owns is generated; anything else in a crontab is the
# operator's and is preserved untouched.
#
# Deliberately NOT in the set: security-scan.sh, postmerge-qa.sh, rebase-train.sh
# and mirror-sync.sh. They take a project argument but are not part of what
# onboarding installs, they are enabled per project by hand, and generating them
# for every project would turn one box's deliberate choice into a fleet default.
cron_managed_scripts() {
  printf 'run-triage|run-product|healthcheck|apply-migrations|merge-queue|deploy-train|review-prs\n'
}

# cron_stagger_min <base> <period> <used> -> the first minute in [0,period),
# counting up from base mod period, that is not in the space list <used>.
# After <period> tries every minute is taken, and it prints base: a shared
# minute, never a hang.
cron_stagger_min() {
  local base="${1:?base}" period="${2:?period}" used=" ${3-} " i m
  for ((i = 0; i < period; i++)); do
    m=$(( (base + i) % period ))
    case "$used" in *" $m "*) ;; *) printf '%s\n' "$m"; return 0 ;; esac
  done
  printf '%s\n' "$(( base % period ))"
}

# cron_project_block <project> <offset> <prod-url> <repo-root> [<mq-min> <rp-min>]
#
# The seven lanes a watched project runs, extracted verbatim from what
# bootstrap-machine.sh used to generate inline. Two are CONDITIONAL, and both
# conditions are about a script that is NOT a quiet no-op when it is wrong:
#
#   run-product   requires prompts/product-<project>.md. Without it the script
#                 writes an ALERTS line and exits 1 — so an unconditional weekly
#                 line is a guaranteed Monday alert, forever, for every project
#                 that has no product prompt (project-5, project-8 and
#                 project-7 were each doing exactly that).
#   healthcheck   requires a real prod URL. fleet.conf's "-" means there is no
#                 prod surface; the script exits 0 on it, so the line is dead
#                 weight rather than harmful — but a dead line in a generated
#                 file reads as a lane someone forgot to wire up.
#
# The other five are unconditional. Four of them fail CLOSED and SILENT on a
# project they do not apply to, which was verified rather than assumed; the
# fifth applies to every project:
#   apply-migrations  `case ... *) exit 0` — quiet no-op off the original four
#   merge-queue       `case ... *) exit 1` — no output, no side effect
#   deploy-train      exits 0 without VERSION_URL/DEPLOY_HOOK_URL, then *) exit 1
#   review-prs        resolves the repo slug from fleet.conf, so the line is
#                     live for every project in the registry (BH-659). A
#                     project it cannot resolve writes ONE ALERTS line and
#                     exits 1 — this lane is no longer silent on anything.
#   run-triage        the lane itself; every watched project has one
#
# merge-queue and review-prs start at a per-project minute, not one fixed
# minute for every project: on box-small all four projects fired
# merge-queue at :06 and review-prs at :07 together. <mq-min> (0-19, then +20
# and +40) and <rp-min> (0-29, then +30) are what bin/render-crontab.sh probed
# so two projects on one box never share one. Absent or not a number, they
# come from the offset: (6 + offset) % 20 and (7 + offset) % 30, so offset 0
# keeps the old 6,26,46 and 7,37.
cron_project_block() {
  local P="${1:?project}" OFF="${2:?offset}" PROD="${3-}" ROOT="${4:?repo root}"
  local MQ="${5-}" RP="${6-}"
  case "$MQ" in ''|*[!0-9]*) MQ=$(( (6 + OFF) % 20 )) ;; *) MQ=$(( 10#$MQ % 20 )) ;; esac
  case "$RP" in ''|*[!0-9]*) RP=$(( (7 + OFF) % 30 )) ;; *) RP=$(( 10#$RP % 30 )) ;; esac
  printf '# BEGIN fleet-managed project=%s\n' "$P"
  printf '%s,%s,%s,%s,%s,%s * * * * /root/harness/bin/run-triage.sh %s\n' \
    "$OFF" "$((OFF+10))" "$((OFF+20))" "$((OFF+30))" "$((OFF+40))" "$((OFF+50))" "$P"
  if [ -f "$ROOT/prompts/product-$P.md" ]; then
    printf '%s 9 * * 1 /root/harness/bin/run-product.sh %s\n' "$OFF" "$P"
  fi
  if [ -n "$PROD" ] && [ "$PROD" != "-" ]; then
    printf '43 6,18 * * * /root/harness/bin/healthcheck.sh %s\n' "$P"
  fi
  printf '*/15 * * * * /root/harness/bin/apply-migrations.sh %s\n' "$P"
  # The two redirects are the evolved form three of the five legacy boxes already
  # carried. merge-queue keeps its own log, so this only catches stray stderr
  # that would otherwise go to cron mail nobody reads; deploy-train is silent on
  # success and its failures beat, so its output is noise.
  printf '%s,%s,%s * * * * /root/harness/bin/merge-queue.sh %s >> /root/harness/logs/merge-queue.log 2>&1\n' \
    "$MQ" "$((MQ+20))" "$((MQ+40))" "$P"
  printf '4,19,34,49 * * * * /root/harness/bin/deploy-train.sh %s >/dev/null 2>&1\n' "$P"
  printf '%s,%s * * * * /root/harness/bin/review-prs.sh %s\n' "$RP" "$((RP+30))" "$P"
  printf '# END fleet-managed project=%s\n' "$P"
}

# cron_box_lines [fly] — the box-level singletons, which are per-BOX and not
# per-project: a two-project box runs ONE preplan tick, not two. They are not
# part of a managed block for that reason, and bootstrap-machine.sh emits them
# into its base before the renderer lays the project blocks on top.
cron_box_lines() {
  printf '*/2 * * * * /root/harness/bin/preplan-tick.sh\n'
  printf '*/10 * * * * /root/harness/bin/reconcile-prs.sh\n'
  printf '17 5 * * * /root/harness/bin/update-runners.sh\n'
  # harden-state re-arm (BH-390): chattr +i on env/ and the ssh key, +a on the
  # ledgers, so a file a writer released never stays writable. It serialises on
  # locks/harden-state.lock with flock -w 60, prints a hardened=N/M changed=K line
  # on every run, and appends to logs/harden-state.log only when it actually
  # changed a flag, so the >/dev/null 2>&1 is what keeps the tick silent.
  # bootstrap-machine.sh does not filter this line out of a live crontab yet (that
  # is the last slice of BH-390), so a re-bootstrap of a box that already runs it
  # carries two copies for now: harmless, the lock serialises them and the second
  # tick finds everything armed and writes nothing.
  printf '*/10 * * * * /root/harness/bin/harden-state.sh >/dev/null 2>&1 # BH-390: re-arm chattr +i env/ssh, +a ledgers, a released file never stays writable\n'
  # state-backup (BH-448, #396): the off-box copy of this box's harness state,
  # per BOX not per project. Off: STATE_BACKUP=0 / flags/state-backup-off.
  printf '5,20,35,50 * * * * /root/harness/bin/state-backup.sh >/dev/null 2>&1\n'
  if [ "${1:-}" = fly ]; then
    printf '*/2 * * * * /root/harness/bin/fly-dispatch.sh\n'
    printf '*/2 * * * * /root/harness/bin/fly-results-ingest.sh sweep\n'
  fi
}
