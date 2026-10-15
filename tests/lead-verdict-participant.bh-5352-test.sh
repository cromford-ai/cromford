#!/bin/bash
# tests/lead-verdict-participant.bh-5352-test.sh — BH-5352: a participant
# machine posts a lead verdict, and the lead-verdict status names it. Driven
# through the real bin/lead-verdict.sh post against a stub curl (the jobs
# worker) and a stub gh (GitHub statuses):
#   P  no lead token file, HARNESS_PARTICIPANT_TOKEN_FILE readable: the header
#      file carries x-participant-token (not x-lead-verdict-token); the worker's
#      auth=participant row publishes `lead review by mac-test-1: ...`.
#   L  a lead-token row publishes today's description, no prefix.
#   U  the worker refuses the participant (403): rc 1, no status POST.
#   E  an empty participant token file dies before any POST.
#   D  vs_lead_desc on its own: participant row, lead row, malformed JSON.
#   S  the token never reaches a stub's argv log; no merge call is made.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-verdict-participant.bh-5352-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SLUG=example-org/demo-os
HEAD1=aaaaaaaa11111111111111111111111111111111
PTOK=participant-secret-5352
G="$T/gh"; W="$T/worker"; mkdir -p "$G" "$W" "$T/fakebin" "$T/tmp" "$T/tok"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"

# The stub gh: the PR head is HEAD1, the statuses POST answers 201.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$G/calls"; printf '%s\n' "\$*" >> "$T/gh-all"
case "\$*" in
  *"api -i -X GET repos/"*"/pulls/"[0-9]*) restpr OPEN "$HEAD1" ticket/x main ;;
  *"api -i -X POST repos/"*"/statuses/"*) restpr --raw 201 '{"id":1}' ;;
  *) echo "" ;;
esac
exit 0
EOF
# The stub worker. $W/mode = participant | lead | refuse decides the answer to
# POST /api/verdicts; the header file curl was given is copied to $W/hdr.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/curl-all"
URL="\${!#}"; M=GET; D=""
while [ \$# -gt 0 ]; do case "\$1" in
  -X) M="\$2"; shift 2 ;; --data-binary) D="\$2"; shift 2 ;;
  -H) case "\$2" in @*) cp "\${2#@}" "$W/hdr" ;; esac; shift 2 ;;
  *) shift ;; esac; done
case "\$M \$URL" in
$(lpp_curl_case M URL D)
  "POST "*/api/verdicts)
    printf '%s\n' "\$D" >> "$W/posted"
    case "\$(cat "$W/mode")" in
      refuse) printf '{"error":"participant: unknown participant token"}\n403\n' ;;
      participant) printf '%s\n201\n' "\$(jq -c '{verdict:(. + {id:7,auth:"participant",reviewer:"mac-test-1",created_at:"2026-10-08T00:00:00Z"})}' <<<"\$D")" ;;
      *) printf '%s\n201\n' "\$(jq -c '{verdict:(. + {id:7,auth:"lead-token",created_at:"2026-10-08T00:00:00Z"})}' <<<"\$D")" ;;
    esac ;;
  *) printf '{"error":"unknown endpoint"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"
printf '%s\n' "$PTOK" > "$T/tok/participant"; chmod 600 "$T/tok/participant"
printf 'lead-test-token\n' > "$T/tok/lead"; chmod 600 "$T/tok/lead"

H="$T/h"; mkdir -p "$H/logs" "$H/state" "$H/catalog"
scratch_install_closure bin/lead-verdict.sh "$H" >/dev/null || { echo "FAIL: closure of bin/lead-verdict.sh"; exit 1; }
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || { echo "FAIL: closure of bin/jobs-client.sh"; exit 1; }
# TEST-CHANGE BH-4148 (merge of main): the lead protected paths come from the
# lead_protected_paths rows (tests/lib/lpp-stub.sh), not the deleted TSV. The rows
# are the cromford globs the TSV held (the fixture).
LPPF="$T/lpp.json"; LPPDOWN="$T/lpp-down"
set -f; lpp_set "$LPPF" example-org/cromford $(cat "$DIR/tests/fixtures/lead-protected-paths.bh-4148.txt"); set +f
lpp_install "$T/fakebin" "$LPPF" "$LPPDOWN"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=s JOBS_URL=https://jobs.test JOBS_RETRIES=0 \
  JOBS_BOX=mac-test-1 TMPDIR="$T/tmp" GH_APP_TOKENS=0 \
  LEAD_VERDICT_TOKEN_FILE="$T/tok/no-such-lead-token" HARNESS_PARTICIPANT_TOKEN_FILE="$T/tok/participant"
unset LEAD_VERDICT_CONTEXT GH_TOKEN

