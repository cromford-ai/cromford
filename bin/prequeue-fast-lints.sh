#!/bin/bash
# bin/prequeue-fast-lints.sh — the pre-queue fast lint set (BH-8473).
#
#   bin/prequeue-fast-lints.sh --list [--set id,..] [--catalog <tsv>]
#   bin/prequeue-fast-lints.sh --run --tree <dir> --out <dir> [--base <ref>]
#       [--base-tree <dir>] [--cache-dir <dir>] [--budget-s N] [--jobs N]
#       [--set id,..] [--catalog <tsv>]
#
# The merge conductor's hook bin/lib/mc-prequeue.d/fast-lints.sh runs it on a
# READY head merged onto current main, in a snapshot, as nobody. It also runs
# by hand on any checkout.
#
#   --catalog    default catalog/prequeue-fast-lints.tsv beside this script.
#   --set        a comma list of catalog ids; empty = every row. An unknown id
#                is one stderr note and is skipped. A set with no known id is
#                rc 2, never an empty green.
#   --list       prints `<id>\t<argv>` for each resolved id.
#   --run        runs the items in --tree, --jobs at once. Every item shares
#                one wall budget, --budget-s: each one gets `timeout` with the
#                seconds left when it starts.
#   --base       the ref the diff-scoped items read (default origin/main).
#   --base-tree  a tree of the base (current main). Each item that is red in
#                --tree runs again there, inside the same budget, unless
#                --cache-dir holds its base rc (<cache>/<id>.rc, one integer).
#                A base rc it measured is written there.
#   --out        receives results.tsv, one `<id>\t<suite>\t<rc>\t<seconds>\t<state>`
#                row per item (rc and seconds of the --tree run), and
#                log/<id>.log (log/<id>.base.log for a base run).
#
# THE DECISION RULE (state):
#   green          rc 0 in --tree (whatever the output says)
#   red            rc != 0 in --tree, and rc 0 in the base (or no --base-tree)
#   preexisting    rc != 0 in --tree, and rc != 0 in the base
#   unfinished     killed by the budget (rc 124/137), or never started, in
#                  --tree or in the base run of a red
#   could-not-run  rc 125/126/127 (a missing script), in --tree or in the base
# Only `red` asks the conductor to park the head.
#
# The `@trace` argv runs bin/test-trace-safety.sh --gate --only-file <list> on
# the tests/*.sh and tests/mc/*.sh files that `git diff <base>..HEAD` adds or
# modifies. No such file: green, nothing runs.
#
# stdout: one line, `prequeue-fast-lints: <n> items, <s>s, red=<ids|none>
#   unfinished=<ids|none> preexisting=<ids|none> could-not-run=<ids|none>`.
# rc 0 no red; rc 1 at least one red; rc 2 bad args or an empty set.
#
# --budget-s 60 and --jobs 4 are the code fallbacks of the settings rows
# lane.merge-conductor.mc_prequeue_fast_lints_budget_s and
# lane.merge-conductor.mc_prequeue_fast_lints_jobs, which the hook passes.
set -uo pipefail

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
CATALOG="$SELF_DIR/../catalog/prequeue-fast-lints.tsv"
MODE="" TREE="" BASE_REF=origin/main BASE_TREE="" OUT="" CACHE="" SET=""
BUDGET=60 JOBS=4

die2() { echo "prequeue-fast-lints: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --list) MODE=list; shift ;;
    --run) MODE=run; shift ;;
    --catalog|--set|--tree|--base|--base-tree|--out|--cache-dir|--budget-s|--jobs)
      [ $# -ge 2 ] || die2 "$1 needs a value"
      case "$1" in
        --catalog) CATALOG=$2 ;; --set) SET=$2 ;; --tree) TREE=$2 ;; --base) BASE_REF=$2 ;;
        --base-tree) BASE_TREE=$2 ;; --out) OUT=$2 ;; --cache-dir) CACHE=$2 ;;
        --budget-s) BUDGET=$2 ;; --jobs) JOBS=$2 ;;
      esac; shift 2 ;;
    *) die2 "unknown argument '$1'" ;;
  esac
done
[ -n "$MODE" ] || die2 "want --list or --run"
[[ "$BUDGET" =~ ^[0-9]+$ ]] && [ "$BUDGET" -ge 1 ] || die2 "--budget-s '$BUDGET' is not a positive integer"
[[ "$JOBS" =~ ^[0-9]+$ ]] && [ "$JOBS" -ge 1 ] || die2 "--jobs '$JOBS' is not a positive integer"
[ -r "$CATALOG" ] || die2 "cannot read the catalog $CATALOG"

