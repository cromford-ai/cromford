#!/bin/bash
# tests/lead-gates-delta-class.bh-8496-test.sh — gate 50's delta class and its
# delta.tsv cache (bin/lib/lead-gates.d/50-replay-delta.sh) on the worklist.
# bin/lead-review.sh tick runs WHOLE over tests/lib/lead-worklist-fixture.bh-4956.sh.
# Its repo is a clone of a real git fixture: base holds worker/jobs/schema.sql
# (40 lines, a lead protected path), f.txt (20 lines) and o.txt. G (the head the
# lead MERGEd) adds one line near the top of schema.sql and of f.txt; main then
# adds one line at the end of schema.sql and one in o.txt.
#   HO = G + 60 own lines in f.txt    (#51, over the default max 40)
#   HP = G + main merged + 5 own lines in schema.sql   (#52, 5 <= 20)
#   HS = G + 12 own lines in f.txt    (#53, a plain delta)
#   DC1   HO: `full over-max:60; a full lead review`, one job, no delta_note,
#         a delta.tsv row of class `full over-max:60`.
#   DC1b  HO under LEAD_DELTA_REVIEW_MAX_LINES=100: `delta 60 100 1;
#         LG_MODE=delta`, delta_note `lead-delta:<G> lines:60/100 files:1`.
#   DC2a  HP: one 8-column delta.tsv row, class `delta 5 40 1
#         protected:worker/jobs/schema.sql`, 8th column 20:MERGE; the delta_note
#         names the protected file.
#   DC2b  the next tick on HP under LEAD_DELTA_PROTECTED_MAX_LINES=0: the cached
#         class is not reused: `full protected:...`, a new row ending 0:MERGE,
#         one job, no delta_note.
#   DC3   HS: tick 1 fetches and caches a 7-column `delta 12 40 1` row; tick 2
#         makes no new fetch of HS and logs the same delta class.
#   M1    the cache rule with its allowance check removed: DC2b reuses the
#         protected delta and writes no row (so DC2b can fail).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-delta-class.bh-8496-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
for f in bin/lead-review.sh bin/lib/lead-gates.d/50-replay-delta.sh bin/lib/lead-delta.sh catalog/lanes.d/_lib.lead-delta.json; do
  [ -f "$SRC/$f" ] || { echo "FAIL: $f does not exist"; exit 1; }
done
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset LEAD_DELTA_REVIEW_MAX_LINES LEAD_DELTA_REVIEW_MAX_BYTES LEAD_DELTA_PROTECTED_MAX_LINES AGENT_CALL_FP AGENT_CALL_GUARD_STAGE

# ───────────────────────────── the fixture repo ─────────────────────────────
OR="$T/dc/origin.git"; WK="$T/dc/work"
git init -q --bare -b main "$OR"; git init -q -b main "$WK"
mkdir -p "$WK/worker/jobs"
seq 1 40 | sed 's/^/schema line /' > "$WK/worker/jobs/schema.sql"
seq 1 20 | sed 's/^/base line /' > "$WK/f.txt"; printf 'other\n' > "$WK/o.txt"
printf '# demo\n\nNo contract here.\n' > "$WK/CLAUDE.md"
git -C "$WK" add -A; git -C "$WK" commit -qm base
git -C "$WK" checkout -qb pr
sed -i '2a pr schema line' "$WK/worker/jobs/schema.sql"; sed -i '2a pr f line' "$WK/f.txt"
git -C "$WK" commit -qam "the pr"; G=$(git -C "$WK" rev-parse HEAD); G12=${G:0:12}
git -C "$WK" checkout -q main
echo 'main schema tail' >> "$WK/worker/jobs/schema.sql"; echo 'main moved' >> "$WK/o.txt"
git -C "$WK" commit -qam "main moves"
git -C "$WK" checkout -q pr; git -C "$WK" merge -q --no-edit main || { echo "FAIL: the fixture merge conflicted"; exit 1; }
H4=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" checkout -qb over "$G"; seq 1 60 | sed 's/^/over own /' >> "$WK/f.txt"
git -C "$WK" commit -qam "60 own lines"; HO=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" checkout -qb prot "$H4"; sed -i '20r /dev/stdin' "$WK/worker/jobs/schema.sql" < <(seq 1 5 | sed 's/^/prot own /')
git -C "$WK" commit -qam "5 own schema lines"; HP=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" checkout -qb small "$G"; seq 1 12 | sed 's/^/small own /' >> "$WK/f.txt"
git -C "$WK" commit -qam "12 own lines"; HS=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" push -q "$OR" main pr over prot small
git -C "$WK" push -q "$OR" "$HO:refs/pull/51/head" "$HP:refs/pull/52/head" "$HS:refs/pull/53/head"

