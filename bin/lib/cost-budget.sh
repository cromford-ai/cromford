#!/bin/bash
# bin/lib/cost-budget.sh — what a PR is allowed to cost, and the fleet's daily
# hard ceiling. Sourced, never executed.
#
# THE ALARM THIS REPLACES (2026-09-15). bin/pipeline-health.sh's spend breaker
# compared a project's 24h dollars against a flat cap — $300, hardcoded as the
# default because flags/cost-caps.conf did not exist on any box. project-5
# merged ~90 PRs that day for ~$16-40 each and the breaker paged
# "$1456 in 24h (cap $300)" four times before lunch. Nothing was wrong. A daily
# dollar cap is a budget for how much WORK the fleet may do; the thing we
# actually want bounded is the UNIT PRICE of a PR, which holds on a 3-PR day and
# a 90-PR day alike.
#
#   cost_budget_for <project>   -> "<usd_per_pr> <min_prs_for_rate>"
#   cost_budget_ceiling         -> "<usd_per_day>" (fleet, 24h, hard)
#   cost_budget_source          -> the layers that answered, joined ` + `, or
#                                  "built-in defaults"
#   cost_budget_legacy_rows     -> the rows this grammar refused, space separated
#                                  (empty when there are none)
#   cost_budget_daily <project> -> "<usd_per_day>" for that project, rc 1 when
#                                  it has no daily ceiling (BH-7876)
#   cost_budget_daily_warn_pct  -> the percent of a daily ceiling that warns
#
# Resolution, lowest to highest, each layer overriding the one below it line
# by line (BH-4155):
#   1. the constants below, the documented fallback and nothing else;
#   2. catalog/cost-caps.conf (reviewed commit; $HARNESS/catalog, else the
#      sibling ../../catalog), read only when no flags/cost-caps.conf is
#      readable;
#   3. the registry-seed settings rows (conf_rows_seeded, bin/lib/conf-row.sh),
#      the DB copy of the catalog that worker/jobs/schema.sql seeds. A
#      reviewed catalog edit still moves the cap: bin/harness-sync.sh re-seeds
#      on the hub (bin/cost-caps-seed-sync.sh) whenever the file's bytes move;
#   4. flags/cost-caps.conf (machine-local, no deploy);
#   5. the operator settings rows (BH-2411, conf_rows), box row first.
# A row's keys are `conf.cost-caps.budget.<project>` = `<per_pr> [min]`,
# `conf.cost-caps.default` = `<per_pr> [min]`, `conf.cost-caps.ceiling` =
# `<usd>`, `conf.cost-caps.<project>.daily_usd` = `<usd>` (the project's daily
# ceiling, read by bin/lib/project-ceiling.sh), `conf.cost-caps.daily_warn_pct`
# = `<1-100>`. A row this grammar refuses binds nothing and is named in
# cost_budget_legacy_rows as `seed:<key>` or `row:<key>`. With $COST_CAPS_CONF
# set (fixtures) no row of either kind is read: the first readable of it,
# flags/ and the catalog answers alone, as before.
#
# THE RATE IT GATES is a project's whole DELIVERY spend over its merged PRs —
# triage, abandoned builds and fix rounds included — measured at $40-$77/PR
# across the fleet on 2026-09-15. The defaults sit at ~2x that.
# The root, "" when neither HARNESS nor H is set (BH-2649): then only the
# sibling catalog answers and nothing is noted.
_CB_H="${HARNESS:-${H:-}}"
# shellcheck source=conf-row.sh
. "$(dirname "${BASH_SOURCE[0]}")/conf-row.sh" 2>/dev/null || true
COST_BUDGET_DEFAULT_PER_PR=100
COST_BUDGET_DEFAULT_MIN_PRS=5
COST_BUDGET_DEFAULT_CEILING=4000
COST_BUDGET_DEFAULT_DAILY_WARN_PCT=80

_CB_LOADED=""
_CB_SOURCE=""
_CB_DEF_PER_PR=""
_CB_DEF_MIN_PRS=""
_CB_CEILING=""
_CB_LEGACY=""
_CB_DAILY_WARN=""
declare -A _CB_PER_PR
declare -A _CB_MIN_PRS
declare -A _CB_DAILY

