#!/bin/bash
# shellcheck shell=bash
# bin/lib/model-watch-suggest.sh — BH-3427 (BH-3422.2): the model-watch route
# matcher, $/day delta, liveness probe and Telegram message composer. Sourced,
# never run. The caller sources bin/lib/model-watch.sh first (mw_norm_id,
# mw_set_state); a function that needs one of those returns 1 when it is not
# defined. The root is ${HARNESS:-${H:-}} with no default (D43).
#
# mw_family <id>
#   mw_norm_id, then the first run of 1-3 digit tokens collapsed to one `#`:
#   <fam>-5-5 -> <fam>-#, <fam>-5-5-mini -> <fam>-#-mini. No run: the whole id.
# mw_version <id>
#   That run joined with `.` (5-5 -> 5.5). Empty line when there is no run.
# _mws_ver_gt <a> <b>
#   rc 0 when dotted a > b, the shorter tuple padded with 0 (5 == 5.0).
# mw_match_routes <vendor> <new id> <routes json>
#   <routes json> is an array of model_routes rungs {project, role, position,
#   model, runner}. The rung vendor comes from its runner (claude anthropic,
#   codex openai, grok xai, fireworks fireworks; any other runner never
#   matches). A rung matches on the same vendor, the same mw_family and a
#   strictly higher mw_version. Prints [{project, role, position, runner,
#   from}] sorted by project (hub first), role, position; [] for no match.
#   rc 1 and nothing when the routes are not a JSON array.
# mw_delta_per_day <old id> <new price> <old price> <usage> [new id]
#   A price is one model-prices per_token object {prompt, completion,
#   cache_read, cache_write} (USD/token); <usage> is {rows, tokens:{prompt,
#   completion, cache_read, cache_write}} over 7 days of the old model, or the
#   usage route's own flat body {rows, input_toks, output_toks, cache_read,
#   cache_write}, folded into that shape first. Prints
#   one line, rc 0: `unknown (usage unreadable)`, `no spend on <old> in 7
#   days`, `unknown (no list price for <id>)` (a missing prompt/completion
#   price, or a cache price missing where that kind has tokens), else
#   `+$X.XX/day`, `-$X.XX/day` or `$0.00/day`. A missing price is never 0.
# mw_probe_verdict <rc> <envelope file> <requested id>
#   Prints {verdict, served, rc, cost_usd, cli[, reason]}: rc 74..79 or no
#   readable envelope -> not-run; a .modelUsage key equal to the requested id
#   (both mw_norm_id'd) with rc 0 -> live; other keys only -> fallback
#   (served = first key); else failed. cost_usd is .total_cost_usd or null;
#   cli is $MWS_CLI_VERSION or null.
# mw_probe_line <probe json>
#   The one `Probe: ...` line for a verdict.
# mw_probe_run <vendor> <id> <outdir>
#   anthropic only (else a not-run JSON, rc 0). MODEL_WATCH_PROBE_USD_CAP
#   (default 1; 0 = `probe disabled`, rc 0; not a number = rc 1, no call).
#   No executable $root/bin/agent-call.sh: not-run, rc 1. DEDUP BEFORE SPEND:
#   the model_watch row is read (mw_get) first; an unreadable list, or no row
#   for (vendor, id), is rc 1 with no PUT and no call. A row that already has
#   probe_attempted_at is not probed again (not-run, `already probed at <ts>`,
#   rc 0) unless its stored verdict is not-run, which billed nothing; a stamp
#   with no verdict is a lost, possibly billed, probe and is not re-bought.
#   Then mw_set_state
#   {probe_attempted_at} (a failed PUT is rc 1, nothing printed, no call), one
#   `probe` call through agent-call.sh capped at the cap, mw_probe_verdict,
#   mw_set_state {probe}. Prints the verdict; rc 0, or rc 2 when that last
#   PUT failed.
# mw_cli_lag <probed version> <cli-versions json>
#   Over the /api/metrics/cli-versions body, the latest claude row per box:
#   `CLI behind on: <box> (<ver>)` per box below the probed version, or one
#   of `CLI versions: unreadable | no rows | unknown (probe CLI version not
#   read) | every box at <v> or newer`.
# mw_message <row json> <suggestion json> <delta> <probe json> <cli lag>
#   The plain-text Telegram message for one model_watch row. <suggestion
#   json> is {routes: <mw_match_routes output>, prices: {<from>: <price>}}.
#   The `Approve:` line is printed only for a live probe, at least one route
#   and an executable $root/bin/model-watch-approve.sh. rc 1 and nothing when
#   the row is not a JSON object.

