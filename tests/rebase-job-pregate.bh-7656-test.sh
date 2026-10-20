#!/bin/bash
# tests/rebase-job-pregate.bh-7656-test.sh — the pool rebase's generate step and
# the first failing file of a GATE_RED (BH-7656, T6 + T7).
#
# THE DEFECT. A fresh `git worktree add` never runs `postinstall`. project-6's
# postinstall is `prisma generate`, which writes a git-ignored client INSIDE
# the tree, so the pool rebase's typecheck was red on a green branch, and the
# RESULT said only `GATE_RED typecheck`. The fixture here is that shape: a
# git-ignored `src/lib/db/__generated__/client.ts` that only postinstall
# writes, and a typecheck that prints a tsc error and exits 2 without it.
#
# Cases (the REAL rebase_job_run on scratch git repos, the bh-543 fixture):
#   G1. main declares postinstall -> it runs, typecheck green, REBASED,
#       `GATE: typecheck=0`, and the generated file is not pushed.
#   G2. main lacks postinstall, the branch adds it -> it runs (read from the
#       merged tree), REBASED.
#   G3. no postinstall anywhere -> no run, typecheck red as before, and the
#       first line names the failing file (F13: the end-to-end line).
#   G4. no node_modules -> no run, gates skipped, REBASED.
#   G5. postinstall exits 3 and typecheck is then red ->
#       `GATE_RED typecheck: <file...> [postinstall rc=3]`; postinstall exits 3
#       and typecheck is green -> REBASED.
#   T.  no `rebase-log-*` file is left in $TMPDIR after any run.
#   F1-F12. _rj_first_fail on log shapes (matches and non-matches).
#   F14. the REAL mc_pool_rebase_apply applies a G5 RESULT: job done, rc 2, and
#        the .out text names the file. F15. bin/result-prefix-ok.sh accepts it.
#
# MUTATIONS THAT TURN THIS SUITE RED (checked 2026-10-20):
#   - delete the 6d `npm run postinstall` call      -> G1, G2, G5b red
#   - make _rj_first_fail print nothing             -> F1-F8, G3/F13, G5 red
#   - drop the `[postinstall rc=]` suffix in _rj_red -> G5 red
#
# Run from anywhere: bash tests/rebase-job-pregate.bh-7656-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
command -v jq  >/dev/null || { echo "jq missing — skipping"; exit 0; }

SLUG=o/tproj
LIB="$DIR/bin/lib/rebase-job.sh"
TSERR="src/lib/db/client.ts(3,24): error TS2307: Cannot find module './__generated__/client'"

export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global protocol.file.allow always
git config --global advice.detachedHead false

mkdir -p "$T/fakebin" "$T/wt" "$T/tmp" "$T/h/logs" "$T/h/state"
scratch_install_closure bin/lib/rebase-job.sh "$T/h" >/dev/null || { echo "closure install failed"; exit 1; }
scratch_install_closure bin/lib/merge-conductor-lib.sh "$T/h" >/dev/null || { echo "closure install failed"; exit 1; }
# unit runs through `npm run test:unit` only (the fixture has none): no select.
rm -f "$T/h/bin/test-select.sh"

# --- the faked binaries: npm runs the package.json script through bash ------
cat > "$T/fakebin/npm" <<'NPMEOF'
#!/bin/bash
[ "${1:-}" = run ] || exit 0
S=$(jq -r --arg s "$2" '.scripts[$s] // ""' package.json 2>/dev/null)
[ -n "$S" ] || exit 1
printf '\n> tproj@1.0.0 %s\n> %s\n\n' "$2" "$S"
bash -c "$S"; rc=$?
[ "$rc" = 0 ] || printf 'npm ERR! code ELIFECYCLE\nnpm ERR! errno %s\n' "$rc"
exit "$rc"
NPMEOF
. "$DIR/tests/lib/hold-fixture.sh" || exit 1
hold_fixture_gh "$T/fakebin" || exit 1
chmod +x "$T/fakebin/npm"
export PATH="$T/fakebin:$PATH" REBASE_WT_DIR="$T/wt" TMPDIR="$T/tmp"
export GEN_MARK="$T/gen-ran"

