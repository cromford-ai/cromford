#!/bin/bash
# tests/project-loop-lint.bh-5945-test.sh — BH-5945: the rules-pack ratchet
# bin/project-loop-lint.sh. A hub lane that the diff ADDS (catalog/lanes.d/<id>.json,
# scope hub or "hub" in .boxes) must not loop over projects in its own script
# unless it dispatches through bin/lib/project-lanes.sh (pl_dispatch,
# pl_lane_dispatch) or bin/project-lane-run.sh, or carries a
# `# project-loop-ok: <reason>` marker. Each case builds a scratch git repo: a
# base commit, then a head commit with the change under test.
#   P1  new hub lane: fleet-conf.sh --projects loop under a global flock -> rc 1,
#       one line naming bin/x.sh, S1 and locks/x.lock
#   P2  while read ... done < "$H/fleet.conf" -> rc 1 (S2)
#   P3  global flock + for p in $PROJECTS -> rc 1 (S3)
#   P4  bare `# project-loop-ok:` marker -> rc 1, "marker with no reason"
#   P5  P1's lane on pl_dispatch -> rc 0, no stdout
#   P6  `# project-loop-ok: one fleet total` -> rc 0
#   P7  the loop in a new scope:project lane -> rc 0
#   P8  an EXISTING hub lane (its json edited too) gains the loop -> rc 0
#   P9  fleet-conf.sh "$P" repo and a per-project lock -> rc 0
#   P10 --projects only in a comment -> rc 0
#   P11 --base no-such-ref -> rc 2, empty stdout
#   P12 the real tree, --base HEAD -> rc 0, empty stdout
#   P13 bin/rules-pack.sh --only project-loop on P1's repo -> rc 1, `project-loop: ` line
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/project-loop-lint.bh-5945-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LINT="$DIR/bin/project-loop-lint.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

# repo <name> — a scratch repo with one base commit (an existing hub lane "old").
# Prints nothing; sets R. Then the case writes its head files and calls head_commit.
repo() {
  R="$T/$1"; mkdir -p "$R/catalog/lanes.d" "$R/bin"
  git init -q -b main "$R"
  printf '{"id":"old","scope":"hub","script":"bin/old.sh","boxes":["hub"]}\n' > "$R/catalog/lanes.d/old.json"
  printf '#!/bin/bash\necho old\n' > "$R/bin/old.sh"
  git -C "$R" add -A; git -C "$R" commit -qm base
  BASE=$(git -C "$R" rev-parse HEAD)
}
head_commit() { git -C "$R" add -A; git -C "$R" commit -qm head; }
# lane <id> <scope> — a new lane file for bin/<id>.sh
lane() { printf '{"id":"%s","scope":"%s","script":"bin/%s.sh","boxes":["%s"]}\n' "$1" "$2" "$1" "$([ "$2" = hub ] && echo hub || echo small)" > "$R/catalog/lanes.d/$1.json"; }
lint() { OUT=$(bash "$LINT" --base "$BASE" "$R" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err"); }

LOOP_S1='#!/bin/bash
H=/root/harness
exec 9>"$H/locks/x.lock"
flock -n 9 || exit 0
for p in $("$H/bin/fleet-conf.sh" --projects); do
  "$H/bin/do-thing.sh" "$p"
done'

# --- P1 -------------------------------------------------------------------
repo p1; lane x hub; printf '%s\n' "$LOOP_S1" > "$R/bin/x.sh"; head_commit; lint
[ "$RC" -eq 1 ] && ok || bad "P1 rc $RC (want 1): $OUT $ERR"
[ "$(printf '%s\n' "$OUT" | grep -c .)" = 1 ] && ok || bad "P1 want one stdout line: $OUT"
case "$OUT" in "bin/x.sh: new hub lane x loops over projects (S1 line 5) under the global lock locks/x.lock (line 3)"*pl_dispatch*) ok ;; *) bad "P1 line: $OUT" ;; esac
P1_REPO=$R P1_BASE=$BASE

# --- P2 -------------------------------------------------------------------
repo p2; lane x hub
printf '#!/bin/bash\nH=/root/harness\nwhile read -r p _; do\n  echo "$p"\ndone < "$H/fleet.conf"\n' > "$R/bin/x.sh"; head_commit; lint
[ "$RC" -eq 1 ] && ok || bad "P2 rc $RC (want 1): $OUT $ERR"
case "$OUT" in *"(S2 line 5)"*) ok ;; *) bad "P2 line: $OUT" ;; esac

