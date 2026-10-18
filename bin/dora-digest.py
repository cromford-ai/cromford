#!/usr/bin/env python3
"""bin/dora-digest.py — the arithmetic behind bin/dora-digest.sh.

Reads the fleet's own records for a trailing window and writes two things: the
reproducible json (every metric carries the file it came from and how many lines
of it were read) and the plain-text message the digest posts. Contract, and how
to re-derive each figure by hand: docs/DORA.md.

TWO RULES RUN THROUGH ALL OF IT.

  A missing source is None with a reason, never 0. "n/a (source X absent)" and
  "0 merges" are different facts about the fleet, and a digest that renders them
  the same teaches the reader to distrust both.

  A rate names its own denominator. Conflict and rebuild rates are counted off
  logs/merge-conductor.log, so they divide by THAT log's merge count and the
  payload says so — not by the ledger's, which covers a slightly different set
  of PRs (the ledger is the better merge count and is reported as the headline,
  but mixing the two inside one ratio is two measurements wearing one name).

It is invoked with its inputs in the environment so the shell stays the only
thing that touches env/global.env, the worker and the beat.
"""
import csv
import glob
import json
import os
import re
import sys

ENV = os.environ
SINCE = ENV["DORA_SINCE"]
UNTIL = ENV["DORA_UNTIL"]
WINDOW = ENV.get("DORA_WINDOW_ARG", "24h")
HOURS = int(ENV.get("DORA_HOURS") or 24)
DAYS = int(ENV.get("DORA_DAYS") or 1)
LEDGER_FILE = ENV.get("DORA_LEDGER_FILE") or ""
REPOMAP = ENV.get("DORA_REPOMAP") or ""
MC_LOG = ENV.get("DORA_MC_LOG") or ""
BR_LOG = ENV.get("DORA_BR_LOG") or ""
COST_DIR = ENV.get("DORA_COST_DIR") or ""
QUOTA_DIR = ENV.get("DORA_QUOTA_DIR") or ""
LOGS_DIR = ENV.get("DORA_LOGS_DIR") or ""
BUILDS_DIR = ENV.get("DORA_BUILDS_DIR") or ""
WARN_PCT = float(ENV.get("DORA_WARN_PCT") or 80)
MAX_ROWS = int(ENV.get("DORA_MAX_ROWS") or 12)
OUT_JSON = ENV["DORA_OUT_JSON"]
OUT_TXT = ENV["DORA_OUT_TXT"]
# Touched when NEITHER merge source could be read, so the shell can page without
# needing jq to re-read the payload it just wrote. The paging path is the last
# place to make conditional on a tool being installed.
SENTINEL = ENV.get("DORA_SENTINEL") or ""
# bin/gh-budget-report.sh --json, run by the shell (BH-6974); the status is
# ok | off | error, and absent when the shell passed none.
GH_BUDGET_FILE = ENV.get("DORA_GH_BUDGET_FILE") or ""
GH_BUDGET_STATUS = ENV.get("DORA_GH_BUDGET_STATUS") or "absent"

NOTES = []


def note(msg):
    if msg not in NOTES:
        NOTES.append(msg)


# ── shared helpers ───────────────────────────────────────────────────────────
def norm_iso(s):
    """Any instant this fleet writes -> 'YYYY-MM-DDTHH:MM:SSZ', or None.

    The csvs are written by several lanes over two months and carry both `Z` and
    `+00:00`, with and without fractional seconds. Normalising to one shape is
    what lets the window filter be a string compare, which is the only reason a
    22k-row csv is cheap to slice.
    """
    if not s:
        return None
    s = s.strip()
    if s.endswith("+00:00"):
        s = s[:-6] + "Z"
    m = re.match(r"^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(?:\.\d+)?Z?$", s)
    return "%sT%sZ" % (m.group(1), m.group(2)) if m else None


def in_window(iso):
    return bool(iso) and SINCE <= iso <= UNTIL


def num(s):
    try:
        v = float(s)
    except (TypeError, ValueError):
        return None
    return v if v == v else None  # NaN is not a cost


def median(xs):
    xs = sorted(xs)
    if not xs:
        return None
    mid = len(xs) // 2
    return xs[mid] if len(xs) % 2 else (xs[mid - 1] + xs[mid]) / 2.0


def pct(part, whole, places=4):
    if not whole:
        return None
    return round(part / float(whole), places)


def dur(secs):
    """Seconds -> the shortest thing a human reads without converting."""
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


def usd(v):
    if v is None:
        return "n/a"
    if abs(v) >= 1000:
        return "$%s" % format(int(round(v)), ",d")
    if abs(v) >= 100:
        return "$%d" % round(v)
    return "$%.2f" % v


def rate(v):
    return "n/a" if v is None else "%d%%" % round(v * 100)


def mins_pp(b):
    """A box_test block -> the minutes-per-PR the message shows."""
    return "n/a" if b["per_pr_min"] is None else "%gm/PR" % b["per_pr_min"]


def count_lines(path):
    try:
        with open(path, "r", errors="replace") as fh:
            return sum(1 for _ in fh)
    except OSError:
        return None


# ── project <-> repo, from fleet.conf via bin/fleet-conf.sh ──────────────────
PROJ_REPO = {}
REPO_PROJ = {}
if REPOMAP and os.path.exists(REPOMAP):
    with open(REPOMAP, "r", errors="replace") as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if not parts or not parts[0]:
                continue
            repo = parts[1].strip() if len(parts) > 1 else ""
            PROJ_REPO[parts[0].strip()] = repo or None
            if repo and repo != "-":
                REPO_PROJ[repo] = parts[0].strip()
if not PROJ_REPO:
    note("fleet.conf was not readable, so repo->project attribution is by repo slug only")


def proj_of_repo(repo):
    return REPO_PROJ.get(repo) or repo


# ── source 1: the ledger's DORA route (best merges + lead time) ──────────────
LEDGER = {"status": "skipped", "path": "GET /api/metrics/dora?days=%d" % DAYS, "projects": 0}
LED_BY_PROJ = {}
LED_TOTALS = {}
if LEDGER_FILE and os.path.exists(LEDGER_FILE):
    try:
        with open(LEDGER_FILE, "r", errors="replace") as fh:
            payload = json.load(fh)
        for row in payload.get("projects") or []:
            name = row.get("project")
            if name:
                LED_BY_PROJ[name] = row
        LED_TOTALS = payload.get("totals") or {}
        LEDGER.update(status="ok", projects=len(LED_BY_PROJ),
                      window_days=payload.get("window", {}).get("days"),
                      as_of=payload.get("as_of"))
    except (OSError, ValueError) as exc:
        LEDGER.update(status="error", error=str(exc)[:200])
        note("the ledger DORA payload did not parse (%s) — merges fall back to the conductor log"
             % str(exc)[:80])
else:
    LEDGER["status"] = "absent"
    note("the harness-jobs /api/metrics/dora route was not read (worker unreachable, "
         "no HARNESS_SECRET, or DORA_LEDGER=0) — merges come from logs/merge-conductor.log "
         "and lead time is n/a")

# ── source 2: logs/merge-conductor.log (conflicts, and the merge fallback) ───
RE_STAMP = re.compile(r"^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})Z\s")
RE_MERGED = re.compile(r"(?:^|\s)MERGED ([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)#(\d+)\s")
RE_DIRTY = re.compile(r"([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)#(\d+) \S+ -> NEEDS_REBASE\b")

