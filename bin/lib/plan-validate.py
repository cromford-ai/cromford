#!/usr/bin/env python3
"""bin/lib/plan-validate.py — the evaluator of the plan-validate self-check rule
(bin/lib/pr-self-check-validate.sh, BH-7072). Run as `python3 -I`.

  plan-validate.py --repo DIR --head SHA --plan-path PATH --body FILE
                   [--approvals FILE] [--max N]

Reads the plan at <head>:<plan-path>, finds each task's colon-anchored
VALIDATE line (outside fences and the contract sections the plan gate skips),
and runs the STATIC ones against the head tree and the PR body. It also reads
the body for a "not met" line and for a missed `Target metric:`.

NO SHELL, EVER. Plan text is model-written from untrusted ticket input, so no
VALIDATE text reaches a shell. A file test is a `git cat-file` read. A grep is
the real grep binary, run as an argv list with -e before each pattern and `--`
before the files, on private temp copies of the head blobs. Any other shape is
SKIP: test suites, pipes, `$`, `;`, `&&`, redirects and prose.

Output, one tab-separated line each:
  NONE                                 the plan has no VALIDATE line: judge nothing
  OK      <id> <cmd>                   a static check that passed
  FAIL    <id> <cmd> <expect> <actual> <owed 0|1>
  OWED    <id> <login>                 a failed check excused by an approved owed: line
  SKIP    <id>                         a VALIDATE line with no static check
  CAP     <n> <max>                    VALIDATE lines past the cap, not read
  NOTMET  <line>                       a body line that says not met
  TARGET  <target> <measured>          a Target metric the measured number misses
  INFO    <text>                       a note (no measured number, no direction)
  EXCUSED <login>                      body findings excused by an approved owed: line
  NEEDAPPROVAL                         a finding exists, the body has an owed: line,
                                       and no --approvals file was given
Exit 0 when it judged; 2 on a bad argument or a plan that will not read.

--approvals: one `<login>\t<comment line>` row per line, already filtered to
operators by the caller. An approval line is `approve owed: <id>` or
`owed <id> approved` (case-insensitive).
"""
import argparse
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

GREP_TIMEOUT_S = float(os.environ.get("PLAN_VALIDATE_GREP_TIMEOUT_S") or 10)
BLOB_MAX = int(os.environ.get("PLAN_VALIDATE_BLOB_MAX") or 2 * 1024 * 1024)

SKIP_SECTIONS = re.compile(
    r"^(system invariants|requirements coverage|acceptance tests|qa screens|verification"
    r"|shared files|spec changes from comments|verify \(run, not edited\))"
)
VALIDATE_RE = re.compile(
    r"^\s*(?:(?:[-*+]|\d+[.)])\s+)?(?:\*\*)?VALIDATE(?:\*\*)?\s*:(?:\*\*)?\s*(.*)$"
)
NUM = r"-?\d+(?:\.\d+)?"
CMP_RE = re.compile(
    r"^\s*(?:(?:returns?|prints?|outputs?|gives?|is)\s+)?(>=|<=|==|!=|=|<|>|-ge|-le|-eq|-ne|-lt|-gt)\s*(\d+)\b"
)
CMP_TAIL_RE = re.compile(r"\s+(>=|<=|==|!=|=|<|>|-ge|-le|-eq|-ne|-lt|-gt)\s*(\d+)\s*$")
BODY_SENTINEL = "\x00BODY\x00"


def git(repo, *args, binary=False):
    p = subprocess.run(["git", "-C", repo, *args], capture_output=True, timeout=30)
    if p.returncode != 0:
        return None
    return p.stdout if binary else p.stdout.decode("utf-8", "replace")


def strip_label(s):
    s = s.strip()
    s = re.sub(r"^#+\s*", "", s)
    s = re.sub(r"^(?:[-*+]|\d+[.)])\s+", "", s)
    s = re.sub(r"^\*\*", "", s)
    return s.strip()


def task_id(label):
    """The plan gate's designator: `Task 3` / `T3` -> T3, else None."""
    t = strip_label(label).lower()
    m = re.match(r"^task\s*(\d+)\s*(?:[^0-9a-z ]|$)", t) or re.match(r"^t(\d+)\s*(?:[^0-9a-z ]|$)", t)
    return "T" + m.group(1) if m else None


