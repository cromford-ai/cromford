#!/bin/bash
# tests/pr-owner-done-guard.bh-6815-test.sh — BH-6815: the sweep never closes a
# done-ticket PR whose change is not on main, nor one that is held, armed or
# recently active. Driven through the REAL bin/pr-owner-sweep.sh and the REAL
# bin/pr-owner-close-replay.sh; the pure checks through bin/lib/pr-owner/shipped.sh.
#
#   S1-S6  the three guarded close paths, fail closed, rule 3 untouched
#   D1-D4  labels, conductor state, recency, the shipped matrix
#   M1-M2  the shipped memo: reuse on (head, main), the 200-row bound, no root
#   K1     the three knobs: fragments, defaults, env overrides
#   Y1     the guard runs under PR_OWNER_DRY_RUN=1
#   G1     superseded.sh with no guard lib declines rules 1 and 2
#   R1     the 7-day replay of sweep closes
#
# gh and curl are PATH shims: no network, no secrets. GitHub writes land in
# $H/writes.log (`COMMENT <n> <body>`, `CLOSE <n>`); the guard's reads land in
# $H/reads.log (`FILES <n>`, `MAIN`, `CONTENTS <path>`).
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pr-owner-done-guard.bh-6815-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/logs" "$H/locks" "$H/state/merge-conductor" "$H/state/pr-owners" "$H/flags" "$H/env" "$H/fixture" "$T/fakebin"
scratch_install_closure bin/pr-owner-sweep.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
scratch_install_closure bin/pr-owner-close-replay.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
scratch_install_closure bin/lib/hub-box.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/alert-line.sh" "$H/bin/"
printf 'HARNESS_SECRET=fixture-secret\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
cat > "$H/fleet.conf" <<'CONF'
project-4 example-org/project-4 https://os.test /api/board
cromford example-org/cromford - -
CONF
printf '#!/bin/bash\necho tok-fixture-%s\n' '$1' > "$H/bin/internal-token-for.sh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/internal-token-for.sh" "$H/bin/lane-alert.sh"

cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
R="${FIX_ROOT:-$HARNESS}"; F="$R/fixture"
resp() { printf 'HTTP/2.0 %s X\r\ncontent-type: application/json\r\n\r\n%s\n' "$1" "$2"; }
case "$1 $2" in
  "api rate_limit") printf '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":1},"graphql":{"remaining":4000,"limit":5000,"reset":1}}}\n'; exit 0 ;;
  "api repos/"*) case "$*" in *--paginate*) exit 1 ;; esac
    # hold_check's plain issue read answers the issue, as GitHub does (the
    # superseded hook reads an issues-board ticket's hold, BH-6814). A 404 is
    # gh's non-zero exit.
    case "$#:$2" in 2:repos/*/issues/*)
      n="${2##*/}"; [ "$(cat "$F/issue-$n.code" 2>/dev/null || echo 404)" = 200 ] || exit 1
      cat "$F/issue-$n.json"; exit 0 ;;
    esac
    echo 1234; exit 0 ;;
  # hold_check's comments read: the ticket's thread.
  "api --paginate") case "$3" in repos/*/issues/*/comments*)
      n="${3%/comments*}"; n="${n##*/}"; cat "$F/thread-$n.json" 2>/dev/null || echo '[]'; exit 0 ;; esac; exit 1 ;;
esac
case "$*" in
  *"pr list"*"--state open"*)   cat "$F/open.json"; exit 0 ;;
  *"pr list"*"--state merged"*) cat "$F/merged.json"; exit 0 ;;
