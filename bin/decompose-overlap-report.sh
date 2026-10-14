#!/bin/bash
# bin/decompose-overlap-report.sh — did the siblings of a split edit the same
# non-seam file? The real-traffic metric for BH-6384 (seam file per sibling,
# `Owns:` lines), before and after the rule.
#
# Usage:
#   decompose-overlap-report.sh before [--last N] [--projects "p1 p2"] [<build-dir>...]
#   decompose-overlap-report.sh after  [--last N] [--projects "p1 p2"] [--yes] [<build-dir>...]
#
# Parents: the build dirs given, else the newest N (default 20) dirs under
# builds/[pool-]<project>-* whose RESULT starts with DECOMPOSED, over the
# projects named (default: every project `bin/fleet-conf.sh --projects` lists;
# an empty or failed read stops the run with rc 1, never "no parents").
#
# before — what the merged code did. For each parent: the child keys from
#   children.txt (line 1 is the contract), the seam paths from the contract's
#   CONTRACT: line, and each sibling's merged PR files (head ticket/<key>,
#   REST through bin/lib/gh-rest.sh). A non-seam overlap is a path in the
#   merged diffs of 2 or more siblings that the CONTRACT line does not name.
#   A pool parent (relayed from a Fly box) has only RESULT: the keys come from
#   its `DECOMPOSED k1,k2,...` line, and the seams are the contract child's
#   merged PR files (contract unread or unmerged: the parent is unmeasured). A
#   sibling with no merged PR counts as `unmerged`, never as "no overlap".
# after — what the new prompt asks for. For each parent, a replay dir
#   state/decompose-replay/<build-dir-name>/ gets plan.md, ticket-body.md,
#   ticket-meta.json, job.json and size-gate.txt, and one DECOMPOSE_DRY_RUN=1
#   bin/run-decompose.sh writes its children.json (one model call, stage
#   decompose). A replay dir that already has a children.json is reused and
#   never bought twice. A non-seam overlap is a path in the `owns` of 2 or more
#   siblings with no `after` link between them; a `fallback` is a sibling
#   `after` entry that says "same file" (the hard fallback of the rule).
#   Without --yes, a run that needs any model call prints the parents and the
#   number of calls, and exits 0 having made none.
#
# Output: one TSV row per parent
#   project  parent  children  overlap_paths  unmerged  fallback_count  unread
# (`unread` is `before` only: siblings whose PR read failed, kept apart from
# `unmerged` so a GitHub error never reads as an unmerged child.)
# then `REPORT <mode> parents=<n> with_overlap=<k> fallback_parents=<f> unmeasured=<u>`.
# `unmeasured` counts parents it could not read in full (no children.txt, a
# sibling with no merged PR, no repo, no children.json), so a parent it could
# not judge is never counted as clean. rc 0, 1 when the fleet project list is
# unreadable, or 2 on a usage error.
set -u
HARNESS="${HARNESS:-/root/harness}"
HERE=$(cd "$(dirname "$0")" && pwd)
MODE="${1:-}"
case "$MODE" in before|after) shift ;; *) echo "usage: decompose-overlap-report.sh before|after [--last N] [--projects \"p1 p2\"] [--yes] [<build-dir>...]" >&2; exit 2 ;; esac
LAST=20; PROJECTS=""; YES=0; DIRS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --last) LAST="${2:-}"; shift 2 ;;
    --projects) PROJECTS="${2:-}"; shift 2 ;;
    --yes) YES=1; shift ;;
    -*) echo "decompose-overlap-report: unknown flag '$1'" >&2; exit 2 ;;
    *) DIRS+=("$1"); shift ;;
  esac
done
case "$LAST" in ''|*[!0-9]*) echo "decompose-overlap-report: --last takes a number" >&2; exit 2 ;; esac
# The default project list is the fleet's own answer, never a literal here.
if [ "${#DIRS[@]}" -eq 0 ] && [ -z "$PROJECTS" ]; then
  PROJECTS=$("$HERE/fleet-conf.sh" --projects 2>/dev/null | tr '\n' ' ') && [ -n "${PROJECTS// /}" ] \
    || { echo "decompose-overlap-report: bin/fleet-conf.sh --projects gave no project list; pass --projects or build dirs" >&2; exit 1; }
fi

if [ "${#DIRS[@]}" -eq 0 ]; then
  while IFS= read -r d; do [ -n "$d" ] && DIRS+=("$d"); done < <(
    for p in $PROJECTS; do
      for d in "$HARNESS/builds/$p"-* "$HARNESS/builds/pool-$p"-*; do
        [ -d "$d" ] || continue
        head -1 "$d/RESULT" 2>/dev/null | grep -q '^DECOMPOSED' || continue
        printf '%s\t%s\n' "$(stat -c %Y "$d" 2>/dev/null || echo 0)" "$d"
      done
    done | awk -F'\t' '!seen[$2]++' | sort -rn | head -n "$LAST" | cut -f2)
