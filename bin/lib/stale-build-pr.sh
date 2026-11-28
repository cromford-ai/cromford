#!/bin/bash
# shellcheck shell=bash
# bin/lib/stale-build-pr.sh — open the PR from a dead build's branch (BH-9484,
# item 5 of #9406). Sourced by bin/stale-build-reaper.sh, never run: no `set`,
# no `exit`, nothing runs at source time but definitions.
#
#   sbp_decide <project> <key> <bkey>                 read only; rc 0 = would-open
#   sbp_open   <project> <key> <stage> <bkey> <outfile>  rc 0 = opened
#
# The caller MUST run both in a subshell. sbp_open sets the globals the item 3
# functions read (P KEY TICKET LOCAL POOL_SLUG ...), it arms a GitHub token,
# and bin/lib/merge-conductor-lib.sh, which the hand-off can load, may `exit`
# at source time. A subshell keeps all of that out of the reaper.
#
# OUTCOME WORDS. sbp_decide sets SBP_OUT to one line; sbp_open writes one line
# to <outfile>:
#   would-open <br> head=<sha12> ahead=<n> behind=<n>   (sbp_decide, rc 0)
#   opened <url> rebase=<word> review=<word>            the PR is open (rc 0)
#   none <why>      no repo slug, no branch, a PR in any state, no commits
#                   ahead, a wip branch, a spec-only branch, or a tip older
#                   than the build
#   unknown <why>   a read did not answer, a page was cut, the bkey names no
#                   build start: nothing opens (fail closed)
#   held <why>      a HOLD on the ticket, or the hold did not read
#   failed <why>    the PR create, or the step itself, did not finish
# sbp_open writes `opened <url> rebase=pending review=pending` as soon as the
# create returned a URL, BEFORE the hand-off. A hand-off that dies still leaves
# the PR recorded, and the reaper reads that line as opened.
#
# THE BRANCH. The newest of ticket/<key-lower> (N=1) and
# ticket/<key-lower>-r<N> (N all digits), from GET git/matching-refs. The
# prefix match also returns ticket/<key-lower>1..., which is dropped.
#
# FINISHED WORK ONLY. A `wip:` commit anywhere on the branch is `none wip`: the
# lane died mid-execute, and the checkpoint adopt resumes it on a rebuild. A
# branch whose every commit is `spec(<KEY>):`, or whose every file is under
# .harness/specs/, is `none spec only`: item 6 (slice C2) owns it.
#
# THE TIP-AGE RULE. The build start is the YYYYMMDDHHMM (UTC) at the end of the
# build dir in the bkey (build:<p>:<KEY>:<dir>). The committer date of the
# branch tip must be at or after it. An older tip is an earlier build's
# leftover, not this build's work, and opens nothing.
#
# THE OPEN is the item 3 path, reused, not copied: hold_push_verdict,
# ppr_title, ppr_plan_from_branch, gh_pr_create_ladder, then ppr_after_reap
# (bin/lib/pool-push-rejected.sh): ppr_rebase_behind queues the conductor's
# pool rebase when the branch is behind main, and ppr_review_handoff
# (bin/lib/ppr-review.sh) asks for the lead review and sends the pr_created
# beat, keyed by the dead build's own bkey.
#
# Globals in: HARNESS, say (the reaper's), SBP_TIMEOUT_S (the reaper sets it
# from the settings row STALE_REAPER_HTTP_TIMEOUT_S). The harness root is
# ${HARNESS:-${H:-}} only; with none, sbp_decide answers `unknown` and builds no
# path.

SBP_H=""; SBP_OUT=""; SBP_BR=""; SBP_SHA=""; SBP_AHEAD=""; SBP_BEHIND=""; SBP_SLUG=""; SBP_TOK=""; SBP_TIP=""

# GitHub caps, not business limits: a compare lists at most 250 commits and
# 300 files. They are used only to detect a cut page.
SBP_GH_COMMITS_CAP=250
SBP_GH_FILES_CAP=300

