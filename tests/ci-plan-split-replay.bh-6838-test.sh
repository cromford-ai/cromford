#!/bin/bash
# tests/ci-plan-split-replay.bh-6838-test.sh — bin/ci-plan-split-replay.sh, the
# read-only replay of the last N merge-queue drafts through THIS checkout's
# planner (BH-6838 Task 6).
#
# The REAL replay, the REAL bin/ci-plan.sh, bin/test-impact.sh and
# bin/test-tiers.sh run in a small scratch repo (four suites, one regression
# row, one nightly tier row). GitHub is a stub of `gh api <path>` over fixture
# files. No case reads the network, the clock or the box.
#
#   R1  three drafts -> three rows, newest first; the failed draft whose failing
#       suite is in the NEW list is `caught-batch`; `.mergify.yml` fires full
#       once: `full fires: 1 of 3`, `row .mergify.yml fires 1`; the old
#       answer comes from the ci-plan notice and the run times
#   R1b a 300-file compare is an `unreadable` row (never planned), rc 0
#   R2  a failed draft whose own diff adds worker/jobs/test/route-table.d/
#       bh-4156-x.txt and whose failing suite is
#       tests/route-keyed-merge.bh-5788-test.sh is `caught-pr` (the regression
#       row in the scratch catalog/ci-batch-regression.d/)
#   R3  the other verdicts: a suite with a nightly tier row is `moved-nightly`,
#       a suite nothing selects is `missed`, a failed lint step still in the
#       workflow is `caught-pr`, a moved lint step is `moved-nightly`; a shard
#       log that cannot be read makes the row `unreadable`
#   R4  an unreadable draft list is rc 2; a bad argument is rc 2
#   R5  `est` is the planner's split over the fetched durations (minutes of
#       the slowest shard); with no durations or a seed fallback it is `-`
#   R6  a STACKED draft whose whole diff escalates only on an inherited path
#       is planned on its own diff: planned_on `own`, batch-selected; a stacked
#       draft whose own diff escalates stays full on the whole diff
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
REPLAY_SRC="$DIR/bin/ci-plan-split-replay.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

[ -f "$REPLAY_SRC" ] || { echo "FAIL: $REPLAY_SRC does not exist"; echo "ci-plan-split-replay.bh-6838-test.sh: 0 passed, 1 failed"; exit 1; }

# ── The scratch repo: the real planner, selector, tier step and replay.
G="$T/repo"; mkdir -p "$G"
for s in bin/ci-plan-split-replay.sh bin/ci-plan.sh bin/test-impact.sh bin/test-tiers.sh bin/ci-durations.sh; do
  scratch_install_closure "$s" "$G" > /dev/null || { echo "FAIL: cannot install $s's closure"; exit 1; }
done
mkdir -p "$G/catalog/ci-batch-regression.d" "$G/tests/lib" "$G/worker/jobs/test/route-table.d" \
         "$G/worker/jobs/scripts" "$G/.github/workflows"
cp -r "$DIR/catalog/ci-batch-escalate.d" "$G/catalog/" || { echo "FAIL: no escalation rules"; exit 1; }
cp "$DIR/tests/lib/scratch.sh" "$G/tests/lib/"
printf 'tests/always-a-test.sh\n' > "$G/catalog/test-impact-always.txt"
printf '# a scratch tier file\ntests/nightly-y-test.sh\tnightly\t30\t-\tfixture: a slow suite\n' > "$G/catalog/test-tiers.tsv"
# The regression row R2 needs. It lives in the scratch repo only.
printf '# fixture: batch #830 failed on a route fragment\ntests/route-keyed-merge.bh-5788-test.sh\tworker/jobs/test/route-table.d/,worker/jobs/scripts/routes-build.mjs\n' \
  > "$G/catalog/ci-batch-regression.d/fixture.txt"
printf 'GET /fixture\n' > "$G/worker/jobs/test/route-table.d/base.txt"
printf '// fixture\n' > "$G/worker/jobs/scripts/routes-build.mjs"
printf '#!/bin/bash\necho foo\n' > "$G/bin/foo.sh"
printf '#!/bin/bash\necho bar\n' > "$G/bin/bar.sh"
for t in always-a foo-x route-keyed-merge.bh-5788 nightly-y other-z; do
  printf '#!/bin/bash\n. "$(dirname "$0")/lib/scratch.sh" || exit 1\n' > "$G/tests/$t-test.sh"
