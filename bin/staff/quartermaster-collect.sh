#!/bin/bash
# bin/staff/quartermaster-collect.sh — Quartermaster's collector. bin/staff.sh
# runs it at step 6 of `staff.sh tick quartermaster` and claims what it prints.
# Deterministic: no model call, no gh call, no write but its own cache.
#
# It reads the last QM_WINDOW_H hours of D1 cost_rows ONE time, through
# cost_rows_fetch (bin/lib/cost-rows-read.sh), and prints one JSONL line per
# finding in the staff collector format:
#   {"item":…, "title":…, "source":{"kind":"cost_rows","url":…,"labels":[]},
#    "observedAt":…, "class":…}
#
# A row is a call when row_source is not `refused` (a refused call is a
# zero-cost llm-gate row, never a vendor request).
#
#   cost-multiplier  per (project, stage, runner): calls with a non-empty
#                    guard_fp (the pre-call guard's input fingerprint) divided
#                    by the distinct guard_fp values. A finding when calls >=
#                    QM_MULT_MIN_CALLS and calls/inputs >= QM_MULT_MAX. A row
#                    with no guard_fp (an old box, or a row the reader had to
#                    reconstruct) has no known input and is left out.
#   cost-parity      per (stage, runner): metered calls (runner in
#                    QM_METERED_RUNNERS, or billing_mode=metered) with rc 0 and
#                    a blank cost_usd. Blank is empty after trim; `0` is a
#                    value, not a blank. A finding when the count >=
#                    QM_PARITY_MIN_CALLS.
#
# The item holds the check, its keys and the UTC day, and no count: the claim
# fingerprints the item, so one key makes at most one finding per day. The
# numbers ride in the title. Output is sorted, so the same rows print the same
# bytes.
#
# READ CACHE. state/staff/quartermaster/last.jsonl holds the last good output.
# When it is younger than QM_READ_EVERY_S, the collector prints it again and
# reads nothing (a PENDING or HELD item must be collected again to move). It is
# written (tmp + mv) only after a whole good read.
#
# rc 0: a good read (lines or none), or the cache. rc 1: cost_rows unreadable,
# or python3 or the reader missing; nothing printed, the cache untouched.
#
# Knobs: catalog/lanes.d/_lib.staff-quartermaster.json, applied with
# lib_env_apply staff-quartermaster. Out of range is one warn line in
# logs/staff.log and the default, never a clamp.
# Note: docs/notes/2026-10-14-BH-5564-quartermaster.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
BIN="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
{
  . "$BIN/lib/lane-gate.sh" 2>/dev/null || true
  . "$BIN/jobs-client.sh" 2>/dev/null || true
}
# shellcheck source=bin/lib/cost-rows-read.sh
. "$BIN/lib/cost-rows-read.sh" || exit 1
# The suite's seam. Sandbox only, and settable:false in the registry.
NOW_S=""
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ]; then
  # shellcheck disable=SC1090
  [ -n "${QM_FIXTURE:-}" ] && . "$QM_FIXTURE"
  [[ ${QM_NOW:-} =~ ^[0-9]+$ ]] && NOW_S=$QM_NOW
fi
[ -n "$NOW_S" ] || NOW_S=$(date -u +%s)
command -v python3 >/dev/null 2>&1 && command -v cost_rows_fetch >/dev/null 2>&1 || exit 1
command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply staff-quartermaster

