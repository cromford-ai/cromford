#!/bin/bash
# tests/web-session-cli.bh-7597-test.sh — BH-7597 (slice C0): the saved-session
# client bin/lib/web-session.sh, driven over real curl against the REAL jobs
# worker (tests/lib/web-session-worker.bh-7597.mjs; the routes are
# worker/jobs/src/routes/web-session.js, registered by
# worker/jobs/test/route-table.d/bh-7597-web-session.txt, and their node suite
# is worker/jobs/test/web-session.bh-7597.test.js). No vendor is called.
#
#   W1  wsess_save a fixture storageState, wsess_load prints a path; cmp is 0
#   W2  stdout, stderr, curl's argv and the worker log never hold the session
#       value or the run token
#   W3  the loaded file is mode 600, its dir mode 700, under $TMPDIR
#   W4  a wrong run token: rc 1, `web-session: refused bad_token`, no file left
#   W5  an expired session: rc 3, `web-session: none (expired)`, no file left;
#       no session at all: rc 3, `web-session: none (no_entry)`
#   W6  no JOBS_URL, no WEB_VAULT_RUN_TOKEN, a missing file, an empty file or
#       a 262145-byte file: rc 2, no request
#   W7  a 200 with no value: rc 1, no file left
#   W8  wsess_forget removes the file and its dir; it refuses a path it did
#       not make and removes nothing
#   W9  a setting_get shim prints 1024: a 2000-byte file is rc 2 with no
#       request; a 1000-byte file is saved
#   W10 setting_get rc 1, rc 2, `abc`, `2000000`, or no setting_get: the cap
#       is 262144 (262145 bytes rc 2, 262144 bytes saved)
#   W11 worker row lane.web-task.session_max_bytes = 1024, no client shim: a
#       2000-byte file is sent and is rc 1 `web-session: 400 value must be
#       1..1024 bytes`
#   W12 the lib has no bare WSESS_MAX_BYTES=<digits>; the fallback names its row
#   F1  wsess_forget on the path wsess_load printed, and on a relative path
#       to one: rc 0, file and dir gone
#   F2  the same shape under another dir: rc 2, file stays
#   F3  a web-session.* symlink in TMPDIR to an outside dir, and a symlinked
#       file: rc 2, target stays
#   F4  a `..` path out of TMPDIR, /etc/hostname, a web-session-save.* dir,
#       one level too deep: rc 2, nothing removed
#   F5  TMPDIR is itself a symlink: load and forget under it is rc 0
#   F6  load under TMPDIR=A, forget under TMPDIR=B: rc 2, the file stays
#
# Run from anywhere: tests/web-session-cli.bh-7597-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRV="$DIR/tests/lib/web-session-worker.bh-7597.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or curl missing"; exit 0; }

for f in "$DIR/bin/lib/web-session.sh" "$DIR/worker/jobs/src/routes/web-session.js" \
         "$DIR/worker/jobs/test/route-table.d/bh-7597-web-session.txt" "$SRV"; do
  [ -s "$f" ] && ok "source exists: ${f#"$DIR"/}" || bad "missing source ${f#"$DIR"/}"
done

H="$T/h"
mkdir -p "$H" "$T/tmp"
( cd "$DIR" && scratch_install_closure bin/lib/web-session.sh "$H" ) >/dev/null 2>&1 || bad "setup: could not install bin/lib/web-session.sh"
[ -s "$H/bin/lib/web-vault.sh" ] && ok "the closure brings bin/lib/web-vault.sh" || bad "the closure lacks bin/lib/web-vault.sh"
unset JOBS_URL HARNESS_SECRET WEB_VAULT_ADMIN_TOKEN LANE_RUN_ID WEB_VAULT_MACHINE FLY_MACHINE_ID WEB_VAULT_RUN_TOKEN
export TMPDIR="$T/tmp"
SECRET=fixture-harness-secret
RUN_TOKEN=fixture-run-token-7597

# A curl shim that records its argv, one line per call, then runs the real curl.
REAL_CURL=$(command -v curl)
mkdir -p "$T/shim"
cat > "$T/shim/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/argv.log"
exec "$REAL_CURL" "\$@"
EOF
chmod +x "$T/shim/curl"
: > "$T/argv.log"
export PATH="$T/shim:$PATH"

