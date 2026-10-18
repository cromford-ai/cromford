#!/bin/bash
# tests/lanes-registry-compose-once.bh-7251-test.sh — BH-7251 part 3: the
# registry loader (bin/lib/lanes-registry.sh lanes_json_path) composes
# catalog/lanes.json once per input change, and N lanes that start together
# on a changed tree compose it once between them.
#
# Fixture: a scratch root with catalog/lanes.d/{a,b}.json and
# a.knobs.d/X.json, and a stub bin/lanes-build.sh that writes a fixed render
# to --to, appends one line to $T/composes per compose, and sleeps 2 s when
# SLOW=1. A cksum shim counts digests. Each call is a fresh bash that sources
# the real lib, as a lane does.
#
#   C1 two calls, no change -> 1 compose; the 2nd runs cksum once (the stamp
#      key only, no source digest).
#   C2 a 3rd call -> still 1 compose.
#   C3 a content edit -> +1.          C4 an edit with an old mtime -> +1.
#   C5 a file deleted -> +1.          C6 a new knob fragment -> +1.
#   C7 a same-content touch -> +0; once the touch is 3 s old the loader
#      re-stamps, and the call after that is fast again (cksum once).
#   C8 a renderer edit -> +1.
#   C9 lanes_stamp_write after a hand render -> the next call does not compose.
#   C10 8 concurrent calls on a changed tree (SLOW=1) -> exactly +1, all rc 0
#       and all print the path.
#   C11 the herd lock held by an outside flock, a stale render present -> rc 0,
#       the path, +0.
#   C12 the lock held and no render, released after 1 s -> rc 0, +1.
#   C13 no flock on PATH -> composes as before (+1), rc 0.
#   C14 a change outside lanes.d and the renderer -> +0.
#
# Run: bash tests/lanes-registry-compose-once.bh-7251-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
LIB="$DIR/bin/lib/lanes-registry.sh"
R="$T/root"; SHIM="$T/shim"; TD="$T/tmp"
mkdir -p "$R/catalog/lanes.d/a.knobs.d" "$R/bin" "$SHIM" "$TD"
printf '{"id":"a"}\n' > "$R/catalog/lanes.d/a.json"
printf '{"id":"b"}\n' > "$R/catalog/lanes.d/b.json"
printf '{"env":"X"}\n' > "$R/catalog/lanes.d/a.knobs.d/X.json"
printf '{"other":1}\n' > "$R/catalog/other.json"
cat > "$R/bin/lanes-build.sh" <<'SH'
#!/bin/bash
# fixture renderer: --root R --to F
to=""; while [ $# -gt 0 ]; do case "$1" in --to) to="$2"; shift ;; esac; shift; done
echo x >> "$COMPOSES"
[ "${SLOW:-0}" = 1 ] && sleep 2   # determinism: ok the slow renderer IS the fixture (C10 siblings start while one compose runs; any order gives 1 compose)
printf '{"lanes":[]}\n' > "$to"
SH
chmod +x "$R/bin/lanes-build.sh"
printf '#!/bin/bash\necho x >> "%s/cksum-calls"\nexec %s "$@"\n' "$T" "$(command -v cksum)" > "$SHIM/cksum"
chmod +x "$SHIM/cksum"
: > "$T/composes"

# call [PATH] — one fresh process calling the loader; leaves $RC and $OUTP.
call() {
  : > "$T/cksum-calls"
  OUTP=$(env -i PATH="${1:-$SHIM:$PATH}" HOME="$T" TMPDIR="$TD" COMPOSES="$T/composes" SLOW="${SLOW:-0}" \
    bash -c '. "$1" || exit 3; lanes_json_path "$2"' _ "$LIB" "$R" 2>/dev/null)
  RC=$?
}
composes() { grep -c . "$T/composes"; }
cks() { grep -c . "$T/cksum-calls"; }
served() { [ "$RC" = 0 ] && [ "$OUTP" = "$R/catalog/lanes.json" ]; }

# ── C1, C2 ──────────────────────────────────────────────────────────────────
# The fixture is 3 s old before the first call, so the stamp the first call
# writes (hash start - 2 s) is newer than every input.
sleep 3   # determinism: ok wall time must pass: the fast path compares input ctime with the stamp mtime, and a ctime cannot be set back
call; check "C1 the first call composes and serves (rc=$RC, out=$OUTP)" 'served && [ "$(composes)" = 1 ]'
call; check "C1 a second call with no change composes nothing ($(composes) composes)" 'served && [ "$(composes)" = 1 ]'
check "C1 the second call digests no source: cksum ran $(cks) time(s), want 1 (the stamp key)" '[ "$(cks)" = 1 ]'
call; check "C2 a third call: still 1 compose ($(composes))" 'served && [ "$(composes)" = 1 ]'

# ── C3-C6, C8, C14: what must and must not compose ──────────────────────────
printf '{"id":"a","v":2}\n' > "$R/catalog/lanes.d/a.json"
call; check "C3 a content edit composes (+1 -> $(composes))" 'served && [ "$(composes)" = 2 ]'
printf '{"id":"a","v":3}\n' > "$R/catalog/lanes.d/a.json"; touch -d 2001-01-01 "$R/catalog/lanes.d/a.json"
call; check "C4 an edit with an old mtime composes (+1 -> $(composes))" 'served && [ "$(composes)" = 3 ]'
rm -f "$R/catalog/lanes.d/b.json"
call; check "C5 a deleted lane file composes (+1 -> $(composes))" 'served && [ "$(composes)" = 4 ]'
printf '{"env":"Y"}\n' > "$R/catalog/lanes.d/a.knobs.d/Y.json"
call; check "C6 a new knob fragment composes (+1 -> $(composes))" 'served && [ "$(composes)" = 5 ]'
echo '# edited' >> "$R/bin/lanes-build.sh"
call; check "C8 a renderer edit composes (+1 -> $(composes))" 'served && [ "$(composes)" = 6 ]'
printf '{"other":2}\n' > "$R/catalog/other.json"
call; check "C14 a change outside lanes.d composes nothing ($(composes))" 'served && [ "$(composes)" = 6 ]'

# ── C7: a same-content touch ────────────────────────────────────────────────
touch "$R/catalog/lanes.d/a.json"
call; check "C7 a same-content touch composes nothing ($(composes))" 'served && [ "$(composes)" = 6 ]'
sleep 3   # determinism: ok wall time must pass: the touch must be older than the next stamp (hash start - 2 s), and a ctime cannot be set back
call; call
check "C7 once the touch is old, a call is fast again: cksum ran $(cks) time(s), want 1" 'served && [ "$(cks)" = 1 ] && [ "$(composes)" = 6 ]'

# ── C9: lanes_stamp_write after a hand render ───────────────────────────────
printf '{"id":"a","v":9}\n' > "$R/catalog/lanes.d/a.json"
env -i PATH="$PATH" HOME="$T" TMPDIR="$TD" COMPOSES="$T/hand" bash "$R/bin/lanes-build.sh" --root "$R" --to "$R/catalog/lanes.json"
env -i PATH="$PATH" HOME="$T" TMPDIR="$TD" bash -c '. "$1" && lanes_stamp_write "$2"' _ "$LIB" "$R"; SW=$?
call; check "C9 a stamp from lanes_stamp_write is honoured (stamp rc=$SW, $(composes) composes)" 'served && [ "$SW" = 0 ] && [ "$(composes)" = 6 ]'

# ── C10: 8 concurrent calls on a changed tree ───────────────────────────────
printf '{"id":"a","v":10}\n' > "$R/catalog/lanes.d/a.json"
for i in 1 2 3 4 5 6 7 8; do
  ( env -i PATH="$PATH" HOME="$T" TMPDIR="$TD" COMPOSES="$T/composes" SLOW=1 \
      bash -c '. "$1" || exit 3; lanes_json_path "$2"' _ "$LIB" "$R" > "$T/c10-$i.out" 2>/dev/null
    echo $? > "$T/c10-$i.rc" ) &
done
wait
C10OK=0
for i in 1 2 3 4 5 6 7 8; do
  [ "$(cat "$T/c10-$i.rc")" = 0 ] && [ "$(cat "$T/c10-$i.out")" = "$R/catalog/lanes.json" ] && C10OK=$((C10OK + 1))
done
check "C10 8 concurrent calls on a changed tree compose once ($(composes) composes, want 7)" '[ "$(composes)" = 7 ]'
check "C10 all 8 rc 0 and print the path ($C10OK of 8)" '[ "$C10OK" = 8 ]'

# ── C11, C12: the herd lock held from outside ───────────────────────────────
LOCKF=$(ls "$TD"/harness-lanes-*/lock-* 2>/dev/null | head -1)
check "C11 setup: the loader keeps its herd lock beside the stamp (${LOCKF:-none})" '[ -n "$LOCKF" ]'
LOCKF="${LOCKF:-$TD/none}"
printf '{"id":"a","v":11}\n' > "$R/catalog/lanes.d/a.json"
flock "$LOCKF" bash -c "touch '$T/held'; while [ ! -e '$T/release' ]; do sleep 0.1; done" &
HOLDER=$!
i=0; until [ -e "$T/held" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done
call; check "C11 a held lock with a render present serves it at once (rc=$RC, $(composes) composes)" 'served && [ "$(composes)" = 7 ]'
rm -f "$R/catalog/lanes.json"
( sleep 1; touch "$T/release" ) &
call; check "C12 a held lock and no render: the waiter composes once the lock frees (rc=$RC, $(composes) composes)" 'served && [ "$(composes)" = 8 ]'
wait "$HOLDER" 2>/dev/null; rm -f "$T/release" "$T/held"

# ── C13: no flock on PATH ───────────────────────────────────────────────────
NF="$T/noflock"; mkdir -p "$NF"
for c in bash cat ls cksum mktemp mv rm find touch tr dirname sleep env; do
  p=$(command -v "$c") && ln -sf "$p" "$NF/$c"
done
printf '{"id":"a","v":13}\n' > "$R/catalog/lanes.d/a.json"
call "$NF"; check "C13 with no flock the loader composes as before (rc=$RC, $(composes) composes)" 'served && [ "$(composes)" = 9 ]'

echo "lanes-registry-compose-once.bh-7251: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
