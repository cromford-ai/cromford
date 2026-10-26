#!/bin/bash
# tests/pool-hold-cache.bh-6549-test.sh — the pool keeps each issue's HOLD
# verdict in state/pool/<p>/hold-cache/<n>.json, keyed on the issue's
# updated_at and comment count from ONE open-issue listing per tick, so a held
# ticket whose key did not change costs no thread read (BH-6549).
#
#   Section L  bin/lib/pool-hold-cache.sh alone: the decision table of phc_get,
#              the store rule of phc_put, the listing parse. `now` is passed in.
#   Section P  the real bin/fly-pool.sh as a subprocess against a scratch
#              harness (the tests/fly-pool-sibling-serial.bh-6374-test.sh
#              scaffold) with a gh stub that counts every thread read:
#              one line per `--paginate .../comments` in comment-reads.log, one
#              per `issues/<n>` GET in issue-reads.log, one per listing page in
#              listing-reads.log. 20 queued rows BH-2001..BH-2020 each carry a
#              person's `HOLD — do not build` comment.
#
# Fail-safe direction under test: the cache can keep a row held, never release
# one. A bad, expired, key-changed or lib-changed entry, or a listing that
# cannot be read, is a full read — today's path.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=1791860000   # 2026-10-13, pinned
TAB=$'\t'

# ════ Section L: the lib ════════════════════════════════════════════════════
# shellcheck source=bin/lib/pool-hold-cache.sh
. "$DIR/bin/lib/pool-hold-cache.sh" 2>/dev/null || bad "L0: bin/lib/pool-hold-cache.sh cannot be sourced"
LD="$T/l"; mkdir -p "$LD"
K='2026-10-13T20:00:00Z|1'
LIB='1234-5678'
entry() { # entry <n> <key> <lib> <at> <verdict> — the v1 shape phc_put writes
  jq -nc --arg n "$1" --arg k "$2" --arg l "$3" --argjson at "$4" --arg v "$5" \
    '{v:1,n:$n,key:$k,lib:$l,verdict:$v,at:$at}' > "$LD/$1.json"
}
get() { phc_get "$LD" "$@"; }

# L1 the listing parse: issues only, n<TAB>updated_at<TAB>comments
L1IN='[{"number":7,"updated_at":"2026-10-13T20:00:00Z","comments":1},
       {"number":8,"updated_at":"2026-10-13T21:00:00Z","comments":0},
       {"number":9,"updated_at":"2026-10-13T20:00:00Z","comments":3,"pull_request":{"url":"x"}},
       {"number":10,"updated_at":"2026-10-12T20:00:00Z","comments":12}]'
OUT=$(phc_listing_keys "$L1IN"); RC=$?
EXP=$(printf '7\t2026-10-13T20:00:00Z\t1\n8\t2026-10-13T21:00:00Z\t0\n10\t2026-10-12T20:00:00Z\t12')
[ "$RC" = 0 ] && [ "$OUT" = "$EXP" ] && ok || bad "L1: listing rows (rc $RC): '$OUT'"
phc_listing_keys '{"message":"Bad credentials"}' >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "L1: a non-array listing must be rc 2, got $RC"
phc_listing_keys 'not json' >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "L1: an unparsable listing must be rc 2, got $RC"
OUT=$(phc_listing_keys '[]'); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "L1: an empty page is rc 0 and no rows (rc $RC '$OUT')"

