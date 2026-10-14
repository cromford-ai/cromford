#!/bin/bash
# tests/backup-freshness.bh-1308-test.sh — the 35 minutes after midnight UTC.
#
# F13 in tests/backup-freshness-test.sh says a report with no collection time
# must produce no record. It passed 97% of the time and read as a flake. It was
# not flaky and it was not a race: GNU `date -u -d ""` answers TODAY'S 00:00:00
# with rc 0, so bin/backup-records-sync.sh "dated" an undatable row at midnight.
# For the BF_RECORD_FRESH_MIN (35) minutes after 00:00Z that fabricated date is
# inside the collection window, the row is written, and F13 fails. Every other
# minute of the day the same row is skipped as stale and the suite is green. The
# two failing trains ran at 00:03:43Z and 00:24:56Z; main's green runs at 23:47Z
# and 00:44Z.
#
# R1-R4 pin that window with the clock PINNED (BACKUP_SYNC_NOW), so the case is
# deterministic at any wall-clock time instead of reachable for 35 minutes a
# day. Every one of them runs the REAL bin/backup-records-sync.sh — the
# production entry point, not an extracted function.
#
# R5 is the other half of the ticket: the `line 269: printf: write error: Broken
# pipe` noise. Line 269 is bf_rows' own printf, and it comes from a READER that
# closes the pipe while bf_rows is still printing later boxes. R5a proves the
# mechanism with a reader that closes early on every awk/head implementation;
# R5b proves the drain-into-a-variable shape tests/backup-freshness-test.sh's
# `rowfor` now uses does not. R6 then runs that whole suite with SIGPIPE ignored
# and demands zero such lines.
#
# The writer under test defaults to this checkout's and can be pointed at
# another copy, which is how the red-before-green check is run without touching
# the working tree:
#   git show main:bin/backup-records-sync.sh > /tmp/bh1308-main.sh
#   BH1308_SYNC_OVERRIDE=/tmp/bh1308-main.sh \
#     HARNESS_TEST_SANDBOX=1 bash tests/backup-freshness.bh-1308-test.sh
#
# Run from anywhere: tests/backup-freshness.bh-1308-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 36 || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SYNC="${BH1308_SYNC_OVERRIDE:-$DIR/bin/backup-records-sync.sh}"
[ -r "$SYNC" ] || { echo "FAIL: no writer to drive at $SYNC"; exit 1; }

# Every clock in this file is an offset from ONE read of today's midnight UTC,
# which is the anchor the defect is about. GNU date only: the whole point is
# what `date -d` does with an empty string, so a box without it has nothing to
# test rather than a different test.
MID=$(date -u -d "$(date -u +%F)" +%s 2>/dev/null) \
  || { echo "GNU date -d missing — skipping"; exit 0; }
stamp_at() { date -u -d "@$1" +%Y%m%dT%H%M%SZ; }   # the marker's own format
iso_at()   { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; } # what the worker reports
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

