#!/bin/bash
# bin/size-threshold.sh <project> [lines|files|src|all] [tier] — how big is "too big" here?
#
# THE HOTFIX TIER (the operator, 2026-10-07: hotfix tickets build as one PR, not split).
# The tier is the 3rd argument or SIZE_TIER in the environment; bin/lib/rb/plan.sh
# passes SIZE_TIER=hotfix when the build's settled HOTFIX is 1. With it, each axis
# reads `size_gate.<axis>.hotfix.<project>` then `size_gate.<axis>.hotfix`
# (seeded 1500/30 in worker/jobs/schema.sql) BEFORE everything below, and the
# src says `row:hotfix`. A tier row that is missing or junk falls through to the
# normal chain, exactly as a junk normal row does. Any other tier value, or none,
# is no tier: the answer is byte-for-byte what it was before the tier existed.
#
# Resolution, PER AXIS, first hit wins (BH-4985, the operator 2026-10-06: "that should
# be a database setting, not hard coded"):
#   1. settings row `size_gate.<axis>.<project>` (axis = lines|files, project
#      lowercased) — one project's own limit.
#   2. settings row `size_gate.<axis>` — the fleet limit. worker/jobs/schema.sql
#      seeds both fleet rows at 1200/30 (insert only when missing), and /config
#      edits them with the change audited in config_changes. Rows are read from
#      state/settings-cache.json through bin/lib/lane-gate.sh, the TTL cache
#      every lane shares (one GET per 60 s per box, not one per build).
#   3. a box-local override in flags/size-gate-<project>, one line
#      "<lines> [files]". The emergency lever for a box with no worker.
#   4. catalog/size-thresholds.conf, a repo-tracked line "<project> <lines>
#      <files>", reaching every box on its own harness-sync.
#   5. 1200 lines / 30 files — the documented fallback of the size_gate.lines /
#      size_gate.files rows, and the only hardcode.
# The worker down, no cache, an unreadable cache or LANE_GATE_DISABLE=1 all mean
# no rows: 3-5 answer exactly as before rows existed. Never 0, never "no gate".
# `src` prints where the answer came from: row:hotfix|row|flag|catalog|default when both
# axes agree, else `lines:<a>,files:<b>`. `all` prints "<lines> <files> <src>".
#
# WHY 1200 AND 30 (the operator, 2026-10-14; BH-5520, BH-6025). bin/split-chain-report.sh
# --days 14 on 2026-10-11 (2026-09-27 to 2026-10-11): split tickets n=82, median
# lead 30.9h; unsplit n=243, median lead 4h. Merged split children (n=350) ran
# p90 578 product lines and p90 10 files, so the split bought small PRs at 7.7x
# the median lead time. The report proposed 1200/30. the operator set both fleet rows by
# hand on 2026-10-14; this fallback and the seed follow those rows.
# Before 2026-10-14: 700/20, for the reasons below.
#
# WHY 700 AND 20 (the operator, 2026-10-06). Measured on our own split-vs-whole builds:
# in the 300-600 line band a split cost $44.8 / 10.4h against $27.6 / 5.9h built
# whole, and in 600-1000 $60.7 / 21.7h against $22.6 / 12.0h. The review-block
# rate by file count runs 12/19/22/33%, so files stay a separate axis. 139 of
# 371 split families stranded spend, $12.9K of $28.3K. Shipped/declared median
# is 1.29, so 700 declared trips at about 805 (the 15% band), which is roughly
# 1,000 shipped lines. Above about 1,000 shipped lines 60% of builds needed a
# fix round, so splitting stays. LINES ARE PRODUCT LINES — tests, docs, specs,
# lockfiles and generated files do not count; bin/size-scope.sh owns that list
# and is the only place it lives.
# Before 2026-10-06: 300/12 (2026-09-12, borrowed from the 100-300 range large orgs land).
#
# A partial flag is a partial override: "150" on its own changes the line limit
# and leaves the file limit wherever the catalog (or the default) had it.
# Resetting the other half to the default would be a silent second edit nobody
# asked for.
#
# Junk is never a threshold. A word, a negative or a 0 — in a row, a flag or the
# catalog — falls through to the next source: a threshold of 0 would split every
# ticket ever filed, and a threshold of "banana" would disable the gate while
# looking configured.
set -uo pipefail
P="${1:?project}"
FIELD="${2:-both}"
TIER="${3:-${SIZE_TIER:-}}"
case "$TIER" in hotfix) ;; *) TIER="" ;; esac
HARNESS="${HARNESS:-/root/harness}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# Step 5: the documented code fallback of the rows size_gate.lines and
# size_gate.files (seeded 1200/30, worker/jobs/schema.d/0001-bh-4985-size-gate.sql).
DEF_LINES=1200
DEF_FILES=30

