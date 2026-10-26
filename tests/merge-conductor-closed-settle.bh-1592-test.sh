#!/bin/bash
# tests/merge-conductor-closed-settle.bh-1592-test.sh — the closed-unmerged
# settle finds the harness's PRs from its OWN records (pr-state rows, build
# records, the closed-watch memo) and reads each by number, instead of paging
# the repo's raw closed list (BH-1592).
#
# THE DEFECT THIS PINS. The settle's only discovery was
# `harness_pr_list "$SLUG" closed … 30`: three REST pages of 100 raw closed PRs,
# author-filtered on the client. On example-org/project-9 289 of the last 300
# closed PRs are aepod's, so a harness PR older by creation than the 300th row
# was never seen and sat in its last live state for good.
#
# WHAT IS DRIVEN. The real bin/merge-conductor.sh, gh and curl stubbed. The stub
# repo example-org/project-9 has 330 closed PRs by creation rank: 319 aepod's and 11
# of ours spread from rank 7 to rank 325, so two of ours are past row 300. Six
# of ours have pr-state rows (WAIT_CI), five have build records only.
#   C2  over four ticks all 11 settle CLOSED, at most 3 pulls GETs a tick, each
#       read once, and no pulls?state=closed walk at all
#   C3  a settled repo costs zero reads
#   C4  MERGED and OPEN candidates never become CLOSED; OPEN rotates to the back
#       and its re-probe goes out with If-None-Match
#   C5  aepod's PRs, a hand branch and another repo's record are never settled
#   C6  a 403 on a probe changes nothing, writes no memo and stops the pass
#   C7  a PR whose lock is held is re-offered, not memo'd closed and dropped
#   C8  the watch store is GC'd on mtime
#   C1  the open list feeds the watch store (drafts included), once
#
# Run from anywhere: tests/merge-conductor-closed-settle.bh-1592-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
export HARNESS="$T/h"
fx_mc_harness "$DIR" "$T" || exit 1
fx_conductor_tick "$DIR" "$T" || exit 1
[ -f "$DIR/bin/merge-conductor.sh" ] || exit 1   # impact: this suite drives the whole tick
# The off-list settle (BH-8310) is a fragment; fx_conductor_tick copies no fragment.
mkdir -p "$T/h/bin/merge-conductor.d" || exit 1
cp "$DIR/bin/merge-conductor.d/bh-8310-stale-row-settle.sh" "$T/h/bin/merge-conductor.d/" || exit 1
# The ETag half of the contract (C3): without gh-rest-etag.sh gh_rest reads
# unconditionally and "the re-probe is conditional" could not be asked.
cp "$DIR/bin/lib/gh-rest-etag.sh" "$T/h/bin/lib/" || exit 1
mkdir -p "$T/pr" || exit 1

# ---- the dense-author closed list: 330 rows, created desc, PR number = 1000 - rank
OURS_RANKS="7 40 75 110 140 180 215 250 290 305 325"
jq -nc --arg ours "$OURS_RANKS" '
  ($ours | split(" ") | map(tonumber)) as $o
  | [range(1; 331)] | map(. as $r | (1000 - $r) as $n | ($o | index($r)) as $mine
    | {number: $n, html_url: "https://github.com/example-org/project-9/pull/\($n)", title: "x", body: "",
       state: "closed", merged_at: null, closed_at: "2026-09-22T01:00:00Z",
       created_at: "2026-09-01T00:00:00Z", updated_at: "2026-09-22T01:00:00Z", draft: false, labels: [],
       user: (if $mine then {login: "operator", type: "User"} else {login: "aepod", type: "User"} end),
       head: {ref: (if $mine then "ticket/sa-\($n)" else "feat/x-\($n)" end), sha: "deadbee"},
       base: {ref: "main"}})' > "$T/closed-all.json" || exit 1
for p in 1 2 3 4; do jq -c ".[$(( (p-1)*100 )):$(( p*100 ))]" "$T/closed-all.json" > "$T/closed-p$p.json" || exit 1; done
OURS="993 960 925 890 860 820 785 750 710 695 675"
ROWN="993 960 925 890 860 695"; RECN="820 785 750 710 675"
for n in $OURS; do echo "CLOSED ticket/sa-$n" > "$T/pr/$n"; done
echo '[]' > "$T/open.json"

