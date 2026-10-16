#!/bin/bash
# bin/test-tamper-scan.sh <base-sha> [repo-dir]
#
# Mechanize the test-integrity iron rule: "never weaken, skip, or delete an
# existing test to get to green; a genuinely wrong test gets fixed AND flagged."
# Today that rule is enforced by asking an LLM reviewer to notice. This counts it.
#
# Deterministic-before-LLM: everything here is a diff count. It does not judge
# whether a test change was justified — it finds the changes, looks for the
# justification the rule already requires, and hands both to the reviewer.
#
# Counts, over test files only, between <base-sha> and HEAD:
#   deleted_files   whole test files removed
#   deleted_cases   NET loss of test-case openers per surviving file (a retitle or
#                   a split removes an opener and adds one back: reported as
#                   reworded_cases, not counted as a deletion)
#   stub_flips      removed openers that were named STUBS and whose replacement
#                   was ADDED in a test file importing the same module — the
#                   contract-first shape (a `.0` child writes the stubs, the
#                   `.N` filler implements them). Not a deletion; the pairing is
#                   printed so the reviewer checks the replacement. A stub with
#                   no such replacement counts as a deletion exactly as before.
#   added_skips     skip/xfail/todo markers added
#   assertion_delta net change in assertion-shaped lines (REPORTED, not judged —
#                   a negative delta is a smell, not proof, and this script does
#                   not pretend to detect tautological tests)
# tamper_count = deleted_files + deleted_cases + added_skips. The assertion delta
# is deliberately EXCLUDED from it: refactoring three asserts into one helper is
# routine, and a gate that fires on it would be trained away within a week.
#
# Justification: a TEST-CHANGE: block in plan.md or in any commit message in the
# range — the flag the iron rule already demands.
#
# exit 0  no tamper found
# exit 1  tamper found, NO justification  (caller should block)
# exit 2  tamper found, justification present (caller passes both to review)
# exit 3  scan failed — caller must surface this, and must NOT block on it
#
# stdout is a short report; the caller pastes it into the review prompt.
set -uo pipefail
BASE="${1:?base sha}"
cd "${2:-.}" 2>/dev/null || { echo "SCAN_FAILED cannot enter repo dir ${2:-.}"; exit 3; }

git rev-parse --verify "$BASE" >/dev/null 2>&1 || { echo "SCAN_FAILED base $BASE not resolvable"; exit 3; }

