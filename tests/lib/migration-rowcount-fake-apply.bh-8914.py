#!/usr/bin/env python3
"""tests/lib/migration-rowcount-fake-apply.bh-8914.py — the fake project apply
CLI of tests/migration-lane-rowcount.bh-8914-test.sh. Not a test.

It stands in for a project's migration ledger CLI (project-6
scripts/db/apply-sql.mjs) that prints the BH-8914 report line. It runs in the
lane's apply tree (main + the members' SQL files) and uses a SQLite file, never
a real database:

  fake-apply.py --seed     create $ML_FX/db.sqlite with users(hayley, 'a')
  fake-apply.py            apply each prisma/sql/*.sql that $ML_FX/status.json
                           does not list, in name order, one transaction per
                           file, and print per statement
                           `migration-rows: <file> <k> <COMMAND> <rowcount|->`

The splitter is sqlite3.complete_statement, on purpose not the judge's own,
so the lane suite checks the judge against an independent writer.
"""
import glob
import hashlib
import json
import os
import sqlite3
import sys

FX = os.environ["ML_FX"]
DB = os.path.join(FX, "db.sqlite")


def statements(sql):
    out, buf = [], ""
    for line in sql.splitlines(keepends=True):
        buf += line
        if sqlite3.complete_statement(buf):
            out.append(buf)
            buf = ""
    if buf.strip():
        out.append(buf)
    return [s for s in out if any(not ln.strip().startswith("--") and ln.strip() for ln in s.splitlines())]


def command(stmt):
    words = [w for ln in stmt.splitlines() if not ln.strip().startswith("--") for w in ln.split()]
    verb = words[0].upper().rstrip(";")
    if verb == "WITH":
        for w in words:
            if w.upper() in ("UPDATE", "DELETE", "INSERT", "SELECT"):
                return w.upper()
    return verb


def main():
    if sys.argv[1:] == ["--seed"]:
        con = sqlite3.connect(DB)
        con.execute("CREATE TABLE users (id TEXT PRIMARY KEY, dashboards TEXT)")
        con.execute("INSERT INTO users VALUES ('hayley', 'a')")
        con.commit()
        return 0
    st_path = os.path.join(FX, "status.json")
    st = json.load(open(st_path)) if os.path.exists(st_path) else {"pending": [], "applied": []}
    done = {a["filename"] for a in st["applied"]}
    con = sqlite3.connect(DB, isolation_level=None)
    for path in sorted(glob.glob("prisma/sql/*.sql")):
        b = os.path.basename(path)
        if b in done:
            continue
        raw = open(path, "rb").read()
        con.execute("BEGIN")
        lines = []
        for k, s in enumerate(statements(raw.decode()), 1):
            cur = con.execute(s)
            n = cur.rowcount if cur.rowcount >= 0 else "-"
            lines.append("migration-rows: %s %d %s %s" % (b, k, command(s), n))
        con.execute("COMMIT")
        print("\n".join(lines))
        print("%s ok" % b)
        st["applied"].append({"filename": b, "checksum": hashlib.sha256(raw).hexdigest()})
        json.dump(st, open(st_path, "w"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
