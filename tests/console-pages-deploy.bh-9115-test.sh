#!/bin/bash
# tests/console-pages-deploy.bh-9115-test.sh — the console-pages deploy snapshot
# holds what console-ui tests read, a red run names its files, one red alert per
# sha, and a stale console raises one alert (BH-9115).
#
# WHY. The snapshot held console-ui, worker and catalog only, so 3 console-ui
# tests that read ../bin/lib/*.sh and ../tests/fixtures/ were red on every run.
# The lane parked each sha, the log line named no test, and the fixed alert id
# counted every later red sha as a repeat that was never sent. Mission Control
# stayed on a 23-day-old deploy and nothing said so.
#
#   S1  the snapshot has bin/ and tests/: a test that reads them is green, deploys
#   S2  a checkout with no bin/ and no tests/ still snapshots and runs npm test
#   L1  Node 22 shape: two failing files, a passing file between, not listed
#   L2  Node 20 wrapper shape: the file once; a wrapper whose children pass is not listed
#   L3  a file that failed to load: listed
#   L4  one file fails twice: listed once; an ok file and a src/ location: not listed
#   L5  25 failing files: the cap 20 and "(+5 more)"; the settings row sets it to 2
#   A1  red alert id console-pages-deploy-red:<C7>, "console not deployed since <date>"
#   A2  a new red console-ui sha: a second alert with a new id
#   A3  green after red: resolves the per-sha id and the legacy bare id; open red id row cleared
#   A4  no deploy record: "since unknown (no deploy record)"
#   K1  red park, oldest undeployed console-ui commit 48 h old: one stale alert
#   K2  the fallback 24 h: fires at exactly 24 h, not at 23 h
#   K3  CONSOLE_PAGES_STALE_ALERT_H=0: off
#   K4  a green deploy: no stale alert, a resolve after the stamp
#   K5  wrangler fails, 48 h old: the stale alert names wrangler
#   K6  the row equals the wanted sha: no stale alert, no npm
#   M1  a parked memo from older lane code (or the old count-only memo): npm test runs again
#   M2  a parked memo from the current lane code: still parked, no npm
#   M3  a red run writes "<count> <lane sha>" to the memo
#
# SCRIPT= points the suite at another deployer.
# Run from anywhere: tests/console-pages-deploy.bh-9115-test.sh  (0 = pass)
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
chk() { if eval "$2"; then ok; else bad "$1"; fi; }
command -v git >/dev/null && command -v flock >/dev/null && command -v timeout >/dev/null \
  && command -v awk >/dev/null || { echo "git/flock/timeout/awk missing — skipping"; exit 0; }
SUT="${SCRIPT:-$DIR/bin/console-pages-deploy.sh}"

# ── fixture: the harness ─────────────────────────────────────────────────────
H=$T/h
mkdir -p "$H/bin/lib" "$H/env" "$H/logs" "$H/state" "$H/locks" "$T/sbin" "$T/knob"
( cd "$DIR" && scratch_install_closure bin/console-pages-deploy.sh "$H" ) >/dev/null || { echo "setup: could not install the deployer closure"; exit 1; }
cp "$SUT" "$H/bin/console-pages-deploy.sh" 2>/dev/null || : > "$H/bin/console-pages-deploy.sh"
chmod +x "$H/bin/console-pages-deploy.sh"
printf 'CLOUDFLARE_API_TOKEN=tok-fixture-9115\n' > "$H/env/cloudflare.env"
NOW=$(date +%s)

# mkrepo <dir> <age of the new console-ui commit, s> [bare] — a main checkout with
# a base commit (the deployed one, 100 h old) and one newer console-ui commit.
# Sets CK, BASE, CSHA, C7. "bare" leaves out bin/ and tests/.
mkrepo() {
  CK=$T/$1
  mkdir -p "$CK/console-ui" "$CK/worker/jobs" "$CK/catalog/lanes.d"
  echo '{"name":"console-ui"}' > "$CK/console-ui/package.json"
  echo '{ "account_id": "acct9115" }' > "$CK/worker/jobs/wrangler.jsonc"
  echo '{}' > "$CK/catalog/lanes.d/x.json"
  if [ "${3:-}" != bare ]; then
    mkdir -p "$CK/bin/lib" "$CK/tests/fixtures"
    echo 'x=1' > "$CK/bin/lib/x.sh"; echo '{}' > "$CK/tests/fixtures/f.json"
  fi
  local d=$((NOW - 360000))
  git -C "$CK" init -q -b main >/dev/null 2>&1
  git -C "$CK" add -A
  GIT_COMMITTER_DATE="@$d" GIT_AUTHOR_DATE="@$d" git -C "$CK" -c user.email=t@t -c user.name=t commit -q -m base
  BASE=$(git -C "$CK" rev-parse HEAD)
  newcommit "$2"
}
# newcommit <age, s> — one more console-ui commit on main in $CK.
NC=0
newcommit() {
  local d=$((NOW - $1))
  NC=$((NC+1)); echo "c$NC $1" >> "$CK/console-ui/app.js"; git -C "$CK" add -A
  GIT_COMMITTER_DATE="@$d" GIT_AUTHOR_DATE="@$d" git -C "$CK" -c user.email=t@t -c user.name=t commit -q -m "ui $1"
  CSHA=$(git -C "$CK" rev-parse HEAD); C7=${CSHA:0:7}
}

