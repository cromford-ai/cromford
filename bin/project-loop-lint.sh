#!/bin/bash
# bin/project-loop-lint.sh [--base <ref>] [root]
#
# A new hub lane does not loop over projects by hand (BH-5945). One hub tick
# that walks every project in turn, often under one global lock, makes each
# project wait on the others. The per-project runner (bin/lib/project-lanes.sh
# pl_dispatch / pl_lane_dispatch, bin/project-lane-run.sh) starts one run per
# project with its own lock and offset instead.
#
# Judged: a catalog/lanes.d/<id>.json the diff ADDS whose .scope is "hub" or
# whose .boxes holds "hub". Existing lanes are never judged. Its .script, read
# at HEAD (comment lines skipped), is a finding when it shows a project loop:
#   S1  `fleet-conf.sh ... --projects` (the project list read)
#   S2  fleet.conf read in a loop (`while ... read`, a `done <` redirect, awk)
#   S3  a global lock (a flock or `exec N>...locks/<name>.lock` with no `$` in
#       the name) plus a `for`/`while read` over $PROJECTS or $projects
# and it does not call pl_dispatch, pl_lane_dispatch or project-lane-run.sh.
# A lane that really needs one fleet-wide pass carries the line
# `# project-loop-ok: <reason>`; a marker with no reason is itself a finding.
# Only the lane's own script is read, not the libs it sources.
# A rules-pack component (catalog/rules-pack.tsv row project-loop).
#
#   --base <ref>  judge the diff from the merge-base of <ref> and HEAD to HEAD
#                 (default: origin/main). The work tree is not read.
#   root          the checkout to scan (default: the current directory).
#   rc 0 clean
#   rc 1 findings, one per stdout line
#   rc 2 bad args, not a git work tree, or unresolvable base or merge-base
set -uo pipefail

BASE=origin/main; ROOT=.
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:-}"; [ -n "$BASE" ] || { echo "project-loop-lint: --base needs a ref" >&2; exit 2; }; shift 2 ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    -*) echo "project-loop-lint: unknown argument $1" >&2; exit 2 ;;
    *) ROOT="$1"; shift ;;
  esac
done
command -v jq >/dev/null 2>&1 || { echo "project-loop-lint: jq missing" >&2; exit 2; }
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "project-loop-lint: $ROOT is not a git work tree" >&2; exit 2; }
git -C "$ROOT" rev-parse -q --verify "$BASE^{commit}" >/dev/null 2>&1 || { echo "project-loop-lint: cannot resolve $BASE" >&2; exit 2; }
FORK=$(git -C "$ROOT" merge-base "$BASE" HEAD 2>/dev/null) && [ -n "$FORK" ] \
  || { echo "project-loop-lint: no merge-base of $BASE and HEAD" >&2; exit 2; }
ADDED=$(git -C "$ROOT" diff --name-only --diff-filter=A "$FORK" HEAD -- 'catalog/lanes.d/' 2>/dev/null) \
  || { echo "project-loop-lint: cannot diff $FORK HEAD" >&2; exit 2; }

# code_lines — stdin script -> "<n>\t<line>" for each line that is not a comment,
# with a trailing ` # ...` comment cut off.
code_lines() {
  awk '{ l = $0; if (l ~ /^[[:space:]]*#/) next; sub(/[[:space:]]#.*$/, "", l); printf "%d\t%s\n", NR, l }'
}
# first <ERE> <code lines> -> the line number of the first match. The ERE goes
# in through ENVIRON, not -v: awk runs escape processing on a -v value, so
# gawk turns `\$` into `$` (an anchor) and `\.` into `.`, and S3 never matched.
first() { PL_RE="$1" awk -F'\t' '$2 ~ ENVIRON["PL_RE"] { print $1; exit }' <<<"$2"; }

OUT=""; N=0
while IFS= read -r f; do
  case "$f" in catalog/lanes.d/*/*|*.knobs.d/*) continue ;; catalog/lanes.d/*.json) ;; *) continue ;; esac
  j=$(git -C "$ROOT" show "HEAD:$f" 2>/dev/null) || continue
  hub=$(jq -r 'if (.scope == "hub") or ((.boxes // []) | index("hub")) then 1 else 0 end' <<<"$j" 2>/dev/null) || continue
  [ "$hub" = 1 ] || continue
  id=$(jq -r '.id // empty' <<<"$j" 2>/dev/null); script=$(jq -r '.script // empty' <<<"$j" 2>/dev/null)
  [ -n "$script" ] || continue
  src=$(git -C "$ROOT" show "HEAD:$script" 2>/dev/null) || continue
  # The exemption marker: a reason passes, an empty one is a finding.
  mk=$(grep -E '^[[:space:]]*# project-loop-ok:' <<<"$src" | head -1)
  if [ -n "$mk" ]; then
    if [ -n "$(sed -E 's/^[[:space:]]*# project-loop-ok:[[:space:]]*//' <<<"$mk")" ]; then continue; fi
    OUT+="$script: project-loop-ok marker with no reason (write '# project-loop-ok: <why this lane needs one fleet-wide pass>')"$'\n'; N=$((N + 1))
    continue
  fi
  code=$(code_lines <<<"$src")
  # The runner is the sanctioned loop. A definition `pl_dispatch()` is not a call.
  if awk -F'\t' '$2 ~ /(^|[^[:alnum:]_])(pl_dispatch|pl_lane_dispatch)([^[:alnum:]_(]|$)/ || $2 ~ /project-lane-run\.sh/ { f = 1 } END { exit !f }' <<<"$code"; then
    continue
  fi
  sig=""; at=""
  if at=$(first 'fleet-conf\.sh[^|;&]*--projects' "$code") && [ -n "$at" ]; then sig=S1
  elif at=$(first 'fleet\.conf' "$code") && [ -n "$at" ] \
       && at=$(awk -F'\t' '$2 ~ /fleet\.conf/ && ($2 ~ /while[[:space:]].*read/ || $2 ~ /^[[:space:]]*done[[:space:]]*</ || $2 ~ /(^|[^[:alnum:]_])awk([^[:alnum:]_]|$)/) { print $1; exit }' <<<"$code") \
       && [ -n "$at" ]; then sig=S2
  fi
  # The first lock whose name has no `$` (a per-project lock is not global).
  lk=""; lat=""
  while IFS=$'\t' read -r n l; do
    for name in $(grep -oE 'locks/[^"[:space:]]*\.lock' <<<"$l"); do
      case "$name" in *'$'*) continue ;; esac
      lk=$name; lat=$n; break 2
    done
  done < <(awk -F'\t' '$2 ~ /flock/ || $2 ~ /exec[[:space:]]+[0-9]+[<>]/' <<<"$code")
  if [ -z "$sig" ] && [ -n "$lk" ]; then
    at=$(first '(^|[[:space:];])(for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in|while[[:space:]].*read).*\$\{?(PROJECTS|projects)' "$code")
    [ -n "$at" ] && sig=S3
  fi
  [ -n "$sig" ] || continue
  line="$script: new hub lane ${id:-?} loops over projects ($sig line $at)"
  [ -n "$lk" ] && line+=" under the global lock $lk (line $lat)"
  line+=" and does not dispatch through bin/lib/project-lanes.sh pl_dispatch. Move the loop onto the runner, or add '# project-loop-ok: <reason>'."
  OUT+="$line"$'\n'; N=$((N + 1))
done <<<"$ADDED"

[ -n "$OUT" ] || exit 0
printf '%s' "$OUT"
echo "project-loop-lint: $N new hub lane(s) loop over projects" >&2
exit 1
