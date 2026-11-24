#!/bin/bash
# tests/gh-ledger-per-repo.bh-9933-test.sh — BH-9933 (BH-9926.1): the
# `--per-merged-pr --by-repo` flags of bin/gh-ledger-report.sh, and `--fleet`.
#
# WHY. BH-9926 moves lanes off GitHub reads one repo at a time, so the metric
# it is judged by must be per repo: counted calls, merged PRs and calls per
# merged PR, over the `--last` window. A repo whose merged count is unknown
# prints `unknown`, never a number over a partial count.
#
# What is pinned (fixture ledger in the writer's 14-column shape,
# GH_LEDGER_REPORT_NOW fixed, merged counts through the
# GH_LEDGER_REPORT_MERGED_FILE seam, a `gh` stub on PATH that records calls):
#   1. 2 repos -> exactly 2 per_merged_pr_repo= lines with the right numbers,
#      and a repo with 0 merged prints n/a;
#   2. the report and the per_merged_pr= total line are the bytes the run
#      without --by-repo prints, and the total line comes before the repo lines;
#   3. --last bounds the count, a cache row is not counted, a graphql row is
#      `(other)`, and with no such row there is no `(other)` line;
#   4. repo attribution: case, digit fold, prefix, other owner, no repo
#      segment, an ambiguous fold;
#   5. one repo unreadable -> that repo is unknown, the other keeps its number;
#   6. bad flag sets exit 2;
#   7. --fleet reads a saved group=repo answer (GH_LEDGER_REPORT_FLEET_FILE)
#      and does not print the local table; truncated / no group echo / an
#      unreadable answer print one unknown line;
#   8. 0 `gh` calls in every case.
# Run from anywhere: bash tests/gh-ledger-per-repo.bh-9933-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
REPORT="$DIR/bin/gh-ledger-report.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -x "$REPORT" ] || { echo "FAIL: $REPORT missing or not executable"; exit 1; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

unset GH_TOKEN GITHUB_TOKEN GH_LEDGER_REPORT_MERGED_FILE GH_LEDGER_REPORT_FLEET_FILE HARNESS H
mkdir -p "$T/fakebin"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/gh-calls.txt"\nexit 1\n' "$T" > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
export HARNESS="$T/h"; mkdir -p "$HARNESS/state"

NOW=$(date -u -d '2026-10-04T19:30:00Z' +%s)   # determinism: ok pinned
export GH_LEDGER_REPORT_NOW="$NOW"

# row <dir> <ts> <path> <counted> [status] — one writer-shaped line
row() {
  local h=${2%%:*}
  printf '%s\tlane.sh\tcromford\tGET\t%s\t%s\t%s\t4000\t1791147755\tapp-1\tcore\trest\t100\t6600\n' \
    "$2" "$3" "${5:-200}" "$4" >> "$1/$h.tsv"
}
run() { OUT=$("$REPORT" "$@" 2>&1); RC=$?; }
repo_lines() { grep '^per_merged_pr_repo=' <<<"$OUT"; }
MF="$T/merged.tsv"

# ---- 1. two repos ------------------------------------------------------------
L1="$T/l1"; mkdir -p "$L1"
row "$L1" 2026-10-04T19:01:00Z repos/A/x/pulls/N 1
row "$L1" 2026-10-04T19:02:00Z /repos/A/x/pulls 1
row "$L1" 2026-10-04T19:03:00Z repos/a/X/issues/N 1
for i in 1 2 3 4; do row "$L1" "2026-10-04T19:1$i:00Z" repos/B/y/git/matching-refs/heads/ 1; done
printf 'A/x\t2\nB/y\t0\n' > "$MF"
GH_LEDGER_REPORT_MERGED_FILE="$MF" run --last 1h --dir "$L1" --per-merged-pr --by-repo
[ "$RC" = 0 ] && ok || bad "1: rc $RC: $OUT"
WANT=$'per_merged_pr_repo=A/x counted=3 merged=2 per_merged_pr=2\nper_merged_pr_repo=B/y counted=4 merged=0 per_merged_pr=n/a'
[ "$(repo_lines)" = "$WANT" ] && ok || bad "1: repo lines: want [$WANT] got [$(repo_lines)]"

# ---- 2. the report and the total line do not change --------------------------
BASE=$(GH_LEDGER_REPORT_MERGED_FILE="$MF" "$REPORT" --last 1h --dir "$L1" --per-merged-pr 2>&1)
[ "$(grep -v '^per_merged_pr_repo=' <<<"$OUT")" = "$BASE" ] && ok \
  || bad "2: the output minus the repo lines must equal the run without --by-repo; diff: $(diff <(printf '%s\n' "$BASE") <(grep -v '^per_merged_pr_repo=' <<<"$OUT"))"
