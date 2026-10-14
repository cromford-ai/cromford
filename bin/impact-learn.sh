#!/bin/bash
# bin/impact-learn.sh — A MERGE-QUEUE EJECTION TEACHES THE IMPACT MAP THE EDGE
# IT MISSED (BH-6390).
#
#   bin/impact-learn.sh record --event <file> [--root <dir>] [--base <ref>]
#                              [--out-dir <dir>] [--max-paths N]
#                              [--map <file>]
#   bin/impact-learn.sh expire --counts <file> --passes N [--out-dir <dir>]
#                              [--keep <file>]
#
# --event     ONE dequeue_events row as JSON, the object shape
#             dqw_events_list (bin/lib/jobs/dequeue-watch.sh) returns in .rows[].
# --root      the checkout whose map is asked (default: this script's repo).
# --base      the ref the culprit's merge base is taken against (default
#             origin/main).
# --out-dir   where the fragments go (default
#             <root>/catalog/test-impact-learned.d).
# --max-paths the most changed paths one suite may learn from one event; a
#             wider culprit teaches nothing (default: env
#             IMPACT_LEARN_MAX_PATHS, else 10).
# --map       a map `bin/test-impact.sh map` already built for <root>; the
#             select reads it instead of building one (bin/impact-learn-lane.sh
#             builds it once per tick). A map that cannot be read is rc 1.
#
# WHAT IT DOES. The event must be attribution `culprit` with class `rule-break`
# or `semantic-test` and at least one named `tests/…sh` suite; anything else is
# `skip event`, rc 0, 0 writes. The culprit's changed paths are
# `git diff --name-only --diff-filter=d <merge-base> <head>`. The map's own
# answer for those paths is `bin/test-impact.sh select --map-only`. For each
# named suite S that answer did not pick, it writes one fragment per changed
# path (not *.md, not .harness/), or one `*` row when S carries the line
# `# test-impact: whole-repo`. bin/test-impact.sh reads the fragments into the
# map (ti_learned_rows), so the next select for that path picks S.
#
# THE STORE. One file per edge, catalog/test-impact-learned.d/<key>.tsv, where
# <key> is the first 16 hex of sha1("<path>\t<suite>"): the same edge is always
# the same file, so a replayed event writes nothing. Each file is one comment
# line and one data line, `<path>\t<suite>\t<repo>#<pr> run <run_id>\t<date>`.
# The date is the event's created_at, never the clock.
#
# It never commits, pushes or opens a PR, and it reads no network.
#
# Exit: 0 the event was processed (the edges written are on stdout); 1 the
# event or the select could not be read, or a write failed; 2 usage; 3 the head
# or the base does not resolve. Only rc 0 and a failed write can leave files.
#
# EXPIRE (BH-6460). An edge expires when its suite passed N times with no
# failure after the edge's date. --counts is a TSV, one line per (edge date,
# suite): `<YYYY-MM-DD>\t<suite>\t<passes>\t<fails>`, the date being the
# fragment's field 4 (bin/impact-learn-lane.sh writes it from the
# suite_results ledger). The whole file is validated before the first delete.
# --keep names fragment basenames, one per line, that are never expired (this
# tick's new or re-confirmed edges). For each <out-dir>/*.tsv, in name order:
# a file whose first line is not the learner's comment is a hand row and is
# kept; so is a kept basename, an unreadable data line, a (date, suite) with no
# counts line, fails > 0, or passes < N. Else the file is deleted, and
# `expire <suite> <path> <file> passes=<p>` prints only once it is gone. The
# last line is `impact-learn: expire expired=<n> kept=<n>`.
#
# Exit (expire): 0 done (the files deleted are exactly the `expire` lines); 1
# the counts cannot be read, a line is malformed, a (date, suite) repeats
# (nothing deleted), or a file is still there after rm (the files before it
# are deleted); 2 usage (nothing read).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
BASE=origin/main
EVENT=""
OUT_DIR=""
MAX_PATHS="${IMPACT_LEARN_MAX_PATHS:-10}"
MAP=""

