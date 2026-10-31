#!/bin/bash
# bin/lib/evidence.sh — the acceptance-claim evidence contract (#527) and the
# deterministic scorer that fills it in (#546): the file names, the JSON schema,
# the verdict vocabulary, the two readers every consumer calls, and the
# grep/awk/sed/jq scorer that decides one verdict per acceptance claim.
# Sourced, never executed: no `set -e`, no `exit`, no output and no file write
# at source time. Safe under `set -uo pipefail` (every positional as ${n:-}).
# No `eval`, nothing under a build dir is ever sourced, jq is called with -n/-s
# and --arg only, no line here calls a model or the network, and file content is
# never re-parsed as shell — it flows into awk/sed/grep/jq as data.
#
# THE THREE BUILD-DIR ARTIFACTS
#   evidence-proposed.txt  model-written, optional. One line per claim:
#     CLAIM <n>: <CONFIRMED|REFUTED|INCONCLUSIVE> :: <artifact path[:line]> :: <note>
#   evidence-verdicts.txt  the scorer's own stdout (what the reviewer prompt receives).
#   evidence.json          the scorer's structured output, written atomically
#                          (mktemp in the build dir, then mv), shape:
#     {"total":T,"confirmed":C,"refuted":R,"inconclusive":I,"claims":[{"n":1,
#      "claim":"<text, max 300 chars>","verdict":"CONFIRMED|REFUTED|INCONCLUSIVE",
#      "artifact":"<path[:line] or empty>","note":"<text>","proposed":"<word or empty>"}]}
#
# The verdict vocabulary is exactly the three words CONFIRMED, REFUTED,
# INCONCLUSIVE. Nothing else is a verdict.
#
# WHAT A CLAIM IS. One top-level list item under `## Acceptance tests` in the
# plan (from that heading to the next heading of the same or higher level;
# fenced blocks skipped; wrapped continuation lines folded into the item; text
# bounded to 300 chars after control-char/pipe/backtick stripping). Numbered
# from 1 in document order. No section, empty section, or prose-only section →
# total=0, claims=[], no rows. Section extraction mirrors bin/kind-gate.sh. An
# absent heading and a present-but-empty one (no bullets, a table, or prose
# only) both score total=0 — but a present, empty heading also gets one
# `EVIDENCE NOTE: acceptance section present, no list items` line on stdout, so
# a consumer can tell "nothing to score" apart from "the plan forgot the
# section" (#547's wiring reads this).
#
# NAMED TESTS in a claim: every token matching the shapes
# bin/test-tamper-scan.sh:is_test_path accepts, from backticks or bare, matched
# as a WHOLE token — `tests/foo-test.sh` must not match `tests/foo-test.sh.bak`
# or `tests/foo-tests.sh`. The scan reads the whole item, not the 300-char cut.
#
# ARTIFACT SOURCES, IN PRECEDENCE: harness-suite-head.txt, then
# harness-suite-fix.txt, then harness-suite.txt (harness-run, ground truth),
# then validate.txt (agent-recorded). In a harness-suite file the artifact is
# the first line naming the test's path or basename together with a pass marker
# (✓, PASS, passed, ok) or a fail marker (✗, ×, FAIL, a NONZERO `N failed`, or
# TAP `not ok`); a bare "0 failed" in a pass summary is not a fail marker; a
# fail marker anywhere for that test wins over a pass. A harness-suite file
# whose LAST line-leading `HARNESS_EXIT:` value is not an integer
# (`could-not-run`, `no-test-script`) never ran: it decides nothing, pass or
# fail, and the next source is read (BH-8850). An integer value (0, 1, 124)
# or no `HARNESS_EXIT:` line at all leaves the file deciding as above. The
# test's own path and basename are deleted from the line before markers are
# matched, so tests/ok-test.sh never reads its own name as a pass. In
# validate.txt only a RUN LINE names a test — one starting `$ `, `CMD`,
# `COMMAND:`, `bash `, `RED`
# or `GREEN` (a prose line mentioning the path decides nothing); the LAST such
# run line wins (a RED block's failing run does not outrank a later GREEN
# rerun). The verdict comes from the first LINE-LEADING `exit`/`exit code`/`rc`
# token (case-insensitive: `EXIT: 0` and `exit 0` both count; embedded in
# prose, e.g. "rc 1" mid-sentence, never counts) in the following 60 lines
# (0 = pass, other = fail, none = not located), labelled
# `validate.txt:<line> (agent-recorded)`. A harness-run FAIL beats an
# agent-recorded pass. red.txt is never a source. `HARNESS_EXIT: 0` alone never
# confirms a test the suite output never names.
#
# STAGING CHECK (evidence_staged): for each named test file that
# `git -C <repo-dir> diff --name-only <base>...HEAD` lists, count ASSERT_RE
# lines at `git merge-base <base> HEAD` (never at `<base>`'s own tip, which may
# have moved since the branch forked) vs the working file. A named directory
# (`tests/x.d/`) counts every file under it, and a driver that
# `<repo-dir>/catalog/list-files.tsv` maps to a fragments dir (`<dir>/` input
# kind) counts the driver plus that dir, so an assertion moved into a fragment
# is not a drop (BH-8708). Count dropped → REFUTED, note `staged: assertions
# N->M in a test the diff touched`, regardless of validate.txt — unless the
# plan names the test under `## Tests that must change`: that drop is planned,
# INCONCLUSIVE, note `planned removal: N->M`. Untouched file, count rose, or
# count unchanged → never staged. File deleted in the diff → INCONCLUSIVE. A
# check that cannot run (not a repo, unknown base, no merge-base) →
# INCONCLUSIVE, never CONFIRMED.
#
# VERDICT RULES, IN ORDER, PER CLAIM:
#   1. any named test located as fail → REFUTED (artifact = that line);
#   2. any named test staged and not planned → REFUTED (artifact = <file> +
#      the N->M note);
#   2b. any named test staged and named under the plan's `## Tests that must
#      change` → INCONCLUSIVE (artifact = <file>, note `planned removal: N->M`);
#   3. every named test located as pass, none staged → CONFIRMED (artifact =
#      harness-run line if one exists, else the validate.txt:<line>
#      (agent-recorded) line);
#   4. tests named but none located → INCONCLUSIVE, note `named test never
#      appears in harness-suite*.txt or validate.txt`, or `harness suite could
#      not run (<file>)` when the first unlocated test was named only in a
#      skipped could-not-run file (BH-8850);
#   5. no test named: the proposal's artifact is used ONLY as a pointer — an
#      existing non-empty file under $BUILD/qa-shots/ or $BUILD/ → CONFIRMED
#      (artifact = that path); missing → INCONCLUSIVE, note `proposed CONFIRMED
#      but artifact missing`; no proposal → INCONCLUSIVE, note `no artifact
#      named`. Only $BUILD-relative paths are honoured; `../x` or `/etc/passwd`
#      count as missing;
#   6. a proposed REFUTED always stands; a proposed CONFIRMED never upgrades a
#      deterministic verdict; `proposed=<word>` is recorded beside the decided
#      one. A `CLAIM 9:` proposal on a 3-claim plan is ignored (out of range,
#      mentioned in that run's stdout), never a row.
#
# Stdout: one `CLAIM n: <VERDICT> :: <artifact> :: <note>` line per claim, then
# any `EVIDENCE NOTE:` lines, then a summary line
# `EVIDENCE VERDICTS: C confirmed, R refuted, I inconclusive of T claims`.
# evidence.json is written via tmp+mv so a crashed scorer never leaves a
# truncated file, and the summary prints only after the mv — a build with no
# evidence.json is un-scored, and saying "0 claims" would stamp it as scored.
# Fail-open: jq missing / build dir not writable / plan unreadable → one
# `EVIDENCE VERDICTS: could not run (<why>)` line, return 1, evidence.json
# untouched.
#
# THE KNOB: EVIDENCE_GATE_ENFORCE — the warn-first demoter for these verdicts,
# default off, documented in env-templates/global.env.example. The wiring
# sibling reads it exactly the way SCOPE_GATE_ENFORCE is read in
# bin/run-build.sh: `1|true|yes|on` on, `0|''|false|no|off` off, anything else
# off plus one ALERTS line. Nothing in THIS file reads it.

