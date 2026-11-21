#!/usr/bin/env bash
# bin/lib/tsc-heap.sh — the Node heap (MB) a harness typecheck (`npx tsc`) runs at.
# Sourced by bin/lib/rb/pr.sh (the post-rebase verify), bin/rebase-train.sh and
# bin/pool-toolchain-probe.sh. Defines one function and runs nothing.
#
# rebase_tsc_heap [project] — echo "<MB> <source>", run with cwd = the repo checkout.
# A command substitution cannot hand a global back, so the source rides on the line.
# Order (BH-9435; BH-575 before it):
#   row       settings row lane.fly-pool.<project>.tsc_heap_mb (knob TSC_HEAP_MB on
#             the fly-pool lane, catalog/lanes.d/fly-pool.knobs.d/TSC_HEAP_MB.json),
#             read through lane_knob. 0 or not a number = no row. A row larger
#             than the RAM ceiling (the ram rule below) is cut to that ceiling,
#             with source `row-capped`: a heap past RAM is an OOM kill (exit 137),
#             not a pass. RAM unreadable: the row stands.
#   env       TSC_HEAP_MB from env/<project>.env (the operator's older knob).
#   ram       70% of RAM, capped at 12288 (bin/edit-feedback-hook.sh uses the same rule).
#   workflow  the largest --max-old-space-size the repo's .github/workflows declare,
#             used ONLY when it is larger than the ram rule, and still capped at 12288.
#             Before BH-9435 the workflow won over RAM: project-6's CI sets 6144, so a
#             16 GB pool machine ran tsc at 6144 and it aborted with exit 134 (TK-3772).
#   fallback  6144, the documented last fallback when /proc/meminfo is unreadable.
# TSC_HEAP_MEMINFO is a test seam (default /proc/meminfo).

# _tsc_heap_ram_ceiling — echo 70% of MemTotal in MB, capped at 12288; rc 1 and no
# output when /proc/meminfo (TSC_HEAP_MEMINFO) cannot be read. The one RAM rule the
# row cap and the ram branch share.
_tsc_heap_ram_ceiling() {
  local mem r
  mem=$(awk '/^MemTotal:/{printf "%d", $2/1024}' "${TSC_HEAP_MEMINFO:-/proc/meminfo}" 2>/dev/null)
  case "$mem" in ''|0|*[!0-9]*) return 1 ;; esac
  r=$(( mem * 7 / 10 )); [ "$r" -gt 12288 ] && r=12288
  echo "$r"
}

rebase_tsc_heap() {
  local p="${1:-${PROJECT:-}}" h="" src="" wf ramh cap=12288 lg self
  # The row. TSC_HEAP_MB is blanked for the read, so lane_knob's env fallback
  # cannot hand the env value back labelled as a row.
  if [ -n "$p" ]; then
    if command -v lane_knob >/dev/null 2>&1; then
      h=$(TSC_HEAP_MB='' lane_knob fly-pool TSC_HEAP_MB "$p" 2>/dev/null)
    else
      self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
      for lg in ${HARNESS:+"$HARNESS/bin/lib/lane-gate.sh"} "$self/lane-gate.sh"; do
        [ -r "$lg" ] || continue
        h=$( TSC_HEAP_MB=''; . "$lg" 2>/dev/null && lane_knob fly-pool TSC_HEAP_MB "$p" 2>/dev/null )
        break
      done
    fi
    case "$h" in ''|0|*[!0-9]*) h="" ;; *) src=row ;; esac
    if [ "$src" = row ] && ramh=$(_tsc_heap_ram_ceiling) && [ "$h" -gt "$ramh" ]; then
      h=$ramh; src=row-capped
    fi
  fi
  if [ -z "$h" ]; then
    case "${TSC_HEAP_MB:-}" in ''|0|*[!0-9]*) : ;; *) h="$TSC_HEAP_MB"; src=env ;; esac
  fi
  if [ -z "$h" ]; then
    if ramh=$(_tsc_heap_ram_ceiling); then src=ram
    else ramh=6144; src=fallback    # documented last fallback: RAM unreadable
    fi
    h=$ramh
    wf=$(grep -rhoE 'max-old-space-size=[0-9]+' .github/workflows/ 2>/dev/null | grep -oE '[0-9]+$' | sort -n | tail -1)
    if [ -n "$wf" ] && [ "$wf" -gt "$ramh" ]; then
      if [ "$wf" -gt "$cap" ]; then h=$cap; else h=$wf; src=workflow; fi
    fi
  fi
  echo "$h $src"
}
