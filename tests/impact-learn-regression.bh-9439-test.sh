#!/bin/bash
# tests/impact-learn-regression.bh-9439-test.sh — BH-9439: A SUITE THAT TURNS
# MERGE-QUEUE BATCHES RED, AND THAT NO MEMBER GATE RAN, GETS A LEARNED `*`
# REGRESSION ROW.
#
# bin/impact-learn.sh regression reads the run records of
# bin/ci-batch-red-report.sh (state/ci-batch-red/runs/<run_id>) and counts, per
# suite, the red, read, in-window records that fail it with every member gate
# readable and none of them running it. At --min or more it writes
# catalog/ci-batch-regression.d/learned-<16hex>.txt. bin/impact-learn-lane.sh
# runs it in step 7c and puts the files in its one PR.
#
#   L1  3 red records: listed red=3; the write makes learned-<sha1 16>.txt
#   L2  2 red records: nothing listed, nothing written
#   L3  near misses: one of 3 records does not count (7 shapes)
#   L4  trace failures count like rc failures
#   L5  a suite with a `*` row already, and a suite not in --root: not written
#   L6  round trip: bin/test-impact.sh regression reads the written fragment
#   L7  round trip: the real bin/ci-batch-red-report.sh writes the records
#       (group-run member gate, current log shape), the verb reads them
#   L8  --min 0, no records dir, bad arguments
#   L9  the lane: no candidate + 3 records goes on and opens; 2 records: none
#   L10 the lane with IMPACT_LEARN_REGRESSION_MIN=0 (and a short DAYS window)
#
# Self-contained: no network (a fake gh and fixture lane functions), no clock
# read (NOW is fixed), each case seeds its own records.
set -uo pipefail
# shellcheck source=lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null || { echo "impact-learn-regression: git is required"; exit 2; }
command -v jq >/dev/null || { echo "impact-learn-regression: jq is required"; exit 2; }

LEARN="$DIR/bin/impact-learn.sh"
NOW=1791000000
DAY=86400
RD=catalog/ci-batch-regression.d
X=tests/x-test.sh
KX=$(printf '%s' "$X" | sha1sum | cut -c1-16)
FX=$'fail\ttests/x-test.sh\t1'
G1=$'gate\t11\tgreen\t-'

# rec <dir> <id> <age-s> <concl> <prs> <tail|""> <line>... — one run record in
# the shape bin/ci-batch-red-report.sh writes (its RECORD FORMAT).
rec() {
  local d="$1" id="$2" age="$3" c="$4" prs="$5" tl="$6" l; shift 6
  mkdir -p "$d"
  { echo "run $id attempt 1 created $((NOW - age)) concl $c tree tree$id prs $prs${tl:+ $tl}"
    for l in "$@"; do printf '%s\n' "$l"; done; } > "$d/$id"
}
# three <dir> [line...] — records 101-103, red, 1-3 days old, member #11.
three() { local d="$1" i; shift; for i in 1 2 3; do rec "$d" "10$i" $((i * DAY)) red 11 "" "$@"; done; }
# verb <args> — the verb; rc in $RC, stdout in $OUT.
verb() { "$LEARN" regression "$@" > "$T/v.out" 2> "$T/v.err"; RC=$?; OUT=$(cat "$T/v.out"); }
list() { verb --list --runs "$1" --now "$NOW" --days 7 --min "${2:-3}"; }

# The tree the write mode writes into: two suites, one with a `*` row.
TREE="$T/tree"
mkdir -p "$TREE/tests" "$TREE/$RD"
scratch_install_closure bin/test-impact.sh "$TREE" >/dev/null || { echo "FAIL: cannot install bin/test-impact.sh"; exit 1; }
printf '#!/bin/bash\necho x\n' > "$TREE/$X"
printf '#!/bin/bash\necho y\n' > "$TREE/tests/y-test.sh"
printf '#!/bin/bash\necho m\n' > "$TREE/tests/mc-free-test.sh"
printf '# regression list\n' > "$TREE/$RD/README.md"
printf '# hand row\ntests/y-test.sh\t*\n' > "$TREE/$RD/other.txt"
git -C "$TREE" init -q -b main
git -C "$TREE" add -A && git -C "$TREE" -c user.name=f -c user.email=f@example.com commit -qm A
[ -f "$LEARN" ] && grep -q 'regression' "$LEARN" || echo "FAIL: $LEARN has no regression verb (every case below runs anyway)"