def validate_lines(plan_text):
    """[(task id, line number, text after the colon, raw line)], in plan order.
    The block walk is bin/plan-gate.sh's: fences skipped whole, the contract
    sections skipped to the next heading at their level, a deeper heading inside
    a task heading stays in the task, a top-level list item opens a block."""
    out = []
    fence = False
    skiplvl = 0
    cur = None          # the open block's task id (None = not a labelled task)
    headtask = False
    tasklvl = 0
    for n, line in enumerate(plan_text.split("\n"), 1):
        line = line.rstrip("\r")
        if re.match(r"^\s*(```|~~~)", line):
            fence = not fence
            continue
        if fence:
            continue
        hm = re.match(r"^(#+)[ \t]", line)
        lvl = len(hm.group(1)) if hm else 0
        if skiplvl:
            if hm and lvl <= skiplvl:
                skiplvl = 0
            else:
                continue
        if hm:
            if headtask and lvl > tasklvl:
                continue
            if SKIP_SECTIONS.match(strip_label(line).lower()):
                skiplvl = lvl
                cur, headtask, tasklvl = None, False, 0
                continue
            cur = task_id(line)
            headtask = cur is not None
            tasklvl = lvl if headtask else 0
            continue
        vm = VALIDATE_RE.match(line)
        if vm:
            out.append((cur or "L%d" % n, n, vm.group(1).strip(), line))
            continue
        if not headtask and re.match(r"^ ?(?:[-*]|\d+[.)])[ \t]+", line):
            cur = task_id(line)
    return out


