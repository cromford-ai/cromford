#!/bin/bash
# bin/lib/remote-gate-fly-rsh.sh — rsync's remote shell for bin/remote-gate.sh
# on the fly-ssh transport (BH-8335). rsync runs it as
#   remote-gate-fly-rsh.sh [-l <user>] <host> rsync --server <args…>
# and this runs `rsync --server <args…>` on the test host through
#   flyctl ssh console -a $TESTHOST_APP -q -C "<the command>"
# with the app-scoped SSH token the pool route put in FLY_API_TOKEN.
#
# IT VALIDATES EVERY ARGUMENT, because the command reaches a root shell on the
# shared host. It refuses (exit 2, one line, nothing run):
#   - a TESTHOST_APP that is not a Fly app name ([a-z0-9-]+);
#   - an option before the host other than `-l root`;
#   - a host other than localhost or root@localhost (remote-gate's own name);
#   - a command that is not `rsync --server`;
#   - an argument with a character outside [A-Za-z0-9._/=,+:-]. Fly's ssh
#     server splits the command on spaces and execs it with no shell, so these
#     are the only characters that keep one argument one argument.
set -uo pipefail
refuse() { echo "remote-gate-fly-rsh: refused: $*" >&2; exit 2; }
app="${TESTHOST_APP:-}"
case "$app" in ''|*[!a-z0-9-]*) refuse "TESTHOST_APP '$app' is not a Fly app name" ;; esac
if [ "${1:-}" = -l ]; then
  [ "${2:-}" = root ] || refuse "user '${2:-}' (only root)"
  shift 2
fi
case "${1:-}" in
  localhost|root@localhost) shift ;;
  *) refuse "host '${1:-}' (only localhost)" ;;
esac
[ "${1:-}" = rsync ] && [ "${2:-}" = --server ] || refuse "command '${1:-} ${2:-}' (only rsync --server)"
for a in "$@"; do
  case "$a" in ''|*[!A-Za-z0-9._/=,+:-]*) refuse "argument '$a'" ;; esac
done
exec env -u FLY_ACCESS_TOKEN flyctl ssh console -a "$app" -q -C "$*"