_cb_num() { # a positive number, or nothing at all — never a half-parsed threshold
  case "${1:-}" in
    ''|*[!0-9.]*) return 1 ;;
    *) awk -v v="$1" 'BEGIN{ exit !(v+0 > 0) }' && printf '%s' "$1" ;;
  esac
}

_cb_pct() { # a percent above 0 and at most 100
  _cb_num "${1:-}" >/dev/null && awk -v v="$1" 'BEGIN{ exit !(v+0 <= 100) }'
}

_cb_load() {
  [ -n "$_CB_LOADED" ] && return 0
  _CB_LOADED=1
  _CB_DEF_PER_PR="$COST_BUDGET_DEFAULT_PER_PR"
  _CB_DEF_MIN_PRS="$COST_BUDGET_DEFAULT_MIN_PRS"
  _CB_CEILING="$COST_BUDGET_DEFAULT_CEILING"
  _CB_DAILY_WARN="$COST_BUDGET_DEFAULT_DAILY_WARN_PCT"
  _CB_SOURCE=""
  local f ff=""
  # $COST_CAPS_CONF (a fixture) reads no row of either kind: the first readable
  # of it and the files below, as given, exactly as before BH-4155.
  if [ -n "${COST_CAPS_CONF:-}" ]; then
    for f in "$COST_CAPS_CONF" ${_CB_H:+"$_CB_H/flags/cost-caps.conf"} \
             ${_CB_H:+"$_CB_H/catalog/cost-caps.conf"} \
             "$(dirname "${BASH_SOURCE[0]}")/../../catalog/cost-caps.conf"; do
      [ -r "$f" ] && { _CB_SOURCE="$f"; _cb_file "$f"; break; }
    done
    _CB_SOURCE="${_CB_SOURCE:-built-in defaults}"
    return 0
  fi
  [ -n "$_CB_H" ] && [ -r "$_CB_H/flags/cost-caps.conf" ] && ff="$_CB_H/flags/cost-caps.conf"
  # The catalog, only when no flags file is readable (the first-hit rule).
  if [ -z "$ff" ]; then
    for f in ${_CB_H:+"$_CB_H/catalog/cost-caps.conf"} \
             "$(dirname "${BASH_SOURCE[0]}")/../../catalog/cost-caps.conf"; do
      [ -r "$f" ] && { _CB_SOURCE="$f"; _cb_file "$f"; break; }
    done
  fi
  # The seed rows (BH-4155): the DB copy of the catalog, above the file line.
  if command -v conf_rows_seeded >/dev/null 2>&1; then
    local sk sv seeded=""
    while IFS=$'\t' read -r sk sv; do
      [ -n "$sk" ] || continue
      _cb_row "$sk" "$sv" seed && seeded=1
    done < <(conf_rows_seeded cost-caps "$_CB_H")
    [ -n "$seeded" ] && _CB_SOURCE="${_CB_SOURCE:+$_CB_SOURCE + }settings seed conf.cost-caps.*"
  fi
  # flags/cost-caps.conf, the box-local lever, line by line above the seed.
  if [ -n "$ff" ]; then
    _CB_SOURCE="${_CB_SOURCE:+$_CB_SOURCE + }$ff"
    _cb_file "$ff"
  fi
  _CB_SOURCE="${_CB_SOURCE:-built-in defaults}"
  command -v conf_rows >/dev/null 2>&1 || return 0
  local k v ks=""
  while IFS=$'\t' read -r k v; do
    [ -n "$k" ] || continue
    _cb_row "$k" "$v" row && ks="$ks $k"
  done < <(conf_rows cost-caps "$_CB_H")
  if [ -n "$ks" ] && [ -n "$_CB_H" ]; then
    _CB_SOURCE="$_CB_SOURCE + settings conf.cost-caps.*"
    # shellcheck disable=SC2086  # the key list, one word per key
    conf_row_note_file cost-caps "$_CB_H/flags/cost-caps.conf" $ks
  fi
  return 0
}