fi

# _project <dir> — job.json's project, else the dir name minus pool- and
# -<KEY>-<stamp>.
_project() {
  local p
  p=$(jq -r '.project // empty' "$1/job.json" 2>/dev/null)
  [ -n "$p" ] || p=$(basename "$1" | sed -E -e 's/^pool-//' -e 's/-[A-Z]+-[0-9.]+-[0-9]+$//')
  printf '%s\n' "$p"
}

# _seams <contract-body> — the paths the CONTRACT: line names, one per line.
_seams() {
  sed -n 's/^CONTRACT:[[:space:]]*//p' "$1" 2>/dev/null | tr ' ;,' '\n\n\n' \
    | sed -E 's/[:()]+$//' | grep -E '/|\.[A-Za-z0-9]+$' | grep -vE '\(\)$' | LC_ALL=C sort -u
}

ROWS=""; NP=0; NOV=0; NFB=0; NUN=0

if [ "$MODE" = before ]; then
  # shellcheck source=bin/lib/gh-rest.sh
  . "$HERE/lib/gh-rest.sh" || { echo "decompose-overlap-report: bin/lib/gh-rest.sh is missing" >&2; exit 2; }
  TMPF=$(mktemp "${TMPDIR:-/tmp}/dor.XXXXXX") || exit 2
  trap 'rm -f "$TMPF"' EXIT
  for d in ${DIRS[@]+"${DIRS[@]}"}; do
    P=$(_project "$d"); PARENT=$(basename "$d"); NP=$((NP + 1))
    REPO=$("$HERE/fleet-conf.sh" "$P" repo 2>/dev/null)
    mapfile -t KEYS < <(grep -v '^[[:space:]]*$' "$d/children.txt" 2>/dev/null)
    # A pool parent relayed from a Fly box has no children.txt: its RESULT
    # line 1 `DECOMPOSED k1,k2,...` lists the same keys in land order, the
    # contract first (bin/lib/split-chain.sh reads it the same way).
    if [ "${#KEYS[@]}" -eq 0 ]; then
      mapfile -t KEYS < <(sed -n '1s/^DECOMPOSED[[:space:]]*//p' "$d/RESULT" 2>/dev/null | tr ',' '\n' | grep -v '^[[:space:]]*$')
    fi
    if [ "${#KEYS[@]}" -lt 2 ] || [ -z "$REPO" ]; then
      ROWS="$ROWS$P	$PARENT	${#KEYS[@]}	-	unreadable	-	-
"; NUN=$((NUN + 1)); continue
    fi
    FILES=""; UNM=0; UNR=0; i=1
    if [ -f "$d/children/child-1.md" ]; then
      SEAMS=$(_seams "$d/children/child-1.md")
    else
      # No contract body on this box: the seams are the files the contract
      # child's merged PR created or changed. Unread or unmerged: the parent
      # is unmeasured, never "no seams".
      SEAMS=""
      br="ticket/$(printf '%s' "${KEYS[0]}" | tr '[:upper:]' '[:lower:]')"
      rc=0; gh_rest GET "repos/$REPO/pulls?state=closed&head=${REPO%%/*}:$br&per_page=20" > "$TMPF" 2>/dev/null || rc=$?
      num=""; [ "$rc" = 0 ] && num=$(jq -r '[.[] | select(.merged_at != null)][0].number // empty' "$TMPF" 2>/dev/null)
      if [ "$rc" != 0 ]; then UNR=$((UNR + 1))
      elif [ -z "$num" ]; then UNM=$((UNM + 1))
      else
        rc=0; gh_rest GET "repos/$REPO/pulls/$num/files?per_page=100" > "$TMPF" 2>/dev/null || rc=$?
        if [ "$rc" = 0 ]; then SEAMS=$(jq -r '.[].filename' "$TMPF" 2>/dev/null | LC_ALL=C sort -u); else UNR=$((UNR + 1)); fi
      fi
    fi
    while [ "$i" -lt "${#KEYS[@]}" ]; do
      br="ticket/$(printf '%s' "${KEYS[$i]}" | tr '[:upper:]' '[:lower:]')"
      i=$((i + 1))
      # Through a file, never `$( )`: GH_REST_STATUS lives in this shell.
      rc=0; gh_rest GET "repos/$REPO/pulls?state=closed&head=${REPO%%/*}:$br&per_page=20" > "$TMPF" 2>/dev/null || rc=$?
      if [ "$rc" != 0 ]; then UNR=$((UNR + 1)); continue; fi
      num=$(jq -r '[.[] | select(.merged_at != null)][0].number // empty' "$TMPF" 2>/dev/null)
      if [ -z "$num" ]; then UNM=$((UNM + 1)); continue; fi
      rc=0; gh_rest GET "repos/$REPO/pulls/$num/files?per_page=100" > "$TMPF" 2>/dev/null || rc=$?
      f=$(jq -r '.[].filename' "$TMPF" 2>/dev/null)
      if [ "$rc" != 0 ] || [ -z "$f" ]; then UNR=$((UNR + 1)); continue; fi
      FILES="$FILES$(printf '%s\n' "$f" | LC_ALL=C sort -u)