# gh: every call recorded; every pulls/<n> read recorded with whether it was
# conditional; answers come from $T/pr/<n> ("STATE BRANCH" or "403"), with an
# ETag that is the state's, so a state change answers 200 and no change 304.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
ARGS="\$*"
case "\$ARGS" in
  *"auth token"*) echo faketoken ;;
  *"pr merge"*|*"push"*|*"pr comment"*|*"issue close"*|*"issue comment"*|*"pr review"*|*"pr edit"*|*"-X PATCH"*|*"-X POST"*)
    echo "WRITE VERB IN OBSERVE MODE: \$ARGS" >> "$T/gh-writes.txt"; exit 1 ;;
  *"pr list -R example-org/project-9 --state open"*) cat "$T/open.json" ;;
  *"repos/example-org/project-9/pulls?state=closed"*)
    pg=\${ARGS##*page=}; pg=\${pg%% *}
    printf 'HTTP/2.0 200\r\n\r\n'; cat "$T/closed-p\$pg.json" 2>/dev/null || echo '[]' ;;
  *"api -i -X GET repos/example-org/project-9/pulls/"*"/"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/project-9/pulls/"*)
    n=\${ARGS#*project-9/pulls/}; n=\${n%% *}
    case "\$ARGS" in *If-None-Match*) c=cond ;; *) c=plain ;; esac
    printf '%s %s\n' "\$n" "\$c" >> "$T/probes.txt"
    spec=\$(cat "$T/pr/\$n" 2>/dev/null) || { restpr --raw 404 '{"message":"Not Found"}'; exit 0; }
    set -- \$spec
    [ "\$1" = 403 ] && { restpr --raw 403 '{"message":"API rate limit exceeded for installation"}'; exit 0; }
    et="\"p\$n-\$1\""
    case "\$ARGS" in *"If-None-Match: \$et"*) printf 'HTTP/1.1 304 Not Modified\r\nETag: %s\r\n\r\n' "\$et"; exit 0 ;; esac
    printf 'HTTP/1.1 200 OK\r\nETag: %s\r\n\r\n' "\$et"
    restpr "\$1" deadbee "\$2" main | tail -1 ;;
  *"api -i -X GET repos/example-org/other/"*) printf '%s\n' "\$ARGS" >> "$T/other.txt"; restpr --raw 404 '{"message":"Not Found"}' ;;
  *"pr list"*) echo "[]" ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
# TEST-CHANGE (fix main red after #1614 + #1620): the open-PR list is REST now
# (BH-1585: a `pulls?state=open` page plus lazy per-PR reads). This stub still
# describes it as the GraphQL `pr list --state open`, so the bridge answers the
# REST reads from that description, as in every sibling conductor suite.
# Without it the open list is unreadable and the tick never reaches the settle.
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
printf '{"error":"not found"}\n404\n'
EOF
chmod +x "$T/fakebin/curl"

printf 'project-9 example-org/project-9 https://project-9.example /api/board 2 box-project-9-1\n' > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"

ROWS="$T/h/state/merge-conductor/pr-state.tsv"
LOG="$T/h/logs/merge-conductor.log"
WATCH="$T/h/state/merge-conductor/closed-watch/example-org_project-9"
seed_row()   { printf 'example-org/project-9#%s\tWAIT_CI\t%s\t-\t-\t-\t-\thttps://github.com/example-org/project-9/pull/%s\n' "$1" "$(date -u +%s)" "$1" >> "$ROWS"; }
seed_rec()   { mkdir -p "$T/h/builds/project-9-SA-$1-202609220001" && echo "PR_CREATED https://github.com/${2:-example-org/project-9}/pull/$1" > "$T/h/builds/project-9-SA-$1-202609220001/RESULT"; }
state_of()   { awk -F'\t' -v k="example-org/project-9#$1" '$1==k {print $2}' "$ROWS"; }
memo()       { cut -f1,2 "$WATCH/$1" 2>/dev/null | tr '\t' ' '; }
# The settle's reads: every pulls request EXCEPT the tick's one open-list page
# (`pulls?state=open`, REST since BH-1585, a GraphQL `pr list` when this budget
# was written). That page is the tick's own list read, not the settle's; it is
# pinned separately below, at most one a tick, so excluding it hides nothing.
settle_calls() { grep 'repos/example-org/project-9/pulls' "$T/gh-calls.txt" | grep -v 'pulls?state=open' || true; }
tick_pulls()   { settle_calls | grep -c . || true; }
open_pages()   { grep -c 'repos/example-org/project-9/pulls?state=open' "$T/gh-calls.txt" || true; }
run_tick() {
  : > "$T/gh-calls.txt"; : > "$T/probes.txt"
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x MC_PR_PARALLEL=1 \
    MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) \
    || { echo "tick rc=$? stderr:"; tail -5 "$T/tick.err"; }
  cat "$T/probes.txt" >> "$T/probes-all.txt"
}
: > "$T/probes-all.txt"; : > "$T/gh-writes.txt"
mkdir -p "$(dirname "$ROWS")"
for n in $ROWN; do seed_row "$n"; done
for n in $RECN; do seed_rec "$n"; done

