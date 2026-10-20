#!/bin/bash
# tests/pipeline-health-open-list.bh-7616-test.sh — BH-7616 (C1): the hub lane
# "$DIR/bin/pipeline-health.sh" reads a repo's open-PR list once per tick,
# through the shared snapshot "$DIR/bin/lib/pr-snapshot.sh", not once per
# section.
#
#   E1  the REAL script, no arguments, snapshot on: 1 open-list read of o/fx,
#       and both the stalepr and the leadunqueued pages for o/fx #7
#   E2  the same run with PR_SNAPSHOT=0: 2 list reads in today's two shapes,
#       and the same two pages
#   M1  a copy of the script without the `export HPL_SNAPSHOT=1` line gives 2
#       reads as E1 (E1 cannot pass without it); M2 a copy whose leadunqueued
#       block reads raw gives 2 reads too
#   R1..R6  the `# >>> open list` block plus the stalepr, stale-parent (REST
#       mode, spr_stale_commits a stub) and leadunqueued blocks in one process:
#       R1 snapshot on, 3 sections, 1 read; R2 PR_SNAPSHOT=0, 3 reads; R3 TTL 0,
#       3 reads; R4 no pr-snapshot.sh, 3 reads; R5 --sections leadunqueued with
#       HPL_SNAPSHOT=1 inherited and a fresh open.json, a live read; R6
#       --sections stalepr,leadunqueued, live for both
#   F1  the snapshot list answers 403: no page, the carry markers are in
#       $FIRED, no open.json, no raw read in its place
#   P1  120 open PRs (20 on main, rows 101-120) under the snapshot: no
#       page-cut, PR 120 judged; P2 100 rows with the snapshot off: the
#       page-cut page names 100; P3 1000 rows under the snapshot: it names 1000
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pipeline-health-open-list.bh-7616-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PHS="$REPO/bin/pipeline-health.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }
unset REGISTRY_SOURCE HARNESS H LANE_RUN_ID PL_LANE PL_PROJECT PL_LOCK_FD GH_TOKEN HPL_SNAPSHOT PH_SECTIONS \
  PR_SNAPSHOT PR_SNAPSHOT_TTL_S PR_SNAPSHOT_QUIET_TTL_S PR_SNAPSHOT_FEED_STALE_S PR_SNAPSHOT_LIB PRS_COUNT_FILE
mkdir -p "$T/fakebin" "$T/stub" "$T/tmp"
HARNESS_TEST_SANDBOX=1 "$REPO/bin/lanes-build.sh" --root "$REPO" --to "$T/lanes.json" >/dev/null 2>&1 \
  || { echo "FAIL: bin/lanes-build.sh could not compose the registry"; exit 1; }
SHA7=7777777777777777777777777777777777777777

# ── stubs ──
cat > "$T/stub/jobs-client.sh" <<'EOF'
# shellcheck shell=bash
_jobs_req() { return 1; }
_jobs_req_file() { return 1; }
setting_get() { return 1; }
_jobs_box_name() { echo fixture-box; }
EOF
cat > "$T/stub/beat.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "${1:-}" >> "$HARNESS/beat.log"
exit 0
EOF
printf '#!/bin/bash\nexit 1\n' > "$T/stub/queued-fly-relayed.sh"
# The stale-parent REST lib for the R trees: judges nothing, logs each PR.
cat > "$T/stub/stale-parent-rest.sh" <<'EOF'
# shellcheck shell=bash
SPR_FETCHED=0; SPR_CACHED=0
spr_budget_init() { SPR_FETCHED=0; SPR_CACHED=0; }
spr_stale_commits() { echo "$3" >> "$HARNESS/spr.log"; return 0; }
spr_cache_save() { return 0; }
EOF
chmod +x "$T/stub/beat.sh" "$T/stub/queued-fly-relayed.sh"

