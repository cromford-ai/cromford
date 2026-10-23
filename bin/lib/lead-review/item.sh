#!/bin/bash
# shellcheck shell=bash
# module: item
# bin/lib/lead-review/item.sh — the `item` mode of bin/lead-review.sh (BH-8027).
# Sourced by bin/lead-review.sh through bin/lib/lead-review/load.sh, never run.
# Defines functions only. Reads the host's IT_P, IT_F, IT_M, IT_OUT and H;
# calls the host's review_one, cleanup, lr_ring_land and lr_get; reads R.
#
# item <project> <item-file> <mode> <word-file> (BH-8027): on a pool machine,
# review ONE tick item (a worklist item or a request row) that a box queued as
# an LR- pool row, through review_one with the tick's limits, and ring
# lead-land as a tick worker does. The word (done, paid, failed ...) goes to
# <word-file>.
# The pool row carries the item's identity only (bin/lib/lead-pool.sh: repo,
# pr, head_sha, id, reset_count, src). An item with an id is a request row, so
# it is read again here by id (scope_notes, detail and the rest), and must name
# the same repo, PR and head. Unreadable = word `unreadable`, no claim, no
# review; a row no longer requested or running = its status as the word.
# rc 1 = malformed item (word `malformed`), rc 0 once any other word is written.
lr_item_run() {
  local r it_id it_row it_st
  r=$(jq -c 'select(type == "object")' "$IT_F" 2>/dev/null)
  if ! [[ "$(jq -r '.pr // empty' <<<"$r" 2>/dev/null)" =~ ^[0-9]+$ && "$(jq -r '.head_sha // empty' <<<"$r" 2>/dev/null)" =~ ^[0-9a-f]{40}$ ]]; then
    log "item: malformed $(head -c 200 "$IT_F")"; echo malformed > "$IT_OUT"; return 1
  fi
  it_id=$(jq -r '.id // empty' <<<"$r" 2>/dev/null)
  if [ -n "$it_id" ]; then
    [[ "$it_id" =~ ^[A-Za-z0-9._-]+$ ]] || { log "item: bad request id $(head -c 80 <<<"$it_id")"; echo malformed > "$IT_OUT"; return 1; }
    it_row=$(lr_get "/$it_id" 2>/dev/null | jq -c '.request // empty' 2>/dev/null)
    if [ -z "$it_row" ] || ! jq -e --argjson i "$r" '.id == $i.id and .repo == $i.repo and ((.pr | tostring) == ($i.pr | tostring)) and .head_sha == $i.head_sha' >/dev/null 2>&1 <<<"$it_row"; then
      log "item $IT_P: request $it_id is unreadable or names another PR head; not reviewed"; echo unreadable > "$IT_OUT"; return 0
    fi
    it_st=$(jq -r '.status // ""' <<<"$it_row")
    case "$it_st" in
      requested|running) r="$it_row" ;;
      *) log "item $IT_P: request $it_id is ${it_st:-unknown}; not reviewed again"; printf '%s\n' "${it_st:-closed}" | tr -cd 'a-z_\n-' > "$IT_OUT"; return 0 ;;
    esac
  fi
  mkdir -p "$H/state/lead-review"
  review_one "$r" "$IT_P" "$IT_M"; cleanup; lr_ring_land
  log "item $IT_P $(jq -r '"\(.repo)#\(.pr)@\(.head_sha[0:12])"' <<<"$r"): ${R:-skipped}"
  printf '%s\n' "${R:-skipped}" > "$IT_OUT"; return 0
}
