#!/bin/bash
# tests/ci-plan-split-replay-speed.bh-6876-test.sh — bin/ci-plan-split-replay.sh
# reports what the slowdown is made of (BH-6876, comment 6197071504 item 3):
# the corpus size at HEAD, the source of the fetched weights, and how much
# slower the suites run now than in the seed (the file's last committed copy).
#
#   V1  seed a=10 b=20 c=30, fetched a=20 b=40 c=90: `speed: median 2.00x over
#       3 re-measured suites; 0 of 3 shared rows carry the seed value (now vs
#       seed <sha12>)` and `speed-top20: median 2.00x over 3 re-measured`;
#       `weights source: api`
#   V2  `corpus: <n> suites at <sha12>` counts tests/*.sh + tests/mc/*.sh at
#       HEAD (not tests/lib/), and names HEAD
#   V3  a fetched file under `# source: seed ...`: `weights source: seed` and
#       `speed: - (weights are the seed)`
#   V4  no seed in the git history: `speed: - (no seed)`
#   V5  a row carried forward byte for byte (the seed's seconds AND run) is not
#       a measurement. Fetched a=10/9001 (the seed's row), b=40/9002,
#       c=90/9002: `speed: median 2.50x over 2 re-measured suites; 1 of 3
#       shared rows carry the seed value` (lead review lr-6997: a carried row
#       is 1.00x by construction and says nothing about runner speed)
#   V6  every shared row carries the seed value: `speed: - (0 of 3 shared rows
#       re-measured; all carry the seed value)` and `speed-top20: - (none of
#       the 20 heaviest seed suites re-measured)`
#
# The REAL replay and planner run in a scratch repo; GitHub is a stub of
# `gh api <path>` over fixture files and the fetch is a stub that writes the
# file. No case reads the network, the clock or the box.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
REPLAY_SRC="$DIR/bin/ci-plan-split-replay.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
line() { printf '%s\n' "$2" | grep "^$1" | head -1; }

# mkrepo <dir> <with-seed 0|1> — the scratch checkout the replay runs from.
mkrepo() {
  local G="$1" s
  mkdir -p "$G/catalog" "$G/tests/lib" "$G/tests/mc" "$G/.github/workflows"
  for s in bin/ci-plan-split-replay.sh bin/ci-plan.sh bin/test-impact.sh bin/test-tiers.sh bin/ci-durations.sh; do
    ( cd "$DIR" && scratch_install_closure "$s" "$G" ) > /dev/null || { echo "FAIL: cannot install $s's closure"; exit 1; }
  done
  cp "$DIR/catalog/ci-batch-escalate.tsv" "$G/catalog/" && cp "$DIR/tests/lib/scratch.sh" "$G/tests/lib/" \
    || { echo "FAIL: fixture copy"; exit 1; }
  printf 'tests/always-a-test.sh\n' > "$G/catalog/test-impact-always.txt"
  printf '# a scratch tier file\n' > "$G/catalog/test-tiers.tsv"
  printf '#!/bin/bash\necho foo\n' > "$G/bin/foo.sh"
  printf '#!/bin/bash\n. "$(dirname "$0")/lib/scratch.sh" || exit 1\n' > "$G/tests/always-a-test.sh"
  printf '#!/bin/bash\n. "$(dirname "$0")/lib/scratch.sh" || exit 1\nbash "$DIR/bin/foo.sh"\n' > "$G/tests/foo-x-test.sh"
  printf '#!/bin/bash\n. "$(dirname "$0")/../lib/scratch.sh" || exit 1\n' > "$G/tests/mc/one-test.sh"
  printf 'name: Harness CI\njobs: {}\n' > "$G/.github/workflows/harness-ci.yml"
  git -C "$G" init -q || exit 1
  if [ "$2" = 1 ]; then
    printf 'tests/a-test.sh\t10.0\t9001\ntests/b-test.sh\t20.0\t9001\ntests/c-test.sh\t30.0\t9001\n' > "$G/catalog/ci-suite-durations.tsv"
    git -C "$G" add -A && git -C "$G" -c user.email=t@example.invalid -c user.name=t commit -qm "fixture: the seed" || exit 1
    git -C "$G" rm -q catalog/ci-suite-durations.tsv \
      && git -C "$G" -c user.email=t@example.invalid -c user.name=t commit -qm "fixture: the seed leaves git" || exit 1
  else
    git -C "$G" add -A && git -C "$G" -c user.email=t@example.invalid -c user.name=t commit -qm fixture || exit 1
  fi
}

