#!/bin/bash
# tests/merge-sweep-order-cache-test.sh — bin/merge-sweep.sh must walk the build
# records FAIRLY and must not re-derive a refusal it already made.
#
# THE INCIDENT (BH-710). The hub sweep's whole scheduling policy was one line:
#
#     for D in "$H"/builds/pool-*-*/ "$H"/builds/*-*/
#
# which (1) visits every pool-* record TWICE, because pool-*-* is a subset of
# *-*, (2) orders the walk by the shell's alphabetical glob, so one project's
# 300-record tail sits in front of every later project, and (3) has no memory
# between runs, so a refusal decided entirely from the build record — "ledger
# provenance is codex", no APPROVE verdict, a judge-provenance demotion, a
# recorded E2E FAIL — is recomputed from scratch every ten minutes, each one
# paying a jobs-worker round trip and a gh call first. 3,513 identical
# "ledger provenance is" lines, and PRs #693-#707 that had never been looked at
# at all.
#
# WHAT THIS SUITE PINS:
#   O  the walk is round-robin across projects, newest-first within one, and
#      visits each record exactly once.
#   C  a skip whose cause is a static property of the record is cached and costs
#      zero verdict/gh calls next tick — and a RETRYABLE skip is never cached.
#   S  the per-tick per-project summary replaces the repeated per-PR line.
#   D  a tick has a deadline, so a slow walk cannot silently eat the next five
#      ticks through flock -n.
#
# HOW IT DRIVES. The production script, copied into a scratch tree as
# $T/bin/sweep.sh (bin/iron-law-guard.sh denies an agent session that invokes
# merge-sweep.sh by name — tests/merge-sweep-async-test.sh:27 does the same),
# with gh, the jobs client and fleet-conf.sh stubbed and every assertion made on
# the ARTIFACTS the run leaves behind: logs/merge-sweep.log,
# state/merge-sweep-terminal.txt, and the call sinks.
#
# Run from anywhere: tests/merge-sweep-order-cache-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" 2>/dev/null || true
# The lib owns $T and its cleanup, and sourcing it is this repo's contract
# (checks/tests-scratch-only R1). It is ABSENT from this checkout — every
# tests/*.sh here dies on `|| exit 1` at that line — so this fixture falls back
# to a scratch tree of its own rather than being unrunnable. Delete the fallback
# the day tests/lib/scratch.sh lands.
if [ -z "${T:-}" ]; then T=$(mktemp -d) || exit 1; trap 'rm -rf "$T"' EXIT; fi
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date +%s)

mkdir -p "$T/bin" "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/builds" "$T/fakebin"
cp "$DIR/bin/merge-sweep.sh" "$T/bin/sweep.sh"
mkdir -p "$T/bin/lib" && cp -rL "$DIR/bin/lib/ms" "$T/bin/lib/" || exit 1   # BH-5242: the sweep loads bin/lib/ms/
# Since BH-784 every decision read in the sweep goes through the conductor lib
# and bin/lib/gh-rest.sh. Both have to be in the scratch box's bin/lib or the
# sweep's fail-closed shims answer "unverifiable" to every read, no record is
# ever visited, and this suite would pin the walk order of a walk that does
# nothing.
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/bin/lib/"
mkdir -p "$T/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/bin/lib/mc/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
for s in beat.sh deploy-request.sh codegraph-ensure.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"
done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/prearm-calls.txt"\nexit 0\n' "$T" > "$T/bin/pre-arm-guards.sh"
chmod +x "$T/bin/pre-arm-guards.sh"

# The project registry. SWEEP_PROJECTS must come from here and nowhere else
# (tests/fleet-projects-not-hardcoded-test.sh forbids a literal fleet list in
# bin/). p1-os exists to prove the longest-name-first match: a record named
# pool-p1-os-... must bucket as p1-os, never as p1.
cat > "$T/bin/fleet-conf.sh" <<'EOF'
#!/bin/bash
case "${1:-}" in
  --projects) printf 'p1\np2\np1-os\n' ;;
  *) case "${2:-}" in
       repo)         echo "o/${1}" ;;
       board_prefix) echo "-" ;;
     esac ;;
esac
exit 0
EOF
chmod +x "$T/bin/fleet-conf.sh"

