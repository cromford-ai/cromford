# bin/lib/handoff-watch.sh — A HAND-OFF TO THE RESOLVER ACTS, SAYS WHY NOT, OR
# PAGES (BH-5125). Sourced by bin/blocked-resolver.sh and bin/review-rescue.sh,
# both behind `[ -r ] && .`, so a box without it runs today's code.
#
# WHY IT EXISTS. 2026-10-07 04:34:50Z: bin/review-rescue.sh logged that PR #5067
# "goes to bin/blocked-resolver.sh for an agent fix round", and no round ran.
# Nobody was fixing it until a hand round started ~05:09Z. A rescued
# REVIEW_BLOCKED record is offered by br_from_builds only once its RESULT is 90
# minutes old, and then as rescue-giving-up (a fresh rebuild), and nothing
# measured whether the resolver ever got to it. Every place a row can fall out
# of a tick without a line (a source floor, the rung budget, the key lock) was
# silent, and the conductor writes `handed to bin/blocked-resolver.sh, not
# paged` for its parks, so in those cases nobody pages by design.
#
# THE RECORD. One CLAIM per hand-off, one ACK file per kind:
#   state/blocked-resolver/handoffs/claims/<id>
#     first_at  not_before  project  tkey  url  who  paged_at  words   (TSV)
#   state/blocked-resolver/handoffs/acks/<id>.<kind>    <epoch>
# <id> is "<project>-<tkey>" (or the PR url's "<owner>/<repo>#<n>" when the
# tkey is "-"), with every character outside [A-Za-z0-9._-] made "-", which is
# br_rkey's rule. A rescue claim and the later rescue-giving-up candidate for the
# same ticket share it, so the candidate's dispatch acks the rescue claim.
#
# THE ACK KINDS. acted: a rung did something (any br_event but the two below),
# and it CLOSES the claim. dispatched: the tick reached the row (br_one ran, or
# br_event resolver_preflight / resolver_yield). lock-held: a round for the key
# is already running. held: the project is held (lane_project_held). The last
# three keep a claim from paging and never close it.
#
# THE SWEEP (bhw_sweep, once at the end of a tick), per claim:
#   - older than BR_HANDOFF_MAX_AGE_SECS (default 172800): deleted.
#   - acked `acted` at or after first_at: closed (deleted).
#   - a resolver candidate's own claim (who=resolver:*) that this tick's
#     candidate list no longer holds: deleted. The source stopped reporting the
#     park (merged, approved, retired), so nothing is owed on it any more.
#   - before not_before: nothing yet. That is the honest floor, stated.
#   - no ack from THIS tick (or a `held` one): a HANDOFF-WAIT line in
#     logs/blocked-resolver.log saying why it was not dispatched. Only the
#     BHW_WAIT_LINES oldest are named; past that, one summary line counts the
#     rest by reason.
#   - made during THIS tick (first_at >= the tick start): never silent yet. The
#     sweep runs at the end of a tick that can outlast the page window.
#   - silent (no ack of any kind) for BR_HANDOFF_SILENT_PAGE_S since
#     max(first_at, not_before, its last ack): counted for the page.
# THE PAGE: at most ONE per sweep, `lane-alert.sh --severity critical --id
# br-handoff-silent`, with the count and the BHW_PAGE_NAMES oldest silent
# claims, sent when at least one claim went silent since the last page. If the
# page is still open, it is resolved first and sent again with the new count
# (lane-alert counts a repeat of an open id and does not send it, and an open
# page must not mute a later silent hand-off: lead review lr-5160).
# state/.../handoffs/paged/<id> marks the claims the open page covers; paged_at
# is stamped and paged/<id> written only after the page answered 0, so a failed
# page is retried next sweep. Once no paged claim is left, the page is resolved,
# retried until it sends. A knob of 0 never pages.
#
# NO ROOT, NO WRITES (BH-2613): the root is ${HARNESS:-${H:-}} and nothing else;
# with neither set every function returns non-zero and writes nothing.
# shellcheck shell=bash

# THE FLOOR br_from_builds PUTS ON A RESCUED REVIEW_BLOCKED RECORD: it offers the
# record only once `find "$d/RESULT" -mmin +90` (or its ledger row is 5400 s
# old). This is a mirror of that hard-coded floor, not a new threshold, and
# tests/blocked-resolver-handoff-watch.bh-5125-test.sh keeps the two in step.
# shellcheck disable=SC2034  # read by bin/review-rescue.sh
BHW_BUILD_FLOOR_S=5400

# The sweep's two output caps. They protect the hub log and the operator's
# pager from a saturated hub, where about 665 claims wait every tick (review of
# 9251f18c3). Each firing hides only names: the summary line and the page
# still carry the full count.
BHW_WAIT_LINES=10
BHW_PAGE_NAMES=10

