#!/bin/bash
# tests/testhost-tick.bh-1221-test.sh — the two bin/testhost-tick.sh follow-ups
# the Fable review of #1213 asked for (BH-1221, items 1 and 2).
#
# WHY A SECOND SUITE AND NOT MORE CASES IN tests/testhost-tick-test.sh. That
# suite's flyctl stub ANSWERS the busy probe with a fixture number: it proves the
# tick does the right thing with a count, and it can never see whether the count
# itself is right. Both findings here are about the probe's own arithmetic and
# about the path resolution that happens before any of it, so both need a
# fixture the other suite deliberately does not have:
#
#   1. THE PROBE IS EXECUTED, NOT ANSWERED. The flyctl stub below takes the
#      exact command string the tick composes for `-C`, rewrites /srv to a
#      fixture root, and runs it. So `find`, `wc -l` and the process witness are
#      the real ones, and the thing under test is the command the host receives.
#      The bug: /srv/tmp/runs is a depth-1 child of /srv/tmp, its mtime moves on
#      every run create/remove, so an EMPTY host read `busy 1` for the whole
#      120-minute window and TESTHOST_IDLE_STOP_MIN (30) never decided anything.
#   2. THE HARNESS FALLBACK RUNS OFF-HUB. Section 2 runs the tick out of a
#      checkout COPY with HARNESS pointing at a directory that does not exist —
#      the Mac case the fallback exists for. The existing suite passes
#      HARNESS=$H, a directory that is there, so deleting the fallback line left
#      it 45/45 green.
#
# Assertions are on the probe's answer, the recorded flyctl calls and the files
# the run left on disk — never on the script's source text.
#
# Run from anywhere: tests/testhost-tick.bh-1221-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
TICK="$DIR/bin/testhost-tick.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -f "$TICK" ] || { echo "FAIL: bin/testhost-tick.sh does not exist"; exit 1; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

FIX="$T/fix"; H="$T/h"
mkdir -p "$FIX/settings" "$T/fakebin" "$H/bin/lib" "$H/catalog" "$H/flags" "$H/logs" "$H/state"
cp "$DIR/bin/lib/lane-gate.sh" "$H/bin/lib/"
cp "$DIR/bin/lib/env-path.sh" "$H/bin/lib/"
cp "$(rendered_registry)" "$H/catalog/lanes.json"
# ONE clock read for the whole file; every age below is derived from it.
NOW=$(date -u '+%s')

# `touch -d @epoch` is GNU; the one case that needs a backdated mtime says so
# and is skipped rather than asserted about, the way tests/backup-freshness-test.sh
# handles the same dependency.
TOUCH_EPOCH=1
touch -d "@$NOW" "$T/.touch-probe" 2>/dev/null || TOUCH_EPOCH=0

# The jobs-client stub: setting_get/setting_set are files under $FIX/settings.
# It is written ONCE here and copied into both scratch harnesses below, so the
# checkout copy in section 2 never copies the real bin/jobs-client.sh — that one
# needs bin/lib/jobs/*.sh beside it, and tests/jobs-client-modules.bh-1194-test.sh
# is right to refuse a fixture that takes the client without its modules.
cat > "$T/jobs-client-stub.sh" <<'STUB'
JOBS_BOX=fixture
flag_sync()  { return 1; }
setting_get() {
  [ -f "$FIX/settings/$1" ] || return 2
  cat "$FIX/settings/$1"
}
setting_set() {
  printf '%s' "$2" > "$FIX/settings/$1"
  return 0
}
STUB
cp "$T/jobs-client-stub.sh" "$H/bin/jobs-client.sh"

# THE FLYCTL STUB THAT EXECUTES THE PROBE. `ssh console … -C <probe>` is the one
# branch that differs from tests/testhost-tick-test.sh: instead of printing a
# fixture count it takes the argument after -C, points every /srv at $FIX/srv,
# and evals it. That is what makes this suite about the probe rather than about
# what the tick does with a number somebody handed it.
cat > "$T/fakebin/flyctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/fly-calls"
case "$*" in
  *"machine list"*)
    cat "$FIX/machines.json"; exit 0 ;;
  *"machine status"*)
    printf 'Machine ID: 873eddb0433018\nState: %s\n\nVM\n ID  | 873eddb0433018\n CPU Kind │ performance\n vCPUs │ 16\n' \
      "$(cat "$FIX/state" 2>/dev/null || echo started)"
    exit 0 ;;
  *"ssh console"*)
    prev=""; probe=""
    for a in "$@"; do
      if [ "$prev" = "-C" ]; then probe="$a"; break; fi
      prev="$a"
    done
    [ -n "$probe" ] || { echo "stub: no -C probe in: $*" >&2; exit 1; }
    printf '%s\n' "$probe" > "$FIX/probe-seen"
    echo "Connecting to fdaa:..."
    from=/srv; to="$FIX/srv"
    eval "${probe//"$from"/"$to"}"
    exit 0 ;;
  *"machine start"*) printf 'started\n' > "$FIX/state"; exit 0 ;;
  *"machine stop"*)  printf 'stopped\n' > "$FIX/state"; exit 0 ;;