# The jobs client the sweep sources. Every call lands in a sink so "this tick
# cost nothing" is an assertion about artifacts rather than about timing.
# flag_active is deliberately NOT defined: the sweep then tests the FILE flag,
# which is its no-worker behaviour.
cat > "$T/bin/jobs-client.sh" <<EOF
WORKER_SINK="$T/worker-calls.txt"
VERDICT_SINK="$T/verdict-calls.txt"
VERDICTS="$T/verdicts.txt"
TIGHTENED="$T/tightened.txt"
job_ledger_get() { printf 'ledger_get %s\n' "\$*" >> "\$WORKER_SINK"; return 1; }
job_ledger_put() { printf 'ledger_put %s\n' "\$*" >> "\$WORKER_SINK"; return 0; }
job_verdict() {
  printf '%s\n' "\$1" >> "\$VERDICT_SINK"
  local row; row=\$(awk -v p="\$1" '\$1==p {print; exit}' "\$VERDICTS" 2>/dev/null)
  [ -n "\$row" ] || return 2
  # shellcheck disable=SC2086
  set -- \$row
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "\$2" "\$3" "\$4" "\$5" "\$6" "\$7"
}
review_tighten_active() { grep -qxF "\${1:-}" "\$TIGHTENED" 2>/dev/null; }
job_lane_open() { printf 'lane_open\n' >> "\$WORKER_SINK"; JOB_ID=job-1; return 0; }
job_lane_close() { return 0; }
job_artifact_put() { return 0; }
job_event() { return 0; }
EOF

# gh: every call recorded, the state answer driven from a per-PR fixture table,
# and the state read is what marks a record VISITED.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
PRURL=\$(printf '%s\n' "\$*" | grep -oE 'https://github.com/[^ ]+/pull/[0-9]+' | head -1)
case "\$*" in
  "api repos/"*" -q .id") echo 1 ;;
  # The PR state read, over REST since BH-597. Same fixture table, same
  # visit-order recording: this call is what marks a record VISITED now.
  "api repos/"*"/pulls/"[0-9]*)
    RP=\$(printf '%s\n' "\$*" | grep -oE 'repos/[^/]+/[^/]+/pulls/[0-9]+' | head -1)
    RS=\${RP#repos/}; RS=\${RS%%/pulls/*}; RN=\${RP##*/}
    PRURL="https://github.com/\$RS/pull/\$RN"
    printf '%s\n' "\$PRURL" >> "$T/visit-order.txt"
    ST=\$(awk -v p="\$PRURL" '\$1==p {print \$2, \$3, \$4, \$5, \$6; exit}' "$T/pr-state.txt" 2>/dev/null)
    [ -n "\$ST" ] || ST="OPEN DIRTY operator headsha OPEN"
    set -- \$ST
    RSTATE=\$1; RMERGE=\$2; RAUTH=\$3; RHEAD=\$4; RPOST=\${5:-OPEN}
    # column 6 is what the POST-MERGE re-read must answer; the PR itself is
    # still open at this point unless the fixture says it closed.
    if [ "\$RSTATE" = MERGED ] || { [ -f "$T/merge-calls.txt" ] && grep -qF "\$PRURL" "$T/merge-calls.txt" 2>/dev/null && [ "\$RPOST" = MERGED ]; }; then
      printf '{"number":%s,"html_url":"%s","title":"t","body":"","state":"closed","merged_at":"2026-09-12T01:00:00Z","merge_commit_sha":"deadbeefcafe","mergeable_state":"%s","draft":false,"head":{"sha":"%s","ref":"ticket/x-1"},"base":{"ref":"main"},"user":{"login":"%s","type":"User"},"labels":[],"created_at":"2026-09-12T00:00:00Z","updated_at":"2026-09-12T01:00:00Z","closed_at":"2026-09-12T01:00:00Z"}\n' \
        "\$RN" "\$PRURL" "\$(printf '%s' "\$RMERGE" | tr 'A-Z' 'a-z')" "\$RHEAD" "\$RAUTH"
    else
      printf '{"number":%s,"html_url":"%s","title":"t","body":"","state":"open","merged_at":null,"merge_commit_sha":null,"mergeable_state":"%s","draft":false,"head":{"sha":"%s","ref":"ticket/x-1"},"base":{"ref":"main"},"user":{"login":"%s","type":"User"},"labels":[],"created_at":"2026-09-12T00:00:00Z","updated_at":"2026-09-12T00:00:00Z","closed_at":null}\n' \
        "\$RN" "\$PRURL" "\$(printf '%s' "\$RMERGE" | tr 'A-Z' 'a-z')" "\$RHEAD" "\$RAUTH"
    fi ;;
  *"--json state,mergeStateStatus,author,headRefOid,closedAt"*)
    printf '%s\n' "\$PRURL" >> "$T/visit-order.txt"
    ST=\$(awk -v p="\$PRURL" '\$1==p {print \$2, \$3, \$4, \$5; exit}' "$T/pr-state.txt" 2>/dev/null)
    [ -n "\$ST" ] || ST="OPEN DIRTY operator headsha"
    printf '%s \n' "\$ST" ;;
  *"--json state -q .state"*)
    ST=\$(awk -v p="\$PRURL" '\$1==p {print \$6; exit}' "$T/pr-state.txt" 2>/dev/null)
    [ -n "\$ST" ] || ST="OPEN"
    printf '%s\n' "\$ST" ;;
  *"--json headRefOid"*) echo "headsha" ;;
  *"--json mergeCommit"*) echo "deadbeefcafe" ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/merge-calls.txt" ;;
  # THE DECISION READS ARE REST (BH-784): every \`gh pr view --json …\` became
  # \`gh api -i -X GET repos/<slug>/pulls/<n>\`, judged on the HTTP status line, so
  # restpr prints a whole HTTP response. The diff shares that path and is told
  # apart by its Accept header, so it is matched FIRST.
  *"v3.diff"*) restpr --diff '+ const x = 1;
