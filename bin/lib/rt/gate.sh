#!/bin/bash
# BH-479: the gate stage of bin/run-triage.sh, moved here verbatim by BH-479.2
# (the driver keeps its inline copy until BH-479.4); defines functions only,
# nothing runs on source. rt_gate_consume is real from BH-479.0 — shards and
# launch both need it, so it lives in the contract.
rt_gate() {
# HOTFIX INTAKE FIRST (BH-7117): open ai-build + hotfix issues are offered to
# bin/launch-fastpath.sh before the reconciler, the cost gate and every SKIP or
# hold below. Deterministic, no model call; bin/lib/triage-hotfix-lib.sh.
command -v triage_hot_intake >/dev/null 2>&1 && triage_hot_intake

# ── RECONCILE BEFORE THE GATE CAN SKIP (2026-09-15, docs/EVENTS.md §5.4) ─────
# the operator: "events are hints, reconciliation is truth". Everything above this line
# and everything below it is EDGE-TRIGGERED — the gate answers "did the board
# move since the last consumed tick", and when the answer is no the tick exits
# ten lines down without ever asking whether every open ticket is actually
# being worked. On 2026-09-15 three project-5 tickets sat for hours inside that
# blind spot (#670 closed and #671 was never keyed; #719 merged and #721 was
# never re-scoped; PR #1045 went red and nobody re-kicked TK-989) while the box
# logged `gate no-change (103 tickets)` every ten minutes, correctly.
#
# So the reconciler runs FIRST, on every tick, and the gate's SKIP is exactly
# the path it exists to cover. It is deterministic, makes no model call, costs
# three gh lists and two ledger reads, and enqueues only a ticket that has no
# owner at all (bin/orphan-reconcile.sh carries the owner rule). It is a no-op
# on in-app board projects — the `ai-build` label and the Blocked-by convention
# are GitHub-Issues things — and fails closed on anything it cannot read.
#
# Same reasoning as the staging block above: a COST gate has no business
# standing in front of free deterministic work, and an enqueue it makes is
# itself one of the inputs the gate hashes, so doing the work is also what
# tells the gate there is something to talk about.
[ "${ORPHAN_RECONCILE:-1}" = 0 ] || "$HARNESS/bin/orphan-reconcile.sh" "$PROJECT" >/dev/null 2>&1 || true

# FIRST-SEEN ANNOUNCEMENT FOR A HOTFIX (#368), for the same reason and in the
# same place: it is free, deterministic, makes no model call, and it must not
# sit behind the cost gate — an emergency ticket filed on a quiet board would
# otherwise be announced only on whichever later tick the gate decided to pay
# for on other grounds. Once per issue for life (the marker is in
# state/hotfix-announced/), so a */10 cron is safe to hook it to.
"$HARNESS/bin/hotfix-seen.sh" "$PROJECT" >/dev/null 2>&1 || true

# COMMENTED -> job_artifacts `commented` rows (BH-2526), free and deterministic
# too, and before the cost gate so a quiet board's SKIP ticks still mirror: it
# is what lets the hub's alerts groomer settle a handled build without ssh.
[ -x "$HARNESS/bin/commented-mirror.sh" ] && "$HARNESS/bin/commented-mirror.sh" "$PROJECT" >/dev/null 2>&1 || true

# Gate release (BH-3825): free and deterministic, before the cost gate.
[ -x "$HARNESS/bin/gate-release.sh" ] && "$HARNESS/bin/gate-release.sh" "$PROJECT" >/dev/null 2>&1 || true

rt_gate_pat_note_alert
# Deterministic gate (cost lever): skip the LLM session when nothing changed.
# Fail-open — any gate uncertainty runs the session.
GATE_DECISION=$("$HARNESS/bin/triage-gate.sh" "$PROJECT" 2>>"$ALERTS" || echo "RUN gate-error")
# Starved-ready alarm (BH-3970): free, deterministic, on every tick before a SKIP
# exits — a ready ticket nothing owns is exactly what a no-change tick hides.
[ -r "$HARNESS/bin/lib/starved-ready.sh" ] && ( . "$HARNESS/bin/lib/starved-ready.sh" && starved_ready_check "$HARNESS" "$PROJECT" ) >/dev/null 2>&1 || true
# >>> triage preconditions (P2, 2026-09-25) — health + per-project throttle,
# bin/lib/triage-throttle.sh. The gate's answer feeds the board-fetch streak on
# EVERY tick (a SKIP no-change is a board read that worked), and a RUN that
# needs the board is only bought when the project can produce a build; any RUN
# is only bought inside the project's cadence and ceiling. The ceiling counts
# PAID launches (rt_launch / the shard dispatch), never this answer. A hold is a
# decision, so the lane reports it `paused`, not `skip`. Absent lib = today.
[ -r "$HARNESS/bin/lib/triage-throttle.sh" ] && . "$HARNESS/bin/lib/triage-throttle.sh"
command -v triage_health_note >/dev/null 2>&1 && triage_health_note "$HARNESS" "$PROJECT" "$GATE_DECISION"
if [ "${GATE_DECISION%% *}" != "SKIP" ] && command -v triage_precondition >/dev/null 2>&1 \
   && ! TT_WHY=$(triage_precondition "$HARNESS" "$PROJECT" "$GATE_DECISION"); then
  case "$TT_WHY" in "health: "*) triage_health_warn_once "$HARNESS" "$PROJECT" "${TT_WHY#health: }" "$ALERTS" ;; esac
  LANE_TICK paused
  # BH-3953: the gate stamped sweepfp when it said RUN results-sweep; a held
  # sweep ran no session, so the stamp would read the set as swept for 45m.
  [ "$GATE_DECISION" = "RUN results-sweep" ] && rm -f "$HARNESS/state/$PROJECT.sweepfp"
  echo "$STAMP [$PROJECT] rc=skip :: gate ${GATE_DECISION} held — $TT_WHY" >> "$LOG"
  exit 0
