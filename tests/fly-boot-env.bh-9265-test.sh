#!/bin/bash
# tests/fly-boot-env.bh-9265-test.sh — BH-9265: no long-lived process on a Fly
# builder or pool machine keeps an HBUNDLE_* or SEED_* app secret in its
# environment.
#
# WHY. /proc/<pid>/environ is the env block a process got at execve. A later
# `unset` in a child never changes it. With `ENTRYPOINT ["tini","--",
# entrypoint.sh]` tini started with every app secret and kept them for the life
# of the machine, and tailscaled (started before the unset loop) kept them too.
# Now the entrypoint is the first image process, it unsets the names, and its
# LAST step execs tini, so tini gets a new, clean environ. tailscaled starts
# through `env -u NAME`.
#
# THE REAL BLOCKS RUN: `# >>> boot traps`, `# >>> env scrub` and `# >>> handoff`
# (BH-9265) are lifted from fly/entrypoint.sh by their markers, and the real
# tailscaled launch lines by their first and last line. They run with a real
# exec, so the kernel environ of the launched pid is what the test reads.
# PINNED:
#   S1-S3  boot traps: forced TERM -> rc 143 + log line; INT -> rc 130; not
#          PID 1 and not forced (or the seam without HARNESS_TEST_SANDBOX=1)
#          -> no trap.
#   T1-T3  tailscaled: its /proc/<pid>/environ has no HBUNDLE_/SEED_ name and
#          keeps KEEP_ME; zero seed names -> it still starts; the entrypoint's
#          launch line is `env ${SEED_ENV_U[@]+...` after seed_env_unset_args.
#   H1-H5  handoff: the launched pid becomes tini with a clean environ and a
#          clean runner child; INT -> runner stop record INT, rc 130; TERM ->
#          TERM, rc 143; parent already tini -> no nested tini; TINI_BIN
#          missing -> the runner is exec'd directly.
#   D1-D2  fly/Dockerfile: ENTRYPOINT is the entrypoint script; tini is still
#          installed; `exec "$RUNNER"` is only in the handoff block.
#   C1-C6  bin/fly-boot-env-check.sh with a stub FLY_BIN that runs the real
#          remote scan over a fixture /proc tree.
# BH9265_FIXTURE_TINI=1 runs the H cases with the fixture tini that CI uses when
# /usr/bin/tini is absent.
# Run from anywhere: bash tests/fly-boot-env.bh-9265-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -r /proc/self/environ ] || { echo "no /proc — skipping"; exit 0; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

EP="$DIR/fly/entrypoint.sh"
blk() { sed -n "/^# >>> $1 (BH-9265)/,/^# <<< $1 (BH-9265)/p" "$EP"; }
TRAPS=$(blk 'boot traps'); SCRUB=$(blk 'env scrub'); HANDOFF=$(blk 'handoff')
UNSET=$(sed -n '/^# bundle. The runner must start with none of them./,/^# <<< seed (BH-7430)/p' "$EP")
TSLAUNCH=$(sed -n '/^seed_env_unset_args$/,/^TAILSCALED_PID=\$!$/p' "$EP")
for b in TRAPS SCRUB HANDOFF UNSET TSLAUNCH; do
  [ -n "${!b}" ] && ok || bad "X0: block $b not found in fly/entrypoint.sh"
done

# A launcher that resets SIGINT to default before exec. A non-interactive bash
# starts `&` jobs with SIGINT ignored, and an ignored signal stays ignored
# across exec, so without this no INT case could pass from a background job.
DFL="$T/dfl"
printf '%s\n' '#!/usr/bin/env python3' 'import os, signal, sys' \
  'signal.signal(signal.SIGINT, signal.SIG_DFL)' 'os.execvp(sys.argv[1], sys.argv[1:])' > "$DFL"
chmod +x "$DFL"
waitfile() { local _; for _ in $(seq 1 100); do [ -s "$1" ] && return 0; sleep 0.05; done; return 1; }
envof() { tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null; }
seedhits() { grep -cE '^(HBUNDLE_|SEED_)' || true; }
SEEDS=(HBUNDLE_G_GH_TOKEN=fixture-g HBUNDLE_SYNCED_AT=fixture-t SEED_1731000000_ab12=fixture-s KEEP_ME=1)

