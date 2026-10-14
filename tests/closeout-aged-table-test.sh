#!/bin/bash
# tests/closeout-aged-table-test.sh — the age-out audit as a TABLE (BH-1033,
# state→DB slice 8), with state/closeout-aged-out.tsv left as an archive.
#
# THE GAP THIS CLOSES, SAID EXACTLY. "We already decided this build record is
# too old to page about" is a line in a TSV on one box. That file is the AUDIT
# set, not the paging gate — bin/pipeline-health.sh decides to stop alerting
# from the RESULT's own mtime and never reads the tsv for it, and this slice
# does not touch that. What the file IS load-bearing for is the record of the
# decision and the dedupe of the write: lose it — a box rebuild, a state
# restore, a rotation, an operator clearing it — and the fleet forgets a verdict
# it already made, and the next sweep re-appends a row for every aged dir still
# under builds/. The decision has to live where the fleet can read it, not on
# whichever box happened to sweep.
#
# THE TICKET'S OWN RED: the dedupe survives an EMPTY TSV. A dir already recorded
# in the table is not recorded twice when the file is gone, so the set stays
# what the fleet decided instead of being rebuilt from whatever is still on one
# box's disk.
#
# FAIL-OPEN, AND LOUD ABOUT IT. A worker outage degrades to exactly today's
# file-only behaviour and leaves one log line. It never goes quiet: the aged-out
# count is what keeps a real wedge visible in the summary line.
#
# Run from anywhere: tests/closeout-aged-table-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$H/bin/"
# BH-1194: the client is a shim over bin/lib/jobs/ and refuses to half-load, so
# a fixture that copies it must copy its modules too.
mkdir -p "$H/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/closeout-terminal.sh" "$H/bin/lib/"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"

# The worker, file-backed: AGED holds `build_dir<TAB>project<TAB>head<TAB>reason`.
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in --data-binary) BODY="$2"; shift 2 ;; -X) M="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
[ "${CURL_MODE:-up}" = down ] && exit 7
case "$M $URL" in
  "GET "*/api/settings/*)
    K="${URL##*/}"
    if [ "$K" = closeout_aged_table ]; then
      printf '{"setting":{"key":"%s","value":"%s"}}\n200\n' "$K" "${FLAG_CLOSEOUT:-0}"
    else printf '{}\n404\n'; fi ;;
  "GET "*/api/closeout-aged*)
    D=""; case "$URL" in *build_dir=*) D="${URL##*build_dir=}"; D="${D%%&*}" ;; esac
    awk -F'\t' -v d="$D" 'BEGIN{printf "{\"aged\":["; n=0}
      (d=="" || $1==d){ if(n++) printf ","; printf "{\"build_dir\":\"%s\",\"project\":\"%s\",\"at\":\"2026-09-19T00:00:00Z\"}", $1,$2 }
      END{print "]}"}' "$AGED" 2>/dev/null
    echo 200 ;;
  "POST "*/api/closeout-aged)
    D=$(jq -r '.build_dir // ""' <<<"$BODY"); P=$(jq -r '.project // ""' <<<"$BODY")
    HD=$(jq -r '.result_head // ""' <<<"$BODY"); R=$(jq -r '.reason // ""' <<<"$BODY")
    if [ -z "$D" ]; then printf '{"error":"build_dir required"}\n400\n'
    elif awk -F'\t' -v d="$D" '$1==d{f=1} END{exit f?0:1}' "$AGED"; then
      printf '{"recorded":false,"duplicate":true}\n200\n'
    else
      printf '%s\t%s\t%s\t%s\n' "$D" "$P" "$HD" "$R" >> "$AGED"
      printf '{"recorded":true,"duplicate":false}\n201\n'
    fi ;;
  *) printf '{}\n200\n' ;;
esac
STUB
chmod +x "$T/fakebin/curl"

AGED="$T/aged.tsv"; : > "$AGED"
TSV="$H/state/closeout-aged-out.tsv"
LOCK="$H/locks/closeout-aged-out.lock"

