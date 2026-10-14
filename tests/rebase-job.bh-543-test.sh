#!/bin/bash
# tests/rebase-job.bh-543-test.sh — the MACHINE side of a pool rebase (BH-543).
#
# WHAT THIS PINS. `rebase_job_run` in bin/lib/rebase-job.sh is the body a pool
# machine runs when the hub hands it a rebase instead of doing one itself, and
# `run_rebase_job` in fly/builder-runner.sh is the only thing that calls it. The
# machine is the half that can PUSH, so every assertion here is about what
# actually reached a real bare origin, a real worktree and a real RESULT file —
# never about source text (D3).
#
# REAL GIT, NO NETWORK. $T/origin.git is a real bare repo; $T/machine is a real
# `git clone --depth 1 --single-branch` of it, which is what fly/Dockerfile's
# `--depth 50` clone looks like to this code: no merge base for a branch that
# forked before the boundary, and a single-branch refspec that drops a bare
# `fetch origin <branch>` into FETCH_HEAD only. Case (i) is that machine.
#
# Only `npm` and `gh` are faked. npm runs the package.json script through bash
# exactly as npm does; gh records its argv and is expected never to be called by
# the body at all.
#
# Run from anywhere: bash tests/rebase-job.bh-543-test.sh   (exit 0 = all pass)
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
BOGUS=1111111111111111111111111111111111111111

export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global protocol.file.allow always
git config --global advice.detachedHead false

mkdir -p "$T/fakebin" "$T/wt" "$T/h/bin/lib" "$T/h/logs" "$T/h/state"
cp "$DIR/bin/lib/rebase-job.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/gh-pr-list.sh" "$T/h/bin/lib/" 2>/dev/null
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/" 2>/dev/null
# BH-2504: the pool rebase pushes only through bin/lib/hold-push.sh (+ hold.sh).
. "$DIR/tests/lib/hold-fixture.sh" && hold_fixture_libs "$DIR" "$T/h" || exit 1
cp "$DIR/bin/result-prefix-ok.sh" "$T/h/bin/" 2>/dev/null

# --- the two faked binaries ---------------------------------------------------
cat > "$T/fakebin/npm" <<'NPMEOF'
#!/bin/bash
# npm run <script> — run the package.json script through bash, as npm does.
[ "${1:-}" = run ] || exit 0
S=$(jq -r --arg s "$2" '.scripts[$s] // ""' package.json 2>/dev/null)
[ -n "$S" ] || exit 1
bash -c "$S"
NPMEOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-argv.txt"
case "\$*" in *"pr list"*) echo '[]' ;; esac
exit 0
EOF
chmod +x "$T/fakebin/npm" "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
: > "$T/gh-argv.txt"

# --- gate knobs: the scripts the fixture's package.json runs -------------------
export GATE_TC_FILE="$T/tc-rc"    GATE_UNIT_FILE="$T/unit-rc"
export GATE_TC_MARK="$T/tc-ran"   GATE_UNIT_MARK="$T/unit-ran"
export GATE_TC_HOOK=""
export REBASE_WT_DIR="$T/wt"
gates() { printf '%s' "${1:-0}" > "$GATE_TC_FILE"; printf '%s' "${2:-0}" > "$GATE_UNIT_FILE"
          rm -f "$GATE_TC_MARK" "$GATE_UNIT_MARK"; GATE_TC_HOOK=""; }
gates 0 0

# ============================================================================
# The fixture: a real bare origin with three commits on main, then branches,
# then two MORE commits on main so a depth-1 machine clone has no merge base.
# ============================================================================
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
mkdir -p "$T/seed/tools"
cat > "$T/seed/tools/tc.sh" <<'EOF'
#!/bin/sh
echo tc >> "$GATE_TC_MARK"
if [ -n "${GATE_TC_HOOK:-}" ] && [ -x "$GATE_TC_HOOK" ]; then "$GATE_TC_HOOK"; fi
exit "$(cat "$GATE_TC_FILE")"
EOF
cat > "$T/seed/tools/unit.sh" <<'EOF'
#!/bin/sh
echo unit >> "$GATE_UNIT_MARK"
exit "$(cat "$GATE_UNIT_FILE")"
EOF
cat > "$T/seed/package.json" <<'EOF'
{
  "name": "tproj",
  "version": "1.0.0",
  "scripts": {
    "typecheck": "sh tools/tc.sh",
    "test:unit": "sh tools/unit.sh"
  }
}
EOF
printf 'a1\na2\na3\n' > "$T/seed/a.txt"
git -C "$T/seed" add -A && git -C "$T/seed" commit -qm base1
printf 'b\n' > "$T/seed/b.txt"; git -C "$T/seed" add -A && git -C "$T/seed" commit -qm base2
printf 'c\n' > "$T/seed/c.txt"; git -C "$T/seed" add -A && git -C "$T/seed" commit -qm base3
git -C "$T/seed" push -q origin main
FORK=$(git -C "$T/seed" rev-parse HEAD)

