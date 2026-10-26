"""bin/dora_landing.py — the `landing` block of the daily DORA digest and the
arithmetic of bin/landing-replay.sh (BH-6748, wave 5 of #6541).

Pure: no env reads, no network. It reads only the sources dir that
bin/lib/landing-sources.sh ls_fetch writes (decisions.jsonl, merges.jsonl,
ci-batches.jsonl, pulls.jsonl, ejected.txt, sources.json). The rules, and how
to re-derive each figure by hand, are in docs/DORA.md ("landing block").

  merge_path(detail)       direct | queued, off the merge ledger row's detail
  revert_culprit(pr, repo) the PR number a main-red revert PR reverts, or None
  parse_ejected(lines)     the (repo, number, head) set of `ejected` lines
  is_ejected(...)          one head of one PR was ejected from the queue
  pctl(xs, p)              nearest-rank percentile, None for no values
  load(srcdir)             the sources dir as one dict
  block(...)               the digest's per-project figures
  replay(...)              what optimistic mode would have landed directly
  text_lines / replay_lines  the plain-text renders

Absent is None, never 0: a window with no direct merges has a direct merge
COUNT of 0, and every figure derived from direct merges is None ("n/a").
"""
import json
import math
import os
import re
import sys
from collections import Counter
from datetime import datetime

SOURCES = ("decisions", "merges", "ci_batches", "pulls", "ejected")
MAIN_RED_LABEL = "fix-main-red"
WHY_DIRECT_CI = "push runs on main are not in ci_batches"
_URL = re.compile(r"^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/(\d+)$")
_ISO = re.compile(r"^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(?:\.\d+)?(?:Z|\+00:00)?$")
_REVERT_TITLE = re.compile(r"^revert: #(\d+)\b")
_REVERT_REF = re.compile(r"^main-red-revert/pr-(\d+)-")
_GH_REVERT_TITLE = re.compile(r'^Revert "')
_EJECTED = re.compile(r"^ejected ([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#(\d+) ([0-9a-fA-F]+)\s*$")


def _iso(s):
    """A stamp in the one shape string compare orders: YYYY-MM-DDTHH:MM:SSZ."""
    m = _ISO.match(s or "")
    return "%sT%sZ" % m.groups() if m else None


def _secs(a, b):
    fmt = "%Y-%m-%dT%H:%M:%SZ"
    return int((datetime.strptime(b, fmt) - datetime.strptime(a, fmt)).total_seconds())


def _in(at, since, until):
    at = _iso(at)
    return at is not None and since <= at <= until


def pr_of_url(url):
    """(repo, number) of a PR url, or (None, None)."""
    m = _URL.match(url or "")
    return (m.group(1), int(m.group(2))) if m else (None, None)


def merge_path(detail):
    """direct when the merge ledger detail has the whitespace token
    `path=direct` (mc_settle_merged writes `merge-conductor path=direct` for a
    direct landing, bin/lib/mc/settle.sh). Every other detail is queued:
    `path=directx`, a JSON detail, none at all."""
    return "direct" if "path=direct" in str(detail or "").split() else "queued"


def revert_culprit(pr, repo, label=MAIN_RED_LABEL):
    """The PR number a revert PR reverts, or None. The revert PR carries the
    main-red label (MC_MAIN_RED_LABEL) AND is merged AND names its culprit one
    of three ways: the title `revert: #N` (bin/lib/mrb-act.sh), the branch
    `main-red-revert/pr-N-<sha12>`, or GitHub's own `Revert "..."` title with
    a body line `Reverts <repo>#N`. A forward fix under the label is not a
    revert, and a body naming another repo is not this repo's revert."""
    if label not in (pr.get("labels") or []) or not pr.get("merged_at"):
        return None
    title = pr.get("title") or ""
    m = _REVERT_TITLE.match(title) or _REVERT_REF.match(pr.get("head_ref") or "")
    if m:
        return int(m.group(1))
    if _GH_REVERT_TITLE.match(title):
        m = re.search(r"(?m)^Reverts %s#(\d+)\b" % re.escape(repo), pr.get("body") or "")
        if m:
            return int(m.group(1))
    return None