warn() { mkdir -p "$H/logs" 2>/dev/null; printf '%s agent=quartermaster warn: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$H/logs/staff.log" 2>/dev/null; }
# knob_int <name> <value> <default> <min> <max>
knob_int() {
  local v=$2
  if [[ $v =~ ^[0-9]+$ ]] && [ "$((10#$v))" -ge "$4" ] && [ "$((10#$v))" -le "$5" ]; then
    printf '%s' "$((10#$v))"
  else
    warn "$1=$v is outside $4..$5; using the default $3"
    printf '%s' "$3"
  fi
}
W=$(knob_int QM_WINDOW_H "${QM_WINDOW_H:-24}" 24 1 168)
MULT=$(knob_int QM_MULT_MAX "${QM_MULT_MAX:-10}" 10 2 1000)
MINC=$(knob_int QM_MULT_MIN_CALLS "${QM_MULT_MIN_CALLS:-100}" 100 1 1000000)
PMIN=$(knob_int QM_PARITY_MIN_CALLS "${QM_PARITY_MIN_CALLS:-3}" 3 1 100000)
EVERY=$(knob_int QM_READ_EVERY_S "${QM_READ_EVERY_S:-3600}" 3600 0 86400)
METERED="${QM_METERED_RUNNERS:-grok openrouter fireworks xai}"
if ! [[ $METERED =~ ^[A-Za-z0-9_.,\ -]+$ ]]; then
  warn "QM_METERED_RUNNERS=$METERED is not a runner list; using the default"
  METERED="grok openrouter fireworks xai"
fi

STATE="$H/state/staff/quartermaster"
CACHE="$STATE/last.jsonl"
if [ "$EVERY" -gt 0 ] && [ -f "$CACHE" ]; then
  age=$(( $(date -u +%s) - $(stat -c %Y "$CACHE" 2>/dev/null || echo 0) ))
  if [ "$age" -ge 0 ] && [ "$age" -lt "$EVERY" ]; then cat "$CACHE"; exit 0; fi
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/qm-collect.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
SINCE=$(date -u -d "@$((NOW_S - W * 3600))" +%Y-%m-%dT%H:%M:%SZ) || exit 1
cost_rows_fetch "$TMP/rows.csv" "$SINCE" || exit 1

python3 - "$TMP/rows.csv" "$NOW_S" "$W" "$MULT" "$MINC" "$PMIN" "$METERED" "${CONSOLE_URL:-}" > "$TMP/out" <<'PY' || exit 1
import csv, json, re, sys, time
path, now, w, mult, minc, pmin, metered, console = sys.argv[1:9]
now, w, mult, minc, pmin = int(now), int(w), int(mult), int(minc), int(pmin)
metered = {m for m in re.split(r"[ ,]+", metered.lower()) if m}
day = time.strftime("%Y-%m-%d", time.gmtime(now))
observed = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
url = (console.rstrip("/") if console else "") + "/costs"

def val(r, k):
    v = r.get(k)
    return v.strip() if isinstance(v, str) else ""

mgroups, pgroups = {}, {}
with open(path, newline="", errors="replace") as fh:
    for r in csv.DictReader(fh):
        if val(r, "row_source") == "refused" or r.get("runner") is None:
            continue
        project, stage, runner = val(r, "project"), val(r, "stage"), val(r, "runner")
        fp = val(r, "guard_fp")
        if fp:
            g = mgroups.setdefault((project, stage, runner), [0, set()])
            g[0] += 1
            g[1].add(fp)
        if runner.lower() in metered or val(r, "billing_mode") == "metered":
            g = pgroups.setdefault((stage, runner), [0, 0])
            g[0] += 1
            if val(r, "rc") == "0" and val(r, "cost_usd") == "":
                g[1] += 1

out = []
for (project, stage, runner), (calls, fps) in mgroups.items():
    inputs = len(fps)
    if inputs == 0 or calls < minc or calls / inputs < mult:
        continue
    out.append(("cost-multiplier", (project, stage, runner), {
        "item": {"check": "cost-multiplier", "project": project, "stage": stage, "runner": runner, "day": day},
        "title": "Paid-call multiplier: %s %s on %s made %d paid calls for %d distinct inputs (%.1fx) in %dh"
                 % (project, stage, runner, calls, inputs, calls / inputs, w),
        "class": "cost-multiplier"}))
for (stage, runner), (total, blank) in pgroups.items():
    if blank < pmin:
        continue
    out.append(("cost-parity", (stage, runner), {
        "item": {"check": "cost-parity", "stage": stage, "runner": runner, "day": day},
        "title": "Cost capture parity: %s on %s made %d metered calls with a blank cost (%d of %d metered calls) in %dh"
                 % (stage, runner, blank, blank, total, w),
        "class": "cost-parity"}))
out.sort(key=lambda x: (x[0], x[1]))
for _, _, o in out:
    o["source"] = {"kind": "cost_rows", "url": url, "labels": []}
    o["observedAt"] = observed
    print(json.dumps({k: o[k] for k in ("item", "title", "source", "observedAt", "class")}, separators=(",", ":")))
PY

mkdir -p "$STATE" 2>/dev/null && cp "$TMP/out" "$STATE/.last.jsonl.tmp" 2>/dev/null \
  && mv -f "$STATE/.last.jsonl.tmp" "$CACHE" 2>/dev/null \
  || warn "cannot write the read cache $CACHE; the next tick reads again"
cat "$TMP/out"
exit 0
