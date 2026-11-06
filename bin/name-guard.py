#!/usr/bin/env python3
"""bin/name-guard.py — the product-board name guard (BH-8918).

Refuses a diff that ADDS a deny term outside an allow-listed path.

  bin/name-guard.py --base <ref> [--repo <dir>] [--lists <dir>]
  bin/name-guard.py --diff-file <file> [--lists <dir>]

LISTS (default <repo>/catalog/name-guard.d, or ./catalog/name-guard.d with
--diff-file). Every *.txt in the dir except allow.txt is a deny file; its stem
(the file name without .txt) names it in the output.
  deny file   one term per line; `#` comment lines; `scope: <glob>` lines limit
              the file to the paths they match (no scope line = every path).
  allow.txt   `<glob> [<stem> ...]`: a bare glob exempts the path from every
              deny file; with stems, only from those deny files.
  Globs match the repo-relative path: `**` is any depth (zero dirs included),
  `*` is one path segment (no `/`), `?` is one char other than `/`.

DIFF. `git diff -M --unified=0 --no-color <base>...HEAD` (committed HEAD only),
or the unified diff in --diff-file. Only added lines count: a removed line, a
context line or a header never hits. New line numbers come from the
`@@ -a,b +c,d @@` headers, the path from `+++ b/<path>`; a deleted file
(`+++ /dev/null`) and a binary file add no lines.
RENAMES. Rename detection is ON (-M), on purpose: with --no-renames a moved
file shows every line as added, so a term on a line nobody changed would hit.
With -M a pure rename shows no hunk and a rename with an edit shows only the
edited lines. The added lines are judged against the NEW path.

MATCH. Case-insensitive and word-bounded. A term becomes its alphanumeric
words (`'`, `@`, `-` and spaces drop). The pattern is
  (^|[^a-z0-9]) w1 [^a-z0-9]* w2 ... (?=[^a-z0-9]|$)
so `_`, `-`, space, apostrophe and nothing at all join the words, and a letter
or digit on either side means a longer word (no hit). Each added line is
judged twice: lowercased as is (so mixed case and ALL CAPS hit), and with
camelCase split first (`([a-z0-9])([A-Z])` -> `\\1 \\2`, so a word that ends at
a case change hits). Either one is a hit.

OUTPUT, one line per hit and term:
  name-guard: <path>:<new line no>: term "<term as listed>" (<deny stem>)
rc 0 clean | 1 hits | 2 usage, a base that does not resolve, an unreadable
diff or lists dir, or no deny file at all. The guard changes no state.
"""
import argparse
import os
import re
import subprocess
import sys

HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")
CAMEL = re.compile(r"([a-z0-9])([A-Z])")


def die2(msg):
    print("name-guard: " + msg, file=sys.stderr)
    sys.exit(2)


def glob_re(glob):
    out, i = [], 0
    while i < len(glob):
        if glob.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif glob.startswith("**", i):
            out.append(".*")
            i += 2
        elif glob[i] == "*":
            out.append("[^/]*")
            i += 1
        elif glob[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(glob[i]))
            i += 1
    return re.compile("".join(out) + r"\Z")


def term_re(term):
    words = re.findall(r"[a-z0-9]+", term.lower())
    if not words:
        return None
    return re.compile(r"(?:^|[^a-z0-9])" + r"[^a-z0-9]*".join(map(re.escape, words)) + r"(?=[^a-z0-9]|$)")


def read_lists(d):
    if not os.path.isdir(d):
        die2("lists dir %s does not exist" % d)
    deny, allow = [], []
    for name in sorted(os.listdir(d)):
        if not name.endswith(".txt"):
            continue
        path = os.path.join(d, name)
        try:
            with open(path, encoding="utf-8") as fh:
                lines = [ln.strip() for ln in fh]
        except OSError as e:
            die2("cannot read %s: %s" % (path, e))
        lines = [ln for ln in lines if ln and not ln.startswith("#")]
        if name == "allow.txt":
            for ln in lines:
                parts = ln.split()
                allow.append((glob_re(parts[0]), set(parts[1:])))
            continue
        stem, scopes, terms = name[:-4], [], []
        for ln in lines:
            if ln.startswith("scope:"):
                scopes.append(glob_re(ln[len("scope:"):].strip()))
            else:
                rx = term_re(ln)
                if rx is not None:
                    terms.append((ln, rx))
        deny.append((stem, scopes, terms))
    if not deny:
        die2("no deny file (*.txt other than allow.txt) in %s" % d)
    return deny, allow


