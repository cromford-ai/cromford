#!/bin/bash
# bin/lib/issue-state-lib.sh — "is this issue still open", and what happens to
# the `ai-build` label when a harness merge closes it. (BH-637 §3)
#
# `ai-build` is the handoff: every selector in the fleet reads it, and nothing
# took it off when a merge closed the issue, so the label outlived the work and
# kept offering it — each re-offer a full build on a pool machine, spent
# rebuilding something already shipped. The ticket asks for BOTH halves and is
# explicit that one is not enough: (a) the enqueue reads the issue's LIVE state
# and refuses a closed one, because humans close issues too and the label would
# still be lying; (b) the merge paths strip the label as they close.
# (a) is issue_is_closed, called once at the funnel every launcher passes
# through (bin/run-build.sh). (b) is issue_close_shipped, called by all four
# places in this harness that close an issue after a merge.
#
# Sourced, never executed. Safe under `set -u`. The state read needs no jq — a
# box without jq must still be able to answer "is this closed".
#
# FAIL-OPEN IS "BUILD IT". Every uncertain answer — no gh, a dead token, a rate
# limit, a state word that is neither OPEN nor CLOSED — is UNKNOWN, and every
# caller treats UNKNOWN as today's behaviour. A wrong UNKNOWN costs one wasted
# build; failing closed on a dead token refuses every build in the fleet.
# The one exception is issue_close_guard (BH-2477), which gates a CLOSE rather
# than a build: there an uncertain answer defers the close, because closing an
# issue a merge only sliced is the error it exists to stop.
#
# The long-form operator notes (knobs, log words, live-box checks) live in
# docs/verification-map/closed-issue-hygiene.md, not here.