def parse_ejected(lines):
    """The set of (repo, number, head lowercased) of `ejected <repo>#<n> <head>`
    attempts lines (bin/merge-conductor.sh). `ejectrebase` and every other
    kind are not ejections."""
    out = set()
    for line in lines or []:
        m = _EJECTED.match(line)
        if m:
            out.add((m.group(1), int(m.group(2)), m.group(3).lower()))
    return out


def is_ejected(eset, repo, number, head):
    """The decided head of that PR was ejected. Another head is another try."""
    return (repo, int(number), (head or "").lower()) in eset


def pctl(xs, p):
    """Nearest rank: the ceil(p * n)-th smallest value. None for no values."""
    xs = sorted(xs)
    if not xs:
        return None
    return xs[max(1, int(math.ceil(p * len(xs)))) - 1]


def _jsonl(path):
    rows = []
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if line:
                    rows.append(json.loads(line))
    except OSError:
        pass
    return rows


def load(srcdir):
    """The sources dir ls_fetch writes, as one dict."""
    try:
        with open(os.path.join(srcdir, "sources.json")) as fh:
            sources = json.load(fh)
    except (OSError, ValueError):
        sources = {}
    try:
        with open(os.path.join(srcdir, "ejected.txt")) as fh:
            ejected = fh.read().splitlines()
    except OSError:
        ejected = []
    return dict(decisions=_jsonl(os.path.join(srcdir, "decisions.jsonl")),
                merges=_jsonl(os.path.join(srcdir, "merges.jsonl")),
                ci_batches=_jsonl(os.path.join(srcdir, "ci-batches.jsonl")),
                pulls=_jsonl(os.path.join(srcdir, "pulls.jsonl")),
                ejected=ejected, sources=sources)


def _status(src, name):
    return ((src.get("sources") or {}).get(name) or {}).get("status")


class _Idx:
    """The joins both readers share, built once per sources dict."""

    def __init__(self, src, label):
        self.merged = {}                     # (repo, n) -> merge ledger row (newest)
        for r in src.get("merges") or []:
            if r.get("status") != "merged":
                continue
            repo, n = pr_of_url(r.get("key"))
            if repo is None:
                continue
            old = self.merged.get((repo, n))
            if old is None or (_iso(r.get("updated_at")) or "") > (_iso(old.get("updated_at")) or ""):
                self.merged[(repo, n)] = r
        self.pulls = {}                      # (repo, n) -> pull row
        self.reverted = set()                # (repo, culprit n)
        for p in src.get("pulls") or []:
            repo = p.get("repo")
            if not repo or p.get("number") is None:
                continue
            self.pulls[(repo, int(p["number"]))] = p
            c = revert_culprit(p, repo, label)
            if c is not None:
                self.reverted.add((repo, c))
        self.ejected = parse_ejected(src.get("ejected"))
        self.pulls_ok = _status(src, "pulls") == "ok"
        self.ejected_ok = _status(src, "ejected") == "ok"

    def path(self, repo, n):
        r = self.merged.get((repo, n))
        return merge_path(r.get("detail")) if r else None


def _window_merges(src, since, until):
    """(repo, n, path, row) of every merge ledger row in the window."""
    out = []
    for r in src.get("merges") or []:
        if r.get("status") != "merged" or not _in(r.get("updated_at"), since, until):
            continue
        repo, n = pr_of_url(r.get("key"))
        if repo is not None:
            out.append((repo, n, merge_path(r.get("detail")), r))
    return out


def _batch_minutes(src, since, until):
    """repo -> (billed_min sum, batch rows) over batches completed in the window."""
    out = {}
    for b in src.get("ci_batches") or []:
        if not _in(b.get("completed_at"), since, until):
            continue
        try:
            m = float(b.get("billed_min") or 0)
        except (TypeError, ValueError):
            continue
        s, n = out.get(b.get("repo"), (0.0, 0))
        out[b.get("repo")] = (s + m, n + 1)
    return out


def _ci_rate(batches, repo, queued):
    """CI job-minutes per queued merge: None with no batch rows or 0 merges."""
    s, n = batches.get(repo, (0.0, 0))
    if not n or not queued:
        return None
    return round(s / queued, 1)


