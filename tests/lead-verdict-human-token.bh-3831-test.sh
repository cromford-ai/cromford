#!/bin/bash
# tests/lead-verdict-human-token.bh-3831-test.sh — BH-3831: a --source human
# verdict from bin/lead-verdict.sh carries the human verdict token
# (HUMAN_VERDICT_TOKEN_FILE) to the worker as x-human-verdict-token, in the same
# 0600 header file as the bearer and the lead token, never on argv and never
# printed. Without the file the post still goes out, with one stderr line, and
# the worker decides (shadow: recorded UNVERIFIED; enforce: 403). Driven through
# the real CLI against a stub gh (head + statuses) and a stub curl (the worker)
# that keeps a copy of the header file it was handed.
#   C1 human + token file   -> header carries the token; not in argv/stdout/stderr; rc 0
#   C2 human, no token file -> still posted; the two warning lines; rc 0
#   C3 C2 in enforce        -> rc 1 with the worker's 403; no status published
#   C4 lead + token file    -> no x-human-verdict-token header
#   C5 box                  -> no lead or human header
#   C6 no lead-verdict-h.* header file survives any run
# demo-os has no lead_protected_paths rows: the stub worker answers GET
# /api/lead-protected-paths from tests/lib/lpp-stub.sh with none ($T/lpp.json).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-verdict-human-token.bh-3831-test.sh
# TEST-CHANGE BH-4140: globs come from the DB, not the TSV
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SLUG=example-org/demo-os
HEAD1=cccccccc33333333333333333333333333333333
G="$T/gh"; W="$T/worker"; mkdir -p "$G" "$W" "$T/fakebin" "$T/tmp" "$T/tok"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
lpp_install "$T/fakebin" "$T/lpp.json" "$T/lpp-down"

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$G/calls"
case "\$*" in
  *"api -i -X GET repos/"*"/pulls/"[0-9]*) restpr OPEN "\$(cat "$G/head")" ticket/x main ;;
  *"api -i -X POST repos/"*"/statuses/"*) restpr --raw 201 '{"id":1}' ;;
  *) echo "" ;;
esac
exit 0
EOF
# The stub worker. Every curl argv goes to $W/argv; a -H @file is copied to
# $W/hdrs. POST /api/verdicts: 403 when $W/enforce exists and the header file
# has no human token, else 201 with human_verified = whether it had one.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$W/argv"
URL="\${!#}"; M=GET; D=""
while [ \$# -gt 0 ]; do case "\$1" in
  -X) M="\$2"; shift 2 ;;
  --data-binary) D="\$2"; shift 2 ;;
  -H) case "\$2" in @*) cat "\${2#@}" >> "$W/hdrs" ;; *) printf '%s\n' "\$2" >> "$W/hdrs" ;; esac; shift 2 ;;
  *) shift ;;
esac; done
case "\$M \$URL" in
$(lpp_curl_case M URL D)
  "POST "*/api/verdicts)
    printf '%s\n' "\$D" >> "$W/posted"
    hv=false; grep -qx 'x-human-verdict-token: human-test-token' "$W/hdrs" 2>/dev/null && hv=true
    if [ -f "$W/enforce" ] && [ "\$hv" = false ] && [ "\$(jq -r .source <<<"\$D")" = human ]; then
      printf '{"error":"source=human needs the human verdict token (x-human-verdict-token); the lead token alone may write source=lead. human_verdict_mode=enforce","human_verdict_mode":"enforce"}\n403\n'
    else
      printf '%s\n201\n' "\$(jq -c --argjson hv "\$hv" '{verdict:(. + {id:31,created_at:"2026-10-01T10:00:00Z"}),human_verified:\$hv,human_verdict_mode:"shadow"}' <<<"\$D")"
    fi ;;
  *) printf '{"error":"unknown endpoint"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"
printf 'lead-test-token\n' > "$T/tok/lead"; chmod 600 "$T/tok/lead"
printf 'human-test-token\n' > "$T/tok/human"; chmod 600 "$T/tok/human"

H="$T/h"; mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/state"
cp "$DIR/bin/lead-verdict.sh" "$DIR/bin/jobs-client.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/verdict-status.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-app-auth.sh" "$H/bin/lib/" 2>/dev/null
for f in env-path lead-reviews verdicts hub-box lane-gate lead-authority; do cp "$DIR/bin/lib/$f.sh" "$H/bin/lib/"; done

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=s JOBS_URL=https://jobs.test JOBS_RETRIES=0 \
  JOBS_BOX=mac-lead TMPDIR="$T/tmp" LEAD_VERDICT_TOKEN_FILE="$T/tok/lead" HUMAN_VERDICT_TOKEN_FILE="$T/tok/human" \
  GH_APP_TOKENS=0
unset LEAD_VERDICT_CONTEXT GH_TOKEN

