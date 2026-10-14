#!/bin/bash
# bin/lib/fc-issues.sh — the GitHub-Issues lane module of the child filer
# (bin/lib/file-children.sh). It files one issue per child on the parent's repo,
# writes the parent's split comment and takes the `ai-build` label off the
# master. This is where the filing loop of bin/run-decompose.sh lives since
# BH-982; the script above it keeps the model call, the spec validation and the
# size/chain gates, and calls `file_children` once.
#
# ITS INPUTS ARE THE FC_* VARIABLES file_children SETS, never arguments:
#   FC_PROJECT  fleet.conf project name
#   FC_PARENT   the parent ticket id (an issue number on this lane)
#   FC_KEY      the parent key, e.g. TK-552 — children are KEY.0, KEY.1, …
#   FC_BUILD    the build directory (children/, children.txt, decompose-gh.log)
#   FC_SPEC     children.json, ALREADY VALIDATED by the caller
#   FC_KIND     decompose (contract child + parallel siblings) or rollout
#                (ordered waves, each blocked on the ones its author named)
#                or slice (the remaining slices of a merged SLICE plan, filed
#                by bin/lib/slice-remainder.sh; rollout's rules, its own
#                title, footer and parent comment, FC_SLICE_BASE = the merged
#                C<k>, FC_SLICE_PR = the merged PR number)
#   FC_LANE     issues, which is why this module was sourced
#   FC_PARENT_NOTE  0 = post no parent comment and leave the parent's label
#                alone: the caller (bin/lib/slice-closeout.sh, BH-6308) closes
#                the parent with its own comment. Default 1.
#
# Sourced, never executed: no `set -e`, no `exit`, no side effect at source
# time, same shape as bin/lib/file-children.sh and for the same reason — a
# sourced `exit` kills the lane that sourced it. So a failure RETURNS nonzero
# and leaves its reason in FC_ERROR, which is what the caller puts in its own
# FAIL line ($BUILD/decompose-run.txt is the artifact the sweep SOP reads).
#
# THE BODY TEXT IS NOT DECIDED HERE. fc_child_title and fc_child_footer in
# bin/lib/file-children.sh own it, because four other scripts parse those exact
# lines: bin/unblocked-children.sh launches a child off `Blocked-by: #<n>`,
# bin/lib/dep-verify-lib.sh reads the `(hard)` suffix,
# bin/decompose-parent-close.sh counts `Part of #N` / `Order: n of N`, and
# bin/size-gate.sh reads the size budget line. This file decides only WHICH
# issues block a child; how the line reads is the contract's.
#
# WHAT ROLLOUT CHANGES, and nothing else does: there is no contract child (wave
# 1 is an ordinary wave, titled `.1`), a wave's blockers come only from the
# positions its own `after` list names, there are no DEPENDS lines and no size
# budget, and the parent comment says waves instead of parts. Labels,
# children.txt, decompose-gh.log, the dry-run print and the parking of the
# master are identical to decompose.

# BH-1650: every read and write below except `gh issue create` goes through the
# REST contract. Guarded, because run-decompose.sh and run-rollout.sh source
# this file without having sourced gh-rest.sh themselves.
if ! command -v gh_rest >/dev/null 2>&1 && [ -r "$(dirname "${BASH_SOURCE[0]}")/gh-rest.sh" ]; then
  . "$(dirname "${BASH_SOURCE[0]}")/gh-rest.sh"
fi

# BH-4075: the parent-side calls (label read, split comment, unlabel) go through
# the tracker contract's GitHub adapter, bin/lib/tracker/github-issues.sh. Beside
# this file first, $HARNESS/bin/lib second; without it fc_file_issues files
# nothing (the parent could not be parked).
if ! command -v trk_gh_comment >/dev/null 2>&1; then
  _fci_d="$(dirname "${BASH_SOURCE[0]}")"
  if [ ! -r "$_fci_d/tracker/github-issues.sh" ] && [ -n "${HARNESS:-${H:-}}" ]; then _fci_d="${HARNESS:-${H:-}}/bin/lib"; fi
  if [ -r "$_fci_d/tracker.sh" ] && [ -r "$_fci_d/tracker/github-issues.sh" ]; then
    # shellcheck source=bin/lib/tracker.sh
    . "$_fci_d/tracker.sh"
    # shellcheck source=bin/lib/tracker/github-issues.sh
    . "$_fci_d/tracker/github-issues.sh"
  fi
  unset _fci_d
fi

# fc_parent_labels <slug> <num> — the parent's label names, one per line. A
# read that did not answer 2xx prints nothing, so nothing is inherited or removed.
# ONE GET: the adapter's label read, not tracker_read, which also pages the thread.
fc_parent_labels() {
  command -v trk_gh_labels >/dev/null 2>&1 || return 0
  TRK_SLUG="$1" trk_gh_labels "$2" 2>/dev/null
  return 0
}

# fc_unlabel_parent <slug> <num> — DELETE the ai-build label. 404 (44) means
# it was not there, which is the state this wanted: success.
fc_unlabel_parent() {
  local rc=0
  command -v trk_gh_label_remove >/dev/null 2>&1 || return 1
  TRK_SLUG="$1" TRK_LOG="" TRK_DRY=0 trk_gh_label_remove "$2" ai-build >/dev/null 2>&1 || rc=$?
  return "$rc"
}

