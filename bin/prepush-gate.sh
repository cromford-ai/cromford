#!/bin/bash
# bin/prepush-gate.sh [--base <ref>] [--tree <dir>] [--out <dir>] [--jobs N]
#                     [--list] [--restamp]
#
# THE PRE-PUSH GATE (BH-7187, HOTFIX TOC lever 1). One command runs every
# deterministic ratchet on the committed head BEFORE the push, so a "no" comes
# at the start and not from the merge queue. Why: on 2026-10-16 (BH-7123
# rollout) 9 of 10 merge-queue rounds were lost to lints that fired only in CI
# (schema-fragment-name, scratch-closure, determinism race-sigpipe-echo,
# test-impact orphans, the br driver ceiling, alert-writers LA_NEW, lib-root
# literal, checks-run tests-scratch-only). Each miss cost a full fast-check and
# batch cycle (about 35 min). All of them are local and deterministic.
#
# THE COMPONENTS, in this order (--list prints them):
#   rules-pack       bin/rules-pack.sh --runner local --base <fork>, every
#                    catalog component except the two below, which run as their
#                    own rows so a red names them
#   fast-lints       bin/fast-lints.sh --run (the always-suites)
#   checks-run       bin/checks-run.sh --tree .
#   list-file-lint   bin/list-file-lint.sh --base <fork> (a list doc grows only with a dated note)
#   orphans          bin/test-impact.sh orphans --check (TI_BASE = the fork)
#   determinism      bin/test-determinism-lint.sh --changed <fork>
#   llm-sites, context-budgets, config-inventory, render-rules, render-cron,
#   render-env, render-doc-sections, schema-build
#                    the derived-docs gates, each with --check
#
# OUTPUT. One summary line per component on stdout:
#   prepush-gate: <id> <green|red|could-not-run> rc=<n> <s>s [<names>]
# then, under a red or could-not-run one, up to 15 indented finding lines. The
# last line is the verdict: GREEN, RED or COULD-NOT-RUN. <out>/summary.tsv has
# `<id>\t<state>\t<rc>\t<seconds>\t<names>` per component (names = the rules
# pack ids behind a red, else the component id), <out>/<id>.out and .err the
# raw output. When a finding is the base stamp-order one (schema-fragment-name:
# uses table <t>, which <L> at the base creates and which sorts after this
# fragment, BH-7229), the exact `git mv`
# lines for the current UTC minute are printed, and `--restamp` applies them
# as ONE commit through bin/lib/schema-restamp.sh (sr_apply).
#
# NEVER SILENTLY GREEN. A component whose script is missing (rc 127), whose
# runner cannot start (125), that times out (124) or ends in any rc other than
# 0 or 1 is could-not-run, not green. A rules pack that exits 1 with no finding
# line is could-not-run too (bin/lib/rb/gates.sh reads it the same way).
#
# rc 0   every component green
#    1   at least one red or could-not-run (the verdict line says which)
#    2   bad args, an unresolvable base, or (--restamp) a restamp that failed
# --restamp rc: 0 committed, 1 nothing stale, 2 failed.
#
# THE OPERATOR PATH. This script is also a git pre-push hook:
#   printf '#!/bin/sh\nexec bin/prepush-gate.sh\n' > .git/hooks/pre-push
#   chmod +x .git/hooks/pre-push
# (docs/notes/2026-10-17-BH-7187-prepush-gate.md.) The pool builder calls it in
# bin/lib/rb/pr.sh, the `prepush gate` span, right before the push.
#
# Knobs (env only, no setting row: the gate decides nothing about business):
#   PREPUSH_GATE_JOBS       components run at once (default 4)
#   PREPUSH_GATE_TIMEOUT_S  per-component cap in seconds (default 300)
#   PREPUSH_GATE_TABLE      a TSV of `id<TAB>argv` rows replacing the table
#                           (the test seam; <base> <fork> <out> are replaced)
#   HARNESS_TEST_SANDBOX    set to 1 for the components when unset, the same
#                           prefix the Verification Contract puts on its checks
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

die2() { echo "prepush-gate: $*" >&2; exit 2; }

