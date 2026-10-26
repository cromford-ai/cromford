#!/bin/bash
# tests/lead-verdict-record-head.bh-8334-test.sh — BH-8334 (C0): a finished
# review still lands when GitHub refuses the head read for quota. Driven
# through the real `bin/lead-verdict.sh post` and, in L1, the real
# bin/lead-review-land.sh tick that calls it. Stubs only: gh (GitHub) and curl
# (the jobs worker: /api/verdicts, GET /api/pr-records, the lead-review list).
# The record answer for PR <n> of demo-os is $W/rec-<n>.json ({row, age_s});
# another repo's same number has no row.
#
#   T1  403 "API rate limit exceeded" on pulls/7, record age 30 s, record head
#       = the review sha: one POST /api/verdicts for that sha, "recorded
#       verdict #", the stderr line "using the PR record's head", rc 0
#   T2  429 secondary rate limit, record age 899: rc 0, one row
#   T3  quota-reserve (an optional read refused before the request): rc 4
#       (the status POST is refused too), one row, pulls/7 never sent
#   T4  the record head in upper case: lowercased, rc 0
#   T5  the record head is another sha: rc 3 "head moved", no row
#   N1  network (no status line)   N2 401   N3 404 (rc 44)
#   N4  403 "Resource not accessible by integration" (not a rate limit)
#   N5  record age 901 > 900       N6 no row       N7 the jobs read fails (500)
#   N8  head_sha null              N9 head_sha 12 chars    N10 knob 0
#       each: rc 1, no row, no status, and the die line names the reason
#   G1  GitHub answers 200: 0 GET /api/pr-records
#   P1  pr_record_peek: a row prints the row plus age_s, rc 0, no gh call
#   P2  no row: rc 1, nothing printed, one logs/pr-record.log miss line
#   P3  a failed read: rc 1 (miss=unreadable); bad args rc 1 and no request;
#       the knob reads 900 by default and for a non-integer
#   L1  bin/lead-review-land.sh over one done MERGE lead review, 403 on
#       pulls/7: "posted as a source=lead row", one POST /api/verdicts
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-verdict-record-head.bh-8334-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq >/dev/null || { echo "SKIP: jq missing"; exit 0; }

SLUG=example-org/demo-os
SHA=aaaaaaaa11111111111111111111111111111111
OTHER=bbbbbbbb22222222222222222222222222222222
G="$T/gh"; W="$T/worker"; mkdir -p "$G" "$W" "$T/fakebin" "$T/tmp" "$T/tok"
cp "$REPO/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
LPPF="$T/lpp.json"; DOWNF="$T/lpp-down"
lpp_install "$T/fakebin" "$LPPF" "$DOWNF"

# The stub gh. $G/pull picks the answer of the PR read: ok (200, head $SHA),
# ratelimit (403 rate limit), secondary (429), perm (403 not a rate limit),
# 401, 404, none (no status line at all). Every call is logged to $G/calls.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$G/calls"
case "\$*" in
  *"api -i -X GET repos/"*"/pulls/"[0-9]*"/reviews"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls/"[0-9]*)
    case "\$(cat "$G/pull" 2>/dev/null)" in
      ratelimit) restpr --raw 403 '{"message":"API rate limit exceeded for installation ID 1."}' ;;
      secondary) restpr --raw 429 '{"message":"You have exceeded a secondary rate limit."}' ;;
      perm) restpr --raw 403 '{"message":"Resource not accessible by integration"}' ;;
      401) restpr --raw 401 '{"message":"Bad credentials"}' ;;
      404) restpr --raw 404 '{"message":"Not Found"}' ;;
      none) : ;;
      *) restpr OPEN "$SHA" ticket/x main ;;
    esac ;;
  *"api -i -X POST repos/"*"/statuses/"*) restpr --raw 201 '{"id":1}' ;;
  *) echo "" ;;
