#!/bin/bash
# tests/console-db-schema.bh-9308-test.sh — bin/console-db-schema.sh applies
# console-ui/schema.d/*.sql to harness-console-db through the D1 query API, and
# bin/console-pages-deploy.sh runs it after the deploy stamp (BH-9308).
#
# WHY. The console's log screens read runs by started_at and commands by
# created_at over a range. harness-console-db had no index for either, and this
# repo had no way to apply one: the Pages deploy shipped code only.
#
#   A1  the real fragment: 3 POSTs, one resolve, 0 warn alerts, rc 0, "applied 3"
#   A2  the token reaches curl on stdin, never argv, never stdout
#   F1  HTTP 403 on the 2nd statement: 1 warn alert naming that index, no resolve, rc 0
#   F2  success:false on one statement: no resolve, 1 warn alert, rc 0
#   F3  curl itself fails (rc 28, code 000): 1 warn alert, no resolve, rc 0
#   R1  a DROP INDEX statement: rc 2, 0 POSTs, the statement printed
#   R2  a CREATE TABLE statement: rc 2, 0 POSTs
#   R3  a refused file after a good one: rc 2, 0 POSTs (validate before any POST)
#   N1  no token: 1 warn alert naming all 3 indexes, 0 POSTs, rc 0
#   N2  no cloudflare.env: 1 warn alert, 0 POSTs, rc 0
#   N3  no schema.d: rc 0, 0 POSTs, 0 alerts
#   K1  settings row console_db.schema_apply_timeout_s=45 is curl --max-time 45
#   K2  the settings read fails: --max-time 30
#   K3  the row is out of range (500): --max-time 30
#   J1  the jobs fragment seeds the console_db.schema_apply_timeout_s row
#   D1  console-pages-deploy.sh calls it with --root <snapshot> after the stamp
#   D2  a console-db-schema.sh that fails leaves the deploy's rc 0
#
# Run from anywhere: tests/console-db-schema.bh-9308-test.sh  (0 = pass)
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
chk() { if eval "$2"; then ok; else bad "$1"; fi; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
SUT="$DIR/bin/console-db-schema.sh"
FRAG="$DIR/console-ui/schema.d/202611261813-bh-9308-console-log-indexes.sql"

# ── fixture: a harness with stubs, a root with the real fragment ─────────────
H=$T/h
mkdir -p "$H/bin/lib" "$H/env" "$H/logs" "$T/sbin" "$T/knob" "$T/root/console-ui/schema.d" "$T/root/worker/jobs"
( cd "$DIR" && scratch_install_closure bin/console-db-schema.sh "$H" ) >/dev/null || { echo "setup: could not install the closure"; exit 1; }
cp "$FRAG" "$T/root/console-ui/schema.d/" 2>/dev/null || true
echo '{ "account_id": "acct9308" }' > "$T/root/worker/jobs/wrangler.jsonc"
TOK=tok-fixture-9308-secret

cat > "$H/bin/jobs-client.sh" <<EOF
#!/bin/bash
printf 'jobs-client %s\n' "\$*" >> "$T/calls.log"
case "\$1" in
  setting-get)
    [ -f "$T/knob.fail" ] && exit 1
    [ -f "$T/knob/\$2" ] && { cat "$T/knob/\$2"; echo; exit 0; }
    exit 2 ;;
esac
exit 1
EOF
cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf 'lane-alert %s\n' "\$*" >> "$T/calls.log"
EOF
# curl: one line per call to posts.log (argv + the body file's sql), stdin to
# stdin.log. CURL_SCEN: ok | 403@N | false@N | fail@N (N = the Nth call).
cat > "$T/sbin/curl" <<'EOF'
#!/bin/bash
out=""; body=""; args="$*"
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --data-binary) body="${2#@}"; shift 2 ;;
    *) shift ;;
  esac
