#!/bin/bash
# bin/hub-probe.sh — BH-3450 (BH-3434.3): the hub-probe lane. A hub cron lane,
# bash + REST only, no model call.
#
# WHAT IT DOES. It claims the hub-probe requests a ticket asked for, runs each
# probe on the hub, stores the result in the worker's ledger and posts one
# marked comment on the ticket. It calls only the BH-3447 contract:
#   hp_claim / hp_result / hp_commented / hp_count_today  (bin/lib/jobs/hub-probe.sh)
#   hp_run                                                (bin/lib/hub-probes/common.sh)
#   hp_on_pass                                            (bin/lib/hub-probes/on-pass.sh)
#
# THE TICK, in this order:
#   1. lane_gate_or_exit hub-probe, then lane_env_apply hub-probe;
#   2. the hub-probe-off switch: ON writes the summary line with ` off` and
#      exits before any claim or GitHub call;
#   3. flock -n on locks/hub-probe.lock: a held lock skips the tick;
#   4. re-drive the owed comments (the spool, below), at most HUB_PROBE_TICK_CAP;
#   5. hp_claim up to HUB_PROBE_TICK_CAP rows. A failed claim logs `claim-failed`
#      and ends the tick;
#   6. per row: hp_count_today <probe> >= HUB_PROBE_DAILY_CAP, or a count that
#      could not be read, sends the row back to pending with the note
#      `deferred: daily cap` / `deferred: count unknown` (defer, never drop).
#      Otherwise hp_run, then hp_result with the output capped at 4096 bytes.
#      A failed store posts nothing. A probe in HP_SCREEN_PROBES (tracker-test,
#      BH-7936) stops at the store: a console screen reads its row, no comment
#      is owed and nothing is spooled (counted `silent`). Otherwise a stored
#      PASS calls hp_on_pass. Then the comment is owed: it is spooled and
#      delivered.
#   7. one summary line in logs/hub-probe.log:
#      <ts> claimed=<n> ran=<n> pass=<n> fail=<n> rejected=<n> deferred=<n> commented=<n> healed=<n> post-failed=<n> store-failed=<n> not-configured=<n>[ <extra>=<n>...][ claim-failed| off]
#      The extras (onpass-failed, bad-key, defer-failed, thread-unknown,
#      spool-failed, silent) appear only when non-zero.
#
# THE SPOOL. state/hub-probe/owed/<id>.json (+ <id>.out) is written only after
# hp_result answered rc 0, and it means "a comment is owed for this row". A
# finished row never comes back from /claim, so the spool is what makes a failed
# post retry on the next tick. An entry is removed only after hp_commented rc 0,
# or when the project has no GitHub-Issues board (`not-configured: comment`,
# commented_at stays NULL).
#
# DELIVERY. Before every POST the ticket's thread is read with
# gh_rest_issue_comments. `<!-- hub-probe:<id> -->` already there means a post
# landed and the stamp did not: only hp_commented runs. A thread that could not
# be read (44/75, or 1000 comments, the read's cap) posts nothing this tick. A
# POST that fails leaves commented_at NULL and the spool in place.
#
# ALERTS. At most one bin/alert-line.sh line per tick, when a store failed, a
# ticket key has no issue number, or the spool could not be written.
#
# OFF: settings row / flags/hub-probe-off (lane_switch), flags/lane-off-hub-probe
# (bin/harness-ctl.sh off hub-probe), or HUB_PROBE_TICK_CAP=0.
# Registry: catalog/lanes.d/hub-probe.json. Note:
# docs/notes/2026-09-29-BH-3434-hub-probe.md.
#
# gh-rest: no-graphql
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }

# shellcheck disable=SC1091
{
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
  . "$SELF/lib/lane-switch.sh" 2>/dev/null || true
  . "$SELF/jobs-client.sh" 2>/dev/null || true
  . "$SELF/lib/gh-rest.sh" 2>/dev/null || true
  . "$SELF/lib/gh-rest-list.sh" 2>/dev/null || true
  . "$SELF/lib/hub-probes/common.sh" 2>/dev/null || true
  . "$SELF/lib/hub-probes/on-pass.sh" 2>/dev/null || true
}
# The suite's seam: a file that overrides _jobs_req/gh_rest/hp_run with recorders.
# Sandbox only, and settable:false in the registry, so no settings row reaches it.
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${HUB_PROBE_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$HUB_PROBE_FIXTURE"
fi

command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit hub-probe
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply hub-probe
command -v hp_claim >/dev/null 2>&1 && command -v hp_run >/dev/null 2>&1 \
  && command -v hp_on_pass >/dev/null 2>&1 || {
  echo "hub-probe: contract libs missing (bin/lib/jobs/hub-probe.sh, bin/lib/hub-probes/)" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "hub-probe: jq is required" >&2; exit 1; }
command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "$H/flags/$1" ]; }

