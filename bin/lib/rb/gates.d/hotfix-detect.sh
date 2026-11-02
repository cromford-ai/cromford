# shellcheck shell=bash
# Sourced by rb_gate_prelude in bin/lib/rb/gates.sh at its call site, never run (BH-8930: gates.d).
# >>> hotfix detect
# --- Is this the emergency ticket? (#368, hotfix lane 1/3) ---------------------
# BEFORE the queue hop, because the answer has to RIDE the job: a pool machine
# is two hops from the issue that carries the label, and asking GitHub again
# from there is a second chance to get a different answer than the watcher did.
# HOTFIX=1 in the environment wins (fly/builder-runner.sh exports it from the
# job file, and a hand-run can force it); otherwise the label is read once,
# here, from the issue. Any failure — no lib, no gh, a board project, a
# non-numeric key — is "not a hotfix", which is exactly today's behaviour.
HOTFIX="${HOTFIX:-}"
# shellcheck source=bin/lib/hotfix-lib.sh
[ -r "$HARNESS/bin/lib/hotfix-lib.sh" ] && . "$HARNESS/bin/lib/hotfix-lib.sh" 2>/dev/null
if command -v hotfix_lane_on >/dev/null 2>&1 && [ "$(hotfix_lane_on "$HARNESS")" = 0 ]; then
  HOTFIX=""
elif [ -z "$HOTFIX" ] && command -v hotfix_key_is >/dev/null 2>&1; then
  # THREE answers, not two. rc 2 is the lib saying the GitHub read itself
  # failed, which is NOT "ordinary ticket" — a dead token would answer "not
  # urgent" for every ticket in the fleet and nothing would say a word. So rc 2
  # buys exactly one retry with the token unset (gh falls back to its stored
  # auth), in a SUBSHELL because a shell function cannot be run through
  # `env -u` and the parent's token must survive. Still 2 -> say so and build
  # as plain: the check that is supposed to make an emergency faster must never
  # be the thing that stops it.
  hotfix_key_is "$HARNESS" "$PROJECT" "$KEY"; HF_RC=$?
  if [ "$HF_RC" = 2 ]; then
    echo "$(STAMP) [$PROJECT/$KEY] HOTFIX check could not be made (gh failed) - retrying once without GH_TOKEN" >> "$BUILD/pipeline.log"
    ( unset GH_TOKEN; hotfix_key_is "$HARNESS" "$PROJECT" "$KEY" ); HF_RC=$?
    [ "$HF_RC" = 2 ] && echo "$(STAMP) [$PROJECT/$KEY] hotfix check unavailable, building as plain" >> "$BUILD/pipeline.log"
  fi
  [ "$HF_RC" = 0 ] && HOTFIX=1
fi
if [ "$HOTFIX" = 1 ]; then
  echo "$(STAMP) [$PROJECT/$KEY] HOTFIX: this ticket carries the $(hotfix_label "$HARNESS") label — cap-exempt, and its PR will carry the label too" >> "$BUILD/pipeline.log"
  # Backstop for the triage-tick announcement (bin/hotfix-seen.sh): the marker
  # dedupes, so whichever of the two sees it first is the one that speaks.
  # QUEUED, not built: on a Fly lane this fires at the enqueue hop, minutes
  # before a machine picks the job up, so the text states the rung it has.
  hotfix_announce "$HARNESS" "$PROJECT" "$KEY" seen "$KEY queued for build" >/dev/null 2>&1 || true
fi
# <<< hotfix detect