esac
exit 0
EOF
# The stub jobs worker. GET /api/verdicts answers no rows (step 1 of the land
# lane); GET /api/lead-reviews answers $W/requests.json.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; M=GET; D=""
while [ \$# -gt 0 ]; do case "\$1" in -X) M="\$2"; shift 2 ;; --data-binary|-d|--data) D="\$2"; shift 2 ;; *) shift ;; esac; done
case "\$M \$URL" in
$(lpp_curl_case M URL D)
  "POST "*/api/verdicts)
    printf '%s\n' "\$D" >> "$W/posted"
    printf '%s\n201\n' "\$(jq -c '{verdict:(. + {id:21,created_at:"2026-10-25T10:00:00Z"})}' <<<"\$D")" ;;
  "GET "*"/api/verdicts?"*) printf '{"standing":null,"rows":[],"truncated":false}\n200\n' ;;
  "GET "*"/api/lead-reviews"*) printf '%s\n200\n' "\$(cat "$W/requests.json" 2>/dev/null || echo '{"requests":[],"truncated":false}')" ;;
  "POST "*"/api/lead-reviews/"*/promoted) printf '{"request":{"promoted_verdict_at":"2026-10-26T00:00:00Z"}}\n200\n' ;;
  "GET "*"/api/pr-records?"*)
    printf '%s\n' "\$URL" >> "$W/rec-reads"
    [ -f "$W/rec-down" ] && { printf '{"error":"boom"}\n500\n'; exit 0; }
    n=\${URL##*number=}; n=\${n%%&*}
    case "\$URL" in
      *"repo=example-org/demo-os&"*) if [ -f "$W/rec-\$n.json" ]; then printf '%s\n200\n' "\$(cat "$W/rec-\$n.json")"; else printf '{"row":null,"age_s":null}\n200\n'; fi ;;
      *) printf '{"row":null,"age_s":null}\n200\n' ;;
    esac ;;
  *) printf '{"error":"unknown endpoint"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"
printf 'lead-test-token-fixture\n' > "$T/tok/lead"; chmod 600 "$T/tok/lead"

H="$T/h"; mkdir -p "$H/bin" "$H/logs" "$H/state"
for L in bin/lead-verdict.sh bin/lead-review-land.sh bin/jobs-client.sh; do
  scratch_install_closure "$L" "$H" >/dev/null || { echo "FAIL: closure install of $L"; exit 1; }
done
[ -r "$H/bin/lib/pr-record.sh" ] && ok "the closure of bin/lead-verdict.sh carries bin/lib/pr-record.sh" \
  || bad "the closure of bin/lead-verdict.sh lacks bin/lib/pr-record.sh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.test JOBS_RETRIES=0 \
  JOBS_BOX=mac-lead TMPDIR="$T/tmp" LEAD_VERDICT_TOKEN_FILE="$T/tok/lead" GH_APP_TOKENS=0 LV_DISMISS_STALE=0 \
  LANE_GATE_DISABLE=1
unset LEAD_VERDICT_CONTEXT GH_TOKEN PR_RECORD_HEAD_FALLBACK_MAX_AGE_S GH_REST_OPTIONAL BOX_NAME HUB_BOX_NAME

# rec <n> <age> <head|null> — the record of demo-os#<n>.
rec() {
  local h='null'; [ "$3" = null ] || h="\"$3\""
  printf '{"row":{"repo":"example-org/demo-os","number":%s,"state":"open","head_sha":%s,"refreshed_at":"2026-10-25T10:00:00Z"},"age_s":%s}\n' "$1" "$h" "$2" > "$W/rec-$1.json"
}
reset() { scratch_rm "$G"; scratch_rm "$W"; scratch_rm "$H/state/gh-rest-ledger"; mkdir -p "$G" "$W"; echo ok > "$G/pull"; rm -f "$H/logs/pr-record.log"; }
rows() { [ -f "$W/posted" ] && grep -c . "$W/posted" || echo 0; }
recreads() { [ -f "$W/rec-reads" ] && grep -c . "$W/rec-reads" || echo 0; }
statuses() { local n; n=$(grep -c -- '-X POST repos/.*/statuses/' "$G/calls" 2>/dev/null); echo "${n:-0}"; }
post() { bash "$H/bin/lead-verdict.sh" post "$@" 2>"$T/cli.err" >"$T/cli.out"; }
err() { tr '\n' ' ' < "$T/cli.err"; }

# ---- T: the record head is used --------------------------------------------
reset; echo ratelimit > "$G/pull"; rec 7 30 "$SHA"
post "$SLUG" 7 "$SHA" MERGE; RC=$?
eq "T1 403 rate limit + a 30 s record: post rc 0 ($(err))" "$RC" 0
eq "T1 one POST /api/verdicts" "$(rows)" 1
eq "T1 the row binds the review sha" "$(jq -r '.head_sha' "$W/posted" 2>/dev/null)" "$SHA"
grep -q '^recorded verdict #21' "$T/cli.out" && ok "T1 prints recorded verdict #" || bad "T1 no 'recorded verdict #': $(cat "$T/cli.out")"
grep -q "GitHub refused the head read of $SLUG#7 (rate-limit); using the PR record's head ${SHA:0:12} (age 30s)" "$T/cli.err" \
  && ok "T1 one stderr line says the head came from the record" || bad "T1 the record-head line is missing: $(err)"
eq "T1 one record read" "$(recreads)" 1
eq "T1 the lead-verdict status was posted" "$(statuses)" 1
eq "T1 the gh stub saw only stubbed paths" "$(grep -cvE -- '-X GET repos/example-org/demo-os/pulls/7$|-X POST repos/example-org/demo-os/statuses/' "$G/calls")" 0

