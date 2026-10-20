#!/bin/bash
# tests/pipeline-health-open-list-rest.bh-7616-test.sh — BH-7616 (C2): the
# starved-project and stall-alerts reads of "$DIR/bin/pipeline-health.sh" take
# o/fx's open-PR list from the shared snapshot "$DIR/bin/lib/pr-snapshot.sh"
# through ph_open_rows, cut to today's cap (100, 200).
#
#   H1..H5  ph_open_rows from the `# >>> open list` block, with stubs:
#           H1 HPL_SNAPSHOT=1 reads the snapshot; H2 unset and H3 0/true read
#           gh_rest_pr_list_all <slug> open <max>; H4 the cut to <max> rows;
#           H5 a failed snapshot read gives its rc, no output, no temp file
#   E1      the REAL script, --project fx, snapshot on, starved fires and the
#           stall block reaches its list read: 1 open-PR list read of o/fx
#   E2      the same run with PR_SNAPSHOT=0: 3 live reads, the same starved page
#   E3      E1 with a fresh open.json in the snapshot dir: 0 list reads
#   M1      a copy whose stall read is gh_rest_pr_list_all: 2 reads in E1's run
#   X1      the `# >>> starved project` fallback line alone: today's call
#   X2      the `# >>> stall alerts` block alone, the list read answers 403:
#           the judge gets '?', the pair key is carried in $FIRED
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pipeline-health-open-list-rest.bh-7616-test.sh
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
  PR_SNAPSHOT PR_SNAPSHOT_TTL_S PR_SNAPSHOT_QUIET_TTL_S PR_SNAPSHOT_FEED_STALE_S PR_SNAPSHOT_LIB PRS_COUNT_FILE \
  STALL_HOLD_CHECK STALL_PARENT_CHECK STALL_MAX_THREADS STALL_OWNER_WINDOW_H STALL_PARENT_MERGED_H
mkdir -p "$T/fakebin" "$T/stub" "$T/tmp"
HARNESS_TEST_SANDBOX=1 "$REPO/bin/lanes-build.sh" --root "$REPO" --to "$T/lanes.json" >/dev/null 2>&1 \
  || { echo "FAIL: bin/lanes-build.sh could not compose the registry"; exit 1; }
blk() { awk -v s="$1" -v e="$2" 'index($0, s) == 1 {f=1; next} index($0, e) == 1 {exit} f' "$PHS"; }

# rows <n> — n open-PR rows in REST shape, numbers n..1 (created desc).
rows() {
  jq -nc --argjson n "$1" '[range(0; $n) as $i | {number: ($n - $i), title: "FX", body: "",
    head: {ref: "b", sha: ("f" * 39 + "0")}, base: {ref: "main"}, state: "open"}]'
}

# ============================================================================
echo "H1-H5: ph_open_rows"
blk '# >>> open list (BH-7616)' '# <<< open list' > "$T/b-open.sh"
[ -s "$T/b-open.sh" ] && grep -q '^ph_open_rows()' "$T/b-open.sh" && ok "the open-list block defines ph_open_rows" \
  || bad "no ph_open_rows in the # >>> open list block"
# hcall <tmpdir> <slug> <max> — ph_open_rows in a fresh shell: the block, then
# stubs that log each read. HSNAP lines: the snapshot rows (or HSNAP_RC).
hcall() {
  local td="$1"; shift
  mkdir -p "$td"; : > "$T/h.log"
  ( H="$T/no-harness"; PH_SECTIONS=""; TMPDIR="$td"
    # shellcheck disable=SC1090
    . "$T/b-open.sh"
    prs_open_list() { echo "prs_open_list $1" >> "$T/h.log"; [ "${HSNAP_RC:-0}" = 0 ] || return "$HSNAP_RC"; cat "$T/snap.json" > "$2"; }
    gh_rest_pr_list_all() { echo "gh_rest_pr_list_all $*" >> "$T/h.log"; echo '[{"number":99}]'; }
    [ "${HSNAP-unset}" = unset ] && unset HPL_SNAPSHOT || HPL_SNAPSHOT="$HSNAP"
    ph_open_rows "$@" ) > "$T/h.out" 2> "$T/h.err"
  HRC=$?
}
rows 3 > "$T/snap.json"
HSNAP=1; hcall "$T/h1" o/fx 100
[ "$HRC" = 0 ] && [ "$(jq -c '[.[].number]' "$T/h.out")" = '[3,2,1]' ] && ok "H1 HPL_SNAPSHOT=1: the 3 snapshot rows" \
  || bad "H1 rc=$HRC out=$(cat "$T/h.out") err=$(cat "$T/h.err")"