# What counts as a test file. Deliberately broad — a false positive costs the
# reviewer one line of reading; a false negative is the whole point missed.
is_test_path() {
  case "$1" in
    */test/*|*/tests/*|*/__tests__/*|*/spec/*|test/*|tests/*|spec/*) return 0 ;;
    *.test.*|*.spec.*|*_test.go|*_test.py|test_*.py|*Test.java|*Tests.cs) return 0 ;;
    *test*.sh) return 0 ;;
    *) return 1 ;;
  esac
}

# NUL-delimited throughout. The first version joined paths with spaces and let
# the shell split them, so a tampered test at "tests/my suite.test.js" was
# silently invisible and the scan reported a clean bill of health.
git diff --name-only "$BASE"...HEAD >/dev/null 2>&1 || { echo "SCAN_FAILED diff against $BASE failed"; exit 3; }
TESTS=()
while IFS= read -r -d '' f; do
  is_test_path "$f" && TESTS+=("$f")
done < <(git diff -z --name-only "$BASE"...HEAD 2>/dev/null)

DEL_FILES=0; DEL_LIST=""; DEL_SET=""
while IFS= read -r -d '' f; do
  is_test_path "$f" && { DEL_FILES=$((DEL_FILES+1)); DEL_LIST="$DEL_LIST $f"; DEL_SET="$DEL_SET$f"$'\n'; }
done < <(git diff -z --name-only --diff-filter=D "$BASE"...HEAD 2>/dev/null)

# ---- BH-1047: contract-first lineage ---------------------------------------
# A contract-first decomposition ships a `.0` child whose test bodies are named
# STUBS and a `.N` filler that flips them into real cases, usually in another
# file. Counting that flip as lost coverage blocked all five of TK-1828, 1872,
# 1896, 1908 and 1909, each of which a person then adjudicated by hand. So the
# scanner learns three facts about the build it is scanning: which ticket it is
# (KEY), whose child it is (PARENT.ORD) and which files the contract child
# created. Every derivation here is BEST EFFORT and fails to the empty answer —
# a shallow clone, a missing record or no jq leaves the sets empty and the scan
# behaves exactly as it did before this shipped. A derivation that guessed would
# hand a builder a way to delete real tests.
meta_title() { # meta_title <ticket-meta.json>
  [ -s "$1" ] || return 0
  if command -v jq >/dev/null 2>&1; then jq -r '.title // ""' "$1" 2>/dev/null
  else sed -n 's/.*"title"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -1; fi
}
KEY="${TICKET_KEY:-}"
if [ -z "$KEY" ] && [ -n "${BUILD_DIR:-}" ]; then
  # Record dirs are <project>-<KEY>-<stamp> and project names are lowercase, so
  # the uppercase-anchored match skips `pool-project-4-` and lands on TK-1828.
  KEY=$(basename "${BUILD_DIR%/}" | grep -oE '[A-Z][A-Z0-9]*-[0-9]+' | head -1)
fi
PARENT=""; ORD=""; CONTRACT_CHILD_LINE=""
if [ -n "${BUILD_DIR:-}" ]; then
  TITLE=$(meta_title "$BUILD_DIR/ticket-meta.json")
  if [[ "$TITLE" =~ ^([A-Z][A-Z0-9]*-[0-9]+)\.([0-9]+): ]]; then
    PARENT="${BASH_REMATCH[1]}"; ORD="${BASH_REMATCH[2]}"
    # ORD 0 is the contract child ITSELF: it WRITES the stubs, it does not get
    # to delete them. No lineage line, and none of the exemptions below.
    if [ "$ORD" -ge 1 ] 2>/dev/null; then
      CONTRACT_CHILD_LINE="CONTRACT_CHILD: $PARENT.$ORD (parent $PARENT, key ${KEY:-unknown})"
    else
      PARENT=""; ORD=""
    fi
  fi
fi

# Marker (a): the vocabulary from the ticket, verbatim, plus this build's own
# key and its parent's `.N` siblings. Matched against a LOWERCASED line —
# that is how the case-insensitivity is done without a `\b`, which mawk (the
# awk on these boxes) reads as a backspace rather than a word boundary.
# ACCEPTED LOOSENESS: the vocabulary is the ticket's, so a REAL case whose name
# contains `placeholder` (`it("rejects placeholder emails")`) reads as a marked
# stub. It still only goes free in exchange for a replacement that imports the
# same module, and the pairing is printed with its reason — so the cost is the
# reviewer reading one line, not a silent drop.
NB='[^a-z0-9_]'
MARK_RE="(^|$NB)(stubs?|placeholders?)($NB|\$)|until [a-z][a-z0-9]*-[0-9]+|implements the bod(y|ies)|must flip"
re_esc() { printf '%s' "$1" | sed 's/[].[*^$()+?{}|\\]/\\&/g'; }
[ -n "$PARENT" ] && MARK_RE="$MARK_RE|(^|$NB)$(re_esc "${PARENT,,}")\\.[0-9]+($NB|\$)"
[ -n "$KEY" ]    && MARK_RE="$MARK_RE|(^|$NB)$(re_esc "${KEY,,}")($NB|\$)"

# Marker (b): the file was CREATED by the `.0` contract child OF THE SAME
# PARENT, so every case in it was a stub by construction and no marker word is
# needed. That provenance is only ever taken from a `.0` RECORD: this build has
# to be a `.N` child (PARENT, derived above from ticket-meta.json) and the `.0`
# child of that same parent has to be one this box can still see. Two things
# such a record gives, both optional:
#   (ii) its changed-files.txt names the files it wrote;
#   (i)  if THIS build is stacked on that record's own branch, the files added
#        between merge-base(origin/main, BASE) and BASE are its work too.
#
# (i) is deliberately NOT "merge-base(origin/main, BASE) != BASE". Being stacked
# on something says nothing about stubs: bin/run-build.sh stacks a child on ANY
# blocked-by parent's branch (2026-09-14) and bin/run-decompose.sh stacks a
# sibling on another sibling's branch whenever it declares `after:`. A sibling's
# branch carries REAL cases, so reading "I am stacked" as contract provenance
# would let any stacked child gut every test its parent added and pay for it
# with one trivial `it()`. The ref has to BE the contract child's branch, and
# when nothing on this box can prove that, the build falls back to marker (a) —
# which is the answer this scanner gave before BH-1047.
#
# (ii) IS NOT "the record names it" EITHER, for the same reason one branch over.
# changed-files.txt is the record's FULL diff list — bin/run-build.sh writes it
# as `git diff --name-only BASE...HEAD` (:2984, and :4248 -> :4492), with no
# --diff-filter=A — so a contract child that merely APPENDED a stub to a suite
# main already carried names that suite too. Taking the list at face value hands
# every `.N` sibling a blanket exemption on every case in a pre-existing file:
# gut two money tests, add one trivial `it()`, and the gate reports `rc 0,
# contract-file`. So a named path only counts when it is ABSENT from the
# mainline — un-merged work whose only plausible author is the contract child.
# A path still on main gets nothing and the build falls back to marker (a).
# The filter needs a mainline to compare against: with none resolvable the
# derivation is empty rather than open, like every other one here.
#
# AND NEITHER (i) NOR (ii) IS "REACHABLE FROM THE `.0` BRANCH". The `.0` child
# can ITSELF be stacked: run-build.sh stacks a child on ANY blocked-by parent's
# branch, so merge-base(mainline, the `.0` branch) can sit BELOW an unmerged
# ticket's commits. `--diff-filter=A` over that range, and equally a
# changed-files.txt entry for a file the `.0` merely appended a stub to, then
# hand this `.N` child every suite that OTHER ticket created: gut two money
# cases, add one trivial `it()`, and the gate reports `rc 0, contract-file`.
# So both derivations ask the same last question — did the `.0` record WRITE
# this file — and read the answer off the subject of the commit that ADDED it:
# the record's own key (from its directory name) or the `PARENT.0` title every
# contract child carries. A subject naming neither proves nothing, the path is
# dropped, and the build falls back to marker (a).
zero_wrote() { # zero_wrote <path> <alternation of keys> -> the `.0` added it
  local subj
  [ -n "$2" ] || return 1
  subj=$(git log -1 --diff-filter=A --format=%s "$BASE" -- "$1" 2>/dev/null)
  [ -n "$subj" ] || return 1
  grep -qE "(^|[^A-Za-z0-9])($2)([^A-Za-z0-9]|\$)" <<<"$subj"
}
CONTRACT_FILES=""; CONTRACT_BRANCHES=""
MAINREF="origin/${BASE_BRANCH:-main}"
git rev-parse --verify --quiet "$MAINREF" >/dev/null 2>&1 || MAINREF="${BASE_BRANCH:-main}"
git rev-parse --verify --quiet "$MAINREF" >/dev/null 2>&1 || MAINREF=""
if [ -n "$PARENT" ] && [ -n "${BUILD_DIR:-}" ]; then
  for m in "$(dirname "${BUILD_DIR%/}")"/*/ticket-meta.json; do
    [ -f "$m" ] || continue
    # The cheap grep first: on a hub with ~2250 sibling records a jq fork per
    # record cost 2.36s of every scan, and all but one of them is the wrong
    # ticket. meta_title still decides — this only skips the obvious misses.
    grep -qF "\"$PARENT.0:" "$m" 2>/dev/null || continue
    case "$(meta_title "$m")" in "$PARENT.0:"*) ;; *) continue ;; esac
    R0=$(dirname "$m")
    # The names a commit subject can carry for THIS record: its own ticket key,
    # read off the build directory (`<project>-<KEY>-<stamp>`), and the
    # `PARENT.0` the decomposition titles every contract child with.
    ZKEY=$(basename "$R0" | grep -oE '[A-Z][A-Z0-9]*-[0-9]+' | head -1)
    ZRE="$(re_esc "$PARENT")\\.0"
    [ -n "$ZKEY" ] && ZRE="$(re_esc "$ZKEY")|$ZRE"
    if [ -s "$R0/changed-files.txt" ] && [ -n "$MAINREF" ]; then
      while IFS= read -r cf; do
        [ -n "$cf" ] || continue
        # Still on the mainline => the record TOUCHED it, it did not write it.
        git cat-file -e "$MAINREF:$cf" 2>/dev/null && continue
        # Absent from the mainline is not authorship either: an unmerged parent
        # the `.0` is stacked on has absent files too.
        zero_wrote "$cf" "$ZRE" || continue
        CONTRACT_FILES="$CONTRACT_FILES$cf"$'\n'
      done < "$R0/changed-files.txt"
    fi
    [ -s "$R0/branch" ] && CONTRACT_BRANCHES="$CONTRACT_BRANCHES$(head -1 "$R0/branch")"$'\t'"$ZRE"$'\n'
  done