# ── stubs: each appends its argv to $T/calls.log ─────────────────────────────
cat > "$H/bin/jobs-client.sh" <<EOF
#!/bin/bash
printf 'jobs-client %s\n' "\$*" >> "$T/calls.log"
case "\$1" in
  setting-get)
    if [ "\$2" = deploy.console-ui.sha ]; then
      rc=\$(cat "$T/row.rc" 2>/dev/null || echo 2)
      [ "\$rc" = 0 ] && { cat "$T/row"; echo; }
      exit "\$rc"
    fi
    [ -f "$T/knob/\$2" ] && { cat "$T/knob/\$2"; exit 0; }
    exit 2 ;;
  setting-set)
    if [ "\$2" = deploy.console-ui.sha ]; then printf '%s' "\$3" > "$T/row"; echo 0 > "$T/row.rc"
    else printf '%s' "\$3" > "$T/knob/\$2"; fi
    exit 0 ;;
esac
exit 1
EOF
cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf 'lane-alert %s\n' "\$*" >> "$T/calls.log"
EOF
cat > "$T/sbin/npm" <<EOF
#!/bin/bash
printf 'npm %s|cwd=%s\n' "\$*" "\$PWD" >> "$T/calls.log"
case "\$1" in
  ci) mkdir -p node_modules; exit 0 ;;
  test)
    if [ -f "$T/need-full" ]; then
      [ -f ../bin/lib/x.sh ] && [ -f ../tests/fixtures/f.json ] || {
        printf 'TAP version 13\nnot ok 1 - U5 round trip\n  ---\n  location: %s\n  ...\n# fail 1\n' "'\$PWD/tests/box-switches.test.js:98:1'"; exit 1; }
    fi
    if [ -f "$T/test.out" ]; then cat "$T/test.out"; exit 1; fi
    printf 'TAP version 13\nok 1 - tests/panel.test.js\n# pass 1\n# fail 0\n'; exit 0 ;;
  run) [ "\$2" = build ] && { mkdir -p dist; echo '<html>' > dist/index.html; exit 0; } ;;
esac
exit 1
EOF
cat > "$T/sbin/npx" <<EOF
#!/bin/bash
printf 'npx %s\n' "\$*" >> "$T/calls.log"
echo "Uploading Functions bundle"
exit "\$(cat "$T/npx.rc" 2>/dev/null || echo 0)"
EOF
# date +%s answers \$T/now when it is set, so the 24 h edge is exact.
cat > "$T/sbin/date" <<EOF
#!/bin/bash
[ "\$*" = +%s ] && [ -f "$T/now" ] && { cat "$T/now"; exit 0; }
exec "$(command -v date)" "\$@"
EOF
cat > "$T/sbin/curl" <<EOF
#!/bin/bash
printf 403
EOF
chmod +x "$H/bin/jobs-client.sh" "$H/bin/lane-alert.sh" "$T/sbin/"*