# gh: one call a line in <tree>/gh.calls. <tree>/prs.json holds o/fx's open
# PRs; every list shape answers its page of 100 rows from it.
#   snapshot  api -i -X GET repos/o/fx/pulls -f state=open -F per_page=100 -F page=N
#   stalepr   api -i -X GET repos/o/fx/pulls?state=open&per_page=100&sort=created&…&page=N
#   raw       api repos/o/fx/pulls?state=open&per_page=100 (page 1 only)
# <tree>/list403 present: every list shape answers 403.
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
A="$*"
echo "$A" >> "$HARNESS/gh.calls"
pg=1; [[ " $A " =~ [\&\ ]page=([0-9]+) ]] && pg="${BASH_REMATCH[1]}"
page() { jq -c --argjson p "$pg" '.[($p - 1) * 100 : $p * 100]' "$HARNESS/prs.json"; }
case "$A" in
  "api repos/"*" -q .id") exit 0 ;;
  *"api rate_limit"*)
    printf '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"-i "*"repos/o/fx/pulls -f state=open"*|*"-i "*"repos/o/fx/pulls?state=open"*)
    if [ -e "$HARNESS/list403" ]; then printf 'HTTP/2 403\r\nx-ratelimit-remaining: 0\r\n\r\n{"message":"API rate limit exceeded"}\n'; exit 0; fi
    printf 'HTTP/2 200\r\n\r\n'; page ;;
  "api repos/o/fx/pulls?state=open&per_page=100")
    [ -e "$HARNESS/list403" ] && exit 1; page ;;
  "api repos/o/fx/commits/"*"/status")
    printf '{"state":"success","statuses":[{"context":"lead-verdict","state":"success","updated_at":"2026-09-10T00:00:00Z"}]}\n' ;;
  "api repos/o/fx/pulls/"*"/reviews?per_page=100") echo '[]' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/fakebin/gh"

# prs <n-total> <first-main-row> — o/fx's open PRs, newest first (created desc);
# rows from <first-main-row> on are based on main, the rest on other branches.
prs() {
  jq -nc --argjson n "$1" --argjson m "$2" --arg sha "$SHA7" '[range(0; $n) as $i | {
    number: ($n - $i + 6), created_at: "2026-09-10T00:00:00Z", updated_at: "2026-09-10T00:00:00Z",
    title: "FX", draft: false, state: "open", merged_at: null, closed_at: null, body: "", labels: [],
    html_url: ("https://github.com/o/fx/pull/" + (($n - $i + 6) | tostring)),
    head: {ref: "b", sha: (if $n == 1 then $sha else ("f" * 39 + "0") end), repo: {full_name: "o/fx"}},
    base: {ref: (if $i + 1 >= $m then "main" else "other" end), repo: {full_name: "o/fx", default_branch: "main"}},
    user: {login: "operator", type: "User"}}]'
}

# mktree <dir> — the stubs, then the REAL closure of bin/pipeline-health.sh.
mktree() {
  local d="$1"
  mkdir -p "$d/bin/lib" "$d/logs" "$d/state" "$d/flags" "$d/env" "$d/locks" || return 1
  cp "$T/stub/beat.sh" "$T/stub/queued-fly-relayed.sh" "$T/stub/jobs-client.sh" "$d/bin/" || return 1
  scratch_install_closure bin/pipeline-health.sh "$d" >/dev/null || return 1
  scratch_install_closure bin/alert-line.sh "$d" >/dev/null || return 1
  printf 'fx\to/fx\n' > "$d/fleet.conf"
  : > "$d/env/global.env"; : > "$d/alerts.conf"; : > "$d/gh.calls"
  touch "$d/flags/remediation-disabled"
  prs 1 1 > "$d/prs.json"
}
# lists <tree> [shape] — open-list reads of o/fx (first pages only).
#   shape snap|stalepr|raw counts one shape; none counts every shape.
lists() {
  local re
  case "${2:-}" in
    snap) re='repos/o/fx/pulls -f state=open' ;;
    stalepr) re='repos/o/fx/pulls\?state=open&per_page=100&sort=' ;;
    raw) re='^api repos/o/fx/pulls\?state=open&per_page=100$' ;;
    *) re='repos/o/fx/pulls( |\?)' ;;
  esac
  grep -E "$re" "$1/gh.calls" | grep -cvE '[&= ]page=([2-9]|10)( |$)'
}
envrun() { # envrun <tree> <script> [args...] — the env a hub cron run gets
  local d="$1"; shift
  ( cd "$d" && env PATH="$T/fakebin:$PATH" HARNESS="$d" GH_BUDGET_TTL_S=0 ALERTS_CONF="$d/alerts.conf" \
      FLEET_CONF="$d/fleet.conf" LANE_GATE_DISABLE=1 HARNESS_ENV_DIR="$d/env" GH_BUDGET_CORE_REMAINING=4000 \
      HUB_REPOS="$T/no-repos" LANE_REGISTRY="$T/lanes.json" TMPDIR="$T/tmp" GH_ETAG=0 \
      HARNESS_PR_AUTHORS=operator LEAD_REVIEW_AUTO_REPOS=o/fx ${XENV[@]+"${XENV[@]}"} "$@" ) > "$d/out.txt" 2> "$d/err.txt"
  RC=$?
}
pages() { # pages <tree> — 1 when both o/fx #7 pages are in the beat log
  grep -q '"akey":"health:stalepr:fx"' "$1/beat.log" 2>/dev/null \
    && grep -q "\"akey\":\"health:leadunqueued:o/fx#7:${SHA7:0:12}\"" "$1/beat.log" 2>/dev/null
}