"
    done
    OV=$(printf '%s' "$FILES" | sed '/^$/d' | LC_ALL=C sort | uniq -d \
         | LC_ALL=C comm -23 - <(printf '%s\n' "$SEAMS") | paste -sd, -)
    [ -n "$OV" ] && NOV=$((NOV + 1))
    [ $((UNM + UNR)) -gt 0 ] && NUN=$((NUN + 1))
    ROWS="$ROWS$P	$PARENT	${#KEYS[@]}	${OV:--}	$UNM	-	$UNR
"
  done
  printf '%s' "$ROWS"
  echo "REPORT before parents=$NP with_overlap=$NOV fallback_parents=- unmeasured=$NUN"
  exit 0
fi

# ---- after ----------------------------------------------------------------
NEED=0
for d in ${DIRS[@]+"${DIRS[@]}"}; do
  [ -s "$HARNESS/state/decompose-replay/$(basename "$d")/children.json" ] || NEED=$((NEED + 1))
done
if [ "$NEED" -gt 0 ] && [ "$YES" != 1 ]; then
  for d in ${DIRS[@]+"${DIRS[@]}"}; do
    [ -s "$HARNESS/state/decompose-replay/$(basename "$d")/children.json" ] || echo "REPLAY needs-call $d"
  done
  echo "REPORT after-plan parents=${#DIRS[@]} model_calls=$NEED — rerun with --yes to spend them"
  exit 0
fi
for d in ${DIRS[@]+"${DIRS[@]}"}; do
  P=$(_project "$d"); PARENT=$(basename "$d"); NP=$((NP + 1))
  R="$HARNESS/state/decompose-replay/$PARENT"
  if [ ! -s "$R/children.json" ]; then
    mkdir -p "$R"
    for f in plan.md ticket-body.md ticket-meta.json job.json size-gate.txt; do
      [ -r "$d/$f" ] && cp "$d/$f" "$R/$f"
    done
    TID=$(jq -r '.ticket_id // empty' "$d/job.json" 2>/dev/null)
    KEY=$(jq -r '.key // empty' "$d/job.json" 2>/dev/null)
    if [ -n "$TID" ] && [ -n "$KEY" ]; then
      HARNESS="$HARNESS" DECOMPOSE_DRY_RUN=1 timeout 2700 "$HERE/run-decompose.sh" "$P" "$TID" "$KEY" "$R" </dev/null >/dev/null 2>&1
    fi
  fi
  if ! jq -e 'type == "array" and length >= 2' "$R/children.json" >/dev/null 2>&1; then
    ROWS="$ROWS$P	$PARENT	-	-	unreadable	-	-
"; NUN=$((NUN + 1)); continue
  fi
  # Siblings are positions 2..N (1-based). A pair is linked when the later one
  # names the earlier one's position in `after`.
  read -r NC OV FB < <(jq -r '
    . as $s | length as $n
    | [range(1; $n) as $a | range($a + 1; $n) as $b
       | (($s[$b].after // []) | map(tostring | split(":")[0] | gsub("\\s"; "")) | index(($a + 1) | tostring)) as $lk
       | select($lk == null)
       | (($s[$a].owns // []) - (($s[$a].owns // []) - ($s[$b].owns // [])))[]] | unique | join(",") as $ov
    | [range(1; $n) | $s[.].after // [] | .[] | tostring | select(test("same file"; "i"))] | length as $fb
    | "\($n) \(if $ov == "" then "-" else $ov end) \($fb)"' "$R/children.json" 2>/dev/null)
  [ "${OV:--}" != - ] && NOV=$((NOV + 1))
  [ "${FB:-0}" -gt 0 ] && NFB=$((NFB + 1))
  ROWS="$ROWS$P	$PARENT	${NC:--}	${OV:--}	0	${FB:-0}	-
"
done
printf '%s' "$ROWS"
echo "REPORT after parents=$NP with_overlap=$NOV fallback_parents=$NFB unmeasured=$NUN"
exit 0
