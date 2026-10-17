#!/bin/bash
# bin/rules-pack.sh [--tree <dir>] [--base <ref>] [--only id,..] [--skip id,..]
#                   [--runner auto|isolated|local] [--out <dir>] [--jobs N] [--list]
#
# The rules pack (BH-3477): a fast, always-run pack of the repo ratchets listed
# in catalog/rules-pack.tsv, for the builder pre-push gate and HARNESS_SUITE_RUN.
#
# CONTRACT (BH-3509; BH-3479's lead-review lane depends on it, do not change it):
#   --tree <dir>   the checkout to judge (default: this script's repo).
#   --base <ref>   default origin/main. The pack judges the merge-base (fork) of
#                  base and the COMMITTED HEAD; uncommitted edits are not judged.
#   --only/--skip  comma lists of catalog ids; an unknown id is a bad arg.
#   --runner       auto | isolated (a snapshot run as nobody, see
#                  bin/lib/rules-pack-snapshot.sh) | local.
#   --out <dir>    receives <id>.log, findings.txt (= stdout), preexisting.txt,
#                  suites.txt (the tests/*.sh paths of the suite components it
#                  actually ran, one per line; read by test-impact-gate.sh
#                  --skip-suites) and summary.json:
#                  {state: clean|red|could-not-run, budget_s, elapsed_s,
#                   over_budget, components:[{id,shape,rc,state,seconds}],
#                   could_not_run:[ids], base, head}
#   --jobs N       components run at once (N >= 1).
#   --list         print the catalog as `id  shape  argv  reason` and exit 0.
#   stdout carries findings only, one per line, `<id>: <line>`. Progress, the
#   summary and pre-existing findings go to stderr and --out.
#   rc 0   no finding in this diff (pre-existing reds allowed)
#   rc 1   at least one finding in this diff
#   rc 2   bad args or unresolvable base
#   rc 125 nothing could run
#
# Knobs (fly-pool lane, resolved `lane_knob fly-pool <ENV> "$PROJECT"` > env >
# code default, which must equal the registry default):
#   RULES_PACK_BUDGET_S  the measured budget (default 60). Elapsed over it is a
#                        stderr note and summary.json's over_budget, never a red.
#   RULES_PACK_JOBS      max parallel components (default 4); --jobs overrides.
#
# Runners (BH-3510): auto is isolated as root beside a live harness
# (${HARNESS_ROOT_OVERRIDE:-/root/harness} exists), else local.
#   local     runs in the tree as it stands; an uncommitted tracked change is
#             warned on stderr (the committed-only guarantee is isolated's).
#             As root beside a harness with HARNESS_TEST_SANDBOX unset, every
#             suite component is could-not-run: tests/lib/scratch.sh refuses to
#             start there and the pack never sets that variable (#463).
#   isolated  rp_snapshot_probe, then rp_snapshot_build; `<fork>`,
#             RATCHET_BASE and TI_BASE become the snapshot's base commit. The
#             snapshot is built in the work dir when nobody can reach it, else
#             under RULES_PACK_SNAPSHOT_TMP (default /tmp); no reachable dir, a
#             failed build, or a base that does not resolve as nobody makes
#             every component could-not-run (rc 125), never a finding.
# A tree component red at HEAD is re-run once on a tree of the fork; red there
# too is pre-existing (stderr and preexisting.txt, never stdout, never rc 1).
# route-fragments needs the generated, git-ignored catalog/lanes.json and
# catalog/llm-sites.json (the worker imports both): when the judged tree lacks
# them, bin/lanes-build.sh --write and the tree's own bin/llm-sites-build.sh
# --compose render them first, and a failed render makes that component
# could-not-run.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
CAT="$ROOT/catalog/rules-pack.tsv"

die2() { echo "rules-pack: $*" >&2; exit 2; }

# rp_catalog — the catalog rows as `id<TAB>shape<TAB>kind<TAB>argv<TAB>needs<TAB>reason`.
rp_catalog() {
  grep -v '^#' "$CAT" | grep .
}

[ -r "$CAT" ] || die2 "no catalog $CAT"
IDS=" $(rp_catalog | cut -f1 | tr '\n' ' ')"

