# shellcheck shell=bash
# bin/blocked-resolver.d/bh-9282-decline-next.sh — BH-9282: a declined
# supersede on a red reviewed PR gets a next action, not a silent skip.
#
# WHY. project-6 #3661 (2026-11-08): a lead MERGE-WITH-NOTES verdict, CI red,
# fix=1/1 spent on an older head. Rung rebuild-fresh was declined on the
# verdict (reviewed work is the lead's to throw away), and the BH-9029 decline
# mark then skipped the row on every tick. Nothing that skip read changes on
# its own, so the PR waited for ever. #3608 was the same with a BLOCK verdict
# (row 5317). The BH-7660 per-head reset (br_head_reset) runs only inside
# br_rebuild_fresh AFTER the supersede guard, so a verdict decline never reset
# the fix-round budget of the old head for the new one.
#
# THE DECISION (bdn_next, asked by bdm_skip once the mark is confirmed and
# before its SKIP line). rc 0 = run the row this tick with a fix round; rc 1 =
# the old skip. A round is offered only when ALL of these are true:
#   * br_action of the reason is `ladder`;
#   * mc_ci_state answers `red` on the PR head (green, pending, none and an
#     unreadable read keep the skip: unreadable is not red);
#   * the fix rounds counted on THIS head are below br_fix_cap. When the last
#     counted rung ran on another head (.rung_head for this url), the
#     per-head budget is reset first with the BH-7660 br_head_reset. No reset
#     when the record names no rung head (a legacy record is not a new head),
#     when the ladder was already reset to this head (.ladder_reset.to), or
#     when this head is the one this lane's own fix round pushed (.fix_head):
#     that last rule stops one paid round per push on a branch the rounds
#     cannot make green.
# The row then runs; bdn_ladder (one line in br_one) turns the ladder's
# mechanical / regen / rebuild-fresh answer into fix-round for that row, in
# front of br_rung_hold_gate, so a held ticket still spends nothing.
#
# THE BRIEF (bdn_brief, one line in br_fix_round). When .decline_next names
# this url and head with a BLOCK or CHANGES_REQUESTED verdict and the findings
# carry no lead block yet, the newest trusted `<!-- lead-review:` review on the
# head (any review state) is prepended, framed with $BR_LEAD_HDR, so the
# BH-2200 lead gate applies to the round. .decline_next rides to the owning
# box in the record copy br_fix_remote hands it.
#
# THE PERSON (bdn_human). The budget on this head is spent and CI is still red
# BR_DECLINE_HUMAN_HOURS after bdn_next first saw the head: one needs-human
# comment per (ticket, head), marker first (cm_put + .decline_next.human_head),
# then the post. A GitHub-issues lane (board prefix "-") posts on the ticket's
# issue; no ticket key posts on the PR; a client product board gets one
# NEEDS_HUMAN lane alert and no board comment (an internal PR-repair note on a
# client's board cannot be taken back). A post that fails is one lane alert.
#
# RECORD FIELD .decline_next = {url, head, since, vrow, vword, offered_at,
# wait_said, human_head, human_at}. A new url or head replaces it (new clock).
# The decline mark (.decl_mark) is not changed here: it stays as the record of
# the decline, and its skip holds only while bdn_next has no action.
#
# Call sites, one line each:
#   bdm_skip (bh-9029 fragment), before the SKIP line -> bdn_next
#   br_one, the ladder block                          -> bdn_ladder
#   br_fix_round, after the dequeue brief             -> bdn_brief
# BR_OPT_OFF=bh-9282-decline-next does not source this file; every call site
# then does what it did before.

