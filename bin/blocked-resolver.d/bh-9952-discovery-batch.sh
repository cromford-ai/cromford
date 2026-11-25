# shellcheck shell=bash
# bin/blocked-resolver.d/bh-9952-discovery-batch.sh — BH-9952: discovery at
# the hub's size. br_from_builds and br_from_rebuilds read the same answers
# with no fork per ledger row or record.
#
# WHY. On 2026-11-24 the hub's cromford pass took 1,978 s, with
# discovery_src=rebuilds:571,builds:603 while the BH-9467 cache skipped 9,419
# of 10,161 dirs and 1,158 of 1,175 records. The cost was not the file scans:
#   - bor_union (bin/lib/builds-of-record.sh) was quadratic. It is linear now,
#     and this file reads it ONCE per project per tick (bdb_union), where the
#     two sources each read it.
#   - the ledger-only loop forked ba_path, date, br_rkey and jq per row. Now:
#     one awk pass over the archive index per tick (bdb_archived), a bash
#     ISO parser (bdb_epoch), and ONE jq over every state file (bdb_state_batch).
#   - each record that br_from_rebuilds read forked jq 5-8 times. Now two:
#     the `.outcome` read (bh-9029 D4 counts it) and bdb_rec. And
#     `queue_list <p> done` is read once per project (bdb_qdone).
#   - the ledger rows whose skip depends only on the row and its state file
#     are cached in the BH-9467 builds cache file (bdb_ledger_skip/_note).
#
# SUB-TIMERS (bdb_sub). `<source>.<part>:<secs>` lines in $BDI_SRC_SECS, the
# file bdi_src_secs writes. bin/lib/br/opt/profile.sh puts them in the prof
# line's discovery_sub=, and keeps discovery_src= for the whole sources:
#   builds.union builds.ledger builds.glob rebuilds.union rebuilds.queue
#   rebuilds.walk
#
# THE LEDGER CACHE ROW. In $ST/.disc-cache-builds-<scope>.tsv (bdc_end writes
# it, bdc_begin reads it; the row shape is the dir rows' shape):
#   ledger:<project>/<build_dir>\t<updated_at>|<state mtime:size or ->\tskip\t<epoch>
# Only two decisions are noted, both stable for one signature: the state says
# rebuild_seen, or its last ladder attempt is at or after the record. The time
# floors (5,400 s, 21,600 s) and every emitted row are read again next tick.
#
# Every function here is called from bin/lib/br/discovery.sh behind a
# `command -v` test. BR_OPT_OFF=bh-9952-discovery-batch does not source this
# file: the sources then take their per-row reads as before (same rows).

# bdb_sub <name> <secs> — one sub-timer line for the prof line.
bdb_sub() {
  [ -n "${BDI_SRC_SECS:-}" ] || return 0
  printf '%s:%s\n' "$1" "${2:-0}" >> "$BDI_SRC_SECS" 2>/dev/null
  return 0
}

