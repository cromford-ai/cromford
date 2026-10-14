#!/bin/bash
# tests/harness-ci-runners.bh-1206-test.sh — BH-1206: NO JOB NAMES ITS RUNNER.
#
# WHERE CI RUNS IS A DATA SWITCH (BH-1209): every job reads the repo variable
# CI_RUNNER, so the fleet moves with one API call and a re-run rather than a PR.
# Since 2026-09-22 the variable holds MonkCI's label and the Fly pool is the
# fallback fleet (BH-1323, docs/CI-RUNNERS.md). `"ubuntu-latest"` is what the
# nine runs-on lines render when the variable is unset, and BH-1323's lint-job
# guard turns that state red rather than running on it silently.
#
# THE SILENCE THIS KILLS. `runs-on:` is nine independent lines in one file.
# Point eight of them at the variable and hard-code the ninth and the gate
# SPLITS: most of the run on one fleet, one job on another — a different
# machine, a different toolset, a different speed — and the whole thing still
# shows up green. Nobody reads a runs-on line in a review, and a literal is
# invisible in a diff that moved nine of them. So the rule is mechanical and it
# does not care which fleet the literal names: every job's runs-on reads
# `vars.CI_RUNNER`, and no hosted image (`ubuntu-`, `macos-`, `windows-`) and no
# self-hosted label appears anywhere in the file outside that one fallback.
# (`publish-cromford.yml` is deliberately out of scope — separate ticket.)
#
# THE SECOND HALF IS THE TOOL STEPS, and the switch is exactly why they matter:
# CI_RUNNER can point at a Fly image that bakes in codegraph 1.5.0, semgrep
# 1.176.1, shellcheck, age and zstd, or at a hosted image that carries none of
# them, between one run and the next. So every install must be idempotent on
# both — check the pin, install only when it is missing. That check is a SCRIPT,
# `bin/ci-tool-present.sh`, not a grep-able line of YAML: a wiring this suite
# could only look at would be dead code the day someone inverted its exit code.
# Block B RUNS it against fake tools on PATH; block C asserts only what a run
# cannot — that the workflow calls it, and that the PIN it names is the pin the
# install command uses. A guard checking for 1.5.0 next to an
# `npm install -g …@1.6.0` reinstalls on every job forever and reads as fine.
#
# No network, no secrets, no clock, no dice. Run from anywhere: exit 0 = pass.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
WF="${BH1206_WORKFLOW:-$DIR/.github/workflows/harness-ci.yml}"
PRESENT="${BH1206_PRESENT:-$DIR/bin/ci-tool-present.sh}"
# The one runs-on line every job must carry, byte for byte. Held as a constant
# because "every job the same" is half the rule: nine jobs agreeing on nothing
# is the split this suite exists to stop.
RUNS_ON='${{ fromJSON(vars.CI_RUNNER || '"'"'"ubuntu-latest"'"'"') }}'

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -f "$WF" ] || { echo "FAIL: workflow not found at $WF"; exit 1; }

# ── A. every job reads the variable, and no job names a runner ──────────────
# Job ids at the workflow's job indent, read off the file rather than listed
# here: a job added tomorrow is covered without anyone remembering this suite.
JOBS=$(awk '/^jobs:/{inj=1;next} inj && /^  [a-zA-Z0-9_-]+:[[:space:]]*$/{gsub(/[ :]/,"");print}' "$WF")
NJOBS=$(printf '%s\n' "$JOBS" | grep -c .)
if [ "$NJOBS" -ge 8 ]; then ok
else bad "A: only $NJOBS jobs parsed out of $WF — the reader is broken, not the file"; fi

job_block() {
  awk -v want="$1" '
    /^  [a-zA-Z0-9_-]+:/ { inblk = ($0 ~ "^  "want":[[:space:]]*$") }
    inblk { print }
  ' "$WF"
}

MISSING=""; WRONG=""
while read -r J; do
  [ -n "$J" ] || continue
  LINE=$(job_block "$J" | sed -n 's|^    runs-on:[[:space:]]*||p' | head -1)
  if [ -z "$LINE" ]; then MISSING="$MISSING $J"; continue; fi
  [ "$LINE" = "$RUNS_ON" ] || WRONG="$WRONG
    $J: $LINE"
done <<< "$JOBS"

if [ -z "$MISSING" ]; then ok; else bad "A: job(s) with no runs-on: line:$MISSING"; fi
if [ -z "$WRONG" ]; then ok
else bad "A: every job's runs-on must be exactly
    $RUNS_ON
  found:$WRONG"; fi

