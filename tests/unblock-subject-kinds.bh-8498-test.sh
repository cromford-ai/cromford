#!/bin/bash
# tests/unblock-subject-kinds.bh-8498-test.sh — BH-8498: every subject_kind a
# Tackler collector emits is one the claim route accepts.
#
# The route (worker/jobs/src/routes/unblock-decisions.js, SUBJECT_KINDS) and
# the unblock_decisions table CHECK accept a fixed set. On 2026-10-26 the infra
# collector emitted source, pool and ticket, so POST
# /api/unblock/decisions/claim answered 400 {"error":"subject_kind"} for every
# infra stall and act mode could not claim one.
#
# K1 the route's set is readable.
# K2 every literal `subject_kind: "<word>"` in bin/lib/unblock/collectors/*.sh
#    is in that set.
# K3 a collector that emits a word outside the set is red (a mutated copy).
# K4 the queue collector's unreadable record carries a subject_kind in the set
#    and a subject (it had neither: 12 x 400 subject_kind on 2026-10-26).
# K5 the infra contract entry ub_collect_infra <project> <repo> gives a park
#    of the tick's repo the tick's project (a branch-park had project null:
#    6 x 400 project on 2026-10-26).
# K6 a park of another repo (pr-state.tsv is fleet-wide) is not in this tick:
#    its own repo's tick claims it, with its own project.
# K7 a box record is hub-wide: it gets UNBLOCK_HUB_PROJECT (default
#    cromford), never the tick's project, and only in that project's tick.
# K8 a line that is not JSON drops that line only, and the tick gets a
#    source-unreadable record with a project, a subject and a kind in the set.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/unblock-subject-kinds.bh-8498-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

ROUTE="$DIR/worker/jobs/src/routes/unblock-decisions.js"

# route_kinds <route-file> — the words in `const SUBJECT_KINDS = new Set([...])`.
route_kinds() {
  grep -E '^const SUBJECT_KINDS = new Set\(\[' "$1" | grep -oE '"[a-z]+"' | tr -d '"' | sort -u
}

