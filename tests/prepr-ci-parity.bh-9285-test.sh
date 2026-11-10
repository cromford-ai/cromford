#!/bin/bash
# tests/prepr-ci-parity.bh-9285-test.sh — BH-9285 slice C0: a box suite run uses
# CI's locale and collation, from a settings row, the CI workflow or the
# documented fallback (bin/lib/ci-env.sh), and never the box locale in silence.
#
#   locale-knob-wins / locale-project-row-wins   a row beats the workflow env
#   locale-from-workflow / locale-lang-only       top-level env LC_ALL, else LANG
#   locale-job-env-ignored                        job-level env is not read
#   locale-hostile-value                          4 bad shapes give the next source
#   locale-bad-yaml / locale-fallback             en_US.UTF-8 (CE_FALLBACK_LOCALE)
#   collation-knob                                CI_PG_COLLATION sets the collation only
#   installed-normalized                          en_US.UTF-8 = en_US.utf8, C, POSIX
#   suite-env-locale                              HARNESS_SUITE_RUN: npm gets LANG/LC_ALL
#   suite-locale-missing                          could-not-run, no npm, no initdb, no alert
#   suite-no-lib-unchanged                        no ci-env.sh: no override, no record
#   suite-sort-fixture                            acceptance 1 (the real en_US half
#                                                 runs only where the box has it)
#   pg-collation-flags / pg-collation-knob        initdb gets the locale flags
#   pg-locale-missing                             pgt_start rc 3, initdb not called
#   pg-no-lib-unchanged                           no ci-env.sh: no locale flags
#   ci-local-step-locale / ci-local-fallback-unchanged / ci-local-locale-missing
#
# `locale -a` is a stub on PATH where a case needs a list this box does not
# have. No network. Nothing is written outside $T.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
unset CI_LOCALE CI_PG_COLLATION POOL_TEST_POSTGRES POOL_TEST_SETUP_CMD PGT_BIN_DIR TEST_SELECT
NOW=1794190000
export GIT_AUTHOR_DATE="2026-11-09T02:00:00Z" GIT_COMMITTER_DATE="2026-11-09T02:00:00Z"
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com

H="$T/h"; mkdir -p "$H/state" "$T/fakebin" "$T/loc-en" "$T/loc-c" "$T/loc-gb" "$T/pgbin" "$T/tmp"
scratch_install_closure bin/lib/ci-env.sh "$H" > /dev/null || bad "setup: cannot install bin/lib/ci-env.sh"
scratch_install_closure bin/lib/pg-test.sh "$H" > /dev/null || bad "setup: cannot install bin/lib/pg-test.sh"
scratch_install_closure bin/lib/lane-gate.sh "$H" > /dev/null || bad "setup: cannot install bin/lib/lane-gate.sh"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" > "$T/lanes.json" 2> "$T/lanes.err" \
  && [ -s "$T/lanes.json" ] && ok || bad "setup: could not compose the lanes registry: $(head -3 "$T/lanes.err")"
export LANE_REGISTRY="$T/lanes.json" LANE_GATE_NOW="$NOW"
CE="$H/bin/lib/ci-env.sh"

# Two `locale` stubs: one box with en_US.UTF-8, one without (this pool image today).
printf '#!/bin/bash\nprintf "C\\nC.utf8\\nPOSIX\\nen_US.utf8\\n"\n' > "$T/loc-en/locale"
printf '#!/bin/bash\nprintf "C\\nC.utf8\\nPOSIX\\n"\n' > "$T/loc-c/locale"
chmod +x "$T/loc-en/locale" "$T/loc-c/locale"

# settings <json-values> — the settings cache lane_knob reads, fresh at NOW.
settings() { printf '{"fetched_at":%s,"values":%s,"seeded":{}}\n' "$NOW" "$1" > "$H/state/settings-cache.json"; }
settings '{}'
# repo <dir> [workflow-yaml] — a scratch repo with an optional .github/workflows/ci.yml.
repo() {
  scratch_rm "$1"; mkdir -p "$1/.github/workflows"
  [ -n "${2:-}" ] && printf '%s\n' "$2" > "$1/.github/workflows/ci.yml"
  return 0
}
# res <repo> — "<locale> <source> <collation>" from ce_resolve in a clean shell.
res() { HARNESS="$H" PROJECT=project-6-os bash -c '. "$0" || exit 9; ce_resolve "$1"; echo "$CE_LOCALE $CE_SOURCE $CE_COLLATION"' "$CE" "$1"; }

