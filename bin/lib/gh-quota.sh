#!/bin/bash
# bin/lib/gh-quota.sh — the GitHub quota gauge: how much of each token's REST and
# GraphQL budget is left, and one alert before the wall rather than at it.
# Sourced, never executed.
#
# THE QUESTION IT ANSWERS (BH-426). bin/lib/gh-budget.sh already pages when a
# bucket hits ZERO, which is the moment the lane has already failed. Nothing
# anywhere said how much was left BEFORE that: `fleet_status` carried an
# Anthropic `quota` block and nothing about GitHub, so "are we about to run out
# of GitHub" was answered by ssh'ing to the hub and reading a log. This library
# is the gauge and the early warning:
#
#   gh_quota_rows                 -> the JSON array bin/gh-token.sh --status
#                                    --json prints, or rc 1 and one log line
#   gh_quota_alert_pct            -> the percent-remaining threshold
#   gh_calls_top [n] [window]     -> "<caller> <count>" for the busiest scripts
#   gh_quota_alert <rows-json>    -> ONE logs/ALERTS.log line per credential
#                                    per 2h, sooner if it fell by the band,
#                                    naming the top three callers
#
# WHO RUNS IT: bin/fleet-status-push.sh, on the hub, every 10 minutes. The push
# carries the rows; the alert runs after the push and the beat, so nothing here
# can cost the dead-man signal.
#
# UNKNOWN IS LOGGED, NEVER PAGED. A token whose /rate_limit answered nothing
# reports `unreadable:true` in the payload and writes one logs/gh-quota.log line
# — it does not alert. That is the convention gh-budget.sh already set for an
# unknown budget ("an unknown budget must still let the lane proceed while
# logging the fact"), and the opposite choice would page every window forever for
# one expired cache file. A bucket whose LIMIT is 0 is the same kind of unknown:
# 0/0 is never "0% left".
#
# NO TOKEN VALUE CAN REACH THIS FILE. It consumes --json rows, which carry
# identities (`app:<owner/repo>`, `pat:default`, `pat:admin`), credentials
# (`app-installation:<id>`, `app:<owner/repo>`, the PAT identity) and numbers only.
#
# ONE LINE PER CREDENTIAL (BH-4717.2). GitHub's App bucket belongs to the
# INSTALLATION, so nine repos minted from one installation are one budget read
# nine times. The rows are grouped on `credential // identity` and the worst row
# speaks for the group; on 2026-10-05 the per-repo, per-reset-window dedupe wrote
# 84 lines for what was a handful of buckets.
[ -n "${_GHQ_LOADED:-}" ] && return 0
_GHQ_LOADED=1
_GHQ_DEFAULT_PCT=20

# The harness root is resolved per call, not at source time: bin/fleet-status-push.sh
# sources this while its own $H is already decided, and the fixtures drive it
# against a scratch tree.
_ghq_home() { printf '%s' "${HARNESS:-/root/harness}"; }