# mkbranch <name> <file> <content> — a branch off FORK with one commit, pushed.
mkbranch() {
  git -C "$T/seed" checkout -q -B "$1" "$FORK"
  printf '%s' "$3" > "$T/seed/$2"
  git -C "$T/seed" add -A && git -C "$T/seed" commit -qm "$1" >/dev/null
  git -C "$T/seed" push -q -f origin "$1"
  git -C "$T/seed" rev-parse HEAD
}

BR_CLEAN=ticket/bh-1;  H_CLEAN=$(mkbranch  "$BR_CLEAN"  d.txt 'clean branch file')
BR_CONF=ticket/bh-2;   H_CONF=$(mkbranch   "$BR_CONF"   a.txt 'a1-branch
a2
a3
')
BR_GATE=ticket/bh-3;   H_GATE=$(mkbranch   "$BR_GATE"   e.txt 'gate branch')
BR_GATE2=ticket/bh-4;  H_GATE2=$(mkbranch  "$BR_GATE2"  f.txt 'gate2 branch')
BR_SEL=ticket/bh-5;    H_SEL=$(mkbranch    "$BR_SEL"    g.txt 'select branch')
BR_LEASE=ticket/bh-6;  H_LEASE=$(mkbranch  "$BR_LEASE"  h.txt 'lease branch')
BR_NODEP=ticket/bh-7;  H_NODEP=$(mkbranch  "$BR_NODEP"  i.txt 'nodep branch')
BR_PUSH=ticket/bh-8;   H_PUSH=$(mkbranch   "$BR_PUSH"   j.txt 'push-lease branch')
BR_SHALLOW=ticket/bh-9;  H_SHALLOW=$(mkbranch  "$BR_SHALLOW"  k.txt 'shallow branch')
BR_SHALLOW2=ticket/bh-10; H_SHALLOW2=$(mkbranch "$BR_SHALLOW2" l.txt 'shallow branch 2')
BR_URL=ticket/bh-11;   H_URL=$(mkbranch    "$BR_URL"    m.txt 'url branch')
BR_PROT=ticket/bh-12;  H_PROT=$(mkbranch   "$BR_PROT"   n.txt 'protected-base branch')
BR_SETUP=ticket/bh-13; H_SETUP=$(mkbranch  "$BR_SETUP"  o.txt 'resolver-missing branch')

# the package.json conflict branch: both sides add a token to the test:unit line
BR_PKG=ticket/bh-14
git -C "$T/seed" checkout -q -B "$BR_PKG" "$FORK"
sed -i 's|"test:unit": "sh tools/unit.sh"|"test:unit": "sh tools/unit.sh BRANCHTOK"|' "$T/seed/package.json"
git -C "$T/seed" add -A && git -C "$T/seed" commit -qm pkg-branch >/dev/null
git -C "$T/seed" push -q origin "$BR_PKG"
H_PKG=$(git -C "$T/seed" rev-parse HEAD)

# a branch that ALREADY contains main (case l) — created after main moves below.

# --- main moves: two commits past the fork point, plus the package.json edit --
git -C "$T/seed" checkout -q main
printf 'a1-main\na2\na3\n' > "$T/seed/a.txt"
sed -i 's|"test:unit": "sh tools/unit.sh"|"test:unit": "sh tools/unit.sh MAINTOK"|' "$T/seed/package.json"
git -C "$T/seed" add -A && git -C "$T/seed" commit -qm main4 >/dev/null
printf 'p\n' > "$T/seed/p.txt"; git -C "$T/seed" add -A && git -C "$T/seed" commit -qm main5 >/dev/null
git -C "$T/seed" push -q origin main
MAIN=$(git -C "$T/seed" rev-parse main)

BR_UPTODATE=ticket/bh-15
git -C "$T/seed" checkout -q -B "$BR_UPTODATE" main
printf 'q\n' > "$T/seed/q.txt"
git -C "$T/seed" add -A && git -C "$T/seed" commit -qm uptodate >/dev/null
git -C "$T/seed" push -q origin "$BR_UPTODATE"
H_UPTODATE=$(git -C "$T/seed" rev-parse HEAD)

# ============================================================================
# The machine repo, and the helper that runs one job against it.
# ============================================================================
mkmachine() { # mkmachine [--full] [--nodeps]
  local full="" nodeps=""
  for a in "$@"; do case "$a" in --full) full=1 ;; --nodeps) nodeps=1 ;; esac; done
  rm -rf "$T/machine"
  if [ -n "$full" ]; then
    git clone -q "$T/origin.git" "$T/machine" 2>/dev/null
  else
    # file:// and not the bare path: git IGNORES --depth on a local-transport
    # clone, and a fixture that is not actually shallow proves nothing.
    git clone -q --depth 1 --single-branch "file://$T/origin.git" "$T/machine" 2>/dev/null
  fi
  [ -n "$nodeps" ] || { mkdir -p "$T/machine/node_modules"; : > "$T/machine/node_modules/.keep"; }
}

