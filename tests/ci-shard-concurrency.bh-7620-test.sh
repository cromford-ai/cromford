#!/bin/bash
# tests/ci-shard-concurrency.bh-7620-test.sh — bin/ci-shard-concurrency.sh, the
# read-only report of shard wall time by how many merge-queue batches ran at
# once (BH-7620).
#
# Every case drives the REAL CLI. GitHub is a fixture directory (--from-dir)
# built in $T with jq, or (K10) a stub of `gh api <path>` over those files.
# The cap comes from a workflow fixture (--workflow-file). No case reads the
# network, the clock or the box.
#
#   K1  the header row is the exact column list; every row has as many fields
#       as the header; the summary has one `conc ` line per bucket
#   K2  one run alone is conc 1; three runs on one window are conc 3 each; two
#       runs that overlap by half: 1.5 rounds half up to 2, and the longer run
#       is 1.25 -> 1
#   K3  the cap is the tests-shard job's timeout-minutes (45, then 50): the
#       cap-cancel decision and the `cap:` line follow it; no tests-shard job
#       is rc 2
#   K4  cap-cancel: cancelled 45.4 min yes, cancelled 43 min no, timed_out
#       44.5 min yes, failure 45.5 min no, cancelled at exactly cap*60-60 s yes
#   K5  the real `ci-plan: sizing:` line gives plan_n, plan_est_min,
#       cap_reached and wall_over_est; no sizing line is `-`; a missing plan
#       log is `-` with the note `plan log unreadable`
#   K6  a run on page 2 is read; non-merge-queue branches and in_progress
#       runs are ignored; --last keeps the newest N
#   K7  a missing jobs file is an `unreadable` row, rc 3, other rows printed
#   K8  p50/p90/max and slowest/est per bucket equal hand-computed values
#   K9  a bad argument is rc 2
#   K10 the live read path: a stub gh on PATH (SHARD_CONC_GH) answers the
#       REST paths; pages 1 and 2 are asked, page 3 is not
#   K11 page 2 cannot be read: the page-1 rows stay, a stderr line names the
#       page, rc 3
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/ci-shard-concurrency.bh-7620-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
CLI="$REPO/bin/ci-shard-concurrency.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
[ -f "$CLI" ] || { echo "FAIL: $CLI does not exist"; echo "ci-shard-concurrency (BH-7620): 0 passed, 1 failed"; exit 1; }

# ── Fixture builders. All times are offsets in seconds from a fixed epoch.
B=1790000000
# mkrun <id> <created_off> [branch] [status] [pr] — one run object, one line
mkrun() {
  jq -nc --argjson id "$1" --argjson c "$((B + $2))" --arg br "${3:-mergify/merge-queue/h$1}" \
         --arg st "${4:-completed}" --arg pr "${5:--}" \
    '{id: $id, head_branch: $br, status: $st, created_at: ($c | todate), run_started_at: ($c | todate),
      pull_requests: (if $pr == "-" then [] else [{number: ($pr | tonumber)}] end)}'
}
# page <out> <file of run lines> — a workflow runs page
page() { jq -sc '{total_count: length, workflow_runs: .}' "$2" > "$1"; }
# mkjobs <dir> <id> <start:end:conclusion> ... — the plan job (id*100) and shard jobs
mkjobs() {
  local d="$1" id="$2"; shift 2
  printf '%s\n' "$@" | jq -Rsc --argjson id "$id" --argjson b "$B" '
    [split("\n")[] | select(length > 0) | split(":")] as $s
    | {total_count: (($s | length) + 1),
       jobs: ([{id: ($id * 100), name: "CI plan (what this run tests)", conclusion: "success",
                started_at: ($b | todate), completed_at: ($b | todate)}]
              + [$s | to_entries[] | {id: ($id * 100 + .key + 1),
                   name: "Tests, traced (shard \(.key + 1)/\($s | length))",
                   started_at: ($b + (.value[0] | tonumber) | todate),
                   completed_at: ($b + (.value[1] | tonumber) | todate),
                   conclusion: .value[2]}])}' > "$d/jobs-$id.json"
}
# wf <out> <timeout> — a workflow with a timeout before and after tests-shard
wf() {
  printf 'name: Harness CI\njobs:\n  lint:\n    timeout-minutes: 10\n  tests-shard:\n    name: Tests\n    timeout-minutes: %s\n    steps:\n      - run: true\n  decisions:\n    timeout-minutes: 99\n' "$2" > "$1"
}
wf "$T/wf45.yml" 45; wf "$T/wf50.yml" 50
printf 'name: x\njobs:\n  lint:\n    timeout-minutes: 10\n' > "$T/wf-none.yml"
# sc <args> — the real CLI; sets RC and OUT (stdout + stderr)
sc() { OUT=$(env -u SHARD_CONC_GH bash "$CLI" "$@" 2>&1); RC=$?; }
# col <run_id> <name> <tsv> — one field by its header name
col() { awk -F'\t' -v d="$1" -v c="$2" 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == c) k = i; next } $1 == d && k { print $k }' "$3" 2>/dev/null; }
line() { grep -m1 "^$1" <<<"$OUT"; }
PLANLINE='2026-10-19T10:00:01.1234567Z ci-plan: sizing: time (artifact), 12 shard(s), slowest est 2036s of budget 480s, cap 12; over budget (biggest suite 968s); cap reached'

