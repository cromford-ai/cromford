#!/bin/bash
# tests/lanes-registry-test.sh — catalog/lanes.json is the whole truth about
# what this fleet runs automatically (BH-1132).
#
# WHY. The registry is only worth having if it CANNOT fall behind cron. A new
# cron line that nobody registers is automation with no off-switch and no line
# on the settings page — exactly the state BH-1132 exists to end — and it would
# never announce itself. This file is the thing that announces it.
#
# What is proved here:
#   1. the JSON parses and every id is unique;
#   2. EVERY script any cron/*.cron line invokes has a registered lane;
#   3. every registered lane's script exists on disk;
#   4. the boxes a lane claims are exactly the boxes whose cron runs it;
#   5. every lane marked wired=true really GATES — its own header block is
#      EXTRACTED FROM THE SHIPPED SCRIPT and EXECUTED against a scratch harness
#      holding flags/all-off, and it must exit 0 without reaching the body and
#      write the SKIPPED line. A grep for the text `lane_gate_or_exit <id>` is
#      NOT this test: PR #1136 shipped nine wirings that sourced `$${HARNESS}`
#      (`$$` is the PID), so every source failed silently behind
#      `2>/dev/null || true`, `command -v` failed, no lane was ever gated — and
#      a grep passed on all nine. The kill switch reported that it existed
#      while a burning lane kept spending. Only running it proves it runs;
#   6. no phantom knobs — every knob of a wired lane is really read by the file
#      that is supposed to read it;
#   7. no missing knobs — every operator-shaped env knob a wired script reads
#      and never assigns itself is in the registry. COMMENTS ARE STRIPPED
#      FIRST: `# KILL FLAG: POOL_AUTOSCALE=0 restores …` read as an assignment
#      and made this section skip that knob entirely. BH-1351: the scan set also
#      carries bin/wake-loop.sh's sourced class files (bin/lib/wake-class-*.sh),
#      because a knob one `source` away was invisible here for a release;
#   8. the knob schema: a knob names an env var or a resolver, and zero_means is
#      one of off | unlimited | null and nothing else;
#   9. every settings key the registry can build — `lane.<id>[.<project>].<env
#      lowercased>`, the published contract's form, with the project segment
#      only where the lane is project-scoped — is legal and fits 64 chars for
#      EVERY project in fleet.conf. PUT /api/settings validates
#      ^[a-z0-9_.-]{1,64}$, and a knob whose key overflows is a knob an operator
#      can never set: the 400 would arrive at the click, not here.
#  12. EVERY LANE THIS REPO OWNS IS WIRED (BH-1165). phase A gated nine of 78
#      and the other 69 were registered, visible on the page, and ungateable —
#      a switch drawn next to a lane that does not read it is worse than no
#      switch. A lane may be unwired only by DECLARING that its script lives in
#      another repo (`external: true` + a reason), and then the script must
#      really not be here.
#  13. NO SECRET IS A KNOB. Registering `MIGRATION_TOKEN` as a knob would print
#      a credential on a settings page and store it in a settings row. The
#      names that look like credentials are refused from the registry, and
#      section 7 does not demand them either.
#  14. `project_scoped: false` is only for a knob whose PROJECT key really
#      overflows the worker's 64-character limit — otherwise it is a way to
#      quietly make a per-project knob global.
#  16. lane_env_apply is called by every wired lane and sits BELOW the env load
#      (BH-1165 review) — above it, `set -a; . env/global.env` re-assigns the
#      knob the settings row just exported and the row silently loses.
#  17. no exec/host/path/identity/test-seam name is settable from a page: those
#      carry `settable: false`, which keeps them registered (section 7) and
#      refuses them at every write surface.
#  18. a knob `default` is a VALUE, never shell text a page would render as one.
#  15. a knob whose env name is BUILT at runtime (`LANE_USD_CAP_<LANE>`)
#      declares the `prefix` its reader contains, and that prefix is a real
#      prefix of the env name.
#  19. the gate runs BEFORE the lane's own work (BH-1165 review). Section 5
#      lifts the header OUT of the script and runs it, so it cannot see WHERE it
#      sits: bin/untriaged-sweep.sh had it after three of its four board sweeps,
#      so `all-off` still curled three clients' boards with their tokens and
#      then logged SKIPPED. This walks each wired script's top-level lines and
#      fails when anything that leaves this box precedes the gate.
#  20. THE SETTINGS CONTRACT (BH-1511.1). The `libs` scope (knobs a shared
#      bin/lib/*.sh reads, catalog/lanes.d/_lib.json) holds the same rules as a
#      lane's: its file exists, every knob is read by it, no secret, a default
#      is a value, every key fits. And a `required: true` knob — lane or lib —
#      has a static default and NO `${ENV:-literal}` read left in its file:
#      required is the promise that the contract, not the file, sets it, so a
#      missing default would fail the lane closed on the first worker outage and
#      a surviving literal would be a second default free to drift.
# Run from anywhere: tests/lanes-registry-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json and cron/<box>.cron are GENERATED and not
# committed. rendered_registry / rendered_cron render this repo's own into $T.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
REG=$(rendered_registry)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
# code_has <file> <grep args…> — does the file's uncommented code match?
# Never `grep -v … | grep -q` here: under pipefail a -q that exits on its first
# match leaves the upstream grep writing into a closed pipe, and on a runner
# that ignores SIGPIPE (GitHub's does) it exits 2 with "write error: Broken
# pipe", so a knob that IS read reads as a phantom (main red at f83ca87f,
# remote-gate/REMOTE_GATE_FREE_FACTOR). Nor `grep -c … >/dev/null`: GNU grep
# treats a /dev/null stdout as -q. Counting into a substitution drains the pipe.
code_has() {
  local f=$1 n; shift
  n=$(grep -v '^[[:space:]]*#' "$f" | grep -c "$@")
  [ "${n:-0}" -gt 0 ]
}
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# LANES_REGISTRY_SECTIONS=static (BH-8473) skips the slow sections that render
# cron, run lane headers or grep every script per knob: 2-5, 6, 12, 16 and 19.
# The ones that read the registry and the knob fragments still run: 1, 7-11,
# 13-15, 17, 18 and 20. Section 7 (no missing knobs, about 16 s) stays in: it
# is the check that caught batch #8344 (a wired script read MC_LOG and the
# registry did not carry it). The merge conductor's pre-queue fast lint set
# (catalog/prequeue-fast-lints.tsv) runs it inside a 90 s budget. Unset, or any
# other value, runs every section.
lr_section() {
  [ "${LANES_REGISTRY_SECTIONS:-}" = static ] || return 0
  case " 2 6 12 16 19 " in *" $1 "*) return 1 ;; esac
  return 0
}

