#!/bin/bash
# fleet-conf.sh <project> <field> — read one field for a project from fleet.conf.
# Fields: repo | prod | board_prefix | offset | box | tailnet_ip
#         box may be empty (legacy rows) — callers use bin/box-for.sh, which
#         applies the naming-convention fallback.
# fleet-conf.sh --projects  — list all project names (col 1), comments stripped.
# fleet-conf.sh --projects-with-board — the subset whose board-api-prefix is a
#         real path (col 4 != "-"), i.e. the projects served by an IN-APP product
#         board. The complement is the GitHub-Issues lane. This is the honest way
#         to ask "which projects have a board?"; hardcoding the four original OS
#         projects is what left project-7/project-6/project-5 out of every lane
#         that asked (2026-09-10 incident).
# fleet-conf.sh --projects-on-box <box> — the subset whose watcher runs on <box>,
#         resolved through bin/box-for.sh so legacy rows with no box column get
#         the naming-convention fallback. "local" means the hub itself.
#         Caller: bin/cost-local-brake.sh --projects-on-box (BH-2599), which
#         judges only the projects its own box owns. The bin/fly-* lanes still
#         key on a per-box tailscale IP; they could resolve through here too.
#         It is the box-scoped counterpart of --projects-with-board and the two
#         are one lookup.
# fleet-conf.sh --tailnet-ip <project>      — that project's box's tailnet address
# fleet-conf.sh --tailnet-ip-of-box <box>   — the same, keyed on the box name
# fleet-conf.sh --tailnet-ips               — every distinct box address, one pass
#         THE REGISTRY ANSWERS THIS NOW (2026-09-11). Nine scripts each carried
#         their own IP table, some keyed on a project and some on a short box
#         label, so a box that moved had to be found in nine places — and until
#         this column existed the registry genuinely could not answer it, which
#         is why every one of them was allowlisted rather than fixed.
#         BOTH EXIT 1 AND PRINT NOTHING when the address is unknown. That is the
#         whole contract: callers must fail closed, because an empty ssh target
#         is `root@` — a hang, not an error, and hangs are what the fleet's
#         timeouts are already fighting.
# fleet-conf.sh --box-ids                  — every distinct box ID of the active rows,
#         one per line, sorted: cron_box_id_for (bin/lib/cron-lines.sh) of col 6,
#         or of bin/box-for.sh's answer when col 6 is empty or `-` (the rule
#         box-register.sh and box-lists-check.sh use). The ids the box
#         lists key on (cron/boxes/<id>.d, catalog/lanes.d .boxes); rc 0 and
#         nothing when there are no rows (BH-5747).
# fleet-conf.sh --standby                  — every `# @standby <box> <hub-name> <hub-id>`
#         directive as `<box> <hub-name> <hub-id>`; nothing (rc 0) when none (#401).
# fleet-conf.sh --standby-of <box>         — `<hub-name> <hub-id>` for that box, first
#         directive wins; rc 1 and no output when the box is no standby.
# fleet-conf.sh --retired                  — every `# @retired <project> [box]`
#         directive as `<project> <box|->`; nothing (rc 0) when none.
# fleet-conf.sh --boxes-with-roles         — every box the file knows, one TSV line
#         `<box>\t<box_id>\t<role>`, sorted by box (LC_ALL=C). First match wins:
#         a `# @boxrole <box> <box_id> <role>` line (role one of build review
#         gate standby hub gate-only retired; any other line is skipped with a
#         stderr note), then the hub (HUB_BOX_NAME, else HARNESS_HUB_BOX) as
#         `hub`, a `# @standby` box as `standby`, an active row's box as
#         `build` (`local` is the hub), a `# @retired <project> <box>` box as
#         `retired`. The box_id is cron_box_id_for of the box, except on an
#         `@boxrole` line. A `# @box <box> <ip>` line is not a role line.
#         Readers: bin/registry-seed.sh and bin/fleet-status-push.sh.
#
# Looks for fleet.conf next to the harness (repo checkout or /root/harness).
# REGISTRY_SOURCE=db (BH-5649; default file until wave 3 of BH-5633) reads the
# D1 registry first: bin/lib/registry.sh serves a fleet.conf-format render of
# harness-jobs GET /api/registry, else its last good cache under
# state/registry/, else (rc 1) the committed file below, exactly as in file
# mode. A registry answer wins over FLEET_CONF, because bin/render-cron.sh
# exports FLEET_CONF unconditionally and would otherwise mask db mode. File
# mode never sources the library: no call, no state, no extra file read.
set -uo pipefail
ARG1="${1:?project or --projects}"
HERE="$(cd "$(dirname "$0")" && pwd)"
CONF=""
if [ "${REGISTRY_SOURCE:-file}" = db ]; then
  # shellcheck source=bin/lib/registry.sh
  . "$HERE/lib/registry.sh" 2>/dev/null \
    && RG_CONF=$(HARNESS="${HARNESS:-/root/harness}" registry_conf_path 2>/dev/null) \
    && [ -f "$RG_CONF" ] && CONF="$RG_CONF"