# ── L1: 3 red records ───────────────────────────────────────────────────────
R="$T/l1"
three "$R" "$FX" "$G1"
echo "strikes 1 created $NOW" > "$R/104.strikes"
echo "run 105 attempt 1 created $NOW concl red tree t prs 11" > "$R/.105.tmp"
list "$R"
[ "$RC" = 0 ] && [ "$OUT" = "regression $X red=3 runs=101,102,103" ] && ok \
  || bad "L1: --list rc=$RC out '$OUT' err '$(cat "$T/v.err")'"
[ -z "$(ls "$TREE/$RD" | grep learned)" ] && ok || bad "L1: --list wrote a file"
verb --runs "$R" --now "$NOW" --days 7 --min 3 --root "$TREE"
LF="$TREE/$RD/learned-$KX.txt"
[ "$RC" = 0 ] && [ -f "$LF" ] && ok || bad "L1: write rc=$RC, no $LF: $OUT $(cat "$T/v.err")"
[ "$(grep -v '^#' "$LF" 2>/dev/null)" = "$X"$'\t*' ] && ok || bad "L1: the data line is '$(grep -v '^#' "$LF" 2>/dev/null)'"
[ "$(head -1 "$LF" 2>/dev/null)" = "# bin/impact-learn.sh regression: $X turned 3 merge-queue batches red in 7 days (runs 101,102,103); no member gate ran it." ] && ok \
  || bad "L1: the comment line is '$(head -1 "$LF" 2>/dev/null)'"
grep -qxF "regression $X red=3 file=$LF" <<<"$OUT" && [ "$(tail -1 <<<"$OUT")" = "impact-learn: regression written=1 kept=0" ] && ok \
  || bad "L1: write stdout is '$OUT'"
[ -z "$(ls -a "$TREE/$RD" | grep '\.tmp')" ] && ok || bad "L1: a tmp file was left: $(ls -a "$TREE/$RD")"
# The same records again: the file is the dedupe key, nothing is rewritten.
verb --runs "$R" --now "$NOW" --days 7 --min 3 --root "$TREE"
[ "$RC" = 0 ] && [ "$(tail -1 <<<"$OUT")" = "impact-learn: regression written=0 kept=1" ] && ok || bad "L1: re-run: rc=$RC '$OUT'"

# ── L2: 2 red records ───────────────────────────────────────────────────────
R="$T/l2"
rec "$R" 101 "$DAY" red 11 "" "$FX" "$G1"
rec "$R" 102 $((2 * DAY)) red 11 "" "$FX" "$G1"
list "$R"
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "L2: 2 records listed: rc=$RC '$OUT'"
rm -f "$LF"
verb --runs "$R" --now "$NOW" --days 7 --min 3 --root "$TREE"
[ "$RC" = 0 ] && [ ! -e "$LF" ] && [ "$OUT" = "impact-learn: regression written=0 kept=0" ] && ok || bad "L2: write rc=$RC '$OUT'"

