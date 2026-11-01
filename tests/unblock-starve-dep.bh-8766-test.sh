#!/bin/bash
# tests/unblock-starve-dep.bh-8766-test.sh — BH-8766: Tackler gives no starve
# card for a ticket that waits on an open Blocked-by parent, or that is under
# its own starve thresholds; a stuck parent gets ONE card that names it; a
# card whose recommended option is `wait` goes out as a warn, not critical.
#
# Evidence: card u-5e109c (2026-10-29 00:38Z) paged CRITICAL for BH-8325
# "queued 51m, 1 pass" while BH-8325 was PLAN_BLOCKED after BH-8324 (open PR
# #8721).
#
#   D1-D2   the threshold gate: a record under either UNBLOCK_STARVE_MIN or
#           UNBLOCK_STARVE_PASSES is dropped with one `starve-skip ... under
#           thresholds` line; 120m/3p (equal) is kept.
#   D3-D9   the dependency read from the newest builds/pool-<p>-<KEY>-*/
#           record: plan-blocked.after with no plan-blocked.released, or a
#           RESULT `BUILD_DEFERRED stack-wait ... Blocked-by #N`. Near misses
#           (released, an older record, no `#N`, a child token, a Blocked-by
#           in a non-stack-wait RESULT, no record) keep the record.
#   D10-D13 the parent read through gh_rest: all closed keeps the record; an
#           unread parent skips it (rc 0, a `state unread` line); one open of
#           two skips it.
#   D14-D16 a parent open and idle >= UNBLOCK_STACK_PARENT_STALE_H (24) is
#           ONE stack-parent-stuck record per parent (children folded); U12
#           cards it and the card subject is the parent.
#   D17-D21 card.sh: recommended `wait...` -> lane-alert --severity warn, no
#           --critical; hold, waiting, do not wait, await, no RECOMMEND, an
#           unreadable file -> today's exact critical argv. REMINDER too.
#   D21b    recommendation 0 with a last `wait` option: critical (no
#           .options[-1] read).
#   D22-D23 the BH-8325 replay through the REAL bin/unblock.sh tick (act,
#           UNBLOCK_ACT=1): 0 claims, 0 alerts, one starve-skip line.
#   D24     6 parents over UNBLOCK_STACK_PARENT_MAX (5): no parent read, the
#           list is unread (`waits on over 5 parents: not read`), not dropped.
#           D24b: the knob at 6 reads all 6.
#   D25     an unread parent holds the record only while queued_min <
#           UNBLOCK_STACK_PARENT_STALE_H * 60; D25b: at 1440m the record goes
#           out with dep_unread and decides U13-STARVE.
#   D26     a project with a board prefix in fleet.conf: 0 gh calls, unread.
#   B       0 non-GET gh calls, 0 model or curl calls in every case.
#
# MUTATIONS (D1), each tried once by hand: drop the threshold gate -> D1, D2
# and D22 red; drop the dependency read -> D3, D6, D12 and D23 red; make
# _unblock_card_severity always print critical -> D17 and D20 red; drop the
# recommendation range check -> D21b red; print the parent list when over
# the cap -> D24 red; drop the unread bound -> D25b red; drop the board-prefix
# gate -> D26 red.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/unblock-starve-dep.bh-8766-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
no() { FAIL=$((FAIL + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '     %s\n' "${2:0:1500}"; return 0; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want '$3' got '$2'"; fi; }
cnt() { if [ -f "$2" ]; then grep -c -- "$1" "$2"; else echo 0; fi; }

FX="$SRC/tests/fixtures/unblock/bh-8766"
RULES="$SRC/catalog/unblock-rules.d"
R=example-org/cromford
P=cromford
NOWS=$(jq -r .now "$FX/gh.json")
NOWE=$(date -u -d "$NOWS" +%s)
ISS="repos/$R/issues/8324"
PRQ="repos/$R/pulls?state=open&head=example-org:ticket/bh-8324&per_page=10"

# ═════ the vendor fakes ══════════════════════════════════════════════════════
mkdir -p "$T/pathbin"
cat > "$T/pathbin/gh" <<'SH'
#!/bin/bash
m=GET; p=; hdr=0
while [ $# -gt 0 ]; do
  case "$1" in api) ;; -i) hdr=1 ;; -X) m="$2"; shift ;; -H|--input|-F|-f) shift ;; *) p="$1" ;; esac
  shift
done
echo "$m $p" >> "$GH_LOG"
if [ "$m" != GET ]; then [ "$hdr" = 1 ] && printf 'HTTP/2 405\r\n\r\n'; echo '{"message":"fixture: writes refused"}'; exit 1; fi
st=$(jq -r --arg p "$p" '.gh_status[$p] // empty' "$GH_FX")
if [ -n "$st" ]; then [ "$hdr" = 1 ] && printf 'HTTP/2 %s\r\ncontent-type: application/json\r\n\r\n' "$st"; echo '{"message":"fixture error"}'; exit 1; fi
if jq -e --arg p "$p" '.gh | has($p)' "$GH_FX" >/dev/null; then
  [ "$hdr" = 1 ] && printf 'HTTP/2 200\r\ncontent-type: application/json\r\n\r\n'; jq -c --arg p "$p" '.gh[$p]' "$GH_FX"; exit 0
