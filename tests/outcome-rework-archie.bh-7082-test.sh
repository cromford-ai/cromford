#!/bin/bash
# tests/outcome-rework-archie.bh-7082-test.sh — BH-7082: Archie initiative I1
# reads csv:logs/outcome-rework-rollup.csv#decomposed_rate@project=cromford,
# and a cromford week with decomposed children gives it a number.
#
# The writer is rework_scan (bin/lib/outcome-rework.sh), run by the real lane
# bin/outcome-metrics.sh. The reader is archie_metric_csv (bin/lib/archie.sh):
# it takes the LAST row that matches the filter and refuses a non-number.
#
#   A1  the real lane: cromford PRs 81 `BH-81: BH-80.1:`, 82 `BH-82:
#       BH-80.2:`, 83 `BH-83:` in WEEK (the newest closed week) give the row
#       3 merged, 2 decomposed, 1 decomposed reworked, decomposed_rate 50.0,
#       1 sibling reworked
#   A2  archie_metric_csv on the exact I1 string prints 50.0, rc 0; with the
#       same PRs in an older week only, the newest row is a zero row and
#       Archie reads nothing
#   A3  REWORK_FETCH_CAP=3 with cromford second in fleet order: the I1
#       initiative moves cromford first, so it gets its row and alpha-os
#       does not; with the initiatives route at 404, fleet order starves it
#   A4  no decomposed children: decomposed_rate is -, Archie reads nothing;
#       the reader takes the last cromford row in file order
#   A5  read-only: the gh sink holds no write after any lane run
#
# NO LIVE CALLS: curl and gh are the stubs of tests/outcome-rework-test.sh,
# plus the initiatives route. Fixtures are invented (Acme/*, BH-8n, AX-nn).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/outcome-rework-archie.bh-7082-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
export JOBS_URL=https://jobs.invalid JOBS_RETRIES=0
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing — skipping"; exit 0; }
BASE="$T"
STUB="$BASE/stub"; mkdir -p "$STUB"
export PATH="$STUB:$PATH"
printf '#!/bin/sh\nexit 0\n' > "$STUB/flock"; chmod +x "$STUB/flock"

# ── curl stub: the worker. The ledger route as in outcome-rework-test.sh, and
# the initiatives route answering $FIX/initiatives.json ($FIX/initiatives.code).
cat > "$STUB/curl" <<'SH'
#!/bin/bash
URL="${!#}"
body='{}'; code=404
case "$URL" in
  */api/ledger\?kind=merge*)
    M=$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%SZ)
    body='{"ledgers":[{"key":"https://github.com/Acme/ledger-only/pull/1","status":"merged","job_id":"b-1","updated_at":"'"$M"'"}]}'; code=200 ;;
  */api/initiatives\?status=active*)
    printf '%s\n' "$URL" >> "$FIX/initiatives.reads"
    body=$(cat "$FIX/initiatives.json" 2>/dev/null || echo '{"initiatives":[]}')
    code=$(cat "$FIX/initiatives.code" 2>/dev/null || echo 200) ;;
esac
printf '%s\n%s\n' "$body" "$code"
SH
chmod +x "$STUB/curl"

# ── gh stub: tests/outcome-rework-test.sh's, verbatim in behaviour ──────────
cat > "$STUB/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
JQ=""; A=()
while [ $# -gt 0 ]; do
  case "$1" in
    --jq|-q) JQ="$2"; shift 2 ;;
    --json)  shift 2 ;;
    --paginate) shift ;;
    -X|--method) echo "WRITE $*" >> "$GH_SINK.writes"; exit 90 ;;
    *) A+=("$1"); shift ;;
  esac
done
SUB="${A[0]:-}"; P="${A[1]:-}"
flat() { printf '%s' "$1" | tr '/' '_'; }
OUT=""
case "$SUB" in
  api)
    case "$P" in
      rate_limit) OUT='{"resources":{"core":{"remaining":5000}}}' ;;
      repos/*/pulls\?state=closed*)
        R=${P#repos/}; R=${R%%/pulls*}; PG=$(printf '%s' "$P" | grep -oE 'page=[0-9]+$' | cut -d= -f2)
        OUT=$(cat "$FIX/pulls-$(flat "$R")-$PG.json" 2>/dev/null || echo '[]') ;;
      repos/*/pulls/*/files*)
        R=${P#repos/}; R=${R%%/pulls/*}; N=${P#*/pulls/}; N=${N%%/*}
        OUT=$(cat "$FIX/prfiles-$(flat "$R")-$N.json" 2>/dev/null || echo '[]') ;;
      repos/*/commits\?since=*) OUT='[]' ;;
      *) OUT='{}' ;;
    esac ;;
  pr)
    case "${A[1]:-}" in
      view) OUT='{"mergeCommit":{"oid":""}}' ;;
      *) echo "WRITE $*" >> "$GH_SINK.writes"; exit 90 ;;
    esac ;;
  *) echo "WRITE $*" >> "$GH_SINK.writes"; exit 90 ;;