# Every job READS THE VARIABLE — stated separately from the byte comparison
# above, because that one also fails on a whitespace change and this is the
# thing that actually matters. A job pinned to a literal cannot follow the
# switch, and moving the fleet would leave it behind, silently, on the old one.
N=$(grep -c 'runs-on:.*vars\.CI_RUNNER' "$WF")
if [ "$N" = "$NJOBS" ]; then ok
else bad "A: $N of $NJOBS jobs read vars.CI_RUNNER — the rest cannot follow the switch"; fi

# NO RUNNER IS NAMED ON A runs-on LINE, and the one exception is counted rather
# than excused: `"ubuntu-latest"` appears once inside each job's fallback and
# nowhere else on those lines. Prose may name a fleet — docs are how the next
# reader learns what the variable holds — but a runs-on line may not.
RO=$(grep -E '^[[:space:]]*runs-on:' "$WF")
N=$(printf '%s\n' "$RO" | grep -c "fromJSON(vars.CI_RUNNER || '\"ubuntu-latest\"')")
if [ "$N" = "$NJOBS" ]; then ok
else bad "A: $N of $NJOBS runs-on lines carry the sanctioned fallback"; fi

# Any OTHER hosted image on a runs-on line: `ubuntu-24.04`, `ubuntu-16-core`,
# `macos-14`, `windows-2025`. The fallback is the only hosted name allowed
# there, so these have no legitimate use.
STRAY=$(printf '%s\n' "$RO" | grep -nE 'ubuntu-(16-core|latest-[0-9]|[0-9]{2}\.[0-9]{2})|macos-|windows-' || true)
if [ -z "$STRAY" ]; then ok
else bad "A: a hosted runner image is named on a runs-on line — the fleet is CI_RUNNER's business:
$STRAY"; fi

# …and no SELF-HOSTED label either. This is the half a reviewer forgets, because
# the labels look like the right answer today: the variable already holds them,
# so a literal copy is invisible until the fleet moves and one job does not.
STRAY=$(printf '%s\n' "$RO" | grep -nE 'self-hosted|bh-ci' || true)
if [ -z "$STRAY" ]; then ok
else bad "A: a self-hosted label is named on a runs-on line — it belongs in the CI_RUNNER variable:
$STRAY"; fi

# The pool label has no other meaning in this file, so it must not appear in
# executable text ANYWHERE — not in a runs-on line, not in an `if:` guard, not
# in a step that branches on which fleet it is running on. Comments are exempt
# on purpose: the header explains the switch and must be able to name it.
# (`self-hosted` alone is not checked here — `console-ui` legitimately says
# "self-hosted font missing" about a woff2, and a rule that cannot tell those
# apart is a rule people delete.)
NOCOMMENT=$(grep -v '^[[:space:]]*#' "$WF")
STRAY=$(printf '%s\n' "$NOCOMMENT" | grep -nE 'bh-ci|\[self-hosted' || true)
if [ -z "$STRAY" ]; then ok
else bad "A: the pool's labels appear in executable text — only the CI_RUNNER variable may name the fleet:
$STRAY"; fi

# setup-node keeps working on a self-hosted runner and the ticket says it stays.
case "$(cat "$WF")" in
  *"actions/setup-node@v4"*) ok ;;
  *) bad "A: actions/setup-node@v4 disappeared — it works on self-hosted and was meant to stay" ;;
esac

# ── B. the presence helper, RUN ─────────────────────────────────────────────
if [ -x "$PRESENT" ]; then ok; else bad "B: $PRESENT is missing or not executable (BH-1206)"; fi

mkdir -p "$T/fakebin"
fake() { # fake <name> <version-output> [exit-code]
  printf '#!/bin/sh\nprintf "%%s\\n" %q\nexit %s\n' "$2" "${3:-0}" > "$T/fakebin/$1"
  chmod 755 "$T/fakebin/$1"
}
present() { # present <args...> → rc, output in $T/p.out
  ( PATH="$T/fakebin:$PATH" "$PRESENT" "$@" >"$T/p.out" 2>&1 ); echo $?
}

