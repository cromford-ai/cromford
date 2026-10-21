#!/bin/bash
# bin/lib/pr-self-check.sh — BH-5798: the pre-review self-check. Does the PR
# body match the head it is about? Decided from git and the body text alone,
# before a lead review is bought. Sourced, never executed: no `exit`, no output
# at source time. Callers: bin/pr-self-check.sh (CLI), bin/lead-review-enqueue.sh.
#
# psc_check <repo> <base-ref> <head-sha> <body-file> [ticket-file]
#   One line per finding on stdout: `REFUSE <rule>: <why>` or `NOTE <rule>: <why>`.
#   rc 0 nothing refused | 1 a rule refused | 2 could not run (no repo, the head
#   or base will not resolve, no body, no catalog).
#   The rules are rows of $PR_SELF_CHECK_CATALOG (default catalog/pr-self-check.tsv
#   beside this lib): id, mode (refuse|note|off), param (ignore globs), what. A
#   rule with no row is off. #5790's section rules join as more rows.
#
# THE RULES
#   closes-not-met  the body says Closes/Fixes/Resolves #N and an acceptance item
#                   is not met: a `- [ ]` item, or a line that is not a checked
#                   `- [x]` item and says "not met" or REFUTED, inside a section
#                   whose heading names acceptance, self-check or evidence. A
#                   partial build must say Refs.
#   evidence-head   every sha the body binds evidence to — `head <sha>` in a
#                   heading, or `<!-- evidence-head: <sha> -->` — is the head, or
#                   a sha where none of the PR's files differ from the head
#                   (param globs excepted; a tree diff, so a rebased head counts).
#                   A PR file changed after it: a human `head <sha>` claim is
#                   refused, the builder's marker (which fix rounds and rebases
#                   never rewrite) is a note. A sha the repo does not have is
#                   refused. A body with no evidence sha at all is a note.
#   body-*          (BH-5790) a PR-body section the lead review would BLOCK on:
#                   Why, an acceptance section or gate table, mutation evidence
#                   for a new suite, the D1 / kill-knob callout, the live probe
#                   the ticket names. WHEN (param) and WHAT COUNTS (match) are the
#                   row's own data (catalog header). The ticket text is the 5th
#                   argument or $PSC_TICKET_FILE; none = a NOTE for ticket=.
#                   $PR_SELF_CHECK_ONLY (an ERE on the rule id) runs a subset.
#                   Rows also come from ${catalog%.tsv}.d/*.tsv, read after the
#                   main file in C filename order, same columns (BH-6380).
#                   Trigger `perf` (BH-6380): the ticket is perf/cost by
#                   pt_classify (bin/lib/perf-ticket.sh) on the ticket text,
#                   $PSC_TICKET_TITLE and $PSC_TICKET_LABELS (comma list). When
#                   it says no and $PSC_TICKET_REPO is set, ONE parent hop: the
#                   title `BH-<p>.<k>:`, else the first `Part of #<p>` in the
#                   ticket text, never $PSC_TICKET_N itself; one gh_rest read,
#                   and the parent is classified with no hop of its own. All
#                   three inputs empty, a classifier that cannot decide or a
#                   failed read = a NOTE, never a refusal.
#                   Trigger `spec-ref` (BH-6485): the ticket text has
#                   `Reference:` lines and a diff file is a UI path
#                   (st_ui_ref_applies, bin/lib/spec-trace.sh). $PSC_PHASE=open,
#                   no ticket text or no lib = a NOTE.
#                   Match `under=<heading-ERE>>><line-ERE>`: a line under a
#                   matching heading (any level) matches the line ERE. `&`
#                   ANDs terms inside one `;` alternative; an unknown term kind
#                   is false.
#   plan-files      every file the PR changes (base...head, param globs excepted)
#                   is named by the plan's `## Files to touch` section, or by a
#                   line under `## Files outside the plan` with a reason after it.
#                   The plan is the one .harness/specs/*/plan.md the PR changes.
#                   No plan, or no such section: a note.
#   test-ownership  (BH-6392, D51 enforced) a test the PR modifies or deletes
#                   (base...head, never an added file) under tests/ whose name
#                   carries a ticket key (`<topic>.<key>-test.sh`,
#                   `.<key>.test.<ext>`, `.<key>.spec.<ext>`) belongs to that
#                   ticket. When its key root is not the PR's own key root, a
#                   body line `TEST-CHANGE: <path or basename> — <premise>` must
#                   name it, with 3 or more words of premise. The PR's key is
#                   $PSC_PR_KEY (--key; the enqueue sets it from the PR title),
#                   the `Harness-Ticket:` trailer, the first line
#                   `Ticket <KEY> —`, or the one .harness/specs/<KEY>/plan.md
#                   the PR changes. `.N` slices of one ticket share a root. No
#                   key: a note. No such test in the diff: silent.
#   body-plan-requires (BH-7378) each item of the fenced ```pr-body-requires
#                   block of a .harness/specs/*/plan.md the PR changes that the
#                   body lacks (fixed-string match) is one `NOTE body-plan-
#                   requires: the body is missing <item> (required by <source>)`
#                   line, 10 at most. A NOTE in every mode but off; it never
#                   sets rc 1. bin/lib/pr-body-requires.sh has the rule.
#   callers-not-ported (BH-7815) each place the merge of the base and the
#                   head (git merge-tree) still names a path the PR deletes or
#                   renames is one `NOTE callers-not-ported: <file>:<line> still
#                   references <old>, ...` line, 20 at most. A NOTE in every mode
#                   but off; it never sets rc 1. bin/lib/callers-not-ported.sh
#                   has the rule.
#   foreign-commits (BH-6394, D66 enforced) a PR carries only its own ticket's
#                   commits. Each first-parent, non-merge commit in base..head
#                   whose subject LEADS with a key (`BH-1: ...`, `fix(BH-1): ...`)
#                   of the PR key's prefix and another key root is foreign. Own
#                   roots: the PR key (as test-ownership finds it) and the second
#                   key of the first body line `Ticket <KEY> — <KEY2>: ...`. It
#                   passes when the base is `ticket/<that key>` (`-rN`/`-pN`
#                   allowed), or the body says `Stacked on #N` and the conductor
#                   row file ($PSC_CONDUCTOR_ROWS, default state/merge-conductor/
#                   pr-state.tsv) holds THIS head as STACKED_WAIT. The refusal
#                   names the owner PR: one gh_rest read per key root when the
#                   caller has gh_rest, else the body's `Stacked on #N`, else the
#                   branch. No own key and a keyed commit: one note.
#   plan-validate   (BH-7072) each static VALIDATE check of the plan the PR
#                   changes passes at the head and in the body, and the body
#                   has no "not met" line and no missed Target metric, unless an
#                   operator approved an `owed:` line. bin/lib/pr-self-check-validate.sh.
#
# psc_test_change_section <plan> <base> — the PR body bridge (bin/lib/rb/pr.sh
#   PR_BODY_FOR): `## Test changes` and one `TEST-CHANGE: <path> — <premise>`
#   line per tests/ path, from the plan's `## Tests that must change` section,
#   the plan's own TEST-CHANGE: lines and the commit messages in <base>..HEAD
#   (first source wins), or nothing.
#
# psc_plan_missing <repo> <base> <head> <body> [param] — the plan-files rule's
#   own file list, uncut (BH-6393). Callers: psc_check, and _pr_self_check_prepush
#   in bin/lib/rb/pr.sh, which writes one reason line per file before the PR opens.