# bad_kinds <collectors-dir> <kinds> — each emitted word not in <kinds>.
bad_kinds() {
  local k
  for k in $(grep -ohE 'subject_kind: "[a-z]+"' "$1"/*.sh | grep -oE '"[a-z]+"' | tr -d '"' | sort -u); do
    grep -qx "$k" <<<"$2" || echo "$k"
  done
}

KINDS=$(route_kinds "$ROUTE")
[ "$(wc -l <<<"$KINDS" | tr -d ' ')" -ge 3 ] && ok || bad "K1 could not read SUBJECT_KINDS from $ROUTE (got [$KINDS])"

OUT=$(bad_kinds "$DIR/bin/lib/unblock/collectors" "$KINDS")
[ -z "$OUT" ] && ok || bad "K2 collectors emit subject_kind words the claim route refuses: $(tr '\n' ' ' <<<"$OUT")(accepted: $(tr '\n' ' ' <<<"$KINDS"))"

mkdir -p "$T/collectors"
# scratch-closure-allow: the copies are scanned as text by bad_kinds, never sourced or run
cp "$DIR"/bin/lib/unblock/collectors/*.sh "$T/collectors/"
printf '%s\n' '# mutated: {subject_kind: "pool"}' >> "$T/collectors/infra.sh"
OUT=$(bad_kinds "$T/collectors" "$KINDS")
[ "$OUT" = pool ] && ok || bad "K3 a mutated collector emitting pool must be red, got [$OUT]"

REC=$( . "$DIR/bin/lib/unblock/collectors/queue.sh" >/dev/null 2>&1; _ubq_unreadable alpha example-org/fixture-repo open-pulls )
RK=$(jq -r '.subject_kind // ""' <<<"$REC" 2>/dev/null); RS=$(jq -r '.subject // ""' <<<"$REC" 2>/dev/null)
if grep -qx "$RK" <<<"$KINDS" && [ -n "$RS" ]; then ok; else bad "K4 queue-unreadable record: subject_kind=[$RK] subject=[$RS]"; fi

PARK=$(printf 'example-org/fixture-repo#42\tBLOCKED_HUMAN\t1761500000\t-\t-\t-\tconflict-unresolvable\thttps://example.invalid/pr/42\t\n')
BOXES='{"boxes":[{"name":"box-x","ssh_reachable":false,"ssh_unreachable_min":45}]}'
# infra <project> <repo> [env...] — ub_collect_infra over the park and box fixtures.
infra() {
  local p="$1" r="$2"; shift 2
  ( for e in "$@"; do export "$e"; done
    . "$DIR/bin/lib/unblock/collectors/infra.sh" >/dev/null 2>&1
    unblock_infra_src() { case "$1" in parks) printf '%s' "$PARK" ;; box_health) printf '%s\n' "$BOXES" ;; *) return 1 ;; esac; }
    ub_collect_infra "$p" "$r" 2>/dev/null )
}
kind_field() { jq -r --arg k "$1" --arg f "$2" 'select(.kind == $k) | .[$f] // "null"' 2>/dev/null | head -1; }

OUTP=$(infra alpha example-org/fixture-repo)
PP=$(kind_field branch-park project <<<"$OUTP")
[ "$PP" = alpha ] && ok || bad "K5 branch-park of the tick repo: want project [alpha] got [$PP] (records: ${OUTP:0:300})"
PP=$(infra alpha example-org/FIXTURE-repo | kind_field branch-park project)
[ "$PP" = alpha ] && ok || bad "K5 the repo match is case-blind: want [alpha] got [$PP]"

OUTP=$(infra alpha example-org/other-repo)
N=$(jq -r 'select(.kind == "branch-park") | .subject' <<<"$OUTP" 2>/dev/null | grep -c .)
[ "$N" = 0 ] && ok || bad "K6 a park of another repo must not be in this tick: got $N (records: ${OUTP:0:300})"
N=$(infra alpha - | jq -r 'select(.kind == "branch-park") | .subject' 2>/dev/null | grep -c .)
[ "$N" = 0 ] && ok || bad "K6 a tick with no repo keeps no park: got $N"
N=$(jq -r 'select(.project == null) | .kind' <<<"$OUTP" 2>/dev/null | grep -c .)
[ "$N" = 0 ] && ok || bad "K6 no record of a one-project tick has a null project: got $N (records: ${OUTP:0:300})"

N=$(infra alpha example-org/fixture-repo | jq -r 'select(.kind == "box-hung") | .subject' 2>/dev/null | grep -c .)
[ "$N" = 0 ] && ok || bad "K7 a box record must not be in a non-hub tick: got $N"
OUTB=$(infra cromford example-org/cromford)
BP=$(kind_field box-hung project <<<"$OUTB")
[ "$BP" = cromford ] && ok || bad "K7 the hub tick's box record: want project [cromford] got [$BP] (records: ${OUTB:0:300})"
BP=$(infra alpha example-org/fixture-repo UNBLOCK_HUB_PROJECT=alpha | kind_field box-hung project)
[ "$BP" = alpha ] && ok || bad "K7 UNBLOCK_HUB_PROJECT=alpha moves the box record to the alpha tick: got [$BP]"
N=$(infra cromford example-org/cromford UNBLOCK_HUB_PROJECT=alpha | jq -r 'select(.kind == "box-hung") | .subject' 2>/dev/null | grep -c .)
[ "$N" = 0 ] && ok || bad "K7 with UNBLOCK_HUB_PROJECT=alpha the cromford tick has no box record: got $N"

OUTK=$( . "$DIR/bin/lib/unblock/collectors/infra.sh" >/dev/null 2>&1
  unblock_infra_src() { case "$1" in parks) printf '%s' "$PARK" ;; *) return 1 ;; esac; }
  _unblock_infra_boxes() { printf '%s\n' 'not json {'; }
  ub_collect_infra alpha example-org/fixture-repo 2>/dev/null )
UR=$(jq -c 'select(.kind == "source-unreadable" and .source == "collect")' <<<"$OUTK" 2>/dev/null | head -1)
UK=$(jq -r '.subject_kind // ""' <<<"$UR" 2>/dev/null); US=$(jq -r '.subject // ""' <<<"$UR" 2>/dev/null); UP=$(jq -r '.project // ""' <<<"$UR" 2>/dev/null)
if [ -n "$UR" ] && grep -qx "$UK" <<<"$KINDS" && [ -n "$US" ] && [ "$UP" = alpha ]; then ok
else bad "K8 a bad line yields a source-unreadable record with project, subject and kind: got [$UR] (records: ${OUTK:0:300})"; fi
PP=$(kind_field branch-park project <<<"$OUTK")
[ "$PP" = alpha ] && ok || bad "K8 the records after a bad line still pass: branch-park project [$PP]"

echo "unblock-subject-kinds.bh-8498: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