# ============================================================================
# C2. THE TICKET'S ACCEPTANCE: all 11 settle within the per-tick budget.
# ============================================================================
C2_OVER=""; C2_WALK=0
for i in 1 2 3 4; do
  run_tick
  P=$(tick_pulls); [ "$P" -le 3 ] || C2_OVER="$C2_OVER tick$i=$P"
  O=$(open_pages); [ "$O" -le 1 ] || C2_OVER="$C2_OVER tick$i-open-pages=$O"
  C2_WALK=$((C2_WALK + $(grep -c 'pulls?state=closed' "$T/gh-calls.txt" || true)))
  [ "$i" = 1 ] && T1LOG=$(grep 'CLOSED-PROBE' "$LOG" 2>/dev/null | tail -1)
done
NCLOSED=0; MISSING=""
for n in $OURS; do if [ "$(state_of "$n")" = CLOSED ]; then NCLOSED=$((NCLOSED+1)); else MISSING="$MISSING #$n=$(state_of "$n")"; fi; done
[ "$NCLOSED" = 11 ] && ok || bad "C2: all 11 closed-unmerged harness PRs must settle CLOSED within 4 ticks (got $NCLOSED of 11; not settled:$MISSING)"
[ -z "$C2_OVER" ] && ok || bad "C2: no tick may make more than 3 pulls requests (today's page budget):$C2_OVER"
[ "$C2_WALK" = 0 ] && ok || bad "C2: the conductor must not walk the raw closed list any more ($C2_WALK pulls?state=closed calls)"
TWICE=""; for n in $OURS; do c=$(grep -c "^$n " "$T/probes-all.txt" || true); [ "$c" = 1 ] || TWICE="$TWICE #$n=$c"; done
[ -z "$TWICE" ] && ok || bad "C2: each of the 11 must be read exactly once:$TWICE"
case "$T1LOG" in *"CLOSED-PROBE candidates=11 probed=3 closed=3 deferred=8 budget=3"*) ok ;;
  *) bad "C2: tick 1 must ledger its capped probe (got: ${T1LOG:-no CLOSED-PROBE line})" ;; esac
[ -s "$T/gh-writes.txt" ] && bad "an observe-mode tick used a write verb: $(cat "$T/gh-writes.txt")" || ok

# ============================================================================
# C3. STEADY STATE: a settled repo costs zero reads.
# ============================================================================
L0=$(grep -c 'CLOSED-PROBE' "$LOG" 2>/dev/null || true)
run_tick
[ "$(tick_pulls)" = 0 ] && ok || bad "C3: a tick with every candidate settled must make zero pulls requests (got $(tick_pulls): $(settle_calls | head -3))"
[ "$(open_pages)" -le 1 ] && ok || bad "C3: a settled tick reads the open list at most once (got $(open_pages))"
[ "$(grep -c 'CLOSED-PROBE' "$LOG" 2>/dev/null || true)" = "$L0" ] && ok || bad "C3: zero candidates must log nothing"

