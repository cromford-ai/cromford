#!/bin/bash
# tests/ci-batch-red-causes.bh-9410-test.sh — `bin/ci-batch-red-report.sh
# --causes` and the tick line's `causes=` field (BH-9410), driven against a
# scratch harness. Every fixture is written in its real writer's format:
#   batch records        the report's step 4 head line + fail/gate TAB lines
#   eject-cause lines    bin/lib/mc-eject-cause.sh ec_record's printf
#   gate.txt             bin/selection-gate.sh write_gate (10 lines + 2 baseline)
#   baseline / prime.tsv bin/selection-gate.sh baseline_pass, selection-gate-prime
#   ci-batches JSON      GET /api/ci-batches (rows[].run_id, billed_min, truncated)
#   random catalog       catalog/ci-batch-red-random.d/*.tsv (match, test_file,
#                        settings_row, since_iso, until_iso|-, ref)
# The jobs client is a scratch stub whose _jobs_req serves fixture JSON and logs
# each call. A PATH `curl` writes a marker and exits 1. The PATH `gh` logs each
# call and serves only an empty run list (the tick case). Time is pinned (NOW).
# Each case resets its own fixture tree.
#
# CASES (plan "Acceptance tests"): C-each, C-unknown, C-near, C-cnr, C-newhead,
# C-cli, C-minutes, C-nonet, C-nowrite, C-line, C-knob, C-empty, C-nolib,
# C-random (R1-R10, the seeded-random cause), C-catalog (the committed catalog).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=1791000000
REPO=example-org/cromford
TAB=$(printf '\t')
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

