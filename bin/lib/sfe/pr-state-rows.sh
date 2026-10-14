# shellcheck shell=bash
# bin/lib/sfe/pr-state-rows.sh — BH-5000: the state-flip evidence for the
# `pr-state-rows` pause flag (order item 1 of #5000). Sourced by
# bin/state-flip-evidence.sh, never run. Uses the runner's sfe_* helpers.
#
#   flag    `bin/jobs-client.sh flag-active pr-state-rows` answers rc 0 AND its
#           source line says the pause_flags row is active=1. A box file with no
#           row, or a file newer than an active=0 row, is a FAIL: the row is
#           what the flip set, so the row is what has to read up.
#   tick    the newest pr_state_events row is at or after --since: the conductor
#           wrote a sighting after the flip. A non-2xx other than 404 is
#           "unreadable", never "no tick". The read passes not_state=queue
#           (BH-5667): a merge-queue stage row is written by the github
#           receiver, not the conductor, so it is not a conductor tick.
#   parity  every line of state/merge-conductor/pr-state.tsv whose `since`
#           (column 3, the mc_now epoch of its last transition) is at or after
#           --since has a pr_state row with the same number and state. Older
#           lines are counted, not compared: the flag shipped with no backfill
#           and mc_transition writes an event only on a state CHANGE, so a PR
#           that sat in one state across the flip never has a row. A since that
#           is not an epoch is compared (it cannot be shown to predate the flip).
#           A read that comes back at the 1000 limit is incomplete and FAILs; a
#           row with no tsv line is info only, since another box may hold it.
#           attempts.txt is counted, not compared, for the same no-backfill
#           reason.
[ -n "${SFE_H:-}" ] || return 1

SFE_PSR_LIMIT=1000

sfe_flag_pr_state_rows() {
  local err rc src
  err=$(HARNESS="$SFE_H" bash "$SFE_H/bin/jobs-client.sh" flag-active pr-state-rows 2>&1 >/dev/null); rc=$?
  src=$(grep -m1 '^flag-active pr-state-rows: source:' <<<"$err")
  sfe_info "flag-active pr-state-rows rc=$rc"
  [ -n "$src" ] && sfe_info "$src"
  if [ "$rc" != 0 ]; then
    sfe_fail flag "pr-state-rows reads off (flag-active rc=$rc)"
  elif [[ "$src" == *"source: pause_flags row (active=1"* ]]; then
    sfe_pass "pr-state-rows reads on from its pause_flags row"
  else
    sfe_fail flag "pr-state-rows is up on this box but not from an active row: ${src:-no source line}"
  fi
}

