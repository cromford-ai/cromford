#!/usr/bin/env python3
"""bin/lib/ci-test-value-render.py <out> <day-dir> -- the CI test value report
(BH-6618). Run as `python3 -I`; standard library only.

Reads <out>/occurrences.tsv (bin/lib/ci-test-value.sh, ctv_classify_all) and
<out>/coverage.json (bin/ci-test-value-report.sh), both required, and the
optional <out>/cache/ files ctv_fetch_sources writes: suite-durations.json,
suite-passes.json, flakes.json, suites-on-disk.txt. An optional file that is
absent or of the wrong shape is a source with read: false, and every field
that needs it is null.

Writes <day-dir>/ci-test-value.json, ci-test-value.html and summary-ste.md, in
that order, each through a temp file and os.replace. rc 1 on an unreadable
required input, and then no output file is written.
"""
import html
import json
import os
import re
import sys

COVERAGE_KEYS = ("runs_listed", "red_runs", "red_runs_read", "unread",
                 "gh_reads", "incomplete", "days_unlisted", "stop")
REAL = ("real-pr", "real-main")
FALSE = ("test-defect", "infra", "flake", "order")
EXPENSIVE_MAX = 20
SUMMARY_TOP = 10
# occurrences.tsv columns (ctv_classify_all).
C_RUN, C_ATT, C_JOB, C_DAY, C_EVENT, C_BATCH, C_SHA, C_UNIT, C_RC, C_SECS, \
    C_CLASS, C_RULE, C_RUN_URL, C_JOB_URL, C_WHY = range(15)
OCC_COLS = 15


def is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def read_json(path, shape):
    """The parsed file when it parses and shape(doc) holds, else None."""
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return None
    try:
        return doc if shape(doc) else None
    except (TypeError, KeyError, AttributeError):
        return None


def shape_durations(d):
    return isinstance(d.get("rows"), list) and all(
        isinstance(r.get("suite"), str) and is_num(r.get("seconds")) for r in d["rows"])


def shape_passes(d):
    return isinstance(d.get("suites"), list) and all(
        isinstance(r.get("suite"), str) and is_num(r.get("passes")) and is_num(r.get("fails"))
        for r in d["suites"])


def shape_flakes(d):
    return isinstance(d.get("flakes"), list)


def slugify(prefix, name, used):
    s = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or "x"
    base = "%s-%s" % (prefix, s)
    slug, n = base, 1
    while slug in used:
        n += 1
        slug = "%s-%d" % (base, n)
    used.add(slug)
    return slug


def sort_key_text(s):
    return s.encode("utf-8")  # LC_ALL=C order


