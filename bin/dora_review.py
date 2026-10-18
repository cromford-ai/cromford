"""bin/dora_review.py — the `review` block of the daily DORA digest (BH-6969).

Pure: no env reads, no writes. bin/dora-digest.py imports it and hands it the
body of GET /api/metrics/review-tiers (worker/jobs/src/routes/review-tiers.js)
plus the window and the path of state/cost/cost-per-pr.csv. The rules, and how
to re-derive each figure by hand, are in docs/DORA.md ("review block").

  cohort(row)        low | intent | full | None for one verdict row
  group_key(row)     "<review_tier or untiered>/<mode>", or "untiered"
  compute(...)       the per-group figures and the 7-day revert rate per cohort
  over_margin(...)   the cohorts whose 7-day revert rate is over full + margin,
                     counting only cohorts (and a full cohort) of min_n merges
  alert_line(...)    the one [dora-review-tiers] ALERTS line, or None

Absent is None with a reason, never 0: a PR with no cost-per-pr.csv row is
unpriced, not $0, and a cohort with no merges has no rate.
"""
import csv
import re
from fractions import Fraction

COHORTS = ("low", "intent", "full")
COHORT_MODE = {"low": "risk-tier", "intent": "intent", "full": "full"}
NO_VERDICT = "no-verdict"
UNTIERED = "untiered"
# The reads whose cap makes a revert rate unknowable. A capped culprits read
# changes no rate, so it marks the block incomplete but does not withhold.
RATE_READS = ("merges", "verdicts", "reverts")
READS = ("merges", "verdicts", "reverts", "culprits")
_CULPRIT_KEY = re.compile(r"^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)@[0-9a-f]{40}$")
_ISO = re.compile(r"^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(?:\.\d+)?(?:Z|\+00:00)?$")


def cohort(row):
    """The review a verdict row stands for. The words are exact: the worker
    refuses any other spelling, so a near miss is not guessed into a cohort."""
    src = row.get("source")
    mode = row.get("review_mode")
    if mode == "risk-tier" or src == "risk-tier":
        return "low"
    if mode == "intent":
        return "intent"
    if mode == "full":
        return "full"
    # Before BH-6967 every lead review was a full review and wrote no mode.
    if src == "lead" and mode is None:
        return "full"
    return None


def group_key(row):
    c = cohort(row)
    if c is None:
        return UNTIERED
    return "%s/%s" % (row.get("review_tier") or UNTIERED, COHORT_MODE[c])


def _iso(s):
    m = _ISO.match((s or "").strip()) if isinstance(s, str) else None
    return "%sT%sZ" % (m.group(1), m.group(2)) if m else None


def _url(repo, pr):
    return ("https://github.com/%s/pull/%s" % (repo, pr)).lower()


def _pr_key(repo, pr):
    """A PR url, lower-cased; a bare number becomes the url of `repo`."""
    s = str(pr if pr is not None else "").strip()
    if s.lower().startswith("https://"):
        return s.lower()
    if s.isdigit() and repo:
        return _url(repo, int(s))
    return None


def _num(s):
    try:
        v = float(s)
    except (TypeError, ValueError):
        return None
    return v if v == v else None


def _word(verdict):
    if verdict == "BLOCK":
        return "block"
    if verdict in ("MERGE", "MERGE-WITH-NOTES"):
        return "merge"
    return None


def _read_costs(path, stage_re):
    """pr_url (lower-cased) -> (review_usd, total_usd), and the source record."""
    src = {"path": path, "status": "absent", "rows": None, "stage_re": stage_re.pattern}
    costs = {}
    if not path:
        return costs, src
    try:
        with open(path, "r", errors="replace", newline="") as fh:
            rd = csv.DictReader(fh)
            cols = rd.fieldnames or []
            if not {"pr_url", "cost_usd", "stage_breakdown"} <= set(cols):
                src.update(status="error", error="header lacks pr_url/cost_usd/stage_breakdown")
                return costs, src
            n = 0
            for row in rd:
                n += 1
                url = (row.get("pr_url") or "").strip().lower()
                total = _num(row.get("cost_usd"))
                if not url or total is None:
                    continue
                review = 0.0
                for part in (row.get("stage_breakdown") or "").split(";"):
                    stage, _, usd = part.rpartition(":")
                    v = _num(usd)
                    if stage and v is not None and stage_re.search(stage):
                        review += v
                costs[url] = (review, total)
            src.update(status="ok", rows=n)
    except FileNotFoundError:
        pass
    except OSError as exc:
        src.update(status="error", error=str(exc)[:200])
    return costs, src


