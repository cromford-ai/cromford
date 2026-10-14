#!/bin/bash
# shellcheck shell=bash
# bin/lib/stack-wait.sh — a child launched onto its parent's OPEN branch
# (STACK_BASE) stacks only when its plan proves the two do not share a file.
# Sourced, never executed: no `set -e`, no `exit`, no output at source time.
#
# WHY. In the 7 days to 2026-10-13, 53% of the PRs stacked on an open parent
# had a merge conflict (plain PRs: 18%), and their median time to merge was
# 52.0h (plain: 12.4h). Under STACK_WAIT_PARENT_MERGE=plan (bin/lib/stale-parent.sh)
# the `stacked child builds` block of bin/lib/rb/gates.sh asks sw_pre before the
# plan, and the `stack plan check (BH-6389)` block at the top of rb_gate_overlap
# asks sw_post after it:
#
#   sw_pre   exempt   a hotfix child (HOTFIX=1): stack as before
#            wait     a `waiting` row under the cap: defer, no plan bought
#            capped   a `waiting` row at the cap (or a `capped` row): build from
#                     the base branch without the parent
#            pending  anything else: plan on the parent, then sw_post decides
#   sw_post  stack    the plan's `## Stack` files are disjoint from the parent's
#                     diff and plan files
#            defer    any other plan: the row goes `waiting`, one comment with
#                     `Blocked-by #<parent>` goes on the child issue
#
# When the parent merges, the `parent PR state (BH-6537)` sub-block of that
# gates.sh block reads its PR through REST (sw_parent_pr), so a merged or
# closed parent builds on main even when the repo keeps its branch
# (delete_branch_on_merge=false, TK-260); an unreadable state with a live
# branch waits. No row is read on the build-on-main path.
#
# THE ROW. `ledgers` kind `stack-wait`, key `<project> <KEY> <parent-branch>`,
# status waiting | stacked | capped, detail `since=<epoch> why=<text>`. `since`
# is the first deferral and is kept on every re-defer: it is the cap's clock.
# Its twin is the file $HARNESS/state/stack-wait/<project>/<KEY>.<parent, / as _>,
# read only when the ledger has no row or cannot answer.
#
# Kill switch: STACK_WAIT_PARENT_MERGE=rollouts (a settings row) restores the
# pre-BH-6389 stacking. The cap is STACK_WAIT_CAP_H (default 24).
# Knobs: catalog/lanes.d/_lib.stale-parent.json. Root: ${HARNESS:-${H:-}}.
# The jobs client (job_ledger_row / job_ledger_put) and gh_rest_comment are the
# caller's to load; without them every row read is an outage and every post
# fails, which is a defer, never a stack.

_SW_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_sw_root() { printf '%s' "${HARNESS:-${H:-}}"; }
sw_now()   { printf '%s\n' "${SW_NOW:-$(date +%s)}"; }

# sw_cap [project] — STACK_WAIT_CAP_H in hours (1..336, default 24).
sw_cap() {
  # shellcheck source=bin/lib/stale-parent.sh
  command -v sp_knob >/dev/null 2>&1 || . "$_SW_LIB/stale-parent.sh" 2>/dev/null
  local c=""
  command -v sp_knob >/dev/null 2>&1 && c=$(sp_knob STACK_WAIT_CAP_H "${1:-}" 2>/dev/null)
  case "$c" in ''|*[!0-9]*|0) c=24 ;; esac
  printf '%s\n' "$c"
}

# sw_pkey <branch> — the parent issue number from ticket/<prefix>-<n> or
# ticket/<prefix>-<n>-r<k>; empty for any other name.
sw_pkey() {
  [[ "${1:-}" =~ [a-z0-9]+-([0-9]+)(-r[0-9]+)?$ ]] && printf '%s\n' "${BASH_REMATCH[1]}"
  return 0
}