def _otm(secs, missing):
    return {"p50_s": pctl(secs, 0.5), "p90_s": pctl(secs, 0.9), "n": len(secs), "no_open_time": missing}


def block(src, since, until, repo_proj, label=MAIN_RED_LABEL):
    """Per project with landing activity in the window (a decision row of any
    mode, or a direct merge): merges by path, reverts of direct merges, CI
    job-minutes per merge, open->merge p50/p90 by path, shadow agreement."""
    since, until = _iso(since), _iso(until)
    ix = _Idx(src, label)
    batches = _batch_minutes(src, since, until)
    proj = lambda repo: repo_proj.get(repo) or repo
    decisions = [d for d in src.get("decisions") or [] if _in(d.get("at"), since, until)]
    merges = _window_merges(src, since, until)
    active = {proj(d.get("repo")) for d in decisions}
    active |= {proj(repo) for repo, _n, path, _r in merges if path == "direct"}
    out = {}
    for p in sorted(active):
        repos = sorted({r for r in [d.get("repo") for d in decisions] + [m[0] for m in merges] if proj(r) == p})
        mine = [m for m in merges if proj(m[0]) == p]
        direct = [m for m in mine if m[2] == "direct"]
        queued = [m for m in mine if m[2] == "queued"]
        otm = {}
        for name, rows in (("direct", direct), ("queued", queued)):
            secs, missing = [], 0
            for repo, n, _path, _r in rows:
                pr = ix.pulls.get((repo, n))
                if pr and _iso(pr.get("created_at")) and _iso(pr.get("merged_at")):
                    secs.append(_secs(_iso(pr["created_at"]), _iso(pr["merged_at"])))
                else:
                    missing += 1
            otm[name] = _otm(secs, missing)
        ci_q = None
        if len(repos) == 1:
            ci_q = _ci_rate(batches, repos[0], len(queued))
        elif queued:
            s = sum(batches.get(r, (0.0, 0))[0] for r in repos)
            ci_q = round(s / len(queued), 1) if any(batches.get(r, (0, 0))[1] for r in repos) else None
        # Shadow agreement: DISTINCT PRs with a mode=shadow, would=direct row in
        # the window, judged at the newest such row's head.
        shadow = {}
        for d in decisions:
            if proj(d.get("repo")) == p and d.get("mode") == "shadow" and d.get("would") == "direct":
                k = (d["repo"], int(d["number"]))
                if k not in shadow or int(d.get("id") or 0) > int(shadow[k].get("id") or 0):
                    shadow[k] = d
        agree = of = pending = 0
        for (repo, n), d in shadow.items():
            path = ix.path(repo, n)
            if path is None:
                pending += 1
                continue
            of += 1
            if path == "queued" and not is_ejected(ix.ejected, repo, n, d.get("head")) \
                    and (repo, n) not in ix.reverted:
                agree += 1
        # A revert count needs the pulls read, an agreement needs the pulls and
        # the ejected reads: a source that is not ok makes the figure None
        # ("n/a"), never a measured-looking 0 or 100% (the `landing sources:`
        # line says which source it was).
        if not (ix.pulls_ok and ix.ejected_ok):
            agree = None
        out[p] = {
            "repos": repos,
            "merges": {"direct": len(direct), "queued": len(queued)},
            "direct_reverted": None if not direct else
            {"reverted": sum(1 for repo, n, _p, _r in direct if (repo, n) in ix.reverted) if ix.pulls_ok else None,
             "of": len(direct)},
            "ci_min_per_merge": {"queued": ci_q, "direct": None, "why_direct": WHY_DIRECT_CI},
            "open_to_merge": otm,
            "shadow_agreement": {"agree": agree, "of": of,
                                 "rate": round(agree / of, 4) if of and agree is not None else None,
                                 "pending": pending},
        }
    return {"status": "ok", "window": {"since": since, "until": until},
            "sources": src.get("sources") or {}, "projects": out}