usage() { sed -n '5,9p' "$0" >&2; exit 2; }

# real_day <s> — true when <s> is a YYYY-MM-DD calendar day.
real_day() {
  [ -n "$1" ] || return 1
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [ "$(date -u -d "$1" +%F 2>/dev/null)" = "$1" ]
}

# expire_main <args> — the expire verb; its own exit code.
expire_main() {
  local counts="" passes="" keep="" line d s p f n k file data first base
  local -A cnt=()
  local -a kept_names=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --counts|--passes|--out-dir|--keep)
        [ $# -ge 2 ] || { echo "impact-learn: $1 needs a value" >&2; return 2; }
        case "$1" in
          --counts) counts="$2" ;; --passes) passes="$2" ;;
          --out-dir) OUT_DIR="$2" ;; --keep) keep="$2" ;;
        esac
        shift ;;
      *) echo "impact-learn: unknown argument '$1'" >&2; usage ;;
    esac
    shift
  done
  [ -n "$counts" ] || { echo "impact-learn: expire needs --counts <file>" >&2; return 2; }
  [[ "$passes" =~ ^[1-9][0-9]{0,5}$ ]] || { echo "impact-learn: --passes must be a positive integer, got '$passes'" >&2; return 2; }
  OUT_DIR="${OUT_DIR:-$ROOT/catalog/test-impact-learned.d}"

  [ -f "$counts" ] && [ -r "$counts" ] || { echo "impact-learn: cannot read the counts $counts — nothing expired" >&2; return 1; }
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    IFS=$'\t' read -r d s p f k <<<"$line"
    if [ -n "$k" ] || ! real_day "$d" || [ -z "$s" ] || [[ ! "$p" =~ ^[0-9]{1,9}$ ]] || [[ ! "$f" =~ ^[0-9]{1,9}$ ]] \
       || [ "$line" != "$d"$'\t'"$s"$'\t'"$p"$'\t'"$f" ]; then
      echo "impact-learn: counts line $n is not <date>\\t<suite>\\t<passes>\\t<fails>: '$line' — nothing expired" >&2; return 1
    fi
    [ -z "${cnt["$d"$'\t'"$s"]+x}" ] || { echo "impact-learn: counts line $n repeats $d $s — nothing expired" >&2; return 1; }
    cnt["$d"$'\t'"$s"]="$((10#$p)) $((10#$f))"
  done < "$counts"
  if [ -n "$keep" ]; then
    [ -f "$keep" ] && [ -r "$keep" ] || { echo "impact-learn: cannot read the keep list $keep — nothing expired" >&2; return 1; }
    while IFS= read -r line || [ -n "$line" ]; do [ -n "$line" ] && kept_names+=("$line"); done < "$keep"
  fi

  local expired=0 kept=0 pf
  while IFS= read -r file; do
    [ -n "$file" ] && [ -f "$file" ] || continue
    base="${file##*/}"
    IFS= read -r first < "$file" || first=""
    case "$first" in '# bin/impact-learn.sh:'*) ;; *) echo "keep $file (hand)"; kept=$((kept + 1)); continue ;; esac
    case " ${kept_names[*]-} " in *" $base "*) echo "keep $file (this tick)"; kept=$((kept + 1)); continue ;; esac
    data=$(grep -v '^#' "$file" | head -1)
    IFS=$'\t' read -r p s _ d k <<<"$data"
    if [ -z "$p" ] || [ -z "$s" ] || [ -n "$k" ] || ! real_day "$d"; then
      echo "keep $file (unreadable)"; kept=$((kept + 1)); continue
    fi
    pf="${cnt["$d"$'\t'"$s"]-}"
    if [ -z "$pf" ]; then echo "keep $s $p (no ledger rows)"; kept=$((kept + 1)); continue; fi
    if [ "${pf#* }" -gt 0 ]; then echo "keep $s $p (fails=${pf#* })"; kept=$((kept + 1)); continue; fi
    if [ "${pf% *}" -lt "$passes" ]; then echo "keep $s $p (passes=${pf% *} < $passes)"; kept=$((kept + 1)); continue; fi
    rm -f -- "$file"
    if [ -e "$file" ]; then
      echo "impact-learn: cannot delete $file — expired=$expired before it" >&2; return 1
    fi
    echo "expire $s $p $file passes=${pf% *}"; expired=$((expired + 1))
  done < <(find "$OUT_DIR" -maxdepth 1 -name '*.tsv' -type f 2>/dev/null | LC_ALL=C sort)
  echo "impact-learn: expire expired=$expired kept=$kept"
  return 0
}

