#!/bin/bash
# tests/test-impact-why.bh-1524-test.sh — BH-1524: THE SELECTION SAYS WHY, AND
# THE PINS THAT COST FOUR EXTRA ROUNDS STAY SELECTED.
#
# The ticket read four extra review rounds (#1478, #1481, #1496 and the
# gh-rest-lib ceiling raise) as bin/test-impact.sh never selecting a pinned
# suite. The replay says otherwise: on main's map, and on the map each PR's own
# tree built, every one of those diffs selected the suite that went red — and
# the suites went red IN CI, which is the lane working. What had not selected
# them was the BUILDER, whose gate table was hand-picked. So this suite is two
# things, and says which is which:
#
#   R  THE REPLAY, A REGRESSION GUARD. Green on main's selection from the start,
#      stated as such: it exists so a future narrowing of the map cannot drop
#      these five pins without a red here. Each miss is fed as the bin/-side
#      paths of the commit that went red (the tests/ half is the fix, and a
#      changed suite selects itself trivially).
#   W  THE WHY COLUMN (new): `select --why` prints suite, kind, path — self,
#      reads, named, source, closure, always, full — so a reviewer can see the
#      pins ran. T1.32 must read as `reads bin/orphan-reconcile.sh`: it greps
#      the reconciler's text, it does not run it.
#   N  NAMED (new): a suite that names a function DEFINED in a changed script
#      is selected even when it names no path — including a function the diff
#      DELETED, which is exactly when a caller-count pin goes red.
#   M  --map-only (new): the builder gate's question. Infra and unknown-reach
#      still answer FULL for CI; the gate asks for what the map can say, and
#      the answer says CI keeps the corpus.
#
# Self-contained: no network, no secrets, no clock read.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1

TI="$DIR/bin/test-impact.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v git >/dev/null || { echo "test-impact-why: git is required for this suite"; exit 2; }
[ -x "$TI" ] || { echo "FAIL: bin/test-impact.sh is missing"; echo "test-impact-why: 0 passed, 1 failed"; exit 1; }

# ── R. the replay, against the REAL tree ────────────────────────────────────
MAP="$T/map.tsv"
"$TI" map --out "$MAP" 2>"$T/map.err"
[ -s "$MAP" ] && ok || bad "R: the map came back empty ($(head -2 "$T/map.err"))"

# sel_paths <label> <path>... — the REAL selector over a changed-path list.
sel_paths() {
  local label="$1"; shift
  printf '%s\n' "$@" > "$T/ch-$label"
  "$TI" --map "$MAP" select --changed "$T/ch-$label" > "$T/sel-$label" 2>"$T/why-$label.err"
  "$TI" --map "$MAP" select --changed "$T/ch-$label" --why > "$T/why-$label" 2>>"$T/why-$label.err"
}
selects() { # <label> <suite> <what the miss was>
  grep -qxF "$2" "$T/sel-$1" && ok || bad "R/$1: $2 was not selected — $3 ($(tail -1 "$T/why-$1.err"))"
}

# #1478 (66a9bc81) — T1.32 in launch-fastpath-test.sh carries a verbatim copy
# of orphan-reconcile's hold classifier and diffs the two.
sel_paths 1478 bin/fleet-status-push.sh bin/fly-pool.sh bin/lib/hold.sh \
  bin/orphan-reconcile.sh console-ui/src/screens/Fleet.js
selects 1478 tests/launch-fastpath-test.sh "T1.32's copy of the reconciler's regex block"
# #1481 (d20488b9) — tests/mc/expected-map.tsv's function placement, and the
# br_close_pr caller pin in br-contested.
sel_paths 1481 bin/blocked-resolver.sh bin/lib/hold.sh bin/lib/mc/rebase.sh
selects 1481 tests/mc-split-layout-test.sh "expected-map.tsv's placement of mc_hold_keeps_pr"
selects 1481 tests/br-contested-test.sh "br_close_pr's enumerated callers"
# #1496 (6ba66f2b), bin/ side only: its tests/lib/fixture-harness.sh change is
# infra and ran the whole corpus, which would make this case prove nothing.
sel_paths 1496 bin/batch-resolve.sh bin/fly-pool.sh bin/hotfix-seen.sh \
  bin/lib/gh-rest-var.sh bin/lib/gh-rest.sh bin/lib/mc/classify.sh bin/lib/mc/queue.sh \
  bin/lib/mc/rebase.sh bin/lib/mc/train.sh bin/lib/resume-dead.sh \
  bin/lib/triage-hotfix-lib.sh bin/lib/triage-shards-lib.sh bin/merge-conductor.sh \
  bin/review-autopilot.sh bin/triage-gate.sh bin/verification-map-retrofit.sh
