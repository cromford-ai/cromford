#!/bin/bash
# shellcheck shell=bash
# bin/lib/split-watchdog-act.sh — BH-1805 (BH-1793.0) contract, BH-1809
# (BH-1793.4) actions: the act lib for the split-watchdog lane (BH-1793).
# Carries out the one step sw_next_step chose.
#
# sw_act <project> <family> <route(pool|box)> <step> <child> <reason>
#   stdin: the same family TSV as sw_next_step (column order in
#     bin/lib/split-watchdog.sh).
#   stdout: one outcome word, acted | skipped | failed | stalled.
#   rc 1: worker unreachable (the lane counts it as `worker-unreachable`).
#   It never merges, pushes, rebases, writes board status or calls a model.
#
# Order: stall gate, family day cap, dedupe, act and record, stall.
#   1. stall gate  a `stalled` row for the family's children fingerprint
#                  (keys + pr_state + queue_status) -> skipped, no call. A
#                  child's state changing changes the fingerprint and lifts it.
#   2. day cap     sw_actions_today >= SPLIT_WATCHDOG_FAMILY_DAY_CAP (4) ->
#                  a `skip-cap-family` row, the UTC date in its reason, skipped.
#   3. dedupe      the (child, step, reason) row already `acted` -> no call; the
#                  row is re-recorded as `acted` so its repeat count grows.
#   4. act         enqueue/reenqueue: pool -> queue_put ... fly 0
#                  {"split_watchdog":<family>}; box -> rq_on gate, then
#                  queue_ready_put (not rq_put, which answers 0 on a failed
#                  write). queued -> acted; duplicate -> skip-duplicate
#                  skipped; anything else -> failed. owed-completion -> one warn
#                  lane-alert on the row's first record. close-parent ->
#                  bin/decompose-parent-close.sh <p> --cooled, acted only when
#                  it prints the family. handoff-rebase -> record only.
#   5. stall       an acted row answering `repeat <n>`, n >= SPLIT_WATCHDOG_STALL_K
#                  (3) -> a `stalled` row (recorded first), one warn lane-alert,
#                  stalled.
# Any ledger rc 1 -> rc 1 and no stdout: an action that cannot be recorded
# could repeat unbounded. The lane sources bin/jobs-client.sh (queue_put,
# queue_ready_put, sw_*) and bin/lib/ready-queue.sh (rq_on); a missing client
# is never `acted` (pool -> failed, box -> skip-no-fleet-path).

# _swa_row <child> — that child's TSV line from the family on stdin.
_swa_row() { awk -F'\t' -v k="${1:-}" '$1 == k { print; exit }'; }

# _swa_fp — `fp:` + 12 hex of sha1 over key:pr_state:queue_status per child.
_swa_fp() {
  local h
  h=$(awk -F'\t' 'NF { print $1 ":" $5 ":" $11 }' | sha1sum | cut -c1-12)
  printf 'fp:%s\n' "$h"
}

# _swa_int <value> <default>
_swa_int() { case "${1:-}" in ''|*[!0-9]*) echo "${2:-0}" ;; *) echo "$1" ;; esac; }