# ==== S: boot traps ===========================================================
S="$T/s"; mkdir -p "$S"
{ echo '#!/bin/bash'; echo 'log() { echo "[entrypoint] $*"; }'; echo "$TRAPS"
  echo 'if [ "${PRINT_TRAP:-}" = 1 ]; then trap -p TERM; trap -p INT; exit 0; fi'
  echo 'kill -"$SIG" $$'; echo 'sleep 1'; echo 'echo after-signal'; } > "$S/b.sh"
out=$(HARNESS_TEST_SANDBOX=1 BOOT_TRAPS_FORCE=1 SIG=TERM "$DFL" bash "$S/b.sh" 2>&1); rc=$?
[ "$rc" = 143 ] && grep -q 'boot: stop signal' <<<"$out" && ! grep -q after-signal <<<"$out" && ok \
  || bad "S1: forced TERM: rc=$rc out=[$out]"
out=$(HARNESS_TEST_SANDBOX=1 BOOT_TRAPS_FORCE=1 SIG=INT "$DFL" bash "$S/b.sh" 2>&1); rc=$?
[ "$rc" = 130 ] && grep -q 'boot: stop signal' <<<"$out" && ok || bad "S2: forced INT: rc=$rc out=[$out]"
out=$(HARNESS_TEST_SANDBOX=1 BOOT_TRAPS_FORCE=0 PRINT_TRAP=1 bash "$S/b.sh" 2>&1)
out2=$(HARNESS_TEST_SANDBOX=0 BOOT_TRAPS_FORCE=1 PRINT_TRAP=1 bash "$S/b.sh" 2>&1)
out3=$(HARNESS_TEST_SANDBOX=1 BOOT_TRAPS_FORCE=1 PRINT_TRAP=1 bash "$S/b.sh" 2>&1)
[ -z "$out" ] && [ -z "$out2" ] && grep -q boot_on_signal <<<"$out3" && ok \
  || bad "S3: traps outside PID 1: unforced=[$out] no-sandbox=[$out2] forced=[$out3]"

# ==== T: tailscaled starts with no seed names ================================
TS="$T/ts"; mkdir -p "$TS/bin"
printf '%s\n' '#!/bin/bash' 'echo up > "$OUT/ts.up"' \
  'for _ in $(seq 1 60); do [ -e "$OUT/ts.stop" ] && exit 0; sleep 0.05; done' > "$TS/bin/tailscaled"; chmod +x "$TS/bin/tailscaled"
{ echo '#!/bin/bash'; echo 'set -uo pipefail'; echo "$SCRUB"
  sed "s#/var/log/tailscaled.log#$TS/ts.log#" <<<"$TSLAUNCH"
  echo 'echo "$TAILSCALED_PID" > "$OUT/ts.pid"'; echo 'wait'; } > "$TS/l.sh"
env "${SEEDS[@]}" OUT="$TS" PATH="$TS/bin:$PATH" bash "$TS/l.sh" &
LP=$!
if waitfile "$TS/ts.up" && waitfile "$TS/ts.pid"; then
  tp=$(cat "$TS/ts.pid"); e=$(envof "$tp")
  [ "$(cat "/proc/$tp/comm" 2>/dev/null)" = tailscaled ] && [ "$(seedhits <<<"$e")" = 0 ] \
    && grep -qx 'KEEP_ME=1' <<<"$e" && ok || bad "T1: tailscaled environ: comm=$(cat "/proc/$tp/comm" 2>/dev/null) hits=$(seedhits <<<"$e")"
else bad "T1: the stub tailscaled never started"; fi
kill "$LP" 2>/dev/null; pkill -P "$LP" 2>/dev/null; wait "$LP" 2>/dev/null
rm -f "$TS/ts.up" "$TS/ts.pid"
env -u HBUNDLE_G_GH_TOKEN KEEP_ME=1 OUT="$TS" PATH="$TS/bin:$PATH" bash "$TS/l.sh" &
LP=$!
waitfile "$TS/ts.up" && ok || bad "T2: zero seed names: the stub tailscaled did not start"
kill "$LP" 2>/dev/null; pkill -P "$LP" 2>/dev/null; wait "$LP" 2>/dev/null
L=$(grep -n '^env \${SEED_ENV_U\[@\]+"\${SEED_ENV_U\[@\]}"} tailscaled \\$' "$EP" | cut -d: -f1)
[ -n "$L" ] && [ "$(sed -n "$((L-1))p" "$EP")" = seed_env_unset_args ] \
  && [ "$(grep -c '^ *tailscaled \\$' "$EP")" = 0 ] && ok || bad "T3: tailscaled launch line not scrubbed (line=$L)"

