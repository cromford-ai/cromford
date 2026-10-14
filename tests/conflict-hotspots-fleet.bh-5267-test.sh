#!/bin/bash
# tests/conflict-hotspots-fleet.bh-5267-test.sh — BH-5267 (BH-5248.1): every
# project measured weekly, on the box that owns it, stored as rows.
#
# The REAL bin/conflict-hotspots-fleet.sh runs the REAL bin/conflict-hotspots.sh
# against fixture checkouts under a scratch REPOS_ROOT, and PUTs through the
# REAL bin/jobs-client.sh to the REAL worker (worker/jobs/src/index.js) over one
# file-backed node:sqlite DB: a fake `curl` on PATH hands each request to
# worker.fetch, the tests/pool-state-db.bh-5001-test.sh pattern. Each fixture
# repo has a bare `origin`, so the lane's fetch is a real one, and its history
# has real conflicted sync merges, built like tests/conflict-hotspots.bh-4986-test.sh.
#   F1 one run stores rows for alpha and for beta, each keyed by its project,
#      equal to bin/conflict-hotspots.sh's own output for that checkout.
#   F2 a new conflicting PR on alpha, re-run: alpha's window is replaced (no
#      duplicate rows), beta's rows carry the same data.
#   F3 gamma, owned by another box, gets no runs row.
#   F4 beta made shallow: runs row `shallow`, beta's rows kept, one warn alert.
#   F5 a missing checkout is `no-checkout`; a worker outage logs FAILED, never stored.
#   F6 a measurer that prints no TSV header is `error`, rows kept.
#   F7 --dry-run prints the body and sends no PUT.
#   F8 lane-off flag: exit 0, no PUT; a held lock: exit 0, `already running`.
# Also runs the route suite (worker/jobs/test/conflict-hotspots-route.test.js).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/conflict-hotspots-fleet.bh-5267-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
done_() { echo "conflict-hotspots-fleet.bh-5267: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

LANE="$DIR/bin/conflict-hotspots-fleet.sh"
ROUTE="$DIR/worker/jobs/src/routes/conflict-hotspots.js"
for f in "$LANE" "$ROUTE"; do [ -f "$f" ] && ok || bad "missing $f"; done

if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  echo "conflict-hotspots-fleet: SKIPPED, this node has no node:sqlite (CI's worker/jobs job runs the route suite)"
  done_
fi
[ -f "$LANE" ] && [ -f "$ROUTE" ] || done_

# core.js imports the GENERATED, git-ignored catalog/lanes.json statically, so
# it is composed BEFORE anything loads the worker (BH-5921: the route suite ran
# first, and a CI shard with no lanes.json yet failed it at import).
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --write >"$T/lb.out" 2>&1 \
  || bad "catalog/lanes.json could not be composed: $(cat "$T/lb.out")"

# The route suite, so this shell suite pins the route too. On a failure the
# node output's error and assertion lines go to the log (BH-5921), since $T and
# its route.out are removed when this suite ends.
if (cd "$DIR/worker/jobs" && node --test test/conflict-hotspots-route.test.js >"$T/route.out" 2>&1); then ok
else
  bad "worker route suite: $(grep -E 'not ok' "$T/route.out" | head -5)"
  grep -E 'Error|AssertionError|expected|actual|\+ |- ' "$T/route.out" | head -40 | sed 's/^/  route: /'
fi

export CH_T="$T" CH_DB="$T/d1.sqlite" NODE_OPTIONS=--no-warnings
cat >"$T/init.mjs" <<EOF
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync(process.env.CH_DB);
db.exec(readFileSync('$DIR/worker/jobs/schema.sql', 'utf8'));
EOF
cat >"$T/drv.mjs" <<EOF
import { DatabaseSync } from 'node:sqlite';
import worker from '$DIR/worker/jobs/src/index.js';
import { d1 } from '$DIR/worker/jobs/test/lib/d1-sqlite.bh-1030.js';
const db = new DatabaseSync(process.env.CH_DB);
const [method, url, body] = process.argv.slice(2);
const res = await worker.fetch(new Request(url, {
  method, headers: { authorization: 'Bearer s', 'content-type': 'application/json' },
  body: body ? body : undefined,
}), { DB: d1(db), HARNESS_SECRET: 's' });
process.stdout.write((await res.text()) + '\n' + res.status);
EOF
node "$T/init.mjs" || { echo "FAIL: schema.sql did not apply"; exit 1; }
sql() { node -e '
  const { DatabaseSync } = require("node:sqlite");
  const db = new DatabaseSync(process.env.CH_DB);
  const r = db.prepare(process.argv[1]).all();
  for (const row of r) console.log(Object.values(row).map((v) => v === null ? "NULL" : v).join("\t"));' "$1"; }

mkdir -p "$T/fakebin"
# The fake curl: `-X M`, `--data-binary B` (or @file), the http(s) argument the URL.
# $CH_T/outage makes every request a transport failure (rc 7).
cat >"$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL=""; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in --data-binary|-d|--data) BODY="$2"; shift 2 ;; -X) M="$2"; shift 2 ;; http*://*) URL="$1"; shift ;; *) shift ;; esac
done
case "$URL" in https://jobs.test*) ;; *) exit 22 ;; esac
case "$BODY" in @-) BODY=$(cat) ;; @*) BODY=$(cat "${BODY#@}") ;; esac
printf '%s %s\n' "$M" "${URL#https://jobs.test}" >> "$CH_T/req.log"
[ -e "$CH_T/outage" ] && exit 7
exec flock "$CH_DB.lock" node "$CH_T/drv.mjs" "$M" "$URL" "$BODY"
STUB
chmod +x "$T/fakebin/curl"

