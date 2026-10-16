#!/bin/bash
# tests/dora-conflicts-block.bh-6965-test.sh — the `conflicts` block of the
# daily DORA digest and its one alert (BH-6965), driven through the real
# entry point bin/dora-digest.sh on fixture slices of the four sources it reads:
#   logs/merge-conductor.log        DIRTY events, merges, DIRTY-to-clean rows
#   logs/blocked-resolver.log       REBUILD FRESH events
#   state/blocked-resolver/<p>/*.json  fix-round-conflict ok|failed attempts
#   logs/repair-on-push.log         REPAIR / range= / left-for-next-tick lines
# Every expected number below is counted by hand off the fixture lines.
#
# Cases: C1 numbers, C2 no merges -> n/a, C3 episodes from conductor rows,
# C4 episodes from REPAIR rows, C5 record attempts, C6 repair wakes, C7 every
# source absent; A1 alert at 41/100, A2 default threshold, A3 no alert at 39,
# A4 env and settings row, A5 once per day and the trailing 24 h.
# Run from anywhere: tests/dora-conflicts-block.bh-6965-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day flag and the json name are read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 60 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
neq() { if awk -v a="$2" -v b="$3" 'BEGIN{exit !(a != "" && a != "null" && a+0 == b+0)}'; then ok
        else bad "$1: expected $3, got '$2'"; fi; }
# The conflicts alert lines in one ALERTS.log; an absent file is zero lines.
calerts() { if [ -f "$1/logs/ALERTS.log" ]; then grep -c '\[dora-conflicts\]' "$1/logs/ALERTS.log"; else echo 0; fi; }

command -v jq >/dev/null 2>&1 || { echo "dora-conflicts-block: jq required, skipping"; exit 0; }
# The parser the digest imports; a digest without it crashes rather than reports.
[ -r "$DIR/bin/dora_conflicts.py" ] || { echo "FAIL: $DIR/bin/dora_conflicts.py is missing"; exit 1; }

# Stamps relative to now. ago <minutes> prints the conductor/resolver stamp.
ago()   { date -u -d "$1 minutes ago" '+%Y-%m-%d %H:%M:%SZ'; }
IN=$(ago 120)
OLD5=$(date -u -d '5 days ago' '+%Y-%m-%d %H:%M:%SZ')
OLD10=$(date -u -d '10 days ago' '+%Y-%m-%d %H:%M:%SZ')
TODAY=$(date -u +%F)
DAYTAG=$(date -u +%Y%m%d)

cat > "$T/fleet.conf" <<'CONF'
alpha  Org/alpha  https://alpha.test  /api/board  1 box-a 192.0.2.1
beta   Org/beta   https://beta.test   -           2 box-b 192.0.2.2
gamma  Org/gamma  https://gamma.test  -           3 box-c 192.0.2.3
CONF
export FLEET_CONF="$T/fleet.conf"
unset DORA_CONFLICTS_REBUILD_ALERT_PER_100

# tree <name> — a fresh harness root with logs/ only.
tree() { mkdir -p "$T/$1/logs"; printf '%s' "$T/$1"; }
# digest <root> [args] — the production entry point, ledger and gh budget off.
digest() {
  local h="$1"; shift
  HARNESS="$h" DORA_LEDGER="${LEDGER:-0}" DORA_GH_BUDGET=0 \
    "$DIR/bin/dora-digest.sh" --no-send "$@" > "$h/stdout" 2> "$h/stderr"
}
J() { printf '%s' "$1/state/dora/$TODAY.json"; }
cj() { jq -r "$2" "$(J "$1")"; }
row() { jq -r ".repos[] | select(.project==\"$2\") | .conflicts | $3" "$(J "$1")"; }
# merges <root> <slug> <n> — n distinct in-window MERGED lines.
merges() {
  local i; for i in $(seq 1 "$3"); do
    echo "$IN MERGED $2#$((1000+i)) by conductor (record /x/builds/pool-x-$i)"
  done >> "$1/logs/merge-conductor.log"
}
# rebuilds <root> <project> <n> [stamp] — n REBUILD FRESH lines.
rebuilds() {
  local i s="${4:-$IN}"; for i in $(seq 1 "$3"); do
    echo "$s $2/$2-K-$i [red-twice]: REBUILD FRESH 1 of 3"
  done >> "$1/logs/blocked-resolver.log"
}

