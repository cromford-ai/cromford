#!/bin/bash
# bin/flow-agent.sh — the flow agent (BH-9924, tracer slice BH-9956). The fleet
# measures pool under-use (bin/lib/pool-underuse.sh) and nothing acted on it.
# This lane finds WHY ready work waits: one pass on one project reads the board
# and the D1 state, gives each waiting ticket a cause code, writes the waiting
# set, and acts (or records `would`) once per cause.
#
#   bin/flow-agent.sh run --project <p> [--reason event:<id>]
#   bin/flow-agent.sh tick [--project <p>]
#
# run: the kill switch (lane_gate_or_exit flow-agent, then the settings row
# flow_agent.enabled: 0 or no row is off, unreadable is could-not-run), then
# flock -n locks/flow-agent-<p>.lock (DEDUPE for one pass, never a queue),
# flow_collect, flow_cause per record, ONE fa_waiting_put, flow_act per stalled
# record, and one summary line in logs/flow-agent.log:
#   <UTC> tick <p> mode=<m> trigger=<t> tickets=<n> codes=<code:n,...> actions=<n> refused=<n> truncated=<n>
# tick: flow_trigger <p> for each project (--project, else this box's
# projects). `none` logs `<UTC> tick <p> trigger=none` and runs no pass; any
# other word runs the pass in this process with that trigger.
#
# It never merges, publishes, changes a ticket's scope or deletes a dependency
# edge: the only writes are flow_actions and flow_waiting rows (and, later,
# what an arm built by a sibling ticket does after its claim).
# Exit 0 always, except a usage error (exit 2).
# The clock seam is FLOW_AGENT_NOW (epoch, tests only).
#
# gh-rest: no-graphql
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
set -a; . "$HENV/global.env" 2>/dev/null; set +a

usage() { echo "usage: flow-agent.sh run --project <p> [--reason event:<id>] | tick [--project <p>]" >&2; exit 2; }
VERB="${1:-}"; [ $# -gt 0 ] && shift
P=""; REASON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage; P="$2"; shift 2 ;;
    --reason)  [ $# -ge 2 ] || usage; REASON="$2"; shift 2 ;;
    *) usage ;;
  esac
done
case "$VERB" in
  run)  [ -n "$P" ] || usage ;;
  tick) ;;
  *) usage ;;
esac
case "$P" in *[!a-z0-9._-]*|.*) usage ;; esac
case "$REASON" in ''|event:[A-Za-z0-9._:-]*) ;; *) usage ;; esac

# >>> lane gate — flags/all-off and flags/lane-off-flow-agent stop the lane
# BEFORE any read; lane_env_apply puts this lane's settings rows into the env.
# Both fail OPEN. Registry row: BH-9924.1 (#9957).
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit flow-agent "$P"
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    flow-agent

