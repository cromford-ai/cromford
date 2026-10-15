#!/bin/bash
# bin/sql-ident-lint.sh [--root DIR] [--baseline DIR] [--print | --print-baseline] [FILE...]
#
# The SQL identifier ratchet (BH-6514). D1 binds values, not names, so a table
# or a column name goes into the SQL text. A SITE is a `prepare(` call whose
# first argument builds that text at run time: it holds a template literal
# with `${`, or it joins with a depth-0 `+` at least one operand that is not a
# literal. A site is MARKED when a `//` comment on its line, or in the run of
# comment-only `//` lines that ends directly above it, holds the sql-ident
# marker (--help prints its exact form) followed by a reason with a
# word of 3+ letters. The reason names where the text comes from.
#
# Scope: `git ls-files 'worker/*/src/*.js' 'worker/*/src/**/*.js'` under the
# root, or only the FILE args (paths relative to the root). Not seen: SQL
# built in a variable and passed by name (`prepare(sql)`).
#
# Baseline: <baseline>/<path with / as __>.count.txt, one decimal integer, the
# number of UNMARKED sites that file may keep. A file with no fragment keeps 0.
# Sites over the count are named `<path>:<line>` (the last ones by line: the
# ratchet cannot tell an old site from a new one). A NOTE (never red) names a
# count above the unmarked sites, or a fragment whose source file is gone.
# With FILE args, fragments of other files are ignored.
#
#   --root DIR       the git work tree to scan (default: this script's repo)
#   --baseline DIR   the fragments (default: <root>/tests/fixtures/sql-ident-baseline)
#   --print          before the summary, one line per site:
#                    <path>:<line>\t<marked|unmarked>\t<first argument, cut to 160>
#   --print-baseline print only `<fragment>\t<unmarked count>` per file with 1+
#                    unmarked sites, and exit 0; existing fragments are ignored
#
# The last stdout line (rc 0 and 1) is:
#   sql-ident-lint: <n> sites in <f> files, <m> marked, <u> unmarked, <b> within baseline, <r> over
# (<f> counts the files with 1+ sites.)
#   rc 0 no site over the baseline
#   rc 1 1+ sites over the baseline
#   rc 2 bad arguments, root not a git work tree, no python3, a file that does
#        not parse, a missing FILE, or a bad fragment (named on stderr)
#
# Regenerate the baseline (never hand-write a fragment), from the repo root:
#   B=tests/fixtures/sql-ident-baseline; rm -f "${B:?}"/*.count.txt; mkdir -p "$B"
#   bin/sql-ident-lint.sh --print-baseline | while IFS=$'\t' read -r f n; do printf '%s\n' "$n" > "$B/$f"; done
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BASELINE=""; MODE=check
FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:-}"; [ -n "$ROOT" ] || { echo "sql-ident-lint: --root needs a directory" >&2; exit 2; }; shift 2 ;;
    --baseline) BASELINE="${2:-}"; [ -n "$BASELINE" ] || { echo "sql-ident-lint: --baseline needs a directory" >&2; exit 2; }; shift 2 ;;
    --print) [ "$MODE" = check ] || { echo "sql-ident-lint: --print and --print-baseline exclude each other" >&2; exit 2; }; MODE=print; shift ;;
    --print-baseline) [ "$MODE" = check ] || { echo "sql-ident-lint: --print and --print-baseline exclude each other" >&2; exit 2; }; MODE=baseline; shift ;;
    -h|--help)
      mk="sql-ident""-ok:"
      sed -n '2,41p' "$0" | sed 's/^# \{0,1\}//'
      printf '\nThe marker: // %s <source of the name>\n' "$mk"
      exit 0 ;;
    --) shift; FILES+=("$@"); break ;;
    -*) echo "sql-ident-lint: unknown argument $1" >&2; exit 2 ;;
    *) FILES+=("$1"); shift ;;
  esac
done

command -v python3 >/dev/null 2>&1 || { echo "sql-ident-lint: python3 not found" >&2; exit 2; }
[ -d "$ROOT" ] && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "sql-ident-lint: --root $ROOT is not a git work tree" >&2; exit 2; }
ROOT=$(cd "$ROOT" && pwd)
[ -n "$BASELINE" ] || BASELINE="$ROOT/tests/fixtures/sql-ident-baseline"

LIST=$(mktemp) || { echo "sql-ident-lint: cannot make a temp file" >&2; exit 2; }
trap 'rm -f "$LIST"' EXIT
if [ "${#FILES[@]}" -gt 0 ]; then
  printf '%s\n' "${FILES[@]}" > "$LIST"
  SCOPE=args
else
  git -C "$ROOT" ls-files -- 'worker/*/src/*.js' 'worker/*/src/**/*.js' > "$LIST" \
    || { echo "sql-ident-lint: git ls-files failed in $ROOT" >&2; exit 2; }
  SCOPE=tree
fi

python3 -I - "$ROOT" "$BASELINE" "$MODE" "$SCOPE" "$LIST" <<'PY'
import os, re, sys