# record <flag> <mode> <project> <dir> <head> <reason>
record() {
  local flag="$1" mode="$2"; shift 2
  : > "$T/req.txt"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 JOBS_TIMEOUT=5 \
           CURL_MODE="$mode" REQ_SINK="$T/req.txt" AGED="$AGED" FLAG_CLOSEOUT="$flag"
    bash -c '
      . "$HARNESS/bin/jobs-client.sh"
      . "$HARNESS/bin/lib/closeout-terminal.sh"
      closeout_record_aged "$1" "$2" "$3" "$4" "$5" "$6"' _ \
      "$TSV" "$LOCK" "$1" "$2" "$3" "$4" )
}
# `grep -c x f || echo 0` prints 0 AND THEN 0 when the count is zero (grep exits
# 1), so every count helper here is an awk that cannot do that.
rows_tsv()  { awk 'END{print NR+0}' "$TSV" 2>/dev/null || echo 0; }
rows_db()   { awk 'END{print NR+0}' "$AGED" 2>/dev/null || echo 0; }
aged_reqs() { awk '/\/api\/closeout-aged/{n++} END{print n+0}' "$T/req.txt" 2>/dev/null || echo 0; }
# client <flag> <mode> <snippet> — the client alone, no lib. Defined here rather
# than beside §8 because §3 reads the table back through it.
client() { # client <flag> <mode> <snippet>
  local flag="$1" mode="$2" snip="$3"
  : > "$T/req.txt"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 JOBS_TIMEOUT=5 \
           CURL_MODE="$mode" REQ_SINK="$T/req.txt" AGED="$AGED" FLAG_CLOSEOUT="$flag"
    bash -c '. "$HARNESS/bin/jobs-client.sh"; '"$snip" )
}

# ══ 1. FLAG OFF IS TODAY, BYTE FOR BYTE ═════════════════════════════════════
: > "$TSV"; : > "$AGED"
record 0 up x-os x-os-TK-1-202607 "PR_CREATED https://github.com/o/r/pull/7" "aged-out >168h (700h)"
[ "$(rows_tsv)" = 1 ] \
  && ok || bad "flag off must append exactly one TSV row, got $(rows_tsv): $(cat "$TSV")"
[ "$(aged_reqs)" = 0 ] \
  && ok || bad "flag off must make NO closeout-aged request: $(cat "$T/req.txt")"
record 0 up x-os x-os-TK-1-202607 "PR_CREATED https://github.com/o/r/pull/7" "aged-out >168h (700h)"
[ "$(rows_tsv)" = 1 ] \
  && ok || bad "the TSV is a SET — a second record of one dir adds nothing, got: $(cat "$TSV")"

# ══ 2. FLAG ON: THE ROW IS WRITTEN, AND THE FILE STAYS THE ARCHIVE ══════════
: > "$TSV"; : > "$AGED"
record 1 up x-os x-os-TK-2-202607 "PR_CREATED |" "aged-out >168h (700h)"
[ "$(rows_db)" = 1 ] \
  && ok || bad "flag on must record the dir in the TABLE, got: $(cat "$AGED")"
[ "$(rows_tsv)" = 1 ] \
  && ok || bad "the FILE stays a write-through archive for one cycle, got: $(cat "$TSV")"
[ "$(awk -F'\t' '{print $2}' "$AGED")" = x-os \
  ] && ok || bad "the row must carry the project, got: $(cat "$AGED")"
grep -q 'aged-out >168h' "$AGED" \
  && ok || bad "the row must carry the REASON — a row that cannot say why is the filename problem again: $(cat "$AGED")"

# ══ 3. RED CORE: THE DEDUPE SURVIVES AN EMPTY TSV ═══════════════════════════
: > "$TSV"          # the file is gone: a box rebuild, a restore, a rotation
record 1 up x-os x-os-TK-2-202607 "PR_CREATED |" "aged-out >168h (700h)"
[ "$(rows_db)" = 1 ] \
  && ok || bad "RED CORE: a dir already in the table must not be recorded twice, got: $(cat "$AGED")"