reset; echo secondary > "$G/pull"; rec 7 899 "$SHA"
post "$SLUG" 7 "$SHA" MERGE; RC=$?
eq "T2 429 secondary rate limit + an 899 s record: rc 0 ($(err))" "$RC" 0
eq "T2 one row" "$(rows)" 1

# T3: quota-reserve. An optional read with the persisted bucket reading below
# the reserve is refused before the request (bin/lib/gh-rest-ledger.sh).
reset; rec 7 30 "$SHA"
BUCKET=$(HARNESS="$H" bash -c '. "$1/bin/lib/gh-rest.sh"; gh_quota_bucket' _ "$H" 2>/dev/null)
mkdir -p "$H/state/gh-rest-ledger"
printf '0 7000 %s %s\n' "$(( $(date -u +%s) + 1800 ))" "$(date -u +%s)" > "$H/state/gh-rest-ledger/.quota-${BUCKET:-none}"
# GH_REST_OPTIONAL=1 is process-wide here, so the status POST is refused too:
# rc 4 is post's "row recorded, status not published" (the drained-bucket path).
GH_REST_OPTIONAL=1 post "$SLUG" 7 "$SHA" MERGE; RC=$?
eq "T3 quota-reserve + a 30 s record: rc 4, the row is recorded ($(err))" "$RC" 4
eq "T3 one row" "$(rows)" 1
grep -q '(quota-reserve); using the PR record' "$T/cli.err" && ok "T3 the line names quota-reserve" || bad "T3 no quota-reserve line: $(err)"
grep -q 'pulls/7' "$G/calls" 2>/dev/null && bad "T3 the refused read must not reach gh" || ok "T3 the refused read never reached gh"

reset; echo ratelimit > "$G/pull"; rec 7 30 "$(printf '%s' "$SHA" | tr 'a-f' 'A-F')"
post "$SLUG" 7 "$SHA" MERGE; RC=$?
eq "T4 an upper-case record head: rc 0 ($(err))" "$RC" 0
eq "T4 the row binds the lower-case sha" "$(jq -r '.head_sha' "$W/posted" 2>/dev/null)" "$SHA"

reset; echo ratelimit > "$G/pull"; rec 7 30 "$OTHER"
post "$SLUG" 7 "$SHA" MERGE; RC=$?
eq "T5 the record head is another sha: rc 3" "$RC" 3
eq "T5 no row" "$(rows)" 0
grep -q 'head moved' "$T/cli.err" && ok "T5 says head moved" || bad "T5 message: $(err)"

# ---- G1: GitHub answers, the record is not read --------------------------
reset; rec 7 30 "$OTHER"
post "$SLUG" 7 "$SHA" MERGE; RC=$?
eq "G1 GitHub 200: rc 0" "$RC" 0
eq "G1 GitHub 200: 0 GET /api/pr-records" "$(recreads)" 0

# ---- N: the record is not used ----------------------------------------------
# neg <label> <die-line pattern> — post once, assert rc 1, no row, no status
neg() {
  post "$SLUG" 7 "$SHA" MERGE; local rc=$?
  eq "$1: rc 1" "$rc" 1
  eq "$1: no verdict row" "$(rows)" 0
  eq "$1: no status" "$(statuses)" 0
  grep -qF -- "$2" "$T/cli.err" && ok "$1: the die line names '$2'" || bad "$1: die line lacks '$2': $(err)"
}
reset; echo none > "$G/pull"; rec 7 30 "$SHA"; neg "N1 network (no status line)" "gh_rest rc 75, network"
eq "N1 a network failure does not read the record" "$(recreads)" 0
reset; echo 401 > "$G/pull"; rec 7 30 "$SHA"; neg "N2 401" "gh_rest rc 75, auth"
reset; echo 404 > "$G/pull"; rec 7 30 "$SHA"; neg "N3 404" "gh_rest rc 44"
reset; echo perm > "$G/pull"; rec 7 30 "$SHA"; neg "N4 403 Resource not accessible (not a rate limit)" "gh_rest rc 75"
eq "N4 the record is not read for a permission 403" "$(recreads)" 0
reset; echo ratelimit > "$G/pull"; rec 7 901 "$SHA"; neg "N5 rate limit + a 901 s record" "record: age 901s > 900s"
reset; echo ratelimit > "$G/pull"; neg "N6 rate limit + no row" "record: no row"
reset; echo ratelimit > "$G/pull"; rec 7 30 "$SHA"; : > "$W/rec-down"; neg "N7 rate limit + the record read fails" "record: no row"
reset; echo ratelimit > "$G/pull"; rec 7 30 null; neg "N8 rate limit + a null head_sha" "record: no 40-hex head_sha"
reset; echo ratelimit > "$G/pull"; rec 7 30 "${SHA:0:12}"; neg "N9 rate limit + a 12-char head_sha" "record: no 40-hex head_sha"
reset; echo ratelimit > "$G/pull"; rec 7 30 "$SHA"
PR_RECORD_HEAD_FALLBACK_MAX_AGE_S=0 neg "N10 rate limit + knob 0" "record: PR_RECORD_HEAD_FALLBACK_MAX_AGE_S=0"
eq "N10 knob 0 does not read the record" "$(recreads)" 0

