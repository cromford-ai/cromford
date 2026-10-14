#!/bin/bash
# tests/ticket-ownership.bh-1526-test.sh — one owner per ticket: a HOLD is read
# by every lane that queues, splits, builds or merges, and a ticket gets ONE PR.
#
# 2026-09-22: BH-1486's pool PR #1497 merged ahead of the lead's #1495; BH-1484's
# pool PR #1500 opened an hour after the lead's #1493 and would have merged over
# it; BH-1485 was split into five children minutes after filing while the lead
# built it. A body `HOLD:` line was the documented reservation and only the
# pool's spawn gate read it.
#
# The acceptance replays, each DRIVEN (a block extracted verbatim by its
# markers, or a script run whole) against a stub `gh` that answers per issue:
#   A. the library: identity, issue, lead row, merge decision
#   B. filing with a body HOLD never queues (run-build's enqueue funnel)
#   C. ...never splits (bin/run-decompose.sh, whole, dry run)
#   D. ...never pre-plans, and the dispatcher never hands it to a builder
#   E. a build held mid-flight stops at the next stage boundary, before the PR
#   F. a pool PR for a held ticket does not merge (tier-2 sweep + box queue,
#      whole)
#   G. a second PR for a ticket auto-closes, with a linking comment and a
#      ledger note, and a lead PR beats a pool PR regardless of order; a
#      stacked same-ticket PR is not a duplicate; a blank lead row closes nothing
#   H. the conductor, whole tick: the close obeys observe mode and the kill
#      switch, and a READY pool PR for a held ticket is not merged
#   I. merge-sweep, whole: the same merge hold
# Run from anywhere: tests/ticket-ownership.bh-1526-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
# BH-3223: scratch.sh blanks JOBS_URL; this suite's fake curl answers a worker URL.
export JOBS_URL=https://jobs.invalid
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ---------------------------------------------------------------------------
# The scratch harness: an issues project `iss` (o/r) and a board project `brd`.
# ---------------------------------------------------------------------------
H="$T/h"; FIX="$T/fix"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" iss || exit 1  # BH-1510.2: lanes read models from model_routes
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/env" "$H/flags" "$H/locks" "$FIX" "$T/fakebin"
cp "$DIR/bin/lib/hold.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
[ -r "$DIR/bin/lib/ticket-ownership.sh" ] && cp "$DIR/bin/lib/ticket-ownership.sh" "$H/bin/lib/"
cat > "$H/bin/fleet-conf.sh" <<'SHIM'
#!/bin/bash
case "$1 ${2:-}" in
  "--projects ")      printf 'iss\nbrd\n' ;;
  "iss repo")         echo "o/r" ;;
  "iss board_prefix") echo "-" ;;
  "brd repo")         echo "o/b" ;;
  "brd board_prefix") echo "/api/board" ;;
esac
exit 0
SHIM
chmod +x "$H/bin/fleet-conf.sh"
: > "$H/env/global.env"
# The same registry as a real fleet.conf, for the libraries that call the repo's
# own bin/fleet-conf.sh beside themselves (bin/lib/file-children.sh does).
printf 'iss o/r https://iss.example - 9 box-1 10.0.0.9\nbrd o/b https://brd.example /api/board 2 box-1 10.0.0.2\n' > "$H/fleet.conf"

# gh: every argv is recorded, and it answers BOTH spellings the code makes:
# `gh api -i -X …` (bin/lib/gh-rest.sh, judged on the status line it prints) and
# the plain `gh api …` reads bin/lib/hold.sh makes. Reads answer from $FIX per
# number; a missing issue/PR fixture is a 404; a missing open list is a 403.
# A PR closed or merged here reads back that way.
cat > "$T/fakebin/gh" <<'SHIM'
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "$*" >> "$FIX/argv.log"
I=0; case " $* " in *" -i "*) I=1 ;; esac
hdr() { [ "$I" = 1 ] && printf 'HTTP/1.1 %s Stub\r\n\r\n' "$1"; return 0; }
miss() { if [ "$I" = 1 ]; then hdr 404; echo '{"message":"Not Found"}'; exit 0; fi
         echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
N=$(printf '%s' "$*" | sed -nE 's#.*repos/[^/]+/[^/]+/(issues|pulls)/([0-9]+).*#\2#p')
[ -n "$N" ] || N=$(printf '%s' "$*" | grep -oE '[0-9]+' | head -1)   # `pr merge 1497 -R o/r`
case "$*" in
  *"pr merge"*|*"-X PUT"*"/merge"*)
      printf '%s\n' "$N" >> "$FIX/merged.log"; hdr 200; echo '{"merged":true,"sha":"dddddddd4444"}'; exit 0 ;;
  *"-X PATCH"*"/pulls/"*"state=closed"*) printf '%s\n' "$N" >> "$FIX/closed.log"; hdr 200; echo '{}'; exit 0 ;;
  *"/issues/"*"/comments"*"body=@"*)
      f=$(printf '%s' "$*" | sed -nE 's#.*body=@([^ ]+).*#\1#p')
      { printf '#%s: ' "$N"; tr '\n' ' ' < "$f"; echo; } >> "$FIX/posted.log"; hdr 201; echo '{"id":1}'; exit 0 ;;
  *"/pulls -f state=open"*|*"pulls?state=open"*)
      [ -f "$FIX/open.json" ] || { hdr 403; echo '{"message":"API rate limit exceeded"}'; exit 1; }
      hdr 200; cat "$FIX/open.json"; exit 0 ;;
  *"/issues/"*"/comments"*) [ -f "$FIX/comments-down-$N" ] && { hdr 502; echo '{"message":"bad gateway"}'; exit 1; }
      hdr 200; cat "$FIX/comments-$N.json" 2>/dev/null || echo '[]'; exit 0 ;;
  *"/issues/"*) [ -s "$FIX/issue-$N.json" ] || miss; hdr 200; cat "$FIX/issue-$N.json"; exit 0 ;;
  *"/pulls/"*)
      # a PR the closer closed reads back closed even with no fixture of its own
      if [ ! -s "$FIX/pr-$N.json" ] && grep -qx "$N" "$FIX/closed.log" 2>/dev/null; then
        hdr 200; echo '{"state":"closed","merged_at":null}'; exit 0
      fi
      [ -s "$FIX/pr-$N.json" ] || miss
      hdr 200
      if grep -qx "$N" "$FIX/merged.log" 2>/dev/null; then jq -c '.state="closed" | .merged_at="2026-09-22T12:00:00Z" | .merge_commit_sha="dddddddd4444"' "$FIX/pr-$N.json"
      elif grep -qx "$N" "$FIX/closed.log" 2>/dev/null; then jq -c '.state="closed"' "$FIX/pr-$N.json"
      else cat "$FIX/pr-$N.json"; fi
      exit 0 ;;
esac
printf '\n'
exit 0
SHIM
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH" FIX HARNESS="$H" FLEET_CONF="$H/fleet.conf"

# issue <n> <body>        an open ai-build issue with that body
# thread <n> <comment>    one human comment on it
issue()  { jq -nc --argjson n "$1" --arg b "$2" '{number:$n,state:"open",labels:[{name:"ai-build"}],title:"BH-\($n): x",body:$b}' > "$FIX/issue-$1.json"; }
thread() { jq -nc --arg b "$2" '[{body:$b,created_at:"2026-09-22T10:00:00Z",user:{type:"User"}}]' > "$FIX/comments-$1.json"; }
# pr <n> <head-ref> <login> [body]
pr()     { jq -nc --argjson n "$1" --arg r "$2" --arg l "$3" --arg b "${4:-}" \
             '{number:$n,state:"open",merged_at:null,head:{ref:$r,sha:"aaaaaaaa1111"},base:{ref:"main"},labels:[],mergeable:true,mergeable_state:"clean",user:{login:$l,type:"User"},merge_commit_sha:null,body:$b,draft:false}' > "$FIX/pr-$1.json"; }