def _blank():
    return {"reviewed": 0, "merged": 0, "flips": 0, "reverts": 0, "main_red_culprits": 0,
            "_review_usd": 0.0, "_total_usd": 0.0, "_priced": 0, "_unpriced": 0}


def compute(payload, since, until, since_7d, cpp_path, stage_re="review"):
    """The block, from the route body. since/until bound the listing window;
    since_7d..until is the window of the 7-day revert rate per cohort."""
    payload = payload or {}
    try:
        sre = re.compile(stage_re or "review", re.I)
    except re.error:
        sre = re.compile("review", re.I)

    def inw(at, lo=since):
        return bool(at) and lo <= at <= until

    # Verdict rows, oldest first by id; a row with no usable stamp is dropped.
    vrows = []
    for r in payload.get("verdicts") or []:
        at = _iso(r.get("created_at"))
        if at is None or not r.get("repo") or r.get("pr") is None or r.get("id") is None:
            continue
        vrows.append(dict(r, created_at=at, _key=_url(r["repo"], r["pr"])))
    vrows.sort(key=lambda r: r["id"])
    by_pr = {}
    for r in vrows:
        by_pr.setdefault(r["_key"], []).append(r)

    def deciding(key, before=None):
        last = None
        for r in by_pr.get(key, ()):
            if before is None or r["created_at"] <= before:
                last = r
        return last

    groups = {}

    def g(k):
        return groups.setdefault(k, _blank())

    # reviewed: PRs with a row in the window, under the newest such row.
    for key, rs in by_pr.items():
        inr = [r for r in rs if inw(r["created_at"])]
        if inr:
            g(group_key(inr[-1]))["reviewed"] += 1

    # flips: consecutive rows on one (repo, pr, head) whose word class differs.
    last_word = {}
    for r in vrows:
        w = _word(r.get("verdict"))
        if w is None:
            continue
        hk = (r["_key"], str(r.get("head_sha") or "").lower())
        prev = last_word.get(hk)
        last_word[hk] = w
        if prev is not None and prev != w and inw(r["created_at"]):
            g(group_key(r))["flips"] += 1

    # merged PRs, keyed by url, each with the verdict that decided it.
    merged = {}
    for m in payload.get("merges") or []:
        url = str(m.get("pr_url") or "").strip().lower()
        at = _iso(m.get("merged_at"))
        if not url or at is None:
            continue
        if url not in merged or at < merged[url]:
            merged[url] = at
    decided = {}
    for url, at in merged.items():
        d = deciding(url, at)
        decided[url] = (group_key(d) if d else NO_VERDICT, cohort(d) if d else None)

    reverted = set()
    for o in payload.get("reverts") or []:
        if o.get("outcome", "reverted") != "reverted":
            continue
        k = _pr_key(o.get("repo"), o.get("pr"))
        if k:
            reverted.add(k)

    costs, cost_src = _read_costs(cpp_path, sre)
    for url, at in merged.items():
        if not inw(at):
            continue
        b = g(decided[url][0])
        b["merged"] += 1
        if url in reverted:
            b["reverts"] += 1
        if cost_src["status"] == "ok":
            if url in costs:
                b["_priced"] += 1
                b["_review_usd"] += costs[url][0]
                b["_total_usd"] += costs[url][1]
            else:
                b["_unpriced"] += 1

    # main-red culprits: the PR a bisect pinned, under the verdict that decided it.
    culprit_rows = 0
    for c in payload.get("culprits") or []:
        m = _CULPRIT_KEY.match(str(c.get("key") or ""))
        pr = c.get("pr")
        if isinstance(pr, str) and pr.isdigit():
            pr = int(pr)
        if not m or isinstance(pr, bool) or not isinstance(pr, int) or pr <= 0:
            continue
        if not inw(_iso(c.get("updated_at"))):
            continue
        culprit_rows += 1
        url = _url(m.group(1), pr)
        if url in decided:
            k = decided[url][0]
        else:
            d = deciding(url)
            k = group_key(d) if d else NO_VERDICT
        g(k)["main_red_culprits"] += 1

    # 7-day revert rate per cohort.
    r7 = {c: {"merged": 0, "reverted": 0} for c in COHORTS}
    for url, at in merged.items():
        c = decided[url][1]
        if c is None or not inw(at, since_7d):
            continue
        r7[c]["merged"] += 1
        if url in reverted:
            r7[c]["reverted"] += 1
    for c in COHORTS:
        n, v = r7[c]["merged"], r7[c]["reverted"]
        r7[c]["rate"] = round(v / float(n), 4) if n else None

    cost_na = None if cost_src["status"] == "ok" else \
        "n/a (state/cost/cost-per-pr.csv %s)" % cost_src["status"]
    out = {}
    for k in sorted(groups):
        b = groups[k]
        p = b.pop("_priced")
        rv, tot, unp = b.pop("_review_usd"), b.pop("_total_usd"), b.pop("_unpriced")
        if cost_na:
            b["cost"] = {"priced": None, "unpriced": None, "review_usd_per_pr": None,
                         "total_usd_per_pr": None, "unavailable": cost_na}
        else:
            b["cost"] = {"priced": p, "unpriced": unp,
                         "review_usd_per_pr": round(rv / p, 2) if p else None,
                         "total_usd_per_pr": round(tot / p, 2) if p else None,
                         "unavailable": None if p else "n/a (no merged PR in this group has a "
                                                       "cost-per-pr.csv row)"}
        out[k] = b

    capped = payload.get("capped") or {}
    incomplete = [k for k in READS if capped.get(k)]
    withheld = [k for k in RATE_READS if k in incomplete]
    return {
        "groups": out,
        "revert_7d": r7,
        "incomplete": incomplete,
        "alert_withheld": ("the %s read hit its LIMIT" % "/".join(withheld)) if withheld else None,
        "rows": {"merges": len(merged), "verdicts": len(vrows), "reverts": len(reverted),
                 "culprits": culprit_rows},
        "sources": {"route": "GET /api/metrics/review-tiers", "cost_per_pr_csv": cost_src},
    }


