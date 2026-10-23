#!/bin/bash
# bin/lib/pool-decide.sh — the pool tick decides its queued rows in parallel
# (BH-7706).
#
# A fly-pool.sh tick walks its queue and asks pool_spawn_decision of each row.
# The decision is mostly network reads (the hold thread, the issue events, the
# PR and queue reads), and the walk asked them one row at a time: on the hub a
# project-6-os tick decided 26 of 126 rows before POOL_TICK_BUDGET_S stopped it.
# This lib keeps the walk in the tick's shell and moves each decision into a
# background worker:
#   pdc_prime        once, before the walk: the reads that are the same for
#                    every row (the gates probe, the hold listing, the
#                    scheduler set, the jobs queue for `after` blockers, the
#                    sibling-serial tick cache). One `decide prime:` line.
#   pdc_start        start one worker for a row the walk reserved a slot for
#   pdc_collect      wait for one worker and act on its verdict: rc 0 calls
#                    pool_walk_spawn (fly-pool.sh) with the row, rc 1 frees
#                    the slot
#   pdc_drain        collect every worker still running
#   pdc_walk_line    the end-of-walk line: decided, spawned, not reached
# The worker runs pool_spawn_decision unchanged in a subshell, so every gate
# says the lines it said before. It writes one verdict file:
#   <PDC_ROOT>/v/<idx>.v   rc hits misses bad read_s gated pr_unreadable pr_code
# (tab-separated) through a temp name and mv. A worker that exits with no
# verdict file is a skip (one line); its row stays queued. pdc_collect adds the
# counters into the tick's _PHC_* so the one `hold cache:` line counts every
# row, and carries a PR read that did not answer (_POOL_PR_UNREADABLE, BH-7421)
# into the tick's shell, so every worker started after it reads no more PRs.
# THE FIRST ROW IS DECIDED ALONE. A serial walk always decided its first row,
# then applied the tick budget and the stop rule (BH-7421, BH-7475) before each
# later row, and its first unreadable PR read stopped PR reads for the tick.
# The walk keeps that: it waits for the first counted row's verdict before it
# starts the next worker. A hung GitHub then costs one row, as before, and
# never POOL_DECIDE_PARALLEL rows.
# The slots: the walk reserves a plain or a hotfix slot before it starts a
# worker (PDC_PEND_PLAIN, PDC_PEND_HOT), so the pool cap and the hotfix
# exemption hold as in a serial walk. The spawn itself stays in fly-pool.sh.
# POOL_DECIDE_PARALLEL (default 20, 1-64) bounds the workers that run at once;
# it never bounds spawns. 1 is the serial walk: one row decided, its spawn
# started, then the next row.
# The caller is fly-pool.sh: P, QDIR, HARNESS, LOG, say and the gate functions
# are its names. Root: ${HARNESS:-${H:-}} only (D43).
# shellcheck shell=bash

declare -A _PDC_PID=() _PDC_QSTATE=()
declare -a _PDC_HOT=() _PDC_JF=() _PDC_KEY=() _PDC_TICKET=() _PDC_ATT=() _PDC_SDTH=() _PDC_SSB=()
PDC_ROOT=""; PDC_DIR=""; PDC_PAR=20; PDC_N=0; PDC_Q=0; PDC_T0=""
PDC_DECIDED=0; PDC_NOVERDICT=0; PDC_PEND_PLAIN=0; PDC_PEND_HOT=0; PDC_BUDGET_N=0
PDC_STOP=""; _PDC_QOK=0; _PDC_QWHY=""
# wait -n -p (bash 5.1) answers the worker that finished; older bash waits for
# the oldest worker, which is slower and still correct.
_PDC_WAITN=0
{ [ "${BASH_VERSINFO[0]:-0}" -gt 5 ] || { [ "${BASH_VERSINFO[0]:-0}" = 5 ] && [ "${BASH_VERSINFO[1]:-0}" -ge 1 ]; }; } && _PDC_WAITN=1

