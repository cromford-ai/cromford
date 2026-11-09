#!/bin/bash
# tests/console-pages-deploy.bh-3563-test.sh — harness-sync deploys console-ui to
# Cloudflare Pages on the hub, sha-gated on the settings row (BH-3563, the
# BH-3554.2 slice).
#
# WHY. The live console sat 15 days on dee684a1 while about 230 console-ui
# commits merged, because Pages was deployed only by hand. bin/console-pages-deploy.sh
# now runs detached from bin/harness-sync.sh wherever cloudflare.env is.
#
#   C1  row = the wanted sha: no npm, no npx
#   C2  no row: green deploy with the exact wrangler argv, the stamp after it,
#       the checkout untouched, no scratch left behind
#   C3  red npm test: refused with one named alert, the test log kept, two
#       tries per sha, then no re-run
#   C4  green after red on the same sha: the red alert resolves, the memo goes
#   C5  wrangler fails: a STALE alert and no stamp
#   C6  the anonymous probes: 403/403, 200, 503, 404, 000
#   C7  a settings outage: no deploy
#   C8  CONSOLE_PAGES_DEPLOY=0, and a box with no cloudflare.env
#   C9  npm test runs in a full-tree snapshot under state/ (pinned by the stub)
#   C10 the row is a descendant of the wanted sha: skip
#   C11 the lock is held: skip
#   C12 the API token never reaches logs/ or an alert
#   C13 row = none: redeploys
#   H1  the harness-sync block returns at once and the deployer finishes after
#   H2  the block does not inherit the caller's fd-9 lock
#   H3  no cloudflare.env: the block launches nothing
#
# SCRIPT= points C* at another deployer, HSYNC= points H* at another harness-sync.
# Run from anywhere: tests/console-pages-deploy.bh-3563-test.sh  (0 = pass)
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
HSYNC="${HSYNC:-$DIR/bin/harness-sync.sh}"
TOK=tok-SECRET-3563

# ── fixture ──────────────────────────────────────────────────────────────────
H=$T/h
mkdir -p "$H/bin/lib" "$H/env" "$H/logs" "$H/state" "$H/locks" "$T/sbin"
cp "$SUT" "$H/bin/console-pages-deploy.sh" 2>/dev/null || : > "$H/bin/console-pages-deploy.sh"
cp "$DIR/bin/lib/console-pages.sh" "$DIR/bin/lib/env-path.sh" "$H/bin/lib/"
chmod +x "$H/bin/console-pages-deploy.sh"
printf 'CLOUDFLARE_API_TOKEN=%s\n' "$TOK" > "$H/env/cloudflare.env"

CK=$T/ck
g() { git -C "$CK" -c user.email=t@t -c user.name=t "$@" >/dev/null 2>&1; }
mkdir -p "$CK/console-ui" "$CK/worker/jobs" "$CK/catalog/lanes.d"
echo '{"name":"console-ui"}' > "$CK/console-ui/package.json"
printf '{\n  // "account_id": "commented-out",\n  "account_id": "acct123"\n}\n' > "$CK/worker/jobs/wrangler.jsonc"
echo '{}' > "$CK/catalog/lanes.d/x.json"
g init -q -b main "$CK"; g add -A; g commit -q -m base
g checkout -q -b feat; echo 'x' > "$CK/console-ui/app.js"; g add -A; g commit -q -m feat
g checkout -q main; g merge -q --no-ff feat -m merge-feat
CSHA=$(git -C "$CK" rev-parse HEAD); C7=${CSHA:0:7}