selects 1496 tests/priority-rank-test.sh "A10 latching on bin/lib/triage-hotfix-lib.sh"
selects 1496 tests/gh-rest-lib-test.sh "the contract-shape check over bin/lib/gh-rest.sh"
# The pinned file ALONE is enough, one case per pin — a selection that only
# found these through a neighbour in the same diff would be luck.
sel_paths one-orc bin/orphan-reconcile.sh
selects one-orc tests/launch-fastpath-test.sh "bin/orphan-reconcile.sh alone"
sel_paths one-mc bin/lib/mc/rebase.sh
selects one-mc tests/mc-split-layout-test.sh "bin/lib/mc/rebase.sh alone"
sel_paths one-br bin/blocked-resolver.sh
selects one-br tests/br-contested-test.sh "bin/blocked-resolver.sh alone"
sel_paths one-thl bin/lib/triage-hotfix-lib.sh
selects one-thl tests/priority-rank-test.sh "bin/lib/triage-hotfix-lib.sh alone"
sel_paths one-ghr bin/lib/gh-rest.sh
selects one-ghr tests/gh-rest-lib-test.sh "bin/lib/gh-rest.sh alone"

# ── W. the why column ──────────────────────────────────────────────────────
# T1.32 READS the reconciler: `sed -n … "$DIR/bin/orphan-reconcile.sh"`.
grep -qxF "$(printf 'tests/launch-fastpath-test.sh\treads\tbin/orphan-reconcile.sh')" "$T/why-one-orc" \
  && ok || bad "W: T1.32 reads bin/orphan-reconcile.sh as data, and --why must say reads (got: $(grep launch-fastpath "$T/why-one-orc" | tr '\t' ' ' | head -3))"
# Every --why row is three tab-separated fields with a known kind — a reviewer
# reads the column, so an unknown word there is a claim nobody defined.
BADROW=$(awk -F'\t' 'NF != 3 || $2 !~ /^(self|reads|named|source|learned|closure|always|full)$/' "$T"/why-1478 "$T"/why-1481 "$T"/why-1496)
[ -z "$BADROW" ] && ok || bad "W: malformed --why rows: $(head -3 <<<"$BADROW")"
# The suites --why names are exactly the suites plain select names.
cut -f1 "$T/why-1481" | LC_ALL=C sort -u > "$T/why-1481.suites"
cmp -s "$T/why-1481.suites" "$T/sel-1481" && ok \
  || bad "W: --why and plain select disagree on WHICH suites ($(diff "$T/why-1481.suites" "$T/sel-1481" | head -4 | tr '\n' ' '))"
# Plain select is unchanged: bare suite paths, no tabs. CI's --only-file reads it.
grep -q "$(printf '\t')" "$T/sel-1481" && bad "W: plain select must print bare suite paths (CI's --only-file reads it)" || ok
# An always-run suite says so. TEST-CHANGE BH-8098: this pinned
# gh-rest-lib-test, whose only always hit was `find "$D/fx"` on a stub dir;
# slice C1 of #8050 took it out of the set. tests/test-impact-test.sh runs
# `git -C "$DIR" ls-files` on the checkout and stays always.
grep -qF "$(printf 'tests/test-impact-test.sh\talways\t')" "$T/why-one-ghr" \
  && ok || bad "W: test-impact-test.sh is always-run and --why must say always"
# gh-rest-lib-test is still picked for gh-rest.sh, now for a map reason.
grep -qE "^tests/gh-rest-lib-test[.]sh	(self|reads|named|source|closure)	" "$T/why-one-ghr" \
  && ok || bad "W: gh-rest-lib-test.sh must be picked for bin/lib/gh-rest.sh by a map row (got: $(grep gh-rest-lib-test "$T/why-one-ghr" | tr '\t' ' ' | head -3))"

# ── a scratch repository for the cases the real tree cannot pose ────────────
R="$T/repo"
mkdir -p "$R/bin/lib" "$R/tests" "$R/docs"
cat > "$R/bin/lib/widget.sh" <<'SH'
#!/bin/bash
widget_count_open() { echo 3; }
widget_close_all() { echo closed; }
ok() { :; }
SH
cat > "$R/bin/tool.sh" <<'SH'
#!/bin/bash
. "$(dirname "$0")/lib/widget.sh"
widget_count_open
SH
# pin-test: names a function of widget.sh and NO path. The caller-count shape.
cat > "$R/tests/pin-test.sh" <<'SH'
#!/bin/bash
n=$(grep -c 'widget_close_all' /dev/null)
echo "pin: 1 passed, 0 failed"
SH
# runs-test: runs bin/tool.sh, which sources widget.sh — the closure.
cat > "$R/tests/runs-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
bash "$DIR/bin/tool.sh" >/dev/null
echo "runs: 1 passed, 0 failed"
SH
# ok-test: says `ok` a lot — a short name that must NOT count as naming widget.sh.
cat > "$R/tests/ok-test.sh" <<'SH'
#!/bin/bash
ok() { :; }; ok; ok
echo "ok: 1 passed, 0 failed"
SH
# wide-test: the always-run floor.
cat > "$R/tests/wide-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
git -C "$DIR" ls-files | wc -l
echo "wide: 1 passed, 0 failed"
SH
echo note > "$R/docs/n.md"
gitc() { git -C "$R" -c user.email=t@example.com -c user.name=t "$@"; }
gitc init -q; gitc add -A; gitc commit -qm base
BASE=$(git -C "$R" rev-parse HEAD)
why() { "$TI" --root "$R" select "$BASE..HEAD" --why 2>"$T/reason"; }
row() { printf '%s\t%s\t%s' "$1" "$2" "$3"; }