# check_ids <flag> <list> — every comma-separated id must be a catalog id.
check_ids() {
  local id
  [ -n "$2" ] || die2 "$1 needs at least one id"
  for id in ${2//,/ }; do
    case "$IDS" in *" $id "*) ;; *) die2 "$1: unknown id $id" ;; esac
  done
}

LIST=0 TREE=$ROOT BASE=origin/main ONLY="" SKIP="" RUNNER=auto OUT="" JOBS=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0"; exit 0 ;;
    --list) LIST=1; shift; continue ;;
    --tree|--base|--only|--skip|--runner|--out|--jobs)
      [ $# -ge 2 ] || die2 "$1 needs a value" ;;
    *) die2 "unexpected argument $1" ;;
  esac
  case "$1" in
    --tree) [ -d "$2" ] || die2 "--tree $2 is not a directory"; TREE=$(cd "$2" && pwd) ;;
    # Resolved after the parse, against --tree (rc 2 if it cannot).
    --base) [ -n "$2" ] || die2 "--base needs a ref"; BASE=$2 ;;
    --only) check_ids "$1" "$2"; ONLY=$2 ;;
    --skip) check_ids "$1" "$2"; SKIP=$2 ;;
    --runner) case "$2" in auto|isolated|local) RUNNER=$2 ;; *) die2 "--runner $2 (want auto|isolated|local)" ;; esac ;;
    --out) [ -n "$2" ] || die2 "--out needs a directory"; OUT=$2 ;;
    --jobs) [[ "$2" =~ ^[1-9][0-9]*$ ]] || die2 "--jobs $2 (want a whole number >= 1)"; JOBS=$2 ;;
  esac
  shift 2
done

if [ "$LIST" -eq 1 ]; then
  rp_catalog | while IFS=$'\t' read -r id shape _kind argv _needs reason; do
    printf '%s  %s  %s  %s\n' "$id" "$shape" "$argv" "$reason"
  done
  exit 0
fi

# ── selection, in catalog order ─────────────────────────────────────────────
declare -A SHAPE KIND ARGV NEEDS CNR_WHY RC STATE SECS
SEL=()
while IFS=$'\t' read -r id shape kind argv needs _reason; do
  if [ -n "$ONLY" ]; then case ",$ONLY," in *",$id,"*) ;; *) continue ;; esac; fi
  case ",$SKIP," in *",$id,"*) continue ;; esac
  SEL+=("$id"); SHAPE[$id]=$shape; KIND[$id]=$kind; ARGV[$id]=$argv; NEEDS[$id]=$needs
done < <(rp_catalog)
[ "${#SEL[@]}" -gt 0 ] || die2 "--only/--skip leave nothing to run"

# ── knobs: a settings row, else env, else the registry default ─────────────
# Same resolution as bin/test-impact-gate.sh: the live harness's lane-gate.sh
# first, then this checkout's; an answer that is not a whole number >= 1 is
# ignored. The entry point owns the root default (BH-2613 rule 4).
H="${HARNESS:-${H:-/root/harness}}"
for _lg in "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" "$HERE/lib/lane-gate.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_lg" ] && . "$_lg" 2>/dev/null && break
done
rp_knob() { # rp_knob <ENV> <fallback>
  local v=""
  command -v lane_knob >/dev/null 2>&1 && v=$(lane_knob fly-pool "$1" "${PROJECT:-}" 2>/dev/null)
  [ -n "$v" ] || v="${!1:-}"
  case "$v" in ''|*[!0-9]*) v="$2" ;; esac
  [ "$((10#$v))" -ge 1 ] || v="$2"
  printf '%s' "$((10#$v))"
}
BUDGET=$(rp_knob RULES_PACK_BUDGET_S 60)
[ -n "$JOBS" ] || JOBS=$(rp_knob RULES_PACK_JOBS 4)
HAVE_WAITN=1
if ! (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) )); then
  echo "rules-pack: bash < 4.3, running serially" >&2
  JOBS=1 HAVE_WAITN=0
fi
TO=$((2 * BUDGET))
T0=$(date +%s)