reset() { rm -f "$G"/* "$W"/*; echo "$HEAD1" > "$G/head"; }
rows() { [ -f "$W/posted" ] && grep -c . "$W/posted" || echo 0; }
statuses() { grep -c -- '-X POST repos/.*/statuses/' "$G/calls" 2>/dev/null; }
cli() { bash "$H/bin/lead-verdict.sh" "$@" >"$T/cli.out" 2>"$T/cli.err"; }
hdr_files() { find "$T/tmp" -name 'lead-verdict-h.*' 2>/dev/null | grep -c .; }

# --- C1 ---------------------------------------------------------------------
reset
cli post "$SLUG" 41 "$HEAD1" MERGE --source human; RC=$?
[ "$RC" = 0 ] && ok || bad "C1 rc must be 0 (rc $RC, err $(cat "$T/cli.err"))"
grep -qx 'x-human-verdict-token: human-test-token' "$W/hdrs" 2>/dev/null && ok \
  || bad "C1 the header file must carry the human token: $(sed 's/:.*/: …/' "$W/hdrs" 2>/dev/null | tr '\n' '|')"
grep -qx 'x-lead-verdict-token: lead-test-token' "$W/hdrs" 2>/dev/null && ok || bad "C1 the lead token still rides"
grep -q 'human-test-token' "$W/argv" && bad "C1 the human token is on curl's argv" || ok
grep -q 'human-test-token' "$T/cli.out" "$T/cli.err" && bad "C1 the human token was printed" || ok
[ "$(rows)" = 1 ] && [ "$(statuses)" = 1 ] && ok || bad "C1 one row and one lead-verdict status (rows $(rows), statuses $(statuses))"
grep -q 'UNVERIFIED\|no human verdict token' "$T/cli.err" && bad "C1 no warning when the token rode: $(cat "$T/cli.err")" || ok
[ "$(hdr_files)" = 0 ] && ok || bad "C6 the header file must be gone after C1"

# --- C2 ---------------------------------------------------------------------
reset
HUMAN_VERDICT_TOKEN_FILE="$T/tok/missing" cli post "$SLUG" 41 "$HEAD1" MERGE --source human; RC=$?
[ "$RC" = 0 ] && ok || bad "C2 rc must be 0 (rc $RC, err $(cat "$T/cli.err"))"
[ "$(rows)" = 1 ] && ok || bad "C2 the post must still go out (rows $(rows))"
grep -q 'x-human-verdict-token' "$W/hdrs" 2>/dev/null && bad "C2 no human header without the file" || ok
grep -q 'no human verdict token (HUMAN_VERDICT_TOKEN_FILE' "$T/cli.err" && ok || bad "C2 the missing-file line: $(cat "$T/cli.err")"
grep -q 'UNVERIFIED human verdict' "$T/cli.err" && ok || bad "C2 the UNVERIFIED line: $(cat "$T/cli.err")"
# An empty file is the same as a missing one.
reset; : > "$T/tok/empty"
HUMAN_VERDICT_TOKEN_FILE="$T/tok/empty" cli post "$SLUG" 41 "$HEAD1" MERGE --source human; RC=$?
[ "$RC" = 0 ] && grep -q 'no human verdict token' "$T/cli.err" && ! grep -q 'x-human-verdict-token' "$W/hdrs" && ok \
  || bad "C2 an empty token file is the missing-file path (rc $RC)"
[ "$(hdr_files)" = 0 ] && ok || bad "C6 the header file must be gone after C2"

# --- C3 ---------------------------------------------------------------------
reset; touch "$W/enforce"
HUMAN_VERDICT_TOKEN_FILE="$T/tok/missing" cli post "$SLUG" 41 "$HEAD1" MERGE --source human; RC=$?
[ "$RC" = 1 ] && ok || bad "C3 enforce without the token must be rc 1 (rc $RC)"
grep -q 'http 403' "$T/cli.err" && grep -q 'x-human-verdict-token' "$T/cli.err" && ok || bad "C3 the worker's 403 text: $(cat "$T/cli.err")"
[ "$(statuses)" = 0 ] && ok || bad "C3 no status published on a refused post"
# ...and with the token, enforce records it.
reset; touch "$W/enforce"
cli post "$SLUG" 41 "$HEAD1" MERGE --source human; RC=$?
[ "$RC" = 0 ] && [ "$(statuses)" = 1 ] && ok || bad "C3 enforce with the token is rc 0 + status (rc $RC)"
[ "$(hdr_files)" = 0 ] && ok || bad "C6 the header file must be gone after C3"

# --- C4 ---------------------------------------------------------------------
reset
cli post "$SLUG" 41 "$HEAD1" BLOCK --source lead; RC=$?
[ "$RC" = 0 ] && ok || bad "C4 lead BLOCK rc 0 (rc $RC, err $(cat "$T/cli.err"))"
grep -q 'x-human-verdict-token' "$W/hdrs" 2>/dev/null && bad "C4 a lead post must not send the human token" || ok
grep -qx 'x-lead-verdict-token: lead-test-token' "$W/hdrs" && ok || bad "C4 the lead token rides on a lead post"
grep -q 'UNVERIFIED\|no human verdict token' "$T/cli.err" && bad "C4 no human warning on a lead post" || ok

# --- C5 ---------------------------------------------------------------------
reset
cli post "$SLUG" 41 "$HEAD1" MERGE --source box; RC=$?
[ "$RC" = 0 ] && ok || bad "C5 box rc 0 (rc $RC, err $(cat "$T/cli.err"))"
grep -q 'x-human-verdict-token\|x-lead-verdict-token' "$W/hdrs" 2>/dev/null && bad "C5 a box post sends no lead/human header" || ok
[ "$(rows)" = 1 ] && ok || bad "C5 the box row was posted (rows $(rows))"
[ "$(hdr_files)" = 0 ] && ok || bad "C6 the header file must be gone after C5"

echo "lead-verdict-human-token: $PASS PASS, $FAIL FAIL"
[ "$FAIL" = 0 ]
