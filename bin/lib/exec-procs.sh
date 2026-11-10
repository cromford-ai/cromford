# shellcheck shell=bash
# bin/lib/exec-procs.sh — BH-9288: the processes of an execute session.
# Sourced, never run. Defining functions is its only effect at source time.
#
# WHY. project-6-os TK-3659, 2026-11-09: the execute session started two vitest
# suites in the background and then ran the typecheck. The machine ran out of
# memory, the typecheck was killed (exit 137), and the stop reason said "Raise
# the row ... vm_memory_mb". The memory went to the concurrent processes, and
# the vitest workers lived on after the session.
#
# THE FUNCTIONS
#   ep_snapshot <dest> <signal>   writes <dest> (tmp + mv): line 1
#       `# oom-procs v1 at=<epoch> mem_total_kb=<n> signal=<sig>`, then TSV rows
#       `pid<TAB>rss_kb<TAB>comm<TAB>args`, largest rss first, at most
#       EXEC_OOM_SNAPSHOT_ROWS rows, args clipped to 160 chars and scrubbed by
#       bin/transcript-scrub.sh. The caller's own ancestor chain (the hook, the
#       claude CLI, agent-call, run-build) is left out. FAIL-CLOSED on the
#       scrub: the header and `# rows withheld: scrub failed`, no rows. The
#       listing is `ps -eo pid=,ppid=,rss=,comm=,args=` (EP_PS_CMD for tests,
#       EP_SELF_PID for the start of the chain). Never fails the caller.
#   ep_oom_cause <snapshot> <mem_mb>   prints `<cause>\t<sentence>`. Memory is
#       the header's mem_total_kb, else <mem_mb>. A heavy process is node,
#       vitest, tsc, jest, postgres or playwright at EXEC_OOM_HEAVY_RSS_MB or
#       more. Rules, in order:
#         no-snapshot  no file, or no valid row
#         single       one row at EXEC_OOM_SINGLE_PCT % of memory or more
#         concurrent   2 or more heavy rows
#         single       (inferred) memory known and all rows together under
#                      (100 - EXEC_OOM_SINGLE_PCT) %: the killed command used most
#         unknown      anything else
#   ep_reap <tag> [--strays <claude-pid>]   kills the process groups of the
#       processes whose environment holds HARNESS_EXEC_TAG=<tag> exactly. TERM,
#       EXEC_PROC_REAP_GRACE_S seconds, then KILL. A group that holds the
#       reaper, one of its ancestors or (with --strays) a live process of the
#       session is never signalled as a group: its target pids (and their
#       descendants) are signalled one by one. --strays keeps only orphaned
#       test runners (vitest, jest, tsc, playwright) that do not descend from
#       <claude-pid>. One stderr line `reaped <n> group(s), <m> process(es)`.
#       rc 0 always. EXEC_PROC_REAP=0 is off. /proc is EP_PROC_ROOT for tests.
#   ep_hook_timeout_s   the CLI's ceiling on bin/exec-proc-hook.sh: the reap
#       grace plus a margin for the snapshot and the TERM pass.
#   ep_knobs   resolves the five lib.exec-procs.* rows (lib_env_apply).

_EP_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
_ep_int() { # _ep_int <value> -> the value when it is a non-negative integer, else rc 1
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) printf '%s' "$((10#$1))" ;; esac
}
# Test runners the mid-session reap may end; heavy processes the classifier counts.
_EP_RUNNER_RE='(^|[ /])(vitest|jest|tsc|playwright)([ /.:-]|$)'
_EP_HEAVY_RE='(^|[ /])(node|vitest|tsc|jest|postgres|playwright)([ /.:-]|$)'