def _dur(secs):
    """bin/dora-digest.py dur(): the shortest thing a human reads."""
    if secs is None:
        return "n/a"
    s = int(round(secs))
    if s < 90:
        return "%ds" % s
    if s < 3600:
        return "%dm" % round(s / 60.0)
    if s < 172800:
        h, m = divmod(int(round(s / 60.0)), 60)
        return "%dh%02dm" % (h, m) if m else "%dh" % h
    d, h = divmod(int(round(s / 3600.0)), 24)
    return "%dd%dh" % (d, h) if h else "%dd" % d


def _na(v, fmt="%s"):
    return "n/a" if v is None else fmt % v


def _source_word(name, s):
    st = (s or {}).get("status") or "absent"
    return "%s %s%s" % (name, st, " (capped)" if (s or {}).get("capped") else "")


def text_lines(blk):
    """One line per project with landing activity, then one sources line.
    No project and no capped source: no line at all."""
    lines = []
    for p in sorted(blk.get("projects") or {}):
        b = blk["projects"][p]
        dr = b["direct_reverted"]
        o = b["open_to_merge"]
        sa = b["shadow_agreement"]
        if sa["rate"] is not None:
            shadow = "shadow agree %d of %d (%.1f%%, %d pending)" % (sa["agree"], sa["of"], 100.0 * sa["rate"], sa["pending"])
        elif sa["agree"] is None:
            shadow = "shadow agree n/a of %d (%d pending)" % (sa["of"], sa["pending"])
        else:
            shadow = "shadow agree n/a (%d pending)" % sa["pending"]
        lines.append(
            "landing %s: merges direct %d, queued %d; direct reverted %s; CI job-min/merge queued %s, direct n/a; "
            "open->merge direct p50 %s p90 %s, queued p50 %s p90 %s; %s"
            % (p, b["merges"]["direct"], b["merges"]["queued"],
               "n/a" if dr is None else "%s of %d" % (_na(dr["reverted"]), dr["of"]),
               _na(b["ci_min_per_merge"]["queued"], "%.1f"),
               _dur(o["direct"]["p50_s"]), _dur(o["direct"]["p90_s"]),
               _dur(o["queued"]["p50_s"]), _dur(o["queued"]["p90_s"]), shadow))
    srcs = blk.get("sources") or {}
    if lines or any((srcs.get(k) or {}).get("capped") for k in SOURCES):
        lines.append("landing sources: " + ", ".join(_source_word(k, srcs.get(k)) for k in SOURCES))
    return lines


def replay(src, since, until, last=None, label=MAIN_RED_LABEL):
    """What optimistic mode would have landed directly: per repo and in total,
    DISTINCT PRs with a would=direct row (any mode, judged at the newest such
    row's head), how many merged, were reverted, were ejected at that head,
    are still pending, and the CI minutes saved (would-direct PRs merged on the
    queued path x the repo's batch minutes per queued merge: an estimate)."""
    since, until = _iso(since), _iso(until)
    ix = _Idx(src, label)
    batches = _batch_minutes(src, since, until)
    dsrc = (src.get("sources") or {}).get("decisions") or {}
    failed = set((dsrc.get("failed") or []))
    rows = [d for d in src.get("decisions") or [] if _in(d.get("at"), since, until)]
    rows.sort(key=lambda d: -int(d.get("id") or 0))
    if last:
        rows = rows[:last]
    repos = sorted(set(dsrc.get("repos") or []) | {d.get("repo") for d in rows})
    queued_in_window = Counter(repo for repo, _n, path, _r in _window_merges(src, since, until) if path == "queued")
    out = {}
    for repo in repos:
        if repo in failed:
            out[repo] = {k: None for k in ("would_direct", "merged", "reverted", "ejected", "ci_min_saved",
                                           "pending", "no_open_time")}
            continue
        wd = {}
        for d in rows:
            if d.get("repo") == repo and d.get("would") == "direct":
                n = int(d["number"])
                if n not in wd or int(d.get("id") or 0) > int(wd[n].get("id") or 0):
                    wd[n] = d
        merged = [n for n in wd if ix.path(repo, n) is not None]
        mq = [n for n in merged if ix.path(repo, n) == "queued"]
        rate = _ci_rate(batches, repo, queued_in_window.get(repo, 0))
        out[repo] = {
            "would_direct": len(wd),
            "merged": len(merged),
            "reverted": sum(1 for n in wd if (repo, n) in ix.reverted) if ix.pulls_ok else None,
            "ejected": sum(1 for n, d in wd.items() if is_ejected(ix.ejected, repo, n, d.get("head")))
            if ix.ejected_ok else None,
            "ci_min_saved": round(len(mq) * rate, 1) if rate is not None else None,
            "ci_min_per_queued_merge": rate,
            "pending": len(wd) - len(merged),
            "no_open_time": sum(1 for n in merged if (repo, n) not in ix.pulls),
        }
    total = {}
    for k in ("would_direct", "merged", "reverted", "ejected", "ci_min_saved", "pending", "no_open_time"):
        vals = [out[r][k] for r in out]
        total[k] = None if not vals or any(v is None for v in vals) else \
            (round(sum(vals), 1) if k == "ci_min_saved" else sum(vals))
    reasons = Counter(d.get("reason") for d in rows if d.get("would") == "queue" and d.get("repo") not in failed)
    top = sorted(reasons.items(), key=lambda kv: (-kv[1], kv[0]))[:5]

    def fb(n, of):
        return {"n": n, "of": of, "rate": round(n / of, 4) if n is not None and of else None}
    srcs = src.get("sources") or {}
    return {"window": {"since": since, "until": until}, "last": last, "rows_replayed": len(rows),
            "repos": out, "total": total, "top_queue_reasons": [{"reason": r, "n": n} for r, n in top],
            "fallbacks": {"pending": fb(total["pending"], total["would_direct"]),
                          "no_open_time": fb(total["no_open_time"], total["merged"]),
                          "capped": sorted(k for k in SOURCES if (srcs.get(k) or {}).get("capped"))},
            "sources": srcs}


