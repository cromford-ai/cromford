#!/bin/bash
# tests/verify-guards.bh-9414-test.sh — BH-9414 slice C0: the pre-push suite run
# adds the project's always-run guard suites (bin/lib/verify-guards.sh) to the
# unit files bin/lib/test-select.sh picks, and a guard list it cannot read makes
# the run full, never narrower.
#
#   list-static-txt / list-lane-rules / list-both-dedup / list-static-dir
#   list-glob / list-missing-at-head / list-hostile-paths / list-e2e-dropped
#   list-always-full-ignored / list-bad-json / list-key-not-array
#   list-no-sources / list-over-cap / list-knob-sources        vg_list
#   suite-guard-joins-selected        selected files + guards, outfile line order
#   suite-sql-no-tenancy-red          acceptance 2 (and the no-lib control)
#   suite-sql-with-tenancy-green
#   suite-full-run-count-only / suite-bad-guard-list-goes-full
#   suite-no-lib-unchanged / suite-no-guards-unchanged
#
# The real HARNESS_SUITE_RUN block and the real test-select.sh run. npm is a stub
# on PATH. Each case builds its own fixture repo. No network. Nothing is written
# outside $T.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
unset VERIFY_GUARD_SOURCES VERIFY_GUARD_MAX TEST_SELECT CI_LOCALE POOL_TEST_POSTGRES SCOPE_BASE
NOW=1794190000
export GIT_AUTHOR_DATE="2026-11-10T02:00:00Z" GIT_COMMITTER_DATE="2026-11-10T02:00:00Z"
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com

H="$T/h"; H0="$T/h0"; mkdir -p "$H/state" "$H0/state" "$T/fakebin" "$T/tmp"
for f in bin/lib/verify-guards.sh bin/lib/lane-gate.sh bin/lib/test-select.sh; do
  scratch_install_closure "$f" "$H" > /dev/null || bad "setup: cannot install $f"
done
for f in bin/lib/lane-gate.sh bin/lib/test-select.sh; do
  scratch_install_closure "$f" "$H0" > /dev/null || bad "setup: cannot install $f in H0"
done
[ -e "$H0/bin/lib/verify-guards.sh" ] && bad "setup: H0 must not carry verify-guards.sh"
[ -e "$H/bin/lib/ci-env.sh" ] && bad "setup: H must not carry ci-env.sh (the locale block stays a no-op)"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" > "$T/lanes.json" 2> "$T/lanes.err" \
  && [ -s "$T/lanes.json" ] && ok || bad "setup: could not compose the lanes registry: $(head -3 "$T/lanes.err")"
export LANE_REGISTRY="$T/lanes.json" LANE_GATE_NOW="$NOW"
VG="$H/bin/lib/verify-guards.sh"

# settings <json-values> — the settings cache lane_knob reads, fresh at NOW.
settings() { printf '{"fetched_at":%s,"values":%s,"seeded":{}}\n' "$NOW" "$1" > "$H/state/settings-cache.json"; }
settings '{}'
printf '{"fetched_at":%s,"values":{},"seeded":{}}\n' "$NOW" > "$H0/state/settings-cache.json"

# fx <dir> — a fresh git repo. Then: put <path> <content>; commit <msg>.
fx() { scratch_rm "$1"; mkdir -p "$1"; git -C "$1" init -q -b main; FX="$1"; }
put() { mkdir -p "$FX/$(dirname -- "$1")"; printf '%s\n' "$2" > "$FX/$1"; }
commit() { git -C "$FX" add -A && git -C "$FX" commit -q -m "$1"; git -C "$FX" rev-parse HEAD; }
# vl <repo> [env...] — vg_list in a clean shell: sets OUTV, ERRV, RCV.
vl() {
  local r="$1"; shift
  OUTV=$(cd "$r" && env HARNESS="$H" PROJECT=fx TMPDIR="$T/tmp" "$@" bash -c '. "$0" || exit 9; vg_list . HEAD' "$VG" 2> "$T/vl.err"); RCV=$?
  ERRV=$(cat "$T/vl.err")
}
want() { # want <case> <expected stdout> <expected rc>
  [ "$RCV" = "$3" ] && [ "$OUTV" = "$2" ] && ok || bad "$1: want rc $3 '$2', got rc $RCV '$OUTV' (stderr: $ERRV)"
}