fi
# <<< triage preconditions
if [ "${GATE_DECISION%% *}" = "SKIP" ]; then
  # A SKIP IS A HEARTBEAT. The gate finding nothing changed is the normal shape
  # of a healthy quiet board — most ticks on most lanes are this — and it claims
  # no job and spends nothing. If only the expensive ticks counted as life, every
  # quiet lane in the fleet would page.
  LANE_TICK skip
  echo "$STAMP [$PROJECT] rc=skip :: gate ${GATE_DECISION#SKIP }" >> "$LOG"
  exit 0
fi
}

# rt_gate_pat_note_alert — BH-2133 review (I2). On a GitHub-Issues board the
# gate absorbs a note only when one of the harness's own Apps wrote it
# (bin/lib/harness-self.sh). A tick whose shards will post with the box's PAT
# (no App installation token was armed above: env/github-app.env missing,
# GH_APP_TOKENS=0, a mint that failed) posts notes as operator, which the gate
# cannot tell from the operator and so treats as a client turn: that is the loop again,
# one note per tick. Say so, once per project per UTC day. No App token on an
# in-app board is not this problem (those notes go through the board API).
rt_gate_pat_note_alert() {
  local h="${HARNESS:-/root/harness}" bp flag
  case "${GH_TOKEN:-}" in ghs_*) return 0 ;; esac
  bp=$("$h/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null) || return 0
  [ "$bp" = - ] || return 0
  flag="$h/flags/alerted-pat-note-$PROJECT-$(date -u +%Y%m%d)"
  [ -e "$flag" ] && return 0
  mkdir -p "$h/flags" "$h/logs" 2>/dev/null; touch "$flag" 2>/dev/null
  printf '%s [%s] triage: this tick has no GitHub App installation token, so its shards post ticket notes with the box PAT (as the PAT login). The triage gate cannot tell those notes from a person and re-triages on each one (BH-2133). Arm env/github-app.env for this project or check bin/gh-token.sh; this line repeats once a day while it lasts.\n' \
    "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$PROJECT" >> "${ALERTS:-$h/logs/ALERTS.log}"
  return 0
}

