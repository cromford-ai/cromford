#!/bin/bash
# tests/web-task-totp.bh-7596-test.sh — BH-7596 (slice C0): the RFC 6238 TOTP
# generator bin/lib/totp.mjs and the vault provider wt_totp_code in
# bin/lib/web-totp.sh. The provider is driven over real curl against the REAL
# jobs worker (tests/lib/web-vault-worker.bh-7595.mjs), with the secret stored
# through the operator CLI bin/web-vault.sh.
#
#   T1a-c all 18 RFC 6238 Appendix B vectors (SHA1, SHA256, SHA512, 8 digits)
#         through the CLI, key on stdin as base32, clock pinned by TOTP_NOW
#   T1d   next-window prints the seconds left in the current step
#   T2a   no flags: 6 digits, step 30, sha1
#   T2b   --digits 8 --step 60 follows the flags; --digits 10 is accepted
#   T2c   lower case, spaces, '-' and '=' padding give the same code
#   T2d   digits 5 or 11, step 0 or abc, algorithm md5, and a secret that
#         is not base32 (1, 8, 0, !, an inner =, empty): rc 2, stderr names
#         the parameter and never holds the secret
#   T3a   wt_totp_code with only totp_secret stored: the default code
#   T3b   totp_digits, totp_step and totp_algorithm stored: the code follows
#   T3c   no totp_secret: rc 1, `web-totp: no totp_secret`
#   T3d   a site off the allow-list: rc 1, the vault refusal, no code
#   T3e   a stored totp_digits=12: rc 2, `web-totp: bad totp_digits`
#   T3f   a stored blank totp_step, totp_step=0 and a blank
#         totp_algorithm: rc 2 (the store refuses a 0-byte value, so blank
#         is the nearest to empty an operator can store)
#   T3g   the worker unreachable: rc 1, no code
#   T3h   an optional field the worker refuses for a reason other than
#         no_entry (key_missing): rc 1, the refusal, no default code
#   T5a   the CLI run through a symlinked directory still prints the code
#   T5b   wt_totp_code sourced through a symlinked directory: the code
#   T5c   totp.mjs exits 0 with no code: wt_totp_code returns rc 1, empty stdout
#   T4    the secret and the codes are in no argv, no worker log and no
#         stderr; a code is only on stdout; neither file turns on xtrace
#
# Run from anywhere: tests/web-task-totp.bh-7596-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRV="$DIR/tests/lib/web-vault-worker.bh-7595.mjs"
TOTP="$DIR/bin/lib/totp.mjs"
WT_LIB="$DIR/bin/lib/web-totp.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

for f in "$TOTP" "$WT_LIB"; do
  [ -s "$f" ] && ok "source exists: ${f#"$DIR"/}" || bad "missing source ${f#"$DIR"/}"
done
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or curl missing"; [ "$FAIL" = 0 ]; exit; }
if [ "$FAIL" != 0 ]; then echo "web-task-totp: $PASS passed, $FAIL failed"; exit 1; fi

# gen <now> <secret> [flags...] — the CLI with the secret on stdin; sets RC, OUT, ERR.
gen() {
  local now="$1" sec="$2"; shift 2
  printf '%s' "$sec" | TOTP_NOW="$now" node "$TOTP" code "$@" > "$T/gout" 2> "$T/gerr"; RC=$?
  OUT=$(cat "$T/gout"); ERR=$(cat "$T/gerr")
}

# --- T1: RFC 6238 Appendix B --------------------------------------------------
K1=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ
K256=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZA====
K512=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNA=
# time sha1 sha256 sha512
VECTORS="59 94287082 46119246 90693936
1111111109 07081804 68084774 25091201
1111111111 14050471 67062674 99943326
1234567890 89005924 91819424 93441116
2000000000 69279037 90698825 38618901
20000000000 65353130 77737706 47863826"
for alg in sha1 sha256 sha512; do
  case $alg in sha1) key=$K1 col=2 tag=T1a ;; sha256) key=$K256 col=3 tag=T1b ;; sha512) key=$K512 col=4 tag=T1c ;; esac
  miss=""
  while read -r line; do
    t=$(cut -d' ' -f1 <<<"$line"); want=$(cut -d' ' -f"$col" <<<"$line")
    gen "$t" "$key" --digits 8 --algorithm "$alg"
    [ "$RC" = 0 ] && [ "$OUT" = "$want" ] || miss="$miss t=$t want=$want got='$OUT' rc=$RC err='$ERR';"
  done <<<"$VECTORS"
  [ -z "$miss" ] && ok "$tag the 6 RFC 6238 $alg vectors match" || bad "$tag $alg:$miss"
