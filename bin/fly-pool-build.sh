#!/bin/bash
# bin/fly-pool-build.sh — render bin/fly-pool.sh from the fragments in
# config/fly-pool.d/ (BH-7454).
#
# Usage: bin/fly-pool-build.sh --check | --write | --absorb
#   --check   validate the fragments and compare their render with
#             bin/fly-pool.sh. Writes nothing.
#   --write   validate, run the merge guard seam, then replace bin/fly-pool.sh
#             with the render (temp file in bin/, chmod 755, mv).
#   --absorb  move a hand edit of bin/fly-pool.sh into the fragments (seam,
#             owner BH-7454.3, issue #7544; today it answers rc 2).
#
# The render is the `cat`, verbatim, of every config/fly-pool.d/NNNN-<name>.sh in
# LC_ALL=C name order. A name must match ^[0-9]{4}-[a-z0-9][a-z0-9-]*\.sh$;
# README.md is the only other file allowed there. The repo root is the parent of
# this script's own dir. No network, no env reads.
#
# rc 0  --check: render == bin/fly-pool.sh; --write: render written
# rc 1  bin/fly-pool.sh is stale, or a fragment fails bash -n or is empty
# rc 2  usage, a bad fragment name, no config/fly-pool.d/, no fragment, a seam
#       that cannot load, or --absorb (not built yet)
#
# Sourceable: `. bin/fly-pool-build.sh` defines fpb_root, fpb_fragments,
# fpb_validate and fpb_render and runs nothing.
set -uo pipefail
# Bash sorts a glob by LC_COLLATE, so the order rule needs this before any glob.
export LC_ALL=C

FPB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FPB_TMP=()

# fpb_root — print the repo root (the parent of this script's dir).
fpb_root() { dirname "$FPB_DIR"; }

# fpb_fragments [root] — print the fragment paths in LC_ALL=C order.
# rc 2 on a missing dir, a bad name or no fragment.
fpb_fragments() {
  local root=${1:-$(fpb_root)}
  local dir="$root/config/fly-pool.d"
  [ -d "$dir" ] || { echo "fly-pool-build: no config/fly-pool.d/ in $root" >&2; return 2; }
  (
    shopt -s dotglob nullglob
    local f name n=0 bad=0
    local -a frags=()
    for f in "$dir"/*; do
      name=${f##*/}
      [ "$name" = README.md ] && [ -f "$f" ] && continue
      if [ -d "$f" ] || ! [[ $name =~ ^[0-9]{4}-[a-z0-9][a-z0-9-]*\.sh$ ]]; then
        echo "fly-pool-build: config/fly-pool.d/$name is not a fragment name (want NNNN-<name>.sh, or README.md)" >&2
        bad=1; continue
      fi
      frags+=("$f"); n=$((n + 1))
    done
    [ "$bad" = 0 ] || exit 2
    [ "$n" -gt 0 ] || { echo "fly-pool-build: no fragment in config/fly-pool.d/" >&2; exit 2; }
    printf '%s\n' "${frags[@]}"
  )
}

# fpb_validate [root] — names (rc 2), then bash -n and non-empty on each (rc 1).
fpb_validate() {
  local list f err rc=0
  list=$(fpb_fragments "$@") || return $?
  while IFS= read -r f; do
    if [ ! -s "$f" ]; then
      echo "fly-pool-build: ${f##*/} is empty" >&2; rc=1; continue
    fi
    if ! err=$(bash -n "$f" 2>&1); then
      echo "fly-pool-build: ${f##*/} fails bash -n" >&2
      printf '%s\n' "$err" >&2; rc=1
    fi
  done <<< "$list"
  return "$rc"
}

# fpb_render <out> [root] — write the render of root's fragments to <out>.
fpb_render() {
  local out=${1:?fpb_render: want <out>} list f
  list=$(fpb_fragments "${2:-$(fpb_root)}") || return $?
  : > "$out" || return 1
  while IFS= read -r f; do
    cat "$f" >> "$out" || return 1
  done <<< "$list"
}

fpb_usage() { echo "usage: bin/fly-pool-build.sh --check | --write | --absorb" >&2; }

main() {
  local root target tmp
  root=$(fpb_root)
  target="$root/bin/fly-pool.sh"
  [ $# -eq 1 ] || { fpb_usage; return 2; }
  trap 'rm -f "${FPB_TMP[@]}"' EXIT
  case "$1" in
    --check)
      fpb_validate "$root" || return $?
      tmp=$(mktemp) || return 2
      FPB_TMP+=("$tmp")
      fpb_render "$tmp" "$root" || return $?
      if [ ! -f "$target" ] || ! cmp -s "$tmp" "$target"; then
        echo "bin/fly-pool.sh is stale: edit config/fly-pool.d/ and run bin/fly-pool-build.sh --write, or run --absorb to move a hand edit into the fragments" >&2
        return 1
      fi
      return 0 ;;
    --write)
      fpb_validate "$root" || return $?
      # shellcheck source=bin/lib/fly-pool-build-guard.sh
      . "$FPB_DIR/lib/fly-pool-build-guard.sh" || exit 2
      fpb_merge_guard || return $?
      tmp=$(mktemp "$root/bin/.fly-pool.sh.XXXXXX") || return 2
      FPB_TMP+=("$tmp")
      fpb_render "$tmp" "$root" || return $?
      chmod 755 "$tmp" && mv -f "$tmp" "$target" || return 1
      return 0 ;;
    --absorb)
      # shellcheck source=bin/lib/fly-pool-build-absorb.sh
      . "$FPB_DIR/lib/fly-pool-build-absorb.sh" || exit 2
      fpb_absorb; return $? ;;
    *) echo "fly-pool-build: unknown argument: $1" >&2; fpb_usage; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"; exit $?
fi