# ── stubs: each appends its argv to $T/calls.log ─────────────────────────────
cat > "$H/bin/jobs-client.sh" <<EOF
#!/bin/bash
printf 'jobs-client %s\n' "\$*" >> "$T/calls.log"
case "\$1" in
  setting-get)
    [ "\$2" = deploy.console-ui.sha ] || exit 2
    rc=\$(cat "$T/row.rc" 2>/dev/null || echo 2)
    [ "\$rc" = 0 ] && { cat "$T/row"; echo; }
    exit "\$rc" ;;
  setting-set) [ "\$2" = deploy.console-ui.sha ] && { printf '%s' "\$3" > "$T/row"; echo 0 > "$T/row.rc"; }; exit 0 ;;
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
  ci) mkdir -p node_modules; exit "\$(cat "$T/ci.rc" 2>/dev/null || echo 0)" ;;
  test)
    case "\$PWD" in "$H/state/console-snap."?*) ;; *) echo "cwd \$PWD is not a snapshot"; exit 1 ;; esac
    [ -f ../worker/jobs/wrangler.jsonc ] && [ -d ../catalog/lanes.d ] || { echo "not a full tree"; exit 1; }
    if [ "\$(cat "$T/test.mode" 2>/dev/null)" = red ]; then
      printf 'TAP version 13\n# Subtest: tests/panel.test.js\n    not ok 7 - BuildQueuePanel (mounted): a refused DROP keeps the row\nnot ok 1 - tests/panel.test.js\n# pass 40\n# fail 1\n'
      exit 1
    fi
    printf 'TAP version 13\nok 1 - tests/panel.test.js\n# pass 41\n# fail 0\n'; exit 0 ;;
  run) [ "\$2" = build ] && { mkdir -p dist; echo '<html>' > dist/index.html; exit 0; } ;;
esac
exit 1
EOF
cat > "$T/sbin/npx" <<EOF
#!/bin/bash
printf 'npx %s|cwd=%s|acct=%s\n' "\$*" "\$PWD" "\${CLOUDFLARE_ACCOUNT_ID:-}" >> "$T/calls.log"
[ -f "$T/nobundle" ] || echo "Uploading Functions bundle"
echo "Authorization: Bearer \$CLOUDFLARE_API_TOKEN"
echo "retrying with token=\$CLOUDFLARE_API_TOKEN"
exit "\$(cat "$T/npx.rc" 2>/dev/null || echo 0)"
EOF
cat > "$T/sbin/curl" <<EOF
#!/bin/bash
for a in "\$@"; do case "\$a" in http*) u=\$a ;; esac; done
printf 'curl %s\n' "\$u" >> "$T/calls.log"
cat "$T/code.\${u##*/}" 2>/dev/null || printf 403
EOF
chmod +x "$H/bin/jobs-client.sh" "$H/bin/lane-alert.sh" "$T/sbin/"*

N=0
# run [VAR=value…] — one deployer run; fresh calls.log, its own log file.
run() {
  N=$((N+1)); RUNLOG="$H/logs/console-pages-deploy-run$N.log"; rm -f "$T/calls.log"; touch "$T/calls.log"
  env -u CONSOLE_PAGES_DEPLOY -u CONSOLE_PAGES_RED_TRIES -u CLOUDFLARE_ACCOUNT_ID -u CLOUDFLARE_API_TOKEN \
    HARNESS="$H" HARNESS_CHECKOUT="$CK" HARNESS_ENV_DIR="$H/env" PATH="$T/sbin:$PATH" \
    CONSOLE_PAGES_PROBE_WAIT_S=0 "$@" bash "$H/bin/console-pages-deploy.sh" >"$RUNLOG" 2>&1
  RC=$?
}
reset() { rm -f "$T/row" "$T/npx.rc" "$T/ci.rc" "$T/nobundle" "$T"/code.*; echo 2 > "$T/row.rc"; echo green > "$T/test.mode"; rm -f "$H"/state/console-pages-deploy/red-*; }
has()   { grep -qF -- "$1" "$T/calls.log"; }
count() { grep -cF -- "$1" "$T/calls.log"; }

