#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-gates.d/60-risk.sh — gates 4 (the risk tier, BH-5022, with the
# rules-text lane of BH-5325) and 6 (the JEV shadow, BH-5024), ported from
# bin/lead-review-enqueue.sh (BH-5878). These worklist facts hold:
#   - Only when rt_mode (bin/lib/risk-tier.sh) says shadow or enforce for the
#     repo. Off = rc 0, and no PR read.
#   - Rule 2c (BH-6968): while risk_tier.low_score_max > 0, rt_evidence_load
#     reads the head's evidence (the PR body, its prequeue-verdict status, the
#     queue-risk score) before rt_classify, as the enqueue does.
#   - The PR read (pulls/<n>, for .user.login) and the compare read failing =
#     rc 11. The compare is lgc_compare's (bin/lib/lead-gates-compare.sh): the
#     repo's default branch, the base gate 15 reads.
#   - The tier cache, the risk-pub and the withheld lines are the enqueue's
#     state/lead-review-enqueue/risk.tsv and risk-pub-* (same format, column 8
#     rt_low_rule's path|evidence|-, BH-6968), so a
#     head classified once is not classified again; gate 20 (20-standing.sh)
#     publishes a risk-pub marker again.
#   - low + enforce: bin/lead-verdict.sh post <head> MERGE --source risk-tier
#     --review-tier low --review-mode risk-tier first. Post rc 0 or 4 = rc 12
#     (decided, no review); rc 5 (withheld) = rc 0 (full review); rc 3 or any
#     other rc = rc 11 (held: a failed write is never a sign-off and never a
#     paid review). No sign-off, rc 0 and a full review instead (the enqueue's
#     rules): a head no reviewer approved (gate 10 left it unapproved, or passed
#     it on a HUMAN-STEP-DONE answer: BH-5630, BH-6696), except a lead-authored
#     rules-text low; and a head with lead-route silence notes (gate 30 passes
#     it; the lead judges the markers).
#   - The tokens (BH-6967): a head classified low (or withheld), medium or high
#     gets field review_tokens `review-tier:<t> review-mode:<full|intent>`, the
#     last group of its scope notes. intent only for a medium head with no
#     delta note from gate 50 while the row risk_tier.medium_mode reads intent
#     (trimmed, any case, read once a process; no row, an unreadable row or
#     another value is full, and an unreadable or bad value is one log line).
#     The first computation is stored in state/lead-review-enqueue/
#     review-tier-<slug_>-<n>-<sha12>; a stored file wins, so a head's notes
#     never change. Markers go after 7 days (lg_tick_risk, once a process,
#     the enqueue's own review-tier-* prune).
#   - Every call sets LG_RISK_KEY (<slug>#<n>@<head>), LG_RISK_TIER and
#     LG_RISK_MODE for 70-inbuild-grace.sh, cleared first.
# Missing libs keep the enqueue's documented behavior: no risk-tier.sh = mode
# off; no rules-render-head.sh = no rules head is low; no ticket-ownership.sh
# = the head is not classified, rc 0. Sourced by bin/lib/lead-gates.sh.

# shellcheck source=bin/lib/risk-tier.sh
. "${BASH_SOURCE[0]%/*}/../risk-tier.sh" 2>/dev/null || true
# shellcheck source=bin/lib/rules-render-head.sh
. "${BASH_SOURCE[0]%/*}/../rules-render-head.sh" 2>/dev/null || true
# shellcheck source=bin/lib/ticket-ownership.sh
. "${BASH_SOURCE[0]%/*}/../ticket-ownership.sh" 2>/dev/null || true
# shellcheck source=bin/lib/lead-gates-compare.sh
. "${BASH_SOURCE[0]%/*}/../lead-gates-compare.sh" 2>/dev/null || true
# ss_note, for the low sign-off's silence-note refusal (gate 30 holds such a
# head first; this is the second line of defense).
# shellcheck source=bin/lib/silence-scan.sh
. "${BASH_SOURCE[0]%/*}/../silence-scan.sh" 2>/dev/null || true