MC = {"status": "absent", "path": MC_LOG, "lines_total": None, "lines_in_window": 0}
mc_merged = {}   # repo -> set(pr number)
mc_dirty = {}    # repo -> set(pr number)
mc_dirty_lines = 0
if MC_LOG and os.path.exists(MC_LOG):
    MC["lines_total"] = count_lines(MC_LOG)
    seen = 0
    with open(MC_LOG, "r", errors="replace") as fh:
        for line in fh:
            m = RE_STAMP.match(line)
            if not m:
                continue
            if not in_window("%sT%sZ" % (m.group(1), m.group(2))):
                continue
            seen += 1
            g = RE_MERGED.search(line)
            if g:
                mc_merged.setdefault(g.group(1), set()).add(g.group(2))
            g = RE_DIRTY.search(line)
            if g:
                mc_dirty.setdefault(g.group(1), set()).add(g.group(2))
            if "merge=DIRTY" in line:
                mc_dirty_lines += 1
    MC.update(status="ok", lines_in_window=seen,
              merged_prs=sum(len(v) for v in mc_merged.values()),
              dirty_prs=sum(len(v) for v in mc_dirty.values()),
              dirty_lines=mc_dirty_lines,
              counted_by="DISTINCT <repo>#<pr>: 'MERGED <repo>#<n> by' for merges, "
                         "'-> NEEDS_REBASE' transitions for conflicts")
else:
    note("logs/merge-conductor.log is absent — conflict rate is n/a and the per-PR cost "
         "join has no merged-PR list to key on")

MERGED_URLS = set()
for repo, prs in mc_merged.items():
    for n in prs:
        MERGED_URLS.add("https://github.com/%s/pull/%s" % (repo, n))

# ── source 3: logs/blocked-resolver.log (rebuilds, lane deaths, red-twice) ───
RE_PARK = re.compile(
    r"^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})Z ([A-Za-z0-9._-]+)/(\S+) \[([^\]]+)\]"
)
BR = {"status": "absent", "path": BR_LOG, "lines_total": None, "lines_in_window": 0}
br_rebuilds = {}
br_deaths = {}
br_red_twice = {}
br_abandoned = {}
br_fix_rounds = {}
if BR_LOG and os.path.exists(BR_LOG):
    BR["lines_total"] = count_lines(BR_LOG)
    seen = 0
    with open(BR_LOG, "r", errors="replace") as fh:
        for line in fh:
            m = RE_PARK.match(line)
            if not m:
                continue
            if not in_window("%sT%sZ" % (m.group(1), m.group(2))):
                continue
            seen += 1
            proj, key, reason = m.group(3), m.group(4), m.group(5)
            # The resolver stamps the same park with and without the lane that
            # reported it (`conductor/red-twice`, `queue/pool-died-twice`); the
            # reason is the tail.
            reason = reason.rsplit("/", 1)[-1]
            tail = line[m.end():]
            if "REBUILD FRESH" in tail:
                br_rebuilds[proj] = br_rebuilds.get(proj, 0) + 1
            if "ABANDONED" in tail:
                br_abandoned.setdefault(proj, set()).add(key)
            if "FIX ROUND" in tail:
                br_fix_rounds[proj] = br_fix_rounds.get(proj, 0) + 1
            if "died" in reason:
                br_deaths.setdefault(proj, set()).add(key)
            if reason == "red-twice":
                br_red_twice.setdefault(proj, set()).add(key)
    BR.update(status="ok", lines_in_window=seen,
              rebuild_events=sum(br_rebuilds.values()),
              lane_deaths=sum(len(v) for v in br_deaths.values()),
              red_twice_prs=sum(len(v) for v in br_red_twice.values()),
              abandoned=sum(len(v) for v in br_abandoned.values()),
              fix_rounds=sum(br_fix_rounds.values()),
              counted_by="'REBUILD FRESH'/'FIX ROUND' as EVENTS; lane deaths, red-twice and "
                         "ABANDONED as DISTINCT <project>/<ticket key>")
else:
    note("logs/blocked-resolver.log is absent — rebuild rate, lane deaths and the RED_TWICE "
         "half of the change-failure proxy are n/a")

# ── source 4: state/cost/fleet-cost.csv ($ in the window) ────────────────────
FC_PATH = os.path.join(COST_DIR, "fleet-cost.csv") if COST_DIR else ""
FC = {"status": "absent", "path": FC_PATH, "rows_total": None, "rows_in_window": 0}
cost_proj = {}     # project -> {total, subscription, cash, unknown}
cost_acct = {}     # auth account -> the same
UNATTRIB = "(unattributed)"


def bucket():
    return {"total_usd": 0.0, "subscription_usd": 0.0, "cash_usd": 0.0,
            "unknown_billing_usd": 0.0, "rows": 0}


if FC_PATH and os.path.exists(FC_PATH):
    try:
        with open(FC_PATH, "r", errors="replace", newline="") as fh:
            rd = csv.DictReader(fh)
            cols = rd.fieldnames or []
            missing = [c for c in ("ts", "project", "cost_usd") if c not in cols]
            if missing:
                FC.update(status="error", error="header lacks %s" % ",".join(missing))
                note("state/cost/fleet-cost.csv header lacks %s — every $ figure is n/a"
                     % ",".join(missing))
            else:
                total_rows = 0
                unpriced = 0
                for row in rd:
                    total_rows += 1
                    if not in_window(norm_iso(row.get("ts"))):
                        continue
                    FC["rows_in_window"] += 1
                    c = num(row.get("cost_usd"))
                    if c is None:
                        unpriced += 1
                        c = 0.0
                    mode = (row.get("billing_mode") or "").strip()
                    field = ("subscription_usd" if mode == "subscription"
                             else "cash_usd" if mode == "metered"
                             else "unknown_billing_usd")
                    p = (row.get("project") or "").strip() or UNATTRIB
                    a = (row.get("auth_account") or "").strip() or UNATTRIB
                    for tab, k in ((cost_proj, p), (cost_acct, a)):
                        b = tab.setdefault(k, bucket())
                        b["total_usd"] += c
                        b[field] += c
                        b["rows"] += 1
                FC.update(status="ok", rows_total=total_rows,
                          unpriced_rows_in_window=unpriced,
                          columns_used="ts, project, cost_usd, billing_mode, auth_account "
                                       "(BY NAME — the column order has moved before)",
                          billing_map="billing_mode=subscription -> absorbed; metered -> cash; "
                                      "anything else -> unknown")
    except OSError as exc:
        FC.update(status="error", error=str(exc)[:200])
else:
    note("state/cost/fleet-cost.csv is absent — total $ and $/PR are n/a")

