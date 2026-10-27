#!/bin/bash
# tests/unblock-reset-notes.bh-8512-test.sh — BH-8512: the lead re-request
# after an empty BLOCK carries its note on the reset, not on a request the
# UNIQUE(repo, pr, head_sha) key answers 409.
#
#   L1-L5  bin/lead-verdict.sh reset [--notes <text>] over a stub curl (the
#          REAL script and bin/lib/lead-reviews.sh): the body, the tier-token
#          neutralizing, the exit codes 0/3/2 by the worker's `notes` answer.
#   U1-U5  bin/lib/unblock/act.sh lead_rerequest in act mode (the REAL lib,
#          a stub bin/lead-verdict.sh): the note rides the reset, no request
#          goes out after a reset, request_id none still sends the request.
#
# Every case has its own scratch dir. 0 network calls: curl and gh are stubs.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/unblock-reset-notes.bh-8512-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
no() { FAIL=$((FAIL + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '     %s\n' "${2:0:1500}"; return 0; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want '$3' got '$2'"; fi; }

R=example-org/cromford
NOTE='write each finding as a - [BLOCK <class>] line'

# ═════ L: bin/lead-verdict.sh reset --notes ══════════════════════════════════
L="$T/lv"; mkdir -p "$L/h" "$L/fakebin" "$L/tmp"
scratch_install_closure bin/lead-verdict.sh "$L/h" >/dev/null || { echo "FAIL: closure install (lead-verdict)"; exit 1; }
scratch_install_closure bin/jobs-client.sh "$L/h" >/dev/null || { echo "FAIL: closure install (jobs-client)"; exit 1; }
printf 'lead-test-token\n' > "$L/token"; chmod 600 "$L/token"
# The stub worker: logs `<path> <body>` per POST, answers $L/answer (200).
cat > "$L/fakebin/curl" <<'EOF'
#!/bin/bash
body=""; url=""; prev=""
for a in "$@"; do
  [ "$prev" = --data-binary ] && body="$a"
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
printf '%s %s\n' "${url#https://jobs.test}" "$body" >> "$LV_DIR/worker.log"
cat "$LV_DIR/answer"; printf '\n200'
EOF
chmod +x "$L/fakebin/curl"
lv() { # lv <case> <answer-json> <args...> -> RC, OUT, ERR, BODY
  local c="$1" a="$2"; shift 2
  : > "$L/worker.log"; printf '%s' "$a" > "$L/answer"
  OUT=$(env PATH="$L/fakebin:$PATH" LV_DIR="$L" HARNESS="$L/h" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
        JOBS_RETRIES=0 TMPDIR="$L/tmp" LEAD_VERDICT_TOKEN_FILE="$L/token" \
        bash "$L/h/bin/lead-verdict.sh" reset "$@" 2>"$L/err.$c"); RC=$?
  ERR=$(cat "$L/err.$c")
  BODY=$(sed -n 's#^/api/lead-reviews/lr-1/reset ##p' "$L/worker.log")
}
RESET_OK='{"request":{"id":"lr-1","status":"requested","reset_count":1}}'
with_notes() { jq -c --arg s "$1" '. + {notes: $s}' <<< "$RESET_OK"; }

lv l1 "$RESET_OK" lr-1
check "L1 no --notes: the body is {} exactly, rc 0" "$RC $BODY" "0 {}"
lv l1b "$(with_notes stored)" lr-1 --notes x
check "L1 --notes x: the body is {\"append_notes\":\"x\"}" "$BODY" '{"append_notes":"x"}'

lv l2 "$(with_notes stored)" lr-1 --notes "$NOTE"
check "L2 answer notes stored: rc 0" "$RC" 0
case "$OUT" in *"reset_count 1"*"notes stored"*) ok "L2 the output names notes stored" ;; *) no "L2 the output names notes stored" "$OUT" ;; esac
check "L2 the body carries the note" "$(jq -r .append_notes <<< "$BODY")" "$NOTE"
lv l2b "$(with_notes present)" lr-1 --notes "$NOTE"
check "L2b answer notes present: rc 0" "$RC" 0

lv l3 "$(with_notes stored)" lr-1 --notes "a review-tier:high review-mode:full b"
check "L3 the tier and mode tokens are neutralized" "$(jq -r .append_notes <<< "$BODY")" "a review-tier=high review-mode=full b"

lv l4 "$(with_notes no-room)" lr-1 --notes "$NOTE"
check "L4 answer notes no-room: rc 3" "$RC" 3
case "$ERR" in *"not stored"*) ok "L4 one stderr line says the notes were not stored" ;; *) no "L4 one stderr line says the notes were not stored" "$ERR" ;; esac

