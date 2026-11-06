#!/bin/bash
# bin/board-conformance.sh <project> | --all [--dry-run] | --file-ticket <project>
# — the daily board API conformance probe (BH-3947; skeleton BH-3958). GET
# only, deterministic, no LLM: it never writes to a board, a DB or GitHub.
#
# Per project with an in-app board:
#   1 skip   board_prefix "-" (GitHub-Issues lane): `skip <p>: GitHub-Issues
#            lane`, rc 0, nothing probed. Not a fleet.conf project: rc 2.
#   2 creds  token and base variable names from bin/lib/board-creds.sh (which
#            alerts when it cannot say), values read by name from env/<p>.env,
#            MIGRATION_TOKEN from the same file (may be empty), prod origin from
#            fleet.conf. Unresolved = probe failed, nothing probed.
#   3 probe  bc_probe_board (rc 3 = probe failed, reason in BC_PROBE_NOTE, the
#            rest skipped) -> bc_probe_origin -> bc_write_routes. Each appends
#            bc_item lines to $BC_ITEMS (bin/lib/board-conformance/*.sh).
#   4 state  state/board-conformance/<p>.json via tmp + mv: {project,
#            probed_at, probe, probe_note, items:{name:{status,note}}, gaps}.
#            gaps = sorted missing|malformed names; unverified is never a gap.
#            A failed probe writes items {} and gaps [].
#   5 alert  bc_alert_on_change <p> <statefile>, only after the write and only
#            when probe is "ok".
#   6 print  `<p> ok=N missing=N malformed=N unverified=N gaps: a,b` (or
#            `<p> probe failed: <note>`), and one line in logs/board-conformance.log.
#
# --all: every project from bin/fleet-conf.sh --projects-with-board.
# --dry-run: probes, prints the would-be state, writes none, never alerts.
# --file-ticket <p>: bc_file_ticket, no network and no lock.
# rc: 0 no gaps, 1 gaps, 2 usage / no state, 3 probe failed; the worst wins
# across --all. Knobs: catalog/lanes.d/board-conformance.json.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")

usage() { sed -n '2,29p' "$0" >&2; exit 2; }
case "${1:-}" in -h|--help) sed -n '2,29p' "$0"; exit 0 ;; esac
# >>> lane gate (BH-1165): flags/lane-off-board-conformance or all-off exits 0;
# the settings rows land in the env the knob reads below use. Both fail OPEN.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit board-conformance
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    board-conformance
export HARNESS="$H"
if [ -f "$HENV/global.env" ]; then set -a; # shellcheck disable=SC1091
  . "$HENV/global.env"; set +a; fi
# Again below the env load: global.env re-assigns the names it carries (BH-1165).
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    board-conformance
for _l in board-creds.sh board-conformance/common.sh board-conformance/board.sh \
  board-conformance/origin.sh board-conformance/writes.sh board-conformance/report.sh; do
  # shellcheck source=/dev/null
  . "$H/bin/lib/$_l" || { echo "board-conformance: cannot load bin/lib/$_l" >&2; exit 2; }
done

ALL=0; DRY=0; FT=""; P=""
while [ $# -gt 0 ]; do
  case "$1" in
    --all) ALL=1 ;;
    --dry-run) DRY=1 ;;
    --file-ticket) [ -n "${2:-}" ] || usage; FT="$2"; shift ;;
    -*) usage ;;
    *) [ -z "$P" ] || usage; P="$1" ;;
  esac
  shift
done
if [ -n "$FT" ]; then
  [ "$ALL" = 0 ] && [ -z "$P" ] || usage
  bc_file_ticket "$FT"; exit $?
fi
[ "$ALL" = 1 ] && [ -n "$P" ] && usage
[ "$ALL" = 1 ] || [ -n "$P" ] || usage

mkdir -p "$H/locks" "$H/logs" "$H/state/board-conformance" 2>/dev/null
exec 9>"$H/locks/board-conformance.lock"
flock -n 9 || exit 0

NOW="${BC_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"   # the ONLY clock read
LOG="$H/logs/board-conformance.log"

