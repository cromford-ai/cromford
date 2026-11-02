#!/bin/bash
# bin/lib/box-move/isolation.sh — `bin/box-move.sh isolation` (BH-8325,
# MKF-10): the isolation drill. The old Orgo computer stays stopped for a
# window, and the counters below prove nothing on the hub still needs it.
# Sourced by bin/box-move.sh after common.sh, cutover.sh (bm_now,
# bm_step_record, bm_step_status, bm_rows_load) and proof.sh (bm_pw_*). The
# runbook is docs/notes/2026-11-02-BH-8325-MKF-10-isolation.md.
#
#   bm_iso_stop <confirm> <oldbox> <newbox>        (isolation --step I1)
#       Preconditions (bm_refuse, exit 3, nothing done): the last B5 row is
#       ok, old-rows.tsv loads, the rows put no project on <oldbox>, and
#       target.json has ts_ip. Without --confirm: a WOULD RUN line and the
#       bin/box-ops.sh stop dry run. With it: bm_iso_baseline, then
#       `bin/box-ops.sh stop <box id> --host <oldbox> --apply`, then an
#       `I1 ok` row in steps.tsv. box-ops rc != 0, or a last line with no
#       result=OK, records `I1 fail` and exits 4. A re-run starts a new drill.
#   bm_iso_report <oldbox> <newbox>                 (isolation)
#       The drill report, on stdout and in
#       $BM_STATE/isolation-report-<YYYYmmddTHHMMSSZ of bm_now>.txt. rc 0;
#       exit 4 only when the report file cannot be written.
#
# isolation-baseline.tsv: line 1 `# since=<iso> epoch=<n> old_ip=<addr>`,
# then one line per regular file under $HARNESS/logs:
# `<inode>\t<size>\t<cksum of the first min(size,512) bytes>\t<path under logs/>`.
#
# Counters. T0 = the baseline epoch, W = BM_ISO_WINDOW_S, the window is
# [T0, T0+W). A value that was not measured is NA(<why>), never 0.
#   old_ip_lines  every file under $HARNESS/logs with mtime >= T0. A file in
#                 the baseline (same inode, not smaller, same head cksum) is
#                 read after its baseline size; any other file is read whole
#                 (zcat -f), and a line stamped before T0 is dropped. A line
#                 counts when it holds the old address with no digit or dot
#                 before it and no digit after it. It covers T0 to now, so the
#                 72 h verdict and retire_ready read the same count. Pass at 0
#                 only; a fail is final, so it shows while the window runs.
#   pull_spawns_result  `[pool/<p>] <MID>: seeded <n> file(s) for <KEY> at
#                 launch` in the window in the hub logs/fly-pool.log, paired
#                 with a later `[pool/<p>] reaped <KEY> from <MID>: ` line.
#                 Distinct (MID, KEY) pairs.
#   lead_reviews  `[pool/<p>] pool lead review reaped for LR-` (as proof.sh).
#   conductor_merges  bm_pw_merges over the window (merged PRs of the repo).
#   triage_dispatches  `[<p>] dispatched <N> shards:` with N >= 1 in
#                 logs/<p>.log on the new box, over ssh.
#   fix_rounds    bm_pw_fix_load + bm_pw_fix_count over the window.
#   tailnet_ip    bin/fleet-conf.sh --tailnet-ip <p> must equal target.json ts_ip.
#   tracked_old_ip  git grep of origin/main in $BM_CHECKOUT (no fetch); a
#                 path under BM_ISO_IP_ALLOW is skipped. Pass at 0 files.
# While the window runs, every count line is NA except a failed
# old_ip_lines. isolation verdict: fail if a line fails, else NA if a line
# is NA or the window runs, else pass. retire_ready=yes needs verdict pass,
# now - T0 >= BM_RETIRE_CLEAN_S and old_ip_lines 0. This file never calls
# the Orgo delete: the report prints the command for the operator.

BM_ISO_STAMP_RE='^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$'
# The head bytes the baseline checksums: an identity check of the file (a
# reused inode has other first bytes), not a limit.
BM_ISO_HEAD_BYTES=512