# ── C1 + A1 + A2: hand-counted numbers, and the alert at 41/100 ─────────────
C1=$(tree c1)
merges "$C1" Org/alpha 100
merges "$C1" Org/beta 2
{
  echo "$IN Org/alpha#201 WAIT_CI -> NEEDS_REBASE head=aaaaaaa1 reviewed=aaaaaaa1 merge=DIRTY reason=mergeState DIRTY"
  echo "$IN Org/alpha#201 BLOCKED_HUMAN -> NEEDS_REBASE head=aaaaaaa1 reviewed=aaaaaaa1 merge=DIRTY reason=mergeState DIRTY"
  echo "$IN Org/alpha#202 - -> NEEDS_REBASE head=aaaaaaa2 reviewed=aaaaaaa2 merge=DIRTY reason=mergeState DIRTY"
  echo "$OLD10 Org/alpha#203 WAIT_CI -> NEEDS_REBASE head=aaaaaaa3 reviewed=aaaaaaa3 merge=DIRTY reason=mergeState DIRTY"
} >> "$C1/logs/merge-conductor.log"
rebuilds "$C1" alpha 41
rebuilds "$C1" alpha 1 "$OLD10"
# The beat bin/alert-line.sh sends for the alert, recorded (a --no-send run
# still raises the alert: --no-send is about the digest's own beat).
mkdir -p "$C1/bin"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/beats"\n' "$C1" > "$C1/bin/beat.sh"
chmod +x "$C1/bin/beat.sh"
# A resolver line that is not a park line and a lowercase rung line: not rebuilds.
echo "$IN alpha/alpha-K-1 [conductor/red-twice] -> rebuild-fresh (rebuilds=0 fix=0 adj=0 rereview=0)" >> "$C1/logs/blocked-resolver.log"
digest "$C1" --window 24h
eq "C1 run exits 0" "$?" "0"
eq "C1 alpha dirty events (3 transitions over 2 PRs)" "$(row "$C1" alpha .dirty_events)" "3"
eq "C1 alpha merges (the conductor-log denominator)" "$(row "$C1" alpha .merges)" "100"
eq "C1 alpha rebuilds (the 10-day-old line is out)" "$(row "$C1" alpha .rebuilds)" "41"
neq "C1 alpha rebuilds per 100 merges" "$(row "$C1" alpha .rebuilds_per_100)" "41"
neq "C1 beta rebuilds per 100 (2 merges, 0 rebuilds)" "$(row "$C1" beta .rebuilds_per_100)" "0"
eq "C1 beta dirty events" "$(row "$C1" beta .dirty_events)" "0"
eq "C1 fleet dirty events" "$(cj "$C1" .fleet.conflicts.dirty_events)" "3"
eq "C1 fleet rebuilds" "$(cj "$C1" .fleet.conflicts.rebuilds)" "41"
eq "C1 fleet merges" "$(cj "$C1" .fleet.conflicts.merges)" "102"
neq "C1 fleet rebuilds per 100 (4100/102)" "$(cj "$C1" .fleet.conflicts.rebuilds_per_100)" "40.2"
eq "C1 the existing distinct-PR conflict count is unchanged" "$(cj "$C1" '.repos[] | select(.project=="alpha") | .conflict.dirty_prs')" "2"
grep -q '^conflicts (fleet): dirty 3, rebuilds 40.2/100 merges (41 of 102)' "$C1/state/dora/latest.txt" 2>/dev/null \
  && ok || bad "C1 fleet text line: $(grep '^conflicts' "$C1/state/dora/latest.txt" 2>/dev/null)"
grep -q '^conflicts alpha: dirty 3, rebuilds 41.0/100 merges (41 of 100)' "$C1/state/dora/latest.txt" 2>/dev/null \
  && ok || bad "C1 alpha text line: $(grep '^conflicts alpha' "$C1/state/dora/latest.txt" 2>/dev/null)"
eq "C1 no line starts with alpha: twice (the row count is unchanged)" "$(grep -c '^alpha:' "$C1/state/dora/latest.txt" 2>/dev/null)" "1"
eq "A1 one ALERTS line at 41/100 over default 40" "$(calerts "$C1")" "1"
grep '\[dora-conflicts\]' "$C1/logs/ALERTS.log" 2>/dev/null | grep -q 'alpha 41 rebuilds / 100 merges' \
  && ok || bad "A1 the line names alpha 41: $(cat "$C1/logs/ALERTS.log" 2>/dev/null)"