# ── source 5: state/cost/cost-per-pr.csv (the rollup's own per-PR price) ─────
CPP_PATH = os.path.join(COST_DIR, "cost-per-pr.csv") if COST_DIR else ""
CPP = {"status": "absent", "path": CPP_PATH, "rows_total": None, "matched_window_prs": 0}
pr_costs = {}   # repo -> [cost, ...]
if CPP_PATH and os.path.exists(CPP_PATH):
    try:
        with open(CPP_PATH, "r", errors="replace", newline="") as fh:
            rd = csv.DictReader(fh)
            cols = rd.fieldnames or []
            if "pr_url" not in cols or "cost_usd" not in cols:
                CPP.update(status="error", error="header lacks pr_url/cost_usd")
            else:
                total = 0
                for row in rd:
                    total += 1
                    url = (row.get("pr_url") or "").strip()
                    if url not in MERGED_URLS:
                        continue
                    c = num(row.get("cost_usd"))
                    if c is None:
                        continue
                    m = re.match(r"^https://github\.com/([^/]+/[^/]+)/pull/\d+$", url)
                    if m:
                        pr_costs.setdefault(m.group(1), []).append(c)
                        CPP["matched_window_prs"] += 1
                CPP.update(status="ok", rows_total=total,
                           joined_on="pr_url == the urls of the MERGED lines this window, "
                                     "from logs/merge-conductor.log",
                           note="cost-per-pr.csv carries no timestamp, so the window comes "
                                "from the merge log rather than from the csv")
    except OSError as exc:
        CPP.update(status="error", error=str(exc)[:200])
else:
    note("state/cost/cost-per-pr.csv is absent — the per-PR cross-check is n/a")

# ── source 6: state/quota/<account>.json (weekly caps) ───────────────────────
QD = {"status": "absent", "path": QUOTA_DIR, "files": 0}
quota = []
if QUOTA_DIR and os.path.isdir(QUOTA_DIR):
    files = sorted(p for p in glob.glob(os.path.join(QUOTA_DIR, "*.json"))
                   if not os.path.basename(p).startswith("."))
    QD.update(status="ok", files=len(files))
    for path in files:
        acct = os.path.basename(path)[:-5]
        try:
            with open(path, "r", errors="replace") as fh:
                q = json.load(fh)
        except (OSError, ValueError) as exc:
            quota.append({"account": acct, "status": "unreadable", "error": str(exc)[:120],
                          "weekly_pct": None, "weekly_resets_at": None})
            continue
        week = q.get("seven_day") or {}
        five = q.get("five_hour") or {}
        quota.append({
            "account": acct,
            "vendor": q.get("vendor"),
            "status": q.get("status") or "none",
            "source": q.get("source"),
            "polled_at": q.get("polled_at"),
            "weekly_pct": week.get("pct") if isinstance(week, dict) else None,
            "weekly_resets_at": week.get("resets_at") if isinstance(week, dict) else None,
            "five_hour_pct": five.get("pct") if isinstance(five, dict) else None,
            "five_hour_resets_at": five.get("resets_at") if isinstance(five, dict) else None,
            "error": q.get("error"),
        })
    if not files:
        note("state/quota/ holds no <account>.json — weekly cap headroom is n/a")
else:
    note("state/quota/ is absent — weekly cap headroom is n/a (bin/quota-poll.sh writes it)")

# ── source 7: logs/extra-usage-<account>.csv (cash overage) ──────────────────
EU = {"status": "absent", "path": os.path.join(LOGS_DIR, "extra-usage-*.csv") if LOGS_DIR else "",
      "files": 0}
overage = []
if LOGS_DIR and os.path.isdir(LOGS_DIR):
    files = sorted(glob.glob(os.path.join(LOGS_DIR, "extra-usage-*.csv")))
    EU.update(status="ok" if files else "absent", files=len(files))
    for path in files:
        acct = os.path.basename(path)[len("extra-usage-"):-len(".csv")]
        try:
            with open(path, "r", errors="replace", newline="") as fh:
                rows = list(csv.DictReader(fh))
        except OSError:
            continue
        if not rows:
            continue
        last = rows[-1]
        # The delta is measured from the last sample AT OR BEFORE the window
        # opened, so "spent in the window" is a difference of two meter reads
        # rather than a guess from one. With no earlier sample the first in-window
        # read is the baseline and the payload says the basis is partial.
        base, basis = None, "no baseline sample — delta is n/a"
        for r in rows:
            ts = norm_iso(r.get("ts"))
            if ts and ts < SINCE:
                base = r
        if base is not None:
            basis = "last sample before the window minus the newest sample"
        else:
            for r in rows:
                if in_window(norm_iso(r.get("ts"))):
                    base = r
                    basis = "PARTIAL: no sample predates the window, so the first in-window read is the baseline"
                    break
        d = None
        if base is not None:
            a, b = num(base.get("extra_used_usd")), num(last.get("extra_used_usd"))
            if a is not None and b is not None:
                d = round(b - a, 2)
        overage.append({
            "account": acct, "source": path,
            "samples": len(rows), "last_sample_at": norm_iso(last.get("ts")),
            "extra_used_usd": num(last.get("extra_used_usd")),
            "extra_limit_usd": num(last.get("extra_limit_usd")),
            "extra_pct": num(last.get("extra_pct")),
            "in_overage": (last.get("in_overage") or "").strip() == "1",
            "weekly_pct": num(last.get("weekly_pct")),
            "weekly_resets_at": last.get("weekly_resets_at") or None,
            "window_delta_usd": d, "window_delta_basis": basis,
        })
    if not files:
        note("no logs/extra-usage-*.csv on this box — cash overage per account is n/a")
else:
    note("the logs directory is unreadable — cash overage per account is n/a")

# ── source 8: builds/<dir>/pipeline.log (minutes spent running repo suites) ──
# bin/run-build.sh's STAGE_END writes one STAGE-TIMING line per stage, and the
# three stages a repo's own suite runs under are `suite` (before the lenses read
# the diff), `suite-fix` and `suite-head`. Nothing else in that file measures
# how long the box spends on somebody else's tests.
#
# Attribution is the build DIR's name, because the line's own [project/KEY] tag
# is the project the BUILD was for and a relayed build is copied to the hub
# under a marker: bin/fly-results-ingest.sh writes fly-<project>-<KEY>-<stamp>,
# and bin/project-of.sh --prefix strips pool- for the same reason.
RE_SUITE = re.compile(r"\sSTAGE-TIMING (suite|suite-fix|suite-head) start=\d+ end=\d+ secs=(\d+)\b")
BT = {"status": "absent",
      "path": os.path.join(BUILDS_DIR, "*/pipeline.log") if BUILDS_DIR else "",
      "build_dirs": 0, "logs_read": 0, "lines_in_window": 0, "unattributed_builds": 0}
bt_secs, bt_runs, bt_builds = {}, {}, {}   # project -> seconds / lines / set(dir)


def proj_of_build_dir(name):
    """A builds/ directory name -> the project it was built for, or None.

    Longest registered name wins, the way bin/project-of.sh sorts its list: a
    project whose name prefixes another's ("sib" before "sib-nav") would
    otherwise claim the longer one's builds.
    """
    head = name
    for marker in ("fly-", "pool-"):
        if head.startswith(marker):
            head = head[len(marker):]
            break
    best = None
    for p in PROJ_REPO:
        if head.startswith(p + "-") and (best is None or len(p) > len(best)):
            best = p
    return best


