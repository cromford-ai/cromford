#!/bin/bash
# BH-479: the shard fan-out stage of bin/run-triage.sh, moved here verbatim
# by BH-479.3 (#566); defines functions only, nothing runs on source.
rt_shards() {
# >>> triage state (TRIAGE-STATE, docs/TRIAGE-STATE.md)
# THE PER-TICKET PRE-CHECK, before any unit is formed and before any money is
# spent: every open ticket's input hash against the hash its stored verdict was
# made against (the triage_state rows). In shadow (the default) it only logs
# and records what it would do. In enforce it may end this tick at $0 (nothing
# changed), launch an unchanged buildable ticket with no model call, drop an
# unchanged key from the shard loop (ts_unit_skip below) and tell the single
# session which tickets not to re-triage. No lib = the tick exactly as before.
[ -r "$HARNESS/bin/lib/triage-state.sh" ] && . "$HARNESS/bin/lib/triage-state.sh" && ts_tick
# <<< triage state
# >>> triage shards
# ONE SESSION PER TICKET, NOT PER TICK (the operator, 2026-09-14 04:2xZ: "can we get
# multiple triagers like we have multiple builders? ... do that").
#
# Everything above this line is what the tick has always been, and stays exactly
# that: the pause flags, the staging of finished builds, the deterministic gate,
# the scope computation, the ledger claim, the contract. What changes is the last
# step. Instead of ONE agent call over the WHOLE scope — every changed thread,
# every queue line and every result dir read one after another inside a 10800s
# timeout, with the next tick bouncing off the per-project flock for as long as it
# ran — the scope is split by TICKET KEY and each key gets its own detached
# session. The dispatcher exits in seconds, so the flock it holds now guards the
# dispatch and nothing else.
#
# A UNIT IS A TICKET, and the three lists are merged ON that ticket: a key whose
# thread moved, whose queue line is pending and whose build just finished is ONE
# shard doing all three, because that is one conversation with one client.
#
# DEDUPE, NEVER A QUEUE (the operator, 2026-09-13). A key whose shard lock is held is
# already being triaged: skip it this tick and launch everything else
# immediately. Nothing here waits for anything.
#
# FAIL-OPEN IN EVERY DIRECTION — shards disarmed, no scope adopted (a full-SOP
# tick is the enumeration that PRODUCES a scope, so it stays one session), a
# scope line this dispatcher cannot place, a queue line that belongs to another
# lane on this box and cannot be told apart: each of them drops through to the
# single agent call below, byte for byte what this file has always run.
SHARD_ON=0
# (the lib is sourced at the top of this file — three decisions above this block
# read it, and a file sourced after its first caller is not there for them)
command -v triage_shards_on >/dev/null 2>&1 && [ "$(triage_shards_on "$HARNESS")" = 1 ] && SHARD_ON=1
# A tick with no adopted scope is a full sweep: it is the enumeration, it is
# cheap relative to what it produces, and it is what gives the NEXT tick its
# shards. Splitting it would mean splitting a list nobody has computed yet.
[ "$SCOPE_N" = full ] && SHARD_ON=0
# A WAKE THAT NAMED NOTHING NEVER FANS OUT. Its scope is whatever the
# deterministic pass printed, which is a list of launchable children rather than
# a list of threads to read — one session handles it, and a doorbell press must
# never be able to buy N. (A wake that DID name its objects shards normally: the
# scope is one or two keys, which is one or two sessions.)
[ "${EW_NO_SHARDS:-0}" = 1 ] && SHARD_ON=0
SHARD_UNITS=""
if [ "$SHARD_ON" = 1 ]; then
  SHARD_GH=$(triage_shard_gh "$HARNESS" "$PROJECT")
  SHARD_RUNNER="${RUNNER_TRIAGE:-claude}"
  command -v triage_shard_runner >/dev/null 2>&1 && SHARD_RUNNER=$(triage_shard_runner "$HARNESS")
  SHARD_DIR="$HARNESS/state/triage-shards/$PROJECT"
  SHARD_UNITS="$SHARD_DIR/.units"
  mkdir -p "$SHARD_DIR" && : > "$SHARD_UNITS" || SHARD_ON=0
fi
if [ "$SHARD_ON" = 1 ]; then
  # This box's own projects, for the one scope input that is NOT project-scoped:
  # logs/READY-QUEUE.log is box-global and a line from another lane rides along in
  # QLINES. The single session was told to ignore foreign keys; a dispatcher
  # cannot, because ignoring one wrongly means a client ticket goes untriaged and
  # acting on one wrongly means paying for a session on another lane's board. So
  # the registry answers it (bin/project-of.sh, the same call bin/preplan-tick.sh
  # makes), and a line the registry cannot place is only assumed ours on a box
  # that owns exactly one project.
  SHARD_BOX_PROJECTS=$("$HARNESS/bin/fleet-conf.sh" --projects-on-box \
    "$("$HARNESS/bin/box-name.sh" 2>/dev/null)" 2>/dev/null | grep -c . 2>/dev/null)
  case "$SHARD_BOX_PROJECTS" in ''|*[!0-9]*) SHARD_BOX_PROJECTS=0 ;; esac
  shard_line_mine() { # shard_line_mine <line> -> 0 ours | 1 another lane's | 2 unknown
    local p
    p=$("$HARNESS/bin/project-of.sh" "$1" 2>/dev/null) || { [ "$SHARD_BOX_PROJECTS" = 1 ] && return 0; return 2; }
    [ "$p" = "$PROJECT" ] && return 0
    return 1
  }
  # <canon-key>\t<class>\t<the scope line, verbatim>. ONE unplaceable line
  # abandons the whole split: a scope line assigned to no shard is a client
  # comment nobody reads, and the single session below has always read all of them.
  shard_collect() { # shard_collect <class> <text> [filter-foreign]
    local cls="$1" line k
    [ -n "${2:-}" ] || return 0
    while IFS= read -r line; do
      case "$line" in ''|'(none)') continue ;; esac
      # The ordering marker comes OFF before anything reads the line. Every key
      # regex in bin/lib/triage-shards-lib.sh anchors at the start of the line,
      # so a `[HOTFIX] ` prefix would make triage_shard_key return 1, which makes
      # this function return 1, which abandons the whole split and silently runs
      # the single session on every tick that has a hotfix. This is the single
      # funnel for every marked list, which is why the strip lives here and the
      # lib is untouched.
      line=${line#'[HOTFIX] '}
      if [ "${3:-}" = filter ]; then
        shard_line_mine "$line"; case $? in 0) ;; 1) continue ;; *) return 1 ;; esac
      fi
      k=$(triage_shard_key "$cls" "$PROJECT" "$SHARD_GH" "$line") || return 1
      printf '%s\t%s\t%s\n' "$k" "$cls" "$line" >> "$SHARD_UNITS"
    done <<<"$2"
    return 0
  }
  # BOARD_SEC's first line is its own header sentence, not a ticket.
  SHARD_ALSO=$(printf '%s' "${BOARD_SEC:-}" | tail -n +2)
  if ! { shard_collect board "${TICK_SCOPE:-}" && shard_collect board "$SHARD_ALSO" \
      && shard_collect queue "${QLINES:-}" filter && shard_collect queue "${QDIRS:-}" \
      && shard_collect result "${RDIRS:-}"; }; then
    echo "$STAMP [$PROJECT] triage shards: a scope line this dispatcher could not place (no ticket key, or a queue line whose lane it cannot tell) — running the single session for this tick instead" >> "$LOG"
    SHARD_ON=0
  fi
  [ -s "$SHARD_UNITS" ] || SHARD_ON=0