# ==== H: handoff execs tini with a clean environ =============================
H="$T/h"; mkdir -p "$H"
if [ -x /usr/bin/tini ] && [ "${BH9265_FIXTURE_TINI:-}" != 1 ]; then TINI=/usr/bin/tini
else
  echo "real tini absent: fixture used"
  mkdir -p "$H/tbin"; TINI="$H/tbin/tini"
  # Like real tini, the child starts with SIGINT at default (through $DFL).
  cat > "$TINI" <<F
#!/bin/bash
DFL="$DFL"
F
  cat >> "$TINI" <<'F'
[ "${1:-}" = -s ] && shift; [ "${1:-}" = -- ] && shift
"$DFL" "$@" & c=$!
trap 'kill -INT $c' INT; trap 'kill -TERM $c' TERM
while :; do wait "$c"; rc=$?; kill -0 "$c" 2>/dev/null || exit "$rc"; done
F
  chmod +x "$TINI"
fi
cat > "$H/stub-runner" <<'R'
#!/bin/bash
trap 'echo INT > "$OUT/stop.rec"; exit 130' INT
trap 'echo TERM > "$OUT/stop.rec"; exit 143' TERM
tr '\0' '\n' < /proc/$$/environ > "$OUT/runner.env"
echo $$ > "$OUT/ready"
while :; do sleep 0.1; done
R
chmod +x "$H/stub-runner"
{ echo '#!/bin/bash'; echo 'set -uo pipefail'; echo 'log() { echo "[entrypoint] $*" >> "$OUT/log"; }'
  echo "$UNSET"; echo "RUNNER=$H/stub-runner"; echo "$HANDOFF"; } > "$H/h.sh"
ppid_of() { awk '/^PPid:/{print $2}' "/proc/$1/status" 2>/dev/null; }
hreset() { rm -f "$H/ready" "$H/stop.rec" "$H/runner.env" "$H/log"; }

# H1-H3: started with seed names, as the image starts the entrypoint.
for sig in INT TERM; do
  hreset
  env "${SEEDS[@]}" OUT="$H" TINI_BIN="$TINI" "$DFL" bash "$H/h.sh" &
  P=$!
  if waitfile "$H/ready"; then
    r=$(cat "$H/ready"); pe=$(envof "$P")
    if [ "$sig" = INT ]; then
      [ "$(cat "/proc/$P/comm")" = tini ] && [ "$(ppid_of "$r")" = "$P" ] \
        && [ "$(seedhits <<<"$pe")" = 0 ] && grep -qx KEEP_ME=1 <<<"$pe" \
        && [ "$(seedhits < "$H/runner.env")" = 0 ] && grep -qx KEEP_ME=1 "$H/runner.env" && ok \
        || bad "H1: pid comm=$(cat "/proc/$P/comm") runner ppid=$(ppid_of "$r") tini hits=$(seedhits <<<"$pe") runner hits=$(seedhits < "$H/runner.env")"
    fi
    kill -"$sig" "$P"; wait "$P"; rc=$?
    want=130; [ "$sig" = TERM ] && want=143
    n=H2; [ "$sig" = TERM ] && n=H3
    [ "$rc" = "$want" ] && [ "$(cat "$H/stop.rec" 2>/dev/null)" = "$sig" ] && ok \
      || bad "$n: $sig: rc=$rc stop.rec=$(cat "$H/stop.rec" 2>/dev/null)"
  else bad "H1-3 ($sig): the stub runner never started"; kill "$P" 2>/dev/null; wait "$P" 2>/dev/null; fi
done

# H4: the parent is already tini (an older image) -> no nested tini.
hreset
"$TINI" -s -- env "${SEEDS[@]}" OUT="$H" TINI_BIN="$TINI" bash "$H/h.sh" &
P=$!
if waitfile "$H/ready"; then
  r=$(cat "$H/ready")
  [ "$(ppid_of "$r")" = "$P" ] && [ "$(cat "/proc/$r/comm")" = stub-runner ] && ok \
    || bad "H4: runner parent=$(ppid_of "$r") (want $P) comm=$(cat "/proc/$r/comm")"
else bad "H4: the stub runner never started"; fi
kill -TERM "$P" 2>/dev/null; wait "$P" 2>/dev/null

# H5: TINI_BIN missing -> exec the runner directly.
hreset
env "${SEEDS[@]}" OUT="$H" TINI_BIN=/nonexistent/tini bash "$H/h.sh" &
P=$!
if waitfile "$H/ready"; then
  [ "$(cat "$H/ready")" = "$P" ] && [ "$(cat "/proc/$P/comm")" = stub-runner ] \
    && grep -q 'exec builder-runner' "$H/log" && ok || bad "H5: runner pid=$(cat "$H/ready") (want $P)"