PID=""
: > "$T/srv.log"; : > "$T/srv.port"
# The host composes its schema in a temp dir of its own, so $T/tmp holds only what the lib makes.
TMPDIR="$T" node "$SRV" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
PID=$!
trap '[ -n "$PID" ] && kill "$PID" 2>/dev/null' EXIT
for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$PID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/srv.port")
if [ -z "$PORT" ]; then
  wait "$PID"; src=$?
  [ "$src" = 3 ] && { echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; }
  echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1
fi
URL="http://127.0.0.1:$PORT"
sql() { "$REAL_CURL" -sS -X POST "$URL/__sql" --data-binary "$1" >/dev/null; }
get() { "$REAL_CURL" -sS -X POST "$URL/__get" --data-binary "$1"; }
reqs() { wc -l < "$T/srv.log" | tr -d ' '; }
# ws <fn> <args...> — runs a web-session function in a subshell that sources
# the installed lib; sets RC, OUT, ERR.
# WS_SHIM=<file> sources <file> after the lib (a setting_get stub); WS_CD=<dir>
# runs the function from <dir>.
ws() {
  ( . "$H/bin/lib/web-session.sh" || exit 9
    if [ -n "${WS_SHIM:-}" ]; then . "$WS_SHIM" || exit 9; fi
    if [ -n "${WS_CD:-}" ]; then cd "$WS_CD" || exit 9; fi
    "$@" ) > "$T/out" 2> "$T/err"; RC=$?
  OUT=$(cat "$T/out"); ERR=$(cat "$T/err")
  cat "$T/out" "$T/err" >> "$T/all-output"
}
: > "$T/all-output"
tmp_entries() { find "$T/tmp" -mindepth 1 | wc -l | tr -d ' '; }

sql "INSERT INTO settings (key,value,note,actor,updated_at) VALUES ('lane.web-task.p1.allowed_domains','app.example.com','','test','2026-10-22T00:00:00Z');
     INSERT INTO lane_runs (lane, project, args_json, enqueued_at, claimed_at, claimed_by, lease_until, attempts, status)
       VALUES ('web-task','p1','[]', strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now'), 'm1',
               strftime('%Y-%m-%dT%H:%M:%SZ','now','+1 hour'), 1, 'claimed');"
RUN_ID=$(get "SELECT id FROM lane_runs WHERE lane='web-task'" | jq -r '.[0].id')
sql "INSERT INTO web_vault_run_token (run_id, machine, token_hash, created_at)
       VALUES ($RUN_ID, 'm1', '$(printf '%s' "$RUN_TOKEN" | sha256sum | cut -d' ' -f1)', strftime('%Y-%m-%dT%H:%M:%SZ','now'));"
export JOBS_URL="$URL" HARNESS_SECRET="$SECRET" LANE_RUN_ID="$RUN_ID" WEB_VAULT_MACHINE=m1 WEB_VAULT_RUN_TOKEN="$RUN_TOKEN"

# The storageState fixture: about 30 KB, a quote, a backslash, unicode, a
# newline inside a value and a trailing newline, so a byte-exact round trip
# proves nothing is re-encoded.
FIX="$T/state.json"
{
  printf '{"cookies":[{"name":"sid","value":"fixture-session-w1-cookie","domain":"app.example.com","path":"/"}],'
  printf '"origins":[{"origin":"https://app.example.com","localStorage":[{"name":"k","value":"fixture-session-w1 \\"q\\" \\\\ ünï 🔑 %s"}]}]}\n' "$(head -c 30000 /dev/zero | tr '\0' 'x')"
} > "$FIX"
jq -e . "$FIX" >/dev/null || bad "setup: the fixture is not JSON"

# --- W1: save then load, byte-exact -------------------------------------------
ws wsess_save p1 app.example.com "$FIX"
[ "$RC" = 0 ] && [ "$OUT" = "web-session: saved p1 app.example.com" ] && [ -z "$ERR" ] \
  && ok "W1 wsess_save prints only the saved line" || bad "W1 save rc=$RC out='$OUT' err='$ERR'"
ROW=$(get "SELECT field, length(ciphertext) > 0 AS has_ct FROM web_vault WHERE project='p1'" | jq -c '.')
[ "$ROW" = '[{"field":"session_state","has_ct":1}]' ] && ok "W1 one session_state row in D1" || bad "W1 D1 rows: $ROW"
ws wsess_load p1 app.example.com
LOADED="$OUT"
if [ "$RC" = 0 ] && [ -f "$LOADED" ] && cmp -s "$FIX" "$LOADED" && [ -z "$ERR" ]; then
  ok "W1 wsess_load prints a path to a byte-identical file"
