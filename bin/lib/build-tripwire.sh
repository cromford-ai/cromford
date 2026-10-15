#!/bin/bash
# bin/lib/build-tripwire.sh — the BUILD TRIPWIRE (BH-3481.0 seam, BH-3481.4
# rules). Sourced by bin/lib/rb/plan.sh (CC), bin/lib/rb/gates.sh (the launch
# guard) and bin/agent-call.sh; no side effect at source time beyond defining
# functions and capturing this file's own directory.
#
# A build trips when it is spending far past what a PR costs, or when it keeps
# paying for the same guarded call. Two rules, both multiples of the operator's
# own numbers; there is NO dollar budget anywhere in this file:
#   spend   spend > BUILD_TRIPWIRE_MULT x expected, where
#           expected = usd_per_pr (cost_budget_for: conf.cost-caps.* rows,
#           catalog/cost-caps.conf) x BUILD_TRIPWIRE_SHAPE_<S|M|L|XL> for the
#           plan's last `SIZE:` line (XL when there is no plan or no size).
#           An expected of 0 unarms this rule; it never means "any spend trips".
#   repeat  BUILD_TRIPWIRE_REPEAT_MAX paid rows (cost_usd > 0) in the build's
#           cost.csv carrying one non-empty guard_fp. 0 unarms it. A
#           `<stage>-advisor` row (BH-3491) is the same call's advisor share:
#           it counts toward spend, never toward the repeat count.
# Knobs: catalog/lanes.d/_lib.build-tripwire.json, resolved at CALL time through
# lib_env_apply build-tripwire (settings row > env > the registry default, which
# the fallbacks below mirror). BUILD_TRIPWIRE=1 measures and alerts; 0 (the
# default) measures nothing.
#
# The tripwire ALERTS and never stops a build (BH-6705, the operator 2026-10-14). No
# function here kills a session, refuses a call or ends a build.
#
# Root: ${HARNESS:-${H:-}} and nothing else.
#
# What a trip writes:
#   $BUILD/tripwire-alert.txt   line 1 is the verdict, then a plain-English
#                     diagnosis. No code reads it; the page names its path.
#   $BUILD/.tripwire.claim      one trip per build dir: later checks of the
#                     dir return at once and page nothing.
#   ledger build-tripwire "<project> <KEY>" = alerted   read by the daily
#                     digest. An old `paused` row is inert: the launch guard
#                     logs one line and builds (bin/lib/rb/gates.sh).
#
#   tw_expected <project> <build-dir>
#       Prints the expected spend (%.4f), or 0 when there is no figure. rc 0.
#   tw_eval <csv> <live-usd> <expected> <mult> <repeat-max>
#       Pure. Prints one tab-separated verdict line, rc 0:
#         trip<TAB>spend<TAB>spend=..<TAB>expected=..<TAB>mult=..<TAB>threshold=..<TAB>top_fp=<fp|->:<n><TAB>unpriced_rows=..
#         trip<TAB>repeat<TAB>fp=..<TAB>count=..<TAB>max=..<TAB>spend=..<TAB>expected=..<TAB>unpriced_rows=..
#         ok<TAB>spend=..<TAB>expected=<..|unarmed><TAB>mult=..<TAB>top_fp=<fp|->:<n><TAB>unpriced_rows=..
#   tw_trip <project> <key> <build-dir> <verdict-line>
#       Alerts: tripwire-alert.txt, the `alerted` ledger row, one critical
#       page. Only the first caller per build dir does anything. rc 0 always.
#   tw_paused <project> <key>
#       rc 0 = an old paused row, 1 = no row / released / alerted, 2 = unreadable.
#   tw_check_build <project> <key> <build-dir> <live-usd>
#       Measures the build and calls tw_trip on a trip. rc 1 always and
#       prints nothing: no caller can read a stop from it.

_TW_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)

_tw_root() {
  local r="${HARNESS:-${H:-}}"
  [ -n "$r" ] || return 1
  printf '%s' "$r"
}

