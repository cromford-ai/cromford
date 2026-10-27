#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-gates.d/50-replay-delta.sh — gate 3 (BH-3930, BH-5294,
# BH-5582, BH-5909, BH-6391, BH-6967), ported from
# bin/lead-review-enqueue.sh (BH-5878): the lead's word on an earlier head G is kept when this head
# carries the same patch.
#   It runs when gate 10 left the head unapproved, rebound or
#   carried, or when bin/lib/lead-delta.sh is loaded (the enqueue's condition). Gate 10's
#   LGB_* globals for this (slug, PR, head) say which; without them the head
#   counts as approved and not rebound. A head gate 10 passed on a person's
#   HUMAN-STEP-DONE answer (LGB_STEPDONE=1, BH-6696) is never replayed or
#   delta-reviewed: rc 0 at once, a full review.
#   BH-7043: a head gate 10 CARRIED a builder APPROVE to (LGB_CARRIED=1) is
#   unapproved again when the history is unreadable or the newest lead word on
#   another head is a BLOCK: gate 10's CI rule then decides (_lgb_ci_green:
#   green = rc 0, a full review; not green = rc 11, held), as for any
#   unapproved head. A carried head is also skipped like an unapproved one when a
#   lead, human or risk-tier row is on it.
#   GET /api/verdicts?repo=&pr= (the whole history):
#     unreadable or truncated            rc 0, a full review (the enqueue fell
#                                        through to its request here too).
#     a lead row on this head with a
#       `lead-replay:` note              rc 12: already replayed, never twice.
#     unapproved and a lead, human or
#       risk-tier row on this head       rc 10 [skip verdict].
#   G is the newest lead MERGE, MERGE-WITH-NOTES or BLOCK row on another head
#   whose note is not itself a `lead-replay:` (bin/lib/lead-worklist.sh
#   lw_replay's rule). A BLOCK is a source only for a rebound head. The same
#   history names the re-review source (BH-6391): field prev_note is
#   lpv_note's `lead-prev:<G> word:<W> ...` group (bin/lib/lead-prev.sh), on
#   the clone under REPOS_ROOT, with a fetch only when it lacks G or the head.
#   The class: a cached delta.tsv row, else patch_same_fetch, then ld_classify
#   (or patch_same alone without bin/lib/lead-delta.sh).
#     replay <how>   BH-5909: a MERGE (or MERGE-WITH-NOTES) onto a head of the
#                    harness repo (fleet.conf's cromford row) that changes
#                    console-ui/src/ with no QA: PASS naming it is not replayed
#                    while the row lane.lead-review.lead_review_console_qa_gate
#                    reads 1 (unreadable = 1): cqg_replay_hold, one log line,
#                    rc 0, a full review. Else bin/lead-verdict.sh post <G's
#                    word> --source lead --note "lead-replay:<G12> how:<how>"
#                    --review-mode <G's review_mode, full when none> (BH-6967).
#                    Exit 0, 4 or 5: one modes.tsv `replay` row and rc 12. Any
#                    other exit: rc 11. With no readable lead token file on
#                    this box it posts nothing and returns 0: review_one's own
#                    lw_replay then replays a MERGE through /result.
#     delta ...      (G's word not BLOCK) LG_MODE=delta and rc 0; field
#                    delta_note is `lead-delta:<G> lines:<l>/<max> files:<f>
#                    [protected:<p>,..]`, the scope note review_one reads to
#                    review the delta.
#     full ..., no G, or any read or lib failure   rc 0.
# LGD_KEY (<slug>#<n>@<head>) and LGD_NOTE (the delta note) are set on every
# call, for gate 60's intent rule.
# State: state/lead-review-enqueue/delta.tsv and modes.tsv, the enqueue's own
# files, columns and keys (pruned 7 and 30 days, once per process).
# Sourced by bin/lib/lead-gates.sh, never run.

# shellcheck source=bin/lib/console-qa-gate.sh
command -v cqg_replay_hold >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../console-qa-gate.sh" 2>/dev/null || true