esac
[ "$1 $2 $3" = "api -i -X" ] || exit 1
M="$4"; P="$5"; shift 5
printf '%s %s\n' "$M" "$P" >> "$R/calls.log"
mainsha() { cat "$F/main.sha" 2>/dev/null || printf 'a%039d' 0; }
case "$M $P" in
  "GET repos/"*/issues/comments*)
    resp "$(cat "$F/repo-comments.code" 2>/dev/null || echo 200)" "$(cat "$F/repo-comments.json" 2>/dev/null || echo '[]')" ;;
  "GET repos/"*/issues/*/comments*)
    n="${P%/comments*}"; n="${n##*/}"
    resp 200 "$(cat "$F/thread-$n.json" 2>/dev/null || echo '[]')" ;;
  "GET repos/"*/issues/*/events*)
    n="${P%/events*}"; n="${n##*/}"
    resp 200 "$(cat "$F/events-$n.json" 2>/dev/null || echo '[]')" ;;
  "GET repos/"*/issues/*)
    n="${P##*/}"; c=$(cat "$F/issue-$n.code" 2>/dev/null || echo 404)
    resp "$c" "$(cat "$F/issue-$n.json" 2>/dev/null || echo '{"message":"Not Found"}')" ;;
  "GET repos/"*/pulls/*/files*)
    n="${P%/files*}"; n="${n##*/}"; echo "FILES $n" >> "$R/reads.log"
    resp "$(cat "$F/files-$n.code" 2>/dev/null || echo 200)" "$(cat "$F/files-$n.json" 2>/dev/null || echo '[]')" ;;
  "GET repos/"*/pulls/*/commits*)
    n="${P%/commits*}"; n="${n##*/}"
    resp 200 "$(cat "$F/prcommits-$n.json" 2>/dev/null || echo '[]')" ;;
  "GET repos/"*/commits/HEAD)
    echo "MAIN" >> "$R/reads.log"
    resp "$(cat "$F/main.code" 2>/dev/null || echo 200)" "{\"sha\":\"$(mainsha)\",\"commit\":{}}" ;;
  "GET repos/"*/commits\?*)
    resp 200 "$(cat "$F/main-at.json" 2>/dev/null || echo "[{\"sha\":\"$(mainsha)\"}]")" ;;
  "GET repos/"*/contents/*)
    p="${P#*/contents/}"; p="${p%%\?*}"
    p=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.unquote(sys.argv[1]))' "$p")
    echo "CONTENTS $p" >> "$R/reads.log"
    c=$(awk -F'\t' -v p="$p" '$1==p {print $2; exit}' "$F/contents-code.tsv" 2>/dev/null)
    s=$(awk -F'\t' -v p="$p" '$1==p {print $2; exit}' "$F/main-blobs.tsv" 2>/dev/null)
    if [ -n "$c" ]; then resp "$c" '{"message":"boom"}'
    elif [ "$s" = DIR ]; then resp 200 '[{"name":"x","sha":"fixture"}]'
    elif [ -n "$s" ]; then resp 200 "{\"type\":\"file\",\"path\":\"$p\",\"sha\":\"$s\"}"
    else resp 404 '{"message":"Not Found"}'; fi ;;
  "POST repos/"*/comments)
    n="${P%/comments}"; n="${n##*/}"; b=""
    for a in "$@"; do case "$a" in body=@*) b=$(cat "${a#body=@}") ;; esac; done
    printf 'COMMENT %s %s\n' "$n" "$(printf '%s' "$b" | tr '\n' ' ')" >> "$R/writes.log"
    resp 201 '{"id":1}' ;;
  "PATCH repos/"*/pulls/*)
    n="${P##*/}"
    printf 'CLOSE %s\n' "$n" >> "$R/writes.log"; touch "$F/closed-$n"
    resp 200 '{"state":"closed"}' ;;
  # TEST-CHANGE (BH-6929 merge): the close-duplicate arm and rules 1 and 3 run
  # po_dup_guard too, which reads latestReviews (pr() sets []) and compares the
  # heads of same-key PRs. Diverged heads are not a stack, so the guard clears.
  "GET repos/"*/compare/*)
    resp 200 '{"status":"diverged","ahead_by":1,"behind_by":1}' ;;
  "GET repos/"*/pulls/*)
    n="${P##*/}"
    if [ -f "$F/pr-$n.json" ]; then resp 200 "$(cat "$F/pr-$n.json")"
    elif [ -f "$F/closed-$n" ]; then resp 200 '{"state":"closed","merged_at":null}'
    else resp 200 '{"state":"open","merged_at":null}'; fi ;;
  *) resp 404 '{}' ;;
esac
exit 0
SH

cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"; M=GET; F="$HARNESS/fixture"
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
case "$M $URL" in
  "GET https://jobs.test/api/jobs"*)  printf '%s\n200\n' "$(cat "$F/jobs.json")" ;;
  "GET https://jobs.test/api/queue"*) printf '{"queue":[]}\n200\n' ;;
  "GET https://jobs.test/"*) printf '{"error":"none"}\n404\n' ;;
  "GET https://os.test/api/board/boards") printf '[{"id":"b1"}]\n200\n' ;;
  "GET https://os.test/api/board/boards/"*/tickets) printf '%s\n200\n' "$(cat "$F/tickets.json" 2>/dev/null || echo '[]')" ;;
  *) printf '{"ok":true}\n200\n' ;;
esac
SH
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"
export BOX_NAME=box-hub HUB_BOX_NAME=box-hub FIX_ROOT="$H"