# bdn_next <src> <p> <rkey> <ck> <reason> <url> <head> <vrow> <vword> <record-json>
#   rc 0 a fix round is offered this tick (BR_DECLINE_NEXT_URL is set);
#   rc 1 the old skip.
bdn_next() {
  local src="$1" p="$2" rkey="$3" ck="$4" reason="$5" url="$6" head="$7" vrow="$8" vword="$9" st="${10:-}"
  local slug num ci f du dh rh lt fh reset=0 n cap h12
  BR_DECLINE_NEXT_URL=""
  [ "$(br_action "$reason")" = ladder ] || return 1
  command -v mc_ci_state >/dev/null 2>&1 || return 1
  br_is_sha "$head" || return 1
  slug=$(br_slug_of_url "$url") || return 1
  num=$(mc_num_of_url "$url"); [ -n "$num" ] || return 1
  ci=$(mc_ci_state "$slug" "$head" 2>/dev/null)
  [ "$ci" = red ] || return 1
  h12="${head:0:12}"
  f=$(jq -r --arg u "$url" '
      def s(x): (x // "") | tostring;
      [ s(.decline_next.url), s(.decline_next.head),
        (if .rung_pr == $u then s(.rung_head) else "" end),
        (if (.ladder_reset.url // "") == $u then s(.ladder_reset.to) else "" end),
        (if .fix_pr == $u then s(.fix_head) else "" end) ]
      | map(if . == "" then "-" else . end) | join("\t")' <<<"$st" 2>/dev/null) || return 1
  IFS=$'\t' read -r du dh rh lt fh <<<"$f"
  rh=$(printf '%s' "$rh" | tr 'A-F' 'a-f'); fh=$(printf '%s' "$fh" | tr 'A-F' 'a-f')
  if br_is_sha "$rh" && [ "$rh" != "$head" ] && [ "$lt" != "$head" ] && [ "$fh" != "$head" ]; then reset=1; fi
  if [ "${OBSERVE:-0}" = 1 ]; then
    n=$(br_num "$st" fixrounds); cap=$(br_fix_cap "$st" "$reason" "$p")
    [ "$reset" = 1 ] && n=0
    if [ "$n" -lt "$cap" ] 2>/dev/null; then
      say "$p/$rkey [$reason]: DECLINE NEXT — WOULD $([ "$reset" = 1 ] && echo "reset the per-head budget (last rung on ${rh:0:12}) and ")offer fix round $((n + 1)) of $cap on $h12 ($vword row $vrow, CI red) — observe mode, nothing written"
    else
      say "$p/$rkey [$reason]: DECLINE NEXT — WOULD wait for the needs-human window on $h12 ($vword row $vrow, CI red, fix rounds $n of $cap spent) — observe mode, nothing written"
    fi
    return 1
  fi
  # A new url or head starts a new clock.
  if [ "$du" != "$url" ] || [ "$dh" != "$head" ]; then
    br_sup_write "$p" "$ck" '.decline_next = {url:$u, head:$h, since:($s|tonumber), vrow:$vr, vword:$vw}' \
      --arg u "$url" --arg h "$head" --arg s "$(date -u +%s)" --arg vr "$vrow" --arg vw "$vword" \
      || { say "$p/$rkey [$reason]: DECLINE NEXT — the record could not be written — the skip stands, retried next tick"; return 1; }
  fi
  if [ "$reset" = 1 ]; then
    br_head_reset "$p" "$ck" "$reason" "$url" "$rh" "$head"
    [ "$?" = 5 ] || return 1
  fi
  st=$(br_load "$p" "$ck")
  n=$(br_cap_rows "$p" "$rkey" "$reason" "$(br_num "$st" fixrounds)" "$url" fixround fixrounds "$st")
  cap=$(br_fix_cap "$st" "$reason" "$p" 2>/dev/null)
  case "$cap" in ''|*[!0-9]*) cap="${MAX_FIXROUNDS:-${BR_MAX_FIXROUNDS:-1}}" ;; esac
  case "$n" in ''|*[!0-9]*) n="$cap" ;; esac
  if [ "$n" -lt "$cap" ]; then
    br_sup_write "$p" "$ck" '.decline_next.offered_at = $t' \
      || say "$p/$rkey [$reason]: DECLINE NEXT — the offer stamp was not written (the round still runs)"
    BR_DECLINE_NEXT_URL="$url"
    say "$p/$rkey [$reason]: DECLINE NEXT — SUPERSEDE DECLINED (verdict) stands ($vword row $vrow on $h12) and CI is red there: fix round $((n + 1)) of $cap on this head"
    return 0
  fi
  bdn_human "$p" "$rkey" "$ck" "$reason" "$url" "$slug" "$num" "$head" "$vrow" "$vword"
  return 1
}

# bdn_ladder <url> <action> — rc 0 when bdn_next admitted a fix round for this
#   url this tick and the ladder answered mechanical, regen or rebuild-fresh
#   (the caller then runs fix-round); rc 1 otherwise. Clears the admission.
bdn_ladder() {
  local url="$1" action="$2" admitted="${BR_DECLINE_NEXT_URL:-}"
  BR_DECLINE_NEXT_URL=""
  [ -n "$admitted" ] && [ "$admitted" = "$url" ] || return 1
  case "$action" in mechanical|regen|rebuild-fresh) return 0 ;; esac
  return 1
}

# bdn_brief <url> <head> <record-json> <findings> — prints the findings to use.
#   rc 0 (the findings, maybe with the lead's review prepended); rc 75 the
#   reviews list could not be read (nothing printed: no rung is spent).
bdn_brief() {
  local url="$1" head="$2" st="$3" findings="$4" f du dh vr vw slug num rows login cid b64 body pick=""
  f=$(jq -r '[(.decline_next.url // ""), (.decline_next.head // ""), (.decline_next.vrow // "" | tostring), (.decline_next.vword // "")]
             | map(if . == "" then "-" else . end) | join("\t")' <<<"$st" 2>/dev/null) || f=""
  IFS=$'\t' read -r du dh vr vw <<<"$f"
  if [ "${du:-}" != "$url" ] || [ "${dh:-}" != "$head" ] || [ -z "$head" ]; then printf '%s' "$findings"; return 0; fi
  case "${vw:-}" in BLOCK|CHANGES_REQUESTED) ;; *) printf '%s' "$findings"; return 0 ;; esac
  case "$findings" in *"${BR_LEAD_HDR:-LEAD FINDINGS}"*) printf '%s' "$findings"; return 0 ;; esac
  [ -n "${BR_LEAD_HDR:-}" ] || { printf '%s' "$findings"; return 0; }
  slug=$(br_slug_of_url "$url") || { printf '%s' "$findings"; return 0; }
  num=$(mc_num_of_url "$url"); [ -n "$num" ] || { printf '%s' "$findings"; return 0; }
  rows=$(br_review_rows "$slug" "$num") || return 75
  # Oldest first (GitHub's order): the last match is the newest.
  while IFS=$'\t' read -r login cid b64; do
    [ "${cid:-}" = "$head" ] && [ -n "${b64:-}" ] || continue
    command -v harness_verdict_author_match >/dev/null 2>&1 && harness_verdict_author_match "$login" || continue
    body=$(printf '%s' "$b64" | base64 -d 2>/dev/null) || continue
    case "$body" in *'<!-- lead-review:'*) ;; *) continue ;; esac
    case "$body" in *'[BLOCK needs-human]'*) continue ;; esac
    pick="$body"
  done < <(jq -r '.[]? | select((.s // "") != "DISMISSED") | [.l, .c, (.b | @base64)] | @tsv' <<<"$rows" 2>/dev/null)
  if [ -z "$pick" ]; then
    say "$url: DECLINE NEXT — no trusted lead-review on ${head:0:12} to brief the $vw verdict row $vr; the round runs on the posted findings"
    printf '%s' "$findings"; return 0
  fi
  br_findings_join "$(printf '%s\n(%s verdict row %s on %s)\n\n%s' "$BR_LEAD_HDR" "$vw" "$vr" "${head:0:12}" "$pick")" "$findings"
}