declare -g LGD_KEY="" LGD_NOTE="" _LGD_PVH="" _LGD_PVW="" _LGD_CQG=""

# _lgd_cqg_on — the row lane.lead-review.lead_review_console_qa_gate, read once
#   per process: 1 = on; no row = off; an unreadable row = on (a replay is held
#   and the head gets a review), the enqueue's cqg_gate_on.
_lgd_cqg_on() {
  local v rc=0
  if [ -z "$_LGD_CQG" ]; then
    v=$(setting_get lane.lead-review.lead_review_console_qa_gate 2>/dev/null) || rc=$?
    case "$rc" in
      0) _LGD_CQG=0; [ "$(printf '%s' "$v" | tr -d '[:space:]')" = 1 ] && _LGD_CQG=1 ;;
      2) _LGD_CQG=0 ;;
      *) _LGD_CQG=1 ;;
    esac
  fi
  [ "$_LGD_CQG" = 1 ]
}

declare -g _LGR_TICKED="" _LGR_LDMAX="" _LGR_LDPMAX=""

_lgr_state() { local root="${HARNESS:-${H:-}}"; [ -n "$root" ] || return 1; printf '%s\n' "$root/state/lead-review-enqueue"; }

# _lgr_skip <slug> <n> <head> <class> <text> — lgs_skip_once (05-skip-ledger.sh);
#   without it the `[skip <class>]` line is logged on every tick.
_lgr_skip() {
  if command -v lgs_skip_once >/dev/null 2>&1; then lgs_skip_once "$@"
  else _lgt_log "[skip $4] $1#$2 @${3:0:12} $5"; fi
}