_mws_root() { printf '%s' "${HARNESS:-${H:-}}"; }

# jq: a per-token USD price as "$X.XX" per 1M tokens, "n/a" for anything else.
_MWS_JQ_USD='def usd: if type == "number" then (. * 100000000 | round) as $c
  | "$\($c / 100 | floor).\($c % 100 | tostring | ("0" + .)[-2:])" else "n/a" end; '

# _mws_split <normalized id>: prints "<family>\t<version>".
_mws_split() {
  local tok fam="" ver="" state=0
  local -a toks
  IFS=- read -ra toks <<<"$1"
  for tok in "${toks[@]}"; do
    if [ "$state" -lt 2 ] && [[ $tok =~ ^[0-9]{1,3}$ ]]; then
      [ "$state" = 0 ] && fam+="${fam:+-}#"
      state=1
      ver+="${ver:+.}$tok"
      continue
    fi
    [ "$state" = 1 ] && state=2
    fam+="${fam:+-}$tok"
  done
  printf '%s\t%s\n' "$fam" "$ver"
}

mw_family() {
  declare -F mw_norm_id >/dev/null || return 1
  local n s
  n=$(mw_norm_id "${1:-}") || return 1
  s=$(_mws_split "$n")
  printf '%s\n' "${s%%$'\t'*}"
}

mw_version() {
  declare -F mw_norm_id >/dev/null || return 1
  local n s
  n=$(mw_norm_id "${1:-}") || return 1
  s=$(_mws_split "$n")
  printf '%s\n' "${s#*$'\t'}"
}

