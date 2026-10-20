#!/bin/bash
# bin/fetch-artifact.sh <project> <key> <which> <command_id>
#   Resolve one WHITELISTED build artifact for a ticket, tail it, and print the
#   `artifact_tail` beat JSON on stdout. Called by poll-commands.sh for the
#   console's fetch_artifact command, so Mission Control can read the plan, the
#   review or the pipeline log of a build without anyone SSH-ing into a box.
#
# bin/fetch-artifact.sh --file <which>              -> artifact filename
# bin/fetch-artifact.sh --path <project> <key> <which> -> full path
#   rc 0 resolved · rc 1 refused (bad which/key/project) · rc 2 valid input but
#   no build dir or no such artifact yet. The split matters: refused is a
#   security answer, 2 is "nothing there yet", and the console shows them
#   differently.
#   A build that bin/builds-retention.sh moved to builds-archive/ still
#   resolves: the beat says archived:true and build_dir is the archive path.
#
# SECURITY: `which` is a closed set of literals. The KEY is a second untrusted
# path component (it names the build dir) and reaches both a glob and an ssh
# command line, so it is REJECTED outright unless it is [A-Za-z0-9_-]+ rather
# than stripped — a key silently rewritten into a different key would quietly
# answer about the wrong build. The project is matched against fleet.conf for
# the same reason.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
CAP=48000   # bytes of tail shipped in one beat
# The builds/ archive index (BH-7437). Missing, only builds/ is searched.
# shellcheck source=bin/lib/build-archive.sh
. "$(dirname "$0")/lib/build-archive.sh" 2>/dev/null || true

artifact_file() { # artifact_file <which> -> basename, rc 1 if refused
  case "$1" in
    plan)     echo plan.md ;;
    review)   echo review.md ;;
    security) echo security-review.md ;;
    qa)       echo qa.md ;;
    evidence) echo evidence.md ;;   # SDLC item 2: the deterministic evidence block
    pipeline) echo pipeline.log ;;
    cost)     echo cost.csv ;;
    context)  echo context.json ;;
    *) return 1 ;;
  esac
}

build_dir() { # build_dir <project> <key> [file] -> dir, rc 1 refused, rc 2 none
  local p="$1" k="$2" f="${3:-}" d first=""
  case "$k" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  # EXACT membership: fleet-conf.sh's row lookup is a REGEX, so `project-1.os`
  # would match the project-1 row there and box-for.sh would route to that box.
  case "$p" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  "$(dirname "$0")/fleet-conf.sh" --projects 2>/dev/null | grep -qxF "$p" || return 1
  # Three naming conventions in builds/: run-build.sh writes <project>-<key>-<ts>,
  # the fly-pool reap writes pool-<...> and fly-results-ingest writes fly-<...>.
  # A retried ticket leaves several behind, and a pool build leaves two at once:
  # the local QUEUED_FLY stub (written last, so newest) and the staged
  # -remote<ts> dir that holds the artifacts (BH-3945). So the NEWEST dir that
  # CONTAINS <file> wins; when none does, the newest dir is returned, so the
  # answer stays missing=true with a real build_dir. The trailing dash after the
  # key is what keeps TK-8 out of TK-88's directory.
  while IFS= read -r d; do
    [ -d "$d" ] || continue
    [ -n "$first" ] || first="$d"
    [ -n "$f" ] && [ -f "$d/$f" ] && { echo "$d"; return 0; }
  done < <(ls -dt "$HARNESS/builds/$p-$k-"* "$HARNESS/builds/pool-$p-$k-"* \
                  "$HARNESS/builds/fly-$p-$k-"* 2>/dev/null)
  # No live dir holds <file>: an ARCHIVED dir of the key may (BH-7437,
  # bin/builds-retention.sh). Newest stamp first, the same rule. A live dir
  # still answers a missing file before the archive does.
  if command -v ba_dirs >/dev/null 2>&1; then
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      [ -n "$first" ] || first="$d"
      [ -n "$f" ] && [ -f "$d/$f" ] && { echo "$d"; return 0; }
    done < <(ba_dirs "$HARNESS" "$p" "$k" 2>/dev/null)
  fi
  [ -n "$first" ] || return 2
  echo "$first"
}