HH="$T/h"
mkdir -p "$HH/bin/lib" "$HH/logs" "$T/path"
# Stubs first: scratch_install_closure never clobbers a file already there.
cat > "$HH/bin/lib/lane-gate.sh" <<'SH'
lane_gate_or_exit() { :; }
lane_env_apply() { :; }
lane_knob() { printf '%s' "${!2:-}"; }
SH
cat > "$HH/bin/lib/gh-budget.sh" <<'SH'
gh_budget_low() { return 1; }
SH
cat > "$HH/bin/lib/gh-repo-token.sh" <<'SH'
gh_repo_use_token() { return 0; }
SH
# The jobs seam: a local fake, 0 network calls.
cat > "$HH/bin/jobs-client.sh" <<'SH'
jobs_configured() { [ -n "${JOBS_URL:-}" ]; }
_jobs_req() {
  echo "$1 $2" >> "$HARNESS/jobs-calls.txt"
  [ "${FAKE_JOBS_RC:-0}" = 0 ] || return 1
  cat "$HARNESS/fx/ci-batches.json"
}
SH
# The STUB client above, not the real one (no modules to carry); saved by
# content so the jobs-client-modules fixture rule does not read it as a copy
# of bin/jobs-client.sh.
cat "$HH/bin/jobs-client.sh" > "$T/jobs-client.sh"
cat > "$T/path/curl" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/curl-called"
exit 1
SH
cat > "$T/path/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/gh-calls.txt"
for a in "$@"; do
  case "$a" in
    repos/*/actions/workflows/harness-ci.yml/runs) echo '{"total_count":0,"workflow_runs":[]}'; exit 0 ;;
  esac
done
exit 1
SH
chmod +x "$T/path/curl" "$T/path/gh"
scratch_install_closure bin/ci-batch-red-report.sh "$HH" >/dev/null \
  || { echo "FAIL: cannot install the lane closure (bin/ci-batch-red-report.sh)"; echo "ci-batch-red-causes: 0 passed, 1 failed"; exit 1; }
# The closure carries the cause lib (bin/lib/ci-batch-red-causes.sh), sourced by the report.
[ -f "$HH/bin/lib/ci-batch-red-causes.sh" ] && ok || bad "closure: bin/lib/ci-batch-red-causes.sh was not installed"
LIBF="$HH/bin/lib/ci-batch-red-causes.sh"

REC="$HH/state/ci-batch-red/runs"
EJ="$HH/state/merge-conductor/eject-cause"
BL="$HH/state/selection-gate/baseline"
LOG="$HH/logs/ci-batch-red.log"
hd() { printf '%08x%032d' "$1" 0; }               # a 40-hex head for PR/head n
c_of() { echo $(( NOW - $1 * 3600 )); }            # the created epoch of the batch k hours old
reset() {
  local p; for p in state builds fx logs jobs-calls.txt gh-calls.txt curl-called; do scratch_rm "$HH/$p"; done
  mkdir -p "$HH/fx" "$HH/logs"
  echo '{"rows":[],"truncated":false}' > "$HH/fx/ci-batches.json"
}
recw() { # recw <id> <created> <red|green> <tree> <prs> [unread] — body lines on stdin
  mkdir -p "$REC"
  { echo "run $1 attempt 1 created $2 concl $3 tree $4 prs $5${6:+ $6}"; cat; } > "$REC/$1"
}
F() { printf 'fail\t%s\t%s\n' "$1" "${2:-1}"; }
ej() { # ej <pr> <epoch> <head> <first|again> <cause> — ec_record's line
  mkdir -p "$EJ"
  printf '%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" "detail" >> "$EJ/example-org_cromford_$1"
}
gt() { # gt <build> <head> <rc> <red csv|-> <baseline-red csv|-> <mtime> [selection suite...]
  local d="$HH/builds/cromford-BH-$1-202611100000" h="$2" rc="$3" red="$4" br="$5" mt="$6"; shift 6
  mkdir -p "$d"
  printf 'head: %s\nbase: %s\nsuites: %s\nrc: %s\nred: %s\nnoted: -\nmode: impact\nwhy: -\nquarantine: read\nhost-noted: -\n' \
    "$h" "$(hd 999)" "$#" "$rc" "$red" > "$d/gate.txt"
  printf 'baseline-red: %s\nbaseline: ran 1 on %s (0 cached)\n' "$br" "$(hd 999 | cut -c1-12)" >> "$d/gate.txt"
  if [ $# -gt 0 ]; then mkdir -p "$d/selection-gate"; printf '%s\n' "$@" > "$d/selection-gate/selection.txt"; fi
  touch -d "@$mt" "$d/gate.txt"
}
bl() { # bl <sha> <dir mtime> <suite> <red|green> — the baseline cache file
  mkdir -p "$BL/$1"; printf '%s\n' "$4" > "$BL/$1/${3//\//_}"; touch -d "@$2" "$BL/$1"
}
drive() { # drive [ENV=val...] [-- args...]
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  ( export HARNESS="$HH" NOW PATH="$T/path:$PATH" CI_BATCH_RED_REPO="$REPO" JOBS_URL=http://jobs.invalid HARNESS_SECRET=x
    [ ${#envs[@]} -gt 0 ] && export "${envs[@]}"
    bash "$HH/bin/ci-batch-red-report.sh" "$@" ) >"$T/out.txt" 2>"$T/err.txt"
  RC=$?
}
causes() { drive "$@" -- --causes --days 7; }
row() { awk -F'\t' -v r="$1" '$1 == r' "$T/out.txt"; }
cause_of() { row "$1" | cut -f4; }
culprit_of() { row "$1" | cut -f3; }
lastlog() { tail -1 "$LOG" 2>/dev/null; }

# ── C-each: one batch per cause, plus a green record
each_fixture() {
  reset
  local c
  # 1 main-red: a-test red on main 1800 s before the batch
  c=$(c_of 60); F tests/a-test.sh | recw 1 "$c" red t1 1
  ej 1 $(( c + 1800 )) "$(hd 1)" first batch-red
  bl "$(hd 901)" $(( c - 1800 )) tests/a-test.sh red
  # 2 flake: a green record has the same tree (and a gate that would say gate-green)
  c=$(c_of 50); F tests/b-test.sh | recw 2 "$c" red tflake 2
  : | recw 90 $(( c + 600 )) green tflake 9
  ej 2 $(( c + 1800 )) "$(hd 2)" first checks
  gt 2 "$(hd 2)" 0 - - $(( c - 20000 )) tests/b-test.sh
  # 3 unchanged-requeue: the culprit's eject line is `again`
  c=$(c_of 40); F tests/c-test.sh | recw 3 "$c" red t3 3
  ej 3 $(( c + 1800 )) "$(hd 3)" again batch-red
  gt 3 "$(hd 3)" 0 - - $(( c - 20000 )) tests/c-test.sh
  # 4 first-run: no gate.txt for the culprit head (one for another head of the PR)
  c=$(c_of 30); F tests/d-test.sh | recw 4 "$c" red t4 4
  ej 4 $(( c + 1800 )) "$(hd 4)" first batch-red
  gt 40 "$(hd 40)" 0 - - $(( c - 20000 )) tests/d-test.sh
  # 5 gate-green-batch-red: rc 0, the selection lists the suite
  c=$(c_of 20); F tests/e-test.sh | recw 5 "$c" red t5 5
  ej 5 $(( c + 1800 )) "$(hd 5)" first batch-red
  gt 5 "$(hd 5)" 0 - - $(( c - 20000 )) tests/e-test.sh tests/z-test.sh
  # 6 unknown: no eject line, no gate line, no gate.txt
  c=$(c_of 10); F tests/f-test.sh | recw 6 "$c" red t6 6
  # 7 seeded-random: the only failing entry is a job named by the catalog in
  # the report's default dir ($H/catalog, as the scratch closure carries none)
  mkdir -p "$HH/catalog/ci-batch-red-random.d"
  printf 'job:Seeded job\tworker/x.test.js\tx.sample_pct\t2020-01-01T00:00:00Z\t-\tfixture\n' \
    > "$HH/catalog/ci-batch-red-random.d/fx.tsv"
  c=$(c_of 5); F "job:Seeded job" other | recw 7 "$c" red t7 7
}
each_fixture
causes
[ "$RC" = 0 ] && ok || bad "C-each: rc 0, got $RC: $(cat "$T/out.txt")"
for want in 1:main-red 2:flake 3:unchanged-requeue 4:first-run 5:gate-green-batch-red 6:unknown 7:seeded-random; do
  [ "$(cause_of "${want%%:*}")" = "${want#*:}" ] && ok || bad "C-each: run ${want%%:*} is ${want#*:}: '$(row "${want%%:*}")'"
done
[ "$(culprit_of 1)" = "1@$(hd 1 | cut -c1-12)" ] && [ "$(culprit_of 5)" = "5@$(hd 5 | cut -c1-12)" ] && ok \
  || bad "C-each: culprit <pr>@<head12>: '$(row 1)' '$(row 5)'"
[ "$(row 4 | cut -f5)" = tests/d-test.sh ] && ok || bad "C-each: the suites column: '$(row 4)'"
# ── C-unknown: no evidence is unknown with culprit -, never a guess
[ "$(culprit_of 6)" = - ] && [ "$(cause_of 6)" = unknown ] && ok || bad "C-unknown: '$(row 6)'"
[ -z "$(row 90)" ] && ok || bad "C-each: a green record has no row"

# ── C-cli: the header, the column header, the 7 summary rows in order, sums
head -1 "$T/out.txt" | grep -qx "ci-batch-red-causes: repo=$REPO days=7 red=7 minutes=read minutes_missing=7" && ok \
  || bad "C-cli: the header line: $(head -1 "$T/out.txt")"
grep -qx "run_id${TAB}created${TAB}culprit${TAB}cause${TAB}suites${TAB}minutes" "$T/out.txt" && ok || bad "C-cli: the column header"
[ "$(sed -n '/^cause\tbatches\trunner_minutes$/,$p' "$T/out.txt" | sed 1d | cut -f1 | paste -sd' ' -)" \
  = "main-red seeded-random first-run gate-green-batch-red flake unchanged-requeue unknown" ] && ok \
  || bad "C-cli: the 7 summary rows in the fixed order: $(cat "$T/out.txt")"
[ "$(sed -n '/^cause\tbatches/,$p' "$T/out.txt" | sed 1d | awk -F'\t' '{s += $2} END {print s}')" = 7 ] && ok \
  || bad "C-cli: the batch counts sum to red="
[ "$(sed -n '/^run_id\t/,/^cause\t/p' "$T/out.txt" | sed '1d;$d' | cut -f1 | paste -sd, -)" = "1,2,3,4,5,6,7" ] && ok \
  || bad "C-cli: one row per red batch, oldest first"

# ── C-nowrite: --causes leaves state/ and logs/ byte-identical
snap() { (cd "$HH" && find state logs -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 -r stat -c '%n %s %Y' ; \
          find state logs -type f -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 -r md5sum); }
snap > "$T/snap1"; causes; snap > "$T/snap2"
cmp -s "$T/snap1" "$T/snap2" && ok || bad "C-nowrite: --causes changed state/ or logs/: $(diff "$T/snap1" "$T/snap2")"
[ ! -s "$LOG" ] && ok || bad "C-nowrite: no log line"

# ── C-minutes
jq -n '{rows: [{run_id: 1, billed_min: 100}, {run_id: 2, billed_min: 50}, {run_id: 3, billed_min: 30},
               {run_id: 4, billed_min: 20}, {run_id: 5, billed_min: 7}, {run_id: 99, billed_min: 1000}], truncated: false}' \
  > "$HH/fx/ci-batches.json"
causes
head -1 "$T/out.txt" | grep -q " red=7 minutes=read minutes_missing=2$" && ok || bad "C-minutes: 5 of 7 known: $(head -1 "$T/out.txt")"
grep -qx "main-red${TAB}1${TAB}100" "$T/out.txt" && grep -qx "gate-green-batch-red${TAB}1${TAB}7" "$T/out.txt" \
  && grep -qx "unknown${TAB}1${TAB}0" "$T/out.txt" && ok || bad "C-minutes: the sums: $(cat "$T/out.txt")"
[ "$(row 1 | cut -f6)" = 100 ] && [ "$(row 6 | cut -f6)" = - ] && ok || bad "C-minutes: the minutes column: '$(row 1)' '$(row 6)'"
causes FAKE_JOBS_RC=1
[ "$RC" = 0 ] && head -1 "$T/out.txt" | grep -q " minutes=unreadable minutes_missing=7$" && grep -qx "main-red${TAB}1${TAB}0" "$T/out.txt" && ok \
  || bad "C-minutes: _jobs_req fails = unreadable, rc 0: $(head -1 "$T/out.txt")"
jq '.truncated = true' "$HH/fx/ci-batches.json" > "$T/cb" && cp "$T/cb" "$HH/fx/ci-batches.json"
causes
head -1 "$T/out.txt" | grep -q " minutes=unreadable minutes_missing=7$" && ok || bad "C-minutes: truncated = unreadable: $(head -1 "$T/out.txt")"
causes JOBS_URL=
head -1 "$T/out.txt" | grep -q " minutes=not-configured minutes_missing=7$" && ok || bad "C-minutes: no JOBS_URL = not-configured: $(head -1 "$T/out.txt")"
rm -f "$HH/bin/jobs-client.sh"
causes
[ "$RC" = 0 ] && head -1 "$T/out.txt" | grep -q " minutes=not-configured " && ok || bad "C-minutes: no jobs client = not-configured: $(head -1 "$T/out.txt")"
cat "$T/jobs-client.sh" > "$HH/bin/jobs-client.sh"

# ── C-nonet: no curl, no gh in any --causes run; _jobs_req only GETs ci-batches
[ ! -e "$HH/curl-called" ] && ok || bad "C-nonet: curl was called: $(cat "$HH/curl-called")"
[ ! -e "$HH/gh-calls.txt" ] && ok || bad "C-nonet: gh was called: $(cat "$HH/gh-calls.txt")"
[ -s "$HH/jobs-calls.txt" ] && [ "$(grep -vc '^GET /api/ci-batches?repo=example-org%2Fcromford&since=.*&limit=5000$' "$HH/jobs-calls.txt")" = 0 ] && ok \
  || bad "C-nonet: _jobs_req calls: $(cat "$HH/jobs-calls.txt" 2>/dev/null)"

# ── C-limit: the ledger row cap is the knob CI_BATCH_RED_LEDGER_LIMIT (1..5000)
rm -f "$HH/jobs-calls.txt"
causes CI_BATCH_RED_LEDGER_LIMIT=250
[ "$(wc -l < "$HH/jobs-calls.txt" 2>/dev/null)" = 1 ] && grep -q '&limit=250$' "$HH/jobs-calls.txt" && ok \
  || bad "C-limit: knob 250: $(cat "$HH/jobs-calls.txt" 2>/dev/null)"
rm -f "$HH/jobs-calls.txt"
causes CI_BATCH_RED_LEDGER_LIMIT=9000
[ "$(wc -l < "$HH/jobs-calls.txt" 2>/dev/null)" = 1 ] && grep -q '&limit=5000$' "$HH/jobs-calls.txt" && ok \
  || bad "C-limit: knob 9000 out of range = 5000: $(cat "$HH/jobs-calls.txt" 2>/dev/null)"

# ── C-line: a normal tick appends causes= with the same counts
rm -f "$HH/jobs-calls.txt"
drive
[ "$RC" = 0 ] && lastlog | grep -q " ignored=0 causes=main-red:1,seeded-random:1,first-run:1,gate-green-batch-red:1,flake:1,unchanged-requeue:1,unknown:1$" && ok \
  || bad "C-line: the tick line: rc=$RC $(lastlog) $(cat "$T/out.txt")"
red=$(lastlog | sed -n 's/.* red=\([0-9]*\) .*/\1/p'); unread=$(lastlog | sed -n 's/.* unread=\([0-9]*\) .*/\1/p')
[ "$(lastlog | sed 's/.*causes=//' | tr ',' '\n' | cut -d: -f2 | awk '{s += $1} END {print s + 0}')" = $(( red - unread )) ] && ok \
  || bad "C-line: the 7 counts sum to the readable red count ($red - $unread): $(lastlog)"
