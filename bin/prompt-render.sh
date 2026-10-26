#!/bin/bash
# bin/prompt-render.sh — render the resolved prompts into state/prompts/ (BH-7971,
# BH-7940.3; docs/PROMPTS.md "## Hub render and build note"). Hub only.
# bin/fleet-propagate.sh runs it on every tick and pushes the tree to the boxes.
#
# For each project of fleet-conf.sh --projects and each kind, in the fixed order
# rules watcher plan execute review fix-round qa, it asks bin/prompt-resolve.sh
# for the `--source` line and then:
#   project, or fleet on a stage kind  -> state/prompts/<project>/<kind>.md
#                                         holds the head body
#   fleet on rules                     -> no <project>/rules.md (the fleet rules
#                                         go to _fleet/rules.md only)
#   repo (rc 0 or rc 4)                -> no <project>/<kind>.md
# Then <project>/sources.tsv gets one `--source` line per kind (a kind with
# rc 4 has no line). Then _fleet/rules.md holds the fleet `rules` head, or is
# removed when there is none. A project dir not in fleet.conf is removed (only
# when the project list is not empty).
#
# Every file is written as <file>.tmp, compared, and moved only when it
# differs, so an unchanged file keeps its mtime. sources.tsv goes after the
# kind files. A stray *.tmp from a killed run is removed first.
#
# Worker down (prompt-resolve rc 3): the run stops and keeps every file as it
# is. The first down run of an outage writes ONE alert (bin/alert-line.sh, id
# prompt-render-worker-down) and the marker
# state/prompt-render.down-since; later down runs log only. The first run that
# answers removes the marker and resolves the alert.
#
# JOBS_URL empty (env, else global.env): not configured, nothing is touched.
# Always rc 0. One summary line per run in logs/prompt-render.log.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H="${HARNESS:-/root/harness}"
LOG="$H/logs/prompt-render.log"
OUT="$H/state/prompts"
DOWN="$H/state/prompt-render.down-since"
KINDS="rules watcher plan execute review fix-round qa"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
mkdir -p "$H/logs" 2>/dev/null
log() { echo "$(STAMP) prompt-render: $*" >> "$LOG"; }

# JOBS_URL and HARNESS_SECRET the way bin/prompt-resolve.sh reads them, then
# exported, so each resolve call reads no file of its own.
if [ -z "${JOBS_URL+set}" ]; then
  # shellcheck source=bin/lib/env-path.sh
  . "$SELF_DIR/lib/env-path.sh" || exit 0
  GF="$(harness_env_dir "$H")/global.env"
  JOBS_URL=""
  if [ -r "$GF" ]; then
    JOBS_URL=$(sed -n 's/^JOBS_URL=//p' "$GF" | head -1 | tr -d "\"' ")
    [ -n "${HARNESS_SECRET:-}" ] || HARNESS_SECRET=$(sed -n 's/^HARNESS_SECRET=//p' "$GF" | head -1 | tr -d "\"' ")
  fi
fi
if [ -z "$JOBS_URL" ]; then log "not configured (no JOBS_URL); state/prompts/ untouched"; exit 0; fi
export JOBS_URL HARNESS_SECRET="${HARNESS_SECRET:-}"
# A repo source reads the git checkout, the same tree the box rules come from.
export PROMPT_RESOLVE_ROOT="${HARNESS_CHECKOUT:-/root/harness-checkout}"
TMPD=$(mktemp -d) || exit 0
trap 'rm -rf "$TMPD"' EXIT
export PROMPT_RESOLVE_CACHE_DIR="$TMPD"   # one list call per project per run
[ -f "$H/fleet.conf" ] && export FLEET_CONF="${FLEET_CONF:-$H/fleet.conf}"

mkdir -p "$OUT" || exit 0
find "$OUT" -type f \( -name '*.md.tmp' -o -name '*.tsv.tmp' \) -delete 2>/dev/null

WRITTEN=0 REMOVED=0 UNCHANGED=0 DOWN_ERR="" NPROJ=0
# put <tmp> <dest> — move <tmp> over <dest> only when the bytes differ.
put() {
  if [ -f "$2" ] && cmp -s "$1" "$2"; then rm -f "$1"; UNCHANGED=$((UNCHANGED+1))
  else mv -f "$1" "$2" && WRITTEN=$((WRITTEN+1)); fi
}
drop() { [ -e "$1" ] || return 0; rm -f "$1" && REMOVED=$((REMOVED+1)); }
# resolve <project> <kind> [--source] > file — sets RRC; DOWN_ERR on rc 3.
resolve() {
  "$SELF_DIR/prompt-resolve.sh" "$@" 2>"$TMPD/err"
  RRC=$?
  [ "$RRC" = 3 ] && DOWN_ERR=$(head -1 "$TMPD/err")
  return 0
}

