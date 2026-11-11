#!/bin/bash
# tests/fresh-main-guards.bh-9471-test.sh — BH-9471 (slice C1 of #9414, #9285
# Fix 3): before the push, the pre-PR gate fetches main and runs every guard
# suite main changed after the build's base, on the branch merged with main.
#
#   vr-green / vr-red / vr-timeout-could-not-run / vr-no-runner / vr-npm-127
#   vr-locale-missing / vr-deps-linked-and-removed / vr-deps-missing-could-not-run
#   vr-no-file / vr-bad-budget                                   vr_run_files
#   guard-added-on-main-runs (acceptance 3, red and green) / guard-modified-on-main-runs
#   glob-guard-added-on-main / no-guard-change-noop / non-guard-change-ignored
#   guard-deleted-on-main-ignored / guard-changed-only-on-branch-ignored
#   guard-changed-before-fork-ignored / e2e-guard-on-main-ignored
#   merge-conflict-could-not-run / fetch-fail-could-not-run / budget-spent-could-not-run
#   bad-base-could-not-run / guard-list-unreadable-could-not-run
#   locale-missing-could-not-run / mixed-red-then-could-not-run
#   impact-gate-repo-skipped / knob-off / cleanup-no-leftover-ref          fmg_run
#   prepr-product-repo-red / prepr-product-repo-could-not-run-stays-skipped
#   prepr-gates-repo-red / prepr-run-brief-and-log / prepr-red-does-not-block
#   prepr-fix-turn-fixes / prepr-fix-turn-unverified / prepr-no-lib-unchanged
#                                                         prepr_scan, prepr_gate
#
# The real libs run from a scratch harness. Each case builds its own bare
# origin and clone (a local path: 0 network calls). Guards are .sh files run by
# `bash <file>`; npm is a stub on PATH. Nothing is written outside $T.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
unset FRESH_MAIN_GUARDS FMG_BUDGET_S VR_DEPS_FROM CI_LOCALE CI_PG_COLLATION POOL_TEST_POSTGRES \
      CI_LOCAL_GATE CI_LOCAL_BUDGET_S CL_BUDGET_CAP VERIFY_GUARD_SOURCES VERIFY_GUARD_MAX
NOW=1794190000
export GIT_AUTHOR_DATE="2026-11-11T02:00:00Z" GIT_COMMITTER_DATE="2026-11-11T02:00:00Z"
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR" "$T/fakebin"

FMG_LIB="$DIR/bin/lib/fresh-main-guards.sh"
VR_LIB="$DIR/bin/lib/verify-run.sh"
[ -r "$FMG_LIB" ] && [ -r "$VR_LIB" ] && ok || bad "setup: bin/lib/fresh-main-guards.sh or bin/lib/verify-run.sh is missing"

# H: the prepr gate's closure plus the new libs. H0: the same without
# fresh-main-guards.sh (the control for a box that has not got this slice).
H="$T/h"; H0="$T/h0"; mkdir -p "$H/state" "$H0/state"
for f in bin/lib/prepr-gate.sh bin/lib/fresh-main-guards.sh bin/lib/verify-run.sh bin/lib/verify-guards.sh \
         bin/lib/ci-local-verify.sh bin/lib/ci-env.sh bin/lib/pg-test.sh bin/lib/lane-gate.sh; do
  scratch_install_closure "$f" "$H" > /dev/null || bad "setup: cannot install $f"
done
for f in bin/lib/prepr-gate.sh bin/lib/ci-local-verify.sh bin/lib/lane-gate.sh; do
  scratch_install_closure "$f" "$H0" > /dev/null || bad "setup: cannot install $f in H0"
done
rm -f "$H0/bin/lib/fresh-main-guards.sh" "$H0/bin/lib/verify-run.sh"
cmp -s "$H/bin/lib/fresh-main-guards.sh" "$FMG_LIB" && cmp -s "$H/bin/lib/verify-run.sh" "$VR_LIB" \
  && ok || bad "setup: the scratch harness does not carry this tree's new libs"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" > "$T/lanes.json" 2> "$T/lanes.err" \
  && [ -s "$T/lanes.json" ] && ok || bad "setup: could not compose the lanes registry: $(head -3 "$T/lanes.err")"
export LANE_REGISTRY="$T/lanes.json" LANE_GATE_NOW="$NOW"