[ ! -e "$HH/jobs-calls.txt" ] && ok || bad "C-line: the tick makes no ci-batches read"

# ── C-near, C-cnr, C-newhead: the negatives (each gives a cause other than its near match)
reset
k=200
nb() { k=$((k + 1)); C=$(c_of $(( 300 - k ))); }   # the next batch, 1 h after the last
# n201 baseline file says green → not main-red
nb; F tests/n201.sh | recw 201 "$C" red t201 201; bl "$(hd 801)" $(( C - 1800 )) tests/n201.sh green
# n202 red, but 9000 s before the batch → not main-red
nb; F tests/n202.sh | recw 202 "$C" red t202 202; bl "$(hd 802)" $(( C - 9000 )) tests/n202.sh red
# n203 red for tests/mc/<same basename> → not main-red
nb; F tests/n203-test.sh | recw 203 "$C" red t203 203; bl "$(hd 803)" $(( C - 1800 )) tests/mc/n203-test.sh red
# n204 prime.tsv red only, its sha dir primed in the window → main-red
nb; F tests/n204.sh | recw 204 "$C" red t204 204
mkdir -p "$BL/$(hd 804)"; touch -d "@$(( C - 1800 ))" "$BL/$(hd 804)/.primed" "$BL/$(hd 804)"
printf '%s\t%s\t%s\n' "$(hd 804)" tests/n204.sh red >> "$HH/state/selection-gate/prime.tsv"
# n205 prime.tsv green → not main-red
nb; F tests/n205.sh | recw 205 "$C" red t205 205
mkdir -p "$BL/$(hd 805)"; touch -d "@$(( C - 1800 ))" "$BL/$(hd 805)"
printf '%s\t%s\t%s\n' "$(hd 805)" tests/n205.sh green >> "$HH/state/selection-gate/prime.tsv"
# n206 a gate.txt in the window whose baseline-red: lists the suite → main-red
nb; F tests/n206.sh | recw 206 "$C" red t206 206; gt 206 "$(hd 1206)" 1 - tests/n206.sh $(( C - 1800 )) tests/n206.sh
# n207 eject cause conflict → no culprit
nb; F tests/n207.sh | recw 207 "$C" red t207 207; ej 207 $(( C + 1800 )) "$(hd 207)" first conflict; gt 207 "$(hd 207)" 0 - - $(( C - 20000 )) tests/n207.sh
# n208 eject line before the batch → no culprit
nb; F tests/n208.sh | recw 208 "$C" red t208 208; ej 208 $(( C - 100 )) "$(hd 208)" first batch-red; gt 208 "$(hd 208)" 0 - - $(( C - 20000 )) tests/n208.sh
# n209 a green record whose tree is `-`, the red tree `-` → not flake
nb; F tests/n209.sh | recw 209 "$C" red - 209; : | recw 299 $(( C + 60 )) green - 9
# n210 an earlier `first` line for the same pr+head → unchanged-requeue
nb; F tests/n210.sh | recw 210 "$C" red t210 210
ej 210 $(( C - 5000 )) "$(hd 210)" first batch-red; ej 210 $(( C + 1800 )) "$(hd 210)" first batch-red
gt 210 "$(hd 210)" 0 - - $(( C - 20000 )) tests/n210.sh
# n211 C-newhead: ejected earlier on head A, now on head B → not requeue (gate-green)
nb; F tests/n211.sh | recw 211 "$C" red t211 211
ej 211 $(( C - 5000 )) "$(hd 2110)" first batch-red; ej 211 $(( C + 1800 )) "$(hd 211)" first batch-red
gt 211 "$(hd 211)" 0 - - $(( C - 20000 )) tests/n211.sh
# n212 C-cnr: the culprit's gate could not run → first-run, never gate-green
nb; F tests/n212.sh | recw 212 "$C" red t212 212; ej 212 $(( C + 1800 )) "$(hd 212)" first batch-red
gt 212 "$(hd 212)" could-not-run - - $(( C - 20000 )) tests/n212.sh
# n213 selection.txt omits the failing suite → first-run
nb; F tests/n213.sh | recw 213 "$C" red t213 213; ej 213 $(( C + 1800 )) "$(hd 213)" first batch-red
gt 213 "$(hd 213)" 0 - - $(( C - 20000 )) tests/other.sh
# n214 rc 1 whose red: names the failing suite → neither first-run nor gate-green
nb; F tests/n214.sh | recw 214 "$C" red t214 214; ej 214 $(( C + 1800 )) "$(hd 214)" first batch-red
gt 214 "$(hd 214)" 1 tests/n214.sh - $(( C - 20000 )) tests/n214.sh
# n215 rc 1 whose red: names another suite → gate-green
nb; F tests/n215.sh | recw 215 "$C" red t215 215; ej 215 $(( C + 1800 )) "$(hd 215)" first batch-red
gt 215 "$(hd 215)" 1 tests/x.sh - $(( C - 20000 )) tests/n215.sh tests/x.sh
# n216 two failing suites, the selection lists one → first-run (both hold; first-run wins)
nb; { F tests/n216a.sh; F tests/n216b.sh; } | recw 216 "$C" red t216 216; ej 216 $(( C + 1800 )) "$(hd 216)" first batch-red
gt 216 "$(hd 216)" 0 - - $(( C - 20000 )) tests/n216a.sh
# n217 no culprit, a legacy gate line lists the suite → gate-green
nb; { F tests/n217.sh; printf 'gate\t217\tgreen\ttests/n217.sh\n'; } | recw 217 "$C" red t217 217
# n218 no culprit, a legacy gate line omits the suite → first-run
nb; { F tests/n218.sh; printf 'gate\t218\tgreen\ttests/z.sh\n'; } | recw 218 "$C" red t218 218
# n219 no culprit, the legacy gate line unreadable → unknown
nb; { F tests/n219.sh; printf 'gate\t219\t?\t-\n'; } | recw 219 "$C" red t219 219
# n220 a job failure only → unknown
nb; F "job:Lint" other | recw 220 "$C" red t220 220; ej 220 $(( C + 1800 )) "$(hd 220)" again batch-red
# n221 an unread record → no row at all
nb; : | recw 221 "$C" red t221 221 unread
causes
[ "$RC" = 0 ] && ok || bad "C-near: rc $RC"
for want in 201:unknown 202:unknown 203:unknown 204:main-red 205:unknown 206:main-red 207:unknown 208:unknown \
            209:unknown 210:unchanged-requeue 211:gate-green-batch-red 212:first-run 213:first-run 214:unknown \
            215:gate-green-batch-red 216:first-run 217:gate-green-batch-red 218:first-run 219:unknown 220:unknown; do
  [ "$(cause_of "${want%%:*}")" = "${want#*:}" ] && ok || bad "C-near: run ${want%%:*} is ${want#*:}: '$(row "${want%%:*}")'"