# PLUMBING — names that are read with ${NAME:-default} but are not operator
# knobs: where the harness lives, what the shell hands down, and credentials.
# Each one is here because putting it on a settings page would be a lie (a
# settings row cannot move $HARNESS) or a hazard (a secret).
PLUMBING="HARNESS H HENV TMPDIR FLEET_CONF REPOS_ROOT GH_TOKEN HARNESS_SECRET
CONSOLE_URL FLY_BIN_DIR JOB_ID JOB_BEAT BASH_SOURCE POOL_APP BR_SSH MC_TICK_ID
MC_RR_PATH MC_FLAKE MC_FLAKE_RUNG MC_IDENTITY_BLOCKED MC_INQUEUE_STATES
MC_LIST_INQUEUE ACCOUNT_EXHAUST_REGEX LANE_REGISTRY LANE_GATE_NOW PAUSE_NOW DOORBELL_APP_HOOK MRG_FLAG
MC_REPOS MC_GIT_NAME MC_GIT_EMAIL GH_REST_STATUS GH_REST_REASON ISSUE_CLOSE_ERR
LANE_GATE_CACHE_S LANE_GATE_LOG_EVERY_S LANE_GATE_DISABLE CI_LOG_BYTES
LANE_PAUSED_WHY LANE_PAUSED_FLAG LANE_PAUSED_SOURCE LANE_GATE_CHECKED
CI_LOG_RUNS BR_ENQUEUE_WHY BR_ADJ_NOVERDICT_MAX BR_ENQUEUE_FAIL_MAX
BR_SATURATED_TICKS PREPLAN_RELAY_DIR DEFER_FAMS HELD_ALERTS"
# LANE_PAUSED_* and LANE_GATE_CHECKED are OUTPUTS of bin/lib/lane-gate.sh's
# lane_paused, read by the one lane that gates per project inside its own tick
# (bin/tier2-merge-sweep.sh). A settings row cannot move them, and a page that
# offered to would be offering to rewrite the gate's answer to itself.
# MRG_FLAG is in that list because bin/review-prs.sh reads it in ONE log string
# and nothing anywhere assigns it — it is a dead variable in a message, not a
# knob, and the message reads correctly on its `:-main-red` default.
#
# THE SIX ADDED BY BH-1269, when bin/batch-resolve.sh became a wired lane, each
# for one of the two reasons already on this list and not for a third:
#   MC_REPOS                 where the hub keeps its clones. A settings row
#                            cannot move a directory, the same way it cannot
#                            move $HARNESS.
#   MC_GIT_NAME/_EMAIL       the identity the fleet's own commits are made
#                            under, set once in env/global.env for every lane
#                            that commits; a per-lane settings row for it would
#                            mean two lanes signing the same repo differently.
#   GH_REST_STATUS/_REASON   SET BY bin/lib/gh-rest.sh in the caller's shell and
#                            read back in log lines. MRG_FLAG's case exactly:
#                            an output, not an input.
#   ISSUE_CLOSE_ERR          the same, from bin/lib/issue-state-lib.sh.
#   JOBS_HTTP                the same, from bin/lib/jobs/req.sh: the last
#                            jobs-worker HTTP status, read back in log lines.
PLUMBING="$PLUMBING JOBS_HTTP"
# LANE_SWITCH_SRC (BH-2433) is SET BY bin/lib/lane-switch.sh's lane_switch
# (box-row, fleet-row or legacy) and read back by the cost lanes so their log
# line and cost-autohalt's reason name the row or the file that stopped them.
# The same case as GH_REST_STATUS: an output, not an input.
PLUMBING="$PLUMBING LANE_SWITCH_SRC"
# JOBS_TRANSCRIPT_TRUNCATED (BH-5915) is SET BY bin/lib/jobs/jobs.sh's
# job_transcript_get: 1 when the ledger kept only the transcript's tail.
# bin/lesson-classify.sh reads it back after the call. An output, the same case
# as GH_REST_STATUS: a settings row that set it would make every full report
# read as tail-only.
PLUMBING="$PLUMBING JOBS_TRANSCRIPT_TRUNCATED"
# PL_LANE, PL_PROJECT, PL_SLUG, PL_STATE_DIR and PL_LOCK_FD (BH-5913) are SET BY
# bin/project-lane-run.sh for the one project run it starts: which lane, which
# project, which lock fd it already holds. Outputs of the runner, never knobs: a
# settings row that set PL_PROJECT would point every run at one project.
PLUMBING="$PLUMBING PL_LANE PL_PROJECT PL_SLUG PL_STATE_DIR PL_LOCK_FD"
# LANE_RUN_ID (BH-6124, read by blocked-resolver since BH-6128) is SET BY
# bin/lane-run-worker.sh for the one lane_runs row it claimed. Its presence
# means "this run is on a Fly lane machine": write back, never start a build.
# An output of the machine loop, never a knob: a settings row that set it would
# make every hub run believe it was off the hub.
PLUMBING="$PLUMBING LANE_RUN_ID"
# MC_FANIN_SOLO_RUN (BH-4842) is a launch marker, not a knob: kw_conductor sets
# it on the keyed run mc_fanin_solo launches, so that run never solos again. A
# settings row that set it would switch the solo split off for every tick.
# HARNESS_REPO is bin/lib/deployment.sh's (catalog/lanes.d/_lib.deployment.json,
# settable: false); the merge-conductor backstop reads it after sourcing that
# file to put the harness's own repo first.
# MC_WORKERS_DONE_BY and MC_WINDOW_DEFER_FILE (BH-4842) are the window a backstop
# fire hands its keyed conductor run: the epoch by which its workers must be
# gone and the file the run writes the keys it had no time for to. Computed per fire, never
# a knob: a settings row would bound every run by a stale epoch.
PLUMBING="$PLUMBING MC_FANIN_SOLO_RUN HARNESS_REPO MC_WORKERS_DONE_BY MC_WINDOW_DEFER_FILE"
# FLEET_PATHS (BH-5247) is SET BY bin/lib/fleet-paths.sh, the one list of paths
# that matter to the fleet. bin/fleet-propagate.sh and bin/pipeline-health.sh
# `unset FLEET_PATHS` and then source the lib, so an env value never reaches
# them: a settings row could not move it, and registering it as a knob would
# offer a value both lanes throw away. A constant from a lib, not an input.
PLUMBING="$PLUMBING FLEET_PATHS"
# TG_MODE and TG_MODE_SRC (BH-4580) are SET BY bin/lib/tier-gate.sh's tg_mode
# and read back in bin/review-prs.sh's "APPROVE left unmerged" log line. The
# same case as LANE_SWITCH_SRC: an output, not an input. The knob itself is the
# tier_gate_mode settings row the lib reads.
PLUMBING="$PLUMBING TG_MODE TG_MODE_SRC"
# HC_STATE (BH-5271) is SET BY bin/lib/hotspot-context.sh's hc_section (yes,
# none, never, off or unknown) and read back by bin/lead-review.sh in one log
# line. GH_REST_STATUS's case: an output, not an input.
PLUMBING="$PLUMBING HC_STATE"
# MC_PROJ_GATE (BH-6890) is SET BY bin/lib/mc/tick-scope.sh's mc_tick_fanout
# (BH-7879) once per tick, from the settings cache, and read back by the
# driver's tick_project. MC_WORKERS_DONE_BY's case: computed per tick, never a
# knob. A settings row that set it would be overwritten by the fan-out anyway.
PLUMBING="$PLUMBING MC_PROJ_GATE"
PLUMBING=$(printf '%s' "$PLUMBING" | tr '\n' ' ')

# --- 1. shape ----------------------------------------------------------------
jq -e . "$REG" >/dev/null 2>&1 && ok || bad "1a catalog/lanes.json is not valid JSON"
NIDS=$(jq -r '.lanes|length' "$REG"); NUNIQ=$(jq -r '[.lanes[].id]|unique|length' "$REG")
[ "$NIDS" = "$NUNIQ" ] && ok || bad "1b $NIDS lanes but $NUNIQ unique ids"

if lr_section 2; then  # LANES_REGISTRY_SECTIONS=static skips 2-5 (they render and run cron)
# --- 2. every cron script is registered --------------------------------------
# Comments are stripped FIRST. hub.cron carries a prose note naming a script
# that was REMOVED from cron; a registry test that read it would demand a lane
# for automation that no longer exists.
# BH-2205: the substitution is CAPTURED and checked. rendered_cron_dir's `exit 1`
# only leaves the $(...) subshell, so an unchecked call let a refused render
# become an empty scan that §2 and §4 then counted as passes.
mkdir -p "$T/cron"
CRON_DIR=$(rendered_cron_dir) || CRON_DIR=""
CRON_SCRIPTS=""
if [ -z "$CRON_DIR" ]; then
  # The library drops the renderer's stderr; run it once more for the reason.
  WHY=$("$DIR/bin/render-cron.sh" --root "$DIR" --out-dir "$T/cron-why" 2>&1 >/dev/null | head -3 | tr '\n' ' ')
  bad "2 could not render the fleet (bin/render-cron.sh refused: ${WHY:-no reason given}), so §2 and §4 did not run"