RUNJOB() { # RUNJOB <branch> <head> [<base>] [<harness>]
  local br="$1" head="$2" base="${3:-main}" hns="${4:-$T/h}"
  rm -f "$T/RESULT"
  ( # shellcheck source=/dev/null
    . "$LIB"
    rebase_job_run "$T/machine" "$SLUG" "$br" "$head" "$base" "$T/RESULT" "$hns" )
}

R1() { head -1 "$T/RESULT" 2>/dev/null; }
ORIGIN_SHA() { git -C "$T/origin.git" rev-parse "$1" 2>/dev/null; }

trailer_ok() { # trailer_ok <label> — (m): the RESULT shape, on EVERY case
  local f="$T/RESULT" l p i=2
  "$DIR/bin/result-prefix-ok.sh" "$(R1)" \
    || { bad "$1: the reap gate must read line 1 as a RESULT (got '$(R1)')"; return 1; }
  for p in "PR: " "HEAD: " "BRANCH: " "BASE: " "GATE: "; do
    l=$(sed -n "${i}p" "$f" 2>/dev/null)
    case "$l" in "$p"*) ;; *) bad "$1: RESULT line $i must start with '$p' (got '$l')"; return 1 ;; esac
    i=$((i+1))
  done
  ok
}

after() { # after <label> — cleanup is a per-case assertion, not a one-off
  [ -z "$(ls -A "$T/wt" 2>/dev/null)" ] \
    && ok || bad "$1: the worktree was left behind: $(ls -A "$T/wt")"
  [ "$(git -C "$T/machine" worktree list 2>/dev/null | wc -l)" = 1 ] \
    && ok || bad "$1: a stale worktree registration survived: $(git -C "$T/machine" worktree list 2>/dev/null | tr '\n' '|')"
  trailer_ok "$1"
}

line_is() { # line_is <label> <expected first line>
  [ "$(R1)" = "$2" ] && ok || bad "$1: first line must be '$2' (got '$(R1)')"
}

# ============================================================================
# (a) a clean branch rebases, pushes, and answers REBASED <sha>
# ============================================================================
gates 0 0; mkmachine
RUNJOB "$BR_CLEAN" "$H_CLEAN"; RC=$?
[ "$RC" = 0 ] && ok || bad "(a) a clean rebase must return 0 (got $RC, RESULT '$(R1)')"
NEW=$(ORIGIN_SHA "$BR_CLEAN")
[ "$(R1)" = "REBASED $NEW" ] && ok || bad "(a) line 1 must be 'REBASED <the sha now on origin>' (got '$(R1)', origin $NEW)"
[ "$NEW" != "$H_CLEAN" ] && ok || bad "(a) origin's branch must have MOVED"
PARENTS=$(git -C "$T/origin.git" rev-list --parents -n 1 "$NEW")
case " $PARENTS " in *" $MAIN "*) ok ;; *) bad "(a) the pushed sha must have origin/main as a parent (parents: $PARENTS)" ;; esac
case " $PARENTS " in *" $H_CLEAN "*) ok ;; *) bad "(a) the pushed sha must have the old head as a parent (parents: $PARENTS)" ;; esac
grep -qxF "PR: https://github.com/$SLUG/pull/-" "$T/RESULT" \
  && ok || bad "(a) with no REBASE_JOB_URL the PR line is the slug form with '-' (got '$(sed -n 2p "$T/RESULT")')"
