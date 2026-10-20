#!/bin/bash
# shellcheck shell=bash
# bin/lib/unblock/tripwire.sh — the unblock lane's warn-only tripwires
# (BH-7726, UNB-4). Sourced by the lane tick, never run; nothing runs on source.
#
#   ub_tripwire_scan <counts-json>
#     counts: {day, class_today: {<class>: n}, class_baseline7d: {<class>: avg},
#              subject_heads: {<subject>: n}, judge_calls: n,
#              card_redeclares: {<card_id>: n}}
#     Four tripwires. Each that fires sends ONE lane-alert.sh --severity warn,
#     id unblock-tripwire-<kind>-<sha12 of the subject>-<day>:
#       class-burst     class_today[c] > 3 * max(class_baseline7d[c], 1)
#       subject-heads   subject_heads[s] >= 3 (one subject seen on 3+ heads)
#       judge-calls     judge_calls > UNBLOCK_TRIPWIRE_JUDGE_MAX (default 20);
#                       the subject is the word `judge`
#       card-redeclare  card_redeclares[id] > 3
#     A missing or non-numeric field skips that tripwire and logs
#     `tripwire: <kind> unread` in logs/unblock.log. Unknown never fires.
#     ALWAYS rc 0: a tripwire alerts, it never stops an action (G3: no daily
#     action cap, no per-ticket budget).
#
# NO ROOT DEFAULT (D43): the root is $HARNESS, then $H; with neither the scan
# does nothing and returns 0.

_ubt_root() { printf '%s' "${HARNESS:-${H:-}}"; }

_ubt_log() {
  local h; h=$(_ubt_root)
  [ -n "$h" ] || return 0
  mkdir -p "$h/logs" 2>/dev/null
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') $*" >> "$h/logs/unblock.log" 2>/dev/null || true
}

_ubt_num() { [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }

# _ubt_fire <kind> <subject> <day> <text>
_ubt_fire() {
  local sha
  sha=$(printf '%s' "$2" | sha256sum | cut -c1-12)
  "$(_ubt_root)/bin/lane-alert.sh" --severity warn --id "unblock-tripwire-$1-$sha-$3" unblock "$4" >/dev/null 2>&1 || true
  _ubt_log "tripwire: $1 fired for $2"
}

ub_tripwire_scan() {
  local c="${1:-}" day k v b max
  [ -n "$(_ubt_root)" ] || return 0
  if ! printf '%s' "$c" | jq -e 'type == "object"' >/dev/null 2>&1; then
    _ubt_log "tripwire: counts unread (not a JSON object)"
    return 0
  fi
  day=$(printf '%s' "$c" | jq -r '.day // ""')
  [[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { _ubt_log "tripwire: day unread"; return 0; }

  # class-burst
  if printf '%s' "$c" | jq -e '(.class_today | type) == "object"' >/dev/null 2>&1; then
    while IFS=$'\t' read -r k v; do
      [ -n "$k" ] || continue
      _ubt_num "$v" || { _ubt_log "tripwire: class-burst unread ($k)"; continue; }
      b=$(printf '%s' "$c" | jq -r --arg k "$k" '.class_baseline7d[$k] // 0 | tostring')
      _ubt_num "$b" || { _ubt_log "tripwire: class-burst unread ($k baseline)"; continue; }
      if awk -v t="$v" -v b="$b" 'BEGIN { m = (b > 1 ? b : 1); exit !(t > 3 * m) }'; then
        _ubt_fire class-burst "$k" "$day" "unblock tripwire: class $k ran $v actions today, over 3x its 7-day baseline of $b. Nothing was stopped."
      fi
    done < <(printf '%s' "$c" | jq -r '.class_today | to_entries[] | "\(.key)\t\(.value)"')
  else
    _ubt_log "tripwire: class-burst unread"
  fi

  # subject-heads
  if printf '%s' "$c" | jq -e '(.subject_heads | type) == "object"' >/dev/null 2>&1; then
    while IFS=$'\t' read -r k v; do
      [ -n "$k" ] || continue
      _ubt_num "$v" || { _ubt_log "tripwire: subject-heads unread ($k)"; continue; }
      if awk -v n="$v" 'BEGIN { exit !(n >= 3) }'; then
        _ubt_fire subject-heads "$k" "$day" "unblock tripwire: $k got actions on $v heads today. Nothing was stopped."
      fi
    done < <(printf '%s' "$c" | jq -r '.subject_heads | to_entries[] | "\(.key)\t\(.value)"')
  else
    _ubt_log "tripwire: subject-heads unread"
  fi

  # judge-calls
  v=$(printf '%s' "$c" | jq -r '.judge_calls // "" | tostring')
  max="${UNBLOCK_TRIPWIRE_JUDGE_MAX:-20}"
  _ubt_num "$max" || max=20
  if ! _ubt_num "$v"; then
    _ubt_log "tripwire: judge-calls unread"
  elif awk -v n="$v" -v m="$max" 'BEGIN { exit !(n > m) }'; then
    _ubt_fire judge-calls judge "$day" "unblock tripwire: $v judge calls today, over the bound of $max. Nothing was stopped."
  fi

  # card-redeclare
  if printf '%s' "$c" | jq -e '(.card_redeclares | type) == "object"' >/dev/null 2>&1; then
    while IFS=$'\t' read -r k v; do
      [ -n "$k" ] || continue
      _ubt_num "$v" || { _ubt_log "tripwire: card-redeclare unread ($k)"; continue; }
      if awk -v n="$v" 'BEGIN { exit !(n > 3) }'; then
        _ubt_fire card-redeclare "$k" "$day" "unblock tripwire: card $k was declared again $v times. Nothing was stopped."
      fi
    done < <(printf '%s' "$c" | jq -r '.card_redeclares | to_entries[] | "\(.key)\t\(.value)"')
  else
    _ubt_log "tripwire: card-redeclare unread"
  fi
  return 0
}
