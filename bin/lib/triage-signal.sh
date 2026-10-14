#!/bin/bash
# bin/lib/triage-signal.sh — settle a ticket change that carries no human signal
# (BH-2542). Sourced by bin/lib/rt/shards.sh inside the shard section, after
# bin/lib/triage-shards-lib.sh; defines functions and resolves its two knobs.
#
# THE GAP. The per-ticket fingerprint (BH-1015) hashes the ticket's LIVE board
# entry, which moves on our own comments, on labels and on the waitingOn /
# triageVerdict a triage session writes. Once one real change makes a tick RUN,
# every other key whose only change was that churn is bought again.
#
# THE SETTLE. When a key's fingerprint moved and its stamp is still inside
# TRIAGE_SHARD_FP_TTL_S, the dispatcher asks for the key's SIGNAL fingerprint:
# the same fingerprint with the live board entry replaced by the digest of the
# human-authored thread (`bin/triage-gate.sh <p> --signal <key>`, which runs
# bin/triage-signal.py). Equal to the one stored at the last dispatch (stamp line
# 3) = nothing a human wrote has changed: no session, the stamp takes the new
# world fingerprint and KEEPS the old epoch, so the TTL backstop still fires.
#
# FAIL-OPEN. Knob off, no board line, a pr-* key, a ticket absent from the
# board, the per-tick read cap spent, a low GitHub budget, or a gate that did not
# print 16 hex chars: no signal fingerprint, and the key dispatches exactly as it
# did before this file existed.
#
# THE TURN (PR #2593 lead fix, 4). waitingOn is out of the digest, because the
# flip a triage session writes (team -> client) and a person's flip look the
# same there. So the stamp carries the turn as line 4, and a key whose turn has
# come BACK to the team since the stamp is never settled: that flip is a person
# (or the board) putting the ticket in our court, and it gets its session now,
# not at the 4h backstop. A flip away from the team settles; it is what our own
# sessions write, and a ticket waiting on its client has nothing for us to do.
#
# THE SAVING IS A ROW (PR #2593 lead fix, 2). Every settle appends one priced-$0
# row to logs/cost.csv through bin/lib/cost-row.sh: stage `triage-precheck`,
# row_source `settled` (BH-2604: its own marker, so a saving and a gate refusal
# count apart; cost-rollup and the unpriced-pair skip treat it like `refused`,
# a $0 that is the answer, never an unpriced call), note `settled:no-signal`,
# the ticket in its column. cost-rows-push mirrors it into cost_rows, so
# fleet-cost.csv and /api/metrics/llm-spend (`settled`) count the sessions not
# bought without a log grep. Rows written before BH-2604 say `refused`.
#
# NO APP ALLOWLIST ON A GITHUB BOARD (PR #2593 lead fix, 3). With
# HARNESS_SELF_APPS empty, nothing on a GitHub thread is ours and a settle
# could never tell our comment from a client's. The key dispatches (never
# settles), one line per tick goes to the project log, and one call per tick
# goes to bin/lane-alert.sh under the id
# `triage-signal-self-apps-<project>-<YYYYMMDD>` at warn (BH-2604): the alert
# state machine keeps that as one row, so one ALERTS line per project per day
# and no flags/ file. With the state machine off lane-alert ignores --id and
# would page every tick, so the call is --log-only then (an ALERTS line, no
# beat).
#
# SELF IDENTITIES (BH-2604). The author_actor markers and author names/userIds
# that are ours on an in-app board, beyond the gate's SELF_ACTORS names, are
# the knob TRIAGE_SIGNAL_SELF_IDENTITIES, resolved per project in
# triage_signal_sfp and handed to bin/triage-gate.sh --signal.
#
# Knobs (catalog/lanes.d/_lib.triage-signal.json), env then env/global.env:
#   TRIAGE_SIGNAL_SETTLE     1 (default) on, 0 off = the old behaviour exactly
#   TRIAGE_SIGNAL_MAX_READS  thread reads per tick, default 10, 0 = no reads
#   TRIAGE_SIGNAL_SELF_IDENTITIES  comma-separated, default agent:build-harness;
#                            settings rows lib.triage-signal[.<p>].triage_signal_self_identities
if [ "${LANE_GATE_DISABLE:-0}" != 1 ] && command -v lib_env_apply >/dev/null 2>&1; then
  lib_env_apply triage-signal >/dev/null 2>&1
fi
TRIAGE_SIGNAL_READS=0
TRIAGE_SIGNAL_SFP=""
TRIAGE_SIGNAL_TURN=""
TRIAGE_SIGNAL_APPS_WARNED=""
_TSG_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
# shellcheck source=bin/lib/cost-row.sh
command -v cost_append >/dev/null 2>&1 || . "$_TSG_DIR/cost-row.sh" 2>/dev/null || true

# triage_signal_on <harness> -> 1 or 0
triage_signal_on() {
  [ "$(_tsh_num "${1:-}" TRIAGE_SIGNAL_SETTLE 1)" = 0 ] && { echo 0; return 0; }
  echo 1
}