grep -qxF "HEAD: $H_CLEAN" "$T/RESULT" && ok || bad "(a) HEAD: must be the head the hub leased"
grep -qxF "BRANCH: $BR_CLEAN" "$T/RESULT" && ok || bad "(a) BRANCH: must be the job's branch"
grep -qxF "BASE: main" "$T/RESULT" && ok || bad "(a) BASE: must be the job's base"
grep -qxF "GATE: typecheck=0 unit=0" "$T/RESULT" \
  && ok || bad "(a) both gates ran green (got '$(grep '^GATE:' "$T/RESULT")')"
[ -z "$(ls -A "$T/h/state" 2>/dev/null)" ] \
  && ok || bad "(a) the machine must rebind NOTHING — state/ is the hub's (found: $(ls -A "$T/h/state"))"
[ ! -s "$T/gh-argv.txt" ] && ok || bad "(a) the body must not call gh at all (argv: $(tr '\n' '|' < "$T/gh-argv.txt"))"
after "(a)"

# ============================================================================
# (a2) REBASE_JOB_URL is the PR line
# ============================================================================
gates 0 0; mkmachine
( export REBASE_JOB_URL="https://github.com/$SLUG/pull/21"
  RUNJOB "$BR_URL" "$H_URL" ) >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "(a2) rc must be 0 (got $RC, RESULT '$(R1)')"
grep -qxF "PR: https://github.com/$SLUG/pull/21" "$T/RESULT" \
  && ok || bad "(a2) REBASE_JOB_URL must become the PR line (got '$(sed -n 2p "$T/RESULT")')"
after "(a2)"

# ============================================================================
# (b) a real conflict: CONFLICT <paths>, nothing pushed, no merge commit
# ============================================================================
gates 0 0; mkmachine
RUNJOB "$BR_CONF" "$H_CONF"; RC=$?
[ "$RC" = 1 ] && ok || bad "(b) a conflict must return 1 (got $RC)"
line_is "(b)" "CONFLICT a.txt"
[ "$(ORIGIN_SHA "$BR_CONF")" = "$H_CONF" ] && ok || bad "(b) origin's branch must be untouched by a conflict"
[ "$(git -C "$T/machine" log --all --merges --oneline 2>/dev/null | wc -l)" = 0 ] \
  && ok || bad "(b) a conflicted merge must be aborted, never committed"
after "(b)"

# ============================================================================
# (c) a conflict the resolver OWNS (package.json test:unit line) is resolved,
#     committed and pushed. MUTATION: comment out the mc_resolve_conflicts call
#     in bin/lib/rebase-job.sh and this case goes red.
# ============================================================================
gates 0 0; mkmachine
RUNJOB "$BR_PKG" "$H_PKG"; RC=$?
[ "$RC" = 0 ] && ok || bad "(c) a resolver-owned conflict must rebase (got $RC, RESULT '$(R1)')"
case "$(R1)" in REBASED\ *) ok ;; *) bad "(c) first line must be REBASED (got '$(R1)')" ;; esac
PKG=$(git -C "$T/origin.git" show "$BR_PKG:package.json" 2>/dev/null)
printf '%s' "$PKG" | jq . >/dev/null 2>&1 \
  && ok || bad "(c) the pushed package.json must still parse as json (got: $PKG)"
grep -q BRANCHTOK <<<"$PKG" && ok || bad "(c) the branch's token must survive the resolve"
grep -q MAINTOK <<<"$PKG"   && ok || bad "(c) main's token must survive the resolve"
after "(c)"

# ============================================================================
# (d) a red typecheck is GATE_RED typecheck and pushes NOTHING
# ============================================================================
gates 1 0; mkmachine
RUNJOB "$BR_GATE" "$H_GATE"; RC=$?
[ "$RC" = 1 ] && ok || bad "(d) a red gate must return 1 (got $RC)"
line_is "(d)" "GATE_RED typecheck"
grep -qxF "GATE: typecheck=1 unit=skipped" "$T/RESULT" \
  && ok || bad "(d) the GATE line must record the real rc and that unit never ran (got '$(grep '^GATE:' "$T/RESULT")')"
[ "$(ORIGIN_SHA "$BR_GATE")" = "$H_GATE" ] && ok || bad "(d) a red gate must push nothing"
[ ! -f "$GATE_UNIT_MARK" ] && ok || bad "(d) the unit gate must not run after a red typecheck"
after "(d)"