# ============================================================================
echo "E1/E2: the real script, one tick"
E1="$T/e1"; mktree "$E1" || exit 1
XENV=(); envrun "$E1" "$E1/bin/pipeline-health.sh"
[ "$RC" = 0 ] && ok "E1 rc 0" || bad "E1 rc=$RC: $(tail -5 "$E1/err.txt")"
[ "$(lists "$E1")" = 1 ] && ok "E1 one open-list read of o/fx" || bad "E1 $(lists "$E1") list reads: $(grep 'pulls' "$E1/gh.calls")"
[ "$(lists "$E1" snap)" = 1 ] && ok "E1 the read is the snapshot's" || bad "E1 snapshot-shape reads: $(lists "$E1" snap)"
[ -s "$E1/state/pr-snapshot/o_fx/open.json" ] && ok "E1 the snapshot holds o/fx's list" || bad "E1 no state/pr-snapshot/o_fx/open.json"
pages "$E1" && ok "E1 the stalepr and the leadunqueued pages for #7" || bad "E1 pages: $(cat "$E1/beat.log" 2>/dev/null)"

E2="$T/e2"; mktree "$E2" || exit 1
XENV=(PR_SNAPSHOT=0); envrun "$E2" "$E2/bin/pipeline-health.sh"
[ "$RC" = 0 ] && ok "E2 rc 0" || bad "E2 rc=$RC: $(tail -5 "$E2/err.txt")"
[ "$(lists "$E2")" = 2 ] && [ "$(lists "$E2" stalepr)" = 1 ] && [ "$(lists "$E2" raw)" = 1 ] \
  && ok "E2 PR_SNAPSHOT=0: 2 reads in today's two shapes" || bad "E2 reads: $(grep 'pulls' "$E2/gh.calls")"
[ ! -e "$E2/state/pr-snapshot" ] && ok "E2 no snapshot dir" || bad "E2 wrote state/pr-snapshot"
pages "$E2" && ok "E2 the same two pages (output parity)" || bad "E2 pages: $(cat "$E2/beat.log" 2>/dev/null)"