# ── the scratch harness on box "box-a" ───────────────────────────────────────
H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/locks" "$H/state" "$H/env"
: > "$H/env/global.env"
# lane-alert is the alerting seam: record the call instead of paging.
cat > "$H/bin/lane-alert.sh" <<'LA'
#!/bin/bash
printf '%s\n' "$*" >> "$CH_T/alerts.log"
LA
chmod +x "$H/bin/lane-alert.sh"
scratch_install_closure bin/conflict-hotspots-fleet.sh "$H" >/dev/null || bad "closure: conflict-hotspots-fleet.sh"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || bad "closure: jobs-client.sh"
# The scripts the lane EXECUTES (the closure follows what it sources).
cp "$DIR/bin/conflict-hotspots.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$H/bin/"
for f in bin/conflict-hotspots.sh bin/fleet-conf.sh bin/box-for.sh bin/jobs-client.sh bin/lib/lane-gate.sh; do
  [ -f "$H/$f" ] || bad "closure did not install $f"
done
cat > "$H/fleet.conf" <<'EOF'
alpha  example-org/alpha  https://alpha.invalid  -  0  box-a  -
beta   example-org/beta   https://beta.invalid   -  0  box-a  -
gamma  example-org/gamma  https://gamma.invalid  -  0  box-b  -
EOF
REPOS="$T/repos"; mkdir -p "$REPOS" "$T/src" "$T/origin"

# ── fixture repos: real PR merges and conflicted sync merges ─────────────────
NOW=$(date +%s)
SYNC="Merge remote-tracking branch 'origin/main' into HEAD"
at() { local d=$1; shift
  GIT_AUTHOR_DATE="@$((NOW - d*86400)) +0000" GIT_COMMITTER_DATE="@$((NOW - d*86400)) +0000" \
    git -C "$R" "$@" >/dev/null 2>&1; }
newrepo() { R=$1; git init -q -b main "$R"
  git -C "$R" config user.name fixture; git -C "$R" config user.email fixture@example.invalid
  git -C "$R" config commit.gpgsign false; }
