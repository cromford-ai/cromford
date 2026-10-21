#!/bin/bash
# bin/lib/pr-self-check-validate.sh — BH-7072: the plan-validate rule of the
# pre-review self-check (bin/lib/pr-self-check.sh). Sourced; defines functions
# only.
#
# WHY. In 12 lead BLOCKs a plan task or a body metric was not delivered, and
# the plan already held the VALIDATE line that would have failed. This rule
# runs the static ones before a review is bought.
#
# THE PLAN is the one .harness/specs/<KEY>/plan.md the diff changes (the pick
# of psc_plan_missing), read at the head. No plan, or a plan with no VALIDATE
# line outside fences and the contract sections: the rule prints nothing.
#
# THE CHECKS (bin/lib/plan-validate.py, run as `python3 -I`, never a shell):
#   each backtick command on a VALIDATE line that is a static shape — test
#   -f|-e|-s|-d, [ ... ], ls, grep with -c -q -n -E -F -i -w -x -s -h -e, a
#   `! ` in front; what it must give is a comparator or the words after it
#   (`prints N`, `prints nothing`, `exits 0|1`, ...) — runs against the head tree,
#   or against the PR body when its file is `<PR body>`, pr-body.md or
#   `gh pr view ... body | grep`. Every other VALIDATE line is skipped and
#   counted in one NOTE. The body is red on a "not met" line (outside fences,
#   inline code, quotes, checked items and `## Pre-open check`) and on a
#   `Target metric:` the measured number misses.
#
# OWED. A body line `owed: <task id> <reason>` excuses that task when a PR
# conversation comment by an operator says `approve owed: <id>` or
# `owed <id> approved`. Operators are the logins in the settings row
# trigger.actors.<project> (ta_allowlist, bin/lib/trigger-actor.sh). Any
# approved owed line also excuses the not-met and Target-metric findings. The
# comments are read only when a finding exists and the body has an owed: line,
# at most PLAN_VALIDATE_COMMENT_PAGES pages (default 5) of 100. The PR comes
# from PSC_PR_REPO and PSC_PR_N, the project from PSC_PROJECT; any of them
# empty (the builder's pre-open check) = no approval, and the finding says why.
#
# psc_validate_check <repo> <base> <head> <body> <mode> <id>
#   The rule's lines: `REFUSE <id>: ...` (mode refuse) or `NOTE <id>: ...`.
#   rc 1 when it refused, else 0. python3 missing or the evaluator failing is
#   one NOTE `could not run`, never a refusal. Callers: psc_check.
#   PLAN_VALIDATE_MAX_LINES (default 60) caps the VALIDATE lines read.

_psc_v_dir() { (cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd); }

# _psc_v_approvals <out-file> — `<login>\t<line>` per comment line by an
# operator. rc 0 written; rc 1 with _PSC_V_WHY saying why there is none.
_psc_v_approvals() {
  local out="$1" root="${HARNESS:-${H:-}}" lib page raw n allow
  local pages="${PLAN_VALIDATE_COMMENT_PAGES:-5}"
  case "$pages" in ''|*[!0-9]*) pages=5 ;; esac
  _PSC_V_WHY=""
  [ -n "${PSC_PR_REPO:-}" ] && [ -n "${PSC_PR_N:-}" ] || { _PSC_V_WHY="no PR yet, so no thread to approve it"; return 1; }
  [ -n "${PSC_PROJECT:-}" ] || { _PSC_V_WHY="no project, so no operator list"; return 1; }
  lib=$(_psc_v_dir)
  # shellcheck source=bin/lib/trigger-actor.sh
  command -v ta_allowlist >/dev/null 2>&1 || . "$lib/trigger-actor.sh" 2>/dev/null || :
  command -v ta_allowlist >/dev/null 2>&1 || { _PSC_V_WHY="bin/lib/trigger-actor.sh not loaded"; return 1; }
  if [ -n "$root" ] && { ! command -v setting_get >/dev/null 2>&1 || ! command -v gh_rest >/dev/null 2>&1; }; then
    _ta_deps >/dev/null 2>&1 || :
  fi
  # shellcheck source=bin/lib/gh-rest-var.sh
  command -v gh_rest_var >/dev/null 2>&1 || . "$lib/gh-rest-var.sh" 2>/dev/null || :
  command -v gh_rest >/dev/null 2>&1 && command -v gh_rest_var >/dev/null 2>&1 \
    || { _PSC_V_WHY="no GitHub client"; return 1; }
  PROJECT_2_NOTE=""
  ta_allowlist "$PSC_PROJECT"
  [ "$PROJECT_2_ROW" = armed ] || { _PSC_V_WHY="the settings row trigger.actors.$PSC_PROJECT is $PROJECT_2_ROW${PROJECT_2_NOTE:+ ($PROJECT_2_NOTE)}"; return 1; }
  allow="$PROJECT_2_ALLOW"
  : > "$out" || { _PSC_V_WHY="no temp file"; return 1; }
  page=1
  while [ "$page" -le "$pages" ]; do
    raw=""
    if ! gh_rest_var raw GET "repos/$PSC_PR_REPO/issues/$PSC_PR_N/comments?per_page=100&page=$page"; then
      _PSC_V_WHY="the PR comments did not read (page $page, HTTP ${GH_REST_STATUS:-000})"; return 1
    fi
    n=$(jq -r 'if type == "array" then length else -1 end' <<<"$raw" 2>/dev/null)
    case "$n" in ''|-1) _PSC_V_WHY="the PR comments page $page is not a list"; return 1 ;; esac
    jq -r '.[] | (.user.login // "" | ascii_downcase) as $l | (.body // "" | gsub("\r"; "") | split("\n")[]) | [$l, .] | @tsv' <<<"$raw" 2>/dev/null \
      | awk -F'\t' -v A="$allow" 'BEGIN { n = split(A, L, "\n"); for (i = 1; i <= n; i++) if (L[i] != "") OK[L[i]] = 1 }
          ($1 in OK) { print }' >> "$out"
    [ "$n" -lt 100 ] && break
    page=$((page + 1))
  done
  return 0
}