# (d2) red unit
gates 0 1; mkmachine
RUNJOB "$BR_GATE2" "$H_GATE2"; RC=$?
[ "$RC" = 1 ] && ok || bad "(d2) a red unit gate must return 1 (got $RC)"
line_is "(d2)" "GATE_RED unit"
grep -qxF "GATE: typecheck=0 unit=1" "$T/RESULT" \
  && ok || bad "(d2) the GATE line must carry both rcs (got '$(grep '^GATE:' "$T/RESULT")')"
[ "$(ORIGIN_SHA "$BR_GATE2")" = "$H_GATE2" ] && ok || bad "(d2) a red unit gate must push nothing"
after "(d2)"

# ============================================================================
# (e) the lease: HEAD != <head> is refused BEFORE any merge
# ============================================================================
gates 0 0; mkmachine
RUNJOB "$BR_LEASE" "$BOGUS"; RC=$?
[ "$RC" = 1 ] && ok || bad "(e) a lost lease must return 1 (got $RC)"
line_is "(e)" "REBASE_LEASE_REJECTED head is $H_LEASE"
[ "$(ORIGIN_SHA "$BR_LEASE")" = "$H_LEASE" ] && ok || bad "(e) a lost lease must push nothing"
[ "$(git -C "$T/machine" log --all --merges --oneline 2>/dev/null | wc -l)" = 0 ] \
  && ok || bad "(e) the lease check must run BEFORE the merge — no merge commit may exist"
[ ! -f "$GATE_TC_MARK" ] && ok || bad "(e) a lost lease must not spend a gate"
after "(e)"

# ============================================================================
# (f) test-select.sh, when the harness has one, replaces npm run test:unit
# ============================================================================
gates 0 0; mkmachine
cat > "$T/h/bin/test-select.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" > "$T/select-argv.txt"
exit 0
EOF
chmod +x "$T/h/bin/test-select.sh"
rm -f "$T/select-argv.txt"
RUNJOB "$BR_SEL" "$H_SEL"; RC=$?
rm -f "$T/h/bin/test-select.sh"
[ "$RC" = 0 ] && ok || bad "(f) a green select run must rebase (got $RC, RESULT '$(R1)')"
grep -qxF "GATE: typecheck=0 unit=select" "$T/RESULT" \
  && ok || bad "(f) the unit slot must record 'select' (got '$(grep '^GATE:' "$T/RESULT")')"
SELARGV=$(cat "$T/select-argv.txt" 2>/dev/null)
[ "$(awk '{print $2}' <<<"$SELARGV")" = "$BR_SEL" ] \
  && ok || bad "(f) test-select.sh argv 2 must be the branch (got '$SELARGV')"
[ "$(awk '{print $3}' <<<"$SELARGV")" = main ] \
  && ok || bad "(f) test-select.sh argv 3 must be the base (got '$SELARGV')"
