#!/bin/bash
# bin/defer-report.sh [--last <N>d] [--project <p>] [--top <n>] [--out <file>]
#                     [--builds <dir>] [--now <epoch>]
#
# BH-9426. Which files make builds wait. For each build dir whose RESULT starts
# with BUILD_DEFERRED it names the files that collided and the ticket that held
# them, then prints:
#   a header   window, builds, deferred, attributed, other, share
#   TOP FILES  count  total_wait_m  median_wait_m  open=<n>  path  holders=<K>(<n>),...
#              (top --top rows, default DEFER_REPORT_TOP = 20; by count, then path)
#   PER TICKET KEY  deferrals  total_wait_m  open=<n>
#
# SOURCE: $HARNESS/builds/[fly-|pool-]<project>-<KEY>-<yyyymmddhhmm[ss]>/RESULT.
# The dir stamp is the build start (UTC). The RESULT shapes this attributes to
# files are the two production writes (bin/lib/rb/gates.sh rb_gate_overlap):
#   BUILD_DEFERRED OVERLAP_DEFER <K> vs <HOLDER> files=[p,q,...]; ...
#     (bin/plan-overlap.sh / bin/plan-sibling.sh stdout)
#   BUILD_DEFERRED file overlap — CONFLICT with <holder-dir>: <p> ~ <q> — ...
#     (bin/conflict-check.sh)
# Any other BUILD_DEFERRED (slots, budget, not-before) is a deferral counted as
# `other`; it is never attributed to a file.
#
# WAIT: the stamp of the NEXT build dir of the same project and KEY minus this
# dir's stamp, in minutes. No next build = `open`: counted, not summed.
#
# LANE MODE (no --last): the window is DEFER_REPORT_WINDOW_DAYS (default 7),
# every project in the window is reported (or --project), one summary line per
# project is appended to logs/defer-report.log, and the TOP FILES paths go to
# state/defer-report/<project>-top.txt (bin/lib/defer-top.sh reads it for the
# planner prompt). The lane runs once a day (cron/lanes/718-defer-report.cron).
# A --last run is ad hoc: it prints and writes --out only when asked, never the log.
#
# --out <file>: the TOP FILES paths, one per line, written atomically (temp +
# mv). With no --project, --out is ignored (one list per project).
#
# Exit: 0 with a report (an empty builds dir reports zeros); 2 on a bad flag,
# before anything is written.
#
# Knobs (catalog/lanes.d/defer-report.json; settings rows via lane_env_apply):
#   DEFER_REPORT_WINDOW_DAYS  lane window in days (default 7)
#   DEFER_REPORT_TOP          TOP FILES rows (default 20)
#   DEFER_REPORT_ENABLED      0 stops a lane run (default 1)
set -uo pipefail
H="${HARNESS:-/root/harness}"

# >>> lane gate — one off-switch and one source of numbers for this lane.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit defer-report
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    defer-report
# <<< lane gate

usage() { echo "usage: defer-report.sh [--last <N>d] [--project <p>] [--top <n>] [--out <file>] [--builds <dir>] [--now <epoch>]" >&2; exit 2; }
LAST="" PROJ="" TOPN="" OUTF="" BUILDS="$H/builds" NOW=""
while [ $# -gt 0 ]; do
  case "$1" in
    --last)    [ $# -ge 2 ] || usage; LAST="$2"; shift 2 ;;
    --project) [ $# -ge 2 ] || usage; PROJ="$2"; shift 2 ;;
    --top)     [ $# -ge 2 ] || usage; TOPN="$2"; shift 2 ;;
    --out)     [ $# -ge 2 ] || usage; OUTF="$2"; shift 2 ;;
    --builds)  [ $# -ge 2 ] || usage; BUILDS="$2"; shift 2 ;;
    --now)     [ $# -ge 2 ] || usage; NOW="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
LANE=0
if [ -n "$LAST" ]; then
  case "$LAST" in *d) DAYS="${LAST%d}" ;; *) DAYS="$LAST" ;; esac
  case "$DAYS" in ''|*[!0-9]*|0) usage ;; esac
