#!/bin/bash
# tests/tickets-snapshot-branch-cache.bh-10217-test.sh — BH-10217:
# bin/tickets-snapshot-push.sh keeps the commit answer of each branch tip and
# the "no merged PR" answer of each branch, and reads the branch list only
# when a ticket has no open PR.
#
# Before (hub, 2026-11-26 10:00Z-10:33Z): 190 GETs in 33 min, about 345 spent
# GETs per hour; 86 commits/<sha>, 94 pulls?state=closed&head=, 10
# matching-refs. "Calls" below are the per-branch reads this ticket owns: the
# pulls?state=closed lookups plus the commits/<sha> reads in the stub gh log.
#
# The production entry point runs in a scratch harness: a fake `curl` for the
# board and the watchdog POST, a stub `gh` that logs each REST read (gh_rest's
# transport), a stub jobs client whose _jobs_req answers /api/pr-record-refs
# from a fixture, and a fake `date` for `date +%s` (the fixture clock). The
# project names carry this run's pid, so parallel runs share no file.
#   A1/B1 20 branch-only tickets, 3 ticks: 40 calls, then 0, then 0
#   A2    branch-commits.tsv holds 20 rows after tick 1
#   A3    a failed commits/ read writes no row; the next tick asks again
#   B2    a new sha on 1 branch: 2 calls, both for that branch
#   B3    a merged record row for 1 ref: 1 closed call, 0 commits, claim merged
#   B4    a closed (not merged) record row: 1 closed call, then 0
#   B5    /api/pr-record-refs answers 404: every branch asks GitHub, no row written
#   B6    the GitHub closed lookup fails: no row; the next tick asks again
#   B7/K1 the age bound (no knob = 21600): 21599 s old is valid, 21601 s is not
#   N1    a merged row of ticket/ab-10 does not end ticket/ab-1's row; an open
#         record row does not change the fingerprint
#   E1    ticks 1-3 push the same snapshot with TICKETS_SNAPSHOT_BRANCH_CACHE=0
#   L1/L2 matching-refs is read only when a ticket has no open PR
#   P1-P3 retention: a gone branch leaves both files; a failed list prunes
#         nothing; a row older than KEEP_DAYS leaves each of the 3 files
#   R1-R3 tsp_ref_states: hit, 404 = unreadable, truncated = miss
#   Z1    0 calls to a real host
# Run from anywhere: bash tests/tickets-snapshot-branch-cache.bh-10217-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
REAL_DATE=$(command -v date)

S="$T/h"; mkdir -p "$S/bin" "$S/env" "$S/logs" "$S/state" "$S/flags" "$T/fakebin" "$T/tmp" "$T/ans"
scratch_install_closure bin/tickets-snapshot-push.sh "$S" >/dev/null || { echo "FAIL: closure install"; exit 1; }
# The lane's seam is loaded by name (prr_seam_load), so no closure scan sees it.
scratch_install_closure bin/lib/prr-shadow.d/tickets-snapshot-push.sh "$S" >/dev/null 2>&1 || true
rm -f "$S/bin/lib/lane-gate.sh" "$S/bin/lib/wake-lanes.sh"

PA="pa$$"; PL="pl$$"
RA="example-org/snap-$PA"; RL="example-org/snap-$PL"
echo secret-fixture > "$S/env/.watchdog-secret"
: > "$S/env/global.env"; : > "$S/env/$PA.env"; : > "$S/env/$PL.env"
echo "$PA" > "$T/projs"
printf '#!/bin/bash\ncat "%s/projs"\n' "$T" > "$S/bin/fleet-projects-or-alert.sh"
cat > "$S/bin/fleet-conf.sh" <<'EOF'
#!/bin/bash
case "$2" in prod) echo https://board.example ;; board_prefix) echo /api ;; repo) echo "example-org/snap-$1" ;; *) echo - ;; esac
EOF
printf '#!/bin/bash\necho tok-fixture-1\n' > "$S/bin/internal-token-for.sh"
printf '#!/bin/bash\necho "$*" >> "%s/alerts.txt"\n' "$T" > "$S/bin/alert-line.sh"
chmod +x "$S/bin/"*.sh