# ONE pinned clock (D60): every fixture date is relative to NOW0.
NOW0=1760500000
D=86400
ISO() { date -u -d "@$(( NOW0 - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }
OLD=$(ISO $((3*D)))
SHA() { printf '%s%039d' "$1" "$2"; }   # a 40-char fixture sha
H1=$(SHA b 1); M1=$(SHA c 1); H2=$(SHA b 2); M2=$(SHA c 2)
# pr <num> <title> <branch> <author> [label] [updatedAt]
pr() {
  jq -nc --argjson n "$1" --arg t "$2" --arg b "$3" --arg a "$4" --arg l "${5:-}" --arg u "${6:-$OLD}" --arg old "$OLD" --arg slug "$SLUG" \
    '{number:$n,title:$t,headRefName:$b,headRefOid:("\($n)"+("0"*39))[0:40],author:{login:$a},
      labels:(if $l == "" then [] else [{name:$l}] end),body:"",mergeable:"MERGEABLE",latestReviews:[],
      updatedAt:$u,createdAt:$old,url:"https://github.com/\($slug)/pull/\($n)",isDraft:false}'
}
merged() { jq -nc --argjson n "$1" --arg t "$2" --arg b "$3" --arg m "$(ISO $D)" '{number:$n,title:$t,headRefName:$b,url:"x",mergedAt:$m,author:{login:"operator"}}'; }
setup() {
  SLUG="$1"
  scratch_rm "$H/fixture" || exit 1; scratch_rm "$H/logs" || exit 1; scratch_rm "$H/locks" || exit 1
  scratch_rm "$H/state" || exit 1
  mkdir -p "$H/fixture" "$H/logs" "$H/locks" "$H/state/merge-conductor" "$H/state/pr-owners"
  rm -f "$H/writes.log" "$H/reads.log" "$H/calls.log"
  echo '[]' > "$H/fixture/open.json"; echo '[]' > "$H/fixture/merged.json"; echo '{"jobs":[]}' > "$H/fixture/jobs.json"
  : > "$H/state/merge-conductor/pr-state.tsv"
}
opens()   { printf '%s\n' "$@" | jq -s . > "$H/fixture/open.json"; }
mergeds() { printf '%s\n' "$@" | jq -s . > "$H/fixture/merged.json"; }
owned()   { jq --arg k "$1" '.jobs += [{id:("build-"+$k),ticket_id:$k,kind:"build",status:"running",meta:"{}"}]' "$H/fixture/jobs.json" > "$T/j" && mv "$T/j" "$H/fixture/jobs.json"; }
mcrow()   { printf '%s#%s\t%s\t1757000000\t%s\t-\t-\tfixture\thttps://x\n' "$SLUG" "$1" "$2" "$(printf '%s%039d' "$1" 0 | cut -c1-40)" >> "$H/state/merge-conductor/pr-state.tsv"; }
issue()   { printf '%s' "$2" > "$H/fixture/issue-$1.code"; printf '%s' "$3" > "$H/fixture/issue-$1.json"; }
tickets() { printf '%s\n' "$@" | jq -R . | jq -s '[.[] | {key: (split(" ")[0]), status: (split(" ")[1])}]' > "$H/fixture/tickets.json"; }
# files <num> <status:path:sha[:prev]>... — the PR's file list
files()   { local n="$1"; shift; printf '%s\n' "$@" | jq -R 'split(":") | {status:.[0],filename:.[1]} + (if (.[2] // "") != "" then {sha:.[2]} else {} end) + (if (.[3] // "") != "" then {previous_filename:.[3]} else {} end)' | jq -s . > "$H/fixture/files-$n.json"; }
blob()    { printf '%s\t%s\n' "$1" "$2" >> "$H/fixture/main-blobs.tsv"; }
run() { env HARNESS="$H" FLEET_CONF="$H/fleet.conf" GH_TOKEN=x GH_BUDGET_TTL_S=0 GH_ETAG=0 JOBS_RETRIES=0 PR_OWNER_NOW="$NOW0" "$@" \
          bash "$H/bin/pr-owner-sweep.sh" --repo "$SLUG" >/dev/null 2>"$T/run.err"; RC=$?; }
W()      { cat "$H/writes.log" 2>/dev/null; }
LOGT()   { cat "$H/logs/pr-owner-sweep.log" 2>/dev/null; }
closed() { grep -qx "CLOSE $1" "$H/writes.log" 2>/dev/null; }
commented() { grep -q "^COMMENT $1 " "$H/writes.log" 2>/dev/null; }
summary() { grep -o "$SLUG: open=.*" "$H/logs/pr-owner-sweep.log" 2>/dev/null | tail -1; }
reads()  { [ -f "$H/reads.log" ] || { echo 0; return; }; grep -c "^$1" "$H/reads.log"; }
# lib <cmd...> — run a function of the new lib through the real REST lib
lib() { env HARNESS="$H" GH_TOKEN=x GH_ETAG=0 TD= bash -c '. "$HARNESS/bin/lib/gh-rest.sh" || exit 9; . "$HARNESS/bin/lib/pr-owner/shipped.sh" || exit 9; "$@"' _ "$@" 2>/dev/null; }

project-4=example-org/project-4
BH=example-org/cromford

# s1_fixture — rule 2: BH-50 done on the issues board, open OWNED PR #300.
s1_fixture() {
  setup "$BH"
  opens "$(pr 300 'BH-50: the thing' ticket/bh-50 operator "${1:-}" "${2:-$OLD}")"
  mcrow 300 "${3:-WAIT_CI}"
  issue 50 200 '{"number":50,"state":"closed","state_reason":"completed"}'
  files 300 "modified:a.txt:$H1"
}