# triage_signal_max_reads <harness> -> thread reads allowed per tick
triage_signal_max_reads() { _tsh_num "${1:-}" TRIAGE_SIGNAL_MAX_READS 10; }

# triage_signal_sfp <harness> <project> <key> <gh> <units-file>
#   rc 0 and TRIAGE_SIGNAL_SFP set to the key's signal fingerprint; rc 1 and
#   TRIAGE_SIGNAL_SFP empty when there is none (see FAIL-OPEN above). Sets a
#   variable rather than printing: the per-tick read counter has to survive, and
#   a $( ) caller would count in a subshell.
triage_signal_sfp() {
  local h="${1:-}" p="${2:-}" k="${3:-}" gh="${4:-0}" u="${5:-}" pend d sfp ids
  TRIAGE_SIGNAL_SFP=""
  [ -n "$h" ] && [ -n "$p" ] && [ -n "$k" ] && [ -s "$u" ] || return 1
  [ "$(triage_signal_on "$h")" = 1 ] || return 1
  case "$k" in pr-*) return 1 ;; esac
  awk -F'\t' -v k="$k" '$1==k && $2=="board"{f=1} END{exit !f}' "$u" 2>/dev/null || return 1
  # Presence stays a signal: a ticket that left the board dispatches.
  pend=$(_tsh_fp_pending "$h" "$p" "$k" "$gh") || return 1
  case "$pend" in "pend absent "*) return 1 ;; esac
  if [ "$gh" = 1 ] && ! triage_signal_apps_ok "$h" "$p" "$k"; then return 1; fi
  [ "$TRIAGE_SIGNAL_READS" -lt "$(triage_signal_max_reads "$h")" ] || return 1
  if [ "$gh" = 1 ] && _tsh_gh_budget_low "$h" triage-signal >/dev/null 2>&1; then return 1; fi
  TRIAGE_SIGNAL_READS=$((TRIAGE_SIGNAL_READS + 1))
  # This project's identities, in a subshell so one project's row never
  # reaches the next key's gate.
  ids=""
  if [ "${LANE_GATE_DISABLE:-0}" != 1 ] && command -v lib_env_apply >/dev/null 2>&1; then
    ids=$(lib_env_apply triage-signal "$p" >/dev/null 2>&1; printf '%s' "${TRIAGE_SIGNAL_SELF_IDENTITIES:-}")
  else
    ids="${TRIAGE_SIGNAL_SELF_IDENTITIES:-}"
  fi
  d=$(TRIAGE_SIGNAL_SELF_IDENTITIES="$ids" "$h/bin/triage-gate.sh" "$p" --signal "$k" 2>/dev/null) || return 1
  grep -qxE '[0-9a-f]{16}' <<<"$d" || return 1
  sfp=$(triage_shard_fp "$h" "$p" "$k" "$gh" "$u" "sig $d") || return 1
  # shellcheck disable=SC2034  # both read by bin/lib/rt/shards.sh
  TRIAGE_SIGNAL_SFP="$sfp"
  # shellcheck disable=SC2034
  TRIAGE_SIGNAL_TURN=$(_triage_signal_turn "$pend")
}

# _triage_signal_turn <pend-line> -> the entry's waitingOn, lowercased; empty
#   when the board has none (GitHub) or it cannot be read.
_triage_signal_turn() {
  local j="${1#pend }"; j="${j#* }"
  printf '%s' "$j" | jq -r '(.waitingOn // .waiting_on // "") | tostring | ascii_downcase' 2>/dev/null \
    | tr -cd 'a-z0-9_-'
}

# _triage_signal_team <turn> -> rc 0 when the next move is ours
#   (docs/BOARD-API-CONTRACT.md: `team`; `us` on the older boards).
_triage_signal_team() { case "${1:-}" in team|us) return 0 ;; esac; return 1; }

# _triage_signal_alert_dedupes <harness> -> rc 0 when bin/lane-alert.sh will
#   dedupe on --id (the alert state machine is on); the same subshell probe as
#   alert_dedupes_by_id in bin/migration-autopilot.sh.
_triage_signal_alert_dedupes() {
  [ -r "${1:-}/bin/lib/alert-state.sh" ] || return 1
  ( set +u; HARNESS="$1"; . "$1/bin/lib/alert-state.sh" >/dev/null 2>&1 || exit 1
    type alert_state_enabled >/dev/null 2>&1 || exit 1
    alert_state_enabled ) 2>/dev/null
}