if [ -x "$PRESENT" ]; then
  fake codegraph "1.5.0"
  RC=$(present codegraph 1.5.0)
  if [ "$RC" = 0 ]; then ok; else bad "B: the pinned version present must be rc 0 (rc=$RC): $(cat "$T/p.out")"; fi

  # The pin is a whole version, never a prefix match: 1.5.0 must not be
  # satisfied by 1.5.01, and 1.5 must not be satisfied by 1.5.0 either — a
  # loose match is how a job silently runs a tool nobody pinned.
  fake codegraph "1.5.10"
  RC=$(present codegraph 1.5.1)
  if [ "$RC" != 0 ]; then ok; else bad "B: 1.5.10 must not satisfy the pin 1.5.1 — the match is loose"; fi

  fake codegraph "1.4.9"
  RC=$(present codegraph 1.5.0)
  if [ "$RC" != 0 ]; then ok; else bad "B: a DIFFERENT version must be rc non-zero (the image is stale and must be re-installed over)"; fi

  # semgrep prints more than a bare number; the pin has to be found inside the
  # line the tool actually emits, which is why this fixture is shaped like it.
  fake semgrep "1.176.1"
  RC=$(present semgrep 1.176.1)
  if [ "$RC" = 0 ]; then ok; else bad "B: semgrep 1.176.1 must satisfy its own pin (rc=$RC): $(cat "$T/p.out")"; fi

  RC=$(present definitely-not-a-tool 1.0.0)
  if [ "$RC" != 0 ]; then ok; else bad "B: an ABSENT command must be rc non-zero"; fi

  # A tool on PATH whose --version FAILS is a broken install, not a present
  # one: reporting it present skips the reinstall that would have fixed it.
  fake brokentool "boom" 3
  RC=$(present brokentool 1.0.0)
  if [ "$RC" != 0 ]; then ok; else bad "B: a command whose --version exits nonzero must be rc non-zero"; fi

  # No pin = presence only. That is the apt half (shellcheck, age, zstd), where
  # the image carries whatever trixie ships and there is nothing to pin.
  fake shellcheck "version: 0.9.0"
  RC=$(present shellcheck)
  if [ "$RC" = 0 ]; then ok; else bad "B: with no pin, a present command must be rc 0 (rc=$RC): $(cat "$T/p.out")"; fi
  RC=$(present definitely-not-a-tool)
  if [ "$RC" != 0 ]; then ok; else bad "B: with no pin, an absent command must be rc non-zero"; fi

  # Misuse is rc 2, never 0: a helper that answered "present" to a call with no
  # arguments would skip every install in the workflow.
  RC=$(present)
  if [ "$RC" = 2 ]; then ok; else bad "B: no arguments must be rc 2 (usage), got rc=$RC"; fi
  case "$(cat "$T/p.out")" in
    *usage*) ok ;;
    *) bad "B: the usage refusal must say usage: $(cat "$T/p.out")" ;;
  esac

  # It must never write anything anywhere; it is called in a loop in CI.
  RC=$(present shellcheck)
  if [ "$RC" = 0 ]; then ok; else bad "B: repeat call changed its answer"; fi
fi

# ── C. the workflow calls the helper, with the pin it installs ──────────────
# Comment lines are stripped first: the steps explain themselves at length and
# an assertion that reads the prose is an assertion about nothing. Backslash
# continuations are then JOINED, because `guard \` / `|| install` is one command
# and a line-wise reader would call the second half unguarded — the assertion
# has to see what runs, not how it was wrapped to fit.
CODE=$(grep -v '^[[:space:]]*#' "$WF" | awk '
  { line = $0
    sub(/^[[:space:]]+/, "", line)
    if (held != "") { line = held " " line; held = "" }
    if (line ~ /\\$/) { sub(/[[:space:]]*\\$/, "", line); held = line; next }
    print line }
  END { if (held != "") print held }')

case "$CODE" in
  *"ci-tool-present.sh"*) ok ;;
  *) bad "C: no job calls bin/ci-tool-present.sh — the installs are not guarded" ;;
esac

# Every pinned install names the same version its guard checks for.
pin_pair() { # pin_pair <tool> <install-substring>
  local tool="$1" needle="$2" guard install
  guard=$(printf '%s\n' "$CODE" | sed -n "s|.*ci-tool-present\.sh $tool \([0-9][0-9.]*\).*|\1|p" | LC_ALL=C sort -u)
  install=$(printf '%s\n' "$CODE" | sed -n "s|.*$needle\([0-9][0-9.]*\).*|\1|p" | LC_ALL=C sort -u)
  if [ -n "$guard" ]; then ok; else bad "C: no 'ci-tool-present.sh $tool <version>' guard in the workflow"; return; fi
  if [ -n "$install" ]; then ok; else bad "C: no '$needle<version>' install line in the workflow"; return; fi
  if [ "$guard" = "$install" ]; then ok
  else bad "C: the $tool guard checks for '$guard' but the install pins '$install' — the guard can never be true"; fi
}
pin_pair codegraph '@colbymchenry/codegraph@'
pin_pair semgrep 'semgrep=='