# -v ip, -v s (since stamp; "" = keep every line). Prints the line count.
BM_AWK_ISO_IP='function hit(l,   i, b, a) {
  while ((i = index(l, ip)) > 0) {
    b = (i > 1) ? substr(l, i - 1, 1) : ""
    a = substr(l, i + length(ip), 1)
    if (b !~ /[0-9.]/ && a !~ /[0-9]/) return 1
    l = substr(l, i + 1)
  }
  return 0
}
s != "" {
  t = $0; sub(/^\[/, "", t); st = substr(t, 1, 20)
  if (st ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][ T][0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/) {
    st = substr(st, 1, 10) " " substr(st, 12)
    if (st < s) next
  }
}
hit($0) { n++ }
END { print n + 0 }'

# BM_S_PW_COUNT programs: -v s u p (the tag at column 22) c (unused).
BM_AWK_ISO_PULL='{ st = substr($0, 1, 20) }
st !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/ { next }
{ if (o == "" || st < o) o = st }
substr($0, 22, length(p)) != p { next }
{ r = substr($0, 22 + length(p)) }
r ~ /^[^ :]+: seeded [0-9]+ file\(s\) for [^ ]+ at launch/ {
  if (st >= s && st < u) {
    split(r, w, " "); k = substr(w[1], 1, length(w[1]) - 1) SUBSEP w[6]
    if (!(k in sd) || st < sd[k]) sd[k] = st
  }
  next
}
r ~ /^reaped [^ ]+ from [^ :]+: / {
  split(r, w, " "); m = w[4]; sub(/:$/, "", m); k = m SUBSEP w[2]
  if (!(k in rp) || st > rp[k]) rp[k] = st
}
END { for (k in sd) if ((k in rp) && rp[k] >= sd[k]) n++; printf "n=%d oldest=%s\n", n, o }'
BM_AWK_ISO_DISPATCH='{ st = substr($0, 1, 20) }
st !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/ { next }
{ if (o == "" || st < o) o = st }
st >= s && st < u && substr($0, 22, length(p)) == p && substr($0, 22 + length(p)) ~ /^[1-9][0-9]* shards:/ { n++ }
END { printf "n=%d oldest=%s\n", n, o }'

bm_iso_headsum() { # <file> <size>
  local n="$2"
  [ "$n" -le "$BM_ISO_HEAD_BYTES" ] || n="$BM_ISO_HEAD_BYTES"
  head -c "$n" -- "$1" 2>/dev/null | cksum | cut -d' ' -f1
}

# bm_iso_baseline <epoch> <old ip> — write isolation-baseline.tsv (tmp + mv).
bm_iso_baseline() {
  local f="$BM_STATE/isolation-baseline.tsv" logs="$HARNESS/logs" ino sz rel
  mkdir -p "$BM_STATE" || return 1
  {
    printf '# since=%s epoch=%s old_ip=%s\n' "$(bm_pw_iso "$1")" "$1" "$2"
    if [ -d "$logs" ]; then
      while IFS=$'\t' read -r ino sz rel; do
        printf '%s\t%s\t%s\t%s\n' "$ino" "$sz" "$(bm_iso_headsum "$logs/$rel" "$sz")" "$rel"
      done < <(find "$logs" -type f -printf '%i\t%s\t%P\n' | LC_ALL=C sort -t$'\t' -k3,3)
    fi
  } > "$f.tmp" && mv -f "$f.tmp" "$f"
}

bm_iso_preflight() { # <oldbox>
  [ "$(bm_step_status B5)" = ok ] || bm_refuse "isolation I1: the last B5 row is $(bm_step_status B5 | grep . || echo absent), not ok (run the cut-over first)"
  bm_rows_load || bm_refuse "isolation I1: no usable $BM_STATE/old-rows.tsv (B2 never ran)"
  grep -qE '^[0-9A-Fa-f.:]+$' <<<"$BM_OLD_IP" || bm_refuse "isolation I1: old-rows.tsv gives a bad address '$BM_OLD_IP'"
  local left
  left=$("$BIN/fleet-conf.sh" --projects-on-box "$1" 2>/dev/null | paste -sd, -)
  [ -z "$left" ] || bm_refuse "isolation I1: the rows still put $left on $1; box-ops stop would pause them"
  [ -n "$(bm_tj_get ts_ip)" ] || bm_refuse "isolation I1: $BM_TJ has no ts_ip"
}

bm_iso_stop() {
  local confirm="$1" old="$2" out rc t0 since
  local acct=()
  [ -z "$BM_ORGO_ACCOUNT" ] || acct=(--account "$BM_ORGO_ACCOUNT")
  bm_iso_preflight "$old"
  if [ "$confirm" -eq 0 ]; then
    echo "WOULD RUN I1: write $BM_STATE/isolation-baseline.tsv (every file under $HARNESS/logs), then bin/box-ops.sh stop $BM_BOX_ID --host $old ${acct[*]} --apply, then an I1 ok row"
    "$BIN/box-ops.sh" stop "$BM_BOX_ID" --host "$old" "${acct[@]}"; rc=$?
    [ "$rc" -eq 0 ] || bm_fail "isolation I1: the box-ops dry run rc=$rc"
    echo "nothing changed: add --confirm to run"
    return 0
  fi
  t0=$(bm_now); since=$(bm_pw_iso "$t0")
  bm_iso_baseline "$t0" "$BM_OLD_IP" || bm_fail "isolation I1: cannot write $BM_STATE/isolation-baseline.tsv"
  bm_say "isolation I1: baseline since=$since old_ip=$BM_OLD_IP; stopping $old (box id $BM_BOX_ID) through box-ops"
  out=$("$BIN/box-ops.sh" stop "$BM_BOX_ID" --host "$old" "${acct[@]}" --apply 2>&1); rc=$?
  printf '%s\n' "$out"
  if [ "$rc" -ne 0 ] || ! grep -q 'result=OK' <<<"$(tail -n 1 <<<"$out")"; then
    bm_step_record I1 fail "box-ops rc=$rc"
    bm_fail "isolation I1: bin/box-ops.sh stop rc=$rc ($(tail -n 1 <<<"$out"))"
  fi
  bm_step_record I1 ok "since=$since old_ip=$BM_OLD_IP box_id=$BM_BOX_ID host=$old" \
    || bm_fail "isolation I1: $old stopped, but the I1 row was not written"
  bm_say "isolation I1: ok; run bin/box-move.sh isolation $old ${BM_NEW_NAME:-<newbox>} for the report"
}

# bm_iso_old_ip_count <T0> <ip> — ISO_IP_N (count or NA(<why>)) and
# ISO_IP_FILES (`<path>\t<n>` per file with n > 0).
bm_iso_old_ip_count() {
  local t0="$1" ip="$2" logs="$HARNESS/logs" base="$BM_STATE/isolation-baseline.tsv"
  local ino sz sum rel mt f n rc s total=0
  local -A bsz=() bsum=()
  ISO_IP_N=""; ISO_IP_FILES=""
  while IFS=$'\t' read -r ino sz sum rel; do
    case "$ino" in ''|'#'*) continue ;; esac
    bsz[$ino]="$sz"; bsum[$ino]="$sum"
  done < "$base"
  [ -d "$logs" ] || { ISO_IP_N="NA(no $logs)"; return; }
  s=$(bm_pw_stamp "$t0")
  while IFS=$'\t' read -r ino sz mt rel; do
    mt="${mt%%.*}"
    bm_is_uint "$mt" && [ "$mt" -ge "$t0" ] || continue
    f="$logs/$rel"
    if [ -n "${bsz[$ino]+x}" ] && [ "$sz" -ge "${bsz[$ino]}" ] \
        && [ "$(bm_iso_headsum "$f" "${bsz[$ino]}")" = "${bsum[$ino]}" ]; then
      n=$(set -o pipefail; tail -c +$(( ${bsz[$ino]} + 1 )) -- "$f" 2>/dev/null | LC_ALL=C awk -v ip="$ip" -v s="" "$BM_AWK_ISO_IP"); rc=$?
    else
      n=$(set -o pipefail; zcat -f -- "$f" 2>/dev/null | LC_ALL=C awk -v ip="$ip" -v s="$s" "$BM_AWK_ISO_IP"); rc=$?
    fi
    if [ "$rc" -ne 0 ] || ! bm_is_uint "$n"; then ISO_IP_N="NA(read $rel)"; return; fi
    total=$(( total + n ))
    [ "$n" -eq 0 ] || ISO_IP_FILES+="$rel"$'\t'"$n"$'\n'
  done < <(find "$logs" -type f -printf '%i\t%s\t%T@\t%P\n' | LC_ALL=C sort -t$'\t' -k4,4)
  ISO_IP_N="$total"
}

