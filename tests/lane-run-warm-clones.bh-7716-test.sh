#!/bin/bash
# tests/lane-run-warm-clones.bh-7716-test.sh — BH-7716 T3: the warm clones of
# the dedicated lane machine (bin/lib/lane-run-warm.sh, LANE_RUN_WARM_CLONES=1
# in bin/lane-run-worker.sh). A missing clone is made before a fix round runs,
# and is never reported as a failure.
#
# Driven through the REAL bin/lane-run-worker.sh --once and
# bin/project-lane-run.sh over real curl against the REAL jobs worker
# (tests/lib/lane-runs-worker.bh-6124.mjs). The origin is a local bare git
# repo (LANE_RUN_WARM_URL_BASE=file://...), so the suite makes 0 network
# calls. The lane is a stub that records whether $REPOS_ROOT/<p>/.git exists
# when it runs. The refresh stamp is set fresh before each ensure case, so the
# clone is made by the ensure in lw_run and not by lw_warm_refresh.
#
#   W1  no clone: cloned before the lane runs (the stub saw .git), report
#       rc 0, `warm ensure p1: cloned` logged, no `no local clone` text
#   W2  clone present: `fetched`, the lane runs
#   W3  origin unreadable: report rc 75 with `reason=clone-ensure`, the lane
#       stub is never called
#   W4  a half clone (dir without .git): moved to p1.broken-<epoch>, re-cloned
#   W5  the clone dir is a symlink: refused, rc 75, the lane not called
#   W6  the fetch fails with .git present: the lane runs, one `kept-stale` line
#   W7  9 clones, lane_run.clone_cache_n=8, LANE_RUN=1: none evicted with
#       LANE_RUN_WARM_CLONES=1 (one `warm clones on, no eviction` line);
#       evicted down to 8 without it (today's behaviour)
#   W8  lw_warm_refresh: the first --once clones every fleet repo and logs
#       `warm refresh: 1 repos in`; a second call inside
#       lane_run.warm_refresh_s does nothing; at the window it runs again
#   W9  a merge-conductor-pr row `<p>.<pr>.<head>`: the ensure uses <p>
#   W10 a project with no fleet.conf repo (`-`): rc 0 `no repo`, the lane runs
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lane-run-warm-clones.bh-7716-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
[ -f "$DIR/catalog/lanes.json" ] || HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --write >/dev/null \
  || { echo "FAIL: cannot compose catalog/lanes.json"; exit 1; }
SRV="$DIR/tests/lib/lane-runs-worker.bh-6124.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 \
  && command -v git >/dev/null 2>&1 || { echo "SKIP: node, jq, flock or git missing"; exit 0; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags"
for L in bin/lane-run-worker.sh bin/project-lane-run.sh bin/fleet-conf.sh bin/jobs-client.sh bin/lib/gh-app-auth.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
scratch_rm "$H/catalog/lane-run-inputs.d"
chmod +x "$H/bin/"*.sh 2>/dev/null
printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\np9 - - - 2 box-p9 192.0.2.1\n' > "$H/fleet.conf"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
# The lane: records whether the clone of its project (the last arg) exists.
cat > "$H/bin/rec-lane.sh" <<EOF
#!/bin/bash
p="\${@: -1}"
if [ -d "\$REPOS_ROOT/\$p/.git" ]; then echo "yes \$p" >> "$T/rec.txt"; else echo "no \$p" >> "$T/rec.txt"; fi
echo "PROF rec p=\$p"
exit 0
EOF
chmod +x "$H/bin/rec-lane.sh"

# The origin: a bare repo with one commit, at <base>/o/p1.git.
git init -q "$T/src" && git -C "$T/src" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m one \
  && mkdir -p "$T/origin/o" && git clone -q --bare "$T/src" "$T/origin/o/p1.git" || bad "setup: origin repo"

export HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos"
export HARNESS_SECRET=fixture-harness-secret GH_TOKEN=tok-fixture-default
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 BOX_NAME=fixture-box
export LANE_RUN_WARM_URL_BASE="file://$T/origin"
mkdir -p "$REPOS_ROOT"
NOW0=1791000000

: > "$T/w.log"; : > "$T/w.port"
node "$SRV" "$T/w.log" > "$T/w.port" 2> "$T/w.err" &
PID=$!
trap 'kill "$PID" 2>/dev/null' EXIT
for _ in $(seq 1 200); do [ -s "$T/w.port" ] && break; kill -0 "$PID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/w.port")
if [ -z "$PORT" ]; then wait "$PID"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; }; echo "setup: worker did not start: $(cat "$T/w.err")"; exit 1; fi
export JOBS_URL="http://127.0.0.1:$PORT"

