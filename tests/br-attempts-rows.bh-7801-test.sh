#!/bin/bash
# tests/br-attempts-rows.bh-7801-test.sh — BH-7801 (slice C1 of #4157): the
# resolver record's attempts, rung fields and adjudication rulings as jobs-DB
# rows, read back when the record file is gone. Dual write: the file stays the
# authority while it exists.
#
#   A1   an attempt becomes ONE br_attempt row: key <p>/<rkey>#<digits>#<n6>,
#        status = action, detail {at,action,reason,detail,url,bump}
#   A2   an adjudicate ACCEPT/REJECT carries verdict + the ruling excerpt
#   A2b  a 20 KB quote/newline ruling: cut:true, valid JSON, <= 3500 bytes
#   A2c  exactly 3500 bytes is kept whole; 3501 is cut
#   A2d  a ruling cut mid-character still parses
#   A3   the ruling is read ONLY from the record's own run file (negatives)
#   A4   the PUT fails: br_record rc 0, the file has the attempt and counter
#   A5   the fragment absent: today's behavior, 0 br_attempt rows
#   A6   file gone, rows there: br_load restores attempts + rung fields
#   A7   file gone, the attempts read fails: attempts [], counters restored
#   A8   file present: 0 /api/br-attempts reads
#   A9   br_record row missing: 0 attempts reads, one ledger read per tick
#   A10  round trip incl. a head reset: same attempts, rung fields, cap rows
#   A11  bra_list skips a row whose detail is not JSON
#   A12  0 network: no curl ran
#   R1   a REAL driver tick: br_attempt rows == attempts in the record file;
#        BR_OPT_OFF=bh-7801-br-attempts gives 0 rows
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/br-attempts-rows.bh-7801-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: br-attempts-rows.bh-7801-test: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }

FRAG="$DIR/bin/blocked-resolver.d/bh-7801-br-attempts.sh"
for SRC in "$FRAG" "$DIR/bin/lib/br/record.sh" "$DIR/bin/lib/br/headgate.sh" \
           "$DIR/worker/jobs/src/routes/br-attempts.js" \
           "$DIR/worker/jobs/test/route-table.d/bh-7801-br-attempts.txt" \
           "$DIR/worker/jobs/test/br-attempts.bh-7801.test.js" \
           "$DIR/worker/jobs/test/br-attempts-indexes.bh-7801.test.js"; do
  [ -r "$SRC" ] && ok || bad "missing $SRC"
done

# ── A12 seam: a PATH curl that records any call; the jobs worker is unset ──
mkdir -p "$T/bin"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/curl.log"\nexit 7\n' "$T" > "$T/bin/curl"
chmod +x "$T/bin/curl"; : > "$T/curl.log"
export PATH="$T/bin:$PATH"
unset JOBS_URL HARNESS_SECRET

# ── the fake jobs client: ledgers as one JSONL file per kind ───────────────
# Switches (files in $T): put-down (every PUT rc 1), db-down (every ledger
# read rc 1), req-down (_jobs_req rc 1), req-body (the body _jobs_req answers).
# Logs: reads.log (ledger reads), req.log (_jobs_req calls), puts.log.
DB="$T/db"
JC="$T/jc.sh"
cat > "$JC" <<JC
job_ledger_put() {
  printf '%s %s\n' "\$1" "\$2" >> "$T/puts.log"
  [ -e "$T/put-down" ] && return 1
  mkdir -p "$DB"; touch "$DB/\$1.jsonl"
  jq -c --arg k "\$2" 'select(.key != \$k)' "$DB/\$1.jsonl" > "$DB/\$1.tmp"
  jq -nc --arg k "\$2" --arg s "\$3" --arg d "\${4:-}" '{key:\$k,status:\$s,detail:\$d,updated_at:"2026-10-21T19:26:00Z"}' >> "$DB/\$1.tmp"
  mv "$DB/\$1.tmp" "$DB/\$1.jsonl"
}
job_ledger_row() {
  printf '%s %s\n' "\$1" "\$2" >> "$T/reads.log"
  [ -e "$T/db-down" ] && return 1
  local r; r=\$(jq -c --arg k "\$2" 'select(.key == \$k) | {status,detail}' "$DB/\$1.jsonl" 2>/dev/null)
  [ -n "\$r" ] || return 2; printf '%s' "\$r"
}
_jobs_req() {
  printf '%s %s\n' "\$1" "\$2" >> "$T/req.log"
  [ -e "$T/req-down" ] && return 1
  [ -e "$T/req-body" ] && { cat "$T/req-body"; return 0; }
  local q p k; q="\${2#*\?}"; p=\$(printf '%s' "\$q" | sed -n 's/.*project=\([^&]*\).*/\1/p'); k=\$(printf '%s' "\$q" | sed -n 's/.*rkey=\([^&]*\).*/\1/p')
  jq -sc --arg pre "\$p/\$k#" '{attempts: [.[] | select(.key | startswith(\$pre))] | sort_by(.key), as_of:"x"}' "$DB/br_attempt.jsonl" 2>/dev/null || echo '{"attempts":[]}'
}
JC