done
echo 'bash "$DIR/bin/foo.sh"' >> "$G/tests/foo-x-test.sh"
echo 'bash "$DIR/bin/bar.sh"' >> "$G/tests/nightly-y-test.sh"
cat > "$G/.github/workflows/harness-ci.yml" <<'EOF'
name: Harness CI
jobs:
  lint:
    steps:
      - name: shellcheck (errors only)
        run: true
EOF
git -C "$G" init -q && git -C "$G" add -A \
  && git -C "$G" -c user.email=t@example.invalid -c user.name=t commit -qm fixture \
  || { echo "FAIL: cannot commit the scratch repo"; exit 1; }
REPLAY="$G/bin/ci-plan-split-replay.sh"
cmp -s "$REPLAY_SRC" "$REPLAY" || { echo "FAIL: the scratch replay is not this checkout's"; exit 1; }

# ── The GitHub fixtures.
FX="$T/fx"; mkdir -p "$FX/r1" "$FX/r2"
sha() { printf '%s%039d' "$1" "$2"; }   # sha <hexchar> <n> -> 40 hex
draft() { # draft <n> <base> <head> <title>
  jq -nc --argjson n "$1" --arg b "$2" --arg h "$3" --arg t "$4" \
    '{number:$n, title:$t, body:"merge queue fixture body", labels:[], user:{login:"mergify[bot]"},
      base:{sha:$b}, head:{sha:$h, ref:("mergify/merge-queue/" + ($n|tostring))}}'
}
files() { jq -nc '{files: [$ARGS.positional[] | {filename: .}]}' --args "$@"; }
# run <dir> <head> <run id> <conclusion> <minutes> — the newest Harness CI run of a head
run() {
  jq -nc --argjson id "$3" --arg c "$4" --arg end "2026-10-13T10:$5:00Z" \
    '{workflow_runs: [{id: $id, name: "Harness CI", event: "pull_request", status: "completed", conclusion: $c,
      run_started_at: "2026-10-13T10:00:00Z", updated_at: $end}]}' > "$1/runs-$2.json"
}
# jobs <dir> <run id> <extra jobs JSON array> — the plan job and one shard (30 min)
jobs() {
  jq -nc --argjson id "$2" --argjson extra "$3" '{jobs: ([
    {id: ($id * 10), name: "CI plan (what this run tests)", conclusion: "success",
     check_run_url: ("https://api.github.com/repos/o/r/check-runs/" + ($id|tostring))},
    {id: ($id * 10 + 1), name: "Tests, traced (shard 0/1)", conclusion: "success",
     started_at: "2026-10-13T10:00:00Z", completed_at: "2026-10-13T10:30:00Z"}] + $extra)}' > "$1/jobs-$2.json"
}
ann() { # ann <dir> <run id> <message>
  jq -nc --arg m "$3" '[{annotation_level: "notice", title: "ci-plan", message: $m}]' > "$1/ann-$2.json"
}
shardfail() { # shardfail <run id> <job id> — a failed shard job
  jq -nc --argjson id "$2" '[{id: $id, name: "Tests, traced (shard 1/2)", conclusion: "failure",
    started_at: "2026-10-13T10:00:00Z", completed_at: "2026-10-13T10:40:00Z"}]'
}

# R1 set: #903 green bin/bar.sh, #902 red bin/foo.sh (tests/foo-x fails), #901 green .mergify.yml.
B1=$(sha b 1); H1=$(sha a 1); B2=$(sha b 2); H2=$(sha a 2); B3=$(sha b 3); H3=$(sha a 3)
{ echo '['
  draft 903 "$B3" "$H3" "merge queue: embarking #13 together"; echo ,
  draft 902 "$B2" "$H2" "merge queue: embarking #12 together"; echo ,
  draft 901 "$B1" "$H1" "merge queue: embarking #11 together"; echo ,
  jq -nc '{number:900, title:"a human PR", body:"", labels:[], user:{login:"fixture-human"}, base:{sha:"x"}, head:{sha:"y", ref:"feature/x"}}'
  echo ']'; } > "$FX/r1/pulls.json"
