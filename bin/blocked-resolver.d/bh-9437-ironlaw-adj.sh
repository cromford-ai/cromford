# shellcheck shell=bash
# bin/blocked-resolver.d/bh-9437-ironlaw-adj.sh — reason iron-law goes to
# adjudication only, never to a fix round; a ruling binds to the head it read;
# a moved head gets a new scan, not a fix round (BH-9437 item 5; project-4#2205
# ran 156 fix rounds after one ACCEPT). Sourced by the driver's
# blocked-resolver.d block; functions only, no exit.
#
# Record field `.ila_ruled` on the rkey record: one row {head, verdict, url, at}
# per iron-law ruling, written by br_adjudicate (brlad_ila_rule_mark) on the
# head it read BEFORE the diff. br_record keeps no head on an adjudicate row,
# so the rulings are their own field. Bounded by BR_ILA_ADJ_MAX (rows past it
# are never bought), and it retires with the record.
# Knob: BR_ILA_ADJ_MAX (catalog/lanes.d/blocked-resolver.knobs.d/
# BR_ILA_ADJ_MAX.json), default 3: adjudicated heads per record before the
# ticket is rebuilt fresh.

# brlad_ila_max — the knob, read once per call site.
brlad_ila_max() {
  # BR_ILA_ADJ_MAX: catalog/lanes.d/blocked-resolver.knobs.d/BR_ILA_ADJ_MAX.json (fallback 3)
  brlad_knob BR_ILA_ADJ_MAX "${BR_ILA_ADJ_MAX:-3}" 3 1 10
}

# brlad_ila_ruled <record-json> — `head<TAB>verdict<TAB>src` per iron-law
#   ruling; src is `model` or `carried` (no model call was made).
brlad_ila_ruled() {
  printf '%s' "${1:-}" | jq -r '(.ila_ruled // [])[] | [(.head // ""), (.verdict // ""), (.src // "model")] | @tsv' 2>/dev/null
}

# brlad_ila_paid <record-json> — how many heads a model ruled on (the cap's count).
brlad_ila_paid() {
  brlad_ila_ruled "$1" | awk -F'\t' '$1 != "" && $3 != "carried" {print $1}' | sort -u | grep -c .
}

# brlad_ila_rule_mark <p> <rkey> <url> <head> <verdict> [carried] — store one ruling.
brlad_ila_rule_mark() {
  local h
  h=$(printf '%s' "${4:-}" | tr 'A-F' 'a-f')
  [ -n "$h" ] && [ -n "${5:-}" ] || return 0
  # shellcheck disable=SC2016  # $h $v $u $t are jq variables
  br_json_edit "$1" "$2" '.ila_ruled = (((.ila_ruled // []) | map(select(.head != $h))) + [{head:$h, verdict:$v, url:$u, at:$t, src:$s}])' \
    --arg h "$h" --arg v "$5" --arg u "${3:--}" --arg t "$(STAMP)" --arg s "${6:-model}" \
    || say "$1/$2 [iron-law]: the $5 ruling on ${h:0:8} could not be written to $(br_file "$1" "$2") — the next tick re-reads it as unruled (BH-9437)"
  return 0
}

# brlad_ila_head_n <p> <rkey> <url> <record-json> <n> — the adjudication count
#   for THIS head, in BRLAD_N. Called by br_adjudicate for iron-law only.
#   BRLAD_N=0 buys one adjudication for a moved head whose hits changed; every
#   other answer keeps n (the head was ruled, the ruled heads are at the cap,
#   the head or the diff is unreadable, the scan cannot decide, or the hits
#   were already accepted — then an ACCEPT is carried onto the new head with
#   no model call). Always rc 0.
brlad_ila_head_n() {
  local p="$1" rkey="$2" url="$3" st="$4" n="$5" cur ruled nr max slug num df hf cnt cov crc
  BRLAD_N="$n"
  [ "${n:-0}" -ge 1 ] 2>/dev/null || return 0
  cur=$(br_pr_field "$url" .head.sha 'head sha' 2>/dev/null | tr 'A-F' 'a-f')
  [ -n "$cur" ] || return 0
  ruled=$(brlad_ila_ruled "$st")
  printf '%s\n' "$ruled" | cut -f1 | grep -qxF "$cur" && return 0
  nr=$(brlad_ila_paid "$st")
  max=$(brlad_ila_max)
  [ "$nr" -ge "$max" ] && return 0
  # THE NEW SCAN: the hits on this head, against the hits already accepted.
  slug=$(br_slug_of_url "$url") || return 0
  num=$(mc_num_of_url "$url"); [ -n "$num" ] || return 0
  command -v ilc_hits >/dev/null 2>&1 && command -v ilc_covered >/dev/null 2>&1 || return 0
  df=$(mktemp) || return 0
  if ! gh_rest GET "repos/$slug/pulls/$num" -H "Accept: application/vnd.github.v3.diff" > "$df" 2>/dev/null; then
    rm -f "$df"
    say "$p/$rkey [iron-law]: the diff of the moved head ${cur:0:8} is unreadable — held, no fix round, retried next tick (BH-9437)"
    return 0
  fi
  hf=$(mktemp) || { rm -f "$df"; return 0; }
  if ! ilc_hits "$df" > "$hf" 2>/dev/null; then
    rm -f "$df" "$hf"
    say "$p/$rkey [iron-law]: the hits of the moved head ${cur:0:8} could not be fingerprinted — held, no fix round (BH-9437)"
    return 0
  fi
  cnt=$(grep -c . "$hf"); rm -f "$hf"
  cov=$(ilc_covered "$url" "$cnt" "$df" 2>/dev/null); crc=$?
  rm -f "$df"
  case "$crc" in
    0) if command -v ila_put >/dev/null 2>&1 && ila_put "$url" "$cur" resolver "carried: same hits as an adjudicated head (BH-9437)"; then
         brlad_ila_rule_mark "$p" "$rkey" "$url" "$cur" ACCEPT carried
         say "$p/$rkey [iron-law]: the moved head ${cur:0:8} carries only hits already accepted — ACCEPT carried, no model call, no fix round (BH-9437)"
       else
         say "$p/$rkey [iron-law]: the moved head ${cur:0:8} carries only accepted hits, but the DB accept did not write — retried next tick, no fix round (BH-9437)"
       fi ;;
    1) BRLAD_N=0
       say "$p/$rkey [iron-law]: the moved head ${cur:0:8} has a new or changed hit ($(head -1 <<<"$cov")) — one adjudication of that head (BH-9437)" ;;
    *) say "$p/$rkey [iron-law]: the scan of the moved head ${cur:0:8} cannot decide ($(head -1 <<<"$cov")) — held, no fix round (BH-9437)" ;;
  esac
  return 0
}

