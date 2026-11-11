#!/bin/bash
# bin/lib/docs-overlap.sh — a docs file never defers a build (BH-9096).
# Sourced, never executed. Defines functions only; safe under `set -u`.
#
# THE RULE. A path that ends in `.md` (lowercase, at any depth: docs/UI.md,
# docs/a/b/c.md, CLAUDE.md) is never an overlap that holds a build back. Two
# builds that add their own section to one markdown file are resolved at merge
# (bin/rebase-train.sh's md union, a fragment file), so a defer on it only
# serialises the repo behind its most boring file. Code files keep their rule:
# docs/UI.mdx, docs/UI.MD, README.md.ts and src/md are NOT docs paths.
#
# WHY A LIB. Six overlap paths judge a file list. Three of them read the
# OVERLAP_IGNORE glob list (bin/overlap-guard.sh, bin/overlap-schedule.sh,
# bin/sibling-serial.sh), whose default holds `*.md`; three never read it
# (bin/plan-overlap.sh, bin/plan-sibling.sh, bin/conflict-check.sh), and those
# printed `OVERLAP_DEFER ... files=[docs/UI.md,docs/UI.md]`. Those three use:
#   docs_overlap_on          rc 0 when the exemption is on
#   docs_overlap_path <p>    rc 0 when p is a docs path (a trailing / is dropped)
#   docs_overlap_pair "<p> ~ <q>"
#                            rc 0 when the exemption is on and EITHER side is a
#                            docs path (`docs ~ docs/UI.md` is a collision ON the
#                            md file; a code file under docs/ is its own pair)
#   docs_overlap_drop        stdin -> stdout without docs paths; passes all when off
#
# THE KNOB. The exemption is on when the resolved OVERLAP_IGNORE list (env ->
# settings row conf.scheduler.overlap_ignore -> flags/scheduler.conf -> the
# default below, bin/lib/scheduler-conf.sh) holds the bare `*.md` token. So one
# knob governs all six paths: an operator override without `*.md` puts the docs
# collision back everywhere (the BH-475 premise tests/overlap-schedule-test.sh
# pins). There is no separate switch.

# The documented default, the same string the three knob scripts pass.
DOCS_OVERLAP_IGNORE_DEFAULT='package.json package-lock.json *.md'

docs_overlap_on() {
  if [ -z "${_DOCS_OVERLAP_ON:-}" ]; then
    local list="$DOCS_OVERLAP_IGNORE_DEFAULT"
    if ! command -v sched_conf >/dev/null 2>&1; then
      # shellcheck source=bin/lib/scheduler-conf.sh
      . "$(dirname "${BASH_SOURCE[0]}")/scheduler-conf.sh" 2>/dev/null || :
    fi
    if command -v sched_conf >/dev/null 2>&1 && [ -n "${HARNESS:-${H:-}}" ]; then
      list=$(sched_conf OVERLAP_IGNORE "$DOCS_OVERLAP_IGNORE_DEFAULT" "${HARNESS:-${H:-}}" 2>/dev/null) \
        || list="$DOCS_OVERLAP_IGNORE_DEFAULT"
    fi
    # Matched as text, never split unquoted: `*.md` would glob the CWD.
    case " $(printf '%s' "$list" | tr -s ' \t' '  ') " in
      *" *.md "*) _DOCS_OVERLAP_ON=on ;;
      *) _DOCS_OVERLAP_ON=off ;;
    esac
  fi
  [ "$_DOCS_OVERLAP_ON" = on ]
}

docs_overlap_path() {
  local p="${1:-}"
  p="${p%/}"
  case "$p" in
    *.md) [ "$p" != .md ] ;;
    *) return 1 ;;
  esac
}

docs_overlap_pair() {
  local p="${1%% ~ *}" q="${1#* ~ }"
  docs_overlap_on || return 1
  docs_overlap_path "$p" || docs_overlap_path "$q"
}

docs_overlap_drop() {
  local f
  if ! docs_overlap_on; then cat; return 0; fi
  while IFS= read -r f || [ -n "$f" ]; do
    docs_overlap_path "$f" || printf '%s\n' "$f"
  done
  return 0
}