# _cb_file <path> — every line of a cost-caps file, applied.
_cb_file() {
  local kw a b c
  while read -r kw a b c; do
    case "$kw" in ''|\#*) continue ;; esac
    _cb_line "$kw" "$a" "$b" "$c"
  done < "$1"
}

# _cb_row <key> <value> <seed|row> — one settings row through the grammar.
# rc 0 when it bound; a refused row is named `<seed|row>:<key>` in
# cost_budget_legacy_rows, and a key this grammar does not have (another box's
# row, an unknown directive) is skipped, rc 1.
_cb_row() {
  local k="$1" kw a b c x y z
  read -r x y z <<<"$2"
  case "$k" in
    budget.*.*) return 1 ;;   # another box's row, or not a key this grammar has
    budget.?*) kw=budget; a="${k#budget.}"; b="$x"; c="$y" ;;
    default|ceiling|daily_warn_pct) kw="$k"; a="$x"; b="$y"; c="" ;;
    # A project's daily ceiling. A dotted project is another box's row or a
    # key with a segment too many: not a key this grammar has.
    ?*.daily_usd)
      a="${k%.daily_usd}"
      case "$a" in *[!a-z0-9_-]*) return 1 ;; esac
      kw=daily; b="$x"; c="$y" ;;
    *) return 1 ;;
  esac
  if [ -z "$z" ] && _cb_row_ok "$kw" "$a" "$b" "$c"; then
    _cb_line "$kw" "$a" "$b" "$c"; return 0
  fi
  _CB_LEGACY="${_CB_LEGACY:+$_CB_LEGACY }$3:$k"
  return 1
}

# _cb_row_ok <kw> <a> <b> <c> — a settings row binds only when EVERY field it
# carries is one this grammar takes: a file line with a bad min column still
# binds its price, but a row is all or nothing, so a half-read row never
# overrides the file's whole line.
_cb_row_ok() {
  case "$1" in
    budget)  [ -n "$2" ] && _cb_num "$3" >/dev/null && { [ -z "$4" ] || _cb_num "$4" >/dev/null; } ;;
    default) _cb_num "$2" >/dev/null && { [ -z "$3" ] || _cb_num "$3" >/dev/null; } && [ -z "$4" ] ;;
    ceiling) _cb_num "$2" >/dev/null && [ -z "$3" ] ;;
    daily)   [ -n "$2" ] && _cb_num "$3" >/dev/null && [ -z "$4" ] ;;
    daily_warn_pct) _cb_pct "$2" && [ -z "$3" ] ;;
    *) return 1 ;;
  esac
}

# _cb_line <kw> <a> <b> <c> — one line of the grammar, applied.
_cb_line() {
  local kw="$1" a="$2" b="$3" c="$4"
  case "$kw" in
    budget)
      # A row with no project, or a price that is not a positive number, is a
      # row that cannot bind anything. It is named, not silently skipped: the
      # whole failure this file exists to end was a threshold nobody could see.
      if [ -n "$a" ] && _cb_num "$b" >/dev/null; then
        _CB_PER_PR["$a"]="$b"
        _cb_num "$c" >/dev/null && _CB_MIN_PRS["$a"]="$c"
      else
        _CB_LEGACY="${_CB_LEGACY:+$_CB_LEGACY }$kw:$a"
      fi
      ;;
    default)
      _cb_num "$a" >/dev/null && _CB_DEF_PER_PR="$a"
      _cb_num "$b" >/dev/null && _CB_DEF_MIN_PRS="$b"
      ;;
    ceiling)
      _cb_num "$a" >/dev/null && _CB_CEILING="$a"
      ;;
    daily)
      # `daily <project> <usd>`: one positive number and nothing after it. A
      # bad line binds nothing and is named, like a bad budget line.
      if [ -n "$a" ] && _cb_num "$b" >/dev/null && [ -z "$c" ]; then
        _CB_DAILY["$a"]="$b"
      else
        _CB_LEGACY="${_CB_LEGACY:+$_CB_LEGACY }$kw:$a"
      fi
      ;;
    daily_warn_pct)
      if _cb_pct "$a" && [ -z "$b" ]; then _CB_DAILY_WARN="$a"
      else _CB_LEGACY="${_CB_LEGACY:+$_CB_LEGACY }$kw"; fi
      ;;
    *)
      # THE OLD GRAMMAR, REFUSED. "project-5 300" used to mean $300 per DAY.
      # Reading it as $300 per PR would raise the bar ~10x and page for
      # nothing ever again — the same broken threshold with the alarm off.
      _CB_LEGACY="${_CB_LEGACY:+$_CB_LEGACY }$kw"
      ;;
  esac
  return 0
}