# pdc_parallel — the effective POOL_DECIDE_PARALLEL: an integer 1-64, else 20
# with one line.
pdc_parallel() {
  local v="${POOL_DECIDE_PARALLEL:-20}"
  case "$v" in
    ''|*[!0-9]*) v=x ;;
    *) { [ "$v" -ge 1 ] && [ "$v" -le 64 ]; } 2>/dev/null || v=x ;;
  esac
  if [ "$v" = x ]; then
    say "POOL_DECIDE_PARALLEL=${POOL_DECIDE_PARALLEL:-} is not a number of workers (1-64) — using 20"
    v=20
  fi
  printf '%s\n' "$v"
}

# pdc_queue_prime — the jobs queue rows with status queued and claimed, once,
# into _PDC_QSTATE[<key>]. _PDC_QOK=1 only when both listings answered and
# neither filled its page: a full page (the worker clamps a page at 500) or a
# failed read proves nothing about a key that is absent, so pool_after_open
# then reads each blocker as before.
pdc_queue_prime() {
  local st out n k s
  _PDC_QOK=0; _PDC_QSTATE=()
  command -v queue_list >/dev/null 2>&1 || { _PDC_QWHY="off(no jobs client)"; return 1; }
  for st in queued claimed; do
    if ! out=$(queue_list "$P" "$st" "" "" 500 2>/dev/null); then
      _PDC_QSTATE=(); _PDC_QWHY="off($st listing did not answer)"; return 1
    fi
    n=$(grep -c . <<<"$out")
    if [ "$n" -ge 500 ]; then
      _PDC_QSTATE=(); _PDC_QWHY="off($st listing filled its page of 500)"; return 1
    fi
    while IFS=$'\t' read -r _ k _ s _; do
      [ -n "$k" ] && [ -n "$s" ] && _PDC_QSTATE[$k]="$s"
    done <<<"$out"
  done
  _PDC_QOK=1; _PDC_QWHY=ok
  return 0
}

# pdc_cleanup — removes this tick's temp dir. In the EXIT trap and at the end
# of the walk.
pdc_cleanup() {
  case "$PDC_ROOT" in
    */pool-decide.*) rm -rf -- "$PDC_ROOT" ;;
  esac
  PDC_ROOT=""; PDC_DIR=""
  unset SIBLING_TICK_DIR
  return 0
}