fi
[ "$hdr" = 1 ] && printf 'HTTP/2 404\r\ncontent-type: application/json\r\n\r\n'; echo '{"message":"Not Found"}'; exit 1
SH
for s in claude curl flyctl; do printf '#!/bin/bash\necho "%s $*" >> "$MODEL_LOG"\nexit 7\n' "$s" > "$T/pathbin/$s"; done
chmod +x "$T/pathbin/"*

# ═════ the collector harness ═════════════════════════════════════════════════
mkc() { # mkc <name> -> the case dir
  local C="$T/$1" f
  mkdir -p "$C/h/logs" "$C/h/builds" "$C/h/catalog"
  for f in bin/lib/unblock/collectors/infra.sh bin/lib/unblock/rules.sh bin/lib/unblock/card.sh \
           bin/lib/token-redact.sh bin/lib/gh-rest.sh bin/fleet-conf.sh; do
    scratch_install_closure "$f" "$C/h" >/dev/null || return 1
  done
  # The scratch fleet.conf (run exports FLEET_CONF): never the box's own.
  printf 'cromford example-org/cromford - - 3 hub 192.0.2.10\n' > "$C/h/fleet.conf"
  cp -R "$RULES" "$C/h/catalog/unblock-rules.d"
  cp "$FX/gh.json" "$C/fx.json"
  : > "$C/gh.log"; : > "$C/model.log"; : > "$C/unblock.log"; : > "$C/h/logs/pipeline-health.log"
  printf '%s' "$C"
}
fx() { # fx <case dir> <jq filter> [jq args...] — edit the gh fixture
  local C="$1" f="$2"; shift 2
  jq "$@" "$f" "$C/fx.json" > "$C/fx.new" && mv "$C/fx.new" "$C/fx.json"
}
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
# phl <case dir> <KEY> <min> <passes> — <passes> pipeline-health lines, 10 min
# apart, the newest at now with <min>.
phl() {
  local C="$1" k="$2" m="$3" n="$4" i back
  for ((i = n - 1; i >= 0; i--)); do
    back=$((i * 600))
    printf '%s %s %s queued %sm with no spawn — fly-dispatch/pool not picking it up\n' \
      "$(date -u -d "@$((NOWE - back))" '+%Y-%m-%d %H:%M:%SZ')" "$P" "$k" "$((m - i * 10))" >> "$C/h/logs/pipeline-health.log"
  done
}
# pool <case dir> <KEY> <age_s> <RESULT line> — a pool record dir, RESULT mtime
# now - age_s; prints the dir.
pool() {
  local d="$1/h/builds/pool-$P-$2-$(date -u -d "@$((NOWE - $3))" +%Y%m%d%H%M%S)"
  mkdir -p "$d"
  printf '%s\n' "$4" > "$d/RESULT"
  touch -d "@$((NOWE - $3))" "$d/RESULT"
  printf '%s' "$d"
}
# after <record dir> <key>... — plan-blocked-stop.sh:223's printf shape.
after() { local d="$1" k; shift; for k in "$@"; do printf 'After: %s\n' "$k"; done > "$d/plan-blocked.after"; }
SW_RESULT="BUILD_DEFERRED stack-wait: parent branch ticket/bh-8324 is still open and BH-8325 has waited 3h of STACK_WAIT_CAP_H=24h — Blocked-by #8324; the child builds after the parent merges"
PB_RESULT="PLAN_BLOCKED: on hold until #8324 merges"

run() { # run <case dir> [pre]
  local C="$1"
  (
    export HARNESS="$C/h" GH_FX="$C/fx.json" GH_LOG="$C/gh.log" MODEL_LOG="$C/model.log" PATH="$T/pathbin:$PATH" GH_ETAG=0 \
      TMPDIR="$C" HARNESS_TEST_SANDBOX=1 UNBLOCK_NOW="$NOWE" FLEET_CONF="$C/h/fleet.conf" REGISTRY_SOURCE=file
    . "$HARNESS/bin/lib/gh-rest.sh" || exit 9
    . "$HARNESS/bin/lib/unblock/collectors/infra.sh" || exit 9
    . "$HARNESS/bin/lib/unblock/rules.sh" || exit 9
    ubt_log() { printf '%s %s\n' "$(iso "$NOWE")" "$*" >> "$C/unblock.log"; }
    [ -n "${2:-}" ] && eval "$2"
    unblock_collect_infra --project "$P" --repo "$R" --family starve > "$C/records.jsonl"; echo "$?" > "$C/rc"
    HARNESS="$C/h" ub_rules_eval < "$C/records.jsonl" > "$C/decisions.jsonl"
    ub_rules_would_lines < "$C/decisions.jsonl" > "$C/would.txt"
  )
}
nrec() { jq -r --arg k "$2" 'select(.kind == $k) | .kind' "$1/records.jsonl" | grep -c .; }
nall() { grep -c . "$1/records.jsonl"; }
skips() { grep -c " starve-skip $P $2: " "$1/unblock.log"; }
skipline() { grep " starve-skip $P $2: " "$1/unblock.log" | head -n1 | sed 's/^[^ ]* //'; }
budget() {
  check "B $2: 0 non-GET gh calls" "$(grep -vc '^GET ' "$1/gh.log")" 0
  check "B $2: 0 model or network calls" "$(grep -c . "$1/model.log")" 0
}