done
[ "$(culprit_of 207)" = - ] && [ "$(culprit_of 208)" = - ] && [ "$(culprit_of 211)" = "211@$(hd 211 | cut -c1-12)" ] && ok \
  || bad "C-near: culprits: '$(row 207)' '$(row 208)' '$(row 211)'"
[ -z "$(row 221)" ] && head -1 "$T/out.txt" | grep -q " red=20 " && ok || bad "C-unread: an unread record is out of the count: $(head -1 "$T/out.txt")"
[ "$(row 220 | cut -f5)" = "job:Lint" ] && ok || bad "C-near: the job row keeps its suite: '$(row 220)'"

# ── C-knob: an eject line at created+1200 names a culprit at 7200, not at 600
reset
C=$(c_of 5); F tests/k.sh | recw 301 "$C" red t301 301; ej 301 $(( C + 1200 )) "$(hd 301)" first batch-red
causes
[ "$(culprit_of 301)" = "301@$(hd 301 | cut -c1-12)" ] && [ "$(cause_of 301)" = first-run ] && ok || bad "C-knob: default 7200 names the culprit: '$(row 301)'"
causes CI_BATCH_RED_EJECT_WINDOW_S=600
[ "$(culprit_of 301)" = - ] && [ "$(cause_of 301)" = unknown ] && ok || bad "C-knob: 600 drops the culprit: '$(row 301)'"
bl "$(hd 302)" $(( C - 1800 )) tests/k.sh red
causes CI_BATCH_RED_MAINRED_WINDOW_S=600
[ "$(cause_of 301)" = first-run ] && ok || bad "C-knob: MAINRED 600 drops evidence 1800 s old: '$(row 301)'"
causes
[ "$(cause_of 301)" = main-red ] && ok || bad "C-knob: MAINRED 7200 keeps it: '$(row 301)'"