# --- P3 -------------------------------------------------------------------
repo p3; lane x hub
printf '#!/bin/bash\nH=/root/harness\nexec 9>"$H/locks/x.lock"\nflock -n 9 || exit 0\nfor p in $PROJECTS; do\n  echo "$p"\ndone\n' > "$R/bin/x.sh"; head_commit; lint
[ "$RC" -eq 1 ] && ok || bad "P3 rc $RC (want 1): $OUT $ERR"
case "$OUT" in *"(S3 line 5) under the global lock locks/x.lock (line 3)"*) ok ;; *) bad "P3 line: $OUT" ;; esac

# --- P4 -------------------------------------------------------------------
repo p4; lane x hub; printf '%s\n# project-loop-ok:\n' "$LOOP_S1" > "$R/bin/x.sh"; head_commit; lint
[ "$RC" -eq 1 ] && ok || bad "P4 rc $RC (want 1): $OUT"
case "$OUT" in "bin/x.sh: project-loop-ok marker with no reason"*) ok ;; *) bad "P4 line: $OUT" ;; esac

# --- P5 -------------------------------------------------------------------
repo p5; lane x hub
printf '#!/bin/bash\nH=/root/harness\n. "$H/bin/lib/project-lanes.sh" || exit 1\nexec 9>"$H/locks/x.lock"\nflock -n 9 || exit 0\nfor p in $("$H/bin/fleet-conf.sh" --projects); do :; done\npl_dispatch x 600 "$H/bin/x-one.sh"\n' > "$R/bin/x.sh"
head_commit; lint
[ "$RC" -eq 0 ] && ok || bad "P5 rc $RC (want 0): $OUT $ERR"
[ -z "$OUT" ] && ok || bad "P5 stdout: $OUT"

# --- P6 -------------------------------------------------------------------
repo p6; lane x hub; printf '%s\n# project-loop-ok: one fleet total\n' "$LOOP_S1" > "$R/bin/x.sh"; head_commit; lint
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok || bad "P6 rc $RC (want 0): $OUT"

# --- P7 -------------------------------------------------------------------
repo p7; lane x project; printf '%s\n' "$LOOP_S1" > "$R/bin/x.sh"; head_commit; lint
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok || bad "P7 rc $RC (want 0): $OUT"

# --- P8 -------------------------------------------------------------------
repo p8; printf '%s\n' "$LOOP_S1" > "$R/bin/old.sh"
printf '{"id":"old","scope":"hub","script":"bin/old.sh","boxes":["hub"],"cadence":"*/5 * * * *"}\n' > "$R/catalog/lanes.d/old.json"; head_commit; lint
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok || bad "P8 rc $RC (want 0): $OUT"

# --- P9 -------------------------------------------------------------------
repo p9; lane x hub
printf '#!/bin/bash\nH=/root/harness\nP="$1"\nexec 9>"$H/locks/x-$P.lock"\nflock -n 9 || exit 0\nrepo=$("$H/bin/fleet-conf.sh" "$P" repo)\necho "$repo"\n' > "$R/bin/x.sh"; head_commit; lint
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok || bad "P9 rc $RC (want 0): $OUT"

# --- P10 ------------------------------------------------------------------
repo p10; lane x hub
printf '#!/bin/bash\n# the old form was: for p in $(fleet-conf.sh --projects)\n  # while read p; do :; done < fleet.conf\necho one  # fleet-conf.sh --projects\n' > "$R/bin/x.sh"; head_commit; lint
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok || bad "P10 rc $RC (want 0): $OUT"

# --- P11 ------------------------------------------------------------------
OUT=$(bash "$LINT" --base no-such-ref "$P1_REPO" 2>/dev/null); RC=$?
[ "$RC" -eq 2 ] && [ -z "$OUT" ] && ok || bad "P11 rc $RC (want 2), stdout '$OUT'"

# --- P12 ------------------------------------------------------------------
OUT=$(bash "$LINT" --base HEAD "$DIR" 2>"$T/err"); RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok || bad "P12 real tree rc $RC (want 0): $OUT $(cat "$T/err")"

# --- P13: through the rules pack, the production entry point --------------
R=$P1_REPO
mkdir -p "$R/bin" && cp "$LINT" "$R/bin/project-loop-lint.sh" 2>/dev/null
git -C "$R" add -A; git -C "$R" commit -qm "lint in tree" >/dev/null
OUT=$(env -u HARNESS bash "$DIR/bin/rules-pack.sh" --tree "$R" --base "$P1_BASE" --only project-loop --runner local 2>"$T/err"); RC=$?
[ "$RC" -eq 1 ] && ok || bad "P13 rules-pack rc $RC (want 1): $OUT $(tail -5 "$T/err")"
case "$OUT" in "project-loop: bin/x.sh: new hub lane x"*) ok ;; *) bad "P13 stdout: $OUT" ;; esac

echo "project-loop-lint.bh-5945: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
