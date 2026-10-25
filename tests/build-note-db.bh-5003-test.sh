#!/bin/bash
# tests/build-note-db.bh-5003-test.sh — BH-5003: a build note (the resolver's
# carried ruling, or a ci-replan brief) is a ledger row build_note/"<p> <KEY>"
# as well as the hub file, so a build on a box that is neither the hub nor a
# pool machine sees it, and reads it ONCE across every box.
#
# WHAT IS STUBBED. Two scratch harnesses, $T/hub and $T/box (and a pool-shaped
# $T/pool), each with the real bin/jobs-client.sh closure and the real
# bin/lib/build-note-db.sh closure installed by scratch_install_closure. They
# share one fake jobs worker: a `curl` first in PATH that keeps every ledger
# row in $T/ledger.json under flock and answers GET/PUT /api/ledger and
# POST /api/ledger/claim with the worker's own rule and shapes
# (worker/jobs/src/routes/ledger.js): GET a missing key 404; PUT is the blind
# upsert (detail COALESCEd, cut at 4000); the claim answers
# `{claimed, ledger, as_of}` and is taken when the row is absent, or not in a
# terminal status and (another status, or the same one older than stale_s).
# $T/mode = claim404 answers the claim like an undeployed worker
# (`{"error":"unknown endpoint","worker":"harness-jobs"}`, 404), claim503 a
# 503, down makes curl exit 7 (an outage).
#
# The pipeline code under test is the SHIPPED text, extracted by marker:
#   the `# >>> carried note` block of bin/lib/rb/plan.sh (the plan stage),
#   the `# >>> build-note relay` block of bin/fly-pool.sh (push_build_note),
#   the `# >>> test-tamper build note` block of bin/blocked-resolver.sh,
#   and br_ci_replan_note / br_ci_replan_floor from bin/lib/br/opt/cirepair.sh.
# The relay path /run/harness/ in the extracted plan block is rewritten to
# $T/run/ so the suite never reads or moves a real box's relay file.
#
# Cases:
#   W   the lib is wired: bin/run-build.sh, bin/fly-pool.sh and
#       bin/blocked-resolver.sh each have bin/lib/build-note-db.sh in their
#       source closure; the knob is registered (BUILD_NOTE_DB, default 1)
#   N1  the resolver's two writers put the note in the DB as `pending`
#   N2  (ticket AT) a build on another box gets the ruling in its plan prompt
#       from the DB, the row becomes `consumed`, pipeline.log names the DB
#   N3  a second build of the same key on another box gets nothing
#   N4  a relay-file consume (pool) and a local-file consume (hub) mark the row
#       `consumed`; a later DB read on another box gets nothing; a hub file
#       whose row another box consumed is not consumed again
#   N5  br_ci_replan_floor counts an un-suffixed hub ci-replan note whose row
#       is `consumed`, and not one whose row is `pending`
#   N6  push_build_note with the row `consumed` retires the hub file and pushes
#       nothing; with the row `pending` it pushes once and marks it `relayed`
#   N7  BUILD_NOTE_DB=0, a 404 claim route, and an outage are main's behaviour
#   N8  (review B1) a consumed/relayed row whose detail is an EARLIER note never
#       retires a newer hub file: the pool relays it, a hub build consumes it,
#       and (N5) the re-plan floor does not count it
#   M2  (mutation) plan.sh with the bn_take line removed fails N2
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/build-note-db.bh-5003-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "build-note-db: jq is required"; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "build-note-db: flock is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

LIB="$DIR/bin/lib/build-note-db.sh"
REG="$DIR/catalog/lanes.d/_lib.build-note-db.json"
HUB="$T/hub"; BOX="$T/box"; POOL="$T/pool"