# sw_parent_pr <slug> <branch> — the state of the PR whose head is <branch>
#   (BH-6537), one REST read: `open|merged|closed <n> <url>`, `none` (no PR has
#   that head), `unreadable <rc>` (the read failed or the body is not a list),
#   or `unchecked` (no gh_rest in this shell, or no slug). Several PRs on one
#   head: open wins, then the newest merged, then the newest closed. rc 0.
sw_parent_pr() {
  local slug="${1:-}" br="${2:-}" f rc=0 out
  if ! command -v gh_rest >/dev/null 2>&1 || [ -z "$slug" ] || [ -z "$br" ]; then
    echo unchecked; return 0
  fi
  f=$(mktemp "${TMPDIR:-/tmp}/sw-parent-pr.XXXXXX") || { echo "unreadable 75"; return 0; }
  gh_rest GET "repos/$slug/pulls?state=all&head=${slug%%/*}:$br&per_page=100" > "$f" 2>/dev/null || rc=$?
  if [ "$rc" != 0 ]; then rm -f "$f"; echo "unreadable $rc"; return 0; fi
  out=$(jq -r 'if type != "array" then "unreadable 75"
      elif length == 0 then "none"
      else (map(select(.state == "open")) | sort_by(.number) | last) as $o
         | (map(select(.state != "open" and .merged_at != null)) | sort_by(.merged_at, .number) | last) as $m
         | (map(select(.state == "closed" and .merged_at == null)) | sort_by(.number) | last) as $c
         | if $o then "open \($o.number) \($o.html_url // "")"
           elif $m then "merged \($m.number) \($m.html_url // "")"
           elif $c then "closed \($c.number) \($c.html_url // "")"
           else "unreadable 75" end
      end' "$f" 2>/dev/null) || out="unreadable 75"
  rm -f "$f"
  printf '%s\n' "${out:-unreadable 75}"
  return 0
}

_sw_file() { # _sw_file <project> <KEY> <parent>
  local h; h=$(_sw_root); [ -n "$h" ] || return 1
  printf '%s/state/stack-wait/%s/%s.%s\n' "$h" "$1" "$2" "${3//\//_}"
}

# sw_row_get <project> <KEY> <parent> — prints "<status> <since-epoch>".
#   rc 1 when neither the ledger nor the file has a row.
sw_row_get() {
  local row st det since f
  if command -v job_ledger_row >/dev/null 2>&1 \
     && row=$(job_ledger_row stack-wait "$1 $2 $3" 2>/dev/null </dev/null); then
    st=$(printf '%s' "$row" | jq -r '.status // ""' 2>/dev/null)
    det=$(printf '%s' "$row" | jq -r '.detail // ""' 2>/dev/null)
    since=$(sed -n 's/^since=\([0-9][0-9]*\).*/\1/p' <<<"$det")
    if [ -n "$st" ]; then printf '%s %s\n' "$st" "${since:-0}"; return 0; fi
  fi
  f=$(_sw_file "$1" "$2" "$3") || return 1
  [ -s "$f" ] || return 1
  read -r st since _ < "$f" || [ -n "${st:-}" ] || return 1
  [ -n "$st" ] || return 1
  case "$since" in ''|*[!0-9]*) since=0 ;; esac
  printf '%s %s\n' "$st" "$since"
}

# sw_row_put <project> <KEY> <parent> <status> <since> <why> — the ledger row,
#   then the file. rc 0 when at least one of the two landed.
sw_row_put() {
  local rrc=1 frc=1 f
  command -v job_ledger_put >/dev/null 2>&1 \
    && job_ledger_put stack-wait "$1 $2 $3" "$4" "since=$5 why=$6" >/dev/null 2>&1 </dev/null && rrc=0
  if f=$(_sw_file "$1" "$2" "$3"); then
    mkdir -p "$(dirname "$f")" 2>/dev/null
    printf '%s %s %s\n' "$4" "$5" "$6" > "$f" 2>/dev/null && frc=0
  fi
  [ "$rrc" = 0 ] || [ "$frc" = 0 ]
}

# sw_pre <project> <KEY> <parent> — the pre-plan decision, one line:
#   exempt | wait <hours> <cap> | capped <hours> <cap> | pending.
#   A read outage is `pending`: the post-plan check still decides.
sw_pre() {
  local row st since now cap waited
  if [ "${HOTFIX:-}" = 1 ]; then echo exempt; return 0; fi
  cap=$(sw_cap "$1")
  row=$(sw_row_get "$1" "$2" "$3") || { echo pending; return 0; }
  read -r st since <<<"$row"
  now=$(sw_now)
  case "$since" in ''|*[!0-9]*) since="$now" ;; esac
  waited=$(( (now - since) / 3600 )); [ "$waited" -ge 0 ] || waited=0
  case "$st" in
    capped) echo "capped $waited $cap" ;;
    waiting)
      if [ "$since" -gt 0 ] && [ $(( now - since )) -ge $(( cap * 3600 )) ]; then
        echo "capped $waited $cap"
      else
        echo "wait $waited $cap"
      fi ;;
    *) echo pending ;;
  esac
}