# settings <json-values> — the settings cache lane_knob reads. Locale C is
# always installed; the Postgres knob stays at its default (off).
settings() { printf '{"fetched_at":%s,"values":%s,"seeded":{}}\n' "$NOW" "$1" > "$H/state/settings-cache.json"; }
BASE_SETTINGS='"lib.ci-env.ci_locale":"C"'
settings "{$BASE_SETTINGS}"
printf '{"fetched_at":%s,"values":{%s},"seeded":{}}\n' "$NOW" "$BASE_SETTINGS" > "$H0/state/settings-cache.json"

# The stub npm: records argv and whether node_modules is a link, exits $NPM_RC.
cat > "$T/fakebin/npm" <<'SH'
#!/bin/bash
printf 'argv: %s\n' "$*" >> "$NPM_LOG"
[ -L node_modules ] && echo "node_modules: link" >> "$NPM_LOG"
printf 'LC_ALL=%s\n' "${LC_ALL:-}" >> "$NPM_LOG"
exit "${NPM_RC:-0}"
SH
chmod +x "$T/fakebin/npm"

GUARD_MARKER='#!/bin/bash
if grep -rq BAD src 2>/dev/null; then echo "FAIL: marker BAD found in src"; exit 1; fi
echo "ok: no marker in src"'
GUARD_PASS='#!/bin/bash
echo "ok: always"'

# ── fixture: a bare origin, a seed clone that plays main, a build clone ────────
# mk <case>: origin + seed with a base commit. Then sput/sdel/scommit on main,
# fork (clones the build at main's head, branch ticket/x), wput/wcommit on the
# branch, and more sput/scommit for main after the fork.
mk() {
  C="$T/c-$1"; scratch_rm "$C"; mkdir -p "$C"
  git init -q --bare -b main "$C/origin.git"
  git clone -q "$C/origin.git" "$C/seed" 2>/dev/null
  git -C "$C/seed" checkout -q -b main 2>/dev/null
  sput src/ok.txt fine; sput README.md base; scommit base
}
sput()    { mkdir -p "$C/seed/$(dirname -- "$1")"; printf '%s\n' "$2" > "$C/seed/$1"; }
sdel()    { git -C "$C/seed" rm -q -- "$1"; }
scommit() { git -C "$C/seed" add -A && git -C "$C/seed" commit -q -m "$1" && git -C "$C/seed" push -q origin main 2>/dev/null; }
fork()    { git clone -q "$C/origin.git" "$C/wt" 2>/dev/null; git -C "$C/wt" checkout -q -b ticket/x; W="$C/wt"; }
wput()    { mkdir -p "$W/$(dirname -- "$1")"; printf '%s\n' "$2" > "$W/$1"; }
wcommit() { git -C "$W" add -A && git -C "$W" commit -q -m "$1"; }

# fm <wt> [base] [env...] — fmg_run in a clean shell: sets WORD, RC, OUT.
fm() {
  local w="$1" b="${2:-main}"; shift 2 2>/dev/null || shift $#
  OUT="$C/fmg"; scratch_rm "$OUT"
  WORD=$(env PATH="$T/fakebin:$PATH" HARNESS="$H" PROJECT=fx FMG_BUDGET_S=60 "$@" \
    bash -c '. "$0" || exit 9; fmg_run "$1" "$2" "$3"' "$H/bin/lib/fresh-main-guards.sh" "$w" "$b" "$OUT" 2> "$C/fm.err"); RC=$?
}
ran()     { grep -c '^== fresh-main guard ' "$OUT/run.log" 2>/dev/null || true; }
# clean_after <case> — no private ref, no temp worktree, no fmg.* dir left.
clean_after() {
  local refs wts left
  refs=$(git -C "$W" for-each-ref refs/harness/ 2>/dev/null)
  wts=$(git -C "$W" worktree list 2>/dev/null | grep -c .)
  left=$(find "$TMPDIR" -maxdepth 1 -name 'fmg.*' 2>/dev/null | grep -c .)
  [ -z "$refs" ] && [ "$wts" = 1 ] && [ "$left" = 0 ] && ok \
    || bad "cleanup-no-leftover-ref ($1): refs='$refs' worktrees=$wts fmg-dirs=$left"
}