declare -F say >/dev/null || say() { :; }

# sbp_rest <api-path> [token] — line 1 = HTTP code (empty if none, TIMEOUT if
# the read was cut at SBP_TIMEOUT_S), the rest = body. The contract of the pool
# reap's pool_rest_read (bin/fly-pool.sh).
sbp_rest() {
  local _path="$1" _tok="${2:-}" _raw="" _to=() _rc=0
  # Fallback 20 s; the reaper sets SBP_TIMEOUT_S from the row STALE_REAPER_HTTP_TIMEOUT_S.
  local _lim="${SBP_TIMEOUT_S:-20}"
  case "$_lim" in ''|*[!0-9]*) _lim=20 ;; esac
  if [ "$_lim" -gt 0 ] && command -v timeout >/dev/null 2>&1; then _to=(timeout "$_lim"); fi
  if [ -n "$_tok" ]; then _raw=$(GH_TOKEN="$_tok" "${_to[@]}" gh api -i "$_path" 2>/dev/null); _rc=$?
  else _raw=$("${_to[@]}" gh api -i "$_path" 2>/dev/null); _rc=$?; fi
  if [ "$_rc" = 124 ] || [ "$_rc" = 137 ]; then printf 'TIMEOUT\n'; return 0; fi
  awk 'NR==1 && $0 ~ /^HTTP\// {sub(/\r$/, ""); print $2; next}
       NR==1 {print ""}
       f {print}
       /^\r?$/ {f=1}' <<<"$_raw"
}

# The ppr functions (ppr_title, ppr_plan_from_branch, pprr_head,
# pprr_migration_check) read through pool_rest_read. Outside bin/fly-pool.sh it
# is not defined, so it is this lib's reader.
command -v pool_rest_read >/dev/null 2>&1 || pool_rest_read() { sbp_rest "$@"; }

# sbp_ppr_load — the item 3 lib (ppr_lib, ppr_title, ppr_after_reap ...).
sbp_ppr_load() {
  command -v ppr_after_reap >/dev/null 2>&1 && return 0
  # shellcheck source=bin/lib/pool-push-rejected.sh
  [ -n "$SBP_H" ] || return 1
  . "$SBP_H/bin/lib/pool-push-rejected.sh" 2>/dev/null
  command -v ppr_after_reap >/dev/null 2>&1
}

# sbp_issues <project> — rc 0 when the project's tickets are GitHub issues.
# The tracker seam decides (bin/lib/tracker.sh tracker_kind: the
# tracker_adapter.<p> settings row, fleet.conf column 4 as its fallback). A
# kind that does not resolve is not issues, the old column-4 answer for an
# unknown project.
sbp_issues() {
  local p="${1:-}" kind=""
  if ! declare -F tracker_kind >/dev/null; then
    [ -n "$SBP_H" ] && [ -r "$SBP_H/bin/lib/tracker.sh" ] || return 1
    # shellcheck source=bin/lib/tracker.sh
    . "$SBP_H/bin/lib/tracker.sh" 2>/dev/null || return 1
  fi
  kind=$(HARNESS="${HARNESS:-$SBP_H}" tracker_kind "$p" 2>/dev/null) || return 1
  [ "$kind" = github-issues ]
}

# sbp_build_start <bkey> — epoch of the build dir's YYYYMMDDHHMM (UTC). rc 1
# and nothing printed when the bkey is not build:<p>:<KEY>:<dir> with that tail.
sbp_build_start() {
  local d ts
  d=$(printf '%s' "${1:-}" | cut -d: -f4)
  case "${1:-}" in build:*:*:?*) ;; *) return 1 ;; esac
  ts="${d##*-}"
  [ "$ts" != "$d" ] && [[ "$ts" =~ ^[0-9]{12}$ ]] || return 1
  date -u -d "${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:8:2}:${ts:10:2}" +%s 2>/dev/null
}