# ─────────────────────── the worklist over that repo ───────────────────────
lwf_setup
export LEAD_REVIEW_AUTO_REPOS="example-org/demo-os"
scratch_rm "$T/repos/demo-os"; git clone -q "$OR" "$T/repos/demo-os"
REALGIT=$(command -v git)
cat > "$T/fakebin/git" <<GIT
#!/bin/bash
for a in "\$@"; do [ "\$a" = fetch ] && { printf '%s\n' "\$*" >> "$T/log/git-fetch"; break; }; done
exec "$REALGIT" "\$@"
GIT
chmod +x "$T/fakebin/git"
DELTA="$H/state/lead-review-enqueue/delta.tsv"
GATE="$H/bin/lib/lead-gates.d/50-replay-delta.sh"
[ -r "$GATE" ] || { echo "FAIL: the closure of bin/lead-review.sh did not install bin/lib/lead-gates.d/50-replay-delta.sh"; exit 1; }
# cset <pr> <head> — the worklist item and the lead MERGE on G; the delta.tsv cache stays
cset() {
  lwf_reset
  lwf_needs_at example-org/demo-os "$2" "$1"; echo "$2" > "$FX/head.$1"
  jq -nc --arg g "$G" --argjson p "$1" '{rows:[{id:7, source:"lead", repo:"example-org/demo-os", pr:$p, head_sha:$g, verdict:"MERGE", note:""}], truncated:false}' > "$FX/verdicts.json"
}
cfresh() { scratch_rm "$H/state/lead-review-enqueue"; }
jobs_for() { lwf_cnt "^POST /api/jobs .*\"ticket_id\":\"lr-$1-" "$T/log/worker"; }
# jmeta <pr> <key> — the key from the meta of the last lead_review job for <pr>
jmeta() {
  grep "^POST /api/jobs .*\"ticket_id\":\"lr-$1-" "$T/log/worker" 2>/dev/null | tail -1 | sed 's#^POST /api/jobs ##' \
    | jq -r --arg k "$2" '(.meta // "{}") | fromjson | .[$k] // empty' 2>/dev/null
}
rows_for() { awk -F'\t' -v n="$1" '$3 == n' "$DELTA" 2>/dev/null; }
nrows_for() { rows_for "$1" | grep -c .; }
gfetch() { lwf_cnt "fetch -q origin main $1" "$T/log/git-fetch"; }

# ── DC1: over LEAD_DELTA_REVIEW_MAX_LINES: a full review, cached as over-max ──
cfresh; cset 51 "$HO"; lwf_tick
grep -q "example-org/demo-os#51 @${HO:0:12}: since $G12: full over-max:60; a full lead review" "$L" && ok || bad "DC1 no over-max line: $(cat "$L")"
[ "$(jobs_for 51)" = 1 ] && ok || bad "DC1 jobs for 51=$(jobs_for 51) (want 1)"
[ -z "$(jmeta 51 delta_note)" ] && ok || bad "DC1 delta_note on a full review: '$(jmeta 51 delta_note)'"
[ "$(nrows_for 51)" = 1 ] && [ "$(rows_for 51 | awk -F'\t' '{print $7}')" = "full over-max:60" ] && ok || bad "DC1 delta.tsv: $(cat "$DELTA" 2>/dev/null)"

# ── DC1b: the same head under max 100: a delta review ──
cfresh; cset 51 "$HO"; LEAD_DELTA_REVIEW_MAX_LINES=100 lwf_tick
grep -q "example-org/demo-os#51 @${HO:0:12}: since $G12: delta 60 100 1; LG_MODE=delta" "$L" && ok || bad "DC1b no delta line: $(cat "$L")"
[ "$(jmeta 51 delta_note)" = "lead-delta:$G lines:60/100 files:1" ] && ok || bad "DC1b delta_note: '$(jmeta 51 delta_note)'"