reset_fix() { rm -f "$FIX"/*; : > "$FIX/argv.log"; : > "$FIX/closed.log"; : > "$FIX/posted.log"; : > "$FIX/merged.log"; }
HELD_BODY=$'HOLD: the lead is building this on the Mac; the pool must not build or split it.\n\n## Build\nstuff'

LIB="$H/bin/lib/ticket-ownership.sh"
[ -r "$LIB" ] && ok || bad "bin/lib/ticket-ownership.sh is missing — every section below needs it"
# lib <shell text> — run text against a fresh copy of the library, in a subshell.
lib() { ( . "$LIB" 2>/dev/null || exit 97; eval "$1" ); }

# ════════════════════════════════════════════════════════════════════════════
# A. THE LIBRARY
# ════════════════════════════════════════════════════════════════════════════
for row in "ticket/bh-1486|BH-1486" "ticket/bh-1486-local|BH-1486" "ticket/bh-1486-r2|BH-1486" \
           "ticket/TK-1481-step0|TK-1481" "ticket/bh-1510-0-local|BH-1510-0" "ticket/bh-1510.0|BH-1510-0" \
           "rules/mined-20260921|" "design/bh-12|" "mergify/merge-queue/x|"; do
  ref="${row%%|*}"; want="${row#*|}"
  got=$(lib "to_pr_identity '$ref'")
  [ "$got" = "$want" ] && ok || bad "A1: to_pr_identity $ref should be '$want', got '$got'"
done

reset_fix
pr 1497 ticket/bh-1486 'cromford[bot]' $'Ticket BH-1486\nCloses #1486\n- Merge pull request #1406 from x'
got=$(lib "to_pr_issue \"\$(cat $FIX/pr-1497.json)\"")
[ "$got" = 1486 ] && ok || bad "A2: the body's Closes line names the issue (got '$got')"
pr 2001 ticket/bh-1510-0 'cromford[bot]' 'Closes #2001'
got=$(lib "to_pr_issue \"\$(cat $FIX/pr-2001.json)\"")
[ "$got" = 2001 ] && ok || bad "A2: a split child is found by its own Closes line, not its parent (got '$got')"
pr 1495 ticket/bh-1486-local operator 'no closing keyword here'
got=$(lib "to_pr_issue \"\$(cat $FIX/pr-1495.json)\"")
[ "$got" = 1486 ] && ok || bad "A2: no closing keyword falls back to the head ref's key (got '$got')"
pr 3 ticket/bh-1510-0-local operator ''
got=$(lib "to_pr_issue \"\$(cat $FIX/pr-3.json)\"")
[ -z "$got" ] && ok || bad "A2: a child ref with no Closes line must not guess the parent (got '$got')"

# THE LEAD IS THE SETTINGS ROW (#1511): the answer changes when the row does.
got=$(lib 'setting_get() { [ "$1" = lead_pr_authors ] && echo "operator, someone-else"; }; to_is_lead operator && to_is_lead someone-else && ! to_is_lead "cromford[bot]" && echo yes')
[ "$got" = yes ] && ok || bad "A3: the lead set must come from the lead_pr_authors row (got '$got')"
got=$(lib 'setting_get() { echo "cromford"; }; to_is_lead "cromford[bot]" && ! to_is_lead operator && echo yes')
[ "$got" = yes ] && ok || bad "A3: a different row, a different lead — nothing is hard-coded (got '$got')"
got=$(lib 'setting_get() { return 1; }; to_is_lead operator && echo lead || echo none')
[ "$got" = none ] && ok || bad "A3: an unreadable row means nobody is the lead (got '$got')"
grep -q "'lead_pr_authors'" "$DIR/worker/jobs/schema.sql" && ok \
  || bad "A3: worker/jobs/schema.sql must seed the lead_pr_authors row"
grep -q . <<<"$(grep -nE 'operator' "$DIR/bin/lib/ticket-ownership.sh" | grep -v '^[0-9]*:#')" \
  && bad "A3: bin/lib/ticket-ownership.sh must not carry a login literal outside comments" || ok

# ════════════════════════════════════════════════════════════════════════════
# B. FILING WITH A BODY HOLD NEVER QUEUES — run-build's enqueue funnel.
# ════════════════════════════════════════════════════════════════════════════
A=$(grep -n '^# >>> held issue skip' "$RB_ALL" | head -1 | cut -d: -f1)
C=$(grep -n '^# <<< held issue skip' "$RB_ALL" | head -1 | cut -d: -f1)
E=$(grep -n 'Fly builder trial (Phase 2): enqueue gate' "$RB_ALL" | head -1 | cut -d: -f1)
CL=$(grep -n '^# <<< closed issue skip' "$RB_ALL" | head -1 | cut -d: -f1)
if [ -z "$A" ] || [ -z "$C" ] || [ -z "$E" ] || [ -z "$CL" ]; then
  bad "B0: run-build needs a '# >>> held issue skip' block (found ${A:-none}..${C:-none}; enqueue gate ${E:-none}, closed skip ${CL:-none})"
else
  [ "$CL" -lt "$A" ] && [ "$C" -lt "$E" ] && ok \
    || bad "B0: the held skip must sit after the closed skip and close BEFORE the enqueue gate ($CL < $A..$C < $E)"
fi
awk '/^# >>> held issue skip/{f=1;next} /^# <<< held issue skip/{exit} f' "$RB_ALL" > "$T/held.sh"

# drive_rb <project> <ticket> <key> [after-text] — the extracted block, then a
# stand-in for everything below it: the queue write the gate must precede.
drive_rb() {
  rm -rf "$T/build"; mkdir -p "$T/build"; : > "$T/qput.log"
  ( cd "$T" && PROJECT="$1" TICKET="$2" KEY="$3" BUILD="$T/build" QLOG="$T/qput.log" \
      bash -c 'STAMP(){ printf "2026-09-22 00:00:00Z"; }; RESULT(){ printf "%s\n" "$*" > "$BUILD/RESULT"; }
               queue_put(){ printf "%s\n" "$*" >> "$QLOG"; }
               . "$1"; eval "${2:-}"; queue_put "$PROJECT" "$KEY" "$TICKET" fly' _ "$T/held.sh" "${4:-}" )
}
reset_fix; issue 1485 "$HELD_BODY"
drive_rb iss 1485 BH-1485; RC=$?
[ "$RC" = 3 ] && ok || bad "B1: a ticket filed with a body HOLD must exit 3 before the enqueue (rc=$RC)"
[ ! -s "$T/qput.log" ] && ok || bad "B1: THE DEFECT — a held ticket reached the queue write: $(cat "$T/qput.log")"
head -1 "$T/build/RESULT" 2>/dev/null | grep -q '^BUILD_DEFERRED held at queue' && ok \
  || bad "B1: RESULT must be BUILD_DEFERRED held at queue (got: $(cat "$T/build/RESULT" 2>/dev/null))"
grep -q 'HOLD: the lead is building' "$T/build/pipeline.log" 2>/dev/null && ok \
  || bad "B1: pipeline.log must quote the line that held it (got: $(cat "$T/build/pipeline.log" 2>/dev/null))"

reset_fix; issue 1486 $'## Build\nThe HOLD mechanism is described here, mid-line.'
drive_rb iss 1486 BH-1486; RC=$?
[ "$RC" = 0 ] && [ -s "$T/qput.log" ] && ok || bad "B2: a clear ticket (HOLD only in prose) must queue exactly as today (rc=$RC)"
reset_fix; issue 1487 "$HELD_BODY"; thread 1487 'RESUME — build it'
drive_rb iss 1487 BH-1487; RC=$?
[ "$RC" = 0 ] && [ -s "$T/qput.log" ] && ok || bad "B2: a RESUME newer than the HOLD queues (rc=$RC)"
reset_fix; jq -nc '{number:1488,state:"open",labels:[],title:"BH-1488",body:"split parent"}' > "$FIX/issue-1488.json"
drive_rb iss 1488 BH-1488; RC=$?
[ "$RC" = 0 ] && ok || bad "B2: label-absent is a fact, not a HOLD — it must not be refused here (rc=$RC)"
reset_fix
drive_rb iss 1489 BH-1489; RC=$?
[ "$RC" = 0 ] && [ -s "$T/qput.log" ] && ok || bad "B3: an unreadable issue must build as today (rc=$RC)"
grep -q 'hold check unreadable at queue' "$T/build/pipeline.log" 2>/dev/null && ok \
  || bad "B3: an unreadable read must say so once in pipeline.log"
reset_fix
drive_rb brd ckabc123 TK-70; RC=$?
[ "$RC" = 0 ] && [ ! -s "$FIX/argv.log" ] && ok \
  || bad "B3: a board project makes no gh call and queues (rc=$RC, gh: $(cat "$FIX/argv.log"))"

# ════════════════════════════════════════════════════════════════════════════
# C. ...NEVER SPLITS — bin/run-decompose.sh, whole, dry run.
# ════════════════════════════════════════════════════════════════════════════
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
echo "AGENT CALL: $*" >> "$FIX/agent.log"
exit 0
SH
chmod +x "$H/bin/agent-call.sh"
SPEC='[{"title":"contract","contract":"a.ts: A","after":[],"body":"b\n\n## Observable outcome\nThe slice acceptance test passes end to end."},{"title":"two","after":[],"body":"c\n\n## Observable outcome\nThe slice acceptance test passes end to end."}]'
decompose() {
  rm -rf "$T/b"; mkdir -p "$T/b"; printf '%s\n' "$SPEC" > "$T/b/children.json"
  ( DECOMPOSE_DRY_RUN=1 "$DIR/bin/run-decompose.sh" iss "$1" "BH-$1" "$T/b" 300 12 2>&1 )
}
reset_fix; issue 1485 "$HELD_BODY"
OUT=$(decompose 1485); RC=$?
[ "$RC" = 3 ] && ok || bad "C1: a held ticket must be refused by the splitter with rc 3 (rc=$RC): $OUT"
grep -q 'gh issue create' <<<"$OUT" && bad "C1: THE DEFECT — a held ticket was split: $OUT" || ok
grep -q '^DECOMPOSE_HELD' "$T/b/decompose-run.txt" 2>/dev/null && ok \
  || bad "C1: decompose-run.txt must carry DECOMPOSE_HELD, never DECOMPOSE_FAILED ($(cat "$T/b/decompose-run.txt" 2>/dev/null))"
reset_fix; issue 1486 '## Build'
OUT=$(decompose 1486); RC=$?
[ "$RC" = 0 ] && grep -q 'gh issue create' <<<"$OUT" && ok \
  || bad "C2: a clear ticket must split exactly as today (rc=$RC): $OUT // $(cat "$T/b/decompose-run.txt" "$T/b/pipeline.log" 2>/dev/null)"
# run-build hands rc 3 back as a deferral, not a DECOMPOSE_FAILED page.
grep -q 'elif \[ "$SG_DRC" = 3 \]; then' "$RB_ALL" && ok \
  || bad "C3: run-build's size gate must treat the splitter's rc 3 as BUILD_DEFERRED"

# ════════════════════════════════════════════════════════════════════════════
# D. ...NEVER PRE-PLANS, AND IS NEVER HANDED TO A BUILDER
# ════════════════════════════════════════════════════════════════════════════
awk '/^# >>> preplan hold gate/{f=1;next} /^# <<< preplan hold gate/{exit} f' "$DIR/bin/run-preplan.sh" > "$T/pp.sh"
[ -s "$T/pp.sh" ] && ok || bad "D0: bin/run-preplan.sh needs a '# >>> preplan hold gate' block"
preplan() {
  : > "$T/pp.log"
  ( PROJECT=iss TICKET="$1" KEY="BH-$1" HERE="$H/bin" LOG="$T/pp.log" \
      bash -c 'STAMP(){ printf "t"; }; . "$1"; echo PLANNED >> "$LOG"' _ "$T/pp.sh" )
}
reset_fix; issue 1485 "$HELD_BODY"; preplan 1485
grep -q 'PREPLAN_SKIP held' "$T/pp.log" && ! grep -q PLANNED "$T/pp.log" && ok \
  || bad "D1: a held ticket must never be pre-planned ($(cat "$T/pp.log"))"
reset_fix; issue 1486 '## Build'; preplan 1486
grep -q PLANNED "$T/pp.log" && ok || bad "D1: a clear ticket pre-plans as today ($(cat "$T/pp.log"))"

awk '/^  # >>> next job pick/{f=1;next} /^  # <<< next job pick/{exit} f' "$DIR/bin/fly-dispatch.sh" > "$T/pick.sh"
[ -s "$T/pick.sh" ] && ok || bad "D2: bin/fly-dispatch.sh lost its '# >>> next job pick' region"
# pick <key:ticket>… — a scratch queue in that order, then the pick region run
# the way dispatch_project runs it; prints the row it chose (or nothing).
pick() {
  local q="$T/q" e
  scratch_rm "$q"; mkdir -p "$q"; : > "$T/fd.log"
  for e in "$@"; do jq -nc --arg t "${e#*:}" --arg k "${e%%:*}" '{ticket_id:$t,key:$k}' > "$q/${e%%:*}.json"; done
  ( . "$LIB"; p=iss; qdir="$q"; next_job=""; FDLOG="$T/fd.log"
    say() { printf '%s\n' "$2" >> "$FDLOG"; }
    . "$T/pick.sh"; basename "${next_job:-none}" .json )
}
# S-1: the OLDEST row is held; the next one must still be claimed.
reset_fix; issue 1485 "$HELD_BODY"; issue 1486 '## Build'
got=$(pick BH-1485:1485 BH-1486:1486)
[ "$got" = BH-1486 ] && ok \
  || bad "D2: THE DEFECT — a held row at the head of the queue must be skipped, not waited on (picked '$got'; $(cat "$T/fd.log"))"
grep -q 'HOLD, skipping BH-1485' "$T/fd.log" && ok || bad "D2: the skip must be said once ($(cat "$T/fd.log"))"
[ -f "$T/q/BH-1485.json" ] && ok || bad "D2: the held row stays queued, so a RESUME builds it"
# every row held -> nothing is claimed
got=$(pick BH-1485:1485)
[ "$got" = none ] && ok || bad "D2: a queue of only held rows claims nothing (picked '$got')"
# no hold -> the oldest, exactly as before
reset_fix; issue 1485 '## Build'; issue 1486 '## Build'
got=$(pick BH-1485:1485 BH-1486:1486)
[ "$got" = BH-1485 ] && ok || bad "D2: with no hold the oldest row is picked as today (picked '$got')"

# ════════════════════════════════════════════════════════════════════════════
# E. A BUILD HELD MID-FLIGHT STOPS AT THE NEXT BOUNDARY, BEFORE ANY PR.
# ════════════════════════════════════════════════════════════════════════════
# the thread flips to HOLD between the queue check and the review boundary
reset_fix; issue 1490 '## Build'
jq -nc '[{body:"HOLD — the lead has this one",created_at:"2026-09-22T11:00:00Z",user:{type:"User"}}]' > "$FIX/held-thread"
drive_rb iss 1490 BH-1490 "cp '$FIX/held-thread' '$FIX/comments-1490.json'; HOLD_STAGE_CHECK review; echo REVIEWED > \"\$BUILD/after\""; RC=$?
[ "$RC" = 3 ] && ok || bad "E1: a HOLD typed mid-build must stop the build at the next boundary (rc=$RC)"
[ ! -f "$T/build/after" ] && ok || bad "E1: code after the boundary ran — the build did not stop"
head -1 "$T/build/RESULT" 2>/dev/null | grep -q '^BUILD_DEFERRED held at review' && ok \
  || bad "E1: RESULT must name the boundary (got: $(cat "$T/build/RESULT" 2>/dev/null))"
# every boundary YIELD_CHECK has, plus the last one before the PR, at top level
for st in queue plan execute review pr; do
  grep -qE "^HOLD_STAGE_CHECK $st\$" "$RB_ALL" && ok || bad "E2: no top-level 'HOLD_STAGE_CHECK $st' in run-build"
done
LASTCHK=$(grep -nE '^HOLD_STAGE_CHECK pr$' "$RB_ALL" | head -1 | cut -d: -f1)
PROPEN=$(grep -n '^# >>> pr open' "$RB_ALL" | head -1 | cut -d: -f1)
PRCALL=$(grep -n '^# >>> pr create call' "$RB_ALL" | head -1 | cut -d: -f1)
if [ -n "$LASTCHK" ] && [ -n "$PROPEN" ] && [ -n "$PRCALL" ]; then
  [ "$LASTCHK" -lt "$PROPEN" ] && [ "$PROPEN" -lt "$PRCALL" ] && ok \
    || bad "E2: the pr boundary must come before the PR is opened ($LASTCHK < $PROPEN < $PRCALL)"
else
  bad "E2: could not find the pr boundary / pr open / pr create landmarks"
fi

# ════════════════════════════════════════════════════════════════════════════
# F. A POOL PR FOR A HELD TICKET DOES NOT MERGE
# ════════════════════════════════════════════════════════════════════════════
LEADROW='setting_get() { echo operator; }'
reset_fix; issue 1486 "$HELD_BODY"
pr 1497 ticket/bh-1486 'cromford[bot]' 'Closes #1486'
pr 1495 ticket/bh-1486-local operator 'lead build'
got=$(lib "$LEADROW; to_merge_hold iss o/r 1497 && echo HOLD || echo GO")
case "$got" in *"#1486 is held"*HOLD) ok ;; *) bad "F1: a pool PR for a held ticket must not merge (got '$got')" ;; esac
got=$(lib "$LEADROW; to_merge_hold iss o/r 1495 && echo HOLD || echo GO")
[ "$got" = GO ] && ok || bad "F1: the lead's own PR is what the hold reserves the ticket for (got '$got')"
got=$(lib 'setting_get() { return 1; }; to_merge_hold iss o/r 1495 >/dev/null && echo HOLD || echo GO')
[ "$got" = HOLD ] && ok || bad "F1: with no readable lead row, the held ticket's PR holds — the safe side (got '$got')"
reset_fix; issue 1486 '## Build'; pr 1497 ticket/bh-1486 'cromford[bot]' 'Closes #1486'
got=$(lib "$LEADROW; to_merge_hold iss o/r 1497 && echo HOLD || echo GO")
[ "$got" = GO ] && ok || bad "F2: a clear ticket's PR merges as today (got '$got')"
reset_fix; jq -nc '{number:1510,state:"open",labels:[],title:"BH-1510",body:"split"}' > "$FIX/issue-1510.json"
issue 2001 '## child'; pr 2001 ticket/bh-1510-0 'cromford[bot]' 'Closes #2001'
got=$(lib "$LEADROW; to_merge_hold iss o/r 2001 && echo HOLD || echo GO")
[ "$got" = GO ] && ok || bad "F2: a split child merges: its de-labelled parent is not a HOLD (got '$got')"
reset_fix; pr 1497 ticket/bh-1486 'cromford[bot]' 'Closes #1486'
got=$(lib "$LEADROW; to_merge_hold iss o/r 1497 && echo HOLD || echo GO")
case "$got" in *"could not be read"*HOLD) ok ;; *) bad "F2: an unreadable hold holds the merge this pass (got '$got')" ;; esac
reset_fix; pr 70 ticket/TK-70 'cromford[bot]' ''
got=$(lib "$LEADROW; to_merge_hold brd o/b 70 && echo HOLD || echo GO")
# TEST-CHANGE (BH-1668, review of #1926 blocking 1): a board project's PR now
# costs ONE read, its own comment thread, because a HOLD written on the PR
# itself binds every project. Still no issue or PR read, and still GO.
[ "$got" = GO ] && [ "$(grep -c . "$FIX/argv.log")" = 1 ] && grep -q 'o/b/issues/70/comments' "$FIX/argv.log" && ok \
  || bad "F2: a board project's PR merges as today, reading only its own thread (got '$got', gh: $(cat "$FIX/argv.log"))"

# F3. A HOLD ON THE PR ITSELF (BH-1668, review of #1926 blocking 1). project-5
# #3214 carries `HOLD: do not enqueue or merge automatically` on the PR, and its
# ticket #3108 carries none. The ticket read alone let it through. The PR's own
# thread is judged by the same classifier (bin/lib/hold.sh): newest human
# decisive word wins, bots are ignored, RESUME lifts, unreadable holds.
reset_fix; issue 1486 '## Build'; pr 1497 ticket/bh-1486 'cromford-builders[bot]' 'Closes #1486'
thread 1497 'HOLD: do not enqueue or merge automatically. It changes a sign-in identity.'
got=$(lib "$LEADROW; to_merge_hold iss o/r 1497 && echo HOLD || echo GO")
case "$got" in *"PR itself is held"*"HOLD: do not enqueue"*HOLD) ok ;; *) bad "F3: a HOLD comment on the PR must hold the merge though its ticket is clear (got '$got')" ;; esac
jq -nc '[{body:"HOLD: wait",created_at:"2026-09-22T10:00:00Z",user:{type:"User"}},{body:"RESUME — reviewed, ship it",created_at:"2026-09-22T11:00:00Z",user:{type:"User"}}]' > "$FIX/comments-1497.json"
got=$(lib "$LEADROW; to_merge_hold iss o/r 1497 && echo HOLD || echo GO")
[ "$got" = GO ] && ok || bad "F3b: a later RESUME on the PR releases it (got '$got')"
jq -nc '[{body:"HOLD: nitpicks",created_at:"2026-09-22T10:00:00Z",user:{type:"Bot"}}]' > "$FIX/comments-1497.json"
got=$(lib "$LEADROW; to_merge_hold iss o/r 1497 && echo HOLD || echo GO")
[ "$got" = GO ] && ok || bad "F3c: a bot's HOLD is not an instruction (got '$got')"
rm -f "$FIX/comments-1497.json"; touch "$FIX/comments-down-1497"
got=$(lib "$LEADROW; to_merge_hold iss o/r 1497 && echo HOLD || echo GO")
case "$got" in *"could not be read"*HOLD) ok ;; *) bad "F3d: an unreadable PR thread holds this pass (got '$got')" ;; esac
reset_fix; pr 70 ticket/TK-70 'cromford[bot]' ''; thread 70 'HOLD: client asked to wait'
got=$(lib "$LEADROW; to_merge_hold brd o/b 70 && echo HOLD || echo GO")
case "$got" in *"PR itself is held"*HOLD) ok ;; *) bad "F3e: a PR-level HOLD binds a board project too (got '$got')" ;; esac
# F3g-i. A PR THREAD IS JUDGED LINE-ANCHORED (review of #1926 round 2). Lead
# reviews post as operator (a User), and they discuss holds constantly: an
# unanchored HOLD held four live PRs on review prose (a knob name,
# MAIN_RED_HOLD_OVERRUN, was enough), and an unanchored RESUME in a later review
# would silently lift a real HOLD. So a comment holds only when a LINE STARTS
# with HOLD / HOLD: / HOLD —, and lifts only when a line starts with RESUME or
# UNHOLD — the rule ticket bodies already follow (BH-1461).
REVIEW=$'## Review\n\n- The knob MAIN_RED_HOLD_OVERRUN bounds a held streak.\n- A HOLD on the PR binds every lane; RESUME on the PR lifts it.\n\nVERDICT: MERGE'
HOLDPROSE=$'## Review\n\n- The knob MAIN_RED_HOLD_OVERRUN bounds a held streak.\n- A HOLD on the PR binds every lane (the MERGE_HELD line says so).\n\nVERDICT: MERGE'
reset_fix; issue 1486 '## Build'; pr 1497 ticket/bh-1486 'cromford-builders[bot]' 'Closes #1486'
jq -nc --arg b "$HOLDPROSE" '[{body:$b,created_at:"2026-09-22T10:00:00Z",user:{type:"User"}}]' > "$FIX/comments-1497.json"
got=$(lib "$LEADROW; to_merge_hold iss o/r 1497 && echo HOLD || echo GO")
[ "$got" = GO ] && ok || bad "F3g: review prose with HOLD / MAIN_RED_HOLD_OVERRUN mid-line must NOT hold (got '$got')"
jq -nc --arg b "$REVIEW" '[{body:"HOLD: do not enqueue or merge automatically. TK-3108 changes a user sign-in identity.",created_at:"2026-09-22T10:00:00Z",user:{type:"User"}},
                           {body:$b,created_at:"2026-09-22T11:00:00Z",user:{type:"User"}}]' > "$FIX/comments-1497.json"
got=$(lib "$LEADROW; to_merge_hold iss o/r 1497 && echo HOLD || echo GO")
case "$got" in *"PR itself is held"*HOLD) ok ;; *) bad "F3h: a later review quoting RESUME mid-line must NOT lift a line-start HOLD (got '$got')" ;; esac
jq -nc '[{body:"HOLD: do not enqueue or merge automatically. TK-3108 changes a user'"'"'s sign-in identity, and the harness review said it needs the operator'"'"'s own review before it lands.",created_at:"2026-09-24T12:14:18Z",user:{type:"User"}},
         {body:"## Review round (lane F): answers to the harness review of b903805\n\nPushed `8b1461f5`.",created_at:"2026-09-24T12:20:36Z",user:{type:"User"}}]' > "$FIX/comments-1497.json"
got=$(lib "$LEADROW; to_merge_hold iss o/r 1497 && echo HOLD || echo GO")
case "$got" in *"PR itself is held"*HOLD) ok ;; *) bad "F3i: #3214's real thread shape must hold (got '$got')" ;; esac
jq -nc '[{body:"HOLD: wait",created_at:"2026-09-22T10:00:00Z",user:{type:"User"}},{body:"reviewed.\nUNHOLD",created_at:"2026-09-22T11:00:00Z",user:{type:"User"}}]' > "$FIX/comments-1497.json"
got=$(lib "$LEADROW; to_merge_hold iss o/r 1497 && echo HOLD || echo GO")
[ "$got" = GO ] && ok || bad "F3j: a line-start UNHOLD on a later line lifts (got '$got')"

# the conductor asks the hold BEFORE it hands the head to the self-enqueue
HL=$(grep -n 'to_lane_hold "\$P" "\$SLUG" "\$NUM"' "$DIR/bin/merge-conductor.sh" | head -1 | cut -d: -f1)
AM=$(grep -n 'ae_mark "\$P" ready' "$DIR/bin/merge-conductor.sh" | head -1 | cut -d: -f1)
[ -n "$HL" ] && [ -n "$AM" ] && [ "$HL" -lt "$AM" ] && ok \
  || bad "F3f: the conductor's hold check (line ${HL:-?}) must come before the READY mark (line ${AM:-?})"

# The lanes. The box queue runs WHOLE; the conductor and
# merge-sweep are pinned by order — the gate sits before their merge verb.
mkdir -p "$H/bin/lib/jobs" "$H/bin/lib/mc" "$H/builds"
cp "$DIR/bin/merge-queue.sh" "$DIR/bin/jobs-client.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"; cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" \
   "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/gh-repo-token.sh" "$H/bin/lib/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
for s in beat.sh deploy-request.sh lander.sh lane-alert.sh review-tighten.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$s"; chmod +x "$H/bin/$s"; done
for s in flock git sleep; do printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/$s"; chmod +x "$T/fakebin/$s"; done
: > "$H/env/iss.env"
# the worker: the lead row answers, everything else 404s.
cat > "$T/fakebin/curl" <<'SHIM'
#!/bin/bash
URL="${!#}"
case "$URL" in
  */api/settings/lead_pr_authors) printf '{"setting":{"key":"lead_pr_authors","value":"operator"}}\n200\n' ;;
  *) printf '{}\n404\n' ;;