def git_diff(repo, base):
    def git(*a):
        return subprocess.run(["git", "-C", repo, "-c", "core.quotePath=false"] + list(a),
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if git("rev-parse", "--verify", "-q", base + "^{commit}").returncode != 0:
        die2("base '%s' does not resolve to a commit in %s" % (base, repo))
    p = git("diff", "-M", "--unified=0", "--no-color", "--no-ext-diff", base + "...HEAD")
    if p.returncode != 0:
        die2("git diff %s...HEAD failed in %s: %s" % (base, repo, p.stderr.decode("utf-8", "replace").strip()))
    return p.stdout.decode("utf-8", "replace")


def unquote(p):
    if len(p) >= 2 and p[0] == '"' and p[-1] == '"':
        p = p[1:-1].encode("latin-1", "backslashreplace").decode("unicode_escape").encode("latin-1").decode("utf-8", "replace")
    return p


def added_lines(diff):
    """Yield (path, new line no, text) for every added line."""
    path, new_no, left = None, 0, 0
    for raw in diff.split("\n"):
        if left > 0 and path is not None:
            if raw.startswith("+"):
                yield path, new_no, raw[1:]
                new_no += 1
                left -= 1
                continue
            if raw.startswith(" "):
                new_no += 1
                left -= 1
                continue
            if raw.startswith("-") or raw.startswith("\\"):
                continue
        if raw.startswith("diff --git "):
            path, left = None, 0
        elif raw.startswith("+++ "):
            tgt = unquote(raw[4:].rstrip("\t"))
            path = None if tgt == "/dev/null" else (tgt[2:] if tgt.startswith("b/") else tgt)
        elif raw.startswith("@@ "):
            m = HUNK.match(raw)
            if m:
                new_no = int(m.group(1))
                left = int(m.group(2)) if m.group(2) is not None else 1


def main():
    ap = argparse.ArgumentParser(prog="name-guard.py", add_help=True)
    src = ap.add_mutually_exclusive_group()
    src.add_argument("--base")
    src.add_argument("--diff-file")
    ap.add_argument("--repo")
    ap.add_argument("--lists")
    try:
        a = ap.parse_args()
    except SystemExit as e:
        sys.exit(0 if e.code == 0 else 2)
    if not a.base and not a.diff_file:
        die2("usage: --base <ref> [--repo <dir>] | --diff-file <file>; [--lists <dir>]")
    repo = a.repo or "."
    lists = a.lists or os.path.join(repo, "catalog", "name-guard.d")
    deny, allow = read_lists(lists)
    if a.diff_file:
        try:
            with open(a.diff_file, encoding="utf-8", errors="replace") as fh:
                diff = fh.read()
        except OSError as e:
            die2("cannot read %s: %s" % (a.diff_file, e))
    else:
        diff = git_diff(repo, a.base)

    hits = 0
    for path, no, text in added_lines(diff):
        exempt = set()
        whole = False
        for rx, stems in allow:
            if rx.match(path):
                if stems:
                    exempt |= stems
                else:
                    whole = True
        if whole:
            continue
        forms = (text.lower(), CAMEL.sub(r"\1 \2", text).lower())
        for stem, scopes, terms in deny:
            if stem in exempt:
                continue
            if scopes and not any(s.match(path) for s in scopes):
                continue
            for term, rx in terms:
                if any(rx.search(f) for f in forms):
                    print('name-guard: %s:%d: term "%s" (%s)' % (path, no, term, stem))
                    hits += 1
    sys.exit(1 if hits else 0)


if __name__ == "__main__":
    main()
