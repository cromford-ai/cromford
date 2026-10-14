#!/bin/bash
# bin/lib/mc-eject-cause.sh — WHY A HEAD LEFT THE MERGE QUEUE, AND A REQUEUE
# THAT WAITS FOR A PRE-QUEUE RUN (BH-6161). Sourced by bin/merge-conductor.sh
# and bin/lib/mc-stale-dequeue.sh's caller, never executed.
#
# WHY. #4735 and #4029 were ejected again and again. Mergify stated a cause on
# every dequeue: a `## Reason` section ("failing checks", the check names) and
# a "Left the queue … at `<sha>`" line. The conductor wrote `queue-ejected` with
# no cause and logged "the batch build went red" for every ejection. And the
# requeue arms put the SAME head back with no run in between.
#
# THE CAUSE. ec_cause answers one `<cause>\t<detail>` per ejection:
#   head-moved  the PR head is not the queued head (no read)
#   batch-red   the native queue: its merge_group build went red (no read)
#   conflict | review | timeout | checks | dequeued | head-moved | other
#               from the `## Reason` of Mergify's comment for this head
#   unknown     no comment for this head, or the comments could not be read
# The settle arm writes it to one record file per PR, one EJECT_CAUSE log line,
# and the row reason (`queue-ejected: <cause> (<detail>)`).
#
# THE RECORD. $MC_STATE_DIR/eject-cause/<owner_repo>_<num>, the last 20 lines:
#   <epoch>\t<head>\t<first|again>\t<cause>\t<detail>
# One line per (head, first|again). A record that cannot be written is one log
# line: recording never stops an ejection.
#
# THE GATED REQUEUE. ec_requeue_gate asks pq_gate (bin/lib/mc-prequeue.sh)
# before the re-entry arm or the stale-dequeue arm requeues an ejected head.
# PQ_MIN_AT (the ejection time) keeps pq_resolve from reusing a verdict that was
# dispatched before the ejection. proceed requeues; hold waits; red parks
# prequeue-red; a conflict goes to NEEDS_REBASE.
#
# KNOBS (catalog/lanes.d/merge-conductor.json, read through lane_knob):
#   MC_EJECT_CAUSE=1       0 = no cause read, the reasons before BH-6161
#   MC_REQUEUE_PREQUEUE=1  0 = the requeue arms ask no gate
#
# No root of its own: the record lives under MC_STATE_DIR, and without it
# nothing is written (D43).

# ec_knob <ENV> <default> — a merge-conductor lane knob for this project, a
#   non-negative integer, else the default (the _bej_knob pattern).
ec_knob() {
  local v
  if command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob merge-conductor "$1" "${P:-}" 2>/dev/null)
  else v="${!1:-}"; fi
  case "$v" in ''|*[!0-9]*) v="$2" ;; esac
  printf '%s' "$v"
}

# _ec_same <sha> <sha> — rc 0 when both are at least 7 characters and one is a
#   prefix of the other.
_ec_same() {
  [ "${#1}" -ge 7 ] && [ "${#2}" -ge 7 ] || return 1
  case "$1" in "$2"*) return 0 ;; esac
  case "$2" in "$1"*) return 0 ;; esac
  return 1
}

# _ec_clean <text> — one TSV-safe field: no tab, newline, CR or backtick, and
#   at most <max> (default 160) characters.
_ec_clean() {
  local s="${1:-}"
  s="${s//$'\t'/ }"; s="${s//$'\n'/ }"; s="${s//$'\r'/}"; s="${s//\`/}"
  printf '%s' "${s:0:${2:-160}}"
}

# _ec_left — stdin: one Mergify body. Prints the sha of its last "Left the
#   queue" line (the last backticked hex word on it), or nothing.
_ec_left() {
  LC_ALL=C awk '/Left the queue/ { n = split($0, f, "`"); for (i = n; i >= 1; i--) if (f[i] ~ /^[0-9a-f]+$/ && length(f[i]) >= 7) { s = f[i]; break } }
    END { if (s != "") print s }'
}