def build(cov, rows, out):
    """The report dict from the inputs."""
    cache = os.path.join(out, "cache")
    durations = read_json(os.path.join(cache, "suite-durations.json"), shape_durations)
    passes = read_json(os.path.join(cache, "suite-passes.json"), shape_passes)
    flakes = read_json(os.path.join(cache, "flakes.json"), shape_flakes)
    disk = None
    try:
        with open(os.path.join(cache, "suites-on-disk.txt"), encoding="utf-8") as f:
            disk = set(ln.strip() for ln in f if ln.strip())
    except OSError:
        pass

    window = cov.get("window") if isinstance(cov.get("window"), dict) else {}
    since = (passes or {}).get("since") or window.get("from")
    median = None if durations is None else {r["suite"]: r["seconds"] for r in durations["rows"]}
    ledger = None if passes is None else {r["suite"]: r["passes"] + r["fails"] for r in passes["suites"]}

    by_class, rules, units = {}, {}, {}
    for r in rows:
        by_class[r[C_CLASS]] = by_class.get(r[C_CLASS], 0) + 1
        rules[r[C_RULE]] = rules.get(r[C_RULE], 0) + 1
        u = units.setdefault(r[C_UNIT], {"runs": set(), "failures": {}, "n": 0, "last_day": None,
                                         "last_real": None})
        u["n"] += 1
        u["runs"].add((r[C_RUN], r[C_ATT]))
        u["failures"][r[C_CLASS]] = u["failures"].get(r[C_CLASS], 0) + 1
        if u["last_day"] is None or r[C_DAY] > u["last_day"]:
            u["last_day"] = r[C_DAY]
        if r[C_CLASS] in REAL and (u["last_real"] is None or r[C_DAY] > u["last_real"]):
            u["last_real"] = r[C_DAY]

    names = set(n for n in units if not n.startswith("job:"))
    names |= set(ledger or ())
    names |= set(disk or ())
    used = set()
    suites = []
    for name in sorted(names, key=sort_key_text):
        u = units.get(name, {"runs": set(), "failures": {}, "last_real": None})
        failures = dict(sorted(u["failures"].items()))
        lr = None if ledger is None else ledger.get(name, 0)
        md = None if median is None else median.get(name)
        cs = None if lr is None or md is None else int(round(md * lr))
        suites.append({
            "suite": name,
            "slug": slugify("suite", name, used),
            "ledger_runs": lr,
            "runs_source": None if lr is None else "suite-results passes+fails since %s" % since,
            "seen_runs": len(u["runs"]),
            "failures": failures,
            "real": sum(failures.get(c, 0) for c in REAL),
            "false": sum(failures.get(c, 0) for c in FALSE),
            "ci_seconds": cs,
            "ci_seconds_source": "median×runs",
            "last_real_catch": u["last_real"],
            "on_disk": None if disk is None else name in disk,
        })
    unattributed = []
    for name in sorted((n for n in units if n.startswith("job:")), key=sort_key_text):
        u = units[name]
        unattributed.append({"unit": name, "slug": slugify("job", name, used), "occurrences": u["n"],
                             "failures": dict(sorted(u["failures"].items())), "last_day": u["last_day"]})

    zero = [s for s in suites if s["real"] == 0]
    zrf = sorted((s for s in zero if s["false"] >= 1), key=lambda s: (-s["false"], sort_key_text(s["suite"])))
    exp = sorted(zero, key=lambda s: (s["ci_seconds"] is None, -(s["ci_seconds"] or 0), sort_key_text(s["suite"])))
    never = None
    if ledger is not None and disk is not None:
        never = [s["suite"] for s in suites if s["on_disk"] and s["ledger_runs"] == 0 and s["seen_runs"] == 0]

    n = len(rows)
    totals = {
        "occurrences": n,
        "by_class": by_class,
        "red_runs": cov.get("red_runs"),
        "red_runs_read": cov.get("red_runs_read"),
        "pct_by_class": {c: round(100.0 * k / n, 1) for c, k in sorted(by_class.items())} if n else {},
        "unattributed_units": len(unattributed),
    }

    def src(rel, read, **extra):
        d = {"file": rel, "read": read}
        d.update(extra)
        return d
    fl = {"rows": len(flakes["flakes"])} if flakes is not None else {}
    sources = {
        "occurrences": src("occurrences.tsv", True),
        "coverage": src("coverage.json", True),
        "suite_durations": src("cache/suite-durations.json", durations is not None),
        "suite_passes": src("cache/suite-passes.json", passes is not None),
        "suites_on_disk": src("cache/suites-on-disk.txt", disk is not None),
        "flakes": src("cache/flakes.json", flakes is not None, **fl),
    }
    return {
        "window": cov.get("window"),
        "repo": cov.get("repo"),
        "generated_at": cov.get("generated_at"),
        "coverage": {k: cov.get(k) for k in COVERAGE_KEYS},
        "totals": totals,
        "rules": rules,
        "suites": suites,
        "unattributed": unattributed,
        "lists": {
            "zero_real_with_false": [s["suite"] for s in zrf],
            "expensive_zero_real": [s["suite"] for s in exp[:EXPENSIVE_MAX]],
            "never_ran": never,
        },
        "sources": sources,
    }


