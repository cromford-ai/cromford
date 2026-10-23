#!/bin/bash
# bin/gh-quota-report.sh — BH-1484: who burns the shared GitHub bucket.
#
# THE QUESTION THIS ANSWERS IN ONE COMMAND. The hub and the pool boxes run every
# lane under ONE GitHub App installation, so a 6,600/h primary bucket is shared
# by every repo and every lane. On 2026-09-22 it was burning ~5,700/h and
# draining in the last five minutes of each window; the only symptom was an
# hourly burst of "UNVERIFIABLE (HTTP 000)" lines in merge-conductor.log, and
# the only way to find the culprit was to guess. bin/lib/gh-rest-ledger.sh now
# writes one line per REST call; this reads them.
#
#   bin/gh-quota-report.sh [--fleet|--local] [hour|day]
#
#   --fleet  (the default when this box can reach harness-jobs) — EVERY box's
#            ledger, from the gh_ledger table bin/gh-ledger-push.sh fills
#            (BH-1574): per box, per bucket (meter/resource), per caller, the
#            top path classes and the GraphQL line from the X-RateLimit headers
#            the rows carried. `hour` is the last hour and the current one,
#            `day` the last 24. A worker that does not answer falls back to
#            this box's files and SAYS so on the first line.
#   --local  this box's files only, the pre-BH-1574 report, unchanged:
#            `hour` the newest hour file, `day` every hour file still on disk
#            (the ledger is swept at 48h, so "day" is at most that).
#
# WHY FLEET IS THE DEFAULT (BH-1574). The hub App installation's 6,600/h bucket
# is shared by the hub, seven boxes and every Fly builder; a report of one box's
# files called ~5,000/h of it "unaccounted" on 2026-09-23 when most of it was
# other boxes' ledgers that nothing summed.
#
# Output, in four blocks: the totals, calls per BUCKET, calls per LANE per HOUR,
# and the top path CLASSES. `calls` is every line; `counted` is the subset
# GitHub actually charged (a 304 answered against an ETag and a 000 that never
# reached GitHub are both counted=0), and the two are printed side by side
# because their RATIO is the whole value of the ETag cache.
#
# THE BUCKET BLOCK IS NOT DECORATION (BH-1484 review I-1). One lane spends from
# several rate-limit buckets in one tick as its token ladder switches per repo:
# every installation token of the App shares one 6,600/h bucket, and each PAT
# has its own 5,000/h. Summing their `remaining` columns together would be
# adding up different meters, so the bucket is column 10 and this splits on it.
#
# READ ONLY, AND IT COSTS NO API CALL — which is the point: a report that asked
# GitHub how much was left would spend the thing it is measuring. It reads files
# under state/gh-rest-ledger/, writes nothing, and deletes nothing (the 48h
# sweep belongs to bin/merge-sweep.sh, not here).
#
# rc 0 = printed (including "no ledger lines", which is a real answer and says
#        so in words — a silent zero would read as "nothing burned it")
# rc 2 = could not read the ledger directory at all.
set -uo pipefail

H="${HARNESS:-/root/harness}"
DIR="$H/state/gh-rest-ledger"
WIN=hour; MODE=auto
while [ $# -gt 0 ]; do
  case "$1" in
    hour|day) WIN="$1" ;;
    --fleet) MODE=fleet ;;
    --local) MODE=local ;;
    -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
    *) echo "usage: gh-quota-report.sh [--fleet|--local] [hour|day]" >&2; exit 2 ;;
  esac
  shift
done

