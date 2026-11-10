#!/usr/bin/env python3
"""bin/lib/migration-rowcount.py — the row-count judge of the hub migration
lane (BH-8914). bin/lib/migration-lane.sh runs it once per member file that
migrations/status proved applied. python3 stdlib only.

  migration-rowcount.py judge <sql-file> <basename> <apply-out>
  migration-rowcount.py classify <sql-file>

THE REPORT LINE. A project's apply CLI prints, at the start of a line of its
stdout or stderr, one line per statement it ran:

  migration-rows: <file basename> <ordinal> <COMMAND> <rowCount or ->

<ordinal> is the 1-based position of the statement in the file over every
non-empty statement; <COMMAND> is the Postgres command tag word (node-pg
Result.command); <rowCount> is node-pg Result.rowCount, `-` when none.

DATA STATEMENTS are UPDATE, DELETE, INSERT ... SELECT (a SELECT at paren depth
0 and no VALUES) and WITH ... UPDATE/DELETE/INSERT (the main verb after the
CTE list; a WITH ... INSERT takes the same INSERT rule). Everything else
(CREATE, ALTER, DROP, GRANT, INSERT ... VALUES, DO blocks, function bodies)
is not counted.

THE MARKER `-- may-be-empty: <reason>` (case-insensitive key, non-empty
reason) exempts one statement. It counts in the statement's leading comments,
inside its text, or on the line of its `;` after the `;`. A `/* */` comment or
a string literal never counts.

`judge` prints one line per data statement (tab-separated):
  <verdict> <ordinal> <COMMAND> <count> <line of the first keyword> <reason|->
verdict ok (count >= 1), marked (0 with a marker), empty (0, no marker),
unaligned (no line for it, another COMMAND, or `-`). A report ordinal past the
last statement adds one `unaligned <ordinal> - - - -` line. No report line at
all for <basename> prints `unreported - - - - -`.
rc 0 = every data statement ok or marked (or none); 1 = an empty or unaligned
line; 3 = unreported; any other rc (2 = unreadable input) = not judged.
It never prints SQL text or apply-output text.
"""
import re
import sys

MARKER = re.compile(r"(?i)^--\s*may-be-empty:\s*(\S.*)$")
REPORT = re.compile(r"^migration-rows: (\S+) ([0-9]+) ([A-Za-z]+) ([0-9]+|-)\s*$")
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_$]*")
DOLLAR = re.compile(r"\$([A-Za-z_][A-Za-z0-9_]*)?\$")


def tokens(sql):
    """Yield (kind, text, line, depth). kind: word, semi, comment, other.
    Strings, quoted identifiers and dollar quotes come out as `other`."""
    i, n, line, depth = 0, len(sql), 1, 0
    while i < n:
        c = sql[i]
        if c == "\n":
            line += 1
            i += 1
        elif c.isspace():
            i += 1
        elif sql.startswith("--", i):
            j = sql.find("\n", i)
            j = n if j < 0 else j
            yield ("comment", sql[i:j], line, depth)
            i = j
        elif sql.startswith("/*", i):
            start, lvl, j = line, 1, i + 2
            while j < n and lvl:
                if sql.startswith("/*", j):
                    lvl, j = lvl + 1, j + 2
                elif sql.startswith("*/", j):
                    lvl, j = lvl - 1, j + 2
                else:
                    j += 1
            line += sql.count("\n", i, j)
            yield ("block", "", start, depth)
            i = j
        elif c in "'\"":
            # E'...' takes backslash escapes; '' and "" are a doubled quote.
            esc = c == "'" and i > 0 and sql[i - 1] in "eE" and (i < 2 or not (sql[i - 2].isalnum() or sql[i - 2] == "_"))
            j = i + 1
            while j < n:
                if esc and sql[j] == "\\":
                    j += 2
                    continue
                if sql[j] == c:
                    if j + 1 < n and sql[j + 1] == c:
                        j += 2
                        continue
                    break
                j += 1
            j = min(j + 1, n)
            yield ("other", "", line, depth)
            line += sql.count("\n", i, j)
            i = j
        elif c == "$" and (i == 0 or not (sql[i - 1].isalnum() or sql[i - 1] == "_")) and DOLLAR.match(sql, i):
            tag = DOLLAR.match(sql, i).group(0)
            j = sql.find(tag, i + len(tag))
            j = n if j < 0 else j + len(tag)
            yield ("other", "", line, depth)
            line += sql.count("\n", i, j)
            i = j
        elif c == ";":
            yield ("semi", ";", line, depth)
            i += 1
        elif c == "(":
            yield ("other", "(", line, depth)
            depth += 1
            i += 1
        elif c == ")":
            depth = max(0, depth - 1)
            yield ("other", ")", line, depth)
            i += 1
        else:
            m = IDENT.match(sql, i)
            if m and not (i > 0 and (sql[i - 1].isalnum() or sql[i - 1] == "_")):
                yield ("word", m.group(0).upper(), line, depth)
                i = m.end()
            else:
                yield ("other", c, line, depth)
                i += 1


