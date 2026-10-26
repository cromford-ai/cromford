#!/bin/bash
# bin/lib/pool-unblock-rank.sh — build first the tickets that unblock the most
# open work (BH-7874).
#
# 2026-10-21: example-org/project-6 had 201 open ai-build tickets and 121 of them
# waited on another open ticket. TK-1219 alone blocked 17, but the pool's
# hotfix_first walked every plain row in age order, so TK-1219 started planning
# only after the queue was 62 deep and its oldest row had waited 448 minutes.
#
# The unblock count of ticket X is the number of distinct open ai-build issues
# of the same repo that name X in a `Blocked-by:` or `Needs:` line, directly or
# through a chain. The walk is transitive and cycle-safe, and X never counts
# itself. hotfix_first (bin/fly-pool.sh) orders its LAST group (not hot, not
# RB/RR, not dispatch-now) by that count, highest first; ties keep age order.
#
# THE LINE SHAPES are bin/lib/ticket-edges.sh te_edges_from_text's, which reads
# the bin/lib/dep-verify-lib.sh shapes: every #N on a Blocked-by line, the FIRST
# #N on a Needs line. That function runs grep and sed per file, which is too
# slow for 1,000 bodies, so pur_edges is one jq and one awk over the whole
# listing. tests/fly-pool-unblock-rank.bh-7874-test.sh U4 pins the parity.
# DEPENDS: lines are not counted: the ticket names Blocked-by and Needs only.
#
# FAIL OPEN: a knob off, no slug, an unreadable page, a body that does not
# parse, or an order that does not hold exactly the input files gives the age
# order, which is the order before BH-7874.
#
#   pur_edges          stdin: one or more GitHub issue-listing JSON arrays.
#                      stdout: <child>\t<parent> per edge. PR rows, self-edges
#                      and duplicates are dropped.
#   pur_counts         stdin: edges. stdout: <ticket>\t<count> per parent,
#                      count desc then ticket asc.
#   pur_prime          caller's shell, once per tick, before the REAP. Reads
#                      the listing (POOL_UNBLOCK_RANK_MAX_PAGES pages at most)
#                      through pool_ai_listing_page (else pool_rest_read),
#                      writes $PDIR/unblock-rank.tsv,
#                      sets PUR_FILE and says one `unblock rank <p>:` line.
#                      PUR_FILE is empty when ranking did not run this tick.
#   pur_order <f>...   the job files, stably reordered by count. No read.

PUR_FILE="${PUR_FILE:-}"

