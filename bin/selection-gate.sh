#!/bin/bash
# bin/selection-gate.sh --tree <dir> --base <ref> --out <dir> [--timeout S] [-P n]
# bin/selection-gate.sh --classify <run file> <suite>   (red|green|unknown, BH-9094)
# — the merge-queue batch's selection for ONE head, run on the fleet test host
# before the PR opens (BH-8062, shape B).
#
# WHY. The conductor no longer dispatches prequeue-gate.yml on the CI runners
# for a READY PR (row lane.merge-conductor.mc_prequeue_gate = 0). The builder
# asks the same question earlier and on a fixed-cost machine: would the batch
# that tests this change go red? The answer is the batch's own selection, not
# the builder gate's capped one: no TEST_IMPACT_GATE_CAP, no time budget below
# the corpus. The gate predicts the batch, or it says it cannot.
#
# STEPS.
#   1  mb = git merge-base HEAD <base> in <tree>. None: could-not-run
#      why=no-merge-base.
#   2  bin/ci-plan.sh in its batch mode over <mb>..HEAD: CI_EVENT=pull_request,
#      TI_PR_HEAD_REF=mergify/merge-queue/selection-gate, TI_BASE=<mb>,
#      CI_PLAN_ESCALATION=- and CI_PLAN_OWN_BASE=- (no PR exists yet, so no
#      member label or draft body is read), with the ci-plan-settings lane rows
#      applied when lane-gate.sh loads. rc != 0: could-not-run why=plan-rc-<n>.
#      An empty list: rc no-selection (never green).
#   3  <runner> <tree> <every listed suite> under `timeout <S>`, with
#      REMOTE_GATE_P=<n>; output in <out>/run.txt. The rc is read unpiped.
#      With SELECTION_GATE_BASELINE_RUN=1 (BH-9061) the base run's time is
#      reserved out of <S>: the main run gets S - SELECTION_GATE_BASELINE_TIMEOUT_S
#      - SELECTION_GATE_BASELINE_RESERVE_PAD_S, never under
#      SELECTION_GATE_MAIN_TIMEOUT_MIN_S and never over S. Step 4's timeout
#      verdict uses that bound.
#   4  0 green. 1-124: red, named by the `FAIL tests/<x>.sh (rc <n>)` lines of
#      run.txt only. 125, any other rc or the timeout: could-not-run with the
#      reason (remote-gate's bad-arguments 2 prints no FAIL line). A RUNNER-FAILURE line, or a red rc with no FAIL line, is
#      could-not-run (why=runner-failure / red-without-names): nothing parks
#      unnamed, and a suite the host could not run is not a red suite.
#      A runner-rc-<n> or red-without-names why also carries the runner's own
#      reason, `<token>: <one remote-gate: line of run.txt>` (_sg_reason).
#   5  A red suite on the active flaky quarantine (the rows bin/flaky-tier.sh
#      projects into CI_QUARANTINE, which the batch drops) moves from red: to
#      noted:. None left: rc 0. The list is CI_QUARANTINE when set (`-` = none),
#      else metric_flake_quarantine_list $REPO_SLUG through bin/jobs-client.sh.
#      No REPO_SLUG, or a failed read, is unreadable:
#      every red counts, and gate.txt says `quarantine: unreadable`.
#      A red suite a host note names (catalog/selection-gate-host-notes.d/*.tsv,
#      BH-8725) also moves to noted: when every failure line of its run.txt
#      section matches the row's ERE; gate.txt's host-noted: names it and its
#      class. A 125 with a `remote-gate: compose-<name> failed` line is
#      could-not-run why=`compose-<name>: <that line>`.
#   6  BH-8901, with SELECTION_GATE_BASELINE_RUN=1: each suite still red, and not
#      a file this diff changes, runs once on <mb> (the same runner, a detached
#      worktree of <mb>, under `timeout SELECTION_GATE_BASELINE_TIMEOUT_S`;
#      output in <out>/baseline-run.txt). A `FAIL <s> (rc N)` there, N not 127,
#      moves <s> from red: to baseline-red:. Any other answer (PASS, rc 127,
#      BLIND, no line) keeps it red, and a base run that could not run (rc 124
#      or more, the timeout, a RUNNER-FAILURE line, no worktree) keeps every
#      red and is named in baseline:. None left: rc 0. A clean red or green is
#      cached in $H/state/selection-gate/baseline/<mb>/<suite, / as _>; dirs
#      older than SELECTION_GATE_BASELINE_KEEP_DAYS days are deleted first.
#      BH-9094: a row `<mb> TAB <suite> TAB red|green` of
#      $H/state/selection-gate/prime.tsv (bin/selection-gate-prime.sh writes it
#      on the hub, bin/fly-pool.sh relays it to the pool machines) is a cached
#      answer too. The per-file cache wins when both have a value.
#
# OUTPUT. <out>/gate.txt, written once (tmp + mv):
#   head: <40-hex>  base: <mb|->  suites: <n>  rc: <0|1|could-not-run|no-selection>
#   red: <comma list|->  noted: <comma list|->  mode: <ci-plan mode|->
#   why: <token|token: reason|->  quarantine: <read|unreadable|env>
#   host-noted: <suite>=<class>,…|->
#   and, only with SELECTION_GATE_BASELINE_RUN=1 (else the file is these 10 lines):
#   baseline-red: <comma list|->
#   baseline: <-|skipped: head-is-base|ran <n> on <mb12> (<c> cached)|could-not-run: <why>>
#   (<c> counts per-file cache hits and prime.tsv hits, BH-9094)
# plus <out>/selection.txt (the list) and <out>/run.txt (the runner's output).
#
# EXIT. 0 green, 1 red, 3 could-not-run, 4 no-selection, 2 bad arguments.
#
# KNOBS. --timeout and -P are the fly-pool lane knobs SELECTION_GATE_TIMEOUT_S
# and SELECTION_GATE_P; bin/lib/selection-gate.sh reads them and passes them in,
# and SELECTION_GATE_WHY_MAX (the reason's length cap), the three
# SELECTION_GATE_BASELINE* rows (step 6) and, BH-9061, the two rows of the
# main-run reserve (step 3: SELECTION_GATE_BASELINE_RESERVE_PAD_S,
# SELECTION_GATE_MAIN_TIMEOUT_MIN_S) in the env.
# The fallbacks below name their rows. Test seams: SELECTION_GATE_PLAN (the
# planner, default <tree>/bin/ci-plan.sh) and SELECTION_GATE_RUNNER (default
# <tree>/bin/remote-gate.sh).
set -uo pipefail