grep -qx 'per_merged_pr=4 counted=7 merged=2' <<<"$OUT" && ok || bad "2: total line want per_merged_pr=4 counted=7 merged=2, got: $(grep '^per_merged_pr=' <<<"$OUT")"
TL=$(grep -n '^per_merged_pr=' <<<"$OUT" | cut -d: -f1); RL=$(grep -n '^per_merged_pr_repo=' <<<"$OUT" | head -1 | cut -d: -f1)
[ -n "$TL" ] && [ -n "$RL" ] && [ "$TL" -lt "$RL" ] && ok || bad "2: the total line ($TL) must come before the repo lines ($RL)"

# ---- 3. window, cache, (other) -----------------------------------------------
grep -q '^per_merged_pr_repo=(other)' <<<"$OUT" && bad "3: no (other) line without a non-repo row: $OUT" || ok
row "$L1" 2026-10-04T18:10:00Z repos/A/x/pulls/N 1          # outside --last 1h
row "$L1" 2026-10-04T19:20:00Z repos/A/x/pulls/N 1 cache    # the shim cache, not a call
row "$L1" 2026-10-04T19:21:00Z graphql 1
row "$L1" 2026-10-04T19:22:00Z search/issues 1
GH_LEDGER_REPORT_MERGED_FILE="$MF" run --last 1h --dir "$L1" --per-merged-pr --by-repo
grep -qx 'per_merged_pr_repo=A/x counted=3 merged=2 per_merged_pr=2' <<<"$OUT" && ok \
  || bad "3: a row outside --last or a cache row was counted: $(repo_lines)"
grep -qx 'per_merged_pr_repo=(other) counted=2' <<<"$OUT" && ok || bad "3: graphql + search must be (other) counted=2: $(repo_lines)"
[ "$(repo_lines | tail -1 | cut -c1-26)" = "per_merged_pr_repo=(other)" ] && ok || bad "3: (other) comes last: $(repo_lines)"
GH_LEDGER_REPORT_MERGED_FILE="$MF" run --last 2h --dir "$L1" --per-merged-pr --by-repo
grep -qx 'per_merged_pr_repo=A/x counted=4 merged=2 per_merged_pr=2' <<<"$OUT" && ok \
  || bad "3: --last 2h must count the 18:10 row (A/x counted=4): $(repo_lines)"

# ---- 4. attribution ----------------------------------------------------------
L4="$T/l4"; mkdir -p "$L4"
row "$L4" 2026-10-04T19:01:00Z repos/A/x/pulls/N 1           # A/x
row "$L4" 2026-10-04T19:02:00Z repos/A/xy/pulls 1            # prefix of A/x, not A/x -> other
row "$L4" 2026-10-04T19:03:00Z repos/B/x/pulls 1             # other owner -> other
row "$L4" 2026-10-04T19:04:00Z repos/A 1                     # no repo segment -> other
row "$L4" 2026-10-04T19:05:00Z repos/example-org/xN/pulls 1    # the writer's fold of x2
row "$L4" 2026-10-04T19:06:00Z repos/example-org/x2/pulls 1    # an unfolded legacy row
row "$L4" 2026-10-04T19:07:00Z repos/A/qN/pulls/N 1          # q1 and q2 both fold to qN
printf 'A/x\t1\nexample-org/x2\t1\nA/q1\t1\nA/q2\t1\n' > "$T/m4.tsv"
GH_LEDGER_REPORT_MERGED_FILE="$T/m4.tsv" run --last 1h --dir "$L4" --per-merged-pr --by-repo
WANT4=$'per_merged_pr_repo=A/q1 counted=? merged=1 per_merged_pr=unknown (ambiguous fold)
per_merged_pr_repo=A/q2 counted=? merged=1 per_merged_pr=unknown (ambiguous fold)
per_merged_pr_repo=A/x counted=1 merged=1 per_merged_pr=1
per_merged_pr_repo=example-org/x2 counted=2 merged=1 per_merged_pr=2
per_merged_pr_repo=(other) counted=3'
[ "$(repo_lines)" = "$WANT4" ] && ok || bad "4: attribution: want [$WANT4] got [$(repo_lines)]"

# ---- 5. one repo unreadable ---------------------------------------------------
printf 'A/x\t2\nB/y\tx\n' > "$T/m5.tsv"
GH_LEDGER_REPORT_MERGED_FILE="$T/m5.tsv" run --last 1h --dir "$L1" --per-merged-pr --by-repo
grep -qx 'per_merged_pr_repo=B/y counted=4 merged=? per_merged_pr=unknown (B/y unreadable)' <<<"$OUT" && ok \
  || bad "5: B/y must be unknown: $(repo_lines)"