# ============================================================================
echo "M1/M2: mutations of the script go red"
M1="$T/m1"; mktree "$M1" || exit 1
grep -q '^  export HPL_SNAPSHOT=1' "$M1/bin/pipeline-health.sh" && ok "M1 the export line is there to remove" || bad "M1 no '  export HPL_SNAPSHOT=1' line in the script"
sed -i 's/^  export HPL_SNAPSHOT=1;/  :;/' "$M1/bin/pipeline-health.sh"
XENV=(); envrun "$M1" "$M1/bin/pipeline-health.sh"
[ "$RC" = 0 ] && [ "$(lists "$M1")" = 2 ] && ok "M1 without the export: 2 reads (E1 depends on it)" || bad "M1 rc=$RC reads: $(lists "$M1")"
M2="$T/m2"; mktree "$M2" || exit 1
grep -q 'LULIST=$(ph_open_list "$SLUG"' "$M2/bin/pipeline-health.sh" && ok "M2 the leadunqueued read calls ph_open_list" || bad "M2 no ph_open_list call in the leadunqueued block"
sed -i 's|LULIST=$(ph_open_list "$SLUG"|LULIST=$(gh api "repos/$SLUG/pulls?state=open\&per_page=100"|' "$M2/bin/pipeline-health.sh"
XENV=(); envrun "$M2" "$M2/bin/pipeline-health.sh"
[ "$RC" = 0 ] && [ "$(lists "$M2")" = 2 ] && ok "M2 a raw leadunqueued read: 2 reads (E1 depends on the call)" || bad "M2 rc=$RC reads: $(lists "$M2")"

# ============================================================================
echo "R1-R6, F1, P1-P3: the open-list block with the three reading blocks"
blk() { awk -v s="$1" -v e="$2" 'index($0, s) == 1 {f=1; next} index($0, e) == 1 {exit} f' "$PHS"; }
blk '# >>> open list (BH-7616)' '# <<< open list' > "$T/b-open.sh"
blk '# >>> stalepr detector' '# <<< stalepr detector' > "$T/b-stalepr.sh"
blk '# >>> stale parent (BH-5234)' '# <<< stale parent' > "$T/b-sp.sh"
blk '# >>> lead merge unqueued (BH-3778)' '# <<< lead merge unqueued' > "$T/b-lu.sh"
for b in open stalepr sp lu; do
  [ -s "$T/b-$b.sh" ] && ok "block $b extracted" || bad "block $b is not in bin/pipeline-health.sh"
done
# The driver: the libs the script loads before these blocks, alert() as a log.
cat > "$T/drive.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
H="$HARNESS"; PH_SECTIONS="${DRV_SECTIONS:-}"
. "$H/bin/lib/gh-pr-list.sh" || exit 98
. "$H/bin/lib/gh-rest-list.sh" || exit 98
NOW=$(date -u +%s); PROJECTS=fx; FIRED="$H/fired.txt"; ACTIVE="$H/active.txt"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
gh_budget_low() { return 1; }
alert() { echo "$2" >> "$FIRED"; printf '%s|%s\n' "$2" "$3" >> "$H/alerts.txt"; }
. "$DRV_T/b-open.sh"
for b in ${DRV_BLOCKS:-stalepr sp lu}; do . "$DRV_T/b-$b.sh"; done
echo "HPL=${HPL_SNAPSHOT:-unset} CAP=${PH_OPEN_CAP:-unset}"
EOF
# rtree <dir> — a tree for the driver: stale parent in REST mode. The stub's
# text overwrites the real stale-parent-rest.sh the closure installed.
rtree() {
  mktree "$1" || return 1
  cat "$T/stub/stale-parent-rest.sh" > "$1/bin/lib/stale-parent-rest.sh" || return 1
  : > "$1/fired.txt"; : > "$1/alerts.txt"; : > "$1/spr.log"
  printf '%s\n' 'staleparent:fx:9' "leadunqueued:o/fx#7:${SHA7:0:12}" > "$1/active.txt"
}
drive() { # drive <tree> — XENV adds env; RC and the driver's last line in OUT
  local d="$1"
  ( cd "$d" && env PATH="$T/fakebin:$PATH" HARNESS="$d" LANE_GATE_DISABLE=1 LANE_REGISTRY="$T/lanes.json" \
      TMPDIR="$T/tmp" GH_ETAG=0 HARNESS_PR_AUTHORS=operator LEAD_REVIEW_AUTO_REPOS=o/fx LANE_RUN_ID=fixture-run \
      DRV_T="$T" ${XENV[@]+"${XENV[@]}"} bash "$T/drive.sh" ) > "$d/out.txt" 2> "$d/err.txt"
  RC=$?; OUT=$(tail -n 1 "$d/out.txt")
}
alerted() { grep -q "^$2" "$1/alerts.txt"; }
three() { # three <tree> <case> — the 3 sections still page #7 and judge it
  alerted "$1" 'stalepr:fx|' && alerted "$1" "leadunqueued:o/fx#7:${SHA7:0:12}|" && grep -qx 7 "$1/spr.log" \
    && ok "$2 stalepr and leadunqueued page #7, stale parent judged it" \
    || bad "$2 alerts: $(cat "$1/alerts.txt") spr: $(cat "$1/spr.log") err: $(tail -3 "$1/err.txt")"
}