mkdir -p "$H/logs" "$H/locks" 2>/dev/null
LOG="$H/logs/hub-probe.log"
declare -A C=()
for k in claimed ran pass fail rejected deferred commented healed post-failed store-failed not-configured \
  onpass-failed bad-key defer-failed thread-unknown spool-failed silent; do C[$k]=0; done
inc() { C[$1]=$(( ${C[$1]} + 1 )); }
summary() { # summary [suffix]
  local s="" k
  for k in claimed ran pass fail rejected deferred commented healed post-failed store-failed not-configured; do
    s="$s $k=${C[$k]}"; done
  for k in onpass-failed bad-key defer-failed thread-unknown spool-failed silent; do
    [ "${C[$k]}" = 0 ] || s="$s $k=${C[$k]}"; done
  printf '%s%s%s\n' "$(date -u +%FT%TZ)" "$s" "${1:+ $1}" >> "$LOG"
}
note() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }

if lane_switch hub-probe-off file; then summary off; exit 0; fi

exec 9>"$H/locks/hub-probe.lock" || exit 0
flock -n 9 || exit 0

knum() { case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
TICK_CAP=$(knum "${HUB_PROBE_TICK_CAP:-10}" 10)
DAY_CAP=$(knum "${HUB_PROBE_DAILY_CAP:-20}" 20)
OWED="$H/state/hub-probe/owed"
mkdir -p "$OWED" 2>/dev/null
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hub-probe.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

# fence_safe: the probe output inside a fenced block. A backtick run could close
# the fence and `<!--` could forge a marker, so both are rewritten.
fence_safe() {
  local l
  while IFS= read -r l || [ -n "$l" ]; do
    l=${l//\`/\'}; l=${l//<!--/<! --}; printf '%s\n' "$l"
  done
}

# deliver <id> — post the comment the spool owes for <id>, or heal its stamp.
deliver() {
  local id="$1" j="$OWED/$1.json" o="$OWED/$1.out" project key probe verdict hs repo bp num rc seen
  IFS=$'\t' read -r project key probe verdict hs < <(jq -r \
    '[.project, .ticket_key, .probe, .verdict, (.http_status // "" | tostring)] | @tsv' "$j" 2>/dev/null)
  if [ -z "${project:-}" ] || [ -z "${probe:-}" ]; then inc bad-key; note "bad-spool id=$id"; return 0; fi
  bp=$("$SELF/fleet-conf.sh" "$project" board_prefix 2>/dev/null)
  repo=$("$SELF/fleet-conf.sh" "$project" repo 2>/dev/null)
  if [ "$bp" != "-" ] || [ -z "$repo" ]; then
    note "not-configured: comment id=$id project=$project"
    inc not-configured; rm -f -- "$OWED/$id.json" "$OWED/$id.out"; return 0
  fi
  num=${key##*-}
  [[ "$num" =~ ^[0-9]+$ ]] || { inc bad-key; note "bad-key id=$id ticket=$key"; return 0; }
  rc=0; gh_rest_issue_comments "$repo" "$num" 1000 > "$TMP/thread.json" || rc=$?
  seen=""
  [ "$rc" = 0 ] && seen=$(jq -r --arg m "<!-- hub-probe:$id -->" \
    'if type == "array" and length < 1000 then (any(.[]; (.body // "") | contains($m)) | tostring) else empty end' \
    "$TMP/thread.json" 2>/dev/null)
  case "$seen" in
    true)
      inc healed
      hp_commented "$id" && rm -f -- "$OWED/$id.json" "$OWED/$id.out"
      return 0 ;;
    false) ;;
    *) inc thread-unknown; return 0 ;;
  esac
  {
    if [ "$verdict" = pass ]; then printf '## Hub probe %s: PASS\n\n' "$probe"
    else printf '## Hub probe %s: FAIL\n\n' "$probe"; fi
    [ -n "$hs" ] && printf 'HTTP %s\n\n' "$hs"
    printf '```\n'
    [ "$verdict" = rejected ] && printf 'rejected: probe or arguments not on the allowlist\n'
    fence_safe < "$o"
    printf '```\n\n<!-- hub-probe:%s -->\n' "$id"
  } > "$TMP/body.md"
  rc=0; gh_rest POST "repos/$repo/issues/$num/comments" -F "body=@$TMP/body.md" > "$TMP/post.json" || rc=$?
  if [ "$rc" != 0 ]; then
    inc post-failed; note "post-failed id=$id rc=$rc http=${GH_REST_STATUS:-000}"; return 0
  fi
  inc commented
  # A failed stamp keeps the spool: the next tick sees the marker and heals.
  hp_commented "$id" && rm -f -- "$OWED/$id.json" "$OWED/$id.out"
  return 0
}