esac
SHIM
chmod +x "$T/fakebin/curl"
printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.invalid\n' > "$H/env/global.env"
Q="$H/state/merge-queue/iss"
mq() { scratch_rm "$Q"; mkdir -p "$Q"; : > "$Q/$1"; : > "$FIX/merged.log"; : > "$H/logs/merge-queue.log"
       ( cd "$T" && bash "$H/bin/merge-queue.sh" iss >/dev/null 2>"$T/mq.err" ) || true; }
reset_fix; issue 1486 "$HELD_BODY"; pr 1497 ticket/bh-1486 'cromford[bot]' 'Closes #1486'
mq 1497
grep -qx 1497 "$FIX/merged.log" && bad "F3: THE DEFECT — the box queue merged a pool PR for a held ticket" || ok
grep -q '#1497 MERGE_HELD: ticket #1486 is held' "$H/logs/merge-queue.log" && ok \
  || bad "F3: the box queue must log one MERGE_HELD line ($(cat "$H/logs/merge-queue.log"); err: $(head -c 400 "$T/mq.err"))"
[ -f "$Q/1497" ] && ok || bad "F3: the entry stays queued, so a RESUME lands it"
[ ! -s "$H/logs/ALERTS.log" ] && ok || bad "F3: an obeyed hold is not an alert: $(cat "$H/logs/ALERTS.log")"
reset_fix; issue 1486 '## Build'; pr 1497 ticket/bh-1486 'cromford[bot]' 'Closes #1486'
mq 1497
grep -qx 1497 "$FIX/merged.log" && ok \
  || bad "F3: a clear ticket's PR lands as today ($(cat "$H/logs/merge-queue.log"); gh: $(grep -E 'PUT|merge|pulls/1497' "$FIX/argv.log" | tail -5))"

