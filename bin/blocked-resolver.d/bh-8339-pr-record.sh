# shellcheck shell=bash
# bin/blocked-resolver.d/bh-8339-pr-record.sh — BH-8339: the ABANDONED terminal
# and the per-PR ladder belong to the PR that was abandoned, a fix round runs
# only on the open PR it was asked to fix, and the branch's own lint is in the
# round's first prompt.
#
# WHY. BH-8062, 2026-10-25: the resolver abandoned PR #8294 and the ticket's
# record (one per ticket, br_cap_key) became ABANDONED. The rebuilt PR #8301
# then got a lead BLOCK, and br_one answered rc 3 for it on every tick: no fix
# round came. A round queued for #8294 also pushed to that closed PR's branch.
#
# THE CALL SITES, each one line in the driver:
#   br_abandon, after the ABANDONED outcome  -> bpr_stamp (abandoned_url)
#   br_one, before the ABANDONED check       -> bpr_scope (reset for an open other PR)
#   br_finished, the ABANDONED arm           -> bpr_retire
#   br_fix_round, after the br_pr_ref read   -> bpr_fix_target (open PRs only:
#     a closed or merged PR's branch is never worked or pushed, nothing is spent)
#   br_fix_adopt, first                      -> bpr_adopt_other (another PR's row:
#     adopted with no record save and no rung, so its record_out cannot
#     overwrite this PR's ladder)
#   br_fix_round, the ci-local brief block   -> bpr_lint_brief (pre-round scan)
# The rebuild counters (rebuilds, rebuild_jobs) and adjudications stay per
# ticket, so the rebuild cap still bounds the ticket. A record with no
# abandoned_url (written before this file, or an operator's ABANDON) keeps the
# ticket-level rule. BR_OPT_OFF=bh-8339-pr-record does not source this file,
# and each call site then does what it did before.

# bpr_is_pr_url <s> — rc 0 when <s> is a GitHub pull request url.
bpr_is_pr_url() {
  [[ "${1:-}" =~ ^https://github\.com/[^/]+/[^/]+/pull/[0-9]+$ ]]
}

# bpr_stamp <project> <cap-key> <pr-url> — the PR this ABANDONED is about.
#   Nothing is written for a url that is not a PR url.
bpr_stamp() {
  bpr_is_pr_url "${3:-}" || return 0
  br_set_field "$1" "$2" abandoned_url "$3" \
    || say "$1/$2: the abandoned PR url was not written — this ABANDONED stays ticket-level"
}

# bpr_retire <abandoned-url> <candidate-url> — br_finished's ABANDONED arm,
#   rc 0 retire. PURE and fork-free (br_prepass calls it once per candidate).
#   Retired: a record with no abandoned url (the ticket rule), a candidate with
#   no PR url, and the abandoned PR itself. Another PR of the ticket is not
#   retired: br_one asks bpr_scope about it.
bpr_retire() {
  local aurl="${1:--}" url="${2:--}"
  bpr_is_pr_url "$aurl" || return 0
  bpr_is_pr_url "$url" || return 0
  [ "$url" = "$aurl" ] && return 0
  return 1
}

# bpr_scope <project> <rkey> <cap-key> <reason> <pr-url> [<record-json>]
#   rc 0 the record was reset for this PR (the caller reloads it); rc 1 no
#   change, the terminal stands. A reset needs ALL of: outcome ABANDONED, an
#   abandoned_url, a candidate PR url that is another PR, a reason that is not
#   rebuild-*, not observe mode, and br_pr_state answering `open`. The reset is
#   one br_save: the outcome and the per-PR counters go to 0, the rebuild
#   counters and the history are kept, one pr-reset attempt names the PR.
bpr_scope() {
  local p="$1" rkey="$2" ck="$3" reason="$4" url="${5:--}" st="${6:-}" aurl s rc=0 t
  [ -n "$st" ] || st=$(br_load "$p" "$ck")
  [ "$(printf '%s' "$st" | jq -r '.outcome // ""' 2>/dev/null)" = ABANDONED ] || return 1
  aurl=$(printf '%s' "$st" | jq -r '.abandoned_url // "-"' 2>/dev/null)
  bpr_retire "$aurl" "$url" && return 1
  case "$reason" in rebuild-*) return 1 ;; esac
  s=$(br_pr_state "$url") || rc=$?
  case "$rc" in
    0)  [ "$s" = open ] || return 1 ;;
    44) return 1 ;;
    *)  say "$p/$rkey [$reason]: the ticket's ABANDONED is about $aurl; the state of $url could not be read — terminal kept this tick, retried next tick"
        return 1 ;;
  esac
  if [ "$OBSERVE" = 1 ]; then
    say "$p/$rkey [$reason]: WOULD reset the ladder for $url (the ABANDONED is about $aurl) — observe mode"
    return 1
  fi
  t=$(STAMP)
  st=$(printf '%s' "$st" | jq -c --arg t "$t" --arg a "$aurl" --arg u "$url" --arg r "$reason" '
    .outcome = "" | .mechanicals = 0 | .regens = 0 | .fixrounds = 0 | .fixround_bonus = 0 | .retired = false
    | .pr_resets = ((.pr_resets // 0) + 1) | .pr_reset = {from:$a, to:$u, at:$t}
    | .attempts += [{at:$t, action:"pr-reset", reason:$r, url:$u,
        detail:("the ABANDONED was about " + $a + "; " + $u + " is open and gets its own ladder (rebuild counters kept)")}]
    | .updated = $t' 2>/dev/null) || st=""
  if [ -z "$st" ] || ! br_save "$p" "$ck" "$st"; then
    say "$p/$rkey [$reason]: the PR reset for $url was not written — terminal kept this tick"
    return 1
  fi
  say "$p/$rkey [$reason]: PR RESET — the ABANDONED was about $aurl; $url is open and gets a fresh ladder (rebuilds kept)"
  br_event resolver_pr_reset "$p" "$ck" "$reason" "ABANDONED about $aurl; fresh ladder for $url"
  return 0
}

# bpr_fix_target <project> <cap-key> <rkey> <reason> <pr-url>
#   rc 0 the PR is open (or the url is not a PR url: nothing to check); rc 1
#   closed, merged or absent; rc 75 the state did not read. On rc 1 and rc 75
#   the round does not run: no worktree, no agent, no push, no rung.
bpr_fix_target() {
  local p="$1" ck="$2" rkey="$3" reason="$4" url="${5:--}" s rc=0
  bpr_is_pr_url "$url" || return 0
  s=$(br_pr_state "$url") || rc=$?
  case "$rc" in
    0)  case "$s" in
          open) return 0 ;;
          closed|merged)
            say "$p/$rkey [$reason]: fix round not run: $url is $s — nothing pushed, no rung spent"
            return 1 ;;
        esac ;;
    44) say "$p/$rkey [$reason]: fix round not run: $url is absent (HTTP 404) — nothing pushed, no rung spent"
        return 1 ;;
  esac
  say "$p/$rkey [$reason]: fix round not run: the state of $url could not be read — nothing pushed, no rung spent, retried next tick"
  return 75
}

