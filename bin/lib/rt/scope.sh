#!/bin/bash
# BH-479: the scope stage of bin/run-triage.sh, moved here verbatim by BH-479.2
# (the driver keeps its inline copy until BH-479.4); defines functions only,
# nothing runs on source.
# >>> inapp dependency release
# THE IN-APP HALF OF bin/unblocked-children.sh (BH-815). A GitHub board spells a
# dependency `Blocked-by: #N` in an issue body and that script reads it, so a
# blocker closing puts its child on THIS tick's reading list. In-app boards have
# no such convention and that script exits 0 for them, so a released child there
# waited for the daily sweep. What in-app boards have instead is structured:
# `dependsOn` and a derived `blocked` boolean (docs/BOARD-API-CONTRACT.md,
# "Dependencies"), carried into the fingerprint by bin/triage-gate.sh. The gate
# already keeps the consumed fingerprint (state/<p>.gate.json) beside the live
# one (state/<p>.gate.pending), so a `blocked` flip true -> false between those
# two files IS the release, and reading it costs no request.
#
# Prints gate-diff-shaped lines — `board <bid>: UNBLOCKED <id> ...` — because
# that is what triage_shard_key parses (bin/lib/triage-shards-lib.sh) and what
# the TICK SCOPE prompt already explains to the session. No prompt text changes.
#
# Bounded by INAPP_RELEASE_MAX_LINES (default 25, the ceiling bin/gate-diff.sh
# puts on its own diff). NOTHING IS DROPPED BY THAT CAP IN PRACTICE, and the
# reason is worth writing down: every call site here sits behind a usable diff,
# and bin/gate-diff.sh refuses one longer than 25 tickets (rc 1). More than 25
# flips at once therefore never reaches this function at all — the tick falls
# back to the full SOP and the session enumerates the whole board, which is the
# pre-existing behaviour for any board-wide change. The cap is the belt to that
# braces.
#
# Silent rc 0 on a GitHub-Issues board (board_prefix "-"), on a missing or
# unparseable fingerprint, and when nothing flipped: its failure mode is "no
# line", and the daily sweep still reads every ticket.
#
# It is also where the in-app parent-close lane is called from, for the reason
# bin/unblocked-children.sh calls the GitHub one from its own pass: a lane with
# no caller is a dead feature. `--cooled` is a DEDUPE window, never a wait.

# THE READY SET (BH-1033). The `queue-pending` arm below builds the SESSION's
# prompt out of "what is ready to build", and that has exactly one definition —
# bin/lib/ready-queue.sh — which is the file's lines UNION the `ready`
# build_queue rows. bin/triage-gate.sh already reads it (that is what un-brakes
# the tick on a row-only ticket); a scope that kept its own grep of the file
# would fire the gate and then hand the session a prompt that says the queue is
# empty. Sourced here, not in bin/run-triage.sh, because this stage file is the
# only consumer and the driver is at its line ceiling. bin/jobs-client.sh is
# already sourced by the driver, so this adds no second client. Flag off, lib
# absent, or an unreachable worker and every read is the grep it always was.
# The root candidate is $HARNESS, else $H, and is skipped with neither (BH-2613).
_RTS_R="${HARNESS:-${H:-}}"
# shellcheck source=bin/lib/ready-queue.sh
for _RTS_P in "$(dirname "${BASH_SOURCE[0]}")/../ready-queue.sh" ${_RTS_R:+"$_RTS_R/bin/lib/ready-queue.sh"}; do
  # shellcheck source=/dev/null
  [ -r "$_RTS_P" ] && { . "$_RTS_P"; break; }
done
unset _RTS_P
# BH-1655: the split-chain pass. bin/triage-gate.sh's step 1c stamps the due
# siblings into state/split-ready-keys-<p>; inapp_released_lines turns them into
# UNBLOCKED lines. No lib = no line, which is today.
# shellcheck source=bin/lib/split-chain.sh
for _RTS_P in "$(dirname "${BASH_SOURCE[0]}")/../split-chain.sh" ${_RTS_R:+"$_RTS_R/bin/lib/split-chain.sh"}; do
  # shellcheck source=/dev/null
  [ -r "$_RTS_P" ] && { . "$_RTS_P"; break; }
done
unset _RTS_P
# BH-3829: the gate-release re-offer. bin/gate-release.sh stamps a PLAN_BLOCKED
# result whose blockers merged into state/gate-reoffer-keys-<p>;
# inapp_released_lines turns them into REOFFER lines. No lib = no line.
# shellcheck source=bin/lib/gate-release.sh
for _RTS_P in "$(dirname "${BASH_SOURCE[0]}")/../gate-release.sh" ${_RTS_R:+"$_RTS_R/bin/lib/gate-release.sh"}; do
  # shellcheck source=/dev/null
  [ -r "$_RTS_P" ] && { . "$_RTS_P"; break; }