api() { curl -sS -X "$1" -H "authorization: Bearer $HARNESS_SECRET" -H 'content-type: application/json' ${3:+-d "$3"} "$JOBS_URL$2"; }
setting() { curl -sS -X PUT "$JOBS_URL/__setting" -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" >/dev/null; }
enq() { api POST /api/lane-runs "$(jq -nc --arg l "$1" --arg p "$2" '{lane:$l,project:$p,args:["bin/rec-lane.sh"]}')" | jq -r .id; }
drow() { curl -sS "$JOBS_URL/__lane_runs" | jq -c --argjson id "$1" '.rows[] | select(.id == $id)'; }
WLOG="$H/logs/lane-run-worker.log"
STAMP="$H/state/lane-run-worker/warm-refresh.at"
# fresh — the refresh stamp at NOW0, so lw_warm_refresh skips and only the
# ensure in lw_run can make the clone.
fresh() { mkdir -p "${STAMP%/*}"; printf '%s\n' "$NOW0" > "$STAMP"; }
# work [extra env...] — one --once machine with warm clones on, clock pinned.
work() { env LANE_RUN_WARM_CLONES=1 LANE_RUN_NOW="$NOW0" "$@" "$H/bin/lane-run-worker.sh" --once --machine m1 > "$T/work.out" 2>&1; WRC=$?; }
mark() { L0=$(wc -l < "$WLOG" 2>/dev/null || echo 0); R0=$(wc -l < "$T/rec.txt" 2>/dev/null || echo 0); }
newlog() { tail -n +"$((L0 + 1))" "$WLOG" 2>/dev/null; }
newrec() { tail -n +"$((R0 + 1))" "$T/rec.txt" 2>/dev/null; }
: > "$T/rec.txt"; : > "$WLOG"

# ============================================================================
echo "W1: a missing clone is made before the lane runs"
fresh; mark
ID=$(enq blocked-resolver p1)
work
D=$(drow "$ID")
[ "$WRC" = 0 ] && ok "W1 the loop exits 0" || bad "W1 rc=$WRC $(cat "$T/work.out")"
[ "$(newrec)" = "yes p1" ] && ok "W1 the lane ran with $REPOS_ROOT/p1/.git present" || bad "W1 rec: '$(newrec)' log: $(newlog)"
[ "$(jq -r .rc <<<"$D")" = 0 ] && [ "$(jq -r .status <<<"$D")" = done ] && ok "W1 the row is done rc 0" || bad "W1 row: $D"
grep -q 'warm ensure p1: cloned' <<<"$(newlog)" && ok "W1 log: warm ensure p1: cloned" || bad "W1 log: $(newlog)"
! grep -rq 'no local clone' "$H/logs" && ok "W1 no 'no local clone' text in any log" || bad "W1 'no local clone' logged"
! grep -q 'warm refresh:' <<<"$(newlog)" && ok "W1 the refresh did not run (fresh stamp): the ensure made the clone" || bad "W1 refresh ran: $(newlog)"

# ============================================================================
echo "W2: a present clone is fetched"
fresh; mark
ID=$(enq blocked-resolver p1)
work
[ "$(newrec)" = "yes p1" ] && [ "$(jq -r .rc <<<"$(drow "$ID")")" = 0 ] && ok "W2 the lane ran, rc 0" || bad "W2 rec '$(newrec)' row $(drow "$ID")"
grep -q 'warm ensure p1: fetched' <<<"$(newlog)" && ok "W2 log: warm ensure p1: fetched" || bad "W2 log: $(newlog)"

# ============================================================================
echo "W3: an unreadable origin reports rc 75 clone-ensure"
fresh; mark; scratch_rm "$REPOS_ROOT/p1"
ID=$(enq blocked-resolver p1)
work LANE_RUN_WARM_URL_BASE="file://$T/no-such-origin"
D=$(drow "$ID")
[ "$WRC" = 0 ] && ok "W3 the loop exits 0" || bad "W3 rc=$WRC"
[ "$(jq -r .rc <<<"$D")" = 75 ] && ok "W3 the row is reported rc 75" || bad "W3 row: $D"
case "$(jq -r .prof_line <<<"$D")" in
  "PROF lane-run rc=75 reason=clone-ensure err="?*) ok "W3 prof: PROF lane-run rc=75 reason=clone-ensure err=<why>" ;;
  *) bad "W3 prof: $(jq -r .prof_line <<<"$D")" ;;