# ── C1 ───────────────────────────────────────────────────────────────────────
reset; printf '%s' "$CSHA" > "$T/row"; echo 0 > "$T/row.rc"; run
chk "C1 rc 0" '[ "$RC" = 0 ]'
chk "C1 row = CSHA: no npm" '! has "npm "'
chk "C1 row = CSHA: no npx" '! has "npx "'

# ── C20: deploy only from main ───────────────────────────────────────────────
# A checkout parked on a side branch never ships its console-ui to production.
reset; g checkout -q feat; run
chk "C20 rc 0" '[ "$RC" = 0 ]'
chk "C20 checkout off main: no npm" '! has "npm "'
chk "C20 checkout off main: no npx" '! has "npx "'
chk "C20 says why" 'grep -qF "not on main" "$RUNLOG"'
g checkout -q main

# ── C2 + C9 + C12 ────────────────────────────────────────────────────────────
reset; run
chk "C2 rc 0" '[ "$RC" = 0 ]'
chk "C2/C9 npm test ran green in the snapshot" 'has "npm test|cwd=$H/state/console-snap."'
chk "C2 exact wrangler argv" 'has "npx --yes wrangler@3 pages deploy dist --project-name mission-control --branch main --commit-hash $CSHA --commit-message harness-sync $C7|"'
chk "C2 account id from the snapshot's wrangler.jsonc" 'has "|acct=acct123"'
chk "C2 stamp written" 'has "jobs-client setting-set deploy.console-ui.sha $CSHA "'
npx_ln=$(grep -n '^npx ' "$T/calls.log" | head -1 | cut -d: -f1)
set_ln=$(grep -n '^jobs-client setting-set' "$T/calls.log" | head -1 | cut -d: -f1)
chk "C2 stamp after the deploy" '[ -n "$npx_ln" ] && [ -n "$set_ln" ] && [ "$set_ln" -gt "$npx_ln" ]'
chk "C2 checkout clean" '[ -z "$(git -C "$CK" status --porcelain)" ]'
chk "C2 no node_modules/dist under the checkout" '[ -z "$(find "$CK" -name node_modules -o -name dist)" ]'
chk "C2 no scratch left" '! ls -d "$H"/state/console-snap.* >/dev/null 2>&1'
chk "C2 logs the deploy" 'grep -qF "console-ui deployed at $C7" "$RUNLOG"'
chk "C2 deploy log reached logs/" 'grep -qF "Uploading Functions bundle" "$RUNLOG"'
chk "C12 token not in the deploy log" '! grep -qF "$TOK" "$RUNLOG"'
chk "C12 Bearer scrubbed" 'grep -qF "Bearer ***" "$RUNLOG"'
chk "C6 403/403: no warn or critical" '! grep -E "^lane-alert .*--(severity|critical)" "$T/calls.log" | grep -qE "probe|failopen"'
chk "C6 403/403: resolves the probe ids" 'has "--resolve --id console-pages-probe" && has "--resolve --id console-pages-failopen"'
chk "C6 403/403 logged" 'grep -qF "probes 403/403" "$RUNLOG"'

# ── C3 ───────────────────────────────────────────────────────────────────────
reset; echo red > "$T/test.mode"; run
chk "C3 rc 0" '[ "$RC" = 0 ]'
chk "C3 red: no npx" '! has "npx "'
chk "C3 red: no stamp" '! has "setting-set deploy.console-ui.sha"'
chk "C3 exactly one red alert" '[ "$(grep -F -- "--id console-pages-deploy-red" "$T/calls.log" | grep -vcF -- "--resolve")" = 1 ]'
chk "C3 alert names the failing test" 'grep -F -- "--id console-pages-deploy-red" "$T/calls.log" | grep -F "$C7" | grep -F REFUSED | grep -qF "BuildQueuePanel (mounted)"'
chk "C3 alert names the test's file" 'grep -F -- "--id console-pages-deploy-red" "$T/calls.log" | grep -qF "BuildQueuePanel (mounted): a refused DROP keeps the row [tests/panel.test.js]"'
chk "C3 wrapper not listed on its own" '! grep -F -- "--id console-pages-deploy-red" "$T/calls.log" | grep -qE "(\(|; )tests/panel\.test\.js"'
chk "C3 test log kept" '[ -s "$H/logs/console-pages-deploy-test-$C7.log" ]'
run
chk "C3 second run re-runs npm test" '[ "$(count "npm test|")" = 1 ]'
run
chk "C3 third run: no npm test" '! has "npm "'
chk "C3 third run logs why" 'grep -qF "not re-running" "$RUNLOG"'