esac
exit 0
STUB
# The process witness, under fixture control. The real pgrep would count this
# suite's own `bash tests/…` command line and every case below would read busy.
cat > "$T/fakebin/pgrep" <<'STUB'
#!/bin/bash
cat "$FIX/procs" 2>/dev/null || echo 0
exit 0
STUB
chmod +x "$T/fakebin"/*
printf '[{"id":"873eddb0433018","name":"testhost-1","state":"started"}]\n' > "$FIX/machines.json"
export FIX

run() { # run [verb...]
  OUT=$(env PATH="$T/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$T" HARNESS="$H" \
    TESTHOST_APP=bh-testhost-fixture TESTHOST_IDLE_STOP_MIN=30 \
    TESTHOST_SIZE=performance-16x \
    bash "$TICK" "$@" 2>&1); RC=$?
}
reset() {
  rm -f "$FIX/fly-calls" "$FIX/probe-seen" "$FIX/procs" "$H/logs/testhost-tick.log"
  rm -f "$FIX"/settings/*
  scratch_rm "$H/state/lane-gate" >/dev/null 2>&1 || true
  scratch_rm "$FIX/srv" >/dev/null 2>&1 || true
  printf 'started\n' > "$FIX/state"
  # The two run roots a quiet host has: present, empty, and freshly touched by
  # the run that finished a moment ago.
  mkdir -p "$FIX/srv/tmp/runs" "$FIX/srv/runs"
}
calls() { cat "$FIX/fly-calls" 2>/dev/null; }
stamp() { printf '%s' "$1" > "$FIX/settings/testhost.last_used"; }

# ── 1. the busy probe counts RUNS, not the roots they live in ───────────────
# 1a is the review's finding: a host with nothing on it but the empty run roots.
reset
run busy
case "$OUT" in
  *idle*) ok ;;
  *) bad "1a a host with only the empty run roots read '$OUT' — /srv/tmp/runs is a fresh-mtime child of /srv/tmp, so the idle stop can never fire" ;;
esac
# and the whole point of the finding: the tick actually stops such a host once
# the row is past TESTHOST_IDLE_STOP_MIN.
reset; stamp "$((NOW - 7200))"
run
case "$(calls)" in
  *"machine stop"*) ok ;;
  *) bad "1b a two-hour-idle host with empty run roots was not stopped: $(calls) / $OUT" ;;
esac
# The probe that ran is the one the tick composes, not a rewrite of it.
case "$(cat "$FIX/probe-seen" 2>/dev/null)" in
  *TESTHOST_BUSY*) ok ;;
  *) bad "1c the tick never sent a probe to the host (nothing to execute): $(cat "$FIX/probe-seen" 2>/dev/null)" ;;
esac

# 1d: a real run under /srv/tmp/runs still counts, and the tick leaves it alone.
reset; stamp "$((NOW - 7200))"
mkdir -p "$FIX/srv/tmp/runs/1700000000-42"
run busy
case "$OUT" in
  *"busy 1"*) ok ;;
  *) bad "1d a live run under /srv/tmp/runs did not read busy: $OUT" ;;
esac
run
case "$(calls)" in
  *"machine stop"*) bad "1e a host with a live run under /srv/tmp/runs was stopped" ;;
  *) ok ;;
esac

# 1f: the third root counts too — different runners on this host have used
# /srv/runs, and a stop must not depend on which one a colleague picked.
reset
mkdir -p "$FIX/srv/runs/1700000000-9"
run busy
case "$OUT" in
  *"busy 1"*) ok ;;
  *) bad "1f a live run under /srv/runs did not read busy: $OUT" ;;
esac

# 1g: a run whose mtime is outside TESTHOST_BUSY_WINDOW_MIN is litter, not work.
if [ "$TOUCH_EPOCH" = 1 ]; then
  reset
  mkdir -p "$FIX/srv/tmp/runs/1600000000-1"
  touch -d "@$((NOW - 10800))" "$FIX/srv/tmp/runs/1600000000-1"
  run busy
  case "$OUT" in
    *idle*) ok ;;
    *) bad "1g a run root three hours dead was still counted as work: $OUT" ;;
  esac
else
  echo "note: touch -d @epoch unsupported here — 1g (a 3h-old run root) skipped"
fi

# 1h: the process witness is still added on top. Excluding the roots must not
# have excluded the other half of the probe.
reset
printf '2\n' > "$FIX/procs"
run busy
case "$OUT" in
  *"busy 2"*) ok ;;
  *) bad "1h two live suite processes on an otherwise empty host read '$OUT', not busy 2" ;;
esac

# ── 2. off-hub, the harness IS the checkout this script lives in ─────────────
# A Mac running the gate has no /root/harness. Without the fallback every path
# the lane writes — logs/, env/, the settings client — resolves under a
# directory that does not exist, and the use is never recorded, which is the
# input the idle stop reads. This section is the assertion the review found
# missing: deleting `[ -d "$HARNESS" ] || HARNESS=…` reds 2b and 2c.
CO="$T/co"
mkdir -p "$CO/bin/lib" "$CO/catalog"
cp "$T/jobs-client-stub.sh" "$CO/bin/jobs-client.sh"
scratch_install_closure bin/testhost-tick.sh "$CO" >/dev/null || bad "2 could not install the tick's closure into $CO"
cp "$(rendered_registry)" "$CO/catalog/lanes.json"
reset; stamp "$((NOW - 60))"   # inside the window: no machine action either way
OUT=$(env PATH="$T/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$T" HARNESS="$T/nope" \
  TESTHOST_APP=bh-testhost-fixture TESTHOST_IDLE_STOP_MIN=30 \
  TESTHOST_SIZE=performance-16x \
  bash "$CO/bin/testhost-tick.sh" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "2a the tick exited $RC with HARNESS pointing at a directory that does not exist: $OUT"
if grep -q "left started" "$CO/logs/testhost-tick.log" 2>/dev/null; then ok; else
  bad "2b the off-hub tick wrote no log under its own checkout ($CO/logs/testhost-tick.log): $OUT"
fi
[ ! -e "$T/nope" ] && ok \
  || bad "2c the lane created the harness path that was not there ($T/nope) instead of falling back to its checkout"

echo "testhost-tick BH-1221: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