# ── locale-knob-wins ────────────────────────────────────────────────────────
repo "$T/r1" $'env:\n  LC_ALL: POSIX\njobs: {}'
settings '{"lib.ci-env.ci_locale":"C.UTF-8"}'
[ "$(res "$T/r1")" = "C.UTF-8 knob C.UTF-8" ] && ok || bad "locale-knob-wins: the row must beat the workflow: '$(res "$T/r1")'"
settings '{"lib.ci-env.ci_locale":"C.UTF-8","lib.ci-env.project-6-os.ci_locale":"POSIX"}'
[ "$(res "$T/r1")" = "POSIX knob POSIX" ] && ok || bad "locale-knob-wins: the project row must beat the fleet row: '$(res "$T/r1")'"
settings '{}'
got=$(HARNESS="$H" CI_LOCALE=C.UTF-8 bash -c '. "$0"; ce_resolve "$1"; echo "$CE_LOCALE $CE_SOURCE"' "$CE" "$T/r1")
[ "$got" = "C.UTF-8 knob" ] && ok || bad "locale-knob-wins: the env CI_LOCALE is the knob too: '$got'"

# ── locale-from-workflow ────────────────────────────────────────────────────
[ "$(res "$T/r1")" = "POSIX workflow POSIX" ] && ok || bad "locale-from-workflow: top-level LC_ALL: '$(res "$T/r1")'"
repo "$T/r2" $'env:\n  LANG: C.UTF-8\njobs: {}'
[ "$(res "$T/r2")" = "C.UTF-8 workflow C.UTF-8" ] && ok || bad "locale-from-workflow: LANG only: '$(res "$T/r2")'"
repo "$T/r3" $'jobs:\n  unit:\n    env:\n      LC_ALL: POSIX\n    steps: []'
[ "$(res "$T/r3")" = "en_US.UTF-8 fallback en_US.UTF-8" ] && ok || bad "locale-from-workflow: job-level env must not be read: '$(res "$T/r3")'"
scratch_rm "$T/r4"; mkdir -p "$T/r4/.github/workflows"; printf 'env:\n  LC_ALL: C.UTF-8\n' > "$T/r4/.github/workflows/harness-ci.yml"
[ "$(res "$T/r4")" = "C.UTF-8 workflow C.UTF-8" ] && ok || bad "locale-from-workflow: harness-ci.yml when there is no ci.yml: '$(res "$T/r4")'"

# ── locale-fallback ─────────────────────────────────────────────────────────
repo "$T/r5"
[ "$(res "$T/r5")" = "en_US.UTF-8 fallback en_US.UTF-8" ] && ok || bad "locale-fallback: '$(res "$T/r5")'"
settings '{"lib.ci-env.ci_pg_collation":"C"}'
[ "$(res "$T/r5")" = "en_US.UTF-8 fallback C" ] && ok || bad "locale-fallback: CI_PG_COLLATION sets the collation only: '$(res "$T/r5")'"
settings '{}'

# ── locale-project-row-wins / locale-lang-only / locale-job-env-ignored ─────
# (asserted above in the knob-wins and from-workflow blocks)

# ── locale-hostile-value ────────────────────────────────────────────────────
settings '{"lib.ci-env.ci_locale":"\"; touch '"$T"'/pwned; \""}'
repo "$T/r6" $'env:\n  LC_ALL: "$(touch '"$T"'/pwned2) x"\njobs: {}'
[ "$(res "$T/r6")" = "en_US.UTF-8 fallback en_US.UTF-8" ] && ok || bad "locale-hostile-value: both bad values must be ignored: '$(res "$T/r6")'"
settings '{}'
repo "$T/r6b" $'env:\n  LC_ALL: "en_US.UTF-8; rm -rf /"\njobs: {}'
[ "$(res "$T/r6b")" = "en_US.UTF-8 fallback en_US.UTF-8" ] && ok || bad "locale-hostile-value: ';' value: '$(res "$T/r6b")'"
repo "$T/r6c" $'env:\n  LC_ALL: ${{ vars.X }}\n  LANG: C.UTF-8\njobs: {}'
[ "$(res "$T/r6c")" = "en_US.UTF-8 fallback en_US.UTF-8" ] && ok || bad "locale-hostile-value: \${{ }} value: '$(res "$T/r6c")'"
repo "$T/r6d" "env:
  LC_ALL: $(printf 'a%.0s' $(seq 1 65))