lv l5 "$RESET_OK" lr-1 --notes "$NOTE"
check "L5 a 200 with no notes field (old worker): rc 3" "$RC" 3
lv l5b "$RESET_OK" lr-1 --bogus x
check "L5 --bogus x: rc 2, no POST" "$RC $(grep -c . "$L/worker.log")" "2 0"
lv l5c "$RESET_OK" lr-1 --notes
check "L5 --notes with no value: rc 2, no POST" "$RC $(grep -c . "$L/worker.log")" "2 0"

# ═════ U: act.sh lead_rerequest ══════════════════════════════════════════════
mkdir -p "$T/pathbin"
cat > "$T/pathbin/gh" <<'SH'
#!/bin/bash
m=GET; p=; hdr=0
while [ $# -gt 0 ]; do
  case "$1" in api) ;; -i) hdr=1 ;; -X) m="$2"; shift ;; -H|--input|-F|-f) shift ;; *) p="$1" ;; esac
  shift
done
echo "$m $p" >> "$GH_LOG"
if [ "$m" != GET ]; then echo '{"message":"fixture: writes refused"}'; exit 1; fi
if jq -e --arg p "$p" '.gh | has($p)' "$GH_FX" >/dev/null; then
  [ "$hdr" = 1 ] && printf 'HTTP/2 200\r\ncontent-type: application/json\r\n\r\n'; jq -c --arg p "$p" '.gh[$p]' "$GH_FX"; exit 0
fi
[ "$hdr" = 1 ] && printf 'HTTP/2 404\r\ncontent-type: application/json\r\n\r\n'; echo '{"message":"Not Found"}'; exit 1
SH
for s in claude agent-call.sh curl; do printf '#!/bin/bash\necho "%s $*" >> "$MODEL_LOG"\nexit 7\n' "$s" > "$T/pathbin/$s"; done
chmod +x "$T/pathbin/"*

