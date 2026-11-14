# shellcheck shell=bash
# bin/lib/defer-top.sh — BH-9426: the current top deferral files, as one line
# for the planner prompt. Sourced, never run; sourcing defines functions only.
#
# The list is bin/defer-report.sh's own output, state/defer-report/<project>-top.txt
# (one path per line, written daily by the defer-report lane), never a literal.
#
# defer_top_line <project> <harness-root>
#   prints "FILES TO STAY OUT OF UNLESS THE TICKET IS ABOUT THEM (top <n>
#   deferral files, from bin/defer-report.sh at <mtime>): a, b, ..." when the
#   file is present, non-empty and not older than DEFER_TOP_MAX_AGE_H hours
#   (default 48, row: lib.defer-top DEFER_TOP_MAX_AGE_H); otherwise nothing.
#   rc 1 with no root or no project (no literal root default, D43).
#   DEFER_TOP_NOW is the clock seam for tests.
defer_top_line() {
  local p="${1:-}" root="${2:-${HARNESS:-${H:-}}}" f age max now mt list n
  [ -n "$p" ] && [ -n "$root" ] || return 1
  f="$root/state/defer-report/$p-top.txt"
  [ -s "$f" ] || return 0
  command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply defer-top >/dev/null 2>&1
  max="${DEFER_TOP_MAX_AGE_H:-48}"   # row: lib.defer-top DEFER_TOP_MAX_AGE_H
  case "$max" in ''|*[!0-9]*) max=48 ;; esac
  now="${DEFER_TOP_NOW:-$(date -u +%s)}"
  mt=$(stat -c %Y "$f" 2>/dev/null) || return 0
  age=$((now - mt))
  [ "$age" -le $((max * 3600)) ] || return 0
  list=$(awk 'NF' "$f" | paste -sd, - | sed 's/,/, /g')
  [ -n "$list" ] || return 0
  n=$(awk 'NF' "$f" | wc -l)
  printf 'FILES TO STAY OUT OF UNLESS THE TICKET IS ABOUT THEM (top %d deferral files, from bin/defer-report.sh at %s): %s\n' \
    "$n" "$(date -u -d "@$mt" '+%Y-%m-%dT%H:%M:%SZ')" "$list"
}