# A scratch hub whose ledger is a file, the tests/backup-freshness-test.sh
# new_hub idiom: bin/backup-records-sync.sh sources its client and calls
# box_backups, so a fake that defines that one function is the whole worker.
new_hub() {
  local Hb; Hb=$(mktemp -d "$T/hub-XXXXXX")
  mkdir -p "$Hb/bin/lib" "$Hb/logs" "$Hb/state/fleet-heartbeat" "$Hb/env"
  cp "$SYNC" "$Hb/bin/backup-records-sync.sh"
  cp "$DIR/bin/lib/backup-freshness.sh" "$Hb/bin/lib/"
  cp "$DIR/bin/lib/env-path.sh" "$Hb/bin/lib/" 2>/dev/null || true
  printf 'box-hub\n' > "$Hb/state/box-name"
  : > "$Hb/rows.tsv"
  cat > "$Hb/bin/fake-client.sh" <<FAKE
#!/bin/bash
box_backups() { cat "$Hb/rows.tsv" 2>/dev/null; }
FAKE
  printf '%s' "$Hb"
}
# The five-field TSV bin/lib/jobs/boxes.sh emits: box, ts, off, unconfigured,
# collection time. Written with printf, never `echo`, so an empty field stays an
# empty field between two tabs.
hub_row() { printf '%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" "$6" >> "$1/rows.tsv"; }
run_hub() {
  ( HARNESS="$1" BACKUP_SYNC_CLIENT="$1/bin/fake-client.sh" BACKUP_SYNC_NOW="$2" \
      HUB_BOX_NAME=box-hub bash "$1/bin/backup-records-sync.sh" >/dev/null 2>&1 )
}
logged() { grep -c "$2" "$1/logs/backup-records-sync.log" 2>/dev/null; }

# ---- R1: an EMPTY collection time, ten minutes after midnight ---------------
# The whole defect in one case. `date -u -d "" +%s` is today's 00:00:00 and rc
# 0, so the numeric guard on the next line sees a number, the window check sees
# a record ten minutes old, and a row nobody can date gets written.
H1=$(new_hub)
hub_row "$H1" box-nodate "$(stamp_at $((MID+300)))" "" "" ""
run_hub "$H1" $((MID+600))
R1F="$H1/state/fleet-heartbeat/backup-box-nodate"
[ ! -e "$R1F" ] \
  && ok || bad "R1: an empty collection time must produce no record at 00:10Z (got: '$(cat "$R1F" 2>/dev/null)')"
[ "$(logged "$H1" 'wrote 0 record(s), skipped 1')" = 1 ] \
  && ok || bad "R1b: the row must be COUNTED as skipped, not silently dropped (log: '$(cat "$H1/logs/backup-records-sync.log" 2>/dev/null)')"

# ---- R2: a BLANK collection time ------------------------------------------
# A single space is the same defect wearing a different hat: GNU date trims it
# and answers midnight again. A gate that only tested for the empty string
# would pass R1 and still write this row.
H2=$(new_hub)
hub_row "$H2" box-blank "$(stamp_at $((MID+300)))" "" "" " "
run_hub "$H2" $((MID+600))
R2F="$H2/state/fleet-heartbeat/backup-box-blank"
[ ! -e "$R2F" ] \
  && ok || bad "R2: a blank collection time must produce no record at 00:10Z (got: '$(cat "$R2F" 2>/dev/null)')"
[ "$(logged "$H2" 'wrote 0 record(s), skipped 1')" = 1 ] \
  && ok || bad "R2b: a blank collection time must be counted as skipped (log: '$(cat "$H2/logs/backup-records-sync.log" 2>/dev/null)')"

# ---- R3: THE CONTROL — a real dated row inside the same window -------------
# Without this every "must produce no record" above would pass on a writer that
# had simply stopped writing. A row collected at 00:08Z, read at 00:10Z, must
# still land with three fields and the mtime the report says.
H3=$(new_hub)
hub_row "$H3" box-dated "$(stamp_at $((MID+420)))" "" "" "$(iso_at $((MID+480)))"
run_hub "$H3" $((MID+600))
R3F="$H3/state/fleet-heartbeat/backup-box-dated"
[ -s "$R3F" ] \
  && ok || bad "R3: a row WITH a collection time must still be written (log: '$(cat "$H3/logs/backup-records-sync.log" 2>/dev/null)')"
[ "$(awk -F'\t' '{print NF; exit}' "$R3F" 2>/dev/null)" = 3 ] \
  && ok || bad "R3b: the record must carry three fields (got: '$(cat "$R3F" 2>/dev/null)')"
R3M=$(mtime_of "$R3F"); R3E=$((MID+480))
[ -n "${R3M:-}" ] && [ "$(( R3M > R3E - 90 && R3M < R3E + 90 ? 1 : 0 ))" = 1 ] \
  && ok || bad "R3c: the record must be dated from its report (mtime $R3M, expected ~$R3E)"

# ---- R4: the other side of the window --------------------------------------
# Forty minutes after midnight the fabricated date is older than
# BF_RECORD_FRESH_MIN, so the stale branch catches the same row and nothing is
# written. This is why the defect looked like a flake instead of a bug, and it
# must keep holding after the gate lands.
H4=$(new_hub)
hub_row "$H4" box-late "$(stamp_at $((MID+300)))" "" "" ""
run_hub "$H4" $((MID+2400))
[ ! -e "$H4/state/fleet-heartbeat/backup-box-late" ] \
  && ok || bad "R4: an empty collection time must produce no record at 00:40Z either"

# ---- R5: nobody closes the pipe while bf_rows is still printing -------------
# bf_rows prints one line per box and forks twice per line, so a reader that
# exits on the first match leaves the writer holding a closed pipe. With SIGPIPE
# ignored (as it is under some runners) every remaining printf reports
# `write error: Broken pipe` from bin/lib/backup-freshness.sh's own line.
BFX="$T/bfx"; mkdir -p "$BFX/state/fleet-heartbeat"
: > "$BFX/fleet.conf"
for i in $(seq -w 1 60); do
  printf 'proj-%s\t-\t-\t-\t-\tbox-%s\n' "$i" "$i" >> "$BFX/fleet.conf"
  printf '%s\t\t\n' "$(stamp_at "$MID")" > "$BFX/state/fleet-heartbeat/backup-box-$i"
done
touch "$BFX"/state/fleet-heartbeat/backup-box-*
# shellcheck source=bin/lib/backup-freshness.sh
. "$DIR/bin/lib/backup-freshness.sh" || { echo "FAIL: cannot source bin/lib/backup-freshness.sh"; exit 1; }
BFNOW=$(date +%s)
bfx_rows() { ( export HUB_BOX_NAME=box-hub FLEET_CONF="$BFX/fleet.conf"; bf_rows "$BFX" "$BFNOW" ); }
[ "$(bfx_rows | wc -l)" -gt 10 ] \
  && ok || bad "R5-setup: the fixture must give bf_rows many rows to print (got $(bfx_rows | wc -l))"

# R5a — the mechanism, on any implementation: a reader that closes after one
# line breaks the writer's later printfs.
EARLY=$( ( trap '' PIPE; bfx_rows | head -1 ) 2>&1 >/dev/null | grep -c 'Broken pipe' )
[ "${EARLY:-0}" -gt 0 ] \
  && ok || bad "R5a: a reader that closes early must be shown to break bf_rows' printf — otherwise R5b proves nothing (got $EARLY)"

# R5b — the fix's shape: drain bf_rows into a variable, THEN select. This is
# exactly what tests/backup-freshness-test.sh's rowfor does now.
drained() { local all; all=$(bfx_rows); printf '%s\n' "$all" | awk -F'\t' -v b="$1" '$1==b{print;exit}'; }
LATE=$( ( trap '' PIPE; drained box-01 >/dev/null ) 2>&1 | grep -c 'Broken pipe' )
[ "${LATE:-0}" = 0 ] \
  && ok || bad "R5b: draining into a variable first must leave no write error behind (got $LATE)"
[ "$( ( trap '' PIPE; drained box-01 ) 2>/dev/null | cut -f1 )" = box-01 ] \
  && ok || bad "R5b2: the drained reader must still select the row it was asked for"

# ---- R6: the suite this ticket is about, with SIGPIPE ignored ---------------
# The regression guard on the real file, and the case that FORCES the race
# instead of waiting for it. Whether an early-exit reader closes the pipe in
# time is a property of the awk on the box: gawk (the CI runner) processes
# records as they arrive and exits on the first match, mawk (Debian's
# /usr/bin/awk, this fleet) reads a whole block first and usually outlives the
# writer — which is the other reason this only ever showed up on some runs.
# `mawk -Winteractive` is mawk with line-buffered reads, so it makes the prompt
# exit deterministic here with no change to any awk semantics. Where the probe
# fails the awk in PATH is not mawk, and it already exits promptly. gawk ACCEPTS
# -Winteractive with a warning on stderr ("option `-W interactive'
# unrecognized, ignored") and rc 0, so a silent rc is not enough: the shim
# would add that warning to every awk call, and a block that must write nothing
# to stderr (backup-freshness-test B2) fails for the shim, not for the code.
mkdir -p "$T/awkshim"
if AWKPROBE=$(awk -Winteractive 'BEGIN{exit 0}' </dev/null 2>&1) && [ -z "$AWKPROBE" ]; then
  printf '#!/bin/sh\nexec %s -Winteractive "$@"\n' "$(command -v awk)" > "$T/awkshim/awk"
  chmod +x "$T/awkshim/awk"
fi
( trap '' PIPE; PATH="$T/awkshim:$PATH" HARNESS_TEST_SANDBOX=1 \
    bash "$DIR/tests/backup-freshness-test.sh" 2>"$T/bf-err" >/dev/null )
BFRC=$?
[ "$BFRC" = 0 ] \
  && ok || bad "R6: tests/backup-freshness-test.sh must pass (exit $BFRC)"
[ "$(grep -c 'Broken pipe' "$T/bf-err" 2>/dev/null)" = 0 ] \
  && ok || bad "R6b: tests/backup-freshness-test.sh must write no 'Broken pipe' line (got: '$(grep -m3 'Broken pipe' "$T/bf-err" 2>/dev/null)')"

echo "backup-freshness.bh-1308-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ] || exit 1
exit 0