# ---------- S1 a done ticket's PR whose change is not on main stays open -------
s1_fixture; blob a.txt "$M1"
run
[ "$RC" = 0 ] && ok || bad "S1 the sweep exits 0 (rc=$RC): $(head -3 "$T/run.err")"
! closed 300 && ! commented 300 && ok || bad "S1 no close and no comment on #300: $(W)"
grep -q 'held=[^ ]*#300:unshipped' <<<"$(summary)" && ok || bad "S1 held #300:unshipped: $(summary)"
grep -q "$BH#300: done-ticket close skipped (ticket-done) — unshipped:a.txt" <<<"$(LOGT)" && ok || bad "S1 the log names a.txt: $(LOGT | tail -3)"

# ---------- S2 the same PR with its change on main closes as today -------------
s1_fixture; blob a.txt "$H1"
run
closed 300 && ok || bad "S2 #300 closed: $(W)"
grep -q '^COMMENT 300 Closing this one: BH-50 is marked done on the board, so nothing here is waiting to ship' "$H/writes.log" && ok \
  || bad "S2 today's rule 2 text: $(W)"

# ---------- S3 rule 1, the project-6 #577 shape --------------------------------
s3_fixture() {
  setup "$BH"
  opens "$(pr 577 'BH-60: second try' ticket/bh-60-b operator)"
  mergeds "$(merged 574 'BH-60: first try' ticket/bh-60)"
  mcrow 577 WAIT_CI
  issue 60 200 '{"number":60,"state":"open"}'
  files 577 "modified:src/lib/a.ts:$H1" "modified:src/lib/home/launch-welcome.ts:$H2"
  blob src/lib/a.ts "$H1"
}
s3_fixture; blob src/lib/home/launch-welcome.ts "$M2"
run
! closed 577 && ! commented 577 && ok || bad "S3 #577 with a path #574 did not ship stays open: $(W)"
grep -q 'unshipped:src/lib/home/launch-welcome.ts' <<<"$(LOGT)" && ok || bad "S3 the log names launch-welcome.ts: $(LOGT | tail -3)"
s3_fixture; blob src/lib/home/launch-welcome.ts "$H2"
run
closed 577 && grep -q '^COMMENT 577 Closing this one: BH-60 already shipped in #574' "$H/writes.log" && ok \
  || bad "S3 control: every path on main closes with today's text: $(W)"

# ---------- S4 the sweep's close-duplicate arm ---------------------------------
s4_fixture() {
  setup "$project-4"
  opens "$(pr 160 'TK-107: leftover' ticket/TK-107-b operator)"
  mergeds "$(merged 118 'TK-107: shipped' ticket/TK-107)"
}
s4_fixture; files 160 "modified:x.js:$H1"; blob x.js "$M1"
run
! closed 160 && ! commented 160 && ok || bad "S4 close-duplicate with a diff not on main writes nothing: $(W)"
grep -q 'held=[^ ]*#160:unshipped' <<<"$(summary)" && ok || bad "S4 held #160:unshipped: $(summary)"
grep -q "$project-4#160: done-ticket close skipped (close-duplicate:#118) — unshipped:x.js" <<<"$(LOGT)" && ok || bad "S4 the skip line: $(LOGT | tail -3)"
s4_fixture
run
closed 160 && grep -qF 'COMMENT 160 Closing this one: **TK-107 already shipped in #118**' "$H/writes.log" && ok \
  || bad "S4 control: an empty diff closes with today's text: $(W)"

# ---------- S5 an unreadable answer keeps the PR open --------------------------
s1_fixture; blob a.txt "$H1"; echo 500 > "$H/fixture/files-300.code"
run
! closed 300 && grep -q 'shipped-unknown:files-read:75' <<<"$(LOGT)" && ok || bad "S5 files 500: $(W) / $(LOGT | tail -2)"
s1_fixture; blob a.txt "$H1"
for i in $(seq 1 100); do echo "modified:f$i.txt:$H1"; done > "$T/hundred"
mapfile -t HUNDRED < "$T/hundred"; files 300 "${HUNDRED[@]}"
run
! closed 300 && grep -q 'shipped-unknown:files:100+' <<<"$(LOGT)" && ok || bad "S5 100 entries: $(W) / $(LOGT | tail -2)"
s1_fixture; blob a.txt "$H1"; printf 'a.txt\t500\n' > "$H/fixture/contents-code.tsv"
run
! closed 300 && grep -q 'shipped-unknown:contents-read:75:a.txt' <<<"$(LOGT)" && ok || bad "S5 contents 500: $(W) / $(LOGT | tail -2)"
s1_fixture; blob a.txt "$H1"; echo 404 > "$H/fixture/main.code"
run
! closed 300 && grep -q 'shipped-unknown:main-sha-unreadable' <<<"$(LOGT)" && ok || bad "S5 commits/HEAD 404: $(W) / $(LOGT | tail -2)"

