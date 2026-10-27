#!/bin/bash
# shellcheck shell=bash
# module: datalane after: headgate
# bin/lib/br/datalane.sh — BH-4926: the DATA-LANE PARK. A review block whose
# only finding is a migration not yet applied to prod waits on the data lane's
# pre-merge apply instead of a rebuild. Sourced by bin/blocked-resolver.sh after
# headgate.sh, never run. Sourcing it defines eight functions and does nothing
# else. At call time it reads $H, $ST, $REPOS, $HENV, $OBSERVE, BR_DL_*,
# BR_NOVERDICT_MAX, BR_LEAD_HDR and the driver's say/br_* helpers.
#
# BH-8626 moved this block out of the driver to give the driver back its line
# budget. The function bodies are unchanged.

# >>> data-lane park (BH-4926)
# A review block whose ONLY finding is a migration not yet applied to prod (the
# reviewer's DATA_LANE: line, bin/lib/data-lane.sh) waits on the data lane's
# pre-merge apply, not on a rebuild: a rebuild of the same diff ends on the same
# BLOCK, and rebuild-review-blocked -> abandon-rebuild is how TK-32 was
# ABANDONED. State, all on this ticket's record: outcome DATA_LANE (the park),
# data_lane_file/_fp (what was parked), data_lane_escalated=<fp> (alerted once),
# data_lane_released="<fp> <head>" (the one re-review, claimed before the call),
# data_lane_unbound="<fp> <head>" (the PR head moved past it: the ladder's).

# br_dl_eval <project> <record|-> <ticket-key> — is this park's review a
#   data-lane candidate? Sets BR_DL_REC BR_DL_FILE BR_DL_HEAD BR_DL_FP, so it is
#   called directly, never inside $( ). The record is <record> when it holds a
#   review.md, else the ticket's newest local build dir that does.
#   rc 0 candidate. rc 1 not one: a final round with no DATA_LANE line costs no
#   git call. rc 2 it HAS a DATA_LANE line but the reviewed sha, the diff or the
#   file could not be read: unreadable holds, it is never "not a candidate".
# _br_dl_fetch_due <sha> — rc 0 a fetch for this sha may run: no miss stamp, or
#   one older than BR_DL_FETCH_MISS_S. _br_dl_fetch_miss <sha> stamps a miss.
_br_dl_fetch_due() {
  local f="$ST/.dl-fetch-miss/$1" t
  [ -f "$f" ] || return 0
  t=$(tr -dc '0-9' < "$f" 2>/dev/null); [ -n "$t" ] || return 0
  [ $(( $(date -u +%s) - t )) -ge "${BR_DL_FETCH_MISS_S:-600}" ]
}
_br_dl_fetch_miss() { mkdir -p "$ST/.dl-fetch-miss" 2>/dev/null && date -u +%s > "$ST/.dl-fetch-miss/$1" 2>/dev/null; return 0; }

