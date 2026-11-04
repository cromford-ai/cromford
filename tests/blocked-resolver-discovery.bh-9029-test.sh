#!/bin/bash
# tests/blocked-resolver-discovery.bh-9029-test.sh — BH-9029 fix 1 and fix 4:
# a row the pre-pass retired leaves DISCOVERY on the next tick, a finished
# record costs br_from_rebuilds no fork, a retired build dir carries a marker
# the build source reads, a finished record with no PR url retires by age, and
# the prof: line says how many rows discovery found and how many it skipped.
#
# THE BUG (hub, 2026-11-03). The pre-pass wrote `.retired=true` on 107 to 109
# records every tick, and no discovery source read the flag: each retired row
# was discovered, read, sent to GitHub and dropped again on the next tick.
# Discovery cost 13 minutes per tick.
#
# WHAT IS DRIVEN. Every section runs the real bin/blocked-resolver.sh end to
# end against a scratch $HARNESS. The gh stub records every call, so "no
# GitHub read for a retired row" is a fact about the run. No network: gh, ssh,
# the jobs client and lane-alert are stubs.
#
# Run from anywhere: tests/blocked-resolver-discovery.bh-9029-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
REALJQ=$(command -v jq)

# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)

H="$T/h"
mkdir -p "$H/bin"
# The scripts this suite drives. The copy stays HERE, in the suite's own text,
# so bin/test-impact.sh selects this suite when one of them changes.
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$H/bin/"
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
fx_br_harness "$DIR" "$T" || exit 1
[ -d "$DIR/bin/lib/br" ] || exit 1   # impact: this suite runs when bin/lib/br/ changes
# Every fragment rides with the driver copy, as bin/harness-sync.sh puts them on
# a box, and the profile module that writes the prof: line is installed too.
mkdir -p "$H/bin/blocked-resolver.d" || exit 1
cp "$DIR"/bin/blocked-resolver.d/*.sh "$H/bin/blocked-resolver.d/" || exit 1
scratch_install_closure bin/lib/br/opt/profile.sh "$H" >/dev/null || exit 1
# The fragment under test, named by its rooted path so the orphan check sees it.
[ -f "$DIR/bin/blocked-resolver.d/bh-9029-discovery-index.sh" ] \
  || bad "0: bin/blocked-resolver.d/bh-9029-discovery-index.sh must exist"

# THE gh STUB: the branch, title and head come from the PR NUMBER in the argv,
# so #1001 is TK-1001 and a seeded record can be keyed to one row. A file
# $T/branch-<n> overrides the branch (the "another PR of the same ticket" case).
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "\$*" >> "$T/gh.txt"
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pull|pulls|issues)/([0-9]+).*#\2#p' | head -1)
BR="ticket/ts-\$N"; [ -s "$T/branch-\$N" ] && BR=\$(cat "$T/branch-\$N")
case "\$*" in
  *"-i -X "*)
    GHT="$T"
    printf '%s' "\$BR" > "$T/prbranch"
    printf 'TK-%s: a thing' "\$N" > "$T/prtitle"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$T/prhead"
    . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"issues/"*"/comments"*) echo '[]' ;;
  *"repos/"*"/issues/"*) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  *"pr close"*)   printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"pr comment"*|*"issue comment"*) exit 0 ;;
  *"--json state"*) echo OPEN ;;
  *"/pulls/"*)    echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \$BR" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
touch "$H/flags/fly-pool-tproj"
: > "$T/run.log"

ROWS="$H/state/merge-conductor/pr-state.tsv"
ST="$H/state/blocked-resolver"
LOGF="$H/logs/blocked-resolver.log"
U="https://github.com/o/tproj/pull"
MFT="merge-failed-twice: gh pr merge refused"
ROWADD() { printf '%s\tBLOCKED_HUMAN\t%s\tabc123\tabc123\t-\t%s\t%s\n' "$1" "$NOW" "$2" "$3" >> "$ROWS"; }
REC() { mkdir -p "$ST/tproj"; printf '%s\n' "$2" > "$ST/tproj/$1.json"; }
LASTTICK() { grep 'tick: candidates=' "$LOGF" | tail -1 | sed -E 's/^[0-9-]+ [0-9:]+Z //'; }
LFIELD() { LASTTICK | sed -nE "s/.*(^| )$1=([^ ]*).*/\2/p"; }
LASTPROF() { grep ' prof: ' "$LOGF" | tail -1 | sed -E 's/^[0-9-]+ [0-9:]+Z //'; }
PFIELD() { LASTPROF | sed -nE "s/.*(^| )$1=([^ ]*).*/\2/p"; }
GHNUM() { grep -cE "(pull|pulls|issues)/$1([^0-9]|\$)" "$T/gh.txt" 2>/dev/null; }
STAMPAT() { date -u -d "@$1" '+%Y-%m-%d %H:%M:%SZ'; }
CLEAN() {
  scratch_rm "$ST" 2>/dev/null
  scratch_rm "$H/builds" 2>/dev/null; mkdir -p "$H/builds"
  scratch_rm "$H/state/merge-conductor/handoff" 2>/dev/null
  scratch_rm "$H/state/merge-conductor/handoff-released" 2>/dev/null
  rm -f "$T"/branch-*
  : > "$T/gh.txt"; : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$LOGF"; : > "$ROWS"
  BRENV=(BR_PER_TICK=1)
}

