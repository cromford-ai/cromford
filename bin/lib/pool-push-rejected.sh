#!/bin/bash
# shellcheck shell=bash
# bin/lib/pool-push-rejected.sh — what the pool reap does with a "push rejected"
# deferral. Sourced by bin/fly-pool.sh, never run: no `set`, no `exit`, nothing
# runs at source time.
#
# A pool machine answers `BUILD_DEFERRED push of <branch> rejected at <sha>` when
# its PR-stage push failed twice (bin/lib/rb/pr.sh). That alone does not say the
# work is lost. BH-5566's head was already on GitHub and only the PR step did not
# run, but the reap wrote a terminal, opened no PR and closed the row failed. So
# the reap now asks GitHub how the built head relates to the remote branch:
#
#   landed    compare `identical` or `ahead`: the remote holds the built head.
#             ppr_reap_landed opens the PR from the branch with the create
#             ladder pr.sh uses, and rewrites the RESULT to PR_CREATED. The
#             reap's own PR_CREATED gate then verifies it and closes the row.
#   diverged  compare `behind` or `diverged`, or a 404 (GitHub does not know the
#             built sha): the work is not on GitHub. The first time,
#             ppr_reap_diverged requeues ONE build that starts from the remote
#             head (`continue_branch` -> TARGET_BRANCH on the machine). Again
#             inside POOL_PUSH_DIVERGE_TTL_S, the terminal stands and
#             ppr_terminal_note writes one ALERTS line.
#   unknown   no built head, an unreadable ref or compare, a held ticket, a
#             failed PR open: the terminal, as before.
#
# POOL_PUSH_LANDED_OPEN=0 turns all of it off: every rejection is terminal.
#
# A PR the hub opened gets what the machine's PR stage would have given it:
# ppr_after_reap (called once after the reap's pool_result beat) loads
# bin/lib/ppr-review.sh, which sends the pr_created build beat, asks for a lead
# review of the PR head and runs the migration-number check. When plan.md was
# not relayed, ppr_plan_from_branch reads .harness/specs/<KEY>/plan.md from the
# branch before the PR body is written.
#
# It reads the reap loop's globals (P KEY TICKET LOCAL RLINE PDIR QDIR POOL_SLUG
# POOL_SLUG_TOK ATT DEFC DTHS SBASE MHF) and calls its functions (pool_rest_read,
# branch_head_rest, pool_key_branch, QROW, say, STAMP). The harness root is
# ${HARNESS:-${H:-}} only; with none, the libs it loads lazily are not found and
# the answer is the terminal.

PPR_KEY=""; PPR_CMP=""; PPR_STATUS=""; PPR_BUILT=""; PPR_REMOTE=""; PPR_BR=""; PPR_SECOND=0
PPR_PR_URL=""; PPR_PR_KEY=""; PPR_PR_BASE=""

# ppr_rejected_line <rline> — rc 0 when the line is a push-rejected deferral.
ppr_rejected_line() {
  case "${1:-}" in "BUILD_DEFERRED push of ticket/"*rejected*) return 0 ;; esac
  return 1
}

# ppr_built_head <rline> <local-dir> — the 40-hex head the machine built: the sha
# after ` rejected at ` in the line, else the relayed reviewed-sha (an image older
# than the line's sha). rc 1, nothing printed, when neither is a sha.
ppr_built_head() {
  local s=""
  if [[ "${1:-}" =~ \ rejected\ at\ ([0-9a-f]{40})([^0-9a-f]|$) ]]; then s="${BASH_REMATCH[1]}"
  elif [ -n "${2:-}" ] && [ -f "$2/reviewed-sha" ]; then s=$(head -n 1 "$2/reviewed-sha" 2>/dev/null | tr -d '[:space:]')
  fi
  [[ "$s" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s' "$s"
}

# ppr_compare <slug> <built> <branch> [token] -> "<landed|diverged|unknown> <status>"
# One REST read of compare/<built>...<branch>, status line first.
ppr_compare() {
  local out code body st
  out=$(pool_rest_read "repos/$1/compare/$2...$3" "${4:-}")
  code=$(head -n 1 <<<"$out"); body=$(tail -n +2 <<<"$out")
  case "$code" in
    200)
      st=$(jq -r '.status // empty' 2>/dev/null <<<"$body")
      case "$st" in
        identical|ahead) printf 'landed %s\n' "$st" ;;
        behind|diverged) printf 'diverged %s\n' "$st" ;;
        *) printf 'unknown status=%s\n' "${st:-none}" ;;
      esac ;;
    404) printf 'diverged 404\n' ;;
    *) printf 'unknown http=%s\n' "${code:-none}" ;;
  esac
}