# default_table — `id<TAB>argv` per component. argv runs under bash -c from the
# tree root; <base> is the --base ref, <fork> the merge-base sha, <out> the dir.
default_table() {
  printf '%s\t%s\n' \
    rules-pack 'bin/rules-pack.sh --runner local --tree . --base <fork> --skip determinism,checks-tree --out <out>/rules-pack.d' \
    fast-lints 'bin/fast-lints.sh --run --out <out>/fast-lints.d' \
    checks-run 'bin/checks-run.sh --tree .' \
    list-file-lint 'bin/list-file-lint.sh --base <fork>' \
    orphans 'bin/test-impact.sh orphans --check' \
    determinism 'bin/test-determinism-lint.sh --changed <fork>' \
    llm-sites 'bin/llm-sites-build.sh --check' \
    context-budgets 'bin/context-budgets-build.sh --check' \
    config-inventory 'bin/config-inventory.sh --check' \
    render-rules 'bin/render-rules.sh --check' \
    render-cron 'bin/render-cron.sh --check' \
    render-env 'bin/render-env-example.sh --check' \
    render-doc-sections 'bin/render-doc-sections.sh --check' \
    schema-build 'bin/schema-build.sh --check'
}

table() {
  if [ -n "${PREPUSH_GATE_TABLE:-}" ]; then
    [ -r "$PREPUSH_GATE_TABLE" ] || die2 "PREPUSH_GATE_TABLE=$PREPUSH_GATE_TABLE is not readable"
    grep -v '^#' "$PREPUSH_GATE_TABLE" | awk -F'\t' 'NF >= 2'
  else
    default_table
  fi
}

# run_one <id> <argv> — one component, from the tree root, on its own files.
run_one() {
  local id="$1" argv="$2" t0 rc tmo=()
  argv=${argv//<base>/$BASE}; argv=${argv//<fork>/$FORK}; argv=${argv//<out>/$OUT}
  if command -v timeout >/dev/null 2>&1; then tmo=(timeout "$TIMEOUT"); elif command -v gtimeout >/dev/null 2>&1; then tmo=(gtimeout "$TIMEOUT"); fi
  t0=$(date +%s)
  ( cd "$TREE" && export TI_BASE="$FORK" HARNESS_TEST_SANDBOX="${HARNESS_TEST_SANDBOX:-1}" \
      && exec ${tmo[@]+"${tmo[@]}"} bash -c "$argv" ) >"$OUT/$id.out" 2>"$OUT/$id.err"
  rc=$?
  echo "$rc" > "$OUT/$id.rc"
  echo $(( $(date +%s) - t0 )) > "$OUT/$id.sec"
}

# state_of <id> <rc> — green | red | could-not-run. 0 is green and 1 is red;
# a rules pack rc 0 without its summary.json saying "clean" is could-not-run (a pack
# that died early, such as bash 3.2 on a Mac, exits 0 with no verdict); every other rc (127 missing, 125 runner, 124 timeout, 2 usage) is could-not-run.
state_of() {
  case "$2" in
    0) if [ "$1" = rules-pack ] && ! grep -Eq '"state": *"clean"' "$OUT/rules-pack.d/summary.json" 2>/dev/null; then echo could-not-run; else echo green; fi ;;
    1) if [ "$1" = rules-pack ] && ! grep -q . "$OUT/$1.out" 2>/dev/null; then echo could-not-run; else echo red; fi ;;
    *) echo could-not-run ;;
  esac
}

# names_of <id> <state> — the rules pack ids behind a red, else the component id.
names_of() {
  local n
  if [ "$1" = rules-pack ] && [ "$2" = red ]; then
    n=$(sed -n 's/^\([a-z0-9][a-z0-9-]*\): .*/\1/p' "$OUT/$1.out" | LC_ALL=C sort -u | paste -sd, -)
    [ -n "$n" ] && { echo "$n"; return; }
  fi
  echo "$1"
}

# show_findings <id> <state> — the lines under a summary row.
show_findings() {
  local id="$1" why=""
  if [ "$id" = rules-pack ] && [ -s "$OUT/$id.out" ]; then
    head -15 "$OUT/$id.out" | sed 's/^/    /'
    return
  fi
  [ "$2" = could-not-run ] && why="    (could not run: rc $(cat "$OUT/$id.rc"); a rc 124 is the ${TIMEOUT}s cap, a rc 127 a missing script)"
  [ -n "$why" ] && echo "$why"
  cat "$OUT/$id.out" "$OUT/$id.err" 2>/dev/null | grep . | tail -n 15 | sed 's/^/    /'
}

# restamp_hint — the exact git mv lines when the stamp-order finding is red.
restamp_hint() {
  local lib="$HERE/lib/schema-restamp.sh" plan old new
  grep -qF 'at the base creates and which sorts after this fragment' "$OUT/rules-pack.out" 2>/dev/null || return 0
  echo "    fix: bin/prepush-gate.sh --restamp (one commit, no SQL change), or by hand:"
  [ -r "$lib" ] && . "$lib" 2>/dev/null && plan=$(sr_plan "$TREE" "$BASE" HEAD 2>/dev/null)
  while IFS=$'\t' read -r old new; do
    [ -n "$old" ] && echo "    git mv $old $new"
  done <<<"${plan:-}"
  return 0
}