# ec_classify <head> — stdin: ONE Mergify comment body, in lines. Pure.
#   Prints <cause>\t<detail>, or nothing when the body has no `## Reason`.
#   Only the `## Reason` section is read for the cause: the status list, the
#   Hint and the conditions checklist are on every comment, whatever the cause.
ec_classify() {
  local head="${1:-}" body left reason lr first names
  body=$(cat)
  left=$(printf '%s\n' "$body" | _ec_left)
  if [ -n "$left" ] && [ -n "$head" ] && ! _ec_same "$left" "$head"; then
    printf "unknown\tMergify's newest dequeue names %s, not this head\n" "${left:0:8}"; return 0
  fi
  reason=$(printf '%s\n' "$body" | awk '
    /^##[[:space:]]/ { inr = ($0 ~ /^##[[:space:]]+Reason[[:space:]]*$/); if (inr) seen = 1; next }
    inr { print }
    END { exit(seen ? 0 : 1) }') || return 0
  lr=$(printf '%s' "$reason" | LC_ALL=C tr 'A-Z' 'a-z')
  first=$(printf '%s\n' "$reason" | awk 'NF { sub(/^[[:space:]>]+/, ""); print; exit }')
  if [[ "$lr" == *conflict* ]]; then
    printf 'conflict\t%s\n' "$(_ec_clean "$first")"
  elif command -v mc_mergify_names_review >/dev/null 2>&1 \
       && printf '## Reason\n%s\n' "$reason" | mc_mergify_names_review github-review-approved; then
    printf 'review\tgithub-review-approved\n'
  elif [[ "$lr" == *timeout* || "$lr" == *"timed out"* ]]; then
    printf 'timeout\t%s\n' "$(_ec_clean "$first")"
  elif [[ "$lr" == *"failing checks"* || "$reason" == *"❌"* ]]; then
    # The names: from the `- ❌ [`NAME`](…)` lines, else the `- `NAME`` bullets.
    names=$(printf '%s\n' "$reason" | awk '/^[[:space:]>]*-[[:space:]]+❌/ { n = split($0, f, "`"); if (n >= 3 && f[2] != "") print f[2] }')
    [ -n "$names" ] || names=$(printf '%s\n' "$reason" | awk '/^[[:space:]>]*-[[:space:]]+`[^`]+`[[:space:]]*$/ { n = split($0, f, "`"); print f[2] }')
    printf 'checks\t%s\n' "$(_ec_clean "$(printf '%s\n' "$names" | awk 'NF' | paste -sd, - | sed 's/,/, /g')")"
  elif [[ "$lr" == *dequeue* ]]; then
    printf 'dequeued\t%s\n' "$(_ec_clean "$first")"
  elif [[ "$lr" == *updated* || "$lr" == *synchroniz* || "$lr" == *"new commit"* ]]; then
    printf 'head-moved\t%s\n' "$(_ec_clean "$first")"
  else
    printf 'other\t%s\n' "$(_ec_clean "$first")"
  fi
}

# ec_cause <provider> <slug> <url> <head> [live-head] -> <cause>\t<detail>, rc 0.
#   One comments read, and only for a Mergify ejection of a head that has not
#   moved. The comment read is the newest mergify[bot] body whose Left-the-queue
#   sha is this head; with none, the newest one that has a `## Reason`.
ec_cause() {
  local prov="${1:-}" slug="${2:-}" url="${3:-}" head="${4:-}" live="${5:-}" num raw b chosen="" anyr="" out i
  local -a bodies=()
  if [ -n "$live" ] && [ -n "$head" ] && ! _ec_same "$live" "$head"; then
    printf 'head-moved\tPR head is now %s\n' "${live:0:8}"; return 0
  fi
  [ "$prov" = mergify ] || { printf 'batch-red\tmerge_group build\n'; return 0; }
  num="${url##*/}"
  case "$num" in ''|*[!0-9]*) printf 'unknown\tno PR number in the URL\n'; return 0 ;; esac
  if ! mc_rest_var raw gh_rest_issue_comments "$slug" "$num" 1000 || [ -z "$raw" ]; then
    printf 'unknown\tdequeue comments unreadable\n'; return 0
  fi
  # One line per mergify[bot] body, oldest first, its newlines folded to \x01
  # (the mc_dequeue_reason fold).
  mapfile -t bodies < <(jq -r '.[]? | select((.user.login // "") == "mergify[bot]") | ((.body // "") | gsub("[\r\n]+"; "\u0001"))' <<<"$raw" 2>/dev/null)
  for ((i = ${#bodies[@]} - 1; i >= 0; i--)); do
    b=$(printf '%s\n' "${bodies[$i]}" | tr '\001' '\n')
    if _ec_same "$(printf '%s\n' "$b" | _ec_left)" "$head"; then chosen="$b"; break; fi
    [ -z "$anyr" ] && grep -qE '^##[[:space:]]+Reason[[:space:]]*$' <<<"$b" && anyr="$b"
  done
  [ -n "$chosen" ] || chosen="$anyr"
  out=""; [ -n "$chosen" ] && out=$(printf '%s\n' "$chosen" | ec_classify "$head")
  [ -n "$out" ] || out=$(printf 'unknown\tno Mergify dequeue reason')
  printf '%s\n' "$out"
}

# ec_file <slug> <num> — the record path; rc 1 with no MC_STATE_DIR.
ec_file() {
  [ -n "${MC_STATE_DIR:-}" ] || return 1
  printf '%s/eject-cause/%s_%s' "$MC_STATE_DIR" "${1//\//_}" "$2"
}

# _ec_find <file> <head> [ord] — the newest record line for head (prefix rule),
#   and of that ord when given.
_ec_find() {
  [ -r "$1" ] || return 0
  awk -F'\t' -v h="$2" -v o="${3:-}" '
    function same(a, b) { return length(a) >= 7 && length(b) >= 7 && (index(a, b) == 1 || index(b, a) == 1) }
    same($2, h) && (o == "" || $3 == o) { l = $0 }
    END { if (l != "") print l }' "$1" 2>/dev/null
}

# ec_record <slug> <num> <head> <first|again> <cause> <detail> — rc 0 always.
ec_record() {
  local slug="$1" num="$2" head="$3" ord="$4" cause="$5" detail="$6" f now
  f=$(ec_file "$slug" "$num") || return 0
  [ -n "$(_ec_find "$f" "$head" "$ord")" ] && return 0
  now=$(mc_now 2>/dev/null) || now=$(date -u +%s)
  if ! { mkdir -p "${f%/*}" \
         && { [ -r "$f" ] && tail -n 19 "$f"; printf '%s\t%s\t%s\t%s\t%s\n' "$now" "$head" "$ord" "$(_ec_clean "$cause" 40)" "$(_ec_clean "$detail")"; } > "$f.tmp.$$" \
         && mv -f "$f.tmp.$$" "$f"; } 2>/dev/null; then
    rm -f "$f.tmp.$$" 2>/dev/null
    command -v mc_log >/dev/null 2>&1 && mc_log "EJECT_CAUSE_UNRECORDED $slug#$num ${head:0:8} $ord $cause — the record $f could not be written; the ejection goes on"
  fi
  return 0
}

# ec_summary <slug> <num> — the last two ejections, numbered by their place in
#   the record: "1 <cause> (<detail>) on <head8>; 2 …". Nothing with no record.
ec_summary() {
  local f s
  f=$(ec_file "$1" "$2") || return 0
  [ -s "$f" ] || return 0
  s=$(awk -F'\t' '{ l[NR] = $0 }
    END { for (i = (NR > 1 ? NR - 1 : 1); i <= NR; i++) { split(l[i], x, "\t")
            o = o (o == "" ? "" : "; ") i " " x[4] (x[5] != "" ? " (" x[5] ")" : "") " on " substr(x[2], 1, 8) }
          print o }' "$f" 2>/dev/null)
  _ec_clean "$s" 240
}

# ec_last_at <slug> <num> <head> — the epoch of the newest record line for head.
ec_last_at() {
  local f
  f=$(ec_file "$1" "$2") || return 0
  _ec_find "$f" "$3" | cut -f1
}

# ec_head_why <slug> <num> <head> — "<cause> (<detail>)" of the newest record
#   line for head, or nothing.
ec_head_why() {
  local f l c d
  f=$(ec_file "$1" "$2") || return 0
  l=$(_ec_find "$f" "$3"); [ -n "$l" ] || return 0
  IFS=$'\t' read -r _ _ _ c d <<<"$l"
  printf '%s%s' "$c" "${d:+ ($d)}"
}

# ec_requeue_gate <slug> <num> <url> <head> <pbase> [min_at] — run in the
#   caller's shell, never in $( ). Sets EC_PQ_WORD (proceed|wait|red|rebase)
#   and EC_PQ_WHY. rc 0 = proceed with the requeue.
ec_requeue_gate() {
  local slug="${1:-}" num="${2:-}" url="${3:-}" head="${4:-}" pbase="${5:-}" min_at="${6:-}" key st
  EC_PQ_WORD=proceed; EC_PQ_WHY=""
  [ "$(ec_knob MC_REQUEUE_PREQUEUE 1)" = 0 ] && return 0
  command -v pq_gate >/dev/null 2>&1 || return 0
  key="$slug#$num"
  PQ_MIN_AT="$min_at" pq_gate "$slug" "$num" "$url" "$head" "$pbase" >/dev/null
  case "$PQ_VERDICT" in
    hold|defer)
      EC_PQ_WORD=wait
      EC_PQ_WHY="requeue waits for the pre-queue run${PQ_MAIN:+ on main ${PQ_MAIN:0:12}}: ${PQ_WHY:-no verdict yet}" ;;
    rebase)
      EC_PQ_WORD=rebase; EC_PQ_WHY="$PQ_WHY" ;;
    red)
      EC_PQ_WORD=red
      EC_PQ_WHY="prequeue-red: $PQ_SUITES on main ${PQ_MAIN:0:12} — the head merged onto current main fails them (after a queue ejection)"
      mc_attempt_has "pqred $key $head $PQ_MAIN" 2>/dev/null \
        || { mc_attempt_put "pqred $key $head $PQ_MAIN"
             mc_log "$key PREQUEUE_RED on ${head:0:8}: $PQ_SUITES fail merged onto main ${PQ_MAIN:0:12} — not re-queued after its ejection, handed to bin/blocked-resolver.sh: $url"; } ;;
    *)
      # A cached conflict on current main is a proceed to pq_gate; a requeue of
      # that head can only be ejected again.
      read -r st _ <<<"$(pq_cache_get "${PQ_PATH:-}")"
      [ "$st" = conflict ] && { EC_PQ_WORD=rebase; EC_PQ_WHY="the head conflicts with main ${PQ_MAIN:0:12}"; } ;;
  esac
  mc_attempt_has "rqpq $key $head ${PQ_MAIN:--}.$EC_PQ_WORD" 2>/dev/null \
    || { mc_attempt_put "rqpq $key $head ${PQ_MAIN:--}.$EC_PQ_WORD"
         mc_log "REQUEUE_PREQUEUE $key $head main=${PQ_MAIN:0:12} -> $EC_PQ_WORD${EC_PQ_WHY:+ ($EC_PQ_WHY)}"; }
  [ "$EC_PQ_WORD" = proceed ]
}