# ════ vr_run_files ═════════════════════════════════════════════════════════════
# vr <dir> <budget> <file>... — word, rc and VR_WHY from one call in a clean shell.
vr() {
  local d="$1" bgt="$2"; shift 2
  VOUT=$(env PATH="$T/fakebin:$PATH" HARNESS="$H" PROJECT=fx NPM_LOG="$T/npm.log" ${VENV[@]+"${VENV[@]}"} \
    bash -c '. "$0" || exit 9; d="$1" o="$2" b="$3"; shift 3; vr_run_files "$d" "$o" "$b" "$@" > "$o.word"; r=$?; printf "%s|%s|%s" "$(cat "$o.word")" "$r" "$VR_WHY"' \
    "$H/bin/lib/verify-run.sh" "$d" "$T/vr.log" "$bgt" "$@")
}
VENV=()
V="$T/vr"; mkdir -p "$V"
printf '#!/bin/bash\necho "ok: green"\n' > "$V/g.sh"
printf '#!/bin/bash\necho "FAIL: red"; exit 3\n' > "$V/r.sh"
printf '#!/bin/bash\nsleep 5\n' > "$V/slow.sh"
printf 'x\n' > "$V/a.test.ts"

: > "$T/vr.log"; vr "$V" 30 g.sh
[ "$VOUT" = "green|0|" ] && grep -q '^HARNESS_LOCALE: C (source: knob' "$T/vr.log" && grep -q 'ok: green' "$T/vr.log" \
  && ok || bad "vr-green: '$VOUT' $(head -3 "$T/vr.log")"
vr "$V" 30 g.sh r.sh
[ "$VOUT" = "red|1|" ] && ok || bad "vr-red: '$VOUT'"
vr "$V" 1 slow.sh
case "$VOUT" in "could-not-run|2|timed out"*) ok ;; *) bad "vr-timeout-could-not-run: '$VOUT'" ;; esac
vr "$V" 30 a.test.ts
case "$VOUT" in "could-not-run|2|no runner"*) ok ;; *) bad "vr-no-runner: '$VOUT'" ;; esac
N="$T/vr-npm"; mkdir -p "$N/node_modules"; printf '{"scripts":{"test":"vitest"}}\n' > "$N/package.json"; printf 'x\n' > "$N/a.test.ts"
VENV=(NPM_RC=127); vr "$N" 30 a.test.ts; VENV=()
case "$VOUT" in "could-not-run|2|exit 127"*) ok ;; *) bad "vr-npm-127: '$VOUT'" ;; esac
settings '{"lib.ci-env.ci_locale":"zz_ZZ.UTF-8"}'
vr "$V" 30 g.sh
case "$VOUT" in "could-not-run|2|HARNESS_LOCALE: could-not-run (locale zz_ZZ.UTF-8 not installed"*) ok ;; *) bad "vr-locale-missing: '$VOUT'" ;; esac
settings "{$BASE_SETTINGS}"
D="$T/vr-deps"; P="$T/vr-deps-src"; mkdir -p "$D" "$P/node_modules"; printf 'keep\n' > "$P/node_modules/keep"
printf '{"scripts":{"test:unit":"vitest","test":"x"}}\n' > "$D/package.json"; printf 'x\n' > "$D/a.test.ts"
: > "$T/npm.log"; VENV=(VR_DEPS_FROM="$P"); vr "$D" 30 a.test.ts; VENV=()
[ "$VOUT" = "green|0|" ] && grep -qx 'argv: run test:unit -- a.test.ts' "$T/npm.log" && grep -qx 'node_modules: link' "$T/npm.log" \
  && grep -qx 'LC_ALL=C' "$T/npm.log" && [ ! -e "$D/node_modules" ] && [ -f "$P/node_modules/keep" ] \
  && ok || bad "vr-deps-linked-and-removed: '$VOUT' $(cat "$T/npm.log") left=$(ls -a "$D")"
VENV=(VR_DEPS_FROM="$T/nowhere"); vr "$D" 30 a.test.ts; VENV=()
case "$VOUT" in "could-not-run|2|no node_modules"*) ok ;; *) bad "vr-deps-missing-could-not-run: '$VOUT'" ;; esac
vr "$V" 30
r1="$VOUT"; vr "$V" 30 missing.sh
case "$r1/$VOUT" in "could-not-run|2|no file to run/could-not-run|2|no file missing.sh") ok ;; *) bad "vr-no-file: '$r1' '$VOUT'" ;; esac
vr "$V" abc g.sh; r1="$VOUT"; vr "$V" 0 g.sh
case "$r1/$VOUT" in "could-not-run|2|bad budget 'abc'/could-not-run|2|bad budget '0'") ok ;; *) bad "vr-bad-budget: '$r1' '$VOUT'" ;; esac