# ppr_decide — the reads, once per reaped RESULT, into PPR_*.
ppr_decide() {
  local b ans
  PPR_KEY="$KEY"; PPR_CMP=unknown; PPR_STATUS=""; PPR_BUILT=""; PPR_REMOTE=""; PPR_SECOND=0
  PPR_PR_URL=""; PPR_PR_KEY=""; PPR_PR_BASE=""
  b="${RLINE#BUILD_DEFERRED push of }"; b="${b%% *}"
  case "$b" in ''|*[!A-Za-z0-9._/-]*) b=$(pool_key_branch "$KEY") ;; esac
  PPR_BR="$b"
  if ! PPR_BUILT=$(ppr_built_head "$RLINE" "${LOCAL:-}"); then
    PPR_BUILT=""
    say "push-rejected $KEY: the built head is unknown (no sha in the RESULT, no relayed reviewed-sha) — terminal"
    return 0
  fi
  [ -n "${POOL_SLUG:-}" ] || return 0
  command -v pool_slug_token_arm >/dev/null 2>&1 && pool_slug_token_arm
  PPR_REMOTE=$(branch_head_rest "$PPR_BR" 2>/dev/null) || PPR_REMOTE=""
  if [ -z "$PPR_REMOTE" ]; then
    say "push-rejected $KEY: the remote head of $PPR_BR did not read — terminal"
    return 0
  fi
  ans=$(ppr_compare "$POOL_SLUG" "$PPR_BUILT" "$PPR_BR" "${POOL_SLUG_TOK:-}")
  PPR_CMP="${ans%% *}"; PPR_STATUS="${ans#* }"
  [ "$PPR_CMP" = unknown ] && say "push-rejected $KEY: the compare of $PPR_BUILT with $PPR_BR did not answer ($PPR_STATUS) — terminal"
  return 0
}

# ppr_lib <name> — load a bin/lib file the open path needs, once.
ppr_lib() {
  local h="${HARNESS:-${H:-}}"
  [ -n "$h" ] && [ -r "$h/bin/lib/$1" ] || return 1
  # shellcheck disable=SC1090
  . "$h/bin/lib/$1"
}

# ppr_title — "<KEY>: <title>", the shape pr.sh gives a PR.
ppr_title() {
  local t="" out
  t=$(jq -r '.title // empty' "$LOCAL/ticket-meta.json" 2>/dev/null | head -n 1)
  if [ -z "$t" ] && [ -n "${TICKET:-}" ] && [ "${PPR_ISSUES:-0}" = 1 ]; then
    out=$(pool_rest_read "repos/$POOL_SLUG/issues/$TICKET" "${POOL_SLUG_TOK:-}")
    [ "$(head -n 1 <<<"$out")" = 200 ] && t=$(tail -n +2 <<<"$out" | jq -r '.title // empty' 2>/dev/null | head -n 1)
  fi
  [ -n "$t" ] || t="pool build of $PPR_BR"
  printf '%s: %s' "$KEY" "$t"
}

# ppr_plan_from_branch — when no plan.md was relayed, read
# .harness/specs/<KEY>/plan.md from the branch into $LOCAL/plan.md, and name
# the source in $LOCAL/plan-source. Any answer but a 200 writes nothing.
ppr_plan_from_branch() {
  local out code tmp sp=".harness/specs/$KEY/plan.md"
  [ -s "$LOCAL/plan.md" ] && return 0
  out=$(pool_rest_read "repos/$POOL_SLUG/contents/$sp?ref=$PPR_BR" "${POOL_SLUG_TOK:-}")
  code=$(head -n 1 <<<"$out")
  if [ "$code" != 200 ]; then
    say "push-rejected $KEY: no plan.md was relayed and $sp on $PPR_BR answered HTTP ${code:-none} — the PR body says so"
    return 0
  fi
  tmp="$LOCAL/plan.md.ppr"
  if tail -n +2 <<<"$out" | jq -r '.content // empty' 2>/dev/null | base64 -d > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv -f "$tmp" "$LOCAL/plan.md"
    printf 'branch:%s@%s\n' "$sp" "$PPR_BR" > "$LOCAL/plan-source"
    say "push-rejected $KEY: plan.md read from $sp on $PPR_BR"
  else
    rm -f "$tmp"
    say "push-rejected $KEY: $sp on $PPR_BR did not decode — the PR body says plan.md was not relayed"
  fi
  return 0
}