esac
[ -z "$OUT" ] && exit 1
if [ -n "$JQ" ]; then printf '%s' "$OUT" | jq -r "$JQ"; else printf '%s' "$OUT"; fi
SH
chmod +x "$STUB/gh"

# The lane writes a row for EVERY closed week (zeros when it has no PRs), in
# week order, and Archie takes the last one. So the row I1 reads is the NEWEST
# closed week: Monday LMON with LMON + 7d - 1 + 7d (window) < now. OMON is four
# ISO weeks back, an older closed week inside the backfill. A0 / OA0 = their
# Tuesday 12:00Z.
NOW=$(date -u +%s)
DAY=86400
D=$((NOW - 28*DAY)); DOW=$(date -u -d "@$D" +%u)
OMON=$(( (D/DAY - (DOW-1)) * DAY ))
LMON=$OMON
while [ $((LMON + 7*DAY + 14*DAY - 1)) -lt "$NOW" ]; do LMON=$((LMON + 7*DAY)); done
A0=$((LMON + DAY + 43200)); OA0=$((OMON + DAY + 43200))
WEEK=$(date -u -d "@$LMON" +%G-W%V); OWEEK=$(date -u -d "@$OMON" +%G-W%V)
I1='csv:logs/outcome-rework-rollup.csv#decomposed_rate@project=cromford'

newroot() { # newroot <name> -> sets R; alpha-os first, cromford second
  R="$BASE/$1"
  mkdir -p "$R/logs" "$R/state" "$R/flags" "$R/locks" "$R/env" "$R/fix"
  echo "HARNESS_SECRET=test-secret" > "$R/env/global.env"
  cat > "$R/fleet.conf" <<'CONF'
alpha-os       Acme/alpha-os       https://os.alpha.example   /api/board  2 box-alpha
cromford  Acme/cromford  https://os.harness.example /api/board  6 box-harness
CONF
  : > "$R/list.tsv"; : > "$R/gh.log"
}
lpr() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$(date -u -d "@$3" +%Y-%m-%dT%H:%M:%SZ)" "$4" "${5:-main}" >> "$R/list.tsv"; }
lfiles() {
  local repo="$1" n="$2"; shift 2
  printf '%s\n' "$@" | jq -R . | jq -s '[.[] | {filename: .}]' > "$R/fix/prfiles-$(printf '%s' "$repo" | tr '/' '_')-$n.json"
}
mkpages() {
  python3 - "$R/list.tsv" "$R/fix" <<'PY'
import json, sys, collections
rows = collections.defaultdict(list)
for line in open(sys.argv[1]):
    repo, n, merged, title, base = line.rstrip("\n").split("\t")
    rows[repo].append({"number": int(n), "merged_at": merged, "updated_at": merged,
                       "title": title, "base": {"ref": base, "repo": {"default_branch": "main"}}})
for repo, prs in rows.items():
    prs.sort(key=lambda p: p["updated_at"], reverse=True)
    json.dump(prs, open("%s/pulls-%s-1.json" % (sys.argv[2], repo.replace("/", "_")), "w"))
PY
}
initiatives() { # initiatives <metric_query>...
  jq -nc '{initiatives: [$ARGS.positional | to_entries[] | {id: (.key + 1), status: "active", metric_query: .value}], truncated: false}' \
    --args "$@" > "$R/fix/initiatives.json"
}
bh_children() { # bh_children [tuesday]: cromford 81-83, two children of BH-80, one plain PR
  local t="${1:-$A0}"
  lpr Acme/cromford 81 "$t" "BH-81: BH-80.1: a"
  lpr Acme/cromford 82 "$((t + DAY))" "BH-82: BH-80.2: b"
  lpr Acme/cromford 83 "$((t + 2*DAY))" "BH-83: c"
  lfiles Acme/cromford 81 bin/x.sh; lfiles Acme/cromford 82 bin/x.sh
  lfiles Acme/cromford 83 worker/y.js
}
run() {
  env HARNESS="$R" FLEET_CONF="$R/fleet.conf" FIX="$R/fix" GH_SINK="$R/gh.log" "$@" bash "$DIR/bin/outcome-metrics.sh" >/dev/null 2>&1
}
summary() { grep ' scanned=' "$R/logs/outcome-metrics.log" | tail -1; }
col() { grep "^$WEEK,cromford," "$R/logs/outcome-rework-rollup.csv" 2>/dev/null | head -1 | cut -d, -f"$1"; }
# shellcheck source=../bin/lib/archie.sh
. "$DIR/bin/lib/archie.sh" || { echo "FAIL: cannot source bin/lib/archie.sh"; exit 1; }
archie() { HARNESS="$R" archie_metric_csv "$I1"; }

