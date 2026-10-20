#!/bin/bash
# bin/lib/starved-ready.sh — the starved-ready alarm (BH-3970). Sourced, never
# executed; defines functions only.
#
# WHAT IT CATCHES. An in-app ticket the board says is todo + triageVerdict=ready
# + waitingOn=team, that `bin/triage-gate.sh --buildable-strict` answers OK for,
# and that NOTHING owns — no READY-QUEUE.log line or ready row, no queue row in
# queued/claimed/ready/held, no build dir — for STARVED_READY_MIN minutes. On
# project-8 (2026-10-03) 32 decompose children sat exactly like that
# for ~90 minutes while every triage tick logged `gate no-change`: each lane's
# answer was right, the work just had no owner, and no lane asked.
#
# WHERE IT RUNS. bin/lib/rt/gate.sh calls it on every triage tick, right after
# the gate's decision and before a SKIP exits, in a subshell that fails open. It
# reads the board through the gate's own stored view (state/<p>.gate.pending,
# else state/<p>.gate.json, the shape fetch_fingerprint writes) and the keymap
# beside it, so it costs no board list call. GitHub-Issues projects are not its
# business: bin/orphan-reconcile.sh is their level-triggered owner.
#
# STATE. state/starved-ready/<p>.tsv is the first-seen ledger (`id<TAB>epoch`),
# rewritten each tick with only the current candidates, so a ticket that leaves
# the set resets its clock. state/starved-ready/<p>.alerted marks an open page;
# the resolve is sent only when a tick's reads were complete and found nothing.
#
# FAIL-OPEN. An unreadable gate state or a queue read that failed is not
# starvation: no page, no resolve, the ledger untouched, one logs/<p>.log line.
#
# Knobs: catalog/lanes.d/_lib.starved-ready.json, through lib_env_apply
# starved-ready (settings row > env > the registry default these fallbacks
# mirror). Root: the caller's argument, else ${HARNESS:-${H:-}}, nothing else.

_SR_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _sr_knobs <project> — sets STARVED_READY* from lib_env_apply when the lane
# gate is present, in a subshell so its fail-closed exit cannot end the tick.
_sr_knobs() {
  local kv k v
  kv=$(
    exec 3>&1
    command -v lib_env_apply >/dev/null 2>&1 || . "$_SR_LIB/lane-gate.sh" >/dev/null 2>&1 || exit 0
    trap 'for k in STARVED_READY STARVED_READY_MIN STARVED_READY_PROBE_MAX STARVED_READY_STATUSES; do printf "%s\t%s\n" "$k" "${!k:-}" >&3; done' EXIT
    lib_env_apply starved-ready "${1:-}" >/dev/null 2>&1) || true
  while IFS=$'\t' read -r k v; do
    [ -n "$k" ] && [ -n "$v" ] || continue
    printf -v "$k" '%s' "$v"
  done <<<"$kv"
  return 0
}

# _sr_log <harness> <project> <message> — one line in the project's tick log.
_sr_log() {
  mkdir -p "$1/logs" 2>/dev/null
  printf '%s [%s] starved-ready: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$2" "$3" >> "$1/logs/$2.log" 2>/dev/null
  return 0
}