# ── the catalog and the set ────────────────────────────────────────────────
declare -A ARGV SUITE
ALL=()
while IFS=$'\t' read -r id argv suite _; do
  case "$id" in ''|'#'*) continue ;; esac
  [[ "$id" =~ ^[a-z0-9-]+$ ]] && [ -n "${argv:-}" ] && [ -n "${suite:-}" ] \
    || { echo "prequeue-fast-lints: catalog row '$id' is malformed, skipped" >&2; continue; }
  ARGV[$id]=$argv; SUITE[$id]=$suite; ALL+=("$id")
done < "$CATALOG"
SEL=()
if [ -z "$SET" ]; then SEL=("${ALL[@]}")
else
  for w in ${SET//,/ }; do
    if [ -z "${ARGV[$w]+x}" ]; then echo "prequeue-fast-lints: unknown id '$w' in the set, skipped" >&2; continue; fi
    case " ${SEL[*]} " in *" $w "*) continue ;; esac
    SEL+=("$w")
  done
fi
[ "${#SEL[@]}" -gt 0 ] || die2 "the set '${SET:-<every row>}' names no catalog item"

if [ "$MODE" = list ]; then
  for id in "${SEL[@]}"; do printf '%s\t%s\n' "$id" "${ARGV[$id]}"; done
  exit 0
fi

# ── the run ────────────────────────────────────────────────────────────────
[ -n "$TREE" ] && [ -d "$TREE" ] || die2 "--run needs --tree <dir>"
[ -n "$OUT" ] || die2 "--run needs --out <dir>"
[ -z "$BASE_TREE" ] || [ -d "$BASE_TREE" ] || die2 "--base-tree $BASE_TREE is not a directory"
mkdir -p "$OUT/log" "$OUT/rc" || die2 "cannot make $OUT"
OUT=$(cd "$OUT" && pwd); TREE=$(cd "$TREE" && pwd)
[ -z "$BASE_TREE" ] || BASE_TREE=$(cd "$BASE_TREE" && pwd)
[ -z "$CACHE" ] || mkdir -p "$CACHE" 2>/dev/null || CACHE=""
DEADLINE=$((SECONDS + BUDGET))

# A base tree is main itself: its diff against the base ref is empty. A
# snapshot's base tree has no such ref, so it is made to point at its HEAD.
if [ -n "$BASE_TREE" ] && [ "$BASE_REF" = origin/main ] \
   && ! git -C "$BASE_TREE" rev-parse -q --verify "origin/main^{commit}" >/dev/null 2>&1; then
  git -C "$BASE_TREE" update-ref refs/remotes/origin/main HEAD >/dev/null 2>&1 || true
fi

# _trace <dir> <limit> — the @trace item: the gate on the suites the diff adds
#   or edits. rc 125 when the diff cannot be read.
_trace() {
  local dir="$1" lim="$2" list
  list="$OUT/trace-list.$(basename "$dir")"
  git -C "$dir" diff --name-only --no-renames --diff-filter=AM "$BASE_REF..HEAD" > "$list.raw" 2>/dev/null \
    || { echo "trace: cannot read the diff $BASE_REF..HEAD in $dir"; return 125; }
  grep -E '^tests/(mc/)?[^/]+\.sh$' "$list.raw" > "$list"
  [ -s "$list" ] || { echo "trace: the diff adds or edits no tests/*.sh"; return 0; }
  echo "trace: $(grep -c . "$list") suite(s): $(tr '\n' ' ' < "$list")"
  ( cd "$dir" || exit 125; exec timeout -k 2 "$lim" bash bin/test-trace-safety.sh --gate --only-file "$list" )
}

_class() {  # _class <rc> -> ok | killed | cnr | fail
  case "$1" in 0) echo ok ;; 124|137) echo killed ;; 125|126|127) echo cnr ;; *) echo fail ;; esac
}

# _run <id> <dir> <limit> <log> — one run of item <id> in <dir>; rc is its rc.
_run() {
  if [ "${ARGV[$1]}" = @trace ]; then _trace "$2" "$3" < /dev/null > "$4" 2>&1
  else ( cd "$2" || exit 125; exec timeout -k 2 "$3" bash -c "${ARGV[$1]}" ) < /dev/null > "$4" 2>&1; fi
}

