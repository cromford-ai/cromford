#!/bin/bash
# bin/gate.sh — run a tree's gate from a Mac session: ONE command (BH-6736).
#
#   bin/gate.sh <dir> tests/a.sh [tests/b.sh …]   on the shared Fly test host
#   bin/gate.sh <dir> -- <command…>               one command on the host
#   bin/gate.sh --local <dir> [tests/a.sh …]      local Docker, under a slot lock
#   bin/gate.sh --impacted [--base <ref>] <dir>   the suites the diff reaches
#   bin/gate.sh -h | --help                       this text
#
#   --local     run <dir>/bin/run-tests-in-docker.sh on this machine. At most
#               GATE_LOCAL_SLOTS (default 2, 1..6) local gates run at once on
#               one machine; the next one prints one line and waits for a slot.
#               Ctrl-C ends the wait (exit 130). Suites only, no `--`.
#   --impacted  compute the suites: the files that differ from the merge-base of
#               <base> (default origin/main) and HEAD, committed or not, plus
#               untracked files, through bin/test-impact.sh select --map-only.
#               It takes no suites and no `--` on the command line.
#   --base REF  the ref --impacted diffs against. Only with --impacted.
#
# EXIT CODES are bin/remote-gate.sh's, and they do not overlap:
#   0-124  the number of failing suites (the command's own exit in `--` mode)
#   125    THE RUN COULD NOT HAPPEN. Nothing passed. On the remote path gate.sh
#          prints the exact `bin/gate.sh --local …` command to run instead; it
#          never falls back to local by itself. --impacted with no suite list
#          is 125 too: a gate that cannot compute its list must not pass.
#   2      the command line was wrong; nothing ran and no slot was taken.
#   130/143  interrupted. Never a pass.
#
# WHY. On 2026-10-14 a Mac ran 7 local test containers at once, each with
# `xargs -P 6`, on 18 cores: load 167. Every session had its own way to run the
# gate, mostly an inline docker run. This is the one sanctioned way: the remote
# host by default, and local Docker only when asked and only GATE_LOCAL_SLOTS
# at a time.
#
# BASH 3.2. A Mac runs /bin/bash 3.2, so: no {fd}> redirection, no mapfile or
# readarray, no declare -A, no ${x,,}. The slot lock uses the fixed fd 9.
#
# THE SLOT LOCK. Slots are $GATE_SLOT_DIR/1..N, tried in order.
#   flock arm (flock on PATH): fd 9 holds a flock on the file <n>. The lock
#     lives as long as fd 9 is open here and in the runner, so a killed gate
#     frees its slot with no cleanup.
#   mkdir arm (no flock, the Mac default): the dir <n>.d holds a file `pid`.
#     A dir whose pid is dead is stale: one `mv` reclaims it, and a reclaimer
#     that finds a different pid in what it moved puts it back. A dir with no
#     pid file is a holder between mkdir and its pid write, so it is held until
#     it is 10 s old. The EXIT trap removes the dir while its pid is ours.
#
# SEAMS (env; the defaults are the production values):
#   REMOTE_GATE_BIN   $SELF_DIR/remote-gate.sh
#   GATE_LOCAL_BIN    <dir>/bin/run-tests-in-docker.sh (the tree's own runner:
#                     it mounts its own repo, so it must be the one in <dir>)
#   GATE_IMPACT_BIN   $SELF_DIR/test-impact.sh (run with --root <dir>)
#   GATE_SLOT_DIR     ${TMPDIR:-/tmp}/bh-gate-slots
#   GATE_LOCK_MODE    auto (flock when on PATH, else mkdir) | mkdir
#   GATE_POLL_S       0.5, the wait loop's poll interval in seconds
# The knob GATE_LOCAL_SLOTS is registered in catalog/lanes.d/_lib.gate.json.
set -uo pipefail

SELF_DIR=$(cd "$(dirname "$0")" && pwd)

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; }
die2() { echo "gate: $*" >&2; exit 2; }