# The stub jobs client. /api/pr-record-refs answers the rows of $T/recrefs.json
# whose head_ref is one of the asked refs (any state: the lane must filter);
# $T/refs-404 makes it a 404 (rc 2), $T/refs-trunc a truncated answer.
echo '[]' > "$T/recrefs.json"
{ printf 'TT=%q\n' "$T"; cat <<'EOF'
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$TT/jobs-calls.txt"
  case "$2" in
    /api/pr-record-refs\?*)
      [ -e "$TT/refs-404" ] && return 2
      [ -e "$TT/refs-trunc" ] && { echo '{"rows":[],"truncated":true}'; return 0; }
      local q=${2#*refs=}; q=${q%%&*}
      local js; js=$(printf '%b' "${q//%/\\x}")
      jq -c --argjson refs "$js" '{rows: [.[] | select(.head_ref as $h | any($refs[]; . == $h))], truncated: false}' "$TT/recrefs.json"
      return 0 ;;
  esac
  return 1
}
EOF
} > "$S/bin/jobs-client.sh"

# The stub gh: REST reads arrive as `gh api -i -X GET <path>` from gh_rest.
{ printf '#!/bin/bash\nTT=%q\n' "$T"; cat <<'EOF'
printf '%s\n' "$*" >> "$TT/gh-calls.txt"
A="$*"
case "$A" in
  "api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000}}}'; exit 0 ;;
  "api -i -X GET "*) ;;
  *) exit 1 ;;
esac
P=${A#api -i -X GET }; P=${P%% *}
f=""
case "$P" in
  *"pulls?state=open"*) r=${P#repos/}; r=${r%%/pulls*}; f="$TT/ans/open-${r//\//_}" ;;
  *"matching-refs"*)    r=${P#repos/}; r=${r%%/git*}; f="$TT/ans/refs-${r//\//_}"
                        [ -e "$f.fail" ] && exit 1 ;;
  *"pulls?state=closed"*) r=${P#*head=}; r=${r#*:}; r=${r%%&*}; f="$TT/ans/closed-${r//\//_}"
                        [ -e "$f.fail" ] && exit 1
                        [ -r "$f" ] || { printf 'HTTP/1.1 200 OK\r\n\r\n[]'; exit 0; } ;;
  *"/commits/"*)        s=${P#*/commits/}; [ -e "$TT/ans/commit-$s.fail" ] && exit 1
                        printf 'HTTP/1.1 200 OK\r\n\r\n{"author":{"login":"dev-%s"},"commit":{"committer":{"date":"2026-11-20T00:00:00Z"}}}' "${s:0:6}"; exit 0 ;;
esac
[ -n "$f" ] && [ -r "$f" ] || { printf 'HTTP/1.1 404 Not Found\r\n\r\n{"message":"Not Found"}'; exit 0; }
printf 'HTTP/1.1 200 OK\r\n\r\n'; cat "$f"
EOF
} > "$T/fakebin/gh"
{ printf '#!/bin/bash\nTT=%q\n' "$T"; cat <<'EOF'
printf '%s\n' "$*" >> "$TT/curl-calls.txt"
for a in "$@"; do
  case "$a" in
    */boards) echo '[{"id":"b1"}]'; exit 0 ;;
    */boards/b1/tickets) cat "$TT/tickets.json"; exit 0 ;;
    @*) cp "${a#@}" "$TT/pushed.json" ;;
  esac
done
exit 0
EOF
} > "$T/fakebin/curl"
# The fixture clock: `date +%s` answers $T/now; every other form is the real date.
{ printf '#!/bin/bash\nTT=%q\n' "$T"; printf 'RD=%q\n' "$REAL_DATE"; cat <<'EOF'
if [ "$*" = "+%s" ] && [ -s "$TT/now" ]; then cat "$TT/now"; exit 0; fi
exec "$RD" "$@"
EOF
} > "$T/fakebin/date"
chmod +x "$T/fakebin/"*

NOW=1795000000; echo "$NOW" > "$T/now"
sha() { printf 'a%03d%036d' "$1" "${2:-0}"; }     # sha <n> [generation]
safe() { printf '%s' "${1//\//_}"; }
# 20 branch-only tickets AB-1..AB-20, each on branch ticket/ab-N, no open PRs.
jq -nc '[range(1;21) | {key:("AB-" + tostring), status:(if . % 2 == 0 then "review" else "in_progress" end), title:("work " + tostring)}]
        + [{key:"AB-99", status:"todo", title:"later"}]' > "$T/tickets.json"