# ── L3: near misses: 2 good records and one that does not count ─────────────
# l3 <name> <age> <concl> <prs> <tail> <line>... — the third record.
l3() {
  local n="$1" age="$2" c="$3" prs="$4" tl="$5"; shift 5
  R="$T/l3-$n"
  rec "$R" 101 "$DAY" red 11 "" "$FX" "$G1"
  rec "$R" 102 $((2 * DAY)) red 11 "" "$FX" "$G1"
  rec "$R" 103 "$age" "$c" "$prs" "$tl" "$@"
  list "$R"
  [ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "L3 $n: listed: rc=$RC '$OUT'"
  # The near miss is the only difference: the same record made good counts.
  list "$R" 2
  [ "$OUT" = "regression $X red=2 runs=101,102" ] && ok || bad "L3 $n: with --min 2 the list is '$OUT'"
}
l3 gate-ran   "$((3 * DAY))" red 11 "" "$FX" $'gate\t11\tgreen\ttests/a-test.sh,tests/x-test.sh'
l3 gate-unread "$((3 * DAY))" red 11,12 "" "$FX" "$G1" $'gate\t12\t?\t-'
l3 unread     "$((3 * DAY))" red 11 unread
l3 old        "$((8 * DAY))" red 11 "" "$FX" "$G1"
l3 job-fail   "$((3 * DAY))" red 11 "" $'fail\tjob:Syntax\tother' "$G1"
l3 green      "$((3 * DAY))" green 11 "" $'ran\ttests/x-test.sh'
l3 no-gate    "$((3 * DAY))" red - "" "$FX"
# A readable `read` verdict (a gate log with no verdict line) counts.
R="$T/l3-read"
three "$R" "$FX" $'gate\t11\tread\t-'
list "$R"
[ "$OUT" = "regression $X red=3 runs=101,102,103" ] && ok || bad "L3 read: a read verdict did not count: '$OUT'"

# ── L4: trace failures ──────────────────────────────────────────────────────
R="$T/l4"
rec "$R" 101 "$DAY" red 11 "" $'fail\ttests/x-test.sh\ttrace' "$G1"
rec "$R" 102 $((2 * DAY)) red 11 "" $'fail\ttests/x-test.sh\ttrace' "$G1"
rec "$R" 103 $((3 * DAY)) red 11 "" "$FX" "$G1"
rec "$R" 104 $((3 * DAY)) red 11 "" $'fail\ttests/mc/m-test.sh\ttrace' $'fail\ttests/mc/m-test.sh\t2' "$G1"
list "$R" 1
grep -qxF "regression $X red=3 runs=101,102,103" <<<"$OUT" && ok || bad "L4: trace did not count: '$OUT'"
grep -qxF "regression tests/mc/m-test.sh red=1 runs=104" <<<"$OUT" && ok || bad "L4: one record counts once: '$OUT'"

# ── L5: an existing `*` row, and a suite not in the tree ────────────────────
R="$T/l5"
three "$R" $'fail\ttests/y-test.sh\t1' $'fail\ttests/z-test.sh\t1' "$G1"
list "$R"
[ "$(grep -c '^regression ' <<<"$OUT")" = 2 ] && ok || bad "L5: --list is '$OUT'"
KY=$(printf '%s' tests/y-test.sh | sha1sum | cut -c1-16)
KZ=$(printf '%s' tests/z-test.sh | sha1sum | cut -c1-16)
verb --runs "$R" --now "$NOW" --days 7 --min 3 --root "$TREE"
[ "$RC" = 0 ] && [ ! -e "$TREE/$RD/learned-$KY.txt" ] && [ ! -e "$TREE/$RD/learned-$KZ.txt" ] && ok \
  || bad "L5: a file was written: rc=$RC $(ls "$TREE/$RD")"
[ "$(tail -1 <<<"$OUT")" = "impact-learn: regression written=0 kept=2" ] && ok || bad "L5: stdout is '$OUT'"
grep -q '^keep tests/y-test.sh' <<<"$OUT" && grep -q '^keep tests/z-test.sh (no such suite)' <<<"$OUT" && ok \
  || bad "L5: the keep reasons are missing: '$OUT'"

# ── L6: the written fragment is a map row ───────────────────────────────────
R="$T/l1"
verb --runs "$R" --now "$NOW" --days 7 --min 3 --root "$TREE"
"$TREE/bin/test-impact.sh" --root "$TREE" regression > "$T/l6.out" 2> "$T/l6.err"; RC=$?
[ "$RC" = 0 ] && grep -qxF "$X"$'\t*' "$T/l6.out" && ok \
  || bad "L6: bin/test-impact.sh regression rc=$RC: $(cat "$T/l6.out" "$T/l6.err")"
printf 'bin/anything.sh\n' > "$T/l6.changed"
"$TREE/bin/test-impact.sh" --root "$TREE" regression --changed "$T/l6.changed" > "$T/l6b.out" 2>/dev/null
grep -qxF "$X"$'\t*' "$T/l6b.out" && ok || bad "L6: an unrelated diff does not select the row: $(cat "$T/l6b.out")"

# ── L8: off, absent, bad arguments ──────────────────────────────────────────
three "$T/l8" "$FX" "$G1"
list "$T/l8" 0
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "L8: --min 0: rc=$RC '$OUT'"
rm -f "$LF"
verb --runs "$T/l8" --now "$NOW" --days 7 --min 0 --root "$TREE"
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ ! -e "$LF" ] && ok || bad "L8: --min 0 write: rc=$RC '$OUT'"
list "$T/no-such-dir"
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "L8: no records dir: rc=$RC '$OUT'"
for a in "--days x" "--days 0" "--now 12ab" "--min -1"; do
  # shellcheck disable=SC2086
  verb --list --runs "$T/l8" --now "$NOW" --days 7 --min 3 $a
  [ "$RC" = 2 ] && ok || bad "L8: '$a' rc=$RC (want 2)"