# ── the fake worker ─────────────────────────────────────────────────────────
mkdir -p "$T/fakebin" "$T/run"
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
FXT="__FXT__"
m=GET; url=""; body=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m="$2"; shift 2 ;;
    --data-binary) body="$2"; shift 2 ;;
    -H|-m|--connect-timeout|-w) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$body" in @*) body=$(cat "${body#@}") ;; esac
printf '%s %s %s %s\n' "${JOBS_BOX:-?}" "$m" "$url" "$body" >> "$FXT/reqlog"
mode=$(cat "$FXT/mode" 2>/dev/null)
[ "$mode" = down ] && exit 7
path="${url#https://jobs.test}"; q=""
case "$path" in *\?*) q="${path#*\?}"; path="${path%%\?*}" ;; esac
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
L="$FXT/ledger.json"
reply() { printf '%s\n%s' "$2" "$1"; exit 0; }
exec 8>"$FXT/ledger.lock"; flock 8
[ -s "$L" ] || printf '{"rows":[]}' > "$L"
case "$m $path" in
  "GET /api/ledger")
    kind=""; key=""
    IFS='&' read -ra kv <<< "$q"
    for p in "${kv[@]}"; do
      v="${p#*=}"; v=$(printf '%b' "${v//%/\\x}")
      case "$p" in kind=*) kind="$v" ;; key=*) key="$v" ;; esac
    done
    row=$(jq -c --arg k "$kind" --arg v "$key" '[.rows[] | select(.kind == $k and .key == $v)] | first // empty' "$L")
    [ -n "$row" ] && reply 200 "{\"ledger\":$row}"
    reply 404 '{"error":"not found"}' ;;
  "PUT /api/ledger")
    jq --argjson b "$body" --arg t "$now" '
      ([.rows[] | select(.kind == $b.kind and .key == $b.key)] | first) as $o
      | .rows = ([.rows[] | select((.kind == $b.kind and .key == $b.key) | not)]
          + [{kind: $b.kind, key: $b.key, status: $b.status,
              actor: ($b.actor // $o.actor // null),
              detail: (($b.detail // null | if . == null then null else .[0:4000] end) // $o.detail // null),
              created_at: ($o.created_at // $t), updated_at: $t}])' "$L" > "$L.tmp" && mv -f "$L.tmp" "$L"
    row=$(jq -c --argjson b "$body" '[.rows[] | select(.kind == $b.kind and .key == $b.key)] | first' "$L")
    reply 200 "{\"ledger\":$row}" ;;
  "POST /api/ledger/claim")
    case "$mode" in
      claim404) reply 404 '{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
      claim503) reply 503 '{"error":"down"}' ;;
    esac
    st=$(jq -r '.stale_s | if type == "number" and . >= 30 and . <= 86400 then . else "" end' <<<"$body")
    [ -n "$st" ] || reply 400 '{"error":"stale_s must be an integer from 30 to 86400"}'
    cut=$(date -u -d "@$(( $(date -u +%s) - st ))" +%Y-%m-%dT%H:%M:%SZ)
    jq --argjson b "$body" --arg t "$now" --arg c "$cut" '
      ([.rows[] | select(.kind == $b.kind and .key == $b.key)] | first) as $o
      | (if $o == null then true
         elif (($b.terminal // []) | index($o.status)) != null then false
         elif $o.status != $b.status then true
         else ($o.updated_at < $c) end) as $w
      | if $w then
          .rows = ([.rows[] | select((.kind == $b.kind and .key == $b.key) | not)]
            + [{kind: $b.kind, key: $b.key, status: $b.status, actor: ($b.actor // $o.actor // null),
                detail: (($b.detail // null) // ($o.detail // null)),
                created_at: ($o.created_at // $t), updated_at: $t}])
        else . end
      | .claimed_last = $w' "$L" > "$L.tmp" && mv -f "$L.tmp" "$L"
    out=$(jq -c --argjson b "$body" --arg t "$now" '{claimed: .claimed_last,
      ledger: ([.rows[] | select(.kind == $b.kind and .key == $b.key)] | first), as_of: $t}' "$L")
    reply 200 "$out" ;;
esac
reply 404 '{"error":"unknown endpoint","worker":"harness-jobs"}'
SH
sed -i "s#__FXT__#$T#" "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
printf '{"rows":[]}' > "$T/ledger.json"

setmode() { printf '%s' "${1:-ok}" > "$T/mode"; }
row()     { jq -c --arg v "tproj $1" '[.rows[] | select(.kind == "build_note" and .key == $v)] | first // empty' "$T/ledger.json"; }
rowst()   { row "$1" | jq -r '.status // ""' 2>/dev/null; }
rowdet()  { row "$1" | jq -r '.detail // ""' 2>/dev/null; }
seed() { # seed <KEY> <status> <detail>
  jq --arg v "tproj $1" --arg s "$2" --arg d "$3" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    .rows = ([.rows[] | select((.kind == "build_note" and .key == $v) | not)]
      + [{kind: "build_note", key: $v, status: $s, actor: "seed", detail: $d, created_at: $t, updated_at: $t}])' \
    "$T/ledger.json" > "$T/ledger.tmp" && mv -f "$T/ledger.tmp" "$T/ledger.json"
}
setmode ok

# ── three harnesses with the real closures ─────────────────────────────────
for h in "$HUB" "$BOX" "$POOL"; do
  mkdir -p "$h/logs" "$h/state" "$h/builds"
  scratch_install_closure bin/jobs-client.sh "$h" >/dev/null || bad "install bin/jobs-client.sh closure into $h"
  scratch_install_closure bin/lib/build-note-db.sh "$h" >/dev/null 2>&1 \
    || bad "install the bin/lib/build-note-db.sh closure into $h (does the lib exist?)"
done
scratch_install_closure bin/lib/br/opt/cirepair.sh "$HUB" >/dev/null || bad "install cirepair.sh into the hub"

# ── W: wired into the real consumers, and the knob registered ──────────────
check "W the lib exists" '[ -r "$LIB" ]'
for s in bin/run-build.sh bin/fly-pool.sh bin/blocked-resolver.sh; do
  scratch_closure_list "$s" 2>/dev/null | grep -qx 'bin/lib/build-note-db.sh' && ok \
    || bad "W $s does not source bin/lib/build-note-db.sh (bn_* would be dead code there)"
done
KNOB=$(jq -r '.libs[] | select(.id == "build-note-db") | .file + " " + (.knobs[] | select(.env == "BUILD_NOTE_DB") | "\(.type) \(.default) \(.min) \(.max)")' "$REG" 2>/dev/null)
check "W _lib.build-note-db.json registers BUILD_NOTE_DB (int, default 1, 0..1) for bin/lib/build-note-db.sh (got '$KNOB')" \
  '[ "$KNOB" = "bin/lib/build-note-db.sh int 1 0 1" ]'

# Each runner is a subshell on one harness: the fake worker first in PATH, the
# real client and lib sourced from that harness, H unset.
on() { # on <harness> <box-name> <cmd...>
  local h="$1" b="$2"; shift 2
  ( export PATH="$T/fakebin:$PATH" HARNESS="$h" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
      JOBS_BOX="$b" JOBS_RETRIES=0 JOBS_TIMEOUT=5
    unset H
    . "$h/bin/jobs-client.sh" >/dev/null 2>&1 || exit 97
    [ -r "$h/bin/lib/build-note-db.sh" ] && . "$h/bin/lib/build-note-db.sh"
    say() { printf '%s\n' "$*" >> "$T/say.log"; }
    STAMP() { echo T; }
    "$@" )
}

# The plan stage's carried-note block, extracted from a plan.sh text.
cn_extract() { # cn_extract <plan.sh> <out>
  awk '/^# >>> carried note/{f=1;next} /^# <<< carried note/{exit} f' "$1" | sed "s#/run/harness/#$T/run/#g" > "$2"
}
cn_extract "$DIR/bin/lib/rb/plan.sh" "$T/cn.sh"
[ -s "$T/cn.sh" ] || bad "bin/lib/rb/plan.sh has no carried note block"
cn_block() { # cn_block <block> <build-dir> <KEY> — prints CARRIED_NOTE_LINE
  BUILD="$2"; PROJECT=tproj; KEY="$3"; mkdir -p "$BUILD"
  # shellcheck source=/dev/null
  . "$1"; printf '%s' "$CARRIED_NOTE_LINE"
}
cn_run() { # cn_run <harness> <box> <build-name> <KEY> [block]
  on "$1" "$2" cn_block "${5:-$T/cn.sh}" "$1/builds/$3" "$4"
}

# ── N1: the two resolver writers put the note in the DB ────────────────────
replan_note() { br_ci_replan_note tproj "$1" https://github.com/o/tproj/pull/9 red-twice 2 2 "- mechanical pushed abc1234"; }
H_on_hub() { H="$HUB"; . "$HUB/bin/lib/br/opt/cirepair.sh"; "$@"; }
on "$HUB" hub H_on_hub replan_note TK-9
check "N1 br_ci_replan_note writes the hub file" '[ "$(head -1 "$HUB/state/build-notes/tproj/TK-9.md" 2>/dev/null)" = "KIND: ci-replan" ]'
check "N1 build_note/\"tproj TK-9\" is pending ($(row TK-9))" '[ "$(rowst TK-9)" = pending ]'
check "N1 the row carries the note text" 'rowdet TK-9 | head -1 | grep -qx "KIND: ci-replan"'

awk '/# >>> test-tamper build note/{f=1;next} /# <<< test-tamper build note/{exit} f' "$DIR/bin/blocked-resolver.sh" > "$T/tamper.sh"
[ -s "$T/tamper.sh" ] || bad "N1 bin/blocked-resolver.sh has no '# >>> test-tamper build note' block"
tamper_arm() { # the arm's own variables, then its extracted text
  local p=tproj rkey=tproj-TK-7 tkey=TK-7 NOTES="$HUB/state/build-notes"
  local just="TEST-CHANGE: adjudicated ACCEPT by bin/blocked-resolver.sh on T. tests/x-test.sh case X3 pinned the removed flag."
  # shellcheck source=/dev/null
  . "$T/tamper.sh"
}
on "$HUB" hub tamper_arm
check "N1 the test-tamper arm writes the hub file" 'grep -q "^TEST-CHANGE: adjudicated ACCEPT" "$HUB/state/build-notes/tproj/TK-7.md" 2>/dev/null'
check "N1 the test-tamper ruling is pending in the DB ($(row TK-7))" '[ "$(rowst TK-7)" = pending ] && rowdet TK-7 | grep -q "TEST-CHANGE: adjudicated ACCEPT"'
check "N1 no NOT-in-the-DB line when the put landed" '! grep -q "NOT in the DB" "$T/say.log" 2>/dev/null'

# ── N2: a build on another box sees the ruling ─────────────────────────────
n2() { # n2 <block> <build-name> -> rc 0 when the AT holds on $BOX for TK-7
  local line b="$BOX/builds/$2"
  line=$(cn_run "$BOX" box "$2" TK-7 "$1")
  printf '%s' "$line" > "$T/n2.line"
  case "$line" in *"TEST-CHANGE: adjudicated ACCEPT"*) ;; *) echo "n2: CARRIED_NOTE_LINE lacks the ruling: $(head -c 200 "$T/n2.line")"; return 1 ;; esac
  grep -q "^TEST-CHANGE: adjudicated ACCEPT" "$b/carried-note.md" 2>/dev/null || { echo "n2: carried-note.md lacks the ruling"; return 1; }
  [ "$(rowst TK-7)" = consumed ] || { echo "n2: row is $(rowst TK-7), not consumed"; return 1; }
  grep -q 'source: db' "$b/pipeline.log" 2>/dev/null || { echo "n2: pipeline.log does not name the DB: $(cat "$b/pipeline.log" 2>/dev/null)"; return 1; }
  return 0
}
[ ! -e "$BOX/state/build-notes" ] && [ ! -e "$T/run/build-note-tproj-TK-7.md" ] || bad "N2 precondition: the box has no hub state and no relay file"
if out=$(n2 "$T/cn.sh" b1); then ok; else bad "N2 a build on another box gets the hub's ruling from the DB ($out)"; fi
check "N2 the hub's own file is untouched by the box (it stays the mirror)" '[ -s "$HUB/state/build-notes/tproj/TK-7.md" ]'
# TEST-CHANGE (BH-7970): the plan prompt text moved to prompts/stages/plan.md, where the token is ${CARRIED_NOTE_LINE}.
check "N2 the CC plan prompt interpolates \$CARRIED_NOTE_LINE" \
  'grep -qF "\${CARRIED_NOTE_LINE}" "$DIR/prompts/stages/plan.md"'

# ── N3: read once across boxes ─────────────────────────────────────────────
L3=$(cn_run "$BOX" box b2 TK-7)
check "N3 a second build of the key gets no carried note (line: $(printf '%.120s' "$L3"))" '[ -z "$L3" ] && [ ! -e "$BOX/builds/b2/carried-note.md" ]'
L3b=$(cn_run "$POOL" pool b1 TK-7)
check "N3 nor does a third box" '[ -z "$L3b" ]'

# ── N4: relay and local consumes mark the row ──────────────────────────────
seed TK-6 pending "KIND: ci-replan
relay copy"
printf 'KIND: ci-replan\nrelay copy\n' > "$T/run/build-note-tproj-TK-6.md"
L4=$(cn_run "$POOL" pool b6 TK-6)
check "N4 the pool build reads the relay file" 'case "$L4" in *NARROWER*) true ;; *) false ;; esac && grep -q "source: relay" "$POOL/builds/b6/pipeline.log"'
check "N4 the relay consume marks the row consumed ($(row TK-6))" '[ "$(rowst TK-6)" = consumed ]'
L4b=$(cn_run "$BOX" box b6 TK-6)
check "N4 a later DB read on another box gets nothing" '[ -z "$L4b" ]'

seed TK-5 pending "hub local ruling"
mkdir -p "$HUB/state/build-notes/tproj"; printf 'TEST-CHANGE: hub local ruling\n' > "$HUB/state/build-notes/tproj/TK-5.md"
setmode claim503
L4c=$(cn_run "$HUB" hub b5 TK-5)
setmode ok
check "N4 with the claim down, the hub build still consumes its local file (line: $(printf '%.80s' "$L4c"))" \
  'case "$L4c" in *"hub local ruling"*) true ;; *) false ;; esac && grep -q "source: local" "$HUB/builds/b5/pipeline.log"'
seed TK-4 pending "hub local ruling 4"
printf 'TEST-CHANGE: hub local ruling 4\n' > "$HUB/state/build-notes/tproj/TK-4.md"
L4d=$(cn_run "$HUB" hub b4 TK-4)
check "N4 a hub build consumes the note once (line: $(printf '%.80s' "$L4d"))" \
  'case "$L4d" in *"hub local ruling 4"*) true ;; *) false ;; esac && [ ! -e "$HUB/state/build-notes/tproj/TK-4.md" ]'
check "N4 and the row is consumed ($(row TK-4))" '[ "$(rowst TK-4)" = consumed ]'
L4e=$(cn_run "$BOX" box b4 TK-4)
check "N4 so another box gets nothing" '[ -z "$L4e" ]'
seed TK-3 consumed "TEST-CHANGE: used on a watcher"
printf 'TEST-CHANGE: used on a watcher\n' > "$HUB/state/build-notes/tproj/TK-3.md"
L4f=$(cn_run "$HUB" hub b3 TK-3)
check "N4 a hub file whose row another box consumed is not consumed again (line: $(printf '%.80s' "$L4f"))" \
  '[ -z "$L4f" ] && [ ! -e "$HUB/state/build-notes/tproj/TK-3.md" ] && ls "$HUB/state/build-notes/tproj/TK-3.md.relayed-"* >/dev/null 2>&1'

# ── N5: the re-plan floor counts a note consumed elsewhere ─────────────────
printf 'KIND: ci-replan\nfloor\n' > "$HUB/state/build-notes/tproj/TK-2.md"
seed TK-2 consumed "KIND: ci-replan
floor"
F5=$(on "$HUB" hub H_on_hub br_ci_replan_floor tproj TK-2)
check "N5 an un-suffixed hub note whose row is consumed counts 1 (got '$F5')" '[ "$F5" = 1 ]'
seed TK-2 pending "KIND: ci-replan
floor"
F5b=$(on "$HUB" hub H_on_hub br_ci_replan_floor tproj TK-2)
check "N5 the same note still pending counts 0 (got '$F5b')" '[ "$F5b" = 0 ]'
seed TK-2 consumed "KIND: ci-replan
an EARLIER note"
F5c=$(on "$HUB" hub H_on_hub br_ci_replan_floor tproj TK-2)
check "N5 a consumed row left by an EARLIER note does not count this one (got '$F5c')" '[ "$F5c" = 0 ]'

# ── N6: the pool relay checks and marks the row ────────────────────────────
awk '/^# >>> build-note relay/{f=1;next} /^# <<< build-note relay/{exit} f' "$DIR/bin/fly-pool.sh" > "$T/bn.sh"
[ -s "$T/bn.sh" ] || bad "N6 bin/fly-pool.sh has no build-note relay block"
relay() { # relay <KEY> — push_build_note as the hub runs it, mput stubbed
  P=tproj
  mput() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$T/mput.txt"; }
  # shellcheck source=/dev/null
  . "$T/bn.sh"; push_build_note m1 "$1"
}
: > "$T/mput.txt"
printf 'KIND: ci-replan\nused\n' > "$HUB/state/build-notes/tproj/TK-1.md"
seed TK-1 consumed "KIND: ci-replan
used"
on "$HUB" hub relay TK-1
check "N6 a consumed row: nothing pushed ($(cat "$T/mput.txt"))" '[ ! -s "$T/mput.txt" ]'
check "N6 a consumed row: the hub file is retired to .relayed-*" \
  '[ ! -e "$HUB/state/build-notes/tproj/TK-1.md" ] && ls "$HUB/state/build-notes/tproj/TK-1.md.relayed-"* >/dev/null 2>&1'
printf 'KIND: ci-replan\nfresh\n' > "$HUB/state/build-notes/tproj/TK-10.md"
seed TK-10 pending "KIND: ci-replan"
on "$HUB" hub relay TK-10
check "N6 a pending row: pushed once" '[ "$(grep -c "^m1 .* /run/harness/build-note-tproj-TK-10.md$" "$T/mput.txt")" = 1 ]'
check "N6 a pending row: marked relayed after the push ($(row TK-10))" '[ "$(rowst TK-10)" = relayed ]'

# ── N8: a used-up row left by an EARLIER note never retires a newer one ────
# (review B1) The row outlives its note. Note #2 for the same key whose put did
# not land finds note #1's consumed row; that row says nothing about note #2.
: > "$T/mput.txt"
printf 'KIND: ci-replan\nsecond note\n' > "$HUB/state/build-notes/tproj/TK-20.md"
seed TK-20 consumed "TEST-CHANGE: the first note, used on a watcher"
on "$HUB" hub relay TK-20
check "N8 pool relay: note #2 is pushed despite note #1's consumed row ($(cat "$T/mput.txt"))" \
  '[ "$(grep -c "^m1 .* /run/harness/build-note-tproj-TK-20.md$" "$T/mput.txt")" = 1 ]'
check "N8 pool relay: the log does not claim another box used it" \
  '! grep "already used on another box" "$T/say.log" 2>/dev/null | grep -q " TK-20 "'
check "N8 pool relay: the earlier row is left as it was ($(row TK-20))" \
  '[ "$(rowst TK-20)" = consumed ] && [ "$(rowdet TK-20)" = "TEST-CHANGE: the first note, used on a watcher" ]'
printf 'TEST-CHANGE: second ruling\n' > "$HUB/state/build-notes/tproj/TK-21.md"
seed TK-21 relayed "TEST-CHANGE: first ruling"
L8=$(cn_run "$HUB" hub b21 TK-21)
check "N8 hub build: note #2 is consumed, not retired (line: $(printf '%.80s' "$L8"))" \
  'case "$L8" in *"second ruling"*) true ;; *) false ;; esac && grep -q "source: local" "$HUB/builds/b21/pipeline.log" \
   && ! ls "$HUB/state/build-notes/tproj/TK-21.md.relayed-"* >/dev/null 2>&1'

# ── N7: knob 0, an undeployed claim route, an outage ───────────────────────
# knob 0: no DB write, the box sees nothing, the hub's file path works.
k0() { BUILD_NOTE_DB=0 "$@"; }
: > "$T/say.log"
on "$HUB" hub k0 H_on_hub replan_note TK-11
check "N7 knob 0: the hub file is written" '[ -s "$HUB/state/build-notes/tproj/TK-11.md" ]'
check "N7 knob 0: no DB row ($(row TK-11))" '[ -z "$(row TK-11)" ]'
check "N7 knob 0: the writer says the note is not in the DB" 'grep -q "build note NOT in the DB — only hub/pool builds will see it" "$T/say.log"'
seed TK-11 pending "KIND: ci-replan
from the db"
L7=$(on "$BOX" box k0 cn_block "$T/cn.sh" "$BOX/builds/b11" TK-11)
check "N7 knob 0: a box build does not read or consume the row" '[ -z "$L7" ] && [ "$(rowst TK-11)" = pending ]'
L7b=$(on "$HUB" hub k0 cn_block "$T/cn.sh" "$HUB/builds/b11" TK-11)
check "N7 knob 0: the hub build consumes its local file as on main" \
  'case "$L7b" in *NARROWER*) true ;; *) false ;; esac && [ ! -e "$HUB/state/build-notes/tproj/TK-11.md" ] && [ "$(rowst TK-11)" = pending ]'

# claim route 404: nothing consumed from the DB, the row stays pending.
setmode claim404
seed TK-12 pending "TEST-CHANGE: 404 case"
L7c=$(cn_run "$BOX" box b12 TK-12)
check "N7 claim 404: the box build sees nothing and the row stays pending" '[ -z "$L7c" ] && [ "$(rowst TK-12)" = pending ] && [ ! -e "$BOX/builds/b12/carried-note.md" ]'
printf 'TEST-CHANGE: 404 case\n' > "$HUB/state/build-notes/tproj/TK-12.md"
L7d=$(cn_run "$HUB" hub b12 TK-12)
check "N7 claim 404: the hub build consumes its local file" 'case "$L7d" in *"404 case"*) true ;; *) false ;; esac'

# outage: the put fails and says so, the box sees nothing, the hub file works.
setmode down; : > "$T/say.log"
on "$HUB" hub H_on_hub replan_note TK-13
check "N7 outage: the hub file is written" '[ -s "$HUB/state/build-notes/tproj/TK-13.md" ]'
check "N7 outage: the writer says the note is not in the DB" 'grep -q "build note NOT in the DB — only hub/pool builds will see it" "$T/say.log"'
L7e=$(cn_run "$BOX" box b13 TK-13)
check "N7 outage: a box build gets nothing" '[ -z "$L7e" ]'
L7f=$(cn_run "$HUB" hub b13 TK-13)
check "N7 outage: the hub build consumes its local file" 'case "$L7f" in *NARROWER*) true ;; *) false ;; esac'
: > "$T/mput.txt"
on "$HUB" hub relay TK-13 2>/dev/null
printf 'KIND: ci-replan\nout\n' > "$HUB/state/build-notes/tproj/TK-14.md"
on "$HUB" hub relay TK-14
check "N7 outage: push_build_note still relays the hub file" '[ "$(grep -c "build-note-tproj-TK-14.md$" "$T/mput.txt")" = 1 ]'
setmode ok

# ── M2: a plan.sh without the bn_take call fails N2 ────────────────────────
# The call is replaced by `false` rather than its line deleted, so the mutant
# still parses: a mutant that fails on a syntax error proves nothing.
grep -q 'bn_take "\$PROJECT" "\$KEY"' "$DIR/bin/lib/rb/plan.sh" || bad "M2 plan.sh has no bn_take \"\$PROJECT\" \"\$KEY\" call to remove"
sed 's/bn_take "\$PROJECT" "\$KEY" "\$BUILD\/carried-note.md"/false/' "$DIR/bin/lib/rb/plan.sh" > "$T/plan.mut.sh"
cn_extract "$T/plan.mut.sh" "$T/cn.mut.sh"
check "M2 the mutant block parses and no longer calls bn_take" 'bash -n "$T/cn.mut.sh" && ! grep -qF "bn_take \"\$PROJECT\"" "$T/cn.mut.sh" && grep -qF "bn_take \"\$PROJECT\"" "$T/cn.sh"'
seed TK-7 pending "TEST-CHANGE: adjudicated ACCEPT by bin/blocked-resolver.sh on T. mutant run"
if n2 "$T/cn.mut.sh" m1 >/dev/null; then bad "M2 the mutant (no bn_take) still passes N2 — N2 does not prove the DB read"; else ok; fi
seed TK-7 pending "TEST-CHANGE: adjudicated ACCEPT by bin/blocked-resolver.sh on T. real run"
if out=$(n2 "$T/cn.sh" m2); then ok; else bad "M2 control: the shipped block passes N2 on a re-seeded row ($out)"; fi

echo "build-note-db: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