if BUILDS_DIR and os.path.isdir(BUILDS_DIR):
    try:
        build_dirs = sorted(os.listdir(BUILDS_DIR))
        BT["status"] = "ok"
    except OSError as exc:
        build_dirs = []
        BT.update(status="error", error=str(exc)[:200])
        note("the builds directory could not be listed (%s) — box test minutes per PR are n/a"
             % str(exc)[:80])
    for d in build_dirs:
        path = os.path.join(BUILDS_DIR, d, "pipeline.log")
        if not os.path.isfile(path):
            continue
        BT["build_dirs"] += 1
        key = proj_of_build_dir(d)
        if key is None:
            # Its minutes are real and go in the fleet total; what is missing is
            # the row to put them on, and the count says how often that happens.
            BT["unattributed_builds"] += 1
            key = UNATTRIB
        try:
            fh = open(path, "r", errors="replace")
        except OSError:
            continue
        BT["logs_read"] += 1
        with fh:
            for line in fh:
                m = RE_STAMP.match(line)
                if not m:
                    continue
                if not in_window("%sT%sZ" % (m.group(1), m.group(2))):
                    continue
                g = RE_SUITE.search(line)
                if not g:
                    continue
                BT["lines_in_window"] += 1
                bt_secs[key] = bt_secs.get(key, 0) + int(g.group(2))
                bt_runs[key] = bt_runs.get(key, 0) + 1
                bt_builds.setdefault(key, set()).add(d)
    if BT["status"] == "ok":
        BT["counted_by"] = ("STAGE-TIMING suite|suite-fix|suite-head secs= summed per build dir "
                            "whose name starts with <project>- (after an optional fly-/pool- copy "
                            "marker); the line's stamp must be in the window")
else:
    note("builds/ is absent — box test minutes per PR are n/a (bin/run-build.sh writes the "
         "STAGE-TIMING suite lines into builds/<dir>/pipeline.log)")

BT_SOURCE = ("builds/[fly-|pool-]<project>-*/pipeline.log STAGE-TIMING suite/suite-fix/"
             "suite-head lines in the window")
# "there is no builds/ here" and "builds/ is there and would not open" are
# different facts, and the n/a says which one it is.
BT_NA = ("n/a (source builds/ absent)" if BT["status"] == "absent"
         else "n/a (source builds/ could not be read)")

# ── the rows ─────────────────────────────────────────────────────────────────
# Row identity is the PROJECT, because every source but the conductor log is
# project-keyed and fleet.conf maps one repo to each. A repo that merged
# something and is in no registry becomes its own row rather than vanishing.
names = set(PROJ_REPO)
for repo in mc_merged:
    names.add(proj_of_repo(repo))
for repo in mc_dirty:
    names.add(proj_of_repo(repo))
names |= set(LED_BY_PROJ)
names |= set(br_rebuilds) | set(br_deaths) | set(br_red_twice) | set(br_abandoned)

MC_OK = MC["status"] == "ok"
BR_OK = BR["status"] == "ok"
FC_OK = FC["status"] == "ok"
BT_OK = BT["status"] == "ok"

rows = []
for name in sorted(names):
    repo = PROJ_REPO.get(name) or (name if "/" in name else None)
    led = LED_BY_PROJ.get(name)
    repos = [repo] if repo else []
    if led and led.get("repos"):
        repos = sorted(set(repos) | set(led["repos"]))
    mc_m = sum(len(mc_merged.get(r, ())) for r in repos) if MC_OK else None
    mc_d = sum(len(mc_dirty.get(r, ())) for r in repos) if MC_OK else None
    merged = led.get("merged") if led else mc_m
    merged_src = ("ledger /api/metrics/dora projects[].merged (ledgers kind=merge)"
                  if led else
                  "logs/merge-conductor.log 'MERGED <repo>#<n>' lines (the ledger was not read)"
                  if MC_OK else None)
    lt = (led or {}).get("lead_time") or {}
    llt = (led or {}).get("launch_lead_time") or {}
    rebuilds = br_rebuilds.get(name) if BR_OK else None
    deaths = br_deaths.get(name, set()) if BR_OK else None
    red2 = br_red_twice.get(name, set()) if BR_OK else None
    # A readable csv with no rows for this project measured $0 — which is a
    # different fact from "the csv was unreadable", and only the second is n/a.
    cb = (cost_proj.get(name) or bucket()) if FC_OK else None
    # The same distinction for suite minutes: a readable builds/ with no build
    # for this project measured 0 minutes, which is not the same fact as having
    # no builds/ to read.
    bt_s = bt_secs.get(name, 0) if BT_OK else None
    prc = [c for r in repos for c in pr_costs.get(r, [])]
    reverts = (led.get("change_failure") or {}).get("bad") if led else None
    n_red2 = len(red2) if red2 is not None else None
    cfp_bad = None if reverts is None and n_red2 is None else (reverts or 0) + (n_red2 or 0)

    row = {
        "project": name,
        "repos": repos,
        "merged": merged,
        "merged_source": merged_src,
        "merged_conductor_log": mc_m,
        "lead_time": {
            "p50_s": lt.get("p50_s"), "p90_s": lt.get("p90_s"), "n": lt.get("n"),
            "basis": lt.get("basis"),
            "source": ("ledger /api/metrics/dora projects[].lead_time — jobs.created_at "
                       "(ticket claimed) to the merge, per PR"
                       if led else None),
        } if led else {"p50_s": None, "p90_s": None, "n": 0, "basis": None,
                       "source": None,
                       "unavailable": "n/a (source /api/metrics/dora absent — no other record "
                                      "carries the instant the ticket was claimed)"},
        # The second clock: filed → first spawn. A worker that predates BH-482
        # sends no such key, and an absent key is absent, never 0 — "we start
        # instantly" is the one wrong answer this metric can give.
        "launch_lead_time": {
            "p50_s": llt.get("p50_s"), "p90_s": llt.get("p90_s"), "n": llt.get("n"),
            "basis": llt.get("basis"),
            "source": ("ledger /api/metrics/dora projects[].launch_lead_time — "
                       "jobs.issue_created_at → jobs.first_spawn_at"),
            "unavailable": None,
        } if llt else {"p50_s": None, "p90_s": None, "n": None, "basis": None,
                       "source": None,
                       "unavailable": "n/a (source /api/metrics/dora launch_lead_time absent)"},
        "conflict": {
            "rate": pct(mc_d, mc_m) if (MC_OK and mc_m) else None,
            "dirty_prs": mc_d, "denominator": mc_m,
            "denominator_source": "logs/merge-conductor.log merges in the window — the SAME log "
                                  "the numerator is counted from",
            "source": ("logs/merge-conductor.log '-> NEEDS_REBASE' transitions, DISTINCT PRs"
                       if MC_OK else None),
            "unavailable": None if MC_OK else "n/a (source logs/merge-conductor.log absent)",
        },
        "rebuild": {
            "rate": pct(rebuilds or 0, mc_m) if (BR_OK and MC_OK and mc_m) else None,
            "rebuilds": rebuilds, "denominator": mc_m if MC_OK else None,
            "denominator_source": "logs/merge-conductor.log merges in the window",
            "source": ("logs/blocked-resolver.log 'REBUILD FRESH n of m' events"
                       if BR_OK else None),
            "unavailable": None if BR_OK else "n/a (source logs/blocked-resolver.log absent)",
        },
        "lane_deaths": {
            "count": len(deaths) if deaths is not None else None,
            "tickets": sorted(deaths) if deaths else [],
            "source": ("logs/blocked-resolver.log parks whose reason names a dead lane "
                       "(pool-died, pool-died-twice), DISTINCT tickets" if BR_OK else None),
            "unavailable": None if BR_OK else "n/a (source logs/blocked-resolver.log absent)",
        },
        "abandoned": len(br_abandoned.get(name, ())) if BR_OK else None,
        "fix_rounds": br_fix_rounds.get(name, 0) if BR_OK else None,
        "change_failure_proxy": {
            "rate": pct(cfp_bad, merged) if (cfp_bad is not None and merged) else None,
            "bad": cfp_bad, "reverts_or_reopens": reverts, "red_twice": n_red2,
            "denominator": merged,
            "main_red": (led.get("change_failure") or {}).get("main_red") if led else None,
            "source": "ledger outcome_metrics(reverted|reopened, DISTINCT pr) PLUS "
                      "logs/blocked-resolver.log red-twice parks, over the merge count above",
            "unavailable": None if cfp_bad is not None else
                           "n/a (neither /api/metrics/dora nor logs/blocked-resolver.log was read)",
        },
        "cost": {
            "total_usd": round(cb["total_usd"], 2) if cb else None,
            "subscription_usd": round(cb["subscription_usd"], 2) if cb else None,
            "cash_usd": round(cb["cash_usd"], 2) if cb else None,
            "unknown_billing_usd": round(cb["unknown_billing_usd"], 2) if cb else None,
            "rows": cb["rows"] if cb else None,
            "per_pr_usd": (round(cb["total_usd"] / merged, 2)
                           if cb and merged else None),
            "per_pr_basis": "every fleet-cost.csv row for this project in the window, divided by "
                            "the merge count above (so triage and preplan spend that opened no PR "
                            "is IN it — that is the CFO number, not the build-only one)",
            "source": ("state/cost/fleet-cost.csv rows where project matches and ts is in the "
                       "window" if FC_OK else None),
            "unavailable": None if FC_OK else "n/a (source state/cost/fleet-cost.csv absent)",
            "attributed": {
                "n": len(prc), "sum_usd": round(sum(prc), 2) if prc else None,
                "median_usd": round(median(prc), 2) if prc else None,
                "source": "state/cost/cost-per-pr.csv, joined on the PRs this window merged",
            },
        },
        "box_test": {
            "minutes": round(bt_s / 60.0, 1) if BT_OK else None,
            "per_pr_min": round(bt_s / 60.0 / merged, 1) if (BT_OK and merged) else None,
            "runs": bt_runs.get(name, 0) if BT_OK else None,
            "builds": len(bt_builds.get(name, ())) if BT_OK else None,
            "denominator": merged,
            "denominator_source": merged_src,
            "source": BT_SOURCE if BT_OK else None,
            "unavailable": None if BT_OK else BT_NA,
        },
    }
    rows.append(row)

