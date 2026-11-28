"""bin/dora_subagent.py — the DORA digest's subagent_share block (BH-10209).

The subagent share of execute spend, per project and fleet, over the last N
days. Pure: it reads one file and returns a dict. bin/dora-digest.py calls
block() and text_lines() and never lets an exception out of this block.

SOURCE. state/cost/fleet-cost.csv, the hub rollup's union of every box's cost
rows (bin/cost-rollup.sh), read BY HEADER NAME: ts, project, stage, cost_usd,
note. A claude row priced from its transcript carries the subagent part of its
dollars as the note token `sub_usd:<x>` (bin/lib/cost-row.sh
cost_sub_usd_token, written first in the note by bin/agent-call.sh). A row
without the token was NOT MEASURED (an envelope row, a grok or codex row, or a
row from before BH-10209). It is never read as a zero.

FIGURES, per project and for the fleet, over rows whose stage is in `stages`
and whose ts is in [until - days, until]:
  execute_rows, execute_usd   every such row (an empty cost_usd adds $0)
  measured_rows, measured_usd the rows that carry a sub_usd token
  sub_usd                     the sum of the tokens
  share     = sub_usd / measured_usd      (None when measured_usd is 0)
  coverage  = measured_usd / execute_usd  (None when execute_usd is 0)

STATUS. ok; absent (no file); error (a needed column is missing, or the read
failed). absent and error carry `unavailable = "n/a (...)"` and no figure.
"""
import csv
import datetime
import os
import re

COLUMNS = ["ts", "project", "stage", "cost_usd", "note"]
SOURCE_NAME = "state/cost/fleet-cost.csv"
# A token at the start of the note or after a `;` or `.` separator, ending at
# the end of the note or at the next separator. `.` because a kill note joins
# its parts with `.`. A sign, a letter or an empty value is not a token.
_TOKEN = re.compile(r"(?:^|[;.])sub_usd:([0-9]+(?:\.[0-9]+)?)(?=$|[;.])")


def parse_sub_usd(note):
    """The float of the first well-formed sub_usd token in a note, or None."""
    if not note:
        return None
    m = _TOKEN.search(note)
    return float(m.group(1)) if m else None


def _norm_iso(s):
    """Any instant the cost rows carry -> 'YYYY-MM-DDTHH:MM:SSZ', or None."""
    if not s:
        return None
    s = s.strip()
    if s.endswith("+00:00"):
        s = s[:-6] + "Z"
    m = re.match(r"^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(?:\.\d+)?Z?$", s)
    return "%sT%sZ" % (m.group(1), m.group(2)) if m else None


def _num(s):
    try:
        v = float(s)
    except (TypeError, ValueError):
        return None
    return v if v == v else None


def _bucket():
    return {"execute_rows": 0, "execute_usd": 0.0, "measured_rows": 0,
            "measured_usd": 0.0, "sub_usd": 0.0, "share": None, "coverage": None}


def _finish(b):
    for k in ("execute_usd", "measured_usd", "sub_usd"):
        b[k] = round(b[k], 6)
    b["share"] = round(b["sub_usd"] / b["measured_usd"], 4) if b["measured_usd"] > 0 else None
    b["coverage"] = round(b["measured_usd"] / b["execute_usd"], 4) if b["execute_usd"] > 0 else None
    return b


def split_stages(s):
    """'execute+fix' or 'execute,fix' -> ['execute', 'fix']."""
    return [x.strip() for x in re.split(r"[+,]", s or "") if x.strip()]


def block(path, until_iso, days, stages):
    """The subagent_share block. Never raises for a bad file: status says why."""
    until = _norm_iso(until_iso) or until_iso
    try:
        u = datetime.datetime.strptime(until, "%Y-%m-%dT%H:%M:%SZ")
        since = (u - datetime.timedelta(days=int(days))).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (TypeError, ValueError):
        since = None
    stages = list(stages or [])
    out = {"status": "ok", "days": days,
           "fleet": None, "projects": None, "unavailable": None,
           "source": {"path": path, "name": SOURCE_NAME, "columns": COLUMNS,
                      "rows_read": 0, "rows_in_window": 0, "rows_counted": 0, "stages": stages,
                      "since": since, "until": until,
                      "token": "note token sub_usd:<x> (bin/lib/cost-row.sh cost_sub_usd_token); "
                               "a row without it is not measured"}}
    if since is None:
        out.update(status="error", unavailable="n/a (the window end %r is not a timestamp)" % until_iso)
        return out
    if not path or not os.path.exists(path):
        out.update(status="absent", unavailable="n/a (source %s absent)" % SOURCE_NAME)
        return out
    fleet = _bucket()
    projects = {}
    try:
        with open(path, "r", errors="replace", newline="") as fh:
            rd = csv.DictReader(fh)
            missing = [c for c in COLUMNS if c not in (rd.fieldnames or [])]
            if missing:
                out.update(status="error",
                           unavailable="n/a (%s header lacks %s)" % (SOURCE_NAME, ",".join(missing)))
                return out
            for row in rd:
                out["source"]["rows_read"] += 1
                ts = _norm_iso(row.get("ts"))
                if not ts or not (since <= ts <= until):
                    continue
                out["source"]["rows_in_window"] += 1
                if (row.get("stage") or "").strip() not in stages:
                    continue
                out["source"]["rows_counted"] += 1
                c = _num(row.get("cost_usd")) or 0.0
                s = parse_sub_usd(row.get("note"))
                p = (row.get("project") or "").strip() or "(unattributed)"
                for b in (fleet, projects.setdefault(p, _bucket())):
                    b["execute_rows"] += 1
                    b["execute_usd"] += c
                    if s is not None:
                        b["measured_rows"] += 1
                        b["measured_usd"] += c
                        b["sub_usd"] += s
    except (OSError, csv.Error) as exc:
        out.update(status="error", unavailable="n/a (%s unreadable: %s)" % (SOURCE_NAME, type(exc).__name__))
        return out
    out["fleet"] = _finish(fleet)
    out["projects"] = {k: _finish(v) for k, v in sorted(projects.items())}
    return out


def _pct(v):
    return "%.1f%%" % (v * 100.0)


def _usd(v):
    return "$%.2f" % v


def text_lines(b, max_rows):
    """One message line. Projects sorted by execute $ (desc), cut to max_rows."""
    st = "+".join(b.get("source", {}).get("stages") or []) or "execute"
    head = "subagent share of %s $, %sd: " % (st, b.get("days"))
    if b.get("status") != "ok":
        return [head + (b.get("unavailable") or "n/a (%s)" % b.get("status"))]
    f = b["fleet"]
    if f["share"] is None:
        return [head + "n/a (no %s row carries sub_usd yet; %d rows, %s)"
                % (st, f["execute_rows"], _usd(f["execute_usd"]))]
    line = head + "fleet %s (%s of %s measured, %d of %d rows)" % (
        _pct(f["share"]), _usd(f["sub_usd"]), _usd(f["measured_usd"]),
        f["measured_rows"], f["execute_rows"])
    projs = sorted(b["projects"].items(), key=lambda kv: (-kv[1]["execute_usd"], kv[0]))
    parts = ["%s %s" % (k, _pct(v["share"]) if v["share"] is not None else "n/a")
             for k, v in projs[:max(0, int(max_rows))]]
    if parts:
        line += "; " + ", ".join(parts)
    return [line]
