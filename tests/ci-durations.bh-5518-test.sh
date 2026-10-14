#!/bin/bash
# tests/ci-durations.bh-5518-test.sh — BH-5518 C1: catalog/ci-suite-durations.tsv
# leaves git, and CI composes the shard weights from its own runs.
#
# Every PR that added an always-run suite had to add a row to one committed
# file, so two such PRs conflicted on it, and a PR that forgot the row turned
# every merge-queue batch red (fast-lints-data D1). The file is now a chain of
# CI artifacts: the tracer times each suite (--timings), bin/ci-durations.sh
# merge folds those timings into the last green batch's file, and
# bin/ci-durations.sh fetch reads the newest one back (seed from git history,
# then header-only, when there is none). docs/ci-durations.md has the design.
#
#   CD-1  bin/test-trace-safety.sh --gate --timings F: one row per suite,
#         `tests/<name>\t<n.n>\t<rc>`, a failing suite carries its rc
#   CD-2  fetch: one green batch run + its ci-durations-next zip -> --out is
#         `# source: artifact run <id>` + the zip member, rc 0
#   CD-3  fetch never picks a red batch, a `full` PR, a push, another
#         workflow, an expired artifact or another artifact name
#   CD-4  merge is a pure function: same bytes twice, input order does not
#         matter, a value change shows, 3 newest values kept, seconds = their
#         median, unmeasured rows kept byte for byte, deleted suites dropped,
#         rc != 0 rows ignored
#   CD-5  a hostile zip: only the member `ci-durations.tsv` is read, nothing
#         lands outside --out, a non-numeric row falls back to the seed
#   CD-6  gh rc 75 / no gh / no artifact -> the seed from history; no seed ->
#         header-only + one ::warning::, and the split is round-robin
#   CD-7  the workflow wiring (plan, tests-shard, decisions, lint)
#   CD-8  the file is not tracked, and it is git-ignored
#   CD-9  two branches that each add an always-suite merge clean in either
#         order, and the merged tree's fast-lints-data is green
#   CD-10 no durations file -> fast-lints-data SKIPs D1-D4 (rc 0); a readable
#         file with a missing row (FAST_LINTS_DURATIONS) WARNs (rc 0, BH-5292),
#         and a malformed row is still red (D0)
#
# Self-contained: stub gh, scratch git repos, no network, no clock, no dice.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR="$(cd "$(dirname "$0")/.." && pwd)"
CD="$DIR/bin/ci-durations.sh"
TRACER="$DIR/bin/test-trace-safety.sh"
WF="$DIR/.github/workflows/harness-ci.yml"
FLD="$DIR/tests/fast-lints-data.bh-3860-test.sh"
PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
unset SUITE_DURATIONS_FILE FAST_LINTS_DURATIONS FLD_DURATIONS FLD_ROOT
TAB=$'\t'

# A scratch git repo whose history commits a durations file and then deletes
# it: the shape main has after this PR. SEED is the copy fetch must recover.
git_q() { git -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false "$@"; }
SEEDREPO="$T/seedrepo"
mkdir -p "$SEEDREPO/catalog"
git_q init -q "$SEEDREPO"
printf '# seed header\ntests/a-test.sh\t2.0\tr0\ntests/b-test.sh\t5.0\tr0\n' > "$SEEDREPO/catalog/ci-suite-durations.tsv"
cp "$SEEDREPO/catalog/ci-suite-durations.tsv" "$T/seed.tsv"
git_q -C "$SEEDREPO" add -A && git_q -C "$SEEDREPO" commit -qm seed
printf 'x\n' > "$SEEDREPO/other" && git_q -C "$SEEDREPO" add -A && git_q -C "$SEEDREPO" commit -qm other
git_q -C "$SEEDREPO" rm -q catalog/ci-suite-durations.tsv && git_q -C "$SEEDREPO" commit -qm drop
SEEDSHA=$(git -C "$SEEDREPO" log -1 --format=%H --diff-filter=D -- catalog/ci-suite-durations.tsv)
NOSEED="$T/noseed"
git_q init -q "$NOSEED" && printf 'x\n' > "$NOSEED/f" && git_q -C "$NOSEED" add -A && git_q -C "$NOSEED" commit -qm one