fi
[ "$SHARD_ON" = 1 ] || { [ -n "$SHARD_UNITS" ] && rm -f "$SHARD_UNITS"; }
if [ "$SHARD_ON" = 1 ]; then
  # CLIENT-COURT GUARD (BH-411): before launching any shard, drop keys whose
  # tickets are waiting on the client, not ready, or whose newest comment is
  # from the harness/system. Board scope lines already carry the raw ticket
  # id; queue/result lines carry the board key and are resolved through the
  # id<->key mapping the gate persists. Fail-open: any resolution failure keeps
  # the line in scope.
  # >>> client-court guard
  if [ -s "$SHARD_UNITS" ]; then
    _filtered=$(mktemp)
    _blocked=""
    while IFS='	' read -r _k _cls _line; do
      _tid="$_k"
      if [ "$_cls" != "board" ]; then
        # THE QUEUE ROW NAMES ITS OWN TICKET, so it is asked first (BH-1042,
        # audit fact #33). state/build-queue/<p>/<KEY>.json is written by
        # bin/fly-dispatch.sh at enqueue time and carries the ticket this unit
        # is really about; the keymap is a rebuilt-every-tick index that can be
        # stale or, on a fetch failure, not rebuilt at all. `-`/`null`/empty is
        # the dispatcher's placeholder, not an answer — it falls through.
        _tid=""
        _qf="$HARNESS/state/build-queue/$PROJECT/$_k.json"
        if [ -s "$_qf" ]; then
          _tid=$(jq -r '.ticket_id // ""' "$_qf" 2>/dev/null) || _tid=""
        fi
        case "$_tid" in -|null) _tid="" ;; esac
        if [ -z "$_tid" ] && [ -s "$HARNESS/state/$PROJECT.keymap.json" ]; then
          _tid=$(jq -r --arg k "$_k" '.[$k] // ""' "$HARNESS/state/$PROJECT.keymap.json" 2>/dev/null) || _tid=""
        fi
      fi
      if [ -n "$_tid" ]; then
        _gb=$("$HARNESS/bin/triage-gate.sh" "$PROJECT" --buildable "$_tid" 2>/dev/null) || _gb="OK"
      else
        _gb="OK"
      fi
      case "$_gb" in
        BLOCKED*) _blocked="$_blocked $_k ($_gb)" ;;
        *) printf '%s	%s	%s