jobs: {}"
[ "$(res "$T/r6d")" = "en_US.UTF-8 fallback en_US.UTF-8" ] && ok || bad "locale-hostile-value: 65-char value: '$(res "$T/r6d")'"
repo "$T/r6e" $'env:\n  LC_ALL: 1\njobs: {}'
[ "$(res "$T/r6e")" = "en_US.UTF-8 fallback en_US.UTF-8" ] && ok || bad "locale-hostile-value: non-string value: '$(res "$T/r6e")'"
repo "$T/r6f" $'env:\n  - LC_ALL=C.UTF-8\njobs: {}'
[ "$(res "$T/r6f")" = "en_US.UTF-8 fallback en_US.UTF-8" ] && ok || bad "locale-hostile-value: env as a list: '$(res "$T/r6f")'"
[ -e "$T/pwned" ] || [ -e "$T/pwned2" ] && bad "locale-hostile-value: a value ran as a command" || ok

# ── locale-bad-yaml ─────────────────────────────────────────────────────────
repo "$T/r7" $'env: [unclosed\n  LC_ALL: C.UTF-8\n: :'
[ "$(res "$T/r7")" = "en_US.UTF-8 fallback en_US.UTF-8" ] && ok || bad "locale-bad-yaml: '$(res "$T/r7")'"

# ── collation-knob ──────────────────────────────────────────────────────────
settings '{"lib.ci-env.ci_pg_collation":"de_DE.UTF-8"}'
[ "$(res "$T/r2")" = "C.UTF-8 workflow de_DE.UTF-8" ] && ok || bad "collation-knob: '$(res "$T/r2")'"
settings '{}'

# ── installed-normalized ────────────────────────────────────────────────────
inst() { PATH="$1:$PATH" bash -c '. "$0"; ce_locale_installed "$1" && echo yes || echo no' "$CE" "$2"; }
printf '#!/bin/bash\nprintf "C\\nC.utf8\\nPOSIX\\nen_GB.utf8\\n"\n' > "$T/loc-gb/locale"; chmod +x "$T/loc-gb/locale"
[ "$(inst "$T/loc-en" en_US.UTF-8)" = yes ] && ok || bad "installed-normalized: en_US.UTF-8 vs en_US.utf8"
[ "$(inst "$T/loc-c" C)" = yes ] && ok || bad "installed-normalized: C"
[ "$(inst "$T/loc-c" POSIX)" = yes ] && ok || bad "installed-normalized: POSIX"
[ "$(inst "$T/loc-c" C.UTF-8)" = yes ] && ok || bad "installed-normalized: C.UTF-8 vs C.utf8"
[ "$(inst "$T/loc-gb" en_US.UTF-8)" = no ] && ok || bad "installed-normalized: en_US.UTF-8 vs only en_GB.utf8 must be no"
[ "$(inst "$T/loc-en" en_US)" = no ] && ok || bad "installed-normalized: en_US with no codeset must be no"
[ "$(inst "$T/loc-en" '')" = no ] && ok || bad "installed-normalized: empty must be no"

# ── HARNESS_SUITE_RUN: the real block, lifted from the flattened pipeline ───
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^# >>> harness suite run/{f=1;next} /^# <<< harness suite run/{exit} f' "$RB" > "$T/suite-run.sh"
[ -s "$T/suite-run.sh" ] && ok || bad "setup: could not extract the harness-suite-run block"