else
  LANE=1
  case "${DEFER_REPORT_ENABLED:-1}" in 0) exit 0 ;; esac
  DAYS="${DEFER_REPORT_WINDOW_DAYS:-7}"   # row: defer-report DEFER_REPORT_WINDOW_DAYS
  case "$DAYS" in ''|*[!0-9]*|0) DAYS=7 ;; esac
fi
TOPN="${TOPN:-${DEFER_REPORT_TOP:-20}}"   # row: defer-report DEFER_REPORT_TOP
case "$TOPN" in ''|*[!0-9]*|0) usage ;; esac
case "$NOW" in '') NOW=$(date -u +%s) ;; *[!0-9]*) usage ;; esac
SINCE=$((NOW - DAYS * 86400))

TMP=$(mktemp -d "${TMPDIR:-/tmp}/defer-report-XXXXXX") || exit 0
trap 'rm -rf "$TMP"' EXIT

# --- 1. every build dir: <epoch> <project> <key> <dir> ------------------------
NAME_RE='^(fly-|pool-)?([a-z0-9][a-z0-9.-]*)-([A-Z][A-Za-z0-9]*-[0-9][A-Za-z0-9.-]*)-([0-9]{12}|[0-9]{14})$'
: > "$TMP/names"
for d in "$BUILDS"/*/; do
  [ -d "$d" ] || continue
  n=$(basename "$d")
  [[ $n =~ $NAME_RE ]] || continue
  [ -n "$PROJ" ] && [ "${BASH_REMATCH[2]}" != "$PROJ" ] && continue
  s="${BASH_REMATCH[4]}"
  printf '%s\t%s\t%s\t%s-%s-%s %s:%s:%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "$n" \
    "${s:0:4}" "${s:4:2}" "${s:6:2}" "${s:8:2}" "${s:10:2}" "${s:12:2}" >> "$TMP/names"
done
# One date call for every stamp; a 12-digit stamp has an empty :ss, so fix it.
sed -E 's/:$/:00/' "$TMP/names" > "$TMP/names2"
: > "$TMP/all"
if [ -s "$TMP/names2" ]; then
  cut -f4 "$TMP/names2" | date -u -f - +%s > "$TMP/epochs" 2>/dev/null || : > "$TMP/epochs"
  if [ "$(wc -l < "$TMP/epochs")" = "$(wc -l < "$TMP/names2")" ]; then
    paste "$TMP/epochs" <(cut -f1-3 "$TMP/names2") | sort -k2,2 -k3,3 -k1,1n > "$TMP/all"
  fi
fi

# --- 2. classify each dir in the window ---------------------------------------
# rec: project key epoch deferred(0|1) attributed(0|1) wait(min|open) holder files(csv)
holder_key() { # holder_key <project> <dir-name> -> the KEY in a build dir name
  local n="$2"
  if [[ $n =~ $NAME_RE ]]; then printf '%s' "${BASH_REMATCH[3]}"; else printf '%s' "$n"; fi
}
: > "$TMP/rec"
PREV_PK="" PREV_EP=""
# Walk in reverse so each row knows the NEXT build of its project+key.
sort -k2,2 -k3,3 -k1,1nr "$TMP/all" > "$TMP/rev"
while IFS=$'\t' read -r ep pr key dn; do
  [ -n "$ep" ] || continue
  pk="$pr/$key"
  nxt=""; [ "$pk" = "$PREV_PK" ] && nxt="$PREV_EP"
  PREV_PK="$pk"; PREV_EP="$ep"
  [ "$ep" -ge "$SINCE" ] && [ "$ep" -le "$NOW" ] || continue
  line=""; [ -r "$BUILDS/$dn/RESULT" ] && IFS= read -r line < "$BUILDS/$dn/RESULT"
  case "$line" in BUILD_DEFERRED*) ;; *) printf '%s\t%s\t%s\t0\t0\t-\t-\t-\n' "$pr" "$key" "$ep" >> "$TMP/rec"; continue ;; esac
  holder="" files=""
  if [[ $line =~ ^BUILD_DEFERRED\ OVERLAP_DEFER\ [^\ ]+\ vs\ ([^\ ]+)\ files=\[([^]]*)\] ]]; then
    holder=${BASH_REMATCH[1]}
    files=${BASH_REMATCH[2]}
  elif [[ $line =~ ^BUILD_DEFERRED\ file\ overlap\ .*CONFLICT\ with\ ([^:\ ]+):\ ([^\ ]+)\ ~\ ([^\ ]+) ]]; then
    files="${BASH_REMATCH[2]},${BASH_REMATCH[3]}"
    holder=$(holder_key "$pr" "${BASH_REMATCH[1]}")
  fi
  wait=open
  [ -n "$nxt" ] && wait=$(( (nxt - ep) / 60 ))
  if [ -n "$files" ]; then
    files=$(printf '%s' "$files" | tr ',' '\n' | awk 'NF && !s[$0]++' | paste -sd, -)
    printf '%s\t%s\t%s\t1\t1\t%s\t%s\t%s\n' "$pr" "$key" "$ep" "$wait" "${holder:--}" "$files" >> "$TMP/rec"
  else
    printf '%s\t%s\t%s\t1\t0\t%s\t-\t-\n' "$pr" "$key" "$ep" "$wait" >> "$TMP/rec"
  fi
done < "$TMP/rev"

# --- 3. report per project ----------------------------------------------------
report() { # report <project> -> stdout; writes $TMP/top.<project> and $TMP/log.<project>
  local p="$1" oldest
  oldest=$(awk -F'\t' -v p="$p" '$2 == p && (o == "" || $1 < o) { o = $1 } END { print o }' "$TMP/all")
  awk -F'\t' -v p="$p" -v oldest="$oldest" -v topn="$TOPN" -v days="$DAYS" -v since="$SINCE" -v now="$NOW" \
      -v topf="$TMP/top.$p" -v logf="$TMP/log.$p" '
    function iso(t) { return strftime("%Y-%m-%dT%H:%MZ", t, 1) }
    $1 != p { next }
    {
      builds++
      if ($4 != 1) next
      deferred++
      k = $2; tdef[k]++
      if ($6 == "open") topen[k]++; else twait[k] += $6
      if ($5 != 1) { other++; next }
      attributed++
      n = split($8, fl, ",")
      for (i = 1; i <= n; i++) {
        f = fl[i]; fc[f]++
        if ($6 == "open") fo[f]++; else { fw[f] += $6; fwn[f]++; fwl[f, fwn[f]] = $6 }
        fh[f, $7]++; if (!((f, $7) in seenh)) { seenh[f, $7] = 1; fhl[f] = fhl[f] SUBSEP $7 }
      }
    }
    END {
      share = builds ? 100 * deferred / builds : 0
      printf "defer-report: project=%s window=%dd since=%s now=%s\n", p, days, iso(since), iso(now)
      printf "builds=%d deferred=%d attributed=%d other=%d share=%.1f%%\n", builds, deferred, attributed, other, share
      if (oldest != "" && oldest - since > 86400)
        printf "note: window truncated: the oldest %s build dir is %s, %d h after the window start (no older build dir exists: a new project, or builds-retention removed them)\n", p, iso(oldest), (oldest - since) / 3600
      print "TOP FILES  count  total_wait_m  median_wait_m  open  path  holders"
      m = 0; for (f in fc) keys[++m] = f
      # sort: count desc, then path asc (insertion sort; the list is small)
      for (i = 2; i <= m; i++) { x = keys[i]; j = i - 1
        while (j > 0 && (fc[keys[j]] < fc[x] || (fc[keys[j]] == fc[x] && keys[j] > x))) { keys[j + 1] = keys[j]; j-- }
        keys[j + 1] = x }
      top1 = ""
      for (i = 1; i <= m && i <= topn; i++) {
        f = keys[i]
        # median of the measured waits
        c = fwn[f]; med = "-"
        if (c > 0) {
          for (a = 1; a <= c; a++) w[a] = fwl[f, a]
          for (a = 2; a <= c; a++) { x = w[a]; b = a - 1; while (b > 0 && w[b] > x) { w[b + 1] = w[b]; b-- } w[b + 1] = x }
          med = (c % 2) ? w[(c + 1) / 2] : int((w[c / 2] + w[c / 2 + 1]) / 2)
        }
        # holders, most first, top 3
        hn = split(substr(fhl[f], 2), hs, SUBSEP)
        for (a = 2; a <= hn; a++) { x = hs[a]; b = a - 1
          while (b > 0 && (fh[f, hs[b]] < fh[f, x] || (fh[f, hs[b]] == fh[f, x] && hs[b] > x))) { hs[b + 1] = hs[b]; b-- }
          hs[b + 1] = x }
        hl = ""; for (a = 1; a <= hn && a <= 3; a++) hl = hl (a > 1 ? "," : "") hs[a] "(" fh[f, hs[a]] ")"
        printf "%d  %d  %s  open=%d  %s  holders=%s\n", fc[f], fw[f], med, fo[f], f, hl
        print f > topf
        if (top1 == "") top1 = f "(" fc[f] ")"
      }
      print "PER TICKET  key  deferrals  total_wait_m  open"
      m = 0; for (k in tdef) tk[++m] = k
      for (i = 2; i <= m; i++) { x = tk[i]; j = i - 1
        while (j > 0 && (tdef[tk[j]] < tdef[x] || (tdef[tk[j]] == tdef[x] && tk[j] > x))) { tk[j + 1] = tk[j]; j-- }
        tk[j + 1] = x }
      for (i = 1; i <= m; i++) printf "%s %d %d open=%d\n", tk[i], tdef[tk[i]], twait[tk[i]], topen[tk[i]]
      printf "project=%s window=%dd builds=%d deferred=%d attributed=%d other=%d share=%.1f%% top=%s\n", \
        p, days, builds, deferred, attributed, other, share, (top1 == "" ? "-" : top1) > logf
    }' "$TMP/rec"
}
write_atomic() { # write_atomic <src> <dst>
  local dst="$2" tmp
  mkdir -p "$(dirname "$dst")" 2>/dev/null || return 1
  tmp=$(mktemp "$dst.XXXXXX") || return 1
  if cat "$1" > "$tmp" 2>/dev/null && mv -f "$tmp" "$dst"; then return 0; fi
  rm -f "$tmp"; return 1
}

if [ -n "$PROJ" ]; then
  PROJECTS="$PROJ"
else
  PROJECTS=$(cut -f2 "$TMP/all" | sort -u)
fi
[ -n "$PROJECTS" ] || PROJECTS="${PROJ:-all}"
first=1
for p in $PROJECTS; do
  [ "$first" = 1 ] || echo
  first=0
  : > "$TMP/top.$p"
  report "$p"
  if [ -n "$OUTF" ] && [ -n "$PROJ" ]; then
    write_atomic "$TMP/top.$p" "$OUTF" || echo "defer-report: cannot write $OUTF" >&2
  fi
  if [ "$LANE" = 1 ] && { [ -n "$PROJ" ] || [ "$p" != all ]; }; then
    write_atomic "$TMP/top.$p" "$H/state/defer-report/$p-top.txt" \
      || echo "defer-report: cannot write $H/state/defer-report/$p-top.txt" >&2
    mkdir -p "$H/logs" 2>/dev/null
    [ -s "$TMP/log.$p" ] && printf '%s %s\n' "$(date -u -d "@$NOW" '+%Y-%m-%dT%H:%M:%SZ')" "$(cat "$TMP/log.$p")" >> "$H/logs/defer-report.log"
  fi
done
exit 0