def replay_lines(res, days):
    """The source lines, the queue reasons, then the LANDING_REPLAY evidence
    rows last, so the paste for the flip is the tail of the output."""
    lines = []
    srcs = res.get("sources") or {}
    for k in SOURCES:
        s = srcs.get(k) or {}
        lines.append("source %s: %s%s%s" % (k, s.get("status") or "absent", " capped" if s.get("capped") else "",
                                            (" " + s["why"]) if s.get("why") else ""))
    top = res.get("top_queue_reasons") or []
    lines.append("top queue reasons: " + (" ".join("%s=%d" % (t["reason"], t["n"]) for t in top) or "none"))

    def row(label, v):
        return ("LANDING_REPLAY %s days=%s would_direct=%s merged=%s reverted=%s ejected=%s ci_min_saved=%s pending=%s"
                % (label, days, _na(v["would_direct"]), _na(v["merged"]), _na(v["reverted"]), _na(v["ejected"]),
                   _na(v["ci_min_saved"], "%.1f"), _na(v["pending"])))
    for repo in sorted(res.get("repos") or {}):
        lines.append(row("repo=" + repo, res["repos"][repo]))
    lines.append(row("total", res["total"]))
    return lines


def main(argv):
    """python3 bin/dora_landing.py replay <srcdir> <since> <until> [--days N] [--last N] [--json]"""
    if len(argv) < 4 or argv[0] != "replay":
        sys.stderr.write("usage: dora_landing.py replay <srcdir> <since> <until> [--days N] [--last N] "
                         "[--label L] [--json]\n")
        return 2
    srcdir, since, until = argv[1:4]
    last, as_json, days, label = None, False, None, MAIN_RED_LABEL
    rest = argv[4:]
    while rest:
        a = rest.pop(0)
        if a == "--json":
            as_json = True
        elif a in ("--last", "--days", "--label") and rest:
            v = rest.pop(0)
            if a == "--label":
                label = v
            elif not v.isdigit():
                sys.stderr.write("dora_landing.py: %s takes a number\n" % a)
                return 2
            elif a == "--last":
                last = int(v)
            else:
                days = int(v)
        else:
            sys.stderr.write("dora_landing.py: unknown argument %s\n" % a)
            return 2
    res = replay(load(srcdir), since, until, last, label)
    res["days"] = days
    if as_json:
        print(json.dumps(res, indent=1, sort_keys=True))
    else:
        print("\n".join(replay_lines(res, days if days is not None else "?")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