R="$T/r1"; rtree "$R" || exit 1
XENV=(); drive "$R"
[ "$RC" = 0 ] && [ "$OUT" = "HPL=1 CAP=1000" ] && ok "R1 snapshot on: HPL_SNAPSHOT=1, cap 1000" || bad "R1 rc=$RC out=$OUT"
[ "$(lists "$R")" = 1 ] && ok "R1 3 sections, 1 read (before: 3)" || bad "R1 reads: $(grep pulls "$R/gh.calls")"
three "$R" R1

R="$T/r2"; rtree "$R" || exit 1
XENV=(PR_SNAPSHOT=0); drive "$R"
[ "$OUT" = "HPL=unset CAP=100" ] && ok "R2 PR_SNAPSHOT=0: snapshot off, cap 100" || bad "R2 rc=$RC out=$OUT"
[ "$(lists "$R")" = 3 ] && [ "$(lists "$R" raw)" = 2 ] && [ "$(lists "$R" stalepr)" = 1 ] \
  && ok "R2 3 live reads in today's shapes" || bad "R2 reads: $(grep pulls "$R/gh.calls")"
three "$R" R2

R="$T/r3"; rtree "$R" || exit 1
XENV=(PR_SNAPSHOT_TTL_S=0); drive "$R"
[ "$OUT" = "HPL=unset CAP=100" ] && [ "$(lists "$R")" = 3 ] && [ "$(lists "$R" snap)" = 0 ] \
  && ok "R3 TTL 0 is no cache: 3 live reads" || bad "R3 out=$OUT reads: $(grep pulls "$R/gh.calls")"

R="$T/r4"; rtree "$R" || exit 1
rm -f "$R/bin/lib/pr-snapshot.sh"
XENV=(); drive "$R"
[ "$RC" = 0 ] && [ "$OUT" = "HPL=unset CAP=100" ] && [ "$(lists "$R")" = 3 ] && [ "$(lists "$R" snap)" = 0 ] \
  && ok "R4 no pr-snapshot.sh: 3 live reads, rc 0" || bad "R4 rc=$RC out=$OUT reads: $(grep pulls "$R/gh.calls")"
grep -q 'pr-snapshot' "$R/err.txt" && bad "R4 an error names pr-snapshot: $(cat "$R/err.txt")" || ok "R4 no error about the missing lib"
three "$R" R4

R="$T/r5"; rtree "$R" || exit 1
mkdir -p "$R/state/pr-snapshot/o_fx"; echo '[]' > "$R/state/pr-snapshot/o_fx/open.json"
date +%s > "$R/state/pr-snapshot/o_fx/open.meta"
XENV=(HPL_SNAPSHOT=1 DRV_SECTIONS=leadunqueued DRV_BLOCKS=lu); drive "$R"
[ "$OUT" = "HPL=unset CAP=100" ] && ok "R5 --sections: the inherited HPL_SNAPSHOT is unset" || bad "R5 rc=$RC out=$OUT"
[ "$(lists "$R" raw)" = 1 ] && [ "$(lists "$R")" = 1 ] && ok "R5 a live read despite a fresh open.json" || bad "R5 reads: $(grep pulls "$R/gh.calls")"
alerted "$R" "leadunqueued:o/fx#7:" && ok "R5 #7 paged from the live list (the cached one is empty)" || bad "R5 alerts: $(cat "$R/alerts.txt")"