# ── K2. Concurrency by window overlap.
X="$T/k2a"; mkdir -p "$X"; mkrun 1 0 > "$X/r"; page "$X/runs.json" "$X/r"; mkjobs "$X" 1 0:1000:success
sc --from-dir "$X" --workflow-file "$T/wf45.yml" --out "$T/k2a.tsv"
[ "$RC" = 0 ] && [ "$(col 1 conc "$T/k2a.tsv")" = 1 ] && ok || bad "K2: a run alone is conc 1 (rc $RC): $(cat "$T/k2a.tsv")"
X="$T/k2b"; mkdir -p "$X"; : > "$X/r"
for i in 1 2 3; do mkrun "$i" "$i" >> "$X/r"; mkjobs "$X" "$i" 0:600:success 100:1000:success; done
page "$X/runs.json" "$X/r"
sc --from-dir "$X" --workflow-file "$T/wf45.yml" --out "$T/k2b.tsv"
[ "$(col 1 conc "$T/k2b.tsv") $(col 2 conc "$T/k2b.tsv") $(col 3 conc "$T/k2b.tsv")" = "3 3 3" ] && ok || bad "K2: three runs on one window are conc 3: $(cat "$T/k2b.tsv")"
has "conc 3: runs 3," "$OUT" && ok || bad "K2: the summary has a conc 3 bucket of 3 runs: $OUT"
# X1 [0,1000], X2 [500,2500]: X1 = (1000 + 500) / 1000 = 1.5 -> 2; X2 = (2000 + 500) / 2000 = 1.25 -> 1.
X="$T/k2c"; mkdir -p "$X"; { mkrun 1 0; mkrun 2 1; } > "$X/r"; page "$X/runs.json" "$X/r"
mkjobs "$X" 1 0:1000:success; mkjobs "$X" 2 500:2500:success
sc --from-dir "$X" --workflow-file "$T/wf45.yml" --out "$T/k2c.tsv"
[ "$(col 1 conc "$T/k2c.tsv")" = 2 ] && ok || bad "K2: half overlap 1.5 rounds half up to 2: $(cat "$T/k2c.tsv")"
[ "$(col 2 conc "$T/k2c.tsv")" = 1 ] && ok || bad "K2: the long run is 1.25 -> 1: $(cat "$T/k2c.tsv")"