# ── the fleet, from D1 ──────────────────────────────────────────────────────
# rc 0 = printed; rc 1 = the worker did not answer (the caller falls back).
fleet_report() {
  local now since resp tmp
  command -v _jobs_req >/dev/null 2>&1 || { FLEET_WHY="bin/jobs-client.sh missing"; return 1; }
  now=$(date -u +%s)
  if [ "$WIN" = day ]; then since=$((now - 86400)); else since=$((now - 3600)); fi
  since=$(date -u -d "@$since" +%Y-%m-%dT%H 2>/dev/null || date -u -r "$since" +%Y-%m-%dT%H)
  # To a FILE, not `$( )`: JOBS_HTTP is set in the shell that ran the request,
  # and the fallback line names it. JOBS_ALERT=0: an operator's read is optional
  # evidence and must not spend the fleet's one daily outage alert.
  tmp=$(mktemp "${TMPDIR:-/tmp}/gh-quota-report.XXXXXX") || { FLEET_WHY="mktemp failed"; return 1; }
  if ! JOBS_ALERT=0 _jobs_req GET "/api/metrics/gh-ledger?since=$since" > "$tmp"; then
    FLEET_WHY="http=${JOBS_HTTP:-none}"; rm -f "$tmp"; return 1
  fi
  resp=$(cat "$tmp"); rm -f "$tmp"
  printf '%s' "$resp" | jq -e '.rows | type == "array"' >/dev/null 2>&1 || { FLEET_WHY="unparseable answer"; return 1; }
  echo "gh-quota-report: fleet (D1) $WIN — since $since UTC$(printf '%s' "$resp" | jq -r 'if .truncated then ", TRUNCATED at \(.rows|length) rows" else "" end')"
  printf '%s' "$resp" | jq -r '.rows[] | [.box, .lane, .meter, .resource, .path_class,
      (.calls // 0), (.counted // 0), (.remaining_min // ""), (.used_max // ""), (.limit_max // "")]
      | map(tostring) | @tsv' | awk -F'\t' '
    function sortk(arr, n, keys,   i, j, t) {
      for (i = 0; i < n; i++) for (j = i + 1; j < n; j++) if (keys[j] < keys[i]) { t = keys[i]; keys[i] = keys[j]; keys[j] = t }
    }
    {
      calls += $6; counted += $7
      if (!($1 in bc)) { bk[nb++] = $1 }; bc[$1] += $6; bcc[$1] += $7
      u = $3 "/" $4
      if (!(u in uc)) { uk[nu++] = u }; uc[u] += $6; ucc[u] += $7
      if ($8 != "" && (!(u in umin) || $8 + 0 < umin[u])) umin[u] = $8 + 0
      if (!($2 in cc)) { ck[nc++] = $2 }; cc[$2] += $6; ccc[$2] += $7
      if (!($5 in pc)) { pk[np++] = $5 }; pc[$5] += $6; pcc[$5] += $7
      if ($4 == "graphql") {
        m = $3; if (!(m in gseen)) { gk[ng++] = m; gseen[m] = 1 }
        if ($8 != "" && (!(m in grem) || $8 + 0 < grem[m])) grem[m] = $8 + 0
        if ($9 != "" && (!(m in gused) || $9 + 0 > gused[m])) gused[m] = $9 + 0
        if ($10 != "" && (!(m in glim) || $10 + 0 > glim[m])) glim[m] = $10 + 0
      }
    }
    END {
      printf "TOTAL  calls=%d  counted=%d  boxes=%d\n", calls, counted, nb
      print ""; print "CALLS PER BOX"; printf "%-28s %8s %8s\n", "BOX", "CALLS", "COUNTED"
      sortk(bc, nb, bk); for (i = 0; i < nb; i++) printf "%-28s %8d %8d\n", bk[i], bc[bk[i]], bcc[bk[i]]
      print ""; print "CALLS PER BUCKET (token meter / X-RateLimit-Resource)"
      printf "%-32s %8s %8s %8s\n", "BUCKET", "CALLS", "COUNTED", "MIN_REM"
      sortk(uc, nu, uk); for (i = 0; i < nu; i++) printf "%-32s %8d %8d %8s\n", uk[i], uc[uk[i]], ucc[uk[i]], ((uk[i] in umin) ? umin[uk[i]] : "?")
      print ""; print "CALLS PER CALLER"; printf "%-28s %8s %8s\n", "CALLER", "CALLS", "COUNTED"
      sortk(cc, nc, ck); for (i = 0; i < nc; i++) printf "%-28s %8d %8d\n", ck[i], cc[ck[i]], ccc[ck[i]]
      print ""; print "TOP PATH CLASSES"; printf "%8s %8s  %s\n", "CALLS", "COUNTED", "CLASS"
      for (i = 0; i < np; i++) for (j = i + 1; j < np; j++)
        if (pc[pk[j]] > pc[pk[i]] || (pc[pk[j]] == pc[pk[i]] && pk[j] < pk[i])) { t = pk[i]; pk[i] = pk[j]; pk[j] = t }
      lim = (np < 15 ? np : 15)
      for (i = 0; i < lim; i++) printf "%8d %8d  %s\n", pc[pk[i]], pcc[pk[i]], pk[i]
      if (ng) print ""
      sortk(gseen, ng, gk)
      for (i = 0; i < ng; i++) {
        m = gk[i]
        printf "GRAPHQL %s used=%s remaining=%s/%s (X-RateLimit headers: highest used, lowest remaining in the window)\n", m,
          ((m in gused) ? gused[m] : "?"), ((m in grem) ? grem[m] : "?"), ((m in glim) ? glim[m] : "?")
      }
    }'
  return 0
}

if [ "$MODE" != local ]; then
  # jobs-client.sh reads HARNESS_SECRET out of this box's global.env itself when
  # the environment does not carry it; it is side-effect-free to source.
  # Only a client with its modules beside it: jobs-client.sh EXITS the shell
  # that sources it when bin/lib/jobs/ is missing, and a report that dies on a
  # half-synced bin/ would hide the local ledger it can still print.
  for JC in "$H/bin/jobs-client.sh" "$(dirname "$0")/jobs-client.sh"; do
    # shellcheck source=bin/jobs-client.sh
    [ -r "$JC" ] && [ -r "${JC%/*}/lib/jobs/req.sh" ] && { . "$JC"; break; }
  done
fi
if [ "$MODE" = auto ]; then
  # Fleet whenever this box holds the credential the worker needs; a box (or a
  # test tree) without one reads its own files, as it always did.
  MODE=local
  [ -n "${HARNESS_SECRET:-}" ] && command -v _jobs_req >/dev/null 2>&1 && MODE=fleet
fi
if [ "$MODE" = fleet ]; then
  FLEET_WHY=""
  fleet_report && exit 0
  echo "gh-quota-report: fleet read failed (${FLEET_WHY:-worker unreachable}) — this box's ledger only"
fi

if [ ! -d "$DIR" ]; then
  echo "gh-quota-report: no ledger at $DIR — nothing has written a REST call on this box"
  exit 0
fi

# The window is chosen by FILE, never by filtering timestamps against the wall
# clock: the files are already keyed on the UTC hour, so "the newest hour" is a
# sort and "the day" is all of them, and neither answer moves while the report
# is running.
FILES=()
if [ "$WIN" = hour ]; then
  NEWEST=$(ls -1 "$DIR"/*.tsv 2>/dev/null | sort | tail -1)
  [ -n "$NEWEST" ] && FILES=("$NEWEST")
else
  while IFS= read -r f; do [ -n "$f" ] && FILES+=("$f"); done < <(ls -1 "$DIR"/*.tsv 2>/dev/null | sort)
fi

if [ "${#FILES[@]}" = 0 ]; then
  echo "gh-quota-report: no ledger lines in $DIR ($WIN) — no REST call has been recorded yet"
  exit 0
fi

echo "gh-quota-report: $WIN — ${#FILES[@]} hour file(s) under $DIR"

# ONE awk pass over the window, three groupings. Ties break on the name so the
# same ledger always prints the same report — a report whose row order moves
# between runs cannot be diffed, and diffing two hours is how a burst is found.
# A status `cache` row is the gh shim's cache answering from disk (BH-8066):
# not a request, so not a call here.
awk -F'\t' '
  NF >= 7 && $6 != "cache" {
    calls++; counted += ($7 + 0)
    hour = substr($1, 1, 13)
    lk = hour "\t" $2
    lc[lk]++; lcc[lk] += ($7 + 0)
    pc[$5]++; pcc[$5] += ($7 + 0)
    # Column 10 arrived with the review fix; a line written before it reads as
    # "-", which is an honest "we did not record which meter this spent from"
    # and never silently folded into the App bucket.
    b = (NF >= 10 && $10 != "" ? $10 : "-")
    bc[b]++; bcc[b] += ($7 + 0)
  }
  END {
    printf "TOTAL  calls=%d  counted=%d\n", calls, counted
    print ""
    print "CALLS PER BUCKET"
    printf "%-20s %8s %8s\n", "BUCKET", "CALLS", "COUNTED"
    nb = 0
    for (k in bc) { bk[nb++] = k }
    for (i = 0; i < nb; i++) for (j = i + 1; j < nb; j++) if (bk[j] < bk[i]) { t = bk[i]; bk[i] = bk[j]; bk[j] = t }
    for (i = 0; i < nb; i++) printf "%-20s %8d %8d\n", bk[i], bc[bk[i]], bcc[bk[i]]
    print ""
    print "CALLS PER LANE PER HOUR"
    printf "%-14s %-26s %8s %8s\n", "HOUR", "LANE", "CALLS", "COUNTED"
    n = 0
    for (k in lc) { keys[n++] = k }
    for (i = 0; i < n; i++) for (j = i + 1; j < n; j++) if (keys[j] < keys[i]) { t = keys[i]; keys[i] = keys[j]; keys[j] = t }
    for (i = 0; i < n; i++) {
      split(keys[i], p, "\t")
      printf "%-14s %-26s %8d %8d\n", p[1], p[2], lc[keys[i]], lcc[keys[i]]
    }
    print ""
    print "TOP PATH CLASSES"
    printf "%8s %8s  %s\n", "CALLS", "COUNTED", "CLASS"
    m = 0
    for (k in pc) { pk[m++] = k }
    for (i = 0; i < m; i++) for (j = i + 1; j < m; j++)
      if (pc[pk[j]] > pc[pk[i]] || (pc[pk[j]] == pc[pk[i]] && pk[j] < pk[i])) { t = pk[i]; pk[i] = pk[j]; pk[j] = t }
    lim = (m < 15 ? m : 15)
    for (i = 0; i < lim; i++) printf "%8d %8d  %s\n", pc[pk[i]], pcc[pk[i]], pk[i]
  }' "${FILES[@]}" || exit 2

# The reserve and the last reading of the SHARED App bucket, so the report ends
# on the number the gate is comparing against rather than leaving the reader to
# find it in a second place. gh_quota_line does not sweep (review S-1), so this
# command deletes nothing.
for L in "$H/bin/lib/gh-rest-ledger.sh" "$(dirname "$0")/lib/gh-rest-ledger.sh"; do
  # shellcheck source=bin/lib/gh-rest-ledger.sh
  [ -r "$L" ] && { . "$L"; break; }
done
if command -v gh_quota_line >/dev/null 2>&1; then
  echo ""
  gh_quota_line
fi
exit 0
