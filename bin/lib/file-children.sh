#!/bin/bash
# bin/lib/file-children.sh — the one filer contract behind BOTH child-filing
# lanes: the decomposer that exists (bin/run-decompose.sh) and the rollout lane
# that is being built (#816). It owns the entry point, the two text templates a
# child body is made of, and the fence-safe rollout detector.
#
# Sourced, never executed: no `set -e`, no `exit`, no side effect at source
# time, same shape as bin/lib/hotfix-lib.sh and bin/lib/test-home-lib.sh and for
# the same reason — a sourced `exit` kills the lane that sourced it. Safe under
# the caller's `set -u`.
#
# NOTHING CALLS IT YET, AND THAT IS THE POINT. This is slice .0 of #816, the
# contract every sibling imports. The lane modules (`fc_file_issues` in
# bin/lib/fc-issues.sh, `fc_file_board` in bin/lib/fc-board.sh), the rollout
# parser and the run-build.sh hook are separate slices and will source this
# file; none of them ships here. `file_children` answering 3 —
# FILE_CHILDREN_UNIMPLEMENTED — is what lets each of them land on its own.
#
# WHY ONE FILE. The decompose lane's child bodies are parsed by four other
# scripts: bin/unblocked-children.sh launches a child off `Blocked-by: #<n>`,
# bin/lib/dep-verify-lib.sh reads the `(hard)` suffix, bin/decompose-parent-close.sh
# counts `Part of #N` / `Order: n of N`, and bin/size-gate.sh reads the size
# budget line. A second filing lane writing its own near-copy of those lines is
# how "the ordering line is phrased differently" becomes a child that launches
# into a conflict. So the templates live here once, and
# tests/file-children.bh-981-test.sh diffs them against what the real
# bin/run-decompose.sh produces today.
#
# bin/run-decompose.sh is NOT touched by this file. It keeps its own inline copy
# of the decompose footer until the sibling slice switches it over; the byte
# compare in the suite is what makes carrying both safe until then.
#
#   file_children <project> <parent> <KEY> <build-dir> <children.json> [--kind decompose|rollout]
#   fc_dry                              is this a dry run (either env name)
#   fc_sq <s>                           single-quote for a command log
#   fc_log <build-dir> <msg>            one stamped pipeline.log line
#   fc_board_base <project>             <API base><board prefix>, or rc 1
#   fc_child_title <kind> <KEY> <i> <title>
#   fc_child_footer <kind> <parent> <n> <N> <block> <depends> <contract> [<contested>] [<indep>]
#   fc_strip_fences                     stdin -> stdout, fences and tags gone
#   fc_has_rollout                      rc 0 when the stripped text has `## Rollout`

# The directory this library was sourced FROM, so a lane module beside it wins
# over the one on a live box. BASH_SOURCE is the file, not the caller.
_fc_dir() { printf '%s' "$(dirname "${BASH_SOURCE[0]}")"; }
# The same non-numeric scrub bin/run-decompose.sh:71-79 applies to its budgets.
_fc_num() { case "${1:-}" in ''|*[!0-9]*) printf '%s' "${2:-0}" ;; *) printf '%s' "$1" ;; esac; }

# fc_dry — the new name is an ALIAS, not a replacement: a lane that already sets
# DECOMPOSE_DRY_RUN keeps working, and either one alone is enough. Same case arm
# as bin/run-decompose.sh:102-105.
fc_dry() {
  local v
  for v in "${FILE_CHILDREN_DRY_RUN:-}" "${DECOMPOSE_DRY_RUN:-}"; do
    case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in
      1|true|yes|on) return 0 ;;
    esac
  done
  return 1
}

# fc_sq — byte-identical to SQ() at bin/run-decompose.sh:101. Single-quoted, so
# a printed command is both paste-safe and readable.
fc_sq() { printf "'%s'" "$(printf '%s' "${1:-}" | sed "s/'/'\\\\''/g")"; }

