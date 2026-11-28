#!/bin/bash
# bin/lib/pool-alloc.sh — the fleet slot allocator (BH-7877). Sourced, never
# executed; defines functions only.
#
# WHY. Each pool project spawns up to its own queue depth (or its pool_cap),
# so one busy project can take every machine while the others wait. With a
# fleet total set, bin/fly-pool-tick.sh shares the free slots among the
# projects with queued work, in proportion to a weight per project.
#
# KNOBS (rows read from the .values of state/settings-cache.json, which
# lane_env_apply at the top of bin/fly-pool-tick.sh has already refreshed;
# a registry-seed row is not in .values, so a seeded default changes nothing):
#   lane.fly-pool.fleet_slots     (FLEET_SLOTS) the fleet total. No row, 0, or
#                                 not a whole number = OFF: no grant at all.
#   lane.fly-pool.<p>.weight      (WEIGHT) <p> lowercased. Fallback 1 when the
#                                 row is absent or not a whole number in
#                                 1..max (WEIGHT.json "max", fallback 100).
# Registry: catalog/lanes.d/fly-pool.knobs.d/{FLEET_SLOTS,WEIGHT}.json.
#
#   pa_allocate <free>      stdin `<p> <weight> <demand>` rows; stdout
#                           `<p> <grant>` in input order. Pure (awk).
#   pa_inputs <p>...        stdout `<p> <weight> <queued> <live> <demand>`
#   pa_tick <p>...          the per-tick writer: one grant file per project in
#                           state/fly-pool-alloc/, one [pool-alloc] line in
#                           logs/fly-pool.log. Always rc 0.
#   pa_clamp <p>            in bin/fly-pool.sh (config/fly-pool.d/
#                           3550-fleet-alloc-clamp.sh): BUDGET = min(BUDGET,
#                           target - LIVE), floor 0.
#
# GRANT FILE state/fly-pool-alloc/<p>, one line, written tmp + mv:
#   fleet-alloc v1 <epoch> <target> <grant> <weight> <queued> <live> <fleet>
# target = live + grant. It is a TOTAL, not a delta: a tick that runs twice on
# one file never spawns the grant twice.
#
# DEMAND = queued; with a pool_cap (bin/pool-cap.sh) min(queued, cap - live),
# floor 0; 0 when pc_eval (bin/lib/project-ceiling.sh) says the project is
# over its daily spend ceiling. pc_eval rc 1/2/3 (no ceiling, spend
# unreadable, no jobs client) leaves demand as it is: the BH-7876 launch gate
# still refuses an over-ceiling build on its own. The CALLER sources
# project-ceiling.sh at its top level (its cost-budget.sh tables are
# `declare -A`, which inside a function would be local); without it there is
# no ceiling read.
#
# Root: ${HARNESS:-${H:-}}. With no root every function returns without a write.

_pa_root() { printf '%s' "${HARNESS:-${H:-}}"; }

