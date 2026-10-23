#!/bin/bash
# bin/ci-minutes-watch.sh — how many CI job-minutes did the fleet's repos bill
# in the last 24h, and is that over the line? (hub, cron 4x a day)
#
# WHY (K1, 2026-09-24). CI moved to MonkCI hosted runners on 2026-09-22
# (docs/CI-RUNNERS.md). MonkCI bills per job-minute, and by 2026-09-24 the
# account was billing overage at ~120K minutes a day. Nothing in the harness
# measured it: the only signal was the invoice. MonkCI exposes no usage API
# reachable with any credential the fleet holds, so this measures the same
# quantity from GitHub, which every MonkCI job reports to.
#
# THE MEASUREMENT, BUDGETED. Exact job-minutes need one jobs read per workflow
# run, and the fleet's busiest repo merges a PR every few minutes — one read
# per run would spend the shared GitHub bucket this lane exists to protect. So
# per repo, every tick:
#   1. the completed runs created in the window: `actions/runs`, 100 a page,
#      at most CI_MINUTES_MAX_PAGES pages. Each run's WALL minutes are
#      updated_at - run_started_at, free from the list.
#   2. CI_MINUTES_SAMPLE_RUNS of those runs (unique by id, sorted by workflow
#      so the spread reaches every workflow), `actions/runs/<id>/jobs`. Each
#      job whose runner labels contain CI_MINUTES_RUNNER_MATCH bills
#      ceil((completed_at - started_at) / 60) x CI_MINUTES_BILL_MULT minutes —
#      the per-job rounding a per-minute runner vendor charges.
#   3. the repo's estimate = each workflow's wall minutes x that workflow's
#      sampled billed/wall ratio (the pooled ratio for a workflow the sample
#      missed), then x total_count / runs read when the pages held fewer runs
#      than GitHub says exist — a busy repo is EXTRAPOLATED, not capped. A repo
#      whose sample has no matching job bills 0.
# Worst case per tick: repos x (MAX_PAGES + SAMPLE_RUNS) reads (about 150 for
# the current fleet.conf). The tick is skipped outright while
# bin/lib/gh-budget.sh says the bucket is low.
#
# THE PAGE. Estimated billed minutes over CI_MINUTES_DAY_MAX (a settings row)
# is ONE critical page a day on the deterministic path (bin/lib/page-critical.sh
# — no LLM between this and the operator), naming the top repos. Every tick writes one
# log line per repo and state/ci-minutes/latest.json whether or not it pages.
# Deterministic, read-only against GitHub, never pauses anything.
#
# TWO COUNTS (BH-8049), from the same run list, no extra read. Per repo, one
# `ci-counts repo=<slug> ...` line before its estimate line, and in
# latest.json and the ci_health payload: dispatches_24h (workflow_dispatch runs,
# split by workflow name, top 5) and pushes_per_pr (per head branch, the
# distinct head SHAs of its pull_request runs: every push to a PR branch starts
# one). Both count completed runs only, the ones this lane reads.
#
# usage: ci-minutes-watch.sh [--dry-run]    --dry-run measures and prints; no page
# Kill switch: bin/harness-ctl.sh off ci-minutes-watch (flags/lane-off-ci-minutes-watch)
# Tests: tests/ci-minutes-watch.k1-test.sh
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
# >>> lane gate (BH-1165)
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit ci-minutes-watch
if [ -f "$HENV/global.env" ]; then set -a; # shellcheck disable=SC1091
  . "$HENV/global.env"; set +a; fi
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply ci-minutes-watch
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"; [ -n "$BIN" ] || BIN="$H/bin"
for _L in gh-budget.sh gh-ci-read.sh gh-repo-token.sh page-critical.sh; do
  # shellcheck source=/dev/null
  if [ -r "$BIN/lib/$_L" ]; then . "$BIN/lib/$_L"; elif [ -r "$H/bin/lib/$_L" ]; then . "$H/bin/lib/$_L"; fi
