#!/bin/bash
# tests/gh-rest-no-subshell-lint.sh — no caller may wrap a bin/lib/gh-rest.sh
# helper in a command substitution.
#
# THE RULE. `bin/lib/gh-rest.sh`'s own header states it: "when you need the
# status after a helper, run the helper as a plain command with `> file` and
# read the file; a helper inside `$( )` still returns the right rc, but its
# status stays in the subshell that then died." GH_REST_STATUS and
# GH_REST_REASON are assigned in the shell that CALLS the helper, and a command
# substitution is a subshell: the rc survives, the two variables do not.
#
# WHAT THAT COSTS. BH-781: "every alert said HTTP 000 for a 403 the library had
# classified correctly". BH-1485 measured it still true on 21 live call sites —
# among them `bin/lib/mc/rebase.sh`'s stack-parent read, which logged
# `HTTP 000` through an hour of a measurably exhausted hourly quota, so the
# rate limit and a dead network read identically in the log and in ALERTS.log
# and the diagnosis needed a manual `rate_limit` call from the box.
#
# WHAT IS FLAGGED: a `$(`, `$( ` or backtick immediately followed by one of the
# ENUMERATED status-bearing helper names — `gh_rest`, `gh_rest_pr_state`,
# `gh_rest_pr_list`, `gh_rest_pr_list_all`, `gh_rest_issue_state`,
# `gh_rest_issue_list`, `gh_rest_issue_comments`, `gh_rest_comment`,
# `gh_rest_close`, `gh_rest_alert`, and BH-1485's `gh_rest_*_var` variants
# (which are flagged too: a variant that exists to keep the status alive is
# pointless inside a subshell). Enumerated, not a `gh_rest*` prefix wildcard
# (BH-1485 fix round) — see the list's own comment in scan.py for why.
#
# WHAT IS DELIBERATELY NOT FLAGGED:
#   - comments. A sentence about `$(gh_rest GET …)` loses no status, and
#     bin/lib/mc/classify.sh's header quotes the bug it fixed verbatim.
#   - heredoc bodies, ONLY when the opener is real code, not text inside a
#     quoted string a script is writing out (BH-1485 fix round, review I1).
#     Several scripts WRITE shell into a fixture or a remote script; the text
#     in a real heredoc, or inside a string that merely LOOKS like one, is
#     data to this file either way.
#     The terminator word is matched WHOLE (BH-1522): a heredoc body is only
#     skipped up to the word the opener actually named, so an opener like
#     `<<PRE || true` cannot be misread as opening `PR` and swallow the rest
#     of the file. Row 5 asserts repo-wide that no file's scan ends still
#     inside a heredoc body, which is what that misreading looks like.
#   - `_gh_rest_*` privates. They are internal to the library, which obeys its
#     own rule, and `$(_gh_rest_stfile)` (bin/lib/mc/classify.sh) prints a PATH
#     and performs no read — a rule that dragged it in would be wrong about it.
#   - a `gh_rest_*`-NAMED helper that is not one of the enumerated callers —
#     `gh_rest_path_class` (bin/lib/gh-rest-ledger.sh) classifies a path
#     string and never touches GH_REST_STATUS/GH_REST_REASON; capturing it
#     loses nothing.
#
# A SCAN THAT SCANNED NOTHING IS NOT A PASS (D9): a tree with no `bin/**/*.sh`
# in it exits 2, never 0.
#
# The scanner is written out as a standalone program and the SAME program scans
# the repo and the fixtures below — a lint nobody has watched fail is a lint
# nobody knows is wired up. It prints `path:line`, never the line's contents: a
# flagged line can carry a token in its arguments.
#
# Run from anywhere: bash tests/gh-rest-no-subshell-lint.sh   (exit 0 = clean)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

mkdir -p "$T/mut/bin/lib" "$T/empty5"

cat > "$T/scan.py" <<'PY'
import os, re, sys

