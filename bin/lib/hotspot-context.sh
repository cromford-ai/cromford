#!/bin/bash
# shellcheck shell=bash
# bin/lib/hotspot-context.sh — the project's measured conflict hotspots, as the
# CONFLICT HOTSPOTS section of the project primer and as a plain path list the
# plan gate reads. Sourced, functions only; nothing runs at source time.
#
#   hc_conf <project>                  sets HC_TOP (PLAN_CONTEXT_HOTSPOT_TOP); rc 1 = off
#   hc_fetch <project> <out-json>      rc 0 = the worker answered a usable object
#   hc_section <project> [<hotlist>]   prints the section, sets HC_STATE
#   hc_list <project> <hotlist>        the list only; rc 0 = it was written
#
# HC_STATE is one of:
#   yes      rows answered; the section cites them;
#   none     measured, zero rows; the hotlist is written EMPTY;
#   never    no successful measurement for this project yet;
#   off      knob 0 or bad;
#   unknown  no coordination DB (EMPTY JOBS_URL), outage, wrong shape.
# Only yes/none write the hotlist. Every other state REMOVES it, so a list from
# an earlier render never passes as current, and "could not read" never reads
# as "no hotspots".
#
# The data is the conflict_hotspots table (GET /api/conflict-hotspots, worker
# routes/conflict-hotspots.js), which the weekly conflict-hotspots-fleet lane
# writes. JOBS_URL resolves exactly as for every other worker caller: an UNSET
# JOBS_URL takes the fleet worker through bin/jobs-client.sh (bin/lib/jobs/req.sh
# fallback), which is the normal state of a pool build machine. An EMPTY
# JOBS_URL is "no coordination DB here" (BH-1957) and makes no request; the
# suites run with it EMPTY (tests/lib/scratch.sh), so a render there stays
# offline.
#
# A row's file name goes into a model prompt, so a name outside a plain path
# charset is dropped and counted, never printed.

HC_TOP_DEFAULT=10
HC_TOP_MAX=50
HC_TOP=""
HC_STATE=""

