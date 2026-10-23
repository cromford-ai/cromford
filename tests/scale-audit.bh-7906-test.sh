#!/bin/bash
# tests/scale-audit.bh-7906-test.sh — BH-7906: the scale envelope audit files
# stay whole. Reads committed files only.
#
#   A1  every `kind<TAB>name` row of "$DIR/docs/scale/inventory.tsv" appears,
#       in backticks, in "$DIR/docs/scale/ENVELOPES.md".
#   A2  every seam file (the ticket's globs plus bin/lib/gh-*.sh and
#       bin/*tg-send*), every lane id in catalog/lanes.d/ and every CREATE TABLE
#       in worker/jobs/schema.d/ is in the inventory, or is printed
#       `NOTE: new since audit: <kind> <name>`. A name added after the audit is
#       a note, not a failure: the inventory is frozen at audit time.
#   A3  the inventory has at least one lane, one table and one seam.
#   A4  every block in ENVELOPES.md has the 10 keys in order, and every NOW:
#       line is a sourced, dated number or `not measured (needs: ...)`.
#   A5  "$DIR/docs/scale/baseline.json" has the 9 keys; every value is a number
#       or "not measured"; each number is on a NOW: line of ENVELOPES.md.
#   A6  "$DIR/docs/scale/LANDMINES.md" has 1 to 3 entries with the six parts and
#       a SKIPPED TEST: that "$DIR/tests/scale-landmines.bh-7906-test.sh" skips,
#       or the line `No path breaks at or below NEXT`.
# Each check is a function over file paths, so the near misses run on fixture
# copies in $T and must go red.
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
INV="$DIR/docs/scale/inventory.tsv"
ENV_MD="$DIR/docs/scale/ENVELOPES.md"
BASE_JSON="$DIR/docs/scale/baseline.json"
LM="$DIR/docs/scale/LANDMINES.md"
LM_SUITE="$DIR/tests/scale-landmines.bh-7906-test.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
red() { if "$@" >/dev/null 2>&1; then bad "near miss stayed green: $*"; else ok; fi; }