# ═════ D1-D2: the threshold gate ═════════════════════════════════════════════
C=$(mkc d1) || { echo "FAIL: case setup"; exit 1; }
cp "$FX/pipeline-health.txt" "$C/h/logs/pipeline-health.log"
run "$C"
check "D1 BH-8325 51m/1p, no pool record: 0 records, 0 decisions" "$(nall "$C") $(grep -c . "$C/decisions.jsonl")" "0 0"
check "D1 one starve-skip line with the numbers" "$(skipline "$C" BH-8325)" "starve-skip $P BH-8325: under thresholds (51m of 120, 1 of 3 passes)"
check "D1 rc 0, 0 gh calls" "$(cat "$C/rc") $(grep -c . "$C/gh.log")" "0 0"
budget "$C" D1

C=$(mkc d2)
phl "$C" BH-8401 130 2; phl "$C" BH-8402 60 5; phl "$C" BH-8403 120 3
run "$C"
check "D2 130m/2p and 60m/5p: no record; 120m/3p (equal): kept" "$(jq -r .ticket "$C/records.jsonl" | tr '\n' ' ')" "BH-8403 "
check "D2 130m/2p skip line" "$(skipline "$C" BH-8401)" "starve-skip $P BH-8401: under thresholds (130m of 120, 2 of 3 passes)"
check "D2 60m/5p skip line" "$(skipline "$C" BH-8402)" "starve-skip $P BH-8402: under thresholds (60m of 120, 5 of 3 passes)"
check "D2 the kept record decides U13-STARVE" "$(jq -r '.rule_id' "$C/decisions.jsonl")" U13-STARVE
check "D2 one line per skipped ticket, none for the kept one" "$(skips "$C" BH-8401) $(skips "$C" BH-8402) $(skips "$C" BH-8403)" "1 1 0"
budget "$C" D2

C=$(mkc d2b)
phl "$C" BH-8401 130 2
run "$C" "export UNBLOCK_STARVE_PASSES=2"
check "D2b UNBLOCK_STARVE_PASSES=2 keeps 130m/2p" "$(nrec "$C" ticket-starved) $(jq -r .starve_passes "$C/records.jsonl")" "1 2"

# ═════ D3-D9: the dependency read ════════════════════════════════════════════
C=$(mkc d3)
phl "$C" BH-8325 130 3
D=$(pool "$C" BH-8325 600 "$PB_RESULT"); after "$D" BH-8324
run "$C"
check "D3 PLAN_BLOCKED after open BH-8324 (fresh PR): 0 records" "$(nall "$C")" 0
check "D3 the skip line names the open parent and its PR" "$(skipline "$C" BH-8325)" "starve-skip $P BH-8325: waits on open parent BH-8324 (PR #8721), idle 1h of 24h"
check "D3 one line" "$(skips "$C" BH-8325)" 1
check "D3 the parent was read: issue and PR, GET only" "$(grep -c "^GET $ISS\$" "$C/gh.log") $(grep -cF "GET $PRQ" "$C/gh.log")" "1 1"
budget "$C" D3

C=$(mkc d4)
phl "$C" BH-8325 130 3
D=$(pool "$C" BH-8325 600 "$PB_RESULT"); after "$D" BH-8324; : > "$D/plan-blocked.released"
run "$C"
check "D4 released: 1 ticket-starved, U13-STARVE" "$(nrec "$C" ticket-starved) $(jq -r .rule_id "$C/decisions.jsonl")" "1 U13-STARVE"
check "D4 no skip line, 0 gh calls" "$(skips "$C" BH-8325) $(grep -c . "$C/gh.log")" "0 0"

C=$(mkc d5)
phl "$C" BH-8325 130 3
D=$(pool "$C" BH-8325 7200 "$PB_RESULT"); after "$D" BH-8324
pool "$C" BH-8325 60 "BUILD_DEFERRED file overlap: bin/unblock.sh is in BH-8300's open PR" >/dev/null
run "$C"
check "D5 the newest RESULT is not a wait (older record has the after file): 1 record" "$(nrec "$C" ticket-starved)" 1

C=$(mkc d6)
phl "$C" BH-8325 130 3
pool "$C" BH-8325 600 "$SW_RESULT" >/dev/null
run "$C"
check "D6 stack-wait Blocked-by #8324, parent open: 0 records" "$(nall "$C")" 0
check "D6 the skip names BH-8324" "$(skipline "$C" BH-8325)" "starve-skip $P BH-8325: waits on open parent BH-8324 (PR #8721), idle 1h of 24h"

C=$(mkc d7)
phl "$C" BH-8325 130 3
pool "$C" BH-8325 600 "BUILD_DEFERRED stack-wait: parent branch ticket/bh-8324 is still open and BH-8325 has waited 3h of STACK_WAIT_CAP_H=24h — Blocked-by ticket/bh-8324; the child builds after the parent merges" >/dev/null
run "$C"
check "D7 stack-wait with no Blocked-by #N: 1 record, 0 gh calls" "$(nrec "$C" ticket-starved) $(grep -c . "$C/gh.log")" "1 0"

C=$(mkc d8)
phl "$C" BH-8325 130 3
D=$(pool "$C" BH-8325 600 "$PB_RESULT"); after "$D" 8324.1
run "$C"
check "D8 After: 8324.1 (a child token, dropped): 1 record, 0 gh calls" "$(nrec "$C" ticket-starved) $(grep -c . "$C/gh.log")" "1 0"