LOCAL=0; IMPACTED=0; BASE=""; HAVE_BASE=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --local) LOCAL=1 ;;
    --impacted) IMPACTED=1 ;;
    --base) [ $# -ge 2 ] || die2 "--base needs a ref"
            BASE=$2; HAVE_BASE=1; shift ;;
    --base=*) BASE="${1#--base=}"; HAVE_BASE=1 ;;
    --) die2 "-- goes after <dir>" ;;
    -*) die2 "unknown flag '$1' (bin/gate.sh --help)" ;;
    *) break ;;
  esac
  shift
done

[ $# -ge 1 ] || die2 "no <dir> (bin/gate.sh --help)"
[ -d "$1" ] || die2 "'$1' is not a directory"
DIR=$(cd "$1" && pwd) || die2 "cannot enter '$1'"
shift

CMD_MODE=0
if [ $# -ge 1 ] && [ "$1" = "--" ]; then CMD_MODE=1; fi

[ "$HAVE_BASE" = 1 ] && [ "$IMPACTED" = 0 ] && die2 "--base only goes with --impacted"
[ "$HAVE_BASE" = 1 ] && [ -z "$BASE" ] && die2 "--base needs a ref"
if [ "$IMPACTED" = 1 ]; then
  [ "$CMD_MODE" = 1 ] && die2 "--impacted computes the suites; it takes no '--' command"
  [ $# -eq 0 ] || die2 "--impacted computes the suites; it takes none on the command line"
fi
[ "$LOCAL" = 1 ] && [ "$CMD_MODE" = 1 ] && \
  die2 "--local runs suites only (bin/run-tests-in-docker.sh takes no '--' command)"

REMOTE_GATE_BIN="${REMOTE_GATE_BIN:-$SELF_DIR/remote-gate.sh}"
GATE_LOCAL_BIN="${GATE_LOCAL_BIN:-$DIR/bin/run-tests-in-docker.sh}"
GATE_IMPACT_BIN="${GATE_IMPACT_BIN:-$SELF_DIR/test-impact.sh}"
GATE_SLOT_DIR="${GATE_SLOT_DIR:-${TMPDIR:-/tmp}/bh-gate-slots}"
GATE_LOCK_MODE="${GATE_LOCK_MODE:-auto}"
GATE_POLL_S="${GATE_POLL_S:-0.5}"

TMP_LIST=""; HELD_DIR=""
cleanup() {
  [ -n "$TMP_LIST" ] && rm -f "$TMP_LIST"
  if [ -n "$HELD_DIR" ] && [ "$(cat "$HELD_DIR/pid" 2>/dev/null)" = "$$" ]; then
    rm -rf "$HELD_DIR"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ── the suite list ──────────────────────────────────────────────────────────
SUITES=()
if [ "$IMPACTED" = 1 ]; then
  git -C "$DIR" rev-parse --is-inside-work-tree > /dev/null 2>&1 || \
    die2 "--impacted needs a git work tree; '$DIR' is not one"
  BASE="${BASE:-origin/main}"
  mb=$(git -C "$DIR" merge-base "$BASE" HEAD 2>/dev/null) || \
    die2 "--impacted cannot find the merge-base of $BASE and HEAD in $DIR"
  TMP_LIST=$(mktemp "${TMPDIR:-/tmp}/gate-changed.XXXXXX") || {
    echo "gate: --impacted could not compute a suite list (no temp file)" >&2; exit 125; }
  { git -C "$DIR" diff --name-only "$mb" && \
    git -C "$DIR" ls-files --others --exclude-standard; } > "$TMP_LIST.raw" || {
    rm -f "$TMP_LIST.raw"
    echo "gate: --impacted could not compute a suite list (git diff failed)" >&2; exit 125; }
  sort -u "$TMP_LIST.raw" > "$TMP_LIST"; rm -f "$TMP_LIST.raw"
  sel=$("$GATE_IMPACT_BIN" select --root "$DIR" --map-only --changed "$TMP_LIST"); src=$?
  while IFS= read -r line; do
    case "$line" in tests/*.sh) SUITES+=("$line") ;; esac
  done <<< "$sel"
  if [ "$src" != 0 ] || [ "${#SUITES[@]}" -eq 0 ]; then
    echo "gate: --impacted could not compute a suite list (rc $src, ${#SUITES[@]} suites). Nothing ran." >&2
    exit 125
  fi
else
  while [ $# -gt 0 ]; do SUITES+=("$1"); shift; done
fi

# ── the remote path (default) ───────────────────────────────────────────────
if [ "$LOCAL" = 0 ]; then
  "$REMOTE_GATE_BIN" "$DIR" ${SUITES[@]+"${SUITES[@]}"}; rc=$?
  if [ "$rc" = 125 ]; then
    echo "gate: the remote gate could not run (rc 125; its reason is above). Nothing passed." >&2
    if [ "$CMD_MODE" = 1 ]; then
      echo "gate: a '--' command has no local path; bin/run-tests-in-docker.sh runs suites only." >&2
    else
      cmd="bin/gate.sh --local $(printf '%q' "$DIR")"
      for s in ${SUITES[@]+"${SUITES[@]}"}; do cmd="$cmd $(printf '%q' "$s")"; done
      echo "gate: to run on this machine instead: $cmd" >&2
    fi
  fi
  exit "$rc"
fi

# ── the local path (--local) ────────────────────────────────────────────────
N="${GATE_LOCAL_SLOTS:-2}"
case "$N" in
  [1-6]) ;;
  *) die2 "GATE_LOCAL_SLOTS wants a whole number 1..6, got '$N'" ;;
esac
[ -x "$GATE_LOCAL_BIN" ] || die2 "no local runner at $GATE_LOCAL_BIN"
mkdir -p "$GATE_SLOT_DIR" || die2 "cannot create the slot dir $GATE_SLOT_DIR"

USE_FLOCK=0
if [ "$GATE_LOCK_MODE" = auto ] && command -v flock > /dev/null 2>&1; then USE_FLOCK=1; fi

alive() { kill -0 "$1" 2>/dev/null || ps -p "$1" > /dev/null 2>&1; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

# reclaim <dir> <pid read before>: move a stale slot dir away. Only one mv can
# win. If the moved dir's pid is not the one we judged dead, a new holder took
# it in between: put it back and leave the slot held.
reclaim() {
  local d=$1 was=$2 s="$1.stale.$$" now
  mv "$d" "$s" 2>/dev/null || return 1
  now=$(cat "$s/pid" 2>/dev/null)
  if [ "$now" != "$was" ]; then
    mv "$s" "$d" 2>/dev/null || true
    return 1
  fi
  rm -rf "$s"
}

# take_slot <n>: 0 when slot n is now ours.
take_slot() {
  local n=$1 d pid age
  if [ "$USE_FLOCK" = 1 ]; then
    exec 9> "$GATE_SLOT_DIR/$n" || return 1
    flock -n 9 && return 0
    exec 9>&-
    return 1
  fi
  d="$GATE_SLOT_DIR/$n.d"
  if ! mkdir "$d" 2>/dev/null; then
    pid=$(cat "$d/pid" 2>/dev/null)
    if [ -z "$pid" ]; then
      age=$(( $(date +%s) - $(mtime "$d" || date +%s) ))
      [ "$age" -gt 10 ] || return 1
    elif alive "$pid"; then
      return 1
    fi
    reclaim "$d" "$pid" || return 1
    mkdir "$d" 2>/dev/null || return 1
  fi
  echo "$$" > "$d/pid" || { rmdir "$d" 2>/dev/null; return 1; }
  HELD_DIR=$d
}

SLOT=""; WAITED=0
while [ -z "$SLOT" ]; do
  i=1
  while [ "$i" -le "$N" ]; do
    if take_slot "$i"; then SLOT=$i; break; fi
    i=$((i + 1))
  done
  [ -n "$SLOT" ] && break
  if [ "$WAITED" = 0 ]; then
    echo "gate: all $N local slots are held ($GATE_SLOT_DIR/1..$N); waiting for one to free" >&2
    WAITED=1
  fi
  sleep "$GATE_POLL_S"
done

echo "gate: local slot $SLOT of $N" >&2
cd "$DIR" || die2 "cannot enter $DIR"
"$GATE_LOCAL_BIN" ${SUITES[@]+"${SUITES[@]}"}
exit $?
