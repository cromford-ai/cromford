#!/bin/bash
# bin/test-impact-fallback-rate.sh --lists <dir> [--impact <script>] [--root <dir>]
#   [--map <file>] — HOW OFTEN DOES A PR SELECT RUN THE WHOLE CORPUS? (BH-7027)
#
# Each <dir>/*.txt is the changed-path list of one PR, one path per line; the
# file name (minus .txt) is the PR's name. For each list the script runs a
# PLAIN select (TI_BATCH_SELECT is unset, as in PR CI and the builder gate):
#
#   bash <impact> --root <root> select --map <map> --changed <list>
#
# and reads the last `impact:` line it prints on stderr. Output:
#
#   <name>\t<full|selected>\t<reason>          one row per list, sorted by name
#   fallback: <F> of <N> (<P>%)                F = rows whose reason starts full:
#   fallback-why: <count>\t<class>\t<top dir>  one row per full reason class
#
# <class> is the reason's words before the path ("infra change", "unknown
# reach"); <top dir> is the path's directory cut to two levels
# (catalog/lanes.d), `.` for a top-level file, `-` when the reason has no path.
#
#   rc 0  every list got an answer
#   rc 2  no *.txt in <dir>, an unreadable --map, a map that cannot be built,
#         or a run that printed no `impact:` line. No fallback: line is printed:
#         a run with no answer is never counted as selected.
#
# Defaults: --impact is this tree's bin/test-impact.sh, --root is this tree,
# and with no --map the script builds one map once (`<impact> map`). It reads
# local files only: no network, no gh, and no write outside its own mktemp -d.
#
# Before and after one change (the BH-7027 evidence row), from the repo root:
#
#   B=$(mktemp -d); mkdir -p "$B/bin"; git show origin/main:bin/test-impact.sh > "$B/bin/test-impact.sh"
#   bin/test-impact.sh map --out "$B/map"
#   bin/test-impact-fallback-rate.sh --lists <dir> --impact "$B/bin/test-impact.sh" --map "$B/map"
#   bin/test-impact-fallback-rate.sh --lists <dir> --map "$B/map"
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LISTS=""; IMPACT=""; SEL_ROOT="$ROOT"; MAP=""
usage() { sed -n '2,/^set -uo/{/^set -uo/d;s/^# \{0,1\}//;p}' "$0"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --lists)  LISTS="${2:-}"; shift 2 ;;
    --impact) IMPACT="${2:-}"; shift 2 ;;
    --root)   SEL_ROOT="${2:-}"; shift 2 ;;
    --map)    MAP="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "test-impact-fallback-rate: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
IMPACT="${IMPACT:-$ROOT/bin/test-impact.sh}"
[ -n "$LISTS" ] && [ -d "$LISTS" ] || { echo "test-impact-fallback-rate: --lists <dir> is required" >&2; exit 2; }
[ -r "$IMPACT" ] || { echo "test-impact-fallback-rate: no such impact script: $IMPACT" >&2; exit 2; }

files=()
while IFS= read -r f; do files+=("$f"); done < <(find "$LISTS" -maxdepth 1 -type f -name '*.txt' | LC_ALL=C sort)
[ "${#files[@]}" -gt 0 ] || { echo "test-impact-fallback-rate: no *.txt lists in $LISTS" >&2; exit 2; }

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
if [ -n "$MAP" ]; then
  [ -r "$MAP" ] || { echo "test-impact-fallback-rate: no such map: $MAP" >&2; exit 2; }
else
  MAP="$W/map"
  bash "$IMPACT" --root "$SEL_ROOT" map --out "$MAP" > /dev/null 2>&1 && [ -s "$MAP" ] \
    || { echo "test-impact-fallback-rate: the map could not be built" >&2; exit 2; }
fi

: > "$W/rows"
for f in "${files[@]}"; do
  name=$(basename "$f" .txt)
  env -u TI_BATCH_SELECT bash "$IMPACT" --root "$SEL_ROOT" select --map "$MAP" --changed "$f" \
    > /dev/null 2> "$W/err"
  line=$(grep '^impact:' "$W/err" | tail -1)
  [ -n "$line" ] || { echo "test-impact-fallback-rate: $name: the select printed no impact: line" >&2; exit 2; }
  # impact: <n> of <total> suites (<reason>)
  reason=$(printf '%s\n' "$line" | sed 's/^impact: [0-9]* of [0-9]* suites (\(.*\))$/\1/')
  case "$reason" in full:*) kind=full ;; *) kind=selected ;; esac
  printf '%s\t%s\t%s\n' "$name" "$kind" "$reason" >> "$W/rows"
done

cat "$W/rows"
awk -F'\t' '
  { n++ }
  $2 == "full" {
    f++; r = $3; sub(/^full: /, "", r); cls = r; dir = "-"
    if (match(r, / \(.*\)$/)) {
      cls = substr(r, 1, RSTART - 1); p = substr(r, RSTART + 2, RLENGTH - 3)
      k = split(p, a, "/")
      dir = (k <= 1) ? "." : (k == 2 ? a[1] : a[1] "/" a[2])
    }
    why[cls "\t" dir]++
  }
  END {
    printf "fallback: %d of %d (%d%%)\n", f, n, (n ? int(f * 100 / n + 0.5) : 0)
    fflush()
    srt = "LC_ALL=C sort -t\"\t\" -k1,1nr -k2 | sed \"s/^/fallback-why: /\""
    for (k in why) printf "%d\t%s\n", why[k], k | srt
    close(srt)
  }' "$W/rows"