# ════ fmg_run ══════════════════════════════════════════════════════════════════
# ── guard-added-on-main-runs (acceptance 3) ────────────────────────────────────
mk add-red; fork; wput src/x.txt BAD; wcommit "branch adds a marker"
sput tests/static-guards/marker-guard.sh "$GUARD_MARKER"; scommit "main adds a guard (TK-3485 shape)"
fm "$W"
[ "$WORD" = red ] && [ "$RC" = 1 ] \
  && [ "$(cat "$OUT/findings.txt")" = "FRESH-MAIN-GUARD tests/static-guards/marker-guard.sh: FAIL: marker BAD found in src" ] \
  && grep -qx 'state=red' "$OUT/fmg.txt" && ok || bad "guard-added-on-main-runs (red): $WORD rc $RC: $(cat "$OUT/findings.txt" "$OUT/fmg.txt" "$C/fm.err")"
clean_after red

mk add-green; fork; wput src/x.txt good; wcommit "branch adds a clean file"
sput tests/static-guards/marker-guard.sh "$GUARD_MARKER"; scommit "main adds a guard"
fm "$W"
[ "$WORD" = clean ] && [ "$RC" = 0 ] && [ "$(ran)" = 1 ] && grep -q 'ok: no marker in src' "$OUT/run.log" \
  && grep -q '^1 changed on main' "$OUT/fmg.txt" && [ ! -s "$OUT/findings.txt" ] \
  && ok || bad "guard-added-on-main-runs (green): $WORD rc $RC: $(cat "$OUT/fmg.txt")"
clean_after clean

# ── guard-modified-on-main-runs ────────────────────────────────────────────────
mk mod; sput tests/static-guards/marker-guard.sh "$GUARD_PASS"; scommit "base guard"
fork; wput src/x.txt BAD; wcommit "branch adds a marker"
sput tests/static-guards/marker-guard.sh "$GUARD_MARKER"; scommit "main tightens the guard"
fm "$W"
[ "$WORD" = red ] && [ "$(ran)" = 1 ] && grep -q '^FRESH-MAIN-GUARD tests/static-guards/marker-guard.sh: ' "$OUT/findings.txt" \
  && ok || bad "guard-modified-on-main-runs: $WORD: $(cat "$OUT/fmg.txt")"

# ── glob-guard-added-on-main ───────────────────────────────────────────────────
mk glob; sput scripts/ci/lane-rules.json '{"alwaysSuites":["checks/*.guard.sh"],"alwaysFull":["checks/full.sh"]}'; scommit "lane rules"
fork; wput src/y.txt y; wcommit branch
sput checks/a.guard.sh $'#!/bin/bash\necho "FAIL: glob guard"; exit 1'
sput checks/full.sh $'#!/bin/bash\necho "FAIL: alwaysFull must not run"; exit 1'; scommit "main adds a glob guard"
fm "$W"
[ "$WORD" = red ] && [ "$(ran)" = 1 ] && [ "$(cat "$OUT/findings.txt")" = "FRESH-MAIN-GUARD checks/a.guard.sh: FAIL: glob guard" ] \
  && ! grep -q 'full.sh' "$OUT/run.log" && ok || bad "glob-guard-added-on-main: $WORD: $(cat "$OUT/findings.txt" "$OUT/fmg.txt")"

# ── no-guard-change-noop ───────────────────────────────────────────────────────
mk noop; sput tests/static-guards/marker-guard.sh "$GUARD_MARKER"; scommit "base guard"
fork; wput src/x.txt BAD; wcommit branch
sput docs/a.md doc; scommit "main docs"
fm "$W"
[ "$WORD" = clean ] && [ "$(ran)" = 0 ] && grep -q '^0 changed on main' "$OUT/fmg.txt" \
  && ok || bad "no-guard-change-noop: $WORD ran $(ran): $(cat "$OUT/fmg.txt")"

# ── non-guard-change-ignored ───────────────────────────────────────────────────
mk nonguard; sput tests/static-guards/marker-guard.sh "$GUARD_MARKER"; scommit "base guard"
fork; wput src/x.txt BAD; wcommit branch
sput src/y.ts 'export const y = 1'; sput tests/unit/y.test.sh "$GUARD_PASS"; scommit "main changes source and a non-guard test"
fm "$W"
[ "$WORD" = clean ] && [ "$(ran)" = 0 ] && ok || bad "non-guard-change-ignored: $WORD ran $(ran)"

# ── guard-deleted-on-main-ignored ──────────────────────────────────────────────
mk deleted; sput tests/static-guards/marker-guard.sh "$GUARD_MARKER"; scommit "base guard"
fork; wput src/x.txt BAD; wcommit branch
sdel tests/static-guards/marker-guard.sh; scommit "main deletes the guard"
fm "$W"
[ "$WORD" = clean ] && [ "$(ran)" = 0 ] && ok || bad "guard-deleted-on-main-ignored: $WORD ran $(ran): $(cat "$OUT/fmg.txt")"