# ── K3. The cap from the workflow file. One shard cancelled at 44.5 min (2670 s).
X="$T/k3"; mkdir -p "$X"; mkrun 1 0 > "$X/r"; page "$X/runs.json" "$X/r"; mkjobs "$X" 1 0:2670:cancelled
sc --from-dir "$X" --workflow-file "$T/wf45.yml" --out "$T/k3a.tsv"
[ "$(col 1 cap_cancelled "$T/k3a.tsv")" = 1 ] && ok || bad "K3: cap 45: 44.5 min is a cap-cancel: $(cat "$T/k3a.tsv")"
[ "$(line cap:)" = "cap: 45 min (harness-ci.yml tests-shard)" ] && ok || bad "K3: cap line 45: $OUT"
sc --from-dir "$X" --workflow-file "$T/wf50.yml" --out "$T/k3b.tsv"
[ "$(col 1 cap_cancelled "$T/k3b.tsv")" = 0 ] && ok || bad "K3: cap 50: 44.5 min is no cap-cancel: $(cat "$T/k3b.tsv")"
[ "$(line cap:)" = "cap: 50 min (harness-ci.yml tests-shard)" ] && ok || bad "K3: cap line 50: $OUT"
sc --from-dir "$X" --workflow-file "$T/wf-none.yml"
[ "$RC" = 2 ] && ok || bad "K3: no tests-shard timeout is rc 2, got $RC: $OUT"

# ── K4. The cap-cancel rule, one shard per run, runs far apart (conc 1 each).
X="$T/k4"; mkdir -p "$X"; : > "$X/r"; i=0
for s in 2724:cancelled 2580:cancelled 2670:timed_out 2730:failure 2640:cancelled; do
  i=$((i + 1)); o=$((i * 10000)); mkrun "$i" "$o" >> "$X/r"; mkjobs "$X" "$i" "$o:$((o + ${s%%:*})):${s#*:}"
done
page "$X/runs.json" "$X/r"
sc --from-dir "$X" --workflow-file "$T/wf45.yml" --out "$T/k4.tsv"
got=""; for i in 1 2 3 4 5; do got="$got$(col "$i" cap_cancelled "$T/k4.tsv")"; done
[ "$got" = 10101 ] && ok || bad "K4: cap-cancel per run (45.4c 43c 44.5t 45.5f 44.0c) must be 10101, got $got: $(cat "$T/k4.tsv")"
has "cap-cancelled shards 3 in 3 runs" "$(line 'conc 1:')" && ok || bad "K4: summary counts 3 shards in 3 runs: $OUT"

# ── K5. The plan line.
X="$T/k5"; mkdir -p "$X"; { mkrun 1 30000; mkrun 2 20000; mkrun 3 10000; } > "$X/r"; page "$X/runs.json" "$X/r"
mkjobs "$X" 1 30000:32442:success 30000:31000:success; printf 'setup\n%s\nmore\n' "$PLANLINE" > "$X/plan-1.log"
mkjobs "$X" 2 20000:20600:success; printf 'ci-plan: sizing: count, 3 shard(s), slowest est 600s of budget 480s, cap 12\n' > "$X/plan-2.log"
mkjobs "$X" 3 10000:10600:success
sc --from-dir "$X" --workflow-file "$T/wf45.yml" --out "$T/k5.tsv"
k5="$(col 1 plan_n "$T/k5.tsv") $(col 1 plan_est_min "$T/k5.tsv") $(col 1 cap_reached "$T/k5.tsv") $(col 1 slowest_wall_min "$T/k5.tsv") $(col 1 wall_over_est "$T/k5.tsv")"
# 2036 s = 33.9 min; slowest 2442 s = 40.7 min; 2442 / 2036 = 1.199 -> 1.20.
[ "$k5" = "12 33.9 yes 40.7 1.20" ] && ok || bad "K5: the real sizing line, want '12 33.9 yes 40.7 1.20', got '$k5'"
[ "$(col 1 mean_wall_min "$T/k5.tsv")" = 28.7 ] && ok || bad "K5: mean of 2442 s and 1000 s is 28.7 min: $(cat "$T/k5.tsv")"
[ "$(col 2 cap_reached "$T/k5.tsv") $(col 2 wall_over_est "$T/k5.tsv")" = "no 1.00" ] && ok || bad "K5: no 'cap reached' is no: $(cat "$T/k5.tsv")"
[ "$(col 3 plan_n "$T/k5.tsv") $(col 3 plan_est_min "$T/k5.tsv") $(col 3 wall_over_est "$T/k5.tsv") $(col 3 conc "$T/k5.tsv")" = "- - - 1" ] \
  && [ "$(col 3 note "$T/k5.tsv")" = "plan log unreadable" ] && ok || bad "K5: a missing plan log is '-' with a note, the row counts: $(cat "$T/k5.tsv")"