# _rt_tgl — load bin/lib/triage-gate-ledger.sh (BH-2318) on first use, so this
# module still runs nothing on source. rc 1 when the lib is not there: every
# caller then does exactly what it did before the ledger twin existed.
_rt_tgl() {
  command -v tgl_put_gate >/dev/null 2>&1 && return 0
  local f
  for f in "$(dirname "${BASH_SOURCE[0]}")/../triage-gate-ledger.sh" "$HARNESS/bin/lib/triage-gate-ledger.sh"; do
    # shellcheck source=/dev/null
    [ -r "$f" ] && { . "$f"; break; }
  done
  command -v tgl_put_gate >/dev/null 2>&1
}

rt_gate_consume() { # a consumed tick always absorbs the pending fingerprint; only a full tick stamps the full-sweep clock
  [ -f "$HARNESS/state/$PROJECT.gate.pending" ] && mv -f "$HARNESS/state/$PROJECT.gate.pending" "$HARNESS/state/$PROJECT.gate.json"
  # BH-2751: SCOPE_N=full (unset counts as full) is a tick that ran the whole
  # SOP. A scoped tick (shards, queue, sweep, a board diff) did not enumerate the
  # board, so stamping for it pushed the daily sweep back on every wake and a
  # board woken more than once a day never got one.
  if [ "${SCOPE_N:-full}" = full ]; then date +%s > "$HARNESS/state/$PROJECT.gate-meta"; fi
  # BH-2318: file first, row second — the consumed state follows the project to
  # whichever box owns it next. A failed or dark write is rc 0.
  _rt_tgl && tgl_put_gate "$HARNESS" "$PROJECT"
  return 0
}