H42=$(printf '4%.0s' $(seq 40))
# newact <case>: a scratch $HARNESS whose bin/lead-verdict.sh logs each call
# and answers stub/lv-<verb>.rc (default 0) with stub/lv-<verb>.err on stderr.
newact() {
  export HARNESS="$T/u-$1" CALLS="$T/u-$1/calls.txt"
  mkdir -p "$HARNESS/bin" "$HARNESS/logs" "$HARNESS/stub"
  : > "$CALLS"
  cat > "$HARNESS/bin/lead-verdict.sh" <<'EOF'
#!/bin/bash
echo "lead-verdict $*" >> "$CALLS"
s="$HARNESS/stub/lv-$1"
[ -f "$s.err" ] && cat "$s.err" >&2
[ -f "$s.rc" ] && exit "$(cat "$s.rc")"
exit 0
EOF
  printf '#!/bin/bash\n[ "$1" = setting-get ] && { echo act; exit 0; }\nexit 2\n' > "$HARNESS/bin/jobs-client.sh"
  printf '#!/bin/bash\nexit 0\n' > "$HARNESS/bin/lane-alert.sh"
  chmod +x "$HARNESS/bin/"*.sh
  cat > "$HARNESS/fx.json" <<EOF
{"gh": {"repos/$R/pulls/42": {"head": {"sha": "$H42"}},
        "repos/$R/issues/42/comments?per_page=100&page=1": [],
        "repos/$R/pulls/42/reviews?per_page=100&page=1": []}}
EOF
  export GH_FX="$HARNESS/fx.json" GH_LOG="$HARNESS/gh.log" MODEL_LOG="$HARNESS/model.log" UNBLOCK_ACT=1
  : > "$GH_LOG"; : > "$MODEL_LOG"
}
mkd() { # mkd <case> <args-json> -> one lead_rerequest decision for PR 42
  jq -nc --arg k "k-8512-$1" --argjson a "$2" --arg s "$R" --arg h "$H42" \
    '{decision_key: $k, project: "cromford", repo: $s, subject_kind: "pr", subject: ($s + "#42"), pr: 42, head: $h,
      rule_id: "U13-EMPTY", class: "review-rerequest", cites: ["G21"], action: {name: "lead_rerequest", args: $a}}'
}
nc() { grep -c -- "$1" "$CALLS"; }
(
  PASS=0; FAIL=0; PATH="$T/pathbin:$PATH"
  . "$SRC/bin/lib/unblock/act.sh" || exit 9
  A_RESET=$(jq -nc --arg n "$NOTE" '{request_id: "91325b08-2165", priority: 900, notes: $n}')

  newact u1
  ub_act "$(mkd u1 "$A_RESET")" >/dev/null; rc=$?
  check "U1 a reset row: done reset" "$rc $UB_ACT_OUTCOME $UB_ACT_DETAIL" "0 done reset"
  check "U1 exactly one reset, carrying --notes" "$(grep -c -x -F "lead-verdict reset 91325b08-2165 --notes $NOTE" "$CALLS") $(nc '^lead-verdict reset')" "1 1"
  check "U1 0 request calls after the reset (no 409 path)" "$(nc '^lead-verdict request')" 0

  newact u2
  ub_act "$(mkd u2 "$(jq -c '.request_id = "none"' <<< "$A_RESET")")" >/dev/null; rc=$?
  check "U2 request_id none: done requested" "$rc $UB_ACT_OUTCOME $UB_ACT_DETAIL" "0 done requested"
  check "U2 0 resets, 1 request with --priority 900 --notes" \
    "$(nc '^lead-verdict reset') $(grep -c -x -F "lead-verdict request $R 42 $H42 --priority 900 --notes $NOTE" "$CALLS")" "0 1"

  newact u3; echo 3 > "$HARNESS/stub/lv-reset.rc"
  ub_act "$(mkd u3 "$A_RESET")" >/dev/null; rc=$?
  check "U3 reset rc 3: failed notes-not-stored after reset" "$rc $UB_ACT_OUTCOME $UB_ACT_DETAIL" "0 failed notes-not-stored after reset"
  check "U3 0 requests" "$(nc '^lead-verdict request')" 0

  newact u4; echo 1 > "$HARNESS/stub/lv-request.rc"; echo 'lead-verdict: HTTP 409 a request is open' > "$HARNESS/stub/lv-request.err"
  ub_act "$(mkd u4 "$A_RESET")" >/dev/null; rc=$?
  check "U4 reset rc 0, request would be 409: still done reset, request never called" \
    "$rc $UB_ACT_OUTCOME $UB_ACT_DETAIL $(nc '^lead-verdict request')" "0 done reset 0"

  newact u5; echo 1 > "$HARNESS/stub/lv-reset.rc"
  ub_act "$(mkd u5 "$A_RESET")" >/dev/null; rc=$?
  check "U5 reset rc 1: failed reset rc 1, 0 requests" "$rc $UB_ACT_OUTCOME $UB_ACT_DETAIL $(nc '^lead-verdict request')" "0 failed reset rc 1 0"

  newact u6
  ub_act "$(mkd u6 '{"request_id":"901","priority":50}')" >/dev/null; rc=$?
  check "U6 a reset with no notes: one bare reset, done reset" "$rc $UB_ACT_OUTCOME $UB_ACT_DETAIL $(grep -c -x 'lead-verdict reset 901' "$CALLS")" "0 done reset 1"

  check "B 0 non-GET gh calls, 0 model calls" "$(cat "$T"/u-*/gh.log | grep -vc '^GET ') $(cat "$T"/u-*/model.log | grep -c .)" "0 0"
  echo "$PASS $FAIL" > "$T/act-counts"
)
read -r ap af < "$T/act-counts" 2>/dev/null || { ap=0; af=1; echo "FAIL the act subshell did not finish"; }
PASS=$((PASS + ap)); FAIL=$((FAIL + af))

echo "unblock-reset-notes.bh-8512: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