_mws_ver_gt() {
  local -a a b
  local i n x y
  IFS=. read -ra a <<<"${1:-}"
  IFS=. read -ra b <<<"${2:-}"
  n=${#a[@]}; [ "${#b[@]}" -gt "$n" ] && n=${#b[@]}
  for ((i = 0; i < n; i++)); do
    x=${a[i]:-0}; y=${b[i]:-0}
    [[ $x =~ ^[0-9]+$ && $y =~ ^[0-9]+$ ]] || return 1
    ((10#$x > 10#$y)) && return 0
    ((10#$x < 10#$y)) && return 1
  done
  return 1
}

mw_match_routes() {
  declare -F mw_norm_id >/dev/null || return 1
  local vendor new=${2:-} routes=${3:-} s nfam nver i=0 runner model rv rfam idx="" tsv
  vendor=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  jq -e 'type == "array"' <<<"$routes" >/dev/null 2>&1 || return 1
  s=$(_mws_split "$(mw_norm_id "$new")") || return 1
  nfam=${s%%$'\t'*}; nver=${s#*$'\t'}
  if [ -n "$nver" ]; then
    # Read the whole stream first: a bad rung part-way through is rc 1, not the
    # matches found before it.
    tsv=$(jq -r '.[] | [(.runner // "" | tostring), (.model // "" | tostring)] | @tsv' <<<"$routes" 2>/dev/null) \
      || return 1
    while IFS=$'\t' read -r runner model; do
      [ -n "$runner$model" ] || { i=$((i + 1)); continue; }
      case "$runner" in
        claude) rv=anthropic ;; codex) rv=openai ;; grok) rv=xai ;; fireworks) rv=fireworks ;; *) rv="" ;;
      esac
      if [ -n "$rv" ] && [ "$rv" = "$vendor" ] && s=$(_mws_split "$(mw_norm_id "$model")"); then
        rfam=${s%%$'\t'*}
        [ "$rfam" = "$nfam" ] && _mws_ver_gt "$nver" "${s#*$'\t'}" && idx+="${idx:+,}$i"
      fi
      i=$((i + 1))
    done <<<"$tsv"
  fi
  jq -c --argjson idx "[$idx]" '[ .[$idx[]] | {project, role, position, runner, from: .model} ]
    | sort_by(.project // "", .role, .position)' <<<"$routes"
}

mw_delta_per_day() {
  local old=${1:-} newp=${2:-} oldp=${3:-} usage=${4:-} newid=${5:-new model} d
  # GET /api/model-watch/usage answers flat {rows, input_toks, output_toks,
  # cache_read, cache_write}; fold that into the {rows, tokens} shape. A body
  # without every flat sum stays as it is and is judged below.
  usage=$(jq -c 'if type == "object" and (has("tokens") | not)
      and all(.input_toks, .output_toks, .cache_read, .cache_write; type == "number")
    then {rows, tokens: {prompt: .input_toks, completion: .output_toks,
      cache_read: .cache_read, cache_write: .cache_write}} else . end' <<<"$usage" 2>/dev/null) || usage=""
  if ! jq -e 'type == "object" and (.rows | type) == "number"
      and (.tokens | type) == "object"
      and all(.tokens[("prompt","completion","cache_read","cache_write")]; type == "number")' \
      <<<"$usage" >/dev/null 2>&1; then
    echo 'unknown (usage unreadable)'; return 0
  fi
  if jq -e '.rows == 0' <<<"$usage" >/dev/null 2>&1; then
    echo "no spend on $old in 7 days"; return 0
  fi
  # A side is priced when prompt and completion are numbers and every cache
  # kind that has tokens has a number too.
  local priced='type == "object" and (.prompt | type) == "number" and (.completion | type) == "number"
    and (. as $p | all("cache_read", "cache_write"; ($u.tokens[.] == 0) or (($p[.] | type) == "number")))'
  if ! jq -e --argjson u "$usage" "$priced" <<<"$newp" >/dev/null 2>&1; then
    echo "unknown (no list price for $newid)"; return 0
  fi
  if ! jq -e --argjson u "$usage" "$priced" <<<"$oldp" >/dev/null 2>&1; then
    echo "unknown (no list price for $old)"; return 0
  fi
  d=$(jq -rn --argjson n "$newp" --argjson o "$oldp" --argjson u "$usage" '
    [ ("prompt","completion","cache_read","cache_write") as $k
      | if $u.tokens[$k] == 0 then 0 else $u.tokens[$k] * ($n[$k] - $o[$k]) end ] | add / 7') || {
    echo 'unknown (usage unreadable)'; return 0; }
  awk -v v="$d" 'BEGIN { v += 0; r = sprintf("%.2f", v < 0 ? -v : v)
    if (r + 0 == 0) print "$0.00/day"; else printf "%s$%s/day\n", (v < 0 ? "-" : "+"), r }'
}

# _mws_v <verdict> <served|""> <reason|""> <rc> <cost json>: one verdict object.
_mws_v() {
  jq -nc --arg v "$1" --arg s "$2" --arg r "$3" --argjson rc "$4" --argjson c "$5" --arg cli "${MWS_CLI_VERSION:-}" \
    '{verdict:$v, served:(if $s == "" then null else $s end), rc:$rc, cost_usd:$c,
      cli:(if $cli == "" then null else $cli end)} + (if $r == "" then {} else {reason:$r} end)'
}

mw_probe_verdict() {
  declare -F mw_norm_id >/dev/null || return 1
  local rc=${1:-} env=${2:-} req=${3:-} want key served="" keys=() cost=null
  [[ $rc =~ ^[0-9]+$ ]] || return 1
  if [ "$rc" -ge 74 ] && [ "$rc" -le 79 ]; then _mws_v not-run "" "rc $rc" "$rc" "$cost"; return 0; fi
  if [ ! -s "$env" ] || ! jq -e 'type == "object"' "$env" >/dev/null 2>&1; then
    _mws_v not-run "" "no envelope" "$rc" "$cost"; return 0
  fi
  cost=$(jq -c '.total_cost_usd | if type == "number" then . else null end' "$env")
  mapfile -t keys < <(jq -r '.modelUsage | if type == "object" then keys[] else empty end' "$env")
  want=$(mw_norm_id "$req")
  if [ "$rc" = 0 ] && [ -n "$want" ]; then
    for key in ${keys[@]+"${keys[@]}"}; do
      [ "$(mw_norm_id "$key")" = "$want" ] && { served=$key; break; }
    done
    [ -n "$served" ] && { _mws_v live "$served" "" "$rc" "$cost"; return 0; }
  fi
  if [ "${#keys[@]}" -gt 0 ]; then
    for key in "${keys[@]}"; do
      [ "$(mw_norm_id "$key")" = "$want" ] && { _mws_v failed "" "" "$rc" "$cost"; return 0; }
    done
    _mws_v fallback "${keys[0]}" "" "$rc" "$cost"; return 0
  fi
  _mws_v failed "" "" "$rc" "$cost"
}

mw_probe_line() {
  jq -r '
    if type != "object" then "Probe: unreadable"
    elif .verdict == "live" then "Probe: live (served by \(.served), "
      + (if (.cost_usd | type) == "number" then (.cost_usd * 10000 | round) as $c
           | "$\($c / 10000 | floor).\($c % 10000 | tostring | ("000" + .)[-4:])" else "cost unknown" end) + ")"
    elif .verdict == "fallback" then "Probe: NOT live (silent fallback: served by \(.served))"
    elif .verdict == "not-run" then "Probe: not run (\(.reason // ("rc \(.rc)")))"
    elif .verdict == "failed" then "Probe: failed (rc \(.rc))"
    else "Probe: unreadable" end' <<<"${1:-}" 2>/dev/null || echo 'Probe: unreadable'
}

mw_probe_run() {
  declare -F mw_norm_id >/dev/null && declare -F mw_set_state >/dev/null && declare -F mw_get >/dev/null || return 1
  local vendor id=${2:-} outdir=${3:-} cap root nid now rc verdict cliv list row prior
  vendor=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  [ -n "$vendor" ] && [ -n "$id" ] && [ -n "$outdir" ] || return 1
  if [ "$vendor" != anthropic ]; then
    jq -nc --arg v "$vendor" '{verdict:"not-run", reason:("no probe runner for " + $v)}'; return 0
  fi
  cap=${MODEL_WATCH_PROBE_USD_CAP:-1}
  if ! [[ $cap =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "model-watch-suggest: MODEL_WATCH_PROBE_USD_CAP=$cap is not a number; no probe" >&2; return 1
  fi
  if awk -v c="$cap" 'BEGIN { exit !(c + 0 == 0) }'; then
    echo '{"verdict":"not-run","reason":"probe disabled"}'; return 0
  fi
  root=$(_mws_root)
  if [ -z "$root" ] || [ ! -x "$root/bin/agent-call.sh" ]; then
    echo '{"verdict":"not-run","reason":"no agent-call"}'; return 1
  fi
  nid=$(mw_norm_id "$id") || return 1
  # The persisted "have we already paid for this?" check, before any spend.
  list=$(mw_get "" "$vendor") || { echo "model-watch-suggest: model_watch list unreadable; no probe" >&2; return 1; }
  row=$(jq -c --arg v "$vendor" --arg m "$nid" \
    'first(.rows[] | select((.vendor // "" | ascii_downcase) == $v and (.model_id // "" | ascii_downcase) == $m)) // empty' \
    <<<"$list" 2>/dev/null) || row=""
  if [ -z "$row" ]; then
    echo "model-watch-suggest: no readable model_watch row for $vendor/$nid; no probe" >&2; return 1
  fi
  prior=$(jq -r '.probe_attempted_at // ""' <<<"$row")
  if [ -n "$prior" ] && [ "$(jq -r '(.probe // "") | (fromjson? // {}) | .verdict // ""' <<<"$row" 2>/dev/null)" != not-run ]; then
    jq -nc --arg t "$prior" '{verdict:"not-run", reason:("already probed at " + $t)}'; return 0
  fi
  mkdir -p "$outdir" || return 1
  # A stale envelope from an earlier probe must never be read as this one's.
  rm -f "$outdir/out.json"
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  mw_set_state "$(jq -nc --arg v "$vendor" --arg m "$nid" --arg t "$now" '{vendor:$v, model_id:$m, probe_attempted_at:$t}')" \
    >/dev/null || return 1
  cliv=$(timeout 10 claude --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)
  AGENT_CALL_RUNNERS=claude RUNNER_PROBE=claude AGENT_CALL_BUDGET_USD_PROBE="$cap" AGENT_CALL_LEDGER=0 \
    AGENT_CALL_FP="model-watch:$vendor:$nid" \
    "$root/bin/agent-call.sh" probe model-watch "$id" 120 "$outdir/out" "Reply with the single word OK." >&2
  rc=$?
  verdict=$(MWS_CLI_VERSION="$cliv" mw_probe_verdict "$rc" "$outdir/out.json" "$id") || return 1
  printf '%s\n' "$verdict"
  mw_set_state "$(jq -nc --arg v "$vendor" --arg m "$nid" --arg p "$verdict" '{vendor:$v, model_id:$m, probe:$p}')" \
    >/dev/null || return 2
  return 0
}

mw_cli_lag() {
  local probed=${1:-} in=${2:-} box ver n=0 unknown=0 tsv
  if ! jq -e '(.cli_versions | type) == "array" and all(.cli_versions[]; type == "object")' \
      <<<"$in" >/dev/null 2>&1; then
    echo 'CLI versions: unreadable'; return 0
  fi
  if ! jq -e 'any(.cli_versions[]; .cli == "claude")' <<<"$in" >/dev/null 2>&1; then
    echo 'CLI versions: no rows'; return 0
  fi
  if [ -z "$probed" ]; then
    echo 'CLI versions: unknown (probe CLI version not read)'; return 0
  fi
  tsv=$(jq -r '[.cli_versions[] | select(.cli == "claude")] | group_by(.box) | map(max_by(.at // ""))
    | sort_by(.box) | .[] | [(.box | tostring), (.version_after // "" | tostring)] | @tsv' <<<"$in" 2>/dev/null) || {
    echo 'CLI versions: unreadable'; return 0
  }
  while IFS=$'\t' read -r box ver; do
    ver=$(grep -oE '[0-9]+(\.[0-9]+)*' <<<"$ver" | head -1)
    if [ -z "$ver" ]; then
      echo "CLI version unknown on: $box"; unknown=1
    elif _mws_ver_gt "$probed" "$ver"; then
      echo "CLI behind on: $box ($ver)"; n=$((n + 1))
    fi
  done <<<"$tsv"
  [ "$n" = 0 ] && [ "$unknown" = 0 ] && echo "CLI versions: every box at $probed or newer"
  return 0
}

mw_message() {
  local row=${1:-} sug=${2:-} delta=${3:-} probe=${4:-} lag=${5:-} root approve="" verdict nroutes
  jq -e 'type == "object"' <<<"$row" >/dev/null 2>&1 || return 1
  jq -e 'type == "object"' <<<"$sug" >/dev/null 2>&1 || sug='{}'
  jq -r --arg or "${OR_BASE:-}" "$_MWS_JQ_USD"'
    "New model: \(.slug // .model_id) (\(.model_id))",
    "Released \(.released_at // "date unknown"). Source: "
      + (if .source == "openrouter" and (.slug // "") != "" then
           (if $or != "" then ($or | sub("/+$"; "")) + "/" + .slug else "OpenRouter (no base URL configured)" end)
         else "Anthropic Models API" end),
    "List price per 1M in/out: \(.prompt | usd) / \(.completion | usd)"' <<<"$row" || return 1
  jq -r "$_MWS_JQ_USD"'
    (.prices // {}) as $p
    | if (.routes | type) == "array" then
        ([.routes[].from] | unique[] | . as $f
          | if ($p[$f] | type) == "object" then "vs \($f): \($p[$f].prompt | usd) / \($p[$f].completion | usd)"
            else "vs \($f): no list price" end),
        (if (.routes | length) == 0 then "Routes: none match"
         else "Routes: " + ([.routes[] | "\(.project // "hub") \(.role)#\(.position)"] | join(", ")) end)
      else "Routes: unreadable" end' <<<"$sug"
  echo "Cost delta: $delta"
  if [ -n "$probe" ]; then
    mw_probe_line "$probe"
  elif [ -n "$(jq -r '.probe_attempted_at // ""' <<<"$row")" ]; then
    echo "Probe: probe result lost (attempted $(jq -r '.probe_attempted_at' <<<"$row"))"
  else
    echo 'Probe: not run'
  fi
  [ -n "$lag" ] && printf '%s\n' "$lag"
  verdict=$(jq -r '.verdict // ""' <<<"$probe" 2>/dev/null)
  nroutes=$(jq -r 'if (.routes | type) == "array" then (.routes | length) else 0 end' <<<"$sug")
  root=$(_mws_root)
  if [ "$verdict" = live ] && [ "${nroutes:-0}" -gt 0 ] && [ -n "$root" ] && [ -x "$root/bin/model-watch-approve.sh" ]; then
    approve="Approve: $root/bin/model-watch-approve.sh $(jq -r '"\(.vendor) \(.model_id)"' <<<"$row")"
    printf '%s\n' "$approve"
  fi
  return 0
}