# A project with nothing in the window is not a finding; the fleet total already
# covers it. Rows are what somebody would act on.
def busy(r):
    return bool(r["merged"] or r["conflict"]["dirty_prs"] or r["rebuild"]["rebuilds"]
                or (r["lane_deaths"]["count"] or 0) or (r["cost"]["total_usd"] or 0)
                or (r["change_failure_proxy"]["bad"] or 0))


quiet = [r["project"] for r in rows if not busy(r)]
rows = [r for r in rows if busy(r)]
rows.sort(key=lambda r: (-(r["merged"] or 0), -(r["cost"]["total_usd"] or 0), r["project"]))

# ── the fleet total ──────────────────────────────────────────────────────────
row_names = set(r["project"] for r in rows)
known = set(PROJ_REPO) | row_names
non_repo = {k: round(v["total_usd"], 2) for k, v in cost_proj.items()
            if k not in known and v["total_usd"]} if FC_OK else {}

fleet_merged = LED_TOTALS.get("merged") if LED_TOTALS else (
    sum(len(v) for v in mc_merged.values()) if MC_OK else None)
mc_total_merged = sum(len(v) for v in mc_merged.values()) if MC_OK else None
mc_total_dirty = sum(len(v) for v in mc_dirty.values()) if MC_OK else None
total_rebuilds = sum(br_rebuilds.values()) if BR_OK else None
total_deaths = sum(len(v) for v in br_deaths.values()) if BR_OK else None
total_red2 = sum(len(v) for v in br_red_twice.values()) if BR_OK else None
total_reverts = LED_TOTALS.get("bad") if LED_TOTALS else None
total_bad = None if total_reverts is None and total_red2 is None else \
    (total_reverts or 0) + (total_red2 or 0)
all_cost = round(sum(v["total_usd"] for v in cost_proj.values()), 2) if FC_OK else None
repo_cost = round(sum(r["cost"]["total_usd"] or 0 for r in rows), 2) if FC_OK else None
cash = round(sum(v["cash_usd"] for v in cost_proj.values()), 2) if FC_OK else None
subs = round(sum(v["subscription_usd"] for v in cost_proj.values()), 2) if FC_OK else None
unkn = round(sum(v["unknown_billing_usd"] for v in cost_proj.values()), 2) if FC_OK else None
led_lead = (LED_TOTALS.get("lead_time") or {}) if LED_TOTALS else {}
led_launch = (LED_TOTALS.get("launch_lead_time") or {}) if LED_TOTALS else {}
# Every key, the unattributed builds included: the fleet spent those minutes
# whether or not a dir name could be resolved to a row.
total_bt = sum(bt_secs.values()) if BT_OK else None

fleet = {
    "merged": fleet_merged,
    "merged_source": ("ledger /api/metrics/dora totals.merged" if LED_TOTALS
                      else "logs/merge-conductor.log MERGED lines" if MC_OK else None),
    "merged_conductor_log": mc_total_merged,
    "projects_with_activity": len(rows),
    "quiet_projects": quiet,
    "lead_time": {"p50_s": led_lead.get("p50_s"), "p90_s": led_lead.get("p90_s"),
                  "n": led_lead.get("n"),
                  "source": "ledger /api/metrics/dora totals.lead_time" if led_lead else None,
                  "unavailable": None if led_lead else
                                 "n/a (source /api/metrics/dora absent)"},
    "launch_lead_time": {"p50_s": led_launch.get("p50_s"), "p90_s": led_launch.get("p90_s"),
                         "n": led_launch.get("n"),
                         "source": "ledger /api/metrics/dora totals.launch_lead_time"
                                   if led_launch else None,
                         "unavailable": None if led_launch else
                                        "n/a (source /api/metrics/dora launch_lead_time absent)"},
    "conflict": {"rate": pct(mc_total_dirty, mc_total_merged) if mc_total_merged else None,
                 "dirty_prs": mc_total_dirty, "dirty_log_lines": mc_dirty_lines if MC_OK else None,
                 "denominator": mc_total_merged},
    "rebuild": {"rate": pct(total_rebuilds or 0, mc_total_merged)
                        if (BR_OK and mc_total_merged) else None,
                "rebuilds": total_rebuilds, "denominator": mc_total_merged},
    "lane_deaths": total_deaths,
    "abandoned": sum(len(v) for v in br_abandoned.values()) if BR_OK else None,
    "fix_rounds": sum(br_fix_rounds.values()) if BR_OK else None,
    "change_failure_proxy": {
        "rate": pct(total_bad, fleet_merged) if (total_bad is not None and fleet_merged) else None,
        "bad": total_bad, "reverts_or_reopens": total_reverts, "red_twice": total_red2,
        "denominator": fleet_merged},
    "cost": {
        "total_usd": all_cost, "repo_usd": repo_cost, "non_repo_usd": non_repo,
        "subscription_usd": subs, "cash_usd": cash, "unknown_billing_usd": unkn,
        "per_pr_usd": (round(repo_cost / fleet_merged, 2)
                       if repo_cost is not None and fleet_merged else None),
        "per_pr_usd_all_in": (round(all_cost / fleet_merged, 2)
                              if all_cost is not None and fleet_merged else None),
        "per_pr_basis": "per_pr_usd divides the repo rows' spend by the merges; "
                        "per_pr_usd_all_in adds the lanes that belong to no repo "
                        "(alert triage, the medic, fleet chores) — both are named because the "
                        "second is what the bill actually is",
    },
    "box_test": {
        "minutes": round(total_bt / 60.0, 1) if BT_OK else None,
        "per_pr_min": (round(total_bt / 60.0 / fleet_merged, 1)
                       if (BT_OK and fleet_merged) else None),
        "runs": sum(bt_runs.values()) if BT_OK else None,
        "builds": sum(len(v) for v in bt_builds.values()) if BT_OK else None,
        "unattributed_builds": BT["unattributed_builds"] if BT_OK else None,
        "denominator": fleet_merged,
        "source": BT_SOURCE if BT_OK else None,
        "unavailable": None if BT_OK else BT_NA,
    },
}