case "${1:-}" in
  record) ;;
  expire) shift; expire_main "$@"; exit $? ;;
  *) usage ;;
esac
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --event|--root|--base|--out-dir|--max-paths|--map)
      [ $# -ge 2 ] || { echo "impact-learn: $1 needs a value" >&2; exit 2; }
      case "$1" in
        --event) EVENT="$2" ;; --root) ROOT="$2" ;; --base) BASE="$2" ;;
        --out-dir) OUT_DIR="$2" ;; --max-paths) MAX_PATHS="$2" ;; --map) MAP="$2" ;;
      esac
      shift ;;
    *) echo "impact-learn: unknown argument '$1'" >&2; usage ;;
  esac
  shift
done
[ -n "$EVENT" ] || { echo "impact-learn: record needs --event <file>" >&2; usage; }
[[ "$MAX_PATHS" =~ ^[1-9][0-9]*$ ]] || { echo "impact-learn: --max-paths must be a positive integer, got '$MAX_PATHS'" >&2; exit 2; }
OUT_DIR="${OUT_DIR:-$ROOT/catalog/test-impact-learned.d}"
MAP_ARGS=()
if [ -n "$MAP" ]; then
  [ -f "$MAP" ] && [ -r "$MAP" ] || { echo "impact-learn: no such map $MAP" >&2; exit 1; }
  MAP_ARGS=(--map "$MAP")
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/impact-learn.XXXXXX") || { echo "impact-learn: cannot make a temp dir" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# ── the event ───────────────────────────────────────────────────────────────
fields=$(jq -r '[.attribution, .class, .suites, .head, .repo, .pr, .run_id, .created_at]
                | map(if . == null then "" else (tostring | gsub("[\n\t\u0001]"; " ")) end) | join("\u0001")' "$EVENT" 2>/dev/null) || {
  echo "impact-learn: cannot read the event $EVENT" >&2; exit 1; }
IFS=$'\001' read -r attribution class suites_raw head repo pr run_id created_at <<<"$fields"

case "$attribution" in culprit) ;; *) echo "impact-learn: skip event (attribution '$attribution' is not culprit)"; exit 0 ;; esac
case "$class" in rule-break|semantic-test) ;; *) echo "impact-learn: skip event (class '$class' is not rule-break or semantic-test)"; exit 0 ;; esac
SUITES=()
for s in $(printf '%s' "$suites_raw" | tr ',' ' '); do
  [[ "$s" =~ ^tests/(mc/)?[A-Za-z0-9._-]+\.sh$ ]] || continue
  case " ${SUITES[*]-} " in *" $s "*) continue ;; esac
  SUITES+=("$s")
done
[ "${#SUITES[@]}" -gt 0 ] || { echo "impact-learn: skip event (no named tests/ suite in '$suites_raw')"; exit 0; }