bm_iso_pull_pairs() { # <project> <since> <until>
  local out rc
  out=$(bash -c "$BM_S_PW_COUNT" pw "$HARNESS/logs/fly-pool.log" "$2" "$3" "[pool/$1] " "" "$BM_AWK_ISO_PULL" 2>/dev/null); rc=$?
  bm_pw_judge "$2" "$rc" "read rc=$rc" <<<"$out"
}
bm_iso_dispatches() { # <new ip> <project> <since> <until>
  local out rc why
  out=$(bm_sh "$1" "$BM_S_PW_COUNT" "$BM_TH/logs/$2.log" "$3" "$4" "[$2] dispatched " "" "$BM_AWK_ISO_DISPATCH" 2>/dev/null); rc=$?
  why="read rc=$rc on new box"; [ "$rc" -eq 255 ] && why="new box unreachable"
  bm_pw_judge "$3" "$rc" "$why" <<<"$out"
}

# bm_iso_tracked <ip> — ISO_TR_REF, ISO_TR_N (count or NA) and ISO_TR_FILES.
bm_iso_tracked() {
  local ip="$1" re out rc path a keep
  ISO_TR_REF="-"; ISO_TR_N=""; ISO_TR_FILES=""
  ISO_TR_REF=$(git -C "$BM_CHECKOUT" rev-parse --short=12 origin/main 2>/dev/null) \
    || { ISO_TR_REF="-"; ISO_TR_N="NA(no origin/main in $BM_CHECKOUT)"; return; }
  re="(^|[^0-9.])${ip//./\\.}(\$|[^0-9])"
  out=$(git -C "$BM_CHECKOUT" grep -lE "$re" origin/main -- 2>/dev/null); rc=$?
  case "$rc" in 0|1) ;; *) ISO_TR_N="NA(git grep rc=$rc)"; return ;; esac
  ISO_TR_N=0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    path="${path#origin/main:}"
    keep=1
    for a in $BM_ISO_IP_ALLOW; do
      case "$path" in "$a"*) keep=0 ;; esac
    done
    [ "$keep" -eq 1 ] || continue
    ISO_TR_N=$(( ISO_TR_N + 1 )); ISO_TR_FILES+="$path"$'\n'
  done <<<"$out"
}

