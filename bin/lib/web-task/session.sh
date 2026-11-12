#!/bin/bash
# bin/lib/web-task/session.sh — a seam of the web-task lane (BH-7594, slice S1).
#
# Keep a signed-in browser session between runs.
#   wt_session_load <project> <site>     -> a storage-state file path
#   wt_session_save <project> <site> <file>
#
# wt_session_save is wsess_save of bin/lib/web-session.sh (the same arguments
# and return codes). bin/web-task.sh calls it after a done run that signed in
# (S4 R1b, BH-9577). This file sources web-session.sh on the first call when
# wsess_save is not defined; when that source fails, it prints "not available"
# and returns 69 (EX_UNAVAILABLE).
#
# wt_session_load is still a stub: it prints "not available" and returns 69.
# Defines functions only; nothing runs on source.
# shellcheck shell=bash

wt_session_load() { echo "not available"; return 69; }

wt_session_save() {
  if ! declare -F wsess_save >/dev/null; then
    # shellcheck source=bin/lib/web-session.sh
    . "$(dirname "${BASH_SOURCE[0]}")/../web-session.sh" >/dev/null 2>&1 && declare -F wsess_save >/dev/null \
      || { echo "not available"; return 69; }
  fi
  wsess_save "$@"
}