grep -q 'beta' <<<"$(grep '\[dora-conflicts\]' "$C1/logs/ALERTS.log" 2>/dev/null)" \
  && bad "A1 beta (0 rebuilds) must not be named" || ok
eq "A1 no ALERTS line contains dora-digest" "$(grep -c 'dora-digest' "$C1/logs/ALERTS.log" 2>/dev/null)" "0"
LINE=$(grep '\[dora-conflicts\]' "$C1/logs/ALERTS.log" 2>/dev/null | head -1)
eq "A1 the ALERTS line is the stamp + the json's alert line" "${LINE#* * }" "$(cj "$C1" .fleet.conflicts.alert.line)"
[ -f "$C1/flags/alerted-dora-conflicts-$DAYTAG" ] && ok || bad "A1 the day flag must be written"
eq "A1 one alert beat, on the dora-conflicts row" "$(grep -c '"akey":"alert:dora-conflicts"' "$C1/beats" 2>/dev/null)" "1"
eq "A1 the beat carries the ALERTS line" "$(jq -r 'select(.kind=="alert") | .line' "$C1/beats" 2>/dev/null)" "$LINE"
eq "A2 default threshold" "$(cj "$C1" .fleet.conflicts.alert_threshold)" "40"
eq "A2 threshold source" "$(cj "$C1" .fleet.conflicts.alert_threshold_source)" "default"
eq "A2 the alert names the projects over" "$(cj "$C1" '.fleet.conflicts.alert.over | map(.project) | join(",")')" "alpha"
# A5 (first half): the same day, a second run, still one line.
digest "$C1" --window 24h
eq "A5 second run exits 0" "$?" "0"
eq "A5 a second run on the same day writes no second line" "$(calerts "$C1")" "1"
eq "A5 and sends no second beat" "$(grep -c '"kind":"alert"' "$C1/beats" 2>/dev/null)" "1"

# ── C2 + A3: no merges -> n/a; 39/100 and 3/0 do not fire; equal is not over
C2=$(tree c2)
merges "$C2" Org/alpha 100
rebuilds "$C2" alpha 39
rebuilds "$C2" gamma 3
digest "$C2" --window 24h
eq "C2 run exits 0" "$?" "0"
eq "C2 gamma has rebuilds" "$(row "$C2" gamma .rebuilds)" "3"
eq "C2 gamma rebuilds per 100 is null with no merges" "$(row "$C2" gamma .rebuilds_per_100)" "null"
row "$C2" gamma '.unavailable.rebuilds_per_100' | grep -q 'no merges' && ok \
  || bad "C2 gamma says why: $(row "$C2" gamma '.unavailable')"
grep -q '^conflicts gamma: .*rebuilds n/a' "$C2/state/dora/latest.txt" 2>/dev/null && ok \
  || bad "C2 gamma text line says n/a: $(grep '^conflicts gamma' "$C2/state/dora/latest.txt" 2>/dev/null)"
neq "C2 alpha 39 per 100" "$(row "$C2" alpha .rebuilds_per_100)" "39"
eq "A3 no line at 39/100 (and none for 3 rebuilds / 0 merges)" "$(calerts "$C2")" "0"
DORA_CONFLICTS_REBUILD_ALERT_PER_100=39 digest "$C2" --window 24h
eq "A3 39/100 at threshold 39: equal is not over" "$(calerts "$C2")" "0"
DORA_CONFLICTS_REBUILD_ALERT_PER_100=38 digest "$C2" --window 24h
eq "A3 39/100 at threshold 38 fires" "$(calerts "$C2")" "1"