[ "$(cat "$T/h.log")" = "prs_open_list o/fx" ] && ok "H1 one snapshot read, gh_rest_pr_list_all not called" || bad "H1 calls: $(cat "$T/h.log")"
unset HSNAP; hcall "$T/h2" o/fx 200
[ "$HRC" = 0 ] && [ "$(cat "$T/h.out")" = '[{"number":99}]' ] && [ "$(cat "$T/h.log")" = "gh_rest_pr_list_all o/fx open 200" ] \
  && ok "H2 unset: gh_rest_pr_list_all o/fx open 200, its output, no snapshot read" || bad "H2 rc=$HRC out=$(cat "$T/h.out") calls: $(cat "$T/h.log")"
for v in 0 true; do
  HSNAP=$v; hcall "$T/h3$v" o/fx 100
  [ "$HRC" = 0 ] && [ "$(cat "$T/h.out")" = '[{"number":99}]' ] && [ "$(cat "$T/h.log")" = "gh_rest_pr_list_all o/fx open 100" ] \
    && ok "H3 HPL_SNAPSHOT=$v: today's read" || bad "H3 $v: rc=$HRC calls: $(cat "$T/h.log")"
done
rows 120 > "$T/snap.json"
HSNAP=1; hcall "$T/h4a" o/fx 100
[ "$HRC" = 0 ] && [ "$(jq 'length' "$T/h.out")" = 100 ] && [ "$(jq -c '[.[0].number, .[99].number]' "$T/h.out")" = '[120,21]' ] \
  && ok "H4 120 rows, max 100: rows 1-100 in snapshot order" || bad "H4 rc=$HRC rows: $(jq -c '[length, .[0].number, .[-1].number]' "$T/h.out" 2>&1)"
rows 50 > "$T/snap.json"
hcall "$T/h4b" o/fx 200
[ "$HRC" = 0 ] && [ "$(jq 'length' "$T/h.out")" = 50 ] && ok "H4 50 rows, max 200: all 50" || bad "H4 rc=$HRC rows: $(jq 'length' "$T/h.out" 2>&1)"
HSNAP=1; HSNAP_RC=75; hcall "$T/h5" o/fx 100; unset HSNAP_RC
[ "$HRC" = 75 ] && [ ! -s "$T/h.out" ] && ok "H5 a failed snapshot read: rc 75, nothing on stdout" || bad "H5 rc=$HRC out=$(cat "$T/h.out")"
[ -z "$(ls -A "$T/h5")" ] && ok "H5 no ph-open temp file left" || bad "H5 left: $(ls -A "$T/h5")"
grep -q gh_rest_pr_list_all "$T/h.log" && bad "H5 a live read in place of the failed one" || ok "H5 no live read in its place"
printf 'not json' > "$T/snap.json"
hcall "$T/h5b" o/fx 100
[ "$HRC" = 75 ] && [ ! -s "$T/h.out" ] && [ -z "$(ls -A "$T/h5b")" ] && ok "H5 a corrupt snapshot: rc 75, no output, no temp file" \
  || bad "H5 corrupt: rc=$HRC out=$(cat "$T/h.out") left: $(ls -A "$T/h5b")"

# ============================================================================
echo "E1-E3, M1: the real script, --project fx"
cat > "$T/stub/jobs-client.sh" <<'EOF'
# shellcheck shell=bash
# The jobs ledger is empty: no build row, no queue row. Every other read fails.
_jobs_req() { case "${2:-}" in /api/jobs\?*) echo '{"jobs":[]}' ;; *) return 1 ;; esac; }
_jobs_req_file() { return 1; }
queue_list() { return 0; }
setting_get() { return 1; }
_jobs_box_name() { echo fixture-box; }
EOF
cat > "$T/stub/beat.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "${1:-}" >> "$HARNESS/beat.log"
exit 0
EOF
printf '#!/bin/bash\nexit 1\n' > "$T/stub/queued-fly-relayed.sh"
chmod +x "$T/stub/beat.sh" "$T/stub/queued-fly-relayed.sh"