case "$(awk '{print $1}' <<<"$SELARGV")" in "$T/wt"/*) ok ;; *) bad "(f) test-select.sh argv 1 must be the worktree (got '$SELARGV')" ;; esac
[ ! -f "$GATE_UNIT_MARK" ] && ok || bad "(f) test-select.sh REPLACES npm run test:unit — it must not also run"
after "(f)"

# ============================================================================
# (g) no conflict resolver at <harness> — refuse, and never touch git
# ============================================================================
gates 0 0; mkmachine
BEFORE=$(ORIGIN_SHA "$BR_SETUP")
RUNJOB "$BR_SETUP" "$H_SETUP" main "$T/no-such-harness"; RC=$?
[ "$RC" = 1 ] && ok || bad "(g) a missing resolver must return 1 (got $RC)"
line_is "(g)" "REBASE_SETUP_FAILED no conflict resolver"
[ "$(ORIGIN_SHA "$BR_SETUP")" = "$BEFORE" ] && ok || bad "(g) a missing resolver must push nothing"
after "(g)"

# ============================================================================
# (h) the protected-branch refusal, and the empty-job refusal — before any git
# ============================================================================
gates 0 0; mkmachine
MAIN_BEFORE=$(ORIGIN_SHA main)
RUNJOB main "$MAIN_BEFORE" develop; RC=$?
[ "$RC" = 1 ] && ok || bad "(h) branch=main must be refused (got $RC)"
line_is "(h/main)" "REBASE_SETUP_FAILED branch is protected"
after "(h/main)"
RUNJOB master "$MAIN_BEFORE" develop >/dev/null 2>&1
line_is "(h/master)" "REBASE_SETUP_FAILED branch is protected"
after "(h/master)"
RUNJOB "$BR_PROT" "$H_PROT" "$BR_PROT" >/dev/null 2>&1
line_is "(h/base)" "REBASE_SETUP_FAILED branch is protected"
after "(h/base)"
[ "$(ORIGIN_SHA main)" = "$MAIN_BEFORE" ] && ok || bad "(h) main must be byte-identical after every refusal"
RUNJOB "" "$H_PROT" main >/dev/null 2>&1
line_is "(h/empty)" "REBASE_SETUP_FAILED job is missing branch, head or base"
after "(h/empty)"
RUNJOB "$BR_PROT" "" main >/dev/null 2>&1
line_is "(h/emptyhead)" "REBASE_SETUP_FAILED job is missing branch, head or base"
after "(h/emptyhead)"

# ============================================================================
# (i) the shallow single-branch machine: deepened once, then complete
# ============================================================================
gates 0 0; mkmachine
[ "$(git -C "$T/machine" rev-parse --is-shallow-repository)" = true ] \
  && ok || bad "(i) the fixture machine must start SHALLOW or it proves nothing"
RUNJOB "$BR_SHALLOW" "$H_SHALLOW"; RC=$?
[ "$RC" = 0 ] && ok || bad "(i) a branch forked before the shallow boundary must still rebase (got $RC, RESULT '$(R1)')"
case "$(R1)" in REBASED\ *) ok ;; *) bad "(i) first line must be REBASED (got '$(R1)')" ;; esac
[ "$(git -C "$T/machine" rev-parse --is-shallow-repository)" = false ] \
  && ok || bad "(i) the fetch must have deepened the machine repo"
after "(i)"
# and a SECOND job on the now-complete repo: --unshallow is fatal there, so the
# guard must have stopped asking for it.
RUNJOB "$BR_SHALLOW2" "$H_SHALLOW2"; RC=$?
[ "$RC" = 0 ] && ok || bad "(i2) a second job on a complete repo must not ask for --unshallow again (got $RC, RESULT '$(R1)')"
case "$(R1)" in REBASED\ *) ok ;; *) bad "(i2) first line must be REBASED (got '$(R1)')" ;; esac
after "(i2)"

# ============================================================================
# (j) the lease lost MID-JOB: the gate runs long, somebody else pushes, and the
#     force-with-lease refuses. Origin keeps the interloper's sha.
# ============================================================================
gates 0 0; mkmachine
git clone -q "$T/origin.git" "$T/other" 2>/dev/null
cat > "$T/interlope.sh" <<EOF
#!/bin/bash
git -C "$T/other" fetch -q origin "$BR_PUSH" >/dev/null 2>&1
git -C "$T/other" checkout -q -B "$BR_PUSH" "origin/$BR_PUSH" >/dev/null 2>&1
printf 'interloper\n' > "$T/other/z.txt"
git -C "$T/other" add -A >/dev/null 2>&1
git -C "$T/other" commit -qm interloper >/dev/null 2>&1
git -C "$T/other" push -q origin "$BR_PUSH" >/dev/null 2>&1
EOF
chmod +x "$T/interlope.sh"
( export GATE_TC_HOOK="$T/interlope.sh"
  RUNJOB "$BR_PUSH" "$H_PUSH" ) >/dev/null 2>&1; RC=$?
INTER=$(git -C "$T/other" rev-parse HEAD 2>/dev/null)
[ "$RC" = 1 ] && ok || bad "(j) a refused lease must return 1 (got $RC, RESULT '$(R1)')"
line_is "(j)" "REBASE_LEASE_REJECTED push"
[ "$(ORIGIN_SHA "$BR_PUSH")" = "$INTER" ] \
  && ok || bad "(j) origin must keep the interloper's sha (origin $(ORIGIN_SHA "$BR_PUSH"), interloper $INTER)"
after "(j)"

# ============================================================================
# (k) no node_modules (warm_up's `npm install || true` failed): gates skipped,
#     still pushed — CI on the PR is the gate, exactly as on the hub.
# ============================================================================
gates 0 0; mkmachine --nodeps
RUNJOB "$BR_NODEP" "$H_NODEP"; RC=$?
[ "$RC" = 0 ] && ok || bad "(k) a machine with no deps must still rebase (got $RC, RESULT '$(R1)')"
case "$(R1)" in REBASED\ *) ok ;; *) bad "(k) first line must be REBASED (got '$(R1)')" ;; esac
grep -qxF "GATE: typecheck=skipped unit=skipped" "$T/RESULT" \
  && ok || bad "(k) missing deps is 'skipped', never GATE_RED (got '$(grep '^GATE:' "$T/RESULT")')"
[ ! -f "$GATE_TC_MARK" ] && [ ! -f "$GATE_UNIT_MARK" ] \
  && ok || bad "(k) no gate script may run without node_modules"
after "(k)"

# ============================================================================
# (l) already up to date: rc 0, the SAME sha, origin untouched
# ============================================================================
gates 0 0; mkmachine
RUNJOB "$BR_UPTODATE" "$H_UPTODATE"; RC=$?
[ "$RC" = 0 ] && ok || bad "(l) an already-current branch is not an error (got $RC, RESULT '$(R1)')"
line_is "(l)" "REBASED $H_UPTODATE"
[ "$(ORIGIN_SHA "$BR_UPTODATE")" = "$H_UPTODATE" ] && ok || bad "(l) a no-op push must leave origin where it was"
after "(l)"

# ============================================================================
# runner — the PRODUCTION entry point (D2): fly/builder-runner.sh's own block,
# extracted between its markers and driven with the surrounding shell stubbed.
# ============================================================================
BLOCK=$(awk '/^# >>> run_job/{f=1;next} /^# <<< run_job/{exit} f' "$DIR/fly/builder-runner.sh")
[ -n "$BLOCK" ] && ok || bad "runner: fly/builder-runner.sh must bracket run_rebase_job + _run_job with # >>> run_job / # <<< run_job"
grep -q 'run_rebase_job' <<<"$BLOCK" && ok || bad "runner: the marked block must contain run_rebase_job"
grep -q '_run_job()' <<<"$BLOCK" && ok || bad "runner: the marked block must contain _run_job"

mkdir -p "$T/h/bin"
cat > "$T/h/bin/run-build.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/rb-argv.txt"
exit 0
EOF
chmod +x "$T/h/bin/run-build.sh"

mkjob() { # mkjob <json>
  printf '%s\n' "$1" > "$T/job.json"
}
runner_run() { # runner_run — drive _run_job with the machine's shell stubbed
  ( set -uo pipefail
    warm_up() { return "${WARMUP_RC:-0}"; }
    log() { :; }
    beat() { printf '%s\n' "$1" >> "$T/beats.txt"; }
    start_heartbeat() { :; }
    stop_heartbeat() { :; }
    load_env() { :; }
    HARNESS="$T/h"; REPO="$T/machine"; PROJECT=tproj
    JOB="$T/job.json"; RESULT_FILE="$T/RESULT"; JOBDIR="$T"
    eval "$BLOCK"
    _run_job )
}

# runner-1: a rebase job goes to the rebase path and NOWHERE else
gates 0 0; mkmachine
: > "$T/rb-argv.txt"; : > "$T/gh-argv.txt"; : > "$T/beats.txt"; rm -f "$T/RESULT"
mkjob "$(jq -nc --arg b "$BR_CLEAN" --arg h "$(ORIGIN_SHA "$BR_CLEAN")" --arg s "$SLUG" \
  '{key:"RB-21-aaaaaaaa",ticket_id:"21",attempt:0,rebase:{kind:"rebase",slug:$s,url:"https://github.com/o/tproj/pull/21",pr:21,branch:$b,head:$h,base:"main"}}')"
runner_run >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "runner-1: a green rebase job must return 0 (got $RC, RESULT '$(R1)')"
case "$(R1)" in REBASED\ *) ok ;; *) bad "runner-1: the runner must write REBASED (got '$(R1)')" ;; esac
grep -qxF "PR: https://github.com/o/tproj/pull/21" "$T/RESULT" \
  && ok || bad "runner-1: the runner must pass .rebase.url through as REBASE_JOB_URL (got '$(sed -n 2p "$T/RESULT")')"
[ ! -s "$T/rb-argv.txt" ] && ok || bad "runner-1: a rebase job must NEVER reach run-build.sh (argv: $(tr '\n' '|' < "$T/rb-argv.txt"))"
[ ! -s "$T/gh-argv.txt" ] && ok || bad "runner-1: a rebase job must run no PR-adopt preflight (gh argv: $(tr '\n' '|' < "$T/gh-argv.txt"))"
[ "$(grep -c '"stage":"rebase_done"' "$T/beats.txt")" = 1 ] \
  && ok || bad "runner-1: exactly one rebase_done beat (beats: $(tr '\n' '|' < "$T/beats.txt"))"
trailer_ok "runner-1"

# runner-2: a job WITHOUT .rebase still reaches run-build.sh, and so does a
# job whose .rebase.kind is something else
: > "$T/rb-argv.txt"
mkjob '{"key":"RB-21-aaaaaaaa","ticket_id":"21","attempt":0}'
runner_run >/dev/null 2>&1
grep -qxF "tproj 21 RB-21-aaaaaaaa" "$T/rb-argv.txt" \
  && ok || bad "runner-2: a job with no .rebase must reach run-build.sh (argv: $(tr '\n' '|' < "$T/rb-argv.txt"))"
: > "$T/rb-argv.txt"
mkjob '{"key":"RB-21-aaaaaaaa","ticket_id":"21","attempt":0,"rebase":{"kind":"build"}}'
runner_run >/dev/null 2>&1
grep -qxF "tproj 21 RB-21-aaaaaaaa" "$T/rb-argv.txt" \
  && ok || bad "runner-2: .rebase.kind='build' is not a rebase (argv: $(tr '\n' '|' < "$T/rb-argv.txt"))"
: > "$T/rb-argv.txt"
mkjob '{"key":"RB-21-aaaaaaaa","ticket_id":"21","attempt":0,"rebase":{}}'
runner_run >/dev/null 2>&1
grep -qxF "tproj 21 RB-21-aaaaaaaa" "$T/rb-argv.txt" \
  && ok || bad "runner-2: an empty .rebase is not a rebase (argv: $(tr '\n' '|' < "$T/rb-argv.txt"))"

# runner-3: warm-up failure is REBASE_SETUP_FAILED, never BUILD_DEFERRED —
# nothing re-offers a rebase job.
: > "$T/rb-argv.txt"; rm -f "$T/RESULT"
mkjob "$(jq -nc --arg b "$BR_CLEAN" --arg s "$SLUG" \
  '{key:"RB-21-aaaaaaaa",ticket_id:"21",attempt:0,rebase:{kind:"rebase",slug:$s,url:"https://github.com/o/tproj/pull/21",pr:21,branch:$b,head:"deadbeef",base:"main"}}')"
WARMUP_RC=1 runner_run >/dev/null 2>&1; RC=$?
[ "$RC" = 1 ] && ok || bad "runner-3: a failed warm-up must return 1 (got $RC)"
line_is "runner-3" "REBASE_SETUP_FAILED warm-up failed"
grep -qxF "BRANCH: $BR_CLEAN" "$T/RESULT" && ok || bad "runner-3: the runner's own RESULT carries the same trailer"
grep -qxF "PR: https://github.com/o/tproj/pull/21" "$T/RESULT" && ok || bad "runner-3: the trailer's PR line is the job's url"
[ ! -s "$T/rb-argv.txt" ] && ok || bad "runner-3: a failed rebase warm-up must not fall through to a build"
trailer_ok "runner-3"

# runner-4: no rebase lib on the volume
rm -f "$T/RESULT"
mv "$T/h/bin/lib/rebase-job.sh" "$T/h/bin/lib/rebase-job.sh.off"
runner_run >/dev/null 2>&1; RC=$?
mv "$T/h/bin/lib/rebase-job.sh.off" "$T/h/bin/lib/rebase-job.sh"
[ "$RC" = 1 ] && ok || bad "runner-4: a missing rebase lib must return 1 (got $RC)"
case "$(R1)" in "REBASE_SETUP_FAILED no rebase lib at "*) ok ;; *) bad "runner-4: first line must name the missing lib (got '$(R1)')" ;; esac
grep -qxF "BRANCH: $BR_CLEAN" "$T/RESULT" && ok || bad "runner-4: the trailer rides on this RESULT too"
trailer_ok "runner-4"

# the job-file shape comment names the new variant (doc pin, code pinned above)
sed -n '15,30p' "$DIR/fly/builder-runner.sh" | grep -q 'rebase:{' \
  && ok || bad "runner: the job-file shape comment near line 19 must name the rebase:{} variant"

echo "rebase-job.bh-543-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