else
  for f in "$CRON_DIR"/*.cron; do
    sed -e 's/[[:space:]]#[[:space:]].*$//' -e '/^[[:space:]]*#/d' "$f" > "$T/cron/$(basename "$f")"
  done
  # A `# @boxrole` box with no cron/boxes/<id>.d (BH-7303) is not in the fleet
  # render, and still runs the lanes that name it: render it on its own.
  while IFS=$'\t' read -r _ RID _; do
    [ -n "$RID" ] && [ ! -e "$T/cron/$RID.cron" ] || continue
    "$DIR/bin/render-cron.sh" --root "$DIR" "$RID" 2>/dev/null \
      | sed -e 's/[[:space:]]#[[:space:]].*$//' -e '/^[[:space:]]*#/d' > "$T/cron/$RID.cron" \
      || bad "2 bin/render-cron.sh $RID (a @boxrole box) refused"
  done < <(FLEET_CONF="$DIR/fleet.conf" REGISTRY_SOURCE=file "$DIR/bin/fleet-conf.sh" --boxes-with-roles)
  CRON_SCRIPTS=$(grep -hoE '/root/(harness|orchestrator)/bin/[a-z0-9-]+\.sh' "$T"/cron/*.cron \
    | sed -E 's#.*/([a-z0-9-]+)\.sh#\1#' | grep -vxE 'hub-lease|fleet-conf' | sort -u)
  [ -n "$CRON_SCRIPTS" ] && ok || bad "2 the rendered fleet runs no harness script — the cron scan read nothing"
  MISSING=""
  for s in $CRON_SCRIPTS; do
    jq -e --arg i "$s" '.lanes[]|select(.id==$i)' "$REG" >/dev/null 2>&1 || MISSING="$MISSING $s"
  done
  [ -z "$MISSING" ] && ok || bad "2 cron runs these with no registered lane:$MISSING"
fi

# --- 3. every registered script exists ---------------------------------------
GONE=""
while read -r sc; do
  case "$sc" in /*) continue ;; esac          # /root/orchestrator/... is not in this repo
  [ -f "$DIR/$sc" ] || GONE="$GONE $sc"
done < <(jq -r '.lanes[].script' "$REG")
[ -z "$GONE" ] && ok || bad "3 registered lanes point at scripts that do not exist:$GONE"

# --- 4. the boxes a lane claims are the boxes that run it --------------------
BOXMISMATCH=""
for s in $CRON_SCRIPTS; do
  want=$(grep -lE "/root/(harness|orchestrator)/bin/$s\.sh" "$T"/cron/*.cron \
    | sed -E 's#.*/([a-z0-9]+)\.cron#\1#' | sort -u | tr '\n' ',' )
  got=$(jq -r --arg i "$s" '.lanes[]|select(.id==$i)|.boxes|sort|join(",")' "$REG")
  [ "${want%,}" = "$got" ] || BOXMISMATCH="$BOXMISMATCH $s(cron=${want%,} registry=$got)"
done
# No render, no §4 verdict: §2 already counted the failure.
[ -n "$CRON_DIR" ] && { [ -z "$BOXMISMATCH" ] && ok || bad "4 boxes drifted from cron:$BOXMISMATCH"; }

# --- 5. every wired lane really GATES (the header is EXECUTED) --------------
# The block is lifted verbatim from the shipped script — the source line and the
# guarded call — and run with HARNESS pointing at a scratch tree that holds
# flags/all-off. A working gate exits 0 before the marker; a broken one prints
# it.
mkdir -p "$T/g/bin/lib" "$T/g/flags" "$T/g/logs" "$T/g/state" "$T/g/catalog"
cp "$DIR/bin/lib/lane-gate.sh" "$T/g/bin/lib/"
cp "$(rendered_registry)" "$T/g/catalog/lanes.json"
: > "$T/g/flags/all-off"
UNGATED=""
while read -r id; do
  sc=$(jq -r --arg i "$id" '.lanes[]|select(.id==$i)|.script' "$REG")
  [ -f "$DIR/$sc" ] || { UNGATED="$UNGATED $id(no-script)"; continue; }
  # The lane-gate lines of this script, in order: the source and the call.
  grep -E '^[[:space:]]*\.[[:space:]]+.*bin/lib/lane-gate\.sh|lane_gate_or_exit' "$DIR/$sc" \
    | grep -v '^[[:space:]]*#' > "$T/block.sh" 2>/dev/null
  if ! grep -q "lane_gate_or_exit $id" "$T/block.sh"; then
    UNGATED="$UNGATED $id(not-wired)"; continue
  fi
  {
    echo '#!/bin/bash'
    echo 'set -uo pipefail'
    echo 'HARNESS="${HARNESS:-/root/harness}"; H="$HARNESS"'
    # The project-scoped headers pass "$P" / "$PROJECT"; under `set -u` an
    # unset one is an unbound-variable exit, which is the probe's gap, not the
    # lane's. The scripts themselves set these before the gate.
    echo 'P=probe-project; PROJECT=probe-project'
    cat "$T/block.sh"
    echo 'echo REACHED_THE_LANE_BODY'
  } > "$T/probe.sh"
  OUT=$(env -i PATH="$PATH" HOME="$T" HARNESS="$T/g" bash "$T/probe.sh" 2>/dev/null); RC=$?
  case "$OUT" in *REACHED_THE_LANE_BODY*) UNGATED="$UNGATED $id(ran-anyway)" ;; esac
  [ "$RC" -eq 0 ] || UNGATED="$UNGATED $id(rc=$RC)"
done < <(jq -r '.lanes[]|select(.wired)|.id' "$REG")
[ -z "$UNGATED" ] && ok || bad "5 wired lanes whose SHIPPED header does not gate:$UNGATED"
# and the skip was recorded, not merely silent
[ -s "$T/g/logs/lane-gate.log" ] && ok || bad "5b nothing was written to logs/lane-gate.log by nine gated headers"

fi  # lr_section 2

if lr_section 6; then  # LANES_REGISTRY_SECTIONS=static skips 6 (30 s of per-knob greps)
# --- 6. no phantom knobs -----------------------------------------------------
PHANTOM=""
while read -r id env readin prefix; do
  [ "$env" = null ] && continue                  # a resolver knob, not an env read
  f="$readin"
  [ "$f" = null ] && f=$(jq -r --arg i "$id" '.lanes[]|select(.id==$i)|.script' "$REG")
  [ -f "$DIR/$f" ] || { PHANTOM="$PHANTOM $id/$env(no-file)"; continue; }
  # A name the reader BUILDS — `LANE_USD_CAP_$(_lc_envkey "$l")` in
  # bin/lib/lane-caps.sh — cannot be grepped for whole. The knob declares the
  # literal `prefix` its reader does contain, and section 15 proves that prefix
  # is really a prefix of this env name, so the escape hatch cannot cover a knob
  # nothing reads.
  if [ "$prefix" != null ] && [ -n "$prefix" ]; then
    grep -qF -- "$prefix" "$DIR/$f" || PHANTOM="$PHANTOM $id/$env(prefix)"
    continue
  fi
  grep -qw "$env" "$DIR/$f" || PHANTOM="$PHANTOM $id/$env"