# --- the fixture -------------------------------------------------------------
# tools/gen.sh writes the git-ignored client (postinstall); tools/tc.sh is the
# typecheck: tsc's error line and exit 2 without the client, else exit 0.
PKG_GEN='{"name":"tproj","version":"1.0.0","scripts":{"postinstall":"sh tools/gen.sh","typecheck":"sh tools/tc.sh"}}'
PKG_NOGEN='{"name":"tproj","version":"1.0.0","scripts":{"typecheck":"sh tools/tc.sh"}}'
GEN_OK='#!/bin/sh
: > "$GEN_MARK"
mkdir -p src/lib/db/__generated__
echo "export const client = 1" > src/lib/db/__generated__/client.ts
'
GEN_FAIL='#!/bin/sh
: > "$GEN_MARK"
echo "Error: prisma schema not found" >&2
exit 3
'
GEN_WRITE_FAIL="${GEN_OK}exit 3
"

mkorigin() { # mkorigin <name> <main package.json> — origin + seed, FORK=its main
  git init -q --bare "$T/$1.git"
  git clone -q "$T/$1.git" "$T/$1.seed" 2>/dev/null
  mkdir -p "$T/$1.seed/tools" "$T/$1.seed/src/lib/db"
  printf '**/__generated__\nnode_modules\n' > "$T/$1.seed/.gitignore"
  printf '%s\n' "$2" > "$T/$1.seed/package.json"
  printf '%s' "$GEN_OK" > "$T/$1.seed/tools/gen.sh"
  cat > "$T/$1.seed/tools/tc.sh" <<EOF
#!/bin/sh
echo "tsc --noEmit"
if [ ! -f src/lib/db/__generated__/client.ts ]; then
  printf '%s\n' "$TSERR"
  echo "src/lib/db/other.ts(9,1): error TS2307: Cannot find module './__generated__/client'"
  echo "Found 2 errors in 2 files."
  exit 2
fi
exit 0
EOF
  echo "import { client } from './__generated__/client'" > "$T/$1.seed/src/lib/db/client.ts"
  git -C "$T/$1.seed" add -A && git -C "$T/$1.seed" commit -qm base1
  git -C "$T/$1.seed" push -q origin main
  FORK=$(git -C "$T/$1.seed" rev-parse HEAD)
}
mkbranch() { # mkbranch <origin> <branch> <file> <content> -> the pushed head
  git -C "$T/$1.seed" checkout -q -B "$2" "$FORK"
  mkdir -p "$(dirname "$T/$1.seed/$3")"
  printf '%s' "$4" > "$T/$1.seed/$3"
  git -C "$T/$1.seed" add -A && git -C "$T/$1.seed" commit -qm "$2" >/dev/null
  git -C "$T/$1.seed" push -q -f origin "$2"
  git -C "$T/$1.seed" rev-parse HEAD
}
movemain() { # movemain <origin> — main takes a commit no branch touches
  git -C "$T/$1.seed" checkout -q main
  echo z > "$T/$1.seed/z.txt"
  git -C "$T/$1.seed" add -A && git -C "$T/$1.seed" commit -qm main2 >/dev/null
  git -C "$T/$1.seed" push -q origin main
}

mkorigin gen "$PKG_GEN"
H_G1=$(mkbranch gen ticket/bh-41 d.txt 'g1')
H_G4=$(mkbranch gen ticket/bh-44 d.txt 'g4')
H_G5=$(mkbranch gen ticket/bh-45 tools/gen.sh "$GEN_FAIL")
H_G5B=$(mkbranch gen ticket/bh-46 tools/gen.sh "$GEN_WRITE_FAIL")
movemain gen
mkorigin nogen "$PKG_NOGEN"
H_G2=$(mkbranch nogen ticket/bh-42 package.json "$PKG_GEN")
H_G3=$(mkbranch nogen ticket/bh-43 d.txt 'g3')
movemain nogen

mkmachine() { # mkmachine <origin> [nodeps]
  rm -rf "$T/machine"
  git clone -q --depth 1 --single-branch "file://$T/$1.git" "$T/machine" 2>/dev/null
  [ "${2:-}" = nodeps ] || { mkdir -p "$T/machine/node_modules"; : > "$T/machine/node_modules/.keep"; }
  rm -f "$GEN_MARK"
}
RUNJOB() { # RUNJOB <branch> <head>
  rm -f "$T/RESULT"
  ( # shellcheck source=/dev/null
    . "$LIB"
    rebase_job_run "$T/machine" "$SLUG" "$1" "$2" main "$T/RESULT" "$T/h" ) >/dev/null 2>&1
}
R1()   { head -1 "$T/RESULT" 2>/dev/null; }
GATE() { grep '^GATE:' "$T/RESULT" 2>/dev/null; }
LEFT() { find "$T/tmp" -maxdepth 1 -name 'rebase-log-*' 2>/dev/null | wc -l | tr -d ' '; }

