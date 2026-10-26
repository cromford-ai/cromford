#!/bin/bash
# tests/lane-scoped-knob-lint.bh-7436-test.sh — bin/lane-scoped-knob-lint.sh
# (BH-7436): POOL_GH_READ_TIMEOUT_S is a fly-pool lane-only knob.
#
#   C0      this checkout: rc 0, no output.
#   R1-R10  red: a planted global or other-lane export, each in its own repo.
#   G1-G9   green: the allowed paths and the near misses.
#   E1-E4   rc 2: a bad option, a non-git dir, a missing --env-file, -h is rc 0.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lane-scoped-knob-lint.bh-7436-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -n "${T:-}" ] && [ -d "$T" ] || { echo "FAIL: no scratch dir"; exit 1; }
LINT_REL=bin/lane-scoped-knob-lint.sh
K=POOL_GH_READ_TIMEOUT_S

# run <cmd...> — sets RC, OUT
run() { "$@" >"$T/out" 2>"$T/err"; RC=$?; OUT=$(cat "$T/out"); }

# mkrepo <name> — a fresh git repo with the lint and the allowed uses of the knob.
mkrepo() {
  local r="$T/$1"
  mkdir -p "$r" && git -C "$r" init -q && git -C "$r" config user.email t@example.invalid \
    && git -C "$r" config user.name fixture || return 1
  scratch_install_closure "$LINT_REL" "$r" >/dev/null || return 1
  mkdir -p "$r/bin/lib" "$r/catalog/lanes.d/fly-pool.knobs.d" "$r/docs/notes" "$r/tests" \
    "$r/.harness/specs/X" "$r/env-templates/lanes" "$r/cron"
  printf 'case "${%s:-}" in *) %s=20 ;; esac\nexport %s\n' "$K" "$K" "$K" > "$r/bin/fly-pool.sh"
  printf '{"env":"%s","default":20}\n' "$K" > "$r/catalog/lanes.d/fly-pool.knobs.d/$K.json"
  printf '{"env":"POOL_HOLD_READ_TIMEOUT_S","note":"%s still cuts the PR reads"}\n' "$K" \
    > "$r/catalog/lanes.d/fly-pool.knobs.d/POOL_HOLD_READ_TIMEOUT_S.json"
  printf '{"lane":"fly-pool","knobs":{"%s":20}}\n' "$K" > "$r/catalog/lanes.d/fly-pool.json"
  printf '# %s is a positive number\nhold_gh() {\n  case "${%s:-}" in 0) gh "$@" ;; *) timeout "$%s" gh "$@" ;; esac\n}\n' \
    "$K" "$K" "$K" > "$r/bin/lib/hold.sh"
  printf 'export %s=5 in a note\n' "$K" > "$r/docs/notes/x.md"
  printf 'export %s=5\n' "$K" > "$r/tests/x-test.sh"
  printf 'set %s=5\n' "$K" > "$r/.harness/specs/X/plan.md"
  printf 'GLOBAL_X=1\n' > "$r/env-templates/global.env.example"
  git -C "$r" add -A && git -C "$r" commit -qm base || return 1
  printf '%s\n' "$r"
}

# plant <repo> <path> <text> [commit|add|none]
plant() {
  mkdir -p "$1/$(dirname "$2")" && printf '%s\n' "$3" >> "$1/$2"
  case "${4:-commit}" in
    commit) git -C "$1" add -A && git -C "$1" commit -qm plant ;;
    add)    git -C "$1" add -- "$2" ;;
  esac
}

lint() { run bash "$1/$LINT_REL" "${@:2}" "$1"; }