# ============================================================================
# C4 + C5. MERGED / OPEN candidates; a hand branch; another repo's record.
# ============================================================================
seed_row 600; echo "OPEN ticket/sa-600" > "$T/pr/600"
seed_row 500; echo "MERGED ticket/sa-500" > "$T/pr/500"
seed_rec 400; echo "CLOSED ticket/sa-400" > "$T/pr/400"
mkdir -p "$WATCH"; printf 'open\t0\thttps://github.com/example-org/project-9/pull/450\tfix/by-hand\n' > "$WATCH/450"
echo "CLOSED fix/by-hand" > "$T/pr/450"
seed_rec 5 example-org/other
run_tick   # candidates 600 500 450 400: budget 3, 400 deferred
[ "$(cut -d' ' -f1 "$T/probes.txt" | tr '\n' ' ')" = "600 500 450 " ] && ok || bad "C4: never-probed candidates go by number, newest first (got: $(tr '\n' ' ' < "$T/probes.txt"))"
# TEST-CHANGE (BH-8310): this asserted the row stays WAIT_CI. That premise was
# the defect: a merged PR's row then never left WAIT_CI. It now moves to MERGED,
# which still proves "never CLOSED" and is stricter.
[ "$(state_of 500)" = MERGED ] && ok || bad "C4: a MERGED harness PR must become MERGED, never CLOSED (row: $(state_of 500))"
[ "$(memo 500)" != "" ] && [ "$(memo 500 | cut -d' ' -f1)" = merged ] && ok || bad "C4: a MERGED probe is memo'd merged (memo: $(memo 500))"
[ "$(state_of 600)" = WAIT_CI ] && ok || bad "C4: an OPEN harness PR must not become CLOSED (row: $(state_of 600))"
[ "$(memo 600 | cut -d' ' -f1)" = open ] && [ "$(memo 600 | cut -d' ' -f2)" != 0 ] && ok || bad "C4: an OPEN probe is memo'd open with its probe time (memo: $(memo 600))"
[ -z "$(state_of 450)" ] && ok || bad "C5: a closed hand-branch PR with no record must get no row (row: $(state_of 450))"
run_tick   # 400 (never probed) before 600 (probed last tick); 500 memo'd merged
[ "$(cut -d' ' -f1 "$T/probes.txt" | tr '\n' ' ')" = "400 600 " ] && ok || bad "C4: a never-probed candidate goes before one probed last tick, and a merged memo is not re-read (got: $(tr '\n' ' ' < "$T/probes.txt"))"
[ "$(state_of 400)" = CLOSED ] && ok || bad "C4: the deferred candidate settles on the next tick (row: $(state_of 400))"
grep -q '^600 cond$' "$T/probes.txt" && ok || bad "C3: the re-probe of an OPEN candidate must go out with If-None-Match (probes: $(tr '\n' ' ' < "$T/probes.txt"))"
[ "$(state_of 600)" = WAIT_CI ] && ok || bad "C4: a 304 on an OPEN candidate must still not settle it (row: $(state_of 600))"
[ -s "$T/other.txt" ] && bad "C5: a record for another repo must never be read on this slug's pass: $(head -1 "$T/other.txt")" || ok
AEPOD=$(cut -d' ' -f1 "$T/probes-all.txt" | sort -u | grep -vxE '993|960|925|890|860|820|785|750|710|695|675|600|500|450|400' | tr '\n' ' ')
[ -z "$AEPOD" ] && ok || bad "C5: only the harness's own PRs may ever be read (also read: $AEPOD)"
echo "MERGED ticket/sa-600" > "$T/pr/600"
run_tick   # 600 merges: memo'd merged, dropped from the candidates
run_tick
[ "$(tick_pulls)" = 0 ] && ok || bad "C4: once every candidate is memo'd merged/closed the pass reads nothing (got $(tick_pulls))"

# ============================================================================
# C6. A 403 ON A PROBE: no row change, no memo, the pass stops, next tick retries.
# ============================================================================
seed_row 350; echo "CLOSED ticket/sa-350" > "$T/pr/350"
seed_row 300; echo "403" > "$T/pr/300"
seed_rec 250; echo "CLOSED ticket/sa-250" > "$T/pr/250"
run_tick
[ "$(state_of 350)" = CLOSED ] && ok || bad "C6: the read before the 403 still settles (row: $(state_of 350))"
[ "$(state_of 300)" = WAIT_CI ] && ok || bad "C6: a 403 must change no row (row: $(state_of 300))"
[ -e "$WATCH/300" ] && bad "C6: a 403 must write no memo (memo: $(cat "$WATCH/300"))" || ok
grep -q '^250 ' "$T/probes.txt" && bad "C6: the pass must stop probing after an unreadable answer" || ok
grep -q 'closed probe of #300 unreadable (HTTP 403.*2 candidates deferred to the next tick' "$LOG" && ok || bad "C6: the unreadable probe is said with what it deferred (log: $(grep '#300' "$LOG" | tail -1))"
grep 'CLOSED-PROBE' "$LOG" | tail -1 | grep -q 'candidates=3 probed=1 closed=1 deferred=2' && ok || bad "C6: the ledger line counts the failed read as deferred (got: $(grep 'CLOSED-PROBE' "$LOG" | tail -1))"
echo "CLOSED ticket/sa-300" > "$T/pr/300"
run_tick
[ "$(head -1 "$T/probes.txt" | cut -d' ' -f1)" = 300 ] && ok || bad "C6: the deferred candidate is probed first next tick (got: $(tr '\n' ' ' < "$T/probes.txt"))"
[ "$(state_of 300)" = CLOSED ] && [ "$(state_of 250)" = CLOSED ] && ok || bad "C6: both deferred candidates settle next tick (300=$(state_of 300) 250=$(state_of 250))"