FX="$T/fx"; mkdir -p "$FX"
B=$(printf 'b%039d' 1); H=$(printf 'a%039d' 1)
jq -nc --arg b "$B" --arg h "$H" '[{number: 901, title: "merge queue: embarking #11 together", body: "fixture", labels: [],
  user: {login: "mergify[bot]"}, base: {sha: $b}, head: {sha: $h, ref: "mergify/merge-queue/901"}}]' > "$FX/pulls.json"
jq -nc '{files: [{filename: "bin/foo.sh"}]}' > "$FX/cmp.json"
jq -nc '{workflow_runs: [{id: 1, name: "Harness CI", conclusion: "success",
  run_started_at: "2026-10-13T10:00:00Z", updated_at: "2026-10-13T10:20:00Z"}]}' > "$FX/runs.json"
jq -nc '{jobs: []}' > "$FX/jobs.json"
cat > "$T/gh" <<EOF
#!/bin/bash
[ "\$1" = api ] || exit 9
case "\$2" in
  *pulls\?*page=1) cat "$FX/pulls.json" ;;
  *pulls\?*) echo '[]' ;;
  */pulls/[0-9]*) echo '{"number": 11, "labels": []}' ;;
  *compare/*) cat "$FX/cmp.json" ;;
  *actions/runs\?*) cat "$FX/runs.json" ;;
  *actions/runs/*/jobs*) cat "$FX/jobs.json" ;;
  *) exit 1 ;;
