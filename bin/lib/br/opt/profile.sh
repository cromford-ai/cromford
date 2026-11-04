#!/bin/bash
# bin/lib/br/opt/profile.sh — the run profile of bin/blocked-resolver.sh
# (BH-5946). Optional module of the BH-1468 seam; see bin/lib/br/opt/README.md.
#
# WHAT IT WRITES. One `prof:` line per run that had candidates, right after the
# `tick:` line, and one TSV row per dispatched candidate in
# state/blocked-resolver/profile/[<project>.]<UTC stamp>.<pid>.tsv (a project run, BH-5913, prefixes its project and keeps its own BR_PROFILE_KEEP):
#
#   prof: secs= discovery= prepass= order= loop= rows= gh= gh_rows= search=
#         pulls= issues= raw= d1= llm= memo_hits= unchanged= discovery_rows=
#         retired_skipped= discovery_src=<src>:<s>,… top=[<p>/<rkey>:<s>s …]
#   TSV:  p rkey src reason rc secs gh_total gh_search gh_pulls gh_issues d1 llm
#         memo_hit unchanged
#
# gh= counts every REST call that reached `gh api -i -X` (gh_rest's own call),
# raw= every other `gh api` call, both made through the lane's `gh` function.
# A memo hit (readmemo.sh) never reaches `gh`, so it is not counted as a GitHub
# call. gh_rows= is the GitHub calls (REST and raw) made inside the rows; the
# rest were made by discovery and the stages before the loop. discovery_rows=
# is the tick line's candidates=; retired_skipped= the rows the sources skipped
# as already retired; discovery_src= each source's seconds (BH-9029). d1= counts
# _jobs_req calls. llm= is the lane's own `llm` token. Seconds are integers.
# A call made before the tick's ledger ($TICK_COUNTS) exists is not counted:
# the lane gate's liveness post and knob read at the top of the script, and the
# contested-hold sweep before the drain.
#
# HOW IT COUNTS. Each call appends one token to $TICK_COUNTS through br_count,
# the same ledger the tick line reads: `gh <METHOD> <shape>`, `gh RAW <shape>`,
# `d1 <first path segment>`. The tick line's readers match whole lines
# (`grep -cx llm`), so a token with a space never changes them. The shape is a
# fixed word (pulls, pulls-files, issues, issue-comments, search, reviews,
# commits, compare, other): no slug and no number is written anywhere.
#
# Rows are dispatched one at a time, so a row's tokens are the lines appended
# between br_opt_prof_row_begin and br_opt_prof_row_end.
#
# Off: BR_PROFILE=0 (a lib.br-repeat-cuts settings row or the env) or
# the br-profile-off switch (lane_switch: a switch.br-profile-off settings row,
# else flags/br-profile-off). Then nothing is defined and every hook is a
# `command -v` miss.

command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply br-repeat-cuts >/dev/null 2>&1
if [ "${BR_PROFILE:-1}" = 0 ] || [ "${BR_FIX_HERE:-0}" = 1 ] \
   || { command -v lane_switch >/dev/null 2>&1 && lane_switch br-profile-off file; }; then
  return 0
fi