else bad "W1 load rc=$RC out='$OUT' err='$ERR'"; fi

# --- W3: modes and place -------------------------------------------------------
if [ -f "$LOADED" ]; then
  FM=$(stat -c %a "$LOADED"); DM=$(stat -c %a "$(dirname "$LOADED")")
  [ "$FM" = 600 ] && [ "$DM" = 700 ] && ok "W3 file mode 600, dir mode 700" || bad "W3 file $FM dir $DM"
  [[ $LOADED == "$T/tmp/"* ]] && ok "W3 the file is under \$TMPDIR" || bad "W3 path $LOADED"
else bad "W3 no loaded file"; fi

# --- W8: forget ------------------------------------------------------------------
echo fixture-not-ours > "$T/other.txt"
ws wsess_forget "$T/other.txt"
[ "$RC" = 2 ] && [ -f "$T/other.txt" ] && ok "W8 forget refuses a file it did not make" || bad "W8 rc=$RC err='$ERR'"
mkdir -p "$T/tmp/web-session.fake"; echo x > "$T/tmp/web-session.fake/other.json"
ws wsess_forget "$T/tmp/web-session.fake/other.json"
[ "$RC" = 2 ] && [ -f "$T/tmp/web-session.fake/other.json" ] && ok "W8 forget refuses another file name in a look-alike dir" || bad "W8b rc=$RC"
rm -rf "$T/tmp/web-session.fake"
ws wsess_forget "$LOADED"
[ "$RC" = 0 ] && [ ! -e "$LOADED" ] && [ ! -e "$(dirname "$LOADED")" ] && ok "W8 forget removes the file and its dir" || bad "W8c rc=$RC err='$ERR'"
[ "$(tmp_entries)" = 0 ] && ok "W8 \$TMPDIR is empty after forget" || bad "W8 \$TMPDIR holds $(tmp_entries) entries"

# --- W4: wrong run token ---------------------------------------------------------
WEB_VAULT_RUN_TOKEN=fixture-run-token-guess ws wsess_load p1 app.example.com
[ "$RC" = 1 ] && [ "$ERR" = "web-session: refused bad_token" ] && [ -z "$OUT" ] && [ "$(tmp_entries)" = 0 ] \
  && ok "W4 a wrong run token: rc 1, refused bad_token, no file" || bad "W4 rc=$RC out='$OUT' err='$ERR' tmp=$(tmp_entries)"
WEB_VAULT_RUN_TOKEN=fixture-run-token-guess ws wsess_save p1 app.example.com "$FIX"
[ "$RC" = 1 ] && [ "$ERR" = "web-session: refused bad_token" ] && [ -z "$OUT" ] \
  && ok "W4 a save with a wrong run token: rc 1, no saved line" || bad "W4b rc=$RC out='$OUT' err='$ERR'"

# --- W5: expired and none ----------------------------------------------------------
sql "UPDATE web_vault SET updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now','-15 days') WHERE field='session_state'"
ws wsess_load p1 app.example.com
[ "$RC" = 3 ] && [ "$ERR" = "web-session: none (expired)" ] && [ -z "$OUT" ] && [ "$(tmp_entries)" = 0 ] \
  && ok "W5 an expired session: rc 3, none (expired), no file" || bad "W5 rc=$RC out='$OUT' err='$ERR' tmp=$(tmp_entries)"
sql "DELETE FROM web_vault"
ws wsess_load p1 app.example.com
[ "$RC" = 3 ] && [ "$ERR" = "web-session: none (no_entry)" ] && [ "$(tmp_entries)" = 0 ] \
  && ok "W5 no session: rc 3, none (no_entry)" || bad "W5b rc=$RC err='$ERR'"