case "${1:-}" in
  --file) artifact_file "${2:-}"; exit $? ;;
  --path)
    F=$(artifact_file "${4:-}") || exit 1
    D=$(build_dir "${2:-}" "${3:-}" "$F") || exit $?
    [ -f "$D/$F" ] || exit 2
    echo "$D/$F"; exit 0 ;;
esac

PROJECT="${1:-}"; KEY="${2:-}"; WHICH="${3:-}"; CID="${4:-}"

# Terminal beat for a request that will never produce a tail — see fetch-log.sh.
if [ "$PROJECT" = "--error" ]; then
  shift; jq -nc --arg p "${1:-}" --arg k "${2:-}" --arg w "${3:-}" --arg cid "${4:-}" \
    --arg e "${5:-error}" --arg ts "$(date -u '+%Y-%m-%d %H:%M:%SZ')" \
    '{kind:"artifact_tail",rkey:("artifact:"+$cid),command_id:$cid,project:$p,key:$k,
      which:$w,content:"",truncated:false,missing:true,bytes:0,build_dir:"",error:$e,ts:$ts}'
  exit 0
fi

JLOG="$HARNESS/logs/console-commands.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
# Sanitised, not quoted: a newline from the console would forge journal lines.
jsafe() { printf %s "${1:-}" | tr -dc 'A-Za-z0-9_.:/-' | head -c 64; }
journal() { mkdir -p "$HARNESS/logs"
  echo "$(STAMP) fetch_artifact id=$(jsafe "$CID") project=$(jsafe "$PROJECT") key=$(jsafe "$KEY") which=$(jsafe "$WHICH") -> $1" >> "$JLOG"; }

[ -n "$CID" ] || { journal "refused: no command id"; exit 1; }
FILE=$(artifact_file "$WHICH") || { journal "REFUSED: '$WHICH' is not a whitelisted artifact"; exit 1; }
DIR=$(build_dir "$PROJECT" "$KEY" "$FILE"); RC=$?
[ "$RC" -eq 1 ] && { journal "REFUSED: bad project/key"; exit 1; }

# A build dir or artifact that does not exist is answered, not swallowed: an
# unanswered request leaves the console spinning forever, which reads as a dead
# box rather than "that build never wrote a qa.md".
F=""; [ "$RC" -eq 0 ] && [ -f "$DIR/$FILE" ] && F="$DIR/$FILE"
SIZE=0; MISSING=true
if [ -n "$F" ]; then MISSING=false; SIZE=$(wc -c < "$F" | tr -dc '0-9'); fi
TRUNC=false; [ "${SIZE:-0}" -gt "$CAP" ] && TRUNC=true
ARCH=false; case "${DIR:-}" in "$HARNESS/builds-archive/"*) ARCH=true ;; esac

CONTENT='""'
[ -n "$F" ] && CONTENT=$(tail -c "$CAP" "$F" 2>/dev/null | jq -Rs . 2>/dev/null)
[ -n "$CONTENT" ] || CONTENT='""'

jq -nc --arg cid "$CID" --arg p "$PROJECT" --arg k "$KEY" --arg w "$WHICH" \
  --argjson c "$CONTENT" --argjson t "$TRUNC" --argjson m "$MISSING" \
  --argjson b "${SIZE:-0}" --arg d "${DIR:-}" --argjson a "$ARCH" --arg ts "$(STAMP)" \
  '{kind:"artifact_tail",rkey:("artifact:"+$cid),command_id:$cid,project:$p,key:$k,
    which:$w,content:$c,truncated:$t,missing:$m,bytes:$b,build_dir:$d,archived:$a,ts:$ts}'
AJ=""; [ "$ARCH" = true ] && AJ="archived "
journal "ok ${SIZE:-0}b truncated=$TRUNC missing=$MISSING ${AJ}dir=${DIR:-none}"
exit 0