done
cat >> "$FAKE_T/stdin.log"
n=$(( $(cat "$FAKE_T/posts.log" 2>/dev/null | wc -l) + 1 ))
printf '%s | sql=%s\n' "$args" "$(jq -r .sql "$body" 2>/dev/null)" >> "$FAKE_T/posts.log"
scen="${CURL_SCEN:-ok}"; code=200; resp='{"success":true,"result":[{"success":true,"results":[]}]}'
case "$scen" in
  "403@$n") code=403; resp='{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}' ;;
  "false@$n") resp='{"success":false,"errors":[{"code":7500,"message":"no such table: runs"}]}' ;;
  "fail@$n") printf '000'; exit 28 ;;
esac
[ -n "$out" ] && printf '%s' "$resp" > "$out"
printf '%s' "$code"
EOF
chmod +x "$H/bin/jobs-client.sh" "$H/bin/lane-alert.sh" "$T/sbin/curl"

# run [VAR=value…] -- [script args…] — one run over $T/root.
run() {
  rm -f "$T/calls.log" "$T/posts.log" "$T/stdin.log"; touch "$T/calls.log" "$T/posts.log" "$T/stdin.log"
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  env -u CLOUDFLARE_ACCOUNT_ID -u CLOUDFLARE_API_TOKEN -u CONSOLE_D1_ID \
    HARNESS="$H" HARNESS_ENV_DIR="$H/env" PATH="$T/sbin:$PATH" FAKE_T="$T" \
    "${envs[@]}" bash "$SUT" --root "$T/root" "$@" >"$T/out.log" 2>&1
  RC=$?
}
reset() {
  rm -f "$T/knob/"* "$T/knob.fail"
  printf 'CLOUDFLARE_API_TOKEN=%s\n' "$TOK" > "$H/env/cloudflare.env"
  rm -f "$T/root/console-ui/schema.d/"*
  cp "$FRAG" "$T/root/console-ui/schema.d/" 2>/dev/null || true
}
posts()    { grep -c . "$T/posts.log"; }
warns()    { grep '^lane-alert' "$T/calls.log" | grep -F -- '--id console-db-schema' | grep -vF -- '--resolve'; }
resolves() { grep '^lane-alert' "$T/calls.log" | grep -F -- '--resolve' | grep -F -- '--id console-db-schema'; }
nwarn()    { warns | grep -c .; }
nres()     { resolves | grep -c .; }

# ── A1/A2 ────────────────────────────────────────────────────────────────────
reset; run
chk "A1 the fragment exists" '[ -f "$FRAG" ]'
chk "A1 rc 0 (got $RC)" '[ "$RC" = 0 ]'
chk "A1 3 POSTs (got $(posts))" '[ "$(posts)" = 3 ]'
chk "A1 POSTs go to the console D1 query endpoint" '[ "$(grep -c "accounts/acct9308/d1/database/00000000-0000-0000-0000-000000000001/query" "$T/posts.log")" = 3 ]'
chk "A1 POST 1 is idx_runs_started" 'sed -n 1p "$T/posts.log" | grep -qF "sql=CREATE INDEX IF NOT EXISTS idx_runs_started ON runs(started_at, id)"'
chk "A1 POST 2 is idx_runs_project_started" 'sed -n 2p "$T/posts.log" | grep -qF "sql=CREATE INDEX IF NOT EXISTS idx_runs_project_started ON runs(project, started_at, id)"'
chk "A1 POST 3 is idx_commands_created" 'sed -n 3p "$T/posts.log" | grep -qF "sql=CREATE INDEX IF NOT EXISTS idx_commands_created ON commands(created_at, id)"'
chk "A1 one resolve" '[ "$(nres)" = 1 ]'
chk "A1 0 warn alerts" '[ "$(nwarn)" = 0 ]'
chk "A1 the applied line" 'grep -qF "console-db-schema: applied 3 index statements to harness-console-db" "$T/out.log"'
chk "A2 token on stdin" 'grep -qF "Bearer $TOK" "$T/stdin.log"'
chk "A2 token not in argv" '! grep -qF "$TOK" "$T/posts.log"'
chk "A2 token not on stdout" '! grep -qF "$TOK" "$T/out.log"'
chk "A2 CONSOLE_D1_ID wins" 'run CONSOLE_D1_ID=d1-other; grep -q "d1/database/d1-other/query" "$T/posts.log"'