# ── C3 + C4: DIRTY-to-clean episodes, conductor rows and REPAIR rows ────────
C3=$(tree c3)
{
  echo "$(ago 1800) Org/alpha#305 WAIT_CI -> NEEDS_REBASE head=a reviewed=a merge=DIRTY reason=mergeState DIRTY"
  echo "$(ago 120) Org/alpha#301 WAIT_CI -> NEEDS_REBASE head=a reviewed=a merge=DIRTY reason=mergeState DIRTY"
  echo "$(ago 120) Org/alpha#302 WAIT_REVIEW -> NEEDS_REBASE head=a reviewed=a merge=DIRTY reason=mergeState DIRTY"
  echo "$(ago 119) Org/alpha#305 NEEDS_REBASE -> WAIT_CI head=a reviewed=a merge=CLEAN reason=rebased"
  echo "$(ago 117) MERGED Org/alpha#303 by conductor (record /x/builds/pool-alpha-3)"
  echo "$(ago 115) Org/alpha#301 NEEDS_REBASE -> REBASING head=a reviewed=a merge=DIRTY reason=merging origin/main"
  echo "$(ago 110) Org/alpha#302 NEEDS_REBASE -> REBASING head=a reviewed=a merge=- reason=merging origin/main"
  echo "$(ago 108) Org/alpha#301 REBASING -> WAIT_CI head=b reviewed=a merge=CLEAN reason=rebased onto main"
  echo "$(ago 90) MERGED Org/alpha#302 by conductor (record /x/builds/pool-alpha-2)"
  echo "$(ago 80) Org/alpha#304 WAIT_CI -> NEEDS_REBASE head=a reviewed=a merge=DIRTY reason=mergeState DIRTY"
  echo "$(ago 75) Org/alpha#304 NEEDS_REBASE -> REBASING head=a reviewed=a merge=DIRTY reason=merging origin/main"
  echo "$(ago 70) MERGED Org/beta#9 by conductor (record /x/builds/pool-beta-9)"
} > "$C3/logs/merge-conductor.log"
{
  echo "$(ago 60) [repair-on-push] REPAIR pr=7 files=2 action=rebase reason=conflict repo=Org/beta wake=21 rc=1"
  echo "$(ago 59) [repair-on-push] REPAIR pr=7 files=2 action=rebase reason=conflict repo=org/beta wake=22 rc=1"
  echo "$(ago 58) [repair-on-push] REPAIR pr=7 files=2 action=rebase reason=pushed repo=Org/beta wake=23 rc=0"
  echo "$(ago 57) [repair-on-push] REPAIR pr=8 files=1 action=rebase reason=conflict repo=Org/beta wake=23 rc=1"
} > "$C3/logs/repair-on-push.log"
digest "$C3" --window 24h
eq "C3 run exits 0" "$?" "0"
eq "C3 alpha episodes closed in the window (#301 12m, #302 30m)" "$(row "$C3" alpha .dirty_to_clean_min.n)" "2"
neq "C3 alpha p50 (nearest rank)" "$(row "$C3" alpha .dirty_to_clean_min.p50)" "12"
neq "C3 alpha p90 (nearest rank)" "$(row "$C3" alpha .dirty_to_clean_min.p90)" "30"
eq "C3 alpha open episodes (#304; #305 opened before the window)" "$(row "$C3" alpha .dirty_to_clean_min.open)" "1"
eq "C4 beta episodes from REPAIR rows" "$(row "$C3" beta .dirty_to_clean_min.n)" "1"
neq "C4 beta p50 (conflict at -60m, pushed at -58m)" "$(row "$C3" beta .dirty_to_clean_min.p50)" "2"
eq "C4 a lone reason=conflict line stays open" "$(row "$C3" beta .dirty_to_clean_min.open)" "1"
eq "C3 fleet episodes" "$(cj "$C3" .fleet.conflicts.dirty_to_clean_min.n)" "3"
neq "C3 fleet p50 of [2,12,30]" "$(cj "$C3" .fleet.conflicts.dirty_to_clean_min.p50)" "12"
neq "C3 fleet p90 of [2,12,30]" "$(cj "$C3" .fleet.conflicts.dirty_to_clean_min.p90)" "30"
eq "C3 fleet open" "$(cj "$C3" .fleet.conflicts.dirty_to_clean_min.open)" "2"
grep -q '^conflicts alpha: .*dirty->clean p50 12.0m p90 30.0m (n=2, 1 open)' "$C3/state/dora/latest.txt" 2>/dev/null && ok \
  || bad "C3 alpha text line: $(grep '^conflicts alpha' "$C3/state/dora/latest.txt" 2>/dev/null)"

# ── C5: fix-round-conflict attempts from the resolver records ──────────────
C5=$(tree c5)
merges "$C5" Org/alpha 3
mkdir -p "$C5/state/blocked-resolver/alpha"
S1=$(ago 300); S2=$(ago 200); S3=$(ago 100)
jq -nc --arg a "$S1" --arg b "$S2" --arg c "$S3" --arg o "$OLD10" '{attempts:[
  {at:$o, action:"fix-round", reason:"conflict", detail:"push rejected under the lease · fix-round-conflict failed lines=4"},
  {at:$a, action:"fix-round", reason:"conflict", detail:"pushed abc1234 to ticket/a-1, typecheck+unit green · fix-round-conflict ok lines=12"},
  {at:$b, action:"fix-round", reason:"conflict", detail:"agent rc=1, verify rc=1 — no verified commit · fix-round-conflict failed lines=unknown"},
  {at:$c, action:"fix-round", reason:"conflict", detail:"guard-silenced — not pushed · fix-round-conflict failed lines=unknown"},
  {at:$c, action:"fix-round", reason:"head-not-reapproved", detail:"pushed def5678 to ticket/a-1, typecheck+unit green"}
 ], fixrounds:5, updated:$c}' > "$C5/state/blocked-resolver/alpha/A-1.json"
