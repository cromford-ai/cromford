# bin/blocked-resolver.d/bh-7555-overdue-first.sh — BH-7555: a park that has
# waited BR_UNTOUCHED_ALERT_MIN/2 is offered first in its project's run.
#
# WHY. The run orders its candidates by rung COST inside a project (BH-1457),
# then by priority rank. Park age plays no part. On project-4 an iron-law park
# (an adjudication, cost 1) sorted behind cost-0 rows that came back every
# tick, and BR_PER_TICK or BR_TICK_MAX_SECS was spent before its turn. The row
# went to br_note_untouched, the br-untouched alert fired, and the next tick
# built the same order again: 2,277 minutes with no visit.
#
# THE BAR is half of BR_UNTOUCHED_ALERT_MIN (default 120, so 60 min), so the
# park gets its visit before the untouched alert fires. 0 turns the alert off
# and this pass with it. A value that is not a number is 120, as
# bin/lib/br/opt/untouched.sh reads it. BR_OPT_OFF=bh-7555-overdue-first does
# not source this file, and the driver's call site then falls back to `cat`.

# br_fresh_park <row> <now> <min> — rc 0 when the row's url is a PR url and it
#   was parked (an epoch, not in the future) less than <min> minutes ago
#   (BH-9369 fix 5). Pure.
br_fresh_park() {
  local src p rkey reason url rec tkey parked
  IFS=$'\t' read -r src p rkey reason url rec tkey parked <<<"$1"
  [[ "${url:-}" =~ ^https://github\.com/[^/]+/[^/]+/pull/[0-9]+$ ]] || return 1
  case "${parked:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$parked" -le "$2" ] && [ $(( $2 - parked )) -lt $(( $3 * 60 )) ]
}

# br_overdue_first <now-epoch> — stdin: the run's 8-column candidate rows
# (src p rkey reason url rec tkey parked), already in cost, round-robin and
# rank order. stdout: the same rows, reordered:
#   1. the leading hotfix rows (priority_rank_meta 0), in input order. The rank
#      pass sorts them to the front, so only that prefix is looked up;
#   2. overdue rows (parked is an epoch and now - parked >= the bar), oldest
#      first, stable on a tie;
#   3. every other row, in input order.
# BH-9369 fix 5: when one overdue row is BR_STALE_OVERDUE_DAYS old (default 7,
# 0 = off), the live PR rows parked less than BR_FRESH_PARK_MIN ago (default
# 1440, 0 = off) are lifted out of 2 and 3 and go between 1 and 2, in their
# order there. With no stale row the order above stands, byte for byte.
# A parked of `-`, empty, non-numeric or in the future is never overdue:
# unknown is not oldest (D11). Every input row is printed exactly once. On any
# failure the input is printed unchanged (fail-open): the driver reads this
# output as its whole candidate list, so a dropped row is a lost park. rc 0.
br_overdue_first() {
  local now="${1:-}" knob="${BR_UNTOUCHED_ALERT_MIN:-120}" bar
  local buf line rank hotdone=0 nin=0 nout=0 out sorted
  local src p rkey reason url rec tkey parked
  local hot=() over=() rest=() said=() m
  buf=$(cat)
  [ -n "$buf" ] || return 0
  case "$knob" in ''|*[!0-9]*) knob=120 ;; esac
  case "$now" in ''|*[!0-9]*) printf '%s\n' "$buf"; return 0 ;; esac
  if [ "$knob" -eq 0 ]; then printf '%s\n' "$buf"; return 0; fi
  bar=$((knob * 30))
  while IFS= read -r line; do
    nin=$((nin + 1))
    IFS=$'\t' read -r src p rkey reason url rec tkey parked <<<"$line"
    if [ "$hotdone" = 0 ]; then
      rank=2
      case "${rec:--}" in
        -|'') ;;
        *) if command -v priority_rank_meta >/dev/null 2>&1; then
             rank=$(priority_rank_meta "$rec/ticket-meta.json" "${H:-}") \
               || { say "overdue-first: the rank lookup for ${p:--}/${rkey:--} failed — every candidate keeps its order this tick"
                    printf '%s\n' "$buf"; return 0; }
           fi ;;
      esac
      if [ "$rank" = 0 ]; then hot+=("$line"); continue; fi
      hotdone=1
    fi
    case "${parked:-}" in
      ''|*[!0-9]*) rest+=("$line"); continue ;;
    esac
    if [ "$parked" -le "$now" ] && [ $((now - parked)) -ge "$bar" ]; then
      over+=("$parked"$'\t'"$line")
      said+=("${p:--}/${rkey:--} [${reason:--}]: OVERDUE — parked $(( (now - parked) / 60 )) min (>= $((bar / 60)) = BR_UNTOUCHED_ALERT_MIN/2), offered first this tick")
    else
      rest+=("$line")
    fi
  done <<<"$buf"
  if [ "${#over[@]}" -eq 0 ]; then printf '%s\n' "$buf"; return 0; fi
  sorted=$(printf '%s\n' "${over[@]}" | sort -s -t$'\t' -k1,1n | cut -f2-) \
    || { say "overdue-first: the age sort failed — every candidate keeps its order this tick"; printf '%s\n' "$buf"; return 0; }
  # BH-9369 fix 5: A FRESH LIVE PARK GOES BEFORE A STALE OVERDUE ROW. When one
  # overdue row is BR_STALE_OVERDUE_DAYS old, the oldest-first order put 200
  # week-old rows ahead of a PR parked 30 min ago, and the fresh park waited
  # hours. Only when such a stale row exists: with none, the order above stands.
  local fdays fmin fresh=() keep=() frow fstale=0 fover=0
  fdays="${BR_STALE_OVERDUE_DAYS:-7}"   # knob: catalog/lanes.d/blocked-resolver.knobs.d/BR_STALE_OVERDUE_DAYS.json
  fmin="${BR_FRESH_PARK_MIN:-1440}"     # knob: catalog/lanes.d/blocked-resolver.knobs.d/BR_FRESH_PARK_MIN.json
  case "$fdays" in ''|*[!0-9]*) say "BR_STALE_OVERDUE_DAYS is '$fdays', not a number — the fallback 7 is used"; fdays=7 ;; esac
  case "$fmin" in ''|*[!0-9]*) say "BR_FRESH_PARK_MIN is '$fmin', not a number — the fallback 1440 is used"; fmin=1440 ;; esac
  if [ "$fdays" -gt 0 ] && [ "$fmin" -gt 0 ]; then
    for frow in "${over[@]}"; do
      [ $((now - ${frow%%$'\t'*})) -ge $((fdays * 86400)) ] && { fstale=1; break; }
    done
  fi
  if [ "$fstale" = 1 ]; then
    # fresh = live PR rows parked < BR_FRESH_PARK_MIN ago, from the over rows
    # (oldest first) and then the rest (input order); hot rows are never moved.
    local frest=()
    while IFS= read -r frow; do
      [ -n "$frow" ] || continue
      if br_fresh_park "$frow" "$now" "$fmin"; then fresh+=("$frow"); fover=$((fover+1)); else keep+=("$frow"); fi
    done <<<"$sorted"
    for frow in ${rest[@]+"${rest[@]}"}; do
      if br_fresh_park "$frow" "$now" "$fmin"; then fresh+=("$frow"); else frest+=("$frow"); fi
    done
    if [ "${#fresh[@]}" -gt 0 ]; then
      sorted=$( { printf '%s\n' "${fresh[@]}"; [ "${#keep[@]}" -eq 0 ] || printf '%s\n' "${keep[@]}"; } )
      rest=(${frest[@]+"${frest[@]}"})
      said+=("fresh-first: ${#fresh[@]} live park(s) parked < $fmin min offered before $(( ${#over[@]} - fover )) overdue row(s) older than $fdays days")
    fi
  fi
  out=$( { [ "${#hot[@]}" -eq 0 ] || printf '%s\n' "${hot[@]}"
           printf '%s\n' "$sorted"
           [ "${#rest[@]}" -eq 0 ] || printf '%s\n' "${rest[@]}"; } )
  nout=$(printf '%s\n' "$out" | wc -l)
  if [ "$nout" -ne "$nin" ]; then
    say "overdue-first: $nout rows out of $nin in — every candidate keeps its order this tick"
    printf '%s\n' "$buf"; return 0
  fi
  # The lines are said only once the new order is the one the driver gets.
  for m in "${said[@]}"; do say "$m"; done
  say "overdue-first: ${#over[@]} of $nin candidate(s) parked >= $((bar / 60)) min offered first (after ${#hot[@]} hotfix row(s))"
  printf '%s\n' "$out"
  return 0
}