# conflict_pr <repo> <n> <file> <days-ago>: branch P<n> and main both append to
# <file>; the branch syncs (a conflicted merge, resolved) and lands as PR #<n>.
conflict_pr() { R=$1; local n=$2 f=$3 d=$4
  at "$d" checkout -q -b "P$n" main; echo "P$n" >> "$R/$f"; at "$d" commit -q -am "P$n edits $f"
  at "$d" checkout -q main; echo "M$n" >> "$R/$f"; at "$d" commit -q -am "main edits $f for $n"
  at $((d-1)) checkout -q "P$n"; at $((d-1)) merge -q main
  { cat "$R/$f" | grep -v '^[<>=|]' ; } > "$R/$f.tmp" && mv "$R/$f.tmp" "$R/$f"
  at $((d-1)) add "$f"; at $((d-1)) commit -q -m "$SYNC"
  at $((d-2)) checkout -q main; at $((d-2)) merge -q --no-ff "P$n" -m "Merge pull request #$n from x/P$n"
}
build() { # <project> — src repo, bare origin, checkout under $REPOS
  local p=$1
  newrepo "$T/src/$p"
  echo base > "$R/hot.txt"; echo base > "$R/warm.txt"; at 20 add -A; at 20 commit -q -m init
  git clone -q --bare "$T/src/$p" "$T/origin/$p.git"
  git -C "$T/src/$p" remote add origin "$T/origin/$p.git"
}
push() { git -C "$T/src/$1" push -q origin main >/dev/null 2>&1; }
build alpha
conflict_pr "$T/src/alpha" 11 hot.txt 12; conflict_pr "$T/src/alpha" 12 hot.txt 9; conflict_pr "$T/src/alpha" 13 warm.txt 6
push alpha
build beta
conflict_pr "$T/src/beta" 21 warm.txt 8
push beta
git clone -q "$T/origin/alpha.git" "$REPOS/alpha"
git clone -q "$T/origin/beta.git" "$REPOS/beta"
# gamma's checkout exists here but gamma belongs to box-b.
git clone -q "$T/origin/beta.git" "$REPOS/gamma"

