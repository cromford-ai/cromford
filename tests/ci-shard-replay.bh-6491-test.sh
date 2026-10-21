#!/bin/bash
# tests/ci-shard-replay.bh-6491-test.sh — bin/ci-shard-replay.sh replays the
# time sizing of bin/ci-plan.sh (BH-6876) over recent merge-queue batches
# (BH-6491).
#
# A stub gh (CI_SHARD_REPLAY_GH) serves fixture JSON and zips per API path.
# No network, no clock, no box env.
#
#   R1  3 runs: 9001 batch-selected with a ledger and 4 suite-timings zips,
#       9002 selected with no ci-durations artifact, 9003 full. Two rows; the
#       predicted max of 9001 is suite_shard_size over <suites> with the
#       budget (600 s) and cap (8) of its sizing notice; the actual max and the
#       runner minutes come from the fixture times; `no-ledger fallback 1 of
#       2`, `sizing=time 1 of 2`; the fewer-runs-than-asked line
#   R2  a notice with budget 300s -> suite_shard_size 300's value; --target 900
#       overrides it; --max 2 caps it; a notice with no budget -> the knob
#       CI_SHARD_BUDGET_S, else 480; a `# source: seed` file is no ledger
#   R3  gh answers a rate limit -> rc 75, no `replay:` line
#   R4  HTTP 500 on run 9002's jobs -> rc 1, the message names 9002, no summary
#   R5  a timings zip with `../evil.tsv` and `x/../../y.tsv`: only safe
#       members are read, nothing is written outside, the result is unchanged
#   R6  a bad argument -> rc 2
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
REPLAY="$DIR/bin/ci-shard-replay.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
# shellcheck source=../bin/lib/suite-runner.sh
. "$DIR/bin/lib/suite-runner.sh" || exit 1

REPO=example-org/cromford
mkdir -p "$T/fix" "$T/work"

# The stub: `api <path>` -> the fixture file named by the path.
cat > "$T/gh" <<'STUB'
#!/bin/bash
[ "$1" = api ] || { echo "stub: only api" >&2; exit 2; }
if [ -n "${STUB_RATE:-}" ]; then echo "gh: API rate limit exceeded for user ID 0000000. (HTTP 403)" >&2; exit 1; fi
if [ -n "${STUB_FAIL:-}" ] && case "$2" in *"$STUB_FAIL"*) true ;; *) false ;; esac; then
  echo "gh: Server Error (HTTP 500)" >&2; exit 1