# ── the fork ───────────────────────────────────────────────────────────────
HEAD_SHA=$(git -C "$TREE" rev-parse --verify -q 'HEAD^{commit}') || die2 "no commit at HEAD in $TREE"
git -C "$TREE" rev-parse --verify -q "$BASE^{commit}" >/dev/null \
  || die2 "base '$BASE' does not resolve to a commit in $TREE"
FORK=$(git -C "$TREE" merge-base "$BASE" HEAD 2>/dev/null) \
  || die2 "base '$BASE' shares no history with HEAD in $TREE"

W=$(mktemp -d "${TMPDIR:-/tmp}/rules-pack.XXXXXX") || { echo "rules-pack: cannot make a work dir" >&2; exit 125; }
SW=""  # the isolated snapshot's own dir, when it cannot live in $W
trap 'rm -rf "$W" ${SW:+"$SW"}' EXIT
mkdir -p "$W/run"
[ -n "$OUT" ] || OUT="$W/out"
mkdir -p "$OUT" || die2 "--out $OUT cannot be created"

# ── the runner ─────────────────────────────────────────────────────────────
HROOT="${HARNESS_ROOT_OVERRIDE:-/root/harness}"
if [ "$RUNNER" = auto ]; then
  if [ "$(id -u)" -eq 0 ] && [ -d "$HROOT" ]; then RUNNER=isolated; else RUNNER=local; fi
fi
ALL_CNR="" RUN_DIR=$TREE SUBST=$FORK
BASE_DIR=""
if [ "$RUNNER" = isolated ]; then
  # shellcheck source=bin/lib/rules-pack-snapshot.sh
  if ! . "$ROOT/bin/lib/rules-pack-snapshot.sh"; then ALL_CNR="cannot load the snapshot lib"
  elif ! rp_snapshot_probe; then ALL_CNR="the snapshot probe failed"
  else
    # The snapshot runs as nobody, who must reach it by its absolute path. A
    # TMPDIR under a root-only parent (a review pool worker's
    # /root/harness/tmp/<queue>.pool/tmp.<id>, BH-5284) is not reachable:
    # build it under RULES_PACK_SNAPSHOT_TMP (default /tmp) instead, and when
    # that is not reachable either, nothing can run (never a red).
    chmod 711 "$W"; SD=$W
    if ! rp_snapshot_reachable "$SD"; then
      SP="${RULES_PACK_SNAPSHOT_TMP:-/tmp}"
      echo "rules-pack: snapshot: $W is not reachable by nobody; building the snapshot under $SP" >&2
      if SW=$(mktemp -d "$SP/rules-pack-snap.XXXXXX" 2>/dev/null) && chmod 711 "$SW" && rp_snapshot_reachable "$SW"; then
        SD=$SW
      else SD=""; ALL_CNR="no snapshot dir reachable by nobody (tried $W and $SP)"; fi
    fi
    if [ -z "$SD" ]; then :
    elif ! SB=$(rp_snapshot_build "$TREE" "$FORK" "$HEAD_SHA" "$SD"); then ALL_CNR="the snapshot build failed"
    # The base every component gets must resolve where they run, as nobody.
    elif ! rp_snapshot_run "$SD/repo" git rev-parse -q --verify "$SB^{commit}" >/dev/null 2>&1; then
      ALL_CNR="the snapshot base $SB does not resolve as nobody in $SD/repo"
    else RUN_DIR="$SD/repo" BASE_DIR="$SD/base" SUBST=$SB; fi
  fi
else
  RUN_DIR=$TREE SUBST=$FORK
  [ -z "$(git -C "$TREE" status --porcelain --untracked-files=no 2>/dev/null)" ] \
    || echo "rules-pack: warning: $TREE has uncommitted tracked changes; local mode judges the tree as it stands" >&2
fi
export RATCHET_BASE="${SUBST:-$FORK}" TI_BASE="${SUBST:-$FORK}"

