#!/bin/bash
# tests/impact-learned-expire.bh-6460-test.sh — BH-6460 (slice C3 of BH-6390):
# A LEARNED IMPACT EDGE EXPIRES AFTER N CLEAN PASSES.
#
# An edge expires when its suite passed N times (IMPACT_LEARN_EXPIRE_PASSES,
# default 30) with no failure after the edge's date. The counts come from the
# suite_results ledger through GET /api/suite-results/passes.
#
#   X  bin/impact-learn.sh expire, the pure verb (cases X1-X11 of the plan).
#   E  bin/impact-learn-lane.sh, the expiry step (cases E1-E10 of the plan).
#
# HOW IT DRIVES (D2): the X cases run the real verb over fragments the real
# `record` verb wrote. The E cases run the real lane against a real bare
# origin, a real checkout and a real worktree. Only the hub check, the jobs
# transport (_jobs_req) and the GitHub REST calls are a fixture file, sourced
# through the sandbox-only IMPACT_LEARN_LANE_FIXTURE seam, so the lane's own
# sr_passes_list (URL and shape check) runs.
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

command -v git >/dev/null || { echo "impact-learned-expire: git is required"; exit 2; }
command -v jq >/dev/null || { echo "impact-learned-expire: jq is required"; exit 2; }

export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com
export GIT_AUTHOR_DATE='2026-10-01T00:00:00Z' GIT_COMMITTER_DATE='2026-10-01T00:00:00Z'
LD=catalog/test-impact-learned.d
SLUG=example/fixture-repo
NOW=$(date -u -d '2026-10-13T00:00:00Z' +%s)
AT=2026-10-12T10:00:00Z
TAB=$'\t'
LEARN="$DIR/bin/impact-learn.sh"

# ── the fixture tree: main (A) and three culprit heads ──────────────────────
S="$T/src"
mkdir -p "$S/bin/lib" "$S/tests" "$S/$LD"
scratch_install_closure bin/impact-learn.sh "$S" >/dev/null || exit 1
scratch_install_closure bin/test-impact.sh "$S" >/dev/null || exit 1
printf '#!/bin/bash\necho x\n' > "$S/bin/x.sh"
printf '#!/bin/bash\necho y\n' > "$S/bin/lib/y.sh"
printf '#!/bin/bash\necho s\n' > "$S/tests/s.sh"
printf '#!/bin/bash\n# test-impact: whole-repo\necho w\n' > "$S/tests/w.sh"
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
git -C "$S" checkout -q main

