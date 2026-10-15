#!/usr/bin/env python3
"""bin/lib/ci-test-value-render.py <out> <day-dir> -- the CI test value report
(BH-6618) as JSON. Run as `python3 -I`; standard library only.

Reads <out>/occurrences.tsv (bin/lib/ci-test-value.sh, ctv_classify_all) and
<out>/coverage.json (bin/ci-test-value-report.sh). Writes
<day-dir>/ci-test-value.json through a temp file and os.replace. rc 1 on an
unreadable input, and then no output file is written.
"""
import json
import os
import sys

COVERAGE_KEYS = ("runs_listed", "red_runs", "red_runs_read", "unread",
                 "gh_reads", "incomplete", "days_unlisted", "stop")


def main(argv):
    if len(argv) != 3:
        print("usage: ci-test-value-render.py <out> <day-dir>", file=sys.stderr)
        return 1
    out, day_dir = argv[1], argv[2]
    try:
        with open(os.path.join(out, "coverage.json"), encoding="utf-8") as f:
            cov = json.load(f)
        with open(os.path.join(out, "occurrences.tsv"), encoding="utf-8") as f:
            rows = [ln.rstrip("\n").split("\t") for ln in f
                    if ln.strip() and not ln.startswith("#")]
    except (OSError, ValueError) as e:
        print("ci-test-value-render: unreadable input: %s" % e, file=sys.stderr)
        return 1
    by_class, rules = {}, {}
    for r in rows:
        if len(r) < 12:
            print("ci-test-value-render: short row in occurrences.tsv", file=sys.stderr)
            return 1
        by_class[r[10]] = by_class.get(r[10], 0) + 1
        rules[r[11]] = rules.get(r[11], 0) + 1
    report = {
        "window": cov.get("window"),
        "repo": cov.get("repo"),
        "generated_at": cov.get("generated_at"),
        "coverage": {k: cov.get(k) for k in COVERAGE_KEYS},
        "totals": {"occurrences": len(rows), "by_class": by_class},
        "rules": rules,
    }
    os.makedirs(day_dir, exist_ok=True)
    dest = os.path.join(day_dir, "ci-test-value.json")
    tmp = "%s.tmp.%d" % (dest, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, dest)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