declare -gA _lgr_mode=() _lgr_jmode=() _lgr_jmax=() _lgr_jt=()
_LGR_JASKED=0
LG_RISK_KEY="" LG_RISK_TIER="" LG_RISK_MODE=""
declare -g _LGRT_MM="" _LGRT_TOK="" _LGRT_PRUNED=""

# _lgrt_medium_mode — intent or full, from risk_tier.medium_mode, once a process
#   (_LGRT_MM). Call it in this shell, never in $(...), so the memo stays.
_lgrt_medium_mode() {
  local v rc=0
  [ -n "$_LGRT_MM" ] && { printf '%s' "$_LGRT_MM"; return 0; }
  v=$(setting_get risk_tier.medium_mode 2>/dev/null) || rc=$?
  v=$(printf '%s' "$v" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
  _LGRT_MM=full
  case "$rc:$v" in
    0:intent) _LGRT_MM=intent ;;
    0:full|2:*) ;;
    0:*) _lgt_log "risk_tier.medium_mode reads '$v', not full or intent; a medium head gets the full review" ;;
    *) _lgt_log "risk_tier.medium_mode unreadable (rc $rc); a medium head gets the full review" ;;
  esac
  printf '%s' "$_LGRT_MM"
}

# _lgrt_tokens <slug> <n> <head> <tier> <state dir> — sets _LGRT_TOK: the
#   stored tokens of this head, else this tier's, stored on first use.
_lgrt_tokens() {
  local f t=""
  f="$5/review-tier-$(printf '%s' "${1//\//_}" | tr -cd 'A-Za-z0-9._-')-$2-${3:0:12}"
  if [ -s "$f" ]; then
    t=$(cat "$f" 2>/dev/null)
    [[ "$t" =~ ^review-tier:(low|medium|high)\ review-mode:(full|intent)$ ]] && { _LGRT_TOK="$t"; return 0; }
  fi
  case "$4" in
    low|withheld) t="review-tier:low review-mode:full" ;;
    high) t="review-tier:high review-mode:full" ;;
    medium)
      t="review-tier:medium review-mode:full"
      if [ "${LGD_KEY:-}" != "$1#$2@$3" ] || [ -z "${LGD_NOTE:-}" ]; then
        _lgrt_medium_mode >/dev/null
        [ "$_LGRT_MM" = intent ] && t="review-tier:medium review-mode:intent"
      fi ;;
    *) return 0 ;;
  esac
  _LGRT_TOK="$t"
  printf '%s' "$t" > "$f" 2>/dev/null || _lgt_log "$1#$2 @${3:0:12}: review tokens not stored in $f; a later start may send other tokens"
  return 0
}

# lg_tick_risk <slug> — the mode, the rules and the JEV rows, once a tick.
lg_tick_risk() {
  local slug="$1" m="off" w="" jv root="${HARNESS:-${H:-}}"
  _lgr_mode[$slug]=off; _lgr_jmode[$slug]=off; _lgr_jmax[$slug]=0; _lgr_jt[$slug]=30
  if [ -z "$_LGRT_PRUNED" ] && [ -n "$root" ]; then
    _LGRT_PRUNED=1
    find "$root/state/lead-review-enqueue" -maxdepth 1 -type f -name 'review-tier-*' -mtime +7 -delete 2>/dev/null
  fi
  command -v rt_classify >/dev/null 2>&1 || return 0
  IFS=$'\t' read -r m w < <(rt_mode "$slug")
  _lgr_mode[$slug]="${m:-off}"
  [ -n "$w" ] && _lgt_log "$slug risk tier: $w"
  case "${_lgr_mode[$slug]}" in shadow|enforce) ;; *) return 0 ;; esac
  rt_rules_load
  [ -n "$root" ] && [ -x "$root/bin/jev-risk.sh" ] || return 0
  jv=$(setting_get jev_risk.mode 2>/dev/null) \
    && [ "$(printf '%s' "$jv" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')" = shadow ] || return 0
  _lgr_jmode[$slug]=shadow
  jv=$(setting_get jev_risk.max_per_tick 2>/dev/null | tr -d '[:space:]'); [[ "$jv" =~ ^[0-9]{1,3}$ ]] || jv=3
  _lgr_jmax[$slug]="$jv"
  jv=$(setting_get jev_risk.timeout_s 2>/dev/null | tr -d '[:space:]'); [[ "$jv" =~ ^[1-9][0-9]{0,3}$ ]] || jv=30
  _lgr_jt[$slug]="$jv"
  return 0
}