esac
[ "$(jq -r '.prof_line | length' <<<"$D")" -le 512 ] && ok "W3 prof is at most 512 bytes" || bad "W3 prof length"
[ -z "$(newrec)" ] && ok "W3 the lane stub was never called" || bad "W3 rec: $(newrec)"
grep -q "run $ID blocked-resolver/p1: warm ensure failed" <<<"$(newlog)" && ok "W3 the log names the failed ensure" || bad "W3 log: $(newlog)"

# ============================================================================
echo "W4: a half clone is moved aside and re-cloned"
fresh; mark; scratch_rm "$REPOS_ROOT/p1"; mkdir -p "$REPOS_ROOT/p1"; echo junk > "$REPOS_ROOT/p1/junk"
ID=$(enq blocked-resolver p1)
work
B=$(find "$REPOS_ROOT" -maxdepth 1 -name 'p1.broken-*' | head -1)
[ -n "$B" ] && [ -f "$B/junk" ] && ok "W4 the half clone is at ${B##*/}" || bad "W4 no p1.broken-*: $(ls "$REPOS_ROOT")"
[ "$(newrec)" = "yes p1" ] && [ "$(jq -r .rc <<<"$(drow "$ID")")" = 0 ] && ok "W4 re-cloned, the lane ran, rc 0" || bad "W4 rec '$(newrec)' row $(drow "$ID") log $(newlog)"
[ -n "$B" ] && scratch_rm "$B"

# ============================================================================
echo "W5: a symlink clone dir is refused"
fresh; mark; scratch_rm "$REPOS_ROOT/p1"; mkdir -p "$T/elsewhere/.git"; ln -s "$T/elsewhere" "$REPOS_ROOT/p1"
ID=$(enq blocked-resolver p1)
work
D=$(drow "$ID")
[ "$(jq -r .rc <<<"$D")" = 75 ] && grep -q 'reason=clone-ensure' <<<"$(jq -r .prof_line <<<"$D")" \
  && ok "W5 rc 75 clone-ensure" || bad "W5 row: $D"
[ -z "$(newrec)" ] && ok "W5 the lane stub was never called" || bad "W5 rec: $(newrec)"
[ -L "$REPOS_ROOT/p1" ] && ok "W5 the symlink is left as it was" || bad "W5 the symlink was changed"
rm -f "$REPOS_ROOT/p1"

# ============================================================================
echo "W6: a failed fetch keeps the stale clone"
fresh; ID=$(enq blocked-resolver p1); work   # setup: a good clone
[ -d "$REPOS_ROOT/p1/.git" ] || bad "W6 setup: no clone"
fresh; mark
mv "$T/origin/o/p1.git" "$T/origin/o/p1.moved"
ID=$(enq blocked-resolver p1)
work
[ "$(newrec)" = "yes p1" ] && [ "$(jq -r .rc <<<"$(drow "$ID")")" = 0 ] && ok "W6 the lane ran on the stale clone, rc 0" || bad "W6 rec '$(newrec)' row $(drow "$ID")"
[ "$(grep -c 'warm ensure p1: kept-stale (' <<<"$(newlog)")" = 1 ] && ok "W6 one kept-stale line" || bad "W6 log: $(newlog)"
mv "$T/origin/o/p1.moved" "$T/origin/o/p1.git"

# ============================================================================
echo "W7: no eviction with warm clones"
setting lane_run.clone_cache_n 8
for i in 1 2 3 4 5 6 7 8; do git init -q "$REPOS_ROOT/q$i"; done
nclones() { find "$REPOS_ROOT" -mindepth 2 -maxdepth 2 -name .git | wc -l; }
[ "$(nclones)" = 9 ] && ok "W7 setup: 9 clones" || bad "W7 setup: $(nclones) clones"
fresh; mark
ID=$(enq blocked-resolver p1)
work LANE_RUN=1
[ "$(nclones)" = 9 ] && ok "W7 LANE_RUN_WARM_CLONES=1: none evicted (9)" || bad "W7 $(nclones) clones left; log $(newlog)"
grep -q 'clone cache: warm clones on, no eviction' <<<"$(newlog)" && ok "W7 log: warm clones on, no eviction" || bad "W7 log: $(newlog)"
! grep -q 'clone cache: evicted' <<<"$(newlog)" && ok "W7 no evicted line" || bad "W7 evicted: $(newlog)"
mark
ID=$(enq blocked-resolver p1)
LANE_RUN=1 LANE_RUN_NOW="$NOW0" "$H/bin/lane-run-worker.sh" --once --machine m1 > "$T/work.out" 2>&1
[ "$(nclones)" = 8 ] && ok "W7 without it: evicted down to 8 (today's behaviour)" || bad "W7 no-warm: $(nclones) clones"
[ "$(grep -c 'clone cache: evicted' <<<"$(newlog)")" = 1 ] && ok "W7 one evicted line" || bad "W7 log: $(newlog)"
for i in 1 2 3 4 5 6 7 8; do scratch_rm "$REPOS_ROOT/q$i"; done