bhw__dir() {
  local root="${HARNESS:-${H:-}}"
  [ -n "$root" ] || return 1
  printf '%s/state/blocked-resolver/handoffs' "$root"
}
bhw__now() { printf '%s' "${BHW_NOW:-$(date -u +%s)}"; }
bhw__int() { case "${1:-}" in ''|*[!0-9]*) printf '%s' "${2:-0}" ;; *) printf '%s' "$1" ;; esac; }
bhw__say() {
  if declare -F say >/dev/null 2>&1; then say "$*"; return 0; fi
  local root="${HARNESS:-${H:-}}"
  [ -n "$root" ] && mkdir -p "$root/logs" 2>/dev/null \
    && printf '%s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$*" >> "$root/logs/blocked-resolver.log"
  return 0
}

# bhw_id <project> <tkey> <url> — the claim id, or rc 1 when the row has no
# stable one (no ticket key and no PR url).
bhw_id() {
  local p="${1:-}" tk="${2:-}" url="${3:-}" raw=""
  if [ -n "$tk" ] && [ "$tk" != - ]; then raw="$p-$tk"
  elif [[ "$url" =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
    raw="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}#${BASH_REMATCH[3]}"
  fi
  [ -n "$raw" ] || return 1
  printf '%s' "${raw//[^A-Za-z0-9._-]/-}"
}

# bhw_claim <project> <tkey> <url> <who> <not_before_epoch> <words> — idempotent:
# an existing claim keeps its first_at, not_before, who and paged_at.
bhw_claim() {
  local p="${1:-}" tk="${2:--}" url="${3:--}" who="${4:--}" nb words d id f tmp
  nb=$(bhw__int "${5:-0}" 0)
  words=$(printf '%s' "${6:-}" | tr '\t\n\r' '   ' | cut -c1-200)
  d=$(bhw__dir) || return 1
  id=$(bhw_id "$p" "$tk" "$url") || return 1
  f="$d/claims/$id"
  [ -s "$f" ] && return 0
  mkdir -p "$d/claims" 2>/dev/null || return 1
  tmp="$f.tmp.$$"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t-\t%s\n' "$(bhw__now)" "$nb" "${p:--}" "$tk" "$url" "$who" "${words:--}" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$f" 2>/dev/null && return 0
  rm -f "$tmp" 2>/dev/null
  return 1
}

# bhw_ack <project> <tkey> <url> <acted|dispatched|lock-held|held> — stamps the
# ack for the ticket id AND the PR-url id, so a claim made under either is seen.
# A write that fails says so and counts as no ack: that fails toward a page.
bhw_ack() {
  local p="${1:-}" tk="${2:--}" url="${3:--}" kind="${4:-}" d id now rc=0 seen=" "
  case "$kind" in acted|dispatched|lock-held|held) ;; *) return 1 ;; esac
  d=$(bhw__dir) || return 1
  now=$(bhw__now)
  mkdir -p "$d/acks" 2>/dev/null || { bhw__say "HANDOFF-ACK $p/$tk: $d/acks could not be created — the $kind ack is lost"; return 1; }
  for id in "$(bhw_id "$p" "$tk" -)" "$(bhw_id "$p" - "$url")"; do
    [ -n "$id" ] || continue
    case "$seen" in *" $id "*) continue ;; esac
    seen="$seen$id "
    printf '%s\n' "$now" > "$d/acks/$id.$kind" 2>/dev/null \
      || { rc=1; bhw__say "HANDOFF-ACK $id: the $kind ack could not be written — it counts as no ack"; }
  done
  return "$rc"
}

# bhw_event_ack <event> — br_event's hook. The row is the one the tick's main
# loop exported (BHW_P BHW_TKEY BHW_URL); outside a tick nothing is acked.
bhw_event_ack() {
  [ -n "${BHW_P:-}" ] || return 0
  case "${1:-}" in
    resolver_preflight|resolver_yield) bhw_ack "$BHW_P" "${BHW_TKEY:--}" "${BHW_URL:--}" dispatched ;;
    *) bhw_ack "$BHW_P" "${BHW_TKEY:--}" "${BHW_URL:--}" acted ;;
  esac
  return 0
}

# bhw_tick_begin — the start of a resolver tick: the epoch every "acked this
# tick" test compares against, and an empty list of this tick's candidates.
bhw_tick_begin() {
  local d
  d=$(bhw__dir) || return 1
  mkdir -p "$d" 2>/dev/null || return 1
  BHW_TICK_AT=$(bhw__now)
  : > "$d/tick-cands" 2>/dev/null || return 1
}

# bhw_seen <project> <tkey> <url> — this row is on this tick's candidate list.
bhw_seen() {
  local d id
  d=$(bhw__dir) || return 1
  id=$(bhw_id "${1:-}" "${2:--}" "${3:--}") || return 1
  printf '%s\n' "$id" >> "$d/tick-cands" 2>/dev/null
}