# The staging check counts assertions with the tamper scan's own regex. This
# line is byte-identical to the `^ASSERT_RE=` line in bin/test-tamper-scan.sh
# on purpose (no line number pinned here — both files move) and
# tests/evidence-no-staging-test.sh §3 fails if the two ever drift: two
# different ideas of "an assertion" would let a weakened test pass one and not
# the other.
ASSERT_RE='(expect\(|assert|should\(|\bok\b|\bbad\b|t\.(is|deepEqual|truthy)\(|require\.(True|Equal)|toBe|toEqual)'

_ev_clean() { # _ev_clean <text> [limit] — one printable line, bounded
  printf '%s' "${1:-}" \
    | tr -d '\000-\010\013-\037\177' \
    | tr '\011\012|`' '    ' \
    | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//' \
    | cut -c "1-${2:-300}"
}

_ev_ere() { # _ev_ere <text> — the text as an ERE literal
  # `@` is escaped too: evidence_locate's own-token scrub uses `@` as its sed
  # delimiter (a test path contains `/`, which rules out the usual one), and an
  # unescaped `@` in a path would be read as a second delimiter instead of a
  # literal character, breaking the substitution silently (finding #8).
  printf '%s' "${1:-}" | sed 's/[][\.*^$+?(){}|/@]/\\&/g'
}

