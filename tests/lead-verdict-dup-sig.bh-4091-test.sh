#!/bin/bash
# tests/lead-verdict-dup-sig.bh-4091-test.sh — BH-4091 (BH-3905): when the
# worker answers a post's 201 with human_sig_duplicate_of (a human-token row
# signed in the same second as an earlier identical one, so it reads unproven),
# bin/lead-verdict.sh prints one WARNING line to stderr naming that verdict id.
# The exit code is the one the same post has without the key. Driven through the
# real CLI against a stub gh (head + statuses) and a stub curl (the worker).
#   L1 201 carries "human_sig_duplicate_of":30 -> stderr WARNING names #30; rc 0
#   L2 201 without the key                     -> no WARNING; rc 0
# demo-os has no lead_protected_paths rows: the stub worker answers GET
# /api/lead-protected-paths from tests/lib/lpp-stub.sh with none ($T/lpp.json).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-verdict-dup-sig.bh-4091-test.sh
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
# The stub worker: POST /api/verdicts answers 201, human-verified, and adds
# human_sig_duplicate_of:30 when $W/dup exists.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; M=GET; D=""
while [ \$# -gt 0 ]; do case "\$1" in
  -X) M="\$2"; shift 2 ;;
  --data-binary) D="\$2"; shift 2 ;;
  *) shift ;;
esac; done
case "\$M \$URL" in
$(lpp_curl_case M URL D)
  "POST "*/api/verdicts)
    dup='{}'; [ -f "$W/dup" ] && dup='{"human_sig_duplicate_of":30}'
    printf '%s\n201\n' "\$(jq -c --argjson dup "\$dup" '{verdict:(. + {id:31,created_at:"2026-10-01T10:00:00Z"}),human_verified:true,human_signed:true,human_verdict_mode:"shadow"} + \$dup' <<<"\$D")" ;;
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
cli() { bash "$H/bin/lead-verdict.sh" "$@" >"$T/cli.out" 2>"$T/cli.err"; }

# --- L2 (baseline rc) ---------------------------------------------------------
reset
cli post "$SLUG" 41 "$HEAD1" MERGE --source human; RC2=$?
[ "$RC2" = 0 ] && ok || bad "L2 rc must be 0 (rc $RC2, err $(cat "$T/cli.err"))"
grep -q 'WARNING: this post repeats' "$T/cli.err" && bad "L2 no WARNING without the key: $(cat "$T/cli.err")" || ok
grep -q 'recorded verdict #31' "$T/cli.out" && ok || bad "L2 the recorded line: $(cat "$T/cli.out")"

# --- L1 -----------------------------------------------------------------------
reset; touch "$W/dup"
cli post "$SLUG" 41 "$HEAD1" MERGE --source human; RC1=$?
[ "$RC1" = "$RC2" ] && ok || bad "L1 rc must equal the no-key rc $RC2 (rc $RC1, err $(cat "$T/cli.err"))"
grep -q 'lead-verdict: WARNING: this post repeats verdict #30 within the same second' "$T/cli.err" && ok \
  || bad "L1 the WARNING line: $(cat "$T/cli.err")"
[ "$(grep -c 'WARNING: this post repeats' "$T/cli.err")" = 1 ] && ok || bad "L1 exactly one WARNING line"
grep -q 'WARNING' "$T/cli.out" && bad "L1 the WARNING goes to stderr, not stdout" || ok
[ "$(grep -c -- '-X POST repos/.*/statuses/' "$G/calls" 2>/dev/null)" = 1 ] && ok || bad "L1 the status is still published"

echo "lead-verdict-dup-sig: $PASS PASS, $FAIL FAIL"
[ "$FAIL" = 0 ]