# starved_ready_check <harness> <project> — always rc 0.
starved_ready_check() {
  local h="${1:-${HARNESS:-${H:-}}}" p="${2:-}"
  [ -n "$h" ] && [ -n "$p" ] || return 0
  local bp; bp=$("$h/bin/fleet-conf.sh" "$p" board_prefix 2>/dev/null) || bp=""
  case "$bp" in ''|-) return 0 ;; esac
  _sr_knobs "$p"
  [ "${STARVED_READY:-1}" = 0 ] && return 0
  local min="${STARVED_READY_MIN:-60}" cap="${STARVED_READY_PROBE_MAX:-20}" statuses="${STARVED_READY_STATUSES:-todo}"
  case "$min" in ''|*[!0-9]*|0) min=60 ;; esac
  case "$cap" in ''|*[!0-9]*|0) cap=20 ;; esac
  local now="${STARVED_READY_NOW:-$(date +%s)}"

  local view="$h/state/$p.gate.pending"
  [ -s "$view" ] || view="$h/state/$p.gate.json"
  [ -s "$view" ] || return 0
  local km="$h/state/$p.keymap.json" keymap='{}'
  [ -s "$km" ] && keymap=$(jq -c 'if type == "object" then . else {} end' "$km" 2>/dev/null) || true
  [ -n "$keymap" ] || keymap='{}'
  # Candidates as `id<TAB>key`, in board order.
  local cands
  if ! cands=$(jq -r --argjson km "$keymap" --arg st " $statuses " '
      to_entries[] | .value | if type == "array" then .[] else empty end
      | select(type == "object")
      | select(((.status // "") | ascii_downcase) as $s | ($st | contains(" " + $s + " ")) and $s != "")
      | select(((.triageVerdict // "") | ascii_downcase) == "ready")
      | select(((.waitingOn // "") | ascii_downcase) == "team")
      | (.id | tostring) as $id
      | [$id, (.key // $km[$id] // "")] | @tsv' "$view" 2>/dev/null); then
    _sr_log "$h" "$p" "the gate state ${view##*/} is unreadable — no starvation check this tick"
    return 0
  fi

  local dir="$h/state/starved-ready" ledger marker
  ledger="$dir/$p.tsv"; marker="$dir/$p.alerted"
  mkdir -p "$dir" 2>/dev/null || return 0
  local next="" aged="" id key first
  while IFS=$'\t' read -r id key; do
    [ -n "$id" ] || continue
    first=$(awk -F'\t' -v i="$id" '$1 == i { print $2; exit }' "$ledger" 2>/dev/null)
    case "$first" in ''|*[!0-9]*) first="$now" ;; esac
    next="$next$id"$'\t'"$first"$'\n'
    [ -n "$key" ] || continue
    [ $(( now - first )) -ge $(( min * 60 )) ] && aged="$aged$id"$'\t'"$key"$'\t'"$first"$'\n'
  done <<<"$cands"

  # Ownership evidence, each read ONCE, only when something is old enough.
  local starved="" nstarved=0 complete=1 probes=0 lines="" qrows="" ans
  if [ -n "$aged" ]; then
    # ready-queue.sh brings rq_lines and, through the jobs client, queue_list.
    if ! command -v rq_lines >/dev/null 2>&1; then
      # shellcheck source=bin/lib/ready-queue.sh
      [ -r "$_SR_LIB/ready-queue.sh" ] && . "$_SR_LIB/ready-queue.sh"
    fi
    if ! command -v queue_list >/dev/null 2>&1 || ! qrows=$(queue_list "$p" 2>/dev/null); then
      _sr_log "$h" "$p" "the queue read failed — a transport failure is not starvation; no alert, no resolve, the ledger is kept"
      return 0
    fi
    command -v rq_lines >/dev/null 2>&1 && lines=$(rq_lines "$h" "$p" 2>/dev/null)
    # shellcheck source=bin/lib/build-archive.sh
    command -v ba_has_key >/dev/null 2>&1 || . "$_SR_LIB/build-archive.sh" 2>/dev/null || true
    while IFS=$'\t' read -r id key first; do
      [ -n "$id" ] || continue
      grep -qE "^${key}[[:space:]]" <<<"$lines" && continue
      awk -F'\t' -v k="$key" '$2 == k && $4 ~ /^(queued|claimed|ready|held)$/ { f=1 } END { exit !f }' <<<"$qrows" && continue
      compgen -G "$h/builds/$p-$key-*" >/dev/null 2>&1 && continue
      compgen -G "$h/builds/pool-$p-$key-*" >/dev/null 2>&1 && continue
      # An archived build dir (BH-7437) is a build dir.
      command -v ba_has_key >/dev/null 2>&1 && ba_has_key "$h" "$p" "$key" && continue
      if [ "$probes" -ge "$cap" ]; then complete=0; break; fi
      probes=$((probes + 1))
      ans=$("$h/bin/triage-gate.sh" "$p" --buildable-strict "$id" 2>/dev/null) || ans=""
      [ "$ans" = "OK" ] || continue
      nstarved=$((nstarved + 1))
      starved="$starved$id"$'\t'"$key"$'\t'"$(( (now - first) / 60 ))"$'\n'
    done <<<"$aged"
  fi
  printf '%s' "$next" > "$ledger.tmp" 2>/dev/null && mv -f "$ledger.tmp" "$ledger"

  if [ "$nstarved" -gt 0 ]; then
    local list first_key first_id more=""
    list=$(head -10 <<<"$starved" | awk -F'\t' 'NF { printf "%s%s (%sm)", (n++ ? ", " : ""), $2, $3 }')
    [ "$nstarved" -gt 10 ] && more=" (+$((nstarved - 10)) more after 10)"
    [ "$complete" = 1 ] || more="$more (probe cap $cap reached: more may be starved)"
    IFS=$'\t' read -r first_id first_key _ <<<"$starved"
    "$h/bin/lane-alert.sh" --id "starved-ready-$p" --severity warn triage \
      "[$p] STARVED READY: $nstarved ticket(s) todo + ready + team + buildable for ≥${min}m with no ready row, queue row or build dir: $list$more. Release one: bin/jobs-client.sh ready-put $p $first_key $first_id" \
      >/dev/null 2>&1 || true
    touch "$marker" 2>/dev/null
  elif [ "$complete" = 1 ] && [ -e "$marker" ]; then
    "$h/bin/lane-alert.sh" --resolve --id "starved-ready-$p" triage "[$p] no starved ready tickets" >/dev/null 2>&1 || true
    rm -f "$marker"
  fi
  return 0
}
