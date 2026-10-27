#!/bin/bash
# shellcheck shell=bash
# module: contested after: datalane
# bin/lib/br/contested.sh — BH-579: the CONTESTED HOLD. Who else wants the path
# a ticket keeps losing, and the hold that parks them behind it. Sourced by
# bin/blocked-resolver.sh after datalane.sh, never run. Sourcing it defines five
# functions and does nothing else. At call time it reads $ST, $OBSERVE, $ONLY,
# CONTESTED_SCAN_MAX, MC_CONTESTED_DIR and the driver's mc_contested_*,
# mc_pr_files, harness_pr_list and say/br_* helpers.
#
# BH-8626 moved this section out of the driver to give the driver back its line
# budget. The function bodies are unchanged.

# ---------------------------------------------------------------------------
# THE CONTESTED HOLD (BH-579). Who else wants the path this ticket keeps losing,
# and the hold that parks them behind it.
# ---------------------------------------------------------------------------
# br_competitors <project> <cap-key> <slug> <path> <winner-num> <winner-key>
#   Writes {loser_prs, loser_tickets, note} to
#   state/blocked-resolver/<p>/<ck>.competitors.json — one file, REWRITTEN per
#   path, because the caller reads it before asking about the next one — and
#   answers rc 0; rc 1 only
#   when the PR list could not be READ, which is never the same thing as "nobody
#   else wants it". The file is the channel because the caller cannot run this
#   in a command substitution and still see a global it set.
#
#   ONE LIST CALL, then cached per-(PR, head) file lists (mc_pr_files), capped at
#   CONTESTED_SCAN_MAX. Two PRs are never losers: the winner itself, and the
#   winner's OWN rebuild (ticket/<key>-rN carries the same ticket key). A PR this
#   harness did not author is not in harness_pr_list's answer at all.
#
#   THE 7th ARGUMENT IS THAT LIST, already read (review round 1). The competitor
#   set is per PATH — a sibling that touches only the second contested file is a
#   loser of that file's hold and of no other — so this runs once per path, and
#   the caller hoists the one open-PR list call out of the loop rather than
#   buying it again per path. Absent, it is read here, which is what any other
#   caller and every direct test gets.
br_competitors() {
  local p="$1" ck="$2" slug="$3" path="$4" wnum="$5" wkey="$6" list="${7:-}"
  local total seen=0 num url head bkey k f want line
  local prs='[]' tix='[]' note="" skipped=""
  if [ -z "$list" ]; then
    command -v harness_pr_list >/dev/null 2>&1 || return 1
    list=$(br_open_prs "$slug") || return 1
  fi
  printf '%s' "$list" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
  total=$(printf '%s' "$list" | jq 'length' 2>/dev/null); case "$total" in ''|*[!0-9]*) total=0 ;; esac
  while IFS=$'\t' read -r num url head bkey; do
    case "$num" in ''|*[!0-9]*) continue ;; esac
    [ "$num" = "$wnum" ] && continue
    # THE CAP IS DECLARED, NEVER SILENT (D12): what was not scanned is named in
    # the log and in the hold's own `why`.
    if [ "$seen" -ge "${CONTESTED_SCAN_MAX:-40}" ]; then skipped="${skipped:+$skipped }#$num"; continue; fi
    seen=$((seen+1))
    k=$(br_key_from_branch "$bkey" 2>/dev/null) || k="-"
    [ -n "$k" ] && [ "$k" = "$wkey" ] && continue
    grep -Fxq -- "$path" <<<"$(mc_pr_files "$slug" "$num" "$url" "$head" 2>/dev/null)" || continue
    prs=$(printf '%s' "$prs" | jq -c --argjson n "$num" --arg u "$url" --arg k "${k:--}" \
            '. + [{num:$n,url:$u,key:$k}]' 2>/dev/null) || return 1
  done < <(printf '%s' "$list" | jq -r '.[]? | "\(.number)\t\(.url)\t\(.headRefOid)\t\(.headRefName)"' 2>/dev/null)
  if [ -n "$skipped" ]; then
    note="scan capped at ${CONTESTED_SCAN_MAX:-40} of $total"
    say "$p/$ck: contested scan capped at ${CONTESTED_SCAN_MAX:-40} of $total open PRs — $skipped were not read and are NOT parked"
  fi
  # And the tickets that are PLANNED to touch it: a build that has not launched
  # yet is the cheapest competitor to stop (bin/triage-gate.sh reads this list).
  for f in "$H/plans/$p-"*/planned-files.txt; do
    [ -s "$f" ] || continue
    k=$(basename "$(dirname "$f")"); k="${k#"$p-"}"
    [ -n "$k" ] && [ "$k" != "$wkey" ] || continue
    while IFS= read -r want; do
      [ -n "$want" ] || continue
      case "$want" in '#'*|SOURCE:*|source:*) continue ;; esac
      # The path itself, or a directory scope that contains it. Never a string
      # prefix: a.txt is not claimed by a plan that names a.txtx.
      # shellcheck disable=SC2254
      case "$path" in
        "$want"|"$want"/*) tix=$(printf '%s' "$tix" | jq -c --arg k "$k" '. + [$k]' 2>/dev/null); break ;;
      esac
    done < "$f"
  done
  mkdir -p "$ST/$p" 2>/dev/null
  jq -nc --argjson prs "$prs" --argjson tix "$tix" --arg note "$note" \
    '{loser_prs:$prs, loser_tickets:($tix|unique), note:$note}' > "$ST/$p/$ck.competitors.json" 2>/dev/null || return 1
  return 0
}

# br_contested_hold <project> <cap-key> <slug> <pr-url> <ticket-key> <head> <paths>
#   rc 0 when the path is held and the bonus round is granted; rc 1, with ONE
#   log line saying why, for every case that leaves the ladder exactly where it
#   was — the PR list unreadable, nobody to hold, a hold that will not write.
#
#   THE ORDER IS THE DURABILITY ARGUMENT. Hold files first (tmp+rename, so a
#   reader never sees half a hold), then ONE json write that records the attempt,
#   grants the bonus and marks the ticket contested, then the loser rows, then
#   the event. A crash after the holds and before the json rewrites the same
#   holds next tick (same key, last write wins). A crash after the json leaves
#   the losers named in a live hold, so they are skipped here and parked by the
#   conductor. Nothing is ever marked contested without a hold on disk.
br_contested_hold() {
  local p="$1" ck="$2" slug="$3" url="$4" tkey="$5" head="$6" recs="$7"
  local first num list prs tix note why written="" heldpaths="" parks="" path f
  local prevpr prevhead cnum cpurl nums keys detail arr allprs='[]' alltix='[]'
  first=$(printf '%s\n' "$recs" | sed '/^$/d' | head -1)
  [ -n "$first" ] || return 1
  num=$(mc_num_of_url "$url")
  # ONE OPEN-PR LIST FOR THE WHOLE HOLD CREATION, hoisted out of the path loop
  # (review round 1, finding 3). What is PER PATH is the file match: the first
  # cut computed the loser set for the first recurring path and stamped it onto
  # every hold, so a sibling touching only the SECOND path was named by no hold,
  # parked by nobody and raced the winner exactly as before — while the second
  # path's hold parked PRs that never touch it. The file lists mc_pr_files reads
  # are cached per (PR, head), so the second path costs no API call either.
  if ! command -v harness_pr_list >/dev/null 2>&1 \
     || ! list=$(br_open_prs "$slug") \
     || [ -z "$list" ]; then
    say "$p/$ck [$tkey]: competitors unreadable (harness_pr_list failed) — contested hold not written, rebuilding as before"
    return 1
  fi
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if ! br_competitors "$p" "$ck" "$slug" "$path" "$num" "$tkey" "$list"; then
      say "$p/$ck [$tkey]: competitors unreadable (harness_pr_list failed) — contested hold not written, rebuilding as before"
      br_contested_withdraw "$written" "hold read incomplete"
      return 1
    fi
    f="$ST/$p/$ck.competitors.json"
    prs=$(jq -c '.loser_prs' "$f" 2>/dev/null); tix=$(jq -c '.loser_tickets' "$f" 2>/dev/null)
    note=$(jq -r '.note // ""' "$f" 2>/dev/null)
    [ -n "$prs" ] || prs='[]'; [ -n "$tix" ] || tix='[]'
    if [ "$prs" = '[]' ] && [ "$tix" = '[]' ]; then
      say "$p/$ck [$tkey]: $path recurs but no open PR or planned ticket touches it — nothing to hold on that path"
      continue
    fi
    IFS=$'\t' read -r prevpr prevhead < <(br_load "$p" "$ck" | jq -r --arg pr "$num" --arg h "$head" --arg path "$path" '
        [ (.conflicts // [])[]
          | select((((.pr|tostring) != $pr) or (.head != $h)) and (((.paths // []) | index($path)) != null)) ]
        | last | select(. != null) | "\(.pr)\t\(.head)"' 2>/dev/null)
    # THE `select(. != null)` IS THE POINT. `last` over an empty list is jq's
    # `null`, and `"\(null)"` renders the four letters n-u-l-l — so with no
    # earlier occurrence the `${prevpr:--}` default below never fired and the
    # hold's own `why` read `after null@null`. Selected away, the no-match case
    # prints nothing, `read` leaves both variables empty, and the defaults answer.
    why="recurred on $num@${head:0:8} after ${prevpr:--}@${prevhead:0:8}${note:+; $note}"
    if ! mc_contested_write "$p" "$slug" "$path" "$tkey" "$url" "$prs" "$tix" "" "$why"; then
      say "$p/$ck [$tkey]: contested hold could not be written — rebuilding as before"
      br_contested_withdraw "$written" "hold write incomplete"
      return 1
    fi
    written="$written$(mc_contested_file "$p" "$path")"$'\n'
    heldpaths="$heldpaths$path"$'\n'
    allprs=$(printf '%s\n%s\n' "$allprs" "$prs" | jq -sc 'add | unique_by(.num)' 2>/dev/null) || allprs='[]'
    alltix=$(printf '%s\n%s\n' "$alltix" "$tix" | jq -sc 'add | unique' 2>/dev/null) || alltix='[]'
    # EVERY LOSER IS PARKED ON THE PATH THAT NAMED IT FIRST. A PR in two holds
    # carries one reason, and the release rule (mc_contested_loser, asked with
    # the hold being released excluded) is what keeps it parked until the LAST
    # hold naming it is gone.
    while IFS=$'\t' read -r cnum cpurl; do
      [ -n "$cnum" ] || continue
      case $'\n'"$parks" in *$'\n'"$cnum"$'\t'*) continue ;; esac
      parks="$parks$cnum"$'\t'"${cpurl:--}"$'\t'"$path"$'\n'
    done < <(printf '%s' "$prs" | jq -r '.[]? | "\(.num)\t\(.url // "-")"' 2>/dev/null)
  done < <(printf '%s\n' "$recs" | sed '/^$/d')
  if [ -z "$heldpaths" ]; then
    say "$p/$ck [$tkey]: $(tr '\n' ' ' <<<"$recs")recurred but no open PR or planned ticket touches any of them — nothing to hold, rebuilding as before"
    return 1
  fi
  first=$(head -1 <<<"$heldpaths")
  arr=$(printf '%s' "$heldpaths" | sed '/^$/d' | jq -R . | jq -sc .)
  nums=$(printf '%s' "$allprs" | jq -r '[.[].num] | join(", ")' 2>/dev/null)
  keys=$(printf '%s' "$alltix" | jq -r 'join(", ")' 2>/dev/null)
  detail="hold on $(tr '\n' ' ' <<<"$heldpaths")written — winner $tkey, loser PRs ${nums:-none}, loser tickets ${keys:-none}; one bonus fix round granted"
  # ONE WRITE: the attempt, the bonus and the mark. The bonus is persisted BEFORE
  # the round runs and the mark is what stops a second hold, so they cannot come
  # apart — two writes here would let a crash grant the bonus twice.
  if ! br_json_edit "$p" "$ck" '
        .attempts += [{at:$t, action:"contested", reason:$why, detail:$d}]
        | .updated = $t
        | .fixround_bonus = ((.fixround_bonus // 0) + 1)
        | .contested = {at:$t, paths:$paths, hold:$hold}' \
        --arg t "$(STAMP)" --arg why conflict-unresolvable --arg d "$detail" \
        --argjson paths "$arr" --arg hold "$(mc_contested_file "$p" "$first")"; then
    say "$p/$ck [$tkey]: the contested hold could not be recorded on the ticket — holds withdrawn, rebuilding as before"
    br_contested_withdraw "$written" "hold could not be recorded"
    return 1
  fi
  # THE LOSERS' ROWS. mc_transition is the conductor's own writer, so the park
  # is recorded exactly like every other one — and `contested:*` is not a
  # hand-off reason, so the conductor may reclassify the row the moment it is
  # released. A loser with NO row is left alone: this lane invents no rows.
  local lnum lurl lpath row lhead lrev
  while IFS=$'\t' read -r lnum lurl lpath; do
    [ -n "$lnum" ] || continue
    row=$(mc_row_get "$slug#$lnum")
    if [ -z "$row" ]; then
      say "$p/$ck: loser #$lnum has no conductor row — left to the conductor"
      continue
    fi
    lhead=$(cut -f4 <<<"$row"); lrev=$(cut -f5 <<<"$row")
    case "$lurl" in ''|-|null) lurl=$(cut -f8 <<<"$row") ;; esac
    mc_transition "$slug#$lnum" BLOCKED_HUMAN "contested:$lpath (winner $tkey)" \
      "$lhead" "$lrev" "$lurl" - - - >/dev/null
  done <<<"$parks"
  br_event resolver_contested "$p" "$ck" conflict-unresolvable \
    "hold on $(tr '\n' ' ' <<<"$heldpaths")— winner $tkey ($url), loser PRs ${nums:-none}, loser tickets ${keys:-none}"
  return 0
}

# br_contested_withdraw <written-list> <why> — every hold this creation managed
#   to write, released, for the paths that came before the one that failed. A
#   half-written hold set parks people behind a winner nothing recorded.
br_contested_withdraw() {
  local written="${1:-}" why="${2:-withdrawn}" f
  [ -n "$written" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] && mc_contested_release "$f" "$why" >/dev/null 2>&1
  done <<<"$written"
  return 0
}

# br_contested_sweep — once per tick, before the drain. Every hold is read and
#   ended when its winner is done with it:
#     row MERGED           -> released, no page (the happy ending)
#     row ABANDONED        -> released + alert (it was held for nothing)
#     no row, gh merged    -> released
#     no row, gh closed     -> released + alert (same shape as abandoned)
#     no row, read failed  -> left in place, one UNVERIFIABLE line, no page
#     now - created >= ttl -> released + alert
#   A TTL RELEASE IS NOT A TIME KILL: it unparks rows and closes nothing. A hold
#   whose created/ttl do not parse is MALFORMED, not expired — it holds nobody
#   (the contract decides liveness per read), it is left on disk as the evidence
#   of a bad write, and it pages nobody.
#
#   NO LOCK, ever (the operator, 2026-09-13 — we never lock and serialize): every write
#   here is either a contract-atomic file op or a row transition the conductor's
#   own writer already serialises. Bounded by the number of holds, outside
#   PER_TICK, and on the row path it costs no GitHub call at all.
br_contested_sweep() {
  local d p f repo wkey wurl created ttl now st rc malformed
  [ -d "$MC_CONTESTED_DIR" ] || return 0
  now=$(date -u +%s)
  for d in "$MC_CONTESTED_DIR"/*; do
    [ -d "$d" ] || continue
    p=$(basename "$d")
    [ -z "$ONLY" ] || [ "$p" = "$ONLY" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      IFS=$'\t' read -r repo wkey wurl created ttl < <(jq -r \
        'select(type=="object")|"\(.repo)\t\(.winner_key)\t\(.winner_url)\t\(.created)\t\(.ttl)"' "$f" 2>/dev/null)
      malformed=0
      case "${created:-}" in ''|*[!0-9]*) malformed=1 ;; esac
      case "${ttl:-}"     in ''|*[!0-9]*) malformed=1 ;; esac
      if [ "$malformed" = 1 ]; then
        say "contested hold $f is malformed — not live, left in place"
        continue
      fi
      if [ "$(( now - created ))" -ge "$ttl" ]; then
        br_release_hold "$f" "expired after ${ttl}s" alert
        continue
      fi
      st=$(mc_row_field "$repo#$(mc_num_of_url "$wurl")" 2)
      case "$st" in
        MERGED)    br_release_hold "$f" "winner merged" ;;
        ABANDONED) br_release_hold "$f" "winner abandoned" alert ;;
        '')
          # No row at all — the only arm that asks GitHub, and the only one that
          # can. Anything but merged/closed (open, a PR GitHub says is absent, a
          # read nobody could make) leaves the hold exactly where it is.
          #
          # THE READ IS br_pr_state, this file's own (#783), NEVER `gh pr view`
          # (docs/verification-map/gh-pr-list-rest.md): `gh pr view --json` is
          # GraphQL, and the GraphQL bucket is the one that empties first on
          # these accounts — a sweep that cannot read the winner leaves every
          # loser parked until the TTL, i.e. the feature fails exactly when the
          # fleet is busiest. It is also the three-answer contract rather than a
          # raw `gh api -q`: rc 0 a state, rc 44 the PR is absent, rc 75 GitHub
          # did not answer, with the `UNVERIFIABLE (HTTP …)` line written for us.
          # A raw read collapsed a 5xx and a rate limit into "not merged" and
          # left nothing in the log to say a read had failed at all.
          br_use_token "$repo"
          st=$(br_pr_state "$wurl"); rc=$?
          if [ "$rc" = 0 ]; then
            case "$st" in
              merged) br_release_hold "$f" "winner merged" ;;
              closed) br_release_hold "$f" "winner closed" alert ;;
            esac
          fi
          br_reset_token ;;
      esac
    done < <(mc_contested_list "$p")
  done
  return 0
}
# br_release_hold <file> <why> [alert] — mc_contested_release, except while the
#   fleet kill switch or this lane's observe flag is on, when a release would
#   move other people's rows for a tick that took no action at all.
br_release_hold() {
  local f="$1" why="$2" alert="${3:-}"
  if [ "$OBSERVE" = 1 ]; then
    say "WOULD release contested hold on $(jq -r '.path // "?"' "$f" 2>/dev/null) ($why) — observe mode"
    return 0
  fi
  mc_contested_release "$f" "$why" "$alert"
}