HV="held${TAB}hold:comment 2026-10-13T19:00:00Z HOLD — do not build"
entry 11 "$K" "$LIB" "$((NOW-60))" "$HV"
# L2 key differs by updated_at
get 11 '2026-10-13T20:05:00Z|1' "$LIB" 21600 "$NOW" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "L2: a changed updated_at must miss, got $RC"
# L3 key differs by comments only
get 11 '2026-10-13T20:00:00Z|2' "$LIB" 21600 "$NOW" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "L3: a changed comment count must miss, got $RC"
# L4 lib differs
get 11 "$K" '9999-5678' 21600 "$NOW" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "L4: a changed hold.sh must miss, got $RC"
# L5 age == ttl -> miss; L6 age == ttl-1 -> hit
entry 12 "$K" "$LIB" "$((NOW-100))" "$HV"
OUT=$(get 12 "$K" "$LIB" 100 "$NOW"); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "L5: age == ttl must miss (rc $RC '$OUT')"
OUT=$(get 12 "$K" "$LIB" 101 "$NOW"); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "$HV" ] && ok || bad "L6: age == ttl-1 must hit with the verdict (rc $RC '$OUT')"
# L7 ttl 0
get 11 "$K" "$LIB" 0 "$NOW" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "L7: ttl 0 must miss, got $RC"
# L8 empty key (the ticket is not in the listing), and an empty lib
get 11 "" "$LIB" 21600 "$NOW" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "L8: an empty key must miss, got $RC"
entry 18 "" "$LIB" "$((NOW-60))" "$HV"
get 18 "" "$LIB" 21600 "$NOW" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "L8: an empty key never matches a stored empty key, got $RC"
get 11 "$K" "" 21600 "$NOW" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "L8: an empty lib must miss, got $RC"
# L9 a hand-written clear never hits; nor does a stored closed/label-absent
entry 13 "$K" "$LIB" "$((NOW-60))" "clear${TAB}no-hold"
get 13 "$K" "$LIB" 21600 "$NOW" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "L9: a stored clear must miss, got $RC"
entry 13 "$K" "$LIB" "$((NOW-60))" "held${TAB}closed"
get 13 "$K" "$LIB" 21600 "$NOW" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "L9: a stored held closed must miss, got $RC"
entry 13 "$K" "$LIB" "$((NOW-60))" "held${TAB}label-absent"
get 13 "$K" "$LIB" 21600 "$NOW" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "L9: a stored held label-absent must miss, got $RC"
entry 13 "$K" "$LIB" "$((NOW-60))" "unreadable${TAB}HTTP 502"
get 13 "$K" "$LIB" 21600 "$NOW" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "L9: a stored unreadable must miss, got $RC"
# L10 the three held kinds hit
for v in "$HV" "held${TAB}hold:title HOLD: wait for the launch" "held${TAB}abandon:comment 2026-10-13T19:00:00Z ABANDON"; do
  entry 14 "$K" "$LIB" "$((NOW-60))" "$v"
  OUT=$(get 14 "$K" "$LIB" 21600 "$NOW"); RC=$?
  [ "$RC" = 0 ] && [ "$OUT" = "$v" ] && ok || bad "L10: '$v' must hit (rc $RC '$OUT')"
done
# L11 invalid JSON -> rc 3, nothing printed; L12 JSON with no key -> rc 3
printf '{not json' > "$LD/15.json"
OUT=$(get 15 "$K" "$LIB" 21600 "$NOW"); RC=$?
[ "$RC" = 3 ] && [ -z "$OUT" ] && ok || bad "L11: invalid JSON must be rc 3 and silent (rc $RC '$OUT')"
jq -nc --arg l "$LIB" --arg v "$HV" --argjson at "$((NOW-60))" '{v:1,n:"15",lib:$l,verdict:$v,at:$at}' > "$LD/15.json"
OUT=$(get 15 "$K" "$LIB" 21600 "$NOW"); RC=$?
[ "$RC" = 3 ] && [ -z "$OUT" ] && ok || bad "L12: a file with no key must be rc 3 (rc $RC '$OUT')"
# L16 .v other than 1 -> rc 3
jq -nc --arg k "$K" --arg l "$LIB" --arg v "$HV" --argjson at "$((NOW-60))" '{v:2,n:"15",key:$k,lib:$l,verdict:$v,at:$at}' > "$LD/15.json"
get 15 "$K" "$LIB" 21600 "$NOW" >/dev/null; RC=$?
[ "$RC" = 3 ] && ok || bad "L16: v 2 must be rc 3, got $RC"
# L17 an entry stamped in the future (clock moved back) misses
entry 16 "$K" "$LIB" "$((NOW+60))" "$HV"
get 16 "$K" "$LIB" 21600 "$NOW" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "L17: an entry from the future must miss, got $RC"
# absent file
get 17 "$K" "$LIB" 21600 "$NOW" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "L: an absent file must miss, got $RC"

# L13 the store table
PD13="$T/l13"
put() { phc_put "$PD13" "$@"; }
put 21 "$K" "$LIB" "$NOW" "$HV"; RC=$?
[ "$RC" = 0 ] && [ "$(jq -r .verdict "$PD13/21.json" 2>/dev/null)" = "$HV" ] && ok || bad "L13: held pause must be written (rc $RC)"
[ "$(jq -r '[.v,.n,.key,.lib,.at]|map(tostring)|join(" ")' "$PD13/21.json" 2>/dev/null)" = "1 21 $K $LIB $NOW" ] && ok \
  || bad "L13: the v1 fields: $(cat "$PD13/21.json" 2>/dev/null)"
