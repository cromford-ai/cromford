# shellcheck shell=bash
# Sourced by rb_gate_prelude in bin/lib/rb/gates.sh at its call site, never run (BH-8930: gates.d).
# >>> onboard canary gate
# BH-9442: a repo onboarded by bin/load-project.sh or the onboarding runner is
# HELD (settings row onboard.<p>.canary_gate=held, written by
# bin/onboard-canary.sh --hold) until a no-op canary PR goes green in the repo's
# own CI. project-12, project-13 and project-14 built 16 PRs into a CI that was red on
# every PR. While held, no ticket of the project builds: BUILD_DEFERRED, and
# the next tick re-offers it. A green canary writes `released`; an operator
# releases a repo with no CI by the row onboard.<p>.canary_override=<reason>
# (bin/onboard-canary.sh --override). No row admits, so every project loaded
# before this gate is unchanged. An unreadable gate row (rc 1), or no jobs
# client on this box (rc 127), ADMITS with one pipeline line: this gate runs for
# every build of every project, so a deferral here would turn one jobs-worker
# outage into a fleet-wide build stop. A readable `held` row still defers. A
# hold is never silent: past ONBOARD_CANARY_HELD_ALERT_HOURS the hub lane
# alerts (onboard-canary:<p>:held, bin/onboard-canary.sh). Placed after
# the dispatch mode gate and before the budget gate and the slots, so a held
# launch takes no claim, no slot and no queue row. Not asked, like the dispatch
# mode gate: a resume and a pool machine (admitted at enqueue).
if [ "${BUILDER_EXEC:-}" != 1 ] && [ -z "${RESUME_BUILD:-}" ]; then
  OC_JC="$HARNESS/bin/jobs-client.sh"
  OC_RC=0
  if [ -x "$OC_JC" ]; then
    OC_GATE=$("$OC_JC" setting-get "onboard.$PROJECT.canary_gate" 2>/dev/null) || OC_RC=$?
  else
    OC_GATE=""; OC_RC=127
  fi
  OC_GATE=$(printf '%s' "$OC_GATE" | tr -d '[:space:]')
  if [ "$OC_RC" = 0 ] && [ "$OC_GATE" = held ]; then
    OC_OVR=$("$OC_JC" setting-get "onboard.$PROJECT.canary_override" 2>/dev/null) || OC_OVR=""
    OC_OVR=$(printf '%s' "$OC_OVR" | tr '\n' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    if [ -n "$OC_OVR" ]; then
      echo "$(STAMP) [$PROJECT/$KEY] onboard-canary: held, admitted by the override row onboard.$PROJECT.canary_override: $OC_OVR" >> "$BUILD/pipeline.log"
    else
      OC_ROW=$("$OC_JC" setting-get "onboard.$PROJECT.canary" 2>/dev/null) || OC_ROW=""
      OC_STATE=$(jq -r '.state // "-"' <<<"$OC_ROW" 2>/dev/null) || OC_STATE="-"
      OC_SHA=$(jq -r '(.sha // "-") | .[0:12]' <<<"$OC_ROW" 2>/dev/null) || OC_SHA="-"
      OC_LINE="onboard-canary held: ${OC_STATE:--} ${OC_SHA:--}"
      echo "$(STAMP) [$PROJECT/$KEY] $OC_LINE; $KEY waits until the canary PR is green (bin/onboard-canary.sh --status $PROJECT)" >> "$BUILD/pipeline.log"
      mkdir -p "$HARNESS/logs" 2>/dev/null
      echo "$(STAMP) [$PROJECT/$KEY] $OC_LINE" >> "$HARNESS/logs/${PROJECT}.log" 2>/dev/null || true
      RESULT "BUILD_DEFERRED $OC_LINE"
      exit 3
    fi
  elif [ "$OC_RC" != 0 ] && [ "$OC_RC" != 2 ]; then
    echo "$(STAMP) [$PROJECT/$KEY] onboard-canary unverifiable: gate row unreadable (rc $OC_RC); admitted" >> "$BUILD/pipeline.log"
  fi
fi
# <<< onboard canary gate
