#!/bin/bash
# bin/lane-scoped-knob-lint.sh [--env-file <path>]... [root]
#
# The lane-scoped knob lint (BH-7436). A lane-only knob must reach the
# environment only through its own lane's registry entry (lane_env_apply
# <lane>). If it is set in env/global.env, a cron line, another lane's or a
# lib's knob entry, or another bin/ script, every lane that runs with it set
# changes behavior.
#
# WHY POOL_GH_READ_TIMEOUT_S: bin/lib/hold.sh hold__gh cuts a hold read at this
# many seconds when it is a positive number. Some hold_check callers outside the
# pool proceed on an unreadable hold, so a global value can let a cut read skip
# a hold in those lanes. Set it as the settings row lane.fly-pool.pool_gh_read_timeout_s.
#
#   --env-file <path>  also check a box env file (for example
#                      $HARNESS/env/global.env). Repeatable. Red on a line that
#                      sets the knob: `NAME=` or `export NAME=`.
#   root               the checkout to scan (default: the current directory).
#   rc 0 clean, no output
#   rc 1 findings, one per stdout line:
#        `<path>:<line>: names <knob>, a <lane> lane-only knob; ...`
#   rc 2 bad args, root not a git work tree, or an unreadable --env-file
#
# SCAN SET: the tracked files of root (git ls-files). Untracked files are not read.
# ALLOWED (never red): the lane's own script and registry entry
#   (bin/<lane>.sh, catalog/lanes.d/<lane>.json, catalog/lanes.d/<lane>.knobs.d/*),
#   this lint, and the non-runtime trees tests/**, docs/**, .harness/specs/**, *.md.
# READER: bin/lib/hold.sh may read the knob. It is red only on a line that
#   assigns or exports it.
# CODE: any other bin/** or cron/** file is red on a line that names the knob
#   and whose first non-blank character is not `#`.
# ANY OTHER TRACKED PATH (env-templates/**, other catalog entries, worker/**):
#   red on every line that names the knob, comments included. A commented
#   template line is an invitation to set the knob globally.
# MATCH: the knob name as a whole word, so NAMEX and XNAME do not match.
set -uo pipefail

usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

# Lane-only knobs: "<knob> <lane>" per line. A list of names, not a limit.
KNOBS='POOL_GH_READ_TIMEOUT_S fly-pool'

ROOT="" ENV_FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --env-file)
      [ $# -ge 2 ] || { echo "lane-scoped-knob-lint: --env-file needs a path" >&2; exit 2; }
      ENV_FILES+=("$2"); shift 2 ;;
    -*) echo "lane-scoped-knob-lint: unknown option $1" >&2; exit 2 ;;
    *)
      [ -z "$ROOT" ] || { echo "lane-scoped-knob-lint: one root only" >&2; exit 2; }
      ROOT="$1"; shift ;;
  esac
done
ROOT="${ROOT:-.}"

git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "lane-scoped-knob-lint: $ROOT is not a git work tree" >&2; exit 2; }
TOP=$(git -C "$ROOT" rev-parse --show-toplevel) || exit 2
for f in ${ENV_FILES[@]+"${ENV_FILES[@]}"}; do
  [ -f "$f" ] && [ -r "$f" ] || { echo "lane-scoped-knob-lint: cannot read --env-file $f" >&2; exit 2; }
done

FOUND=0
finding() { # finding <path> <line> <knob> <lane>
  printf '%s:%s: names %s, a %s lane-only knob; set it as lane.%s.%s (BH-7436)\n' \
    "$1" "$2" "$3" "$4" "$4" "$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]')"
  FOUND=1
}

while read -r knob lane; do
  [ -n "$knob" ] || continue
  word="(^|[^A-Za-z0-9_])${knob}([^A-Za-z0-9_]|\$)"
  setter="(^|[;&|[:space:]])(export[[:space:]]+|local[[:space:]]+|declare[^=]*[[:space:]])?${knob}="

  # Tracked files that name the knob at all; then judge each matching line.
  while IFS= read -r -d '' path; do
    case "$path" in
      "bin/$lane.sh"|bin/lane-scoped-knob-lint.sh|"catalog/lanes.d/$lane.json"|"catalog/lanes.d/$lane.knobs.d/"*) continue ;;
      tests/*|docs/*|.harness/specs/*|*.md) continue ;;
    esac
    while IFS=: read -r ln text; do
      case "$path" in
        bin/lib/hold.sh)
          grep -Eq "$setter" <<<"$text" || continue ;;
        bin/*|cron/*)
          case "${text#"${text%%[![:space:]]*}"}" in '#'*) continue ;; esac ;;
      esac
      finding "$path" "$ln" "$knob" "$lane"
    done < <(grep -nE "$word" "$TOP/$path" 2>/dev/null)
  done < <(git -C "$TOP" grep -lzE "$word" 2>/dev/null)

  for f in ${ENV_FILES[@]+"${ENV_FILES[@]}"}; do
    while IFS=: read -r ln _; do
      finding "$f" "$ln" "$knob" "$lane"
    done < <(grep -nE "^[[:space:]]*(export[[:space:]]+)?${knob}=" "$f")
  done
done <<<"$KNOBS"

exit "$FOUND"
