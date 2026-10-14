#!/bin/bash
# tests/impact-learn-lane.bh-6458-test.sh — BH-6458: A HUB LANE TURNS
# dequeue_events ROWS INTO ONE LEARNED-EDGE PR.
#
# bin/impact-learn-lane.sh reads the culprit rule-break / semantic-test rows of
# dequeue_events, runs the tree's own bin/impact-learn.sh record in a scratch
# worktree of origin/main, and opens ONE PR on impact-learn/edges with the new
# catalog/test-impact-learned.d fragments.
#
#   M  bin/impact-learn.sh record --map <file> (the prebuilt map).
#   A  the lane, cases A1-A17 of the plan.
#
# HOW IT DRIVES (D2): every A case runs the real lane script against a real
# bare origin, a real checkout and a real git worktree. Only the hub check, the
# jobs route (dqw_events_list) and the GitHub REST calls are a fixture file,
# sourced through the sandbox-only IMPACT_LEARN_LANE_FIXTURE seam.
#
# Self-contained: no network, no secrets, no clock read (IMPACT_LEARN_NOW is
# fixed). The commit dates are fixed, so the fixture shas are the same on
# every run.
set -uo pipefail
# shellcheck source=lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v git >/dev/null || { echo "impact-learn-lane: git is required"; exit 2; }
command -v jq >/dev/null || { echo "impact-learn-lane: jq is required"; exit 2; }

export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com
export GIT_AUTHOR_DATE='2026-10-01T00:00:00Z' GIT_COMMITTER_DATE='2026-10-01T00:00:00Z'
LD=catalog/test-impact-learned.d
SLUG=example/fixture-repo
NOW=$(date -u -d '2026-10-13T00:00:00Z' +%s)
AT=2026-10-12T10:00:00Z
M1_LINE=$(printf 'bin/x.sh\ttests/s.sh\texample/fixture-repo#101 run 9001\t2026-10-12')

# ── the fixture tree: main (A) and four culprit heads ──────────────────────
S="$T/src"
mkdir -p "$S/bin/lib" "$S/tests" "$S/$LD"
scratch_install_closure bin/impact-learn.sh "$S" >/dev/null || exit 1
scratch_install_closure bin/test-impact.sh "$S" >/dev/null || exit 1
printf '#!/bin/bash\necho x\n' > "$S/bin/x.sh"
printf '#!/bin/bash\necho y\n' > "$S/bin/lib/y.sh"
printf '#!/bin/bash\necho s\n' > "$S/tests/s.sh"
printf '#!/bin/bash\n# test-impact: whole-repo\necho w\n' > "$S/tests/w.sh"
printf '#!/bin/bash\nDIR=$(cd "$(dirname "$0")/.." && pwd)\nbash "$DIR/bin/x.sh"\n' > "$S/tests/x-own.sh"
printf '#!/bin/bash\necho always\n' > "$S/tests/always.sh"
printf 'tests/always.sh\n' > "$S/catalog/test-impact-always.txt"
printf '# learned edges\n' > "$S/$LD/README.md"
git -C "$S" init -q -b main
git -C "$S" add -A && git -C "$S" commit -qm A
# culprit <branch> <file>... — one commit past main that edits (or adds) files.
culprit() {
  local br="$1" f; shift
  git -C "$S" checkout -q -b "$br" main
  for f in "$@"; do mkdir -p "$S/$(dirname "$f")"; printf 'changed %s\n' "$br" >> "$S/$f"; done
  git -C "$S" add -A && git -C "$S" commit -qm "$br"
  git -C "$S" rev-parse HEAD
}
H101=$(culprit c101 bin/x.sh)
H102=$(culprit c102 bin/new.sh)
H103=$(culprit c103 bin/x.sh bin/lib/y.sh)
H104=$(culprit c104 bin/x.sh)
git -C "$S" checkout -q main
ZERO=0000000000000000000000000000000000000000

git init -q --bare -b main "$T/origin.git"
git -C "$S" push -q "$T/origin.git" main:main "$H101:refs/pull/101/head" "$H102:refs/pull/102/head" \
  "$H103:refs/pull/103/head" "$H104:refs/pull/104/head"
