#!/bin/bash
# bin/lead-review-libs-build.sh [--root <dir>] --print|--check
#
# The optional libs of bin/lead-review.sh are one fragment file each in
# bin/lib/lead-review/libs.d/. The host sources every *.sh there at top level,
# sorted by name under LC_ALL=C. Nothing is rendered to disk: the host joins
# the fragments when it runs (docs/notes/2026-10-19-BH-7455-lead-review-libs.md).
#
# NAMES. The entries that moved out of the host are NNNN-<name>.sh, step 10 in
# the old order. A new entry is <yyyymmddhhmm>-<ticket-key>-<name>.sh (the UTC
# minute the builder creates it), the bin/schema-build.sh rule (BH-5788): the
# key makes the name unique and the same name sort loads it after every older
# entry.
#
# FORMAT. Line 1 `#!/bin/bash`, line 2 `# shellcheck shell=bash`, line 3
# `# bin/lib/lead-review/libs.d/<own file name> — <what it is>`. Lines 4+ are
# the entry, as it would stand in the host.
#
#   --print   the join: lines 4+ of each fragment, in load order. rc 1 when the
#             directory holds no fragment.
#   --check   validate the directory; each fault prints one
#             `lead-review-libs: <path>: <reason>` line on stderr:
#               * a name that is neither NNNN-<name>.sh nor
#                 <yyyymmddhhmm>-bh-<n>[.<m>]-<name>.sh (lower case)
#               * an entry that is not a *.sh file (README, x.sh.bak, a dir)
#               * a header that is not the 3-line shape naming its own file
#               * a `# module:` line (bin/module-map-build.sh would take
#                 libs.d/ for a module dir)
#               * a fragment that fails `bash -n`
#               * two fragments with the same entry body (a duplicate entry)
#               * no fragment at all
#               * a render of the fragments tracked in git
#                 (bin/lib/lead-review/libs.sh or libs.d.sh): a committed join
#                 would conflict exactly as the host did
#             With no fault: `lead-review-libs: <n> fragments ok` on stdout.
#   --root    the repo root (default: this script's repo)
#
# Exit: 0 OK, 1 a check failure (or --print with no fragment), 2 a usage error.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE=""
usage() { echo "usage: bin/lead-review-libs-build.sh [--root <dir>] --print|--check" >&2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --root)  [ $# -ge 2 ] || { usage; exit 2; }; ROOT="$2"; shift 2 ;;
    --print) MODE=print; shift ;;
    --check) MODE=check; shift ;;
    *) echo "lead-review-libs: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
[ -n "$MODE" ] || { usage; exit 2; }
[ -d "$ROOT" ] || { echo "lead-review-libs: --root $ROOT is not a directory" >&2; exit 2; }

REL=bin/lib/lead-review/libs.d
DIR="$ROOT/$REL"
NAME_RE='^([0-9]{4}-[a-z0-9-]+|[0-9]{12}-bh-[0-9]+(\.[0-9]+)?-[a-z0-9-]+)\.sh$'

# The fragments in load order: the same set and order as the host's loader.
FRAGS=()
if [ -d "$DIR" ]; then
  mapfile -t FRAGS < <(for f in "$DIR"/*.sh; do [ -f "$f" ] && printf '%s\n' "${f##*/}"; done | LC_ALL=C sort)
fi

if [ "$MODE" = print ]; then
  [ "${#FRAGS[@]}" -gt 0 ] || { echo "lead-review-libs: $REL/ has no fragment" >&2; exit 1; }
  for f in "${FRAGS[@]}"; do tail -n +4 "$DIR/$f"; done
  exit 0
fi

BAD=0
fault() { echo "lead-review-libs: $1" >&2; BAD=1; }

if [ -d "$DIR" ]; then
  for p in "$DIR"/* "$DIR"/.[!.]*; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    n=${p##*/}
    if [ ! -f "$p" ] || [[ $n != *.sh ]]; then
      fault "$REL/$n: not a *.sh fragment file (the host never loads it)"
    elif ! [[ $n =~ $NAME_RE ]]; then
      fault "$REL/$n: bad name; want NNNN-<name>.sh or <yyyymmddhhmm>-bh-<n>-<name>.sh"
    fi
  done
fi
[ "${#FRAGS[@]}" -gt 0 ] || fault "$REL/: has no fragment"

declare -A BODY=()
for n in "${FRAGS[@]}"; do
  f="$DIR/$n"
  l1=$(sed -n 1p "$f"); l2=$(sed -n 2p "$f"); l3=$(sed -n 3p "$f")
  if [ "$l1" != '#!/bin/bash' ] || [ "$l2" != '# shellcheck shell=bash' ] || [[ $l3 != "# $REL/$n "* ]]; then
    fault "$REL/$n: bad header; want '#!/bin/bash', '# shellcheck shell=bash', '# $REL/$n — <what it is>'"
  fi
  grep -q '^# module:' "$f" && fault "$REL/$n: has a '# module:' line; libs.d/ is not a module dir"
  bash -n "$f" 2>/dev/null || fault "$REL/$n: does not parse (bash -n)"
  sum=$(tail -n +4 "$f" | sha256sum | cut -d' ' -f1)
  if [ -n "${BODY[$sum]:-}" ]; then
    fault "$REL/$n: the same entry as $REL/${BODY[$sum]} (a duplicate entry)"
  else
    BODY[$sum]=$n
  fi
done

if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  while IFS= read -r t; do
    [ -n "$t" ] && fault "$t: a render of $REL/ is tracked in git; the host joins the fragments itself, so git rm --cached $t"
  done < <(git -C "$ROOT" ls-files -- bin/lib/lead-review/libs.sh bin/lib/lead-review/libs.d.sh)
fi

[ "$BAD" = 0 ] || exit 1
echo "lead-review-libs: ${#FRAGS[@]} fragments ok"
exit 0