# fc_file_issues — files every child in FC_SPEC. 0 = filed (or nothing to
# re-file), 1 = a create failed and FC_ERROR says which child and why.
fc_file_issues() {
  local DRY=0; fc_dry && DRY=1
  local HARNESS="${HARNESS:-/root/harness}"
  local ISSUE GH_REPO N CONTRACT fcs OWNS
  local VOCAB PARENT_LABELS LBL_SRC INHERITED ONE MATCH V LBL_SET LBL_NOTE LBL_FLAGS
  local CHILDREN_DIR GHLOG PREFIX LINKS i n TITLE BODY BLOCK DEPENDS AFTERS A P p SYM F CT NUM URL
  local SG_DECL SG_OVER SG_BUDGET COMMENT DRYNOTE _FRESH
  local PATHS_DIR PF CONTRACT_PATHS CP_RC CONTESTED_ALL CONTESTED CHILD_PATHS CHP_RC SHARED sp CONTESTED_NOTE
  local EXTRACT_FAILED EXTRACT_NOTE INDEP INDEP_WHY CONTRACT_TOKENS INDEP_SHARED
  local NUMS=() LBL_ARGS=()
  local EXISTING=() EXISTING_TITLE EXISTING_NUM EV_RC EV_T FC_UL _ei _eln _PL FILED_NEW=0
  # Callable directly (the rollout lane's caller is a later slice), so the
  # inputs get the same defaults file_children would have set, and `set -u` in
  # that caller cannot kill this function on an unset name.
  FC_PROJECT="${FC_PROJECT:-}"; FC_PARENT="${FC_PARENT:-}"; FC_KEY="${FC_KEY:-}"
  FC_BUILD="${FC_BUILD:-}"; FC_SPEC="${FC_SPEC:-}"; FC_KIND="${FC_KIND:-decompose}"
  FC_ERROR=""
  # Without the adapter the master could not be commented on or unparked, so
  # nothing is filed at all (BH-4075). A dry run refuses too: it predicts the run.
  if ! command -v trk_gh_comment >/dev/null 2>&1; then
    FC_ERROR="tracker adapter bin/lib/tracker/github-issues.sh not found beside $(dirname "${BASH_SOURCE[0]}") or in \$HARNESS/bin/lib — nothing filed"
    fc_log "$FC_BUILD" "$FC_ERROR"
    return 1
  fi

  # Dry-run cannot verify synthetic issue titles, so a non-empty children.txt
  # still means "do nothing" — this preserves every existing dry-run test.
  # Real-mode runs resume below by reconciling ordinals against the spec.
  if [ -s "$FC_BUILD/children.txt" ] && [ "$DRY" = 1 ]; then
    fc_log "$FC_BUILD" "already decomposed into: $(paste -sd, "$FC_BUILD/children.txt") — nothing re-filed"
    return 0
  fi

  # RESUME: load any children already filed in a previous run. Ordinals are
  # 0-based positions in the spec; line n of children.txt corresponds to child
  # n+1.
  #
  # THE RECORD IS APPEND-ONLY (review of PR #1400). children.txt is the only
  # evidence that a child exists on the client's repo, and nothing on the resume
  # path rewrites it: a recorded child is re-proven and its line left exactly as
  # written, and only an ordinal this run files itself is appended. Truncating
  # first and rebuilding line by line — what this did — meant a 502 on a title
  # read, or a container going away mid-loop, erased children that really exist,
  # and the next rerun filed a second set of issues on someone's repo.
  EXISTING=(); EXISTING_TITLE=""; EXISTING_NUM=""; _ei=""; _eln=0
  if [ -s "$FC_BUILD/children.txt" ]; then
    # `|| [ -n "$_ei" ]`: read -r returns 1 on a final line with no newline but
    # still fills the variable, so without it the last child on a hand-edited
    # record was invisible — a one-line record read as EMPTY, the truncation
    # below fired, and the rerun re-filed every child on the client's repo and
    # reported success (BH-1482).
    while IFS= read -r _ei || [ -n "$_ei" ]; do
      _eln=$((_eln + 1))
      # EVERY LINE IS A CHILD KEY OR THE RUN STOPS HERE. A blank or malformed
      # line used to read as "no child at this ordinal", so a child was filed
      # for it and appended after the real lines — wrong ordinals on every
      # later rerun. The record is the only evidence of issues that exist on
      # someone's repo; a line we cannot read is theirs to fix, not ours to
      # skip. Same key shape the ISSUE derivation below accepts, so a CRLF or
      # a stray space is named here rather than trimmed into a guess.
      if ! grep -qE '^[A-Za-z]+-[0-9]+$' <<<"$_ei"; then
        FC_ERROR="children.txt line $_eln is not a child key ('$_ei') — left as it was, resolve by hand"
        fc_log "$FC_BUILD" "$FC_ERROR"; return 1
      fi
      EXISTING+=("$_ei")
    done < "$FC_BUILD/children.txt"
  fi
  FILED_NEW=0

  # The same three resolutions bin/run-decompose.sh:113-119 makes, re-derived
  # here because the library is handed a project and a parent, not a parsed one.
  GH_REPO="${GH_ISSUES_REPO:-}"
  if [ -z "$GH_REPO" ]; then
    fcs="$(_fc_dir)/../fleet-conf.sh"
    [ -x "$fcs" ] || fcs="$HARNESS/bin/fleet-conf.sh"
    [ -x "$fcs" ] && GH_REPO=$("$fcs" "$FC_PROJECT" repo 2>/dev/null || true)
  fi
  case "$FC_PARENT" in
    ''|*[!0-9]*) ISSUE=$(sed -nE 's/^[A-Za-z]+-([0-9]+)$/\1/p' <<<"$FC_KEY") ;;
    *)           ISSUE="$FC_PARENT" ;;
  esac
  if [ -z "$GH_REPO" ]; then
    FC_ERROR="no GitHub repo for this project in fleet.conf"
    fc_log "$FC_BUILD" "$FC_ERROR"; return 1
  fi
  if [ -z "$ISSUE" ]; then
    FC_ERROR="cannot derive an issue number from parent '$FC_PARENT' / key '$FC_KEY'"
    fc_log "$FC_BUILD" "$FC_ERROR"; return 1
  fi
  # The spec's SHAPE is the caller's to validate (2-5 children, titles, bodies,
  # the contract field, the chain cap). What this reads is the count it has to
  # loop over, and a count it cannot read is a failure, never a zero-child run.
  N=$(jq 'length' "$FC_SPEC" 2>/dev/null)
  case "${N:-}" in
    ''|*[!0-9]*)
      FC_ERROR="cannot read a child count from $FC_SPEC"
      fc_log "$FC_BUILD" "$FC_ERROR"; return 1 ;;
  esac
  # A RECORD LONGER THAN THE SPEC IS NOT THIS RUN'S TO TRIM. The loop below only
  # walks N ordinals, so extra lines would sit outside it — and the rewrite this
  # replaced dropped them without a word. They are real issue numbers on a real
  # repo, so the honest answer is to stop and say the two counts disagree.
  if [ "${#EXISTING[@]}" -gt "$N" ]; then
    FC_ERROR="children.txt records ${#EXISTING[@]} children but the spec has $N: $(paste -sd, "$FC_BUILD/children.txt") — left as it was, resolve by hand"
    fc_log "$FC_BUILD" "$FC_ERROR"; return 1
  fi
  if [ "$FC_KIND" = rollout ] || [ "$FC_KIND" = slice ]; then
    # A wave has no contract by definition; a `contract` field on a rollout spec
    # is not this lane's to read.
    CONTRACT=""
  else
    CONTRACT=$(jq -r 'if ((.[0].contract? // "") | type) == "string" then (.[0].contract // "") else "" end' "$FC_SPEC" 2>/dev/null)
  fi

  # The repo this box can actually see. The hub's default PAT 404s on at least
  # one fleet repo (2026-09-12, the 10-hour project-5 loss), and a split that
  # files nothing because the token cannot see the repo must not look like a
  # model that refused.
  # shellcheck source=bin/lib/gh-repo-token.sh
  [ -r "$HARNESS/bin/lib/gh-repo-token.sh" ] && . "$HARNESS/bin/lib/gh-repo-token.sh"
  # A token that is alive NOW, not the one this lane inherited at build start.
  # That inherited token is a one-hour App installation token; a split past the
  # 12-file cap takes longer to plan than that, and on a watcher box nothing
  # refreshes it (gh-token-live.sh only knows pool machines). 2026-09-15 20:34Z:
  # eight resilience tickets (BH-390..BH-403) parked DECOMPOSE_FAILED because
  # child 1's `gh issue create` answered "Try authenticating with: gh auth login".
  if _FRESH=$("$HARNESS/bin/gh-token.sh" "$GH_REPO" 2>/dev/null) && [ -n "$_FRESH" ]; then
    export GH_TOKEN="$_FRESH"
  else
    command -v gh_repo_use_token >/dev/null 2>&1 && gh_repo_use_token "$GH_REPO"
  fi

  # ---- THE CHILDREN INHERIT THE PARENT'S LABELS (BH-637 §2) ---------------
  # A parent carrying `ai-build,hotfix` used to produce children filed with the
  # literal `--label ai-build`, so every consumer that selects on the hotfix
  # label skipped them in silence and a human merged the lot by hand. A split
  # child is the same work as its parent; it inherits the parent's urgency.
  #
  # THE VOCABULARY IS A WHITELIST, never a copy of everything. `not-hotfix` is
  # somebody saying this is NOT urgent and `hotfix-candidate` is somebody
  # asking, so a substring or blanket copy would spend a cap exemption nobody
  # granted. Names match whole, case-insensitively, trimmed — the same rule
  # bin/lib/hotfix-lib.sh applies. `bug` is deliberately NOT in the default set:
  # bin/kind-gate.sh reads it as the deterministic KIND signal and
  # bin/repro-gate.sh would then demand a reproduction from a contract child
  # that contains nothing but types. An operator who wants it adds it to
  # DECOMPOSE_INHERIT_LABELS in env/global.env.
  #
  # NO EXTRA GitHub CALL in the common path: bin/run-build.sh already wrote the
  # parent's labels to $BUILD/ticket-meta.json (`gh issue view --json
  # title,labels`) before the size gate reached this script. A real run without
  # that file asks GitHub once; a DRY run never does. No answer is not an error
  # and not a guess — the children get `ai-build` alone and the log says so.
  # shellcheck source=bin/lib/hotfix-lib.sh
  if [ -r "$(dirname "$0")/lib/hotfix-lib.sh" ]; then . "$(dirname "$0")/lib/hotfix-lib.sh" 2>/dev/null
  elif [ -r "$HARNESS/bin/lib/hotfix-lib.sh" ]; then . "$HARNESS/bin/lib/hotfix-lib.sh" 2>/dev/null
  fi
  if command -v hotfix_label >/dev/null 2>&1; then VOCAB="ai-build,$(hotfix_label "$HARNESS")"
  else VOCAB="ai-build,hotfix"; fi
  # Read, never sourced: the operator list is a name list, not a secret store.
  if command -v _hotfix_env >/dev/null 2>&1; then
    VOCAB="$VOCAB,$(_hotfix_env "$HARNESS" DECOMPOSE_INHERIT_LABELS "")"
  else
    VOCAB="$VOCAB,${DECOMPOSE_INHERIT_LABELS:-}"
  fi
  PARENT_LABELS=""; LBL_SRC=""
  if [ -s "$FC_BUILD/ticket-meta.json" ]; then
    # Both shapes: gh's [{"name":"x"}] and a board's bare ["x"] — the same
    # expression bin/kind-gate.sh reads labels with.
    PARENT_LABELS=$(jq -r '[(.labels // [])[]? | if type=="object" then (.name // "") else tostring end] | .[]' \
                    "$FC_BUILD/ticket-meta.json" 2>/dev/null)
    LBL_SRC="parent #$ISSUE"
  elif [ "$DRY" != 1 ]; then
    PARENT_LABELS=$(fc_parent_labels "$GH_REPO" "$ISSUE")
    # Set whether or not the read answered: the log line must say what was
    # ASKED, so "nothing inherited" after a refused read cannot read as "the
    # parent had no labels".
    LBL_SRC="parent #$ISSUE (read from GitHub — no ticket-meta.json in this record)"
  fi
  # `ai-build` is applied whether or not the parent still carries it: a RESUME
  # after the parent was un-labelled (this script takes the label off at the end
  # of a split) must still file children a watcher can see.
  LBL_ARGS=(--label ai-build); INHERITED=""
  while IFS= read -r ONE; do
    ONE=$(printf '%s' "$ONE" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')
    [ -n "$ONE" ] || continue
    [ "$ONE" = "ai-build" ] && continue
    case ",$INHERITED," in *",$ONE,"*) continue ;; esac
    MATCH=""
    while IFS= read -r V; do
      V=$(printf '%s' "$V" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')
      [ -n "$V" ] && [ "$V" = "$ONE" ] && { MATCH=1; break; }
    done < <(printf '%s\n' "$VOCAB" | tr ',' '\n')
    [ -n "$MATCH" ] || continue
    LBL_ARGS+=(--label "$ONE")
    INHERITED="${INHERITED:+$INHERITED,}$ONE"
  done < <(printf '%s\n' "$PARENT_LABELS")
  LBL_SET="ai-build${INHERITED:+,$INHERITED}"
  if [ -n "$INHERITED" ]; then LBL_NOTE="inherited from ${LBL_SRC:-the parent}: $INHERITED"
  elif [ -n "$LBL_SRC" ];  then LBL_NOTE="nothing inherited from ${LBL_SRC}"
  else                          LBL_NOTE="nothing inherited — no parent labels in this build record"; fi

  # ---- THE PATHS THE CONTRACT OWNS (BH-579.4) -----------------------------
  # A sibling that names a file the contract is moving is working on ground that
  # shifts under it, and the body it is handed says nothing about that today. So
  # the filer writes it down: `CONTESTED: <path> -> #<contract>` in that
  # sibling's body and again in the split comment. It is informational — the
  # hard blocker BH-481 already puts on every sibling is what orders the work.
  #
  # DECOMPOSE ONLY: a rollout wave has no contract (CONTRACT is already forced
  # empty above), so there is no "the contract's paths" to compute and no
  # sibling gets a line — this whole block is skipped for FC_KIND=rollout.
  #
  # bin/planned-files.sh is THE ONE EXTRACTOR: it is what every reader of a
  # planned-files list runs (bin/lib/dep-verify-lib.sh, bin/plan-overlap.sh), so
  # "the paths this child names" cannot mean two different sets. It reads
  # <dir>/plan.md and writes <dir>/planned-files.txt. Its prefix list is not
  # widened here: a path it does not extract (this repo's own bin/, for one)
  # produces no line, which is the same caveat every other reader carries.
  CONTESTED_ALL=""
  # One line per body whose extraction RAN and FAILED, rendered in the split
  # comment below (BH-1343). Initialised outside the block so the rollout arm —
  # which never enters it — reads an empty string rather than dying on `set -u`.
  EXTRACT_FAILED=""
  if [ "$FC_KIND" != rollout ] && [ "$FC_KIND" != slice ]; then
    PATHS_DIR="$FC_BUILD/decompose-paths"; mkdir -p "$PATHS_DIR"
    PF="$HARNESS/bin/planned-files.sh"
    paths_of_body() { # paths_of_body <name> <text...> -> sorted unique paths on stdout; rc 2 = extractor ran and failed
      local d="$PATHS_DIR/$1"; shift
      local rc why line
      mkdir -p "$d"; printf '%s\n' "$@" > "$d/plan.md"
      [ -x "$PF" ] || return 0
      # STDERR TO A FILE, not /dev/null (BH-1343). The rc alone says the
      # extraction died, never why, and the extractor's own first line is the
      # only thing that does — without it the WARN below sends the next reader
      # off to run bin/planned-files.sh by hand to find out.
      "$PF" "$d" >/dev/null 2>"$d/planned-files.err"; rc=$?
      if [ "$rc" != 0 ]; then
        why="rc=$rc"
        line=$(grep -m1 -v '^[[:space:]]*$' "$d/planned-files.err" 2>/dev/null | cut -c1-200)
        [ -n "$line" ] && why="$why: $line"
        printf '%s\n' "$why" > "$d/extract-failed.txt"
        # planned-files.txt is left EXACTLY as the extractor left it. The real
        # bin/planned-files.sh writes it progressively (`>`, then `>>`, then a
        # rewrite), so a mid-run death leaves a partial list, and that partial
        # list is evidence of how far it got — worth logging, never worth
        # reading as a list. An incomplete list fed to the intersection below
        # produces "nothing shared" for paths that are, which is the exact
        # false negative this arm exists to refuse.
        return 2
      fi
      # LC_ALL=C here and on the comm below: one byte ordering, so the two lists
      # are sorted the way the intersection reads them on every box.
      LC_ALL=C sort -u "$d/planned-files.txt" 2>/dev/null
    }
    # The two halves of what a failed extraction leaves behind, read-only, for
    # the WARN and the comment line. Both answer for a body that never failed
    # too, so no caller has to guard them.
    # EVERY PATH-SHAPED TOKEN, with no prefix filter (BH-5520). planned-files.sh
    # keeps only src/, tests/, docs/ and the like, and in cromford the
    # product code is under bin/, so its list cannot prove that a sibling shares
    # no file with the contract. The independence check below reads this set
    # too, and only that check reads it: CONTESTED lines stay planned-files.sh's.
    path_tokens_of() { # path_tokens_of <text...> -> sorted unique a/b.ext tokens
      printf '%s\n' "$@" \
        | grep -oE '[][A-Za-z0-9_@()/.-]+\.(ts|tsx|js|jsx|mjs|cjs|sql|prisma|css|scss|json|sh|md|yml|yaml|py|conf|tsv|toml|txt|cron|go|rs)' \
        | sed 's|^\./||' | grep '/' | LC_ALL=C sort -u
    }
    paths_fail_reason() { # paths_fail_reason <name> -> `rc=<n>[: <stderr>]`
      local f="$PATHS_DIR/$1/extract-failed.txt"
      if [ -s "$f" ]; then cat "$f"; else printf 'rc=?\n'; fi
    }
    paths_partial() { # paths_partial <name> -> the partial list on one line, or `none`
      local f="$PATHS_DIR/$1/planned-files.txt" out=""
      [ -s "$f" ] && out=$(tr '\n' ' ' < "$f" | sed 's/[[:space:]]*$//')
      printf '%s\n' "${out:-none}"
    }
    # Absent is not "nothing overlaps" — both silences are logged, so a split with
    # no CONTESTED lines can be read as the answer it is. A present extractor that
    # RUNS and fails is the same rule, checked per call (rc 2): a swallowed
    # mid-run failure must not read as "nothing shared".
    [ -x "$PF" ] || fc_log "$FC_BUILD" "WARN: $PF is missing — no contested paths can be computed for this split"
    # The CONTRACT: string and child 1's body are ONE plan.md: the union is one
    # extractor run, not two lists merged by hand.
    CONTRACT_PATHS=$(paths_of_body contract "$CONTRACT" "$(jq -r '.[0].body' "$FC_SPEC")"); CP_RC=$?
    CONTRACT_TOKENS=$(path_tokens_of "$CONTRACT" "$(jq -r '.[0].body' "$FC_SPEC")")
    if [ "$CP_RC" = 2 ]; then
      fc_log "$FC_BUILD" "WARN: $PF failed on the contract body ($(paths_fail_reason contract)) — no contested paths can be computed for this split; partial list left in $PATHS_DIR/contract/planned-files.txt: $(paths_partial contract)"
      EXTRACT_FAILED="shared-file extraction failed: contract body ($(paths_fail_reason contract))"
    elif [ -z "$CONTRACT_PATHS" ]; then fc_log "$FC_BUILD" "the contract names no extractable path — no contested paths for this split"
    fi
  fi

  CHILDREN_DIR="$FC_BUILD/children"; mkdir -p "$CHILDREN_DIR"
  GHLOG="$FC_BUILD/decompose-gh.log"; : > "$GHLOG"
  # Only a run with nothing on the record starts the file. A resume appends to
  # what is already there and never rewrites it (see RESUME above).
  [ "${#EXISTING[@]}" -eq 0 ] && : > "$FC_BUILD/children.txt"
  PREFIX="${FC_KEY%-*}"
  NUMS=(); LINKS=""
  i=0
  while [ "$i" -lt "$N" ]; do
    n=$((i + 1))
    TITLE=$(jq -r --argjson i "$i" '.[$i].title' "$FC_SPEC")
    BODY=$(jq -r --argjson i "$i" '.[$i].body' "$FC_SPEC")
    # THE DECLARATIONS THIS CHILD CARRIES (BH-481). The contract is every
    # sibling's blocker and it is `(hard)`, because every sibling imports it:
    # bin/lib/dep-verify-lib.sh honours that suffix as the author's word and does
    # not argue, so nothing downstream second-guesses the one link that is always
    # real. The DEFAULT sibling has that blocker and no other, which is the whole
    # point: one parallel wave, not a chain.
    #
    # A DECLARED IMPORT FROM A SIBLING IS ALSO A BLOCKER (review of PR #513). In
    # this harness `Blocked-by` means "needs that chunk's CODE", and a spec that
    # says this slice imports sibling p's symbol is saying exactly that. Left as
    # a declaration only, the launcher would start it in the same wave as the
    # sibling it imports from and the build could not compile. So the number goes
    # on the SAME Blocked-by line, contract first, and the chain cap computed
    # above still bounds this at two levels — a declaration cannot grow a chain.
    # The `DEPENDS:` lines ride alongside in the shape prompts/plan-contract.md
    # §7 asks the child's own plan to carry.
    BLOCK=""; DEPENDS=""; CONTESTED=""; INDEP=""
    AFTERS=$(jq -r --argjson i "$i" '(.[$i].after // []) | .[] | tostring' "$FC_SPEC" 2>/dev/null)
    if [ "$FC_KIND" = rollout ] || [ "$FC_KIND" = slice ]; then
      # A WAVE WAITS ONLY ON THE WAVES ITS AUTHOR NAMED. There is no contract to
      # block everyone on, so an empty `after` is an empty blocker list and
      # fc_child_footer omits the line entirely. Same drop rule as decompose: a
      # position at or after this wave has no issue number yet, and a wave that
      # names itself is an author slip, so both are dropped out loud.
      while IFS= read -r A; do
        P=$(printf '%s' "${A%%:*}" | tr -d '[:space:]')
        case "$P" in ''|*[!0-9]*) continue ;; esac
        if [ "$P" -lt 1 ] || [ "$P" -ge "$n" ]; then
          fc_log "$FC_BUILD" "child $n: dropped 'after: $A' — a child can only depend on a sibling that lands before it"
        fi
      done <<<"$AFTERS"
      # Ascending, which is also the dedupe: a position named twice is rendered
      # once. `10` must not match position `1`, hence the non-digit anchor.
      p=1
      while [ "$p" -lt "$n" ]; do
        if grep -qE "^[[:space:]]*$p([^0-9]|\$)" <<<"$AFTERS"; then
          if [ -n "$BLOCK" ]; then BLOCK="$BLOCK, #${NUMS[$((p - 1))]} (hard)"
          else BLOCK="#${NUMS[$((p - 1))]} (hard)"; fi
        fi
        p=$((p + 1))
      done
    elif [ "$i" = 0 ]; then
      # The contract depends on nothing by definition. An `after` on it is a
      # model slip, and a slip that is ignored in silence is one nobody fixes.
      [ -n "$AFTERS" ] && fc_log "$FC_BUILD" "contract child: ignored 'after: $(paste -sd, <<<"$AFTERS")' — the contract is what the rest wait on, it waits on nothing"
    else
      BLOCK="#${NUMS[0]} (hard)"
      DEPENDS="DEPENDS: #${NUMS[0]} hard — this slice imports the contract ($CONTRACT)"
      # Only siblings ALREADY FILED can be named: GitHub hands out the numbers as
      # this loop runs, so a later sibling has none yet. A forward or self
      # reference is dropped out loud for the same reason.
      while IFS= read -r A; do
        P=$(printf '%s' "${A%%:*}" | tr -d '[:space:]')
        case "$P" in ''|*[!0-9]*) continue ;; esac
        [ "$P" = 1 ] && continue
        if [ "$P" -lt 1 ] || [ "$P" -ge "$n" ]; then
          fc_log "$FC_BUILD" "child $n: dropped 'after: $A' — a child can only depend on a sibling that lands before it"
        fi
      done <<<"$AFTERS"
      p=2
      while [ "$p" -lt "$n" ]; do
        SYM=$(printf '%s\n' "$AFTERS" | grep -E "^[[:space:]]*$p([^0-9]|\$)" | head -1 \
              | sed -E "s/^[[:space:]]*${p}[[:space:]]*:?[[:space:]]*//")
        if grep -qE "^[[:space:]]*$p([^0-9]|\$)" <<<"$AFTERS"; then
          [ -n "$SYM" ] || SYM="it imports this sibling's code"
          BLOCK="$BLOCK, #${NUMS[$((p - 1))]} (hard)"
          DEPENDS="$DEPENDS