sw_act() {
  local p="${1:-}" fam="${2:-}" route="${3:-}" step="${4:-}" child="${5:-}" reason="${6:-}"
  local tsv crow fp cap k seen n ans tid out outcome h
  tsv=$(cat)
  # The root is SW_HARNESS, then HARNESS, then H (BH-2613); the lane's entry
  # point owns the /root/harness default. A step that needs a harness script
  # (owed-completion, close-parent, a stall alert) with no root is rc 1 before
  # anything is recorded: never a path built from an empty root.
  h="${SW_HARNESS:-${HARNESS:-${H:-}}}"
  case "$step" in
    enqueue|reenqueue)
      case "$route" in pool|box) ;; *) echo "sw_act: unknown route [$route]" >&2; echo skipped; return 0 ;; esac ;;
    owed-completion|close-parent|handoff-rebase) ;;
    *) echo "sw_act: unknown step [$step]" >&2; echo skipped; return 0 ;;
  esac
  cap=$(_swa_int "${SPLIT_WATCHDOG_FAMILY_DAY_CAP:-4}" 4)
  k=$(_swa_int "${SPLIT_WATCHDOG_STALL_K:-3}" 3)
  fp=$(printf '%s\n' "$tsv" | _swa_fp)
  crow=$(printf '%s\n' "$tsv" | _swa_row "$child")

  # 1. stall gate
  seen=$(sw_seen "$p" "$fam" stalled "$fp") || return 1
  [ "$seen" = stalled ] && { echo skipped; return 0; }

  # 2. family day cap
  n=$(sw_actions_today "$p" "$fam") || return 1
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$n" -ge "$cap" ]; then
    sw_record "$p" "$fam" "$child" skip-cap-family "day $(date -u +%F): $n acted, cap $cap" skipped >/dev/null || return 1
    echo skipped; return 0
  fi

  # 3. dedupe: the repeat is counted on the SAME acted row, never another outcome.
  seen=$(sw_seen "$p" "$child" "$step" "$reason") || return 1
  if [ "$seen" = acted ]; then
    ans=$(sw_record "$p" "$fam" "$child" "$step" "$reason" acted) || return 1
    _swa_stall "$p" "$fam" "$child" "$step" "$reason" "$fp" "$k" "$ans" || return 1
    return 0
  fi

  # 4. act, then record the real outcome
  tid=$(printf '%s' "$crow" | cut -f2)
  [ "$tid" = - ] && tid=""
  case "$step" in
    enqueue|reenqueue)
      if [ -z "$tid" ]; then
        sw_record "$p" "$fam" "$child" "$step" "$reason (no ticket id)" failed >/dev/null || return 1
        echo failed; return 0
      fi
      if [ "$route" = box ]; then
        if ! command -v rq_on >/dev/null 2>&1 || ! rq_on; then
          sw_record "$p" "$fam" "$child" skip-no-fleet-path "$reason" skipped >/dev/null || return 1
          echo skipped; return 0
        fi
        out=""
        command -v queue_ready_put >/dev/null 2>&1 \
          && out=$(queue_ready_put "$p" "$child" "$tid" "$child SPLIT-WATCHDOG $step [family #$fam] $reason" 2>/dev/null)
      else
        out=""
        command -v queue_put >/dev/null 2>&1 \
          && out=$(queue_put "$p" "$child" "$tid" fly 0 "$(jq -nc --arg f "$fam" '{split_watchdog:$f}')" 2>/dev/null)
      fi
      case "$out" in
        queued)    sw_record "$p" "$fam" "$child" "$step" "$reason" acted >/dev/null || return 1; echo acted ;;
        duplicate) sw_record "$p" "$fam" "$child" skip-duplicate "$reason" skipped >/dev/null || return 1; echo skipped ;;
        *)         sw_record "$p" "$fam" "$child" "$step" "$reason" failed >/dev/null || return 1; echo failed ;;
      esac ;;
    owed-completion)
      [ -n "$h" ] || return 1
      # Record FIRST: a crash can lose one warn, never repeat it.
      ans=$(sw_record "$p" "$fam" "$child" "$step" "$reason" acted) || return 1
      if [ "$ans" = first ]; then
        "$h/bin/lane-alert.sh" --severity warn --id "split-watchdog-owed-$p-$child" split-watchdog \
          "$child PR merged $(printf '%s' "$crow" | cut -f6), deploy serves $(printf '%s' "$crow" | cut -f9), ticket still in_progress. What-shipped comment owed." \
          >/dev/null 2>&1
        echo acted
      else
        _swa_stall "$p" "$fam" "$child" "$step" "$reason" "$fp" "$k" "$ans" || return 1
      fi ;;
    close-parent)
      [ -n "$h" ] || return 1
      out=$("$h/bin/decompose-parent-close.sh" "$p" --cooled 2>/dev/null)
      if grep -qxF -- "$fam" <<<"$out"; then
        sw_record "$p" "$fam" "$child" "$step" "$reason" acted >/dev/null || return 1; echo acted
      else
        sw_record "$p" "$fam" "$child" "$step" "decompose-parent-close declined" skipped >/dev/null || return 1; echo skipped
      fi ;;
    handoff-rebase)
      sw_record "$p" "$fam" "$child" "$step" "dirty @$(printf '%s' "$crow" | cut -f9); owner rebase-train" skipped >/dev/null || return 1
      echo skipped ;;
  esac
  return 0
}

# _swa_stall <p> <family> <child> <step> <reason> <fp> <K> <sw_record answer>
#   Prints stalled (after recording the fp row, then one alert) when the answer
#   is `repeat <n>` with n >= K, skipped otherwise. rc 1 when the record fails.
_swa_stall() {
  local p="$1" fam="$2" child="$3" step="$4" reason="$5" fp="$6" k="$7" ans="$8" n h
  n=$(_swa_int "${ans#repeat }" 0)
  case "$ans" in repeat\ *) ;; *) n=0 ;; esac
  if [ "$n" -lt "$k" ]; then echo skipped; return 0; fi
  h="${SW_HARNESS:-${HARNESS:-${H:-}}}"
  [ -n "$h" ] || return 1
  sw_record "$p" "$fam" "$fam" stalled "$fp" stalled >/dev/null || return 1
  "$h/bin/lane-alert.sh" --severity warn --id "split-watchdog-stalled-$p-$fam" split-watchdog \
    "$fam: $child $step repeated ${n}x without progress ($reason)" >/dev/null 2>&1
  echo stalled
}
