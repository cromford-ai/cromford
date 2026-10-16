#!/bin/bash
# bin/split-host-growth-lint.sh [--base <ref>] [root]
#
# A split host script must not grow back (BH-6293). A host is a file under bin/
# with the marker line `# split-host: <module-dir>/ max-growth=<n>`: its
# function groups moved to <module-dir>, and new code goes there. A diff that
# adds more than <n> net lines (added minus deleted) to the host is refused.
# The limit is read from the marker at the merge-base when the host has one
# there, so a diff cannot raise its own limit or delete the marker to pass.
# Only hosts the diff touches are judged. A HEAD marker line that does not
# parse is a finding, also when the fork marker is valid. A diff that deletes
# the marker gets a stderr note (the fork limit still applies to that diff).
# A rules-pack component (catalog/rules-pack.tsv row split-host-growth), so the
# PR lint job's always-lints step, the builder gate and the lead review run it.
#
#   --base <ref>  judge the diff from the merge-base of <ref> and HEAD to HEAD
#                 (default: origin/main). The work tree is not read.
#   root          the checkout to scan (default: the current directory).
#   rc 0 clean (also when no host carries a marker)
#   rc 1 findings, one per stdout line:
#        `<host>: grew <net> lines in this diff (limit <n>; +<a> -<d>). Put new
#        code in <module-dir> and load it through <module-dir>load.sh.`
#        `<host>: malformed split-host marker: <line>`
#   rc 2 bad args, not a git work tree, or unresolvable base or merge-base
set -uo pipefail

BASE=origin/main; ROOT=.
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:-}"; [ -n "$BASE" ] || { echo "split-host-growth-lint: --base needs a ref" >&2; exit 2; }; shift 2 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    -*) echo "split-host-growth-lint: unknown argument $1" >&2; exit 2 ;;
    *) ROOT="$1"; shift ;;
  esac
done
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "split-host-growth-lint: $ROOT is not a git work tree" >&2; exit 2; }
git -C "$ROOT" rev-parse -q --verify "$BASE^{commit}" >/dev/null 2>&1 || { echo "split-host-growth-lint: cannot resolve $BASE" >&2; exit 2; }
FORK=$(git -C "$ROOT" merge-base "$BASE" HEAD 2>/dev/null) && [ -n "$FORK" ] \
  || { echo "split-host-growth-lint: no merge-base of $BASE and HEAD" >&2; exit 2; }

RE='^# split-host: (bin/[A-Za-z0-9_./-]+/) max-growth=([0-9]+)$'
# markers <rev> — "<path>\t<marker line>" for every marker line under bin/ at <rev>.
markers() {
  local out rc
  out=$(git -C "$ROOT" grep -I -E '^# split-host:' "$1" -- bin/ 2>/dev/null); rc=$?
  [ "$rc" -le 1 ] || return 2
  [ -n "$out" ] || return 0
  printf '%s\n' "$out" | sed "s|^$1:||" | sed 's|:|\t|'
}
FM=$(markers "$FORK") || { echo "split-host-growth-lint: cannot read the markers at $FORK" >&2; exit 2; }
HM=$(markers HEAD) || { echo "split-host-growth-lint: cannot read the markers at HEAD" >&2; exit 2; }

# first_valid <marker rows> <path> — "<dir>\t<limit>" of the path's first valid marker.
first_valid() {
  local p l
  while IFS=$'\t' read -r p l; do
    [ "$p" = "$2" ] || continue
    [[ $l =~ $RE ]] && { printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; return 0; }
  done <<<"$1"
  return 1
}

# Only a host this diff touches is judged: a bad marker already at the fork
# must not turn every unrelated PR red (BH-6293 review F1).
CHANGED=$(git -C "$ROOT" diff --name-only "$FORK" HEAD 2>/dev/null) \
  || { echo "split-host-growth-lint: cannot diff $FORK HEAD" >&2; exit 2; }
OUT=""; NBAD=0; NOVER=0
while IFS= read -r host; do
  [ -n "$host" ] || continue
  grep -qxF -- "$host" <<<"$CHANGED" || continue
  # A HEAD marker row that does not parse is a finding even when the fork
  # marker is valid, so the PR that breaks the marker is the one that goes red.
  while IFS=$'\t' read -r p l; do
    [ "$p" = "$host" ] || continue
    [[ $l =~ $RE ]] && continue
    OUT+="$host: malformed split-host marker: $l"$'\n'; NBAD=$((NBAD + 1))
  done <<<"$HM"
  if ! spec=$(first_valid "$FM" "$host") && ! spec=$(first_valid "$HM" "$host"); then
    continue
  fi
  if first_valid "$FM" "$host" >/dev/null && ! awk -F'\t' -v h="$host" '$1 == h { f = 1 } END { exit !f }' <<<"$HM"; then
    echo "split-host-growth-lint: $host: split-host marker removed in this diff; the fork limit applies to this diff only" >&2
  fi
  dir=${spec%%$'\t'*}; limit=${spec#*$'\t'}
  ns=$(git -C "$ROOT" diff --numstat "$FORK" HEAD -- "$host" 2>/dev/null) \
    || { echo "split-host-growth-lint: cannot diff $FORK HEAD -- $host" >&2; exit 2; }
  read -r a d < <(awk -F'\t' '{ a += ($1 == "-" ? 0 : $1); d += ($2 == "-" ? 0 : $2) } END { print a + 0, d + 0 }' <<<"$ns")
  net=$((a - d))
  if [ "$net" -gt "$limit" ]; then
    OUT+="$host: grew $net lines in this diff (limit $limit; +$a -$d). Put new code in $dir and load it through ${dir}load.sh."$'\n'
    NOVER=$((NOVER + 1))
  fi
done < <(printf '%s\n%s\n' "$FM" "$HM" | cut -f1 | grep . | sort -u)

[ -n "$OUT" ] || exit 0
printf '%s' "$OUT"
[ "$NOVER" -eq 0 ] || echo "split-host-growth-lint: $NOVER host(s) over the limit" >&2
[ "$NBAD" -eq 0 ] || echo "split-host-growth-lint: $NBAD malformed split-host marker(s)" >&2
exit 1