sfe_tick_pr_state_rows() {
  local since_epoch="$1" log="$SFE_H/logs/merge-conductor.log" rc at at_epoch
  if [ -e "$log" ]; then sfe_info "logs/merge-conductor.log last written $(date -u -r "$log" +%Y-%m-%dT%H:%M:%SZ)"
  else sfe_info "no logs/merge-conductor.log on this box"; fi
  sfe_get "/api/pr-state-events?limit=1&not_state=queue" "$SFE_TMP"; rc=$?
  case "$rc" in
    0) ;;
    2) sfe_fail tick "no pr_state_events row since $SFE_SINCE (http=$SFE_HTTP)"; return ;;
    *) sfe_fail tick "pr_state_events unreadable http=$SFE_HTTP"; return ;;
  esac
  if ! jq -e '.rows | type == "array"' "$SFE_TMP" >/dev/null 2>&1; then
    sfe_fail tick "pr_state_events unreadable http=$SFE_HTTP: the answer carried no rows array"; return
  fi
  at=$(jq -r '.rows[0].at // empty' "$SFE_TMP")
  [ -n "$at" ] || { sfe_fail tick "no pr_state_events row since $SFE_SINCE (the log is empty)"; return; }
  at_epoch=""
  [[ "$at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$ ]] \
    && at_epoch=$(date -u -d "$at" +%s 2>/dev/null)
  [ -n "$at_epoch" ] || { sfe_fail tick "pr_state_events unreadable: newest at '$at' is not a time"; return; }
  if [ "$at_epoch" -ge "$since_epoch" ]; then
    sfe_pass "newest pr_state_events row at $at, at or after the flip"
  else
    sfe_fail tick "no pr_state_events row since $SFE_SINCE (newest at $at)"
  fi
}

sfe_parity_pr_state_rows() {
  local since_epoch="$1" dir="$SFE_H/state/merge-conductor" before="$SFE_FAILS"
  local all entries n old repo q rc key state num row extra
  local -A have tsvnum
  if [ -f "$dir/attempts.txt" ]; then
    sfe_info "attempts.txt: $(grep -c . "$dir/attempts.txt") entries (no backfill; rows accrue from the flip, not compared)"
  fi
  if [ ! -f "$dir/pr-state.tsv" ]; then
    sfe_info "no pr-state.tsv on this box"
    sfe_pass "parity: 0 file entries"; return
  fi
  all=$(awk -F'\t' '$1 !~ /^#/ && $1 != "" { print $1 "\t" $2 "\t" $3 }' "$dir/pr-state.tsv")
  entries=$(printf '%s\n' "$all" | awk -F'\t' -v s="$since_epoch" 'NF && !($3 ~ /^[0-9]+$/ && $3 + 0 < s + 0) { print $1 "\t" $2 }')
  n=$(printf '%s' "$entries" | grep -c .)
  old=$(( $(printf '%s' "$all" | grep -c .) - n ))
  [ "$old" -gt 0 ] && sfe_info "$old pre-flip entries (since before $SFE_SINCE, no backfill, not compared)"
  if [ "$n" = 0 ]; then sfe_pass "parity: 0 post-flip file entries"; return; fi
  while IFS= read -r repo; do
    q=$(jq -nr --arg r "$repo" '$r | @uri')
    sfe_get "/api/pr-state?repo=$q&limit=$SFE_PSR_LIMIT" "$SFE_TMP"; rc=$?
    case "$rc" in
      0) if ! jq -e '.rows | type == "array"' "$SFE_TMP" >/dev/null 2>&1; then
           sfe_fail parity "$repo: pr_state unreadable http=$SFE_HTTP: no rows array"; continue
         fi
         if [ "$(jq '.rows | length' "$SFE_TMP")" -ge "$SFE_PSR_LIMIT" ]; then
           sfe_fail parity "$repo: incomplete read: rows = limit $SFE_PSR_LIMIT, so parity is not known"; continue
         fi ;;
      2) printf '{"rows":[]}' > "$SFE_TMP" ;;
      *) sfe_fail parity "$repo: pr_state unreadable http=$SFE_HTTP"; continue ;;
    esac
    have=(); tsvnum=()
    while IFS=$'\t' read -r num state; do have[$num]="$state"; done \
      < <(jq -r '.rows[] | "\(.number)\t\(.state)"' "$SFE_TMP")
    while IFS=$'\t' read -r key _; do tsvnum[${key##*#}]=1; done \
      < <(printf '%s\n' "$all" | awk -F'\t' -v r="$repo" '{ k = $1; sub(/#[^#]*$/, "", k); if (k == r) print }')
    extra=0
    for num in "${!have[@]}"; do [ -n "${tsvnum[$num]+x}" ] || extra=$((extra + 1)); done
    while IFS=$'\t' read -r key state; do
      num="${key##*#}"
      if [ -z "${have[$num]+x}" ]; then sfe_fail parity "$key no row (file=$state)"; continue; fi
      row="${have[$num]}"
      [ "$row" = "$state" ] || sfe_fail parity "$key file=$state row=$row"
    done < <(printf '%s\n' "$entries" | awk -F'\t' -v r="$repo" '{ k = $1; sub(/#[^#]*$/, "", k); if (k == r) print }')
    [ "$extra" -gt 0 ] && sfe_info "$repo: $extra row(s) with no line in this box's pr-state.tsv (another box may hold them)"
  done < <(printf '%s\n' "$entries" | awk -F'\t' '{ k = $1; sub(/#[^#]*$/, "", k); print k }' | sort -u)
  [ "$SFE_FAILS" = "$before" ] && sfe_pass "parity: $n post-flip file entries, each matches its pr_state row"
}

sfe_rollback_pr_state_rows() { echo "bin/jobs-client.sh flag-set pr-state-rows off"; }
