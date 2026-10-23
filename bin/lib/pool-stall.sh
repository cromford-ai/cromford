#!/bin/bash
# bin/lib/pool-stall.sh — the pool's stall alert and its in-flight HOLD cancel
# (BH-7107).
#
# TWO HALVES.
#   1. Pure deciders: no network, no clock, no environment. Every input is an
#      argument, every answer is one line on stdout. tests/fly-pool-stall-
#      reclaim.bh-7107-test.sh drives them as tables.
#        pool_stall_verdict, pool_stall_cause,
#        pool_inflight_hold_action, pool_inflight_hold_due, pool_inflight_hold_grace
#   2. Two tick steps that run in bin/fly-pool.sh's own shell, the way
#      bin/lib/pool-actor-gate.sh does. They use the caller's P, HARNESS, say,
#      QROW, destroy_machine and the hold-gate functions, so the hotspot file
#      carries one call line each.
#        pool_stall_step, pool_inflight_hold_step
#
# The root is ${HARNESS:-} and nothing else (D43): with no root, a step does
# nothing and returns non-zero.

_ps_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }
_ps_sint() { case "${1:-}" in -) return 1 ;; -*) _ps_int "${1#-}" ;; *) _ps_int "$1" ;; esac; }

# pool_stall_verdict <queued> <budget> <hot_extra> <building|unknown> <ok|missing>
#                    <since_epoch|-> <now> <threshold_s>
# -> `clear`, `pending<TAB><age_s>` or `stall<TAB><age_s>`.
# Stalled now: token missing with queued > 0, OR queued > 0 with no budget, no
# hotfix exemption and no machine building (0, or unknown when the listing was
# unusable). The age is now - since; `-` (first stalled tick) is age 0. age >=
# threshold is a stall. threshold 0 = off (always clear). A non-number in any
# count is `clear` and rc 2: a count this tick could not read is never a stall.
pool_stall_verdict() {
  local q="${1:-}" b="${2:-}" h="${3:-}" bl="${4:-}" tok="${5:-}" since="${6:-}" now="${7:-}" thr="${8:-}" age stalled=0
  _ps_int "$q" && _ps_sint "$b" && _ps_int "$h" && _ps_int "$now" && _ps_int "$thr" \
    || { printf 'clear\n'; return 2; }
  case "$bl" in unknown) ;; *) _ps_int "$bl" || { printf 'clear\n'; return 2; } ;; esac
  case "$since" in -) ;; *) _ps_int "$since" || { printf 'clear\n'; return 2; } ;; esac
  [ "$thr" = 0 ] && { printf 'clear\n'; return 0; }
  if [ "$q" -gt 0 ]; then
    if [ "$tok" = missing ]; then stalled=1
    elif [ "$b" -le 0 ] && [ "$h" = 0 ] && { [ "$bl" = unknown ] || [ "$bl" = 0 ]; }; then stalled=1
    fi
  fi
  [ "$stalled" = 1 ] || { printf 'clear\n'; return 0; }
  age=0; [ "$since" = - ] || age=$((now - since))
  [ "$age" -lt 0 ] && age=0
  if [ "$age" -ge "$thr" ]; then printf 'stall\t%s\n' "$age"; else printf 'pending\t%s\n' "$age"; fi
  return 0
}

# pool_stall_cause <token-src|missing> <list_ok 0|1> <list_why> <live> <building|unknown>
#                  <orphans> <scoped-token-name>
# -> one plain line that names why the slots are not turning over.
pool_stall_cause() {
  local src="${1:-}" lok="${2:-0}" why="${3:-}" live="${4:-0}" bl="${5:-unknown}" orph="${6:-0}" tv="${7:-FLY_API_TOKEN_<P>}"
  if [ "$src" = missing ] || [ -z "$src" ]; then
    printf 'no Fly token (%s or FLY_API_TOKEN) in fly.env: the pool cannot reap, sweep or spawn\n' "$tv"
    return 0
  fi
  if [ "$lok" != 1 ]; then
    printf 'machines list unusable (%s): cannot tell if the %s held slots are building\n' "${why:-no answer}" "$live"
    return 0
  fi
  if _ps_int "$orph" && [ "$orph" -gt 0 ]; then
    printf '%s slots held by %s job files, %s building: %s on machines Fly does not list\n' "$live" "$live" "$bl" "$orph"
  else
    printf '%s slots held by %s job files, %s building: every held machine is listed, none is started\n' "$live" "$live" "$bl"
  fi
  return 0
}