R="$T/r6"; rtree "$R" || exit 1
XENV=(DRV_SECTIONS=stalepr,leadunqueued "DRV_BLOCKS=stalepr lu"); drive "$R"
[ "$OUT" = "HPL=unset CAP=100" ] && [ "$(lists "$R" stalepr)" = 1 ] && [ "$(lists "$R" raw)" = 1 ] && [ "$(lists "$R" snap)" = 0 ] \
  && ok "R6 --sections stalepr,leadunqueued: live for both" || bad "R6 out=$OUT reads: $(grep pulls "$R/gh.calls")"
[ ! -e "$R/state/pr-snapshot/o_fx/open.json" ] && ok "R6 no snapshot written" || bad "R6 wrote open.json"

R="$T/f1"; rtree "$R" || exit 1
touch "$R/list403"
XENV=(); drive "$R"
[ "$RC" = 0 ] && [ "$OUT" = "HPL=1 CAP=1000" ] && ok "F1 rc 0, snapshot on" || bad "F1 rc=$RC out=$OUT"
[ ! -s "$R/alerts.txt" ] && ok "F1 no page on a failed list" || bad "F1 alerts: $(cat "$R/alerts.txt")"
grep -qx '+=stalepr:fx' "$R/fired.txt" && grep -qx 'staleparent:fx:9' "$R/fired.txt" \
  && grep -qx '+^leadunqueued:o/fx#' "$R/fired.txt" && grep -qx '+^leadunqueued:o/fx:' "$R/fired.txt" \
  && ok "F1 every section carried its keys" || bad "F1 FIRED: $(cat "$R/fired.txt")"
[ ! -e "$R/state/pr-snapshot/o_fx/open.json" ] && ok "F1 no open.json written" || bad "F1 open.json: $(cat "$R/state/pr-snapshot/o_fx/open.json")"
[ "$(lists "$R" raw)" = 0 ] && [ "$(lists "$R" stalepr)" = 0 ] && ok "F1 no live read in place of the failed one" || bad "F1 reads: $(grep pulls "$R/gh.calls")"

R="$T/p1"; rtree "$R" || exit 1
prs 120 101 > "$R/prs.json"
XENV=(); drive "$R"
grep -q 'page-cut' "$R/alerts.txt" && bad "P1 a page-cut page: $(grep page-cut "$R/alerts.txt")" || ok "P1 120 rows under the snapshot: no page-cut"
grep -qx 7 "$R/spr.log" && [ "$(grep -c . "$R/spr.log")" = 20 ] && ok "P1 rows 101-120 judged (PR 7 is row 120)" || bad "P1 judged: $(tr '\n' ' ' < "$R/spr.log")"
[ "$(grep -cE 'repos/o/fx/pulls -f state=open' "$R/gh.calls")" = 2 ] && [ "$(lists "$R")" = 1 ] \
  && ok "P1 one list read of 2 pages" || bad "P1 reads: $(grep pulls "$R/gh.calls")"

R="$T/p2"; rtree "$R" || exit 1
prs 100 1 > "$R/prs.json"
XENV=(PR_SNAPSHOT=0 STALE_PARENT_MAX_PRS=100); drive "$R"
grep -q '^staleparent:fx:page-cut|fx: the stale-parent check read a full page of 100 open PRs' "$R/alerts.txt" \
  && ok "P2 snapshot off, 100 rows: the page-cut page names 100" || bad "P2 alerts: $(grep page-cut "$R/alerts.txt")"

R="$T/p3"; rtree "$R" || exit 1
prs 1000 991 > "$R/prs.json"
XENV=(); drive "$R"
grep -q '^staleparent:fx:page-cut|fx: the stale-parent check read a full page of 1000 open PRs' "$R/alerts.txt" \
  && ok "P3 1000 rows under the snapshot: the page-cut page names 1000" || bad "P3 alerts: $(grep page-cut "$R/alerts.txt")"
[ "$(grep -cE 'repos/o/fx/pulls -f state=open' "$R/gh.calls")" = 10 ] && ok "P3 the list read 10 pages" || bad "P3 pages: $(grep -c 'pulls -f' "$R/gh.calls")"

echo
echo "pipeline-health-open-list.bh-7616: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
