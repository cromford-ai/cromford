#!/bin/bash
# bin/signal-env-install.sh <project> <NAME>   (the value on stdin)
#
# BH-9799: install ONE signal key (a Sentry token, a PostHog key, or one of
# their non-secret companions) into env/<project>.env on this box. This is the
# env install path for the hub copy of a key whose first home is a project box
# (docs/KEY-ROTATION.md).
#
#   printf '%s' "$VALUE" | bin/signal-env-install.sh project-6-os SENTRY_MK_API_TOKEN
#
# Refused with exit 2, before anything is touched (the message names the key,
# never the value): a project with no fleet.conf row (FLEET_CONF or
# $H/fleet.conf), a NAME outside ^[A-Z][A-Z0-9_]{0,63}$, an empty value, more
# than one line, a value outside ^[A-Za-z0-9_./:@+=-]+$.
#
# Under locks/harden-state.lock (flock -w SIGNAL_ENV_INSTALL_LOCK_WAIT_S):
#   1. bin/harden-state.sh --release env/<project>.env (when the file exists);
#   2. a temp file with every other line kept and NAME=<value> last, chmod 600,
#      mv over the env file;
#   3. bin/harden-state.sh --rearm env/<project>.env, always (a trap runs it on
#      a failure too).
# Then one line: `installed <NAME> for <project> (value not shown)`. Any
# failure after the lock is exit 1 with one stderr line. The value goes only
# through printf into the file: never an argv, stdout, stderr or a log.
#
# Knob: SIGNAL_ENV_INSTALL_LOCK_WAIT_S (catalog/lanes.d/_lib.signal-env-install.json),
# applied with lib_env_apply signal-env-install.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/env-path.sh
. "$SELF/lib/env-path.sh" || { echo "signal-env-install: bin/lib/env-path.sh missing" >&2; exit 1; }
# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
{ command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply signal-env-install; } >/dev/null 2>&1 || true

refuse() { echo "signal-env-install: refused: $1; nothing written" >&2; exit 2; }
[ $# -eq 2 ] || refuse "usage: signal-env-install.sh <project> <NAME> (the value on stdin)"
P=$1; N=$2
[[ $P =~ ^[a-z0-9-]+$ ]] || refuse "project name '$P' is not [a-z0-9-]"
FC="${FLEET_CONF:-$H/fleet.conf}"
awk -v p="$P" 'NF && $1 !~ /^#/ && $1 == p {f=1} END {exit !f}' "$FC" 2>/dev/null \
  || refuse "no fleet.conf row for project $P"
[[ $N =~ ^[A-Z][A-Z0-9_]{0,63}$ ]] || refuse "the name $N is not ^[A-Z][A-Z0-9_]{0,63}\$"

V=$(cat; printf x); V=${V%x}
V=${V%$'\n'}
[ -n "$V" ] || refuse "the value for $N is empty"
case "$V" in *$'\n'*|*$'\r'*) refuse "the value for $N has more than one line" ;; esac
VAL_RE='^[A-Za-z0-9_./:@+=-]+$'
[[ $V =~ $VAL_RE ]] || refuse "the value for $N holds a character outside [A-Za-z0-9_./:@+=-]"

# Fallback: the default of the settings row lib.signal-env-install.signal_env_install_lock_wait_s.
WAIT="${SIGNAL_ENV_INSTALL_LOCK_WAIT_S:-30}"
if ! [[ $WAIT =~ ^[0-9]+$ ]] || [ "$((10#$WAIT))" -lt 1 ] || [ "$((10#$WAIT))" -gt 300 ]; then WAIT=30; fi

HENV=$(harness_env_dir "$H")
F="$HENV/$P.env"
HS="$H/bin/harden-state.sh"
mkdir -p "$H/locks" "$HENV" 2>/dev/null
exec 8>"$H/locks/harden-state.lock" || { echo "signal-env-install: cannot open locks/harden-state.lock" >&2; exit 1; }
flock -w "$WAIT" 8 || { echo "signal-env-install: locks/harden-state.lock held for ${WAIT}s; nothing written" >&2; exit 1; }

TMPF="$F.install.$$"
REARMED=0
rearm() {
  [ "$REARMED" = 1 ] && return 0
  REARMED=1
  if [ -x "$HS" ] && [ -e "$F" ]; then "$HS" --rearm "$F" >/dev/null 2>&1 || echo "signal-env-install: harden-state --rearm $P.env failed" >&2; fi
}
trap 'rm -f "$TMPF"; rearm' EXIT

if [ -e "$F" ] && [ -x "$HS" ]; then
  "$HS" --release "$F" >/dev/null 2>&1 || { echo "signal-env-install: harden-state --release $P.env failed; nothing written" >&2; exit 1; }
fi
if ! ( umask 077
       { if [ -e "$F" ]; then grep -v -E "^[[:space:]]*(export[[:space:]]+)?$N=" "$F" || [ "$?" = 1 ]; fi
         printf '%s=%s\n' "$N" "$V"
       } > "$TMPF" ); then
  echo "signal-env-install: could not write the new $P.env; nothing changed" >&2; exit 1
fi
chmod 600 "$TMPF" && mv -f "$TMPF" "$F" || { echo "signal-env-install: could not replace $P.env; nothing changed" >&2; exit 1; }
rearm
echo "installed $N for $P (value not shown)"
exit 0
