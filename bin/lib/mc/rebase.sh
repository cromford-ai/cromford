#!/bin/bash
# shellcheck shell=bash
# module: rebase after: queue
# bin/lib/mc/rebase.sh — BH-477: stacked bases, git auth, mc_rebase/mc_restack, generated-path resolution, mc_rereview, the detached re-review/rebase/deploy-verify lanes, the merge funnel. Sourced by bin/lib/merge-conductor-lib.sh, never run.
# THE DECISION READS GO THROUGH REST (BH-784), and the marker below is what
# tests/gh-no-graphql-decision-guard-test.sh scans this file for. It moved here
# with the code when BH-477.3 emptied bin/lib/merge-conductor-lib.sh: the lib
# carried the marker while it carried these calls, and a module holding them
# unmarked would be a call site the guard silently stopped policing.
# gh-rest: no-graphql
# BH-8150: pass-through stubs for a caller that sources this module without
# mc/log.sh. mc/log.sh's stubs, or the real bin/lib/pr-record-write.sh, load
# first in every other caller, so these never fire there.
type prr_write >/dev/null 2>&1 || prr_write() { shift 4; "$@"; }
type prr_note_push >/dev/null 2>&1 || prr_note_push() { return 0; }
type prr_now >/dev/null 2>&1 || prr_now() { :; }


# --- Generated-files table parser (BH-968) -----------------------------------
# mc_regen_table <dir> <ref> -> "<path-or-glob>\t<command>" per line, from the
#   repo's own "generated files" table at the given ref. THREE homes, in order:
#   AGENT_ARCHITECTURE.md (where target repos keep it),
#   docs/verification-map/README.md (a target repo that still commits its index)
#   and docs/verification-map/index/tail.md (cromford's own home since
#   BH-1175 took the generated README out of git — `git show <ref>:<path>` says
#   nothing about a file that is not in the tree, so without this third home the
#   table reads EMPTY and every regenerate rung silently stops running). Cells
#   are markdown, so backticks come off; separator/header rows and path cells
#   with no slash or dot are skipped. Deduped, so a repo carrying both the README
#   and its source does not declare every row twice. Missing git/dir/ref returns
#   empty, no writes.
# BH-4080: the merge identity's defaults live in the deployment defaults home.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-${BASH_SOURCE[0]%/*}/../deployment.sh}" || return 1
# BH-4659: branch tips from one refs read per prefix (prs_branch_tip, sourced
# by mc/snapshot-refs.sh). Optional: every caller below checks
# `command -v prs_branch_tip`, and a miss probes live as before.

mc_regen_table() {
  local dir="${1:-.}" ref="${2:-HEAD}" f
  for f in AGENT_ARCHITECTURE.md docs/verification-map/README.md docs/verification-map/index/tail.md; do
    git -C "$dir" show "$ref:$f" 2>/dev/null | awk '
      tolower($0) ~ /^#+[ \t]*.*generated files/ { sec=1; next }
      sec && /^#+ / { exit }
      sec && /^\|/ {
        line = $0
        sub(/^\|/, "", line)
        n = split(line, c, "|")
        if (n < 2) next
        p = c[1]; cmd = c[2]
        gsub(/`/, "", p);   gsub(/^[ \t]+|[ \t]+$/, "", p)
        gsub(/`/, "", cmd); gsub(/^[ \t]+|[ \t]+$/, "", cmd)
        if (p == "" || cmd == "") next
        if (p ~ /^-+$/ || cmd ~ /^-+$/) next
        if (p !~ /[\/.]/) next
        print p "\t" cmd
      }'
  done | awk 'NF && !seen[$0]++'
}

# mc_regen_generated <worktree> <ref> <label> — after a merge of <ref> into
#   <worktree>, run the repo's OWN regenerate commands over the merged tree and
#   commit the declared paths as ONE extra commit when (and only when) the
#   output differs. BH-969: mc_rebase and the pool twin merged origin/main and
#   went straight to the gates, so a branch carrying a stale generated file was
#   pushed still stale and CI's drift step failed the PR for a file no ticket is
#   about. bin/batch-resolve.sh already did this over a union; this is the same
#   deferred regenerate for the rebase paths.
#
#   ALWAYS rc 0. The regenerate is best-effort: a repo's docs generator having a
#   bad day must not turn into a blocked rebase, and the local gates plus CI's
#   own drift check stay the arbiters. A FAILING command is logged, its partial
#   writes are dropped (so a half-regenerated tree can never be committed) and
#   the remaining commands are abandoned.
#
#   The table is read from the BASE <ref>, never the branch head, so the command
#   STRING is the one main declares and a PR cannot introduce a new one in its
#   own diff. The script that string names still runs from the MERGED tree, so
#   this is the same trust level as the gates — not a sandbox. Mirrors
#   batch-resolve's show_base.
mc_regen_generated() {
  local wt="${1:-}" ref="${2:-HEAD}" label="${3:-rebase}"
  local table cmds cmd out paths p
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  table=$(mc_regen_table "$wt" "$ref")
  # A repo that declares nothing behaves exactly as it did before BH-969: no
  # command, no commit, nothing logged.
  [ -n "$table" ] || return 0
  cmds=$(printf '%s\n' "$table" | cut -f2- | awk 'NF && !seen[$0]++')
  paths=$(printf '%s\n' "$table" | cut -f1 | awk 'NF && !seen[$0]++')
  [ -n "$cmds" ] || return 0
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    out=$(mktemp "${TMPDIR:-/tmp}/mc-regen-XXXX")
    # `eval` of a string out of the repo's own markdown is the same trust level
    # as running that repo's test suite, which the gates below do; both are the
    # repo telling us how to build it. 9>&- : a command that leaves a background
    # process behind would otherwise hold this lane's dedupe flock for that
    # process's whole life (the same reason build_union closes it).
    # </dev/null : this loop reads $cmds on stdin, so a generator that reads
    # stdin at all would swallow the remaining commands and they would silently
    # never run.
    if ! ( cd "$wt" && eval "$cmd" ) >"$out" 2>&1 9>&- </dev/null; then
      mc_log "$label regenerate FAILED: $cmd — $(tail -3 "$out" | tr '\n' ' ' | cut -c1-300)"
      rm -f "$out"
      # drop the partial writes: a half-regenerated file is worse than a stale one
      git -C "$wt" checkout -q -- . >/dev/null 2>&1
      return 0
    fi
    rm -f "$out"
  done <<<"$cmds"
  # Only the DECLARED paths are staged. `git add -A` here would sweep any stray
  # output a generator happens to leave into a PR nobody reviewed for it.
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    git -C "$wt" add -A -- "$p" >/dev/null 2>&1 || true
  done <<<"$paths"
  git -C "$wt" diff --cached --quiet >/dev/null 2>&1 && return 0
  git -C "$wt" -c user.name="${MC_GIT_NAME:-$HARNESS_MERGE_GIT_NAME}" -c user.email="${MC_GIT_EMAIL:-$HARNESS_GIT_EMAIL}" \
      -c commit.gpgsign=false commit -q -m "regenerate $(printf '%s' "$paths" | tr '\n' ' ' | sed 's/ *$//') after rebase onto $ref" >/dev/null 2>&1 \
    || { mc_log "$label regenerate: the regenerated files would not commit"; git -C "$wt" reset -q >/dev/null 2>&1; }
  return 0
}

# --- CONTESTED HOLDS (BH-579) ------------------------------------------------
# TK-1529 was rebuilt three times on a scheduling problem: sibling tickets kept
# landing edits to one file, and each rebuild hit the same conflict. A CONTESTED
# HOLD says who won a contested path, so the losers can be parked and released
# together instead of each one racing the others through a rebuild.
#
# THE STORE. Natural key is (project, path) — one hold per contested path per
# project, so two projects touching the same path keep separate holds by
# construction. File: state/contested/<project>/<sha1(path)[0:16]>, JSON:
#   {project, repo, path, winner_key, winner_url,
#    loser_prs:[{num,url,key}], loser_tickets:[key], created:<epoch>, ttl:<secs>, why}
# Writes are tmp + rename, so last write wins and a reader never sees half a
# hold. LIVENESS IS DECIDED PER READ (created + ttl vs now), never by a sweep:
# an expired hold is inert the instant it expires even if nobody deletes it, and
# a malformed one is treated as not live rather than as a crash.
#
# CONTESTED_TTL (default 21600 = 6h) is the hold's window. Unlike the MC_*_SECS
# caps above — which are captured once, at SOURCE time — it is read from the
# environment AT CALL TIME, deliberately: the lane that writes holds
# (bin/blocked-resolver.sh) exports it after sourcing this file, and a cap
# captured at source time would ignore it. env/global.env is where a box sets it.
#
# THE SIDECAR. state/merge-conductor/conflict-size/<safe-slug>_<num> =
# `<lines>\t<head>\t<paths space-joined>`, written by mc_rebase when it hands
# back rc 1 (last write wins, best effort: a failed write can never change that
# rc). <lines> is the MARKER-BOUNDED count over the paths still unmerged at that
# moment, so a generated path mc_resolve_conflicts already resolved and staged
# is not counted, while <paths> is the full list the caller is handed — the two
# fields can differ by exactly those resolved paths.
#
# THE POOL ARM WRITES NO SIDECAR. Under REBASE_ON_POOL=1 (ships OFF — nothing
# rebases on a pool yet) mc_rebase returns from mc_pool_rebase_enqueue before
# this block, so the conductor-side measurement is never written and br_shape
# reads UNMEASURED = large, which is today's ladder and the safe direction. The
# resolver's own fix-round tree still measures. Whoever turns the pool on owns
# carrying the measurement back with the job's result.
#
# WHO USES IT. bin/blocked-resolver.sh (BH-588) is the production writer: it
# writes the hold, parks the losers as `contested:<path> (winner <KEY>)` and
# sweeps the holds it wrote. The remaining siblings of BH-579 are #589 (the
# conductor's own loser park and settle release), #590 (the launch gate) and
# #591 (the decomposer).
#
# WHAT THE HOLD DOES NOT DO, UNTIL #589. `contested*` is deliberately not a
# sticky hand-off reason (mc_handoff_owns), so the conductor does not freeze a
# loser's row: its next tick re-derives the row from GitHub state and may rebase
# it, or merge it if it is clean and approved. The hold binds the RESOLVER lane
# — the loser skip in br_one spends no rung and no API call on a held PR — and
# #589 is what makes it bind the conductor as well.
mc_contested_dir()  { printf '%s/%s' "$MC_CONTESTED_DIR" "$(mc_safe_name "${1:-}")"; }
mc_contested_file() { printf '%s/%s' "$(mc_contested_dir "${1:-}")" "$(printf '%s' "${2:-}" | sha1sum | cut -c1-16)"; }

# mc_contested_write <project> <slug> <path> <winner_key> <winner_url>
#                    <loser_prs_json> <loser_tickets_json> [ttl] [why]
#   rc 0 and the hold on disk, or rc 1 and NO file: a mkdir, a malformed loser
#   list, a non-numeric ttl or a failed rename all leave the store as it was.
mc_contested_write() {
  local project="${1:-}" slug="${2:-}" path="${3:-}" wkey="${4:-}" wurl="${5:-}"
  local lprs="${6:-[]}" ltix="${7:-[]}" ttl="${8:-}" why="${9:-}" dir tmp
  [ -n "$project" ] && [ -n "$path" ] || return 1
  ttl="${ttl:-${CONTESTED_TTL:-21600}}"
  dir=$(mc_contested_dir "$project")
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp=$(mktemp "$dir/.tmp.XXXXXX" 2>/dev/null) || return 1
  if ! jq -nc --arg project "$project" --arg repo "$slug" --arg path "$path" \
       --arg winner_key "$wkey" --arg winner_url "$wurl" --arg why "$why" \
       --argjson loser_prs "${lprs:-[]}" --argjson loser_tickets "${ltix:-[]}" \
       --argjson created "$(mc_now)" --argjson ttl "$ttl" \
       '{project:$project,repo:$repo,path:$path,winner_key:$winner_key,winner_url:$winner_url,
         loser_prs:$loser_prs,loser_tickets:$loser_tickets,created:$created,ttl:$ttl,why:$why}' \
       > "$tmp" 2>/dev/null; then
    rm -f "$tmp"; return 1
  fi
  mv -f "$tmp" "$(mc_contested_file "$project" "$path")" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

# mc_contested_list <project> -> every hold file, one path per line. Silent rc 0
#   when the project has never had one. The dot-file skip keeps a write that is
#   in flight (.tmp.XXXXXX in the same dir, for the rename) out of the listing.
mc_contested_list() {
  local dir; dir=$(mc_contested_dir "${1:-}")
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -type f ! -name '.*' 2>/dev/null
  return 0
}

# mc_contested_live <file> -> rc 0 only for a hold that parses as an object with
#   an all-digit created and ttl and is still inside its window. Anything else —
#   absent, empty, `not json`, an array, a string ttl — is NOT live.
mc_contested_live() {
  local f="${1:-}" both created ttl
  [ -s "$f" ] || return 1
  both=$(jq -r 'select(type=="object")|"\(.created)\t\(.ttl)"' "$f" 2>/dev/null) || return 1
  created=$(cut -f1 <<<"$both"); ttl=$(cut -f2 <<<"$both")
  case "$created" in ''|*[!0-9]*) return 1 ;; esac
  case "$ttl"     in ''|*[!0-9]*) return 1 ;; esac
  [ "$(( $(mc_now) - created ))" -lt "$ttl" ]
}

# mc_contested_loser <project> <slug> <num> [skip-file] -> `path<TAB>winner_key`
#   per live hold of that repo listing this PR as a loser, rc 0 if any. Silent
#   rc 1 otherwise: unlisted PR, expired hold, another repo, no dir at all.
#   The number is compared as a STRING after tostring, so a caller passing 41 and
#   one passing "41" hit the same hold.
#   SKIP-FILE is one hold to ignore, and it exists for mc_contested_release:
#   the file being released is still on disk while its losers are handed back
#   (rows first, file last), so "is anybody ELSE still holding this PR" has to be
#   asked with that one hold excluded.
mc_contested_loser() {
  local project="${1:-}" slug="${2:-}" num="${3:-}" skip="${4:-}" f out hit=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -n "$skip" ] && [ "$f" = "$skip" ] && continue
    mc_contested_live "$f" || continue
    out=$(jq -r --arg r "$slug" --arg n "$num" \
      'select(.repo==$r and any((.loser_prs//[])[]?; (.num|tostring)==$n)) | "\(.path)\t\(.winner_key)"' \
      "$f" 2>/dev/null) || continue
    [ -n "$out" ] || continue
    printf '%s\n' "$out"; hit=1
  done < <(mc_contested_list "$project")
  [ -n "$hit" ]
}

# mc_contested_wins <project> <KEY> -> rc 0 when a live hold names KEY the winner.
mc_contested_wins() {
  local project="${1:-}" key="${2:-}" f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    mc_contested_live "$f" || continue
    [ "$(jq -r 'select(type=="object")|.winner_key // empty' "$f" 2>/dev/null)" = "$key" ] && return 0
  done < <(mc_contested_list "$project")
  return 1
}

# mc_contested_release <file> <why> [alert] — end a hold and hand its losers back.
#   ROWS FIRST, FILE LAST, log and alert after that: a crash mid-release leaves
#   the hold on disk, and the next call skips the rows it already moved (their
#   reason is no longer contested*) and finishes the rest. "Stamped released
#   without the rows moving" is impossible by construction.
#   A loser whose row is absent, is not BLOCKED_HUMAN (MERGED, ABANDONED, …) or
#   is parked on some OTHER reason is left exactly as it is: that park belongs to
#   whoever made it. Idempotent — a second call on a missing file is a silent
#   rc 0. Always rc 0.
#
#   A PR CAN LOSE TWICE, SO A RELEASE IS NOT ENOUGH ON ITS OWN. One PR touching
#   two contested files is a loser on two holds, and its row carries only one of
#   those paths, so "the reason starts with contested" cannot tell the two apart.
#   A row is therefore released only when NO OTHER LIVE HOLD still names that PR
#   as a loser — asked with THIS hold excluded, because rows move before the file
#   is removed. Unparking it while another hold is live hands the conductor a PR
#   that rebases straight back into a path somebody else is still landing: the
#   same wasted rebuild, on the same conflict, this mechanism exists to stop.
#   The last hold to release is the one that unparks it, whichever path its own
#   park names — so a row can never be orphaned by the order the holds end in.
mc_contested_release() {
  local f="${1:-}" why="${2:-}" alert="${3:-}"
  local repo wkey path project nums="" n u key row st reason head rev rurl
  [ -s "$f" ] || { rm -f "$f" 2>/dev/null; return 0; }
  IFS=$'\t' read -r repo wkey path project < <(jq -r 'select(type=="object")|"\(.repo)\t\(.winner_key)\t\(.path)\t\(.project)"' "$f" 2>/dev/null)
  [ -n "${path:-}" ] || { rm -f "$f" 2>/dev/null; return 0; }
  while IFS=$'\t' read -r n u; do
    [ -n "$n" ] || continue
    nums="${nums:+$nums,}$n"
    key="$repo#$n"
    row=$(mc_row_get "$key"); [ -n "$row" ] || continue
    st=$(cut -f2 <<<"$row"); [ "$st" = BLOCKED_HUMAN ] || continue
    reason=$(cut -f7 <<<"$row"); case "$reason" in contested*) ;; *) continue ;; esac
    if [ -n "${project:-}" ] && [ "$project" != null ] \
       && mc_contested_loser "$project" "$repo" "$n" "$f" >/dev/null 2>&1; then
      mc_log "contested: $key stays parked — another live hold still names it (this release was $path)"
      continue
    fi
    head=$(cut -f4 <<<"$row"); rev=$(cut -f5 <<<"$row"); rurl="$u"
    case "$rurl" in ''|-|null) rurl=$(cut -f8 <<<"$row") ;; esac
    mc_transition "$key" NEEDS_REBASE "contested released: $why" "$head" "$rev" "$rurl" - - - >/dev/null
    mc_handoff_release "$key" contested-release
  done < <(jq -r 'select(type=="object")|(.loser_prs//[])[]?|"\(.num)\t\(.url // "-")"' "$f" 2>/dev/null)
  rm -f "$f" 2>/dev/null
  mc_log "contested hold on $path released — winner $wkey, losers ${nums:-none}: $why"
  [ "$alert" = alert ] && mc_alert "$repo" contested "hold on $path released — winner $wkey, losers ${nums:-none}, why: $why"
  return 0
}

# mc_conflict_lines <tree> -> the size of the conflict in a worktree that has one:
#   the lines from `<<<<<<< ` through `>>>>>>> ` inclusive, summed over every
#   unmerged path. NOT `git diff | wc -l`, which counts the context around the
#   markers too and answers a number that grows with the file rather than with
#   the disagreement. 0 for a clean tree, a path that is no tree, or a file this
#   process cannot read — never a crash, never noise on stdout.
mc_conflict_lines() {
  local tree="${1:-}" p n total=0
  [ -n "$tree" ] || { printf '0\n'; return 0; }
  while IFS= read -r p; do
    [ -n "$p" ] && [ -r "$tree/$p" ] || continue
    n=$(awk '/^<<<<<<< /{b=1} b{n++} /^>>>>>>> /{b=0} END{print n+0}' "$tree/$p" 2>/dev/null) || n=0
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    total=$(( total + n ))
  done < <(git -C "$tree" diff --name-only --diff-filter=U 2>/dev/null)
  printf '%s\n' "$total"
}
# mc_conflict_size_file <owner/repo> <num> -> the sidecar path for one PR.
mc_conflict_size_file() { printf '%s/%s_%s' "$MC_CONFLICT_SIZE_DIR" "$(mc_safe_name "${1:-}")" "${2:-}"; }

# --- Stacked child PRs (2026-09-14) ------------------------------------------
# A child ticket whose Blocked-by parent has an OPEN PR is built ON TOP of that
# PR's branch (bin/run-build.sh, STACK_BASE), so its PR's base is a feature
# branch rather than the project's. These three answer what the conductor has to
# know about that: which base is the right one, what the parent is doing, and
# how to retarget when GitHub does not do it for us.

# mc_project_base <project> -> the branch this project's PRs merge INTO.
#   Repos whose default branch is not main set BASE_BRANCH in their project env
#   — the same file and the same variable bin/run-build.sh reads — so the two
#   sides of this comparison can never disagree. Anything unreadable is main,
#   which is what every project in the fleet actually uses today.
mc_project_base() {
  local p="${1:-}" b=""
  [ -n "$p" ] || { echo main; return; }
  b=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}BASE_BRANCH=//p' "$MC_H/env/$p.env" 2>/dev/null | tr -d "\"'" | head -n 1)
  case "$b" in ''|*[!A-Za-z0-9._/-]*) b=main ;; esac
  echo "$b"
}

# mc_base_guard <project-base> <list-base> <fresh-base>
#   rc 0 = a merge or an enqueue of this PR may proceed.
#   rc 1 = REFUSE, and stdout is the base that is wrong.
#
# THE SECOND CHECK, AND IT READS NO LABEL AND NO LIST COLUMN IT CANNOT SEE
# (BH-410). The classifier already parks a stacked child — MC_STACK=wait, ahead
# of every other clause — but that test is `[ -n "$BASEREF" ]`, so it abstains
# exactly when the PR list loses the base column, which is what the collapsed
# tsv did to every harness PR until #342. The list is belt; this is braces: it
# is called at the merge action itself, where the only question left is "does
# `gh pr merge` land this INTO the project's base or into somebody's feature
# branch", and it is fed BOTH the list's answer and a base read fresh from
# GitHub in the same pre-action `gh pr view` the arm already makes.
#
# Either source that KNOWS a base and says it is not the project's refuses. A
# source that knows nothing ABSTAINS rather than refusing: `-` is the tsv's
# placeholder for absent and an empty fresh read is an older gh or a field
# GitHub did not return, and neither is evidence that the base is wrong.
# Two abstentions therefore proceed — today's behaviour, and what every
# conductor fixture that omits baseRefName runs on. GitHub never answers a null
# baseRefName for a real PR, so fail-closed-on-empty would buy nothing here and
# would park PRs on a gh field-name change.
#
# The FRESH read outranks the list, which is why it is tested first: the list
# was read at the top of the tick and may be minutes old, and a parent that
# merged in between is exactly when GitHub retargets a child.
mc_base_guard() {
  local pb="${1:-}" lb="${2:-}" fb="${3:-}"
  [ "$lb" = "-" ] && lb=""
  [ "$fb" = "-" ] && fb=""
  [ -n "$pb" ] || pb=main
  if [ -n "$fb" ] && [ "$fb" != "$pb" ]; then printf '%s' "$fb"; return 1; fi
  if [ -n "$lb" ] && [ "$lb" != "$pb" ]; then printf '%s' "$lb"; return 1; fi
  return 0
}

# mc_stack_parent <owner/repo> <base-ref> -> "<state>\t<url>"
#   The PR whose HEAD is <base-ref>, i.e. the parent this PR is stacked on.
#   state is OPEN | MERGED | CLOSED | NONE (no PR on that branch at all).
#   A read that fails answers NONE, and the caller treats NONE as "keep
#   waiting" — never as a reason to merge or to park.
#   MC_STACK_PARENT_ANS (BH-3950), when it names a file, gets what the read
#   ACTUALLY said: `none` only for a read that succeeded with no PR on that
#   head, `HTTP <status>[ <reason>]` for a read that failed, `unparseable` for a
#   200 that was not a list. stack_parent_memo runs this in a subshell, so the
#   stdout word and GH_REST_STATUS cannot carry that split; the file can, and
#   the NONE arm acts only on `none`. A file nobody wrote reads as unreadable.
mc_stack_parent() {
  local slug="${1:-}" br="${2:-}" out list="" rc=0
  [ -n "$slug" ] && [ -n "$br" ] || { printf 'NONE\t-'; return; }
  # REST spells `head` as owner:branch. A read that failed answers NONE, exactly
  # as the GraphQL one did.
  # THE RC IS READ BEFORE THE JSON, not lost in a pipeline. NONE is the same
  # answer either way — the caller's NONE arm is "keep waiting" — but "there is
  # no parent PR" and "GitHub would not tell us" are two different facts, and
  # the second one is the whole subject of this change, so it says so in the log.
  # BH-1485: the `_var` variant, never `list=$(gh_rest_pr_list …)`. The capture
  # was a subshell, so GH_REST_STATUS died inside it and this line said HTTP 000
  # for every 403 — through a measurably exhausted hourly quota a rate limit, a
  # 5xx and a dead network read identically here and in ALERTS.log, and the
  # diagnosis needed a manual `rate_limit` call from the box.
  gh_rest_pr_list_var list "$slug" all "${slug%%/*}:$br" 1 2>/dev/null || rc=$?
  if [ "$rc" != 0 ]; then
    mc_log "stack-parent read for $slug head $br UNVERIFIABLE (HTTP ${GH_REST_STATUS:-000}${GH_REST_REASON:+ $GH_REST_REASON}) — answering NONE, which keeps the child waiting"
    [ -n "${MC_STACK_PARENT_ANS:-}" ] && printf 'HTTP %s%s' "${GH_REST_STATUS:-000}" "${GH_REST_REASON:+ $GH_REST_REASON}" > "$MC_STACK_PARENT_ANS" 2>/dev/null
    printf 'NONE\t-'; return
  fi
  out=$(printf '%s' "$list" \
        | jq -r 'if length == 0 then "NONE\t-"
                 else (.[0] | [(if (.merged_at // null) != null then "MERGED"
                                elif .state == "open" then "OPEN" else "CLOSED" end),
                               (.html_url // "-")] | @tsv) end' 2>/dev/null)
  if [ -n "${MC_STACK_PARENT_ANS:-}" ]; then
    case "$out" in
      NONE*) printf 'none' > "$MC_STACK_PARENT_ANS" 2>/dev/null ;;
      '')    printf 'unparseable' > "$MC_STACK_PARENT_ANS" 2>/dev/null ;;
    esac
  fi
  [ -n "$out" ] || out=$(printf 'NONE\t-')
  printf '%s' "$out"
}

# mc_branch_exists <owner/repo> <branch> -> rc 0 present | 1 GitHub answered 404
#   | 2 unreadable (403, 5xx, a network failure, a 200 that does not parse, or a
#   name mc_ref_ok refuses). A plain command into a FILE, never `$( )`, so
#   GH_REST_STATUS is still in the caller's shell (head_lag_tip's shape).
mc_branch_exists() {
  local slug="${1:-}" br="${2:-}" f rc=0 name
  [ -n "$slug" ] && mc_ref_ok "$br" || return 2
  # A refs hit is "present" with no probe (BH-4659). A miss probes, so rc 1
  # ("gone") is still only ever a live 404.
  command -v prs_branch_tip >/dev/null 2>&1 && prs_branch_tip "$slug" "$br" >/dev/null 2>&1 && return 0
  f=$(mktemp "${TMPDIR:-/tmp}/mc-branch.XXXXXX") || return 2
  gh_rest GET "repos/$slug/branches/$br" > "$f" 2>/dev/null || rc=$?
  if [ "$rc" != 0 ]; then
    rm -f "$f"
    [ "${GH_REST_STATUS:-000}" = 404 ] && return 1
    return 2
  fi
  name=$(jq -r '.name // empty' "$f" 2>/dev/null); rm -f "$f"
  [ -n "$name" ] && return 0
  return 2
}

# mc_stack_parent_key <branch> -> the ticket key that branch was built for:
#   `agent/<KEY>` gives KEY, `ticket/<k>[-rN]` gives k uppercased without the
#   rebuild suffix, anything else prints nothing. The NONE arm hands it to
#   open_pr_for_key (bin/lib/open-pr-precheck.sh, BH-3948), so a parent that is
#   open under the OTHER head shape keeps its child waiting.
mc_stack_parent_key() {
  local br="${1:-}" k
  case "$br" in
    agent/?*)  k="${br#agent/}" ;;
    ticket/?*) k="${br#ticket/}"
               case "$k" in *-r[0-9]|*-r[0-9][0-9]) k="${k%-r*}" ;; esac
               k="${k^^}" ;;
    *) return 0 ;;
  esac
  case "$k" in ''|*[!A-Za-z0-9-]*) return 0 ;; esac
  printf '%s' "$k"
}

# mc_parent_pr_open <owner/repo> <KEY> — open_pr_for_key (bin/lib/open-pr-precheck.sh,
#   the BH-3948 contract), same rc and stdout: 0 `#N` open | 1 verified none |
#   2 unreadable. Loaded on first use, not at source time: by then gh-rest.sh is
#   in, so the contract lib does not source it a second time over a caller's
#   stubs. A box without the file answers 2, and the NONE arm waits.
mc_parent_pr_open() {
  command -v open_pr_for_key >/dev/null 2>&1 \
    || { [ -r "${MC_LIB_DIR:-}/../open-pr-precheck.sh" ] && . "$MC_LIB_DIR/../open-pr-precheck.sh"; } 2>/dev/null
  command -v open_pr_for_key >/dev/null 2>&1 || return 2
  open_pr_for_key "$@"
}

# HOW MANY REBUILDS DEEP TO LOOK FOR A LIVE PARENT (BH-458). A ticket rebuilt
# by bin/blocked-resolver.sh cuts `ticket/<key>-r2`, then `-r3`, and the ladder
# caps at three rebuilds — so six is already past anything the fleet produces
# and the probe is bounded whatever a repo's history looks like.
MC_RETRY_MAX="${MC_RETRY_MAX:-6}"

# mc_retry_pr <owner/repo> <dead-base-ref> -> "<state>\t<url>\t<branch>"
#   The NEWEST rebuild of the ticket whose branch is <dead-base-ref>: the PR on
#   `ticket/<key>-rN` for the highest N above the one the dead base already
#   carries. state is OPEN | MERGED | CLOSED | NONE, and NONE (no rebuild in
#   flight, or a read that failed) means the caller parks exactly as it did
#   before this existed.
#
#   WHY THIS IS A PROBE AND NOT ONE LIST CALL. `gh pr list --head` matches a
#   branch exactly, and the search qualifier that would match a prefix is not a
#   promise GitHub documents. Listing the repo's PRs and filtering locally reads
#   a page of PRs to answer a question about at most five branch names, and it
#   is wrong the moment the retry is older than the page. This asks by name,
#   highest first, and stops at the first hit — so the common answer costs one
#   call and the worst case costs MC_RETRY_MAX-1. It only runs for a stacked
#   child whose parent PR is CLOSED, which is rare.
#
#   The search starts ABOVE the base's own generation: a child sitting on
#   `-r2` must never be handed `-r2` back, which is the branch that just died.
#   A newest generation that is itself CLOSED means the rebuild ladder has moved
#   on again (or run out): the caller parks, and the tick that runs after the
#   next `-rN` appears finds it.
mc_retry_pr() {
  local slug="${1:-}" base="${2:-}" stem cur n st url
  [ -n "$slug" ] && [ -n "$base" ] || { printf 'NONE\t-\t-'; return; }
  stem="$base"; cur=1
  case "$base" in
    *-r[0-9]|*-r[0-9][0-9]) stem="${base%-r*}"; cur="${base##*-r}" ;;
  esac
  case "$cur" in ''|*[!0-9]*) cur=1 ;; esac
  n="${MC_RETRY_MAX:-6}"
  case "$n" in ''|*[!0-9]*) n=6 ;; esac
  while [ "$n" -gt "$cur" ]; do
    IFS=$'\t' read -r st url <<<"$(mc_stack_parent "$slug" "$stem-r$n")"
    if [ "${st:-NONE}" != NONE ]; then printf '%s\t%s\t%s' "$st" "$url" "$stem-r$n"; return; fi
    n=$((n-1))
  done
  printf 'NONE\t-\t-'
}

# mc_retarget_base <owner/repo> <pr-number> <new-base> -> rc 0 on success
#   GitHub retargets a child PR to the parent's base automatically WHEN the
#   parent merges AND its branch is deleted. A repo that keeps merged branches
#   leaves the child pointing at a dead branch forever, so the conductor does it
#   itself. It must be the REST call: `gh pr edit --base` reports success and
#   changes nothing (verified 2026-09-14), which would leave the row looking
#   retargeted while the PR still merges into a feature branch.
mc_retarget_base() {
  local slug="${1:-}" num="${2:-}" base="${3:-}"
  [ -n "$slug" ] && [ -n "$num" ] && [ -n "$base" ] || return 1
  prr_write "$slug" "$num" pull - gh api -X PATCH "repos/$slug/pulls/$num" -f "base=$base" >/dev/null 2>&1
}

# mc_close_for_rebuild <owner/repo> <pr-number> <comment-body> -> rc 0 when the
#   comment landed AND the PR is closed.
#   The fallback when a stranded child cannot be moved (BH-458): the ticket is
#   left OPEN, so the next triage tick builds it fresh, and the PR carries one
#   comment saying why. The comment goes FIRST and the close only happens if it
#   landed — a PR closed with no explanation tells the next reader nothing, and
#   a rebuild has nothing to avoid.
#   REST, not `gh pr close --comment`, for the reason mc_retarget_base carries:
#   gh's high-level PR commands have reported success on this object and changed
#   nothing (2026-09-14), and tests/stacked-child-builds-test.sh holds this lane
#   to the REST form.
mc_close_for_rebuild() {
  local slug="${1:-}" num="${2:-}" body="${3:-}"
  [ -n "$slug" ] && [ -n "$num" ] && [ -n "$body" ] || return 1
  mc_hold_keeps_pr "$slug" "$num" && return 1
  prr_write "$slug" "$num" comment - gh api -X POST "repos/$slug/issues/$num/comments" -f "body=$body" >/dev/null 2>&1 || return 1
  prr_write "$slug" "$num" pull - gh api -X PATCH "repos/$slug/pulls/$num" -f state=closed >/dev/null 2>&1
}

# ── A HOLD ON THE TICKET KEEPS ITS PR (BH-1460, 2026-09-22) ──────────────────
# mc_hold_keeps_pr <owner/repo> <pr-number> — rc 0 when this PR must be LEFT
# ALONE because its ticket says HOLD. rc 1 in every other case, which is this
# lane's behaviour unchanged.
#
# WHY IT LIVES HERE AND NOT AT THE CALL SITES. Two functions in this file close
# a PR — mc_close_for_rebuild and mc_kick_ci — and between them they have eleven
# call sites in bin/merge-conductor.sh. Guarding each one is whack-a-mole and
# every close written later reintroduces the hole; guarding the two functions
# covers the call sites that do not exist yet as well.
#
# WHY THIS LANE NEEDED ONE AT ALL. On 2026-09-22 the lead held ticket #1386 to
# adjudicate the iron-law park on its PR #1453 by hand, and twenty minutes later
# that green, approved PR was closed and a person had to reopen it. The resolver
# has read the ticket since BH-408; the merge family never has — `grep -n
# hold_check bin/merge-conductor.sh bin/merge-sweep.sh` answers nothing — so the
# one instruction that is supposed to stop automation on a ticket did not reach
# the two functions that can throw its PR away. mc_kick_ci is the sharper edge
# of the two: it CLOSES and reopens, and a reopen GitHub refuses (a base branch
# deleted a minute earlier refuses it) leaves the PR closed until a person
# intervenes.
#
# EVERY OTHER ANSWER IS TODAY'S BEHAVIOUR, and each of those is deliberate:
#   no hold library        a box mid-sync runs the code it has, and never dies
#                          on an unset function.
#   ABANDON                a different instruction — it means close it. This
#                          guard must not be what keeps an abandoned PR open.
#   clear / closed /       not a pause: nothing here is being asked to stop.
#   label-absent
#   unreadable             a read that failed says NOTHING about the ticket, and
#                          a lane that stops on every unreadable read is a lane
#                          an outage freezes. The resolver can afford to park
#                          and retry; a CI kick that never fires parks a PR that
#                          nothing else will start.
#   a PR that is not open  a hold protects OPEN work; there is nothing to keep.
#   no issue number        an in-app board ticket (or any head ref that is not a
#                          build branch) has no GitHub issue to read, exactly
#                          as bin/fly-pool.sh's own gate says.
#
# ONE EXTRA REST READ, and only on the path that is about to close something:
# the PR object (state + head ref), then hold_check's two. Closes are rare and
# the hot classification path never reaches this.
#
# AND ONLY ONCE PER TICK PER PR (review round 1). mc_kick_ci has seven call
# sites in bin/merge-conductor.sh and the refusal writes no attempt marker, so
# a held PR paid those three reads on every kick attempt in the tick. The
# conductor runs one process per tick, so this process-lifetime memo IS a
# per-tick memo. Only the HELD answer is remembered: a cached "not held" would
# let a close land minutes after a person typed HOLD, which is the bug this
# guard exists to kill. The refusal is still logged on every call, because each
# call site's line is what tells the reader why THAT close did not happen.
# A plain string, not an associative array: bash 3.2 runs these suites.
MC_HOLD_MEMO="${MC_HOLD_MEMO:-}"
# _mc_root -> $MC_H, else $HARNESS, else $H, else nothing (BH-2613). With no
# root, hold.sh and gh-token.sh are absent, which is what an unreadable root reads as.
_mc_root() { printf '%s' "${MC_H:-${HARNESS:-${H:-}}}"; }
mc_hold_keeps_pr() {
  local slug="${1:-}" num="${2:-}" pr state ref key n out
  [ -n "$slug" ] && [ -n "$num" ] || return 1
  case " $MC_HOLD_MEMO " in
    *" $slug#$num "*)
      mc_log "$slug#$num held, PR kept — the ticket says so and this tick has already read it: no close and no CI kick (BH-1460)."
      return 0 ;;
  esac
  # THE LIBRARY IS LOADED HERE, ON FIRST USE, BECAUSE NOTHING ELSE IN THIS LANE
  # LOADS IT. bin/merge-conductor.sh and bin/lib/merge-conductor-lib.sh source
  # the mc/ modules and nothing else — `grep -n hold.sh` over all three answers
  # nothing — so a guard that only asked `command -v hold_check` would have been
  # a no-op in production on every tick, green in a suite that sources the lib
  # itself, and indistinguishable from a lane with no hold. That is the same
  # shape as a cost parser that never matches: the guard exists, reviews as
  # correct, and never fires. Sourcing is idempotent and costs nothing once the
  # functions are defined.
  if ! command -v hold_check >/dev/null 2>&1; then
    # shellcheck source=bin/lib/hold.sh
    [ -n "$(_mc_root)" ] && [ -r "$(_mc_root)/bin/lib/hold.sh" ] \
      && . "$(_mc_root)/bin/lib/hold.sh" 2>/dev/null
  fi
  command -v hold_check >/dev/null 2>&1 || return 1
  command -v hold_is_pause >/dev/null 2>&1 || return 1
  pr=$(gh api "repos/$slug/pulls/$num" 2>/dev/null) || return 1
  [ -n "$pr" ] || return 1
  state=$(printf '%s' "$pr" | jq -r '.state // ""' 2>/dev/null)
  [ "$state" = open ] || return 1
  ref=$(printf '%s' "$pr" | jq -r '.head.ref // ""' 2>/dev/null)
  # `ticket/bh-1386` -> 1386, AND `ticket/bh-1386-r2` -> 1386 (review round 1).
  # The first cut read the ref's TRAILING digits, which is the retry number on
  # every branch that has one: of the live `ticket/*` refs on this repo the day
  # it was written, 96 of 466 carried an `-r2`/`-r3`/`-r4`/`-r5`/`-step0`/
  # `-local` suffix, so `ticket/bh-1000-r2` asked about issue #2 and `-step0`
  # about #0. A held ticket did not protect its own round-2 PR — and a round-2
  # PR is exactly the one a lead pauses to adjudicate by hand.
  #
  # mc_ticket_of_branch (this file) is the parser bin/run-build.sh's naming
  # rule calls for and the rebase lane has used since it was written: the KEY at
  # the head of the last path segment, suffix and all ignored. A branch it does
  # not recognise (design/…, mergify/…, an in-app board project) yields nothing,
  # and nothing means "no issue to read".
  key=$(mc_ticket_of_branch "$ref" 2>/dev/null) || return 1
  n="${key##*-}"
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  out=$(hold_check "$slug" "$n" 2>/dev/null) || true
  hold_is_pause "$out" || return 1
  MC_HOLD_MEMO="$MC_HOLD_MEMO $slug#$num"
  mc_log "$slug#$num held, PR kept — the ticket ($slug#$n) says ${out#*	}: no close and no CI kick (BH-1460). RESUME on the ticket lifts it; ABANDON is the word that closes this PR."
  return 0
}

# A RETARGET FIRES NO CI, SO THE CONDUCTOR RE-FIRES IT (2026-09-15, project-5
# #913/#943/#1011/#1020/#1021). A `pull_request` workflow's DEFAULT activity
# types are opened|synchronize|reopened. A base change is `edited`, and neither
# the PATCH above nor GitHub's own retarget (when the parent's branch is
# deleted) touches the head — so the head keeps exactly the runs it already
# had, which for a child cut from a feature branch is NONE. mc_ci_state then
# answers `none`, mc_classify parks the row at `WAIT_CI checks none`, the
# required check ("Build + Unit tests" on project-5's main ruleset) never
# reports, the merge-queue label is never added, and the PR never merges.
#
# All five of those PRs carried a `base_ref_changed` timeline event by
# cromford[bot] and ZERO runs on their head, while sibling PRs opened
# straight against main merged within the hour. `gh pr close N && gh pr reopen
# N` fired CI immediately on every one of them and unstuck them all. That is
# the mechanism, and this is it as the REST pair.
#
# WHY REST AND NOT `gh pr close/reopen`: the same lesson mc_retarget_base
# carries two functions up — gh's high-level edit commands have reported
# success and changed nothing on this exact object before (2026-09-14).
#
# THE CLOSE MUST NEVER BE LEFT STANDING. A close that lands and a reopen that
# does not leaves a CLOSED PR that no later tick can even see (it drops out of
# the open list), so the reopen is retried and a PR still closed after the last
# attempt is named LEFT CLOSED in the log, loudly, for an alert to pick up.
# rc 0 means, and only means, that the PR is open again.
# CLAMPED TO AT LEAST 1: the loop below always makes one attempt, so a 0 here
# would make the log say "0 reopen attempts all failed" about an attempt that
# really happened. The value is read once, and the message reads the same name.
MC_KICK_REOPEN_TRIES="${MC_KICK_REOPEN_TRIES:-3}"
case "$MC_KICK_REOPEN_TRIES" in ''|*[!0-9]*) MC_KICK_REOPEN_TRIES=3 ;; esac
[ "$MC_KICK_REOPEN_TRIES" -ge 1 ] || MC_KICK_REOPEN_TRIES=1
MC_KICK_REOPEN_SLEEP="${MC_KICK_REOPEN_SLEEP:-2}"
# How long a row may sit in `WAIT_CI checks none` before the generic kick in
# bin/merge-conductor.sh fires. Below it, a head with no run is a run that has
# not APPEARED yet; above it, it is a run that is never coming.
MC_CI_KICK_MIN_AGE="${MC_CI_KICK_MIN_AGE:-600}"

# mc_kick_ci <owner/repo> <pr-number> [expected-head] -> rc 0 when the PR is OPEN again
#   With [expected-head] (BH-3804) the PR's live head is re-read first and a
#   PR that has moved off it is not closed: a close/reopen on a new head fires
#   a run that the repo's cancel-in-progress group lets cancel the new head's.
#   MC_KICK_CLOSED says, after an rc 1, which failure it was (BH-1529): 0 = the
#   close never landed and NOTHING changed (a hold, a refused PATCH), 1 = the
#   close landed and the reopen did not (LEFT CLOSED, already paged). Set in the
#   calling shell, so call this as a plain command, never inside `$( )`.
MC_KICK_CLOSED=0
mc_kick_ci() {
  local slug="${1:-}" num="${2:-}" i=1
  MC_KICK_CLOSED=0
  [ -n "$slug" ] && [ -n "$num" ] || return 1
  # AND THE TICKET IS ASKED FIRST (BH-1460). This close is the one that can
  # strand a PR: the reopen below is refused by a base branch that has just been
  # deleted, and the PR is then LEFT CLOSED until a person puts it back. A
  # ticket on HOLD must not be able to lose its work that way.
  mc_hold_keeps_pr "$slug" "$num" && return 1
  if [ -n "${3:-}" ] && command -v mc_head_still >/dev/null 2>&1; then
    mc_head_still "$slug" "$slug#$num" "$3" "CI kick" || return 1
  fi
  # A refused close changed nothing at all: return without touching anything
  # else, and the caller retries on a later tick.
  prr_write "$slug" "$num" pull - gh api -X PATCH "repos/$slug/pulls/$num" -f state=closed >/dev/null 2>&1 || return 1
  MC_KICK_CLOSED=1
  while :; do
    prr_write "$slug" "$num" pull - gh api -X PATCH "repos/$slug/pulls/$num" -f state=open >/dev/null 2>&1 && return 0
    [ "$i" -ge "${MC_KICK_REOPEN_TRIES:-3}" ] && break
    i=$((i+1)); sleep "${MC_KICK_REOPEN_SLEEP:-2}"
  done
  local why="LEFT CLOSED — the CI kick closed this PR and ${MC_KICK_REOPEN_TRIES:-3} reopen attempts all failed. REOPEN IT BY HAND: gh api -X PATCH repos/$slug/pulls/$num -f state=open"
  mc_log "$slug#$num $why"
  # AND IT PAGES (2026-09-15, review of #352). Nothing in the fleet reads
  # merge-conductor.log for this line, and the conductor's own closed-unmerged
  # pass will tell the reader on the NEXT tick to "rebuild or close the issue" —
  # which buys a duplicate PR for a change that is sitting right there, one
  # reopen away. Critical, because the conductor closed it and only a person
  # can put it back.
  mc_alert "$slug#$num" CLOSED "$why" 1
  return 1
}

# --- Actions (called only behind flags by bin/merge-conductor.sh) -----------

# mc_git_auth <owner/repo> -> sets MC_REMOTE to the https remote git should use
#   for that repo, and arms the credential git answers the password prompt with.
#   rc 1 (and MC_REMOTE = the PLAIN url) when no token could be resolved.
#   It SETS a global rather than printing one because `x=$(mc_git_auth …)` runs
#   in a subshell, where the exports that are the whole point would be lost.
#
# WHY THIS EXISTS. mc_rebase used to clone `https://github.com/<slug>.git`.
# That url is unauthenticated and git does NOT read GH_TOKEN, so the conductor's
# own token routing (bin/lib/gh-repo-token.sh, which picks the admin PAT for the
# repos the default one cannot see) never reached it. Every repo in the fleet is
# private, so every mc_rebase off the hub returned rc 4 — forever, and silently,
# because the clone's stderr goes to /dev/null.
#
# WHY GIT_ASKPASS AND NOT A TOKEN IN THE URL. The obvious fix,
# `https://x-access-token:$TOKEN@github.com/...`, puts the secret in three
# places that outlive the call: the scratch clone's .git/config (that clone at
# $MC_H/tmp/conductor/<slug> is REUSED on every later tick, so it is a secret at
# rest), the process argv that anyone can read out of `ps`, and every git error
# message, which echo the remote back. GIT_ASKPASS keeps the value in this
# process's environment alone: the url carries a username and nothing else, so
# .git/config, argv and any log line are all safe to read. `-c credential.helper=`
# at each call site stops an ambient helper from preempting or caching it.
MC_ASKPASS=""
MC_REMOTE=""
mc_git_auth() {
  local slug="$1" tok=""
  MC_REMOTE="https://github.com/$slug.git"
  # The accessor decides WHICH token; we only consume what it exported.
  if type gh_repo_use_token >/dev/null 2>&1; then gh_repo_use_token "$slug" >/dev/null 2>&1 || true; fi
  tok="${GH_TOKEN:-}"
  # The DEFAULT token is not in GH_TOKEN on a box — gh_repo_use_token resets the
  # variable and gh reads its keyring. Every conductor rebase on a default-token
  # repo therefore found an empty token here and fetched unauthenticated: rc 4,
  # "rebase setup failed", on project-5 #517/#518/#507/#490 (2026-09-13 trace:
  # `tok=` → `return 1` → git fetch refused). gh's own answer is the token.
  # C2 (2026-09-24): bin/gh-token.sh first — the App for this repo, then its own
  # PAT ladder (env/global.env, env/gh-pat) — because the keyring below is the operator's
  # PAT and is empty on a box that has been logged out. The keyring stays last.
  local _mc_gt; _mc_gt=$(_mc_root)
  [ -n "$tok" ] || { [ -n "$_mc_gt" ] && _mc_gt="$_mc_gt/bin/gh-token.sh" && [ -x "$_mc_gt" ] && tok=$("$_mc_gt" --min-life 600 "$slug" 2>/dev/null | head -n 1); }
  [ -n "$tok" ] || tok=$(gh auth token 2>/dev/null)
  [ -n "$tok" ] || return 1
  if [ -z "$MC_ASKPASS" ] || [ ! -x "$MC_ASKPASS" ]; then
    MC_ASKPASS=$(mktemp "${TMPDIR:-/tmp}/mc-askpass-XXXXXX") || return 1
    cat > "$MC_ASKPASS" <<'MCASKPASS'
#!/bin/sh
# Answers git's credential prompt from the environment. The token is NEVER in
# this file, in an argv, or in .git/config.
printf '%s\n' "$MC_GIT_TOKEN"
MCASKPASS
    chmod 700 "$MC_ASKPASS"
  fi
  export GIT_ASKPASS="$MC_ASKPASS" GIT_TERMINAL_PROMPT=0
  MC_REMOTE="https://x-access-token@github.com/$slug.git"
  # A TOKEN THAT CAN SEE THE REPO IS NOT A TOKEN THAT CAN FETCH IT (2026-09-13,
  # project-5 #517/#507/#490, every rebase rc 4). gh_repo_use_token's probe is
  # `GET /repos/<slug>` — metadata — and the hub's default fine-grained PAT
  # passes it while `git fetch` answers "Write access to repository not
  # granted" (403): the PAT has no Contents grant on that repo. So the
  # credential is chosen by the capability git actually needs: each candidate
  # (the accessor's pick, then the admin token when one is configured) is
  # tried with a one-request `ls-remote`, and the first that can read the
  # remote wins. Nothing here reads a branch; the probe is HEAD only.
  local cand which=accessor
  for cand in "$tok" "${_GHRT_ADMIN_TOK:-}"; do
    [ -n "$cand" ] || { which=admin; continue; }
    export MC_GIT_TOKEN="$cand"
    # `ls-remote HEAD` without -h: `-h` restricts the listing to refs/heads and
    # HEAD is not one, so with --exit-code that form is rc 2 for EVERY token —
    # the 2026-09-13 03:45 tick refused both candidates on a repo the admin
    # token reads fine. Auth failure is rc 128 and the only thing probed here.
    if git -c credential.helper= ls-remote --exit-code "$MC_REMOTE" HEAD >/dev/null 2>&1; then
      [ "$which" = admin ] && mc_log "$slug git credential: the accessor's token cannot read the remote — using the admin token for fetch/push"
      return 0
    fi
    which=admin
  done
  unset MC_GIT_TOKEN
  mc_log "$slug git credential: no configured token can read $MC_REMOTE (ls-remote refused every candidate)"
  return 1
}
# Called on EVERY mc_rebase exit path, so the helper is not left behind: the
# conductor is a */5 cron and one stray temp file per tick is a real leak.
mc_git_auth_clear() {
  unset MC_GIT_TOKEN GIT_ASKPASS
  [ -n "$MC_ASKPASS" ] && rm -f "$MC_ASKPASS"
  MC_ASKPASS=""; return 0
}

# mc_unshallow_once <repo> <project> <url> <lane>
#   A hub clone made with a --depth has no merge base with origin/main for any
#   branch that forked before its boundary, so `git merge origin/main` answers
#   "fatal: refusing to merge unrelated histories" with ZERO unmerged paths and
#   the rebase dies rc 4 (BH-517: the 2026-09-15 restore cloned by hand, and
#   seven PRs looped NEEDS_REBASE in a day). Heal it ONCE — under the project's
#   git lock, on the credentials mc_git_auth has already armed — and let the
#   caller retry the merge in the same call.
#   rc 0 it WAS shallow and is now complete (retry) | 1 not shallow, nothing to
#   do | 2 shallow and the unshallow failed, or the git lock could not be had —
#   logged with git's own words, and the caller gives up with rc 4.
#   The gate is `--is-shallow-repository`, never the stderr text: --unshallow on
#   a complete repo is itself a fatal, and a second fatal is not a diagnosis.
mc_unshallow_once() {
  local repo="$1" project="$2" url="$3" lane="$4" err n rc=0
  [ "$(git -C "$repo" rev-parse --is-shallow-repository 2>/dev/null)" = true ] || return 1
  n=$(wc -l < "$repo/.git/shallow" 2>/dev/null | tr -d ' '); : "${n:=?}"
  # Written BEFORE the fetch: a remote that hangs costs this PR its tick, and a
  # wait nobody can see is the half of this defect that cost the day.
  mc_log "$url $lane: $repo is a SHALLOW clone ($n boundary commit(s)) — git fetch --unshallow origin, once, then the merge is retried"
  err=$(mc_git_locked "$project" mc_git_bounded "${MC_UNSHALLOW_SECS:-900}" \
          git -C "$repo" -c credential.helper= fetch -q --unshallow origin 2>&1 >/dev/null) || rc=$?
  [ "$rc" = 0 ] && { mc_log "$url $lane: unshallowed $repo"; return 0; }
  # rc 99 is the lock, 124 the wall clock, anything else git's own — each says
  # which it was rather than collapsing into "could not unshallow".
  mc_log "$url $lane: git fetch --unshallow origin failed (rc $rc) — $(mc_git_err_line "${err:-(no stderr)}")"
  return 2
}

# --- POOL REBASE (BH-486) ----------------------------------------------------
# A rebase costs the hub a clone, a worktree, a typecheck and a unit run. Under
# REBASE_ON_POOL that work moves to a pool machine and the hub keeps only what
# it must own: the lease, the approval rebind and the merge. This slice is the
# CONTRACT — the flag read, the key, and two stubs. Nothing rebases on a pool
# yet, and the flag ships OFF.
#
# mc_pool_rebase_enabled <project> — rc 0: rebase this project's PRs on the pool.
#   REBASE_ON_POOL comes from the environment when it is set to something, else
#   from env/<project>.env (the same read as BASE_BRANCH above). It must be
#   exactly `1` AND flags/fly-pool-app-<project> must exist, because
#   bin/fly-pool.sh spawns nothing for a project without that flag. `1` with no
#   pool app says so once per call and answers rc 1 — a fallback, not a page.
#   Unset or anything else is rc 1 and silent.
mc_pool_rebase_enabled() {
  local p="$1" v="${REBASE_ON_POOL-}"
  [ -n "$v" ] || v=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}REBASE_ON_POOL=//p' "$MC_H/env/$p.env" 2>/dev/null | tr -d "\"'" | head -n 1)
  [ "$v" = 1 ] || return 1
  if command -v routing_pool_app >/dev/null 2>&1; then routing_pool_app "$p" >/dev/null 2>&1 && return 0
  elif [ -e "$MC_H/flags/fly-pool-app-$p" ]; then return 0; fi
  mc_log "REBASE_ON_POOL=1 but no pool app for $p; rebasing on the hub"
  return 1
}
# mc_pool_rebase_key <num> <head> — the queue/ledger key: RB-<num>-<head8>.
#   A short head prints as it is; nothing is padded.
mc_pool_rebase_key() { printf 'RB-%s-%s' "$1" "${2:0:8}"; }
# mc_pool_rebase_enqueue <slug> <project> <branch> <head> <url>
#   One build_queue row with kind=rebase in its meta and
#   key=$(mc_pool_rebase_key <num> <head>).
#     rc 6  row written (or already there) — nothing cloned, nothing spent
#     rc 7  the pool queue is unreachable — retry next tick, nothing spent
#
#   THE JOB FILE IS WRITTEN FIRST, under the same MC_RB_DIR/.lock the detached
#   lane takes, because it is what the conductor reads to know this PR has a
#   rebase in flight: a queue row with no job file would be re-enqueued by every
#   tick until the machine answered. If the queue then refuses, the file is
#   removed again — rc 7 means NOTHING was spent, and the caller's arm relies on
#   that to hand its budget back and leave no attempts line.
#
#   A RE-ENQUEUE OF A HEAD THAT IS ALREADY `pool` KEEPS ITS started_at. The
#   resolver and the rebase train reach mc_rebase without reading the job file,
#   so the same head can be offered again while a machine has it; restarting the
#   clock there would mean the pool timeout never fires and the PR waits for
#   ever on a machine that died.
#
#   `ticket_id` is the PR number: bin/fly-pool.sh quarantines a row whose key or
#   ticket_id is empty. `duplicate` (the row is already queued or claimed) is rc
#   6 too — queue_put is idempotent on (project, key) and one head gets one row.
#   The meta carries the documented fields and no credential of any kind.
#
#   A QUEUED ROW OWES A READ, SO THE PREVIOUS READ OF THIS HEAD IS FORGOTTEN.
#   rebase_consume reads one result per (PR, head) — `mc_attempted rebasedone` /
#   `rebasefailed` — and that one-shot is right for the tick, which enqueues a
#   head exactly once. It is wrong for everybody else: the resolver's rung 1,
#   the rebase train and the stuck re-kick all reach mc_rebase for a head the
#   conductor has ALREADY turned into a row. Without this clear the second
#   machine's answer is unreadable — rebase_consume returns 1, the `done` file
#   sits there, the row falls back to NEEDS_REBASE on mergeState, the park that
#   would start the resolver's fix round is never made, and the stuck re-kick
#   buys another pool machine for the same head every TTL. The clear happens
#   only after the queue actually took the row (rc 7 spends nothing and changes
#   nothing), and it cannot un-read a stale result: the job file above is
#   already back to `pool`, so the next tick has nothing to re-read.
mc_pool_rebase_enqueue() {
  local slug="$1" project="$2" br="$3" head="$4" url="$5"
  local num key jf out meta r wrc started prev
  num=$(mc_num_of_url "$url")
  [ -n "$num" ] || { mc_log "${url:--} pool rebase: no PR number in that url — nothing queued, nothing spent"; return 7; }
  key=$(mc_pool_rebase_key "$num" "$head")
  # ON A MACHINE WITH conductor_remote_spawn ON (BH-6888) the row is the whole
  # record: no job file, no attempts clear. The machine's run ends with it.
  if [ "${MC_ON_MACHINE:-}" = 1 ] && command -v mc_remote_on >/dev/null 2>&1 && mc_remote_on "$project"; then
    mc_remote_rebase_spawn "$slug" "$num" "$project" "$br" "$head" "$url"
    case "$?" in 0|4) return 6 ;; *) return 7 ;; esac
  fi
  mkdir -p "$MC_RB_DIR" 2>/dev/null || { mc_log "$url pool rebase: $MC_RB_DIR is not writable — nothing spent"; return 7; }
  jf=$(mc_rb_file "$slug" "$num" "$head"); out="${jf%.json}.out"
  started=$(mc_now)
  if [ "$(mc_rr_field "$jf" status)" = pool ]; then
    prev=$(mc_rr_field "$jf" started_at)
    case "$prev" in ''|-|null|*[!0-9]*) : ;; *) started="$prev" ;; esac
  fi
  # The lock covers the jq + mv and nothing else; the HTTP call below sits
  # outside it, because a short critical section is a dedupe and a long one is
  # a queue.
  ( flock 9 2>/dev/null
    mc_rb_write "$jf" pool 0 "$started" 0 - "$head" - "$out" || exit 1
  ) 9>>"$MC_RB_DIR/.lock" 2>/dev/null
  wrc=$?
  [ "$wrc" = 0 ] || { mc_log "$url pool rebase: the job file $jf could not be written — nothing spent"; return 7; }
  type queue_put >/dev/null 2>&1 || {
    rm -f "$jf"
    mc_log "$url pool rebase: no queue client sourced on this box — nothing spent, retried next tick"; return 7; }
  # BH-8035: `mergify` and `hold` tell the machine to read the hold again at its push.
  meta=$(jq -nc --arg s "$slug" --arg u "$url" --argjson n "$num" --arg b "$br" --arg h "$head" \
    --argjson x "$(mc_pool_rebase_meta_extra "$slug" "$project" "$num" "$head" "${PROVIDER:-}")" \
    '{kind:"rebase",slug:$s,url:$u,pr:$n,branch:$b,head:$h,base:"main"} + $x' 2>/dev/null) || {
    rm -f "$jf"; mc_log "$url pool rebase: the queue meta could not be built — nothing spent"; return 7; }
  r=$(queue_put "$project" "$key" "$num" fly "" "$meta") || {
    rm -f "$jf"
    mc_log "$url pool rebase: pool queue unreachable — nothing spent, retried next tick"; return 7; }
  # The row exists, so the read is owed again (see the header): the conductor
  # key is the slug and number this row was queued under, exactly as pr_worker
  # builds it.
  mc_attempt_clear rebasedone "$slug#$num" "$head"
  mc_attempt_clear rebasefailed "$slug#$num" "$head"
  mc_log "$url pool rebase queued as $key (${r:-queued}) for ${head:0:8} on $br — nothing cloned on the hub"
  type job_ledger_put >/dev/null 2>&1 && job_ledger_put rebase "$url@$head" queued "$key" >/dev/null 2>&1 || true
  return 6
}
# mc_pool_rebase_apply <project> <key> <result-file>
#   Read the RESULT file bin/lib/rebase-job.sh documents, write the job file the
#   conductor's rebase_consume reads, attempt the approval rebind, and write the
#   ledger row. Called from the reap in BH-486.3.
#     rc 0      the job file was written (its `rc` field says what happened)
#     rc 1      nothing could be written — the caller leaves the queue row
#               `claimed` and alerts
#
#   THE RECORDED rc IS mc_rebase's, because rebase_consume feeds it straight to
#   rebase_result: 0 rebased, 1 conflict, 2 gate red, 3 lease rejected, 4 setup
#   failed, 5 pushed but the approval could not be moved. A RESULT this parser
#   cannot read as one of the five words is rc 4 and NEVER 0 — "succeeded but
#   said nothing usable" is a setup failure, not a rebase. A `REBASED <sha>`
#   with no usable `PR:` line is rc 4 for the same reason: without the url there
#   is no approval to rebind, and presuming one moved is how a sha nobody
#   reviewed gets merged.
#
#   THE KEY WINS OVER THE FILE. The RESULT is a text file written by a machine
#   this box does not hold, and two of its lines would otherwise steer things
#   the hub owns: `PR:` decides whose approval is rebound, and `HEAD:` becomes a
#   component of the job-file path. So each is cross-checked against the key the
#   reap claimed the row under — `PR:` must name the key's number, `HEAD:` must
#   be 40 lowercase hex starting with the key's head8 — and a line that fails is
#   DROPPED, not trusted. Dropping `PR:` costs a REBASED its rc 0 (rc 4: nothing
#   to rebind); dropping `HEAD:` costs nothing, because the on-disk job file for
#   (num, head8) carries the head the hub itself queued.
mc_pool_rebase_apply() {
  local project="$1" key="$2" rf="$3"
  local first word arg url head br num head8 slug jf out f started wrc rbrc
  local rc=4 new="-" outtext="" status=SETUP_FAILED rec
  [ -n "$key" ] && [ -f "$rf" ] || return 1
  first=$(head -n 1 "$rf" 2>/dev/null)
  # The first COLUMN, exactly: a leading space makes `word` empty and drops the
  # line into the catch-all, which is the same rule bin/result-prefix-ok.sh
  # applies at the pool's own gate.
  word="${first%% *}"; arg="${first#* }"; [ "$arg" = "$first" ] && arg=""
  url=$(sed -n 's/^PR: //p' "$rf" 2>/dev/null | head -1)
  local union; union=$(sed -n 's/^UNION: //p' "$rf" 2>/dev/null | head -1)
  head=$(sed -n 's/^HEAD: //p' "$rf" 2>/dev/null | head -1)
  br=$(sed -n 's/^BRANCH: //p' "$rf" 2>/dev/null | head -1)
  num="${key#RB-}"; num="${num%%-*}"; head8="${key##*-}"
  # The cross-check, before either value is used for anything.
  if [ -n "$head" ]; then
    case "$head" in
      "$head8"*) [ "${#head}" = 40 ] && [ -z "${head//[0-9a-f]/}" ] || head="" ;;
      *) head="" ;;
    esac
  fi
  if [ -n "$url" ] && [ "$(mc_num_of_url "$url")" != "$num" ]; then
    mc_log "$project pool rebase: RESULT for $key names PR $(mc_num_of_url "$url"), not $num — ignored"
    url=""
  fi
  [ -n "$url" ] && slug=$(mc_slug_of_url "$url")
  # Name the job file. The RESULT's surviving lines are preferred; a RESULT that
  # lost one of them falls back to the file this (PR, head8) already has on disk.
  if [ -z "$head" ] || [ -z "${slug:-}" ]; then
    for f in "$MC_RB_DIR"/*_"${num}"_"${head8}"*.json; do
      [ -f "$f" ] || continue
      jf="$f"; [ -n "$head" ] || head=$(mc_rr_field "$f" head_sha); break
    done
  fi
  [ -n "${slug:-}" ] && [ -n "$head" ] && jf=$(mc_rb_file "$slug" "$num" "$head")
  [ -n "${jf:-}" ] || return 1
  # REBASE_SKIPPED (BH-8035): the machine read a hold just before its push and
  # pushed nothing. A clean no-op: the job file of this head goes, so no tick
  # reads a result, and the row is classified again from GitHub next tick.
  if [ "$word" = REBASE_SKIPPED ]; then
    ( flock 9 2>/dev/null
      rm -f "$jf" "${jf%.json}.out"
    ) 9>>"$MC_RB_DIR/.lock" 2>/dev/null
    if [ -n "$url" ] && [ -n "$head" ]; then
      type job_ledger_put >/dev/null 2>&1 && \
        job_ledger_put rebase "$url@$head" SKIPPED "$(printf '%.200s' "$first")" >/dev/null 2>&1 || true
    fi
    mc_log "$project $key pool rebase applied: SKIPPED (${arg:-no reason}) on ${br:-the branch} at ${head:0:8} — nothing pushed, nothing to apply (BH-8035)"
    return 0
  fi
  case "$word" in
    REBASED)
      if [ "${#arg}" = 40 ] && [ -z "${arg//[0-9a-f]/}" ] && [ -n "$url" ]; then
        new="$arg"; outtext="$arg"; status=REBASED; rc=0
        # THE REBIND IS THE ONLY PATH TO rc 0. The record half is a no-op for
        # pool builds, so the LEDGER rebind is what carries the approval, and a
        # rebind that did not happen — refused, or a shell with no jobs client
        # in it — is rc 5. The record's reviewed-sha follows the approval and
        # never leads it: a file saying the new head is reviewed, over a verdict
        # row that still names the old one, is how an unreviewed sha merges.
        rbrc=1
        if [ -n "$union" ]; then
          # BH-4641: the machine union-resolved this merge — see mc_rebase.
          rc=5
          mc_log "$url pool rebase pushed ${new:0:8} — union-resolved ($union): approval deliberately NOT rebound (a resolved merge is not a clean main merge; iron guardrail 1), the head-bound re-review reads the new head (BH-4641)"
        elif type job_verdict_rebind >/dev/null 2>&1 && { job_verdict_rebind "$url" "$new" >/dev/null 2>&1; rbrc=$?; [ "$rbrc" = 0 ]; }; then
          rec=$(mc_record_for "$url" || true)
          [ -n "$rec" ] && [ -s "$rec/reviewed-sha" ] && echo "$new" > "$rec/reviewed-sha"
        else
          rc=5
          mc_log "$url pool rebase pushed ${new:0:8} but the approval rebind did not happen (rc $rbrc) — the approval is STILL bound to ${head:0:8}; NOT treating this as rebound"
        fi
      elif [ -z "$url" ]; then
        outtext="REBASED but the RESULT carried no usable PR: line — no approval can be rebound"
      else
        outtext="REBASED with no usable sha: $first"
      fi ;;
    CONFLICT)              rc=1; status=CONFLICT;        outtext="${arg:--}" ;;
    GATE_RED)              rc=2; status=GATE_RED;        outtext="$first" ;;
    REBASE_LEASE_REJECTED) rc=3; status=LEASE_REJECTED;  outtext="$first" ;;
    REBASE_SETUP_FAILED)   rc=4; status=SETUP_FAILED;    outtext="$first" ;;
    *)                     outtext="${first:-empty RESULT}" ;;
  esac
  out="${jf%.json}.out"
  mkdir -p "$MC_RB_DIR" 2>/dev/null
  started=$(mc_rr_field "$jf" started_at); case "$started" in ''|-|null) started=$(mc_now) ;; esac
  # The .out file first and the job file second, the same order mc_rebase_run
  # writes them in: `done` is the flag that makes a tick read the output, so it
  # is written last.
  printf '%s' "$outtext" > "$out" 2>/dev/null
  ( flock 9 2>/dev/null
    mc_rb_write "$jf" done 0 "$started" "$(mc_now)" "$rc" "$head" "$new" "$out" || exit 1
  ) 9>>"$MC_RB_DIR/.lock" 2>/dev/null
  wrc=$?
  [ "$wrc" = 0 ] || return 1
  # Fail-open, and skipped entirely when the RESULT named no PR this key owns:
  # the ledger key IS <url>@<head>, and there is no honest key to write without
  # both halves.
  if [ -n "$url" ] && [ -n "$head" ]; then
    type job_ledger_put >/dev/null 2>&1 && \
      job_ledger_put rebase "$url@$head" "$status" "$(printf '%.200s' "$first")" >/dev/null 2>&1 || true
  fi
  local moved=""; [ "$new" != - ] && moved=" -> ${new:0:8}"
  mc_log "$project $key pool rebase applied: $status (rc $rc) on ${br:-the branch} at ${head:0:8}$moved"
  return 0
}

# mc_pool_rebase_fail <project> <key> [reason]
#   A pool rebase that is NOT coming back: the machine died or stood down before
#   the job ever ran, so no RESULT will ever exist to apply. Mark the hub job
#   file `failed` so the conductor's failed/stale arm reaches the PR on its NEXT
#   tick, instead of holding it in REBASING for MC_REBASE_POOL_TIMEOUT_SECS
#   (5400s) — mc_rb_state reads a `pool` file as `running` on its age alone, so a
#   reaped stand-down that leaves the file at `pool` costs the PR 90 minutes
#   (BH-986).
#     rc 0  at least one job file was marked failed
#     rc 1  the key is not an RB-<num>-<head8> key, there is no job file for it,
#           or every file found was already done/failed
#
#   A `done` FILE IS NEVER REWRITTEN. A late machine RESULT is a fact:
#   mc_pool_rebase_apply already recorded what the rebase did, and overwriting
#   that with `failed` would hide a pushed sha from every reader. Only a `pool`
#   file — the one this reap is the last word on — is touched.
#
#   THE LOOKUP is the fallback mc_pool_rebase_apply already uses: the queue key
#   carries (num, head8) and nothing else, and the machine json carries no
#   `rebase` object, so the (owner_repo, num, head) file is found by glob.

#   THE LEDGER ROW is keyed on `<url>@<40-sha>` — the key mc_pool_rebase_enqueue
#   wrote — read back from the job file's own head_sha. If that field is gone
#   the row is SKIPPED, never keyed on the 8-hex head8: an 8-hex key matches no
#   row any reader has, so it would only add an orphan. The file is still
#   marked failed either way.
#
#   WHAT IT DELIBERATELY DOES NOT DO: clear the `rebase <key> <head>` attempt
#   marker or remove the job file. The NEEDS_REBASE TTL stays the pacing for a
#   fresh rebase of this head; clearing them would let a flapping pool buy a new
#   machine for the same head every tick.
mc_pool_rebase_fail() {
  local project="$1" key="$2" reason="${3:-}"
  local num head8 f st head slug url n=0
  case "$key" in RB-*-*) : ;; *) return 1 ;; esac
  num="${key#RB-}"; num="${num%%-*}"; head8="${key##*-}"
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$head8" ] || return 1
  [ -d "$MC_RB_DIR" ] || return 1
  for f in "$MC_RB_DIR"/*_"${num}"_"${head8}"*.json; do
    [ -f "$f" ] || continue
    st=$(mc_rr_field "$f" status)
    [ "$st" = pool ] || continue
    # NO FALLBACK TO head8. mc_pool_rebase_enqueue keyed the ledger row on
    # `<url>@<40-sha>`; an 8-hex key can never match that row, so a file that
    # lost its head_sha gets NO row rather than an orphan one — the same rule
    # mc_pool_rebase_apply follows ("no honest key without both halves"). The
    # job file is still marked failed; only the ledger row is skipped.
    head=$(mc_rr_field "$f" head_sha)
    case "$head" in
      ????????????????????????????????????????) [ -z "${head//[0-9a-f]/}" ] || head="" ;;
      *) head="" ;;
    esac
    ( flock 9 2>/dev/null
      mc_rb_fail "$f" || exit 1
    ) 9>>"$MC_RB_DIR/.lock" 2>/dev/null
    [ "$(mc_rr_field "$f" status)" = failed ] || continue
    n=$((n+1))
    # The ledger row mirrors the TIMED_OUT one the conductor's own timeout arm
    # writes for the same reader, on the same <url>@<head> key. The slug comes
    # back out of the file name (mc_rr_key wrote `<owner>_<repo>_<num>_<head>`),
    # and the row is skipped rather than guessed when that read is not usable.
    slug=$(basename "$f" | sed -n "s/^\([^_]*\)_\(.*\)_${num}_${head8}.*\.json$/\1\/\2/p")
    if [ -n "$slug" ] && [ -n "$head" ]; then
      url="https://github.com/$slug/pull/$num"
      type job_ledger_put >/dev/null 2>&1 && \
        job_ledger_put rebase "$url@$head" FAILED "$(printf '%.200s' "${reason:-the pool rebase machine produced no RESULT}")" >/dev/null 2>&1 || true
    fi
  done
  if [ "$n" -gt 0 ]; then
    mc_log "$project $key pool rebase marked failed on the hub: $n job file(s) — ${reason:-no RESULT from the machine}"
    return 0
  fi
  mc_log "$project $key pool rebase: no pool job file for PR $num at $head8 — nothing marked failed"
  return 1
}

# --- Pool re-review rows (BH-7635) --------------------------------------------
# A lane-run machine cannot run the detached re-review (mc_rereview_spawn), so
# the re-review rides the pool as an `RR-<num>-<head8>` row with meta
# kind=rereview, the way a rebase rides it as `RB-*`. The machine body is
# bin/lib/rereview-job.sh; the two functions below are the HUB half. They write
# the SAME job file mc_rereview_run writes (mc_rr_file), so headbound_review
# consumes a pool verdict exactly as it consumes a hub one. Nothing here writes
# to GitHub: the post, the rebind and the transition stay in headbound_review.

# mc_pool_rereview_key <num> <head> — the queue key: RR-<num>-<head8>.
mc_pool_rereview_key() { printf 'RR-%s-%s' "$1" "${2:0:8}"; }

# mc_pool_rereview_apply <project> <key> <result-file>
#   Read the RESULT bin/lib/rereview-job.sh documents and write the hub job file:
#     REREVIEWED APPROVE|BLOCK          -> done, verdict, out_file = the review text
#                                          (after the FIRST `--- review ---` line),
#                                          .out.model / .out.runner from MODEL/RUNNER
#     REREVIEW_LANE_FAILED|_SETUP_FAILED -> lane-failed, reason = the rest of line 1
#     REREVIEW_NOVERDICT                -> failed (the no-verdict path, one retry)
#     REREVIEW_DEFERRED                 -> the job file is removed (the `none` case)
#   rc 0  written, or a no-op: a `done` file of the same head is never rewritten,
#         so a second reap of one RESULT changes nothing.
#   rc 1  nothing written: the key is not RR-<num>-<head8>, the RESULT is empty,
#         line 1 is not one of the five words (or not APPROVE/BLOCK), a
#         REREVIEWED has no `--- review ---` body, the PR: line names another PR,
#         the HEAD: line is not 40 hex starting with the key's head8, or the
#         write failed. The caller leaves the row claimed and alerts.
#   THE KEY WINS OVER THE FILE, as in mc_pool_rebase_apply: the RESULT is text
#   from a machine this box does not hold, and PR:/HEAD: name the job file.
mc_pool_rereview_apply() {
  local project="$1" key="$2" rf="$3"
  local first word arg hdr url head rev model runner num head8 slug jf out now wrc
  case "$key" in RR-*-*) : ;; *) return 1 ;; esac
  [ -s "$rf" ] || return 1
  num="${key#RR-}"; num="${num%%-*}"; head8="${key##*-}"
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  first=$(head -n 1 "$rf" 2>/dev/null)
  word="${first%% *}"; arg="${first#* }"; [ "$arg" = "$first" ] && arg=""
  case "$word" in
    REREVIEWED)
      case "$arg" in APPROVE|BLOCK) : ;; *) mc_log "$project $key pool re-review: RESULT '$first' carries no verdict word — not applied"; return 1 ;; esac
      grep -qx -- '--- review ---' "$rf" 2>/dev/null \
        || { mc_log "$project $key pool re-review: REREVIEWED with no review body — not applied"; return 1; } ;;
    REREVIEW_LANE_FAILED|REREVIEW_SETUP_FAILED|REREVIEW_NOVERDICT|REREVIEW_DEFERRED) : ;;
    *) mc_log "$project $key pool re-review: RESULT '${first:-empty}' is not a re-review word — not applied"; return 1 ;;
  esac
  # The header lines come from the part BEFORE the body: a review that quotes a
  # `HEAD:` line must not steer the file name.
  hdr=$(sed '/^--- review ---$/q' "$rf" 2>/dev/null)
  url=$(printf '%s\n' "$hdr" | sed -n 's/^PR: //p' | head -1)
  head=$(printf '%s\n' "$hdr" | sed -n 's/^HEAD: //p' | head -1)
  rev=$(printf '%s\n' "$hdr" | sed -n 's/^REVIEWED: //p' | head -1)
  model=$(printf '%s\n' "$hdr" | sed -n 's/^MODEL: //p' | head -1)
  runner=$(printf '%s\n' "$hdr" | sed -n 's/^RUNNER: //p' | head -1)
  if [ "${#head}" != 40 ] || [ -n "${head//[0-9a-f]/}" ] || [ "${head:0:8}" != "$head8" ]; then
    mc_log "$project $key pool re-review: RESULT HEAD '${head:--}' is not the key's head $head8 — not applied"; return 1
  fi
  slug=$(mc_slug_of_url "$url")
  case "$slug" in ''|*[!A-Za-z0-9._/-]*) slug="" ;; esac
  if [ -z "$slug" ] || [ "$url" != "https://github.com/$slug/pull/$num" ]; then
    mc_log "$project $key pool re-review: RESULT PR '${url:--}' is not PR $num — not applied"; return 1
  fi
  case "$rev" in ''|-) rev=- ;; *) { [ "${#rev}" = 40 ] && [ -z "${rev//[0-9a-f]/}" ]; } || rev=- ;; esac
  mkdir -p "$MC_RR_DIR" 2>/dev/null || return 1
  jf=$(mc_rr_file "$slug" "$num" "$head"); out="${jf%.json}.out"; now=$(mc_now)
  # Under the same lock the detached job and the spawn take. `done` is written
  # last, after the .out file it points at, as mc_rereview_run orders them.
  ( flock 9 2>/dev/null
    [ "$(mc_rr_field "$jf" status)" = done ] && exit 4
    case "$word" in
      REREVIEWED)
        sed '1,/^--- review ---$/d' "$rf" > "$out.tmp" 2>/dev/null && mv -f "$out.tmp" "$out" || exit 1
        rm -f "$out.model" "$out.runner" "$out.lanefail"
        case "${model:--}" in -) : ;; *) printf '%s\n' "$model" > "$out.model" ;; esac
        case "${runner:--}" in -) : ;; *) printf '%s\n' "$runner" > "$out.runner" ;; esac
        mc_rr_write "$jf" done 0 "$now" "$now" "$arg" "$head" "$rev" "$out" || exit 1 ;;
      REREVIEW_LANE_FAILED|REREVIEW_SETUP_FAILED)
        mc_rr_write "$jf" lane-failed 0 "$now" "$now" - "$head" "$rev" "$out" "${arg:-the pool re-review lane failed}" || exit 1 ;;
      REREVIEW_NOVERDICT)
        mc_rr_write "$jf" failed 0 "$now" "$now" - "$head" "$rev" "$out" || exit 1 ;;
      REREVIEW_DEFERRED)
        rm -f "$jf" "$out.lanefail" ;;
    esac
  ) 9>>"$MC_RR_DIR/.lock" 2>/dev/null
  wrc=$?
  case "$wrc" in
    0) mc_log "$project $key pool re-review applied: $first on ${head:0:8} ($slug#$num)"; return 0 ;;
    4) mc_log "$project $key pool re-review: the job file of ${head:0:8} is already done — '$first' changes nothing"; return 0 ;;
  esac
  return 1
}

# mc_pool_rereview_fail <project> <key> <why> [<meta-json>]
#   A pool re-review that is NOT coming back: the machine died or stood down
#   before it wrote a RESULT. The hub job file becomes `lane-failed` with <why>,
#   never `failed`: a dead machine is our outage, not a fact about the PR, so it
#   costs no no-verdict strike, and headbound_review retries it within
#   MC_RR_LANEFAIL_MAX. The slug, head and reviewed sha come from <meta-json>,
#   or from the key's queue row when it is not given (one GET).
#     rc 0  the job file was written
#     rc 1  no usable meta (the key, the PR number or the head8 do not agree), a
#           `done` file of that head (never rewritten), or the write failed
mc_pool_rereview_fail() {
  local project="$1" key="$2" why="${3:-the pool re-review machine produced no RESULT}" m="${4:-}"
  local num head8 o slug head rev pr jf out now wrc
  case "$key" in RR-*-*) : ;; *) return 1 ;; esac
  num="${key#RR-}"; num="${num%%-*}"; head8="${key##*-}"
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  if [ -z "$m" ] && declare -F _jobs_req >/dev/null 2>&1; then
    m=$(_jobs_req GET "/api/queue?project=$project&key=$key&limit=1" 2>/dev/null \
          | jq -c '.queue[0].meta // empty | if type == "string" then (try fromjson catch {}) else . end' 2>/dev/null)
  fi
  o=$(printf '%s' "$m" | jq -c 'select(type=="object") | if (.rereview|type)=="object" then .rereview else . end' 2>/dev/null)
  slug=$(printf '%s' "$o" | jq -r '.slug // "" | tostring' 2>/dev/null)
  head=$(printf '%s' "$o" | jq -r '.head // "" | tostring' 2>/dev/null)
  rev=$(printf '%s' "$o" | jq -r '.reviewed // "-" | tostring' 2>/dev/null)
  pr=$(printf '%s' "$o" | jq -r '.pr // "" | tostring' 2>/dev/null)
  case "$slug" in ''|*[!A-Za-z0-9._/-]*) slug="" ;; esac
  if [ -z "$slug" ] || [ "$pr" != "$num" ] || [ "${#head}" != 40 ] || [ -n "${head//[0-9a-f]/}" ] || [ "${head:0:8}" != "$head8" ]; then
    mc_log "$project $key pool re-review: no usable row meta — no hub job file marked lane-failed ($why)"; return 1
  fi
  case "$rev" in -) : ;; *) { [ "${#rev}" = 40 ] && [ -z "${rev//[0-9a-f]/}" ]; } || rev=- ;; esac
  mkdir -p "$MC_RR_DIR" 2>/dev/null || return 1
  jf=$(mc_rr_file "$slug" "$num" "$head"); out="${jf%.json}.out"; now=$(mc_now)
  ( flock 9 2>/dev/null
    [ "$(mc_rr_field "$jf" status)" = done ] && exit 4
    mc_rr_write "$jf" lane-failed 0 "$now" "$now" - "$head" "$rev" "$out" "$why" || exit 1
  ) 9>>"$MC_RR_DIR/.lock" 2>/dev/null
  wrc=$?
  [ "$wrc" = 0 ] && { mc_log "$project $key pool re-review marked lane-failed on the hub: $why"; return 0; }
  [ "$wrc" = 4 ] && mc_log "$project $key pool re-review: the job file of ${head:0:8} is already done — not marked"
  return 1
}

# mc_rebase <owner/repo> <project> <branch> <head-sha-read> <url> [<base>]
#   Merge origin/<base> (default main) INTO the branch in a scratch worktree (the reviewed
#   commits keep their shas), resolve only the rebase train's deterministic
#   conflict classes, gate, push with the EXPLICIT lease on the sha this tick
#   read (PR #252), rebind the approval. Prints the new head on success.
#   rc 0 pushed and rebound | 1 conflict (stdout: files) | 2 gate red
#   | 3 lease rejected | 4 setup failed, or the merge/commit itself failed for a
#       non-conflict reason — always LOGGED (`<url> rebase: merge failed — …`);
#       a SHALLOW hub clone is unshallowed once and the merge retried first
#       (BH-517). rc 4 never prints a conflict list of zero files.
#   | 5 PUSHED but the approval rebind FAILED — stdout is still the new head,
#       and the caller must NOT treat it as reviewed (see the rc-5 arm in
#       bin/merge-conductor.sh).
#   | 6 queued on the pool (nothing cloned)
#   | 7 pool queue unreachable, retry next tick, nothing spent
#   | 8 ${TMPDIR:-/tmp} has less than MC_TMP_MIN_FREE_MB free (mc_tmp_room) —
#       LOGGED `tmp full`, nothing fetched, no credential armed (BH-4464)
#   <base> other than main is a STACKED child's open parent branch (BH-5519).
#   The merge, the resolvers and the regenerate then read origin/<base>, and
#   the approval is NEVER rebound: a pushed parent merge answers rc 5, because
#   the parent's commits are not part of the reviewed diff. Under REBASE_ON_POOL
#   such a call answers rc 3, LOGGED, with no hub git: the pool job merges main.
#   The hub's own clone at $MC_REPOS/<project> is preferred when it exists: it
#   is what enables the typecheck/unit gate below. MC_REPOS is overridable so
#   the fixtures can drive both paths.
# mc_hold_push_load — bin/lib/hold-push.sh, beside this module's lib dir, loaded
# on first use for the same reason mc_hold_keeps_pr loads hold.sh: nothing else
# in the conductor sources it. Absent, hold_push is undefined and every push
# below fails closed (rc 3, nothing written) rather than going out unchecked.
mc_hold_push_load() {
  command -v hold_push >/dev/null 2>&1 && return 0
  local f; f="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/hold-push.sh"
  # shellcheck source=bin/lib/hold-push.sh
  [ -r "$f" ] && . "$f" 2>/dev/null
  command -v hold_push >/dev/null 2>&1
}

mc_rebase() {
  local slug="$1" project="$2" br="$3" head="$4" url="$5" base="${6:-main}"
  local repo="${MC_REPOS:-/root/repos}/$project" wt cloned="" rc=0 conf csz new remote ferr hv
  # A HELD TICKET'S BRANCH IS NOT MERGED INTO (BH-2504). #2493, #2552 and #2586
  # took "Merge remote-tracking branch 'origin/main' into HEAD" pushes while a
  # lead held them. Asked BEFORE any work (a merge and a typecheck bought for a
  # push that must not happen is waste) and asked AGAIN at the push, because a
  # HOLD can land while this runs. rc 3 is the caller's "the head moved, come
  # back next tick" answer, which is exactly what a hold is to this lane.
  if mc_hold_push_load; then
    hv=$(hold_push_verdict "$project" - "$br"); case "$?" in
      1) mc_log "$url rebase: HOLD — not merging $base into $br: ${hv#*	} (BH-2504)"; return 3 ;;
      2) mc_log "$url rebase: the ticket's hold could not be read (${hv#*	}) — not merging $base into $br this tick"; return 3 ;;
    esac
  fi
  # BH-486: under REBASE_ON_POOL the rebase is a pool job, not a hub worktree.
  # This sits ABOVE mc_git_auth on purpose — no credential is resolved and no
  # git command runs on the hub from ANY caller, because all four enter here:
  # the tick's inline path (bin/merge-conductor.sh, MC_DETACHED_REBASE=0),
  # mc_rebase_run (the detached job body), br_mechanical in
  # bin/blocked-resolver.sh, and bin/rebase-train-ahead.sh.
  if mc_pool_rebase_enabled "$project"; then
    if [ "$base" != main ]; then
      mc_log "$url rebase: stacked parent merge into $br from $base is not a pool job — skipped (REBASE_ON_POOL)"
      return 3
    fi
    mc_pool_rebase_enqueue "$slug" "$project" "$br" "$head" "$url"; return $?
  fi
  # Below the pool block (a pool rebase uses no hub tmp) and above mc_git_auth,
  # whose askpass mktemp is itself a write to TMPDIR (BH-4464).
  mc_tmp_room "$url" rebase || return 8
  # Every fleet repo is private: a remote no token can read is a setup failure
  # now, not an unauthenticated fetch that fails one line later with its
  # reason discarded (2026-09-13: four rc-4 rebases, nothing said why).
  mc_git_auth "$slug" || { mc_log "$url rebase: no configured token can read $slug — rc 4, see the credential line above"; mc_git_auth_clear; return 4; }
  remote="$MC_REMOTE"
  if [ -d "$repo/.git" ]; then
    wt=$(mktemp -d "${TMPDIR:-/tmp}/mc-rebase-XXXX")
    # The hub clone's origin is the bare https url (gh repo clone wrote it), so
    # git asks askpass for a USERNAME too and gets the token twice — GitHub
    # refuses that pair. Point origin at the x-access-token form (no secret in
    # it) exactly as the scratch-clone path does, and keep the failing command's
    # stderr: rc 4 with nothing said is what hid this for a night (2026-09-13).
    git -C "$repo" remote set-url origin "$remote" >/dev/null 2>&1 || true
    ferr=$(git -C "$repo" -c credential.helper= fetch -q origin "$base" "$br" 2>&1 >/dev/null) || {
      mc_log "$url rebase: fetch on the hub clone failed — $(head -1 <<<"$ferr" | sed 's/github_pat_[A-Za-z0-9_]*/<redacted>/g')"
      rm -rf "$wt"; mc_git_auth_clear; return 4; }
    ferr=$(git -C "$repo" worktree add -f "$wt" "origin/$br" 2>&1 >/dev/null) || {
      mc_log "$url rebase: worktree add on the hub clone failed — $(mc_git_fail_line "$ferr")"
      rm -rf "$wt"; mc_git_auth_clear; return 4; }
  else
    wt="$MC_H/tmp/conductor/${slug//\//_}"; mkdir -p "$(dirname "$wt")"; cloned=1
    if [ ! -d "$wt/.git" ]; then
      git -c credential.helper= clone -q --filter=blob:none "$remote" "$wt" >/dev/null 2>&1 || { mc_git_auth_clear; return 4; }
    else
      # A clone left by an earlier tick may carry the old unauthenticated url.
      git -C "$wt" remote set-url origin "$remote" >/dev/null 2>&1 || true
    fi
    ferr=$(git -C "$wt" -c credential.helper= fetch -q origin "$base" "$br" 2>&1 >/dev/null) || {
      mc_log "$url rebase: fetch on the scratch clone failed — $(head -1 <<<"$ferr" | sed 's/github_pat_[A-Za-z0-9_]*/<redacted>/g')"
      mc_git_auth_clear; return 4; }
    git -C "$wt" checkout -q --detach "origin/$br" 2>/dev/null || { mc_git_auth_clear; return 4; }
  fi
  [ "$(git -C "$wt" rev-parse HEAD)" = "$head" ] || { mc_rebase_cleanup "$repo" "$wt" "$cloned"; return 3; }
  # A FAILED MERGE IS A CONFLICT OR A FATAL, AND THEY ARE NOT THE SAME THING
  # (BH-517). Unmerged paths in the index = a conflict, the arm below. NO
  # unmerged paths = git refused the merge outright and left nothing to
  # resolve; reading that as "everything resolved" is what produced a silent
  # rc 4 from the commit of a merge that never happened.
  # The merge and its resolved commit carry the conductor's identity, as the
  # regenerate and restack writes do (BH-8003: no global identity on the hub).
  local merr cerr healed=""
  while :; do
    if merr=$(git -C "$wt" -c user.name="${MC_GIT_NAME:-$HARNESS_MERGE_GIT_NAME}" -c user.email="${MC_GIT_EMAIL:-$HARNESS_GIT_EMAIL}" \
                merge -q --no-edit "origin/$base" 2>&1 >/dev/null); then
      # A CLEAN merge is not always a healthy one: the `merge=union` attribute
      # on docs/verification-map/README.md resolves that file without ever
      # conflicting, gluing two tables into a README no entry file backs. The
      # repair is rc-0-or-declined and never fails the rung (BH-868).
      mc_resolve_vmap_clean_merge "$wt" "$br" "$head" "origin/$base" || true
      break
    fi
    if [ -n "$(git -C "$wt" diff --name-only --diff-filter=U)" ]; then
      # The policy itself lives in mc_resolve_conflicts (which knows about the
      # generated per-ticket paths and is driven directly by the fixtures); this
      # arm only decides what a leftover conflict means to the caller.
      if ! conf=$(mc_resolve_conflicts "$wt" "$br"); then
        # THE SIZE OF THIS CONFLICT, measured HERE because this is the last moment
        # the markers are in the tree — the abort on the next line takes them with
        # it. Best effort by construction: the whole block is silenced and
        # `|| true`d, so a store this box cannot write can neither change the rc
        # nor print a word into the conflict list the caller reads off stdout.
        { csz=$(mc_conflict_lines "$wt")
          mkdir -p "$MC_CONFLICT_SIZE_DIR"
          printf '%s\t%s\t%s\n' "$csz" "$head" "$(tr '\n' ' ' <<<"$conf" | sed 's/ *$//')" > "$MC_CONFLICT_SIZE_DIR/.tmp.$$"
          mv -f "$MC_CONFLICT_SIZE_DIR/.tmp.$$" "$(mc_conflict_size_file "$slug" "$(mc_num_of_url "$url")")"
        } 2>/dev/null || true
        git -C "$wt" merge --abort >/dev/null 2>&1
        printf '%s\n' "$conf"; mc_rebase_cleanup "$repo" "$wt" "$cloned"; return 1
      fi
      cerr=$(git -C "$wt" -c user.name="${MC_GIT_NAME:-$HARNESS_MERGE_GIT_NAME}" -c user.email="${MC_GIT_EMAIL:-$HARNESS_GIT_EMAIL}" \
                 -c commit.gpgsign=false commit -q --no-edit 2>&1 >/dev/null) || {
        mc_log "$url rebase: commit of the resolved merge failed — $(mc_git_err_line "${cerr:-(no stderr)}")"
        mc_rebase_cleanup "$repo" "$wt" "$cloned"; return 4; }
      break
    fi
    git -C "$wt" merge --abort >/dev/null 2>&1
    # A shallow HUB clone is the known cause of a fatal here, and it is ours to
    # fix: heal it once and retry the merge in this same call. The scratch
    # clone ($cloned) is --filter=blob:none — partial, never shallow — so it is
    # not eligible and a fatal there is only ever reported.
    if [ -z "$healed" ] && [ -z "$cloned" ] && mc_unshallow_once "$repo" "$project" "$url" rebase; then
      healed=1; continue
    fi
    mc_log "$url rebase: merge failed — $(mc_git_err_line "${merr:-(no stderr)}")"
    mc_rebase_cleanup "$repo" "$wt" "$cloned"; return 4
  done
  # BH-969: regenerate the declared generated files over the MERGED tree, before
  # the gates read it and before the push. The node_modules link is hoisted above
  # this on purpose — a regenerate command is as likely to need the repo's deps
  # as the typecheck below is, and linking it after the regenerate would run the
  # generator in a tree without them.
  if [ -d "$repo/node_modules" ] && [ ! -e "$wt/node_modules" ]; then
    ln -s "$repo/node_modules" "$wt/node_modules" 2>/dev/null || true
  fi
  mc_regen_generated "$wt" "origin/$base" "$url rebase"
  # BH-7365: a migration number main already took is renumbered here, over the
  # merged tree and before the gates, so the unit gate and CI read the new
  # number. Its `Union-resolved:` trailers take the rc 5 path below (no
  # rebind). A decline is the "gate red, not pushed" answer; could-not-run
  # goes on unchanged and CI decides. Stacked parent merges are not renumbered.
  if [ "$base" = main ] && command -v mnr_fix >/dev/null 2>&1; then
    local mnr mnrc=0 mnl
    # stderr is a knob warning, never a move: it is logged on its own line.
    mnr=$(mnr_fix "$wt" "origin/$base" "$project" "$br" "${url##*/}" 2>"$wt.mnr-err") || mnrc=$?
    while IFS= read -r mnl; do [ -n "$mnl" ] && mc_log "$url rebase: $mnl"; done < "$wt.mnr-err" 2>/dev/null
    rm -f "$wt.mnr-err"
    case "$mnrc" in
      0) while IFS= read -r mnl; do [ -n "$mnl" ] && mc_log "$url rebase: migration renumbered — $mnl"; done <<<"$mnr" ;;
      1) while IFS= read -r mnl; do [ -n "$mnl" ] && mc_log "$url rebase: migration number collision not fixed — $mnl"; done <<<"$mnr"
         mc_rebase_cleanup "$repo" "$wt" "$cloned"; return 2 ;;
      *) mc_log "$url rebase: ${mnr:-migration renumber could not run} — going on unchanged" ;;
    esac
  fi
  # Gates the hub can run: typecheck + unit when node_modules is at hand (the
  # hub clones); otherwise CI is the gate and the PR goes WAIT_CI honestly.
  if [ -d "$repo/node_modules" ]; then
    if jq -e '.scripts.typecheck' "$wt/package.json" >/dev/null 2>&1; then
      ( cd "$wt" && NODE_OPTIONS=--max-old-space-size=12288 npm run typecheck >/dev/null 2>&1 ) || { mc_rebase_cleanup "$repo" "$wt" "$cloned"; return 2; }
    fi
    if jq -e '.scripts["test:unit"]' "$wt/package.json" >/dev/null 2>&1; then
      ( cd "$wt" && npm run test:unit >/dev/null 2>&1 ) || { mc_rebase_cleanup "$repo" "$wt" "$cloned"; return 2; }
    fi
  fi
  new=$(git -C "$wt" rev-parse HEAD)
  # BH-4641: what the append-union step resolved in THIS rebase, read from the
  # trailers of every first-parent commit this run added on top of $head
  # (earlier union commits on the branch are not this rebase's concern). Not
  # `log -1`: mc_regen_generated above may have committed a regenerate on top
  # of the union merge, and reading only HEAD would then rebind an approval
  # onto machine-written lines nobody reviewed.
  local union
  union=$(git -C "$wt" log --first-parent --format=%B "$head..HEAD" 2>/dev/null | sed -n 's/^Union-resolved: //p' | tr '\n' ';' | sed 's/;$//')
  # The remote is named EXPLICITLY rather than as `origin`: on the hub-clone
  # path `origin` is whatever that checkout was set up with, and it is the same
  # GitHub repo either way. One credential, both paths.
  # THE QUEUE IS READ AGAIN AT THE PUSH (BH-8021). A detached rebase runs for
  # minutes, and the PR can enter the Mergify queue while it runs (project-6
  # #2309: queued at ~11:31Z, this push at 11:42Z, Mergify dequeued it). If
  # Mergify holds the PR now, the result is dropped and nothing is pushed:
  # rc 3, the caller's "come back next tick". A read that fails does not stop
  # the push; the land arm already read it before the spawn.
  if [ "$base" = main ] && command -v mc_mergify_holds >/dev/null 2>&1 \
     && [ "$(mc_queue_provider "$slug" 2>/dev/null)" = mergify ]; then
    local mqwhy mqrc
    mqwhy=$(mc_mergify_holds "$slug" "$url" "$head"); mqrc=$?
    case "$mqrc" in
      0) mc_log "$url rebase: SKIP_PUSH mergify-queue: $mqwhy on ${head:0:8} — the rebase result ${new:0:8} is dropped, nothing pushed (BH-8021)"
         mc_rebase_cleanup "$repo" "$wt" "$cloned"; return 3 ;;
      2) mc_log "$url rebase: the Mergify check runs on ${head:0:8} could not be read at the push — pushing as before (BH-8021)" ;;
    esac
  fi
  # The push re-reads the hold and leases on the head this run started from
  # (BH-2504): mc_rebase's merge and mc_restack's rebase both rewrite a PR branch.
  local prat; prat=$(prr_now)
  if ! { mc_hold_push_load && HOLD_PUSH_LOG="${MC_LOG:-}" hold_push -n "$project" - "$wt" "$remote" HEAD "$br" "$head" >/dev/null 2>&1; }; then
    mc_rebase_cleanup "$repo" "$wt" "$cloned"; return 3
  fi
  prr_note_push "$slug" "$(mc_num_of_url "$url")" "$prat" "$wt" HEAD "$head"
  # A UNION-RESOLVED MERGE IS NOT A CLEAN MAIN MERGE (BH-4641, iron guardrail 1).
  # The resolution wrote code no reviewer has read, so the approval stays on the
  # old head: no reviewed-sha write, no ledger rebind, rc 5. Every caller already
  # reads rc 5 as "pushed, approval still on the old sha", and the head-bound
  # re-review then reads the new head.
  if [ -n "$union" ]; then
    mc_log "$url pushed ${new:0:8} — union-resolved ($union): approval deliberately NOT rebound (a resolved merge is not a clean main merge; iron guardrail 1), the head-bound re-review reads the new head (BH-4641)"
    mc_rebase_cleanup "$repo" "$wt" "$cloned"
    printf '%s' "$new"
    return 5
  fi
  # A PARENT MERGE IS NOT A MAIN MERGE (BH-5519). The PR's diff is read against
  # a parent branch that just moved, so no patch-same proof covers this push:
  # the approval stays on the old head, as for a union-resolved merge.
  if [ "$base" != main ]; then
    mc_log "$url pushed ${new:0:8} — merged parent branch $base: approval deliberately NOT rebound (BH-5519)"
    mc_rebase_cleanup "$repo" "$wt" "$cloned"
    printf '%s' "$new"
    return 5
  fi
  local rec rbrc=0; rec=$(mc_record_for "$url" || true)
  [ -n "$rec" ] && [ -s "$rec/reviewed-sha" ] && echo "$new" > "$rec/reviewed-sha"
  # The record half is a no-op for pool builds (bin/fly-pool.sh does not relay
  # reviewed-sha), so the LEDGER rebind is what actually carries the approval
  # forward. rc 1 = no row or an outage, rc 2 = the row makes no head claim to
  # move; on either the approval is still bound to the OLD sha, so reporting
  # success here would have the conductor go WAIT_CI as if rebound and the sweep
  # then park the PR on a sha nobody approved. Say so, and hand back rc 5.
  if type job_verdict_rebind >/dev/null 2>&1; then
    job_verdict_rebind "$url" "$new" >/dev/null 2>&1 || rbrc=$?
  fi
  mc_rebase_cleanup "$repo" "$wt" "$cloned"
  printf '%s' "$new"
  if [ "$rbrc" != 0 ]; then
    mc_log "$url pushed ${new:0:8} but job_verdict_rebind returned $rbrc — the approval is STILL bound to ${head:0:8}; NOT treating this as rebound"
    return 5
  fi
  return 0
}
# mc_restack <owner/repo> <project> <branch> <head-sha-read> <old-base> <new-base> <url>
#   MOVE a stacked child off a dead parent branch and onto the branch that
#   replaced it (BH-458). `git rebase --onto <new-base> <old-base>` replays only
#   the commits the child added on top of the dead parent, so the child's diff
#   stays one ticket's work and none of the abandoned parent's commits ride
#   along. That is the whole reason this is not mc_rebase: mc_rebase MERGES
#   origin/main into the branch, which on a stacked child would pull the dead
#   parent's tree in with it.
#   rc 0 pushed (stdout: the new head) | 1 conflict (stdout: the files)
#   | 3 the head moved under us / the push lease was refused | 4 setup failed,
#       or the rebase itself failed for a non-conflict reason — LOGGED
#       (`<url> restack: rebase --onto failed — …`), stdout empty (BH-517)
#   | 6 <old-base> is a sha that is not an ancestor of the head — LOGGED,
#       nothing rebased or pushed (BH-1670)
#   | 8 TMPDIR too full to start (mc_tmp_room), as mc_rebase's rc 8 (BH-4464)
#
#   <old-base> is a branch name OR a 40-hex commit sha (BH-1670). A sha is the
#   parent's pre-merge head: after a squash merge the parent branch may already
#   be gone, and the sha is the exact upstream anyway. It is used bare (never
#   `origin/<sha>`) and never fetched: a child cut from that head already has it
#   in its own history. A sha that is NOT in the head's history means the parent
#   was rewritten after the child was cut, and `<sha>..HEAD` would replay the
#   parent's old commits too — so that is never rebased blind. BH-5234 (#5053):
#   bin/lib/stale-parent.sh looks for the child's real fork point by patch-id —
#   the leading run of its first-parent commits whose patches are already on
#   <new-base> (one by one after a rebased parent landed, or cumulatively after
#   a squash). When one is PROVEN, only the child's own non-merge commits are
#   replayed onto <new-base> (sync merges are dropped), and the push happens
#   only when every replayed commit kept its own patch-id. No proof, an
#   interleaved range, or a changed own diff is rc 6 exactly as before.
#
#   THE CHILD'S OWN CHILDREN (BH-5234). Every restack rewrites <branch>, so the
#   open PRs based on it are read before the push (unreadable = rc 3, owed,
#   never a blind push), the push says HOLD_PUSH_CHILDREN=follow to
#   bin/lib/hold-push.sh's rewrite guard, and each of them is then owed a
#   restack from <branch>'s OLD head (mc_stack_pending_put), which the drain
#   does on the ancestor path.
#
#   NO LOCAL GATE, unlike mc_rebase. A restacked child's CI runs on the new head
#   (the push is a `synchronize`, and the caller kicks it besides) and its
#   approval is bound to the OLD head, so the head-bound re-review reads the new
#   one before anything merges. Two more gates in front of that would cost a
#   typecheck per restack and answer a question already being asked.
#
#   NO APPROVAL REBIND EITHER. The child's commits are rewritten onto a
#   different base, so the approval that was bound to the old head is about code
#   that no longer exists in that shape. The row goes to the ordinary moved-head
#   path, which re-reviews it — or rebinds for free when the patch-id turns out
#   identical, which after a clean rebase it usually is.
mc_restack() {
  local slug="$1" project="$2" br="$3" head="$4" oldbase="$5" newbase="$6" url="$7"
  local repo="${MC_REPOS:-/root/repos}/$project" wt cloned="" conf new remote ferr
  [ -n "$br" ] && [ -n "$head" ] && [ -n "$oldbase" ] && [ -n "$newbase" ] || return 4
  local upstream="origin/$oldbase" refs=("$newbase" "$oldbase" "$br")
  if [[ "$oldbase" =~ ^[0-9a-f]{40}$ ]]; then upstream="$oldbase"; refs=("$newbase" "$br"); fi
  mc_tmp_room "$url" restack || return 8
  mc_git_auth "$slug" || { mc_log "$url restack: no configured token can read $slug — rc 4, see the credential line above"; mc_git_auth_clear; return 4; }
  remote="$MC_REMOTE"
  if [ -d "$repo/.git" ]; then
    wt=$(mktemp -d "${TMPDIR:-/tmp}/mc-restack-XXXX")
    git -C "$repo" remote set-url origin "$remote" >/dev/null 2>&1 || true
    ferr=$(git -C "$repo" -c credential.helper= fetch -q origin "${refs[@]}" 2>&1 >/dev/null) || {
      mc_log "$url restack: fetch on the hub clone failed — $(head -1 <<<"$ferr" | sed 's/github_pat_[A-Za-z0-9_]*/<redacted>/g')"
      rm -rf "$wt"; mc_git_auth_clear; return 4; }
    ferr=$(git -C "$repo" worktree add -f "$wt" "origin/$br" 2>&1 >/dev/null) || {
      mc_log "$url restack: worktree add on the hub clone failed — $(mc_git_fail_line "$ferr")"
      rm -rf "$wt"; mc_git_auth_clear; return 4; }
  else
    wt="$MC_H/tmp/conductor/${slug//\//_}"; mkdir -p "$(dirname "$wt")"; cloned=1
    if [ ! -d "$wt/.git" ]; then
      git -c credential.helper= clone -q --filter=blob:none "$remote" "$wt" >/dev/null 2>&1 || { mc_git_auth_clear; return 4; }
    else
      git -C "$wt" remote set-url origin "$remote" >/dev/null 2>&1 || true
    fi
    ferr=$(git -C "$wt" -c credential.helper= fetch -q origin "${refs[@]}" 2>&1 >/dev/null) || {
      mc_log "$url restack: fetch on the scratch clone failed — $(head -1 <<<"$ferr" | sed 's/github_pat_[A-Za-z0-9_]*/<redacted>/g')"
      mc_git_auth_clear; return 4; }
    git -C "$wt" checkout -q --detach "origin/$br" 2>/dev/null || { mc_git_auth_clear; return 4; }
  fi
  # The lease, taken exactly as mc_rebase takes it: a head that moved since this
  # tick read it is somebody else's work, and replaying onto it blind would
  # rewrite a commit nothing here has seen.
  [ "$(git -C "$wt" rev-parse HEAD)" = "$head" ] || { mc_rebase_cleanup "$repo" "$wt" "$cloned"; return 3; }
  # bin/lib/stale-parent.sh beside this module's lib dir (BH-5234). Absent,
  # mc_restack keeps its pre-BH-5234 behaviour: a rewritten parent is rc 6 and
  # the push reads no children.
  local replayed="" sp_ok=""
  command -v sp_fork_point >/dev/null 2>&1 \
    || . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/stale-parent.sh" 2>/dev/null
  command -v sp_fork_point >/dev/null 2>&1 && sp_ok=1
  if [ "$upstream" = "$oldbase" ] && ! git -C "$wt" merge-base --is-ancestor "$oldbase" HEAD >/dev/null 2>&1; then
    # BH-5234: the parent was rewritten after this branch was cut. Its landed
    # copy is found by patch-id, or nothing moves.
    local sp_rc=0 fork="" why="" nown nmerge
    if [ -n "$sp_ok" ]; then
      fork=$(sp_fork_point "$wt" "origin/$newbase" HEAD) || sp_rc=$?
    else
      sp_rc=9
    fi
    case "$sp_rc" in
      0)
        nown=$(sp_own_commits "$wt" "$fork" HEAD | wc -l)
        nmerge=$(git -C "$wt" rev-list --count --first-parent --merges "$fork..HEAD" 2>/dev/null || echo 0)
        sp_rc=0; conf=$(sp_replay "$wt" "origin/$newbase" "$fork" "$head") || sp_rc=$?
        case "$sp_rc" in
          0) replayed=1
             mc_log "$url restack: parent rewritten — fork point ${fork:0:8} by patch-id, $nown own commit(s) replayed, $nmerge sync merge(s) dropped" ;;
          1) printf '%s\n' "$conf"; mc_rebase_cleanup "$repo" "$wt" "$cloned"; return 1 ;;
          7) why="own diff changed: ${conf:0:8}'s patch-id differs after the replay onto $newbase" ;;
          *) mc_log "$url restack: the replay from fork point ${fork:0:8} could not be set up (rc $sp_rc)"
             mc_rebase_cleanup "$repo" "$wt" "$cloned"; return 4 ;;
        esac ;;
      2) why="interleaved: a commit already on $newbase sits after one of this branch's own" ;;
      9) why="bin/lib/stale-parent.sh is not loaded" ;;
      *) why="no fork point by patch-id" ;;
    esac
    if [ -z "$replayed" ]; then
      mc_log "$url restack: ${oldbase:0:8} is not an ancestor of ${head:0:8} (the parent was rewritten after this branch was cut; $why) — rc 6, nothing rebased"
      mc_rebase_cleanup "$repo" "$wt" "$cloned"; return 6
    fi
  fi
  # The identity is passed in rather than assumed: a rebase writes commits, and
  # a box with no global user.email fails the whole thing with "unable to
  # auto-detect email address" (bin/review-rescue.sh carries the same note). The
  # AUTHOR of each replayed commit is untouched — this is the committer only.
  # Same classification as mc_rebase's merge (BH-517): unmerged paths = a
  # conflict the caller can hand to a fix round; none = git refused the rebase
  # outright (a missing upstream, a shallow clone), and printing an empty
  # conflict list as rc 1 tells the caller "a conflict in zero files".
  local rerr
  # BH-6000: a replayed commit that conflicts only in a regenerated path
  # (config/regenerated-paths.conf, e.g. worker/jobs/schema.sql) is re-rendered
  # and the rebase goes on (mc_rebase_regen_continue). Anything else is the
  # conflict it always was.
  [ -n "$replayed" ] || rerr=$(git -C "$wt" -c user.name="${MC_GIT_NAME:-$HARNESS_MERGE_GIT_NAME}" -c user.email="${MC_GIT_EMAIL:-$HARNESS_GIT_EMAIL}" \
           -c commit.gpgsign=false rebase --onto "origin/$newbase" "$upstream" 2>&1 >/dev/null) \
    || mc_rebase_regen_continue "$wt" "$url restack" || {
    conf=$(git -C "$wt" diff --name-only --diff-filter=U)
    git -C "$wt" rebase --abort >/dev/null 2>&1
    if [ -n "$conf" ]; then printf '%s\n' "$conf"; mc_rebase_cleanup "$repo" "$wt" "$cloned"; return 1; fi
    mc_log "$url restack: rebase --onto failed — $(mc_git_err_line "${rerr:-(no stderr)}")"
    mc_rebase_cleanup "$repo" "$wt" "$cloned"; return 4; }
  new=$(git -C "$wt" rev-parse HEAD)
  # This branch's own open children, read BEFORE the push (BH-5234): the push
  # rewrites their parent, so each is owed a restack from the head they were cut
  # from. A list that cannot be proven is not "no children" — the restack stays
  # owed (rc 3). With no stale-parent lib the push goes out as before.
  local kids="" krc=0 kid
  if [ -n "$sp_ok" ]; then
    kids=$(sp_open_children "$slug" "$br") || krc=$?
    if [ "$krc" != 0 ]; then
      mc_log "$url restack: the open children of $br could not be read ($kids) — not pushed, still owed"
      mc_rebase_cleanup "$repo" "$wt" "$cloned"; return 3
    fi
  fi
  # The push re-reads the hold and leases on the head this run started from
  # (BH-2504): mc_rebase's merge and mc_restack's rebase both rewrite a PR branch.
  # HOLD_PUSH_CHILDREN=follow: this is the one sanctioned rewrite of a parent,
  # because its children are followed just below.
  local prat; prat=$(prr_now)
  if ! { mc_hold_push_load && HOLD_PUSH_CHILDREN=follow HOLD_PUSH_LOG="${MC_LOG:-}" hold_push -n "$project" - "$wt" "$remote" HEAD "$br" "$head" >/dev/null 2>&1; }; then
    mc_rebase_cleanup "$repo" "$wt" "$cloned"; return 3
  fi
  prr_note_push "$slug" "$(mc_num_of_url "$url")" "$prat" "$wt" HEAD "$head"
  for kid in $kids; do
    if mc_stack_pending_put "$slug" "$kid" "${url##*/}" "$url" "$br" "$head" "$br"; then
      mc_log "$url restack: $slug#$kid is based on $br — owed a restack from its old head ${head:0:8} onto the new ${new:0:8}"
    else
      mc_log "$url restack: $slug#$kid is based on $br and its restack record could not be written — rebase it onto $br by hand"
    fi
  done
  mc_rebase_cleanup "$repo" "$wt" "$cloned"
  printf '%s' "$new"
  return 0
}
mc_rebase_cleanup() { # <repo> <wt> <cloned>
  mc_git_auth_clear
  if [ -n "$3" ]; then git -C "$2" merge --abort >/dev/null 2>&1; git -C "$2" checkout -q --detach origin/main >/dev/null 2>&1; return 0; fi
  git -C "$1" worktree remove -f "$2" >/dev/null 2>&1; rm -rf "$2"
}
# --- A PARENT THE CONDUCTOR MERGED: FOLLOW ITS CHILDREN (BH-1670) ----------
# project-5 #3180 sat on #3117 after the parent squash-merged: GitHub moved its
# base to main, but its branch still carried the parent's pre-squash commits and
# nothing pushed it, so it had no CI run and a diff two tickets wide. So when
# conductor_settle writes a parent MERGED, each OPEN child (base.ref == the
# parent's branch) is retargeted to the base FIRST, then rebased
# `--onto <base> <parent's pre-merge head sha>` and pushed ONCE. That push is a
# `synchronize` on a PR that is already based on main, so it is the CI trigger;
# no close/reopen kick runs on this path (a kick after a push cancels its run).
#
# The owed work is one file per child, written BEFORE anything is sent:
#   $MC_H/state/stack-follow/<owner_repo>#<child>
#   <parent-num> <parent-url> <parent-branch> <parent-head> <base> <attempts> <since>
# The settle writes it and follows the child at once when it can take the
# child's PR lock (flock -n). When the child's own worker holds that lock the
# file waits for pr_worker, which drains it before the stacked block. A newer
# parent head for the same child overwrites it: the later merge is the one that
# counts. It is removed on every terminal outcome, and after MC_STACK_FOLLOW_TRIES
# failed tries or MC_STACK_FOLLOW_GIVEUP_S seconds (registry knobs, BH-1715) it
# is dropped with ONE alert that says what to do by hand. bin/lib/gh-pr-merge.sh
# `_gpm_owe_restack` writes the same record when merge-sweep or poll-commands
# retargets a child off a parent they merged (BH-1715).
mc_stack_pending_file() { printf '%s/state/stack-follow/%s#%s' "$MC_H" "${1//\//_}" "$2"; }

# mc_stack_pending_put <slug> <child> <parent-num> <parent-url> <parent-branch>
#                      <parent-head> <base> [attempts] [since]
mc_stack_pending_put() {
  local f tmp
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${6:-}" ] && [ -n "${7:-}" ] || return 1
  f=$(mc_stack_pending_file "$1" "$2"); tmp="$f.tmp.$$"
  mkdir -p "${f%/*}" 2>/dev/null || return 1
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${3:--}" "${4:--}" "${5:--}" "$6" "$7" "${8:-0}" "${9:-$(mc_now)}" > "$tmp" \
    && mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}
# mc_stack_pending_get <slug> <child> -> the line; rc 1 when nothing is owed
mc_stack_pending_get() {
  local f; f=$(mc_stack_pending_file "${1:-}" "${2:-}")
  [ -s "$f" ] || return 1
  head -n 1 "$f"
}
mc_stack_pending_clear() { rm -f "$(mc_stack_pending_file "${1:-}" "${2:-}")"; }

# mc_stack_parent_moved <slug> <project> <child-branch> <child-head> <parent-branch>
#   BH-5796: has the OPEN parent branch moved past this child? Fetches the two
#   branches into the hub clone ($MC_REPOS/<project>) or, without one, the
#   scratch clone mc_rebase uses, and asks git whether the parent's tip is in
#   the child's history.
#   rc 0 moved (stdout: the parent tip) | 1 not moved (stdout: the parent tip)
#   | 2 unreadable (stdout: why). The child head on origin must still be
#   <child-head>; a head that moved under us is unreadable this tick.
mc_stack_parent_moved() {
  local slug="$1" project="$2" cbr="$3" chead="$4" pbr="$5" repo ferr ph oh
  repo="${MC_REPOS:-/root/repos}/$project"
  [ -n "$cbr" ] && [ -n "$chead" ] && [ -n "$pbr" ] || { printf 'missing branch or head'; return 2; }
  mc_git_auth "$slug" || { mc_git_auth_clear; printf 'no configured token can read %s' "$slug"; return 2; }
  if [ ! -d "$repo/.git" ]; then
    repo="$MC_H/tmp/conductor/${slug//\//_}"; mkdir -p "$(dirname "$repo")"
    if [ ! -d "$repo/.git" ]; then
      git -c credential.helper= clone -q --filter=blob:none "$MC_REMOTE" "$repo" >/dev/null 2>&1 \
        || { mc_git_auth_clear; printf 'scratch clone failed'; return 2; }
    fi
  fi
  git -C "$repo" remote set-url origin "$MC_REMOTE" >/dev/null 2>&1 || true
  ferr=$(git -C "$repo" -c credential.helper= fetch -q origin "$pbr" "$cbr" 2>&1 >/dev/null) || {
    mc_git_auth_clear; printf 'fetch failed: %s' "$(head -1 <<<"$ferr" | sed 's/github_pat_[A-Za-z0-9_]*/<redacted>/g')"; return 2; }
  mc_git_auth_clear
  ph=$(git -C "$repo" rev-parse -q --verify "origin/$pbr^{commit}" 2>/dev/null) || { printf 'no origin/%s' "$pbr"; return 2; }
  oh=$(git -C "$repo" rev-parse -q --verify "origin/$cbr^{commit}" 2>/dev/null)
  [ "$oh" = "$chead" ] || { printf 'the child head moved (%s, not %s)' "${oh:0:8}" "${chead:0:8}"; return 2; }
  printf '%s' "$ph"
  git -C "$repo" merge-base --is-ancestor "$ph" "$chead" >/dev/null 2>&1 && return 1
  return 0
}

# mc_stack_children <slug> <parent-branch> -> open child numbers, one a line
#   rc 0 = the list is PROVEN complete (possibly empty); rc 1 = stdout is why
#   it is not (a failed read, a full page, no lib). Never "no children" on a
#   failure (D11/D12).
mc_stack_children() {
  command -v _gpm_open_children >/dev/null 2>&1 || { printf 'bin/lib/gh-pr-merge.sh is not loaded'; return 1; }
  _gpm_open_children "${1:-}" "${2:-}"
}

# mc_stack_follow <project> <slug> <child> <parent-num> <parent-url>
#                 <parent-branch> <parent-head> <base>
#   rc 0 done: stdout is the pushed head, or EMPTY when nothing was ours to do
#        (child not open, a fork, the parent sha not in its history) and the
#        stacked block's own retarget is left to handle it
#   rc 1 the replay conflicts: the row is parked for bin/blocked-resolver.sh
#   rc 3 not done this time (observe mode, a hold, a failed read, a refused
#        retarget, a lease or setup failure): the follow stays owed
mc_stack_follow() {
  local proj="$1" slug="$2" kid="$3" pn="$4" purl="$5" pbr="$6" phead="$7" base="$8"
  local key="$slug#$kid" url="https://github.com/$slug/pull/$kid" j rc st cbr chead cbase crepo out row files
  if [ "$ACTIONS" != 1 ]; then
    mc_log "would restack $key onto $base (parent=#$pn, upstream ${phead:0:8}) — observe mode, nothing written; the first actions tick does it"
    return 3
  fi
  if mc_hold_keeps_pr "$slug" "$kid"; then
    mc_log "$key is on HOLD — the restack after parent=#$pn merged is left owed, nothing pushed"
    return 3
  fi
  rc=0; j=$(mc_rest_pr_json "$slug" "$kid") || rc=$?
  if [ "$rc" != 0 ]; then
    _mc_stack_follow_retry "$key" "$slug" "$kid" "$pn" "$purl" "$pbr" "$phead" "$base" \
      "the child could not be read (HTTP ${GH_REST_STATUS:-000})"; return 3
  fi
  IFS=$'\t' read -r st cbr chead cbase crepo < <(printf '%s' "$j" \
    | jq -r '[.STATE, (.head.ref // ""), (.head.sha // ""), (.base.ref // ""), (.head.repo.full_name // "")] | map(if . == "" then "-" else . end) | @tsv' 2>/dev/null)
  if [ "${st:-}" != OPEN ] && [ -n "${st:-}" ]; then
    mc_stack_pending_clear "$slug" "$kid"
    mc_log "$key is ${st} — nothing to restack after parent=#$pn merged"; return 0
  fi
  if [ -z "${st:-}" ] || [ "${cbr:--}" = - ] || [ "${chead:--}" = - ]; then
    _mc_stack_follow_retry "$key" "$slug" "$kid" "$pn" "$purl" "$pbr" "$phead" "$base" \
      "the child read had no state, head ref or head sha"; return 3
  fi
  if [ "$crepo" != "$slug" ]; then
    mc_stack_pending_clear "$slug" "$kid"
    mc_log "$key head lives in ${crepo} — not $slug, so this lane does not push it; the stacked block's retarget handles its base"
    return 0
  fi
  if [ "$cbase" != "$base" ]; then
    if ! mc_retarget_base "$slug" "$kid" "$base"; then
      _mc_stack_follow_retry "$key" "$slug" "$kid" "$pn" "$purl" "$pbr" "$phead" "$base" \
        "the base PATCH to $base was refused (nothing pushed while it still points at $cbase)"; return 3
    fi
  fi
  rc=0; out=$(mc_restack "$slug" "$proj" "$cbr" "$chead" "$phead" "$base" "$url") || rc=$?
  case "$rc" in
    0)
      mc_stack_pending_clear "$slug" "$kid"
      mc_attempt_put "stackfollow $key $out"
      printf '%s\t%s\n' "${MC_TICK_ID:-notick}" "$out" > "$(mc_stack_pending_file "$slug" "$kid").pushed"
      mc_log "$key restacked onto $base after parent=#$pn merged: retargeted, rebased onto $base (${out:0:8}) and pushed; the push is the CI trigger"
      printf '%s' "$out"; return 0 ;;
    1)
      files=$(tr '\n' ' ' <<<"$out" | sed 's/ *$//')
      # A REPLAY CONFLICT IS NOT A PARK YET (BH-5967). 9 approved stacked
      # children sat parked for hours on 2026-10-10 asking for a human rebase,
      # and nobody rebases by hand. So the conductor merges $base INTO the child
      # (mc_rebase: the reviewed commits keep their shas, the deterministic
      # conflict classes resolve, the gate runs, the push carries a lease). A
      # push re-runs CI; an approval the merge-main rule does not rebind sends
      # the row down the moved-head path, which re-requests the review. Only a
      # merge that still conflicts, or a red gate, goes to a fix round.
      local mrc=0 mout
      mout=$(mc_rebase "$slug" "$proj" "$cbr" "$chead" "$url" "$base") || mrc=$?
      case "$mrc" in
        0|5)
          mc_stack_pending_clear "$slug" "$kid"
          mc_attempt_put "stackfollow $key $mout"
          printf '%s\t%s\n' "${MC_TICK_ID:-notick}" "$mout" > "$(mc_stack_pending_file "$slug" "$kid").pushed"
          if [ "$mrc" = 0 ]; then
            mc_log "$key STACK_MAIN_MERGED ${mout:0:8}: parent=#$pn merged and the replay onto $base conflicted in $files, so $base was merged into the child instead and pushed; the approval is rebound by the merge-main rule and CI re-runs on the push"
          else
            mc_log "$key STACK_MAIN_MERGED ${mout:0:8}: parent=#$pn merged and the replay onto $base conflicted in $files, so $base was merged into the child instead and pushed; the approval is NOT rebound, so the moved-head path re-requests the review and CI re-runs on the push"
          fi
          printf '%s' "$mout"; return 0 ;;
        1|2) [ "$mrc" = 1 ] && files=$(tr '\n' ' ' <<<"$mout" | sed 's/ *$//') ;;
        6)
          mc_stack_pending_clear "$slug" "$kid"
          mc_log "$key parent=#$pn merged and the replay onto $base conflicted in $files — the merge of $base into the child is queued on the pool (REBASE_ON_POOL); its push re-runs CI, and a pool conflict parks the row on the rebase path"
          return 0 ;;
        *)
          _mc_stack_follow_retry "$key" "$slug" "$kid" "$pn" "$purl" "$pbr" "$phead" "$base" \
            "the replay conflicted and merging $base into the child answered rc $mrc (held, lease or setup)"; return 3 ;;
      esac
      row=$(mc_row_get "$key")
      # rc 2: the merge was clean and its gate went red, so the reason says
      # that, not "both conflict" (review of 99682a0c6). rebase-gate-red is
      # the resolver's too (mc_resolver_owns).
      if [ "$mrc" = 2 ]; then
        mc_transition "$key" BLOCKED_HUMAN "rebase-gate-red: stacked child of parent=#$pn ($purl) — rebase --onto $base conflicted in: $files; the merge of $base was clean but its typecheck/unit gate is red" \
          "$chead" "$(cut -f5 <<<"$row")" "$url" - UNKNOWN "$(mc_record_for "$url" || true)" >/dev/null
        mc_log "$key BLOCKED_AGENT rebase-gate-red: stacked child of parent=#$pn ($purl) — the replay onto $base conflicted in $files, the merge of $base was clean, and its gate is red — handed to bin/blocked-resolver.sh's fix round: $url"
        mc_stack_pending_clear "$slug" "$kid"
        return 1
      fi
      mc_transition "$key" BLOCKED_HUMAN "conflict-unresolvable: stacked child of parent=#$pn ($purl) — rebase --onto $base and a merge of $base both conflict in: $files" \
        "$chead" "$(cut -f5 <<<"$row")" "$url" - UNKNOWN "$(mc_record_for "$url" || true)" >/dev/null
      mc_log "$key BLOCKED_AGENT conflict-unresolvable: stacked child of parent=#$pn ($purl) — rebase --onto $base and a merge of $base both conflict in: $files — handed to bin/blocked-resolver.sh (its ladder: merge main again, then an agent fix round on this branch, then a fresh rebuild) — $(mc_park_human_action conflict-unresolvable): $url"
      mc_stack_pending_clear "$slug" "$kid"
      return 1 ;;
    6)
      mc_stack_pending_clear "$slug" "$kid"
      mc_log "$key parent=#$pn head ${phead:0:8} is not an ancestor of ${chead:0:8} — not restacked; left to the stacked block's retarget and CI kick"
      return 0 ;;
    *)
      _mc_stack_follow_retry "$key" "$slug" "$kid" "$pn" "$purl" "$pbr" "$phead" "$base" \
        "the restack answered rc $rc (lease refused or setup failed)"; return 3 ;;
  esac
}
# One more failed try on an owed follow: counted, and given up with ONE alert
# after MC_STACK_FOLLOW_TRIES tries or MC_STACK_FOLLOW_GIVEUP_S seconds, so the
# wait is never silent. Both are required registry knobs (BH-1715) with no
# literal here: a limit that does not resolve to a positive integer gives up on
# this try, with the same alert naming the knob, never an endless retry.
_mc_stack_follow_retry() {
  local key="$1" slug="$2" kid="$3" pn="$4" purl="$5" pbr="$6" phead="$7" base="$8" why="$9" line n since tries giveup
  if command -v lane_knob >/dev/null 2>&1; then
    tries=$(lane_knob merge-conductor MC_STACK_FOLLOW_TRIES 2>/dev/null)
    giveup=$(lane_knob merge-conductor MC_STACK_FOLLOW_GIVEUP_S 2>/dev/null)
  else
    tries="${MC_STACK_FOLLOW_TRIES:-}"; giveup="${MC_STACK_FOLLOW_GIVEUP_S:-}"
  fi
  line=$(mc_stack_pending_get "$slug" "$kid") || line=""
  n=$(cut -f6 <<<"$line"); since=$(cut -f7 <<<"$line")
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  case "$since" in ''|*[!0-9]*) since=$(mc_now) ;; esac
  n=$((n + 1))
  case "$tries" in ''|*[!0-9]*|0) why="$why; MC_STACK_FOLLOW_TRIES did not resolve to a positive number ('${tries:-unset}')"; tries=0 ;; esac
  case "$giveup" in ''|*[!0-9]*|0) why="$why; MC_STACK_FOLLOW_GIVEUP_S did not resolve to a positive number ('${giveup:-unset}')"; giveup=0 ;; esac
  if [ "$n" -ge "$tries" ] || [ $(( $(mc_now) - since )) -ge "$giveup" ]; then
    mc_stack_pending_clear "$slug" "$kid"
    mc_log "$key restack after parent=#$pn given up after $n tries: $why"
    mc_alert "$key" STACK_FOLLOW "stacked child of #$pn ($purl) could not be restacked after $n tries ($why); its branch may still carry the parent's pre-squash commits. Run \`git rebase --onto origin/$base ${phead}\` on it and push, or let bin/blocked-resolver.sh rebuild it: https://github.com/$slug/pull/$kid"
    return 0
  fi
  mc_stack_pending_put "$slug" "$kid" "$pn" "$purl" "$pbr" "$phead" "$base" "$n" "$since"
  mc_log "$key restack after parent=#$pn not done (try $n of $tries): $why — still owed"
}
# --- GENERATED PER-TICKET PATHS ----------------------------------------------
# The conflict class that was costing a rebuild a time (2026-09-16, project-5:
# 7 of 14 open PRs DIRTY, the MERGE_TREE log add/add on docs/build-log/waves/
# TK-<n>.md and .harness/specs/TK-<n>/plan.md). These files are HARNESS OUTPUT,
# one per ticket, never hand-edited. A branch cut from a stale base carries its
# own copy of a SIBLING ticket's wave doc or plan; the sibling merges first; git
# sees two unrelated additions at one path and calls it a conflict. There is
# nothing to reconcile — main's copy is the real one.
#
# The rule, and it is deliberately narrow:
#   this PR's own ticket's file -> OURS (the branch: it is the build's output)
#   another ticket's file       -> THEIRS (main: the branch's copy is a fossil)
#   no ticket key in the path   -> NOT ours to resolve, a real conflict
# Every path outside config/generated-paths.conf stays a real conflict.
MC_GENERATED_PATHS_CONF="${MC_GENERATED_PATHS_CONF:-$MC_H/config/generated-paths.conf}"
# The compiled-in fallback, so a box (or a pool image, which bakes bin/ and not
# config/) that has not yet taken the conf file behaves identically. Keep this in
# step with config/generated-paths.conf — that file says so too.
MC_GENERATED_PATHS_DEFAULT='docs/build-log/waves/*.md
.harness/specs/*/'

# mc_generated_globs — the allowlist, one glob per line, comments stripped.
mc_generated_globs() {
  # A directory is not a conf (BH-2210): it reads as an empty table, not absent.
  if [ -f "$MC_GENERATED_PATHS_CONF" ] && [ -r "$MC_GENERATED_PATHS_CONF" ]; then
    sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$MC_GENERATED_PATHS_CONF" \
      | grep -v '^$'
  else
    printf '%s\n' "$MC_GENERATED_PATHS_DEFAULT"
  fi
}

# mc_path_is_generated <path> — rc 0 when the path is on the allowlist.
#   A glob ending in `/` matches everything BELOW that directory.
mc_path_is_generated() {
  local p="$1" g
  [ -n "$p" ] || return 1
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    case "$g" in
      */) case "$p" in $g*) return 0 ;; esac ;;
      *)  case "$p" in $g)  return 0 ;; esac ;;
    esac
  done < <(mc_generated_globs)
  return 1
}

# mc_ticket_of_path <path> — the ticket key a generated path belongs to, or rc 1.
#   docs/build-log/waves/TK-1605.md  -> TK-1605
#   .harness/specs/TK-1561/plan.md   -> TK-1561
#   The FIRST key-shaped segment wins; a path with none is never auto-resolved,
#   which is what keeps a hand-written file under one of these prefixes safe.
mc_ticket_of_path() {
  local p="$1" seg segs
  IFS=/ read -ra segs <<<"$p"
  for seg in "${segs[@]}"; do
    seg="${seg%.md}"
    if [[ "$seg" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]]; then printf '%s' "$seg"; return 0; fi
  done
  return 1
}

# mc_ticket_of_branch <branch> — this PR's ticket key, or rc 1.
#   bin/run-build.sh names every build branch `ticket/<key lowercased>`, with an
#   optional `-r<n>` retry suffix or a BRANCH_SUFFIX after it, so the key is the
#   head of the last path segment:
#     ticket/TK-1608     -> TK-1608
#     ticket/TK-1481-r3  -> TK-1481
#   A branch that is not a build branch (design/…, mergify/…) yields nothing, and
#   nothing is what turns the whole mechanism off for that PR.
mc_ticket_of_branch() {
  local b="${1:-}" t
  [ -n "$b" ] || return 1
  t=$(tr '[:lower:]' '[:upper:]' <<<"${b##*/}")
  if [[ "$t" =~ ^([A-Z][A-Z0-9]*-[0-9]+) ]]; then printf '%s' "${BASH_REMATCH[1]}"; return 0; fi
  return 1
}

# --- APPEND-UNION PATHS (BH-4641) ---------------------------------------------
# Files where two branches almost always conflict by each APPENDING a block at
# the same place (a table at the end of schema.sql, an import and a spread in
# index.js, an object at the end of a JSON array). mc_resolve_append_union keeps
# both blocks, main's first, when every hunk is a pure insertion and the result
# validates; anything else stays a real conflict. The list is the settings row
# lane.merge-conductor.mc_union_files (catalog/lanes.d/merge-conductor.json);
# this is the compiled fallback for a pool image or a tree with no registry.
MC_UNION_FILES_DEFAULT='worker/jobs/schema.sql worker/jobs/src/index.js catalog/llm-sites.json catalog/context-budgets.json worker/jobs/test/route-table.d/*'

# mc_union_globs — the allowlist, one glob per line. Commas or whitespace
#   separate entries; the single value `off` prints nothing (step disabled).
mc_union_globs() {
  local v=""
  command -v lane_knob >/dev/null 2>&1 && v=$(lane_knob merge-conductor MC_UNION_FILES 2>/dev/null)
  [ -n "$v" ] || v="${MC_UNION_FILES-$MC_UNION_FILES_DEFAULT}"
  case "$(tr '[:upper:]' '[:lower:]' <<<"$v" | tr -d '[:space:]')" in off) return 0 ;; esac
  # tr, never an unquoted expansion: `route-table.d/*` must not glob against cwd.
  tr ', \t' '\n\n\n' <<<"$v" | grep -v '^$'
}

# mc_path_is_union <path> — rc 0 when an allowlist glob matches the path.
mc_path_is_union() {
  local p="${1:-}" g
  [ -n "$p" ] || return 1
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    case "$p" in $g) return 0 ;; esac
  done < <(mc_union_globs)
  return 1
}

# --- REGENERATED PATHS (BH-1162) ----------------------------------------------
# A committed file a generator renders from the rest of the tree
# (rules/CLAUDE.md <- bin/render-rules.sh --write). Two PRs that each change a
# source conflict on it, and neither side is right: the right answer is a render
# over the MERGED tree. config/regenerated-paths.conf says which paths and why.
# docs/notes/INDEX.md, the first row, left git and this table (BH-8254).
MC_REGENERATED_PATHS_CONF="${MC_REGENERATED_PATHS_CONF:-$MC_H/config/regenerated-paths.conf}"
# The pool-image fallback, as for MC_GENERATED_PATHS_DEFAULT. Keep in step with
# config/regenerated-paths.conf.
MC_REGENERATED_PATHS_DEFAULT=$'rules/CLAUDE.md\tbin/render-rules.sh --write\ndocs/PR-OWNERSHIP.md\tbin/render-doc-sections.sh --write\n.github/workflows/harness-ci.yml\tbin/render-ci-workflow.sh --write'

# mc_regen_paths — the table, `<path><TAB><command>` a line, comments stripped.
mc_regen_paths() {
  # A directory is not a conf (BH-2210): it reads as an empty table, not absent.
  if [ -f "$MC_REGENERATED_PATHS_CONF" ] && [ -r "$MC_REGENERATED_PATHS_CONF" ]; then
    sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$MC_REGENERATED_PATHS_CONF" \
      | grep -v '^$'
  else
    printf '%s\n' "$MC_REGENERATED_PATHS_DEFAULT"
  fi
}

# mc_regen_cmd_for_path <path> — prints the command that renders <path>, or rc 1.
#   Exact match on the first field; never a glob.
mc_regen_cmd_for_path() {
  local p="${1:-}" path cmd
  [ -n "$p" ] || return 1
  while IFS=$'\t' read -r path cmd; do
    if [ "$path" == "$p" ] && [ -n "$cmd" ]; then printf '%s' "$cmd"; return 0; fi
  done < <(mc_regen_paths)
  return 1
}

# mc_regen_restore <worktree> <path> — put the conflict (stages and markers)
#   back the way git left it, so the ladder sees the real thing.
mc_regen_restore() { git -C "$1" checkout -m -- "$2" >/dev/null 2>&1 || true; }

# mc_resolve_by_regen <worktree> <path> <command>
#   rc 0 = regenerated, marker-free and staged | 1 = left a real conflict.
#   Nothing on stdout: mc_resolve_conflicts runs inside $(...) and its stdout is
#   the conflict list the caller reads.
mc_resolve_by_regen() {
  local wt="$1" f="$2" cmd="$3" d out rc
  d=$(dirname "$f")
  # The generator reads the files beside <path>. One of them still carrying
  # markers would be rendered into the index as if it were a note.
  if git -C "$wt" ls-files -u -- "$d" | awk -F'\t' -v f="$f" '$2 != f { found = 1 } END { exit !found }'; then
    mc_log "regenerated path $f left as a REAL conflict: another path under $d/ is still unmerged"
    return 1
  fi
  # Take a side only to clear the markers so the generator can overwrite the
  # file. A modify/delete has no stage 3 and fails here with its stages intact.
  git -C "$wt" checkout --theirs -- "$f" >/dev/null 2>&1 || {
    mc_log "regenerated path $f left as a REAL conflict: no side to render over (modify/delete?)"
    return 1
  }
  if [ ! -x "$wt/${cmd%% *}" ]; then
    mc_regen_restore "$wt" "$f"
    mc_log "regenerated path $f left as a REAL conflict: ${cmd%% *} is not in the merged tree"
    return 1
  fi
  out=$(mktemp "${TMPDIR:-/tmp}/mc-regen.XXXXXX") || { mc_regen_restore "$wt" "$f"; return 1; }
  # 9>&- so a stray child cannot hold the conductor's flock; </dev/null so it
  # cannot read the caller's input. Same shape as mc_regen_generated.
  ( cd "$wt" && eval "$cmd" ) >"$out" 2>&1 9>&- </dev/null
  rc=$?
  if [ "$rc" != 0 ]; then
    mc_log "regenerated path $f left as a REAL conflict: $cmd exited $rc: $(tail -n 5 "$out" | tr '\n' ' ')"
    rm -f "$out"
    mc_regen_restore "$wt" "$f"
    return 1
  fi
  rm -f "$out"
  if grep -Eq '^(<<<<<<<|=======|>>>>>>>)( |$)' "$wt/$f" 2>/dev/null || [ ! -f "$wt/$f" ]; then
    mc_log "regenerated path $f left as a REAL conflict: $cmd wrote no file, or one with conflict markers"
    mc_regen_restore "$wt" "$f"
    return 1
  fi
  git -C "$wt" add -- "$f" >/dev/null 2>&1 || { mc_regen_restore "$wt" "$f"; return 1; }
  mc_log "regenerated path $f resolved by re-running $cmd over the merged tree"
  return 0
}

# mc_rebase_regen_continue <worktree> <log-tag>
#   A `git rebase` stopped on a conflict. When EVERY conflicted path is a
#   regenerated path (config/regenerated-paths.conf), re-render them over the
#   tree (mc_resolve_conflicts, which tries regenerated paths last and leaves a
#   real conflict in place) and `rebase --continue`, as many times as the
#   replay stops. rc 0 = the rebase finished. rc 1 = a conflict that is not
#   only regenerated paths, a render that failed, or a continue that stopped
#   with nothing unmerged: the rebase is left stopped for the caller to read
#   its conflict list and abort, exactly as before (BH-6000).
#   The step bound is the number of commits a rebase can stop on, so it can
#   never loop: each pass either finishes or moves to the next commit.
mc_rebase_regen_continue() {
  local wt="$1" tag="${2:-rebase}" conf f steps=0 max
  max=$(git -C "$wt" rev-list --count HEAD 2>/dev/null) || max=0
  max=$((max + 1000))
  while :; do
    conf=$(git -C "$wt" diff --name-only --diff-filter=U)
    [ -n "$conf" ] || return 1
    for f in $conf; do mc_regen_cmd_for_path "$f" >/dev/null || return 1; done
    steps=$((steps + 1)); [ "$steps" -le "$max" ] || return 1
    mc_resolve_conflicts "$wt" "" >/dev/null || return 1
    mc_log "$tag: regenerated $(printf '%s ' $conf | sed 's/ $//') on a replayed commit and continued the rebase"
    GIT_EDITOR=true git -C "$wt" -c user.name="${MC_GIT_NAME:-$HARNESS_MERGE_GIT_NAME}" -c user.email="${MC_GIT_EMAIL:-$HARNESS_GIT_EMAIL}" \
      -c commit.gpgsign=false rebase --continue >/dev/null 2>&1 && return 0
  done
}

# mc_resolve_generated <worktree> <path> <this-PR's-ticket-key>
#   Resolve ONE conflicted path in the index of an in-progress merge.
#   rc 0 = resolved and staged | 1 = not ours to resolve (a real conflict).
#   Three classes:
#     a REGENERATED path (config/regenerated-paths.conf) -> re-render it over
#       the merged tree; no ticket key needed for the PR or the path (BH-1162)
#     this PR's own per-ticket generated file            -> OURS
#     another ticket's per-ticket generated file         -> THEIRS
#   rc 1 is the safe answer everywhere: no ticket key for the PR, a path off the
#   allowlist, a path with no ticket key in it, or a checkout that cannot produce
#   the side we want (a modify/delete conflict has no stage to take).
mc_resolve_generated() {
  local wt="$1" f="$2" mine="${3:-}" side tk ours theirs cmd
  if cmd=$(mc_regen_cmd_for_path "$f"); then mc_resolve_by_regen "$wt" "$f" "$cmd"; return $?; fi
  [ -n "$mine" ] || return 1
  mc_path_is_generated "$f" || return 1
  tk=$(mc_ticket_of_path "$f") || return 1
  if [ "$tk" = "$mine" ]; then
    side=--ours
  else
    # THE PARENT-WAVE CASE, and the reason this is not a bare `checkout --theirs`.
    # Not every one of these files is strictly one ticket's: project-5's
    # docs/build-log/waves/TK-1251.md is a PARENT wave's narrative that each of
    # its five children appends its own section to. Taking main's copy of a file
    # the branch has written its OWN ticket into would silently delete this
    # build's output — the one outcome worse than a conflict.
    # So THEIRS is taken only when the branch's side carries nothing about this
    # PR's ticket that main's side does not. Otherwise it is a real conflict and
    # the fix round gets it, markers and all.
    # Both stages are captured first: grep -qF exits at the first match while git
    # is still writing the rest of the blob, and pipefail hands the `if` git's
    # 141 — which reads here as "the branch's copy carries nothing of $mine" and
    # takes THEIRS over the branch's own work (BH-1248).
    ours=$(git -C "$wt" show ":2:$f" 2>/dev/null)
    theirs=$(git -C "$wt" show ":3:$f" 2>/dev/null)
    if grep -qF "$mine" <<<"$ours" && ! grep -qF "$mine" <<<"$theirs"; then
      mc_log "generated per-ticket path $f left as a REAL conflict: it is ${tk}'s, but the branch's copy carries $mine's own work and main's does not"
      return 1
    fi
    side=--theirs
  fi
  git -C "$wt" checkout "$side" -- "$f" >/dev/null 2>&1 || return 1
  git -C "$wt" add -- "$f" >/dev/null 2>&1 || return 1
  mc_log "generated per-ticket path $f resolved ${side#--} (that file is ${tk}'s; this PR is ${mine}'s)"
  return 0
}

# mc_resolve_vmap_readme <worktree> <branch>
#   docs/verification-map/README.md is GENERATED (bin/verification-map-build.sh
#   builds it from index/head.md + entries/<KEY>.md + index/tail.md, BH-798). The
#   `*.md` union arm below is the wrong operation for it: gluing main's generated
#   table onto a PR's hand-edited one leaves a duplicated header and a row no
#   entry file backs, so the rung "succeeds", pushes, and CI's --check step goes
#   red — a fix round spent on a mechanical problem (BH-868, ~27 open PRs).
#   The right operation is "move the PR's appended rows into a source and rebuild",
#   which is bin/verification-map-retrofit.sh's vmr-core block, shared so the CLI
#   and this rung resolve a README identically.
#   rc 0 = resolved and staged. ANY other answer is rc 1 here, which FALLS THROUGH
#   to today's union case: a refusal must not turn a merging PR into a rung-1
#   failure, and a repo without the build script must behave exactly as it does now.
mc_vmr_load() {
  command -v vmr_resolve_readme >/dev/null 2>&1 && return 0
  local lib="$MC_H/bin/verification-map-retrofit.sh"
  [ -r "$lib" ] || lib="${BASH_SOURCE[0]%/*}/../verification-map-retrofit.sh"
  # shellcheck source=/dev/null
  [ -r "$lib" ] && . "$lib"
  command -v vmr_resolve_readme >/dev/null 2>&1
}

mc_resolve_vmap_readme() {
  local wt="$1" br="${2:-}" key base ours out rc
  mc_vmr_load || {
    mc_log "verification-map README retrofit declined (bin/verification-map-retrofit.sh not found) — union resolver takes it"; return 1; }
  key=$(mc_ticket_of_branch "$br" 2>/dev/null) || {
    mc_log "verification-map README retrofit declined (no ticket key in branch $br) — union resolver takes it"; return 1; }
  base=$(git -C "$wt" merge-base HEAD MERGE_HEAD 2>/dev/null) || base=""
  ours=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || ours=""
  [ -n "$base" ] && [ -n "$ours" ] || {
    mc_log "verification-map README retrofit declined (no merge in progress) — union resolver takes it"; return 1; }
  # `2>&1` and an explicit rc: the core's ONE stderr line is the only thing that
  # says WHICH row it refused, and `$?` read after an `if` whose condition
  # failed is 0, so the old line said "declined (rc 0)" on every single decline.
  out=$(vmr_resolve_readme "$wt" "$base" "$ours" "$key" MERGE_HEAD 2>&1); rc=$?
  if [ "$rc" = 0 ]; then
    mc_log "verification-map README retrofitted into docs/verification-map/entries/$key.md ($(grep -o 'rows_before=.*' <<<"$out" | tail -1))"
    return 0
  fi
  mc_log "verification-map README retrofit declined (rc $rc: $(tail -1 <<<"$out")) — union resolver takes it"
  return 1
}

# mc_resolve_vmap_clean_merge <worktree> <branch> <pre-merge-head> [theirs-ref]
#   THE CLEAN-MERGE HALF of BH-868, and the one that matters most today. Main's
#   .gitattributes has carried `docs/verification-map/README.md merge=union`
#   since BH-865, so the conductor's `git merge origin/main` SUCCEEDS on the
#   README: git's union driver glues main's generated table onto the PR's hand
#   table, no path is ever unmerged, mc_resolve_conflicts is never reached, and
#   the rung commits and pushes a README with a duplicated header and a row no
#   entry file backs — which is the CI red this ticket exists to stop.
#   Runs AFTER a clean merge, on the merge commit git already made.
#   rc 0 = nothing was needed, or it was repaired and COMMITTED.
#   rc 1 = declined; the tree is exactly as the merge left it, which is today's
#          behaviour, so a decline never turns a merging PR into a failed rung.
mc_resolve_vmap_clean_merge() {
  local wt="$1" br="${2:-}" pre="${3:-}" ref="${4:-origin/main}" key base out rc
  [ -n "$pre" ] || return 0
  # TRACKED, not merely PRESENT (BH-1175). The non-hub path reuses one scratch
  # clone across ticks, and mc_regen_generated writes the now-ignored README
  # into it after every merge — so `-f` stayed true for ever, `--check-committed`
  # compared a stale artifact to fresh sources, and this function logged a
  # decline on every clean rebase of a repo it has no business in. It is the
  # INDEX that says whether a repo commits its index.
  [ -n "$(git -C "$wt" ls-files -- docs/verification-map/README.md 2>/dev/null)" ] || return 0
  [ -x "$wt/bin/verification-map-build.sh" ] || return 0
  # Only a README that does NOT rebuild to itself is this function's business;
  # every other clean merge is left completely alone. --check-committed, not
  # --check: the question is about BYTES, and since BH-1175 plain --check grades
  # the SOURCES and would answer 0 for a glued README — which would silently
  # retire this repair on every repo that still commits its index.
  "$wt/bin/verification-map-build.sh" --check-committed --repo "$wt" >/dev/null 2>&1 && return 0
  mc_vmr_load || { mc_log "verification-map README clean-merge repair declined (retrofit script not found)"; return 1; }
  key=$(mc_ticket_of_branch "$br" 2>/dev/null) || {
    mc_log "verification-map README clean-merge repair declined (no ticket key in branch $br)"; return 1; }
  base=$(git -C "$wt" merge-base "$pre" "$ref" 2>/dev/null) || base=""
  [ -n "$base" ] || { mc_log "verification-map README clean-merge repair declined (no merge base with $ref)"; return 1; }
  out=$(vmr_resolve_readme "$wt" "$base" "$pre" "$key" "$ref" 2>&1); rc=$?
  if [ "$rc" != 0 ]; then
    mc_log "verification-map README clean-merge repair declined (rc $rc: $(tail -1 <<<"$out")) — the merge stands as git made it"
    return 1
  fi
  git -C "$wt" -c user.email="$HARNESS_BOT_GIT_EMAIL" -c user.name="$HARNESS_BOT_GIT_NAME" -c commit.gpgsign=false \
      commit -q -m "verification-map: move $key's hand-added README row into docs/verification-map/entries/$key.md and regenerate (BH-868)" >/dev/null 2>&1 || {
    mc_log "verification-map README clean-merge repair could not commit — the merge stands as git made it"; return 1; }
  mc_log "verification-map README repaired after a CLEAN union merge into docs/verification-map/entries/$key.md ($(grep -o 'rows_before=.*' <<<"$out" | tail -1))"
  return 0
}

# mc_schema_drop_safe <worktree> <path>
#   rc 0 = taking the deletion of <path> loses no schema statement: the path is
#   not worker/<w>/schema.sql, worker/<w> has no schema.d/, or every statement
#   the branch's copy (stage 2) added over the base (stage 1) is in the
#   composition of the merged tree's fragments. rc 1 = a statement would be
#   lost, or the check could not run; one mc_log line says which. Nothing goes
#   to stdout: the caller runs inside $(...), where stdout is the conflict list.
#
#   WHY (BH-6005). Once the untrack child makes worker/jobs/schema.sql ignored,
#   a branch cut before the BH-4987 split, which appended its CREATE TABLE to
#   schema.sql only, merges main as a modify/delete on an ignored path — and
#   mc_resolve_deleted_ignored would take the deletion and the table with it,
#   with no conflict and no log line. The ignore rule says the FILE may not be
#   committed; it says nothing about the statements in it. So a statement in no
#   fragment is a REAL conflict, and a check that cannot run is one too.
#   Statements compare byte for byte as bin/lib/d1-schema.sh splits them: a
#   false "lost" costs one fix round, a false "kept" loses a table.
mc_schema_drop_safe() {
  local wt="$1" f="$2" w tmp rc
  case "$f" in worker/*/schema.sql) ;; *) return 0 ;; esac
  w=${f#worker/}; w=${w%/schema.sql}
  case "$w" in */*) return 0 ;; esac
  [ -d "$wt/worker/$w/schema.d" ] || return 0
  if [ ! -x "$wt/bin/schema-build.sh" ] || [ ! -r "$wt/bin/lib/d1-schema.sh" ]; then
    mc_log "$f: cannot check the branch's schema statements — the merged tree has no bin/schema-build.sh (BH-6005)"
    return 1
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/mc-schema-XXXXXX") \
    || { mc_log "$f: cannot make a temp dir to check the branch's schema statements — a REAL conflict (BH-6005)"; return 1; }
  (
    "$wt/bin/schema-build.sh" --root "$wt" --worker "$w" --to "$tmp/composed.sql" > "$tmp/build.err" 2>&1
    brc=$?
    if [ "$brc" != 0 ]; then
      mc_log "$f: the merged tree's schema.d could not be composed (rc $brc: $(head -n 1 "$tmp/build.err")) — a REAL conflict (BH-6005)"
      exit 1
    fi
    git -C "$wt" show ":2:$f" > "$tmp/ours.sql" 2>/dev/null \
      || { mc_log "$f: cannot read the branch's copy (stage 2) — a REAL conflict (BH-6005)"; exit 1; }
    # No stage 1 (both sides added the file): the base holds no statement.
    git -C "$wt" show ":1:$f" > "$tmp/base.sql" 2>/dev/null || : > "$tmp/base.sql"
    # shellcheck source=bin/lib/d1-schema.sh
    . "$wt/bin/lib/d1-schema.sh" || { mc_log "$f: cannot load bin/lib/d1-schema.sh — a REAL conflict (BH-6005)"; exit 1; }
    declare -A known=()
    for src in base composed; do
      mapfile -t -d '' st < <(d1_schema_statements "$tmp/$src.sql")
      for s in "${st[@]}"; do known["$s"]=1; done
    done
    n=0; first=""
    mapfile -t -d '' st < <(d1_schema_statements "$tmp/ours.sql")
    for s in "${st[@]}"; do
      [ -z "${known["$s"]+x}" ] || continue
      known["$s"]=1; n=$((n + 1)); [ -n "$first" ] || first=${s%%$'\n'*}
    done
    [ "$n" = 0 ] && exit 0
    mc_log "$f: the branch's schema.sql carries $n statement(s) in no fragment of the merged tree (first: $first) — a REAL conflict, not a deletion to take (BH-6005)"
    exit 1
  )
  rc=$?
  [ -n "$tmp" ] && rm -rf -- "$tmp"
  return "$rc"
}

# mc_resolve_conflicts <worktree> <branch>
#   THE MECHANICAL RUNG'S WHOLE CONFLICT POLICY, in one place so the fixtures can
#   drive it against a real git merge rather than against mc_rebase's network.
#   Called with a merge already in progress and conflicts in the index.
#   rc 0 = every conflicted path is resolved and staged, stdout empty.
#   rc 1 = at least one path is a real conflict; stdout is the FULL conflict list
#          (the caller aborts the merge and hands that list to the fix round).
#   Generated per-ticket paths are tried FIRST, because they are `*.md` too and
#   the union resolver below would happily glue two unrelated tickets' documents
#   into one file and call it merged.
#   Regenerated paths (config/regenerated-paths.conf, BH-1162) are held back
#   and tried LAST, once every other path is staged, so the generator renders a
#   tree with no markers in it. One that cannot be regenerated is a real
#   conflict: it never falls to the union arm, which is the thing it replaces.
# mc_resolve_deleted_ignored <worktree> <path>
#   rc 0 = this unmerged path was DELETED by one side and is GIT-IGNORED in the
#   merged tree, so the deletion is the answer: it is dropped from the index and
#   from the worktree and the caller moves on. rc 1 = any other shape, and the
#   caller's normal policy runs unchanged.
#
#   WHY (BH-1175). docs/verification-map/README.md is generated and left git on
#   that ticket. 48 of the 63 PRs open at that moment carried a commit that
#   regenerated it, so merging main into any of them is a modify/delete — and
#   git resolves a modify/delete by leaving OUR file in the worktree with NO
#   conflict markers. mc_resolve_md_union then finds zero marker blocks and
#   fails, so the path came back as a REAL conflict and each of those 48 PRs
#   would have bought one blocked-resolver fix round on a file the repo has
#   decided nothing may commit. Worse, a fix round that "resolves" it the way
#   every prompt teaches — regenerate and `git add -f` — pushes a tracked README
#   and CI's own --check then refuses the head.
#
#   THE IGNORE RULE IS THE WHOLE AUTHORITY. This never guesses: it acts only
#   where the merged tree's own .gitignore says the path must not be in git, so
#   "take the deletion" is the only resolution that agrees with the repo. A
#   modify/delete on a TRACKED path is left exactly as it was — a real conflict
#   a human or a fix round owns.
mc_resolve_deleted_ignored() {
  local wt="$1" f="$2" stages
  stages=$(git -C "$wt" ls-files -u -- "$f" 2>/dev/null | awk '{print $3}' | sort -u | tr '\n' ' ')
  [ -n "${stages// /}" ] || return 1
  # ORIENTATION IS THE WHOLE SAFETY PROPERTY. Stage 2 is OURS (the ticket
  # branch), stage 3 is THEIRS (the base being merged in). Only a BASE-side
  # deletion may be taken — stage 3 absent.
  #
  # The mirror image is data loss. If the BRANCH deleted a tracked-but-ignored
  # file and the BASE modified it, stages 1 and 3 are present and stage 2 is
  # not; "take the deletion" would throw the base's edit away silently, with no
  # conflict for anyone to look at. The first cut of this function tested only
  # "not both sides" and did exactly that (probed on a `*.log` path). A branch
  # deleting a file the base still edits is a decision a human makes.
  case " $stages " in *" 3 "*) return 1 ;; esac
  case " $stages " in *" 2 "*) ;; *) return 1 ;; esac
  git -C "$wt" check-ignore -q --no-index -- "$f" 2>/dev/null || return 1
  mc_schema_drop_safe "$wt" "$f" || return 1
  git -C "$wt" rm -q --cached -- "$f" >/dev/null 2>&1 || return 1
  rm -f "$wt/$f"
  mc_log "$f: deleted on the other side and git-ignored in the merged tree — taking the deletion rather than merging a file nothing may commit (BH-1175)"
  return 0
}

mc_resolve_conflicts() {
  local wt="$1" br="${2:-}" conf f cmd mine="" regen="" unioned=""
  conf=$(git -C "$wt" diff --name-only --diff-filter=U)
  [ -n "$conf" ] || return 0
  mine=$(mc_ticket_of_branch "$br" 2>/dev/null) || mine=""
  for f in $conf; do
    # FIRST, because a generated path that main DELETED is not a side to pick.
    mc_resolve_deleted_ignored "$wt" "$f" && continue
    if cmd=$(mc_regen_cmd_for_path "$f"); then
      # BH-6000: a registered render whose generator is not in the merged tree
      # (another repo's worker/jobs/schema.sql, a branch cut before the
      # generator existed) is not this rule's to settle. An append-union path
      # then takes the append-union step it took before; any other path stays
      # a regenerated path, and so a REAL conflict (BH-1162: never a union).
      if [ -x "$wt/${cmd%% *}" ] || ! mc_path_is_union "$f"; then regen="$regen $f"; continue; fi
      mc_log "$f: its generator ${cmd%% *} is not in the merged tree — the append-union step takes it, as before (BH-6000)"
      mc_resolve_append_union "$wt" "$f" || { printf '%s\n' "$conf"; return 1; }
      unioned=1; continue
    fi
    mc_resolve_generated "$wt" "$f" "$mine" && continue
    case "$f" in
      docs/verification-map/README.md)
        # No `git add -A`: the core stages the README and the entry file itself,
        # and a blanket add would sweep in whatever untracked file the REUSED
        # scratch clone is carrying — another ticket's entry row included.
        if mc_resolve_vmap_readme "$wt" "$br"; then continue; fi ;;
    esac
    # BH-4641: an allowlisted file the append-union step declines is a REAL
    # conflict; it never falls through to the *.md union below.
    if mc_path_is_union "$f"; then
      mc_resolve_append_union "$wt" "$f" || { printf '%s\n' "$conf"; return 1; }
      unioned=1; continue
    fi
    # BH-6374: an add/add whose real base is a squash-merged stack parent.
    [ "${MC_SQUASH_BASE_MERGE:-1}" != 0 ] && mc_resolve_squash_base "$wt" "$f" && continue
    case "$f" in
      package.json) ( cd "$wt" && mc_resolve_package_json ) >/dev/null 2>&1 || { printf '%s\n' "$conf"; return 1; } ;;
      *.md)         ( cd "$wt" && mc_resolve_md_union "$f" ) >/dev/null 2>&1 || { printf '%s\n' "$conf"; return 1; } ;;
      *) printf '%s\n' "$conf"; return 1 ;;
    esac
    git -C "$wt" add "$f"
  done
  for f in $regen; do
    mc_resolve_generated "$wt" "$f" "$mine" || { printf '%s\n' "$conf"; return 1; }
  done
  [ -z "$unioned" ] || mc_union_renumber_fragments "$wt" || { printf '%s\n' "$conf"; return 1; }
  return 0
}

# The two deterministic resolvers, from bin/rebase-train.sh (merge-marker form).
mc_resolve_package_json() {
python3 - <<'PYEOF'
import json, re, sys
s = open('package.json').read()
m = re.search(r'<<<<<<< [^\n]*\n(.*?)\n=======\n(.*?)\n>>>>>>> [^\n]+\n', s, re.S)
if not m or m.group(1).count('\n') > 0: sys.exit(1)
ours, theirs = m.group(1), m.group(2)
km = re.search(r'"(test:[a-z-]+)":\s*"(.*)",?\s*$', ours)
if not km: sys.exit(1)
key = km.group(1)
def val(line):
    mm = re.search(r'"' + re.escape(key) + r'":\s*"(.*)",?\s*$', line)
    return mm.group(1) if mm else None
o, t = val(ours), val(theirs)
if o is None or t is None: sys.exit(1)
missing = [tok for tok in t.split(' ') if tok not in o.split(' ') and tok not in ('&&','node','npx','tsx','--test')]
parts = o.split(' && ')
for tok in missing:
    if tok.endswith('.test.tsx') or '.render.' in tok: parts[-1] += ' ' + tok
    else: parts[0] += ' ' + tok
s = s[:m.start()] + ours.replace(o, ' && '.join(parts)) + '\n' + s[m.end():]
open('package.json', 'w').write(s)
json.load(open('package.json'))
PYEOF
}
mc_resolve_md_union() {
python3 - "$1" <<'PYEOF'
import re, sys
p = sys.argv[1]; s = open(p).read()
new, n = re.subn(r'<<<<<<< [^\n]*\n(.*?)\n=======\n(.*?)\n>>>>>>> [^\n]*\n', lambda m: m.group(1) + "\n\n" + m.group(2) + "\n", s, flags=re.S)
if n == 0 or '<<<<<<<' in new: sys.exit(1)
open(p, 'w').write(new)
PYEOF
}

# mc_union_trailer <worktree> <line> — append one `Union-resolved:` line to the
#   in-progress merge's MERGE_MSG. `git commit --no-edit` keeps it, so the merge
#   commit records what was resolved mechanically, and mc_rebase /
#   rebase_job_run read it back from there (a global could not cross the
#   $(...) subshell mc_resolve_conflicts runs in).
mc_union_trailer() {
  local wt="$1" line="$2" m
  m=$(git -C "$wt" rev-parse --git-path MERGE_MSG 2>/dev/null) || return 1
  case "$m" in /*) ;; *) m="$wt/$m" ;; esac
  [ -f "$m" ] || return 1
  # The first trailer gets a blank line above it; later ones join its paragraph.
  if ! grep -q '^Union-resolved: ' "$m" && [ -n "$(tail -n 1 "$m")" ]; then printf '\n' >> "$m" || return 1; fi
  printf '%s\n' "$line" >> "$m"
}

# mc_resolve_squash_base <worktree> <path>   (BH-6374)
#   rc 0 = an add/add path merged with the squash commit as its base, staged,
#          trailer written | rc 1 = not this shape, or declined: the path is
#          exactly as git left it and the caller's next arm runs.
#   Nothing on stdout (mc_resolve_conflicts' stdout is the conflict list).
#
#   THE SHAPE. A child built STACKED on a parent PR's branch carries the files
#   the parent created. The parent then merges as a SQUASH, so main gets the
#   same files in a commit the child does not have. Merging main into the child
#   finds no common base for them (the merge base predates both) and git calls
#   each one add/add (stages 2 and 3, no stage 1), although main's real change
#   is only what landed after the squash (project-6-os #209/#210/#211).
#
#   THE BASE IT USES, AND ITS PROOF. A = the OLDEST commit on MERGE_HEAD since
#   the merge base that added the path: after a squash merge, the squash
#   commit. A is used only when A's blob equals the path's blob at some commit
#   on the branch since the merge base, i.e. the branch already carries that
#   exact state (the stacked parent's tip). Without that proof, A is just
#   another side's add, and the path stays a real conflict.
#
#   ORIENTATION: mc_rebase merges main INTO the branch, so stage 2 is the
#   branch and stage 3 is main: `git merge-file -p <stage2> <A:path> <stage3>`.
#   Only a clean merge-file (rc 0) is taken. The `Union-resolved:` trailer makes
#   mc_rebase re-review the merged head rather than rebind the approval.
mc_resolve_squash_base() {
  local wt="$1" f="$2" stages mb a ab c proof="" d rc
  stages=$(git -C "$wt" ls-files -u -- "$f" 2>/dev/null | awk '{print $3}' | sort -u | tr '\n' ' ')
  [ "$stages" = "2 3 " ] || return 1
  mb=$(git -C "$wt" merge-base HEAD MERGE_HEAD 2>/dev/null) || {
    mc_log "$f: add/add, but no merge in progress or no merge base — squash-base merge declined (BH-6374)"; return 1; }
  a=$(git -C "$wt" log --no-renames --diff-filter=A --format=%H MERGE_HEAD "^$mb" -- "$f" 2>/dev/null | tail -n 1)
  [ -n "$a" ] || { mc_log "$f: add/add, no commit on the merged side added it — squash-base merge declined (no add, BH-6374)"; return 1; }
  ab=$(git -C "$wt" rev-parse -q --verify "$a:$f" 2>/dev/null) || ab=""
  if [ -n "$ab" ]; then
    for c in $(git -C "$wt" rev-list "$mb..HEAD" -- "$f" 2>/dev/null); do
      [ "$(git -C "$wt" rev-parse -q --verify "$c:$f" 2>/dev/null)" = "$ab" ] && { proof="$c"; break; }
    done
  fi
  [ -n "$proof" ] || {
    mc_log "$f: add/add, ${a:0:8} added it but no branch commit since the merge base has that content — squash-base merge declined (no proof, BH-6374)"; return 1; }
  d=$(mktemp -d "${TMPDIR:-/tmp}/mc-squash-XXXXXX" 2>/dev/null) || { mc_log "$f: could not make a scratch dir — squash-base merge declined (BH-6374)"; return 1; }
  if ! git -C "$wt" show ":2:$f" > "$d/ours" 2>/dev/null || ! git -C "$wt" show "$a:$f" > "$d/base" 2>/dev/null \
     || ! git -C "$wt" show ":3:$f" > "$d/theirs" 2>/dev/null; then
    rm -rf "$d"; mc_log "$f: could not read a stage — squash-base merge declined (BH-6374)"; return 1
  fi
  git merge-file -p "$d/ours" "$d/base" "$d/theirs" > "$d/out" 2>/dev/null; rc=$?
  if [ "$rc" != 0 ]; then
    rm -rf "$d"
    mc_log "$f: add/add with squash base ${a:0:8}, but the branch and main change the same lines — left a real conflict (merge-file conflict, rc $rc, BH-6374)"
    return 1
  fi
  if ! cat "$d/out" > "$wt/$f" \
     || ! mc_union_trailer "$wt" "Union-resolved: $f (squash base ${a:0:8}, BH-6374)" \
     || ! git -C "$wt" add -- "$f" >/dev/null 2>&1; then
    rm -rf "$d"; mc_regen_restore "$wt" "$f"
    mc_log "$f: squash-base merge could not write, record or stage the result — left a real conflict (BH-6374)"
    return 1
  fi
  rm -rf "$d"
  mc_log "$f: add/add merged with the squash commit ${a:0:8} as the base (proof: ${proof:0:8} on the branch has the same blob) — staged (BH-6374)"
  return 0
}

# mc_resolve_append_union <worktree> <path>   (BH-4641)
#   rc 0 = both sides' blocks kept, main's first, validated, staged, trailer
#          written | rc 1 = a REAL conflict, the file put back the way git left it.
#   Nothing on stdout (mc_resolve_conflicts' stdout is the conflict list); every
#   decline is one log line naming why.
#
#   ORIENTATION: mc_rebase merges origin/main INTO the ticket branch, so stage 2
#   (ours) is the BRANCH and stage 3 (theirs) is MAIN. "Main's block first" is
#   stage 3's insertion, then stage 2's — the opposite of mc_resolve_md_union.
#
#   It resolves only when the merge base's lines are a subsequence of BOTH
#   sides' files: nothing of the base removed or changed anywhere in the file,
#   not just where git conflicted. Each side's insertions are then placed
#   between the base lines they sit between, and where both sides inserted at
#   the same place (a "hunk" in the log line) main's block goes first, then the
#   branch's. In a .json file one trailing comma is ignored when comparing
#   lines, because appending to an array or object rewrites the old last
#   element `{…}` -> `{…},` on both sides; a comma is added between main's block
#   and the branch's. Then the file must pass its validator (python sqlite3 for .sql,
#   jq plus a duplicate-key parse for .json, node --check for .js; .txt has
#   none) — a missing validator is a decline, never a skip.
mc_resolve_append_union() {
  local wt="$1" f="$2" kind="" d="" why="" n="" s tool verr
  case "$f" in
    *.json) kind=json ;;
    *.sql) kind=sql ;;
    *.js|*.mjs|*.cjs) kind=js ;;
    *.txt) kind=text ;;
    *) why="no validator for this file type" ;;
  esac
  if [ -z "$why" ]; then
    for tool in python3 $(case "$kind" in json) echo jq ;; js) echo node ;; esac); do
      command -v "$tool" >/dev/null 2>&1 || { why="validator unavailable: $tool"; break; }
    done
  fi
  if [ -z "$why" ] && [ "$kind" = sql ] && ! python3 -c 'import sqlite3' >/dev/null 2>&1; then
    why="validator unavailable: python3 sqlite3"
  fi
  if [ -z "$why" ]; then
    d=$(mktemp -d "${TMPDIR:-/tmp}/mc-union-XXXXXX" 2>/dev/null) || { d=""; why="could not make a scratch dir"; }
  fi
  if [ -z "$why" ]; then
    for s in 1 2 3; do
      git -C "$wt" show ":$s:$f" > "$d/$s" 2>/dev/null && continue
      if [ "$s" = 1 ]; then why="no merge base for this path"; else why="deleted on one side"; fi
      break
    done
  fi
  if [ -z "$why" ]; then
    # argv: kind base ours(branch) theirs(main) out. Prints the hunk count;
    # a decline exits 1 with its reason on stderr.
    if ! n=$(python3 - "$kind" "$d/1" "$d/2" "$d/3" "$wt/$f" 2>"$d/why" <<'PYEOF'
import sys
kind, bp, op, tp, out = sys.argv[1:6]

def fail(why):
    sys.stderr.write(why + "\n")
    sys.exit(1)

def split(s):
    # Lines with their "\n" kept. Never str.splitlines: it also splits on \x0c,
    # \x1c,   and friends, which git does not.
    ls = [x + "\n" for x in s.split("\n")]
    ls[-1] = ls[-1][:-1]
    return ls if ls[-1] else ls[:-1]

def read(p):
    with open(p, encoding="utf-8", errors="surrogateescape", newline="") as fh:
        return split(fh.read())

def norm(l):
    if kind != "json":
        return l
    s = l.rstrip()
    return s[:-1] if s.endswith(",") else s

def mark(l):
    return l.rstrip("\r\n")

def subseq(small, big):
    it = iter(big)
    return all(any(x == y for y in it) for x in small)

def ns(ls):
    return [norm(x) for x in ls]

base, ours, theirs = read(bp), read(op), read(tp)
nb, no, nt = ns(base), ns(ours), ns(theirs)

def align(nx):
    # Each base line's position in the side, earliest first; None when the
    # base is not a subsequence of the side, i.e. a base line was removed or
    # changed. Checked over the WHOLE file, not only where git conflicted.
    pos, j = [], 0
    for x in nb:
        while j < len(nx) and nx[j] != x:
            j += 1
        if j == len(nx):
            return None
        pos.append(j)
        j += 1
    return pos

po, pt = align(no), align(nt)
if po is None:
    fail("not pure insertion: the branch changed or removed a base line")
if pt is None:
    fail("not pure insertion: main changed or removed a base line")

def gaps(side, pos):
    # gaps[i] = the lines the side inserted just before base line i (the last
    # one is after the final base line).
    edges = [-1] + pos + [len(side)]
    return [side[edges[i] + 1:edges[i + 1]] for i in range(len(edges) - 1)]

go, gt = gaps(ours, po), gaps(theirs, pt)

def join(t_ins, o_ins):
    # Main's block, then the branch's. In JSON the two must be comma-separated.
    if kind == "json" and t_ins and o_ins:
        last = t_ins[-1]
        s = last.rstrip()
        if not s.endswith((",", "[", "{")):
            t_ins = t_ins[:-1] + [s + "," + last[len(s):]]
    return t_ins + o_ins

def base_line(i):
    # Identical on both sides outside JSON. In JSON a side may have added the
    # trailing comma an append needs; keep the side that changed it (main's
    # when both did).
    b, t, o = base[i], theirs[pt[i]], ours[po[i]]
    if kind != "json":
        return b
    return t if t != b else o

# Why not git merge-file's diff3 hunks: both sides of a multi-line JSON append
# add the same `},` and `{` scaffolding, diff3 factors those out as common, and
# the hunk left is `"id": "main"` against `"id": "tick"` INSIDE one object.
# Aligning on the base and unioning whole insertions keeps each block intact.
res, hunks = [], 0
for i in range(len(base) + 1):
    if gt[i] and go[i]:
        hunks += 1
        res.extend(join(gt[i], go[i]))
    else:
        res.extend(gt[i] or go[i])
    if i < len(base):
        res.append(base_line(i))

if not hunks:
    fail("no place where both sides inserted, so not an append-append conflict")
if any(not l.endswith("\n") for l in res[:-1]):
    fail("a block has no newline at its end")
if any(l.startswith(("<<<<<<<", ">>>>>>>", "|||||||")) or mark(l) == "=======" for l in res):
    fail("a conflict marker is left in the composed file")
if not subseq(ns(ours), ns(res)) or not subseq(ns(theirs), ns(res)):
    fail("the composed file dropped a line one side added")
with open(out, "w", encoding="utf-8", errors="surrogateescape", newline="") as fh:
    fh.write("".join(res))
print(hunks)
PYEOF
    ); then
      why=$(head -n 1 "$d/why" 2>/dev/null); why="${why:-the composer failed}"
    fi
  fi
  if [ -z "$why" ]; then
    case "$kind" in
      sql)
        verr=$(timeout 60 python3 -c 'import sqlite3, sys; sqlite3.connect(":memory:").executescript(open(sys.argv[1]).read())' \
               "$wt/$f" 2>&1 9>&- </dev/null) || why="validator failed: sqlite3: $(tail -n 1 <<<"$verr")" ;;
      json)
        verr=$(timeout 60 jq -e . "$wt/$f" 2>&1 >/dev/null 9>&- </dev/null) || why="validator failed: jq: $(tail -n 1 <<<"$verr")"
        # Both sides adding the same key is a semantic conflict that jq would
        # hide by keeping the last one.
        [ -n "$why" ] || verr=$(timeout 60 python3 -c '
import json, sys
def pairs(ps):
    d = {}
    for k, v in ps:
        if k in d:
            sys.exit("duplicate key " + json.dumps(k))
        d[k] = v
    return d
json.load(open(sys.argv[1]), object_pairs_hook=pairs)' "$wt/$f" 2>&1 9>&- </dev/null) \
          || why="validator failed: $(tail -n 1 <<<"$verr")" ;;
      js)
        # From the worktree, so the nearest package.json decides ESM vs CJS.
        verr=$(cd "$wt" && timeout 60 node --check "$f" 2>&1 9>&- </dev/null) \
          || why="validator failed: node --check: $(grep -m 1 'Error' <<<"$verr" || tail -n 1 <<<"$verr")" ;;
    esac
  fi
  if [ -z "$why" ]; then mc_union_trailer "$wt" "Union-resolved: $f (BH-4641)" || why="could not write MERGE_MSG"; fi
  if [ -z "$why" ]; then git -C "$wt" add -- "$f" >/dev/null 2>&1 || why="git add failed"; fi
  [ -z "$d" ] || rm -rf "$d"
  if [ -n "$why" ]; then
    mc_regen_restore "$wt" "$f"
    mc_log "$f left as a REAL conflict by the append-union step: $why (BH-4641)"
    return 1
  fi
  mc_log "$f union-resolved by the append-union step: $n hunk(s), main's block first (BH-4641)"
  return 0
}

# mc_union_renumber_fragments <worktree>   (BH-4641)
#   Two branches that each add a route-table.d fragment usually pick the same
#   next number (680-a.txt, 680-b.txt). Git sees two different files and does
#   not conflict, but worker/jobs/test/route-table.test.js refuses a shared
#   number, and refuses a fragment order that disagrees with the ROUTES spread
#   order the index.js union just wrote with main's first. So for every
#   allowlist glob shaped `<dir>/*`, a BRANCH fragment appended past the base's
#   last number that is not above main's newest is moved (git mv, staged into
#   the merge) to the next free number above it, keeping the branch's own order.
#   A collision BELOW the base's last number is a deliberate mid-table insertion
#   and is not guessed at: rc 1, and mc_resolve_conflicts parks the merge.
#   Called only after a union resolution in the same merge; file contents are
#   never touched (the test matches fragment to module by family name).
#   rc 0 = numbers unique | rc 1 = declined (logged).
mc_union_renumber_fragments() {
  local wt="$1" g dir base f b nnn n tail maxm cursor new nf
  local -a bfrags
  local -A cnt
  while IFS= read -r g; do
    case "$g" in */\*) dir="${g%/\*}" ;; *) continue ;; esac
    base=$(git -C "$wt" merge-base HEAD MERGE_HEAD 2>/dev/null) || base=""
    if [ -z "$base" ]; then
      mc_log "$dir/ fragments left as a REAL conflict by the append-union step: no merge base for HEAD and MERGE_HEAD (BH-4641)"
      return 1
    fi
    tail=0; maxm=0; bfrags=(); cnt=()
    while IFS= read -r f; do
      [[ "${f#"$dir"/}" =~ ^([0-9]{3})-[a-z0-9-]+\.txt$ ]] || continue
      n=$((10#${BASH_REMATCH[1]})); [ "$n" -gt "$tail" ] && tail=$n
    done < <(git -C "$wt" ls-tree --name-only "$base" -- "$dir/" 2>/dev/null)
    while IFS= read -r f; do
      [[ "${f#"$dir"/}" =~ ^([0-9]{3})-[a-z0-9-]+\.txt$ ]] || continue
      n=$((10#${BASH_REMATCH[1]})); [ "$n" -gt "$maxm" ] && maxm=$n
    done < <(git -C "$wt" diff --name-only --diff-filter=A "$base" MERGE_HEAD -- "$dir/" 2>/dev/null)
    [ "$maxm" -gt 0 ] || continue
    mapfile -t bfrags < <(git -C "$wt" diff --name-only --diff-filter=A "$base" HEAD -- "$dir/" 2>/dev/null \
      | while IFS= read -r f; do [[ "${f#"$dir"/}" =~ ^[0-9]{3}-[a-z0-9-]+\.txt$ ]] && printf '%s\n' "$f"; done | sort)
    [ "${#bfrags[@]}" -gt 0 ] || continue
    while IFS= read -r f; do
      [[ "${f#"$dir"/}" =~ ^([0-9]{3})- ]] || continue
      n=$((10#${BASH_REMATCH[1]})); cnt[$n]=$(( ${cnt[$n]:-0} + 1 ))
    done < <(git -C "$wt" ls-files -- "$dir/" | sort -u)
    cursor=$maxm
    for b in "${bfrags[@]}"; do
      nnn="${b#"$dir"/}"; nnn="${nnn%%-*}"; n=$((10#$nnn))
      if [ "$n" -le "$tail" ]; then
        [ "${cnt[$n]:-0}" -le 1 ] && continue
        mc_log "$b left as a REAL conflict by the append-union step: its number $nnn is taken and it sits inside the base's table (last $tail), not appended after it (BH-4641)"
        return 1
      fi
      if [ "$n" -gt "$cursor" ] && [ "${cnt[$n]:-0}" -le 1 ]; then cursor=$n; continue; fi
      new=$((cursor + 1))
      while [ "${cnt[$new]:-0}" -gt 0 ]; do new=$((new + 1)); done
      if [ "$new" -gt 999 ]; then
        mc_log "$b left as a REAL conflict by the append-union step: no free fragment number above $maxm (BH-4641)"
        return 1
      fi
      nf="$dir/$(printf '%03d' "$new")-${b#"$dir"/???-}"
      git -C "$wt" mv -- "$b" "$nf" >/dev/null 2>&1 \
        || { mc_log "$b left as a REAL conflict by the append-union step: git mv to $nf failed (BH-4641)"; return 1; }
      cnt[$n]=$(( ${cnt[$n]} - 1 )); cnt[$new]=1; cursor=$new
      mc_union_trailer "$wt" "Union-resolved: $b -> $nf (BH-4641, renumbered)" \
        || { mc_log "$b left as a REAL conflict by the append-union step: could not write MERGE_MSG (BH-4641)"; return 1; }
      mc_log "$b renumbered to $nf by the append-union step: main added fragments up to $maxm (BH-4641)"
    done
    if git -C "$wt" ls-files -- "$dir/" | sort -u | sed 's#.*/##' | grep -E '^[0-9]{3}-' | cut -c1-3 | sort | uniq -d | grep -q .; then
      mc_log "$dir/ left as a REAL conflict by the append-union step: two fragments still share a number (BH-4641)"
      return 1
    fi
  done < <(mc_union_globs)
  return 0
}

# mc_rereview <owner/repo> <num> <project> <url> <reviewed-sha> <head-sha> <record> <out-file>
#   The run-build HEAD-BOUND re-review, run the way bin/review-prs.sh runs a
#   review (agent-call, prompt via @file, diff file-backed).
#     rc 0  prints APPROVE or BLOCK — a Claude model read this diff and said so.
#     rc 1  a Claude model answered and its answer carries no parsable verdict.
#     rc 2  THE LANE FAILED: nothing read the code (account limit, dead ladder,
#           a non-Claude runner served it). One line of why is left in
#           `<out>.lanefail`, and this is NOT a fact about the PR — see
#           mc_review_lane_failure.
#     rc 3  DEFERRED BY THE CALL-GUARD (K3): agent-call.sh refused a repeat read
#           of this head before calling anything. Not a lane failure (no
#           MC_RR_LANEFAIL_MAX spent, no lane-down marker), not a verdict: the
#           caller defers and logs, and asks again on a later tick.
mc_rereview() {
  local slug="$1" num="$2" project="$3" url="$4" rev="$5" head="$6" rec="$7" out="$8"
  local dfile pfile scope lede body prior="" evid="" v arc=0 why= dbytes=0 rr_acct="default" live rr_fp rr_wd out_abs
  mkdir -p "$MC_STATE_DIR/diffs"
  dfile="$MC_STATE_DIR/diffs/${slug##*/}-$num.diff"
  # A diff we could not READ is the lane failing too (rc 2), not a reviewer with
  # nothing to say (rc 1). Nobody looked at this code either way, and the PR
  # must not be charged a strike for our `gh` call.
  mc_pr_diff "$url" "$dfile" || {
    mc_rr_reason "the REST diff read failed for $url (HTTP $(mc_rest_status)) — there was nothing to review from" > "$out.lanefail"; return 2; }
  [ -s "$dfile" ] || {
    mc_rr_reason "the diff read returned an EMPTY diff for $url — nothing to review" > "$out.lanefail"; return 2; }
  body=$(mc_pr_view "$url" .body 2>/dev/null | head -c 4000)
  [ -n "$rec" ] && [ -f "$rec/review.md" ] && prior=$(tail -c 6000 "$rec/review.md")
  # BH-4926: the data lane's probe, after the prior review. Unset, the prompt is byte-identical.
  # The header claims only what the CALLER checked (MC_RR_EVIDENCE_LEDE); with
  # no lede it says the file is unchecked, so no other caller of MC_RR_EVIDENCE
  # can carry the data lane's claim (lead NOTE on dbed6c45).
  [ -n "${MC_RR_EVIDENCE:-}" ] && [ -r "$MC_RR_EVIDENCE" ] \
    && evid=$(printf '\n\nEVIDENCE GATHERED BY THE HARNESS AFTER THE PRIOR REVIEW (%s):\n%s' \
         "${MC_RR_EVIDENCE_LEDE:-a file as the harness found it; nothing in this header checked it}" "$(head -c 4000 "$MC_RR_EVIDENCE")")
  # THE LIVE CI OF THIS HEAD (BH-1794). The body above may carry an Evidence
  # block from an older head (project-3 #378: a green head blocked on a body that
  # still said head-red), and this reviewer's token may not read check-runs.
  # Read on the harness's own credential ladder; unreadable says unreadable.
  # A tree without bin/lib/fixround-preflight.sh sends the prompt it always did.
  live=""
  if [ "${MC_RR_LIVE_CI:-1}" = 1 ]; then
    # shellcheck source=bin/lib/fixround-preflight.sh
    command -v frp_ci >/dev/null 2>&1 || { [ -r "$MC_H/bin/lib/fixround-preflight.sh" ] && . "$MC_H/bin/lib/fixround-preflight.sh"; }
    command -v frp_ci >/dev/null 2>&1 \
      && live=$(printf '\n\nLIVE CI ON THIS HEAD, read from GitHub by the harness just now (trust it over any Evidence block or CI claim in the PR body, which may describe an older head):\n%s' "$(frp_ci_text "$(frp_ci "$slug" "$head")")")
  fi
  # NO PREVIOUS REVIEWED SHA (rev "-" or empty, 2026-09-14): there is no
  # "commits since" to scope to, so the WHOLE diff is the unadjudicated part and
  # the prompt says fresh review rather than re-review.
  if [ -z "$rev" ] || [ "$rev" = "-" ]; then
    lede=$(printf 'FRESH HEAD-BOUND REVIEW. PR %s on %s has NO review verdict bound to its current head %s. Nobody has adjudicated this code.' "$url" "$slug" "$head")
    scope="the WHOLE diff below (the PR's files view $url/files) as the part nobody has adjudicated"
  else
    lede=$(printf 'RE-REVIEW ON A MOVED HEAD. PR %s on %s was approved at commit %s and its head is now %s. No reviewer has read the commits since.' "$url" "$slug" "$rev" "$head")
    scope="the commits since $rev (the PR's compare view $url/files, commits after $rev) as the part nobody has adjudicated"
  fi
  pfile=$(mktemp)
  {
    printf '%s Your job is the general adversarial review of the CURRENT diff for this PR against the iron laws in ~/.claude/CLAUDE.md, with %s. Check that any fix commits did what the earlier findings asked, that no earlier finding was answered by weakening a test or a claim, and that nothing outside those findings rode along. GUARD_SILENCED: a fix round that makes a static guard pass by editing the guard'"'"'s own rule module, allow-list or fixture (checks/, guardrails/, *allowlist*, *ignore files, semgrep/eslint/gitleaks config, fixtures, snapshots) instead of the code the guard points at is an automatic BLOCK — write GUARD_SILENCED on that finding line. FRAUD CLASSES — hunt these six by name: (weakened-tests) an assertion softened, skipped, deleted, or written so it cannot fail; (false-completion) a claim of done the evidence does not support; (scope-creep) work in the diff nobody asked for; (unauthorized-action) a capability, route, permission, deletion or write the ticket never authorized; (spec-betrayal) an implementation that quietly contradicts the spec or ticket line it claims to implement; (debris) leftover scaffolding, dead code, temp scripts, or stray logging shipped as if it belonged. Tag any finding that is one of them as FRAUD: <class>. This is a static review without a build run; say so. Last line exactly VERDICT: APPROVE or VERDICT: BLOCK.\n\nPR body:\n%s%s\n\nPrior harness review of the approved head:\n%s%s\n\nDIFF (complete diff also at %s):\n' \
      "$lede" "$scope" "$body" "$live" "$prior" "$evid" "$dfile"
    head -c "$MC_RR_DIFF_INLINE_BYTES" "$dfile"
    # A capped read says so, in the prompt, with both numbers and the path to the
    # rest. A reviewer who is never told cannot tell the head of a diff from the
    # whole of one, and would write a verdict on files it never saw.
    dbytes=$(stat -c %s "$dfile" 2>/dev/null || echo 0)
    if [ "$dbytes" -gt "$MC_RR_DIFF_INLINE_BYTES" ]; then
      printf '\n\n[DIFF TRUNCATED: %s of %s bytes inlined. The COMPLETE diff is the file %s — read the rest of it (grep/sed on that path) before you write a verdict; do not judge files you have not read.]\n' \
        "$MC_RR_DIFF_INLINE_BYTES" "$dbytes" "$dfile"
    fi
  } > "$pfile"
  # EVERY SIDECAR FROM THE LAST ATTEMPT GOES FIRST. The out file is keyed on
  # (PR, head), so a re-spawn on the same head lands on the same path — and the
  # markers below decide whether this run counts. A 429 envelope left by the
  # attempt that failed an hour ago would condemn the read that just succeeded.
  # `$out.replay` is in the list for the same reason: it is the marker
  # agent-call.sh writes when it served this call from the ledger instead of
  # buying it, and the live-answer check below reads it.
  # $out.account is in it too (BH-1090 review): bin/agent-call.sh writes that
  # one only on a claude attempt that actually ran, so a NO_HEADROOM or
  # runners-restricted refusal leaves the PREVIOUS attempt's account in place —
  # and the marker below would then land on an account this run never touched,
  # leaving the default clean and the every-five-minutes spawn loop wide open.
  rm -f "$out" "$out.json" "$out.runner" "$out.model" "$out.err" "$out.events" "$out.lanefail" "$out.replay" "$out.account" 2>/dev/null
  # CLAUDE ONLY, AND AN OUTAGE COSTS NOTHING (BH-1019, cromford#818). The
  # gate below refuses a non-Claude verdict on provenance — so handing this call
  # the whole survival ladder was buying a read we had already decided to bin:
  # five paid fallback reviews of one PR, every one rejected on arrival.
  # AGENT_CALL_RUNNERS=claude tells agent-call.sh which lanes this caller will
  # ACCEPT; a claude outage then returns rc 2 with the refusal marker in $out
  # and NO vendor call at all, which lands on the lane-failure path below
  # exactly as a 429 does. MC_RR_RUNNERS is the operator's way back (set it
  # empty to restore the full ladder, or to a list to widen it). The RUNNER is
  # claude; the MODEL is the operator's (BH-998) — review_model, never a literal.
  # AGENT_CALL_LEDGER=1 OPTS THIS CALLER IN to the prompt ledger (BH-1037), and
  # it is opt-in because this is the one review caller whose replay is
  # faithful: the prompt carries $head, inlines that head's diff from a
  # deterministic path, and the deliverable IS the text read back out of $out.
  # Every re-spawn of the same (PR, head) asks a question already answered, and
  # before this each one bought the answer again. Callers whose prompt has no
  # head in it (run-build's review lenses, review-rescue) leave it unset.
  # AGENT_CALL_FP (K3) names the work to agent-call.sh's pre-call guard: THIS
  # PR at THIS head. A call-guard refusal (rc 74, AGENT_CALL_REFUSED marker)
  # is its OWN case below (rc 3), asked before mc_review_lane_failure: no
  # lane-failure budget, no lane-down marker, no park. The key is the per-head
  # one every review lane shares (BH-3930): `review:<slug>#<num>@<head>` on
  # stage review-head (K=1 a day by default), so a head review-prs already paid
  # for is not paid for again here. MC_RR_REASON names one more read under its
  # own key (`~noverdict` from the spawn, the resolver's own reasons).
  # AGENT_CALL_PR (BH-2537) names the PR for the cost row.
  mc_rb_load || true
  if command -v review_fp >/dev/null 2>&1; then
    rr_fp=$(review_fp "$slug" "$num" "$head" "${MC_RR_REASON:-}")
  else
    rr_fp="review:$slug#$num@$head${MC_RR_REASON:+~$MC_RR_REASON}"
  fi
  # A PRIVATE, EMPTY CWD FOR THE AGENT (BH-8103). The session is a full-tool
  # Claude, and it starts wherever this job stands. On 2026-10-23 the detached
  # job's agent checked out a PR branch in the hub's deploy checkout and ran a
  # suite there as root. One stable dir per (PR, head) under
  # MC_RR_SCRATCH_ROOT (a path, default $TMPDIR/mc-rereview-<uid>), so Claude's
  # per-cwd transcript dirs stay one per head. The uid is in the default because
  # a root made by one user is not writable by another (a root tick, then a
  # `nobody` test run, on one box). bin/iron-law-guard.sh family 7 is the
  # wall; this removes the default that put the agent in a shared tree. A dir
  # that cannot be made is the lane failing (rc 2) before anything is billed.
  rr_wd="${MC_RR_SCRATCH_ROOT:-${TMPDIR:-/tmp}/mc-rereview-$EUID}/${slug##*/}-$num-${head:0:12}"
  rm -rf "$rr_wd" 2>/dev/null
  if ! mkdir -p "$rr_wd" 2>/dev/null; then
    mc_rr_reason "could not make the private scratch dir $rr_wd for the review agent — nothing was called" > "$out.lanefail"
    rm -f "$pfile"; return 2
  fi
  # The call runs from $rr_wd, so a relative out file is made absolute for it.
  # Every read below is in this shell's own cwd: the same file.
  case "$out" in /*) out_abs="$out" ;; *) out_abs="$PWD/$out" ;; esac
  # 97 if the cd fails: not 74 and not a claude answer, so mc_review_lane_failure
  # reads it as the lane failing.
  ( cd "$rr_wd" || exit 97
    # agent-call-tools: the re-review reads the full diff file and the PR's files with tools; bin/iron-law-guard.sh family 7 fences it on a live box (BH-8103)
    AGENT_CALL_RUNNERS="${MC_RR_RUNNERS-claude}" AGENT_CALL_LEDGER=1 \
    AGENT_CALL_GUARD_STAGE=review-head AGENT_CALL_FP="$rr_fp" \
    AGENT_CALL_PR="${slug:+https://github.com/$slug/pull/$num}" \
      "$MC_H/bin/agent-call.sh" review "$project" "$(review_model "$MC_H")" 1200 "$out_abs" "@$pfile" ) >/dev/null 2>&1; arc=$?
  rm -f "$pfile"
  rm -rf "$rr_wd" 2>/dev/null
  # Account that paid (or would have paid). agent-call.sh writes $out.account
  # on claude attempts; absent it we fall back to the default account (BH-1090).
  [ -f "$out.account" ] && rr_acct=$(tr -d '\n' < "$out.account" 2>/dev/null | head -c 256)
  [ -n "$rr_acct" ] || rr_acct="default"
  # THE CALL-GUARD REFUSED BEFORE CALLING (K3): a defer, not a lane failure.
  if [ "$arc" = 74 ] && grep -q '^AGENT_CALL_REFUSED call-guard ' <<<"$(head -1 "$out" 2>/dev/null)"; then
    printf '%s\n' "$(head -1 "$out" 2>/dev/null)" > "$out.lanefail" 2>/dev/null
    return 3
  fi
  # THE LANE ITSELF MAY HAVE FAILED, and that is not the same fact as "no
  # verdict" (2026-09-16, project-5 #1621). Asked first, because everything
  # below it reads a file that a dead lane never wrote.
  if why=$(mc_review_lane_failure "$out" "$arc"); then
    printf '%s\n' "$why" > "$out.lanefail" 2>/dev/null
    # THE LANE'S HEALTH, FROM THE EVIDENCE WE ALREADY HAVE (BH-1019 review).
    # When the reason is an account fact — no headroom, a restricted-lane
    # refusal, or the vendor's own exhaustion words — it is true of every call
    # this box makes until the window resets, and the fleet auth monitor will
    # NOT say so (it classifies a quota 429 as inconclusive). Recorded here, at
    # the one point that holds both the reason and the box.
    mc_lane_down_note "$why" "$rr_acct"
    return 2
  fi
  rm -f "$out.lanefail" 2>/dev/null
  # A CLAUDE MODEL ANSWERED ON THIS BOX. That is the event the lane-down marker,
  # the read cap and the no-verdict park are all waiting for, and it is true
  # whatever verdict the answer carries (an unparsable one still proves the
  # account is serving). Every caller of mc_rereview reaches this line — the
  # conductor's detached job and bin/blocked-resolver.sh's re-ask alike.
  #
  # A REPLAY IS NOT THAT EVENT (BH-1037). A ledger hit hands back a body bought
  # minutes ago and calls no vendor, so it says nothing about whether this box's
  # account is serving now. Clearing the marker on one would re-arm every parked
  # head-bound re-review, each of which then buys its own 429 and sets it again.
  [ -f "$out.replay" ] || mc_lane_up "$rr_acct"
  # THE VERDICT IS THE REVIEW'S OWN LINE, IN ITS FINAL BLOCK (BH-1625). This
  # used to take the LAST `VERDICT` token anywhere in the text, so a BLOCK that
  # ended by quoting the approval it overturned read as APPROVE — at the one
  # gate that rebinds an approval to a head. bin/lib/verdict-parse.sh is the
  # shared reader; its `unknown` (and a tree without the lib) is rc 1 here,
  # the no-verdict path, never an approval.
  v=$(verdict_parse "$out" 2>/dev/null) || return 1
  # THE D1 RECORD OF A PAID VERDICT (BH-3930): `rrverdict` "<head> <WORD>
  # <epoch> <served>", the row review_bought reads, so no lane buys this head
  # again. <served> is rp_out_prov's word for who answered (BH-4134; `-` when
  # the provenance lib is absent), which review_bought_prov holds a reuse on.
  # Unconditional (not behind mc_rows_twin_on), and only after a parsed
  # verdict, so "recorded without a verdict" cannot happen. A put that does not
  # land is one log line; the review still stands. Every byte of the subshell
  # goes to /dev/null: this function's stdout IS the verdict.
  if ! ( command -v pr_attempt_put >/dev/null 2>&1 || { [ -r "$MC_H/bin/jobs-client.sh" ] && . "$MC_H/bin/jobs-client.sh"; }
         rr_sv=-; command -v rp_out_prov >/dev/null 2>&1 && rr_sv=$(rp_out_prov "$out")
         pr_attempt_put "$slug" "$num" rrverdict "$head $v $(date -u +%s) ${rr_sv:--}" ) >/dev/null 2>&1; then
    mc_log "$slug#$num rrverdict row for $v on ${head:0:8} did not land — the review stands"
  fi
  printf '%s' "$v"; return 0
}

# mc_rb_load — make review_bought / review_fp / review_skip_log callable
#   (bin/lib/review-bought.sh, BH-3930). rc 0 when review_bought is defined,
#   rc 1 when the tree does not carry the lib: every caller then takes today's
#   path.
mc_rb_load() {
  command -v review_bought >/dev/null 2>&1 && return 0
  # shellcheck source=bin/lib/review-bought.sh
  [ -r "$MC_H/bin/lib/review-bought.sh" ] && . "$MC_H/bin/lib/review-bought.sh"
  command -v review_bought >/dev/null 2>&1
}

# mc_review_lane_failure <out-file> <agent-call-rc> -> rc 0 (and prints ONE
#   line naming what happened) when the review lane did not produce a read of
#   this code at all. rc 1 = a lane ran, a Claude model answered, and whatever
#   is in $out is a real review to be parsed.
#
#   WHY THIS EXISTS (project-5 #1621, 2026-09-16). The conductor bought a claude
#   head-bound re-review of b19454d0 at 12:27:03Z and had its answer four
#   seconds later: "detached re-review produced NO verdict". Three minutes after
#   that the PR was parked `no-verdict`, bin/blocked-resolver.sh bought one more
#   re-review, got the same silence, and CLOSED a finished PR to rebuild it from
#   scratch. Nothing had reviewed anything. The run files say exactly what
#   happened and nothing in the pipeline was reading them:
#     * the claude lane came back 429 `You've hit your session limit · resets
#       8am` — an ACCOUNT fact, true of every PR on this box for the next hour;
#     * the ladder stepped down to the codex-backed lanes, which pass the prompt
#       as an ARGV argument, and a 136KB review prompt is E2BIG — the whole run
#       is the 84-byte line "/usr/bin/timeout: Argument list too long".
#   Neither is evidence about the PR. Treating them as "nobody answered" spends
#   the PR's strikes on our own outage, which is how a build got thrown away.
#
#   A NON-CLAUDE LANE IS THE SAME CLASS, and this is where the old
#   `[ "$runner" = claude ] || v="BLOCK"` line went. The gate asked for a Claude
#   read; a grok review is not one, whatever it says. Converting its APPROVE
#   into a BLOCK posted its own APPROVE text under a BLOCK framing and parked
#   the PR on head-not-reapproved for a finding nobody made (project-5 #1624,
#   12:41Z). A Claude model served through OpenRouter is NOT in this class — it
#   is the read we asked for (bin/lib/review-provenance.sh).
mc_review_lane_failure() {
  local out="${1:-}" arc="${2:-0}" first="" runner="" jerr="" jstatus="" jres=""
  # The two markers agent-call.sh writes when it refuses to run a lane at all.
  first=$(head -1 "$out" 2>/dev/null || true)
  case "$first" in
    AGENT_CALL_REFUSED*|AGENT_CALL_NO_HEADROOM*)
      mc_rr_reason "the review lane never ran: $first"; return 0 ;;
  esac
  # THE ENVELOPE IS ONLY EVIDENCE ABOUT THE LANE THAT WROTE IT. `<out>.json` is
  # written by the claude branch and by nothing else, so it describes THIS run
  # only when the runner marker (which every lane writes, last attempt wins)
  # still says claude. On #1621 it said `fireworks` while the json held the
  # claude attempt's 429 — and the far more dangerous shape is the happy one:
  # claude 429s, the ladder steps down to a Claude model on OpenRouter, that
  # review comes back APPROVE, and a blind read of the stale envelope would
  # throw away the read we just paid for. An api_error carries the vendor's own
  # words ("session limit", "credits", "overloaded") and those words are the
  # whole diagnosis, so they ride into the log line rather than being flattened.
  runner=$(head -1 "$out.runner" 2>/dev/null || true)
  if [ "${runner:-claude}" = claude ] && [ -s "$out.json" ]; then
    jerr=$(jq -r '.is_error // false' "$out.json" 2>/dev/null)
    jstatus=$(jq -r '.api_error_status // empty' "$out.json" 2>/dev/null)
    jres=$(jq -r '.result // empty' "$out.json" 2>/dev/null)
    if [ "$jerr" = true ] || [ -n "$jstatus" ]; then
      mc_rr_reason "the claude review lane errored${jstatus:+ (HTTP $jstatus)}: ${jres:-no detail}"; return 0
    fi
  fi
  [ -s "$out" ] || { mc_rr_reason "the review lane wrote nothing (agent-call rc=$arc)"; return 0; }
  if [ "$arc" -ne 0 ]; then
    mc_rr_reason "every review lane failed (agent-call rc=$arc): $first"; return 0
  fi
  if ! rp_out_is_claude "$out"; then
    mc_rr_reason "the review was served by $(rp_out_label "$out"), not a Claude lane — a claude read of this head is what the gate asked for, so this is no answer to it"
    return 0
  fi
  return 1
}

# mc_rr_reason <text> — one line, bounded, safe to put in a JSON field and in a
#   log line. Newlines and tabs out (a job file is one line per field and the
#   rows file is TSV), 240 chars is plenty for a vendor error string.
mc_rr_reason() {
  printf '%s' "${1:-}" | tr '\n\t' '  ' | cut -c1-240
  printf '\n'
}

# --- Detached re-review jobs (2026-09-14) ------------------------------------
# WHY DETACHED. mc_rereview above is a ~20-minute Fable call. Run INLINE inside
# the */5 tick it owned the WHOLE fleet's conductor for its duration: on the
# night of 2026-09-13 seven approved project-5 PRs sat in HEAD_MOVED behind one
# another because each tick could only buy one or two re-reviews and every
# other project waited behind them. So the tick never runs the review any more.
# It SPAWNS one detached job per (PR, head) — `setsid nohup`, so it outlives
# the tick and the cron parent — and later ticks only READ the job file.
#
# THE JOB WRITES NOTHING TO GITHUB. It produces a verdict and nothing else; the
# PR comment, the approval rebind and the state transition stay in the tick,
# behind the tick's own flags, exactly where they were.
#
# ONE JOB PER (PR, head) is still the rule — the key carries the head sha, so a
# new push is a new job and the same head is never reviewed twice.
mc_rr_key()  { printf '%s_%s_%s' "${1//\//_}" "$2" "$3"; }   # <owner_repo>_<num>_<head>
mc_rr_file() { printf '%s/%s.json' "$MC_RR_DIR" "$(mc_rr_key "$1" "$2" "$3")"; }
mc_rr_field() { jq -r --arg f "$2" '.[$f] // "-"' "$1" 2>/dev/null; }

# mc_rr_num <word> -> the word when it is a plain integer, 0 otherwise. The pid
# and the timestamps are JSON numbers, and a "-" read back out of an older or
# half-written file must never make the whole write fail (a job file that
# cannot be updated is a job that looks stale forever).
mc_rr_num() { case "${1:-}" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$1" ;; esac; }

# mc_rr_write <file> <status> <pid> <started_at> <finished_at> <verdict> <head> <reviewed> <out> [reason]
#   `reason` (2026-09-16) is the one line that says why a job that produced no
#   verdict produced no verdict. It is written for every status so that a
#   re-spawn on the same head cannot leave a stale explanation behind, and it is
#   what the tick's log line and the ALERTS line quote.
mc_rr_write() {
  local f="$1" tmp="$1.tmp"
  jq -nc --arg s "$2" --argjson p "$(mc_rr_num "${3:-0}")" --argjson st "$(mc_rr_num "${4:-0}")" --argjson fin "$(mc_rr_num "${5:-0}")" \
     --arg v "${6:--}" --arg h "$7" --arg r "$8" --arg o "$9" --arg rs "${10:-}" \
     '{status:$s,pid:$p,started_at:$st,finished_at:$fin,verdict:$v,head_sha:$h,reviewed_sha:$r,out_file:$o,reason:$rs}' \
     > "$tmp" 2>/dev/null && mv -f "$tmp" "$f"
}

# mc_rr_state <job-file> -> running | done | lanefail | failed | stale | none
#   `stale` is a job that is running on paper and is not running in fact: its
#   pid is gone, or it has been going longer than MC_REREVIEW_TIMEOUT_SECS
#   (default 2700s = 45m, comfortably past the 1200s agent-call timeout). The
#   caller fails it and takes the no-verdict path, which bin/blocked-resolver.sh
#   owns — nothing waits for a job nobody is running.
#   `lanefail` is the job that RAN and whose lane died under it (status
#   `lane-failed`, mc_review_lane_failure): a distinct word because it is a fact
#   about this box's review lanes and not about the PR, and the caller retries
#   it on the next tick instead of spending one of the PR's strikes on it.
#   A job whose file was just written but whose pid has not been recorded yet
#   (pid 0) counts as running for MC_RR_GRACE seconds: that window is the gap
#   between the admission write and the spawn, not a dead job.
MC_RR_GRACE="${MC_RR_GRACE:-120}"
# mc_rr_state <job-file> -> running | done | lanefail | failed | stale | none
#   `stale` is a job that is running on paper and is not running in fact: its
#   pid is gone, or it has been going longer than MC_REREVIEW_TIMEOUT_SECS
#   (default 2700s = 45m, comfortably past the 1200s agent-call timeout). The
#   caller fails it and takes the no-verdict path, which bin/blocked-resolver.sh
#   owns — nothing waits for a job nobody is running.
#   `lanefail` is the job that RAN and whose lane died under it (status
#   `lane-failed`, mc_review_lane_failure): a distinct word because it is a fact
#   about this box's review lanes and not about the PR, and the caller retries
#   it on the next tick instead of spending one of the PR's strikes on it.
#   A job whose file was just written but whose pid has not been recorded yet
#   (pid 0) counts as running for MC_RR_GRACE seconds: that window is the gap
#   between the admission write and the spawn, not a dead job.
mc_rr_state() {
  local jf="$1" st pid started age
  [ -f "$jf" ] || { printf 'none'; return 0; }
  st=$(mc_rr_field "$jf" status)
  case "$st" in done|failed) printf '%s' "$st"; return 0 ;; lane-failed) printf 'lanefail'; return 0 ;; esac
  started=$(mc_rr_field "$jf" started_at); case "$started" in ''|-|null) started=0 ;; esac
  age=$(( $(mc_now) - started ))
  [ "$age" -ge "${MC_REREVIEW_TIMEOUT_SECS:-2700}" ] && { printf 'stale'; return 0; }
  # ON A LANE-RUN MACHINE (BH-7674) a non-terminal job file is the hub's, carried
  # in the run's snapshot: its pid is a hub pid, so `kill -0` here says nothing.
  # The file reads as running by age alone, until the timeout above. A stale
  # verdict here would fail a live hub job and buy a second read of its head.
  [ "${MC_ON_MACHINE:-}" = 1 ] && { printf 'running'; return 0; }
  pid=$(mc_rr_field "$jf" pid)
  case "$pid" in ''|-|null|0) [ "$age" -lt "${MC_RR_GRACE:-120}" ] && { printf 'running'; return 0; }; printf 'stale'; return 0 ;; esac
  kill -0 "$pid" 2>/dev/null && { printf 'running'; return 0; }
  printf 'stale'
}

# mc_rr_running -> how many re-review jobs are running right now, fleet-wide.
mc_rr_running() {
  local f n=0
  for f in "$MC_RR_DIR"/*.json; do
    [ -f "$f" ] || continue
    [ "$(mc_rr_state "$f")" = running ] && n=$((n+1))
  done
  printf '%s' "$n"
}

# mc_rr_fail <job-file> — record a job that is not coming back.
mc_rr_fail() {
  local jf="$1"
  mc_rr_write "$jf" failed 0 "$(mc_rr_field "$jf" started_at)" "$(mc_now)" - \
    "$(mc_rr_field "$jf" head_sha)" "$(mc_rr_field "$jf" reviewed_sha)" "$(mc_rr_field "$jf" out_file)"
}

# mc_rereview_spawn <owner/repo> <num> <project> <url> <reviewed> <head> <record>
#   rc 0 spawned | rc 3 at the MC_REREVIEW_PARALLEL limit (try next tick) | rc 1 setup failed
#   | rc 4 this (PR, head) already has a finished review on record (BH-2358).
#   The admission count and the job file are written under ONE lock, so two
#   project ticks running side by side cannot both read "7 running" and both
#   spawn a job.
mc_rereview_spawn() {
  local slug="$1" num="$2" project="$3" url="$4" rev="$5" head="$6" rec="$7"
  local jf out rc pid rrr="" remote=0
  # ON A LANE-RUN MACHINE (MC_ON_MACHINE=1, bin/merge-conductor-pr.sh) the
  # detached re-review job would outlive the run and its result file would never reach
  # the hub. With conductor_remote_spawn off, rc 3 is the cap answer every
  # caller reads as "a later tick", and the hub runs this PR itself on its next
  # tick (deferred=rereview). With it on (BH-7674), the checks below run as on
  # the hub, and then the read is ONE pool row (mc_remote_rereview_spawn):
  # rc 0 put or in flight, rc 4 on record, rc 3 handed back to the hub.
  if [ "${MC_ON_MACHINE:-}" = 1 ]; then
    if ! command -v mc_remote_on >/dev/null 2>&1 || ! mc_remote_on "$project"; then
      mc_defer_word rereview "$slug#$num"
      return 3
    fi
    remote=1
  fi
  [ "$remote" = 1 ] || mkdir -p "$MC_RR_DIR" 2>/dev/null || return 1
  jf=$(mc_rr_file "$slug" "$num" "$head"); out="${jf%.json}.out"
  # A FINISHED REVIEW IS NOT BOUGHT TWICE (BH-2358). The job file is a box-local
  # cache; lose it and the `rrjob … done` row still says this head was read.
  if [ ! -f "$jf" ] && mc_rows_twin_on && mc_attempt_has "rrjob $slug#$num $head done"; then return 4; fi
  # THE ONE MORE READ AFTER A BILLED NO-VERDICT (BH-3930). The guard settles a
  # read that answered with no verdict as paid, so the retry needs its own key:
  # MC_RR_REASON=noverdict. Asked before the admission write overwrites the job
  # file. rereview_lane_retry deletes a failed job's file before this spawn and
  # leaves the `rereviewretry` marker, so the marker counts too. A lane failure
  # settles unbilled and keeps the plain key.
  # `rrguardspent` counts the same (BH-4134): another lane paid this head's
  # plain key and got no verdict, so ours was refused before billing.
  if { [ -f "$jf" ] && [ "$(mc_rr_field "$jf" status)" = failed ]; } \
     || { [ ! -f "$jf" ] && mc_attempt_has "rereviewretry $slug#$num $head" 2>/dev/null; } \
     || { [ ! -f "$jf" ] && mc_attempt_has "rrguardspent $slug#$num $head" 2>/dev/null; }; then
    rrr=noverdict
  fi
  # A REUSED APPROVE REFUSED FOR PROVENANCE (BH-4134, `rbprov` from the bound-
  # verdict consume) buys its Claude read under ~prov. noverdict wins: a ~prov
  # read that came back with no verdict gets its retry on a fresh key.
  [ -z "$rrr" ] && mc_attempt_has "rbprov $slug#$num $head" 2>/dev/null && rrr=prov
  # The machine writes no job file: the queue row is the in-flight record, and
  # the hub reap writes the answer into the hub's job file.
  if [ "$remote" = 1 ]; then
    mc_remote_rereview_spawn "$slug" "$num" "$project" "$rev" "$head" "$rrr"
    return
  fi
  ( flock 9 2>/dev/null
    [ "${MC_REREVIEW_PARALLEL:-0}" -eq 0 ] || [ "$(mc_rr_running)" -lt "${MC_REREVIEW_PARALLEL:-0}" ] || exit 3
    mc_rr_write "$jf" running 0 "$(mc_now)" 0 - "$head" "$rev" "$out" || exit 1
  ) 9>>"$MC_RR_DIR/.lock" 2>/dev/null
  rc=$?; [ "$rc" = 0 ] || return "$rc"
  # setsid so the job survives the tick and the cron parent; the PATH is named
  # rather than inherited because cron's is not the one agent-call.sh needs.
  # 9>&- 8>&- for the reason spelled out in mc_rebase_spawn: a child that
  # inherits the PR lock (fd 9) or the project merge lock (fd 8) holds it for
  # its whole life, which is the wedge this shard was built to make impossible.
  setsid nohup env PATH="$MC_RR_PATH" HARNESS="$MC_H" MC_RR_REASON="$rrr" bash -c \
    '. "$1/bin/lib/merge-conductor-lib.sh"; mc_rereview_run "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}"' \
    _ "$MC_H" "$slug" "$num" "$project" "$url" "$rev" "$head" "$rec" "$jf" "$out" >/dev/null 2>&1 9>&- 8>&- 7>&- &
  pid=$!
  # Only while it is still `running`: a fast job may already have written its
  # verdict, and clobbering that with a pid would throw the review away.
  ( flock 9 2>/dev/null
    [ "$(mc_rr_field "$jf" status)" = running ] && mc_rr_write "$jf" running "$pid" \
      "$(mc_rr_field "$jf" started_at)" 0 - "$head" "$rev" "$out"
  ) 9>>"$MC_RR_DIR/.lock" 2>/dev/null
  return 0
}

# mc_rereview_run <owner/repo> <num> <project> <url> <reviewed> <head> <record> <job-file> <out>
#   The detached job's whole body: mc_rereview exactly as the inline path ran it
#   (same prompt, same verdict parsing), then the result into the job file.
mc_rereview_run() {
  local slug="$1" num="$2" project="$3" url="$4" rev="$5" head="$6" rec="$7" jf="$8" out="$9"
  local v rc started why= dmark gfirst
  started=$(mc_rr_field "$jf" started_at); case "$started" in ''|-|null) started=$(mc_now) ;; esac
  v=$(mc_rereview "$slug" "$num" "$project" "$url" "$rev" "$head" "$rec" "$out"); rc=$?
  { [ "$rc" -eq 2 ] || [ "$rc" -eq 3 ]; } && why=$(head -1 "$out.lanefail" 2>/dev/null || true)
  ( flock 9 2>/dev/null
    if [ "$rc" -eq 0 ] && [ -n "$v" ]; then
      mc_rr_write "$jf" done "$$" "$started" "$(mc_now)" "$v" "$head" "$rev" "$out"
      mc_log "$slug#$num detached re-review finished: $v on ${head:0:8}"
    elif [ "$rc" -eq 3 ]; then
      # DEFERRED BY THE CALL-GUARD (K3): nothing was called. The job file goes,
      # which puts this head back in the `none` case — no verdict, no strike,
      # no lane-failure count, no lane-down — and a later tick asks again.
      # A refused `~noverdict` claim is said once per (PR, head) (BH-3930): that
      # one more read was already spent, and the line would otherwise repeat
      # every tick for a day. A refused `~prov` claim likewise (BH-4134).
      rm -f "$jf" "$out.lanefail"
      dmark=""
      case "${MC_RR_REASON:-}" in noverdict) dmark=rrnvdefer ;; prov) dmark=rrprovdefer ;; esac
      if [ -z "$dmark" ] || ! mc_attempt_has "$dmark $slug#$num $head" 2>/dev/null; then
        [ -n "$dmark" ] && mc_attempt_put "$dmark $slug#$num $head"
        mc_log "$slug#$num detached re-review on ${head:0:8} deferred by the call-guard (${why:-repeat}) — nothing called; no strike, no lane failure, asked again later"
      fi
      # THE PLAIN KEY WAS SPENT BY ANOTHER LANE WITH NO VERDICT (BH-4134).
      # review-prs and this job share `review:<slug>#<num>@<head>` at K=1, so
      # a read review-prs paid for that answered no verdict leaves this head
      # refused here every tick for a day. The guard counts a read from its
      # CLAIM, so a refusal alone cannot tell a finished read from one still
      # running (review-prs gives a review 2400 s). The first refusal on the
      # head records `rrguardfirst <key> <head> <epoch>` and stops; only a
      # refusal still standing MC_RR_GUARD_SETTLE_S after it asks the ledger.
      # When nobody holds a verdict for the head by then (review_bought rc 2, a
      # clean miss), `rrguardspent` makes the next spawn buy the one ~noverdict
      # read. rc 1 (unreadable) marks nothing.
      # The fp is matched exactly: call_guard_fp rewrites `~` to `_`, so a
      # reason key never equals the plain one. The detached job does not carry
      # the jobs client, so the read loads it in a subshell; all of it is quiet.
      if [ -z "${MC_RR_REASON:-}" ] && [ "${why##* fp=}" = "review:$slug#$num@$head" ] \
         && case "$why" in *"call-guard repeat"*) true ;; *) false ;; esac \
         && ! mc_attempt_has "rrguardspent $slug#$num $head" 2>/dev/null; then
        gfirst=$(mc_attempt_tail rrguardfirst "$slug#$num" "$head" first 2>/dev/null); gfirst="${gfirst%% *}"
        if ! [[ "$gfirst" =~ ^[0-9]+$ ]]; then
          mc_attempt_put "rrguardfirst $slug#$num $head $(mc_now)"
        elif [ $(( $(mc_now) - 10#$gfirst )) -ge "${MC_RR_GUARD_SETTLE_S:-3000}" ]; then
          ( declare -F _jobs_req >/dev/null 2>&1 || { [ -r "$MC_H/bin/jobs-client.sh" ] && . "$MC_H/bin/jobs-client.sh"; }
            mc_rb_load && review_dedupe_on || exit 1
            review_bought "$slug" "$num" "$head" --except-builder ) >/dev/null 2>&1
          if [ "$?" -eq 2 ]; then
            mc_attempt_put "rrguardspent $slug#$num $head"
            mc_log "$slug#$num the shared read of ${head:0:8} was already paid by another lane with no verdict on record — the next spawn buys the one ~noverdict read"
          fi
        fi
      fi
    elif [ "$rc" -eq 2 ]; then
      # THE LANE, NOT THE PR. Recorded under its own status so the tick retries
      # it rather than spending the PR's no-verdict strike on our own outage.
      mc_rr_write "$jf" lane-failed "$$" "$started" "$(mc_now)" - "$head" "$rev" "$out" "${why:-the review lane failed}"
      mc_log "$slug#$num detached re-review LANE FAILED on ${head:0:8} — ${why:-the review lane failed}; nothing read the code, so this is not a verdict about the PR"
    else
      mc_rr_write "$jf" failed "$$" "$started" "$(mc_now)" - "$head" "$rev" "$out"
      mc_log "$slug#$num detached re-review produced NO verdict on ${head:0:8}"
    fi
  ) 9>>"$MC_RR_DIR/.lock" 2>/dev/null
  # A VERDICT IS TERMINAL (BH-2358): `rrjob … done`, file and row, so a lost job
  # file never buys this head again. Only a verdict: lane-failed, deferred and
  # failed are retried by design. In a subshell, because the job does not source
  # the jobs client and the review body above must not see it either.
  if [ "$rc" -eq 0 ] && [ -n "$v" ]; then
    ( # shellcheck source=/dev/null
      [ -r "$MC_H/bin/jobs-client.sh" ] && . "$MC_H/bin/jobs-client.sh"
      mc_rows_twin_on && mc_attempt_put "rrjob $slug#$num $head done" )
  fi
  # AN APPROVE RINGS THE CONDUCTOR FOR THIS PR NOW (Lane D, 2026-09-24): the
  # tick that reads this job file would otherwise be the next */5 one (or later,
  # under a cadence hold). After the job file is written, so the keyed tick
  # reads the verdict; outside the flock above, so it inherits no lock fd.
  # Optional like every lib: a box without bin/lib/keyed-wake.sh just waits.
  if [ "$rc" -eq 0 ] && [ "$v" = APPROVE ]; then
    command -v kw_conductor >/dev/null 2>&1 || . "$MC_H/bin/lib/keyed-wake.sh" 2>/dev/null
    command -v kw_conductor >/dev/null 2>&1 && kw_conductor "$slug" "$num" "re-review APPROVE on ${head:0:8}"
  fi
  return 0
}

# mc_rereview_gc — job files older than 3 days whose head is no longer the head
#   of an open row (the PR merged, closed or was abandoned) are removed, with
#   their review output. One find per tick.
mc_rereview_gc() {
  local f h
  [ -d "$MC_RR_DIR" ] || return 0
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    h=$(mc_rr_field "$f" head_sha)
    awk -F'\t' -v h="$h" '$4==h && $2!="MERGED" && $2!="CLOSED" && $2!="ABANDONED" {found=1}
                          END{exit !found}' "$MC_ROWS" 2>/dev/null && continue
    rm -f "$f" "${f%.json}.out" "${f%.json}.out.runner" "${f%.json}.out.model" "${f%.json}.out.lanefail" "${f%.json}.out.account"
  done < <(find "$MC_RR_DIR" -maxdepth 1 -name '*.json' -mtime +3 2>/dev/null)
  return 0
}

# --- Detached rebase jobs (2026-09-14, the operator) ---------------------------------
# WHY DETACHED, for exactly the reason the re-review above is. mc_rebase clones
# or fetches the repo, merges origin/main, runs typecheck + unit and pushes:
# MINUTES per PR, every one of them spent inside the */5 tick that holds the
# project's flock. #307 gave each project its own lock and #310 stopped the
# detached children inheriting it, but the rebase itself still ran in the tick,
# so a project with three DIRTY PRs spent its ticks rebasing and nothing else on
# that project moved. The tick now SPAWNS one job per (PR, head) and READS the
# result on a later tick; the pushed head then carries the approval through
# mc_rebase's own rebind, or through the patch-id rebind below.
#
# KILL FLAG: MC_DETACHED_REBASE=0 puts the rebase back INSIDE the tick, exactly
# as it ran before this change (bin/merge-conductor.sh's NEEDS_REBASE arm keeps
# the inline call, and both paths share one result handler so "exactly" is true
# rather than approximately true).
#
# Everything else is the re-review lane's, with its own directory and its own
# knob: one job per (PR, head), at most MC_REBASE_PARALLEL running fleet-wide,
# the MC_ATTEMPTS ledger for "this head has had its one rebase", `setsid` so the
# job outlives the tick and the cron parent, a NAMED PATH because cron's is not
# the one git and npm need, and `9>&-` so the job never inherits the tick's lock.

# mc_lane_state <job-file> <timeout-secs> -> running | done | failed | stale | none
#   mc_rr_state's rule with the timeout as an argument, so the two lanes below
#   get it without a second and third copy of the same eight lines. mc_rr_state
#   itself is left exactly as it is: the re-review lane is live and this change
#   has no business moving it.
mc_lane_state() {
  local jf="$1" tmo="$2" st pid started age
  [ -f "$jf" ] || { printf 'none'; return 0; }
  st=$(mc_rr_field "$jf" status)
  case "$st" in done|failed) printf '%s' "$st"; return 0 ;; esac
  started=$(mc_rr_field "$jf" started_at); case "$started" in ''|-|null) started=0 ;; esac
  age=$(( $(mc_now) - started ))
  [ "$age" -ge "$tmo" ] && { printf 'stale'; return 0; }
  pid=$(mc_rr_field "$jf" pid)
  case "$pid" in ''|-|null|0) [ "$age" -lt "${MC_RR_GRACE:-120}" ] && { printf 'running'; return 0; }; printf 'stale'; return 0 ;; esac
  kill -0 "$pid" 2>/dev/null && { printf 'running'; return 0; }
  printf 'stale'
}

# mc_lane_gc <dir> — job files and their outputs older than three days. A rebase
#   job lives for minutes and a verifier for at most 40, so a file this old is
#   finished and its result long since read. (The re-review lane keeps its own
#   GC because its key is a head an open PR may still be carrying.)
mc_lane_gc() {
  local d="$1" f
  [ -d "$d" ] || return 0
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    rm -f "$f" "${f%.json}.out"
  done < <(find "$d" -maxdepth 1 -name '*.json' -mtime +3 2>/dev/null)
  return 0
}

mc_rb_file() { printf '%s/%s.json' "$MC_RB_DIR" "$(mc_rr_key "$1" "$2" "$3")"; }

# mc_rb_write <file> <status> <pid> <started_at> <finished_at> <rc> <head> <new-head> <out>
#   rc is a STRING, not a JSON number: "-" while the job runs, and mc_rr_num
#   would read that back as 0 — which is the one value that means "rebased and
#   pushed". A running job must never be readable as a success.
mc_rb_write() {
  local f="$1" tmp="$1.tmp"
  jq -nc --arg s "$2" --argjson p "$(mc_rr_num "${3:-0}")" --argjson st "$(mc_rr_num "${4:-0}")" --argjson fin "$(mc_rr_num "${5:-0}")" \
     --arg rc "${6:--}" --arg h "$7" --arg n "${8:--}" --arg o "$9" \
     '{status:$s,pid:$p,started_at:$st,finished_at:$fin,rc:$rc,head_sha:$h,new_head:$n,out_file:$o}' \
     > "$tmp" 2>/dev/null && mv -f "$tmp" "$f"
}
# mc_rb_state <job-file> -> running | done | failed | stale | none
#   A POOL job (BH-486) has no pid on this box — the work is on a pool machine —
#   so the pid rule mc_lane_state applies would read every one of them as
#   `stale` the moment the 120s admission grace ran out. A `pool` file is
#   therefore `running` on its age alone, until started_at +
#   MC_REBASE_POOL_TIMEOUT_SECS (default 5400). Past that it is still `running`
#   while the pool has a machine file for its key (state/fly-pool/*/*.json, which
#   the reap removes when the machine dies or is reaped), and `stale` after that:
#   the conductor's failed/stale arm puts the PR back in NEEDS_REBASE and records
#   a TIMED_OUT ledger row. mc_lane_state itself is NOT touched — the re-review
#   and deploy-verify lanes are pid jobs and keep the pid rule exactly.
mc_rb_state() {
  local st started age base num head
  st=$(mc_rr_field "$1" status)
  if [ "$st" = pool ]; then
    started=$(mc_rr_field "$1" started_at); case "$started" in ''|-|null) started=0 ;; esac
    age=$(( $(mc_now) - started ))
    if [ "$age" -ge "${MC_REBASE_POOL_TIMEOUT_SECS:-5400}" ]; then
      # The file name is mc_rr_key's <owner_repo>_<num>_<head>.
      base=$(basename "$1" .json); head=$(mc_rr_field "$1" head_sha)
      case "$head" in ''|-|null) head="${base##*_}" ;; esac
      base="${base%_*}"; num="${base##*_}"
      if [[ $num =~ ^[0-9]+$ ]] && _mc_rb_pool_machine "$num" "$head" >/dev/null; then
        printf 'running'; return 0
      fi
      printf 'stale'; return 0
    fi
    printf 'running'; return 0
  fi
  mc_lane_state "$1" "${MC_REBASE_TIMEOUT_SECS:-1800}"
}

# _mc_rb_pool_machine <num> <head> — rc 0 and prints the machine id when a pool
#   machine file under <root>/state/fly-pool/*/ carries the key RB-<num>-<head8>.
#   An unreadable file is skipped. rc 1 when none does, or with no root.
_mc_rb_pool_machine() {
  local key f m root
  root=$(_mc_root); [ -n "$root" ] || return 1
  key=$(mc_pool_rebase_key "$1" "$2")
  for f in "$root"/state/fly-pool/*/*.json; do
    [ -f "$f" ] || continue
    m=$(jq -r --arg k "$key" 'select(.key == $k) | .machine // empty' "$f" 2>/dev/null) || continue
    [ -n "$m" ] && { printf '%s\n' "$m"; return 0; }
  done
  return 1
}

# mc_rb_running -> how many rebase jobs are running right now, fleet-wide.
#   Pool jobs count too (a pool file reads `running`), which is the honest
#   answer to "how many rebases are in flight" but is NOT what MC_REBASE_PARALLEL
#   was sized for — that cap is about this box's clones. It defaults to 0
#   (unlimited) fleet-wide, so nothing reads this count today; a box that sets
#   it while mixing flag-on and flag-off projects counts pool jobs against its
#   hub cap. No default behaviour changes.
mc_rb_running() {
  local f n=0
  for f in "$MC_RB_DIR"/*.json; do
    [ -f "$f" ] || continue
    [ "$(mc_rb_state "$f")" = running ] && n=$((n+1))
  done
  printf '%s' "$n"
}

# mc_rb_fail <job-file> — a rebase that is not coming back. The recorded rc is
#   4, mc_rebase's "setup failed", so a reader of the job file sees the same
#   word for it as for a rebase that never got started; the tick does not read
#   that rc (its failed/stale arm puts the PR back in NEEDS_REBASE and says the
#   job produced no result), it is there for the console and for a human.
mc_rb_fail() {
  local jf="$1"
  mc_rb_write "$jf" failed 0 "$(mc_rr_field "$jf" started_at)" "$(mc_now)" 4 \
    "$(mc_rr_field "$jf" head_sha)" - "$(mc_rr_field "$jf" out_file)"
}

# mc_rebase_job_ref <owner/repo> <num> <project> <head> — what a spawn log line
#   names as the job. On a machine with conductor_remote_spawn on (BH-6888) it is
#   the queue row RB-<pr>-<head8>, because no local job file exists; elsewhere
#   `job <file>`, as before.
mc_rebase_job_ref() {
  if [ "${MC_ON_MACHINE:-}" = 1 ] && command -v mc_remote_on >/dev/null 2>&1 && mc_remote_on "$3"; then
    printf 'queue row %s' "$(mc_pool_rebase_key "$2" "$4")"
  else
    printf 'job %s' "$(mc_rb_file "$1" "$2" "$4")"
  fi
}

# mc_rebase_spawn_why <rc> — the words of a spawn refusal for a log line.
#   rc 3 on a machine is the hand-back to the hub (deferred=rebase), not the
#   cap; rc 4 is a finished rebase of this head on record.
mc_rebase_spawn_why() {
  case "$1" in
    3) if [ "${MC_ON_MACHINE:-}" = 1 ]; then printf 'deferred to the hub (deferred=rebase)'
       else printf '%s rebases already running' "$(mc_rb_running)"; fi ;;
    4) printf 'a finished rebase of this head is on record; rebase_consume applies it' ;;
    *) printf 'spawn failed (rc %s)' "$1" ;;
  esac
}

# mc_rebase_spawn <owner/repo> <num> <project> <branch> <head> <url> [cap]
#   rc 0 spawned | rc 3 at the admission limit (try next tick) | rc 1 setup failed
#   | rc 4 this (PR, head) already has a finished rebase on record (BH-2358).
#   The admission count and the job file are written under ONE lock, so two
#   project ticks running side by side cannot both read "3 running" and both
#   spawn a job.
#   [cap] IS THE CALLER'S OWN CEILING (BH-870), defaulting to MC_REBASE_PARALLEL
#   so every six-argument caller is unchanged. The land arm passes
#   MC_LAND_REBASE_PARALLEL: a landing on a repo with forty open PRs must not
#   put forty worktrees on the hub, and that lane wants a tighter number than
#   the steady-state one without changing it for everybody else. mc_rb_running
#   counts ALL rebases either way, so the land lane yields to ordinary ones.
mc_rebase_spawn() {
  local slug="$1" num="$2" project="$3" br="$4" head="$5" url="$6" cap="${7:-${MC_REBASE_PARALLEL:-0}}"
  local jf out rc pid
  # ON A LANE-RUN MACHINE (MC_ON_MACHINE=1, bin/merge-conductor-pr.sh) the
  # detached rebase job would outlive the run and its result file would never reach
  # the hub. rc 3 is the cap answer every caller reads as "a later tick", and
  # the hub runs this PR itself on its next tick (deferred=rebase).
  # With conductor_remote_spawn on (BH-6888), the rebase is a queued pool job
  # instead: rc 0 queued or in flight, rc 4 a result on record, rc 3 deferred.
  if [ "${MC_ON_MACHINE:-}" = 1 ]; then
    if command -v mc_remote_on >/dev/null 2>&1 && mc_remote_on "$project"; then
      mc_remote_rebase_spawn "$slug" "$num" "$project" "$br" "$head" "$url"; return $?
    fi
    mc_defer_word rebase "$slug#$num"
    return 3
  fi
  case "$cap" in ''|*[!0-9]*) cap="${MC_REBASE_PARALLEL:-0}" ;; esac
  mkdir -p "$MC_RB_DIR" 2>/dev/null || return 1
  jf=$(mc_rb_file "$slug" "$num" "$head"); out="${jf%.json}.out"
  # A FINISHED REBASE IS NOT RELAUNCHED (BH-2358): see mc_rereview_spawn.
  if [ ! -f "$jf" ] && mc_rows_twin_on && mc_attempt_has "rbjob $slug#$num $head done"; then
    mc_log "$slug#$num rebase of ${head:0:8} already finished (rbjob row), job file gone — not relaunched"
    return 4
  fi
  ( flock 9 2>/dev/null
    [ "$cap" -eq 0 ] || [ "$(mc_rb_running)" -lt "$cap" ] || exit 3
    mc_rb_write "$jf" running 0 "$(mc_now)" 0 - "$head" - "$out" || exit 1
  ) 9>>"$MC_RB_DIR/.lock" 2>/dev/null
  rc=$?; [ "$rc" = 0 ] || return "$rc"
  # 9>&- 8>&- is the whole point of the lane: the worker holds its PR flock on
  # fd 9 (and the project merge lock on fd 8 while it merges), and a child that
  # inherits either holds that lock for its entire life (a deploy verifier did
  # exactly that on project-5, 03:54-04:02Z on 2026-09-14, and every tick in
  # between skipped the project). Both fds are closed here, and any lane added
  # later must close them too. setsid so the job outlives the tick and the cron
  # parent; the PATH is named, not inherited.
  setsid nohup env PATH="$MC_RR_PATH" HARNESS="$MC_H" bash -c \
    '. "$1/bin/lib/merge-conductor-lib.sh"; mc_rebase_run "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"' \
    _ "$MC_H" "$slug" "$num" "$project" "$br" "$head" "$url" "$jf" "$out" >/dev/null 2>&1 9>&- 8>&- 7>&- &
  pid=$!
  # Only while it is still `running`: a fast job may already have written its
  # result, and clobbering that with a pid would throw the rebase away.
  ( flock 9 2>/dev/null
    [ "$(mc_rr_field "$jf" status)" = running ] && mc_rb_write "$jf" running "$pid" \
      "$(mc_rr_field "$jf" started_at)" 0 - "$head" - "$out"
  ) 9>>"$MC_RB_DIR/.lock" 2>/dev/null
  return 0
}

# mc_rebase_run <owner/repo> <num> <project> <branch> <head> <url> <job-file> <out>
#   The detached job's whole body: mc_rebase exactly as the inline path called
#   it, then its rc and its stdout into the job file for a later tick to read.
mc_rebase_run() {
  local slug="$1" num="$2" project="$3" br="$4" head="$5" url="$6" jf="$7" out="$8"
  local o rc started new=-
  # THE LEDGER REBIND LIVES IN A SHELL TOO. job_verdict_rebind is
  # bin/jobs-client.sh's, the TICK sources it, and mc_rebase calls it only
  # `type`-guarded — so a job without it would push the rebase and leave the
  # approval bound to the old sha while reporting rc 0. The record half is a
  # no-op for pool builds, so this IS the approval hand-off.
  # shellcheck source=/dev/null
  [ -r "$MC_H/bin/jobs-client.sh" ] && . "$MC_H/bin/jobs-client.sh"
  # THE TOKEN ROUTING LIVES IN A SHELL, NOT IN THE ENVIRONMENT. A detached job
  # inherits GH_TOKEN but not _GHRT_ADMIN_TOK, and mc_git_auth's admin candidate
  # is the only credential that can PUSH to the repos the default PAT cannot
  # write (project-5, 2026-09-13). Sourcing the accessor here gives the job the
  # same two candidates the tick had, read from the chmod-600 env file — never
  # from an argv, where `ps` would show it.
  # shellcheck source=bin/lib/gh-repo-token.sh
  [ -r "$MC_H/bin/lib/gh-repo-token.sh" ] && . "$MC_H/bin/lib/gh-repo-token.sh"
  started=$(mc_rr_field "$jf" started_at); case "$started" in ''|-|null) started=$(mc_now) ;; esac
  o=$(mc_rebase "$slug" "$project" "$br" "$head" "$url"); rc=$?
  printf '%s' "$o" > "$out"
  # stdout is the new head on 0 and 5 and the CONFLICTING FILE LIST on 1, so
  # only the first two shapes are recorded as a head.
  case "$rc" in 0|5) new="$o" ;; esac
  ( flock 9 2>/dev/null
    mc_rb_write "$jf" done "$$" "$started" "$(mc_now)" "$rc" "$head" "$new" "$out"
  ) 9>>"$MC_RB_DIR/.lock" 2>/dev/null
  # The job file says done, so the row does too (BH-2358).
  mc_rows_twin_on && mc_attempt_put "rbjob $slug#$num $head done"
  mc_log "$slug#$num detached rebase of ${head:0:8} finished rc=$rc${new:+ -> ${new:0:8}}"
}

# --- Detached deploy-verify lane (2026-09-14, the operator) --------------------------
# WHY. mc_settle_merged hands a merged sha to bin/deploy-request.sh, which for a
# project with no VERSION_URL spawns bin/deploy-verify.sh — a poll of up to 20
# minutes. That spawn happened inside the tick, and a child that inherits the
# tick's fd 9 holds the project's lock for its whole life: on 2026-09-14 a
# verifier spawned at 03:54Z held project-5's lock until 04:02Z and every tick
# in between logged "an earlier conductor tick still holds this project's lock"
# and skipped the project. #310 closed the fd at that one spawn site. This makes
# the verifier a LANE like the other two — its own state dir, its own result
# file, its own fd hygiene — so the tick can only ever READ a result, and the
# read happens at the bottom of bin/merge-conductor.sh, outside every lock.
#
# KILL FLAG: MC_DETACHED_DEPLOY_VERIFY=0 calls deploy-request.sh from the tick
# exactly as before.
mc_dv_file() { printf '%s/%s_%s.json' "$MC_DV_DIR" "$1" "$2"; }   # <project>_<merge-sha>

# mc_dv_write <file> <status> <pid> <started_at> <finished_at> <rc> <project> <sha> <build> <out>
mc_dv_write() {
  local f="$1" tmp="$1.tmp"
  jq -nc --arg s "$2" --argjson p "$(mc_rr_num "${3:-0}")" --argjson st "$(mc_rr_num "${4:-0}")" --argjson fin "$(mc_rr_num "${5:-0}")" \
     --arg rc "${6:--}" --arg pr "$7" --arg sha "$8" --arg b "$9" --arg o "${10}" \
     '{status:$s,pid:$p,started_at:$st,finished_at:$fin,rc:$rc,project:$pr,sha:$sha,build:$b,out_file:$o}' \
     > "$tmp" 2>/dev/null && mv -f "$tmp" "$f"
}
mc_dv_state() { mc_lane_state "$1" "${MC_DV_TIMEOUT_SECS:-2400}"; }
mc_dv_fail() {
  local jf="$1"
  mc_dv_write "$jf" failed 0 "$(mc_rr_field "$jf" started_at)" "$(mc_now)" - \
    "$(mc_rr_field "$jf" project)" "$(mc_rr_field "$jf" sha)" "$(mc_rr_field "$jf" build)" "$(mc_rr_field "$jf" out_file)"
}

# mc_dv_spawn <project> <slug> <merge-sha> <build-dir>
#   rc 0 spawned | rc 1 setup failed. No parallel cap: a verifier is a poll, not
#   a build, and capping it would mean a merged sha nobody is watching.
mc_dv_spawn() {
  local project="$1" slug="$2" sha="$3" build="$4" jf out pid
  # ON A LANE-RUN MACHINE (MC_ON_MACHINE=1, bin/merge-conductor-pr.sh) the
  # deploy-verify job would outlive the run and its result file would never reach
  # the hub. No caller reaches this on a machine: conductor_settle, the only
  # caller, defers first (deferred=settle). If one does, rc 3 is a refusal and
  # no job file is written (deferred=dv).
  if [ "${MC_ON_MACHINE:-}" = 1 ]; then
    [ -n "${MC_PR_DEFERRED_FILE:-}" ] && echo dv >> "$MC_PR_DEFERRED_FILE"
    return 3
  fi
  mkdir -p "$MC_DV_DIR" 2>/dev/null || return 1
  jf=$(mc_dv_file "$project" "$sha"); out="${jf%.json}.out"
  ( flock 9 2>/dev/null
    mc_dv_write "$jf" running 0 "$(mc_now)" 0 - "$project" "$sha" "$build" "$out" || exit 1
  ) 9>>"$MC_DV_DIR/.lock" 2>/dev/null || return 1
  setsid nohup env PATH="$MC_RR_PATH" HARNESS="$MC_H" bash -c \
    '. "$1/bin/lib/merge-conductor-lib.sh"; mc_dv_run "$2" "$3" "$4" "$5" "$6" "$7"' \
    _ "$MC_H" "$project" "$slug" "$sha" "$build" "$jf" "$out" >/dev/null 2>&1 9>&- 8>&- 7>&- &
  pid=$!
  ( flock 9 2>/dev/null
    [ "$(mc_rr_field "$jf" status)" = running ] && mc_dv_write "$jf" running "$pid" \
      "$(mc_rr_field "$jf" started_at)" 0 - "$project" "$sha" "$build" "$out"
  ) 9>>"$MC_DV_DIR/.lock" 2>/dev/null
  return 0
}

# mc_dv_run <project> <slug> <merge-sha> <build-dir> <job-file> <out>
#   MC_DV_INLINE=1 tells bin/deploy-request.sh to run the verifier in the
#   FOREGROUND: the routing (deploy train when the project has a VERSION_URL,
#   verifier when it does not) stays in that one script, and its exit code is
#   what this lane records.
mc_dv_run() {
  local project="$1" slug="$2" sha="$3" build="$4" jf="$5" out="$6" rc started
  # shellcheck source=bin/lib/gh-repo-token.sh
  [ -r "$MC_H/bin/lib/gh-repo-token.sh" ] && . "$MC_H/bin/lib/gh-repo-token.sh"
  type gh_repo_use_token >/dev/null 2>&1 && gh_repo_use_token "$slug" >/dev/null 2>&1
  started=$(mc_rr_field "$jf" started_at); case "$started" in ''|-|null) started=$(mc_now) ;; esac
  MC_DV_INLINE=1 "$MC_H/bin/deploy-request.sh" "$project" "$slug" "$sha" "$build" >> "$out" 2>&1; rc=$?
  ( flock 9 2>/dev/null
    mc_dv_write "$jf" done "$$" "$started" "$(mc_now)" "$rc" "$project" "$sha" "$build" "$out"
  ) 9>>"$MC_DV_DIR/.lock" 2>/dev/null
}

# mc_dv_reap — the ONLY thing a tick does with this lane: read finished jobs,
#   log one line each, and fail the ones that are not coming back. A verifier
#   that vanished is a merged sha nobody is watching, so it gets ONE alert
#   rather than a silent wait (rules/CLAUDE.md: "nothing waits silently").
#   Read once per (project, sha) through the same MC_ATTEMPTS ledger everything
#   else in this file dedupes on.
mc_dv_reap() {
  local f st rc p sha
  [ -d "$MC_DV_DIR" ] || return 0
  for f in "$MC_DV_DIR"/*.json; do
    [ -f "$f" ] || continue
    st=$(mc_dv_state "$f"); p=$(mc_rr_field "$f" project); sha=$(mc_rr_field "$f" sha)
    case "$st" in
      done)
        mc_attempt_has "dvread $p $sha" 2>/dev/null && continue
        mc_attempt_put "dvread $p $sha"
        rc=$(mc_rr_field "$f" rc)
        if [ "$rc" = 0 ]; then mc_log "$p deploy-verify OK for ${sha:0:8} (detached lane)"
        else mc_log "$p deploy-verify FAILED (rc $rc) for ${sha:0:8} — its own ALERTS.log line says what broke; output in $(mc_rr_field "$f" out_file)"; fi ;;
      stale)
        mc_attempt_has "dvstale $p $sha" 2>/dev/null && continue
        mc_attempt_put "dvstale $p $sha"
        mc_dv_fail "$f"
        mc_log "$p deploy-verify for ${sha:0:8} never came back (past ${MC_DV_TIMEOUT_SECS:-2400}s) — failed"
        mc_alert "$p ${sha:0:8}" DEPLOY_VERIFY "the detached deploy verifier for ${sha:0:8} never finished, so NOTHING checked that production took this merge — read $(mc_rr_field "$f" out_file) and verify prod by hand" ;;
    esac
  done
  mc_lane_gc "$MC_DV_DIR"
  return 0
}

# --- THE MERGE FUNNEL (W2-D, 2026-09-14, the operator: "every throughput ceiling is a
# --- bug") --------------------------------------------------------------------
# THE CEILING. Every merge to main marks every other open PR on the repo
# DIRTY-or-stale, and today that costs two things per sibling PR: a REBASE (a
# clone, a merge, a typecheck, a push — minutes, and it MOVES THE HEAD) and,
# because the head moved, a RE-REVIEW (a Fable call, unless the patch-id rebind
# above catches it). At the 4000 PRs/day this fleet is being built for, one
# merge into one main is therefore a rebase storm plus a review storm, and both
# of them are paid on PRs that do not conflict with what landed and do not
# touch a line of it. The two functions below are the two tests that say so.
#
# BOTH ARE READ-ONLY AND LOCAL. Nothing here pushes, comments or merges; each
# one only ever answers "is today's expensive path actually needed for this
# PR", and every failure to answer returns "yes, take today's path".
#
# KILL FLAGS: MC_MERGE_TREE=0 and MC_OVERLAP_REREVIEW=0. With each set to 0 its
# caller in bin/merge-conductor.sh never runs, so the tick does byte-for-byte
# what it did before this change.
MC_MERGE_TREE="${MC_MERGE_TREE:-1}"            # 0 = rebase every DIRTY PR, as before 2026-09-14
MC_MERGE_TREE_MAX="${MC_MERGE_TREE_MAX:-3}"    # clean merge-tree answers a head may spend before the rebase runs anyway
MC_MERGE_TREE_FETCH_SECS="${MC_MERGE_TREE_FETCH_SECS:-60}" # wall-clock cap on EACH fetch the merge-tree test makes
MC_MERGE_TREE_SECS="${MC_MERGE_TREE_SECS:-60}" # wall-clock cap on the merge-tree call itself (a partial clone fetches blobs lazily inside it)
MC_OVERLAP_REREVIEW="${MC_OVERLAP_REREVIEW:-1}" # 0 = re-review every moved head the patch-id rebind missed
MC_FILES_DIR="$MC_STATE_DIR/pr-files"          # cached REST /pulls/{n}/files per (PR, head)

# mc_funnel_repo <owner/repo> <project> — SETS MC_FUNNEL_WT to a checkout of the
#   repo that is fetched and authed, rc 1 when none can be had.
#   It SETS a global rather than printing one for the same reason mc_git_auth
#   does: `wt=$(mc_funnel_repo …)` runs in a subshell and the GIT_ASKPASS export
#   that is the whole point of the auth would be lost there.
#   It is the clone-or-hub-checkout chooser mc_patch_id and mc_rebase each make
#   for themselves. Those two are LIVE and this change has no business rewriting
#   them, so this is a third copy rather than a refactor of theirs — ten lines
#   against a lane that reviews and merges the fleet's PRs is the cheap side of
#   that trade.
MC_FUNNEL_WT=""
mc_funnel_repo() {
  local slug="$1" project="$2" repo
  MC_FUNNEL_WT=""
  mc_git_auth "$slug" || { mc_git_auth_clear; return 1; }
  repo="${MC_REPOS:-/root/repos}/$project"
  if [ -d "$repo/.git" ]; then
    git -C "$repo" remote set-url origin "$MC_REMOTE" >/dev/null 2>&1 || true
    MC_FUNNEL_WT="$repo"; return 0
  fi
  repo="$MC_H/tmp/conductor/${slug//\//_}"; mkdir -p "$(dirname "$repo")"
  if [ ! -d "$repo/.git" ]; then
    git -c credential.helper= clone -q --filter=blob:none "$MC_REMOTE" "$repo" >/dev/null 2>&1 || { mc_git_auth_clear; return 1; }
  else
    git -C "$repo" remote set-url origin "$MC_REMOTE" >/dev/null 2>&1 || true
  fi
  MC_FUNNEL_WT="$repo"; return 0
}

# mc_git_has_merge_tree — rc 0 when this box's git understands
#   `merge-tree --write-tree`, which is git 2.38 and newer. An older git is not
#   an error and not an alert: the caller falls back to today's rebase path,
#   which is what every box did before this change.
mc_git_has_merge_tree() {
  local v maj min
  v=$(git --version 2>/dev/null | awk '{print $3}')
  maj=${v%%.*}; min=${v#*.}; min=${min%%.*}
  case "${maj:-}${min:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$maj" -gt 2 ] && return 0
  [ "$maj" -eq 2 ] && [ "$min" -ge 38 ]
}

# mc_git_bounded <seconds> <command...> — run one git command under a wall
#   clock cap, so a remote that hangs costs this PR its tick and never the
#   conductor's. rc is the command's own; rc 124 is the timeout's, and every
#   caller here reads that as "could not tell", never as an answer. A box
#   without coreutils' `timeout` runs the command unbounded, exactly as before.
mc_git_bounded() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout -k 5 "$secs" "$@"; else "$@"; fi
}

# mc_git_err_line <text> — a git error squeezed onto one log-safe line. The
#   remote url in git's messages carries a username and no secret (see
#   mc_git_auth), but a token-shaped string is redacted anyway: rule 3 of this
#   fleet is that no log line can leak one, and "anyway" is how that stays true.
mc_git_err_line() {
  printf '%s' "$(printf '%s' "$1" | tr '\n' ' ' | sed 's/gh[pousr]_[A-Za-z0-9_]\{8,\}/REDACTED/g; s/  */ /g; s/^ //; s/ $//' | cut -c1-160)"
}

# mc_rebase_reason <url> <mark> — the text of the newest `<url> rebase: <text>`
#   line in $MC_LOG after line <mark>, through mc_git_err_line. rc 1 and no
#   output when there is none: no log, a bad mark, only older lines, another
#   PR's lines, a restack line. The match is the fixed string " <url> rebase: ",
#   so pull/9 never reads pull/19 or pull/92. The resolver's rc-4 alert names
#   this text instead of guessing "clone or credential" (BH-8003).
mc_rebase_reason() {
  local url="$1" mark="$2" l
  case "$mark" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$url" ] && [ -r "${MC_LOG:-}" ] || return 1
  l=$(tail -n +"$((mark + 1))" "$MC_LOG" 2>/dev/null | grep -F -- " $url rebase: " | tail -n 1)
  [ -n "$l" ] || return 1
  l=${l#*" $url rebase: "}
  l=$(mc_git_err_line "$(printf '%s' "$l" | sed 's/github_pat_[A-Za-z0-9_]*/<redacted>/g')")
  [ -n "$l" ] || return 1
  printf '%s' "$l"
}

# mc_git_fail_line <stderr> — the line of git's stderr that says WHY, through
#   mc_git_err_line. The LAST line starting `fatal:` or `error:`, else the last
#   non-empty line, else `(no stderr)`. Not `head -1`: git prints progress first
#   (`Preparing worktree (detached HEAD …)`), and on 2026-10-04 that progress
#   line was the only reason a full /tmp ever logged (BH-4464).
mc_git_fail_line() {
  local l
  l=$(printf '%s\n' "$1" | grep -E '^(fatal|error):' | tail -n 1)
  [ -n "$l" ] || l=$(printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | tail -n 1)
  mc_git_err_line "${l:-(no stderr)}"
}

# mc_tmp_room <url> <lane> — rc 0 when ${TMPDIR:-/tmp} has at least
#   MC_TMP_MIN_FREE_MB (default 256; empty or non-integer -> 256; 0 = off) free.
#   rc 1, after one `tmp full` log line, when it has less. A df that fails or
#   prints no number is rc 0 with no log: an unreadable probe must not stop
#   every rebase (the bin/lib/disk-guard.sh doctrine). BH-4464: a full hub /tmp
#   made every rebase an rc 4 that said nothing about space.
mc_tmp_room() {
  local url="$1" lane="$2" dir="${TMPDIR:-/tmp}" min="${MC_TMP_MIN_FREE_MB:-256}" kb
  case "$min" in ''|*[!0-9]*) min=256 ;; esac
  [ "$min" -gt 0 ] || return 0
  kb=$(df -Pk "$dir" 2>/dev/null | awk 'NR==2 {print $4}') || return 0
  case "$kb" in ''|*[!0-9]*) return 0 ;; esac
  [ "$kb" -lt $((min * 1024)) ] || return 0
  mc_log "$url $lane: tmp full ($((kb / 1024)) MB free on $dir, need $min MB) — rc 8, nothing fetched"
  return 1
}

# mc_merge_tree_fetch <checkout> <remote-url> <head-sha> [pr-number]
#   BRING BOTH SIDES OF THE MERGE INTO THE CLONE, and nothing else. rc 0 means
#   origin/main is current AND the head is a local commit object — the two
#   things merge-tree needs. rc 1 prints a one-line reason naming which half
#   could not be had.
#
#   WHY IT IS ITS OWN STEP (2026-09-16). mc_merge_tree used to fold the fetch
#   into `git fetch -q origin main <sha>` whose failure was indistinguishable
#   from an old git and from merge-tree's own refusal: all three answered rc 2
#   and logged one "could not be computed" line — 177 of them on 2026-09-16
#   alone — and every one of them bought the rebase (a lease, a re-review, a
#   moved head) that this whole test exists to avoid. Splitting the step gives
#   each cause its own rc, and gives the fetch the two things it lacked:
#     * THE EXPLICIT MAIN REFSPEC. `fetch origin main` updates
#       refs/remotes/origin/main only through the remote's CONFIGURED refspec.
#       A clone narrowed to something else (single-branch, a hand-set refspec,
#       a mirror built for one branch) fetches main into FETCH_HEAD and leaves
#       origin/main where it was — and merge-tree then answers truthfully about
#       a main that is days old, which is a wrong answer, not a missing one.
#     * THE refs/pull/<n>/head FALLBACK. A remote need not serve an arbitrary
#       sha: `uploadpack.allowAnySHA1InWant` is off by default, and a fork's
#       head is not the tip of any branch of the base repo. The PR ref is the
#       one name that always exists for an open PR, so it is tried second.
#
#   IT FETCHES FROM THE URL, NOT FROM THE REMOTE NAME. The checkout is shared:
#   mc_rebase, mc_patch_id and mc_no_overlap all point its `origin` at their own
#   authed url and clear the credential again when they are done, and a fetch
#   that says `origin` reads whatever url the other worker last wrote. Naming
#   the url this call authed with takes that race off the table for this test;
#   the refspec still writes refs/remotes/origin/main, so origin/main is the
#   same ref the merge-tree call below reads.
#
#   NO --depth HERE, deliberately. A shallow fetch would graft a shallow
#   boundary onto clones the rest of the conductor shares (mc_no_overlap's two
#   merge-bases read the same checkout), and merge-tree needs the MERGE BASE:
#   a depth-1 head has no ancestry to find one in, so the cheaper fetch would
#   buy a wrong answer. The bound is a timeout, not a truncation.
mc_merge_tree_fetch() {
  local wt="$1" remote="$2" head="$3" num="${4:-}" main='+refs/heads/main:refs/remotes/origin/main' err both
  # The happy path is ONE round trip: both refspecs in one fetch.
  both=$(mc_merge_tree_fetch_one "$wt" "$remote" "$main" "$head" 2>&1) && return 0
  # It failed. Ask the halves separately so the reason names the broken one.
  if ! err=$(mc_merge_tree_fetch_one "$wt" "$remote" "$main" 2>&1); then
    printf 'origin/main could not be fetched (%s)' "$(mc_git_err_line "$err")"; return 1
  fi
  git -C "$wt" cat-file -e "${head}^{commit}" 2>/dev/null && return 0
  if [ -n "$num" ] && [ "$num" != "-" ] \
     && mc_merge_tree_fetch_one "$wt" "$remote" "+refs/pull/$num/head:refs/mc/pull/$num" >/dev/null 2>&1 \
     && git -C "$wt" cat-file -e "${head}^{commit}" 2>/dev/null; then
    return 0
  fi
  printf 'origin/main is current but the head is not in the clone: neither the sha nor refs/pull/%s/head brought it (%s)' \
    "${num:--}" "$(mc_git_err_line "$both")"
  return 1
}
# One authed, quiet, tagless fetch of the given refspecs, bounded.
mc_merge_tree_fetch_one() {
  local wt="$1" remote="$2"; shift 2
  mc_git_bounded "${MC_MERGE_TREE_FETCH_SECS:-60}" git -C "$wt" -c credential.helper= fetch -q --no-tags "$remote" "$@"
}

# mc_merge_tree <owner/repo> <project> <head-sha> [pr-number]
#   THE CONFLICT TEST THAT IS NOT A REBASE. `git merge-tree --write-tree
#   origin/main <head>` performs the merge in the object store and writes NO
#   ref, NO working tree and NO commit: it answers "would these two conflict"
#   in one local operation, on a head it does not touch. GitHub's own merge
#   commit — the thing CI and Mergify actually test — is that same merge, so a
#   clean answer here means the rebase would have bought nothing but a moved
#   head and the re-review the move costs.
#
#   IT ASKS GIT ABOUT TWO COMMITS, SO IT FETCHES THEM FIRST (2026-09-16). The
#   head of a PR is not in the conductor's clone until something puts it there,
#   and origin/main is only as fresh as the last fetch; mc_merge_tree_fetch
#   above is that step, and merge-tree runs only after it says yes.
#
#   rc 0 clean
#   rc 1 conflict — stdout: the conflicted paths
#   rc 2 this box's git has no `merge-tree --write-tree` (older than 2.38)
#   rc 3 the two sides could not be brought into the clone — stdout: why (no
#        token for the remote, origin/main unfetchable, a head that neither the
#        sha nor refs/pull/<n>/head served, a fetch that timed out)
#   rc 4 merge-tree itself could not tell — stdout: its rc and first line
#   Every rc but 0 and 1 means the same thing to the caller, "take today's
#   rebase path"; they are separate ONLY so the log names the cause, because a
#   fetch that has been failing for a day must not read as an old git.
#
#   KNOBS: MC_MERGE_TREE=0 skips the test entirely (the caller rebases every
#   DIRTY PR, as before 2026-09-14); MC_MERGE_TREE_MAX caps how many clean
#   answers a head may spend before the rebase runs anyway;
#   MC_MERGE_TREE_FETCH_SECS bounds each fetch and MC_MERGE_TREE_SECS the
#   merge-tree call (a blob:none clone fetches blobs lazily inside it).
mc_merge_tree() {
  local slug="$1" project="$2" head="$3" num="${4:-}" wt out rc why errf
  [ -n "$head" ] && [ "$head" != "-" ] || { printf 'no head sha to test'; return 3; }
  mc_git_has_merge_tree || return 2
  mc_funnel_repo "$slug" "$project" || {
    mc_git_auth_clear
    printf 'no checkout of %s could be authed (see the git credential line above)' "$slug"; return 3; }
  wt="$MC_FUNNEL_WT"
  if ! why=$(mc_merge_tree_fetch "$wt" "$MC_REMOTE" "$head" "$num"); then
    mc_git_auth_clear; printf '%s' "$why"; return 3
  fi
  # stderr goes to a file, not into `out`: rc 1's stdout is parsed for the
  # conflicted paths and a warning mixed into it would be read as one.
  errf=$(mktemp "${TMPDIR:-/tmp}/mc-mtree-XXXXXX" 2>/dev/null) || errf=/dev/null
  out=$(mc_git_bounded "${MC_MERGE_TREE_SECS:-60}" git -C "$wt" merge-tree --write-tree --name-only origin/main "$head" 2>"$errf"); rc=$?
  mc_git_auth_clear
  case "$rc" in
    0) [ "$errf" = /dev/null ] || rm -f "$errf"; return 0 ;;
    # rc 1 is git's documented "the merge conflicted"; the informational block
    # after the blank line names the paths, which is what the log line wants.
    1) [ "$errf" = /dev/null ] || rm -f "$errf"
       printf '%s' "$(printf '%s\n' "$out" | awk 'f{print} /^$/{f=1}' | tr '\n' ' ' | cut -c1-200)"; return 1 ;;
    *) why=$(mc_git_err_line "$(head -c 400 "$errf" 2>/dev/null)"); [ "$errf" = /dev/null ] || rm -f "$errf"
       printf 'git merge-tree rc %s%s' "$rc" "${why:+: $why}"; return 4 ;;
  esac
}

# --- THE PARENT THAT CLOSED WITHOUT MERGING (2026-09-16) ---------------------
# The block above retargets a stacked child when its parent MERGES. The other
# ending had no event at all: on 2026-09-16 09:35Z bin/blocked-resolver.sh gave
# up on project-5 TK-1529 and CLOSED #1556 to rebuild the ticket fresh, and the
# three children cut from ticket/TK-1529 (#1586, #1585, #1587) were left based
# on a branch nothing would ever merge. The conductor parked them
# `parent-closed`, which is a word no lane owns, and they sat there.
#
# A closed parent has exactly two shapes, and only a LOOK AT THE BRANCH tells
# them apart:
#   a) the child's own commits sit on the base already — the parent's work was
#      never in this branch, or it landed some other way. Nothing is lost by
#      pointing the PR at the base: that is a one-call PATCH, and the child
#      keeps its CI and its number. Its review is re-bought (BH-3950): see
#      MC_RETARGET_REREVIEW below.
#   b) the child was really cut from the parent's commits and still carries
#      them. Retargeting THAT opens the abandoned parent's diff against main
#      under the child's number, which is worse than the park. It needs the
#      branch moved, which is an agent's job, so it goes to
#      bin/blocked-resolver.sh as a fix round on the existing branch.
#
# NOTHING HERE CLOSES ANYTHING, and nothing here is on a timer (the operator,
# 2026-09-16: "we shouldn't have rules that kill PRs because of time; it should
# be event based"). The event is the PARENT's close; the answer is a retarget or
# a hand-off; a tick that cannot read the branch says so and re-reads next tick.
#
# KILL FLAG: MC_ORPHAN_RETARGET=0 restores the 2026-09-14 behaviour byte for
# byte — every child of a closed parent parks `parent-closed` and stays there.
MC_ORPHAN_RETARGET="${MC_ORPHAN_RETARGET:-1}"

# A RETARGET OFF A CLOSED OR ABSENT PARENT OWES A RE-REVIEW (BH-3950). The
# review the child carries was of its diff against the parent's branch; on the
# project base that diff can hold commits no reviewer read. MC_RETARGET_REREVIEW
# resolves through lib_env_apply mc-stack-orphan (catalog/lanes.d/
# _lib.mc-stack-orphan.json): row > cached row > env > registry default, in a
# subshell for queue.sh's reasons (a fail-closed exit 75 never stops the lane).
# Code default 1; 0 restores "keeps its review" without a revert.
_MCSO_V=$(
  exec 3>&1
  _MCSO_R=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null && pwd) || exit 0
  command -v lib_env_apply >/dev/null 2>&1 || . "$_MCSO_R/bin/lib/lane-gate.sh" >/dev/null 2>&1 || exit 0
  if [ -z "${LANE_REGISTRY:-}" ] && [ ! -r "$(_lg_registry)" ] && . "$_MCSO_R/bin/lib/lanes-registry.sh" >/dev/null 2>&1; then
    LANE_REGISTRY=$(lanes_json_path "$_MCSO_R" 2>/dev/null) && export LANE_REGISTRY
  fi
  trap 'printf "%s" "${MC_RETARGET_REREVIEW:-}" >&3' EXIT
  lib_env_apply mc-stack-orphan >/dev/null 2>&1)
[ -n "$_MCSO_V" ] && MC_RETARGET_REREVIEW="$_MCSO_V"
unset _MCSO_V
case "${MC_RETARGET_REREVIEW-}" in 0) MC_RETARGET_REREVIEW=0 ;; *) MC_RETARGET_REREVIEW=1 ;; esac

# mc_ref_ok <ref> — rc 0 when this name is safe to hand to git. The same
#   character class mc_project_base allows, plus a refusal of anything starting
#   with `-`, which git would read as an option. Branch names arrive here from
#   GitHub's baseRefName, so this is belt and braces — but the one place a repo
#   name reached a git command unchecked is the one that would matter.
mc_ref_ok() {
  case "${1:-}" in ''|-*|*[!A-Za-z0-9._/-]*) return 1 ;; esac
  return 0
}

# stack_orphan_retarget <retargeted-phrase> <kick-failed-prefix> <refused-line>
#   The CLOSED-no-rebuild arm's retarget, shared with the NONE arm (BH-3950).
#   It lives here, not in bin/merge-conductor.sh (tests/mc/driver-complete-test.sh
#   pins the driver to its kept five); it is still only ever called from pr_worker:
#   PATCH the base to PBASE, then the CI kick on a head with no runs, then the
#   log line. rc 1 = the PATCH was refused; <refused-line> is logged and nothing
#   else changes. On rc 0 a retarget off a parent that never merged OWES a
#   head-bound re-review (rtreview <key> <head>, written after the PATCH and
#   before the kick); MC_RETARGET_REREVIEW=0 turns that off. Reads and sets
#   pr_worker's own variables (KEY SLUG NUM PBASE CI HEAD; MC_STACK*, BASEREF).
stack_orphan_retarget() {
  mc_retarget_base "$SLUG" "$NUM" "$PBASE" || { mc_log "$3"; return 1; }
  if [ "$MC_RETARGET_REREVIEW" != 0 ]; then
    # A read of this head that already exists judged it against the dead
    # parent, and the detached review is one per (PR, head): it cannot be
    # bought again here. Recorded so the gate holds the row, never lets it pass.
    if [ -f "$(mc_rr_file "$SLUG" "$NUM" "$HEAD")" ] || mc_attempt_has "rereviewdone $KEY $HEAD" 2>/dev/null; then
      mc_attempt_has "rtpreread $KEY $HEAD" 2>/dev/null || mc_attempt_put "rtpreread $KEY $HEAD"
    fi
    mc_attempt_has "rtreview $KEY $HEAD" 2>/dev/null || mc_attempt_put "rtreview $KEY $HEAD"
    mc_log "$KEY retargeted off closed parent - re-review owed on ${HEAD:0:8}"
    MC_RT_THIS_TICK=1
  fi
  # The same CI kick the MERGED arm buys, for the same reason and under the
  # same condition: a base change is an `edited` event, which fires no
  # `pull_request` workflow, so a head with no runs would wait for a required
  # check that is never coming. A head that already has runs is left alone —
  # closing it would cancel them.
  if [ "$CI" != none ]; then
    mc_log "$1; CI is already $CI on ${HEAD:0:8}, so no kick (a close/reopen would cancel it)"
  elif mc_kick_ci "$SLUG" "$NUM" "$HEAD"; then
    mc_attempt_has "cikick $KEY $HEAD" 2>/dev/null || mc_attempt_put "cikick $KEY $HEAD"
    mc_log "$1 and CI kicked (close/reopen); it classifies normally from here"
  else
    mc_log "$2 — retargeted to $PBASE; the CI kick FAILED and the retarget stands — the generic kick retries on a later tick"
  fi
  MC_STACK=""; MC_STACK_BASE=""
  BASEREF="$PBASE"   # stale list base, after the lines that name the old one (BH-410)
  return 0
}

# mc_orphan_clean <owner/repo> <project> <base> <parent-branch> <head-sha>
#   May this child of a CLOSED parent be retargeted to <base> as it stands?
#   rc 0 yes | 1 no, hand it to the resolver | 2 this tick could not tell.
#   stdout: one short evidence phrase in every case, for the log line — a
#   verdict whose reason is not written down is a verdict nobody can argue with.
#
#   THE TWO HALVES, and both must hold for rc 0:
#     carries  the commits this head has beyond <base>, intersected with the
#              commits the PARENT branch has beyond <base>, must be EMPTY. That
#              is the `rebase --onto <base> <parent-branch>` question asked as a
#              set difference: a rebase that would drop commits is a branch that
#              is carrying them, and a PATCH of the base ref drops nothing.
#     conflict `merge-tree --write-tree` against <base> must come back clean —
#              the same local, ref-free, worktree-free conflict test the merge
#              funnel above uses, for the same reason.
#   Read-only: no ref is written, no branch is pushed, nothing is commented.
#   Every unknown is rc 2 and every rc 2 leaves the PR exactly where it was.
#
#   [carry] (BH-3950, default 1): 0 skips the carries half, for a parent branch
#   that is gone AND never had a PR. There is no ref left to intersect against
#   and nothing on it will ever merge, so whatever this head carries can only
#   land through this PR; the conflict half alone decides, and the re-review the
#   retarget owes reads the whole diff against <base>. Every five-argument
#   caller gets exactly the behaviour above.
mc_orphan_clean() {
  local slug="$1" project="$2" base="$3" parent="$4" head="$5" carry="${6:-1}"
  local wt carried out rc
  [ -n "$head" ] && [ "$head" != "-" ] || { printf 'no head sha to read'; return 2; }
  mc_ref_ok "$base" && mc_ref_ok "$parent" || { printf 'unsafe branch name, refused before it reached git'; return 2; }
  [ "$parent" = "$base" ] && { printf 'the parent branch IS the base'; return 2; }
  mc_funnel_repo "$slug" "$project" || { printf 'no authed checkout of %s on this box' "$slug"; return 2; }
  wt="$MC_FUNNEL_WT"
  git -C "$wt" -c credential.helper= fetch -q origin "+refs/heads/$base:refs/remotes/origin/$base" >/dev/null 2>&1 \
    || { mc_git_auth_clear; printf 'could not fetch %s' "$base"; return 2; }
  git -C "$wt" -c credential.helper= fetch -q origin "$head" >/dev/null 2>&1 \
    || { mc_git_auth_clear; printf 'origin no longer has %s' "${head:0:8}"; return 2; }
  # A PARENT BRANCH THAT IS GONE IS A HAND-OFF, NOT A WAIT. Deleting it is what
  # GitHub does when someone tidies up after the close, and it takes the only
  # witness to "what of the parent is still in this branch" with it. Waiting for
  # a branch that will never come back is the silent wait this whole change is
  # against, so it goes to the resolver with that said out loud.
  if [ "$carry" != 0 ]; then
  if ! git -C "$wt" -c credential.helper= fetch -q origin "+refs/heads/$parent:refs/remotes/origin/$parent" >/dev/null 2>&1; then
    mc_git_auth_clear
    printf 'the parent branch %s is gone from origin, so what this head still carries of it cannot be read' "$parent"
    return 1
  fi
  carried=$(comm -12 \
    <(git -C "$wt" rev-list "$head" --not "refs/remotes/origin/$base" 2>/dev/null | sort) \
    <(git -C "$wt" rev-list "refs/remotes/origin/$parent" --not "refs/remotes/origin/$base" 2>/dev/null | sort) \
    2>/dev/null | grep -c . || true)
  case "$carried" in ''|*[!0-9]*) mc_git_auth_clear; printf 'could not list this branch against %s' "$parent"; return 2 ;; esac
  if [ "$carried" -gt 0 ]; then
    mc_git_auth_clear
    printf 'the head still carries %s commit(s) of the closed parent %s — a retarget would open them against %s under this PR number' "$carried" "$parent" "$base"
    return 1
  fi
  fi
  mc_git_has_merge_tree || { mc_git_auth_clear; printf 'git is older than 2.38, so the conflict half cannot be answered here'; return 2; }
  out=$(git -C "$wt" merge-tree --write-tree --name-only "refs/remotes/origin/$base" "$head" 2>/dev/null); rc=$?
  mc_git_auth_clear
  case "$rc" in
    0) if [ "$carry" = 0 ]; then printf 'the parent branch %s is gone and never had a PR; it merges into %s cleanly' "$parent" "$base"
       else printf 'it carries no commit of %s and merges into %s cleanly' "$parent" "$base"; fi
       return 0 ;;
    1) printf 'it conflicts with %s in %s' "$base" "$(printf '%s\n' "$out" | awk 'f{print} /^$/{f=1}' | tr '\n' ' ' | cut -c1-120)"; return 1 ;;
    *) printf 'merge-tree could not answer against %s' "$base"; return 2 ;;
  esac
}

# mc_pr_files <owner/repo> <num> <pr-url> <head-sha>
#   The paths this PR changes, one per line, CACHED per (PR, head) under
#   state/ — a head's file list cannot change without the head changing, and at
#   4000 PRs a day the same list would otherwise be bought from the API on every
#   five-minute tick. rc 1 when GitHub gave us nothing, which the caller reads as
#   "cannot judge".
#   READ OVER REST, AND ONLY OVER REST (BH-587 review). `gh pr view --json
#   files` is GraphQL, and the GraphQL bucket is the one that dies first on
#   these accounts — bin/blocked-resolver.sh's contested scan buys one list per
#   open PR (up to CONTESTED_PR_SCAN_MAX = 40) for a single hold, so a busy repo
#   would exhaust it and the feature would stop firing exactly when it is
#   needed. REST pages the same list at repos/<slug>/pulls/<num>/files.
#
#   NO GraphQL FALLBACK (review round 1). The first cut kept `gh pr view --json
#   files` for "the one case REST cannot answer from", but it fired on any empty
#   stdout and stderr is discarded — so a REST OUTAGE, not an empty PR, bought
#   up to 40 GraphQL reads per hold creation, out of exactly the bucket this
#   change exists to protect. The decision is the same either way: an empty file
#   list is rc 1, "cannot judge", and parks nobody. So the answer is rc 1, and
#   nothing is spent getting there.
mc_pr_files() {
  local slug="$1" num="$2" url="$3" head="$4" f
  [ -n "$head" ] && [ "$head" != "-" ] || return 1
  mkdir -p "$MC_FILES_DIR" 2>/dev/null
  f="$MC_FILES_DIR/${slug//\//_}_${num}_${head}"
  if [ ! -s "$f" ]; then
    # Paginated, because /pulls/{n}/files is 100 a page and a truncated list
    # read as complete is a wrong answer about which files a PR touches.
    mc_rest_pages "repos/$slug/pulls/$num/files" 2>/dev/null \
      | jq -r '.[].filename // empty' 2>/dev/null | sed '/^$/d' | sort -u > "$f.tmp" 2>/dev/null
    [ -s "$f.tmp" ] || { rm -f "$f.tmp"; return 1; }
    mv -f "$f.tmp" "$f"
  fi
  cat "$f"
}

# mc_pr_files_gc — cached file lists older than three days. The same three-day
#   rule mc_lane_gc uses, and for the same reason: the head it is keyed on is
#   long gone.
mc_pr_files_gc() {
  [ -d "$MC_FILES_DIR" ] || return 0
  find "$MC_FILES_DIR" -maxdepth 1 -type f -mtime +3 -delete 2>/dev/null
  return 0
}

# mc_no_overlap <owner/repo> <project> <num> <pr-url> <reviewed-sha> <head-sha>
#   CHANGE 2. The head moved and the patch-id rebind above did NOT catch it —
#   so something really did change between the approved sha and the head. This
#   asks the one question that can still save the re-review: did it change
#   anything this PR is about?
#
#   THE THREE CONDITIONS, all of which must hold:
#     a) the MERGE BASE moved. B1 = merge-base(origin/main, reviewed),
#        B2 = merge-base(origin/main, head). B1 == B2 means the head did not
#        move because main did, and this test has nothing to say about it.
#     b) every file that differs between the reviewed sha and the head is a file
#        MAIN changed between B1 and B2. That is what makes "a merge landed
#        underneath me" true and "somebody pushed a commit" false — a new commit
#        touches something main did not, and falls out here.
#     c) the PR's OWN file list (mc_pr_files, at the new head) is disjoint from
#        the files main changed. Nothing that landed is anywhere near the diff
#        a reviewer approved.
#
#   WHY THE MAIN-SIDE LIST IS COMPUTED FROM GIT AND NOT FROM `gh pr view --json
#   files` OF THE MERGED PR. Merges into main arrive from four places — this
#   conductor, the hub's merge sweep, a Mergify batch, and the operator from the console
#   — and a bookkeeping table of "what we merged" would be missing exactly the
#   ones we did not make. Two merge-bases and a diff is the same question asked
#   of the only witness that sees every merge, so a merge nobody recorded can
#   never be mistaken for no merge at all.
#
#   Prints "<n> file(s) landed under it: <sample>" and rc 0 when the approval
#   may be rebound. rc 1 on ANY doubt — an unreadable file list, a sha the
#   remote no longer has, a base that did not move — and the caller then buys
#   today's detached re-review, unchanged.
mc_no_overlap() {
  local slug="$1" project="$2" num="$3" url="$4" rev="$5" head="$6"
  local wt b1 b2 mainf movedf prf hit n
  [ -n "$rev" ] && [ "$rev" != "-" ] && [ -n "$head" ] && [ "$head" != "-" ] || return 1
  mc_funnel_repo "$slug" "$project" || return 1
  wt="$MC_FUNNEL_WT"
  git -C "$wt" -c credential.helper= fetch -q origin main "$rev" "$head" >/dev/null 2>&1 || { mc_git_auth_clear; return 1; }
  b1=$(git -C "$wt" merge-base origin/main "$rev" 2>/dev/null)
  b2=$(git -C "$wt" merge-base origin/main "$head" 2>/dev/null)
  if [ -z "$b1" ] || [ -z "$b2" ] || [ "$b1" = "$b2" ]; then mc_git_auth_clear; return 1; fi
  mainf=$(git -C "$wt" diff --name-only "$b1" "$b2" 2>/dev/null | sed '/^$/d' | sort -u)
  movedf=$(git -C "$wt" diff --name-only "$rev" "$head" 2>/dev/null | sed '/^$/d' | sort -u)
  mc_git_auth_clear
  [ -n "$mainf" ] || return 1
  # (b) — anything the head move touched that main did NOT is a real edit.
  hit=$(printf '%s\n' "$movedf" | grep -vxF -f <(printf '%s\n' "$mainf") | head -1)
  [ -z "$hit" ] || return 1
  # (c) — the PR's own files against main's.
  prf=$(mc_pr_files "$slug" "$num" "$url" "$head") || return 1
  [ -n "$prf" ] || return 1
  hit=$(printf '%s\n' "$prf" | grep -xF -f <(printf '%s\n' "$mainf") | head -1)
  [ -z "$hit" ] || return 1
  n=$(printf '%s\n' "$mainf" | grep -c . || true)
  printf '%s file(s) landed under it: %s' "$n" "$(head -4 <<<"$mainf" | paste -sd, -)"
  return 0
}

# rebind_no_overlap — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# rebind_no_overlap <key> <project> <slug> <num> <url> <record> <reviewed> <head>
#   CHANGE 2 of the merge funnel (W2-D, 2026-09-14). The head moved, the patch
#   changed, and NOTHING that changed is anywhere near this PR: mc_no_overlap
#   proved that the only thing between the approved sha and the head is a merge
#   of main, and that main's files and this PR's files are disjoint sets. That
#   is the same principle as the patch-id rebind next door — an approval binds
#   to CODE, and no code a reviewer read has moved — so it gets the same answer:
#   the approval is REBOUND and no re-review is bought. rc 0 when it was.
#
#   It runs AFTER rebind_patch_id, never instead of it: patch-id is the stronger
#   and cheaper test (no gh call at all), and this only ever sees the heads it
#   could not vouch for.
rebind_no_overlap() {
  local key="$1" proj="$2" slug="$3" num="$4" url="$5" rec="$6" rev="$7" head="$8" what
  what=$(mc_no_overlap "$slug" "$proj" "$num" "$url" "$rev" "$head") || return 1
  if [ -n "$rec" ] && [ -d "$rec" ]; then
    echo "$head" > "$rec/reviewed-sha"
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') approval rebound $rev -> $head no file overlap with what landed ($what)" >> "$rec/rebind.log"
  fi
  type job_verdict_rebind >/dev/null 2>&1 && job_verdict_rebind "$url" "$head" >/dev/null 2>&1 || true
  mc_log "$key NO_OVERLAP rebound ${rev:0:8} -> ${head:0:8}: $what — none of them is a file this PR touches, approval rebound, no re-review bought"
  # The rebound head carries no lead-verdict status yet (BH-4596, settle.sh).
  mc_rebind_publish "$key" "$proj" "$slug" "$num" "$url" "$head" "$rev" || true
  return 0
}

# rebase_noop_say — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# rebase_noop_say <tag> <key> <head> <why>
#   A NEEDS_REBASE EXIT THAT REBASES NOTHING SAYS SO (BH-764). Two of the arm's
#   exits were a bare `return 0` underneath a line that had just announced a
#   rebase, so the tick summary's `rebases=0` and the log disagreed and neither
#   named a reason. Once per (tag, PR, head), like every other said-once record
#   in this file — and stuck_rekick and mc_handoff_human_release clear these
#   with the attempt itself, so the next cycle speaks again instead of being
#   deduped into permanent silence.
#   mc_count_inc rebases is untouched: it moves on a spawn and only on a spawn,
#   which is what the counter means.
rebase_noop_say() {
  local tag="$1" key="$2" head="$3" why="$4"
  mc_attempted "rebasenoop-$tag" "$key" "$head" && return 0
  mc_log "$key NO_REBASE on ${head:0:8} — $why"
  return 0
}

# merge_tree_clean — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# merge_tree_clean <key> <slug> <project> <head> [num]
#   CHANGE 1 of the merge funnel (W2-D, 2026-09-14). Before spending a rebase on
#   a PR GitHub calls DIRTY, ask git. `git merge-tree --write-tree` merges the
#   head with origin/main in the object store — no ref, no worktree, no commit,
#   no push — and a clean answer means the merge commit GitHub builds for CI and
#   Mergify is a clean one too. Rebasing it anyway would move the head for
#   nothing and buy a re-review with the move.
#   rc 0 = leave the head alone this tick. rc 1 = take today's rebase path.
#
#   IT CANNOT HOLD A PR FOREVER. GitHub's mergeStateStatus is the field the rest
#   of this file steers on, and if it goes on saying DIRTY while git says clean
#   then one of the two is wrong about something we cannot see from here. So the
#   skip is capped at MC_MERGE_TREE_MAX observations per (PR, head) — three
#   ticks, fifteen minutes, well inside NEEDS_REBASE's 30-minute TTL — which
#   alerts and re-kicks the rebase and NEVER closes the PR (docs/MERGE-CONDUCTOR.md,
#   "No time kills, and a setup failure is not an event")
#   — and after that the rebase runs exactly as it does today.
merge_tree_clean() {
  local key="$1" slug="$2" proj="$3" head="$4" num="${5:-}" out rc n
  out=$(mc_merge_tree "$slug" "$proj" "$head" "$num"); rc=$?
  case "$rc" in
    0) ;;
    1) mc_log "$key MERGE_TREE conflict on ${head:0:8} (${out:-paths unavailable}) — GitHub is right, this head needs a rebase"; return 1 ;;
    # THREE CAUSES, THREE LINES (2026-09-16). One "could not be computed" line
    # covered all of them and a fetch that had been failing all day read as a
    # box with an old git: 177 of them on project-5 in a morning, each one a
    # rebase the test was supposed to save. Each cause now says its own name,
    # and all of them still do what they did before — rebase.
    #
    # THE WORD IS "NEEDS A REBASE", NOT "REBASING" (BH-764). rc 1 hands the row
    # to the NEEDS_REBASE arm, and that arm has exits which spawn nothing — a
    # consumed job, a head that already had its one rebase. Promising a rebase
    # here while the tick summary said `rebases=0` is the disagreement between
    # the log and the counter that made those rows look stranded.
    2) mc_log "$key MERGE_TREE unavailable: this box's git ($(git --version 2>/dev/null | awk '{print $3}')) has no merge-tree --write-tree, which needs 2.38 — this head needs a rebase, as before"; return 1 ;;
    3) mc_log "$key MERGE_TREE fetch failed on ${head:0:8}: ${out:-no reason given} — this head needs a rebase, as before"; return 1 ;;
    *) mc_log "$key MERGE_TREE inconclusive on ${head:0:8}: ${out:-git merge-tree rc $rc} — this head needs a rebase, as before"; return 1 ;;
  esac
  mc_attempt_put_n mergetree "$key" "$head"
  n=$(mc_attempt_count mergetree "$key" "$head")
  case "${n:-}" in ''|*[!0-9]*) n=1 ;; esac
  if [ "$n" -ge "${MC_MERGE_TREE_MAX:-3}" ]; then
    mc_log "$key MERGE_TREE clean on ${head:0:8} for the ${n}th tick while GitHub still says DIRTY — trusting GitHub and rebasing"
    return 1
  fi
  mc_log "$key MERGE_TREE clean — ${head:0:8} merges into origin/main with no conflict, so the head is left alone (observation $n of ${MC_MERGE_TREE_MAX:-3}); GitHub's merge commit is what CI and Mergify test"
  return 0
}

# mc_rebase_mig_lane <project> <slug> <num> <key> <head> — BH-8035. Does the
#   migration hold give this PR to an apply lane (bin/lib/migration-hold.sh)?
#     rc 0  yes: MMH_NAMES and MMH_DETAIL name the files and the lane
#     rc 1  no, or the project is not gated (no globs row, no apply_lane row)
#     rc 2  a settings row or the files list could not be read: MMH_DETAIL says which
#   A read that fails is rc 2, never rc 1 (BH-8021 had `lane=""` on a failed
#   read, so an outage spawned the rebase).
#   IT LOADS WHAT IT NEEDS (BH-8035). The BH-8021 check ran only when mmh_decide
#   and setting_get were already defined, and a process without them passed in
#   silence (project-6 #2362 and #2374 at 19:17Z: hold rows set, no LAND_SKIP,
#   no "migration hold:" line). Now a missing mmh_decide sources
#   $MC_H/bin/lib/migration-hold.sh here, and mmh_globs loads setting_get
#   (the jobs client) when this shell has none. A lib or a settings reader that
#   still cannot be loaded is rc 2: the caller defers, never spawns. So is a
#   failed read after the globs row says the project is gated (the apply_lane
#   row, the files list). An unreadable globs row is "not gated this tick",
#   with one log line, as mc_mig_hold reads it.
mc_rebase_mig_lane() {
  local p="$1" lane grc=0 lrc=0 lib="${MC_H:-${HARNESS:-}}/bin/lib/migration-hold.sh"
  if ! command -v mmh_decide >/dev/null 2>&1 || ! command -v mmh_globs >/dev/null 2>&1; then
    # shellcheck source=bin/lib/migration-hold.sh
    [ -r "$lib" ] && . "$lib" >/dev/null 2>&1
  fi
  if ! command -v mmh_decide >/dev/null 2>&1 || ! command -v mmh_globs >/dev/null 2>&1; then
    MMH_DETAIL="the migration hold lib could not be loaded ($lib)"; return 2
  fi
  # The lib's root is HARNESS or H (D43); the conductor's root is MC_H.
  [ -n "${HARNESS:-${H:-}}" ] || local H="${MC_H:-}"
  mmh_globs "$p" >/dev/null 2>&1 || grc=$?
  case "$grc" in
    0) ;;
    2) return 1 ;;
    *) command -v setting_get >/dev/null 2>&1 || { MMH_DETAIL="no settings reader (setting_get) could be loaded"; return 2; }
       # The globs row itself is unreadable: not gated this tick, the same rule
       # the READY hold (mc_mig_hold) applies, and said out loud.
       command -v mc_log >/dev/null 2>&1 && mc_log "${4:-$p} migration hold: $p globs row unreadable this tick (rc $grc); not gated this tick (BH-8035)"
       return 1 ;;
  esac
  command -v setting_get >/dev/null 2>&1 || { MMH_DETAIL="no settings reader (setting_get) could be loaded"; return 2; }
  lane=$(setting_get "mc_migration_hold.apply_lane.$p" 2>/dev/null) || lrc=$?
  case "$lrc" in
    0) ;;
    2) return 1 ;;
    *) MMH_DETAIL="the apply_lane row could not be read (rc $lrc)"; return 2 ;;
  esac
  [ -n "$(printf '%s' "$lane" | tr -d '[:space:]')" ] || return 1
  mmh_decide "$@"
  case "$MMH_VERDICT" in
    lane) return 0 ;;
    unreadable) return 2 ;;
  esac
  return 1
}

# mc_rebase_gate <what> — BH-8035. The one question each conductor rebase
#   spawn asks first: does another lane own this PR? <what> names the spawn
#   (land, eject, needs-rebase) in the log line. It reads pr_worker's row
#   variables (P SLUG NUM KEY HEAD URL RAWLBL PROVIDER), as land_rebase_arm does.
#     rc 0  no other lane holds it: spawn as before
#     rc 1  held: Mergify holds it (mc_mergify_holds, BH-8021), or the migration
#           hold gives it to an apply lane (mc_rebase_mig_lane). One LAND_SKIP
#           line per (PR, head, reason).
#     rc 2  a read failed: spawn nothing this tick. One LAND_DEFER line.
#   MC_RBG_WHY is the reason word: mergify-queue | migration-apply-lane.
#   A push cancels a waiting `@mergifyio queue` request (project-6 #2300) and
#   resets the apply lane's run (project-6 #2305, #2362).
mc_rebase_gate() {
  local what="${1:-rebase}" why rc mark
  MC_RBG_WHY=""
  if [ "${PROVIDER:-}" = mergify ] && command -v mc_mergify_holds >/dev/null 2>&1; then
    why=$(mc_mergify_holds "$SLUG" "$URL" "$HEAD" "${RAWLBL:-}"); rc=$?
    case "$rc" in
      0) MC_RBG_WHY=mergify-queue; mark="rbgate $KEY $HEAD $MC_RBG_WHY"
         mc_attempt_has "$mark" 2>/dev/null \
           || mc_log "$KEY LAND_SKIP mergify-queue: $why on ${HEAD:0:8} — Mergify owns this PR, no $what rebase (BH-8021, BH-8035)"
         mc_attempt_put "$mark"
         return 1 ;;
      2) MC_RBG_WHY=mergify-queue
         mc_log "$KEY LAND_DEFER mergify-queue: the Mergify check runs on ${HEAD:0:8} could not be read — no $what rebase this tick (BH-8021, BH-8035)"
         return 2 ;;
    esac
  fi
  mc_rebase_mig_lane "$P" "$SLUG" "$NUM" "$KEY" "$HEAD"; rc=$?
  case "$rc" in
    0) MC_RBG_WHY=migration-apply-lane; mark="rbgate $KEY $HEAD $MC_RBG_WHY"
       mc_attempt_has "$mark" 2>/dev/null \
         || mc_log "$KEY LAND_SKIP migration-apply-lane: $MMH_NAMES on ${HEAD:0:8} $MMH_DETAIL — no $what rebase (BH-8021, BH-8035)"
       mc_attempt_put "$mark"
       return 1 ;;
    2) MC_RBG_WHY=migration-apply-lane
       mc_log "$KEY LAND_DEFER migration-apply-lane: $MMH_DETAIL on ${HEAD:0:8} — no $what rebase this tick (BH-8021, BH-8035)"
       return 2 ;;
  esac
  return 0
}

# mc_pool_rebase_meta_extra <slug> <project> <num> <head> [provider] — BH-8035.
#   The JSON object a pool rebase row adds to its meta for the machine's push
#   check (bin/lib/rebase-job.sh step 8): `mergify:true` on a Mergify repo, so
#   the machine reads the Mergify hold again just before its push, and `hold`
#   when the migration hold already gives the PR to an apply lane, so the
#   machine pushes nothing (also when the hold cannot be read). [provider] is the tick's PROVIDER: given, nothing
#   is probed (`-` = not known, no flag); empty, mc_queue_provider is asked.
#   Prints {} when neither applies. Never fails.
mc_pool_rebase_meta_extra() {
  local slug="$1" p="$2" num="$3" head="$4" prov="${5:-}" mq=false hold=""
  [ -n "$prov" ] || prov=$(mc_queue_provider "$slug" 2>/dev/null)
  [ "$prov" = mergify ] && mq=true
  # Fail closed (BH-8035): a hold that cannot be read is a hold, so the
  # machine pushes nothing and the next tick asks the gate again.
  mc_rebase_mig_lane "$p" "$slug" "$num" "$slug#$num" "$head" 2>/dev/null
  case "$?" in
    0) hold="migration-apply-lane: $MMH_NAMES $MMH_DETAIL" ;;
    2) hold="migration-apply-lane: unreadable: $MMH_DETAIL" ;;
  esac
  jq -nc --argjson m "$mq" --arg h "$hold" \
    '(if $m then {mergify:true} else {} end) + (if $h == "" then {} else {hold:$h} end)' 2>/dev/null || printf '{}'
}

# land_rebase_arm — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# land_rebase_arm — CHANGE 2 OF THE MERGE FUNNEL (BH-870). merge_tree_clean
#   above is about a PR GitHub has already called DIRTY. This one is about the
#   event that eventually MAKES it dirty: a merge landing on the project's base.
#   Until now nothing acted on that landing, so an open PR stayed on the base it
#   was cut from until it conflicted — and a conflict is the expensive way to
#   learn main moved, because by then the rebase is not mechanical any more and
#   the ticket is on bin/blocked-resolver.sh's ladder.
#
#   It is called once per PR, straight after mc_transition and before the state
#   arms, so it judges THIS tick's state and so a spawn takes the REBASING
#   transition exactly as the NEEDS_REBASE arm's does.
#     rc 0  a rebase was spawned or queued and the row moved to REBASING; the
#           caller returns, the state arms do not run
#     rc 1  nothing was spawned; the state arms run exactly as they do today
#
#   IT READS pr_worker's ROW VARIABLES rather than taking fifteen arguments, the
#   way the `case "$STATE"` arms below do, and it writes only through functions
#   that take their own lock. LAND_SHA and LAND_FIRE come from tick_project, the
#   same way PBASE, SLUG and ACTIONS reach the worker.
#
#   THE IDEMPOTENCY KEY IS (PR, base sha), in MC_ATTEMPTS as
#   `landrebase <key> <sha>`, and it is written AFTER the spawn succeeded —
#   never before. A spawn refused at the cap must be retried on the next tick,
#   and a marker that exists for a job nobody wrote is a PR this lane has
#   silently dropped. Every non-delivery path increments `landdeferred` instead,
#   which is what stops tick_project recording the sha as handled (D12).
#
#   IT DOES NOT TOUCH MC_REBASE_BUDGET. That budget rations the steady-state
#   NEEDS_REBASE spend, and the whole point of this arm is that a landing is not
#   rationed by it. Its ceiling is MC_LAND_REBASE_PARALLEL, passed to
#   mc_rebase_spawn, so a forty-PR fan-out cannot put forty worktrees on the hub.
land_rebase_arm() {
  [ "${MC_LAND_REBASE:-1}" != 0 ] && [ "${LAND_FIRE:-0}" = 1 ] || return 1
  local mark="landrebase $KEY $LAND_SHA" lout lrc
  # This PR already had its answer for THIS sha. Written last, read first.
  mc_attempt_has "$mark" 2>/dev/null && return 1
  # Not based on the branch that moved. A stacked child belongs to the
  # STACKED_WAIT block, and merging the base into it is the one merge this lane
  # must never make.
  if [ -z "$PBASE" ] || [ "${BASEREF:-}" != "$PBASE" ]; then
    mc_count_inc "$P" landskipped >/dev/null; mc_attempt_put "$mark"; return 1
  fi
  # THE STATES THIS LANE MAY MOVE, and nothing else. READY is one merge away and
  # moving its head would cost that merge a whole CI cycle; QUEUED belongs to the
  # queue provider; NEEDS_REBASE/REBASING are the existing rebase path's; the
  # terminals are terminal. The two parks say so out loud, because "nothing
  # happened" and "something decided not to" read the same in a log.
  case "$STATE" in
    WAIT_CI|WAIT_REVIEW|HEAD_MOVED) ;;
    BLOCKED_HUMAN|RED_TWICE)
      mc_count_inc "$P" landskipped >/dev/null; mc_attempt_put "$mark"
      mc_log "$KEY LAND_SKIP parked $(mc_state_display "$STATE" "$WHY") — bin/blocked-resolver.sh owns it, no land rebase"
      return 1 ;;
    *) mc_count_inc "$P" landskipped >/dev/null; mc_attempt_put "$mark"; return 1 ;;
  esac
  # Mergify's terminal label, tested exactly as the re-entry arm below tests it
  # (anchored, so `predequeued` is not `dequeued`).
  if grep -qE '(^|,)dequeued(,|$)' <<<"${RAWLBL:-}"; then
    mc_count_inc "$P" landskipped >/dev/null; mc_attempt_put "$mark"
    mc_log "$KEY LAND_SKIP Mergify dequeued label on ${HEAD:0:8} — a PR nobody queues is not rebased by this lane"
    return 1
  fi
  # ANOTHER LANE OWNS IT (BH-8021, BH-8035): Mergify holds it (a waiting
  # `@mergifyio queue` request has no label, so the row is WAIT_CI, and a push
  # cancels it, project-6 #2300), or the migration hold gives it to an apply
  # lane (a push resets that lane, project-6 #2305). mc_rebase_gate is the one
  # gate every conductor rebase spawn asks. A read that fails is a deferral.
  local grc
  mc_rebase_gate land; grc=$?
  case "$grc" in
    1) mc_count_inc "$P" landskipped >/dev/null; mc_attempt_put "$mark"; return 1 ;;
    2) mc_count_inc "$P" landdeferred >/dev/null; return 1 ;;
  esac
  # A head-bound re-review is READING this exact head right now. Moving it under
  # that read throws away a billed agent call and buys a verdict bound to a sha
  # that no longer exists. Deferred, not skipped: no marker, so the next tick
  # offers it again.
  if [ "$(mc_rr_state "$(mc_rr_file "$SLUG" "$NUM" "$HEAD")")" = running ]; then
    mc_count_inc "$P" landdeferred >/dev/null
    mc_log "$KEY LAND_DEFER re-review running on ${HEAD:0:8} — the head is not moved under a read; offered again next tick"
    return 1
  fi
  if [ "$ACTIONS" != 1 ]; then
    mc_count_inc "$P" landwould >/dev/null
    mc_log "$KEY would land-rebase ${HEAD:0:8} onto $PBASE ${LAND_SHA:0:8} (observe mode: nothing written)"
    return 1
  fi
  lout=$(mc_land_needed "$SLUG" "$P" "$HEAD" "$NUM" "$LAND_SHA"); lrc=$?
  case "$lrc" in
    1) mc_count_inc "$P" landcurrent >/dev/null; mc_attempt_put "$mark"; return 1 ;;
    2) mc_count_inc "$P" landconflict >/dev/null; mc_attempt_put "$mark"
       mc_log "$KEY LAND_CONFLICT ${HEAD:0:8} vs $PBASE ${LAND_SHA:0:8} ($lout) — left to the NEEDS_REBASE path (GitHub will mark it DIRTY) and the resolver's ladder, unchanged"
       return 1 ;;
    3) mc_count_inc "$P" landdeferred >/dev/null
       mc_log "$KEY LAND_DEFER could not test ${HEAD:0:8}: $lout — offered again next tick"
       return 1 ;;
  esac
  # THE POOL PATH WINS, exactly as it does in the NEEDS_REBASE arm below: under
  # REBASE_ON_POOL there is no hub work to detach, so mc_rebase is called inline
  # and answers rc 6 (queued) or rc 7 (queue unreachable, nothing spent).
  if mc_pool_rebase_enabled "$P"; then
    lout=$(mc_rebase "$SLUG" "$P" "$BR" "$HEAD" "$URL"); lrc=$?
    if [ "$lrc" = 7 ]; then
      mc_count_inc "$P" landdeferred >/dev/null
      mc_log "$KEY LAND_DEFER pool queue unreachable for ${HEAD:0:8} — nothing spent, offered again next tick"
      return 1
    fi
    mc_attempt_put "$mark"
    mc_count_inc "$P" landspawned >/dev/null; mc_count_inc "$P" rebases >/dev/null
    mc_log "$KEY LAND_REBASE_QUEUED main ${LAND_SHA:0:8} — pool rebase of ${HEAD:0:8} ($(mc_pool_rebase_key "$NUM" "$HEAD"))"
    rebase_result "$KEY" "$URL" "$REC" "$HEAD" "$REVIEWED" "$VERDICT" "$MSTATE" "$lrc" "$lout"
    return 0
  fi
  # A new main is a new rebase job for this head: its own mark dedupes it, so
  # an earlier finished job's `rbjob` line must not refuse it (BH-2358).
  mc_attempt_clear rbjob "$KEY" "$HEAD done"
  mc_rebase_spawn "$SLUG" "$NUM" "$P" "$BR" "$HEAD" "$URL" "${MC_LAND_REBASE_PARALLEL:-4}"; lrc=$?
  case "$lrc" in
    0) mc_attempt_put "$mark"
       mc_count_inc "$P" landspawned >/dev/null; mc_count_inc "$P" rebases >/dev/null
       mc_log "$KEY LAND_REBASE_SPAWNED main ${LAND_SHA:0:8} — detached rebase of ${HEAD:0:8} into $BR ($(mc_rebase_job_ref "$SLUG" "$NUM" "$P" "$HEAD"))"
       mc_transition "$KEY" REBASING "REBASING ${HEAD:0:8} (land rebase spawned, main ${LAND_SHA:0:8})" "$HEAD" "$REVIEWED" "$URL" "$VERDICT" "$MSTATE" "$REC" >/dev/null
       return 0 ;;
    3) mc_count_inc "$P" landdeferred >/dev/null
       if [ "${MC_ON_MACHINE:-}" = 1 ]; then
         mc_log "$KEY LAND_DEFER ${HEAD:0:8} $(mc_rebase_spawn_why 3)"
       else
         mc_log "$KEY LAND_DEFER $(mc_rb_running) rebases already running (MC_LAND_REBASE_PARALLEL=${MC_LAND_REBASE_PARALLEL:-4}) — spawned on a later tick"
       fi
       return 1 ;;
    4) mc_count_inc "$P" landdeferred >/dev/null
       mc_log "$KEY LAND_DEFER ${HEAD:0:8}: $(mc_rebase_spawn_why 4)"
       return 1 ;;
    *) mc_count_inc "$P" landdeferred >/dev/null
       mc_log "$KEY LAND_DEFER spawn of ${HEAD:0:8} failed (rc $lrc) — offered again next tick"
       return 1 ;;
  esac
}

# rebase_result — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# eject_rebase_arm — the NEEDS_REBASE arm's first question (BH-1677). Reads
#   the pr_worker row variables, as land_rebase_arm does. rc 0 = it acted and
#   this PR's tick is over; rc 1 = the ordinary NEEDS_REBASE arm runs unchanged.
#
#   WHAT IT BUYS. A head Mergify ejected for a base-branch conflict (the settle
#   pass's `ejectconflict` mark) gets ONE rebase, ahead of MC_REBASE_BUDGET and
#   without the merge-tree test: Mergify's `## Reason` at this exact head is the
#   evidence. It is bounded three ways: once per head (`ejectrebase`, plus the
#   ordinary `rebase` mark so no budgeted rebase of the same head follows), the
#   land lane's MC_LAND_REBASE_PARALLEL hub cap, and marks that exist only after
#   a conflict was read. Any job file for this head means some rebase already
#   owns it, and the ordinary arm reports it.
#
#   MARK FIRST (D16). `ejectrebase` is written before the spawn and taken back
#   only when nothing was spent: the cap refused (rc 3), the spawn failed, or
#   the pool queue was unreachable (rc 7). The next tick offers it again.
eject_rebase_arm() {
  # THE NEEDS_REBASE ARM'S GATE (BH-8035). This arm is the first call of the
  # NEEDS_REBASE arm in bin/merge-conductor.sh, so the gate sits here, before
  # the eject rebase and before the pool, inline and detached spawns below it:
  # a PR another lane holds gets no rebase from either, and its tick is over.
  mc_rebase_gate needs-rebase || return 0
  [ "${MC_EJECT_REBASE:-1}" != 0 ] || return 1
  mc_attempt_has "ejectconflict $KEY $HEAD" 2>/dev/null || return 1
  mc_attempt_has "ejectrebase $KEY $HEAD" 2>/dev/null && return 1
  mc_attempt_has "rebase $KEY $HEAD" 2>/dev/null && return 1
  local jf erc eout
  jf=$(mc_rb_file "$SLUG" "$NUM" "$HEAD")
  [ "$(mc_rb_state "$jf")" = none ] || return 1
  if [ "$MERGES" != 1 ]; then
    mc_log "$KEY would EJECT_REBASE $HEAD (merge mode off) — Mergify ejected this head for a base-branch conflict"
    return 0
  fi
  mc_attempt_put "ejectrebase $KEY $HEAD"
  if mc_pool_rebase_enabled "$P"; then
    eout=$(mc_rebase "$SLUG" "$P" "$BR" "$HEAD" "$URL"); erc=$?
    if [ "$erc" = 7 ]; then
      mc_attempt_clear ejectrebase "$KEY" "$HEAD"
      mc_log "$KEY EJECT_REBASE_DEFER $HEAD — pool queue unreachable, nothing spent; offered again next tick"
      return 1
    fi
    mc_attempt_put "rebase $KEY $HEAD"; mc_count_inc "$P" rebases >/dev/null
    mc_log "EJECT_REBASE_SPAWNED $KEY $HEAD (pool)"
    rebase_result "$KEY" "$URL" "$REC" "$HEAD" "$REVIEWED" "$VERDICT" "$MSTATE" "$erc" "$eout"
    return 0
  fi
  # Same as the land arm: the ejection is a new rebase job, `ejectrebase` dedupes it (BH-2358).
  mc_attempt_clear rbjob "$KEY" "$HEAD done"
  mc_rebase_spawn "$SLUG" "$NUM" "$P" "$BR" "$HEAD" "$URL" "${MC_LAND_REBASE_PARALLEL:-4}"; erc=$?
  if [ "$erc" != 0 ]; then
    mc_attempt_clear ejectrebase "$KEY" "$HEAD"
    if [ "$erc" = 3 ] && [ "${MC_ON_MACHINE:-}" != 1 ]; then
      mc_log "$KEY EJECT_REBASE_DEFER $HEAD — spawn refused (rc $erc; $(mc_rb_running) rebases running, MC_LAND_REBASE_PARALLEL=${MC_LAND_REBASE_PARALLEL:-4}); offered again next tick"
    else
      mc_log "$KEY EJECT_REBASE_DEFER $HEAD — $(mc_rebase_spawn_why "$erc") (rc $erc)"
    fi
    return 1
  fi
  mc_attempt_put "rebase $KEY $HEAD"; mc_count_inc "$P" rebases >/dev/null
  mc_log "EJECT_REBASE_SPAWNED $KEY $HEAD — detached rebase of ${HEAD:0:8} into $BR after a base-conflict ejection ($(mc_rebase_job_ref "$SLUG" "$NUM" "$P" "$HEAD"))"
  mc_transition "$KEY" REBASING "REBASING ${HEAD:0:8} (rebase after a base-conflict ejection)" "$HEAD" "$REVIEWED" "$URL" "$VERDICT" "$MSTATE" "$REC" >/dev/null
  return 0
}

# rebase_result <key> <url> <record> <head> <reviewed> <verdict> <mstate> <rc> <out>
#   What a FINISHED rebase means, for both paths: the detached job's recorded rc
#   and stdout (the normal case) and the inline call's under MC_DETACHED_REBASE=0.
#   rc 6 and 7 are the pool arms (BH-486) and are the one pair where the rebase
#   has NOT finished: 6 says a pool machine has the job, 7 says the queue refused
#   it and nothing was spent.
#   It is one function for one reason — the kill flag has to restore today's
#   behaviour exactly, not approximately, and a second copy of these six arms is
#   how "exactly" rots.
rebase_result() {
  local key="$1" url="$2" rec="$3" head="$4" reviewed="$5" verdict="$6" mstate="$7" rc="$8" out="$9"
  case "$rc" in
    0) mc_log "$key rebased: pushed ${out:0:8} over ${head:0:8} with an explicit lease; approval rebound"
       mc_transition "$key" WAIT_CI "rebased to ${out:0:8}, checks pending" "$out" "$out" "$url" "$verdict" UNKNOWN "$rec" >/dev/null ;;
    1) mc_transition "$key" BLOCKED_HUMAN "conflict-unresolvable: $(tr '\n' ' ' <<<"$out")" "$head" "$reviewed" "$url" "$verdict" "$mstate" "$rec" >/dev/null
       mc_log "$key BLOCKED_AGENT conflict-unresolvable: $(tr '\n' ' ' <<<"$out") — handed to bin/blocked-resolver.sh (its ladder: merge main again, then an agent fix round on this branch, then a fresh rebuild) — $(mc_park_human_action conflict-unresolvable): $url" ;;
    2) mc_log "$key rebase gate RED (typecheck/unit) — not pushed"
       mc_transition "$key" BLOCKED_HUMAN "rebase-gate-red" "$head" "$reviewed" "$url" "$verdict" "$mstate" "$rec" >/dev/null
       mc_log "$key BLOCKED_AGENT rebase-gate-red: merged with main the branch fails typecheck/unit on the hub — handed to bin/blocked-resolver.sh (its ladder: merge main again, then an agent fix round on this branch, then a fresh rebuild): $url" ;;
    3) mc_log "$key rebase lease rejected — head moved between read and push; back to NEEDS_REBASE next tick"
       mc_transition "$key" NEEDS_REBASE "lease rejected, retry" "$head" "$reviewed" "$url" "$verdict" "$mstate" "$rec" >/dev/null ;;
    # mc_tmp_room refused before any git work (BH-4464): the `*)` transition,
    # with a reason that says the hub's tmp is the problem, not the PR.
    8) mc_log "$key rebase refused: hub tmp full — nothing spent, retried next tick"
       mc_transition "$key" NEEDS_REBASE "tmp full, retry" "$head" "$reviewed" "$url" "$verdict" "$mstate" "$rec" >/dev/null ;;
    # The push LANDED but the approval could not be moved onto it. WAIT_CI
    # here would be a lie — the sweep would read the row as reviewed and
    # park the PR on the old approved sha — so the row stays honest: the
    # head is the new one, the reviewed sha is the old one, reason says why.
    # A PR THAT HAD NO APPROVAL HAS NONE TO LOSE (2026-09-14). Since the DIRTY
    # clause moved ahead of the no-verdict branch, a conflicted PR nobody has
    # reviewed reaches this lane too — and for it rc 5 is not a failure at all:
    # job_verdict_rebind answers "no claim to move" because there is no claim.
    # Parking it in NEEDS_REBASE would be a rebase loop on a PR that just
    # stopped conflicting. The honest row is the pushed head with no reviewed
    # sha, which classifies as the fresh head-bound review on the next tick.
    # rc 5 is ALSO a union-resolved merge (BH-4641): the rebind is withheld on
    # purpose, and the same NEEDS_REBASE row buys the head-bound re-review.
    5) if [ -z "$reviewed" ] || [ "$reviewed" = "-" ]; then
         mc_log "$key rebased: pushed ${out:0:8} over ${head:0:8}; no approval to rebind (this PR has never had one) — the head-bound review is bought on the new head"
         mc_transition "$key" WAIT_CI "rebased to ${out:0:8}, no verdict to rebind" "$out" "-" "$url" "$verdict" UNKNOWN "$rec" >/dev/null
       else
         mc_log "$key rebased to ${out:0:8} but the approval rebind FAILED — reviewed is still ${reviewed:0:8}, not moving to WAIT_CI"
         mc_transition "$key" NEEDS_REBASE "rebind-failed" "$out" "$reviewed" "$url" "$verdict" UNKNOWN "$rec" >/dev/null
       fi ;;
    # THE POOL ARMS (BH-486). Nothing has moved on GitHub yet in either of
    # them, so the head and the reviewed sha are passed through untouched.
    6) mc_log "$key pool rebase queued ($(mc_pool_rebase_key "$(mc_num_of_url "$url")" "$head")) — ${head:0:8} rebases on a pool machine; nothing waits on it"
       mc_transition "$key" REBASING "pool rebase queued ($(mc_pool_rebase_key "$(mc_num_of_url "$url")" "$head"))" "$head" "$reviewed" "$url" "$verdict" "$mstate" "$rec" >/dev/null ;;
    7) mc_log "$key pool queue unreachable — nothing spent, retried next tick"
       mc_transition "$key" NEEDS_REBASE "pool queue unreachable, retry" "$head" "$reviewed" "$url" "$verdict" "$mstate" "$rec" >/dev/null ;;
    *) mc_log "$key rebase setup failed (rc $rc)"
       mc_transition "$key" NEEDS_REBASE "rebase setup failed rc=$rc" "$head" "$reviewed" "$url" "$verdict" "$mstate" "$rec" >/dev/null ;;
  esac
}

# eject_rebased_note <key> <url> <head> <rc> <out> — the audit of a rebase
#   eject_rebase_arm bought (BH-1677): one ledger row and one EJECT_REBASED line
#   when a finished job pushed a new head (rc 0 or 5) for a head marked
#   `ejectrebase`, once per head (`ejectrebased`). The re-enqueue is the
#   ordinary path. The ledger write is fail-open like every other caller;
#   attempts.txt and the log are the record.
eject_rebased_note() {
  local key="$1" url="$2" head="$3" rc="$4" out="$5"
  [ "${MC_EJECT_REBASE:-1}" != 0 ] || return 0
  case "$rc" in 0|5) ;; *) return 0 ;; esac
  [[ "$out" =~ ^[0-9a-f]{7,40}$ ]] || return 0
  mc_attempt_has "ejectrebase $key $head" 2>/dev/null || return 0
  mc_attempt_has "ejectrebased $key $head" 2>/dev/null && return 0
  mc_attempt_put "ejectrebased $key $head"
  type job_ledger_put >/dev/null 2>&1 && \
    job_ledger_put rebase "$url@$out" REBASED "rebased_after_ejection=1 from=${head:0:8}" >/dev/null 2>&1 || true
  mc_log "EJECT_REBASED $key ${head:0:8} -> ${out:0:8}"
  return 0
}

# eject_rebased_moved <key> <slug> <num> <url> <head> — the same audit when the
#   push is already visible. rebase_consume reads the job file of the head the
#   list shows NOW, so once GitHub lists the pushed head the finished job (keyed
#   by the old head) is never read there. The row still carries the old head
#   until this tick transitions it: when that head was marked `ejectrebase` and
#   its finished job pushed exactly the head listed now, audit it here.
eject_rebased_moved() {
  local key="$1" slug="$2" num="$3" url="$4" head="$5" old jf
  [ "${MC_EJECT_REBASE:-1}" != 0 ] || return 0
  old=$(mc_row_field "$key" 4)
  [ -n "$old" ] && [ "$old" != "$head" ] || return 0
  mc_attempt_has "ejectrebase $key $old" 2>/dev/null || return 0
  jf=$(mc_rb_file "$slug" "$num" "$old")
  [ "$(mc_rr_field "$jf" status)" = done ] && [ "$(mc_rr_field "$jf" new_head)" = "$head" ] || return 0
  eject_rebased_note "$key" "$url" "$old" "$(mc_rr_field "$jf" rc)" "$head"
}

# rebase_consume — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# rebase_consume <key> <slug> <num> <url> <record> <head> <reviewed> <verdict> <mstate>
#   rc 0 when a FINISHED detached rebase job for (PR, this head) was read and
#   applied this tick, and the caller must then move to the next PR. rc 1 when
#   there is nothing to read.
#
#   WHY IT RUNS BEFORE THE CLASSIFIER. The job pushed (or refused to) minutes
#   ago and it may have moved `reviewed-sha` onto the head it pushed, so its
#   result is a NEWER fact about this PR than anything mc_classify can derive
#   from a head the job started from. Inline, the rebase was the last thing the
#   tick did for a PR and its transition was the tick's final word; reading the
#   result first, and moving on, is that same order.
#
#   It is not gated on the actions flag: reading a result file writes nothing to
#   GitHub, and a job spawned before the flag went off must still be recorded.
rebase_consume() {
  local key="$1" slug="$2" num="$3" url="$4" rec="$5" head="$6" reviewed="$7" verdict="$8" mstate="$9"
  local jf st rc out pst res outc
  # ON A MACHINE WITH conductor_remote_spawn ON (BH-6888) the result is the
  # queue row, read through the API; there is no local job file. A CONFLICT,
  # GATE_RED or lease rejection is applied once per (key, head), the marker
  # written last (BH-523). A REBASED moved the PR: the hub reap already did the
  # rebind (or not), so this run only logs the sha and lets the classifier read
  # the head GitHub lists. A failed, empty, stale or defer row reopens the
  # NEEDS_REBASE arm's mark, so the arm calls the spawn again this tick and the
  # spawn retries or hands the PR back (mc_remote_rebase_reopen).
  if [ "${MC_ON_MACHINE:-}" = 1 ] && command -v mc_remote_on >/dev/null 2>&1 && mc_remote_on "$P"; then
    res=$(mc_remote_rebase_result "$P" "$num" "$head") || return 1
    IFS=$'\t' read -r outc rc out <<<"$res"
    [ "$outc" = ok ] || { mc_remote_rebase_reopen "$key" "$head" "$outc" "$out"; return 1; }
    case "$rc" in
      0) mc_log "$key remote rebase of ${head:0:8} pushed $out — the classifier reads the listed head"; return 1 ;;
      1|2|3)
        mc_attempt_has "rebasedone $key $head" 2>/dev/null && return 1
        rebase_result "$key" "$url" "$rec" "$head" "$reviewed" "$verdict" "$mstate" "$rc" "$out"
        mc_attempt_put "rebasedone $key $head"
        return 0 ;;
    esac
    return 1
  fi
  # THE KILL SWITCH IS ABOUT THE DETACHED LANE, NOT ABOUT THE POOL (BH-486).
  # With MC_DETACHED_REBASE=0 and the flag OFF this is the single-line guard it
  # replaced. With the knob at 0 and the flag ON, a result a pool machine
  # already wrote must still be read — otherwise mc_pool_rebase_apply stamps the
  # job file `done` and the row sits REBASING for ever.
  if [ "${MC_DETACHED_REBASE:-1}" = 0 ]; then
    mc_pool_rebase_enabled "$P" || return 1
  fi
  jf=$(mc_rb_file "$slug" "$num" "$head"); st=$(mc_rb_state "$jf")
  case "$st" in
    done)
      rc=$(mc_rr_field "$jf" rc); out=$(cat "$(mc_rr_field "$jf" out_file)" 2>/dev/null)
      # A job file with no readable rc told us nothing, which is rc 4's meaning:
      # nothing was pushed and we cannot say why.
      case "$rc" in ''|*[!0-9]*) rc=4 ;; esac
      if mc_attempt_has "rebasedone $key $head" 2>/dev/null; then
        # SEEN ONCE — BUT DID IT LAND? (BH-523). The marker used to be appended
        # on first SIGHT, before the result was applied, so a worker killed in
        # between left it behind with no transition behind it and the finished
        # rebase was dropped for ever. It is written last now, and the strands
        # the old order left on the hub are drained here: only when the row
        # still shows the pre-apply shape — this state, on this head — and only
        # for an rc whose application MOVES the row. rc 3 and rc >=4 park it in
        # NEEDS_REBASE on the same head by design, so for those a seen marker
        # plus a NEEDS_REBASE row IS the applied state; re-applying would answer
        # rc 0 every tick and starve the stuck detector that ends the strand.
        case "$(mc_row_field "$key" 2)" in NEEDS_REBASE|REBASING) ;; *) return 1 ;; esac
        [ "$(mc_row_field "$key" 4)" = "$head" ] || return 1
        case "$rc" in 0|1|2|5) ;; *) return 1 ;; esac
        mc_log "$key finished rebase result on ${head:0:8} was never applied — applying now"
        rebase_result "$key" "$url" "$rec" "$head" "$reviewed" "$verdict" "$mstate" "$rc" "$out"
        eject_rebased_note "$key" "$url" "$head" "$rc" "$out"
        return 0
      fi
      rebase_result "$key" "$url" "$rec" "$head" "$reviewed" "$verdict" "$mstate" "$rc" "$out"
      eject_rebased_note "$key" "$url" "$head" "$rc" "$out"
      # THE MARKER IS WRITTEN LAST (BH-523). The worker holds this PR's flock,
      # so the marker's only job is the double-tick guard above — and a guard
      # recorded before the work it guards is a guard against doing the work.
      mc_attempt_put "rebasedone $key $head"
      return 0 ;;
    failed|stale)
      # Read BEFORE mc_rb_fail rewrites the status: a POOL job that timed out is
      # a different fact from a dead pid, and it is the one the console needs —
      # the queue row is still sitting there and nobody on the pool answered.
      pst=$(mc_rr_field "$jf" status)
      if [ "$st" = stale ]; then
        mc_rb_fail "$jf"
        if [ "$pst" = pool ]; then
          mc_log "$key pool rebase of ${head:0:8} produced no RESULT within ${MC_REBASE_POOL_TIMEOUT_SECS:-5400}s — failed"
          type job_ledger_put >/dev/null 2>&1 && \
            job_ledger_put rebase "$url@$head" TIMED_OUT "no RESULT within ${MC_REBASE_POOL_TIMEOUT_SECS:-5400}s" >/dev/null 2>&1 || true
        else
          mc_log "$key detached rebase on ${head:0:8} is gone (pid dead or past ${MC_REBASE_TIMEOUT_SECS:-1800}s) — failed"
        fi
      fi
      # A LATE MACHINE RESULT STILL APPLIES. mc_pool_rebase_apply rewrites this
      # same file to `done`, and the next tick's `done` arm reads it: a head a
      # pool machine actually pushed is a fact, whatever the hub gave up on.
      mc_attempted rebasefailed "$key" "$head" && return 1
      mc_log "$key detached rebase produced NO result on ${head:0:8}"
      mc_transition "$key" NEEDS_REBASE "detached rebase produced no result" "$head" "$reviewed" "$url" "$verdict" "$mstate" "$rec" >/dev/null
      return 0 ;;
  esac
  return 1
}

# rereview_lane_retry — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# rereview_lane_retry <mode> <key> <url> <record> <head> <reviewed> <verdict>
#                     <mstate> <job-file>
#   A DEAD RE-REVIEW IS A FACT ABOUT THE REVIEWER, NOT ABOUT THE PR (2026-09-16,
#   lever 2). `failed`/`stale` means nobody answered — the pid is gone, or the
#   job is past MC_REREVIEW_TIMEOUT_SECS — and the arm below turns that silence
#   into a `no-verdict` park the resolver then has to drain. Once, that is the
#   right answer; the FIRST time it is just a lane that died under us, and the
#   cheap thing to do is ask again.
#
#   So the first failure per (PR, head) FORGETS the job file and leaves the row
#   in HEAD_MOVED: the next tick walks the `none` case and buys one more read,
#   through the same budget, the same daily cap and the same CI-green debounce
#   as the first. The SECOND failure falls through to today's park, unchanged —
#   `mc_attempted rereviewretry` is what makes the retry exactly one, and makes
#   it a retry of the READ rather than a clock anybody can run out.
#
#   NOTHING HERE IS TIMED (the operator, 2026-09-16: "no rules that kill PRs because of
#   time; it should be event based"). The retry fires on the EVENT of a job that
#   is not coming back, and the park fires on the EVENT of a second one. No
#   elapsed-time rule closes, abandons or parks a PR from this path.
#
#   The provenance mode is deliberately untouched: its hold has its own
#   auto-resolve window and its own alert (mc_prov_autoresolving), and a second
#   read bought from here would change when that window says "not paged".
#   rc 0 = retried, and the caller is finished with this PR this tick.
rereview_lane_retry() {
  local mode="$1" key="$2" url="$3" rec="$4" head="$5" reviewed="$6" verdict="$7"
  local mstate="$8" jobf="$9"
  [ "${MC_REREVIEW_ON_MOVE:-1}" != 0 ] || return 1
  [ "$mode" != provenance ] || return 1
  mc_attempted rereviewretry "$key" "$head" && return 1
  rm -f "$jobf" 2>/dev/null
  mc_log "$key head-bound re-review LANE FAILED on ${head:0:8} — nobody answered, which says something about the reviewer and nothing about this diff; the job file is forgotten and the next tick buys ONE more read before any park"
  mc_transition "$key" HEAD_MOVED "re-review lane failed on ${head:0:8}, buying one more read" "$head" "$reviewed" "$url" "$verdict" "$mstate" "$rec" >/dev/null
  return 0
}

# head_lag_mins_for — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# head_lag_mins_for <project> — the registered knob; 0 (or unreadable) is off.
head_lag_mins_for() {
  local v
  if command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob merge-conductor MC_HEAD_LAG_MINS "${1:-}" 2>/dev/null)
  else v="${MC_HEAD_LAG_MINS:-}"; fi
  case "$v" in ''|*[!0-9]*) v=0 ;; esac
  printf '%s' "$v"
}

# head_lag_held_recheck_mins_for <project> — BH-1564: how long a HELD answer
#   for one tip stands before head_lag_kick asks both holds again. 0 (or
#   unreadable) asks on every tick, which is what BH-1529 shipped.
head_lag_held_recheck_mins_for() {
  local v
  if command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob merge-conductor MC_HEAD_LAG_HELD_RECHECK_MINS "${1:-}" 2>/dev/null)
  else v="${MC_HEAD_LAG_HELD_RECHECK_MINS:-}"; fi
  case "$v" in ''|*[!0-9]*) v=0 ;; esac
  printf '%s' "$v"
}

# head_lag_file — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
head_lag_file() { printf '%s/head-lag/%s' "$MC_STATE_DIR" "$(mc_safe_name "$1")"; }

# head_lag_gc — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# Since BH-1564 the file is only a cache: a PR whose file this drops reads its
# record back from the `headlag` rows, so an old lag is not re-armed.
head_lag_gc() { find "$MC_STATE_DIR/head-lag" -maxdepth 1 -type f -mtime +3 -delete 2>/dev/null; return 0; }

# head_lag_tip — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# head_lag_tip <slug> <branch> <out-file> [head] — rc 0 and the tip sha in <out-file>,
#   else rc 75 and HEAD_LAG_WHY says why. A plain command, never `$( )`, so
#   GH_REST_STATUS survives into the log line.
#   BH-4659: after the per-tick memo, the refs read (prs_branch_tip). A refs tip
#   is taken only when no head was passed or it EQUALS the head: a refs file up
#   to a TTL old can carry a pre-push tip, so a tip that would start a lag clock
#   is confirmed by the live branches/ read below first.
#   BH-6462: the refs read takes this tick's pin (MC_REFS_PIN_PREFIX, set by
#   tick_project; bin/lib/pr-snapshot-refs.sh, THE PIN) before the cache.
#   BH-6810: both GitHub reads (the refs read on a cache miss and the live
#   branches/ read) are bounded by MC_HEAD_LAG_READ_TIMEOUT_S (default 30 s,
#   0 = off, not a number = 30) through gh_rest's GH_REST_TIMEOUT_S. A read
#   that passes it is rc 75 with HEAD_LAG_WHY "HTTP 000 timeout".
head_lag_read_timeout_s() { local s="${MC_HEAD_LAG_READ_TIMEOUT_S:-30}"; [[ "$s" =~ ^[0-9]+$ ]] || s=30; printf '%s\n' "$((10#$s))"; }
head_lag_tip() {
  local slug="$1" br="$2" out="$3" head="${4:-}" memo rc=0 sha GH_REST_TIMEOUT_S
  GH_REST_TIMEOUT_S=$(head_lag_read_timeout_s); [ "$GH_REST_TIMEOUT_S" -gt 0 ] || GH_REST_TIMEOUT_S=
  memo=$(tick_memo_file headtip "$slug#$br")
  if [ -s "$memo" ]; then cp "$memo" "$out" 2>/dev/null && return 0; fi
  if command -v prs_branch_tip >/dev/null 2>&1 && PRS_REFS_PIN_PREFIX="${MC_REFS_PIN_PREFIX:-}" prs_branch_tip "$slug" "$br" > "$out" 2>/dev/null \
     && { [ -z "$head" ] || [ "$(cat "$out")" = "$head" ]; }; then
    mkdir -p "$MC_TICK_DIR" 2>/dev/null && cp "$out" "$memo" 2>/dev/null
    return 0
  fi
  gh_rest GET "repos/$slug/branches/$br" > "$out" || rc=$?
  sha=$(jq -r '.commit.sha // empty' "$out" 2>/dev/null)
  if [ "$rc" != 0 ] || ! [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]]; then
    HEAD_LAG_WHY="HTTP ${GH_REST_STATUS:-000}${GH_REST_REASON:+ $GH_REST_REASON}"; return 75
  fi
  printf '%s\n' "$sha" > "$out"
  mkdir -p "$MC_TICK_DIR" 2>/dev/null && cp "$out" "$memo" 2>/dev/null
  return 0
}

# head_lag_put — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# head_lag_put <key> <head> <tip> <since> <spent> <alerted> <outcome> <refused> [held-at]
#   The FILE half only. The eighth column (BH-1564) is when a hold last kept
#   this tip from its kick; a seven-column line reads it as 0.
head_lag_put() {
  local f; f=$(head_lag_file "$1")
  mkdir -p "${f%/*}" 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" "$6" "${7:--}" "${8:-0}" "${9:-0}" > "$f.tmp.$BASHPID" && mv -f "$f.tmp.$BASHPID" "$f"
}

# --- THE HEAD-LAG RECORD IS ROWS (BH-1564) -----------------------------------
# The file above lives on ONE box. A wiped state dir, a hub move or the 3-day GC
# lost it, and a PR still lagging on the same tip then got a fresh clock, a
# SECOND close/reopen and a SECOND page. So every change to the record is also
# a `pr_attempts` row (the BH-1025 table, through mc_attempt_row_put and its
# pr-state-rows flag and per-tick latch), kind `headlag`, one row per fact,
# the sha column "<tip> <fact> [n]":
#   seen <epoch>         the lag clock for this tip started
#   try <n> <epoch>      close/reopen attempt n, written BEFORE mc_kick_ci
#   reopened | closed    how the attempt ended (closed = LEFT CLOSED, paged)
#   refused <n>          GitHub refused attempt n's close; nothing changed
#   gaveup <epoch>       the MC_KICK_REOPEN_TRIES-th refusal; the tip is spent
#   alerted              the one HEAD_LAG page for this tip went out
#   held <epoch>         a hold kept this tip from its kick (the cached verdict)
# Facts are only ever added, and the (repo, number, kind, sha) key makes each
# one idempotent, so there is no read-modify-write to race. The file stays the
# first read, a cache: the rows are asked only when the file does not hold the
# tip being looked at. Keyed by tip, so a new push is a new record with no
# delete, exactly as the file treats it.

# head_lag_note <key> <tip> <fact> [args] — add one fact row. The rc is
#   mc_attempt_row_put's, which is always 0: the file is written first.
head_lag_note() { mc_attempt_row_put "headlag $1 $2 $3${4:+ $4}"; }

# head_lag_rows_read <key> <tip> <head> <out-file> — rebuild the file line for
#   <tip> from its rows into <out-file>. rc 0 a record | rc 2 no row for this
#   tip | rc 1 the rows are off (the caller then does what it did before rows
#   existed: starts a fresh clock) | rc 3 the worker could not answer (the
#   caller must not start a clock: the record may exist, BH-1891).
head_lag_rows_read() {
  local key="$1" tip="$2" head="$3" out="$4" t rc x f a b found=0
  local since=0 try=0 tryat=0 gave=0 re=0 cl=0 al=0 refused=0 held=0 spent=0 outcome=- alerted=0
  t=$(mktemp "${TMPDIR:-/tmp}/mc-lagrows.XXXXXX") || return 1
  mc_attempt_rows headlag "$key" "$t"; rc=$?
  if [ "$rc" != 0 ]; then rm -f "$t"; return "$rc"; fi
  while read -r x f a b _; do
    [ "$x" = "$tip" ] || continue
    case "$a" in ''|*[!0-9]*) a=0 ;; esac
    case "$b" in ''|*[!0-9]*) b=0 ;; esac
    found=1
    case "$f" in
      seen)     if [ "$a" -gt 0 ] && { [ "$since" = 0 ] || [ "$a" -lt "$since" ]; }; then since=$a; fi ;;
      try)      if [ "$a" -gt "$try" ]; then try=$a; tryat=$b; fi ;;
      gaveup)   [ "$a" -le "$gave" ] || gave=$a ;;
      refused)  [ "$a" -le "$refused" ] || refused=$a ;;
      held)     [ "$a" -le "$held" ] || held=$a ;;
      reopened) re=1 ;;
      closed)   cl=1 ;;
      alerted)  al=1 ;;
    esac
  done < "$t"
  rm -f "$t"
  [ "$found" = 1 ] || return 2
  if [ "$gave" -gt 0 ]; then
    spent=$gave; outcome=refused
  elif [ "$try" -gt "$refused" ]; then
    # The latest attempt was not refused, so it spent the reopen — and with no
    # outcome row it is `pending`, exactly the file's "died half-way" case.
    spent=$tryat; outcome=pending
    [ "$re" = 1 ] && outcome=reopened
    [ "$cl" = 1 ] && outcome=closed
  fi
  { [ "$al" = 1 ] || [ "$outcome" = closed ]; } && alerted=1
  [ "$since" -gt 0 ] || since=$tryat
  [ "$since" -gt 0 ] || since=$(mc_now)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$head" "$tip" "$since" "$spent" "$alerted" "$outcome" "$refused" "$held" > "$out"
}

# head_lag_check — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# head_lag_check <project> <key> <slug> <num> <url> <head> <branch> <cross>
#   rc 0 = this tick closed the PR (the kick), and the caller stops here: the
#   rest of the tick would be reasoning about a head GitHub has not caught up
#   with. rc 1 = carry on with the PR exactly as before.
head_lag_check() {
  local p="$1" key="$2" slug="$3" num="$4" url="$5" head="$6" br="$7" cross="$8"
  local mins f t tip now sh="" st="" ss="" sk=0 sa=0 so="-" sr=0 sd=0 rc
  mins=$(head_lag_mins_for "$p"); [ "$mins" -gt 0 ] || return 1
  [ "$cross" = false ] && [ -n "$head" ] && [[ "$br" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
  t=$(mktemp "${TMPDIR:-/tmp}/mc-tip.XXXXXX") || return 1
  if ! head_lag_tip "$slug" "$br" "$t" "$head"; then
    rm -f "$t"
    # BH-6810: a read that passed its bound is a named HELD reason, said once
    # per (PR, head). The PR carries on (rc 1), as for any unreadable tip.
    if [ "${GH_REST_REASON:-}" = timeout ]; then
      mc_attempt_has "headlag-held $key $head" 2>/dev/null || { mc_attempt_put "headlag-held $key $head"
        mc_log "$key HEAD_LAG_HELD reason=tip-read-timeout: the tip read of $br passed $(head_lag_read_timeout_s)s — head-lag not checked on ${head:0:8} this tick; the PR carries on, asked again every tick"; }
      return 1
    fi
    # Said once per (PR, head): a PR whose branch is gone stays unreadable on
    # every tick, and a line per tick would bury the log.
    mc_attempt_has "headlag-unread $key $head" 2>/dev/null || { mc_attempt_put "headlag-unread $key $head"
      mc_log "$key head-lag check skipped: the tip of $br could not be read ($HEAD_LAG_WHY) — unverifiable, asked again every tick"; }
    return 1
  fi
  tip=$(cat "$t"); rm -f "$t"; f=$(head_lag_file "$key"); now=$(mc_now)
  [ -f "$f" ] && IFS=$'\t' read -r sh st ss sk sa so sr sd < "$f"
  case "$sd" in ''|*[!0-9]*) sd=0 ;; esac
  if [ "$tip" = "$head" ]; then
    [ -f "$f" ] || return 1
    rm -f "$f"; [ "${sk:-0}" != 0 ] && mc_log "$key HEAD_LAG_CLEARED — the PR object caught up with $br at ${tip:0:8}"
    return 1
  fi
  # A file that does not hold THIS tip asks the rows before it starts a clock
  # (BH-1564): no file at all after a wiped state dir, a hub move or the GC,
  # or an older tip's. A record found there is warmed back into the file and
  # carries on where it stopped, so a restart cannot buy a second reopen. A
  # worker that cannot answer (rc 3) writes NOTHING — no file, no row, no kick
  # decision — because "unreadable" is not "never kicked" (BH-1891); the next
  # tick asks again.
  if [ "$st" != "$tip" ]; then
    t=$(mktemp "${TMPDIR:-/tmp}/mc-lagrec.XXXXXX") || return 1
    head_lag_rows_read "$key" "$tip" "$head" "$t"; rc=$?
    if [ "$rc" = 0 ] && IFS=$'\t' read -r sh st ss sk sa so sr sd < "$t"; then
      rm -f "$t"
      head_lag_put "$key" "$head" "$tip" "$ss" "$sk" "$sa" "$so" "$sr" "$sd"
      mc_log "$key head-lag record for ${tip:0:8} read back from its rows (kick outcome: $so) — the state file did not hold it"
    elif [ "$rc" = 3 ]; then
      rm -f "$t"
      mc_log "$key head-lag record for ${tip:0:8} not read: pr-state-rows unreachable — no clock started and no kick decision this tick; asked again next tick"
      return 1
    else
      # A new tip is a new push, so it gets a fresh clock and a fresh reopen.
      rm -f "$t"
      head_lag_put "$key" "$head" "$tip" "$now" 0 0 - 0
      head_lag_note "$key" "$tip" seen "$now"
      mc_log "$key head ${head:0:8} lags its branch tip ${tip:0:8} ($br) — closed and reopened once if GitHub has not caught up in ${mins}m"
      return 1
    fi
  fi
  if [ "${sk:-0}" != 0 ]; then head_lag_after_kick "$key" "$url" "$head" "$tip" "$ss" "$sk" "${sa:-0}" "$mins" "${so:--}" "${sr:-0}"; return 1; fi
  [ $((now - ss)) -ge $((mins * 60)) ] || return 1
  # BH-6670: the kick is a close/reopen WRITE, so it is its own step, and a
  # step timeout in it pages (bin/lib/fanin.sh holds only read-only steps).
  command -v mc_step >/dev/null 2>&1 && mc_step head-lag-kick
  head_lag_kick "$p" "$key" "$slug" "$num" "$url" "$head" "$tip" "$ss" "$(( (now - ss) / 60 ))" "${sr:-0}" "$sd"
}

# head_lag_kick — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# head_lag_kick — the ONE close/reopen for this tip, behind every write guard.
#   A hold (either kind) or a close GitHub refused changes nothing on GitHub,
#   so neither spends the reopen — but refusals are counted, and the reopen is
#   given up after MC_KICK_REOPEN_TRIES of them, so a close that can never land
#   is not retried on every tick for ever.
head_lag_kick() {
  local p="$1" key="$2" slug="$3" num="$4" url="$5" head="$6" tip="$7" since="$8" m="$9" refused="${10:-0}" held="${11:-0}"
  local recheck now try
  if [ "$ACTIONS" != 1 ]; then
    mc_attempt_has "headlag-would $key $tip" 2>/dev/null || { mc_attempt_put "headlag-would $key $tip"
      mc_log "$key would close and reopen — head ${head:0:8} has lagged the branch tip ${tip:0:8} for ${m}m (observe mode: nothing written)"; }
    return 1
  fi
  # THE HELD VERDICT IS CACHED PER TIP (BH-1564). A held PR that keeps lagging
  # used to re-read both holds (a REST PR read, a gh PR read and the hold
  # issue/comment reads) on every tick. A held answer now stands for
  # MC_HEAD_LAG_HELD_RECHECK_MINS on this tip: long enough to stop the per-tick
  # reads, short enough that a lifted hold still gets its kick.
  recheck=$(head_lag_held_recheck_mins_for "$p"); now=$(mc_now)
  case "$held" in ''|*[!0-9]*) held=0 ;; esac
  if [ "$held" -gt 0 ] && [ "$recheck" -gt 0 ] && [ $((now - held)) -lt $((recheck * 60)) ]; then return 1; fi
  # BOTH holds are asked BEFORE anything is recorded (BH-1529 fix round 1).
  # to_lane_hold (BH-1526) exempts a lead PR; mc_hold_keeps_pr (BH-1460, the
  # one mc_kick_ci obeys) does not. Asking only the first let a lead PR on a
  # HOLD ticket spend its reopen with no kick and then page "after one
  # close/reopen" about a PR nobody closed. mc_hold_keeps_pr is memoised per
  # tick, so mc_kick_ci's own ask below costs nothing more.
  if { command -v to_lane_hold >/dev/null 2>&1 && to_lane_hold "$p" "$slug" "$num"; } \
     || mc_hold_keeps_pr "$slug" "$num"; then
    if [ "$recheck" -gt 0 ]; then
      head_lag_put "$key" "$head" "$tip" "$since" 0 0 - "$refused" "$now"
      head_lag_note "$key" "$tip" held "$now"
    fi
    return 1
  fi
  # Recorded BEFORE the kick as `pending` (the file) and as try <n> (the row):
  # a kick that dies half-way costs this tip its one reopen, never a loop of
  # them — on this box or, through the row, on the next.
  try=$((refused + 1))
  head_lag_put "$key" "$head" "$tip" "$since" "$now" 0 pending "$refused"
  head_lag_note "$key" "$tip" try "$try $now"
  # No expected head on purpose (BH-3804): this kick's premise is that the PR's
  # head lags the branch, and a stale answer would spend the refusal budget.
  if mc_kick_ci "$slug" "$num"; then
    head_lag_put "$key" "$head" "$tip" "$since" "$now" 0 reopened "$refused"
    head_lag_note "$key" "$tip" reopened
    mc_log "$key HEAD_LAG_KICKED — head ${head:0:8} lagged the branch tip ${tip:0:8} for ${m}m; closed and reopened once so GitHub re-reads the branch: $url"
  elif [ "$MC_KICK_CLOSED" = 1 ]; then
    head_lag_put "$key" "$head" "$tip" "$since" "$now" 1 closed "$refused"
    head_lag_note "$key" "$tip" closed
    mc_log "$key HEAD_LAG kick closed the PR and could not reopen it (mc_kick_ci paged LEFT CLOSED) — the reopen for this tip is spent: $url"
  else
    refused=$((refused + 1))
    head_lag_note "$key" "$tip" refused "$refused"
    if [ "$refused" -lt "$MC_KICK_REOPEN_TRIES" ]; then
      head_lag_put "$key" "$head" "$tip" "$since" 0 0 - "$refused"
      mc_log "$key HEAD_LAG close refused on ${head:0:8} (HTTP refusal $refused of $MC_KICK_REOPEN_TRIES) — nothing changed on GitHub; a later tick tries again: $url"
      return 1
    fi
    now=$(mc_now)
    head_lag_put "$key" "$head" "$tip" "$since" "$now" 0 refused "$refused"
    head_lag_note "$key" "$tip" gaveup "$now"
    mc_log "$key HEAD_LAG close refused $refused times on ${head:0:8} — the PR was NOT closed or reopened; given up for this tip, a lag that persists pages once: $url"
    return 1
  fi
  return 0
}

# head_lag_after_kick — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# head_lag_after_kick — the reopen is spent; a lag that outlives it by the
#   window is written to ALERTS once, saying what actually happened, and then
#   the lane is quiet about this tip. `closed` has already paged (LEFT CLOSED).
head_lag_after_kick() {
  local key="$1" url="$2" head="$3" tip="$4" since="$5" spent="$6" alerted="$7" mins="$8" outcome="$9" refused="${10:-0}" m what
  m=$(( ($(mc_now) - spent) / 60 ))
  [ "$alerted" = 0 ] && [ "$m" -ge "$mins" ] || return 0
  case "$outcome" in
    reopened) what="${m}m after one close/reopen — GitHub has not synced the PR" ;;
    refused)  what="and GitHub refused the close $refused times, so it was never closed or reopened" ;;
    pending)  what="${m}m after a close/reopen that did not report back — check the PR is open" ;;
    *)        return 0 ;;
  esac
  head_lag_put "$key" "$head" "$tip" "$since" "$spent" 1 "$outcome" "$refused"
  head_lag_note "$key" "$tip" alerted
  mc_alert "$key" HEAD_LAG "head ${head:0:8} still lags the branch tip ${tip:0:8} $what; push an empty commit or close and reopen it by hand: $url"
  mc_log "$key HEAD_LAG_PERSISTS on ${tip:0:8} (kick outcome: $outcome) — alerted once"
}