# gh: one call a line in <tree>/gh.calls. <tree>/prs.json holds o/fx's open
# PRs, <tree>/issues.json its ai-build issues. Every list read of either is one
# page of 100 rows. <tree>/list403 present: the PR list answers 403.
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
A="$*"
echo "$A" >> "$HARNESS/gh.calls"
pg=1; [[ " $A " =~ [\&\ ]page=([0-9]+) ]] && pg="${BASH_REMATCH[1]}"
page() { jq -c --argjson p "$pg" '.[($p - 1) * 100 : $p * 100]' "$1"; }
case "$A" in
  "api repos/"*" -q .id") exit 0 ;;
  *"api rate_limit"*)
    printf '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"-i "*"repos/o/fx/pulls -f state=open"*|*"-i "*"repos/o/fx/pulls?state=open"*)
    if [ -e "$HARNESS/list403" ]; then printf 'HTTP/2 403\r\nx-ratelimit-remaining: 0\r\n\r\n{"message":"API rate limit exceeded"}\n'; exit 0; fi
    printf 'HTTP/2 200\r\n\r\n'; page "$HARNESS/prs.json" ;;
  "api repos/o/fx/pulls?state=open&per_page=100") page "$HARNESS/prs.json" ;;
  *"-i "*"repos/o/fx/issues -f state="*)
    printf 'HTTP/2 200\r\n\r\n'; page "$HARNESS/issues.json" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/fakebin/gh"

# The fixture: #20 open, launchable (no blocker, no PR names it); #21 open with
# a hard Blocked-by on #20, so starved names #20 only and the stall block
# reaches its list read for the pair 21:20. One open PR, #7, on branch b.
mktree() {
  local d="$1"
  mkdir -p "$d/bin/lib" "$d/logs" "$d/state" "$d/flags" "$d/env" "$d/locks" "$d/prompts" || return 1
  cp "$T/stub/beat.sh" "$T/stub/queued-fly-relayed.sh" "$T/stub/jobs-client.sh" "$d/bin/" || return 1
  scratch_install_closure bin/pipeline-health.sh "$d" >/dev/null || return 1
  scratch_install_closure bin/alert-line.sh "$d" >/dev/null || return 1
  # The starved block reads the board prefix through "$H/bin/fleet-conf.sh".
  scratch_install_closure bin/fleet-conf.sh "$d" >/dev/null || return 1
  printf 'fx o/fx - - 2 box\n' > "$d/fleet.conf"
  printf 'run-build.sh fx <issue-number> FX-<issue-number>\n' > "$d/prompts/fx.md"
  : > "$d/env/global.env"; : > "$d/alerts.conf"; : > "$d/gh.calls"
  touch "$d/flags/remediation-disabled"
  jq -nc '[{number: 7, created_at: "2026-09-10T00:00:00Z", updated_at: "2026-09-10T00:00:00Z", title: "FX", draft: false,
            state: "open", merged_at: null, closed_at: null, body: "", labels: [], html_url: "https://github.com/o/fx/pull/7",
            head: {ref: "b", sha: ("f" * 39 + "0"), repo: {full_name: "o/fx"}},
            base: {ref: "main", repo: {full_name: "o/fx", default_branch: "main"}}, user: {login: "operator", type: "User"}}]' > "$d/prs.json"
  jq -nc '[{number: 21, state: "open", title: "FX-21: child", body: "Blocked-by: #20 (hard)", labels: [{name: "ai-build"}],
            html_url: "https://github.com/o/fx/issues/21"},
           {number: 20, state: "open", title: "FX-20: parent", body: "", labels: [{name: "ai-build"}],
            html_url: "https://github.com/o/fx/issues/20"}]' > "$d/issues.json"
}
# lists <tree> — open-PR list reads of o/fx, any shape, first pages only.
lists() { grep -E 'repos/o/fx/pulls( |\?)' "$1/gh.calls" | grep -cvE '[&= ]page=([2-9]|10)( |$)'; }
envrun() { # envrun <tree> <script> [args...] — the env a hub project run gets
  local d="$1"; shift
  ( cd "$d" && env PATH="$T/fakebin:$PATH" HARNESS="$d" GH_BUDGET_TTL_S=0 ALERTS_CONF="$d/alerts.conf" \
      FLEET_CONF="$d/fleet.conf" LANE_GATE_DISABLE=1 HARNESS_ENV_DIR="$d/env" GH_BUDGET_CORE_REMAINING=4000 \
      HUB_REPOS="$T/no-repos" LANE_REGISTRY="$T/lanes.json" TMPDIR="$T/tmp" GH_ETAG=0 \
      HARNESS_PR_AUTHORS=operator LEAD_REVIEW_AUTO_REPOS=o/fx ${XENV[@]+"${XENV[@]}"} "$@" ) > "$d/out.txt" 2> "$d/err.txt"
  RC=$?
}
starved() { # starved <tree> — 1 when the starved page for fx names #20 and not #21
  local pg; pg="$(grep '"akey":"health:starved:fx"' "$1/beat.log" 2>/dev/null)"
  grep -q '#20 ' <<<"$pg" && ! grep -q '#21' <<<"$pg"
}
stallread() { # stallread <tree> — 1 when the stall block judged the pair 21:20
  grep -q 'repos/o/fx/issues/20' "$1/gh.calls"
}

