# shellcheck shell=bash
# Sourced by rb_gate_claim_and_workspace in bin/lib/rb/gates.sh at its call site, never run (BH-8930: gates.d).
# >>> issue created-at stamp
# The acceptance clock (docs/DORA.md launch_lead_time) starts when the issue was
# FILED, not when this fleet got round to claiming it — lead_time already
# measures the second half. GitHub-Issues projects only; an in-app board has no
# issue to ask about, so it is not asked. FAIL-OPEN everywhere: a read that
# fails, is refused, or answers something that is not a whole-second Z stamp
# leaves a null column and one `unknown` log line, never a stopped build.
ISSUE_CREATED_AT=""
if [ "$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null)" = "-" ] \
   && [[ "$TICKET" =~ ^[0-9]+$ ]] && [ -n "${GH_AUTH_SLUG:-}" ]; then
  # ONE READ PER ENQUEUE (BH-1735). The closed-issue skip above already read
  # this issue and kept the JSON (issue_memo_file); created_at never changes, so
  # the stamp is served from that read. The memo only ever holds THIS enqueue's
  # successful read of THIS (repo, issue), so when the skip was switched off,
  # failed, or read another repo there is no file and the read below is made.
  ICA_M=""; command -v issue_memo_file >/dev/null 2>&1 && ICA_M=$(issue_memo_file "$BUILD" "$GH_AUTH_SLUG" "$TICKET")
  if [ -n "$ICA_M" ] && [ -s "$ICA_M" ] && jq -e 'type == "object"' "$ICA_M" >/dev/null 2>&1; then
    ISSUE_CREATED_AT=$(jq -r '.created_at // empty' "$ICA_M" 2>/dev/null)
    echo "$(STAMP) [$PROJECT/$KEY] issue created-at served from the closed-issue read (no second GET)" >> "$BUILD/pipeline.log"
  else
    # Every other gh spend in this file re-mints the minute-0 App token first. This
    # read fails open, so an expired token would not raise anything — it would just
    # record `unknown` for every build on every pool box, which is the one way a
    # fail-open metric read can lie without anybody noticing.
    GH_LIVE
    # REST (bin/lib/gh-rest.sh), through a temp file so the status stays in this shell.
    ICA_RC=0; ICA_T=$(mktemp "${TMPDIR:-/tmp}/issue-created.XXXXXX") || ICA_RC=75
    [ "$ICA_RC" = 0 ] && { gh_rest GET "repos/$GH_AUTH_SLUG/issues/$TICKET" > "$ICA_T" || ICA_RC=$?; }
    [ "$ICA_RC" = 0 ] && ISSUE_CREATED_AT=$(jq -r '.created_at // empty' "$ICA_T" 2>/dev/null)
    rm -f "${ICA_T:-}"
  fi
  [ -z "$ICA_M" ] || rm -f "$ICA_M"
  [[ "$ISSUE_CREATED_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || ISSUE_CREATED_AT=""
fi
# Written BEFORE the claim goes out, and from the same variable the claim sends,
# so a build that dies inside job_open still leaves the evidence and the log can
# never name a stamp the ledger was not offered.
echo "$(STAMP) [$PROJECT/$KEY] ISSUE-CREATED-AT ${ISSUE_CREATED_AT:-unknown}" >> "$BUILD/pipeline.log"
# <<< issue created-at stamp
