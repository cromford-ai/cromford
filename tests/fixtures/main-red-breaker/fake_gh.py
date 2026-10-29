"""BH-8706 test fake: a recording GitHub REST store for bin/main-red-breaker.sh.

Used only by tests/main-red-breaker.bh-8706-test.sh through the lane's
MAIN_RED_BREAKER_FIXTURE seam. 0 network calls. Any path it does not
implement answers status 99 and the shell side writes an UNFAKED line.

  fake_gh.py <dir> gh <METHOD> <path> [args...]   -> line 1 status, rest body
  fake_gh.py <dir> add <slug> <n> <labels,csv> [state] [pr|issue] [body]
  fake_gh.py <dir> labels <slug> <n>              -> labels, comma joined
  fake_gh.py <dir> set <key> <json>               -> store[key] = json
  fake_gh.py <dir> fail <METHOD path-prefix> <status>
  fake_gh.py <dir> created                        -> the issues POSTed, JSON
  GET repos/<slug>/pulls/<n> answers the PR row (head "head<n>" padded to 40).
  store key gone404: ["<slug>#<n>", ...] — that PR's label DELETE removes the
  label and still answers 404 (someone took it off first)
  GET repos/<slug>/contents/.mergify.yml answers DEFAULT_MERGIFY (a templated
  repo: its queue_conditions exclude merge-queue-paused) base64-encoded, as
  GitHub does. store key "mergify:<slug>": a string is that repo's YAML, null
  answers 404.
"""
import base64
import json
import os
import re
import sys
from urllib.parse import urlsplit

D = sys.argv[1]
P = os.path.join(D, "store.json")
DEFAULT_MERGIFY = """queue_rules:
  - name: default
    queue_conditions:
      - label=merge-queue
      - -label=merge-queue-paused
"""


def load():
    try:
        with open(P) as f:
            return json.load(f)
    except FileNotFoundError:
        return {"issues": {}, "fail": {}, "created": [], "next": 9000}


def save(s):
    with open(P, "w") as f:
        json.dump(s, f)


def out(st, body=None):
    print(st)
    if body is not None:
        print(json.dumps(body))
    return 0


