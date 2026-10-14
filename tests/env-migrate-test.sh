#!/bin/bash
# tests/env-migrate-test.sh — bin/migrate-env-dir.sh (BH-452 / BH-392.2):
# the copy-then-swap migration of $HARNESS/env to /etc/harness/env.
#
# THE PROPERTY: the migration either leaves the box strictly better (files at
# /etc/harness/env, 0700/0600, a working symlink where the old path was) or it
# leaves it exactly as it found it. There is no half-migrated state, and no
# secret content ever reaches stdout/stderr.
#
# MUTATION CHECK (D1), each run once against this suite before it was called done:
#   comment out the `ln -s "$DEST" "$SRC"` in the swap  -> case (a) red
#   comment out the `[ -L "$SRC" ]` foreign-link refusal -> case (c) red
#
# Run from anywhere: tests/env-migrate-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# Release any +i/+a flags the suite puts on fixture files before scratch_cleanup
# tries to rm -rf them.
cleanup() {
  chattr -R -i "$T" 2>/dev/null || true
  chattr -R -a "$T" 2>/dev/null || true
  scratch_cleanup
}
trap cleanup EXIT
DIR=$(cd "$(dirname "$0")/.." && pwd)
MIG="$DIR/bin/migrate-env-dir.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -x "$MIG" ] && ok || bad "bin/migrate-env-dir.sh missing or not executable"

mode() { stat -c %a "$1" 2>/dev/null; }
listing() { find "$1" -printf '%p %m %s\n' 2>/dev/null | sort; }