[ "$(rows_tsv)" = 0 ] \
  && ok || bad "RED CORE: with the table saying 'already decided', an emptied TSV must NOT be refilled, got: $(cat "$TSV")"
# ...and the table still ANSWERS for that dir, which is the durable half: the
# decision is readable after the file is gone, by any box, not just this one.
grep -qx 'rc=0' <<<"$(client 1 up 'closeout_aged_has x-os-TK-2-202607; echo "rc=$?"')" \
  && ok || bad "closeout_aged_has must still answer 'already decided' for a dir whose tsv row is gone"

# ══ 4. A DIR THE TABLE HAS NEVER SEEN IS STILL RECORDED ═════════════════════
record 1 up x-os x-os-TK-3-202608 "PR_CREATED |" "aged-out >168h (900h)"
[ "$(rows_db)" = 2 ] && [ "$(rows_tsv)" = 1 ] \
  && ok || bad "a NEW dir must be recorded in both, got db=$(cat "$AGED") tsv=$(cat "$TSV")"

# ══ 5. AN OUTAGE IS NOT 'ALREADY RECORDED' ═════════════════════════════════
: > "$TSV"; : > "$AGED"; : > "$H/logs/jobs-client.log"
record 1 down x-os x-os-TK-4-202608 "PR_CREATED |" "aged-out >168h (700h)"
[ "$(rows_tsv)" = 1 ] \
  && ok || bad "an outage must fall back to the TSV dedupe and still record, got: $(cat "$TSV")"
[ -s "$H/logs/jobs-client.log" ] \
  && ok || bad "a reader that failed open must leave a log line (iron law)"

# ══ 6. TABS AND NEWLINES CANNOT SPLIT A ROW ════════════════════════════════
: > "$TSV"; : > "$AGED"
record 1 up x-os "x-os-TK-5-202608" "$(printf 'PR_CREATED\ttwo\nlines')" "aged-out >168h"
[ "$(rows_tsv)" = 1 ] \
  && ok || bad "a RESULT head with a tab/newline must still be ONE TSV row, got: $(cat "$TSV")"
[ "$(rows_db)" = 1 ] \
  && ok || bad "…and ONE table row, got: $(cat "$AGED")"

# ══ 7. BAD ARGUMENTS ARE REFUSED, EVERYWHERE ═══════════════════════════════
: > "$TSV"; : > "$AGED"
record 1 up x-os "" "head" "reason"
[ "$(rows_db)" = 0 ] && [ "$(rows_tsv)" = 0 ] \
  && ok || bad "an empty build dir must write nothing anywhere"

# ══ 8. THE CLIENT'S CONTRACT ════════════════════════════════════════════════
: > "$AGED"
grep -qx 'rc=0' <<<"$(client 1 up 'closeout_aged_put x-os d-1 head reason >/dev/null; echo "rc=$?"')" \
  && ok || bad "closeout_aged_put must answer rc 0 on a fresh record"
grep -qx 'rc=3' <<<"$(client 1 up 'closeout_aged_put x-os d-1 head reason >/dev/null; echo "rc=$?"')" \
  && ok || bad "a DUPLICATE is its own answer (rc 3), never 'recorded' and never an error"
grep -qx 'rc=0' <<<"$(client 1 up 'closeout_aged_has d-1; echo "rc=$?"')" \
  && ok || bad "closeout_aged_has must answer rc 0 for a recorded dir"
grep -qx 'rc=2' <<<"$(client 1 up 'closeout_aged_has d-nope; echo "rc=$?"')" \
  && ok || bad "a dir with NO row is rc 2 — a real answer, not an outage"
grep -qx 'rc=1' <<<"$(client 1 down 'closeout_aged_has d-1; echo "rc=$?"')" \
  && ok || bad "an outage is rc 1 and is never confused with 'no row'"