# pdc_prime — once per tick, in the tick's shell, before POOL_TICK_T0.
pdc_prime() {
  local files=() jf nafter=0 qtxt="off(no after rows)" stxt=off cur="" plain=0
  PDC_PAR=$(pdc_parallel)
  for jf in "$QDIR"/*.json; do
    [ -e "$jf" ] || continue
    case "$jf" in *.failed.json) ;; *) files+=("$jf") ;; esac
  done
  PDC_Q=${#files[@]}
  PDC_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/pool-decide.XXXXXX" 2>/dev/null) || PDC_ROOT=""
  if [ -n "$PDC_ROOT" ] && mkdir -p "$PDC_ROOT/v" 2>/dev/null; then
    PDC_DIR="$PDC_ROOT/v"
    cur=$(trap -p EXIT)
    if [ -n "$cur" ]; then eval "set -- $cur"; cur="${3:-}"; fi
    # shellcheck disable=SC2064 # the current trap text is meant to be fixed here
    trap "pdc_cleanup; $cur" EXIT
  else
    PDC_ROOT=""; PDC_DIR=""
  fi
  if [ "$PDC_Q" -gt 0 ]; then
    for jf in "${files[@]}"; do case "${jf##*/}" in RB-*|RR-*|LR-*|CP-*) ;; *) plain=1; break ;; esac; done
    if pool_gates_applicable; then
      # The ai-build issue listing, when a row has a GitHub issue number.
      if command -v phc_get >/dev/null 2>&1 && command -v hold_check >/dev/null 2>&1 \
         && jq -r '.ticket_id // empty' "${files[@]}" 2>/dev/null | grep -qE '^[0-9]+$'; then
        pool_hold_cache_knobs
        if [ "$_PHC_TTL" = 0 ]; then _POOL_HOLD_LIST=off; else pool_hold_list_prime; fi
      fi
      nafter=$(jq -r '.after // empty' "${files[@]}" 2>/dev/null | sort -u | grep -c .)
      if [ "${nafter:-0}" -gt 0 ]; then pdc_queue_prime; qtxt="$_PDC_QWHY"; fi
    elif [ "$plain" = 1 ] && [ -z "${_POOL_GATES_SAID:-}" ]; then
      # pool_spawn_decision's own line, said here once for every worker. NOT
      # "pool $P: ..." (tests/pool-autoscale-test.sh reads that prefix).
      say "$P spawn gates inactive: no repo slug, a gh client that cannot reach GitHub, or a repo no credential can see (that one also writes an ALERTS line naming the rungs) — HOLD/open-PR/terminal/cap checks not applied"
      _POOL_GATES_SAID=1
    fi
    if command -v sched_enforced >/dev/null 2>&1 && sched_enforced "$P"; then
      sched_ready_load "$P" >/dev/null 2>&1 || true
    fi
    if [ -n "$PDC_ROOT" ] && [ -x "$HARNESS/bin/sibling-serial.sh" ] && mkdir -p "$PDC_ROOT/sibling" 2>/dev/null; then
      export SIBLING_TICK_DIR="$PDC_ROOT/sibling"
      HARNESS="$HARNESS" SIBLING_QDIR="$QDIR" "$HARNESS/bin/sibling-serial.sh" prime "$P" 2>>"$LOG" && stxt=ok
    fi
  fi
  [ -n "$PDC_DIR" ] || say "decide: no temp dir for verdict files — rows are decided one at a time in this shell"
  say "decide prime: queue=$PDC_Q rows, after-blockers=${nafter:-0}, queue-list=$qtxt, sibling-cache=$stxt, parallel=$PDC_PAR"
  PDC_T0=$(date +%s)
  return 0
}

# pdc_worker <idx> <jf> <key> <ticket> — runs in the background (a subshell).
pdc_worker() {
  local rc t
  _POOL_ROWS_DECIDED=0; _PHC_HITS=0; _PHC_MISSES=0; _PHC_BAD=0; _PHC_READ_S=0; _PHC_GATED=0
  pool_spawn_decision "$2" "$3" "$4"; rc=$?
  t="$PDC_DIR/$1.v.tmp"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rc" "$_PHC_HITS" "$_PHC_MISSES" "$_PHC_BAD" "$_PHC_READ_S" "$_PHC_GATED" \
    "${_POOL_PR_UNREADABLE:-0}" "${_POOL_PR_UNREADABLE_CODE:-none}" > "$t" \
    && mv -f "$t" "$PDC_DIR/$1.v"
  exit "$rc"
}

# pdc_running — how many workers run now.
pdc_running() { printf '%s\n' "${#_PDC_PID[@]}"; }

# pdc_start <hot 0|1> <jf> <key> <ticket> <attempt> <deaths> <stack-base>
# The slot is reserved here. Without a verdict dir the row is decided in this
# shell, as the serial walk did.
pdc_start() {
  local i="$PDC_N" rc
  PDC_N=$((PDC_N + 1))
  _PDC_HOT[$i]="$1"; _PDC_JF[$i]="$2"; _PDC_KEY[$i]="$3"; _PDC_TICKET[$i]="$4"
  _PDC_ATT[$i]="$5"; _PDC_SDTH[$i]="$6"; _PDC_SSB[$i]="$7"
  case "$3" in RB-*|RR-*|LR-*|CP-*) ;; *) PDC_BUDGET_N=$((PDC_BUDGET_N + 1)) ;; esac
  if [ -z "$PDC_DIR" ]; then
    pool_spawn_decision "$2" "$3" "$4"; rc=$?
    PDC_DECIDED=$((PDC_DECIDED + 1))
    [ "$rc" = 0 ] && pdc_spawn "$i"
    return 0
  fi
  if [ "$1" = 1 ]; then PDC_PEND_HOT=$((PDC_PEND_HOT + 1)); else PDC_PEND_PLAIN=$((PDC_PEND_PLAIN + 1)); fi
  pdc_worker "$i" "$2" "$3" "$4" &
  _PDC_PID[$!]="$i"
  return 0
}