done
verb --list --now "$NOW" --days 7 --min 3
[ "$RC" = 2 ] && ok || bad "L8: no --runs rc=$RC (want 2)"
verb --list --runs "$T/l8" --now "$NOW" --days 7 --min 3 --bogus
[ "$RC" = 2 ] && ok || bad "L8: an unknown argument rc=$RC (want 2)"

# ── L9 / L10: the lane ──────────────────────────────────────────────────────
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com
export GIT_AUTHOR_DATE='2026-10-01T00:00:00Z' GIT_COMMITTER_DATE='2026-10-01T00:00:00Z'
SLUG=example/fixture-repo
# mkorigin <src> <name> — a bare origin and a checkout of <src>'s main, kept pristine.
mkorigin() {
  git -C "$1" init -q -b main && git -C "$1" add -A && git -C "$1" commit -qm A
  git init -q --bare -b main "$T/pristine/$2/origin.git"
  git -C "$1" push -q "$T/pristine/$2/origin.git" main:main
  mkdir -p "$T/pristine/$2/repos"
  git clone -q --no-local "$T/pristine/$2/origin.git" "$T/pristine/$2/repos/fixture-repo"
}
S="$T/src"
mkdir -p "$S/tests" "$S/$RD" "$S/catalog/test-impact-learned.d"
scratch_install_closure bin/impact-learn.sh "$S" >/dev/null || exit 1
scratch_install_closure bin/test-impact.sh "$S" >/dev/null || exit 1
printf '#!/bin/bash\necho x\n' > "$S/$X"
printf '# regression list\n' > "$S/$RD/README.md"
printf '# learned edges\n' > "$S/catalog/test-impact-learned.d/README.md"
cp -a "$S" "$T/src-bad"
mkorigin "$S" good
# The bad tree: the regression directory is a file, so the tree's verb cannot write.
rm -rf "$T/src-bad/$RD" "$T/src-bad/.git"; printf 'not a dir\n' > "$T/src-bad/$RD"
mkorigin "$T/src-bad" bad

H="$T/h"
mkdir -p "$H/bin" "$H/env"
: > "$H/env/global.env"
printf '#!/bin/bash\n[ "${BASH_SOURCE[0]}" = "$0" ] || return 0\nexit 0\n' > "$H/bin/jobs-client.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts"\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/jobs-client.sh" "$H/bin/lane-alert.sh"
scratch_install_closure bin/impact-learn-lane.sh "$H" >/dev/null 2>&1
scratch_install_closure bin/impact-learn.sh "$H" >/dev/null 2>&1
LANE="$H/bin/impact-learn-lane.sh"
F="$T/f"
cat > "$T/fx.sh" <<SH
F="$F"
is_hub_box() { return 0; }
local_box_name() { echo hub; }
dqw_events_list() { echo "dqw \$*" >> "\$F/calls"; echo '{"rows":[],"truncated":false}'; }
gh_rest_pr_list() { echo "prlist \$*" >> "\$F/calls"; echo '[]'; }
gh_default_auth_for_slug() { return 0; }
[ -r "\$HARNESS/bin/lib/stale-parent.sh" ] && . "\$HARNESS/bin/lib/stale-parent.sh"
sp_open_children() { return 0; }
gh_rest() {
  echo "gh_rest \$1 \$2" >> "\$F/calls"
  [ "\$1" = POST ] && [ "\$3" = --input ] && cp "\$4" "\$F/post.json"
  GH_REST_STATUS=201
  echo '{"number":777}'
}
SH
# reset <origin> — a fresh origin, checkout and harness state.
reset() {
  rm -rf "$T/origin.git" "$T/repos" "$H/state" "$H/logs" "$H/locks" "$F" "$T/alerts" "$T/tmp"
  cp -a "$T/pristine/$1/origin.git" "$T/origin.git"
  cp -a "$T/pristine/$1/repos" "$T/repos"
  git -C "$T/repos/fixture-repo" remote set-url origin "$T/origin.git"
  mkdir -p "$F" "$T/tmp"; : > "$F/calls"
}
LRUNS="$H/state/ci-batch-red/runs"
lane() {
  env -i PATH="$PATH" HOME="$T" HARNESS="$H" HARNESS_TEST_SANDBOX=1 \
    IMPACT_LEARN_LANE_FIXTURE="$T/fx.sh" IMPACT_LEARN_NOW="$NOW" REPOS_ROOT="$T/repos" \
    HARNESS_REPO="$SLUG" TMPDIR="$T/tmp" "$@" bash "$LANE" > "$T/out" 2> "$T/err"; RC=$?
  OUT=$(cat "$T/out")
}
lastlog() { tail -1 "$H/logs/impact-learn.log" 2>/dev/null; }
nalerts() { cat "$T/alerts" 2>/dev/null | grep -c .; }