PROJECTS=$("$SELF_DIR/fleet-conf.sh" --projects 2>/dev/null)
render_project() { # render_project <project> — rc 3 when the worker did not answer
  local p=$1 k src d="$OUT/$1"
  : > "$TMPD/sources"
  for k in $KINDS; do
    resolve "$p" "$k" --source > "$TMPD/src"
    case "$RRC" in
      0) ;;
      3) return 3 ;;
      4) drop "$d/$k.md"; continue ;;
      *) log "$p $k: prompt-resolve rc $RRC ($(head -1 "$TMPD/err")); project skipped"; return 1 ;;
    esac
    read -r _ src _ < "$TMPD/src"
    if [ "$src" = repo ] || { [ "$k" = rules ] && [ "$src" = fleet ]; }; then
      drop "$d/$k.md"
    else
      mkdir -p "$d" || return 1
      resolve "$p" "$k" > "$d/$k.md.tmp"
      [ "$RRC" = 3 ] && { rm -f "$d/$k.md.tmp"; return 3; }
      if [ "$RRC" != 0 ]; then rm -f "$d/$k.md.tmp"; log "$p $k: body rc $RRC; project skipped"; return 1; fi
      put "$d/$k.md.tmp" "$d/$k.md"
    fi
    cat "$TMPD/src" >> "$TMPD/sources"
  done
  mkdir -p "$d" && cp "$TMPD/sources" "$d/sources.tsv.tmp" && put "$d/sources.tsv.tmp" "$d/sources.tsv"
}

RUN_DOWN=0
for P in $PROJECTS; do
  NPROJ=$((NPROJ+1))
  render_project "$P"
  [ $? = 3 ] && { RUN_DOWN=1; break; }
done
if [ "$RUN_DOWN" = 0 ]; then
  resolve _fleet rules --source > "$TMPD/fsrc"
  case "$RRC" in
    0) read -r _ FSRC _ < "$TMPD/fsrc"
       if [ "$FSRC" = fleet ]; then
         mkdir -p "$OUT/_fleet"
         resolve _fleet rules > "$OUT/_fleet/rules.md.tmp"
         if [ "$RRC" = 0 ]; then put "$OUT/_fleet/rules.md.tmp" "$OUT/_fleet/rules.md"
         else rm -f "$OUT/_fleet/rules.md.tmp"; [ "$RRC" = 3 ] && RUN_DOWN=1; fi
       else
         drop "$OUT/_fleet/rules.md"
       fi ;;
    3) RUN_DOWN=1 ;;
    4) drop "$OUT/_fleet/rules.md" ;;
    *) log "_fleet rules: prompt-resolve rc $RRC ($(head -1 "$TMPD/err")); _fleet/rules.md kept" ;;
  esac
fi
# A project that left fleet.conf: its dir goes. An empty list removes nothing.
if [ "$RUN_DOWN" = 0 ] && [ -n "$PROJECTS" ]; then
  for D in "$OUT"/*/; do
    D=${D%/}; N=${D##*/}
    [ -d "$D" ] && [ "$N" != _fleet ] || continue
    grep -qxF -- "$N" <<<"$PROJECTS" && continue
    rm -rf -- "$D" && REMOVED=$((REMOVED+1))
  done
fi

if [ "$RUN_DOWN" = 1 ]; then
  if [ ! -f "$DOWN" ]; then
    date -u +%s > "$DOWN"
    HARNESS="$H" "$H/bin/alert-line.sh" --id prompt-render-worker-down \
      "prompt-render: worker did not answer (${DOWN_ERR:-no detail}); state/prompts/ kept as is, builds use the last resolved prompts" >/dev/null 2>&1
  else
    log "worker still down since $(cat "$DOWN" 2>/dev/null) (${DOWN_ERR:-no detail}); state/prompts/ kept"
  fi
elif [ -f "$DOWN" ]; then
  rm -f "$DOWN"
  log "worker answered again; down marker removed"
  HARNESS="$H" "$H/bin/alert-line.sh" --severity resolved --id prompt-render-worker-down \
    "prompt-render: worker answered again" >/dev/null 2>&1
fi
log "projects=$NPROJ written=$WRITTEN removed=$REMOVED unchanged=$UNCHANGED down=$RUN_DOWN"
exit 0
