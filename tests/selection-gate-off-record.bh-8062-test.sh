#!/bin/bash
# tests/selection-gate-off-record.bh-8062-test.sh — BH-8062 fix round (PR
# #8294 change requests): with the knob SELECTION_GATE at 0 the build and a
# resolver fix round write an rc=off selection-gate record, and the lead review
# accepts it, so a cromford builder PR is not refused `missing` in a loop.
#
#   O1  sg_block, a checkout with an executable bin/selection-gate.sh, knob 0:
#       rc 0, the gate never runs, $BUILD/gate.txt is the rc=off record of
#       HEAD, SG_MARKER is `<!-- selection-gate: head=<HEAD> suites=0 rc=off -->`,
#       no RESULT
#   O2  no bin/selection-gate.sh: no marker, no gate.txt; a non-executable one:
#       no marker; SELECTION_GATE=off (not a number): fallback 1, the gate runs;
#       SELECTION_GATE=00: not 0, the gate runs; a checkout with no HEAD: rc 0,
#       no marker
#   O3  knob 0: 0 ALERTS.log lines and no state/selection-gate/cnr-* marker
#   O4  round trip: br_sg_verify at knob 0 writes <od>/gate.txt rc off for the
#       worktree HEAD and prints `SELECTION_GATE_EXIT: skipped (SELECTION_GATE=0)`;
#       br_sg_after_push PATCHes a body that holds that record; lr_gate_record
#       on the body answers `ok 0 off`. O4b: a failed GET names its real HTTP
#       code (gh_rest_var keeps GH_REST_STATUS).
#   O5  LR_GR_RE through lr_gate_record: accept rc 0, could-not-run,
#       no-selection, off, and an rc=off record of a moved head with the same
#       patch (rebound); refuse OFF, a trailing space, offline, rc=1, another
#       head with a different patch, two markers that differ
#   O6  sg_marker_replace keeps a caller's `lines` array unchanged
#
# Scratch git repos, stub gate scripts and a stub gh_rest. No network.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/selection-gate-off-record.bh-8062-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
unset SELECTION_GATE SELECTION_GATE_TIMEOUT_S SELECTION_GATE_P SELECTION_GATE_FIX_ROUNDS
LIB="$DIR/bin/lib/selection-gate.sh"
FRAG="$DIR/bin/blocked-resolver.d/bh-8062-selection-gate.sh"
GR="$DIR/bin/lib/lead-review/gate-record.sh"
for f in "$LIB" "$FRAG" "$GR"; do [ -r "$f" ] || { echo "FAIL: setup: $f is missing"; exit 1; }; done

# The harness root: the libs' closures and a recording alert-line.sh.
HH="$T/h"; mkdir -p "$HH/bin" "$HH/logs"
for f in bin/lib/selection-gate.sh bin/lib/lead-review/gate-record.sh bin/lib/patch-same.sh bin/lib/gh-rest-var.sh; do
  scratch_install_closure "$f" "$HH" >/dev/null || { echo "FAIL: setup: scratch_install_closure $f"; exit 1; }
done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/logs/ALERTS.log"\n' "$HH" > "$HH/bin/alert-line.sh"; chmod +x "$HH/bin/alert-line.sh"

gc() { git -C "$1" -c user.email=t@example.com -c user.name=t "${@:2}"; }
# A checkout with a stub gate that records each run and writes a green gate.txt.
CO="$T/co"; mkdir -p "$CO/bin"
cat > "$CO/bin/selection-gate.sh" <<'SH'
#!/bin/bash
echo ran >> "$STUB_LOG"
out=""; while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; shift; done
mkdir -p "$out"
printf 'head: %s\nbase: -\nsuites: 5\nrc: 0\nred: -\nnoted: -\nmode: batch\nwhy: -\nquarantine: env\n' "$(git rev-parse HEAD)" > "$out/gate.txt"
SH
chmod +x "$CO/bin/selection-gate.sh"
git -C "$CO" init -q -b main; gc "$CO" add -A; gc "$CO" commit -qm base
HEADSHA=$(git -C "$CO" rev-parse HEAD)
NOGATE="$T/nogate"; mkdir -p "$NOGATE"; git -C "$NOGATE" init -q -b main; gc "$NOGATE" commit -q --allow-empty -m base
NOEXEC="$T/noexec"; mkdir -p "$NOEXEC/bin"; printf '#!/bin/bash\n' > "$NOEXEC/bin/selection-gate.sh"
git -C "$NOEXEC" init -q -b main; gc "$NOEXEC" add -A; gc "$NOEXEC" commit -qm base
NOHEAD="$T/nohead"; mkdir -p "$NOHEAD/bin"; cp "$CO/bin/selection-gate.sh" "$NOHEAD/bin/"; git -C "$NOHEAD" init -q -b main