# ============================================================================
# D1. 200 SEEDED CONDUCTOR ROWS: 50 RESOLVED_MERGED with their url, 50 ABANDONED
#     with their url, 50 HELD, 50 with no record. Tick 1 retires the 100
#     finished ones, as the pre-pass did before this change.
# ============================================================================
CLEAN
for N in $(seq 1001 1200); do ROWADD "o/tproj#$N" "$MFT" "$U/$N"; done
for N in $(seq 1001 1050); do REC "tproj-TK-$N" "{\"project\":\"tproj\",\"rkey\":\"tproj-TK-$N\",\"outcome\":\"RESOLVED_MERGED\",\"resolved_url\":\"$U/$N\",\"attempts\":[]}"; done
for N in $(seq 1051 1100); do REC "tproj-TK-$N" "{\"project\":\"tproj\",\"rkey\":\"tproj-TK-$N\",\"outcome\":\"ABANDONED\",\"abandoned_url\":\"$U/$N\",\"attempts\":[]}"; done
for N in $(seq 1101 1150); do REC "tproj-TK-$N" "{\"project\":\"tproj\",\"rkey\":\"tproj-TK-$N\",\"outcome\":\"HELD\",\"attempts\":[]}"; done
RUN
[ "$(LFIELD candidates)" = 200 ] && ok || bad "D1: tick 1 must discover all 200 rows (tick: $(LASTTICK))"
[ "$(LFIELD retired)" = 100 ] && ok || bad "D1: tick 1 must retire the 100 finished rows (tick: $(LASTTICK))"
[ "$(jq -r '.retired // false' "$ST/tproj/tproj-TK-1001.json")" = true ] && ok \
  || bad "D1: the retired flag must be written on the record"

# ============================================================================
# D3. TICK 2 DISCOVERS ONLY THE OPEN ROWS. The 100 retired rows are skipped in
#     the source, before any GitHub read: candidates=100, retired=0, and the gh
#     log of tick 2 names none of their PR numbers.
# ============================================================================
: > "$T/gh.txt"
RUN
[ "$(LFIELD candidates)" = 100 ] && ok || bad "D3: THE BUG: tick 2 must discover only the 100 open rows (tick: $(LASTTICK))"
[ "$(LFIELD retired)" = 0 ] && ok || bad "D3: tick 2 retires nothing — the retired rows never reach the pre-pass (tick: $(LASTTICK))"
[ "$(PFIELD retired_skipped)" = 100 ] && ok || bad "D3: prof must say retired_skipped=100 (prof: $(LASTPROF))"
hits=0
for N in $(seq 1001 1100); do [ "$(GHNUM "$N")" = 0 ] || hits=$((hits+1)); done
[ "$hits" = 0 ] && ok || bad "D3: tick 2 must make no GitHub call for a retired row ($hits of 100 were read)"
[ "$(GHNUM 1151)" -gt 0 ] && ok || bad "D3: an open row is still read (gh log has no call for #1151)"

