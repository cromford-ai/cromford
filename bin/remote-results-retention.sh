#!/bin/bash
# bin/remote-results-retention.sh — the retention rule for the hub's backup
# result jsons, state/remote-results/<p>/<KEY>.json (BH-7582).
#
# WHAT THE JSONS ARE FOR. bin/fly-pool.sh keeps each json on the ledger path as
# the backup copy of a pool build's result. Once the build is over (its newest
# jobs-ledger build row is terminal, bin/lib/remote-results-ledger.sh) the copy
# has no reader, and once its build folder is pruned nothing marks it consumed.
#
# THE RULE. A json is RETIRED when its ledger build row is terminal AND (its
# build folder is gone OR it is older than the window). Retiring writes one
# ledger row through bin/jobs-client.sh (job_ledger_put):
#   kind=remote_result key=<p>/<KEY> status=retired
#   detail={"json_mtime":N,"reason":"build folder gone"|"older than Nd","window_days":N}
# The ledger row is the record. This script reads the json directory and never
# moves, writes or deletes a file in it (the directory is class `rows` in
# catalog/state-paths.json; its row twins have their own retention in
# worker/jobs/src/routes/retention.js). A json with no row, an open row or an
# unreadable ledger is not retired (the staleremote check keeps paging a json
# with no row and no folder).
#
# Usage:
#   bin/remote-results-retention.sh [--project P | --all] [--dry-run | --apply] [--max-reads N]
#     --project P   one project (default: --all, every project directory)
#     --dry-run     list the candidates, write no ledger row
#     --apply       write the remote_result ledger rows
#     --max-reads N ledger reads per project this run (default STALEREMOTE_LEDGER_READS, 200)
#   Replay (prints what a real run would mark, and counts what would page):
#     bin/remote-results-retention.sh --all --dry-run --max-reads 5000
#
# Knobs (settings rows of the pipeline-health lane, through lane_env_apply):
#   REMOTE_RESULTS_RETENTION_APPLY  1 = write rows; anything else = dry-run (default 0)
#   REMOTE_RESULTS_RETENTION_DAYS   the window in days, 1..365 (default 7)
#   STALEREMOTE_LEDGER_READS        the read cap per project (default 200)
# --dry-run / --apply win over the knob.
#
# Output: ONE audit line per project per run in logs/remote-results-retention.log;
# a dry-run also writes its candidate list to
# logs/remote-results-retention-dryrun-<p>.txt (replaced each run) and stdout.
# `would_page` on the audit line counts the jsons the staleremote check pages
# (older than 30 minutes, no RELAYED, and a folder present or an open or absent
# row): the replay number. The terminal-answer cache is
# state/remote-results-terminal/<p>.tsv (class cache).
# Exit 0 on every run path; 2 on a bad argument (and no audit line).
set -uo pipefail
H="${HARNESS:-/root/harness}"
# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply pipeline-health
if [ -f "$H/bin/jobs-client.sh" ]; then # shellcheck source=/dev/null
  . "$H/bin/jobs-client.sh"; fi
# shellcheck source=bin/lib/remote-results-ledger.sh
. "$H/bin/lib/remote-results-ledger.sh" 2>/dev/null \
  || { echo "remote-results-retention: cannot source bin/lib/remote-results-ledger.sh" >&2; exit 0; }