reset() { rm -f "$G"/* "$W"/*; echo "${1:-participant}" > "$W/mode"; }
statuses() { grep -c -- '-X POST repos/.*/statuses/' "$G/calls" 2>/dev/null; }
desc_of() { sed -n 's/.*-f description=\(.*\)$/\1/p' "$G/calls" | sed 's/ -f target_url=.*//'; }
cli() { bash "$H/bin/lead-verdict.sh" "$@" 2>"$T/cli.err"; }

# P. the participant post, end to end
reset participant
cli post "$SLUG" 41 "$HEAD1" MERGE >/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "P1 a participant post with an auth=participant row is rc 0 (rc $RC, err $(cat "$T/cli.err"))"
grep -q "^x-participant-token: $PTOK\$" "$W/hdr" 2>/dev/null && ok || bad "P2 the header file must carry x-participant-token"
grep -q '^x-lead-verdict-token:' "$W/hdr" 2>/dev/null && bad "P2 no x-lead-verdict-token in participant mode" || ok
[ "$(statuses)" = 1 ] && ok || bad "P3 exactly one statuses POST (got $(statuses))"
D=$(desc_of)
[[ "$D" == "lead review by mac-test-1: MERGE by mac-test-1 (verdict #7)" ]] && ok || bad "P4 the description starts 'lead review by mac-test-1:' (got '$D')"
[ "$(jq -r .source "$W/posted")" = lead ] && ok || bad "P5 the body posts source=lead: $(cat "$W/posted")"

# L. a lead-token row: today's description, no prefix
reset lead
LEAD_VERDICT_TOKEN_FILE="$T/tok/lead" cli post "$SLUG" 41 "$HEAD1" MERGE --reviewer hub >/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "L1 a lead-token post is rc 0 (rc $RC, err $(cat "$T/cli.err"))"
grep -q '^x-lead-verdict-token: lead-test-token$' "$W/hdr" && ! grep -q '^x-participant-token:' "$W/hdr" && ok \
  || bad "L2 a readable lead token file wins over the participant file"
D=$(desc_of)
[ "$D" = "MERGE by hub (verdict #7)" ] && ok || bad "L3 a lead-token row keeps today's description (got '$D')"

# U. the worker refuses the participant: no status
reset refuse
cli post "$SLUG" 41 "$HEAD1" MERGE >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "U1 a refused participant post is rc 1 (rc $RC)"
grep -q 'unknown participant token' "$T/cli.err" && ok || bad "U2 the worker's error is printed: $(cat "$T/cli.err")"
[ "$(statuses)" = 0 ] && ok || bad "U3 no statuses POST after a refusal (got $(statuses))"

# E. an empty participant token file: nothing is posted
reset participant
: > "$T/tok/empty"
HARNESS_PARTICIPANT_TOKEN_FILE="$T/tok/empty" cli post "$SLUG" 41 "$HEAD1" MERGE >/dev/null; RC=$?
[ "$RC" = 1 ] && [ ! -f "$W/posted" ] && grep -q 'is empty' "$T/cli.err" && ok \
  || bad "E1 an empty token file dies before any POST (rc $RC, err $(cat "$T/cli.err"))"
reset participant
HARNESS_PARTICIPANT_TOKEN_FILE= cli post "$SLUG" 41 "$HEAD1" MERGE >/dev/null; RC=$?
[ "$RC" = 1 ] && [ ! -f "$W/posted" ] && grep -q 'HARNESS_PARTICIPANT_TOKEN_FILE' "$T/cli.err" && ok \
  || bad "E2 neither token readable dies naming both files (rc $RC, err $(cat "$T/cli.err"))"
reset participant
cli post "$SLUG" 41 "$HEAD1" MERGE --source human >/dev/null; RC=$?
[ "$RC" = 1 ] && [ ! -f "$W/posted" ] && ok || bad "E3 a participant token never posts --source human (rc $RC)"

# D. vs_lead_desc on its own
vld() { ( . "$H/bin/lib/verdict-status.sh"; vs_lead_desc "$@" ); }
[ "$(vld '{"auth":"participant","reviewer":"mac-test-1"}' 'MERGE by x (verdict #7)')" = "lead review by mac-test-1: MERGE by x (verdict #7)" ] \
  && ok || bad "D1 a participant row gets the prefix"
[ "$(vld '{"auth":"lead-token","reviewer":"mac-test-1"}' 'MERGE by x')" = "MERGE by x" ] && ok || bad "D2 a lead-token row is unchanged"
[ "$(vld '{"auth":"participant","reviewer":""}' 'MERGE by x')" = "MERGE by x" ] && ok || bad "D3 a participant row with no reviewer is unchanged"
OUT=$(vld 'not json {' 'MERGE by x'); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "MERGE by x" ] && ok || bad "D4 malformed JSON is unchanged, rc 0 (rc $RC, '$OUT')"
OUT=$(vld '' 'MERGE by x'); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "MERGE by x" ] && ok || bad "D5 an empty row is unchanged, rc 0"

# S. no secret on argv, no merge call
[ -s "$T/curl-all" ] && [ -s "$T/gh-all" ] && ok || bad "S0 both stubs were called"
grep -qF "$PTOK" "$T/curl-all" "$T/gh-all" && bad "S1 the participant token reached a stub argv log" || ok
grep -qE 'pulls/[0-9]+/merge|/merges' "$T/gh-all" "$T/curl-all" && bad "S2 a merge call was made" || ok

echo "lead-verdict-participant.bh-5352: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