done
A=$(TOTP_NOW=59 node "$TOTP" next-window); B=$(TOTP_NOW=60 node "$TOTP" next-window); C=$(TOTP_NOW=59 node "$TOTP" next-window --step 60)
[ "$A" = 1 ] && [ "$B" = 30 ] && [ "$C" = 1 ] && ok "T1d next-window prints the seconds left (1, 30, 1)" || bad "T1d next-window: '$A' '$B' '$C'"

# --- T2: defaults, flags, normalization, refusals -----------------------------
gen 59 "$K1"
[ "$RC" = 0 ] && [ "$OUT" = 287082 ] && [ "$(wc -c < "$T/gout" | tr -d ' ')" = 6 ] && ok "T2a no flags: 6 digits, step 30, sha1, no newline" \
  || bad "T2a rc=$RC out='$OUT' err='$ERR'"
# RFC 4226 Appendix D: counter 0 gives the truncated value 1284755224.
gen 59 "$K1" --digits 8 --step 60
[ "$RC" = 0 ] && [ "$OUT" = 84755224 ] && ok "T2b --digits 8 --step 60 follows the flags" || bad "T2b rc=$RC out='$OUT' err='$ERR'"
gen 59 "$K1" --digits 10 --step 60
[ "$RC" = 0 ] && [ "$OUT" = 1284755224 ] && ok "T2b --digits 10 gives the whole 31-bit value" || bad "T2b10 rc=$RC out='$OUT' err='$ERR'"
gen 1111111111 "$K1" --step 3600
[ "$RC" = 0 ] && [[ $OUT =~ ^[0-9]{6}$ ]] && ok "T2b a long step has no cap (format: an integer >= 1)" || bad "T2b3600 rc=$RC out='$OUT' err='$ERR'"
gen 1111111111 "$(tr 'A-Z' 'a-z' <<<"${K1:0:8} ${K1:8:8}-${K1:16:16}")===="$'\n'
[ "$RC" = 0 ] && [ "$OUT" = 050471 ] && ok "T2c lower case, spaces, '-' and '=' padding give the same code" || bad "T2c rc=$RC out='$OUT' err='$ERR'"
FX=FIXTUREFIXTURE23
miss=""
for c in "digits 5:--digits 5" "digits 11:--digits 11" "digits x:--digits x" "step 0:--step 0" "step abc:--step abc" \
         "algorithm md5:--algorithm md5"; do
  name=${c%%:*}; flags=${c#*:}
  # shellcheck disable=SC2086 # the flag pair splits on purpose
  gen 59 "$FX" $flags
  want="totp: bad ${name%% *}"
  { [ "$RC" = 2 ] && [ -z "$OUT" ] && [ "$ERR" = "$want" ]; } || miss="$miss $name: rc=$RC out='$OUT' err='$ERR';"
done
for s in "FIXTURE!FIXTURE23" "FIXTURE1FIXTURE" "FIXTURE8FIXTURE" "FIXTURE0FIXTURE" "FIXT=UREFIXTURE23" "  ===" ""; do
  gen 59 "$s"
  { [ "$RC" = 2 ] && [ -z "$OUT" ] && [ "$ERR" = "totp: bad secret" ]; } || miss="$miss secret '$s': rc=$RC err='$ERR';"
done
gen 59 "$FX" "$FX"
{ [ "$RC" = 2 ] && [ "$ERR" = "totp: bad argument" ]; } || miss="$miss a stray argv word: rc=$RC err='$ERR';"
printf '%s' "$FX" | TOTP_NOW=soon node "$TOTP" code > "$T/gout" 2> "$T/gerr"; RC=$?
{ [ "$RC" = 2 ] && [ "$(cat "$T/gerr")" = "totp: bad TOTP_NOW" ]; } || miss="$miss TOTP_NOW=soon: rc=$RC;"
[ -z "$miss" ] && ok "T2d each bad input exits 2 with one line that names the parameter" || bad "T2d$miss"
grep -q FIXTURE "$T/gerr" && bad "T2d stderr holds the secret" || ok "T2d stderr never holds the secret"

# --- T3: the vault provider against the real worker ---------------------------
H="$T/h"
mkdir -p "$H/env" "$H/logs"
( cd "$DIR" && scratch_install_closure bin/web-vault.sh "$H" ) >/dev/null 2>&1 || bad "setup: could not install bin/web-vault.sh"
CLI="$H/bin/web-vault.sh"
export HARNESS="$H" HARNESS_ENV_DIR="$H/env"
unset JOBS_URL HARNESS_SECRET WEB_VAULT_ADMIN_TOKEN LANE_RUN_ID WEB_VAULT_MACHINE FLY_MACHINE_ID WEB_VAULT_RUN_TOKEN TOTP_NOW

# Shims that record their argv, one line per call, then run the real binary.
REAL_CURL=$(command -v curl); REAL_NODE=$(command -v node)
mkdir -p "$T/shim"
for b in curl node; do
  real=$REAL_CURL; [ "$b" = node ] && real=$REAL_NODE
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexec "%s" "$@"\n' "$T/$b-argv.log" "$real" > "$T/shim/$b"
  chmod +x "$T/shim/$b"; : > "$T/$b-argv.log"
done
export PATH="$T/shim:$PATH"

PID=""
: > "$T/srv.log"; : > "$T/srv.port"
"$REAL_NODE" "$SRV" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
PID=$!
trap '[ -n "$PID" ] && kill "$PID" 2>/dev/null' EXIT
for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$PID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/srv.port")
if [ -z "$PORT" ]; then
  wait "$PID"; src=$?
  [ "$src" = 3 ] && { echo "SKIP: node:sqlite unavailable in this runtime"; echo "web-task-totp: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]; exit; }
  echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1
fi
URL="http://127.0.0.1:$PORT"
sql() { "$REAL_CURL" -sS -X POST "$URL/__sql" --data-binary "$1" >/dev/null; }
get() { "$REAL_CURL" -sS -X POST "$URL/__get" --data-binary "$1"; }
export JOBS_URL="$URL" HARNESS_SECRET=fixture-harness-secret WEB_VAULT_ADMIN_TOKEN=fixture-admin-token-7595
# put <site> <field> <value> — the operator step, with the value on stdin and a trailing newline.
put() {
  printf '%s\n' "$3" | "$CLI" set p1 "$1" "$2" >/dev/null 2>"$T/put.err" || bad "setup: set $1 $2 failed: $(cat "$T/put.err")"
}
put a.example.com totp_secret "$FX"
put b.example.com totp_secret "$FX"
put b.example.com totp_digits 8
put b.example.com totp_step 60
put b.example.com totp_algorithm sha256
put d.example.com totp_secret "$FX"
put d.example.com totp_digits 12
put e.example.com totp_secret "$FX"
put e.example.com totp_step ' '
put g.example.com totp_secret "$FX"
put g.example.com totp_step 0
put f.example.com totp_secret "$FX"
put f.example.com totp_algorithm ' '
put h.example.com totp_secret "$FX"
put h.example.com totp_digits 8
put off.example.com totp_secret "$FX"
unset WEB_VAULT_ADMIN_TOKEN

sql "INSERT INTO settings (key,value,note,actor,updated_at) VALUES ('lane.web-task.p1.allowed_domains','a.example.com,b.example.com,c.example.com,d.example.com,e.example.com,f.example.com,g.example.com,h.example.com','','test','2026-10-22T00:00:00Z');
     UPDATE web_vault SET key_id=7 WHERE site='h.example.com' AND field='totp_digits';
     INSERT INTO lane_runs (lane, project, args_json, enqueued_at, claimed_at, claimed_by, lease_until, attempts, status)
       VALUES ('web-task','p1','[]', strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now'), 'm1',
               strftime('%Y-%m-%dT%H:%M:%SZ','now','+1 hour'), 1, 'claimed');"
RUN_ID=$(get "SELECT id FROM lane_runs WHERE lane='web-task'" | jq -r '.[0].id')
RUN_TOKEN=fixture-run-token-7596
sql "INSERT INTO web_vault_run_token (run_id, machine, token_hash, created_at)
       VALUES ($RUN_ID, 'm1', '$(printf '%s' "$RUN_TOKEN" | sha256sum | cut -d' ' -f1)', strftime('%Y-%m-%dT%H:%M:%SZ','now'));"
export LANE_RUN_ID="$RUN_ID" WEB_VAULT_MACHINE=m1 WEB_VAULT_RUN_TOKEN="$RUN_TOKEN"

: > "$T/wt.err.all"
# wt <site> — wt_totp_code in a subshell that sources the lib; sets RC, OUT, ERR.
wt() {
  ( . "$WT_LIB" || exit 9; TOTP_NOW=1111111111 wt_totp_code p1 "$1" ) > "$T/wout" 2> "$T/werr"; RC=$?
  OUT=$(cat "$T/wout"); ERR=$(cat "$T/werr"); cat "$T/wout" >> "$T/wt.out.all"; cat "$T/werr" >> "$T/wt.err.all"
}
# The expected codes come from an independent HMAC (python3 hmac) of the
# base32 decode of the fixture secret at t=1111111111.
wt a.example.com
cli_a=$(printf '%s' "$FX" | TOTP_NOW=1111111111 "$REAL_NODE" "$TOTP" code)
[ "$RC" = 0 ] && [ "$OUT" = 683604 ] && [ "$OUT" = "$cli_a" ] && [ "$(wc -c < "$T/wout" | tr -d ' ')" = 6 ] && [ -z "$ERR" ] \
  && ok "T3a only totp_secret stored: the 6-digit default code, no newline" || bad "T3a rc=$RC out='$OUT' cli='$cli_a' err='$ERR'"
wt b.example.com
[ "$RC" = 0 ] && [ "$OUT" = 33862936 ] && [ -z "$ERR" ] && ok "T3b stored digits 8, step 60, sha256: the code follows them" || bad "T3b rc=$RC out='$OUT' err='$ERR'"
wt c.example.com
[ "$RC" = 1 ] && [ -z "$OUT" ] && [ "$ERR" = "web-totp: no totp_secret" ] && ok "T3c no totp_secret: rc 1" || bad "T3c rc=$RC out='$OUT' err='$ERR'"
wt off.example.com
[ "$RC" = 1 ] && [ -z "$OUT" ] && [ "$ERR" = "web-vault: refused site_not_allowed" ] && ok "T3d a site off the allow-list: rc 1, no code" || bad "T3d rc=$RC out='$OUT' err='$ERR'"
wt d.example.com
[ "$RC" = 2 ] && [ -z "$OUT" ] && [ "$ERR" = "web-totp: bad totp_digits" ] && ok "T3e a stored totp_digits=12: rc 2" || bad "T3e rc=$RC out='$OUT' err='$ERR'"
wt e.example.com
[ "$RC" = 2 ] && [ -z "$OUT" ] && [ "$ERR" = "web-totp: bad totp_step" ] && ok "T3f a stored blank totp_step: rc 2" || bad "T3f rc=$RC out='$OUT' err='$ERR'"
wt g.example.com
[ "$RC" = 2 ] && [ -z "$OUT" ] && [ "$ERR" = "web-totp: bad totp_step" ] && ok "T3f a stored totp_step=0: rc 2" || bad "T3f0 rc=$RC out='$OUT' err='$ERR'"
wt f.example.com
[ "$RC" = 2 ] && [ -z "$OUT" ] && [ "$ERR" = "web-totp: bad totp_algorithm" ] && ok "T3f a blank totp_algorithm: rc 2" || bad "T3f2 rc=$RC out='$OUT' err='$ERR'"
JOBS_URL="http://127.0.0.1:1" wt a.example.com
[ "$RC" = 1 ] && [ -z "$OUT" ] && [ "$ERR" = "web-vault: worker unreachable" ] && ok "T3g the worker unreachable: rc 1, no code" || bad "T3g rc=$RC out='$OUT' err='$ERR'"
wt h.example.com
[ "$RC" = 1 ] && [ -z "$OUT" ] && [ "$ERR" = "web-vault: refused key_missing" ] && ok "T3h an optional field refused for key_missing: rc 1, no default code" || bad "T3h rc=$RC out='$OUT' err='$ERR'"
( . "$WT_LIB" || exit 9; wt_totp_code p1 ) > "$T/wout" 2> "$T/werr"; RC=$?
[ "$RC" = 2 ] && [ ! -s "$T/wout" ] && ok "T3 a missing site argument: rc 2" || bad "T3 usage rc=$RC"
AUD=$(get "SELECT COUNT(*) AS n FROM web_vault_audit WHERE action='read' AND site='a.example.com' AND field='totp_secret' AND outcome='ok'" | jq -r '.[0].n')
[ "$AUD" = 1 ] && ok "T3 the provider reads through the worker (one audit row for site a)" || bad "T3 audit rows for a: $AUD"

# --- T5: symlinked paths (/root/harness -> /data/harness) and an empty code ---
ln -s "$DIR/bin/lib" "$T/linked-lib"
out5=$(printf '%s' "$K1" | TOTP_NOW=59 "$REAL_NODE" "$T/linked-lib/totp.mjs" code); rc5=$?
[ "$rc5" = 0 ] && [ "$out5" = 287082 ] && ok "T5a the CLI through a symlinked directory prints the code" \
  || bad "T5a rc=$rc5 out='$out5'"
( . "$T/linked-lib/web-totp.sh" || exit 9; TOTP_NOW=1111111111 wt_totp_code p1 b.example.com ) > "$T/wout" 2> "$T/werr"; RC=$?
OUT=$(cat "$T/wout"); ERR=$(cat "$T/werr"); cat "$T/wout" >> "$T/wt.out.all"; cat "$T/werr" >> "$T/wt.err.all"
[ "$RC" = 0 ] && [ "$OUT" = 33862936 ] && [ -z "$ERR" ] && ok "T5b wt_totp_code sourced through a symlinked directory gives the code" \
  || bad "T5b rc=$RC out='$OUT' err='$ERR'"
mkdir -p "$T/stub-lib"; cp "$WT_LIB" "$T/stub-lib/web-totp.sh"
printf '%s\n' 'process.exitCode = 0;' > "$T/stub-lib/totp.mjs"
( wv_read() { [ "$3" = totp_secret ] && { printf '%s' "$FX"; return 0; }; echo "web-vault: refused no_entry" >&2; return 1; }
  . "$T/stub-lib/web-totp.sh" || exit 9; wt_totp_code p1 a.example.com ) > "$T/wout" 2> "$T/werr"; RC=$?
[ "$RC" = 1 ] && [ ! -s "$T/wout" ] && [ "$(cat "$T/werr")" = "web-totp: totp.mjs gave no code" ] \
  && ok "T5c totp.mjs rc 0 with no code: rc 1, empty stdout" || bad "T5c rc=$RC out='$(cat "$T/wout")' err='$(cat "$T/werr")'"

# --- T4: no secret and no code outside stdout ---------------------------------
LEAK=0
for f in "$T/curl-argv.log" "$T/node-argv.log" "$T/srv.log" "$T/wt.err.all"; do
  for s in "$FX" 683604 33862936 "$RUN_TOKEN"; do
    if grep -qF -- "$s" "$f"; then LEAK=1; bad "T4 $(basename "$f") holds '$s'"; fi
  done
done
grep -q totp.mjs "$T/node-argv.log" || { LEAK=1; bad "T4 the node shim recorded no totp.mjs call"; }
grep -q /api/web-vault/read "$T/curl-argv.log" "$T/srv.log" || { LEAK=1; bad "T4 no read request was recorded"; }
[ "$LEAK" = 0 ] && ok "T4 no secret or code in curl argv, node argv, the worker log or stderr"
grep -qF 683604 "$T/wt.out.all" && ok "T4 the code is on stdout" || bad "T4 the code is not on stdout"
if grep -Eq 'set -x|xtrace' "$TOTP" "$WT_LIB"; then bad "T4 a new file turns on xtrace"; else ok "T4 no xtrace in either new file"; fi

echo "web-task-totp: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