# L9: no dequeue candidate, 3 records: the tick goes on and would open.
reset good
three "$LRUNS" "$FX" "$G1"
lane IMPACT_LEARN_ACT=0
[ "$RC" = 0 ] && grep -qx 'would-open edges=1 expired=0' <<<"$OUT" && ok || bad "L9: rc=$RC out '$OUT' err '$(cat "$T/err")'"
grep -qxF "  regression $X -> * (red=3, runs 101,102,103)" <<<"$OUT" && ok || bad "L9: the would-open print has no regression row: '$OUT'"
lastlog | grep -q ' candidates=0 edges=1 .* would-open$' && ok || bad "L9: log line is '$(lastlog)'"
[ "$(nalerts)" = 0 ] && ok || bad "L9: alerts: $(cat "$T/alerts")"
# L9b: the same tick for real: one PR with the file and the body section.
lane
[ "$RC" = 0 ] && lastlog | grep -q 'opened #777$' && ok || bad "L9b: rc=$RC log '$(lastlog)' err '$(cat "$T/err")'"
[ "$(git -C "$T/origin.git" diff --name-only main impact-learn/edges 2>/dev/null)" = "$RD/learned-$KX.txt" ] && ok \
  || bad "L9b: the branch adds '$(git -C "$T/origin.git" diff --name-only main impact-learn/edges 2>/dev/null)'"
BODY=$(jq -r .body "$F/post.json" 2>/dev/null)
grep -qF 'These suites turned 3 or more merge-queue batches red in 7 days, and no member gate ran them.' <<<"$BODY" \
  && grep -qF -- "- \`$X\` (3 red batches: runs 101,102,103)" <<<"$BODY" && ok || bad "L9b: the PR body is '$BODY'"
grep -q 'The merge queue ejected these culprits' <<<"$BODY" && bad "L9b: the body has an empty learned-edge section" || ok
# L9c: 2 records: none, and the tick stops before the worktree (no expiry
# step ran, so expired= stays `-`).
reset good
rec "$LRUNS" 101 "$DAY" red 11 "" "$FX" "$G1"
rec "$LRUNS" 102 $((2 * DAY)) red 11 "" "$FX" "$G1"
lane IMPACT_LEARN_ACT=0
[ "$RC" = 0 ] && lastlog | grep -q ' expired=- none$' && ok || bad "L9c: rc=$RC log '$(lastlog)'"
grep -q 'regression' <<<"$OUT" && bad "L9c: stdout has a regression line: '$OUT'" || ok
# L9d: the tree's verb fails: one warn, no row, the tick still ends.
reset bad
three "$LRUNS" "$FX" "$G1"
lane IMPACT_LEARN_ACT=0
[ "$RC" = 0 ] && lastlog | grep -q ' none$' && ok || bad "L9d: rc=$RC log '$(lastlog)' err '$(cat "$T/err")'"
[ "$(nalerts)" = 1 ] && grep -q -- '--id impact-learn-regression ' "$T/alerts" && ok || bad "L9d: alerts are '$(cat "$T/alerts" 2>/dev/null)'"