esac
EOF
# mkfetch <path> <header> — a stub `ci-durations.sh fetch` that writes a=20 b=40 c=90.
mkfetch() {
  cat > "$1" <<EOF
#!/bin/bash
out=""; while [ \$# -gt 0 ]; do [ "\$1" = --out ] && out="\$2"; shift; done
printf '%s\ntests/a-test.sh\t20.0\t9001\t20.0\ntests/b-test.sh\t40.0\t9001\t40.0\ntests/c-test.sh\t90.0\t9001\t90.0\n' '$2' > "\$out"
EOF
  chmod +x "$1"
}
mkfetch "$T/fetch-api" '# source: api'
mkfetch "$T/fetch-seed" '# source: seed 0123456789abcdef0123456789abcdef01234567'
# mkfetch_rows <path> <printf rows> — a stub fetch: `# source: api`, then <rows>.
mkfetch_rows() {
  cat > "$1" <<EOF
#!/bin/bash
out=""; while [ \$# -gt 0 ]; do [ "\$1" = --out ] && out="\$2"; shift; done
printf '# source: api\n$2' > "\$out"
EOF
  chmod +x "$1"
}
mkfetch_rows "$T/fetch-mixed" 'tests/a-test.sh\t10.0\t9001\ntests/b-test.sh\t40.0\t9002\t40.0\ntests/c-test.sh\t90.0\t9002\t90.0\n'
mkfetch_rows "$T/fetch-carried" 'tests/a-test.sh\t10.0\t9001\ntests/b-test.sh\t20.0\t9001\ntests/c-test.sh\t30.0\t9001\n'
chmod +x "$T/gh"

replay() { # replay <repo> <fetch> — the real replay; sets RRC ROUT
  ROUT=$(cd "$T" && env -u CI_SUITES_PER_SHARD -u CI_MAX_SHARDS -u CI_SHARD_BUDGET_S -u CI_FULL_TRIGGERS -u CI_QUARANTINE \
    REPLAY_GH="$T/gh" REPLAY_DURATIONS="$2" bash "$1/bin/ci-plan-split-replay.sh" --repo o/r 2>&1); RRC=$?
}

mkrepo "$T/seeded" 1
SEED12=$(git -C "$T/seeded" log -1 --format=%H --diff-filter=D -- catalog/ci-suite-durations.tsv | cut -c1-12)
HEAD12=$(git -C "$T/seeded" rev-parse HEAD | cut -c1-12)
[ -n "$SEED12" ] && [ "$SEED12" = "$HEAD12" ] || bad "fixture: the seed commit is HEAD ($SEED12 vs $HEAD12)"

# ── V1. the speed ratio against the seed.
replay "$T/seeded" "$T/fetch-api"
[ "$RRC" = 0 ] && ok || bad "V1: the replay must be rc 0 (rc=$RRC) [$ROUT]"
V1S="speed: median 2.00x over 3 re-measured suites; 0 of 3 shared rows carry the seed value (now vs seed $SEED12)"
[ "$(line 'speed: ' "$ROUT")" = "$V1S" ] && ok || bad "V1: '$V1S' expected: '$(line 'speed: ' "$ROUT")'"
[ "$(line 'speed-top20: ' "$ROUT")" = "speed-top20: median 2.00x over 3 re-measured" ] && ok || bad "V1: speed-top20: median 2.00x over 3 re-measured expected: '$(line 'speed-top20: ' "$ROUT")'"
[ "$(line 'weights source: ' "$ROUT")" = "weights source: api" ] && ok || bad "V1: weights source: api expected: '$(line 'weights source: ' "$ROUT")'"

# ── V2. the corpus at HEAD: tests/*.sh + tests/mc/*.sh, never tests/lib/.
[ "$(line 'corpus: ' "$ROUT")" = "corpus: 3 suites at $HEAD12" ] && ok || bad "V2: corpus: 3 suites at $HEAD12 expected: '$(line 'corpus: ' "$ROUT")'"
# A suite added on disk but not committed is not in HEAD's corpus.
printf '#!/bin/bash\n' > "$T/seeded/tests/uncommitted-test.sh"
replay "$T/seeded" "$T/fetch-api"
[ "$(line 'corpus: ' "$ROUT")" = "corpus: 3 suites at $HEAD12" ] && ok || bad "V2: the corpus is HEAD's tree, not the disk: '$(line 'corpus: ' "$ROUT")'"
rm -f "$T/seeded/tests/uncommitted-test.sh"

# ── V3. the fetch fell back to the seed: no ratio of the seed against itself.
replay "$T/seeded" "$T/fetch-seed"
[ "$RRC" = 0 ] && ok || bad "V3: the replay must be rc 0 (rc=$RRC) [$ROUT]"
[ "$(line 'weights source: ' "$ROUT")" = "weights source: seed" ] && ok || bad "V3: weights source: seed expected: '$(line 'weights source: ' "$ROUT")'"
[ "$(line 'speed: ' "$ROUT")" = "speed: - (weights are the seed)" ] && ok || bad "V3: speed: - (weights are the seed) expected: '$(line 'speed: ' "$ROUT")'"
[ "$(line 'speed-top20: ' "$ROUT")" = "speed-top20: - (weights are the seed)" ] && ok || bad "V3: speed-top20 says why too: '$(line 'speed-top20: ' "$ROUT")'"

# ── V4. no seed anywhere in the history.
mkrepo "$T/unseeded" 0
replay "$T/unseeded" "$T/fetch-api"
[ "$RRC" = 0 ] && ok || bad "V4: the replay must be rc 0 (rc=$RRC) [$ROUT]"
[ "$(line 'speed: ' "$ROUT")" = "speed: - (no seed)" ] && ok || bad "V4: speed: - (no seed) expected: '$(line 'speed: ' "$ROUT")'"
[ "$(line 'weights source: ' "$ROUT")" = "weights source: api" ] && ok || bad "V4: weights source: api expected: '$(line 'weights source: ' "$ROUT")'"

# ── V5. a row carried forward byte for byte is not a measurement.
replay "$T/seeded" "$T/fetch-mixed"
[ "$RRC" = 0 ] && ok || bad "V5: the replay must be rc 0 (rc=$RRC) [$ROUT]"
V5S="speed: median 2.50x over 2 re-measured suites; 1 of 3 shared rows carry the seed value (now vs seed $SEED12)"
[ "$(line 'speed: ' "$ROUT")" = "$V5S" ] && ok || bad "V5: '$V5S' expected: '$(line 'speed: ' "$ROUT")'"
[ "$(line 'speed-top20: ' "$ROUT")" = "speed-top20: median 2.50x over 2 re-measured" ] && ok \
  || bad "V5: speed-top20: median 2.50x over 2 re-measured expected: '$(line 'speed-top20: ' "$ROUT")'"

# ── V6. every shared row is the seed's own row: no ratio at all.
replay "$T/seeded" "$T/fetch-carried"
[ "$RRC" = 0 ] && ok || bad "V6: the replay must be rc 0 (rc=$RRC) [$ROUT]"
[ "$(line 'speed: ' "$ROUT")" = "speed: - (0 of 3 shared rows re-measured; all carry the seed value)" ] && ok \
  || bad "V6: speed: - (0 of 3 shared rows re-measured; all carry the seed value) expected: '$(line 'speed: ' "$ROUT")'"
[ "$(line 'speed-top20: ' "$ROUT")" = "speed-top20: - (none of the 20 heaviest seed suites re-measured)" ] && ok \
  || bad "V6: speed-top20 says why: '$(line 'speed-top20: ' "$ROUT")'"

echo "ci-plan-split-replay-speed.bh-6876: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