files bin/bar.sh > "$FX/r1/cmp-$B3-$H3.json"
files bin/foo.sh > "$FX/r1/cmp-$B2-$H2.json"
files .mergify.yml > "$FX/r1/cmp-$B1-$H1.json"
run "$FX/r1" "$H3" 3 success 40; jobs "$FX/r1" 3 '[]'
ann "$FX/r1" 3 "mode=batch-selected count=2 total=5 n=1 reason=selected: 1 changed path(s)"
run "$FX/r1" "$H2" 2 failure 50; jobs "$FX/r1" 2 "$(shardfail 2 77)"
ann "$FX/r1" 2 "mode=batch-selected count=2 total=5 n=1 reason=selected: 1 changed path(s)"
printf '2026-10-13T10:01:00.0000000Z --- tests/always-a-test.sh rc=0 3s\n2026-10-13T10:02:00.0000000Z --- tests/foo-x-test.sh rc=1 9s\n' > "$FX/r1/log-77.txt"
run "$FX/r1" "$H1" 1 success 20; jobs "$FX/r1" 1 '[]'
ann "$FX/r1" 1 "mode=full count=5 total=5 n=1 reason=full: selection input: .mergify.yml"

# R2/R3 set: #906 red route fragment (caught-pr), #905 red: nightly-y + other-z + two lint
# steps, #904 red with a shard log that cannot be read.
B4=$(sha b 4); H4=$(sha a 4); B5=$(sha b 5); H5=$(sha a 5); B6=$(sha b 6); H6=$(sha a 6)
{ echo '['
  draft 906 "$B6" "$H6" "merge queue: embarking #16 together"; echo ,
  draft 905 "$B5" "$H5" "merge queue: embarking #15 together"; echo ,
  draft 904 "$B4" "$H4" "merge queue: embarking #14 together"
  echo ']'; } > "$FX/r2/pulls.json"
files worker/jobs/test/route-table.d/bh-4156-x.txt > "$FX/r2/cmp-$B6-$H6.json"
run "$FX/r2" "$H6" 6 failure 30; jobs "$FX/r2" 6 "$(shardfail 6 66)"
ann "$FX/r2" 6 "mode=batch-selected count=2 total=5 n=1 reason=selected: 1 changed path(s)"
printf -- '--- tests/route-keyed-merge.bh-5788-test.sh rc=1 4s\n' > "$FX/r2/log-66.txt"
files bin/bar.sh bin/foo.sh > "$FX/r2/cmp-$B5-$H5.json"
run "$FX/r2" "$H5" 5 failure 30
jobs "$FX/r2" 5 "$(jq -nc '[{id: 55, name: "Tests, traced (shard 1/2)", conclusion: "failure"},
  {id: 56, name: "Syntax + shellcheck + config integrity", conclusion: "failure", steps: [{name: "bash -n every script", conclusion: "success"},
    {name: "shellcheck (errors only)", conclusion: "failure"}]},
  {id: 57, name: "Test determinism lint", conclusion: "failure", steps: [{name: "determinism lint", conclusion: "failure"}]}]')"
ann "$FX/r2" 5 "mode=batch-selected count=3 total=5 n=1 reason=selected: 2 changed path(s)"
printf -- '--- tests/nightly-y-test.sh rc=1 4s\n--- tests/other-z-test.sh rc=2 4s\n' > "$FX/r2/log-55.txt"
files bin/foo.sh > "$FX/r2/cmp-$B4-$H4.json"
run "$FX/r2" "$H4" 4 failure 30; jobs "$FX/r2" 4 "$(shardfail 4 44)"
ann "$FX/r2" 4 "mode=batch-selected count=2 total=5 n=1 reason=selected: 1 changed path(s)"

# R6 set: #908 stacked on C8 (own diff bin/foo.sh, inherited .mergify.yml); #907 stacked,
# own diff .mergify.yml.
B8=$(sha b 8); H8=$(sha a 8); C8=$(sha c 8); B7=$(sha b 7); H7=$(sha a 7); C7=$(sha c 7)
mkdir -p "$FX/r3"
sbody() { printf '```yaml\n---\nchecking_base_sha: %s\npull_requests:\n  - number: 18\n...\n```\n' "$1"; }
{ echo '['
  draft 908 "$B8" "$H8" "merge queue: embarking #18 together" | jq -c --arg b "$(sbody "$C8")" '.body = $b'; echo ,
  draft 907 "$B7" "$H7" "merge queue: embarking #17 together" | jq -c --arg b "$(sbody "$C7")" '.body = $b'
  echo ']'; } > "$FX/r3/pulls.json"