bm_iso_tally() { case "$1" in fail) ISO_FAIL=1 ;; NA) ISO_NA=1 ;; esac; }
# bm_iso_min <n> <min> — the verdict of a count line (NA while running).
bm_iso_min() {
  [ "$ISO_RUNNING" -eq 0 ] && bm_is_uint "$1" || { echo NA; return; }
  if [ "$1" -ge "$2" ]; then echo pass; else echo fail; fi
}
bm_iso_count() { # <project> <counter> <n> <min> [extra]
  local v; v=$(bm_iso_min "$3" "$4"); bm_iso_tally "$v"
  echo "count $1 $2 n=$3 min=$4${5:+ $5} verdict=$v"
}

bm_iso_body() {
  local old="$1" f="$BM_STATE/steps.tsv" base="$BM_STATE/isolation-baseline.tsv" why="" h t0 ip det
  local now w="$BM_ISO_WINDOW_S" s u p v nip ans repo clean rv=no rwhy
  ISO_FAIL=0; ISO_NA=0; ISO_RUNNING=0
  if [ "$(bm_step_status I1)" != ok ]; then why="the last I1 row is $(bm_step_status I1 | grep . || echo absent), not ok"
  elif [ ! -s "$base" ]; then why="no $base"
  else
    h=$(head -n 1 "$base")
    t0=$(sed -n 's/^# since=[^ ]* epoch=\([0-9]*\) old_ip=.*/\1/p' <<<"$h")
    ip=$(sed -n 's/^# since=[^ ]* epoch=[0-9]* old_ip=\([0-9A-Fa-f.:]*\)$/\1/p' <<<"$h")
    det=$(awk -F'\t' '$2 == "I1" && $3 == "ok" {v = $4} END {print v}' "$f")
    if [ -z "$t0" ] || [ -z "$ip" ]; then why="a bad baseline header: $h"
    elif [[ " $det " != *" since=$(bm_pw_iso "$t0") "* ]]; then why="the baseline (since=$(bm_pw_iso "$t0")) is not the drill of the last I1 ok row ($det)"
    elif ! bm_rows_load; then why="no usable old-rows.tsv"
    fi
  fi
  if [ -n "$why" ]; then
    echo "isolation: none ($why)"
    echo "isolation verdict=NA"
    echo "retire_ready=no (no drill)"
    return 0
  fi
  now=$(bm_now)
  [ "$now" -ge $(( t0 + w )) ] || ISO_RUNNING=1
  s=$(bm_pw_stamp "$t0"); u=$(bm_pw_stamp $(( t0 + w )))
  nip=$(bm_tj_get ts_ip)
  echo "isolation since=$(bm_pw_iso "$t0") until=$(bm_pw_iso $(( t0 + w ))) elapsed_s=$(( now - t0 )) window_s=$w state=$([ "$ISO_RUNNING" -eq 1 ] && echo running || echo complete) old_box=$old box_id=$BM_BOX_ID"

  bm_iso_old_ip_count "$t0" "$ip"
  if ! bm_is_uint "$ISO_IP_N"; then v=NA
  elif [ "$ISO_IP_N" -gt 0 ]; then v=fail
  elif [ "$ISO_RUNNING" -eq 1 ]; then v=NA
  else v=pass; fi
  bm_iso_tally "$v"
  echo "count old_ip_lines n=$ISO_IP_N files=$(grep -c . <<<"$ISO_IP_FILES") verdict=$v"
  [ -z "$ISO_IP_FILES" ] || printf '%s' "$ISO_IP_FILES" | awk -F'\t' '{print "old_ip_file " $1 " n=" $2}'

  for p in ${BM_ISO_PROJECTS:-$BM_PROJECTS}; do
    bm_iso_count "$p" pull_spawns_result "$(bm_iso_pull_pairs "$p" "$s" "$u")" "$BM_ISO_MIN_PULL"
    bm_iso_count "$p" lead_reviews \
      "$(bm_pw_hub "$HARNESS/logs/fly-pool.log" "$s" "$u" "[pool/$p] pool lead review reaped for LR-")" "$BM_ISO_MIN_EACH"
    repo=$("$BIN/fleet-conf.sh" "$p" repo 2>/dev/null)
    if [ -n "$repo" ]; then bm_pw_merges "$repo" "$t0" $(( t0 + w ))
    else PW_MERGES="NA(no repo)"; PW_MERGIFY="$PW_MERGES"; fi
    bm_iso_count "$p" conductor_merges "$PW_MERGES" "$BM_ISO_MIN_EACH" "mergify=$PW_MERGIFY"
    if [ -n "$nip" ]; then bm_iso_count "$p" triage_dispatches "$(bm_iso_dispatches "$nip" "$p" "$s" "$u")" "$BM_ISO_MIN_EACH"
    else bm_iso_count "$p" triage_dispatches "NA(no ts_ip)" "$BM_ISO_MIN_EACH"; fi
    bm_pw_fix_load "$p"
    bm_iso_count "$p" fix_rounds "$(bm_pw_fix_count "$s" "$u")" "$BM_ISO_MIN_EACH"
    ans=$("$BIN/fleet-conf.sh" --tailnet-ip "$p" 2>/dev/null) || ans=""
    if [ -z "$nip" ]; then v=NA
    elif [ -n "$ans" ] && [ "$ans" = "$nip" ]; then v=pass
    else v=fail; fi
    bm_iso_tally "$v"
    echo "tailnet_ip $p answer=${ans:-none} want=${nip:-none} verdict=$v"
  done

  bm_iso_tracked "$ip"
  if ! bm_is_uint "$ISO_TR_N"; then v=NA
  elif [ "$ISO_TR_N" -eq 0 ]; then v=pass
  else v=fail; fi
  bm_iso_tally "$v"
  echo "tracked_old_ip ref=$ISO_TR_REF files=$ISO_TR_N allow=$(tr ' ' ',' <<<"${BM_ISO_IP_ALLOW:--}") verdict=$v"
  [ -z "$ISO_TR_FILES" ] || printf '%s' "$ISO_TR_FILES" | sed 's/^/tracked_old_ip_file /'

  if [ "$ISO_FAIL" -eq 1 ]; then v=fail
  elif [ "$ISO_NA" -eq 1 ] || [ "$ISO_RUNNING" -eq 1 ]; then v=NA
  else v=pass; fi
  echo "isolation verdict=$v"
  clean=$(( now - t0 ))
  if [ "$v" != pass ]; then rwhy="isolation verdict=$v"
  elif [ "$clean" -lt "$BM_RETIRE_CLEAN_S" ]; then rwhy="clean_s $clean < $BM_RETIRE_CLEAN_S"
  elif [ "$ISO_IP_N" != 0 ]; then rwhy="old_ip_lines n=$ISO_IP_N"
  else rv=yes; fi
  echo "retire_ready=$rv${rwhy:+ ($rwhy)} clean_s=$clean need_s=$BM_RETIRE_CLEAN_S"
  [ "$rv" = yes ] && echo "NEXT (the operator runs this, never this tool): bin/box-ops.sh retire $BM_BOX_ID --host $old --delete --apply"
  return 0
}

bm_iso_report() {
  local old="$1" out f
  out=$(bm_iso_body "$old")
  printf '%s\n' "$out"
  f="$BM_STATE/isolation-report-$(date -u -d "@$(bm_now)" '+%Y%m%dT%H%M%SZ').txt"
  { mkdir -p "$BM_STATE" && printf '%s\n' "$out" > "$f.tmp" && mv -f "$f.tmp" "$f"; } 2>/dev/null \
    || bm_fail "isolation: cannot write $f"
  echo "report: $f"
}