# ── HTML ─────────────────────────────────────────────────────────────────────
CSS = """:root{--bg:#0f1115;--panel:#171a21;--line:#2a2f3a;--text:#e6e8ee;--dim:#9aa3b2;--accent:#6ea8fe;--real:#5bd28f;--false:#f0a35b}
*{box-sizing:border-box}
body{margin:0;padding:16px;background:var(--bg);color:var(--text);font:14px/1.45 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
h1{font-size:20px;margin:0 0 4px}h2{font-size:16px;margin:24px 0 8px}
p.meta{color:var(--dim);margin:0 0 12px;word-break:break-word}
.tw{overflow-x:auto;-webkit-overflow-scrolling:touch;border:1px solid var(--line);border-radius:6px;background:var(--panel)}
table{border-collapse:collapse;width:100%;font-size:13px}
th,td{padding:6px 8px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}
td{overflow-wrap:break-word}
td.n,th[data-type=num]{text-align:right;white-space:nowrap}
th{position:sticky;top:0;background:var(--panel);cursor:pointer;user-select:none;white-space:nowrap;min-height:32px}
th:focus{outline:2px solid var(--accent);outline-offset:-2px}
th[aria-sort=ascending]::after{content:" \\25B2"}
th[aria-sort=descending]::after{content:" \\25BC"}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
tr:target,tr.hit{background:#24304a}
.real{color:var(--real)}.false{color:var(--false)}
.empty{color:var(--dim);padding:8px}"""

JS = """(function(){
function val(td,num){var v=td.hasAttribute('data-v')?td.getAttribute('data-v'):td.textContent.trim();
if(v===''||v==='\\u2014')return null;
if(num){var n=Number(v);return isNaN(n)?null:n;}return v.toLowerCase();}
function go(th){var t=th.closest('table'),tb=t.tBodies[0],i=th.cellIndex,num=th.getAttribute('data-type')==='num';
var dir=th.getAttribute('aria-sort')==='ascending'?'descending':'ascending';
Array.prototype.forEach.call(t.querySelectorAll('th'),function(h){h.setAttribute('aria-sort','none');});
th.setAttribute('aria-sort',dir);
var rows=Array.prototype.slice.call(tb.rows);
rows.sort(function(a,b){var x=val(a.cells[i],num),y=val(b.cells[i],num);
if(x===null&&y===null)return 0;if(x===null)return 1;if(y===null)return -1;
var c=x<y?-1:x>y?1:0;return dir==='ascending'?c:-c;});
rows.forEach(function(r){tb.appendChild(r);});}
Array.prototype.forEach.call(document.querySelectorAll('th'),function(th){
th.addEventListener('click',function(){go(th);});
th.addEventListener('keydown',function(e){if(e.key==='Enter'||e.key===' '){e.preventDefault();go(th);}});});
})();"""


def esc(v):
    return html.escape("" if v is None else str(v), quote=True)


def gh_link(url, text):
    if isinstance(url, str) and url.startswith("https://github.com/"):
        return '<a href="%s">%s</a>' % (esc(url), esc(text))
    return esc(text if text not in (None, "") else url)


def cell(v, num=False, raw=None, cls=None):
    """One <td>. None prints an em dash and sorts last (data-v empty)."""
    attrs = []
    if cls:
        attrs.append('class="%s"' % cls)
    elif num:
        attrs.append('class="n"')
    if v is None:
        attrs.append('data-v=""')
        body = "—"
    else:
        if num:
            attrs.append('data-v="%s"' % esc(v))
        body = raw if raw is not None else esc(v)
    return "<td%s>%s</td>" % ("".join(" " + a for a in attrs), body)


def table(title, heads, rows, empty="No rows."):
    """heads: [(label, 'num'|'text')]; rows: list of (tr-attrs, [td html])."""
    out = ["<h2>%s</h2>" % esc(title), '<div class="tw"><table><thead><tr>']
    for label, kind in heads:
        out.append('<th role="columnheader" aria-sort="none" tabindex="0" data-type="%s">%s</th>'
                   % (kind, esc(label)))
    out.append("</tr></thead><tbody>")
    for attrs, tds in rows:
        out.append("<tr%s>%s</tr>" % (attrs, "".join(tds)))
    out.append("</tbody></table></div>")
    if not rows:
        out.append('<p class="empty">%s</p>' % esc(empty))
    return "".join(out)


def failures_text(f):
    return ", ".join("%s %d" % (k, v) for k, v in f.items())


