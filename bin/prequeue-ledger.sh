#!/bin/bash
# bin/prequeue-ledger.sh — THE PRE-QUEUE IMPACT STEP THAT READS THE SUITE
# LEDGER AND RUNS NOTHING (BH-9178, slice C2 of #9063).
#
#   bin/prequeue-ledger.sh --base B --head H --failed F --summary S
#                          [--skip-suites FILE] [--also FILE]
#
# .github/workflows/prequeue-gate.yml calls it in place of the impact gate when
# its input `impact` is `ledger` (the hub sends it, bin/lib/mc-prequeue.d/
# impact-ledger.sh). The invariants still run before it, in the workflow.
#
#   1. The run list: `bin/test-impact-gate.sh --runner plan --list L`, the same
#      selection, cap, --skip-suites and learned --also the gate would run. The
#      plan runner runs no suite.
#   2. The ledger: `bin/suite-reuse.sh plan --suites L ... --reds REDS`, class
#      SUITE_REUSE_CLASS (default ci), repo SUITE_REUSE_REPO (else origin's
#      <owner>/<name>), ctx SUITE_REUSE_CTX (default local), fingerprints at H.
#      --rerun-red is never passed: a red row is a red without a run. A helper
#      that rejects --reds (rc 2, `unknown argument --reds`) is asked once more
#      without it, and the summary says reds=unsupported.
#   3. The counts. green = the suites the helper reused, or every suite but the
#      reds when it says `off (would run nothing)`; any other `off (<why>)` is
#      green 0 and ledger=off:<why>. red = the REDS lines whose first
#      tab-separated column is a tests/[mc/]*.sh in L; a line of another shape
#      is counted in reds_bad and ignored; a suite outside L is ignored.
#      unverified = selected - green - red: the merge-queue batch runs them.
#
# --failed gets the red suites, in L's order. --summary gets ONE line:
#   selected=N green=G red=R unverified=U ledger=on|off:<why> reds=on|unsupported reds_bad=B
# stdout ends with `prequeue-ledger: selected N, green G, red R, unverified U (left to the batch)`.
#
# The token: SUITE_LEDGER_TOKEN_FD (3-9, read once, then closed) or
# SUITE_LEDGER_TOKEN. Both names leave the environment first; the token reaches
# only the bin/suite-reuse.sh call. It is never printed.
#
# EXIT: 0 no ledger red; 1 a ledger red (in --failed); 2 no selection (the
# plan runner's rc 2 or an empty list); 125 the selection could not run (any
# other plan-runner rc, or bad arguments). It writes no ledger row.
set -uo pipefail

PL_TOKEN="${SUITE_LEDGER_TOKEN:-}"
if [ -n "${SUITE_LEDGER_TOKEN_FD+x}" ]; then
  PL_TOKEN=""
  case "$SUITE_LEDGER_TOKEN_FD" in
    [3-9]) _plfd="$SUITE_LEDGER_TOKEN_FD"
           { IFS= read -r PL_TOKEN <&"$_plfd"; } 2>/dev/null || :
           exec {_plfd}<&- 2>/dev/null; unset _plfd ;;
  esac
fi
unset SUITE_LEDGER_TOKEN SUITE_LEDGER_TOKEN_FD

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRE='^tests/(mc/)?[A-Za-z0-9._-]+\.sh$'

die() { echo "prequeue-ledger: $*" >&2; exit 125; }
BASE="" HEAD_REF="" FAILED="" SUMMARY="" GATE_EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:-}"; shift ;;
    --head) HEAD_REF="${2:-}"; shift ;;
    --failed) FAILED="${2:-}"; shift ;;
    --summary) SUMMARY="${2:-}"; shift ;;
    --skip-suites|--also) [ -n "${2:-}" ] || die "$1 needs a path"; GATE_EXTRA+=("$1" "$2"); shift ;;
    *) die "unknown argument $1" ;;
  esac
  shift
done
[ -n "$BASE" ] && [ -n "$HEAD_REF" ] && [ -n "$FAILED" ] && [ -n "$SUMMARY" ] \
  || die "needs --base, --head, --failed and --summary"
: > "$FAILED" && : > "$SUMMARY" || die "cannot write --failed or --summary"

