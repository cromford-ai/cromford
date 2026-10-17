#!/bin/bash
# tests/data-lane-pending-lib.bh-6467-test.sh — the decisions of
# bin/lib/data-lane-pending.sh (BH-6467), table-driven, no network.
#   D1-D3   data-lane-only review shapes -> dlp_only rc 0, prints the path
#   D4-D12  negatives -> rc 1; D13 an unreadable file -> rc 2
#   F1-F4   dlp_names_file: full path, basename, `.bak` and a stem do not match
#   P1-P9   dlp_probe against a stub curl: the word and the rc per case, and
#           the token never reaches the stub's argv
#   C1-C2   dlp_missing_comment posts once; a thread with the tag posts nothing
#   N1-N4   dlp_finish: ready + unlabel, a 404 label is success, a failed
#           ready is rc 1, a PR that is not a draft gets no ready call
#   Q1-Q7   dlp_probe_alert_line: a refused token pages at once; any other
#           unknown or a missing row pages only past the window after the
#           done comment; 0 turns the window off; one line per record;
#           Q8 an empty done time is not a time
#
# MUTATION (D1), run by hand in the build: make dlp_only return 0 always ->
# D4 red; make the probe skip the checksum compare -> P2 red.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

H="$T/h"
mkdir -p "$H/env" "$T/fakebin"
scratch_install_closure bin/lib/data-lane-pending.sh "$H" >/dev/null \
  || { echo "FAIL: closure install of bin/lib/data-lane-pending.sh"; exit 1; }
export HARNESS="$H"
# shellcheck disable=SC1091
. "$H/bin/lib/data-lane-pending.sh" || { echo "FAIL: the lib does not source"; exit 1; }

# ── dlp_only ─────────────────────────────────────────────────────────────────
r() { printf '%s\n' "$2" > "$T/$1.md"; printf '%s' "$T/$1.md"; }
only() { local o rc; o=$(dlp_only "$@" 2>/dev/null); rc=$?; printf '%s %s' "$rc" "$o"; }
P=prisma/sql/0087_x.sql
printf 'src/app.ts\n%s\n' "$P" > "$T/diff.txt"

