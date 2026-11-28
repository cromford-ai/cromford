#!/bin/bash
# tests/jobs-req-auth-argv.bh-9946-test.sh — the jobs worker bearer token never
# rides on curl's argv (BH-9946). `ps -eo args` on a pool machine showed
# HARNESS_SECRET for every _jobs_req call, because bin/lib/jobs/req.sh put
# `authorization: Bearer $HARNESS_SECRET` on argv unless JOBS_AUTH_VIA_FILE was
# set. Since BH-9946 the header rides on curl's fd 3 (`-H @/dev/fd/3` plus a
# bash here-string), so nothing is on argv and nothing is written to disk.
#
# The REAL client (bin/jobs-client.sh, its closure installed in a scratch tree)
# sends through the REAL curl, behind an argv-recording wrapper, to a loopback
# python stub that records the authorization header it received.
#   A1 _jobs_req GET: rc 0, payload, token not on argv, argv holds
#      @/dev/fd/3, stub got the bearer
#   A2 _jobs_req POST with a small body: the same, stub got the body
#   A3 _jobs_req POST with a body over JOBS_BODY_ARGV_MAX: the same
#   A4 _jobs_req_file POST: the same
#   A5 the fd content is exactly the header line, and its mode is 600
#   A6 the TMPDIR listing is the same before and after each call
#   A7 a transport failure (curl rc 7): rc 1, curl_rc=7, TMPDIR unchanged
#   A8 TMPDIR names a regular file: on bash >= 5.1 the request still goes
#      out (a pipe, no temp file); the token is never on argv
#   A9 JOBS_AUTH_VIA_FILE set or unset gives the same argv (no token)
#   A10 (the r1 regression) a `set -u` caller captures _jobs_req stderr in
#      `$( )`: no "unbound variable", rc 0
#   A11 _jobs_curl at top level and in `$( )` keeps the caller's EXIT trap
#   A12 SIGTERM to the subshell that runs curl: rc 1, TMPDIR unchanged
#   A13 (pins the BH-7432 fork budget) a GET, a small POST and a
#      _jobs_req_file POST exec no mktemp, rm, cat, printf or stat
#   A14 the caller's own fd 3 still points at its file after _jobs_req,
#      and that file never holds the token
# JOBS_REQ_UNDER_TEST=<file>, when set, is copied over the installed
# bin/lib/jobs/req.sh (the reproduction runs this suite on main's copy).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/jobs-req-auth-argv.bh-9946-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
HERE=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing — skipping"; exit 0; }
REAL_CURL=$(command -v curl) || { echo "curl missing — skipping"; exit 0; }

scratch_install_closure bin/jobs-client.sh "$T" >/dev/null || { echo "FAIL: closure install"; exit 1; }
if [ -n "${JOBS_REQ_UNDER_TEST:-}" ]; then
  # scratch-closure-allow: the reproduction swaps in another copy of req.sh (main's) over the installed closure
  cp "$JOBS_REQ_UNDER_TEST" "$T/bin/lib/jobs/req.sh" || { echo "FAIL: cannot copy $JOBS_REQ_UNDER_TEST"; exit 1; }
fi
# Unique per run (the scratch dir name), so parallel runs share nothing.
SECRET="fixture-sek-9946-$(basename "$T" | tr -cd 'A-Za-z0-9')"
FB="$T/fakebin"; mkdir -p "$FB" "$T/srv" "$T/home" "$T/tmp" "$T/env" "$T/logs" "$T/flags"

# The stub: logs "<METHOD> <path>", the authorization header and the body, one
# record per request, and answers {"ok":true} 200.
cat > "$T/srv/stub.py" <<'PY'
import http.server, os, sys
root = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _do(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode() if n else ""
        with open(os.path.join(root, "reqs.log"), "a") as f:
            f.write("%s %s\n" % (self.command, self.path))
            f.write("auth=%s\n" % (self.headers.get("authorization") or ""))
            f.write("body=%s\n" % body)
        b = b'{"ok":true}'
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    do_GET = _do
    do_POST = _do
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(root, "port"), "w").write(str(s.server_address[1]))
s.serve_forever()
PY
( trap - EXIT; exec python3 -I "$T/srv/stub.py" "$T/srv" ) & SRV=$!
__ja_exit() { local rc=$?
              [ "${__scratch_owner_pid:-}" = "${BASHPID:-$$}" ] || return 0
              kill "$SRV" 2>/dev/null; scratch_cleanup; exit "$rc"; }