_ev_is_test_path() { # a verbatim copy of bin/test-tamper-scan.sh:is_test_path
  case "$1" in
    */test/*|*/tests/*|*/__tests__/*|*/spec/*|test/*|tests/*|spec/*) return 0 ;;
    *.test.*|*.spec.*|*_test.go|*_test.py|test_*.py|*Test.java|*Tests.cs) return 0 ;;
    *test*.sh) return 0 ;;
    *) return 1 ;;
  esac
}

_ev_items() { # _ev_items <plan> — <n>TAB<bounded text>TAB<whole item text>
  local plan="${1:-}" n=0 text
  [ -n "$plan" ] && [ -r "$plan" ] || return 0
  # CRLF line endings defeat the heading match (a trailing \r survives after
  # `sub`/`gsub` strip everything else), so a CRLF plan silently scored zero
  # claims — the same "indistinguishable from no section" gap the note in
  # evidence_score exists to close (round-2 finding #4). Stripped on the way
  # in, once, for both this function and _ev_has_section below.
  tr -d '\r' < "$plan" 2>/dev/null | awk '
    function flushit() { if (item != "") { print item; item = "" } }
    {
      line = $0
      if (line ~ /^[ \t]*(```|~~~)/) { fence = 1 - fence; flushit(); next }
      if (fence) next
      if (line ~ /^#+[ \t]/) {
        match(line, /^#+/); lvl = RLENGTH
        t = tolower(line); sub(/^#+[ \t]*/, "", t); gsub(/[*`#]/, "", t); sub(/^[ \t]+/, "", t)
        flushit()
        if (t ~ /^(acceptance tests?)([ \t:—-]|$)/) { insect = 1; seclvl = lvl; next }
        if (insect && lvl <= seclvl) { insect = 0 }
        next
      }
      if (!insect) next
      if (line ~ /^[ \t]*$/) { blank = 1; next }
      if (line ~ /^[ \t]*([-*+]|[0-9]+[.)])[ \t]+/) {
        # A marker indented more than 3 is a NESTED bullet: it folds into its
        # parent item below, it is not a claim of its own. (The indent is
        # measured rather than written into the regex: mawk 1.3.4 panics on an
        # interval followed by an alternation group.)
        match(line, /^[ \t]*/)
        if (RLENGTH <= 3) {
          flushit()
          s = line; sub(/^[ \t]*([-*+]|[0-9]+[.)])[ \t]+/, "", s); gsub(/\t/, " ", s)
          item = s; blank = 0; next
        }
      }
      if (item != "") {
        if (blank && line ~ /^[^ \t]/) { flushit(); blank = 0; next }
        s = line; sub(/^[ \t]+/, "", s); gsub(/\t/, " ", s)
        item = item " " s
      }
      blank = 0
    }
    END { flushit() }
  ' 2>/dev/null | while IFS= read -r text; do
    [ -n "$text" ] || continue
    n=$((n+1))
    printf '%s\t%s\t%s\n' "$n" "$(_ev_clean "$text")" "$text"
  done
  return 0
}

evidence_claims() { # evidence_claims <plan> — <n>TAB<bounded claim text>
  _ev_items "${1:-}" | cut -f1,2
  return 0
}

_ev_has_section() { # _ev_has_section <plan> — an `## Acceptance tests` heading exists, any level
  local plan="${1:-}"
  [ -n "$plan" ] && [ -r "$plan" ] || return 1
  # CRLF-stripped for the same reason as _ev_items (round-2 finding #4).
  tr -d '\r' < "$plan" 2>/dev/null | awk '
    {
      line = $0
      if (line ~ /^#+[ \t]/) {
        t = tolower(line); sub(/^#+[ \t]*/, "", t); gsub(/[*`#]/, "", t); sub(/^[ \t]+/, "", t)
        if (t ~ /^(acceptance tests?)([ \t:—-]|$)/) { found = 1; exit }
      }
    }
    END { exit !found }
  ' 2>/dev/null
}

evidence_tests_in() { # evidence_tests_in <item text> — the test paths it names
  local txt tok seen="" toks=()
  # Backticks, quotes, brackets and separators are never part of a path: blank
  # them out, then split on whitespace, so only WHOLE tokens are tested. The
  # split is an array, not a `read` loop: a path that ends the item has no
  # trailing separator, and `read` drops that last unterminated token — which
  # is exactly how a plan that names its test bare, at the end of the line,
  # goes unnoticed.
  txt=$(printf '%s' "${1:-}" | sed 's/[]`'"'"'"(){},;|[]/ /g' | tr '\011\012' '  ')
  read -ra toks <<< "$txt"
  for tok in ${toks[@]+"${toks[@]}"}; do
    while [ -n "$tok" ]; do
      case "$tok" in *[.:,\;\)]) tok=${tok%?} ;; *) break ;; esac
    done
    [[ "$tok" =~ ^(.+):[0-9]+$ ]] && tok="${BASH_REMATCH[1]}"
    [ -n "$tok" ] || continue
    _ev_is_test_path "$tok" || continue
    case " $seen " in *" $tok "*) continue ;; esac
    seen="$seen $tok"
    printf '%s\n' "$tok"
  done
  return 0
}