files .mergify.yml bin/foo.sh > "$FX/r3/cmp-$B8-$H8.json"; files bin/foo.sh > "$FX/r3/cmp-$C8-$H8.json"
files .mergify.yml bin/foo.sh > "$FX/r3/cmp-$B7-$H7.json"; files .mergify.yml > "$FX/r3/cmp-$C7-$H7.json"
for i in 7 8; do
  h=$(eval echo "\$H$i"); run "$FX/r3" "$h" "$i" success 30; jobs "$FX/r3" "$i" '[]'
  ann "$FX/r3" "$i" "mode=full count=5 total=5 n=1 reason=full: selection input: .mergify.yml"
done

cat > "$T/gh" <<EOF
#!/bin/bash
# a stub of \`gh api <path>\` over the fixture files; anything else is refused
[ "\$1" = api ] || exit 9
p="\$2"; d="$FX/\${STUB_SET:-r1}"; echo "\$p" >> "$FX/asked"
case "\$p" in
  *pulls\?*) [ "\${STUB_LIST_FAIL:-0}" = 1 ] && exit 1
             case "\$p" in *page=1) cat "\$d/pulls.json" ;; *) echo '[]' ;; esac ;;
  */pulls/[0-9]*) echo '{"number": 1, "labels": []}' ;;
  *compare/*) r="\${p##*compare/}"; f="\$d/cmp-\${r%%...*}-\${r##*...}.json"
              [ "\${STUB_BIG:-}" = "\${r##*...}" ] && { jq -nc '{files: [range(300) | {filename: ("bin/f" + tostring + ".sh")}]}'; exit 0; }
              [ -f "\$f" ] && cat "\$f" || exit 1 ;;
  *actions/runs\?*head_sha=*) h="\${p##*head_sha=}"; h="\${h%%&*}"; cat "\$d/runs-\$h.json" 2>/dev/null || exit 1 ;;
  *actions/runs/*/jobs*) i="\${p#*actions/runs/}"; cat "\$d/jobs-\${i%%/*}.json" 2>/dev/null || exit 1 ;;
  # Real gh refuses a log with escape codes without --allow-escape-sequences.
  *actions/jobs/*/logs) [ "\${3:-}" = --allow-escape-sequences ] || exit 1
                        i="\${p#*actions/jobs/}"; cat "\$d/log-\${i%%/*}.txt" 2>/dev/null || exit 1 ;;
  *check-runs/*/annotations*) i="\${p#*check-runs/}"; cat "\$d/ann-\${i%%/*}.json" 2>/dev/null || exit 1 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/gh"
# replay [VAR=val ...] -- [args] — the real replay in the scratch repo; sets RC OUT
replay() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" != -- ] || shift
  OUT=$(cd "$T" && env -u CI_SUITES_PER_SHARD -u CI_MAX_SHARDS -u CI_FULL_TRIGGERS -u CI_QUARANTINE \
          REPLAY_GH="$T/gh" ${envs[@]+"${envs[@]}"} bash "$REPLAY" "$@" 2>&1); RC=$?
}
row() { awk -F'\t' -v d="$1" '$1 == d' "$2" 2>/dev/null; }
# col <draft> <name> <tsv> — a column by its header name
col() { awk -F'\t' -v d="$1" -v c="$2" 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == c) k = i; next } $1 == d && k { print $k }' "$3" 2>/dev/null; }

# ── R1. three drafts, one caught-batch, one full fire.
replay -- --last 20 --repo o/r --out "$T/r1.tsv"
[ "$RC" = 0 ] && ok || bad "R1: the replay must be rc 0 (rc=$RC) [$OUT]"
[ "$(grep -c . "$T/r1.tsv" 2>/dev/null)" = 4 ] && ok || bad "R1: one header and 3 rows expected: [$(cat "$T/r1.tsv" 2>/dev/null)]"
[ "$(awk -F'\t' 'NR > 1 { printf "%s ", $1 }' "$T/r1.tsv" 2>/dev/null)" = "903 902 901 " ] && ok || bad "R1: rows must be newest first: [$(cut -f1 "$T/r1.tsv" 2>/dev/null | paste -sd' ')]"
[ -z "$(row 900 "$T/r1.tsv")" ] && ok || bad "R1: a human PR is not a draft"
[ "$(col 902 verdict "$T/r1.tsv")" = caught-batch ] && ok || bad "R1: #902's tests/foo-x-test.sh is in the NEW list, so caught-batch: '$(row 902 "$T/r1.tsv")'"
[ "$(col 902 failing "$T/r1.tsv")" = "tests/foo-x-test.sh=caught-batch" ] && ok || bad "R1: #902 failing must name the rc=1 suite only: '$(row 902 "$T/r1.tsv")'"
[ "$(col 903 verdict "$T/r1.tsv")" = - ] && [ "$(col 901 verdict "$T/r1.tsv")" = - ] && ok || bad "R1: a green draft has verdict '-'"
[ "$(col 901 new_mode "$T/r1.tsv")" = full ] && [ "$(col 901 new_escalation "$T/r1.tsv")" = "selection input: .mergify.yml" ] && ok \
  || bad "R1: #901 (.mergify.yml) must plan full: '$(row 901 "$T/r1.tsv")'"