trap __ja_exit EXIT
i=0; while [ ! -s "$T/srv/port" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
[ -s "$T/srv/port" ] || { echo "FAIL: the stub did not start"; exit 1; }
URL="http://127.0.0.1:$(cat "$T/srv/port")"

# The curl wrapper: one argv line per call; for an `@/dev/fd/<n>` argument it
# records the mode of that fd (CURL_MODE) and its content (CURL_FD), read with
# bash builtins and the absolute stat path (A13 shims the PATH), then hands the
# same content to the real curl on the same fd. CURL_FAIL=<n> exits <n>
# without calling it. CURL_PPID=<file> records the pid of the shell that runs
# curl, and CURL_SLEEP=<s> waits that long first (A12 signals that shell).
REAL_STAT=$(command -v stat) || { echo "stat missing — skipping"; exit 0; }
REAL_SLEEP=$(command -v sleep)
cat > "$FB/curl" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "\$CURL_ARGV"
fdn=""; hdr=""
for a in "\$@"; do
  case "\$a" in @/dev/fd/[0-9]*) fdn=\${a#@/dev/fd/} ;; esac
done
if [ -n "\$fdn" ]; then
  "$REAL_STAT" -L -c %a "/dev/fd/\$fdn" >> "\$CURL_MODE" 2>/dev/null
  hdr=\$(< "/dev/fd/\$fdn")
  printf '%s\n' "\$hdr" >> "\$CURL_FD"
fi
[ -z "\${CURL_PPID:-}" ] || echo "\$PPID" > "\$CURL_PPID"
[ -z "\${CURL_SLEEP:-}" ] || "$REAL_SLEEP" "\$CURL_SLEEP"
[ -z "\${CURL_FAIL:-}" ] || exit "\$CURL_FAIL"
if [ -n "\$fdn" ]; then
  eval 'exec "$REAL_CURL" "\$@" '"\$fdn"'<<<"\$hdr"'
fi
exec "$REAL_CURL" "\$@"
SH
chmod +x "$FB/curl"

reset() { : > "$T/argv"; : > "$T/mode"; : > "$T/fd"; : > "$T/srv/reqs.log"; : > "$T/status"; }
# tmp_ls: the TMPDIR listing (A6: a call must leave it unchanged).
tmp_ls() { ls -A "$T/tmp" 2>/dev/null; }
# call <env...> -- <shell snippet>: runs the snippet with the client sourced;
# prints its stdout then "|rc=N".
call() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  env -i HOME="$T/home" PATH="${CALL_PATH_PRE:-}$FB:$PATH" HARNESS="$T" HARNESS_DEPLOYMENT_FILE="$HERE/bin/lib/deployment.sh" \
    HARNESS_SECRET="$SECRET" JOBS_URL="$URL" TMPDIR="$T/tmp" JOBS_RETRIES=0 JOBS_RETRY_SLEEP=0 \
    JOBS_STATUS_FILE="$T/status" CURL_ARGV="$T/argv" CURL_MODE="$T/mode" CURL_FD="$T/fd" "${envs[@]}" \
    bash -c ". \"$T/bin/jobs-client.sh\" >/dev/null 2>&1; $1; echo \"|rc=\$?\"" 2>/dev/null
}
# check_sent <case> <method path> [body]: argv clean, stub got the bearer.
check_sent() {
  local c=$1 req=$2 body=${3-}
  if grep -qF "$SECRET" "$T/argv"; then bad "$c argv holds the token: $(grep -F "$SECRET" "$T/argv" | sed "s/$SECRET/<SECRET>/g")"; else ok; fi
  [ -s "$T/argv" ] && ok || bad "$c curl was never called"
  grep -qF -- '-H @/dev/fd/3' "$T/argv" && ok || bad "$c argv has no '-H @/dev/fd/3': $(sed "s/$SECRET/<SECRET>/g" "$T/argv")"
  grep -qxF "$req" "$T/srv/reqs.log" && ok || bad "$c stub did not see '$req': $(cat "$T/srv/reqs.log")"
  grep -qxF "auth=Bearer $SECRET" "$T/srv/reqs.log" && ok || bad "$c stub did not get 'authorization: Bearer <secret>'"
  [ "$(grep -c '^auth=' "$T/srv/reqs.log")" -eq 1 ] && ok || bad "$c want exactly 1 request at the stub"
  if [ -n "$body" ]; then grep -qxF "body=$body" "$T/srv/reqs.log" && ok || bad "$c stub did not get the body"; fi
  # A5: the fd held exactly the header line, owner-only.
  [ "$(cat "$T/fd")" = "authorization: Bearer $SECRET" ] && ok || bad "$c A5 fd content is not exactly the header line"
  [ "$(sort -u "$T/mode")" = 600 ] && ok || bad "$c A5 header fd mode while curl ran: [$(tr '\n' ' ' < "$T/mode")] (want 600)"
}
# check_tmp <case> <listing before>: A6, nothing written or left in TMPDIR.
check_tmp() { [ "$(tmp_ls)" = "$2" ] && ok || bad "$1 A6 TMPDIR changed: before [$2] after [$(tmp_ls | tr '\n' ' ')]"; }
mkdir -p "$T/tmp"; : > "$T/tmp/keep.marker"