# brlad_ila_no_fix <p> <rkey> <reason> <url> <rec> <ticket-key> — the guard at
#   the top of br_fix_round. rc 1 for every reason but iron-law (today's
#   path); for iron-law the hold runs instead of a round, rc 0.
brlad_ila_no_fix() {
  [ "${3:-}" = iron-law ] || return 1
  brlad_ila_hold "$@"
  return 0
}

# brlad_ila_hold <p> <rkey> <reason> <url> <rec> <ticket-key> — what an
#   iron-law park does instead of a fix round, read off the ruling on the
#   CURRENT head: an ACCEPT is written again (idempotent, no model); a REJECT
#   is carried to the next build as a ruling note and the ticket is rebuilt;
#   no ruling and the ruled heads at BR_ILA_ADJ_MAX rebuilds; else it holds.
brlad_ila_hold() {
  local p="$1" rkey="$2" reason="$3" url="$4" rec="$5" tkey="${6:--}" cur st v nr max adj
  cur=$(br_pr_field "$url" .head.sha 'head sha' 2>/dev/null | tr 'A-F' 'a-f')
  if [ -z "$cur" ]; then
    say "$p/$rkey [iron-law]: the PR head could not be read — held, no fix round (BH-9437)"
    return 0
  fi
  st=$(br_load "$p" "$rkey")
  v=$(brlad_ila_ruled "$st" | awk -F'\t' -v h="$cur" '$1 == h {v = $2} END {print v}')
  case "$v" in
    ACCEPT)
      if command -v ila_put >/dev/null 2>&1 && ila_put "$url" "$cur" resolver "adjudicated ACCEPT"; then
        say "$p/$rkey [iron-law]: ACCEPT stands on ${cur:0:8} and the DB accept is written; no fix round (BH-9437)"
      else
        say "$p/$rkey [iron-law]: ACCEPT stands on ${cur:0:8}, the DB accept did not write — retried next tick; no fix round (BH-9437)"
      fi
      br_quiet ila-accepted
      return 0 ;;
    REJECT)
      if [ -n "$tkey" ] && [ "$tkey" != "-" ]; then
        adj="$ST/$p/$rkey.adjudication-run.txt"
        mkdir -p "$NOTES/$p" 2>/dev/null
        printf 'ADJUDICATED REJECT by bin/blocked-resolver.sh on %s: the iron-law gate was right about %s at %s. The flagged change is REJECTED; do not make it again. RULING: %s\n' \
          "$(STAMP)" "${url:--}" "${cur:0:12}" "$(grep -vE '^[[:space:]]*(ACCEPT|REJECT)[[:space:]]*$' "$adj" 2>/dev/null | tail -20 | tr '\n' ' ' | head -c 900)" > "$NOTES/$p/$tkey.md"
        command -v bn_put >/dev/null 2>&1 && ! bn_put "$p" "$tkey" "$NOTES/$p/$tkey.md" \
          && say "$p/$rkey [iron-law]: the REJECT note is NOT in the DB — only hub/pool builds will see it"
      fi
      say "$p/$rkey [iron-law]: REJECT stands on ${cur:0:8} — the ruling is carried to a fresh build; no fix round (BH-9437)"
      br_rebuild_fresh "$p" "$rkey" "$reason" "$url" "$rec" "$tkey"
      return 0 ;;
  esac
  nr=$(brlad_ila_paid "$st")
  max=$(brlad_ila_max)
  if [ "$nr" -ge "$max" ]; then
    say "$p/$rkey [iron-law]: $nr head(s) already adjudicated (BR_ILA_ADJ_MAX=$max) and ${cur:0:8} is not ruled — rebuilt fresh, no fix round (BH-9437)"
    br_rebuild_fresh "$p" "$rkey" "$reason" "$url" "$rec" "$tkey"
    return 0
  fi
  say "$p/$rkey [iron-law]: head ${cur:0:8} was not ruled; the conductor's scan and carry decide; no fix round (BH-9437)"
  br_quiet ila-unruled
  return 0
}