export PATH="$T/fakebin:$PATH"
lane() { env HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$REPOS" BOX_NAME=box-a \
  HARNESS_SECRET=s JOBS_URL=https://jobs.test JOBS_RETRIES=0 JOBS_RETRY_SLEEP=0 JOBS_TIMEOUT=60 JOBS_ALERT=0 \
  JOBS_BOX=box-a LANE_GATE_CACHE_S=0 bash "$H/bin/conflict-hotspots-fleet.sh" "$@" >"$T/lane.out" 2>"$T/lane.err"; LRC=$?; }
# expected <project>: the measurer's own data rows for that checkout, as
# file<TAB>conflicts<TAB>rebases<TAB>prs, sorted.
expected() { "$DIR/bin/conflict-hotspots.sh" -C "$REPOS/$1" --days 30 2>/dev/null \
  | awk 'NR > 1 && !/^# ref=/' | LC_ALL=C sort; }
stored() { sql "SELECT file, conflicts, rebases, prs FROM conflict_hotspots WHERE project = '$1' ORDER BY file" | LC_ALL=C sort; }
runcol() { sql "SELECT $2 FROM conflict_hotspot_runs WHERE project = '$1'"; }
puts() { grep -c '^PUT /api/conflict-hotspots' "$T/req.log" 2>/dev/null || true; }

# ── F1 ───────────────────────────────────────────────────────────────────────
lane
check "F1 lane rc 0 (rc=$LRC: $(head -c 300 "$T/lane.err"))" '[ "$LRC" = 0 ]'
EA=$(expected alpha); EB=$(expected beta)
check "F1 fixture: alpha's measurer output has rows" '[ -n "$EA" ] && grep -q "^hot.txt	2	" <<<"$EA"'
check "F1 fixture: beta's measurer output has rows" '[ -n "$EB" ]'
check "F1 alpha rows equal the measurer's (got: $(stored alpha | tr '\n' ' '))" '[ "$(stored alpha)" = "$EA" ]'
check "F1 beta rows equal the measurer's" '[ "$(stored beta)" = "$EB" ]'
check "F1 every row is keyed by alpha or beta" '[ "$(sql "SELECT DISTINCT project FROM conflict_hotspots ORDER BY project" | tr "\n" " ")" = "alpha beta " ]'
check "F1 alpha run ok, repo, box, full ref sha" '[ "$(runcol alpha "status, repo, box, ref_sha")" = "ok	example-org/alpha	box-a	$(git -C "$REPOS/alpha" rev-parse origin/main)" ]'
check "F1 files_total = rows_stored = measurer rows" '[ "$(runcol alpha "files_total, rows_stored")" = "$(printf "%s\t%s" "$(printf "%s\n" "$EA" | wc -l | tr -d " ")" "$(printf "%s\n" "$EA" | wc -l | tr -d " ")")" ]'
check "F1 window recorded" '[ "$(runcol alpha window_days)" = 30 ] && [ "$(sql "SELECT DISTINCT window_days FROM conflict_hotspots")" = 30 ]'
check "F1 summary line" 'grep -q "box=box-a projects=2 ok=2 failed=0 skipped=0" "$H/logs/conflict-hotspots.log"'
check "F1 no alert on a clean run" '[ ! -s "$T/alerts.log" ]'

# ── F2 ───────────────────────────────────────────────────────────────────────
BETA1=$(stored beta)
A1=$(stored alpha)
conflict_pr "$T/src/alpha" 14 hot.txt 4
push alpha
lane
EA2=$(expected alpha)
check "F2 lane rc 0" '[ "$LRC" = 0 ]'
check "F2 the fetch brought the new PR: hot.txt now 3 conflicts" 'grep -q "^hot.txt	3	" <<<"$EA2" && [ "$EA2" != "$A1" ]'
check "F2 alpha rows replaced by the new window" '[ "$(stored alpha)" = "$EA2" ]'
check "F2 no duplicate (project,file)" '[ -z "$(sql "SELECT project, file FROM conflict_hotspots GROUP BY project, file HAVING COUNT(*) > 1")" ]'
# beta is re-measured too (its run_at and until move), so its DATA must match.
check "F2 beta's rows unchanged" '[ -n "$BETA1" ] && [ "$(stored beta)" = "$BETA1" ]'

# ── F3 ───────────────────────────────────────────────────────────────────────
check "F3 gamma (box-b) has no runs row" '[ -z "$(runcol gamma status)" ]'
check "F3 gamma has no rows" '[ -z "$(stored gamma)" ]'

# ── F4 ───────────────────────────────────────────────────────────────────────
B_ROWS=$(stored beta); B_OK=$(runcol beta last_ok_at)
git -C "$REPOS/beta" fetch -q --depth 1 origin >/dev/null 2>&1
check "F4 fixture: beta is shallow" '[ "$(git -C "$REPOS/beta" rev-parse --is-shallow-repository)" = true ]'
: > "$T/alerts.log"
lane
check "F4 lane rc 0" '[ "$LRC" = 0 ]'
check "F4 beta run shallow" '[ "$(runcol beta status)" = shallow ]'
check "F4 beta rows kept" '[ "$(stored beta)" = "$B_ROWS" ]'
check "F4 beta last_ok_at kept" '[ "$(runcol beta last_ok_at)" = "$B_OK" ]'
check "F4 alpha still ok" '[ "$(runcol alpha status)" = ok ]'
check "F4 one warn alert naming beta" '[ "$(wc -l < "$T/alerts.log")" = 1 ] && grep -q -- "--severity warn" "$T/alerts.log" && grep -q "beta=shallow" "$T/alerts.log"'
check "F4 summary counts the failure" 'tail -1 "$H/logs/conflict-hotspots.log" | grep -q "projects=2 ok=1 failed=1"'
scratch_rm "$REPOS/beta"; git clone -q "$T/origin/beta.git" "$REPOS/beta"

# ── F5 ───────────────────────────────────────────────────────────────────────
printf 'delta  example-org/delta  https://delta.invalid  -  0  box-a  -\n' >> "$H/fleet.conf"
: > "$T/alerts.log"
lane
check "F5 delta no-checkout" '[ "$(runcol delta status)" = no-checkout ]'
check "F5 alert names delta" 'grep -q "delta=no-checkout" "$T/alerts.log"'
A_ROWS=$(stored alpha); A_RUN=$(runcol alpha run_at)
: > "$T/req.log"; : > "$T/outage"; : > "$T/alerts.log"
lane
rm -f "$T/outage"
check "F5 outage: rc 0" '[ "$LRC" = 0 ]'
check "F5 outage: a PUT was attempted" '[ "$(puts)" -ge 1 ]'
check "F5 outage: log says FAILED" 'grep -q "project=alpha .*FAILED" "$H/logs/conflict-hotspots.log"'
check "F5 outage: never logged stored" '! tail -4 "$H/logs/conflict-hotspots.log" | grep -q "project=alpha .*stored"'
check "F5 outage: alert names the failed PUT" 'grep -q "alpha=put-failed" "$T/alerts.log"'
check "F5 outage: rows untouched" '[ "$(stored alpha)" = "$A_ROWS" ] && [ "$(runcol alpha run_at)" = "$A_RUN" ]'
sed -i '/^delta /d' "$H/fleet.conf"

# ── F6 ───────────────────────────────────────────────────────────────────────
cp "$H/bin/conflict-hotspots.sh" "$T/ch.real"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/conflict-hotspots.sh"
A_ROWS=$(stored alpha)
lane
cp "$T/ch.real" "$H/bin/conflict-hotspots.sh"
check "F6 no header is error" '[ "$(runcol alpha status)" = error ]'
check "F6 detail says why" 'runcol alpha detail | grep -qi "header"'
check "F6 rows kept" '[ "$(stored alpha)" = "$A_ROWS" ]'

# ── F7 ───────────────────────────────────────────────────────────────────────
: > "$T/req.log"
lane --dry-run --project alpha
check "F7 dry-run rc 0" '[ "$LRC" = 0 ]'
check "F7 dry-run sends no PUT" '[ "$(puts)" = 0 ]'
check "F7 dry-run prints alpha's body" 'jq -e "select(.project == \"alpha\") | .status == \"ok\" and (.rows | length) > 0" "$T/lane.out" >/dev/null'
check "F7 dry-run left alpha at error (nothing written)" '[ "$(runcol alpha status)" = error ]'
lane --project gamma
check "F7 --project off this box is rc 2" '[ "$LRC" = 2 ]'

# ── F8 ───────────────────────────────────────────────────────────────────────
: > "$H/flags/lane-off-conflict-hotspots-fleet"; : > "$T/req.log"
lane
rm -f "$H/flags/lane-off-conflict-hotspots-fleet"
check "F8 lane-off: rc 0" '[ "$LRC" = 0 ]'
check "F8 lane-off: no PUT" '[ "$(puts)" = 0 ]'
: > "$T/req.log"
exec 9>"$H/locks/conflict-hotspots.lock"; flock -n 9
lane
exec 9>&-
check "F8 held lock: rc 0" '[ "$LRC" = 0 ]'
check "F8 held lock: no PUT" '[ "$(puts)" = 0 ]'
check "F8 held lock: logged already running" 'tail -1 "$H/logs/conflict-hotspots.log" | grep -q "already running"'
# And once released, a run goes through again.
lane
check "F8 after release: alpha back to ok" '[ "$(runcol alpha status)" = ok ]'

done_