accounts = sorted(
    ({"account": k, "cost_usd": round(v["total_usd"], 2),
      "subscription_usd": round(v["subscription_usd"], 2),
      "cash_usd": round(v["cash_usd"], 2),
      "unknown_billing_usd": round(v["unknown_billing_usd"], 2), "rows": v["rows"]}
     for k, v in cost_acct.items()),
    key=lambda a: -a["cost_usd"]) if FC_OK else []

# ── who spends the GitHub REST budget (BH-6974) ─────────────────────────────
gh_budget = {"status": GH_BUDGET_STATUS}
if GH_BUDGET_STATUS == "ok":
    try:
        with open(GH_BUDGET_FILE) as fh:
            ghb = json.load(fh)
        gh_budget = {
            "status": "ok", "source": ghb.get("source"), "file": ghb.get("state_file"),
            "window": ghb.get("window"), "totals": ghb.get("totals"), "merged": ghb.get("merged"),
            "per_merged_pr": ghb.get("per_merged_pr"), "top": (ghb.get("top") or [])[:5],
        }
    except (OSError, ValueError, AttributeError):
        gh_budget = {"status": "error"}

payload = {
    "generated_at": UNTIL,
    "window": {"arg": WINDOW, "hours": HOURS, "ledger_days": DAYS,
               "since": SINCE, "until": UNTIL},
    "row_key": "project — fleet.conf maps one repo to each; a repo in no registry rows under "
               "its own slug",
    "sources": {
        "ledger_dora": LEDGER, "conductor_log": MC, "resolver_log": BR,
        "fleet_cost_csv": FC, "cost_per_pr_csv": CPP, "quota_dir": QD, "extra_usage_csv": EU,
        "builds_pipeline_logs": BT,
    },
    "repos": rows,
    "fleet": fleet,
    "accounts": accounts,
    "quota": quota,
    "cash_overage": overage,
    "notes": NOTES,
    "gh_budget": gh_budget,
}

# >>> conflicts block (BH-6965)
# The conflict ladder's own numbers, per row and for the fleet: DIRTY events,
# rebuilds per 100 merges, fix-round-conflict ok/failed, DIRTY-to-clean minutes
# and repair wakes. The parsing is bin/dora_conflicts.py; this section only
# places its blocks and makes the alert decision on the TRAILING 24 h, whatever
# the window is, so a `--window 7d` run still answers the alert's question.
try:
    import dora_conflicts  # noqa: E402  (bin/ is on sys.path: it is this script's dir)
except ImportError:
    # A box (or a fixture) without bin/dora_conflicts.py still writes the
    # digest: every conflicts figure is null with the reason, and no alert.
    dora_conflicts = None
from datetime import datetime as _dt, timedelta as _td  # noqa: E402


def _cf_missing(*_args):
    why = "n/a (bin/dora_conflicts.py is not installed)"
    keys = ("dirty_events", "merges", "rebuilds", "rebuilds_per_100",
            "fix_round_conflict", "dirty_to_clean_min", "repair_wakes")

    def blk():
        b = dict.fromkeys(keys)
        b["unavailable"] = {k: why for k in keys if k not in ("merges", "rebuilds")}
        return b
    fl = blk()
    fl["source"] = {}
    return {"projects": {}, "fleet": fl, "sources": {}, "empty": blk()}


_cf_compute = dora_conflicts.compute if dora_conflicts else _cf_missing
_cf_over = dora_conflicts.over_threshold if dora_conflicts else (lambda _p, _t: [])

CF_ROP_LOG = ENV.get("DORA_ROP_LOG") or ""
CF_BR_STATE = ENV.get("DORA_BR_STATE") or ""
CF_ALERT_FILE = ENV.get("DORA_CONFLICTS_ALERT_FILE") or ""
try:
    CF_THRESHOLD = int(ENV.get("DORA_CONFLICTS_ALERT_PER_100") or 40)
except ValueError:
    CF_THRESHOLD = 40
CF_THRESHOLD_SRC = ENV.get("DORA_CONFLICTS_ALERT_SRC") or "default"
CF_ARGS = (MC_LOG, BR_LOG, CF_BR_STATE, CF_ROP_LOG, REPO_PROJ)
cf = _cf_compute(SINCE, UNTIL, *CF_ARGS)
CF_SINCE_24 = (_dt.strptime(UNTIL, "%Y-%m-%dT%H:%M:%SZ") - _td(hours=24)).strftime("%Y-%m-%dT%H:%M:%SZ")
cf24 = cf if HOURS == 24 else _cf_compute(CF_SINCE_24, UNTIL, *CF_ARGS)
for r in rows:
    r["conflicts"] = cf["projects"].get(r["project"]) or dict(cf["empty"])
cf_over = _cf_over(cf24["projects"], CF_THRESHOLD)
cf_line = None
if cf_over:
    cf_line = ("[dora-conflicts] REBUILDS OVER %d PER 100 MERGES in the trailing 24h: %s. "
               "Source: %s 'REBUILD FRESH' events over %s merges. Needs: a look at the "
               "conflict ladder of %s (repair-on-push, the fix-round-conflict rung). "
               "Threshold: settings row conflicts.rebuild_alert_per_100 (%d, %s)."
               % (CF_THRESHOLD,
                  ", ".join("%s %d rebuilds / %d merges (%.1f per 100)" % o for o in cf_over),
                  BR_LOG, MC_LOG, ", ".join(o[0] for o in cf_over),
                  CF_THRESHOLD, CF_THRESHOLD_SRC))