# ============================================================================
# D7. THE prof: LINE. discovery_rows equals the tick line's candidates, and the
#     per-source seconds are named in the order br_candidates runs them.
#     `top=[...]` stays the last field (BH-5946's pin).
# ============================================================================
if LASTPROF | grep -qE ' discovery_rows=100 retired_skipped=100 discovery_src=rebuilds:[0-9]+,conductor:[0-9]+,queue:[0-9]+,builds:[0-9]+,reviews:[0-9]+,external:[0-9]+ project='; then ok
else bad "D7: the prof line must carry discovery_rows, retired_skipped and discovery_src before project= (prof: $(LASTPROF))"; fi
LASTPROF | grep -qE ' top=\[[^]]*\]$' && ok || bad "D7: top=[...] must stay last (prof: $(LASTPROF))"
[ "$(PFIELD discovery_rows)" = "$(LFIELD candidates)" ] && ok || bad "D7: discovery_rows must equal candidates"

# ============================================================================
# D2. THE URL DECISION TABLE. Records already retired by an earlier tick; one
#     tick; a skipped row makes no gh call and counts once in retired_skipped.
#       skip:    (1) retired RESOLVED_MERGED, resolved_url = row url
#                (2) retired ABANDONED, abandoned_url = row url
#                (3) retired RESOLVED_MERGED, url only in the legacy attempt
#       no skip: (4) another PR of the retired ticket
#                (5) RESOLVED_MERGED url match, never retired
#                (6) retired, outcome reset to '' (bpr_scope)
#                (7) retired, outcome url not a pull url
#                (9) row url = outcome url + /files
#     (8), an index that did not load, is D8.
# ============================================================================
CLEAN
REC tproj-TK-2001 "{\"outcome\":\"RESOLVED_MERGED\",\"resolved_url\":\"$U/2001\",\"retired\":true,\"attempts\":[]}"
REC tproj-TK-2002 "{\"outcome\":\"ABANDONED\",\"abandoned_url\":\"$U/2002\",\"retired\":true,\"attempts\":[]}"
REC tproj-TK-2003 "{\"outcome\":\"RESOLVED_MERGED\",\"retired\":true,\"attempts\":[{\"action\":\"resolved-merged\",\"detail\":\"$U/2003 is already MERGED — stale park, no rebuild\"}]}"
REC tproj-TK-2004 "{\"outcome\":\"RESOLVED_MERGED\",\"resolved_url\":\"$U/2014\",\"retired\":true,\"attempts\":[]}"
printf 'ticket/TK-2004' > "$T/branch-2004"   # #2004 is ANOTHER PR of TK-2004
REC tproj-TK-2005 "{\"outcome\":\"RESOLVED_MERGED\",\"resolved_url\":\"$U/2005\",\"attempts\":[]}"
REC tproj-TK-2006 "{\"outcome\":\"\",\"resolved_url\":\"$U/2006\",\"retired\":true,\"attempts\":[]}"
REC tproj-TK-2007 "{\"outcome\":\"RESOLVED_MERGED\",\"resolved_url\":\"-\",\"retired\":true,\"attempts\":[]}"
REC tproj-TK-2009 "{\"outcome\":\"RESOLVED_MERGED\",\"resolved_url\":\"$U/2009\",\"retired\":true,\"attempts\":[]}"
for N in 2001 2002 2003 2004 2005 2006 2007; do ROWADD "o/tproj#$N" "$MFT" "$U/$N"; done
ROWADD "o/tproj#2009" "$MFT" "$U/2009/files"
RUN
for N in 2001 2002 2003; do
  [ "$(GHNUM "$N")" = 0 ] && ok || bad "D2: case ${N#200}: a retired row must be skipped before any gh call ($(GHNUM "$N") calls)"
