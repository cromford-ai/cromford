#!/bin/bash
# bin/fly-boot-env-check.sh — BH-9265: prove that no process on one Fly
# machine holds an HBUNDLE_* or SEED_* app secret in its environment.
#
# Usage: bin/fly-boot-env-check.sh <app> <machine-id>
#
# READ-ONLY. One `fly ssh console -C` on the machine. It creates, stops and
# destroys nothing. The remote scan reads every /proc/<pid>/environ and prints
# NAMES ONLY (`cut -d= -f1`), never a value:
#   hit <pid> <comm> <NAME>   one line per HBUNDLE_*/SEED_* name in a process
#   ps -eo pid,ppid,comm      the process table, so pid 1 and tailscaled show
#   scanned <n>               the number of processes read
# The scan runs under `env -i` and skips its own shell, so the check does not
# report itself.
#
# Exit 0  the `scanned` line arrived and 0 hits (prints `clean: <n> processes`).
# Exit 1  one or more hits (prints them).
# Exit 2  usage error, fly failed, or no `scanned` line (`could-not-run: <why>`).
#         A missing `scanned` line is never read as clean.
#
# FLY_BIN (default `fly`) is the flyctl binary; the tests set a stub.
set -uo pipefail

usage() { echo "usage: bin/fly-boot-env-check.sh <app> <machine-id>" >&2; exit 2; }
[ $# -eq 2 ] && [ -n "$1" ] && [ -n "$2" ] || usage
APP=$1; MID=$2
FLY_BIN="${FLY_BIN:-fly}"

# One line, no single quote: it rides inside `/bin/sh -c <printf %q>`.
# shellcheck disable=SC2016  # expanded on the machine, not here
SCAN='n=0; for f in /proc/[0-9]*/environ; do [ -r "$f" ] || continue; p=${f%/environ}; p=${p##*/}; [ "$p" = "$$" ] && continue; c=$(cat /proc/$p/comm 2>/dev/null); for k in $(tr "\0" "\n" < "$f" 2>/dev/null | cut -d= -f1 | grep -E "^(HBUNDLE_|SEED_)"); do echo "hit $p $c $k"; done; n=$((n+1)); done; ps -eo pid,ppid,comm 2>/dev/null; echo "scanned $n"'

OUT=$("$FLY_BIN" ssh console -a "$APP" --machine "$MID" -C "env -i /bin/sh -c $(printf '%q' "$SCAN")" 2>&1)
RC=$?
if [ "$RC" -ne 0 ]; then
  echo "could-not-run: fly ssh console rc $RC: $(printf '%s' "$OUT" | tail -1)"
  exit 2
fi
N=$(printf '%s\n' "$OUT" | sed -n 's/^scanned \([0-9][0-9]*\)$/\1/p' | tail -1)
if [ -z "$N" ]; then
  echo "could-not-run: no scanned line from $APP/$MID"
  exit 2
fi
printf '%s\n' "$OUT" | grep -v '^hit ' | grep -v '^scanned '
HITS=$(printf '%s\n' "$OUT" | grep '^hit ' || true)
if [ -n "$HITS" ]; then
  printf '%s\n' "$HITS"
  echo "seed names found: $(printf '%s\n' "$HITS" | wc -l) in $N processes on $APP/$MID"
  exit 1
fi
echo "clean: $N processes on $APP/$MID, no HBUNDLE_ or SEED_ name"
exit 0