done
unset _RTS_P
# BH-3946: in-app text-dependency releases. bin/triage-gate.sh's step 1e answers
# `RUN inapp-deps-ready`; inapp_released_lines appends inapp_deps_take_lines.
# No lib = no line.
# shellcheck source=bin/lib/inapp-deps.sh
for _RTS_P in "$(dirname "${BASH_SOURCE[0]}")/../inapp-deps.sh" ${_RTS_R:+"$_RTS_R/bin/lib/inapp-deps.sh"}; do
  # shellcheck source=/dev/null
  [ -r "$_RTS_P" ] && { . "$_RTS_P"; break; }
done
unset _RTS_P _RTS_R
command -v rq_lines >/dev/null 2>&1 || rq_lines() {
  local r="${1:-${HARNESS:-${H:-}}}"
  [ -n "$r" ] || return 0
  grep -E '^[A-Z]+-[0-9]' "$r/logs/READY-QUEUE.log" 2>/dev/null
}

inapp_released_lines() {
  local bp old new cap out closed sc gr idl
  bp=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null) || bp=""
  [ -n "$bp" ] && [ "$bp" != "-" ] || return 0
  old="$HARNESS/state/$PROJECT.gate.json"
  new="$HARNESS/state/$PROJECT.gate.pending"
  cap="${INAPP_RELEASE_MAX_LINES:-25}"
  case "$cap" in ''|*[!0-9]*) cap=25 ;; esac
  if [ -s "$old" ] && [ -s "$new" ] && [ "$cap" -gt 0 ] && command -v jq >/dev/null 2>&1; then
    # FILES, never argv: a real board fingerprint is 135KB and Linux
    # MAX_ARG_STRLEN is ~128KB (the cliff bin/triage-gate.sh already paid once).
    out=$(jq -r --slurpfile o "$old" --argjson cap "$cap" '
      ( [ ($o[0] // {}) | to_entries[] | (.value // [])[]? | select(type == "object") ]
        | map(select(.id != null) | {key: (.id | tostring), value: .}) | from_entries ) as $was
    | ( [ to_entries[] | (.value // [])[]? | select(type == "object") ]
        | map(select(.id != null) | {key: (.id | tostring), value: (.key // (.id | tostring))}) | from_entries ) as $keyof
    | [ to_entries[]
        | .key as $bid
        | (.value // [])[]?
        | select(type == "object")
        | select(.blocked == false)
        | . as $t
        | ($was[($t.id | tostring)] // {}) as $prev
        | select($prev.blocked == true)
        | ($t.key // ($t.id | tostring)) as $k
        | ( [ ($t.dependsOn // [])[] | ($keyof[(. | tostring)] // (. | tostring)) ] | join(", ") ) as $deps
        | "board \($bid): UNBLOCKED \($t.id) \"\($t.title // "")\" (\($k) — dependency \(if ($deps | length) == 0 then "unlisted" else $deps end) done: the board released it this tick, blocked went true -> false; fetch it and launch per the queue rules if no PR or build already covers it)"
      ] | .[0:$cap][]' "$new" 2>/dev/null) || out=""
    # ONLY a boolean flip counts, and the two select() lines above are the whole
    # rule: absent -> false, null -> false, false -> false, true -> true,
    # true -> absent (the board dropped the field) and a ticket NEW this tick
    # all produce nothing. Absent is not false (D11), and a ticket nobody was
    # holding was never released.
    [ -n "$out" ] && printf '%s\n' "$out"
  fi
  # BH-3927: merged + deploy-audited tickets move on first, so a split's last
  # child reaching `done` lets the parent close below in this same tick. Its
  # stdout is dropped: the moves are board changes the next fingerprint carries,
  # and the lane writes its own MERGED_ADVANCE line. Silent with no in-app env.
  [ -x "$HARNESS/bin/merged-ticket-advance.sh" ] && "$HARNESS/bin/merged-ticket-advance.sh" "$PROJECT" --cooled >/dev/null 2>&1 || true
  if [ -x "$HARNESS/bin/decompose-parent-close.sh" ]; then
    closed=$("$HARNESS/bin/decompose-parent-close.sh" "$PROJECT" --cooled 2>/dev/null) || closed=""
    closed=$(printf '%s' "$closed" | tr '\n' ' ' | sed 's/  */ /g; s/ *$//')
    # NOT scope. The status move it made is a board change the NEXT fingerprint
    # diff carries; what belongs here is this tick's own record that it happened.
    # Expect TWO PARENT_CLOSED lines per real close in this log: the lane writes
    # its own per-parent line (bin/decompose-parent-close.sh) and this is the
    # caller's one-line-per-tick roll-up of the keys it got back.
    [ -n "$closed" ] && echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$PROJECT] PARENT_CLOSED $closed" \
      >> "${LOG:-$HARNESS/logs/$PROJECT.log}" 2>/dev/null
  fi
  # BH-1655: split siblings whose earlier siblings' PRs have all merged
  # (bin/lib/split-chain.sh). Consumes the gate's one-shot keys file.
  command -v split_chain_take_lines >/dev/null 2>&1 && {
    sc=$(split_chain_take_lines "$HARNESS" "$PROJECT" 2>/dev/null) || sc=""
    [ -n "$sc" ] && printf '%s\n' "$sc"
  }
  # BH-3829: PLAN_BLOCKED results whose stated blockers all merged
  # (bin/lib/gate-release/reoffer.sh). Consumes the driver's one-shot keys file.
  declare -F gate_release_take_lines >/dev/null 2>&1 && {
    gr=$(gate_release_take_lines "$HARNESS" "$PROJECT" 2>/dev/null) || gr=""
    [ -n "$gr" ] && printf '%s\n' "$gr"
  }
  # BH-3946: in-app tickets whose `Blocked by` text dependencies merged
  # (bin/lib/inapp-deps/release.sh). Inert under flags/inapp-deps-off.
  declare -F inapp_deps_take_lines >/dev/null 2>&1 && [ "$(inapp_deps_on "$HARNESS")" = 1 ] && {
    idl=$(inapp_deps_take_lines "$HARNESS" "$PROJECT" 2>/dev/null) || idl=""
    [ -n "$idl" ] && printf '%s\n' "$idl"
  }
  return 0
}
# <<< inapp dependency release

# >>> stack launch filter (BH-3684)
# Every bin/unblocked-children.sh call below pipes through this. A STACKABLE line
# for a decomposition's own chain (`chain=#P`) is launched stacked by
# bin/stack-launch.sh through bin/launch-fastpath.sh, and a line whose parent PR
# is BLOCKed waits; both leave the reading list, so no session is bought for
# them. Everything else comes back unchanged. No script in the tree (a scratch
# tree, a box mid-sync) is `cat`.
rt_stack_filter() {
  if [ -x "$HARNESS/bin/stack-launch.sh" ]; then "$HARNESS/bin/stack-launch.sh" "$PROJECT"; else cat; fi
  return 0
}
# <<< stack launch filter

# board_section: fetch live fingerprint into gate.pending + diff it. Sets
# BOARD_OK=1 when the board state is KNOWN (diff printed, or verified
# unchanged); BOARD_SEC carries the changed-tickets text (may be empty).
# A consumed run (rc=0) then absorbs the pending fingerprint as usual.
board_section() {
  BOARD_SEC=""; BOARD_OK=0
  "$HARNESS/bin/triage-gate.sh" "$PROJECT" --pending >/dev/null 2>&1 || return 0
  local d rc
  d=$("$HARNESS/bin/gate-diff.sh" "$PROJECT" 2>/dev/null); rc=$?
  if [ "$rc" -eq 0 ]; then
    BOARD_OK=1
    # A ticket that just went OPEN -> CLOSED from outside a tick (a hand merge,
    # GitHub's "closes #N") releases its Blocked-by children; list them here or
    # nothing ever re-reads them (bin/unblocked-children.sh, fail-open). The
    # same call also lists the children a merely-OPEN parent PR already makes
    # buildable (STACKABLE); every such line says so in its own text, so a scope
    # that carries one needs no extra instruction here.
    local u ur
    # Guarded on `command -v`, same reason as the rc=2 arm's u2 below: a caller
    # that does not source bin/lib/triage-hotfix-lib.sh still gets the plain
    # unblocked-children lines rather than a "command not found" abort.
    command -v triage_hot_load >/dev/null 2>&1 && triage_hot_load
    u=$("$HARNESS/bin/unblocked-children.sh" "$PROJECT" <<<"$d" 2>/dev/null | { command -v rt_stack_filter >/dev/null 2>&1 && rt_stack_filter || cat; }) || u=""
    ur=$(inapp_released_lines) || ur=""
    [ -n "$ur" ] && u="${u:+$u
}$ur"
    u=$(printf '%s' "$u" | { command -v triage_hot_mark >/dev/null 2>&1 && triage_hot_mark board || cat; })
    [ -n "$u" ] && d="$d
$u"
    BOARD_SEC="ALSO changed on the board since the last consumed tick (work these too — fetch their threads):
$d"
  elif [ "$rc" -eq 2 ]; then
    BOARD_OK=1   # board verified unchanged — scope is safe
    # ...but "unchanged" is only an answer about the BOARD. The STACKABLE and
    # dep-verified-soft classes act on facts no board diff can carry (a parent
    # PR is open; a child's pre-plan and its parent's PR disagree about whether
    # the dependency is real), and the release class acts on a closure the
    # ai-build fingerprint cannot see at all once the size gate un-labels the
    # parent. Gating the pass on a non-empty diff meant those three ran on
    # exactly the ticks that had other work and never on the quiet ones. The
    # script is fail-open and prints nothing when its classes are off, so this
    # costs a quiet tick nothing.
    local u2 ur2
    # The hotfix set is loaded HERE, in the parent shell, so the marking below
    # (and the queue slice's, on a tick that has both) costs one gh call.
    # Guarded on `command -v`, same reason as the queue-pending arm's QLINES:
    # bin/lib/triage-hotfix-lib.sh may not be sourced by every caller of this
    # function.
    command -v triage_hot_load >/dev/null 2>&1 && triage_hot_load
    u2=$("$HARNESS/bin/unblocked-children.sh" "$PROJECT" </dev/null 2>/dev/null | { command -v rt_stack_filter >/dev/null 2>&1 && rt_stack_filter || cat; }) || u2=""
    ur2=$(inapp_released_lines) || ur2=""
    [ -n "$ur2" ] && u2="${u2:+$u2
}$ur2"
    u2=$(printf '%s' "$u2" | { command -v triage_hot_mark >/dev/null 2>&1 && triage_hot_mark board || cat; })
    [ -n "$u2" ] && BOARD_SEC="ALSO launchable right now (deterministic — the board itself did not move this tick; each line says what makes it launchable):
$u2"
  fi
}

rt_scope() {
# >>> overlap schedule feed
# BH-475. The launch decision on this path belongs to the triage session, so the
# planned-file overlap graph reaches it as ONE deterministic section computed
# once per tick, before any scope arm is chosen — every tick type and every
# shard then carries the same order. bin/overlap-schedule.sh is fail-open by
# construction (no candidates, no pre-plans, kill flag, no python3 -> it prints
# nothing and exits 0), so an empty answer is the ONLY thing that can go wrong
# here, and an empty answer leaves this tick byte-for-byte what it was.
#
# NEVER FOLDED INTO BOARD_SEC. The shard dispatcher feeds BOARD_SEC's tail
# through triage_shard_key, which would fail on a `WAVE 1:` line and abandon the
# split — the whole tick would collapse back to one serial session because a
# scheduling hint looked like a ticket line.
OVERLAP_SEC=""
if [ -x "$HARNESS/bin/overlap-schedule.sh" ]; then
  # The scheduler's stderr (its OVERLAP_UNJUDGED lines) belongs in the project
  # log, but EVERY line in that file carries `$STAMP [$PROJECT] ` and the
  # pipeline-health greps read that shape — appending raw stderr straight to
  # "$LOG" writes lines those greps cannot see. So it lands in a scratch file
  # and is re-emitted stamped. No scratch file (a full /tmp) is not worth
  # failing a tick over: the diagnostics are dropped and the schedule still runs.
  OV_ERR=$(mktemp "${TMPDIR:-/tmp}/overlap-sched-err.XXXXXX" 2>/dev/null) || OV_ERR=""
  if [ -n "$OV_ERR" ]; then
    OV_OUT=$("$HARNESS/bin/overlap-schedule.sh" "$PROJECT" 2>"$OV_ERR") || OV_OUT=""
    while IFS= read -r OV_EL; do
      [ -n "$OV_EL" ] && echo "$STAMP [$PROJECT] $OV_EL" >> "$LOG"
    done < "$OV_ERR"
    rm -f "$OV_ERR"
  else
    OV_OUT=$("$HARNESS/bin/overlap-schedule.sh" "$PROJECT" 2>/dev/null) || OV_OUT=""
  fi
  if [ -n "$OV_OUT" ]; then
    OVERLAP_SEC="OVERLAP SCHEDULE (deterministic — bin/overlap-schedule.sh, planned-file overlap across this project's pre-planned ready backlog):
$OV_OUT

Launch rule: launch the WAVE 1 keys whose own gating conditions hold, first. Do NOT launch a HELD key this tick — something is building on its files right now; leave its queue line exactly where it is and say \`skip :: overlaps in-flight <KEY> on <file>\` in your output. A HELD verdict clears itself when that build finishes, so it is the only hard stop here. WAVE 2 and later are ORDER, not a veto: the wave-1 key named in the verdict goes first, and if that key does not launch this tick — its gating condition fails, no slot, it is not yours — then launch the wave-2 key anyway rather than holding it for a build that never started. bin/overlap-guard.sh at launch time is the gate that settles it either way. A key under UNPLANNED has no pre-plan file list yet, so this schedule says nothing about it — treat it exactly as you would have without this section. This is BUILD_DEFERRED semantics: not a queue, not a wait, and nothing here is a reason to comment on a ticket. A STACK line (\`STACK: <KEY> base=<branch> (overlaps open PR #<n> on <file>)\`) names a WAVE 1 key whose planned files overlap exactly one OPEN harness PR and nothing in flight: it is just as launchable as any WAVE 1 key, but pass the base branch through, \`STACK_BASE=<the line's base= value> setsid /root/harness/bin/run-build.sh ...\`, so it builds on top of that PR's branch instead of rebasing onto it later. A HELD verdict still wins over it."
    # One log line per hot file, so the split conversation has a written trail
    # on the box and not only inside a session's output. Written only AFTER a
    # non-empty HOT-FILES section was actually produced: a stamped line with no
    # content behind it is the shape this harness keeps having to un-learn.
    printf '%s\n' "$OV_OUT" | awk '/^HOT-FILES:/{h=1;next} h && NF' | while IFS= read -r OV_HL; do
      case "$OV_HL" in
        *" :: "*) echo "$STAMP [$PROJECT] HOT-FILES: ${OV_HL%% ::*} shared by ${OV_HL#* :: }" >> "$LOG" ;;
      esac
    done
  fi
fi
# <<< overlap schedule feed

case "$GATE_REASON" in
  board-changed|event-wake|split-ready|gate-reoffer|inapp-deps-ready)
    # EVENT-WAKE IS A BOARD TICK (2026-09-14). bin/triage-gate.sh answers `RUN
    # event-wake` for a webhook delivery (docs/EVENTS.md §2) and returns BEFORE
    # its own board diff, so this arm used to skip it entirely: the default
    # full-SOP prompt was built and bin/unblocked-children.sh was never called.
    # On the project-5 box that made both deterministic classes dead work —
    # 17 event-wake ticks and 0 board-changed ticks in one afternoon, 0 DEP_
    # lines, 0 STACKABLE launches, while a hand run of the same script printed
    # 9 STACKABLE lines. The wake is now scoped exactly like a board-changed
    # tick, with the one step the gate did not take: fetch the live fingerprint
    # first. A fetch that fails leaves the scope unset and the tick runs the
    # full SOP, which is what it did before this line existed.
    SCOPE_TRY=1
    # split-ready (BH-1655), gate-reoffer (BH-3829) and inapp-deps-ready
    # (BH-3946) return from the gate before its board diff too.
    case "$GATE_REASON" in
      event-wake|split-ready|gate-reoffer|inapp-deps-ready)
        "$HARNESS/bin/triage-gate.sh" "$PROJECT" --pending >/dev/null 2>&1 || SCOPE_TRY=0 ;;
    esac
    TICK_SCOPE=""; DIFF_RC=1
    if [ "$SCOPE_TRY" = 1 ]; then
      TICK_SCOPE=$("$HARNESS/bin/gate-diff.sh" "$PROJECT" 2>/dev/null); DIFF_RC=$?
      [ "$DIFF_RC" -eq 0 ] || TICK_SCOPE=""
    fi
    SCOPE_WHY="computed by diffing the board fingerprint since the last consumed tick"
    # ── A WAKE IS ABOUT ONE OBJECT (2026-09-14, the shard storm) ──────────────
    # The arm above was written for `board-changed`, where the diff IS the tick's
    # reason: the board moved, and everything that moved is the work. A webhook
    # delivery is not that. It names ONE issue, and the diff it happens to land
    # next to is "everything that has moved since the last CONSUMED tick" — which
    # on a busy repo is a dozen other tickets that already have their own ticks
    # coming. #333 pointed the wake at that diff and the dispatcher below fanned
    # it out: ~13 wakes an hour past the cooldown, each buying a session for every
    # line in it, 190 sessions in the 19Z hour against 4-7 in every hour before.
    #
    # So the wake carries its keys (bin/wake-loop.sh writes them beside the
    # un-brake) and the keys ARE the scope. Everything else on the board is left
    # for the tick whose reason it is.
    #
    # THE KEYLESS WAKE. A wake with no usable key — a push whose merge released
    # nothing nameable, an old row from a box that predates this, a key the board
    # cannot spell — runs the deterministic pass and NOTHING ELSE: no shards, and
    # no full-SOP board enumeration bought by a doorbell press. That pass is free,
    # it is the whole reason #333 exists, and the cron tick still owns the sweep.
    EW_NO_SHARDS=0; EW_KEYS=""; EW_KEYS_TXT=none; EW_SKIP_OK=0
    if [ "$GATE_REASON" = event-wake ]; then
      # ONE-SHOT, exactly like state/wake-<project> itself: a key that outlived
      # its wake would scope some later tick to a ticket nobody rang about.
      EW_KEYFILE="$HARNESS/state/wake-keys-$PROJECT"
      if [ -s "$EW_KEYFILE" ]; then
        EW_KEYS=$(tr -s ' \t' '\n' < "$EW_KEYFILE" 2>/dev/null \
          | grep -E '^[A-Za-z0-9._-]{1,48}$' | awk '!seen[$0]++' | head -50)
      fi
      rm -f "$EW_KEYFILE" 2>/dev/null || true
      case "$DIFF_RC" in 0|2) EW_SKIP_OK=1 ;; esac
      if [ -n "$EW_KEYS" ] && command -v triage_shard_key >/dev/null 2>&1; then
        EW_GH=0
        command -v triage_shard_gh >/dev/null 2>&1 && EW_GH=$(triage_shard_gh "$HARNESS" "$PROJECT")
        # Both sides canonicalised: a GitHub-Issues board spells one ticket `563`
        # in the diff and `TK-563` in a queue line, and a wake may carry either.
        EW_WANT=" "
        while IFS= read -r EW_K; do
          [ -n "$EW_K" ] || continue
          EW_C=$(triage_shard_canon "$EW_K" "$EW_GH" 2>/dev/null) || continue
          EW_WANT="$EW_WANT$EW_C "
        done <<<"$EW_KEYS"
        EW_KEYS_TXT=$(printf '%s' "${EW_WANT# }" | sed 's/ $//; s/ /,/g')
        [ -n "$EW_KEYS_TXT" ] || EW_KEYS_TXT=none
        EW_KEPT=""
        while IFS= read -r EW_L; do
          [ -n "$EW_L" ] || continue
          EW_LK=$(triage_shard_key board "$PROJECT" "$EW_GH" "$EW_L" 2>/dev/null) || continue
          case "$EW_WANT" in
            *" $EW_LK "*) EW_KEPT="${EW_KEPT:+$EW_KEPT
}$EW_L" ;;
          esac
        done <<<"$TICK_SCOPE"
        TICK_SCOPE="$EW_KEPT"
        SCOPE_WHY="the object(s) this webhook named ($EW_KEYS_TXT), taken out of the board fingerprint diff"
      else
        EW_KEYS=""
      fi
      if [ -z "$EW_KEYS" ] || [ -z "$TICK_SCOPE" ]; then
        # No key, or a key the board diff does not carry. EITHER WAY THE DIFF IS
        # DROPPED, and that line is the whole fix: a wake that cannot say what it
        # was about has no business inheriting "everything that moved since the
        # last consumed tick" as its reading list. What is left is the
        # deterministic pass below, on an empty stdin (its no-board-trigger
        # classes), and at most one session to act on it.
        EW_NO_SHARDS=1
        TICK_SCOPE=""
        SCOPE_WHY="computed by the deterministic dependency pass — this webhook named no board object that moved"
      fi
    fi
    if [ "$DIFF_RC" -eq 0 ] || [ "$DIFF_RC" -eq 2 ]; then
      # Same expansion as board_section: a blocker closed from outside a tick
      # puts its released children on the reading list, and a blocker whose PR
      # is merely OPEN puts its children there as STACKABLE (see the script
      # header — the operator, 2026-09-14: chain levels overlap instead of queueing).
      # rc 2 is "the board is verified unchanged", and those classes have no
      # board trigger by design, so their lines ARE the tick's work: an empty
      # diff is not an empty tick. rc 1 is "no usable diff" — a scope built
      # from these lines alone would then be a scope that dropped whatever the
      # gate fired on, so that case keeps running the full SOP.
      UNBLOCKED=$("$HARNESS/bin/unblocked-children.sh" "$PROJECT" <<<"$TICK_SCOPE" 2>/dev/null | { command -v rt_stack_filter >/dev/null 2>&1 && rt_stack_filter || cat; }) || UNBLOCKED=""
      INAPP_REL=$(inapp_released_lines) || INAPP_REL=""
      [ -n "$INAPP_REL" ] && UNBLOCKED="${UNBLOCKED:+$UNBLOCKED
}$INAPP_REL"
      if [ -n "$TICK_SCOPE" ]; then
        [ -n "$UNBLOCKED" ] && TICK_SCOPE="$TICK_SCOPE
$UNBLOCKED"
      elif [ -n "$UNBLOCKED" ]; then
        TICK_SCOPE="$UNBLOCKED"
        SCOPE_WHY="computed by the deterministic dependency pass — the board itself did not move this tick"
      fi
    fi
    # THE FOURTH SLICE (BH-1349). board_section's two arms (:132, :159) and the
    # queue-pending arm (:383) all pipe their lines through triage_hot_mark;
    # this one did not, so a hotfix that reached the session through the board
    # diff was read in diff order — on the tick shape a live box takes most
    # often. The mark runs over the WHOLE scope, after the UNBLOCKED append:
    # a hotfix child released by a parent merge is exactly the emergency this
    # lane exists for. triage_hot_load is called from THIS shell, like the other
    # three sites, because the marking pipeline runs in its own subshell and a
    # memo set there is a memo the next slice does not have.
    if [ -n "$TICK_SCOPE" ]; then
      command -v triage_hot_load >/dev/null 2>&1 && triage_hot_load
      TICK_SCOPE=$(printf '%s' "$TICK_SCOPE" | { command -v triage_hot_mark >/dev/null 2>&1 && triage_hot_mark board || cat; })
    fi
    if [ -n "$TICK_SCOPE" ]; then
      SCOPE_N=$(printf '%s\n' "$TICK_SCOPE" | grep -c .)
      PROMPT_TEXT="TICK SCOPE (deterministic — $SCOPE_WHY):
$TICK_SCOPE

Work ONLY the tickets listed above this tick: fetch each one's full comment thread and act on it per the SOP below. An UNBLOCKED line names a child that is launchable on the DEFAULT BRANCH now — either its Blocked-by ticket is CLOSED with no other blocker open, or the line says 'dep-verified soft', which means the harness checked those still-open blockers against this child's planned files and its own plan and found no code dependency (bin/dep-verify.sh), or it says 'dep-unverified, released', which means the check had no evidence yet and DEP_UNKNOWN_MODE=soft releases the child anyway (the merge conductor rebases it if a real overlap surfaces). Any of those ways, fetch it and launch it per the queue rules unless a PR or a build already covers it. A STACKABLE line is JUST AS LAUNCHABLE: its Blocked-by ticket is still open, but that parent's PR is open, so the child builds ON TOP of the parent's branch — launch it exactly like an UNBLOCKED one and pass the base branch through, \`STACK_BASE=<the line's base= value> setsid /root/harness/bin/run-build.sh ...\` (everything else about the launch is unchanged; GitHub retargets the child's PR to the default branch when the parent merges). SKIP the full board/ticket enumeration the SOP opens with — unchanged tickets have not moved since the last consumed run and owe nothing new. You MAY fetch any other specific ticket that a changed thread references or depends on. Queue and build-results handling in the SOP still applies as written. If the scope list looks inconsistent with what you actually fetch (a listed ticket is missing, ids look stale), discard the scope and run the full SOP instead.$(command -v hot_sop >/dev/null 2>&1 && HS=$(hot_sop "$TICK_SCOPE") && [ -n "$HS" ] && printf '\n\n%s' "$HS")

$PROMPT_TEXT"
    fi
    # ONE LINE PER WAKE TICK, always, whatever it decided. The storm was invisible
    # in this log for an hour because a wake tick logged nothing until its shards
    # finished: `scope=N keys=...` is what makes "a doorbell press bought N
    # sessions" readable at the moment it happens.
    if [ "$GATE_REASON" = event-wake ]; then
      EW_N=0
      [ -n "$TICK_SCOPE" ] && EW_N=$(printf '%s\n' "$TICK_SCOPE" | grep -c .)
      echo "$STAMP [$PROJECT] event-wake scope=$EW_N keys=$EW_KEYS_TXT" >> "$LOG"
      # A wake that named nothing and whose deterministic pass found nothing has
      # no work in it. It used to buy the FULL SOP — a whole board enumeration,
      # on a doorbell press, at the most expensive tick shape there is. Only when
      # the diff was usable (rc 0/2): an unusable diff is the one case where we
      # genuinely do not know, and that still falls through to the full SOP.
      if [ "$EW_NO_SHARDS" = 1 ] && [ "$EW_SKIP_OK" = 1 ] && [ "$SCOPE_N" = full ]; then
        if [ -n "${JOB_ID:-}" ] && command -v job_update >/dev/null 2>&1; then
          [ -n "${JOB_BEAT:-}" ] && job_beat_stop "$JOB_BEAT"
          job_update "$JOB_ID" stage=done status=done "meta=event-wake with nothing to work"
        fi
        LANE_TICK skip
        echo "$STAMP [$PROJECT] rc=skip :: event-wake named no board object that moved and the deterministic pass found nothing — the cron tick still owns the sweep" >> "$LOG"
        exit 0
      fi
    fi
    ;;
  queue-pending)
    # THE SAME READY SET THE GATE BRAKED ON (BH-1033), not a second grep: the
    # file's lines UNION this project's `ready` rows. Before this, a row-only
    # ticket fired the gate (rq_any) and then arrived here as "(none)" — the
    # queue-pending scope collapsed, the session ran the full SOP against the
    # same file, and the row was never surfaced. rq_lines keeps the gate's key
    # regex for the file half. READY-QUEUE.log is box-global: on the
    # multi-project small box a line from another lane may ride along; the
    # prompt tells the session to fetch only tickets that resolve on ITS board,
    # so foreign keys are inert. The ROW half is scoped to $PROJECT by the
    # query, so it can never carry a foreign key here.
    # The mark + sort runs BEFORE `head -40`: a hotfix sitting at line 43 of a
    # busy box's queue is exactly the line the cap would otherwise cut off, and
    # sorting what survived the cap would leave it there. triage_hot_load is
    # called from this shell first so the tick's one gh read is memoised for
    # board_section below (both pipelines run in their own subshell).
    # Guarded on `command -v`: bin/lib/triage-hotfix-lib.sh is normally sourced
    # by bin/run-triage.sh, but a caller that lifts this line alone (this is
    # the assignment tests/ready-queue-rows-test.sh drives verbatim) must still
    # get the file's plain lines rather than a "command not found" abort.
    command -v triage_hot_load >/dev/null 2>&1 && triage_hot_load
    QLINES=$(rq_lines "$HARNESS" "$PROJECT" 2>/dev/null | { command -v triage_hot_mark >/dev/null 2>&1 && triage_hot_mark queue || cat; } | head -40)
    # THE QUEUE, DB FIRST (2026-09-10). Until now this listed a directory, which
    # meant a queued build was only visible to the box holding the file. The
    # rows carry the same entries plus what a filename could not: target,
    # attempt, and who claimed it — so the session can tell a build already
    # running on a fly machine from one still waiting for a slot.
    # Fail-open and fall-through: an outage, an old client, or an empty table
    # (which is what the transition looks like until the producers land) all
    # drop straight back to the directory listing this line has always done.
    QDIRS=""
    if command -v queue_list >/dev/null 2>&1; then
      QDIRS=$(queue_list "$PROJECT" queued 2>/dev/null \
        | awk -F'\t' '{printf "%s (target %s, attempt %s, queued %s)\n", $2, $5, $6, $8}' | head -20)
    fi
    [ -n "$QDIRS" ] || QDIRS=$(ls "$HARNESS/state/build-queue/$PROJECT/" 2>/dev/null | head -20)
    board_section
    if [ -n "$QLINES$QDIRS" ] && [ "$BOARD_OK" = 1 ]; then
      SCOPE_N=queue
      PROMPT_TEXT="TICK SCOPE (queue — deterministic): this tick fired because queue-side state changed, not the board. The queue right now:
READY-QUEUE lines:
${QLINES:-(none)}
Queued launch requests for $PROJECT (from the coordination DB):
${QDIRS:-(none)}

Work ONLY the queue this tick, per the SOP's queue and launch rules: for each line, verify its gating condition against reality (blocking PR merged? in-flight build finished? free slots per free-slots.sh <project> — its first word, where 'unlimited' means this project is Fly-routed and the local slot gate does not apply?), launch what is genuinely unblocked, drop lines that are satisfied or superseded, leave the rest. Results-sweep rules still apply to any finished build you encounter. Fetch ONLY the board tickets these lines name (a key that does not resolve on this project's board belongs to another lane on this box — ignore it) — SKIP the full board/ticket enumeration: the board fingerprint was re-checked at the start of this tick.$([ -n "$BOARD_SEC" ] && printf '\n\n%s' "$BOARD_SEC")$(HS=$(hot_sop "$QLINES$BOARD_SEC"); [ -n "$HS" ] && printf '\n\n%s' "$HS")
If the queue state looks inconsistent with reality (a named PR or ticket is missing), discard this scope and run the full SOP instead.

$PROMPT_TEXT"
    fi
    ;;
  results-sweep|remote-results-pending)
    RDIRS=$(rt_unswept_dirs)
    board_section
    if [ -n "$RDIRS" ] && [ "$BOARD_OK" = 1 ]; then
      SCOPE_N=sweep
      PROMPT_TEXT="TICK SCOPE (results sweep — deterministic): this tick fired because these finished builds await their board close-out (dir :: first RESULT line):
$RDIRS

Handle ONLY these result dirs this tick, per the SOP's sweep rules: read each dir's RESULT in full, post the close-out comment on its ticket (direct production links included), set the ticket's status, mark the dir COMMENTED. Queue rules still apply to any launch these close-outs unblock. Fetch ONLY the tickets these dirs name — SKIP the full board/ticket enumeration: the board fingerprint was re-checked at the start of this tick.$([ -n "$BOARD_SEC" ] && printf '\n\n%s' "$BOARD_SEC")$(HS=$(hot_sop "$BOARD_SEC"); [ -n "$HS" ] && printf '\n\n%s' "$HS")
If a dir or its ticket looks inconsistent (missing ticket, unparseable RESULT), handle the others and note the odd one; if the whole list looks wrong, discard this scope and run the full SOP instead.

$PROMPT_TEXT"
    fi
    ;;
esac
# BH-7117: a full-sweep tick leads with the open hotfixes. Loaded here, in the
# parent shell, so the note's subshell reads the tick's one memoised answer.
if [ "${SCOPE_N:-}" = full ] && command -v triage_hot_full_note >/dev/null 2>&1; then
  triage_hot_load; HOT_NOTE=$(triage_hot_full_note)
  [ -z "$HOT_NOTE" ] || PROMPT_TEXT="$HOT_NOTE

$PROMPT_TEXT"
fi
# BH-3949: one `triage-park: N parked (KEYS)` line per tick and the stale
# alert-once markers pruned (bin/lib/triage-park.sh). The last step of the scope
# stage, so it runs before rt_shards, which exits the tick when it dispatches;
# not in shards.sh, which BH-3418 keeps unedited. No lib = the tick as before.
[ -r "$HARNESS/bin/lib/triage-park.sh" ] && . "$HARNESS/bin/lib/triage-park.sh" 2>/dev/null && triage_park_tick_line "$HARNESS" "$PROJECT"
}

# rt_unswept_dirs — the results sweep's reading list: every builds/<p>-*/ and
# builds/pool-<p>-*/ dir with a RESULT and no COMMENTED, one
# `<dir> :: <first RESULT line>` per line, NEWEST RESULT FIRST, at most 30.
# BH-3953: the list used to be the glob's NAME order cut at 30, so with 30 older
# un-commented dirs sorting first (BH-3001..3030) a fresh BH-3859 result never
# made it, and the sweep that result fired bought shards for everyone else.
# Ties keep glob order (sort -s); a RESULT that vanishes mid-list sorts last.
rt_unswept_dirs() {
  local d m
  for d in "$HARNESS/builds/$PROJECT"-*/ "$HARNESS/builds/pool-$PROJECT"-*/; do
    [ -f "$d/RESULT" ] && [ ! -f "$d/COMMENTED" ] || continue
    m=$(stat -c %Y "$d/RESULT" 2>/dev/null) || m=0
    printf '%s\t%s :: %s\n' "${m:-0}" "${d%/}" "$(head -c 200 "$d/RESULT" 2>/dev/null | head -1)"
  done 2>/dev/null | sort -s -rn -k1,1 | cut -f2- | head -30
}