# triage_signal_apps_ok <harness> <project> <key> -> rc 0 when our GitHub App
#   allowlist is non-empty. Empty: one log line per tick, one lane-alert call
#   per tick under a per-project per-day id (see NO APP ALLOWLIST above), rc 1
#   (the key dispatches; it is never settled).
triage_signal_apps_ok() {
  local h="${1:-}" p="${2:-}" apps lo=""
  command -v harness_self_apps_json >/dev/null 2>&1 || . "$_TSG_DIR/harness-self.sh" 2>/dev/null || true
  apps=$(harness_self_apps_json 2>/dev/null)
  [ -n "$apps" ] && [ "$apps" != '[]' ] && return 0
  if [ -z "$TRIAGE_SIGNAL_APPS_WARNED" ]; then
    TRIAGE_SIGNAL_APPS_WARNED=1
    mkdir -p "$h/logs" 2>/dev/null
    printf '%s [%s] triage shards: no-signal settle is OFF for this GitHub board this tick — HARNESS_SELF_APPS is empty, so our own App comments cannot be told from a client'"'"'s; every moved key dispatches (first: %s)\n' \
      "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$p" "${3:-?}" >> "$h/logs/$p.log" 2>/dev/null
    _triage_signal_alert_dedupes "$h" || lo=--log-only
    HARNESS="$h" "$h/bin/lane-alert.sh" ${lo:+"$lo"} --id "triage-signal-self-apps-$p-$(date -u +%Y%m%d)" --severity warn triage-signal \
      "[$p] HARNESS_SELF_APPS is empty, so the no-signal settle (BH-2542) never fires on this GitHub board and every bot-only change buys a triage session. Set it in env/global.env (catalog/lanes.d/_lib.harness-self.json). Safe, but the saving is silently zero until then." \
      >/dev/null 2>&1 || true
  fi
  return 1
}

# triage_signal_count <harness> <project> <key> — the settle's priced-$0 row
#   (see THE SAVING IS A ROW above). Best effort: a row that cannot be written
#   never turns a settle into a dispatch.
triage_signal_count() {
  local h="${1:-}" p="${2:-}" k="${3:-}" row
  command -v cost_append >/dev/null 2>&1 || return 0
  command -v cost_csv_field >/dev/null 2>&1 || return 0
  row="$(date -u '+%Y-%m-%dT%H:%M:%SZ'),$(hostname),$(cost_csv_field "$p"),triage-precheck,none,none,0,0,0,0,0,0,0,none,none,unknown,,settled,0,$(cost_csv_field "$k"),,,,settled:no-signal,run-triage"
  (
    # shellcheck disable=SC2034  # cost_append reads both
    HARNESS="$h"; COST="$h/logs/cost.csv"
    mkdir -p "$h/logs" "$h/locks" 2>/dev/null
    [ -f "$COST" ] || printf '%s\n' "${COST_ROW_HDR:-}" > "$COST" 2>/dev/null
    cost_append "$row"
  ) 2>/dev/null || true
  return 0
}

# triage_signal_settled <harness> <project> <key> <sfp> [turn]
#   rc 0 when the stamp's line 3 is this signal fingerprint, the turn has not
#   come back to the team since the stamp (line 4), and the epoch is still
#   younger than the fingerprint TTL; rc 1 otherwise.
triage_signal_settled() {
  local f old ts sig was ttl want="${4:-}" turn="${5:-}"
  [ -n "$want" ] || return 1
  f=$(triage_shard_fp_file "${1:-}" "${2:-}" "${3:-}")
  [ -r "$f" ] || return 1
  old=$(sed -n 1p "$f" 2>/dev/null); ts=$(sed -n 2p "$f" 2>/dev/null); sig=$(sed -n 3p "$f" 2>/dev/null)
  was=$(sed -n 4p "$f" 2>/dev/null)
  case "$old" in ''|*[!0-9a-f]*) return 1 ;; esac
  case "$ts"  in ''|*[!0-9]*)    return 1 ;; esac
  [ "$sig" = "$want" ] || return 1
  if _triage_signal_team "$turn" && [ "$was" != "$turn" ]; then return 1; fi
  ttl=$(triage_shard_fp_ttl "${1:-}")
  [ "$ttl" -gt 0 ] && [ $(( $(date +%s) - ts )) -lt "$ttl" ]
}

# _triage_signal_write <harness> <project> <key> <fp> <epoch> <sfp> [turn]
_triage_signal_write() {
  local f d
  [ -n "${4:-}" ] && [ -n "${5:-}" ] && [ -n "${6:-}" ] || return 1
  f=$(triage_shard_fp_file "$1" "$2" "$3"); d=$(dirname "$f")
  mkdir -p "$d" 2>/dev/null || return 1
  printf '%s\n%s\n%s\n%s\n' "$4" "$5" "$6" "${7:-}" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f"
}

# triage_signal_restamp <harness> <project> <key> <fp> <sfp> [turn]
#   A settle: the new world fingerprint, the OLD epoch (the last paid session),
#   the same signal fingerprint, the turn as it is now.
triage_signal_restamp() {
  local ts
  ts=$(sed -n 2p "$(triage_shard_fp_file "${1:-}" "${2:-}" "${3:-}")" 2>/dev/null)
  case "$ts" in ''|*[!0-9]*) return 1 ;; esac
  _triage_signal_write "${1:-}" "${2:-}" "${3:-}" "${4:-}" "$ts" "${5:-}" "${6:-}"
}

# triage_signal_put <harness> <project> <key> <fp> <sfp> [turn]
#   A dispatch: the 4-line stamp, epoch now. Written BEFORE the spawn, like
#   triage_shard_fp_put.
triage_signal_put() {
  _triage_signal_write "${1:-}" "${2:-}" "${3:-}" "${4:-}" "$(date +%s)" "${5:-}" "${6:-}"
}