# pa_allocate <free> — water-fill. share = remaining x w / sum(w) over the
# projects not yet satisfied; a project whose share covers its demand takes
# its demand and leaves, and the rest is shared again. In the last round each
# share is floored, and the slots left go one each by largest fraction, then
# larger weight, then name (C order). No grant passes its demand; the sum of
# the grants never passes <free>.
pa_allocate() {
  local free="${1:-0}"
  case "$free" in ''|*[!0-9]*) free=0 ;; esac
  LC_ALL=C awk -v free="$free" '
    NF >= 3 { n++; p[n] = $1; w[n] = $2 + 0; d[n] = $3 + 0
              if (w[n] < 1) w[n] = 1
              if (d[n] < 0) d[n] = 0
              g[n] = 0; done[n] = (d[n] == 0) }
    END {
      rem = free
      while (1) {
        sw = 0; for (i = 1; i <= n; i++) if (!done[i]) sw += w[i]
        if (sw == 0 || rem <= 0) break
        left = 0
        for (i = 1; i <= n; i++) if (!done[i] && rem * w[i] / sw >= d[i]) { g[i] = d[i]; done[i] = 1; left += d[i] }
        if (left == 0) break
        rem -= left
      }
      if (sw > 0 && rem > 0) {
        m = 0; used = 0
        for (i = 1; i <= n; i++) if (!done[i]) {
          s = rem * w[i] / sw; g[i] = int(s); used += g[i]; fr[i] = s - g[i]; o[++m] = i
        }
        # Order by fraction desc, weight desc, name asc (selection sort: one
        # tick holds at most the fleet registry, about 1,000 projects).
        for (a = 1; a <= m; a++) { b = a
          for (c = a + 1; c <= m; c++) {
            x = o[c]; y = o[b]
            if (fr[x] > fr[y] || (fr[x] == fr[y] && (w[x] > w[y] || (w[x] == w[y] && p[x] < p[y])))) b = c
          }
          t = o[a]; o[a] = o[b]; o[b] = t }
        extra = rem - used
        for (a = 1; a <= m && extra > 0; a++) { i = o[a]; if (g[i] < d[i]) { g[i]++; extra-- } }
      }
      for (i = 1; i <= n; i++) print p[i], g[i]
    }'
}

