#!/bin/bash
# tests/pipeline-health-closeout-ageout-test.sh — the age-out and terminal-row
# rules in bin/pipeline-health.sh checks 4 and 5, extracted VERBATIM by their
# markers and driven with a recording alert() and a stubbed jobs ledger.
#
# THE BUG THIS PINS. Both checks had a floor (>1h) and no ceiling, and neither
# ever asked whether the ticket was already over. A build record from July
# therefore paged forever: 398 project-1 records with the oldest at 652h, plus
# three July/August EMPTY-URL dirs that each paged under their own key every 6
# hours. An alert nobody can act on is an alert nobody reads.
#
#   age-out:  a RESULT older than CLOSEOUT_AGE_OUT_H (default 168h) is recorded
#             in state/closeout-aged-out.tsv and stops paging. Recorded, not
#             silent — the tsv is the audit trail of every decision.
#   terminal: a record whose PR is merged (or whose PR was closed unmerged, or
#             that carries a SUPERSEDED marker) is nobody's close-out debt.
#   summary:  one line per project in logs/pipeline-health.log, one alert per
#             project, never one alert per record.
#
# A LEDGER OUTAGE IS NOT TERMINAL. Every negative below (parked, no row, rc 1,
# merge_sha "-") must still page: fail-open means keep alerting, never go quiet.
#
# Run from anywhere: tests/pipeline-health-closeout-ageout-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/builds" "$T/ledger" "$T/prfacts"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

printf 'x-os o/r https://x.example /api/board 2 local\n' > "$T/fleet.conf"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
printf '#!/bin/bash\nexit 1\n' > "$T/bin/queued-fly-relayed.sh"
chmod +x "$T/bin/beat.sh" "$T/bin/queued-fly-relayed.sh"

# The two blocks under test, lifted out of the production script by their
# markers. If the markers move or vanish this test fails loudly rather than
# quietly testing a copy that has drifted.
awk '/^# >>> no board close-out/{f=1;next} /^# <<< no board close-out/{exit} f' \
  "$DIR/bin/pipeline-health.sh" > "$T/c4.sh"
awk '/^# >>> empty url/{f=1;next} /^# <<< empty url/{exit} f' \
  "$DIR/bin/pipeline-health.sh" > "$T/c5.sh"
[ -s "$T/c4.sh" ] && [ -s "$T/c5.sh" ] && ok || bad "could not extract the close-out blocks — markers missing?"
cp "$DIR/bin/lib/closeout-terminal.sh" "$T/bin/lib/" 2>/dev/null \
  || bad "bin/lib/closeout-terminal.sh is missing"

# Pinned clock: every fixture age is computed from this one read, so the suite
# cannot pick its own red day.
NOW=$(date +%s)
TSV="$T/state/closeout-aged-out.tsv"