ST="$T/st"
RUNF="$ST/p/k.adjudication-run.txt"
SHA=abcdef0123456789abcdef0123456789abcdef01
URL=https://github.com/o/r/pull/5
# reset — a fresh DB, state dir, logs and clock for one case
reset() {
  scratch_rm "$DB"; scratch_rm "$ST"; mkdir -p "$DB" "$ST/p"
  rm -f "$T/put-down" "$T/db-down" "$T/req-down" "$T/req-body" "$T/nofrag" "$T/miss"
  : > "$T/reads.log"; : > "$T/req.log"; : > "$T/puts.log"; echo 1 > "$T/clock"
}
# brx <fn> [args…] — runs one record function with the lane's globals, the
# fake client, the record and headgate modules and (unless $T/nofrag) the fragment
brx() {
  ( ST="$T/st"; H="$T/h"; BR_ROW_MISS="$T/miss"
    STAMP() { local n; n=$(cat "$T/clock"); echo $((n + 1)) > "$T/clock"; printf '2026-10-21 19:%02d:%02dZ' $((n / 60)) $((n % 60)); }
    say() { printf '%s\n' "$*" >> "$T/say.log"; }
    . "$JC"; . "$DIR/bin/lib/br/record.sh" || exit 9; . "$DIR/bin/lib/br/headgate.sh" || exit 9
    [ -e "$T/nofrag" ] || { . "$FRAG" || exit 9; }
    "$@" )
}
rows()   { cat "$DB/br_attempt.jsonl" 2>/dev/null; }
nrows()  { rows | grep -c . ; }
lastdet() { rows | tail -1 | jq -r .detail; }
bytes()  { printf '%s' "$1" | wc -c | tr -d ' '; }

# ── A1 ─────────────────────────────────────────────────────────────────────
reset
brx br_record p k rebuild why det rebuilds "$URL" "$SHA"; rc=$?
[ "$rc" = 0 ] && ok || bad "A1: br_record rc $rc"
[ "$(nrows)" = 1 ] && ok || bad "A1: one attempt must give ONE br_attempt row: $(rows)"
rows | jq -r .key | grep -Eq '^p/k#[0-9]{14}#000000$' && ok || bad "A1: key shape: $(rows | jq -r .key)"
[ "$(rows | jq -r .status)" = rebuild ] && ok || bad "A1: status is the action: $(rows | jq -r .status)"
D=$(lastdet)
[ "$(jq -r .action <<<"$D")" = rebuild ] && [ "$(jq -r .reason <<<"$D")" = why ] && [ "$(jq -r .detail <<<"$D")" = det ] \
  && [ "$(jq -r .url <<<"$D")" = "$URL" ] && [ "$(jq -r .bump <<<"$D")" = rebuilds ] && ok || bad "A1: detail fields: $D"
[ "$(jq -r .at <<<"$D")" = "$(jq -r '.attempts[0].at' "$ST/p/k.json")" ] && ok || bad "A1: at is the attempt's own at: $D"
brx br_record p k fixround why2 det2 fixrounds "$URL" "$SHA"
[ "$(nrows)" = 2 ] && rows | tail -1 | jq -r .key | grep -q '#000001$' && ok || bad "A1: the second attempt is row n=1: $(rows | jq -r .key)"
[ "$(lastdet | jq -r .head)" = "$SHA" ] && ok || bad "A1: a counted rung's head rides the row: $(lastdet)"
: > "$T/puts.log"
brx br_set_flag p k some_flag
[ "$(grep -c '^br_attempt ' "$T/puts.log")" = 0 ] && grep -q '^br_record p/k$' "$T/puts.log" && ok \
  || bad "A1: a save that appends no attempt PUTs no attempt row: $(cat "$T/puts.log")"