# ── C-empty: no runs dir
reset
causes
[ "$RC" = 0 ] && head -1 "$T/out.txt" | grep -q " red=0 minutes=read minutes_missing=0$" \
  && [ "$(sed -n '/^cause\tbatches/,$p' "$T/out.txt" | sed 1d | grep -c "${TAB}0${TAB}0$")" = 7 ] && ok \
  || bad "C-empty: red=0 and 7 zero rows: $(cat "$T/out.txt")"
drive
lastlog | grep -q " causes=main-red:0,seeded-random:0,first-run:0,gate-green-batch-red:0,flake:0,unchanged-requeue:0,unknown:0$" && ok \
  || bad "C-empty: the tick line with no record: $(lastlog)"
drive -- --causes --dry-run
[ "$RC" = 2 ] && ok || bad "C-cli: --causes with --dry-run is a usage error, got $RC"

# ── C-nolib: the lib absent → causes=- and the rest of the line as before
each_fixture
mv "$LIBF" "$T/causes-lib.off"
drive
lastlog | grep -q " pruned=0 ignored=0 causes=-$" && ok || bad "C-nolib: causes=-: $(lastlog)"
causes
[ "$RC" = 0 ] && grep -q 'not loaded' "$T/out.txt" && head -1 "$T/out.txt" | grep -q . && ok || bad "C-nolib: --causes rc 0 with no lib: $(cat "$T/out.txt")"
mv "$T/causes-lib.off" "$LIBF"