# L10: IMPACT_LEARN_REGRESSION_MIN=0: no regression read, today's none.
reset good
three "$LRUNS" "$FX" "$G1"
lane IMPACT_LEARN_ACT=0 IMPACT_LEARN_REGRESSION_MIN=0
[ "$RC" = 0 ] && lastlog | grep -q ' edges=0 .* expired=- none$' && ok || bad "L10: rc=$RC log '$(lastlog)'"
grep -q 'regression' <<<"$OUT" && bad "L10: stdout has a regression line: '$OUT'" || ok
# L10b: IMPACT_LEARN_REGRESSION_DAYS=1: the 1-3 day old records are mostly outside it.
lane IMPACT_LEARN_ACT=0 IMPACT_LEARN_REGRESSION_DAYS=1
[ "$RC" = 0 ] && lastlog | grep -q ' expired=- none$' && ok || bad "L10b: DAYS=1: rc=$RC log '$(lastlog)'"
# L10c: IMPACT_LEARN_REGRESSION_MIN=2 with 2 records: the knob is the threshold.
scratch_rm "$LRUNS"
rec "$LRUNS" 101 "$DAY" red 11 "" "$FX" "$G1"
rec "$LRUNS" 102 $((2 * DAY)) red 11 "" "$FX" "$G1"
lane IMPACT_LEARN_ACT=0 IMPACT_LEARN_REGRESSION_MIN=2
grep -qxF "  regression $X -> * (red=2, runs 101,102)" <<<"$OUT" && ok || bad "L10c: MIN=2: '$OUT' log '$(lastlog)'"

# ── L7: round trip with the writer, bin/ci-batch-red-report.sh ──────────────
# The real report (stub lane-gate, gh-budget and gh-repo-token libs, the REAL
# bin/lib/gh-ci-read.sh, a fake gh that exits 1 on any path it does not know)
# reads red batches whose member gate is a group run (prequeue-group-gate.yml,
# job `gate (<pr>, <head40>) / gate`, the log in the current shape:
# tests/fixtures/bh-9439/gate-job-log.txt). The verb reads its records.
GFIX="$DIR/tests/fixtures/bh-9439/gate-job-log.txt"
[ -s "$GFIX" ] || bad "L7: fixture missing: $GFIX"
RR="$T/rr"
mkdir -p "$RR/bin/lib" "$T/path"
cat > "$RR/bin/lib/lane-gate.sh" <<'SH'
lane_gate_or_exit() { :; }
lane_env_apply() { :; }
lane_knob() { printf '%s' "${!2:-}"; }
SH
printf 'gh_budget_low() { return 1; }\n' > "$RR/bin/lib/gh-budget.sh"
printf 'gh_repo_use_token() { return 0; }\n' > "$RR/bin/lib/gh-repo-token.sh"
cat > "$T/path/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls.txt"
FX="$HARNESS/fx"; path=""; pg=1; esc=0
for a in "$@"; do
  case "$a" in
    repos/*) path="$a" ;;
    page=*) pg="${a#page=}" ;;
    --allow-escape-sequences) esc=1 ;;
  esac
done
case "$path" in *page=*) pg="${path##*page=}"; pg="${pg%%&*}" ;; esac
p="${path%%\?*}"
case "$p" in
  repos/*/actions/workflows/harness-ci.yml/runs) f="$FX/runs.$pg.json" ;;
  repos/*/actions/workflows/prequeue-group-gate.yml/runs) f="$FX/ggates.$pg.json" ;;
  repos/*/actions/runs/*/jobs) id="${p#*/actions/runs/}"; id="${id%/jobs}"; f="$FX/jobs.$id.json" ;;
  repos/*/actions/jobs/*/logs)
    id="${p#*/actions/jobs/}"; id="${id%/logs}"
    [ "$esc" = 1 ] || exit 0
    f="$FX/log.$id.txt" ;;
  *) exit 1 ;;