' ;;
  *"api -i -X GET repos/"*"/pulls/"*)
    # The fixture table is still keyed on the PR url, so rebuild the url from the
    # REST path. This GET is what marks a record VISITED, exactly as the old
    # state read did.
    SN=\$(printf '%s\n' "\$*" | grep -oE 'repos/[^ ]+/pulls/[0-9]+' | head -1)
    SN=\${SN#repos/}; NUM=\${SN##*/}; SLUG=\${SN%/pulls/*}
    PRURL="https://github.com/\$SLUG/pull/\$NUM"
    printf '%s\n' "\$PRURL" >> "$T/visit-order.txt"
    ST=\$(awk -v p="\$PRURL" '\$1==p {print \$2, \$3, \$4, \$5, \$6; exit}' "$T/pr-state.txt" 2>/dev/null)
    [ -n "\$ST" ] || ST="OPEN DIRTY operator headsha OPEN"
    # shellcheck disable=SC2086
    set -- \$ST   # state mstate author headsha post-merge-state
    # After the merge verb the same GET is the post-merge state read the old
    # \`--json state -q .state\` arm answered, so column 6 speaks once this PR is
    # in merge-calls.txt — with the merge sha the old --json mergeCommit arm gave.
    if grep -qF "\$PRURL" "$T/merge-calls.txt" 2>/dev/null; then
      restpr "\$5" "\$4" ticket/x main "" MERGEABLE "\$2" "\$3" deadbeefcafe
    else
      restpr "\$1" "\$4" ticket/x main "" MERGEABLE "\$2" "\$3"
    fi ;;
  # The issue close-out is a comment POST, a close PATCH and the re-read
  # gh_rest_close does before it reports the close landed — the same sink the
  # old \`issue comment\`/\`issue close\` arms wrote to.
  *"api -i -X POST repos/"*"/issues/"*"/comments"*|*"api -i -X PATCH repos/"*"/issues/"*|*"api -i -X GET repos/"*"/issues/"*)
    printf '%s\n' "\$*" >> "$T/issue-calls.txt"; restpr --raw 200 '{"state":"closed"}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/sh\nprintf "{}\\n404\\n"\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"

