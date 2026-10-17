#!/bin/bash
# bin/fly-onboard.sh <project> [--cap N] — put ONE project on the Fly builder
# pool, from the hub, idempotently (BH-662).
#
# WHAT IT IS. A wrapper over bin/fly-pool-rollout.sh, which already does the
# work: mint the org token, ensure builder-<p>/pool-<p>, rebake the image, run a
# real SMOKE on a real pool machine, and flip flags/fly-pool-<p> +
# flags/builder-fly-<p> ONLY on SMOKE_OK. Nothing here writes a routing flag.
# That is the safety property: "stamped routed without a green probe" is
# impossible by construction, because the only code that writes those files is
# the code that ran the probe.
#
# WHY A WRAPPER AT ALL. The rollout is a one-shot with a three-project default,
# it always exits 0 (set -uo pipefail, every failure is `say …; continue`), and
# it says nothing an operator can read back. Onboarding a project was therefore
# a shell session someone had to be on the hub to run and had to interpret by
# tailing a log. This gives it one entry point with one answer: a verdict line
# naming both flag files and what bin/free-slots.sh says about the project, and
# ONE ALERTS line when it did not work.
#
# HUB ONLY, AND IT FAILS CLOSED. It mints org tokens out of the hub's flyctl
# session auth and writes hub-side routing flags, so a run anywhere else is
# refused before any flyctl call — and if bin/lib/hub-box.sh is not readable it
# refuses too, rather than assuming. That is the opposite of the build guards,
# which fail OPEN on a missing lib so a box mid-sync keeps building; here the
# cost of a wrong "yes" is org credentials and fleet routing, not a build.
#
# THE TWO CHANNELS THAT REACH THE HUB (docs/OPERATOR-SETUP.md, "Reaching the hub
# without ssh"):
#   1. the repo — `bin/load-project.sh <owner/repo> --fly`, or a line added by
#      hand to fly/onboard-queue.conf and merged. bin/fleet-propagate.sh (*/5)
#      syncs it to the hub and bin/fly-pool-tick.sh (*/10) drains it by running
#      this script there.
#   2. the console `chat` command addressed to the orchestrator, from which this
#      is a one-line operation.
#
# Verdict, one line, on stdout AND in logs/fly-pool-rollout.log:
#   FLY_ONBOARD <p> OK|ALREADY|FAILED: <flags/fly-pool-p>=… <flags/builder-fly-p>=… free-slots="…"
# Exit: 0 OK/ALREADY, 1 FAILED, 2 usage/unknown project, 3 refused (not the hub).
#
# CONSOLE SECRET (BH-7196). On OK and ALREADY it also runs
# bin/console-fly-secrets.sh --project <p>, which puts FLY_API_TOKEN_<P> on the
# console worker. A failure there writes ONE "[fly-onboard] <p>: console secret"
# ALERTS line and changes neither the verdict nor the exit code.
set -uo pipefail
H="${HARNESS:-/root/harness}"
LOG="$H/logs/fly-pool-rollout.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
mkdir -p "$H/logs" "$H/locks" 2>/dev/null

usage() {
  echo "usage: fly-onboard.sh <project> [--cap N]   (N = a positive integer)" >&2
  exit 2
}

# ── 1. arguments ─────────────────────────────────────────────────────────────
# REFUSE, NEVER CLAMP (D11). --cap 0 is the spelling of "unlimited" in
# bin/pool-cap.sh's OUTPUT, not in its input, and a typo that silently became
# "no ceiling" on a billable resource is the one mistake worth an exit code.
P=""; CAP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cap) [ $# -ge 2 ] || usage
           case "$2" in ''|0|0*|*[!0-9]*) usage ;; esac
           CAP="$2"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    --*) usage ;;
    *) [ -z "$P" ] || usage; P="$1"; shift ;;
  esac
done
[ -n "$P" ] || usage
# A name that needed cleaning is a name we refuse: everything downstream builds
# file paths and an app name out of it.
[ "$P" = "$(printf %s "$P" | tr -dc 'A-Za-z0-9._-')" ] || usage

say()  { printf '%s\n' "$*"; printf '%s [fly-onboard/%s] %s\n' "$(STAMP)" "$P" "$*" >> "$LOG"; }
saye() { printf '%s\n' "$*" >&2; printf '%s [fly-onboard/%s] %s\n' "$(STAMP)" "$P" "$*" >> "$LOG"; }

# ── 2. hub guard — before anything Fly ───────────────────────────────────────
HB=""
for C in "$(dirname "$0")/lib/hub-box.sh" "$H/bin/lib/hub-box.sh"; do
  [ -r "$C" ] && { HB="$C"; break; }
done
if [ -z "$HB" ]; then
  saye "fly-onboard: refused: bin/lib/hub-box.sh missing — cannot prove this is the hub"
  exit 3
fi
# shellcheck source=bin/lib/hub-box.sh
. "$HB"
BOX=$(local_box_name)
if ! is_hub_box "$BOX"; then
  saye "refused on ${BOX:-unknown}: fly-onboard runs only on the hub ($(hub_box_name)): it mints org tokens from the hub's flyctl session and writes hub-side routing flags. Queue it instead: bin/load-project.sh <owner/repo> --fly, or add '$P' to fly/onboard-queue.conf and merge."
  exit 3
fi

# ── 3. registry ──────────────────────────────────────────────────────────────
if ! "$H/bin/fleet-conf.sh" --projects 2>/dev/null | grep -qxF "$P"; then
  saye "refused: '$P' is not a fleet.conf project — load it first (bin/load-project.sh <owner/repo>)"
  exit 2
fi

