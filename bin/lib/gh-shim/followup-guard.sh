#!/bin/bash
# bin/lib/gh-shim/followup-guard.sh — no follow-up chains (BH-7123 wave B).
# Sourced by bin/gh-rest-shim step 6 beside the other handlers; never executed.
# Used by gshim_cmd_issue_create (issue-write.sh):
#
#   gshim_fu_guard                  rc 0 = the create may go on; rc 1 = refused,
#                                   ONE stderr line already printed
#   gshim_fu_prepend <bodyfile> <#parent>
#                                   prints the path of a body whose first line
#                                   is `Follow-up-of: <#parent>` (the input path
#                                   when it already is; a new temp file else)
#
# WHY. Follow-up tickets are filed by build and review AGENTS through this shim
# (`gh issue create`), and nothing read the ancestry before: a follow-up's build
# filed follow-ups of its own, each reviewed with the same prompt, forever. The
# rule (prompts, wave A): a ticket that is itself a follow-up files no
# follow-ups. This is the mechanical half. The running build's ticket is
# $HARNESS_TICKET (bin/lib/rb/gates.sh exports it for the iron-law guard); its
# body is read from the build's own $HARNESS/builds/<project>-<ticket>-*/
# ticket-meta.json (the newest), else ONE issue GET cached under that build dir
# (or state/gh-shim/ when no build dir is found), and only when the key is a
# GitHub issue number. A ticket is a follow-up when its first non-blank body
# line is `Follow-up-of: #<n>` or its body carries the QA marker
# `<!-- findings-followup-of: #<n> -->` (bin/lib/group-findings.sh).
# The settings row review.followup_chain=1 (seed 0; REVIEW_FOLLOWUP_CHAIN env
# for a test) turns the guard off. No ticket body reachable = no refusal: this
# is a guard on a known chain, not a gate on every create.

# gshim_fu_ticket_body <outfile> — the running build's ticket body; rc 1 none.
gshim_fu_ticket_body() {
  local out="$1" key="${HARNESS_TICKET:-}" proj="${HARNESS_LANE_PROJECT:-}" d best="" bt=0 t cache n body
  [ -n "$key" ] || return 1
  if [ -n "${GH_SHIM_TICKET_BODY_FILE:-}" ] && [ -r "$GH_SHIM_TICKET_BODY_FILE" ]; then
    cat "$GH_SHIM_TICKET_BODY_FILE" > "$out"; return 0
  fi
  for d in "$HARNESS/builds/"${proj:+"$proj-"}"$key-"*/ "$HARNESS/builds/"*"-$key-"*/; do
    [ -d "$d" ] || continue
    t=$(stat -c %Y "$d" 2>/dev/null || stat -f %m "$d" 2>/dev/null || echo 0)
    [ "$t" -ge "$bt" ] && { bt="$t"; best="${d%/}"; }
  done
  if [ -n "$best" ]; then
    if [ -s "$best/ticket-meta.json" ] && jq -r '.body // ""' "$best/ticket-meta.json" > "$out" 2>/dev/null; then return 0; fi
    if [ -s "$best/ticket-body.md" ]; then cat "$best/ticket-body.md" > "$out"; return 0; fi
    cache="$best/ticket-issue.json"
  else
    cache="$HARNESS/state/gh-shim/ticket-$(printf '%s' "${GSHIM_SLUG:-x}" | tr -c 'A-Za-z0-9._-' '_')-$key.json"
  fi
  if [ -s "$cache" ]; then jq -r '.body // ""' "$cache" > "$out" 2>/dev/null && return 0; fi
  # One issue GET, only for a key that IS a GitHub issue number (an in-app board
  # key like TK-233 names no issue of this repo), cached for the build's life.
  [[ "$key" =~ ^[0-9]+$ ]] || return 1
  [ -n "${GSHIM_SLUG:-}" ] || return 1
  body=$(gshim_api "repos/$GSHIM_SLUG/issues/$key") || return 1
  mkdir -p "$(dirname "$cache")" 2>/dev/null
  printf '%s' "$body" > "$cache" 2>/dev/null
  printf '%s' "$body" | jq -r '.body // ""' > "$out" 2>/dev/null
}

# gshim_fu_is_followup <bodyfile> — rc 0 when the body marks a follow-up.
gshim_fu_is_followup() {
  local first
  first=$(grep -m1 -v '^[[:space:]]*$' "$1" 2>/dev/null)
  [[ "$first" =~ ^[[:space:]]*Follow-up-of:[[:space:]]*# ]] && return 0
  grep -qF '<!-- findings-followup-of:' "$1" 2>/dev/null
}

# gshim_fu_chain_on — rc 0 when review.followup_chain is 1 (chains allowed).
gshim_fu_chain_on() {
  local v="${REVIEW_FOLLOWUP_CHAIN:-}"
  if [ -z "$v" ] && [ -r "$HARNESS/bin/jobs-client.sh" ]; then
    v=$( . "$HARNESS/bin/jobs-client.sh" 2>/dev/null || exit 1; setting_get review.followup_chain 2>/dev/null 7>&- 8>&- ) || v=""
  fi
  [ "$(printf '%s' "$v" | tr -d '[:space:]')" = 1 ]
}

gshim_fu_guard() {
  local bf
  [ -n "${HARNESS_TICKET:-}" ] || return 0
  bf=$(gshim_tmp) || return 0
  gshim_fu_ticket_body "$bf" || return 0
  gshim_fu_is_followup "$bf" || return 0
  gshim_fu_chain_on && return 0
  echo "gh issue create refused: ticket $HARNESS_TICKET is itself a follow-up (Follow-up-of / findings-followup-of), and a follow-up files no follow-ups (BH-7123). Leave the finding as a [NOTE] line in the review or the PR body; review.followup_chain=1 allows chains." >&2
  return 1
}

gshim_fu_prepend() { # gshim_fu_prepend <bodyfile-or-empty> <#parent>
  local bf="$1" parent="$2" out first=""
  if [ -n "$bf" ]; then
    first=$(grep -m1 -v '^[[:space:]]*$' "$bf" 2>/dev/null)
    if [[ "$first" =~ ^[[:space:]]*Follow-up-of:[[:space:]]*# ]]; then printf '%s\n' "$bf"; return 0; fi
  fi
  out=$(gshim_tmp) || return 1
  { printf 'Follow-up-of: %s\n' "$parent"
    if [ -n "$bf" ] && [ -s "$bf" ]; then printf '\n'; cat "$bf"; fi
  } > "$out"
  printf '%s\n' "$out"
}