C=$(mkc d8b)
phl "$C" BH-8325 130 3
D=$(pool "$C" BH-8325 600 "$PB_RESULT"); after "$D" '#8324'
run "$C"
check "D8b After: #8324 normalizes to BH-8324 (open): 0 records" "$(nall "$C") $(grep -c "^GET $ISS\$" "$C/gh.log")" "0 1"

C=$(mkc d8c)
phl "$C" BH-8325 130 3
pool "$C" BH-8325 600 "BUILD_DEFERRED After: BH-8324 — Blocked-by #8324 not a stack-wait" >/dev/null
run "$C"
check "D8c Blocked-by #N in a non-stack-wait RESULT: 1 record" "$(nrec "$C" ticket-starved)" 1

C=$(mkc d8d)
phl "$C" BH-8325 130 3
pool "$C" BH-8325 600 "$PB_RESULT" >/dev/null
run "$C"
check "D8d PLAN_BLOCKED with no after file: 1 record" "$(nrec "$C" ticket-starved)" 1

C=$(mkc d9)
phl "$C" TK-2601 296 3
D=$(pool "$C" BH-9999 600 "$PB_RESULT"); after "$D" BH-8324
run "$C"
check "D9 296m/3p, no pool record of its own: 1 record" "$(nrec "$C" ticket-starved)" 1
check "D9 decides U13-STARVE WOULD_LAUNCH_FASTPATH" "$(grep -c '^WOULD_LAUNCH_FASTPATH U13-STARVE ticket:cromford:TK-2601 ' "$C/would.txt")" 1
check "D9 0 gh calls" "$(grep -c . "$C/gh.log")" 0
budget "$C" D9

# ═════ D10-D13: the parent state ═════════════════════════════════════════════
C=$(mkc d10)
phl "$C" BH-8325 130 3
D=$(pool "$C" BH-8325 600 "$PB_RESULT"); after "$D" BH-8324
fx "$C" '.gh[$i].state = "closed"' --arg i "$ISS"
run "$C"
check "D10 parent closed: 1 ticket-starved record" "$(nrec "$C" ticket-starved)" 1
check "D10 no skip line; a closed parent reads no PR" "$(skips "$C" BH-8325) $(grep -cF "GET $PRQ" "$C/gh.log")" "0 0"

C=$(mkc d11)
phl "$C" BH-8325 130 3
D=$(pool "$C" BH-8325 600 "$PB_RESULT"); after "$D" BH-8324
fx "$C" '.gh_status[$i] = "500"' --arg i "$ISS"
run "$C"
check "D11 parent read 500: rc 0, 0 records" "$(cat "$C/rc") $(nall "$C")" "0 0"
check "D11 the skip line says state unread" "$(skipline "$C" BH-8325)" "starve-skip $P BH-8325: waits on parent BH-8324: state unread"
budget "$C" D11

C=$(mkc d11b)
phl "$C" BH-8325 130 3
D=$(pool "$C" BH-8325 600 "$PB_RESULT"); after "$D" BH-8324
fx "$C" '.gh[$i] = []' --arg i "$ISS"
run "$C"
check "D11b a parent body that is not an issue object: unread, 0 records" "$(nall "$C") $(skips "$C" BH-8325)" "0 1"

C=$(mkc d12)
phl "$C" BH-8325 130 3
pool "$C" BH-8325 600 "$SW_RESULT" >/dev/null
run "$C"
check "D12 stack-wait child, open parent with an open PR: 0 escalate decisions" "$(jq -r 'select(.decision == "escalate") | .decision' "$C/decisions.jsonl" | grep -c .)" 0
check "D12 0 decisions at all" "$(grep -c . "$C/decisions.jsonl")" 0

C=$(mkc d13)
phl "$C" BH-8325 130 3
D=$(pool "$C" BH-8325 600 "$PB_RESULT"); after "$D" BH-8320 BH-8324
run "$C"
check "D13 one parent closed, one open: 0 records" "$(nall "$C")" 0
check "D13 the skip names the open one" "$(skipline "$C" BH-8325)" "starve-skip $P BH-8325: waits on open parent BH-8324 (PR #8721), idle 1h of 24h"

# ═════ D14-D16: the parent-stuck record ══════════════════════════════════════
stale() { # stale <case dir> <hours idle>
  fx "$1" '.gh[$q][0].updated_at = $t | .gh[$i].updated_at = "2026-10-20T00:00:00Z"' \
    --arg q "$PRQ" --arg i "$ISS" --arg t "$(iso $((NOWE - $2 * 3600)))"
}
C=$(mkc d14)
phl "$C" BH-8325 130 3
D=$(pool "$C" BH-8325 600 "$PB_RESULT"); after "$D" BH-8324
stale "$C" 25
run "$C"
check "D14 parent idle 25h: 1 stack-parent-stuck, 0 ticket-starved" "$(nrec "$C" stack-parent-stuck) $(nrec "$C" ticket-starved)" "1 0"
check "D14 the record names the parent" \
  "$(jq -r 'select(.kind == "stack-parent-stuck") | "\(.subject) \(.subject_kind) \(.parent) \(.parent_issue) \(.parent_pr) \(.parent_idle_h) \(.parent_stale_h) \(.children | join(",")) \(.dep_source) \(.head)"' "$C/records.jsonl")" \
  "ticket:$P:BH-8324 build BH-8324 8324 8721 25 24 BH-8325 after 8721872187218721872187218721872187218721"