done
for N in 2004 2005 2006 2007; do
  [ "$(GHNUM "$N")" -gt 0 ] && ok || bad "D2: case ${N#200}: this row must NOT be skipped (no gh call for #$N)"
done
# Case 9's url is not a PR url, so discovery makes no gh read for it either way:
# the candidate count below is what shows it was not skipped.
[ "$(PFIELD retired_skipped)" = 3 ] && ok || bad "D2: exactly the 3 skip cases are counted (prof: $(LASTPROF))"
[ "$(LFIELD candidates)" = 5 ] && ok || bad "D2: the 5 no-skip rows are discovered (tick: $(LASTTICK))"

# ============================================================================
# D8. THE INDEX DID NOT LOAD. Every skip answers "no" and the tick runs as it
#     did before this change, with one line that says so. The failure is forced
#     with a jq that refuses the index's own filter; every other jq call runs.
# ============================================================================
CLEAN
REC tproj-TK-2001 "{\"outcome\":\"RESOLVED_MERGED\",\"resolved_url\":\"$U/2001\",\"retired\":true,\"attempts\":[]}"
ROWADD "o/tproj#2001" "$MFT" "$U/2001"
ROWADD "o/tproj#2002" "$MFT" "$U/2002"
cat > "$T/fakebin/jq" <<EOF
#!/bin/bash
for a in "\$@"; do case "\$a" in *'bdi-index'*) exit 5 ;; esac; done
exec "$REALJQ" "\$@"
EOF
chmod +x "$T/fakebin/jq"
RUN
rm -f "$T/fakebin/jq"
[ "$(grep -c 'discovery index did not load' "$LOGF")" = 1 ] && ok \
  || bad "D8: a failed index must say so in ONE line (log: $(grep -i 'index' "$LOGF" | tail -3))"
[ "$(GHNUM 2001)" -gt 0 ] && ok || bad "D8: with no index the retired row is discovered as before"
[ "$(LFIELD candidates)" = 2 ] && [ "$(LFIELD retired)" = 1 ] && ok \
  || bad "D8: the tick is today's: candidates=2 retired=1 (tick: $(LASTTICK))"
[ "$(PFIELD retired_skipped)" = 0 ] && ok || bad "D8: nothing is counted as skipped (prof: $(LASTPROF))"
# ...and the same tree with the fragment switched off gives the same tick line.
T8=$(LASTTICK | sed -E 's/ secs=[0-9]+//; s/ oldest_untouched=[^ ]*//')
CLEAN
REC tproj-TK-2001 "{\"outcome\":\"RESOLVED_MERGED\",\"resolved_url\":\"$U/2001\",\"retired\":true,\"attempts\":[]}"
ROWADD "o/tproj#2001" "$MFT" "$U/2001"
ROWADD "o/tproj#2002" "$MFT" "$U/2002"
BRENV=(BR_PER_TICK=1 BR_OPT_OFF=bh-9029-discovery-index)
RUN
[ "$(LASTTICK | sed -E 's/ secs=[0-9]+//; s/ oldest_untouched=[^ ]*//')" = "$T8" ] && ok \
  || bad "D8: a failed index must give the tick line the fragment-off run gives (failed: '$T8'; off: '$(LASTTICK)')"