# ---------- S6 rule 3 is not guarded -------------------------------------------
setup "$project-4"
opens "$(pr 100 'TK-103: one' ticket/TK-103 operator)" "$(pr 110 'TK-103: two' ticket/TK-103-b operator)"
owned TK-103; tickets 'TK-103 in_progress'
run
closed 100 && ! closed 110 && ok || bad "S6 rule 3 closes the older duplicate as today: $(W)"
[ "$(reads FILES)" = 0 ] && ok || bad "S6 rule 3 reads no PR file list: $(cat "$H/reads.log" 2>/dev/null)"

# ---------- D1 labels ------------------------------------------------------------
r() { local o rc; o=$(lib po_done_skip_reason "$@"); rc=$?; printf '%s:%s' "$o" "$rc"; }
[ "$(r 'HOLD' - "$OLD" "$NOW0")" = "label:hold:0" ] && ok || bad "D1 HOLD skips label:hold: $(r 'HOLD' - "$OLD" "$NOW0")"
[ "$(r 'merge-queue' - "$OLD" "$NOW0")" = "label:merge-queue:0" ] && ok || bad "D1 merge-queue skips: $(r 'merge-queue' - "$OLD" "$NOW0")"
[ "$(r 'parked' - "$OLD" "$NOW0")" = ":1" ] && ok || bad "D1 parked alone is no label skip: $(r 'parked' - "$OLD" "$NOW0")"
[ "$(r '' - "$OLD" "$NOW0")" = ":1" ] && ok || bad "D1 no label, no skip: $(r '' - "$OLD" "$NOW0")"
s1_fixture merge-queue; blob a.txt "$H1"
run
! closed 300 && grep -q 'held=[^ ]*#300:label' <<<"$(summary)" && ok || bad "D1 a merge-queue label keeps a shipped PR open in the sweep: $(W) / $(summary)"

# ---------- D2 armed -------------------------------------------------------------
[ "$(r '' READY "$OLD" "$NOW0")" = "armed:READY:0" ] && ok || bad "D2 READY skips: $(r '' READY "$OLD" "$NOW0")"
[ "$(r '' MERGING "$OLD" "$NOW0")" = "armed:MERGING:0" ] && ok || bad "D2 MERGING skips"
[ "$(r '' WAIT_CI "$OLD" "$NOW0")" = ":1" ] && ok || bad "D2 WAIT_CI is not armed: $(r '' WAIT_CI "$OLD" "$NOW0")"
s1_fixture '' "$OLD" READY; blob a.txt "$H1"
run
! closed 300 && grep -q "done-ticket close skipped (ticket-done) — armed:READY" <<<"$(LOGT)" && ok || bad "D2 a READY PR is not closed by rule 2: $(W) / $(LOGT | tail -2)"

# ---------- D3 recent ------------------------------------------------------------
[ "$(r '' - "$(ISO $((119*60)))" "$NOW0")" = "recent:119m:0" ] && ok || bad "D3 119m skips: $(r '' - "$(ISO $((119*60)))" "$NOW0")"
[ "$(r '' - "$(ISO $((121*60)))" "$NOW0")" = ":1" ] && ok || bad "D3 121m does not skip"
[ "$(r '' - "$(ISO $((120*60)))" "$NOW0")" = ":1" ] && ok || bad "D3 120m exactly does not skip"
[ "$(PR_OWNER_DONE_RECENT_MIN=0 r '' - "$(ISO 300)" "$NOW0")" = ":1" ] && ok || bad "D3 knob 0 never skips"
[ "$(r '' - "garbage" "$NOW0")" = "recent:unreadable:0" ] && ok || bad "D3 an unreadable updatedAt holds: $(r '' - garbage "$NOW0")"
s1_fixture '' "$(ISO 420)"; blob a.txt "$H1"
run
! closed 300 && grep -q 'done-ticket close skipped (ticket-done) — recent:7m' <<<"$(LOGT)" && ok || bad "D3 a PR updated 7m ago is kept: $(W) / $(LOGT | tail -2)"
[ "$(reads FILES)" = 0 ] && ok || bad "D3 a recent PR costs no file read: $(cat "$H/reads.log" 2>/dev/null)"