# _tw_knobs — sets _TW_ON _TW_MULT _TW_S _TW_M _TW_L _TW_XL _TW_RMAX. The
# gh-budget.sh pattern: lane-gate runs in a subshell, so its fail-closed
# `exit 75` cannot stop a build and it never replaces a caller's function; the
# EXIT trap hands back on fd 3 every knob that resolved.
_tw_knobs() {
  local kv k v
  kv=$(
    exec 3>&1
    command -v lib_env_apply >/dev/null 2>&1 || . "$_TW_LIB/lane-gate.sh" >/dev/null 2>&1 || exit 0
    if [ -z "${LANE_REGISTRY:-}" ] && [ ! -r "$(_lg_registry)" ] && . "$_TW_LIB/lanes-registry.sh" >/dev/null 2>&1; then
      LANE_REGISTRY=$(lanes_json_path "$_TW_LIB/../.." 2>/dev/null) && export LANE_REGISTRY
    fi
    trap 'for k in BUILD_TRIPWIRE BUILD_TRIPWIRE_MULT BUILD_TRIPWIRE_SHAPE_S BUILD_TRIPWIRE_SHAPE_M BUILD_TRIPWIRE_SHAPE_L BUILD_TRIPWIRE_SHAPE_XL BUILD_TRIPWIRE_REPEAT_MAX; do printf "%s\t%s\n" "$k" "${!k:-}" >&3; done' EXIT
    lib_env_apply build-tripwire >/dev/null 2>&1) || true
  _TW_ON="${BUILD_TRIPWIRE:-0}"
  _TW_MULT="${BUILD_TRIPWIRE_MULT:-5}"
  _TW_S="${BUILD_TRIPWIRE_SHAPE_S:-0.5}"
  _TW_M="${BUILD_TRIPWIRE_SHAPE_M:-1}"
  _TW_L="${BUILD_TRIPWIRE_SHAPE_L:-2}"
  _TW_XL="${BUILD_TRIPWIRE_SHAPE_XL:-3}"
  _TW_RMAX="${BUILD_TRIPWIRE_REPEAT_MAX:-4}"
  while IFS=$'\t' read -r k v; do
    [ -n "$v" ] || continue
    case "$k" in
      BUILD_TRIPWIRE)            _TW_ON="$v" ;;
      BUILD_TRIPWIRE_MULT)       _TW_MULT="$v" ;;
      BUILD_TRIPWIRE_SHAPE_S)    _TW_S="$v" ;;
      BUILD_TRIPWIRE_SHAPE_M)    _TW_M="$v" ;;
      BUILD_TRIPWIRE_SHAPE_L)    _TW_L="$v" ;;
      BUILD_TRIPWIRE_SHAPE_XL)   _TW_XL="$v" ;;
      BUILD_TRIPWIRE_REPEAT_MAX) _TW_RMAX="$v" ;;
    esac
  done <<<"$kv"
  return 0
}

# _tw_shape <build-dir> -> `S|M|L|XL<TAB>plan|no-plan|unparseable`
_tw_shape() {
  local b="${1:-}" w=""
  [ -n "$b" ] && [ -f "$b/plan.md" ] || { printf 'XL\tno-plan\n'; return 0; }
  read -r w _ <<<"$(sed -n 's/^SIZE:[[:space:]]*//p' "$b/plan.md" 2>/dev/null | tr -d '\r' | tail -1)" || true
  case "$w" in
    S|M|L|XL) printf '%s\tplan\n' "$w" ;;
    *) printf 'XL\tunparseable\n' ;;
  esac
  return 0
}

# _tw_per_pr <project> -> the operator's usd_per_pr, or nothing. A subshell:
# cost-budget.sh declares its arrays at top level, which inside a function
# would be function-local.
_tw_per_pr() {
  local pp=""
  read -r pp _ <<<"$( ( . "$_TW_LIB/cost-budget.sh" >/dev/null 2>&1 || exit 0; cost_budget_for "${1:-}" ) 2>/dev/null )" || true
  printf '%s' "$pp"
  return 0
}

# _tw_factor <S|M|L|XL> -> the shape factor from the resolved knobs
_tw_factor() {
  case "${1:-}" in
    S) printf '%s' "$_TW_S" ;;
    M) printf '%s' "$_TW_M" ;;
    L) printf '%s' "$_TW_L" ;;
    *) printf '%s' "$_TW_XL" ;;
  esac
}