# ── the checks ───────────────────────────────────────────────────────────────
# inv_missing <inventory> <envelopes> — prints each inventory row whose name is
# not in backticks in the envelopes file. rc 1 when any is missing.
inv_missing() {
  awk -F'\t' '
    NR == FNR { line = $0
      while (match(line, /`[^`]+`/)) { seen[substr(line, RSTART+1, RLENGTH-2)] = 1; line = substr(line, RSTART+RLENGTH) }
      next }
    /^#/ || NF < 2 { next }
    !($2 in seen) { print $1 "\t" $2; miss = 1 }
    END { exit miss }' "$2" "$1"
}

inv_count() { awk -F'\t' -v k="$2" '!/^#/ && $1 == k' "$1" | wc -l | tr -d ' '; }
inv_nonempty() { [ "$(inv_count "$1" lane)" -ge 1 ] && [ "$(inv_count "$1" table)" -ge 1 ] && [ "$(inv_count "$1" seam)" -ge 1 ]; }

now_ok() { # now_ok <line>
  grep -qE '^NOW: [0-9.,]+.*\(src: .+, 20[0-9]{2}-[0-9]{2}-[0-9]{2}\)|^NOW: not measured \(needs: .+\)' <<<"$1"
}

# blocks_ok <envelopes> — every ```text block has the 10 keys in order and a
# valid NOW. Prints one line per defect; rc 1 on any. rc 1 also with 0 blocks.
blocks_ok() {
  awk '
    BEGIN { n = split("PATH:|UNIT:|NOW:|NEXT: 10x|CEILING:|BREAKS FIRST AT CEILING:|SIGNAL:|COST NOW/NEXT/CEILING:|BUILT FOR TODAY:|DEFER UNTIL CEILING:", K, "|") }
    /^```text$/ { inb = 1; b++; delete at; ln = 0; next }
    inb && /^```$/ {
      last = 0
      for (i = 1; i <= n; i++) {
        if (!(i in at)) { print "block " b ": no " K[i]; bad = 1 }
        else if (at[i] < last) { print "block " b ": " K[i] " out of order"; bad = 1 }
        else last = at[i]
      }
      inb = 0; next }
    inb { ln++
      for (i = n; i >= 1; i--) if (index($0, K[i]) == 1 && !(i in at)) { at[i] = ln; break }
      if (index($0, "NOW:") == 1) print "NOWLINE\t" $0
      if (index($0, "DEFER UNTIL CEILING:") == 1 && index($0, "; trigger = ") == 0) { print "block " b ": DEFER has no trigger"; bad = 1 }
    }
    END { if (b == 0) { print "no blocks"; bad = 1 } exit bad }' "$1" > "$T/blocks.out"
  local rc=$? l
  while IFS=$'\t' read -r tag l; do
    [ "$tag" = NOWLINE ] || { echo "$tag"; continue; }
    now_ok "$l" || { echo "bad NOW: $l"; rc=1; }
  done < "$T/blocks.out"
  return "$rc"
}

# baseline_ok <baseline.json> <envelopes> <inventory>
baseline_ok() {
  jq -e '
    def val: type == "number" or . == "not measured";
    (keys | sort) == (["as_of","tickets_per_day","prs_per_day","builds_in_flight_peak","github_calls_per_hour","d1_rows_per_day","model_usd_per_day","fly_usd_per_day","sources"] | sort)
    and (.as_of | type == "string" and test("^20[0-9]{2}-[0-9]{2}-[0-9]{2}$"))
    and (.sources | type == "array" and length > 0 and all(.[]; type == "string"))
    and ([.tickets_per_day, .prs_per_day, .builds_in_flight_peak, .github_calls_per_hour, .model_usd_per_day, .fly_usd_per_day] | all(.[]; val))
    and (.d1_rows_per_day | type == "object" and length > 0 and all(.[]; val))' "$1" >/dev/null 2>&1 || { echo "baseline: shape"; return 1; }
  # Each number is the NOW of its path in ENVELOPES.md (commas ignored).
  local nows v
  nows=$(grep '^NOW:' "$2" | tr -d ',')
  for v in $(jq -r '[.tickets_per_day, .prs_per_day, .builds_in_flight_peak, .github_calls_per_hour, .model_usd_per_day, .fly_usd_per_day, (.d1_rows_per_day[])][] | numbers' "$1"); do
    grep -qE "(^NOW: |; )$v( |$)" <<<"$nows" || { echo "baseline: $v is on no NOW: line"; return 1; }
  done
  # One d1_rows_per_day key per inventory table.
  diff <(jq -r '.d1_rows_per_day | keys[]' "$1" | LC_ALL=C sort) \
       <(awk -F'\t' '!/^#/ && $1 == "table" {print $2}' "$3" | LC_ALL=C sort) >/dev/null \
    || { echo "baseline: d1_rows_per_day keys differ from the inventory tables"; return 1; }
}

# landmines_ok <LANDMINES.md> <landmines suite>
landmines_ok() {
  local n
  n=$(grep -c '^## ' "$1")
  if [ "$n" -eq 0 ]; then
    grep -q '^No path breaks at or below NEXT' "$1" || { echo "landmines: 0 entries and no no-break line"; return 1; }
    return 0
  fi
  [ "$n" -le 3 ] || { echo "landmines: $n entries, max 3"; return 1; }
  awk -v suite="$2" '
    function check() {
      if (name == "") return
      split("PATH:|WHAT BREAKS:|AT:|SMALLEST FIX:|TICKET TITLE:|TICKET BODY:|SKIPPED TEST:", P, "|")
      for (i = 1; i <= 7; i++) if (!(P[i] in got)) { print "landmines: " name ": no " P[i]; bad = 1 }
      if (body != 5) { print "landmines: " name ": TICKET BODY has " body " lines, want 5"; bad = 1 }
    }
    /^## / { check(); name = substr($0, 4); delete got; body = 0; inbody = 0; next }
    name != "" {
      if (match($0, /^[A-Z][A-Z ]+:/)) { k = substr($0, 1, RLENGTH); got[k] = 1; inbody = (k == "TICKET BODY:") }
      else if (inbody && $0 ~ /^[1-9]\. /) body++
      if (k == "SKIPPED TEST:" && index($0, "SKIPPED TEST: ") == 1) print "SKIP\t" substr($0, 15)
    }
    END { check(); exit bad }' "$1" > "$T/lm.out" || { grep -v '^SKIP' "$T/lm.out"; return 1; }
  local s
  while IFS=$'\t' read -r _ s; do
    grep -qF "skip \"$s\"" "$2" || { echo "landmines: no skip \"$s\" in the suite"; return 1; }
  done < <(grep '^SKIP' "$T/lm.out")
  [ "$(grep -c '^SKIP' "$T/lm.out")" -eq "$n" ] || { echo "landmines: not one SKIPPED TEST per entry"; return 1; }
}

# ── A1, A3 ───────────────────────────────────────────────────────────────────
if inv_nonempty "$INV"; then ok; else bad "A3 the inventory lacks a lane, a table or a seam"; fi
if out=$(inv_missing "$INV" "$ENV_MD"); then ok; else bad "A1 inventory names missing from ENVELOPES.md: $(head -n 5 <<<"$out" | tr '\n' ' ')"; fi
# Near misses: one lane row gone from ENVELOPES.md; an empty inventory.
lane1=$(awk -F'\t' '!/^#/ && $1 == "lane" {print $2; exit}' "$INV")
grep -vF "| \`$lane1\` |" "$ENV_MD" > "$T/env-nolane.md"
red inv_missing "$INV" "$T/env-nolane.md"
grep '^#' "$INV" > "$T/inv-empty.tsv"
red inv_nonempty "$T/inv-empty.tsv"
grep -v $'^seam\t' "$INV" > "$T/inv-noseam.tsv"
red inv_nonempty "$T/inv-noseam.tsv"

# ── A2 ───────────────────────────────────────────────────────────────────────
: > "$T/repo.tsv"
( cd "$DIR" || exit 1
  for p in bin/lib/*github* bin/lib/gh-*.sh bin/jobs-client.sh bin/lib/*fly* bin/*telegram* bin/*tg-send*; do
    [ -f "$p" ] && printf 'seam\t%s\n' "$p"
  done
  jq -r '.id // empty' catalog/lanes.d/*.json | sed 's/^/lane\t/'
  grep -hoiE 'CREATE TABLE (IF NOT EXISTS )?[A-Za-z_0-9]+' worker/jobs/schema.d/*.sql \
    | awk '{print "table\t" tolower($NF)}'
) | LC_ALL=C sort -u > "$T/repo.tsv"
grep -v '^#' "$INV" | LC_ALL=C sort -u > "$T/inv-rows.tsv"
new=$(LC_ALL=C comm -23 "$T/repo.tsv" "$T/inv-rows.tsv")
if [ -n "$new" ]; then printf '%s\n' "$new" | awk -F'\t' '{print "NOTE: new since audit: " $1 " " $2}'; fi
nnew=$(grep -c . <<<"$new" || true)
[ -s "$T/repo.tsv" ] && ok || bad "A2 the repo scan found nothing"

# ── A4 ───────────────────────────────────────────────────────────────────────
if out=$(blocks_ok "$ENV_MD"); then ok; else bad "A4 ENVELOPES.md blocks: $(head -n 5 <<<"$out" | tr '\n' ' ')"; fi
nblocks=$(grep -c '^```text$' "$ENV_MD")
[ "$nblocks" -ge 19 ] && ok || bad "A4 ENVELOPES.md has $nblocks blocks, want >= 19"
good_block() { printf '```text\nPATH: p\nUNIT: u\n%s\nNEXT: 10x = 1\nCEILING: c\nBREAKS FIRST AT CEILING: b\nSIGNAL: s\nCOST NOW/NEXT/CEILING: $0 / $0 / $0\nBUILT FOR TODAY: t\nDEFER UNTIL CEILING: d; trigger = x\n```\n' "$1"; }
good_block 'NOW: 42 calls/h (src: fixture ledger, 2026-10-21)' > "$T/blk-good.md"
if blocks_ok "$T/blk-good.md" >/dev/null; then ok; else bad "A4 a good fixture block went red"; fi
good_block 'NOW: not measured (needs: a fixture read)' > "$T/blk-nm.md"
if blocks_ok "$T/blk-nm.md" >/dev/null; then ok; else bad "A4 a not-measured fixture block went red"; fi
for l in 'NOW: 42' 'NOW: not measured' 'NOW: 42 (src: ledger)' 'NOW: about 40 (src: fixture ledger, 2026-10-21)'; do
  good_block "$l" > "$T/blk-bad.md"; red blocks_ok "$T/blk-bad.md"
done
sed '/^SIGNAL:/d' "$T/blk-good.md" > "$T/blk-nosignal.md"; red blocks_ok "$T/blk-nosignal.md"
sed 's/; trigger = x//' "$T/blk-good.md" > "$T/blk-notrigger.md"; red blocks_ok "$T/blk-notrigger.md"
awk '/^UNIT:/{u=$0; next} {print} /^NOW:/{print u}' "$T/blk-good.md" > "$T/blk-order.md"; red blocks_ok "$T/blk-order.md"
printf 'no blocks here\n' > "$T/blk-none.md"; red blocks_ok "$T/blk-none.md"

# ── A5 ───────────────────────────────────────────────────────────────────────
if out=$(baseline_ok "$BASE_JSON" "$ENV_MD" "$INV"); then ok; else bad "A5 baseline.json: $out"; fi
jq '.tickets_per_day = "0"' "$BASE_JSON" > "$T/b1.json"; red baseline_ok "$T/b1.json" "$ENV_MD" "$INV"
jq '.prs_per_day = null' "$BASE_JSON" > "$T/b2.json"; red baseline_ok "$T/b2.json" "$ENV_MD" "$INV"
jq '.model_usd_per_day = "unknown"' "$BASE_JSON" > "$T/b3.json"; red baseline_ok "$T/b3.json" "$ENV_MD" "$INV"
jq 'del(.fly_usd_per_day)' "$BASE_JSON" > "$T/b4.json"; red baseline_ok "$T/b4.json" "$ENV_MD" "$INV"
jq '.d1_rows_per_day[(.d1_rows_per_day|keys[0])] = "0"' "$BASE_JSON" > "$T/b5.json"; red baseline_ok "$T/b5.json" "$ENV_MD" "$INV"
jq '.github_calls_per_hour = 5701' "$BASE_JSON" > "$T/b6.json"; red baseline_ok "$T/b6.json" "$ENV_MD" "$INV"
jq '.d1_rows_per_day |= del(.[keys[0]])' "$BASE_JSON" > "$T/b7.json"; red baseline_ok "$T/b7.json" "$ENV_MD" "$INV"
printf '{"as_of":' > "$T/b8.json"; red baseline_ok "$T/b8.json" "$ENV_MD" "$INV"

# ── A6 ───────────────────────────────────────────────────────────────────────
if out=$(landmines_ok "$LM" "$LM_SUITE"); then ok; else bad "A6 LANDMINES.md: $out"; fi
nlm=$(grep -c '^## ' "$LM")
lmout=$(bash "$LM_SUITE"); lmrc=$?
if [ "$lmrc" -eq 0 ] && grep -q " $nlm skipped$" <<<"$lmout"; then ok; else bad "A6 the landmines suite: rc $lmrc, want 0 and '$nlm skipped': $lmout"; fi
printf '# fixture\n' > "$T/lm0.md"; red landmines_ok "$T/lm0.md" "$LM_SUITE"
printf '# fixture\nNo path breaks at or below NEXT: fixture evidence.\n' > "$T/lm0ok.md"
if landmines_ok "$T/lm0ok.md" "$LM_SUITE" >/dev/null; then ok; else bad "A6 the no-break line went red"; fi
entry() { printf '## %s\n\nPATH: p\n\nWHAT BREAKS: w\n\nAT: 1\n\nSMALLEST FIX: f\n\nTICKET TITLE: t\n\nTICKET BODY:\n1. a\n2. b\n3. c\n4. d\n5. e\n\nSKIPPED TEST: landmine BH-7906: %s\n\n' "$1" "$1"; }
{ echo '# fixture'; entry github-rest-shared-bucket; } > "$T/lm1.md"
if landmines_ok "$T/lm1.md" "$LM_SUITE" >/dev/null; then ok; else bad "A6 a good fixture entry went red"; fi
{ echo '# fixture'; for e in a b c d; do entry "$e"; done; } > "$T/lm4.md"; red landmines_ok "$T/lm4.md" "$LM_SUITE"
sed '/^SMALLEST FIX:/d' "$T/lm1.md" > "$T/lm5parts.md"; red landmines_ok "$T/lm5parts.md" "$LM_SUITE"
sed '/^5\. e$/d' "$T/lm1.md" > "$T/lm4lines.md"; red landmines_ok "$T/lm4lines.md" "$LM_SUITE"
{ echo '# fixture'; entry not-a-skip-in-the-suite; } > "$T/lmnoskip.md"; red landmines_ok "$T/lmnoskip.md" "$LM_SUITE"

if [ "$FAIL" -eq 0 ]; then
  echo "scale-audit: inventory covers $(inv_count "$INV" lane) lanes, $(inv_count "$INV" table) tables, $(inv_count "$INV" seam) seams; $nnew new since audit"
fi
echo "scale-audit.bh-7906: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