: > "$T/puts.log"
brx br_record p k held why3 det3
[ "$(grep -c '^br_attempt ' "$T/puts.log")" = 1 ] && ok || bad "A1: a save that appends one attempt PUTs one row: $(cat "$T/puts.log")"

# ── A2 ─────────────────────────────────────────────────────────────────────
reset
printf 'The diff is fine.\nReasons: x.\nVERDICT: ACCEPT\n' > "$RUNF"
brx br_record p k adjudicate why "ACCEPT — $RUNF" adjudications "$URL" "$SHA"
D=$(lastdet)
[ "$(jq -r .verdict <<<"$D")" = ACCEPT ] && ok || bad "A2: verdict ACCEPT: $D"
jq -r .ruling <<<"$D" | grep -q 'ACCEPT$' && ok || bad "A2: ruling ends with the verdict line: $D"
jq -r .ruling <<<"$D" | grep -q 'The diff is fine' && ok || bad "A2: ruling holds the text: $D"
[ "$(jq -r '.cut // "none"' <<<"$D")" = none ] && ok || bad "A2: a 1 KB ruling is not cut: $D"
printf 'No.\nVERDICT: REJECT\n' > "$RUNF"
brx br_record p k adjudicate why "REJECT — $RUNF" adjudications "$URL" "$SHA"
D=$(lastdet)
[ "$(jq -r .verdict <<<"$D")" = REJECT ] && jq -r .ruling <<<"$D" | grep -q 'REJECT$' && ok || bad "A2: REJECT verdict + ruling: $D"
# A2 tail: only the last 1500 bytes of a long ruling
reset
{ printf 'HEAD-OF-FILE\n'; head -c 3000 /dev/zero | tr '\0' 'a'; printf '\nVERDICT: ACCEPT\n'; } > "$RUNF"
brx br_record p k adjudicate why "ACCEPT — $RUNF" adjudications "$URL"
D=$(lastdet)
grep -q HEAD-OF-FILE <<<"$(jq -r .ruling <<<"$D")" && bad "A2: the ruling is the TAIL of the run file: $D" || ok
L=$(jq -r '.ruling | utf8bytelength' <<<"$D"); [ "$L" -le 1500 ] && [ "$L" -ge 1400 ] && ok || bad "A2: the excerpt is about 1500 bytes: $L"

# ── A2b: a 20 KB ruling of quotes, newlines and control bytes ───────────────
# A control byte encodes to 6 (\u0001), so 1500 bytes of them pass 3500.
reset
for _ in $(seq 1 500); do printf '"""""\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\n\n'; done > "$RUNF"; printf 'VERDICT: ACCEPT\n' >> "$RUNF"
brx br_record p k adjudicate why "ACCEPT — $RUNF" adjudications "$URL"
D=$(lastdet)
jq -e . >/dev/null 2>&1 <<<"$D" && ok || bad "A2b: the detail must parse: ${D:0:200}"
[ "$(bytes "$D")" -le 3500 ] && ok || bad "A2b: detail <= 3500 bytes: $(bytes "$D")"
[ "$(jq -r .cut <<<"$D")" = true ] && ok || bad "A2b: cut:true: ${D:0:300}"
jq -r .ruling <<<"$D" | grep -q 'ACCEPT$' && ok || bad "A2b: the cut keeps the END (the verdict): ${D:0:300}"

# ── A2c: the 3500-byte boundary ─────────────────────────────────────────────
# A ruling of 1500 backslashes encodes to 3000 bytes; the reason pads the rest.
mkrun() { head -c 1500 /dev/zero | tr '\0' '\\' > "$RUNF"; }
sized() { # sized <reason-length> — the stored detail for that reason length
  reset; mkrun
  brx br_record p k adjudicate "$(head -c "$1" /dev/zero | tr '\0' r)" "ACCEPT — $RUNF" adjudications "$URL"
  lastdet
}
D0=$(sized 0); S0=$(bytes "$D0")
NEED=$((3500 - S0))
if [ "$NEED" -ge 1 ] && [ "$NEED" -le 299 ]; then
  D=$(sized "$NEED")
  [ "$(bytes "$D")" = 3500 ] && ok || bad "A2c: fixture — expected a 3500-byte detail, got $(bytes "$D")"
  [ "$(jq -r '.cut // "none"' <<<"$D")" = none ] && [ "$(jq -r '.ruling | length' <<<"$D")" = 1500 ] && ok \
    || bad "A2c: exactly 3500 bytes is kept whole: cut=$(jq -r .cut <<<"$D")"
  D=$(sized $((NEED + 1)))
  [ "$(jq -r .cut <<<"$D")" = true ] && [ "$(bytes "$D")" -le 3500 ] && ok || bad "A2c: 3501 bytes is cut: $(bytes "$D")"