# _tw_expect <project> <build-dir> -> tw_expected's answer on knobs already resolved
_tw_expect() {
  local per shape f
  per=$(_tw_per_pr "${1:-}")
  IFS=$'\t' read -r shape _ <<<"$(_tw_shape "${2:-}")" || true
  f=$(_tw_factor "$shape")
  awk -v u="$per" -v f="$f" 'BEGIN{
    n = "^[0-9]+(\\.[0-9]+)?$"
    if (u ~ n && f ~ n && u+0 > 0 && f+0 > 0) printf "%.4f\n", u*f; else print 0 }'
  return 0
}

# _tw_vf <verdict> <name> -> the value of name= in a verdict line
_tw_vf() {
  awk -F'\t' -v n="${2:-}=" '{ for (i = 1; i <= NF; i++) if (index($i, n) == 1) { print substr($i, length(n) + 1); break } }' <<<"${1:-}"
}

tw_expected() {
  _tw_knobs
  _tw_expect "${1:-}" "${2:-}"
  return 0
}

tw_eval() {
  local csv="${1:-}"
  [ -n "$csv" ] && [ -r "$csv" ] || csv=/dev/null
  awk -F, -v C=13 -v G=26 -v S=4 -v live="${2:-}" -v e="${3:-}" -v m="${4:-}" -v r="${5:-}" '
    function isnum(x) { return x ~ /^[0-9]+(\.[0-9]+)?$/ }
    NF == 0 { next }
    $C == "cost_usd" { next }
    {
      if (!isnum($C)) { u++; next }
      rows += $C
      # An --advisor attempt (BH-3491) writes a second row, stage <stage>-advisor,
      # with the same guard_fp: the same call, so its dollars count and it does not.
      if ($G != "" && $C + 0 > 0 && $S !~ /-advisor$/) { if (!($G in rep)) ord[++n] = $G; rep[$G]++ }
    }
    END {
      if (!isnum(live)) live = 0
      s = rows + live
      top = "-"; tn = 0
      for (i = 1; i <= n; i++) if (rep[ord[i]] > tn) { tn = rep[ord[i]]; top = ord[i] }
      earmed = isnum(e) && e + 0 > 0
      es = earmed ? sprintf("%.2f", e) : "unarmed"
      if (earmed && isnum(m) && m + 0 > 0 && s > m * e) {
        printf "trip\tspend\tspend=%.2f\texpected=%s\tmult=%s\tthreshold=%.2f\ttop_fp=%s:%d\tunpriced_rows=%d\n", s, es, m, m * e, top, tn, u
        exit
      }
      if (r ~ /^[0-9]+$/ && r + 0 >= 1 && tn >= r + 0) {
        printf "trip\trepeat\tfp=%s\tcount=%d\tmax=%d\tspend=%.2f\texpected=%s\tunpriced_rows=%d\n", top, tn, r, s, es, u
        exit
      }
      printf "ok\tspend=%.2f\texpected=%s\tmult=%s\ttop_fp=%s:%d\tunpriced_rows=%d\n", s, es, m, top, tn, u
    }' "$csv" 2>/dev/null
  return 0
}

