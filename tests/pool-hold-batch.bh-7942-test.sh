#!/bin/bash
# tests/pool-hold-batch.bh-7942-test.sh — the pool's HOLD gate reads each
# queued row's issue from the ONE open ai-build listing the tick already reads
# (BH-6549), so a row costs one comments read, not an issue GET plus a comments
# read. Every hold read is cut at POOL_HOLD_READ_TIMEOUT_S (45), and a read that
# does not answer is retried once in the tick before the row is skipped
# (BH-7942).
#
#   Section L  phc_listing_issues (bin/lib/pool-hold-cache.sh) alone.
#   Section H  hold_check_issue (bin/lib/hold.sh) against a gh stub.
#   Section P  the real bin/fly-pool.sh as a subprocess (the BH-6549 scaffold):
#              read counts per tick.
#   Section K  the POOL_HOLD_READ_TIMEOUT_S knob, from a fake `timeout` that
#              logs the limit of every gh read.
#   Section S  the one retry inside the tick, its breaker, the listing retry.
#   Section R  real holds still hold, RESUME still releases.
#
# Fail-safe direction under test: an unreadable read never marks or clears a
# hold; a listing item without the full fields is read as before.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
TAB=$'\t'
HOLD_THREAD='[{"id":101,"created_at":"2026-10-13T19:00:00Z","body":"HOLD — do not build","user":{"login":"fixture-person","type":"User"}}]'
RESUME_THREAD='[{"id":101,"created_at":"2026-10-13T19:00:00Z","body":"HOLD — do not build","user":{"login":"fixture-person","type":"User"}},
                {"id":102,"created_at":"2026-10-13T21:00:00Z","body":"RESUME","user":{"login":"fixture-person","type":"User"}}]'
AI_BUILD='[{"name":"ai-build"}]'
item() { # item <n> [labels-json] [title] — one complete listing item
  jq -nc --argjson n "$1" --argjson l "${2:-$AI_BUILD}" --arg t "${3:-fixture ticket}" \
    '{number:$n,updated_at:"2026-10-13T20:00:00Z",comments:1,state:"open",labels:$l,title:$t,body:"fixture body"}'
}

# ════ Section L: phc_listing_issues ═════════════════════════════════════════
# shellcheck source=bin/lib/pool-hold-cache.sh
. "$DIR/bin/lib/pool-hold-cache.sh" 2>/dev/null || bad "L0: bin/lib/pool-hold-cache.sh cannot be sourced"
if ! command -v phc_listing_issues >/dev/null 2>&1; then
  bad "L0: phc_listing_issues is not defined"
