#!/bin/bash
# bin/lib/gh-shim/issue-write.sh — the `gh issue` WRITE verbs as single REST
# calls (#769 chunk 3). Sourced by bin/gh-rest-shim step 6; never executed.
#
# Same contract as its pr-write sibling: no arguments, read the parsed globals,
# call only the contract's gshim_* helpers, never gh / $GH_REAL / gh api. Body
# text goes through gshim_bodyfile + `gshim_input --rawfile` and never into argv.
#
# SHARED WALKER. The argv walker and body builder (gshim_prw_parse, gshim_prw_body_init,
# gshim_prw_str/raw/split/json, gshim_prw_build, gshim_prw_bodyfield, gshim_prw_has_body,
# gshim_prw_labels_post) ship in pr-write.sh, in THIS slice, and step 6 sources
# every bin/lib/gh-shim/*.sh before step 7 dispatches — so they are defined by
# the time any handler here runs. One walker, not three copies of one.

# ── issue create ─────────────────────────────────────────────────────────────
gshim_cmd_issue_create() {
  gshim_prw_parse "--title:v:title -t:v:title --body:v:body -b:v:body \
--body-file:v:bodyfile -F:v:bodyfile --label:m:label -l:m:label"
  gshim_slug ""
  local inp out bf
  # BH-7123 wave B (followup-guard.sh): a build whose own ticket is a follow-up
  # files no follow-ups — refused with one stderr line, nothing posted — and
  # every issue a build files names its parent on the first body line.
  if command -v gshim_fu_guard >/dev/null 2>&1; then gshim_fu_guard || exit 1; fi
  gshim_prw_body_init
  gshim_prw_str title "${GSHIM_PRW[title]:-}"
  bf=$(gshim_bodyfile "${GSHIM_PRW[body]:-}" "${GSHIM_PRW[bodyfile]:-}") || exit 1
  if [ -n "${HARNESS_TICKET:-}" ] && command -v gshim_fu_prepend >/dev/null 2>&1; then
    bf=$(gshim_fu_prepend "$bf" "#$HARNESS_TICKET") || exit 1
  fi
  if [ -n "$bf" ]; then gshim_prw_raw body "$bf"; else gshim_prw_str body ""; fi
  [ -n "${GSHIM_PRW[label]:-}" ] && gshim_prw_split labels "${GSHIM_PRW[label]}"
  inp=$(gshim_prw_build) || exit 1
  out=$(gshim_api -X POST "repos/$GSHIM_SLUG/issues" --input "$inp") || exit $?
  printf '%s\n' "$(printf '%s' "$out" | jq -r '.html_url // empty')"
  exit 0
}

# ── issue edit ───────────────────────────────────────────────────────────────
gshim_cmd_issue_edit() {
  gshim_prw_parse "--add-label:m:add --remove-label:m:remove \
--title:v:title -t:v:title --body:v:body -b:v:body --body-file:v:bodyfile -F:v:bodyfile"
  gshim_slug "${GSHIM_PRW[pos]:-}"
  local inp name
  if [ -n "${GSHIM_PRW[add]:-}" ]; then
    gshim_prw_labels_post "$GSHIM_SLUG" "$GSHIM_NUM" "${GSHIM_PRW[add]}" || exit $?
  fi
  if [ -n "${GSHIM_PRW[remove]:-}" ]; then
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      gshim_api -X DELETE "repos/$GSHIM_SLUG/issues/$GSHIM_NUM/labels/$name" >/dev/null || exit $?
    done < <(printf '%s\n' "${GSHIM_PRW[remove]}" | tr ',' '\n')
  fi
  if [ -n "${GSHIM_PRW[title]:-}" ] || gshim_prw_has_body; then
    gshim_prw_body_init
    [ -n "${GSHIM_PRW[title]:-}" ] && gshim_prw_str title "${GSHIM_PRW[title]}"
    gshim_prw_has_body && gshim_prw_bodyfield body
    inp=$(gshim_prw_build) || exit 1
    gshim_api -X PATCH "repos/$GSHIM_SLUG/issues/$GSHIM_NUM" --input "$inp" >/dev/null || exit $?
  fi
  exit 0
}

# ── issue comment ────────────────────────────────────────────────────────────
gshim_cmd_issue_comment() {
  gshim_prw_parse "--body:v:body -b:v:body --body-file:v:bodyfile -F:v:bodyfile"
  gshim_slug "${GSHIM_PRW[pos]:-}"
  local inp out
  gshim_prw_body_init
  gshim_prw_bodyfield body
  inp=$(gshim_prw_build) || exit 1
  out=$(gshim_api -X POST "repos/$GSHIM_SLUG/issues/$GSHIM_NUM/comments" --input "$inp") || exit $?
  printf '%s\n' "$(printf '%s' "$out" | jq -r '.html_url // empty')"
  exit 0
}

# ── issue close ──────────────────────────────────────────────────────────────
# Comment FIRST, same reasoning as pr close: a failed comment aborts with the
# issue still open rather than closing it with no word on why.
gshim_cmd_issue_close() {
  gshim_prw_parse "--comment:v:comment -c:v:comment --reason:v:reason"
  gshim_slug "${GSHIM_PRW[pos]:-}"
  local inp reason
  if [ -n "${GSHIM_PRW[comment]:-}" ]; then
    gshim_prw_body_init
    gshim_prw_str body "${GSHIM_PRW[comment]}"
    inp=$(gshim_prw_build) || exit 1
    gshim_api -X POST "repos/$GSHIM_SLUG/issues/$GSHIM_NUM/comments" --input "$inp" >/dev/null || exit $?
  fi
  gshim_prw_body_init
  gshim_prw_str state closed
  # gh documents `completed` and `"not planned"`; the REST field spells the
  # second one `not_planned`. Passing gh's spelling through verbatim is a 422
  # where real gh succeeds — accepting a flag and translating it wrong is worse
  # than not accepting it. Any other value is GitHub's to reject, not ours.
  if [ -n "${GSHIM_PRW[reason]:-}" ]; then
    reason="${GSHIM_PRW[reason]}"
    [ "$reason" = "not planned" ] && reason="not_planned"
    gshim_prw_str state_reason "$reason"
  fi
  inp=$(gshim_prw_build) || exit 1
  gshim_api -X PATCH "repos/$GSHIM_SLUG/issues/$GSHIM_NUM" --input "$inp" >/dev/null || exit $?
  exit 0
}
