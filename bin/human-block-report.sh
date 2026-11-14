#!/bin/bash
# bin/human-block-report.sh [--last <N>d] [--repo OWNER/NAME] [--log PATH]...
#                           [--now YYYY-MM-DDTHH:MM:SSZ] [--daily]
#
# BH-9427 (C0): THE HUMAN-BLOCK REPORT. Why do PRs park in BLOCKED_HUMAN, how
# long do they wait there, and how does each block end? Daily at 06:40Z on the
# hub (cron/lanes/781-human-block-report.cron, --daily). No GitHub call, no
# model call, no worker call: it reads the conductor log only.
#
# THE SOURCE. mc_transition (bin/lib/mc/settle.sh) writes one line per state
# change to logs/merge-conductor.log (mc_log, bin/lib/mc/log.sh):
#   <YYYY-MM-DD HH:MM:SSZ> <owner>/<repo>#<n> <PREV|-> -> <NEW> head=… reviewed=… merge=… reason=<why>
# The default source is logs/merge-conductor.log.1 (when present), then
# logs/merge-conductor.log; --log PATH (repeatable) replaces both, read in the
# order given. Any other line is ignored (a re-reasoned line, a "MERGED <key>
# by conductor" line, a BLOCKED_AGENT line, a truncated last line).
#
# THE RULES.
#   1. A transition matches the format above. The states come from the FIRST
#      " -> "; the reason is the text after the first " reason=". A line
#      after --now is ignored.
#   2. An episode starts at "-> BLOCKED_HUMAN" and ends at the next transition
#      of the same key. Wait = end - start, whole minutes; an episode with no
#      end waits until --now.
#   3. Outcome: the first MERGED after the episode = merged; the first CLOSED
#      or ABANDONED = closed; no end = blocked (still blocked); else open (left
#      the block, not merged or closed yet).
#   4. Class = the reason up to the first ":", " " or "("; empty or "-" =
#      "(none)". Detail = the text after "<class>: " up to " on main", " — " or
#      the end, cut to 60 bytes; "-" when there is none.
#   5. An episode counts when it STARTED in [now - N days, now]. A MERGED in
#      that window counts in merged_prs; it is human-blocked when the same key
#      had an episode (any time in the files read) before the merge.
#   6. Median: the middle value; for an even count, the floor of the mean of
#      the two middle values.
#
# STDOUT (TSV after the header line):
#   human-block-report: window <N>d ending <now>, repo <all|slug>, source <files>, window_src <arg|knob|default|fallback>
#   class blocks prs median_wait_min total_wait_min merged closed blocked open
#   <one row per class, most blocks first, ties by class name>
#   TOTAL …
#   merged_prs <M> human_blocked_before_merge <K> share_pct <K*100/M, 1 decimal | n/a>
#   detail <class> <detail> <count>     (top HUMAN_BLOCK_REPORT_DETAILS per class)
#   repo <slug> blocks <b> merged <m> blocked_merged <k> share_pct <p> median_wait_min <w>
#
# --daily ALSO appends ONE line to logs/human-block.log:
#   <ISO now> [human-block] status=ok window=<N>d window_src=<src> blocks= prs=
#   median_wait_min= total_wait_min= merged= closed= still_blocked= open=
#   merged_prs= blocked_share_pct= classes=<class>:<blocks>/<median>,…
#   repos=<slug>:<blocks>/<blocked_merged>/<merged>/<median>,…
# AN UNREADABLE SOURCE IS NEVER A ZERO COUNT: with no readable log, stdout
# names the paths, --daily writes "status=no-source paths=<p1,p2>", rc 3.
#
# Exit: 0 printed; 2 bad arguments (nothing written); 3 no readable log.
#
# Knobs (catalog/lanes.d/human-block-report.json; settings rows via lane_env_apply):
#   HUMAN_BLOCK_REPORT_WINDOW_D  7  default window, days (1..90); --last wins
#   HUMAN_BLOCK_REPORT_DETAILS   3  detail rows per class (1..20)
# Retention: logs/human-block.log grows one line (under 600 bytes) a day; no
# job is needed (docs/notes/2026-11-12-BH-9427-human-block-report.md).
set -uo pipefail
H="${HARNESS:-/root/harness}"

