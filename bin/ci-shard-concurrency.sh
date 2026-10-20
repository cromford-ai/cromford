#!/bin/bash
# bin/ci-shard-concurrency.sh [--last 50] [--repo O/R] [--out TSV]
#                             [--from-dir DIR] [--workflow-file PATH]
# Shard wall time by how many merge-queue batches ran at once (BH-7620).
# READ-ONLY: GitHub REST reads through `${SHARD_CONC_GH:-gh} api` (no gh
# pr/run/issue subcommand); nothing is written but --out and a temp dir.
#
#   bin/ci-shard-concurrency.sh --last 50 --out /tmp/conc.tsv
#
# READS (the repo default is HARNESS_REPO from bin/lib/deployment.sh):
#   1. repos/<r>/actions/workflows/harness-ci.yml/runs?per_page=100&page=<p>,
#      p = 1..3. The read stops after a page with fewer than 100 runs, or when
#      enough runs are found. A run counts when its head_branch starts with
#      mergify/merge-queue/ and its status is completed. The newest --last
#      runs by created_at are kept.
#   2. Per run: repos/<r>/actions/runs/<id>/jobs?per_page=100 (one read; the
#      latest attempt). The run is unreadable when the read fails, when the
#      JSON has no .jobs array, or when total_count > (.jobs | length).
#   3. Per run: the log of the job "CI plan (what this run tests)" through
#      repos/<r>/actions/jobs/<job id>/logs. Only the `ci-plan: sizing:` line
#      is parsed: the shard count, the slowest shard estimate and `cap
#      reached`. No sizing line gives `-`. A failed log read gives `-` and the
#      note `plan log unreadable`. The row still counts in both cases.
#   --from-dir DIR replaces every read: DIR/runs.json (page 1) or
#   DIR/runs-<p>.json, DIR/jobs-<id>.json, DIR/plan-<id>.log. A missing jobs
#   file makes the run unreadable.
#   --workflow-file (default .github/workflows/harness-ci.yml of this
#   checkout): the cap is the job-level `timeout-minutes:` of the tests-shard
#   job. A cap that cannot be read is rc 2. The cap is never assumed.
#
# DEFINITIONS:
#   shard job    a job named `Tests, traced (shard <i>/<n>)` with both
#                timestamps. Its wall is completed_at - started_at.
#   window W     [min started_at, max completed_at] over the run's shard jobs.
#   conc c       round(sum over all listed readable runs R' (R included) of
#                overlap(W_R, W_R') / |W_R|), half up. So c >= 1.
#   cap-cancel   a shard job with conclusion cancelled or timed_out and wall
#                >= cap*60 - 60 s. A failure or a success is never one.
#
# OUTPUT. A TSV, header first, one row per run, newest first: run_id draft
# started_at conc shards slowest_wall_min mean_wall_min cap_cancelled plan_n
# plan_est_min cap_reached wall_over_est note. draft is the run's
# .pull_requests[0].number or `-`. wall_over_est = slowest wall / plan est.
# An unreadable row has `unreadable` in conc, `-` elsewhere and the reason in
# note. A run with no shard job has conc `-` and note `no shard jobs`, and is
# not in any bucket. Unknown values are `-`, never 0.
# Then the summary on stdout (the TSV goes to stdout too, or to --out):
#   note: concurrency counts merge-queue batch runs of harness-ci.yml only
#   conc <c>: runs <r>, shard wall p50 <x> p90 <y> max <z> min, slowest/est
#     p50 <a> max <b>, cap-cancelled shards <k> in <j> runs   (one per c)
#   cap: <m> min (harness-ci.yml tests-shard)
#   runs: <n> read, <u> unreadable
# Percentiles are nearest rank: the value at rank ceil(p/100*n), ascending.
#
# Seam: SHARD_CONC_GH (the gh binary). rc 0 on a complete read; rc 3 when a
# row is unreadable or the run list cannot be read; rc 2 on a bad argument or
# an unreadable cap.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKOUT="$(cd "$SELF_DIR/.." && pwd)"
GH="${SHARD_CONC_GH:-gh}"
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$SELF_DIR/lib/deployment.sh}" || exit 2
LAST=50; REPO="$HARNESS_REPO"; OUTF=""; FROM=""; WF="$CHECKOUT/.github/workflows/harness-ci.yml"
PLAN_JOB="CI plan (what this run tests)"
SHARD_RE='^Tests, traced \(shard [0-9]+/[0-9]+\)$'
need() { [ "$2" -ge 2 ] || { echo "shard-conc: $1 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --last) need "$1" $#; LAST="$2"; shift ;;
    --repo) need "$1" $#; REPO="$2"; shift ;;
    --out) need "$1" $#; OUTF="$2"; shift ;;
    --from-dir) need "$1" $#; FROM="$2"; shift ;;
    --workflow-file) need "$1" $#; WF="$2"; shift ;;
    -h|--help) sed -n '2,58p' "$0"; exit 0 ;;
    *) echo "shard-conc: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