# ── F1-F3 ────────────────────────────────────────────────────────────────────
reset; run CURL_SCEN=403@2
chk "F1 rc 0 (got $RC)" '[ "$RC" = 0 ]'
chk "F1 every statement still tried" '[ "$(posts)" = 3 ]'
chk "F1 1 warn alert" '[ "$(nwarn)" = 1 ]'
chk "F1 it names idx_runs_project_started and HTTP 403" 'warns | grep -F idx_runs_project_started | grep -qF "HTTP 403"'
chk "F1 it does not name the applied ones" '! warns | grep -qF "idx_runs_started "'
chk "F1 it names the token and D1 edit" 'warns | grep -qF "the hub'"'"'s CLOUDFLARE_API_TOKEN needs D1 edit on harness-console-db"'
chk "F1 severity warn" 'warns | grep -qF -- "--severity warn"'
chk "F1 no resolve" '[ "$(nres)" = 0 ]'
chk "F1 no applied line" '! grep -qF "applied 3" "$T/out.log"'
reset; run CURL_SCEN=false@3
chk "F2 rc 0" '[ "$RC" = 0 ]'
chk "F2 no resolve" '[ "$(nres)" = 0 ]'
chk "F2 1 warn alert naming idx_commands_created" '[ "$(nwarn)" = 1 ] && warns | grep -qF idx_commands_created'
reset; run CURL_SCEN=fail@1
chk "F3 rc 0" '[ "$RC" = 0 ]'
chk "F3 no resolve" '[ "$(nres)" = 0 ]'
chk "F3 1 warn alert naming idx_runs_started" '[ "$(nwarn)" = 1 ] && warns | grep -qF "idx_runs_started (HTTP 000"'

# ── R1-R3 ────────────────────────────────────────────────────────────────────
reset; printf -- '-- a drop\nDROP INDEX IF EXISTS idx_runs_started;\n' > "$T/root/console-ui/schema.d/202611261900-x-drop.sql"
run
chk "R1 rc 2 (got $RC)" '[ "$RC" = 2 ]'
chk "R1 0 POSTs" '[ "$(posts)" = 0 ]'
chk "R1 the refused statement and file printed" 'grep -F "DROP INDEX IF EXISTS idx_runs_started" "$T/out.log" | grep -qF "202611261900-x-drop.sql"'
chk "R1 no resolve" '[ "$(nres)" = 0 ]'
reset; printf 'CREATE TABLE IF NOT EXISTS t (id INTEGER);\n' > "$T/root/console-ui/schema.d/202611261900-y-table.sql"
run
chk "R2 CREATE TABLE: rc 2" '[ "$RC" = 2 ]'
chk "R2 0 POSTs" '[ "$(posts)" = 0 ]'
reset; printf 'create index if not exists idx_a on runs(a);\nCREATE INDEX IF NOT EXISTS idx_b ON runs(b); DELETE FROM runs;\n' > "$T/root/console-ui/schema.d/202611261900-z-mixed.sql"
run
chk "R3 a DELETE after good statements: rc 2" '[ "$RC" = 2 ]'
chk "R3 0 POSTs" '[ "$(posts)" = 0 ]'
chk "R3 the DELETE printed" 'grep -qF "DELETE FROM runs" "$T/out.log"'
reset; printf 'create index if not exists idx_lower on runs(a);\n' > "$T/root/console-ui/schema.d/202611261900-w-lower.sql"
run
chk "R4 lowercase create index is accepted: 4 POSTs" '[ "$RC" = 0 ] && [ "$(posts)" = 4 ]'