check "D14 the child still gets its skip line" "$(skips "$C" BH-8325)" 1
cp "$C/records.jsonl" "$T/d14-records.jsonl"
budget "$C" D14

C=$(mkc d14b)
phl "$C" BH-8325 130 3
D=$(pool "$C" BH-8325 600 "$PB_RESULT"); after "$D" BH-8324
stale "$C" 25
run "$C" "export UNBLOCK_STACK_PARENT_STALE_H=48"
check "D14b UNBLOCK_STACK_PARENT_STALE_H=48: 0 records" "$(nall "$C")" 0

C=$(mkc d14c)
phl "$C" BH-8325 130 3
D=$(pool "$C" BH-8325 600 "$PB_RESULT"); after "$D" BH-8324
stale "$C" 23
run "$C"
check "D14c parent idle 23h (stale - 1h): 0 records" "$(nall "$C")" 0

C=$(mkc d14d)
phl "$C" BH-8325 130 3
pool "$C" BH-8325 600 "$SW_RESULT" >/dev/null
fx "$C" '.gh[$q] = [] | .gh[$i].updated_at = $t' --arg q "$PRQ" --arg i "$ISS" --arg t "$(iso $((NOWE - 30 * 3600)))"
run "$C"
check "D14d no parent PR, issue idle 30h: 1 record, pr null, head null, source stack-wait" \
  "$(jq -r 'select(.kind == "stack-parent-stuck") | "\(.parent_pr) \(.head) \(.parent_idle_h) \(.dep_source)"' "$C/records.jsonl")" "null null 30 stack-wait"

C=$(mkc d15)
(
  export HARNESS="$C/h" HARNESS_TEST_SANDBOX=1 TMPDIR="$C" MODEL_LOG="$C/model.log" PATH="$T/pathbin:$PATH" UB_NOW="$NOWE"
  . "$HARNESS/bin/lib/unblock/rules.sh" || exit 9
  . "$HARNESS/bin/lib/unblock/card.sh" || exit 9
  ub_rules_eval < "$T/d14-records.jsonl" > "$C/decisions.jsonl"
  d=$(head -n1 "$C/decisions.jsonl")
  UBT_CLAIMED_KEY=$(jq -r .decision_key <<<"$d") ubt_stage_card "$d" "" shadow > "$C/card.json"
)
check "D15 one escalate decision by U12" "$(jq -r '"\(.decision) \(.rule_id)"' "$C/decisions.jsonl" | tr '\n' ';')" "escalate U12;"
check "D15 the card subject is the parent" "$(jq -r '.card.subject' "$C/card.json") $(jq -r .outcome "$C/card.json")" "ticket:$P:BH-8324 would"
check "D15 the card's first line names the parent, not the child" "$(jq -r '.card.text | split("\n")[0] | test("ticket:cromford:BH-8324$")' "$C/card.json") $(jq -r '.card.text | split("\n")[0] | test("BH-8325")' "$C/card.json")" "true false"
case "$(jq -r '.card.options[1]' "$C/card.json")" in
  "look at parent BH-8324 (PR #8721) by hand; 1 ticket(s) wait on it") ok "D15 the fallback option 2 names the parent and its PR" ;;
  *) no "D15 the fallback option 2 names the parent and its PR" "$(jq -c .card.options "$C/card.json")" ;;
esac
check "D15 0 model calls" "$(jq -r .model_calls "$C/card.json") $(grep -c . "$C/model.log")" "0 0"

C=$(mkc d16)
phl "$C" BH-8325 130 3; phl "$C" BH-8326 140 4
D=$(pool "$C" BH-8325 600 "$PB_RESULT"); after "$D" BH-8324
pool "$C" BH-8326 600 "${SW_RESULT//BH-8325/BH-8326}" >/dev/null
stale "$C" 25
run "$C"
check "D16 two children, one stale parent: 1 record" "$(nall "$C") $(nrec "$C" stack-parent-stuck)" "1 1"
check "D16 children are both keys" "$(jq -r '.children | join(",")' "$C/records.jsonl")" "BH-8325,BH-8326"
check "D16 the parent is read once (the per-call cache)" "$(grep -c "^GET $ISS\$" "$C/gh.log")" 1
check "D16 one skip line per child" "$(skips "$C" BH-8325) $(skips "$C" BH-8326)" "1 1"
budget "$C" D16

# ═════ D17-D21: card severity ════════════════════════════════════════════════
K64=$(printf 'a%.0s' $(seq 64)); K12=${K64:0:12}
CH="$T/card-h"; mkdir -p "$CH/bin"
scratch_install_closure bin/lib/unblock/card.sh "$CH" >/dev/null && scratch_install_closure bin/lib/token-redact.sh "$CH" >/dev/null \
  || { echo "FAIL: card setup"; exit 1; }
