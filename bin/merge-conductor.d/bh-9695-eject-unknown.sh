# shellcheck shell=bash
# bin/merge-conductor.d/bh-9695-eject-unknown.sh - A SECOND EJECTION WITH NO
# NAMED CAUSE GETS ONE MERGIFY EVENT READ AND ONE MORE REQUEUE (BH-9695).
# Sourced by bin/merge-conductor.sh (the BH-7453 fragment block); functions
# only, no side effect at source time.
#
# WHY. In the 7 days to 2026-11-14, 17 of 23 `queue-ejected-twice` parks had
# the cause `unknown (no Mergify dequeue reason)`: the comments read of
# bin/lib/mc-eject-cause.sh found no Mergify dequeue comment for the head. A
# park with no cause hands a fix round a PR it has nothing to fix in.
#
# THE RULE. At the second ejection of a head (EJN >= 2) whose newest
# eject-cause record line is `unknown`:
#   1. ONE read of Mergify's activity log for the PR
#      (bin/lib/vendor/mergify.sh mergify_queue_leave_events). The newest
#      `action.queue.leave` event that is not a merge, for this head (or with
#      no head), names the cause (mc_eu_event_cause). It is written as one
#      eject-cause record line, ord `event`. Mark `ejunkread <key> <head>`
#      goes in BEFORE the read: one read per head, a crash costs the read.
#   2. A named cause: the park stands, and its reason names the cause
#      (ec_summary reads the `event` line).
#   3. Still unknown: ONE more requeue (mark `ejunkrq <key> <head>` FIRST,
#      then `requeued`, then the `reejected` line is cleared, then
#      mc_requeue_mergify). The head is then in the state of a first requeue.
#   4. Ejected again: `reejected` comes back, EJN is 2, and mc_eu_decide
#      answers park:extra-spent. The park reason ends with mc_eu_why:
#      ` — no named cause after the Mergify event read and one more requeue
#      (BH-9695)`. That is the cap.
# A batch victim's solo requeue (BH-9253, `batchvictim`) counts as the one
# extra requeue. A culprit head (`dqwculprit`, BH-5819) is never requeued. A
# park already handed to the fix round (`ejectfix`) is left to it.
#
# THE VERBS (Mergify repos only):
#   mc_eu_event_cause <head>     stdin: the seam's JSON. PURE.
#                                Prints <cause>\t<detail>.
#   mc_eu_decide <knob> <provider> <final> <extra> <solo> <culprit> <fix>
#                <rec-cause> <event-cause> <bound> <merges>
#                                PURE: `requeue`, `observe` or `park:<why>`
#   mc_eu_requeue <project> <slug> <key> <head> <url>
#                                rc 0 requeued (the caller must not park);
#                                rc 1 park as before; rc 2 deferred (the
#                                caller parks with no fix round; the
#                                parked-row pass asks again next tick)
#   mc_eu_ord <key> <head> <ord> `extra` after the extra requeue, else <ord>
#   mc_eu_why <key> <head>       the park reason suffix, or nothing
#
# KNOBS (catalog/lanes.d/merge-conductor.knobs.d/, read through lane_knob):
#   MC_EJECT_UNKNOWN_REQUEUE=1  0 = off: every second ejection parks as before
#   MC_EJECT_EVENT_READS=3      Mergify reads per project per tick; 0 = no read
# Log lines: EJECT_UNKNOWN_EVENT <key> <h8> <cause> (<detail>), once per read;
# EJECT_UNKNOWN_REQUEUE <key> <head>, once per requeue; EJECT_UNKNOWN_PARK
# <key> <h8> <why>, once per (key, head, final why).

# _mc_eu_final — the park answers that do not change while the head stays.
_mc_eu_final() { printf '%s' "named named-event extra-spent solo-tried culprit"; }

# _mc_eu_knob <ENV> <fallback> — the settings row lane.merge-conductor.<env
#   lower> through lane_knob, else the env var, else <fallback>. A value that
#   is not a non-negative integer reads as <fallback>. Rows:
#   lane.merge-conductor.mc_eject_unknown_requeue (fallback 1) and
#   lane.merge-conductor.mc_eject_event_reads (fallback 3).
_mc_eu_knob() {
  local v=""
  if command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob merge-conductor "$1" "${P:-}" 2>/dev/null); fi
  [ -n "$v" ] || v="${!1:-}"
  case "$v" in ''|*[!0-9]*) v="$2" ;; esac
  printf '%s' "$v"
}