[ "$RC" = 0 ] && ok || bad "K5: a missing plan log is not unreadable, rc 0, got $RC"
printf 'nothing here\n' > "$X/plan-3.log"
sc --from-dir "$X" --workflow-file "$T/wf45.yml" --out "$T/k5b.tsv"
[ "$(col 3 plan_n "$T/k5b.tsv") $(col 3 cap_reached "$T/k5b.tsv") $(col 3 note "$T/k5b.tsv")" = "- - -" ] && ok || bad "K5: no sizing line is '-' and no note: $(cat "$T/k5b.tsv")"

# ── K6. Pages, filters, --last.
X="$T/k6"; mkdir -p "$X"; : > "$X/p1"
mkrun 101 9000 mergify/merge-queue/a >> "$X/p1"; mkrun 102 8900 mergify/merge-queue/b in_progress >> "$X/p1"
mkrun 103 8800 mergify/merge-queue/c completed 7613 >> "$X/p1"
for i in $(seq 1 97); do mkrun "$((1000 + i))" "$((8000 - i))" main >> "$X/p1"; done
: > "$X/p2"; for i in 201 202 203; do mkrun "$i" "$((7000 - i))" >> "$X/p2"; done; mkrun 204 6000 ticket/x >> "$X/p2"
page "$X/runs-1.json" "$X/p1"; page "$X/runs-2.json" "$X/p2"
for i in 101 103 201 202 203; do mkjobs "$X" "$i" "$((i * 1000)):$((i * 1000 + 60)):success"; done
sc --from-dir "$X" --workflow-file "$T/wf45.yml" --last 4 --out "$T/k6.tsv"
ids=$(awk -F'\t' 'NR > 1 { printf "%s ", $1 }' "$T/k6.tsv")
[ "$ids" = "101 103 201 202 " ] && ok || bad "K6: --last 4 over two pages, newest first, want '101 103 201 202 ', got '$ids'"
[ "$(col 103 draft "$T/k6.tsv") $(col 101 draft "$T/k6.tsv")" = "7613 -" ] && ok || bad "K6: draft from pull_requests[0].number: $(cat "$T/k6.tsv")"
[ "$(line runs:)" = "runs: 4 read, 0 unreadable" ] && ok || bad "K6: runs line: $OUT"

# ── K7. A missing jobs file.
X="$T/k7"; mkdir -p "$X"; { mkrun 1 0; mkrun 2 5000; mkrun 3 10000; } > "$X/r"; page "$X/runs.json" "$X/r"
mkjobs "$X" 1 0:60:success; mkjobs "$X" 3 10000:10060:success
printf '{"total_count": 5, "jobs": []}\n' > "$X/jobs-2.json"
sc --from-dir "$X" --workflow-file "$T/wf45.yml" --out "$T/k7a.tsv"
[ "$RC" = 3 ] && [ "$(col 2 conc "$T/k7a.tsv")" = unreadable ] && ok || bad "K7: total_count > jobs is unreadable, rc 3 (rc $RC): $(cat "$T/k7a.tsv")"
rm -f "$X/jobs-2.json"
sc --from-dir "$X" --workflow-file "$T/wf45.yml" --out "$T/k7.tsv"
[ "$RC" = 3 ] && ok || bad "K7: a missing jobs file is rc 3, got $RC"
r2=$(awk -F'\t' '$1 == 2' "$T/k7.tsv")
[ "$(col 2 conc "$T/k7.tsv")" = unreadable ] && [ "$(col 2 shards "$T/k7.tsv") $(col 2 cap_cancelled "$T/k7.tsv")" = "- -" ] \
  && [ "$(col 2 started_at "$T/k7.tsv")" = "$(jq -nr --argjson e $((B + 5000)) '$e | todate')" ] && ok || bad "K7: the unreadable row: '$r2'"