WORDNUM = {"zero": 0, "no": 0, "one": 1, "a single": 1, "two": 2, "three": 3, "four": 4,
           "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10}
VERB = r"(?:prints?|returns?|outputs?|shows?|gives?|finds?|counts?|reports?|equals?|is|are|stays?)"


def expectation(after):
    """What the words right after a command expect (up to the next span):
    ('cmp', op, n, each) | ('ret', n, each) | ('nomatch',) | ('exit', n) |
    ('default',) when nothing is said | ('unknown',) for prose this cannot read.
    The forms are the ones the spec plans on main use most: `prints 0`,
    `prints nothing`, `is empty`, `finds nothing`, `prints 1`, `exits 0`,
    `is at least 3`, `prints one line`, a comparator."""
    t = after.split("`", 1)[0].strip()
    t = re.sub(r"^\([^)]*\)\s*", "", t)
    t = re.sub(r"^[:\u2014\u2013-]+\s*", "", t)
    while True:
        u = re.sub(r"^(?:must|should|which|that|then|still|now)\s+", "", t, flags=re.I)
        if u == t:
            break
        t = u
    low = t.lower()
    each = re.search(r"^\S+(?:\s+\S+){0,4}?\s+(?:for|in)\s+(?:each|both|every)\b", low) is not None
    m = CMP_RE.match(t)
    if m:
        return ("cmp", m.group(1), int(m.group(2)), each)
    if re.match(VERB + r"\s+(?:nothing|empty|no\s+(?:output|lines?|match(?:es)?|hits?|rows?|results?))\b", low) \
            or re.match(r"no\s+(?:output|match(?:es)?|hits?)\b", low):
        return ("nomatch",)
    m = re.match(r"exits?\s+(?:with\s+)?(?:code\s+|status\s+)?(\d+)\b", low)
    if m:
        return ("exit", int(m.group(1)))
    m = re.match(r"(?:is|are)\s+at\s+(least|most)\s+(\d+)\b", low)
    if m:
        return ("cmp", ">=" if m.group(1) == "least" else "<=", int(m.group(2)), each)
    m = re.match(VERB + r"\s+(?:exactly\s+)?(\d+|zero|one|two|three|four|five|six|seven|eight|nine|ten|a single)\b"
                 r"(?:\s+or\s+(more|fewer|less|\S+))?", low)
    if m:
        n = int(m.group(1)) if m.group(1).isdigit() else WORDNUM[m.group(1)]
        if m.group(2) in ("more",):
            return ("cmp", ">=", n, each)
        if m.group(2) in ("fewer", "less"):
            return ("cmp", "<=", n, each)
        if m.group(2):
            return ("unknown",)
        if low.startswith("return"):
            return ("ret", n, each)
        return ("cmp", "==", n, each)
    if re.match(VERB + r"\s+(?:a|the|one or more|at least one)\s+(?:line|match|hit)", low):
        return ("cmp", ">=", 1, False)
    if re.match(r"^(?:[,;.]|and\b|or\b|$)", low):
        return ("default",)
    return ("unknown",)


def candidates(text):
    """The commands of one VALIDATE line: (cmd, expectation). Every backtick
    span, each with a comparator inside its tail or the words right after it;
    with no span, the whole text after the colon."""
    spans = list(re.finditer(r"`([^`]+)`", text))
    res = [(s.group(1).strip(), expectation(text[s.end():])) for s in spans] if spans \
        else [(text.strip(), ("default",))]
    out = []
    for cmd, exp in res:
        tm = CMP_TAIL_RE.search(cmd)
        if tm:
            cmd = cmd[:tm.start()].rstrip()
            if exp[0] in ("default", "unknown"):
                exp = ("cmp", tm.group(1), int(tm.group(2)), False)
        out.append((cmd, exp))
    return out


def body_alias(cmd, mentions_body, plan_path):
    """Swap every PR-body target for the sentinel, before the metachar scan."""
    cmd = re.sub(r"<\s*pr[ _-]?body\s*>", BODY_SENTINEL, cmd, flags=re.I)
    cmd = re.sub(r"""(?<![^\s'"])["']?[^\s'"]*["']?pr-body\.md(?![^\s'"])""", BODY_SENTINEL, cmd)
    cmd = re.sub(r"(?<!\S)PR-body(?!\S)", BODY_SENTINEL, cmd, flags=re.I)
    if mentions_body and plan_path:
        cmd = re.sub(r"(?<!\S)(?:\./)?" + re.escape(plan_path) + r"(?!\S)", BODY_SENTINEL, cmd)
    return cmd


def unsafe(cmd):
    """True when the text holds a shell construct outside single quotes."""
    q = None
    i = 0
    while i < len(cmd):
        c = cmd[i]
        if q == "'":
            if c == "'":
                q = None
        elif c == "\\":
            i += 1
        elif c == "'" and q is None:
            q = "'"
        elif c == '"':
            q = None if q == '"' else '"'
        elif c in "$`":
            return True
        elif q is None and c in ";&|<>(){}\n":
            return True
        i += 1
    return q is not None


def safe_path(p):
    if not p or "\x00" in p or p.startswith("/") or p.startswith("-"):
        return None
    p = re.sub(r"^(\./)+", "", p).rstrip("/")
    if not p or any(seg == ".." for seg in p.split("/")):
        return None
    if re.search(r"[*?\[\]~]", p):
        return None
    return p


GREP_FLAGS = set("cqnEFiwxsh")


def parse_grep(tokens):
    """grep [flags] PAT FILE... -> (flags, patterns, files) or None."""
    flags, pats, files = set(), [], []
    i, endopts = 0, False
    while i < len(tokens):
        t = tokens[i]
        if not endopts and t == "--":
            endopts = True
        elif not endopts and t.startswith("-") and len(t) > 1:
            if t.startswith("--"):
                return None
            body = t[1:]
            for j, ch in enumerate(body):
                if ch == "e":
                    rest = body[j + 1:]
                    if rest:
                        pats.append(rest)
                    else:
                        i += 1
                        if i >= len(tokens):
                            return None
                        pats.append(tokens[i])
                    break
                if ch not in GREP_FLAGS:
                    return None
                flags.add(ch)
        elif not pats:
            pats.append(t)
        else:
            files.append(t)
        i += 1
    return (flags, pats, files) if pats else None


def parse(cmd, mentions_body, plan_path):
    """A static shape: ('file', op, neg, path) | ('ls', path) |
    ('grep', neg, flags, pats, files) — files may hold BODY_SENTINEL — or None."""
    cmd = body_alias(cmd, mentions_body, plan_path)
    piped_body = False
    m = re.match(r"^gh\s+pr\s+view\b([^|]*)\|\s*(grep\b.*)$", cmd)
    if m and "body" in m.group(1) and not unsafe(m.group(1).replace("'", "").replace('"', "")) \
            and not unsafe(m.group(2)):
        cmd, piped_body = m.group(2), True
    if unsafe(cmd.replace(BODY_SENTINEL, "B")):
        return None
    try:
        tok = shlex.split(cmd, posix=True)
    except ValueError:
        return None
    if not tok:
        return None
    neg = False
    if tok[0] == "!":
        neg, tok = True, tok[1:]
    if not tok:
        return None
    if tok[0] == "[" and tok[-1] == "]":
        tok = ["test"] + tok[1:-1]
    if tok[0] == "test":
        args = tok[1:]
        if args and args[0] == "!":
            neg, args = not neg, args[1:]
        if len(args) != 2 or args[0] not in ("-f", "-e", "-s", "-d"):
            return None
        p = safe_path(args[1])
        return ("file", args[0], neg, p) if p and BODY_SENTINEL not in p else None
    if tok[0] == "ls" and len(tok) == 2 and not neg:
        p = safe_path(tok[1])
        return ("ls", p) if p and BODY_SENTINEL not in p else None
    if tok[0] == "grep":
        g = parse_grep(tok[1:])
        if not g:
            return None
        flags, pats, files = g
        if piped_body:
            if files:
                return None
            files = [BODY_SENTINEL]
        if not files:
            return None
        clean = []
        for f in files:
            if f == BODY_SENTINEL:
                clean.append(f)
                continue
            p = safe_path(f)
            if not p:
                return None
            clean.append(p)
        return ("grep", neg, flags, pats, clean)
    return None


def compare(n, cmp):
    op, v = cmp
    return {
        ">=": n >= v, "-ge": n >= v, "<=": n <= v, "-le": n <= v,
        "==": n == v, "=": n == v, "-eq": n == v, "!=": n != v, "-ne": n != v,
        "<": n < v, "-lt": n < v, ">": n > v, "-gt": n > v,
    }[op]


class Head:
    def __init__(self, repo, head, tmp, body_file):
        self.repo, self.head, self.tmp, self.body = repo, head, tmp, body_file
        self.cache = {}

    def kind(self, path):
        t = git(self.repo, "cat-file", "-t", "%s:%s" % (self.head, path))
        return t.strip() if t else None

    def ignored(self, path):
        """A path the repo git-ignores (a generated file is never at the head)."""
        p = subprocess.run(["git", "-C", self.repo, "check-ignore", "-q", "--no-index", "--", path],
                           capture_output=True, timeout=30)
        return p.returncode == 0

    def size(self, path):
        s = git(self.repo, "cat-file", "-s", "%s:%s" % (self.head, path))
        return int(s.strip()) if s and s.strip().isdigit() else None

    def file(self, path):
        """A temp copy of the head blob: (file, None) or (None, why)."""
        if path == BODY_SENTINEL:
            return self.body, None
        if path in self.cache:
            return self.cache[path]
        k = self.kind(path)
        if k is None and self.ignored(path):
            r = (None, "skip")
        elif k != "blob":
            r = (None, "missing at head" if k is None else "a %s at head" % k)
        elif (self.size(path) or 0) > BLOB_MAX:
            r = (None, "skip")
        else:
            data = git(self.repo, "show", "%s:%s" % (self.head, path), binary=True)
            if data is None:
                r = (None, "missing at head")
            else:
                f = os.path.join(self.tmp, "b%d" % len(self.cache))
                with open(f, "wb") as fh:
                    fh.write(data)
                r = (f, None)
        self.cache[path] = r
        return r


def run_grep(argv):
    try:
        p = subprocess.run(argv, capture_output=True, timeout=GREP_TIMEOUT_S,
                           env={"LC_ALL": "C", "PATH": os.environ.get("PATH", "/usr/bin:/bin")})
        return p.returncode, p.stdout.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        return None, ""


def evaluate(shape, exp, head, grep_bin):
    """(verdict, expect, actual): verdict ok | fail | skip."""
    if shape[0] in ("file", "ls"):
        if exp[0] == "exit" and exp[1] not in (0, 1) or exp[0] in ("cmp", "ret", "nomatch"):
            return "skip", "", "a file test with a count"
        flip = exp[0] == "exit" and exp[1] == 1
    if shape[0] == "file":
        _, op, neg, p = shape
        neg = neg != flip
        k = head.kind(p)
        if k is None and head.ignored(p):
            return "skip", "", "git-ignored"
        if op == "-f":
            good = k == "blob"
        elif op == "-d":
            good = k == "tree"
        elif op == "-e":
            good = k is not None
        else:
            good = k == "blob" and (head.size(p) or 0) > 0
        actual = "missing at head" if k is None else ("a %s at head" % k if not good or neg else "present")
        if op == "-s" and k == "blob" and not good:
            actual = "empty at head"
        if neg:
            good = not good
            actual = "present at head" if not good else actual
        return ("ok" if good else "fail"), ("absent" if neg else "test %s" % op), actual
    if shape[0] == "ls":
        k = head.kind(shape[1])
        if k is None and head.ignored(shape[1]):
            return "skip", "", "git-ignored"
        good = (k is not None) != flip
        return ("ok" if good else "fail"), ("absent" if flip else "exists"), ("missing at head" if not k else "present")
    _, neg, flags, pats, files = shape
    kind = exp[0]
    if kind == "unknown":
        return "skip", "", "an expectation this cannot read"
    if kind == "ret":
        exp = ("cmp", "==", exp[1], exp[2]) if "c" in flags else ("exit", exp[1])
        kind = exp[0]
    if kind == "exit" and exp[1] not in (0, 1):
        return "skip", "", "grep exit %d asked" % exp[1]
    keep = [f for f in "EFiwx" if f in flags]
    paths = []
    for f in files:
        tf, why = head.file(f)
        if why == "skip":
            return "skip", "", "a blob over the size cap, or git-ignored"
        if tf is None:
            return "fail", "a readable file", "%s: %s" % (f, why)
        paths.append(tf)
    pargs = []
    for p in pats:
        pargs += ["-e", p]

    def counts():
        res = []
        for tf in paths:
            rc, out = run_grep([grep_bin, "-c"] + ["-" + f for f in keep] + pargs + ["--", tf])
            if rc is None:
                return None, "grep timed out"
            if rc not in (0, 1):
                return None, "grep exit %d" % rc
            res.append(int((out.strip() or "0").split("\n")[-1]))
        return res, None

    if kind == "cmp":
        cmp = (exp[1], exp[2])
        cs, err = counts()
        if cs is None:
            return ("skip" if err == "grep timed out" else "fail"), "count %s %d" % cmp, err
        each = exp[3] and len(cs) > 1
        good = all(compare(c, cmp) for c in cs) if each else compare(sum(cs), cmp)
        if neg:
            good = not good
        actual = ", ".join("%s: %d" % (f, c) for f, c in zip(files, cs)) if each else str(sum(cs))
        actual = actual.replace(BODY_SENTINEL, "<PR body>")
        return ("ok" if good else "fail"), "count %s %d%s" % (cmp[0], cmp[1], " in each file" if each else ""), actual
    want = not (kind == "nomatch" or (kind == "exit" and exp[1] == 1))
    if neg:
        want = not want
    rc, _ = run_grep([grep_bin, "-q"] + ["-" + f for f in keep] + pargs + ["--"] + paths)
    if rc is None:
        return "skip", "", "grep timed out"
    if rc not in (0, 1):
        return "fail", ("a match" if want else "no match"), "grep exit %d" % rc
    good = (rc == 0) == want
    actual = "no match"
    if rc == 0:
        cs, _ = counts()
        actual = "%d matching line(s)" % sum(cs) if cs is not None else "a match"
    return ("ok" if good else "fail"), ("a match" if want else "no match"), actual


# ── the body ────────────────────────────────────────────────────────────────

def body_lines(text):
    """(line number, cleaned line, raw line) outside fences and outside a
    `## Pre-open check` section; inline code and double-quoted text removed."""
    out = []
    fence = False
    skiplvl = 0
    for n, raw in enumerate(text.split("\n"), 1):
        raw = raw.rstrip("\r")
        if re.match(r"^\s*(```|~~~)", raw):
            fence = not fence
            continue
        if fence:
            continue
        hm = re.match(r"^(#+)[ \t]", raw)
        if skiplvl and hm and len(hm.group(1)) <= skiplvl:
            skiplvl = 0
        if skiplvl:
            continue
        if hm and re.match(r"^#+\s+pre-open check", raw, re.I):
            skiplvl = len(hm.group(1))
            continue
        clean = re.sub(r"`[^`]*`", " ", raw)
        clean = re.sub(r'"[^"]*"', " ", clean)
        clean = re.sub(r"“[^”]*”", " ", clean)
        out.append((n, clean, raw))
    return out


def num(s):
    return float(s.replace(",", ""))


def measured_in(line):
    m = re.search(r"\bmeasured\b(.*)$", line, re.I)
    if not m:
        return None
    tail = re.sub(r"(?<=\d),(?=\d{3})", "", m.group(1))
    ft = re.search(r"\bfrom\s+(" + NUM + r")\s*[^\s\d]*\s+to\s+(" + NUM + ")", tail, re.I)
    if ft:
        return ft.group(2)
    n = re.search(NUM, tail)
    return n.group(0) if n else None


def body_findings(text):
    lines = body_lines(text)
    notmet, targets, info = [], [], []
    for i, (n, clean, raw) in enumerate(lines):
        if not re.match(r"^\s*[-*+]\s+\[[xX]\]", clean) and re.search(r"\bnot\s+met\b", clean, re.I):
            notmet.append(raw.strip())
        tm = re.search(r"target metric\s*:\**\s*(.*)$", clean, re.I)
        if not tm:
            continue
        t = tm.group(1).strip().strip("*").strip()
        a = b = op = None
        ft = re.match(r"^([A-Za-z0-9][A-Za-z0-9_.-]*)\s+from\s+(" + NUM + r")\s*[^\s\d]*\s+to\s+(" + NUM + ")", t, re.I)
        if ft:
            a, b = num(ft.group(2)), num(ft.group(3))
            label = "%s from %s to %s" % (ft.group(1), ft.group(2), ft.group(3))
        else:
            om = re.match(r"^(.+?)\s*(<=|>=|<|>|≤|≥)\s*(" + NUM + r")", t)
            if not om:
                continue
            op = {"≤": "<=", "≥": ">="}.get(om.group(2), om.group(2))
            b = num(om.group(3))
            label = "%s %s %s" % (om.group(1).strip(), op, om.group(3))
        # The measured number: after `measured` on this line (the part after
        # the target), else on one of the next 5 lines.
        m = measured_in(clean)
        if m is None:
            for _, c2, _ in lines[i + 1:i + 6]:
                m = measured_in(c2)
                if m is not None:
                    break
        if m is None:
            info.append("Target metric %s has no measured number" % label)
            continue
        mv = num(m)
        if op:
            met = compare_f(mv, op, b)
        elif a == b:
            info.append("Target metric %s has no direction (from equals to)" % label)
            continue
        else:
            met = mv <= b if b < a else mv >= b
        if not met:
            targets.append((label, m))
    return notmet, targets, info


def compare_f(v, op, b):
    return {"<=": v <= b, ">=": v >= b, "<": v < b, ">": v > b}[op]


def norm_id(s):
    s = s.strip("`*").strip()
    m = re.match(r"^(?:task\s*|t)(\d+)$", s, re.I)
    if m:
        return "T" + m.group(1)
    m = re.match(r"^l(\d+)$", s, re.I)
    return "L" + m.group(1) if m else None


def owed_ids(text):
    ids = set()
    for _, _, raw in body_lines(text):
        m = re.match(r"^\s*(?:[-*+]\s+)?`?owed\s*:\s*`?((?:task\s*)?[A-Za-z]?\d+)`?\s+\S", raw, re.I)
        if m:
            i = norm_id(m.group(1))
            if i:
                ids.add(i)
    return ids


def approved(ids, approvals):
    """{id: login} for each owed id an operator comment approves."""
    got = {}
    for login, line in approvals:
        for i in ids:
            if i in got:
                continue
            idre = re.escape(i) + r"(?![0-9A-Za-z])"
            if re.search(r"\bapprove[ds]?\s+owed\s*:?\s*`?" + idre, line, re.I) \
                    or re.search(r"\bowed\s*:?\s*`?" + idre + r"`?\s+approved\b", line, re.I):
                got[i] = login
    return got


def clip(s, n):
    s = re.sub(r"[\x00-\x1f\x7f]", " ", s)
    return s if len(s) <= n else s[:n - 3] + "..."


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--head", required=True)
    ap.add_argument("--plan-path", required=True)
    ap.add_argument("--body", required=True)
    ap.add_argument("--approvals")
    ap.add_argument("--max", type=int, default=60)
    a = ap.parse_args()
    plan = git(a.repo, "show", "%s:%s" % (a.head, a.plan_path))
    if plan is None:
        print("plan-validate: %s does not read at the head" % a.plan_path, file=sys.stderr)
        return 2
    try:
        with open(a.body, encoding="utf-8", errors="replace") as fh:
            body = fh.read().replace("\r", "")
    except OSError:
        print("plan-validate: the body does not read", file=sys.stderr)
        return 2
    vlines = validate_lines(plan)
    if not vlines:
        print("NONE")
        return 0
    grep_bin = shutil.which("grep") or "/bin/grep"
    rows = []
    skipped = []
    with tempfile.TemporaryDirectory(prefix="plan-validate.") as tmp:
        bf = os.path.join(tmp, "body")
        with open(bf, "w", encoding="utf-8") as fh:
            fh.write(body)
        head = Head(a.repo, a.head, tmp, bf)
        for tid, n, text, raw in vlines[:max(a.max, 0)]:
            mentions = re.search(r"pr[ _-]?body", raw, re.I) is not None
            judged = False
            partial = False
            for cmd, exp in candidates(text):
                shape = parse(cmd, mentions, a.plan_path)
                if shape is None:
                    partial = True
                    continue
                verdict, expect, actual = evaluate(shape, exp, head, grep_bin)
                if verdict == "skip":
                    partial = True
                    continue
                judged = True
                rows.append((verdict, tid, cmd, expect, actual))
            if partial or not judged:
                skipped.append(tid)
    over = max(len(vlines) - max(a.max, 0), 0)
    notmet, targets, info = body_findings(body)
    owed = owed_ids(body)
    failing = [r for r in rows if r[0] == "fail"]
    need = bool(failing or notmet or targets) and bool(owed)
    approvals = []
    if a.approvals:
        try:
            with open(a.approvals, encoding="utf-8", errors="replace") as fh:
                for ln in fh:
                    if "\t" in ln:
                        lg, txt = ln.rstrip("\n").split("\t", 1)
                        approvals.append((lg, txt))
        except OSError:
            pass
    ok_ids = approved(owed, approvals) if approvals else {}
    if need and not a.approvals:
        print("NEEDAPPROVAL")
    for verdict, tid, cmd, expect, actual in rows:
        if verdict == "ok":
            print("OK\t%s\t%s" % (tid, clip(cmd, 160)))
        elif tid in ok_ids:
            print("OWED\t%s\t%s" % (tid, ok_ids[tid]))
        else:
            print("FAIL\t%s\t%s\t%s\t%s\t%d" % (tid, clip(cmd, 160), expect, clip(actual, 200), 1 if tid in owed else 0))
    for tid in dict.fromkeys(skipped):
        print("SKIP\t%s" % tid)
    if over:
        print("CAP\t%d\t%d" % (over, a.max))
    excuse = next(iter(sorted(ok_ids.items())), None)
    if (notmet or targets) and excuse:
        print("EXCUSED\t%s\t%s" % (excuse[1], excuse[0]))
    else:
        for ln in notmet:
            print("NOTMET\t%s" % clip(ln, 200))
        for label, m in targets:
            print("TARGET\t%s\t%s" % (clip(label, 120), m))
    for t in info:
        print("INFO\t%s" % clip(t, 200))
    return 0


if __name__ == "__main__":
    sys.exit(main())