# --- W6: not configured / bad file: no request --------------------------------------
N=$(reqs)
JOBS_URL='' ws wsess_load p1 app.example.com
[ "$RC" = 2 ] && [ "$(reqs)" = "$N" ] && ok "W6 no JOBS_URL: rc 2, no request" || bad "W6a rc=$RC err='$ERR'"
WEB_VAULT_RUN_TOKEN='' ws wsess_save p1 app.example.com "$FIX"
[ "$RC" = 2 ] && [ "$(reqs)" = "$N" ] && [[ $ERR == *WEB_VAULT_RUN_TOKEN* ]] && ok "W6 no run token: rc 2, no request" || bad "W6b rc=$RC err='$ERR'"
ws wsess_save p1 app.example.com "$T/no-such-file.json"
[ "$RC" = 2 ] && [ "$(reqs)" = "$N" ] && ok "W6 a missing file: rc 2, no request" || bad "W6c rc=$RC err='$ERR'"
: > "$T/empty.json"
ws wsess_save p1 app.example.com "$T/empty.json"
[ "$RC" = 2 ] && [ "$(reqs)" = "$N" ] && ok "W6 an empty file: rc 2, no request" || bad "W6d rc=$RC err='$ERR'"
head -c 262145 /dev/zero | tr '\0' 'x' > "$T/big.json"
ws wsess_save p1 app.example.com "$T/big.json"
[ "$RC" = 2 ] && [ "$(reqs)" = "$N" ] && [[ $ERR == *262144* ]] && ok "W6 a 262145-byte file: rc 2, no request" || bad "W6e rc=$RC err='$ERR'"
ws wsess_load p1
[ "$RC" = 2 ] && [ "$(reqs)" = "$N" ] && ok "W6 a missing argument: rc 2, no request" || bad "W6f rc=$RC err='$ERR'"

# --- W7: a 200 with no value is not a session ----------------------------------------
ws wsess_save p1 app.example.com "$FIX"
[ "$RC" = 0 ] || bad "W7 setup save rc=$RC err='$ERR'"
"$REAL_CURL" -sS -X POST "$URL/__novalue" >/dev/null
ws wsess_load p1 app.example.com
[ "$RC" = 1 ] && [ -z "$OUT" ] && [ "$(tmp_entries)" = 0 ] && [[ $ERR == "web-session: "* ]] \
  && ok "W7 a 200 with no value: rc 1, no file" || bad "W7 rc=$RC out='$OUT' err='$ERR' tmp=$(tmp_entries)"

# --- W9-W11: the size cap is the settings row lane.web-task.session_max_bytes ---------
for v in 1024 rc1 rc2 abc 2000000; do
  case "$v" in
    rc1) echo 'setting_get() { return 1; }' ;;
    rc2) echo 'setting_get() { return 2; }' ;;
    *)   echo "setting_get() { [ \"\$1\" = lane.web-task.session_max_bytes ] || return 2; printf '%s' '$v'; }" ;;
  esac > "$T/shim-$v.sh"
done
head -c 2000 /dev/zero | tr '\0' 'x' > "$T/2000.json"
head -c 1000 /dev/zero | tr '\0' 'x' > "$T/1000.json"
head -c 262144 /dev/zero | tr '\0' 'x' > "$T/262144.json"
N=$(reqs)
WS_SHIM="$T/shim-1024.sh" ws wsess_save p1 app.example.com "$T/2000.json"
[ "$RC" = 2 ] && [ "$(reqs)" = "$N" ] && [[ $ERR == *"1..1024 bytes"* ]] \
  && ok "W9 setting_get 1024: a 2000-byte file is rc 2, no request" || bad "W9 rc=$RC err='$ERR'"
WS_SHIM="$T/shim-1024.sh" ws wsess_save p1 app.example.com "$T/1000.json"
[ "$RC" = 0 ] && [ "$(reqs)" = "$((N + 1))" ] && ok "W9 setting_get 1024: a 1000-byte file is saved" || bad "W9b rc=$RC err='$ERR'"
for v in rc1 rc2 abc 2000000 none; do
  shim="$T/shim-$v.sh"; [ "$v" = none ] && shim=""
  N=$(reqs)
  WS_SHIM="$shim" ws wsess_save p1 app.example.com "$T/big.json"
  [ "$RC" = 2 ] && [ "$(reqs)" = "$N" ] && [[ $ERR == *"1..262144 bytes"* ]] \
    && ok "W10 setting_get $v: a 262145-byte file is rc 2, no request" || bad "W10 $v big rc=$RC err='$ERR'"
  WS_SHIM="$shim" ws wsess_save p1 app.example.com "$T/262144.json"
  [ "$RC" = 0 ] && [ "$(reqs)" = "$((N + 1))" ] && ok "W10 setting_get $v: a 262144-byte file is sent and saved" || bad "W10 $v max rc=$RC err='$ERR'"
done
sql "INSERT INTO settings (key,value,note,actor,updated_at) VALUES ('lane.web-task.session_max_bytes','1024','','test','2026-10-22T00:00:00Z')
       ON CONFLICT(key) DO UPDATE SET value=excluded.value"