grep -qx 'per_merged_pr_repo=A/x counted=3 merged=2 per_merged_pr=2' <<<"$OUT" && ok || bad "5: A/x keeps its number: $(repo_lines)"
grep -qx 'per_merged_pr=unknown (B/y unreadable)' <<<"$OUT" && ok || bad "5: the total line stays unknown: $(grep '^per_merged_pr=' <<<"$OUT")"
GH_LEDGER_REPORT_MERGED_FILE="$T/no-such.tsv" run --last 1h --dir "$L1" --per-merged-pr --by-repo
[ "$(repo_lines)" = 'per_merged_pr_repo=unknown (merged file unreadable)' ] && ok || bad "5: no merged file: $(repo_lines)"

# ---- 6. bad flag sets ---------------------------------------------------------
RC=0; "$REPORT" --last 1h --dir "$L1" --by-repo >/dev/null 2>&1 || RC=$?
[ "$RC" = 2 ] && ok || bad "6: --by-repo without --per-merged-pr must exit 2, got $RC"
RC=0; "$REPORT" --last 1h --dir "$L1" --per-merged-pr --fleet >/dev/null 2>&1 || RC=$?
[ "$RC" = 2 ] && ok || bad "6: --fleet without --by-repo must exit 2, got $RC"
RC=0; GH_LEDGER_REPORT_MERGED_FILE="$MF" "$REPORT" --last 1h --dir "$L1" --per-merged-pr >/dev/null 2>&1 || RC=$?
[ "$RC" = 0 ] && ok || bad "6: --per-merged-pr alone still exits 0, got $RC"

# ---- 7. --fleet ----------------------------------------------------------------
FF="$T/fleet.json"
printf '%s' '{"group":"repo","rows":[{"repo":"A/x","calls":12,"counted":10},{"repo":"B/y","calls":5,"counted":5},{"repo":"(no repo)","calls":3,"counted":3}],"truncated":false,"totals":{"rest_calls":20,"rest_counted":18,"graphql_calls":0,"graphql_counted":0}}' > "$FF"
GH_LEDGER_REPORT_FLEET_FILE="$FF" GH_LEDGER_REPORT_MERGED_FILE="$MF" run --fleet --last 168h --dir "$T/no-local-dir" --per-merged-pr --by-repo
[ "$RC" = 0 ] && ok || bad "7: rc $RC: $OUT"
WANT7=$'per_merged_pr_repo=A/x counted=10 merged=2 per_merged_pr=5\nper_merged_pr_repo=B/y counted=5 merged=0 per_merged_pr=n/a\nper_merged_pr_repo=(other) counted=3'
[ "$(repo_lines)" = "$WANT7" ] && ok || bad "7: fleet repo lines: want [$WANT7] got [$(repo_lines)]"
head -1 <<<"$OUT" | grep -q 'fleet gh_ledger (D1)' && ok || bad "7: header must name the fleet table: $(head -1 <<<"$OUT")"
grep -q '^RANK' <<<"$OUT" && bad "7: the local table must not print under --fleet: $OUT" || ok
grep -qx 'per_merged_pr=9 counted=18 merged=2' <<<"$OUT" && ok || bad "7: fleet total line: $(grep '^per_merged_pr=' <<<"$OUT")"
jq '.truncated = true' "$FF" > "$T/f-trunc.json"
GH_LEDGER_REPORT_FLEET_FILE="$T/f-trunc.json" GH_LEDGER_REPORT_MERGED_FILE="$MF" run --fleet --last 168h --per-merged-pr --by-repo
[ "$RC" = 0 ] && [ "$(repo_lines)" = 'per_merged_pr_repo=unknown (fleet ledger: truncated)' ] && ok || bad "7: truncated: rc $RC [$(repo_lines)]"
jq 'del(.group)' "$FF" > "$T/f-nogroup.json"
GH_LEDGER_REPORT_FLEET_FILE="$T/f-nogroup.json" GH_LEDGER_REPORT_MERGED_FILE="$MF" run --fleet --last 168h --per-merged-pr --by-repo
[ "$RC" = 0 ] && [ "$(repo_lines)" = 'per_merged_pr_repo=unknown (fleet ledger: no group echo)' ] && ok || bad "7: no group echo: rc $RC [$(repo_lines)]"
grep -q '^per_merged_pr=[0-9]' <<<"$OUT" && bad "7: a fleet failure must print no number: $OUT" || ok
GH_LEDGER_REPORT_FLEET_FILE="$T/no-such.json" GH_LEDGER_REPORT_MERGED_FILE="$MF" run --fleet --last 168h --per-merged-pr --by-repo
[ "$RC" = 0 ] && [ "$(repo_lines)" = 'per_merged_pr_repo=unknown (fleet ledger: unreadable answer)' ] && ok || bad "7: unreadable fleet file: rc $RC [$(repo_lines)]"

# ---- 8. no GitHub call ----------------------------------------------------------
[ ! -s "$T/gh-calls.txt" ] && ok || bad "8: gh was called: $(cat "$T/gh-calls.txt")"

echo "gh-ledger-per-repo.bh-9933: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