else
  bad "A2c: fixture — the base detail is $S0 bytes, no reason length reaches 3500"
fi
# Worst case: 800-char quote detail + 300-char quote reason + the ruling. The
# detail here must not be an adjudicate path, so the ruling cannot be read: use
# a big ruling through the adjudicate path, plus a long quote reason.
reset; for _ in $(seq 1 100); do printf '""""""""""""""""""""\n'; done > "$RUNF"
brx br_record p k adjudicate "$(head -c 300 /dev/zero | tr '\0' '"')" "ACCEPT — $RUNF" adjudications "$(printf 'https://github.com/o/r/pull/5?%s' "$(head -c 400 /dev/zero | tr '\0' '"')")"
D=$(lastdet)
jq -e . >/dev/null 2>&1 <<<"$D" && [ "$(bytes "$D")" -le 3500 ] && ok || bad "A2c worst: parses and fits: $(bytes "$D")"

# ── A2d: a 4-byte character cut by the excerpt ──────────────────────────────
reset
{ for _ in $(seq 1 500); do printf '\xf0\x9f\x98\x80'; done; printf 'x'; } > "$RUNF"
brx br_record p k adjudicate why "ACCEPT — $RUNF" adjudications "$URL"
D=$(lastdet)
jq -e .ruling >/dev/null 2>&1 <<<"$D" && [ "$(bytes "$D")" -le 3500 ] && ok || bad "A2d: a broken character still parses: ${D:0:120}"

# ── A3: the ruling is read only from <ST>/<p>/<rkey>.adjudication-run.txt ───
neg() { # neg <action> <detail> <label> — no ruling, no sentinel in any row
  reset
  printf 'SENTINEL-7801 VERDICT: ACCEPT\n' > "$RUNF"
  printf 'SENTINEL-7801 other\n' > "$ST/p/OTHER.adjudication-run.txt"
  printf 'SENTINEL-7801 outside\n' > "$T/outside.txt"
  [ "${4:-}" = absent ] && rm -f "$RUNF"
  brx br_record p k "$1" why "$2" adjudications "$URL"
  [ "$(nrows)" = 1 ] && ok || bad "A3 $3: fixture — one row: $(rows)"
  [ "$(lastdet | jq -r 'has("ruling")')" = false ] && ok || bad "A3 $3: no ruling field: $(lastdet)"
  grep -q SENTINEL-7801 "$DB/br_attempt.jsonl" && bad "A3 $3: the file was read into a row" || ok
}
neg adjudicate "ACCEPT — /etc/passwd" outside-etc
neg adjudicate "ACCEPT — $T/outside.txt" outside
neg adjudicate "ACCEPT — $ST/p/OTHER.adjudication-run.txt" other-record
neg adjudicate "ACCEPTED — $RUNF" near-miss-word
neg fixround "ACCEPT — $RUNF" other-action
neg adjudicate "ACCEPT — $ST/p/../p/k.adjudication-run.txt" dotdot
neg adjudicate "ACCEPT —
$RUNF" newline
neg adjudicate "ACCEPT — $RUNF" absent absent
[ "$(lastdet | jq -r .verdict)" = ACCEPT ] && ok || bad "A3 absent: the verdict is kept without the file: $(lastdet)"
# control: the same fixture with the right path IS read (what makes A3 about the rule)
reset; printf 'SENTINEL-7801 VERDICT: ACCEPT\n' > "$RUNF"
brx br_record p k adjudicate why "ACCEPT — $RUNF" adjudications "$URL"
grep -q SENTINEL-7801 "$DB/br_attempt.jsonl" && ok || bad "A3 control: the record's own run file is read"

# ── A4: the PUT fails ──────────────────────────────────────────────────────
reset; touch "$T/put-down"
brx br_record p k rebuild why det rebuilds "$URL"; rc=$?
[ "$rc" = 0 ] && ok || bad "A4: a failed PUT must not fail br_record (rc $rc)"
[ "$(jq -r '.attempts | length' "$ST/p/k.json")" = 1 ] && [ "$(jq -r .rebuilds "$ST/p/k.json")" = 1 ] && ok \
  || bad "A4: the file holds the attempt and the counter: $(cat "$ST/p/k.json")"