# Stub gh: `gh api <path>`. runs / artifacts answer the fixture JSON, a zip
# answers zip-<id>.zip. GH_STUB_RC forces an exit code (75 = rate limited).
GHFX="$T/ghfx"; mkdir -p "$GHFX" "$T/stubbin"
cat > "$T/stubbin/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "$GHFX/calls"
[ -z "${GH_STUB_RC:-}" ] || exit "$GH_STUB_RC"
[ "$1" = api ] || exit 2
case "$2" in
  repos/o/r/actions/runs\?*)      cat "$GHFX/runs.json" ;;
  repos/o/r/actions/artifacts\?*) cat "$GHFX/artifacts.json" ;;
  repos/o/r/actions/artifacts/*/zip)
    id=${2#repos/o/r/actions/artifacts/}; id=${id%/zip}
    [ -f "$GHFX/zip-$id.zip" ] || { echo "HTTP 404" >&2; exit 1; }
    cat "$GHFX/zip-$id.zip" ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$T/stubbin/gh"
export GHFX
mkzip() { # <out.zip> <member-name> <content-file> [<member-name> <content-file>]...
  python3 -I - "$@" <<'PY'
import sys, zipfile
out = sys.argv[1]; a = sys.argv[2:]
with zipfile.ZipFile(out, "w") as z:
    for i in range(0, len(a), 2):
        z.writestr(a[i], open(a[i + 1], "rb").read())
PY
}
run() { printf '{"id":%s,"name":"%s","event":"%s","status":"completed","conclusion":"%s","head_branch":"%s"}' "$@"; }
art() { printf '{"id":%s,"name":"%s","expired":%s,"created_at":"%s","workflow_run":{"id":%s}}' "$@"; }
fetch() { # <out> [env...]
  local out="$1"; shift
  env CI_DURATIONS_GH="$T/stubbin/gh" CI_REPO=o/r CI_WORKFLOW="Harness CI" "$@" \
    "$CD" fetch --root "$SEEDREPO" --out "$out"
}

echo "CD-1: the tracer writes one timing row per suite"
mkdir -p "$T/fx/tests" "$T/cd1"
printf '#!/bin/bash\nexit 0\n' > "$T/fx/tests/pass-test.sh"
printf '#!/bin/bash\nexit 1\n' > "$T/fx/tests/fail-test.sh"
TF="$T/cd1/new/shard-0.tsv"
HARNESS_TEST_SANDBOX=1 "$TRACER" --gate --timings "$TF" "$T/fx" > "$T/cd1/out" 2>&1; rc=$?
[ "$rc" = 1 ] && ok "CD-1 --gate rc 1 on the failing suite" || bad "CD-1 rc=$rc $(cat "$T/cd1/out")"
[ -f "$TF" ] && [ "$(grep -c . "$TF")" = 2 ] && ok "CD-1 two rows" || bad "CD-1 timings: $(cat "$TF" 2>&1)"
grep -qE "^tests/pass-test\.sh${TAB}[0-9]+\.[0-9]${TAB}0\$" "$TF" 2>/dev/null && ok "CD-1 pass row" || bad "CD-1 no pass row"
grep -qE "^tests/fail-test\.sh${TAB}[0-9]+\.[0-9]${TAB}1\$" "$TF" 2>/dev/null && ok "CD-1 fail row has rc 1" || bad "CD-1 no fail row"
grep -qE '^--- tests/pass-test\.sh rc=0 [0-9]+s$' "$T/cd1/out" && ok "CD-1 the --- line is unchanged" || bad "CD-1 --- line changed"
# a re-run starts the file empty
HARNESS_TEST_SANDBOX=1 "$TRACER" --gate --timings "$TF" "$T/fx" > /dev/null 2>&1
[ "$(grep -c . "$TF")" = 2 ] && ok "CD-1 a re-run does not append" || bad "CD-1 re-run left $(grep -c . "$TF") rows"
HARNESS_TEST_SANDBOX=1 "$TRACER" --timings "$TF" "$T/fx" > /dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "CD-1 --timings without --gate is refused" || bad "CD-1 --timings without --gate rc=$rc"

echo "CD-2: fetch reads the newest green batch's artifact"
printf '# composed\ntests/a-test.sh\t3.0\t101\t3.0\n' > "$T/m101.tsv"
mkzip "$GHFX/zip-9001.zip" ci-durations.tsv "$T/m101.tsv"
printf '{"workflow_runs":[%s]}' "$(run 101 "Harness CI" pull_request success mergify/merge-queue/main/x)" > "$GHFX/runs.json"
printf '{"artifacts":[%s]}' "$(art 9001 ci-durations-next false 2026-10-08T10:00:00Z 101)" > "$GHFX/artifacts.json"
: > "$GHFX/calls"
fetch "$T/cd2.tsv" > "$T/cd2.log" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "CD-2 rc 0" || bad "CD-2 rc=$rc $(cat "$T/cd2.log")"
[ "$(head -1 "$T/cd2.tsv" 2>/dev/null)" = "# source: artifact run 101" ] && ok "CD-2 header names the run" || bad "CD-2 head: $(head -1 "$T/cd2.tsv" 2>&1)"
tail -n +2 "$T/cd2.tsv" 2>/dev/null | cmp -s - "$T/m101.tsv" && ok "CD-2 body equals the zip member" || bad "CD-2 body differs"
[ "$(grep -c . "$GHFX/calls")" = 3 ] && ok "CD-2 three API calls" || bad "CD-2 calls: $(cat "$GHFX/calls")"
grep -q '::warning::' "$T/cd2.log" && bad "CD-2 a warning on the happy path" || ok "CD-2 no warning"

echo "CD-3: fetch picks only a green merge-queue batch of this workflow"
printf '# good\ntests/a-test.sh\t1.0\t101\t1.0\n' > "$T/good.tsv"
printf '# bad\ntests/a-test.sh\t99.0\tx\t99.0\n' > "$T/badpick.tsv"
mkzip "$GHFX/zip-9001.zip" ci-durations.tsv "$T/good.tsv"
for id in 9102 9103 9104 9105 9106 9107; do mkzip "$GHFX/zip-$id.zip" ci-durations.tsv "$T/badpick.tsv"; done
printf '{"workflow_runs":[%s,%s,%s,%s,%s,%s]}' \
  "$(run 102 "Harness CI" pull_request failure mergify/merge-queue/main/r)" \
  "$(run 103 "Harness CI" pull_request success ticket/bh-1-full)" \
  "$(run 104 "Harness CI" push success main)" \
  "$(run 105 "Other CI" pull_request success mergify/merge-queue/main/o)" \
  "$(run 106 "Harness CI" pull_request success mergify/merge-queue/main/e)" \
  "$(run 101 "Harness CI" pull_request success mergify/merge-queue/main/x)" > "$GHFX/runs.json"
printf '{"artifacts":[%s,%s,%s,%s,%s,%s,%s]}' \
  "$(art 9107 ci-durations false 2026-10-08T16:00:00Z 101)" \
  "$(art 9106 ci-durations-next true 2026-10-08T15:00:00Z 106)" \
  "$(art 9105 ci-durations-next false 2026-10-08T14:00:00Z 105)" \
  "$(art 9104 ci-durations-next false 2026-10-08T13:00:00Z 104)" \
  "$(art 9103 ci-durations-next false 2026-10-08T12:00:00Z 103)" \
  "$(art 9102 ci-durations-next false 2026-10-08T11:00:00Z 102)" \
  "$(art 9001 ci-durations-next false 2026-10-08T10:00:00Z 101)" > "$GHFX/artifacts.json"
: > "$GHFX/calls"
fetch "$T/cd3.tsv" > "$T/cd3.log" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(head -1 "$T/cd3.tsv")" = "# source: artifact run 101" ] && ok "CD-3 picked run 101" || bad "CD-3 rc=$rc head=$(head -1 "$T/cd3.tsv" 2>&1)"
tail -n +2 "$T/cd3.tsv" | cmp -s - "$T/good.tsv" && ok "CD-3 body is the valid artifact" || bad "CD-3 body: $(cat "$T/cd3.tsv")"
grep -qE 'artifacts/(9102|9103|9104|9105|9106|9107)/zip' "$GHFX/calls" && bad "CD-3 downloaded a rejected artifact: $(cat "$GHFX/calls")" || ok "CD-3 no rejected artifact downloaded"

echo "CD-4: merge is a pure function of its inputs"
M="$T/cd4"; mkdir -p "$M/root/tests" "$M/t1" "$M/t2"
for s in a b c keep new; do : > "$M/root/tests/$s-test.sh"; done
printf '# source: seed abc\ntests/a-test.sh\t2.0\tr0\t2.0\ntests/b-test.sh\t5.0\tr0\ntests/c-test.sh\t5.0\tr0\t5.0,2.0,9.0\ntests/gone-test.sh\t1.0\tr0\t1.0\ntests/keep-test.sh\t7.5\tr0\t7.5,7.0\n' > "$M/prev.tsv"
printf 'tests/a-test.sh\t4.0\t0\ntests/c-test.sh\t1.0\t0\n' > "$M/t1/shard-0.tsv"
printf 'tests/b-test.sh\t9.0\t1\ntests/new-test.sh\t6.0\t0\n' > "$M/t1/shard-1.tsv"
# the same rows, the files named so a glob reads them in the other order
cp "$M/t1/shard-1.tsv" "$M/t2/a.tsv"; cp "$M/t1/shard-0.tsv" "$M/t2/z.tsv"
mrg() { "$CD" merge --prev "$M/prev.tsv" --timings-dir "$1" --run 777 --root "$M/root" --out "$2"; }
mrg "$M/t1" "$M/o1" > "$M/log" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "CD-4 merge rc 0" || bad "CD-4 merge rc=$rc $(cat "$M/log")"
mrg "$M/t1" "$M/o2" > /dev/null 2>&1
cmp -s "$M/o1" "$M/o2" && ok "CD-4 two runs, same bytes" || bad "CD-4 two runs differ"
mrg "$M/t2" "$M/o3" > /dev/null 2>&1
cmp -s "$M/o1" "$M/o3" && ok "CD-4 file order does not matter" || bad "CD-4 file order changed the output"
want() { grep -qxF "$1" "$M/o1" && ok "CD-4 $2" || bad "CD-4 $2: want '$1' in: $(cat "$M/o1")"; }
want "tests/a-test.sh${TAB}3.0${TAB}777${TAB}4.0,2.0" "two values: the mean, new value first, this run id"
want "tests/b-test.sh${TAB}5.0${TAB}r0" "an rc != 0 row is ignored, the old row kept byte for byte"
want "tests/c-test.sh${TAB}2.0${TAB}777${TAB}1.0,5.0,2.0" "a 4th value keeps the 3 newest, seconds is their median"
want "tests/keep-test.sh${TAB}7.5${TAB}r0${TAB}7.5,7.0" "an unmeasured suite keeps its row"
want "tests/new-test.sh${TAB}6.0${TAB}777${TAB}6.0" "a new suite gets a row"
grep -q 'gone-test' "$M/o1" && bad "CD-4 a suite with no file under --root stays" || ok "CD-4 a deleted suite is dropped"
grep -v '^#' "$M/o1" | cut -f1 > "$M/keys"; LC_ALL=C sort "$M/keys" | cmp -s - "$M/keys" && ok "CD-4 rows are C-sorted" || bad "CD-4 rows not sorted"
grep -qF 'run 777' "$M/o1" && grep -qF 'seed abc' "$M/o1" && ok "CD-4 header names this run and the previous source" || bad "CD-4 header: $(grep '^#' "$M/o1")"
sed -i "s/^tests\/a-test.sh${TAB}4.0/tests\/a-test.sh${TAB}8.0/" "$M/t1/shard-0.tsv"
mrg "$M/t1" "$M/o4" > /dev/null 2>&1
cmp -s "$M/o1" "$M/o4" && bad "CD-4 a changed timing did not change the output" || ok "CD-4 a changed timing changes the output"

echo "CD-5: a hostile zip"
mkdir -p "$T/cd5/work"
printf 'pwned\n' > "$T/evil.txt"
mkzip "$GHFX/zip-9001.zip" ../evil.tsv "$T/evil.txt" ci-durations.tsv "$T/good.tsv" sub/../../evil2.tsv "$T/evil.txt"
printf '{"workflow_runs":[%s]}' "$(run 101 "Harness CI" pull_request success mergify/merge-queue/main/x)" > "$GHFX/runs.json"
printf '{"artifacts":[%s]}' "$(art 9001 ci-durations-next false 2026-10-08T10:00:00Z 101)" > "$GHFX/artifacts.json"
(cd "$T/cd5/work" && fetch "$T/cd5/work/out.tsv") > "$T/cd5/log" 2>&1; rc=$?
[ "$rc" = 0 ] && tail -n +2 "$T/cd5/work/out.tsv" | cmp -s - "$T/good.tsv" && ok "CD-5 only ci-durations.tsv is read" || bad "CD-5 rc=$rc out=$(cat "$T/cd5/work/out.tsv" 2>&1)"
[ -z "$(find "$T/cd5" "$T/seedrepo" -name '*evil*' 2>/dev/null)" ] && ok "CD-5 nothing written outside --out" || bad "CD-5 a member path reached the disk"
printf '# bad\ntests/a-test.sh\tNaN\t101\n' > "$T/nan.tsv"
mkzip "$GHFX/zip-9001.zip" ci-durations.tsv "$T/nan.tsv"
fetch "$T/cd5/nan-out.tsv" > "$T/cd5/nan.log" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(head -1 "$T/cd5/nan-out.tsv")" = "# source: seed $SEEDSHA" ] && ok "CD-5 a non-numeric row falls back to the seed" || bad "CD-5 rc=$rc head=$(head -1 "$T/cd5/nan-out.tsv" 2>&1)"
grep -q NaN "$T/cd5/nan-out.tsv" && bad "CD-5 the bad row reached --out" || ok "CD-5 the bad row is not in --out"

echo "CD-6: the fallbacks"
seed_ok() { # <out> <log> <label>
  [ "$(head -1 "$1" 2>/dev/null)" = "# source: seed $SEEDSHA" ] && tail -n +2 "$1" | cmp -s - "$T/seed.tsv" \
    && ok "CD-6 $3: the seed is the parent's copy" || bad "CD-6 $3: out=$(cat "$1" 2>&1)"
  [ "$(grep -c '::warning::' "$2")" = 1 ] && ok "CD-6 $3: one ::warning::" || bad "CD-6 $3: warnings: $(cat "$2")"
}
fetch "$T/cd6a.tsv" GH_STUB_RC=75 > "$T/cd6a.log" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "CD-6 gh rc 75: rc 0" || bad "CD-6 gh rc 75: rc=$rc"
seed_ok "$T/cd6a.tsv" "$T/cd6a.log" "gh rc 75"
env CI_DURATIONS_GH="$T/no-such-gh" CI_REPO=o/r "$CD" fetch --root "$SEEDREPO" --out "$T/cd6b.tsv" > "$T/cd6b.log" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "CD-6 no gh: rc 0" || bad "CD-6 no gh: rc=$rc"
seed_ok "$T/cd6b.tsv" "$T/cd6b.log" "no gh"
printf '{"artifacts":[]}' > "$GHFX/artifacts.json"
fetch "$T/cd6c.tsv" > "$T/cd6c.log" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "CD-6 no artifact: rc 0" || bad "CD-6 no artifact: rc=$rc"
seed_ok "$T/cd6c.tsv" "$T/cd6c.log" "no artifact"
env CI_DURATIONS_GH="$T/stubbin/gh" CI_REPO=o/r "$CD" fetch --root "$NOSEED" --out "$T/cd6d.tsv" > "$T/cd6d.log" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "CD-6 no seed: rc 0" || bad "CD-6 no seed: rc=$rc"
[ -f "$T/cd6d.tsv" ] && [ -z "$(grep -v '^#' "$T/cd6d.tsv")" ] && grep -qxF '# source: none' "$T/cd6d.tsv" \
  && ok "CD-6 no seed: a header-only file" || bad "CD-6 no seed: $(cat "$T/cd6d.tsv" 2>&1)"
[ "$(grep -c '::warning::' "$T/cd6d.log")" = 1 ] && ok "CD-6 no seed: one ::warning::" || bad "CD-6 no seed: $(cat "$T/cd6d.log")"
(
  # shellcheck source=../bin/lib/suite-runner.sh
  . "$DIR/bin/lib/suite-runner.sh" || exit 1
  SUITE_DURATIONS_FILE="$T/cd6d.tsv" suite_shard_plan 4 tests/a.sh tests/b.sh tests/c.sh tests/d.sh tests/e.sh tests/f.sh \
    | cut -f1,3 | LC_ALL=C sort -k2
) > "$T/cd6d.plan"
printf '0\ttests/a.sh\n1\ttests/b.sh\n2\ttests/c.sh\n3\ttests/d.sh\n0\ttests/e.sh\n1\ttests/f.sh\n' | cmp -s - "$T/cd6d.plan" \
  && ok "CD-6 no seed: the split is round-robin" || bad "CD-6 no seed plan: $(cat "$T/cd6d.plan")"

echo "CD-7: the workflow wiring"
job_block() { awk -v want="$1" '/^  [a-zA-Z0-9_-]+:/ { inblk = ($0 ~ "^  "want":[[:space:]]*$") } inblk { print }' "$WF"; }
# the one step (from its `      - ` line to the next) of a job block that has <fixed string>
step_of() { printf '%s\n' "$1" | awk -v pat="$2" '/^      - / { if (f) exit; buf = "" } { buf = buf $0 "\n" } index($0, pat) { f = 1 } END { if (f) printf "%s", buf }' ; }
has() { case "$1" in *"$2"*) ok "CD-7 $3" ;; *) bad "CD-7 $3: no '$2'" ;; esac; }
PLAN=$(job_block plan); SHARDJ=$(job_block tests-shard); DEC=$(job_block decisions); LINT=$(job_block lint)
S=$(step_of "$PLAN" 'bin/ci-durations.sh fetch')
has "$S" 'bin/ci-durations.sh fetch --out "$RUNNER_TEMP/ci-durations/ci-durations.tsv"' "plan fetches the file once"
has "$S" "if: steps.plan.outputs.corpus == '1'" "plan fetches only on a corpus run"
has "$S" 'GH_TOKEN: ${{ github.token }}' "plan fetch reads with the job token"
S=$(step_of "$PLAN" 'name: ci-durations')
has "$S" 'actions/upload-artifact@v4' "plan uploads ci-durations"
S=$(step_of "$SHARDJ" 'name: ci-durations')
has "$S" 'actions/download-artifact@v4' "tests-shard downloads ci-durations"
case "$S" in *continue-on-error*) bad "CD-7 the shard download must not continue on error" ;; *) [ -n "$S" ] && ok "CD-7 the shard download is hard" || bad "CD-7 no shard download step" ;; esac
has "$SHARDJ" 'no ci-durations from the plan job' "tests-shard guards a missing file"
S=$(step_of "$SHARDJ" 'bin/test-trace-safety.sh --gate')
grep -qxF '          SUITE_DURATIONS_FILE: ${{ runner.temp }}/ci-durations/ci-durations.tsv' <<<"$S" \
  && ok "CD-7 the traced step reads the plan's file" || bad "CD-7 the traced step has no SUITE_DURATIONS_FILE env line"
has "$S" '--timings "$RUNNER_TEMP/timings/shard-$SHARD.tsv"' "the traced step writes timings"
S=$(step_of "$SHARDJ" 'name: suite-timings-${{ matrix.shard }}')
has "$S" 'if: always()' "the timings upload runs always"
has "$S" 'actions/upload-artifact@v4' "tests-shard uploads suite-timings"
for p in 'pattern: suite-timings-*' 'bin/ci-durations.sh merge' 'name: ci-durations-next'; do
  S=$(step_of "$DEC" "$p")
  has "$S" 'continue-on-error: true' "decisions '$p' cannot turn the check red"
  has "$S" 'if: always()' "decisions '$p' runs always"
done
has "$(step_of "$DEC" 'name: ci-durations-next')" 'retention-days: 30' "ci-durations-next keeps 30 days"
has "$(step_of "$DEC" 'bin/ci-durations.sh merge')" '--run ${{ github.run_id }}' "merge names this run"
has "$(step_of "$LINT" 'bin/ci-durations.sh fetch')" "if: github.event_name == 'pull_request'" "lint fetches on a PR"
has "$(step_of "$LINT" 'name: fast always-lints (BH-3860)')" 'FAST_LINTS_DURATIONS: ${{ runner.temp }}/ci-durations.tsv' "fast-lints reads the fetched file"

echo "CD-8: the file is not committed"
[ -z "$(git -C "$DIR" ls-files catalog/ci-suite-durations.tsv)" ] && ok "CD-8 not tracked" || bad "CD-8 catalog/ci-suite-durations.tsv is tracked"
git -C "$DIR" check-ignore -q catalog/ci-suite-durations.tsv && ok "CD-8 git-ignored" || bad "CD-8 not git-ignored"

echo "CD-9: two PRs that each add an always-suite merge in either order"
CL="$T/clone"
git clone -q "$DIR" "$CL" 2>/dev/null || bad "CD-9 cannot clone $DIR"
git_q -C "$CL" checkout -q -b base
addsuite() { # <branch> <name>
  git_q -C "$CL" checkout -q -b "$1" base
  printf '#!/bin/bash\n# BH-5518 fixture: an always-run suite\ngit -C "$DIR" ls-files | wc -l\n' > "$CL/tests/$2"
  git_q -C "$CL" add "tests/$2" && git_q -C "$CL" commit -qm "add $2"
}
addsuite pa a.bh-x-test.sh; addsuite pb b.bh-y-test.sh
for order in "pa pb" "pb pa"; do
  set -- $order
  git_q -C "$CL" checkout -q -B "m-$1" base
  if git_q -C "$CL" merge -q --no-edit "$1" > /dev/null 2>&1 && git_q -C "$CL" merge -q --no-edit "$2" > /dev/null 2>&1; then
    ok "CD-9 $1 then $2 merges clean"
  else
    bad "CD-9 $1 then $2 conflicts: $(git -C "$CL" diff --name-only --diff-filter=U | tr '\n' ' ')"
    git -C "$CL" merge --abort 2>/dev/null
  fi
done
"$CL/bin/test-impact.sh" --root "$CL" always > "$T/cd9.always" 2>/dev/null
grep -qxF tests/a.bh-x-test.sh "$T/cd9.always" && grep -qxF tests/b.bh-y-test.sh "$T/cd9.always" \
  && ok "CD-9 both new suites are always-run" || bad "CD-9 the fixtures are not always-run"
(cd "$CL" && HARNESS_TEST_SANDBOX=1 bash tests/fast-lints-data.bh-3860-test.sh) > "$T/cd9.fld" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "CD-9 the merged tree's fast-lints-data is green" || bad "CD-9 merged fast-lints-data rc=$rc: $(grep -E 'FAIL|SKIP' "$T/cd9.fld" | cut -c1-300)"

echo "CD-10: fast-lints-data with and without a durations file"
git_q -C "$CL" checkout -q base
(cd "$CL" && HARNESS_TEST_SANDBOX=1 bash tests/fast-lints-data.bh-3860-test.sh) > "$T/cd10.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "CD-10 no file: rc 0" || bad "CD-10 no file: rc=$rc $(grep FAIL "$T/cd10.out" | cut -c1-300)"
grep -qF 'SKIP D1-D4: no durations file (CI composes it; bin/ci-durations.sh fetch renders it locally)' "$T/cd10.out" \
  && ok "CD-10 the SKIP line" || bad "CD-10 no SKIP line"
# TEST-CHANGE (BH-5292, #5302): a missing row was red here. BH-5292 makes it a
# report, per prompts/plan-contract.md §10: "A plan that proposes a new limit on
# a harmless metric (time, size, line count) makes it a report, not a gate."
# A missing timing row is that metric; a malformed row is a broken file and
# stays red (D0). The file carries the two rows D2 and D4 pin, so they test
# their own facts and every other always-suite is the missing row.
printf '# rows for D2 and D4 only\ntests/gh-rest-no-subshell-lint.sh\t1.0\t1\ntests/gh-app-ratchet-test.sh\t1.0\t1\n' > "$T/cd10.tsv"
(cd "$CL" && FAST_LINTS_DURATIONS="$T/cd10.tsv" HARNESS_TEST_SANDBOX=1 bash tests/fast-lints-data.bh-3860-test.sh) > "$T/cd10b.out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'WARN D1 no durations row' "$T/cd10b.out" && ok "CD-10 a readable file with a missing row warns, rc 0" \
  || bad "CD-10 FAST_LINTS_DURATIONS rc=$rc $(grep -E 'FAIL|WARN' "$T/cd10b.out" | cut -c1-300)"
printf 'tests/gh-rest-no-subshell-lint.sh\tabc\t1\n' >> "$T/cd10.tsv"
(cd "$CL" && FAST_LINTS_DURATIONS="$T/cd10.tsv" HARNESS_TEST_SANDBOX=1 bash tests/fast-lints-data.bh-3860-test.sh) > "$T/cd10c.out" 2>&1; rc=$?
[ "$rc" != 0 ] && grep -q 'FAIL D0 ' "$T/cd10c.out" && ok "CD-10 a malformed row is still red" || bad "CD-10 malformed row rc=$rc"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
