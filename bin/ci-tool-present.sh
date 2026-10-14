#!/bin/bash
# bin/ci-tool-present.sh — "is this tool already on the image, at the pin we
# want?" One answer, used by every install step in .github/workflows/harness-ci.yml.
#
#   ci-tool-present.sh <command>              present?  (rc 0 = yes)
#   ci-tool-present.sh <command> <version>    present AND at exactly that version?
#   ci-tool-present.sh --python-module <name> can python3 import it?  (BH-1741)
#
# The module form is presence-only, like the apt tools: PyYAML arrives as apt
# `python3-yaml`, whose version is whatever the base image ships. It exists
# because a python library is not a command, so `command -v` cannot see it —
# and the mergify-template suites skipped in CI for want of exactly that one.
#
# WHY (BH-1206). Where CI runs is the `CI_RUNNER` repo variable, so a job may
# land on the Fly `bh-ci` image — which bakes in codegraph 1.5.0, semgrep
# 1.176.1, ShellCheck, age, zstd, actionlint and node 22 — or on a GitHub-hosted
# image that carries almost none of it, between one run and the next. Re-running
# `npm install -g` and `pip install` where the tool is already present is a
# minute of nothing per job; DELETING the install breaks the fleet that needs
# it. So each step keeps its install and guards it: install only when this
# script says the tool is not already there. Neither fleet is assumed.
#
# THE MATCH IS EXACT, NEVER A PREFIX. `1.5.0` must not be satisfied by `1.5.01`
# and `1.5` must not be satisfied by `1.5.0`: a loose match reports the pin
# satisfied by a version nobody pinned, and the install that would have fixed it
# never runs. The version is matched as a whole token in the tool's own
# `--version` output — that output carries prose and a program name around the
# number (`semgrep 1.176.1`, `ShellCheck - shell script analysis tool version:
# 0.9.0`), so the number is looked for inside the line rather than compared to
# the whole of it.
#
# THREE OUTCOMES, NEVER TWO:
#   rc 0   the tool is on PATH (and, when a pin was given, reports that pin)
#   rc 1   it is absent, its --version failed, or it reports a different version
#          — all three mean "install it", which is the only thing the caller does
#   rc 2   misuse (no command named, or a module name that is not a dotted
#          python identifier — the name is interpolated into python source, so
#          anything else is refused before python3 sees it). NEVER 0: a helper
#          that answered "present" to a call it did not understand would switch
#          off every install in the workflow at once, and the jobs would fail
#          later, somewhere else.
#
# It writes nothing, reads no network and takes no argument from the environment.
# tests/harness-ci-runners.bh-1206-test.sh runs it against fake tools on PATH.
set -uo pipefail

if [ "${1:-}" = --python-module ]; then
  MOD="${2:-}"
  if [ $# -ne 2 ] || ! [[ "$MOD" =~ ^[A-Za-z_][A-Za-z0-9_.]*$ ]]; then
    echo "usage: ci-tool-present.sh --python-module <module-name>" >&2
    exit 2
  fi
  command -v python3 >/dev/null 2>&1 || {
    echo "ci-tool-present: python3 is not on PATH, so module $MOD is not importable"
    exit 1
  }
  if python3 -c "import $MOD" >/dev/null 2>&1; then
    echo "ci-tool-present: python3 module $MOD is importable"
    exit 0
  fi
  echo "ci-tool-present: python3 module $MOD is not importable"
  exit 1
fi

CMD="${1:-}"
PIN="${2:-}"

if [ -z "$CMD" ] || [ $# -gt 2 ]; then
  echo "usage: ci-tool-present.sh <command> [<pinned-version>]" >&2
  exit 2
fi

command -v "$CMD" >/dev/null 2>&1 || {
  echo "ci-tool-present: $CMD is not on PATH"
  exit 1
}

# Presence only: nothing to pin (the apt packages, whose version is whatever
# the base image ships).
if [ -z "$PIN" ]; then
  echo "ci-tool-present: $CMD is on PATH"
  exit 0
fi

OUT=$("$CMD" --version 2>&1)
RC=$?
if [ "$RC" != 0 ]; then
  # On PATH but unable to say what it is: a half-installed tool, which is the
  # 2026-09-10 semgrep wheel's exact shape. Reinstall over it.
  echo "ci-tool-present: $CMD --version exited $RC — treating it as absent"
  exit 1
fi

# Whole-token match: the pin must be bounded by something that is not a version
# character on both sides, so 1.5.0 does not match inside 1.5.01 or 11.5.0.
if grep -qE "(^|[^0-9.])$(printf '%s' "$PIN" | sed 's/\./\\./g')([^0-9.]|$)" <<<"$OUT"; then
  echo "ci-tool-present: $CMD is already at $PIN"
  exit 0
fi

echo "ci-tool-present: $CMD is on PATH but not at $PIN (it reports: $(head -1 <<<"$OUT"))"
exit 1