# pool_inflight_hold_action <verdict-line> -> park | requeue | keep
# The verdict is bin/lib/hold.sh's `<state><TAB><why>`. A closed issue parks the
# row (the spawn gate does the same). Any other held reason (a HOLD comment, the
# hold label, a title or body hold, an ABANDON comment) requeues it, so the spawn
# gate holds it until the HOLD lifts. `label-absent` is KEPT: the decompose and
# rollout lanes take ai-build off a parent while its machine still works.
# clear, unreadable and anything else are kept: a read that did not answer
# never cancels a build.
pool_inflight_hold_action() {
  local v="${1:-}"
  case "$v" in
    "held	closed")       printf 'park\n' ;;
    "held	label-absent") printf 'keep\n' ;;
    "held	"?*)           printf 'requeue\n' ;;
    *)                     printf 'keep\n' ;;
  esac
  return 0
}

# pool_inflight_hold_due <ticket> <key> <list_state> <in_listing 0|1> <listing_key>
#                        <last_key> <reads_used> <reads_max>
# -> `read` or `skip<TAB><why>`.
# Only GitHub-issue tickets (a number) are read; a board cuid, an RB- rebase
# key and an RR- re-review key are not. reads_max 0 is off. A listing that is not `ok` cannot say what
# changed, so nothing is read. The key compared is the listing's
# `updated_at|comments`, or `absent` when the issue is not in the open ai-build
# listing (closed, or the label is gone); an unchanged key is not re-read, which
# bounds an absent issue to one read until it changes. Past reads_max the read
# is deferred to the next tick, and the caller says so.
pool_inflight_hold_due() {
  local t="${1:-}" k="${2:-}" ls="${3:-}" inl="${4:-0}" lk="${5:-}" last="${6:-}" used="${7:-}" max="${8:-}" eff
  case "$t" in ''|*[!0-9]*) printf 'skip\tboard-ticket\n'; return 0 ;; esac
  case "$k" in RB-*) printf 'skip\trebase\n'; return 0 ;; RR-*) printf 'skip\trereview\n'; return 0 ;; CP-*) printf 'skip\tconsole-preview\n'; return 0 ;; esac
  { _ps_int "$max" && [ "$max" -gt 0 ]; } || { printf 'skip\toff\n'; return 0; }
  _ps_int "$used" || used=0
  [ "$ls" = ok ] || { printf 'skip\tlisting %s\n' "${ls:-none}"; return 0; }
  eff=absent; [ "$inl" = 1 ] && eff="$lk"
  [ -n "$last" ] && [ "$eff" = "$last" ] && { printf 'skip\tunchanged\n'; return 0; }
  [ "$used" -ge "$max" ] && { printf 'skip\tbudget\n'; return 0; }
  printf 'read\n'
  return 0
}

# pool_inflight_hold_grace <first_seen_epoch|-> <now> <grace_s> -> wait | act
# A verdict acts once it has stood grace_s (>=). A build that closes its own
# issue on merge writes its RESULT inside the window, and the RESULT arm of the
# reap takes it first.
pool_inflight_hold_grace() {
  local s="${1:-}" now="${2:-}" g="${3:-}"
  _ps_int "$s" && _ps_int "$now" && _ps_int "$g" || { printf 'wait\n'; return 0; }
  [ "$s" -le "$now" ] || { printf 'wait\n'; return 0; }
  if [ $((now - s)) -ge "$g" ]; then printf 'act\n'; else printf 'wait\n'; fi
  return 0
}

# ════ tick steps (caller's shell) ════════════════════════════════════════════