# red <id> <path> <text> [mode] — the planted line must be a finding on that path.
red() {
  local id="$1" r; r=$(mkrepo "$id") || { bad "$id: fixture"; return; }
  plant "$r" "$2" "$3" "${4:-commit}" || { bad "$id: plant"; return; }
  lint "$r"
  if [ "$RC" = 1 ] && grep -q "^$2:[0-9]*: names $K, a fly-pool lane-only knob" <<<"$OUT" \
     && [ "$(wc -l <<<"$OUT")" = 1 ]; then ok
  else bad "$id: '$3' in $2: want rc 1 and one finding on $2, got rc $RC: $OUT"; fi
}
# green <id> <path> <text> [mode]
green() {
  local id="$1" r; r=$(mkrepo "$id") || { bad "$id: fixture"; return; }
  plant "$r" "$2" "$3" "${4:-commit}" || { bad "$id: plant"; return; }
  lint "$r"
  if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok
  else bad "$id: '$3' in $2: want rc 0 and no output, got rc $RC: $OUT"; fi
}

# --- C0: this checkout (the production tree) -----------------------------------
run bash "$REPO/$LINT_REL" "$REPO"
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok; else bad "C0: this checkout: rc $RC: $OUT"; fi

# --- red ---------------------------------------------------------------------
red R1  env-templates/lanes/999-x.env.example "export $K=20"
red R2  env-templates/lanes/999-x.env.example "# $K=20"
red R3  catalog/lanes.d/merge-conductor.knobs.d/$K.json "{\"env\":\"$K\",\"default\":20}"
red R4  catalog/lanes.d/_lib.foo.json "{\"knobs\":[{\"env\":\"$K\"}]}"
red R5  cron/x.cron "*/2 * * * * $K=5 bin/x.sh"
red R6  bin/other-lane.sh "export $K=5"
red R7  bin/lib/hold.sh "$K=30"
red R8  bin/lib/hold.sh "  local $K=30"
red R9  env-templates/global.env.example "export $K=20" add

# R10: a box env file named with --env-file, both setter shapes.
r=$(mkrepo R10) || bad "R10: fixture"
printf 'A=1\n%s=20\n  export %s=5\n' "$K" "$K" > "$T/R10.env"
lint "$r" --env-file "$T/R10.env"
if [ "$RC" = 1 ] && grep -q "^$T/R10.env:2: names $K" <<<"$OUT" \
   && grep -q "^$T/R10.env:3: names $K" <<<"$OUT" \
   && grep -q "lane.fly-pool.pool_gh_read_timeout_s" <<<"$OUT"; then ok
else bad "R10: --env-file setters: rc $RC: $OUT"; fi

# --- green -------------------------------------------------------------------
green G1 bin/other-lane.sh "  # uses $K through hold__gh"
green G2 bin/lib/hold.sh "  echo \"\${$K:-20}\""
green G3 env-templates/global.env.example "${K}X=1"
green G4 env-templates/global.env.example "POOL_HOLD_READ_TIMEOUT_S=45"
green G5 env-templates/global.env.example "X$K=1"
green G6 env-templates/lanes/999-x.env.example "export $K=20" none
green G7 catalog/lanes.d/fly-pool.knobs.d/POOL_PR_BULK_BUDGET_S.json "{\"note\":\"cut at $K\"}"
green G8 docs/notes/y.md "export $K=20"

# G9: --env-file near misses.
r=$(mkrepo G9) || bad "G9: fixture"
printf '#%s=20\n%s_X=1\nPOOL_HOLD_READ_TIMEOUT_S=45\n' "$K" "$K" > "$T/G9.env"
lint "$r" --env-file "$T/G9.env"
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok; else bad "G9: --env-file near misses: rc $RC: $OUT"; fi

# --- exit paths --------------------------------------------------------------
r=$(mkrepo E) || bad "E: fixture"
lint "$r" --bogus
[ "$RC" = 2 ] && ok || bad "E1: --bogus: want rc 2, got $RC"
mkdir -p "$T/nogit"
run bash "$r/$LINT_REL" "$T/nogit"
[ "$RC" = 2 ] && ok || bad "E2: non-git dir: want rc 2, got $RC"
lint "$r" --env-file "$T/absent.env"
[ "$RC" = 2 ] && ok || bad "E3: missing --env-file: want rc 2, got $RC"
run bash "$r/$LINT_REL" -h
if [ "$RC" = 0 ] && grep -q 'lane-scoped knob lint' "$T/out"; then ok; else bad "E4: -h: rc $RC"; fi

echo "lane-scoped-knob-lint.bh-7436: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
