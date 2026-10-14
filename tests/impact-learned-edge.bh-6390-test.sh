#!/bin/bash
# tests/impact-learned-edge.bh-6390-test.sh — BH-6390: A MERGE-QUEUE EJECTION
# TEACHES THE IMPACT MAP THE EDGE IT MISSED.
#
# A culprit PR fails suite S in a batch, and the map did not select S for the
# culprit's paths. bin/impact-learn.sh record reads that dequeue_events row and
# writes one learned edge per changed path to catalog/test-impact-learned.d/.
# bin/test-impact.sh reads those fragments into the map, so the next select
# for the same path picks S.
#
#   L  the ticket's acceptance cases L1-L5.
#   E  the event gate: only a culprit with a test failure class writes.
#   W  the width cap (--max-paths, default 10).
#   F  docs and plan paths are never learned.
#   U  unresolvable heads, unreadable fragments and usage.
#   R  the reader drops phantom and short rows, and reads directory rows.
#
# HOW IT DRIVES (D2): every case runs the real bin/impact-learn.sh and the real
# bin/test-impact.sh against a scratch git repo with --root. Nothing is sourced
# out of either script.
#
# Self-contained: no network, no secrets, no clock read. The commit dates are
# fixed, so the fixture shas are the same on every run.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1

LEARN="$DIR/bin/impact-learn.sh"
TI="$DIR/bin/test-impact.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v git >/dev/null || { echo "impact-learned-edge: git is required"; exit 2; }
command -v jq >/dev/null || { echo "impact-learned-edge: jq is required"; exit 2; }

export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com
export GIT_AUTHOR_DATE='2026-10-01T00:00:00Z' GIT_COMMITTER_DATE='2026-10-01T00:00:00Z'
LD=catalog/test-impact-learned.d
TAB=$'\t'

# ── the fixture repo ────────────────────────────────────────────────────────
B="$T/base"
mkdir -p "$B/bin/lib" "$B/tests" "$B/catalog" "$B/docs/notes"
printf '#!/bin/bash\necho x\n' > "$B/bin/x.sh"
printf '#!/bin/bash\necho y\n' > "$B/bin/lib/y.sh"
for i in 01 02 03 04 05 06 07 08 09 10 11; do printf '#!/bin/bash\necho p%s\n' "$i" > "$B/bin/p$i.sh"; done
printf 'a note\n' > "$B/docs/notes/a.md"
printf '#!/bin/bash\necho s\n' > "$B/tests/s.sh"
printf '#!/bin/bash\n# test-impact: whole-repo\necho w\n' > "$B/tests/w.sh"
printf '#!/bin/bash\nDIR=$(cd "$(dirname "$0")/.." && pwd)\nbash "$DIR/bin/x.sh"\n' > "$B/tests/x-own.sh"
printf '#!/bin/bash\necho always\n' > "$B/tests/always.sh"
printf 'tests/always.sh\n' > "$B/catalog/test-impact-always.txt"
git -C "$B" init -q -b main
git -C "$B" add -A && git -C "$B" commit -qm A
# culprit <branch> <file>... — one commit past main that edits these files.
culprit() {
  local br="$1" f; shift
  git -C "$B" checkout -q -b "$br" main
  for f in "$@"; do mkdir -p "$B/$(dirname "$f")"; printf 'changed\n' >> "$B/$f"; done
  git -C "$B" add -A && git -C "$B" commit -qm "$br"
  git -C "$B" rev-parse HEAD
}
H_X=$(culprit c-x bin/x.sh)
H_XY=$(culprit c-xy bin/x.sh bin/lib/y.sh)
H_10=$(culprit c-10 bin/p01.sh bin/p02.sh bin/p03.sh bin/p04.sh bin/p05.sh bin/p06.sh bin/p07.sh bin/p08.sh bin/p09.sh bin/p10.sh)
H_11=$(culprit c-11 bin/p01.sh bin/p02.sh bin/p03.sh bin/p04.sh bin/p05.sh bin/p06.sh bin/p07.sh bin/p08.sh bin/p09.sh bin/p10.sh bin/p11.sh)
H_DOC=$(culprit c-doc docs/notes/a.md .harness/specs/BH-1/plan.md)
git -C "$B" checkout -q main

