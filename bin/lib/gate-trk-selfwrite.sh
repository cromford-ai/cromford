#!/bin/bash
# bin/lib/gate-trk-selfwrite.sh — self-write absorption for a Jira or Linear
# project (BH-8449), sourced by bin/triage-gate.sh. Defines one function and
# runs nothing at source time.
#
#   gate_trk_selfwrite <gate.json> <gate.pending>   prints ABSORB or RUN
#
# ABSORB only when every row that moved between the consumed fingerprint and
# the live one moved because WE commented on it. The steps, each failing to RUN:
#   1. The settings row tracker_<TRK_GATE>.<PROJECT>.self_actors names our
#      comment authors, comma-separated, as tracker_read prints them (Linear
#      displayName, else name, else botActor.name; Jira displayName). No row,
#      an empty value or a read error is RUN: absorption is off by default.
#   2. bin/gate-selfwrite.py in GATE_SELFWRITE_MODE=ids diffs the two files:
#      only commentCount and updatedAt may move, the count must go up, and at
#      most its MAX_CHANGED rows. It prints `ID <id> <old> <new>` per row.
#   3. tracker_read <id> for each row (the gate already loaded the context).
#      The newest <new - old> comments (the read is oldest first) must each
#      have an author in the list, compared exactly after a trim. A failed
#      read, or fewer comments than the delta, is RUN.
# Fail-open on purpose: a wrong ABSORB misses a client, a wrong RUN costs one
# session. TRK_GATE and PROJECT are the gate's own variables.

# _gts_self_actors — the row's value on stdout; rc 0 only for a non-empty row.
_gts_self_actors() {
  local d jc v
  d="$(dirname "${BASH_SOURCE[0]}")"
  jc="$d/../jobs-client.sh"; [ -r "$jc" ] || jc="${HARNESS:+$HARNESS/bin/jobs-client.sh}"
  [ -n "$jc" ] && [ -r "$jc" ] || return 1
  # In a subshell: the client sets shell options that must not reach the gate.
  # shellcheck source=/dev/null
  v=$( . "$jc" >/dev/null 2>&1 || exit 1
       JOBS_ALERT=0 setting_get "tracker_${TRK_GATE}.${PROJECT}.self_actors" 2>/dev/null ) || return 1
  [ -n "$(printf '%s' "$v" | tr -d ' ,\t\n')" ] || return 1
  printf '%s' "$v"
}

gate_trk_selfwrite() {
  local old="${1:-}" new="${2:-}" sa d py ids tag id o n doc
  case "${TRK_GATE:-}" in jira|linear) ;; *) echo RUN; return 0 ;; esac
  [ -r "$old" ] && [ -r "$new" ] || { echo RUN; return 0; }
  sa=$(_gts_self_actors) || { echo RUN; return 0; }
  d="$(dirname "${BASH_SOURCE[0]}")"
  py="$d/../gate-selfwrite.py"; [ -r "$py" ] || py="${HARNESS:+$HARNESS/bin/gate-selfwrite.py}"
  [ -n "$py" ] && [ -r "$py" ] || { echo RUN; return 0; }
  ids=$(GATE_SELFWRITE_MODE=ids GATE_OLD="$old" GATE_NEW="$new" python3 "$py" 2>/dev/null) || { echo RUN; return 0; }
  grep -q '^ID ' <<<"$ids" || { echo RUN; return 0; }
  while read -r tag id o n; do
    [ "$tag" = ID ] || { echo RUN; return 0; }
    [[ "$id" =~ ^[A-Za-z0-9._-]{1,64}$ ]] && [[ "$o" =~ ^[0-9]+$ ]] && [[ "$n" =~ ^[0-9]+$ ]] || { echo RUN; return 0; }
    doc=$(tracker_read "$id" 2>/dev/null) || { echo RUN; return 0; }
    printf '%s' "$doc" | jq -e --argjson k "$((n - o))" --arg sa "$sa" '
      def trim: gsub("^\\s+|\\s+$"; "");
      ($sa | split(",") | map(trim) | map(select(length > 0))) as $self
      | (.comments // []) as $c
      | $k > 0 and ($c | type) == "array" and ($c | length) >= $k
        and all($c[-$k:][]; ((.author // "") | tostring | trim) as $a | any($self[]; . == $a))' >/dev/null 2>&1 \
      || { echo RUN; return 0; }
  done <<<"$ids"
  echo ABSORB
}
