# shellcheck shell=bash
# bin/blocked-resolver.d/bh-9437-review-replan.sh — one re-plan before the
# abandon when an ALWAYS-BLOCK review finding outlasts the fix rounds (BH-9437
# item 2). The CI ladder's park-and-re-plan rung (bin/lib/br/opt/cirepair.sh,
# BR_CI_REPLAN_MAX) is the pattern. Sourced by the driver's blocked-resolver.d
# block; functions only, no exit.
#
# br_fix_terminal's review arm runs br_cap_notes first. When that return is the
# floor one (BR_CAPN_FLOOR=1, the standing bodies copied to
# $ST/<p>/<ck>.capnotes-floor.txt), brlad_review_replan writes a build note
# `KIND: review-replan` (the prior PR, its head, the ALWAYS-BLOCK findings and
# the fix-round history) and rebuilds the ticket fresh. bin/lib/rb/plan.sh
# frames that note as a re-plan after a review block. The counter
# `.review_replans` moves only when the rebuild bought a job; the notes this
# ticket already carried are a floor under it, so a reset record buys no
# second re-plan. After BR_REVIEW_REPLAN_MAX re-plans the cap abandons.
# Knob: BR_REVIEW_REPLAN_MAX (catalog/lanes.d/blocked-resolver.knobs.d/
# BR_REVIEW_REPLAN_MAX.json), default 1; 0 = abandon at the cap, as before.