# drive <block> [VAR=VAL ...] — run one extracted block against the scratch tree.
drive() {
  local blk="$1"; shift
  : > "$T/alerts.txt"; : > "$T/err.txt"
  ( export HARNESS="$T" T="$T" NOW_PIN="$NOW"
    env "$@" bash -c '
      set -uo pipefail
      H="$T"; NOW="$NOW_PIN"; PROJECTS="x-os"
      STAMP() { echo TS; }
      alert() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/alerts.txt"; }
      # The jobs ledger, answered from files keyed by the PR number.
      job_ledger_get() {
        [ "${1:-}" = merge ] || return 1
        [ -f "$T/ledger-rc" ] && return "$(cat "$T/ledger-rc")"
        local n="${2##*/}"
        [ -f "$T/ledger/$n" ] || return 2
        cat "$T/ledger/$n"; return 0; }
      job_pr_facts() {
        [ -f "$T/prfacts-rc" ] && return "$(cat "$T/prfacts-rc")"
        local n="${1##*/}"
        [ -f "$T/prfacts/$n" ] || return 2
        cat "$T/prfacts/$n"; return 0; }
      . "$T/bin/lib/closeout-terminal.sh"
      . "$0"' "$T/$blk.sh" 2>"$T/err.txt" )
}

# mkrec <dirname> <age-seconds> <RESULT first line>
mkrec() {
  local d="$T/builds/$1"; mkdir -p "$d"
  printf '%s\n' "$3" > "$d/RESULT"
  touch -d "@$(( NOW - $2 ))" "$d/RESULT"
}
reset() {
  rm -rf "$T/builds" "$T/ledger" "$T/prfacts"
  mkdir -p "$T/builds" "$T/ledger" "$T/prfacts"
  rm -f "$T/ledger-rc" "$T/prfacts-rc" "$TSV"
  rm -rf "$T/state/pipeline-health"   # the BH-5941 skip set, cleared with the tsv it shadows
  : > "$T/logs/pipeline-health.log"
}
alerts() { cat "$T/alerts.txt" 2>/dev/null; }
health()  { cat "$T/logs/pipeline-health.log" 2>/dev/null; }

# Fixture ages, all derived from the one pinned NOW read above.
H200=720000; H167=601200; H2=7200; H30=108000

# ============================================================================
# 1. a 200h-old record ages out: no page, one summary line, one audit row
# ============================================================================
reset
mkrec x-os-TK-1-202607010000 "$H200" "PR_CREATED https://github.com/o/r/pull/1"
drive c4
[ ! -s "$T/alerts.txt" ] && ok || bad "a 200h-old record must not page: $(alerts) err=$(cat "$T/err.txt")"
health | grep -q 'x-os close-out: aged-out 1, terminal 0, still-open 0' \
  && ok || bad "the per-project summary line is missing: $(health)"
[ "$(wc -l < "$TSV" 2>/dev/null || echo 0)" -eq 1 ] \
  && ok || bad "exactly one audit row expected, got: $(cat "$TSV" 2>/dev/null)"
awk -F'\t' 'NR==1 && NF==4 && $1=="x-os" && $2=="x-os-TK-1-202607010000" \
  && $3=="PR_CREATED https://github.com/o/r/pull/1" && $4 ~ /^aged-out >168h \(200h\)$/ {exit 0} {exit 1}' "$TSV" \
  && ok || bad "audit row shape wrong: $(cat "$TSV" 2>/dev/null)"
# Out of scope, and it must stay out of scope: nothing backfills a close-out marker.
[ ! -f "$T/builds/x-os-TK-1-202607010000/COMMENTED" ] \
  && ok || bad "the age-out must never write a COMMENTED marker"

# 1b. one hour under the ceiling is still a live debt
reset
mkrec x-os-TK-1-202607010000 "$H167" "PR_CREATED https://github.com/o/r/pull/1"
drive c4
alerts | grep -q '^7200|uncommented:x-os:1|' \
  && ok || bad "a 167h-old record must still page: $(alerts)"
[ ! -s "$TSV" ] && ok || bad "a record under the ceiling must not be recorded as aged out: $(cat "$TSV")"

# 1c. the ceiling is an operator knob, and a junk value falls back to 168h
reset
mkrec x-os-TK-1-202607010000 "$H30" "PR_CREATED https://github.com/o/r/pull/1"
drive c4 CLOSEOUT_AGE_OUT_H=24
[ ! -s "$T/alerts.txt" ] && grep -q 'aged-out >24h (30h)' "$TSV" \
  && ok || bad "CLOSEOUT_AGE_OUT_H=24 must age out a 30h record: alerts=$(alerts) tsv=$(cat "$TSV" 2>/dev/null)"
reset
mkrec x-os-TK-1-202607010000 "$H30" "PR_CREATED https://github.com/o/r/pull/1"
drive c4 CLOSEOUT_AGE_OUT_H=abc
alerts | grep -q 'uncommented:x-os:1' \
  && ok || bad "a non-numeric CLOSEOUT_AGE_OUT_H must behave as 168h: $(alerts)"

# ============================================================================
# 2. three records, three verdicts, ONE alert and ONE summary line
# ============================================================================
reset
mkrec x-os-TK-1-202607010000 "$H200" "PR_CREATED https://github.com/o/r/pull/1"
mkrec x-os-TK-2-202609150000 "$H2"   "PR_CREATED https://github.com/o/r/pull/2"
mkrec x-os-TK-3-202609150000 "$H2"   "PR_CREATED https://github.com/o/r/pull/3"
echo merged > "$T/ledger/2"
drive c4
[ "$(alerts | grep -c .)" -eq 1 ] && ok || bad "exactly one alert expected for three records: $(alerts)"
alerts | grep -q '^7200|uncommented:x-os:1|' && ok || bad "the alert key must carry the still-open count: $(alerts)"
alerts | grep -q '(aged-out 1, terminal 1 ignored)' \
  && ok || bad "the alert line must say what it ignored: $(alerts)"
alerts | grep -q 'oldest x-os-TK-3' && ok || bad "the alert must still name a record: $(alerts)"
[ "$(health | grep -c 'x-os close-out:')" -eq 1 ] && ok || bad "exactly one summary line: $(health)"
health | grep -q 'x-os close-out: aged-out 1, terminal 1, still-open 1' \
  && ok || bad "summary counts wrong: $(health)"

# ============================================================================
# 3. terminal branches, and every negative that must still page
# ============================================================================
# 3. the merge ledger says merged
reset
mkrec x-os-TK-9-202609150000 "$H2" "PR_CREATED https://github.com/o/r/pull/9"
echo merged > "$T/ledger/9"
drive c4
[ ! -s "$T/alerts.txt" ] && health | grep -q 'aged-out 0, terminal 1, still-open 0' \
  && ok || bad "a merged PR is not owed a close-out: alerts=$(alerts) health=$(health)"

# 3b. no merge-ledger row, but the PR facts carry a merge_sha
reset
mkrec x-os-TK-9-202609150000 "$H2" "PR_CREATED https://github.com/o/r/pull/9"
printf 'j1\tx-os\tPB-9\tAPPROVE\tdeadbeef\t2\t0\t-' > "$T/prfacts/9"
drive c4
[ ! -s "$T/alerts.txt" ] && health | grep -q 'terminal 1' \
  && ok || bad "a merge_sha in the PR facts is terminal: alerts=$(alerts) health=$(health)"

# 3c. a PR the sweep recorded as closed unmerged is over too
reset
mkrec x-os-TK-9-202609150000 "$H2" "PR_CREATED https://github.com/o/r/pull/9"
echo closed > "$T/ledger/9"
drive c4
[ ! -s "$T/alerts.txt" ] && health | grep -q 'terminal 1' \
  && ok || bad "a closed PR is terminal: alerts=$(alerts) health=$(health)"

# 3c2. a SUPERSEDED marker, no network at all (what health-uncommented.sh honours)
reset
mkrec x-os-TK-9-202609150000 "$H2" "BUILD_DONE no pr here"
touch "$T/builds/x-os-TK-9-202609150000/SUPERSEDED"
drive c4
[ ! -s "$T/alerts.txt" ] && health | grep -q 'terminal 1' \
  && ok || bad "a SUPERSEDED marker is terminal: alerts=$(alerts) health=$(health)"

# 3d. the negatives: a non-terminal status, no row at all, an outage, an empty
#     merge_sha, and a RESULT with no PR url — every one of them still pages.
for NEG in parked norow outage nosha nourl; do
  reset
  case "$NEG" in
    parked)  mkrec x-os-TK-9-202609150000 "$H2" "PR_CREATED https://github.com/o/r/pull/9"; echo parked > "$T/ledger/9" ;;
    norow)   mkrec x-os-TK-9-202609150000 "$H2" "PR_CREATED https://github.com/o/r/pull/9" ;;
    outage)  mkrec x-os-TK-9-202609150000 "$H2" "PR_CREATED https://github.com/o/r/pull/9"; echo 1 > "$T/ledger-rc"; echo 1 > "$T/prfacts-rc" ;;
    nosha)   mkrec x-os-TK-9-202609150000 "$H2" "PR_CREATED https://github.com/o/r/pull/9"
             printf 'j1\tx-os\tPB-9\t-\t-\t2\t0\t-' > "$T/prfacts/9" ;;
    nourl)   mkrec x-os-TK-9-202609150000 "$H2" "BUILD_DONE something without a url" ;;
  esac
  drive c4
  alerts | grep -q '^7200|uncommented:x-os:1|' \
    && ok || bad "negative '$NEG' must still page: alerts=$(alerts) err=$(cat "$T/err.txt")"