# ── DC2a: a small protected delta: the cached row carries the allowance and the word ──
cfresh; cset 52 "$HP"; lwf_tick
[ "$(nrows_for 52)" = 1 ] && ok || bad "DC2a delta.tsv rows for 52: $(cat "$DELTA" 2>/dev/null) / $(cat "$L")"
[ "$(rows_for 52 | awk -F'\t' '{print NF}')" = 8 ] && ok || bad "DC2a the row is not 8 columns: $(rows_for 52)"
[ "$(rows_for 52 | awk -F'\t' '{print $7 "|" $8}')" = "delta 5 40 1 protected:worker/jobs/schema.sql|20:MERGE" ] && ok || bad "DC2a class/key: $(rows_for 52)"
[ "$(jmeta 52 delta_note)" = "lead-delta:$G lines:5/40 files:1 protected:worker/jobs/schema.sql" ] && ok || bad "DC2a delta_note: '$(jmeta 52 delta_note)'"

# ── DC2b: the next tick under knob 0 does not reuse the protected class ──
dc2b() {
  cset 52 "$HP"; LEAD_DELTA_PROTECTED_MAX_LINES=0 lwf_tick
}
dc2b
grep -q "example-org/demo-os#52 @${HP:0:12}: since $G12: full protected:worker/jobs/schema.sql; a full lead review" "$L" && ok || bad "DC2b no full protected line: $(cat "$L")"
[ "$(lwf_cnt "#52 @${HP:0:12}: .*LG_MODE=delta" "$L")" = 0 ] && ok || bad "DC2b the knob-0 tick reused the protected delta: $(cat "$L")"
# The review job's own replay check fetches HP in this tick either way, so the
# proof of a fresh classify is the second row: a reused class writes none (M1).
[ "$(nrows_for 52)" = 2 ] && [ "$(rows_for 52 | tail -1 | awk -F'\t' '{print $8}')" = "0:MERGE" ] && ok || bad "DC2b delta.tsv: $(rows_for 52)"
[ "$(jobs_for 52)" = 1 ] && ok || bad "DC2b jobs for 52=$(jobs_for 52) (want 1)"
[ -z "$(jmeta 52 delta_note)" ] && ok || bad "DC2b delta_note under knob 0: '$(jmeta 52 delta_note)'"

# ── DC3: a plain delta row is reused on the next tick with no fetch ──
cfresh; cset 53 "$HS"; lwf_tick
[ "$(nrows_for 53)" = 1 ] && [ "$(rows_for 53 | awk -F'\t' '{print NF "|" $7}')" = "7|delta 12 40 1" ] && ok || bad "DC3 tick 1 delta.tsv: $(rows_for 53) / $(cat "$L")"
f1=$(gfetch "$HS")
[ "$f1" -ge 1 ] && ok || bad "DC3 tick 1 made no fetch (tick 2 would prove nothing): $(cat "$T/log/git-fetch" 2>/dev/null)"
# Tick 2 keeps the logs and the job state, so the review job does not run again
# and every fetch of HS in it would be the gate's own.
lwf_tick
[ "$(gfetch "$HS")" = "$f1" ] && ok || bad "DC3 tick 2 fetched again ($(gfetch "$HS") vs $f1): $(cat "$T/log/git-fetch")"
[ "$(lwf_cnt "example-org/demo-os#53 @${HS:0:12}: since $G12: delta 12 40 1; LG_MODE=delta" "$L")" = 2 ] && ok || bad "DC3 tick 2 no delta line: $(cat "$L")"
[ "$(nrows_for 53)" = 1 ] && ok || bad "DC3 delta.tsv rows after 2 ticks: $(rows_for 53)"

# ── M1: without the allowance check the knob-0 tick reuses the class ──
cp "$GATE" "$T/gate.orig"
sed -i 's/|| \$8 == k)/|| 1)/' "$GATE"
cmp -s "$GATE" "$T/gate.orig" && bad "M1 the mutation did not apply"
cfresh; cset 52 "$HP"; lwf_tick
dc2b
[ "$(lwf_cnt "#52 @${HP:0:12}: since $G12: delta 5 40 1 protected:worker/jobs/schema.sql; LG_MODE=delta" "$L")" = 1 ] && ok || bad "M1 the mutated rule did not reuse the class: $(cat "$L")"
[ "$(nrows_for 52)" = 1 ] && ok || bad "M1 a reused class wrote a row: $(rows_for 52)"
cp "$T/gate.orig" "$GATE"
cmp -s "$GATE" "$SRC/bin/lib/lead-gates.d/50-replay-delta.sh" && ok || bad "M1 the gate was not restored"

echo "lead-gates-delta-class.bh-8496: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
