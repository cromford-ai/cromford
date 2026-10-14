#!/bin/bash
# tests/generated-files-train.bh-969-test.sh — BH-969 (BH-950.1).
#
# WHAT WAS WRONG. bin/batch-resolve.sh regenerates a repo's declared generated
# files over a merge train, but the REBASE paths did not: mc_rebase merged
# origin/main and went straight to the gates and the push, so a PR branch that
# hand-edited (or simply carried a stale) generated file was pushed with that
# file still stale — and CI's drift check then failed the PR for a file no
# ticket is about. Same omission in the pool twin (_rebase_job_body, step 6/7),
# and in build_union, whose deferred regenerate only ever ran for commands a
# CONFLICT had recorded — a train with no generated-file conflict regenerated
# nothing at all.
#
# WHAT THIS SUITE IS WORTH. Every case drives a REAL production entry point
# against REAL git — mc_rebase (R1-R5), rebase_job_run (R6) and build_union
# (R7, extracted verbatim by function name from bin/batch-resolve.sh, so a
# rename turns this red rather than green). The assertions are bytes on the
# bare origin and real commit counts, never source text. Seams replaced:
# mc_git_auth / mc_git_auth_clear (point at a local bare repo, no network) and
# mc_pool_rebase_enabled (off, so mc_rebase takes the hub path).
#
# Run from anywhere:  bash tests/generated-files-train.bh-969-test.sh
# As root next to a live harness:  HARNESS_TEST_SANDBOX=1 bash tests/generated-files-train.bh-969-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/merge-conductor-lib.sh"
BR="$DIR/bin/batch-resolve.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
[ -r "$LIB" ] || { echo "FAIL: bin/lib/merge-conductor-lib.sh is missing"; exit 1; }
[ -r "$BR" ]  || { echo "FAIL: bin/batch-resolve.sh is missing"; exit 1; }

git_q() { git -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }

# An AMBIENT identity, scoped to this run's scratch tree. git_q only dresses
# the test's OWN git calls; the commits that matter here are made by PRODUCTION
# code inside the clones (`git merge` in mc_rebase, the member merges in
# build_union), which has no -c to inherit. On the build box root has a global
# identity and those commits succeed; a CI runner has none, so every merge
# failed and 25 assertions went red on a fixture gap, not on the product. Same
# block as tests/generated-files-train-test.sh:70 and the --global block in
# tests/rebase-job.bh-543-test.sh — GIT_CONFIG_GLOBAL keeps it inside $T, so it
# can never reach the developer's real ~/.gitconfig.
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false

# ── the fixture ──────────────────────────────────────────────────────────────
# A repo that DECLARES docs/verification-map/README.md generated, with a
# deterministic generator (ls of the sibling .txt files). The generator also
# asserts it can read node_modules/marker: that is what proves the symlink is
# in place BEFORE the regenerate runs, not after it in the gate block.
#
# mkfix <name> [--fail] [--notable]
#   builds $T/<name>/work (a real repo), $T/<name>/origin.git (bare), with
#   branches: main (two generated rows), ticket/x (hand-edited README),
#   ticket/u (contains main, stale README), ticket/c (contains main, clean).
mkfix() {
  local name="$1"; shift
  local fail="" notable=""
  for a in "$@"; do case "$a" in --fail) fail=1 ;; --notable) notable=1 ;; esac; done
  local w="$T/$name/work"
  mkdir -p "$w"
  git_q init -q -b main "$w"
  mkdir -p "$w/docs/verification-map" "$w/bin"
  if [ -n "$fail" ]; then
    # writes junk into the declared path and THEN fails: the restore is what
    # keeps that junk out of the pushed head.
    printf '#!/bin/sh\nprintf "junk\\n" > docs/verification-map/README.md\nexit 3\n' > "$w/bin/gen.sh"
  else
    cat > "$w/bin/gen.sh" <<'GEN'