# _ghq_log <words> — one line, to logs/gh-quota.log. This is the file that says
# WHY a gh_quota key is absent from a push; a silent failure would be
# indistinguishable from a healthy box that holds no tokens.
_ghq_log() {
  local d; d="$(_ghq_home)/logs"
  { mkdir -p "$d"; printf '%s [gh-quota] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$*" >> "$d/gh-quota.log"; } \
    >/dev/null 2>&1 || true
}

# gh_quota_rows — the rows, validated. rc 0 prints a JSON array on stdout; rc 1
# prints NOTHING and names the reason in the log, in a closed vocabulary
# (helper-missing|helper-failed|nonjson). The caller turns rc 1 into an ABSENT
# `gh_quota` key — never a null one, and never an empty array, which would read
# as "this box holds no tokens" (D9/D11).
gh_quota_rows() {
  local h raw rc to=""
  h=$(_ghq_home)
  [ -x "$h/bin/gh-token.sh" ] || { _ghq_log "helper-missing $h/bin/gh-token.sh"; return 1; }
  # The helper makes one curl per token. Each of those is already -m 5, and this
  # is the belt: bin/fleet-status-push.sh is a dead-man signal, so a helper that
  # HANGS would stop it as surely as one that crashes.
  command -v timeout >/dev/null 2>&1 && to="timeout 20"
  # shellcheck disable=SC2086  # $to is "timeout 20" or empty, by design
  raw=$($to "$h/bin/gh-token.sh" --status --json 2>/dev/null); rc=$?
  if [ "$rc" != 0 ]; then _ghq_log "helper-failed rc=$rc"; return 1; fi
  if [ -z "$raw" ] || ! printf '%s' "$raw" | jq -e 'type == "array"' >/dev/null 2>&1; then
    _ghq_log nonjson
    return 1
  fi
  printf '%s' "$raw"
}

# _ghq_knob <key> <default> <min> <max> — one integer knob, DB first. Same
# resolution shape as gh-budget.sh's _ghb_resolve_threshold: a settings row an
# operator can edit in the app, the code constant only as the documented
# fallback. A value that is not an integer in min..max is logged and ignored — a
# knob is not a place to trust, and clamping it silently would hide the typo (D11).
_ghq_knob() {
  local key="$1" def="$2" lo="$3" hi="$4" val
  if command -v setting_get >/dev/null 2>&1; then
    val=$(setting_get "$key" 2>/dev/null) || true
    case "${val:-}" in
      '') ;;
      *[!0-9]*) _ghq_log "unusable setting $key='$val' — falling back to $def" ;;
      *) if [ "$val" -ge "$lo" ] && [ "$val" -le "$hi" ]; then printf '%s\n' "$val"; return 0
         else _ghq_log "out-of-range setting $key='$val' — falling back to $def"; fi ;;
    esac
  fi
  printf '%s\n' "$def"
}

# gh_quota_alert_pct — the percent-remaining threshold, 1..99.
gh_quota_alert_pct() { _ghq_knob gh_quota_alert_pct "$_GHQ_DEFAULT_PCT" 1 99; }
# gh_quota_alert_dedupe_s — seconds before one credential's line repeats.
gh_quota_alert_dedupe_s() { _ghq_knob gh_quota_alert_dedupe_s 7200 60 86400; }
# gh_quota_alert_band_pct — a fall of this many points re-fires inside the window.
gh_quota_alert_band_pct() { _ghq_knob gh_quota_alert_band_pct 10 1 99; }

# gh_calls_top [n=3] [window=3600] — "<caller> <count>", busiest first, from the
# counter bin/lib/gh-limit-logger.sh appends to. Prints nothing when no wrapped
# call happened in the window.
#
# It globs the WHOLE directory and filters on the epoch in each line rather than
# opening "this hour" and "the previous hour" by name: the writer's hour label
# comes from its own process's timezone, and the epoch does not. The directory
# holds at most a few files because the writer prunes at 180 minutes.
# Ties break on the caller name, so the same counter always yields the same line.
gh_calls_top() {
  local n="${1:-3}" win="${2:-3600}" dir now cutoff
  dir="$(_ghq_home)/logs/gh-calls"
  [ -d "$dir" ] || return 0
  now=$(date -u +%s); cutoff=$(( now - win ))
  awk -v c="$cutoff" 'NF >= 2 && $1+0 >= c { n[$2]++ }
       END { for (k in n) printf "%s %s\n", k, n[k] }' "$dir"/*.log 2>/dev/null \
    | sort -k2,2nr -k1,1 | head -n "$n"
}