def render_html(rep, rows):
    by_suite = {s["suite"]: s for s in rep["suites"]}
    by_unit = {u["unit"]: u for u in rep["unattributed"]}
    anchored = set()
    occ_rows = []
    for r in rows:
        unit = r[C_UNIT]
        ref = by_suite.get(unit) or by_unit.get(unit)
        attrs = ""
        if ref is not None and ref["slug"] not in anchored:
            anchored.add(ref["slug"])
            attrs = ' id="%s"' % ref["slug"]
        unit_html = '<a href="#%s">%s</a>' % (ref["slug"], esc(unit)) if ref else esc(unit)
        cls_css = "real" if r[C_CLASS] in REAL else "false" if r[C_CLASS] in FALSE else None
        occ_rows.append((attrs, [
            cell(r[C_DAY]),
            cell(r[C_RUN], raw=gh_link(r[C_RUN_URL], r[C_RUN])),
            cell(r[C_ATT], num=True),
            cell(r[C_JOB], raw=gh_link(r[C_JOB_URL], r[C_JOB])),
            cell(unit, raw=unit_html),
            cell(r[C_CLASS], cls=cls_css),
            cell(r[C_RULE]),
            cell(r[C_RC]),
            cell(None if r[C_SECS] in ("", "-") else r[C_SECS], num=r[C_SECS] not in ("", "-")),
            cell(r[C_EVENT]),
            cell(r[C_BATCH]),
            cell(r[C_WHY] or None),
        ]))

    def suite_link(name):
        s = by_suite.get(name)
        return '<a href="#%s">%s</a>' % (s["slug"], esc(name)) if s else esc(name)

    def suite_row(s, anchor=False):
        attrs = ""
        if anchor and s["slug"] not in anchored:
            anchored.add(s["slug"])
            attrs = ' id="%s"' % s["slug"]
        return (attrs, [
            cell(s["suite"], raw=suite_link(s["suite"])),
            cell(s["ledger_runs"], num=True),
            cell(s["seen_runs"], num=True),
            cell(s["real"], num=True),
            cell(s["false"], num=True),
            cell(failures_text(s["failures"]) or None),
            cell(s["ci_seconds"], num=True),
            cell(s["last_real_catch"]),
        ])
    suite_heads = [("Suite", "text"), ("Ledger runs", "num"), ("Seen runs", "num"), ("Real", "num"),
                   ("False", "num"), ("Failures by class", "text"), ("CI seconds", "num"),
                   ("Last real catch", "text")]

    def list_rows(names):
        return [suite_row(by_suite[n]) for n in (names or []) if n in by_suite]

    t, cov = rep["totals"], rep["coverage"]
    kv = lambda pairs: [("", [cell(k), cell(v, num=is_num(v))]) for k, v in pairs]
    tot_pairs = [("occurrences", t["occurrences"]), ("red runs", t["red_runs"]),
                 ("red runs read", t["red_runs_read"]), ("unattributed job units", t["unattributed_units"]),
                 ("suites", len(rep["suites"]))]
    tot_pairs += [("class %s" % c, "%d (%s%%)" % (k, t["pct_by_class"].get(c))) for c, k in sorted(t["by_class"].items())]
    cov_pairs = [(k, cov.get(k)) for k in COVERAGE_KEYS]
    cov_pairs += [("source %s" % k, "read" if v["read"] else "unread") for k, v in sorted(rep["sources"].items())]
    lists = rep["lists"]
    never_note = "Never ran: not known. A source it needs is unread." if lists["never_ran"] is None else "No rows."

    body = [
        table("Totals", [("Item", "text"), ("Value", "text")], kv(tot_pairs)),
        table("Coverage", [("Item", "text"), ("Value", "text")], kv(cov_pairs)),
        table("Zero real with false", suite_heads, list_rows(lists["zero_real_with_false"])),
        table("Expensive zero real (top %d)" % EXPENSIVE_MAX, suite_heads, list_rows(lists["expensive_zero_real"])),
        table("Never ran", suite_heads, list_rows(lists["never_ran"]), empty=never_note),
    ]
    all_rows = [suite_row(s, anchor=True) for s in rep["suites"]]
    body.append(table("All suites", suite_heads, all_rows))
    body.append(table("Unattributed jobs", [("Job unit", "text"), ("Occurrences", "num"),
                                            ("Failures by class", "text"), ("Last day", "text")],
                      [("", [cell(u["unit"], raw='<a href="#%s">%s</a>' % (u["slug"], esc(u["unit"]))),
                             cell(u["occurrences"], num=True), cell(failures_text(u["failures"]) or None),
                             cell(u["last_day"])]) for u in rep["unattributed"]]))
    body.append(table("Occurrences", [("Day", "text"), ("Run", "text"), ("Attempt", "num"), ("Job", "text"),
                                      ("Unit", "text"), ("Class", "text"), ("Rule", "text"), ("Rc", "text"),
                                      ("Secs", "num"), ("Event", "text"), ("Batch", "text"), ("Why", "text")],
                      occ_rows))
    w = rep["window"] if isinstance(rep["window"], dict) else {}
    meta = "%s. Window %s to %s (%s days). Generated %s." % (
        esc(rep["repo"]), esc(w.get("from")), esc(w.get("to")), esc(w.get("days")), esc(rep["generated_at"]))
    return ('<!doctype html>\n<html lang="en"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            "<title>CI test value report</title><style>%s</style></head><body>"
            "<h1>CI test value report</h1><p class=\"meta\">%s</p>%s<script>%s</script></body></html>\n"
            % (CSS, meta, "".join(body), JS))