TREE=""; BASE=""; OUT=""
# lane.fly-pool.selection_gate_timeout_s (catalog/lanes.d/fly-pool.knobs.d/SELECTION_GATE_TIMEOUT_S.json)
TO=2400
# lane.fly-pool.selection_gate_p (catalog/lanes.d/fly-pool.knobs.d/SELECTION_GATE_P.json)
PAR=12
usage() { sed -n '2,4p' "$0" >&2; exit 2; }
# bl_class <run file> <suite> — red, green or unknown. red: a `FAIL <suite>
# (rc N)` line with N not 127 (127 is a suite the base does not have) and no
# other line for it. green: a `PASS <suite>` line and no other. Anything else
# (BLIND, no line, a near-miss name, both) is unknown.
bl_class() {
  awk -v s="$2" '
    $0 == "PASS " s { p = 1; next }
    index($0, "FAIL " s " (rc ") == 1 {
      r = substr($0, length("FAIL " s " (rc ") + 1)
      if (r ~ /^[0-9]+\)$/ && r != "127)") f = 1; else o = 1
      next }
    index($0, " " s) && $0 ~ /^(BLIND|RUNNER-FAILURE) / { o = 1 }
    END { if (f && !p && !o) print "red"; else if (p && !f && !o) print "green"; else print "unknown" }' "$1" 2>/dev/null
}
# --classify <run file> <suite> (BH-9094): prints bl_class for one suite and
# exits 0. bin/selection-gate-prime.sh classifies its prime run through this
# mode, so a primed red means what a base-run red means.
if [ "${1:-}" = --classify ]; then
  [ $# -eq 3 ] || { echo "selection-gate: --classify <run file> <suite>" >&2; exit 2; }
  bl_class "$2" "$3"; exit 0
fi
while [ $# -gt 0 ]; do
  case "$1" in
    --tree)    [ $# -ge 2 ] || usage; TREE="$2"; shift ;;
    --base)    [ $# -ge 2 ] || usage; BASE="$2"; shift ;;
    --out)     [ $# -ge 2 ] || usage; OUT="$2"; shift ;;
    --timeout) [ $# -ge 2 ] || usage; TO="$2"; shift ;;
    -P)        [ $# -ge 2 ] || usage; PAR="$2"; shift ;;
    -h|--help) sed -n '2,84p' "$0"; exit 0 ;;
    *) echo "selection-gate: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$TREE" ] && [ -d "$TREE" ] && [ -n "$BASE" ] && [ -n "$OUT" ] || usage
