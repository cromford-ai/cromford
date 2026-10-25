# shellcheck shell=bash
# bin/blocked-resolver.d/bh-7804-ila-pending.sh — the iron-law ACCEPT is the
# DB row, and a paid ruling survives a DB outage (BH-7804, slice C4 of #4157).
# Sourced by the driver's blocked-resolver.d block; functions only.
#
# The ACCEPT arm of br_adjudicate writes the `ironlaw-head-accept` row
# (ila_put, bin/lib/ironlaw-carry.sh). The conductor and the merge sweep unpark
# a head only on that row. When the write fails, the ruling is kept as
# `.ila_pending = {url, head, at}` in the resolver record json, and the next
# tick that offers the same park retries the write before it drops a rung.
# The retry makes no model call and spends no counter.

# br_ila_accept_write <p> <rkey> <url> <head> — the ACCEPT arm's write.
br_ila_accept_write() {
  local p="$1" rkey="$2" url="$3" head="$4" st
  if command -v ila_put >/dev/null 2>&1 && ila_put "$url" "$head" resolver "adjudicated ACCEPT"; then
    say "$p/$rkey [iron-law]: ADJUDICATED ACCEPT — DB accept recorded ($(ila_key "$url" "$head")); the sweep and conductor unpark this sha"
    br_ila_pending_clear "$p" "$rkey"
    return 0
  fi
  st=$(br_load "$p" "$rkey" | jq -c --arg u "$url" --arg h "$head" --arg a "$(STAMP)" \
        '.ila_pending = {url:$u, head:$h, at:$a}' 2>/dev/null)
  if [ -n "$st" ] && br_save "$p" "$rkey" "$st"; then
    say "$p/$rkey [iron-law]: ADJUDICATED ACCEPT — DB accept NOT recorded; kept as pending in the record, retried next tick with no model call"
  else
    say "$p/$rkey [iron-law]: ADJUDICATED ACCEPT — DB accept NOT recorded and the pending could not be saved — the ruling is in the adjudication comment only"
  fi
  return 0
}

# br_ila_pending_clear <p> <rkey> — drop .ila_pending, when the record has one.
# Observe mode writes nothing.
br_ila_pending_clear() {
  local st
  [ "${OBSERVE:-0}" = 1 ] && return 0
  st=$(br_load "$1" "$2")
  [ "$(printf '%s' "$st" | jq -r 'has("ila_pending")' 2>/dev/null)" = true ] || return 0
  st=$(printf '%s' "$st" | jq -c 'del(.ila_pending)' 2>/dev/null) && [ -n "$st" ] && br_save "$1" "$2" "$st"
  return 0
}

# br_ila_pending_retry <p> <rkey> <reason> <url> — the "already adjudicated
# once" branch asks this first.
#   rc 0 handled, no rung this tick: the row is written, or it is still kept
#        (an outage, an unreadable head), or observe mode said WOULD.
#   rc 1 fall through to the rung below: no pending, or a pending that does not
#        bind to this PR and its current head (it is dropped).
br_ila_pending_retry() {
  local p="$1" rkey="$2" reason="$3" url="$4" pend purl phead head
  [ "$reason" = iron-law ] || return 1
  pend=$(br_load "$p" "$rkey" | jq -c '.ila_pending // empty' 2>/dev/null)
  [ -n "$pend" ] || return 1
  purl=$(printf '%s' "$pend" | jq -r '.url // "" | tostring' 2>/dev/null)
  phead=$(printf '%s' "$pend" | jq -r '.head // "" | tostring' 2>/dev/null | tr 'A-F' 'a-f')
  if [ -z "$purl" ] || [ "$purl" != "$url" ]; then
    say "$p/$rkey [iron-law]: pending ACCEPT was for ${purl:-no url}, this park is $url — dropped"
    br_ila_pending_clear "$p" "$rkey"; return 1
  fi
  if ! [[ "$phead" =~ ^[0-9a-f]{40}$ ]]; then
    say "$p/$rkey [iron-law]: pending ACCEPT names no 40-hex head (${phead:0:12}) — dropped"
    br_ila_pending_clear "$p" "$rkey"; return 1
  fi
  if [ "${OBSERVE:-0}" = 1 ]; then
    say "$p/$rkey [iron-law]: WOULD retry pending ACCEPT on ${phead:0:8} — observe mode"
    return 0
  fi
  head=$(br_pr_field "$url" .head.sha 'head sha' | tr 'A-F' 'a-f')
  if [ -z "$head" ]; then
    say "$p/$rkey [iron-law]: pending ACCEPT on ${phead:0:8} kept — head unreadable, retried next tick"
    return 0
  fi
  if [ "$head" != "$phead" ]; then
    say "$p/$rkey [iron-law]: pending ACCEPT was for ${phead:0:8}, head is now ${head:0:8} — dropped"
    br_ila_pending_clear "$p" "$rkey"; return 1
  fi
  if command -v ila_put >/dev/null 2>&1 && ila_put "$url" "$phead" resolver "adjudicated ACCEPT"; then
    br_ila_pending_clear "$p" "$rkey"
    say "$p/$rkey [iron-law]: pending ACCEPT recorded ($(ila_key "$url" "$phead")) — no model call; the sweep and conductor unpark this sha"
    return 0
  fi
  say "$p/$rkey [iron-law]: pending ACCEPT still NOT recorded — kept, retried next tick with no model call"
  return 0
}