# ============================================================================
# C7. A HELD PR LOCK: the settle is re-offered, not memo'd closed and dropped.
# ============================================================================
seed_row 150; echo "CLOSED ticket/sa-150" > "$T/pr/150"
exec 8>"$T/h/locks/merge-conductor-project-9-150.lock"; flock -n 8 || bad "C7: the test could not take the PR lock"
run_tick
[ "$(state_of 150)" = WAIT_CI ] && ok || bad "C7: a PR whose lock is held must not be settled this tick (row: $(state_of 150))"
[ "$(memo 150)" = "open 0" ] && ok || bad "C7: a lock-skipped settle resets its memo to open 0 (memo: $(memo 150))"
exec 8>&-
run_tick
[ "$(state_of 150)" = CLOSED ] && ok || bad "C7: once the lock is free the PR settles (row: $(state_of 150))"

# ============================================================================
# C8. GC on mtime: a 40-day memo goes, a 5-day one stays.
# ============================================================================
printf 'merged\t1\thttps://github.com/example-org/project-9/pull/111\tticket/sa-111\n' > "$WATCH/111"
printf 'merged\t1\thttps://github.com/example-org/project-9/pull/112\tticket/sa-112\n' > "$WATCH/112"
touch -d '40 days ago' "$WATCH/111"; touch -d '5 days ago' "$WATCH/112"
run_tick
[ -e "$WATCH/111" ] && bad "C8: a watch memo older than 30 days must be GC'd" || ok
[ -e "$WATCH/112" ] && ok || bad "C8: a 5-day-old watch memo must be kept"

# ============================================================================
# C1. THE OPEN LIST FEEDS THE WATCH STORE, drafts included, written once.
# ============================================================================
cat > "$T/open.json" <<'J'
[{"number":11,"url":"https://github.com/example-org/project-9/pull/11","headRefOid":"aaaa0011","headRefName":"ticket/sa-11","isDraft":true,"mergeStateStatus":"DRAFT","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"main"},
 {"number":12,"url":"https://github.com/example-org/project-9/pull/12","headRefOid":"aaaa0012","headRefName":"ticket/sa-12","isDraft":false,"mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"main"}]
J
echo "OPEN ticket/sa-11" > "$T/pr/11"; echo "OPEN ticket/sa-12" > "$T/pr/12"
L0=$(grep -c 'CLOSED-PROBE' "$LOG" 2>/dev/null || true)
run_tick
[ "$(memo 11)" = "open 0" ] && [ "$(memo 12)" = "open 0" ] && ok || bad "C1: every PR on the open list, draft included, gets a watch memo (11: $(memo 11), 12: $(memo 12))"
cp "$WATCH/11" "$T/w11" 2>/dev/null; cp "$WATCH/12" "$T/w12" 2>/dev/null
run_tick
cmp -s "$WATCH/11" "$T/w11" && cmp -s "$WATCH/12" "$T/w12" && ok || bad "C1: a second tick must not rewrite a watch memo"
[ "$(grep -c 'CLOSED-PROBE' "$LOG" 2>/dev/null || true)" = "$L0" ] && ok || bad "C1: a PR on this tick's open list is never a closed candidate"
# Both leave the list closed: the draft has no row and no record, #12 no record.
echo '[]' > "$T/open.json"
echo "CLOSED ticket/sa-11" > "$T/pr/11"; echo "CLOSED ticket/sa-12" > "$T/pr/12"
run_tick
[ "$(state_of 11)" = CLOSED ] && [ "$(state_of 12)" = CLOSED ] && ok || bad "C1: a record-less PR the watch store saw open settles when it closes (11=$(state_of 11) 12=$(state_of 12))"

echo "merge-conductor-closed-settle.bh-1592-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