cat > "$CH/bin/lane-alert.sh" <<'SH'
#!/bin/bash
head -n1 <<<"$*" >> "$ALOG"
exit 0
SH
chmod +x "$CH/bin/lane-alert.sh"
mkcard() { # mkcard <file> <recommended option text>
  jq -nc --arg k "$K64" --arg o "$2" '{id: "u-aaaaaa", key: $k, options: ["hold: keep it parked", $o, "relaunch it"],
    recommendation: 2, text: ("TACKLER CARD u-aaaaaa x\nOPTIONS:\n1. hold: keep it parked\n2. " + $o + "\nRECOMMEND: 2")}' > "$1"
}
send() { # send <card file> -> the lane-alert argv line, then the send line
  : > "$T/alerts.log"
  local out
  out=$(export HARNESS="$CH" ALOG="$T/alerts.log" UNBLOCK_ACT=1; . "$CH/bin/lib/unblock/card.sh"; unblock_card_send "$1" act)
  printf '%s | %s' "$(head -n1 "$T/alerts.log")" "$out"
}
mkcard "$T/c17.json" "wait for #8324 to merge"
check "D17 recommended 'wait for #8324 to merge': warn, no --critical" "$(send "$T/c17.json")" "--id unblock-$K12 --severity warn unblock TACKLER CARD u-aaaaaa x | SENT_CARD u-aaaaaa"
for o in "Wait: leave it" "WAIT"; do
  mkcard "$T/c17b.json" "$o"
  check "D17 recommended '$o': warn" "$(send "$T/c17b.json" | cut -d' ' -f1-4)" "--id unblock-$K12 --severity warn"
done
mkcard "$T/c18.json" "hold: keep it parked"
jq '.recommendation = 1' "$T/c18.json" > "$T/c18b.json"
check "D18 recommended 'hold: keep it parked': today's exact critical argv" "$(send "$T/c18b.json")" "--critical --id unblock-$K12 --severity critical unblock TACKLER CARD u-aaaaaa x | SENT_CARD u-aaaaaa"
for o in "waiting room cleanup" "do not wait: relaunch" "await the parent"; do
  mkcard "$T/c19.json" "$o"
  check "D19 recommended '$o': critical" "$(send "$T/c19.json" | cut -d' ' -f1-5)" "--critical --id unblock-$K12 --severity critical"
done
# D20: a reminder row with only .text; its RECOMMEND names a wait option.
row() { # row <file> <text>
  jq -nc --arg k "$K64" --arg t "$2" --arg dl "$(iso $((NOWE + 86400)))" --arg ld "$(iso $((NOWE - 90000)))" \
    '{id: "u-aaaaaa", key: $k, text: $t, deadline_at: $dl, last_declared_at: $ld}' > "$1"
}
remind() {
  : > "$T/alerts.log"
  local out
  out=$(export HARNESS="$CH" ALOG="$T/alerts.log" UNBLOCK_ACT=1; . "$CH/bin/lib/unblock/card.sh"; unblock_card_redeclare "$1" "$NOWE" act)
  printf '%s | %s' "$(head -n1 "$T/alerts.log" | cut -d' ' -f1-6)" "$out"
}
row "$T/r20.json" "$(printf 'TACKLER CARD u-aaaaaa ticket:cromford:BH-8324\nWHAT: 1. not an option\nOPTIONS:\n1. hold: keep it parked\n2. wait for #8324 to merge\nRECOMMEND: 2. the parent PR moves\nDEFAULT: x.')"
check "D20 a text-only row recommending 'wait ...': REMIND sent as warn" "$(remind "$T/r20.json")" "--id unblock-$K12 --severity warn unblock REMINDER: | REMIND u-aaaaaa"
row "$T/r20b.json" "$(printf 'TACKLER CARD u-aaaaaa x\nOPTIONS:\n1. hold: keep it parked\n2. wait for #8324 to merge\nRECOMMEND: 1\nDEFAULT: x.')"
check "D20b a text-only row recommending hold: REMIND stays critical" "$(remind "$T/r20b.json")" "--critical --id unblock-$K12 --severity critical unblock | REMIND u-aaaaaa"
row "$T/r21.json" "garbage with no recommend line"
check "D21 an unparseable row text: critical" "$(remind "$T/r21.json")" "--critical --id unblock-$K12 --severity critical unblock | REMIND u-aaaaaa"
printf 'not json' > "$T/c21.json"
check "D21 _unblock_card_severity on an unreadable file: critical" \
  "$( (. "$CH/bin/lib/unblock/card.sh"; _unblock_card_severity "$T/c21.json"; _unblock_card_severity "$T/nope.json") | tr '\n' ' ')" "critical critical "

jq -nc --arg k "$K64" '{id: "u-aaaaaa", key: $k, options: ["hold: keep it parked", "wait for #8324"], recommendation: 0,
  text: "TACKLER CARD u-aaaaaa x\nOPTIONS:\n1. hold: keep it parked\n2. wait for #8324"}' > "$T/c21b.json"
check "D21b recommendation 0, last option 'wait ...': critical" "$(send "$T/c21b.json" | cut -d' ' -f1-5)" "--critical --id unblock-$K12 --severity critical"

