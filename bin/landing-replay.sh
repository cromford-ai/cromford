#!/bin/bash
# bin/landing-replay.sh [--days N] [--last N] [--repo owner/name] [--json]
#
# THE EVIDENCE ROW FOR THE OPTIMISTIC-LANDING FLIP (BH-6748, wave 5 of #6541).
# Reads the last N days (default 7) of landing_decisions rows and the merge
# ledger, and prints what optimistic mode would have landed directly, how many
# of those PRs were later reverted or ejected from the queue, and the CI
# minutes saved. The flip procedure (docs/OPERATING.md, "Optimistic landing:
# measure, then flip") pastes its LANDING_REPLAY lines on the ticket.
#
# Output, in this order (the evidence rows are the last lines):
#   source <name>: <status> [capped] [why]     one per source
#   top queue reasons: <reason>=<n> ...        the 5 commonest would=queue reasons
#   LANDING_REPLAY repo=<r> days=<d> would_direct=<n> merged=<n> reverted=<n|n/a>
#     ejected=<n|n/a> ci_min_saved=<n|n/a> pending=<n>      one per repo
#   LANDING_REPLAY total ...
# --json prints the same numbers as keys. --last N replays only the N newest
# decision rows in the window. Every figure is defined in docs/DORA.md
# ("landing block"); ci_min_saved is an estimate: would-direct PRs merged on
# the queued path x the repo's batch minutes per queued merge in the window.
#
# Sources: bin/lib/landing-sources.sh ls_fetch (the harness-jobs worker
# through $HARNESS/bin/jobs-client.sh, GitHub REST through
# $HARNESS/bin/lib/gh-rest.sh, the conductor's attempts.txt); the arithmetic is
# bin/dora_landing.py. Repos: bin/fleet-conf.sh, or --repo.
# Knob: the window's default is the settings row landing.replay.days, then env
# LANDING_REPLAY_DAYS, then 7. The page caps are ls_fetch's knobs.
#
# Exit: 0 printed; 2 usage (nothing read); 3 every decisions read failed (the
# lines still print, with n/a). Writes nothing: no state, no alert, no beat.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
H="${HARNESS:-/root/harness}"
BIN="$(cd "$(dirname "$0")" && pwd)"
usage() { echo "usage: landing-replay.sh [--days N (1..90)] [--last N] [--repo owner/name] [--json]" >&2; exit 2; }

DAYS=""; LAST=""; REPO=""; JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --days) [ $# -ge 2 ] || usage; DAYS="$2"; shift 2 ;;
    --days=*) DAYS="${1#*=}"; shift ;;
    --last) [ $# -ge 2 ] || usage; LAST="$2"; shift 2 ;;
    --last=*) LAST="${1#*=}"; shift ;;
    --repo) [ $# -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    --repo=*) REPO="${1#*=}"; shift ;;
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) usage ;;
  esac
done
in_range() { [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }
if [ -n "$DAYS" ]; then in_range "$DAYS" 1 90 || { echo "landing-replay.sh: --days must be 1..90 (got '$DAYS')" >&2; exit 2; }; fi
if [ -n "$LAST" ]; then in_range "$LAST" 1 100000 || { echo "landing-replay.sh: --last must be a positive integer (got '$LAST')" >&2; exit 2; }; fi
if [ -n "$REPO" ]; then [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "landing-replay.sh: --repo must be owner/name" >&2; exit 2; }; fi

# shellcheck source=/dev/null
. "$H/bin/jobs-client.sh" 2>/dev/null || true
# shellcheck source=/dev/null
. "$H/bin/lib/gh-app-auth.sh" 2>/dev/null || true
# shellcheck source=/dev/null
. "$H/bin/lib/gh-rest.sh" 2>/dev/null || true
# shellcheck source=lib/pr-health.sh
. "$BIN/lib/pr-health.sh" 2>/dev/null || true
# shellcheck source=lib/landing-sources.sh
. "$BIN/lib/landing-sources.sh" || { echo "landing-replay.sh: bin/lib/landing-sources.sh is missing" >&2; exit 1; }

if [ -z "$DAYS" ]; then
  DAYS=$(_ls_knob landing.replay.days LANDING_REPLAY_DAYS 7)  # fallback 7: settings row landing.replay.days
  in_range "$DAYS" 1 90 || DAYS=7
fi
LABEL=fix-main-red
# shellcheck source=lib/main-red-label.sh
if . "$BIN/lib/main-red-label.sh" 2>/dev/null && command -v main_red_label_resolve >/dev/null 2>&1; then
  L=$(main_red_label_resolve "$H" 2>/dev/null); [ -n "$L" ] && LABEL="$L"
fi

NOW_ISO=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
SINCE_ISO=$(date -u -d "$DAYS days ago" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) \
  || SINCE_ISO=$(date -u -v-"${DAYS}"d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/landing-replay-XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

: > "$WORK/repos.tsv"
if [ -n "$REPO" ]; then
  printf '%s\t%s\n' "$REPO" "$REPO" > "$WORK/repos.tsv"
else
  while read -r P; do
    [ -n "$P" ] || continue
    R=$("$BIN/fleet-conf.sh" "$P" repo 2>/dev/null) || R=""
    [ -n "$R" ] && [ "$R" != "-" ] && printf '%s\t%s\n' "$P" "$R" >> "$WORK/repos.tsv"
  done < <("$BIN/fleet-conf.sh" --projects 2>/dev/null)
fi

ls_fetch "$WORK/src" "$SINCE_ISO" "$WORK/repos.tsv"
ARGS=(replay "$WORK/src" "$SINCE_ISO" "$NOW_ISO" --days "$DAYS" --label "$LABEL")
[ -n "$LAST" ] && ARGS+=(--last "$LAST")
[ "$JSON" = 1 ] && ARGS+=(--json)
python3 "$BIN/dora_landing.py" "${ARGS[@]}" || exit 1
[ "$(jq -r '.decisions.status' "$WORK/src/sources.json" 2>/dev/null)" = error ] && exit 3
exit 0