# BH-1021: A SESSION THAT FAILS EVERY TIME MUST STOP BEING BOUGHT EVERY TICK.
# Only rc=0 consumed the pending fingerprint, so a lane whose triage session
# died on every attempt left the same pending file in place, the next gate
# diffed the same board against the same old gate.json, answered RUN
# board-changed again, and bought the identical failing session ten minutes
# later — 1,168 rc!=0 triage rows on ONE fingerprint on project-5 on
# 2026-09-17. Three attempts is a fair try; the fourth is just money.
#
# So consecutive rc!=0 exits are counted per pending-fingerprint sha, and at the
# cap the tick consumes the fingerprint ANYWAY (same rt_gate_consume the success
# path calls), drops the counter and alerts once. A success clears the counter; a
# different fingerprint restarts it at 1, because a new board state deserves its
# own attempts. Failing is never recorded as success (D9): the log line and the
# alert both say rc!=0, and the only thing borrowed from the success path is the
# absorb.
rt_gate_fail_consume() { # rc!=0: count this failure, and at the cap consume the fingerprint anyway
  local cap="${TRIAGE_FAIL_CONSUME_AFTER:-3}" pend="$HARNESS/state/$PROJECT.gate.pending" \
        ff="$HARNESS/state/$PROJECT.gate.fail" sha n old stuck
  # A knob nobody can read must never be the thing that keeps paying, so garbage
  # reads as the default rather than as "no cap".
  case "$cap" in ''|*[!0-9]*) cap=3 ;; esac
  [ "$cap" -eq 0 ] && return 0                       # off: today's behaviour, never consume on failure
  if [ -s "$pend" ]; then sha=$(sha256sum < "$pend" | cut -c1-16); else sha=none; fi
  old=""; n=0
  # BH-2318: a box with no counter file continues the project's streak from
  # its ledger row (the old box's attempts count); a cleared or missing row is 0.
  [ -e "$ff" ] || { _rt_tgl && tgl_hydrate_fail "$HARNESS" "$PROJECT"; }
  [ -f "$ff" ] && { old=$(head -1 "$ff"); n=$(sed -n 2p "$ff"); }
  case "$n" in ''|*[!0-9]*) n=0 ;; esac                # hand-edited or truncated: this failure is attempt 1
  if [ "$old" = "$sha" ]; then n=$((n+1)); else n=1; fi
  if [ "$n" -lt "$cap" ]; then
    printf '%s\n%s\n' "$sha" "$n" > "$ff"
    _rt_tgl && tgl_put_fail "$HARNESS" "$PROJECT"
    echo "$STAMP [$PROJECT] triage rc=$RC: fingerprint $sha NOT consumed, failed attempt $n/$cap (consumed anyway at $cap)" >> "$LOG"
    return 0
  fi
  # ORDER MATTERS: consume first, then drop the counter, then say so. If the
  # alert cannot be sent the consume still stands and a raw ALERTS.log line is
  # written, so "consumed with nothing recorded" cannot happen. The no-pending
  # shape (daily-sweep/forced/no-gate-state) rides the same path: there is
  # nothing to absorb, but stamping the full-sweep clock (a full tick) is what
  # ends ITS loop.
  rt_gate_consume; rm -f "$ff"; _rt_tgl && tgl_clear_fail "$HARNESS" "$PROJECT"
  echo "$STAMP [$PROJECT] triage rc=$RC: fingerprint $sha consumed after $n failed attempts — the board state it carried is not re-offered until it changes again or the daily sweep" >> "$LOG"
  "$HARNESS/bin/lane-alert.sh" --id "triage-fail-consume:$PROJECT" --severity warn triage \
    "[$PROJECT] the triage session exited rc!=0 $n times in a row on the same board fingerprint ($sha); consumed it anyway so the tick stops buying the same failure every cron tick. The tickets that fingerprint carried are not re-offered until they change or the daily sweep (FULL_SWEEP_SECS). What to read next: $OUT — the failing session's own output. Raise or disable the cap with TRIAGE_FAIL_CONSUME_AFTER in env/global.env." \
    >/dev/null 2>&1 \
    || echo "$STAMP [$PROJECT] triage fingerprint $sha consumed after $n failed attempts and bin/lane-alert.sh did not run" >> "$ALERTS"
  # BH-3920: when the failures were the call-guard refusing the same full
  # triage prompt, say WHICH keys keep that prompt alive and why, once per
  # streak (this branch runs once and drops the counter). ts_stuck_line is
  # bin/lib/triage-state.sh, sourced in this shell by bin/lib/rt/shards.sh.
  if grep -q '^AGENT_CALL_REFUSED call-guard repeat' "$OUT" 2>/dev/null; then
    if command -v ts_stuck_line >/dev/null 2>&1; then stuck=$(ts_stuck_line "$PROJECT" "$n" "$sha")
    else stuck="[$PROJECT] triage is stuck: the call-guard refused the same full triage $n times (fingerprint $sha). Reason: the triage-state lib is not loaded, so the keys cannot be named. Read: logs/call-guard.log."; fi
    "$HARNESS/bin/lane-alert.sh" --id "triage-stuck:$PROJECT" --severity warn triage "$stuck" >/dev/null 2>&1 \
      || ALERT_LINE_STAMP="$STAMP" "$HARNESS/bin/alert-line.sh" --severity warn --project "$PROJECT" "$stuck"
  fi
}