def gh(s, method, path, args):
    with open(os.path.join(D, "calls"), "a") as f:
        f.write(f"{method} {path}\n")
    for k, v in s["fail"].items():
        m, pre = k.split(" ", 1)
        if m == method and path.startswith(pre):
            return out(v, {"message": "fixture failure"})
    opts, inp, i = {}, None, 0
    while i < len(args):
        if args[i] in ("-f", "-F") and i + 1 < len(args):
            k, _, v = args[i + 1].partition("=")
            opts[k] = v
            i += 2
        elif args[i] == "--input" and i + 1 < len(args):
            with open(args[i + 1]) as f:
                inp = json.load(f)
            i += 2
        else:
            i += 1
    if inp is None and "labels[]" in opts:
        # The tracker adapter's form (trk_gh_label_add): -f labels[]=<name>.
        inp = {"labels": [opts["labels[]"]]}
    u = urlsplit(path)
    p = u.path
    m = re.match(r"^repos/([^/]+/[^/]+)/issues$", p)
    if m and method == "GET":
        # The labels filter is NOT applied: the lane's own exact-label match
        # must carry the decision (a looser fake than GitHub, on purpose).
        rows = [x for x in s["issues"].get(m.group(1), [])
                if opts.get("state", "open") in ("all", x["state"])]
        pg = int(opts.get("page", "1"))
        return out(200, rows[(pg - 1) * 100: pg * 100])
    if m and method == "POST":
        s["next"] += 1
        n = s["next"]
        row = {"number": n, "state": "open", "title": inp["title"], "body": inp["body"],
               "labels": [{"name": x} for x in inp.get("labels", [])],
               "html_url": f"https://github.com/{m.group(1)}/issues/{n}"}
        s["issues"].setdefault(m.group(1), []).append(row)
        s["created"].append(row)
        save(s)
        return out(201, row)
    m = re.match(r"^repos/([^/]+/[^/]+)/issues/([0-9]+)/labels(?:/(.+))?$", p)
    if m:
        rows = [x for x in s["issues"].get(m.group(1), []) if x["number"] == int(m.group(2))]
        if not rows:
            return out(404, {"message": "Not Found"})
        row = rows[0]
        names = [x["name"] for x in row["labels"]]
        if method == "POST" and m.group(3) is None:
            for x in inp["labels"]:
                if x not in names:
                    row["labels"].append({"name": x})
            save(s)
            return out(200, row["labels"])
        if method == "DELETE" and m.group(3):
            if f"{m.group(1)}#{m.group(2)}" in s.get("gone404", []):
                # Someone else took the label off first: GitHub answers 404.
                row["labels"] = [x for x in row["labels"] if x["name"] != m.group(3)]
                save(s)
                return out(404, {"message": "Label does not exist"})
            if m.group(3) not in names:
                return out(404, {"message": "Label does not exist"})
            row["labels"] = [x for x in row["labels"] if x["name"] != m.group(3)]
            save(s)
            return out(200, row["labels"])
    m = re.match(r"^repos/([^/]+/[^/]+)/pulls/([0-9]+)$", p)
    if m and method == "GET":
        # The PR read of a resume: state, head sha, labels, html_url. The head
        # is "head<n>" padded to 40 characters.
        rows = [x for x in s["issues"].get(m.group(1), [])
                if x["number"] == int(m.group(2)) and "pull_request" in x]
        if not rows:
            return out(404, {"message": "Not Found"})
        x = rows[0]
        return out(200, {"number": x["number"], "state": x["state"], "labels": x["labels"],
                         "head": {"sha": ("head%d" % x["number"]).ljust(40, "0")},
                         "html_url": f"https://github.com/{m.group(1)}/pull/{x['number']}"})
    m = re.match(r"^repos/([^/]+/[^/]+)/contents/\.mergify\.yml$", p)
    if m and method == "GET":
        y = s.get("mergify:" + m.group(1), DEFAULT_MERGIFY)
        if y is None:
            return out(404, {"message": "Not Found"})
        return out(200, {"encoding": "base64", "content": base64.encodebytes(y.encode()).decode()})
    m = re.match(r"^repos/[^/]+/[^/]+/actions/runs/([0-9]+)/jobs$", p)
    if m and method == "GET":
        j = s.get("jobs:" + m.group(1))
        return out(200, j) if j is not None else out(404, {"message": "Not Found"})
    m = re.match(r"^repos/[^/]+/[^/]+/check-runs/([0-9]+)/annotations$", p)
    if m and method == "GET":
        return out(200, s.get("ann:" + m.group(1), []))
    m = re.match(r"^repos/[^/]+/[^/]+/actions/workflows/([^/]+)/runs$", p)
    if m and method == "GET":
        g = s.get("green:" + m.group(1))
        return out(200, {"workflow_runs": [{"head_sha": g}] if g else []})
    m = re.match(r"^repos/[^/]+/[^/]+/compare/(.+)$", p)
    if m and method == "GET":
        c = s.get("compare:" + m.group(1))
        return out(200, c) if c is not None else out(404, {"message": "Not Found"})
    return out(99)


def main():
    s = load()
    cmd = sys.argv[2]
    a = sys.argv[3:]
    if cmd == "gh":
        return gh(s, a[0], a[1], a[2:])
    if cmd == "add":
        slug, n, labels = a[0], int(a[1]), [x for x in a[2].split(",") if x]
        state = a[3] if len(a) > 3 else "open"
        kind = a[4] if len(a) > 4 else "pr"
        row = {"number": n, "state": state, "title": f"item {n}", "body": a[5] if len(a) > 5 else "",
               "labels": [{"name": x} for x in labels],
               "html_url": f"https://github.com/{slug}/issues/{n}"}
        if kind == "pr":
            row["pull_request"] = {"url": f"https://api.github.com/repos/{slug}/pulls/{n}"}
        s["issues"].setdefault(slug, []).append(row)
    elif cmd == "labels":
        rows = [x for x in s["issues"].get(a[0], []) if x["number"] == int(a[1])]
        print(",".join(x["name"] for x in rows[0]["labels"]) if rows else "")
        return 0
    elif cmd == "set":
        s[a[0]] = json.loads(a[1])
    elif cmd == "fail":
        if a[1] == "-":
            s["fail"].pop(a[0], None)
        else:
            s["fail"][a[0]] = int(a[1])
    elif cmd == "created":
        print(json.dumps(s["created"]))
        return 0
    save(s)
    return 0


sys.exit(main())