# The _tw_knobs / np_knobs pattern: lib_env_apply runs in a subshell, so its
# fail-closed exit cannot stop the caller, and the EXIT trap hands back on fd 3
# every knob that resolved. Rows override the environment.
_EP_KNOBS="EXEC_PROC_REAP EXEC_PROC_REAP_GRACE_S EXEC_OOM_HEAVY_RSS_MB EXEC_OOM_SINGLE_PCT EXEC_OOM_SNAPSHOT_ROWS"
ep_knobs() {
  local kv k v
  [ -n "${_EP_KNOBS_DONE:-}" ] && return 0
  kv=$(
    exec 3>&1
    command -v lib_env_apply >/dev/null 2>&1 || . "$_EP_LIB/lane-gate.sh" >/dev/null 2>&1 || exit 0
    if [ -z "${LANE_REGISTRY:-}" ] && [ ! -r "$(_lg_registry)" ] && . "$_EP_LIB/lanes-registry.sh" >/dev/null 2>&1; then
      LANE_REGISTRY=$(lanes_json_path "$_EP_LIB/../.." 2>/dev/null) && export LANE_REGISTRY
    fi
    # shellcheck disable=SC2016
    trap 'for k in $_EP_KNOBS; do printf "%s\t%s\n" "$k" "${!k:-}" >&3; done' EXIT
    lib_env_apply exec-procs >/dev/null 2>&1) || true
  # Fallbacks: the rows lib.exec-procs.exec_proc_reap (1),
  # lib.exec-procs.exec_proc_reap_grace_s (5), lib.exec-procs.exec_oom_heavy_rss_mb
  # (200), lib.exec-procs.exec_oom_single_pct (50) and
  # lib.exec-procs.exec_oom_snapshot_rows (15).
  _EP_REAP=$(_ep_int "${EXEC_PROC_REAP:-1}") || _EP_REAP=1
  _EP_GRACE=$(_ep_int "${EXEC_PROC_REAP_GRACE_S:-5}") || _EP_GRACE=5
  _EP_HEAVY_MB=$(_ep_int "${EXEC_OOM_HEAVY_RSS_MB:-200}") || _EP_HEAVY_MB=200
  _EP_PCT=$(_ep_int "${EXEC_OOM_SINGLE_PCT:-50}") || _EP_PCT=50
  _EP_ROWS=$(_ep_int "${EXEC_OOM_SNAPSHOT_ROWS:-15}") || _EP_ROWS=15
  while IFS=$'\t' read -r k v; do
    v=$(_ep_int "$v") || continue
    case "$k" in
      EXEC_PROC_REAP)         _EP_REAP="$v" ;;
      EXEC_PROC_REAP_GRACE_S) _EP_GRACE="$v" ;;
      EXEC_OOM_HEAVY_RSS_MB)  _EP_HEAVY_MB="$v" ;;
      EXEC_OOM_SINGLE_PCT)    _EP_PCT="$v" ;;
      EXEC_OOM_SNAPSHOT_ROWS) _EP_ROWS="$v" ;;
    esac
  done <<<"$kv"
  [ "$_EP_PCT" -ge 1 ] && [ "$_EP_PCT" -le 100 ] || _EP_PCT=50
  [ "$_EP_ROWS" -ge 1 ] || _EP_ROWS=15
  _EP_KNOBS_DONE=1
  return 0
}

ep_hook_timeout_s() {
  ep_knobs
  # The margin covers the ps listing, the scrub and the TERM pass; the grace
  # itself is the knob lib.exec-procs.exec_proc_reap_grace_s.
  printf '%s' "$((_EP_GRACE + 25))"
}

_ep_scrub() { # stdin -> stdout; rc 1 when the scrubber cannot run or fails
  local s="${EP_SCRUB:-$_EP_LIB/../transcript-scrub.sh}"
  [ -r "$s" ] || return 1
  bash "$s"
}