# ============================================================================
# D4. br_from_rebuilds FORKS NOTHING FOR A FINISHED RECORD. 150 finished
#     records (RESOLVED_MERGED, ABANDONED, ESCALATED, STALLED) and 50 open ones
#     with no rebuild in flight: no candidate at all, so every `.outcome` read
#     below is the rebuilds source's. Before: one per record (200). After: one
#     per open record (50).
# ============================================================================
CLEAN
for N in $(seq 3001 3200); do
  case $(( (N - 3001) / 50 )) in
    0) oc=RESOLVED_MERGED ;; 1) oc=ABANDONED ;; 2) oc=ESCALATED ;; *) oc="" ;;
  esac
  [ "$N" -gt 3140 ] && [ "$N" -le 3150 ] && oc=STALLED
  REC "tproj-TK-$N" "{\"project\":\"tproj\",\"rkey\":\"tproj-TK-$N\",\"outcome\":\"$oc\",\"attempts\":[{\"action\":\"fix-round\",\"at\":\"2026-11-01 00:00:00Z\"}]}"
done
cat > "$T/fakebin/jq" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/jq.txt"
exec "$REALJQ" "\$@"
EOF
chmod +x "$T/fakebin/jq"; : > "$T/jq.txt"
RUN
rm -f "$T/fakebin/jq"
NOC=$(grep -cxF -- '-r .outcome // ""' "$T/jq.txt")
[ "$NOC" -le 50 ] && ok || bad "D4: THE BUG: the rebuilds source must not fork jq for a finished record ($NOC .outcome reads over 150 finished + 50 open records; want <= 50)"
[ "$NOC" -ge 50 ] && ok || bad "D4: each open record is still read ($NOC .outcome reads; want 50)"
# D4b. A record with no outcome whose enqueue did not land is still offered.
CLEAN
REC tproj-TK-3301 '{"project":"tproj","rkey":"tproj-TK-3301","outcome":"","attempts":[{"action":"rebuild-fresh-failed","at":"2026-11-01 00:00:00Z"}]}'
REC tproj-TK-3302 '{"project":"tproj","rkey":"tproj-TK-3302","outcome":"ABANDONED","attempts":[{"action":"rebuild-fresh-failed","at":"2026-11-01 00:00:00Z"}]}'
RUN
[ "$(LFIELD candidates)" = 1 ] && ok || bad "D4b: the open rebuild-fresh-failed record is still a candidate, the ABANDONED one is not (tick: $(LASTTICK))"
grep -q 'rebuild-enqueue-failed' "$LOGF" && ok || bad "D4b: it is offered as rebuild-enqueue-failed (log: $(tail -3 "$LOGF"))"

# ============================================================================
# D5. A RETIRED BUILD DIR. Build rows carry no PR url, so the pre-pass writes
#     .blocked-resolver-retired in the dir and br_from_builds skips it. A dir of
#     another ticket with no marker is still read, and a RESULT with no
#     trailing newline still classifies.
# ============================================================================
CLEAN
mkdir -p "$H/builds/tproj-TK-501-202611010000" "$H/builds/tproj-TK-502-202611010000"
printf 'REVIEW_BLOCKED gate refused\n' > "$H/builds/tproj-TK-501-202611010000/RESULT"
printf 'BUILD_DEAD no heartbeat' > "$H/builds/tproj-TK-502-202611010000/RESULT"   # no trailing newline
touch -d "@$((NOW - 25200))" "$H/builds/tproj-TK-501-202611010000/RESULT" "$H/builds/tproj-TK-502-202611010000/RESULT"
REC tproj-TK-501 '{"project":"tproj","rkey":"tproj-TK-501","outcome":"ABANDONED","attempts":[]}'
REC tproj-TK-502 '{"project":"tproj","rkey":"tproj-TK-502","outcome":"HELD","attempts":[]}'
RUN
[ "$(LFIELD candidates)" = 2 ] && [ "$(LFIELD retired)" = 1 ] && ok \
  || bad "D5: tick 1 discovers both dirs and retires the ABANDONED one (tick: $(LASTTICK))"