# row <pr> <head> <attribution> <class> <suites> [created_at] [run_id] — one
# dequeue_events row in the shape dqw_events_list returns in .rows[].
row() {
  jq -nc --argjson pr "$1" --arg head "$2" --arg a "$3" --arg c "$4" --arg s "$5" \
    --arg at "${6:-$AT}" --arg r "${7:-9001}" \
    '{id: 7, repo: "example/fixture-repo", pr: $pr, head: $head, run_id: $r,
      attribution: $a, class: $c, suites: $s, created_at: $at}'
}
nfrag() { find "$1" -maxdepth 1 -name '*.tsv' -type f 2>/dev/null | grep -c .; }
sums() { (cd "$1" && sha256sum ./*.tsv 2>/dev/null); }

# ── X: the verb ─────────────────────────────────────────────────────────────
# The store: fragments written by the real `record` (D63), plus one hand row.
X="$T/xrepo"
cp -a "$S" "$X"
row 101 "$H101" culprit semantic-test tests/s.sh 2026-10-01T10:00:00Z > "$T/xev-s.json"
row 101 "$H101" culprit semantic-test tests/w.sh 2026-10-01T10:00:00Z > "$T/xev-w.json"
"$LEARN" record --event "$T/xev-s.json" --root "$X" --base main > "$T/xrec-s.out" 2>&1 \
  || bad "X setup: record tests/s.sh failed: $(cat "$T/xrec-s.out")"
"$LEARN" record --event "$T/xev-w.json" --root "$X" --base main > "$T/xrec-w.out" 2>&1 \
  || bad "X setup: record tests/w.sh failed: $(cat "$T/xrec-w.out")"
XS=$(awk '$1 == "edge" { print $NF }' "$T/xrec-s.out"); XS=$(basename "$XS")
XW=$(awk '$1 == "edge" { print $NF }' "$T/xrec-w.out"); XW=$(basename "$XW")
[ -n "$XS" ] && [ -n "$XW" ] && [ "$XS" != "$XW" ] && ok || bad "X setup: the learner wrote '$XS' and '$XW'"
grep -q "^\*${TAB}tests/w.sh${TAB}" "$X/$LD/$XW" && ok || bad "X setup: $XW is not a * row: $(cat "$X/$LD/$XW")"
# A hand row: no learner comment line.
XH=00000000000000aa.tsv
printf 'bin/lib/y.sh\ttests/s.sh\thand\t2026-10-01\n' > "$T/hand.tsv"

# xcase <name> <counts-lines> [extra args] — a fresh copy of the store, then
# the real verb. The store holds $XS (bin/x.sh -> tests/s.sh) only, unless the
# case copies more in. rc in $RC, stdout+stderr in $OUT, the dir in $XD.
xstore() { XD="$T/x-$1"; scratch_rm "$XD"; mkdir -p "$XD"; cp "$X/$LD/$XS" "$XD/"; }
xrun() {
  "$LEARN" expire "$@" > "$T/xout" 2>&1; RC=$?
  OUT=$(cat "$T/xout")
}

# X1: exactly N passes, no fail → the fragment is deleted.
xstore X1; printf '2026-10-01\ttests/s.sh\t30\t0\n' > "$T/c1"
xrun --counts "$T/c1" --passes 30 --out-dir "$XD"
[ "$RC" = 0 ] && ok || bad "X1: rc=$RC (want 0): $OUT"
[ ! -e "$XD/$XS" ] && ok || bad "X1: the 30-pass fragment still exists"
grep -q "^expire tests/s.sh bin/x.sh $XD/$XS passes=30\$" <<<"$OUT" && ok || bad "X1: no expire line: $OUT"
grep -qx 'impact-learn: expire expired=1 kept=0' <<<"$OUT" && ok || bad "X1: summary: $OUT"

# X2: N+1 passes → deleted.
xstore X2; printf '2026-10-01\ttests/s.sh\t31\t0\n' > "$T/c2"
xrun --counts "$T/c2" --passes 30 --out-dir "$XD"
[ "$RC" = 0 ] && [ ! -e "$XD/$XS" ] && ok || bad "X2: rc=$RC, 31 passes did not expire: $OUT"

# X3: N-1 passes → kept.
xstore X3; printf '2026-10-01\ttests/s.sh\t29\t0\n' > "$T/c3"
xrun --counts "$T/c3" --passes 30 --out-dir "$XD"
[ "$RC" = 0 ] && [ -e "$XD/$XS" ] && ok || bad "X3: rc=$RC, 29 passes expired: $OUT"
grep -q '^keep tests/s.sh bin/x.sh (passes=29 < 30)$' <<<"$OUT" && ok || bad "X3: no keep line: $OUT"
grep -qx 'impact-learn: expire expired=0 kept=1' <<<"$OUT" && ok || bad "X3: summary: $OUT"

# X4: many passes and one fail → kept.
xstore X4; printf '2026-10-01\ttests/s.sh\t500\t1\n' > "$T/c4"
xrun --counts "$T/c4" --passes 30 --out-dir "$XD"
[ "$RC" = 0 ] && [ -e "$XD/$XS" ] && ok || bad "X4: rc=$RC, a failed suite expired: $OUT"
grep -q '^keep tests/s.sh bin/x.sh (fails=1)$' <<<"$OUT" && ok || bad "X4: no keep line: $OUT"

# X5: no counts line for (date, suite) → kept. Another date's line does not count.
xstore X5; printf '2026-09-30\ttests/s.sh\t500\t0\n2026-10-01\ttests/other.sh\t500\t0\n' > "$T/c5"
xrun --counts "$T/c5" --passes 30 --out-dir "$XD"
[ "$RC" = 0 ] && [ -e "$XD/$XS" ] && ok || bad "X5: rc=$RC, an edge with no ledger rows expired: $OUT"
grep -q '^keep tests/s.sh bin/x.sh (no ledger rows)$' <<<"$OUT" && ok || bad "X5: no keep line: $OUT"

# X6: a hand row never expires.
XD="$T/x-X6"; scratch_rm "$XD"; mkdir -p "$XD"; cp "$T/hand.tsv" "$XD/$XH"
printf '2026-10-01\ttests/s.sh\t500\t0\n' > "$T/c6"
xrun --counts "$T/c6" --passes 30 --out-dir "$XD"
[ "$RC" = 0 ] && [ -e "$XD/$XH" ] && ok || bad "X6: rc=$RC, a hand row expired: $OUT"
grep -q "^keep $XD/$XH (hand)\$" <<<"$OUT" && ok || bad "X6: no keep (hand) line: $OUT"

# X7: a basename in --keep is kept this tick.
xstore X7; printf '2026-10-01\ttests/s.sh\t500\t0\n' > "$T/c7"; printf '%s\n' "$XS" > "$T/k7"
xrun --counts "$T/c7" --passes 30 --out-dir "$XD" --keep "$T/k7"
[ "$RC" = 0 ] && [ -e "$XD/$XS" ] && ok || bad "X7: rc=$RC, a --keep edge expired: $OUT"
grep -q "^keep $XD/$XS (this tick)\$" <<<"$OUT" && ok || bad "X7: no keep (this tick) line: $OUT"

# X8: a counts file that cannot be read whole deletes nothing, rc 1.
for c in missing short dup; do
  xstore "X8-$c"; cp "$X/$LD/$XW" "$XD/"
  before=$(sums "$XD")
  case "$c" in
    missing) cf="$T/nonexistent.counts" ;;
    short) cf="$T/c8-short"; printf '2026-10-01\ttests/w.sh\t30\t0\n2026-10-01\ttests/s.sh\t30\n' > "$cf" ;;
    dup) cf="$T/c8-dup"; printf '2026-10-01\ttests/w.sh\t30\t0\n2026-10-01\ttests/s.sh\t30\t0\n2026-10-01\ttests/s.sh\t30\t0\n' > "$cf" ;;
  esac
  xrun --counts "$cf" --passes 30 --out-dir "$XD"
  [ "$RC" = 1 ] && ok || bad "X8 $c: rc=$RC (want 1): $OUT"
  [ "$(sums "$XD")" = "$before" ] && [ "$(nfrag "$XD")" = 2 ] && ok || bad "X8 $c: a fragment changed"
done

# X9: usage errors are rc 2 and read nothing.
xstore X9; printf '2026-10-01\ttests/s.sh\t30\t0\n' > "$T/c9"
for a in "--passes 0" "--passes x" "--passes -1"; do
  # shellcheck disable=SC2086
  xrun --counts "$T/c9" $a --out-dir "$XD"
  [ "$RC" = 2 ] && [ -e "$XD/$XS" ] && ok || bad "X9 '$a': rc=$RC (want 2): $OUT"
done
xrun --passes 30 --out-dir "$XD"
[ "$RC" = 2 ] && [ -e "$XD/$XS" ] && ok || bad "X9 no --counts: rc=$RC (want 2): $OUT"
xrun --counts "$T/c9" --out-dir "$XD"
[ "$RC" = 2 ] && [ -e "$XD/$XS" ] && ok || bad "X9 no --passes: rc=$RC (want 2): $OUT"

# X10: a * (whole-repo) row expires by the same rule.
XD="$T/x-X10"; scratch_rm "$XD"; mkdir -p "$XD"; cp "$X/$LD/$XW" "$XD/"
printf '2026-10-01\ttests/w.sh\t30\t0\n' > "$T/c10"
xrun --counts "$T/c10" --passes 30 --out-dir "$XD"
[ "$RC" = 0 ] && [ ! -e "$XD/$XW" ] && ok || bad "X10: rc=$RC, the * row did not expire: $OUT"
grep -q "^expire tests/w.sh \* $XD/$XW passes=30\$" <<<"$OUT" && ok || bad "X10: no expire line: $OUT"

# X11: `record` still writes one edge (the verb dispatch did not break it).
X11="$T/x11"; cp -a "$S" "$X11"
"$LEARN" record --event "$T/xev-s.json" --root "$X11" --base main > "$T/x11.out" 2>&1; RC=$?
[ "$RC" = 0 ] && [ "$(nfrag "$X11/$LD")" = 1 ] && grep -q 'written=1 ' "$T/x11.out" && ok \
  || bad "X11: record rc=$RC, $(nfrag "$X11/$LD") fragments: $(cat "$T/x11.out")"
"$LEARN" nosuchverb > /dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "X11: an unknown verb rc=$RC (want 2)"

# ── E: the lane ─────────────────────────────────────────────────────────────
git init -q --bare -b main "$T/origin.git"
git -C "$S" push -q "$T/origin.git" main:main "$H101:refs/pull/101/head" "$H102:refs/pull/102/head" \
  "$H103:refs/pull/103/head"
mkdir -p "$T/repos"
git clone -q --no-local "$T/origin.git" "$T/repos/fixture-repo"
REPO="$T/repos/fixture-repo"
mkdir -p "$T/pristine"
cp -a "$T/origin.git" "$T/pristine/origin.git"
cp -a "$T/repos" "$T/pristine/repos"

H="$T/h"
mkdir -p "$H/bin" "$H/env"
: > "$H/env/global.env"
printf '#!/bin/bash\n[ "${BASH_SOURCE[0]}" = "$0" ] || return 0\nexit 0\n' > "$H/bin/jobs-client.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts"\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/jobs-client.sh" "$H/bin/lane-alert.sh"
scratch_install_closure bin/impact-learn-lane.sh "$H" >/dev/null 2>&1
LANE="$H/bin/impact-learn-lane.sh"

F="$T/f"
cat > "$T/fx.sh" <<SH
F="$F"
is_hub_box() { true; }
local_box_name() { echo hub; }
dqw_events_list() { echo "dqw \$*" >> "\$F/calls"; cat "\$F/events.json"; }
# The jobs transport: the lane's own sr_passes_list builds the path and checks
# the answer's shape; only the HTTP call is a recorder.
_jobs_req() {
  echo "jobs \$1 \$2" >> "\$F/calls"
  [ -e "\$F/passes.fail" ] && return 1
  local since; since=\$(printf '%s' "\$2" | sed -n 's/.*[?&]since=\([0-9-]*\).*/\1/p')
  cat "\$F/passes-\$since.json" 2>/dev/null || echo '{"repo":"x","since":"x","suites":[]}'
}
gh_rest_pr_list() { echo "prlist \$*" >> "\$F/calls"; cat "\$F/open.json" 2>/dev/null || echo '[]'; }
gh_default_auth_for_slug() { echo "auth \$*" >> "\$F/calls"; return 0; }
[ -r "\$HARNESS/bin/lib/stale-parent.sh" ] && . "\$HARNESS/bin/lib/stale-parent.sh"
sp_open_children() { echo "children \$2" >> "\$F/calls"; return 0; }
gh_rest() {
  echo "gh_rest \$1 \$2" >> "\$F/calls"
  local n
  if [ "\$1" = POST ] && [ "\$3" = --input ]; then
    n=\$(grep -c '^gh_rest POST' "\$F/calls"); cp "\$4" "\$F/post-\$n.json"
  fi
  GH_REST_STATUS=201
  echo '{"number":777,"html_url":"https://github.example/example/fixture-repo/pull/777"}'
}
SH

reset() {
  rm -rf "$T/origin.git" "$T/repos" "$H/state" "$H/logs" "$H/locks" "$F" "$T/alerts" "$T/tmp" "$T/seed" "$T/chk"
  cp -a "$T/pristine/origin.git" "$T/origin.git"
  cp -a "$T/pristine/repos" "$T/repos"
  mkdir -p "$F" "$T/tmp"
  printf '[]\n' > "$F/open.json"
  : > "$F/calls"
  printf '{"rows":[],"truncated":false}\n' > "$F/events.json"
}
events() { jq -s '{rows: ., truncated: false}' > "$F/events.json"; }
# seed <day> <head> <suite> [<day> <head> <suite>]... — the real learner writes
# each edge in a clone of origin, dated <day>; one commit lands them on main.
seed() {
  local sd="$T/seed"
  scratch_rm "$sd"; git clone -q "$T/origin.git" "$sd"
  git -C "$sd" fetch -q origin 'refs/pull/*/head:refs/remotes/origin/pull/*'
  while [ $# -ge 3 ]; do
    row 101 "$2" culprit semantic-test "$3" "${1}T10:00:00Z" > "$T/seed-ev.json"
    "$sd/bin/impact-learn.sh" record --event "$T/seed-ev.json" --root "$sd" --base origin/main > "$T/seed.out" 2>&1 \
      || bad "seed: record $1 $3 failed: $(cat "$T/seed.out")"
    grep -q '^edge ' "$T/seed.out" || bad "seed: record $1 $3 wrote no edge: $(cat "$T/seed.out")"
    shift 3
  done
  git -C "$sd" add -A && git -C "$sd" commit -qm seed && git -C "$sd" push -q origin main
}
# passes <since> <suite:passes:fails>... — the route's answer for that since.
passes() {
  local since="$1"; shift
  printf '%s\n' "$@" | jq -R 'split(":") | {suite: .[0], passes: (.[1]|tonumber), fails: (.[2]|tonumber)}' \
    | jq -s --arg s "$since" '{repo: "example/fixture-repo", since: $s, suites: .}' > "$F/passes-$since.json"
}
run() {
  local c="$1"; shift
  env -i PATH="$PATH" HOME="$T" HARNESS="$H" HARNESS_TEST_SANDBOX=1 \
    IMPACT_LEARN_LANE_FIXTURE="$T/fx.sh" IMPACT_LEARN_NOW="$NOW" REPOS_ROOT="$T/repos" \
    HARNESS_REPO="$SLUG" TMPDIR="$T/tmp" "$@" bash "$LANE" > "$T/out" 2> "$T/err"; RC=$?
  OUT=$(cat "$T/out")
  # The expiry-only path makes a worktree too: it must not leak one.
  [ "$(git -C "$REPO" worktree list 2>/dev/null | grep -c .)" = 1 ] && ok || bad "$c: a worktree was left: $(git -C "$REPO" worktree list)"
  [ -z "$(ls "$T/tmp" 2>/dev/null | grep '^impact-learn\.')" ] && ok || bad "$c: a temp dir was left: $(ls "$T/tmp")"
}
posts() { grep -c "^gh_rest POST repos/$SLUG/pulls\$" "$F/calls"; }
reads() { grep '^jobs GET /api/suite-results/passes' "$F/calls"; }
lastlog() { tail -1 "$H/logs/impact-learn.log" 2>/dev/null; }
main_frags() { git -C "$T/origin.git" ls-tree --name-only main -- "$LD/" | grep -c '\.tsv$'; }
has_branch() { git -C "$T/origin.git" rev-parse -q --verify refs/heads/impact-learn/edges >/dev/null 2>&1; }
body() { jq -r .body "$F/post-1.json" 2>/dev/null; }
title() { jq -r .title "$F/post-1.json" 2>/dev/null; }
# sel <tree> — what the tree's own map selects for bin/x.sh.
sel() { printf 'bin/x.sh\n' > "$T/sel.changed"; "$1/bin/test-impact.sh" --root "$1" select --map-only --changed "$T/sel.changed" 2>/dev/null; }

# E1: one tracked edge dated 2026-10-10, 30 passes since 2026-10-11 → one PR deletes it.
reset
seed 2026-10-10 "$H101" tests/s.sh
sel "$T/seed" | grep -qxF tests/s.sh && ok || bad "E1: before the tick, main's map does not select tests/s.sh for bin/x.sh"
E1F=$(git -C "$T/origin.git" ls-tree --name-only main -- "$LD/" | grep '\.tsv$')
passes 2026-10-11 tests/s.sh:30:0
run E1
[ "$RC" = 0 ] && ok || bad "E1: rc=$RC: $OUT $(cat "$T/err")"
[ "$(posts)" = 1 ] && ok || bad "E1: $(posts) POSTs (want 1): $(cat "$F/calls")"
[ "$(reads)" = "jobs GET /api/suite-results/passes?repo=example%2Ffixture-repo&since=2026-10-11" ] && ok \
  || bad "E1: the ledger reads are '$(reads)'"
[ "$(git -C "$T/origin.git" diff --name-status main impact-learn/edges 2>/dev/null)" = "D${TAB}$E1F" ] && ok \
  || bad "E1: the branch diff is '$(git -C "$T/origin.git" diff --name-status main impact-learn/edges 2>/dev/null)'"
lastlog | grep -q ' expired=1 ' && lastlog | grep -q 'opened #777$' && ok || bad "E1: log line is '$(lastlog)'"
[ "$(title)" = "chore(test-impact): expire 1 impact edge(s) after clean passes" ] && ok || bad "E1: title is '$(title)'"
body | grep -qF '`bin/x.sh` → `tests/s.sh` (from example/fixture-repo#101 run 9001, 2026-10-10; passed 30 times)' && ok \
  || bad "E1: the PR body does not list the expired edge: $(body)"
body | grep -q 'Expired: 1\.' && ok || bad "E1: the PR body has no 'Expired: 1.': $(body)"
grep -q 'Expiry is a later slice' <<<"$(body)" && bad "E1: the PR body still says expiry is a later slice" || ok
git clone -q -b impact-learn/edges "$T/origin.git" "$T/chk" 2>/dev/null
grep -qxF tests/s.sh <<<"$(sel "$T/chk")" && bad "E1: the branch's map still selects tests/s.sh for bin/x.sh" || ok
grep -q 'expire ' <<<"$OUT" && ok || bad "E1: stdout has no expire line: $OUT"

# E2: one builder-class fail since the edge's date → kept, no PR.
reset
seed 2026-10-10 "$H101" tests/s.sh
passes 2026-10-11 tests/s.sh:30:1
run E2
[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "E2: rc=$RC, $(posts) POSTs (want 0)"
lastlog | grep -q ' expired=0 ' && lastlog | grep -q ' none$' && ok || bad "E2: log line is '$(lastlog)'"
has_branch && bad "E2: a branch was pushed" || ok

# E3: an old edge reads from the 30-day floor; two old dates share one read.
reset
seed 2026-08-01 "$H101" tests/s.sh 2026-08-02 "$H102" tests/w.sh
passes 2026-09-13 tests/s.sh:5:0
run E3
[ "$RC" = 0 ] && ok || bad "E3: rc=$RC: $(cat "$T/err")"
[ "$(reads)" = "jobs GET /api/suite-results/passes?repo=example%2Ffixture-repo&since=2026-09-13" ] && ok \
  || bad "E3: the ledger reads are '$(reads)' (want one, since 2026-09-13)"
lastlog | grep -q ' expired=0 ' && ok || bad "E3: log line is '$(lastlog)'"

# E4: an edge dated today has no day after it yet: no read, kept.
reset
seed 2026-10-13 "$H101" tests/s.sh
passes 2026-10-14 tests/s.sh:500:0
run E4
[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "E4: rc=$RC, $(posts) POSTs (want 0)"
[ -z "$(reads)" ] && ok || bad "E4: the ledger was read: $(reads)"
lastlog | grep -q ' expired=0 ' && ok || bad "E4: log line is '$(lastlog)'"

# E5: the ledger cannot be read → expired=?, one warn, nothing deleted.
reset
seed 2026-10-10 "$H101" tests/s.sh
passes 2026-10-11 tests/s.sh:30:0
: > "$F/passes.fail"
run E5
[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "E5: rc=$RC, $(posts) POSTs (want 0)"
lastlog | grep -q ' expired=? ' && ok || bad "E5: log line is '$(lastlog)'"
[ "$(grep -c . "$T/alerts" 2>/dev/null)" = 1 ] && grep -q -- '--id impact-learn-ledger ' "$T/alerts" && ok \
  || bad "E5: alerts are '$(cat "$T/alerts" 2>/dev/null)'"
[ "$(main_frags)" = 1 ] && ! has_branch && ok || bad "E5: the fragment left main or a branch was pushed"

# E6: three expiries over IMPACT_LEARN_MAX_EDGES=2 → mass, no push.
reset
seed 2026-10-10 "$H103" tests/s.sh 2026-10-10 "$H102" tests/w.sh
[ "$(main_frags)" = 3 ] && ok || bad "E6: the seed put $(main_frags) fragments on main (want 3)"
passes 2026-10-11 tests/s.sh:30:0 tests/w.sh:40:0
run E6 IMPACT_LEARN_MAX_EDGES=2
[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "E6: rc=$RC, $(posts) POSTs (want 0)"
lastlog | grep -q ' mass$' && ok || bad "E6: log line is '$(lastlog)'"
grep -q -- '--id impact-learn-mass-expire ' "$T/alerts" 2>/dev/null && ok || bad "E6: alerts are '$(cat "$T/alerts" 2>/dev/null)'"
has_branch && bad "E6: a branch was pushed" || ok
run E6-cap3 IMPACT_LEARN_MAX_EDGES=3
[ "$RC" = 0 ] && [ "$(posts)" = 1 ] && lastlog | grep -q ' expired=3 ' && ok \
  || bad "E6: cap 3: rc=$RC, $(posts) POSTs, log '$(lastlog)'"

# E7: an edge this tick's event re-confirms (`exists`) is kept, even at 30 passes.
# bin/new.sh is not on main, so the map drops the tracked row and the learner
# answers `exists` for it.
reset
seed 2026-10-10 "$H102" tests/s.sh
passes 2026-10-11 tests/s.sh:30:0
row 102 "$H102" culprit semantic-test tests/s.sh | events
run E7
[ "$RC" = 0 ] && ok || bad "E7: rc=$RC: $(cat "$T/err")"
grep -q '^example/fixture-repo#102: exists tests/s.sh bin/new.sh ' <<<"$OUT" && ok || bad "E7: the learner did not say exists: $OUT"
[ "$(posts)" = 0 ] && lastlog | grep -q ' expired=0 ' && ok || bad "E7: $(posts) POSTs, log '$(lastlog)'"

# E8: an answer with no .suites array is unreadable → expired=?, nothing deleted.
reset
seed 2026-10-10 "$H101" tests/s.sh
printf '{"error":"fixture"}\n' > "$F/passes-2026-10-11.json"
run E8
[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "E8: rc=$RC, $(posts) POSTs (want 0)"
lastlog | grep -q ' expired=? ' && ok || bad "E8: log line is '$(lastlog)'"
grep -q -- '--id impact-learn-ledger ' "$T/alerts" 2>/dev/null && ok || bad "E8: alerts are '$(cat "$T/alerts" 2>/dev/null)'"
# E8b: a suite whose passes is not a number is unreadable too.
reset
seed 2026-10-10 "$H101" tests/s.sh
printf '{"suites":[{"suite":"tests/s.sh","passes":"30","fails":0}]}\n' > "$F/passes-2026-10-11.json"
run E8b
[ "$(posts)" = 0 ] && lastlog | grep -q ' expired=? ' && ok || bad "E8b: $(posts) POSTs, log '$(lastlog)'"

# E9: IMPACT_LEARN_EXPIRE_PASSES=0 turns expiry off: no read, expired=-.
reset
seed 2026-10-10 "$H101" tests/s.sh
passes 2026-10-11 tests/s.sh:30:0
run E9 IMPACT_LEARN_EXPIRE_PASSES=0
[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "E9: rc=$RC, $(posts) POSTs (want 0)"
[ -z "$(reads)" ] && ok || bad "E9: the ledger was read: $(reads)"
lastlog | grep -q ' expired=- none$' && ok || bad "E9: log line is '$(lastlog)'"
# E9b: the knob read: 31 passes are not enough at IMPACT_LEARN_EXPIRE_PASSES=40.
run E9b IMPACT_LEARN_EXPIRE_PASSES=40
[ "$(posts)" = 0 ] && lastlog | grep -q ' expired=0 ' && ok || bad "E9b: $(posts) POSTs, log '$(lastlog)'"

# E10: one new edge and one expiry in the same tick → one PR with both.
reset
seed 2026-10-10 "$H101" tests/s.sh
passes 2026-10-11 tests/s.sh:30:0
row 101 "$H101" culprit semantic-test tests/w.sh | events
run E10
[ "$RC" = 0 ] && [ "$(posts)" = 1 ] && ok || bad "E10: rc=$RC, $(posts) POSTs (want 1): $(cat "$T/err")"
[ "$(title)" = "chore(test-impact): learn 1 and expire 1 impact edge(s)" ] && ok || bad "E10: title is '$(title)'"
body | grep -qF '`*` → `tests/w.sh` (from example/fixture-repo#101 run 9001, 2026-10-12)' && ok || bad "E10: no new edge in the body: $(body)"
body | grep -qF '`bin/x.sh` → `tests/s.sh` (from example/fixture-repo#101 run 9001, 2026-10-10; passed 30 times)' && ok \
  || bad "E10: no expired edge in the body: $(body)"
lastlog | grep -q ' edges=1 .* expired=1 ' && ok || bad "E10: log line is '$(lastlog)'"
[ "$(git -C "$T/origin.git" diff --name-status main impact-learn/edges 2>/dev/null | cut -c1 | LC_ALL=C sort | tr -d '\n')" = AD ] && ok \
  || bad "E10: the branch diff is '$(git -C "$T/origin.git" diff --name-status main impact-learn/edges 2>/dev/null)'"

# E11: dry run lists the expiry and pushes nothing.
reset
seed 2026-10-10 "$H101" tests/s.sh
passes 2026-10-11 tests/s.sh:30:0
run E11 IMPACT_LEARN_ACT=0
[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && ! has_branch && ok || bad "E11: rc=$RC, $(posts) POSTs"
grep -q '^would-open edges=0 expired=1$' <<<"$OUT" && grep -q '^  expire bin/x.sh -> tests/s.sh (passes=30)$' <<<"$OUT" && ok \
  || bad "E11: stdout is '$OUT'"

# E12: the tree's expire verb deletes a file and then fails → the lane puts
# the file back, warns once, expired=?, and opens no PR.
reset
seed 2026-10-10 "$H101" tests/s.sh
passes 2026-10-11 tests/s.sh:30:0
cat > "$T/seed/bin/impact-learn.sh" <<'VERB'
#!/bin/bash
# fixture: an expire that deletes every fragment, then fails.
[ "${1:-}" = expire ] || exit 2
while [ $# -gt 0 ]; do [ "$1" = --out-dir ] && od="$2"; shift; done
rm -f -- "$od"/*.tsv
echo "fixture: expire failed after the delete" >&2
exit 1
VERB
git -C "$T/seed" commit -qam broken-verb && git -C "$T/seed" push -q origin main
run E12
[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && ! has_branch && ok || bad "E12: rc=$RC, $(posts) POSTs (want 0): $(cat "$T/err")"
lastlog | grep -q ' expired=? none$' && ok || bad "E12: log line is '$(lastlog)'"
grep -q -- '--id impact-learn-expire ' "$T/alerts" 2>/dev/null && ok || bad "E12: alerts are '$(cat "$T/alerts" 2>/dev/null)'"

echo "impact-learned-expire: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