GEN=(); for n in $(seq 1 20); do GEN[$n]=0; done
refs_fixture() { # the matching-refs answer of RA from GEN[]; skip branch $1 if given
  local n out="[" sep=""
  for n in $(seq 1 20); do
    [ "${1:-}" = "$n" ] && continue
    out="$out$sep{\"ref\":\"refs/heads/ticket/ab-$n\",\"object\":{\"sha\":\"$(sha "$n" "${GEN[$n]}")\"}}"; sep=","
  done
  printf '%s]' "$out" > "$T/ans/refs-$(safe "$RA")"
}
refs_fixture
echo '[]' > "$T/ans/open-$(safe "$RA")"

tick() { # tick [ENV=VALUE...] — one lane run, the clock 600 s on
  NOW=$((NOW + 600)); echo "$NOW" > "$T/now"
  : > "$T/gh-calls.txt"; : > "$T/jobs-calls.txt"; rm -f "$T/pushed.json"
  ( cd "$T" && env HARNESS="$S" PATH="$T/fakebin:$PATH" TMPDIR="$T/tmp" GH_SOURCE=off \
      TICKETS_SNAPSHOT_MERGED_KEEP_DAYS=30 WATCHDOG_URL=http://watchdog.invalid "$@" \
      bash "$S/bin/tickets-snapshot-push.sh" ) >/dev/null 2>&1
}
closed()  { grep -c 'pulls?state=closed' "$T/gh-calls.txt" 2>/dev/null || true; }
commits() { grep -c '/commits/' "$T/gh-calls.txt" 2>/dev/null || true; }
calls()   { echo $(( $(closed) + $(commits) )); }
mrefs()   { grep -c 'matching-refs' "$T/gh-calls.txt" 2>/dev/null || true; }
rrefs()   { grep -c '/api/pr-record-refs?' "$T/jobs-calls.txt" 2>/dev/null || true; }
CDB="$S/state/tickets-snapshot/branch-commits.tsv"
NDB="$S/state/tickets-snapshot/not-merged.tsv"
MDB="$S/state/tickets-snapshot/merged-branches.tsv"
rows() { [ -s "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
snapshot() { jq -c 'del(.generated_at)' "$T/pushed.json" 2>/dev/null; }
claim() { jq -r --arg p "$PA" --arg k "$1" '.projects[$p].tickets[] | select(.key==$k) | .claim | "\(.kind) \(.state // "-") \(.pr) \(.ref)"' "$T/pushed.json" 2>/dev/null; }
nm_row() { awk -F'\t' -v b="ticket/ab-$1" '$2==b' "$NDB"; }
set_nm_epoch() { # set_nm_epoch <n> <epoch>
  awk -F'\t' -v OFS='\t' -v b="ticket/ab-$1" -v e="$2" '$2==b {$5=e} {print}' "$NDB" > "$NDB.t" && mv "$NDB.t" "$NDB"
}

# ---- A1/B1/A2: 40, 0, 0 ------------------------------------------------------------
tick; T1=$(calls); SNAP1=$(snapshot)
[ "$T1" = 40 ] && [ "$(closed)" = 20 ] && ok || bad "A1/B1 tick 1 = 40 calls (20 closed + 20 commits), got $T1 (closed $(closed), commits $(commits))"
[ "$(rows "$CDB")" = 20 ] && ok || bad "A2 branch-commits.tsv holds 20 rows after tick 1, got $(rows "$CDB")"
[ "$(rows "$NDB")" = 20 ] && ok || bad "B1 not-merged.tsv holds 20 rows after tick 1, got $(rows "$NDB")"
[ "$(rrefs)" = 1 ] && ok || bad "B1 one /api/pr-record-refs read per repo per tick, got $(rrefs)"
[ "$(claim AB-3)" = "branch - null ticket/ab-3" ] && ok || bad "B1 AB-3 claims its branch, got '$(claim AB-3)'"
tick; T2=$(calls); SNAP2=$(snapshot)
[ "$T2" = 0 ] && ok || bad "A1/B1 tick 2 = 0 calls, got $T2: $(grep -E 'closed|commits' "$T/gh-calls.txt" | head -3)"
tick; T3=$(calls); SNAP3=$(snapshot)
[ "$T3" = 0 ] && ok || bad "A1/B1 tick 3 = 0 calls, got $T3"
[ -n "$SNAP1" ] && [ "$SNAP1" = "$SNAP2" ] && [ "$SNAP2" = "$SNAP3" ] && ok || bad "B1 the cached ticks push the same snapshot as tick 1"

# ---- B2: a new sha on 1 branch = 2 calls for that branch ----------------------------
GEN[5]=1; refs_fixture
tick
[ "$(calls)" = 2 ] && grep -qF "head=example-org:ticket/ab-5&" "$T/gh-calls.txt" && grep -qF "commits/$(sha 5 1)" "$T/gh-calls.txt" && ok \
  || bad "B2 a new sha on ab-5 = 2 calls, both for ab-5, got $(calls): $(grep -E 'closed|commits' "$T/gh-calls.txt")"
[ "$(nm_row 5 | cut -f3)" = "$(sha 5 1)" ] && ok || bad "B2 the not-merged row of ab-5 holds the new sha: $(nm_row 5)"

# ---- B3: a merged record row = 1 closed call, the claim says merged -----------------
jq -c '. + [{number:106, state:"merged", head_ref:"ticket/ab-6", merged_at:"2026-11-26T09:00:00Z"}]' "$T/recrefs.json" > "$T/r.t" && mv "$T/r.t" "$T/recrefs.json"
echo '[{"number":106,"merged_at":"2026-11-26T09:00:00Z","html_url":"https://github.com/x/pull/106","user":{"login":"lead-dev"},"head":{"ref":"ticket/ab-6"}}]' > "$T/ans/closed-ticket_ab-6"
tick
[ "$(closed)" = 1 ] && [ "$(commits)" = 0 ] && grep -qF "head=example-org:ticket/ab-6&" "$T/gh-calls.txt" && ok \
  || bad "B3 a merged record row = 1 closed call for ab-6, 0 commits, got closed $(closed) commits $(commits)"
[ "$(claim AB-6)" = "pr merged 106 ticket/ab-6" ] && ok || bad "B3 AB-6 claims merged PR 106, got '$(claim AB-6)'"
[ -z "$(nm_row 6)" ] && ok || bad "B3 the merged branch leaves not-merged.tsv: $(nm_row 6)"
tick
[ "$(calls)" = 0 ] && ok || bad "B3 the tick after: 0 calls (merged is terminal), got $(calls)"

# ---- B4: a closed (not merged) record row = 1 closed call, then 0 -------------------
jq -c '. + [{number:107, state:"closed", head_ref:"ticket/ab-7", merged_at:null}]' "$T/recrefs.json" > "$T/r.t" && mv "$T/r.t" "$T/recrefs.json"
tick
[ "$(closed)" = 1 ] && [ "$(commits)" = 0 ] && grep -qF "head=example-org:ticket/ab-7&" "$T/gh-calls.txt" && ok \
  || bad "B4 a closed record row = 1 closed call for ab-7, got closed $(closed) commits $(commits)"
[ "$(nm_row 7 | cut -f4)" = "107:closed" ] && ok || bad "B4 the new fingerprint is stored: $(nm_row 7)"
tick
[ "$(calls)" = 0 ] && ok || bad "B4 the tick after = 0 calls, got $(calls)"

# ---- N1: near misses ----------------------------------------------------------------
jq -c '. + [{number:110, state:"merged", head_ref:"ticket/ab-10", merged_at:"2026-11-26T09:30:00Z"},
            {number:111, state:"open", head_ref:"ticket/ab-11", merged_at:null}]' "$T/recrefs.json" > "$T/r.t" && mv "$T/r.t" "$T/recrefs.json"
tick
[ "$(closed)" = 1 ] && grep -qF "head=example-org:ticket/ab-10&" "$T/gh-calls.txt" && ok \
  || bad "N1 a merged row of ticket/ab-10 ends only ab-10's row (not ab-1's), an open row of ab-11 ends nothing: $(grep closed "$T/gh-calls.txt")"
[ "$(nm_row 10 | cut -f4)" = "110:merged" ] && ok || bad "N1 ab-10 (no merged PR on GitHub) stores fingerprint 110:merged: $(nm_row 10)"
[ "$(nm_row 11 | cut -f4)" = "-" ] && ok || bad "N1 the open row does not enter ab-11's fingerprint: $(nm_row 11)"

# ---- B5: the record read is a 404 = unknown -------------------------------------------
touch "$T/refs-404"; cp "$NDB" "$T/nm-before"
tick
[ "$(closed)" = 19 ] && [ "$(commits)" = 0 ] && ok \
  || bad "B5 a 404 record read: every not-merged branch asks GitHub (19; ab-6 is merged), got closed $(closed) commits $(commits)"
cmp -s "$NDB" "$T/nm-before" && ok || bad "B5 not-merged.tsv gains no row on a 404 tick: $(diff "$T/nm-before" "$NDB")"
grep -qF "refs example-org/snap-$PA miss=unreadable" "$S/logs/pr-record.log" && ok || bad "B5 one pr-record.log miss line: $(tail -2 "$S/logs/pr-record.log" 2>/dev/null)"
rm -f "$T/refs-404"
tick
[ "$(calls)" = 0 ] && ok || bad "B5 the record answers again: 0 calls, got $(calls)"

# ---- B6/A3: a failed GitHub read writes no row; the next tick asks again -------------
GEN[8]=1; GEN[9]=1; refs_fixture
touch "$T/ans/closed-ticket_ab-8.fail" "$T/ans/commit-$(sha 9 1).fail"
tick
# (The old-sha row leaves through the retention by branch: the tip moved.)
[ "$(nm_row 8 | cut -f3)" != "$(sha 8 1)" ] && ok || bad "B6 a failed closed lookup writes no row for the new sha: $(nm_row 8)"
grep -qF "$(sha 9 1)" "$CDB" && bad "A3 a failed commits/ read writes no row" || ok
rm -f "$T/ans/closed-ticket_ab-8.fail" "$T/ans/commit-$(sha 9 1).fail"
tick
grep -qF "head=example-org:ticket/ab-8&" "$T/gh-calls.txt" && ok || bad "B6 the next tick asks ab-8 again"
grep -qF "commits/$(sha 9 1)" "$T/gh-calls.txt" && ok || bad "A3 the next tick asks the failed sha again"
[ "$(nm_row 8 | cut -f3)" = "$(sha 8 1)" ] && grep -qF "$(sha 9 1)" "$CDB" && ok || bad "B6/A3 the answered reads are stored"
tick
[ "$(calls)" = 0 ] && ok || bad "B6/A3 then 0 calls, got $(calls)"

# ---- B7/K1: the age bound, no knob in the env = 21600 -------------------------------
NEXT=$((NOW + 600))
set_nm_epoch 12 $((NEXT - 21601)); set_nm_epoch 13 $((NEXT - 21599))
tick
[ "$(closed)" = 1 ] && grep -qF "head=example-org:ticket/ab-12&" "$T/gh-calls.txt" && ok \
  || bad "B7/K1 a row 21601 s old asks GitHub, a row 21599 s old does not: $(grep closed "$T/gh-calls.txt")"
[ "$(nm_row 12 | cut -f5)" = "$NOW" ] && ok || bad "B7 the row is fresh after the read: $(nm_row 12)"
# ab-13's row (21599 s old a tick ago) is now past the bound: it alone asks.
tick
[ "$(calls)" = 1 ] && grep -qF "head=example-org:ticket/ab-13&" "$T/gh-calls.txt" && ok || bad "B7 the 21599 s row ages out on the next tick: $(grep closed "$T/gh-calls.txt")"
tick
[ "$(calls)" = 0 ] && ok || bad "B7 then 0 calls, got $(calls)"
set_nm_epoch 14 $((NOW + 600 - 700))
tick TICKETS_SNAPSHOT_NOT_MERGED_MAX_AGE_S=650
grep -qF "head=example-org:ticket/ab-14&" "$T/gh-calls.txt" && ok || bad "K1 the knob value is the bound (650 s): a 700 s row asks GitHub"
tick TICKETS_SNAPSHOT_NOT_MERGED_MAX_AGE_S=junk
[ "$(calls)" = 0 ] && ok || bad "K1 a junk knob falls back to 21600, got $(calls) calls"

# ---- P1-P3: retention ----------------------------------------------------------------
refs_fixture 20
tick
[ -z "$(nm_row 20)" ] && ok || bad "P1 a gone branch leaves not-merged.tsv: $(nm_row 20)"
grep -qF "$(sha 20 0)" "$CDB" && bad "P1 a gone branch's tip leaves branch-commits.tsv" || ok
[ -n "$(nm_row 19)" ] && grep -qF "$(sha 19 0)" "$CDB" && ok || bad "P1 a live branch keeps its rows"
grep -qF "$(sha 9 0)" "$CDB" && bad "P1 a tip that moved leaves branch-commits.tsv" || ok
cp "$NDB" "$T/nm-before"; cp "$CDB" "$T/c-before"
touch "$T/ans/refs-$(safe "$RA").fail"
tick
cmp -s "$NDB" "$T/nm-before" && cmp -s "$CDB" "$T/c-before" && ok || bad "P2 a failed branch list prunes nothing"
rm -f "$T/ans/refs-$(safe "$RA").fail"
OLD=$((NOW + 600 - 31 * 86400))
printf 'example-org/old\tticket/x\t%s\t-\t%s\n' "$(sha 90)" "$OLD" >> "$NDB"
printf 'example-org/old\t%s\t{"actor":"x","at":"y"}\t%s\n' "$(sha 90)" "$OLD" >> "$CDB"
printf 'example-org/old\tticket/x\t%s\t{"pr":1}\t%s\n' "$(sha 90)" "$OLD" >> "$MDB"
printf 'example-org/old\tticket/y\t%s\t-\t%s\n' "$(sha 91)" "$NOW" >> "$NDB"
tick
grep -qF "$(sha 90)" "$NDB" "$CDB" "$MDB" && bad "P3 a row older than KEEP_DAYS leaves each of the 3 files: $(grep -F "$(sha 90)" "$NDB" "$CDB" "$MDB")" || ok
grep -qF "$(sha 91)" "$NDB" && ok || bad "P3 a fresh row of another repo stays"

# ---- E1: the same snapshot with the cache off ------------------------------------------
# A fresh state over the tick-1 fixtures, 3 ticks with the cache off.
cp "$T/ans/refs-$(safe "$RA")" "$T/refs-keep"
for n in $(seq 1 20); do GEN[$n]=0; done; refs_fixture
echo '[]' > "$T/recrefs.json"; rm -f "$T/ans/closed-ticket_ab-6"
scratch_rm "$S/state/tickets-snapshot"
OFF=()
for i in 1 2 3; do
  tick TICKETS_SNAPSHOT_BRANCH_CACHE=0; OFF[$i]=$(snapshot)
  [ "$(calls)" = 40 ] && ok || bad "E1 cache off: tick $i = 40 calls as before BH-10217, got $(calls)"
  [ "$(rrefs)" = 0 ] && ok || bad "E1 cache off: 0 /api/pr-record-refs reads, got $(rrefs)"
done
[ ! -e "$CDB" ] && [ ! -e "$NDB" ] && ok || bad "E1 cache off writes neither file"
[ "${OFF[1]}" = "$SNAP1" ] && [ "${OFF[2]}" = "$SNAP2" ] && [ "${OFF[3]}" = "$SNAP3" ] && ok \
  || bad "E1 each cached tick's snapshot equals the cache-off snapshot: on=[$SNAP2] off=[${OFF[2]}]"

# ---- L1/L2: lazy matching-refs -----------------------------------------------------------
echo "$PL" > "$T/projs"
jq -nc '[{key:"AB-50", status:"in_progress", title:"on a PR"}, {key:"AB-51", status:"review", title:"on a PR"}]' > "$T/tickets.json"
jq -nc '[{number:50, title:"AB-50 x", head:{ref:"ticket/ab-50"}, user:{login:"dev"}, updated_at:"2026-11-26T00:00:00Z", html_url:"https://github.com/x/pull/50"},
         {number:51, title:"AB-51 y", head:{ref:"ticket/ab-51"}, user:{login:"dev"}, updated_at:"2026-11-26T00:00:00Z", html_url:"https://github.com/x/pull/51"}]' > "$T/ans/open-$(safe "$RL")"