# PEP 668 IS ASKED, NOT ASSUMED — and that is the whole point of the switch.
# An externally-managed python (the Fly image) refuses a bare `pip install`;
# a python without the flag (an older hosted pip) refuses the flag itself. A
# step that hard-codes either answer works on exactly one fleet, and CI_RUNNER
# can point at the other between one run and the next.
if grep -q 'pip install' <<<"$CODE"; then
  case "$CODE" in
    *"pip install --help"*) ok ;;
    *) bad "C: a pip install with no capability probe — it assumes one fleet's python" ;;
  esac
  case "$CODE" in
    *--break-system-packages*) ok ;;
    *) bad "C: no --break-system-packages path — the externally-managed fleet cannot install" ;;
  esac
  # …and a path WITHOUT the flag has to exist too, or the probe decides nothing.
  BARE=$(printf '%s\n' "$CODE" | grep 'pip install' | grep -v -- '--break-system-packages' | grep -vc -- '--help')
  if [ "$BARE" -ge 1 ]; then ok
  else bad "C: every pip install passes --break-system-packages — the probe has no else branch, so a pip without the flag fails"; fi
else
  ok; ok; ok
fi

# No apt-get install runs unguarded. The image already has these packages, and
# an unguarded install on a runner with empty package lists fails with
# "Unable to locate package" — which is a red CI job for a tool that was there.
#
# Scoped to the STEP, not the line: the guard is an `if` whose body is the
# install, so a line-wise reader would call every one of them unguarded. The
# step is the smallest unit that is honestly one script.
UNGUARDED=$(printf '%s\n' "$CODE" | awk '
  /^- name:/ || /^- uses:/ { if (apt && !guard) print name; name = $0; apt = 0; guard = 0; next }
  /apt-get install/ { apt = 1 }
  /ci-tool-present\.sh/ { guard = 1 }
  END { if (apt && !guard) print name }')
if [ -z "$UNGUARDED" ]; then ok
else bad "C: step(s) that apt-get install with no ci-tool-present.sh guard:
$UNGUARDED"; fi
# …and the reader itself is not vacuous: it must have SEEN the installs it just
# graded. An awk that matched nothing reports "all guarded" forever.
#
# THE THRESHOLD WAS 2 AND IS NOW 1 (BH-1200), which is a change to this
# assertion and so is stated rather than quietly made. It was never a rule that
# the workflow must apt-install two things; it is an anti-vacuity guard on the
# awk above it. There were two installs when it was written — `shellcheck` and
# `age zstd` — and BH-1200 replaced the shellcheck one with a pinned, sha256-
# verified download in bin/ci-shellcheck.sh, so one remains. One install still
# gives the reader something to grade, which is the whole intent; leaving the
# threshold at 2 would have meant keeping an apt call the ticket removed on
# purpose. That no apt install of shellcheck comes back is asserted positively,
# in tests/ci-shellcheck-cache.bh-1200-test.sh, rather than implied here.
APT=$(printf '%s\n' "$CODE" | grep -c 'apt-get install')
if [ "$APT" -ge 1 ]; then ok
else bad "C: only $APT apt-get install line(s) found — the guard check graded nothing"; fi

# THE SHARD LANES PIN NODE. This is not tidiness — it is the one thing the move
# to the bh-ci image actually broke. tests/repro-gate-test.sh shells out to
# `node --experimental-strip-types` (node >= 22.6); GitHub-hosted happened to
# ship a new enough node, the image ships 20, and the first run on the pool
# failed three assertions in that suite. It fails identically on main against
# node 20, which is how you know the lane had an undeclared runtime dependency
# rather than a regression. A pin that is silently dropped puts it straight
# back, on a machine nobody is looking at.
for J in tests-shard; do
  B=$(job_block "$J")
  case "$B" in
    *"actions/setup-node@v4"*) ok ;;
    *) bad "C: '$J' must pin node with actions/setup-node — the image ships 20 and a suite needs >= 22.6" ;;
  esac
  V=$(printf '%s\n' "$B" | sed -n "s|^ *node-version: '\\([0-9][0-9]*\\)'|\\1|p" | head -1)
  if [ -n "$V" ] && [ "$V" -ge 22 ]; then ok
  else bad "C: '$J' pins node-version '${V:-<none>}' — it must be 22 or newer"; fi
done

# The capability flags the sharded suites depend on must survive the move.
case "$CODE" in
  *CODEGRAPH_REQUIRED=1*) ok ;;
  *) bad "C: CODEGRAPH_REQUIRED=1 disappeared from the decisions shards" ;;
esac
case "$CODE" in
  *SEMGREP_REQUIRED=1*) ok ;;
  *) bad "C: SEMGREP_REQUIRED=1 disappeared from the decisions shards" ;;
esac

echo "harness-ci-runners.bh-1206-test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