done < <(jq -r '.lanes[]|select(.wired)|.id as $i|.knobs[]?|[$i,(.env//"null"),(.read_in//"null"),(.prefix//"null")]|@tsv' "$REG")
[ -z "$PHANTOM" ] && ok || bad "6 registered knobs nothing reads:$PHANTOM"
fi  # lr_section 6

# --- 7. no missing knobs -----------------------------------------------------
# An operator knob looks like ${NAME:-default} for an ALL-CAPS NAME the script
# never assigns itself. That heuristic is what separates a knob from a local
# (${ERR:-?}, ${SCAN:-0}) without a hand-maintained list of locals.
MISSINGK=""
while read -r id; do
  sc=$(jq -r --arg i "$id" '.lanes[]|select(.id==$i)|.script' "$REG")
  [ -f "$DIR/$sc" ] || continue
  known=$(jq -r --arg i "$id" '.lanes[]|select(.id==$i)|.knobs[]?|.env//empty' "$REG" | tr '\n' ' ')
  # Comments are stripped FIRST, from both halves. `# KILL FLAG:
  # POOL_AUTOSCALE=0 restores …` in bin/fly-pool.sh read as an ASSIGNMENT and
  # made this section skip the very knob the PR claimed it had caught: with
  # POOL_AUTOSCALE deleted from the registry the suite was still green.
  # BH-1351: a lane whose script SOURCES libraries hid knobs from this section.
  # WAKE_PROMPT_EVAL_COOLDOWN_S lived in bin/lib/wake-class-push.sh for a whole
  # release and §7 never saw it, because the lane's `script` is bin/wake-loop.sh
  # and the knob is read one `source` away. So the scan set is the lane script
  # PLUS, for bin/wake-loop.sh, the class files its OWN loader globs (the glob
  # below is copied from bin/wake-loop.sh's `for f in "$SELF/lib"/wake-class-*.sh`),
  # which means the next class file is scanned the moment it lands and cannot
  # hide a bare ${X:-} the registry does not carry. The files are concatenated
  # into ONE $T/code.sh on purpose: the assignment check further down then reads
  # a class-local (WC_PR_CLOSED=0, WC_SNAPSHOT=0, WC_PUSH_PROJECTS="") as the
  # local it is instead of reporting it as a missing knob. Only wake-loop is
  # expanded — following every `source` generically would pull
  # bin/lib/lane-gate.sh and friends into all 80 lanes' knob sets and flood this
  # line with names no lane owns.
  scan=("$DIR/$sc")
  if [ "$sc" = bin/wake-loop.sh ]; then
    for cl in "$DIR"/bin/lib/wake-class-*.sh; do
      [ -r "$cl" ] && scan+=("$cl")
    done
  fi
  sed -e 's/[[:space:]]#[[:space:]].*$//' -e '/^[[:space:]]*#/d' "${scan[@]}" > "$T/code.sh"
  # BH-3548: a contract reader. A lane that runs `lane_env_apply <other lane>`
  # gets that lane's knobs exported by the gate, so a knob registered THERE is
  # registered (bin/lead-review-precision.sh reads LEAD_REVIEW_AUTO_REPOS off
  # lead-review-land, BH-3479.0). A name no lane registers still fails.
  for other in $(grep -oE 'lane_env_apply[[:space:]]+[a-z0-9-]+' "$T/code.sh" | awk '{print $2}' | sort -u); do
    [ "$other" = "$id" ] && continue
    known="$known $(jq -r --arg i "$other" '.lanes[]|select(.id==$i)|.knobs[]?|.env//empty' "$REG" | tr '\n' ' ')"
  done
  for n in $(grep -ohE '\$\{[A-Z][A-Z0-9_]{2,}:-' "$T/code.sh" | sed -E 's/\$\{([A-Z0-9_]+):-/\1/' | sort -u); do
    case " $PLUMBING " in *" $n "*) continue ;; esac
    # A CREDENTIAL IS NOT A KNOB, in either direction. Section 13 refuses a
    # credential-shaped STRING from the registry (it would print a token on the
    # settings page); demanding one here would make those two rules contradict
    # each other, and the only way to satisfy both would be to register the
    # secret. The shape is the same regex section 13 uses.
    grep -qE '(^|_)(TOKEN|SECRET|PASSWORD|CREDENTIALS?|KEY|DSN)$' <<<"$n" && continue
    case " $known "    in *" $n "*) continue ;; esac
    grep -qE "(^|[[:space:]]|;|\(|!)(local[[:space:]]+|export[[:space:]]+)?$n=|read[[:space:]].*\b$n\b" "$T/code.sh" && continue
    MISSINGK="$MISSINGK $id/$n"
  done
done < <(jq -r '.lanes[]|select(.wired)|.id' "$REG")
[ -z "$MISSINGK" ] && ok || bad "7 wired lanes read env knobs the registry does not carry:$MISSINGK"