lg_tick_replay_delta() {
  local st now f
  [ -n "$_LGR_TICKED" ] && return 0
  _LGR_TICKED=1
  if command -v ld_classify >/dev/null 2>&1; then
    _LGR_LDMAX=$(ld_knob LEAD_DELTA_REVIEW_MAX_LINES) || _LGR_LDMAX="unresolved"
    _LGR_LDPMAX=$(ld_knob LEAD_DELTA_PROTECTED_MAX_LINES) || _LGR_LDPMAX="unresolved"
  fi
  st=$(_lgr_state) || return 0
  mkdir -p "$st" 2>/dev/null || return 0
  now=$(date +%s)
  f="$st/delta.tsv"
  [ -f "$f" ] && awk -F'\t' -v c=$((now - 604800)) '$1 ~ /^[0-9]+$/ && $1 >= c' "$f" > "$f.tmp.$$" 2>/dev/null && mv -f "$f.tmp.$$" "$f"
  f="$st/modes.tsv"
  [ -f "$f" ] && awk -F'\t' -v c=$((now - 2592000)) '$1 ~ /^[0-9]+$/ && $1 >= c' "$f" > "$f.tmp.$$" 2>/dev/null && mv -f "$f.tmp.$$" "$f"
  rm -f "$st"/*.tmp."$$" 2>/dev/null
  return 0
}

# _lgr_uncarry <slug> <n> <head> <why> — BH-7043: the carried APPROVE does not
#   stand; gate 10's rule for an unapproved head decides (rc 0 or 11). Gate
#   10's globals say so too (LGB_APPROVED=0, LGB_CARRIED=0, LGB_REQFOR as gate
#   10's CI rule sets it), so gate 60 never signs the head off as approved.
_lgr_uncarry() {
  local slug="$1" n="$2" head="$3"
  LGB_APPROVED=0; LGB_CARRIED=0; LGB_REBOUND=0; LGB_REQFOR=""
  _lgt_log "$slug#$n @${head:0:12}: builder APPROVE on ${LGB_RSHA:0:12} not carried: $4"
  if command -v _lgb_ci_green >/dev/null 2>&1 && _lgb_ci_green "$slug" "$n" "$head"; then
    LGB_REQFOR="CI green"; return 0
  fi
  _lgt_log "$slug#$n @${head:0:12}: no builder APPROVE on this head and CI not known green (${_LGB_WHY:-gate 10 not loaded}); held"
  return 11
}

lg_gate_replay_delta() {
  local slug="$1" n="$2" head h12="${3:0:12}" root="${HARNESS:-${H:-}}" approved=1 rebound=0 carried=0 ld=0 st vd d
  local ph="" pw="" pid="" pm="" project repo cls="" how prc out tok box cqh hrepo
  head=$(printf '%s' "$3" | tr 'A-F' 'a-f')
  [ -n "$_LGR_TICKED" ] || lg_tick_replay_delta "$slug"
  LGD_KEY="$slug#$n@$head"; LGD_NOTE=""; _LGD_PVH=""; _LGD_PVW=""
  if [ "${LGB_KEY:-}" = "$slug#$n@$head" ]; then
    approved="${LGB_APPROVED:-1}"; rebound="${LGB_REBOUND:-0}"; carried="${LGB_CARRIED:-0}"
    [ "${LGB_STEPDONE:-0}" = 1 ] && return 0
  fi
  command -v ld_classify >/dev/null 2>&1 && ld=1
  [ "$rebound" = 1 ] || [ "$approved" = 0 ] || [ "$ld" = 1 ] || [ "$carried" = 1 ] || return 0
  d=$(lgs_dir 2>/dev/null) || { _lgt_log "$slug#$n @$h12: no scratch dir; no replay, full review"; return 0; }
  vd="$d/vd-$n"
  # A truncated history cannot prove which lead row is newest: unreadable.
  if ! JOBS_ALERT=0 _jobs_req GET "/api/verdicts?repo=$slug&pr=$n" > "$vd" 2>/dev/null \
     || ! jq -e '(.rows | type) == "array" and .truncated != true' "$vd" >/dev/null 2>&1; then
    if [ "$carried" = 1 ]; then
      _lgr_uncarry "$slug" "$n" "$head" "the verdict history is unreadable" || return $?
    fi
    _lgt_log "$slug#$n @$h12: verdicts read failed; full review"; return 0
  fi
  # BH-8476: a retracted lead BLOCK (bin/lead-verdict.sh retract) is absent here too.
  if jq -e --arg h "$head" 'any(.rows[] | select(.retracted_at == null); .source == "lead" and ((.head_sha // "") | ascii_downcase) == $h
       and ((.note // "") | split(" ") | any(startswith("lead-replay:"))))' "$vd" >/dev/null 2>&1; then
    _lgt_log "$slug#$n @$h12: lead word already replayed onto this head; no post, no review"
    return 12
  fi
  if { [ "$approved" = 0 ] || [ "$carried" = 1 ]; } && jq -e --arg h "$head" 'any(.rows[] | select(.retracted_at == null); ((.head_sha // "") | ascii_downcase) == $h
       and ((.source // "") | IN("lead", "human", "risk-tier")))' "$vd" >/dev/null 2>&1; then
    _lgr_skip "$slug" "$n" "$head" verdict "a lead, human or risk-tier verdict is on this head"; return 10
  fi
  IFS=$'\t' read -r ph pw pid pm < <(jq -r --arg h "$head" '[.rows[] | select(.retracted_at == null) | select(.source == "lead"
      and ((.head_sha // "") | ascii_downcase) != $h
      and ((.verdict // "") | IN("MERGE", "MERGE-WITH-NOTES", "BLOCK"))
      and (((.note // "") | contains("lead-replay:")) | not))]
    | max_by(.id) // empty | "\(.head_sha | ascii_downcase)\t\(.verdict)\t\(.id)\t\(.review_mode // "")"' "$vd" 2>/dev/null)
  if [ "$carried" = 1 ] && [ "$pw" = BLOCK ]; then
    _lgr_uncarry "$slug" "$n" "$head" "the newest lead verdict on another head is a BLOCK"; return $?
  fi
  [[ "$ph" =~ ^[0-9a-f]{40}$ ]] || return 0
  # BH-6391: the re-review source is the same row (a replay row has no review behind it).
  _LGD_PVH="$ph"; _LGD_PVW="$pw"
  # BH-5294: a BLOCK never leaves its own head but through BH-3930's rebound replay.
  [ "$pw" = BLOCK ] && [ "$rebound" != 1 ] && return 0
  st=$(_lgr_state) || { _lgt_log "$slug#$n @$h12: no harness root; no replay, full review"; return 0; }
  mkdir -p "$st" 2>/dev/null
  project=$(awk -v r="$slug" '$1 !~ /^#/ && $2 == r {print $1; exit}' "${FLEET_CONF:-$root/fleet.conf}" 2>/dev/null)
  repo="${REPOS_ROOT:-/root/repos}/$project"
  if [ "$ld" = 1 ]; then
    # A protected or over-max class is only reused under the same allowance and word (BH-5582).
    cls=$(awk -F'\t' -v s="$slug" -v n="$n" -v g="$ph" -v h="$head" -v m="$_LGR_LDMAX" -v k="$_LGR_LDPMAX:$pw" \
      '$2 == s && $3 == n && $4 == g && $5 == h && $6 == m \
       && (($7 !~ /^full (protected:|over-max:)/ && $7 !~ / protected:/) || $8 == k) {c = $7} END {print c}' "$st/delta.tsv" 2>/dev/null)
  fi
  if [ -n "$cls" ]; then :
  elif ! command -v patch_same >/dev/null 2>&1; then _lgt_log "$slug#$n @$h12: bin/lib/patch-same.sh not loaded; full review"; return 0
  elif [ -z "$project" ] || [ ! -d "$repo/.git" ]; then _lgt_log "$slug#$n @$h12: no checkout at $repo; full review"; return 0
  elif ! patch_same_fetch "$repo" "$ph" "$head" "$n"; then _lgt_log "$slug#$n @$h12: fetch of ${ph:0:12}/$h12 failed (${PS_FETCH_ERR:-no git error text}); full review"; return 0
  elif [ "$ld" = 1 ]; then
    cls=$(ld_classify "$repo" origin/main "$ph" "$head" "$slug" "$pw")
    # Only answers git settled are cached; a knob or read that failed is asked again.
    case "$cls" in
      "full protected:"*|"full over-max:"*|"delta "*" protected:"*)
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$slug" "$n" "$ph" "$head" "$_LGR_LDMAX" "$cls" "$_LGR_LDPMAX:$pw" >> "$st/delta.tsv" ;;
      "replay "*|"delta "*|"full binary"|"full knob-off")
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$slug" "$n" "$ph" "$head" "$_LGR_LDMAX" "$cls" >> "$st/delta.tsv" ;;
    esac
  elif how=$(patch_same "$repo" origin/main "$ph" "$head"); then cls="replay $how"
  else _lgt_log "$slug#$n @$h12: patch changed since ${ph:0:12}; full review"; return 0
  fi
  case "$cls" in
    "replay "*)
      how=${cls#replay }
      # BH-5909: a replayed MERGE would skip the console QA gate.
      hrepo=$(awk '$1 == "cromford" {print $2; exit}' "${FLEET_CONF:-$root/fleet.conf}" 2>/dev/null)
      if [ "$pw" != BLOCK ] && [ -n "$hrepo" ] && command -v cqg_replay_hold >/dev/null 2>&1 && _lgd_cqg_on \
         && cqh=$(cqg_replay_hold "$slug" "$n" "$head" "$repo" origin/main "$hrepo"); then
        _lgt_log "$slug#$n @$h12: no lead $pw replay from ${ph:0:12} ($cqh); full review"
        return 0
      fi
      # BH-6967: the replayed row's own mode; a row with none was a full review.
      case "$pm" in full|intent) ;; *) pm=full ;; esac
      tok="${LEAD_VERDICT_TOKEN_FILE:-${HOME:-}/.config/cromford/lead-verdict-token}"
      if [ ! -r "$tok" ]; then
        _lgt_log "$slug#$n @$h12: since ${ph:0:12}: $cls; no lead token on this box, so review_one's own replay decides"
        return 0
      fi
      box="${JOBS_BOX:-}"; [ -n "$box" ] || box=$(local_box_name 2>/dev/null)
      prc=0; out=$("$root/bin/lead-verdict.sh" post "$slug" "$n" "$head" "$pw" --source lead --reviewer "box:${box:-unknown}" \
        --note "lead-replay:${ph:0:12} how:$how" --review-mode "$pm" 2>&1) || prc=$?
      case "$prc" in
        0|4|5)
          printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$(date -u +%Y%m%d)" replay "$slug" "$n" "$head" \
            "from=${ph:0:12} how=$how" >> "$st/modes.tsv" 2>/dev/null || true
          _lgt_log "$slug#$n @$h12: lead $pw replayed from ${ph:0:12} (how:$how, post rc $prc); no review"
          return 12 ;;
      esac
      _lgt_log "$slug#$n @$h12: lead $pw replay from ${ph:0:12} not recorded (post rc $prc: $(printf '%s' "$out" | tr '\n' ' ' | head -c 200)); held"
      return 11 ;;
    "delta "*)
      if [ "$pw" != BLOCK ]; then
        local dl dm df dp=""
        read -r _ dl dm df dp <<<"$cls"
        LG_MODE=delta; LGD_NOTE="lead-delta:$ph lines:$dl/$dm files:$df${dp:+ $dp}"
        _lgt_log "$slug#$n @$h12: since ${ph:0:12}: $cls; LG_MODE=delta (lead $pw, verdict row #$pid)"
      fi ;;
    *) _lgt_log "$slug#$n @$h12: since ${ph:0:12}: ${cls}; a full lead review" ;;
  esac
  return 0
}

# The fields of this head's job and scope notes (BH-5878).
lg_field_delta_note() {
  [ "$LGD_KEY" = "$1#$2@$(printf '%s' "$3" | tr 'A-F' 'a-f')" ] && printf '%s' "$LGD_NOTE"
  return 0
}
# lg_field_prev_note — the re-review group (lpv_note), computed here, after
#   every gate passed, so no held head pays the git work.
lg_field_prev_note() {
  local slug="$1" n="$2" head root="${HARNESS:-${H:-}}" project repo note c
  head=$(printf '%s' "$3" | tr 'A-F' 'a-f')
  [ "$LGD_KEY" = "$slug#$n@$head" ] && [ -n "$_LGD_PVH" ] && command -v lpv_note >/dev/null 2>&1 || return 0
  project=$(awk -v r="$slug" '$1 !~ /^#/ && $2 == r {print $1; exit}' "${FLEET_CONF:-$root/fleet.conf}" 2>/dev/null)
  repo="${REPOS_ROOT:-/root/repos}/$project"
  if [ -z "$project" ] || [ ! -d "$repo/.git" ]; then
    _lgt_log "$slug#$n @${head:0:12}: re-review of ${_LGD_PVH:0:12} ($_LGD_PVW): no checkout at $repo; no lead-prev note"
    return 0
  fi
  if ! git -C "$repo" cat-file -e "$_LGD_PVH^{commit}" 2>/dev/null || ! git -C "$repo" cat-file -e "$head^{commit}" 2>/dev/null; then
    command -v patch_same_fetch >/dev/null 2>&1 && patch_same_fetch "$repo" "$_LGD_PVH" "$head" >/dev/null 2>&1
  fi
  note=$(lpv_note "$repo" origin/main "$_LGD_PVH" "$_LGD_PVW" "$head" "$n")
  c=${note#* own-commits:}
  _lgt_log "$slug#$n @${head:0:12}: re-review of ${_LGD_PVH:0:12} ($_LGD_PVW): own-commits:${c%% *}"
  printf '%s' "$note"
  return 0
}
