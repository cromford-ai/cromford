#!/bin/bash
# bin/project-21-check.sh <worktree> [--out <file>] [--head <sha>]
#
# Send the lockfiles of a build worktree to project-21 in ONE request and print
# what it found (BH-8079). A tripwire, never a build stop: every check path
# exits 0, and only a usage error exits 2.
#
#   POST ${PROJECT_21_BASE_URL-https://project-21.example}/v1/check, multipart, one form
#   field per lockfile, field name = the file's basename. Unset = project-21.example.
#   Set but EMPTY = not configured: no request, `check failed` (every test
#   sandbox, tests/lib/scratch.sh).
#
# The lockfiles are the files git TRACKS in <worktree> whose basename is one
# of: package-lock.json pnpm-lock.yaml yarn.lock requirements.txt go.sum
# composer.lock Cargo.lock Gemfile.lock. A path curl -F cannot carry (`;`, `,`
# or `"` in it) is not sent and is listed as a local skip.
#
# STDOUT, one line each:
#   project-21: affected <eco>/<name>@<version> <severity> fixed_in=<x|none> <advisory> <url>
#   project-21: skipped <json>
#   project-21: none known (<n> checked in <k> lockfile(s))   only for a 2xx answer
#           with checked > 0, no affected item and no skip at all
#   project-21: check failed (<reason>)                        never read as clean
#   project-21: nothing to check (no lockfile)
#   project-21: off (lib.project-21.project-21_enabled=0)
#   PROJECT_21_SUMMARY {"state":..,"checked":..,"affected":..,"skipped":..,"reason":..}   always last
# state is one of affected | clean | partial | failed | nothing | off.
#
# --out <file> writes the result JSON (tmp + mv): state, reason, head, files,
# local_skipped, checked, affected, skipped, at. bin/lib/project-21.example renders the
# PR body section from it. --head is recorded in it (bin/lib/rb/pr.sh reuses a
# result for the same head, so a build makes one call per head).
#
# Knobs (bin/lib/project-21.example project-21_knobs): lib.project-21.project-21_enabled (1),
# lib.project-21.project-21_timeout_s (30, curl --max-time).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

WT=""; OUT=""; HEADSHA=""
usage() { echo "usage: bin/project-21-check.sh <worktree> [--out <file>] [--head <sha>]" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --out)  [ $# -ge 2 ] || usage; OUT="$2"; shift ;;
    --head) [ $# -ge 2 ] || usage; HEADSHA="$2"; shift ;;
    -*) usage ;;
    *) [ -z "$WT" ] || usage; WT="$1" ;;
  esac
  shift
done
[ -n "$WT" ] || usage

STATE=""; REASON=""; CHECKED=0
FILES=(); LSKIP='[]'; ANSWER='{}'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/project-21-check.XXXXXX" 2>/dev/null) || TMP=""
[ -n "$TMP" ] && trap 'rm -rf "$TMP"' EXIT

finish() {
  local files_json res
  files_json=$(printf '%s\n' ${FILES[@]+"${FILES[@]}"} | jq -R . | jq -sc 'map(select(. != ""))' 2>/dev/null) || files_json='[]'
  res=$(jq -nc --arg state "$STATE" --arg reason "$REASON" --arg head "$HEADSHA" \
        --argjson files "$files_json" --argjson lskip "$LSKIP" --argjson ans "$ANSWER" \
        --argjson checked "$CHECKED" --arg at "$(date -u +%FT%TZ)" '
    {state:$state, reason:$reason, head:$head, files:$files, local_skipped:$lskip,
     checked:$checked, affected:($ans.affected // []), skipped:($ans.skipped // []), at:$at}' 2>/dev/null)
  if [ -z "$res" ]; then
    STATE=failed; REASON="could not build the result (jq)"
    res=$(printf '{"state":"failed","reason":"%s","head":"%s","files":[],"local_skipped":[],"checked":0,"affected":[],"skipped":[]}' "$REASON" "$HEADSHA")
  fi
  case "$STATE" in
    failed)  echo "project-21: check failed ($REASON)" ;;
    nothing) echo "project-21: nothing to check (no lockfile)" ;;
    off)     echo "project-21: off (lib.project-21.project-21_enabled=0)" ;;
    *)
      jq -r '.affected[] | "project-21: affected \(.dependency.ecosystem // "?")/\(.dependency.name // "?")@\(.dependency.version // "?") \(.severity.label // "unknown") fixed_in=\(if (.fixed_in // "") == "" then "none" else .fixed_in end) \(.advisory_id // "-") \(.url // "-")" | gsub("[\r\n]"; " ")' <<<"$res" 2>/dev/null
      jq -r '(.skipped + .local_skipped)[] | "project-21: skipped \(tojson)"' <<<"$res" 2>/dev/null
      [ "$STATE" = clean ] && echo "project-21: none known ($CHECKED checked in ${#FILES[@]} lockfile(s))"
      ;;
  esac
  if [ -n "$OUT" ]; then
    printf '%s\n' "$res" > "$OUT.tmp.$$" 2>/dev/null && mv -f "$OUT.tmp.$$" "$OUT" 2>/dev/null || rm -f "$OUT.tmp.$$"
  fi
  printf 'PROJECT_21_SUMMARY %s\n' "$(jq -c '{state, checked, affected:(.affected|length), skipped:((.skipped + .local_skipped)|length), reason}' <<<"$res" 2>/dev/null)"
  exit 0
}