# >>> pauses (BH-1672 / BH-1684) — the triage and builds rows of the pauses
# table, read ONLY through bin/lib/pause.sh (pause_why in pause-rows.sh adds the
# reason and age). No lib, or an unreadable cache, is not paused: the tick runs
# exactly as it did before BH-1672. Here rather than inline because the driver
# is capped at 380 lines (tests/rt-split-layout-test.sh).
#
# rt_pause_triage — called right after the paused-<project> flag check. A live
# triage row ends the tick the way that flag does (exit 0, the fail-open hotfix
# line, LANE_TICK paused), before rt_stage, rt_gate, the job claim and the agent
# call. Refreshes the cache once per tick first.
rt_pause_triage() {
  if [ -r "$HARNESS/bin/lib/pause.sh" ] && [ -r "$HARNESS/bin/lib/pause-rows.sh" ]; then
    . "$HARNESS/bin/lib/pause.sh"; . "$HARNESS/bin/lib/pause-rows.sh"
  else
    pause_active() { return 1; }; pause_refresh() { return 0; }; pause_why() { return 0; }
  fi
  pause_refresh || true
  pause_active "$PROJECT" triage || return 0
  "$HARNESS/bin/hotfix-seen.sh" "$PROJECT" --paused >/dev/null 2>&1 || true
  LANE_TICK paused; echo "$STAMP [$PROJECT] PAUSED(triage) $(pause_why "$PROJECT" triage) — skipping" >> "$LOG"; exit 0
}
# rt_pause_builds — called right after the overlap guard, before SHARD_SOP is
# taken from PROMPT_TEXT, so the single session and every shard carry it. A
# live builds row lets triage run and appends a directive forbidding any
# run-build.sh launch this tick. A PROMPT DIRECTIVE, NOT A BLOCK: every launch
# on this path is made by the agent, so there is no launch site here to guard,
# and a queue tick, a Fly pool launch or a hand launch never reads it.
rt_pause_builds() {
  pause_active "$PROJECT" builds || return 0
  local why; why=$(pause_why "$PROJECT" builds)
  echo "$STAMP [$PROJECT] PAUSED(builds) $why — triage runs; run-build launches withheld by prompt directive (not enforced at run-build.sh)" >> "$LOG"
  PROMPT_TEXT="$PROMPT_TEXT

BUILDS PAUSED (BH-1672): a live builds pause covers $PROJECT ($why). Triage this tick as usual, but launch NO run-build.sh this tick, including relaunches and STACK_BASE launches. Leave every queue line where it is and treat free build slots as 0. The next tick re-checks the pause and re-offers the queue."
}
# <<< pauses

# >>> dispatch mode (BH-6350)
# rt_dispatch_mode — called right after rt_pause_builds, before SHARD_SOP is
# taken from PROMPT_TEXT. In dispatch mode hotfix-only (bin/lib/dispatch-mode.sh)
# triage still runs, because the results sweep and close-outs must, but the
# prompt is told to launch run-build.sh only for a hotfix-labelled or
# allow-listed ticket. bin/lib/rb/gates.sh `# >>> dispatch mode gate` enforces
# the same rule at the launch, so this directive saves the agent's turns and is
# not the guard. Also runs the age alert (dm_age_alert), which resolves itself
# on any other mode. One log line per tick in hotfix-only; nothing otherwise.
rt_dispatch_mode() {
  [ -r "$HARNESS/bin/lib/dispatch-mode.sh" ] && . "$HARNESS/bin/lib/dispatch-mode.sh" 2>/dev/null
  command -v dm_read >/dev/null 2>&1 || return 0
  dm_read "$PROJECT"
  [ "$DM_UNREADABLE" = 1 ] && echo "$STAMP [$PROJECT] dispatch mode unreadable, reading normal" >> "$LOG"
  dm_age_alert "$PROJECT"
  [ "$DM_MODE" = hotfix-only ] || return 0
  local lbl=hotfix allow
  command -v hotfix_label >/dev/null 2>&1 && lbl=$(hotfix_label "$HARNESS")
  allow=$(dm_allow_text)
  echo "$STAMP [$PROJECT] DISPATCH-MODE hotfix-only (allow-list: $allow) — triage runs; only hotfix or allow-listed tickets may launch" >> "$LOG"
  PROMPT_TEXT="$PROMPT_TEXT

DISPATCH MODE hotfix-only (BH-6350): $PROJECT builds only tickets with the \`$lbl\` label or issue numbers $allow. Launch run-build.sh for no other ticket this tick. Leave every other ticket as it is: keep its ai-build label, post no comment, write no queue line. Results sweep, close-outs and open-PR work run as usual."
}
# <<< dispatch mode