# The public, status-bearing gh-rest helpers, ENUMERATED — not a `gh_rest`
# prefix wildcard. BH-1485 fix round: rebasing onto BH-1484's ledger (#1493)
# landed gh_rest_path_class() (bin/lib/gh-rest-ledger.sh), a pure path
# classifier with no REST call and no GH_REST_STATUS/GH_REST_REASON of its
# own — `cls=$(gh_rest_path_class "${2:-}")` loses nothing by being captured,
# and under a prefix wildcard it read as a 22nd offender. gh_rest_etag_report()
# is the same shape (a log-line writer, no REST call). A wildcard also means
# any future gh_rest_*-named helper anywhere in the tree — REST caller or
# not — silently joins this lint's scope the day it is defined; naming the
# real callers instead means a genuinely new status-bearing helper has to be
# ADDED here to be covered, the direction a lint that guards a real loss of
# information should err in. `\b` after each name so `gh_rest_pr_list` does
# not falsely terminate before `gh_rest_pr_list_all`/`_var` — re.search
# backtracks across the alternation until the trailing `\b` is satisfied, so
# the ordering below does not matter.
HELPERS = (
    "gh_rest", "gh_rest_pr_state", "gh_rest_pr_state_var",
    "gh_rest_pr_list", "gh_rest_pr_list_var", "gh_rest_pr_list_all",
    "gh_rest_issue_state", "gh_rest_issue_state_var",
    "gh_rest_issue_list", "gh_rest_issue_comments", "gh_rest_issue_events",
    "gh_rest_comment", "gh_rest_close", "gh_rest_alert", "gh_rest_var",
)
# `$(gh_rest`, `$( gh_rest` and the backtick form. A BACKSLASH in front is not
# a substitution at all: `"\$(gh_rest …)"` is the four characters, which is
# how a script QUOTES the bug in a message. Note the opposite is not true —
# `"$(gh_rest …)"` inside double quotes runs, so a rule that exempted quoted
# text would exempt the commonest offending shape there is.
CALL = re.compile(
    r"(?<!\\)(?:\$\(|`)\s*(" + "|".join(re.escape(h) for h in HELPERS) + r")\b"
)
# A heredoc opener: `<<WORD`, `<<-WORD`, `<<'WORD'`, `<<"WORD"`. The body is
# data, not code this file gets to have an opinion about.
#
# BH-1485 fix round (review I1), three false-heredoc traps closed:
#   - `(?<!<)` in front: a here-string `<<<word` is two `<<` immediately
#     followed by a third `<`, which used to match the SAME as a real opener
#     and swallow the rest of the file as a phony "heredoc body" nothing ever
#     terminates. The lookbehind rejects the match that starts on the second
#     `<` of the triple, and the match starting on the first `<` then fails
#     for a different reason: the next character is `<`, not `[A-Za-z_]`.
#   - `(?!\s*[)&|;])` after the word: `$(( a << b ))` is an arithmetic left
#     shift, not a heredoc, and `b` looks like a valid terminator word to the
#     old pattern — the body then never closes (no line is ever bare `b`) and
#     every call after it in the file goes unscanned. Right after a genuine
#     heredoc terminator the line ends, or is followed by another redirection
#     or a command separator; right after an arithmetic shift's RHS it is
#     `))`, `)`, `&&`, `||` or `;` from the enclosing expression — reject the
#     match when a `)`/`&`/`|`/`;` (with optional space) follows immediately.
#   - only OUTSIDE quotes: `bin/remote-gate.sh` does
#     `echo "cat > \"\$R/suites\" <<'RG_SUITES'"` — text this file WRITES into
#     a remote script, not a heredoc THIS file opens. quote_span reuses
#     strip_comment's own quote-tracking so a match that starts inside a
#     quoted string is skipped, the same way a `#` inside quotes is not a
#     comment.
#   - `(?![A-Za-z0-9_])` right after the word group, and the trailing
#     lookahead narrowed to `\)` alone (BH-1522 N1). The word group had no
#     right anchor, so when `(?!\s*[)&|;])` rejected a real opener whose
#     terminator is followed by an operator the engine simply BACKTRACKED to a
#     shorter word and matched anyway: `read -r -d '' PREAMBLE <<PRE || true`
#     (bin/box-chat.sh:115) matched with word `PR`, no line is ever bare `PR`,
#     and lines 116-252 of that file were treated as heredoc body — every
#     gh_rest call there went unscanned and the lint read clean. Anchoring the
#     word forces it to be consumed whole; with that in place the `&|;` arm of
#     the lookahead can only ever cause this bug (a real `<<WORD || …`,
#     `<<WORD && …`, `<<WORD; …` opener would be read as no heredoc at all and
#     its body scanned as code), so only `\)` — the arithmetic-shift trap
#     `$(( a << b ))`, still rejected — is left. `$(( a << b && c ))` would now
#     be misread; it occurs nowhere under bin/, and row 5's unterminated-span
#     self-check catches it repo-wide the day it appears.
HEREDOC = re.compile(
    r"(?<!<)<<-?\s*[\"']?([A-Za-z_][A-Za-z0-9_]*)(?![A-Za-z0-9_])[\"']?(?!\s*\))"
)