# A1 — the ticket's evidence call: a flag read.
reset; t0=$(tmp_ls); out=$(call -- '_jobs_req GET /api/flags/x')
[ "$out" = '{"ok":true}|rc=0' ] && ok || bad "A1 _jobs_req GET: got '$out'"
check_sent A1 "GET /api/flags/x"; check_tmp A1 "$t0"

# A2 — a small POST body.
reset; t0=$(tmp_ls); out=$(call -- "_jobs_req POST /api/x '{\"a\":1}'")
[ "$out" = '{"ok":true}|rc=0' ] && ok || bad "A2 _jobs_req POST: got '$out'"
check_sent A2 "POST /api/x" '{"a":1}'; check_tmp A2 "$t0"

# A3 — a body over JOBS_BODY_ARGV_MAX rides in a file; the header on fd 3.
reset; t0=$(tmp_ls); out=$(call JOBS_BODY_ARGV_MAX=16 -- "_jobs_req POST /api/x '{\"big\":\"0123456789abcdef0123\"}'")
[ "$out" = '{"ok":true}|rc=0' ] && ok || bad "A3 _jobs_req POST big: got '$out'"
check_sent A3 "POST /api/x" '{"big":"0123456789abcdef0123"}'; check_tmp A3 "$t0"
grep -q -- '--data-binary @' "$T/argv" && ok || bad "A3 the large body did not ride in a file: $(sed "s/$SECRET/<SECRET>/g" "$T/argv")"

# A4 — _jobs_req_file.
printf '{"f":2}' > "$T/body.json"
reset; t0=$(tmp_ls); out=$(call -- "_jobs_req_file POST /api/x \"$T/body.json\"")
[ "$out" = '{"ok":true}|rc=0' ] && ok || bad "A4 _jobs_req_file: got '$out'"
check_sent A4 "POST /api/x" '{"f":2}'; check_tmp A4 "$t0"