done

# ============================================================================
# 4. the EMPTY-URL tripwire ages out too, and records exactly one row
# ============================================================================
reset
mkrec pool-x-os-TK-5-202607241847 4000000 "PR_CREATED "
drive c4
drive c5
[ ! -s "$T/alerts.txt" ] && ok || bad "an August empty-url record must not page: $(alerts)"
[ "$(awk -F'\t' '$2=="pool-x-os-TK-5-202607241847"' "$TSV" | grep -c .)" -eq 1 ] \
  && ok || bad "the dir must be recorded exactly once across both checks: $(cat "$TSV" 2>/dev/null)"
awk -F'\t' '$2=="pool-x-os-TK-5-202607241847" && $4 ~ /aged-out/ {n++} END{exit (n?0:1)}' "$TSV" \
  && ok || bad "the audit row must name the reason: $(cat "$TSV" 2>/dev/null)"
health | grep -q 'x-os empty-url: aged-out 1, still-open 0' \
  && ok || bad "the empty-url summary line is missing: $(health)"

# 4b. two live empty-url records page ONCE, per project, not once per record
reset
mkrec pool-x-os-TK-6-202609150000 "$H2" "PR_CREATED "
mkrec x-os-TK-7-202609150000     "$H2" "PR_CREATED "
drive c5
[ "$(alerts | grep -c .)" -eq 1 ] && ok || bad "two empty-url records must page once: $(alerts)"
alerts | grep -q '^21600|emptyurl:x-os:2|' && ok || bad "the key must be per project: $(alerts)"
alerts | grep -q 'pool-x-os-TK-6-202609150000' && alerts | grep -q 'x-os-TK-7-202609150000' \
  && ok || bad "the line must name the records: $(alerts)"