# ppr_body <file> [title] — the PR body: the plan's why, the relayed evidence,
# and what the hub did. pr.sh's body render runs on the machine and did not run
# there. Line 1 names the ticket and line 2 is `Closes #<ticket>` on an issues
# lane (board prefix "-", PPR_ISSUES=1) with a numeric TICKET, the shape pr.sh
# gives it: a merge then closes the issue, and lead review finds the thread.
# Any other project, or a non-numeric TICKET, gets no line. pr.sh's Refs-on-a-
# REFUTED-claim rule needs evidence.json, which the reap does not relay.
ppr_body() {
  local f="$1" t="${2:-}" why="" closes=""
  if [ -f "$LOCAL/plan.md" ]; then
    why=$(awk '/^## Why/ {on=1; next} on && /^## / {exit} on {print}' "$LOCAL/plan.md" | grep -v '^$' | head -8 | head -c 900)
    [ -n "$why" ] || why=$(awk 'NR==1{next} /^## /{exit} {print}' "$LOCAL/plan.md" | grep -v '^$' | head -8 | head -c 900)
  fi
  t="${t#"$KEY: "}"
  if [ "${PPR_ISSUES:-0}" = 1 ]; then
    case "${TICKET:-}" in ''|*[!0-9]*) ;; *) closes="Closes #$TICKET" ;; esac
  fi
  {
    printf 'Ticket %s — %s\n' "$KEY" "${t:-pool build of $PPR_BR}"
    [ -n "$closes" ] && printf '%s\n' "$closes"
    printf '\n## Why\n\n%s\n\n' "${why:-plan.md was not relayed from the machine.}"
    printf '## Evidence\n\n'
    if [ -s "$LOCAL/evidence.md" ]; then head -c 20000 "$LOCAL/evidence.md"; printf '\n\n'
    else printf 'evidence.md was not relayed from the machine.\n\n'; fi
    printf '## Opened by the hub\n\n'
    printf 'The pool machine reported the push of `%s` rejected. The branch already held `%s`, which contains the built head `%s` (GitHub compare: %s). The hub opened this PR from the branch as it stands.\n\n' \
      "$PPR_BR" "$PPR_REMOTE" "$PPR_BUILT" "$PPR_STATUS"
    printf 'Review is bound to `%s`.\n\n' "$(head -n 1 "$LOCAL/reviewed-sha" 2>/dev/null | tr -d '[:space:]' | grep . || echo 'no reviewed-sha relayed')"
    printf '🤖 Generated with [Claude Code](https://claude.com/claude-code)\n'
  } > "$f"
}