cat > "$T/pgbin/initdb" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/initdb.argv"
d=""; while [ \$# -gt 0 ]; do [ "\$1" = -D ] && { d="\$2"; shift; }; shift; done
mkdir -p "\$d"
EOF
cat > "$T/pgbin/pg_ctl" <<'EOF'
#!/bin/bash
d=""; verb=""; while [ $# -gt 0 ]; do case "$1" in -D) d="$2"; shift ;; start|stop) verb="$1" ;; esac; shift; done
case "$verb" in start) echo 1 > "$d/postmaster.pid" ;; stop) rm -f "$d/postmaster.pid" ;; esac
EOF
printf '#!/bin/bash\necho "postgres (PostgreSQL) 16.14"\n' > "$T/pgbin/postgres"
cat > "$T/fakebin/setpriv" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ] && [ "${1#--}" != "$1" ]; do shift; done
exec "$@"
EOF
# The npm stub runs the repo's test.sh the way `npm run test` would, and logs
# the locale it saw.
cat > "$T/fakebin/npm" <<EOF
#!/bin/bash
echo "npm \$* LANG=\${LANG:-UNSET} LC_ALL=\${LC_ALL:-UNSET}" >> "$T/npm.log"
[ "\$2" = test ] && exec bash ./test.sh
exit 0
EOF
chmod +x "$T/pgbin/"* "$T/fakebin/"*

REPO="$T/repo"; BUILD="$T/build"; OUT="$BUILD/harness-suite.txt"
# A second scratch harness with NO ci-env.sh: the run must be as before (A6).
H0="$T/h0"; mkdir -p "$H0/state"
scratch_install_closure bin/lib/pg-test.sh "$H0" > /dev/null || bad "setup: cannot install pg-test.sh in H0"
scratch_install_closure bin/lib/lane-gate.sh "$H0" > /dev/null || bad "setup: cannot install lane-gate.sh in H0"
[ -e "$H0/bin/lib/ci-env.sh" ] && bad "setup: H0 must not carry ci-env.sh"
printf '{"fetched_at":%s,"values":{},"seeded":{}}\n' "$NOW" > "$H0/state/settings-cache.json"
SH="$H"
# A de_DE box for the collation knob case.
mkdir -p "$T/loc-de"; printf '#!/bin/bash\nprintf "C\\nC.utf8\\nPOSIX\\nen_US.utf8\\nde_DE.utf8\\n"\n' > "$T/loc-de/locale"; chmod +x "$T/loc-de/locale"
# suite <locale-stub-dir> <test.sh body> — HARNESS_SUITE_RUN lenses in a fresh repo,
# against the harness $SH, with ALERTS pointed into $T.
suite() {
  scratch_rm "$REPO"; scratch_rm "$BUILD"; mkdir -p "$REPO" "$BUILD"
  : > "$T/npm.log"; : > "$T/initdb.argv"
  printf '{"scripts":{"test":"bash test.sh"}}\n' > "$REPO/package.json"
  printf '%s\n' "$2" > "$REPO/test.sh"
  ( cd "$REPO" || exit 1
    export PATH="$1:$T/fakebin:$PATH" HARNESS="$SH" BUILD PROJECT=project-6-os KEY=TK-1 TEST_SELECT=0 ALERTS="$T/ALERTS.log" \
      PGT_BIN_DIR="$T/pgbin" TMPDIR="$T/tmp" PGT_ROOTS="$T/tmp"
    STAMP() { echo 2026-11-09T02:00:00Z; }
    # shellcheck source=/dev/null
    . "$T/suite-run.sh"
    HARNESS_SUITE_RUN harness-suite.txt lenses )
}

# ── suite-env-locale ────────────────────────────────────────────────────────
suite "$T/loc-en" 'exit 0'
grep -q 'npm run test LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8' "$T/npm.log" && ok || bad "suite-env-locale: npm env: $(cat "$T/npm.log")"
grep -qx 'HARNESS_LOCALE: en_US.UTF-8 (source: fallback, collation en_US.UTF-8)' "$OUT" && ok || bad "suite-env-locale: locale line: $(cat "$OUT")"
grep -qx 'HARNESS_EXIT: 0' "$OUT" && ok || bad "suite-env-locale: exit: $(cat "$OUT")"
grep -q 'HARNESS-VERIFY lenses HARNESS_LOCALE: en_US.UTF-8' "$BUILD/pipeline.log" && ok || bad "suite-env-locale: pipeline.log: $(cat "$BUILD/pipeline.log")"

