#!/bin/bash
# bin/lib/pool-stage.sh — a pool build's stage hand-off and its soft cap
# (BH-9065). Sourced by bin/run-build.sh on a pool machine; never executed.
#
# TWO ANSWERS THAT ARE NOT VERDICTS. Both end this machine's part of the build
# and ask the hub to re-offer the key. The hub reap (bin/fly-pool.sh, `pool
# stage re-offer`) requeues the key with no deferral, death, CI-repair,
# EXECUTE_EMPTY or abandon count changed.
#
#   PLANNED stage=plan <KEY>
#     The job carried `stage:"plan"` (RB_STAGE_ONLY=plan): the hub spawned it on
#     a `model`-class machine because row lane.fly-pool.<p>.vm_class maps
#     `plan=model`. After the plan and its gates, the plan is published to the
#     coordination DB (the same /api/preplans row bin/run-preplan.sh writes),
#     and the hub re-offers the key as `stage:"execute"` on a compute machine.
#     That machine adopts the plan through the existing preplan relay
#     (PREPLAN_HIT, no PLAN call). A publish that fails hands nothing off: the
#     build goes on here, whole, as it did before this file.
#
#   CAPPED stage=<stage> after=<n>s
#     The job carried `soft_cap_s` (POOL_SOFT_CAP_S, row
#     lane.fly-pool.<p>.machine_soft_cap_s) and this machine has been up that
#     long. CC() asks ps_cap_due at each model-session boundary and clamps a
#     session's timeout to the time left. At the cap: the branch is
#     checkpointed and pushed (bin/lane-checkpoint.sh, the same wip commit a
#     dead lane leaves, which the next build resumes from), the plan is
#     published, brief.md is written, THEN the RESULT. "Landed" is read from
#     the tree, not from lane-checkpoint's rc (rc 0 also means "switched off"):
#     nothing uncommitted outside its excludes, and origin/<branch> is HEAD. A
#     checkpoint that did not land writes no CAPPED: the build goes on with its
#     full session timeouts, and the next boundary tries again.
#     Once the PR is open (RB_PR_OPEN, set by bin/lib/rb/pr.sh) the cap is off:
#     a CAPPED there would hide PR_CREATED and re-offer a key that has a PR.
#
# The clock is the machine's own uptime (/proc/uptime): a Fly machine boots at
# spawn, and a reused machine keeps counting, which is the point of a
# per-machine cap. PS_UPTIME_S overrides it for the suites.
#
# Reads the caller's BUILD, WT, BRANCH, BASE, PROJECT, KEY, HARNESS, and its
# RESULT/STAMP functions. Every function returns 0/1 and never exits.

# ps_uptime -> whole seconds this machine has been up, or nothing.
ps_uptime() {
  local u="${PS_UPTIME_S:-}"
  [ -n "$u" ] || u=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)
  u="${u%%.*}"
  [[ "$u" =~ ^[0-9]+$ ]] && printf '%s\n' "$u"
}

# ps_cap_s -> the cap in seconds, or nothing when off (absent, 0, not a number).
ps_cap_s() {
  local c="${POOL_SOFT_CAP_S:-}"
  [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -gt 0 ] && printf '%s\n' "$c"
}

# ps_cap_due -> rc 0 when the cap is on and reached. Only in the build's own
# shell: a backgrounded review lens that hit it would end only its subshell,
# so the lens runs on and the parent's next boundary caps the build.
# PS_MAIN_PID names the build's shell when it is not $$ (the suites).
ps_cap_due() {
  local c u
  [ -z "${RB_PR_OPEN:-}" ] || return 1
  [ "${BASHPID:-$$}" = "${PS_MAIN_PID:-$$}" ] || return 1
  c=$(ps_cap_s) || return 1
  u=$(ps_uptime) || return 1
  [ "$u" -ge "$c" ]
}

# ps_cap_clamp <timeout-s> -> the timeout, cut to the time left before the cap.
# Unchanged when the cap is off, when the PR is open, and when the cap is
# already reached: CC() gets here past the cap only when ps_cap_fire could not
# land the checkpoint, and that build goes on with its full timeout.
ps_cap_clamp() {
  local to="${1:-}" c u left
  [[ "$to" =~ ^[0-9]+$ ]] || { printf '%s\n' "$to"; return 0; }
  [ -z "${RB_PR_OPEN:-}" ] || { printf '%s\n' "$to"; return 0; }
  c=$(ps_cap_s) && u=$(ps_uptime) || { printf '%s\n' "$to"; return 0; }
  left=$(( c - u )); [ "$left" -ge 1 ] || { printf '%s\n' "$to"; return 0; }
  [ "$left" -lt "$to" ] && to="$left"
  printf '%s\n' "$to"
}