ep_snapshot() { # ep_snapshot <dest> <signal>
  local dest="${1:-}" sig="${2:-}" tmp memkb list rows self
  [ -n "$dest" ] || return 0
  ep_knobs
  memkb=$(awk '$1 == "MemTotal:" { print $2; exit }' "${EE_MEMINFO:-/proc/meminfo}" 2>/dev/null)
  case "$memkb" in ''|*[!0-9]*) memkb=0 ;; esac
  self="${EP_SELF_PID:-$$}"
  tmp="$dest.tmp.$$"
  {
    printf '# oom-procs v1 at=%s mem_total_kb=%s signal=%s\n' "$(date -u +%s)" "$memkb" "$(printf '%s' "$sig" | tr -d '\r\n\t')"
  } 2>/dev/null > "$tmp" || { rm -f "$tmp" 2>/dev/null; return 0; }
  list=$(${EP_PS_CMD:-ps -eo pid=,ppid=,rss=,comm=,args=} 2>/dev/null) || list=""
  # Drop the caller's ancestor chain, sort by rss, keep the cap, clip args.
  rows=$(printf '%s\n' "$list" | awk -v self="$self" -v cap="$_EP_ROWS" '
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ {
      pid = $1; pp[pid] = $2; rss[pid] = $3; comm[pid] = $4
      a = $0; sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+[0-9]+[ \t]+[^ \t]+[ \t]*/, "", a)
      gsub(/\t/, " ", a); args[pid] = substr(a, 1, 160); order[n++] = pid
    }
    END {
      p = self; hops = 0
      while (p != "" && p != "0" && hops++ < 64) { anc[p] = 1; p = pp[p] }
      for (i = 0; i < n; i++) { q = order[i]; if (!(q in anc)) printf "%s\t%s\t%s\t%s\n", q, rss[q], comm[q], args[q] }
    }' | sort -t$'\t' -k2,2nr | head -n "$_EP_ROWS")
  if [ -n "$rows" ]; then
    local scrubbed
    if scrubbed=$(printf '%s\n' "$rows" | _ep_scrub 2>/dev/null) && [ -n "$scrubbed" ]; then
      printf '%s\n' "$scrubbed" >> "$tmp" 2>/dev/null
    else
      printf '# rows withheld: scrub failed\n' >> "$tmp" 2>/dev/null
    fi
  fi
  mv -f "$tmp" "$dest" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

ep_oom_cause() { # ep_oom_cause <snapshot> <mem_mb>
  local f="${1:-}" memmb="${2:-}" proj="${PROJECT:-<project>}" row="" out
  ep_knobs
  row="lane.fly-pool.$proj.vm_memory_mb"
  case "$memmb" in ''|*[!0-9]*) memmb=0 ;; esac
  if [ -r "$f" ] && [ -s "$f" ]; then
    out=$(awk -F'\t' -v argkb="$((memmb * 1024))" -v floor="$((_EP_HEAVY_MB * 1024))" -v pct="$_EP_PCT" \
              -v hre="$_EP_HEAVY_RE" '
      function label(c, a,   m) {
        if (match(a, /(^|[ \/])(vitest|jest|tsc|playwright|postgres)([ \/.:-]|$)/)) {
          m = substr(a, RSTART, RLENGTH); gsub(/[ \/.:-]/, "", m); return m
        }
        return c
      }
      NR == 1 && /^# oom-procs v1 / {
        if (match($0, /mem_total_kb=[0-9]+/)) hdrkb = substr($0, RSTART + 13, RLENGTH - 13) + 0
        next
      }
      /^#/ { next }
      NF >= 4 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
        n++; tot += $2
        if ($2 > maxkb) { maxkb = $2; maxl = label($3, $4) }
        if ($2 >= floor && (($3 " " $4) ~ hre)) { h++; hl = hl (h > 1 ? ", " : "") label($3, $4) " " int($2 / 1024) " MB" }
      }
      END {
        mem = (hdrkb > 0) ? hdrkb : argkb
        if (n == 0) { print "no-snapshot"; exit }
        if (mem > 0 && maxkb * 100 >= pct * mem) { printf "single\t%s\t%d\n", maxl, int(maxkb * 100 / mem); exit }
        if (h >= 2) { printf "concurrent\t%d\t%s\n", h, hl; exit }
        if (mem > 0 && tot * 100 < (100 - pct) * mem) { printf "inferred\t%d\n", int(tot * 100 / mem); exit }
        printf "unknown\t%d\t%d\n", h, (mem > 0 ? int(maxkb * 100 / mem) : -1)
      }' "$f" 2>/dev/null) || out=""
  else
    out=""
  fi
  local c a b
  IFS=$'\t' read -r c a b <<<"${out:-no-snapshot}"
  case "$c" in
    concurrent)
      printf 'concurrent\tCause: concurrent processes (%s heavy: %s). Run one heavy check at a time; do not raise vm_memory_mb.\n' "$a" "$b" ;;
    single)
      printf 'single\tCause: one process used most of the memory (%s %s%%). Raise the row %s.\n' "$a" "$b" "$row" ;;
    inferred)
      printf 'single\tCause: one process used most of the memory (the killed command; the processes left alive held %s%%). Raise the row %s.\n' "$a" "$row" ;;
    unknown)
      if [ "${b:--1}" -ge 0 ] 2>/dev/null; then b="largest $b%"; else b="machine memory unknown"; fi
      printf 'unknown\tCause unknown: %s heavy process(es), %s. Check for concurrent processes before you raise the row %s.\n' "$a" "$b" "$row" ;;
    *)
      printf 'no-snapshot\tCause unknown, no snapshot (oom-procs.txt missing). Check for concurrent processes before you raise the row %s.\n' "$row" ;;
  esac
  return 0
}