[ "$(col 902 new_mode "$T/r1.tsv")" = batch-selected ] && [ "$(col 902 new_count "$T/r1.tsv")" = 2 ] && [ "$(col 902 new_n "$T/r1.tsv")" = 1 ] && ok \
  || bad "R1: #902 must plan batch-selected, 2 suites, 1 shard: '$(row 902 "$T/r1.tsv")'"
[ "$(col 901 old_mode "$T/r1.tsv")" = full ] && [ "$(col 901 old_count "$T/r1.tsv")" = 5 ] && [ "$(col 901 old_wall_min "$T/r1.tsv")" = 20.0 ] \
  && [ "$(col 902 old_shard_mean_min "$T/r1.tsv")" = 35.0 ] && ok \
  || bad "R1: the old answer must come from the notice and the run times: '$(row 901 "$T/r1.tsv")' '$(row 902 "$T/r1.tsv")'"
[ "$(col 902 status "$T/r1.tsv")" = ok ] && ok || bad "R1: #902 must be readable: '$(row 902 "$T/r1.tsv")'"
has "full fires: 1 of 3" "$OUT" && ok || bad "R1: the summary must say 'full fires: 1 of 3' [$OUT]"
has "row .mergify.yml fires 1" "$OUT" && ok || bad "R1: the .mergify.yml row must fire once [$OUT]"
has "median wall (min): old 40.0 over 3" "$OUT" && ok || bad "R1: the old median wall must be 40.0 [$OUT]"
[ "$(sed -n 1p "$T/r1.tsv" | cut -f1)" = draft ] && ok || bad "R1: the first TSV row must be the header"
grep -qv '^repos/o/r/\(pulls\|compare\|actions\|check-runs\)' "$FX/asked" && bad "R1: the replay asked GitHub for something else: $(grep -v '^repos/o/r/\(pulls\|compare\|actions\|check-runs\)' "$FX/asked" | head -3)" || ok

# ── R1b. a 300-file compare is unreadable, never planned.
replay STUB_BIG="$H2" -- --repo o/r --out "$T/r1b.tsv"
[ "$RC" = 0 ] && [ "$(col 902 status "$T/r1b.tsv")" = unreadable ] && ok \
  || bad "R1b: a 300-file compare must be an unreadable row, rc 0 (rc=$RC): '$(row 902 "$T/r1b.tsv")'"
[ "$(col 902 verdict "$T/r1b.tsv")" = unreadable ] && [ "$(col 902 new_mode "$T/r1b.tsv")" = - ] && ok \
  || bad "R1b: an unreadable row carries no NEW answer and no verdict guess: '$(row 902 "$T/r1b.tsv")'"
has "full fires: 1 of 2 (unreadable 1)" "$OUT" && ok || bad "R1b: the summary must count readable rows only [$OUT]"

# ── R2. the route fragment: the regression row makes the builder gate run it.
replay STUB_SET=r2 -- --repo o/r --out "$T/r2.tsv"
[ "$RC" = 0 ] && ok || bad "R2: rc 0 expected (rc=$RC) [$OUT]"
[ "$(col 906 failing "$T/r2.tsv")" = "tests/route-keyed-merge.bh-5788-test.sh=caught-pr" ] && ok \
  || bad "R2: tests/route-keyed-merge.bh-5788-test.sh must be caught-pr: '$(row 906 "$T/r2.tsv")'"
[ "$(col 906 verdict "$T/r2.tsv")" = caught-pr ] && ok || bad "R2: #906's verdict must be caught-pr: '$(row 906 "$T/r2.tsv")'"