# ---------- D4 the shipped matrix ------------------------------------------------
setup "$BH"
shp() { local o rc; o=$(lib po_shipped "$BH" 300 - "$M1"); rc=$?; printf '%s:%s' "$o" "$rc"; }
files 300 "removed:gone.txt"
[ "$(shp)" = "shipped:0" ] && ok || bad "D4 removed + main 404 is shipped: $(shp)"
blob gone.txt "$M1"
[ "$(shp)" = "unshipped gone.txt:1" ] && ok || bad "D4 removed + main 200 is unshipped: $(shp)"
files 300 "renamed:new.txt:$H1:gone.txt"; blob new.txt "$H1"
[ "$(shp)" = "unshipped gone.txt:1" ] && ok || bad "D4 renamed with the old path still on main is unshipped: $(shp)"
setup "$BH"; files 300 "renamed:new.txt:$H1:gone.txt"; blob new.txt "$H1"
[ "$(shp)" = "shipped:0" ] && ok || bad "D4 a renamed file fully on main is shipped: $(shp)"
echo '[]' > "$H/fixture/files-300.json"
[ "$(shp)" = "shipped:0" ] && ok || bad "D4 an empty list is shipped: $(shp)"
for i in $(seq 1 61); do echo "modified:f$i.txt:$H1"; done > "$T/sixtyone"
mapfile -t SIXTYONE < "$T/sixtyone"; files 300 "${SIXTYONE[@]}"
[ "$(shp)" = "unknown files:61>60:2" ] && ok || bad "D4 61 files over a max of 60 is unknown: $(shp)"
files 300 "added:dir1:$H1"; blob dir1 DIR
[ "$(shp)" = "unknown dir:dir1:2" ] && ok || bad "D4 a directory where a file is expected is unknown: $(shp)"
files 300 "modified:nosha.txt"
[ "$(shp)" = "unknown no-sha:nosha.txt:2" ] && ok || bad "D4 an entry with no sha is unknown: $(shp)"
files 300 "modified:dir a/x#1.txt:$H1"; blob 'dir a/x#1.txt' "$H1"
[ "$(shp)" = "shipped:0" ] && ok || bad "D4 a path with a space and # is encoded per segment: $(shp)"
files 300 "frobbed:odd.txt:$H1"
[ "$(shp)" = "unknown status:frobbed:odd.txt:2" ] && ok || bad "D4 a status the guard does not know is unknown: $(shp)"
files 300 "renamed:new.txt:$H1"
[ "$(shp)" = "unknown no-previous:new.txt:2" ] && ok || bad "D4 a rename with no previous_filename is unknown: $(shp)"
echo '{"message":"not a list"}' > "$H/fixture/files-300.json"
[ "$(shp)" = "unknown files-not-a-list:2" ] && ok || bad "D4 a body that is not a list is unknown: $(shp)"