# ═════ D24-D26: the parent cap, the unread bound, a board project ═══════════
C=$(mkc d24)
phl "$C" BH-8325 130 3
D=$(pool "$C" BH-8325 600 "$PB_RESULT"); after "$D" BH-8320 BH-8321 BH-8322 BH-8323 BH-8324 BH-8319
run "$C"
check "D24 6 parents over the cap 5: 0 records, rc 0" "$(nall "$C") $(cat "$C/rc")" "0 0"
check "D24 the skip line says the list is not read" "$(skipline "$C" BH-8325)" "starve-skip $P BH-8325: waits on over 5 parents: not read"
check "D24 0 gh calls" "$(grep -c . "$C/gh.log")" 0
budget "$C" D24

C=$(mkc d24b)
phl "$C" BH-8325 130 3
D=$(pool "$C" BH-8325 600 "$PB_RESULT"); after "$D" BH-8319 BH-8320 BH-8321 BH-8322 BH-8323 BH-8324
for i in 8319 8320 8321 8322 8323 8324; do fx "$C" '.gh["repos/\($r)/issues/\($n)"] = {state: "closed", updated_at: "2026-10-28T00:00:00Z"}' --arg r "$R" --arg n "$i"; done
run "$C" "export UNBLOCK_STACK_PARENT_MAX=6"
check "D24b UNBLOCK_STACK_PARENT_MAX=6, all 6 closed: 1 ticket-starved" "$(nrec "$C" ticket-starved)" 1
check "D24b 6 issue GETs" "$(grep -c "^GET repos/$R/issues/83[12][0-9]\$" "$C/gh.log")" 6
budget "$C" D24b

C=$(mkc d25)
phl "$C" BH-8325 600 3
D=$(pool "$C" BH-8325 600 "$PB_RESULT"); after "$D" BH-8324
fx "$C" '.gh_status[$i] = "500"' --arg i "$ISS"
run "$C"
check "D25 unread parent, queued 600m < 1440m: 0 records" "$(nall "$C")" 0
check "D25 one state unread line" "$(skips "$C" BH-8325) $(skipline "$C" BH-8325)" "1 starve-skip $P BH-8325: waits on parent BH-8324: state unread"

C=$(mkc d25b)
phl "$C" BH-8325 1440 3
D=$(pool "$C" BH-8325 600 "$PB_RESULT"); after "$D" BH-8324
fx "$C" '.gh_status[$i] = "500"' --arg i "$ISS"
run "$C"
check "D25b unread parent, queued 1440m: 1 ticket-starved with dep_unread" "$(nrec "$C" ticket-starved) $(jq -r .dep_unread "$C/records.jsonl")" "1 BH-8324"
check "D25b it decides U13-STARVE, no skip line" "$(jq -r .rule_id "$C/decisions.jsonl") $(skips "$C" BH-8325)" "U13-STARVE 0"
budget "$C" D25b

C=$(mkc d26)
printf 'cromford example-org/cromford - /api/board 3 hub 192.0.2.10\n' > "$C/h/fleet.conf"
phl "$C" BH-8325 130 3
D=$(pool "$C" BH-8325 600 "$PB_RESULT"); after "$D" TK-123
run "$C"
check "D26 board project, After: TK-123: 0 records, 0 gh calls" "$(nall "$C") $(grep -c . "$C/gh.log")" "0 0"
check "D26 the skip line says state unread" "$(skipline "$C" BH-8325)" "starve-skip $P BH-8325: waits on parent TK-123: state unread"