root, baseline, mode, scope, listfile = sys.argv[1:6]
MARK = re.compile(r"sql-ident-o[k]:(.*)")
REASON = re.compile(r"[A-Za-z]{3}")
REGEX_AFTER_PUNCT = set("(,=:[!&|?{};+-*%<>~^")
REGEX_AFTER_WORD = {"return", "typeof", "case", "in", "of", "void", "delete", "throw", "new",
                    "else", "do", "yield", "await", "instanceof"}
ID_START = re.compile(r"[A-Za-z_$]")
ID_CHAR = re.compile(r"[A-Za-z0-9_$]")


class ParseError(Exception):
    pass


class Lexer:
    """One pass over a JS file: tokens per code region, // comments by line."""

    def __init__(self, src):
        self.s = src
        self.n = len(src)
        self.nl = [i for i, c in enumerate(src) if c == "\n"]
        self.regions = []          # one token list per code region (top level + each ${ })
        self.line_comments = {}    # line -> [comment text]
        self.code_lines = set()    # lines that hold a non-comment token
        self.block_lines = set()   # lines that hold a block comment

    def line(self, i):
        lo, hi = 0, len(self.nl)
        while lo < hi:
            mid = (lo + hi) // 2
            if self.nl[mid] < i:
                lo = mid + 1
            else:
                hi = mid
        return lo + 1

    def add(self, toks, kind, val, a, b, interp=False):
        toks.append((kind, val, a, b, interp))
        for ln in range(self.line(a), self.line(max(a, b - 1)) + 1):
            self.code_lines.add(ln)

    def code(self, i, nested):
        """Lex code from i. nested: the start of the template whose `${` this closes, or None."""
        s, n = self.s, self.n
        toks = []
        self.regions.append(toks)
        depth = 0
        while i < n:
            c = s[i]
            if c in " \t\r\n\f\v":
                i += 1
            elif s.startswith("//", i):
                j = s.find("\n", i)
                j = n if j < 0 else j
                self.line_comments.setdefault(self.line(i), []).append(s[i + 2:j])
                i = j
            elif s.startswith("/*", i):
                j = s.find("*/", i + 2)
                if j < 0:
                    raise ParseError("unterminated block comment from line %d" % self.line(i))
                for ln in range(self.line(i), self.line(j) + 1):
                    self.block_lines.add(ln)
                i = j + 2
            elif c in "'\"":
                i = self.string(toks, i, c)
            elif c == "`":
                i = self.template(toks, i)
            elif c == "/" and self.regex_ok(toks):
                i = self.regex(toks, i)
            elif ID_START.match(c):
                j = i + 1
                while j < n and ID_CHAR.match(s[j]):
                    j += 1
                self.add(toks, "id", s[i:j], i, j)
                i = j
            elif c.isdigit() or (c == "." and i + 1 < n and s[i + 1].isdigit()):
                j = i + 1
                while j < n and (s[j].isalnum() or s[j] in "._"):
                    j += 1
                self.add(toks, "num", s[i:j], i, j)
                i = j
            else:
                if nested is not None and c == "}" and depth == 0:
                    return i + 1
                if c == "{":
                    depth += 1
                elif c == "}":
                    depth -= 1
                self.add(toks, "p", c, i, i + 1)
                i += 1
        if nested is not None:
            raise ParseError("unterminated template from line %d" % self.line(nested))
        return i

    def regex_ok(self, toks):
        if not toks:
            return True
        kind, val = toks[-1][0], toks[-1][1]
        if kind == "p":
            return val in REGEX_AFTER_PUNCT
        return kind == "id" and val in REGEX_AFTER_WORD

    def string(self, toks, i, q):
        s, n, j = self.s, self.n, i + 1
        while j < n:
            if s[j] == "\\":
                j += 2
            elif s[j] == q:
                self.add(toks, "str", s[i:j + 1], i, j + 1)
                return j + 1
            elif s[j] == "\n":
                break
            else:
                j += 1
        raise ParseError("unterminated string from line %d" % self.line(i))

    def template(self, toks, i):
        s, n, j = self.s, self.n, i + 1
        interp = False
        while j < n:
            if s[j] == "\\":
                j += 2
            elif s[j] == "`":
                self.add(toks, "tmpl", s[i:j + 1], i, j + 1, interp)
                return j + 1
            elif s.startswith("${", j):
                interp = True
                j = self.code(j + 2, i)
            else:
                j += 1
        raise ParseError("unterminated template from line %d" % self.line(i))

    def regex(self, toks, i):
        s, n, j = self.s, self.n, i + 1
        cls = False
        while j < n:
            c = s[j]
            if c == "\\":
                j += 2
                continue
            if c == "\n":
                break
            if cls:
                cls = c != "]"
            elif c == "[":
                cls = True
            elif c == "/":
                j += 1
                while j < n and ID_CHAR.match(s[j]):
                    j += 1
                self.add(toks, "re", s[i:j], i, j)
                return j
            j += 1
        raise ParseError("unterminated regex from line %d" % self.line(i))


def literal(op):
    return len(op) == 1 and (op[0][0] in ("str", "num") or (op[0][0] == "tmpl" and not op[0][4]))