esac
[ -r "$f" ] || exit 1
cat "$f"
SH
chmod +x "$T/path/gh"
scratch_install_closure bin/ci-batch-red-report.sh "$RR" >/dev/null || bad "L7: cannot install bin/ci-batch-red-report.sh"
GH40=1f7f14b3c2d9e8a7b6c5d4e3f2a1b0c9d8e7f6a5
riso() { jq -rn --argjson t "$(( NOW - $1 ))" '$t | todate'; }
# batches <n> — n red batches (run 20<i>, member #914<i>), each after its own
# group run, every batch failing tests/x-test.sh.
batches() {
  local n="$1" i runs="" gg="" age
  scratch_rm "$RR/fx"; scratch_rm "$RR/state"; scratch_rm "$RR/logs"; mkdir -p "$RR/fx" "$RR/logs"
  for (( i = 1; i <= n; i++ )); do
    age=$(( i * DAY ))
    runs="$runs${runs:+,}$(jq -nc --argjson id "20$i" --arg t "$(riso "$age")" --arg m "Merge of #914$i" --arg tr "tree$i" \
      '{id: $id, head_branch: "mergify/merge-queue/main/pr-x", conclusion: "failure", status: "completed", created_at: $t, run_attempt: 1, head_commit: {tree_id: $tr, message: $m}}')"
    jq -n "{total_count: 2, jobs: [{id: 30${i}1, conclusion: \"failure\", name: \"Tests, traced (shard 0/2)\"}, {id: 30${i}2, conclusion: \"success\", name: \"Tests, traced (shard 1/2)\"}]}" > "$RR/fx/jobs.20$i.json"
    printf '2026-10-01T10:00:00.1Z --- tests/x-test.sh rc=1 3s\n' > "$RR/fx/log.30${i}1.txt"
    gg="$gg${gg:+,}$(jq -nc --argjson id "40$i" --arg t "$(riso $(( age + 600 )))" --arg d "prequeue group=g0$i main=8e1c0d2a9b7f4c6e3a5d1b0f9c8e7a6d5b4c3a21" \
      '{id: $id, display_title: $d, created_at: $t, conclusion: "success"}')"
    jq -n --arg g "gate (914$i, $GH40) / gate" "{total_count: 2, jobs: [{id: 50${i}0, conclusion: \"success\", name: \"plan\"}, {id: 50${i}1, conclusion: \"success\", name: \$g}]}" > "$RR/fx/jobs.40$i.json"
    cp "$GFIX" "$RR/fx/log.50${i}1.txt"
  done
  jq -n --argjson r "[$runs]" '{total_count: ($r | length), workflow_runs: $r}' > "$RR/fx/runs.1.json"
  jq -n --argjson r "[$gg]" '{total_count: ($r | length), workflow_runs: $r}' > "$RR/fx/ggates.1.json"
  rm -f "$RR/calls.txt"
  ( export HARNESS="$RR" NOW PATH="$T/path:$PATH" CI_BATCH_RED_REPO=example-org/cromford
    unset CI_BATCH_RED_GROUP_SCAN CI_BATCH_RED_DAYS
    bash "$RR/bin/ci-batch-red-report.sh" ) > "$T/rr.out" 2> "$T/rr.err"
  RC=$?
}
batches 3
[ "$RC" = 0 ] && ok || bad "L7: the report rc=$RC: $(cat "$T/rr.err")"
grep -qxF $'gate\t9141\tgreen\t-' "$RR/state/ci-batch-red/runs/201" 2>/dev/null \
  && grep -qxF $'fail\ttests/x-test.sh\t1' "$RR/state/ci-batch-red/runs/201" && ok \
  || bad "L7: record 201 is '$(cat "$RR/state/ci-batch-red/runs/201" 2>/dev/null)'"
list "$RR/state/ci-batch-red/runs"
[ "$RC" = 0 ] && [ "$OUT" = "regression $X red=3 runs=201,202,203" ] && ok || bad "L7: 3 batches: rc=$RC '$OUT'"
batches 2
list "$RR/state/ci-batch-red/runs"
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ -f "$RR/state/ci-batch-red/runs/202" ] && ok || bad "L7: 2 batches: rc=$RC '$OUT'"
grep -qE 'https?://' "$RR/calls.txt" 2>/dev/null && bad "L7: the fake gh saw a URL" || ok

echo "impact-learn-regression: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