sbp_decide() {
  local p="${1:-}" k="${2:-}" bkey="${3:-}" start kl stem out code body pick cmp
  local ncm nfiles subj any_wip=0 all_spec_subj=1 all_spec_files=1 f tipd tip
  SBP_OUT=""; SBP_BR=""; SBP_SHA=""; SBP_AHEAD=""; SBP_BEHIND=""; SBP_SLUG=""; SBP_TOK=""; SBP_TIP=""
  SBP_H="${HARNESS:-${H:-}}"
  # a. the build start, from the bkey. No GitHub call on this path.
  start=$(sbp_build_start "$bkey") || start=""
  [[ "$start" =~ ^[0-9]+$ ]] || { SBP_OUT="unknown no build start in bkey $bkey"; return 1; }
  [ -n "$p" ] && [ -n "$k" ] || { SBP_OUT="unknown no project or key"; return 1; }
  [ -n "$SBP_H" ] || { SBP_OUT="unknown no harness root"; return 1; }
  sbp_ppr_load || { SBP_OUT="unknown bin/lib/pool-push-rejected.sh is missing"; return 1; }
  # b. the repo
  SBP_SLUG=$("$SBP_H/bin/fleet-conf.sh" "$p" repo 2>/dev/null)
  case "$SBP_SLUG" in [A-Za-z0-9]*/[A-Za-z0-9]*) ;; *) SBP_OUT="none no repo slug for $p"; SBP_SLUG=""; return 1 ;; esac
  # c. the token that can see the repo (the pool_slug_token_arm shape). No
  #    token lib: ambient auth.
  command -v gh_repo_use_token >/dev/null 2>&1 || ppr_lib gh-repo-token.sh >/dev/null 2>&1 || true
  if command -v gh_repo_use_token >/dev/null 2>&1; then
    if gh_repo_use_token "$SBP_SLUG" >/dev/null 2>&1; then SBP_TOK="${GH_TOKEN:-}"; fi
    gh_repo_token_reset >/dev/null 2>&1 || true
  fi
  # d. the newest branch of this key
  kl=$(printf '%s' "$k" | tr '[:upper:]' '[:lower:]')
  stem="ticket/$kl"
  out=$(sbp_rest "repos/$SBP_SLUG/git/matching-refs/heads/$stem" "$SBP_TOK")
  code=$(head -n 1 <<<"$out"); body=$(tail -n +2 <<<"$out")
  [ "$code" = 200 ] || { SBP_OUT="unknown refs ${code:-none}"; return 1; }
  pick=$(jq -r --arg s "$stem" '
    if type != "array" then "ERR" else
    [ .[] | ((.ref // "") | sub("^refs/heads/"; "")) as $b | (.object.sha // "") as $sha
      | if $b == $s then {b: $b, n: 1, sha: $sha}
        elif ($b | startswith($s + "-r")) and ($b[($s | length) + 2:] | test("^[0-9]+$"))
        then {b: $b, n: ($b[($s | length) + 2:] | tonumber), sha: $sha}
        else empty end ]
    | sort_by(.n) | last | if . == null then "" else "\(.b)\t\(.sha)" end end' <<<"$body" 2>/dev/null) || pick=ERR
  [ "$pick" = ERR ] && { SBP_OUT="unknown refs answer is not a list"; return 1; }
  [ -n "$pick" ] || { SBP_OUT="none no branch"; return 1; }
  SBP_BR="${pick%%$'\t'*}"; SBP_SHA="${pick#*$'\t'}"
  [[ "$SBP_SHA" =~ ^[0-9a-f]{40}$ ]] || { SBP_OUT="unknown head of $SBP_BR"; return 1; }
  # e. any PR on the branch, in any state (a closed one is a person's decision)
  out=$(sbp_rest "repos/$SBP_SLUG/pulls?state=all&head=${SBP_SLUG%%/*}:$SBP_BR" "$SBP_TOK")
  code=$(head -n 1 <<<"$out"); body=$(tail -n +2 <<<"$out")
  [ "$code" = 200 ] || { SBP_OUT="unknown pulls ${code:-none}"; return 1; }
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$body" || { SBP_OUT="unknown pulls answer is not a list"; return 1; }
  f=$(jq -r 'if length > 0 then (.[0].html_url // "a PR") else "" end' <<<"$body")
  [ -z "$f" ] || { SBP_OUT="none PR exists $f"; return 1; }
  # f. the compare with main, read in full, or nothing opens
  out=$(sbp_rest "repos/$SBP_SLUG/compare/main...$SBP_BR" "$SBP_TOK")
  code=$(head -n 1 <<<"$out"); cmp=$(tail -n +2 <<<"$out")
  [ "$code" = 200 ] || { SBP_OUT="unknown compare http=${code:-none}"; return 1; }
  SBP_AHEAD=$(jq -r '.ahead_by // empty' <<<"$cmp" 2>/dev/null)
  SBP_BEHIND=$(jq -r '.behind_by // empty' <<<"$cmp" 2>/dev/null)
  ncm=$(jq -r '.commits | if type == "array" then length else empty end' <<<"$cmp" 2>/dev/null)
  [[ "$SBP_AHEAD" =~ ^[0-9]+$ ]] && [[ "$SBP_BEHIND" =~ ^[0-9]+$ ]] && [[ "$ncm" =~ ^[0-9]+$ ]] \
    || { SBP_OUT="unknown compare answer"; return 1; }
  # GitHub lists at most SBP_GH_COMMITS_CAP commits: ahead_by above the list is a cut page.
  [ "$SBP_AHEAD" = "$ncm" ] && [ "$ncm" -le "$SBP_GH_COMMITS_CAP" ] \
    || { SBP_OUT="unknown compare cut (ahead_by=$SBP_AHEAD, $ncm commits listed)"; return 1; }
  [ "$SBP_AHEAD" -gt 0 ] || { SBP_OUT="none no commits ahead of main"; return 1; }
  # g. finished work only
  while IFS= read -r subj; do
    case "$subj" in
      wip:*) any_wip=1 ;;
      "spec($k):"*) ;;
      *) all_spec_subj=0 ;;
    esac
  done < <(jq -r '.commits[] | (.commit.message // "") | split("\n")[0]' <<<"$cmp")
  [ "$any_wip" = 0 ] || { SBP_OUT="none wip on branch ($SBP_BR): the checkpoint adopt resumes it"; return 1; }
  [ "$all_spec_subj" = 0 ] || { SBP_OUT="none spec only ($SBP_BR)"; return 1; }
  nfiles=$(jq -r '.files | if type == "array" then length else 0 end' <<<"$cmp" 2>/dev/null)
  [[ "$nfiles" =~ ^[0-9]+$ ]] || nfiles=0
  # At SBP_GH_FILES_CAP files the list may be cut, so the file rule is not used.
  if [ "$nfiles" -gt 0 ] && [ "$nfiles" -lt "$SBP_GH_FILES_CAP" ]; then
    while IFS= read -r f; do
      case "$f" in .harness/specs/*) ;; *) all_spec_files=0 ;; esac
    done < <(jq -r '.files[] | (.filename // "")' <<<"$cmp")
    [ "$all_spec_files" = 0 ] || { SBP_OUT="none spec only ($SBP_BR)"; return 1; }
  fi
  # h. the tip must be this build's work, not an earlier build's leftover
  tipd=$(jq -r '.commits[-1].commit.committer.date // empty' <<<"$cmp" 2>/dev/null)
  tip=""; [ -n "$tipd" ] && tip=$(date -u -d "$tipd" +%s 2>/dev/null)
  [[ "$tip" =~ ^[0-9]+$ ]] || { SBP_OUT="unknown tip date"; return 1; }
  SBP_TIP="$tipd"
  [ "$tip" -ge "$start" ] || { SBP_OUT="none branch tip $tipd is older than build $(printf '%s' "$bkey" | cut -d: -f4)"; return 1; }
  # i. pass
  SBP_OUT="would-open $SBP_BR head=${SBP_SHA:0:12} ahead=$SBP_AHEAD behind=$SBP_BEHIND"
  return 0
}

# sbp_body <file> <title> <stage> — the PR body.
sbp_body() {
  local f="$1" t="${2:-}" st="${3:-}" why=""
  if [ -f "$LOCAL/plan.md" ]; then
    why=$(awk '/^## Why/ {on=1; next} on && /^## / {exit} on {print}' "$LOCAL/plan.md" | grep -v '^$' | head -8 | head -c 900)
    [ -n "$why" ] || why=$(awk 'NR==1{next} /^## /{exit} {print}' "$LOCAL/plan.md" | grep -v '^$' | head -8 | head -c 900)
  fi
  t="${t#"$KEY: "}"
  {
    printf 'Ticket %s — %s\n' "$KEY" "${t:-build of $PPR_BR}"
    [ -n "${TICKET:-}" ] && printf 'Closes #%s\n' "$TICKET"
    printf '\n## Why\n\n%s\n\n' "${why:-The branch carries no .harness/specs/$KEY/plan.md that read.}"
    printf '## Opened by the stale-build reaper\n\n'
    printf 'The build of %s died in %s and wrote no PR. Its branch `%s` is at `%s` and holds %s commit(s) that main does not have. bin/stale-build-reaper.sh opened this PR from the branch as it stands.\n\n' \
      "$KEY" "${st:-an unknown stage}" "$PPR_BR" "$PPR_REMOTE" "${SBP_AHEAD:-?}"
    printf 'This PR still needs its lead review. The reaper asks for it next.\n\n'
    printf '🤖 Generated with [Claude Code](https://claude.com/claude-code)\n'
  } > "$f"
}

# sbp_done <rc> — remove the LOCAL dir and return <rc>.
sbp_done() {
  [ -n "${LOCAL:-}" ] && [ -d "$LOCAL" ] && rm -rf "$LOCAL"
  return "$1"
}

sbp_open() {
  local p="${1:-}" k="${2:-}" st="${3:-}" bkey="${4:-}" of="${5:-/dev/null}"
  local issues=0 v vrc title bf url rb rv bdir rbnote=""
  if ! sbp_decide "$p" "$k" "$bkey"; then printf '%s\n' "$SBP_OUT" > "$of"; return 1; fi
  sbp_issues "$p" && issues=1
  # a. the HOLD, read now: a person who typed HOLD gets no PR
  if ! command -v hold_push_verdict >/dev/null 2>&1 && ! ppr_lib hold-push.sh >/dev/null 2>&1; then
    printf 'held bin/lib/hold-push.sh is missing\n' > "$of"; return 1
  fi
  v=$(GH_TOKEN="${SBP_TOK:-${GH_TOKEN:-}}" hold_push_verdict "$p" - "$SBP_BR" 2>/dev/null); vrc=$?
  v=$(head -n 1 <<<"$v" | tr '\t' ' ')
  case "$vrc" in
    0) ;;
    1) printf 'held a HOLD on the ticket (%s)\n' "$v" > "$of"; return 1 ;;
    *) printf 'held the hold did not read (%s)\n' "$v" > "$of"; return 1 ;;
  esac
  # b. the create ladder
  if ! command -v gh_pr_create_ladder >/dev/null 2>&1 && ! ppr_lib gh-pr-create.sh >/dev/null 2>&1; then
    printf 'failed bin/lib/gh-pr-create.sh is missing\n' > "$of"; return 1
  fi
  # c. the globals the ppr functions read
  P="$p"; KEY="$k"; TICKET=""; PPR_ISSUES="$issues"
  if [ "$issues" = 1 ] && [[ "$k" =~ ^[A-Za-z][A-Za-z0-9]*-([0-9]+)$ ]]; then TICKET="${BASH_REMATCH[1]}"; fi
  POOL_SLUG="$SBP_SLUG"; POOL_SLUG_TOK="$SBP_TOK"; PPR_BR="$SBP_BR"; PPR_REMOTE="$SBP_SHA"
  # The step f read is compare/main...<branch>, the read ppr_behind_main makes: no second read.
  PPR_BEHIND="$SBP_BEHIND"
  LOCAL=$(mktemp -d "${TMPDIR:-/tmp}/sbp-local.XXXXXX") || { printf 'failed mktemp\n' > "$of"; return 1; }
  bdir=$(printf '%s' "$bkey" | cut -d: -f4-)
  printf 'BUILD_DIR: %s\n' "$bdir" > "$LOCAL/RESULT"   # pprr_beat beats the dead build's own bkey
  # d. title, plan, body, trailers
  title=$(ppr_title)
  ppr_plan_from_branch
  bf="$LOCAL/pr-body.md"
  sbp_body "$bf" "$title" "$st"
  if command -v pr_trailers_apply >/dev/null 2>&1 || ppr_lib pr-trailers.sh >/dev/null 2>&1; then
    pr_trailers_apply "$bf" none "$KEY" >/dev/null 2>&1 || true
  fi
  # e. open. GH_REPO points rung graphql (gh pr create, cwd-scoped) at the repo.
  url=$(GH_REPO="$SBP_SLUG" GH_TOKEN="${SBP_TOK:-${GH_TOKEN:-}}" gh_pr_create_ladder "$SBP_SLUG" "$SBP_BR" main "$title" "$bf" \
          "$LOCAL/gh-stderr.log" "$LOCAL/pipeline.log" "stale-reaper/$p/$k" 2>/dev/null)
  url=$(head -n 1 <<<"$url")
  case "$url" in
    https://github.com/*/*/pull/[0-9]*) ;;
    *) printf 'failed every PR create rung (%s)\n' "$(tail -c 200 "$LOCAL/gh-stderr.log" 2>/dev/null | tr '\n' ' ')" > "$of"
       sbp_done 1; return 1 ;;
  esac
  # f. record the PR at once, before the hand-off
  printf 'opened %s rebase=pending review=pending\n' "$url" > "$of"
  say "stale-build-pr $KEY: opened $url from $SBP_BR (head $SBP_SHA, ahead $SBP_AHEAD, behind $SBP_BEHIND)"
  # g. the conductor lib can `exit 1` at source time (bin/lib/merge-conductor-lib.sh).
  #    ppr_rebase_behind loads it only for a branch behind main, so probe it then.
  if [ "${SBP_BEHIND:-0}" != 0 ] && ! ( . "$SBP_H/bin/lib/merge-conductor-lib.sh" ) >/dev/null 2>&1; then
    POOL_PUSH_LANDED_REBASE=0; rbnote=not-queued
    say "stale-build-pr $KEY: rebase=not-queued, the conductor lib did not load — land_rebase_arm still owns $url"
  fi
  # h. the item 3 hand-off: pool rebase when behind, lead review, pr_created beat
  PPR_PR_URL="$url"; PPR_PR_KEY="$KEY"; PPR_PR_BASE=main
  ppr_after_reap || true
  # i. the outcome
  rb=$(awk 'NR==1{print $1}' "$LOCAL/prepr-rebase.txt" 2>/dev/null)
  rv=$(awk 'NR==1{print $1}' "$LOCAL/review-request.txt" 2>/dev/null)
  printf 'opened %s rebase=%s review=%s\n' "$url" "${rbnote:-${rb:-none}}" "${rv:-none}" > "$of"
  sbp_done 0
}
