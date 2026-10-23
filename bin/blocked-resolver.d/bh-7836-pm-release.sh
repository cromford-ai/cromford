# bin/blocked-resolver.d/bh-7836-pm-release.sh — BH-7836: the rebuild-fresh
# rung releases the malformed-plan hold before it buys a rebuild.
#
# WHY. bin/lib/rb/plan.sh holds a ticket after two malformed plans: every later
# launch reads state/plan-malformed.txt and the plan_malformed ledger row, and
# `held` or `skipped` means `PLAN skipped … no plan session spent`, exit 4.
# PM_TERMINAL hands that ticket to this lane "for a fresh build against current
# main", but the rebuild this lane bought reached the same gate and was skipped.
# The lane read PLAN_MALFORMED again and spent the next rung. TK-1163 spent three
# rungs this way and went ABANDONED.
#
# THE FIX writes the hold's documented way out, a `released` row (last row wins,
# PM_HOLD_STATUS), to the file AND the ledger, before the PR close and the
# enqueue. A later malformed plan still holds the ticket again (PM_TERMINAL sees
# the earlier rows), so the hold still bounds plan sessions.
# BR_OPT_OFF=bh-7836-pm-release does not source this file, and the call site in
# br_rebuild_fresh then does nothing.

# br_pm_release <p> <rkey> <reason> <tkey>
#   rc 0  no hold (nothing written, no line), or the hold is released in both
#         halves (one file row, one ledger put, one say line).
#   rc 1  the release could not be recorded (file append or ledger put failed).
#         One say line. The caller defers the rung: nothing closed, nothing
#         enqueued, no counter spent.
# The ticket is held when EITHER half says `held` or `skipped`: a box reads its
# file first, a Fly machine with an empty state dir reads the ledger, and with
# the BH-1036 flag up the ledger row comes first. Both must answer `released`.
br_pm_release() {
  local p="$1" rkey="$2" reason="$3" tkey="$4" f st_file="" st_led="" led was=""
  case "$tkey" in ''|-) return 0 ;; esac
  f="$H/state/plan-malformed.txt"
  [ -r "$f" ] && st_file=$(awk -v p="$p" -v k="$tkey" '$1==p && $2==k {s=$3} END{print s}' "$f" 2>/dev/null)
  if command -v job_ledger_get >/dev/null 2>&1 && led=$(job_ledger_get plan_malformed "$p $tkey" 2>/dev/null); then
    st_led=$(head -1 <<<"$led" | awk '{print $1}')
  fi
  case "$st_file" in held|skipped) was=$st_file ;; esac
  [ -n "$was" ] || case "$st_led" in held|skipped) was=$st_led ;; esac
  [ -n "$was" ] || return 0
  if ! { mkdir -p "$H/state" 2>/dev/null \
         && printf '%s %s released %s blocked-resolver:%s\n' "$p" "$tkey" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$rkey" >> "$f"; } 2>/dev/null; then
    say "$p/$rkey [$reason]: the malformed-plan hold on $tkey (was $was) could not be released — state/plan-malformed.txt is not writable; rebuild deferred, nothing closed, no counter spent"
    return 1
  fi
  if command -v job_ledger_put >/dev/null 2>&1 \
     && ! job_ledger_put plan_malformed "$p $tkey" released \
          "released by blocked-resolver before a rebuild-fresh rung ($reason)" >/dev/null 2>&1; then
    say "$p/$rkey [$reason]: the malformed-plan hold on $tkey (was $was) — release NOT recorded in the ledger; rebuild deferred, nothing closed, no counter spent"
    return 1
  fi
  say "$p/$rkey [$reason]: released the malformed-plan hold on $tkey (was $was) so the fresh rebuild gets a plan session"
  return 0
}