br_dl_eval() {
  local p="$1" rec="${2:--}" tkey="${3:--}" repo d diff blob mb cand rc=0
  BR_DL_REC=""; BR_DL_FILE=""; BR_DL_HEAD=""; BR_DL_FP=""
  command -v dl_candidate >/dev/null 2>&1 && command -v _nh_final >/dev/null 2>&1 || return 1
  if [ "$rec" = - ] || [ ! -f "$rec/review.md" ]; then
    rec=""
    if [ -n "$tkey" ] && [ "$tkey" != - ]; then
      # The trailing dash keeps BH-23 from answering for BH-234.
      for d in $(ls -td "$H"/builds/pool-"$p"-"$tkey"-*/ "$H"/builds/"$p"-"$tkey"-*/ 2>/dev/null); do
        [ -f "$d/review.md" ] && { rec="${d%/}"; break; }
      done
    fi
    [ -n "$rec" ] || return 1
  fi
  _nh_final "$rec/review.md" | tr -d '\r' | _nh_lines | grep -q '^DATA_LANE:' || return 1
  BR_DL_REC="$rec"
  BR_DL_HEAD=$(dl_reviewed_sha "$rec") || return 2
  repo="$REPOS/$p"
  diff=$(mktemp) || return 2
  blob=$(mktemp) || { rm -f "$diff"; return 2; }
  # A merged re-review header carries the SHORT sha review.sh writes (7 to 40
  # hex, dl_reviewed_sha). Resolve it to the full commit here, so every later
  # compare, dedupe key and reviewed-sha binding uses one form. A short sha
  # cannot be fetched by itself: fetch origin's branches (the PR branch is one)
  # and resolve again. Unresolvable or ambiguous holds (rc 2), never "moved".
  # A fetch runs only when the object is missing here; once fetched, later
  # ticks resolve it locally. A sha that a fetch could not find is not fetched
  # again for BR_DL_FETCH_MISS_S (600 s): one miss stamp per sha
  # (_br_dl_fetch_due), so an unresolvable park costs one fetch per window,
  # not one per tick and per br_abandon call (lead NOTE on dbed6c45).
  # The miss stamp is written ONLY when a fetch really ran and still could not
  # find the sha (lead BLOCK on 0d5f96563): a call inside the window skips the
  # fetch and leaves the stamp alone, so the window ends BR_DL_FETCH_MISS_S
  # after the last real fetch, not after the last tick.
  if ! [[ "$BR_DL_HEAD" =~ ^[0-9a-f]{40}$ ]]; then
    local full
    full=$(git -C "$repo" rev-parse --verify -q "$BR_DL_HEAD^{commit}" 2>/dev/null) || full=""
    if ! [[ "$full" =~ ^[0-9a-f]{40}$ ]] && _br_dl_fetch_due "$BR_DL_HEAD"; then
      git -C "$repo" fetch -q origin 2>/dev/null
      full=$(git -C "$repo" rev-parse --verify -q "$BR_DL_HEAD^{commit}" 2>/dev/null) || full=""
      [[ "$full" =~ ^[0-9a-f]{40}$ ]] || _br_dl_fetch_miss "$BR_DL_HEAD"
    fi
    [[ "$full" =~ ^[0-9a-f]{40}$ ]] || { rm -f "$diff" "$blob"; return 2; }
    BR_DL_HEAD="$full"
  fi
  local have=0
  git -C "$repo" cat-file -e "$BR_DL_HEAD^{commit}" 2>/dev/null && have=1
  if [ "$have" = 0 ] && _br_dl_fetch_due "$BR_DL_HEAD"; then
    git -C "$repo" fetch -q origin "$BR_DL_HEAD" 2>/dev/null && git -C "$repo" cat-file -e "$BR_DL_HEAD^{commit}" 2>/dev/null && have=1
    [ "$have" = 1 ] || _br_dl_fetch_miss "$BR_DL_HEAD"
  fi
  [ "$have" = 1 ] \
    && mb=$(git -C "$repo" merge-base origin/HEAD "$BR_DL_HEAD" 2>/dev/null) \
    && git -C "$repo" diff --name-only "$mb" "$BR_DL_HEAD" > "$diff" 2>/dev/null || rc=2
  if [ "$rc" = 0 ]; then cand=$(dl_candidate "$rec/review.md" "$diff"); rc=$?; fi
  if [ "$rc" = 0 ]; then
    BR_DL_FILE="${cand#*$'\t'}"
    git -C "$repo" show "$BR_DL_HEAD:$BR_DL_FILE" > "$blob" 2>/dev/null && BR_DL_FP=$(dl_fp "$blob") || rc=2
  fi
  rm -f "$diff" "$blob"
  return "$rc"
}