# _ps_knob <ENV> <default> <max> — the knob as a number, or the default with one
# say line naming the bad value (D11).
_ps_knob() {
  local n="${1:-}" d="${2:-}" mx="${3:-}" v
  v="${!n:-$d}"
  if ! _ps_int "$v" || { [ -n "$mx" ] && [ "$v" -gt "$mx" ]; }; then
    declare -F say >/dev/null 2>&1 && say "$n=$v is not a number of 0-$mx — using $d"
    v="$d"
  fi
  printf '%s\n' "$v"
}

# pool_stall_step <queued> <budget> <hot_extra> <building|unknown> <ok|missing> <cause>
# Keeps state/pool-stall/<p>.json {since,cause} while the pool is stalled and
# removes it on a clear tick. On a stall: one say line every tick, and one
# ALERTS line per project per hour (flags/alerted-pool-stall-<p>-h<HH>-<YYYYmmdd>,
# pruned by bin/alerts-groom.sh). The flag is written before the send, as the
# orphan alert does: a crash between them loses one line, never pages twice.
pool_stall_step() {
  local q="${1:-}" b="${2:-}" h="${3:-}" bl="${4:-}" tok="${5:-}" cause="${6:-}"
  local root="${HARNESS:-}" thr sf since now out st age af tmp
  [ -n "$root" ] && [ -n "${P:-}" ] || return 1
  thr=$(_ps_knob POOL_STALL_ALERT_S 1800 86400)
  sf="$root/state/pool-stall/$P.json"
  since=$(jq -r '.since // "-"' "$sf" 2>/dev/null); _ps_int "$since" || since=-
  now=$(date +%s)
  out=$(pool_stall_verdict "$q" "$b" "$h" "$bl" "$tok" "$since" "$now" "$thr")
  st="${out%%	*}"; age="${out#*	}"
  case "$st" in
    clear) rm -f "$sf"; return 0 ;;
  esac
  [ "$since" = - ] && since="$now"
  mkdir -p "$root/state/pool-stall" 2>/dev/null
  tmp="$sf.tmp.$$"
  jq -nc --argjson s "$since" --arg c "$cause" '{since:$s,cause:$c}' > "$tmp" 2>/dev/null && mv -f "$tmp" "$sf" || rm -f "$tmp"
  [ "$st" = stall ] || return 0
  declare -F say >/dev/null 2>&1 && say "stall: queued $q, building $bl, for $((age / 60))m: $cause"
  # The hour flag goes through bin/lib/flags.sh (BH-4153; the file
  # flags/<name> on every path). The read is --cached: no worker request.
  af="alerted-pool-stall-$P-$(date -u +h%H-%Y%m%d)"
  command -v flag_set >/dev/null 2>&1 \
    || . "$(dirname "${BASH_SOURCE[0]}")/flags.sh" 2>/dev/null || true
  if ! flag_has --cached "$af" 2>/dev/null; then
    flag_set "$af" on "pool-stall: stall alert sent" >/dev/null 2>&1
    HARNESS="$root" "$root/bin/alert-line.sh" "[pool/$P] queued $q, building $bl, for $((age / 60))m: $cause"
  fi
  return 0
}

# pool_stall_no_token <scoped-token-name> <queued> <live> — the tick has an
# app and no Fly token: nothing can be reaped, swept or spawned. The caller
# counts the queue and job files (no flyctl call can be made to ask more);
# building is unknown. A non-number count is 0.
pool_stall_no_token() {
  local tv="${1:-}" q="${2:-0}" live="${3:-0}"
  [ -n "${HARNESS:-}" ] && [ -n "${P:-}" ] || return 1
  _ps_int "$q" || q=0
  _ps_int "$live" || live=0
  pool_stall_step "$q" 0 0 unknown missing "$(pool_stall_cause missing 0 "" "$live" unknown 0 "$tv")"
  declare -F say >/dev/null 2>&1 && say "no Fly token ($tv or FLY_API_TOKEN) in fly.env: queued $q, $live job files — nothing reaped, swept or spawned this tick"
  return 0
}