num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 1 ;; *) printf '%s' "$1" ;; esac; }

L=""; F=""; LSRC=""; FSRC=""
# 4. the repo-tracked registry, wherever this install keeps its catalog.
for C in "${SIZE_THRESHOLDS_CONF:-}" "$HARNESS/catalog/size-thresholds.conf" \
         "$HERE/../catalog/size-thresholds.conf"; do
  [ -n "$C" ] && [ -r "$C" ] || continue
  ROW=$(grep -vE '^[[:space:]]*(#|$)' "$C" | awk -v p="$P" '$1 == p { print $2, $3; exit }')
  [ -n "$ROW" ] || break
  set -- $ROW
  L=$(num "${1:-}") && LSRC=catalog || L=""
  F=$(num "${2:-}") && FSRC=catalog || F=""
  break
done
# 3. the box-local flag outranks it.
FLAG=$(cat "$HARNESS/flags/size-gate-$P" 2>/dev/null | head -1)
if [ -n "${FLAG:-}" ]; then
  set -- $FLAG
  FL=$(num "${1:-}") && { L="$FL"; LSRC=flag; }
  FF=$(num "${2:-}") && { F="$FF"; FSRC=flag; }
fi
# 2 then 1. the settings rows, fleet first so the project row lands last and wins.
# Sourced the way bin/lib/conf-row.sh does it; any failure leaves L/F as they are.
if [ "${LANE_GATE_DISABLE:-}" != 1 ]; then
  if ! command -v _lg_setting_lookup >/dev/null 2>&1 && [ -r "$HERE/lib/lane-gate.sh" ]; then
    # shellcheck source=lib/lane-gate.sh
    . "$HERE/lib/lane-gate.sh" >/dev/null 2>&1 || true
    set -uo pipefail
  fi
  if command -v _lg_setting_lookup >/dev/null 2>&1; then
    # A tree with no jobs client (a fixture) reads its cache as it stands.
    if command -v _jobs_req >/dev/null 2>&1 || [ -r "$HARNESS/bin/jobs-client.sh" ]; then
      _lg_settings_refresh >/dev/null 2>&1 || true
      set -uo pipefail
    fi
    PK=$(printf '%s' "$P" | tr '[:upper:]' '[:lower:]')
    # The worker's SETTING_KEY_RE: a slug outside it has no row, so no lookup.
    case "$PK" in ''|*[!a-z0-9_.-]*) PK="" ;; esac
    for K in "size_gate.lines" "size_gate.lines${PK:+.$PK}"; do
      [ "${#K}" -le 64 ] || continue
      V=$(_lg_setting_lookup "$K" 2>/dev/null) && V=$(num "$V") && { L="$V"; LSRC=row; }
      [ -n "$PK" ] || break
    done
    for K in "size_gate.files" "size_gate.files${PK:+.$PK}"; do
      [ "${#K}" -le 64 ] || continue
      V=$(_lg_setting_lookup "$K" 2>/dev/null) && V=$(num "$V") && { F="$V"; FSRC=row; }
      [ -n "$PK" ] || break
    done
    # The tier outranks every normal source: fleet tier row, then the project's.
    if [ -n "$TIER" ]; then
      for K in "size_gate.lines.$TIER" "size_gate.lines.$TIER${PK:+.$PK}"; do
        [ "${#K}" -le 64 ] || continue
        V=$(_lg_setting_lookup "$K" 2>/dev/null) && V=$(num "$V") && { L="$V"; LSRC="row:$TIER"; }
        [ -n "$PK" ] || break
      done
      for K in "size_gate.files.$TIER" "size_gate.files.$TIER${PK:+.$PK}"; do
        [ "${#K}" -le 64 ] || continue
        V=$(_lg_setting_lookup "$K" 2>/dev/null) && V=$(num "$V") && { F="$V"; FSRC="row:$TIER"; }
        [ -n "$PK" ] || break
      done
    fi
  fi
fi
# 5. the default.
[ -n "$L" ] || { L=$DEF_LINES; LSRC=default; }
[ -n "$F" ] || { F=$DEF_FILES; FSRC=default; }
if [ "$LSRC" = "$FSRC" ]; then SRC=$LSRC; else SRC="lines:$LSRC,files:$FSRC"; fi

case "$FIELD" in
  lines) printf '%s\n' "$L" ;;
  files) printf '%s\n' "$F" ;;
  src)   printf '%s\n' "$SRC" ;;
  all)   printf '%s %s %s\n' "$L" "$F" "$SRC" ;;
  *)     printf '%s %s\n' "$L" "$F" ;;
esac