# do_restamp — sr_apply on the tree; the gate's own rc contract (0 / 1 / 2).
do_restamp() {
  local lib="$HERE/lib/schema-restamp.sh" sha rc
  [ -r "$lib" ] || die2 "cannot read $lib"
  . "$lib" || die2 "cannot source $lib"
  sha=$(sr_apply "$TREE" "$BASE"); rc=$?
  case "$rc" in
    0) echo "prepush-gate: restamped schema fragments in commit ${sha:0:12}" ;;
    1) echo "prepush-gate: no stale schema fragment, nothing to restamp" ;;
    *) echo "prepush-gate: the restamp failed (see the line above)" >&2; return 2 ;;
  esac
  return "$rc"
}

# run_all — start the table in batches of $JOBS; fills $OUT/<id>.{out,err,rc,sec}.
run_all() {
  local id argv n=0
  while IFS=$'\t' read -r id argv; do
    [ -n "$id" ] || continue
    run_one "$id" "$argv" &
    n=$((n + 1))
    [ $((n % JOBS)) -eq 0 ] && wait
  done < <(table)
  wait
}

# report — summary rows, summary.tsv, the verdict. Returns the gate rc.
report() {
  local id argv rc st sec names red=0 cnr=0 green=0 verdict
  : > "$OUT/summary.tsv"
  while IFS=$'\t' read -r id argv; do
    [ -n "$id" ] || continue
    rc=$(cat "$OUT/$id.rc" 2>/dev/null || echo 125); sec=$(cat "$OUT/$id.sec" 2>/dev/null || echo 0)
    st=$(state_of "$id" "$rc"); names=$(names_of "$id" "$st")
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$st" "$rc" "$sec" "$names" >> "$OUT/summary.tsv"
    echo "prepush-gate: $id $st rc=$rc ${sec}s$([ "$st" = red ] && echo " [$names]")"
    case "$st" in
      green) green=$((green + 1)) ;;
      red) red=$((red + 1)); show_findings "$id" "$st"; [ "$id" = rules-pack ] && restamp_hint ;;
      *) cnr=$((cnr + 1)); show_findings "$id" "$st" ;;
    esac
  done < <(table)
  verdict=GREEN; [ "$cnr" -gt 0 ] && verdict=COULD-NOT-RUN; [ "$red" -gt 0 ] && verdict=RED
  echo "prepush-gate: $verdict green=$green red=$red could-not-run=$cnr (details in $OUT)"
  [ "$verdict" = GREEN ]
}

BASE=origin/main; TREE="$ROOT"; OUT=""; MODE=run
JOBS=${PREPUSH_GATE_JOBS:-4}; TIMEOUT=${PREPUSH_GATE_TIMEOUT_S:-300}
while [ $# -gt 0 ]; do
  case "$1" in --base|--tree|--out|--jobs) [ $# -ge 2 ] || die2 "$1 needs a value" ;; esac
  case "$1" in
    --base) BASE="$2"; shift 2 ;;
    --tree) [ -d "$2" ] || die2 "--tree $2 is not a directory"; TREE=$(cd "$2" && pwd); shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --list) MODE=list; shift ;;
    --restamp) MODE=restamp; shift ;;
    -h|--help) sed -n '2,62p' "$0"; exit 0 ;;
    *) die2 "unknown argument '$1' (see --help)" ;;
  esac
done
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die2 "--jobs must be a whole number >= 1 (got '$JOBS')"
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die2 "PREPUSH_GATE_TIMEOUT_S must be a whole number >= 1 (got '$TIMEOUT')"

if [ "$MODE" = list ]; then table; exit 0; fi

git -C "$TREE" rev-parse --verify -q "$BASE^{commit}" >/dev/null 2>&1 || die2 "base '$BASE' does not resolve in $TREE"
if [ "$MODE" = restamp ]; then do_restamp; exit $?; fi
FORK=$(git -C "$TREE" merge-base "$BASE" HEAD 2>/dev/null) || die2 "no merge-base of '$BASE' and HEAD in $TREE"

[ -n "$OUT" ] || OUT=$(mktemp -d "${TMPDIR:-/tmp}/prepush-gate.XXXXXX") || die2 "cannot make a temp dir"
mkdir -p "$OUT" || die2 "cannot make $OUT"
OUT=$(cd "$OUT" && pwd)
echo "prepush-gate: base ${FORK:0:12} head $(git -C "$TREE" rev-parse --short=12 HEAD), $(table | grep -c .) components, $JOBS at once"
run_all
report