mkdir -p "$H/logs" "$H/locks" 2>/dev/null
say() { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*" >> "$H/logs/flow-agent.log"; }

# bin/jobs-client.sh `exit`s when a module is missing, so it is proved
# loadable in a child shell first.
if bash -c '. "$1"' _ "$H/bin/jobs-client.sh" >/dev/null 2>&1; then
  # shellcheck source=bin/jobs-client.sh
  . "$H/bin/jobs-client.sh" >/dev/null 2>&1
fi
# shellcheck source=bin/lib/gh-rest.sh
. "$H/bin/lib/gh-rest.sh" 2>/dev/null
# shellcheck source=bin/lib/gh-rest-list.sh
. "$H/bin/lib/gh-rest-list.sh" 2>/dev/null
# shellcheck source=bin/lib/tracker.sh
. "$H/bin/lib/tracker.sh" 2>/dev/null
# shellcheck source=bin/lib/preplan-lib.sh
. "$H/bin/lib/preplan-lib.sh" 2>/dev/null
# shellcheck source=bin/lib/board-creds.sh
. "$H/bin/lib/board-creds.sh" 2>/dev/null
# shellcheck source=bin/lib/jobs/flow-agent.sh
. "$H/bin/lib/jobs/flow-agent.sh" 2>/dev/null
# shellcheck source=bin/lib/flow-agent/collect.sh
. "$H/bin/lib/flow-agent/collect.sh" 2>/dev/null
# shellcheck source=bin/lib/flow-agent/cause.sh
. "$H/bin/lib/flow-agent/cause.sh" 2>/dev/null
# shellcheck source=bin/lib/flow-agent/trigger.sh
. "$H/bin/lib/flow-agent/trigger.sh" 2>/dev/null
# shellcheck source=bin/lib/flow-agent/gates.sh
. "$H/bin/lib/flow-agent/gates.sh" 2>/dev/null
# shellcheck source=bin/lib/flow-agent/diagnose.sh
. "$H/bin/lib/flow-agent/diagnose.sh" 2>/dev/null
# shellcheck source=bin/lib/flow-agent/act.sh
. "$H/bin/lib/flow-agent/act.sh" 2>/dev/null
for f in _jobs_req setting_get gh_rest_issue_list gh_rest_pr_list_all preplan_key_prefix fa_claim flow_collect flow_cause flow_act flow_trigger flow_gates flow_diagnose; do
  declare -F "$f" >/dev/null || { say "could-not-run ${P:-fleet} lib $f"; exit 0; }
done

# pass <project> <trigger> — one pass. Always returns 0.
pass() {
  local p="$1" trig="$2" en rc mode W n=0 i code o actions=0 refused=0 codes="" lk
  local -A count=()
  en=$(setting_get flow_agent.enabled); rc=$?
  case "$rc" in
    0) [ "$en" = 1 ] || { say "off $p flow_agent.enabled=$en"; return 0; } ;;
    2) say "off $p flow_agent.enabled has no row"; return 0 ;;
    *) say "could-not-run settings $p"; return 0 ;;
  esac
  lk="$H/locks/flow-agent-$p.lock"
  exec 9>"$lk" || { say "could-not-run $p lock"; return 0; }
  flock -n 9 || { say "skip $p locked"; exec 9>&-; return 0; }
  mode=$(fa_mode "$p") || mode=log
  W=$(mktemp -d "${TMPDIR:-/tmp}/flow-agent.XXXXXX") || { say "could-not-run $p mktemp"; exec 9>&-; return 0; }
  if ! flow_collect "$p" > "$W/records.jsonl"; then
    say "could-not-run $p ${FA_COLLECT_WHY:-collect}"
    rm -rf "$W"; exec 9>&-; return 0
  fi
  [ "${FA_BOARD_TRUNCATED:-0}" = 1 ] && say "board-truncated $p the open-issue list filled flow_agent.issue_list_pages"
  : > "$W/stalled.tsv"; : > "$W/rows.jsonl"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n + 1))
    printf '%s\n' "$line" > "$W/rec.$n.json"
    code=$(flow_cause < "$W/rec.$n.json")
    count[$code]=$(( ${count[$code]:-0} + 1 ))
    [ "$code" = not_stalled ] && continue
    printf '%s\t%s\n' "$n" "$code" >> "$W/stalled.tsv"
    jq -c --arg c "$code" --arg ev "$(fa_state "$W/rec.$n.json")" '
        def iso: if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$") then . else null end;
        {key, code: $c, since: ((.triaged_at | iso) // (.updated_at | iso) // (.now | todate)), episode,
         evidence: ($ev + (if (.unread // []) | length > 0 then ",unread:" + (.unread | join("+")) else "" end))}' \
      "$W/rec.$n.json" >> "$W/rows.jsonl"
  done < "$W/records.jsonl"
  jq -s -c '.' "$W/rows.jsonl" > "$W/rows.json"
  fa_waiting_put "$p" "$W/rows.json"; rc=$?
  [ "$rc" = 0 ] || say "waiting-put-failed $p rc=$rc"
  while IFS=$'\t' read -r i code; do
    o=$(flow_act "$W/rec.$i.json" "$code")
    case "$o" in done|failed) actions=$((actions + 1)) ;; refused) actions=$((actions + 1)); refused=$((refused + 1)) ;; esac
  done < "$W/stalled.tsv"
  for code in $(printf '%s\n' "${!count[@]}" | LC_ALL=C sort); do codes="$codes${codes:+,}$code:${count[$code]}"; done
  say "tick $p mode=$mode trigger=$trig tickets=$n codes=${codes:-none} actions=$actions refused=$refused truncated=${FA_TRUNCATED:-0}"
  rm -rf "$W"; exec 9>&-
  return 0
}

if [ "$VERB" = run ]; then
  pass "$P" "${REASON:-manual}"
  exit 0
fi

# tick
if [ -n "$P" ]; then PROJECTS="$P"
else PROJECTS=$(FLEET_CONF="${FLEET_CONF:-$H/fleet.conf}" "$H/bin/fleet-conf.sh" --projects-on-box "${BOX_NAME:-$(hostname -s 2>/dev/null || hostname)}" 2>/dev/null) || { say "could-not-run fleet-conf"; exit 0; }
fi
for p in $PROJECTS; do
  t=$(flow_trigger "$p" 2>/dev/null) || t=none
  case "$t" in
    ''|none) say "tick $p trigger=none" ;;
    *) pass "$p" "$(printf '%s' "$t" | tr -c 'A-Za-z0-9:._-' '_')" ;;
  esac
done
exit 0