# fresh <name> — an isolated copy of the fixture repo, main checked out.
fresh() { cp -a "$B" "$T/$1"; printf '%s\n' "$T/$1"; }

# event <file> <head> <attribution> <class> <suites> [created_at] — one
# dequeue_events row in the shape dqw_events_list returns in .rows[].
event() {
  jq -n --arg head "$2" --arg a "$3" --arg c "$4" --arg s "$5" --arg at "${6-2026-10-12T10:00:00Z}" \
    '{id: 7, repo: "example/fixture-repo", pr: 101, head: $head, run_id: "9001",
      attribution: $a, class: $c, suites: $s, created_at: $at}' > "$1"
}
# record <repo> <event> [args] — the real learner; stdout+stderr to $OUT, rc to $RC.
record() {
  local r="$1" e="$2"; shift 2
  "$LEARN" record --event "$e" --root "$r" --base main "$@" > "$T/out" 2>&1; RC=$?
  OUT=$(cat "$T/out")
}
nfrag() { find "$1" -maxdepth 1 -name '*.tsv' -type f 2>/dev/null | grep -c .; }
datalines() { cat "$1"/*.tsv 2>/dev/null | grep -v '^#'; }
# sel <repo> <label> [--why] <path>... — select --map-only over a changed list.
sel() {
  local r="$1" l="$2" why=""; shift 2
  [ "${1:-}" = --why ] && { why=--why; shift; }
  printf '%s\n' "$@" > "$T/ch-$l"
  "$TI" --root "$r" select --map-only $why --changed "$T/ch-$l" > "$T/sel-$l" 2> "$T/sel-$l.err"
}

# ── L1 / L2 / L5: learn, read back, replay ──────────────────────────────────
R=$(fresh L)
event "$T/ev-s" "$H_X" culprit semantic-test tests/s.sh
sel "$R" L2pre bin/x.sh
grep -qxF tests/x-own.sh "$T/sel-L2pre" && ok || bad "L2 pre: the fixture map does not select tests/x-own.sh ($(cat "$T/sel-L2pre.err"))"
grep -qxF tests/s.sh "$T/sel-L2pre" && bad "L2 pre: tests/s.sh is selected before any edge was learned" || ok

record "$R" "$T/ev-s"
[ "$RC" = 0 ] && ok || bad "L1: record rc=$RC: $OUT"
[ "$(nfrag "$R/$LD")" = 1 ] && ok || bad "L1: expected 1 fragment, got $(nfrag "$R/$LD")"
[ "$(datalines "$R/$LD")" = "$(printf 'bin/x.sh\ttests/s.sh\texample/fixture-repo#101 run 9001\t2026-10-12')" ] && ok \
  || bad "L1: data line is '$(datalines "$R/$LD")'"
grep -q '^edge tests/s.sh bin/x.sh ' <<<"$OUT" && ok || bad "L1: no 'edge tests/s.sh bin/x.sh' line: $OUT"
grep -q 'written=1 ' <<<"$OUT" && ok || bad "L1: summary is not written=1: $OUT"
F1=$(sed -n 's/^edge tests\/s.sh bin\/x.sh //p' <<<"$OUT")
[ -n "$F1" ] && [ -f "$F1" ] && ok || bad "L1: the edge line names no file that exists ('$F1')"

sel "$R" L2 bin/x.sh
grep -qxF tests/s.sh "$T/sel-L2" && ok || bad "L2: select --changed bin/x.sh does not contain tests/s.sh ($(cat "$T/sel-L2.err"))"

SUM1=$(sha256sum "$R/$LD"/*.tsv 2>/dev/null)
record "$R" "$T/ev-s"
[ "$RC" = 0 ] && ok || bad "L5: replay rc=$RC: $OUT"
grep -q 'written=0 ' <<<"$OUT" && ok || bad "L5: replay summary is not written=0: $OUT"
[ "$(nfrag "$R/$LD")" = 1 ] && ok || bad "L5: replay left $(nfrag "$R/$LD") fragments"
[ "$(sha256sum "$R/$LD"/*.tsv 2>/dev/null)" = "$SUM1" ] && ok || bad "L5: the fragment bytes changed on replay"
# L5b: the replay above is answered by the map (the edge now selects S). Into an
# --out-dir the map does not read, the second run must find the key instead.
R=$(fresh L5b)
record "$R" "$T/ev-s" --out-dir "$T/L5b-out"
SUM1=$(sha256sum "$T/L5b-out"/*.tsv 2>/dev/null)
record "$R" "$T/ev-s" --out-dir "$T/L5b-out"
[ "$RC" = 0 ] && grep -q '^exists tests/s.sh bin/x.sh ' <<<"$OUT" && grep -q 'written=0 exists=1 ' <<<"$OUT" && ok \
  || bad "L5b: replay into --out-dir did not say exists: $OUT"
[ "$(nfrag "$T/L5b-out")" = 1 ] && [ "$(sha256sum "$T/L5b-out"/*.tsv 2>/dev/null)" = "$SUM1" ] && ok \
  || bad "L5b: replay left $(nfrag "$T/L5b-out") fragments or changed their bytes"
[ "$(nfrag "$R/$LD")" = 0 ] && ok || bad "L5b: --out-dir was ignored, the repo store has $(nfrag "$R/$LD") fragments"

# ── L3: an already-selected suite writes nothing ────────────────────────────
R=$(fresh L3)
event "$T/ev-own" "$H_X" culprit semantic-test tests/x-own.sh
record "$R" "$T/ev-own"
[ "$RC" = 0 ] && ok || bad "L3: rc=$RC: $OUT"
grep -q '^selected tests/x-own.sh' <<<"$OUT" && ok || bad "L3: no 'selected tests/x-own.sh' line: $OUT"
grep -q 'written=0 ' <<<"$OUT" && ok || bad "L3: summary is not written=0: $OUT"
[ "$(nfrag "$R/$LD")" = 0 ] && ok || bad "L3: a fragment was written"

# ── L4: a whole-repo suite gets a `*` row, never a path row ─────────────────
R=$(fresh L4)
event "$T/ev-w" "$H_X" culprit semantic-test tests/w.sh
record "$R" "$T/ev-w"
[ "$RC" = 0 ] && ok || bad "L4: rc=$RC: $OUT"
[ "$(nfrag "$R/$LD")" = 1 ] && ok || bad "L4: expected 1 fragment, got $(nfrag "$R/$LD")"
grep -qF "*${TAB}tests/w.sh${TAB}" <<<"$(datalines "$R/$LD")" && ok || bad "L4: no '*' row for tests/w.sh: $(datalines "$R/$LD")"
grep -qF "bin/x.sh${TAB}tests/w.sh" <<<"$(datalines "$R/$LD")" && bad "L4: a path row was written for a whole-repo suite" || ok
sel "$R" L4 --why bin/lib/y.sh
grep -qxF "tests/w.sh${TAB}always${TAB}*" "$T/sel-L4" && ok || bad "L4: tests/w.sh is not an always row ($(cat "$T/sel-L4" "$T/sel-L4.err"))"

# ── E: the event gate ───────────────────────────────────────────────────────
R=$(fresh E1)
event "$T/ev-e1" "$H_XY" culprit rule-break tests/s.sh
record "$R" "$T/ev-e1"
[ "$RC" = 0 ] && [ "$(nfrag "$R/$LD")" = 2 ] && ok || bad "E1: rc=$RC, $(nfrag "$R/$LD") fragments (want 2): $OUT"
# E1b: the suites field splits on commas and whitespace, and dedupes.
R=$(fresh E1b)
event "$T/ev-e1b" "$H_X" culprit semantic-test 'tests/s.sh, tests/s.sh tests/x-own.sh'
record "$R" "$T/ev-e1b"
[ "$RC" = 0 ] && [ "$(nfrag "$R/$LD")" = 1 ] && grep -q 'written=1 exists=0 selected=1 ' <<<"$OUT" && ok \
  || bad "E1b: rc=$RC, $(nfrag "$R/$LD") fragments: $OUT"
for c in "E2 bystander semantic-test tests/s.sh" "E3 culprit flake tests/s.sh" \
         "E3b culprit main-red tests/s.sh" "E4 culprit semantic-test -" \
         "E4b culprit semantic-test share-mirror-clean"; do
  set -- $c
  R=$(fresh "$1")
  event "$T/ev-$1" "$H_X" "$2" "$3" "$4"
  record "$R" "$T/ev-$1"
  [ "$RC" = 0 ] && grep -q '^impact-learn: skip event' <<<"$OUT" && [ "$(nfrag "$R/$LD")" = 0 ] && ok \
    || bad "$1: rc=$RC, $(nfrag "$R/$LD") fragments: $OUT"
done
# E5: an event with no readable date writes nothing and is an error, not a skip.
R=$(fresh E5)
event "$T/ev-e5" "$H_X" culprit semantic-test tests/s.sh ""
record "$R" "$T/ev-e5"
[ "$RC" = 1 ] && [ "$(nfrag "$R/$LD")" = 0 ] && ok || bad "E5: rc=$RC (want 1), $(nfrag "$R/$LD") fragments: $OUT"
# E6: a named suite that is not in the tree is skipped.
R=$(fresh E6)
event "$T/ev-e6" "$H_X" culprit semantic-test tests/ghost.sh
record "$R" "$T/ev-e6"
[ "$RC" = 0 ] && grep -q '^skip tests/ghost.sh (no such suite)' <<<"$OUT" && [ "$(nfrag "$R/$LD")" = 0 ] && ok \
  || bad "E6: rc=$RC: $OUT"

# ── W: the width cap ────────────────────────────────────────────────────────
R=$(fresh W1)
event "$T/ev-w1" "$H_10" culprit semantic-test tests/s.sh
record "$R" "$T/ev-w1"
[ "$RC" = 0 ] && [ "$(nfrag "$R/$LD")" = 10 ] && ok || bad "W1: rc=$RC, $(nfrag "$R/$LD") fragments (want 10): $OUT"
R=$(fresh W2)
event "$T/ev-w2" "$H_11" culprit semantic-test tests/s.sh
record "$R" "$T/ev-w2"
[ "$RC" = 0 ] && [ "$(nfrag "$R/$LD")" = 0 ] && grep -q 'wide: 11 paths > 10' <<<"$OUT" && ok \
  || bad "W2: rc=$RC, $(nfrag "$R/$LD") fragments (want 0): $OUT"
record "$R" "$T/ev-w2" --max-paths 11
[ "$RC" = 0 ] && [ "$(nfrag "$R/$LD")" = 11 ] && ok || bad "W3: rc=$RC, $(nfrag "$R/$LD") fragments (want 11): $OUT"
R=$(fresh W4)
IMPACT_LEARN_MAX_PATHS=11 "$LEARN" record --event "$T/ev-w2" --root "$R" --base main > "$T/out" 2>&1; RC=$?
[ "$RC" = 0 ] && [ "$(nfrag "$R/$LD")" = 11 ] && ok || bad "W4: env knob: rc=$RC, $(nfrag "$R/$LD") fragments (want 11): $(cat "$T/out")"
record "$R" "$T/ev-w2" --max-paths 0
[ "$RC" = 2 ] && ok || bad "W5: --max-paths 0 rc=$RC (want 2)"

# ── F: docs and plan paths are never learned ────────────────────────────────
R=$(fresh F1)
event "$T/ev-f1" "$H_DOC" culprit semantic-test tests/s.sh
record "$R" "$T/ev-f1"
[ "$RC" = 0 ] && grep -q 'no learnable path' <<<"$OUT" && [ "$(nfrag "$R/$LD")" = 0 ] && ok \
  || bad "F1: rc=$RC, $(nfrag "$R/$LD") fragments: $OUT"

# ── U: what cannot be read ──────────────────────────────────────────────────
R=$(fresh U1)
event "$T/ev-u1" 0000000000000000000000000000000000000000 culprit semantic-test tests/s.sh
record "$R" "$T/ev-u1"
[ "$RC" = 3 ] && [ "$(nfrag "$R/$LD")" = 0 ] && ok || bad "U1: rc=$RC (want 3): $OUT"
record "$R" "$T/ev-s" --base no-such-base
[ "$RC" = 3 ] && [ "$(nfrag "$R/$LD")" = 0 ] && ok || bad "U1b: unresolvable base rc=$RC (want 3): $OUT"
R=$(fresh U2)
mkdir -p "$R/$LD"; ln -s "$T/nowhere.tsv" "$R/$LD/bad.tsv"
sel "$R" U2 bin/x.sh
grep -q 'the map could not be built' "$T/sel-U2.err" && grep -qxF tests/s.sh "$T/sel-U2" && ok \
  || bad "U2: select over a dangling fragment did not fall to the corpus ($(cat "$T/sel-U2.err"))"
record "$R" "$T/ev-s"
[ "$RC" = 1 ] && [ "$(nfrag "$R/$LD")" = 0 ] && ok || bad "U2: record rc=$RC (want 1), $(nfrag "$R/$LD") fragments: $OUT"
"$LEARN" record --root "$R" > "$T/out" 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "U3: record with no --event rc=$RC (want 2)"
printf 'not json\n' > "$T/ev-bad"
record "$R" "$T/ev-bad"
[ "$RC" = 1 ] && ok || bad "U4: an unparseable event rc=$RC (want 1): $OUT"

# ── R: the reader ───────────────────────────────────────────────────────────
R=$(fresh R)
"$TI" --root "$R" map > "$T/map-R0" 2> "$T/map-R0.err" || bad "R: the fixture map did not build ($(cat "$T/map-R0.err"))"
mkdir -p "$R/$LD"
printf '# phantom suite\nbin/x.sh\ttests/ghost.sh\tsrc\t2026-10-12\n' > "$R/$LD/r1a.tsv"
printf '# phantom path\nbin/ghost.sh\ttests/s.sh\tsrc\t2026-10-12\n' > "$R/$LD/r1b.tsv"
printf '# one field\nbin/x.sh\n' > "$R/$LD/r3.tsv"
"$TI" --root "$R" map > "$T/map-R" 2> "$T/map-R.err"; RC=$?
[ "$RC" = 0 ] && ok || bad "R3: the map did not build over a one-field row (rc=$RC: $(cat "$T/map-R.err"))"
cmp -s "$T/map-R0" "$T/map-R" && ok || bad "R1/R3: phantom or one-field rows changed the map: $(diff "$T/map-R0" "$T/map-R" | head -5)"
printf '# dir row\nbin/lib/\ttests/s.sh\tsrc\t2026-10-12\n' > "$R/$LD/r2.tsv"
sel "$R" R2 bin/lib/y.sh
grep -qxF tests/s.sh "$T/sel-R2" && ok || bad "R2: a bin/lib/ row did not select tests/s.sh for bin/lib/y.sh ($(cat "$T/sel-R2.err"))"

# ── the committed store: every fragment in this checkout is well formed ─────
for f in "$DIR/catalog/test-impact-learned.d/"*.tsv; do
  [ -e "$f" ] || continue
  grep -v '^#' "$f" | awk -F'\t' 'NF != 4 || $2 !~ /^tests\/(mc\/)?[A-Za-z0-9._-]+\.sh$/ || $4 !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/ { bad = 1 } END { exit bad }' \
    && ok || bad "store: $f has a malformed data line"
done

echo "impact-learned-edge: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