fi
f="$STUB_FIX/$(printf '%s' "$2" | tr -c 'A-Za-z0-9' '_')"
[ -f "$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
cat "$f"
STUB
chmod +x "$T/gh"
fx() { printf '%s/%s' "$T/fix" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"; }

# ── fixtures: the run list (two decoys that must not count)
cat > "$(fx "repos/$REPO/actions/workflows/harness-ci.yml/runs?status=completed&per_page=100&page=1")" <<'JSON'
{"total_count":5,"workflow_runs":[
 {"id":9003,"name":"Harness CI","status":"completed","conclusion":"success","head_branch":"mergify/merge-queue/c3","created_at":"2026-10-12T09:00:00Z"},
 {"id":9100,"name":"Harness CI","status":"completed","conclusion":"success","head_branch":"ticket/bh-0001","created_at":"2026-10-12T08:30:00Z"},
 {"id":9002,"name":"Harness CI","status":"completed","conclusion":"failure","head_branch":"mergify/merge-queue/c2","created_at":"2026-10-12T08:00:00Z"},
 {"id":9200,"name":"Other","status":"completed","conclusion":"success","head_branch":"mergify/merge-queue/zz","created_at":"2026-10-12T07:30:00Z"},
 {"id":9001,"name":"Harness CI","status":"completed","conclusion":"success","head_branch":"mergify/merge-queue/c1","created_at":"2026-10-12T07:00:00Z"}
]}
JSON
# 9001: plan 90 s (2), shard0 630 s (11), shard1 360 s (6), decisions 20 s (1), one never started -> 20 min; max 10.5
cat > "$(fx "repos/$REPO/actions/runs/9001/jobs?per_page=100&page=1")" <<'JSON'
{"total_count":5,"jobs":[
 {"id":7101,"name":"CI plan","started_at":"2026-10-12T07:00:00Z","completed_at":"2026-10-12T07:01:30Z"},
 {"id":7111,"name":"Tests, traced (shard 0/2)","started_at":"2026-10-12T07:02:00Z","completed_at":"2026-10-12T07:12:30Z"},
 {"id":7112,"name":"Tests, traced (shard 1/2)","started_at":"2026-10-12T07:02:00Z","completed_at":"2026-10-12T07:08:00Z"},
 {"id":7113,"name":"decisions","started_at":"2026-10-12T07:13:00Z","completed_at":"2026-10-12T07:13:20Z"},
 {"id":7114,"name":"skipped lane","started_at":null,"completed_at":null}
]}
JSON
# 9002: plan 60 s (1), shard0 300 s (5), shard1 125 s (3) -> 9 min; max 5.0
cat > "$(fx "repos/$REPO/actions/runs/9002/jobs?per_page=100&page=1")" <<'JSON'
{"total_count":3,"jobs":[
 {"id":7201,"name":"CI plan","started_at":"2026-10-12T08:00:00Z","completed_at":"2026-10-12T08:01:00Z"},
 {"id":7211,"name":"Tests, traced (shard 0/2)","started_at":"2026-10-12T08:02:00Z","completed_at":"2026-10-12T08:07:00Z"},
 {"id":7212,"name":"Tests, traced (shard 1/2)","started_at":"2026-10-12T08:02:00Z","completed_at":"2026-10-12T08:04:05Z"}
]}
JSON
cat > "$(fx "repos/$REPO/actions/runs/9003/jobs?per_page=100&page=1")" <<'JSON'
{"total_count":1,"jobs":[
 {"id":7301,"name":"CI plan","started_at":"2026-10-12T09:00:00Z","completed_at":"2026-10-12T09:01:00Z"}
]}
JSON
cat > "$(fx "repos/$REPO/check-runs/7101/annotations?per_page=100")" <<'JSON'
[{"title":"ci-plan","message":"mode=batch-selected count=6 total=980 n=2 reason=batch: impact"},
 {"title":"ci-plan sizing","message":"sizing: time (api), 2 shard(s), slowest est 650s of budget 600s, cap 8"}]
JSON
cat > "$(fx "repos/$REPO/check-runs/7201/annotations?per_page=100")" <<'JSON'
[{"title":"ci-plan","message":"mode=selected count=6 total=980 n=2 reason=selected: impact"},
 {"title":"ci-plan sizing","message":"sizing: count, ceil(6/120) cap 8 (durations file unreadable)"}]
JSON
cat > "$(fx "repos/$REPO/check-runs/7301/annotations?per_page=100")" <<'JSON'
[{"title":"ci-plan","message":"mode=full count=980 total=980 n=8 reason=full: label"}]
JSON
cat > "$(fx "repos/$REPO/actions/runs/9001/artifacts?per_page=100")" <<'JSON'
{"total_count":6,"artifacts":[
 {"id":501,"name":"ci-durations","expired":false},
 {"id":511,"name":"suite-timings-0","expired":false},
 {"id":512,"name":"suite-timings-1","expired":false},
 {"id":513,"name":"suite-timings-2","expired":false},
 {"id":514,"name":"suite-timings-3","expired":false},
 {"id":515,"name":"verdict-0","expired":false}
]}
JSON
cat > "$(fx "repos/$REPO/actions/runs/9002/artifacts?per_page=100")" <<'JSON'
{"total_count":1,"artifacts":[{"id":521,"name":"suite-timings-0","expired":false}]}
JSON
echo '{"total_count":0,"artifacts":[]}' > "$(fx "repos/$REPO/actions/runs/9003/artifacts?per_page=100")"

# zips: mkzip <out> <member> <content file> [<member> <content file> ...]
mkzip() {
  python3 -I -c '
import sys, zipfile
out = sys.argv[1]; a = sys.argv[2:]
with zipfile.ZipFile(out, "w") as z:
    for i in range(0, len(a), 2):
        with open(a[i + 1], "rb") as f:
            z.writestr(zipfile.ZipInfo(a[i], (2026, 1, 1, 0, 0, 0)), f.read())
' "$@"
}
mkdur() { # mkdur <source> -> $T/dur.tsv
  { echo "# source: $1"
    echo "# ci-suite-durations.tsv from the jobs worker's ci_suite_durations (BH-5653); <suite>\t<seconds>\t<run>"
    printf 'tests/a-test.sh\t400\t7001\t400,390,410\n'
    printf 'tests/b-test.sh\t300\t7001\t300\n'
    printf 'tests/c-test.sh\t250.5\t7001\t250.5\n'
    printf 'tests/d-test.sh\t200\t7001\n'
    printf 'tests/e-test.sh\t100\t7001\n'
    printf 'tests/huge-test.sh\t2000\t7001\n'; } > "$T/dur.tsv"
  mkzip "$(fx "repos/$REPO/actions/artifacts/501/zip")" ci-durations.tsv "$T/dur.tsv"
}
mkdur api
printf 'tests/a-test.sh\t401.2\t0\ntests/b-test.sh\t299.0\t0\n' > "$T/s0"
printf 'tests/c-test.sh\t250.1\t1\n' > "$T/s1"
printf 'tests/d-test.sh\t198.0\t0\ntests/e-test.sh\t99.0\t0\n' > "$T/s2"
printf 'tests/f-test.sh\t50.0\t0\ntests/a-test.sh\t1.0\t0\n' > "$T/s3"
printf 'tests/huge-test.sh\t2000\t0\n' > "$T/evil"
mkzip "$(fx "repos/$REPO/actions/artifacts/511/zip")" shard-0.tsv "$T/s0"
mkzip "$(fx "repos/$REPO/actions/artifacts/512/zip")" shard-1.tsv "$T/s1"
mkzip "$(fx "repos/$REPO/actions/artifacts/513/zip")" shard-2.tsv "$T/s2"
mkzip "$(fx "repos/$REPO/actions/artifacts/514/zip")" shard-3.tsv "$T/s3"
mkzip "$(fx "repos/$REPO/actions/artifacts/521/zip")" shard-0.tsv "$T/s0"
SUITES=(tests/a-test.sh tests/b-test.sh tests/c-test.sh tests/d-test.sh tests/e-test.sh tests/f-test.sh)
expect() { # expect <budget s> [cap] -> "<n> <max min>"
  SUITE_DURATIONS_FILE="$T/dur.tsv" suite_shard_size "$(($1 * 1000))" "${2:-8}" "${SUITES[@]}" | awk -F'\t' '{ printf "%s %.1f", $1, $2 / 60000 }'
}
ann() { # ann <budget text> — the 9001 plan annotations
  printf '[{"title":"ci-plan","message":"mode=batch-selected count=6 total=980 n=2 reason=batch: impact"},\n {"title":"ci-plan sizing","message":"%s"}]\n' "$1" \
    > "$(fx "repos/$REPO/check-runs/7101/annotations?per_page=100")"
}

# run [args...] — sets RC OUT ERR; cwd is $T/work
run() {
  OUT=$(cd "$T/work" && env -u CI_REPO -u GH_TOKEN -u GITHUB_TOKEN -u CI_SHARD_BUDGET_S -u CI_MAX_SHARDS ${RUN_ENV:-} CI_SHARD_REPLAY_GH="$T/gh" STUB_FIX="$T/fix" \
          "$REPLAY" "$@" 2>"$T/err"); RC=$?
  ERR=$(cat "$T/err")
}
row() { printf '%s\n' "$OUT" | awk -F'\t' -v id="$1" '$1 == id'; }
col() { row "$1" | cut -f"$2"; }

# ── R1. the whole read
read -r EN EM <<< "$(expect 600)"
run
{ [ "$RC" = 0 ] && [ "$(printf '%s\n' "$OUT" | grep -c '^90[0-9][0-9]	')" = 2 ] && [ -z "$(row 9003)" ]; } && ok \
  || bad "R1: rc 0 and two rows, none for 9003 (rc=$RC) [$OUT] [$ERR]"
[ "$(row 9001)" = "9001	batch-selected	time	2	10.5	$EN	$EM	20	yes" ] && ok \
  || bad "R1: 9001 row, predicted $EN/$EM from suite_shard_size 600 s cap 8 [$(row 9001)]"
[ "$(row 9002)" = "9002	selected	count	2	5.0	-	-	9	no" ] && ok || bad "R1: 9002 row [$(row 9002)]"
has "replay: 2 batches; actual max shard mean 7.8 min; predicted max mean $EM min; no-ledger fallback 1 of 2; runner min per batch mean 14.5; sizing=time 1 of 2" "$OUT" && ok \
  || bad "R1: summary line [$OUT]"
has "replay: read 3 runs (2 selected-mode) in the window" "$OUT" && has "replay: --last 30 asked for 30 runs, found 3" "$OUT" && ok \
  || bad "R1: window lines [$OUT]"
[ "${OUT%%$'\n'*}" = $'run_id	mode	sizing	shards	actual_max_min	predicted_n	predicted_max_min	runner_min\tledger' ] && ok \
  || bad "R1: header line [$OUT]"
BASE="$OUT"
run --last 2
{ [ "$RC" = 0 ] && has "replay: read 2 runs (1 selected-mode)" "$OUT" && ! has "asked for" "$OUT" && [ -z "$(row 9001)" ]; } && ok \
  || bad "R1: --last 2 stops after two matching runs [$OUT]"
run --since 2026-10-12T07:30:00Z
{ [ "$RC" = 0 ] && has "replay: read 2 runs" "$OUT" && [ -z "$(row 9001)" ]; } && ok || bad "R1: --since stops at older runs [$OUT]"

# ── R2. the budget and cap: the notice's, --target/--max over it, the knob without it
ann "sizing: time (api), 3 shard(s), slowest est 300s of budget 300s, cap 8"
read -r E3N E3M <<< "$(expect 300)"
read -r E9N E9M <<< "$(expect 900)"
read -r E4N E4M <<< "$(expect 480)"
read -r E2N E2M <<< "$(expect 300 2)"
{ [ "$E3N $E3M" != "$EN $EM" ] && [ "$E9N $E9M" != "$EN $EM" ] && [ "$E4N $E4M" != "$EN $EM" ] && [ "$E2N" = 2 ]; } && ok \
  || bad "R2: the fixture must tell budgets apart ($EN $EM / $E3N $E3M / $E9N $E9M / $E4N $E4M / $E2N $E2M)"
run
[ "$(col 9001 6) $(col 9001 7)" = "$E3N $E3M" ] && ok || bad "R2: the notice's budget 300s gives $E3N $E3M [$(row 9001)]"
run --target 900
[ "$(col 9001 6) $(col 9001 7)" = "$E9N $E9M" ] && ok || bad "R2: --target 900 gives $E9N $E9M [$(row 9001)]"
run --max 2
[ "$(col 9001 6) $(col 9001 7)" = "$E2N $E2M" ] && ok || bad "R2: --max 2 gives $E2N $E2M [$(row 9001)]"
ann "mode note without a budget"
run
{ [ "$(col 9001 3)" = - ] && [ "$(col 9001 6) $(col 9001 7)" = "$E4N $E4M" ]; } && ok || bad "R2: no budget in the notice is 480 s [$(row 9001)]"
RUN_ENV="CI_SHARD_BUDGET_S=900" run
[ "$(col 9001 6) $(col 9001 7)" = "$E9N $E9M" ] && ok || bad "R2: the knob CI_SHARD_BUDGET_S=900 gives $E9N $E9M [$(row 9001)]"
ann "sizing: time (api), 2 shard(s), slowest est 650s of budget 600s, cap 8"
mkdur "seed 0123456789abcdef"
run
[ "$(col 9001 7) $(col 9001 9)" = "- no" ] && ok || bad "R2: a seed file is a no-ledger fallback [$(row 9001)]"
mkdur api

# ── R3. a rate limit
STUB_RATE=1 run
{ [ "$RC" = 75 ] && ! has "replay:" "$OUT"; } && ok || bad "R3: rc 75 and no summary (rc=$RC) [$OUT] [$ERR]"

# ── R4. a server error on 9002's jobs
STUB_FAIL="runs/9002/jobs" run
{ [ "$RC" = 1 ] && has "run 9002" "$ERR" && ! has "replay:" "$OUT"; } && ok || bad "R4: rc 1 naming 9002, no summary (rc=$RC) [$OUT] [$ERR]"

# ── R5. unsafe member names
mkzip "$(fx "repos/$REPO/actions/artifacts/514/zip")" shard-3.tsv "$T/s3" ../evil.tsv "$T/evil" x/../../y.tsv "$T/evil"
run
{ [ "$RC" = 0 ] && [ "$OUT" = "$BASE" ]; } && ok || bad "R5: unsafe members change nothing (rc=$RC) [$OUT] [$ERR]"
UP=$(dirname "$T")
{ [ -z "$(find "$UP" "$T/work" "$DIR/bin" -maxdepth 2 \( -name evil.tsv -o -name y.tsv \) 2>/dev/null)" ]; } && ok \
  || bad "R5: a member path reached the disk"

# ── R6. bad arguments
run --frobnicate; [ "$RC" = 2 ] && ok || bad "R6: unknown arg rc 2 (rc=$RC)"
run --last zero; [ "$RC" = 2 ] && ok || bad "R6: --last zero rc 2 (rc=$RC)"
run --target -5; [ "$RC" = 2 ] && ok || bad "R6: --target -5 rc 2 (rc=$RC)"

echo "ci-shard-replay: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