E1="$T/e1"; mktree "$E1" || exit 1
XENV=(); envrun "$E1" "$E1/bin/pipeline-health.sh" --project fx
[ "$RC" = 0 ] && ok "E1 rc 0" || bad "E1 rc=$RC: $(tail -5 "$E1/err.txt")"
starved "$E1" && ok "E1 the starved page names #20" || bad "E1 beat: $(cat "$E1/beat.log" 2>/dev/null) err: $(tail -3 "$E1/err.txt")"
stallread "$E1" && ok "E1 the stall block judged parent #20" || bad "E1 no stall judge read: $(grep -v rate_limit "$E1/gh.calls")"
[ "$(lists "$E1")" = 1 ] && ok "E1 one open-PR list read of o/fx (before: 3)" || bad "E1 $(lists "$E1") list reads: $(grep pulls "$E1/gh.calls")"
grep -q 'list failed\|skipped this tick' "$E1/logs/pipeline-health.log" && bad "E1 a read failed: $(grep -i 'failed\|skipped' "$E1/logs/pipeline-health.log")" \
  || ok "E1 no list read failed in the run log"
[ -s "$E1/state/pr-snapshot/o_fx/open.json" ] && ok "E1 the snapshot holds o/fx's list" || bad "E1 no state/pr-snapshot/o_fx/open.json"

E2="$T/e2"; mktree "$E2" || exit 1
XENV=(PR_SNAPSHOT=0); envrun "$E2" "$E2/bin/pipeline-health.sh" --project fx
[ "$RC" = 0 ] && ok "E2 rc 0" || bad "E2 rc=$RC: $(tail -5 "$E2/err.txt")"
[ "$(lists "$E2")" = 3 ] && [ "$(grep -cE '^api -i -X GET repos/o/fx/pulls -f state=open' "$E2/gh.calls")" = 2 ] \
  && ok "E2 PR_SNAPSHOT=0: 3 live reads (stalepr, starved, stall)" || bad "E2 reads: $(grep pulls "$E2/gh.calls")"
[ ! -e "$E2/state/pr-snapshot" ] && ok "E2 no snapshot dir" || bad "E2 wrote state/pr-snapshot"
starved "$E2" && ok "E2 the same starved page (output parity)" || bad "E2 beat: $(cat "$E2/beat.log" 2>/dev/null)"
stallread "$E2" && ok "E2 the stall block judged parent #20" || bad "E2 no stall judge read"