# BH-1366: F4 drove bin/tier2-merge-sweep.sh (a held ticket's PR is never
# enqueued). That feeder is retired; the merge-time HOLD is asked by
# merge-queue.sh on all three landing paths, which F3 drives and F5 pins.
[ "$(grep -c 'to_lane_hold "$PROJECT" "$SLUG"' "$DIR/bin/merge-queue.sh")" = 3 ] && ok \
  || bad "F5: the box queue asks on all three landing paths (assembly, train landing, serial)"

# ════════════════════════════════════════════════════════════════════════════
# G. ONE OPEN PR PER TICKET — the newer closes, a lead PR always wins.
# ════════════════════════════════════════════════════════════════════════════
# open <n|ref|login|created[|base]>… — the open-PR list the closer reads.
open_list() { local r; for r in "$@"; do IFS='|' read -r n ref login at base <<<"$r"
                jq -nc --argjson n "$n" --arg r "$ref" --arg l "$login" --arg a "$at" --arg b "${base:-main}" \
                  '{number:$n,head:{ref:$r},base:{ref:$b},user:{login:$l},created_at:$a}'; done | jq -sc . > "$FIX/open.json"; }
dedupe() { : > "$T/ledger.log"; : > "$H/logs/ticket-ownership.log"
  lib "$LEADROW; job_ledger_put() { printf '%s\n' \"\$*\" >> '$T/ledger.log'; }
       to_dedupe_open_prs o/r; printf '%s' \"\${TO_LOSERS:-}\" > '$T/losers'"; }