# br_dl_escalate <project> <rkey> <reason> <url> <cap-key> <ticket-key> <why>
#   ONCE per fingerprint. The record row and the stamp are written before the
#   send (br_stall's rule), so a failed send can never re-page every tick; the
#   alert's --id is the second dedupe. The row stays DATA_LANE.
br_dl_escalate() {
  local p="$1" rkey="$2" reason="$3" url="${4:--}" ck="$5" tkey="${6:--}" why="$7" ref
  [ "$(br_load "$p" "$ck" | jq -r '.data_lane_escalated // ""' 2>/dev/null)" = "$BR_DL_FP" ] && return 0
  if [ "$OBSERVE" = 1 ]; then say "$p/$rkey [$reason]: WOULD escalate the data-lane park ($BR_DL_FILE: $why) — observe mode"; return 0; fi
  br_record "$p" "$ck" escalate-data-lane "$reason" "$BR_DL_FILE fp=${BR_DL_FP:0:12}: $why"
  br_set_field "$p" "$ck" data_lane_escalated "$BR_DL_FP"
  ref="$tkey"
  case "$url" in https://github.com/*/pull/*) ref="$(mc_num_of_url "$url")" ;; esac
  "$H/bin/lane-alert.sh" --id "data-lane-escalate:$p:$ref:$BR_DL_FP" --severity warn blocked-resolver \
    "[$p] data-lane: $tkey ${url:+($url) }is parked because its only review BLOCK is $BR_DL_FILE, which is not applied to prod, and the data lane will not apply it: $why. The row stays DATA_LANE. Nothing was abandoned or closed." >/dev/null 2>&1 || true
  say "$p/$rkey [$reason]: data-lane park escalated once ($BR_DL_FILE fp ${BR_DL_FP:0:12}: $why) — the row stays DATA_LANE"
}

# br_dl_unbind <project> <rkey> <reason> <cap-key> <why> — this fp+head no
#   longer describes the PR (its head moved past the reviewed sha), so the park
#   hands the row back to the ladder and is never re-taken on the same fp+head:
#   data_lane_unbound="<fp> <head>". Nothing in this lane re-binds the record's
#   review.md, so a park that stayed would wait forever with nobody told.
br_dl_unbind() {
  local p="$1" rkey="$2" reason="$3" ck="$4" why="$5"
  if [ "$OBSERVE" = 1 ]; then say "$p/$rkey [$reason]: WOULD hand the data-lane park back to the ladder ($why) — observe mode"; return 0; fi
  [ "$(br_load "$p" "$ck" | jq -r '.outcome // ""' 2>/dev/null)" = DATA_LANE ] && br_set_outcome "$p" "$ck" ""
  br_set_field "$p" "$ck" data_lane_unbound "$BR_DL_FP $BR_DL_HEAD"
  br_record "$p" "$ck" data-lane-unbound "$reason" "$BR_DL_FILE fp=${BR_DL_FP:0:12}: $why — the ladder owns it"
  say "$p/$rkey [$reason]: data-lane park handed back to the ladder — $why"
}

# br_dl_rcr_bound <url> — for a review-changes-requested row: is the PR's
#   standing CHANGES_REQUESTED the record's own DATA_LANE BLOCK, on the record's
#   review-head? The row's reason comes from the PR's newest standing review,
#   and the record is only the ticket's newest local build: a lead review on an
#   unrelated bug is not the data lane's to park.
#   rc 0 bound. rc 1 not bound (the ladder's). rc 4 the head moved. rc 2 the
#   head or the reviews list could not be read: held, never "not bound".
br_dl_rcr_bound() {
  local url="${1:--}" slug num head rc=0 b64 body
  slug=$(br_slug_of_url "$url") || return 2
  num=$(mc_num_of_url "$url"); [ -n "$num" ] || return 2
  head=$(br_pr_field "$url" .head.sha 'head sha') || return 2
  [ -n "$head" ] || return 2
  dl_sha_is "$BR_DL_HEAD" "$head" || return 4
  b64=$(br_review_newest "$slug" "$num" "$head") || rc=$?
  case "$rc" in 0) ;; 1) return 1 ;; *) return 2 ;; esac
  body=$(printf '%s' "$b64" | base64 -d 2>/dev/null | tr -d '\r')
  case "$body" in "$BR_LEAD_HDR"*) return 1 ;; esac
  grep -qxF -- "DATA_LANE: $BR_DL_FILE" <<<"$body" || return 1
  return 0
}