def strip_comment(line):
    """Drop a trailing comment, but only at a `#` that starts a word outside a
    quoted string. A `#` inside quotes is text; a `#` at column 0 makes the
    whole line a comment."""
    out, quote = [], None
    i, n = 0, len(line)
    while i < n:
        c = line[i]
        if quote:
            if c == quote:
                quote = None
            out.append(c)
        elif c in "\"'":
            quote = c
            out.append(c)
        elif c == "#" and (i == 0 or line[i - 1].isspace()):
            break
        else:
            out.append(c)
        i += 1
    return "".join(out)


def quote_span(line):
    """outside[i] is True when position i is NOT inside a single/double-quoted
    string — the same quote-tracking strip_comment does, exposed per-index so
    a heredoc-opener match can be checked against the position it started at."""
    outside, quote = [], None
    for c in line:
        outside.append(quote is None)
        if quote:
            if c == quote:
                quote = None
        elif c in "\"'":
            quote = c
    return outside


def scan_file(path):
    """Returns (hits, open_span). open_span is None when every heredoc this
    file opened was also terminated, else (openline, word) for the one still
    open at EOF — BH-1522's `--unterminated` mode reports exactly that."""
    hits, body_end, open_at = [], None, None
    try:
        with open(path, "r", errors="replace") as fh:
            lines = fh.readlines()
    except OSError:
        return hits, None
    for num, raw in enumerate(lines, 1):
        line = raw.rstrip("\n")
        if body_end is not None:
            # Inside a heredoc body: the terminator is the word alone on a line
            # (leading whitespace allowed, which is what `<<-` means).
            if line.strip() == body_end:
                body_end = None
            continue
        code = strip_comment(line)
        if CALL.search(code):
            hits.append(num)
        outside = quote_span(code)
        opener = None
        for m in HEREDOC.finditer(code):
            if outside[m.start()]:
                opener = m
                break
        if opener:
            body_end = opener.group(1)
            open_at = num
    return hits, (open_at, body_end) if body_end is not None else None


def walk(root):
    files = []
    for base, _dirs, names in os.walk(root):
        for nm in sorted(names):
            if nm.endswith(".sh"):
                files.append(os.path.join(base, nm))
    return sorted(files)


def main():
    # `--helpers` prints the enumerated status-bearing names, one per line, so
    # tests/gh-rest-helpers-classified.bh-1522-test.sh (BH-1522 N2) reads the
    # tuple from the program itself instead of regex-parsing this source.
    if sys.argv[1] == "--helpers":
        for h in HELPERS:
            print(h)
        return 0 if HELPERS else 2
    mode = "scan"
    argv = sys.argv[1:]
    if argv[0] == "--unterminated":
        mode = "unterminated"
        argv = argv[1:]
    root = argv[0]
    bindir = os.path.join(root, "bin")
    files = walk(bindir) if os.path.isdir(bindir) else []
    if not files:
        sys.stderr.write("gh-rest-no-subshell: nothing to scan under %s\n" % bindir)
        return 2
    found = 0
    for f in files:
        hits, open_span = scan_file(f)
        rel = os.path.relpath(f, root)
        if mode == "unterminated":
            if open_span is not None:
                print("%s:%d:%s" % (rel, open_span[0], open_span[1]))
                found += 1
            continue
        for num in hits:
            print("%s:%d" % (rel, num))
            found += 1
    return 1 if found else 0


sys.exit(main())
PY