# ── A1: the real lane, a week with decomposed children ──────────────────────
newroot a1
lpr Acme/alpha-os 11 "$A0" "AX-11: a"; lfiles Acme/alpha-os 11 src/a.ts
bh_children; mkpages
run; RC=$?
[ "$RC" = 0 ] && ok || bad "A1 lane exited $RC"
RU="$R/logs/outcome-rework-rollup.csv"
grep -q "^$WEEK,cromford," "$RU" 2>/dev/null && ok \
  || bad "A1 no ^$WEEK,cromford, row: $(cat "$RU" 2>/dev/null)"
[ "$(grep "^$WEEK,cromford," "$RU" 2>/dev/null | head -1 | awk -F, '{print NF}')" = 10 ] && ok \
  || bad "A1 the $WEEK cromford row has not 10 columns"
[ "$(col 3)" = 3 ] && ok || bad "A1 merged: want 3, got '$(col 3)'"
[ "$(col 6)" = 2 ] && ok || bad "A1 decomposed_merged: want 2, got '$(col 6)'"
[ "$(col 7)" = 1 ] && ok || bad "A1 decomposed_reworked: want 1, got '$(col 7)'"
[ "$(col 8)" = 50.0 ] && ok || bad "A1 decomposed_rate: want 50.0, got '$(col 8)'"
[ "$(col 9)" = 1 ] && ok || bad "A1 sibling_reworked: want 1, got '$(col 9)'"
grep "rework week=$WEEK project=cromford " "$R/logs/outcome-metrics.log" | grep -qF 'decomposed=50.0% (1/2)' && ok \
  || bad "A1 no log line with decomposed=50.0% (1/2): $(grep 'project=cromford' "$R/logs/outcome-metrics.log")"
[ ! -s "$R/gh.log.writes" ] && ok || bad "A5 a gh write (A1): $(cat "$R/gh.log.writes")"

# ── A2: Archie reads the row through the exact I1 string ────────────────────
V=$(archie); RC=$?
[ "$RC" = 0 ] && [ "$V" = 50.0 ] && ok || bad "A2 archie_metric_csv on I1: want 50.0 rc 0, got '$V' rc $RC"

# The other side: the same PRs in OWEEK only. OWEEK's row has 50.0, but the
# lane also writes the zero rows of the newer weeks up to WEEK, and Archie
# reads the last one.
newroot a2-old
bh_children "$OA0"; mkpages
run; RC=$?
[ "$RC" = 0 ] && ok || bad "A2 old week: lane exited $RC"
grep -q "^$OWEEK,cromford,3,1,33.3,2,1,50.0,1," "$R/logs/outcome-rework-rollup.csv" 2>/dev/null && ok \
  || bad "A2 old week: no 50.0 row for $OWEEK: $(grep ',cromford,' "$R/logs/outcome-rework-rollup.csv" 2>/dev/null)"
[ "$(grep ',cromford,' "$R/logs/outcome-rework-rollup.csv" | tail -1)" = "$WEEK,cromford,0,0,-,0,0,-,0,backfill" ] && ok \
  || bad "A2 old week: the last cromford row is not the $WEEK zero row: $(grep ',cromford,' "$R/logs/outcome-rework-rollup.csv" | tail -1)"
V=$(archie); RC=$?
[ "$RC" != 0 ] && [ -z "$V" ] && ok || bad "A2 old week: Archie read '$V' rc $RC; the newest row is a zero row"
[ ! -s "$R/gh.log.writes" ] && ok || bad "A5 a gh write (A2 old week)"

# ── A3: the fetch cap, cromford second in fleet order ──────────────────
a3() { # a3 <name> -> fixture: alpha-os 3 PRs, cromford 81-83, cap 3
  newroot "$1"
  lpr Acme/alpha-os 11 "$A0" "AX-11: a"; lpr Acme/alpha-os 12 "$((A0 + DAY))" "AX-12: b"
  lpr Acme/alpha-os 13 "$((A0 + 2*DAY))" "AX-13: c"
  lfiles Acme/alpha-os 11 src/a.ts; lfiles Acme/alpha-os 12 src/a.ts; lfiles Acme/alpha-os 13 src/b.ts
  bh_children; mkpages
  initiatives "$I1"
}
a3 a3
run REWORK_FETCH_CAP=3; RC=$?
[ "$RC" = 0 ] && ok || bad "A3 lane exited $RC"
for n in 81 82 83; do
  grep -q "repos/Acme/cromford/pulls/$n/files" "$R/gh.log" && ok || bad "A3 PR $n files not read: $(grep files "$R/gh.log")"
