#!/bin/bash
# bin/lib/fly-token.sh — which Fly token a pool tick uses (BH-7107).
#
# fly_token_resolve <project> sets two globals and prints nothing, so a token
# never reaches stdout or a log line:
#   FLY_TOKEN_SRC  the NAME of the variable it took: FLY_API_TOKEN_<P> (the
#                  project-scoped token, upper case, `.` and `-` as `_`), else
#                  FLY_API_TOKEN (the org token the hub's fly.env carries), else
#                  empty.
#   FLY_TOKEN_VAL  its value, or empty.
# rc 0 when a token was found, rc 1 when neither is set.
#
# FLY_ACCESS_TOKEN is NEVER read. It is the variable flyctl authenticates with,
# and another project's call in the same shell (bin/fly-dispatch.sh exports it)
# can leave it set. A pool must not run on a token that was resolved for a
# different project.
#
# Before this lib, bin/fly-pool.sh read only FLY_API_TOKEN_<P>. A project with
# no scoped token exited 0 before the reap, with no line and no alert, and the
# job files of machines Fly no longer had held every slot (project-6-os,
# 2026-10-16). bin/lane-fleet.sh and bin/testhost-tick.sh already fell back to
# the org token.
fly_token_resolve() {
  local p="${1:-}" tv
  FLY_TOKEN_SRC=""; FLY_TOKEN_VAL=""
  [ -n "$p" ] || return 1
  tv="FLY_API_TOKEN_$(printf '%s' "$p" | tr '[:lower:].-' '[:upper:]__')"
  if [ -n "${!tv:-}" ]; then
    FLY_TOKEN_SRC="$tv"; FLY_TOKEN_VAL="${!tv}"; return 0
  fi
  if [ -n "${FLY_API_TOKEN:-}" ]; then
    FLY_TOKEN_SRC=FLY_API_TOKEN; FLY_TOKEN_VAL="$FLY_API_TOKEN"; return 0
  fi
  return 1
}