run_scan() { python3 "$T/scan.py" "$1"; }   # prints path:line, rc 0/1/2

# ── 1. THE REPO ITSELF, PINNED AT ZERO ──────────────────────────────────────
# This is the assertion the ticket exists for. It fails on today's main with 21
# lines; it must print nothing here.
OUT=$(run_scan "$DIR"); RC=$?
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok
else bad "1: bin/ must have ZERO gh_rest helpers inside a command substitution (rc $RC, $(printf '%s' "$OUT" | grep -c . ) site(s)):
$OUT"
fi

# ── 2. THE LINT CATCHES WHAT IT CLAIMS TO ───────────────────────────────────
# Every shape the 21 converted sites were written in, one file, one expected
# line number each. A lint that cannot be shown failing proves nothing.
cat > "$T/mut/bin/lib/offenders.sh" <<'SH'
#!/bin/bash
st=$(gh_rest_pr_state "$slug" "$num")
body=$( gh_rest GET "repos/$slug/pulls/$n" )
list=`gh_rest_pr_list "$slug" all`
[ "$(gh_rest_issue_state "$slug" "$n")" = open ] && echo yes
printf '%s' "$(gh_rest_pr_state_var x "$slug" "$n")"
SH
OUT=$(run_scan "$T/mut"); RC=$?
[ "$RC" = 1 ] && ok || bad "2: a tree with offenders must exit 1 (got $RC)"
for L in 2 3 4 5 6; do
  grep -qx "bin/lib/offenders.sh:$L" <<<"$OUT" && ok \
    || bad "2: line $L of the fixture must be flagged (got: $OUT)"
done

# ── 3. THE SHAPES THAT ARE NOT OFFENCES ─────────────────────────────────────
# The prescribed call, a comment about the bug, a heredoc that WRITES one, the
# library's own `_gh_rest_*` privates, and a gh_rest_*-NAMED helper that is not
# one of the status-bearing callers (BH-1485 fix round: gh_rest_path_class,
# landed by #1493's ledger after this lint was first written, is exactly this
# shape — bin/lib/gh-rest-ledger.sh:389).
rm -f "$T/mut/bin/lib/offenders.sh"
cat > "$T/mut/bin/lib/clean.sh" <<'SH'
#!/bin/bash
# The bug this replaced was `b=$(gh_rest GET …)` — a comment loses no status.
gh_rest GET "repos/$slug/pulls/$n" > "$t" || rc=$?
gh_rest_pr_state_var st "$slug" "$n" || rc=$?
sf=$(_gh_rest_stfile)
cls=$(gh_rest_path_class "${2:-}")
MSG="a line that says \$(gh_rest GET) inside a string is text"   # still a string
cat > "$out" <<'FIXTURE'
st=$(gh_rest_pr_state a/b 1)
FIXTURE
echo done
SH
OUT=$(run_scan "$T/mut"); RC=$?
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok
else bad "3: the prescribed shapes must NOT be flagged (rc $RC): $OUT"
fi