mkdir -p "$T/repos"
# --no-local: a local clone hard-links every object, the culprit heads too; the
# lane must fetch them, as it does on the hub.
git clone -q --no-local "$T/origin.git" "$T/repos/fixture-repo"
REPO="$T/repos/fixture-repo"
mkdir -p "$T/pristine"
cp -a "$T/origin.git" "$T/pristine/origin.git"
cp -a "$T/repos" "$T/pristine/repos"

# ── the scratch harness ─────────────────────────────────────────────────────
H="$T/h"
mkdir -p "$H/bin" "$H/env"
: > "$H/env/global.env"
printf '#!/bin/bash\n[ "${BASH_SOURCE[0]}" = "$0" ] || return 0\nexit 0\n' > "$H/bin/jobs-client.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts"\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/jobs-client.sh" "$H/bin/lane-alert.sh"
[ -f "$DIR/bin/impact-learn-lane.sh" ] || echo "FAIL: $DIR/bin/impact-learn-lane.sh is missing (every A case below runs anyway)"
scratch_install_closure bin/impact-learn-lane.sh "$H" >/dev/null 2>&1
LANE="$H/bin/impact-learn-lane.sh"

F="$T/f"
cat > "$T/fx.sh" <<SH
F="$F"
is_hub_box() { [ ! -e "\$F/nothub" ]; }
local_box_name() { echo hub; }
dqw_events_list() {
  echo "dqw \$*" >> "\$F/calls"
  local rc; rc=\$(cat "\$F/events.rc" 2>/dev/null || echo 0)
  cat "\$F/events.json"
  return "\$rc"
}
gh_rest_pr_list() { echo "prlist \$*" >> "\$F/calls"; cat "\$F/open.json" 2>/dev/null || echo '[]'; }
gh_default_auth_for_slug() { echo "auth \$*" >> "\$F/calls"; return 0; }
# hold_push's rewrite guard (BH-5234) reads the open PRs based on the branch.
# The real lib stays for its knob; only the GitHub read is a recorder.
[ -r "\$HARNESS/bin/lib/stale-parent.sh" ] && . "\$HARNESS/bin/lib/stale-parent.sh"
sp_open_children() {
  echo "children \$2" >> "\$F/calls"
  [ -e "\$F/children.fail" ] && { printf 'fixture: the open-PR list is unreadable'; return 1; }
  return 0
}
gh_rest() {
  echo "gh_rest \$1 \$2" >> "\$F/calls"
  local n
  if [ "\$1" = POST ] && [ "\$3" = --input ]; then
    n=\$(grep -c '^gh_rest POST' "\$F/calls"); cp "\$4" "\$F/post-\$n.json"
  fi
  GH_REST_STATUS=\$(cat "\$F/post.status" 2>/dev/null || echo 201)
  if [ "\${GH_REST_STATUS#2}" != "\$GH_REST_STATUS" ]; then
    cat "\$F/post.body" 2>/dev/null \\
      || echo '{"number":777,"html_url":"https://github.example/example/fixture-repo/pull/777"}'
    return 0
  fi
  echo '{"message":"Validation Failed"}'; return 1
}
SH

# reset — a fresh origin, checkout, harness state and fixture answers.
reset() {
  rm -rf "$T/origin.git" "$T/repos" "$H/state" "$H/logs" "$H/locks" "$F" "$T/alerts" "$T/tmp"
  cp -a "$T/pristine/origin.git" "$T/origin.git"
  cp -a "$T/pristine/repos" "$T/repos"
  mkdir -p "$F" "$T/tmp"
  printf '[]\n' > "$F/open.json"
  : > "$F/calls"
  printf '{"rows":[],"truncated":false}\n' > "$F/events.json"
}
# row <pr> <head> <attribution> <class|null> <suites> [created_at] [run_id]
row() {
  jq -nc --argjson pr "$1" --arg head "$2" --arg a "$3" --arg c "$4" --arg s "$5" \
    --arg at "${6:-$AT}" --arg r "${7:-9001}" \
    '{id: 7, repo: "example/fixture-repo", pr: $pr, head: $head, run_id: $r,
      attribution: $a, class: (if $c == "null" then null else $c end), suites: $s, created_at: $at}'
}
# events — the rows on stdin become the route answer, in that order.
events() { jq -s '{rows: ., truncated: false}' > "$F/events.json"; }