[ "$(col 1 conc "$T/k7.tsv") $(col 3 conc "$T/k7.tsv")" = "1 1" ] && ok || bad "K7: the other rows still print: $(cat "$T/k7.tsv")"
[ "$(line runs:)" = "runs: 2 read, 1 unreadable" ] && ok || bad "K7: runs line: $OUT"

# ── K8. Percentiles. Three runs on window [0,1200] (conc 3), ten walls 120..1200 s
# in steps of 120: p50 = rank 5 = 600 s = 10.0; p90 = rank 9 = 1080 s = 18.0;
# max 20.0. slowest/est: run 1 360/240 = 1.50, run 2 720/600 = 1.20, run 3 none:
# p50 = rank 1 = 1.20, max 1.50. A solo run far away is bucket 1.
X="$T/k8"; mkdir -p "$X"; { mkrun 1 3; mkrun 2 2; mkrun 3 1; mkrun 4 100000; } > "$X/r"; page "$X/runs.json" "$X/r"
mkjobs "$X" 1 0:120:success 960:1200:success 840:1200:success
mkjobs "$X" 2 0:480:success 600:1200:success 480:1200:success
mkjobs "$X" 3 0:840:success 240:1200:success 120:1200:success 0:1200:success
mkjobs "$X" 4 100000:100060:success
printf 'ci-plan: sizing: time (artifact), 3 shard(s), slowest est 240s of budget 480s, cap 12\n' > "$X/plan-1.log"
printf 'ci-plan: sizing: time (artifact), 3 shard(s), slowest est 600s of budget 480s, cap 12\n' > "$X/plan-2.log"
sc --from-dir "$X" --workflow-file "$T/wf45.yml" --out "$T/k8.tsv"
[ "$(line 'conc 3:')" = "conc 3: runs 3, shard wall p50 10.0 p90 18.0 max 20.0 min, slowest/est p50 1.20 max 1.50, cap-cancelled shards 0 in 0 runs" ] \
  && ok || bad "K8: the conc 3 bucket: '$(line 'conc 3:')'"
[ "$(line 'conc 1:')" = "conc 1: runs 1, shard wall p50 1.0 p90 1.0 max 1.0 min, slowest/est p50 - max -, cap-cancelled shards 0 in 0 runs" ] \
  && ok || bad "K8: the conc 1 bucket: '$(line 'conc 1:')'"

# ── K1. The TSV shape and the summary order (on the K8 run).
[ "$(head -1 "$T/k8.tsv")" = "$(printf 'run_id\tdraft\tstarted_at\tconc\tshards\tslowest_wall_min\tmean_wall_min\tcap_cancelled\tplan_n\tplan_est_min\tcap_reached\twall_over_est\tnote')" ] \
  && ok || bad "K1: the header row: '$(head -1 "$T/k8.tsv")'"
nf=$(awk -F'\t' '{ print NF }' "$T/k8.tsv" "$T/k7.tsv" "$T/k5.tsv" | sort -u)
[ "$nf" = 13 ] && ok || bad "K1: every row has the header's 13 fields, got '$nf'"
[ "$(printf '%s\n' "$OUT" | grep -c '^conc ')" = 2 ] && ok || bad "K1: one conc line per bucket (2): $OUT"
order=$(printf '%s\n' "$OUT" | cut -c1-6 | tr '\n' '|')
[ "$order" = "note: |conc 1|conc 3|cap: 4|runs: |" ] && ok || bad "K1: summary order note, conc ascending, cap, runs: '$order'"
sc --from-dir "$X" --workflow-file "$T/wf45.yml"
[ "$(head -1 <<<"$OUT" | cut -f1)" = run_id ] && has "runs: 4 read" "$OUT" && ok || bad "K1: no --out puts TSV then summary on stdout: $OUT"

# ── K9. Bad arguments.
sc --last x --workflow-file "$T/wf45.yml"; [ "$RC" = 2 ] && ok || bad "K9: --last x is rc 2, got $RC"
sc --bogus; [ "$RC" = 2 ] && ok || bad "K9: an unknown argument is rc 2, got $RC"

