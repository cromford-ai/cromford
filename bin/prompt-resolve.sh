#!/bin/bash
# bin/prompt-resolve.sh — print the prompt a build uses for <project> <kind>
# (BH-7969, BH-7940.0; docs/PROMPTS.md). Owner: BH-7940.0.
#
# Usage: bin/prompt-resolve.sh <project> <kind> [--source]
#   kind: rules, watcher, plan, execute, review, fix-round or qa.
#
# Resolution: the project head, else the fleet head (one GET /api/prompts on
# the jobs worker, then one GET /api/prompts/<scope>/<kind>/<version>), else
# the repo file: rules/CLAUDE.md for rules, prompts/<project>.md for watcher,
# prompts/stages/<kind>.md for the stage kinds. The body is printed byte for
# byte, with no newline added.
#
# The reserved project `_fleet` (BH-7971) resolves with no project: the fleet
# head, else the repo file. The hub render reads the fleet rules through it.
# `_fleet watcher` is usage (rc 2): a watcher prompt is always per project.
#
# --source prints one line and no body: `<kind> <source> v<version> <version_id>`,
# and `<kind> repo v0 -` for the repo file.
#
# Exit codes:
#   0  printed the body (or the --source line).
#   2  usage: wrong argument count, unknown flag, bad project or kind.
#   3  the worker is configured but did not answer: curl failed, HTTP not 200,
#      an unreadable answer, no row for the kind, or JOBS_URL set with no
#      HARNESS_SECRET. Nothing is printed; never the repo default.
#   4  the repo file is the answer and it does not exist (the stage kinds until
#      BH-7940.2 adds prompts/stages/). Nothing is printed.
#
# Env:
#   JOBS_URL, HARNESS_SECRET   the jobs worker and its bearer. When JOBS_URL is
#       unset, both are read from global.env (bin/lib/env-path.sh). JOBS_URL
#       empty after that means not configured: the repo file is printed.
#   PROMPT_RESOLVE_ROOT        the repo the default files are read from
#       (default: this script's repo).
#   PROMPT_RESOLVE_TIMEOUT_S   curl --max-time per call (default 10).
#   PROMPT_RESOLVE_CACHE_DIR   when set, a 200 list answer is kept at
#       <dir>/list-<project>.json and later calls in the run read it.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KINDS=" rules watcher plan execute review fix-round qa "
PROJECT_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$'

usage() { echo "usage: prompt-resolve.sh <project> <kind> [--source]${1:+ ($1)}" >&2; exit 2; }
fail3() { echo "prompt-resolve: $*" >&2; exit 3; }

SOURCE_ONLY=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --source) SOURCE_ONLY=1 ;;
    -*) usage "unknown flag $a" ;;
    *) ARGS+=("$a") ;;
  esac
done
[ "${#ARGS[@]}" -eq 2 ] || usage
PROJECT=${ARGS[0]} KIND=${ARGS[1]}
case "$KINDS" in *" $KIND "*) ;; *) usage "unknown kind $KIND" ;; esac
if [ "$PROJECT" = _fleet ]; then
  [ "$KIND" != watcher ] || usage "_fleet has no watcher"
  LISTQ=""
else
  [[ "$PROJECT" =~ $PROJECT_RE ]] || usage "bad project"
  LISTQ=$PROJECT
fi

ROOT=${PROMPT_RESOLVE_ROOT:-$(dirname "$SELF_DIR")}
case "$KIND" in
  rules) DEFAULT="$ROOT/rules/CLAUDE.md" ;;
  watcher) DEFAULT="$ROOT/prompts/$PROJECT.md" ;;
  *) DEFAULT="$ROOT/prompts/stages/$KIND.md" ;;
esac

# repo_default — print the repo file (rc 0), or rc 4 when it is missing.
repo_default() {
  if [ ! -f "$DEFAULT" ]; then
    echo "prompt-resolve: no repo default $DEFAULT" >&2
    exit 4
  fi
  if [ "$SOURCE_ONLY" = 1 ]; then printf '%s repo v0 -\n' "$KIND"; else cat "$DEFAULT"; fi
  exit 0
}

URL=${JOBS_URL-}
TOK=${HARNESS_SECRET-}
if [ -z "${JOBS_URL+set}" ]; then
  . "$SELF_DIR/lib/env-path.sh" || exit 1
  GF="$(harness_env_dir "${HARNESS:-/root/harness}")/global.env"
  if [ -r "$GF" ]; then
    URL=$(sed -n 's/^JOBS_URL=//p' "$GF" | head -1 | tr -d "\"' ")
    [ -n "$TOK" ] || TOK=$(sed -n 's/^HARNESS_SECRET=//p' "$GF" | head -1 | tr -d "\"' ")
  fi
fi
URL=${URL%/}
[ -n "$URL" ] || repo_default
[ -n "$TOK" ] || fail3 "no HARNESS_SECRET for $URL"

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
umask 077
printf 'authorization: Bearer %s\n' "$TOK" > "$TMP/hdr"

# get <url> <out file> — rc 0 on HTTP 200, else rc 3 with one stderr line.
get() {
  local code rc
  code=$(curl -s --max-time "${PROMPT_RESOLVE_TIMEOUT_S:-10}" -H @"$TMP/hdr" -o "$2" -w '%{http_code}' "$1")
  rc=$?
  [ "$rc" = 0 ] || fail3 "curl rc $rc for $1"
  [ "$code" = 200 ] || fail3 "HTTP $code for $1"
}

LIST="$TMP/list.json"
CACHED=""
[ -n "${PROMPT_RESOLVE_CACHE_DIR:-}" ] && CACHED="$PROMPT_RESOLVE_CACHE_DIR/list-$PROJECT.json"
if [ -n "$CACHED" ] && [ -f "$CACHED" ]; then
  LIST=$CACHED
else
  get "$URL/api/prompts?project=$LISTQ" "$LIST"
  if [ -n "$CACHED" ]; then cp "$LIST" "$CACHED.tmp.$$" && mv "$CACHED.tmp.$$" "$CACHED"; fi
fi

ROW=$(jq -r --arg k "$KIND" '[.prompts[] | select(.kind == $k)] | if length == 1 then .[0] | "\(.source) \(.version) \(.version_id)" else empty end' "$LIST" 2>/dev/null) \
  || fail3 "unreadable list answer for $PROJECT"
[ -n "$ROW" ] || fail3 "the list for $PROJECT has no $KIND row"
read -r SRC VER VID <<<"$ROW"
case "$SRC" in
  repo) repo_default ;;
  fleet) Q="" ;;
  project) [ "$PROJECT" != _fleet ] || fail3 "a project head in the _fleet list for $KIND"
           Q="?project=$PROJECT" ;;
  *) fail3 "unknown source '$SRC' for $KIND" ;;
esac
[[ "$VER" =~ ^[1-9][0-9]*$ && "$VID" =~ ^[1-9][0-9]*$ ]] || fail3 "bad head v$VER id $VID for $KIND"

get "$URL/api/prompts/$SRC/$KIND/$VER$Q" "$TMP/version.json"
jq -j 'if (.prompt.body | type) == "string" then .prompt.body else error("no body") end' "$TMP/version.json" > "$TMP/body" 2>/dev/null \
  || fail3 "unreadable version answer for $SRC/$KIND/$VER"
if [ "$SOURCE_ONLY" = 1 ]; then printf '%s %s v%s %s\n' "$KIND" "$SRC" "$VER" "$VID"; else cat "$TMP/body"; fi