# App-token arming (tests/gh-app-ratchet-test.sh). Sourced guarded, so a box
# whose sync has not landed gh-app-auth.sh yet runs exactly as before. Every gh
# call below is armed INSIDE its own $(...) — the token never reaches the
# caller's shell, so a lane running on the PAT keeps its identity afterwards.
# With no HARNESS/H it is not sourced at all (BH-2650): that lib would bind its
# own literal root at source time, and the gh calls run on the caller's token.
# shellcheck source=bin/lib/gh-app-auth.sh
command -v gh_auth_for >/dev/null 2>&1 || [ -z "${HARNESS:-${H:-}}" ] \
  || { [ -r "$(dirname "${BASH_SOURCE[0]}")/gh-app-auth.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/gh-app-auth.sh"; }
_issue_arm() { command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "${1:-}"; return 0; }

# REST primitives for the close-out reads. Guarded so a tree that has not yet
# landed gh-rest.sh fails safe: issue_state answers UNKNOWN (build as today) and
# issue_close_shipped answers close-failed rc 1 (nothing was closed, so no
# caller may log it as closed).
# shellcheck source=bin/lib/gh-rest.sh
command -v gh_rest >/dev/null 2>&1 \
  || { [ -r "$(dirname "${BASH_SOURCE[0]}")/gh-rest.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/gh-rest.sh"; }

# BH-5961: the remainder filer for a SLICE plan with no open child. Guarded:
# a tree without it runs the no-children path exactly as before.
# shellcheck source=bin/lib/slice-remainder.sh
command -v slice_remainder_settle >/dev/null 2>&1 \
  || { [ -r "$(dirname "${BASH_SOURCE[0]}")/slice-remainder.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/slice-remainder.sh"; }
# BH-6308: with no open child, close a parent the merged slices delivered, or
# file the rest as one child and close it. Guarded the same way.
# shellcheck source=bin/lib/slice-closeout.sh
command -v sco_settle >/dev/null 2>&1 \
  || { [ -r "$(dirname "${BASH_SOURCE[0]}")/slice-closeout.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/slice-closeout.sh"; }

# _issue_env <harness> <VAR> <default> -> the value
#   Environment first, then env/global.env, then the default. READS the env file
#   rather than sourcing it, exactly as bin/lib/hotfix-lib.sh:_hotfix_env does:
#   a predicate answering a yes/no question must not inherit a box's secrets to
#   answer it. Reading by FILE is also required, not cosmetic — the skip block
#   runs near the top of bin/run-build.sh, hundreds of lines before that script
#   sources env/global.env, so an env-only knob would be invisible where it acts.
_issue_env() {
  local h="${1:-}" var="${2:-}" def="${3:-}" v=""
  eval "v=\${$var:-}"
  if [ -z "$v" ] && [ -n "$h" ] && [ -r "$h/env/global.env" ]; then
    v=$(sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$var=//p" "$h/env/global.env" \
        | tr -d '"'"'"' \t' | tail -1)
  fi
  [ -n "$v" ] || v="$def"
  printf '%s\n' "$v"
}

# _issue_switch <harness> <VAR> <flag-file> -> 1 on | 0 off   (DEFAULT 1)
#   The kill-switch shape the rest of this harness uses: an env var and a file
#   under flags/, because an operator switching a lane off at 3am should not
#   have to edit env/global.env on every box.
_issue_switch() {
  local h="${1:-${HARNESS:-${H:-}}}" var="${2:-}" flag="${3:-}" v
  [ -n "$h" ] && [ -n "$flag" ] && [ -e "$h/flags/$flag" ] && { printf '0\n'; return 0; }
  v=$(_issue_env "$h" "$var" 1)
  case "$v" in 0|no|off|false) printf '0\n' ;; *) printf '1\n' ;; esac
}

# issue_memo_file <dir> <repo-slug> <issue-number> -> the path of the issue
#   memo for that (repo, issue) under <dir>; rc 1 and nothing printed when an
#   argument is missing. (BH-1735) One build enqueue needs the same issue twice:
#   the closed-issue skip below and run-build's created-at stamp. The skip's
#   read keeps the JSON here and the stamp is served from it, so the issue is
#   read ONCE. The slug is lowercased (GitHub's are case-insensitive) and its
#   `/` becomes `+`, a character no owner or repo name can hold, so two repos
#   or two numbers never share a file.
issue_memo_file() {
  local dir="${1:-}" repo="${2:-}" n="${3:-}"
  [ -n "$dir" ] && [ -n "$repo" ] && [ -n "$n" ] || return 1
  repo=$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')
  printf '%s/issue-memo.%s.%s.json\n' "$dir" "${repo//\//+}" "$n"
}

# issue_state <repo-slug> <issue-number> [harness] [memo-file] -> prints OPEN or CLOSED
#   rc 0 — the word on stdout is GitHub's answer.
#   rc 2 — UNKNOWN: no repo, no number, a non-numeric number, no gh, a call that
#          exited nonzero (EVEN IF it printed a payload — a rate-limited or
#          half-written response is a failure, not data), or any other word.
#   There is deliberately no rc 1: this function either knows or it does not.
#   With [memo-file] (BH-1735, from issue_memo_file) the SAME one GET keeps the
#   whole issue JSON there, written tmp + mv, but ONLY on an rc 0 answer. The
#   file is removed before the read, so whatever a consumer finds is this call's
#   answer and never an earlier run's: a failed read leaves no memo at all.
issue_state() {
  local repo="${1:-}" n="${2:-}" h="${3:-${HARNESS:-${H:-}}}" memo="${4:-}" out
  : "$h"
  [ -n "$memo" ] && rm -f "$memo" 2>/dev/null
  [ -n "$repo" ] && [ -n "$n" ] || return 2
  case "$n" in *[!0-9]*|'') return 2 ;; esac
  command -v gh_rest_issue_state >/dev/null 2>&1 || return 2
  # A memo dir that cannot be written takes the plain read: keeping the body is
  # an economy, and it must never turn a readable state into UNKNOWN.
  if [ -n "$memo" ] && [ -d "${memo%/*}" ] && [ -w "${memo%/*}" ] && command -v gh_rest >/dev/null 2>&1; then
    # gh_rest_issue_state's own read (_gh_rest_field), with the body kept. The
    # memo is written inside the armed subshell, so the token stays in there.
    out=$(_issue_arm "$repo"
          t="$memo.tmp.$BASHPID"
          gh_rest GET "repos/$repo/issues/$n" > "$t" 2>/dev/null || { rm -f "$t"; exit 2; }
          s=$(jq -er '.state' "$t" 2>/dev/null) && [ -n "$s" ] || { rm -f "$t"; exit 2; }
          case "$s" in open|closed) mv -f "$t" "$memo" 2>/dev/null || rm -f "$t" ;; *) rm -f "$t" ;; esac
          printf '%s\n' "$s") || return 2
  else
    out=$(_issue_arm "$repo"; gh_rest_issue_state "$repo" "$n" 2>/dev/null) || return 2
  fi
  out=$(printf '%s' "$out" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
  case "$out" in
    OPEN|CLOSED) printf '%s\n' "$out"; return 0 ;;
    *)           return 2 ;;
  esac
}