fi
if [ -n "$CONTRACT_BRANCHES" ]; then
  CBS=$(git rev-parse --verify --quiet "$BASE^{commit}" 2>/dev/null)
  ON_CONTRACT=0; ON_ZRE=""
  while IFS=$'\t' read -r b0 z0; do
    [ -n "$b0" ] || continue
    # By name first (run-build.sh hands this script the branch it stacked on),
    # then by commit, so a BASE passed as a sha still resolves to the same tip.
    [ "$b0" = "$BASE" ] && { ON_CONTRACT=1; ON_ZRE="$z0"; break; }
    b0c=$(git rev-parse --verify --quiet "$b0^{commit}" 2>/dev/null)
    [ -n "$b0c" ] && [ -n "$CBS" ] && [ "$b0c" = "$CBS" ] && { ON_CONTRACT=1; ON_ZRE="$z0"; break; }
  done <<<"$CONTRACT_BRANCHES"
  if [ "$ON_CONTRACT" = 1 ]; then
    CMB=$(git merge-base "$MAINREF" "$BASE" 2>/dev/null)
    if [ -n "$CMB" ] && [ -n "$CBS" ] && [ "$CMB" != "$CBS" ]; then
      while IFS= read -r -d '' f; do
        # Added in the range is not authorship: the range spans whatever
        # unmerged branch the `.0` was itself stacked on.
        zero_wrote "$f" "$ON_ZRE" || continue
        CONTRACT_FILES="$CONTRACT_FILES$f"$'\n'
      done < <(git diff -z --name-only --diff-filter=A "$CMB..$CBS" 2>/dev/null)
    fi
  fi