# ── guard-changed-only-on-branch-ignored ───────────────────────────────────────
mk branchonly; sput tests/static-guards/marker-guard.sh "$GUARD_PASS"; sput tests/static-guards.txt tests/b.guard.sh
sput tests/b.guard.sh "$GUARD_PASS"; scommit "base guards"
fork; wput tests/static-guards/marker-guard.sh $'#!/bin/bash\necho "FAIL: branch"; exit 1'
wput tests/b.guard.sh $'#!/bin/bash\necho "FAIL: branch"; exit 1'; wcommit "branch edits guards"
sput docs/a.md doc; scommit "main docs"
fm "$W"
[ "$WORD" = clean ] && [ "$(ran)" = 0 ] && ok || bad "guard-changed-only-on-branch-ignored: $WORD ran $(ran)"

# ── guard-changed-before-fork-ignored ──────────────────────────────────────────
mk beforefork; sput tests/static-guards/marker-guard.sh "$GUARD_MARKER"; scommit "main adds the guard BEFORE the fork"
fork; wput src/x.txt BAD; wcommit branch
sput docs/a.md doc; scommit "main docs after the fork"
fm "$W"
[ "$WORD" = clean ] && [ "$(ran)" = 0 ] && ok || bad "guard-changed-before-fork-ignored: $WORD ran $(ran)"

# ── e2e-guard-on-main-ignored ──────────────────────────────────────────────────
mk e2e; fork; wput src/x.txt x; wcommit branch
sput e2e/smoke.guard.sh $'#!/bin/bash\necho "FAIL: e2e ran"; exit 1'; sput tests/static-guards.txt e2e/smoke.guard.sh
scommit "main lists an e2e guard"
fm "$W"
[ "$WORD" = clean ] && [ "$(ran)" = 0 ] && ok || bad "e2e-guard-on-main-ignored: $WORD ran $(ran)"

# ── merge-conflict-could-not-run ───────────────────────────────────────────────
mk conflict; fork; wput src/ok.txt branch-side; wcommit branch
sput src/ok.txt main-side; sput tests/static-guards/marker-guard.sh "$GUARD_MARKER"; scommit "main conflicts and adds a guard"
fm "$W"
[ "$WORD" = could-not-run ] && [ "$RC" = 2 ] && grep -q 'merge conflict with origin/main' "$OUT/fmg.txt" && [ "$(ran)" = 0 ] \
  && ok || bad "merge-conflict-could-not-run: $WORD: $(cat "$OUT/fmg.txt")"
clean_after conflict

# ── fetch-fail-could-not-run ───────────────────────────────────────────────────
mk fetchfail; fork; wput src/x.txt BAD; wcommit branch
sput tests/static-guards/marker-guard.sh "$GUARD_MARKER"; scommit "main adds a guard"
mv "$C/origin.git" "$C/origin.gone"
fm "$W"
[ "$WORD" = could-not-run ] && grep -q 'fetch of origin/main failed' "$OUT/fmg.txt" && [ "$(ran)" = 0 ] \
  && ok || bad "fetch-fail-could-not-run: $WORD: $(cat "$OUT/fmg.txt")"
clean_after fetch-fail
mv "$C/origin.gone" "$C/origin.git"

# ── budget-spent-could-not-run ─────────────────────────────────────────────────
fm "$W" main FMG_BUDGET_S=0
[ "$WORD" = could-not-run ] && grep -q 'budget spent' "$OUT/fmg.txt" && ok || bad "budget-spent-could-not-run (0): $WORD: $(cat "$OUT/fmg.txt")"
clean_after budget
mk slow; fork; wput src/x.txt x; wcommit branch
sput tests/static-guards/slow-guard.sh $'#!/bin/bash\nsleep 6\necho "ok: slow"'; scommit "main adds a slow guard"
fm "$W" main FMG_BUDGET_S=2
[ "$WORD" = could-not-run ] && [ "$RC" = 2 ] && ! grep -q 'ok: slow' "$OUT/run.log" \
  && ok || bad "budget-spent-could-not-run (slow guard): $WORD: $(cat "$OUT/fmg.txt")"
clean_after budget-slow