cost_budget_for() { # cost_budget_for <project> -> "<usd_per_pr> <min_prs>"
  _cb_load
  local p="${1:-}" pr min
  pr="${_CB_PER_PR[$p]:-$_CB_DEF_PER_PR}"
  min="${_CB_MIN_PRS[$p]:-$_CB_DEF_MIN_PRS}"
  printf '%s %s\n' "$pr" "$min"
}

cost_budget_ceiling() { _cb_load; printf '%s\n' "$_CB_CEILING"; }
cost_budget_source()  { _cb_load; printf '%s\n' "$_CB_SOURCE"; }
cost_budget_legacy_rows() { _cb_load; printf '%s\n' "$_CB_LEGACY"; }
# A project with no daily line or row has no daily ceiling at all: rc 1, and
# nothing reads its spend.
cost_budget_daily() {
  _cb_load
  local p="${1:-}"
  [ -n "$p" ] && [ -n "${_CB_DAILY[$p]:-}" ] || return 1
  printf '%s\n' "${_CB_DAILY[$p]}"
}
cost_budget_daily_warn_pct() { _cb_load; printf '%s\n' "$_CB_DAILY_WARN"; }

# cost_budget_rates_tsv -> one line per priced model, then a `__MAX__` line:
#   <model>\t<prompt>\t<completion>\t<cache_read>\t<cache_write>\t<cliff_tokens|"">
# per TOKEN, from the same table cost_price_tokens reads (bin/lib/cost-row.sh),
# first readable wins: $MODEL_PRICES (used as given, never fallen back from),
# state/model-prices.json (the hub's live table), the catalog beside this file,
# then $HARNESS/catalog.
#
# WHY (K1, 2026-09-24). The fleet ceiling summed only rows that carried a
# cost_usd, so a runner whose calls the ledger could not price (blank
# cost_usd, `UNPRICED:*` in the note) spent against a $4,000/day brake that
# could not see it. bin/pipeline-health.sh now prices those rows PESSIMISTICALLY
# for the brake's arithmetic only: the model's own rates when the table has
# the model, the table's highest rate per component (`__MAX__`) when it does
# not. rc 1 and nothing printed when there is no table; the caller then prices
# an unpriced row at its flat default, never at zero.
cost_budget_rates_tsv() {
  local t=""
  if [ -n "${MODEL_PRICES:-}" ]; then
    [ -r "$MODEL_PRICES" ] && t="$MODEL_PRICES"
  else
    local f
    for f in ${_CB_H:+"$_CB_H/state/model-prices.json"} \
             "$(dirname "${BASH_SOURCE[0]}")/../../catalog/model-prices.json" \
             ${_CB_H:+"$_CB_H/catalog/model-prices.json"}; do
      [ -r "$f" ] && { t="$f"; break; }
    done
  fi
  [ -n "$t" ] || return 1
  jq -r '[(.per_token // .) | to_entries[] | select(.value | type == "object")] as $e
    | ($e[] | [.key, (.value.prompt // 0), (.value.completion // 0),
               (.value.cache_read // 0), (.value.cache_write // 0),
               ((.value.cliff_tokens | numbers) // "")] | @tsv),
      (if ($e | length) > 0 then
         ["__MAX__", ([$e[].value.prompt // 0] | max), ([$e[].value.completion // 0] | max),
          ([$e[].value.cache_read // 0] | max), ([$e[].value.cache_write // 0] | max), ""] | @tsv
       else empty end)' "$t" 2>/dev/null
}