POOLF="$H/flags/fly-pool-$P"
BFLAG="$H/flags/builder-fly-$P"
APPF="$H/flags/fly-pool-app-$P"

cap_txt() { # how the pool cap RESOLVES for $P right now, never what we meant
  local n
  n=$("$H/bin/pool-cap.sh" "$P" 2>/dev/null | tr -dc '0-9')
  [ -n "$n" ] || { printf 'unknown'; return 0; }
  [ "$n" = 0 ] && { printf 'unlimited'; return 0; }
  printf '%s' "$n"
}

# VERDICT FROM DISK, NEVER FROM AN EXIT CODE (D9). Since BH-666 the rollout
# exits non-zero for ANY project it skipped, which says that something failed
# but not what — and for a multi-project pass, not even which project. The flags
# and the step log say both, so those stay the verdict.
verdict() { # verdict <OK|ALREADY|FAILED>
  local ps bs
  if [ -f "$POOLF" ]; then ps="present(cap $(cap_txt))"; else ps=absent; fi
  if [ -f "$BFLAG" ]; then bs=present; else bs=absent; fi
  say "FLY_ONBOARD $P $1: $POOLF=$ps $BFLAG=$bs free-slots=\"$("$H/bin/free-slots.sh" "$P" 2>/dev/null)\""
}

# The console worker reads FLY_API_TOKEN_<P> to list pool-<p>. The routing flags
# are already on disk, so this step can only cost an ALERTS line, never a route
# or an onboarding retry. Always returns 0.
console_secret() {
  local tv rc err
  tv="FLY_API_TOKEN_$(printf %s "$P" | tr '[:lower:].-' '[:upper:]__')"
  if [ ! -x "$H/bin/console-fly-secrets.sh" ]; then
    err="bin/console-fly-secrets.sh missing"; rc=127
  else
    err=$(HARNESS="$H" "$H/bin/console-fly-secrets.sh" --project "$P" 2>&1 >/dev/null); rc=$?
    if [ "$rc" = 0 ]; then say "console: $tv put on the console worker"; return 0; fi
  fi
  err=$(printf '%s' "$err" | tr '\n' ' ')
  HARNESS="$H" "$H/bin/alert-line.sh" "[fly-onboard] $P: console secret $tv NOT put (rc $rc): $err — onboarding still succeeded; the console machines view cannot see pool-$P until bin/console-fly-secrets.sh --apply runs on the hub"
  say "console: $tv NOT put (rc $rc): $err"
  return 0
}

# A project enrolled by a routing row (BH-1373) reads ALREADY below instead of
# spending a smoke machine: with the routing_rows knob on this derives the four
# files from the row. Knob off, no client, or any failure: the files as they are.
[ -x "$H/bin/jobs-client.sh" ] && HARNESS="$H" "$H/bin/jobs-client.sh" routing-sync "$P" >/dev/null 2>&1 || true

# ── 4. already routed ────────────────────────────────────────────────────────
# Both flags, by EXACT name — `alpha` must never read `alpha-2`'s routing as its
# own. The app flag is reported, not required: a project routed before that flag
# existed is still routed, and re-probing it would spend a machine to learn
# nothing.
if [ -f "$POOLF" ] && [ -f "$BFLAG" ]; then
  say "already fly-routed — nothing to spawn"
  [ -s "$APPF" ] || say "WARNING: flags/fly-pool-app-$P missing — the pool is reap-only until it names pool-$P"
  console_secret
  verdict ALREADY
  exit 0
fi

# ── 5. dedupe, never a queue (the operator, 2026-09-13) ──────────────────────────────
# One owner per key. A second run — the */2 drain racing an operator's hub shell
# — says so and leaves; it does not wait for the first to finish, because the
# first is a rollout that can take twenty minutes.
exec 9>"$H/locks/fly-onboard-$P.lock"
if ! flock -n 9; then
  say "another fly-onboard for $P is running (locks/fly-onboard-$P.lock held) — not starting a second"
  exit 0
fi

# ── 6. the rollout, for exactly ONE project ──────────────────────────────────
# The rollout loops over "$@"; passing one positional IS the isolation mechanism
# — no other project's token, apps, machines or flags are reachable from here.
LN0=$(wc -l 2>/dev/null < "$LOG" | tr -dc '0-9'); LN0="${LN0:-0}"
say "start (cap ${CAP:-unset → autoscale})"
POOL_CAP="${CAP:-}" HARNESS="$H" "$H/bin/fly-pool-rollout.sh" "$P" >/dev/null 2>&1

# ── 7. per-step outcomes ─────────────────────────────────────────────────────
# The rollout's own step log for THIS run: token, apps, image, smoke, flags.
NEW=$(tail -n "+$((LN0 + 1))" "$LOG" 2>/dev/null | grep -F "[$P]")
[ -n "$NEW" ] && printf '%s\n' "$NEW"

# ── 8. verdict ───────────────────────────────────────────────────────────────
if [ -f "$POOLF" ] && [ -f "$BFLAG" ]; then
  console_secret
  verdict OK
  exit 0
fi
STEP=$(printf '%s\n' "$NEW" | grep -E 'FAILED|skipping' | tail -1 | sed "s/^.*\[$P\] //")
[ -n "$STEP" ] || STEP="unknown step — see logs/fly-pool-rollout.log"
HARNESS="$H" "$H/bin/alert-line.sh" "[fly-onboard] $P onboarding FAILED at \"$STEP\" — no routing flag written, $P builds stay local; fix and re-run bin/fly-onboard.sh $P on the hub (logs/fly-pool-rollout.log)"
verdict FAILED
exit 1
