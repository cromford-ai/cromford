#!/bin/bash
# bin/lib/pool-hold-cache.sh — the pool's per-issue HOLD verdict cache (BH-6549).
#
# The pool's HOLD gate (bin/fly-pool.sh pool_spawn_decision, step 1) reads the
# issue and its whole comment thread for every queued row on every tick. On the
# loaded hub one read costs 30-45 s, and a project with 19 held tickets spent
# about 12 min of a 30 min cycle re-reading threads that had not changed.
# This lib keeps the last HELD verdict per issue in <dir>/<n>.json, keyed on
# "<updated_at>|<comments>" from the open-issue listing the pool reads once per
# tick. A key that did not change answers from the file; anything else is a
# full read.
#
# FAIL-SAFE DIRECTION: only `held` verdicts are kept, so the cache can keep a
# row held and can never release one. A clear is always read from GitHub. A
# missing, unparsable, expired, key-changed or lib-changed entry is a miss.
# `held closed` and `held label-absent` are never kept: the pool parks those
# rows, and a re-opened ticket must be read again.
#
# PURE: no network, no env knobs, no clock. The caller passes the cache dir,
# the key, the hold.sh checksum, the TTL and `now`.
#
#   phc_listing_keys <listing-json>
#       one line per issue of one listing page: n<TAB>updated_at<TAB>comments.
#       Pull requests and issues without both fields are dropped.
#       rc 0, rc 2 when the input is not a JSON array.
#   phc_get <dir> <n> <key> <lib> <ttl_s> <now>
#       rc 0 hit (prints the verdict), rc 1 miss, rc 3 bad file (prints
#       nothing). The caller treats rc 3 as a miss, never as a clear.
#   phc_put <dir> <n> <key> <lib> <now> <verdict>
#       held (not closed/label-absent) with a key and a lib: written (tmp + mv).
#       clear, held closed, held label-absent: the file is removed.
#       unreadable or anything else: unchanged.
#       rc 0 written/removed/unchanged, rc 1 the write failed.
#
# File format v1: {"v":1,"n":"<n>","key":"<updated_at>|<comments>",
#                  "lib":"<cksum>","verdict":"held\t…","at":<epoch>}

phc_listing_keys() {
  printf '%s' "${1:-}" | jq -r '
    if type != "array" then error("not an array") else .[] end
    | select(type == "object" and (has("pull_request") | not))
    | select(.number != null and .updated_at != null and .comments != null)
    | "\(.number)\t\(.updated_at)\t\(.comments)"' 2>/dev/null || return 2
}

# _phc_keepable <verdict> — rc 0 when the verdict is one the cache may keep.
_phc_keepable() {
  case "${1:-}" in
    *"	closed"|*"	label-absent") return 1 ;;
    "held	"*) return 0 ;;
  esac
  return 1
}

phc_get() {
  local dir="${1:-}" n="${2:-}" key="${3:-}" lib="${4:-}" ttl="${5:-}" now="${6:-}" f out
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  case "$ttl" in ''|*[!0-9]*) return 1 ;; esac
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$dir" ] && [ -n "$key" ] && [ -n "$lib" ] && [ "$ttl" -gt 0 ] || return 1
  f="$dir/$n.json"
  [ -f "$f" ] || return 1
  out=$(jq -r --arg k "$key" --arg l "$lib" --argjson ttl "$ttl" --argjson now "$now" '
    if type != "object" or .v != 1 or (.key | type) != "string" or (.lib | type) != "string"
       or (.verdict | type) != "string" or (.at | type) != "number" then "bad"
    elif .key != $k or .lib != $l then "miss"
    elif .at > $now or ($now - .at) >= $ttl then "miss"
    else "ok\t" + .verdict end' "$f" 2>/dev/null) || return 3
  case "$out" in
    bad) return 3 ;;
    "ok	"*) out="${out#ok	}"; _phc_keepable "$out" || return 1
            printf '%s\n' "$out"; return 0 ;;
  esac
  return 1
}

phc_put() {
  local dir="${1:-}" n="${2:-}" key="${3:-}" lib="${4:-}" now="${5:-}" v="${6:-}" f tmp
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$dir" ] || return 1
  f="$dir/$n.json"
  case "$v" in
    clear*|*"	closed"|*"	label-absent")
      [ -e "$f" ] || return 0
      rm -f "$f" 2>/dev/null; [ ! -e "$f" ] || return 1; return 0 ;;
    "held	"*) ;;
    *) return 0 ;;
  esac
  [ -n "$key" ] && [ -n "$lib" ] || return 0
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp=$(mktemp "$dir/.$n.json.XXXXXX" 2>/dev/null) || return 1
  if jq -nc --arg n "$n" --arg k "$key" --arg l "$lib" --arg v "$v" --argjson at "$now" \
       '{v:1,n:$n,key:$k,lib:$l,verdict:$v,at:$at}' > "$tmp" 2>/dev/null \
     && mv -fT "$tmp" "$f" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}