put 22 "$K" "$LIB" "$NOW" "held${TAB}abandon:comment x ABANDON"; RC=$?
[ "$RC" = 0 ] && [ -f "$PD13/22.json" ] && ok || bad "L13: held abandon must be written (rc $RC)"
put 21 "$K" "$LIB" "$NOW" "held${TAB}closed"; RC=$?
[ "$RC" = 0 ] && [ ! -e "$PD13/21.json" ] && ok || bad "L13: held closed must remove the file (rc $RC)"
put 22 "$K" "$LIB" "$NOW" "held${TAB}label-absent"; RC=$?
[ "$RC" = 0 ] && [ ! -e "$PD13/22.json" ] && ok || bad "L13: held label-absent must remove the file (rc $RC)"
put 23 "$K" "$LIB" "$NOW" "$HV"
put 23 "$K" "$LIB" "$NOW" "clear${TAB}no hold"; RC=$?
[ "$RC" = 0 ] && [ ! -e "$PD13/23.json" ] && ok || bad "L13: clear must remove the file (rc $RC)"
put 24 "$K" "$LIB" "$NOW" "$HV"; cp "$PD13/24.json" "$T/l13-24.before"
put 24 "$K" "$LIB" "$((NOW+5))" "unreadable${TAB}HTTP 502"; RC=$?
[ "$RC" = 0 ] && cmp -s "$PD13/24.json" "$T/l13-24.before" && ok || bad "L13: unreadable must leave the file byte-equal (rc $RC)"
put 25 "" "$LIB" "$NOW" "$HV"; RC=$?
[ "$RC" = 0 ] && [ ! -e "$PD13/25.json" ] && ok || bad "L13: held with an empty key must write nothing (rc $RC)"
put 26 "$K" "" "$NOW" "$HV"; RC=$?
[ "$RC" = 0 ] && [ ! -e "$PD13/26.json" ] && ok || bad "L13: held with an empty lib must write nothing (rc $RC)"

# L14 round trip: TAB, ", \ and an em dash, byte-equal
RT="held${TAB}hold:comment 2026-10-13T19:00:00Z HOLD \"quoted\" back\\slash — dash"
put 27 "$K" "$LIB" "$NOW" "$RT"
OUT=$(phc_get "$PD13" 27 "$K" "$LIB" 21600 "$NOW"); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "$RT" ] && ok || bad "L14: round trip (rc $RC): '$OUT' != '$RT'"

# L15 a failed write leaves no partial file: the dest is a directory, and the
# cache dir is a regular file (works as root, where a read-only dir does not)
mkdir -p "$PD13/28.json"
put 28 "$K" "$LIB" "$NOW" "$HV"; RC=$?
LEFT=$(ls -A "$PD13" | grep -c '^\.28\.json\.')
[ "$RC" = 1 ] && [ -d "$PD13/28.json" ] && [ "$LEFT" = 0 ] && ok || bad "L15: a failed mv must be rc 1 with no tmp left (rc $RC, tmp $LEFT)"
: > "$T/l15-file"
phc_put "$T/l15-file" 29 "$K" "$LIB" "$NOW" "$HV"; RC=$?
[ "$RC" = 1 ] && [ ! -e "$T/l15-file/29.json" ] && ok || bad "L15: an unwritable cache dir must be rc 1, got $RC"

# ════ Section P: real pool ticks ════════════════════════════════════════════
H="$T/h"
QD="$H/state/build-queue/project-5"; PD="$H/state/pool/project-5"; MD="$H/state/fly-pool/project-5"
HC="$PD/hold-cache"; GF="$T/gh"
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
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
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
  *"ssh console"*) : ;;
  *"ssh sftp put"*) : ;;
  *"machines list"*) echo '[]' ;;
  *"machine run"*) printf 'Machine ID: 1234567890abcd\\n' ;;