R1=$(r d1 "## Findings

B1 migration $P not applied in prod — the RPC is called on every load.

DATA_LANE: $P
TIER: 2
VERDICT: BLOCK")
[ "$(only "$R1")" = "0 $P" ] && ok || bad "D1: plain data-lane-only BLOCK, got '$(only "$R1")'"
[ "$(only "$R1" "$T/diff.txt")" = "0 $P" ] && ok || bad "D1: with the diff list, got '$(only "$R1" "$T/diff.txt")'"
R2=$(r d2 "## B1 migration $P not applied in prod

DATA_LANE: $P
TIER: 2
VERDICT: BLOCK")
[ "$(only "$R2")" = "0 $P" ] && ok || bad "D2: heading-shaped B1, got '$(only "$R2")'"
R3=$(r d3 "B1 migration $P not applied in prod.
B2 the guard returns early on empty input.
TIER: 2
VERDICT: BLOCK

=== MERGED RE-REVIEW after the single fix round (head 5b35bacc) ===
B2 is fixed. B1 stands: migration $P not applied in prod.
DATA_LANE: $P
TIER: 2
VERDICT: BLOCK")
[ "$(only "$R3")" = "0 $P" ] && ok || bad "D3: data-lane-only final round over a code round, got '$(only "$R3")'"

R4=$(r d4 "B1 migration $P not applied in prod.
B2 the guard returns early on empty input.
DATA_LANE: $P
TIER: 2
VERDICT: BLOCK")
[ "$(only "$R4")" = "1 " ] && ok || bad "D4: a code BLOCK beside the data lane, got '$(only "$R4")'"
R5=$(r d5 "B1 migration $P not applied in prod.
NEEDS_HUMAN: set STRIPE_KEY in Vercel
DATA_LANE: $P
TIER: 2
VERDICT: BLOCK")
[ "$(only "$R5")" = "1 " ] && ok || bad "D5: a second human step (NEEDS_HUMAN), got '$(only "$R5")'"
R6=$(r d6 "B1 migration $P not applied in prod.
B2 migration prisma/sql/0088_y.sql not applied in prod.
DATA_LANE: $P
DATA_LANE: prisma/sql/0088_y.sql
TIER: 2
VERDICT: BLOCK")
[ "$(only "$R6")" = "1 " ] && ok || bad "D6: two DATA_LANE lines, got '$(only "$R6")'"
R7=$(r d7 "B1 migration scripts/migrations/0042.sql not applied in prod.
DATA_LANE: scripts/migrations/0042.sql
TIER: 2
VERDICT: BLOCK")
[ "$(only "$R7")" = "1 " ] && ok || bad "D7: a BH-4926 path, got '$(only "$R7")'"
R8=$(r d8 "B1 migration ../etc/x.sql not applied in prod.
DATA_LANE: ../etc/x.sql
TIER: 2
VERDICT: BLOCK")
[ "$(only "$R8")" = "1 " ] && ok || bad "D8: a path with .., got '$(only "$R8")'"
R9=$(r d9 "B1 migration $P not applied in prod.
DATA_LANE: $P
TIER: 2
VERDICT: BLOCK

=== MERGED RE-REVIEW after the single fix round (head 5b35bacc) ===
The DATA_LANE: $P step is done; nothing blocks.
TIER: 2
VERDICT: APPROVE")
[ "$(only "$R9")" = "1 " ] && ok || bad "D9: a final APPROVE whose prose names DATA_LANE, got '$(only "$R9")'"
R10=$(r d10 "B1 migration $P not applied in prod.
DATA_LANE: $P
TIER: 2
VERDICT: BLOCK

=== MERGED RE-REVIEW after the single fix round (head 5b35bacc) ===
B2 the guard returns early on empty input.
TIER: 2
VERDICT: BLOCK")
[ "$(only "$R10")" = "1 " ] && ok || bad "D10: the data-lane round is older than a code round, got '$(only "$R10")'"
R11=$(r d11 "B1 migration $P not applied in prod.
\`\`\`
DATA_LANE: $P
\`\`\`
TIER: 2
VERDICT: BLOCK")
[ "$(only "$R11")" = "1 " ] && ok || bad "D11: a DATA_LANE line inside a fence, got '$(only "$R11")'"
printf 'src/app.ts\n' > "$T/diff-other.txt"
[ "$(only "$R1" "$T/diff-other.txt")" = "1 " ] && ok || bad "D12: a path absent from the diff, got '$(only "$R1" "$T/diff-other.txt")'"
[ "$(only "$T/nope.md" | cut -c1)" = 2 ] && ok || bad "D13: an unreadable review is rc 2, got '$(only "$T/nope.md")'"

# ── dlp_names_file ──────────────────────────────────────────────────────────
nf() { dlp_names_file "$1" "$P" && echo yes || echo no; }
[ "$(nf "comment: u
HUMAN-STEP-DONE: applied $P in prod")" = yes ] && ok || bad "F1: the full path names the file"
[ "$(nf "HUMAN-STEP-DONE: applied 0087_x.sql to prod.")" = yes ] && ok || bad "F2: the basename names the file"
[ "$(nf "HUMAN-STEP-DONE: applied 0087_x.sql.bak")" = no ] && ok || bad "F3: 0087_x.sql.bak must not name 0087_x.sql"
[ "$(nf "HUMAN-STEP-DONE: applied 0087_x")" = no ] && ok || bad "F4: the stem alone must not name the file"

# ── dlp_probe ───────────────────────────────────────────────────────────────
# A repo whose HEAD holds the migration file.
G="$T/repo"
mkdir -p "$G/prisma/sql"
( cd "$G" && git init -q . && git config user.email t@t && git config user.name t \
  && printf 'CREATE FUNCTION fixture_fn() RETURNS int AS $$ SELECT 1 $$ LANGUAGE sql;\n' > "$P" \
  && git add -A && git commit -qm init ) >/dev/null 2>&1
HEADSHA=$(git -C "$G" rev-parse HEAD)
SUM=$(git -C "$G" show "$HEADSHA:$P" | sha256sum | cut -c1-64)
# The stub curl: argv to probe-argv.log, the body from probe-body, the code
# from probe-code, both written per case.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB/probe-argv.log"
out=""; prev=""
for a in "$@"; do [ "$prev" = -o ] && out="$a"; prev="$a"; done
[ -n "$out" ] && cat "$STUB/probe-body" > "$out"
printf '%s' "$(cat "$STUB/probe-code")"
EOF
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH" STUB="$T"
printf 'DATA_LANE_APP_BASE=https://app.example.test\nMIGRATION_TOKEN=tok-fixture-1\n' > "$H/env/tproj.env"
probe() { # probe <code> <body> -> "<rc> <first line>"
  printf '%s' "$1" > "$T/probe-code"; printf '%s' "$2" > "$T/probe-body"
  local o rc; o=$(dlp_probe tproj "$G" "$HEADSHA" "$P" 2>/dev/null); rc=$?
  printf '%s %s' "$rc" "$(printf '%s\n' "$o" | sed -n 1p)"
  printf '%s\n' "$o" > "$T/probe-out"
}
row() { jq -nc --arg f "$1" --arg c "$2" '{filename:$f, checksum:$c, appliedAt:"2026-10-15T10:00:00Z", actor:"fixture-operator"}'; }
OUT=$(probe 200 "{\"applied\":[$(row 0087_x.sql "$SUM")],\"pending\":[]}")
[ "$OUT" = "0 confirmed" ] && ok || bad "P1: same name + same sum is confirmed, got '$OUT'"
grep -q '^ledger: 0087_x.sql applied at 2026-10-15T10:00:00Z by fixture-operator$' "$T/probe-out" && ok || bad "P1: the detail line, got '$(cat "$T/probe-out")'"
OUT=$(probe 200 "{\"applied\":[$(row 0087_x.sql "$(printf '%064d' 7)")]}")
[ "$OUT" = "1 missing" ] && ok || bad "P2: same name + another sum is missing, got '$OUT'"
grep -q "^ledger: 0087_x.sql is applied at checksum 000000000000, the PR's file is ${SUM:0:12}$" "$T/probe-out" && ok || bad "P2: the detail, got '$(cat "$T/probe-out")'"
OUT=$(probe 200 "{\"applied\":[$(row 0086_w.sql "$SUM")]}")
[ "$OUT" = "1 missing" ] && ok || bad "P3: another name only is missing, got '$OUT'"
grep -q "^ledger: no schema_migration row for 0087_x.sql at sha256 ${SUM:0:12}$" "$T/probe-out" && ok || bad "P3: the detail, got '$(cat "$T/probe-out")'"
OUT=$(probe 200 '{"applied":[]}')
[ "$OUT" = "1 missing" ] && ok || bad "P4: an empty applied list is missing, got '$OUT'"
OUT=$(probe 500 '{"error":"boom"}')
[ "$OUT" = "75 unknown" ] && ok || bad "P5: a 500 is unknown, got '$OUT'"
OUT=$(probe 200 '<html><body>Maintenance</body></html>')
[ "$OUT" = "75 unknown" ] && ok || bad "P6: an HTML 200 is unknown, got '$OUT'"
OUT=$(probe 401 '{"error":"unauthorized"}')
[ "$OUT" = "75 unknown" ] && ok || bad "P7: a 401 is unknown, got '$OUT'"
grep -q 'token was refused' "$T/probe-out" && ok || bad "P7: a 401 says the token was refused, got '$(cat "$T/probe-out")'"
: > "$H/env/tproj.env"
N0=$(grep -c . "$T/probe-argv.log")
OUT=$(probe 200 '{"applied":[]}')
[ "$OUT" = "3 not-configured" ] && ok || bad "P8: no env is not-configured, got '$OUT'"
[ "$(grep -c . "$T/probe-argv.log")" = "$N0" ] && ok || bad "P8: not-configured makes no request"
printf 'DATA_LANE_APP_BASE=https://app.example.test\nMIGRATION_TOKEN=tok-fixture-1\n' > "$H/env/tproj.env"
OUT=$(printf '%s' 200 > "$T/probe-code"; dlp_probe tproj "$G" "$HEADSHA" prisma/sql/0099_absent.sql 2>/dev/null; echo "rc=$?")
[ "$(printf '%s\n' "$OUT" | sed -n '1p;$p' | tr '\n' ' ')" = "unknown rc=75 " ] && ok || bad "P9: a file absent at the head is unknown, got '$OUT'"
grep -q 'tok-fixture-1' "$T/probe-argv.log" && bad "P: the token reached curl's argv: $(cat "$T/probe-argv.log")" || ok
grep -q 'https://app.example.test/api/internal/migrations/status' "$T/probe-argv.log" && ok || bad "P: the status route was not asked: $(cat "$T/probe-argv.log")"

# ── dlp_missing_comment and dlp_finish (stub gh, REST envelope) ──────────────
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB/gh.log"
send() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "$2"; exit 0; }
if [ "$1 $2 $3" = "api -i -X" ]; then
  M="$4"; P="$5"; shift 5
  case "$M $P" in
    "POST repos/o/tproj/issues/87/comments")
      for a in "$@"; do case "$a" in body=@*) cat "${a#body=@}" > "$STUB/posted-body.txt" ;; esac; done
      send "$(cat "$STUB/st-comment" 2>/dev/null || echo 201)" '{"id":1}' ;;
    "GET repos/o/tproj/pulls/501") send 200 "{\"number\":501,\"draft\":$(cat "$STUB/draft" 2>/dev/null || echo true)}" ;;
    "DELETE repos/o/tproj/issues/501/labels/data-lane-pending") send "$(cat "$STUB/st-unlabel" 2>/dev/null || echo 200)" '[]' ;;
  esac
  send 404 '{}'
fi
case "$1 $2" in
  "pr ready") exit "$(cat "$STUB/ready-rc" 2>/dev/null || echo 0)" ;;
esac
exit 1
EOF
chmod +x "$T/fakebin/gh"
: > "$T/gh.log"
THREAD='[{"body":"HUMAN-STEP-DONE: applied prisma/sql/0087_x.sql","user":{"login":"operator","type":"User"}}]'
dlp_missing_comment o/tproj 87 "$THREAD" "https://github.com/o/tproj/issues/87#issuecomment-1" "ledger: no schema_migration row for 0087_x.sql at sha256 abc" >/dev/null 2>&1
MC=$?
[ "$MC" = 0 ] && [ "$(grep -c 'POST repos/o/tproj/issues/87/comments' "$T/gh.log")" = 1 ] && ok || bad "C1: one post without the tag (rc $MC): $(cat "$T/gh.log")"
grep -q 'no schema_migration row for 0087_x.sql' "$T/posted-body.txt" 2>/dev/null && grep -q '<!-- dlp-missing:[0-9a-f]\{40\} -->' "$T/posted-body.txt" \
  && ok || bad "C1: the body names the missing row and carries the tag: $(cat "$T/posted-body.txt" 2>/dev/null)"
TAGGED=$(jq -nc --arg b "$(cat "$T/posted-body.txt")" '[{body:$b,user:{login:"cromford[bot]",type:"Bot"}}]')
: > "$T/gh.log"
dlp_missing_comment o/tproj 87 "$TAGGED" "https://github.com/o/tproj/issues/87#issuecomment-1" "ledger: no schema_migration row for 0087_x.sql at sha256 abc" >/dev/null 2>&1
MC=$?
[ "$MC" = 0 ] && [ ! -s "$T/gh.log" ] && ok || bad "C2: a thread with the tag posts nothing (rc $MC): $(cat "$T/gh.log")"
echo 422 > "$T/st-comment"
dlp_missing_comment o/tproj 87 "$THREAD" u2 "detail two" >/dev/null 2>&1 && bad "C3: a failed post is rc 1" || ok
rm -f "$T/st-comment"

: > "$T/gh.log"
dlp_finish o/tproj https://github.com/o/tproj/pull/501 >/dev/null 2>&1 && ok || bad "N1: ready + unlabel is rc 0"
grep -q '^pr ready https://github.com/o/tproj/pull/501' "$T/gh.log" && grep -q 'DELETE repos/o/tproj/issues/501/labels/data-lane-pending' "$T/gh.log" \
  && ok || bad "N1: ready and the label DELETE ran: $(cat "$T/gh.log")"
echo 404 > "$T/st-unlabel"
dlp_finish o/tproj https://github.com/o/tproj/pull/501 >/dev/null 2>&1 && ok || bad "N2: a 404 on the label DELETE is success"
rm -f "$T/st-unlabel"; echo 1 > "$T/ready-rc"
dlp_finish o/tproj https://github.com/o/tproj/pull/501 >/dev/null 2>&1 && bad "N3: a failed gh pr ready is rc 1" || ok
rm -f "$T/ready-rc"; echo false > "$T/draft"; : > "$T/gh.log"
dlp_finish o/tproj https://github.com/o/tproj/pull/501 >/dev/null 2>&1 && ok || bad "N4: a ready PR only loses the label"
grep -q '^pr ready' "$T/gh.log" && bad "N4: no gh pr ready on a PR that is not a draft" || ok

# ── dlp_probe_alert_line ────────────────────────────────────────────────────
# ONE clock read for this block (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
QR="$T/qrec"; mkdir -p "$QR"
printf 'url=https://github.com/o/tproj/pull/501\nfile=prisma/sql/0087_x.sql\nhead=%s\n' "$HEADSHA" > "$QR/data-lane-pending"
OLD=$(date -u -d "@$((NOW - 90000))" '+%Y-%m-%dT%H:%M:%SZ'); NEW=$(date -u -d "@$((NOW - 3600))" '+%Y-%m-%dT%H:%M:%SZ')
REFUSED="probe: the migration token was refused (HTTP 401)"
OUT=$(dlp_probe_alert_line "$QR" tproj TP-87 75 "$REFUSED" "$NEW" 24); RC=$?
[ "$RC" = 0 ] && grep -q 'TP-87 draft https://github.com/o/tproj/pull/501' <<<"$OUT" && grep -q 'MIGRATION_TOKEN the app accepts in env/tproj.env' <<<"$OUT" \
  && ok || bad "Q1: a refused token pages at once (rc $RC): '$OUT'"
OUT=$(dlp_probe_alert_line "$QR" tproj TP-87 75 "$REFUSED" "$NEW" 0); RC=$?
[ "$RC" = 0 ] && ok || bad "Q2: a refused token pages even with the window off (rc $RC)"
dlp_probe_alert_line "$QR" tproj TP-87 75 "probe: migrations/status answered HTTP 500" "$NEW" 24 >/dev/null && bad "Q3: a 1 h old done comment with a 500 does not page yet" || ok
OUT=$(dlp_probe_alert_line "$QR" tproj TP-87 75 "probe: migrations/status answered HTTP 500" "$OLD" 24); RC=$?
[ "$RC" = 0 ] && grep -q 'DATA_LANE_APP_BASE' <<<"$OUT" && ok || bad "Q4: a 25 h old done comment with a 500 pages (rc $RC): '$OUT'"
OUT=$(dlp_probe_alert_line "$QR" tproj TP-87 1 "ledger: no schema_migration row for 0087_x.sql" "$OLD" 24); RC=$?
[ "$RC" = 0 ] && grep -q 'apply prisma/sql/0087_x.sql at the draft' <<<"$OUT" && ok || bad "Q5: a 25 h old missing row pages (rc $RC): '$OUT'"
dlp_probe_alert_line "$QR" tproj TP-87 1 "ledger: no row" "$OLD" 0 >/dev/null && bad "Q6: the window at 0 is off for a missing row" || ok
dlp_probe_alert_line "$QR" tproj TP-87 3 "probe: not set" "$OLD" 24 >/dev/null && bad "Q6: not-configured never pages here" || ok
dlp_probe_alert_line "$QR" tproj TP-87 1 "ledger: no row" "" 24 >/dev/null && bad "Q8: an empty done time never pages on the window" || ok
: > "$QR/.dlp-probe-alerted"
dlp_probe_alert_line "$QR" tproj TP-87 75 "$REFUSED" "$NEW" 24 >/dev/null && bad "Q7: an alerted record pages no second time" || ok

echo "data-lane-pending-lib.bh-6467: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