# ── summary-ste.md ───────────────────────────────────────────────────────────
def summary(rep):
    cov, t = rep["coverage"], rep["totals"]
    red, read, unread = cov.get("red_runs"), cov.get("red_runs_read"), cov.get("unread")
    if not (is_int(red) and is_int(read) and is_int(unread)):
        first = "INCOMPLETE: unknown red runs unread"
    elif unread == 0 and read == red and cov.get("incomplete") is not True:
        first = "COMPLETE: %d red runs read" % red
    else:
        first = "INCOMPLETE: %d red runs unread" % max(red - read, unread, 0)
    w = rep["window"] if isinstance(rep["window"], dict) else {}
    lines = [first, ""]
    lines.append("Window: %s to %s (%s days). Repo: %s." % (w.get("from"), w.get("to"), w.get("days"), rep["repo"]))
    lines.append("Occurrences: %d. Red runs: %s. Red runs read: %s. Unattributed job units: %d."
                 % (t["occurrences"], red, read, t["unattributed_units"]))
    for c, k in sorted(t["by_class"].items()):
        lines.append("Class %s: %d (%s%%)." % (c, k, t["pct_by_class"].get(c)))
    by_suite = {s["suite"]: s for s in rep["suites"]}

    def top(title, names, of=None):
        lines.append("")
        size = "%d suites" % len(names) if of is None else "%d listed of %d suites with real 0" % (len(names), of)
        lines.append("%s: %s. Top %d:" % (title, size, min(SUMMARY_TOP, len(names))))
        for n in names[:SUMMARY_TOP]:
            s = by_suite[n]
            lines.append("- %s: false=%d runs=%s ci_seconds=%s" % (
                n, s["false"], "unknown" if s["ledger_runs"] is None else s["ledger_runs"],
                "unknown" if s["ci_seconds"] is None else s["ci_seconds"]))
    top("Zero real with false", rep["lists"]["zero_real_with_false"])
    top("Expensive zero real", rep["lists"]["expensive_zero_real"], sum(1 for x in rep["suites"] if x["real"] == 0))
    nr = rep["lists"]["never_ran"]
    lines.append("")
    lines.append("Never ran: %s." % ("not known" if nr is None else "%d suites" % len(nr)))
    lines.append("Coverage: gh_reads=%s days_unlisted=%s stop=%s." % (
        cov.get("gh_reads"), cov.get("days_unlisted"), cov.get("stop") or "none"))
    for k, v in sorted(rep["sources"].items()):
        if not v["read"]:
            lines.append("Source %s is unread. The fields that need it are null." % k)
    return "\n".join(lines) + "\n"


def write_atomic(path, text):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


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
    if not isinstance(cov, dict):
        print("ci-test-value-render: unreadable input: coverage.json is not an object", file=sys.stderr)
        return 1
    for r in rows:
        if len(r) < 12:
            print("ci-test-value-render: short row in occurrences.tsv", file=sys.stderr)
            return 1
        r.extend([""] * (OCC_COLS - len(r)))
    report = build(cov, rows, out)
    os.makedirs(day_dir, exist_ok=True)
    write_atomic(os.path.join(day_dir, "ci-test-value.json"),
                 json.dumps(report, indent=2, sort_keys=True) + "\n")
    write_atomic(os.path.join(day_dir, "ci-test-value.html"), render_html(report, rows))
    write_atomic(os.path.join(day_dir, "summary-ste.md"), summary(report))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