case "$LAST" in ''|*[!0-9]*|0) echo "shard-conc: --last must be a positive integer, got '$LAST'" >&2; exit 2 ;; esac
case "$REPO" in */*) ;; *) echo "shard-conc: --repo must be owner/repo, got '$REPO'" >&2; exit 2 ;; esac
[ -z "$FROM" ] || [ -d "$FROM" ] || { echo "shard-conc: --from-dir $FROM is not a directory" >&2; exit 2; }

# ── The cap: the job-level timeout-minutes of the tests-shard block.
CAP=$(awk '/^  tests-shard:/ { f = 1; next }
           f && /^  [A-Za-z0-9_-]+:/ { exit }
           f && /^    timeout-minutes:/ { v = $0; sub(/^    timeout-minutes:[ \t]*/, "", v); sub(/[ \t]*(#.*)?$/, "", v); print v; exit }' "$WF" 2>/dev/null)
case "$CAP" in
  ''|*[!0-9]*) echo "shard-conc: cannot read timeout-minutes of the tests-shard job in $WF" >&2; exit 2 ;;
esac

TMP=$(mktemp -d "${TMPDIR:-/tmp}/shard-conc.XXXXXX") || { echo "shard-conc: no temp dir" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

# summary_fail <reason> — the run list cannot be read: header, empty summary, rc 3.
summary_fail() {
  echo "shard-conc: $1" >&2
  hdr > "${OUTF:-/dev/stdout}"
  echo "note: concurrency counts merge-queue batch runs of harness-ci.yml only"
  echo "cap: $CAP min (harness-ci.yml tests-shard)"
  echo "runs: 0 read, 0 unreadable"
  exit 3
}
hdr() { printf 'run_id\tdraft\tstarted_at\tconc\tshards\tslowest_wall_min\tmean_wall_min\tcap_cancelled\tplan_n\tplan_est_min\tcap_reached\twall_over_est\tnote\n'; }

# ── 1. The run list.
: > "$TMP/runs"
LIST_RC=0
for pg in 1 2 3; do
  if [ -n "$FROM" ]; then
    f="$FROM/runs-$pg.json"; [ "$pg" = 1 ] && [ -f "$FROM/runs.json" ] && f="$FROM/runs.json"
    if [ ! -f "$f" ]; then
      [ "$pg" = 1 ] && summary_fail "the run list could not be read: no $f"
      break
    fi
    cp "$f" "$TMP/page" || summary_fail "the run list could not be read: $f"
  elif ! "$GH" api "repos/$REPO/actions/workflows/harness-ci.yml/runs?per_page=100&page=$pg" > "$TMP/page" 2> "$TMP/err"; then
    [ "$pg" = 1 ] && summary_fail "the run list could not be read (page 1): $(head -c 300 "$TMP/err")"
    echo "shard-conc: the run list page $pg could not be read; the list stops at page $((pg - 1))" >&2
    LIST_RC=3; break
  fi
  n=$(jq '.workflow_runs | length' "$TMP/page" 2>/dev/null) \
    || { [ "$pg" = 1 ] && summary_fail "the run list page 1 did not parse"; echo "shard-conc: page $pg did not parse" >&2; LIST_RC=3; break; }
  jq -c '.workflow_runs[] | select(((.head_branch // "") | test("^mergify/merge-queue/")) and .status == "completed")' \
    "$TMP/page" >> "$TMP/runs"
  [ "$(jq -s 'unique_by(.id) | length' "$TMP/runs")" -lt "$LAST" ] || break
  [ "$n" -ge 100 ] || break
done
jq -s -c --argjson n "$LAST" 'unique_by(.id) | sort_by(.created_at) | reverse | .[:$n] | .[]' "$TMP/runs" > "$TMP/runs.n"

# ── 2-3. Per run: the shard jobs and the plan line.
# meta: id draft started state plan_n plan_est_s cap_reached note
# shards: id start_epoch end_epoch conclusion
: > "$TMP/meta"; : > "$TMP/shards"
while IFS=$'\t' read -r id draft rstart; do
  jf="$TMP/jobs-$id.json"
  if [ -n "$FROM" ]; then
    cp "$FROM/jobs-$id.json" "$jf" 2>/dev/null || { printf '%s\t%s\t%s\tunreadable\t-\t-\t-\tjobs read failed\n' "$id" "$draft" "$rstart" >> "$TMP/meta"; continue; }
  elif ! "$GH" api "repos/$REPO/actions/runs/$id/jobs?per_page=100" > "$jf" 2>/dev/null; then
    printf '%s\t%s\t%s\tunreadable\t-\t-\t-\tjobs read failed\n' "$id" "$draft" "$rstart" >> "$TMP/meta"; continue
  fi
  chk=$(jq -r 'if (.jobs | type) != "array" then "no jobs array"
               elif (.total_count // 0) > (.jobs | length) then "jobs list incomplete (\(.total_count) > \(.jobs | length))"
               else "ok" end' "$jf" 2>/dev/null) || chk="jobs did not parse"
  [ "$chk" = ok ] || { printf '%s\t%s\t%s\tunreadable\t-\t-\t-\t%s\n' "$id" "$draft" "$rstart" "$chk" >> "$TMP/meta"; continue; }
  sh=$(jq -r --arg re "$SHARD_RE" --arg id "$id" '
        def ep: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
        .jobs[] | select((.name // "") | test($re)) | select(.started_at != null and .completed_at != null)
        | [$id, (.started_at | ep), (.completed_at | ep), (.conclusion // "-"), .started_at] | @tsv' "$jf" 2>/dev/null) \
    || { printf '%s\t%s\t%s\tunreadable\t-\t-\t-\tjob timestamps did not parse\n' "$id" "$draft" "$rstart" >> "$TMP/meta"; continue; }
  [ -z "$sh" ] || printf '%s\n' "$sh" >> "$TMP/shards"
  # The window start as ISO: the earliest started_at (same format, so it sorts).
  wstart=$(printf '%s\n' "$sh" | awk -F'\t' 'NF { if (m == "" || $2 < m) { m = $2; s = $5 } } END { print s }')
  [ -n "$wstart" ] || wstart="$rstart"
  pn=-; pe=-; pc=-; note=""
  jid=$(jq -r --arg n "$PLAN_JOB" '[.jobs[] | select(.name == $n) | .id][0] // empty' "$jf")
  if [ -z "$jid" ]; then
    note="no plan job"
  else
    lf="$TMP/plan-$id.log"; lok=1
    if [ -n "$FROM" ]; then cp "$FROM/plan-$id.log" "$lf" 2>/dev/null || lok=0
    else "$GH" api "repos/$REPO/actions/jobs/$jid/logs" --allow-escape-sequences > "$lf" 2>/dev/null || lok=0
    fi
    if [ "$lok" = 0 ]; then
      note="plan log unreadable"
    else
      line=$(grep -m1 'ci-plan: sizing:' "$lf")
      if [ -n "$line" ]; then
        v=$(printf '%s\n' "$line" | sed -nE 's/.* ([0-9]+) shard\(s\).*/\1/p'); [ -n "$v" ] && pn="$v"
        v=$(printf '%s\n' "$line" | sed -nE 's/.*slowest est ([0-9]+)s.*/\1/p'); [ -n "$v" ] && pe="$v"
        case "$line" in *"cap reached"*) pc=yes ;; *) pc=no ;; esac
      fi
    fi
  fi
  printf '%s\t%s\t%s\tok\t%s\t%s\t%s\t%s\n' "$id" "$draft" "$wstart" "$pn" "$pe" "$pc" "$note" >> "$TMP/meta"
done < <(jq -r '[.id, ((.pull_requests // [])[0].number // "-"), (.run_started_at // .created_at // "-")] | @tsv' "$TMP/runs.n")

# ── The rows and the summary. awk reads the shards first, then the meta rows
# in run-list order (newest first).
cat > "$TMP/calc.awk" <<'AWK'
function min1(s) { return sprintf("%.1f", s / 60) }
# rank <arr> <n> <p> — nearest rank on a sorted copy (insertion sort, mawk has no asort).
function nrank(a, n, p,    b, i, j, x, k) {
  if (n == 0) return "-"
  for (i = 1; i <= n; i++) b[i] = a[i]
  for (i = 2; i <= n; i++) { x = b[i]; j = i - 1; while (j >= 1 && b[j] > x) { b[j + 1] = b[j]; j-- } b[j + 1] = x }
  k = p * n / 100; if (k != int(k)) k = int(k) + 1; if (k < 1) k = 1
  return b[k]
}
FILENAME == ARGV[1] {
  id = $1; s = $2 + 0; e = $3 + 0
  ns[id]++; st[id, ns[id]] = s; wl[id, ns[id]] = e - s; cn[id, ns[id]] = $4
  if (!(id in ws) || s < ws[id]) ws[id] = s
  if (!(id in we) || e > we[id]) we[id] = e
  next
}
{ nm++; mid[nm] = $1; mdr[nm] = $2; mst[nm] = $3; mstate[nm] = $4; mpn[nm] = $5; mpe[nm] = $6; mpc[nm] = $7; mnote[nm] = $8 }
END {
  # The listed readable runs with a window.
  for (i = 1; i <= nm; i++) if (mstate[i] == "ok" && (mid[i] in ws)) { nw++; wid[nw] = mid[i] }
  thr = cap * 60 - 60
  for (i = 1; i <= nm; i++) {
    id = mid[i]
    if (mstate[i] != "ok") {
      printf "%s\t%s\t%s\tunreadable\t-\t-\t-\t-\t-\t-\t-\t-\t%s\n", id, mdr[i], mst[i], mnote[i]
      unread++; continue
    }
    readn++
    pe = mpe[i]; pem = (pe == "-") ? "-" : min1(pe)
    if (!(id in ws)) {
      note = mnote[i] == "" ? "no shard jobs" : "no shard jobs; " mnote[i]
      printf "%s\t%s\t%s\t-\t0\t-\t-\t-\t%s\t%s\t%s\t-\t%s\n", id, mdr[i], mst[i], mpn[i], pem, mpc[i], note
      continue
    }
    len = we[id] - ws[id]
    if (len <= 0) {
      note = mnote[i] == "" ? "zero-length window" : "zero-length window; " mnote[i]
      c = "-"
    } else {
      sum = 0
      for (k = 1; k <= nw; k++) {
        o = wid[k]; lo = ws[id] > ws[o] ? ws[id] : ws[o]; hi = we[id] < we[o] ? we[id] : we[o]
        if (hi > lo) sum += hi - lo
      }
      c = int(sum / len + 0.5); note = mnote[i]
    }
    slow = 0; tot = 0; cc = 0
    for (k = 1; k <= ns[id]; k++) {
      w = wl[id, k]; tot += w; if (w > slow) slow = w
      if ((cn[id, k] == "cancelled" || cn[id, k] == "timed_out") && w >= thr) cc++
    }
    woe = (pe == "-" || pe + 0 == 0) ? "-" : sprintf("%.2f", slow / pe)
    if (note == "") note = "-"
    printf "%s\t%s\t%s\t%s\t%d\t%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\n", id, mdr[i], mst[i], c, ns[id], min1(slow), min1(tot / ns[id]), cc, mpn[i], pem, mpc[i], woe, note
    if (c == "-") continue
    if (!(c in br)) { nb++; bkey[nb] = c }
    br[c]++
    for (k = 1; k <= ns[id]; k++) { bw[c]++; bwv[c, bw[c]] = wl[id, k] }
    if (woe != "-") { be[c]++; bev[c, be[c]] = slow / pe }
    bcc[c] += cc; if (cc > 0) bcr[c]++
  }
  # Buckets ascending (insertion sort on the keys).
  for (i = 2; i <= nb; i++) { x = bkey[i]; j = i - 1; while (j >= 1 && bkey[j] + 0 > x + 0) { bkey[j + 1] = bkey[j]; j-- } bkey[j + 1] = x }
  sumf = ENVIRON["SC_SUMMARY"]
  print "note: concurrency counts merge-queue batch runs of harness-ci.yml only" > sumf
  for (i = 1; i <= nb; i++) {
    c = bkey[i]
    delete a; for (k = 1; k <= bw[c]; k++) a[k] = bwv[c, k]
    p50 = min1(nrank(a, bw[c], 50)); p90 = min1(nrank(a, bw[c], 90)); mx = min1(nrank(a, bw[c], 100))
    delete a; for (k = 1; k <= be[c]; k++) a[k] = bev[c, k]
    if (be[c] + 0 > 0) { e50 = sprintf("%.2f", nrank(a, be[c], 50)); emx = sprintf("%.2f", nrank(a, be[c], 100)) } else { e50 = "-"; emx = "-" }
    printf "conc %s: runs %d, shard wall p50 %s p90 %s max %s min, slowest/est p50 %s max %s, cap-cancelled shards %d in %d runs\n", c, br[c], p50, p90, mx, e50, emx, bcc[c], bcr[c] + 0 > sumf
  }
  printf "cap: %s min (harness-ci.yml tests-shard)\n", cap > sumf
  printf "runs: %d read, %d unreadable\n", readn, unread > sumf
  exit (unread > 0 ? 3 : 0)
}
AWK
{ hdr; SC_SUMMARY="$TMP/summary" awk -F'\t' -v cap="$CAP" -f "$TMP/calc.awk" "$TMP/shards" "$TMP/meta"; } > "$TMP/tsv"
RC=$?
[ -s "$TMP/summary" ] || { echo "shard-conc: the summary could not be computed" >&2; exit 3; }
if [ -n "$OUTF" ]; then cp "$TMP/tsv" "$OUTF" || { echo "shard-conc: cannot write $OUTF" >&2; exit 2; }
else cat "$TMP/tsv"
fi
cat "$TMP/summary"
[ "$RC" = 0 ] || exit 3
exit "$LIST_RC"