# _ep_stat <proc-root> <pid> -> "ppid pgid" from /proc/<pid>/stat; rc 1 when gone or a zombie
_ep_stat() {
  local s st rest
  { read -r s < "$1/$2/stat"; } 2>/dev/null || return 1
  rest=${s##*) }
  # shellcheck disable=SC2086
  set -- $rest
  st=$1
  [ "$st" = Z ] || [ "$st" = X ] && return 1
  printf '%s %s' "$2" "$3"
}

ep_reap() { # ep_reap <tag> [--strays <claude-pid>]
  local tag="${1:-}" strays="" claude="" root="${EP_PROC_ROOT:-/proc}" f pid st pp pg
  [ "${2:-}" = --strays ] && { strays=1; claude="${3:-}"; }
  ep_knobs
  if [ -z "$tag" ] || [ "${_EP_REAP:-1}" = 0 ]; then
    echo "exec-procs: reaped 0 group(s), 0 process(es)" >&2; return 0
  fi
  [ -n "$strays" ] && case "$claude" in ''|*[!0-9]*) echo "exec-procs: reaped 0 group(s), 0 process(es) (no claude pid)" >&2; return 0 ;; esac
  local -A PP=() PG=() prot_pg=() tg=()
  local -a tagged=() targets=()
  # One pass over every process: ppid and pgid.
  for f in "$root"/[0-9]*/stat; do
    pid=${f%/stat}; pid=${pid##*/}
    st=$(_ep_stat "$root" "$pid") || continue
    PP[$pid]=${st% *}; PG[$pid]=${st#* }
  done
  # The tagged set: the exact NUL-delimited entry, never a prefix.
  while IFS= read -r f; do
    pid=${f%/environ}; pid=${pid##*/}
    [ -n "${PP[$pid]:-}" ] && tagged+=("$pid")
  done < <(grep -lzxF -- "HARNESS_EXEC_TAG=$tag" "$root"/[0-9]*/environ 2>/dev/null)
  # _ep_desc_of <pid> <ancestor> -> rc 0 when pid descends from ancestor (or is it)
  _ep_desc_of() { local p="$1" i=0; while [ -n "$p" ] && [ "$p" != 0 ] && [ "$i" -lt 256 ]; do [ "$p" = "$2" ] && return 0; p=${PP[$p]:-}; i=$((i+1)); done; return 1; }
  # Protected groups: the reaper and its ancestors; with --strays, the claude
  # pid, its ancestors and every live process that descends from it.
  pid=$$; local i=0
  while [ -n "$pid" ] && [ "$pid" != 0 ] && [ "$i" -lt 256 ]; do [ -n "${PG[$pid]:-}" ] && prot_pg[${PG[$pid]}]=1; pid=${PP[$pid]:-}; i=$((i+1)); done
  [ -n "${BASHPID:-}" ] && [ -n "${PG[$BASHPID]:-}" ] && prot_pg[${PG[$BASHPID]}]=1
  if [ -n "$strays" ]; then
    pid=$claude; i=0
    while [ -n "$pid" ] && [ "$pid" != 0 ] && [ "$i" -lt 256 ]; do [ -n "${PG[$pid]:-}" ] && prot_pg[${PG[$pid]}]=1; pid=${PP[$pid]:-}; i=$((i+1)); done
    for pid in "${!PP[@]}"; do _ep_desc_of "$pid" "$claude" && prot_pg[${PG[$pid]}]=1; done
  fi
  for pid in ${tagged[@]+"${tagged[@]}"}; do
    [ "$pid" = $$ ] || [ "$pid" = "${BASHPID:-}" ] && continue
    _ep_desc_of $$ "$pid" && continue          # never an ancestor of the reaper
    if [ -n "$strays" ]; then
      _ep_desc_of "$pid" "$claude" && continue  # a live process of the session
      grep -qE "$_EP_RUNNER_RE" <<<"$(tr '\0' ' ' < "$root/$pid/cmdline" 2>/dev/null)" || continue
    fi
    targets+=("$pid")
  done
  # Signal plan: a whole group when no protected process is in it, else the
  # target pid and its descendants one by one.
  local -A one=() grp=()
  for pid in ${targets[@]+"${targets[@]}"}; do
    pg=${PG[$pid]}
    if [ -n "${prot_pg[$pg]:-}" ] || [ "$pg" = 0 ]; then
      for f in "${!PP[@]}"; do _ep_desc_of "$f" "$pid" && [ "$f" != $$ ] && one[$f]=1; done
    else
      grp[$pg]=1
    fi
  done
  local ng=0 np=0
  for pg in "${!grp[@]}"; do
    if kill -TERM -- "-$pg" 2>/dev/null; then
      ng=$((ng+1))
      for f in "${!PG[@]}"; do [ "${PG[$f]}" = "$pg" ] && np=$((np+1)); done
    fi
  done
  for pid in "${!one[@]}"; do kill -TERM "$pid" 2>/dev/null && np=$((np+1)); done
  # Grace, then KILL whatever is left.
  if [ "${#grp[@]}" -gt 0 ] || [ "${#one[@]}" -gt 0 ]; then
    local left w=0 limit=$(( ${_EP_GRACE:-5} * 10 ))
    while :; do
      left=0
      for pg in "${!grp[@]}"; do for f in "${!PG[@]}"; do [ "${PG[$f]}" = "$pg" ] && _ep_stat "$root" "$f" >/dev/null && left=1 && break; done; done
      for pid in "${!one[@]}"; do _ep_stat "$root" "$pid" >/dev/null && left=1 && break; done
      [ "$left" = 0 ] && break
      [ "$w" -ge "$limit" ] && break
      sleep 0.1; w=$((w+1))
    done
    if [ "$left" = 1 ]; then
      for pg in "${!grp[@]}"; do kill -KILL -- "-$pg" 2>/dev/null; done
      for pid in "${!one[@]}"; do kill -KILL "$pid" 2>/dev/null; done
    fi
  fi
  echo "exec-procs: reaped $ng group(s), $np process(es)" >&2
  return 0
}