[[ "$TO" =~ ^[1-9][0-9]*$ ]] || { echo "selection-gate: --timeout '$TO' is not a positive integer" >&2; exit 2; }
[[ "$PAR" =~ ^[1-9][0-9]*$ ]] || { echo "selection-gate: -P '$PAR' is not a positive integer" >&2; exit 2; }
TREE=$(cd "$TREE" && pwd)
mkdir -p "$OUT" || { echo "selection-gate: cannot create $OUT" >&2; exit 2; }
PLAN="${SELECTION_GATE_PLAN:-$TREE/bin/ci-plan.sh}"
RUNNER="${SELECTION_GATE_RUNNER:-$TREE/bin/remote-gate.sh}"
H="${HARNESS:-${H:-/root/harness}}"

# lane.fly-pool.selection_gate_baseline_run (catalog/lanes.d/fly-pool.knobs.d/SELECTION_GATE_BASELINE_RUN.json).
# Unset is 0: the script alone stays the BH-8062 gate; bin/lib/selection-gate.sh passes the row.
BL="${SELECTION_GATE_BASELINE_RUN:-0}"; [ "$BL" = 1 ] || BL=0
# lane.fly-pool.selection_gate_baseline_timeout_s (catalog/lanes.d/fly-pool.knobs.d/SELECTION_GATE_BASELINE_TIMEOUT_S.json)
BTO="${SELECTION_GATE_BASELINE_TIMEOUT_S:-900}"; [[ "$BTO" =~ ^[1-9][0-9]*$ ]] || BTO=900
# lane.fly-pool.selection_gate_baseline_keep_days (catalog/lanes.d/fly-pool.knobs.d/SELECTION_GATE_BASELINE_KEEP_DAYS.json)
BKEEP="${SELECTION_GATE_BASELINE_KEEP_DAYS:-2}"; [[ "$BKEEP" =~ ^[1-9][0-9]*$ ]] || BKEEP=2
# lane.fly-pool.selection_gate_baseline_reserve_pad_s (catalog/lanes.d/fly-pool.knobs.d/SELECTION_GATE_BASELINE_RESERVE_PAD_S.json)
BPAD="${SELECTION_GATE_BASELINE_RESERVE_PAD_S:-60}"; [[ "$BPAD" =~ ^(0|[1-9][0-9]*)$ ]] || BPAD=60
# lane.fly-pool.selection_gate_main_timeout_min_s (catalog/lanes.d/fly-pool.knobs.d/SELECTION_GATE_MAIN_TIMEOUT_MIN_S.json)
MMIN="${SELECTION_GATE_MAIN_TIMEOUT_MIN_S:-300}"; [[ "$MMIN" =~ ^[1-9][0-9]*$ ]] || MMIN=300
# MTO — the main run's bound (step 3, BH-9061): with the base run on, its time
# is reserved out of the gate's wall, so the base run is not cut off.
MTO=$TO
if [ "$BL" = 1 ]; then
  MTO=$((TO - BTO - BPAD))
  [ "$MTO" -ge "$MMIN" ] || MTO=$MMIN
  [ "$MTO" -le "$TO" ] || MTO=$TO