# ppr_reap_landed — called once per reaped RESULT, before the deferral arm.
# rc 0: the PR is open and RLINE/RESULT now say PR_CREATED <url>. rc 1: nothing
# changed (not a push rejection, not landed, held, or the open failed).
ppr_reap_landed() {
  PPR_PR_URL=""; PPR_PR_KEY=""; PPR_PR_BASE=""
  ppr_rejected_line "${RLINE:-}" || return 1
  [ "${POOL_PUSH_LANDED_OPEN:-1}" = 0 ] && return 1
  ppr_decide
  [ "$PPR_CMP" = landed ] || return 1
  local v vrc tk base title bf url h="${HARNESS:-${H:-}}"
  PPR_ISSUES=0
  [ "$("$h/bin/fleet-conf.sh" "$P" board_prefix 2>/dev/null)" = "-" ] && PPR_ISSUES=1
  # The HOLD, read now: a person who typed HOLD on the ticket gets no PR.
  tk=none; [ "$PPR_ISSUES" = 1 ] && [ -n "${TICKET:-}" ] && tk="$TICKET"
  if ! command -v hold_push_verdict >/dev/null 2>&1 && ! ppr_lib hold-push.sh; then
    say "push-rejected $KEY: landed at $PPR_BUILT but the ticket hold reads unreadable (bin/lib/hold-push.sh is missing) — no PR opened"
    return 1
  fi
  v=$(GH_TOKEN="${POOL_SLUG_TOK:-${GH_TOKEN:-}}" hold_push_verdict "$P" "$tk" "$PPR_BR" 2>/dev/null); vrc=$?
  if [ "$vrc" != 0 ]; then
    say "push-rejected $KEY: landed at $PPR_BUILT but the ticket hold reads $([ "$vrc" = 1 ] && echo held || echo unreadable) — no PR opened (${v#*	})"
    return 1
  fi
  if ! command -v gh_pr_create_ladder >/dev/null 2>&1 && ! ppr_lib gh-pr-create.sh; then
    say "push-rejected $KEY: landed at $PPR_BUILT but bin/lib/gh-pr-create.sh is missing — no PR opened"
    return 1
  fi
  title=$(ppr_title)
  ppr_plan_from_branch
  bf="$LOCAL/pr-body.md"
  ppr_body "$bf" "$title"
  if command -v pr_trailers_apply >/dev/null 2>&1 || ppr_lib pr-trailers.sh; then
    pr_trailers_apply "$bf" "$(pr_trailers_job_for "$LOCAL" 2>/dev/null || echo none)" "$KEY" >/dev/null 2>&1 || true
  fi
  base="${SBASE:-${BASE_BRANCH:-main}}"
  url=$(GH_TOKEN="${POOL_SLUG_TOK:-${GH_TOKEN:-}}" gh_pr_create_ladder "$POOL_SLUG" "$PPR_BR" "$base" "$title" "$bf" \
          "$LOCAL/gh-stderr.log" "$LOCAL/pipeline.log" "pool/$P/$KEY")
  case "$url" in
    https://github.com/*/pull/[0-9]*) ;;
    *) say "push-rejected $KEY: landed at $PPR_BUILT but every PR create rung failed ($(tail -c 200 "$LOCAL/gh-stderr.log" 2>/dev/null | tr '\n' ' ')) — terminal"
       return 1 ;;
  esac
  # The ticket's PR-Labels line (BH-7929), as pr.sh applies it on a machine.
  if [ -r "$LOCAL/ticket-meta.json" ] && { command -v prl_apply >/dev/null 2>&1 || ppr_lib rb-pr-labels.sh; }; then
    GH_TOKEN="${POOL_SLUG_TOK:-${GH_TOKEN:-}}" prl_apply "$P" "$url" "$LOCAL/ticket-meta.json" "$LOCAL/pipeline.log" || true
  fi
  { printf 'PR_CREATED %s (opened by the hub: push reported rejected, %s already at %s)\n' "$url" "$PPR_BR" "$PPR_REMOTE"
    cat "$LOCAL/RESULT"; } > "$LOCAL/RESULT.ppr" && mv -f "$LOCAL/RESULT.ppr" "$LOCAL/RESULT"
  RLINE=$(head -n 1 "$LOCAL/RESULT")
  rm -f "$PDIR/$KEY.push-diverged"
  PPR_PR_URL="$url"; PPR_PR_KEY="$KEY"; PPR_PR_BASE="$base"
  say "push-rejected $KEY: landed at $PPR_BUILT -> PR $url"
  return 0
}

# ppr_after_reap — called once per reaped RESULT, after the pool_result beat.
# Only a PR ppr_reap_landed opened on this reap gets the hand-off
# (bin/lib/ppr-review.sh). Always rc 0.
ppr_after_reap() {
  [ -n "${PPR_PR_URL:-}" ] && [ "${PPR_PR_KEY:-}" = "$KEY" ] || return 0
  local h="${HARNESS:-${H:-}}"
  if ! command -v ppr_review_handoff >/dev/null 2>&1 && ! ppr_lib ppr-review.sh; then
    say "push-rejected $KEY: bin/lib/ppr-review.sh is missing — $PPR_PR_URL gets no build row and no review request"
    [ -n "$h" ] && env HARNESS="$h" "$h/bin/alert-line.sh" "[pool/$P] $KEY: the hub opened $PPR_PR_URL after a push-rejected deferral, but bin/lib/ppr-review.sh is missing, so the PR has no build row and no review request. Ask by hand: bin/lead-verdict.sh request"
    PPR_PR_URL=""; PPR_PR_KEY=""
    return 0
  fi
  ppr_review_handoff || true
  PPR_PR_URL=""; PPR_PR_KEY=""
  return 0
}

