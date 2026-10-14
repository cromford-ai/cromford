#!/bin/bash
# bin/lib/gh-rest-auth.sh — the 401 stop of a merge-conductor worker (BH-6346).
# Sourced by bin/lib/gh-rest.sh behind a guarded line, never executed. Defining
# two functions is its only effect at source time.
#
# WHY. A 1 h App installation token can expire inside a long conductor tick (one
# cromford tick ran 2909 s). After that every read answers HTTP 401, and a
# worker went on sending them, each one another 401, until its deadline killed
# it. A 401 does not cure itself inside a tick.
#
# THE MARKER. mc_worker_bounded (bin/lib/fanin.sh) points GH_REST_AUTH_FAIL_FILE
# at <deadline mark>.auth, a plain shell variable that is never exported, so
# only that worker and its subshells see it. Outside a worker it is unset and
# both functions do nothing.
#   _gh_auth_observe   gh_rest calls it on a 401: it creates the marker. rc 0.
#   _gh_auth_gate      gh_rest calls it before a request: rc 1 when the marker
#                      exists, and gh_rest then answers 75, GH_REST_STATUS 401,
#                      GH_REST_REASON auth-skipped, with no request. rc 0
#                      otherwise.
# The gh() wrapper in bin/lib/gh-limit-logger.sh creates the same marker for a
# 401 on a call that does not go through gh_rest. mc_step reads it at the next
# step boundary and stops the worker.

_gh_auth_gate() {
  [ -n "${GH_REST_AUTH_FAIL_FILE:-}" ] && [ -e "$GH_REST_AUTH_FAIL_FILE" ] && return 1
  return 0
}

_gh_auth_observe() {
  [ -n "${GH_REST_AUTH_FAIL_FILE:-}" ] && : > "$GH_REST_AUTH_FAIL_FILE" 2>/dev/null
  return 0
}