N=$(reqs)
ws wsess_save p1 app.example.com "$T/2000.json"
[ "$RC" = 1 ] && [ "$(reqs)" = "$((N + 1))" ] && [ "$ERR" = "web-session: 400 value must be 1..1024 bytes" ] && [ -z "$OUT" ] \
  && ok "W11 worker row 1024: a 2000-byte file is sent and refused 400" || bad "W11 rc=$RC out='$OUT' err='$ERR'"
sql "UPDATE settings SET value='262144' WHERE key='lane.web-task.session_max_bytes'"
LIT=$(grep -nE 'WSESS_MAX_BYTES *= *[0-9]' "$DIR/bin/lib/web-session.sh")
FB=$(grep -nE '^ *echo 262144 ' "$DIR/bin/lib/web-session.sh")
[ -z "$LIT" ] && [ "$(printf '%s\n' "$FB" | grep -c .)" = 1 ] && [[ $FB == *"lane.web-task.session_max_bytes"* ]] \
  && ok "W12 no bare literal cap; the one fallback names its row" || bad "W12 lit='$LIT' fallback='$FB'"

# --- F1-F6: wsess_forget removes only a session file directly in the physical TMPDIR ---
ws wsess_save p1 app.example.com "$FIX"
[ "$RC" = 0 ] || bad "F setup save rc=$RC err='$ERR'"
ws wsess_load p1 app.example.com; F1P="$OUT"
ws wsess_forget "$F1P"
[ "$RC" = 0 ] && [ ! -e "$F1P" ] && [ ! -e "$(dirname "$F1P")" ] && ok "F1 forget on the loaded path: rc 0, file and dir gone" || bad "F1 rc=$RC err='$ERR'"
ws wsess_load p1 app.example.com; F1P="$OUT"
WS_CD="$T/tmp" ws wsess_forget "$(basename "$(dirname "$F1P")")/storage-state.json"
[ "$RC" = 0 ] && [ ! -e "$F1P" ] && [ ! -e "$(dirname "$F1P")" ] && ok "F1 forget on a relative path: rc 0, gone" || bad "F1b rc=$RC err='$ERR'"
# keep: <path> — rc 2 and the file still there.
keep() { [ "$RC" = 2 ] && [ -e "$1" ] && [[ $ERR == "web-session: forget: "* ]]; }
mkdir -p "$T/elsewhere/web-session.abc123"; echo fixture-keep > "$T/elsewhere/web-session.abc123/storage-state.json"
ws wsess_forget "$T/elsewhere/web-session.abc123/storage-state.json"
keep "$T/elsewhere/web-session.abc123/storage-state.json" && ok "F2 the same shape outside TMPDIR: rc 2, file stays" || bad "F2 rc=$RC err='$ERR'"
mkdir -p "$T/outside"; echo fixture-keep > "$T/outside/storage-state.json"
ln -s "$T/outside" "$T/tmp/web-session.lnk123"
ws wsess_forget "$T/tmp/web-session.lnk123/storage-state.json"
keep "$T/outside/storage-state.json" && ok "F3 a symlinked web-session dir in TMPDIR: rc 2, target stays" || bad "F3 rc=$RC err='$ERR'"
rm -f "$T/tmp/web-session.lnk123"
mkdir -p "$T/tmp/web-session.fil123"; ln -s "$T/outside/storage-state.json" "$T/tmp/web-session.fil123/storage-state.json"
ws wsess_forget "$T/tmp/web-session.fil123/storage-state.json"
keep "$T/outside/storage-state.json" && [ -L "$T/tmp/web-session.fil123/storage-state.json" ] && ok "F3 a symlinked file: rc 2, target and link stay" || bad "F3b rc=$RC err='$ERR'"
rm -rf "$T/tmp/web-session.fil123"
ws wsess_forget "$T/tmp/../elsewhere/web-session.abc123/storage-state.json"
keep "$T/elsewhere/web-session.abc123/storage-state.json" && ok "F4 a .. path out of TMPDIR: rc 2, file stays" || bad "F4a rc=$RC err='$ERR'"
if [ -f /etc/hostname ]; then
  ws wsess_forget /etc/hostname
  keep /etc/hostname && ok "F4 /etc/hostname: rc 2" || bad "F4b rc=$RC err='$ERR'"