# ── suite-locale-missing ────────────────────────────────────────────────────
: > "$T/ALERTS.log"
POOL_TEST_POSTGRES=1 suite "$T/loc-c" 'exit 0'
[ "$(tail -1 "$OUT")" = 'HARNESS_EXIT: could-not-run' ] && ok || bad "suite-locale-missing: HARNESS_EXIT must be the last line: $(cat "$OUT")"
nl=$(grep -n '^HARNESS_LOCALE: could-not-run (locale en_US.UTF-8 not installed; source: fallback)$' "$OUT" | cut -d: -f1)
ne=$(grep -n '^HARNESS_EXIT: ' "$OUT" | cut -d: -f1)
[ -n "$nl" ] && [ -n "$ne" ] && [ "$nl" -lt "$ne" ] && ok || bad "suite-locale-missing: HARNESS_LOCALE before HARNESS_EXIT: $(cat "$OUT")"
[ -s "$T/npm.log" ] && bad "suite-locale-missing: npm ran with no CI locale: $(cat "$T/npm.log")" || ok
[ -s "$T/initdb.argv" ] && bad "suite-locale-missing: initdb ran: $(cat "$T/initdb.argv")" || ok
grep -q 'HARNESS-VERIFY lenses HARNESS_LOCALE: could-not-run' "$BUILD/pipeline.log" && ok || bad "suite-locale-missing: pipeline.log line: $(cat "$BUILD/pipeline.log")"
[ -s "$T/ALERTS.log" ] && bad "suite-locale-missing: wrote ALERTS: $(cat "$T/ALERTS.log")" || ok
# With no Postgres at all, a missing locale still stops the run before npm.
suite "$T/loc-c" 'exit 0'
grep -qx 'HARNESS_EXIT: could-not-run' "$OUT" && ok || bad "suite-locale-missing: no-postgres run exit: $(cat "$OUT")"
[ -s "$T/npm.log" ] && bad "suite-locale-missing: npm ran in the box locale: $(cat "$T/npm.log")" || ok

# ── suite-no-lib-unchanged ──────────────────────────────────────────────────
SH="$H0"; suite "$T/loc-c" 'exit 0'; SH="$H"
grep -q '^npm run test LANG=' "$T/npm.log" && ok || bad "suite-no-lib-unchanged: npm must run: $(cat "$T/npm.log")"
grep -q 'LC_ALL=en_US.UTF-8' "$T/npm.log" && bad "suite-no-lib-unchanged: npm got a locale override: $(cat "$T/npm.log")" || ok
grep -q '^HARNESS_LOCALE' "$OUT" && bad "suite-no-lib-unchanged: a HARNESS_LOCALE line with no lib: $(cat "$OUT")" || ok
grep -qx 'HARNESS_EXIT: 0' "$OUT" && ok || bad "suite-no-lib-unchanged: exit: $(cat "$OUT")"

# ── pg-collation-flags ──────────────────────────────────────────────────────
POOL_TEST_POSTGRES=1 suite "$T/loc-en" 'exit 0'
grep -q -- '--locale=en_US.UTF-8 --lc-collate=en_US.UTF-8 --lc-ctype=en_US.UTF-8' "$T/initdb.argv" && ok \
  || bad "pg-collation-flags: initdb argv '$(cat "$T/initdb.argv")'"
grep -qx 'HARNESS_PG: started (locale en_US.UTF-8, collation en_US.UTF-8)' "$OUT" && ok || bad "pg-collation-flags: started line: $(cat "$OUT")"
grep -q 'npm run test LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8' "$T/npm.log" && ok || bad "pg-collation-flags: the suite env: $(cat "$T/npm.log")"
grep -qx 'HARNESS_EXIT: 0' "$OUT" && ok || bad "pg-collation-flags: exit: $(cat "$OUT")"