usage() { sed -n '/^# Usage:/,/^# Knobs/p' "$0" | sed '$d' >&2; exit 2; }
PROJ=""; ALL=0; MODE=""; MAXR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage; PROJ="$2"; shift 2 ;;
    --all) ALL=1; shift ;;
    --dry-run) MODE=dry; shift ;;
    --apply) MODE=apply; shift ;;
    --max-reads) [ $# -ge 2 ] || usage; MAXR="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "remote-results-retention: unknown argument: $1" >&2; usage ;;
  esac
done
if [ -n "$PROJ" ]; then
  [ "$ALL" = 0 ] || { echo "remote-results-retention: --project and --all together" >&2; usage; }
  [[ "$PROJ" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "remote-results-retention: bad project name: $PROJ" >&2; usage; }
fi
if [ -n "$MAXR" ]; then
  [[ "$MAXR" =~ ^[0-9]+$ ]] || { echo "remote-results-retention: --max-reads wants a whole number: $MAXR" >&2; usage; }
else
  MAXR=${STALEREMOTE_LEDGER_READS:-200}   # fallback of the pipeline-health knob STALEREMOTE_LEDGER_READS
  [[ "$MAXR" =~ ^[0-9]+$ ]] || MAXR=200
fi
if [ -z "$MODE" ]; then
  [ "${REMOTE_RESULTS_RETENTION_APPLY:-0}" = 1 ] && MODE=apply || MODE=dry
fi
DRY=1; [ "$MODE" = apply ] && DRY=0
WIN=${REMOTE_RESULTS_RETENTION_DAYS:-}; WIN_TAG=""
if ! [[ "$WIN" =~ ^[0-9]+$ ]] || [ "$WIN" -lt 1 ] || [ "$WIN" -gt 365 ]; then
  WIN=7; WIN_TAG="(default)"   # fallback of the pipeline-health knob REMOTE_RESULTS_RETENTION_DAYS
fi
WIN_S=$((WIN * 86400))
NOW=${RR_NOW:-$(date +%s)}
TCD="$H/state/remote-results-terminal"
AUDIT="$H/logs/remote-results-retention.log"
mkdir -p "$H/logs" 2>/dev/null
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

# retain_project <json dir> — one project, one audit line. The project is the
# directory's name. Reads the directory; writes only the cache, the logs and
# the ledger rows.
retain_project() {
  local d="$1" p j k m age st rc reason detail cache dryf
  local n=0 term=0 open=0 absent=0 unk=0 def=0 young=0 marked=0 would=0 already=0 page=0 err=0 reads=0
  p=${d%/}; p=${p##*/}
  [[ "$p" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 0
  cache="$TCD/$p.tsv"; dryf="$H/logs/remote-results-retention-dryrun-$p.txt"
  [ "$DRY" = 1 ] && : > "$dryf" 2>/dev/null
  rr_terminal_cache_load "$cache"
  for j in "$d/"*.json; do
    [ -f "$j" ] || continue
    n=$((n+1))
    k=${j##*/}; k=${k%.json}
    m=$(stat -c %Y "$j") || { err=$((err+1)); continue; }
    age=$((NOW - m))
    reason=""
    if rr_folder_present "$H" "$p" "$k"; then
      # staleremote pages a present folder with no RELAYED, with no ledger read.
      if [ "$age" -gt 1800 ] && ! rr_relayed_present "$H" "$p" "$k"; then page=$((page+1)); fi
      [ "$age" -gt "$WIN_S" ] || { young=$((young+1)); continue; }
      reason="older than ${WIN}d"
    else
      reason="build folder gone"
    fi
    if rr_terminal_cache_has "$k" "$m"; then
      st=terminal
    elif [ "$reads" -ge "$MAXR" ]; then
      def=$((def+1)); continue
    else
      reads=$((reads+1))
      st=$(rr_build_state "$p" "$k"); rc=$?
      [ "$rc" = 0 ] || st=unknown
      [ "$st" = terminal ] && rr_terminal_cache_add "$cache" "$k" "$m"
    fi
    if [ "$reason" = "build folder gone" ] && [ "$age" -gt 1800 ]; then
      case "$st" in open|absent) page=$((page+1)) ;; esac
    fi
    case "$st" in
      terminal) term=$((term+1)) ;;
      open)     open=$((open+1)); continue ;;
      absent)   absent=$((absent+1)); continue ;;
      *)        unk=$((unk+1)); continue ;;
    esac
    if rr_terminal_cache_marked "$k" "$m"; then
      already=$((already+1)); continue
    fi
    if [ "$DRY" = 1 ]; then
      would=$((would+1))
      printf 'would-mark %s/%s (%s)\n' "$p" "$k" "$reason" | tee -a "$dryf"
      continue
    fi
    detail=$(jq -nc --argjson m "$m" --arg r "$reason" --argjson w "$WIN" \
      '{json_mtime:$m,reason:$r,window_days:$w}') || { err=$((err+1)); continue; }
    if job_ledger_put remote_result "$p/$k" retired "$detail" >/dev/null 2>&1; then
      rr_terminal_cache_mark "$cache" "$k" "$m"
      marked=$((marked+1))
    else
      err=$((err+1))
    fi
  done
  rr_terminal_cache_prune "$cache" "$d"
  printf '%s run project=%s dry=%s window=%s%s jsons=%s terminal=%s open=%s absent=%s unknown=%s deferred=%s young=%s marked=%s would_mark=%s already=%s would_page=%s errors=%s\n' \
    "$(STAMP)" "$p" "$DRY" "$WIN" "$WIN_TAG" "$n" "$term" "$open" "$absent" "$unk" "$def" "$young" "$marked" "$would" "$already" "$page" "$err" \
    >> "$AUDIT" 2>/dev/null || true
}

# The json directories are only ever named on these two lines (a read).
if [ -n "$PROJ" ]; then
  retain_project "$H/state/remote-results/$PROJ"
else
  for pd in "$H/state/remote-results/"*/; do
    [ -d "$pd" ] && retain_project "${pd%/}"
  done
fi
exit 0