# ── C-random: the seeded-random cause (BH-9410, comment 6780574176). Every
# failing entry must equal the match of a catalog row whose [since, until)
# holds the batch's created time. Time is pinned to 2026-11-11T12:00Z.
reset
ep() { date -u -d "$1" +%s; }
NR=$(ep 2026-11-11T12:00:00Z)
J='job:Jobs worker — routes + schema'
RND="$T/rnd"; mkdir -p "$RND"
{ printf '# match\ttest_file\tsettings_row\tsince_iso\tuntil_iso|-\tref\n'
  printf '#job:Commented job\tw/c.test.js\tc.pct\t2026-01-01T00:00:00Z\t-\tR7\n'
  printf '%s\tworker/jobs/test/d1-overload-giveup.bh-7541.test.js\td1.stmt_stats_sample_pct\t2026-11-07T00:00:00Z\t-\tR1\n' "$J"
  printf 'job:Ended job\tw/e.test.js\te.pct\t2026-11-05T00:00:00Z\t2026-11-08T00:00:00Z\tR5\n'
  printf 'job:Bad date job\tw/b.test.js\tb.pct\tnot-a-date\t-\tR8\n'
  printf 'job:Short row\tw/s.test.js\n'
} > "$RND/fx.tsv"
echo 'not a tsv fragment' > "$RND/README.md"
rw() { local id="$1" at="$2" tree="$3"; shift 3; local e; for e in "$@"; do F "$e" other; done | recw "$id" "$(ep "$at")" red "$tree" "$id"; }
rw 501 2026-11-10T00:00:00Z tr1 "$J"; : | recw 591 "$(ep 2026-11-10T00:30:00Z)" green tr1 9     # R1 (+ a green twin)
rw 502 2026-11-10T01:00:00Z tr2 "$J"                                                         # R2
rw 503 2026-11-10T02:00:00Z tr3 "$J" tests/a-test.sh                                         # R3
rw 504 2026-11-06T00:00:00Z tr4 "$J"; : | recw 594 "$(ep 2026-11-06T00:30:00Z)" green tr4 9  # R4
rw 505 2026-11-09T00:00:00Z tr5 "job:Ended job"                                              # R5 after until
rw 515 2026-11-07T12:00:00Z tr15 "job:Ended job"                                             # R5b inside
rw 506 2026-11-10T03:00:00Z tr6 "$J (retry)"                                                 # R6 near miss
rw 516 2026-11-10T03:30:00Z tr16 "job:Jobs worker"                                           # R6b prefix
rw 507 2026-11-10T04:00:00Z tr7 "#job:Commented job"                                         # R7
rw 508 2026-11-10T05:00:00Z tr8 "job:Bad date job"                                           # R8
rw 509 2026-11-10T06:00:00Z tr9 tests/r9.sh "$J"; bl "$(hd 509)" "$(ep 2026-11-10T05:30:00Z)" tests/r9.sh red   # R9
: | recw 510 "$(ep 2026-11-10T07:00:00Z)" red tr10 510                                      # no failing entry
rw 511 2026-11-10T08:00:00Z tr11 "job:Short row"                                             # a short row
causes NOW="$NR" CBR_RANDOM_DIR="$RND"
[ "$RC" = 0 ] && ok || bad "C-random: rc $RC: $(cat "$T/out.txt" "$T/err.txt")"
for want in 501:seeded-random 502:seeded-random 503:unknown 504:flake 505:unknown 515:seeded-random \
            506:unknown 516:unknown 507:unknown 508:unknown 509:main-red 510:unknown 511:unknown; do
  [ "$(cause_of "${want%%:*}")" = "${want#*:}" ] && ok || bad "C-random: run ${want%%:*} is ${want#*:}: '$(row "${want%%:*}")'"