# issue_is_closed <repo-slug> <issue-number> [harness] [memo-file]
#   rc 0 — CLOSED: the caller must refuse whatever it was about to do.
#   rc 1 — OPEN, or the check is switched off.
#   rc 2 — UNKNOWN: the caller proceeds as it did before this lib existed.
# SKIP_CLOSED=0 (env or env/global.env) and flags/skip-closed-off both answer
# rc 1 for everything and make no GitHub call at all (and so write no memo).
# [memo-file] is handed to issue_state unchanged (BH-1735).
issue_is_closed() {
  local repo="${1:-}" n="${2:-}" h="${3:-${HARNESS:-${H:-}}}" memo="${4:-}" st rc
  [ "$(_issue_switch "$h" SKIP_CLOSED skip-closed-off)" = 1 ] || return 1
  st=$(issue_state "$repo" "$n" "$h" "$memo"); rc=$?
  [ "$rc" = 0 ] || return 2
  [ "$st" = CLOSED ] && return 0
  return 1
}

# _issue_labels_has <json> <label> -> rc 0 when the label is present.
#   WHOLE-NAME, case-insensitive, trimmed — the same rule
#   bin/lib/hotfix-lib.sh:hotfix_labels_json_has applies, and for the same
#   reason: `ai-build-later` is a different label, and a substring match would
#   strip one off an issue nobody asked about.
_issue_labels_has() {
  local json="${1:-}" want="${2:-}"
  [ -n "$json" ] && [ -n "$want" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  want=$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')
  printf '%s' "$json" | jq -e --arg l "$want" '
      (if type == "object" then (.labels // []) else . end)
      | (if type == "array" then . else [] end)
      | map(if type == "object" then (.name // "") else (. | tostring) end)
      | map(ascii_downcase | gsub("^[[:space:]]+|[[:space:]]+$"; ""))
      | index($l) != null' >/dev/null 2>&1
}

# _issue_comment <repo> <n> <body> -> rc 0 posted | 1 not (ISSUE_CLOSE_ERR set)
#   The body goes by file so it never reaches argv or a process listing. Removed
#   explicitly, not by a RETURN trap: a RETURN trap set in a function stays
#   installed in the caller's shell after it returns.
_issue_comment() {
  local repo="${1:-}" n="${2:-}" f out
  f=$(mktemp "${TMPDIR:-/tmp}/issue-close.XXXXXX") || { ISSUE_CLOSE_ERR="mktemp failed"; return 1; }
  printf '%s\n' "${3:-}" > "$f"
  if ! out=$(_issue_arm "$repo"; gh_rest_comment "$repo" "$n" "$f" 2>&1 >/dev/null); then
    ISSUE_CLOSE_ERR="${out:-gh-rest comment failed}"; rm -f "$f"; return 1
  fi
  rm -f "$f"; return 0
}

# issue_close_guard <repo-slug> <issue> <pr-url> [record-dir] [harness] -> ONE word, rc 0
#   Did this merge DELIVER the issue, or only a slice of it? (BH-2477: #2320 was
#   closed by the merge of C0, its first slice, while C1..C6 were open.)
#     close                        all three checks passed
#     slice:plan                   <record>/plan.md has a line STARTING with the
#                                  planner's `SLICE: C<k> of #<n>` for THIS issue
#                                  (BH-2508), or the older sentence "The build for
#                                  THIS ticket is C<k>" from plans written before it
#                                  (bold/quote markup allowed; mid-line quotes are not it)
#     slice:no-keyword             the PR body has no GitHub closing keyword for
#                                  THIS issue (Closes/Fixes/Resolves and their
#                                  tenses, `#n`, `<slug>#n` or the issue URL)
#     slice:open-children:#a,#b    the issue timeline cross-references OPEN
#                                  issues whose body has a line `Part of #n`
#                                  (bin/run-decompose.sh) or `Child **C<k>** of #n`
#     unknown:<what>               a read failed, did not parse, or the timeline
#                                  was still full at ISSUE_CLOSE_GUARD_PAGES (default 5)
#   Checked in that order (local, then one read, then the paged read), stopping
#   at the first slice. AN UNKNOWN IS NOT A CLOSE: unlike issue_state above, this
#   answer gates an irreversible client-visible write, and a wrong close is the
#   defect it exists for. GitHub's own keyword close at merge still closes a
#   `Closes` PR's issue whatever this says.
issue_close_guard() {
  local slug="${1:-}" n="${2:-}" pr="${3:-}" rec="${4:-}" h="${5:-${HARNESS:-${H:-}}}"
  local prslug prn out body esc kw kids
  [ -n "$slug" ] && [ -n "$n" ] || { printf 'unknown:args\n'; return 0; }
  case "$n" in *[!0-9]*) printf 'unknown:args\n'; return 0 ;; esac
  if [ -n "$rec" ] && [ -r "$rec/plan.md" ] \
     && grep -qE "^[[:space:]*_>]*(SLICE:[[:space:]*_]*C[0-9]+[[:space:]]+of[[:space:]]+#$n([^0-9]|\$)|The build for THIS ticket is C[0-9]+)" "$rec/plan.md" 2>/dev/null; then
    printf 'slice:plan\n'; return 0
  fi
  [[ "$pr" =~ ^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([0-9]+)/?$ ]] \
    || { printf 'unknown:pr-url\n'; return 0; }
  prslug="${BASH_REMATCH[1]}"; prn="${BASH_REMATCH[2]}"
  command -v jq >/dev/null 2>&1 || { printf 'unknown:no-jq\n'; return 0; }
  command -v gh_rest >/dev/null 2>&1 || { printf 'unknown:no-gh-rest\n'; return 0; }
  out=$(_issue_arm "$prslug"; gh_rest GET "repos/$prslug/pulls/$prn" 2>/dev/null) \
    || { printf 'unknown:pr-read\n'; return 0; }
  # A null body is an empty description ("no keyword"), not an unreadable PR.
  body=$(printf '%s' "$out" | jq -er 'if type == "object" then (.body // "") else error("not a pull") end' 2>/dev/null) \
    || { printf 'unknown:pr-unparseable\n'; return 0; }
  esc="${slug//./\\.}"   # a slug is [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+: only the dot is special
  kw="(^|[^[:alnum:]_])(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved):?[[:space:]]+(#|$esc#|https://github\\.com/$esc/issues/)$n([^0-9]|\$)"
  printf '%s\n' "$body" | tr -d '\r' | grep -qiE "$kw" || { printf 'slice:no-keyword\n'; return 0; }
  kids=$(_issue_open_children "$slug" "$n" "$h") || { printf 'unknown:%s\n' "${kids#ERR:}"; return 0; }
  if [ -n "$kids" ]; then
    printf 'slice:open-children:%s\n' "$kids"
    return 0
  fi
  printf 'close\n'
}

# _issue_open_children <repo-slug> <issue> [harness] -> `#a,#b` or nothing, rc 0
#   The OPEN issues the timeline cross-references whose body has a line
#   `Part of #n` (bin/run-decompose.sh) or `Child **C<k>** of #n`, sorted and
#   comma-joined; nothing when the whole timeline was read and none is there.
#   rc 1 when the list was NOT read to its end: no jq or gh_rest, a page that
#   failed or did not parse, or a page still full at ISSUE_CLOSE_GUARD_PAGES
#   (default 5). Its only stdout then is `ERR:<why>`, why one of no-jq,
#   no-gh-rest, timeline-read, timeline-unparseable, timeline-capped (the why
#   rides stdout because a variable cannot leave the caller's `$(...)`).
#   Shared by issue_close_guard and both slice close-outs (BH-4662), so "is
#   there a child?" has one answer.
_issue_open_children() {
  local slug="${1:-}" n="${2:-}" h="${3:-${HARNESS:-${H:-}}}" childre max p=1 page len kids="" k
  command -v jq >/dev/null 2>&1 || { printf 'ERR:no-jq\n'; return 1; }
  command -v gh_rest >/dev/null 2>&1 || { printf 'ERR:no-gh-rest\n'; return 1; }
  max=$(_issue_env "$h" ISSUE_CLOSE_GUARD_PAGES 5)
  case "$max" in ''|*[!0-9]*|0) max=5 ;; esac
  childre="^[[:space:]>*_-]*(Part of:? #$n|Child \\*\\*C[0-9]+\\*\\* of #$n)([^0-9]|\$)"
  while [ "$p" -le "$max" ]; do
    page=$(_issue_arm "$slug"; gh_rest GET "repos/$slug/issues/$n/timeline?per_page=100&page=$p" 2>/dev/null) \
      || { printf 'ERR:timeline-read\n'; return 1; }
    len=$(printf '%s' "$page" | jq -e 'if type == "array" then length else error("not a list") end' 2>/dev/null) \
      || { printf 'ERR:timeline-unparseable\n'; return 1; }
    k=$(printf '%s' "$page" | jq -r --arg re "$childre" --argjson n "$n" '
          .[] | select(type == "object" and .event == "cross-referenced")
          | (.source.issue // empty)
          | select(.pull_request == null and .state == "open" and .number != $n)
          | select((.body // "") | split("\n") | map(sub("\r$"; "")) | any(test($re)))
          | "#\(.number)"' 2>/dev/null) || { printf 'ERR:timeline-unparseable\n'; return 1; }
    [ -n "$k" ] && kids="$kids$k"$'\n'
    [ "$len" = 100 ] || break
    p=$((p+1))
  done
  # Stopped by the cap on a FULL page: the rest was never read, so "no open
  # children" would be a claim about a list nobody finished (D12).
  [ "$p" -le "$max" ] || { printf 'ERR:timeline-capped\n'; return 1; }
  [ -z "$kids" ] || printf '%s\n' "$(printf '%s' "$kids" | sort -t'#' -k2 -n -u | paste -sd, -)"
  return 0
}

# _issue_slice_alert <harness> <repo-slug> <issue> <pr-url> [sfx]
#   ONE warn alert for a slice that no open child issue carries on (BH-4662):
#   the master stays open with `ai-build`, so the rest is re-offered, and an
#   operator files the children. The --id names the issue and PR, so the alert
#   state machine collapses a repeat from a lane with no build record.
_issue_slice_alert() {
  local h="${1:-}" slug="${2:-}" n="${3:-}" pr="${4:-}" sfx="${5:-}" prn msg
  prn="${pr##*/pull/}"; prn="${prn%%/*}"
  msg="issue $slug#$n: PR $pr delivered a slice but no open child issue carries the rest; the issue stays open with ai-build"
  case "$sfx" in *comment-failed*) msg="$msg, and the slice comment failed" ;; esac
  if [ -n "$h" ] && [ -x "$h/bin/lane-alert.sh" ]; then
    "$h/bin/lane-alert.sh" --severity warn --id "slice-no-children:$slug#$n:$prn" slice-closeout "$msg" >/dev/null 2>&1 || true
  else
    echo "issue-state-lib: $msg (no bin/lane-alert.sh to alert with)" >&2
  fi
  return 0
}

# issue_slice_body <pr-url> <guard-word> [issue] -> the thread comment for a slice
#   Client-visible, so plain sentences and no em dashes. Every sentence is true
#   whether or not GitHub's keyword close also fired: it says what the close-out
#   did, not what the issue's state is. The child-carrying words say nothing
#   about the label, because the strip runs after it and may be switched off or
#   fail. `slice:no-children` (BH-4662) is the one that names it, because that
#   path never strips: the callers pass it only after a complete children read
#   found none, and every other word only after one found a child.
issue_slice_body() {
  local pr="${1:-}" g="${2:-}" n="${3:-}" num
  num="${pr##*/pull/}"; num="${num%%/*}"
  if [ "$g" = slice:no-children ]; then
    printf 'Slice delivered: #%s. No child issue carries the rest yet, so this issue stays open and keeps ai-build.\n%s\n\n' "$num" "$pr"
    printf 'Once the rest is filed as child issues, the next slice close-out takes the label off.\n'
    return 0
  fi
  printf 'Slice delivered: #%s; children own the rest.\n%s\n\n' "$num" "$pr"
  case "$g" in
    slice:no-keyword)   printf "The PR doesn't say Closes #%s, so the close-out left this issue open.\n" "$n" ;;
    slice:plan)         printf 'The plan built one slice of this ticket, so the close-out left it open until the rest ships.\n' ;;
    slice:open-children:*)
                        printf '%s still open, so the close-out left this issue open.\n' \
                          "$(k="${g#slice:open-children:}"; case "$k" in *,*) printf '%s are' "${k//,/, }" ;; *) printf '%s is' "$k" ;; esac)" ;;
  esac
}

# issue_strip_ai_build <repo-slug> <issue> [harness] -> ONE strip word, rc 0
#   The `ai-build` label rule, shared by the close path and the slice path
#   (BH-2508): read the issue, keep the label on a split child, honour the
#   switch, DELETE. Words: stripped, strip-noop, kept-split-child, strip-off,
#   strip-skipped-unreadable, strip-failed. A failed DELETE sets ISSUE_CLOSE_ERR.
issue_strip_ai_build() {
  local repo="${1:-}" n="${2:-}" h="${3:-${HARNESS:-${H:-}}}" out ibody
  if ! out=$(_issue_arm "$repo"; gh_rest GET "repos/$repo/issues/$n" 2>/dev/null) || [ -z "$out" ]; then
    printf 'strip-skipped-unreadable\n'; return 0
  fi
  if ! _issue_labels_has "$out" ai-build; then
    # No jq answers the same way, and it is the honest answer: this function
    # could not read the labels, so it must not claim it removed one.
    command -v jq >/dev/null 2>&1 || { printf 'strip-skipped-unreadable\n'; return 0; }
    printf 'strip-noop\n'; return 0
  fi
  ibody=$(printf '%s' "$out" | jq -r '.body // ""' 2>/dev/null)
  if grep -qE '^Part of #[0-9]+' <<<"$ibody"; then
    printf 'kept-split-child\n'; return 0
  fi
  if [ "$(_issue_switch "$h" CLOSE_STRIP_AI_BUILD close-strip-ai-build-off)" != 1 ]; then
    printf 'strip-off\n'; return 0
  fi
  if out=$(_issue_arm "$repo"; gh_rest DELETE "repos/$repo/issues/$n/labels/ai-build" 2>&1 >/dev/null); then
    printf 'stripped\n'
  else
    ISSUE_CLOSE_ERR="${out:-gh-rest label delete failed}"
    printf 'strip-failed\n'
  fi
  return 0
}

# issue_slice_settle <repo-slug> <issue> <pr-url> <guard-word> [harness] [record-dir] -> ONE word
#   The close-out of a merge that only sliced the issue (BH-2508). Never closes.
#   For slice:plan and slice:no-keyword the open children are read first
#   (BH-4662; an open-children word has already read them), with three outcomes:
#     a child       post the slice comment (best effort), THEN take `ai-build`
#                   off under the rule above, so a master the watchers stop
#                   relaunching already says why. Prints
#                   `kept-<guard-word>+<strip word>`, rc 0.
#     none          slice:plan first asks slice_remainder_settle
#                   (bin/lib/slice-remainder.sh, BH-5961) to file the
#                   remaining slices the plan names. Filed (now or before):
#                   the filer commented on the issue and took `ai-build` off;
#                   prints `kept-slice:remainder-filed:#a,#b`, rc 0. Not
#                   finished (lock held, parent unreadable, a create failed):
#                   writes nothing more, prints `close-deferred:remainder`,
#                   rc 1. No remainder in the plan: it paged critical
#                   SLICE_REMAINDER_UNKNOWN once, and the no-children comment
#                   below posts with no warn alert. Otherwise (switched off,
#                   no record, parent closed, dry run, slice:no-keyword):
#                   post the no-children comment, raise ONE warn alert
#                   (_issue_slice_alert), and never strip (A3: the label stays
#                   so the rest is re-offered). Prints
#                   `kept-slice:no-children+label-kept`, rc 0.
#     unreadable    write nothing, print `close-deferred:children-read`, rc 1,
#                   so the caller retries next tick as it does for an unknown.
#   Either rc 0 word gains `,comment-failed` when the comment was refused; the
#   no-children alert fires on that too, since nothing retries an rc 0.
#
#   THE COMMENT IS PAID ONCE PER BUILD RECORD. A slice stays open, so every
#   close-out lane that sees the same merge acts on it: rb/pr.sh or the merge
#   conductor at merge time, then bin/hotfix-after-deploy.sh after the deploy.
#   With a record dir, `<record>/issue-commented` (the marker mc_close_shipped
#   already writes) skips the comment when it exists and is written after one
#   posts; the strip still runs and answers strip-noop on the second lane.
issue_slice_settle() {
  local repo="${1:-}" n="${2:-}" pr="${3:-}" g="${4:-}" h="${5:-${HARNESS:-${H:-}}}" rec="${6:-}" sfx="" kids w src=3
  case "$g" in slice:plan|slice:no-keyword)
    kids=$(_issue_open_children "$repo" "$n" "$h") || {
      ISSUE_CLOSE_ERR="children read failed (${kids#ERR:})"
      printf 'close-deferred:children-read\n'; return 1; }
    if [ -z "$kids" ]; then
      # BH-6308: nothing is left (close) or the rest gets one child (file, then
      # close). rc 3 (switched off, dry run, parent closed, a local remainder)
      # runs the path below unchanged.
      if command -v sco_settle >/dev/null 2>&1; then
        w=$(sco_settle "$repo" "$n" "$pr" "$g" "$rec" "$h"); src=$?
        case "$src" in
          4) [ -n "$rec" ] && touch "$rec/issue-commented" 2>/dev/null
             printf 'closed-slice:%s\n' "$w"; return 0 ;;
          0) [ -n "$rec" ] && touch "$rec/issue-commented" 2>/dev/null
             printf 'kept-slice:%s\n' "$w"; return 0 ;;
          1) ISSUE_CLOSE_ERR="slice close-out: $w"
             printf 'close-deferred:slice-closeout\n'; return 1 ;;
        esac
        src=3
      fi
      if [ "$g" = slice:plan ] && command -v slice_remainder_settle >/dev/null 2>&1; then
        w=$(slice_remainder_settle "$repo" "$n" "$pr" "$rec" "$h"); src=$?
        case "$src" in
          0) [ -n "$rec" ] && touch "$rec/issue-commented" 2>/dev/null
             printf 'kept-slice:%s\n' "$w"; return 0 ;;
          1) ISSUE_CLOSE_ERR="slice remainder: $w"
             printf 'close-deferred:remainder\n'; return 1 ;;
        esac
      fi
      if [ -z "$rec" ] || [ ! -f "$rec/issue-commented" ]; then
        if _issue_comment "$repo" "$n" "$(issue_slice_body "$pr" slice:no-children "$n")"; then
          [ -n "$rec" ] && touch "$rec/issue-commented" 2>/dev/null
        else
          sfx=",comment-failed"
        fi
        # rc 2: slice_remainder_settle already paged critical, which replaces the warn.
        [ "$src" = 2 ] || _issue_slice_alert "$h" "$repo" "$n" "$pr" "$sfx"
      fi
      printf 'kept-slice:no-children+label-kept%s\n' "$sfx"
      return 0
    fi ;;
  esac
  if [ -z "$rec" ] || [ ! -f "$rec/issue-commented" ]; then
    if _issue_comment "$repo" "$n" "$(issue_slice_body "$pr" "$g" "$n")"; then
      [ -n "$rec" ] && touch "$rec/issue-commented" 2>/dev/null
    else
      sfx=",comment-failed"
    fi
  fi
  printf 'kept-%s+%s%s\n' "$g" "$(issue_strip_ai_build "$repo" "$n" "$h")" "$sfx"
  return 0
}