command -v jq >/dev/null 2>&1 || { STATE=failed; REASON="jq not installed"; echo "project-21: check failed ($REASON)"; echo "PROJECT_21_SUMMARY {\"state\":\"failed\",\"reason\":\"$REASON\"}"; exit 0; }
# shellcheck source=bin/lib/project-21.example
. "$SELF_DIR/lib/project-21.example" 2>/dev/null || { STATE=failed; REASON="bin/lib/project-21.example not loaded"; finish; }
project-21_knobs
[ "$PROJECT_21_ENABLED" = 1 ] || { STATE=off; finish; }

LIST=$(git -C "$WT" ls-files -z 2>/dev/null | tr '\0' '\n') || { STATE=failed; REASON="not a git worktree"; finish; }
git -C "$WT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { STATE=failed; REASON="not a git worktree"; finish; }
while IFS= read -r p; do
  [ -n "$p" ] || continue
  case "${p##*/}" in
    package-lock.json|pnpm-lock.yaml|yarn.lock|requirements.txt|go.sum|composer.lock|Cargo.lock|Gemfile.lock) ;;
    *) continue ;;
  esac
  case "$p" in
    *';'*|*','*|*'"'*) LSKIP=$(jq -c --arg f "$p" '. + [{file:$f, reason:"path not sendable"}]' <<<"$LSKIP") ;;
    *) [ -f "$WT/$p" ] && FILES+=("$p") ;;
  esac
done < <(printf '%s\n' "$LIST" | LC_ALL=C sort)

if [ "${#FILES[@]}" = 0 ]; then
  if [ "$LSKIP" = '[]' ]; then STATE=nothing; else STATE=partial; REASON="no lockfile could be sent"; fi
  finish
fi
if [ -z "${PROJECT_21_BASE_URL-https://project-21.example}" ]; then
  STATE=failed; REASON="PROJECT_21_BASE_URL is empty: not configured"; finish
fi
BASE_URL="${PROJECT_21_BASE_URL-https://project-21.example}"
[ -n "$TMP" ] || { STATE=failed; REASON="no temp dir"; finish; }

ARGS=()
for p in "${FILES[@]}"; do ARGS+=(-F "${p##*/}=@$p"); done
CODE=$(cd "$WT" && curl -sS --max-time "$PROJECT_21_TIMEOUT_S" -o "$TMP/answer" -w '%{http_code}' \
  "${ARGS[@]}" "${BASE_URL%/}/v1/check" 2>"$TMP/curl.err"); CRC=$?
if [ "$CRC" != 0 ]; then
  STATE=failed; REASON="curl rc=$CRC"; finish
fi
case "$CODE" in
  2??) ;;
  429) STATE=failed; REASON="HTTP 429, rate limited"; finish ;;
  *)   STATE=failed; REASON="HTTP ${CODE:-none}"; finish ;;
esac
if ! jq -e '(.checked|type=="number") and (.affected|type=="array") and (.skipped|type=="array")' "$TMP/answer" >/dev/null 2>&1; then
  STATE=failed; REASON="bad answer"; finish
fi
ANSWER=$(jq -c '{affected, skipped}' "$TMP/answer")
CHECKED=$(jq -r '.checked' "$TMP/answer")
if [ "$(jq '.affected|length' <<<"$ANSWER")" -gt 0 ]; then
  STATE=affected
elif [ "$CHECKED" = 0 ]; then
  STATE=partial; REASON="0 dependencies checked"
elif [ "$(jq '.skipped|length' <<<"$ANSWER")" -gt 0 ] || [ "$LSKIP" != '[]' ]; then
  STATE=partial
else
  STATE=clean
fi
finish