date="${created_at:0:10}"
[[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "impact-learn: the event has no readable created_at ('$created_at')" >&2; exit 1; }
src="$repo#$pr run $run_id"
[ -n "$repo" ] && [ -n "$pr" ] && [ -n "$run_id" ] && [[ "$src" != *[$'\t\n']* ]] || {
  echo "impact-learn: the event has no readable repo, pr or run_id" >&2; exit 1; }

# ── the culprit's paths ─────────────────────────────────────────────────────
[[ "$head" =~ ^[0-9a-f]{40}$ ]] && git -C "$ROOT" cat-file -e "$head^{commit}" 2>/dev/null || {
  echo "impact-learn: the head '$head' is not a commit in $ROOT" >&2; exit 3; }
mb=$(git -C "$ROOT" merge-base "$BASE" "$head" 2>/dev/null) && [ -n "$mb" ] || {
  echo "impact-learn: no merge base of '$BASE' and $head in $ROOT" >&2; exit 3; }
git -C "$ROOT" diff --name-only --diff-filter=d "$mb" "$head" > "$TMP/changed" || {
  echo "impact-learn: cannot diff $mb..$head" >&2; exit 1; }
PATHS=()
while IFS= read -r p; do
  case "$p" in ''|*.md|.harness/*) continue ;; esac
  PATHS+=("$p")
done < "$TMP/changed"

# ── the map's answer for those paths ────────────────────────────────────────
"$SELF_DIR/test-impact.sh" --root "$ROOT" ${MAP_ARGS[@]+"${MAP_ARGS[@]}"} select --map-only --changed "$TMP/changed" > "$TMP/sel" 2> "$TMP/reason"
rc=$?
reason=$(grep '^impact: ' "$TMP/reason" | tail -1)
if [ "$rc" != 0 ] || [ -z "$reason" ] || [[ "$reason" == *"(full:"* ]]; then
  echo "impact-learn: the map could not answer for $repo#$pr (rc=$rc, ${reason:-no reason line}) — 0 edges written" >&2
  exit 1
fi

# ── the edges ───────────────────────────────────────────────────────────────
key() { printf '%s\t%s' "$1" "$2" | sha1sum | cut -c1-16; }
written=0 exists=0 selected=0 skipped=0
# write_edge <suite> <path> — one fragment, tmp + mv; an existing key is kept.
write_edge() {
  local s="$1" p="$2" k f
  k=$(key "$p" "$s") && [ -n "$k" ] || { echo "impact-learn: cannot hash $p $s" >&2; exit 1; }
  f="$OUT_DIR/$k.tsv"
  if [ -e "$f" ]; then echo "exists $s $p $f"; exists=$((exists + 1)); return 0; fi
  mkdir -p "$OUT_DIR" && {
    printf '# bin/impact-learn.sh: %s failed merge-queue run %s for %s#%s head %s; the map did not select it.\n' \
      "$s" "$run_id" "$repo" "$pr" "$head"
    printf '%s\t%s\t%s\t%s\n' "$p" "$s" "$src" "$date"
  } > "$OUT_DIR/.$k.tsv.tmp" && mv "$OUT_DIR/.$k.tsv.tmp" "$f" && [ -f "$f" ] || {
    rm -f "$OUT_DIR/.$k.tsv.tmp"
    echo "impact-learn: cannot write $f — $written edge(s) written before it" >&2; exit 1; }
  echo "edge $s $p $f"; written=$((written + 1))
}

for s in "${SUITES[@]}"; do
  if [ ! -f "$ROOT/$s" ]; then echo "skip $s (no such suite)"; skipped=$((skipped + 1)); continue; fi
  if grep -qxF "$s" "$TMP/sel"; then echo "selected $s"; selected=$((selected + 1)); continue; fi
  if grep -qx '# test-impact: whole-repo' "$ROOT/$s"; then
    echo "whole-repo $s"; write_edge "$s" '*'; continue
  fi
  if [ "${#PATHS[@]}" -eq 0 ]; then echo "skip $s (no learnable path)"; skipped=$((skipped + 1)); continue; fi
  if [ "${#PATHS[@]}" -gt "$MAX_PATHS" ]; then
    echo "skip $s (wide: ${#PATHS[@]} paths > $MAX_PATHS)"; skipped=$((skipped + 1)); continue
  fi
  for p in "${PATHS[@]}"; do write_edge "$s" "$p"; done
done

echo "impact-learn: event $repo#$pr run $run_id written=$written exists=$exists selected=$selected skipped=$skipped"
exit 0