fleet["conflicts"] = dict(cf["fleet"])
fleet["conflicts"].update(
    alert_threshold=CF_THRESHOLD, alert_threshold_source=CF_THRESHOLD_SRC,
    alert={"window": "trailing 24h", "since": CF_SINCE_24, "until": UNTIL,
           "rule": "per project: rebuilds * 100 / merges strictly over the threshold; "
                   "no merges is n/a, never over",
           "over": [{"project": o[0], "rebuilds": o[1], "merges": o[2], "rebuilds_per_100": o[3]}
                    for o in cf_over],
           "trailing_24h": {p: {"rebuilds": b["rebuilds"], "merges": b["merges"],
                                "rebuilds_per_100": b["rebuilds_per_100"]}
                            for p, b in sorted(cf24["projects"].items())
                            if b["rebuilds"] or b["merges"]},
           "line": cf_line})
payload["sources"].update(cf["sources"])
if cf_line and CF_ALERT_FILE:
    with open(CF_ALERT_FILE, "w") as fh:
        fh.write(cf_line + "\n")
# <<< conflicts block

# >>> review block (BH-6969)
# PRs by review tier and mode, verdict flips, reverts and main-red culprits by
# tier, review $ per PR by tier, and the 7-day revert rate per cohort (low,
# intent, full). The counting is bin/dora_review.py; this section places the
# block, and writes the alert text when a cohort is over the margin and no
# read the rate depends on was capped. A failure here is status error, never
# a digest crash.
try:
    import dora_review  # noqa: E402  (bin/ is on sys.path: it is this script's dir)
except ImportError:
    dora_review = None