[ -f "$H/builds/tproj-TK-501-202611010000/.blocked-resolver-retired" ] && ok \
  || bad "D5: the retired build dir must carry .blocked-resolver-retired"
grep -q '^ABANDONED	' "$H/builds/tproj-TK-501-202611010000/.blocked-resolver-retired" 2>/dev/null && ok \
  || bad "D5: the marker names the outcome (got: $(cat "$H/builds/tproj-TK-501-202611010000/.blocked-resolver-retired" 2>/dev/null))"
[ ! -e "$H/builds/tproj-TK-502-202611010000/.blocked-resolver-retired" ] && ok \
  || bad "D5: a dir that was not retired gets no marker"
grep -q 'tproj/tproj-TK-502 \[build-dead\]\|tproj-TK-502.*build-dead' "$LOGF" && ok \
  || bad "D5: a RESULT with no trailing newline still classifies as build-dead (log: $(grep 'TK-502' "$LOGF" | tail -2))"
# Tick 1 rebuilt TK-502 (its dir is now superseded), so tick 2 gets a third
# dir with no marker: it is read while the marked one is skipped.
mkdir -p "$H/builds/tproj-TK-503-202611010000"
printf 'BUILD_DEAD no heartbeat\n' > "$H/builds/tproj-TK-503-202611010000/RESULT"
touch -d "@$((NOW - 7200))" "$H/builds/tproj-TK-503-202611010000/RESULT"
: > "$LOGF"
RUN
[ "$(LFIELD candidates)" = 1 ] && [ "$(LFIELD retired)" = 0 ] && ok \
  || bad "D5: THE BUG: tick 2 must not discover the retired dir (tick: $(LASTTICK))"
[ "$(PFIELD retired_skipped)" = 1 ] && ok || bad "D5: the marker skip counts in retired_skipped (prof: $(LASTPROF))"
grep -q 'tproj-TK-503' "$LOGF" && ok || bad "D5: a dir with no marker is still read on tick 2 (log: $(tail -3 "$LOGF"))"

# ============================================================================
# D6. A FINISHED RECORD WITH NO PR URL RETIRES BY AGE (the D11 case). A build
#     row has url `-`; br_finished never retires RESOLVED_MERGED on it. After
#     BR_FINISHED_RECORD_RETIRE_DAYS (default 14) it does, with one audit line.
# ============================================================================
D6SEED() {
  CLEAN
  mkdir -p "$H/builds/tproj-TK-601-202611010000" "$H/builds/tproj-TK-602-202611010000"
  printf 'BUILD_DEAD no heartbeat\n' > "$H/builds/tproj-TK-601-202611010000/RESULT"
  printf 'BUILD_DEAD no heartbeat\n' > "$H/builds/tproj-TK-602-202611010000/RESULT"
  touch -d "@$((NOW - 7200))" "$H/builds/tproj-TK-601-202611010000/RESULT" "$H/builds/tproj-TK-602-202611010000/RESULT"
  REC tproj-TK-601 "{\"project\":\"tproj\",\"rkey\":\"tproj-TK-601\",\"outcome\":\"RESOLVED_MERGED\",\"updated\":\"$(STAMPAT $((NOW - 20*86400)))\",\"attempts\":[]}"
  REC tproj-TK-602 "{\"project\":\"tproj\",\"rkey\":\"tproj-TK-602\",\"outcome\":\"RESOLVED_MERGED\",\"updated\":\"$(STAMPAT $((NOW - 3*86400)))\",\"attempts\":[]}"
}
D6SEED
RUN
[ "$(LFIELD retired)" = 1 ] && ok || bad "D6: THE BUG: the 20-day record with no url must retire at the default 14 days (tick: $(LASTTICK))"
[ "$(grep -c 'EVENT resolver_retired tproj/tproj-TK-601 .*finished with no PR url, untouched for 20 days (BR_FINISHED_RECORD_RETIRE_DAYS=14)' "$LOGF")" = 1 ] && ok \
  || bad "D6: one audit line names the age and the knob (log: $(grep 'resolver_retired' "$LOGF"))"