pur_edges() {
  jq -r '.[]? | select(type == "object" and .pull_request == null and (.number | type) == "number")
         | (.number | tostring) as $n
         | ((.body // "") | tostring | gsub("\r"; "") | split("\n")[])
         | $n + "\t" + .' 2>/dev/null \
  | awk -F'\t' '
    function num_ok(s) { return s ~ /^[1-9][0-9]*$/ && length(s) <= 9 }
    function emit(c, p) {
      if (!num_ok(p) || p == c) return
      if ((c SUBSEP p) in seen) return
      seen[c SUBSEP p] = 1
      print c "\t" p
    }
    {
      c = $1
      line = substr($0, length($1) + 2)
      low = tolower(line)
      rest = low
      if (match(rest, /^[ \t\v\f>*_#-]+/)) rest = substr(rest, RLENGTH + 1)
      # blocked-by / blocked by, then a non-word character or the end.
      if (rest ~ /^blocked[- ]by/ && substr(rest, 11, 1) !~ /[a-z0-9_]/) {
        s = low
        while (match(s, /#[0-9]+/)) {
          emit(c, substr(s, RSTART + 1, RLENGTH - 1))
          s = substr(s, RSTART + RLENGTH)
        }
      }
      # needs, then a non-word character: the FIRST # only, if digits follow.
      if (rest ~ /^needs/ && substr(rest, 6, 1) !~ /[a-z0-9_]/) {
        s = substr(rest, 6)
        h = index(s, "#")
        if (h > 0 && match(substr(s, h + 1), /^[0-9]+/))
          emit(c, substr(s, h + 1, RLENGTH))
      }
    }'
}

pur_counts() {
  awk -F'\t' '
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $1 != $2 {
      k = $2 SUBSEP $1
      if (!(k in seen)) { seen[k] = 1; kids[$2] = kids[$2] " " $1; par[$2] = 1 }
    }
    END {
      for (p in par) {
        split("", vis); vis[p] = 1; qn = 1; q[1] = p; h = 1; cnt = 0
        while (h <= qn) {
          x = q[h++]
          if (!(x in kids)) continue
          m = split(kids[x], a, " ")
          for (i = 1; i <= m; i++)
            if (!(a[i] in vis)) { vis[a[i]] = 1; q[++qn] = a[i]; cnt++ }
        }
        print p "\t" cnt
      }
    }' | LC_ALL=C sort -t "$(printf '\t')" -k2,2nr -k1,1n
}

# _pur_fields <file>... — <file>\t<ticket_id>\t<key>\t<hot> per file with at
# least one line. One awk over every file, so a file that is not JSON costs
# its own row, never the rows after it (jq stops at the first bad file).
_pur_fields() {
  [ "$#" -gt 0 ] || return 0
  awk '
    function flush() { if (fn != "") print fn "\t" t "\t" k "\t" hot }
    FNR == 1 { flush(); fn = FILENAME; t = ""; k = ""; hot = 0 }
    t == "" && match($0, /"ticket_id"[ \t]*:[ \t]*"?[0-9]+/) {
      s = substr($0, RSTART, RLENGTH); sub(/^[^:]*:[ \t]*"?/, "", s); t = s
    }
    k == "" && match($0, /"key"[ \t]*:[ \t]*"[^"]*"/) {
      s = substr($0, RSTART, RLENGTH); sub(/^[^:]*:[ \t]*"/, "", s); sub(/"$/, "", s); k = s
    }
    /"hotfix": *true/ { hot = 1 }
    END { flush() }' "$@" 2>/dev/null
}

_pur_secs() { # _pur_secs <t0_ns> <t1_ns> -> seconds with 3 decimals
  local ms=$(( ($2 - $1) / 1000000 ))
  printf '%d.%03d' "$((ms / 1000))" "$((ms % 1000))"
}

pur_prime() {
  PUR_FILE=""
  local on="${POOL_UNBLOCK_RANK:-1}" max="${POOL_UNBLOCK_RANK_MAX_PAGES:-10}"
  case "$on" in 0|1) ;; *) say "POOL_UNBLOCK_RANK=$on is not 0 or 1 — using 1"; on=1 ;; esac
  case "$max" in
    ''|*[!0-9]*) say "POOL_UNBLOCK_RANK_MAX_PAGES=$max is not a number of pages (1-50) — using 10"; max=10 ;;
    *) [ "$max" -ge 1 ] && [ "$max" -le 50 ] \
         || { say "POOL_UNBLOCK_RANK_MAX_PAGES=$max is not a number of pages (1-50) — using 10"; max=10; } ;;
  esac
  [ "$on" = 1 ] || return 0
  [ -n "${POOL_SLUG:-}" ] && [ -n "${QDIR:-}" ] && [ -n "${PDIR:-}" ] || return 0
  # The queued rows the order can move, oldest first: not failed, not RB/RR.
  local f files=() rows rankable
  # shellcheck disable=SC2045 # job files are KEY.json; the callers word-split ls the same way
  for f in $(ls -tr "$QDIR"/*.json 2>/dev/null); do
    case "${f##*/}" in *.failed.json|RB-*|RR-*) continue ;; esac
    [ -r "$f" ] && files+=("$f")
  done
  [ "${#files[@]}" -ge 2 ] || return 0
  rows=$(_pur_fields "${files[@]}")
  rankable=$(awk -F'\t' -v hon="${HOTFIX_ON:-1}" '$2 ~ /^[0-9]+$/ && !(hon == 1 && $4 == 1) {n++} END {print n + 0}' <<<"$rows")
  [ "$rankable" -ge 2 ] || return 0

  local page=1 got=0 out code body len status=truncated tmp t0 t1 t2 issues
  mkdir -p "$PDIR" 2>/dev/null || return 0
  tmp="$PDIR/unblock-rank.listing.$$"
  : > "$tmp" || return 0
  command -v pool_slug_token_arm >/dev/null 2>&1 && pool_slug_token_arm
  t0=$(date +%s%N)
  while [ "$page" -le "$max" ]; do
    # bin/fly-pool.sh keeps each 200 page for its hold cache (one listing per
    # tick); without that reader, the plain REST read.
    if command -v pool_ai_listing_page >/dev/null 2>&1; then pool_ai_listing_page "$page"; out=$_PAL_OUT
    else out=$(pool_rest_read "repos/$POOL_SLUG/issues?state=open&labels=ai-build&per_page=100&page=$page" "${POOL_SLUG_TOK:-}"); fi
    code=${out%%$'\n'*}
    case "$out" in *$'\n'*) body=${out#*$'\n'} ;; *) body="" ;; esac
    if [ "$code" != 200 ]; then
      say "unblock rank $P: off (listing unreadable: ${code:-none}) — age order"
      rm -f -- "$tmp"; return 0
    fi
    if ! len=$(jq -e 'if type == "array" then length else error("not an array") end' <<<"$body" 2>/dev/null); then
      say "unblock rank $P: off (listing unreadable: body) — age order"
      rm -f -- "$tmp"; return 0
    fi
    printf '%s\n' "$body" >> "$tmp"
    got=$page
    [ "$len" -ge 100 ] || { status=ok; break; }
    page=$((page + 1))
  done
  t1=$(date +%s%N)
  issues=$(jq -n '[inputs | .[] | select(type == "object" and .pull_request == null)] | length' "$tmp" 2>/dev/null)
  if ! pur_edges < "$tmp" | pur_counts > "$tmp.tsv" || ! [ -n "$issues" ]; then
    say "unblock rank $P: off (listing unreadable: parse) — age order"
    rm -f -- "$tmp" "$tmp.tsv"; return 0
  fi
  mv -f -- "$tmp.tsv" "$PDIR/unblock-rank.tsv" || { rm -f -- "$tmp" "$tmp.tsv"; return 0; }
  rm -f -- "$tmp"
  t2=$(date +%s%N)
  PUR_FILE="$PDIR/unblock-rank.tsv"
  # Top 5 queued rows with a count, count desc, then age.
  local top
  top=$( { awk '{print "C\t" $0}' "$PUR_FILE"; awk '{print "R\t" $0}' <<<"$rows"; } | awk -F'\t' '
      $1 == "C" { cnt[$2] = $3; next }
      $1 == "R" { i++; if ($3 in cnt && cnt[$3] > 0) { k = $4; if (k == "") { k = $2; sub(/.*\//, "", k); sub(/\.json$/, "", k) }; print i "\t" cnt[$3] "\t" k } }' \
    | LC_ALL=C sort -t "$(printf '\t')" -k2,2nr -k1,1n | head -n 5 | awk -F'\t' '{printf "%s%s=%s", (NR > 1 ? " " : ""), $3, $2}')
  say "unblock rank $P: issues=$issues pages=$got read=$(_pur_secs "$t0" "$t1")s rank=$(_pur_secs "$t1" "$t2")s listing=$status top5: ${top:-none}"
  return 0
}

pur_order() {
  if [ -z "${PUR_FILE:-}" ] || [ ! -r "$PUR_FILE" ] || [ "$#" -lt 2 ]; then
    [ "$#" -gt 0 ] && printf '%s\n' "$@"
    return 0
  fi
  local f readable=() out
  for f in "$@"; do [ -r "$f" ] && readable+=("$f"); done
  out=$( { awk '{print "C\t" $0}' "$PUR_FILE"
           _pur_fields "${readable[@]}" | awk '{print "T\t" $0}'
           printf 'O\t%s\n' "$@"; } \
    | awk -F'\t' '
        $1 == "C" { if ($2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/) cnt[$2] = $3; next }
        $1 == "T" { tid[$2] = $3; next }
        $1 == "O" { i++; f = substr($0, 3); t = (f in tid) ? tid[f] : ""
                    c = (t != "" && (t in cnt)) ? cnt[t] : 0
                    print i "\t" c "\t" f }' \
    | LC_ALL=C sort -t "$(printf '\t')" -k2,2nr -k1,1n | cut -f3-)
  # The guard: exactly the input files, each once, or the input order.
  if [ "$(printf '%s\n' "$out" | LC_ALL=C sort)" != "$(printf '%s\n' "$@" | LC_ALL=C sort)" ]; then
    printf '%s\n' "$@"; return 0
  fi
  printf '%s\n' "$out"
}