#!/bin/sh
# the marker read is the point: no node_modules link, no regenerate output
[ -r node_modules/marker ] || { echo "node_modules/marker is not readable" >&2; exit 4; }
ls docs/verification-map/*.txt 2>/dev/null | sort > docs/verification-map/README.md
GEN
  fi
  chmod +x "$w/bin/gen.sh"
  # gen2.sh is the same generator WITHOUT the node_modules assertion: the batch
  # lane runs its regenerate in a bare union worktree with no deps linked, so
  # the marker check belongs only to the rebase paths it proves something about.
  printf '#!/bin/sh\nls docs/verification-map/*.txt 2>/dev/null | sort > docs/verification-map/README.md\n' > "$w/bin/gen2.sh"
  chmod +x "$w/bin/gen2.sh"
  # gen3.sh: gen2 PLUS one undeclared write. The table declares only the README,
  # so stray.log is output no reviewer asked for — R9a is what keeps it out of
  # the union commit.
  printf '#!/bin/sh\nls docs/verification-map/*.txt 2>/dev/null | sort > docs/verification-map/README.md\nprintf "stray\\n" > docs/verification-map/stray.log\n' > "$w/bin/gen3.sh"
  chmod +x "$w/bin/gen3.sh"
  # gen4.sh: gen2 gated on $E, so ONE script gives a working command
  # (`E=1 bin/gen4.sh`) and a failing one (`bin/gen4.sh`) whose text is a strict
  # SUFFIX of the first. That pair is what R9c needs.
  printf '#!/bin/sh\n[ -n "${E:-}" ] || { echo "E unset" >&2; exit 3; }\nls docs/verification-map/*.txt 2>/dev/null | sort > docs/verification-map/README.md\n' > "$w/bin/gen4.sh"
  chmod +x "$w/bin/gen4.sh"
  if [ -z "$notable" ]; then
    cat > "$w/AGENT_ARCHITECTURE.md" <<'MD'
# Architecture

## Generated files

| File | Regenerate with |
|---|---|
| `docs/verification-map/README.md` | `bin/gen.sh` |
MD
  else
    printf '# Architecture\n\nNo table here.\n' > "$w/AGENT_ARCHITECTURE.md"
  fi
  : > "$w/docs/verification-map/a.txt"
  # OUTSIDE the generator's glob on purpose: R9c declares a second table row for
  # it, and a path the README lists would change every other case's expectations.
  printf 'keep\n' > "$w/docs/keep.md"
  printf 'docs/verification-map/a.txt\n' > "$w/docs/verification-map/README.md"
  git_q -C "$w" add -A; git_q -C "$w" commit -qm base

  # ticket/x: a new row AND a hand-edited README (the real tail this fixes)
  git_q -C "$w" checkout -qb ticket/x
  : > "$w/docs/verification-map/b.txt"
  printf 'hand edited\n' > "$w/docs/verification-map/README.md"
  git_q -C "$w" add -A; git_q -C "$w" commit -qm branch

  # main moves: one more row, README regenerated by hand-equivalent content
  git_q -C "$w" checkout -q main
  : > "$w/docs/verification-map/c.txt"
  printf 'docs/verification-map/a.txt\ndocs/verification-map/c.txt\n' > "$w/docs/verification-map/README.md"
  git_q -C "$w" add -A; git_q -C "$w" commit -qm main2

  # ticket/u: already contains main, README stale (missing its own new row)
  git_q -C "$w" checkout -qb ticket/u main
  : > "$w/docs/verification-map/d.txt"
  git_q -C "$w" add -A; git_q -C "$w" commit -qm uptodate-stale

  # ticket/c: already contains main, README already generate-clean
  git_q -C "$w" checkout -qb ticket/c main
  : > "$w/docs/verification-map/e.txt"
  printf 'docs/verification-map/a.txt\ndocs/verification-map/c.txt\ndocs/verification-map/e.txt\n' \
    > "$w/docs/verification-map/README.md"
  git_q -C "$w" add -A; git_q -C "$w" commit -qm uptodate-clean

  git_q -C "$w" checkout -q main
  git_q clone -q --bare "$w" "$T/$name/origin.git" >/dev/null 2>&1
}

# runrebase <fixture> <branch> — mc_rebase against that fixture, in a subshell
#   so the seam overrides and MC_* never leak between cases. Prints the rc on
#   the last line, the function's own stdout before it.
runrebase() {
  local name="$1" br="$2"
  (
    export HARNESS="$T/$name/h"
    mkdir -p "$HARNESS/logs" "$HARNESS/state" "$HARNESS/locks" "$HARNESS/flags" "$HARNESS/tmp"
    # shellcheck source=/dev/null
    . "$LIB" >/dev/null 2>&1
    mc_init >/dev/null 2>&1
    mc_git_auth() { MC_REMOTE="$T/$name/origin.git"; return 0; }
    mc_git_auth_clear() { :; }
    mc_pool_rebase_enabled() { return 1; }
    export MC_REPOS="$T/$name/repos"
    mkdir -p "$MC_REPOS"
    [ -d "$MC_REPOS/demo-os" ] || git_q clone -q "$T/$name/origin.git" "$MC_REPOS/demo-os" >/dev/null 2>&1
    mkdir -p "$MC_REPOS/demo-os/node_modules"; printf 'm\n' > "$MC_REPOS/demo-os/node_modules/marker"
    local head out rc
    head=$(git -C "$T/$name/origin.git" rev-parse "$br")
    out=$(mc_rebase o/r demo-os "$br" "$head" "https://github.com/o/r/pull/1" 2>/dev/null); rc=$?
    printf '%s\n%s\n' "$out" "$rc"
  )
}

# logn <pattern> <logfile> — how many times the log says it, 0 when the file is
#   not there at all. NOT `grep -c … || echo 0`: on a file that exists with zero
#   matches grep PRINTS 0 and EXITS 1, so the `|| echo 0` appends a second line
#   and the caller compares against the two-line string "0\n0" — an assertion
#   that can never pass. `|| true` swallows the status and keeps grep's own 0;
#   the `[ -r ]` guard covers the missing-file case, where grep prints nothing.
logn() { [ -r "$2" ] || { printf '0\n'; return 0; }; grep -c "$1" "$2" 2>/dev/null || true; }

RC_OF()  { tail -1 <<<"$1"; }
NEW_OF() { sed -n '1p' <<<"$1"; }

# generate_clean <fixture> <branch> — check out origin's branch in a fresh
#   worktree, run the repo's OWN generator, and answer whether the committed
#   README already matched. This is the same question CI's drift step asks.
generate_clean() {
  local name="$1" br="$2" chk
  # keyed on the arguments, never $RANDOM: the determinism lint reads a random
  # path as an unreproducible run, and every call here is a distinct pair.
  chk="$T/$name/chk-${br//\//_}"
  git_q clone -q "$T/$name/origin.git" "$chk" >/dev/null 2>&1 || return 2
  git_q -C "$chk" checkout -q "$br" >/dev/null 2>&1 || return 2
  mkdir -p "$chk/node_modules"; printf 'm\n' > "$chk/node_modules/marker"
  ( cd "$chk" && ./bin/gen.sh ) >/dev/null 2>&1 || return 2
  git -C "$chk" diff --quiet -- docs/verification-map/README.md
}

# ============================================================================
# R0: mc_regen_table is the SAME parser bin/batch-resolve.sh's regen_table is
# ============================================================================
mkfix r0
# a CLONE, so `origin/main` resolves for both parsers (regen_table's show_base
# reads origin/$PBASE, which a bare fixture work-tree has no remote for)
git_q clone -q "$T/r0/origin.git" "$T/r0/clone" >/dev/null 2>&1
R0_MC=$(
  # shellcheck source=/dev/null
  ( export HARNESS="$T/r0/h"; mkdir -p "$HARNESS/logs"; . "$LIB" >/dev/null 2>&1
    mc_regen_table "$T/r0/clone" origin/main )
)
R0_BR=$(
  ( REPO="$T/r0/clone"; PBASE=main
    # show_base is a one-liner: a /^}/ range from it would swallow the file
    eval "$(grep -m1 '^show_base() {.*}$' "$BR")"
    eval "$(sed -n '/^regen_table()/,/^}/p' "$BR")"
    # the extraction must not come back empty: a rename is a FAIL, not a skip
    type regen_table >/dev/null 2>&1 || exit 9
    regen_table )
)
[ -n "$R0_BR" ] && ok || bad "R0: regen_table could not be extracted from bin/batch-resolve.sh"
[ "$R0_MC" = "$R0_BR" ] && ok \
  || bad "R0: mc_regen_table must byte-match regen_table (mc='$R0_MC' br='$R0_BR')"
grep -qx 'docs/verification-map/README.md	bin/gen.sh' <<<"$R0_MC" && ok \
  || bad "R0: the fixture's row must parse to path<TAB>command (got '$R0_MC')"

# ============================================================================
# R1: a hand-edited generated file is regenerated into ONE extra commit
# ============================================================================
mkfix r1
R1_MERGEBASE=$(git -C "$T/r1/origin.git" rev-parse main)
R1_OUT=$(runrebase r1 ticket/x); R1_RC=$(RC_OF "$R1_OUT"); R1_NEW=$(NEW_OF "$R1_OUT")
[ "$R1_RC" = 0 ] && ok || bad "R1: mc_rebase must return 0 (got $R1_RC, out '$R1_OUT')"
R1_PUSHED=$(git -C "$T/r1/origin.git" rev-parse ticket/x)
[ "$R1_PUSHED" = "$R1_NEW" ] && ok \
  || bad "R1: origin's ticket/x must be the sha mc_rebase printed (origin $R1_PUSHED, said $R1_NEW)"
# the merge commit is the one with two parents; HEAD must be exactly one past it
R1_MERGE=$(git -C "$T/r1/origin.git" rev-list --min-parents=2 -n1 ticket/x)
[ -n "$R1_MERGE" ] && ok || bad "R1: the pushed head must carry a merge of main"
R1_EXTRA=$(git -C "$T/r1/origin.git" rev-list --count "$R1_MERGE..ticket/x")
[ "$R1_EXTRA" = 1 ] && ok \
  || bad "R1: exactly ONE regenerate commit must sit on top of the merge (got $R1_EXTRA)"
R1_FILES=$(git -C "$T/r1/origin.git" show --name-only --format= ticket/x | grep -c .)
R1_FILE=$(head -1 <<<"$(git -C "$T/r1/origin.git" show --name-only --format= ticket/x)")
[ "$R1_FILES" = 1 ] && [ "$R1_FILE" = docs/verification-map/README.md ] && ok \
  || bad "R1: the regenerate commit must touch ONLY the declared path (touched $R1_FILES: $R1_FILE)"
generate_clean r1 ticket/x && ok \
  || bad "R1: the README on the pushed head must be generate-clean (CI's drift check is this)"
R1_BODY=$(git -C "$T/r1/origin.git" show "ticket/x:docs/verification-map/README.md")
grep -qx 'docs/verification-map/b.txt' <<<"$R1_BODY" && grep -qx 'docs/verification-map/c.txt' <<<"$R1_BODY" && ok \
  || bad "R1: the regenerated README must carry BOTH sides' rows (got '$R1_BODY')"
grep -q 'hand edited' <<<"$R1_BODY" && bad "R1: the hand-edited content must be gone" || ok
[ -r "$T/r1/repos/demo-os/node_modules/marker" ] && ok \
  || bad "R1: the fixture must actually have \$repo/node_modules/marker (the link-before-regenerate proof)"
grep -qi '^regenerate ' <<<"$(git -C "$T/r1/origin.git" log -1 --format=%s ticket/x)" && ok \
  || bad "R1: the extra commit's subject must name the regenerate (got '$(git -C "$T/r1/origin.git" log -1 --format=%s ticket/x)')"

# ============================================================================
# R2: a branch that already contains main, with a stale README, still gets one
# ============================================================================
mkfix r2
R2_HEAD=$(git -C "$T/r2/origin.git" rev-parse ticket/u)
R2_OUT=$(runrebase r2 ticket/u); R2_RC=$(RC_OF "$R2_OUT")
[ "$R2_RC" = 0 ] && ok || bad "R2: mc_rebase must return 0 on an up-to-date branch (got $R2_RC)"
R2_EXTRA=$(git -C "$T/r2/origin.git" rev-list --count "$R2_HEAD..ticket/u")
[ "$R2_EXTRA" = 1 ] && ok \
  || bad "R2: an up-to-date branch with a stale README must gain exactly one commit (got $R2_EXTRA)"
generate_clean r2 ticket/u && ok || bad "R2: the README on the pushed head must be generate-clean"

# ============================================================================
# R3: an in-sync branch with a clean README gains NOTHING
# ============================================================================
mkfix r3
R3_HEAD=$(git -C "$T/r3/origin.git" rev-parse ticket/c)
R3_OUT=$(runrebase r3 ticket/c); R3_RC=$(RC_OF "$R3_OUT")
[ "$R3_RC" = 0 ] && ok || bad "R3: mc_rebase must return 0 (got $R3_RC)"
R3_EXTRA=$(git -C "$T/r3/origin.git" rev-list --count "$R3_HEAD..ticket/c")
[ "$R3_EXTRA" = 0 ] && ok \
  || bad "R3: a branch whose generated files are already clean must gain NO commit (got $R3_EXTRA)"
grep -qi '^regenerate ' <<<"$(git -C "$T/r3/origin.git" log --format=%s "$R3_HEAD..ticket/c")" \
  && bad "R3: no regenerate commit may exist on an already-clean branch" || ok

# ============================================================================
# R4: a FAILING generator is logged, stages nothing, and does not block
# ============================================================================
mkfix r4 --fail
R4_MAIN=$(git -C "$T/r4/origin.git" rev-parse main)
R4_OUT=$(runrebase r4 ticket/x); R4_RC=$(RC_OF "$R4_OUT")
[ "$R4_RC" = 0 ] && ok || bad "R4: a failing generator must NOT block the rebase (rc $R4_RC)"
R4_LOGN=$(logn 'regenerate FAILED:' "$T/r4/h/logs/merge-conductor.log")
[ "$R4_LOGN" = 1 ] && ok \
  || bad "R4: the failure must be logged exactly once as 'regenerate FAILED:' (got $R4_LOGN)"
R4_MERGE=$(git -C "$T/r4/origin.git" rev-list --min-parents=2 -n1 ticket/x)
R4_EXTRA=$(git -C "$T/r4/origin.git" rev-list --count "$R4_MERGE..ticket/x")
[ "$R4_EXTRA" = 0 ] && ok \
  || bad "R4: a failing generator must leave NO commit on the pushed head (got $R4_EXTRA)"
R4_BODY=$(git -C "$T/r4/origin.git" show "ticket/x:docs/verification-map/README.md")
grep -q junk <<<"$R4_BODY" && bad "R4: the generator's partial write must be restored, never pushed" || ok

# R4b: the partial write is RESTORED in the worktree, not just left unstaged.
# The pushed head cannot show this (a dirty worktree is never pushed), and the
# gates that run straight after the regenerate read that very tree — so this
# case calls mc_regen_generated directly on a failing generator and asserts the
# tree it hands on is clean.
R4B=$(
  export HARNESS="$T/r4/h2"; mkdir -p "$HARNESS/logs"
  # shellcheck source=/dev/null
  . "$LIB" >/dev/null 2>&1
  w="$T/r4/direct"
  git -c user.email=t@t -c user.name=t clone -q "$T/r4/origin.git" "$w" >/dev/null 2>&1
  git -C "$w" checkout -q main >/dev/null 2>&1
  mc_regen_generated "$w" origin/main "direct" >/dev/null 2>&1; rc=$?
  git -C "$w" diff --quiet && clean=clean || clean=dirty
  staged=$(git -C "$w" diff --cached --name-only | grep -c .)
  printf 'rc=%s tree=%s staged=%s\n' "$rc" "$clean" "$staged"
)
[ "$R4B" = "rc=0 tree=clean staged=0" ] && ok \
  || bad "R4b: a failing generator must leave the worktree clean and nothing staged (got '$R4B')"

# ============================================================================
# R5: a repo that declares NO table behaves exactly as it did before BH-950
# ============================================================================
mkfix r5 --notable
R5_HEAD=$(git -C "$T/r5/origin.git" rev-parse ticket/x)
R5_OUT=$(runrebase r5 ticket/x); R5_RC=$(RC_OF "$R5_OUT")
[ "$R5_RC" = 0 ] && ok || bad "R5: mc_rebase must return 0 with no table (got $R5_RC)"
R5_MERGE=$(git -C "$T/r5/origin.git" rev-list --min-parents=2 -n1 ticket/x)
R5_EXTRA=$(git -C "$T/r5/origin.git" rev-list --count "$R5_MERGE..ticket/x")
[ "$R5_EXTRA" = 0 ] && ok \
  || bad "R5: no table means the merge commit is the whole answer (got $R5_EXTRA extra)"
# a log file that does not exist at all is the strongest form of "said nothing"
R5_LOGN=$(logn 'regenerate' "$T/r5/h/logs/merge-conductor.log")
[ "$R5_LOGN" = 0 ] && ok || bad "R5: a repo with no table must log nothing about regenerate (got $R5_LOGN)"

# ============================================================================
# R6: the POOL twin — rebase_job_run answers REBASED <sha> with a clean README
# ============================================================================
mkfix r6
mkdir -p "$T/r6/h/bin/lib" "$T/r6/h/logs"
cp "$LIB" "$T/r6/h/bin/lib/merge-conductor-lib.sh"
# BH-680 (#929): merge-conductor-lib.sh is a shim that sources bin/lib/mc/*.sh
# and `exit 1`s on a missing module — a fixture that copies only the shim kills
# _rebase_job_body at its loader, which is what left every R6 assertion reading
# an empty RESULT file. Same three lines as tests/blocked-resolver.bh-488-test.sh.
mkdir -p "$T/r6/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/r6/h/bin/lib/mc/"
git_q clone -q "$T/r6/origin.git" "$T/r6/machine" >/dev/null 2>&1
mkdir -p "$T/r6/machine/node_modules"; printf 'm\n' > "$T/r6/machine/node_modules/marker"
R6_HEAD=$(git -C "$T/r6/origin.git" rev-parse ticket/x)
(
  export REBASE_WT_DIR="$T/r6/wt"; mkdir -p "$REBASE_WT_DIR"
  # shellcheck source=/dev/null
  . "$DIR/bin/lib/rebase-job.sh" >/dev/null 2>&1
  rebase_job_run "$T/r6/machine" o/r ticket/x "$R6_HEAD" main "$T/r6/RESULT" "$T/r6/h"
) >/dev/null 2>&1; R6_RC=$?
R6_NEW=$(git -C "$T/r6/origin.git" rev-parse ticket/x)
[ "$R6_RC" = 0 ] && ok || bad "R6: rebase_job_run must return 0 (RESULT '$(head -1 "$T/r6/RESULT" 2>/dev/null)')"
[ "$(head -1 "$T/r6/RESULT" 2>/dev/null)" = "REBASED $R6_NEW" ] && ok \
  || bad "R6: line 1 must be 'REBASED <the sha now on origin>' (got '$(head -1 "$T/r6/RESULT" 2>/dev/null)')"
"$DIR/bin/result-prefix-ok.sh" "$(head -1 "$T/r6/RESULT" 2>/dev/null)" >/dev/null 2>&1 && ok \
  || bad "R6: the reap gate must read line 1 as a RESULT"
R6_I=2
for p in "PR: " "HEAD: " "BRANCH: " "BASE: " "GATE: "; do
  case "$(sed -n "${R6_I}p" "$T/r6/RESULT" 2>/dev/null)" in
    "$p"*) ;; *) bad "R6: RESULT line $R6_I must start with '$p'" ;;
  esac
  R6_I=$((R6_I+1))
done
ok
R6_MERGE=$(git -C "$T/r6/origin.git" rev-list --min-parents=2 -n1 ticket/x)
R6_EXTRA=$(git -C "$T/r6/origin.git" rev-list --count "$R6_MERGE..ticket/x")
[ "$R6_EXTRA" = 1 ] && ok || bad "R6: the pool body must add exactly one regenerate commit (got $R6_EXTRA)"
generate_clean r6 ticket/x && ok || bad "R6: the README on origin's ticket/x must be generate-clean after a POOL rebase"

# ============================================================================
# R7: build_union regenerates over the union even with ZERO conflicts
# ============================================================================
# The real build_union, extracted by name and run against a fixture with two
# members that touch DISJOINT files — so nothing conflicts and, before this
# ticket, `pend` stayed empty and the generator never ran.
mkfix r7
R7_REPO="$T/r7/union"
git_q clone -q "$T/r7/origin.git" "$R7_REPO" >/dev/null 2>&1
# two sibling branches off main, each adding its own row, neither touching the
# README (a source-disjoint pair: the pre-BH-969 zero-conflict train)
for m in 1 2; do
  git_q -C "$R7_REPO" checkout -q -B "sib/$m" origin/main >/dev/null 2>&1
  : > "$R7_REPO/docs/verification-map/s$m.txt"
  git_q -C "$R7_REPO" add -A; git_q -C "$R7_REPO" commit -qm "sibling $m" >/dev/null
done
R7_H1=$(git -C "$R7_REPO" rev-parse sib/1); R7_H2=$(git -C "$R7_REPO" rev-parse sib/2)
git_q -C "$R7_REPO" checkout -q --detach origin/main >/dev/null 2>&1
R7_OUT=$(
  set -uo pipefail
  REPO="$R7_REPO"; PBASE=main
  declare -A HEADOF=( [1]="$R7_H1" [2]="$R7_H2" )
  declare -A BRANCHOF=( [1]=sib/1 [2]=sib/2 )
  REGEN_TABLE=$'docs/verification-map/README.md\tbin/gen2.sh'
  say() { :; }
  . "$DIR/bin/lib/deployment.sh" || exit 9  # BH-4080: batch-resolve.sh loads the merge identity from it
  regen_cmd_for() { case "$1" in docs/verification-map/README.md) printf 'bin/gen2.sh' ;; *) return 1 ;; esac; }
  eval "$(sed -n '/^build_union()/,/^}/p;/^union_cleanup()/,/^}/p' "$BR")"
  type build_union >/dev/null 2>&1 || exit 9
  WT=""; UNION_MEMBERS=""
  build_union batch/x 1 2; rc=$?
  if [ "$rc" = 0 ]; then
    printf 'MEMBERS=%s\nSUBJECT=%s\nREADME=%s\n' \
      "$UNION_MEMBERS" "$(git -C "$WT" log -1 --format=%s)" \
      "$(git -C "$WT" show HEAD:docs/verification-map/README.md | tr '\n' ' ')"
  fi
  printf 'RC=%s\n' "$rc"
  union_cleanup
)
[ "$(grep -o 'RC=[0-9]*' <<<"$R7_OUT")" = "RC=0" ] && ok || bad "R7: build_union must return 0 (out '$R7_OUT')"
grep -qx 'MEMBERS=1 2' <<<"$R7_OUT" && ok || bad "R7: both members must be kept (out '$R7_OUT')"
grep -qx "SUBJECT=batch: regenerate the repo's generated files over the union" <<<"$R7_OUT" && ok \
  || bad "R7: the union must carry the batch regenerate commit (out '$(grep SUBJECT= <<<"$R7_OUT")')"
R7_README=$(sed -n 's/^README=//p' <<<"$R7_OUT")
case "$R7_README" in
  *s1.txt*s2.txt*) ok ;;
  *) bad "R7: the regenerated README must list BOTH members' new rows (got '$R7_README')" ;;
esac

# ============================================================================
# R8: a FAILING generator on the union — best-effort when the widening is the
#     only reason the command ran, still fatal when a conflict needed it
# ============================================================================
# BH-969 made `pend` the whole table, so the pre-existing "abandon this batch"
# arm became reachable on EVERY train instead of only on a train that conflicted
# in a generated file. A docs generator having a bad day must not cost a whole
# project its merges — that is the opposite of the contract its rebase twin
# holds to (mc_regen_generated is always rc 0; see regen-on-rebase.md). The
# distinction the two cases below pin:
#   R8a  nothing conflicted — the regenerate is a freshness top-up. A failure
#        leaves the union exactly as stale as it was before BH-969, which is
#        strictly better than dropping every member. rc 0, both kept.
#   R8b  a generated file DID conflict and was resolved by taking THEIRS — only
#        the regenerate makes that resolution correct, so a failure still
#        abandons the batch. This is the pre-BH-969 behaviour and must not move.
#
# union_run <repo> <regen-cmd> <h1> <h2> — the real build_union over a two-member
#   fixture, printing MEMBERS/README/RC the way R7 does.
union_run() {
  # RCMD, not `cmd`: build_union declares `local cmd`, and bash is dynamically
  # scoped — a seam that read $cmd would read build_union's empty local and die
  # on `set -u` inside the command substitution, which silently turns the
  # conflict arm into "not regenerable" and makes R8b pass for the wrong reason.
  local repo="$1" RCMD="$2" h1="$3" h2="$4"
  (
    set -uo pipefail
    REPO="$repo"; PBASE=main
    declare -A HEADOF=( [1]="$h1" [2]="$h2" )
    declare -A BRANCHOF=( [1]=sib/1 [2]=sib/2 )
    REGEN_TABLE="docs/verification-map/README.md"$'\t'"$RCMD"
    say() { :; }
    . "$DIR/bin/lib/deployment.sh" || exit 9  # BH-4080: batch-resolve.sh loads the merge identity from it
    regen_cmd_for() { case "$1" in docs/verification-map/README.md) printf '%s' "$RCMD" ;; *) return 1 ;; esac; }
    eval "$(sed -n '/^build_union()/,/^}/p;/^union_cleanup()/,/^}/p' "$BR")"
    type build_union >/dev/null 2>&1 || exit 9
    WT=""; UNION_MEMBERS=""
    build_union batch/x 1 2; rc=$?
    if [ "$rc" = 0 ]; then
      printf 'MEMBERS=%s\nREADME=%s\n' "$UNION_MEMBERS" \
        "$(git -C "$WT" show HEAD:docs/verification-map/README.md | tr '\n' ' ')"
    fi
    printf 'RC=%s\n' "$rc"
    union_cleanup
  )
}

# R8a: disjoint members (nothing conflicts), generator exits 3 after writing junk
mkfix r8a --fail
R8A_REPO="$T/r8a/union"
git_q clone -q "$T/r8a/origin.git" "$R8A_REPO" >/dev/null 2>&1
for m in 1 2; do
  git_q -C "$R8A_REPO" checkout -q -B "sib/$m" origin/main >/dev/null 2>&1
  : > "$R8A_REPO/docs/verification-map/s$m.txt"
  git_q -C "$R8A_REPO" add -A; git_q -C "$R8A_REPO" commit -qm "sibling $m" >/dev/null
done
R8A_H1=$(git -C "$R8A_REPO" rev-parse sib/1); R8A_H2=$(git -C "$R8A_REPO" rev-parse sib/2)
git_q -C "$R8A_REPO" checkout -q --detach origin/main >/dev/null 2>&1
R8A_OUT=$(union_run "$R8A_REPO" bin/gen.sh "$R8A_H1" "$R8A_H2")
grep -qx 'RC=0' <<<"$R8A_OUT" && ok \
  || bad "R8a: a failing generator must NOT abandon a batch nothing conflicted in (out '$R8A_OUT')"
grep -qx 'MEMBERS=1 2' <<<"$R8A_OUT" && ok \
  || bad "R8a: both members must survive a failing generator (out '$R8A_OUT')"
R8A_README=$(sed -n 's/^README=//p' <<<"$R8A_OUT")
case "$R8A_README" in
  *junk*) bad "R8a: the failed generator's partial write must be restored, never committed (got '$R8A_README')" ;;
  *) ok ;;
esac

# R8b: both members edit the DECLARED file, so member 2 conflicts in it and the
# resolution records the command — a failure there is still fatal.
mkfix r8b --fail
R8B_REPO="$T/r8b/union"
git_q clone -q "$T/r8b/origin.git" "$R8B_REPO" >/dev/null 2>&1
for m in 1 2; do
  git_q -C "$R8B_REPO" checkout -q -B "sib/$m" origin/main >/dev/null 2>&1
  printf 'member %s only\n' "$m" > "$R8B_REPO/docs/verification-map/README.md"
  git_q -C "$R8B_REPO" add -A; git_q -C "$R8B_REPO" commit -qm "sibling $m" >/dev/null
done
R8B_H1=$(git -C "$R8B_REPO" rev-parse sib/1); R8B_H2=$(git -C "$R8B_REPO" rev-parse sib/2)
git_q -C "$R8B_REPO" checkout -q --detach origin/main >/dev/null 2>&1
R8B_OUT=$(union_run "$R8B_REPO" bin/gen.sh "$R8B_H1" "$R8B_H2")
grep -qx 'RC=1' <<<"$R8B_OUT" && ok \
  || bad "R8b: a generated-file conflict resolved by THEIRS must still abandon the batch when the regenerate fails (out '$R8B_OUT')"
# and it must abandon at the REGENERATE, not by dropping the member at the
# conflict arm — a dropped member would give RC=1 for a different reason and
# make the case above green on a broken seam.
R8B_OK=$(union_run "$R8B_REPO" bin/gen2.sh "$R8B_H1" "$R8B_H2")
grep -qx 'MEMBERS=1 2' <<<"$R8B_OK" && ok \
  || bad "R8b: with a WORKING generator the same conflict must resolve and keep both members (out '$R8B_OK')"

# ============================================================================
# R9: the union path must obey the SAME three invariants its rebase twin does
# ============================================================================
# docs/verification-map/regen-on-rebase.md lists build_union as one of the three
# entry points it governs, and its "What must never regress" list says only the
# DECLARED paths are staged and node_modules is linked BEFORE the regenerate.
# mc_regen_generated does both; build_union did neither, so the doc described
# one twin and not the other. R9c pins the third: which of the two failure arms
# a command takes must be decided by an EXACT match against the commands a
# conflict recorded, not by a substring of one.
#
# union_probe <repo> <table> <regen_cmd_for body> <h1> <h2> — the real
#   build_union like union_run, but with a multi-row table and the union
#   worktree's own facts (the regenerate commit's file list, what stayed
#   untracked) printed before the cleanup tears it down.
union_probe() {
  local repo="$1" RTABLE="$2" RMAP="$3" h1="$4" h2="$5"
  (
    set -uo pipefail
    REPO="$repo"; PBASE=main
    declare -A HEADOF=( [1]="$h1" [2]="$h2" )
    declare -A BRANCHOF=( [1]=sib/1 [2]=sib/2 )
    REGEN_TABLE="$RTABLE"
    say() { :; }
    . "$DIR/bin/lib/deployment.sh" || exit 9  # BH-4080: batch-resolve.sh loads the merge identity from it
    eval "regen_cmd_for() { $RMAP; }"
    eval "$(sed -n '/^build_union()/,/^}/p;/^union_cleanup()/,/^}/p' "$BR")"
    type build_union >/dev/null 2>&1 || exit 9
    WT=""; UNION_MEMBERS=""
    build_union batch/x 1 2; rc=$?
    if [ "$rc" = 0 ]; then
      printf 'MEMBERS=%s\nSUBJECT=%s\nFILES=%s\nUNTRACKED=%s\nREADME=%s\n' \
        "$UNION_MEMBERS" "$(git -C "$WT" log -1 --format=%s)" \
        "$(git -C "$WT" show --name-only --format= HEAD | tr '\n' ' ')" \
        "$(git -C "$WT" status --porcelain --untracked-files=all | tr '\n' ' ')" \
        "$(git -C "$WT" show HEAD:docs/verification-map/README.md 2>/dev/null | tr '\n' ' ')"
    fi
    printf 'RC=%s\n' "$rc"
    union_cleanup
  )
}

# union_sibs <fixture> — clone the fixture and lay down the two disjoint members
#   R7/R8a use (each adds its own .txt row, neither touches the README), echoing
#   "<repo> <h1> <h2>".
union_sibs() {
  local name="$1" repo="$T/$1/union" m
  git_q clone -q "$T/$name/origin.git" "$repo" >/dev/null 2>&1
  for m in 1 2; do
    git_q -C "$repo" checkout -q -B "sib/$m" origin/main >/dev/null 2>&1
    : > "$repo/docs/verification-map/s$m.txt"
    git_q -C "$repo" add -A; git_q -C "$repo" commit -qm "sibling $m" >/dev/null
  done
  git_q -C "$repo" checkout -q --detach origin/main >/dev/null 2>&1
  printf '%s %s %s\n' "$repo" "$(git -C "$repo" rev-parse sib/1)" "$(git -C "$repo" rev-parse sib/2)"
}

# R9a: a generator that also writes an UNDECLARED file. The table names only the
# README, so stray.log must be left untracked in the union worktree, exactly as
# mc_regen_generated leaves it — never swept into a commit the train PR's
# reviewers approved for other reasons.
mkfix r9a
read -r R9A_REPO R9A_H1 R9A_H2 <<<"$(union_sibs r9a)"
R9A_OUT=$(union_probe "$R9A_REPO" \
  $'docs/verification-map/README.md\tbin/gen3.sh' \
  'case "$1" in docs/verification-map/README.md) printf "bin/gen3.sh" ;; *) return 1 ;; esac' \
  "$R9A_H1" "$R9A_H2")
grep -qx 'RC=0' <<<"$R9A_OUT" && ok || bad "R9a: build_union must return 0 (out '$R9A_OUT')"
R9A_FILES=$(sed -n 's/^FILES=//p' <<<"$R9A_OUT")
case "$R9A_FILES" in
  *stray.log*) bad "R9a: the union regenerate commit must stage ONLY the table's declared paths, never a generator's stray output (committed '$R9A_FILES')" ;;
  *README.md*) ok ;;
  *) bad "R9a: the union regenerate commit must contain the declared README (committed '$R9A_FILES')" ;;
esac
case "$(sed -n 's/^UNTRACKED=//p' <<<"$R9A_OUT")" in
  *"?? docs/verification-map/stray.log"*) ok ;;
  *) bad "R9a: the stray write must survive as UNTRACKED, the way mc_regen_generated leaves it (status '$(sed -n 's/^UNTRACKED=//p' <<<"$R9A_OUT")')" ;;
esac

# R9b: node_modules must be linked BEFORE the regenerate, not in the gate block
# after it. bin/gen.sh refuses to run without node_modules/marker, so a union
# that regenerates at all is a union that had the link in place.
mkfix r9b
read -r R9B_REPO R9B_H1 R9B_H2 <<<"$(union_sibs r9b)"
mkdir -p "$R9B_REPO/node_modules"; printf 'm\n' > "$R9B_REPO/node_modules/marker"
R9B_OUT=$(union_probe "$R9B_REPO" \
  $'docs/verification-map/README.md\tbin/gen.sh' \
  'case "$1" in docs/verification-map/README.md) printf "bin/gen.sh" ;; *) return 1 ;; esac' \
  "$R9B_H1" "$R9B_H2")
grep -qx 'RC=0' <<<"$R9B_OUT" && ok || bad "R9b: build_union must return 0 (out '$R9B_OUT')"
case "$(sed -n 's/^README=//p' <<<"$R9B_OUT")" in
  *s1.txt*s2.txt*) ok ;;
  *) bad "R9b: a deps-needing generator must find node_modules linked BEFORE it runs (README '$(sed -n 's/^README=//p' <<<"$R9B_OUT")')" ;;
esac

# R9c: which failure arm a command takes is an EXACT question. Both members edit
# the declared README, so member 2 conflicts in it and the resolution records
# `E=1 bin/gen4.sh`. The table's OTHER row declares `bin/gen4.sh` — a strict
# suffix of it, and a different command that nothing conflicted in. It fails;
# the batch must survive, because a substring test would read it as the
# conflict-recorded one and abandon a train it has no claim on.
mkfix r9c
R9C_REPO="$T/r9c/union"
git_q clone -q "$T/r9c/origin.git" "$R9C_REPO" >/dev/null 2>&1
for m in 1 2; do
  git_q -C "$R9C_REPO" checkout -q -B "sib/$m" origin/main >/dev/null 2>&1
  printf 'member %s only\n' "$m" > "$R9C_REPO/docs/verification-map/README.md"
  git_q -C "$R9C_REPO" add -A; git_q -C "$R9C_REPO" commit -qm "sibling $m" >/dev/null
done
R9C_H1=$(git -C "$R9C_REPO" rev-parse sib/1); R9C_H2=$(git -C "$R9C_REPO" rev-parse sib/2)
git_q -C "$R9C_REPO" checkout -q --detach origin/main >/dev/null 2>&1
R9C_OUT=$(union_probe "$R9C_REPO" \
  $'docs/verification-map/README.md\tE=1 bin/gen4.sh\ndocs/keep.md\tbin/gen4.sh' \
  'case "$1" in docs/verification-map/README.md) printf "E=1 bin/gen4.sh" ;; docs/keep.md) printf "bin/gen4.sh" ;; *) return 1 ;; esac' \
  "$R9C_H1" "$R9C_H2")
grep -qx 'RC=0' <<<"$R9C_OUT" && ok \
  || bad "R9c: a failing command that merely SHARES A SUFFIX with a conflict-recorded one must take the best-effort arm, not abandon the batch (out '$R9C_OUT')"
grep -qx 'MEMBERS=1 2' <<<"$R9C_OUT" && ok \
  || bad "R9c: both members must survive that failure (out '$R9C_OUT')"
# and the conflict-recorded command itself must STILL be fatal when IT fails —
# the exact match must not have loosened the arm R8b pins.
R9C_FATAL=$(union_probe "$R9C_REPO" \
  $'docs/verification-map/README.md\tbin/gen4.sh' \
  'case "$1" in docs/verification-map/README.md) printf "bin/gen4.sh" ;; *) return 1 ;; esac' \
  "$R9C_H1" "$R9C_H2")
grep -qx 'RC=1' <<<"$R9C_FATAL" && ok \
  || bad "R9c: the conflict-recorded command failing must still abandon the batch (out '$R9C_FATAL')"

# ============================================================================
echo "generated-files-train.bh-969: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