# gh_calls_top_endpoints [caller] [n=10] [window=3600] — BH-8334: "<count>
# <METHOD>:<template>", busiest first, from field 5 of the same counter (a
# gh_rest-shaped call writes it; a 4-field line is not counted here). With a
# caller, only that caller's lines. Ties break on the endpoint. Prints nothing
# when no line in the window has a 5th field.
gh_calls_top_endpoints() {
  local who="${1:-}" n="${2:-10}" win="${3:-3600}" dir now cutoff
  dir="$(_ghq_home)/logs/gh-calls"
  [ -d "$dir" ] || return 0
  now=$(date -u +%s); cutoff=$(( now - win ))
  awk -v c="$cutoff" -v w="$who" 'NF >= 5 && $1+0 >= c && (w == "" || $2 == w) { n[$5]++ }
       END { for (k in n) printf "%s %s\n", n[k], k }' "$dir"/*.log 2>/dev/null \
    | sort -k1,1nr -k2,2 | head -n "$n"
}

# _ghq_top_text — the "top callers" clause. "none recorded" when the counter is
# empty, NEVER an empty list: a sentence that ends in nothing reads as "nobody
# called GitHub", which beside a drained bucket is the one thing it cannot mean
# (D13).
_ghq_top_text() {
  local rows out
  rows=$(gh_calls_top 3 3600)
  [ -n "$rows" ] || { printf 'none recorded'; return 0; }
  out=$(printf '%s\n' "$rows" | awk 'NF >= 2 { printf "%s%s %s", (NR>1 ? ", " : ""), $1, $2 }')
  [ -n "$out" ] || out='none recorded'
  printf '%s' "$out"
}

# _ghq_bucket_text <remaining> <limit> <percent-or--1> — "<r> of <l> left
# (<p>% left)", or "unknown" for a bucket whose limit was 0. 0/0 is not 0
# percent, and a bare "r/l (p%)" read as percent USED (BH-4717.2).
_ghq_bucket_text() {
  case "${3:-}" in ''|-1) printf 'unknown' ;; *) printf '%s of %s left (%s%% left)' "$1" "$2" "$3" ;; esac
}