# br_data_lane_route <project> <rkey> <reason> <url> <record> <ticket-key> <cap-key>
#   rc 0 not a data-lane park: today's path. rc 3 parked (or held): no rung, no
#   slot, like HELD. rc 5 the release is due: the ledger says applied at this fp,
#   the probe file names this fp, and this fp+head has not been released yet.
br_data_lane_route() {
  local p="$1" rkey="$2" reason="$3" url="${4:--}" rec="${5:--}" tkey="${6:--}" ck="$7"
  local st oc rc=0 key status lrc probe base
  st=$(br_load "$p" "$ck"); oc=$(printf '%s' "$st" | jq -r '.outcome // ""' 2>/dev/null)
  br_dl_eval "$p" "$rec" "$tkey" || rc=$?
  case "$rc" in
    2) # Held, but never silently forever (lead BLOCK on dbed6c45): after
       # BR_DL_UNREADABLE_MAX (3) held ticks in a row, one escalation, deduped
       # on the park's fp (or on the record, for a review never parked).
       local nu
       nu=$(( $(br_num "$st" data_lane_unreadable) + 1 ))
       br_set_field "$p" "$ck" data_lane_unreadable "$nu"
       say "$p/$rkey [$reason]: DATA_LANE review in ${BR_DL_REC:-its record} could not be read (reviewed sha, diff or file) — held ($nu in a row), nothing abandoned, asked again next tick"
       if [ "$nu" -ge "${BR_DL_UNREADABLE_MAX:-3}" ]; then
         BR_DL_FILE=$(printf '%s' "$st" | jq -r '.data_lane_file // "its migration"')
         BR_DL_FP=$(printf '%s' "$st" | jq -r --arg r "unreadable:${BR_DL_REC##*/}" '.data_lane_fp // $r')
         br_dl_escalate "$p" "$rkey" "$reason" "$url" "$ck" "$tkey" "its review could not be read for $nu ticks in a row (reviewed sha, diff or file), so the park can neither release nor hand back"
       fi
       return 3 ;;
    1) if [ "$oc" = DATA_LANE ]; then
         br_set_outcome "$p" "$ck" ""
         br_record "$p" "$ck" data-lane-cleared "$reason" "the review is no longer a data-lane candidate — the ladder resumes"
         say "$p/$rkey [$reason]: the review is no longer a data-lane candidate — DATA_LANE cleared, the ladder resumes"
       fi
       return 0 ;;
  esac
  [ "$(br_num "$st" data_lane_unreadable)" = 0 ] || br_set_field "$p" "$ck" data_lane_unreadable 0
  key="$BR_DL_FP $BR_DL_HEAD"
  # Handed back once (the head moved): the same fp+head never parks again.
  [ "$(printf '%s' "$st" | jq -r '.data_lane_unbound // ""' 2>/dev/null)" = "$key" ] && return 0
  if [ "$reason" = review-changes-requested ]; then
    rc=0; br_dl_rcr_bound "$url" || rc=$?
    case "$rc" in
      2) say "$p/$rkey [$reason]: DATA_LANE — the PR's head or reviews could not be read — held, nothing abandoned, asked again next tick"
         return 3 ;;
      4) br_dl_unbind "$p" "$rkey" "$reason" "$ck" "the PR head moved past the reviewed ${BR_DL_HEAD:0:12}"
         return 0 ;;
      1) if [ "$oc" = DATA_LANE ]; then
           br_set_outcome "$p" "$ck" ""
           br_record "$p" "$ck" data-lane-cleared "$reason" "the PR's standing CHANGES_REQUESTED is not the data-lane BLOCK — the ladder resumes"
         fi
         say "$p/$rkey [$reason]: the PR's standing CHANGES_REQUESTED is not the record's data-lane BLOCK — not parked, the ladder runs"
         return 0 ;;
    esac
  fi
  if [ "$oc" != DATA_LANE ]; then
    # The one release ran and its re-review did not approve: the ladder owns it,
    # and the same fp+head never parks again.
    [ "$(printf '%s' "$st" | jq -r '.data_lane_released // ""' 2>/dev/null)" = "$key" ] && return 0
    if [ "$OBSERVE" = 1 ]; then say "$p/$rkey [$reason]: WOULD park DATA_LANE ($BR_DL_FILE) — observe mode"; return 3; fi
    br_set_outcome "$p" "$ck" DATA_LANE
    br_set_field "$p" "$ck" data_lane_file "$BR_DL_FILE"
    br_set_field "$p" "$ck" data_lane_fp "$BR_DL_FP"
    br_record "$p" "$ck" data-lane-parked "$reason" "$BR_DL_FILE fp=${BR_DL_FP:0:12} head=${BR_DL_HEAD:0:12}: the review's only BLOCK is this migration, not applied yet"
    say "$p/$rkey [$reason]: parked DATA_LANE — the only BLOCK is $BR_DL_FILE, not applied yet (fp ${BR_DL_FP:0:12}); no rung, nothing abandoned"
    st=$(br_load "$p" "$ck")
  fi
  status=$(dl_ledger_status "$p" "$BR_DL_FILE"); lrc=$?
  case "$lrc" in
    0) case "$status" in
         "flagged "*" fp=$BR_DL_FP"|"failed "*" fp=$BR_DL_FP")
           br_dl_escalate "$p" "$rkey" "$reason" "$url" "$ck" "$tkey" "ledger: $status"
           return 3 ;;
         "applied "*" fp=$BR_DL_FP"|"already-applied "*" fp=$BR_DL_FP")
           probe=$(dl_probe_file "$BR_DL_REC")
           if [ -f "$probe" ] && grep -qF "fp=$BR_DL_FP" "$probe"; then
             if [ "$(printf '%s' "$st" | jq -r '.data_lane_released // ""' 2>/dev/null)" = "$key" ]; then
               say "$p/$rkey [$reason]: DATA_LANE — the release for ${BR_DL_HEAD:0:12} was already requested; the conductor merges on its APPROVE"
               return 3
             fi
             return 5
           fi
           say "$p/$rkey [$reason]: DATA_LANE — $BR_DL_FILE applied, no probe yet — release waits"
           return 3 ;;
       esac ;;
    1) ;;
    *) say "$p/$rkey [$reason]: DATA_LANE — the migration ledger is unknown this tick, held (no alert, no release)"
       return 3 ;;
  esac
  # Absent, or another fp: the apply lane owns it, unless it has nowhere to go.
  # Read for emptiness only and never logged: it is the host the token goes to.
  base=$(sed -n 's/^DATA_LANE_APP_BASE=//p' "$HENV/$p.env" 2>/dev/null | sed -n '$p' | tr -d "\"' ")
  if [ -z "$base" ]; then
    br_dl_escalate "$p" "$rkey" "$reason" "$url" "$ck" "$tkey" "no apply path: DATA_LANE_APP_BASE unset in env/$p.env"
  else
    say "$p/$rkey [$reason]: DATA_LANE — $BR_DL_FILE waits on the data lane's apply (fp ${BR_DL_FP:0:12})"
  fi
  return 3
}