_psc_lib_dir() { (cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd); }
# pt_classify, the perf/cost classifier (BH-6380). Missing = the perf trigger
# is a NOTE, never a refusal.
# shellcheck source=bin/lib/perf-ticket.sh
. "$(dirname "${BASH_SOURCE[0]}")/perf-ticket.sh" 2>/dev/null || :
# st_ui_ref_applies, the spec-trace trigger (BH-6485). Missing = the spec-ref
# trigger is a NOTE, never a refusal.
# shellcheck source=bin/lib/spec-trace.sh
. "$(dirname "${BASH_SOURCE[0]}")/spec-trace.sh" 2>/dev/null || :

# _psc_rows — the catalog rows, comments stripped:
#   id<TAB>mode<TAB>param<TAB>match<TAB>what   (an empty field reads `-`)
# Then the rows of every ${cat%.tsv}.d/*.tsv, in C filename order (BH-6380):
# a ticket adds its own fragment instead of a line in the shared file.
_psc_rows() {
  local cat="${PR_SELF_CHECK_CATALOG:-$(_psc_lib_dir)/../../catalog/pr-self-check.tsv}" f ng=0
  local -a frag=()
  [ -r "$cat" ] || return 1
  shopt -q nullglob && ng=1
  shopt -s nullglob
  for f in "${cat%.tsv}.d"/*.tsv; do [ -f "$f" ] && frag+=("$f"); done
  [ "$ng" = 1 ] || shopt -u nullglob
  [ "${#frag[@]}" -gt 0 ] && mapfile -t frag < <(printf '%s\n' "${frag[@]}" | LC_ALL=C sort)
  awk -F'\t' '!/^[[:space:]]*#/ && NF >= 2 && $1 != "" {
    print $1 "\t" $2 "\t" ($3 == "" ? "-" : $3) "\t" ($5 == "" ? "-" : $5) "\t" ($4 == "" ? "-" : $4) }' "$cat" ${frag[@]+"${frag[@]}"}
}

# _psc_any_glob <globs> <paths> — rc 0 when a path matches a glob in the list
_psc_any_glob() {
  local p
  while IFS= read -r p; do [ -n "$p" ] && _psc_ignored "$p" "$1" && return 0; done <<<"$2"
  return 1
}

# _psc_perf <ticket-file> — rc 0 a perf/cost ticket, 1 not, 3 unknown
# (_PSC_UNK_WHY says why). Memoized in _PSC_PERF for one psc_check call, so two
# perf rows cost one parent hop.
_psc_perf() {
  local pf="$1" prc par="" pd pt
  if [ -n "${_PSC_PERF:-}" ]; then
    [ "${_PSC_PERF%%:*}" = 3 ] && _PSC_UNK_WHY="${_PSC_PERF#*:}"
    return "${_PSC_PERF%%:*}"
  fi
  [ -n "$pf" ] && [ -s "$pf" ] || pf=""
  if [ -z "$pf" ] && [ -z "${PSC_TICKET_TITLE:-}" ] && [ -z "${PSC_TICKET_LABELS:-}" ]; then
    _PSC_PERF="3:no ticket text"
  elif ! declare -F pt_classify >/dev/null; then
    _PSC_PERF="3:the perf/cost classifier could not decide"
  else
    pt_classify "$pf" "${PSC_TICKET_TITLE:-}" "${PSC_TICKET_LABELS:-}" >/dev/null 2>&1; prc=$?
    case "$prc" in
      0) _PSC_PERF=0 ;;
      1)
        _PSC_PERF=1
        # ONE parent hop, the contract's rule; the parent gets none of its own.
        if [ -n "${PSC_TICKET_REPO:-}" ]; then
          if [[ ${PSC_TICKET_TITLE:-} =~ ^BH-([0-9]+)\.[0-9]+: ]]; then par="${BASH_REMATCH[1]}"
          elif [ -n "$pf" ]; then par=$(grep -oiE 'part of #[0-9]+' "$pf" 2>/dev/null | head -1 | grep -oE '[0-9]+$'); fi
          if [ -n "$par" ] && [ "$par" != "${PSC_TICKET_N:-}" ]; then
            _PSC_PERF="3:the perf/cost classifier could not decide"
            declare -F gh_rest >/dev/null || . "$(_psc_lib_dir)/gh-rest.sh" 2>/dev/null
            if declare -F gh_rest >/dev/null && pd=$(mktemp -d "${TMPDIR:-/tmp}/psc-perf.XXXXXX" 2>/dev/null); then
              if gh_rest GET "repos/$PSC_TICKET_REPO/issues/$par" > "$pd/j" 2>/dev/null \
                 && jq -r '.body // ""' "$pd/j" > "$pd/b" 2>/dev/null \
                 && pt=$(jq -r '.title // ""' "$pd/j" 2>/dev/null) \
                 && jq -r '[.labels[]?.name] | join(",")' "$pd/j" > "$pd/l" 2>/dev/null; then
                pt_classify "$pd/b" "$pt" "$(cat "$pd/l")" >/dev/null 2>&1; prc=$?
                case "$prc" in 0) _PSC_PERF=0 ;; 1) _PSC_PERF=1 ;; esac
              fi
              rm -rf "$pd"
            fi
          fi
        fi ;;
      *) _PSC_PERF="3:the perf/cost classifier could not decide" ;;
    esac
  fi
  [ "${_PSC_PERF%%:*}" = 3 ] && _PSC_UNK_WHY="${_PSC_PERF#*:}"
  return "${_PSC_PERF%%:*}"
}

# _psc_body_fires <repo> <base> <head> <param> <files> <ticket-file>
#   rc 0 the rule applies, 1 it does not, 3 it cannot tell (a ticket= or perf
#   trigger with no answer and nothing else fired; _PSC_UNK_WHY says why). The
#   triggers are the catalog header's: always, added=, touched=, knob,
#   ticket=, perf (BH-6380, _psc_perf) and spec-ref (BH-6485).
_psc_body_fires() {
  local repo="$1" base="$2" head="$3" files="$5" tk="$6" t trig=() unk=0 added kd why=""
  _PSC_UNK_WHY=""
  IFS=';' read -r -a trig <<<"$4"
  for t in "${trig[@]}"; do
    case "$t" in
      always) return 0 ;;
      added=*)
        added=$(git -C "$repo" diff --no-renames --diff-filter=A --name-only "$base...$head" 2>/dev/null)
        _psc_any_glob "${t#added=}" "$added" && return 0 ;;
      touched=*) _psc_any_glob "${t#touched=}" "$files" && return 0 ;;
      knob)
        # Captured first: grep -q on a git pipe is a SIGPIPE race under pipefail.
        kd=$(git -C "$repo" diff --no-renames -U0 "$base...$head" -- 'catalog/lanes.d/*.json' 2>/dev/null)
        grep -qE '^\+[[:space:]]*"env"[[:space:]]*:' <<<"$kd" && return 0 ;;
      ticket=*)
        if [ -z "$tk" ] || [ ! -s "$tk" ]; then unk=1; why="${why:-no ticket text}"
        else _psc_section "$tk" 'done[- ]when|acceptance' | grep -qiE -- "${t#ticket=}" && return 0; fi ;;
      spec-ref)
        # BH-6485: the ticket body has `Reference:` lines and the diff touches
        # UI. The shots exist only after preview QA, so the open phase
        # ($PSC_PHASE=open) is a note; the edit phase and the enqueue refuse.
        if [ "${PSC_PHASE:-}" = open ]; then unk=1; why="${why:-reference shots are taken after preview QA}"
        elif [ -z "$tk" ] || [ ! -s "$tk" ]; then unk=1; why="${why:-no ticket text}"
        elif ! declare -F st_ui_ref_applies >/dev/null; then unk=1; why="${why:-the spec-trace lib is missing}"
        elif st_ui_ref_applies "$tk" "$files"; then return 0; fi ;;
      perf)
        _psc_perf "$tk"
        case $? in
          0) return 0 ;;
          3) unk=1; why="${why:-$_PSC_UNK_WHY}" ;;
        esac ;;
    esac
  done
  _PSC_UNK_WHY="$why"
  [ "$unk" = 1 ] && return 3
  return 1
}

# _psc_body_term <body> <term> — rc 0 when the body shows one term. An
# unknown kind is false, so a typo never passes every body.
_psc_body_term() {
  local u sec
  case "$2" in
    section=*)
      awk -v re="${2#section=}" '
        function done_() { if (on && words >= 3) found = 1 }
        /^#+[[:space:]]/ { done_(); on = (tolower($0) ~ tolower(re)); words = 0; next }
        on { n = split($0, w, /[^A-Za-z]+/); for (i = 1; i <= n; i++) if (length(w[i]) >= 2) words++ }
        END { done_(); exit !found }' "$1" ;;
    line=*) grep -qiE -- "${2#line=}" "$1" ;;
    table) awk 'prev ~ /^[[:space:]]*\|/ && $0 ~ /^[[:space:]]*\|[[:space:]:|-]*-/ {f = 1} {prev = $0} END {exit !f}' "$1" ;;
    under=*'>>'*)
      # Captured first: grep -q on a pipe is a SIGPIPE race under pipefail.
      u="${2#under=}"; sec=$(_psc_section "$1" "${u%%>>*}")
      grep -qiE -- "${u#*>>}" <<<"$sec" ;;
    *) return 1 ;;
  esac
}

# _psc_body_shows <body> <match> — rc 0 when the body shows one `;`
# alternative; an alternative holds when every `&` term in it holds.
_psc_body_shows() {
  local m t all alts=() terms=()
  IFS=';' read -r -a alts <<<"$2"
  for m in "${alts[@]}"; do
    IFS='&' read -r -a terms <<<"$m"
    [ "${#terms[@]}" -gt 0 ] || continue
    all=1
    for t in "${terms[@]}"; do _psc_body_term "$1" "$t" || { all=0; break; }; done
    [ "$all" = 1 ] && return 0
  done
  return 1
}

# _psc_ignored <path> <globs> — rc 0 when a glob in the comma list matches
_psc_ignored() {
  local p="$1" g gl=()
  [ "${2:--}" = - ] && return 1
  # read -a, never `for g in $2`: an unquoted list is pathname-expanded against
  # the caller's working directory before the match ever runs.
  IFS=, read -r -a gl <<<"$2"
  for g in "${gl[@]}"; do
    # shellcheck disable=SC2053  # the glob is the point
    [[ "$p" == $g ]] && return 0
  done
  return 1
}

# _psc_section <body> <heading-regex> — the lines under every heading matching
# the (case-insensitive) regex, up to the next heading of the same or a higher
# level (BH-6191): `### C0` under `## Files to touch` is part of it.
_psc_section() {
  awk -v re="$2" '/^#+[[:space:]]/ { lv = match($0, /[^#]/) - 1
      if (on && lv > lvl) next
      on = (tolower($0) ~ tolower(re)); lvl = lv; next } on' "$1"
}

_psc_closes_not_met() { # <body> -> the not-met lines, rc 0 when Closes + not met
  grep -qiE '(^|[^a-z])(closes|fixes|resolves)[[:space:]]+#[0-9]+' "$1" || return 1
  local nm
  # A checkbox line is decided by its box alone: `- [x] ... not met is refused`
  # is a met item that happens to name the rule. Any other line counts when it
  # says "not met" or REFUTED.
  # A table row (the builder's ## Evidence table) names claims and their
  # verdicts; its text is not an item, so it never counts (lead review
  # lr-5828). The match lower-cases the line itself: IGNORECASE is gawk only.
  nm=$(_psc_section "$1" 'acceptance|self-check|evidence' \
        | awk '/^[[:space:]]*\|/ { next }
               /^[[:space:]]*[-*][[:space:]]+\[ \]/ { print; next }
               /^[[:space:]]*[-*][[:space:]]+\[[xX]\]/ { next }
               tolower($0) ~ /not met|refuted/ { print }' | head -5)
  [ -n "$nm" ] || return 1
  printf '%s\n' "$nm"
}

_psc_evidence_shas() { # <body> -> `<kind> <sha>` a line; kind human | marker
  # human: a `head <sha>` claim in a heading. marker: the builder's
  # <!-- evidence-head: <sha> --> (bin/lib/rb/pr.sh), which no fix round or
  # conductor rebase rewrites.
  { grep -iE '^#+[[:space:]].*\bhead[[:space:]]+[0-9a-f]{7,40}\b' "$1" \
      | grep -oiE '\bhead[[:space:]]+[0-9a-f]{7,40}\b' | awk '{print "human " $2}'
    grep -oE '<!--[[:space:]]*evidence-head:[[:space:]]*[0-9a-f]{7,40}' "$1" | grep -oE '[0-9a-f]{7,40}$' | awk '{print "marker " $1}'
  } | tr 'A-F' 'a-f' | awk '!s[$0]++'
}

# _psc_key_root <key> — lower case, a trailing `.N` slice suffix stripped
_psc_key_root() { printf '%s' "${1:-}" | tr 'A-Z' 'a-z' | sed -E 's/(\.[0-9]+)+$//'; }

# _psc_test_key <path> — the ticket key a tests/ file name carries, or nothing
_psc_test_key() {
  case "${1:-}" in tests/*) ;; *) return 0 ;; esac
  printf '%s' "${1##*/}" | tr 'A-Z' 'a-z' \
    | sed -nE 's/^.*\.([a-z]+-[0-9]+(\.[0-9]+)*)(-test\.sh|\.test\.[a-z0-9]+|\.spec\.[a-z0-9]+)$/\1/p'
}