# ── pg-collation-knob ───────────────────────────────────────────────────────
settings '{"lib.ci-env.ci_pg_collation":"de_DE.UTF-8"}'
POOL_TEST_POSTGRES=1 suite "$T/loc-de" 'exit 0'
grep -q -- '--locale=en_US.UTF-8 --lc-collate=de_DE.UTF-8 --lc-ctype=de_DE.UTF-8' "$T/initdb.argv" && ok \
  || bad "pg-collation-knob: CI_PG_COLLATION=de_DE.UTF-8 argv '$(cat "$T/initdb.argv")'"
# The collation the box does not have stops the run too.
POOL_TEST_POSTGRES=1 suite "$T/loc-en" 'exit 0'
grep -qx 'HARNESS_EXIT: could-not-run' "$OUT" && ok || bad "pg-collation-knob: missing collation must be could-not-run: $(cat "$OUT")"
settings '{}'

# ── pg-locale-missing ───────────────────────────────────────────────────────
: > "$T/initdb.argv"
got=$(cd "$T" && HARNESS="$H" PATH="$T/loc-c:$T/fakebin:$PATH" PGT_BIN_DIR="$T/pgbin" PGT_ROOTS="$T/tmp" \
  bash -c '. "$0"; . "$1"; pgt_start "$2"; echo "rc=$?"' "$CE" "$H/bin/lib/pg-test.sh" "$T/pgm.out")
[ "$got" = "rc=3" ] && ok || bad "pg-locale-missing: pgt_start rc '$got', want 3"
grep -qx 'HARNESS_PG: could-not-start (locale en_US.UTF-8 not installed)' "$T/pgm.out" && ok || bad "pg-locale-missing: line '$(cat "$T/pgm.out")'"
[ -s "$T/initdb.argv" ] && bad "pg-locale-missing: initdb ran: $(cat "$T/initdb.argv")" || ok

# ── pg-no-lib-unchanged ─────────────────────────────────────────────────────
SH="$H0"; POOL_TEST_POSTGRES=1 suite "$T/loc-en" 'exit 0'; SH="$H"
[ -s "$T/initdb.argv" ] && ok || bad "pg-no-lib-unchanged: initdb must run"
grep -q -- '--locale\|--lc-collate\|--lc-ctype' "$T/initdb.argv" && bad "pg-no-lib-unchanged: locale flags with no lib: $(cat "$T/initdb.argv")" || ok
grep -q '^HARNESS_PG: started' "$OUT" && bad "pg-no-lib-unchanged: started line with no lib" || ok
grep -qx 'HARNESS_EXIT: 0' "$OUT" && ok || bad "pg-no-lib-unchanged: exit: $(cat "$OUT")"

# ── suite-sort-fixture (acceptance 1) ───────────────────────────────────────
# The fixture's test expects byte order (B before a). glibc en_US puts a first.
SORT_TEST='[ "$(printf "a\nB\n" | sort | tr "\n" " ")" = "B a " ] || { echo "FAIL sort order: $(printf "a\nB\n" | sort | tr "\n" " ")"; exit 1; }'
( cd "$T" && LC_ALL=C bash -c "$SORT_TEST" ) && ok || bad "suite-sort-fixture: the fixture must pass under LC_ALL=C"
settings '{"lib.ci-env.ci_locale":"C"}'
suite "$T/loc-en" "$SORT_TEST"
grep -qx 'HARNESS_LOCALE: C (source: knob, collation C)' "$OUT" && ok || bad "suite-sort-fixture: locale line under the knob: $(cat "$OUT")"
grep -qx 'HARNESS_EXIT: 0' "$OUT" && ok || bad "suite-sort-fixture: green under C: $(cat "$OUT")"
settings '{}'
suite "$T/loc-en" "$SORT_TEST"
grep -qx 'HARNESS_LOCALE: en_US.UTF-8 (source: fallback, collation en_US.UTF-8)' "$OUT" && ok || bad "suite-sort-fixture: locale line: $(cat "$OUT")"
grep -q 'npm run test LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8' "$T/npm.log" && ok || bad "suite-sort-fixture: the suite must run with LC_ALL=en_US.UTF-8: $(cat "$T/npm.log")"
if [ "$(LC_ALL=en_US.UTF-8 bash -c 'printf "a\nB\n" | sort | head -1' 2>/dev/null)" = a ]; then
  suite "" "$SORT_TEST"
  grep -qx 'HARNESS_EXIT: 1' "$OUT" && ok || bad "suite-sort-fixture: red under en_US.UTF-8: $(cat "$OUT")"