# _pa_settings <p>... — ONE jq over the cache: sets PA_FLEET (digits, else 0)
# and _PA_W[<p>] (whole number >= 1, else 1).
_pa_settings() {
  local root f p v wmax
  root=$(_pa_root)
  PA_FLEET=0
  declare -gA _PA_W=()
  for p in "$@"; do [ -n "$p" ] && _PA_W[$p]=1; done
  [ -n "$root" ] || return 0
  f="$root/state/settings-cache.json"
  [ -r "$f" ] || return 0
  # The weight's upper bound is the registry's "max" (WEIGHT.json); 100 is the
  # code fallback when the registry file is not readable. A row past it reads
  # as 1, as a row below 1 does.
  wmax=$(jq -r '.max // empty' "$root/catalog/lanes.d/fly-pool.knobs.d/WEIGHT.json" 2>/dev/null | tr -dc 0-9)
  wmax="${wmax:-100}"
  { read -r v
    # Code fallback 0 = off: row lane.fly-pool.fleet_slots (knob FLEET_SLOTS).
    v="${v//[[:space:]]/}"; [[ "$v" =~ ^[0-9]+$ ]] && PA_FLEET=$((10#$v))
    while IFS=$'\t' read -r p v; do
      # Code fallback 1: row lane.fly-pool.<p>.weight (knob WEIGHT).
      v="${v//[[:space:]]/}"
      [ -n "$p" ] && [[ "$v" =~ ^[0-9]+$ ]] && [ "$((10#$v))" -ge 1 ] && [ "$((10#$v))" -le "$wmax" ] && _PA_W[$p]=$((10#$v))
    done
  } < <(printf '%s\n' "$@" | jq -rR --slurpfile c "$f" '
      ($c[0].values // {}) as $v
      | (if input_line_number == 1 then (($v["lane.fly-pool.fleet_slots"] // "") | tostring) else empty end),
        (. as $p | "\($p)\t\(($v["lane.fly-pool.\($p | ascii_downcase).weight"] // "") | tostring)")' 2>/dev/null)
  return 0
}

# _pa_count <dir> <skip-failed 0|1> — entries a glob sees (ls without -A), no fork.
_pa_count() {
  local n=0 e
  for e in "$1"/*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    if [ "$2" = 1 ]; then case "$e" in *.json) case "$e" in *.failed.json) continue ;; esac ;; *) continue ;; esac; fi
    n=$((n + 1))
  done
  printf '%s' "$n"
}

# _pa_demand <p> <queued> <live> — prints the demand (see the header).
_pa_demand() {
  local p="$1" q="$2" l="$3" root cap d
  root=$(_pa_root)
  d="$q"
  cap=$("$root/bin/pool-cap.sh" "$p" 2>/dev/null | tr -dc '0-9')
  if [ -n "$cap" ] && [ "$cap" -gt 0 ]; then
    [ $((cap - l)) -lt "$d" ] && d=$((cap - l))
    [ "$d" -lt 0 ] && d=0
  fi
  if command -v pc_eval >/dev/null 2>&1 && pc_eval "$p" >/dev/null 2>&1 && [ "${PC_STATE:-}" = over ]; then d=0; fi
  printf '%s\n' "$d"
}

# pa_inputs <p>... — `<p> <weight> <queued> <live> <demand>` per project.
# The cap and ceiling reads run only for a project with queued work, in
# parallel, at most PA_PARALLEL at once (empty or 0 = all at once). pool-cap.sh
# bounds its own row read (timeout 10) and pc_eval's spend read is one jobs
# request under the client's -m $JOBS_TIMEOUT.
pa_inputs() {
  local root p q l tmp max d
  local -A Q=() L=()
  root=$(_pa_root)
  [ -n "$root" ] && [ "$#" -gt 0 ] || return 0
  # pa_tick has read the cache already (_PA_HAVE, its local); alone, read it here.
  [ "${_PA_HAVE:-0}" = 1 ] || _pa_settings "$@"
  max="${PA_PARALLEL:-0}"; case "$max" in ''|*[!0-9]*) max=0 ;; esac
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/pa-inputs.XXXXXX" 2>/dev/null) || tmp=""
  for p in "$@"; do
    Q[$p]=$(_pa_count "$root/state/build-queue/$p" 1)
    L[$p]=$(_pa_count "$root/state/fly-pool/$p" 0)
    [ "${Q[$p]}" -gt 0 ] && [ -n "$tmp" ] || continue
    if [ "$max" -gt 0 ]; then
      while [ "$(jobs -pr | wc -l)" -ge "$max" ]; do wait -n 2>/dev/null || break; done
    fi
    ( _pa_demand "$p" "${Q[$p]}" "${L[$p]}" > "$tmp/$p" ) &
  done
  wait
  for p in "$@"; do
    q="${Q[$p]}"; l="${L[$p]}"; d=0
    if [ "$q" -gt 0 ]; then
      d=""
      [ -n "$tmp" ] && d=$(tr -dc '0-9' < "$tmp/$p" 2>/dev/null)
      d="${d:-$q}"   # a read that did not answer: demand stays the queue
    fi
    printf '%s %s %s %s %s\n' "$p" "${_PA_W[$p]:-1}" "$q" "$l" "$d"
  done
  [ -n "$tmp" ] && case "$tmp" in "${TMPDIR:-/tmp}"/pa-inputs.?*) rm -rf -- "$tmp" ;; esac
  return 0
}

# _pa_clear — remove every grant file (the allocator is off).
_pa_clear() {
  local root e
  root=$(_pa_root); [ -n "$root" ] || return 0
  for e in "$root/state/fly-pool-alloc"/*; do
    case "$e" in "$root/state/fly-pool-alloc/"?*) [ -f "$e" ] && rm -f -- "$e" ;; esac
  done
  return 0
}

# pa_tick <p>... — compute and write this tick's grants. Always rc 0.
pa_tick() {
  local root dir p w q l d g ts free live_all=0 idle=0 entries="" now as keep _PA_HAVE=1
  local -a ps=()
  local -A W=() QQ=() LL=() G=()
  root=$(_pa_root); [ -n "$root" ] || return 0
  for p in "$@"; do [[ "$p" =~ ^[A-Za-z0-9._-]+$ ]] && ps+=("$p"); done
  _pa_settings "${ps[@]}"
  if [ "$PA_FLEET" -le 0 ]; then _pa_clear; return 0; fi
  # POOL_AUTOSCALE=0 promises the pre-autoscale budget byte for byte.
  as=$("$root/bin/pool-cap.sh" --autoscale 2>/dev/null)
  if [ "$as" = 0 ]; then _pa_clear; return 0; fi
  dir="$root/state/fly-pool-alloc"
  mkdir -p "$dir" 2>/dev/null || return 0
  while read -r p w q l d; do
    [ -n "$p" ] || continue
    W[$p]=$w; QQ[$p]=$q; LL[$p]=$l; live_all=$((live_all + l))
    printf '%s %s %s\n' "$p" "$w" "$d"
  done < <(pa_inputs "${ps[@]}") > "$dir/.rows.$$"
  free=$((PA_FLEET - live_all)); [ "$free" -lt 0 ] && free=0
  while read -r p g; do [ -n "$p" ] && G[$p]=$g; done < <(pa_allocate "$free" < "$dir/.rows.$$")
  rm -f -- "$dir/.rows.$$"
  now="${PA_NOW:-$(date +%s)}"
  for p in "${ps[@]}"; do
    [ -n "${W[$p]:-}" ] || continue
    g="${G[$p]:-0}"
    printf 'fleet-alloc v1 %s %s %s %s %s %s %s\n' "$now" "$((LL[$p] + g))" "$g" "${W[$p]}" "${QQ[$p]}" "${LL[$p]}" "$PA_FLEET" \
      > "$dir/.$p.tmp.$$" 2>/dev/null && mv -f -- "$dir/.$p.tmp.$$" "$dir/$p" 2>/dev/null \
      || rm -f -- "$dir/.$p.tmp.$$"
    if [ "${QQ[$p]}" -gt 0 ]; then entries="$entries $p:w=${W[$p]},q=${QQ[$p]},g=$g"; else idle=$((idle + 1)); fi
  done
  # A project that left the pool loses its file.
  for p in "$dir"/*; do
    [ -f "$p" ] || continue
    keep=0
    [ -n "${W[${p##*/}]:-}" ] && keep=1
    [ "$keep" = 1 ] || { case "$p" in "$dir/"?*) rm -f -- "$p" ;; esac; }
  done
  ts=$(date -u '+%Y-%m-%d %H:%M:%SZ')
  mkdir -p "$root/logs" 2>/dev/null
  echo "$ts [pool-alloc] fleet=$PA_FLEET live=$live_all free=$free$entries idle=$idle" >> "$root/logs/fly-pool.log" 2>/dev/null
  return 0
}

# pa_clamp <p> — lower BUDGET to this project's grant target. No file, a line
# that does not parse, or a version that is not v1: BUDGET is not changed.
# Uses the caller's BUDGET, LIVE and say (bin/fly-pool.sh).
pa_clamp() {
  local root f tag ver ep tgt gr w q l fl extra new
  root=$(_pa_root); [ -n "$root" ] || return 0
  f="$root/state/fly-pool-alloc/${1:-}"
  [ -n "${1:-}" ] && [ -f "$f" ] || return 0
  read -r tag ver ep tgt gr w q l fl extra < "$f" 2>/dev/null || [ -n "${tag:-}" ] || return 0
  [ "$tag" = fleet-alloc ] && [ "$ver" = v1 ] && [ -n "$fl" ] && [ -z "$extra" ] || return 0
  [[ "$ep$tgt$gr$w$q$l$fl" =~ ^[0-9]+$ ]] || return 0
  [[ "${BUDGET:-}" =~ ^[0-9]+$ ]] && [[ "${LIVE:-}" =~ ^[0-9]+$ ]] || return 0
  new=$((tgt - LIVE)); [ "$new" -lt 0 ] && new=0
  [ "$new" -lt "$BUDGET" ] || return 0
  declare -F say >/dev/null 2>&1 && say "fleet-alloc: spawning $BUDGET->$new (target $tgt, live $LIVE, grant $gr)"
  BUDGET=$new
  return 0
}