# A record whose mtime is older than the window is skipped unread, even though
# its attempt stamp looks in-window.
jq -nc --arg c "$S3" '{attempts:[{at:$c, action:"fix-round", reason:"conflict",
  detail:"push rejected under the lease · fix-round-conflict failed lines=9"}]}' \
  > "$C5/state/blocked-resolver/alpha/A-2.json"
touch -d '3 days ago' "$C5/state/blocked-resolver/alpha/A-2.json"
echo "not json" > "$C5/state/blocked-resolver/alpha/A-3.json"
digest "$C5" --window 24h
eq "C5 run exits 0" "$?" "0"
eq "C5 alpha fix-round-conflict ok" "$(row "$C5" alpha .fix_round_conflict.ok)" "1"
eq "C5 alpha fix-round-conflict failed (in-window, fresh files only)" "$(row "$C5" alpha .fix_round_conflict.failed)" "2"
eq "C5 fleet ok" "$(cj "$C5" .fleet.conflicts.fix_round_conflict.ok)" "1"
eq "C5 fleet failed" "$(cj "$C5" .fleet.conflicts.fix_round_conflict.failed)" "2"
eq "C5 the stale record was skipped unread" "$(cj "$C5" .sources.resolver_records.files_skipped_stale)" "1"
eq "C5 the unreadable record is counted as such" "$(cj "$C5" .sources.resolver_records.files_unreadable)" "1"
grep -q '^conflicts alpha: .*fix-round-conflict ok 1 failed 2' "$C5/state/dora/latest.txt" 2>/dev/null && ok \
  || bad "C5 alpha text line: $(grep '^conflicts alpha' "$C5/state/dora/latest.txt" 2>/dev/null)"

# ── C6: repair wakes consumed ───────────────────────────────────────────────
C6=$(tree c6)
merges "$C6" Org/alpha 1
{
  echo "$OLD10 [repair-on-push] REPAIR pr=4 files=1 action=rebase reason=pushed repo=Org/alpha wake=10 rc=0"
  echo "$(ago 100) [repair-on-push] wake=11 repo=Org/alpha range=aaaaaaaa..bbbbbbbb files=3"
  echo "$(ago 100) [repair-on-push] REPAIR pr=5 files=1 action=skip reason=locked repo=Org/alpha wake=11"
  echo "$(ago 100) [repair-on-push] wake=11 left for next tick (cursor stays at 10)"
  echo "$(ago 70) [repair-on-push] wake=11 repo=Org/alpha range=aaaaaaaa..bbbbbbbb files=3"
  echo "$(ago 70) [repair-on-push] REPAIR pr=5 files=1 action=rebase reason=pushed repo=Org/alpha wake=11 rc=0"
  echo "$(ago 70) [repair-on-push] wake=12 repo=Org/alpha range=cccccccc..dddddddd files=2"
  echo "$(ago 70) [repair-on-push] wake=12 left for next tick (cursor stays at 11)"
  echo "$(ago 60) [repair-on-push] REPAIR pr=- files=0 action=skip reason=unowned-repo repo=Other/zeta wake=13"
} > "$C6/logs/repair-on-push.log"
digest "$C6" --window 24h
eq "C6 run exits 0" "$?" "0"
eq "C6 alpha repair wakes (11 once; 12 left; 10 is old)" "$(row "$C6" alpha .repair_wakes)" "1"
eq "C6 fleet repair wakes (11 and the unowned 13)" "$(cj "$C6" .fleet.conflicts.repair_wakes)" "2"
eq "C6 the repair log source is ok" "$(cj "$C6" .sources.repair_on_push_log.status)" "ok"

# ── C7: every new source absent ─────────────────────────────────────────────
C7=$(tree c7)
digest "$C7" --window 24h
eq "C7 run exits 0" "$?" "0"
eq "C7 fleet carries a conflicts block" "$(cj "$C7" '.fleet | has("conflicts")')" "true"
for k in dirty_events rebuilds_per_100 fix_round_conflict dirty_to_clean_min repair_wakes; do
  eq "C7 fleet $k is null" "$(cj "$C7" ".fleet.conflicts.$k")" "null"