# ── list-static-txt ─────────────────────────────────────────────────────────
fx "$T/l1"; put tests/unit/a.guard.test.ts x; put tests/static-guards.txt $'# a comment\n\ntests/unit/a.guard.test.ts\r'; commit base >/dev/null
vl "$T/l1"; want list-static-txt "tests/unit/a.guard.test.ts" 0

# ── list-lane-rules ─────────────────────────────────────────────────────────
fx "$T/l2"; put tests/unit/tenancy.test.ts x; put scripts/ci/lane-rules.json '{"alwaysSuites":["tests/unit/tenancy.test.ts"]}'; commit base >/dev/null
vl "$T/l2"; want list-lane-rules "tests/unit/tenancy.test.ts" 0

# ── list-both-dedup ─────────────────────────────────────────────────────────
fx "$T/l3"; put tests/unit/t.test.ts x; put tests/unit/u.test.ts x
put tests/static-guards.txt $'tests/unit/t.test.ts\ntests/unit/u.test.ts'
put scripts/ci/lane-rules.json '{"alwaysSuites":["tests/unit/t.test.ts","tests/unit/t.test.ts"]}'; commit base >/dev/null
vl "$T/l3"; want list-both-dedup $'tests/unit/t.test.ts\ntests/unit/u.test.ts' 0

# ── list-static-dir ─────────────────────────────────────────────────────────
fx "$T/l4"; put tests/static-guards/no-raw-sql.test.ts x; put tests/static-guards/sub/deep.test.ts x; commit base >/dev/null
vl "$T/l4"; want list-static-dir $'tests/static-guards/no-raw-sql.test.ts\ntests/static-guards/sub/deep.test.ts' 0

# ── list-glob ───────────────────────────────────────────────────────────────
fx "$T/l5"; put tests/guards/a.test.ts x; put tests/guards/b.test.ts x; put tests/guards/readme.md x; put tests/other/c.test.ts x
put scripts/ci/lane-rules.json '{"alwaysSuites":["tests/guards/*.test.ts"]}'; commit base >/dev/null
vl "$T/l5"; want list-glob $'tests/guards/a.test.ts\ntests/guards/b.test.ts' 0

# ── list-missing-at-head ────────────────────────────────────────────────────
fx "$T/l6"; put tests/unit/gone.test.ts x; put tests/unit/kept.test.ts x
put tests/static-guards.txt $'tests/unit/gone.test.ts\ntests/unit/kept.test.ts\ntests/unit/untracked.test.ts'; commit base >/dev/null
git -C "$T/l6" rm -q tests/unit/gone.test.ts; commit head >/dev/null
put tests/unit/untracked.test.ts x     # on disk, not in the HEAD tree
vl "$T/l6"; want list-missing-at-head "tests/unit/kept.test.ts" 0

# ── list-hostile-paths ──────────────────────────────────────────────────────
fx "$T/l7"; put tests/unit/a.test.ts x; put "-rf" x
put tests/static-guards.txt $'../etc/passwd\n/abs/x.test.ts\n-rf\ntests/../tests/unit/a.test.ts\n$(touch '"$T"'/pwned).test.ts'
put scripts/ci/lane-rules.json '{"alwaysSuites":["tests/unit/a\r.test.ts","tests/unit/a.test.ts\nx","/etc/passwd","./../x"]}'; commit base >/dev/null
vl "$T/l7"; want list-hostile-paths "" 0
[ -e "$T/pwned" ] && bad "list-hostile-paths: a path ran as a command" || ok