# ── R3. moved-nightly, missed, lint steps, an unreadable shard log.
f905=$(col 905 failing "$T/r2.tsv")
for want in "tests/nightly-y-test.sh=moved-nightly" "tests/other-z-test.sh=missed" \
            "lint:Syntax + shellcheck + config integrity/shellcheck (errors only)=caught-pr" "lint:Test determinism lint/determinism lint=moved-nightly"; do
  has "$want" "$f905" && ok || bad "R3: #905 failing must carry '$want': '$f905'"
done
[ "$(col 905 verdict "$T/r2.tsv")" = missed ] && ok || bad "R3: one missed culprit makes the draft missed: '$(row 905 "$T/r2.tsv")'"
[ "$(col 904 status "$T/r2.tsv")" = unreadable ] && [ "$(col 904 verdict "$T/r2.tsv")" = unreadable ] && ok \
  || bad "R3: a shard log that cannot be read makes the row unreadable: '$(row 904 "$T/r2.tsv")'"
has "verdicts: caught-batch 0, caught-pr 1, moved-nightly 0, missed 1" "$OUT" && ok || bad "R3: the verdict summary [$OUT]"

# ── R4. an unreadable draft list and a bad argument are rc 2.
replay STUB_LIST_FAIL=1 -- --repo o/r
[ "$RC" = 2 ] && ok || bad "R4: an unreadable draft list must be rc 2 (rc=$RC) [$OUT]"
replay -- --last zero --repo o/r
[ "$RC" = 2 ] && ok || bad "R4: --last zero must be rc 2 (rc=$RC)"

# ── R5. est: no durations is '-'; fixture durations give the slowest shard.
[ "$(col 902 new_est_min "$T/r1.tsv")" = - ] && ok || bad "R5: with no durations est must be '-': '$(row 902 "$T/r1.tsv")'"
cat > "$T/durations" <<'EOF'
#!/bin/bash
# a stub of `bin/ci-durations.sh fetch --out <f>`: fixture weights, source api
out=""; while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; shift; done
printf '# source: api\ntests/always-a-test.sh\t60\t1\ntests/foo-x-test.sh\t120\t1\ntests/route-keyed-merge.bh-5788-test.sh\t30\t1\n' > "$out"
EOF
chmod +x "$T/durations"
replay REPLAY_DURATIONS="$T/durations" -- --repo o/r --out "$T/r5.tsv"
[ "$(col 902 new_est_min "$T/r5.tsv")" = 3.0 ] && ok || bad "R5: #902's est must be (60 + 120) s on one shard = 3.0: '$(row 902 "$T/r5.tsv")'"
has "durations: api" "$OUT" && ok || bad "R5: the summary must name the durations source [$OUT]"
sed 's/source: api/source: seed fixture/' "$T/durations" > "$T/durations-seed"; chmod +x "$T/durations-seed"
replay REPLAY_DURATIONS="$T/durations-seed" -- --repo o/r --out "$T/r5s.tsv"
[ "$(col 902 new_est_min "$T/r5s.tsv")" = - ] && ok || bad "R5: a seed fallback is not a fetch, so est must be '-': '$(row 902 "$T/r5s.tsv")'"

# ── R6. a stacked draft escalates on its own diff only.
replay STUB_SET=r3 -- --repo o/r --out "$T/r6.tsv"
[ "$RC" = 0 ] && [ "$(col 908 planned_on "$T/r6.tsv")" = own ] && [ "$(col 908 new_mode "$T/r6.tsv")" = batch-selected ] && ok \
  || bad "R6: #908 (inherited .mergify.yml) must be planned on its own diff and select (rc=$RC): '$(row 908 "$T/r6.tsv")'"
has "lower bound" "$(col 908 note "$T/r6.tsv")" && ok || bad "R6: an own-diff plan must say its count is a lower bound: '$(row 908 "$T/r6.tsv")'"
[ "$(col 907 planned_on "$T/r6.tsv")" = full ] && [ "$(col 907 new_mode "$T/r6.tsv")" = full ] && ok \
  || bad "R6: #907 (own .mergify.yml) must stay full on the whole diff: '$(row 907 "$T/r6.tsv")'"
has "full fires: 1 of 2" "$OUT" && ok || bad "R6: one stacked draft still fires full [$OUT]"

echo "ci-plan-split-replay.bh-6838-test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