done
cj "$C7" .fleet.conflicts.unavailable.dirty_events | grep -q 'merge-conductor.log absent' && ok || bad "C7 dirty_events names its file"
cj "$C7" .fleet.conflicts.unavailable.rebuilds_per_100 | grep -q 'blocked-resolver.log absent' && ok || bad "C7 rebuilds names its file"
cj "$C7" .fleet.conflicts.unavailable.fix_round_conflict | grep -q 'state/blocked-resolver absent' && ok || bad "C7 fix rounds name their dir"
cj "$C7" .fleet.conflicts.unavailable.repair_wakes | grep -q 'repair-on-push.log absent' && ok || bad "C7 wakes name their file"
cj "$C7" .fleet.conflicts.unavailable.dirty_to_clean_min | grep -q 'absent' && ok || bad "C7 dirty-to-clean names its files"
grep -q '^conflicts (fleet): dirty n/a, rebuilds n/a, fix-round-conflict n/a, dirty->clean n/a, repair wakes n/a$' \
  "$C7/state/dora/latest.txt" 2>/dev/null && ok || bad "C7 text says n/a: $(grep '^conflicts' "$C7/state/dora/latest.txt" 2>/dev/null)"
eq "C7 no conflicts alert" "$(calerts "$C7")" "0"

# ── A4: env, then the settings row over env ─────────────────────────────────
A4=$(tree a4)
merges "$A4" Org/alpha 100
rebuilds "$A4" alpha 41
DORA_CONFLICTS_REBUILD_ALERT_PER_100=50 digest "$A4" --window 24h
eq "A4 env 50 run exits 0" "$?" "0"
eq "A4 41/100 under env 50: no line" "$(calerts "$A4")" "0"
eq "A4 env threshold" "$(cj "$A4" .fleet.conflicts.alert_threshold)" "50"
eq "A4 env threshold source" "$(cj "$A4" .fleet.conflicts.alert_threshold_source)" "env"
# A settings client whose row answers 30: the row wins over env 50.
mkdir -p "$A4/bin"
cat > "$A4/bin/jobs-client.sh" <<'SH'
_jobs_req() { [ "$2" = /api/settings ] && { printf '{"settings":[]}'; return 0; }; return 1; }
setting_get() { [ "$1" = conflicts.rebuild_alert_per_100 ] && { printf '30'; return 0; }; return 2; }
SH
LEDGER=1 DORA_CONFLICTS_REBUILD_ALERT_PER_100=50 digest "$A4" --window 24h
eq "A4 row run exits 0" "$?" "0"
eq "A4 the row 30 wins over env 50: one line" "$(calerts "$A4")" "1"
eq "A4 row threshold" "$(cj "$A4" .fleet.conflicts.alert_threshold)" "30"
eq "A4 row threshold source" "$(cj "$A4" .fleet.conflicts.alert_threshold_source)" "row"
grep '\[dora-conflicts\]' "$A4/logs/ALERTS.log" 2>/dev/null | grep -q 'conflicts.rebuild_alert_per_100 (30, row)' \
  && ok || bad "A4 the line names the knob and its value: $(cat "$A4/logs/ALERTS.log" 2>/dev/null)"

# ── A5 (second half): the alert reads the trailing 24 h, not the window ─────
A5=$(tree a5)
merges "$A5" Org/alpha 100
rebuilds "$A5" alpha 41 "$OLD5"
digest "$A5" --window 7d
eq "A5 7d run exits 0" "$?" "0"
J7="$A5/state/dora/$TODAY-7d.json"
neq "A5 the 7d block counts the 5-day-old rebuilds" "$(jq -r '.repos[] | select(.project=="alpha") | .conflicts.rebuilds_per_100' "$J7")" "41"
neq "A5 the trailing-24h figure the alert read" "$(jq -r '.fleet.conflicts.alert.trailing_24h.alpha.rebuilds_per_100' "$J7")" "0"
eq "A5 no line: the trailing 24 h has 0 rebuilds" "$(calerts "$A5")" "0"
rebuilds "$A5" alpha 41
digest "$A5" --window 7d
eq "A5 a 7d run with 41 rebuilds in the last 24 h fires" "$(calerts "$A5")" "1"

echo "dora-conflicts-block: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