# _psc_pr_key <body> <files> — the PR's own ticket key, or nothing
_psc_pr_key() {
  local re='^[A-Za-z]+-[0-9]+(\.[0-9]+)*$' k specs
  k="${PSC_PR_KEY:-}"
  [[ "$k" =~ $re ]] && { printf '%s' "$k"; return 0; }
  k=$(sed -nE 's/^Harness-Ticket:[[:space:]]*([^[:space:]]+).*/\1/p' "$1" | tail -1)
  [[ "$k" =~ $re ]] && { printf '%s' "$k"; return 0; }
  k=$(sed -nE '1{s/\r$//;s/^(HOTFIX: )?Ticket ([A-Za-z]+-[0-9]+(\.[0-9]+)*)[[:space:]].*/\2/p;}' "$1")
  [[ "$k" =~ $re ]] && { printf '%s' "$k"; return 0; }
  specs=$(sed -nE 's#^\.harness/specs/([^/]+)/plan\.md$#\1#p' <<<"$2" | sort -u)
  [ -n "$specs" ] && [ "$(wc -l <<<"$specs")" = 1 ] && [[ "$specs" =~ $re ]] && printf '%s' "$specs"
  return 0
}

# _psc_lead_key <subject> — the ticket key a commit subject leads with
# (`BH-1: x`, `fix(BH-1): x`, `spec(BH-1.2)!: x`), or nothing. A key anywhere
# else in the subject does not count.
_psc_lead_key() {
  local k='[A-Za-z]+-[0-9]+(\.[0-9]+)*'
  local scoped="^[[:space:]]*[A-Za-z]+\\(($k)[^)]*\\)" bare="^[[:space:]]*($k)([^A-Za-z0-9_-]|\$)"
  if [[ "${1:-}" =~ $scoped ]] || [[ "${1:-}" =~ $bare ]]; then printf '%s' "${BASH_REMATCH[1]}"; fi
  return 0
}