# bdb_epoch <iso> — the epoch of an ISO time into $_BDB_EP, rc 0. Pure bash for
# YYYY-MM-DD[T ]HH:MM:SS[.frac][Z] (UTC, the feed's and the attempts' shape),
# with the month length and leap years checked. Any other shape asks
# `date -u -d`, so the answer is always date's answer. rc 1: date cannot read it,
# or the stamp is empty (GNU date -d "" answers today's 00:00Z with rc 0).
bdb_epoch() {
  local v="${1-}" y m d hh mm ss md era yoe doy doe
  _BDB_EP=""
  if [[ "$v" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})[T\ ]([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?Z?$ ]]; then
    y=$((10#${BASH_REMATCH[1]})); m=$((10#${BASH_REMATCH[2]})); d=$((10#${BASH_REMATCH[3]}))
    hh=$((10#${BASH_REMATCH[4]})); mm=$((10#${BASH_REMATCH[5]})); ss=$((10#${BASH_REMATCH[6]}))
    case "$m" in 1|3|5|7|8|10|12) md=31 ;; 4|6|9|11) md=30 ;; 2) md=28
      if (( (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 )); then md=29; fi ;; *) md=0 ;; esac
    if [ "$y" -ge 1970 ] && [ "$md" -gt 0 ] && [ "$d" -ge 1 ] && [ "$d" -le "$md" ] \
       && [ "$hh" -le 23 ] && [ "$mm" -le 59 ] && [ "$ss" -le 59 ]; then
      # days_from_civil (H. Hinnant), y >= 1970 so era is never negative.
      (( m <= 2 )) && y=$((y - 1))
      era=$((y / 400)); yoe=$((y - era * 400))
      doy=$(( (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1 ))
      doe=$(( yoe * 365 + yoe / 4 - yoe / 100 + doy ))
      _BDB_EP=$(( (era * 146097 + doe - 719468) * 86400 + hh * 3600 + mm * 60 + ss ))
      return 0
    fi
  fi
  [ -n "$v" ] || return 1
  _BDB_EP=$(date -u -d "$v" +%s 2>/dev/null) || { _BDB_EP=""; return 1; }
  return 0
}

# bdb_union <project> — bor_union's stdout into $_BDB_U and its rc, read once
# per project per tick. The sources run in one $(br_candidates) subshell, so
# the memo lives exactly one tick.
bdb_union() {
  local p="$1"
  declare -gA _BDB_UNION _BDB_UNION_RC
  if [ -z "${_BDB_UNION_RC[$p]+x}" ]; then
    _BDB_UNION[$p]=$(bor_union "$p" 2>/dev/null); _BDB_UNION_RC[$p]=$?
  fi
  _BDB_U="${_BDB_UNION[$p]}"
  return "${_BDB_UNION_RC[$p]}"
}

# bdb_qdone <project> — `queue_list <project> done` into $_BDB_Q, once per
# project per tick. rc is the list's rc.
bdb_qdone() {
  local p="$1"
  declare -gA _BDB_QDONE _BDB_QDONE_RC
  if [ -z "${_BDB_QDONE_RC[$p]+x}" ]; then
    _BDB_QDONE[$p]=$(queue_list "$p" done 2>/dev/null); _BDB_QDONE_RC[$p]=$?
  fi
  _BDB_Q="${_BDB_QDONE[$p]}"
  return "${_BDB_QDONE_RC[$p]}"
}

# bdb_archived <build_dir> — rc 0 when ba_path "$H" <build_dir> would answer
# rc 0 (bin/lib/build-archive.sh): an index row for the name or its pool-/fly-
# form, not MOVE_FAILED, whose dir exists. ONE awk pass over the index per
# tick; the [ -d ] check stays per call, as in ba_path.
bdb_archived() {
  local n="$1" a r root
  if [ "${_BDB_ARCH_LOADED:-0}" != 1 ]; then
    declare -gA _BDB_ARCH=()
    _BDB_ARCH_LOADED=1
    local idx="$H/builds-archive/index.tsv" line k
    if [ -r "$idx" ]; then
      while IFS= read -r line; do
        k="${line%%$'\t'*}"; r="${line#*$'\t'}"
        [ -n "$k" ] && [ -n "$r" ] && _BDB_ARCH[$k]+="$r"$'\n'
      done < <(awk -F'\t' '/^#/ || NF < 7 || $7 == "MOVE_FAILED" { next } { print $2 "\t" $3 }' "$idx" 2>/dev/null)
    fi
  fi
  root="$H/builds-archive"
  for a in "$n" "pool-$n" "fly-$n"; do
    [ -n "${_BDB_ARCH[$a]+x}" ] || continue
    while IFS= read -r r; do
      [ -n "$r" ] && [ -d "$root/$r" ] && return 0
    done <<<"${_BDB_ARCH[$a]}"
  done
  return 2
}

# bdb_ledger_sig <project> <state file> <updated_at> — the ledger row's cache
# signature into $_BDB_SIG: `<updated_at>|<state mtime:size or ->`. ONE find of
# $ST/<project> per project per tick.
bdb_ledger_sig() {
  local p="$1" f="$2" u="$3" pth m
  declare -gA _BDB_STSIG _BDB_STSIG_P
  if [ -z "${_BDB_STSIG_P[$p]+x}" ]; then
    _BDB_STSIG_P[$p]=1
    if [ -d "$ST/$p" ]; then
      while IFS=$'\t' read -r pth m; do
        [ -n "$pth" ] && _BDB_STSIG[$pth]="$m"
      done < <(find "$ST/$p" -mindepth 1 -maxdepth 1 -name '*.json' -type f -printf '%p\t%T@:%s\n' 2>/dev/null)
    fi
  fi
  _BDB_SIG="$u|${_BDB_STSIG[$f]:--}"
}

# bdb_ledger_skip <key> <sig> — rc 0 when the last tick noted this ledger row
# as a skip under the same signature: carried forward and counted as skipped.
bdb_ledger_skip() {
  [ "${_BDC_ON:-0}" = 1 ] || return 1
  local k="$1" s="$2" old
  _BDC_D=$((_BDC_D+1))
  old="${_BDC_OLD["$k"]:-}"
  [ -n "$old" ] || return 1
  [ "${old%%$'\t'*}" = "$s" ] || return 1
  case "$old" in *$'\t'skip$'\t'*) ;; *) return 1 ;; esac
  _BDC_NEW["$k"]="$old"
  _BDC_H=$((_BDC_H+1))
  return 0
}

# bdb_ledger_note <key> <sig> — a stable skip, written at bdc_end.
bdb_ledger_note() {
  [ "${_BDC_ON:-0}" = 1 ] || return 0
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 0
  _BDC_NEW["$1"]="$2	skip	$EPOCHSECONDS"
  return 0
}