# _br_prof_shape <path> — the fixed word for a REST path.
_br_prof_shape() {
  case "${1%%\?*}" in
    search/*)                        echo search ;;
    repos/*/*/pulls/[0-9]*/files)    echo pulls-files ;;
    repos/*/*/pulls/[0-9]*/reviews*) echo reviews ;;
    repos/*/*/pulls/[0-9]*/commits*) echo commits ;;
    repos/*/*/pulls/[0-9]*/*)        echo other ;;
    repos/*/*/pulls/[0-9]*)          echo pulls ;;
    repos/*/*/issues/[0-9]*/comments) echo issue-comments ;;
    repos/*/*/issues/[0-9]*)         echo issues ;;
    repos/*/*/compare/*)             echo compare ;;
    *)                               echo other ;;
  esac
}

# THE WRAPS. The lane's `gh` is bin/lib/gh-limit-logger.sh's function when that
# file is on the box, else the binary; _jobs_req is bin/jobs-client.sh's
# (bin/lib/jobs/req.sh) on a box with a worker. A lib that sources one of those
# files again later (bin/lib/lane-gate.sh's _lg_ensure_client does, from the
# per-row project-hold check) puts the bare function back, so _br_prof_wrap is
# asked again at every stage mark and before every row, in the lane's shell.
# It wraps only a function that is not wrapped already.
_br_prof_wrap() {
  if ! declare -f gh 2>/dev/null | grep -q '_br_prof_gh "\$@"'; then
    if declare -F gh >/dev/null 2>&1; then
      eval "$(declare -f gh | sed '1s/^gh /_br_prof_gh /')"
    else
      _br_prof_gh() { command gh "$@"; }
    fi
    gh() {
      if [ "${1:-}" = api ]; then
        if [ "${2:-}" = -i ] && [ "${3:-}" = -X ]; then
          br_count "gh ${4:-?} $(_br_prof_shape "${5:-}")"
        else
          br_count "gh RAW $(_br_prof_shape "${2:-}")"
        fi
      fi
      _br_prof_gh "$@"
    }
  fi
  if declare -F _jobs_req >/dev/null 2>&1 \
     && ! declare -f _jobs_req | grep -q '_br_prof_jobs_req "\$@"'; then
    eval "$(declare -f _jobs_req | sed '1s/^_jobs_req /_br_prof_jobs_req /')"
    _jobs_req() {
      local seg="${2:-}"
      seg="${seg#/api/}"; seg="${seg%%\?*}"; seg="${seg%%/*}"
      br_count "d1 ${seg:-other}"
      _br_prof_jobs_req "$@"
    }
  fi
  return 0
}
_br_prof_wrap

_br_prof_now() { printf '%s' "${EPOCHREALTIME:-$(date +%s.%N)}"; }
# _br_prof_secs <from> <to> — whole seconds between two EPOCHREALTIME stamps.
_br_prof_secs() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN { d = b - a; if (d < 0) d = 0; printf "%d", d }'; }

declare -gA _BR_PROF_STAGE=()
_BR_PROF_ROWS=0
_BR_PROF_FILE=""

# br_opt_prof_stage <discovery|prepass|order|loop> — the start of a stage, in
# the parent shell. A stage that never started reads 0 seconds.
br_opt_prof_stage() {
  _br_prof_wrap
  _BR_PROF_STAGE[${1:-other}]=$(_br_prof_now)
  return 0
}

# br_opt_prof_row_begin — before the row's subshell.
br_opt_prof_row_begin() {
  _br_prof_wrap
  _BR_PROF_ROW_LINE=0
  [ -n "${TICK_COUNTS:-}" ] && _BR_PROF_ROW_LINE=$(wc -l < "$TICK_COUNTS" 2>/dev/null)
  case "$_BR_PROF_ROW_LINE" in ''|*[!0-9]*) _BR_PROF_ROW_LINE=0 ;; esac
  _BR_PROF_ROW_T=$(_br_prof_now)
  return 0
}

# _br_prof_file — this run's TSV in _BR_PROF_FILE, made on first use. Called as
# a plain command, never in `$( )`, so the name stays in the lane's shell.
# Retention runs here, once.
_br_prof_file() {
  [ -n "$_BR_PROF_FILE" ] && return 0
  # A project run (BH-5913) names its files for its project and keeps its own
  # retention, so one busy project's runs never push another project's out.
  local d="$ST/profile" pfx="${ONLY:+$ONLY.}" keep
  mkdir -p "$d" 2>/dev/null || return 1
  _BR_PROF_FILE="$d/$pfx$(date -u +%Y%m%dT%H%M%SZ).$$.tsv"
  : > "$_BR_PROF_FILE" 2>/dev/null || { _BR_PROF_FILE=""; return 1; }
  keep="${BR_PROFILE_KEEP:-24}"
  case "$keep" in ''|*[!0-9]*|0) keep=24 ;; esac
  # Newest first by mtime; this run's file is the newest, so it is always kept.
  ls -1t "$d/$pfx"*.tsv 2>/dev/null | tail -n +"$((keep + 1))" | while IFS= read -r f; do rm -f "$f"; done
  return 0
}

# br_opt_prof_row_end <p> <rkey> <src> <reason> <rc> — after the row's subshell.
br_opt_prof_row_end() {
  local f secs counts
  [ -n "${_BR_PROF_ROW_T:-}" ] || return 0
  secs=$(_br_prof_secs "$_BR_PROF_ROW_T" "$(_br_prof_now)")
  _BR_PROF_ROW_T=""
  counts="0 0 0 0 0 0 0 0"
  if [ -n "${TICK_COUNTS:-}" ]; then
    counts=$(tail -n +"$((_BR_PROF_ROW_LINE + 1))" "$TICK_COUNTS" 2>/dev/null | awk '
      /^gh /                 { g++ }
      /^gh [A-Z]+ search$/   { s++ }
      /^gh [A-Z]+ pulls$/    { pu++ }
      /^gh [A-Z]+ (issues|issue-comments)$/ { i++ }
      /^d1 /                 { d++ }
      $0 == "llm"            { l++ }
      $0 == "memo-hit"       { m++ }
      $0 == "unchanged"      { u++ }
      END { printf "%d %d %d %d %d %d %d %d", g, s, pu, i, d, l, m, u }')
  fi
  _br_prof_file || return 0
  f="$_BR_PROF_FILE"
  _BR_PROF_ROWS=$((_BR_PROF_ROWS + 1))
  # shellcheck disable=SC2086 # counts is eight integers, split on purpose
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${1:--}" "${2:--}" "${3:--}" "${4:--}" "${5:-0}" "$secs" $counts >> "$f" 2>/dev/null || true
  return 0
}

# br_opt_prof_tick_end — the `prof:` line, right after the `tick:` line.
br_opt_prof_tick_end() {
  local now st t0 secs dis pre ord lop tot top="" f
  now=$(_br_prof_now)
  # Stage seconds: from a stage's start to the next stage that started, the
  # last one to now.
  local -a names=(discovery prepass order loop) d=()
  local i j nxt
  for i in 0 1 2 3; do
    d[$i]=0
    st="${_BR_PROF_STAGE[${names[$i]}]:-}"
    [ -n "$st" ] || continue
    nxt="$now"
    for ((j = i + 1; j < 4; j++)); do
      if [ -n "${_BR_PROF_STAGE[${names[$j]}]:-}" ]; then nxt="${_BR_PROF_STAGE[${names[$j]}]}"; break; fi
    done
    d[$i]=$(_br_prof_secs "$st" "$nxt")
  done
  dis=${d[0]}; pre=${d[1]}; ord=${d[2]}; lop=${d[3]}
  t0="${TICK_START:-}"
  case "$t0" in ''|*[!0-9]*) secs=0 ;; *) secs=$(_br_prof_secs "$t0" "$now") ;; esac
  tot="0 0 0 0 0 0 0 0 0"
  if [ -n "${TICK_COUNTS:-}" ]; then
    tot=$(awk '
      /^gh [A-Z]+ /          { if ($2 == "RAW") r++; else g++ }
      /^gh [A-Z]+ search$/   { if ($2 != "RAW") s++ }
      /^gh [A-Z]+ pulls$/    { if ($2 != "RAW") pu++ }
      /^gh [A-Z]+ (issues|issue-comments)$/ { if ($2 != "RAW") i++ }
      /^d1 /                 { d++ }
      $0 == "llm"            { l++ }
      $0 == "memo-hit"       { m++ }
      $0 == "unchanged"      { u++ }
      END { printf "%d %d %d %d %d %d %d %d %d", g, s, pu, i, r, d, l, m, u }' "$TICK_COUNTS" 2>/dev/null)
  fi
  local g s pu is r d1 l m u grows=0
  read -r g s pu is r d1 l m u <<<"$tot"
  f="$_BR_PROF_FILE"
  if [ -n "$f" ] && [ -s "$f" ]; then
    grows=$(awk -F'\t' '{ s += $7 } END { printf "%d", s }' "$f" 2>/dev/null)
    top=$(sort -t$'\t' -k6,6nr "$f" 2>/dev/null | head -5 | awk -F'\t' '{ printf "%s%s/%s:%ss", (NR > 1 ? " " : ""), $1, $2, $6 }')
  fi
  say "prof: secs=$secs discovery=$dis prepass=$pre order=$ord loop=$lop rows=$_BR_PROF_ROWS gh=${g:-0} gh_rows=${grows:-0} search=${s:-0} pulls=${pu:-0} issues=${is:-0} raw=${r:-0} d1=${d1:-0} llm=${l:-0} memo_hits=${m:-0} unchanged=${u:-0} discovery_rows=${RAWCOUNT:-0} retired_skipped=${BDI_SKIPPED:-0} discovery_src=${BDI_SRC:--} project=${ONLY:-fleet} top=[$top]"
  return 0
}