# G1. the incident: lead PR first, the pool's an hour later -> the pool closes.
reset_fix
open_list '1493|ticket/bh-1484-local|operator|2026-09-22T09:00:00Z' '1500|ticket/bh-1484|cromford[bot]|2026-09-22T10:00:00Z'
dedupe
[ "$(cat "$FIX/closed.log")" = 1500 ] && ok || bad "G1: the newer pool PR #1500 must close (closed: $(cat "$FIX/closed.log"))"
grep -q '^#1500: .*#1493' "$FIX/posted.log" && ok || bad "G1: the closing comment must link the PR that stays ($(cat "$FIX/posted.log"))"
grep -q '^ticket_pr_owner o/r#BH-1484 closed-duplicate closed #1500, kept #1493' "$T/ledger.log" && ok \
  || bad "G1: the decision must be written to the ledger ($(cat "$T/ledger.log"))"
grep -q 'o/r#1500' "$T/losers" && ok || bad "G1: the closed PR must be named to this tick's merge gate (TO_LOSERS='$(cat "$T/losers")')"

# G2. REGARDLESS OF ORDER: the pool PR first, the lead's second -> the POOL closes.
reset_fix
open_list '1497|ticket/bh-1486|cromford[bot]|2026-09-22T09:00:00Z' '1495|ticket/bh-1486-local|operator|2026-09-22T09:30:00Z'
dedupe
[ "$(cat "$FIX/closed.log")" = 1497 ] && ok \
  || bad "G2: a lead PR beats an OLDER pool PR — #1497 must close, never #1495 (closed: $(cat "$FIX/closed.log"))"