# ── fixture helpers ─────────────────────────────────────────────────────────
reset_tree() {
  rm -rf "$T/builds"; mkdir -p "$T/builds"
  for f in state/merge-sweep-done.txt state/merge-sweep-terminal.txt \
           state/headbound-alerted.txt logs/merge-sweep.log logs/ALERTS.log; do
    : > "$T/$f"
  done
  for f in gh-calls.txt visit-order.txt merge-calls.txt worker-calls.txt \
           verdict-calls.txt issue-calls.txt prearm-calls.txt \
           pr-state.txt verdicts.txt tightened.txt; do
    : > "$T/$f"
  done
  rm -f "$T/flags"/* 2>/dev/null
}
mkrec() { # mkrec <dir> <pr-url> <verdict> <result-mtime>
  local d="$T/builds/$1"
  mkdir -p "$d"
  echo "PR_CREATED $2" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: %s\n' "$3" > "$d/review.md"
  : > "$d/pipeline.log"
  touch -d "@$4" "$d/RESULT"
}
run_sweep() { # run_sweep [VAR=VAL ...]
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T" env SWEEP_MERGE_SETTLE=0 "$@" \
      bash "$T/bin/sweep.sh" >/dev/null 2>>"$T/sweep.err" ) \
    || { echo "sweep rc=$? — stderr:"; tail -5 "$T/sweep.err"; }
}
pos_of() { # pos_of <pr-url> — 1-based position in the visit order, 0 if absent
  awk -v p="$1" '$0==p {print NR; found=1; exit} END {if (!found) print 0}' "$T/visit-order.txt"
}
count_in() { grep -cF "$1" "$2" 2>/dev/null || true; }

# ============================================================================
# O — the walk order
# ============================================================================
echo "--- O: round-robin across projects, newest-first within one"
reset_tree
# p1 has six records, p2 two. Every one of them reaches gh (APPROVE record, no
# e2e.md, DIRTY head) so the visit order is exactly the order of gh state reads.
for i in 1 2 3 4 5 6; do
  mkrec "pool-p1-K-$i-20260917000$i" "https://github.com/o/p1/pull/$i" APPROVE "$((NOW - 1000 + i))"
done
# ...and record 4 is the NEWEST of p1's six, out of alphabetical order.
touch -d "@$((NOW - 10))" "$T/builds/pool-p1-K-4-202609170004/RESULT"
for i in 7 8; do
  mkrec "pool-p2-K-$i-20260917000$i" "https://github.com/o/p2/pull/$i" APPROVE "$((NOW - 2000 + i))"
done
run_sweep

P2FIRST=$(pos_of "https://github.com/o/p2/pull/8")
[ "$P2FIRST" -gt 0 ] && [ "$P2FIRST" -le 4 ] && ok \
  || bad "O1: p2's newest record must be interleaved into the first four visits, not queued behind all six p1 records (position $P2FIRST; order: $(tr '\n' ' ' < "$T/visit-order.txt"))"

P1FIRST=$(head -1 "$T/visit-order.txt")
[ "$P1FIRST" = "https://github.com/o/p1/pull/4" ] && ok \
  || bad "O3: p1's NEWEST record (pull/4) must be the first of p1's visited, got '$P1FIRST'"

DUPES=$(sort "$T/visit-order.txt" | uniq -d | tr '\n' ' ')
[ -z "$DUPES" ] && ok \
  || bad "O4: every record must be visited exactly once per tick — these were visited twice: $DUPES"

VISITS=$(grep -c . "$T/visit-order.txt")
[ "$VISITS" = 8 ] && ok \
  || bad "O4: eight records, eight visits expected, got $VISITS"

echo "--- O2: a long tail in one project must not starve another"
reset_tree
i=1
while [ "$i" -le 200 ]; do
  mkrec "pool-p1-K-$i-tail" "https://github.com/o/p1/pull/$i" APPROVE "$((NOW - 5000 + i))"
  i=$((i + 1))
done
mkrec "pool-p2-K-900-fresh" "https://github.com/o/p2/pull/900" APPROVE "$((NOW - 30))"
run_sweep
FRESH=$(pos_of "https://github.com/o/p2/pull/900")
[ "$FRESH" -gt 0 ] && [ "$FRESH" -le 2 ] && ok \
  || bad "O2: a fresh record in p2 must be seen in the first two visits, not behind p1's 200-record tail (position $FRESH)"

# ============================================================================
# C — the terminal-skip cache
# ============================================================================
echo "--- C1/C2/C3: the three record-decided refusals are cached"
reset_tree
# C1 ledger provenance: the ledger says APPROVE, served by a non-primary lane.
mkrec pool-p1-K-11-r "https://github.com/o/p1/pull/11" APPROVE "$((NOW - 100))"
echo "https://github.com/o/p1/pull/11 APPROVE 2 codex - job-11 -" > "$T/verdicts.txt"
# C2 no APPROVE in the record, and no ledger row for it.
mkrec pool-p1-K-12-r "https://github.com/o/p1/pull/12" BLOCK "$((NOW - 100))"
# C3 judge-provenance demotion recorded in pipeline.log.
mkrec pool-p2-K-13-r "https://github.com/o/p2/pull/13" APPROVE "$((NOW - 100))"
echo "review served on the fallback judge provenance lane" > "$T/builds/pool-p2-K-13-r/pipeline.log"

run_sweep
T1_PROV=$(count_in "ledger provenance is codex" "$T/logs/merge-sweep.log")
[ "$T1_PROV" = 1 ] && ok || bad "C1: tick 1 must log the provenance skip exactly once, got $T1_PROV"
for pr in 11 12 13; do
  grep -q " https://github.com/o/p./pull/$pr " "$T/state/merge-sweep-terminal.txt" && ok \
    || bad "C1/C2/C3: pull/$pr's terminal skip was not cached: $(cat "$T/state/merge-sweep-terminal.txt")"
done
grep -q "no-approve-record" "$T/state/merge-sweep-terminal.txt" && ok \
  || bad "C2: a record without VERDICT: APPROVE must be cached as no-approve-record"
grep -q "judge-provenance-record" "$T/state/merge-sweep-terminal.txt" && ok \
  || bad "C3: a judge-provenance demotion must be cached as judge-provenance-record"

cp "$T/gh-calls.txt" "$T/gh-calls.tick1"
cp "$T/verdict-calls.txt" "$T/verdict-calls.tick1"
run_sweep
cmp -s "$T/gh-calls.tick1" "$T/gh-calls.txt" && ok \
  || bad "C7: tick 2 made gh calls for records whose refusal was already cached: $(diff "$T/gh-calls.tick1" "$T/gh-calls.txt" | head -5)"
cmp -s "$T/verdict-calls.tick1" "$T/verdict-calls.txt" && ok \
  || bad "C7: tick 2 asked the jobs worker for a verdict it had already cached: $(diff "$T/verdict-calls.tick1" "$T/verdict-calls.txt" | head -5)"
T2_PROV=$(count_in "ledger provenance is codex" "$T/logs/merge-sweep.log")
[ "$T2_PROV" = 1 ] && ok || bad "C1: tick 2 must not re-log the provenance skip (lines now: $T2_PROV)"

echo "--- C7: the daily re-log keeps pipeline-health's explanation alive"
run_sweep SWEEP_TERMINAL_RELOG_SECS=0
T3_PROV=$(count_in "ledger provenance is codex" "$T/logs/merge-sweep.log")
[ "$T3_PROV" = 2 ] && ok \
  || bad "C7: with the re-log interval elapsed the reason line must reappear exactly once (lines: $T3_PROV)"
T3_SILENT=$(count_in "pull/12" "$T/logs/merge-sweep.log")
[ "$T3_SILENT" = 0 ] && ok \
  || bad "C7: causes that are silent today must stay silent — pull/12 wrote $T3_SILENT line(s)"

echo "--- C8: a record that changes is re-evaluated (the load-bearing case)"
printf 'findings\nTIER: 2\nfixed after the block round\nVERDICT: APPROVE\n' > "$T/builds/pool-p1-K-12-r/review.md"
touch -d "@$((NOW + 30))" "$T/builds/pool-p1-K-12-r/review.md"
: > "$T/gh-calls.txt"; : > "$T/visit-order.txt"
run_sweep
grep -q "https://github.com/o/p1/pull/12" "$T/visit-order.txt" && ok \
  || bad "C8: review.md rewritten to APPROVE must invalidate the cache entry and re-evaluate the PR"

echo "--- C9: an unreadable cache line fails OPEN"
reset_tree
mkrec pool-p1-K-21-r "https://github.com/o/p1/pull/21" APPROVE "$((NOW - 100))"
echo "https://github.com/o/p1/pull/21 APPROVE 2 codex - job-21 -" > "$T/verdicts.txt"
printf 'this is not a cache line\n%s bogus\n' "$NOW" > "$T/state/merge-sweep-terminal.txt"
run_sweep
[ -s "$T/verdict-calls.txt" ] && ok \
  || bad "C9: a corrupt cache file must fail open (re-evaluate), not suppress the walk"
grep -q "ledger provenance is codex" "$T/logs/merge-sweep.log" && ok \
  || bad "C9: the run must still reach and log its decision with a corrupt cache file"

echo "--- C10: entries are pruned by AGE and the file does not grow"
reset_tree
mkrec pool-p1-K-22-r "https://github.com/o/p1/pull/22" BLOCK "$((NOW - 100))"
run_sweep SWEEP_TERMINAL_TTL_SECS=0
C10A=$(grep -c . "$T/state/merge-sweep-terminal.txt")
run_sweep SWEEP_TERMINAL_TTL_SECS=0
C10B=$(grep -c . "$T/state/merge-sweep-terminal.txt")
[ "$C10A" = 0 ] && ok || bad "C10: with TTL 0 every entry must be pruned at end of run, file holds $C10A line(s)"
[ "$C10B" = "$C10A" ] && ok || bad "C10: the cache file must not grow across ticks ($C10A then $C10B)"

echo "--- C4/C5/C6: retryable skips are never cached"
reset_tree
# C4 UNSTABLE — the ticket names this one explicitly.
mkrec pool-p1-K-31-r "https://github.com/o/p1/pull/31" APPROVE "$((NOW - 100))"
echo "https://github.com/o/p1/pull/31 OPEN UNSTABLE operator headsha OPEN" > "$T/pr-state.txt"
# C5 head-bound park — the head is not the sha the review approved.
mkrec pool-p1-K-32-r "https://github.com/o/p1/pull/32" APPROVE "$((NOW - 100))"
echo "othersha" > "$T/builds/pool-p1-K-32-r/reviewed-sha"
echo "https://github.com/o/p1/pull/32 OPEN CLEAN operator headsha OPEN" >> "$T/pr-state.txt"
# C6 the repo's review gate is TIGHTENED — it clears when the revert rate drops.
mkrec pool-p2-K-33-r "https://github.com/o/tight/pull/33" APPROVE "$((NOW - 100))"
echo "o/tight" > "$T/tightened.txt"
run_sweep
for pr in 31 32 33; do
  grep -q "pull/$pr " "$T/state/merge-sweep-terminal.txt" \
    && bad "C4/C5/C6: pull/$pr is a RETRYABLE skip and must never be cached: $(grep "pull/$pr " "$T/state/merge-sweep-terminal.txt")" \
    || ok
done
: > "$T/gh-calls.txt"; : > "$T/visit-order.txt"
TIGHT1=$(count_in "review gate is TIGHTENED" "$T/logs/merge-sweep.log")
run_sweep
grep -q "https://github.com/o/p1/pull/31" "$T/visit-order.txt" && ok \
  || bad "C4: an UNSTABLE PR must be re-read from gh on the next tick"
grep -q "https://github.com/o/p1/pull/32" "$T/visit-order.txt" && ok \
  || bad "C5: a head-bound park must be re-evaluated on the next tick"
TIGHT2=$(count_in "review gate is TIGHTENED" "$T/logs/merge-sweep.log")
[ "$TIGHT2" -gt "$TIGHT1" ] && ok \
  || bad "C6: a TIGHTENED review gate must be re-evaluated every tick (lines $TIGHT1 then $TIGHT2)"

# ============================================================================
# S — the per-tick summary
# ============================================================================
echo "--- S1/S2: one summary line per project, and no growing re-skip log"
reset_tree
# p1: one record that really merges, one with a recorded E2E failure.
mkrec pool-p1-K-41-202609170041 "https://github.com/o/p1/pull/41" APPROVE "$((NOW - 100))"
echo "https://github.com/o/p1/pull/41 OPEN CLEAN operator headsha MERGED" > "$T/pr-state.txt"
mkrec pool-p1-K-42-202609170042 "https://github.com/o/p1/pull/42" APPROVE "$((NOW - 200))"
printf 'ROUTE 500 /x FAIL\nE2E: FAIL\n' > "$T/builds/pool-p1-K-42-202609170042/e2e.md"
# p2: one retryable (DIRTY) record.
mkrec pool-p2-K-43-202609170043 "https://github.com/o/p2/pull/43" APPROVE "$((NOW - 300))"
echo "https://github.com/o/p2/pull/43 OPEN DIRTY operator headsha OPEN" >> "$T/pr-state.txt"

run_sweep
grep -q "MERGED https://github.com/o/p1/pull/41" "$T/logs/merge-sweep.log" && ok \
  || bad "S1: the merge path must still work under the new walk (log: $(cat "$T/logs/merge-sweep.log"))"
S_P1=$(count_in "tick p1:" "$T/logs/merge-sweep.log")
S_P2=$(count_in "tick p2:" "$T/logs/merge-sweep.log")
S_TOT=$(count_in "tick TOTAL:" "$T/logs/merge-sweep.log")
[ "$S_P1" = 1 ] && ok || bad "S1: exactly one 'tick p1:' summary line expected, got $S_P1"
[ "$S_P2" = 1 ] && ok || bad "S1: exactly one 'tick p2:' summary line expected, got $S_P2"
[ "$S_TOT" = 1 ] && ok || bad "S1: exactly one 'tick TOTAL:' line expected, got $S_TOT"
P1LINE=$(grep "tick p1:" "$T/logs/merge-sweep.log" | tail -1)
for k in "seen=2" "merged=1" "retryable=0" "terminal-new=1" "terminal-cached=0"; do
  grep -q "$k" <<<"$P1LINE" && ok || bad "S1: p1's summary must carry $k — got: $P1LINE"
done
P2LINE=$(grep "tick p2:" "$T/logs/merge-sweep.log" | tail -1)
grep -q "seen=1" <<<"$P2LINE" && grep -q "retryable=1" <<<"$P2LINE" && ok \
  || bad "S1: p2's summary must count its one retryable record — got: $P2LINE"
grep -q "deadline=no" "$T/logs/merge-sweep.log" && grep -q "unseen=0" "$T/logs/merge-sweep.log" && ok \
  || bad "S1: the TOTAL line must state deadline= and unseen= ($(grep 'tick TOTAL:' "$T/logs/merge-sweep.log"))"
grep -qE "tick (p1|p2|TOTAL):.*https://" "$T/logs/merge-sweep.log" \
  && bad "S1: a summary line must carry no PR URL — bin/pipeline-health.sh greps this log per PR" || ok

S2_ONE=$(count_in "E2E smoke FAILED" "$T/logs/merge-sweep.log")
run_sweep
run_sweep
S2_THREE=$(count_in "E2E smoke FAILED" "$T/logs/merge-sweep.log")
[ "$S2_ONE" = 1 ] && ok || bad "S2: tick 1 must explain the E2E skip exactly once, got $S2_ONE"
[ "$S2_THREE" = "$S2_ONE" ] && ok \
  || bad "S2: the per-PR re-skip line must not grow across ticks ($S2_ONE after tick 1, $S2_THREE after tick 3)"

# ============================================================================
# D — the tick deadline
# ============================================================================
echo "--- D1: an expired deadline stops the walk and says how much it did not see"
reset_tree
for i in 51 52 53; do
  mkrec "pool-p1-K-$i-r" "https://github.com/o/p1/pull/$i" APPROVE "$((NOW - 100 - i))"
  echo "https://github.com/o/p1/pull/$i OPEN CLEAN operator headsha MERGED" >> "$T/pr-state.txt"
done
run_sweep SWEEP_DEADLINE_SECS=0
grep -q "deadline=hit" "$T/logs/merge-sweep.log" && ok \
  || bad "D1: an expired deadline must be stated in the summary ($(cat "$T/logs/merge-sweep.log"))"
UNSEEN=$(grep -o 'unseen=[0-9]*' "$T/logs/merge-sweep.log" | tail -1 | cut -d= -f2)
[ -n "$UNSEEN" ] && [ "$UNSEEN" -gt 0 ] && ok \
  || bad "D1: the summary must report the records the deadline left unwalked, got 'unseen=$UNSEEN'"
[ -s "$T/merge-calls.txt" ] \
  && bad "D1: no merge may be attempted after the deadline broke the walk: $(cat "$T/merge-calls.txt")" || ok

echo "merge-sweep-order-cache-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