done
[ "$(row 501 | cut -f5)" = "$J" ] && ok || bad "C-random: the job name is the suites column: '$(row 501)'"
# R8: one stderr line, for the bad row only (the column-header comment has a bad
# date field too, and is skipped as a comment)
[ "$(grep -c . "$T/err.txt")" = 1 ] && grep -q "bad date 'not-a-date'" "$T/err.txt" && grep -q 'fx.tsv:5' "$T/err.txt" && ok \
  || bad "C-random: R8 one stderr line for the bad row: $(cat "$T/err.txt")"
grep -qx "seeded-random${TAB}3${TAB}0" "$T/out.txt" && ok || bad "C-random: 3 seeded-random batches in the summary: $(cat "$T/out.txt")"
# The tick line counts the same rule.
drive NOW="$NR" CBR_RANDOM_DIR="$RND"
lastlog | grep -q " causes=main-red:1,seeded-random:3,first-run:0,gate-green-batch-red:0,flake:1,unchanged-requeue:0,unknown:8$" && ok \
  || bad "C-random: the tick line: $(lastlog)"
# R10: the catalog dir is missing → rc 0, no stderr, R1 is a flake and R2 unknown
causes NOW="$NR" CBR_RANDOM_DIR="$T/no-such-dir"
[ "$RC" = 0 ] && [ "$(cause_of 501)" = flake ] && [ "$(cause_of 502)" = unknown ] && [ ! -s "$T/err.txt" ] && ok \
  || bad "C-random: R10 a missing catalog dir: rc=$RC '$(row 501)' '$(row 502)' $(cat "$T/err.txt")"