grep -q 'EVENT resolver_retired tproj/tproj-TK-602' "$LOGF" && bad "D6: the 3-day record must not retire" || ok
[ "$(jq -r '.retired_aged // false' "$ST/tproj/tproj-TK-601.json")" = true ] && ok \
  || bad "D6: the aged retire is remembered on the record"
# Tick 2: the flag write made .updated 0 days old, and the row still stays retired.
: > "$LOGF"
rm -f "$H/builds/tproj-TK-601-202611010000/.blocked-resolver-retired"   # the url-less row comes back to the pre-pass
RUN
[ "$(LFIELD retired)" = 1 ] && ok || bad "D6: the aged row stays retired after the flag write (tick: $(LASTTICK))"
[ "$(grep -c 'EVENT resolver_retired' "$LOGF")" = 0 ] && ok || bad "D6: tick 2 writes no second audit line"
# Knob 0 is off.
D6SEED
BRENV=(BR_PER_TICK=1 BR_FINISHED_RECORD_RETIRE_DAYS=0)
RUN
[ "$(LFIELD retired)" = 0 ] && ok || bad "D6: BR_FINISHED_RECORD_RETIRE_DAYS=0 retires nothing (tick: $(LASTTICK))"
# A knob that is not a number falls back to 14, with one line.
D6SEED
BRENV=(BR_PER_TICK=1 BR_FINISHED_RECORD_RETIRE_DAYS=abc)
RUN
[ "$(LFIELD retired)" = 1 ] && ok || bad "D6: a non-number knob falls back to 14 (tick: $(LASTTICK))"
[ "$(grep -c "BR_FINISHED_RECORD_RETIRE_DAYS is 'abc'" "$LOGF")" = 1 ] && ok \
  || bad "D6: the bad knob is named in ONE line (log: $(grep -c 'BR_FINISHED_RECORD_RETIRE_DAYS' "$LOGF"))"

# D6b. The decision table, on the fragment's own function (pure, no fork).
(
  say() { printf '%s\n' "$*" >> "$T/d6-say.txt"; }
  # shellcheck source=bin/blocked-resolver.d/bh-9029-discovery-index.sh
  . "$DIR/bin/blocked-resolver.d/bh-9029-discovery-index.sh" || exit 9
  r=""
  for c in "RESOLVED_MERGED|-|build-dead|20|0" "RESOLVED_MERGED||build-dead|14|0" \
           "RESOLVED_MERGED|-|build-dead|13|1" "ABANDONED|-|build-dead|30|1" \
           "RESOLVED_MERGED|-|rebuild-landed|20|1" "HELD|-|build-dead|30|1" \
           "RESOLVED_MERGED|-|build-dead|-|1" "RESOLVED_MERGED|$U/1|build-dead|30|1"; do
    IFS='|' read -r o u w a want <<<"$c"
    got=0; bdi_aged_finished "$o" "$u" "$w" "$a" 0 || got=1
    [ "$got" = "$want" ] || r="$r [$c -> $got]"
  done
  got=0; BR_FINISHED_RECORD_RETIRE_DAYS=0 bdi_aged_finished RESOLVED_MERGED - build-dead 400 0 || got=1
  [ "$got" = 1 ] || r="$r [knob 0 -> $got]"
  got=0; bdi_aged_finished RESOLVED_MERGED - build-dead 0 1 || got=1
  [ "$got" = 0 ] || r="$r [aged flag -> $got]"
  [ -z "$r" ] || { echo "$r"; exit 1; }
) && ok || bad "D6b: the aged-retire table: $(cat "$T/d6-say.txt" 2>/dev/null)"

echo "blocked-resolver-discovery.bh-9029: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