fi

HEAD_SHA=$(git -C "$TREE" rev-parse HEAD 2>/dev/null) || HEAD_SHA=""
MB="-"; N=0; RC=""; RED="-"; NOTED="-"; MODE="-"; WHY="-"; QSRC="-"; HNOTED="-"; BRED="-"; BSTAT="-"

# write_gate — gate.txt in one rename, then the exit code for RC.
write_gate() {
  local t="$OUT/gate.txt.tmp.$$"
  printf 'head: %s\nbase: %s\nsuites: %s\nrc: %s\nred: %s\nnoted: %s\nmode: %s\nwhy: %s\nquarantine: %s\nhost-noted: %s\n' \
    "${HEAD_SHA:--}" "$MB" "$N" "$RC" "$RED" "$NOTED" "$MODE" "$WHY" "$QSRC" "$HNOTED" > "$t" \
    && { [ "$BL" = 0 ] || printf 'baseline-red: %s\nbaseline: %s\n' "$BRED" "$BSTAT" >> "$t"; } \
    && mv -f "$t" "$OUT/gate.txt" || { rm -f "$t"; echo "selection-gate: cannot write $OUT/gate.txt" >&2; exit 3; }
  local b=""; [ "$BL" = 0 ] || b=" baseline-red=$BRED"
  echo "selection-gate: rc=$RC suites=$N red=$RED noted=$NOTED mode=$MODE why=$WHY$b"
  case "$RC" in 0) exit 0 ;; 1) exit 1 ;; no-selection) exit 4 ;; *) exit 3 ;; esac
}
cnr() { RC=could-not-run; WHY="$1"; write_gate; }

# lane.fly-pool.selection_gate_why_max (catalog/lanes.d/fly-pool.knobs.d/SELECTION_GATE_WHY_MAX.json)
WHY_MAX="${SELECTION_GATE_WHY_MAX:-160}"
[[ "$WHY_MAX" =~ ^[1-9][0-9]*$ ]] || WHY_MAX=160

# _sg_reason <run.txt> <max> — the runner's own reason, one line: the first
# `remote-gate: pool test-host route incomplete:` line (it names every part of
# the route), else the LAST line that starts `remote-gate:` and is not the
# host-resources dump (die_infra and die2 exit right after their one line;
# earlier lines are notes). Control characters
# go; a line that holds a Fly token becomes `<token line dropped>`; the result
# is cut to <max> characters. No such line: nothing.
_sg_reason() {
  local l
  l=$(grep -m 1 '^remote-gate: pool test-host route incomplete:' "$1" 2>/dev/null)
  # `remote-gate:   ` (three spaces) is rg_host_resources' memory and disk
  # dump, printed AFTER the reason on a runner failure: never the reason.
  [ -n "$l" ] || l=$(grep '^remote-gate:' "$1" 2>/dev/null | grep -v '^remote-gate:   ' | tail -n 1)
  [ -n "$l" ] || return 0
  _sg_scrub "$l" "$2"
}
# _sg_scrub <line> <max> — the line with control characters gone, a Fly token
# line replaced by `<token line dropped>`, cut to <max> characters.
_sg_scrub() {
  local l
  l=$(printf '%s' "$1" | tr -d '\000-\037\177')
  case "$l" in *FlyV1*|*fm2_*) l='<token line dropped>' ;; esac
  printf '%s' "${l:0:$2}"
}
# cnr_why <token> — could-not-run with the runner's reason after the token.
cnr_why() {
  local r; r=$(_sg_reason "$OUT/run.txt" "$WHY_MAX")
  cnr "$1${r:+: $r}"
}