# ── bad-base-could-not-run ─────────────────────────────────────────────────────
mk badbase; fork; wput src/x.txt x; wcommit branch
sput tests/static-guards/marker-guard.sh "$GUARD_MARKER"; scommit "main adds a guard"
for b in -x 'a;b' 'a b' 'origin/-x'; do
  fm "$W" "$b"
  [ "$WORD" = could-not-run ] && grep -q 'bad base name' "$OUT/fmg.txt" && [ "$(ran)" = 0 ] \
    && ok || bad "bad-base-could-not-run ($b): $WORD: $(cat "$OUT/fmg.txt")"
done
fm "$W" origin/main
[ "$WORD" = clean ] && [ "$(ran)" = 1 ] && ok || bad "bad-base-could-not-run (origin/main is a good base): $WORD"

# ── guard-list-unreadable-could-not-run ────────────────────────────────────────
mk badjson; fork; wput src/x.txt x; wcommit branch
sput tests/static-guards/marker-guard.sh "$GUARD_MARKER"; sput scripts/ci/lane-rules.json '{bad'; scommit "main breaks the guard list"
fm "$W"
[ "$WORD" = could-not-run ] && grep -q 'guard list at origin/main' "$OUT/fmg.txt" && [ "$(ran)" = 0 ] \
  && ok || bad "guard-list-unreadable-could-not-run: $WORD: $(cat "$OUT/fmg.txt")"

# ── locale-missing-could-not-run ───────────────────────────────────────────────
mk locale; fork; wput src/x.txt x; wcommit branch
sput tests/static-guards/marker-guard.sh "$GUARD_MARKER"; scommit "main adds a guard"
settings '{"lib.ci-env.ci_locale":"zz_ZZ.UTF-8"}'
fm "$W"
settings "{$BASE_SETTINGS}"
[ "$WORD" = could-not-run ] && grep -q 'HARNESS_LOCALE: could-not-run (locale zz_ZZ.UTF-8' "$OUT/fmg.txt" \
  && ! grep -q 'ok: no marker' "$OUT/run.log" && ok || bad "locale-missing-could-not-run: $WORD: $(cat "$OUT/fmg.txt")"

# ── mixed-red-then-could-not-run ───────────────────────────────────────────────
mk mixed; fork; wput src/x.txt x; wcommit branch
sput tests/static-guards/a-red.sh $'#!/bin/bash\necho "FAIL: a is red"; exit 1'
sput tests/static-guards/b-broken.sh $'#!/bin/bash\nexit 127'; scommit "main adds two guards"
fm "$W"
[ "$WORD" = could-not-run ] && [ "$RC" = 2 ] && grep -q '^FRESH-MAIN-GUARD tests/static-guards/a-red.sh: FAIL: a is red' "$OUT/findings.txt" \
  && grep -q 'guard tests/static-guards/b-broken.sh' "$OUT/fmg.txt" && ok || bad "mixed-red-then-could-not-run: $WORD: $(cat "$OUT/fmg.txt")"
MIXED_W="$W"

# ── impact-gate-repo-skipped ───────────────────────────────────────────────────
mk impact; sput bin/test-impact-gate.sh $'#!/bin/bash\nexit 0'; chmod +x "$C/seed/bin/test-impact-gate.sh"; scommit "the repo has an impact gate"
fork; wput src/x.txt BAD; wcommit branch
sput tests/static-guards/marker-guard.sh "$GUARD_MARKER"; scommit "main adds a guard"
fm "$W"
[ "$WORD" = skipped ] && [ "$RC" = 3 ] && [ "$(ran)" = 0 ] && ok || bad "impact-gate-repo-skipped: $WORD rc $RC"
clean_after skipped

# ── knob-off ───────────────────────────────────────────────────────────────────
mk off; fork; wput src/x.txt BAD; wcommit branch
sput tests/static-guards/marker-guard.sh "$GUARD_MARKER"; scommit "main adds a guard"
settings "{$BASE_SETTINGS,\"lib.fresh-main-guards.fresh_main_guards\":0}"
fm "$W"
[ "$WORD" = off ] && [ "$RC" = 4 ] && [ ! -s "$OUT/run.log" ] && ! grep -q 'changed on main\|fetch' "$OUT/fmg.txt" \
  && ok || bad "knob-off (row): $WORD rc $RC: $(cat "$OUT/fmg.txt")"
clean_after off
settings "{$BASE_SETTINGS,\"lib.fresh-main-guards.fx.fresh_main_guards\":0}"
fm "$W"
[ "$WORD" = off ] && ok || bad "knob-off (project row): $WORD"
settings "{$BASE_SETTINGS}"
fm "$W"
[ "$WORD" = red ] && ok || bad "knob-off (control: the default is on): $WORD"