grep -q '^br_attempt ' "$T/puts.log" && ok || bad "A4: fixture — the attempt PUT was tried"

# ── A5: the fragment absent ────────────────────────────────────────────────
reset; touch "$T/nofrag"
brx br_record p k rebuild why det rebuilds "$URL"; rc=$?
[ "$rc" = 0 ] && [ "$(jq -r '.attempts | length' "$ST/p/k.json")" = 1 ] && ok || bad "A5: br_record works without the fragment"
[ "$(nrows)" = 0 ] && ok || bad "A5: no fragment, no br_attempt row: $(rows)"
grep -q '^br_record p/k$' "$T/puts.log" && ok || bad "A5: the br_record row is still written"

# ── A6: the file gone, the rows there ──────────────────────────────────────
H6="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; B6="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
reset
brx br_record p k mechanical w1 d1 mechanicals "$URL" "$H6"
brx br_record p k fixround w2 d2 fixrounds "$URL" "$H6"
brx br_head_reset p k why "$URL" "$H6" "$B6" >/dev/null
PRE=$(cat "$ST/p/k.json")
rm -f "$ST/p/k.json" "$T/miss"; : > "$T/req.log"   # a wipe, then a new tick
OUT=$(brx br_load p k)
[ "$(jq -r '.attempts | length' <<<"$OUT")" = 3 ] && ok || bad "A6: three attempts restored: $(jq -c .attempts <<<"$OUT")"
[ "$(jq -r '[.attempts[].action] | join(",")' <<<"$OUT")" = "mechanical,fixround,head-reset" ] && ok \
  || bad "A6: oldest first: $(jq -c '[.attempts[].action]' <<<"$OUT")"
[ "$(jq -r '[.attempts[].restored] | unique | join(",")' <<<"$OUT")" = ledger ] && ok || bad "A6: each restored:ledger"
[ "$(jq -r .rung_head <<<"$OUT")" = "$H6" ] && [ "$(jq -r .rung_pr <<<"$OUT")" = "$URL" ] && ok \
  || bad "A6: rung_head/rung_pr restored: $(jq -c '{rung_head,rung_pr}' <<<"$OUT")"
[ "$(jq -c .ladder_reset <<<"$OUT")" = "$(jq -c .ladder_reset <<<"$PRE")" ] && [ "$(jq -r .ladder_reset.to <<<"$OUT")" = "$B6" ] && ok \
  || bad "A6: ladder_reset restored: $(jq -c .ladder_reset <<<"$OUT")"
[ "$(grep -c 'GET /api/br-attempts?project=p&rkey=k' "$T/req.log")" = 1 ] && ok || bad "A6: one attempts read: $(cat "$T/req.log")"

# ── A7: the attempts read fails ────────────────────────────────────────────
rm -f "$ST/p/k.json" "$T/miss"; touch "$T/req-down"
OUT=$(brx br_load p k)
[ "$(jq -c .attempts <<<"$OUT")" = '[]' ] && [ "$(jq -r .restored <<<"$OUT")" = ledger ] && ok \
  || bad "A7: an outage gives attempts [] and the restored counters: $OUT"
[ "$(jq -r .rebuilds <<<"$OUT")" = 0 ] && [ "$(jq -r .first_seen <<<"$OUT")" = "$(jq -r .first_seen <<<"$PRE")" ] && ok || bad "A7: counters restored: $OUT"
rm -f "$T/req-down"

# ── A8: the file present ───────────────────────────────────────────────────
reset
brx br_record p k rebuild why det rebuilds "$URL"; : > "$T/req.log"
brx br_load p k >/dev/null
[ ! -s "$T/req.log" ] && ok || bad "A8: a record file on disk means no attempts read: $(cat "$T/req.log")"

# ── A9: no br_record row ───────────────────────────────────────────────────
reset
( ST="$T/st"; BR_ROW_MISS="$T/miss"; STAMP() { echo x; }; . "$JC"; . "$DIR/bin/lib/br/record.sh"; . "$FRAG"
  for _ in 1 2; do x=$(br_load p nokey); done; : "$x" )