# ── C-catalog: the committed catalog, read from the report's default dir
reset
mkdir -p "$HH/catalog/ci-batch-red-random.d"
cp "$REPO_DIR"/catalog/ci-batch-red-random.d/*.tsv "$HH/catalog/ci-batch-red-random.d/" \
  || bad "C-catalog: no committed fragment in catalog/ci-batch-red-random.d"
rw 601 2026-11-10T00:00:00Z tc1 "$J"      # before the BH-9430 fix merged
rw 602 2026-11-11T03:00:00Z tc2 "$J"      # after it merged (#9462, 01:58:49Z)
causes NOW="$NR"
[ "$(cause_of 601)" = seeded-random ] && [ "$(cause_of 602)" = unknown ] && [ ! -s "$T/err.txt" ] && ok \
  || bad "C-catalog: the committed row: '$(row 601)' '$(row 602)' $(cat "$T/err.txt")"

# ── C-noroot: the lib refuses with no harness root (D43), never a default root
( HARNESS='' H='' CBR_REPO="$REPO"; . "$LIBF"; cbr_classify "$REC" 0 ) > "$T/noroot.txt" 2>&1
NR_RC=$?
[ "$NR_RC" = 1 ] && [ ! -s "$T/noroot.txt" ] && ok || bad "C-noroot: rc 1 and no rows with no root, got rc $NR_RC: $(cat "$T/noroot.txt")"

echo "ci-batch-red-causes: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