done
summary | grep -qE ' rework_first=cromford( |$)' && ok || bad "A3 summary lacks rework_first=cromford: $(summary)"
grep -q "^$WEEK,cromford," "$R/logs/outcome-rework-rollup.csv" 2>/dev/null && ok \
  || bad "A3 no $WEEK cromford row: $(cat "$R/logs/outcome-rework-rollup.csv" 2>/dev/null)"
grep -q "^$WEEK,alpha-os," "$R/logs/outcome-rework-rollup.csv" 2>/dev/null \
  && bad "A3 alpha-os got a $WEEK row with its week unread" || ok
[ "$(archie)" = 50.0 ] && ok || bad "A3 Archie does not read 50.0 after a capped run: '$(archie)'"
[ ! -s "$R/gh.log.writes" ] && ok || bad "A5 a gh write (A3)"
# The other side: the initiatives route answers 404, fleet order starves it.
a3 a3-404; echo 404 > "$R/fix/initiatives.code"
run REWORK_FETCH_CAP=3
summary | grep -qE ' rework_first=-( |$)' && ok || bad "A3 404: summary lacks rework_first=-: $(summary)"
grep -q 'rework: initiatives unreadable; fleet order' "$R/logs/outcome-metrics.log" && ok \
  || bad "A3 404: no 'initiatives unreadable' line: $(grep rework "$R/logs/outcome-metrics.log")"
grep -q "^$WEEK,cromford," "$R/logs/outcome-rework-rollup.csv" 2>/dev/null \
  && bad "A3 404: cromford got a row although the cap ran out on alpha-os" || ok
[ ! -s "$R/gh.log.writes" ] && ok || bad "A5 a gh write (A3 404)"

# ── A4: no decomposed children -> decomposed_rate is -, Archie reads nothing ─
newroot a4
lpr Acme/cromford 91 "$A0" "BH-91: a"; lpr Acme/cromford 92 "$((A0 + DAY))" "BH-92: b"
lfiles Acme/cromford 91 bin/x.sh; lfiles Acme/cromford 92 bin/x.sh
mkpages
run; RC=$?
[ "$RC" = 0 ] && ok || bad "A4 lane exited $RC"
grep -q "^$WEEK,cromford," "$R/logs/outcome-rework-rollup.csv" 2>/dev/null && ok \
  || bad "A4 no $WEEK cromford row: $(cat "$R/logs/outcome-rework-rollup.csv" 2>/dev/null)"
[ "$(col 6)" = 0 ] && ok || bad "A4 decomposed_merged: want 0, got '$(col 6)'"
[ "$(col 8)" = - ] && ok || bad "A4 decomposed_rate: want -, got '$(col 8)'"
V=$(archie); RC=$?
[ "$RC" != 0 ] && [ -z "$V" ] && ok || bad "A4 Archie read '$V' rc $RC from a - rate"
[ ! -s "$R/gh.log.writes" ] && ok || bad "A5 a gh write (A4)"
# Edge: the reader takes the LAST cromford row in file order.
HDR='week,project,merged,reworked,rate,decomposed_merged,decomposed_reworked,decomposed_rate,sibling_reworked,source'
newroot a4-num-first
printf '%s\n%s\n%s\n' "$HDR" "2026-W01,cromford,3,1,33.3,2,1,50.0,1,backfill" \
  "2026-W02,cromford,2,0,0.0,0,0,-,0,run" > "$R/logs/outcome-rework-rollup.csv"
V=$(archie); RC=$?
[ "$RC" != 0 ] && [ -z "$V" ] && ok || bad "A4 numeric row first, - row last: Archie read '$V' rc $RC"
newroot a4-dash-first
printf '%s\n%s\n%s\n' "$HDR" "2026-W01,cromford,2,0,0.0,0,0,-,0,backfill" \
  "2026-W02,cromford,3,1,33.3,2,1,50.0,1,run" > "$R/logs/outcome-rework-rollup.csv"
V=$(archie); RC=$?
[ "$RC" = 0 ] && [ "$V" = 50.0 ] && ok || bad "A4 - row first, 50.0 last: want 50.0, got '$V' rc $RC"

# ── A5: no lane run issued a write verb ─────────────────────────────────────
W=$(cat "$BASE"/*/gh.log.writes 2>/dev/null)
[ -z "$W" ] && ok || bad "A5 a run issued a mutating gh call: $(head -1 <<<"$W")"

echo "outcome-rework-archie: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