# bdn_human <p> <rkey> <ck> <reason> <url> <slug> <num> <head> <vrow> <vword>
#   The once-per-head needs-human post, when the window has passed.
bdn_human() {
  local p="$1" rkey="$2" ck="$3" reason="$4" url="$5" slug="$6" num="$7" head="$8" vrow="$9" vword="${10}"
  local hrs st since now left said hh key mark mrc=0 last body prefix tk issue rc h12="${8:0:12}"
  # Registry knob lane.blocked-resolver.BR_DECLINE_HUMAN_HOURS
  # (catalog/lanes.d/blocked-resolver.knobs.d/BR_DECLINE_HUMAN_HOURS.json);
  # 12 is its documented fallback.
  hrs="${BR_DECLINE_HUMAN_HOURS:-12}"
  case "$hrs" in
    ''|*[!0-9]*|0) say "$p/$rkey [$reason]: BR_DECLINE_HUMAN_HOURS is '$hrs', not a number — the fallback 12 is used"; hrs=12 ;;
  esac
  hrs=$((10#$hrs))
  st=$(br_load "$p" "$ck")
  IFS=$'\t' read -r since said hh < <(jq -r '[(.decline_next.since // "" | tostring), (.decline_next.wait_said // "" | tostring), (.decline_next.human_head // "")]
      | map(if . == "" then "-" else . end) | join("\t")' <<<"$st" 2>/dev/null)
  case "${since:-}" in ''|*[!0-9]*) say "$p/$rkey [$reason]: DECLINE NEXT — the clock on $h12 does not parse ('${since:-}') — no needs-human comment this tick"; return 0 ;; esac
  now=$(date -u +%s)
  if [ $((now - since)) -lt $((hrs * 3600)) ]; then
    if [ "${said:-}" != "$head" ]; then
      left=$(( (hrs * 3600 - (now - since) + 3599) / 3600 ))
      say "$p/$rkey [$reason]: DECLINE NEXT — the fix rounds on $h12 are spent and CI is red; the needs-human comment waits ${left}h more (BR_DECLINE_HUMAN_HOURS=$hrs)"
      br_sup_write "$p" "$ck" '.decline_next.wait_said = $h' --arg h "$head" || true
    fi
    return 0
  fi
  [ "${hh:-}" = "$head" ] && return 0
  key="decline-human $p $ck $head"
  mark="$ST/$p/$ck.decline-human-$h12"
  cm_has "$key" - "$mark" 2>/dev/null || mrc=$?
  [ "$mrc" = 127 ] && { [ -e "$mark" ] && mrc=0; }
  [ "$mrc" = 0 ] && return 0
  # THE MARKER FIRST: at most one post per head, even when the post fails.
  cm_put "$key" - "$mark" 2>/dev/null || { mkdir -p "$(dirname "$mark")" 2>/dev/null; : > "$mark"; }
  br_sup_write "$p" "$ck" '.decline_next.human_head = $h | .decline_next.human_at = $t' --arg h "$head" \
    || say "$p/$rkey: the needs-human mark was not written on the record — the comment marker file holds it"
  last=$(jq -r --arg u "$url" '[.attempts[]? | select((.action // "") | startswith("fix-round")) | select((.url // $u) == $u)] | last
      | if . == null then "none recorded for this PR" else "\(.at // "?"), \(.action): \(.detail // "no detail")" end' <<<"$st" 2>/dev/null)
  body="This PR needs a person: $url

The lead's $vword verdict (row $vrow) stands on head $h12, and CI is red on that head. The resolver cannot rebuild the PR fresh, because the verdict marks it as reviewed work. The fix-round budget for this head is spent, and CI is still red after ${hrs}h.

Last fix round: ${last:-none recorded for this PR}.

This PR needs a person: push a fix, merge it, or close it."
  prefix=$("$H/bin/fleet-conf.sh" "$p" board_prefix 2>/dev/null)
  tk="${ck#"$p"-}"; [ "$tk" = "$ck" ] && tk=""
  if [ "$prefix" != "-" ]; then
    "$H/bin/lane-alert.sh" blocked-resolver "NEEDS_HUMAN: $p/$rkey: $url — the lead's $vword verdict (row $vrow) stands on $h12, CI is red, and the fix rounds on this head are spent. Push a fix, merge it, or close it. (Product board: no board comment is posted for this.)" >/dev/null 2>&1 || true
    say "$p/$rkey [$reason]: DECLINE NEXT — needs a person on $h12: one NEEDS_HUMAN lane alert (product board, no board comment)"
    return 0
  fi
  issue=$(sed -nE 's/^[A-Za-z]+-([0-9]+)$/\1/p' <<<"$tk")
  rc=0
  if [ -n "$issue" ]; then
    br_issue_comment "$slug" "$issue" "$body" || rc=$?
    [ "$rc" = 0 ] && { say "$p/$rkey [$reason]: DECLINE NEXT — told $slug#$issue that $url needs a person (head $h12)"; return 0; }
  else
    issue="$num"
    br_pr_comment "$url" "$body" || rc=$?
    [ "$rc" = 0 ] && { say "$p/$rkey [$reason]: DECLINE NEXT — told $slug#$num (the PR, no ticket key) that it needs a person (head $h12)"; return 0; }
  fi
  "$H/bin/lane-alert.sh" blocked-resolver "NEEDS_HUMAN: $p/$rkey: the needs-human comment for $url (head $h12) was NOT posted on $slug#$issue (HTTP ${GH_REST_STATUS:-000}). The marker stands, so it is not retried: push a fix, merge it, or close it." >/dev/null 2>&1 || true
  say "$p/$rkey [$reason]: DECLINE NEXT — the needs-human comment on $slug#$issue failed (HTTP ${GH_REST_STATUS:-000}); one lane alert sent, not retried"
  return 0
}