# blk <case> <checkout> [VAR=value …] — sg_block in a subshell from <checkout>.
#   Sinks under $T/c/<case>: rc, marker, stub (gate runs), build/.
blk() {
  local c="$1" co="$2"; shift 2
  local C="$T/c/$c"; mkdir -p "$C/build"; : > "$C/stub"
  ( cd "$co" || exit 99
    env HARNESS="$HH" STUB_LOG="$C/stub" BUILD="$C/build" PROJECT=demo-os KEY=BH-7 TICKET=7 BASE=main \
      BUILDER_DIRECT_ON=0 JOBS_URL='' C="$C" "$@" bash -c '
      STAMP() { echo 2026-10-25T00:00:00Z; }
      RESULT() { printf "%s\n" "$*" > "$BUILD/RESULT"; }
      . "$1" || exit 98
      sg_block; echo "$?" > "$C/rc"; printf "%s" "$SG_MARKER" > "$C/marker"' _ "$LIB"
  ) > "$T/c/$c.out" 2>&1
}
cat_() { cat "$T/c/$1/$2" 2>/dev/null; }

# ── O1: knob 0 with a gate in the checkout ───────────────────────────────────
blk o1 "$CO" SELECTION_GATE=0
[ "$(cat_ o1 rc)" = 0 ] && ok || bad "O1 rc 0 (got '$(cat_ o1 rc)'; $(cat "$T/c/o1.out"))"
[ ! -s "$T/c/o1/stub" ] && ok || bad "O1 the gate script never runs"
[ "$(cat_ o1 marker)" = "<!-- selection-gate: head=$HEADSHA suites=0 rc=off -->" ] && ok || bad "O1 SG_MARKER (got '$(cat_ o1 marker)')"
G="$T/c/o1/build/gate.txt"
grep -qx "head: $HEADSHA" "$G" 2>/dev/null && grep -qx 'suites: 0' "$G" && grep -qx 'rc: off' "$G" && grep -qx 'why: SELECTION_GATE=0' "$G" \
  && [ "$(wc -l < "$G")" = 9 ] && ok || bad "O1 \$BUILD/gate.txt is the 9-field rc=off record ($(cat "$G" 2>/dev/null))"
[ ! -e "$T/c/o1/build/RESULT" ] && ok || bad "O1 no RESULT"
grep -q 'SELECTION-GATE off (SELECTION_GATE=0), record rc=off' "$T/c/o1/build/pipeline.log" 2>/dev/null && ok || bad "O1 one log line"

# ── O2: the near misses ──────────────────────────────────────────────────────
blk o2a "$NOGATE" SELECTION_GATE=0
[ "$(cat_ o2a rc)" = 0 ] && [ -z "$(cat_ o2a marker)" ] && [ ! -e "$T/c/o2a/build/gate.txt" ] && ok || bad "O2 no gate script: no marker, no gate.txt"
blk o2b "$NOEXEC" SELECTION_GATE=0
[ "$(cat_ o2b rc)" = 0 ] && [ -z "$(cat_ o2b marker)" ] && ok || bad "O2 a non-executable gate script: no marker (got '$(cat_ o2b marker)')"
blk o2c "$CO" SELECTION_GATE=off
[ "$(grep -c ran "$T/c/o2c/stub")" = 1 ] && [ "$(cat_ o2c marker)" = "<!-- selection-gate: head=$HEADSHA suites=5 rc=0 -->" ] && ok \
  || bad "O2 SELECTION_GATE=off falls back to 1: the gate runs (runs $(grep -c ran "$T/c/o2c/stub"), marker '$(cat_ o2c marker)')"