fi
mkdir -p "$T/tmp/web-session-save.abc123"; echo fixture-keep > "$T/tmp/web-session-save.abc123/storage-state.json"
ws wsess_forget "$T/tmp/web-session-save.abc123/storage-state.json"
keep "$T/tmp/web-session-save.abc123/storage-state.json" && ok "F4 a web-session-save.* dir: rc 2, file stays" || bad "F4c rc=$RC err='$ERR'"
rm -rf "$T/tmp/web-session-save.abc123"
mkdir -p "$T/tmp/web-session.abc123/sub"; echo fixture-keep > "$T/tmp/web-session.abc123/sub/storage-state.json"
ws wsess_forget "$T/tmp/web-session.abc123/sub/storage-state.json"
keep "$T/tmp/web-session.abc123/sub/storage-state.json" && ok "F4 one level too deep: rc 2, file stays" || bad "F4d rc=$RC err='$ERR'"
rm -rf "$T/tmp/web-session.abc123"
ln -s "$T/tmp" "$T/tmplink"
TMPDIR="$T/tmplink" ws wsess_load p1 app.example.com; F5P="$OUT"
[[ $F5P == "$T/tmplink/"* ]] || bad "F5 setup load rc=$RC out='$OUT' err='$ERR'"
TMPDIR="$T/tmplink" ws wsess_forget "$F5P"
[ "$RC" = 0 ] && [ ! -e "$F5P" ] && [ "$(tmp_entries)" = 0 ] && ok "F5 a symlinked TMPDIR: load and forget is rc 0" || bad "F5 rc=$RC err='$ERR' tmp=$(tmp_entries)"
mkdir -p "$T/tmpB"
ws wsess_load p1 app.example.com; F6P="$OUT"
TMPDIR="$T/tmpB" ws wsess_forget "$F6P"
keep "$F6P" && ok "F6 load under TMPDIR=A, forget under TMPDIR=B: rc 2, file stays" || bad "F6 rc=$RC err='$ERR'"
ws wsess_forget "$F6P"
[ "$RC" = 0 ] && [ "$(tmp_entries)" = 0 ] && ok "F6 the same path under TMPDIR=A is removed" || bad "F6b rc=$RC tmp=$(tmp_entries)"

# --- K1: the HTTP timeouts are knobs (catalog/lanes.d/_lib.web-session.json) -------------
WEB_SESSION_TIMEOUT_S=7 WEB_SESSION_CONNECT_TIMEOUT_S=3 ws wsess_load p1 knob-k1.example.com
tail -1 "$T/argv.log" | grep -q -- '^-sS -m 7 --connect-timeout 3 ' && ok "K1 the env knobs reach curl" \
  || bad "K1 argv: $(tail -1 "$T/argv.log")"
[ -n "$OUT" ] && [ -f "$OUT" ] && rm -rf -- "$(dirname "$OUT")"
( unset WEB_SESSION_TIMEOUT_S WEB_SESSION_CONNECT_TIMEOUT_S; ws wsess_load p1 knob-k1.example.com; [ -n "$OUT" ] && [ -f "$OUT" ] && rm -rf -- "$(dirname "$OUT")"; exit 0 )
tail -1 "$T/argv.log" | grep -q -- '^-sS -m 15 --connect-timeout 5 ' && ok "K1 unset knobs read the fallbacks 15 and 5" \
  || bad "K1 fallback argv: $(tail -1 "$T/argv.log")"
grep -q 'connect-timeout 5\b' "$DIR/bin/lib/web-session.sh" && bad "K1 a literal connect timeout is back in the lib" || ok "K1 no literal connect timeout"

# --- W2: no value and no token anywhere -------------------------------------------------
LEAK=0
for f in "$T/all-output" "$T/argv.log" "$T/srv.log" "$T/srv.err"; do
  for s in fixture-session "$RUN_TOKEN" "$SECRET"; do
    if grep -qF -- "$s" "$f"; then LEAK=1; bad "W2 $(basename "$f") holds '$s'"; fi
  done
done
[ -s "$T/argv.log" ] || { LEAK=1; bad "W2 the curl shim recorded no call"; }
[ "$LEAK" = 0 ] && ok "W2 no session value or token in stdout, stderr, curl argv or the worker log"
if grep -Eq '(^|[^_])set -x|set -o xtrace' "$DIR/bin/lib/web-session.sh"; then bad "W2 the lib turns on xtrace"; else ok "W2 no xtrace in the lib"; fi

echo "web-session-cli: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