# ---------------------------------------------------------------------------
# (a) real dir -> copy-then-swap: modes, symlink, byte-identical, no secrets
# ---------------------------------------------------------------------------
mkdir -p "$T/m/env/accounts.d"
printf 'FIXTURE_SECRET_ONE=a\n'   > "$T/m/env/global.env"
printf 'FIXTURE_SECRET_TWO=b\n'   > "$T/m/env/p.env"
printf 'FIXTURE_SECRET_THREE=c\n' > "$T/m/env/accounts.d/a.env"
chmod 644 "$T/m/env"/*.env "$T/m/env/accounts.d/a.env"
chmod 755 "$T/m/env" "$T/m/env/accounts.d"
cp "$T/m/env/global.env" "$T/global.env.orig"

OUT=$("$MIG" --harness "$T/m" --dest "$T/m-etc" 2>"$T/a.err"); RC=$?
ERR=$(cat "$T/a.err")
[ "$RC" -eq 0 ] && ok || bad "(a) rc=$RC want 0 (out=$OUT err=$ERR)"
[ "$(mode "$T/m-etc")" = "700" ] && ok || bad "(a) dest mode $(mode "$T/m-etc") want 700"
[ "$(mode "$T/m-etc/accounts.d")" = "700" ] && ok || bad "(a) accounts.d mode $(mode "$T/m-etc/accounts.d") want 700"
BADMODE=""
for f in "$T/m-etc/global.env" "$T/m-etc/p.env" "$T/m-etc/accounts.d/a.env"; do
  [ -f "$f" ] || { BADMODE="$BADMODE missing:$f"; continue; }
  [ "$(mode "$f")" = "600" ] || BADMODE="$BADMODE $f=$(mode "$f")"
done
[ -z "$BADMODE" ] && ok || bad "(a) dest files not 600:$BADMODE"
[ -L "$T/m/env" ] && ok || bad "(a) $T/m/env is not a symlink after migration"
[ "$(readlink -f "$T/m/env")" = "$(realpath -m "$T/m-etc")" ] && ok || bad "(a) symlink points at $(readlink -f "$T/m/env")"
cmp -s "$T/m/env/global.env" "$T/global.env.orig" && ok || bad "(a) bytes differ through the symlink"
[ ! -e "$T/m/env.pre-migrate" ] && [ -z "$(find "$T/m" -maxdepth 1 -name 'env.pre-migrate*' 2>/dev/null)" ] && ok || bad "(a) pre-migrate backup left on disk"
[ -z "$(find "$T" -maxdepth 1 -name '*.tmp.*' 2>/dev/null)" ] && ok || bad "(a) tmp tree left on disk"
if grep -q 'FIXTURE_SECRET' <<<"$OUT$ERR"; then
  bad "(a) secret content in output: $OUT $ERR"
else ok; fi
grep -q 'migrated' <<<"$OUT" && ok || bad "(a) stdout does not report the migration: $OUT"

# ---------------------------------------------------------------------------
# (b) second run is a no-op: rc 0, tree byte-identical, says already migrated
# ---------------------------------------------------------------------------
BEFORE=$(listing "$T/m-etc")
OUT2=$("$MIG" --harness "$T/m" --dest "$T/m-etc" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok || bad "(b) rc=$RC want 0 ($OUT2)"
[ "$(listing "$T/m-etc")" = "$BEFORE" ] && ok || bad "(b) dest tree changed on the second run"
grep -q 'already migrated' <<<"$OUT2" && ok || bad "(b) no 'already migrated' in output: $OUT2"

# ---------------------------------------------------------------------------
# (c) Fly/pool shape: env is a symlink somewhere else -> refuse, untouched
# ---------------------------------------------------------------------------
mkdir -p "$T/f" "$T/run-env" "$T/f-etc"
ln -s "$T/run-env" "$T/f/env"
OUT3=$("$MIG" --harness "$T/f" --dest "$T/f-etc" 2>&1); RC=$?
[ "$RC" -eq 1 ] && ok || bad "(c) rc=$RC want 1 ($OUT3)"
[ "$(readlink "$T/f/env")" = "$T/run-env" ] && ok || bad "(c) symlink was rewritten to $(readlink "$T/f/env")"
[ -z "$(find "$T/f-etc" -mindepth 1 2>/dev/null)" ] && ok || bad "(c) dest was populated: $(listing "$T/f-etc")"

# ---------------------------------------------------------------------------
# (d) real SRC + non-empty DEST -> refuse, both trees untouched
# ---------------------------------------------------------------------------
mkdir -p "$T/d/env" "$T/d-etc"
printf 'FIXTURE_SECRET_ONE=a\n' > "$T/d/env/global.env"
printf 'keep\n' > "$T/d-etc/other.env"
SRCB=$(listing "$T/d/env"); DSTB=$(listing "$T/d-etc")
OUT4=$("$MIG" --harness "$T/d" --dest "$T/d-etc" 2>&1); RC=$?
[ "$RC" -eq 1 ] && ok || bad "(d) rc=$RC want 1 ($OUT4)"
[ "$(listing "$T/d/env")" = "$SRCB" ] && ok || bad "(d) source tree changed"
[ "$(listing "$T/d-etc")" = "$DSTB" ] && ok || bad "(d) dest tree changed"
[ ! -L "$T/d/env" ] && ok || bad "(d) source was replaced by a symlink"

# ---------------------------------------------------------------------------
# (e) no env dir at all (fresh box) -> create dest 700 + symlink, rc 0
# ---------------------------------------------------------------------------
mkdir -p "$T/n"
OUT5=$("$MIG" --harness "$T/n" --dest "$T/n-etc" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok || bad "(e) rc=$RC want 0 ($OUT5)"
[ -d "$T/n-etc" ] && [ "$(mode "$T/n-etc")" = "700" ] && ok || bad "(e) dest mode $(mode "$T/n-etc") want 700"
[ -L "$T/n/env" ] && [ "$(readlink -f "$T/n/env")" = "$(realpath -m "$T/n-etc")" ] && ok || bad "(e) symlink not created"

# ---------------------------------------------------------------------------
# (f) resolver end-to-end: after migration harness_env_dir prints the new dir
# ---------------------------------------------------------------------------
RES=$(env -u HARNESS_ENV_DIR ETC_HARNESS_ENV="$T/m-etc" bash -c '. "$1/bin/lib/env-path.sh"; harness_env_dir "$2"' _ "$DIR" "$T/m")
[ "$RES" = "$T/m-etc" ] && ok || bad "(f) resolver printed [$RES] want [$T/m-etc]"

# ---------------------------------------------------------------------------
# (g) usage: unknown flag -> rc 2
# ---------------------------------------------------------------------------
OUT7=$("$MIG" --harness "$T/n" --nope 2>&1); RC=$?
[ "$RC" -eq 2 ] && ok || bad "(g) unknown flag rc=$RC want 2 ($OUT7)"
grep -qi 'usage' <<<"$OUT7" && ok || bad "(g) no usage text: $OUT7"

# ---------------------------------------------------------------------------
# (h) pre-existing EMPTY dest is reused: migration proceeds, rc 0
# ---------------------------------------------------------------------------
mkdir -p "$T/h/env" "$T/h-etc"
printf 'FIXTURE_SECRET_TWO=b\n' > "$T/h/env/global.env"
OUT8=$("$MIG" --harness "$T/h" --dest "$T/h-etc" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok || bad "(h) rc=$RC want 0 ($OUT8)"
[ -L "$T/h/env" ] && [ "$(mode "$T/h-etc/global.env")" = "600" ] && ok || bad "(h) empty dest not reused cleanly ($(mode "$T/h-etc/global.env"))"

# ---------------------------------------------------------------------------
# (i) armed fixture (+i files) still migrates cleanly and removes the backup
# ---------------------------------------------------------------------------
mkdir -p "$T/i/env"
printf 'FIXTURE_SECRET_ARMED=z\n' > "$T/i/env/global.env"
chmod 644 "$T/i/env/global.env"
probe=$(mktemp)
if ! chattr +i "$probe" 2>/dev/null; then
  rm -f "$probe"
  echo "SKIP: (i) chattr +i refused here — armed-migration case not run"
else
  chattr -i "$probe" 2>/dev/null || true
  rm -f "$probe"
  chattr +i "$T/i/env/global.env"
  OUT9=$("$MIG" --harness "$T/i" --dest "$T/i-etc" 2>"$T/i.err"); RC=$?
  ERR9=$(cat "$T/i.err")
  [ "$RC" -eq 0 ] && ok || bad "(i) armed fixture rc=$RC want 0 (out=$OUT9 err=$ERR9)"
  [ -L "$T/i/env" ] && ok || bad "(i) armed fixture did not create symlink"
  [ -z "$(find "$T/i" -maxdepth 1 -name 'env.pre-migrate*' 2>/dev/null)" ] && ok || bad "(i) pre-migrate backup left on disk for armed fixture"
  cmp -s "$T/i-etc/global.env" "$T/i/env/global.env" && ok || bad "(i) armed fixture bytes differ through the symlink"
  if grep -q 'FIXTURE_SECRET_ARMED' <<<"$OUT9$ERR9"; then
    bad "(i) secret content in output: $OUT9 $ERR9"
  else ok; fi
fi

echo "env-migrate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