# ============================================================================
# G1. main declares postinstall: it runs before typecheck, REBASED
# ============================================================================
mkmachine gen
RUNJOB ticket/bh-41 "$H_G1"; RC=$?
[ "$RC" = 0 ] && ok || bad "G1: rc must be 0 (got $RC, RESULT '$(R1)')"
case "$(R1)" in REBASED\ *) ok ;; *) bad "G1: first line must be REBASED (got '$(R1)')" ;; esac
[ "$(GATE)" = "GATE: typecheck=0 unit=skipped" ] && ok || bad "G1: GATE line (got '$(GATE)')"
[ -e "$GEN_MARK" ] && ok || bad "G1: postinstall must have run"
git -C "$T/gen.seed" fetch -q origin
PUSHED=$(git -C "$T/gen.seed" ls-tree -r --name-only origin/ticket/bh-41)
[ -n "$PUSHED" ] && ok || bad "G1: could not read the pushed tree"
grep -q __generated__ <<<"$PUSHED" && bad "G1: the generated file must not be pushed" || ok
[ "$(LEFT)" = 0 ] && ok || bad "T: G1 left $(LEFT) rebase-log-* file(s) in TMPDIR"

# ============================================================================
# G2. the branch adds postinstall main lacked: read from the merged tree
# ============================================================================
mkmachine nogen
RUNJOB ticket/bh-42 "$H_G2"; RC=$?
[ "$RC" = 0 ] && ok || bad "G2: rc must be 0 (got $RC, RESULT '$(R1)')"
[ -e "$GEN_MARK" ] && ok || bad "G2: postinstall from the merged tree must have run"

# ============================================================================
# G3 / F13. no postinstall: no run, red, and the first line names the file
# ============================================================================
mkmachine nogen
RUNJOB ticket/bh-43 "$H_G3"; RC=$?
[ "$RC" = 1 ] && ok || bad "G3: rc must be 1 (got $RC)"
[ -e "$GEN_MARK" ] && bad "G3: no postinstall script, so none must run" || ok
[ "$(R1)" = "GATE_RED typecheck: $TSERR" ] && ok \
  || bad "F13: first line must name the first failing file (got '$(R1)')"
[ "$(GATE)" = "GATE: typecheck=2 unit=skipped" ] && ok || bad "G3: GATE line (got '$(GATE)')"
[ "$(LEFT)" = 0 ] && ok || bad "T: G3 left $(LEFT) rebase-log-* file(s) in TMPDIR"

# ============================================================================
# G4. no node_modules: no run, gates skipped
# ============================================================================
mkmachine gen nodeps
RUNJOB ticket/bh-44 "$H_G4"; RC=$?
[ "$RC" = 0 ] && ok || bad "G4: rc must be 0 (got $RC, RESULT '$(R1)')"
[ -e "$GEN_MARK" ] && bad "G4: no node_modules, so postinstall must not run" || ok
[ "$(GATE)" = "GATE: typecheck=skipped unit=skipped" ] && ok || bad "G4: GATE line (got '$(GATE)')"

# ============================================================================
# G5. a failing postinstall: typecheck decides, and a red names the rc
# ============================================================================
mkmachine gen
( export REBASE_JOB_URL="https://github.com/$SLUG/pull/45"; RUNJOB ticket/bh-45 "$H_G5" ); RC=$?
[ "$RC" = 1 ] && ok || bad "G5: rc must be 1 (got $RC)"
[ "$(R1)" = "GATE_RED typecheck: $TSERR [postinstall rc=3]" ] && ok \
  || bad "G5: first line must name the file and the postinstall rc (got '$(R1)')"
cp "$T/RESULT" "$T/RESULT.g5"
[ "$(LEFT)" = 0 ] && ok || bad "T: G5 left $(LEFT) rebase-log-* file(s) in TMPDIR"
mkmachine gen
RUNJOB ticket/bh-46 "$H_G5B"; RC=$?
[ "$RC" = 0 ] && ok || bad "G5b: postinstall rc 3 with a green typecheck must be REBASED (got $RC, '$(R1)')"

