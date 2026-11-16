# shellcheck shell=bash
# bin/blocked-resolver.d/bh-9437-red-sig.sh — no rebuild on the same red
# (BH-9437 item 1). Sourced by the driver's blocked-resolver.d block;
# functions only, no exit.
#
# Before br_rebuild_fresh closes a ci-red PR and buys a fresh build, the gate
# reads the failing required checks of the PR's head and stores them on the
# record as `.red_sigs` rows {url, head, checks, at}. When the set equals the
# set of the PR before it (the newest row with another url), a third build
# would fail the same way: the ladder stops. One `red-repeat` attempt row,
# `.red_stop={url, head, checks, prev_url}`, ONE warn alert that names the
# checks, and br_rebuild_fresh returns 3 (held: nothing closed, nothing
# enqueued, no counter). The PR stays open. A new push is a new head and
# restarts the compare.
#
# Knob: BR_RED_SIG_STOP (catalog/lanes.d/blocked-resolver.knobs.d/
# BR_RED_SIG_STOP.json), default 1; 0 = no compare, as before BH-9437.
# Retention: `.red_sigs` keeps the last 8 rows (the rebuild cap is <= 4), and
# both fields live and retire with the record (BR_FINISHED_RECORD_RETIRE_DAYS).

# brlad_knob <name> <value> <default> <min> <max> — a usable integer. A value
# that is not a number gets one say line and the default; a number outside the
# range is clamped. The BH-9437 fragments read every knob through this.
brlad_knob() {
  local name="$1" v="$2" d="$3" lo="$4" hi="$5"
  case "$v" in
    '') printf '%s' "$d"; return 0 ;;
    *[!0-9]*) say "knob $name='$v' is not a number — using the default $d (BH-9437)"; printf '%s' "$d"; return 0 ;;
  esac
  v=$((10#$v))
  [ "$v" -lt "$lo" ] && v=$lo
  [ "$v" -gt "$hi" ] && v=$hi
  printf '%s' "$v"
}

# brlad_red_checks <slug> <head> — the sorted, unique names of the failing
#   check runs on <head> (failure, timed_out, startup_failure). When the repo's
#   required list (mc_mergify_required_checks) answers a non-empty list, only
#   those names count. rc 2 = the check-runs page could not be read.
brlad_red_checks() {
  local slug="$1" head="$2" f names req
  f=$(mktemp) || return 2
  if ! gh_rest GET "repos/$slug/commits/$head/check-runs?filter=latest&per_page=100" > "$f" 2>/dev/null \
     || ! jq -e '.check_runs | type == "array"' "$f" >/dev/null 2>&1; then
    rm -f "$f"; return 2
  fi
  names=$(jq -r '.check_runs[] | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "startup_failure") | .name // empty' "$f" 2>/dev/null)
  rm -f "$f"
  if [ -n "$names" ] && command -v mc_mergify_required_checks >/dev/null 2>&1; then
    req=$(mc_mergify_required_checks "$slug" 2>/dev/null) || req=""
    [ -n "$req" ] && names=$(printf '%s\n' "$names" | grep -Fx -f <(printf '%s\n' "$req") || true)
  fi
  printf '%s\n' "$names" | sed '/^$/d' | LC_ALL=C sort -u
  return 0
}

# brlad_red_gate <p> <ck> <rkey> <reason> <url>
#   rc 0 the rebuild may go on (not ci-red, the knob is 0, a read failed, a
#        green head, no PR before it, or another set)
#   rc 1 stop: this head repeats the PR before it, or a red_stop stands on it
brlad_red_gate() {
  local p="$1" ck="$2" rkey="$3" reason="$4" url="$5" on head slug checks cj st prev pu pc list
  [ "$(br_ladder_class "$reason")" = ci-red ] || return 0
  # BR_RED_SIG_STOP: catalog/lanes.d/blocked-resolver.knobs.d/BR_RED_SIG_STOP.json (fallback 1)
  on=$(brlad_knob BR_RED_SIG_STOP "${BR_RED_SIG_STOP:-1}" 1 0 1)
  [ "$on" = 1 ] || return 0
  case "$url" in https://github.com/*/pull/*) ;; *) return 0 ;; esac
  head=$(br_pr_field "$url" .head.sha 'head sha' 2>/dev/null | tr 'A-F' 'a-f')
  if [ -z "$head" ]; then
    say "$p/$rkey [$reason]: red-signature check skipped — the PR head could not be read; the rebuild goes on as before (BH-9437)"
    return 0
  fi
  st=$(br_load "$p" "$ck")
  if [ "$(printf '%s' "$st" | jq -r --arg u "$url" --arg h "$head" '(.red_stop // {}) | (.url == $u and .head == $h)' 2>/dev/null)" = true ]; then
    say "$p/$rkey [$reason]: RED REPEAT stands on ${head:0:12} ($(printf '%s' "$st" | jq -r '(.red_stop.checks // []) | join(", ")' 2>/dev/null)) — no rebuild; a new push restarts the compare (BH-9437)"
    return 1
  fi
  slug=$(br_slug_of_url "$url") || return 0
  if ! checks=$(brlad_red_checks "$slug" "$head"); then
    say "$p/$rkey [$reason]: red-signature check skipped — the check runs of ${head:0:12} could not be read; the rebuild goes on as before (BH-9437)"
    return 0
  fi
  [ -n "$checks" ] || return 0
  cj=$(printf '%s\n' "$checks" | jq -R . | jq -sc .) || return 0
  list=$(printf '%s' "$cj" | jq -r 'join(", ")')
  # The PR before this one: the newest row of another url, read before this row is written.
  prev=$(printf '%s' "$st" | jq -c --arg u "$url" '[(.red_sigs // [])[] | select(.url != $u)] | last // empty' 2>/dev/null)
  pc=$(printf '%s' "$prev" | jq -c '(.checks // []) | sort' 2>/dev/null)
  pu=$(printf '%s' "$prev" | jq -r '.url // ""' 2>/dev/null)
  if [ "${OBSERVE:-0}" = 1 ]; then
    if [ -n "$prev" ] && [ "$pc" = "$cj" ]; then
      say "$p/$rkey [$reason]: WOULD stop the ladder — ${head:0:12} fails the same checks as $pu ($list) — observe mode"
      return 1
    fi
    return 0
  fi
  # shellcheck disable=SC2016  # $u $h $c $t are jq variables
  br_json_edit "$p" "$ck" '.red_sigs = ((((.red_sigs // []) | map(select((.url == $u and .head == $h) | not))) + [{url:$u, head:$h, checks:$c, at:$t}]) | .[-8:])' \
    --arg u "$url" --arg h "$head" --argjson c "$cj" --arg t "$(STAMP)" \
    || say "$p/$rkey [$reason]: the red signature of ${head:0:12} could not be written to $(br_file "$p" "$ck") (BH-9437)"
  [ -n "$prev" ] && [ "$pc" = "$cj" ] || return 0
  # THE RECORD FIRST, THEN THE ALERT: a failed send does not repeat, and the
  # alert id dedupes on the head.
  br_record "$p" "$ck" red-repeat "$reason" "${head:0:12} fails the same checks as $pu ($list): no rebuild" "" "$url" "$head"
  # shellcheck disable=SC2016
  br_json_edit "$p" "$ck" '.red_stop = {url:$u, head:$h, checks:$c, prev_url:$pu, at:$t}' \
    --arg u "$url" --arg h "$head" --argjson c "$cj" --arg pu "$pu" --arg t "$(STAMP)" \
    || say "$p/$rkey [$reason]: red_stop could not be written to $(br_file "$p" "$ck") (BH-9437)"
  "$H/bin/lane-alert.sh" --id "red-repeat:$p:$ck:${head:0:12}" --severity warn blocked-resolver \
    "[$p] red repeat: $url fails the same required checks as $pu ($list). The ladder is stopped, so no third build runs. The PR stays open; a new push restarts the compare." >/dev/null 2>&1 </dev/null || true
  say "$p/$rkey [$reason]: RED REPEAT — ${head:0:12} fails the same checks as $pu ($list); the ladder is stopped, no rebuild, one alert sent (BH-9437)"
  return 1
}