# ---------- G1 superseded.sh with no guard lib closes nothing ---------------------
# The sweep sources shipped.sh itself (|| exit 1); this is the lazy load
# superseded.sh does for any other caller. The scratch copy is moved away, then back.
mv "$H/bin/lib/pr-owner/shipped.sh" "$T/shipped.away" || exit 1
O=$(env HARNESS="$H" bash -c '. "$HARNESS/bin/lib/pr-owner/superseded.sh" || exit 9
  job_ledger_row() { return 2; }; _po_ss_held() { return 1; }
  gh_rest_comment() { echo WROTE; }; gh_rest_close() { echo WROTE; }; _po_ss_rest() { return 0; }
  PO_SLUG=example-org/cromford PO_NUM=300 N_ACT=0 MAX_ACTIONS=5 HELD="" DRY=0
  _po_ss_close ticket-done "fixture text"; echo "rc=$? held=$HELD"' 2>&1)
mv "$T/shipped.away" "$H/bin/lib/pr-owner/shipped.sh" || exit 1
grep -qx 'rc=2 held=#300:guard-missing' <<<"$O" && ! grep -q WROTE <<<"$O" && ok || bad "G1 no guard lib: rule 2 declines and writes nothing: $O"

# ---------- M1 the memo is reused on the same (head, main) -----------------------
s1_fixture; blob a.txt "$M1"
run
rm -f "$H/reads.log"
run
[ "$(reads CONTENTS)" = 0 ] && [ "$(reads FILES)" = 0 ] && ok || bad "M1 the second run reads no contents: $(cat "$H/reads.log" 2>/dev/null)"
grep -q 'held=[^ ]*#300:unshipped' <<<"$(summary)" && ! closed 300 && ok || bad "M1 the memo answer still holds the PR: $(summary)"
echo "$M2" > "$H/fixture/main.sha"; rm -f "$H/reads.log"
run
[ "$(reads CONTENTS)" -ge 1 ] && ok || bad "M1 a new main sha reads again: $(cat "$H/reads.log" 2>/dev/null)"

# ---------- M2 the memo is bounded, and needs a root -----------------------------
s1_fixture; blob a.txt "$M1"
MEMO="$H/state/pr-owners/example-org_cromford.shipped.tsv"
for i in $(seq 1000 1249); do printf '%s\t%s\t%s\tunshipped\tz.txt\t1\n' "$i" "$H1" "$M1"; done > "$MEMO"
run
[ "$(wc -l < "$MEMO")" = 200 ] && ok || bad "M2 the memo is cut to 200 rows: $(wc -l < "$MEMO")"
tail -1 "$MEMO" | grep -qP "^300\t300000\d+\t$(SHA a 0)\tunshipped\ta\.txt\t" && ok || bad "M2 the newest row is #300's: $(tail -1 "$MEMO")"
setup "$BH"; files 300 "modified:a.txt:$H1"; blob a.txt "$M1"; mkdir -p "$T/cwd"
O=$(cd "$T/cwd" && env -u H HARNESS= GH_TOKEN=x GH_ETAG=0 TD= LIBH="$H" bash -c '. "$LIBH/bin/lib/gh-rest.sh"; . "$LIBH/bin/lib/pr-owner/shipped.sh"; po_shipped example-org/cromford 300 '"$H1 $M1" 2>/dev/null)
[ "$O" = "unshipped a.txt" ] && [ ! -e "$T/cwd/state" ] && [ ! -e "$MEMO" ] && ok || bad "M2 no root writes no memo: '$O' $(ls "$T/cwd" "$H/state/pr-owners" 2>/dev/null)"

# ---------- K1 knobs -------------------------------------------------------------
KD="$DIR/catalog/lanes.d/pr-owner-sweep.knobs.d"
kdef() { jq -r --arg e "$1" 'select(.env == $e) | .default' "$KD/$1.json" 2>/dev/null; }
[ "$(kdef PR_OWNER_DONE_RECENT_MIN)" = 120 ] && [ "$(lib _po_sh_recent_min)" = 120 ] && ok || bad "K1 recent default 120 in the fragment and the lib"
[ "$(kdef PR_OWNER_SHIPPED_MAX_FILES)" = 60 ] && [ "$(lib _po_sh_max_files)" = 60 ] && ok || bad "K1 max files default 60"
[ "$(kdef PR_OWNER_DONE_SKIP_LABELS)" = "hold merge-queue queue-solo fix-main-red" ] && [ "$(lib _po_sh_skip_labels)" = "$(kdef PR_OWNER_DONE_SKIP_LABELS)" ] && ok || bad "K1 labels default"
HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/lanes-build.sh" --root "$DIR" --check >/dev/null 2>"$T/lb.err" && ok || bad "K1 lanes-build --check: $(head -3 "$T/lb.err")"
[ "$(PR_OWNER_DONE_SKIP_LABELS=foo r 'foo' - "$OLD" "$NOW0")" = "label:foo:0" ] && ok || bad "K1 the label env override skips foo"
[ "$(PR_OWNER_DONE_SKIP_LABELS=foo r 'hold' - "$OLD" "$NOW0")" = ":1" ] && ok || bad "K1 …and hold is no longer a skip label"
s1_fixture '' "$(ISO 420)"; blob a.txt "$H1"
run PR_OWNER_DONE_RECENT_MIN=5
closed 300 && ok || bad "K1 PR_OWNER_DONE_RECENT_MIN=5 reaches the sweep: a PR quiet 7m closes: $(W) / $(LOGT | tail -2)"
s1_fixture; for i in $(seq 1 3); do echo "modified:f$i.txt:$H1"; blob "f$i.txt" "$H1"; done > "$T/three"
mapfile -t THREE < "$T/three"; files 300 "${THREE[@]}"
run PR_OWNER_SHIPPED_MAX_FILES=2
! closed 300 && grep -q 'shipped-unknown:files:3>2' <<<"$(LOGT)" && ok || bad "K1 PR_OWNER_SHIPPED_MAX_FILES=2 reaches the sweep: $(LOGT | tail -2)"

# ---------- Y1 the guard runs in a dry run ---------------------------------------
s1_fixture; blob a.txt "$M1"
run PR_OWNER_DRY_RUN=1
grep -q 'done-ticket close skipped (ticket-done) — unshipped:a.txt' <<<"$(LOGT)" && ! grep -q 'DRY-RUN would: superseded close #300' <<<"$(LOGT)" && ok \
  || bad "Y1 a dry run reports the real decision: $(LOGT | tail -3)"
[ ! -s "$H/writes.log" ] && ok || bad "Y1 a dry run writes nothing: $(W)"

# ---------- R1 the replay --------------------------------------------------------
setup "$BH"
SW='_bin/pr-owner-sweep.sh_'
T1=$(ISO $((2*D)))
cmt() { jq -nc --argjson n "$1" --arg at "$2" --arg b "$3" --arg slug "$BH" \
  '{id:$n,created_at:$at,body:$b,html_url:"https://github.com/\($slug)/pull/\($n)#issuecomment-\($n)",issue_url:"https://api.github.com/repos/\($slug)/issues/\($n)",user:{login:"example-org-bot"}}'; }
prj() { jq -nc --argjson n "$1" --arg c "$2" --arg s "$3" --arg m "$4" --arg h "$(SHA d "$1")" \
  '{number:$n,state:$s,merged_at:(if $m == "" then null else $m end),created_at:$c,head:{sha:$h},user:{login:"operator"}}' > "$H/fixture/pr-$1.json"; }
{
  cmt 551 "$T1" "Closing this one: BH-51 is marked done on the board, so nothing here is waiting to ship. If that's wrong, reopen the ticket and this PR and say so.

$SW"
  cmt 577 "$T1" "Closing this one: BH-60 already shipped in #574, so this branch is a leftover. If something here didn't make it in, reopen it and say so.

$SW"
  cmt 160 "$T1" "Closing this one: **BH-70 already shipped in #118**, so this branch is a leftover from an earlier attempt at the same ticket.

_bin/pr-owner-sweep.sh — every open PR is owned, parked with an expiry, or closed._"
  cmt 100 "$T1" "Closing this one: #110 is the PR for BH-103 that we're landing, so this one is a duplicate. If it has something #110 doesn't, reopen it and say so.

$SW"
  cmt 200 "$T1" "LGTM, ship it"
} | jq -s . > "$H/fixture/repo-comments.json"
prj 551 "$(ISO $((2*D + 420)))" open "$(ISO $D)"
prj 577 "$(ISO $((5*D)))" closed "$(ISO $D)"
prj 160 "$(ISO $((6*D)))" closed ""
prj 100 "$(ISO $((6*D)))" closed ""
files 551 "modified:a.txt:$H1"; files 577 "modified:src/lib/home/launch-welcome.ts:$H2"; echo '[]' > "$H/fixture/files-160.json"
blob a.txt "$H1"; blob src/lib/home/launch-welcome.ts "$M2"
# #160: a merge-queue label added and removed before the close, and a commit
# and a human comment three days before it.
jq -nc --arg a "$(ISO $((4*D)))" --arg b "$(ISO $((3*D)))" '[{event:"labeled",created_at:$a,label:{name:"merge-queue"}},{event:"unlabeled",created_at:$b,label:{name:"merge-queue"}}]' > "$H/fixture/events-160.json"
jq -nc --arg a "$(ISO $((5*D)))" '[{sha:"x",commit:{committer:{date:$a}}}]' > "$H/fixture/prcommits-160.json"
jq -nc --arg a "$(ISO $((5*D)))" '[{created_at:$a,body:"looks fine",user:{login:"operator"}}]' > "$H/fixture/thread-160.json"
jq -nc --arg a "$(ISO $((6*D)))" --arg late "$(ISO $D)" '[{sha:"x",commit:{committer:{date:$a}}},{sha:"y",commit:{committer:{date:$late}}}]' > "$H/fixture/prcommits-577.json"
REP=$(env HARNESS="$H" FLEET_CONF="$H/fleet.conf" GH_TOKEN=x GH_ETAG=0 PR_OWNER_NOW="$NOW0" bash "$H/bin/pr-owner-close-replay.sh" --days 7 --repo "$BH" 2>"$T/rep.err"); RRC=$?
[ "$RRC" = 0 ] && ok || bad "R1 the replay exits 0 (rc=$RRC): $(head -3 "$T/rep.err")"
row() { grep -P "^\Q$BH\E\t#$1\t" <<<"$REP"; }
row 551 | grep -qP '\trule=ticket\t.*\twould=skip\treasons=recent:7m' && ok || bad "R1 #551 (closed 7m after it opened) would skip, recent:7m: $(row 551)"
row 577 | grep -qP '\trule=merged\t.*\twould=skip\treasons=.*unshipped:src/lib/home/launch-welcome.ts' && ok || bad "R1 #577 would skip, unshipped: $(row 577)"
row 160 | grep -qP '\trule=close-dup\t.*\twould=close\t' && ok || bad "R1 #160 (empty diff, 3 days quiet, label removed) would close: $(row 160)"
row 100 | grep -qP '\trule=duplicate\t.*\twould=n/a\t' && ok || bad "R1 rule 3 prints n/a: $(row 100)"
[ -z "$(row 200)" ] && ok || bad "R1 a non-sweep comment is ignored: $(row 200)"
row 577 | grep -qP '\tclosed_at=\Q'"$T1"'\E\t' && row 577 | grep -qP '\tnow=merged\t' && ok || bad "R1 the row carries the close time and today's state: $(row 577)"
grep -qx 'replay: days=7 closes=4 would_skip=2 would_close=1 n/a=1 unreadable=0' <<<"$REP" && ok || bad "R1 the summary line: $(tail -1 <<<"$REP")"
! grep -qE '^(POST|PATCH|PUT|DELETE) ' "$H/calls.log" 2>/dev/null && [ ! -s "$H/writes.log" ] && ok || bad "R1 the replay writes nothing: $(grep -E '^(POST|PATCH)' "$H/calls.log")"
echo 500 > "$H/fixture/repo-comments.code"
REP=$(env HARNESS="$H" FLEET_CONF="$H/fleet.conf" GH_TOKEN=x GH_ETAG=0 PR_OWNER_NOW="$NOW0" bash "$H/bin/pr-owner-close-replay.sh" --repo "$BH" 2>/dev/null); RRC=$?
[ "$RRC" = 0 ] && grep -qx 'replay: days=7 closes=0 would_skip=0 would_close=0 n/a=0 unreadable=1' <<<"$REP" && ok || bad "R1 an unreadable repo is counted, not skipped silently (rc=$RRC): $(tail -2 <<<"$REP")"

echo "pr-owner-done-guard.bh-6815: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