# ── N. named: a function defined in the changed script ──────────────────────
echo '# touched' >> "$R/bin/lib/widget.sh"; gitc commit -qam touch
GOT=$(why)
grep -qxF "$(row tests/pin-test.sh named 'bin/lib/widget.sh#widget_close_all')" <<<"$GOT" \
  && ok || bad "N: pin-test names widget_close_all (defined in bin/lib/widget.sh) and must be selected as named (got: $(printf '%s' "$GOT" | tr '\t\n' ' |'))"
grep -qxF "$(row tests/runs-test.sh closure bin/lib/widget.sh)" <<<"$GOT" \
  && ok || bad "N: runs-test reaches widget.sh only through bin/tool.sh's source line — kind closure (got: $(printf '%s' "$GOT" | tr '\t\n' ' |'))"
grep -qxF "$(row tests/wide-test.sh always "*")" <<<"$GOT" \
  && ok || bad "N: the always-run floor must say always"
grep -q '^tests/ok-test.sh' <<<"$(printf '%s\n' "$GOT")" \
  && bad "N: a two-letter function (ok) must not count as a suite naming widget.sh — precision" || ok

# A DELETED function still selects its callers: the base defines it, the head
# does not, and a suite that counts its callers is exactly the one to go red.
gitc reset -q --hard "$BASE"
sed -i.bak '/widget_close_all/d' "$R/bin/lib/widget.sh" && rm -f "$R/bin/lib/widget.sh.bak"
gitc commit -qam "drop widget_close_all"
GOT=$(why)
grep -qxF "$(row tests/pin-test.sh named 'bin/lib/widget.sh#widget_close_all')" <<<"$GOT" \
  && ok || bad "N: a function the diff DELETED must still select the suites naming it (got: $(printf '%s' "$GOT" | tr '\t\n' ' |'))"

# A changed suite selects itself, and says self.
gitc reset -q --hard "$BASE"
echo '# edit' >> "$R/tests/pin-test.sh"; gitc commit -qam "edit suite"
why | grep -qxF "$(row tests/pin-test.sh self tests/pin-test.sh)" \
  && ok || bad "W: a changed suite must select itself as self"

# ── M. --map-only: the builder gate's view of an infra change ──────────────
gitc reset -q --hard "$BASE"
mkdir -p "$R/tests/lib"; echo '# lib' > "$R/tests/lib/h.sh"
echo '# touched' >> "$R/bin/lib/widget.sh"; gitc add -A; gitc commit -qm "infra + widget"
FULLN=$("$TI" --root "$R" select "$BASE..HEAD" 2>"$T/reason" | grep -c .)
[ "$FULLN" -eq 4 ] && grep -q 'full: infra change (tests/lib/h.sh)' "$T/reason" \
  && ok || bad "M: without --map-only an infra change is still the whole corpus (got $FULLN, $(cat "$T/reason"))"
GOT=$("$TI" --root "$R" select "$BASE..HEAD" --map-only 2>"$T/reason")
grep -qxF tests/pin-test.sh <<<"$GOT" && ! grep -qxF tests/ok-test.sh <<<"$GOT" \
  && ok || bad "M: --map-only must answer the map's picks, not the corpus (got: $(printf '%s' "$GOT" | tr '\n' ' '))"
grep -q 'map-only' "$T/reason" && grep -q 'infra change (tests/lib/h.sh)' "$T/reason" \
  && ok || bad "M: --map-only must still NAME the full-corpus reason CI will act on (got: $(cat "$T/reason"))"

# ── flags: refused where they mean nothing ─────────────────────────────────
"$TI" --root "$R" map --why >/dev/null 2>&1; [ $? -eq 2 ] && ok || bad "flags: map --why must be rc 2"
"$TI" --root "$R" select --changed "$T/nope" >/dev/null 2>"$T/reason"
grep -q 'impact: 4 of 4' "$T/reason" && ok || bad "flags: an unreadable --changed list must fall to the whole corpus (got: $(cat "$T/reason"))"

echo "test-impact-why: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