# brlad_review_replan_floor <p> <ticket-key> — the review re-plans this ticket
#   already carried, counted from the notes (br_ci_replan_floor's globs).
brlad_review_replan_floor() {
  local p="$1" key="$2" f n=0
  [ -n "$key" ] && [ "$key" != "-" ] || { printf 0; return 0; }
  f="$NOTES/$p/$key.md"
  if [ -f "$f" ] && [ "$(head -1 "$f" 2>/dev/null)" = "KIND: review-replan" ] && command -v bn_used >/dev/null 2>&1 \
     && [ "$(bn_used "$p" "$key" "$f" 2>/dev/null)" = consumed ]; then
    n=$((n + 1))
  fi
  for f in "$NOTES/$p/$key.md.relayed-"* \
           "$H"/builds/pool-"$p"-"$key"-*/carried-note.md "$H"/builds/fly-"$p"-"$key"-*/carried-note.md \
           "$H"/builds/"$p"-"$key"-*/carried-note.md; do
    [ -f "$f" ] || continue
    [ "$(head -1 "$f" 2>/dev/null)" = "KIND: review-replan" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

# brlad_review_replan <p> <rkey> <reason> <url> <rec> <ticket-key>
#   rc 0 handled this tick: the re-plan was bought, or the rebuild rung held or
#        deferred it (the note stays, nothing counted, the next tick comes back
#        through the cap), or observe mode
#   rc 1 abandon as before: not a floor finding, the knob is 0, no ticket key,
#        or the re-plans are spent
brlad_review_replan() {
  local p="$1" rkey="$2" reason="$3" url="$4" rec="$5" tkey="${6:--}" max ck st used floor head fl hist note before after
  [ "${BR_CAPN_FLOOR:-0}" = 1 ] || return 1
  # BR_REVIEW_REPLAN_MAX: catalog/lanes.d/blocked-resolver.knobs.d/BR_REVIEW_REPLAN_MAX.json (fallback 1)
  max=$(brlad_knob BR_REVIEW_REPLAN_MAX "${BR_REVIEW_REPLAN_MAX:-1}" 1 0 3)
  [ "$max" -gt 0 ] || return 1
  [ -n "$tkey" ] && [ "$tkey" != "-" ] || return 1
  ck=$(br_cap_key "$p" "$rkey" "$tkey")
  st=$(br_load "$p" "$ck")
  used=$(printf '%s' "$st" | jq -r '(.review_replans // 0) | tostring | tonumber? // 0' 2>/dev/null)
  case "$used" in ''|*[!0-9]*) used=0 ;; esac
  floor=$(brlad_review_replan_floor "$p" "$tkey")
  [ "${floor:-0}" -gt "$used" ] && used=$floor
  if [ "$used" -ge "$max" ]; then
    say "$p/$rkey [$reason]: the ALWAYS-BLOCK finding outlasted the fix rounds after $used automatic re-plan(s) (BR_REVIEW_REPLAN_MAX=$max) — abandoned (BH-9437)"
    return 1
  fi
  if [ "${OBSERVE:-0}" = 1 ]; then
    say "$p/$rkey [$reason]: WOULD re-plan the ticket — an ALWAYS-BLOCK finding outlasted the fix rounds (re-plan $((used + 1)) of $max) — observe mode"
    return 0
  fi
  head=$(printf '%s' "$st" | jq -r '(.review_fix_heads // [])[-1] // (.rung_head // "")' 2>/dev/null)
  # The floor lines only: the same filter br_floor_stands applies.
  fl=""
  if [ -s "$ST/$p/$ck.capnotes-floor.txt" ]; then
    local line
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      grep -qiE "${RL_FIND_RE:-\\[BLOCK}|^[[:space:]]*NEEDS_HUMAN:" <<<"$line" || continue
      grep -qiE '\[NOTE|not verified here|\[BLOCK needs-human\]' <<<"$line" && continue
      command -v rl_line_blocks >/dev/null 2>&1 && ! rl_line_blocks "$line" && continue
      fl="$fl$line"$'\n'
    done < "$ST/$p/$ck.capnotes-floor.txt"
  fi
  [ -n "$fl" ] || fl="(the standing review's ALWAYS-BLOCK lines could not be read back; see the PR's review thread)"$'\n'
  hist=$(printf '%s' "$st" | jq -r --arg r "$reason" '.attempts[]? | select((.action | startswith("fix-round")) and .reason == $r) | "- \(.at) \(.action): \(.detail)"' 2>/dev/null)
  [ -n "$hist" ] || hist="- (no fix-round row on the record)"
  note="KIND: review-replan
PRIOR PR: ${url:--} (head ${head:-unknown}), closed by bin/blocked-resolver.sh at the review fix cap
ALWAYS-BLOCK FINDINGS:
$(head -c 2500 < <(printf '%s' "$fl"))
FIX ROUNDS ON THIS TICKET:
$hist"
  mkdir -p "$NOTES/$p" 2>/dev/null
  if ! printf '%s\n' "$note" > "$NOTES/$p/$tkey.md"; then
    say "$p/$rkey [$reason]: the review re-plan note could not be written to $NOTES/$p/$tkey.md — abandoned as before (BH-9437)"
    return 1
  fi
  if command -v bn_put >/dev/null 2>&1 && ! bn_put "$p" "$tkey" "$NOTES/$p/$tkey.md"; then
    say "$p/$rkey [$reason]: review re-plan note NOT in the DB — only hub/pool builds will see it"
  fi
  before=$(br_jobs_count "$st")
  br_rebuild_fresh "$p" "$rkey" "$reason" "$url" "$rec" "$tkey"
  st=$(br_load "$p" "$ck"); after=$(br_jobs_count "$st")
  case "$before" in ''|null) before=0 ;; esac
  case "$after" in ''|null) after=0 ;; esac
  if [ "$after" -gt "$before" ] 2>/dev/null; then
    # shellcheck disable=SC2016  # $n is a jq variable
    br_json_edit "$p" "$ck" '.review_replans = $n' --argjson n "$((used + 1))" \
      || say "$p/$rkey [$reason]: review_replans could not be written to $(br_file "$p" "$ck") — the carried note is the floor (BH-9437)"
    br_record "$p" "$ck" review-replan "$reason" "re-plan $((used + 1)) of $max enqueued (job $(printf '%s' "$st" | jq -r '(.rebuild_jobs // [])[-1].id // "?"' 2>/dev/null)) with the ALWAYS-BLOCK finding and $(printf '%s\n' "$hist" | grep -c .) fix-round row(s) of ${url:--}" "" "$url"
    say "$p/$rkey [$reason]: an ALWAYS-BLOCK finding outlasted the fix rounds — re-plan $((used + 1)) of $max enqueued with the finding and the round history (BH-9437)"
  elif [ "$(printf '%s' "$st" | jq -r '.outcome // ""' 2>/dev/null)" = ABANDONED ]; then
    say "$p/$rkey [$reason]: review re-plan not bought — the rebuild ladder of this ticket is spent and the rebuild rung abandoned it (BH-9437)"
  else
    say "$p/$rkey [$reason]: review re-plan not bought this tick (the rebuild rung held or deferred it) — the note stays, nothing counted, retried next tick (BH-9437)"
  fi
  return 0
}