# mc_eu_event_cause <head> — see the header. stdin: the activity-log JSON.
#   checks    CHECKS_FAILED or BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS with
#             check names (unsuccessful_checks: strings or {name})
#   conflict  CONFLICT_WITH_BASE_BRANCH
#   timeout   CHECKS_TIMEOUT
#   other     any other code (`<code>[: <reason line 1>]`), or no code and a
#             reason (`<reason line 1>`)
#   unknown   no such event, a body that is not JSON, or no code and no reason
#   The code match is exact (case and length).
mc_eu_event_cause() {
  local head="${1:-}" body row code reason names
  body=$(cat)
  if ! row=$(jq -r --arg h "$head" '
      def same(a; b): (a | length) >= 7 and (b | length) >= 7 and ((a | startswith(b)) or (b | startswith(a)));
      if type != "object" then error("not an object") else . end
      | [ (.events // [])[]? | select(type == "object")
          | select((.type // "") == "action.queue.leave")
          | select(((.metadata // {}) | type) == "object")
          | select((.metadata.merged // false) != true)
          | select(((.metadata.pull_request_head_sha // "") | tostring) as $s | $s == "" or same($s; $h)) ]
      | sort_by([(.received_at // "" | tostring), (.id // 0)]) | last
      | if . == null then empty else
          [ (.metadata.dequeue_code // "" | tostring),
            (.metadata.reason // "" | tostring | split("\n") | map(select(test("\\S"))) | (.[0] // "")),
            ([ .metadata.unsuccessful_checks[]? | if type == "object" then (.name // "" | tostring) else tostring end
               | select(. != "") ] | join(", ")) ] | map(gsub("[\u001f\n\r]"; " ")) | join("\u001f")
        end' <<<"$body" 2>/dev/null); then
    printf 'unknown\tevent read failed (not a JSON object)\n'; return 0
  fi
  if [ -z "$row" ]; then
    printf 'unknown\tno queue.leave event for %s\n' "${head:0:8}"; return 0
  fi
  # A unit separator, not a tab: IFS whitespace would fold an empty code.
  IFS=$'\x1f' read -r code reason names <<<"$row"
  reason="${reason#"${reason%%[![:space:]]*}"}"
  case "$code" in
    CHECKS_FAILED|BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS)
      if [ -n "$names" ]; then printf 'checks\t%s\n' "$(_ec_clean "$names")"; return 0; fi ;;
    CONFLICT_WITH_BASE_BRANCH) printf 'conflict\t%s\n' "$code"; return 0 ;;
    CHECKS_TIMEOUT) printf 'timeout\t%s\n' "$code"; return 0 ;;
  esac
  if [ -n "$code" ]; then
    printf 'other\t%s\n' "$(_ec_clean "$code${reason:+: $reason}")"
  elif [ -n "$reason" ]; then
    printf 'other\t%s\n' "$(_ec_clean "$reason")"
  else
    printf 'unknown\tevent names no cause\n'
  fi
}

# mc_eu_decide — PURE, see the header. The first rule that holds answers:
#   off, provider, final (a cached final park), extra-spent, solo-tried,
#   culprit, fix-round, no-record (no record line: a stale-dequeue park),
#   named (the record names a cause), named-event, unbound, observe, requeue.
#   An empty event cause is `unknown`: a failed read never names a cause.
mc_eu_decide() {
  local knob="${1:-1}" prov="${2:-}" final="${3:-0}" extra="${4:-0}" solo="${5:-0}" culprit="${6:-0}"
  local fix="${7:-0}" rec="${8:-}" ev="${9:-}" bound="${10:-0}" merges="${11:-0}"
  [ "$knob" != 0 ] || { printf 'park:off'; return 0; }
  [ "$prov" = mergify ] || { printf 'park:provider'; return 0; }
  [ "$final" != 1 ] || { printf 'park:final'; return 0; }
  [ "$extra" != 1 ] || { printf 'park:extra-spent'; return 0; }
  [ "$solo" != 1 ] || { printf 'park:solo-tried'; return 0; }
  [ "$culprit" != 1 ] || { printf 'park:culprit'; return 0; }
  [ "$fix" != 1 ] || { printf 'park:fix-round'; return 0; }
  [ -n "$rec" ] || { printf 'park:no-record'; return 0; }
  [ "$rec" = unknown ] || { printf 'park:named'; return 0; }
  [ -z "$ev" ] || [ "$ev" = unknown ] || { printf 'park:named-event'; return 0; }
  [ "$bound" = 1 ] || { printf 'park:unbound'; return 0; }
  [ "$merges" = 1 ] || { printf 'observe'; return 0; }
  printf 'requeue'
}

# _mc_eu_cause <slug> <num> <head> <ord|-> — the cause word of the newest
#   record line for head: of that ord, or (with `-`) of any ord but `event`.
#   Nothing with no line (the bin/lib/mc-eject-cause.sh record, prefix rule).
_mc_eu_cause() {
  local f
  command -v ec_file >/dev/null 2>&1 || return 0
  f=$(ec_file "$1" "$2") || return 0
  [ -r "$f" ] || return 0
  awk -F'\t' -v h="$3" -v o="$4" '
    function same(a, b) { return length(a) >= 7 && length(b) >= 7 && (index(a, b) == 1 || index(b, a) == 1) }
    same($2, h) && ((o == "-" && $3 != "event") || (o != "-" && $3 == o)) { c = $4 }
    END { if (c != "") print c }' "$f" 2>/dev/null
}

# _mc_eu_park <key> <head> <word> — a final word is marked `eupark` and logged
#   once per (key, head, why). rc 1 always, so a caller can `return` it.
_mc_eu_park() {
  local w="${3#park:}" f
  for f in $(_mc_eu_final); do
    [ "$f" = "$w" ] || continue
    mc_attempt_has "eupark $1 $2 $3" 2>/dev/null && return 1
    mc_attempt_put "eupark $1 $2 $3"
    mc_log "EJECT_UNKNOWN_PARK $1 ${2:0:8} $w — the queue-ejected-twice park stands (BH-9695)"
    return 1
  done
  return 1
}

# _mc_eu_read <slug> <num> — the seam's answer on stdout, its rc. The seam is
#   sourced on first use, so the fragment has no side effect at source time.
_mc_eu_read() {
  if ! command -v mergify_queue_leave_events >/dev/null 2>&1; then
    # shellcheck source=../lib/vendor/mergify.sh
    . "${BASH_SOURCE[0]%/*}/../lib/vendor/mergify.sh" 2>/dev/null || return 2
  fi
  mergify_queue_leave_events MERGIFY_API_TOKEN "$1" "$2"
}

# mc_eu_requeue <project> <slug> <key> <head> <url> — see the header. Reads,
#   cheapest first: ledger marks; the record (no network); one Mergify read per
#   head under the per-tick budget `ejevent`; the verdict and the live head;
#   the requeue budget.
mc_eu_requeue() {
  local p="$1" slug="$2" key="$3" head="$4" url="$5" n knob w word final=0 extra=0 solo=0 culprit=0 fix=0
  local rec ev="" evd="" reads out rrc bound=0 recf v vprov vrev vjob vhb live rc why
  [ -n "$key" ] && [ -n "$head" ] && [ -n "$url" ] || return 1
  n="${key##*#}"
  knob=$(_mc_eu_knob MC_EJECT_UNKNOWN_REQUEUE 1)
  for w in $(_mc_eu_final); do mc_attempt_has "eupark $key $head park:$w" 2>/dev/null && { final=1; break; }; done
  mc_attempt_has "ejunkrq $key $head" 2>/dev/null && extra=1
  mc_attempt_has "batchvictim $key $head" 2>/dev/null && solo=1
  mc_attempt_has "dqwculprit $key $head" 2>/dev/null && culprit=1
  mc_attempt_has "ejectfix $key $head" 2>/dev/null && fix=1
  # The marks alone: with every later input set to "go on", any park here is
  # decided by a mark, and nothing is read.
  word=$(mc_eu_decide "$knob" "${PROVIDER:-}" "$final" "$extra" "$solo" "$culprit" "$fix" unknown unknown 1 1)
  case "$word" in park:*) _mc_eu_park "$key" "$head" "$word"; return 1 ;; esac
  rec=$(_mc_eu_cause "$slug" "$n" "$head" -)
  if [ "$rec" = unknown ]; then
    if mc_attempt_has "ejunkread $key $head" 2>/dev/null; then
      # Read once already: its answer is the record's `event` line.
      ev=$(_mc_eu_cause "$slug" "$n" "$head" event); [ -n "$ev" ] || ev=unknown
    else
      reads=$(_mc_eu_knob MC_EJECT_EVENT_READS 3)
      if [ "$reads" = 0 ]; then
        ev=unknown
      elif ! mc_tick_budget_take "$p" ejevent "$reads"; then
        mc_log "$key ${head:0:8} has no named ejection cause, but this tick's Mergify event reads (MC_EJECT_EVENT_READS=$reads) are spent — the park stands and the parked-row pass asks again next tick"
        return 2
      else
        mc_attempt_put "ejunkread $key $head"
        rrc=0; out=$(_mc_eu_read "$slug" "$n" 2>/dev/null) || rrc=$?
        if [ "$rrc" = 0 ]; then
          IFS=$'\t' read -r ev evd <<<"$(printf '%s\n' "$out" | mc_eu_event_cause "$head")"
        else
          ev=unknown; evd="event read failed (rc $rrc)"
        fi
        [ -n "$ev" ] || { ev=unknown; evd="event read failed (no answer)"; }
        command -v ec_record >/dev/null 2>&1 && ec_record "$slug" "$n" "$head" event "$ev" "$evd"
        mc_log "EJECT_UNKNOWN_EVENT $key ${head:0:8} $ev${evd:+ ($evd)}"
      fi
    fi
  fi
  if [ "$rec" = unknown ] && [ "$ev" = unknown ]; then
    recf=$(mc_record_for "$url" 2>/dev/null || true)
    IFS=$'\t' read -r v vprov vrev vjob vhb <<<"$(mc_verdict "$url" "$recf" 2>/dev/null)"
    [ "${v:-}" = APPROVE ] && [ "${vrev:-}" = "$head" ] && bound=1
    # The queue takes the LIVE head: a head that moved is not the one the
    # approval is about.
    if [ "$bound" = 1 ] && command -v mc_pr_view >/dev/null 2>&1; then
      live=$(mc_pr_view "$url" '.head.sha // ""' 2>/dev/null) || live=""
      [ -z "$live" ] || [ "$live" = "$head" ] || bound=0
    fi
  fi
  word=$(mc_eu_decide "$knob" "${PROVIDER:-}" "$final" "$extra" "$solo" "$culprit" "$fix" "$rec" "$ev" "$bound" "${MERGES:-0}")
  case "$word" in
    requeue) ;;
    observe)
      mc_log "$key ${head:0:8} has no named ejection cause after the Mergify event read — would requeue it once more (observe mode: nothing written; the park stands)"
      return 1 ;;
    *) _mc_eu_park "$key" "$head" "$word"; return 1 ;;
  esac
  if ! mc_tick_budget_take "$p" requeue "${MC_REQUEUE_CAP:-5}"; then
    mc_log "$key ${head:0:8} has no named ejection cause, but this tick's requeue budget (MC_REQUEUE_CAP=${MC_REQUEUE_CAP:-5}) is spent — the park stands and the parked-row pass asks again next tick"
    return 2
  fi
  # THE MARK BEFORE THE WRITE: a crash after it costs this head its extra try
  # (the `reejected` line is still there, so the row parks), never a loop.
  mc_attempt_put "ejunkrq $key $head"
  mc_requeued_record "$key" "$head"
  mc_attempt_clear reejected "$key" "$head"
  rc=0; why=$(mc_requeue_mergify "$slug" "$url" "$head") || rc=$?
  case "$rc" in
    0|2)
      mc_transition "$key" QUEUED "queue-ejected: requeued once more on ${head:0:8} (no named cause after the Mergify event read)" "$head" "$head" "$url" APPROVE UNKNOWN "${recf:--}" >/dev/null ;;
    3)
      mc_transition "$key" WAIT_CI "queue-ejected: requeued once more on ${head:0:8} (no named cause after the Mergify event read), awaiting Mergify's witness" "$head" "$head" "$url" APPROVE UNKNOWN "${recf:--}" >/dev/null ;;
    *)
      # The try is spent. `reejected` goes back, so the head reads as ejected
      # twice and no other arm puts it back.
      mc_attempt_has "reejected $key $head" 2>/dev/null || mc_attempt_put "reejected $key $head"
      mc_log "REQUEUE_FAILED $key ${head:0:8} eject unknown: the extra requeue was refused (rc $rc${why:+: $why}) — the park stands; this head's extra try is spent"
      return 1 ;;
  esac
  mc_handoff_release "$key" eject-unknown
  command -v mc_fbh_clear >/dev/null 2>&1 && mc_fbh_clear "$key" "$head" eject-unknown
  mc_log "EJECT_UNKNOWN_REQUEUE $key $head — no named cause after the Mergify event read; requeued once more, not parked (BH-9695)"
  return 0
}

# mc_eu_ord <key> <head> <ord> — the eject-cause record ord: `extra` for the
#   ejection after the extra requeue, else <ord>.
mc_eu_ord() {
  if mc_attempt_has "ejunkrq $1 $2" 2>/dev/null; then printf 'extra'; else printf '%s' "${3:-}"; fi
}

# mc_eu_why <key> <head> — the park reason suffix after the extra requeue:
#   the cap words when the newest record cause for head is `unknown`, a short
#   note when it is named, nothing when the head had no extra requeue.
mc_eu_why() {
  local key="$1" head="$2" f l c
  mc_attempt_has "ejunkrq $key $head" 2>/dev/null || return 0
  c=""
  if command -v ec_file >/dev/null 2>&1 && f=$(ec_file "${key%#*}" "${key##*#}"); then
    l=$(_ec_find "$f" "$head"); c=$(printf '%s' "$l" | cut -f4)
  fi
  if [ -z "$c" ] || [ "$c" = unknown ]; then
    printf ' — no named cause after the Mergify event read and one more requeue (BH-9695)'
  else
    printf ' — after one more requeue (BH-9695)'
  fi
}