N=0
# run [VAR=value…] — one deployer run over $CK; fresh calls.log, its own log file.
run() {
  N=$((N+1)); RUNLOG="$H/logs/run$N.log"; rm -f "$T/calls.log"; touch "$T/calls.log"
  env -u CONSOLE_PAGES_DEPLOY -u CONSOLE_PAGES_RED_TRIES -u CONSOLE_PAGES_STALE_ALERT_H \
    -u CONSOLE_PAGES_RED_FILES_MAX -u CONSOLE_POSTMERGE_QA -u CLOUDFLARE_ACCOUNT_ID \
    HARNESS="$H" HARNESS_CHECKOUT="$CK" HARNESS_ENV_DIR="$H/env" PATH="$T/sbin:$PATH" \
    CONSOLE_PAGES_PROBE_WAIT_S=0 "$@" bash "$H/bin/console-pages-deploy.sh" >"$RUNLOG" 2>&1
  RC=$?
}
# reset [row] — no test output, no knobs, no red memo; row = the given sha (or no row).
reset() {
  rm -f "$T/row" "$T/npx.rc" "$T/need-full" "$T/test.out" "$T/knob/"* "$H"/state/console-pages-deploy/*
  if [ -n "${1:-}" ]; then printf '%s' "$1" > "$T/row"; echo 0 > "$T/row.rc"; else echo 2 > "$T/row.rc"; fi
}
has()   { grep -qF -- "$1" "$T/calls.log"; }
npm_ran() { grep -q "^npm " "$T/calls.log"; }
redline() { grep -F 'npm test red at' "$RUNLOG"; }
alerts_on() { grep '^lane-alert' "$T/calls.log" | grep -F -- "--id $1" | grep -vF -- "--resolve"; }
stale_n() { alerts_on console-pages-stale | grep -c .; }

# ── S1 ───────────────────────────────────────────────────────────────────────
mkrepo ck-s1 3600
reset; touch "$T/need-full"; run
chk "S1 rc 0" '[ "$RC" = 0 ]'
chk "S1 tests that read ../bin and ../tests are green: deploys" 'has "npx --yes wrangler@3 pages deploy"'
chk "S1 no red line" '[ -z "$(redline)" ]'

# ── S2 ───────────────────────────────────────────────────────────────────────
mkrepo ck-s2 3600 bare
reset; run
chk "S2 no bin/ no tests/: npm test ran" 'has "npm test|"'
chk "S2 no snapshot failure" '! grep -qF "snapshot of" "$RUNLOG"'
chk "S2 deploys" 'has "npx --yes wrangler@3 pages deploy"'

# ── L1-L5 (red runs on one repo; the red memo is reset each time) ────────────
mkrepo ck-l 3600
reset "$BASE"
cat > "$T/test.out" <<'EOF'
TAP version 13
# Subtest: T1 alpha
not ok 1 - T1 alpha
  ---
  location: '/x/console-ui/tests/a.test.js:10:3'
  ...
# Subtest: T2 beta
ok 2 - T2 beta
  ---
  location: '/x/console-ui/tests/d.test.js:5:1'
  ...
# Subtest: T3 gamma
not ok 3 - T3 gamma
  ---
  location: '/x/console-ui/tests/b.test.js:10:3'
  ...
1..3
# pass 1
# fail 2
EOF
run
chk "L1 rc 0" '[ "$RC" = 0 ]'
chk "L1 names two files in order" 'redline | grep -qF ": 2 failing in 2 file(s): tests/a.test.js, tests/b.test.js — not deploying"'
chk "L1 passing file not named" '! grep -qF d.test.js <<<"$(redline)"'
chk "L1 node version in the line" 'redline | grep -qE "\(try 1, node v[0-9]"'

reset "$BASE"
printf 'TAP version 13\n# Subtest: tests/p.test.js\n    ok 1 - P fine\nok 1 - tests/p.test.js\n# Subtest: tests/c.test.js\n    not ok 7 - C broke\nnot ok 2 - tests/c.test.js\n# fail 1\n' > "$T/test.out"
run
chk "L2 wrapper file once" 'redline | grep -qF ": 1 failing in 1 file(s): tests/c.test.js — not"'
chk "L2 all-pass wrapper not named" '! grep -qF p.test.js <<<"$(redline)"'

reset "$BASE"
printf 'TAP version 13\nnot ok 1 - tests/c.test.js\n  ---\n  error: boom\n  ...\n# fail 1\n' > "$T/test.out"
run
chk "L3 failed load listed" 'redline | grep -qF "in 1 file(s): tests/c.test.js — not"'

reset "$BASE"
cat > "$T/test.out" <<'EOF'
TAP version 13
not ok 1 - A1 one
  ---
  location: '/x/console-ui/tests/a.test.js:1:1'
  ...
not ok 2 - A2 two
  ---
  location: '/x/console-ui/tests/a.test.js:2:1'
  ...
ok 3 - tests/e.test.js
not ok 4 - S1 src
  ---
  location: '/x/console-ui/src/ui/x.js:3:1'
  ...
# fail 3
EOF
run
chk "L4 a.test.js once" 'redline | grep -qF ": 3 failing in 1 file(s): tests/a.test.js — not"'
chk "L4 ok file not named" '! grep -qF e.test.js <<<"$(redline)"'
chk "L4 src location not named" '! grep -qF src/ui <<<"$(redline)"'

reset "$BASE"
{ echo 'TAP version 13'; for i in $(seq 1 25); do printf 'not ok %d - tests/f%02d.test.js\n' "$i" "$i"; done; echo '# fail 25'; } > "$T/test.out"
run CONSOLE_PAGES_RED_FILES_MAX=20
chk "L5 cap 20" 'redline | grep -qF "25 failing in 25 file(s): tests/f01.test.js, "'
chk "L5 20th listed" 'grep -qF "tests/f20.test.js (+5 more) — not" <<<"$(redline)"'
chk "L5 21st not listed" '! grep -qF f21.test.js <<<"$(redline)"'
reset "$BASE"
{ echo 'TAP version 13'; for i in $(seq 1 25); do printf 'not ok %d - tests/f%02d.test.js\n' "$i" "$i"; done; echo '# fail 25'; } > "$T/test.out"
echo 2 > "$T/knob/lane.fleet-propagate.console_pages_red_files_max"
run
chk "L5 settings row cap 2" 'redline | grep -qF "in 25 file(s): tests/f01.test.js, tests/f02.test.js (+23 more) — not"'

# ── A1-A4 ────────────────────────────────────────────────────────────────────
mkrepo ck-a 3600
SINCE=$(git -C "$CK" log -1 --format=%cs "$BASE")
reset "$BASE"; printf 'TAP version 13\nnot ok 1 - tests/c.test.js\n# fail 1\n' > "$T/test.out"; run
A_C7=$C7
chk "A1 one red alert, per-sha id" '[ "$(alerts_on console-pages-deploy-red | grep -c .)" = 1 ] && alerts_on "console-pages-deploy-red:$C7 " | grep -q .'
chk "A1 since date and count" 'alerts_on "console-pages-deploy-red:$C7" | grep -qF "] console not deployed since $SINCE: 1 tests red at $C7"'
chk "A1 keeps REFUSED and the log path" 'alerts_on "console-pages-deploy-red:$C7" | grep -F REFUSED | grep -qF "logs/console-pages-deploy-test-$C7.log"'
chk "A1 open red id row written" '[ "$(cat "$T/knob/deploy.console-ui.open_red_id" 2>/dev/null)" = "console-pages-deploy-red:$C7" ]'

# A2: a new console-ui commit, still red.
newcommit 1800
run
chk "A2 new sha: a new alert id" 'alerts_on "console-pages-deploy-red:$C7 " | grep -q . && [ "$C7" != "$A_C7" ]'
chk "A2 not the old id" '! alerts_on "console-pages-deploy-red:$A_C7" | grep -q .'

# A3: green at the same sha.
rm -f "$T/test.out"; run
chk "A3 resolves the per-sha id" 'has "--resolve --id console-pages-deploy-red:$C7 "'
chk "A3 resolves the legacy bare id" 'has "--resolve --id console-pages-deploy-red fleet-propagate"'
chk "A3 open red id row cleared" '[ "$(cat "$T/knob/deploy.console-ui.open_red_id" 2>/dev/null)" = none ] && [ ! -e "$H/state/console-pages-deploy/open-red-id" ]'
chk "A3 deploys" 'has "npx --yes wrangler@3"'

reset; printf 'TAP version 13\nnot ok 1 - tests/c.test.js\n# fail 1\n' > "$T/test.out"; run
chk "A4 no row: since unknown" 'alerts_on "console-pages-deploy-red:$C7" | grep -qF "console not deployed since unknown (no deploy record): 1 tests red at $C7"'
reset none; printf 'TAP version 13\nnot ok 1 - tests/c.test.js\n# fail 1\n' > "$T/test.out"; run
chk "A4 row none: since unknown" 'alerts_on "console-pages-deploy-red:$C7" | grep -qF "since unknown (no deploy record)"'

# ── K1-K6 ────────────────────────────────────────────────────────────────────
# park <n> — the red memo for $CSHA says npm test was red n times.
park() { mkdir -p "$H/state/console-pages-deploy"; echo "$1" > "$H/state/console-pages-deploy/red-$CSHA"; }
mkrepo ck-k1 172800
reset "$BASE"; park 2; run
chk "K1 parked: no npm" '! npm_ran'
chk "K1 one stale alert" '[ "$(stale_n)" = 1 ]'
chk "K1 stale text" 'alerts_on console-pages-stale | grep -F "Mission Control not deployed for 48h" | grep -F "main'"'"'s console-ui is at $C7" | grep -qF "1 undeployed console-ui commits"'
chk "K1 stale reason: parked" 'alerts_on console-pages-stale | grep -qF "last reason: npm test red 2 time(s) at $C7"'
chk "K1 warn severity" 'alerts_on console-pages-stale | grep -qF -- "--severity warn"'

mkrepo ck-k2a 86400
echo "$NOW" > "$T/now"
reset "$BASE"; park 2; run
chk "K2 exactly 24 h: fires" '[ "$(stale_n)" = 1 ]'
echo $((NOW - 1)) > "$T/now"
reset "$BASE"; park 2; run
chk "K2 one second under 24 h: no stale alert" '[ "$(stale_n)" = 0 ]'
rm -f "$T/now"
mkrepo ck-k2b 82800
reset "$BASE"; park 2; run
chk "K2 23 h: no stale alert" '[ "$(stale_n)" = 0 ]'
reset "$BASE"; park 2; run CONSOLE_PAGES_STALE_ALERT_H=abc
chk "K2 non-number: fallback 24, 23 h: no alert" '[ "$(stale_n)" = 0 ]'
reset "$BASE"; park 2; echo 1 > "$T/knob/lane.fleet-propagate.console_pages_stale_alert_h"; run
chk "K2 settings row 1 h: fires at 23 h" '[ "$(stale_n)" = 1 ]'

CK=$T/ck-k1; CSHA=$(git -C "$CK" rev-parse HEAD); C7=${CSHA:0:7}; BASE=$(git -C "$CK" rev-parse HEAD~1)
reset "$BASE"; park 2; run CONSOLE_PAGES_STALE_ALERT_H=0
chk "K3 off: no stale alert" '[ "$(stale_n)" = 0 ]'

reset "$BASE"; run
chk "K4 green: deploys" 'has "npx --yes wrangler@3"'
chk "K4 green: no stale alert" '[ "$(stale_n)" = 0 ]'
set_ln=$(grep -n '^jobs-client setting-set' "$T/calls.log" | head -1 | cut -d: -f1)
res_ln=$(grep -n -- '--resolve --id console-pages-stale' "$T/calls.log" | head -1 | cut -d: -f1)
chk "K4 resolve after the stamp" '[ -n "$set_ln" ] && [ -n "$res_ln" ] && [ "$res_ln" -gt "$set_ln" ]'

reset "$BASE"; echo 1 > "$T/npx.rc"; run
chk "K5 wrangler fails: stale alert names wrangler" '[ "$(stale_n)" = 1 ] && alerts_on console-pages-stale | grep -qF "last reason: wrangler"'
chk "K5 no stamp" '! has "setting-set"'

reset "$BASE"; printf 'TAP version 13\nnot ok 1 - tests/c.test.js\n# fail 1\n' > "$T/test.out"; run
chk "K5b red run: stale alert names npm test" '[ "$(stale_n)" = 1 ] && alerts_on console-pages-stale | grep -qF "last reason: npm test red at $C7"'

reset "$CSHA"; run
chk "K6 row = wanted sha: no npm" '! npm_ran'
chk "K6 row = wanted sha: no stale alert" '! has "console-pages-stale"'

# ── M1-M3 ────────────────────────────────────────────────────────────────────
# The parked console-ui sha stays the same when only the lane code changes.
mkrepo ck-m 3600
lanecommit() {
  mkdir -p "$CK/bin/lib"; echo "# $1" >> "$CK/bin/console-pages-deploy.sh"; git -C "$CK" add -A
  git -C "$CK" -c user.email=t@t -c user.name=t commit -q -m "lane $1"
  git -C "$CK" rev-parse HEAD
}
OLD_LANE=$(lanecommit v1); NEW_LANE=$(lanecommit v2)
chk "M0 wanted sha unchanged by lane commits" '[ "$(git -C "$CK" rev-list -1 --first-parent HEAD -- console-ui)" = "$CSHA" ]'
reset "$BASE"; park "2 $OLD_LANE"; run
chk "M1 memo from old lane code: npm test runs" 'has "npm test|"'
chk "M1 memo from old lane code: deploys" 'has "npx --yes wrangler@3"'
chk "M1 logs the cleared memo" 'grep -qF "red memo at $C7 is from lane code ${OLD_LANE:0:7}, the lane is now at ${NEW_LANE:0:7}" "$RUNLOG"'
reset "$BASE"; park 2; run
chk "M1 count-only memo: npm test runs" 'has "npm test|"'
reset "$BASE"; park "2 $NEW_LANE"; run
chk "M2 memo from current lane code: no npm" '! npm_ran'
chk "M2 logs the park" 'grep -qF "not re-running" "$RUNLOG"'
reset "$BASE"; printf 'TAP version 13\nnot ok 1 - tests/c.test.js\n# fail 1\n' > "$T/test.out"; run
chk "M3 memo holds count and lane sha" '[ "$(cat "$H/state/console-pages-deploy/red-$CSHA" 2>/dev/null)" = "1 $NEW_LANE" ]'

echo "console-pages-deploy.bh-9115: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