done
# The jobs client, for ci_health_put (BH-2633). Best-effort and never fatal: with
# no client the snapshot push below is a silent skip, never a failed lane.
# shellcheck source=/dev/null
. "$BIN/jobs-client.sh" 2>/dev/null || . "$H/bin/jobs-client.sh" 2>/dev/null || true
DRY=""; [ "${1:-}" = "--dry-run" ] && DRY=1
NOW="${NOW:-$(date +%s)}"
LOG="$H/logs/ci-minutes-watch.log"
STATE="$H/state/ci-minutes"
mkdir -p "$(dirname "$LOG")" "$STATE" 2>/dev/null
STAMP() { date -u -d "@$NOW" '+%Y-%m-%d %H:%M:%SZ'; }
log() { echo "$(STAMP) $*" >> "$LOG"; [ -n "$DRY" ] && echo "$*"; return 0; }
knob() { # knob <ENV> <default> — row/env via lane_env_apply, else the default; a number (decimals allowed)
  local v="${!1:-}"
  case "$v" in ''|.|*.*.*|*[!0-9.]*) v="$2" ;; esac
  printf '%s' "$v"
}
DAY_MAX=$(knob CI_MINUTES_DAY_MAX 25000); DAY_MAX="${DAY_MAX%.*}"
PAGES=$(knob CI_MINUTES_MAX_PAGES 3); PAGES="${PAGES%.*}"
SAMPLE=$(knob CI_MINUTES_SAMPLE_RUNS 10); SAMPLE="${SAMPLE%.*}"
MATCH="${CI_MINUTES_RUNNER_MATCH:-monkci}"
# MonkCI bills a 4-vCPU job-minute as 2 minutes (docs/CI-RUNNERS.md: "5,000
# minutes ~= 30 full runs at the 4-vCPU 2x rate"), so the billed figure is the
# rounded job-minutes times this.
MULT=$(knob CI_MINUTES_BILL_MULT 2)
SINCE=$(date -u -d "@$(( NOW - 86400 ))" '+%Y-%m-%dT%H:%M:%SZ')

if command -v gh_budget_low >/dev/null 2>&1 && gh_budget_low ci-minutes-watch; then
  log "skipped: the GitHub API budget is low (bin/lib/gh-budget.sh) — no reads this tick"
  exit 0
fi

REPOS=$(for P in $("$H/bin/fleet-conf.sh" --projects 2>/dev/null); do
  "$H/bin/fleet-conf.sh" "$P" repo 2>/dev/null
done | awk 'NF && $1 != "-"' | sort -u)
[ -n "$REPOS" ] || { log "no repos: fleet.conf answered nothing"; exit 0; }