# br_data_lane_release <project> <cap-key> <reason> <url> <record> <ticket-key>
#   The release rung: ONE re-review of the SAME head, with the probe file as
#   evidence that the BLOCK is answered. It never merges, enqueues or builds; the
#   conductor merges on the head-bound APPROVE as for any other review. Reads the
#   BR_DL_* globals br_data_lane_route set in this same br_one.
br_data_lane_release() {
  local p="$1" ck="$2" reason="$3" url="${4:--}" tkey="${6:--}"
  local key probe purl="" slug brn head rc n0 n1 last
  key="$BR_DL_FP $BR_DL_HEAD"; probe=$(dl_probe_file "$BR_DL_REC")
  case "$url" in https://github.com/*/pull/*) purl="$url" ;; esac
  if [ -z "$purl" ]; then
    slug=$("$H/bin/fleet-conf.sh" "$p" repo 2>/dev/null)
    brn=$(sed -n 1p "$BR_DL_REC/branch" 2>/dev/null | tr -d '[:space:]')
    [ -n "$slug" ] && [ -n "$brn" ] \
      && purl=$(br_open_prs "$slug" | jq -r --arg b "$brn" '[.[]? | select(.headRefName == $b) | .url] | first // empty' 2>/dev/null)
  fi
  if [ -z "$purl" ]; then
    say "$p/$ck [$reason]: DATA_LANE release due, but no open PR carries ${BR_DL_REC##*/}'s branch — asked again next tick"
    return 0
  fi
  head=$(br_pr_field "$purl" .head.sha 'head sha'); rc=$?
  if [ "$rc" != 0 ] || [ -z "$head" ]; then
    say "$p/$ck [$reason]: DATA_LANE release due, but the head of $purl could not be read — asked again next tick"
    return 0
  fi
  if ! dl_sha_is "$BR_DL_HEAD" "$head"; then
    br_dl_unbind "$p" "$ck" "$reason" "$ck" "release refused, the PR head moved (${head:0:12}, reviewed ${BR_DL_HEAD:0:12})"
    return 0
  fi
  if [ "$OBSERVE" = 1 ]; then say "$p/$ck [$reason]: WOULD request the data-lane re-review of ${head:0:12} — observe mode"; return 0; fi
  br_set_field "$p" "$ck" data_lane_released "$key" || return 0
  n0=$(br_num "$(br_load "$p" "$ck")" data_lane_rereviews)
  br_rereview "$p" "$ck" "$reason" "$purl" "$BR_DL_REC" "$tkey" data-lane "$probe" "dl-${BR_DL_FP:0:12}"
  n1=$(br_num "$(br_load "$p" "$ck")" data_lane_rereviews)
  last=$(br_load "$p" "$ck" | jq -r '[.attempts[]? | select(.action == "re-review")] | last | (.detail // "")' 2>/dev/null)
  if [ "${n1:-0}" -le "${n0:-0}" ]; then
    # Nothing read the code (the lane failed, the call-guard deferred, the head
    # was unreadable): the claim is given back and the next tick asks again.
    br_set_field "$p" "$ck" data_lane_released "-"
    return 0
  fi
  case "$last" in
    APPROVE*) br_record "$p" "$ck" data-lane-released "$reason" "re-review APPROVE on ${head:0:12}, the BLOCK answered by $probe" ;;
    BLOCK*)   br_set_outcome "$p" "$ck" ""
              br_record "$p" "$ck" data-lane-release-blocked "$reason" "re-review BLOCK on ${head:0:12} after the apply — the ladder owns it" ;;
    # A paid read with no verdict is asked again next tick, up to the lane's
    # no-verdict cap; past it the claim stays (nothing more is bought) and one
    # escalation says so. The row stays DATA_LANE either way.
    *) if [ "${n1:-0}" -lt "$BR_NOVERDICT_MAX" ]; then br_set_field "$p" "$ck" data_lane_released "-"
       else br_dl_escalate "$p" "$ck" "$reason" "$purl" "$ck" "$tkey" "$n1 data-lane re-reviews of ${head:0:12} returned no verdict (BR_NOVERDICT_MAX)"; fi ;;
  esac
}
# <<< data-lane park