# bhw__ackat <file> — the ack epoch into BHW_A (0 when absent). No subshell: the
# sweep asks this four times per claim, and a hub tick can hold hundreds.
bhw__ackat() {
  BHW_A=0
  [ -f "$1" ] && read -r BHW_A < "$1" 2>/dev/null
  case "$BHW_A" in ''|*[!0-9]*) BHW_A=0 ;; esac
}

# bhw_sweep <stopreason> — the end of a tick (see the header for the rules).
bhw_sweep() {
  local stop="${1:-drained}" d root now page_s maxage tick f id fa nb p tk url who pa words
  local acted last k a start since why ageM n=0 lrc incand nwait=0 ntot=0 names msg
  local w_held=0 w_budget=0 w_share=0 w_cand=0
  local -A cands=()
  d=$(bhw__dir) || return 1
  root="${HARNESS:-${H:-}}"
  [ -d "$d/claims" ] || return 0
  now=$(bhw__now)
  page_s=$(bhw__int "${BR_HANDOFF_SILENT_PAGE_S:-1800}" 1800)
  maxage=$(bhw__int "${BR_HANDOFF_MAX_AGE_SECS:-172800}" 172800)
  tick=$(bhw__int "${BHW_TICK_AT:-$now}" "$now")
  if [ -f "$d/tick-cands" ]; then
    while IFS= read -r id; do [ -n "$id" ] && cands["$id"]=1; done < "$d/tick-cands"
  fi
  # wait.tsv: one `<since>\t<line>` per claim not dispatched this tick; silent.tsv:
  # `<since>\t<id>\t<who>\t<url>\t<paged:0|1>` per claim past the page window.
  : > "$d/wait.tsv" 2>/dev/null; : > "$d/silent.tsv" 2>/dev/null
  for f in "$d"/claims/*; do
    [ -f "$f" ] || continue
    case "$f" in *.tmp.*) continue ;; esac
    id=${f##*/}
    IFS=$'\t' read -r fa nb p tk url who pa words < "$f" || continue
    case "$fa" in ''|*[!0-9]*) fa=$now ;; esac
    case "$nb" in ''|*[!0-9]*) nb=0 ;; esac
    incand=0; [ -n "${cands[$id]:-}" ] && incand=1
    if [ $((now - fa)) -gt "$maxage" ]; then rm -f "$f" "$d/acks/$id".*; continue; fi
    bhw__ackat "$d/acks/$id.acted"; acted=$BHW_A
    if [ "$acted" -ge "$fa" ] && [ "$acted" -gt 0 ]; then rm -f "$f" "$d/acks/$id".*; continue; fi
    case "$who" in
      resolver:*) [ "$incand" = 1 ] || { rm -f "$f" "$d/acks/$id".*; continue; } ;;
    esac
    [ "$now" -ge "$nb" ] || continue
    last=0
    for k in dispatched lock-held held; do
      bhw__ackat "$d/acks/$id.$k"; [ "$BHW_A" -gt "$last" ] && last=$BHW_A
    done
    bhw__ackat "$d/acks/$id.held"; a=$BHW_A
    if [ "$last" -lt "$tick" ] || [ "$a" -ge "$tick" ]; then
      if [ "$a" -ge "$tick" ]; then why="project held"; w_held=$((w_held+1))
      elif [ "$incand" = 1 ]; then
        case "$stop" in
          budget|tick-budget) why="tick stopped at $stop before reaching it"; w_budget=$((w_budget+1)) ;;
          *) why="its project's share of this tick was spent before it"; w_share=$((w_share+1)) ;;
        esac
      else why="not a candidate (a source floor or filter kept it out)"; w_cand=$((w_cand+1)); fi
      ageM=$(( (now - fa) / 60 ))
      nwait=$((nwait+1))
      printf '%s\tHANDOFF-WAIT %s: claimed by %s %sm ago — not dispatched this tick: %s\n' "$fa" "$id" "$who" "$ageM" "$why" >> "$d/wait.tsv"
    fi
    # A claim made during THIS tick has not had one tick to be dispatched yet:
    # the sweep runs at the end of a tick that can be longer than the page
    # window (about 3000 s on a saturated hub), so it is never silent here.
    [ "$fa" -ge "$tick" ] && continue
    start=$fa; [ "$nb" -gt "$start" ] && start=$nb
    since=$start; [ "$last" -gt "$since" ] && since=$last
    if [ "$page_s" -gt 0 ] && [ $((now - since)) -ge "$page_s" ]; then
      ntot=$((ntot+1))
      if [ "$pa" != - ] && [ -n "$pa" ]; then
        printf '%s\t%s\t%s\t%s\t1\n' "$since" "$id" "$who" "$url" >> "$d/silent.tsv"
      else
        n=$((n+1)); printf '%s\t%s\t%s\t%s\t0\n' "$since" "$id" "$who" "$url" >> "$d/silent.tsv"
      fi
    fi
  done
  # THE LOG, RATE-LIMITED: the BHW_WAIT_LINES oldest claims by name, then one
  # summary line. A saturated hub leaves hundreds of claims undispatched every
  # tick, and one line each buried the log (review of 9251f18c3).
  if [ "$nwait" -gt 0 ]; then
    sort -n "$d/wait.tsv" | head -"$BHW_WAIT_LINES" | cut -f2- | while IFS= read -r msg; do bhw__say "$msg"; done
    [ "$nwait" -gt "$BHW_WAIT_LINES" ] && bhw__say "HANDOFF-WAIT summary: $nwait hand-off(s) not dispatched this tick (tick budget $w_budget, project share $w_share, not a candidate $w_cand, held $w_held); the $BHW_WAIT_LINES oldest are named above"
  fi
  # ONE AGGREGATED PAGE PER SWEEP, under the stable id br-handoff-silent, naming
  # the count and the BHW_PAGE_NAMES oldest silent claims. A page per claim sent
  # about 665 critical pages on the first hub tick (review of 9251f18c3).
  # lane-alert.sh counts a repeat of an OPEN id and does not send it, so when a
  # NEW claim goes silent while the page is open, the open page is resolved and
  # sent again with the new count (lead review lr-5160: an open page must not
  # mute a later silent hand-off). $d/paged/<id> keeps per-claim state only:
  # which claims the open page covers. paged_at is stamped, and paged/<id>
  # written, only after the page answered 0, so a failed page is retried.
  if [ "$n" -gt 0 ] && [ -n "$root" ] && [ -x "$root/bin/lane-alert.sh" ]; then
    lrc=0
    if [ -f "$d/paged-open" ]; then
      "$root/bin/lane-alert.sh" --resolve --id br-handoff-silent blocked-resolver \
        "replaced by a new count: more resolver hand-offs went silent" >/dev/null 2>&1 </dev/null \
        && rm -f "$d/paged-open" || lrc=1
    fi
    names=$(sort -n "$d/silent.tsv" | head -"$BHW_PAGE_NAMES" \
      | awk -F'\t' -v t="$now" '{ printf "%s%s (%s, %s) silent %dm", (NR > 1 ? "; " : ""), $2, $3, $4, (t - $1) / 60 }')
    if [ "$lrc" = 0 ] && "$root/bin/lane-alert.sh" --severity critical --id br-handoff-silent blocked-resolver \
         "$ntot resolver hand-off(s) silent for ${page_s}s+ ($n new): handed to bin/blocked-resolver.sh and no tick dispatched them. Oldest: $names. The HANDOFF-WAIT lines in logs/blocked-resolver.log say why." \
         >/dev/null 2>&1 </dev/null; then
      : > "$d/paged-open" 2>/dev/null
      mkdir -p "$d/paged" 2>/dev/null
      while IFS=$'\t' read -r since id who url k; do
        [ "$k" = 0 ] || continue
        f="$d/claims/$id"
        awk -F'\t' -v OFS='\t' -v t="$now" '{ $7 = t; print }' "$f" > "$f.tmp.$$" 2>/dev/null \
          && mv -f "$f.tmp.$$" "$f" 2>/dev/null
        : > "$d/paged/$id" 2>/dev/null
      done < "$d/silent.tsv"
      bhw__say "HANDOFF-PAGE one page for $ntot silent hand-off(s), $n new"
    else
      bhw__say "HANDOFF-PAGE the page did not send (lane-alert.sh failed) — retried next sweep: $n new silent hand-off(s)"
    fi
  elif [ "$n" -gt 0 ]; then
    bhw__say "HANDOFF-PAGE no bin/lane-alert.sh — retried next sweep: $n new silent hand-off(s)"
  fi
  # Per-claim state: a paged claim that is gone (acted, retired, aged out)
  # leaves the page. When none is left, the page is resolved, retried until it
  # sends.
  if [ -d "$d/paged" ]; then
    for f in "$d"/paged/*; do
      [ -f "$f" ] || continue
      [ -f "$d/claims/${f##*/}" ] || rm -f "$f"
    done
  fi
  if [ -f "$d/paged-open" ] && [ -z "$(ls -A "$d/paged" 2>/dev/null)" ]; then
    [ -n "$root" ] && [ -x "$root/bin/lane-alert.sh" ] \
      && "$root/bin/lane-alert.sh" --resolve --id br-handoff-silent blocked-resolver \
           "every paged resolver hand-off was acted on or retired" >/dev/null 2>&1 </dev/null \
      && rm -f "$d/paged-open"
  fi
  return 0
}
