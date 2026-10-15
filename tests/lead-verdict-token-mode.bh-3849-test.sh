#!/bin/bash
# tests/lead-verdict-token-mode.bh-3849-test.sh — BH-3849: bin/lead-verdict.sh
# warns on stderr when the human verdict token file (HUMAN_VERDICT_TOKEN_FILE)
# is not mode 600. A warning only: the post still goes out, rc unchanged, and
# the line names the path and mode, never the token. Driven through the real
# CLI against a stub gh (head + statuses) and a stub curl (the worker).
#   M1 token file 0644 -> one 'not 600' stderr line; rc 0; the post was made
#   M2 token file 0600 -> no 'not 600' line
#   M3 the token value is never in stdout or stderr
#   M4 no token file   -> no 'not 600' line (BH-3831 C2 counts its two lines)
# demo-os has no lead_protected_paths rows: the stub worker answers GET
# /api/lead-protected-paths from tests/lib/lpp-stub.sh with none ($T/lpp.json).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-verdict-token-mode.bh-3849-test.sh
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
HEAD1=dddddddd44444444444444444444444444444444
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
cli() { bash "$H/bin/lead-verdict.sh" "$@" >"$T/cli.out" 2>"$T/cli.err"; }

# --- M1 ---------------------------------------------------------------------
reset; chmod 644 "$T/tok/human"
cli post "$SLUG" 41 "$HEAD1" MERGE --source human; RC=$?
[ "$RC" = 0 ] && ok || bad "M1 rc must be 0 (rc $RC, err $(cat "$T/cli.err"))"
[ "$(grep -c 'not 600' "$T/cli.err")" = 1 ] && ok || bad "M1 one 'not 600' warning on stderr: $(cat "$T/cli.err")"
grep -q "$T/tok/human is mode 644, not 600" "$T/cli.err" && ok || bad "M1 the line names the path and mode: $(cat "$T/cli.err")"
grep -q 'not 600' "$T/cli.out" && bad "M1 the warning goes to stderr, not stdout" || ok
[ "$(rows)" = 1 ] && ok || bad "M1 the post must still go out (rows $(rows))"
grep -qx 'x-human-verdict-token: human-test-token' "$W/hdrs" 2>/dev/null && ok || bad "M1 the human token still rides"
grep -q 'human-test-token' "$T/cli.out" "$T/cli.err" && bad "M3 the human token was printed (0644)" || ok

# --- M2 ---------------------------------------------------------------------
reset; chmod 600 "$T/tok/human"
cli post "$SLUG" 41 "$HEAD1" MERGE --source human; RC=$?
[ "$RC" = 0 ] && ok || bad "M2 rc must be 0 (rc $RC, err $(cat "$T/cli.err"))"
grep -q 'not 600' "$T/cli.err" && bad "M2 no warning at 0600: $(cat "$T/cli.err")" || ok
grep -q 'human-test-token' "$T/cli.out" "$T/cli.err" && bad "M3 the human token was printed (0600)" || ok

# --- M4 ---------------------------------------------------------------------
reset
HUMAN_VERDICT_TOKEN_FILE="$T/tok/missing" cli post "$SLUG" 41 "$HEAD1" MERGE --source human; RC=$?
[ "$RC" = 0 ] && ok || bad "M4 rc must be 0 (rc $RC)"
grep -q 'not 600' "$T/cli.err" && bad "M4 no mode warning without a file: $(cat "$T/cli.err")" || ok
# ...and a lead post never looks at the human token file.
reset; chmod 644 "$T/tok/human"
cli post "$SLUG" 41 "$HEAD1" BLOCK --source lead; RC=$?
[ "$RC" = 0 ] && ok || bad "M4 lead rc 0 (rc $RC)"
grep -q 'not 600' "$T/cli.err" && bad "M4 no mode warning on a lead post: $(cat "$T/cli.err")" || ok

echo "lead-verdict-token-mode: $PASS PASS, $FAIL FAIL"
[ "$FAIL" = 0 ]