# run_project <p> — steps 1-6 for one project; returns its rc.
run_project() {
  local p="$1" bp tv="" bv="" tok="" base="" mt prod ev probe=ok note="" rc=0 json sum gaps st
  bp=$("$H/bin/fleet-conf.sh" "$p" board_prefix 2>/dev/null)
  case "$bp" in
    -) echo "skip $p: GitHub-Issues lane"; return 0 ;;
    '') echo "board-conformance: $p is not a fleet.conf project" >&2; return 2 ;;
  esac
  if tv=$(board_token_var "$p" "$HENV/$p.env" board-conformance) \
    && bv=$(board_base_var "$p" "$HENV/$p.env" board-conformance); then
    tok=$(board_env_value "$tv" "$HENV/$p.env"); base=$(board_env_value "$bv" "$HENV/$p.env")
    if [ -z "$tok" ] || [ -z "$base" ]; then
      # Both names resolved, so board-creds said nothing: the value is empty.
      if [ -z "$tok" ]; then ev="$tv"; else ev="$bv"; fi
      _bc_alert "$p" "$HENV/$p.env sets $ev to an empty value" board-conformance
    fi
  fi
  mt=$(board_env_value MIGRATION_TOKEN "$HENV/$p.env")
  prod=$("$H/bin/fleet-conf.sh" "$p" prod 2>/dev/null)
  BC_ITEMS=$(mktemp) || { echo "board-conformance: $p: mktemp failed" >&2; return 2; }
  BC_PROBE_NOTE=""
  if [ -z "$tok" ] || [ -z "$base" ]; then
    probe=failed; note="creds unresolved"
  elif [ -z "$prod" ]; then
    probe=failed; note="prod origin unresolved"
  else
    bc_probe_board "$bp" "$base" "$tok"; rc=$?
    if [ "$rc" -ne 0 ]; then
      probe=failed; note="${BC_PROBE_NOTE:-bc_probe_board rc $rc}"
    else
      bc_probe_origin "$prod" "$base" "$tok" "$mt" "$bp"
      bc_write_routes "$p"
    fi
  fi
  # A failed probe's partial items are not evidence of anything.
  [ "$probe" = ok ] || : > "$BC_ITEMS"
  json=$(jq -s --arg p "$p" --arg at "$NOW" --arg probe "$probe" --arg note "$note" '{project:$p,
      probed_at:$at, probe:$probe, probe_note:$note,
      items:(map({(.name):{status,note}})|add // {}),
      gaps:([.[]|select(.status=="missing" or .status=="malformed")|.name]|unique)}' "$BC_ITEMS")
  rc=$?; rm -f "$BC_ITEMS"
  if [ "$rc" -ne 0 ] || [ -z "$json" ]; then
    echo "board-conformance: $p: could not build the state from the probe items" >&2
    echo "$NOW $p probe=error state=unbuilt" >> "$LOG"; return 2
  fi
  st="$H/state/board-conformance/$p.json"
  if [ "$DRY" = 1 ]; then
    printf '%s\n' "$json"
  elif printf '%s\n' "$json" > "$st.tmp.$$" && mv -f "$st.tmp.$$" "$st"; then
    [ "$probe" = ok ] && bc_alert_on_change "$p" "$st"
  else
    rm -f "$st.tmp.$$"
    echo "board-conformance: $p: cannot write $st" >&2
    echo "$NOW $p probe=$probe state=unwritten" >> "$LOG"; return 2
  fi
  if [ "$probe" != ok ]; then
    echo "$p probe failed: $note"
    echo "$NOW $p probe=failed note=$note" >> "$LOG"; return 3
  fi
  sum=$(jq -r '[.items[].status] as $s | def n(x): [$s[]|select(.==x)]|length;
    "ok=\(n("ok")) missing=\(n("missing")) malformed=\(n("malformed")) unverified=\(n("unverified"))"' <<<"$json")
  gaps=$(jq -r '.gaps|join(",")' <<<"$json")
  echo "$p $sum gaps: $gaps"
  echo "$NOW $p probe=ok $sum gaps=${gaps:--}" >> "$LOG"
  [ -z "$gaps" ] || return 1
  return 0
}

if [ "$ALL" = 0 ]; then run_project "$P"; exit $?; fi
PS=$("$H/bin/fleet-conf.sh" --projects-with-board 2>/dev/null); frc=$?
if [ "$frc" -ne 0 ] || [ -z "$PS" ]; then
  echo "board-conformance: bin/fleet-conf.sh --projects-with-board listed no project (rc $frc)" >&2
  echo "$NOW --all: no project with a board (fleet-conf rc $frc)" >> "$LOG"; exit 2
fi
WORST=0
for p in $PS; do
  run_project "$p"; r=$?
  [ "$r" -gt "$WORST" ] && WORST=$r
done
exit "$WORST"