# ── list-e2e-dropped ────────────────────────────────────────────────────────
fx "$T/l8"; put e2e/login.spec.ts x; put tests/e2e/x.spec.ts x; put tests/unit/ok.test.ts x
put scripts/ci/lane-rules.json '{"alwaysSuites":["e2e/login.spec.ts","tests/e2e/x.spec.ts","tests/unit/ok.test.ts","tests/e2e/*.spec.ts"]}'; commit base >/dev/null
vl "$T/l8"; want list-e2e-dropped "tests/unit/ok.test.ts" 0

# ── list-always-full-ignored ────────────────────────────────────────────────
fx "$T/l9"; put tests/unit/full.test.ts x
put scripts/ci/lane-rules.json '{"alwaysFull":["tests/unit/full.test.ts"],"alwaysSuites":[]}'; commit base >/dev/null
vl "$T/l9"; want list-always-full-ignored "" 0

# ── list-bad-json ───────────────────────────────────────────────────────────
fx "$T/l10"; put tests/unit/a.test.ts x; put tests/static-guards.txt tests/unit/a.test.ts
put scripts/ci/lane-rules.json '{"alwaysSuites": ["tests/unit/a.test.ts"'; commit base >/dev/null
vl "$T/l10"; want list-bad-json "" 3
case "$ERRV" in 'UNREADABLE: scripts/ci/lane-rules.json is not a JSON object') ok ;; *) bad "list-bad-json: stderr '$ERRV'" ;; esac
scratch_rm "$T/tmp"; mkdir -p "$T/tmp"
got=$(cd "$T/l10" && HARNESS="$H" TMPDIR="$T/tmp" bash -c '. "$0"; vg_suite_guards . HEAD; echo "rc=$? n=${#VG_GUARDS[@]} why=$VG_WHY"' "$VG")
[ "$got" = "rc=2 n=0 why=guard list unreadable: scripts/ci/lane-rules.json is not a JSON object" ] && ok || bad "list-bad-json: vg_suite_guards '$got'"
[ -z "$(ls -A "$T/tmp")" ] && ok || bad "list-bad-json: temp files left: $(ls -A "$T/tmp")"

# ── list-key-not-array ──────────────────────────────────────────────────────
fx "$T/l11"; put tests/unit/a.test.ts x; put scripts/ci/lane-rules.json '{"alwaysSuites":"tests/unit/a.test.ts"}'; commit base >/dev/null
vl "$T/l11"; want list-key-not-array "" 3
put scripts/ci/lane-rules.json '{"alwaysSuites":["tests/unit/a.test.ts",1]}'; commit two >/dev/null
vl "$T/l11"; want "list-key-not-array (non-string item)" "" 3

# ── list-no-sources ─────────────────────────────────────────────────────────
fx "$T/l12"; put src/a.ts x; commit base >/dev/null
vl "$T/l12"; want list-no-sources "" 0
put scripts/ci/lane-rules.json '{"alwaysFull":["x"]}'; commit two >/dev/null
vl "$T/l12"; want "list-no-sources (no key)" "" 0

# ── list-over-cap ───────────────────────────────────────────────────────────
fx "$T/l13"; put tests/unit/a.test.ts x; put tests/unit/b.test.ts x; put tests/unit/c.test.ts x
put tests/static-guards.txt $'tests/unit/a.test.ts\ntests/unit/b.test.ts\ntests/unit/c.test.ts'; commit base >/dev/null
settings '{"lib.verify-guards.verify_guard_max":"2"}'
vl "$T/l13"; want list-over-cap "" 2
got=$(cd "$T/l13" && HARNESS="$H" PROJECT=fx TMPDIR="$T/tmp" bash -c '. "$0"; vg_suite_guards . HEAD; echo "rc=$? why=$VG_WHY"' "$VG")
[ "$got" = "rc=2 why=guard list over the cap: 3 guard paths > VERIFY_GUARD_MAX 2" ] && ok || bad "list-over-cap: vg_suite_guards '$got'"
settings '{"lib.verify-guards.verify_guard_max":"2","lib.verify-guards.fx.verify_guard_max":"3"}'
vl "$T/l13"; want "list-over-cap (project row wins)" $'tests/unit/a.test.ts\ntests/unit/b.test.ts\ntests/unit/c.test.ts' 0
settings '{}'
vl "$T/l13" VERIFY_GUARD_MAX=1; want "list-over-cap (env)" "" 2