# A7 — a transport failure: rc 1, curl_rc=7, TMPDIR unchanged.
reset; t0=$(tmp_ls); out=$(call CURL_FAIL=7 -- '_jobs_req GET /api/flags/x')
[ "$out" = '|rc=1' ] && ok || bad "A7 transport failure: got '$out' (want |rc=1)"
[ "$(cat "$T/status")" = curl_rc=7 ] && ok || bad "A7 JOBS_STATUS_FILE [$(cat "$T/status")] (want curl_rc=7)"
grep -qF "$SECRET" "$T/argv" && bad "A7 argv holds the token" || ok
check_tmp A7 "$t0"
reset; out=$(call CURL_FAIL=7 -- "_jobs_req_file POST /api/x \"$T/body.json\"")
[ "$out" = '|rc=1' ] && ok || bad "A7 _jobs_req_file transport failure: got '$out' (want |rc=1)"
check_tmp A7-file "$t0"

# A8 — TMPDIR names a regular file, so no temp file can exist. On bash >= 5.1
# a small here-string is a pipe: the request still goes out, header off argv.
# On an older bash the here-string needs a temp file, so the request must fail
# (rc 1) and never fall back to argv.
: > "$T/notadir"
bash_new=$(bash -c '[ "${BASH_VERSINFO[0]}" -gt 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 5 ] && [ "${BASH_VERSINFO[1]}" -ge 1 ]; } && echo 1')
reset; out=$(call TMPDIR="$T/notadir" -- '_jobs_req GET /api/flags/x')
if [ "$bash_new" = 1 ]; then
  [ "$out" = '{"ok":true}|rc=0' ] && ok || bad "A8 TMPDIR a file: got '$out' (want the payload, rc 0)"
  check_sent A8 "GET /api/flags/x"
  reset; out=$(call TMPDIR="$T/notadir" -- "_jobs_req_file POST /api/x \"$T/body.json\"")
  [ "$out" = '{"ok":true}|rc=0' ] && ok || bad "A8 _jobs_req_file TMPDIR a file: got '$out'"
  check_sent A8-file "POST /api/x" '{"f":2}'
else
  [ "$out" = '|rc=1' ] && ok || bad "A8 old bash, TMPDIR a file: got '$out' (want |rc=1)"
  grep -qF "$SECRET" "$T/argv" && bad "A8 argv holds the token" || ok
fi

# A9 — the BH-7188 opt-in no longer changes anything.
reset; out=$(call JOBS_AUTH_VIA_FILE=1 -- '_jobs_req GET /api/flags/x')
[ "$out" = '{"ok":true}|rc=0' ] && ok || bad "A9 with JOBS_AUTH_VIA_FILE=1: got '$out'"
check_sent A9-set "GET /api/flags/x"
shape_set=$(cat "$T/argv")
reset; out=$(call -- '_jobs_req GET /api/flags/x')
shape_unset=$(cat "$T/argv")
[ "$shape_set" = "$shape_unset" ] && ok || bad "A9 argv differs with and without JOBS_AUTH_VIA_FILE"

# A10 — the r1 regression: an EXIT trap that named a function local printed
# "hf: unbound variable" on stderr after the `$( )` subshell returned. A
# `set -u` caller that captures stderr must see the payload and nothing else.
reset; out=$(call -- 'set -u; x=$(_jobs_req GET /api/flags/x 2>&1); r=$?; printf "%s" "$x"; (exit $r)')
case "$out" in *"unbound variable"*) bad "A10 stderr holds 'unbound variable': $(printf '%s' "$out" | sed "s/$SECRET/<SECRET>/g")" ;; *) ok ;; esac
[ "$out" = '{"ok":true}|rc=0' ] && ok || bad "A10 set -u caller with 2>&1: got '$(printf '%s' "$out" | sed "s/$SECRET/<SECRET>/g")'"
check_sent A10 "GET /api/flags/x"