fi
[ -n "$CONF" ] || for CONF in "${FLEET_CONF:-}" /root/harness/fleet.conf "$(dirname "$0")/../fleet.conf"; do
  [ -n "$CONF" ] && [ -f "$CONF" ] && break
done
[ -f "${CONF:-}" ] || exit 1
if [ "$ARG1" = "--projects" ]; then
  awk '!/^[[:space:]]*(#|$)/ {print $1}' "$CONF"
  exit 0
fi
if [ "$ARG1" = "--projects-with-board" ]; then
  awk '!/^[[:space:]]*(#|$)/ && NF>=4 && $4 != "-" {print $1}' "$CONF"
  exit 0
fi
if [ "$ARG1" = "--tailnet-ips" ]; then
  # Every distinct box address in the fleet, one pass. The callers that want
  # "reach every box" (the alert sweep) had to spawn fleet-conf.sh once per
  # project to build this; the registry can answer it in one read.
  # `# @box <box> <ip>` (BH-5650) is written only by the db-mode render, for a
  # registry box that may have no project row yet. A committed fleet.conf has
  # none, so file mode answers exactly as before.
  awk '!/^[[:space:]]*(#|$)/ && $7 != "" {print $7} $1 == "#" && $2 == "@box" && NF >= 4 {print $4}' "$CONF" | sort -u
  exit 0
fi
if [ "$ARG1" = "--box-ids" ]; then
  # box-for.sh and cron-lines.sh read the SAME file this answer came from.
  export FLEET_CONF="$CONF"
  # Sourced only here: other callers copy fleet-conf.sh alone into a scratch tree.
  # shellcheck source=bin/lib/cron-lines.sh
  . "$HERE/lib/cron-lines.sh" || exit 1
  while read -r P B; do
    [ -n "$P" ] || continue
    [ -n "${B:-}" ] && [ "$B" != "-" ] || B=$("$HERE/box-for.sh" "$P" 2>/dev/null) || continue
    cron_box_id_for "$B"
  done < <(awk '!/^[[:space:]]*(#|$)/ {print $1, $6}' "$CONF") | sort -u
  exit 0
fi
if [ "$ARG1" = "--boxes-with-roles" ]; then
  export FLEET_CONF="$CONF"
  # shellcheck source=bin/lib/cron-lines.sh
  . "$HERE/lib/cron-lines.sh" || exit 1
  HUB="${HUB_BOX_NAME:-$HARNESS_HUB_BOX}"
  # One fact per line, `<precedence> <box> <box_id> <role>`; the lowest wins.
  {
    awk '$1 == "#" && $2 == "@boxrole" {
           if (NF < 5) { print "fleet-conf: skipped a @boxrole line with " NF - 2 " fields (want <box> <box_id> <role>): " $0 > "/dev/stderr"; next }
           if ($5 !~ /^(build|review|gate|standby|hub|gate-only|retired)$/) { print "fleet-conf: skipped a @boxrole line with unknown role " $5 > "/dev/stderr"; next }
           if ($4 !~ /^[a-z][a-z0-9]*$/) { print "fleet-conf: skipped a @boxrole line with bad box_id " $4 > "/dev/stderr"; next }
           print 0, $3, $4, $5 }' "$CONF"
    [ -z "$HUB" ] || echo "1 $HUB hub hub"
    while read -r B; do
      [ -n "$B" ] && echo "2 $B $(cron_box_id_for "$B") standby"
    done < <(awk '$1 == "#" && $2 == "@standby" && NF >= 5 {print $3}' "$CONF")
    while read -r P B; do
      [ -n "$P" ] || continue
      [ -n "${B:-}" ] && [ "$B" != "-" ] || B=$("$HERE/box-for.sh" "$P" 2>/dev/null) || continue
      [ "$B" != local ] || B="$HUB"
      [ -n "$B" ] && echo "3 $B $(cron_box_id_for "$B") build"
    done < <(awk '!/^[[:space:]]*(#|$)/ {print $1, $6}' "$CONF")
    while read -r B; do
      [ -n "$B" ] && echo "4 $B $(cron_box_id_for "$B") retired"
    done < <(awk '$1 == "#" && $2 == "@retired" && NF >= 4 {print $4}' "$CONF")
  } | LC_ALL=C sort -k2,2 -k1,1n | awk -v OFS='\t' '!seen[$2]++ {print $2, $3, $4}'
  exit 0