esac
exit 0
FLY
# The gh stub serves everything from files under $GF:
#   listing-<page>.json / listing.code   the open ai-build issue listing
#   issue-<n>.json                       the issue object (default: open, ai-build)
#   comments-<n>.json / comments-<n>.fail the thread, or a failed read
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
  [ -e "$GF/comments-$n.fail" ] && { echo "HTTP 502: fixture failure" >&2; exit 1; }
  cat "$GF/comments-$n.json" 2>/dev/null || echo '[]'
  exit 0
fi
if [ "$inc" = 1 ]; then
  if [[ "$args" == *"issues?state=open"* ]]; then
    echo "$args" >> "$T/listing-reads.log"
    code=$(cat "$GF/listing.code" 2>/dev/null || echo 200)
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

HOLD_THREAD='[{"id":101,"created_at":"2026-10-13T19:00:00Z","body":"HOLD — do not build","user":{"login":"fixture-person","type":"User"}}]'
RESUME_THREAD='[{"id":101,"created_at":"2026-10-13T19:00:00Z","body":"HOLD — do not build","user":{"login":"fixture-person","type":"User"}},
                {"id":102,"created_at":"2026-10-13T21:00:00Z","body":"RESUME","user":{"login":"fixture-person","type":"User"}}]'
queue() { # queue <n>
  jq -nc --arg k "BH-$1" --arg t "$1" \
    '{ticket_id:$t,key:$k,attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-10-13T02:30:00Z"}' > "$QD/BH-$1.json"
}
listing_set() { # listing_set <n> <updated_at> <comments> — add or replace one issue
  local f="$GF/listing-1.json"
  [ -f "$f" ] || echo '[]' > "$f"
  jq -c --argjson n "$1" --arg u "$2" --argjson c "$3" \
    '[.[] | select(.number != $n)] + [{number:$n,updated_at:$u,comments:$c,state:"open"}]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
listing_drop() {
  local f="$GF/listing-1.json"
  jq -c --argjson n "$1" '[.[] | select(.number != $n)]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
reset_state() {
  local p
  for p in "$QD"/* "$MD"/* "$PD"/* "$GF"/* "$T/fly-calls" "$T/alert-calls" "$T/gh-post.txt" "$T/gh-sink.txt" \
           "$T/comment-reads.log" "$T/issue-reads.log" "$T/listing-reads.log"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  return 0
}
# fixture20: 20 held rows, each in the listing with a fixed key, plus one open
# pull request in the listing (a PR is never a ticket).
fixture20() {
  local n
  reset_state
  echo '[{"number":1999,"updated_at":"2026-10-13T20:00:00Z","comments":4,"pull_request":{"url":"fixture"}}]' > "$GF/listing-1.json"
  for n in $(seq 2001 2020); do
    queue "$n"; printf '%s\n' "$HOLD_THREAD" > "$GF/comments-$n.json"
    listing_set "$n" 2026-10-13T20:00:00Z 1
  done
}
summary() { grep -o 'hold cache: .*' "$H/logs/fly-pool.log"; }

# ── P1 + P10: tick 1 reads 20 threads, tick 2 reads none ───────────────────
fixture20
run_pool
[ "$(reads comment-reads.log)" = 20 ] && ok || bad "P1: tick 1 must read 20 threads, read $(reads comment-reads.log)"
NF=$(ls "$HC" 2>/dev/null | grep -c '^20[0-9][0-9]\.json$')
[ "$NF" = 20 ] && ok || bad "P1: tick 1 must leave 20 cache files, found $NF"
C1=$(reads comment-reads.log); I1=$(reads issue-reads.log)
run_pool
[ "$(( $(reads comment-reads.log) - C1 ))" = 0 ] && ok \
  || bad "P1: tick 2 over 20 unchanged held tickets must make 0 comment reads, made $(( $(reads comment-reads.log) - C1 ))"
[ "$(( $(reads issue-reads.log) - I1 ))" = 0 ] && ok \
  || bad "P1: tick 2 must make 0 issue reads, made $(( $(reads issue-reads.log) - I1 ))"
NS=$(grep -c 'skipping BH-20[0-9][0-9]: HOLD (held' "$H/logs/fly-pool.log")
[ "$NS" = 20 ] && ok || bad "P1: tick 2 must still log 20 HOLD skips, logged $NS"
NH=$(ls "$PD" | grep -c '^BH-20[0-9][0-9]\.held$')
[ "$NH" = 20 ] && ok || bad "P1: every .held marker must stay, found $NH"
grep -q 'machine run' "$T/fly-calls" 2>/dev/null && bad "P1: a held row reached a machine" || ok
[ "$(summary | grep -c .)" = 1 ] && ok || bad "P10: exactly one 'hold cache:' line per tick: $(summary)"
grep -q 'hits=20 misses=0 bad=0 listing=ok ' <<<"$(summary)" && ok || bad "P10: the tick-2 summary: '$(summary)'"
grep -q 'pool project-5: .*hold cache' "$H/logs/fly-pool.log" && bad "P10: the summary must not wear the 'pool <p>:' prefix" || ok
grep -q 'skipping\|HOLD' <<<"$(summary)" && bad "P10: the summary must not contain 'skipping' or 'HOLD'" || ok
[ "$(reads listing-reads.log)" = 2 ] && ok || bad "P1: one listing page per tick, read $(reads listing-reads.log)"

# ── P2: 2003's key changes and its thread ends with RESUME ─────────────────
C2=$(reads comment-reads.log)
listing_set 2003 2026-10-13T21:00:00Z 2
printf '%s\n' "$RESUME_THREAD" > "$GF/comments-2003.json"
run_pool
[ "$(( $(reads comment-reads.log) - C2 ))" = 1 ] && [ "$(tail -n 1 "$T/comment-reads.log")" = 2003 ] && ok \
  || bad "P2: exactly one new read (2003), got $(( $(reads comment-reads.log) - C2 )): $(tail -n 3 "$T/comment-reads.log" | tr '\n' ' ')"
grep -q 'skipping BH-2003: HOLD' "$H/logs/fly-pool.log" && bad "P2: BH-2003 is resumed and must not be skipped as HOLD" || ok
[ -e "$PD/BH-2003.held" ] && bad "P2: BH-2003.held must be gone" || ok
[ -e "$HC/2003.json" ] && bad "P2: hold-cache/2003.json must be gone" || ok
[ "$(grep -c 'skipping BH-20[0-9][0-9]: HOLD' "$H/logs/fly-pool.log")" = 19 ] && ok || bad "P2: the other 19 rows stay held"

# ── P3: a clear ticket is not cached; a later HOLD is read next tick ───────
reset_state
echo '[]' > "$GF/listing-1.json"
listing_set 2021 2026-10-13T20:00:00Z 0
queue 2021
run_pool
[ "$(reads_of comment-reads.log 2021)" = 1 ] && ok || bad "P3: the clear ticket is read once"
[ -e "$HC/2021.json" ] && bad "P3: a clear verdict must not be cached" || ok
for p in "$MD"/*.json; do [ -e "$p" ] && scratch_rm "$p"; done
printf '%s\n' "$HOLD_THREAD" > "$GF/comments-2021.json"
listing_set 2021 2026-10-13T21:30:00Z 1
queue 2021
run_pool
[ "$(reads_of comment-reads.log 2021)" = 2 ] && ok || bad "P3: the re-held ticket is read on the next tick"
grep -q 'skipping BH-2021: HOLD' "$H/logs/fly-pool.log" && ok || bad "P3: the new HOLD must be seen: $(grep 2021 "$H/logs/fly-pool.log")"

# ── P4: a corrupt cache file is a re-read that stays held ──────────────────
fixture20; run_pool
C4=$(reads comment-reads.log)
printf '{not json' > "$HC/2001.json"
run_pool
[ "$(( $(reads comment-reads.log) - C4 ))" = 1 ] && [ "$(tail -n 1 "$T/comment-reads.log")" = 2001 ] && ok \
  || bad "P4: a bad file must re-read exactly 2001, read $(( $(reads comment-reads.log) - C4 ))"
grep -q 'skipping BH-2001: HOLD' "$H/logs/fly-pool.log" && ok || bad "P4: BH-2001 must stay held"
jq -e '.v == 1' "$HC/2001.json" >/dev/null 2>&1 && ok || bad "P4: 2001.json must parse again"
grep -q 'bad=1 ' <<<"$(summary)" && ok || bad "P4: the summary must count the bad file: '$(summary)'"

# ── P5: the listing answers 500: every row is a full read, all stay held ───
fixture20; run_pool
C5=$(reads comment-reads.log)
echo 500 > "$GF/listing.code"
run_pool
[ "$(( $(reads comment-reads.log) - C5 ))" = 20 ] && ok || bad "P5: an unreadable listing must re-read all 20, read $(( $(reads comment-reads.log) - C5 ))"
[ "$(grep -c 'skipping BH-20[0-9][0-9]: HOLD' "$H/logs/fly-pool.log")" = 20 ] && ok || bad "P5: all 20 stay held"
grep -q 'listing=unreadable(500)' <<<"$(summary)" && ok || bad "P5: the summary must name the listing: '$(summary)'"

# ── P6: listing 500 AND 2001's thread read fails: held, never released ─────
: > "$GF/comments-2001.fail"
: > "$T/fly-calls"
run_pool
grep -q 'skipping BH-2001: hold check unreadable' "$H/logs/fly-pool.log" && ok || bad "P6: BH-2001 must be skipped as unreadable: $(grep 2001 "$H/logs/fly-pool.log")"
[ -f "$PD/BH-2001.held" ] && ok || bad "P6: BH-2001.held must be kept"
grep -q 'machine run' "$T/fly-calls" && bad "P6: no machine may run for BH-2001" || ok
[ -f "$QD/BH-2001.json" ] && ok || bad "P6: BH-2001's queue file must stay"

# ── P7: a changed hold.sh invalidates every entry ──────────────────────────
# The changed lib stays for the cases below: each warm tick keys the cache to
# the hold.sh it finds, so nothing restores it.
fixture20; run_pool
C7=$(reads comment-reads.log)
printf '# fixture: the classifier changed on a sync\n' >> "$H/bin/lib/hold.sh"
run_pool
[ "$(( $(reads comment-reads.log) - C7 ))" = 20 ] && ok || bad "P7: a hold.sh change must re-read all 20, read $(( $(reads comment-reads.log) - C7 ))"

# ── P8: TTL 0 is off; an expired entry is a re-read ────────────────────────
# POOL_UNBLOCK_RANK=0: the unblock rank (BH-7874) reads the same listing for its
# own use; off here, the count below is the hold cache's alone.
fixture20; run_pool POOL_HOLD_CACHE_TTL_S=0 POOL_UNBLOCK_RANK=0
C8=$(reads comment-reads.log)
run_pool POOL_HOLD_CACHE_TTL_S=0 POOL_UNBLOCK_RANK=0
[ "$(( $(reads comment-reads.log) - C8 ))" = 20 ] && ok || bad "P8: TTL 0 must read all 20, read $(( $(reads comment-reads.log) - C8 ))"
[ "$(reads listing-reads.log)" = 0 ] && ok || bad "P8: TTL 0 must make no listing read, made $(reads listing-reads.log)"
grep -q 'listing=off .*ttl_s=0' <<<"$(summary)" && ok || bad "P8: the summary must say the cache is off: '$(summary)'"
fixture20; run_pool
C8=$(reads comment-reads.log)
jq -c '.at = 1000' "$HC/2001.json" > "$T/2001.tmp" && cp "$T/2001.tmp" "$HC/2001.json"
run_pool
[ "$(( $(reads comment-reads.log) - C8 ))" = 1 ] && ok || bad "P8: an expired entry must re-read once, read $(( $(reads comment-reads.log) - C8 ))"
run_pool POOL_HOLD_CACHE_TTL_S=soon
grep -q 'POOL_HOLD_CACHE_TTL_S=soon is not' "$H/logs/fly-pool.log" && ok || bad "P8: a non-number TTL must be said once"
grep -q 'ttl_s=21600' <<<"$(summary)" && ok || bad "P8: a non-number TTL falls back to 21600: '$(summary)'"

# ── P9: a closed ticket is parked and its entry removed ────────────────────
fixture20; run_pool
listing_drop 2005
echo '{"state":"closed","labels":[{"name":"ai-build"}],"title":"fixture ticket","body":"fixture body"}' > "$GF/issue-2005.json"
run_pool
grep -q 'skipping BH-2005: closed — parking the row' "$H/logs/fly-pool.log" && ok || bad "P9: BH-2005 must be parked: $(grep 2005 "$H/logs/fly-pool.log")"
[ -e "$QD/BH-2005.json" ] && bad "P9: BH-2005's queue file must be gone" || ok
[ -e "$HC/2005.json" ] && bad "P9: hold-cache/2005.json must be removed" || ok

echo "pool-hold-cache.bh-6549: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