# ── 3b. THE HEREDOC SKIPPER'S BLIND TAIL (review I1) ────────────────────────
# Each of these three shapes used to be misread as a real heredoc opener, and
# the offending call AFTER it went unscanned because the file was believed to
# still be inside a heredoc body it never actually opened. Each row here pairs
# the trap with a real offender on the next line, so the assertion is "the
# offender is still caught", not just "the tool did not crash".
rm -f "$T/mut/bin/lib/clean.sh"
cat > "$T/mut/bin/lib/herestring.sh" <<'SH'
#!/bin/bash
read -r a <<<word
st=$(gh_rest_pr_state "$slug" "$num")
SH
cat > "$T/mut/bin/lib/arithshift.sh" <<'SH'
#!/bin/bash
n=$(( a << b ))
st=$(gh_rest_pr_state "$slug" "$num")
SH
cat > "$T/mut/bin/lib/quotedecho.sh" <<'SH'
#!/bin/bash
echo "cat > \"\$R/suites\" <<'RG_SUITES'"
echo "RG_SUITES"
st=$(gh_rest_pr_state "$slug" "$num")
SH
OUT=$(run_scan "$T/mut"); RC=$?
[ "$RC" = 1 ] && ok || bad "3b: the three trap fixtures must still exit 1 (got $RC)"
for F in herestring:3 arithshift:3 quotedecho:4; do
  NAME=${F%%:*}; L=${F##*:}
  grep -qx "bin/lib/$NAME.sh:$L" <<<"$OUT" && ok \
    || bad "3b: bin/lib/$NAME.sh:$L (the real offender past the trap) must be flagged (got: $OUT)"
done
rm -f "$T/mut/bin/lib/herestring.sh" "$T/mut/bin/lib/arithshift.sh" "$T/mut/bin/lib/quotedecho.sh"

# ── 3c. THE TERMINATOR WORD MUST BE CONSUMED WHOLE (BH-1522 N1) ─────────────
# `read -r -d '' PREAMBLE <<PRE || true` (bin/box-chat.sh:115) is a REAL
# opener. Before BH-1522 the trailing lookahead rejected `PRE` (a ` ||`
# follows), the engine backtracked to the shorter `PR`, and every line to EOF
# was treated as heredoc body because no line is ever bare `PR` — box-chat.sh
# lines 116-252 went unscanned. Row 3c pairs the shape with an offender AFTER
# the properly-closed heredoc (must be flagged) and a call INSIDE the body
# (must NOT be: the heredoc is still honoured, just terminated correctly).
cat > "$T/mut/bin/lib/readheredoc.sh" <<'SH'
#!/bin/bash
read -r -d '' PREAMBLE <<PRE || true
body=$(gh_rest GET x)
PRE
st=$(gh_rest_pr_state "$slug" "$num")
SH
OUT=$(run_scan "$T/mut"); RC=$?
[ "$RC" = 1 ] && ok || bad "3c: the <<PRE || true fixture's offender must exit 1 (got $RC)"
grep -qx "bin/lib/readheredoc.sh:5" <<<"$OUT" && ok \
  || bad "3c: bin/lib/readheredoc.sh:5 (past the closed heredoc) must be flagged (got: $OUT)"
grep -qx "bin/lib/readheredoc.sh:3" <<<"$OUT" && \
  bad "3c: line 3 is INSIDE the heredoc body and must NOT be flagged (got: $OUT)" || ok
rm -f "$T/mut/bin/lib/readheredoc.sh"

# ── 5. NO FILE ENDS INSIDE AN UNTERMINATED HEREDOC (BH-1522 N1) ─────────────
# The parser's own self-check: if a file's scan ends still believing it is in a
# heredoc body, everything after the opener was skipped and this lint is blind
# there. '--unterminated' reports 'path:openline:WORD'. Against the repo it
# must print nothing; the pre-BH-1522 regex printed 'bin/box-chat.sh:115:PR'.
OUT=$(python3 "$T/scan.py" --unterminated "$DIR"); RC=$?
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok
else bad "5: no bin/**/*.sh may end inside an unterminated heredoc span (rc $RC): $OUT"
fi
cat > "$T/mut/bin/lib/never.sh" <<'SH'
#!/bin/bash
cat <<NEVER
still inside
SH
OUT=$(python3 "$T/scan.py" --unterminated "$T/mut"); RC=$?
[ "$RC" = 1 ] && ok || bad "5: a never-closed heredoc must exit 1 (got $RC)"
grep -qx "bin/lib/never.sh:2:NEVER" <<<"$OUT" && ok \
  || bad "5: bin/lib/never.sh:2:NEVER must be reported (got: $OUT)"
rm -f "$T/mut/bin/lib/never.sh"
OUT=$(python3 "$T/scan.py" --unterminated "$T/empty5" 2>/dev/null); RC=$?
[ "$RC" = 2 ] && ok || bad "5: --unterminated over a tree with nothing to scan must exit 2 (got $RC)"

# ── 4. A SCAN THAT SCANNED NOTHING IS NOT A PASS ────────────────────────────
mkdir -p "$T/empty"
OUT=$(run_scan "$T/empty" 2>/dev/null); RC=$?
[ "$RC" = 2 ] && ok || bad "4: a tree with no bin/**/*.sh must exit 2, never 0 (got $RC)"

echo "gh-rest-no-subshell-lint: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0