tw_trip() {
  local p="${1:-}" k="${2:-}" b="${3:-}" v="${4:-}" root="" rule s e es t per shape why f stages d top tfp tn u arow text
  b="${b%/}"
  [ -n "$b" ] && [ -d "$b" ] || return 0
  # One caller per build dir: the live meter and CC(), or two review lenses,
  # can reach this in the same instant, and only one of them pages.
  ( set -C; : > "$b/.tripwire.claim" ) 2>/dev/null || return 0
  _tw_knobs
  rule=$(printf '%s' "$v" | cut -f2)
  s=$(_tw_vf "$v" spend)
  per=$(_tw_per_pr "$p")
  IFS=$'\t' read -r shape why <<<"$(_tw_shape "$b")" || true
  f=$(_tw_factor "$shape")
  e=$(_tw_expect "$p" "$b")
  read -r es t <<<"$(awk -v e="$e" -v m="$_TW_MULT" 'BEGIN{
    if (e + 0 > 0) printf "%.2f %.2f\n", e, m * e; else print "unarmed unarmed" }')" || true
  stages=$(awk -F, -v C=13 -v S=4 '$C != "cost_usd" && $C ~ /^[0-9]+(\.[0-9]+)?$/ { sum[$S == "" ? "-" : $S] += $C }
    END { for (x in sum) printf "%s=%.2f\n", x, sum[x] }' "$b/cost.csv" 2>/dev/null | sort | tr '\n' ' ')
  stages="${stages% }"
  d=$(tw_eval "$b/cost.csv" 0 0 0 0)
  top=$(_tw_vf "$d" top_fp); tfp="${top%:*}"; tn="${top##*:}"
  u=$(_tw_vf "$d" unpriced_rows)
  {
    printf '%s\n' "$v"
    printf 'rule: %s\n' "${rule:-?}"
    printf 'spend: %s vs expected %s x mult %s = threshold %s (usd_per_pr %s x shape factor %s)\n' \
      "${s:-?}" "$es" "$_TW_MULT" "$t" "${per:-none}" "$f"
    printf 'shape: %s (%s)\n' "$shape" "$why"
    printf 'stages: %s\n' "${stages:-none}"
    if [ "${tfp:--}" = - ]; then printf 'top repeated guard_fp: none\n'
    else printf 'top repeated guard_fp: %s x%s (paid rows)\n' "$tfp" "$tn"; fi
    printf 'unpriced rows: %s\n' "${u:-?}"
    printf 'live session: %s\n' "${SESSION_ID:-none}"
  } > "$b/tripwire-alert.txt.tmp" 2>/dev/null && mv -f "$b/tripwire-alert.txt.tmp" "$b/tripwire-alert.txt" 2>/dev/null
  root=$(_tw_root) || root=""
  arow=FAILED
  if [ -n "$root" ] && [ -x "$root/bin/jobs-client.sh" ] \
     && "$root/bin/jobs-client.sh" ledger-put build-tripwire "$p $k" alerted >/dev/null 2>&1; then
    arow=written
  fi
  printf 'alert_row: %s\n' "$arow" >> "$b/tripwire-alert.txt" 2>/dev/null || true
  text="TRIPWIRE (alert only, build continues) $p/$k ${rule:-?}: spend ${s:-?} vs expected $es x $_TW_MULT (shape $shape); top fp ${tfp:--} x${tn:-?}; build ${b##*/}; alert_row=$arow; diagnosis $b/tripwire-alert.txt"
  if [ -n "$root" ] && [ -x "$root/bin/lane-alert.sh" ]; then
    "$root/bin/lane-alert.sh" --severity critical --id "tripwire:$p:$k:${b##*/}" build-tripwire "$text" >/dev/null 2>&1 || true
  elif [ -n "$root" ] && [ -x "$root/bin/alert-line.sh" ]; then
    "$root/bin/alert-line.sh" --severity critical --id "tripwire:$p:$k:${b##*/}" --project "$p" "[build-tripwire] $text" >/dev/null 2>&1 || true
  fi
  return 0
}

tw_paused() {
  local p="${1:-}" k="${2:-}" root st="" rc=0
  if command -v job_ledger_get >/dev/null 2>&1; then
    st=$(job_ledger_get build-tripwire "$p $k" 2>/dev/null) || rc=$?
  else
    root=$(_tw_root) || return 2
    [ -x "$root/bin/jobs-client.sh" ] || return 2
    st=$("$root/bin/jobs-client.sh" ledger-get build-tripwire "$p $k" 2>/dev/null) || rc=$?
  fi
  case "$rc" in
    0) [ "$st" = paused ] && return 0; return 1 ;;
    2) return 1 ;;
    *) return 2 ;;
  esac
}

tw_check_build() {
  local p="${1:-}" k="${2:-}" b="${3:-}" live="${4:-}" e v
  [ -n "$b" ] && [ -d "$b" ] || return 1
  # Already alerted: the live meter polls every minute, so skip the re-measure.
  [ -e "$b/.tripwire.claim" ] && return 1
  _tw_knobs
  case "$(printf '%s' "$_TW_ON" | tr '[:upper:]' '[:lower:]')" in 0|off|false|no) return 1 ;; esac
  e=$(_tw_expect "$p" "$b")
  v=$(tw_eval "$b/cost.csv" "$live" "$e" "$_TW_MULT" "$_TW_RMAX")
  case "$v" in
    trip*) tw_trip "$p" "$k" "$b" "$v" ;;
  esac
  return 1
}