# run <case> [VAR=value ...] — one tick of the real lane; rc in $RC, stdout in
# $OUT. A15 is checked after every tick: one worktree line, no temp dir left.
run() {
  local c="$1"; shift
  env -i PATH="$PATH" HOME="$T" HARNESS="$H" HARNESS_TEST_SANDBOX=1 \
    IMPACT_LEARN_LANE_FIXTURE="$T/fx.sh" IMPACT_LEARN_NOW="$NOW" REPOS_ROOT="$T/repos" \
    HARNESS_REPO="$SLUG" TMPDIR="$T/tmp" "$@" bash "$LANE" > "$T/out" 2> "$T/err"; RC=$?
  OUT=$(cat "$T/out")
  [ "$(git -C "$REPO" worktree list 2>/dev/null | grep -c .)" = 1 ] && ok \
    || bad "A15 ($c): a worktree was left: $(git -C "$REPO" worktree list)"
  [ -z "$(ls "$T/tmp" 2>/dev/null | grep '^impact-learn\.')" ] && ok || bad "A15 ($c): a temp dir was left: $(ls "$T/tmp")"
}
posts() { grep -c "^gh_rest POST repos/$SLUG/pulls\$" "$F/calls"; }
lastlog() { tail -1 "$H/logs/impact-learn.log" 2>/dev/null; }
seen() { cat "$H/state/impact-learn/seen.tsv" 2>/dev/null; }
nalerts() { cat "$T/alerts" 2>/dev/null | grep -c .; }
# branch_files — the fragments impact-learn/edges adds over main on the origin.
branch_files() { git -C "$T/origin.git" diff --name-only main impact-learn/edges -- "$LD" 2>/dev/null | grep '\.tsv$'; }
has_branch() { git -C "$T/origin.git" rev-parse -q --verify refs/heads/impact-learn/edges >/dev/null 2>&1; }

# ── M: record --map ─────────────────────────────────────────────────────────
LEARN="$DIR/bin/impact-learn.sh"
TI="$DIR/bin/test-impact.sh"
row 101 "$H101" culprit semantic-test tests/s.sh > "$T/ev101.json"
cp -a "$S" "$T/m1"
git -C "$T/m1" checkout -q main
"$TI" --root "$T/m1" map > "$T/m1.map" 2> "$T/m1.map.err" || bad "M1: the fixture map did not build: $(cat "$T/m1.map.err")"
"$LEARN" record --event "$T/ev101.json" --root "$T/m1" --base main --map "$T/m1.map" > "$T/m1.out" 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "M1: record --map rc=$RC: $(cat "$T/m1.out")"
[ "$(cat "$T/m1/$LD"/*.tsv 2>/dev/null | grep -v '^#')" = "$M1_LINE" ] && ok \
  || bad "M1: the data line with --map is '$(cat "$T/m1/$LD"/*.tsv 2>/dev/null | grep -v '^#')'"