# ── N1-N3 ────────────────────────────────────────────────────────────────────
reset; printf 'OTHER=1\n' > "$H/env/cloudflare.env"; run
chk "N1 rc 0 (got $RC)" '[ "$RC" = 0 ]'
chk "N1 0 POSTs" '[ "$(posts)" = 0 ]'
chk "N1 1 warn alert" '[ "$(nwarn)" = 1 ]'
chk "N1 it names the 3 indexes" 'warns | grep -F idx_runs_started | grep -F idx_runs_project_started | grep -qF idx_commands_created'
chk "N1 no resolve" '[ "$(nres)" = 0 ]'
reset; rm -f "$H/env/cloudflare.env"; run
chk "N2 no cloudflare.env: rc 0, 0 POSTs, 1 alert" '[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && [ "$(nwarn)" = 1 ]'
reset; rm -f "$T/root/console-ui/schema.d/"*; run
chk "N3 no fragments: rc 0, 0 POSTs, 0 alerts" '[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && [ "$(grep -c "^lane-alert" "$T/calls.log")" = 0 ]'

# ── K1-K3 ────────────────────────────────────────────────────────────────────
reset; echo 45 > "$T/knob/console_db.schema_apply_timeout_s"; run
chk "K1 the row is read" 'grep -qF "setting-get console_db.schema_apply_timeout_s" "$T/calls.log"'
chk "K1 --max-time 45 on every POST" '[ "$(grep -c -- "--max-time 45 " "$T/posts.log")" = 3 ]'
reset; touch "$T/knob.fail"; run
chk "K2 a failed read: --max-time 30" '[ "$(grep -c -- "--max-time 30 " "$T/posts.log")" = 3 ] && [ "$RC" = 0 ]'
reset; echo 500 > "$T/knob/console_db.schema_apply_timeout_s"; run
chk "K3 out of range: --max-time 30" '[ "$(grep -c -- "--max-time 30 " "$T/posts.log")" = 3 ]'

# ── J1 ───────────────────────────────────────────────────────────────────────
JF="$DIR/worker/jobs/schema.d/202611090614-bh-9120-4-log-indexes.sql"
chk "J1 the jobs fragment exists" '[ -f "$JF" ]'
chk "J1 it inserts into settings" 'grep -qiE "insert[[:space:]]+or[[:space:]]+ignore[[:space:]]+into[[:space:]]+settings" "$JF" 2>/dev/null'
chk "J1 it seeds console_db.schema_apply_timeout_s = 30" \
  'grep -qE "'"'"'console_db\.schema_apply_timeout_s'"'"'[[:space:]]*,[[:space:]]*'"'"'30'"'"'" "$JF" 2>/dev/null'

# ── D1/D2: the deployer, run for real with stubs ─────────────────────────────
DH=$T/dh; CK=$T/ck
mkdir -p "$DH/bin/lib" "$DH/env" "$DH/logs" "$DH/state" "$DH/locks" "$T/dsbin"
( cd "$DIR" && scratch_install_closure bin/console-pages-deploy.sh "$DH" ) >/dev/null 2>&1 \
  || { echo "setup: could not install the deployer closure"; exit 1; }