grep -q "^#1497: .*#1495 is the lead's build" "$FIX/posted.log" && ok || bad "G2: the comment must say why the lead's PR won ($(cat "$FIX/posted.log"))"

# G3. two pool PRs -> the newer closes; two lead PRs -> nothing closes.
reset_fix
open_list '30|ticket/bh-30|cromford[bot]|2026-09-22T09:00:00Z' '31|ticket/bh-30-r2|cromford[bot]|2026-09-22T10:00:00Z'
dedupe
[ "$(cat "$FIX/closed.log")" = 31 ] && ok || bad "G3: of two pool PRs the newer closes (closed: $(cat "$FIX/closed.log"))"
reset_fix
open_list '40|ticket/bh-40-local|operator|2026-09-22T09:00:00Z' '41|ticket/bh-40-local2|operator|2026-09-22T10:00:00Z'
dedupe
[ ! -s "$FIX/closed.log" ] && ok || bad "G3: a lead PR is never closed by this rule (closed: $(cat "$FIX/closed.log"))"

# G4. NOT duplicates: a parent and its split child, two tickets, a non-ticket branch.
reset_fix
open_list '50|ticket/bh-7-local|operator|2026-09-22T09:00:00Z' '51|ticket/bh-7-0|cromford[bot]|2026-09-22T10:00:00Z' \
          '52|ticket/bh-8|cromford[bot]|2026-09-22T10:00:00Z' '53|rules/mined-1|cromford[bot]|2026-09-22T10:00:00Z' \
          '54|rules/mined-2|cromford[bot]|2026-09-22T11:00:00Z'
dedupe
[ ! -s "$FIX/closed.log" ] && ok || bad "G4: nothing here duplicates anything (closed: $(cat "$FIX/closed.log"))"

# G5. no readable lead row, or no list: close NOTHING.
reset_fix
open_list '1497|ticket/bh-1486|cromford[bot]|2026-09-22T09:00:00Z' '1495|ticket/bh-1486-local|operator|2026-09-22T09:30:00Z'
: > "$T/ledger.log"
lib "setting_get() { return 1; }; to_dedupe_open_prs o/r"
[ ! -s "$FIX/closed.log" ] && ok || bad "G5: with no lead row nothing may be closed (closed: $(cat "$FIX/closed.log"))"
reset_fix
dedupe
[ ! -s "$FIX/closed.log" ] && ok || bad "G5: an unreadable list closes nothing"

# G6. the merge gate refuses a PR this tick closed, whatever else it would say.
got=$(lib "TO_LOSERS=' o/r#1500'; to_merge_hold brd o/r 1500 && echo HOLD || echo GO")
case "$got" in *duplicate*HOLD) ok ;; *) bad "G6: a PR closed as a duplicate this tick must not merge (got '$got')" ;; esac
grep -q 'to_dedupe_open_prs "$SLUG"' "$DIR/bin/merge-conductor.sh" && ok \
  || bad "G6: the conductor must run the one-PR-per-ticket check every tick"

# G7. A STACKED PR IS NOT A DUPLICATE (review round 1): step2's base is step1's
#     head, same ticket: one piece of work, nothing closes.
reset_fix
open_list '10|ticket/bh-9-step1|cromford[bot]|2026-09-22T09:00:00Z|main' \
          '11|ticket/bh-9-step2|cromford[bot]|2026-09-22T10:00:00Z|ticket/bh-9-step1'
dedupe
[ ! -s "$FIX/closed.log" ] && ok || bad "G7: a stacked same-ticket PR must not be closed as a duplicate (closed: $(cat "$FIX/closed.log"))"
#     ...but a real duplicate beside the stack still closes.
reset_fix
open_list '10|ticket/bh-9-step1|cromford[bot]|2026-09-22T09:00:00Z|main' \
          '11|ticket/bh-9-step2|cromford[bot]|2026-09-22T10:00:00Z|ticket/bh-9-step1' \
          '12|ticket/bh-9-r2|cromford[bot]|2026-09-22T11:00:00Z|main'
dedupe
[ "$(cat "$FIX/closed.log")" = 12 ] && ok || bad "G7: the unstacked newer duplicate still closes (closed: $(cat "$FIX/closed.log"))"

# G8. A WHITESPACE-ONLY LEAD ROW IS NO ROW (review round 1, I-1): nothing closes,
#     and above all not the lead's own newer PR.
reset_fix
open_list '17|ticket/bh-17|cromford[bot]|2026-09-22T09:00:00Z' '18|ticket/bh-17-local|operator|2026-09-22T10:00:00Z'
lib "setting_get() { printf ' , \t'; }; to_dedupe_open_prs o/r"
[ ! -s "$FIX/closed.log" ] && ok || bad "G8: a ' , ' lead row must close nothing (closed: $(cat "$FIX/closed.log"))"
got=$(lib "setting_get() { printf '  operator ,  '; }; to_lead_authors")
[ "$got" = operator ] && ok || bad "G8: the row is trimmed (got '$got')"