# _sw_tokens — path tokens on stdin, one per line: a [A-Za-z0-9_@./-]+ run that
# contains `/` and ends in `.<ext>` (a file) or `/` (a directory). Absolute
# paths, `..` and range-like tokens are not repo files and are dropped.
_sw_tokens() {
  grep -oE '[A-Za-z0-9_@./-]+' \
    | sed -E 's/\.+$//; s#^\./##' \
    | grep -E '/' | grep -vE '^/|\.\.' \
    | grep -E '(\.[A-Za-z0-9]+|/)$' \
    | awk '!s[$0]++'
}

# _sw_stack_body <plan.md> — the lines of the `## Stack` section, outside ```
#   fences, up to the next heading. rc 1 when the plan has no such section.
_sw_stack_body() {
  awk '
    /^[[:space:]]*```/ { fence = !fence; next }
    fence { next }
    { sub(/\r$/, "") }
    /^#+([[:space:]]|$)/ {
      t = tolower($0)
      ins = (t ~ /^##[[:space:]]+stack[[:space:]]*$/)
      if (ins) found = 1
      next
    }
    ins { print }
    END { exit !found }' "$1" 2>/dev/null
}

# sw_stack_files <plan.md> — the child's files from its `## Stack` section.
#   The child's own .harness/specs/ plan is not a file it shares with anyone.
sw_stack_files() {
  _sw_stack_body "$1" | _sw_tokens | grep -v '^\.harness/specs/'
  return 0
}

# sw_plan_paths <plan.md|-> — every path token in a plan, skipping the
#   `## Sibling claims` and `## Verify` sections and VALIDATE: lines (the
#   skip rule bin/planned-files.sh uses for run-only and avoided paths).
sw_plan_paths() {
  awk '
    { sub(/\r$/, "") }
    /^##[[:space:]]/ {
      t = tolower($0)
      skip = (t ~ /^##[[:space:]]+sibling claims/ || t ~ /^##[[:space:]]+verify/)
      next
    }
    skip { next }
    /VALIDATE:/ { next }
    { print }' "${1:--}" 2>/dev/null | _sw_tokens
  return 0
}

# sw_parent_files <repo> <base> <parent> — the parent's diff over the base
#   (three-dot; two-dot, a superset, when there is no merge base) plus the
#   paths in every .harness/specs/*/plan.md that diff carries. rc 1 when no
#   diff form worked.
sw_parent_files() {
  local repo="$1" base="$2" parent="$3" d p
  d=$(git -C "$repo" diff --name-only "origin/$base...origin/$parent" 2>/dev/null) \
    || d=$(git -C "$repo" diff --name-only "origin/$base..origin/$parent" 2>/dev/null) \
    || return 1
  {
    [ -n "$d" ] && printf '%s\n' "$d"
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      git -C "$repo" show "origin/$parent:$p" 2>/dev/null | sw_plan_paths -
    done < <(grep -E '^\.harness/specs/[^/]+/plan\.md$' <<<"$d")
  } | awk 'NF && !s[$0]++'
}

# sw_overlap <child-list> <parent-list> — the first child path that is a parent
#   path, or sits under a parent directory, or is a directory over a parent
#   path. `bin/a.sh` vs `bin/a.sh.bak` and `bin/lib/` vs `bin/lib2/x.sh` do not.
sw_overlap() {
  awk '
    NR == FNR { if (NF) p[++n] = $0; next }
    NF {
      for (i = 1; i <= n; i++) {
        q = p[i]
        if ($0 == q \
            || (substr($0, length($0)) == "/" && index(q, $0) == 1) \
            || (substr(q, length(q)) == "/" && index($0, q) == 1)) { print; exit }
      }
    }' <(printf '%s\n' "$2") <(printf '%s\n' "$1")
}

# sw_post <build> <repo> <base> <parent> — the post-plan decision, one line:
#   stack <n-child> <n-parent> | defer <reason>.
sw_post() {
  local plan="$1/plan.md" c p o
  if [ ! -r "$plan" ] || ! _sw_stack_body "$plan" >/dev/null; then
    echo "defer the plan has no Stack section"; return 0
  fi
  c=$(sw_stack_files "$plan")
  [ -n "$c" ] || { echo "defer the Stack section lists no files"; return 0; }
  p=$(sw_parent_files "$2" "$3" "$4") || { echo "defer the parent's diff could not be read"; return 0; }
  o=$(sw_overlap "$c" "$p")
  [ -z "$o" ] || { echo "defer $o is in the parent's diff or plan"; return 0; }
  printf 'stack %s %s\n' "$(grep -c . <<<"$c")" "$(grep -c . <<<"$p")"
}

_sw_log() { # _sw_log <project> <KEY> <text>
  local h; h=$(_sw_root); [ -n "$h" ] || return 0
  mkdir -p "$h/logs" 2>/dev/null
  printf '%s [%s/%s] stack-wait: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$1" "$2" "$3" >> "$h/logs/stack-wait.log" 2>/dev/null
  return 0
}

# sw_note <project> <KEY> <parent> <reason> <build> — one comment per
#   (KEY, parent) on the child issue, GitHub-issue projects only. Every path
#   returns 0: a skipped or failed post is one logs/stack-wait.log line, and
#   the marker is written only after a 2xx, so the next defer retries it.
sw_note() {
  local project="$1" key="$2" parent="$3" why="$4" build="$5" h n num slug mkey mfile cap body rc=0
  h=$(_sw_root); [ -n "$h" ] || return 0
  if [ "$("$h/bin/fleet-conf.sh" "$project" board_prefix 2>/dev/null)" != "-" ]; then
    _sw_log "$project" "$key" "comment=skipped parent=$parent (board project)"; return 0
  fi
  n=$(sw_pkey "$parent"); num="${key##*-}"
  case "$n:$num" in
    :*|*:|*:*[!0-9]*) _sw_log "$project" "$key" "comment=skipped parent=$parent (no issue number)"; return 0 ;;
  esac
  slug=$("$h/bin/fleet-conf.sh" "$project" repo 2>/dev/null)
  [ -n "$slug" ] || { _sw_log "$project" "$key" "comment=failed parent=$parent reason=no-repo"; return 0; }
  # shellcheck source=bin/lib/comment-mark.sh
  command -v cm_has >/dev/null 2>&1 || . "$_SW_LIB/comment-mark.sh" 2>/dev/null
  mkey="stack-wait $project $key:$parent"
  mfile="$h/state/comment-marks/stack-wait/$project/$key.${parent//\//_}"
  if command -v cm_has >/dev/null 2>&1 && cm_has "$mkey" - "$mfile"; then
    _sw_log "$project" "$key" "comment=already parent=$parent"; return 0
  fi
  cap=$(sw_cap "$project")
  body=$(mktemp "${TMPDIR:-/tmp}/stack-wait.XXXXXX") || return 0
  printf 'Holding this one until #%s merges. Its plan builds on #%s'"'"'s open branch, and %s. It starts from main on the first tick after #%s merges, or after %s hours at the latest.\n\nBlocked-by #%s\n\n<!-- stack-wait:%s:%s -->\n' \
    "$n" "$n" "$why" "$n" "$cap" "$n" "$key" "$n" > "$body"
  if command -v gh_rest_comment >/dev/null 2>&1; then gh_rest_comment "$slug" "$num" "$body" || rc=$?; else rc=127; fi
  if [ "$rc" != 0 ]; then
    _sw_log "$project" "$key" "comment=failed rc=$rc parent=$parent"; rm -f "$body"; return 0
  fi
  # The build's own note, so the plan thread gate never refuses its plan on it.
  # shellcheck source=bin/lib/plan-thread.sh
  command -v ptg_own_post >/dev/null 2>&1 || . "$_SW_LIB/plan-thread.sh" 2>/dev/null
  command -v ptg_own_post >/dev/null 2>&1 && ptg_own_post "$build" "$body"
  if command -v cm_put >/dev/null 2>&1 && cm_put "$mkey" - "$mfile"; then
    _sw_log "$project" "$key" "comment=posted parent=$parent"
  else
    _sw_log "$project" "$key" "comment=posted-unmarked parent=$parent"
  fi
  rm -f "$body"
  return 0
}

# sw_plan_note <build> — the planner rule, one line, only while the build's
#   stack-wait-pending file exists (line 1 the parent branch, then its files).
sw_plan_note() {
  local f="${1:-}/stack-wait-pending" parent files
  [ -s "$f" ] || return 0
  parent=$(head -n 1 "$f")
  files=$(tail -n +2 "$f" | awk 'NF' | head -n 40 | paste -sd, - | sed 's/,/, /g')
  printf 'THIS CHILD IS PLANNED ON THE OPEN PARENT BRANCH %s. It goes on to execute only if plan.md has a "## Stack" section that lists every file this child edits or creates, one path per line, and none of them is in the parent'"'"'s files (%s). Without that section the build is deferred and the child builds from main after the parent merges. Write the section only when the files are truly disjoint.' \
    "$parent" "${files:-none listed}"
}