W=$(mktemp -d "${TMPDIR:-/tmp}/prequeue-ledger.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$W"' EXIT

# 1. the run list
( cd "$ROOT" && bash bin/test-impact-gate.sh --base "$BASE" --head "$HEAD_REF" --runner plan --list "$W/list" "${GATE_EXTRA[@]}" ) \
  > "$W/gate.out" 2>&1
GRC=$?
grep -v '^plan: ' "$W/gate.out"
[ "$GRC" = 2 ] && { echo "prequeue-ledger: no selection"; exit 2; }
[ "$GRC" = 0 ] || { echo "prequeue-ledger: the selection could not run (rc $GRC)"; exit 125; }
grep -v '^$' "$W/list" 2>/dev/null | awk '!seen[$0]++' > "$W/L"
[ -s "$W/L" ] || { echo "prequeue-ledger: no selection"; exit 2; }
N=$(grep -c . < "$W/L")

# 2. the ledger
LEDGER=on REDS_MODE=on
: > "$W/reds"; : > "$W/reused"
if [ ! -x "$ROOT/bin/suite-reuse.sh" ]; then
  LEDGER="off:no helper"
else
  REPO="${SUITE_REUSE_REPO:-}"
  if [ -z "$REPO" ]; then
    REPO=$(git -C "$ROOT" remote get-url origin 2>/dev/null | sed -e 's#\.git/*$##' -e 's#/*$##' -e 's#:#/#g' \
      | awk -F/ 'NF >= 2 && $(NF - 1) != "" && $NF != "" { print $(NF - 1) "/" $NF }')
  fi
  ask() { # ask [--reds FILE] — one helper call; rc and output in HRC / $W/helper.out|err
    ( cd "$ROOT" && SUITE_LEDGER_TOKEN="$PL_TOKEN" bin/suite-reuse.sh plan --class "${SUITE_REUSE_CLASS:-ci}" \
        --repo "$REPO" --ctx "${SUITE_REUSE_CTX:-local}" --suites "$W/L" --run "$W/run" --reused "$W/reused" \
        --fingerprints "$W/fp" --rev "$HEAD_REF" "$@" ) > "$W/helper.out" 2> "$W/helper.err"
    HRC=$?
  }
  ask --reds "$W/reds"
  if [ "$HRC" = 2 ] && grep -q 'unknown argument --reds' "$W/helper.err"; then
    REDS_MODE=unsupported; : > "$W/reds"
    ask
  fi
  grep -v '^suite-reuse: reused ' "$W/helper.out"
  OFF=$(sed -n 's/^suite-reuse: off (\(.*\))$/\1/p' "$W/helper.out" | tail -n1 | tr -cd 'A-Za-z0-9 ._:/-' | cut -c1-80)
  if [ "$HRC" != 0 ]; then
    LEDGER="off:helper rc $HRC"; : > "$W/reused"; : > "$W/reds"
  elif [ -n "$OFF" ] && [ "$OFF" != "would run nothing" ]; then
    LEDGER="off:$OFF"; : > "$W/reused"
  fi
fi

# 3. the counts
awk -F'\t' -v re="$SRE" -v lf="$W/L" -v bf="$W/bad" '
  BEGIN { while ((getline l < lf) > 0) inl[l] = 1; nb = 0 }
  $0 == "" { next }
  { s = $1 }
  s !~ re || index(s, "..") { nb++; next }
  (s in inl) && !(s in red) { red[s] = 1; print s }
  END { print nb > bf }' "$W/reds" > "$W/red.set"
REDS_BAD=$(cat "$W/bad" 2>/dev/null || echo 0)
grep -xF -f "$W/red.set" "$W/L" > "$FAILED" 2>/dev/null || : > "$FAILED"
[ -s "$W/red.set" ] || : > "$FAILED"
R=$(grep -c . < "$FAILED")
if [ "$LEDGER" = on ] && grep -qxF 'suite-reuse: off (would run nothing)' "$W/helper.out"; then
  G=$((N - R))
else
  G=$(cut -f1 "$W/reused" | awk -v lf="$W/L" -v rf="$W/red.set" '
    BEGIN { while ((getline l < lf) > 0) inl[l] = 1; while ((getline l < rf) > 0) r[l] = 1 }
    ($1 in inl) && !($1 in r) && !seen[$1]++ { n++ } END { print n + 0 }')
fi
U=$((N - G - R))
printf 'selected=%s green=%s red=%s unverified=%s ledger=%s reds=%s reds_bad=%s\n' \
  "$N" "$G" "$R" "$U" "$LEDGER" "$REDS_MODE" "$REDS_BAD" > "$SUMMARY"
echo "prequeue-ledger: selected $N, green $G, red $R, unverified $U (left to the batch)"
[ "$R" -gt 0 ] && exit 1
exit 0