# ── C4 ───────────────────────────────────────────────────────────────────────
echo green > "$T/test.mode"; echo 1 > "$H/state/console-pages-deploy/red-$CSHA"; run
chk "C4 green resolves the red alert" 'has "--resolve --id console-pages-deploy-red"'
chk "C4 memo gone" '[ ! -e "$H/state/console-pages-deploy/red-$CSHA" ]'
chk "C4 deploys" 'has "npx "'

# ── C5 ───────────────────────────────────────────────────────────────────────
reset; echo 1 > "$T/npx.rc"; run
chk "C5 rc 0" '[ "$RC" = 0 ]'
chk "C5 STALE alert" 'grep -F -- "--id console-pages-deploy-failed" "$T/calls.log" | grep -v -- "--resolve" | grep -qF STALE'
chk "C5 no stamp" '! has "setting-set"'
chk "C5 no probes" '! has "curl "'
reset; touch "$T/nobundle"; run
chk "C5b no Functions bundle: warns 404" 'grep -F -- "--id console-pages-deploy-failed" "$T/calls.log" | grep -v -- "--resolve" | grep -qF "Uploading Functions bundle"'
chk "C5b no Functions bundle: still stamps" 'has "setting-set deploy.console-ui.sha $CSHA"'

# ── C6 ───────────────────────────────────────────────────────────────────────
reset; printf 200 > "$T/code.jobs"; run
chk "C6 200: critical failopen" 'grep -F -- "--critical" "$T/calls.log" | grep -F -- "--id console-pages-failopen" | grep -qF SECURITY'
reset; printf 503 > "$T/code.jobs"; run
chk "C6 503: probe warn" 'grep -F -- "--id console-pages-probe" "$T/calls.log" | grep -v -- "--resolve" | grep -qF "=503"'
chk "C6 503: no critical" '! has "--critical"'
reset; printf 404 > "$T/code.list"; run
chk "C6 404: probe warn" 'grep -F -- "--id console-pages-probe" "$T/calls.log" | grep -v -- "--resolve" | grep -qF "=404"'
reset; printf 000 > "$T/code.jobs"; run
chk "C6 000: six rounds" '[ "$(count "curl ")" = 12 ]'
chk "C6 000: probe warn" 'grep -F -- "--id console-pages-probe" "$T/calls.log" | grep -v -- "--resolve" | grep -qF "=000"'

# ── C7 ───────────────────────────────────────────────────────────────────────
reset; echo 1 > "$T/row.rc"; run
chk "C7 outage: no npm" '! has "npm "'
chk "C7 outage: no npx" '! has "npx "'
chk "C7 outage logged" 'grep -qF "not deploying blind" "$RUNLOG"'

# ── C8 ───────────────────────────────────────────────────────────────────────
reset; run CONSOLE_PAGES_DEPLOY=0
chk "C8 off: no npm/npx" '! has "npm " && ! has "npx "'
chk "C8 off: no setting-set" '! has "setting-set"'
chk "C8 off: one log line" '[ "$(wc -l < "$RUNLOG")" = 1 ] && grep -qF off "$RUNLOG"'
reset; mv "$H/env/cloudflare.env" "$T/cf.env"; run
chk "C8 no cloudflare.env: no calls" '[ ! -s "$T/calls.log" ]'
chk "C8 no cloudflare.env: no log" '[ ! -s "$RUNLOG" ]'
mv "$T/cf.env" "$H/env/cloudflare.env"

