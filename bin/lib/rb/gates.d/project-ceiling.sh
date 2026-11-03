# shellcheck shell=bash
# Sourced by rb_gate_prelude in bin/lib/rb/gates.sh at its call site, never run (BH-8930: gates.d).
# >>> project daily ceiling
  # The project's daily ceiling (BH-7876, bin/lib/project-ceiling.sh): at 100%
  # of conf.cost-caps.<p>.daily_usd no new build starts until 00:00Z; a hotfix
  # still starts. ` budget-project-day ` makes pool_lane_failure requeue it
  # uncounted. An unreadable spend defers, as the BH-4489 check above does.
  command -v pc_launch_check >/dev/null 2>&1 || . "$HARNESS/bin/lib/project-ceiling.sh" 2>/dev/null || true
  if command -v pc_launch_check >/dev/null 2>&1; then
    PC_HF=0; [ "${HOTFIX:-}" = 1 ] && PC_HF=1
    BL_RC=0; pc_launch_check "$PROJECT" "$PC_HF" || BL_RC=$?
    if [ "$BL_RC" = 1 ]; then
      BL_LINE="BUILD_DEFERRED budget-project-day $PC_LINE — no new build for $PROJECT until 00:00Z; running builds finish; re-offered next tick"
      echo "$(STAMP) [$PROJECT/$KEY] budget launch gate: $BL_LINE" >> "$BUILD/pipeline.log"
      RESULT "$BL_LINE"
      exit 3
    elif [ "$BL_RC" = 2 ]; then
      BL_LINE="BUILD_DEFERRED budget-cap-unreadable launch $PC_REASON — the project's daily ceiling spend could not be read; re-offered next tick"
      echo "$(STAMP) [$PROJECT/$KEY] budget launch gate: $BL_LINE" >> "$BUILD/pipeline.log"
      RESULT "$BL_LINE"
      exit 3
    elif [ -n "${PC_NOTE:-}" ]; then
      echo "$(STAMP) [$PROJECT/$KEY] budget launch gate: HOTFIX admitted over the daily ceiling: $PC_NOTE" >> "$BUILD/pipeline.log"
    fi
  fi
# <<< project daily ceiling