# fc_log — LOG()'s format (bin/run-decompose.sh:97-98). An absent or unwritable
# build directory is a silent no-op returning 0: this is the ONLY swallowed
# error in the file, because a library that kills a filing lane over a read-only
# log directory trades a cosmetic loss for a real one.
fc_log() {
  local build="${1:-}"
  [ $# -gt 0 ] && shift
  [ -n "$build" ] && [ -d "$build" ] || return 0
  { printf '%s [%s/%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" \
      "${FC_PROJECT:-}" "${FC_KEY:-}" "$*" >> "$build/pipeline.log"; } 2>/dev/null
  return 0
}

# fc_board_base <project> — <API base><board prefix> for an in-app project.
# This exists because bin/run-decompose.sh:519 hardcodes `/api/board` while
# fleet.conf column 4 is the registry answer (docs/BOARD-API-CONTRACT.md:31-39):
# a project served at /api/accounting/requests-board gets a URL that does not
# exist. FAILS CLOSED — prints nothing and returns 1 on the GitHub-Issues lane
# ("-"), an unknown project or a missing base, because an empty base
# concatenated into a URL is a request to the wrong host, not an error anyone
# sees. READS NO TOKEN AND LOGS NOTHING: the env file holds secrets, this
# touches one variable and prints one URL.
fc_board_base() {
  local project="${1:-}" harness fcs prefix envdir file var base libdir
  [ -n "$project" ] || return 1
  # The root is HARNESS, then the caller's H. With neither there is no env dir
  # to read a base from, so this fails closed below, before any URL exists.
  harness="${HARNESS:-${H:-}}"
  libdir="$(_fc_dir)"
  fcs="$libdir/../fleet-conf.sh"
  [ -x "$fcs" ] || { [ -n "$harness" ] && fcs="$harness/bin/fleet-conf.sh"; }
  [ -x "$fcs" ] || return 1
  prefix=$("$fcs" "$project" board_prefix 2>/dev/null) || return 1
  [ -n "$prefix" ] && [ "$prefix" != "-" ] || return 1
  # /root/harness/env is a compat symlink for one release; the real directory is
  # /etc/harness/env and bin/lib/env-path.sh is the one thing that knows.
  if [ -r "$libdir/env-path.sh" ]; then
    # shellcheck source=bin/lib/env-path.sh
    . "$libdir/env-path.sh"
  elif [ -n "$harness" ] && [ -r "$harness/bin/lib/env-path.sh" ]; then
    # shellcheck source=bin/lib/env-path.sh
    . "$harness/bin/lib/env-path.sh"
  fi
  [ -n "$harness" ] || return 1
  if command -v harness_env_dir >/dev/null 2>&1; then envdir=$(harness_env_dir "$harness")
  else envdir="$harness/env"; fi
  file="$envdir/$project.env"
  [ -r "$file" ] || return 1
  # WHICH variable is the base comes from bin/lib/internal-token.sh (BH-1955),
  # never `grep | head -1`: that took no digit prefix (project-32_), no *_APP_BASE,
  # and silently used the first of two. None or two is a return 1 here; the
  # caller's bin/lib/board-creds.sh resolve is what writes the ALERTS line.
  if ! command -v app_base_var >/dev/null 2>&1; then
    if [ -r "$libdir/internal-token.sh" ]; then
      # shellcheck source=bin/lib/internal-token.sh
      . "$libdir/internal-token.sh"
    elif [ -n "$harness" ] && [ -r "$harness/bin/lib/internal-token.sh" ]; then
      # shellcheck source=bin/lib/internal-token.sh
      . "$harness/bin/lib/internal-token.sh"
    fi
  fi
  command -v app_base_var >/dev/null 2>&1 || return 1
  var=$(app_base_var "$file") || return 1
  [ -n "$var" ] || return 1
  # The already-exported value first (a lane that sourced the env file may have
  # overridden it), then the literal in the file. A sourced library cannot
  # assume that source happened.
  base="${!var:-}"
  if [ -z "$base" ]; then
    base=$(sed -E 's/^[[:space:]]*export[[:space:]]+//' "$file" 2>/dev/null | sed -n "s/^${var}=//p" | tail -1)
    base="${base%\"}"; base="${base#\"}"; base="${base%\'}"; base="${base#\'}"
  fi
  [ -n "$base" ] || return 1
  while [ "${base%/}" != "$base" ]; do base="${base%/}"; done
  printf '%s%s\n' "$base" "$prefix"
}

# fc_child_title <kind> <KEY> <i> <title> — `i` is 0-based.
# Decompose i=0 is the contract (bin/run-decompose.sh:418, em dash and all);
# rollout waves are `.1` upward, so a rollout `.0` is unreachable. A slice
# child (bin/lib/slice-remainder.sh) is numbered after the merged slice C<k>:
# `.<FC_SLICE_BASE + 1 + i>`, so the remainder of C0 starts at `.1`.
fc_child_title() {
  local kind="${1:-decompose}" key="${2:-}" i="${3:-0}" title="${4:-}"
  if [ "$kind" = rollout ]; then printf '%s.%s: %s\n' "$key" "$((i + 1))" "$title"; return 0; fi
  if [ "$kind" = slice ]; then printf '%s.%s: %s\n' "$key" "$(( $(_fc_num "${FC_SLICE_BASE:-}" 0) + 1 + i ))" "$title"; return 0; fi
  if [ "$i" = 0 ]; then printf '%s.0: contract — %s\n' "$key" "$title"
  else printf '%s.%s: %s\n' "$key" "$i" "$title"; fi
}

# fc_child_footer <kind> <parent-issue> <n> <N> <block> <depends> <contract> [<contested>] [<indep>]
# The trailing block of a child body, starting with the `---` rule. The lane
# filer writes the child's own body first, then a blank line, then this.
#
# THE DECOMPOSE ARM IS COPIED VERBATIM from bin/run-decompose.sh:400-412 and
# must stay byte-identical: four other scripts parse these exact lines. The
# contract arm is selected by n = 1, which is literally the `[ "$i" = 0 ]`
# branch in the original. `block` and `depends` arrive already composed — this
# function never decides WHICH issues block a child, only how the line reads, so
# the `, ` separator and the `(hard)` suffix stay exactly as handed in. An
# empty `block` omits the sibling's `Blocked-by:` line; only the board lane on a
# board that advertises "dependencies" passes one (BH-3965), so the issues
# lane's bytes do not move.
#
# `contested` (BH-579.4) is optional and decompose-siblings-only: the caller
# hands in the `CONTESTED: <path> -> #<contract>` line(s) it already computed
# (or nothing), and this prints them directly after `Blocked-by:` and before
# `DEPENDS:` — the position tests/decompose-contract-first-test.sh asserts on.
# Rollout and the contract child (n = 1) never receive one; a caller that
# passes one anyway is ignored, because neither arm reads the parameter.
#
# `indep` (BH-5520) is optional and decompose-siblings-only: `1` when the issues
# lane checked that this sibling imports nothing from the contract and shares no
# file with it. The caller then hands in no `block`, and this prints the
# builds-on-main sentence in place of the stacked-build one. Empty = today's
# bytes.
fc_child_footer() {
  local kind="${1:-decompose}" parent="${2:-}" n="${3:-1}" total="${4:-1}"
  local block="${5:-}" depends="${6:-}" contract="${7:-}" contested="${8:-}" indep="${9:-}" maxl maxf cmaxl
  maxl=$(_fc_num "${MAXL:-}" 300)
  maxf=$(_fc_num "${MAXF:-}" 12)
  cmaxl=$(_fc_num "${CONTRACT_MAXL:-${CONTRACT_MAX_LINES:-}}" 60)
  printf -- '---\n'
  printf 'Part of #%s\n' "$parent"
  printf 'Order: %s of %s\n' "$n" "$total"
  if [ "$kind" = rollout ]; then
    # A wave has no contract, no dependency lines and no size budget: it may
    # still size XL and be decomposed normally by the size gate.
    [ -n "$block" ] && printf 'Blocked-by: %s\n' "$block"
    printf 'Rollout wave %s of %s: planned by its author; the PLAN stage fleshes it out. Never split into a rollout again.\n' "$n" "$total"
    return 0
  fi
  if [ "$kind" = slice ]; then
    # A remaining slice of a merged SLICE plan: no contract, no DEPENDS, no
    # size budget. Its own plan sizes it, and it may split again.
    [ -n "$block" ] && printf 'Blocked-by: %s\n' "$block"
    printf 'Remaining slice C%s of #%s, filed from the plan of the merged slice. The PLAN stage plans it from scratch.\n' \
      "$(( $(_fc_num "${FC_SLICE_BASE:-}" 0) + n ))" "$parent"
    return 0
  fi
  if [ "$n" = 1 ]; then
    printf 'CONTRACT: %s\n' "$contract"
    printf 'This is the tracer every other part of this split builds on: the thinnest end-to-end path, from a real trigger to a persisted result to an outcome you can observe. It lands first and stays small: aim for %s lines of product code, well inside the budget below. The names on the CONTRACT: line are working code the siblings import, not stubs. Each sibling adds one capability on top of it.\n' "$cmaxl"
  else
    [ -n "$block" ] && printf 'Blocked-by: %s\n' "$block"
    [ -n "$contested" ] && printf '%s\n' "$contested"
    printf '%s\n' "$depends"
    if [ "$indep" = 1 ]; then
      printf 'This slice imports nothing from the contract, so it builds on main in parallel with it and merges on its own.\n'
    else
      printf 'You do not wait for the contract to merge: this builds on the contract branch as soon as its pull request is open, and GitHub retargets this one when it lands.\n'
    fi
  fi
  printf 'Size budget: at most %s lines of product code across %s files.\n' "$maxl" "$maxf"
  printf 'Split child (depth 1): if the plan for this slice still sizes over the budget, it is built whole and says so. It is never split again.\n'
}

# fc_owns_line <spec> <0-based index> — the child's `Owns: <path>, <path>` line
# (BH-6384), from the spec's `owns` array: strings only, blanks dropped, in the
# spec's order. Prints nothing when the field is missing, empty or not an
# array, so a spec without `owns` files bodies byte-identical to before. Both
# lanes print it AFTER fc_child_footer, so no footer reader sees a new line
# inside the footer. bin/decompose-lint.sh is its reader.
fc_owns_line() {
  local o
  o=$(jq -r --argjson i "${2:-0}" '(.[$i].owns // []) | if type == "array"
        then map(select(type == "string") | gsub("^\\s+|\\s+$"; "") | select(length > 0)) | join(", ")
        else "" end' "${1:-}" 2>/dev/null) || o=""
  [ -n "$o" ] && printf 'Owns: %s\n' "$o"
  return 0
}

# fc_strip_fences — stdin to stdout, in this order:
#   1. fenced blocks (``` and ~~~, matched pairs, closed by their OWN marker)
#   2. code spans: markdown backticks, then `<pre>` and `<code>`
#   3. <h2>/<h3> mapped to `## ` / `### ` headings
#   4. every remaining HTML tag stripped
# (then the blank lines step 3 introduces are collapsed, so a mapped heading
# reads the same as a markdown one.)
#
# STEP 1 BEFORE ANYTHING ELSE IS LOAD-BEARING: issue #816's own body documents
# the wave convention inside a fence, and a detector that reads through a fence
# files issues nobody asked for, on somebody else's repo, under our App
# identity. Step 2 covers backtick spans for the same reason — that same body
# writes `<h2>Rollout</h2>` in inline code while explaining the convention.
# AN UNTERMINATED FENCE OR SPAN SWALLOWS THE REST (a span to end of line, a
# fence to EOF): a body that cannot be parsed confidently must not arm an
# irreversible lane. This is a state machine on purpose — a regex that fakes
# fence state is the bug this function exists to prevent.
# ONE THING SURVIVES THE DROP: an HTML BLOCK MARKER. Dropping the rest of a line
# is the right fail-closed rule for text, and the wrong one for a `<pre`/`<code`
# OPEN tag, because that tag is exactly what the END pass needs in order to hide
# everything after it. `` ` `` then `<pre>` then `## Rollout` used to answer
# "this is a rollout" and file phantom waves on someone's repo (BH-1335), so an
# unclosed BACKTICK span re-emits the canonical marker (`<pre>` or `<code>`) for
# the first open tag in the remainder it swallows, and drops the rest as before.
# OPEN TAGS ONLY: re-emitting a `</pre>` could close a real block early, which
# is the one direction that makes this function say yes more often.
# A FENCE IS A CHARACTER AND A RUN LENGTH: a run closes only on the same
# character at a length >= the one that opened it, so a 3-backtick block quoted
# inside a 4-backtick fence does not reopen visibility. Blockquotes are dropped
# in both spellings — the `>` line here, the <blockquote> span in the END pass —
# because the tag pass moves <h2> onto a line of its own and would otherwise
# strand a quoted heading as a real one. A trailing \r is removed first so a
# CRLF body reaches every guard, and the heading, as its author wrote it.
fc_strip_fences() {
  awk '
    # block_marker — the canonical open tag for the FIRST <pre/<code open tag in
    # a remainder an unclosed span is about to swallow, or "" if it holds none.
    # Byte-identical to the helper of the same name in bin/run-rollout.sh: the
    # two parsers have to agree about what a stray backtick hides.
    function block_marker(rest,   lo, ip, ic) {
      lo = tolower(rest)
      ip = index(lo, "<pre"); ic = index(lo, "<code")
      if (ip > 0 && (ic == 0 || ip < ic)) return "<pre>"
      if (ic > 0) return "<code>"
      return ""
    }
    # op/cl, not open/close: those are awk builtins and mawk refuses them as
    # parameter names. An unclosed span drops the rest of what it was handed,
    # except for a block marker it would otherwise eat (see the header).
    function strip_span(s, op, cl,   i, j, out, rest) {
      out = ""
      while (1) {
        i = index(tolower(s), op)
        if (i == 0) { out = out s; break }
        out = out substr(s, 1, i - 1)
        rest = substr(s, i + length(op))
        j = index(tolower(rest), cl)
        if (j == 0) { if (op == "`") out = out block_marker(rest); break }
        s = substr(rest, j + length(cl))
      }
      return out
    }
    # A fence is a CHARACTER AND A RUN LENGTH, not a character. CommonMark
    # closes a run only with a run of the same char at least as long, and the
    # natural way to document "put your waves in a fence" is to wrap the
    # example in a LONGER fence. Closing the outer 4-backtick run on the inner
    # 3-backtick line reopens visibility inside the outer block, so the heading
    # the author was quoting arms the lane. Length is load-bearing.
    function run(s,   m) {
      if (!match(s, /^[ \t]*(`+|~+)/)) return ""
      m = substr(s, RSTART, RLENGTH); sub(/^[ \t]+/, "", m)
      return m
    }
    {
      # A CRLF body must not silently become an ordinary ticket, and the \r
      # must not ride through the fence, blockquote and indent guards either.
      sub(/\r$/, "")
      m = run($0)
      if (fence != "") {
        if (m != "" && substr(m, 1, 1) == fence && length(m) >= flen) { fence = ""; flen = 0 }
        next
      }
      if (length(m) >= 3) { fence = substr(m, 1, 1); flen = length(m); next }
      # A blockquote is a quoted spec, not a declaration — the markdown
      # `> ## Rollout` is already a corpus negative, and `> <h2>Rollout</h2>`
      # has to answer the same way. It cannot: the tag pass below maps <h2> to
      # a NEW line, orphaning the heading from the `>` that qualified it. Drop
      # the quoted line here, while the marker is still attached to it.
      if ($0 ~ /^[ \t]*>/) next
      buf = buf strip_span($0, "`", "`") "\n"
    }
    END {
      buf = strip_span(buf, "<pre", "</pre>")
      buf = strip_span(buf, "<code", "</code>")
      # The HTML twin of the `>` drop above: a board that stores the quoted
      # convention as <blockquote>…</blockquote> spans lines, so it cannot be
      # caught per line. Dropped whole, before <h2> becomes a heading.
      buf = strip_span(buf, "<blockquote", "</blockquote>")
      gsub(/[ \t]*<[hH]2[^>]*>[ \t]*/, "\n## ", buf)
      gsub(/[ \t]*<\/[hH]2>[ \t]*/, "\n", buf)
      gsub(/[ \t]*<[hH]3[^>]*>[ \t]*/, "\n### ", buf)
      gsub(/[ \t]*<\/[hH]3>[ \t]*/, "\n", buf)
      gsub(/<[^>]*>/, "", buf)
      gsub(/\n\n\n+/, "\n\n", buf)
      printf "%s", buf
    }
  '
}

# fc_has_rollout — rc 0 when the stripped text carries a heading line that is
# exactly `## Rollout`, trimmed, case-insensitive. NOT a match: a blockquoted
# `> ## Rollout`, a suffixed `## Rollout risk`, an h3, `##Rollout`, the word in
# prose, the heading inside any fence or code span, or an INDENTED code block.
# Downstream a true answer files N issues on a real repo with no plan stage, so
# every uncertain shape answers no.
#
# THE INDENT GUARD IS THE FOURTH CODE FORM. fc_strip_fences is a state machine
# over markers (```, ~~~, `, <pre>, <code>); an indented code block has no
# marker to track, so it reaches here intact. Markdown allows a heading up to
# THREE leading spaces — four spaces, or a tab anywhere in the leading run, is
# a code block. Trimming it blind is how a body that merely DOCUMENTS the
# convention arms an irreversible lane, which is the exact class of false
# positive the corpus exists to prevent.
fc_has_rollout() {
  fc_strip_fences | awk '
    { line = $0
      if (line ~ /^    / || line ~ /^[ ]*\t/) next
      sub(/^[ ]+/, "", line); sub(/[ \t]+$/, "", line)
      if (tolower(line) ~ /^##[ \t]+rollout$/) found = 1
    }
    END { exit(found ? 0 : 1) }
  '
}

# file_children <project> <parent> <KEY> <build-dir> <children.json> [--kind …]
# Resolves the lane from the project's tracker (tracker_adapter, BH-4075: the
# settings row, else fleet.conf column 4 as bin/run-decompose.sh:113-121 does), sources that
# lane's module and dispatches. ONE RESOLUTION RULE, FOR EVERY --kind: the
# module beside THIS file wins, $HARNESS/bin/lib is the fallback for a checkout
# that carries none, and that is it. The kind is not part of the search —
# a lane module owns which kinds it accepts, and fc_file_issues has taken
# FC_KIND=rollout since BH-982. bin/lib/fc-issues.sh is the shipped module for
# the issues lane and bin/lib/fc-board.sh for the in-app board lane, so both
# lanes resolve to a module wherever this file ships with its siblings.
# Scoping the search by kind (BH-1347's defect) breaks every caller
# whose checkout is not the live $HARNESS — a worktree, a test tree, a box
# mid-propagate — because it makes the module it ships WITH unreachable.
# THE rc 3 IS A FEATURE: with no lane module present it logs
# FILE_CHILDREN_UNIMPLEMENTED <lane> and returns 3, which is what makes each
# filing slice shippable on its own. The log line is written BEFORE the return,
# so a 3 is never silent. Sets the seven FC_* for the lane module and exports
# nothing: an exported FC_BUILD would follow a child process into a lane it does
# not belong to.
file_children() {
  local project parent key build spec kind lane prefix harness dir mod fn fcs trk adapter
  if [ $# -lt 5 ]; then
    fc_log "${4:-}" "FILE_CHILDREN_USAGE file_children needs 5 arguments, got $#"
    return 2
  fi
  project="$1"; parent="$2"; key="$3"; build="$4"; spec="$5"; shift 5
  FC_PROJECT="$project"; FC_KEY="$key"
  kind=decompose
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind)
        if [ $# -lt 2 ]; then fc_log "$build" "FILE_CHILDREN_USAGE --kind needs a value"; return 2; fi
        kind="$2"; shift 2 ;;
      --kind=*) kind="${1#--kind=}"; shift ;;
      *) fc_log "$build" "FILE_CHILDREN_USAGE unrecognised argument '$1'"; return 2 ;;
    esac
  done
  case "$kind" in
    decompose|rollout) ;;
    *) fc_log "$build" "FILE_CHILDREN_USAGE unknown --kind '$kind' (decompose|rollout)"; return 2 ;;
  esac
  harness="${HARNESS:-${H:-}}"
  dir="$(_fc_dir)"
  # THE LANE IS THE PROJECT'S TRACKER (BH-4075): bin/lib/tracker.sh reads the
  # settings row tracker_adapter.<project>, with fleet.conf column 4 as its
  # fallback. An adapter it cannot resolve files nothing: a guessed lane is
  # children on the wrong tracker. A checkout without tracker.sh (a suite that
  # copies this file alone) keeps the column-4 rule inline, which is the same
  # answer the fallback gives.
  trk=""
  if [ -r "$dir/tracker.sh" ]; then trk="$dir/tracker.sh"
  elif [ -n "$harness" ] && [ -r "$harness/bin/lib/tracker.sh" ]; then trk="$harness/bin/lib/tracker.sh"; fi
  if [ -n "$trk" ]; then
    # shellcheck source=bin/lib/tracker.sh
    . "$trk"
    if fc_dry; then adapter=$(TRK_DRY=1 tracker_adapter "$project") || adapter=""
    else adapter=$(tracker_adapter "$project") || adapter=""; fi
    case "$adapter" in
      github-issues) lane=issues ;;
      board) lane=board ;;
      jira) fc_log "$build" "FILE_CHILDREN no child-filing lane for jira ($project)"; return 1 ;;
      # A Linear project has no child-filing lane yet (BH-4077): file nothing,
      # and say that, not "unresolved" — the row resolved fine.
      linear) fc_log "$build" "FILE_CHILDREN no child-filing lane for linear ($project)"; return 1 ;;
      *) fc_log "$build" "FILE_CHILDREN tracker adapter unresolved for $project"; return 1 ;;
    esac
  else
    fcs="$dir/../fleet-conf.sh"
    [ -x "$fcs" ] || { [ -n "$harness" ] && fcs="$harness/bin/fleet-conf.sh"; }
    prefix=$("$fcs" "$project" board_prefix 2>/dev/null || true)
    lane=board
    [ "$prefix" = "-" ] && lane=issues
  fi
  FC_PARENT="$parent"; FC_BUILD="$build"; FC_SPEC="$spec"; FC_KIND="$kind"; FC_LANE="$lane"
  mod="fc-$lane.sh"
  if [ -r "$dir/$mod" ]; then
    # shellcheck source=/dev/null
    . "$dir/$mod"
  elif [ -n "$harness" ] && [ -r "$harness/bin/lib/$mod" ]; then
    # shellcheck source=/dev/null
    . "$harness/bin/lib/$mod"
  fi
  fn="fc_file_$lane"
  if declare -F "$fn" >/dev/null 2>&1; then "$fn"; return $?; fi
  fc_log "$build" "FILE_CHILDREN_UNIMPLEMENTED $lane"
  return 3
}