RV_STATUS = ENV.get("DORA_REVIEW_STATUS") or "off"
RV_WHY = ENV.get("DORA_REVIEW_WHY") or ""
RV_MARGIN = ENV.get("DORA_REVIEW_MARGIN") or "0.02"
RV_MARGIN_SRC = ENV.get("DORA_REVIEW_MARGIN_SRC") or "default"
RV_MIN_N = ENV.get("DORA_REVIEW_MIN_N") or ""
RV_MIN_N = int(RV_MIN_N) if RV_MIN_N.isdigit() else 5
RV_MIN_N_SRC = ENV.get("DORA_REVIEW_MIN_N_SRC") or "default"
RV_ALERT_FILE = ENV.get("DORA_REVIEW_ALERT_FILE") or ""
RV_SINCE_7D = (_dt.strptime(UNTIL, "%Y-%m-%dT%H:%M:%SZ") - _td(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ")
review = {"status": RV_STATUS, "margin": RV_MARGIN, "margin_source": RV_MARGIN_SRC,
          "min_n": RV_MIN_N, "min_n_source": RV_MIN_N_SRC,
          "window": {"since": SINCE, "until": UNTIL}, "revert_7d_window": {"since": RV_SINCE_7D,
                                                                         "until": UNTIL},
          "groups": None, "revert_7d": None, "incomplete": None, "unavailable": None,
          "alert": {"rule": "per cohort (low, intent): reverted/merged over the trailing 7d, by the "
                            "verdict that decided each PR, minus the full cohort's, strictly over "
                            "the margin; a cohort (or the full cohort) with fewer than min_n "
                            "merges is not compared",
                    "over": [], "withheld": None, "line": None}}
if RV_STATUS == "ok" and dora_review is None:
    review.update(status="error", unavailable="n/a (bin/dora_review.py is not installed)")
elif RV_STATUS == "ok":
    try:
        with open(ENV.get("DORA_REVIEW_FILE") or "") as fh:
            rv_body = json.load(fh)
        rv = dora_review.compute(rv_body, SINCE, UNTIL, RV_SINCE_7D,
                                 os.path.join(COST_DIR, "cost-per-pr.csv") if COST_DIR else "",
                                 ENV.get("DORA_REVIEW_COST_STAGE_RE") or "review")
        rv_over = [] if rv["alert_withheld"] else dora_review.over_margin(rv["revert_7d"], RV_MARGIN, RV_MIN_N)
        rv_line = dora_review.alert_line(rv_over, RV_MARGIN, RV_MARGIN_SRC)
        review.update(groups=rv["groups"], revert_7d=rv["revert_7d"], incomplete=rv["incomplete"],
                      rows=rv["rows"], sources=rv["sources"])
        review["alert"].update(over=rv_over, withheld=rv["alert_withheld"], line=rv_line)
        if rv_line and RV_ALERT_FILE:
            with open(RV_ALERT_FILE, "w") as fh:
                fh.write(rv_line + "\n")
    except Exception as exc:  # noqa: BLE001 — the block must never take the digest down
        review.update(status="error", groups=None, revert_7d=None,
                      unavailable="n/a (the review block failed: %s)" % type(exc).__name__)
else:
    review["unavailable"] = "n/a (%s)" % (RV_WHY or RV_STATUS)
fleet["review"] = review
# <<< review block

with open(OUT_JSON, "w") as fh:
    json.dump(payload, fh, indent=1, sort_keys=False)
    fh.write("\n")

if SENTINEL and LEDGER["status"] != "ok" and MC["status"] != "ok":
    with open(SENTINEL, "w") as fh:
        fh.write("both merge sources unreadable\n")

# ── the plain-text message ───────────────────────────────────────────────────
# Short lines, one repo per line, no markdown: this is read on a phone, in a
# Telegram topic, beside lines from six other lanes.
L = []
L.append("DORA + unit economics — %s to %s" % (WINDOW, UNTIL))
f = fleet
L.append("fleet: %s merged, lead p50 %s p90 %s, launch p50 %s p90 %s, conflict %s, rebuild %s, "
         "%s lane death(s), CFR %s"
         % (f["merged"] if f["merged"] is not None else "n/a",
            dur(f["lead_time"]["p50_s"]), dur(f["lead_time"]["p90_s"]),
            dur(f["launch_lead_time"]["p50_s"]), dur(f["launch_lead_time"]["p90_s"]),
            rate(f["conflict"]["rate"]), rate(f["rebuild"]["rate"]),
            f["lane_deaths"] if f["lane_deaths"] is not None else "n/a",
            rate(f["change_failure_proxy"]["rate"])))
L.append("fleet $: %s total (%s repos + %s other lanes), all-in %s/PR, cash %s, absorbed %s, "
         "box test %s"
         % (usd(f["cost"]["total_usd"]), usd(f["cost"]["repo_usd"]),
            usd(round(sum(non_repo.values()), 2)) if non_repo else ("$0" if FC_OK else "n/a"),
            usd(f["cost"]["per_pr_usd_all_in"]), usd(f["cost"]["cash_usd"]),
            usd(f["cost"]["subscription_usd"]), mins_pp(f["box_test"])))
if not rows:
    L.append("no repo had merges, conflicts, rebuilds or spend in this window")
for r in rows[:MAX_ROWS]:
    L.append("%s: %s merged, lead %s/%s, launch %s/%s, conflict %s, rebuild %s, deaths %s, "
             "CFR %s, %s/PR (%s), box test %s"
             % (r["project"],
                r["merged"] if r["merged"] is not None else "n/a",
                dur(r["lead_time"]["p50_s"]), dur(r["lead_time"]["p90_s"]),
                dur(r["launch_lead_time"]["p50_s"]), dur(r["launch_lead_time"]["p90_s"]),
                rate(r["conflict"]["rate"]), rate(r["rebuild"]["rate"]),
                r["lane_deaths"]["count"] if r["lane_deaths"]["count"] is not None else "n/a",
                rate(r["change_failure_proxy"]["rate"]),
                usd(r["cost"]["per_pr_usd"]), usd(r["cost"]["total_usd"]),
                mins_pp(r["box_test"])))
if len(rows) > MAX_ROWS:
    L.append("(%d more repo(s) in the json)" % (len(rows) - MAX_ROWS))

# >>> conflicts lines (BH-6965)
def cf_text(b):
    parts = ["dirty %s" % ("n/a" if b["dirty_events"] is None else b["dirty_events"])]
    if b["rebuilds_per_100"] is not None:
        parts.append("rebuilds %.1f/100 merges (%d of %d)"
                     % (b["rebuilds_per_100"], b["rebuilds"], b["merges"]))
    elif b["rebuilds"] is not None and b["merges"] is not None:
        parts.append("rebuilds n/a (%d, no merges)" % b["rebuilds"])
    else:
        parts.append("rebuilds n/a")
    fx = b["fix_round_conflict"]
    parts.append("fix-round-conflict n/a" if fx is None
                 else "fix-round-conflict ok %d failed %d" % (fx["ok"], fx["failed"]))
    d = b["dirty_to_clean_min"]
    if d is None:
        parts.append("dirty->clean n/a")
    elif d["n"]:
        parts.append("dirty->clean p50 %.1fm p90 %.1fm (n=%d, %d open)"
                     % (d["p50"], d["p90"], d["n"], d["open"]))
    else:
        parts.append("dirty->clean n/a (n=0, %d open)" % d["open"])
    parts.append("repair wakes %s" % ("n/a" if b["repair_wakes"] is None else b["repair_wakes"]))
    return ", ".join(parts)


def cf_active(b):
    d = b["dirty_to_clean_min"] or {}
    fx = b["fix_round_conflict"] or {}
    return bool(b["dirty_events"] or b["rebuilds"] or fx.get("ok") or fx.get("failed")
                or d.get("n") or d.get("open") or b["repair_wakes"])


L.append("conflicts (fleet): " + cf_text(fleet["conflicts"]))
for r in rows[:MAX_ROWS]:
    if cf_active(r["conflicts"]):
        L.append("conflicts %s: %s" % (r["project"], cf_text(r["conflicts"])))
# <<< conflicts lines

# >>> review lines (BH-6969)
def rv_text(k, b):
    c = b["cost"]
    if c["priced"]:
        cost = "review %s/PR of %s/PR (%d priced)" % (usd(c["review_usd_per_pr"]),
                                                     usd(c["total_usd_per_pr"]), c["priced"])
    else:
        cost = "cost n/a"
    return ("review %s: reviewed %d, merged %d, flips %d, reverts %d, culprits %d, %s"
            % (k, b["reviewed"], b["merged"], b["flips"], b["reverts"], b["main_red_culprits"], cost))


def rv_rate(b):
    if not b["merged"]:
        return "n/a (0 merged)"
    return "%d/%d (%s)" % (b["reverted"], b["merged"], rate(b["rate"]))


if review["status"] == "ok":
    if not review["groups"]:
        L.append("review (fleet): no reviewed or merged PR in this window")
    for k in sorted(review["groups"]):
        L.append(rv_text(k, review["groups"][k]))
    r7 = review["revert_7d"]
    L.append("review 7d reverts: %s; margin %s (%s)%s"
             % (", ".join("%s %s" % (c, rv_rate(r7[c])) for c in ("low", "intent", "full")),
                review["margin"], review["margin_source"],
                "; INCOMPLETE (%s read capped), alert withheld" % "/".join(review["incomplete"])
                if review["alert"]["withheld"] else
                ("; INCOMPLETE (%s read capped)" % "/".join(review["incomplete"])
                 if review["incomplete"] else "")))
elif review["status"] == "off":
    L.append("review: off (%s)" % (RV_WHY or "not configured"))
else:
    L.append("review: " + review["unavailable"])
# <<< review lines

top = [a for a in accounts if a["cost_usd"] > 0][:4]
if top:
    L.append("by account: " + " | ".join(
        "%s %s (cash %s)" % (a["account"], usd(a["cost_usd"]), usd(a["cash_usd"])) for a in top))

qrows = [q for q in quota if q.get("weekly_pct") is not None]
if qrows:
    qrows.sort(key=lambda q: -q["weekly_pct"])
    L.append("weekly caps: " + " | ".join(
        "%s %g%%%s resets %s" % (q["account"], q["weekly_pct"],
                                 " HOT" if q["weekly_pct"] >= WARN_PCT else "",
                                 (norm_iso(q["weekly_resets_at"]) or q["weekly_resets_at"] or "?"))
        for q in qrows[:6]))
blind = [q["account"] for q in quota if q.get("weekly_pct") is None]
if blind:
    L.append("caps unreadable: %s (no weekly number — these accounts cannot self-report)"
             % ", ".join(blind[:6]))
if not quota:
    L.append("weekly caps: n/a (source state/quota/ absent)")

for o in overage:
    L.append("cash %s: %s used of %s (%s%%)%s, %s in this window"
             % (o["account"], usd(o["extra_used_usd"]), usd(o["extra_limit_usd"]),
                "%g" % o["extra_pct"] if o["extra_pct"] is not None else "?",
                ", IN OVERAGE" if o["in_overage"] else "",
                usd(o["window_delta_usd"]) if o["window_delta_usd"] is not None else "n/a"))
if not overage:
    L.append("cash overage: n/a (no logs/extra-usage-*.csv on this box)")

src = []
src.append("ledger %s" % (("%d projects" % LEDGER["projects"]) if LEDGER["status"] == "ok"
                          else LEDGER["status"]))
src.append("conductor.log %s" % (("%d lines in window" % MC["lines_in_window"])
                                 if MC["status"] == "ok" else MC["status"]))
src.append("resolver.log %s" % (("%d lines" % BR["lines_in_window"])
                                if BR["status"] == "ok" else BR["status"]))
src.append("fleet-cost.csv %s" % (("%d rows" % FC["rows_in_window"])
                                  if FC["status"] == "ok" else FC["status"]))
src.append("cost-per-pr.csv %s" % (("%d PRs matched" % CPP["matched_window_prs"])
                                   if CPP["status"] == "ok" else CPP["status"]))
src.append("builds/ %s" % (("%d lines in window" % BT["lines_in_window"])
                           if BT_OK else BT["status"]))
if gh_budget["status"] == "ok":
    t = gh_budget.get("totals") or {}
    pp = (gh_budget.get("per_merged_pr") or {}).get("counted")
    L.append("github REST: %s calls, %s charged, %s/merged PR; top pollers: %s"
             % (t.get("rest_calls", "n/a"), t.get("rest_counted", "n/a"),
                ("%g" % pp) if isinstance(pp, (int, float)) else "n/a",
                " | ".join("%s %s %s" % (p.get("lane"), p.get("path_class"), p.get("counted"))
                           for p in gh_budget.get("top") or []) or "none"))
elif gh_budget["status"] != "off":
    L.append("github REST: n/a (%s)" % gh_budget["status"])
L.append("sources: " + ", ".join(src))
for n in NOTES[:4]:
    L.append("note: " + n)
L.append("every number's source + line counts: " + OUT_JSON)

with open(OUT_TXT, "w") as fh:
    fh.write("\n".join(L) + "\n")
sys.exit(0)