else
  echo "SKIP suite-sort-fixture: en_US.UTF-8 not installed on this box (locale -a: $(locale -a 2>/dev/null | tr '\n' ' '))"
fi

# ── ci-local-step-locale ────────────────────────────────────────────────────
F="$T/cl"; scratch_rm "$F"; mkdir -p "$F"
git -C "$F" init -q -b main && git -C "$F" commit -q --allow-empty -m base
FBASE=$(git -C "$F" rev-parse HEAD)
echo x > "$F/x.txt"; git -C "$F" add x.txt; git -C "$F" commit -q -m head
cat > "$T/wf.yml" <<'YML'
name: fixture
on: pull_request
jobs:
  fx:
    name: Fixture job
    runs-on: fixture
    steps:
      - name: show locale
        run: echo "STEP-LC_ALL=${LC_ALL:-UNSET}"
YML
cl() { # cl <out> [env...]
  local o="$1"; shift
  env "$@" HARNESS="$T/not-a-harness" LANE_REGISTRY="$T/lanes.json" TMPDIR="$T/tmp" XDG_CACHE_HOME="$T/cache" \
    "$DIR/bin/ci-local.sh" --tree "$F" --base "$FBASE" --workflow "$T/wf.yml" --jobs "Fixture job" \
    --skip-rules-pack --budget 60 --out "$o" > "$o.stdout" 2>&1
}
cl "$T/cl1" CI_LOCALE=POSIX; rc=$?
[ "$rc" = 0 ] && ok || bad "ci-local-step-locale: knob POSIX run rc $rc: $(cat "$T/cl1.stdout")"
grep -qx 'STEP-LC_ALL=POSIX' "$T/cl1/step-1.log" 2>/dev/null && ok || bad "ci-local-step-locale: the step must see the knob locale: $(cat "$T/cl1/step-1.log" 2>/dev/null)"
# ci-local-fallback-unchanged: no knob, no workflow env -> the caller's LC_ALL, as before.
cl "$T/cl0" LC_ALL=POSIX; rc=$?
[ "$rc" = 0 ] && ok || bad "ci-local-fallback-unchanged: rc $rc: $(cat "$T/cl0.stdout")"
grep -qx 'STEP-LC_ALL=POSIX' "$T/cl0/step-1.log" 2>/dev/null && ok || bad "ci-local-fallback-unchanged: the step must keep the caller's LC_ALL: $(cat "$T/cl0/step-1.log" 2>/dev/null)"
# ci-local-step-locale (workflow): a top-level env LC_ALL reaches the step.
sed -i 's/^on: pull_request$/on: pull_request\nenv:\n  LC_ALL: C.UTF-8/' "$T/wf.yml"
cl "$T/cl3" LC_ALL=POSIX; rc=$?
grep -qx 'STEP-LC_ALL=C.UTF-8' "$T/cl3/step-1.log" 2>/dev/null && ok || bad "ci-local-step-locale: the workflow env locale must reach the step: $(cat "$T/cl3/step-1.log" 2>/dev/null) rc=$rc"
# ci-local-locale-missing
cl "$T/cl2" CI_LOCALE=en_US.UTF-8 PATH="$T/loc-c:$PATH"; rc=$?
[ "$rc" = 2 ] && ok || bad "ci-local-step-locale: a missing locale is rc 2, got $rc: $(cat "$T/cl2.stdout")"
grep -q 'COULD-NOT-RUN Fixture job / show locale.*locale en_US.UTF-8 not installed' "$T/cl2.stdout" && ok \
  || bad "ci-local-step-locale: the step must be COULD-NOT-RUN with the reason: $(cat "$T/cl2.stdout")"
[ -e "$T/cl2/step-1.log" ] && bad "ci-local-step-locale: the step ran with no CI locale" || ok

echo "prepr-ci-parity.bh-9285: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