CALLS=0; TOTAL=0; ROWS=""; UNREAD=""; COUNTS="{}"
for SLUG in $REPOS; do
  if command -v gh_repo_use_token >/dev/null 2>&1; then
    gh_repo_use_token "$SLUG" 2>/dev/null || { UNREAD="${UNREAD:+$UNREAD }$SLUG"; continue; }
  fi
  RUNS="[]"; FULL=0; OK=1; TOTALC=0
  for (( pg = 1; pg <= PAGES; pg++ )); do
    CALLS=$(( CALLS + 1 ))
    PAGE=$(gh_ci_api "$SLUG" -X GET "repos/$SLUG/actions/runs" -f status=completed \
             -f "created=>=$SINCE" -f per_page=100 -f "page=$pg" \
             -q '{t: (.total_count // 0), r: [.workflow_runs[]? | {id, w: (.workflow_id // 0), s: .run_started_at, e: .updated_at, ev: (.event // ""), wn: (.name // ""), b: (.head_branch // ""), h: (.head_sha // "")}]}' 2>/dev/null) || { OK=0; break; }
    [ -n "$PAGE" ] || PAGE='{"t":0,"r":[]}'
    [ "$pg" = 1 ] && TOTALC=$(jq -r '.t // 0' <<<"$PAGE" 2>/dev/null || echo 0)
    RUNS=$(jq -c --argjson p "$PAGE" '. + ($p.r // [])' <<<"$RUNS" 2>/dev/null) || { OK=0; break; }
    N=$(jq '.r | length' <<<"$PAGE" 2>/dev/null || echo 0)
    [ "$N" -ge 100 ] || { FULL=0; break; }
    FULL=1
  done
  if [ "$OK" = 0 ]; then UNREAD="${UNREAD:+$UNREAD }$SLUG"; continue; fi
  # A run that moved between two page reads appears on both: once per id.
  # Wall minutes per run; the list sorted by (workflow, id) so the evenly spread
  # sample reaches every workflow in proportion to its runs.
  RUNS=$(jq -c '[unique_by(.id)[] | select(.s and .e)
      | . + {m: (((.e | fromdateiso8601) - (.s | fromdateiso8601)) / 60)} | select(.m >= 0)]
      | sort_by(.w, .id)' <<<"$RUNS" 2>/dev/null) || RUNS="[]"
  read -r NRUNS WALL <<<"$(jq -r '"\(length) \(map(.m) | add // 0)"' <<<"$RUNS" 2>/dev/null)"
  NRUNS="${NRUNS:-0}"; WALL="${WALL:-0}"; TOTALC="${TOTALC:-0}"
  IDS=$(jq -r --argjson k "$SAMPLE" '. as $r | length as $n
      | if $n == 0 or $k == 0 then empty
        else [range(0; ([$k, $n] | min))] | map(($n * . / ([$k, $n] | min)) | floor) | unique[]
             | $r[.] | .id end' <<<"$RUNS" 2>/dev/null)
  SAMP="[]"; SN=0
  for ID in $IDS; do
    CALLS=$(( CALLS + 1 ))
    J=$(gh_ci_api "$SLUG" "repos/$SLUG/actions/runs/$ID/jobs?per_page=100" 2>/dev/null) || continue
    JB=$(jq -r --arg m "$MATCH" --argjson x "$MULT" '[.jobs[]? | select(.started_at and .completed_at)
        | select([.labels[]?, (.runner_name // "")] | map(ascii_downcase) | any(contains($m | ascii_downcase)))
        | (((.completed_at | fromdateiso8601) - (.started_at | fromdateiso8601)) / 60) | select(. > 0) | ceil * $x]
        | add // 0' <<<"$J" 2>/dev/null)
    SAMP=$(jq -c --argjson id "$ID" --argjson b "${JB:-0}" --argjson r "$RUNS" \
        '. + [($r[] | select(.id == $id) | {w, m, b: $b})]' <<<"$SAMP" 2>/dev/null) || continue
    SN=$(( SN + 1 ))
  done
  # PER WORKFLOW. A repo's workflows bill very differently (a MonkCI test
  # matrix beside a GitHub-hosted lint), so each workflow's wall minutes take
  # that workflow's own sampled billed/wall ratio; a workflow the sample missed
  # takes the pooled ratio. Then, when the pages held fewer runs than GitHub's
  # total_count, the result is EXTRAPOLATED by total_count / runs read — a busy
  # repo is estimated, never silently capped.
  read -r SB SW EST0 <<<"$(jq -r --argjson s "$SAMP" '
      ($s | map(.b) | add // 0) as $sb | ($s | map(.m) | add // 0) as $sw
      | (if $sw > 0 then $sb / $sw else 0 end) as $pool
      | ($s | group_by(.w) | map({key: (.[0].w | tostring),
            value: ((map(.m) | add) as $m | if $m > 0 then (map(.b) | add) / $m else $pool end)}) | from_entries) as $rw
      | (group_by(.w) | map((map(.m) | add) * ($rw[(.[0].w | tostring)] // $pool)) | add // 0) as $est
      | "\($sb) \($sw) \($est)"' <<<"$RUNS" 2>/dev/null)"
  SB="${SB:-0}"; SW="${SW:-0}"; EST0="${EST0:-0}"
  FLOOR=""; SEEN="$NRUNS run(s)"; XF=1
  if [ "$TOTALC" -gt "$NRUNS" ] 2>/dev/null && [ "$NRUNS" -gt 0 ]; then
    XF=$(awk -v t="$TOTALC" -v n="$NRUNS" 'BEGIN{ printf "%.4f", t / n }')
    SEEN="$NRUNS of $TOTALC run(s)"
    FLOOR=" extrapolated x$(awk -v x="$XF" 'BEGIN{ printf "%.2f", x }') from total_count"
  elif [ "$FULL" = 1 ]; then
    FLOOR=" floor (every page full, no total_count)"
  fi
  EST=$(awk -v e="$EST0" -v x="$XF" 'BEGIN{ printf "%d", e * x + 0.5 }')
  # BH-8049: dispatches per day and pushes per PR, from the runs read above.
  CNT=$(jq -c '
      ([.[] | select(.ev == "workflow_dispatch")] | group_by(.wn)
        | map({key: (.[0].wn | if . == "" then "?" else . end), value: length})
        | sort_by(-.value, .key) | .[:5] | from_entries) as $dw
      | ([.[] | select(.ev == "workflow_dispatch")] | length) as $d
      | ([.[] | select(.ev == "pull_request" and .b != "")] | group_by(.b)
        | map({b: .[0].b, n: (map(.h) | unique | length)}) | sort_by(-.n, .b)) as $pp
      | ($pp | map(.n) | sort) as $ns | ($ns | length) as $k
      | {dispatches_24h: $d, dispatches_by_workflow: $dw,
         pushes_per_pr: {prs: $k,
           median: (if $k == 0 then 0 elif $k % 2 == 1 then $ns[($k - 1) / 2]
                    else ($ns[$k / 2 - 1] + $ns[$k / 2]) / 2 end),
           max: ($pp[0].n // 0), max_branch: ($pp[0].b // ""), total: ($ns | add // 0)}}' <<<"$RUNS" 2>/dev/null) \
    || CNT='{"dispatches_24h":0,"dispatches_by_workflow":{},"pushes_per_pr":{"prs":0,"median":0,"max":0,"max_branch":"","total":0}}'
  COUNTS=$(jq -c --arg r "$SLUG" --argjson c "$CNT" '. + {($r): $c}' <<<"$COUNTS" 2>/dev/null) || COUNTS="{}"
  log "ci-counts repo=$SLUG $(jq -r --argjson n "$NRUNS" '"dispatches_24h=\(.dispatches_24h)"
      + (if .dispatches_24h > 0 then " (" + (.dispatches_by_workflow | to_entries | map("\(.key)=\(.value)") | join(",")) + ")" else "" end)
      + " pushes_per_pr prs=\(.pushes_per_pr.prs)"
      + (if .pushes_per_pr.prs > 0 then " median=\(.pushes_per_pr.median) max=\(.pushes_per_pr.max) (\(.pushes_per_pr.max_branch))" else "" end)
      + " of \($n) run(s) read"' <<<"$CNT" 2>/dev/null)"
  log "$SLUG: $SEEN in 24h, $(printf '%.0f' "$WALL") wall min; sample $SN run(s) billed $(printf '%.0f' "$SB") job-min over $(printf '%.0f' "$SW") wall min -> est $EST billed job-min/24h$FLOOR"
  TOTAL=$(( TOTAL + EST ))
  ROWS="$ROWS$SLUG $EST$FLOOR"$'\n'
done
command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset

TOP=$(printf '%s' "$ROWS" | awk 'NF' | sort -k2 -nr | head -3 | awk '{n=$1" "$2" min"; if (NF > 2) n=n" ("$3")"; printf "%s, ", n}' | sed 's/, $//')
log "fleet: est $TOTAL billed job-min/24h (runner match '$MATCH', job-minute x$MULT, line $DAY_MAX; $CALLS GitHub read(s))${UNREAD:+; could not read: $UNREAD}"
jq -n --arg at "$(STAMP)" --argjson total "$TOTAL" --argjson max "$DAY_MAX" --argjson calls "$CALLS" \
   --arg match "$MATCH" --arg rows "$ROWS" --arg unread "$UNREAD" --argjson counts "$COUNTS" \
   '{at: $at, est_billed_job_minutes_24h: $total, day_max: $max, gh_reads: $calls, runner_match: $match,
     repos: ($rows | split("\n") | map(select(length > 0) | split(" ") | {repo: .[0], est: (.[1] | tonumber), note: (.[2:] | join(" "))}
                                       | . + ($counts[.repo] // {}))),
     unread: ($unread | split(" ") | map(select(length > 0)))}' > "$STATE/latest.json" 2>/dev/null

[ -n "$DRY" ] && exit 0
if [ "$DAY_MAX" -gt 0 ] && [ "$TOTAL" -gt "$DAY_MAX" ]; then
  if command -v page_critical >/dev/null 2>&1; then
    PAGE_LANE=ci-minutes-watch page_critical 86400 "ci-minutes:fleet" \
      "CI is billing an estimated $TOTAL job-minutes in the last 24h against a line of $DAY_MAX (runner labels matching '$MATCH'). Top: ${TOP:-none}. Estimate = each repo's run wall-minutes x the per-workflow billed/wall ratio of a $SAMPLE-run jobs sample, extrapolated by total_count; state/ci-minutes/latest.json, logs/ci-minutes-watch.log. Levers: docs/CI-RUNNERS.md (flip CI_RUNNER), the merge queue's batch size."
  else
    echo "$(STAMP) [ci-minutes-watch] CI est $TOTAL job-min/24h over the line $DAY_MAX — page-critical lib missing, this line is the only copy" >> "$H/logs/ALERTS.log"
  fi
fi

# THE SNAPSHOT PUSH (BH-2633): each repo's line of latest.json becomes the
# newest (repo, "minutes") row of the worker's ci_health table. AFTER the page on
# purpose, so a slow worker can never delay it, and it touches nothing the page
# read. An unread repo is pushed as {unread:true}, never as 0 minutes. A failed
# push is one log line per tick naming the repos; the lane still exits 0.
if command -v ci_health_put >/dev/null 2>&1; then
  if PUSH=$(jq -r '{day_max, runner_match, at} as $c
                   | (.repos[]? | [.repo, ({est_24h: .est, note} + $c
                                            + (if .dispatches_24h != null then {dispatches_24h, pushes_per_pr} else {} end) | tojson)]),
                     (.unread[]? | [., ({unread: true} + $c | tojson)])
                   | join("\t")' "$STATE/latest.json" 2>/dev/null); then
    PN=0; PFAIL=""
    while IFS=$'\t' read -r PREPO PBODY; do
      [ -n "$PREPO" ] || continue
      PN=$(( PN + 1 ))
      ci_health_put "$PREPO" minutes "$PBODY" || PFAIL="${PFAIL:+$PFAIL }$PREPO"
    done <<<"$PUSH"
    [ -n "$PFAIL" ] && log "ci-health push: push failed for $(wc -w <<<"$PFAIL" | tr -d ' ') of $PN repo(s): $PFAIL"
  else
    log "ci-health push: $STATE/latest.json did not read — no snapshot sent"
  fi
fi
exit 0