fi
if [ "$ARG1" = "--tailnet-ip" ]; then
  IP=$(awk -v p="${2:?project}" '!/^[[:space:]]*(#|$)/ && $1 == p {print $7; exit}' "$CONF")
  [ -n "${IP:-}" ] || exit 1
  echo "$IP"; exit 0
fi
if [ "$ARG1" = "--tailnet-ip-of-box" ]; then
  # Any project on that box answers for the box: the address belongs to the
  # machine, and every row naming it carries the same value. First match wins.
  # A box with no project row yet answers from its `# @box` directive.
  IP=$(awk -v b="${2:?box}" '!/^[[:space:]]*(#|$)/ && $6 == b && $7 != "" {print $7; exit}' "$CONF")
  [ -n "${IP:-}" ] || IP=$(awk -v b="$2" '$1 == "#" && $2 == "@box" && NF >= 4 && $3 == b {print $4; exit}' "$CONF")
  [ -n "${IP:-}" ] || exit 1
  echo "$IP"; exit 0
fi
if [ "$ARG1" = "--projects-on-box" ]; then
  WANT="${2:?box}"
  while read -r P; do
    [ -n "$P" ] || continue
    [ "$("$HERE/box-for.sh" "$P" 2>/dev/null)" = "$WANT" ] && echo "$P"
  done < <(awk '!/^[[:space:]]*(#|$)/ {print $1}' "$CONF")
  exit 0
fi
if [ "$ARG1" = "--standby" ]; then
  awk '$1 == "#" && $2 == "@standby" && NF >= 5 {print $3, $4, $5}' "$CONF"
  exit 0
fi
# --retired (V1 alert hygiene): every `# @retired <project> [box]` directive as
# `<project> <box|->`. A retired project is not a row (it is not watched, built
# or probed); the directive is what lets alerting and the operator sweep name it
# as GONE rather than keep a hardcoded list of it (bin/lib/alert-state.sh,
# bin/alerts-hygiene-sweep.sh). Nothing (rc 0) when there are none.
if [ "$ARG1" = "--retired" ]; then
  awk '$1 == "#" && $2 == "@retired" && NF >= 3 {print $3, (NF >= 4 ? $4 : "-")}' "$CONF"
  exit 0
fi
if [ "$ARG1" = "--standby-of" ]; then
  OF=$(awk -v b="${2:?box}" '$1 == "#" && $2 == "@standby" && NF >= 5 && $3 == b {print $4, $5; exit}' "$CONF")
  [ -n "${OF:-}" ] || exit 1
  echo "$OF"; exit 0
fi
FIELD="${2:?repo|prod|board_prefix|offset|box|tailnet_ip}"
LINE=$(grep -E "^${ARG1}[[:space:]]" "$CONF" | head -1)
[ -n "$LINE" ] || exit 1
set -- $LINE
case "$FIELD" in
  repo) echo "$2" ;;
  prod) echo "$3" ;;
  board_prefix) echo "$4" ;;
  offset) echo "$5" ;;
  box) echo "${6:-}" ;;
  # FAILS CLOSED, exactly like --tailnet-ip. A legacy 6-column row would
  # otherwise echo nothing and exit 0, and a caller doing `IP=$(... tailnet_ip)`
  # would ssh to `root@` — the hang this column exists to prevent. Two accessors
  # for one fact must not disagree about what "unknown" looks like.
  tailnet_ip) [ -n "${7:-}" ] || exit 1; echo "$7" ;;
  *) exit 1 ;;
esac