# ps_plan_publish -> rc 0 when $BUILD/plan.md is published as this key's
# pre-plan (the record shape bin/run-preplan.sh publishes). rc 1 otherwise.
ps_plan_publish() {
  local d="$BUILD/handoff-plan" f
  [ -s "$BUILD/plan.md" ] || return 1
  command -v preplan_put >/dev/null 2>&1 || . "$HARNESS/bin/jobs-client.sh" 2>/dev/null
  command -v preplan_put >/dev/null 2>&1 && command -v preplan_record >/dev/null 2>&1 || return 1
  rm -rf "$d"; mkdir -p "$d" || return 1
  cp -f "$BUILD/plan.md" "$d/plan.md" || return 1
  for f in ticket-fp plan-thread-at; do [ -s "$BUILD/$f" ] && cp -f "$BUILD/$f" "$d/$f"; done
  printf '%s\n' "$KEY" > "$d/key"
  preplan_record "$d" "$WT" "$BASE" || return 1
  preplan_put "$PROJECT" "$KEY" "$d" >/dev/null
}

# ps_plan_handoff -> rc 0 when this is a plan-stage job and the plan is handed
# off (RESULT written; the caller exits 0). rc 1 = go on and execute here.
ps_plan_handoff() {
  [ "${RB_STAGE_ONLY:-}" = plan ] || return 1
  if ps_plan_publish; then
    echo "$(STAMP) [$PROJECT/$KEY] STAGE hand-off: plan published — the hub re-offers $KEY as execute on a compute machine" >> "$BUILD/pipeline.log"
    RESULT "PLANNED stage=plan $KEY"
    return 0
  fi
  echo "$(STAMP) [$PROJECT/$KEY] STAGE hand-off refused: the plan could not be published (http ${JOBS_HTTP:-none}) — executing on this machine" >> "$BUILD/pipeline.log"
  return 1
}

# ps_tree_landed -> rc 0 when the worktree's work is on origin: nothing
# uncommitted outside lane-checkpoint's excludes, and origin/$BRANCH is HEAD
# (lane-checkpoint moves that ref only after its push lands).
ps_tree_landed() {
  local -a ex=() ; local tok head remote
  for tok in ${CHECKPOINT_EXCLUDE:-node_modules .next}; do ex+=(":!$tok/*" ":!*/$tok/*"); done
  ex+=(":(exclude)__pycache__/*" ":(exclude)*/__pycache__/*" ":(exclude)*.pyc" ":(exclude)*.pyo")
  [ -z "$(git -C "$WT" status --porcelain --untracked-files=all -- . "${ex[@]}" 2>/dev/null)" ] || return 1
  head=$(git -C "$WT" rev-parse -q --verify HEAD 2>/dev/null) || return 1
  remote=$(git -C "$WT" rev-parse -q --verify "refs/remotes/origin/$BRANCH" 2>/dev/null) || return 1
  [ "$head" = "$remote" ]
}

# ps_cap_fire <stage> -> rc 0 when the build is capped (RESULT written; the
# caller exits 3). rc 1 when the checkpoint did not land: no CAPPED.
ps_cap_fire() {
  local stage="${1:-unknown}" u c rc=0 head="" wip=0 pub=no
  u=$(ps_uptime); c=$(ps_cap_s)
  if [ -n "${WT:-}" ] && [ -n "${BRANCH:-}" ] && git -C "$WT" rev-parse --git-dir >/dev/null 2>&1; then
    "$HARNESS/bin/lane-checkpoint.sh" "$BUILD" "$WT" "$BRANCH" cap >/dev/null 2>&1 || rc=$?
    if [ "$rc" != 0 ]; then
      echo "$(STAMP) [$PROJECT/$KEY] SOFT CAP reached (${u:-?}s of ${c:-?}s) but the checkpoint did not land (rc $rc) — not capped, the build goes on" >> "$BUILD/pipeline.log"
      return 1
    fi
    if ! ps_tree_landed; then
      echo "$(STAMP) [$PROJECT/$KEY] SOFT CAP reached (${u:-?}s of ${c:-?}s) but the tree is not on origin/$BRANCH (checkpoint skipped or switched off) — not capped, the build goes on" >> "$BUILD/pipeline.log"
      return 1
    fi
    head=$(git -C "$WT" rev-parse --short=12 HEAD 2>/dev/null)
    wip=$(git -C "$WT" log --format=%s "$BASE..HEAD" 2>/dev/null | grep -c '^wip: checkpoint ')
  fi
  [ "$stage" != plan ] && ps_plan_publish && pub=yes
  {
    echo "# Soft-cap brief — $KEY"
    echo
    echo "- capped at stage: $stage, after ${u:-?}s (cap ${c:-?}s)"
    echo "- branch: ${BRANCH:-none}${head:+ at $head} (${wip} wip checkpoint commit(s), pushed)"
    echo "- plan published for the next machine: $pub"
    echo "- build dir on this machine: $(basename "$BUILD")"
    echo
    echo "Last pipeline lines:"
    tail -5 "$BUILD/pipeline.log" 2>/dev/null | sed 's/^/    /'
  } > "$BUILD/brief.md"
  echo "$(STAMP) [$PROJECT/$KEY] SOFT CAP reached at $stage after ${u:-?}s — branch checkpointed, brief.md written, the hub re-offers $KEY on a fresh machine" >> "$BUILD/pipeline.log"
  RESULT "CAPPED stage=$stage after=${u:-0}s"
  return 0
}