def sites_of(lx):
    out = []
    for toks in lx.regions:
        for k, t in enumerate(toks):
            if t[0] != "id" or t[1] != "prepare" or k + 1 >= len(toks) or toks[k + 1][:2] != ("p", "("):
                continue
            depth, arg, m = 0, [], k + 2
            while m < len(toks):
                kind, val = toks[m][0], toks[m][1]
                if kind == "p" and val in "([{":
                    depth += 1
                elif kind == "p" and val in ")]}":
                    if depth == 0:
                        break
                    depth -= 1
                elif kind == "p" and val == "," and depth == 0:
                    break
                arg.append(toks[m])
                m += 1
            if not arg:
                continue
            hit = any(a[0] == "tmpl" and a[4] for a in arg)
            if not hit:
                ops, cur, d = [], [], 0
                for a in arg:
                    if a[0] == "p" and a[1] in "([{":
                        d += 1
                    elif a[0] == "p" and a[1] in ")]}":
                        d -= 1
                    if a[0] == "p" and a[1] == "+" and d == 0:
                        ops.append(cur)
                        cur = []
                    else:
                        cur.append(a)
                ops.append(cur)
                hit = len(ops) > 1 and not all(literal(o) for o in ops)
            if hit:
                text = " ".join(lx.s[arg[0][2]:arg[-1][3]].split())[:160]
                out.append((lx.line(t[2]), text))
    return out


def marked(lx, ln):
    def has(line):
        for c in lx.line_comments.get(line, []):
            m = MARK.search(c)
            if m and REASON.search(m.group(1)):
                return True
        return False
    if has(ln):
        return True
    up = ln - 1
    while up >= 1 and up in lx.line_comments and up not in lx.code_lines and up not in lx.block_lines:
        if has(up):
            return True
        up -= 1
    return False


def frag(path):
    return path.replace("/", "__") + ".count.txt"


def die(msg):
    sys.stderr.write("sql-ident-lint: %s\n" % msg)
    sys.exit(2)


with open(listfile, encoding="utf-8") as fh:
    paths = sorted({p.strip() for p in fh if p.strip()})

results = {}
for p in paths:
    full = os.path.join(root, p)
    if not os.path.isfile(full):
        if scope == "args":
            die("no such file %s" % p)
        continue
    try:
        with open(full, encoding="utf-8") as fh:
            src = fh.read()
    except (OSError, UnicodeDecodeError) as e:
        die("cannot read %s: %s" % (p, e))
    lx = Lexer(src)
    try:
        lx.code(0, None)
    except ParseError as e:
        die("cannot parse %s: %s" % (p, e))
    rows = sorted((ln, marked(lx, ln), text) for ln, text in sites_of(lx))
    if rows:
        results[p] = rows

if mode == "baseline":
    for name, n in sorted((frag(p), sum(1 for r in rows if not r[1])) for p, rows in results.items()):
        if n:
            print("%s\t%d" % (name, n))
    sys.exit(0)

counts = {}
if os.path.isdir(baseline):
    for name in sorted(os.listdir(baseline)):
        if not name.endswith(".count.txt"):
            continue
        try:
            with open(os.path.join(baseline, name), encoding="utf-8") as fh:
                body = fh.read()
        except (OSError, UnicodeDecodeError):
            die("bad fragment %s" % name)
        if not re.fullmatch(r"[0-9]+\n?", body):
            die("bad fragment %s" % name)
        counts[name] = int(body)

by_frag = {frag(p): p for p in paths}
notes, over_lines = [], []
n_sites = n_marked = n_unmarked = n_within = n_over = 0
for name in sorted(counts):
    if name not in by_frag:
        if scope == "tree":
            gone = name[:-len(".count.txt")].replace("__", "/")
            notes.append("NOTE %s: source file %s is gone; delete the fragment" % (name, gone))
        continue
    u = sum(1 for r in results.get(by_frag[name], []) if not r[1])
    if counts[name] > u:
        notes.append("NOTE %s: count %d is above the %d unmarked sites; regenerate the baseline" % (name, counts[name], u))
for p in sorted(results):
    rows = results[p]
    unmarked = [r for r in rows if not r[1]]
    allowed = counts.get(frag(p), 0)
    within = min(len(unmarked), allowed)
    n_sites += len(rows)
    n_marked += len(rows) - len(unmarked)
    n_unmarked += len(unmarked)
    n_within += within
    n_over += len(unmarked) - within
    for r in unmarked[within:]:
        over_lines.append("%s:%d: unmarked SQL text built at run time (add a sql-ident marker with its source, or fix the SQL)" % (p, r[0]))

if mode == "print":
    for p in sorted(results):
        for ln, mk, text in results[p]:
            print("%s:%d\t%s\t%s" % (p, ln, "marked" if mk else "unmarked", text))
for line in notes + over_lines:
    print(line)
print("sql-ident-lint: %d sites in %d files, %d marked, %d unmarked, %d within baseline, %d over"
      % (n_sites, len(results), n_marked, n_unmarked, n_within, n_over))
sys.exit(1 if n_over else 0)
PY