# >>> lane gate. Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off human-block-report.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit human-block-report
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    human-block-report
# <<< lane gate

usage() {
  echo "usage: human-block-report.sh [--last <N>d] [--repo OWNER/NAME] [--log PATH]... [--now YYYY-MM-DDTHH:MM:SSZ] [--daily]" >&2
  exit 2
}

LAST="" REPO="" NOW_ISO="" DAILY=0
LOGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --last)  [ $# -ge 2 ] || usage; LAST="$2"; shift ;;
    --repo)  [ $# -ge 2 ] || usage; REPO="$2"; shift ;;
    --log)   [ $# -ge 2 ] || usage; LOGS+=("$2"); shift ;;
    --now)   [ $# -ge 2 ] || usage; NOW_ISO="$2"; shift ;;
    --daily) DAILY=1 ;;
    *) usage ;;
  esac
  shift
done

# The window: --last wins; else the knob; a bad knob value falls back to 7.
WIN_SRC=arg
if [ -n "$LAST" ]; then
  [[ "$LAST" =~ ^([0-9]{1,3})d$ ]] || usage
  WIN_D=$((10#${BASH_REMATCH[1]}))
  { [ "$WIN_D" -ge 1 ] && [ "$WIN_D" -le 90 ]; } || usage
else
  v="${HUMAN_BLOCK_REPORT_WINDOW_D:-}"
  if [ -z "$v" ]; then WIN_D=7; WIN_SRC=default          # fallback of knob HUMAN_BLOCK_REPORT_WINDOW_D
  elif [[ "$v" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$v))" -ge 1 ] && [ "$((10#$v))" -le 90 ]; then WIN_D=$((10#$v)); WIN_SRC=knob
  else WIN_D=7; WIN_SRC=fallback; fi                       # fallback of knob HUMAN_BLOCK_REPORT_WINDOW_D
fi
v="${HUMAN_BLOCK_REPORT_DETAILS:-}"
if [[ "$v" =~ ^[0-9]{1,2}$ ]] && [ "$((10#$v))" -ge 1 ] && [ "$((10#$v))" -le 20 ]; then DETAILS=$((10#$v))
else DETAILS=3; fi                                         # fallback of knob HUMAN_BLOCK_REPORT_DETAILS

if [ -n "$REPO" ]; then
  [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || usage
fi
if [ -n "$NOW_ISO" ]; then
  [[ "$NOW_ISO" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || usage
  NOW_S=$(date -u -d "$NOW_ISO" +%s 2>/dev/null) || usage
else
  NOW_S=$(date -u +%s)
  NOW_ISO=$(date -u -d "@$NOW_S" +%Y-%m-%dT%H:%M:%SZ)
fi

if [ "${#LOGS[@]}" -eq 0 ]; then
  LOGS=("$H/logs/merge-conductor.log.1" "$H/logs/merge-conductor.log")
fi
READ=()
for f in "${LOGS[@]}"; do [ -f "$f" ] && [ -r "$f" ] && READ+=("$f"); done

OUT_LOG="$H/logs/human-block.log"
daily_line() {
  [ "$DAILY" = 1 ] || return 0
  mkdir -p "$H/logs" 2>/dev/null
  printf '%s [human-block] %s\n' "$NOW_ISO" "$1" >> "$OUT_LOG"
}

if [ "${#READ[@]}" -eq 0 ]; then
  echo "human-block-report: no conductor log at ${LOGS[*]}"
  daily_line "status=no-source paths=$(IFS=,; printf '%s' "${LOGS[*]}")"
  exit 3
fi

REPORT=$(
  # One prefilter, one awk pass. A partial last line (the conductor is still
  # writing) has fewer than 7 fields and is skipped by rule 1.
  grep -h -- ' -> ' "${READ[@]}" 2>/dev/null |
  LC_ALL=C awk -v now="$NOW_S" -v win="$WIN_D" -v repo="$REPO" -v ndet="$DETAILS" '
    function days(y, m, d,   era, yoe, mp, doy, doe) {
      y -= (m <= 2); era = int((y >= 0 ? y : y - 399) / 400); yoe = y - era * 400
      mp = (m + 9) % 12; doy = int((153 * mp + 2) / 5) + d - 1
      doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
      return era * 146097 + doe - 719468
    }
    function epoch(dt, tm,   a, b) {
      split(dt, a, "-"); split(tm, b, ":"); sub(/Z$/, "", b[3])
      return days(a[1] + 0, a[2] + 0, a[3] + 0) * 86400 + b[1] * 3600 + b[2] * 60 + b[3]
    }
    # isort <arr> <n> — sort arr[1..n] numerically, ascending.
    function isort(arr, n,   i, j, t) {
      for (i = 2; i <= n; i++) { t = arr[i]; for (j = i - 1; j >= 1 && arr[j] > t; j--) arr[j + 1] = arr[j]; arr[j + 1] = t }
    }
    function median(arr, n) {
      if (n == 0) return 0
      isort(arr, n)
      if (n % 2) return arr[(n + 1) / 2]
      return int((arr[n / 2] + arr[n / 2 + 1]) / 2)
    }
    function share(k, m) { return m == 0 ? "n/a" : sprintf("%.1f", k * 100 / m) }
    BEGIN { FS = " "; wstart = now - win * 86400; ne = 0 }
    {
      if (NF < 7 || $5 != "->") next
      if ($1 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) next
      if ($2 !~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/) next
      if ($3 !~ /^[^ #\/]+\/[^ #\/]+#[0-9]+$/) next
      if ($4 != "-" && $4 !~ /^[A-Z_]+$/) next
      if ($6 !~ /^[A-Z_]+$/) next
      key = $3; nw = $6
      sl = key; sub(/#.*/, "", sl)
      if (repo != "" && sl != repo) next
      t = epoch($1, $2)
      if (t > now) next
      i = index($0, " reason="); why = (i ? substr($0, i + 8) : "")
      # Close the open episode of this key on any other state.
      if ((key in cur) && nw != "BLOCKED_HUMAN") { e = cur[key]; eend[e] = t; delete cur[key] }
      if (nw == "BLOCKED_HUMAN" && !(key in cur)) {
        e = ++ne; ekey[e] = key; estart[e] = t; eslug[e] = sl; cur[key] = e
        pend[key] = pend[key] " " e; blocked_ever[key] = 1
        cls = why
        if (match(cls, /[: (]/)) cls = substr(cls, 1, RSTART - 1)
        if (cls == "" || cls == "-") cls = "(none)"
        det = "-"
        if (substr(why, length(cls) + 1, 2) == ": ") {
          det = substr(why, length(cls) + 3)
          if ((j = index(det, " on main"))) det = substr(det, 1, j - 1)
          if ((j = index(det, " \342\200\224 "))) det = substr(det, 1, j - 1)
          det = substr(det, 1, 60)
          if (det == "") det = "-"
        }
        ecls[e] = cls; edet[e] = det
      }
      if (nw == "MERGED" || nw == "CLOSED" || nw == "ABANDONED") {
        oc = (nw == "MERGED" ? "merged" : "closed")
        n = split(pend[key], pl, " ")
        for (j = 1; j <= n; j++) eout[pl[j]] = oc
        delete pend[key]
        if (nw == "MERGED" && t >= wstart) {
          mprs++; rmerged[sl]++; seen_repo[sl] = 1
          if (blocked_ever[key]) { mblk++; rbm[sl]++ }
        }
      }
    }
    END {
      nc = 0
      for (e = 1; e <= ne; e++) {
        if (estart[e] < wstart) continue
        c = ecls[e]; k = ekey[e]; sl = eslug[e]
        if (!(e in eout)) eout[e] = ((k in cur) && cur[k] == e) ? "blocked" : "open"
        w = int((((e in eend) ? eend[e] : now) - estart[e]) / 60)
        if (!(c in cb)) { cl[++nc] = c }
        cb[c]++; ct[c] += w; cw[c, cb[c]] = w; co[c, eout[e]]++
        if (!((c, k) in cpr)) { cpr[c, k] = 1; cp[c]++ }
        if (!(k in tpr)) { tpr[k] = 1; tp++ }
        tb++; tt += w; tw[tb] = w; to[eout[e]]++
        cd[c, edet[e]]++; if (!((c, edet[e]) in cdl)) { cdl[c, edet[e]] = 1; cdn[c]++; cdk[c, cdn[c]] = edet[e] }
        rb[sl]++; rw[sl, rb[sl]] = w; seen_repo[sl] = 1
      }
      # Class order: most blocks first, ties by class name.
      for (i = 2; i <= nc; i++) {
        x = cl[i]
        for (j = i - 1; j >= 1 && (cb[cl[j]] < cb[x] || (cb[cl[j]] == cb[x] && cl[j] > x)); j--) cl[j + 1] = cl[j]
        cl[j + 1] = x
      }
      print "class\tblocks\tprs\tmedian_wait_min\ttotal_wait_min\tmerged\tclosed\tblocked\topen"
      for (i = 1; i <= nc; i++) {
        c = cl[i]; split("", a); for (j = 1; j <= cb[c]; j++) a[j] = cw[c, j]
        cm[c] = median(a, cb[c])
        printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", c, cb[c], cp[c], cm[c], ct[c], co[c, "merged"], co[c, "closed"], co[c, "blocked"], co[c, "open"]
      }
      tmed = median(tw, tb)
      printf "TOTAL\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", tb, tp, tmed, tt, to["merged"], to["closed"], to["blocked"], to["open"]
      printf "merged_prs\t%d\thuman_blocked_before_merge\t%d\tshare_pct\t%s\n", mprs, mblk, share(mblk, mprs)
      for (i = 1; i <= nc; i++) {
        c = cl[i]; n = cdn[c]
        for (j = 1; j <= n; j++) dl[j] = cdk[c, j]
        for (p = 2; p <= n; p++) {
          x = dl[p]
          for (q = p - 1; q >= 1 && (cd[c, dl[q]] < cd[c, x] || (cd[c, dl[q]] == cd[c, x] && dl[q] > x)); q--) dl[q + 1] = dl[q]
          dl[q + 1] = x
        }
        for (j = 1; j <= n && j <= ndet; j++) printf "detail\t%s\t%s\t%d\n", c, dl[j], cd[c, dl[j]]
      }
      nr = 0; for (s in seen_repo) rl[++nr] = s
      for (i = 2; i <= nr; i++) {
        x = rl[i]
        for (j = i - 1; j >= 1 && (rb[rl[j]] < rb[x] || (rb[rl[j]] == rb[x] && rl[j] > x)); j--) rl[j + 1] = rl[j]
        rl[j + 1] = x
      }
      for (i = 1; i <= nr; i++) {
        s = rl[i]; split("", a); for (j = 1; j <= rb[s]; j++) a[j] = rw[s, j]
        printf "repo\t%s\tblocks\t%d\tmerged\t%d\tblocked_merged\t%d\tshare_pct\t%s\tmedian_wait_min\t%d\n", s, rb[s], rmerged[s], rbm[s], share(rbm[s], rmerged[s]), median(a, rb[s])
      }
    }'
)

echo "human-block-report: window ${WIN_D}d ending $NOW_ISO, repo ${REPO:-all}, source ${READ[*]}, window_src $WIN_SRC"
printf '%s\n' "$REPORT"

if [ "$DAILY" = 1 ]; then
  line=$(printf '%s\n' "$REPORT" | awk -F'\t' -v w="${WIN_D}d" -v ws="$WIN_SRC" '
    $1 == "class" { p = 1; next }
    $1 == "TOTAL" { p = 0; tot = sprintf("blocks=%s prs=%s median_wait_min=%s total_wait_min=%s merged=%s closed=%s still_blocked=%s open=%s", $2, $3, $4, $5, $6, $7, $8, $9); next }
    p { cls = cls cs $1 ":" $2 "/" $4; cs = "," }
    $1 == "merged_prs" { mp = sprintf("merged_prs=%s blocked_share_pct=%s", $2, $6) }
    $1 == "repo" { rp = rp rs $2 ":" $4 "/" $8 "/" $6 "/" $12; rs = "," }
    END { printf "status=ok window=%s window_src=%s %s %s classes=%s repos=%s", w, ws, tot, mp, cls, rp }')
  daily_line "$line"
fi
exit 0