# ---- P: pr_record_peek and the knob, on their own -----------------------------
reset; rec 9 12 "$SHA"
peek() { ( . "$H/bin/jobs-client.sh" >/dev/null 2>&1; . "$H/bin/lib/pr-record.sh"; pr_record_peek "$@" ) 2>/dev/null; }
OUT=$(peek "$SLUG" 9); RC=$?
eq "P1 a row: rc 0" "$RC" 0
eq "P1 a row: prints head_sha and age_s" "$(jq -r '"\(.head_sha) \(.age_s)"' <<<"$OUT" 2>/dev/null)" "$SHA 12"
[ -f "$H/logs/pr-record.log" ] && bad "P1 a hit writes no pr-record.log line" || ok "P1 a hit writes no pr-record.log line"
OUT=$(peek "$SLUG" 10); RC=$?
eq "P2 no row: rc 1, nothing printed" "$RC:$OUT" "1:"
grep -q 'peek example-org/demo-os#10 miss=unknown' "$H/logs/pr-record.log" 2>/dev/null && ok "P2 one miss=unknown line" \
  || bad "P2 no miss=unknown line: $(cat "$H/logs/pr-record.log" 2>/dev/null)"
: > "$W/rec-down"; OUT=$(peek "$SLUG" 9); RC=$?
eq "P3 a failed read: rc 1, nothing printed" "$RC:$OUT" "1:"
grep -q 'peek example-org/demo-os#9 miss=unreadable' "$H/logs/pr-record.log" 2>/dev/null && ok "P3 one miss=unreadable line" \
  || bad "P3 no miss=unreadable line: $(cat "$H/logs/pr-record.log" 2>/dev/null)"
rm -f "$W/rec-reads"; OUT=$(peek "not a slug" 9); RC=$?
eq "P3 bad args: rc 1" "$RC" 1
eq "P3 bad args: no request" "$(recreads)" 0
eq "P3 0 gh calls in every peek" "$(grep -c . "$G/calls" 2>/dev/null || echo 0)" 0
knob() { ( . "$H/bin/lib/pr-record.sh"; pr_record_head_fallback_max_age ) 2>/dev/null; }
eq "P3 knob default 900" "$(knob)" 900
eq "P3 knob an explicit 120" "$(PR_RECORD_HEAD_FALLBACK_MAX_AGE_S=120 knob)" 120
eq "P3 knob abc reads as 900" "$(PR_RECORD_HEAD_FALLBACK_MAX_AGE_S=abc knob)" 900
grep -q "PR_RECORD_HEAD_FALLBACK_MAX_AGE_S='abc'" "$H/logs/pr-record.log" 2>/dev/null \
  && ok "P3 one log line names the bad value" || bad "P3 no log line for abc"

# ---- L1: the land lane posts the verdict under the 403 ------------------------
reset; echo ratelimit > "$G/pull"; rec 7 30 "$SHA"
echo box-hub > "$H/state/box-name"
jq -nc --arg h "$SHA" --arg c "$(date -u -d '-30 minutes' +%Y-%m-%dT%H:%M:%SZ)" \
  '{requests:[{id:"lr-1", repo:"example-org/demo-os", pr:7, head_sha:$h, status:"done", verdict:"MERGE",
     reviewer_model:"stub-model", report_ref:"state/lead-reviews/lr-7.md", promoted_verdict_at:null,
     detail:null, created_at:$c, updated_at:$c}], truncated:false}' > "$W/requests.json"
( cd "$T" && bash "$H/bin/lead-review-land.sh" ) > "$T/land.out" 2>&1; RC=$?
eq "L1 the land tick rc 0 ($(tr '\n' ' ' < "$T/land.out" | head -c 300))" "$RC" 0
eq "L1 one POST /api/verdicts" "$(rows)" 1
eq "L1 the row is source=lead on the review sha" "$(jq -r '"\(.source) \(.head_sha)"' "$W/posted" 2>/dev/null)" "lead $SHA"
grep -q 'lead review lr-1: MERGE posted as a source=lead row' "$H/logs/lead-review-land.log" 2>/dev/null \
  && ok "L1 the land log says posted as a source=lead row" \
  || bad "L1 the land log lacks the posted line: $(tail -5 "$H/logs/lead-review-land.log" 2>/dev/null)"

echo "lead-verdict-record-head.bh-8334: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