echo '[{"ref":"refs/heads/ticket/ab-52","object":{"sha":"'"$(sha 52)"'"}}]' > "$T/ans/refs-$(safe "$RL")"
tick
[ "$(mrefs)" = 0 ] && [ "$(rrefs)" = 0 ] && ok || bad "L1 every ticket on an open PR: 0 matching-refs reads, got $(mrefs) (record reads $(rrefs))"
jq -r --arg p "$PL" '.projects[$p].tickets[] | .claim.pr' "$T/pushed.json" 2>/dev/null | tr '\n' ' ' | grep -qx '50 51 ' && ok || bad "L1 the open-PR claims still land"
jq -nc '[{key:"AB-50", status:"in_progress", title:"on a PR"}, {key:"AB-52", status:"review", title:"branch only"}]' > "$T/tickets.json"
tick
[ "$(mrefs)" = 1 ] && [ "$(calls)" = 2 ] && ok || bad "L2 1 branch-only ticket: 1 matching-refs read, got $(mrefs) (calls $(calls))"

# ---- R1-R3: tsp_ref_states ------------------------------------------------------------------
rs() { # rs <out-file> <args...> — the seam function in a subshell, as the lane loads it
  ( export HARNESS="$S"; . "$S/bin/lib/prr-shadow.d/tickets-snapshot-push.sh"; tsp_ref_states "$@" )
}
echo '[{"number":5,"state":"merged","head_ref":"ticket/r1","merged_at":"x"},{"number":6,"state":"closed","head_ref":"ticket/other","merged_at":null}]' > "$T/recrefs.json"
: > "$T/jobs-calls.txt"
W=$(rs "$T/rs.json" example-org/Snap-R ticket/r1 "agent/PB 249"); RC=$?
[ "$RC" = 0 ] && [ -z "$W" ] && [ "$(jq -c '[.[].number]' "$T/rs.json")" = "[5]" ] && ok || bad "R1 a hit: rc 0, the asked ref's rows, got rc $RC '$W' $(cat "$T/rs.json")"
grep -qF 'GET /api/pr-record-refs?repo=example-org/snap-r&refs=%5B%22ticket%2Fr1%22%2C%22agent%2FPB%20249%22%5D' "$T/jobs-calls.txt" && ok \
  || bad "R1 one GET, lower-case repo, URI-encoded JSON refs: $(cat "$T/jobs-calls.txt")"