# ══ 9. THE FLAG IS A DB ROW, AND OFF BY DEFAULT ════════════════════════════
grep -qx 'rc=1' <<<"$(client 0 up 'closeout_aged_table_on; echo "rc=$?"')" \
  && ok || bad "closeout_aged_table must be OFF at 0 — the flag is the whole rollback"
grep -qx 'rc=0' <<<"$(client 1 up 'closeout_aged_table_on; echo "rc=$?"')" \
  && ok || bad "closeout_aged_table_on must read the settings row"
grep -qx 'rc=1' <<<"$(client 1 down 'closeout_aged_table_on; echo "rc=$?"')" \
  && ok || bad "an outage must NEVER read as ON — a blinking worker must not switch a lane's code path"

# ══ 10. THE SCHEMA IS ADDITIVE AND SEEDED OFF ══════════════════════════════
grep -q 'CREATE TABLE IF NOT EXISTS closeout_aged' "$DIR/worker/jobs/schema.sql" \
  && ok || bad "worker/jobs/schema.sql must create closeout_aged (IF NOT EXISTS — the file re-applies on every deploy)"
grep -q "closeout_aged_table" "$DIR/worker/jobs/schema.sql" \
  && ok || bad "the closeout_aged_table flag must be SEEDED (INSERT OR IGNORE) so a knob nobody touched still answers"
grep -qE "INSERT OR IGNORE INTO settings[^;]*'closeout_aged_table','0'" \
     <(tr '\n' ' ' < "$DIR/worker/jobs/schema.sql") \
  && ok || bad "the seed must be 0 — this slice lands DARK"
grep -qE '^\s*(DROP|ALTER TABLE [A-Za-z_]+ (DROP|RENAME))' "$DIR/worker/jobs/schema.sql" \
  && bad "schema.sql must stay additive-only — no DROP, no rename" || ok

# ══ 11. THE NARRATIVE ON THE TABLE MATCHES WHAT THE CODE DOES ══════════════
# The tsv is the AUDIT set, not the paging gate: bin/pipeline-health.sh stops
# alerting from the RESULT's own mtime and never reads it to decide. A comment
# claiming "losing the file makes a year of aged-out records page again at once,
# because the dedupe IS the file" is a failure this code cannot have, and it is
# the comment an operator reads on the table itself before flipping the flag.
for F in worker/jobs/schema.sql bin/lib/closeout-terminal.sh docs/verification-map/ready-queue-rows.md; do
  [ -f "$DIR/$F" ] || continue
  grep -q 'dedupe IS the file' "$DIR/$F" \
    && bad "$F still claims losing the tsv makes aged-out records page again — it is the audit set, not the paging gate" || ok
done
grep -qi 'audit set' "$DIR/worker/jobs/schema.sql" \
  && ok || bad "worker/jobs/schema.sql must say what the tsv IS (the audit set) beside the table it backs"
# The gate itself: bin/pipeline-health.sh decides to stop paging from the
# RESULT's own mtime against CLOSEOUT_AGE_S and continues — it writes the tsv
# through closeout_record_aged, it never reads it to decide. Unchanged here.
# The window is anchored on the RESULT stat, not on any `NOW - stat` (the
# stuck-queue check at the top of the same file is one of those and has no `fi`
# to close the window on, so a looser anchor read the whole file and matched
# nothing) — rebase fix, BH-1033.
awk '/AGE=\$\(\( NOW - \$\(stat -c %Y "\$D\/RESULT"\) \)\)/{f=1} f{print} f && /^ *fi$/{exit}' \
  "$DIR/bin/pipeline-health.sh" | grep -qE 'if \[ "\$AGE" -gt "\$CLOSEOUT_AGE_S" \]' \
  && ok || bad "bin/pipeline-health.sh's age-out decision must still be the RESULT mtime vs CLOSEOUT_AGE_S"

echo "closeout-aged-table: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