# M1b: the map really is the one passed. A map that already holds the edge
# answers `selected`, even though the tree it is run on has no fragment.
cp -a "$S" "$T/m1b"; git -C "$T/m1b" checkout -q main
cp "$T/m1/$LD"/*.tsv "$T/m1b/$LD/" 2>/dev/null
"$TI" --root "$T/m1b" map > "$T/m1b.map" 2>/dev/null
cp -a "$S" "$T/m1c"; git -C "$T/m1c" checkout -q main
"$LEARN" record --event "$T/ev101.json" --root "$T/m1c" --base main --map "$T/m1b.map" > "$T/m1c.out" 2>&1; RC=$?
[ "$RC" = 0 ] && grep -q '^selected tests/s.sh' "$T/m1c.out" && [ -z "$(ls "$T/m1c/$LD"/*.tsv 2>/dev/null)" ] && ok \
  || bad "M1b: a map that holds the edge did not answer selected (rc=$RC): $(cat "$T/m1c.out")"
# M2: an unreadable map is rc 1 with 0 writes, and stderr names it.
cp -a "$S" "$T/m2"; git -C "$T/m2" checkout -q main
"$LEARN" record --event "$T/ev101.json" --root "$T/m2" --base main --map "$T/nonexistent.map" > "$T/m2.out" 2> "$T/m2.err"; RC=$?
[ "$RC" = 1 ] && ok || bad "M2: record --map <missing> rc=$RC (want 1): $(cat "$T/m2.out" "$T/m2.err")"
[ -z "$(ls "$T/m2/$LD"/*.tsv 2>/dev/null)" ] && ok || bad "M2: a fragment was written"
grep -qF "$T/nonexistent.map" "$T/m2.err" && ok || bad "M2: stderr does not name the map: $(cat "$T/m2.err")"

# ── A1: one culprit row → one PR with one fragment ──────────────────────────
reset
row 101 "$H101" culprit semantic-test tests/s.sh | events
run A1
[ "$RC" = 0 ] && ok || bad "A1: rc=$RC: $OUT $(cat "$T/err")"
[ "$(posts)" = 1 ] && ok || bad "A1: $(posts) POSTs to repos/$SLUG/pulls (want 1): $(cat "$F/calls")"
[ "$(jq -r '.head + " " + .base' "$F/post-1.json" 2>/dev/null)" = "impact-learn/edges main" ] && ok \
  || bad "A1: the POST head/base is '$(jq -r '.head + " " + .base' "$F/post-1.json" 2>/dev/null)'"
jq -r .body "$F/post-1.json" 2>/dev/null | grep -qx 'Harness-Job: lane:impact-learn-lane' && ok \
  || bad "A1: the PR body has no lane:impact-learn-lane trailer: $(jq -r .body "$F/post-1.json" 2>/dev/null)"
jq -r .body "$F/post-1.json" 2>/dev/null | grep -qF '`bin/x.sh` → `tests/s.sh` (from example/fixture-repo#101 run 9001, 2026-10-12)' && ok \
  || bad "A1: the PR body does not list the edge: $(jq -r .body "$F/post-1.json" 2>/dev/null)"
[ "$(branch_files | grep -c .)" = 1 ] && ok || bad "A1: the branch adds $(branch_files | grep -c .) fragments (want 1)"
bf=$(branch_files | sed -n 1p)
[ "$(git -C "$T/origin.git" show "impact-learn/edges:$bf" 2>/dev/null | grep -v '^#')" = "$M1_LINE" ] && ok \
  || bad "A1: the branch fragment's data line is '$(git -C "$T/origin.git" show "impact-learn/edges:$bf" 2>/dev/null | grep -v '^#')'"
git clone -q -b impact-learn/edges "$T/origin.git" "$T/a1chk" 2>/dev/null
printf 'bin/x.sh\n' > "$T/a1.changed"
"$T/a1chk/bin/test-impact.sh" --root "$T/a1chk" select --map-only --changed "$T/a1.changed" > "$T/a1.sel" 2>/dev/null
grep -qxF tests/s.sh "$T/a1.sel" && ok || bad "A1: the branch's map does not select tests/s.sh for bin/x.sh: $(cat "$T/a1.sel")"
lastlog | grep -q ' edges=1 ' && lastlog | grep -q 'opened #777$' && ok || bad "A1: log line is '$(lastlog)'"
[ "$(seen)" = "example/fixture-repo#101 $H101 9001	$AT	edges" ] && ok || bad "A1: seen.tsv is '$(seen)'"
[ "$(nalerts)" = 0 ] && ok || bad "A1: alerts: $(cat "$T/alerts")"

git -C "$REPO" cat-file -e "$H101^{commit}" 2>/dev/null && ok || bad "A1: the lane did not fetch the culprit head into the checkout"

# ── A2: the same tick again: the row is seen, nothing is re-learned ─────────
sha1=$(git -C "$T/origin.git" rev-parse impact-learn/edges 2>/dev/null)
run A2
[ "$RC" = 0 ] && [ "$(posts)" = 1 ] && ok || bad "A2: rc=$RC, $(posts) POSTs in total (want 1)"
lastlog | grep -q ' candidates=0 ' && lastlog | grep -q ' none$' && ok || bad "A2: log line is '$(lastlog)'"
[ "$(git -C "$T/origin.git" rev-parse impact-learn/edges 2>/dev/null)" = "$sha1" ] && ok || bad "A2: the branch moved"

# ── A3: an open lane PR stops the tick; old enough, it pages once ───────────
for c in "47 2026-10-11T01:00:00Z 0" "48 2026-10-11T00:00:00Z 0" "49 2026-10-10T23:00:00Z 1"; do
  set -- $c
  reset
  row 101 "$H101" culprit semantic-test tests/s.sh | events
  printf '[{"number":555,"created_at":"%s","head":{"ref":"impact-learn/edges"}}]\n' "$2" > "$F/open.json"
  run "A3-$1h"
  [ "$RC" = 0 ] && ok || bad "A3 ${1}h: rc=$RC: $(cat "$T/err")"
  [ "$(nalerts)" = "$3" ] && ok || bad "A3 ${1}h: $(nalerts) alerts (want $3): $(cat "$T/alerts" 2>/dev/null)"
  if [ "$3" = 1 ]; then
    grep -q -- '--id impact-learn-stale:555 ' "$T/alerts" && grep -q 'learned-edge PR #555 has been open 49h' "$T/alerts" && ok \
      || bad "A3 ${1}h: the alert is '$(cat "$T/alerts")'"
  fi
  grep -q '^dqw ' "$F/calls" && bad "A3 ${1}h: the events were read" || ok
  lastlog | grep -q 'open #555$' && ok || bad "A3 ${1}h: log line is '$(lastlog)'"
  [ -z "$(seen)" ] && ok || bad "A3 ${1}h: seen.tsv was written"
done

# ── A4: rows that are not candidates are neither learned nor seen ───────────
reset
{ row 101 "$H101" bystander semantic-test tests/s.sh
  row 101 "$H101" culprit flake tests/s.sh
  row 101 "$H101" culprit semantic-test -; } | events
run A4
[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "A4: rc=$RC, $(posts) POSTs (want 0)"
lastlog | grep -q ' events=3 candidates=0 ' && ok || bad "A4: log line is '$(lastlog)'"
[ -z "$(seen)" ] && ok || bad "A4: seen.tsv is '$(seen)'"
# A4b: culprit / rule-break is a candidate.
reset
row 101 "$H101" culprit rule-break tests/s.sh | events
run A4b
[ "$RC" = 0 ] && [ "$(posts)" = 1 ] && ok || bad "A4b: rc=$RC, $(posts) POSTs (want 1): $(cat "$T/err")"
# A4c: a null class is skipped and not seen; once classified, it is learned.
reset
row 101 "$H101" culprit null tests/s.sh | events
run A4c-null
[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && [ -z "$(seen)" ] && ok || bad "A4c: null class: rc=$RC, $(posts) POSTs, seen '$(seen)'"
row 101 "$H101" culprit semantic-test tests/s.sh | events
run A4c-set
[ "$RC" = 0 ] && [ "$(posts)" = 1 ] && ok || bad "A4c: the classified row was not learned: rc=$RC, $(posts) POSTs"

# ── A5: a suite the map already selects writes nothing, but is seen ─────────
reset
row 101 "$H101" culprit semantic-test tests/x-own.sh | events
run A5
[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "A5: rc=$RC, $(posts) POSTs (want 0)"
grep -q 'selected tests/x-own.sh' <<<"$OUT" && ok || bad "A5: the learner did not say selected: $OUT"
[ "$(seen)" = "example/fixture-repo#101 $H101 9001	$AT	none" ] && ok || bad "A5: seen.tsv is '$(seen)'"

# ── A6: an edge whose path exists only on the culprit is dropped ────────────
reset
row 102 "$H102" culprit semantic-test tests/s.sh | events
run A6
[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "A6: rc=$RC, $(posts) POSTs (want 0): $OUT"
lastlog | grep -q ' dead=1 ' && ok || bad "A6: log line is '$(lastlog)'"
[ "$(seen)" = "example/fixture-repo#102 $H102 9001	$AT	none" ] && ok || bad "A6: seen.tsv is '$(seen)'"
# A6b: a whole-repo suite's `*` edge is kept.
reset
row 102 "$H102" culprit semantic-test tests/w.sh | events
run A6b
[ "$RC" = 0 ] && [ "$(posts)" = 1 ] && ok || bad "A6b: rc=$RC, $(posts) POSTs (want 1): $OUT"
a6b=$(git -C "$T/origin.git" show "impact-learn/edges:$(branch_files | sed -n 1p)" 2>/dev/null)
grep -q "^\*	tests/w.sh	" <<<"$a6b" && ok \
  || bad "A6b: the branch has no * row for tests/w.sh"

# ── A7: the mass cap ────────────────────────────────────────────────────────
reset
{ row 103 "$H103" culprit semantic-test tests/s.sh
  row 102 "$H102" culprit semantic-test tests/w.sh; } | events
run A7-cap2 IMPACT_LEARN_MAX_EDGES=2
[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "A7: cap 2: rc=$RC, $(posts) POSTs (want 0)"
[ "$(nalerts)" = 1 ] && grep -q -- '--id impact-learn-mass ' "$T/alerts" \
  && grep -q '3 new learned edges from 2 events is over IMPACT_LEARN_MAX_EDGES=2; no PR opened' "$T/alerts" && ok \
  || bad "A7: cap 2: alerts are '$(cat "$T/alerts" 2>/dev/null)'"
[ -z "$(seen)" ] && ok || bad "A7: cap 2: seen.tsv is '$(seen)'"
lastlog | grep -q ' mass$' && ok || bad "A7: cap 2: log line is '$(lastlog)'"
has_branch && bad "A7: cap 2: a branch was pushed" || ok
run A7-cap3 IMPACT_LEARN_MAX_EDGES=3
[ "$RC" = 0 ] && [ "$(posts)" = 1 ] && ok || bad "A7: cap 3: rc=$RC, $(posts) POSTs (want 1)"
[ "$(branch_files | grep -c .)" = 3 ] && ok || bad "A7: cap 3: the branch adds $(branch_files | grep -c .) fragments (want 3)"

# ── A8: the per-tick event cap takes the oldest first ───────────────────────
reset
{ row 101 "$H101" culprit semantic-test tests/s.sh 2026-10-12T09:00:00Z
  row 103 "$H103" culprit semantic-test tests/s.sh 2026-10-12T11:00:00Z 9002; } | events
run A8 IMPACT_LEARN_MAX_EVENTS=1
[ "$RC" = 0 ] && [ "$(posts)" = 1 ] && ok || bad "A8: rc=$RC, $(posts) POSTs (want 1)"
[ "$(seen)" = "example/fixture-repo#101 $H101 9001	2026-10-12T09:00:00Z	edges" ] && ok || bad "A8: seen.tsv is '$(seen)'"
[ "$(branch_files | grep -c .)" = 1 ] && ok || bad "A8: the branch adds $(branch_files | grep -c .) fragments (want 1)"

# ── A9: a head that is no commit, even after the fetches ────────────────────
reset
row 101 "$ZERO" culprit semantic-test tests/s.sh | events
run A9
[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "A9: rc=$RC, $(posts) POSTs (want 0)"
[ "$(seen)" = "example/fixture-repo#101 $ZERO 9001	$AT	unreachable" ] && ok || bad "A9: seen.tsv is '$(seen)'"
lastlog | grep -q ' unreachable=1 ' && ok || bad "A9: log line is '$(lastlog)'"

# ── A10: dry run ────────────────────────────────────────────────────────────
reset
row 101 "$H101" culprit semantic-test tests/s.sh | events
run A10 IMPACT_LEARN_ACT=0
[ "$RC" = 0 ] && ok || bad "A10: rc=$RC"
grep -q 'would-open edges=1' <<<"$OUT" && ok || bad "A10: stdout has no would-open edges=1: $OUT"
[ "$(posts)" = 0 ] && ok || bad "A10: $(posts) POSTs (want 0)"
has_branch && bad "A10: a branch was pushed" || ok
[ -z "$(seen)" ] && ok || bad "A10: seen.tsv is '$(seen)'"

# ── A11: the push fails ─────────────────────────────────────────────────────
reset
row 101 "$H101" culprit semantic-test tests/s.sh | events
git -C "$REPO" remote set-url --push origin "$T/nowhere.git"
run A11
[ "$RC" = 1 ] && [ "$(posts)" = 0 ] && ok || bad "A11: rc=$RC (want 1), $(posts) POSTs (want 0)"
[ "$(nalerts)" = 1 ] && grep -q -- '--id impact-learn-push ' "$T/alerts" && ok || bad "A11: alerts are '$(cat "$T/alerts" 2>/dev/null)'"
[ -z "$(seen)" ] && ok || bad "A11: seen.tsv is '$(seen)'"

# ── A12: the PR POST is refused; the next tick opens it ─────────────────────
reset
row 101 "$H101" culprit semantic-test tests/s.sh | events
echo 422 > "$F/post.status"
run A12-422
[ "$RC" = 1 ] && ok || bad "A12: rc=$RC (want 1)"
grep -q 'opened' "$H/logs/impact-learn.log" "$T/out" 2>/dev/null && bad "A12: a 422 printed opened" || ok
[ "$(nalerts)" = 1 ] && grep -q -- '--id impact-learn-pr ' "$T/alerts" && ok || bad "A12: alerts are '$(cat "$T/alerts" 2>/dev/null)'"
[ -z "$(seen)" ] && ok || bad "A12: seen.tsv is '$(seen)'"
echo 201 > "$F/post.status"
run A12-201
[ "$RC" = 0 ] && [ "$(posts)" = 2 ] && ok || bad "A12: retry: rc=$RC, $(posts) POSTs in total (want 2)"
lastlog | grep -q 'opened #777$' && ok || bad "A12: retry: log line is '$(lastlog)'"
[ "$(branch_files | grep -c .)" = 1 ] && ok || bad "A12: retry: the branch adds $(branch_files | grep -c .) fragments (want 1)"

# A12b: rc 0 but HTTP 200, and A12c: a 201 with no PR number, are not opened.
for c in "A12b 200 {\"number\":777}" "A12c 201 {\"message\":\"ok\"}"; do
  set -- $c
  reset
  row 101 "$H101" culprit semantic-test tests/s.sh | events
  echo "$2" > "$F/post.status"; printf '%s\n' "$3" > "$F/post.body"
  run "$1"
  [ "$RC" = 1 ] && ok || bad "$1: rc=$RC (want 1)"
  grep -q 'opened' "$H/logs/impact-learn.log" 2>/dev/null && bad "$1: the log says opened: $(lastlog)" || ok
  [ "$(nalerts)" = 1 ] && grep -q -- '--id impact-learn-pr ' "$T/alerts" && ok || bad "$1: alerts are '$(cat "$T/alerts" 2>/dev/null)'"
  [ -z "$(seen)" ] && ok || bad "$1: seen.tsv is '$(seen)'"
done

# ── A13: the events route cannot be read ────────────────────────────────────
# The fixture still prints a well-formed answer: the rc alone must stop it.
reset
row 101 "$H101" culprit semantic-test tests/s.sh | events
echo 1 > "$F/events.rc"
run A13
[ "$RC" = 1 ] && ok || bad "A13: rc=$RC (want 1)"
lastlog | grep -q 'events-unreadable' && ok || bad "A13: log line is '$(lastlog)'"
[ "$(nalerts)" = 1 ] && grep -q -- '--id impact-learn-events ' "$T/alerts" && ok || bad "A13: alerts are '$(cat "$T/alerts" 2>/dev/null)'"
[ "$(posts)" = 0 ] && [ -z "$(seen)" ] && ok || bad "A13: $(posts) POSTs, seen '$(seen)'"
# A13b: rc 0 with an answer that has no rows array is unreadable too.
reset
printf '{"error":"fixture"}\n' > "$F/events.json"
run A13b
[ "$RC" = 1 ] && lastlog | grep -q 'events-unreadable' && ok || bad "A13b: rc=$RC, log line is '$(lastlog)'"

# ── A14: not the hub ────────────────────────────────────────────────────────
reset
row 101 "$H101" culprit semantic-test tests/s.sh | events
: > "$F/nothub"
run A14
[ "$RC" = 0 ] && ok || bad "A14: rc=$RC (want 0)"
[ ! -e "$H/logs/impact-learn.log" ] && ok || bad "A14: a log line was written: $(lastlog)"
[ ! -s "$F/calls" ] && ok || bad "A14: calls were made: $(cat "$F/calls")"

# ── A16: the seen.tsv prune ─────────────────────────────────────────────────
reset
mkdir -p "$H/state/impact-learn"
printf 'example/fixture-repo#90 %s 1\t2026-10-04T16:00:00Z\tnone\nexample/fixture-repo#91 %s 2\t2026-10-12T14:00:00Z\tedges\n' \
  "$H101" "$H101" > "$H/state/impact-learn/seen.tsv"
run A16
[ "$RC" = 0 ] && ok || bad "A16: rc=$RC"
grep -q '#90 ' <<<"$(seen)" && bad "A16: the 200h-old line was not pruned" || ok
grep -q '#91 ' <<<"$(seen)" && ok || bad "A16: the 10h-old line was pruned"

# ── A17: the map is rebuilt after a write ───────────────────────────────────
reset
{ row 101 "$H101" culprit semantic-test tests/s.sh
  row 104 "$H104" culprit semantic-test tests/s.sh "$AT" 9004; } | events
run A17
[ "$RC" = 0 ] && [ "$(posts)" = 1 ] && ok || bad "A17: rc=$RC, $(posts) POSTs (want 1)"
grep -q '^example/fixture-repo#104: selected tests/s.sh' <<<"$OUT" && ok \
  || bad "A17: the second event did not see the new edge as selected: $OUT"
[ "$(branch_files | grep -c .)" = 1 ] && ok || bad "A17: the branch adds $(branch_files | grep -c .) fragments (want 1)"

# ── A18: a branch left by a closed PR is replaced through hold_push ─────────
# The push goes through hold_push (BH-2504) with the remote head as its lease.
# Step 1 found no open PR, so the old branch is replaced, never merged into.
reset
git -C "$T/origin.git" update-ref refs/heads/impact-learn/edges "$H102"
row 101 "$H101" culprit semantic-test tests/s.sh | events
run A18
[ "$RC" = 0 ] && [ "$(posts)" = 1 ] && ok || bad "A18: rc=$RC (want 0), $(posts) POSTs (want 1): $(cat "$T/err")"
git -C "$T/origin.git" merge-base --is-ancestor "$H102" impact-learn/edges 2>/dev/null \
  && bad "A18: the closed PR's commit is still on the branch" || ok
[ "$(branch_files | grep -c .)" = 1 ] && ok || bad "A18: the branch adds $(branch_files | grep -c .) fragments (want 1)"
LANE_CODE=$(grep -vE '^[[:space:]]*#' "$LANE")
grep -q 'hold_push' <<<"$LANE_CODE" && ! grep -qE 'git[^|]* push' <<<"$LANE_CODE" \
  && ok || bad "A18: the lane must push only through hold_push"
grep -q '^children impact-learn/edges$' "$F/calls" && ok || bad "A18: the rewrite guard did not read the branch's children: $(cat "$F/calls")"

# ── A19: the children of the old branch cannot be read: nothing is pushed ───
reset
git -C "$T/origin.git" update-ref refs/heads/impact-learn/edges "$H102"
: > "$F/children.fail"
row 101 "$H101" culprit semantic-test tests/s.sh | events
run A19
[ "$RC" = 1 ] && [ "$(posts)" = 0 ] && ok || bad "A19: rc=$RC (want 1), $(posts) POSTs (want 0)"
[ "$(git -C "$T/origin.git" rev-parse impact-learn/edges)" = "$H102" ] && ok || bad "A19: the branch moved"
grep -q -- '--id impact-learn-push ' "$T/alerts" && ok || bad "A19: alerts are '$(cat "$T/alerts" 2>/dev/null)'"
[ -z "$(seen)" ] && ok || bad "A19: seen.tsv is '$(seen)'"

echo "impact-learn-lane: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