def split(sql):
    """A list of statements: dict(ordinal, line, words [(WORD, depth)], comments [text])."""
    out, cur, pending = [], None, []
    last_semi_line, last_stmt = None, None
    for kind, text, line, depth in tokens(sql):
        if kind == "comment":
            if cur is not None:
                cur["comments"].append(text)
            elif last_stmt is not None and line == last_semi_line:
                last_stmt["comments"].append(text)
            else:
                pending.append(text)
            continue
        if kind == "block":
            continue
        if kind == "semi":
            if cur is not None:
                out.append(cur)
                last_stmt, cur = cur, None
            last_semi_line = line
            continue
        if cur is None:
            cur = {"ordinal": len(out) + 1, "line": line, "words": [], "comments": pending, "base": depth}
            pending = []
        if kind == "word":
            cur["words"].append((text, depth - cur["base"]))
    if cur is not None:
        out.append(cur)
    return out


def _insert_is_data(words):
    top = [w for w, d in words if d == 0]
    return "SELECT" in top and "VALUES" not in top


def classify(stmt):
    words = stmt["words"]
    if not words:
        return None
    first = words[0][0]
    if first in ("UPDATE", "DELETE"):
        return first
    if first == "INSERT":
        return "INSERT" if _insert_is_data(words) else None
    if first == "WITH":
        for i, (w, d) in enumerate(words[1:], 1):
            if d != 0:
                continue
            if w in ("UPDATE", "DELETE"):
                return w
            if w == "INSERT":
                return "INSERT" if _insert_is_data(words[i:]) else None
            if w in ("SELECT", "VALUES", "TABLE", "MERGE"):
                return None
    return None


def marker(stmt):
    for c in stmt["comments"]:
        m = MARKER.match(c.strip())
        if m:
            return " ".join(m.group(1).split())
    return None


def report(text, basename):
    rows = {}
    for raw in text.split("\n"):
        m = REPORT.match(raw.rstrip("\r"))
        if m and m.group(1) == basename:
            rows[int(m.group(2))] = (m.group(3).upper(), m.group(4))
    return rows


def read(path):
    with open(path, "rb") as f:
        return f.read().decode("utf-8", errors="replace").replace("\r", "")


def judge(sql_path, basename, out_path):
    stmts = split(read(sql_path))
    rows = report(read(out_path), basename)
    if not rows:
        print("unreported\t-\t-\t-\t-\t-")
        return 3
    bad = False
    for s in stmts:
        verb = classify(s)
        if verb is None:
            continue
        cmd, cnt = rows.get(s["ordinal"], (None, "-"))
        why = "-"
        if cmd != verb or cnt == "-":
            v = "unaligned"
        elif int(cnt) >= 1:
            v = "ok"
        else:
            why = marker(s)
            v = "marked" if why else "empty"
            why = why or "-"
        bad = bad or v in ("empty", "unaligned")
        print("\t".join([v, str(s["ordinal"]), verb, cnt, str(s["line"]), why]))
    for k in sorted(k for k in rows if k > len(stmts) or k < 1):
        print("unaligned\t%d\t-\t-\t-\t-" % k)
        bad = True
    return 1 if bad else 0


def main(argv):
    try:
        if len(argv) == 5 and argv[1] == "judge":
            return judge(argv[2], argv[3], argv[4])
        if len(argv) == 3 and argv[1] == "classify":
            for s in split(read(argv[2])):
                print("%d\t%d\t%s" % (s["ordinal"], s["line"], classify(s) or "-"))
            return 0
    except OSError as e:
        print("migration-rowcount: cannot read input (%s)" % e.strerror, file=sys.stderr)
        return 2
    print("usage: migration-rowcount.py judge <sql-file> <basename> <apply-out> | classify <sql-file>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