DEPENDS: #${NUMS[$((p - 1))]} hard — $SYM"
        else
          DEPENDS="$DEPENDS
DEPENDS: #${NUMS[$((p - 1))]} soft — a separate slice of the same parent, no shared code"
        fi
        p=$((p + 1))
      done
      # WHICH OF THIS SIBLING'S PATHS THE CONTRACT ALSO NAMES. Two sorted,
      # deduped lists through `comm -12`: exact string match, so src/x.tsx is
      # not src/x.ts, and a body that names the same file twice yields one line.
      # An empty intersection writes nothing at all — the sibling's Blocked-by
      # and DEPENDS lines are untouched either way.
      CHP_RC=""
      if [ -n "$CONTRACT_PATHS" ]; then
        CHILD_PATHS=$(paths_of_body "child-$n" "$BODY"); CHP_RC=$?
        if [ "$CHP_RC" = 2 ]; then
          fc_log "$FC_BUILD" "WARN: $PF failed on child $n's body ($(paths_fail_reason "child-$n")) — no contested paths computed for this sibling; partial list left in $PATHS_DIR/child-$n/planned-files.txt: $(paths_partial "child-$n")"
          # $FC_KEY.$i, not "child $n": the number GitHub hands out is not known
          # until the create below, and the key is what the split comment's own
          # link list calls this child, so the reader can find it.
          EXTRACT_FAILED="${EXTRACT_FAILED:+$EXTRACT_FAILED
}shared-file extraction failed: $FC_KEY.$i body ($(paths_fail_reason "child-$n"))"
        else
          SHARED=$(LC_ALL=C comm -12 <(printf '%s\n' "$CONTRACT_PATHS") <(printf '%s\n' "$CHILD_PATHS"))
          while IFS= read -r sp; do
            [ -n "$sp" ] || continue
            CONTESTED="${CONTESTED:+$CONTESTED
}CONTESTED: $sp -> #${NUMS[0]}"
          done <<<"$SHARED"
          if [ -n "$CONTESTED" ]; then
            CONTESTED_ALL="${CONTESTED_ALL:+$CONTESTED_ALL
}$CONTESTED"
          fi
        fi
      fi
      # AN INDEPENDENT SIBLING FILES OFF MAIN (BH-5520). The spec may say
      # `imports_contract: false` (the JSON literal; the string "false" is the
      # same as absent). The filer takes that word only when it can check it:
      # no `after` names an earlier sibling, the contract's paths were
      # extracted, this body's paths were extracted, and none of them is shared.
      # Then the contract blocker goes away, so the launcher never stacks this
      # child on the contract branch. Any failed check keeps today's hard lines
      # byte for byte and says which check failed. An absent field runs none of
      # this.
      if jq -e --argjson i "$i" '.[$i].imports_contract == false' "$FC_SPEC" >/dev/null 2>&1; then
        INDEP_WHY=""
        p=2
        while [ "$p" -lt "$n" ]; do
          if grep -qE "^[[:space:]]*$p([^0-9]|\$)" <<<"$AFTERS"; then
            INDEP_WHY="it names sibling $p in 'after'"; break
          fi
          p=$((p + 1))
        done
        if [ -z "$INDEP_WHY" ] && [ -z "$CONTRACT_PATHS" ]; then INDEP_WHY="the contract has no extracted path to check against"
        elif [ -z "$INDEP_WHY" ] && [ "$CHP_RC" != 0 ]; then INDEP_WHY="path extraction failed on this body"
        elif [ -z "$INDEP_WHY" ] && [ -n "$CONTESTED" ]; then INDEP_WHY="it shares $(printf '%s\n' "$CONTESTED" | sed -E 's/^CONTESTED: (.*) -> #[0-9]+$/\1/' | paste -sd, -) with the contract"
        elif [ -z "$INDEP_WHY" ]; then
          # The extractor's list is blind to bin/ and to any other prefix it
          # does not keep, so the full token sets decide too. Any shared token
          # refuses: fail closed.
          INDEP_SHARED=$(LC_ALL=C comm -12 <(printf '%s\n' "$CONTRACT_TOKENS") <(path_tokens_of "$BODY") | sed '/^$/d' | paste -sd, -)
          [ -z "$INDEP_SHARED" ] || INDEP_WHY="it names $INDEP_SHARED, which the contract also names"
        fi
        if [ -z "$INDEP_WHY" ]; then
          INDEP=1
          BLOCK=""
          # Every other DEPENDS line is a soft sibling line here: no `after`
          # entry passed the check above.
          DEPENDS="DEPENDS: #${NUMS[0]} soft — this slice imports nothing from the contract (imports_contract: false) and shares no file with it${DEPENDS#"DEPENDS: #${NUMS[0]} hard — this slice imports the contract ($CONTRACT)"}"
        else
          fc_log "$FC_BUILD" "child $n: imports_contract false refused — $INDEP_WHY — kept hard on the contract #${NUMS[0]}"
        fi
      fi
    fi
    F="$CHILDREN_DIR/child-$n.md"
    OWNS=$(fc_owns_line "$FC_SPEC" "$i")
    [ -z "$OWNS" ] && [ "$FC_KIND" = decompose ] && fc_log "$FC_BUILD" "child $n declares no owns"
    { printf '%s\n\n' "$BODY"
      fc_child_footer "$FC_KIND" "$ISSUE" "$n" "$N" "$BLOCK" "$DEPENDS" "$CONTRACT" "$CONTESTED" "$INDEP"
      [ -n "$OWNS" ] && printf '%s\n' "$OWNS"
    } > "$F"
    if [ "$INDEP" = 1 ]; then fc_log "$FC_BUILD" "child $n: independent of the contract — filed with no blocker, builds on main"; fi
    # The contract is .0 and the siblings are .1 up, so the key says which one a
    # child is; a rollout wave is .1 up and there is no .0. The Order line above
    # stays 1-based over every filed child: it is what
    # bin/decompose-parent-close.sh counts to know it is not looking at a
    # truncated list.
    CT=$(fc_child_title "$FC_KIND" "$FC_KEY" "$i" "$TITLE")
    # ONE label set, used by the dry-run print, the command log and the real
    # create — so what the log says was filed is what was filed.
    LBL_FLAGS="${LBL_ARGS[*]}"
    fc_log "$FC_BUILD" "child $n labels: $LBL_SET ($LBL_NOTE)"
    NUM=""
    if [ -n "${EXISTING[$i]:-}" ]; then
      EXISTING_NUM=$(printf '%s' "${EXISTING[$i]}" | sed -nE 's#^.*-([0-9]+)$#\1#p')
      if [ "$DRY" = 1 ]; then
        NUM="$EXISTING_NUM"
        fc_log "$FC_BUILD" "child $n: using existing #$NUM (dry run, no title check)"
      else
        EV_RC=0; EXISTING_TITLE=""
        EV_T=$(mktemp "${TMPDIR:-/tmp}/fc-title.XXXXXX") || EV_RC=75
        if [ "$EV_RC" = 0 ]; then
          gh_rest GET "repos/$GH_REPO/issues/$EXISTING_NUM" > "$EV_T" 2>/dev/null || EV_RC=$?
          if [ "$EV_RC" = 0 ]; then
            EXISTING_TITLE=$(jq -er '.title' "$EV_T" 2>/dev/null) || EV_RC=75
            [ -n "$EXISTING_TITLE" ] || EV_RC=75
          fi
          rm -f "$EV_T"
        fi
        if [ "$EV_RC" -ne 0 ]; then
          # COULD NOT READ IT IS NOT THE SAME AS IT DIFFERS. The sweep SOP reads
          # this line: a mismatch tells the operator to go inspect the issue, and
          # a 502 or a token blip tells them to run it again. Either way the
          # record is untouched, so the rerun is safe.
          FC_ERROR="cannot read issue #$EXISTING_NUM for child $n of $N (issue read failed: HTTP ${GH_REST_STATUS:-000}${GH_REST_REASON:+ $GH_REST_REASON}, rc=$EV_RC) — children.txt is unchanged, rerun when GitHub answers"
          fc_log "$FC_BUILD" "$FC_ERROR"
          return 1
        elif [ "$EXISTING_TITLE" = "$CT" ]; then
          NUM="$EXISTING_NUM"
          fc_log "$FC_BUILD" "child $n: resumed from existing #$NUM (title matches)"
        else
          FC_ERROR="resume mismatch on child $n of $N: existing issue #$EXISTING_NUM title does not match '$CT' (got '${EXISTING_TITLE:-<none>}') — children.txt is unchanged"
          fc_log "$FC_BUILD" "$FC_ERROR"
          return 1
        fi
      fi
    fi
    if [ -z "$NUM" ]; then
      FILED_NEW=1
      if [ "$DRY" = 1 ]; then
        NUM=$((ISSUE + n))
        printf 'gh issue create -R %s --title %s %s --body-file %s\n' "$GH_REPO" "$(fc_sq "$CT")" "$LBL_FLAGS" "$F" >> "$GHLOG"
        printf 'DRYRUN gh issue create -R %s --title %s %s --body-file %s\n' "$GH_REPO" "$(fc_sq "$CT")" "$LBL_FLAGS" "$F"
        printf 'DRYRUN would become #%s (synthetic number — a real run uses the number GitHub returns)\n' "$NUM"
      else
        printf 'gh issue create -R %s --title %s %s --body-file %s\n' "$GH_REPO" "$(fc_sq "$CT")" "$LBL_FLAGS" "$F" >> "$GHLOG"
        # A global of the calling script, not of this library: a caller without it
        # must not be killed under `set -u`.
        command -v gh_fresh >/dev/null 2>&1 && gh_fresh
        URL=$(gh issue create -R "$GH_REPO" --title "$CT" "${LBL_ARGS[@]}" --body-file "$F" 2>&1)
        NUM=$(printf '%s' "$URL" | sed -nE 's#.*/issues/([0-9]+).*#\1#p' | tail -1)
        if [ -z "$NUM" ]; then
          # RETURN, never exit: the children filed before this one are already in
          # children.txt and they are real, the parent has not been commented on
          # and has not lost its label, and the caller turns this into its own
          # DECOMPOSE_FAILED line.
          local MISSING=""
          local _m
          # THE CHILD THAT FAILED IS MISSING TOO. This started at n+1, so the
          # line said which create failed and then listed everything EXCEPT it
          # — a resume list the next reader had to correct by hand.
          _m=$n
          while [ "$_m" -le "$N" ]; do
            MISSING="${MISSING:+$MISSING, }child $_m"
            _m=$((_m + 1))
          done
          FC_ERROR="gh issue create failed on child $n of $N: $(printf '%s' "$URL" | tail -1)${MISSING:+; missing children: $MISSING}"
          fc_log "$FC_BUILD" "$FC_ERROR"
          return 1
        fi
      fi
    fi
    NUMS+=("$NUM")
    # APPEND ONLY WHAT THIS RUN FILED. A recorded child was re-proven above and
    # its line is already on the file, written by the run that created it — this
    # one does not rewrite it, so nothing that happens after this point can cost
    # us the record of an issue that exists.
    if [ -z "${EXISTING[$i]:-}" ]; then
      # A hand-edited record may end without a newline (the reader above now
      # sees that line); terminate it before appending so the new key is not
      # glued onto the last one. Still append-only: every existing byte stays
      # exactly where the run that wrote it put it, and a rerun that files
      # nothing never reaches this branch, so a complete record is untouched.
      [ -s "$FC_BUILD/children.txt" ] && [ -n "$(tail -c1 "$FC_BUILD/children.txt")" ] \
        && printf '\n' >> "$FC_BUILD/children.txt"
      printf '%s-%s\n' "$PREFIX" "$NUM" >> "$FC_BUILD/children.txt"
    fi
    if [ "$FC_KIND" = rollout ]; then
      LINKS="$LINKS