hc_conf() { # hc_conf <project>
  local p="${1:-}" root v
  root="${HARNESS:-${H:-}}"
  HC_TOP=""
  if ! command -v lib_env_apply >/dev/null 2>&1; then
    if [ -n "$root" ] && [ -r "$root/bin/lib/lane-gate.sh" ]; then
      # shellcheck source=/dev/null
      . "$root/bin/lib/lane-gate.sh" 2>/dev/null || true
    fi
  fi
  if command -v lib_env_apply >/dev/null 2>&1; then
    v=$(lib_env_apply plan-context-hotspots "$p" >/dev/null 2>&1; printf '%s' "${PLAN_CONTEXT_HOTSPOT_TOP-}")
  else
    v="${PLAN_CONTEXT_HOTSPOT_TOP-}"
  fi
  [ -n "$v" ] || v=$HC_TOP_DEFAULT
  case "$v" in
    *[!0-9]*) echo "PLAN_CONTEXT_HOTSPOTS_BADKNOB PLAN_CONTEXT_HOTSPOT_TOP=$v" >&2; return 1 ;;
  esac
  v=$((10#$v))
  if [ "$v" -gt "$HC_TOP_MAX" ]; then
    echo "PLAN_CONTEXT_HOTSPOTS_BADKNOB PLAN_CONTEXT_HOTSPOT_TOP=$v" >&2; return 1
  fi
  [ "$v" -gt 0 ] || return 1
  HC_TOP=$v
  return 0
}

# hc_fetch <project> <out-json> — HC_WHY says why on rc 1.
hc_fetch() {
  local p="${1:-}" out="${2:-}" lib body
  HC_WHY=""
  grep -qE '^[A-Za-z0-9._-]{1,64}$' <<<"$p" || { HC_WHY="project name not usable"; return 1; }
  [ -n "$out" ] || { HC_WHY="no output path"; return 1; }
  # Set and EMPTY: answered here, before the client is sourced. UNSET goes on to
  # the client, which resolves the fleet worker.
  if [ -n "${JOBS_URL+set}" ] && [ -z "$JOBS_URL" ]; then HC_WHY="JOBS_URL is empty: no coordination DB here"; return 1; fi
  case "$HC_TOP" in ''|*[!0-9]*) HC_WHY="no row limit"; return 1 ;; esac
  lib="$(dirname "${BASH_SOURCE[0]}")/../jobs-client.sh"
  [ -r "$lib" ] || { HC_WHY="bin/jobs-client.sh is not beside this lib"; return 1; }
  # A subshell: the client's globals and its `set -uo pipefail` stay out of the
  # caller. JOBS_ALERT=0 — this read is optional evidence, and an outage is
  # already alerted by the lanes that depend on the worker.
  # rc 3 = the client resolved no worker (an EMPTY global.env line, or no
  # subdomain for the fallback): the same "no coordination DB" answer.
  local frc=0
  body=$( JOBS_ALERT=0
          # shellcheck source=/dev/null
          . "$lib" >/dev/null 2>&1 || exit 1
          jobs_configured || exit 3
          _jobs_req GET "/api/conflict-hotspots?project=$p&limit=$HC_TOP" 2>/dev/null ) || frc=$?
  if [ "$frc" = 3 ]; then HC_WHY="JOBS_URL resolved empty: no coordination DB here"; return 1; fi
  [ "$frc" = 0 ] || { HC_WHY="the jobs worker did not answer"; return 1; }
  printf '%s' "$body" | jq -e 'type == "object" and (.hotspots | type == "array") and has("run")' >/dev/null 2>&1 \
    || { HC_WHY="the answer is not a conflict-hotspots object"; return 1; }
  printf '%s' "$body" > "$out" || { HC_WHY="cannot write $out"; return 1; }
  return 0
}

