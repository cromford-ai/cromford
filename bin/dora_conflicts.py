"""bin/dora_conflicts.py — the `conflicts` block of the DORA digest (BH-6965).

Imported by bin/dora-digest.py; a pure module: it reads the four files it is
handed and returns numbers. It reads no environment and writes no file.

  compute(since, until, mc_log, br_log, br_state_dir, rop_log, repo_proj)
      -> {"projects": {name: block}, "fleet": block, "sources": {...},
          "empty": the block of a project no source named}
  over_threshold(projects, threshold) -> [(project, rebuilds, merges, per_100)]

A block, for the window [since, until] (ISO 'YYYY-MM-DDTHH:MM:SSZ'):
  dirty_events        conductor transitions `<slug>#<n> <prev> -> NEEDS_REBASE`,
                      EVENTS (a PR that goes DIRTY twice is 2)
  merges, rebuilds    DISTINCT `MERGED <slug>#<n> by` PRs in the conductor log,
                      and `REBUILD FRESH` park lines in the resolver log
  rebuilds_per_100    rebuilds * 100 / merges, 1 place; None with no merges
  fix_round_conflict  {ok, failed}: resolver record attempts in the window
                      whose detail carries ` · fix-round-conflict ok|failed`
  dirty_to_clean_min  {p50, p90, n, open}: one episode per PR, opened by a
                      `-> NEEDS_REBASE` transition or a REPAIR rebase conflict,
                      closed by a non-DIRTY transition, a MERGED line or a
                      REPAIR rebase pushed. Nearest-rank percentiles.
  repair_wakes        distinct wake ids repair-on-push finished reading
  unavailable         {figure: "n/a (...)"} for every figure that is None

A missing source is None with a reason, never 0 (the digest's own rule).
"""
import glob
import json
import math
import os
import re
from datetime import datetime, timezone

STAMP = r"(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})Z"
SLUG = r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+"
RE_TRANS = re.compile(r"^%s (%s)#(\d+) (\S+) -> (\S+) .*? merge=(\S+)" % (STAMP, SLUG))
RE_MERGED = re.compile(r"^%s\s(?:.*\s)?MERGED (%s)#(\d+) by\b" % (STAMP, SLUG))
RE_REBUILD = re.compile(r"^%s ([A-Za-z0-9._-]+)/\S+ \[[^\]]+\].*REBUILD FRESH" % STAMP)
RE_ROP_STAMP = re.compile(r"^%s\s" % STAMP)
RE_REPAIR = re.compile(r"REPAIR pr=(\d+|-) files=\d+ action=(\w+) reason=(\S+) repo=(\S+) wake=(\d+)")
RE_RANGE = re.compile(r"wake=(\d+) repo=(\S+) range=")
RE_LEFT = re.compile(r"wake=(\d+) left for next tick")
# The mergeStates that say the PR is not DIRTY. `-` (unknown) and DIRTY do not close.
CLEAN_STATES = {"CLEAN", "UNSTABLE", "BLOCKED", "HAS_HOOKS", "BEHIND"}
FIX_OK = " · fix-round-conflict ok"
FIX_FAILED = " · fix-round-conflict failed"

SRC_MC = "logs/merge-conductor.log"
SRC_BR = "logs/blocked-resolver.log"
SRC_REC = "state/blocked-resolver"
SRC_ROP = "logs/repair-on-push.log"

FIGURE_SOURCES = {
    "dirty_events": SRC_MC + " '<slug>#<n> <prev> -> NEEDS_REBASE' transitions, EVENTS",
    "rebuilds_per_100": SRC_BR + " 'REBUILD FRESH' events x 100 / " + SRC_MC
                        + " DISTINCT 'MERGED <slug>#<n> by' PRs (the rebuild.rate denominator)",
    "fix_round_conflict": SRC_REC + "/<project>/<key>.json attempts[] whose 'at' is in the window "
                          "and whose detail carries ' · fix-round-conflict ok|failed' (BH-6964)",
    "dirty_to_clean_min": SRC_MC + " transitions + MERGED lines and " + SRC_ROP
                          + " 'REPAIR ... action=rebase reason=conflict|pushed' lines; one "
                          "episode per PR, opened and closed in the window; nearest rank",
    "repair_wakes": SRC_ROP + " DISTINCT wake=<id> on REPAIR and range= lines, minus wakes whose "
                    "last line in the window is 'left for next tick'",
}


def _iso(day, clock):
    return "%sT%sZ" % (day, clock)


def _epoch(iso):
    return datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()


def _norm_at(s):
    m = re.match(r"^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(?:\.\d+)?Z?$", (s or "").strip())
    return _iso(m.group(1), m.group(2)) if m else None


def _rank(xs, p):
    """Nearest rank: sorted[ceil(p*n)-1]."""
    xs = sorted(xs)
    return xs[max(0, int(math.ceil(p * len(xs))) - 1)]