# ── C11 ──────────────────────────────────────────────────────────────────────
reset; exec 7>"$H/locks/console-pages-deploy.lock"; flock -n 7; run; exec 7>&-
chk "C11 held lock: rc 0" '[ "$RC" = 0 ]'
chk "C11 held lock: no npm" '! has "npm "'

# ── C13 ──────────────────────────────────────────────────────────────────────
reset; printf none > "$T/row"; echo 0 > "$T/row.rc"; run
chk "C13 row none: deploys" 'has "npx "'

# ── C10 (moves main on, so last) ─────────────────────────────────────────────
echo readme > "$CK/README"; g add -A; g commit -q -m later
reset; git -C "$CK" rev-parse HEAD | tr -d '\n' > "$T/row"; echo 0 > "$T/row.rc"; run
chk "C10 row is a descendant: no npm" '! has "npm "'

# ── C12 over everything ──────────────────────────────────────────────────────
chk "C12 token nowhere under logs/" '! grep -rqF "$TOK" "$H/logs"'
chk "C12 token in no alert" '! grep "^lane-alert" "$T/calls.log" | grep -qF "$TOK"'

# ── H1-H3: the harness-sync block ────────────────────────────────────────────
BLOCK=$(sed -n '/^# >>> console pages deploy/,/^# <<< console pages deploy/p' "$HSYNC")
chk "H block present in harness-sync" '[ -n "$BLOCK" ]'
H2=$T/h2; mkdir -p "$H2/bin" "$H2/env" "$H2/logs"
cat > "$H2/bin/console-pages-deploy.sh" <<EOF
#!/bin/bash
touch "$T/stub-started"
i=0; while [ ! -f "$T/release" ] && [ \$i -lt 200 ]; do sleep 0.05; i=\$((i+1)); done
echo "stub-marker-done"; touch "$T/stub-done"
EOF
chmod +x "$H2/bin/console-pages-deploy.sh"
wait_for() { local i=0; while [ ! -e "$1" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i+1)); done; [ -e "$1" ]; }
hrun() { HARNESS="$H2" CHECKOUT="$CK" HENV="$H2/env" CFENV="$H2/env/cloudflare.env" timeout 5 bash -c "$BLOCK"; }

: > "$H2/env/cloudflare.env"
t0=$(date +%s%N); hrun; HRC=$?; el=$(( ($(date +%s%N) - t0) / 1000000 ))
chk "H1 block rc 0" '[ "$HRC" = 0 ]'
chk "H1 block returns in under 3 s" '[ "$el" -lt 3000 ]'
chk "H1 deployer launched" 'wait_for "$T/stub-started"'
chk "H1 deployer still running after the block returned" '[ ! -e "$T/stub-done" ]'
touch "$T/release"
chk "H1 deployer finishes after release" 'wait_for "$T/stub-done"'
sleep 0.2
chk "H1 deployer output in its own log" 'grep -qF stub-marker-done "$H2/logs/console-pages-deploy.log"'

rm -f "$T/release" "$T/stub-started" "$T/stub-done"
( exec 9>"$T/fp.lock"; flock -n 9 || exit 1; hrun )
wait_for "$T/stub-started" >/dev/null
chk "H2 the caller's fd-9 lock is free while the deployer runs" '[ ! -e "$T/stub-done" ] && flock -n "$T/fp.lock" true'
touch "$T/release"; wait_for "$T/stub-done" >/dev/null

rm -f "$T/release" "$T/stub-started" "$T/stub-done" "$H2/env/cloudflare.env"
hrun; sleep 1
chk "H3 no cloudflare.env: nothing launched" '[ ! -e "$T/stub-started" ]'
touch "$T/release"

echo "console-pages-deploy.bh-3563: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