# ════════════════════════════════════════════════════════════════════════════
# H. THE CONDUCTOR, WHOLE TICK: the close obeys ACTIONS, and the hold stops a
#    READY pool PR in merge mode.
# ════════════════════════════════════════════════════════════════════════════
CT="$T/ct"; mkdir -p "$CT"
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
fx_mc_harness "$DIR" "$CT" && fx_conductor_tick "$DIR" "$CT" || bad "H0: the conductor fixture did not build"
[ -f "$DIR/bin/merge-conductor.sh" ] || exit 1   # impact: this suite drives the whole tick
CH="$CT/h"; HC1=aaaaaaaa1111
# The lane gate reads the per-project knob row (MC_TICKET_DEDUPE) the way a box
# does: lane-gate.sh plus the lane registry rendered from catalog/lanes.d.
cp "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/lanes-registry.sh" "$CH/bin/lib/"
mkdir -p "$CH/catalog"; cp -R "$DIR/catalog/lanes.d" "$CH/catalog/"
"$DIR/bin/lanes-build.sh" --root "$CH" --write >/dev/null 2>&1 || bad "H0: could not render the lane registry"
printf 'issuer example-org/issuer - - 3 box-issuer\n' > "$CH/fleet.conf"
: > "$CH/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$CH/bin/agent-call.sh"; chmod +x "$CH/bin/agent-call.sh"
mkdir -p "$CH/builds/pool-issuer-IS-9-202609220001"
echo "PR_CREATED https://github.com/example-org/issuer/pull/9" > "$CH/builds/pool-issuer-IS-9-202609220001/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$CH/builds/pool-issuer-IS-9-202609220001/review.md"
echo "$HC1" > "$CH/builds/pool-issuer-IS-9-202609220001/reviewed-sha"
cat > "$CT/fakebin/gh" <<GHSTUB
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "\$*" >> "$CT/gh-calls.txt"
case "\$*" in
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n'; exit 0 ;;  # BH-1668: the PR's own thread (no HOLD), read over REST by to_merge_hold
  *"-X PATCH"*"/pulls/"*"state=closed"*) printf '%s\n' "\$*" >> "$CT/closed.txt"; printf 'HTTP/1.1 200 OK\r\n\r\n{}\n' ;;
  *"-X POST"*"/comments"*) printf 'HTTP/1.1 201 Created\r\n\r\n{"id":1}\n' ;;
  *"pr merge"*|*"-X PUT"*"/merge"*) printf '%s\n' "\$*" >> "$CT/merged.txt"; touch "$CT/merged9"; printf 'HTTP/1.1 200 OK\r\n\r\n{"merged":true,"sha":"cccccccc3333"}\n' ;;
  *"api -i -X GET repos/example-org/issuer/pulls -f state=open"*)
    printf 'HTTP/1.1 200 OK\r\n\r\n'; cat "$CT/restopen.json" ;;
  *"repos/example-org/issuer/pulls?state=open"*) cat "$CT/restopen.json" ;;   # the plain spelling, answered too
  *"pr list -R example-org/issuer --state open"*) cat "$CT/openlist.json" ;;
  *"pr list"*) echo "[]" ;;
  *"repos/example-org/issuer/pulls?state=closed"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n' ;;
  *"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/example-org/issuer/pulls/9")
    if [ -f "$CT/merged9" ]; then restpr MERGED "$HC1" ticket/is-9 main "" MERGEABLE CLEAN app/cromford cccccccc3333 "Closes #9"
    else restpr OPEN "$HC1" ticket/is-9 main "" MERGEABLE CLEAN app/cromford "" "Closes #9"; fi ;;
  *"api -i -X GET repos/example-org/issuer/issues/9") restpr --raw 200 '{"state":"open"}' ;;
  *"repos/example-org/issuer/issues/9/comments?per_page"*) cat "$CT/thread9.json" 2>/dev/null || echo '[]' ;;
  "api repos/example-org/issuer/issues/9") cat "$CT/issue9.json" ;;
  *"actions/runs?head_sha=$HC1"*) printf 'completed|success\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
GHSTUB
chmod +x "$CT/fakebin/gh"
cat > "$CT/fakebin/curl" <<'CURLSTUB'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
case "$M $URL" in
  "GET "*/api/settings/lead_pr_authors) printf '{"setting":{"key":"lead_pr_authors","value":"operator"}}\n200\n' ;;
  "GET "*/api/settings) [ -s "${DEDUPE_ROWS:-/nonexistent}" ] && printf '%s\n200\n' "$(cat "$DEDUPE_ROWS")" || printf '{"settings":[]}\n200\n' ;;
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
CURLSTUB
chmod +x "$CT/fakebin/curl"
jq -nc --arg h "$HC1" '[{number:9,url:"https://github.com/example-org/issuer/pull/9",headRefOid:$h,headRefName:"ticket/is-9",baseRefName:"main",isDraft:false,mergeStateStatus:"CLEAN",mergeable:"MERGEABLE",state:"OPEN",updatedAt:"2026-09-22T10:00:00Z"}]' > "$CT/openlist.json"
# the REST list the one-PR rule reads: pool #30 (older) and pool #31 (newer), one ticket
jq -nc '[{number:30,head:{ref:"ticket/is-30"},base:{ref:"main"},user:{login:"cromford[bot]"},created_at:"2026-09-22T09:00:00Z"},
         {number:31,head:{ref:"ticket/is-30-r2"},base:{ref:"main"},user:{login:"cromford[bot]"},created_at:"2026-09-22T10:00:00Z"}]' > "$CT/restopen.json"
jq -nc '{number:9,state:"open",labels:[{name:"ai-build"}],title:"IS-9",body:"scope"}' > "$CT/issue9.json"
# the per-project opt-in (MC_TICKET_DEDUPE, default off): the settings list the
# lane gate reads carries lane.merge-conductor.issuer.mc_ticket_dedupe = 1
export DEDUPE_ROWS="$CT/dedupe-rows.json"
# BH-5781: the list carries lead_pr_authors too, as the real list route does
# (every row): setting_get now answers from the fresh list the gate cached.
dedupe_on()  { jq -nc '{settings:[{key:"lead_pr_authors",value:"operator"},{key:"lane.merge-conductor.issuer.mc_ticket_dedupe",value:"1"}]}' > "$DEDUPE_ROWS"; }
dedupe_off() { jq -nc '{settings:[{key:"lead_pr_authors",value:"operator"}]}' > "$DEDUPE_ROWS"; }
dedupe_on
ctick() { # ctick <flag…> — one whole conductor tick with exactly these flags on
  [ -n "$CH" ] || return 1
  local d; for d in "$CH/state" "$CH/logs" "$CH/locks" "$CH/flags"; do scratch_rm "$d"; done; mkdir -p "$CH/state" "$CH/logs" "$CH/locks" "$CH/flags"
  : > "$CT/gh-calls.txt"; : > "$CT/closed.txt"; : > "$CT/merged.txt"; rm -f "$CT/merged9"
  local f; for f in "$@"; do : > "$CH/flags/$f"; done
  ( cd "$CT" && PATH="$CT/fakebin:$PATH" HARNESS="$CH" HARNESS_SECRET=x FLEET_CONF="$CH/fleet.conf" \
      MC_MAIN_RED_DETECT=0 MC_MERGE_SETTLE=0 bash "$CH/bin/merge-conductor.sh" >/dev/null 2>>"$CT/tick.err" ) || true
}
CLOG="$CH/logs/merge-conductor.log"

ctick
[ ! -s "$CT/closed.txt" ] && ok || bad "H1: THE DEFECT — observe mode closed a PR: $(cat "$CT/closed.txt")"
grep -q 'issuer#31 would be CLOSED as a duplicate of #30' "$CLOG" 2>/dev/null && ok \
  || bad "H1: observe mode must say what it would close ($(grep -i 'duplicate' "$CLOG" 2>/dev/null | head -3); err: $(head -c 300 "$CT/tick.err"))"
ctick merge-conductor-actions merge-conductor-merge automerge-disabled
[ ! -s "$CT/closed.txt" ] && ok || bad "H2: THE DEFECT — the kill switch did not stop the close: $(cat "$CT/closed.txt")"
# I-3: the rule is OFF unless the project opted in — no list read, no close.
dedupe_off
ctick merge-conductor-actions
[ ! -s "$CT/closed.txt" ] && ok || bad "H6: a project that has not opted in must not be de-duplicated: $(cat "$CT/closed.txt")"
grep -q 'repos/example-org/issuer/pulls -f state=open' "$CT/gh-calls.txt" && bad "H6: an off project is not even listed" || ok
dedupe_on
ctick merge-conductor-actions
grep -q 'repos/example-org/issuer/pulls/31' "$CT/closed.txt" && ! grep -q 'pulls/30 ' "$CT/closed.txt" && ok \
  || bad "H3: in actions mode the newer duplicate #31 closes and #30 stays (closed: $(cat "$CT/closed.txt"); log: $(grep -i duplicate "$CLOG" | head -2))"

# the merge half: PR 9 is READY (approved at head, clean, green)
echo '[]' > "$CT/restopen.json"
jq -nc '[{body:"HOLD — the lead has this one",created_at:"2026-09-22T11:00:00Z",user:{type:"User"}}]' > "$CT/thread9.json"
ctick merge-conductor-actions merge-conductor-merge
[ ! -s "$CT/merged.txt" ] && ok || bad "H4: THE DEFECT — the conductor merged a pool PR for a held ticket: $(cat "$CT/merged.txt")"
[ "$(grep -c 'issuer#9 MERGE_HELD: ticket #9 is held' "$CLOG" 2>/dev/null)" = 1 ] && ok \
  || bad "H4: exactly one MERGE_HELD line ($(grep -E 'issuer#9' "$CLOG" 2>/dev/null | tail -4); err: $(head -c 300 "$CT/tick.err"))"
