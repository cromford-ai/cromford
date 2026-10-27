#!/bin/bash
# bin/lib/lead-reenqueue.sh — a re-pushed PR head with a prior lead verdict is
# asked for a lead review at once, not on the next */15 tick. Sourced, never run.
#
# Two sides share one item format:
#   <owner/repo>#<n>=<trigger>     a pr wake row (the PR number)
#   <owner/repo>@<sha>=<trigger>   a checks wake row (the head sha, 7-64 hex)
# The trigger is the GitHub event the wake row stores (pull_request.synchronize).
#
# bin/wake-loop.sh (hub only):
#   lre_wake_row <kind> <event> <repo> <key>  one item into LRE_Q for a pr row
#       pull_request.synchronize|reopened|ready_for_review with an all-digit
#       key, or a checks row check_suite.completed with a 7-64 hex key. Deduped.
#       Any other row adds nothing. rc 0 always.
#   lre_wake_launch  ONE detached `lead-review-enqueue.sh pr <items>` per drain
#       through the loop's launch(), its fd 9 closed; then LRE_Q is emptied.
# bin/lead-review-enqueue.sh pr:
#   lre_parse <item>...  fills LRE_PRS (<slug>\t<n>\t<trigger> lines) and
#       LRE_SHAS (<slug>\t<sha>\t<trigger>), slug and sha lowercased; LRE_N is
#       the valid count, LRE_BAD the dropped items. rc 1 when none is valid.
#   lre_repo_wanted <slug>  rc 0 when an item names that repo (any case).
#   lre_row_wanted <slug> <n> <list head>  rc 0 when an item names <slug>#<n>,
#       or a sha item of that repo is a prefix of the head (or the head of it).
#       LRE_TRIG is the matched triggers, comma-joined.
#   lre_row_go <slug> <n> <head> <ledger>  rc 0 = go. rc 1, one line through
#       the caller's log(), when the head is already in the ledger, when the
#       verdict history is unreadable or truncated, or when no source=lead
#       MERGE / MERGE-WITH-NOTES / BLOCK row stands on an EARLIER head.
# Every other gate is the tick's own, so this never asks for a head the tick
# would not ask for.

LRE_Q=()

lre_wake_row() {
  local kind="$1" ev="$2" repo="$3" key="$4" item="" q
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 0
  case "$kind:$ev" in
    pr:pull_request.synchronize|pr:pull_request.reopened|pr:pull_request.ready_for_review)
      [[ "$key" =~ ^[0-9]{1,9}$ ]] && item="$repo#$key=$ev" ;;
    checks:check_suite.completed)
      [[ "$key" =~ ^[0-9a-fA-F]{7,64}$ ]] && item="$repo@${key,,}=$ev" ;;
  esac
  [ -n "$item" ] || return 0
  for q in "${LRE_Q[@]}"; do [ "$q" = "$item" ] && return 0; done
  LRE_Q+=("$item")
  return 0
}

lre_wake_launch() {
  if [ "${#LRE_Q[@]}" -gt 0 ]; then
    ( exec 9>&-; launch "lead-enqueue" "$SELF/lead-review-enqueue.sh" pr "${LRE_Q[@]}" )
  fi
  LRE_Q=()
  return 0
}

lre_parse() {
  local it slug rest ref trig sep
  LRE_PRS=""; LRE_SHAS=""; LRE_N=0; LRE_BAD=""
  for it in "$@"; do
    trig="${it##*=}"; rest="${it%=*}"
    if [[ "$it" == *=* ]] && [[ "$trig" =~ ^[a-z_.]{1,64}$ ]] \
       && [[ "$rest" =~ ^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)([#@])(.+)$ ]]; then
      slug="${BASH_REMATCH[1],,}"; sep="${BASH_REMATCH[2]}"; ref="${BASH_REMATCH[3]}"
      if [ "$sep" = "#" ] && [[ "$ref" =~ ^[0-9]{1,9}$ ]]; then
        LRE_PRS+="$slug"$'\t'"$ref"$'\t'"$trig"$'\n'; LRE_N=$((LRE_N + 1)); continue
      fi
      if [ "$sep" = "@" ] && [[ "$ref" =~ ^[0-9a-fA-F]{7,64}$ ]]; then
        LRE_SHAS+="$slug"$'\t'"${ref,,}"$'\t'"$trig"$'\n'; LRE_N=$((LRE_N + 1)); continue
      fi
    fi
    LRE_BAD="${LRE_BAD:+$LRE_BAD }$it"
  done
  [ "$LRE_N" -gt 0 ]
}

lre_repo_wanted() {
  local s="${1,,}" a _b _c
  while IFS=$'\t' read -r a _b _c; do
    [ -n "$a" ] && [ "$a" = "$s" ] && return 0
  done <<<"$LRE_PRS$LRE_SHAS"
  return 1
}

lre_row_wanted() {
  local s="${1,,}" n="$2" h="${3,,}" a b c
  LRE_TRIG=""
  while IFS=$'\t' read -r a b c; do
    [ -n "$a" ] && [ "$a" = "$s" ] && [ "$b" = "$n" ] || continue
    case ",$LRE_TRIG," in *",$c,"*) ;; *) LRE_TRIG="${LRE_TRIG:+$LRE_TRIG,}$c" ;; esac
  done <<<"$LRE_PRS"
  if [[ "$h" =~ ^[0-9a-f]{7,64}$ ]]; then
    while IFS=$'\t' read -r a b c; do
      [ -n "$a" ] && [ "$a" = "$s" ] || continue
      [[ "$h" == "$b"* || "$b" == "$h"* ]] || continue
      case ",$LRE_TRIG," in *",$c,"*) ;; *) LRE_TRIG="${LRE_TRIG:+$LRE_TRIG,}$c" ;; esac
    done <<<"$LRE_SHAS"
  fi
  [ -n "$LRE_TRIG" ]
}

lre_row_go() {
  local slug="$1" n="$2" head="${3,,}" ledger="$4" vd
  if awk -F'\t' -v s="$slug" -v n="$n" -v h="$head" '$2 == s && $3 == n && tolower($4) == h {f=1} END {exit !f}' "$ledger" 2>/dev/null; then
    log "$slug#$n @${head:0:12}: already requested; nothing to do"; return 1
  fi
  if ! vd=$(JOBS_ALERT=0 _jobs_req GET "/api/verdicts?repo=$slug&pr=$n" 2>/dev/null) \
     || ! jq -e '(.rows | type) == "array" and .truncated != true' <<<"$vd" >/dev/null 2>&1; then
    log "$slug#$n @${head:0:12}: verdict history unreadable; left to the */15 tick"; return 1
  fi
  # BH-8476: a retracted lead BLOCK is absent.
  if ! jq -e --arg h "$head" 'any(.rows[] | select(.retracted_at == null); .source == "lead"
         and ((.head_sha // "") | ascii_downcase) != $h
         and ((.verdict // "") | IN("MERGE", "MERGE-WITH-NOTES", "BLOCK")))' <<<"$vd" >/dev/null 2>&1; then
    log "$slug#$n @${head:0:12}: no prior lead verdict; left to the */15 tick"; return 1
  fi
  return 0
}