[ ! -s "$T/req.log" ] && ok || bad "A9: a miss makes no attempts read: $(cat "$T/req.log")"
[ "$(grep -c 'br_record p/nokey' "$T/reads.log")" = 1 ] && ok || bad "A9: one ledger read per tick: $(cat "$T/reads.log")"
touch "$T/db-down"; rm -f "$T/miss"; : > "$T/reads.log"
brx br_load p nokey >/dev/null
[ ! -s "$T/req.log" ] && ok || bad "A9: an outage on the record row makes no attempts read"

# ── A10: the round trip ────────────────────────────────────────────────────
reset
capfx() { # the pr_attempts read br_cap_rows makes, faked: 3 fix rounds on the PR
  pr_rows_on() { return 0; }; br_slug_of_url() { echo o/r; }; mc_num_of_url() { echo 5; }
  pr_attempt_count() { echo 3; }; pr_attempt_put() { :; }
  br_cap_rows p k review "$(br_num "$(br_load p k)" fixrounds)" "$URL" fixround fixrounds "$(br_load p k)"
}
brx br_record p k fixround w1 d1 fixrounds "$URL" "$H6"
brx br_record p k fixround w2 d2 fixrounds "$URL" "$H6"
brx br_head_reset p k why "$URL" "$H6" "$B6" >/dev/null
brx br_record p k fixround w3 d3 fixrounds "$URL" "$B6"
PRE=$(cat "$ST/p/k.json"); CAP0=$(brx capfx)
rm -f "$ST/p/k.json" "$T/miss"
POST=$(brx br_load p k); CAP1=$(brx capfx)
sel='[.attempts[] | {at,action,reason,url}]'
[ "$(jq -c "$sel" <<<"$POST")" = "$(jq -c "$sel" <<<"$PRE")" ] && ok \
  || bad "A10: attempts round-trip: pre $(jq -c "$sel" <<<"$PRE") post $(jq -c "$sel" <<<"$POST")"
[ "$(jq -c '{rung_head,rung_pr,ladder_reset}' <<<"$POST")" = "$(jq -c '{rung_head,rung_pr,ladder_reset}' <<<"$PRE")" ] && ok \
  || bad "A10: rung fields round-trip: $(jq -c '{rung_head,rung_pr,ladder_reset}' <<<"$POST")"
[ "$CAP0" = 1 ] && [ "$CAP1" = "$CAP0" ] && ok || bad "A10: br_cap_rows the same before ($CAP0) and after ($CAP1) the wipe, 1 expected (3 rows - base 2)"
# the next attempt after the restore is a new row, the old rows stay
: > "$T/puts.log"
brx br_record p k fixround w4 d4 fixrounds "$URL" "$B6"
[ "$(grep -c '^br_attempt ' "$T/puts.log")" = 1 ] && ok || bad "A10: the restored attempts are not PUT again: $(grep '^br_attempt ' "$T/puts.log")"
[ "$(nrows)" = 5 ] && ok || bad "A10: one new row after a restore, no re-put of the restored ones: $(nrows)"
[ "$(rows | jq -r .key | sort -u | wc -l | tr -d ' ')" = 5 ] && ok || bad "A10: unique keys"

# ── A11: a row whose detail is not JSON ────────────────────────────────────
reset
jq -nc '{attempts:[{key:"p/k#1#000000",status:"rebuild",detail:"{\"at\":\"t1\",\"action\":\"rebuild\",\"reason\":\"r\",\"detail\":\"d\"}"},
                   {key:"p/k#2#000001",status:"x",detail:"not json {"},
                   {key:"p/k#3#000002",status:"fixround",detail:"{\"at\":\"t3\",\"action\":\"fixround\",\"reason\":\"r3\",\"detail\":\"d3\",\"url\":\"u\"}"}]}' > "$T/req-body"
OUT=$(brx bra_list p k); rc=$?
[ "$rc" = 0 ] && [ "$(jq -r '[.[].at] | join(",")' <<<"$OUT")" = "t1,t3" ] && ok || bad "A11: the bad row is skipped (rc $rc): $OUT"
[ "$(jq -r '.[1].url' <<<"$OUT")" = u ] && ok || bad "A11: url kept: $OUT"
echo '{"error":"x"}' > "$T/req-body"
OUT=$(brx bra_list p k); rc=$?
[ "$rc" = 1 ] && [ -z "$OUT" ] && ok || bad "A11: a body with no attempts array is rc 1 and prints nothing (rc $rc): $OUT"
rm -f "$T/req-body"

