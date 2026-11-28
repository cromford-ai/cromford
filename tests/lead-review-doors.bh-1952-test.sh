#!/bin/bash
# tests/lead-review-doors.bh-1952-test.sh — BH-1952 (BH-1525.4): the three shell
# doors that request a lead review, driven through their REAL entry points with
# only curl (and gh, which must never be called) stubbed:
#   * bin/lead-verdict.sh request posts ONE request to $JOBS_URL/api/lead-reviews
#     (no trailing slash), the lead token only in a 0600 header file, never on
#     argv; the sha is required, 40-hex, never looked up (short/missing = rc 2,
#     no call); a worker 409/403 is printed verbatim and is rc 1;
#   * bin/lead-verdict.sh list [repo] reads /api/lead-reviews, rc 75 = the
#     routes are not deployed;
#   * bin/harness-ctl.sh review execs that request;
#   * the poll-commands `lead_review` arm validates repo (fleet.conf), pr and sha
#     before any call, and acks OK=true only on a 2xx.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-doors.bh-1952-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SHA=abcdef0123456789abcdef0123456789abcdef01
SHA_UP=ABCDEF0123456789ABCDEF0123456789ABCDEF01
SLUG=example-org/cromford

# A scratch harness carrying the real scripts under test and their libs.
H="$T/h"; mkdir -p "$H/bin/lib/jobs" "$T/fakebin" "$T/log" "$T/tmp"
cp "$DIR/bin/lead-verdict.sh" "$DIR/bin/harness-ctl.sh" "$DIR/bin/jobs-client.sh" "$H/bin/"
cp "$DIR"/bin/lib/*.sh "$H/bin/lib/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cat > "$H/bin/fleet-conf.sh" <<'CONF'
#!/bin/bash
case "$1" in
  --projects) printf 'cromford\nproject-3\n' ;;
  cromford) echo example-org/cromford ;;
  project-3) echo example-org/project-3 ;;
esac
CONF
chmod +x "$H/bin/fleet-conf.sh"

# The stub curl: argv one per line into $T/log/argv ("----" between calls), the
# -H @file content and mode captured, POST bodies into $T/log/posted, and the
# answer from $T/answer ("<code>\n<body>"). $T/slow makes it sleep first.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$@" >> "$T/log/argv"; echo ---- >> "$T/log/argv"
prev=""; post=0; body=""
for a in "\$@"; do
  # TEST-CHANGE (BH-9946): jobs calls now pass the bearer on a curl fd
  # (-H @/dev/fd/3); skip it so only the lead-verdict header file is captured.
  if [ "\$prev" = -H ]; then case "\$a" in @/dev/fd/*) ;; @*)
    f="\${a#@}"; cat "\$f" > "$T/log/hdr"; stat -c %a "\$f" > "$T/log/hdr-mode"; printf '%s' "\$f" > "$T/log/hdr-path" ;;
  esac; fi
  [ "\$prev" = -X ] && [ "\$a" = POST ] && post=1
  [ "\$prev" = --data-binary ] && body="\$a"
  prev="\$a"
done
# BH-4956: a stored request is followed by the nudge's gate event and doorbell
# POSTs; they are not the request door this suite counts.
case "\$*" in *"/api/pr-state-events"*|*"/api/wakes/lane"*) post=0 ;; esac
[ "\$post" = 1 ] && { printf '%s\n' "\$body" >> "$T/log/posted"; echo x >> "$T/log/posts"; }
[ -f "$T/slow" ] && sleep 1
code=\$(head -1 "$T/answer"); resp=\$(tail -n +2 "$T/answer")
printf '%s\n%s' "\$resp" "\$code"
EOF
chmod +x "$T/fakebin/curl"
printf '#!/bin/bash\necho called >> "%s/log/gh"\nexit 1\n' "$T" > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"

TOKF="$T/tok"; printf 'tok-SECRET-9\n' > "$TOKF"; chmod 600 "$TOKF"
export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 JOBS_BOX=testbox TMPDIR="$T/tmp" LEAD_VERDICT_TOKEN_FILE="$TOKF"

answer() { printf '%s\n%s' "$1" "$2" > "$T/answer"; }
reset()  { rm -f "$T/log"/* "$T/slow"; }
posts()  { [ -f "$T/log/posts" ] && grep -c . "$T/log/posts" || echo 0; }
calls()  { [ -f "$T/log/argv" ] && grep -c '^----$' "$T/log/argv" || echo 0; }
lv()     { bash "$H/bin/lead-verdict.sh" "$@" > "$T/out" 2> "$T/err"; RC=$?; }
REQ_OK='{"request":{"id":31,"repo":"example-org/cromford","pr":12,"head_sha":"'"$SHA"'","status":"requested"}}'

# cli-1: the POST goes to /api/lead-reviews exactly, and the id is printed.
reset; answer 201 "$REQ_OK"
lv request "$SLUG" 12 "$SHA_UP"
[ "$RC" = 0 ] && ok || bad "cli-1: a 201 must be rc 0 (got $RC): $(cat "$T/out" "$T/err")"
[ "$(posts)" = 1 ] && ok || bad "cli-1: exactly one POST (got $(posts))"
grep -qx 'https://jobs.test/api/lead-reviews' "$T/log/argv" && ok || bad "cli-1: URL must be \$JOBS_URL/api/lead-reviews: $(grep jobs.test "$T/log/argv")"
grep -q "requested lead review #31 on $SLUG#12 @ ${SHA:0:12} (requested)" "$T/out" && ok || bad "cli-1: success line: $(cat "$T/out")"
B=$(head -1 "$T/log/posted")
[ "$(jq -r .head_sha <<<"$B")" = "$SHA" ] && ok || bad "cli-1: the sha must be lowercased, as given: $B"
[ "$(jq -r '.pr|type' <<<"$B")" = number ] && [ "$(jq -r .repo <<<"$B")" = "$SLUG" ] && ok || bad "cli-1: repo/pr in body: $B"
[ "$(jq -r .requested_by <<<"$B")" = testbox ] && ok || bad "cli-1: requested_by must be JOBS_BOX: $B"
jq -e 'has("scope_notes")|not' <<<"$B" >/dev/null && ok || bad "cli-1: no notes given means no scope_notes key: $B"

# cli-2: the token rides only in the 0600 header file, never argv, and the file is gone.
grep -q 'tok-SECRET-9' "$T/log/argv" && bad "cli-2: the lead token reached curl argv" || ok
grep -q '^x-lead-verdict-token: tok-SECRET-9$' "$T/log/hdr" && ok || bad "cli-2: the header file must carry the lead token"
[ "$(cat "$T/log/hdr-mode")" = 600 ] && ok || bad "cli-2: header file mode $(cat "$T/log/hdr-mode"), want 600"
[ -e "$(cat "$T/log/hdr-path")" ] && bad "cli-2: header file left behind" || ok
reset; answer 201 "$REQ_OK"; touch "$T/slow"
bash "$H/bin/lead-verdict.sh" request "$SLUG" 12 "$SHA" >/dev/null 2>&1 & BG=$!
PS=""; for _ in 1 2 3 4 5 6 7 8; do sleep 0.1; PS="$PS$(ps -eo args= 2>/dev/null)"; done
wait "$BG"
grep -q 'jobs.test/api/lead-reviews' <<<"$PS" && ok || bad "cli-2: the ps sample never saw the slow curl, so it proves nothing"
grep -q 'tok-SECRET-9' <<<"$PS" && bad "cli-2: the lead token is visible in ps during the call" || ok

# cli-3 / cli-4: missing or short sha = rc 2, no call, gh never asked.
reset; answer 201 "$REQ_OK"
lv request "$SLUG" 12
[ "$RC" = 2 ] && ok || bad "cli-3: a missing sha must be rc 2 (got $RC)"
[ "$(calls)" = 0 ] && ok || bad "cli-3: a missing sha must make no call"
reset; answer 201 "$REQ_OK"
lv request "$SLUG" 12 "${SHA:0:39}"
[ "$RC" = 2 ] && ok || bad "cli-4: a 39-hex sha must be rc 2 (got $RC): $(cat "$T/err")"
[ "$(calls)" = 0 ] && ok || bad "cli-4: a short sha must make no call"
grep -q 'head-sha' "$T/err" && ok || bad "cli-4: the refusal names head-sha: $(cat "$T/err")"
reset; lv request "$SLUG" 12 "${SHA:0:39}g"
[ "$RC" = 2 ] && [ "$(calls)" = 0 ] && ok || bad "cli-4: a non-hex 40-char sha must be rc 2 with no call (got $RC)"
[ -f "$T/log/gh" ] && bad "cli-3/4: gh was called to resolve a sha" || ok
reset; lv request 'not a repo' 12 "$SHA"
[ "$RC" = 1 ] && [ "$(calls)" = 0 ] && ok || bad "cli: a bad repo must be refused before any call (rc $RC)"

# cli-5: a 409 / 403 is printed verbatim and is rc 1.
reset; answer 409 '{"error":"already requested"}'
lv request "$SLUG" 12 "$SHA"
[ "$RC" = 1 ] && ok || bad "cli-5: a 409 must be rc 1 (got $RC)"
grep -q '{"error":"already requested"}' "$T/out" "$T/err" && ok || bad "cli-5: the worker body verbatim: $(cat "$T/out" "$T/err")"
grep -q 'HTTP 409' "$T/err" && ok || bad "cli-5: HTTP 409 on stderr: $(cat "$T/err")"
[ "$(posts)" = 1 ] && ok || bad "cli-5: a 409 is not retried (posts $(posts))"
reset; answer 403 '{"error":"lead token required"}'
lv request "$SLUG" 12 "$SHA"
[ "$RC" = 1 ] && grep -q 'lead token required' "$T/out" "$T/err" && grep -q 'HTTP 403' "$T/err" && ok \
  || bad "cli-5: a 403 must be rc 1 with its body and HTTP 403 (rc $RC): $(cat "$T/out" "$T/err")"

# cli-6: --notes and --prior reach the body, notes with quotes/newlines intact.
reset; answer 201 "$REQ_OK"
NOTE=$'look at "the gate"\nand the lock'
lv request "$SLUG" 12 "$SHA" --notes "$NOTE" --prior verdict-7
[ "$RC" = 0 ] && ok || bad "cli-6: rc $RC: $(cat "$T/err")"
B=$(cat "$T/log/posted")
[ "$(jq -r .scope_notes <<<"$B")" = "$NOTE" ] && ok || bad "cli-6: scope_notes: $B"
[ "$(jq -r .prior_verdict_ref <<<"$B")" = verdict-7 ] && ok || bad "cli-6: prior_verdict_ref: $B"
reset; lv request "$SLUG" 12 "$SHA" --bogus x
[ "$RC" = 2 ] && [ "$(calls)" = 0 ] && ok || bad "cli-6: an unknown option is usage (rc $RC)"

# cli-7: list reads /api/lead-reviews[?repo=], prints rows; rc 75 names the missing routes.
reset; answer 200 '{"requests":[{"id":31,"created_at":"2026-09-24T14:00:00Z","repo":"example-org/x","pr":12,"head_sha":"'"$SHA"'","status":"requested"}],"truncated":true}'
lv list example-org/x
[ "$RC" = 0 ] && ok || bad "cli-7: list rc $RC: $(cat "$T/err")"
grep -qx 'https://jobs.test/api/lead-reviews?repo=example-org/x' "$T/log/argv" && ok || bad "cli-7: list URL: $(grep jobs.test "$T/log/argv")"
grep -q "^#31	2026-09-24T14:00:00Z	example-org/x#12	${SHA:0:12}	requested$" "$T/out" && ok || bad "cli-7: row line: $(cat "$T/out")"
grep -qx '(truncated)' "$T/out" && ok || bad "cli-7: truncated marker"
reset; answer 200 '{"requests":[],"truncated":false}'
lv list
grep -qx 'https://jobs.test/api/lead-reviews' "$T/log/argv" && [ "$RC" = 0 ] && ok || bad "cli-7: list with no repo: rc $RC $(grep jobs.test "$T/log/argv")"
reset; answer 404 '{"error":"unknown endpoint","worker":"harness-jobs"}'
lv list
[ "$RC" = 1 ] && grep -q 'not deployed on https://jobs.test' "$T/err" && ok || bad "cli-7: rc 75 must say the routes are not deployed (rc $RC): $(cat "$T/err")"
reset; answer 500 '{"error":"boom"}'
lv list
[ "$RC" = 1 ] && grep -q boom "$T/out" "$T/err" && ok || bad "cli-7: a 500 prints its body, rc 1 (rc $RC)"
reset; lv list 'bad repo'
[ "$RC" = 1 ] && [ "$(calls)" = 0 ] && ok || bad "cli-7: a bad repo filter is refused before any call"

# ctl-1: the real harness-ctl.sh review is the same request.
reset; answer 201 "$REQ_OK"
bash "$H/bin/harness-ctl.sh" review "$SLUG" 12 "$SHA" > "$T/out" 2> "$T/err"; RC=$?
[ "$RC" = 0 ] && ok || bad "ctl-1: rc $RC: $(cat "$T/out" "$T/err")"
[ "$(posts)" = 1 ] && grep -qx 'https://jobs.test/api/lead-reviews' "$T/log/argv" && ok || bad "ctl-1: exactly one POST to /api/lead-reviews (posts $(posts))"
grep -q '^-H$' "$T/log/argv" && grep -q '^@' "$T/log/argv" && grep -q '^x-lead-verdict-token: tok-SECRET-9$' "$T/log/hdr" && ok \
  || bad "ctl-1: the POST carries -H @<file> with the lead token"
grep -q 'requested lead review #31' "$T/out" && ok || bad "ctl-1: the request's own line: $(cat "$T/out")"
bash "$H/bin/harness-ctl.sh" nope >/dev/null 2> "$T/err"
grep -q 'review' "$T/err" && ok || bad "ctl-1: the unknown-verb list names review: $(cat "$T/err")"

# ---- poll-commands lead_review arm, extracted by its markers ----
extract() {
  awk -v n="$1" '
    $0 ~ "^    # >>> " n " handler" {f=1; next}
    $0 ~ "^    # <<< " n " handler" {exit}
    f {print}' "$DIR/bin/poll-commands.sh"
}
extract lead_review > "$T/lr.arm"
# poll-4: the markers exist and the arm talks to the jobs worker only.
[ -s "$T/lr.arm" ] && ok || { bad "poll-4: could not extract the lead_review handler — markers missing?"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }
grep -q 'CONSOLE_URL' "$T/lr.arm" && bad "poll-4: the arm must not call the console" || ok
{ echo 'case "$TYPE" in'; cat "$T/lr.arm"; echo 'esac'; } > "$T/lr.body"
poll() { # poll <payload-json>
  TYPE=lead_review ID=c1 PROJECT=cromford PAYLOAD="$1" OK=false RESULT="" \
    bash -c 'set -uo pipefail; . "$0"; echo "OK=$OK"; echo "RESULT=$RESULT"' "$T/lr.body" > "$T/out" 2> "$T/err"
}
# poll-1: a valid payload is one POST and OK=true.
reset; answer 201 "$REQ_OK"
poll "{\"repo\":\"$SLUG\",\"pr\":12,\"head_sha\":\"$SHA_UP\",\"notes\":\"two words\"}"
grep -qx 'OK=true' "$T/out" && ok || bad "poll-1: a 201 must ack OK=true: $(cat "$T/out" "$T/err")"
[ "$(posts)" = 1 ] && ok || bad "poll-1: exactly one POST (got $(posts))"
grep -q 'RESULT=requested lead review #31' "$T/out" && ok || bad "poll-1: RESULT is the request's line: $(cat "$T/out")"
[ "$(jq -r .scope_notes "$T/log/posted" 2>/dev/null)" = "two words" ] && ok || bad "poll-1: notes stay one argument: $(cat "$T/log/posted")"
[ "$(jq -r .head_sha "$T/log/posted" 2>/dev/null)" = "$SHA" ] && ok || bad "poll-1: sha lowercased"
# poll-2: every refused payload makes no call and names its field.
for case in \
  "sha|{\"repo\":\"$SLUG\",\"pr\":12,\"head_sha\":\"${SHA:0:39}\"}" \
  "sha|{\"repo\":\"$SLUG\",\"pr\":12,\"head_sha\":\"${SHA}0\"}" \
  "sha|{\"repo\":\"$SLUG\",\"pr\":12,\"head_sha\":\"${SHA:0:39}g\"}" \
  "sha|{\"repo\":\"$SLUG\",\"pr\":12,\"head_sha\":null}" \
  "sha|{\"repo\":\"$SLUG\",\"pr\":12}" \
  "repo|{\"repo\":\"someone/else\",\"pr\":12,\"head_sha\":\"$SHA\"}" \
  "repo|{\"repo\":\"example-org/cromford/../x\",\"pr\":12,\"head_sha\":\"$SHA\"}" \
  "repo|{\"pr\":12,\"head_sha\":\"$SHA\"}" \
  "pr|{\"repo\":\"$SLUG\",\"pr\":0,\"head_sha\":\"$SHA\"}" \
  "pr|{\"repo\":\"$SLUG\",\"pr\":-1,\"head_sha\":\"$SHA\"}" \
  "pr|{\"repo\":\"$SLUG\",\"pr\":\"12abc\",\"head_sha\":\"$SHA\"}"; do
  field="${case%%|*}"; p="${case#*|}"
  reset; answer 201 "$REQ_OK"; poll "$p"
  grep -qx 'OK=false' "$T/out" && [ "$(calls)" = 0 ] && grep -q "RESULT=refused: .*$field" "$T/out" && ok \
    || bad "poll-2: $p must be OK=false, no call, refused naming $field: $(cat "$T/out") calls=$(calls)"
done
# poll-3: a worker 403 is OK=false with the worker's own text.
reset; answer 403 '{"error":"lead token required"}'
poll "{\"repo\":\"$SLUG\",\"pr\":12,\"head_sha\":\"$SHA\"}"
grep -qx 'OK=false' "$T/out" && ok || bad "poll-3: a 403 must be OK=false: $(cat "$T/out")"
grep -q 'RESULT=refused: .*lead token required' "$T/out" && grep -q 'HTTP 403' "$T/out" && ok || bad "poll-3: RESULT carries the worker text and HTTP 403: $(cat "$T/out")"
reset; answer 409 '{"error":"already requested"}'
poll "{\"repo\":\"$SLUG\",\"pr\":12,\"head_sha\":\"$SHA\"}"
grep -qx 'OK=false' "$T/out" && grep -q 'already requested' "$T/out" && [ "$(posts)" = 1 ] && ok || bad "poll-3: a 409 is OK=false, verbatim, not retried: $(cat "$T/out")"
# No token file on this box: honest failure, no POST.
reset; answer 201 "$REQ_OK"
LEAD_VERDICT_TOKEN_FILE="$T/none" poll "{\"repo\":\"$SLUG\",\"pr\":12,\"head_sha\":\"$SHA\"}"
grep -qx 'OK=false' "$T/out" && grep -q 'not readable' "$T/out" && [ "$(calls)" = 0 ] && ok || bad "poll: no token file must be OK=false naming it, no call: $(cat "$T/out")"

# ---- console door: console-ui/src/ui/PRVerdicts.js, named by path ----
# The screen is proved by console-ui/tests/pr-verdicts.bh-1952.test.js in the
# console-ui job. This names the module for the impact lane and drives its
# request flow when console-ui's deps are installed on this box.
PRV="$DIR/console-ui/src/ui/PRVerdicts.js"
[ -f "$PRV" ] && ok || bad "missing $PRV"
if command -v node >/dev/null 2>&1 && [ -d "$DIR/console-ui/node_modules/htm" ]; then
  OUT=$(node --input-type=module -e "
import { liveHeadOf, requestLeadReview } from '$PRV';
const sent = [];
const base = { action: async (p) => { sent.push(p); return { command_id: 5 }; }, project: 'cromford', repo: '$SLUG', pr: 12 };
const short = await requestLeadReview({ ...base, confirm: async () => true, headSha: liveHeadOf({ head_sha: 'abc123' }) });
const no = await requestLeadReview({ ...base, confirm: async () => false, headSha: '$SHA' });
const yes = await requestLeadReview({ ...base, confirm: async () => true, headSha: liveHeadOf({ head_sha: '$SHA_UP' }) });
console.log(JSON.stringify({ short, no, yes, sent }));" 2>&1)
  [ "$(jq -c .short <<<"$OUT" 2>/dev/null)" = null ] && ok || bad "console: a short head must ask nothing: $OUT"
  [ "$(jq -c .no <<<"$OUT" 2>/dev/null)" = '{"sent":false}' ] && ok || bad "console: cancel sends nothing: $OUT"
  [ "$(jq -c '.sent' <<<"$OUT" 2>/dev/null)" = "[{\"type\":\"lead_review\",\"project\":\"cromford\",\"repo\":\"$SLUG\",\"pr\":12,\"head_sha\":\"$SHA\"}]" ] && ok \
    || bad "console: confirm sends exactly one lead_review command with the lowercased head: $OUT"
else
  echo "console door: SKIPPED — node or console-ui/node_modules missing on this box (console-ui/tests/pr-verdicts.bh-1952.test.js covers it)"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