' "$_k" "$_cls" "$_line" >> "$_filtered" ;;
      esac
    done < "$SHARD_UNITS"
    if [ -n "$_blocked" ]; then
      echo "$STAMP [$PROJECT] triage shards: client-court skipped$_blocked" >> "$LOG"
    fi
    mv -f "$_filtered" "$SHARD_UNITS"
    [ -s "$SHARD_UNITS" ] || SHARD_ON=0
  fi
  # <<< client-court guard
fi

if [ "$SHARD_ON" = 1 ]; then
  # THE CAP IS OPT-IN AND IT IS NOT A QUEUE. TRIAGE_SHARDS_MAX defaults to 0 =
  # unlimited, so by default no census runs and no shard is ever withheld. Set
  # above zero on a box that wants a ceiling, and a unit over the cap is LEFT IN
  # SCOPE — re-armed below, offered again next tick — never parked in a list.
  SHARD_MAX=$(triage_shards_max "$HARNESS")
  SHARD_INFLIGHT=0
  if [ "$SHARD_MAX" -gt 0 ]; then
    for L in "$HARNESS"/locks/triage-key-*.lock; do
      triage_shard_held "$L" && SHARD_INFLIGHT=$((SHARD_INFLIGHT+1))
    done
  fi
  # ── THE RATE CEILINGS (2026-09-14, the shard storm) ───────────────────────
  # TRIAGE_SHARDS_MAX above is a CONCURRENCY cap and it was never the missing
  # brake: the 190 sessions of the 19Z hour arrived over ~13 ticks and rarely more
  # than a dozen overlapped, so any plausible concurrency number would have let
  # every one of them through. What ran away was the RATE, per project, per hour —
  # in sessions and in dollars — and nothing anywhere counted either.
  #
  # Both are OFF by default since 2026-09-15 (the operator: everything unlimited; the
  # 30/h ceiling was deferring real project-5 tickets tick after tick). With
  # TRIAGE_SHARD_CAPS=1 they behave like every other ceiling in this file: a
  # unit over the cap is LEFT IN SCOPE and re-offered next tick, never parked
  # in a queue. flags/triage-shard-caps-off removes them regardless.
  SHARD_CAPS=0; SHARD_PH=0; SHARD_UCAP=0; SHARD_HN=0; SHARD_HUSD=0; SHARD_CAPHIT=""
  if command -v triage_caps_on >/dev/null 2>&1 && [ "$(triage_caps_on "$HARNESS")" = 1 ]; then
    SHARD_CAPS=1
    SHARD_PH=$(triage_shards_per_hour "$HARNESS")
    SHARD_UCAP=$(triage_shard_usd_per_hour "$HARNESS")
    SHARD_HN=$(triage_hour_count "$HARNESS" "$PROJECT")
    SHARD_HUSD=$(triage_hour_usd "$HARNESS" "$PROJECT")
  fi
  SHARD_LAUNCHED=""; SHARD_HELD=""; SHARD_LEFT=""; SHARD_SAME=""; SHARD_NOSIG=""; SHARD_TSS=""; SHARD_N=0; SHARD_HELD_N=0
  # BH-9113: the running builds, read ONCE per tick (bin/lib/shard-building.sh).
  # A key with a running build gets no shard below: its claim would refuse it.
  # No lib = today; an unreadable census skips nothing.
  SHARD_BUILD=""; SHARD_BCENSUS=""
  if [ -r "$HARNESS/bin/lib/shard-building.sh" ] && . "$HARNESS/bin/lib/shard-building.sh"; then
    SHARD_BCENSUS="$SHARD_DIR/.building.tsv"
    shard_building_census "$HARNESS" "$PROJECT" "$SHARD_BCENSUS"
    grep -qx '#unreadable' "$SHARD_BCENSUS" 2>/dev/null \
      && echo "$STAMP [$PROJECT] triage shards: running-build census unreadable — no key skipped for a running build this tick (the claim stays the backstop)" >> "$LOG"
  fi
  # BH-2542: the no-signal settle (bin/lib/triage-signal.sh). No lib = today.
  [ -r "$HARNESS/bin/lib/triage-signal.sh" ] && . "$HARNESS/bin/lib/triage-signal.sh"
  SHARD_FPTTL=0
  command -v triage_shard_fp_ttl >/dev/null 2>&1 && SHARD_FPTTL=$(triage_shard_fp_ttl "$HARNESS")
  SHARD_FPNEXT="${SHARD_FPTTL}s"
  [ "$SHARD_FPTTL" -ge 60 ] && SHARD_FPNEXT="$(( SHARD_FPTTL / 60 ))m"
  # ONCE PER TICK, NEVER PER KEY. The PR states every key's fingerprint reads
  # are refreshed here, in one pass: first for free out of the gate's own
  # lookup, then — only for numbers the gate has not refreshed inside its 45
  # minute window — with one REST call each, capped at 20 like the gate's. Per
  # key this would be N times the API budget for one answer.
  if [ "$SHARD_FPTTL" -gt 0 ] && command -v triage_prstates_ingest >/dev/null 2>&1; then
    triage_prstates_ingest "$HARNESS" "$PROJECT" || true
    triage_prstates_refresh "$HARNESS" "$PROJECT" "$SHARD_UNITS" || true
    # and one locked rewrite dropping the entries no queue line has named for a
    # week — the ledger is otherwise bounded only by every PR number this
    # project has ever blocked on.
    command -v triage_prstates_prune >/dev/null 2>&1 \
      && { triage_prstates_prune "$HARNESS" "$PROJECT" || true; }
  fi
  for K in $(cut -f1 "$SHARD_UNITS" | awk '!seen[$0]++'); do
    if triage_shard_held "$HARNESS/locks/triage-key-$PROJECT-$K.lock"; then
      SHARD_HELD="$SHARD_HELD $K"; SHARD_HELD_N=$((SHARD_HELD_N+1)); continue
    fi
    # TRIAGE-STATE (enforce only): a key whose inputs have not moved since its
    # verdict, and whose only units are board units, is not bought. Consumed
    # like an unchanged key below, never re-armed: there is nothing to put back.
    if command -v ts_unit_skip >/dev/null 2>&1 && ts_unit_skip "$SHARD_UNITS" "$K"; then
      SHARD_TSS="$SHARD_TSS $K"; continue
    fi
    # >>> per-ticket fingerprint
    # THE DEDUP THAT RUNS BEFORE THE MONEY (BH-1015). Everything below this
    # block spends: the prompt is composed, a session is detached, a cost row
    # lands. The tick-level queuefp brake upstream is all-or-nothing — one
    # ticket's line gaining a word un-brakes the tick and every OTHER key in
    # scope is re-bought having not moved at all. That is the $896/day the
    # 2026-09-17..19 audit found, and it is invisible in every log because each
    # individual session looks like an ordinary no-action triage.
    #
    # So each key is asked the only question that matters before its session is
    # bought: has this exact world already been handed to a shard, recently?
    # The fingerprint and its three outcomes live in
    # bin/lib/triage-shards-lib.sh; a key with no computable fingerprint, or an
    # unreadable stamp, DISPATCHES — this brake may cost the fleet a duplicate
    # session, never a client's answer. The tick brake stays exactly where it
    # is, as the backstop it has always been.
    SHARD_FP=""; SHARD_SFP=""; SHARD_TURN=""
    if [ "$SHARD_FPTTL" -gt 0 ] && command -v triage_shard_fp >/dev/null 2>&1; then
      SHARD_FP=$(triage_shard_fp "$HARNESS" "$PROJECT" "$K" "$SHARD_GH" "$SHARD_UNITS" 2>/dev/null) || SHARD_FP=""
    fi
    if [ -n "$SHARD_FP" ]; then
      triage_shard_fp_fresh "$HARNESS" "$PROJECT" "$K" "$SHARD_FP"; SHARD_FPRC=$?
      case "$SHARD_FPRC" in
        0) echo "$STAMP [$PROJECT] triage shards: $K unchanged since the last shard — same queue line (ISO stamps and session prose aside), same live board entry, same state for every PR it names, same build dirs; no session bought. Next re-read on any real change, or in at most $SHARD_FPNEXT." >> "$LOG"
           SHARD_SAME="$SHARD_SAME $K"
           # A SKIPPED KEY IS NOT RE-ARMED, and that is the honest state rather
           # than a saving. The fingerprint now reads this ticket's own entry in
           # the LIVE board fingerprint, so fp-fresh MEANS the thread has not
           # moved since the shard that was handed this exact world — there is
           # nothing to put back. Re-arming anyway (the first cut of this PR)
           # kept the key permanently absent from state/<p>.gate.json, where
           # bin/gate-diff.sh describes it as `NEW <id> "<title>"` — a line that
           # is byte-identical at five comments and at six. A client's reply
           # then never moved the input and was skipped for the whole TTL, on a
           # webhook wake as well, because the wake scopes off the same line.
           continue ;;
        2) echo "$STAMP [$PROJECT] triage shards: $K fingerprint file unreadable (state/triage-shards/$PROJECT/$K.fp) — dispatching anyway and restamping; a corrupt ledger must never read as 'already paid'" >> "$LOG" ;;
      esac
      # THE NO-SIGNAL SETTLE (BH-2542). The world moved, but maybe only through
      # our own comments, labels or the waitingOn/triageVerdict a session wrote.
      # Equal signal fingerprints = no human wrote anything since the last paid
      # shard: restamp with the OLD epoch (the TTL backstop still fires) and buy
      # nothing. Not re-armed, for the same reason as the rc-0 skip above.
      if command -v triage_signal_sfp >/dev/null 2>&1 \
         && triage_signal_sfp "$HARNESS" "$PROJECT" "$K" "$SHARD_GH" "$SHARD_UNITS"; then
        SHARD_SFP="$TRIAGE_SIGNAL_SFP"; SHARD_TURN="$TRIAGE_SIGNAL_TURN"
        if [ "$SHARD_FPRC" = 1 ] && triage_signal_settled "$HARNESS" "$PROJECT" "$K" "$SHARD_SFP" "$SHARD_TURN"; then
          triage_signal_restamp "$HARNESS" "$PROJECT" "$K" "$SHARD_FP" "$SHARD_SFP" "$SHARD_TURN" || true
          triage_signal_count "$HARNESS" "$PROJECT" "$K"
          echo "$STAMP [$PROJECT] triage shards: $K no-signal — the ticket moved, but no human wrote anything since the last shard (our own comments, labels, a waitingOn flip away from the team, triageVerdict aside); no session bought, one \$0 triage-precheck row in logs/cost.csv. Re-read on the next human change, or in at most $SHARD_FPNEXT from that shard." >> "$LOG"
          SHARD_NOSIG="$SHARD_NOSIG $K"
          continue  # no-signal settle
        fi
      fi
    fi
    # <<< per-ticket fingerprint
    # BH-9113: a running build owns the ticket. Before any slot or cap, and
    # before the fingerprint is stamped: re-armed below, offered again next tick.
    if [ -n "$SHARD_BCENSUS" ] && SHARD_BWHY=$(shard_building_why "$HARNESS" "$PROJECT" "$SHARD_GH" "$SHARD_BCENSUS" "$K"); then
      echo "$STAMP [$PROJECT] triage shards: $K skipped — build running ($SHARD_BWHY); no shard bought, no slot used, re-offered next tick" >> "$LOG"
      SHARD_BUILD="$SHARD_BUILD $K"; continue
    fi
    if [ "$SHARD_MAX" -gt 0 ] && [ "$SHARD_INFLIGHT" -ge "$SHARD_MAX" ]; then
      SHARD_LEFT="$SHARD_LEFT $K"; continue
    fi
    # The dollar ceiling is checked against the rows that already exist, not
    # against a forecast: the shards this tick launches bill while they run, so
    # the number only moves for the NEXT tick. That is deliberate — a cap that
    # guessed what a session will cost would be a cap on a number nobody wrote.
    if [ "$SHARD_CAPS" = 1 ]; then
      if [ "$SHARD_PH" -gt 0 ] && [ "$SHARD_HN" -ge "$SHARD_PH" ]; then
        SHARD_CAPHIT="${SHARD_HN}/${SHARD_PH} shards per hour"
        SHARD_LEFT="$SHARD_LEFT $K"; continue
      fi
      if triage_usd_over "$SHARD_HUSD" "$SHARD_UCAP"; then
        SHARD_CAPHIT="\$$SHARD_HUSD/\$$SHARD_UCAP per hour"
        SHARD_LEFT="$SHARD_LEFT $K"; continue
      fi
    fi
    # >>> shard overlap verdict
    # This shard's own line of the tick's overlap schedule (BH-475). Asked per
    # key rather than handing every shard the whole graph: a shard owns exactly
    # one ticket, and the other keys' waves are another session's business.
    # Fail-open like the tick's own feed — no script, no answer, no sentence.
    # Marker-delimited so tests/overlap-schedule-test.sh drives these exact
    # lines against a stub scheduler instead of grepping the source for them.
    SHARD_OV=""
    [ -x "$HARNESS/bin/overlap-schedule.sh" ] && \
      SHARD_OV=$("$HARNESS/bin/overlap-schedule.sh" "$PROJECT" --key "$K" 2>/dev/null)
    # <<< shard overlap verdict
    SHARD_LINES=$(awk -F'\t' -v k="$K" '$1==k' "$SHARD_UNITS")
    SHARD_BOARD=$(printf '%s\n' "$SHARD_LINES" | awk -F'\t' '$2=="board"{print $3}')
    SHARD_QUEUE=$(printf '%s\n' "$SHARD_LINES" | awk -F'\t' '$2=="queue"{print $3}')
    SHARD_RES=$(printf '%s\n'   "$SHARD_LINES" | awk -F'\t' '$2=="result"{print $3}')
    # The scope wording is the single session's, narrowed to one ticket — the
    # same sentences, so the SOP's rules apply to a shard exactly as they always
    # have. prompts/<project>.md is appended unchanged and is never rewritten for
    # this; the isolation clause is the only new idea here, and it is the whole
    # point: a shard that widened past its ticket would re-create the serial tick
    # inside every one of its siblings.
    SHARD_PROMPT="TICK SCOPE (triage shard — deterministic): this tick's scope was split by ticket, one session per ticket, and this session owns exactly ONE: $K. Every other ticket that moved this tick is being worked in its own session right now.