# ── what cannot run, decided once ──────────────────────────────────────────
for id in "${SEL[@]}"; do
  if [ -n "$ALL_CNR" ]; then CNR_WHY[$id]=$ALL_CNR; continue; fi
  if [ "${NEEDS[$id]}" != - ]; then
    for b in ${NEEDS[$id]//,/ }; do
      command -v "$b" >/dev/null 2>&1 || { CNR_WHY[$id]="needs $b"; break; }
    done
  fi
  # BH-5793: a suite the PR head does not carry (main added it after the PR
  # branched) is the runner's environment, not a finding about the PR.
  if [ -z "${CNR_WHY[$id]:-}" ] && [ "${KIND[$id]}" = suite ]; then
    read -ra _sv <<< "${ARGV[$id]}"
    [ -n "${_sv[0]:-}" ] && [ ! -f "$RUN_DIR/${_sv[0]}" ] && CNR_WHY[$id]="suite missing at the PR head: ${_sv[0]}"
  fi
  if [ -z "${CNR_WHY[$id]:-}" ] && [ "${KIND[$id]}" = suite ] && [ "$RUNNER" = local ] \
     && [ "$(id -u)" -eq 0 ] && [ -d "$HROOT" ] && [ "${HARNESS_TEST_SANDBOX:-}" != 1 ]; then
    CNR_WHY[$id]="local runner as root beside $HROOT needs HARNESS_TEST_SANDBOX=1"
  fi
done

# rp_lanes_render <dir> — route-fragments reads the git-ignored
# catalog/lanes.json, which a snapshot or an archive never carries, and the
# catalog/llm-sites.json composed from catalog/llm-sites.d/ (BH-4987), and the
# catalog/context-budgets.json composed from catalog/context-budgets.d/
# (BH-6487). A tree with no .d/ directory still commits that file and needs no
# compose. All three renders run THIS checkout's trusted script against <dir>, never <dir>'s own
# copy: <dir> is the judged PR head, and this runs as root outside the nobody
# sandbox.
rp_lanes_render() {
  if [ -d "$1/catalog/llm-sites.d" ] && [ ! -e "$1/catalog/llm-sites.json" ]; then
    [ -x "$ROOT/bin/llm-sites-build.sh" ] || return 1
    "$ROOT/bin/llm-sites-build.sh" --repo "$1" --compose >>"$W/lanes-render.log" 2>&1 || return 1
  fi
  if [ -d "$1/catalog/context-budgets.d" ] && [ ! -e "$1/catalog/context-budgets.json" ]; then
    [ -x "$ROOT/bin/context-budgets-build.sh" ] || return 1
    "$ROOT/bin/context-budgets-build.sh" --repo "$1" --compose >>"$W/lanes-render.log" 2>&1 || return 1
  fi
  [ -e "$1/catalog/lanes.json" ] && return 0
  [ -x "$ROOT/bin/lanes-build.sh" ] || return 1
  "$ROOT/bin/lanes-build.sh" --root "$1" --write >>"$W/lanes-render.log" 2>&1
}
case " ${SEL[*]} " in *" route-fragments "*)
  if [ -z "${CNR_WHY[route-fragments]:-}" ] && ! rp_lanes_render "$RUN_DIR"; then
    CNR_WHY[route-fragments]="bin/lanes-build.sh could not render catalog/lanes.json, bin/llm-sites-build.sh could not compose catalog/llm-sites.json, or bin/context-budgets-build.sh could not compose catalog/context-budgets.json"
  fi ;;
esac
for id in "${SEL[@]}"; do
  [ -n "${CNR_WHY[$id]:-}" ] && echo "rules-pack: could-not-run: $id: ${CNR_WHY[$id]}" >&2
done

