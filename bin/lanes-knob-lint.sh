#!/bin/bash
# bin/lanes-knob-lint.sh [--base <ref>] [root]
#
# A new knob on a lane or lib that already exists is its own file,
# catalog/lanes.d/<owner>.knobs.d/<ENV>.json, not an append to the inline
# `knobs` array of catalog/lanes.d/<id>.json (BH-4987). Two builds that append
# to one array both edit its last element and conflict; two files never do.
# bin/lanes-build.sh composes the fragments. A rules-pack component, so the
# builder gate, the PR lint job and every fix round run it before a push.
#
#   --base <ref>  judge the diff from the merge-base of <ref> and HEAD
#                 (default: origin/main).
#   root          the checkout to judge (default: the current directory).
#   rc 0 clean, or skipped: a fork that has no bin/lanes-knob-lint.sh predates
#        knob fragments, and its branch is not judged by a rule it never saw
#   rc 1 findings, one per stdout line:
#        `catalog/lanes.d/<id>.json: adds knob <ENV> to an existing inline
#         knobs array; write it as catalog/lanes.d/<owner>.knobs.d/<ENV>.json (BH-4987)`
#   rc 2 bad args, not a git work tree, an unresolvable base, no jq, or a lane
#        file that does not parse at the fork or at HEAD
# Not findings: a new lane file, a new lib, an edit to an existing knob, a knob
# removed or moved to a fragment, a renamed lane file.
set -uo pipefail

BASE=origin/main; ROOT=.
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:-}"; [ -n "$BASE" ] || { echo "lanes-knob-lint: --base needs a ref" >&2; exit 2; }; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    -*) echo "lanes-knob-lint: unknown argument $1" >&2; exit 2 ;;
    *) ROOT="$1"; shift ;;
  esac
done
command -v jq >/dev/null 2>&1 || { echo "lanes-knob-lint: jq is required" >&2; exit 2; }
g() { git -C "$ROOT" "$@"; }
g rev-parse --git-dir >/dev/null 2>&1 || { echo "lanes-knob-lint: $ROOT is not a git work tree" >&2; exit 2; }
g rev-parse -q --verify "$BASE^{commit}" >/dev/null 2>&1 || { echo "lanes-knob-lint: cannot resolve $BASE" >&2; exit 2; }
FORK=$(g merge-base "$BASE" HEAD 2>/dev/null) || { echo "lanes-knob-lint: no merge-base of $BASE and HEAD" >&2; exit 2; }
if ! g cat-file -e "$FORK:bin/lanes-knob-lint.sh" 2>/dev/null; then
  echo "lanes-knob-lint: skipped: $BASE predates knob fragments" >&2
  exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/lanes-knob-lint.XXXXXX") || { echo "lanes-knob-lint: cannot make a temp dir" >&2; exit 2; }
trap 'rm -rf -- "$TMP"' EXIT
PATHS=$(g diff --no-renames --diff-filter=M --name-only "$FORK" HEAD -- 'catalog/lanes.d/*.json') \
  || { echo "lanes-knob-lint: cannot diff $FORK..HEAD" >&2; exit 2; }
OUT=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  rel=${p#catalog/lanes.d/}
  case "$rel" in */*|_registry.json) continue ;; esac
  bn=${rel%.json}
  g show "$FORK:$p" > "$TMP/old.json" 2>/dev/null && g show "HEAD:$p" > "$TMP/new.json" 2>/dev/null \
    || { echo "lanes-knob-lint: cannot read $p at $FORK or HEAD" >&2; exit 2; }
  case "$bn" in
    _lib|_lib.*)
      # Per lib that existed at the fork: envs at HEAD minus envs at the fork.
      F=$(jq -rn --slurpfile o "$TMP/old.json" --slurpfile n "$TMP/new.json" '
          ($n[0].libs // []) as $nl
          | ($o[0].libs // [])[] | .id as $id | ((.knobs // []) | map(.env)) as $oe
          | ($nl[] | select(.id == $id) | (.knobs // []) | map(.env)) - $oe
          | .[] | "_lib.\($id)\t\(.)"' 2>/dev/null) ;;
    *)
      F=$(jq -rn --arg bn "$bn" --slurpfile o "$TMP/old.json" --slurpfile n "$TMP/new.json" '
          ($o[0].id // $bn) as $id
          | ((($n[0].knobs // []) | map(.env)) - (($o[0].knobs // []) | map(.env)))
          | .[] | "\($id)\t\(.)"' 2>/dev/null) ;;
  esac || { echo "lanes-knob-lint: $p does not parse at $FORK or at HEAD" >&2; exit 2; }
  while IFS=$'\t' read -r owner env; do
    [ -n "$env" ] || continue
    OUT+="$p: adds knob $env to an existing inline knobs array; write it as catalog/lanes.d/$owner.knobs.d/$env.json (BH-4987)"$'\n'
  done <<<"$F"
done <<<"$PATHS"
[ -z "$OUT" ] && exit 0
printf '%s' "$OUT"
echo "lanes-knob-lint: $(printf '%s' "$OUT" | grep -c .) inline knob append(s); a new knob is its own file" >&2
exit 1
