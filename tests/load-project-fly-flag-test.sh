#!/bin/bash
# tests/load-project-fly-flag-test.sh — `bin/load-project.sh --fly` queues the
# Fly onboarding in the loader's OWN commit, and without the flag the loader is
# unchanged (BH-662).
#
# WHY IT DRIVES THE REAL SCRIPT. The property under test is not "a line gets
# appended" — it is that the line rides the commit the loader already makes, so
# it reaches the hub on the next fleet-propagate with no ssh anywhere. That is a
# fact about load-project.sh's commit wiring, which only the real script has, so
# this runs it end to end against a scratch copy of the repo with `gh`, `git`
# and `ssh` stubbed. The `git` stub records its argv, which is how "the queue
# file was STAGED" becomes an assertion rather than an assumption.
#
# THE NEGATIVE IS THE POINT (§B): the ticket says "without the flag nothing is
# queued (no behavior change to today's loader)", so the default path is pinned
# with `cmp` against the committed fixture and an argv check that the file is
# never even staged.
#
# MUTATION NOTE (D1): drop the `--fly` arm from the flag parser and §A goes red;
# stage the queue file unconditionally and §B goes red.
#
# Run from anywhere: tests/load-project-fly-flag-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" 2>/dev/null || SCRATCH_FALLBACK=1
# BRIDGE until BH-459/#609 lands tests/lib/scratch.sh on main.
if [ "${SCRATCH_FALLBACK:-}" = 1 ]; then
  T=$(mktemp -d "${TMPDIR:-/tmp}/bh662.XXXXXX"); trap 'rm -rf "$T"' EXIT
fi
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

mkbin() { # mkbin <dir> — the three commands the loader shells out to
  cat > "$1/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
  *"--json defaultBranchRef --jq"*) echo main ;;
  *"repo view"*) echo '{"name":"gamma","defaultBranchRef":{"name":"main"},"isArchived":false}' ;;
  *) : ;;
esac
exit 0
STUB
  # `diff --quiet` answers DIRTY, which is what it answers in production too —
  # the loader always writes a fleet.conf row before it gets here.
  cat > "$1/git" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$GIT_LOG"
case "$1" in
  diff)      case "$*" in *--quiet*) exit 1 ;; esac ;;
  rev-parse) echo deadbeef ;;
esac
exit 0
STUB
  # --no-bootstrap must never reach a box. A call here is a failure, loudly.
  cat > "$1/ssh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$SSH_LOG"
exit 1
STUB
  chmod +x "$1/gh" "$1/git" "$1/ssh"
}

mkrepo() { # mkrepo <dir> — a scratch checkout the real loader can run inside
  local R="$1"
  mkdir -p "$R/bin/lib" "$R/prompts" "$R/fly" "$R/stub"
  cp "$DIR/bin/load-project.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" \
     "$DIR/bin/render-crontab.sh" "$R/bin/"
  cp "$DIR/bin/lib/cron-lines.sh" "$R/bin/lib/"
  cp "$DIR/prompts/TEMPLATE-GH.md" "$R/prompts/"
  # Header only: the committed file may carry real project lines (routing
  # decisions), and they must not leak into this fixture's line counts.
  grep -E '^[[:space:]]*(#|$)' "$DIR/fly/onboard-queue.conf" > "$R/fly/onboard-queue.conf"
  cp "$R/fly/onboard-queue.conf" "$R/queue-baseline.conf"
  cat > "$R/fleet.conf" <<'CONF'
# project      repo                       prod                                 pfx off box                     tailnet_ip
alpha          example-org/alpha            -                                    -   1  box-small     10.0.0.13
CONF
  mkbin "$R/stub"
  export GH_LOG="$R/gh.log" GIT_LOG="$R/git.log" SSH_LOG="$R/ssh.log"
}

load() { # load <repo-dir> [args...] -> stdout in $OUT, rc in $RC
  local R="$1"; shift
  OUT=$(cd "$R" && PATH="$R/stub:$PATH" bash "$R/bin/load-project.sh" "$@" 2>&1); RC=$?
}
qlines() { grep -cvE '^[[:space:]]*(#|$)' "$1/fly/onboard-queue.conf"; }

# ══ A. --fly queues it, stages it, and says how to check it ═════════════════
A="$T/a"; mkrepo "$A"
load "$A" example-org/gamma --fly --no-bootstrap
[ "$RC" = 0 ] && ok || bad "--fly --no-bootstrap must exit 0 (got $RC): $OUT"
[ "$(qlines "$A")" = 1 ] \
  && ok || bad "exactly one project line must be queued (got $(qlines "$A"))"
[ "$(grep -vE '^[[:space:]]*(#|$)' "$A/fly/onboard-queue.conf" | awk '{print $1}')" = gamma ] \
  && ok || bad "field 1 of the queued line must be the project name"
grep -E '^add .*fly/onboard-queue.conf' "$A/git.log" >/dev/null \
  && ok || bad "the queue file must be STAGED into the loader's own commit: $(grep '^add' "$A/git.log")"
grep -E '^commit ' "$A/git.log" >/dev/null \
  && ok || bad "the loader must still make its commit"
grep -q "fly/onboard-queue.conf now carries 'gamma'" <<<"$OUT" \
  && ok || bad "the loader must print what it queued: $OUT"
grep -q 'free-slots.sh gamma' <<<"$OUT" \
  && ok || bad "the loader must print how to check it on the hub: $OUT"
grep -q 'ALERTS.log' <<<"$OUT" \
  && ok || bad "the loader must say where a failure will land: $OUT"
[ ! -s "$A/ssh.log" ] \
  && ok || bad "queuing must need no ssh in either direction (got: $(cat "$A/ssh.log"))"
# Re-run: idempotent, no second line.
load "$A" example-org/gamma --fly --no-bootstrap
[ "$RC" = 0 ] && ok || bad "a re-run must exit 0 (got $RC): $OUT"
grep -q 'already carries gamma — skipping' <<<"$OUT" \
  && ok || bad "a re-run must say it is already queued: $OUT"
[ "$(qlines "$A")" = 1 ] \
  && ok || bad "a re-run must not append a second line (got $(qlines "$A"))"

# ══ B. WITHOUT --fly: byte-identical, and never staged ══════════════════════
B="$T/b"; mkrepo "$B"
load "$B" example-org/gamma --no-bootstrap
[ "$RC" = 0 ] && ok || bad "the default path must exit 0 (got $RC): $OUT"
cmp -s "$B/fly/onboard-queue.conf" "$B/queue-baseline.conf" \
  && ok || bad "without --fly the queue file must be byte-identical to the fixture copy"
grep -q 'fly onboarding' <<<"$(printf '%s\n' "$OUT")" \
  && bad "without --fly the loader must not mention onboarding at all: $OUT" || ok
grep -E '^add .*fly/onboard-queue.conf' "$B/git.log" >/dev/null \
  && bad "without --fly the queue file must never be staged" || ok
grep -E '^commit ' "$B/git.log" >/dev/null \
  && ok || bad "the default path must still commit the registry row"

# ══ C. AN UNKNOWN FLAG STILL REFUSES, AND QUEUES NOTHING ═══════════════════
C="$T/c"; mkrepo "$C"
load "$C" example-org/gamma --fly --bogus --no-bootstrap
[ "$RC" = 2 ] && ok || bad "an unknown flag must still exit 2 (got $RC): $OUT"
cmp -s "$C/fly/onboard-queue.conf" "$C/queue-baseline.conf" \
  && ok || bad "a refused invocation must queue nothing"

echo "load-project-fly-flag: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