else bad "H5: the stub runner never started"; fi
kill -TERM "$P" 2>/dev/null; wait "$P" 2>/dev/null

# ==== D: the Dockerfile =======================================================
DF="$DIR/fly/Dockerfile"
EPJ=$(grep '^ENTRYPOINT ' "$DF" | tail -1 | sed 's/^ENTRYPOINT //' | jq -c . 2>/dev/null)
[ "$EPJ" = '["/opt/fly-boot/entrypoint.sh"]' ] && ok || bad "D1: ENTRYPOINT is [$EPJ]"
[ "$(grep -c 'exec "\$RUNNER"' "$EP")" = 1 ] && grep -q 'exec "\$RUNNER"' <<<"$HANDOFF" \
  && grep -qE '^ +tini \\$' "$DF" && ok || bad "D2: tini not installed or exec \"\$RUNNER\" outside the handoff block"

# ==== C: bin/fly-boot-env-check.sh ===========================================
C="$T/c"; mkdir -p "$C/proc"
CHK="$DIR/bin/fly-boot-env-check.sh"
cat > "$C/fly" <<'Y'
#!/bin/bash
printf '%s\n' "$*" > "$FLY_ARGS"
case "${FLY_MODE:-}" in
  fail) echo "Error: no machine" >&2; exit 1 ;;
  noscan) echo "hit-less output"; exit 0 ;;
esac
cmd=""; prev=""
for a in "$@"; do [ "$prev" = -C ] && cmd="$a"; prev="$a"; done
cmd=${cmd//\/proc\//$FAKEPROC/}
eval "$cmd"
Y
chmod +x "$C/fly"
mkproc() { # mkproc <pid> <comm> <NAME=VAL>...
  local p=$1 c=$2; shift 2; mkdir -p "$C/proc/$p"; echo "$c" > "$C/proc/$p/comm"
  printf '%s\0' "$@" > "$C/proc/$p/environ"
}
runchk() { FLY_BIN="$C/fly" FAKEPROC="$C/proc" FLY_ARGS="$C/args" bash "$CHK" "$@" 2>&1; }
scratch_rm "$C/proc" && mkdir -p "$C/proc"; mkproc 1 tini PATH=/usr/bin KEEP_ME=1; mkproc 7 tailscaled PATH=/usr/bin
out=$(runchk builder-x m1); rc=$?
[ "$rc" = 0 ] && grep -q '^clean: 2 processes' <<<"$out" && grep -q -- '--machine m1' "$C/args" \
  && grep -q -- '-a builder-x' "$C/args" && ok || bad "C1: clean: rc=$rc out=[$out]"
mkproc 7 tailscaled PATH=/usr/bin SEED_1_ab=fixture-secret-v HBUNDLE_G_GH_TOKEN=fixture-tok
out=$(runchk builder-x m1); rc=$?
[ "$rc" = 1 ] && grep -q 'hit 7 tailscaled SEED_1_ab' <<<"$out" && grep -q 'hit 7 tailscaled HBUNDLE_G_GH_TOKEN' <<<"$out" \
  && ! grep -q fixture-secret-v <<<"$out" && ! grep -q fixture-tok <<<"$out" && ok || bad "C2: hit: rc=$rc out=[$out]"
mkproc 7 tailscaled MY_SEED_X=1 HBUNDLE=1 X=SEED_abc seed_x=1 SEEDS=1 hbundle_g=1
out=$(runchk builder-x m1); rc=$?
[ "$rc" = 0 ] && ! grep -q '^hit' <<<"$out" && ok || bad "C3: near misses: rc=$rc out=[$out]"
out=$(FLY_MODE=fail runchk builder-x m1); rc=$?
[ "$rc" = 2 ] && grep -q '^could-not-run' <<<"$out" && ok || bad "C4: fly failed: rc=$rc out=[$out]"
out=$(FLY_MODE=noscan runchk builder-x m1); rc=$?
[ "$rc" = 2 ] && grep -q '^could-not-run' <<<"$out" && ok || bad "C5: no scanned line: rc=$rc out=[$out]"
out=$(runchk); rc=$?
[ "$rc" = 2 ] && grep -qi usage <<<"$out" && ok || bad "C6: no args: rc=$rc out=[$out]"

echo "fly-boot-env.bh-9265: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