MIN_N_DEFAULT = 5


def over_margin(revert_7d, margin, min_n=MIN_N_DEFAULT):
    """The low and intent cohorts whose 7-day revert rate is strictly more than
    `margin` over the full cohort's, in exact fractions. No merges is no rate,
    and no rate is never over. A cohort with fewer than `min_n` merges (and a
    full cohort under it) is too small to compare: 1 revert in 1 merge is not
    a trend (settings row review.tier_revert_min_n)."""
    m = Fraction(str(margin))
    n_min = max(int(min_n), 1)
    full = revert_7d.get("full") or {}
    if (full.get("merged") or 0) < n_min:
        return []
    fr = Fraction(full.get("reverted", 0), full["merged"])
    out = []
    for c in ("low", "intent"):
        r = revert_7d.get(c) or {}
        if (r.get("merged") or 0) < n_min:
            continue
        if Fraction(r.get("reverted", 0), r["merged"]) - fr > m:
            out.append({"cohort": c, "reverted": r.get("reverted", 0), "merged": r["merged"],
                        "full_reverted": full.get("reverted", 0), "full_merged": full["merged"]})
    return out


def _pct(n, d):
    return "%.1f%%" % (100.0 * n / d)


def alert_line(over, margin, margin_src):
    """One line for every cohort over, or None."""
    if not over:
        return None
    f = over[0]
    return ("[dora-review-tiers] 7-DAY REVERT RATE OVER THE FULL REVIEW TIER: %s vs full %d/%d (%s). "
            "Source: outcome_metrics reverted rows over ledgers merges, by the verdict that decided "
            "each PR (GET /api/metrics/review-tiers). Needs: a look at which PRs the %s review "
            "passed that were reverted. Margin: settings row review.tier_revert_margin (%s, %s)."
            % (", ".join("%s %d/%d (%s)" % (o["cohort"], o["reverted"], o["merged"],
                                            _pct(o["reverted"], o["merged"])) for o in over),
               f["full_reverted"], f["full_merged"], _pct(f["full_reverted"], f["full_merged"]),
               " and ".join(o["cohort"] for o in over), margin, margin_src))