# ============================================================================
# F1-F12. _rj_first_fail on log shapes
# ============================================================================
# shellcheck source=bin/lib/rebase-job.sh
. "$LIB"
# `| ff` must count in THIS shell, not in a pipeline subshell.
shopt -s lastpipe
ff() { # ff <case> <expected> — the log is on stdin
  cat > "$T/ff.log"
  local got; got=$(_rj_first_fail "$T/ff.log")
  [ "$got" = "$2" ] && ok || bad "$1: expected '$2', got '$got'"
}
printf '> tsc --noEmit\n%s\nnpm ERR! code ELIFECYCLE\n' "$TSERR" | ff F1 "$TSERR"
printf '\033[96msrc/a.ts\033[0m:\033[93m4\033[0m:\033[93m7\033[0m - \033[91merror\033[0m\033[90m TS2322: \033[0mType x\n' \
  | ff F2 "src/a.ts:4:7 - error TS2322: Type x"
printf ' RUN  v1.6.0\n FAIL  tests/a.test.ts > adds\n' | ff F3 "FAIL  tests/a.test.ts > adds"
printf ' ✓ tests/ok.test.ts\n × tests/b.test.ts > x\n' | ff F4 "× tests/b.test.ts > x"
printf 'src/one.ts(1,1): error TS1005: a\nsrc/two.ts(2,2): error TS1005: b\n' | ff F5 "src/one.ts(1,1): error TS1005: a"
{ seq 1 5000 | sed 's/^/noise line /'; printf 'src/late.ts(7,7): error TS2304: late\n'; } \
  | ff F6 "src/late.ts(7,7): error TS2304: late"
LONG="src/long.ts(1,1): error TS2304: $(printf 'x%.0s' $(seq 1 400))"
printf '%s\n' "$LONG" | ff F7 "${LONG:0:200}"
printf 'src/t.ts(1,1): error TS2304:\tTabbed\r\n' | ff F8 "src/t.ts(1,1): error TS2304: Tabbed"
printf 'npm ERR! code ELIFECYCLE\nnpm ERR! errno 2\n' | ff F9 ""
printf '> pretypecheck\n> npm run registry\n' | ff F10 ""
printf 'src/x.ts(1,1): warning TS6133: unused\n' | ff F11 ""
printf ' ✓ tests/a.test.ts\nFAILED to fetch\n' | ff F12 ""
: | ff F12b ""
_rj_first_fail "$T/does-not-exist" >/dev/null 2>&1 && ok || bad "F12c: a missing log must be rc 0"

# ============================================================================
# F14 / F15. the hub reads a G5 RESULT
# ============================================================================
mkdir -p "$T/hub/logs" "$T/hub/state" "$T/hub/flags" "$T/hub/locks" "$T/hub/builds" "$T/hub/env"
scratch_install_closure bin/lib/merge-conductor-lib.sh "$T/hub" >/dev/null || { echo "closure install failed"; exit 1; }
: > "$T/hub/env/global.env"
OUT=$( export HARNESS="$T/hub" MC_REPOS="$T/repos"
  # shellcheck source=/dev/null
  . "$T/hub/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1; mc_init >/dev/null 2>&1
  mc_pool_rebase_apply tproj "RB-45-${H_G5:0:8}" "$T/RESULT.g5" >/dev/null 2>&1; arc=$?
  jf=$(mc_rb_file "$SLUG" 45 "$H_G5" 2>/dev/null)
  printf '%s %s %s|%s' "$arc" "$(jq -r .status "$jf" 2>/dev/null)" "$(jq -r .rc "$jf" 2>/dev/null)" \
    "$(cat "${jf%.json}.out" 2>/dev/null)" )
[ "${OUT%%|*}" = "0 done 2" ] && ok || bad "F14: apply of the G5 RESULT must be rc 0, job done, job rc 2 (got '${OUT%%|*}')"
case "${OUT#*|}" in *"src/lib/db/client.ts(3,24)"*) ok ;; *) bad "F14: the .out text must name the file (got '${OUT#*|}')" ;; esac
bash "$DIR/bin/result-prefix-ok.sh" "$(cat "$T/RESULT.g5")" && ok || bad "F15: result-prefix-ok must accept the G5 RESULT"

echo "rebase-job-pregate.bh-7656-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