# _item <id> <limit> — the item in --tree, then, when it failed, its base rc: from the
#   cache, else a run in --base-tree with the seconds left (in the same job, so
#   a slow sibling never starves it). Writes $OUT/rc/<id>.merged (`<rc>
#   <seconds>`) and $OUT/rc/<id>.base (`<rc> <seconds> cached|measured`).
_item() {
  local id="$1" t0=$SECONDS rc left c
  _run "$id" "$TREE" "$2" "$OUT/log/$id.log"; rc=$?
  echo "$rc $((SECONDS - t0))" > "$OUT/rc/$id.merged"
  [ "$(_class "$rc")" = fail ] || return 0
  if [ -n "$CACHE" ] && c=$(cat "$CACHE/$id.rc" 2>/dev/null) && [[ "$c" =~ ^[0-9]+$ ]]; then
    echo "$c 0 cached" > "$OUT/rc/$id.base"; return 0
  fi
  [ -n "$BASE_TREE" ] || return 0
  left=$((DEADLINE - SECONDS))
  [ "$left" -ge 1 ] || { echo "124 0 measured" > "$OUT/rc/$id.base"; return 0; }
  t0=$SECONDS
  _run "$id" "$BASE_TREE" "$left" "$OUT/log/$id.base.log"; rc=$?
  echo "$rc $((SECONDS - t0)) measured" > "$OUT/rc/$id.base"
}

# _pool <id...> — runs the items, $JOBS at once, inside the budget. An item
#   the budget leaves no second for is recorded as killed (124 0).
_pool() {
  local id left
  for id in "$@"; do
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n 2>/dev/null || true; done
    left=$((DEADLINE - SECONDS))
    if [ "$left" -lt 1 ]; then echo "124 0" > "$OUT/rc/$id.merged"; continue; fi
    _item "$id" "$left" &
  done
  wait
}

_rc_of() { local r=""; read -r r _ < "$OUT/rc/$1.$2" 2>/dev/null; printf '%s' "${r:-125}"; }
_secs_of() { local s=""; read -r _ s _ < "$OUT/rc/$1.$2" 2>/dev/null; printf '%s' "${s:-0}"; }

_pool "${SEL[@]}"

declare -A STATE
for id in "${SEL[@]}"; do
  case "$(_class "$(_rc_of "$id" merged)")" in
    ok) STATE[$id]=green; continue ;;
    killed) STATE[$id]=unfinished; continue ;;
    cnr) STATE[$id]=could-not-run; continue ;;
  esac
  if [ ! -e "$OUT/rc/$id.base" ]; then STATE[$id]=red; continue; fi   # no --base-tree
  brc=$(_rc_of "$id" base)
  case "$(_class "$brc")" in
    ok) STATE[$id]=red ;;
    fail) STATE[$id]=preexisting ;;
    killed) STATE[$id]=unfinished ;;
    cnr) STATE[$id]=could-not-run ;;
  esac
  # A base rc this run measured is a hint for the next run on the same main.
  if [ -n "$CACHE" ] && grep -q ' measured$' "$OUT/rc/$id.base" 2>/dev/null; then
    case "$(_class "$brc")" in ok|fail) printf '%s\n' "$brc" > "$CACHE/$id.rc.tmp.$$" && mv -f "$CACHE/$id.rc.tmp.$$" "$CACHE/$id.rc" ;; esac
  fi
done

: > "$OUT/results.tsv"
red="" unf="" pre="" cnr="" anyred=0
for id in "${SEL[@]}"; do
  printf '%s\t%s\t%s\t%s\t%s\n' "$id" "${SUITE[$id]}" "$(_rc_of "$id" merged)" "$(_secs_of "$id" merged)" "${STATE[$id]}" >> "$OUT/results.tsv"
  case "${STATE[$id]}" in
    red) red="$red,$id"; anyred=1 ;;
    unfinished) unf="$unf,$id" ;;
    preexisting) pre="$pre,$id" ;;
    could-not-run) cnr="$cnr,$id" ;;
  esac
done
el=$((SECONDS - DEADLINE + BUDGET))
red=${red#,} unf=${unf#,} pre=${pre#,} cnr=${cnr#,}
echo "prequeue-fast-lints: ${#SEL[@]} items, ${el}s, red=${red:-none} unfinished=${unf:-none} preexisting=${pre:-none} could-not-run=${cnr:-none}"
[ "$anyred" = 0 ]