E3="$T/e3"; mktree "$E3" || exit 1
mkdir -p "$E3/state/pr-snapshot/o_fx"; cp "$E3/prs.json" "$E3/state/pr-snapshot/o_fx/open.json"
date +%s > "$E3/state/pr-snapshot/o_fx/open.meta"
XENV=(); envrun "$E3" "$E3/bin/pipeline-health.sh" --project fx
[ "$RC" = 0 ] && [ "$(lists "$E3")" = 0 ] && ok "E3 a fresh open.json: 0 list reads" || bad "E3 rc=$RC reads: $(grep pulls "$E3/gh.calls")"
starved "$E3" && stallread "$E3" && ok "E3 the same starved page and stall judge" || bad "E3 beat: $(cat "$E3/beat.log" 2>/dev/null)"

M1="$T/m1"; mktree "$M1" || exit 1
[ "$(grep -c 'ph_open_rows "$SLUG" 200' "$M1/bin/pipeline-health.sh")" = 2 ] && ok "M1 the 2 stall reads call ph_open_rows" \
  || bad "M1 the stall block does not call ph_open_rows \"\$SLUG\" 200 twice"
sed -i 's|ph_open_rows "$SLUG" 200|gh_rest_pr_list_all "$SLUG" open 200|' "$M1/bin/pipeline-health.sh"
XENV=(); envrun "$M1" "$M1/bin/pipeline-health.sh" --project fx
[ "$RC" = 0 ] && [ "$(lists "$M1")" = 2 ] && ok "M1 a live stall read: 2 reads (E1 depends on the call)" || bad "M1 rc=$RC reads: $(lists "$M1")"

# ============================================================================
echo "X1-X2: the blocks alone keep today's read"
blk '# >>> starved project' '# <<< starved project' > "$T/b-starved.sh"
FBL=$(head -n 1 "$T/b-starved.sh")
case "$FBL" in "command -v ph_open_rows "*) ok "X1 the starved block opens with the fallback" ;; *) bad "X1 first line: $FBL" ;; esac
grep -q 'if ! ph_open_rows "$SSLUG" 100 > "$SPF"' "$T/b-starved.sh" && ok "X1 the starved read is ph_open_rows <slug> 100" || bad "X1 no ph_open_rows read in the starved block"
X1OUT=$( unset -f ph_open_rows; gh_rest_pr_list_all() { echo "gh_rest_pr_list_all $*"; }; eval "$FBL"; ph_open_rows o/fx 100 )
[ "$X1OUT" = "gh_rest_pr_list_all o/fx open 100" ] && ok "X1 no open-list block: the fallback is today's call" || bad "X1 got: $X1OUT"

blk '# >>> stall alerts (BH-6308)' '# <<< stall alerts' > "$T/b-stall.sh"
[ -s "$T/b-stall.sh" ] && ok "X2 the stall block extracted" || bad "X2 no # >>> stall alerts block"
X="$T/x2"; mkdir -p "$X/bin/lib" "$X/tmp"
scratch_install_closure bin/lib/gh-rest-list.sh "$X" >/dev/null || bad "X2 the gh-rest-list closure did not install"
# A stall lib that judges only the parent check; its judge keeps the real
# contract for an unreadable PR list ('?' is rc 2, unknown).
cat > "$X/bin/lib/stall-alerts.sh" <<'EOF'
# shellcheck shell=bash
stall_knob() { case "$1" in STALL_HOLD_CHECK) echo 0 ;; STALL_PARENT_CHECK) echo 1 ;; STALL_MAX_THREADS) echo 30 ;; *) echo 12 ;; esac; }
stall_hard_blockers() { grep -oE '#[0-9]+ \(hard\)' <<<"$1" | grep -oE '[0-9]+'; }
stall_parent_judge() { echo "$7" > "$HARNESS/judge-prs.txt"; [ "$7" = '?' ] && { printf 'unknown\tPRs unreadable\n'; return 2; }; printf 'ok\tpr\n'; return 1; }
EOF
cp "$E1/issues.json" "$X/issues.json"; cp "$E1/prs.json" "$X/prs.json"; touch "$X/list403"; : > "$X/gh.calls"
printf 'fx o/fx - - 2 box\n' > "$X/fleet.conf"
printf '%s\n' 'stalledblocker:fx:21:20' 'stalehold:fx:5' > "$X/active.txt"; : > "$X/fired.txt"; : > "$X/alerts.txt"
cat > "$T/x2drive.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
H="$HARNESS"; PROJECTS=fx; NOW=$(date -u +%s); FIRED="$H/fired.txt"; ACTIVE="$H/active.txt"
. "$H/bin/lib/gh-rest-list.sh" || exit 98
gh_budget_low() { return 1; }
preplan_key_prefix() { echo FX; }
alert() { printf '%s|%s\n' "$2" "$3" >> "$H/alerts.txt"; }
[ -n "${X2_OPEN:-}" ] && { PH_SECTIONS=""; . "$X2_OPEN"; }
command -v ph_open_rows >/dev/null 2>&1 && echo "ph_open_rows before the block" >> "$H/x2.log"
. "$X2_BLOCK"
echo "STPRS=$STPRS"
EOF
( cd "$X" && env PATH="$T/fakebin:$PATH" HARNESS="$X" TMPDIR="$X/tmp" GH_ETAG=0 X2_BLOCK="$T/b-stall.sh" \
    bash "$T/x2drive.sh" ) > "$X/out.txt" 2> "$X/err.txt"