# ppr_diverge_ttl — POOL_PUSH_DIVERGE_TTL_S, or its default for a bad value.
ppr_diverge_ttl() {
  local v="${POOL_PUSH_DIVERGE_TTL_S:-604800}"
  case "$v" in ''|*[!0-9]*) v=604800 ;; esac
  [ "$v" -ge 3600 ] || v=604800
  printf '%s' "$v"
}

# ppr_reap_diverged — called inside the push-rejected arm, before the terminal.
# rc 0: the key was handled (requeued once from the remote head, or found
# abandoned) and no terminal is written. rc 1: write the terminal, as before.
ppr_reap_diverged() {
  [ "${POOL_PUSH_LANDED_OPEN:-1}" = 0 ] && return 1
  [ "$PPR_KEY" = "$KEY" ] || ppr_decide
  [ "$PPR_CMP" = diverged ] || return 1
  [ -n "${TICKET:-}" ] && [ "$TICKET" != null ] || return 1
  local sf="$PDIR/$KEY.push-diverged" age why meta
  if [ -f "$sf" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$sf" 2>/dev/null || echo 0) ))
    if [ "$age" -lt "$(ppr_diverge_ttl)" ]; then PPR_SECOND=1; return 1; fi
  fi
  why="push to $PPR_BR rejected: remote $PPR_REMOTE diverged from built $PPR_BUILT ($PPR_STATUS) — requeued once from the remote head"
  meta=$(jq -nc --argjson d "${DEFC:-0}" --argjson x "${DTHS:-0}" --arg sb "${SBASE:-}" --arg hf "${MHF:-false}" --arg cb "$PPR_BR" \
    '{deferrals:$d,deaths:$x,continue_branch:$cb} + (if $sb == "" then {} else {stack_base:$sb} end) + (if $hf == "true" then {hotfix:true} else {} end)')
  : > "$LOCAL/DEFERRED"
  if ! QROW requeue "$KEY" "$why" "${ATT:-0}" "$meta" "$TICKET"; then
    say "push-rejected $KEY: diverged at $PPR_REMOTE, but the ticket was abandoned by an operator — not requeued"
    return 0
  fi
  jq -nc --arg t "$TICKET" --arg k "$KEY" --argjson a "${ATT:-0}" --argjson d "${DEFC:-0}" --argjson x "${DTHS:-0}" --arg ts "$(STAMP)" \
     --arg sb "${SBASE:-}" --arg hf "${MHF:-false}" --arg cb "$PPR_BR" \
    '{ticket_id:$t,key:$k,attempt:$a,deferrals:$d,deaths:$x,enqueued_at:$ts,continue_branch:$cb} + (if $sb == "" then {} else {stack_base:$sb} end) + (if $hf == "true" then {hotfix:true} else {} end)' \
    > "$QDIR/$KEY.json"
  mkdir -p "$PDIR"
  jq -nc --arg b "$PPR_BUILT" --arg r "$PPR_REMOTE" --arg at "$(STAMP)" --arg t "$TICKET" \
    '{built:$b,remote:$r,at:$at,ticket_id:$t}' > "$sf"
  say "push-rejected $KEY: diverged -> requeue 1 from $PPR_REMOTE (built $PPR_BUILT, $PPR_STATUS)"
  return 0
}

# ppr_terminal_note — after the terminal is written. A second divergence inside
# the window is the one case that pages: once, here.
ppr_terminal_note() {
  [ "$PPR_KEY" = "$KEY" ] && [ "$PPR_SECOND" = 1 ] || return 0
  local h="${HARNESS:-${H:-}}"
  rm -f "$PDIR/$KEY.push-diverged"
  # `env` on purpose: a NAME= line that names state/pool reads as a new writer
  # to bin/state-paths-guard.sh, and this line only quotes the path in text.
  env HARNESS="$h" "$h/bin/alert-line.sh" "[pool/$P] $KEY: push to $PPR_BR rejected twice; remote $PPR_REMOTE diverged from built $PPR_BUILT both times — terminal. Evidence: state/pool/$P/$KEY.terminal"
  return 0
}