# ── list-knob-sources ───────────────────────────────────────────────────────
fx "$T/l14"; put tests/unit/a.test.ts x; put tests/unit/b.test.ts x
put tests/static-guards.txt tests/unit/a.test.ts; put ci/guards.txt tests/unit/b.test.ts; commit base >/dev/null
settings '{"lib.verify-guards.verify_guard_sources":"ci/guards.txt"}'
vl "$T/l14"; want list-knob-sources "tests/unit/b.test.ts" 0
settings '{}'
vl "$T/l14" VERIFY_GUARD_SOURCES=" ci/guards.txt , tests/static-guards.txt "; want "list-knob-sources (env)" $'tests/unit/a.test.ts\ntests/unit/b.test.ts' 0
vl "$T/l14"; want "list-knob-sources (default)" "tests/unit/a.test.ts" 0

# ── HARNESS_SUITE_RUN: the real block, lifted from the flattened pipeline ───
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^# >>> harness suite run/{f=1;next} /^# <<< harness suite run/{exit} f' "$RB" > "$T/suite-run.sh"
[ -s "$T/suite-run.sh" ] && ok || bad "setup: could not extract the harness-suite-run block"

# The npm stub logs its argv. It is red when the tenancy guard is in argv and a
# db/*.sql file at the checkout has no `-- tenancy:` header (the project-6 guard).
cat > "$T/fakebin/npm" <<EOF
#!/bin/bash
printf '%s\n' "npm \$*" >> "$T/npm.log"
for a in "\$@"; do
  [ "\$a" = tests/unit/tenancy.test.ts ] || continue
  for s in db/*.sql; do [ -f "\$s" ] || continue; grep -q -- '-- tenancy:' "\$s" || { echo "FAIL tenancy: \$s has no -- tenancy: header"; exit 1; }; done
done
exit 0
EOF
chmod +x "$T/fakebin/npm"

BUILD="$T/build"; OUT="$BUILD/harness-suite.txt"
# suite <harness> <repo> <base> [env...] — HARNESS_SUITE_RUN lenses in <repo>.
suite() {
  local sh="$1" repo="$2" base="$3"; shift 3
  scratch_rm "$BUILD"; mkdir -p "$BUILD"; : > "$T/npm.log"
  ( cd "$repo" || exit 1
    export PATH="$T/fakebin:$PATH" HARNESS="$sh" BUILD PROJECT=fx KEY=FX-1 BASE="$base" TEST_SELECT=1 \
      ALERTS="$T/ALERTS.log" TMPDIR="$T/tmp"
    for kv in "$@"; do export "${kv?}"; done
    STAMP() { echo 2026-11-10T02:00:00Z; }
    # shellcheck source=/dev/null
    . "$T/suite-run.sh"
    HARNESS_SUITE_RUN harness-suite.txt lenses )
}
# A fixture: src/a.ts mapped to tests/unit/a.test.ts, db/*.sql mapped to
# tests/unit/db.test.ts, its own always-full.txt with no .sql pattern.
proj() {
  fx "$1"
  put package.json '{"scripts":{"test:unit":"vitest run"}}'
  put src/a.ts 'export const a = 1'
  put tests/unit/a.test.ts x; put tests/unit/db.test.ts x; put tests/unit/tenancy.test.ts x; put tests/unit/b.guard.test.ts x
  put tests/impact-map.json '{"src/a.ts":["tests/unit/a.test.ts"],"db/*.sql":["tests/unit/db.test.ts"]}'
  put tests/always-full.txt '^package\.json$'
  put db/0001.sql $'-- tenancy: company_id\ncreate table t (id int);'
}

# ── suite-guard-joins-selected ──────────────────────────────────────────────
proj "$T/s1"; put scripts/ci/lane-rules.json '{"alwaysSuites":["tests/unit/tenancy.test.ts"]}'
put tests/static-guards.txt tests/unit/b.guard.test.ts
B=$(commit base); put src/a.ts 'export const a = 2'; commit head >/dev/null
suite "$H" "$T/s1" "$B"
[ "$(sed -n 1p "$OUT")" = "HARNESS_SUITE: selected 3 of the suite — npm run test:unit" ] && ok || bad "suite-guard-joins-selected: line 1: $(cat "$OUT")"
[ "$(sed -n 2p "$OUT")" = "HARNESS_GUARDS: 2 guard suite(s) in the run" ] && ok || bad "suite-guard-joins-selected: line 2: $(cat "$OUT")"
[ "$(tail -1 "$OUT")" = "HARNESS_EXIT: 0" ] && ok || bad "suite-guard-joins-selected: last line: $(cat "$OUT")"
[ "$(cat "$T/npm.log")" = "npm run test:unit -- tests/unit/a.test.ts tests/unit/b.guard.test.ts tests/unit/tenancy.test.ts" ] && ok \
  || bad "suite-guard-joins-selected: npm argv: $(cat "$T/npm.log")"
grep -q 'HARNESS-VERIFY lenses (npm run test:unit) selected 3 of the suite$' "$BUILD/pipeline.log" && ok || bad "suite-guard-joins-selected: pipeline.log: $(cat "$BUILD/pipeline.log")"
# The reader of HARNESS_EXIT (bin/evidence-summary.sh) still finds it.
got=$(sed -n 's/^HARNESS_EXIT: //p' "$OUT" | tail -1)
[ "$got" = 0 ] && ok || bad "suite-guard-joins-selected: HARNESS_EXIT reader got '$got'"

# ── suite-sql-no-tenancy-red (acceptance 2) ─────────────────────────────────
proj "$T/s2"; put scripts/ci/lane-rules.json '{"alwaysSuites":["tests/unit/tenancy.test.ts"]}'
B=$(commit base); put db/0002.sql 'create table u (id int);'; commit head >/dev/null
suite "$H" "$T/s2" "$B"
grep -qx 'HARNESS_EXIT: 1' "$OUT" && ok || bad "suite-sql-no-tenancy-red: want HARNESS_EXIT: 1: $(cat "$OUT")"
grep -q 'tests/unit/tenancy.test.ts' "$T/npm.log" && ok || bad "suite-sql-no-tenancy-red: guard not in argv: $(cat "$T/npm.log")"
grep -q 'FAIL tenancy: db/0002.sql' "$OUT" && ok || bad "suite-sql-no-tenancy-red: the guard failure is not in the record: $(cat "$OUT")"
# Control: the same fixture with no lib runs only the selection, and is green (the gap).
suite "$H0" "$T/s2" "$B"
[ "$(cat "$T/npm.log")" = "npm run test:unit -- tests/unit/db.test.ts" ] && ok || bad "suite-sql-no-tenancy-red control: argv: $(cat "$T/npm.log")"
grep -qx 'HARNESS_EXIT: 0' "$OUT" && ok || bad "suite-sql-no-tenancy-red control: exit: $(cat "$OUT")"

# ── suite-sql-with-tenancy-green ────────────────────────────────────────────
proj "$T/s3"; put scripts/ci/lane-rules.json '{"alwaysSuites":["tests/unit/tenancy.test.ts"]}'
B=$(commit base); put db/0002.sql $'-- tenancy: company_id\ncreate table u (id int);'; commit head >/dev/null
suite "$H" "$T/s3" "$B"
grep -qx 'HARNESS_EXIT: 0' "$OUT" && ok || bad "suite-sql-with-tenancy-green: exit: $(cat "$OUT")"
[ "$(cat "$T/npm.log")" = "npm run test:unit -- tests/unit/db.test.ts tests/unit/tenancy.test.ts" ] && ok || bad "suite-sql-with-tenancy-green: argv: $(cat "$T/npm.log")"

# ── suite-full-run-count-only ───────────────────────────────────────────────
suite "$H" "$T/s1" "$(git -C "$T/s1" rev-parse HEAD~1)" TEST_SELECT=0
[ "$(cat "$T/npm.log")" = "npm run test:unit" ] && ok || bad "suite-full-run-count-only: argv: $(cat "$T/npm.log")"
[ "$(sed -n 1p "$OUT")" = "HARNESS_SUITE: full (TEST_SELECT=0) — npm run test:unit" ] && ok || bad "suite-full-run-count-only: line 1: $(cat "$OUT")"
[ "$(sed -n 2p "$OUT")" = "HARNESS_GUARDS: 2 guard suite(s), in the full run" ] && ok || bad "suite-full-run-count-only: line 2: $(cat "$OUT")"

# ── suite-bad-guard-list-goes-full ──────────────────────────────────────────
proj "$T/s4"; put scripts/ci/lane-rules.json '{"alwaysSuites": ['
B=$(commit base); put src/a.ts 'export const a = 2'; commit head >/dev/null
suite "$H" "$T/s4" "$B"
[ "$(sed -n 1p "$OUT")" = "HARNESS_SUITE: full (guard list unreadable: scripts/ci/lane-rules.json is not a JSON object) — npm run test:unit" ] && ok \
  || bad "suite-bad-guard-list-goes-full: line 1: $(cat "$OUT")"
[ "$(sed -n 2p "$OUT")" = "HARNESS_GUARDS: none listed (guard list unreadable: scripts/ci/lane-rules.json is not a JSON object)" ] && ok \
  || bad "suite-bad-guard-list-goes-full: line 2: $(cat "$OUT")"
[ "$(cat "$T/npm.log")" = "npm run test:unit" ] && ok || bad "suite-bad-guard-list-goes-full: argv must name no files: $(cat "$T/npm.log")"
[ "$(tail -1 "$OUT")" = "HARNESS_EXIT: 0" ] && ok || bad "suite-bad-guard-list-goes-full: last line: $(cat "$OUT")"
grep -q 'HARNESS-VERIFY lenses (npm run test:unit) full (guard list unreadable' "$BUILD/pipeline.log" && ok || bad "suite-bad-guard-list-goes-full: pipeline.log: $(cat "$BUILD/pipeline.log")"

# ── suite-no-lib-unchanged ──────────────────────────────────────────────────
suite "$H0" "$T/s1" "$(git -C "$T/s1" rev-parse HEAD~1)"
grep -q '^HARNESS_GUARDS' "$OUT" && bad "suite-no-lib-unchanged: a HARNESS_GUARDS line with no lib: $(cat "$OUT")" || ok
[ "$(cat "$T/npm.log")" = "npm run test:unit -- tests/unit/a.test.ts tests/unit/b.guard.test.ts" ] && ok || bad "suite-no-lib-unchanged: argv: $(cat "$T/npm.log")"
[ "$(sed -n 1p "$OUT")" = "HARNESS_SUITE: selected 2 of the suite — npm run test:unit" ] && ok || bad "suite-no-lib-unchanged: line 1: $(cat "$OUT")"

# ── suite-no-guards-unchanged ───────────────────────────────────────────────
proj "$T/s5"; B=$(commit base); put src/a.ts 'export const a = 2'; commit head >/dev/null
suite "$H" "$T/s5" "$B"
[ "$(sed -n 2p "$OUT")" = "HARNESS_GUARDS: 0 guard suite(s) in the run" ] && ok || bad "suite-no-guards-unchanged: line 2: $(cat "$OUT")"
[ "$(cat "$T/npm.log")" = "npm run test:unit -- tests/unit/a.test.ts" ] && ok || bad "suite-no-guards-unchanged: argv: $(cat "$T/npm.log")"
grep -qx 'HARNESS_EXIT: 0' "$OUT" && ok || bad "suite-no-guards-unchanged: exit: $(cat "$OUT")"

echo "verify-guards.bh-9414: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