# ── A12: 0 network ─────────────────────────────────────────────────────────
[ ! -s "$T/curl.log" ] && ok || bad "A12: no curl may run: $(cat "$T/curl.log")"

# ── R1: a REAL driver tick ─────────────────────────────────────────────────
# The #1634 no-key ladder of tests/blocked-resolver-record-rows.bh-2317-test.sh
# case B1, in this suite's own scratch, with the resolver's .d/ directory.
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin"
for s in blocked-resolver.sh fly-pool.sh merge-sweep.sh merge-conductor.sh fleet-conf.sh project-of.sh box-for.sh; do
  scratch_install_closure "bin/$s" "$T/h" >/dev/null || exit 1
done
fx_br_harness "$DIR" "$T" || exit 1
mkdir -p "$H/bin/blocked-resolver.d" && cp "$FRAG" "$H/bin/blocked-resolver.d/" || exit 1
scratch_install_closure bin/lib/comment-mark.sh "$T/h" >/dev/null || exit 1
RDB="$T/rdb"
cat > "$H/bin/jobs-client.sh" <<JC
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { return 0; }
queue_list() { return 1; }
job_ledger_row() { return 2; }
job_ledger_get() { return 2; }
job_ledger_put() { mkdir -p "$RDB"; printf '%s\t%s\t%s\n' "\$1" "\$2" "\$3" >> "$RDB/puts.tsv"; }
JC
# The gh stub of the BH-2317 suite, verbatim in what it answers.
cat > "$T/fakebin/gh" <<EOF2
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
case "\$*" in
  *"-i -X "*) GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"pr close"*) exit 0 ;;
  *"issue comment"*|*"pr comment"*) exit 0 ;;
  *"--json state"*) cat "$T/prstate" 2>/dev/null || echo OPEN ;;
  *"/pulls/"*) _h=\$(<"$T/prhead"); _b=\$(<"$T/prbranch"); echo "\${_h:-null} \${_b:-null}" ;;
  *"--json headRefOid,headRefName"*) echo "\$(cat "$T/prhead") \$(cat "$T/prbranch")" ;;
  *"--json headRefName"*) cat "$T/prbranch" ;;
  *"--json headRefOid"*)  cat "$T/prhead" ;;
  *"--json title"*)       cat "$T/prtitle" 2>/dev/null ;;
  *"pr list"*) : ;;
  *) echo "" ;;
esac
exit 0
EOF2
chmod +x "$T/fakebin/gh"
r1() {
  scratch_rm "$H/state/blocked-resolver"; scratch_rm "$RDB"
  : > "$T/prtitle"; : > "$T/mergedprs"; printf 'feature/x' > "$T/prbranch"; : > "$T/prhead"; echo OPEN > "$T/prstate"
  touch "$H/flags/fly-pool-tproj"; : > "$H/state/merge-conductor/pr-state.tsv"
  SPENT o-tproj-1634
  ROW "o/tproj#1634" "conflict-unresolvable: CONFLICT (content): src/a.ts" "https://github.com/o/tproj/pull/1634"
  : > "$T/run.log"; RUN
}
BRENV=()
r1
NA=$(STATEJSON o-tproj-1634 | jq '.attempts | length')
NR=$(awk -F'\t' '$1 == "br_attempt" && index($2, "tproj/o-tproj-1634#") == 1' "$RDB/puts.tsv" 2>/dev/null | cut -f2 | sort -u | wc -l | tr -d ' ')
[ "${NA:-0}" -ge 1 ] 2>/dev/null && ok || bad "R1: fixture — the tick must record an attempt: $(STATEJSON o-tproj-1634); $(tail -5 "$T/run.log")"
[ "$NR" = "$NA" ] && ok || bad "R1: br_attempt rows ($NR) must equal the record's attempts ($NA): $(cat "$RDB/puts.tsv" 2>/dev/null)"
BRENV=(BR_OPT_OFF=bh-7801-br-attempts)
r1
NR=$(awk -F'\t' '$1 == "br_attempt"' "$RDB/puts.tsv" 2>/dev/null | wc -l | tr -d ' ')
[ "$(STATEJSON o-tproj-1634 | jq '.attempts | length')" -ge 1 ] && [ "$NR" = 0 ] && ok || bad "R1: BR_OPT_OFF=bh-7801-br-attempts gives 0 rows ($NR)"

echo "br-attempts-rows.bh-7801-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