# pool_stall_tick — after the spawn budget. Reads the caller's QUEUED BUDGET
# HOTFIX_EXTRA LIVE POOL LISTING LIST_OK LIST_WHY FLY_TOKEN_SRC TV. The machines
# are counted only when the counts already say "no slot": building is the job
# files whose machine this tick's listing has `started`, orphans those it does
# not list at all; an unusable listing makes building `unknown`, never 0.
pool_stall_tick() {
  local bl=0 orph=0 f m st
  if _ps_int "${QUEUED:-}" && [ "$QUEUED" -gt 0 ] && _ps_sint "${BUDGET:-}" && [ "$BUDGET" -le 0 ] && [ "${HOTFIX_EXTRA:-0}" = 0 ]; then
    if [ "${LIST_OK:-0}" = 1 ] && [ -s "${LISTING:-}" ]; then
      for f in "${POOL:-}"/*.json; do
        [ -f "$f" ] || continue
        m=$(jq -r '.machine // ""' "$f" 2>/dev/null)
        st=$(jq -r --arg m "$m" '[.[] | select(.id == $m) | (.state // "")][0] // "absent"' "$LISTING" 2>/dev/null)
        case "$st" in started) bl=$((bl + 1)) ;; absent) orph=$((orph + 1)) ;; esac
      done
    else
      bl=unknown
    fi
  fi
  pool_stall_step "${QUEUED:-}" "${BUDGET:-}" "${HOTFIX_EXTRA:-0}" "$bl" ok \
    "$(pool_stall_cause "${FLY_TOKEN_SRC:-}" "${LIST_OK:-0}" "${LIST_WHY:-}" "${LIVE:-0}" "$bl" "$orph" "${TV:-}")"
}

# pool_inflight_hold_step — inside the reap, for a LIVE machine that has no
# RESULT this tick (DEAD=0). rc 0 = the build was cancelled and its file is
# gone (the caller `continue`s), rc 1 = the machine keeps running.
# Reads the caller's MF MID KEY TICKET ATT DEFC DTHS SBASE MHF QDIR POOL.
# The verdict and the first time it was seen ride the machine json as
# .inflight_hold {ticket,key,verdict,seen_at}, so the grace survives ticks and
# an unchanged listing key costs no thread read.
_PIH_MAX=""; _PIH_GRACE=""; _PIH_USED=0
pool_inflight_hold_step() {
  local rec rt last lastv seen lk inl ls due v act g now why tmp rec_out
  [ -n "${HARNESS:-}" ] && [ -f "${MF:-}" ] || return 1
  if [ -z "$_PIH_MAX" ]; then
    _PIH_MAX=$(_ps_knob POOL_INFLIGHT_HOLD_READS 4 50)
    _PIH_GRACE=$(_ps_knob POOL_INFLIGHT_HOLD_GRACE_S 600 86400)
  fi
  [ "$_PIH_MAX" = 0 ] && return 1
  case "${TICKET:-}" in ''|*[!0-9]*) return 1 ;; esac
  case "${KEY:-}" in RB-*|RR-*|CP-*) return 1 ;; esac
  command -v pool_hold_check >/dev/null 2>&1 && command -v pool_hold_list_prime >/dev/null 2>&1 || return 1
  command -v pool_hold_cache_knobs >/dev/null 2>&1 && pool_hold_cache_knobs
  pool_hold_list_prime
  ls="${_POOL_HOLD_LIST:-}"
  lk="${_POOL_HOLD_LKEY[$TICKET]:-}"; inl=0; [ -n "$lk" ] && inl=1
  rec=$(jq -c '.inflight_hold // empty' "$MF" 2>/dev/null)
  rt=""; [ -n "$rec" ] && rt=$(jq -r '.ticket // ""' <<<"$rec" 2>/dev/null)
  if [ -n "$rec" ] && [ "$rt" = "$TICKET" ]; then
    last=$(jq -r '.key // ""' <<<"$rec"); lastv=$(jq -r '.verdict // ""' <<<"$rec"); seen=$(jq -r '.seen_at // "-"' <<<"$rec")
  else
    last=""; lastv=""; seen=-
  fi
  _ps_int "$seen" || seen=-
  v=""
  if command -v pool_hold_cache_lookup >/dev/null 2>&1 && pool_hold_cache_lookup "$TICKET"; then
    v="$_PHC_V"
    last=absent; [ "$inl" = 1 ] && last="$lk"
  else
    due=$(pool_inflight_hold_due "$TICKET" "$KEY" "$ls" "$inl" "$lk" "$last" "$_PIH_USED" "$_PIH_MAX")
    case "$due" in
      read)
        _PIH_USED=$((_PIH_USED + 1))
        v=$(pool_hold_check "$TICKET" 2>/dev/null) || true
        command -v pool_hold_cache_store >/dev/null 2>&1 && pool_hold_cache_store "$TICKET" "$v"
        # A read that did not answer changes nothing: the record stays as it
        # was, so the next tick reads again, and nothing is cancelled.
        case "$v" in held*|clear*) ;; *) say "in-flight hold read for $KEY unreadable (${v:-no answer}) — the build keeps running"; return 1 ;; esac
        last=absent; [ "$inl" = 1 ] && last="$lk" ;;
      "skip	unchanged") v="$lastv" ;;
      "skip	budget")
        say "in-flight hold read for $KEY deferred: $_PIH_USED of $_PIH_MAX reads used this tick (POOL_INFLIGHT_HOLD_READS) — read next tick"
        return 1 ;;
      *) return 1 ;;
    esac
  fi
  act=$(pool_inflight_hold_action "$v")
  now=$(date +%s)
  if [ "$act" = keep ]; then seen=-; elif [ "$seen" = - ] || [ "$(pool_inflight_hold_action "$lastv")" != "$act" ]; then seen="$now"; fi
  rec_out=$(jq -nc --arg t "$TICKET" --arg k "$last" --arg v "$v" --arg s "$seen" \
    '{ticket:$t,key:$k,verdict:$v,seen_at:(if $s == "-" then null else ($s|tonumber) end)}')
  tmp="$MF.tmp.$$"
  jq -c --argjson r "$rec_out" '.inflight_hold = $r' "$MF" > "$tmp" 2>/dev/null && mv -f "$tmp" "$MF" || rm -f "$tmp"
  [ "$act" = keep ] && return 1
  why="${v#held	}"
  g=$(pool_inflight_hold_grace "$seen" "$now" "$_PIH_GRACE")
  if [ "$g" != act ]; then
    say "in-flight $KEY on $MID: ticket $TICKET $why — cancel after ${_PIH_GRACE}s (seen $((now - seen))s ago)"
    return 1
  fi
  destroy_machine "$MID" "in-flight cancel: ticket $TICKET $why"
  rm -f "$MF" "$POOL/.$MID.snapmt"
  command -v machines_row_close >/dev/null 2>&1 && machines_row_close "$MID"
  command -v pool_account_release >/dev/null 2>&1 && pool_account_release "$MID"
  if [ "$act" = park ]; then
    QROW failed "$KEY" "ticket $TICKET is closed — in-flight build cancelled, pool slot released"
    command -v pool_hold_clear >/dev/null 2>&1 && { pool_hold_clear "$KEY" || true; }
  else
    if QROW requeue "$KEY" "ticket $TICKET is held ($why) — in-flight build cancelled, pool slot released" "$ATT" \
         "$(jq -nc --argjson d "$DEFC" --argjson x "$DTHS" --arg sb "$SBASE" --arg hf "$MHF" '{deferrals:$d,deaths:$x} + (if $sb == "" then {} else {stack_base:$sb} end) + (if $hf == "true" then {hotfix:true} else {} end)')" "$TICKET"; then
      jq -nc --arg t "$TICKET" --arg k "$KEY" --argjson a "$ATT" --argjson d "$DEFC" --argjson x "$DTHS" --arg ts "$(STAMP)" --arg sb "$SBASE" --arg hf "$MHF" \
        '{ticket_id:$t,key:$k,attempt:$a,deferrals:$d,deaths:$x,enqueued_at:$ts} + (if $sb == "" then {} else {stack_base:$sb} end) + (if $hf == "true" then {hotfix:true} else {} end)' > "$QDIR/$KEY.json"
    fi
  fi
  say "cancelled in-flight $KEY on $MID: ticket $TICKET $why (held since $(date -u -d "@$seen" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "$seen"))"
  return 0
}