$FC_KEY.$n (#$NUM): $TITLE"
    elif [ "$FC_KIND" = slice ]; then
      LINKS="$LINKS
$FC_KEY.$(( $(_fc_num "${FC_SLICE_BASE:-}" 0) + n )) (#$NUM): $TITLE"
    elif [ "$i" = 0 ]; then
      LINKS="$LINKS
$FC_KEY.0 (#$NUM): $TITLE (the contract, it lands first)"
    else
      LINKS="$LINKS
$FC_KEY.$i (#$NUM): $TITLE"
    fi
    i="$n"
  done

  # The parent thread, in the project's own voice. The numbers are on it because
  # "we split this" without them reads as a process detail; with them it is the
  # reason.
  SG_DECL=$(sed -n 's/^SIZE_DECLARED:[[:space:]]*//p' "$FC_BUILD/size-gate.txt" 2>/dev/null | tail -1)
  SG_OVER=$(sed -n 's/^SIZE_OVER:[[:space:]]*//p' "$FC_BUILD/size-gate.txt" 2>/dev/null | tail -1)
  # The tier the plan was sized against (2026-10-07): bin/size-gate.sh writes
  # bin/size-threshold.sh's src on the SIZE_LIMITS line, and a hotfix ticket's
  # src names `row:hotfix`. Only then does the comment say "hotfix budget"; with
  # no src, or any other, the sentence reads byte for byte as before.
  SG_BUDGET=$(sed -n 's/^SIZE_LIMITS:.* src=\([a-z:,]*\)$/\1/p' "$FC_BUILD/size-gate.txt" 2>/dev/null | tail -1)
  case "$SG_BUDGET" in *:hotfix*) SG_BUDGET="a hotfix budget" ;; *) SG_BUDGET="a budget" ;; esac
  if [ "$FC_KIND" = slice ]; then
    # No size numbers: a slice was not split for size, its plan named the rest.
    COMMENT="Slice delivered: #${FC_SLICE_PR:-?}. The plan for it named $N more slices, so we filed each one as its own issue:
$LINKS

Each one gets its own branch, PR and tests.$(jq -e 'any(.[]; (.after // []) | length > 0)' "$FC_SPEC" >/dev/null 2>&1 && printf ' A slice the plan put after another one waits for that one to merge.')

This issue stays open until they ship. We took the \`ai-build\` label off it so no builder picks the whole thing up again."
  elif [ "$FC_KIND" = rollout ]; then
    # No size numbers here: a rollout was not split because it was too big, it
    # was split because its author wrote the waves down.
    COMMENT="We split this one into $N waves, the way its author laid them out, and we are building them one at a time.
$LINKS

Each wave is its own issue, its own branch and its own PR, with its own tests. Each wave builds when the one before it merges.

This issue stays open as the master. We took the \`ai-build\` label off it so no builder picks the whole thing up again, and we will comment here as each wave lands."
  else
    # The same lines, once each, on the parent thread: the reader of the split
    # deserves the shared-file list without opening five issues. It appears ONLY
    # when there is something in it — a sentence about contested paths over an
    # empty list is copy that is false in the state it usually renders in.
    CONTESTED_NOTE=""
    if [ -n "$CONTESTED_ALL" ]; then
      CONTESTED_NOTE="
These paths are the contract's to move. The parts that also name them are hard-blocked on it:
$(printf '%s\n' "$CONTESTED_ALL" | LC_ALL=C sort -u)
"
    fi
    # A BODY WE COULD NOT READ IS NOT A BODY THAT SHARES NOTHING (BH-1343). The
    # `|| return 2` arm above already refuses to let a failed extraction read as
    # "nothing shared", but its WARN goes to pipeline.log and the person the
    # shared-file list is FOR reads this comment. Without this, a dead contract
    # extraction rendered a comment with no list at all and a dead sibling
    # extraction rendered one quietly short by that sibling's paths — both of
    # which read as "nothing is shared here".
    #
    # Like CONTESTED_NOTE, it renders ONLY when there is something in it, and
    # the sentence is true in both states it can render in (D13): a contract
    # failure leaves no list ("or missing"), a sibling failure leaves a short
    # one ("shorter than it should be").
    EXTRACT_NOTE=""
    if [ -n "$EXTRACT_FAILED" ]; then
      EXTRACT_NOTE="
We could not check every part for shared files, so any shared-file list above is shorter than it should be, or missing:
$EXTRACT_FAILED
"
    fi
    COMMENT="We split this one into $N parts and we are building them separately.

The plan for it came in at ${SG_DECL:-more than this project builds in one go}${SG_OVER:+ ($SG_OVER)}, against $SG_BUDGET of ${MAXL:-300} lines of product code across ${MAXF:-12} files. A pull request that size is the one nobody reviews properly, and it takes one long session instead of a few short ones. So:
$LINKS

The first part is the contract: the types, signatures and schema the other parts use. It is deliberately tiny, it goes in first, and the rest are built on top of it at the same time rather than one after another.
$CONTESTED_NOTE$EXTRACT_NOTE
Each part is its own issue, its own branch and its own PR, with its own tests.

This issue stays open as the master. We took the \`ai-build\` label off it so no builder picks the whole thing up again, and we will comment here as each part lands."
  fi
  if [ "$FILED_NEW" -eq 1 ] && [ "${FC_PARENT_NOTE:-1}" != 0 ]; then
    if [ "$DRY" = 1 ]; then
      printf '%s\n' "$COMMENT" > "$FC_BUILD/decompose-comment.md"
      printf 'gh api -X POST repos/%s/issues/%s/comments -F body=@%s\n' "$GH_REPO" "$ISSUE" "$FC_BUILD/decompose-comment.md" >> "$GHLOG"
      printf 'DRYRUN gh api -X POST repos/%s/issues/%s/comments -F body=@%s\n' "$GH_REPO" "$ISSUE" "$FC_BUILD/decompose-comment.md"
      printf 'gh api -X DELETE repos/%s/issues/%s/labels/ai-build\n' "$GH_REPO" "$ISSUE" >> "$GHLOG"
      printf 'DRYRUN gh api -X DELETE repos/%s/issues/%s/labels/ai-build\n' "$GH_REPO" "$ISSUE"
    else
      printf '%s\n' "$COMMENT" > "$FC_BUILD/decompose-comment.md"
      printf 'gh api -X POST repos/%s/issues/%s/comments -F body=@%s\n' "$GH_REPO" "$ISSUE" "$FC_BUILD/decompose-comment.md" >> "$GHLOG"
      command -v gh_fresh >/dev/null 2>&1 && gh_fresh
      TRK_SLUG="$GH_REPO" TRK_LOG="" TRK_DRY=0 trk_gh_comment "$ISSUE" "$FC_BUILD/decompose-comment.md" >/dev/null 2>&1 \
        || fc_log "$FC_BUILD" "WARN: children are filed but the split comment did not post on #$ISSUE"
      # PARKING IS THE LABEL. prompts/project-5.md: "the label IS the handoff" —
      # an unlabelled issue is invisible to every watcher, which is exactly what a
      # master of a split has to be. Closing it instead would tell the operator the
      # work shipped before any of it has.
      printf 'gh api -X DELETE repos/%s/issues/%s/labels/ai-build\n' "$GH_REPO" "$ISSUE" >> "$GHLOG"
      FC_UL=0; fc_unlabel_parent "$GH_REPO" "$ISSUE" || FC_UL=$?
      if [ "$FC_UL" = 0 ]; then
        fc_log "$FC_BUILD" "parent #$ISSUE unlabelled (master of split)"
      elif [ "$FC_UL" = 44 ]; then
        fc_log "$FC_BUILD" "parent #$ISSUE was not labelled ai-build (master of split)"
      else
        fc_log "$FC_BUILD" "WARN: could not remove the ai-build label from #$ISSUE after the split — it may be re-claimed whole"
      fi
    fi
  fi
  [ "$DRY" = 1 ] && DRYNOTE=" (DRY RUN, nothing was filed — the commands are in $GHLOG)" || DRYNOTE=""
  if [ "$FILED_NEW" -eq 0 ] && [ "${#EXISTING[@]}" -gt 0 ]; then
    # A rerun that found the split already complete. Saying "decomposed into"
    # here would read as work this run did; it re-proved every child and filed
    # none, and the operator reading the log deserves that distinction.
    fc_log "$FC_BUILD" "already decomposed into: $(paste -sd, "$FC_BUILD/children.txt") — every child re-proven on the repo, nothing re-filed"
    if [ "$DRY" != 1 ] && [ "${FC_PARENT_NOTE:-1}" != 0 ]; then
      # THE PARKING STEP ONLY EVER RAN BEHIND FILED_NEW. The first run's
      # `--remove-label` can fail after every child is filed, and no rerun
      # retried it — a parent of a COMPLETE split still carrying `ai-build` is
      # a parent a watcher picks up whole. So a complete rerun re-parks it.
      # The split comment is NOT re-posted: a duplicate on the client's thread
      # cannot be undone and this has no cheap way to know the first landed.
      command -v gh_fresh >/dev/null 2>&1 && gh_fresh
      _PL=$(fc_parent_labels "$GH_REPO" "$ISSUE")
      # A read that answered nothing does NOTHING and says nothing: absent is
      # not "unlabelled". The split is complete either way, so rc stays 0.
      if grep -qxi 'ai-build' <<<"$_PL"; then
        printf 'gh api -X DELETE repos/%s/issues/%s/labels/ai-build\n' "$GH_REPO" "$ISSUE" >> "$GHLOG"
        FC_UL=0; fc_unlabel_parent "$GH_REPO" "$ISSUE" || FC_UL=$?
        if [ "$FC_UL" = 0 ] || [ "$FC_UL" = 44 ]; then
          fc_log "$FC_BUILD" "parent #$ISSUE still carried ai-build after a complete split — unlabelled now (master of split)"
        else
          fc_log "$FC_BUILD" "WARN: parent #$ISSUE still carries ai-build after a complete split and the remove failed — it may be re-claimed whole"
        fi
      fi
    fi
  else
    fc_log "$FC_BUILD" "decomposed into: $(paste -sd, "$FC_BUILD/children.txt")$DRYNOTE"
  fi
  # BELOW the complete-rerun arm, not above it: that arm reads the parent's
  # labels, and a reset here first would hand it the token this lane inherited
  # instead of the one resolved for this repo.
  command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
  return 0
}