X2RC=$?
[ "$X2RC" = 0 ] && [ "$(tail -n 1 "$X/out.txt")" = "STPRS=?" ] && ok "X2 a 403 list read: STPRS is '?'" || bad "X2 rc=$X2RC out=$(cat "$X/out.txt") err=$(tail -3 "$X/err.txt")"
[ ! -e "$X/x2.log" ] && grep -qE 'repos/o/fx/pulls -f state=open' "$X/gh.calls" && ok "X2 the block's fallback made today's REST read" \
  || bad "X2 reads: $(grep pulls "$X/gh.calls")"
[ "$(cat "$X/judge-prs.txt" 2>/dev/null)" = '?' ] && ok "X2 the judge got '?'" || bad "X2 judge prs: $(cat "$X/judge-prs.txt" 2>/dev/null)"
grep -qx 'stalledblocker:fx:21:20' "$X/fired.txt" && ok "X2 the pair key is carried in \$FIRED" || bad "X2 FIRED: $(cat "$X/fired.txt")"
[ ! -s "$X/alerts.txt" ] && ok "X2 no page on a failed list" || bad "X2 alerts: $(cat "$X/alerts.txt")"
# X2b: the same 403 with the open-list block loaded and the snapshot on.
rm -f "$X/judge-prs.txt"; : > "$X/fired.txt"; : > "$X/gh.calls"
scratch_install_closure bin/lib/pr-snapshot.sh "$X" >/dev/null || bad "X2b the pr-snapshot closure did not install"
( cd "$X" && env PATH="$T/fakebin:$PATH" HARNESS="$X" TMPDIR="$X/tmp" GH_ETAG=0 X2_BLOCK="$T/b-stall.sh" \
    X2_OPEN="$T/b-open.sh" LANE_REGISTRY="$T/lanes.json" LANE_GATE_DISABLE=1 bash "$T/x2drive.sh" ) > "$X/out.txt" 2> "$X/err.txt"
X2RC=$?
[ "$X2RC" = 0 ] && [ "$(tail -n 1 "$X/out.txt")" = "STPRS=?" ] && [ "$(cat "$X/judge-prs.txt" 2>/dev/null)" = '?' ] \
  && grep -qx 'stalledblocker:fx:21:20' "$X/fired.txt" && ok "X2b snapshot on, 403: STPRS '?', the pair key carried" \
  || bad "X2b rc=$X2RC out=$(cat "$X/out.txt") FIRED=$(cat "$X/fired.txt") err=$(tail -3 "$X/err.txt")"
[ "$(grep -cE 'repos/o/fx/pulls -f state=open' "$X/gh.calls")" = 1 ] && [ -z "$(ls -A "$X/tmp" | grep '^ph-open\.')" ] \
  && ok "X2b one snapshot read, no ph-open temp file left" || bad "X2b reads: $(grep pulls "$X/gh.calls") tmp: $(ls -A "$X/tmp")"

echo
echo "pipeline-health-open-list-rest.bh-7616: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