# ── K10. The live read path through a stub gh on PATH.
G="$T/k10"; mkdir -p "$G/bin"; cp "$T/k6/runs-1.json" "$T/k6/runs-2.json" "$T/k6/"jobs-*.json "$G/"
printf '%s\n' "$PLANLINE" > "$G/log-10100.txt"
cat > "$G/bin/gh" <<EOF
#!/bin/bash
# a stub of \`gh api <path>\` over fixture files; anything else is refused
[ "\$1" = api ] || exit 9
p="\$2"; echo "\$p" >> "$G/asked"
case "\$p" in
  repos/o/r/actions/workflows/harness-ci.yml/runs\?per_page=100\&page=[0-9]) cat "$G/runs-\${p##*page=}.json" 2>/dev/null || exit 1 ;;
  repos/o/r/actions/runs/*/jobs\?per_page=100) i="\${p#*actions/runs/}"; cat "$G/jobs-\${i%%/*}.json" 2>/dev/null || exit 1 ;;
  repos/o/r/actions/jobs/*/logs) i="\${p#*actions/jobs/}"; cat "$G/log-\${i%%/*}.txt" 2>/dev/null || exit 1 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$G/bin/gh"
OUT=$(PATH="$G/bin:$PATH" SHARD_CONC_GH="$G/bin/gh" bash "$CLI" --repo o/r --last 4 --workflow-file "$T/wf45.yml" --out "$T/k10.tsv" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "K10: rc 0 through the stub, got $RC: $OUT"
ids=$(awk -F'\t' 'NR > 1 { printf "%s ", $1 }' "$T/k10.tsv")
[ "$ids" = "101 103 201 202 " ] && ok || bad "K10: the same four runs as K6, got '$ids'"
grep -qx 'repos/o/r/actions/workflows/harness-ci.yml/runs?per_page=100&page=2' "$G/asked" \
  && ! grep -q 'page=3' "$G/asked" && ok || bad "K10: page 2 is asked, page 3 is not: $(cat "$G/asked")"
grep -qx 'repos/o/r/actions/runs/202/jobs?per_page=100' "$G/asked" && ok || bad "K10: the jobs path per run: $(cat "$G/asked")"
grep -qx 'repos/o/r/actions/jobs/10100/logs' "$G/asked" && [ "$(col 101 plan_n "$T/k10.tsv")" = 12 ] \
  && [ "$(col 103 note "$T/k10.tsv")" = "plan log unreadable" ] && ok || bad "K10: the plan log path by job id: $(cat "$T/k10.tsv")"
OUT=$(SHARD_CONC_GH="$T/no-such-gh" bash "$CLI" --repo o/r --workflow-file "$T/wf45.yml" 2>&1); RC=$?
[ "$RC" = 3 ] && has "runs: 0 read" "$OUT" && ok || bad "K10: an unreadable run list is rc 3 with 'runs: 0 read', got $RC: $OUT"

# ── K11. Page 2 cannot be read: the page-1 rows stay, the run says so, rc 3.
mv "$G/runs-2.json" "$G/runs-2.off"
OUT=$(PATH="$G/bin:$PATH" SHARD_CONC_GH="$G/bin/gh" bash "$CLI" --repo o/r --last 4 --workflow-file "$T/wf45.yml" --out "$T/k11.tsv" 2>&1); RC=$?
[ "$RC" = 3 ] && ok || bad "K11: a failed page 2 is rc 3, got $RC: $OUT"
ids=$(awk -F'\t' 'NR > 1 { printf "%s ", $1 }' "$T/k11.tsv")
[ "$ids" = "101 103 " ] && ok || bad "K11: the page-1 runs are still rows, got '$ids'"
has "the run list page 2 could not be read" "$OUT" && has "runs: 2 read, 0 unreadable" "$OUT" && ok \
  || bad "K11: the output names the failed page and the real count: $OUT"

echo "ci-shard-concurrency (BH-7620): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