# bpr_row_other_pr <row-json> <pr-url> — rc 0 when the fix_round_jobs row was
#   queued for ANOTHER PR (args[3] is a PR url that is not <pr-url>). A row with
#   no args or a non-PR args[3] is not another PR's (fail-open: today's adopt).
bpr_row_other_pr() {
  local ru
  ru=$(printf '%s' "${1:-}" | jq -r '.args[3]? // "" | strings' 2>/dev/null)
  bpr_is_pr_url "$ru" || return 1
  [ "$ru" != "${2:--}" ]
}

# bpr_adopt_other <project> <rkey> <reason> <pr-url> <row-json>
#   rc 0 the row belongs to another PR and was handled: it is adopted (the one
#   CAS) with no record save and no rung. rc 1 the row is this PR's: the caller
#   adopts it as before.
bpr_adopt_other() {
  local p="$1" rkey="$2" reason="$3" url="$4" row="$5" id ru arc=0
  bpr_row_other_pr "$row" "$url" || return 1
  id=$(printf '%s' "$row" | jq -r '.id // empty' 2>/dev/null)
  ru=$(printf '%s' "$row" | jq -r '.args[3]' 2>/dev/null)
  fix_round_adopt "$id" >/dev/null 2>>"${LOG:-/dev/null}" || arc=$?
  case "$arc" in
    0|9) say "$p/$rkey [$reason]: fix-round row $id belongs to $ru, not $url — adopted, no record saved, no rung taken" ;;
    *)   say "$p/$rkey [$reason]: fix-round row $id belongs to $ru: the adopt was not recorded — retried next tick, no rung taken" ;;
  esac
  return 0
}

# bpr_lint_brief <worktree> <base-ref> <outdir> <last-findings-file> [<conflicts>]
#   The ci-local paragraph of the round's brief, with its leading blank line,
#   or nothing. When the merge left no conflicted path and the ci-local seam is
#   loaded, the worktree's own bin/ci-local.sh runs first (cl_run, into
#   <outdir>): red prints its findings, clean prints nothing. Skipped, off,
#   could-not-run or a conflicted merge print the last round's findings from
#   <last-findings-file> when it is not empty, as before this file.
bpr_lint_brief() {
  local wt="$1" base="$2" od="$3" last="$4" conflicts="${5:-}" w=""
  if [ -z "$conflicts" ] && command -v cl_run >/dev/null 2>&1; then
    mkdir -p "$(dirname "$od")" 2>/dev/null
    w=$(cl_run "$wt/bin/ci-local.sh" "$wt" "$base" "$od")
    case "$w" in
      red)
        printf '\n\n%s\n%s' "THE CI LINT STEPS ARE RED ON THIS BRANCH BEFORE YOUR CHANGE (bin/ci-local.sh, the steps of CI's lint job and the rules pack). The harness re-runs them after you and will not push while they are red, so fix them in this same commit, with the brief above. Reproduce one step with \`bin/ci-local.sh --step '<step>'\`. Fix the code each line names; never edit .github/workflows/harness-ci.yml, bin/ci-local.sh or catalog/ci-local-skip.d/:" \
          "$(cl_findings "$od")"
        return 0 ;;
      clean) return 0 ;;
    esac
  fi
  [ -s "$last" ] || return 0
  printf '\n\n%s\n%s' "THE CI LINT STEPS WERE RED ON THE LAST ROUND (bin/ci-local.sh, the steps of CI's lint job and the rules pack). The harness re-runs them after you and will not push while they are red. Reproduce one step with \`bin/ci-local.sh --step '<step>'\`. Fix the code each line names; never edit .github/workflows/harness-ci.yml, bin/ci-local.sh or catalog/ci-local-skip.d/:" \
    "$(head -40 "$last")"
}