# ════ the pre-PR gate ══════════════════════════════════════════════════════════
# stub CC: records the brief, runs $STUB_FIX in the worktree when set.
# ps <harness> <wt> <case> — prepr_scan . main <out>; sets PRC and PSCAN.
ps() {
  local h="$1" w="$2" c="$3"
  PO="$T/p-$c"; scratch_rm "$PO"
  ( cd "$w" && env PATH="$T/fakebin:$PATH" HARNESS="$h" PROJECT=fx bash -c '
      . "$HARNESS/bin/lib/prepr-gate.sh" || exit 9
      prepr_scan . main "$0"; r=$?
      echo "${PREPR_SCAN_FMG:-<unset>}" > "$0.fmg"; exit "$r"' "$PO" ) > "$T/p-$c.err" 2>&1; PRC=$?
  PSCAN=$(cat "$PO/prepr-scan.txt" 2>/dev/null)
}
# ── prepr-product-repo-red ─────────────────────────────────────────────────────
mk prod-red; fork; wput src/x.txt BAD; wcommit branch
sput tests/static-guards/marker-guard.sh "$GUARD_MARKER"; scommit "main adds a guard"
PROD_RED="$W"; PROD_RED_C="$C"
ps "$H" "$W" prod-red
[ "$PRC" = 1 ] && [ "$(cat "$PO.fmg")" = red ] && grep -qx 'fresh-main-guards: red' <<<"$PSCAN" \
  && grep -qx 'FRESH-MAIN-GUARD tests/static-guards/marker-guard.sh: FAIL: marker BAD found in src' "$PO/prepr-findings.txt" \
  && ok || bad "prepr-product-repo-red: rc $PRC fmg $(cat "$PO.fmg" 2>/dev/null): $PSCAN $(cat "$T/p-prod-red.err")"
# ── prepr-product-repo-could-not-run-stays-skipped ─────────────────────────────
mv "$C/origin.git" "$C/origin.gone"
ps "$H" "$W" prod-cnr
mv "$C/origin.gone" "$C/origin.git"
[ "$PRC" = 3 ] && grep -qx 'fresh-main-guards: could-not-run' <<<"$PSCAN" && grep -q 'could not run: could-not-run: fetch' <<<"$PSCAN" \
  && [ ! -s "$PO/prepr-findings.txt" ] && ok || bad "prepr-product-repo-could-not-run-stays-skipped: rc $PRC: $PSCAN"
ps "$H" "$MIXED_W" prod-mixed
[ "$PRC" = 3 ] && [ ! -s "$PO/prepr-findings.txt" ] && ok || bad "mixed-red-then-could-not-run (prepr_scan skip path): rc $PRC"
# ── prepr-gates-repo-red ───────────────────────────────────────────────────────
mk gates; sput bin/checks-run.sh $'#!/bin/bash\nexit 0'; sput bin/test-determinism-lint.sh $'#!/bin/bash\nexit 0'
chmod +x "$C/seed/bin/checks-run.sh" "$C/seed/bin/test-determinism-lint.sh"; scommit "the repo ships the two gates"
fork; wput src/x.txt BAD; wcommit branch
sput tests/static-guards/marker-guard.sh "$GUARD_MARKER"; scommit "main adds a guard"
ps "$H" "$W" gates
[ "$PRC" = 1 ] && grep -qx 'fresh-main-guards: red' <<<"$PSCAN" && grep -qx 'ci-local: skipped' <<<"$PSCAN" \
  && grep -qx 'FRESH-MAIN-GUARD tests/static-guards/marker-guard.sh: FAIL: marker BAD found in src' "$PO/prepr-findings.txt" \
  && grep -q '^in-diff=1 ' <<<"$PSCAN" && ok || bad "prepr-gates-repo-red: rc $PRC: $PSCAN $(cat "$T/p-gates.err")"

# pg <harness> <wt> <case> [env...] — the real prepr_gate with a stub CC.
pg() {
  local h="$1" w="$2" c="$3"; shift 3
  B="$T/b-$c"; scratch_rm "$B"; mkdir -p "$B"
  ( cd "$w" && env PATH="$T/fakebin:$PATH" HARNESS="$h" PROJECT=fx KEY=BH-1 BRANCH=ticket/x FIX_MODEL=fix-x STUB_FIX= "$@" bash -c '
      STAMP() { echo TS; }
      CC() { printf "%s\n" "$5" > "$0/brief.txt"; [ -n "$STUB_FIX" ] && bash "$STUB_FIX"; return 0; }
      . "$HARNESS/bin/lib/prepr-gate.sh" || exit 9
      prepr_gate . main "$0"
      declare -p PREPR_STATE PREPR_NOTE PREPR_SECTION PREPR_LINT_STATE PREPR_PACK_STATE > "$0/vars.sh"' "$B" ) > "$B.err" 2>&1
  PREPR_STATE="<unset>"; PREPR_LINT_STATE="<unset>"; PREPR_SECTION=""; PREPR_NOTE=""
  # declare -g: a plain `declare` sourced in this function would make locals.
  [ -f "$B/vars.sh" ] && sed 's/^declare -- /declare -g /' "$B/vars.sh" > "$B/vars.g.sh" && . "$B/vars.g.sh"
}
# ── prepr-run-brief-and-log / prepr-red-does-not-block ─────────────────────────
pg "$H" "$PROD_RED" red
grep -qF 'FRESH-MAIN-GUARD tests/static-guards/marker-guard.sh: FAIL: marker BAD found in src' "$B/brief.txt" 2>/dev/null \
  && grep -qF "The guard is main's: never edit it. Fix this branch's code so the guard passes." "$B/brief.txt" \
  && grep -qx 'fmg=red' "$B/prepr.txt" && grep -qx 'fix_calls=1' "$B/prepr.txt" \
  && grep -q 'PREPR fresh-main-guards=red red=1$' "$B/pipeline.log" \
  && ok || bad "prepr-run-brief-and-log: $(cat "$B/prepr.txt" "$B.err" 2>/dev/null) $(grep PREPR "$B/pipeline.log" 2>/dev/null)"
[ "$PREPR_STATE" = red ] && [ "$PREPR_LINT_STATE" = clean ] && [ "$PREPR_NOTE" = " | prepr=red" ] \
  && grep -qF 'Pre-PR gate: unresolved' <<<"$PREPR_SECTION" && grep -qF 'FRESH-MAIN-GUARD tests/static-guards/marker-guard.sh' <<<"$PREPR_SECTION" \
  && ok || bad "prepr-red-does-not-block: state=$PREPR_STATE lint=$PREPR_LINT_STATE section=$PREPR_SECTION"
# ── prepr-fix-turn-fixes: the fix turn edits the branch's code, the guard is green ─
printf 'printf "good\\n" > src/x.txt\ngit add -A && git commit -qm "fix the marker"\n' > "$T/fix-marker.sh"
pg "$H" "$PROD_RED" fixed STUB_FIX="$T/fix-marker.sh"
[ "$PREPR_STATE" = fixed ] && grep -qx 'fmg=clean' "$B/prepr.txt" && ok || bad "prepr-fix-turn-fixes: state=$PREPR_STATE $(cat "$B/prepr.txt" 2>/dev/null)"
# ── prepr-fix-turn-unverified: the re-scan after the turn cannot run the guard ──
mk unverified; fork; wput src/x.txt BAD; wcommit branch
sput tests/static-guards/marker-guard.sh "$GUARD_MARKER"; scommit "main adds a guard"
printf 'printf "good\\n" > src/x.txt\ngit add -A && git commit -qm "fix the marker"\nmv "%s/origin.git" "%s/origin.gone"\n' "$C" "$C" > "$T/fix-and-break.sh"
pg "$H" "$W" unverified STUB_FIX="$T/fix-and-break.sh"
mv "$C/origin.gone" "$C/origin.git"
[ "$PREPR_STATE" = red ] && grep -qx 'fmg=could-not-run' "$B/prepr.txt" && grep -qF 're-scan after the fix turn could not run' <<<"$PREPR_SECTION" \
  && ok || bad "prepr-fix-turn-unverified: state=$PREPR_STATE $(cat "$B/prepr.txt" 2>/dev/null)"
# ── prepr-no-lib-unchanged ─────────────────────────────────────────────────────
mk nolib; fork; wput src/x.txt BAD; wcommit branch
sput tests/static-guards/marker-guard.sh "$GUARD_MARKER"; scommit "main adds a guard"
ps "$H0" "$W" nolib
[ "$PRC" = 3 ] && grep -qx 'fresh-main-guards: off' <<<"$PSCAN" && [ ! -e "$PO/fmg" ] \
  && ok || bad "prepr-no-lib-unchanged: rc $PRC: $PSCAN $(cat "$T/p-nolib.err")"

echo "fresh-main-guards.bh-9471: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