# A11 — _jobs_curl at top level and inside `$( )` leaves the caller's EXIT
# trap as it was, and that trap still runs when the caller's shell exits.
reset; out=$(call -- 'trap "echo CALLER-TRAP" EXIT; _jobs_curl GET /api/flags/x "" "" >/dev/null; echo "top=[$(trap -p EXIT)]"; y=$(_jobs_curl GET /api/flags/x "" "" >/dev/null; trap -p EXIT); echo "sub=[$y]"')
case "$out" in *"top=[trap -- 'echo CALLER-TRAP' EXIT]"*) ok ;; *) bad "A11 top-level trap -p EXIT changed: got '$out'" ;; esac
case "$out" in *"sub=[trap -- 'echo CALLER-TRAP' EXIT]"*) ok ;; *) bad "A11 in-subshell trap -p EXIT changed: got '$out'" ;; esac
case "$out" in *CALLER-TRAP*'|rc='*|*'|rc='*CALLER-TRAP*) ok ;; *) bad "A11 the caller's EXIT trap did not run: got '$out'" ;; esac
grep -qF "$SECRET" "$T/argv" && bad "A11 argv holds the token" || ok

# A12 — SIGTERM to the subshell that runs curl while curl is busy: rc 1,
# nothing written or left in TMPDIR.
reset; rm -f "$T/ppid"; t0=$(tmp_ls)
call CURL_PPID="$T/ppid" CURL_SLEEP=1 CURL_FAIL=7 -- '_jobs_req GET /api/flags/x' > "$T/a12.out" & A12=$!
i=0; while [ ! -s "$T/ppid" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
if [ -s "$T/ppid" ]; then
  kill -TERM "$(cat "$T/ppid")" 2>/dev/null && ok || bad "A12 could not signal the curl subshell"
else
  bad "A12 the curl wrapper did not record its parent pid"
fi
wait "$A12" 2>/dev/null
check_tmp A12 "$t0"
grep -q '|rc=1' "$T/a12.out" && ok || bad "A12 _jobs_req after SIGTERM: got '$(cat "$T/a12.out")' (want |rc=1)"

# A13 — the BH-7432 fork budget: the transport execs only curl. PATH shims
# log every mktemp, rm, cat, printf and stat exec while SHIM_LOG is set (the
# snippet sets it after the client is sourced), then run the real command.
SH13="$T/shim13"; mkdir -p "$SH13"
for c in mktemp rm cat printf stat; do
  real=$(command -v "$c" 2>/dev/null || type -P "$c") || continue
  printf '#!/bin/bash\n[ -z "${SHIM_LOG:-}" ] || echo %s >> "$SHIM_LOG"\nexec %s "$@"\n' "$c" "$real" > "$SH13/$c"
  chmod +x "$SH13/$c"
done
: > "$T/shim.log"
reset; out=$(CALL_PATH_PRE="$SH13:" call SHIM_LOG_AT="$T/shim.log" -- "export SHIM_LOG=\"\$SHIM_LOG_AT\"; _jobs_req GET /api/flags/x >/dev/null; _jobs_req POST /api/x '{\"a\":1}' >/dev/null; _jobs_req_file POST /api/x \"$T/body.json\" >/dev/null")
[ "$out" = '|rc=0' ] && ok || bad "A13 the three calls: got '$out' (want |rc=0)"
[ "$(grep -c '^auth=' "$T/srv/reqs.log")" -eq 3 ] && ok || bad "A13 want 3 requests at the stub, got $(grep -c '^auth=' "$T/srv/reqs.log")"
[ ! -s "$T/shim.log" ] && ok || bad "A13 the transport exec'd more than curl: $(sort "$T/shim.log" | uniq -c | tr -s ' \n' ' ')"

# A14 — the caller's own fd 3 is untouched: it still points at its file after
# _jobs_req, and that file never gets the token.
: > "$T/fd3.out"
reset; out=$(call -- "exec 3>\"$T/fd3.out\"; _jobs_req GET /api/flags/x >/dev/null; echo after >&3")
[ "$out" = '|rc=0' ] && ok || bad "A14 caller with fd 3 open: got '$out' (want |rc=0)"
[ "$(cat "$T/fd3.out")" = after ] && ok || bad "A14 the caller's fd 3 file: [$(sed "s/$SECRET/<SECRET>/g" "$T/fd3.out")] (want 'after')"
grep -qF "$SECRET" "$T/fd3.out" && bad "A14 the caller's fd 3 file holds the token" || ok
check_sent A14 "GET /api/flags/x"

echo "jobs-req-auth-argv: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