# bdb_state_batch <array of "file<TAB>bdir"> — ONE jq over every state file
# for the filter above. $_BDB_ST["file<TAB>bdir"] holds what the per-row jq
# printed. A pair with no entry failed (the caller fails closed, as before).
# A parse error stops jq at that file, so a pair the batch did not answer, or
# answered with more than one line, is asked alone with the old command.
bdb_state_batch() {
  local -n _bdb_pairs="$1"
  local pr f b out line k
  # The per-row state filter of br_from_builds, unchanged: is <bdir> (or its
  # pool-/fly- form) in rebuild_seen, and the .at of the last ladder attempt.
  local q='[
  ((.rebuild_seen // []) | any(. == $b or . == ("pool-" + $b) or . == ("fly-" + $b))),
  ([.attempts[]? | select((.action // "") | . != "held" and . != "stalled" and . != "stall-cleared" and (startswith("hold-") | not))] | last | (.at // ""))
] | @tsv'
  local -a files=() args=()
  local -A seenf=() cnt=() val=()
  declare -gA _BDB_ST=()
  [ "${#_bdb_pairs[@]}" -gt 0 ] || return 0
  for pr in "${_bdb_pairs[@]}"; do
    f="${pr%%$'\t'*}"; b="${pr#*$'\t'}"
    [ -n "${seenf[$f]+x}" ] || { seenf[$f]=1; files+=("$f"); }
    args+=("$f" "$b")
  done
  # The filter's $b comes from the positional pairs (file, bdir, file, bdir...).
  # `rebuild_seen` and `input_filename` in argv are what a fork counter reads.
  # jq stops at a file that does not parse: that file is asked alone below, and
  # the batch runs again on the files after it (one more jq per such file).
  local -a todo=("${files[@]}") rest=()
  local -A got=()
  local hit
  while [ "${#todo[@]}" -gt 0 ]; do
    out=$(jq -r '
      input_filename as $f
      | ($ARGS.positional) as $a
      | [range(0; $a | length; 2) | select($a[.] == $f) | $a[. + 1]] as $bs
      | $bs[] as $b
      | (try ('"$q"') catch "\u0001ERR") as $v
      | [$f, $b, $v] | join("\u0001")
    ' "${todo[@]}" --args "${args[@]}" 2>/dev/null)
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      f="${line%%$'\x01'*}"; line="${line#*$'\x01'}"
      k="$f"$'\t'"${line%%$'\x01'*}"; line="${line#*$'\x01'}"
      got[$f]=1
      cnt[$k]=$(( ${cnt[$k]:-0} + 1 ))
      val[$k]="$line"
    done <<<"$out"
    # The first file with no answer stopped the batch (or holds no JSON value).
    rest=(); hit=0
    for f in "${todo[@]}"; do
      if [ "$hit" = 0 ]; then [ -n "${got[$f]+x}" ] || hit=1; continue; fi
      [ -n "${got[$f]+x}" ] || rest+=("$f")
    done
    todo=(${rest[@]+"${rest[@]}"})
  done
  for pr in "${_bdb_pairs[@]}"; do
    if [ "${cnt[$pr]:-0}" = 1 ] && [ "${val[$pr]}" != $'\x01ERR' ]; then
      _BDB_ST[$pr]="${val[$pr]}"
    elif [ "${cnt[$pr]:-0}" = 0 ] || [ "${cnt[$pr]:-0}" -gt 1 ]; then
      f="${pr%%$'\t'*}"; b="${pr#*$'\t'}"
      out=$(jq -r --arg b "$b" "$q" "$f" 2>/dev/null) && _BDB_ST[$pr]="$out"
    fi
  done
  return 0
}

# bdb_rec <record text> — the fields br_from_rebuilds reads from one record
# after its outcome, in ONE jq: _BDB_R_LAST _BDB_R_AT _BDB_R_URL _BDB_R_PREC
# _BDB_R_SEEN _BDB_R_NH _BDB_R_WJ, each what its old per-field jq printed (a
# field whose filter fails is empty, as its own jq's output was). rc 1 when
# the text is not one JSON value, or a field holds a newline: the caller then
# takes the old per-field reads, so the answer is never different.
bdb_rec() {
  local out
  _BDB_R_LAST=""; _BDB_R_AT=""; _BDB_R_URL=""; _BDB_R_PREC=""
  _BDB_R_SEEN=""; _BDB_R_NH=""; _BDB_R_WJ=""
  out=$(jq -r '
    def la: [.attempts[]? | select((.action // "") | . != "held" and . != "stalled" and . != "stall-cleared" and (startswith("hold-") | not) and (startswith("data-lane") | not) and . != "escalate-data-lane")] | last;
    def s(f): (try (f | if type == "string" then . else tojson end) catch "");
    [ s(la | (.action // "")), s(la | (.at // "")),
      s(.parked_url // "-"), s(.parked_rec // "-"),
      s((.rebuild_seen // []) | join(" ")), s(.nh_placed // ""), s(.wait_job // "") ]
    | join("\u0001")' <<<"$1" 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  case "$out" in *$'\n'*) return 1 ;; esac
  IFS=$'\x01' read -r _BDB_R_LAST _BDB_R_AT _BDB_R_URL _BDB_R_PREC _BDB_R_SEEN _BDB_R_NH _BDB_R_WJ <<<"$out"
  return 0
}