# issue_close_shipped <repo-slug> <issue-number> <comment-body> [harness] [pr-url] [record-dir]
#   Comment, close, then take `ai-build` off — ONE implementation for the four
#   harness paths that close an issue after a merge, so the rule cannot drift
#   into four.
#
#   WITH A PR URL THE GUARD RUNS FIRST (BH-2477), before any write:
#     slice:*    issue_slice_settle: post issue_slice_body instead of
#                <comment-body> (best effort), close nothing, then take
#                `ai-build` off under the strip rule below (BH-2508), print
#                `kept-slice:<why>+<strip word>`, rc 0 — the close-out is
#                settled, so no caller retries it. With no open child it keeps
#                the label, alerts, and prints
#                `kept-slice:no-children+label-kept`, rc 0; when the children
#                cannot be read it writes nothing and prints
#                `close-deferred:children-read`, rc 1 (BH-4662)
#     unknown:*  write nothing, print `close-deferred:<what>`, rc 1
#     close      exactly the path below
#   Without one (mc_close_shipped's strip call) nothing changes.
#
#   ORDER IS THE DESIGN. The comment is best effort (a refused comment is noted
#   and changes nothing). The CLOSE is the side effect this exists for: on
#   failure it is rc 1, the word `close-failed`, and nothing else runs — a label
#   is never removed from an issue that did not close, so "unlabelled but still
#   open", an issue no watcher can see and no merge has shipped, cannot be
#   produced here. The strip runs only after a verified close.
#
#   STDOUT IS THE STRIP WORD, so a caller logs it on its existing line and an
#   operator can grep a box for `strip-failed`: stripped, strip-noop,
#   kept-split-child, strip-off, strip-skipped-unreadable, strip-failed,
#   close-failed. A failed comment appends `,comment-failed` to whichever word
#   the run ends on, because a close-out nobody can read on the issue is worth
#   one word in the log.
#
#   THE SPLIT-CHILD EXEMPTION. bin/decompose-parent-close.sh finds a split's
#   children with `--label ai-build --state all` and treats a child it cannot
#   see as "an unknown, and an unknown is not a closure", so stripping children
#   would leave every split master open for ever. A body line matching
#   `^Part of #<n>` is written by this harness's own filer
#   (bin/run-decompose.sh) and by nothing else, so it is the exact and only
#   exemption: prose about being "part of the onboarding plan" is not it.
#
#   The last stderr is left in ISSUE_CLOSE_ERR for callers that report it.
# ISSUE_CLOSE_ERR is written here and read by the CALLER (bin/batch-resolve.sh
# reports it on its failure line), which shellcheck cannot see from this file.
# shellcheck disable=SC2034
issue_close_shipped() {
  local repo="${1:-}" n="${2:-}" body="${3:-}" h="${4:-${HARNESS:-${H:-}}}" pr="${5:-}" rec="${6:-}" out sfx="" g
  ISSUE_CLOSE_ERR=""
  [ -n "$repo" ] && [ -n "$n" ] || { printf 'close-failed\n'; return 1; }
  if ! command -v gh_rest_comment >/dev/null 2>&1 || ! command -v gh_rest_close >/dev/null 2>&1; then
    ISSUE_CLOSE_ERR="gh-rest.sh not loaded"; printf 'close-failed\n'; return 1
  fi
  if [ -n "$pr" ]; then
    g=$(issue_close_guard "$repo" "$n" "$pr" "$rec" "$h")
    case "$g" in
      close) ;;
      slice:*) issue_slice_settle "$repo" "$n" "$pr" "$g" "$h" "$rec"; return $? ;;
      *)
        ISSUE_CLOSE_ERR="close guard could not decide: ${g:-no answer}"
        printf 'close-deferred:%s\n' "${g#unknown:}"; return 1 ;;
    esac
  fi
  if [ -n "$body" ]; then
    _issue_comment "$repo" "$n" "$body" || sfx=",comment-failed"
  fi
  if ! out=$(_issue_arm "$repo"; gh_rest_close "$repo" "$n" 2>&1 >/dev/null); then
    ISSUE_CLOSE_ERR="${out:-gh-rest close failed}"
    printf 'close-failed%s\n' "$sfx"; return 1
  fi
  printf '%s%s\n' "$(issue_strip_ai_build "$repo" "$n" "$h")" "$sfx"
  return 0
}