# pdc_collect — wait for one worker and act on its verdict. rc 1 = none running.
pdc_collect() {
  local w="" p i f rc=1 h=0 m=0 b=0 r=0 g=0 u=0 uc=none
  [ "${#_PDC_PID[@]}" -gt 0 ] || return 1
  if [ "$_PDC_WAITN" = 1 ]; then
    wait -n -p w "${!_PDC_PID[@]}" 2>/dev/null
  fi
  if [ -z "$w" ] || [ -z "${_PDC_PID[$w]:-}" ]; then
    w=""
    for p in "${!_PDC_PID[@]}"; do
      if [ -z "$w" ] || [ "${_PDC_PID[$p]}" -lt "${_PDC_PID[$w]}" ]; then w="$p"; fi
    done
    wait "$w" 2>/dev/null
  fi
  i="${_PDC_PID[$w]}"; unset "_PDC_PID[$w]"
  if [ "${_PDC_HOT[$i]}" = 1 ]; then PDC_PEND_HOT=$((PDC_PEND_HOT - 1)); else PDC_PEND_PLAIN=$((PDC_PEND_PLAIN - 1)); fi
  f="$PDC_DIR/$i.v"
  if [ -r "$f" ] && IFS=$'\t' read -r rc h m b r g u uc < "$f" && [[ "$rc" =~ ^[01]$ ]]; then
    case "$h$m$b$r$g" in *[!0-9]*|'') h=0; m=0; b=0; r=0; g=0 ;; esac
    _PHC_HITS=$((_PHC_HITS + h)); _PHC_MISSES=$((_PHC_MISSES + m)); _PHC_BAD=$((_PHC_BAD + b))
    _PHC_READ_S=$((_PHC_READ_S + r)); [ "$g" = 1 ] && _PHC_GATED=1
    if [ "$u" = 1 ] && [ "${_POOL_PR_UNREADABLE:-0}" != 1 ]; then
      _POOL_PR_UNREADABLE=1; _POOL_PR_UNREADABLE_CODE="${uc:-none}"
    fi
    PDC_DECIDED=$((PDC_DECIDED + 1))
  else
    say "decide worker for ${_PDC_KEY[$i]} wrote no verdict — skipped this tick"
    PDC_NOVERDICT=$((PDC_NOVERDICT + 1)); rc=1
  fi
  rm -f "$f"
  [ "$rc" = 0 ] && pdc_spawn "$i"
  return 0
}

# pdc_spawn <idx> — the row's spawn, through fly-pool.sh's pool_walk_spawn.
pdc_spawn() {
  pool_walk_spawn "${_PDC_HOT[$1]}" "${_PDC_JF[$1]}" "${_PDC_KEY[$1]}" "${_PDC_TICKET[$1]}" \
    "${_PDC_ATT[$1]}" "${_PDC_SDTH[$1]}" "${_PDC_SSB[$1]}"
}

# pdc_drain — collect every worker still running.
pdc_drain() { while pdc_collect; do :; done; return 0; }

# pdc_walk_line <rows-not-reached> — the end-of-walk line; PDC_STOP names why
# the walk ended early (budget, stop, cap), empty when it reached every row.
pdc_walk_line() {
  local left="${1:-0}" s=0
  [ -n "$PDC_T0" ] && s=$(( $(date +%s) - PDC_T0 ))
  say "decided $PDC_DECIDED of $PDC_Q queued rows in ${s}s (parallel $PDC_PAR); spawn started $((LAUNCHED + HOT_LAUNCHED)); not reached $left${PDC_STOP:+ ($PDC_STOP)}; no verdict $PDC_NOVERDICT"
}
