#!/bin/bash
# bin/lane-sheds-lint.sh [root]
#
# Every project lane that starts agent or build work says in its lane file,
# catalog/lanes.d/<id>.json, whether it sheds while the hub is over (BH-7659).
# The sampler (bin/hub-load-sample.sh) builds the shed list from the
# `"sheds": true` lanes, so a new spawning lane with no field never sheds.
#
# A lane file is an object with .id and .script (_lib.*.json files have no .id
# and are skipped). Comment lines (first non-blank character #) are ignored.
#   DISPATCHED  its script names pl_dispatch, pl_lane_dispatch, llp_dispatch,
#               llm-lane-project.sh or project-lane-run.sh. Only these lanes
#               run through bin/project-lane-run.sh, the one reader of the list.
#   SPAWNING    DISPATCHED, and one of: .stats.cost_stage is not null; the
#               script names run-build.sh, agent-call.sh or claude-cost.sh; a
#               bin/<x>.sh on a pl_dispatch or pl_lane_dispatch line names a
#               script that does.
# Findings:
#   a SPAWNING lane with no `sheds` key;
#   a `sheds` that is not a boolean;
#   `sheds: false` with an empty or absent `sheds_why`;
#   `sheds: true` on a lane that is not DISPATCHED.
# The key `shed` (lane-gate, BH-7616) is a different field and is not read.
#
#   root  the checkout to judge (default: the current directory)
#   rc 0 clean, no output
#   rc 1 findings, one per stdout line:
#        `catalog/lanes.d/<file>: lane <id> <what is wrong>`
#   rc 2 bad args, no jq, no <root>/catalog/lanes.d, or a lane file that does
#        not parse
# Writes nothing.
set -uo pipefail

ROOT=.
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
    -*) echo "lane-sheds-lint: unknown argument $1" >&2; exit 2 ;;
    *) ROOT="$1"; shift ;;
  esac
done
command -v jq >/dev/null 2>&1 || { echo "lane-sheds-lint: jq is required" >&2; exit 2; }
[ -d "$ROOT/catalog/lanes.d" ] || { echo "lane-sheds-lint: no $ROOT/catalog/lanes.d" >&2; exit 2; }

DISPATCH_RE='pl_dispatch|pl_lane_dispatch|llp_dispatch|llm-lane-project\.sh|project-lane-run\.sh'
SPAWN_RE='run-build\.sh|agent-call\.sh|claude-cost\.sh'

code() { # code <file> — the file without its comment lines; empty when absent
  [ -f "$1" ] && grep -v '^[[:space:]]*#' "$1" 2>/dev/null
}

FOUND=0
find_line() { printf '%s\n' "$1"; FOUND=1; }

for f in "$ROOT"/catalog/lanes.d/*.json; do
  [ -f "$f" ] || continue
  rel="catalog/lanes.d/${f##*/}"
  # One jq per file; \x1f keeps an empty field in place (a tab would not).
  row=$(jq -r 'def str: if type == "string" then gsub("[\u001f\n]"; " ") else "" end;
               [(.id | str), (.script | str), (.stats.cost_stage != null),
                has("sheds"), (.sheds | type), (.sheds == true),
                ((.sheds_why // "") | tostring | test("[^[:space:]]"))] | map(tostring) | join("\u001f")' "$f" 2>/dev/null) \
    || { echo "lane-sheds-lint: $rel does not parse" >&2; exit 2; }
  IFS=$'\x1f' read -r id script cost has kind istrue why <<<"$row"
  [ -n "$id" ] && [ -n "$script" ] || continue

  body=$(code "$ROOT/$script")
  dispatched=0; spawn=""
  grep -qE "$DISPATCH_RE" <<<"$body" && dispatched=1
  if [ "$dispatched" = 1 ]; then
    [ "$cost" = true ] && spawn="stats.cost_stage"
    if [ -z "$spawn" ]; then
      spawn=$(grep -oE "$SPAWN_RE" <<<"$body" | head -1)
    fi
    if [ -z "$spawn" ]; then
      while IFS= read -r tok; do
        [ -n "$tok" ] || continue
        hit=$(code "$ROOT/$tok" | grep -oE "$SPAWN_RE" | head -1)
        [ -n "$hit" ] && { spawn="$tok -> $hit"; break; }
      done < <(grep -E 'pl_dispatch|pl_lane_dispatch' <<<"$body" | grep -oE 'bin/[A-Za-z0-9._/-]+\.sh' | sort -u)
    fi
  fi

  if [ "$has" = true ] && [ "$kind" != boolean ]; then
    find_line "$rel: lane $id has sheds of type $kind; it must be a boolean"
    continue
  fi
  if [ "$has" != true ]; then
    [ -n "$spawn" ] && find_line "$rel: lane $id is dispatched and starts agent or build work ($spawn) but has no \"sheds\" field; add \"sheds\": true, or \"sheds\": false with a \"sheds_why\""
    continue
  fi
  if [ "$istrue" = true ]; then
    [ "$dispatched" = 1 ] || find_line "$rel: lane $id has \"sheds\": true but bin/project-lane-run.sh never runs it (no dispatch in $script)"
  else
    [ "$why" = true ] \
      || find_line "$rel: lane $id has \"sheds\": false with no sheds_why; say why it keeps running while the hub is over"
  fi
done
exit "$FOUND"