# rp_run_one <id> <dir> <tag> — one component in <dir>; writes
# $W/run/<id>.<tag>.{out,err,rc,secs}. Builtins run as this user against --tree
# (or the base tree), with the tree's own fork.
rp_run_one() {
  local id="$1" dir="$2" tag="$3" f="$W/run/$1.$3" s0=$SECONDS rc bt argv
  local -a av
  argv=${ARGV[$id]//<fork>/$SUBST}
  {
    if [ -n "${CNR_WHY[$id]:-}" ]; then rc=125
    else
      case "${KIND[$id]}" in
        suite)
          read -ra av <<< "$argv"
          if [ "$RUNNER" = isolated ]; then rp_snapshot_run "$dir" timeout "$TO" bash "${av[@]}"
          else (cd "$dir" && exec timeout "$TO" bash "${av[@]}"); fi ;;
        cmd)
          if [ "$RUNNER" = isolated ]; then rp_snapshot_run "$dir" timeout "$TO" bash -c "$argv"
          else (cd "$dir" && exec timeout "$TO" bash -c "$argv"); fi ;;
        builtin)
          bt=$TREE; [ "$tag" = base ] && bt=$dir
          (cd "$bt" && exec timeout "$TO" bash -c '. "$1" || exit 125; shift; "$@"' _ \
             "$ROOT/bin/lib/rules-pack-checks.sh" "$argv" "$bt" "$FORK") ;;
      esac
      rc=$?
    fi
  } >"$f.out" 2>"$f.err"
  echo "$rc" > "$f.rc"
  echo "$((SECONDS - s0))" > "$f.secs"
}

# rp_state <kind> <rc> — green | red | could-not-run
rp_state() {
  case "$1:$2" in
    *:0) echo green ;;
    *:124|*:125) echo could-not-run ;;
    suite:*|cmd:1|builtin:1) echo red ;;
    *) echo could-not-run ;;
  esac
}

# rp_parallel <tag> <dir> <id...> — at most JOBS at once
rp_parallel() {
  local tag="$1" dir="$2" id n=0
  shift 2
  for id in "$@"; do
    if [ "$n" -ge "$JOBS" ]; then
      if [ "$HAVE_WAITN" = 1 ]; then wait -n; else wait; fi
      n=$((n - 1))
    fi
    rp_run_one "$id" "$dir" "$tag" &
    n=$((n + 1))
  done
  wait
}

# The finding lines of a suite: a FAIL/not ok/bad/✗/RED line, plus up to two
# continuation lines (lib-root and alert-writers name the file on the next
# line), stopping at a blank, a summary, passing chatter or a header.
EXTRACT_AWK='
function hit(s) { return s ~ /(^|[^a-z])(FAIL|not ok|bad)[: ]/ || s ~ /^✗/ || s ~ /^# fail [1-9]/ || s ~ /^RED: / }
function stop(s) { return s ~ /^[[:space:]]*$/ || s ~ /[0-9]+ pass(ed)?, [0-9]+ fail(ed)?/ || s ~ /(^|[^A-Za-z])ok([^A-Za-z]|$)/ || s ~ /as expected/ || s ~ /^(---|===|##) / }
hit($0) { print; c = 2; next }
c > 0 { if (stop($0)) c = 0; else { print; c-- } }'

# rp_extract <id> <tag> — the finding lines, prefixed `<id>: `, at most 20
rp_extract() {
  local id="$1" f="$W/run/$1.$2" lines
  case "$id:${KIND[$id]}" in
    determinism:*) lines=$(cat "$f.out" "$f.err" | awk '/^── determinism findings \(fail\)/{f=1;next} /^──/{f=0} f && /^[^[:space:]][^:]*:[0-9]+: [^:]+:/') ;;
    test-sources:*|date-bomb:*|tier-wording:*|agent-call-no-tools:*|*:builtin) lines=$(grep . "$f.out") ;;
    checks-tree:*) lines=$(cat "$f.out" "$f.err" | grep '^CHECK-HIT ') ;;
    *) lines=$(cat "$f.out" "$f.err" | awk "$EXTRACT_AWK") ;;
  esac
  [ -n "$lines" ] || lines=$(cat "$f.out" "$f.err" | tail -n 10)
  printf '%s\n' "$lines" | awk -v p="$id: " 'NF && n < 20 { gsub(/\033\[[0-9;]*m/, ""); gsub(/\t/, " "); print p $0; n++ }'
}

# ── run HEAD ───────────────────────────────────────────────────────────────
rp_parallel head "$RUN_DIR" "${SEL[@]}"
REBASE=()
for id in "${SEL[@]}"; do
  RC[$id]=$(cat "$W/run/$id.head.rc")
  SECS[$id]=$(cat "$W/run/$id.head.secs")
  STATE[$id]=$(rp_state "${KIND[$id]}" "${RC[$id]}")
  [ "${STATE[$id]}" = red ] && [ "${SHAPE[$id]}" = tree ] && REBASE+=("$id")