psc_validate_check() {
  local repo="$1" base="$2" head="$3" body="$4" mode="$5" id="$6" rc=0 plan py out af ev max why
  local kind a b c d e skips="" nskip=0 owedwhy=""
  _psc_vsay() { case "$mode" in refuse) echo "REFUSE $id: $1"; rc=1 ;; note) echo "NOTE $id: $1" ;; esac; }
  plan=$(git -C "$repo" diff --no-renames --name-only "$base...$head" 2>/dev/null) || return 0
  plan=$(grep -E '^\.harness/specs/[^/]+/plan\.md$' <<<"$plan" | head -1)
  [ -n "$plan" ] || return 0
  git -C "$repo" cat-file -e "$head:$plan" 2>/dev/null || return 0
  py="$(_psc_v_dir)/plan-validate.py"
  command -v python3 >/dev/null 2>&1 && [ -r "$py" ] || { echo "NOTE $id: could not run (no python3 or no bin/lib/plan-validate.py)"; return 0; }
  max="${PLAN_VALIDATE_MAX_LINES:-60}"
  case "$max" in ''|*[!0-9]*) max=60 ;; esac
  # _psc_v_run [approvals-file] — the evaluator's lines into $out; rc its own.
  _psc_v_run() {
    local -a t=()
    # No __pycache__ beside bin/lib/plan-validate.py (BH-1138).
    export PYTHONDONTWRITEBYTECODE=1
    command -v timeout >/dev/null 2>&1 && t=(timeout 120)
    out=$(${t[@]+"${t[@]}"} python3 -I "$py" --repo "$repo" --head "$head" --plan-path "$plan" \
          --body "$body" --max "$max" ${1:+--approvals "$1"} 2>/dev/null)
  }
  if ! _psc_v_run; then echo "NOTE $id: could not run (the evaluator failed on $plan)"; return 0; fi
  if grep -qx NEEDAPPROVAL <<<"$out"; then
    af=$(mktemp "${TMPDIR:-/tmp}/psc-vappr.XXXXXX" 2>/dev/null) || af=""
    if [ -n "$af" ] && _psc_v_approvals "$af"; then
      ev="$out"
      owedwhy="no comment by a login in trigger.actors.$PSC_PROJECT approves it"
      _psc_v_run "$af" || { out="$ev"; owedwhy="the evaluator failed on the approvals"; }
    else
      owedwhy="${_PSC_V_WHY:-no temp file}"
    fi
    [ -n "$af" ] && rm -f "$af"
  fi
  while IFS=$'\t' read -r kind a b c d e; do
    case "$kind" in
      NONE) return 0 ;;
      OK) echo "NOTE $id: $a ok: \`$b\`" ;;
      OWED) echo "NOTE $id: $a owed (approved by $b)" ;;
      FAIL)
        why=""
        if [ "$e" = 1 ]; then why="; its owed: line is not approved${owedwhy:+ ($owedwhy)}"; fi
        _psc_vsay "$a: \`$b\` wants $c — got $d$why" ;;
      SKIP) nskip=$((nskip + 1)); skips="${skips:+$skips,}$a" ;;
      CAP) echo "NOTE $id: $a VALIDATE line(s) past the cap of $b were not read (PLAN_VALIDATE_MAX_LINES)" ;;
      NOTMET) _psc_vsay "body says not met: $a${owedwhy:+ (owed: not approved: $owedwhy)}" ;;
      TARGET) _psc_vsay "Target metric $a measured $b — not met${owedwhy:+ (owed: not approved: $owedwhy)}" ;;
      EXCUSED) echo "NOTE $id: the body's not-met and Target metric findings are owed (approved by $a for $b)" ;;
      INFO) echo "NOTE $id: $a" ;;
    esac
  done <<<"$out"
  [ "$nskip" -gt 0 ] && echo "NOTE $id: $nskip VALIDATE line(s) skipped (not a static check): $skips"
  return "$rc"
}