touch "$T/refs-404"
W=$(rs "$T/rs.json" example-org/snap-r ticket/r1); RC=$?
[ "$RC" = 1 ] && [ "$W" = unreadable ] && [ ! -s "$T/rs.json" ] && ok || bad "R2 a 404: rc 1 unreadable and an empty file, got rc $RC '$W'"
rm -f "$T/refs-404"; touch "$T/refs-trunc"
W=$(rs "$T/rs.json" example-org/snap-r ticket/r1); RC=$?
[ "$RC" = 1 ] && [ "$W" = truncated ] && [ ! -s "$T/rs.json" ] && ok || bad "R3 a truncated answer: rc 1 truncated, got rc $RC '$W'"
rm -f "$T/refs-trunc"
rs "$T/rs.json" example-org/snap-r >/dev/null; [ "$?" = 2 ] && ok || bad "R3 no ref is rc 2"

# ---- Z1: 0 calls to a real host ----------------------------------------------------------------
OTHER=$(grep -vE 'https://board\.example|http://watchdog\.invalid' "$T/curl-calls.txt")
grep -qE 'https?://' <<<"$OTHER" \
  && bad "Z1 a curl call left the fixtures: $(grep -vE 'board\.example|watchdog\.invalid' "$T/curl-calls.txt" | head -2)" || ok
[ -s "$T/gh-calls.txt" ] && ! grep -vqE '^api ' "$T/gh-calls.txt" && ok || bad "Z1 every GitHub read went to the stub gh"

echo "tickets-snapshot-branch-cache.bh-10217: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