done

# ── re-run red tree components on the fork ─────────────────────────────────
if [ "${#REBASE[@]}" -gt 0 ] && [ -z "$BASE_DIR" ]; then
  BASE_DIR="$W/base"
  mkdir -p "$BASE_DIR" \
    && git -C "$TREE" archive "$FORK" | tar -x -C "$BASE_DIR" \
    && git -C "$BASE_DIR" init -q \
    && git -C "$BASE_DIR" add -A \
    && git -C "$BASE_DIR" -c user.name=rules-pack -c user.email=rules-pack@localhost \
         -c commit.gpgsign=false commit -qm "rules-pack base $FORK" \
    || { echo "rules-pack: cannot build the base tree; red tree components stay findings" >&2; REBASE=(); }
fi
if [ "${#REBASE[@]}" -gt 0 ]; then
  case " ${REBASE[*]} " in *" route-fragments "*) rp_lanes_render "$BASE_DIR" ;; esac
  rp_parallel base "$BASE_DIR" "${REBASE[@]}"
  for id in "${REBASE[@]}"; do
    [ "$(rp_state "${KIND[$id]}" "$(cat "$W/run/$id.base.rc")")" = red ] && STATE[$id]=pre-existing
  done
fi

# ── outputs ────────────────────────────────────────────────────────────────
: > "$OUT/findings.txt"; : > "$OUT/preexisting.txt"; : > "$OUT/suites.txt"
NF=0 NP=0 CNR=() COMP=""
for id in "${SEL[@]}"; do
  f="$W/run/$id"
  { cat "$f.head.out" "$f.head.err"
    [ -e "$f.base.rc" ] && { echo "== base re-run =="; cat "$f.base.out" "$f.base.err"; }
  } > "$OUT/$id.log"
  case "${STATE[$id]}" in
    red) rp_extract "$id" head >> "$OUT/findings.txt" ;;
    pre-existing) rp_extract "$id" head >> "$OUT/preexisting.txt" ;;
    could-not-run) CNR+=("$id") ;;
  esac
  [ "${KIND[$id]}" = suite ] && [ "${STATE[$id]}" != could-not-run ] && echo "${ARGV[$id]}" >> "$OUT/suites.txt"
  COMP+="${COMP:+,}{\"id\":\"$id\",\"shape\":\"${SHAPE[$id]}\",\"rc\":${RC[$id]},\"state\":\"${STATE[$id]}\",\"seconds\":${SECS[$id]}}"
done
NF=$(grep -c . "$OUT/findings.txt")
NP=$(grep -c . "$OUT/preexisting.txt")
sed 's/^/rules-pack: pre-existing: /' "$OUT/preexisting.txt" >&2
cat "$OUT/findings.txt"

if [ "$NF" -gt 0 ]; then ST=red RCX=1
elif [ "${#CNR[@]}" -eq "${#SEL[@]}" ]; then ST=could-not-run RCX=125
else ST=clean RCX=0; fi
T1=$(date +%s)
EL=$((T1 - T0))
OVER=false
if [ "$EL" -gt "$BUDGET" ]; then OVER=true; echo "rules-pack: over budget (${EL}s > ${BUDGET}s)" >&2; fi
CJ=""
for id in "${CNR[@]}"; do CJ+="${CJ:+,}\"$id\""; done
printf '{"state":"%s","budget_s":%s,"elapsed_s":%s,"over_budget":%s,"components":[%s],"could_not_run":[%s],"base":"%s","head":"%s"}\n' \
  "$ST" "$BUDGET" "$EL" "$OVER" "$COMP" "$CJ" "$FORK" "$HEAD_SHA" > "$OUT/summary.json"
CNRS="${CNR[*]:-}"; CNRS=${CNRS// /,}
echo "rules-pack: $ST: $NF finding(s), $NP pre-existing, could-not-run: ${CNRS:--}, ${EL}s of ${BUDGET}s" >&2
exit "$RCX"