# --- 8. the knob schema ------------------------------------------------------
BADSCHEMA=$(jq -r '
  [ .lanes[] | .id as $i | .knobs[]?
    | select((.env == null and (.resolver // null) == null)
             or ((.zero_means // null) | IN(null,"off","unlimited") | not)
             or (has("type")|not) or (has("default")|not))
    | "\($i)/\(.env // .resolver)" ] | join(" ")' "$REG")
[ -z "$BADSCHEMA" ] && ok || bad "8 knobs with a bad schema: $BADSCHEMA"

# --- 9. every settings key is legal for every project in fleet.conf ----------
BADKEY=""
while read -r id scope env pscoped; do
  [ "$env" = null ] && continue
  low=$(printf '%s' "$env" | tr '[:upper:]' '[:lower:]')
  # A hub- or box-scoped lane never gets a project segment, so only a
  # project-scoped one is measured against the slugs.
  PROJS=""
  # A knob that declares project_scoped:true takes a project row on ANY lane
  # (BH-1770: the reaper's per-build-lane deadline on a box lane), so its keys
  # are measured against every slug too.
  { { [ "$scope" = project ] && [ "$pscoped" != false ]; } || [ "$pscoped" = explicit-true ]; } \
    && PROJS=$(awk 'NF && $1!~/^#/{print $1}' "$DIR/fleet.conf" | sort -u)
  for proj in "" $PROJS; do
    if [ -n "$proj" ]; then k="lane.$id.$proj.$low"; else k="lane.$id.$low"; fi
    [ "${#k}" -le 64 ] || { BADKEY="$BADKEY $k(${#k})"; continue; }
    case "$k" in *[!a-z0-9_.-]*) BADKEY="$BADKEY $k(charset)" ;; esac
  done
done < <(jq -r '.lanes[]|.id as $i|.scope as $s|.knobs[]?|[$i,$s,(.env//"null"),(if has("project_scoped") then (if .project_scoped == true then "explicit-true" else (.project_scoped|tostring) end) else "true" end)]|@tsv' "$REG")
[ -z "$BADKEY" ] && ok || bad "9 settings keys that PUT /api/settings would refuse:$BADKEY"

# --- 10. the registry carries NO key alias ----------------------------------
# One knob, one key, and it is the contract's. An alias here would be a second
# spelling, and the console writes the other one.
ALIASED=$(jq -r '[.lanes[]|.id as $i|.knobs[]?|select(has("key"))|"\($i)/\(.env)"]|join(" ")' "$REG")
[ -z "$ALIASED" ] && ok || bad "10 knobs carrying a key alias the console will not write:$ALIASED"

# --- 11. every alias declares its polarity ----------------------------------
BADPOL=$(jq -r '
  [ .lanes[] | .id as $i | .switch.aliases[]?
    | select((type != "object") or (has("name")|not)
             or ((.off_when // "") | IN("present","absent","partial") | not))
    | "\($i)/\(if type == "object" then (.name // "?") else . end)" ] | join(" ")' "$REG")
[ -z "$BADPOL" ] && ok || bad "11 aliases with no polarity (present|absent|partial):$BADPOL"

if lr_section 12; then  # LANES_REGISTRY_SECTIONS=static skips 12 (it reads every cron render)
# --- 12. every lane this repo owns is WIRED ------------------------------------
# The only way out is a DECLARATION, and the declaration is checked: a lane
# claiming external=true whose script is sitting in this repo fails here, and so
# does one with no reason. Phase A's 69 ungated lanes each drew a switch on the
# settings page that the lane never read.
#
# TWO CHECKS THAT COULD NEVER FIRE (BH-1165 review). The no-reason arm was
# written `[ "$reason" = null ] || [ -z "$reason" ] && [ "$reason" = null ] && …`,
# which the shell parses as `A || (B && C && D)`: with a missing field jq's
# `//"null"` yields the STRING null, A is true and the rest is skipped; with an
# empty one C is false. Either way BADEXT was never touched. And `read -r`
# without an IFS splits an @tsv row on SPACES, so a multi-word external_reason
# (the only one in the registry is multi-word) spilled across the fields and
# `$sc` held the last word of the reason rather than the script — so the
# script-is-here arm was testing `[ -f "$DIR/<word>" ]` and could not fire
# either. The separator is US (\037) and not a tab, because TAB IS IFS
# WHITESPACE: bash collapses a run of it however IFS is set, so an EMPTY
# external_reason between two tabs shifts every later field left and the
# reason field would hold the script. Both arms are re-run below against a
# fixture that MUST be caught, so neither can go dead again silently.
_reg_check12() { # _reg_check12 <registry> -> prints "unwired|badext"
  local reg="$1" id wired ext reason sc unwired="" badext=""
  while IFS=$'\037' read -r id wired ext reason sc; do
    if [ "$wired" = true ]; then
      [ "$ext" = true ] && badext="$badext $id(wired+external)"
      continue
    fi
    if [ "$ext" != true ]; then unwired="$unwired $id"; continue; fi
    if [ "$reason" = null ] || [ -z "$reason" ]; then badext="$badext $id(no-reason)"; fi
    case "$sc" in /*) : ;; *) [ -f "$DIR/$sc" ] && badext="$badext $id(script-is-here)" ;; esac
  done < <(jq -r '.lanes[]|[.id,(.wired|tostring),((.external//false)|tostring),(.external_reason//"null"),.script]|join("\u001f")' "$reg")
  printf '%s|%s' "$unwired" "$badext"
}
R12=$(_reg_check12 "$REG"); UNWIRED="${R12%%|*}"; BADEXT="${R12#*|}"
[ -z "$UNWIRED" ] && ok || bad "12a lanes registered with a switch they never read:$UNWIRED"
[ -z "$BADEXT" ] && ok || bad "12b lanes claiming to live in another repo without proving it:$BADEXT"
# 12c — THE CHECK ITSELF IS ALIVE. Three lanes it must catch: no reason at all,
# an empty reason, and a script that is sitting right here in this repo behind a
# multi-word reason (the shape the space-splitting read could not see).
cat > "$T/reg12.json" <<'J'
{"lanes":[
 {"id":"noreason","wired":false,"external":true,"script":"/root/orchestrator/bin/x.sh"},
 {"id":"emptyreason","wired":false,"external":true,"external_reason":"","script":"/root/orchestrator/bin/y.sh"},
 {"id":"ishere","wired":false,"external":true,"external_reason":"lives in the orchestrator repo","script":"bin/untriaged-sweep.sh"}
]}
J
R12F=$(_reg_check12 "$T/reg12.json"); B12F="${R12F#*|}"
case "$B12F" in
  *noreason\(no-reason\)*) case "$B12F" in
      *emptyreason\(no-reason\)*) case "$B12F" in
          *ishere\(script-is-here\)*) ok ;;
          *) bad "12c the script-is-here arm did not catch a registry script sitting in this repo:$B12F" ;;
        esac ;;
      *) bad "12c the no-reason arm did not catch an EMPTY external_reason:$B12F" ;;
    esac ;;
  *) bad "12c the no-reason arm did not catch a MISSING external_reason:$B12F" ;;
esac

fi  # lr_section 12

# --- 13. no secret is a knob --------------------------------------------------
# A credential-SHAPED name is not automatically a credential: POOL_GH_TOKEN_
# ROTATE_EVERY is how many seconds a token lives and POOL_SPAWN_CAP_PER_KEY is a
# count. What separates them from MIGRATION_TOKEN is the TYPE — a secret is
# never an int, and a number is all the page will ever let anyone write into one
# of these rows (console-ui validateKnob refuses anything but a decimal). So a
# credential-shaped name is allowed only as a number, and a STRING one is
# refused: that is the shape that would print a token on the page and store it
# in a settings row.
# A `*_URL`, a `*HOOK*` and a `*WEBHOOK*` ARE CREDENTIALS HERE (BH-1165
# review). A Vercel DEPLOY_HOOK_URL is a bearer token inside a URL, and so are
# WATCHDOG_URL and LOCKS_URL — the suffix-only rule did not see any of them, so
# `harness-ctl.sh seed` would have copied all three out of env/global.env into
# web-visible settings rows. The escape hatch is `settable: false`: section 7
# still demands every read be REGISTERED (that is how a new one announces
# itself), and this refuses it being WRITABLE from a page. Registered and not
# settable satisfies both; there is no longer any shape that satisfies neither.
LEAK=$(jq -r '
  [ .lanes[] | .id as $i | .knobs[]? | select(.env)
    | select((.env|test("(^|_)(TOKEN|SECRET|PASSWORD|CREDENTIALS?|KEY|DSN|URL|HOOK|WEBHOOK)$")) or (.env|test("HOOK")))
    | select(((.type // "string") | IN("int","number")) | not)
    | select(.settable != false)
    | "\($i)/\(.env)" ] | join(" ")' "$REG")
[ -z "$LEAK" ] && ok || bad "13 credentials registered as settable knobs: $LEAK"

# --- 14. project_scoped:false is only for a key that really overflows ---------
BADPS=""
while read -r id scope env; do
  low=$(printf '%s' "$env" | tr '[:upper:]' '[:lower:]')
  [ "$scope" = project ] || { BADPS="$BADPS $id/$env(not-a-project-lane)"; continue; }
  LONGEST=$(awk 'NF && $1!~/^#/{print length($1)}' "$DIR/fleet.conf" | sort -rn | head -1)
  N=$(( ${#low} + ${#id} + LONGEST + 7 ))   # lane. + id + . + project + . + env
  [ "$N" -gt 64 ] || BADPS="$BADPS $id/$env(fits-at-$N)"
done < <(jq -r '.lanes[]|.id as $i|.scope as $s|.knobs[]?|select(.project_scoped==false)|[$i,$s,.env]|@tsv' "$REG")
[ -z "$BADPS" ] && ok || bad "14 knobs made lane-wide that a project could have set:$BADPS"

# --- 15. a built env name declares a real prefix ------------------------------
# `.prefix` is captured into a VARIABLE first: inside `.env|startswith(...)`
# the dot is the env STRING, so `.prefix` there is an index into a string — jq
# errors, the command substitution comes back empty, and the section passes
# without checking anything.
BADPRE=$(jq -r '[.lanes[]|.id as $i|.knobs[]?|select(has("prefix"))|.prefix as $pre
  |select(((.env|type)=="string" and (.env|startswith($pre)))|not)|"\($i)/\(.env // "?")"]|join(" ")' "$REG")
[ -z "$BADPRE" ] && ok || bad "15 knobs whose declared prefix is not a prefix of the env name: $BADPRE"

if lr_section 16; then  # LANES_REGISTRY_SECTIONS=static skips 16 (it walks every wired script)
# --- 16. lane_env_apply runs BELOW the env load -------------------------------
# THE BUG THIS EXISTS FOR. Phase C wired 68 lanes and put the gate header near
# the top of each script — above `set -a; . env/global.env` in 24 of them. The
# env file then re-assigned every knob lane_env_apply had just exported, so a
# settings row an operator wrote lost to the box's env file while the page went
# on reporting `source: settings` and nothing errored anywhere. That is the
# exact sentence this ticket uses to describe the defect it closes.
#
# THE ANCHOR is the last line of the script's TOP-LEVEL env-load block: the
# first `. "…/global.env"` (or `$PROJECT.env`) outside a function, a loop and a
# subshell, plus any further one within two lines of it — which is the
# `global.env` / `$PROJECT.env` pair four lanes load together. A later source
# inside a function or a `( … )` is that call's own environment and cannot
# reach the parent, so it is not an anchor.
#
# EVERY WIRED LANE MUST CALL IT. A lane with a switch but no knob path is a
# settings page whose numbers are decoration; the nine lanes phase A wired had
# 90 knobs between them and not one could be set.
BADORDER=""; NOAPPLY=""
cat > "$T/anchor.awk" <<'AWK'
/^[A-Za-z_][A-Za-z0-9_-]*\(\)/ { if ($0 !~ /\}[[:space:]]*$/) infunc=1; next }
infunc && /^\}/ { infunc=0; next }
infunc { next }
/^[[:space:]]*(for|while|until)[[:space:]].*;[[:space:]]*do([[:space:]]|$)/ { loop++; next }
/^[[:space:]]*do([[:space:]]|$)/ { loop++; next }
/^[[:space:]]*done([[:space:]]|$|;)/ { if (loop>0) loop--; next }
loop > 0 { next }
/\$\(/ { next }
/^[[:space:]]*\(/ { next }
/^[^#]*\.[[:space:]]+"[^"]*\/(global|\$PROJECT|\$P)\.env"/ {
  if (last == 0) last = NR; else if (NR - last <= 2) last = NR
}
END { if (last) print last }
AWK
while read -r id; do
  sc=$(jq -r --arg i "$id" '.lanes[]|select(.id==$i)|.script' "$REG")
  [ -f "$DIR/$sc" ] || continue
  a=$(grep -nE '^[^#]*lane_env_apply' "$DIR/$sc" | tail -1 | cut -d: -f1)
  if [ -z "$a" ]; then NOAPPLY="$NOAPPLY $id"; continue; fi
  e=$(awk -f "$T/anchor.awk" "$DIR/$sc")
  [ -n "$e" ] || continue
  [ "$a" -gt "$e" ] || BADORDER="$BADORDER $id(apply@$a,env@$e)"
done < <(jq -r '.lanes[]|select(.wired)|.id' "$REG")
[ -z "$NOAPPLY" ] && ok || bad "16a wired lanes whose settings rows can never reach the script:$NOAPPLY"
[ -z "$BADORDER" ] && ok || bad "16b lane_env_apply ABOVE the env load — global.env overwrites the row:$BADORDER"

fi  # lr_section 16

# --- 17. a command, a host, a path or an identity is never settable -----------
# Registering every `${X:-…}` a wired script reads (section 7) pulled 212 new
# names in, and about eighty of them are not numbers an operator tunes: they are
# the command the lane runs (`CLI_CHECK_SSH`, expanded UNQUOTED as
# `$SSH_CMD "root@$1" "bash -s"`; `PROMPT_EVAL_AGENT_CALL`; `OAUTH_USAGE_FETCH`,
# run with the OAuth token in its environment), the HOST it talks to (`JOBS_URL`
# — every request in that tick carries `authorization: Bearer $HARNESS_SECRET`;
# `*_API_BASE` — `MIGRATION_TOKEN` is POSTed to it), the PATH it deletes under
# (`DISK_CLEAN_REPOS`), the IDENTITY it claims (`JOBS_BOX`, `HARNESS_PR_AUTHORS`)
# or a TEST SEAM (`AUTH_CHECK_LIB`, `BACKUP_NOW`). bin/lib/lane-gate.sh exports a
# settings row into a lane cron runs AS ROOT, and bin/poll-commands.sh — the
# other thing the console can drive — deliberately runs a fixed verb list. So a
# hazard-shaped name must carry `settable: false`, which keeps it REGISTERED and
# visible while refusing it at every write surface. A NEW one announces itself
# here instead of on a box.
# THE `APP` ARM (BH-1291). A Fly app name is a host the lane acts ON, not a
# number: bin/testhost-tick.sh hands TESTHOST_APP to `flyctl machine stop/start`
# and `flyctl ssh console` as `-a "$APP"` under the box's own Fly credential, so
# a row naming another app re-aims that credential at it. Suffix-anchored like
# every other arm, which leaves GH_APP_ROTATE (a settable rotation switch)
# alone.
HAZ='(^|_)(SSH|CMD|CALL|BIN|FETCH|GH|CLIENT|URL|BASE|HOOK|WEBHOOK|DIR|ROOT|ROOTS|PATH|FILE|REPOS|REPO|PROC|BOX|BOXES|LIB|SOURCES|CATALOG|SNAPSHOT|BASELINE|FIXTURES|LOG|ALERTS|CHECKOUT|HTTP|BUCKET|REGION|NOW|AT|CONF|PRICES|LOGINS|BRANCH|AUTHOR|AUTHORS|ID|PROJECTS|WORKTREES|RUNNER|APP)$|^RUNNER_|^WORKTREES$|^HUB_BOX_NAME$'
# THE THREE REVIEWED EXCEPTIONS. A `*_RUNNER` name reads like "the thing this
# lane executes", and for every other name on the hazard list that is what it
# is. These three do not run anything: they NAME a runner out of the closed list
# bin/agent-call.sh dispatches (claude|codex|openrouter|fireworks|grok|gemini,
# with `runner_ready` refusing anything else and no default arm in the case), so
# a row can only pick one of six lanes the repo already ships. And which runner
# triage runs on is the spend lever the $793 night (#1039) turned on, which is
# the one number this whole control plane exists to put on a page. The list is
# NAMED here rather than carved out of the regex so the next `*_RUNNER` still
# has to be argued for.
# THE FOURTH (the operator, 2026-09-29): split-watchdog/SPLIT_WATCHDOG_PROJECTS. A
# `*_PROJECTS` name reads like "the identity this lane acts as", but here it is
# only a FILTER: bin/split-watchdog.sh loops over the fleet's own $PROJECTS and
# skips any not named in the row (`case "$ENABLED" in *" $p "*)`), and each
# survivor must still pass fleet-conf.sh. A row can switch the watchdog on or
# off for a project the fleet already runs; it cannot name a host, a path, a
# command or a new project. Named here, like the runners, so the next
# `*_PROJECTS` still has to be argued for.
# THE FIFTH (BH-4007): cost-rows-push/COST_ROWS_LANE_PROJECTS. Also only a
# FILTER: cost_row_allowed_projects (bin/lib/cost-row.sh) appends its words to
# fleet-conf.sh --projects, and _metric_cost_rows_chunk compares each cost.csv
# row's project against that set. A row can widen or narrow which of the box's
# own cost rows reach the DB mirror (cost.csv keeps every row either way); it
# cannot name a host, a path, a command or an identity.
# THE SIXTH (BH-5910): fly-pool/EXTRA_READ_REPOS. The ticket asks for exactly a
# per-project settings row. The words are GitHub `owner/repo` slugs, never a
# path: bin/gh-token.sh --extra-read drops any word that is not
# ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$, and keeps only a repo the SAME App
# installation as the project already covers (GET /repos/<repo>/installation,
# another owner never). The token it mints is contents+metadata READ, with no
# PAT or hub fallback. A row can widen what one project's pool builds can READ
# inside that installation; it cannot grant a write, name a host, a path, a
# command or an identity. The raw row never reaches a shell: bin/fly-pool.sh
# writes the builder's sourced global.env with only the regex-checked slugs,
# comma-joined (tests/fly-pool-extra-read.bh-5910-test.sh cases 8 and 9).
# THE SEVENTH (BH-5962): fly-pool/POOL_TEST_SETUP_CMD. The ticket's spec asks
# for exactly a per-project settings row. It is not a command: bin/lib/pg-test.sh
# accepts only the whole value `npm run <name>`, <name> matching
# ^[A-Za-z0-9][A-Za-z0-9:_.-]{0,63}$ and declared in the target repo's own
# package.json, refuses any multi-line value, and runs `npm run "<name>"` with
# the name quoted. A row can pick which of the repo's OWN scripts runs against a
# throwaway 127.0.0.1 Postgres; it cannot name a binary, an argument, a host, a
# path or an identity (tests/pool-test-postgres.bh-5962-test.sh P5d).
# THE EIGHTH (BH-5943): stuck-work/STUCK_WORK_PROJECTS. Also only a FILTER:
# bin/stuck-work.sh --dispatch starts one run per fleet.conf project, and each
# run's sw_watched compares its own fleet project against the row (`self`,
# `all`, or exact names via `case ",$list," in *",$p,"*`). A value with any
# character outside [A-Za-z0-9._,-] is one stderr line and reads as `self`. The
# words never reach a path, a host, a command or an identity: the project name
# a run uses comes from fleet.conf and passed fleet-conf.sh before the row is
# read. A row can turn paging on or off for a project the fleet already runs.
# TEST-CHANGE (BH-5943): stuck-work/STUCK_WORK_PROJECTS added to HAZ_OK with the argument above.
HAZ_OK='alert-triage/HOUSEKEEPING_RUNNER alerts-medic/HOUSEKEEPING_RUNNER run-triage/RUNNER_TRIAGE split-watchdog/SPLIT_WATCHDOG_PROJECTS cost-rows-push/COST_ROWS_LANE_PROJECTS fly-pool/EXTRA_READ_REPOS fly-pool/POOL_TEST_SETUP_CMD stuck-work/STUCK_WORK_PROJECTS'
HAZARD=""
while read -r k; do
  [ -n "$k" ] || continue
  case " $HAZ_OK " in *" $k "*) continue ;; esac
  HAZARD="$HAZARD $k"
done < <(jq -r --arg re "$HAZ" '
  .lanes[] | .id as $i | .knobs[]? | select(.env) | select(.env|test($re))
    | select(.settable != false) | "\($i)/\(.env)"' "$REG")
[ -z "$HAZARD" ] && ok || bad "17a exec/host/path/identity knobs a settings row could drive into a root lane:$HAZARD"
# and the field is a real boolean, never a string "false" that reads as truthy
BADSET=$(jq -r '[.lanes[]|.id as $i|.knobs[]?|select(has("settable"))|select((.settable|type)!="boolean")|"\($i)/\(.env)"]|join(" ")' "$REG")
[ -z "$BADSET" ] && ok || bad "17b settable is not a boolean on:$BADSET"

# --- 18. a default is a VALUE, never shell text ------------------------------
# `$(date +%s)`, `$(knob reconcile_every 6)` and `${HARNESS:-/root/harness`
# (truncated at the first `}`) were scraped in as defaults. The page renders
# that string as "the default", `harness-ctl.sh show` prints it, and
# bin/lib/lane-gate.sh hands it to the lane verbatim when nothing else answers.
# A default nobody can copy into env/global.env and get the same behaviour is a
# lie on a control plane; where there is no static default the field is empty
# and the note says what computes it.
BADDEF=$(jq -r '[.lanes[]|.id as $i|.knobs[]?|select((.default|tostring)|test("\\$"))|"\($i)/\(.env)"]|join(" ")' "$REG")
[ -z "$BADDEF" ] && ok || bad "18 knob defaults carrying shell text instead of a value:$BADDEF"

if lr_section 19; then  # LANES_REGISTRY_SECTIONS=static skips 19 (it walks every wired script)
# --- 19. the gate runs BEFORE the lane's work, not somewhere inside it --------
# THE OTHER HALF OF SECTION 5 (BH-1165 review). Section 5 lifts a header's two
# lines out of the script and runs them, so it proves the header WORKS — it
# cannot see WHERE it sits. bin/untriaged-sweep.sh placed it after three of its
# four board sweeps: with flags/all-off set, the hub still curled the project-1,
# project-2 and project-3 boards with their internal API tokens, wrote three clients'
# ALERTS lines, beat for them — and then logged `untriaged-sweep SKIPPED`, so the
# operator's stop looked like it had taken. A switch that stops the last quarter
# of a lane while asserting it stopped the lane is worse than no switch.
#
# WHAT COUNTS AS WORK: a top-level command that leaves this box — curl, gh, ssh,
# scp, rsync, node/npm/npx, beat.sh, git push — or a call to a function defined
# in the same file whose body runs one. Assignments (`BEAT=$H/bin/beat.sh`),
# function definitions, comments and anything inside a loop, a function body or
# a subshell are not commands this walk can order. Setup that stays local (mkdir,
# touch, sourcing env) is deliberately allowed above the gate: lane_env_apply
# has to sit below the env load (section 16), so the header cannot be first.
cat > "$T/sidefuncs.awk" <<'AWK'
function isside(s) {
  return (s ~ /(^|[;&|(` \t])(curl|gh|ssh|scp|rsync|node|npm|npx)([ \t]|$)/ || s ~ /beat\.sh/ || s ~ /git[ \t]+push/)
}
function mark(n) { if (n != "" && !(n in seen)) { seen[n]=1; printf "%s ", n } }
/^[A-Za-z_][A-Za-z0-9_-]*\(\)/ {
  nm=$1; sub(/\(\).*/, "", nm)
  # a one-line body (`f() { curl …; }`) is the whole function, not an opening
  if ($0 ~ /\}[[:space:]]*$/) { if (isside($0)) mark(nm); name=""; infunc=0 }
  else { name=nm; infunc=1 }
  next
}
infunc && /^\}/ { infunc=0; name=""; next }
infunc && isside($0) { mark(name) }
AWK
cat > "$T/pregate.awk" <<'AWK'
/^[A-Za-z_][A-Za-z0-9_-]*\(\)/ { if ($0 !~ /\}[[:space:]]*$/) infunc=1; next }
infunc && /^\}/ { infunc=0; next }
infunc { next }
/^[[:space:]]*#/ { next }
/^[[:space:]]*$/ { next }
/^[[:space:]]*(for|while|until)[[:space:]].*;[[:space:]]*do([[:space:]]|$)/ { loop++; next }
/^[[:space:]]*do([[:space:]]|$)/ { loop++; next }
/^[[:space:]]*done([[:space:]]|$|;)/ { if (loop>0) loop--; next }
loop > 0 { next }
/^[[:space:]]*\(/ { next }
{
  if (gate == 0 && $0 ~ /lane_gate_or_exit/) { gate = NR; next }
  if (work) next
  if ($0 ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=[^ \t]*$/ && $0 !~ /\$\(/) next
  if ($0 ~ /(^|[;&|(` \t])(curl|gh|ssh|scp|rsync|node|npm|npx)([ \t]|$)/ || $0 ~ /beat\.sh/ || $0 ~ /git[ \t]+push/) { work = NR; next }
  n = split(FUNCS, a, " ")
  for (i = 1; i <= n; i++)
    if (a[i] != "" && $0 ~ ("(^|[;&|(`$ \t])" a[i] "([ \t]|$|;)")) { work = NR; next }
}
END { printf "%d %d\n", gate, work }
AWK
_reg_pregate() { # _reg_pregate <script> -> "<gate line> <first work line>" (0 = none)
  local f="$1" fns
  fns=$(awk -f "$T/sidefuncs.awk" "$f")
  awk -v FUNCS="$fns" -f "$T/pregate.awk" "$f"
}
LATEGATE=""
while read -r id; do
  sc=$(jq -r --arg i "$id" '.lanes[]|select(.id==$i)|.script' "$REG")
  [ -f "$DIR/$sc" ] || continue
  read -r g w < <(_reg_pregate "$DIR/$sc")
  [ "${w:-0}" -eq 0 ] && continue
  { [ "${g:-0}" -gt 0 ] && [ "$g" -lt "$w" ]; } || LATEGATE="$LATEGATE $id(gate@${g:-none},work@$w)"
done < <(jq -r '.lanes[]|select(.wired)|.id' "$REG")
[ -z "$LATEGATE" ] && ok || bad "19a lanes that leave this box BEFORE their own gate runs:$LATEGATE"
# 19b — THE WALK ITSELF IS ALIVE. The shape section 5 cannot see (work above the
# gate) must be caught, and the shape it must not flag (gate first) must pass.
mkdir -p "$T/pg"
cat > "$T/pg/late.sh" <<'S'
#!/bin/bash
H=/root/harness
BEAT=$H/bin/beat.sh
sweep() { curl -s "$1/api/board/boards" >/dev/null; }
set -a; . "$H/env/global.env"; set +a
sweep https://m.example
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit demo
sweep https://t.example
S
cat > "$T/pg/early.sh" <<'S'
#!/bin/bash
H=/root/harness
BEAT=$H/bin/beat.sh
sweep() { curl -s "$1/api/board/boards" >/dev/null; }
set -a; . "$H/env/global.env"; set +a
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit demo
sweep https://m.example
sweep https://t.example
S
read -r LG LW < <(_reg_pregate "$T/pg/late.sh")
read -r EG EW < <(_reg_pregate "$T/pg/early.sh")
if [ "${LW:-0}" -gt 0 ] && { [ "${LG:-0}" -eq 0 ] || [ "$LG" -gt "$LW" ]; } \
   && [ "${EW:-0}" -gt 0 ] && [ "${EG:-0}" -gt 0 ] && [ "$EG" -lt "$EW" ]; then
  ok
else
  bad "19b the pre-gate walk is dead: late(gate=$LG,work=$LW) early(gate=$EG,work=$EW)"
fi

fi  # lr_section 19

# --- 20. the libs scope and the required knobs (BH-1511.1) -------------------
# 20-self: code_has still tells a read from a comment, so the SIGPIPE-safe form
# did not weaken 20a/20b.
printf '# CH_ONLY_COMMENT is documented here\nx=${CH_READ:-1}\n' > "$T/code_has.sh"
if code_has "$T/code_has.sh" -w -- CH_READ && ! code_has "$T/code_has.sh" -w -- CH_ONLY_COMMENT \
   && code_has "$T/code_has.sh" -E '\$\{CH_READ:?[-=][^}]'; then ok
else bad "20-self code_has no longer separates a read from a comment"; fi
LIBBAD=""
while IFS=$'\t' read -r lid lfile env rin def; do
  [ -f "$DIR/$lfile" ] || { LIBBAD="$LIBBAD $lid(no-file:$lfile)"; continue; }
  # The knob's own read_in when it declares one, else the lib's file: section
  # 6's rule for lane knobs. A lib split across files (bin/lib/triage-state-pr.sh
  # reads PR_STATE_MODE for the triage-state lib, BH-3418) names its reader.
  [ "$rin" = null ] && rin="$lfile"
  [ -f "$DIR/$rin" ] || { LIBBAD="$LIBBAD $lid/$env(no-file:$rin)"; continue; }
  code_has "$DIR/$rin" -w -- "$env" || LIBBAD="$LIBBAD $lid/$env(phantom)"
  key="lib.$lid.$(printf '%s' "$env" | tr '[:upper:]' '[:lower:]')"
  grep -qE '^[a-z0-9_.-]{1,64}$' <<<"$key" || LIBBAD="$LIBBAD $lid/$env(key:$key)"
  case "$def" in *'$'*) LIBBAD="$LIBBAD $lid/$env(default-is-shell)" ;; esac
done < <(jq -r '.libs[]?|.id as $i|.file as $f|.knobs[]?|select(.env)|[$i,$f,.env,(.read_in//"null"),(.default|tostring)]|@tsv' "$REG")
[ -z "$LIBBAD" ] && ok || bad "20a libs scope:$LIBBAD"
LIBLEAK=$(jq -r '[.libs[]?|.id as $i|.knobs[]?|select(.env)
  |select((.env|test("(^|_)(TOKEN|SECRET|PASSWORD|CREDENTIALS?|KEY|DSN|URL|HOOK|WEBHOOK)$")) or (.env|test("HOOK")))
  |select(.settable != false)|"\($i)/\(.env)"]|join(" ")' "$REG")
[ -z "$LIBLEAK" ] && ok || bad "20b credential-shaped lib knobs that are settable: $LIBLEAK"
NLIBS=$(jq -r '[.libs[]?.id]|length' "$REG"); NLIBU=$(jq -r '[.libs[]?.id]|unique|length' "$REG")
[ "$NLIBS" = "$NLIBU" ] && ok || bad "20c $NLIBS libs but $NLIBU unique ids"
REQBAD=""
while IFS=$'\t' read -r scope id env def files; do
  case "$def" in ''|null) REQBAD="$REQBAD $scope:$id/$env(no-default)" ;; esac
  # (review M3) the knob stream is @tsv, which escapes \ and TAB: such a
  # required default would be exported altered.
  case "$def" in *\\*|*"$(printf '\t')"*) REQBAD="$REQBAD $scope:$id/$env(backslash-or-tab-in-default)" ;; esac
  for f in $files; do
    [ -f "$DIR/$f" ] || continue
    # code_has, not `| grep -q`: here a lost SIGPIPE race would be a silent PASS.
    code_has "$DIR/$f" -E "\\\$\\{$env:?[-=][^}]" \
      && REQBAD="$REQBAD $scope:$id/$env(literal-in:$f)"
  done
done < <(jq -r '
  (.lanes[]?|.id as $i|.script as $s|.knobs[]?|select(.env and .required==true)
     |["lane",$i,.env,(.default|tostring),([$s,(.read_in//empty)]|join(" "))]),
  (.libs[]?|.id as $i|.file as $f|.knobs[]?|select(.env and .required==true)
     |["lib",$i,.env,(.default|tostring),$f])
  |@tsv' "$REG")
[ -z "$REQBAD" ] && ok || bad "20d required knobs must have a default and no literal read left:$REQBAD"

LR_RUN=""; [ "${LANES_REGISTRY_SECTIONS:-}" = static ] && LR_RUN=" (static sections only: LANES_REGISTRY_SECTIONS=static)"
echo "lanes-registry: $PASS passed, $FAIL failed  ($NIDS lanes, $(jq -r '[.lanes[].knobs|length]|add' "$REG") knobs, $(jq -r '[.lanes[]|select(.wired)]|length' "$REG") wired)$LR_RUN"
[ "$FAIL" -eq 0 ]