# _hc_path_ok <path> — a plain repo path: no leading /, no .. segment, no
# whitespace or shell metacharacters. [] stays in: Next.js route paths use it.
_hc_path_ok() {
  local f="$1"
  [ "${#f}" -ge 1 ] && [ "${#f}" -le 200 ] || return 1
  case "$f" in /*|..|../*|*/..|*/../*) return 1 ;; esac
  printf '%s' "$f" | LC_ALL=C grep -qxE '[]A-Za-z0-9._@()/+[-]+' 2>/dev/null || return 1
  # grep -x matches per line: a name with a newline has a second line to fail on.
  [ "$(printf '%s' "$f" | wc -l | tr -d ' ')" = 0 ]
}

_hc_put_list() { # _hc_put_list <hotlist> <content-file>
  local dest="$1" src="$2" tmp
  tmp=$(mktemp "$(dirname "$dest")/.hotspots.XXXXXX" 2>/dev/null) || { rm -f "$dest"; return 1; }
  cat "$src" > "$tmp" && mv -f "$tmp" "$dest" || { rm -f "$tmp" "$dest"; return 1; }
}

hc_section() { # hc_section <project> [<hotlist-out>]
  local p="${1:-}" list="${2:-}" tmp kept dropped=0 n=0 f c r when win total limit trunc
  HC_STATE=unknown
  if ! hc_conf "$p"; then
    HC_STATE=off
    [ -n "$list" ] && rm -f "$list"
    echo "--- CONFLICT HOTSPOTS ---"
    echo "ABSENT: hotspot section off for $p (PLAN_CONTEXT_HOTSPOT_TOP)."
    return 0
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/hc.XXXXXX" 2>/dev/null) || tmp=""
  if [ -z "$tmp" ] || ! hc_fetch "$p" "$tmp"; then
    [ -n "$tmp" ] && rm -f "$tmp"
    [ -n "$list" ] && rm -f "$list"
    echo "--- CONFLICT HOTSPOTS ---"
    echo "COULD NOT READ: conflict_hotspots for $p (${HC_WHY:-mktemp failed}). Treat every file as possibly hot; this is not \"no hotspots\"."
    return 0
  fi
  when=$(jq -r '.run.last_ok_at // empty' "$tmp" 2>/dev/null)
  if [ "$(jq -r '.run == null' "$tmp")" = true ] || { [ -z "$when" ] && [ "$(jq -r '.hotspots | length' "$tmp")" = 0 ]; }; then
    HC_STATE=never
    rm -f "$tmp"
    [ -n "$list" ] && rm -f "$list"
    echo "--- CONFLICT HOTSPOTS ---"
    echo "ABSENT: no conflict_hotspots measurement for $p yet (the weekly conflict-hotspots-fleet lane writes it)."
    return 0
  fi
  [ -n "$when" ] || when=$(jq -r '.run.run_at // "an unknown time"' "$tmp")
  win=$(jq -r '.run.window_days // .hotspots[0].window_days // empty' "$tmp")
  total=$(jq -r '.total // empty' "$tmp"); limit=$(jq -r '.limit // empty' "$tmp")
  trunc=$(jq -r '.truncated == true' "$tmp")
  kept=$(mktemp "${TMPDIR:-/tmp}/hc-kept.XXXXXX" 2>/dev/null) || { rm -f "$tmp"; HC_STATE=unknown; [ -n "$list" ] && rm -f "$list"
    echo "--- CONFLICT HOTSPOTS ---"; echo "COULD NOT READ: conflict_hotspots for $p (mktemp failed). Treat every file as possibly hot; this is not \"no hotspots\"."; return 0; }
  echo "--- CONFLICT HOTSPOTS (source: conflict_hotspots rows for $p, GET /api/conflict-hotspots, measured $when, ${win:-?}-day window) ---"
  if [ "$(jq -r '.hotspots | length' "$tmp")" = 0 ]; then
    HC_STATE=none
    echo "The last measurement found no file that conflicted."
  else
    HC_STATE=yes
    echo "These files conflicted most across parallel PRs. Prefer a new file, a fragment or a module over growing them."
    echo "A plan that names one lists it under \`## Shared files\` with a reason (prompts/plan-contract.md §11)."
    # One row per line, base64 per field, so a name with a newline stays one row.
    while IFS=$'\t' read -r f c r; do
      # The trailing x keeps a decoded trailing newline, so it fails the check.
      f=$(printf '%s' "$f" | base64 -d 2>/dev/null; echo x); f=${f%x}
      if ! _hc_path_ok "$f"; then dropped=$((dropped+1)); continue; fi
      case "$c" in ''|*[!0-9]*) c='?' ;; esac
      case "$r" in ''|*[!0-9]*) r='?' ;; esac
      n=$((n+1))
      printf '  %d. %s — %s conflicts, %s rebases\n' "$n" "$f" "$c" "$r"
      printf '%s\n' "$f" >> "$kept"
    done < <(jq -r '.hotspots[] | [(.file // "" | tostring | @base64), (.conflicts // "" | tostring), (.rebases // "" | tostring)] | @tsv' "$tmp" 2>/dev/null)
    [ "$dropped" -gt 0 ] && echo "  ($dropped rows with an unusable path were left out)"
    [ "$trunc" = true ] && echo "  (top ${limit:-?} of ${total:-?} files)"
  fi
  rm -f "$tmp"
  [ -n "$list" ] && { _hc_put_list "$list" "$kept" || true; }
  rm -f "$kept"
  return 0
}

hc_list() { # hc_list <project> <hotlist>
  local list="${2:-}"
  [ -n "$list" ] || return 1
  hc_section "${1:-}" "$list" >/dev/null
  case "$HC_STATE" in yes|none) [ -f "$list" ] ;; *) return 1 ;; esac
}
