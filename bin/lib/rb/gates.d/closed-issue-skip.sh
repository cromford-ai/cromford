# shellcheck shell=bash
# Sourced by rb_gate_prelude in bin/lib/rb/gates.sh at its call site, never run (BH-8930: gates.d).
# >>> closed issue skip
# --- Is this ticket already shipped? (BH-637 §3a) ------------------------------
# `ai-build` is the handoff label and nothing took it off when a merge closed the
# issue, so the label outlived the work and kept offering it — each re-offer a
# full pool build spent rebuilding shipped work. The label is also not enough to
# fix on its own: humans close issues by hand, and that close strips nothing. So
# the state is read LIVE, here.
#
# HERE, because this script is the only mechanical enqueue point in the fleet —
# the triage session, bin/up10-lane.sh, bin/unblocked-children.sh, the
# READY-QUEUE tick, the blocked-resolver rebuild and fly/builder-runner.sh all
# funnel through it — and ABOVE the enqueue gate below, so a refused build never
# writes a queue row, never takes a build slot and never takes the per-key lock.
#
# BUILD_REFUSED, not BUILD_DEFERRED: a deferral is re-offered by the pool up to
# DEFER_MAX times and reads as `parked` in the ledger. A closed issue is not
# "not now", it is "never", and BUILD_REFUSED is the terminal the sweep SOP
# already owns — one ALERTS line naming the ticket and the reason, which is
# exactly the "the label is lying on #n" signal an operator wants.
#
# FAIL-OPEN: no lib, a board project, a non-numeric key or a gh that failed all
# fall through and build exactly as today. A dead token must not refuse every
# build in the fleet.
# shellcheck source=bin/lib/issue-state-lib.sh
if [ -r "$(dirname "$0")/lib/issue-state-lib.sh" ]; then . "$(dirname "$0")/lib/issue-state-lib.sh" 2>/dev/null
elif [ -r "$HARNESS/bin/lib/issue-state-lib.sh" ]; then . "$HARNESS/bin/lib/issue-state-lib.sh" 2>/dev/null
fi
if command -v issue_is_closed >/dev/null 2>&1 \
   && [ "$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null)" = "-" ]; then
  CI_N=$(printf '%s' "$KEY" | sed -nE 's/^[A-Za-z]+-([0-9]+)$/\1/p')
  CI_REPO="${GH_ISSUES_REPO:-$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null || true)}"
  if [ -n "$CI_N" ] && [ -n "$CI_REPO" ]; then
    # BH-1735: the read keeps the issue JSON in the build dir, and the created-at
    # stamp below is served from it — one GET of this issue per enqueue, not two.
    CI_MEMO=""; command -v issue_memo_file >/dev/null 2>&1 && CI_MEMO=$(issue_memo_file "$BUILD" "$CI_REPO" "$CI_N")
    issue_is_closed "$CI_REPO" "$CI_N" "$HARNESS" "$CI_MEMO"; CI_RC=$?
    if [ "$CI_RC" = 0 ]; then
      CI_LINE="SKIP_CLOSED #$CI_N — issue is CLOSED on $CI_REPO; the ai-build label is stale, nothing enqueued"
      echo "$(STAMP) [$PROJECT/$KEY] $CI_LINE" >> "$BUILD/pipeline.log"
      mkdir -p "$HARNESS/logs" 2>/dev/null
      echo "$(STAMP) [$PROJECT/$KEY] $CI_LINE" >> "$HARNESS/logs/${PROJECT}.log" 2>/dev/null || true
      RESULT "BUILD_REFUSED SKIP_CLOSED #$CI_N — issue is CLOSED on $CI_REPO; nothing enqueued, nothing built"
      exit 3
    elif [ "$CI_RC" = 2 ]; then
      echo "$(STAMP) [$PROJECT/$KEY] closed-issue check unavailable (gh failed) — building as today" >> "$BUILD/pipeline.log"
    fi
  fi
fi
# <<< closed issue skip