# ── host notes (BH-8725) ─────────────────────────────────────────────────────
# A suite that is red on the test host for a reason the host has and CI does
# not (a shallow git context, a wall-clock bound on a shared host) is named in
# $TREE/catalog/selection-gate-host-notes.d/*.tsv, one file per ticket:
#   <suite path> TAB <class> TAB <ERE> TAB <reason sentence>
# The class is a closed set (HOST_NOTE_CLASSES). A row with another class,
# fewer than 4 fields or an ERE grep -E rejects is skipped with one stderr line,
# so that suite stays red (fail closed). The notes are the gate's own: the
# merge-queue batch still runs and gates those suites; the flaky quarantine and
# CI_QUARANTINE are not touched.
HOST_NOTE_CLASSES="shallow-context host-timing"
HN_SUITE=(); HN_CLASS=(); HN_ERE=()
host_notes_load() {
  local f ln line su cl re rest erc files
  HN_SUITE=(); HN_CLASS=(); HN_ERE=()
  mapfile -t files < <(printf '%s\n' "$TREE"/catalog/selection-gate-host-notes.d/*.tsv | LC_ALL=C sort)
  for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    [ -r "$f" ] || { echo "selection-gate: host-notes: skipped $f (unreadable)" >&2; continue; }
    ln=0
    while IFS= read -r line || [ -n "$line" ]; do
      ln=$((ln + 1))
      case "$line" in ''|'#'*) continue ;; esac
      IFS=$'\t' read -r su cl re rest <<<"$line"
      if [ -z "$su" ] || [ -z "$cl" ] || [ -z "$re" ] || [ -z "$rest" ]; then
        echo "selection-gate: host-notes: skipped $f:$ln (fewer than 4 tab-separated fields)" >&2; continue
      fi
      case " $HOST_NOTE_CLASSES " in *" $cl "*) ;; *)
        echo "selection-gate: host-notes: skipped $f:$ln (class '$cl' is not one of: $HOST_NOTE_CLASSES)" >&2; continue ;; esac
      erc=0; grep -qE -- "$re" </dev/null 2>/dev/null || erc=$?
      [ "$erc" = 2 ] && { echo "selection-gate: host-notes: skipped $f:$ln (grep -E rejects the ERE)" >&2; continue; }
      HN_SUITE+=("$su"); HN_CLASS+=("$cl"); HN_ERE+=("$re")
    done < "$f"
  done
}
# host_note <suite> — prints the class and rc 0 when a row names <suite>, its
# section of run.txt (from `===== <suite> (rc N) =====` to the next `=====`
# line or the `remote-gate: N suites` line) holds at least one failure line
# (`FAIL` at the start or after a space, then `:` or a space), and EVERY
# failure line there matches that row's ERE. Anything else: rc 1, still red.
host_note() {
  local i sec fl cnt
  for i in "${!HN_SUITE[@]}"; do
    [ "${HN_SUITE[$i]}" = "$1" ] || continue
    sec=$(awk -v h="===== $1 (rc " '
      on && (/^=====/ || /^remote-gate: [0-9]+ suites/) { exit }
      on { print }
      index($0, h) == 1 && $0 ~ /\) =====$/ { on = 1 }' "$OUT/run.txt" 2>/dev/null)
    fl=$(grep -E '(^|[[:space:]])FAIL[: ]' <<<"$sec")
    [ -n "$fl" ] || continue
    grep -vqE -- "${HN_ERE[$i]}" <<<"$fl" && continue
    # The section is a tail window (bin/remote-gate.sh RG_TAIL), so a real FAIL
    # above it must not hide behind a noted one inside it. When the suite prints
    # its own count (`<n> passed, <m> failed`, both shipped suites do), m must
    # equal the FAIL lines seen here; a larger m is a red the window cut off.
    cnt=$(grep -oE '[0-9]+ failed' <<<"$sec" | tail -n 1 | grep -oE '^[0-9]+' || true)
    if [ -n "$cnt" ] && [ "$cnt" != "$(grep -c . <<<"$fl")" ]; then continue; fi
    printf '%s' "${HN_CLASS[$i]}"; return 0
  done
  return 1
}

# ── the base run (BH-8901) ───────────────────────────────────────────────────
# A suite that is red on the merge base too is not this diff's red. With
# SELECTION_GATE_BASELINE_RUN=1, baseline_pass runs the reds left after step 5 once
# on MB, with the same runner, in a detached worktree of MB, and moves each
# suite that is red there from keep to BRED. Fail closed: anything but a clean
# red on the base keeps the suite red.
BL_TMP=""
# bl_cleanup — the base worktree and its temp dir go, on every exit.
bl_cleanup() {
  [ -n "$BL_TMP" ] || return 0
  git -C "$TREE" worktree remove --force "$BL_TMP/base" >/dev/null 2>&1
  git -C "$TREE" worktree prune >/dev/null 2>&1
  rm -rf "$BL_TMP"; BL_TMP=""
}
# baseline_pass — reads and rewrites keep; sets BRED and BSTAT. The result per
# (base sha, suite) is cached in $H/state/selection-gate/baseline/<MB>/<suite,
# / as _> (red or green only), and a dir older than SELECTION_GATE_BASELINE_KEEP_DAYS
# days is deleted first. A base run that could not run caches nothing.
baseline_pass() {
  local cdir="$H/state/selection-gate/baseline" s v k r tok changed brc=0 t0 bel hit=0
  local -a cand=() send=() bred=() still=()
  local -A got=() prime=()
  local ps pv
  if [ "$HEAD_SHA" = "$MB" ]; then BSTAT="skipped: head-is-base"; return 0; fi
  # A suite this diff edits is never sent: its red can be this diff's.
  changed=$(git -C "$TREE" diff --name-only "$MB" HEAD 2>/dev/null) || { BSTAT="could-not-run: no-diff"; return 0; }
  for s in "${keep[@]}"; do grep -qxF -- "$s" <<<"$changed" || cand+=("$s"); done
  find "$cdir" -mindepth 1 -maxdepth 1 -type d -mtime "+$BKEEP" -exec rm -rf {} + 2>/dev/null
  # BH-9094: the relayed prime, rows for MB with a red or green value only.
  while IFS=$'\t' read -r ps pv; do [ -n "$ps" ] && prime[$ps]=$pv; done < <(awk -F'\t' -v mb="$MB" \
    'NF == 3 && $1 == mb && ($3 == "red" || $3 == "green") { print $2 "\t" $3 }' \
    "$H/state/selection-gate/prime.tsv" 2>/dev/null)
  for s in "${cand[@]}"; do
    v=$(cat "$cdir/$MB/${s//\//_}" 2>/dev/null)
    case "$v" in red|green) ;; *) v="${prime[$s]:-}" ;; esac
    case "$v" in red|green) got[$s]=$v; hit=$((hit + 1)) ;; *) send+=("$s") ;; esac
  done
  if [ "${#send[@]}" -gt 0 ]; then
    BL_TMP=$(mktemp -d "${TMPDIR:-/tmp}/selection-gate-baseline.XXXXXX") || { BL_TMP=""; BSTAT="could-not-run: no-tmp"; return 0; }
    trap bl_cleanup EXIT
    if ! git -C "$TREE" worktree add -q --detach "$BL_TMP/base" "$MB" >/dev/null 2>&1; then
      bl_cleanup; BSTAT="could-not-run: no-worktree"; return 0
    fi
    t0=$SECONDS
    REMOTE_GATE_P="$PAR" timeout -k 30 "$BTO" "$RUNNER" "$BL_TMP/base" "${send[@]}" > "$OUT/baseline-run.txt" 2>&1 || brc=$?
    bel=$((SECONDS - t0))
    bl_cleanup
    tok=""
    if [ "$bel" -ge "$BTO" ]; then tok=timeout
    elif [ "$brc" -gt 123 ]; then
      r=$(_sg_reason "$OUT/baseline-run.txt" "$WHY_MAX"); tok="runner-rc-$brc${r:+: $r}"
    elif grep -q '^RUNNER-FAILURE ' "$OUT/baseline-run.txt" 2>/dev/null; then tok=runner-failure
    fi
    if [ -n "$tok" ]; then BSTAT="could-not-run: $tok"; return 0; fi
    mkdir -p "$cdir/$MB" 2>/dev/null
    for s in "${send[@]}"; do
      v=$(bl_class "$OUT/baseline-run.txt" "$s"); got[$s]=$v
      case "$v" in red|green)
        k="$cdir/$MB/${s//\//_}"
        printf '%s\n' "$v" > "$k.tmp.$$" 2>/dev/null && mv -f "$k.tmp.$$" "$k" 2>/dev/null || rm -f "$k.tmp.$$" ;;
      esac
    done
  fi
  [ -d "$cdir/$MB" ] && touch "$cdir/$MB" 2>/dev/null
  for s in "${keep[@]}"; do
    if [ "${got[$s]:-}" = red ]; then bred+=("$s"); else still+=("$s"); fi
  done
  [ "${#bred[@]}" -gt 0 ] && BRED=$(IFS=,; echo "${bred[*]}")
  BSTAT="ran ${#cand[@]} on ${MB:0:12} ($hit cached)"
  keep=("${still[@]}")
}

[[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] || { HEAD_SHA=""; cnr no-head; }
MB=$(git -C "$TREE" merge-base HEAD "$BASE" 2>/dev/null) || MB=""
[[ "$MB" =~ ^[0-9a-f]{40}$ ]] || { MB="-"; cnr no-merge-base; }

# ── 2. the batch's selection ─────────────────────────────────────────────────
: > "$OUT/selection.txt"; : > "$OUT/plan.out"; : > "$OUT/plan.github-output"
prc=0
(
  # The ci-plan-settings rows (CI_SHARD_BUDGET_S, CI_MAX_SHARDS, CI_FULL_TRIGGERS)
  # in this subshell only. No lane-gate.sh: ci-plan's own fallbacks.
  # shellcheck disable=SC1091
  [ -r "$H/bin/lib/lane-gate.sh" ] && . "$H/bin/lib/lane-gate.sh" >/dev/null 2>&1 \
    && command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply ci-plan-settings >/dev/null 2>&1
  unset GITHUB_ACTIONS GITHUB_STEP_SUMMARY CI_QUARANTINE CI_PLAN_REUSE CI_PLAN_REUSED_FILE
  cd "$TREE" && CI_EVENT=pull_request TI_PR_HEAD_REF=mergify/merge-queue/selection-gate TI_BASE="$MB" \
    CI_PLAN_ESCALATION=- CI_PLAN_OWN_BASE=- GITHUB_OUTPUT="$OUT/plan.github-output" \
    "$PLAN" --out "$OUT/selection.txt"
) > "$OUT/plan.out" 2>&1 || prc=$?
[ "$prc" = 0 ] || cnr "plan-rc-$prc"
MODE=$(sed -n 's/^mode=//p' "$OUT/plan.github-output" 2>/dev/null | tail -n 1); MODE="${MODE:--}"
mapfile -t SUITES < <(grep -v '^[[:space:]]*$' "$OUT/selection.txt" 2>/dev/null)
N=${#SUITES[@]}
[ "$N" -gt 0 ] || { RC=no-selection; WHY=empty-selection; write_gate; }

# ── 3. the run on the test host ──────────────────────────────────────────────
rrc=0; t0=$SECONDS
REMOTE_GATE_P="$PAR" timeout -k 30 "$MTO" "$RUNNER" "$TREE" "${SUITES[@]}" > "$OUT/run.txt" 2>&1 || rrc=$?
el=$((SECONDS - t0))

# ── 4. the verdict ───────────────────────────────────────────────────────────
case "$rrc" in
  0) RC=0 ;;
  # timeout's own 124 (137 after the -k kill) once the budget passed; a 124
  # inside it is 124 failing suites.
  124) if [ "$el" -ge "$MTO" ]; then cnr timeout; fi; RC=1 ;;
  137) if [ "$el" -ge "$MTO" ]; then cnr timeout; fi; cnr_why runner-rc-137 ;;
  # A failed host compose (bin/remote-gate.sh rg_compose_catalogs, BH-8725)
  # is could-not-run why=compose-<name>: the catalogs CI builds before the
  # suites could not be built, so nothing ran.
  125) l=$(grep -m 1 -E '^remote-gate: compose-[a-z0-9-]+ failed' "$OUT/run.txt" 2>/dev/null)
       if [ -n "$l" ]; then
         c=${l#remote-gate: compose-}; c=${c%% failed*}
         cnr "compose-$c: $(_sg_scrub "$l" "$WHY_MAX")"
       fi
       cnr_why runner-rc-125 ;;
  # 2 is also remote-gate's bad command line; that run prints no FAIL line, so
  # it ends red-without-names below.
  *) if [ "$rrc" -ge 1 ] && [ "$rrc" -le 123 ]; then RC=1; else cnr_why "runner-rc-$rrc"; fi ;;
esac
# A suite the host could not run is never a red suite, and never a pass.
grep -q '^RUNNER-FAILURE ' "$OUT/run.txt" 2>/dev/null && cnr runner-failure
if [ "$RC" = 1 ]; then
  mapfile -t REDS < <(sed -nE 's/^FAIL (tests\/[^ ]+\.sh) \(rc [0-9]+\)$/\1/p' "$OUT/run.txt" 2>/dev/null | sort -u)
  [ "${#REDS[@]}" -gt 0 ] || cnr_why red-without-names
  # ── 5. the flaky quarantine ──────────────────────────────────────────────
  Q=""
  if [ -n "${CI_QUARANTINE+set}" ]; then QSRC=env; Q="${CI_QUARANTINE}"
  else
    # shellcheck disable=SC1091
    if [ -n "${REPO_SLUG:-}" ] && [ -r "$H/bin/jobs-client.sh" ] && Q=$( . "$H/bin/jobs-client.sh" >/dev/null 2>&1 \
         && metric_flake_quarantine_list "$REPO_SLUG" 2>/dev/null ); then QSRC=read
    else QSRC=unreadable; Q=""; fi
  fi
  host_notes_load
  keep=(); note=(); hn=()
  for s in "${REDS[@]}"; do
    q=0; [ "$QSRC" != unreadable ] && grep -qxF -- "$s" <<<"$(tr ' ,' '\n\n' <<<"$Q")" && q=1
    if cls=$(host_note "$s"); then hn+=("$s=$cls"); q=1; fi
    if [ "$q" = 1 ]; then note+=("$s"); else keep+=("$s"); fi
  done
  [ "${#note[@]}" -gt 0 ] && NOTED=$(IFS=,; echo "${note[*]}")
  [ "${#hn[@]}" -gt 0 ] && HNOTED=$(IFS=,; echo "${hn[*]}")
  # ── 6. the base run (BH-8901) ────────────────────────────────────────────
  [ "$BL" = 1 ] && [ "${#keep[@]}" -gt 0 ] && baseline_pass
  if [ "${#keep[@]}" -gt 0 ]; then RED=$(IFS=,; echo "${keep[*]}"); else RC=0; fi
fi
write_gate