What moved for $K:$([ -n "$SHARD_BOARD" ] && printf '\nOn the board:\n%s' "$SHARD_BOARD")$([ -n "$SHARD_QUEUE" ] && printf '\nIn the launch queue:\n%s' "$SHARD_QUEUE")$([ -n "$SHARD_RES" ] && printf '\nFinished builds awaiting their board close-out (dir :: first RESULT line):\n%s' "$SHARD_RES")

Work ONLY ticket $K this tick, per the SOP below. Fetch its full comment thread and act on it. SKIP the full board/ticket enumeration the SOP opens with — every other ticket either has not moved or has its own session. Do NOT go looking for other work, do NOT read the board list to find it, and do NOT touch another ticket's comments, status, queue line or build dir. You MAY fetch any other specific ticket that THIS thread references or depends on, read-only, to decide $K.
An UNBLOCKED line names a child that is launchable on the DEFAULT BRANCH now — either its Blocked-by ticket is CLOSED with no other blocker open, or the line says 'dep-verified soft', which means the harness checked those still-open blockers against this child's planned files and its own plan and found no code dependency (bin/dep-verify.sh), or it says 'dep-unverified, released', which means the check had no evidence yet and DEP_UNKNOWN_MODE=soft releases the child anyway (the merge conductor rebases it if a real overlap surfaces). Any of those ways, fetch it and launch it per the queue rules unless a PR or a build already covers it. A STACKABLE line is JUST AS LAUNCHABLE: its Blocked-by ticket is still open, but that parent's PR is open, so the child builds ON TOP of the parent's branch — launch it exactly like an UNBLOCKED one and pass the base branch through, \`STACK_BASE=<the line's base= value> setsid /root/harness/bin/run-build.sh ...\` (everything else about the launch is unchanged; GitHub retargets the child's PR to the default branch when the parent merges).
For a LAUNCH QUEUE line: verify its gating condition against reality (blocking PR merged? in-flight build finished? free slots per free-slots.sh $PROJECT — its first word, where 'unlimited' means this project is Fly-routed and the local slot gate does not apply?), launch it if it is genuinely unblocked, and drop the line if it is satisfied or superseded.
For a FINISHED BUILD: read the dir's RESULT in full, post the close-out comment on its ticket (direct production links included), set the ticket's status, and mark the dir COMMENTED. Queue rules still apply to any launch that close-out unblocks.
READY-QUEUE.log IS SHARED WITH THE OTHER SHARDS RUNNING RIGHT NOW. Never rewrite it: your read-modify-write and a sibling's would lose one of the two edits, and the edit that vanishes is a ticket nobody launches. Drop your own line with \`/root/harness/bin/queue-line-drop.sh $K\`, which does it under the file's lock.
If $K looks inconsistent with what you actually fetch (the ticket is missing, its id looks stale, its RESULT is unparseable), say so plainly in your output and handle THIS ticket per the full SOP — do not widen to the rest of the board.$([ -n "$SHARD_OV" ] && printf '\nOVERLAP SCHEDULE (deterministic, bin/overlap-schedule.sh): %s\nA HELD verdict means a build is running RIGHT NOW on files this ticket plans to touch: do NOT launch %s this tick, leave its queue line where it is, and say '"'"'skip :: overlaps <KEY> on <file>'"'"' in your output; the next tick re-offers it once that build is done. A WAVE 2 or later verdict is ORDER, not a veto — an earlier key in this tick'"'"'s order plans one of the same files. Prefer to let that key go first, but if it does not launch this tick (its gating condition fails, no slot, another shard owns it) then launch %s anyway; bin/overlap-guard.sh at launch time is the gate that settles it. WAVE 1 and UNPLANNED say nothing against launching. A STACK verdict (<KEY> STACK base=<branch> ...) is WAVE 1 with a base: this ticket overlaps exactly one open harness PR and nothing in flight, so launch it on top of that PR'"'"'s branch by passing the base through, STACK_BASE=<the verdict'"'"'s base= value> setsid /root/harness/bin/run-build.sh ... (everything else about the launch is unchanged).' "$SHARD_OV" "$K" "$K")

$SHARD_SOP"
    SHARD_PF="$SHARD_DIR/$K.prompt"
    if ! printf '%s' "$SHARD_PROMPT" > "$SHARD_PF" 2>/dev/null; then
      echo "$STAMP [$PROJECT] triage shards: could not write $SHARD_PF — $K left in scope for the next tick" >> "$ALERTS"
      SHARD_LEFT="$SHARD_LEFT $K"; continue
    fi
    # PERSISTED BEFORE THE SPEND, never after (the fleet rule's one hard line):
    # a ledger written once the session's answer is back has already paid for
    # it. A stamp that cannot be written is alerted and the shard runs — the
    # cost of that is one duplicate session next tick, bounded and announced,
    # against a ticket nobody triages if we refuse.
    if [ -n "$SHARD_SFP" ]; then
      triage_signal_put "$HARNESS" "$PROJECT" "$K" "$SHARD_FP" "$SHARD_SFP" "$SHARD_TURN" || SHARD_SFP=""
    fi
    if [ -n "$SHARD_FP" ] && [ -z "$SHARD_SFP" ] && ! triage_shard_fp_put "$HARNESS" "$PROJECT" "$K" "$SHARD_FP"; then
      echo "$STAMP [$PROJECT] triage shards: could not persist state/triage-shards/$PROJECT/$K.fp — this shard runs, but $K will be re-bought next tick until the write succeeds" >> "$ALERTS"
    fi
    # lock_spawn_unheld closes the per-project flock in the child. Without it
    # every shard would hold the tick's own lock for its whole life and the next
    # tick would exit "previous run still active" — the exact ceiling this change
    # removes, rebuilt out of an inherited descriptor (the lesson of PR #310).
    # It used to be a bare `9>&-` here, which the OTHER spawn site in this file
    # never got; the closing is bin/lib/lock-hygiene.sh's job now, so a third
    # fork added later inherits the fix instead of the bug (BH-651). It carries
    # the `&` itself: backgrounding the FUNCTION would leave a waiting shell
    # holding fd 9 for the shard's whole life, which is the same bug one layer up.
    # HARNESS rides along explicitly: this file resolves it with a default and
    # never exports it, so without this line a shard launched from a test tree —
    # or any box that does not live at /root/harness — would silently work the
    # real fleet's directories.
    # TSH_RUNNER rides along for the same reason TSH_MODEL always has: the
    # selection is the TICK's, made once, so one ticket of a tick can never route
    # to a different runner than its siblings. The shard exports it as
    # RUNNER_TRIAGE, which is the variable bin/agent-call.sh actually reads.
    ( HARNESS="$HARNESS" TSH_MODEL="$TRIAGE_MODEL" TSH_RUNNER="$SHARD_RUNNER" \
      TSH_EFFORT="$EFFECTIVE_GROK_EFFORT" TSH_GATE="$GATE_REASON" \
      TSH_SCOPE="$SCOPE_N" TSH_GH="$SHARD_GH" \
      TSH_TS_HASH="$(command -v ts_shard_hash >/dev/null 2>&1 && ts_shard_hash "$K")" \
      lock_spawn_unheld setsid "$HARNESS/bin/triage-shard.sh" "$PROJECT" "$K" "$SHARD_PF" \
        </dev/null >/dev/null 2>&1 )
    SHARD_LAUNCHED="$SHARD_LAUNCHED $K"; SHARD_N=$((SHARD_N+1))
    SHARD_INFLIGHT=$((SHARD_INFLIGHT+1))
    # Counted at DISPATCH, not by the shard: the cap has to bind on the tick that
    # is spending, and a shard that has not opened its lock yet is invisible to
    # every census this file can take.
    if [ "$SHARD_CAPS" = 1 ]; then
      triage_hour_record "$HARNESS" "$PROJECT" "$K" || true
      SHARD_HN=$((SHARD_HN+1))
    fi
  done
  # THE FINGERPRINT IS CONSUMED AT DISPATCH, because handing a ticket to an owner
  # is what "this board state has been worked" now means — there is no single exit
  # code left to wait for. Every unit that did NOT get an owner is then put back,
  # one entry at a time, so the next diff re-offers exactly those tickets and
  # re-reads nothing else. A shard that dies does the same for its own key
  # (bin/triage-shard.sh), which is why a failed shard is not a lost ticket.
  #
  # A KEY SKIPPED AS UNCHANGED CONSUMES TOO (BH-1079). It was verified against
  # its own live board entry a few lines up, so its pending fingerprint is
  # absorbed exactly as if it had been dispatched — there is nothing left to put
  # back. Without this a key the held path had re-armed out of gate.json stayed
  # out of it for ever: every following tick re-fetched the board, bin/gate-diff.sh
  # reported the same `NEW <id>` line, this block skipped it again, and the gate
  # could never answer `SKIP no-change` because the file it compares against was
  # missing the very ticket the board kept reporting — until the 4h fingerprint
  # TTL expired and bought one spurious session. A NO-SIGNAL settle (BH-2542)
  # consumes for the same reason: its thread was read and nothing human moved.
  # Order is load-bearing: consume FIRST, re-arm HELD/LEFT after. triage_shard_rearm
  # edits gate.json in place, so a re-arm before the mv below would be overwritten.
  if [ "$SHARD_N" -gt 0 ] || [ -n "$SHARD_SAME" ] || [ -n "$SHARD_NOSIG" ] || [ -n "$SHARD_TSS" ]; then
    rt_gate_consume
  fi
  # P2 (#2294 review I3): a tick that dispatched a shard is a PAID tick, and the
  # throttle ledger counts it once here — never at the gate.
  [ "$SHARD_N" -gt 0 ] && command -v triage_throttle_record >/dev/null 2>&1 && triage_throttle_record "$HARNESS" "$PROJECT"
  # SHARD_SAME is deliberately absent from this list: those keys were CONSUMED
  # just above, not re-armed — see the note at the skip for why fp-fresh means
  # there is nothing to put back.
  for K in $SHARD_HELD $SHARD_LEFT $SHARD_BUILD; do
    triage_shard_rearm "$HARNESS" "$PROJECT" "$K" "$SHARD_GH" || true
  done
  # A unit the CAP withheld is work this box chose not to start, so the gate's
  # 45-minute queue/sweep brakes — which exist to stop re-paying for an unchanged
  # world — would be answering a question nobody asked. Drop their stamps so the
  # next tick offers the withheld units again. Only with TRIAGE_SHARDS_MAX set,
  # which is not the default: a HELD key needs no such help, because the shard
  # holding it is the work.
  # state/<project>.prstates is NOT deleted here, and must never be: dropping
  # queuefp drops the gate's PR-state vector with it, which is exactly why the
  # fingerprint stopped reading that file. The ledger is carried forward across
  # every cap deferral so the keys the cap did NOT withhold stay unchanged.
  { [ "$SHARD_MAX" -gt 0 ] || [ -n "$SHARD_CAPHIT" ]; } && [ -n "$SHARD_LEFT" ] \
    && rm -f "$HARNESS/state/$PROJECT.queuefp" "$HARNESS/state/$PROJECT.sweepfp"
  rm -f "$SHARD_UNITS"
  LANE_TICK dispatch
  SHARD_LEFT_TXT=""
  if [ -n "$SHARD_LEFT" ]; then
    if [ -n "$SHARD_CAPHIT" ]; then SHARD_LEFT_TXT=" — deferred to the next tick (cap $SHARD_CAPHIT):$SHARD_LEFT"
    elif [ "$SHARD_MAX" -gt 0 ]; then SHARD_LEFT_TXT=" — left in scope (cap $SHARD_MAX):$SHARD_LEFT"
    else SHARD_LEFT_TXT=" — left in scope:$SHARD_LEFT"; fi
  fi
  echo "$STAMP [$PROJECT] dispatched $SHARD_N shards:${SHARD_LAUNCHED:- (none)} — skipped $SHARD_HELD_N held${SHARD_HELD:+:$SHARD_HELD}${SHARD_SAME:+ — unchanged:$SHARD_SAME}${SHARD_NOSIG:+ — no-signal:$SHARD_NOSIG}${SHARD_BUILD:+ — building:$SHARD_BUILD}${SHARD_TSS:+ — triage-state unchanged:$SHARD_TSS}$SHARD_LEFT_TXT [gate=$GATE_REASON scope=$SCOPE_N runner=$SHARD_RUNNER model=$TRIAGE_MODEL hour=$SHARD_HN/${SHARD_PH:-0} \$$SHARD_HUSD/\$${SHARD_UCAP:-0}]" >> "$LOG"
  # ONE ALERT PER PROJECT PER CLOCK HOUR, and it is an ALERT rather than a log
  # line on purpose (the 08-13 lesson: "stopping is an alert, not a whisper").
  # A lane that has stopped triaging its board because it hit a money ceiling is
  # exactly the state that looks, from every other angle, like a quiet day. The
  # marker is the dedupe: a busy hour rings this once, not once per tick.
  if [ -n "$SHARD_CAPHIT" ]; then
    CAP_MARK="$SHARD_DIR/cap-alerted-$(date -u '+%Y%m%d%H')"
    if [ ! -e "$CAP_MARK" ] && : > "$CAP_MARK" 2>/dev/null; then
      "$HARNESS/bin/lane-alert.sh" triage-shards \
        "[$PROJECT] triage shard cap reached ($SHARD_CAPHIT) —$(printf '%s' "$SHARD_LEFT" | wc -w | tr -d ' ') ticket(s) deferred to the next cron tick, none dropped. Raise TRIAGE_SHARDS_PER_HOUR / TRIAGE_SHARD_USD_PER_HOUR in env/global.env, or touch flags/triage-shard-caps-off, if this board is genuinely this busy." \
        >/dev/null 2>&1 || \
        echo "$STAMP [$PROJECT] triage shard cap reached ($SHARD_CAPHIT) and bin/lane-alert.sh did not run — deferred:$SHARD_LEFT" >> "$ALERTS"
    fi
  fi
  # The tick's own ticketless claim closes here: it registered a DISPATCH, and
  # the sessions it bought carry their own ticket-keyed rows.
  if [ -n "${JOB_ID:-}" ] && command -v job_update >/dev/null 2>&1; then
    [ -n "${JOB_BEAT:-}" ] && job_beat_stop "$JOB_BEAT"
    job_update "$JOB_ID" stage=done status=done "meta=dispatched $SHARD_N triage shards"
  fi
  exit 0
fi
# <<< triage shards
}