blk o2d "$CO" SELECTION_GATE=00
[ "$(grep -c ran "$T/c/o2d/stub")" = 1 ] && ok || bad "O2 SELECTION_GATE=00 is not 0: the gate runs"
blk o2e "$NOHEAD" SELECTION_GATE=0
[ "$(cat_ o2e rc)" = 0 ] && [ -z "$(cat_ o2e marker)" ] && [ ! -e "$T/c/o2e/build/gate.txt" ] && ok || bad "O2 no HEAD: rc 0, no marker ($(cat "$T/c/o2e.out"))"

# ── O3: no alert at knob 0 ───────────────────────────────────────────────────
[ ! -s "$HH/logs/ALERTS.log" ] && ok || bad "O3 knob 0 wrote an alert ($(cat "$HH/logs/ALERTS.log"))"
[ -z "$(find "$HH/state/selection-gate" -name 'cnr-*' 2>/dev/null)" ] && ok || bad "O3 knob 0 left a cnr day marker"

# ── O4: the fix-round round trip at knob 0 ───────────────────────────────────
# RT: a repo whose base carries bin/selection-gate.sh, so lr_gate_record checks.
RT="$T/rt"; mkdir -p "$RT/bin"; cp "$CO/bin/selection-gate.sh" "$RT/bin/"
git -C "$RT" init -q -b main; gc "$RT" add -A; gc "$RT" commit -qm base; git -C "$RT" update-ref refs/remotes/origin/main HEAD
RTH=$(git -C "$RT" rev-parse HEAD)
OLD=1111111111111111111111111111111111111111
printf 'The change.\n<!-- selection-gate: head=%s suites=5 rc=0 -->\nTail.' "$OLD" > "$T/o4.body0"
( export H="$HH" STUB_LOG="$T/o4.stub" SELECTION_GATE=0 C="$T/o4" GETFAIL=""
  say() { printf '%s\n' "$*" >> "$C.say"; }
  . "$FRAG" || exit 9
  br_sg_verify "$RT" origin/main "$T/o4.sg" demo > "$C.verify"
  gh_rest() {
    printf '%s %s\n' "$1" "$2" >> "$C.calls"
    case "$1" in
      GET) jq -n --rawfile b "$C.body0" '{number:9, body:$b}' ;;
      PATCH) local a; for a in "$@"; do case "$a" in body=@*) cp "${a#body=@}" "$C.patched" ;; esac; done ;;
    esac
  }
  br_sg_after_push example-org/demo https://github.com/example-org/demo/pull/9 "$RTH" "$T/o4.sg" ) > "$T/o4.out" 2>&1