# _psc_own_roots <pr-key> <body> — the PR's own key roots, one a line: the PR
# key's, and the second key of the first body line `Ticket <KEY> — <KEY2>: ...`
# (#6093: title BH-6008, its own commits written as BH-6005.1).
_psc_own_roots() {
  [ -n "${1:-}" ] || return 0
  _psc_key_root "$1"; echo
  local k2
  k2=$(sed -nE '1{s/\r$//;s/^(HOTFIX: )?Ticket [A-Za-z]+-[0-9]+(\.[0-9]+)*[[:space:]]+(—|–|-)[[:space:]]+([A-Za-z]+-[0-9]+(\.[0-9]+)*)([^A-Za-z0-9_-].*)?$/\4/p;}' "$2")
  [ -n "$k2" ] && { _psc_key_root "$k2"; echo; }
  return 0
}

# _psc_base_key <base-ref> — the key root of a `ticket/<KEY>[-rN|-pN]` base, or nothing
_psc_base_key() {
  local b="${1:-}" re='^ticket/([A-Za-z]+-[0-9]+(\.[0-9]+)*)(-r[0-9]+|-p[0-9]+)?$'
  b=${b#refs/remotes/origin/}; b=${b#refs/heads/}; b=${b#origin/}
  [[ "$b" =~ $re ]] && _psc_key_root "${BASH_REMATCH[1]}"
  return 0
}

# _psc_stacked_wait <body> <head-sha> — rc 0 when the body says it is stacked
# and the conductor holds THIS head as STACKED_WAIT (an older head's row does
# not count: bin/pipeline-health.sh reads it the same way). Rows are
# bin/lib/mc/settle.sh mc_row_put's: key state since head reviewed alerted reason url.
_psc_stacked_wait() {
  grep -qiE 'stacked on[^#]*#[0-9]+' "$1" || return 1
  awk -F'\t' -v h="$2" '$2=="STACKED_WAIT" && $4==h {f=1} END {exit !f}' \
    "${PSC_CONDUCTOR_ROWS:-$(_psc_lib_dir)/../../state/merge-conductor/pr-state.tsv}" 2>/dev/null
}

# _psc_owner_pr <key-root> <repo> <body> — the PR that owns a key, message only:
# `#N` from one gh_rest read (when the caller sourced bin/lib/gh-rest.sh), else
# the body's `Stacked on #N`, else the branch name.
_psc_owner_pr() {
  local u o r n raw=""
  if declare -F gh_rest_var >/dev/null 2>&1 && u=$(git -C "$2" remote get-url origin 2>/dev/null); then
    u=${u%/}; u=${u%.git}; r=${u##*/}; u=${u%/*}; o=${u##*[/:]}
    if [[ "$o/$r" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
      # gh_rest_var, never $(gh_rest ...): GH_REST_STATUS must live in this shell (gh-rest-no-subshell-lint).
      if gh_rest_var raw GET "repos/$o/$r/pulls?state=all&head=$o:ticket/$1&per_page=1" 2>/dev/null; then
        n=$(jq -r '.[0].number // empty' <<<"$raw" 2>/dev/null)
        [[ "$n" =~ ^[0-9]+$ ]] && { printf '#%s' "$n"; return 0; }
      fi
    fi
  fi
  n=$(grep -oiE 'stacked on[^#]*#[0-9]+' "$3" 2>/dev/null | head -1 | grep -oE '[0-9]+$')
  if [ -n "$n" ]; then printf 'the PR of ticket/%s; the body says Stacked on #%s' "$1" "$n"
  else printf 'the PR of ticket/%s' "$1"; fi
}

# _psc_test_change_ok <tc-lines> <path> — rc 0 a line names the path (or its
# basename) and 3+ words of premise; rc 1 no line names it; rc 3 lines name it
# with no premise
_psc_test_change_ok() {
  local l rest b="${2##*/}" seen=1
  while IFS= read -r l; do
    case "$l" in *"$b"*) ;; *) continue ;; esac
    seen=3
    rest=${l#*TEST-CHANGE:}; rest=${rest//"$2"/}; rest=${rest//"$b"/}
    awk '{ n = split($0, w, /[^A-Za-z]+/); for (i = 1; i <= n; i++) if (length(w[i]) >= 2) c++ }
         END { exit !(c >= 3) }' <<<"$rest" && return 0
  done <<<"$1"
  return "$seen"
}

psc_test_change_section() {
  local plan="${1:-}" base="${2:-}" l p rest out="" paths="" log
  _psc_tc_add() { # <path> <line>
    grep -qxF -- "$1" <<<"$paths" && return 0
    paths="$paths"$'\n'"$1"; out="$out$2"$'\n'
  }
  _psc_tc_path() { # <line> -> sets p, the first tests/ path in it
    p=""
    [[ "$1" =~ (^|[^A-Za-z0-9_./-])(tests/[A-Za-z0-9_./-]+) ]] || return 1
    p="${BASH_REMATCH[2]}"; while [[ "$p" == *. ]]; do p=${p%.}; done
  }
  if [ -r "$plan" ]; then
    while IFS= read -r l; do
      _psc_tc_path "$l" || continue
      rest=$(sed -E 's/^[[:space:]]*[-*+][[:space:]]*//' <<<"$l"); rest=${rest/"$p"/}; rest=${rest//\`/}
      rest=$(sed -E 's/^([[:space:]]|:|—|-)+//; s/[[:space:]]+$//' <<<"$rest")
      _psc_tc_add "$p" "TEST-CHANGE: $p — $rest"
    done < <(_psc_section "$plan" 'tests that must change')
    while IFS= read -r l; do
      _psc_tc_path "$l" && _psc_tc_add "$p" "$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$l")"
    done < <(grep -E '^[[:space:]]*TEST-CHANGE:' "$plan")
  fi
  # Captured first: a grep on a git pipe is a SIGPIPE race under pipefail.
  if [ -n "$base" ] && log=$(git log --format=%B "$base..HEAD" 2>/dev/null); then
    while IFS= read -r l; do
      _psc_tc_path "$l" && _psc_tc_add "$p" "$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$l")"
    done < <(grep -E '^[[:space:]]*TEST-CHANGE:' <<<"$log")
  fi
  [ -n "$out" ] || return 0
  printf '\n## Test changes\n\nEach test of another ticket this PR edits, and the premise this PR changes (D65).\n\n%s' "$out"
}

# psc_plan_missing <repo> <base> <head> <body-file> [param] — the files the
#   plan-files rule refuses, one a line: changed in base...head, not a param
#   glob, not named by the plan's `## Files to touch`, and with no reason line
#   under the body's `## Files outside the plan`. An empty param reads the
#   plan-files row's globs from the catalog. rc 0 computed (no output = none
#   missing) | 2 the diff carries no .harness/specs/*/plan.md with a
#   `Files to touch` section | 3 no temp file for the plan. Callers: psc_check
#   and the builder's pre-open check (_pr_self_check_prepush, bin/lib/rb/pr.sh).
psc_plan_missing() {
  local repo="$1" base="$2" head="$3" body="$4" param="${5:-}" files plan pf reasons f
  [ -n "$param" ] || param=$(_psc_rows | awk -F'\t' '$1 == "plan-files" {print $3; exit}')
  files=$(git -C "$repo" diff --no-renames --name-only "$base...$head" 2>/dev/null) || return 2
  plan=$(grep -E '^\.harness/specs/[^/]+/plan\.md$' <<<"$files" | head -1)
  # Into a file first, never `git show | grep -q`: the early exit is a
  # SIGPIPE on git, and pipefail would turn a found section into "none".
  # A private temp file: the caller's body directory may be read-only.
  pf=$(mktemp "${TMPDIR:-/tmp}/psc-plan.XXXXXX" 2>/dev/null) || return 3
  [ -n "$plan" ] && git -C "$repo" show "$head:$plan" > "$pf" 2>/dev/null
  if ! grep -qiE '^#+[[:space:]]+files to touch' "$pf"; then
    rm -f "$pf"; return 2
  fi
  reasons=$(_psc_section "$body" 'files outside the plan')
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    _psc_ignored "$f" "$param" && continue
    _psc_section "$pf" 'files to touch' | grep -qF -- "$f" && continue
    # a reason line names the path and says something after it
    grep -F -- "$f" <<<"$reasons" | grep -qE "$(printf '%s' "$f" | sed 's/[.[\*^$/]/\\&/g')[\`]*[[:space:]]*[:—-]+[[:space:]]*[^[:space:]]" && continue
    printf '%s\n' "$f"
  done <<<"$files"
  rm -f "$pf"
  return 0
}

# psc_gating_check, the body-live-probes-gating rule (BH-7074). Missing = the
# rule is a NOTE, never a refusal.
# shellcheck source=bin/lib/pr-self-check-gating.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-self-check-gating.sh" 2>/dev/null || :
# psc_validate_check, the plan-validate rule (BH-7072). Missing = a NOTE.
# shellcheck source=bin/lib/pr-self-check-validate.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-self-check-validate.sh" 2>/dev/null || :
# psc_requires_check, the body-plan-requires rule (BH-7378). Missing = one
# NOTE that the items are not checked.
# shellcheck source=bin/lib/pr-body-requires.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-body-requires.sh" 2>/dev/null || :
# psc_cnp_check, the callers-not-ported rule (BH-7815). Missing = one NOTE
# that deleted paths are not checked.
# shellcheck source=bin/lib/callers-not-ported.sh
. "$(dirname "${BASH_SOURCE[0]}")/callers-not-ported.sh" 2>/dev/null || :

psc_check() {
  local repo="${1:-}" base="${2:-}" head="${3:-}" body="${4:-}" ticket="${5:-${PSC_TICKET_FILE:-}}"
  local rows id mode param match what rc=0 files s full later f nm missing frc ek
  local md pk pkr tk others tc n roots bk lf sub lk lr owners own nk
  [ -d "$repo" ] && [ -r "$body" ] || { echo "pr-self-check: no repo or no body"; return 2; }
  head=$(git -C "$repo" rev-parse -q --verify "$head^{commit}" 2>/dev/null) || { echo "pr-self-check: head does not resolve"; return 2; }
  git -C "$repo" rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1 || { echo "pr-self-check: base $base does not resolve"; return 2; }
  _PSC_PERF=""
  rows=$(_psc_rows) || { echo "pr-self-check: no catalog"; return 2; }
  files=$(git -C "$repo" diff --no-renames --name-only "$base...$head" 2>/dev/null) || { echo "pr-self-check: the diff will not read"; return 2; }
  _psc_say() { # <mode> <rule> <text>
    case "$1" in refuse) echo "REFUSE $2: $3"; rc=1 ;; note) echo "NOTE $2: $3" ;; esac
  }
  while IFS=$'\t' read -r id mode param match what; do
    [ "$mode" = off ] && continue
    # --only (PR_SELF_CHECK_ONLY, an ERE on the rule id): the build's fix-body
    # round and CI run the body rules alone.
    if [ -n "${PR_SELF_CHECK_ONLY:-}" ] && ! grep -qE -- "$PR_SELF_CHECK_ONLY" <<<"$id"; then continue; fi
    case "$id" in
      closes-not-met)
        if nm=$(_psc_closes_not_met "$body"); then
          _psc_say "$mode" "$id" "the body closes the issue, but an acceptance item is not met ($(head -1 <<<"$nm" | sed 's/^[[:space:]]*//' | cut -c1-120)); say Refs #N and list what is left"
        fi ;;
      evidence-head)
        s=$(_psc_evidence_shas "$body")
        if [ -z "$s" ]; then
          echo "NOTE $id: no evidence sha in the body (\`head <sha>\` in a heading, or <!-- evidence-head: <sha> -->)"
          continue
        fi
        # THE TREE DECIDES, NOT THE HISTORY (lead review lr-5828): the evidence
        # still holds when no file this PR changes differs between the
        # evidence sha and the head (param globs excepted). That keeps a
        # conductor rebase, which moves the sha out of the head's history, from
        # reading as stale. When a PR file did change after it, a human's own
        # `head <sha>` claim is refused, and the builder's marker is a NOTE: a
        # fix round pushes new heads and never rewrites the body, so holding
        # every fixed PR for it would stall them all.
        while read -r ek s; do
          [ -n "$s" ] || continue
          if ! full=$(git -C "$repo" rev-parse -q --verify "$s^{commit}" 2>/dev/null); then
            # The hub clone fetches only the base and the head, so after a
            # rebase the builder's old marker sha is not there (lead review
            # lr-5828-da3826282). The marker is the build's own record: a NOTE.
            # A human's own claim still has to name a sha the repo has.
            if [ "$ek" = marker ]; then
              echo "NOTE $id: the builder's evidence is on ${s:0:12}, which this clone does not have (an older head before a rebase); the lead review reads the head"
            else
              _psc_say "$mode" "$id" "evidence names ${s:0:12}, which this repo does not have"
            fi
            continue
          fi
          [ "$full" = "$head" ] && continue
          later=""
          while IFS= read -r f; do
            [ -n "$f" ] || continue
            _psc_ignored "$f" "$param" && continue
            grep -qxF -- "$f" <<<"$files" && later="$later $f"
          done < <(git -C "$repo" diff --no-renames --name-only "$full" "$head" 2>/dev/null)
          [ -z "$later" ] && continue
          if [ "$ek" = marker ]; then
            echo "NOTE $id: the builder's evidence is on ${s:0:12}, and the PR's files changed after it:$(printf '%s' "$later" | cut -c1-200); the lead review reads the head"
          elif git -C "$repo" merge-base --is-ancestor "$full" "$head" 2>/dev/null; then
            _psc_say "$mode" "$id" "evidence names ${s:0:12}, but the PR's files changed after it:$(printf '%s' "$later" | cut -c1-200); rerun it on ${head:0:12}"
          else
            _psc_say "$mode" "$id" "evidence names ${s:0:12}, which is not in the head's history and whose PR files differ from the head:$(printf '%s' "$later" | cut -c1-200)"
          fi
        done <<<"$s" ;;
      plan-files)
        missing=$(psc_plan_missing "$repo" "$base" "$head" "$body" "$param"); frc=$?
        case "$frc" in
          2) echo "NOTE $id: no plan with a \"Files to touch\" section in this PR"; continue ;;
          3) echo "NOTE $id: no temp file for the plan"; continue ;;
        esac
        missing=$(printf '%s\n' "$missing" | awk 'NF { printf " %s", $0 }')
        [ -z "$missing" ] || _psc_say "$mode" "$id" "files not in the plan's \"Files to touch\" and with no reason under \"## Files outside the plan\":$(printf '%s' "$missing" | cut -c1-300)" ;;
      test-ownership)
        # BH-6392: a test belongs to its ticket (D51). Modified or deleted only:
        # an added file conflicts with nobody. Captured before any grep.
        md=$(git -C "$repo" diff --no-renames --diff-filter=MD --name-only "$base...$head" 2>/dev/null)
        pk=$(_psc_pr_key "$body" "$files"); pkr=$(_psc_key_root "$pk")
        others=""
        while IFS= read -r f; do
          [ -n "$f" ] || continue
          tk=$(_psc_test_key "$f"); [ -n "$tk" ] || continue
          _psc_ignored "$f" "$param" && continue
          [ -n "$pkr" ] && [ "$(_psc_key_root "$tk")" = "$pkr" ] && continue
          others="$others$f"$'\n'
        done <<<"$md"
        [ -n "$others" ] || continue
        if [ -z "$pk" ]; then
          echo "NOTE $id: the PR edits tests of a ticket ($(printf '%s' "$others" | tr '\n' ' ' | cut -c1-200)), but no ticket key names this PR (--key, Harness-Ticket:, the first body line or one .harness/specs/<KEY>/plan.md), so ownership is not checked"
          continue
        fi
        tc=$(grep -E '^[[:space:]>*+-]*`?TEST-CHANGE:' "$body")
        n=0
        while IFS= read -r f; do
          [ -n "$f" ] || continue
          _psc_test_change_ok "$tc" "$f"; frc=$?
          [ "$frc" = 0 ] && continue
          n=$((n+1)); [ "$n" -le 10 ] || continue
          if [ "$frc" = 3 ]; then
            _psc_say "$mode" "$id" "$f is a test of $(_psc_test_key "$f" | tr 'a-z' 'A-Z'), and its TEST-CHANGE: line names no premise; say which premise of this PR ($pk) changes it, in 3 or more words"
          else
            _psc_say "$mode" "$id" "$f is a test of $(_psc_test_key "$f" | tr 'a-z' 'A-Z'), not of $pk; put new cases in this ticket's own test file, or add 'TEST-CHANGE: $f — <the premise this PR changes>' to the body"
          fi
        done <<<"$others"
        if [ "$n" -gt 10 ]; then _psc_say "$mode" "$id" "and $((n - 10)) more"; fi ;;
      foreign-commits)
        # BH-6394 (D66): a PR carries only its own ticket's commits. The walk
        # is first-parent and non-merge: a commit that came in through a merge
        # of main is not this PR's. Into a file first (the plan-files SIGPIPE note).
        lf=$(mktemp "${TMPDIR:-/tmp}/psc-log.XXXXXX" 2>/dev/null) || { echo "NOTE $id: no temp file for the commit log"; continue; }
        if ! git -C "$repo" log --first-parent --no-merges --format='%H%x09%s' "$base..$head" > "$lf" 2>/dev/null; then
          rm -f "$lf"; echo "NOTE $id: the commit log of $base..$head will not read"; continue
        fi
        pk=$(_psc_pr_key "$body" "$files"); roots=$(_psc_own_roots "$pk" "$body")
        bk=$(_psc_base_key "$base"); owners=""; n=0; nk=0
        while IFS=$'\t' read -r s sub; do
          [ -n "$s" ] || continue
          lk=$(_psc_lead_key "$sub"); [ -n "$lk" ] || continue
          if [ -z "$pk" ]; then
            echo "NOTE $id: ${s:0:12} leads with $lk, but no ticket key names this PR (--key, Harness-Ticket:, the first body line or one .harness/specs/<KEY>/plan.md), so ownership is not checked"
            break
          fi
          # Same prefix only: `UTF-8: ...` is not a ticket of this board.
          [ "$(_psc_key_root "${lk%%-*}")" = "$(_psc_key_root "${pk%%-*}")" ] || continue
          lr=$(_psc_key_root "$lk")
          grep -qxF -- "$lr" <<<"$roots" && continue
          [ -n "$bk" ] && [ "$lr" = "$bk" ] && continue
          _psc_stacked_wait "$body" "$head" && continue
          n=$((n+1)); [ "$n" -le 10 ] || continue
          own=$(awk -F'\t' -v k="$lr" '$1==k {print $2; exit}' <<<"$owners")
          if [ -z "$own" ]; then
            # At most 3 owner lookups per check; past that, the branch name.
            nk=$((nk+1))
            if [ "$nk" -le 3 ]; then own=$(_psc_owner_pr "$lr" "$repo" "$body"); else own="the PR of ticket/$lr"; fi
            owners="$owners$lr"$'\t'"$own"$'\n'
          fi
          _psc_say "$mode" "$id" "${s:0:12} \"$(printf '%s' "$sub" | cut -c1-80)\" is a commit of $lk ($own), not of $pk; stack on ticket/$lr as the base, or merge main after that PR merges; never copy its commits"
        done < "$lf"
        rm -f "$lf"
        if [ "$n" -gt 10 ]; then _psc_say "$mode" "$id" "and $((n - 10)) more"; fi ;;
      body-live-probes-gating)
        # BH-7074: a gating diff (a lane_placement.* / *.require_* settings
        # seed in worker/jobs/schema.d/, a new && precondition on a cron lane,
        # a read of a catalog/live-probes.tsv route in bin/) must carry a
        # fenced live-probes block with probe lines and a KILL KNOB: line.
        # bin/lib/pr-self-check-gating.sh has the rule.
        if command -v psc_gating_check >/dev/null 2>&1; then
          psc_gating_check "$repo" "$base" "$head" "$body" "$mode" "$id" || rc=1
        else
          echo "NOTE $id: bin/lib/pr-self-check-gating.sh not loaded, so gating diffs are not checked"
        fi ;;
      plan-validate)
        # BH-7072: the plan's static VALIDATE checks, the body's not-met and
        # Target metric lines; bin/lib/pr-self-check-validate.sh has the rule.
        if command -v psc_validate_check >/dev/null 2>&1; then
          psc_validate_check "$repo" "$base" "$head" "$body" "$mode" "$id" || rc=1
        else
          echo "NOTE $id: bin/lib/pr-self-check-validate.sh not loaded, so plan VALIDATE lines are not checked"
        fi ;;
      body-plan-requires)
        # BH-7378: each item of the plan's ```pr-body-requires block that the
        # body lacks is one NOTE. Every mode but off reads as note, and rc is
        # never touched: the rule never refuses and never changes the verdict.
        if command -v psc_requires_check >/dev/null 2>&1; then
          psc_requires_check "$repo" "$base" "$head" "$body" "$id" "$files" || :
        else
          echo "NOTE $id: bin/lib/pr-body-requires.sh not loaded, so required body items are not checked"
        fi ;;
      callers-not-ported)
        # BH-7815: each place the merge of the base and the head still names a
        # path the PR deletes or renames is one NOTE. Every mode but off reads
        # as note, and rc is never touched.
        if command -v psc_cnp_check >/dev/null 2>&1; then
          psc_cnp_check "$repo" "$base" "$head" "$id" || :
        else
          echo "NOTE $id: bin/lib/callers-not-ported.sh not loaded, so deleted paths are not checked"
        fi ;;
      body-*)
        # BH-5790: a PR-body section the lead review would BLOCK on. When it
        # applies (param) the body must show it (match); both are catalog data.
        _psc_body_fires "$repo" "$base" "$head" "$param" "$files" "$ticket"; frc=$?
        case "$frc" in
          0) _psc_body_shows "$body" "$match" \
               || _psc_say "$mode" "$id" "the body is missing $what (add it to the PR body; catalog/pr-self-check.tsv says what counts)" ;;
          3) echo "NOTE $id: ${_PSC_UNK_WHY:-no ticket text}, so whether the ticket asks for it is unknown ($what)" ;;
        esac ;;
      *) echo "NOTE $id: no such rule in bin/lib/pr-self-check.sh (catalog row ignored)" ;;
    esac
  done <<<"$rows"
  return "$rc"
}