evidence_locate() { # evidence_locate <build> <test> — <pass|fail|none>TAB<artifact>TAB<note>
  local build="${1:-}" tst="${2:-}" f epath ebase enames nm hit ln content scrub
  local passref="" passnote="" win num eln vhit vln vcontent ex cnrfile=""
  # A bare "failed" is not a fail marker: a pass summary like "12 passed, 0
  # failed" must not refute the claim it is reporting success on. Only a
  # NONZERO count before "failed" counts (finding #3).
  local FAIL_RE='(✗|×|\bFAIL(ED)?\b|\b[1-9][0-9]* failed\b|\bnot ok\b)'
  local PASS_RE='(✓|\bPASS(ED)?\b|\bpassed\b|\bok\b)'
  # TAP's `# SKIP` directive on an `ok` line means the case never ran — it is
  # not evidence either way, so it must not read as a pass (round-2 finding
  # #3). Checked after FAIL_RE (a skip is never a failure) and before PASS_RE.
  local SKIP_RE='#[[:space:]]*SKIP\b'
  # Only a RUN line can name a test in validate.txt: `$ …`, `CMD …`/`CMD :…`,
  # `COMMAND:…`, `bash …`, or a `RED`/`GREEN` block marker. A prose line that
  # merely mentions the path (e.g. "tests/a-test.sh flaked before") must not be
  # read as the run that proves or refutes the claim (finding #2). The `$` is
  # written as the bracket expression `[$]`, not `\$`: this string is later
  # handed to awk via `-v` (the round-3 window cut, below), and a `-v` value
  # goes through the SAME backslash-escape processing as an awk string
  # literal before it becomes a regex — `\$` degrades to a bare `$` anchor on
  # gawk/BSD/busybox awk (round-3 finding #1). `[$]` has no backslash at all,
  # so there is nothing for that pass to mangle, on any awk — and it still
  # reads as a literal `$` in the `grep -qE` use of this same string below.
  local RUN_RE='^[[:space:]]*([$][[:space:]]|CMD|COMMAND:|bash[[:space:]]|RED[[:space:]:]|GREEN[[:space:]:])'
  [ -n "$build" ] && [ -n "$tst" ] || { printf 'none\t\t\n'; return 0; }
  epath=$(_ev_ere "$tst"); ebase=$(_ev_ere "${tst##*/}"); enames="$epath|$ebase"
  # A directory claim (`tests/x.d/`) has an empty basename: `($epath|)` would
  # match every line, and `s@@ @g` would reuse sed's last regex. It is named by
  # its path only (BH-8708).
  [ -n "$ebase" ] || enames="$epath"
  # A line "names" the test when its path or basename appears as a whole token.
  for f in harness-suite-head.txt harness-suite-fix.txt harness-suite.txt; do
    [ -f "$build/$f" ] || continue
    nm=$(grep -nE "(^|[^A-Za-z0-9_./-])($enames)([^A-Za-z0-9_./-]|\.([^A-Za-z0-9_-]|\$)|\$)" \
         "$build/$f" 2>/dev/null)
    [ -n "$nm" ] || continue
    # A file whose LAST line-leading `HARNESS_EXIT:` is not an integer
    # (`could-not-run`, `no-test-script`) never ran the suite: its lines
    # decide nothing, so try the next source (BH-8850). Read the same way as
    # LIVE_SUITE (bin/lib/rb/gates.sh). No `HARNESS_EXIT:` line at all keeps
    # the old behaviour: the file decides.
    ex=$(sed -n 's/^HARNESS_EXIT:[[:space:]]*//p' "$build/$f" 2>/dev/null | tail -1)
    ex=${ex//[[:space:]]/}
    if [ -n "$ex" ] && ! [[ "$ex" =~ ^-?[0-9]+$ ]]; then
      [ -n "$cnrfile" ] || cnrfile="$f"
      continue
    fi
    passref=""; passnote=""
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      ln=${hit%%:*}; content=${hit#*:}
      # The test's own name is not a marker: tests/ok-test.sh must not read its
      # own basename as a pass, and `bad` in a name is not a failure.
      if [ -n "$ebase" ]; then
        scrub=$(printf '%s' "$content" | sed -E "s@$epath@ @g; s@$ebase@ @g" 2>/dev/null)
      else
        scrub=$(printf '%s' "$content" | sed -E "s@$epath@ @g" 2>/dev/null)
      fi
      if grep -qE "$FAIL_RE" <<<"$scrub"; then
        printf 'fail\t%s:%s\t%s\n' "$f" "$ln" "$(_ev_clean "$content")"
        return 0
      fi
      if grep -qiE "$SKIP_RE" <<<"$scrub"; then
        : # a skipped case decides nothing on this line; try the next hit/file
      elif [ -z "$passref" ] && grep -qE "$PASS_RE" <<<"$scrub"; then
        passref="$f:$ln"; passnote=$(_ev_clean "$content")
      fi
    done <<< "$nm"
    # Named with no marker at all: this file decides nothing, try the next.
    [ -n "$passref" ] || continue
    printf 'pass\t%s\t%s\n' "$passref" "$passnote"
    return 0
  done
  f=validate.txt
  if [ -f "$build/$f" ]; then
    # Take the LAST run line naming the path, not the first: a RED block's
    # failing rerun above a later GREEN rerun of the same test must not outrank
    # the GREEN one (finding #2).
    ln=""
    while IFS= read -r vhit; do
      [ -n "$vhit" ] || continue
      vln=${vhit%%:*}; vcontent=${vhit#*:}
      grep -qE "$RUN_RE" <<<"$vcontent" && ln="$vln"
    done <<< "$(grep -nE "(^|[^A-Za-z0-9_./-])($epath)([^A-Za-z0-9_./-]|\.([^A-Za-z0-9_-]|\$)|\$)" \
                "$build/$f" 2>/dev/null)"
    if [ -n "$ln" ]; then
      # The exit token must be LINE-LEADING (never matched mid-sentence, e.g.
      # "the driver saw rc 1 here" — finding #2) and matched case-insensitively
      # (the executor's own template writes `EXIT: 0`, not just `exit 0` —
      # finding #1). The window is also cut at the NEXT run line or a
      # `NOT RUN:` line, whichever comes first: the executor writes one block
      # per task (TASK/CMD/EXIT, roughly 15 lines), so without a stop a test
      # recorded `NOT RUN:` — or one whose own block has no exit line at all —
      # reads deep into its neighbour's block and borrows that task's EXIT,
      # scoring a false CONFIRMED or REFUTED on a test nobody ran (round-2
      # finding #1). A block with no exit token inside its own bounds falls
      # through to `none` below, same as today. The `NOT RUN` stop is written
      # as `not run([^a-z0-9_]|$)` against a lowercased copy of the line, not
      # `NOT RUN\b`: `\b` is a WORD BOUNDARY in grep/PCRE but the BACKSPACE
      # character (0x08) in mawk and gawk, so the literal it used to be never
      # matched on either (round-3 finding #1); this form needs no `\b` and
      # also tolerates a lowercase `not run:` for free.
      win=$(sed -n "$((ln+1)),$((ln+60))p" "$build/$f" 2>/dev/null \
            | awk -v re="$RUN_RE" '
                { if ($0 ~ re) exit
                  low = tolower($0)
                  if (low ~ /^[[:space:]]*not run([^a-z0-9_]|$)/) exit
                  print }' \
            | grep -inEm1 '^[[:space:]]*(exit( code)?|rc)\b[[:space:]]*[:=]?[[:space:]]*-?[0-9]+')
      if [ -n "$win" ]; then
        eln=$((ln + ${win%%:*})); content=${win#*:}
        num=$(printf '%s' "$content" \
              | grep -ioE '^[[:space:]]*(exit( code)?|rc)\b[[:space:]]*[:=]?[[:space:]]*-?[0-9]+' \
              | head -1 | grep -oE -- '-?[0-9]+$')
        if [ "${num:-x}" = "0" ]; then
          printf 'pass\t%s:%s (agent-recorded)\t%s\n' "$f" "$ln" "$(_ev_clean "$content")"
        else
          printf 'fail\t%s:%s (agent-recorded)\t%s\n' "$f" "$eln" "$(_ev_clean "$content")"
        fi
        return 0
      fi
    fi
  fi
  if [ -n "$cnrfile" ]; then
    printf 'none\t\tharness suite could not run (%s)\n' "$cnrfile"
  else
    printf 'none\t\t\n'
  fi
  return 0
}

_ev_fragment_dir() { # _ev_fragment_dir <repo> <test> — the fragments dir catalog/list-files.tsv maps <test> to
  # Column 1 is compared as a literal path with its `\` escapes removed, never
  # as a glob. Only the `<dir>/` input kind is a fragments dir: a `rendered` or
  # `ignored` dir holds a render, not moved assertions. No file, no row: nothing.
  local repo="${1:-}" tst="${2:-}"
  [ -n "$repo" ] && [ -n "$tst" ] && [ -r "$repo/catalog/list-files.tsv" ] || return 0
  tr -d '\r' < "$repo/catalog/list-files.tsv" 2>/dev/null | awk -F'\t' -v t="$tst" '
    /^#/ || /^[ \t]*$/ { next }
    { p = $1; gsub(/\\/, "", p)
      if (p == t && $2 ~ /\/$/ && $2 !~ /^(rendered|ignored) /) { print $2; exit } }' 2>/dev/null
  return 0
}

_ev_assert_count() { # _ev_assert_count <repo> <rev|-> <path>... — ASSERT_RE lines summed over every file under each path
  # <rev> reads the files git holds at that commit; `-` reads the tracked
  # files from the working tree. A missing path adds 0.
  local repo="${1:-}" rev="${2:-}" sum=0 p f c files
  shift 2 2>/dev/null || { printf '0\n'; return 0; }
  for p in "$@"; do
    if [ "$rev" = - ]; then
      files=$(git -C "$repo" -c core.quotePath=off ls-files -- "$p" 2>/dev/null </dev/null)
    else
      files=$(git -C "$repo" -c core.quotePath=off ls-tree -r --name-only "$rev" -- "$p" 2>/dev/null </dev/null)
    fi
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if [ "$rev" = - ]; then
        c=$(grep -cE "$ASSERT_RE" "$repo/$f" 2>/dev/null)
      else
        c=$(git -C "$repo" show "$rev:$f" 2>/dev/null </dev/null | grep -cE "$ASSERT_RE")
      fi
      sum=$((sum + ${c:-0}))
    done <<< "$files"
  done
  printf '%s\n' "$sum"
  return 0
}

evidence_staged() { # evidence_staged <repo-dir> <base> <test> — no|deleted|staged N M|unknown
  local repo="${1:-}" base="${2:-}" tst="${3:-}" listed delisted n m mb frag paths
  [ -n "$repo" ] && [ -n "$base" ] && [ -n "$tst" ] || { printf 'unknown\n'; return 0; }
  listed=$(git -C "$repo" diff --name-only "$base"...HEAD -- "$tst" 2>/dev/null </dev/null) \
    || { printf 'unknown\n'; return 0; }
  [ -n "$listed" ] || { printf 'no\n'; return 0; }
  # captured first: grep -q exits at the first path while git is still writing
  # the rest of the name list, and pipefail hands the `if` git's 141 — a deleted
  # test then reads as not deleted (BH-1248).
  delisted=$(git -C "$repo" diff --name-only --diff-filter=D "$base"...HEAD -- "$tst" 2>/dev/null </dev/null)
  if grep -q . <<<"$delisted"; then
    printf 'deleted\n'; return 0
  fi
  # Count assertions at the MERGE-BASE, never at <base>'s own current tip: a
  # long-lived base moves after the branch forks, and comparing against its
  # later state can manufacture a false drop the branch never made (finding
  # #4) — e.g. base grows the test 3->10 after the branch already grew it
  # 3->5; counting at base's tip reads that as "10->5, REFUTED" when nothing
  # on the branch regressed. A merge-base that cannot be found is INCONCLUSIVE,
  # same as any other staging check that cannot run.
  mb=$(git -C "$repo" merge-base "$base" HEAD 2>/dev/null </dev/null) \
    || { printf 'unknown\n'; return 0; }
  # Absent at the merge-base means the diff ADDED the test: new assertions, not staging.
  git -C "$repo" cat-file -e "$mb:${tst%/}" >/dev/null 2>&1 </dev/null || { printf 'no\n'; return 0; }
  # One suite can span several files (BH-8708): a directory claim counts every
  # file under it, and a driver that catalog/list-files.tsv maps to a fragments
  # dir counts the driver plus that dir. An assertion moved into a fragment is
  # not an assertion removed.
  paths=("$tst")
  case "$tst" in
    */) ;;
    *) frag=$(_ev_fragment_dir "$repo" "$tst"); [ -z "$frag" ] || paths+=("$frag") ;;
  esac
  n=$(_ev_assert_count "$repo" "$mb" "${paths[@]}")
  m=$(_ev_assert_count "$repo" - "${paths[@]}")
  [ -n "$n" ] || n=0
  [ -n "$m" ] || m=0
  if [ "$n" -gt "$m" ]; then printf 'staged %s %s\n' "$n" "$m"; else printf 'no\n'; fi
  return 0
}

_ev_artifact_ok() { # _ev_artifact_ok <build> <artifact> — a real, non-empty, $BUILD-relative file
  local build="${1:-}" a="${2:-}" p
  [ -n "$a" ] || return 1
  case "$a" in /*) return 1 ;; esac
  case "/$a/" in */../*) return 1 ;; esac
  p="$a"
  [[ "$p" =~ ^(.+):[0-9]+$ ]] && p="${BASH_REMATCH[1]}"
  [ -f "$build/$p" ] && [ -s "$build/$p" ]
}

evidence_proposals() { # evidence_proposals <build> <total> — <n>TAB<verdict>TAB<artifact>TAB<note>
  local build="${1:-}" total="${2:-0}" f="${1:-}/evidence-proposed.txt" n verdict art note seen=""
  [ -f "$f" ] || return 0
  tr -d '\r' < "$f" 2>/dev/null \
    | sed -nE 's/^CLAIM ([0-9]+): (CONFIRMED|REFUTED|INCONCLUSIVE) :: (.*) :: (.*)$/\1\t\2\t\3\t\4/p' \
    | while IFS=$'\t' read -r n verdict art note; do
        [ -n "${n:-}" ] || continue
        case " $seen " in *" $n "*) continue ;; esac
        seen="$seen $n"
        if [ "$n" -lt 1 ] || [ "$n" -gt "$total" ]; then
          printf 'EVIDENCE NOTE: proposal CLAIM %s ignored (out of range, %s claims)\n' "$n" "$total"
          continue
        fi
        printf '%s\t%s\t%s\t%s\n' "$n" "$verdict" "$(_ev_clean "$art")" "$(_ev_clean "$note")"
      done
  return 0
}

_ev_planned_tests() { # _ev_planned_tests <plan> — each tests/ path under `## Tests that must change`
  # Any heading level, case-insensitive, to the next heading of the same or
  # higher level; CRLF stripped and fenced blocks skipped (as _ev_items). The
  # path shape is bin/lib/pr-self-check.sh's _psc_tc_path, trailing dots cut.
  local plan="${1:-}" line p
  [ -n "$plan" ] && [ -r "$plan" ] || return 0
  tr -d '\r' < "$plan" 2>/dev/null | awk '
    {
      line = $0
      if (line ~ /^[ \t]*(```|~~~)/) { fence = 1 - fence; next }
      if (fence) next
      if (line ~ /^#+[ \t]/) {
        match(line, /^#+/); lvl = RLENGTH
        t = tolower(line); sub(/^#+[ \t]*/, "", t); gsub(/[*`#]/, "", t); sub(/^[ \t]+/, "", t)
        if (t ~ /^tests that must change([ \t:—-]|$)/) { insect = 1; seclvl = lvl; next }
        if (insect && lvl <= seclvl) { insect = 0 }
        next
      }
      if (insect) print
    }' 2>/dev/null | while IFS= read -r line; do
    while [[ "$line" =~ (^|[^A-Za-z0-9_./-])(tests/[A-Za-z0-9_./-]+)(.*)$ ]]; do
      p="${BASH_REMATCH[2]}"; line="${BASH_REMATCH[3]}"
      while [[ "$p" == *. ]]; do p=${p%.}; done
      printf '%s\n' "$p"
    done
  done
  return 0
}

evidence_score() { # evidence_score <build> <plan> <base> <repo-dir>
  local build="${1:-}" plan="${2:-}" base="${3:-}" repo="${4:-}"
  local rows tmp items props prows pnotes n claim whole tests t prow
  local verdict artifact note proposed partifact pnote st loc lv la lnote
  local anyfail failref failnote anystaged stagedn stagedm deleted unknown
  local firstunloc firstunlocnote harnessref harnessnote validref validnote total=0
  local section_empty_note="" plannedtests planned plannedn plannedm
  command -v jq >/dev/null 2>&1 || {
    printf 'EVIDENCE VERDICTS: could not run (jq missing)\n'; return 1; }
  [ -n "$build" ] && [ -d "$build" ] && [ -w "$build" ] || {
    printf 'EVIDENCE VERDICTS: could not run (build dir not writable)\n'; return 1; }
  [ -n "$plan" ] && [ -f "$plan" ] && [ -r "$plan" ] || {
    printf 'EVIDENCE VERDICTS: could not run (plan unreadable)\n'; return 1; }
  items=$(_ev_items "$plan")
  plannedtests=$(_ev_planned_tests "$plan")
  [ -z "$items" ] || total=$(printf '%s\n' "$items" | grep -c .)
  # A present-but-empty section (no bullets, a table, prose only) scores the
  # same zero total as no section at all — but the two mean different things
  # to a caller: one is "nothing to prove", the other is "the plan forgot the
  # acceptance tests". This note is how #547's wiring tells them apart
  # (finding #7); it never changes total, claims or any verdict.
  if [ "$total" -eq 0 ] && _ev_has_section "$plan"; then
    section_empty_note="EVIDENCE NOTE: acceptance section present, no list items"
  fi
  props=$(evidence_proposals "$build" "$total")
  prows=$(printf '%s\n' "$props" | grep -E '^[0-9]+[[:space:]]')
  pnotes=$(printf '%s\n' "$props" | grep '^EVIDENCE NOTE:')
  rows=$(mktemp "$build/evidence.rows.XXXXXX" 2>/dev/null) || {
    printf 'EVIDENCE VERDICTS: could not run (build dir not writable)\n'; return 1; }
  tmp=$(mktemp "$build/evidence.json.XXXXXX" 2>/dev/null) || {
    rm -f "$rows" 2>/dev/null
    printf 'EVIDENCE VERDICTS: could not run (build dir not writable)\n'; return 1; }
  while IFS=$'\t' read -r n claim whole; do
    [ -n "${n:-}" ] || continue
    verdict=""; artifact=""; note=""; proposed=""; partifact=""; pnote=""
    prow=$(printf '%s\n' "$prows" | awk -F'\t' -v k="$n" '$1==k {print; exit}')
    if [ -n "$prow" ]; then
      proposed=$(printf '%s' "$prow" | cut -f2)
      partifact=$(printf '%s' "$prow" | cut -f3)
      pnote=$(printf '%s' "$prow" | cut -f4)
    fi
    tests=$(evidence_tests_in "$whole")
    if [ -n "$tests" ]; then
      anyfail=""; failref=""; failnote=""; anystaged=""; stagedn=""; stagedm=""
      planned=""; plannedn=""; plannedm=""
      deleted=""; unknown=""; firstunloc=""; firstunlocnote=""
      harnessref=""; harnessnote=""; validref=""; validnote=""
      while IFS= read -r t; do
        [ -n "$t" ] || continue
        st=$(evidence_staged "$repo" "$base" "$t")
        case "$st" in
          # A drop the plan declares under `## Tests that must change` is a
          # planned removal, not staging (BH-8708).
          staged*) if grep -qxF -- "$t" <<<"$plannedtests"; then
                     [ -n "$planned" ] || {
                       planned="$t"
                       plannedn=$(printf '%s' "$st" | cut -d' ' -f2)
                       plannedm=$(printf '%s' "$st" | cut -d' ' -f3); }
                   else
                     [ -n "$anystaged" ] || {
                       anystaged="$t"
                       stagedn=$(printf '%s' "$st" | cut -d' ' -f2)
                       stagedm=$(printf '%s' "$st" | cut -d' ' -f3); }
                   fi ;;
          deleted) [ -n "$deleted" ] || deleted="$t" ;;
          unknown) [ -n "$unknown" ] || unknown="$t" ;;
        esac
        loc=$(evidence_locate "$build" "$t")
        lv=$(printf '%s' "$loc" | cut -f1)
        la=$(printf '%s' "$loc" | cut -f2)
        lnote=$(printf '%s' "$loc" | cut -f3)
        case "$lv" in
          fail) [ -n "$anyfail" ] || { anyfail="$t"; failref="$la"; failnote="$lnote"; } ;;
          pass) case "$la" in
                  validate.txt*) [ -n "$validref" ] || { validref="$la"; validnote="$lnote"; } ;;
                  *) [ -n "$harnessref" ] || { harnessref="$la"; harnessnote="$lnote"; } ;;
                esac ;;
          *) [ -n "$firstunloc" ] || { firstunloc="$t"; firstunlocnote="$lnote"; } ;;
        esac
      done <<< "$tests"
      if [ -n "$anyfail" ]; then
        verdict=REFUTED; artifact="$failref"
        note="${failnote:-named test $anyfail was located as failed}"
      elif [ -n "$anystaged" ]; then
        verdict=REFUTED; artifact="$anystaged"
        note="staged: assertions $stagedn->$stagedm in a test the diff touched"
      elif [ -n "$planned" ]; then
        verdict=INCONCLUSIVE; artifact="$planned"
        note="planned removal: $plannedn->$plannedm"
      elif [ -n "$deleted" ]; then
        verdict=INCONCLUSIVE; note="named test deleted in the diff ($deleted)"
      elif [ -n "$unknown" ]; then
        verdict=INCONCLUSIVE; note="staging check could not run against ${base:-<no base>}"
      elif [ -z "$firstunloc" ]; then
        verdict=CONFIRMED; artifact="${harnessref:-$validref}"
        note="${harnessnote:-$validnote}"
      else
        verdict=INCONCLUSIVE
        note="${firstunlocnote:-named test never appears in harness-suite*.txt or validate.txt ($firstunloc)}"
      fi
    elif [ "$proposed" = CONFIRMED ] && _ev_artifact_ok "$build" "$partifact"; then
      verdict=CONFIRMED; artifact="$partifact"; note="proposed CONFIRMED, artifact present"
    elif [ "$proposed" = CONFIRMED ]; then
      verdict=INCONCLUSIVE; note="proposed CONFIRMED but artifact missing"
    else
      verdict=INCONCLUSIVE; note="no artifact named"
    fi
    # Rule 6: the model can always DEMOTE, never upgrade.
    if [ "$proposed" = REFUTED ]; then
      verdict=REFUTED; artifact="$partifact"; note="${pnote:-proposed REFUTED}"
    fi
    jq -n --arg n "$n" --arg claim "$claim" --arg verdict "$verdict" \
       --arg artifact "$artifact" --arg note "$note" --arg proposed "$proposed" \
       '{n:($n|tonumber),claim:$claim,verdict:$verdict,artifact:$artifact,
         note:$note,proposed:$proposed}' >> "$rows" 2>/dev/null
  done <<< "$items"
  if ! jq -s '{total:length,
               confirmed:(map(select(.verdict=="CONFIRMED"))|length),
               refuted:(map(select(.verdict=="REFUTED"))|length),
               inconclusive:(map(select(.verdict=="INCONCLUSIVE"))|length),
               claims:.}' "$rows" > "$tmp" 2>/dev/null \
     || ! mv -f "$tmp" "$build/evidence.json" 2>/dev/null; then
    rm -f "$rows" "$tmp" 2>/dev/null
    printf 'EVIDENCE VERDICTS: could not run (build dir not writable)\n'; return 1
  fi
  rm -f "$rows" 2>/dev/null
  # Every byte of these lines is assembled INSIDE jq: a claim or a note carrying
  # $(…) or a backtick stays data all the way to the reviewer's prompt.
  jq -r '.claims[]? | "CLAIM \(.n): \(.verdict) :: \(.artifact) :: \(.note)"' \
     "$build/evidence.json" 2>/dev/null
  [ -z "$section_empty_note" ] || printf '%s\n' "$section_empty_note"
  [ -z "$pnotes" ] || printf '%s\n' "$pnotes"
  jq -r '"EVIDENCE VERDICTS: \(.confirmed) confirmed, \(.refuted) refuted, \(.inconclusive) inconclusive of \(.total) claims"' \
     "$build/evidence.json" 2>/dev/null
  return 0
}

evidence_counts() { # evidence_counts <build> — a reader, never a gate: always rc 0
  local build="${1:-}" out
  out=$(jq -r '"confirmed=\(.confirmed) refuted=\(.refuted) inconclusive=\(.inconclusive) total=\(.total)"' \
        "$build/evidence.json" 2>/dev/null)
  [ -n "$out" ] || { printf 'not-recorded\n'; return 0; }
  printf '%s\n' "$out"
  return 0
}

evidence_note() { # evidence_note <build> — the CLAIM lines again, from the JSON
  # Every byte of the line is assembled INSIDE jq, so a note carrying $(…) or a
  # backtick stays data. Nothing here expands file content.
  local build="${1:-}"
  [ -f "$build/evidence.json" ] || return 0
  jq -r '.claims[]? | "CLAIM \(.n): \(.verdict) :: \(.artifact) :: \(.note)"' \
     "$build/evidence.json" 2>/dev/null
  return 0
}
