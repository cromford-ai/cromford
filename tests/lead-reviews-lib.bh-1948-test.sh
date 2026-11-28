#!/bin/bash
# tests/lead-reviews-lib.bh-1948-test.sh — BH-1948 (BH-1525.0): the shell client
# for /api/lead-reviews (bin/lib/lead-reviews.sh), driven through the REAL
# bin/jobs-client.sh transport with only curl stubbed:
#   * lr_get prints the body on 2xx; the jobs worker's own unknown-endpoint 404
#     is rc 75 (route not deployed); any other 404 or a 5xx is rc 1 + HTTP <code>;
#   * lr_post sends the box bearer only; a 409 prints the body and is not rc 0;
#   * lr_post_lead sends the lead token in a 0600 header file, never on argv,
#     and removes that file on success and on a refusal; no token file = no call;
#   * the constants, and sourcing the lib has no side effects.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-reviews-lib.bh-1948-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/lead-reviews.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# A scratch harness carrying the real jobs client and its modules.
H="$T/h"; mkdir -p "$H/bin/lib/jobs" "$T/fakebin" "$T/log"
cp "$DIR/bin/jobs-client.sh" "$H/bin/"
cp "$DIR/bin/lib/env-path.sh" "$H/bin/lib/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"

# The stub curl: one arg per line into $T/log/argv (a "----" line between
# calls), the -H @file header file's content, mode and path captured, and the
# answer "<STUB_BODY>\n<STUB_CODE>".
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
# TEST-CHANGE (BH-9946): the jobs bearer now rides on a curl fd
# (-H @/dev/fd/3), so record that fd's content into the argv log first.
for a in "\$@"; do case "\$a" in @/dev/fd/*) cat "\${a#@}" >> "$T/log/argv" ;; esac; done
printf '%s\n' "\$@" >> "$T/log/argv"; echo ---- >> "$T/log/argv"
prev=""
for a in "\$@"; do
  if [ "\$prev" = -H ]; then case "\$a" in @*)
    f="\${a#@}"; cat "\$f" > "$T/log/hdr"; stat -c %a "\$f" > "$T/log/hdr-mode"; printf '%s' "\$f" > "$T/log/hdr-path" ;;
  esac; fi
  prev="\$a"
done
printf '%s\n%s' "\${STUB_BODY:-}" "\${STUB_CODE:-200}"
EOF
chmod +x "$T/fakebin/curl"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 JOBS_BOX=testbox TMPDIR="$T/tmp"
mkdir -p "$TMPDIR"
TOKF="$T/lead-token"; printf 'tok-FIXTURE-SECRET-123\n' > "$TOKF"; chmod 600 "$TOKF"
export LEAD_VERDICT_TOKEN_FILE="$TOKF"

reset() { rm -f "$T/log"/*; }
calls() { [ -f "$T/log/argv" ] && grep -c '^----$' "$T/log/argv" || echo 0; }
# run <code> <body> <fn> [args...] — the lib sourced fresh in a subshell
run() {
  local code="$1" body="$2"; shift 2
  reset
  ( . "$LIB"; STUB_CODE="$code" STUB_BODY="$body" "$@" ) > "$T/out" 2> "$T/err"
  RC=$?
}

# G1: 200 -> body, rc 0, bearer, the right URL
B='{"requests":[],"truncated":false}'
run 200 "$B" lr_get '?status=requested'
[ "$RC" -eq 0 ] && ok || bad "G1 rc=$RC (want 0)"
[ "$(cat "$T/out")" = "$B" ] && ok || bad "G1 stdout '$(cat "$T/out")'"
grep -qx 'authorization: Bearer test-secret' "$T/log/argv" && ok || bad "G1 no bearer on the request"
grep -qx 'https://jobs.test/api/lead-reviews?status=requested' "$T/log/argv" && ok || bad "G1 url: $(grep -F https:// "$T/log/argv")"

# G2: the jobs worker's own unknown-endpoint 404 -> rc 75
run 404 '{"error":"unknown endpoint","worker":"harness-jobs"}' lr_get ''
[ "$RC" -eq 75 ] && ok || bad "G2 rc=$RC (want 75)"

# G3: any other 404 (a route's unknown id, a CDN) -> rc 1, HTTP 404
run 404 '{"error":"not found"}' lr_get '/lr-1'
[ "$RC" -eq 1 ] && ok || bad "G3 rc=$RC (want 1)"
grep -q 'HTTP 404' "$T/err" && ok || bad "G3 stderr '$(cat "$T/err")'"

# G4: 500 -> rc 1, HTTP 500
run 500 '{"error":"boom"}' lr_get ''
[ "$RC" -eq 1 ] && ok || bad "G4 rc=$RC (want 1)"
grep -q 'HTTP 500' "$T/err" && ok || bad "G4 stderr '$(cat "$T/err")'"

# P1: lr_post 200 -> rc 0, body, bearer only
run 200 '{"request":{"id":"lr-1"}}' lr_post /lr-1/claim '{"job_id":"j1","box":"b"}'
[ "$RC" -eq 0 ] && ok || bad "P1 rc=$RC (want 0)"
[ "$(cat "$T/out")" = '{"request":{"id":"lr-1"}}' ] && ok || bad "P1 stdout '$(cat "$T/out")'"
grep -qx 'authorization: Bearer test-secret' "$T/log/argv" && ok || bad "P1 no bearer"
grep -qx 'https://jobs.test/api/lead-reviews/lr-1/claim' "$T/log/argv" && ok || bad "P1 url"
grep -qi 'x-lead-verdict-token' "$T/log/argv" && bad "P1 sent a lead token header" || ok

# P2: 409 -> not rc 0, body printed, HTTP 409
run 409 '{"error":"claimed by j0"}' lr_post /lr-1/claim '{}'
[ "$RC" -ne 0 ] && ok || bad "P2 rc=0 on a 409"
[ "$(cat "$T/out")" = '{"error":"claimed by j0"}' ] && ok || bad "P2 stdout '$(cat "$T/out")'"
grep -q 'HTTP 409' "$T/err" && ok || bad "P2 stderr '$(cat "$T/err")'"

# L1: lr_post_lead 201 -> token in a 0600 header file, never on argv, file gone
BODY='{"repo":"example-org/demo-os","pr":41,"head_sha":"'"$(printf 'a%.0s' {1..40})"'"}'
run 201 '{"request":{"id":"lr-2"}}' lr_post_lead '' "$BODY"
[ "$RC" -eq 0 ] && ok || bad "L1 rc=$RC (want 0) err='$(cat "$T/err")'"
[ "$(cat "$T/out")" = '{"request":{"id":"lr-2"}}' ] && ok || bad "L1 stdout '$(cat "$T/out")'"
grep -qx 'x-lead-verdict-token: tok-FIXTURE-SECRET-123' "$T/log/hdr" 2>/dev/null && ok || bad "L1 header file has no lead token"
grep -qx 'authorization: Bearer test-secret' "$T/log/hdr" 2>/dev/null && ok || bad "L1 header file has no bearer"
[ "$(cat "$T/log/hdr-mode" 2>/dev/null)" = 600 ] && ok || bad "L1 header file mode $(cat "$T/log/hdr-mode" 2>/dev/null)"
grep -q 'tok-FIXTURE-SECRET-123' "$T/log/argv" && bad "L1 the token is on curl argv" || ok
grep -q 'tok-FIXTURE-SECRET-123' "$T/out" "$T/err" && bad "L1 the token was printed" || ok
[ -s "$T/log/hdr-path" ] && [ ! -e "$(cat "$T/log/hdr-path")" ] && ok || bad "L1 header file not removed"
grep -qx 'https://jobs.test/api/lead-reviews' "$T/log/argv" && ok || bad "L1 url"

# L2: 403 -> rc 1, HTTP 403, header file still removed
run 403 '{"error":"needs the lead verdict token"}' lr_post_lead '' "$BODY"
[ "$RC" -eq 1 ] && ok || bad "L2 rc=$RC (want 1)"
grep -q 'HTTP 403' "$T/err" && ok || bad "L2 stderr '$(cat "$T/err")'"
[ -s "$T/log/hdr-path" ] && [ ! -e "$(cat "$T/log/hdr-path")" ] && ok || bad "L2 header file not removed"

# L3: no token file -> rc 1, no curl call
LEAD_VERDICT_TOKEN_FILE="$T/nope" run 201 '{}' lr_post_lead '' "$BODY"
[ "$RC" -eq 1 ] && ok || bad "L3 rc=$RC (want 1)"
[ "$(calls)" = 0 ] && ok || bad "L3 curl was called $(calls) time(s)"

# C1: the constants
( . "$LIB"
  [ "$LR_STATUSES" = "requested running done superseded failed" ] || exit 1
  [ "$LR_VERDICT_WORDS" = "MERGE MERGE-WITH-NOTES BLOCK" ] || exit 2
  case " $LR_VERDICT_WORDS " in *" APPROVE "*) exit 3 ;; esac ); rc=$?
[ "$rc" -eq 0 ] && ok || bad "C1 constants (rc=$rc)"

# C2: sourcing has no side effects: no curl call, no file anywhere, the three
# functions defined, rc 0
reset; E="$T/empty"; mkdir -p "$E"
before=$(find "$T" -path "$T/log" -prune -o -print | sort)
( HARNESS="$E"; . "$LIB" || exit 9
  for f in lr_get lr_post lr_post_lead; do declare -F "$f" >/dev/null || exit 8; done ); rc=$?
after=$(find "$T" -path "$T/log" -prune -o -print | sort)
[ "$rc" -eq 0 ] && ok || bad "C2 source rc=$rc"
[ "$(calls)" = 0 ] && ok || bad "C2 sourcing called curl"
[ "$before" = "$after" ] && ok || bad "C2 sourcing changed the tree: $(diff <(echo "$before") <(echo "$after"))"

# C3: no model literal in the client
[ "$(grep -c 'claude-' "$LIB")" = 0 ] && ok || bad "C3 a claude- literal in the lib"

echo "lead-reviews-lib: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