grep -qE '\|emptyurl:(pool-|x-os-PB)' <<<"$(alerts)" && bad "the old per-record key shape is still being emitted: $(alerts)" || ok

# ============================================================================
# 5. the audit file holds exactly the aged-out records, and nothing else
# ============================================================================
reset
mkrec x-os-TK-1-202607010000     "$H200" "PR_CREATED https://github.com/o/r/pull/1"
mkrec pool-x-os-TK-5-202607241847 4000000 "PR_CREATED "
mkrec x-os-TK-2-202609150000     "$H2"    "PR_CREATED https://github.com/o/r/pull/2"
drive c4
drive c5
[ "$(cut -f2 "$TSV" | sort | tr '\n' ' ')" = "pool-x-os-TK-5-202607241847 x-os-TK-1-202607010000 " ] \
  && ok || bad "the tsv must hold exactly the aged-out dirs: $(cut -f2 "$TSV" | sort | tr '\n' ' ')"
[ "$(awk -F'\t' 'NF==4' "$TSV" | grep -c .)" -eq "$(grep -c . "$TSV")" ] \
  && ok || bad "every row must have 4 tab-separated fields: $(cat "$TSV")"

# ============================================================================
# 6. a second run adds nothing — the record is a set, not a stream
# ============================================================================
cp "$TSV" "$T/tsv.before"
drive c4
drive c5
cmp -s "$T/tsv.before" "$TSV" && ok || bad "a second run changed the audit file: $(diff "$T/tsv.before" "$TSV")"
[ -z "$(sort "$TSV" | uniq -d)" ] && ok || bad "duplicate rows after a second run: $(sort "$TSV" | uniq -d)"

echo "pipeline-health-closeout-ageout: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