[ ! -s "$CH/logs/ALERTS.log" ] && ok || bad "H4: an obeyed hold is not an alert: $(cat "$CH/logs/ALERTS.log")"
rm -f "$CT/thread9.json"
ctick merge-conductor-actions merge-conductor-merge
[ -s "$CT/merged.txt" ] && ok \
  || bad "H5: with the hold gone the same READY PR merges ($(grep -E 'issuer#9' "$CLOG" 2>/dev/null | tail -4); err: $(head -c 300 "$CT/tick.err"))"

# ════════════════════════════════════════════════════════════════════════════
# I. merge-sweep, WHOLE: a held ticket's approved PR is not merged.
# ════════════════════════════════════════════════════════════════════════════
ST="$T/sw"; mkdir -p "$ST"
fx_mc_harness "$DIR" "$ST" || bad "I0: the sweep fixture did not build"
[ -f "$DIR/bin/merge-sweep.sh" ] || exit 1   # impact: this suite drives the whole sweep
cp "$DIR/bin/merge-sweep.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$ST/h/bin/"
mkdir -p "$ST/h/bin/lib" && cp -rL "$DIR/bin/lib/ms" "$ST/h/bin/lib/" || exit 1   # BH-5242: the sweep loads bin/lib/ms/
mkdir -p "$ST/h/bin/lib/jobs"; cp "$DIR"/bin/lib/jobs/*.sh "$ST/h/bin/lib/jobs/"
cp "$DIR/bin/lib/ticket-ownership.sh" "$DIR/bin/lib/hold.sh" "$ST/h/bin/lib/"
for s in beat.sh deploy-request.sh codegraph-ensure.sh lane-alert.sh; do printf '#!/bin/bash\nexit 0\n' > "$ST/h/bin/$s"; chmod +x "$ST/h/bin/$s"; done
printf 'issuer example-org/issuer - - - box-issuer\n' > "$ST/h/fleet.conf"
printf 'HARNESS_SECRET=x\nJOBS_URL=https://jobs.invalid\n' > "$ST/h/env/global.env"
SREC="$ST/h/builds/pool-issuer-IS-9-202609220003"; mkdir -p "$SREC" "$ST/h/state" "$ST/tmp"
echo "PR_CREATED https://github.com/example-org/issuer/pull/9" > "$SREC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$SREC/review.md"
cp "$CT/fakebin/curl" "$ST/fakebin/curl"
cat > "$ST/fakebin/gh" <<GHSTUB
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "\$*" >> "$ST/gh-argv.log"
case "\$*" in
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n'; exit 0 ;;  # BH-1668: the PR's own thread (no HOLD), read over REST by to_merge_hold
  *"pr merge"*|*"-X PUT"*"/merge"*) touch "$ST/merged9"; echo "\$*" >> "$ST/merged.txt"; printf 'HTTP/1.1 200 OK\r\n\r\n{"merged":true,"sha":"cccc3333"}\n'; exit 0 ;;
  *"-X PATCH"*|*"issue close"*) printf 'HTTP/1.1 200 OK\r\n\r\n{"state":"closed"}\n'; exit 0 ;;
  *"-X POST"*"/comments"*) printf 'HTTP/1.1 201 Created\r\n\r\n{"id":1}\n'; exit 0 ;;
  *"api -i -X GET repos/example-org/issuer/issues/9"*) printf 'HTTP/1.1 200 OK\r\n\r\n{"state":"open"}\n'; exit 0 ;;
  *v3.diff*) printf 'HTTP/1.1 200 OK\r\n\r\n+++ b/src/x.ts\n+const a = 1;\n'; exit 0 ;;
  *"api -i -X GET repos/example-org/issuer/pulls/9"*)
    printf 'HTTP/1.1 200 OK\r\n\r\n'
    if [ -e "$ST/merged9" ]; then S=closed; M='"2026-09-22T00:00:00Z"'; else S=open; M=null; fi
    printf '{"state":"%s","merged_at":%s,"head":{"sha":"aaaa1111","ref":"ticket/is-9"},"base":{"ref":"main"},"labels":[],"mergeable":true,"mergeable_state":"clean","user":{"login":"app/cromford","type":"Bot"},"merge_commit_sha":"cccc3333","body":"Closes #9"}\n' "\$S" "\$M"
    exit 0 ;;
  *"repos/example-org/issuer/issues/9/comments?per_page"*) cat "$ST/thread9.json" 2>/dev/null || echo '[]'; exit 0 ;;
  "api repos/example-org/issuer/issues/9") echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"IS-9","body":"scope"}'; exit 0 ;;
  *"pr view"*"mergeCommit"*) [ -e "$ST/merged9" ] && echo cccc3333; exit 0 ;;
  *"pr view"*"--json state,mergeStateStatus"*)
    if [ -e "$ST/merged9" ]; then echo "MERGED CLEAN app/cromford aaaa1111 2026-09-22T00:00:00Z"
    else echo "OPEN CLEAN app/cromford aaaa1111 "; fi; exit 0 ;;
  *"pr view"*"--json state"*) if [ -e "$ST/merged9" ]; then echo MERGED; else echo OPEN; fi; exit 0 ;;
  *"pr view"*"headRefOid"*) echo aaaa1111; exit 0 ;;
  *"pr view"*"headRefName"*) echo ticket/is-9; exit 0 ;;
  *"pr view"*) echo ""; exit 0 ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n'; exit 0 ;;
  *"api repos/example-org/issuer -q .id"*) echo 1; exit 0 ;;
  *"actions/runs?head_sha="*) printf 'completed|success\n'; exit 0 ;;
  *"api -i"*) printf 'HTTP/1.1 404 Not Found\r\n\r\n{"message":"no route"}\n'; exit 0 ;;
  *"rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"auth token"*) echo faketoken ;;
  *) echo "" ;;
esac
exit 0
GHSTUB
chmod +x "$ST/fakebin/gh"
sweep() {
  [ -n "$ST" ] || return 1
  : > "$ST/gh-argv.log"; : > "$ST/merged.txt"; rm -f "$ST/merged9"; : > "$ST/h/state/merge-sweep-done.txt"
  scratch_rm "$ST/h/logs"; mkdir -p "$ST/h/logs"
  ( export PATH="$ST/fakebin:$PATH" HARNESS="$ST/h" HARNESS_TEST_SANDBOX=1 TMPDIR="$ST/tmp" \
           FLEET_CONF="$ST/h/fleet.conf" SWEEP_MERGE_SETTLE=0
    bash "$ST/h/bin/merge-sweep.sh" >/dev/null 2>"$ST/sweep.err" )
}
SLOG="$ST/h/logs/merge-sweep.log"
jq -nc '[{body:"HOLD: the lead has this one",created_at:"2026-09-22T11:00:00Z",user:{type:"User"}}]' > "$ST/thread9.json"
sweep
[ ! -s "$ST/merged.txt" ] && ok || bad "I1: THE DEFECT — merge-sweep merged a pool PR for a held ticket: $(cat "$ST/merged.txt")"
[ "$(grep -c 'issuer#9 MERGE_HELD: ticket #9 is held' "$SLOG" 2>/dev/null)" = 1 ] && ok \
  || bad "I1: exactly one MERGE_HELD line ($(tail -4 "$SLOG" 2>/dev/null); err: $(head -c 300 "$ST/sweep.err"))"
rm -f "$ST/thread9.json"
sweep
[ -s "$ST/merged.txt" ] && ok || bad "I2: the clear ticket's PR merges as today ($(tail -4 "$SLOG" 2>/dev/null); err: $(head -c 300 "$ST/sweep.err"))"

echo "ticket-ownership.bh-1526: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