else
  # L1 a PR and an item without labels are dropped; body null is kept
  L1IN=$(jq -nc --argjson a "$(item 7)" '[$a,
    {number:8,updated_at:"x",comments:0,state:"open",labels:[],title:"t",body:"b",pull_request:{url:"x"}},
    {number:9,updated_at:"x",comments:0,state:"open",title:"t",body:"b"},
    {number:10,updated_at:"x",comments:0,state:"open",labels:[{name:"ai-build"}],title:"t",body:null}]')
  OUT=$(phc_listing_issues "$L1IN"); RC=$?
  [ "$RC" = 0 ] && [ "$(cut -f1 <<<"$OUT" | tr '\n' ' ')" = "7 10 " ] && ok || bad "L1: kept numbers (rc $RC): '$(cut -f1 <<<"$OUT" | tr '\n' ' ')'"
  [ "$(grep '^10	' <<<"$OUT" | cut -f2- | jq -c .body)" = null ] && ok || bad "L1: body null must survive"
  # L2 a non-array page is rc 2; [] is rc 0 with no rows
  phc_listing_issues '{"message":"Bad credentials"}' >/dev/null 2>&1; RC=$?
  [ "$RC" = 2 ] && ok || bad "L2: a non-array page must be rc 2, got $RC"
  OUT=$(phc_listing_issues '[]'); RC=$?
  [ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "L2: [] is rc 0 and no rows (rc $RC '$OUT')"
  # L3 a body with a tab, a newline and a HOLD line round-trips byte-equal
  B3=$(printf 'first\tcol\nHOLD — x\nlast')
  L3IN=$(jq -nc --arg b "$B3" '[{number:11,updated_at:"x",comments:0,state:"open",labels:[{name:"ai-build"}],title:"t",body:$b}]')
  OUT=$(phc_listing_issues "$L3IN")
  [ "$(grep -c . <<<"$OUT")" = 1 ] && ok || bad "L3: one line per item, got $(grep -c . <<<"$OUT")"
  IFS=$'\t' read -r N3 J3 <<<"$OUT"
  [ "$N3" = 11 ] && [ "$(jq -r .body <<<"$J3")" = "$B3" ] && ok || bad "L3: the body must round-trip: '$(jq -r .body <<<"$J3")'"
  # L4 two items, two lines, listing order
  OUT=$(phc_listing_issues "[$(item 21),$(item 20)]")
  [ "$(cut -f1 <<<"$OUT" | tr '\n' ' ')" = "21 20 " ] && ok || bad "L4: listing order: '$(cut -f1 <<<"$OUT" | tr '\n' ' ')'"
fi

# ════ Section H: hold_check_issue ══════════════════════════════════════════
HB="$T/hbin"; HG="$T/hgh"; mkdir -p "$HB" "$HG"
cat > "$HB/gh" <<'GH'
#!/bin/bash
G=@G@; args="$*"
num() { local x="${args#*issues/}"; printf '%s' "${x%%[!0-9]*}"; }
if [[ "$args" == *"issues/"*"/comments"* ]]; then
  n=$(num); echo "$n" >> "$G/comment-reads.log"; cat "$G/comments-$n.json" 2>/dev/null || echo '[]'; exit 0
fi
if [[ "$args" == *"issues/"* ]]; then
  n=$(num); echo "$n" >> "$G/issue-reads.log"; cat "$G/issue-$n.json"; exit 0
fi
exit 0
GH
sed -i "s#@G@#$HG#" "$HB/gh"; chmod +x "$HB/gh"
hcount() { grep -c . "$HG/$1" 2>/dev/null || echo 0; }
hreset() { rm -f "$HG"/*; }
(
  export PATH="$HB:$PATH"
  # shellcheck source=bin/lib/hold.sh
  . "$DIR/bin/lib/hold.sh" || { echo "FAIL: H0: hold.sh cannot be sourced"; exit 1; }
  command -v hold_check_issue >/dev/null 2>&1 || { echo "FAIL: H0: hold_check_issue is not defined"; exit 1; }
  f=0
  # H1 no issue GET, one comments read
  hreset; printf '%s\n' "$HOLD_THREAD" > "$HG/comments-5.json"
  OUT=$(hold_check_issue o/r 5 "$(item 5)"); RC=$?
  [ "$RC" = 1 ] && [ "$(hcount issue-reads.log)" = 0 ] && [ "$(hcount comment-reads.log)" = 1 ] \
    || { echo "FAIL: H1: rc $RC, issue GETs $(hcount issue-reads.log), comment reads $(hcount comment-reads.log): $OUT"; f=1; }
  # H2 same verdict line and rc as hold_check, four fixtures
  for fx in comment resume label title; do
    hreset
    case "$fx" in
      comment) it=$(item 6); th="$HOLD_THREAD" ;;
      resume)  it=$(item 6); th="$RESUME_THREAD" ;;
      label)   it=$(item 6 '[{"name":"ai-build"},{"name":"hold"}]'); th='[]' ;;
      title)   it=$(item 6 '[{"name":"ai-build"}]' '(HOLD) wait for the launch'); th='[]' ;;
    esac
    printf '%s\n' "$th" > "$HG/comments-6.json"; printf '%s\n' "$it" > "$HG/issue-6.json"
    A=$(hold_check o/r 6); ARC=$?
    B=$(hold_check_issue o/r 6 "$it"); BRC=$?
    [ "$A" = "$B" ] && [ "$ARC" = "$BRC" ] || { echo "FAIL: H2 $fx: hold_check '$A' rc $ARC, hold_check_issue '$B' rc $BRC"; f=1; }
  done
  # H3 an empty issue json: unreadable rc 2, no read
  hreset
  OUT=$(hold_check_issue o/r 7 ""); RC=$?
  [ "$RC" = 2 ] && [ "${OUT%%	*}" = unreadable ] && [ "$(hcount comment-reads.log)" = 0 ] && [ "$(hcount issue-reads.log)" = 0 ] \
    || { echo "FAIL: H3: rc $RC '$OUT'"; f=1; }
  # H4 a non-numeric ticket
  OUT=$(hold_check_issue o/r BH-7 "$(item 7)"); RC=$?
  [ "$RC" = 2 ] && [ "$OUT" = "unreadable${TAB}no issue number to read" ] || { echo "FAIL: H4: rc $RC '$OUT'"; f=1; }
  exit "$f"
) && ok || bad "H: section H (lines above)"

# ════ Section P: real pool ticks ════════════════════════════════════════════
H="$T/h"
QD="$H/state/build-queue/project-5"; PD="$H/state/pool/project-5"; MD="$H/state/fly-pool/project-5"
GF="$T/gh"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" "$H/plans" \
         "$H/state/fly" "$MD" "$QD" "$H/state/remote-results/project-5" \
         "$PD" "$H/builds" "$T/fakebin" "$GF"
printf 'FLY_API_TOKEN_project-5=tok-fixture-1\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf 'project-5 example-org/project-5 - - 0 local\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"
printf '#!/bin/bash\necho "$*" >> "%s/alert-calls"\nexit 0\n' "$T" > "$H/bin/alert-line.sh"
cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
scratch_install_closure bin/fly-pool.sh "$H" >/dev/null || { echo "closure install of bin/fly-pool.sh failed"; exit 1; }
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
# The fake timeout logs "<limit><TAB><command>" for every call, then runs it.
cat > "$T/fakebin/timeout" <<TO
#!/bin/bash
printf '%s\t%s\n' "\$1" "\${*:2}" >> "$T/timeout-args.log"
shift; exec "\$@"
TO
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
cat > "$T/fakebin/base64" <<'B64'
#!/bin/bash
REAL=/usr/bin/base64; [ -x "$REAL" ] || REAL=/bin/base64
DEC=0; W0=0; FILE=""
for a in "$@"; do
  case "$a" in
    -d|-D)  DEC=1 ;;
    -w0|-w) W0=1 ;;
    0)      ;;
    -*)     ;;
    *)      FILE="$a" ;;
  esac
done
GNU=0; printf 'eA==' | "$REAL" -d >/dev/null 2>&1 && GNU=1
FLAGS=()
if [ "$DEC" = 1 ]; then
  [ "$GNU" = 1 ] && FLAGS+=(-d) || FLAGS+=(-D)
elif [ "$W0" = 1 ]; then
  [ "$GNU" = 1 ] && FLAGS+=(-w0) || FLAGS+=(-b 0)
fi
if [ -n "$FILE" ]; then exec "$REAL" "${FLAGS[@]}" < "$FILE"; fi
exec "$REAL" "${FLAGS[@]}"
B64
cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
echo "\$*" >> "$T/fly-calls"
case "\$*" in
  *"machine status"*) echo "State: started" ;;
  *"machines list"*) echo '[]' ;;
  *"machine run"*) printf 'Machine ID: 1234567890abcd\\n' ;;
esac
exit 0
FLY
# The gh stub serves everything from files under $GF:
#   listing-<page>.json            the open ai-build issue listing page
#   listing.codes                  one HTTP code per listing call, consumed in order (default 200)
#   issue-<n>.json                 the single-issue object (default: open, ai-build)
#   comments-<n>.json              the thread
#   comments-<n>.cut               N: the next N comments reads exit 124 (a cut read); `always`: every one
cat > "$T/fakebin/gh" <<'GH'
#!/bin/bash
T=@T@; GF="$T/gh"
args="$*"; inc=0
for a in "$@"; do
  case "$a" in issue) echo "$args" >> "$T/gh-sink.txt"; exit 0 ;; -i) inc=1 ;; esac
done
num() { local x="${args#*issues/}"; printf '%s' "${x%%[!0-9]*}"; }
if [[ "$args" == *"/comments"* ]] && [[ "$args" == *"body=@"* ]]; then
  echo "$args" >> "$T/gh-post.txt"; echo '{"id":1}'; exit 0
fi
if [[ "$args" == *"--paginate"* ]] && [[ "$args" == *"issues/"*"/comments"* ]]; then
  n=$(num); echo "$n" >> "$T/comment-reads.log"
  if [ -e "$GF/comments-$n.cut" ]; then
    c=$(cat "$GF/comments-$n.cut")
    [ "$c" = always ] && exit 124
    if [ "$c" -gt 0 ] 2>/dev/null; then echo $((c - 1)) > "$GF/comments-$n.cut"; exit 124; fi
  fi
  cat "$GF/comments-$n.json" 2>/dev/null || echo '[]'
  exit 0
fi
if [ "$inc" = 1 ]; then
  if [[ "$args" == *"issues?state=open"* ]]; then
    echo "$args" >> "$T/listing-reads.log"
    code=200
    if [ -s "$GF/listing.codes" ]; then
      code=$(head -n 1 "$GF/listing.codes"); tail -n +2 "$GF/listing.codes" > "$GF/listing.codes.tmp"; mv "$GF/listing.codes.tmp" "$GF/listing.codes"
    fi
    page="${args##*&page=}"; page="${page%%[!0-9]*}"
    printf 'HTTP/1.1 %s Fixture\n\n' "$code"
    if [ "$code" = 200 ]; then cat "$GF/listing-$page.json" 2>/dev/null || echo '[]'; else echo '{"message":"fixture"}'; fi
    exit 0
  fi
  if [[ "$args" == *"repos/example-org/project-5" ]] || [[ "$args" == *"repos/example-org/project-5 "* ]]; then
    printf 'HTTP/1.1 200 OK\n\n{"full_name":"example-org/project-5"}\n'; exit 0
  fi
  if [[ "$args" == *"pulls?state=open"* ]]; then printf 'HTTP/1.1 200 OK\n\n[]\n'; exit 0; fi
  printf 'HTTP/1.1 404 Not Found\n\n{}\n'; exit 0
fi
if [[ "$args" == *"repos/example-org/project-5/issues/"* ]]; then
  n=$(num); echo "$n" >> "$T/issue-reads.log"
  cat "$GF/issue-$n.json" 2>/dev/null \
    || echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"fixture ticket","body":"fixture body"}'
  exit 0
fi
exit 0
GH
sed -i "s#@T@#$T#" "$T/fakebin/gh"
chmod +x "$H/bin/beat.sh" "$H/bin/result-prefix-ok.sh" "$H/bin/fly-envbundle.sh" \
         "$H/bin/alert-line.sh" "$T/fakebin"/*

run_pool() {
  : > "$H/logs/fly-pool.log"; : > "$H/logs/ALERTS.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           FLY_API_TOKEN_project-5=tok-fixture-1 FLY_BIN_DIR="$T/fakebin" "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}
reads() { grep -c . "$T/$1" 2>/dev/null || echo 0; }
reads_of() { grep -cx "$2" "$T/$1" 2>/dev/null || echo 0; }
LOGF="$H/logs/fly-pool.log"
STAMP_I=0
queue() { # queue <n> — each queue file one second older than the next (walk order)
  STAMP_I=$((STAMP_I + 1))
  jq -nc --arg k "BH-$1" --arg t "$1" \
    '{ticket_id:$t,key:$k,attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-10-13T02:30:00Z"}' > "$QD/BH-$1.json"
  touch -d "@$((1791800000 + STAMP_I))" "$QD/BH-$1.json"
}
listing_add() { # listing_add <page> <item-json>
  local f="$GF/listing-$1.json"
  [ -f "$f" ] || echo '[]' > "$f"
  jq -c --argjson i "$2" '. + [$i]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
reset_state() {
  local p
  for p in "$QD"/* "$MD"/* "$PD"/* "$GF"/* "$T/fly-calls" "$T/alert-calls" "$T/gh-post.txt" "$T/gh-sink.txt" \
           "$T/comment-reads.log" "$T/issue-reads.log" "$T/listing-reads.log" "$T/timeout-args.log"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  STAMP_I=0
  return 0
}
# held_rows <from> <to> — queued, held by a comment, complete items on page 1
held_rows() {
  local n items=()
  for n in $(seq "$1" "$2"); do
    queue "$n"; printf '%s\n' "$HOLD_THREAD" > "$GF/comments-$n.json"; items+=("$(item "$n")")
  done
  printf '%s\n' "${items[@]}" | jq -sc '.' > "$GF/listing-1.json"
}
summary() { grep -o 'hold reads: batched=.*' "$LOGF"; }

# ── P1: 30 held rows: 1 listing call, 0 issue GETs, 30 comment reads ───────
reset_state; held_rows 3001 3030
run_pool
L=$(reads listing-reads.log); I=$(reads issue-reads.log)
[ $((L + I)) -le 3 ] && ok || bad "P1: 30 rows must make <= 3 issue-list calls (listing + issue GETs), made $L listing + $I issue GETs"
[ "$I" = 0 ] && ok || bad "P1: 0 issue GETs, made $I"
[ "$(reads comment-reads.log)" = 30 ] && ok || bad "P1: 30 comment reads, made $(reads comment-reads.log)"
NS=$(grep -c 'skipping BH-30[0-9][0-9]: HOLD (held' "$LOGF")
[ "$NS" = 30 ] && ok || bad "P1: 30 HOLD skips, logged $NS"
grep -q 'hold reads: batched=30 ' <<<"$(summary)" && ok || bad "P1: the summary must say batched=30: '$(summary)'"
[ "$(summary | grep -c .)" = 1 ] && ok || bad "P1: exactly one 'hold reads:' line: '$(summary)'"

# ── P2: one item without labels reads its issue, the other 29 do not ───────
reset_state; held_rows 3001 3030
jq -c 'map(if .number == 3005 then del(.labels) else . end)' "$GF/listing-1.json" > "$GF/l.tmp" && mv "$GF/l.tmp" "$GF/listing-1.json"
run_pool
[ "$(reads issue-reads.log)" = 1 ] && [ "$(reads_of issue-reads.log 3005)" = 1 ] && ok \
  || bad "P2: only 3005 makes an issue GET: $(tr '\n' ' ' < "$T/issue-reads.log" 2>/dev/null)"
[ "$(grep -c 'skipping BH-30[0-9][0-9]: HOLD (held' "$LOGF")" = 30 ] && ok || bad "P2: all 30 stay held"

# ── P3: a row absent from the listing, closed: 1 issue GET, the row parks ──
reset_state; held_rows 3001 3002
queue 3031; echo '{"state":"closed","labels":[{"name":"ai-build"}],"title":"t","body":"b"}' > "$GF/issue-3031.json"
run_pool
[ "$(reads issue-reads.log)" = 1 ] && [ "$(reads_of issue-reads.log 3031)" = 1 ] && ok || bad "P3: one issue GET for 3031: $(tr '\n' ' ' < "$T/issue-reads.log" 2>/dev/null)"
grep -q 'skipping BH-3031: closed — parking the row' "$LOGF" && ok || bad "P3: BH-3031 must park: $(grep 3031 "$LOGF")"
[ -e "$QD/BH-3031.json" ] && bad "P3: BH-3031's queue file must be gone" || ok

# ── P4: two listing pages, rows on both: 2 listing calls, 0 issue GETs ─────
reset_state
seq 3001 3100 | while read -r n; do item "$n"; done | jq -sc . > "$GF/listing-1.json"
seq 3101 3105 | while read -r n; do item "$n"; done | jq -sc . > "$GF/listing-2.json"
for n in 3001 3103; do queue "$n"; printf '%s\n' "$HOLD_THREAD" > "$GF/comments-$n.json"; done
run_pool
[ "$(reads listing-reads.log)" = 2 ] && [ "$(reads issue-reads.log)" = 0 ] && ok \
  || bad "P4: 2 listing calls and 0 issue GETs, got $(reads listing-reads.log) and $(reads issue-reads.log)"
[ "$(grep -c 'skipping BH-3\(001\|103\): HOLD' "$LOGF")" = 2 ] && ok || bad "P4: both rows held"

# ════ Section K: the hold read timeout ══════════════════════════════════════
# A batched row (3001) and a row absent from the listing (3031, closed), so the
# log has a listing page, a comments read and an issue GET.
kfix() { reset_state; held_rows 3001 3001; queue 3031; echo '{"state":"closed","labels":[{"name":"ai-build"}],"title":"t","body":"b"}' > "$GF/issue-3031.json"; }
lims() { # lims <pattern> — the distinct limits logged for gh reads that match
  grep -F 'gh api' "$T/timeout-args.log" 2>/dev/null | grep -F -- "$1" | cut -f1 | sort -u | tr '\n' ' '
}
kfix; run_pool
[ "$(lims 'issues?state=open')" = "45 " ] && ok || bad "K1: listing reads must be cut at 45: '$(lims 'issues?state=open')'"
[ "$(lims '/comments')" = "45 " ] && ok || bad "K1: comments reads must be cut at 45: '$(lims '/comments')'"
[ "$(lims 'issues/3031')" = "45 " ] && ok || bad "K1: the issue GET must be cut at 45: '$(lims 'issues/3031')'"
[ "$(lims 'pulls?state=open')" = "20 " ] && ok || bad "K1: the PR list read keeps 20: '$(lims 'pulls?state=open')'"
kfix; run_pool POOL_HOLD_READ_TIMEOUT_S=7
[ "$(lims 'issues?state=open')$(lims '/comments')$(lims 'issues/3031')" = "7 7 7 " ] && ok \
  || bad "K2: hold reads must be cut at 7: '$(lims 'issues?state=open')|$(lims '/comments')|$(lims 'issues/3031')'"
kfix; run_pool POOL_HOLD_READ_TIMEOUT_S=soon
[ "$(lims 'issues?state=open')$(lims '/comments')" = "45 45 " ] && ok || bad "K3: a non-number falls back to 45: '$(lims '/comments')'"
[ "$(grep -c 'POOL_HOLD_READ_TIMEOUT_S=soon is not a number' "$LOGF")" = 1 ] && ok || bad "K3: the bad value must be said once"
grep -q 'timeout_s=45' <<<"$(summary)" && ok || bad "K3: the summary must say timeout_s=45: '$(summary)'"

# ════ Section S: one retry inside the tick ═════════════════════════════════
# S1 the first comments read is cut, the retry answers: a decision, not a skip
reset_state; held_rows 3001 3001; echo 1 > "$GF/comments-3001.cut"
run_pool
grep -q 'skipping BH-3001: HOLD (held' "$LOGF" && ok || bad "S1: BH-3001 must be held by the retry: $(grep 3001 "$LOGF")"
grep -q 'skipping BH-3001: hold check unreadable' "$LOGF" && bad "S1: the retry answered, so no unreadable skip" || ok
[ "$(reads_of comment-reads.log 3001)" = 2 ] && ok || bad "S1: two comments reads, made $(reads_of comment-reads.log 3001)"
grep -q 'retries=1 retry_ok=1 ' <<<"$(summary)" && ok || bad "S1: summary: '$(summary)'"

# S2 both reads cut: unreadable, the earlier .held kept byte-equal, queue kept
reset_state; held_rows 3001 3001; echo always > "$GF/comments-3001.cut"
printf '{"key":"BH-3001","why":"fixture"}\n' > "$PD/BH-3001.held"; cp "$PD/BH-3001.held" "$T/s2.before"
run_pool
[ "$(grep -c 'skipping BH-3001: hold check unreadable (.*) — will retry' "$LOGF")" = 1 ] && ok || bad "S2: one unreadable skip: $(grep 3001 "$LOGF")"
cmp -s "$PD/BH-3001.held" "$T/s2.before" && ok || bad "S2: the .held marker must be kept as it was"
[ -f "$QD/BH-3001.json" ] && ok || bad "S2: the queue file must stay"
[ "$(reads_of comment-reads.log 3001)" = 2 ] && ok || bad "S2: two comments reads, made $(reads_of comment-reads.log 3001)"

# S3 the breaker: after one row's retry fails, the next row reads once
reset_state; held_rows 3001 3002
echo always > "$GF/comments-3001.cut"; echo always > "$GF/comments-3002.cut"
run_pool
[ "$(reads_of comment-reads.log 3001)" = 2 ] && [ "$(reads_of comment-reads.log 3002)" = 1 ] && ok \
  || bad "S3: 3001 reads twice and 3002 once, got $(reads_of comment-reads.log 3001) and $(reads_of comment-reads.log 3002)"
[ "$(grep -c 'retry off for the rest of this tick' "$LOGF")" = 1 ] && ok || bad "S3: exactly one 'retry off' line"
grep -q 'retry_off=1' <<<"$(summary)" && ok || bad "S3: summary: '$(summary)'"

# S4 listing page 1 answers 502, then 200: 2 listing calls, 0 issue GETs
reset_state; held_rows 3001 3003; printf '502\n200\n' > "$GF/listing.codes"
run_pool
[ "$(reads listing-reads.log)" = 2 ] && [ "$(reads issue-reads.log)" = 0 ] && ok \
  || bad "S4: 2 listing calls and 0 issue GETs, got $(reads listing-reads.log) and $(reads issue-reads.log)"
[ "$(grep -c 'skipping BH-300[1-3]: HOLD (held' "$LOGF")" = 3 ] && ok || bad "S4: the three rows decided"

# S5 a held verdict whose text says "unreadable" is not retried
reset_state; held_rows 3001 3001
echo '[{"id":101,"created_at":"2026-10-13T19:00:00Z","body":"HOLD — the last log was unreadable","user":{"login":"fixture-person","type":"User"}}]' > "$GF/comments-3001.json"
run_pool
grep -q 'skipping BH-3001: HOLD (held' "$LOGF" && ok || bad "S5: held: $(grep 3001 "$LOGF")"
[ "$(reads_of comment-reads.log 3001)" = 1 ] && ok || bad "S5: one comments read, made $(reads_of comment-reads.log 3001)"

# S6 pool_hold_read alone (lifted out of bin/fly-pool.sh): a why that no
# second read can change is not retried; a cut read is.
(
  eval "$(awk '/^pool_hold_read\(\) \{/,/^}/' "$DIR/bin/fly-pool.sh")"
  command -v pool_hold_read >/dev/null 2>&1 || { echo "FAIL: S6: pool_hold_read is not in bin/fly-pool.sh"; exit 1; }
  declare -A _POOL_HOLD_IJ=(); _PHR_BATCHED=0; _PHR_RETRIES=0; _PHR_RETRY_OK=0; _PHR_RETRY_OFF=0
  say() { :; }; CALLS=0; f=0
  for why in "missing slug or ticket" "no issue number to read" "jq is not on PATH" "no owner/repo to read" "no issue json to classify"; do
    : > "$T/s6.calls"
    pool_hold_check() { echo x >> "$T/s6.calls"; printf 'unreadable\t%s\n' "$WHY"; return 2; }
    WHY="$why" pool_hold_read 3001
    [ "$(grep -c . "$T/s6.calls")" = 1 ] && [ "$_PHR_RETRIES" = 0 ] || { echo "FAIL: S6: '$why' must be read once, read $(grep -c . "$T/s6.calls")"; f=1; }
  done
  : > "$T/s6.calls"
  WHY="gh api repos/x/issues/5/comments answered rc=124" pool_hold_read 3001
  [ "$(grep -c . "$T/s6.calls")" = 2 ] && [ "$_PHR_RETRIES" = 1 ] && [ "$_PHR_RETRY_OFF" = 1 ] || { echo "FAIL: S6: a cut read must be retried once"; f=1; }
  exit "$f"
) && ok || bad "S6: section S6 (lines above)"

# ════ Section R: real holds ════════════════════════════════════════════════
# R1 a HOLD comment holds the row through the batch path
reset_state; held_rows 3001 3001
run_pool
grep -q 'skipping BH-3001: HOLD (held	hold:comment' "$LOGF" && [ "$(reads issue-reads.log)" = 0 ] && ok \
  || bad "R1: held by the comment with 0 issue GETs: $(grep 3001 "$LOGF")"
[ -f "$PD/BH-3001.held" ] && ok || bad "R1: the .held marker must be written"
# R2 HOLD then RESUME: not skipped, the earlier .held cleared
reset_state; held_rows 3001 3001; printf '%s\n' "$RESUME_THREAD" > "$GF/comments-3001.json"
printf '{"key":"BH-3001","why":"fixture"}\n' > "$PD/BH-3001.held"
run_pool
grep -q 'skipping BH-3001: HOLD' "$LOGF" && bad "R2: BH-3001 is resumed and must not be skipped as HOLD" || ok
[ -e "$PD/BH-3001.held" ] && bad "R2: BH-3001.held must be gone" || ok
[ "$(reads issue-reads.log)" = 0 ] && ok || bad "R2: 0 issue GETs"
# R3 a hold label in the listing holds the row
reset_state; queue 3001; echo '[]' > "$GF/comments-3001.json"
jq -sc . <<<"$(item 3001 '[{"name":"ai-build"},{"name":"hold"}]')" > "$GF/listing-1.json"
run_pool
grep -q "skipping BH-3001: HOLD (held${TAB}hold:label hold)" "$LOGF" && ok || bad "R3: held by the label: $(grep 3001 "$LOGF")"

echo "pool-hold-batch.bh-7942: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