# ============================================================================
echo "W8: lw_warm_refresh runs at most once per lane_run.warm_refresh_s"
setting lane_run.warm_refresh_s 300
rm -f "$STAMP"; scratch_rm "$REPOS_ROOT/p1"; mark
work
[ "$WRC" = 0 ] && [ -d "$REPOS_ROOT/p1/.git" ] && ok "W8 an empty queue: the refresh cloned p1" || bad "W8 rc $WRC; no clone; log $(newlog)"
[ "$(grep -c 'warm refresh: 1 repos in [0-9]*s' <<<"$(newlog)")" = 1 ] && ok "W8 one 'warm refresh: 1 repos in <s>s' line" || bad "W8 log: $(newlog)"
[ "$(head -1 "$STAMP" 2>/dev/null)" = "$NOW0" ] && ok "W8 the stamp holds the clock" || bad "W8 stamp: $(cat "$STAMP" 2>/dev/null)"
mark
env LANE_RUN_WARM_CLONES=1 LANE_RUN_NOW=$((NOW0 + 299)) "$H/bin/lane-run-worker.sh" --once --machine m1 >/dev/null 2>&1
! grep -q 'warm refresh:' <<<"$(newlog)" && ok "W8 at 299 s: no refresh" || bad "W8 299: $(newlog)"
mark
env LANE_RUN_WARM_CLONES=1 LANE_RUN_NOW=$((NOW0 + 300)) "$H/bin/lane-run-worker.sh" --once --machine m1 >/dev/null 2>&1
grep -q 'warm refresh: 1 repos in' <<<"$(newlog)" && ok "W8 at 300 s: the refresh runs again" || bad "W8 300: $(newlog)"
setting lane_run.warm_refresh_s 5
mark
env LANE_RUN_WARM_CLONES=1 LANE_RUN_NOW=$((NOW0 + 400)) "$H/bin/lane-run-worker.sh" --once --machine m1 >/dev/null 2>&1
! grep -q 'warm refresh:' <<<"$(newlog)" && ok "W8 a row of 5 (out of 60..3600) falls back to 300 s" || bad "W8 fallback: $(newlog)"
mark
"$H/bin/lane-run-worker.sh" --once --machine m1 >/dev/null 2>&1
! grep -q 'warm' <<<"$(newlog)" && ok "W8 without LANE_RUN_WARM_CLONES no warm line" || bad "W8 off: $(newlog)"

# ============================================================================
echo "W9: a merge-conductor-pr key ensures its project"
fresh; mark; scratch_rm "$REPOS_ROOT/p1"
ID=$(enq merge-conductor-pr p1.42.abcdef123456)
work
grep -q 'warm ensure p1: cloned' <<<"$(newlog)" && [ -d "$REPOS_ROOT/p1/.git" ] && ok "W9 the ensure cloned p1 for p1.42.abcdef123456" \
  || bad "W9 log: $(newlog)"
[ "$(jq -r .rc <<<"$(drow "$ID")")" = 0 ] && ok "W9 rc 0" || bad "W9 row: $(drow "$ID")"

# ============================================================================
echo "W10: a project with no repo"
fresh; mark
ID=$(enq blocked-resolver p9)
work
[ "$(newrec)" = "no p9" ] && [ "$(jq -r .rc <<<"$(drow "$ID")")" = 0 ] && ok "W10 the lane ran, rc 0" || bad "W10 rec '$(newrec)' row $(drow "$ID")"
grep -q 'warm ensure p9: no repo' <<<"$(newlog)" && ok "W10 log: warm ensure p9: no repo" || bad "W10 log: $(newlog)"

grep -q 'tok-fixture-default' "$WLOG" && bad "a token reached the worker log" || ok "no token in the worker log"

echo
echo "lane-run-warm-clones.bh-7716: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