grep -qx 'SELECTION_GATE_EXIT: skipped (SELECTION_GATE=0)' "$T/o4.verify" 2>/dev/null && ok || bad "O4 the verify line ($(cat "$T/o4.verify" 2>/dev/null))"
[ ! -s "$T/o4.stub" ] && ok || bad "O4 the gate script never runs"
grep -qx "head: $RTH" "$T/o4.sg/gate.txt" 2>/dev/null && grep -qx 'rc: off' "$T/o4.sg/gate.txt" && ok || bad "O4 <od>/gate.txt is the rc=off record of the worktree head ($(cat "$T/o4.sg/gate.txt" 2>/dev/null))"
grep -qxF "<!-- selection-gate: head=$RTH suites=0 rc=off -->" "$T/o4.patched" 2>/dev/null && ok || bad "O4 the PATCHed body holds the rc=off record ($(cat "$T/o4.patched" 2>/dev/null); $(cat "$T/o4.out"))"
got=$( HARNESS="$HH"; . "$GR"; lr_gate_record "$(cat "$T/o4.patched" 2>/dev/null)" "$RTH" ticket/bh-7 block "$RT" main )
[ "$got" = "ok 0 off" ] && ok || bad "O4 lr_gate_record on the refreshed body (got '$got')"
# O4b: a failed GET keeps its status out of the subshell.
mkdir -p "$T/o4b.sg"
printf 'head: %s\nbase: -\nsuites: 0\nrc: off\nred: -\nnoted: -\nmode: -\nwhy: SELECTION_GATE=0\nquarantine: -\n' "$RTH" > "$T/o4b.sg/gate.txt"
( export H="$HH" C="$T/o4b"
  say() { printf '%s\n' "$*" >> "$C.say"; }
  gh_rest() { printf '%s\n' "$1" >> "$C.calls"; [ "$1" = GET ] && { GH_REST_STATUS=502; return 75; }; return 0; }
  . "$FRAG" || exit 9
  br_sg_after_push example-org/demo https://github.com/example-org/demo/pull/9 "$RTH" "$T/o4b.sg" ) > "$T/o4b.out" 2>&1
grep -q 'could not be read (HTTP 502)' "$T/o4b.say" 2>/dev/null && ! grep -q '^PATCH' "$T/o4b.calls" && ok || bad "O4b the say line names HTTP 502, no PATCH ($(cat "$T/o4b.say" 2>/dev/null))"

# ── O5: what the lead review accepts ─────────────────────────────────────────
# LR: base M0 (carries the gate), H on top, main moves to M1, S_MERGE = a clean
# merge of M1 into H (same patch), S_CODE = H + a code commit (another patch).
LR="$T/lr"; mkdir -p "$LR/bin"; cp "$CO/bin/selection-gate.sh" "$LR/bin/"
git -C "$LR" init -q -b main; gc "$LR" add -A; gc "$LR" commit -qm M0
git -C "$LR" checkout -q -b ticket/bh-7; echo a > "$LR/a.txt"; gc "$LR" add -A; gc "$LR" commit -qm H
LH=$(git -C "$LR" rev-parse HEAD)
git -C "$LR" checkout -q main; echo m > "$LR/m.txt"; gc "$LR" add -A; gc "$LR" commit -qm M1
git -C "$LR" update-ref refs/remotes/origin/main HEAD
git -C "$LR" checkout -q ticket/bh-7; gc "$LR" merge -q --no-edit main; S_MERGE=$(git -C "$LR" rev-parse HEAD)
git -C "$LR" checkout -q -b code "$LH"; echo b > "$LR/b.txt"; gc "$LR" add -A; gc "$LR" commit -qm code; S_CODE=$(git -C "$LR" rev-parse HEAD)
mk() { printf 'Body.\n<!-- selection-gate: head=%s suites=%s rc=%s -->\n' "$1" "$2" "$3"; }
lrg() { ( HARNESS="$HH"; . "$GR"; lr_gate_record "$1" "$2" ticket/bh-7 block "$LR" main ); }
row() {   # row <id> <want> <body> <sha>
  local got; got=$(lrg "$3" "$4")
  [ "$got" = "$2" ] && ok || bad "O5 $1: want '$2', got '$got'"
}
row accept-0   "ok 3 0"             "$(mk "$LH" 3 0)" "$LH"
row accept-cnr "ok 3 could-not-run" "$(mk "$LH" 3 could-not-run)" "$LH"
row accept-nos "ok 3 no-selection"  "$(mk "$LH" 3 no-selection)" "$LH"
row accept-off "ok 0 off"           "$(mk "$LH" 0 off)" "$LH"
row rebound-off "ok 0 off rebound=main-merge" "$(mk "$LH" 0 off)" "$S_MERGE"
row refuse-OFF  "refuse malformed"  "$(mk "$LH" 0 OFF)" "$LH"
row refuse-space "refuse malformed" "$(printf 'B\n<!-- selection-gate: head=%s suites=0 rc=off  -->\n' "$LH")" "$LH"
row refuse-offline "refuse malformed" "$(mk "$LH" 0 offline)" "$LH"
row refuse-rc1  "refuse malformed"  "$(mk "$LH" 3 1)" "$LH"
row refuse-other "refuse head=$LH"  "$(mk "$LH" 0 off)" "$S_CODE"
row refuse-two  "refuse malformed"  "$(mk "$LH" 3 0; mk "$LH" 0 off)" "$LH"

# ── O6: sg_marker_replace does not touch a caller's `lines` ──────────────────
got=$( . "$LIB"; lines=(keep); sg_marker_replace $'a\nb' '<!-- selection-gate: x -->' >/dev/null; printf '%s|%s' "${#lines[@]}" "${lines[0]}" )
[ "$got" = "1|keep" ] && ok || bad "O6 a caller's lines array changed (got '$got')"

echo "selection-gate-off-record.bh-8062: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