# defer <id> <note> — back to pending. hp_result refuses `pending` and takes no
# note, so this is the same route and key with the #3448 defer body.
defer() {
  local out
  out=$(_jobs_req POST /api/hub-probe/result "$(jq -nc --argjson i "$1" --arg n "$2" \
    '{id:$i, result:"pending", note:$n}')") \
    && printf '%s' "$out" | jq -e '.ok == true' >/dev/null 2>&1 && { inc deferred; return 0; }
  inc defer-failed; note "defer-failed id=$1"
}

# 4. Re-drive what earlier ticks still owe, oldest id first.
if [ "$TICK_CAP" -gt 0 ]; then
  for id in $(find "$OWED" -maxdepth 1 -name '*.json' -printf '%f\n' 2>/dev/null \
      | sed -n 's/^\([0-9][0-9]*\)\.json$/\1/p' | sort -n | head -n "$TICK_CAP"); do
    deliver "$id"
  done
fi

# 5. Claim.
[ "$TICK_CAP" -gt 0 ] || { summary; exit 0; }
rc=0; hp_claim "hub-probe@$(hostname -s 2>/dev/null || hostname)" "$TICK_CAP" > "$TMP/claim.json" || rc=$?
if [ "$rc" != 0 ] || ! jq -e 'type == "array"' "$TMP/claim.json" >/dev/null 2>&1; then
  summary claim-failed; exit 0
fi

# 6. Per row.
while IFS= read -r r; do
  inc claimed
  id=$(jq -r '.id // empty | tostring' <<<"$r")
  project=$(jq -r '.project // empty' <<<"$r")
  key=$(jq -r '.ticket_key // empty' <<<"$r")
  probe=$(jq -r '.probe // empty' <<<"$r")
  [[ "$id" =~ ^[0-9]+$ ]] || { inc bad-key; note "bad-row id=$id"; continue; }
  args_json=$(jq -c '(.args // (.args_json | fromjson?)) as $a
    | if ($a | type) == "array" and all($a[]; type == "string" and (contains("\n") | not)) then $a else empty end' <<<"$r" 2>/dev/null)
  n=$(hp_count_today "$probe") || n=""
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then defer "$id" "deferred: count unknown"; continue; fi
  if [ "$n" -ge "$DAY_CAP" ]; then defer "$id" "deferred: daily cap"; continue; fi
  HP_HTTP_STATUS=""
  if [ -z "$args_json" ]; then
    args_json='[]'; prc=2
    echo "arguments are not a list of strings" > "$TMP/$id.raw"
  else
    mapfile -t args < <(jq -r '.[]' <<<"$args_json")
    inc ran
    prc=0; hp_run "$probe" "${args[@]}" > "$TMP/$id.raw" 2>&1 || prc=$?
  fi
  case "$prc" in 0) verdict=pass ;; 2) verdict=rejected ;; *) verdict=fail ;; esac
  inc "$verdict"
  head -c 4096 "$TMP/$id.raw" > "$TMP/$id.out"
  hs="${HP_HTTP_STATUS:-}"
  if ! hp_result "$id" "$verdict" "$hs" "$TMP/$id.out"; then
    inc store-failed; note "store-failed id=$id"; continue
  fi
  # HP_SCREEN_PROBES is the common.sh allowlist constant, not a knob: no :- read.
  case " $HP_SCREEN_PROBES " in *" $probe "*) inc silent; continue ;; esac
  if [ "$verdict" = pass ]; then
    hp_on_pass "$project" "$key" "$probe" "$args_json" || inc onpass-failed
  fi
  if cp "$TMP/$id.out" "$OWED/$id.out" 2>/dev/null \
    && jq -nc --argjson i "$id" --arg p "$project" --arg k "$key" --arg pr "$probe" --arg v "$verdict" --arg s "$hs" \
      '{id:$i, project:$p, ticket_key:$k, probe:$pr, verdict:$v, http_status:$s}' > "$OWED/$id.json.tmp" 2>/dev/null \
    && mv "$OWED/$id.json.tmp" "$OWED/$id.json"; then
    deliver "$id"
  else
    inc spool-failed; note "spool-failed id=$id"
  fi
done < <(jq -c '.[]' "$TMP/claim.json")

summary
if [ "$(( ${C[store-failed]} + ${C[bad-key]} + ${C[spool-failed]} ))" -gt 0 ]; then
  "$SELF/alert-line.sh" --id hub-probe "hub-probe: store-failed=${C[store-failed]} bad-key=${C[bad-key]} spool-failed=${C[spool-failed]} (logs/hub-probe.log)" >/dev/null 2>&1 || true
fi
exit 0