cp "$DIR/bin/console-pages-deploy.sh" "$DH/bin/console-pages-deploy.sh"
printf 'CLOUDFLARE_API_TOKEN=%s\n' "$TOK" > "$DH/env/cloudflare.env"
mkdir -p "$CK/console-ui/schema.d" "$CK/worker/jobs"
echo '{"name":"console-ui"}' > "$CK/console-ui/package.json"
cp "$FRAG" "$CK/console-ui/schema.d/" 2>/dev/null || true
echo '{ "account_id": "acct9308" }' > "$CK/worker/jobs/wrangler.jsonc"
git -C "$CK" init -q -b main >/dev/null 2>&1; git -C "$CK" add -A
git -C "$CK" -c user.email=t@t -c user.name=t commit -q -m ui
cat > "$DH/bin/jobs-client.sh" <<EOF
#!/bin/bash
printf 'jobs-client %s\n' "\$*" >> "$T/dcalls.log"
case "\$1" in setting-get) exit 2 ;; setting-set) exit 0 ;; esac
exit 1
EOF
cat > "$DH/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf 'lane-alert %s\n' "\$*" >> "$T/dcalls.log"
EOF
# The stub records its argv and whether the snapshot's schema.d is there, then fails.
cat > "$DH/bin/console-db-schema.sh" <<EOF
#!/bin/bash
r=""; [ "\$1" = --root ] && r="\$2"
printf 'console-db-schema %s schema=%s\n' "\$*" "\$(ls "\$r/console-ui/schema.d" 2>/dev/null | head -1)" >> "$T/dcalls.log"
exit "\$(cat "$T/dschema.rc" 2>/dev/null || echo 0)"
EOF
cat > "$T/dsbin/npm" <<EOF
#!/bin/bash
case "\$1" in
  ci) exit 0 ;;
  test) exit 0 ;;
  run) mkdir -p dist; echo '<html>' > dist/index.html; exit 0 ;;
esac
exit 1
EOF
cat > "$T/dsbin/npx" <<EOF
#!/bin/bash
printf 'npx %s\n' "\$*" >> "$T/dcalls.log"
echo "Uploading Functions bundle"
EOF
printf '#!/bin/bash\nprintf 403\n' > "$T/dsbin/curl"
chmod +x "$DH/bin/jobs-client.sh" "$DH/bin/lane-alert.sh" "$DH/bin/console-db-schema.sh" "$T/dsbin/"*
drun() {
  rm -f "$T/dcalls.log"; touch "$T/dcalls.log"
  env -u CONSOLE_PAGES_DEPLOY -u CONSOLE_PAGES_RED_TRIES -u CONSOLE_PAGES_STALE_ALERT_H \
    -u CONSOLE_POSTMERGE_QA -u CLOUDFLARE_ACCOUNT_ID \
    HARNESS="$DH" HARNESS_CHECKOUT="$CK" HARNESS_ENV_DIR="$DH/env" PATH="$T/dsbin:$PATH" \
    CONSOLE_PAGES_PROBE_WAIT_S=0 bash "$DH/bin/console-pages-deploy.sh" >"$T/dout.log" 2>&1
  DRC=$?
}
line_of() { grep -nF -- "$1" "$T/dcalls.log" | head -1 | cut -d: -f1; }
echo 0 > "$T/dschema.rc"; drun
chk "D1 the deploy ran (rc $DRC)" '[ "$DRC" = 0 ] && grep -q "^npx " "$T/dcalls.log"'
chk "D1 console-db-schema.sh called once with --root <snapshot>" \
  '[ "$(grep -c "^console-db-schema --root $DH/state/console-snap\." "$T/dcalls.log")" = 1 ]'
chk "D1 the snapshot holds the schema.d fragment" 'grep "^console-db-schema" "$T/dcalls.log" | grep -qF "schema=202611261813-bh-9308-console-log-indexes.sql"'
S=$(line_of "setting-set deploy.console-ui.sha"); C=$(line_of "console-db-schema --root")
chk "D1 called after the stamp (stamp line ${S:-none}, call line ${C:-none})" '[ -n "$S" ] && [ -n "$C" ] && [ "$C" -gt "$S" ]'
echo 1 > "$T/dschema.rc"; drun
chk "D2 a failing console-db-schema.sh: the deploy rc stays 0 (got $DRC)" '[ "$DRC" = 0 ] && grep -q "^console-db-schema" "$T/dcalls.log"'
echo 2 > "$T/dschema.rc"; drun
chk "D2 rc 2 (refused): the deploy rc stays 0" '[ "$DRC" = 0 ]'

echo "console-db-schema.bh-9308: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