fi
in_set() { # in_set <path> <newline-set>
  [ -n "$2" ] || return 1
  grep -qxF -- "$1" < <(printf '%s' "$2")
}

# The module a test file depends on, as a set of normalised specifiers. This is
# what "adds a case in a test file that imports the same module" is decided on:
# path equality after normalisation, never directory proximity — a replacement
# in an unrelated suite must not pay for a deleted stub.
spec_scan() { # spec_scan <ref> <path> -> raw import specifiers
  local body
  body=$(git show "$1:$2" 2>/dev/null) || return 0
  case "$2" in
    # Dotted module names, kept literal. Only for .py files: `import chan from
    # "x"` in a JS file would otherwise read as the Python module `chan`, and
    # two files that both default-import React would "share a module".
    *.py) grep -oE '^[[:space:]]*(from|import)[[:space:]]+[A-Za-z_][A-Za-z0-9_.]*' <<<"$body" \
            | sed -E 's/^[[:space:]]*(from|import)[[:space:]]+/py:/' ;;
    *)    grep -oE "(from|require|import)[[:space:]]*\(?[\"'][^\"']+[\"']" <<<"$body" \
            | sed -E "s/^(from|require|import)[[:space:]]*\(?[\"']//; s/[\"']\$//" ;;
  esac
  return 0
}
imports_of() { # imports_of <ref> <path> -> newline-separated module keys
  local ref="$1" f="$2" dir spec p out=""
  dir=$(dirname "$f")
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    case "$spec" in
      py:*) out="$out$spec"$'\n'; continue ;;
      ./*|../*|/*) p=$(realpath -m --relative-to="$PWD" "$dir/$spec" 2>/dev/null) || p="$spec" ;;
      '@/'*|'~/'*|'#'*|src/*) p="$spec" ;;
      # A bare package name is every project's dependency, never a module two
      # suites can be said to share.
      *) continue ;;
    esac
    p=$(sed -E 's/\.(js|jsx|ts|tsx|mjs|cjs|mts|cts)$//; s#/index$##' <<<"$p")
    [ -n "$p" ] && out="$out$p"$'\n'
  done < <(spec_scan "$ref" "$f")
  printf '%s' "$out"
}

# Test-case openers and skip markers across the stacks these repos actually use:
# vitest/jest, node --test, playwright, pytest, go, and the bash fixtures in
# this very repo (ok()/bad() assertions).
# (The removed-line form of the opener shape lives with its readers as OPEN_RE
# below: since BH-1047 the removals are judged by the awk pass, which reads the
# line with its diff marker already stripped, so a `^-` copy here would be a
# second definition nothing uses.)
SKIP_RE='^\+[[:space:]]*.*((it|test|describe|context)\.(skip|todo|failing)|\b(xit|xdescribe|xtest)\b|@pytest\.mark\.(skip|skipif|xfail)|t\.Skip\(|--skip\b|\.only\()'
ASSERT_RE='(expect\(|assert|should\(|\bok\b|\bbad\b|t\.(is|deepEqual|truthy)\(|require\.(True|Equal)|toBe|toEqual)'

DEL_CASES=0; REWORDED=0; ADD_SKIPS=0; ADD_ASSERT=0; RM_ASSERT=0
STUB_FLIPS=0; PAIR_LINES=""; UNPAIR_LINES=""; DEL_NAMES=""
if [ "${#TESTS[@]}" -gt 0 ]; then
  # One diff pass over the test files only, pathspecs passed as argv.
  DIFF=$(git diff "$BASE"...HEAD -- "${TESTS[@]}" 2>/dev/null) || DIFF=""
  ADD_SKIPS=$(grep -cE "$SKIP_RE" <<<"$DIFF" 2>/dev/null || true)
  ADD_ASSERT=$(grep '^+' <<<"$DIFF" | grep -cE "$ASSERT_RE" 2>/dev/null || true)
  RM_ASSERT=$(grep '^-' <<<"$DIFF" | grep -cE "$ASSERT_RE" 2>/dev/null || true)
  # deleted_cases is the NET loss of case openers PER FILE, not the gross count
  # of removed opener lines. 2026-09-13: 36 builds fleet-wide ($730 of spend)
  # were blocked because a builder retitled one `it(` while adding dozens
  # around it — a gross count cannot tell a retitle or a split from a deletion,
  # and the iron rule is about LOSING coverage. Per file, deliberately: forty
  # new cases in a fresh file buy no right to delete one in an old file. The
  # gross removals are still reported (REWORDED_CASES) so the reviewer reads
  # them; the deliberately-not-handled case is "delete a hard test, add a
  # trivial one in the same file" — that is what ASSERTION_DELTA and the
  # reviewer are for.
  #
  # THE ONE CROSS-FILE EXEMPTION (BH-1047). Per-file is still the rule, with a
  # single exception it took five hand-adjudicated PRs to buy: a removed case
  # that is a named STUB, whose replacement is a case ADDED in a test file
  # importing the SAME module, is a flip rather than a loss. Both halves are
  # required — the marker without a replacement blocks exactly as before, and
  # a replacement in an unrelated suite buys nothing. The pairing is printed so
  # the reviewer checks the replacement rather than taking the word stub for it.
  # Literal ERE, not ${CASE_RE/^-/^\+}: bash parameter expansion eats the
  # backslash and leaves `^+`, which GNU grep warns "plus at start of
  # expression" and then matches CONTEXT lines as adds. #294 (2026-09-13)
  # shipped that; Harness CI on main has been red since (deleted_cases=0 on
  # a real deletion because a=context-openers > d=removed-openers).
  ADD_CASE_RE='^\+[[:space:]]*((it|test|describe|context)[[:space:]]*[.(]|(async[[:space:]]+)?function[[:space:]]+test|def[[:space:]]+test_|func[[:space:]]+Test[A-Z])'
  # Occurrences, not lines: `describe('s', () => { it('a', ...) })` on one line
  # is two openers, and gutting it to `describe('s', () => {})` removes one.
  # Counted only on lines that open a case at column one (OPEN_RE), so a
  # `test(` inside a string or an `expect(it)` elsewhere is not an opener.
  TOKEN_RE='(^|[^A-Za-z0-9_.])((it|test|describe|context)[[:space:]]*[.(]|(async[[:space:]]+)?function[[:space:]]+test|def[[:space:]]+test_|func[[:space:]]+Test[A-Z])'
  # The same opener shape as ADD_CASE_RE, matched on the line with its
  # diff marker already stripped — the awk pass below judges the TEXT.
  OPEN_RE='^[[:space:]]*((it|test|describe|context)[[:space:]]*[.(]|(async[[:space:]]+)?function[[:space:]]+test|def[[:space:]]+test_|func[[:space:]]+Test[A-Z])'
  DESC_RE='^[[:space:]]*(describe|context)[[:space:]]*[.(]'
  # "Its adjacent comment" is a COMMENT. Any-preceding-line would hand the
  # marker to whatever sits under a stub, and in a contract-first file a real
  # case sits under a stub all the time — so `it("is a stub")` directly above
  # `it("refuses to move money twice for the same idempotency key")` would have
  # exempted the money test. A comment marks at most the case beneath it.
  COMMENT_RE='^[[:space:]]*(//|#|/\*|\*|--)'
  declare -A F_A=() F_REALNET=() F_STUBNET=() F_REALTXT=() F_STUBTXT=() F_STUBWHY=()
  for f in "${TESTS[@]}"; do
    FDIFF=$(git diff "$BASE"...HEAD -- "$f" 2>/dev/null) || FDIFF=""
    a=$(grep -E "$ADD_CASE_RE" <<<"$FDIFF" 2>/dev/null | grep -oE "$TOKEN_RE" | wc -l | tr -d ' ')
    case "$a" in ''|*[!0-9]*) a=0 ;; esac
    # A whole-file deletion is NEVER a stub flip, whatever the file is called
    # or where it came from: the ticket's evidence is all case-level and a
    # deleted stub FILE goes to adjudication exactly as it does today.
    FORCE_CONTRACT=0
    in_set "$f" "$DEL_SET" || { in_set "$f" "$CONTRACT_FILES" && FORCE_CONTRACT=1; }
    FORCE_REAL=0; in_set "$f" "$DEL_SET" && FORCE_REAL=1
    # ONE PASS PER FILE, one row per removed opener: <stub|real> <tokens>
    # <reason> <opener text>. The old arithmetic could not tell a stub from a
    # real case because it never read the line; this does.
    ROWS=$(FORCE_CONTRACT="$FORCE_CONTRACT" FORCE_REAL="$FORCE_REAL" \
           MARK_RE="$MARK_RE" OPEN_RE="$OPEN_RE" DESC_RE="$DESC_RE" TOKEN_RE="$TOKEN_RE" \
           COMMENT_RE="$COMMENT_RE" \
           awk '
      function marked(s) { return (tolower(s) ~ mark_re) }
      function indent_of(s,   i, n, c) {
        n = 0
        for (i = 1; i <= length(s); i++) {
          c = substr(s, i, 1)
          if (c == " ") n++; else if (c == "\t") n += 8; else break
        }
        return n
      }
      function ntokens(s,   n, r) {
        n = 0; r = s
        while (match(r, token_re)) {
          n++
          if (RLENGTH < 1) break
          r = substr(r, RSTART + RLENGTH)
        }
        return n
      }
      BEGIN { mark_re = ENVIRON["MARK_RE"]; open_re = ENVIRON["OPEN_RE"]
              desc_re = ENVIRON["DESC_RE"]; token_re = ENVIRON["TOKEN_RE"]
              comment_re = ENVIRON["COMMENT_RE"]
              fc = ENVIRON["FORCE_CONTRACT"] + 0; fr = ENVIRON["FORCE_REAL"] + 0
              sp = 0; wn = 0 }
      # A hunk boundary resets both the scope stack and the comment window: a
      # describe forty lines away in another hunk encloses nothing here.
      /^@@/ { sp = 0; wn = 0; next }
      # ADDED lines are invisible to scope, window and openers alike. A builder
      # must not be able to write `+ // stub` above a deletion and manufacture
      # the exemption out of the diff side of the same hunk.
      /^\+/ { next }
      # The old-file header, ANCHORED on its path: a REMOVED `--` comment (Lua,
      # SQL, Haskell) reaches this pass as `--- …`, the same three characters,
      # and an unanchored skip dropped the marker written above a stub.
      /^--- (a\/|\/dev\/null)/ { next }
      /^(diff |index |new file|deleted file|old mode|new mode|similarity|rename |Binary)/ { next }
      {
        raw = $0
        isdel = (substr(raw, 1, 1) == "-")
        txt = substr(raw, 2)
        if (txt ~ /^[ \t]*$/) next
        ind = indent_of(txt)
        while (sp > 0 && stind[sp] >= ind) sp--
        if (isdel && txt ~ open_re) {
          # The reason is never empty: tab is an IFS whitespace character, so
          # an empty field would collapse and shift the opener text into it.
          st = 0; why = "-"
          if (fr) { st = 0 }
          else if (fc) { st = 1; why = "contract-file" }
          else if (marked(txt)) { st = 1; why = "stub marker" }
          else {
            for (i = 1; i <= wn; i++) if (marked(win[i])) { st = 1; why = "stub marker"; break }
            if (!st) for (i = 1; i <= sp; i++) if (stmark[i]) { st = 1; why = "stub marker"; break }
          }
          n = ntokens(raw); if (n < 1) n = 1
          trimmed = txt
          sub(/^[ \t]+/, "", trimmed); sub(/[ \t]+$/, "", trimmed)
          gsub(/\t/, " ", trimmed)
          print (st ? "stub" : "real") "\t" n "\t" why "\t" trimmed
        }
        if (txt ~ desc_re) {
          sp++; stind[sp] = ind
          stmark[sp] = (marked(txt) || (sp > 1 && stmark[sp-1])) ? 1 : 0
        }
        # THE WINDOW HOLDS COMMENTS ONLY, IMMEDIATELY ABOVE, AND ANYTHING ELSE
        # EMPTIES IT. All three halves are the same rule: a marker reaches the
        # case written under it and stops there. Without the first, a removed
        # stub `it(` line is itself in the window for the case below it; without
        # the second, a comment three lines up walks past the case it was
        # written about; without the third, ANY non-blank line that is neither a
        # comment nor an opener (`const fx = seed()`, a `beforeEach`) left the
        # window standing, so a `// placeholder fixtures until the seed lands`
        # at the top of a suite cleared a money case an unbounded distance below
        # it (review round 2, 2026-09-20). The cost is stated and accepted: a
        # marker separated from its stub by a line of setup now blocks and goes
        # to adjudication — the answer this scanner gave before BH-1047.
        if (txt ~ open_re) { wn = 0 }
        else if (txt ~ comment_re) {
          wn++
          if (wn > 3) { win[1] = win[2]; win[2] = win[3]; wn = 3 }
          win[wn] = txt
        }
        else { wn = 0 }
      }' <<<"$FDIFF") || ROWS=""
    d_real=0; d_stub=0; realtxt=""; stubtxt=""; stubwhy=""
    while IFS=$'\t' read -r rflag rn rwhy rtxt; do
      [ "$rflag" = stub ] || [ "$rflag" = real ] || continue
      case "$rn" in ''|*[!0-9]*) rn=1 ;; esac
      # A line's flag applies to all of its tokens: the one-liner
      # `describe('s', () => { it('a') })` is two openers with one verdict.
      i=0
      while [ "$i" -lt "$rn" ]; do
        if [ "$rflag" = stub ]; then
          d_stub=$((d_stub+1)); stubtxt="$stubtxt$rtxt"$'\n'; stubwhy="$stubwhy$rwhy"$'\n'
        else
          d_real=$((d_real+1)); realtxt="$realtxt$rtxt"$'\n'
        fi
        i=$((i+1))
      done
    done <<<"$ROWS"
    # Added openers pay off the REAL removals first. A stub retitled in the
    # same file can therefore never hide a real deletion behind it.
    used_real=$(( a < d_real ? a : d_real ))
    a_left=$(( a - used_real ))
    used_stub=$(( a_left < d_stub ? a_left : d_stub ))
    F_A["$f"]=$a
    F_REALNET["$f"]=$(( d_real - used_real ))
    F_STUBNET["$f"]=$(( d_stub - used_stub ))
    F_REALTXT["$f"]=$(printf '%s' "$realtxt" | tail -n +$((used_real + 1)))
    F_STUBTXT["$f"]=$(printf '%s' "$stubtxt" | tail -n +$((used_stub + 1)))
    F_STUBWHY["$f"]=$(printf '%s' "$stubwhy" | tail -n +$((used_stub + 1)))
    # REWORDED keeps its own formula, on the TOTAL removals: whether a retitle
    # was of a stub or of a real case makes no difference to the reviewer.
    d=$(( d_real + d_stub ))
    if [ "$d" -gt "$a" ]; then REWORDED=$((REWORDED + a)); else REWORDED=$((REWORDED + d)); fi
  done

  # THE REPLACEMENT REQUIREMENT. A stub flip is exempt only in exchange for a
  # case ADDED in a test file that imports the same module — otherwise the
  # "flip" is a silent drop wearing the word stub.
  declare -A M_HEAD=()
  # The exchange rate, for the report: how many ADDED case openers the paired
  # files carry between them, counted exactly as the arithmetic above counts
  # them (a `describe` is an opener). One trivial `it()` can pay for eight
  # flips — the ticket says "at least one test case" — so the reviewer is told
  # the ratio rather than the word "paired".
  declare -A PAID=(); PAIR_ADDS=0
  for f in "${TESTS[@]}"; do
    rn=${F_REALNET["$f"]}; sn=${F_STUBNET["$f"]}
    [ "$rn" -gt 0 ] && DEL_NAMES="$DEL_NAMES$(awk -v f="$f" '{ print "  " f ": " $0 }' <<<"${F_REALTXT["$f"]}")"$'\n'
    DEL_CASES=$((DEL_CASES + rn))
    [ "$sn" -gt 0 ] || continue
    MF=$(imports_of "$BASE" "$f")
    REPL=""
    if [ -n "$MF" ]; then
      for g in "${TESTS[@]}"; do
        [ "$g" = "$f" ] && continue
        [ "${F_A["$g"]:-0}" -gt 0 ] || continue
        [ -n "${M_HEAD["$g"]+x}" ] || M_HEAD["$g"]=$(imports_of HEAD "$g")
        [ -n "${M_HEAD["$g"]}" ] || continue
        if [ -n "$(comm -12 <(sort -u <<<"$MF") <(sort -u <<<"${M_HEAD["$g"]}"))" ]; then
          REPL="$g"; break
        fi
      done
    fi
    if [ -n "$REPL" ]; then
      STUB_FLIPS=$((STUB_FLIPS + sn))
      if [ -z "${PAID["$REPL"]+x}" ]; then
        PAID["$REPL"]=1; PAIR_ADDS=$(( PAIR_ADDS + ${F_A["$REPL"]:-0} ))
      fi
      i=1
      while [ "$i" -le "$sn" ]; do
        PAIR_LINES="$PAIR_LINES""stub-flip: $f: $(sed -n "${i}p" <<<"${F_STUBTXT["$f"]}") ($(sed -n "${i}p" <<<"${F_STUBWHY["$f"]}")) -> $REPL"$'\n'
        i=$((i+1))
      done
    else
      DEL_CASES=$((DEL_CASES + sn))
      DEL_NAMES="$DEL_NAMES$(awk -v f="$f" '{ print "  " f ": " $0 }' <<<"${F_STUBTXT["$f"]}")"$'\n'
      i=1
      while [ "$i" -le "$sn" ]; do
        UNPAIR_LINES="$UNPAIR_LINES""stub-flip-unpaired: $f: $(sed -n "${i}p" <<<"${F_STUBTXT["$f"]}") (no added case in a test file importing: $(tr '\n' ' ' <<<"$MF" | sed 's/[[:space:]]*$//'; [ -n "$MF" ] || printf 'none resolvable'))"$'\n'
        i=$((i+1))
      done
    fi
  done
fi
for v in DEL_CASES REWORDED ADD_SKIPS ADD_ASSERT RM_ASSERT; do
  case "${!v}" in ''|*[!0-9]*) printf -v "$v" '%s' 0 ;; esac
done
ASSERT_DELTA=$(( ADD_ASSERT - RM_ASSERT ))
TAMPER=$(( DEL_FILES + DEL_CASES + ADD_SKIPS ))
# DECISION (finding 6, review 2026-08-24) — CHOSEN, not overlooked.
# Only DELETIONS block. A skip marker is matched by a regex that cannot tell
# code from a comment or a string — ".only(" and "--skip" appear in both — and a
# gate that blocks a build over the word "skip" in a comment gets worked around
# rather than obeyed. Deleting a test file or a test case is unambiguous, so
# that is what carries a terminal; skips are counted and handed to the reviewer.
# Accepted cost: a suite genuinely switched off with it.skip escapes the
# terminal and reaches the reviewer as a warning instead. Worth it — the
# alternative blocks builds over the word "skip" in a comment, and a gate that
# fires on comments gets routed around rather than obeyed.
BLOCKING=$(( DEL_FILES + DEL_CASES ))

# The justification the iron rule already requires, wherever the build put it.
JUST=""
if [ -n "${BUILD_DIR:-}" ] && [ -s "$BUILD_DIR/plan.md" ] && grep -q 'TEST-CHANGE:' "$BUILD_DIR/plan.md" 2>/dev/null; then
  JUST="plan.md"
fi
# captured first: grep -q exits at the first match while git is still writing the
# rest of the range, and pipefail hands the `if` git's 141 — a real TEST-CHANGE:
# justification then reads as absent and the build is blocked for tampering (BH-1248).
if [ -z "$JUST" ] && grep -q 'TEST-CHANGE:' <<<"$(git log --format=%B "$BASE"..HEAD 2>/dev/null)"; then
  JUST="commit message"
fi

echo "TAMPER_COUNT: $TAMPER (deleted_files=$DEL_FILES deleted_cases=$DEL_CASES added_skips=$ADD_SKIPS stub_flips=$STUB_FLIPS)"
echo "BLOCKING_COUNT: $BLOCKING (deletions only — skip markers are reported, not gated: the pattern cannot tell code from a comment)"
echo "ASSERTION_DELTA: $ASSERT_DELTA (added=$ADD_ASSERT removed=$RM_ASSERT) — reported, not gated"
echo "REWORDED_CASES: $REWORDED (case openers removed and re-added in the same file — retitles or splits; reported, not gated)"
[ -n "$DEL_LIST" ] && echo "DELETED_TEST_FILES:$DEL_LIST"
# Everything below is AFTER the four count lines and the deleted-file list, so
# every grep the callers already run (^TAMPER_COUNT, ^BLOCKING_COUNT: [1-9] in
# bin/run-build.sh and bin/evidence-summary.sh, deleted_cases=N, REWORDED_CASES,
# JUSTIFICATION: NONE) keeps matching the line it always matched.
[ -n "$CONTRACT_CHILD_LINE" ] && echo "$CONTRACT_CHILD_LINE"
if [ -n "$DEL_NAMES" ]; then
  # The names, so an adjudication can say WHICH cases it is ruling on instead
  # of quoting a number back at the reader.
  echo "DELETED_CASES:"
  head -40 < <(printf '%s' "$DEL_NAMES")
  DEL_EXTRA=$(( $(printf '%s' "$DEL_NAMES" | grep -c '') - 40 ))
  [ "$DEL_EXTRA" -gt 0 ] && echo "  … and $DEL_EXTRA more"
fi
if [ "$STUB_FLIPS" -gt 0 ] || [ -n "$UNPAIR_LINES" ]; then
  echo "STUB_FLIPS: $STUB_FLIPS (paid for by ${PAIR_ADDS:-0} added case opener(s) in the file(s) named below — read the ratio)"
  [ -n "$PAIR_LINES" ] && printf '%s' "$PAIR_LINES"
  [ -n "$UNPAIR_LINES" ] && printf '%s' "$UNPAIR_LINES"
fi
if [ "$BLOCKING" -eq 0 ]; then
  if [ "$ADD_SKIPS" -gt 0 ]; then
    echo "VERDICT: no test DELETIONS, but $ADD_SKIPS skip/only marker(s) were added — read them, they may be a suite quietly switched off"
  elif [ "$STUB_FLIPS" -gt 0 ]; then
    echo "VERDICT: no test DELETIONS; $STUB_FLIPS stub case(s) flipped and paired with a replacement (see stub-flip lines — the reviewer confirms the replacements test what the stubs promised)"
  else
    echo "VERDICT: no test tampering detected"
  fi
  exit 0
fi
if [ -n "$JUST" ]; then
  echo "JUSTIFICATION: TEST-CHANGE: block found in $JUST — reviewer adjudicates whether it holds"
  git log --format=%B "$BASE"..HEAD 2>/dev/null | grep -A5 'TEST-CHANGE:' | head -20
  exit 2
fi
echo "JUSTIFICATION: NONE — no TEST-CHANGE: block in plan.md or any commit message in range"
exit 1