def _per_100(rebuilds, merges):
    if rebuilds is None or not merges:
        return None
    return round(rebuilds * 100.0 / merges, 1)


def _lines(path):
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            yield line.rstrip("\n")


def compute(since, until, mc_log, br_log, br_state_dir, rop_log, repo_proj):
    """Parses the four sources into per-project and fleet conflict blocks."""
    lower_map = {r.lower(): p for r, p in (repo_proj or {}).items()}

    def proj_or_slug(repo):
        return lower_map.get(repo.lower()) or repo

    def inw(iso):
        return bool(iso) and since <= iso <= until

    mc_ok = bool(mc_log) and os.path.exists(mc_log)
    br_ok = bool(br_log) and os.path.exists(br_log)
    rec_ok = bool(br_state_dir) and os.path.isdir(br_state_dir)
    rop_ok = bool(rop_log) and os.path.exists(rop_log)
    sources = {
        "repair_on_push_log": {"status": "ok" if rop_ok else "absent", "path": rop_log,
                               "lines_in_window": 0},
        "resolver_records": {"status": "ok" if rec_ok else "absent", "path": br_state_dir,
                             "files_read": 0, "files_skipped_stale": 0, "files_unreadable": 0,
                             "attempts_in_window": 0},
    }

    dirty = {}       # project -> events
    merged = {}      # project -> set((repo lower, pr))
    rebuilds = {}    # project -> events
    fix = {}         # project -> {"ok", "failed"}
    events = []      # (iso, order, seq, kind, project, key)
    wakes = {}       # wake id -> {"repo": slug or None, "last": kind}

    seq = 0
    if mc_ok:
        for line in _lines(mc_log):
            m = RE_TRANS.match(line)
            if m:
                iso = _iso(m.group(1), m.group(2))
                if not inw(iso):
                    continue
                repo, num, new, ms = m.group(3), m.group(4), m.group(6), m.group(7)
                p = proj_or_slug(repo)
                key = (repo.lower(), num)
                if new == "NEEDS_REBASE":
                    dirty[p] = dirty.get(p, 0) + 1
                    events.append((iso, 0, seq, "open", p, key))
                elif ms in CLEAN_STATES:
                    events.append((iso, 0, seq, "close", p, key))
                seq += 1
                continue
            m = RE_MERGED.match(line)
            if m:
                iso = _iso(m.group(1), m.group(2))
                if not inw(iso):
                    continue
                repo, num = m.group(3), m.group(4)
                p = proj_or_slug(repo)
                merged.setdefault(p, set()).add((repo.lower(), num))
                events.append((iso, 0, seq, "close", p, (repo.lower(), num)))
                seq += 1

    if br_ok:
        for line in _lines(br_log):
            m = RE_REBUILD.match(line)
            if m and inw(_iso(m.group(1), m.group(2))):
                rebuilds[m.group(3)] = rebuilds.get(m.group(3), 0) + 1

    if rec_ok:
        since_epoch = _epoch(since)
        st = sources["resolver_records"]
        for path in sorted(glob.glob(os.path.join(br_state_dir, "*", "*.json"))):
            p = os.path.basename(os.path.dirname(path))
            try:
                if os.path.getmtime(path) < since_epoch:
                    # Any attempt in the window rewrote the file, so an older
                    # file holds none; skipped unread.
                    st["files_skipped_stale"] += 1
                    continue
                with open(path, "r", encoding="utf-8", errors="replace") as fh:
                    rec = json.load(fh)
                attempts = rec.get("attempts") or []
            except (OSError, ValueError, AttributeError):
                st["files_unreadable"] += 1
                continue
            st["files_read"] += 1
            for a in attempts:
                if not isinstance(a, dict) or not inw(_norm_at(a.get("at"))):
                    continue
                st["attempts_in_window"] += 1
                detail = a.get("detail") or ""
                b = fix.setdefault(p, {"ok": 0, "failed": 0})
                if FIX_OK in detail:
                    b["ok"] += 1
                elif FIX_FAILED in detail:
                    b["failed"] += 1

    if rop_ok:
        st = sources["repair_on_push_log"]
        for line in _lines(rop_log):
            m = RE_ROP_STAMP.match(line)
            if not m:
                continue
            iso = _iso(m.group(1), m.group(2))
            if not inw(iso):
                continue
            st["lines_in_window"] += 1
            r = RE_REPAIR.search(line)
            if r:
                pr, action, reason, repo, wid = r.groups()
                w = wakes.setdefault(wid, {"repo": None, "last": None})
                w["repo"], w["last"] = repo, "read"
                if pr != "-" and action == "rebase" and reason in ("conflict", "pushed"):
                    kind = "open" if reason == "conflict" else "close"
                    events.append((iso, 1, seq, kind, proj_or_slug(repo), (repo.lower(), pr)))
                    seq += 1
                continue
            r = RE_RANGE.search(line)
            if r:
                w = wakes.setdefault(r.group(1), {"repo": None, "last": None})
                w["repo"], w["last"] = r.group(2), "read"
                continue
            r = RE_LEFT.search(line)
            if r:
                wakes.setdefault(r.group(1), {"repo": None, "last": None})["last"] = "left"

    # Episodes: the conductor and repair logs merged in stamp order, the
    # conductor first on a tie (a stable sort on (iso, order, seq)).
    open_at = {}     # key -> (iso, project)
    durations = {}   # project -> [minutes]
    for iso, _o, _s, kind, p, key in sorted(events):
        if kind == "open":
            open_at.setdefault(key, (iso, p))
        elif key in open_at:
            t0, p0 = open_at.pop(key)
            durations.setdefault(p0, []).append((_epoch(iso) - _epoch(t0)) / 60.0)
    still_open = {}
    for _t0, p0 in open_at.values():
        still_open[p0] = still_open.get(p0, 0) + 1

    consumed = {}    # project -> set(wake id)
    fleet_wakes = set()
    for wid, w in wakes.items():
        if w["last"] != "read":
            continue
        fleet_wakes.add(wid)
        p = lower_map.get((w["repo"] or "").lower())
        if p:
            consumed.setdefault(p, set()).add(wid)

    def block(n_dirty, n_merges, n_rebuilds, fx, durs, n_open, n_wakes):
        unavailable = {}
        b = {"dirty_events": n_dirty if mc_ok else None,
             "merges": n_merges if mc_ok else None,
             "rebuilds": n_rebuilds if br_ok else None,
             "rebuilds_per_100": None,
             "fix_round_conflict": fx if rec_ok else None,
             "dirty_to_clean_min": None,
             "repair_wakes": n_wakes if rop_ok else None}
        if not mc_ok:
            unavailable["dirty_events"] = "n/a (source %s absent)" % SRC_MC
        if not br_ok:
            unavailable["rebuilds_per_100"] = "n/a (source %s absent)" % SRC_BR
        elif not mc_ok:
            unavailable["rebuilds_per_100"] = "n/a (source %s absent)" % SRC_MC
        elif not n_merges:
            unavailable["rebuilds_per_100"] = "n/a (no merges in the window)"
        else:
            b["rebuilds_per_100"] = _per_100(n_rebuilds, n_merges)
        if not rec_ok:
            unavailable["fix_round_conflict"] = "n/a (source %s absent)" % SRC_REC
        if mc_ok or rop_ok:
            b["dirty_to_clean_min"] = {
                "p50": round(_rank(durs, 0.5), 1) if durs else None,
                "p90": round(_rank(durs, 0.9), 1) if durs else None,
                "n": len(durs), "open": n_open,
                "partial": None if (mc_ok and rop_ok) else
                           "only %s was read" % (SRC_MC if mc_ok else SRC_ROP)}
        else:
            unavailable["dirty_to_clean_min"] = "n/a (sources %s and %s absent)" % (SRC_MC, SRC_ROP)
        if not rop_ok:
            unavailable["repair_wakes"] = "n/a (source %s absent)" % SRC_ROP
        b["unavailable"] = unavailable
        return b

    names = (set(dirty) | set(merged) | set(rebuilds) | set(fix) | set(durations)
             | set(still_open) | set(consumed) | set(lower_map.values()))
    projects = {}
    for p in names:
        projects[p] = block(dirty.get(p, 0), len(merged.get(p, ())), rebuilds.get(p, 0),
                            dict(fix.get(p) or {"ok": 0, "failed": 0}), durations.get(p, []),
                            still_open.get(p, 0), len(consumed.get(p, ())))
    all_durs = [d for ds in durations.values() for d in ds]
    fleet = block(sum(dirty.values()), sum(len(v) for v in merged.values()),
                  sum(rebuilds.values()),
                  {"ok": sum(v["ok"] for v in fix.values()),
                   "failed": sum(v["failed"] for v in fix.values())},
                  all_durs, sum(still_open.values()), len(fleet_wakes))
    fleet["source"] = FIGURE_SOURCES
    # The block of a project the four sources never named (a ledger-only row).
    empty = block(0, 0, 0, {"ok": 0, "failed": 0}, [], 0, 0)
    return {"projects": projects, "fleet": fleet, "sources": sources, "empty": empty}


def over_threshold(projects, threshold):
    """The alert decision: every project whose rebuilds per 100 merges is
    STRICTLY over the threshold. No merges is n/a, never over."""
    out = []
    for p in sorted(projects):
        b = projects[p]
        r, m = b.get("rebuilds"), b.get("merges")
        if r is None or not m:
            continue
        if r * 100 > threshold * m:
            out.append((p, r, m, _per_100(r, m)))
    return out