# gh_quota_alert <rows-json> — the 20-percent alert, one line per credential.
#
# DEDUPE: flags/alerted-gh-quota-<credential> holds "<epoch> <pct>" of the last
# line. It fires again when the flag is absent or unparseable, when it is
# gh_quota_alert_dedupe_s old, or when the worst percent fell to the flagged one
# minus gh_quota_alert_band_pct or lower. A flag from the future (clock skew)
# reads as inside the window: a missed repeat, never a page storm.
#
# ORDER IS THE DURABILITY STORY: the ALERTS line is written FIRST, then the beat,
# then the dedupe flag. A crash in between can repeat one line on the next tick;
# it can never stamp a credential as alerted without having delivered the alert.
gh_quota_alert() {
  local rows="${1:-}" pct dedupe band pm now h flagdir logdir line top ident
  local cred n slugs rr rl rp gr gl gp iso w clause flag fe fpct akey
  [ -n "$rows" ] || return 1
  printf '%s' "$rows" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
  h=$(_ghq_home); flagdir="$h/flags"; logdir="$h/logs"
  mkdir -p "$flagdir" "$logdir" 2>/dev/null || true
  pct=$(gh_quota_alert_pct)
  dedupe=$(gh_quota_alert_dedupe_s)
  band=$(gh_quota_alert_band_pct)
  # Bound the flag directory the same way the counter bounds itself (D21), but
  # never inside a live window: a flag younger than the dedupe must survive.
  pm=$(( dedupe / 60 + 60 )); [ "$pm" -ge 180 ] || pm=180
  find "$flagdir" -maxdepth 1 -name 'alerted-gh-quota-*' -mmin +"$pm" -delete >/dev/null 2>&1 || true

  # Unknown rows are logged here and never reach the compare below.
  while IFS= read -r ident; do
    [ -n "$ident" ] || continue
    _ghq_log "unreadable token $ident — /rate_limit gave no numbers, not alerting"
  done < <(printf '%s' "$rows" | jq -r '.[] | select(.unreadable == true) | .identity // "?"' 2>/dev/null)

  top=$(_ghq_top_text)
  now=$(date -u +%s)
  # One TSV line per CREDENTIAL with a low row. The percent is floored, so 19.9%
  # reads 19 and the threshold compare is on integers. A bucket with limit 0
  # yields -1, which the select never treats as low and the sentence prints as
  # "unknown". `w` is the lowest LOW percent of a row; the group's worst row
  # (lowest w) gives the numbers and the reset time. No field is ever empty: a tab
  # is whitespace to `read`, so an empty one would shift every column after it.
  while IFS=$'\t' read -r cred n slugs rr rl rp gr gl gp iso w; do
    [ -n "$cred" ] || continue
    flag="$flagdir/alerted-gh-quota-$(printf '%s' "$cred" | tr -c 'A-Za-z0-9._-' '_')"
    fe=""; fpct=""
    [ -f "$flag" ] && read -r fe fpct _ < "$flag" 2>/dev/null
    # No flag, an empty legacy one or garbage reads as no flag: fire.
    case "$fe" in ''|*[!0-9]*) fe="" ;; esac
    case "$fpct" in ''|*[!0-9]*) fe="" ;; esac
    if [ -n "$fe" ]; then
      fe=$(( 10#$fe )); fpct=$(( 10#$fpct ))
      [ $(( now - fe )) -ge "$dedupe" ] || [ "$w" -le $(( fpct - band )) ] || continue
    fi
    clause=""
    if [ "$n" -ge 2 ]; then
      clause=" (shared by $n repos: $slugs"
      [ "$n" -gt 3 ] && clause="$clause +$(( n - 3 )) more"
      clause="$clause)"
    elif [ "$n" = 1 ] && [ "$cred" != "app:$slugs" ]; then
      clause=" (repo $slugs)"
    fi
    line="[gh-quota] GitHub quota low for $cred$clause: rest $(_ghq_bucket_text "$rr" "$rl" "$rp"), graphql $(_ghq_bucket_text "$gr" "$gl" "$gp"), resets at $iso — top callers last hour: $top"
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') $line" >> "$logdir/ALERTS.log"
    akey="ghquota:$cred:$now"
    if [ -x "$h/bin/beat.sh" ]; then
      "$h/bin/beat.sh" "$(jq -nc --arg akey "$akey" --arg l "$line" \
        '{kind:"fleet_alert",project:"fleet",akey:$akey,line:$l}')" >/dev/null 2>&1 || true
    fi
    printf '%s %s\n' "$now" "$w" > "$flag"
  done < <(printf '%s' "$rows" | jq -r --argjson pct "${pct:-$_GHQ_DEFAULT_PCT}" '
    [ .[] | select(.unreadable != true)
      | (.rest_limit // 0) as $rl | (.rest_remaining // 0) as $rr
      | (.graphql_limit // 0) as $gl | (.graphql_remaining // 0) as $gr
      | (if $rl > 0 then (($rr * 100) / $rl | floor) else -1 end) as $rp
      | (if $gl > 0 then (($gr * 100) / $gl | floor) else -1 end) as $gp
      | (($rp >= 0) and ($rp < $pct)) as $rlow
      | (($gp >= 0) and ($gp < $pct)) as $glow
      | select($rlow or $glow)
      | (if $rlow and ((($glow | not)) or ($rp <= $gp)) then "rest" else "graphql" end) as $b
      | {cred:(.credential // .identity // "?"), ident:(.identity // "?"), slug,
         rr:$rr, rl:$rl, rp:$rp, gr:$gr, gl:$gl, gp:$gp,
         w:(if $b == "rest" then $rp else $gp end),
         iso:(if $b == "rest" then (.resets_at.rest // "") else (.resets_at.graphql // "") end)} ]
    | group_by(.cred)[]
    | sort_by(.w, .ident) as $g
    | ([ $g[] | .slug // empty ] | unique) as $s
    | $g[0] as $x
    | [ $x.cred, ($s | length), (if $s == [] then "-" else ($s[0:3] | join(", ")) end),
        $x.rr, $x.rl, $x.rp, $x.gr, $x.gl, $x.gp,
        (if $x.iso == "" then "unknown" else $x.iso end), $x.w ]
    | @tsv' 2>/dev/null)
}