# _lgr_lead_skip <pr body file> — the enqueue's rt_lead_skip: sets _LGR_RLEAD
# (why the risk tier must not touch this PR) and _LGR_RLAUTH=1 for a confirmed
# lead author.
_lgr_lead_skip() {
  local who
  _LGR_RLEAD=""; _LGR_RLAUTH=0
  who=$(jq -r '.user.login // empty' "$1" 2>/dev/null)
  if ! command -v to_is_lead >/dev/null 2>&1; then _LGR_RLEAD="no bin/lib/ticket-ownership.sh, so a lead author cannot be told"
  elif [ -z "$who" ]; then _LGR_RLEAD="PR author unreadable"
  else
    to__lead_load
    if [ -z "$TO_LEAD_AUTHORS" ]; then _LGR_RLEAD="lead_pr_authors row unreadable"
    elif to_is_lead "$who"; then _LGR_RLEAD="lead-authored ($who): a risk-tier row never clears a lead PR"; _LGR_RLAUTH=1
    fi
  fi
}

lg_gate_risk() {
  local slug="$1" n="$2" head="$3" h12="${3:0:12}" root="${HARNESS:-${H:-}}"
  local mode st risk safe project box prf tier="" why="" newc=0 rlines="" rfiles="" ract body
  local js jti jp jx jout rrev rtxt snote prc out
  LG_RISK_KEY=""; LG_RISK_TIER=""; LG_RISK_MODE=""; _LGRT_TOK=""
  [ -n "${_lgr_mode[$slug]+x}" ] || lg_tick_risk "$slug"
  mode="${_lgr_mode[$slug]}"
  case "$mode" in shadow|enforce) ;; *) return 0 ;; esac
  if [ -z "$root" ]; then _lgt_log "no harness root; $slug#$n @$h12 held"; return 11; fi
  st="$root/state/lead-review-enqueue"; risk="$st/risk.tsv"
  mkdir -p "$st" 2>/dev/null
  safe=$(printf '%s' "${slug//\//_}" | tr -cd 'A-Za-z0-9._-')
  project=$(awk -v r="$slug" '$1 !~ /^#/ && $2 == r {print $1; exit}' "${FLEET_CONF:-$root/fleet.conf}" 2>/dev/null)
  box=$(local_box_name 2>/dev/null)
  LG_RISK_KEY="$slug#$n@$head"; LG_RISK_MODE="$mode"
  prf="$root/state/lead-review-gates/pr-$safe-$n.json"
  mkdir -p "${prf%/*}" 2>/dev/null
  if ! gh_rest GET "repos/$slug/pulls/$n" > "$prf" 2>/dev/null; then
    _lgt_log "$slug#$n @$h12: risk tier: PR unreadable (HTTP ${GH_REST_STATUS:-000}); held"; return 11
  fi
  _lgr_lead_skip "$prf"
  if [ -n "$_LGR_RLEAD" ] && [ "$_LGR_RLAUTH" != 1 ]; then
    _lgt_log "$slug#$n @$h12: risk tier skipped ($_LGR_RLEAD); reviewed as before"; return 0
  fi
  IFS=$'\t' read -r tier why < <(awk -F'\t' -v s="$slug" -v n="$n" -v h="$head" \
    -v g="${RT_RULES_SIG:-}" '$2 == s && $3 == n && tolower($4) == h && $7 == g {t = $5 "\t" $6} END {if (t != "") print t}' "$risk" 2>/dev/null)
  if [ -z "$tier" ]; then
    if ! command -v lgc_compare >/dev/null 2>&1 || ! lgc_compare "$slug" "$n" "$head"; then
      _lgt_log "$slug#$n @$h12: risk tier: compare unreadable (rc ${LGC_RC:-none}); held"; return 11
    fi
    if [ "$LGC_SELF" = false ]; then
      RT_RULES_RENDER=""
      rt_rules_shape "$LGC_FILE" && command -v rrh_check >/dev/null 2>&1 \
        && RT_RULES_RENDER=$(rrh_check "${REPOS_ROOT:-/root/repos}/$project" "$head" "$root/bin/render-rules.sh")
      # BH-6968: rule 2c's inputs, only while its lane is on; never carried to the next head.
      RT_EVIDENCE_SCORE=""; RT_EVIDENCE_SUITES=""; RT_EVIDENCE_PREQUEUE=""; RT_EVIDENCE_WHY=""
      [ "${RT_LOW_SCORE_MAX:-0}" -gt 0 ] && rt_evidence_load "$slug" "$n" "$head" "$LGC_FILE" "$prf"
      IFS=$'\t' read -r tier why rlines rfiles < <(rt_classify "$LGC_FILE" "$slug")
      case "$tier" in low|medium|high) newc=1 ;; *) tier=""; why="compare files unreadable" ;; esac
    else
      why="compare $LGC_SELF (a Lead-Lane commit, or not read whole)"
    fi
    if [ -z "$tier" ]; then
      tier=unclassified
      printf '%s\t%s\t%s\t%s\tunclassified\t%s\t%s\n' "$(date +%s)" "$slug" "$n" "$head" "$why" "${RT_RULES_SIG:-}" >> "$risk"
      _lgt_log "$slug#$n @$h12: risk tier not classified ($why); as before"
    fi
  fi
  # BH-5325: a lead PR goes on only as a rules-text low.
  if [ "$_LGR_RLAUTH" = 1 ] && ! rt_rules_low "$tier" "$why"; then
    [ "$newc" = 1 ] && printf '%s\t%s\t%s\t%s\tlead\t%s\t%s\n' "$(date +%s)" "$slug" "$n" "$head" "$tier: $why" "${RT_RULES_SIG:-}" >> "$risk"
    _lgt_log "$slug#$n @$h12: risk tier skipped ($_LGR_RLEAD); reviewed as before"
    LG_RISK_TIER=lead; return 0
  fi
  LG_RISK_TIER="$tier"
  _lgrt_tokens "$slug" "$n" "$head" "$tier" "$st"
  if [ "$newc" = 1 ]; then
    case "$tier:$mode" in
      low:enforce) ract=sign-off ;; low:shadow) ract=would-sign-off ;;
      high:*) ract=request-first ;; *) ract=request ;;
    esac
    body=$(jq -nc --arg r "$slug" --argjson p "$n" --arg h "$head" --arg pj "$project" --arg t "$tier" \
      --arg m "$mode" --arg a "$ract" --arg w "$why" --arg l "${rlines:-}" --arg f "${rfiles:-}" \
      '{repo:$r, pr:$p, head_sha:$h, project:$pj, tier:$t, mode:$m, action:$a, reasons:$w}
       + (if ($l|test("^[0-9]+$")) then {lines:($l|tonumber)} else {} end)
       + (if ($f|test("^[0-9]+$")) then {files:($f|tonumber)} else {} end)')
    JOBS_ALERT=0 _jobs_req POST /api/risk-tiers "$body" >/dev/null 2>&1 \
      || _lgt_log "$slug#$n @$h12: POST /api/risk-tiers failed (http ${JOBS_HTTP:-none}); the console has no row for this head"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$slug" "$n" "$head" "$tier" "$why" "${RT_RULES_SIG:-}" "$(rt_low_rule "$tier" "$why")" >> "$risk"
    _lgt_log "$slug#$n @$h12: risk tier $tier ($why), mode $mode"
    [ "$tier" = low ] && [ "$mode" = shadow ] && _lgt_log "$slug#$n @$h12: risk-tier WOULD sign off (low risk: $why); shadow, so the lead review runs as before"
    # The JEV shadow (BH-5024): one log line, never a change to the tier or rc.
    if [ "${_lgr_jmode[$slug]}" = shadow ]; then
      if [ "$_LGR_JASKED" -ge "${_lgr_jmax[$slug]}" ]; then
        _lgt_log "$slug#$n @$h12: jev shadow not asked (jev_risk.max_per_tick=${_lgr_jmax[$slug]} reached this tick)"
      else
        _LGR_JASKED=$((_LGR_JASKED + 1)); js=""; jti=""; jp=""; jx=""
        IFS=$'\t' read -r js jti jp _ jx < <(JEV_CALLER="shadow:$box" timeout -k 5 $((${_lgr_jt[$slug]} + 10)) \
          "$root/bin/jev-risk.sh" ask "$slug" "$n" "$head" "$tier" "$LGC_FILE" 2>>"${LOG:-/dev/null}")
        jout="no answer"; [ -n "$js" ] && jout="$js $jti $jp${jx:+ $jx}"
        _lgt_log "$slug#$n @$h12: jev shadow $jout (rule tier $tier); shadow only, nothing changed"
      fi
    fi
  fi
  [ "$tier" = low ] && [ "$mode" = enforce ] || return 0
  rrev="risk-tier:$box"; rtxt=0
  rt_rules_low "$tier" "$why" && { rrev="risk-tier:rules-text:$box"; rtxt=1; }
  # BH-5630, BH-6696: no reviewer approved this head; only a lead-authored
  # rules-text low (its CI and the render check are green) is signed anyway.
  # BH-7043: a head gate 10 carried a builder APPROVE to counts as one no
  # reviewer approved, as in the enqueue.
  if [ "${LGB_KEY:-}" = "$slug#$n@$head" ] \
     && { [ "${LGB_APPROVED:-1}" = 0 ] || [ "${LGB_STEPDONE:-0}" = 1 ] || [ "${LGB_CARRIED:-0}" = 1 ]; } \
     && { [ "$rtxt" = 0 ] || [ "$_LGR_RLAUTH" != 1 ]; }; then
    _lgt_log "$slug#$n @$h12: risk tier low, but no reviewer approved this head (${LGB_REQFOR:-unapproved}); no risk-tier sign-off, the lead review starts"
    return 0
  fi
  snote=""; command -v ss_note >/dev/null 2>&1 && snote=$(ss_note "$st/silence" "$slug" "$n" "$head")
  if [ -n "$snote" ]; then
    _lgt_log "$slug#$n @$h12: risk tier low, but the diff adds silence markers for the lead to judge; no risk-tier sign-off, the lead review starts"
    return 0
  fi
  prc=0; out=$("$root/bin/lead-verdict.sh" post "$slug" "$n" "$head" MERGE --source risk-tier --reviewer "$rrev" \
    --note "low risk: $why" --review-tier low --review-mode risk-tier 2>&1) || prc=$?
  case "$prc" in
    0) _lgt_log "$slug#$n @$h12: signed off by risk-tier (low risk: $why); no lead review started"; return 12 ;;
    4) printf 'low risk: %s' "$why" > "$st/risk-pub-$safe-$n-$h12" 2>/dev/null
       _lgt_log "$slug#$n @$h12: signed off by risk-tier (low risk: $why), its status not published (rc 4); gate 20 publishes it on a later tick"
       return 12 ;;
    3) _lgt_log "$slug#$n @$h12: head moved before the risk-tier sign-off; held"; return 11 ;;
    5) printf '%s\t%s\t%s\t%s\twithheld\t%s\t%s\t%s\n' "$(date +%s)" "$slug" "$n" "$head" "$why" "${RT_RULES_SIG:-}" "$(rt_low_rule withheld "$why")" >> "$risk"
       LG_RISK_TIER=withheld; _lgrt_tokens "$slug" "$n" "$head" withheld "$st"
       _lgt_log "$slug#$n @$h12: risk-tier sign-off withheld (post rc 5: $(printf '%s' "$out" | tr '\n' ' ' | head -c 200)); the lead review runs"
       return 0 ;;
  esac
  _lgt_log "$slug#$n @$h12: risk-tier sign-off not recorded (post rc $prc: $(printf '%s' "$out" | tr '\n' ' ' | head -c 200)); held"
  return 11
}

# lg_field_review_tokens — this head's tier and mode tokens (header).
lg_field_review_tokens() {
  [ "${LG_RISK_KEY:-}" = "$1#$2@$3" ] && printf '%s' "$_LGRT_TOK"
  return 0
}