# ═════ D22-D23: the BH-8325 replay through bin/unblock.sh tick ═══════════════
mktick() { # mktick <name> -> the case dir (copied from the bh-8418 suite's mktick, trimmed)
  local C="$T/$1" S
  mkdir -p "$C/h/env" "$C/h/state/merge-conductor" "$C/h/logs" "$C/h/builds" "$C/h/catalog/unblock-rules.d" "$C/h/catalog/prompts" "$C/fx" "$C/col"
  for S in bin/unblock.sh bin/fleet-conf.sh bin/jobs-client.sh bin/lib/unblock/rules.sh bin/lib/unblock/judge.sh bin/lib/unblock/card.sh \
           bin/lib/unblock/collectors/infra.sh bin/lib/gh-rest.sh; do
    ( cd "$SRC" && scratch_install_closure "$S" "$C/h" ) >/dev/null || { echo "setup: closure $S" >&2; return 1; }
  done
  # scratch-closure-allow: places the already-installed infra collector into the UNBLOCK_COLLECTORS_DIR seam the tick reads; the closure itself comes from scratch_install_closure above
  cp "$C/h/bin/lib/unblock/collectors/infra.sh" "$C/col/infra.sh"
  cp "$RULES"/*.json "$C/h/catalog/unblock-rules.d/"
  cp "$SRC/catalog/prompts/unblock-decide.md" "$SRC/catalog/prompts/unblock-judge.md" "$C/h/catalog/prompts/"
  : > "$C/h/env/global.env"; : > "$C/h/state/merge-conductor/pr-state.tsv"
  printf 'cromford example-org/cromford - - 3 hub 192.0.2.10\n' > "$C/h/fleet.conf"
  rm -f "$C/h/bin/lane-alert.sh" "$C/h/bin/agent-call.sh"
  printf '#!/bin/bash\nhead -n1 <<<"ALERT $*" >> "$FXT/alerts.log"\nexit 0\n' > "$C/h/bin/lane-alert.sh"
  printf '#!/bin/bash\necho "AGENTCALL $1 $2 $3" >> "$FXT/seq.log"\n: > "$5"\nexit 0\n' > "$C/h/bin/agent-call.sh"
  chmod +x "$C/h/bin/lane-alert.sh" "$C/h/bin/agent-call.sh"
  cp "$FX/gh.json" "$C/fx.json"; : > "$C/gh.log"; : > "$C/model.log"
  cat > "$C/fx.sh" <<'SH'
seq_log() { printf '%s\n' "$*" >> "$FXT/seq.log"; }
setting_get() { case "$1" in unblock.enabled) printf 1; return 0 ;; esac; return 2; }
lane_gate_or_exit() { return 0; }
lane_env_apply() { return 0; }
_jobs_req() {
  local k n
  seq_log "JOBS $1 $2 ${3:-}"
  case "$1 $2" in
    "GET /api/box-health") printf '{"boxes":[]}'; return 0 ;;
    "GET /api/pool/status?project=cromford") printf '{"queued":0,"running":0,"last_tick":{}}'; return 0 ;;
    "GET /api/ledger?kind=pr_state&status=BLOCKED_HUMAN&limit=1000") printf '{"ledgers":[]}'; return 0 ;;
    "POST /api/unblock/decisions/claim")
      k=$(jq -r .decision_key <<<"$3"); mkdir -p "$FXT/seen"
      if [ -f "$FXT/seen/$k" ]; then printf '{"claimed":false,"id":%s,"outcome":"would"}' "$(cat "$FXT/seen/$k")"; return 9; fi
      n=$(( $(cat "$FXT/id.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FXT/id.n"; echo "$n" > "$FXT/seen/$k"
      printf '{"claimed":true,"id":%s}' "$n"; return 0 ;;
    "POST /api/unblock/decisions/record") printf '{"ok":true}'; return 0 ;;
  esac
  return 1
}
lane_role_model() { seq_log "ROUTE $*"; printf 'model-fixture\n'; }
SH
  jq -nc --argjson fa "$NOWE" '{fetched_at: $fa, values: {"unblock.project.cromford.mode": "act", "unblock.enabled": "1"}, seeded: {}}' \
    > "$C/h/state/settings-cache.json"
  printf '%s' "$C"
}
tick() {
  local C="$1"; shift
  ( env HARNESS="$C/h" FXT="$C/fx" GH_FX="$C/fx.json" GH_LOG="$C/gh.log" MODEL_LOG="$C/model.log" UNBLOCK_FIXTURE="$C/fx.sh" \
      UNBLOCK_COLLECTORS_DIR="$C/col" FLEET_CONF="$C/h/fleet.conf" REGISTRY_SOURCE=file HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 LANE_GATE_NOW="$NOWE" LANE_GATE_CACHE_S=60 \
      UNBLOCK_TIMED=1 JOBS_URL= HARNESS_SECRET= PATH="$T/pathbin:$PATH" GH_ETAG=0 TMPDIR="$C" UNBLOCK_ACT=1 \
      HARNESS_CONSOLE_URL=http://192.0.2.10 UNBLOCK_NOW="$NOWE" UB_NOW="$NOWE" "$@" \
      bash "$C/h/bin/unblock.sh" tick --project cromford ) > "$C/tick.out" 2>&1
}
claims() { grep '^JOBS POST /api/unblock/decisions/claim ' "$1/fx/seq.log" 2>/dev/null | grep -c . ; }
tickline() { grep ' tick cromford mode=' "$1/h/logs/unblock.log" 2>/dev/null | tail -n1; }

C=$(mktick d22) || { echo "FAIL: tick setup"; exit 1; }
cp "$FX/pipeline-health.txt" "$C/h/logs/pipeline-health.log"
D=$(pool "$C" BH-8325 3600 "$PB_RESULT"); after "$D" BH-8324
tick "$C"
check "D22 BH-8325 replay: 0 claim POSTs, 0 lane-alert calls" "$(claims "$C") $(cnt ALERT "$C/fx/alerts.log")" "0 0"
check "D22 one starve-skip line for BH-8325" "$(grep -c ' starve-skip cromford BH-8325: under thresholds (51m of 120, 1 of 3 passes)$' "$C/h/logs/unblock.log")" 1
case "$(tickline "$C")" in
  *" mode=act "*" records=0 "*) ok "D22 the tick line says records=0" ;;
  *) no "D22 the tick line says records=0" "$(tickline "$C"); $(head -c 600 "$C/tick.out")" ;;
esac
budget "$C" D22

C=$(mktick d23) || { echo "FAIL: tick setup"; exit 1; }
phl "$C" BH-8325 130 3
D=$(pool "$C" BH-8325 3600 "$PB_RESULT"); after "$D" BH-8324
tick "$C"
check "D23 the replay at 130m/3p: 0 claim POSTs, 0 lane-alert calls" "$(claims "$C") $(cnt ALERT "$C/fx/alerts.log")" "0 0"
check "D23 the skip reason is the open parent" "$(grep -c ' starve-skip cromford BH-8325: waits on open parent BH-8324 (PR #8721), idle 1h of 24h$' "$C/h/logs/unblock.log")" 1
case "$(tickline "$C")" in
  *" records=0 "*) ok "D23 the tick line says records=0" ;;
  *) no "D23 the tick line says records=0" "$(tickline "$C"); $(head -c 600 "$C/tick.out")" ;;
esac
budget "$C" D23

echo "unblock-starve-dep.bh-8766: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
