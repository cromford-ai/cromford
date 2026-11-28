#!/bin/bash
# bin/onboard-canary.sh — BH-9442: the onboarding canary. A new repo builds no
# ticket until a no-op PR goes green in the repo's OWN CI. No LLM call.
#
# THE INCIDENT. project-12, project-13 and project-14 were onboarded about 2026-11-05
# and merged 0 of 16 PRs in two weeks: "E2E Tests" / "Playwright E2E" were red
# on every PR, the tickets' own and every rebuild. Onboarding checked only the
# harness wiring, never one PR check of the repo.
#
# Verbs:
#   --hold <p>             onboarding (bin/onboard-run.sh `ready`,
#                          bin/load-project.sh): write onboard.<p>.canary_gate=held,
#                          then --start. Already `released`: no new hold.
#   --start <p>...         open one canary PR (branch harness/onboard-canary-<ymdHM>
#                          off the default branch, one commit writing
#                          .harness/onboard-canary.md). An open canary PR on the repo
#                          is reused, never a second one.
#   --tick                 cron, every 5 min: read the checks of every pending
#                          canary's head sha and decide (rule below). A final verdict
#                          writes its rows, then closes the PR and deletes its branch.
#                          It never merges.
#   --weekly               cron, Monday: --start every fleet project, minus a
#                          pending one and one with onboard.<p>.canary_skip=<reason>.
#   --status [p...]        one line per project: <p> <gate> <state> <sha12> <pr-url> <at>
#   --override <p> <reason>  write onboard.<p>.canary_override=<reason>, release the gate.
#
# Records (settings rows, read from every box; the build gate is
# bin/lib/rb/gates.d/onboard-canary.sh):
#   onboard.<p>.canary          {"state","pr","sha","opened","at","mode"} (<= 256 chars)
#                               state: pending | green | red | no-checks
#   onboard.<p>.canary_gate     held | released (no row: never held, builds as before)
#   onboard.<p>.canary_override the operator's reason; releases a held project
#   onboard.<p>.canary_skip     the --weekly run skips the project
#   onboard.<p>.canary_held_at  epoch seconds the hold started (--hold, or the
#                               first --tick that sees a held gate with none)
# Hub working list: state/onboard-canary/<p>.json, one file per project,
# overwritten in place. A pending row with no file (a --hold run off the hub,
# from a laptop) is adopted by the next --tick.
#
# Mode: `hold` when the gate row reads held at start, else `weekly`. A red or
# no-checks verdict never writes the gate row: a held project stays held, an
# unheld one is alerted, not paused. Green releases a held gate.
#
# NEVER HELD SILENTLY, NEVER RELEASED ON A READ FAILURE (lead review of #9490).
# Every --tick reads the gate row of each fleet project. A project held for
# ONBOARD_CANARY_HELD_ALERT_HOURS or more, with no override row, gets the alert
# onboard-canary:<p>:held; it stays open (lane-alert reminds, never re-sends)
# until a release resolves it. The bound alerts, it never releases: only a
# green canary or --override writes `released`. A gate read that fails is never
# taken as "not held": a green verdict keeps release_owed until a readable tick
# writes `released`.
#
# DECISION RULE (one head sha). Items: every check run (all pages, up to
# ONBOARD_CANARY_CHECK_PAGES of 100) and every commit status context.
#   red        any completed item whose conclusion is not success|neutral|skipped
#              (a status error|failure), final at once, even with others running
#   green      >= 1 item, all completed, all pass
#   no-checks  0 items, and 0 workflows after ONBOARD_CANARY_NOCHECK_GRACE_MIN,
#              or 0 items at ONBOARD_CANARY_TIMEOUT_MIN
#   pending    otherwise; at ONBOARD_CANARY_TIMEOUT_MIN it is red, reason
#              "timeout after <n> min, still running: <names>"
#   A new head sha on the PR (someone pushed) is recorded and stays pending.
#   First error line: the first failing item's output.title, else the first
#   non-empty line of output.summary, else its first failure annotation, else
#   "conclusion=<c> <url>"; cut to 200 characters.
#
# Alerts: one lane-alert per verdict, id onboard-canary:<p>:<sha12>; a failed
# start: onboard-canary:<p>:start. Exit codes: 0 done; 1 a start failed;
# 2 not configured (no jobs client or gh lib) or a settings write failed (the
# state is unchanged, retried next tick); 64 a bad argument; 75 GitHub did not
# answer (403/429/5xx/network: state unchanged, retried next tick).
#
# Env, test seams: ONBOARD_CANARY_JOBS_CLIENT (default bin/jobs-client.sh),
#   ONBOARD_CANARY_NOW (epoch seconds, the clock).
# Knobs (catalog/lanes.d/onboard-canary.json, settings rows
#   lane.onboard-canary.<env lowercased>): ONBOARD_CANARY_TIMEOUT_MIN (60),
#   ONBOARD_CANARY_NOCHECK_GRACE_MIN (10), ONBOARD_CANARY_CHECK_PAGES (5),
#   ONBOARD_CANARY_HELD_ALERT_HOURS (24).
# OFF: bin/harness-ctl.sh off onboard-canary. Doc: docs/onboarding-a-repo.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$H/logs/onboard-canary.log"
SDIR="$H/state/onboard-canary"
JC="${ONBOARD_CANARY_JOBS_CLIENT:-$H/bin/jobs-client.sh}"
# A checkout off the hub (bin/load-project.sh from a laptop) has no $H: use its own client.
[ -x "$JC" ] || [ -n "${ONBOARD_CANARY_JOBS_CLIENT:-}" ] || JC="$SELF/jobs-client.sh"
BR_PREFIX="harness/onboard-canary-"
MARKER=".harness/onboard-canary.md"
PR_TITLE="[harness] onboarding canary, do not merge"
PASS_RE='^(success|neutral|skipped)$'

mkdir -p "$H/logs" "$SDIR" 2>/dev/null
now_s() { if [[ "${ONBOARD_CANARY_NOW:-}" =~ ^[0-9]+$ ]]; then printf '%s\n' "$ONBOARD_CANARY_NOW"; else date -u +%s; fi; }
NOW=$(now_s)
iso() { date -u -d "@$1" +%FT%TZ 2>/dev/null || printf '%s' "$1"; }
log() { printf '%s %s\n' "$(iso "$NOW")" "$*" >> "$LOG"; }
alert() { # alert <id> <text>
  "$SELF/lane-alert.sh" --id "$1" --severity warn onboard-canary "$2" >/dev/null 2>&1 || true
}
held_resolved() { # held_resolved <p> <why> — close the held alert after a release (silent when none is open)
  "$SELF/lane-alert.sh" --resolve --id "onboard-canary:$1:held" onboard-canary "onboard-canary $1: released ($2)" >/dev/null 2>&1 || true
}

# shellcheck disable=SC1091
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
# The lane knobs' settings rows reach the env here, after global.env.
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply onboard-canary
# shellcheck source=bin/lib/gh-rest.sh
command -v gh_rest >/dev/null 2>&1 || . "$SELF/lib/gh-rest.sh" 2>/dev/null || true
# shellcheck disable=SC1091
command -v gh_auth_for >/dev/null 2>&1 || . "$SELF/lib/gh-app-auth.sh" 2>/dev/null || true

# knob <ENV> <fallback> — a positive integer, from the lane registry and its
# settings row when lane-gate is loaded, else the env, else the fallback.
knob() {
  local v=""
  command -v lane_knob >/dev/null 2>&1 && v=$(lane_knob onboard-canary "$1" 2>/dev/null)
  [[ "$v" =~ ^[1-9][0-9]*$ ]] || v="${!1:-}"
  [[ "$v" =~ ^[1-9][0-9]*$ ]] || v="$2"
  printf '%s' "$v"
}
TIMEOUT_MIN=$(knob ONBOARD_CANARY_TIMEOUT_MIN 60)         # fallback of the lane knob ONBOARD_CANARY_TIMEOUT_MIN
GRACE_MIN=$(knob ONBOARD_CANARY_NOCHECK_GRACE_MIN 10)     # fallback of the lane knob ONBOARD_CANARY_NOCHECK_GRACE_MIN
CHECK_PAGES=$(knob ONBOARD_CANARY_CHECK_PAGES 5)          # fallback of the lane knob ONBOARD_CANARY_CHECK_PAGES
HELD_HOURS=$(knob ONBOARD_CANARY_HELD_ALERT_HOURS 24)     # fallback of the lane knob ONBOARD_CANARY_HELD_ALERT_HOURS

# ── settings ────────────────────────────────────────────────────────────────
# srd <key> — the trimmed value on stdout; rc 0 found, 2 no row, else unreadable.
srd() {
  local v rc=0
  [ -x "$JC" ] || return 1
  v=$("$JC" setting-get "$1" 2>/dev/null) || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  v=$(printf '%s' "$v" | tr '\n' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -n "$v" ] || return 2
  printf '%s' "$v"
}
swr() { [ -x "$JC" ] && "$JC" setting-set "$1" "$2" "bin/onboard-canary.sh (BH-9442)" >/dev/null 2>&1; }

slug_of() { # slug_of <p> -> owner/repo, rc 1 when fleet-conf has none
  local s
  s=$("$SELF/fleet-conf.sh" "$1" repo 2>/dev/null) || return 1
  [[ "$s" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  printf '%s' "$s"
}

# ghj <out-file> <method> <path> [args] — one REST call; rc as gh_rest (0, 44, 75).
ghj() {
  local f="$1" rc=0; shift
  command -v gh_rest >/dev/null 2>&1 || return 75
  gh_rest "$@" > "$f" || rc=$?
  return "$rc"
}

sfile() { printf '%s/%s.json' "$SDIR" "$1"; }
# row_of <state-json> — the compact settings row.
row_of() { jq -c --argjson at "$NOW" '{state, pr, sha, opened, at: $at, mode}' <<<"$1"; }
save() { # save <p> <json> — the hub file, atomically
  local f tmp; f=$(sfile "$1"); tmp="$f.tmp.$$"
  printf '%s\n' "$2" > "$tmp" && mv "$tmp" "$f"
}

# ── start ───────────────────────────────────────────────────────────────────
start_fail() { # start_fail <p> <what>
  log "start-failed $1 $2"
  alert "onboard-canary:$1:start" "onboard-canary $1: the canary PR could not be opened: $2. Tickets of a held project stay held. Retry: bin/onboard-canary.sh --start $1"
  echo "canary: OWED: $1 canary PR not opened: $2"
  return 1
}

oc_start() { # oc_start <p>
  local p="$1" slug gate mode f tmp rc=0 pr url sha branch base bsha opened fsha body st
  slug=$(slug_of "$p") || { start_fail "$p" "no repo for $p in fleet.conf"; return 1; }
  command -v gh_auth_for >/dev/null 2>&1 && { gh_auth_for "$slug" || true; }
  f=$(sfile "$p")
  if [ -f "$f" ] && [ "$(jq -r '.state' "$f" 2>/dev/null)" = pending ]; then
    echo "canary: $p pending, PR $(jq -r '.url' "$f"), reused"
    return 0
  fi
  gate=$(srd "onboard.$p.canary_gate") || gate=""
  mode=weekly; [ "$gate" = held ] && mode=hold
  tmp=$(mktemp "${TMPDIR:-/tmp}/oc.XXXXXX")
  ghj "$tmp" GET "repos/$slug/pulls?state=open&per_page=100" || rc=$?
  if [ "$rc" != 0 ]; then rm -f "$tmp"; start_fail "$p" "open PR list answered rc $rc (HTTP ${GH_REST_STATUS:-000})"; return 1; fi
  if jq -e --arg b "$BR_PREFIX" '[.[] | select(.head.ref | startswith($b))] | length > 0' "$tmp" >/dev/null 2>&1; then
    body=$(jq -c --arg b "$BR_PREFIX" '[.[] | select(.head.ref | startswith($b))][0]' "$tmp")
    pr=$(jq -r '.number' <<<"$body"); url=$(jq -r '.html_url' <<<"$body"); sha=$(jq -r '.head.sha' <<<"$body")
    branch=$(jq -r '.head.ref' <<<"$body")
    opened=$(date -u -d "$(jq -r '.created_at // empty' <<<"$body")" +%s 2>/dev/null) || opened=$NOW
    log "start $p reuse PR #$pr"
  else
    rc=0; ghj "$tmp" GET "repos/$slug" || rc=$?
    base=$(jq -r '.default_branch // empty' "$tmp" 2>/dev/null)
    [ "$rc" = 0 ] && [ -n "$base" ] || { rm -f "$tmp"; start_fail "$p" "repo read answered rc $rc (HTTP ${GH_REST_STATUS:-000})"; return 1; }
    rc=0; ghj "$tmp" GET "repos/$slug/git/ref/heads/$base" || rc=$?
    bsha=$(jq -r '.object.sha // empty' "$tmp" 2>/dev/null)
    [ "$rc" = 0 ] && [ -n "$bsha" ] || { rm -f "$tmp"; start_fail "$p" "base branch $base read answered rc $rc"; return 1; }
    branch="$BR_PREFIX$(date -u -d "@$NOW" +%Y%m%d%H%M)"
    rc=0; ghj "$tmp" POST "repos/$slug/git/refs" -f "ref=refs/heads/$branch" -f "sha=$bsha" || rc=$?
    [ "$rc" = 0 ] || { rm -f "$tmp"; start_fail "$p" "branch create refused (HTTP ${GH_REST_STATUS:-000})"; return 1; }
    fsha=""; rc=0; ghj "$tmp" GET "repos/$slug/contents/$MARKER?ref=$branch" || rc=$?
    [ "$rc" = 0 ] && fsha=$(jq -r '.sha // empty' "$tmp" 2>/dev/null)
    rc=0; ghj "$tmp" PUT "repos/$slug/contents/$MARKER" -f "message=harness: onboarding canary (BH-9442)" \
      -f "content=$(printf 'Harness onboarding canary %s. A no-op change: bin/onboard-canary.sh closes this PR unmerged.\n' "$(iso "$NOW")" | base64 -w0)" \
      -f "branch=$branch" ${fsha:+-f "sha=$fsha"} || rc=$?
    if [ "$rc" != 0 ]; then
      st=${GH_REST_STATUS:-000}; ghj /dev/null DELETE "repos/$slug/git/refs/heads/$branch" || true
      rm -f "$tmp"; start_fail "$p" "marker commit refused (HTTP $st)"; return 1
    fi
    # >>> pr trailers (BH-3987)
    # The lane opened this canary PR, and no ticket owns its branch.
    printf '%s\n' "Onboarding canary (BH-9442). A no-op change to $MARKER, so the repo's own CI runs once. The harness reads the checks, records the verdict in the settings row onboard.$p.canary, then closes this PR unmerged. Do not merge." > "$tmp.body"
    command -v pr_trailers_apply >/dev/null 2>&1 || . "$SELF/lib/pr-trailers.sh" 2>/dev/null || true
    command -v pr_trailers_apply >/dev/null 2>&1 && { pr_trailers_apply "$tmp.body" lane:onboard-canary none \
      || log "pr-trailers: could not write the body of $p, PR opened without trailers"; }
    rc=0; ghj "$tmp" POST "repos/$slug/pulls" -f "title=$PR_TITLE" -f "head=$branch" -f "base=$base" -F "body=@$tmp.body" || rc=$?
    # <<< pr trailers
    rm -f "$tmp.body"
    if [ "$rc" != 0 ]; then
      st=${GH_REST_STATUS:-000}; ghj /dev/null DELETE "repos/$slug/git/refs/heads/$branch" || true
      rm -f "$tmp"; start_fail "$p" "PR create refused (HTTP $st)"; return 1
    fi
    pr=$(jq -r '.number' "$tmp"); url=$(jq -r '.html_url' "$tmp"); sha=$(jq -r '.head.sha' "$tmp")
    opened=$NOW
    log "start $p opened PR #$pr $branch"
  fi
  rm -f "$tmp"
  body=$(jq -nc --arg p "$p" --arg s "$slug" --argjson pr "$pr" --arg u "$url" --arg sha "$sha" --arg b "$branch" \
    --argjson o "$opened" --arg m "$mode" \
    '{project:$p, slug:$s, state:"pending", pr:$pr, url:$u, sha:$sha, branch:$b, opened:$o, mode:$m, closed:false}')
  save "$p" "$body"
  swr "onboard.$p.canary" "$(row_of "$body")" || log "row-write-failed $p pending (the hub file is the working list; the next tick writes the verdict)"
  echo "canary: $p $mode pending, PR $url, head ${sha:0:12}"
  return 0
}

oc_hold() { # oc_hold <p>
  local p="$1" gate
  if command -v lane_paused >/dev/null 2>&1 && lane_paused onboard-canary >/dev/null 2>&1; then
    echo "canary: the onboard-canary lane is off; $p is not held"
    return 0
  fi
  gate=$(srd "onboard.$p.canary_gate") || gate=""
  if [ "$gate" = released ]; then
    echo "canary: $p already released ($(oc_status_line "$p"))"
    return 0
  fi
  swr "onboard.$p.canary_gate" held || { echo "canary: OWED: could not write onboard.$p.canary_gate=held (jobs client)"; return 1; }
  # The hold clock; a failed write is restarted by the next --tick (held_watch).
  swr "onboard.$p.canary_held_at" "$NOW" || log "held-at-write-failed $p (the next tick starts the clock)"
  log "hold $p"
  local out rc=0
  out=$(oc_start "$p") || rc=$?
  printf '%s\n' "$out"
  [ "$rc" = 0 ] || return "$rc"
  echo "canary: held, PR $(jq -r '.url' "$(sfile "$p")" 2>/dev/null), tickets wait for green"
}

# ── decision ────────────────────────────────────────────────────────────────
# items <runs-json> <status-json> — one array of {name,status,conclusion,id,title,summary,url}.
items_of() {
  jq -c -n --slurpfile r "$1" --slurpfile s "$2" '
    ([$r[0][]?] | map({name, status, conclusion, id, title: (.output.title // ""), summary: (.output.summary // ""), url: (.details_url // .html_url // "")}))
    + ([$s[0].statuses[]?] | map({name: .context,
         status: (if .state == "pending" then "in_progress" else "completed" end),
         conclusion: (if .state == "success" then "success" elif .state == "pending" then null else "failure" end),
         id: null, title: (.description // ""), summary: "", url: (.target_url // "")}))'
}

first_line() { tr -d '\r' | sed -n '/[^[:space:]]/{s/^[[:space:]]*//;p;q;}' | cut -c1-200; }

# first_error <slug> <items> — one line for the alert.
first_error() {
  local slug="$1" it t id tmp
  it=$(jq -c --arg re "$PASS_RE" '[.[] | select(.status == "completed" and ((.conclusion // "") | test($re) | not))][0]' <<<"$2")
  t=$(jq -r '.title' <<<"$it" | first_line)
  [ -n "$t" ] || t=$(jq -r '.summary' <<<"$it" | first_line)
  if [ -z "$t" ]; then
    id=$(jq -r '.id // empty' <<<"$it")
    if [ -n "$id" ]; then
      tmp=$(mktemp "${TMPDIR:-/tmp}/oc.XXXXXX")
      ghj "$tmp" GET "repos/$slug/check-runs/$id/annotations" \
        && t=$(jq -r '[.[] | select(.annotation_level == "failure")][0].message // empty' "$tmp" 2>/dev/null | first_line)
      rm -f "$tmp"
    fi
  fi
  [ -n "$t" ] || t=$(jq -r '"conclusion=\(.conclusion) \(.url)"' <<<"$it" | cut -c1-200)
  printf '%s' "$t"
}

# ── tick ────────────────────────────────────────────────────────────────────
# finish <p> — close the PR and delete its branch after a verdict; retry a
# release write that failed. rc 0 always (a failure is retried next tick).
finish() {
  local p="$1" f j slug pr branch rc=0 gate
  f=$(sfile "$p"); j=$(cat "$f")
  slug=$(jq -r '.slug' <<<"$j"); pr=$(jq -r '.pr' <<<"$j"); branch=$(jq -r '.branch // empty' <<<"$j")
  if [ "$(jq -r '.release_owed // false' <<<"$j")" = true ]; then
    # A read failure is not "not held": the release stays owed (lead review of #9490).
    rc=0; gate=$(srd "onboard.$p.canary_gate") || rc=$?
    if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then
      log "release-owed $p: gate row unreadable rc $rc (retried next tick)"
    elif [ "$gate" != held ] || swr "onboard.$p.canary_gate" released; then
      [ "$gate" = held ] && { log "released $p (retried)"; held_resolved "$p" "green canary"; }
      j=$(jq -c '.release_owed = false' <<<"$j"); save "$p" "$j"
    fi
    rc=0
  fi
  [ "$(jq -r '.closed' <<<"$j")" = true ] && return 0
  if [ "$(jq -r '.pr_state // "open"' <<<"$j")" != closed ]; then
    ghj /dev/null PATCH "repos/$slug/pulls/$pr" -f state=closed || rc=$?
    [ "$rc" = 0 ] || { log "close-failed $p PR #$pr rc $rc (retried next tick)"; return 0; }
  fi
  if [ -n "$branch" ]; then
    rc=0; ghj /dev/null DELETE "repos/$slug/git/refs/heads/$branch" || rc=$?
    case "$rc" in 0|44) ;; *) log "branch-delete-failed $p $branch rc $rc" ;; esac
  fi
  j=$(jq -c '.closed = true' <<<"$j"); save "$p" "$j"
  log "closed $p PR #$pr"
  return 0
}

# tick_one <p> — rc 0, 2 (settings write failed) or 75 (GitHub unverifiable).
tick_one() {
  local p="$1" f j slug pr sha tmp runs st rc=0 page total got its kind verdict reason elapsed names wf \
        fails err row gate msg
  f=$(sfile "$p"); j=$(cat "$f" 2>/dev/null) || return 0
  if [ "$(jq -r '.state' <<<"$j")" != pending ]; then finish "$p"; return 0; fi
  slug=$(jq -r '.slug' <<<"$j"); pr=$(jq -r '.pr' <<<"$j"); sha=$(jq -r '.sha' <<<"$j")
  command -v gh_auth_for >/dev/null 2>&1 && { gh_auth_for "$slug" || true; }
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/oc.XXXXXX")
  ghj "$tmp/pr" GET "repos/$slug/pulls/$pr" || rc=$?
  if [ "$rc" != 0 ]; then log "unverifiable $p PR #$pr rc $rc (HTTP ${GH_REST_STATUS:-000})"; rm -rf "$tmp"; return 75; fi
  j=$(jq -c --arg b "$(jq -r '.head.ref // empty' "$tmp/pr")" '.branch = (if $b == "" then .branch else $b end)' <<<"$j")
  if [ "$(jq -r '.state' "$tmp/pr")" = closed ]; then
    verdict=red; reason="the canary PR #$pr was closed before a verdict"; its='[]'
    j=$(jq -c '.pr_state = "closed"' <<<"$j")
  else
    local head; head=$(jq -r '.head.sha // empty' "$tmp/pr")
    if [ -n "$head" ] && [ "$head" != "$sha" ]; then
      j=$(jq -c --arg s "$head" '.sha = $s' <<<"$j"); save "$p" "$j"
      swr "onboard.$p.canary" "$(row_of "$j")" || true
      log "new-head $p PR #$pr ${sha:0:12} -> ${head:0:12}, pending"
      rm -rf "$tmp"; return 0
    fi
    echo '[]' > "$tmp/runs"; page=1; got=0; total=0
    while [ "$page" -le "$CHECK_PAGES" ]; do
      rc=0; ghj "$tmp/pg" GET "repos/$slug/commits/$sha/check-runs?per_page=100&page=$page" || rc=$?
      if [ "$rc" != 0 ]; then log "unverifiable $p check-runs rc $rc (HTTP ${GH_REST_STATUS:-000})"; rm -rf "$tmp"; return 75; fi
      total=$(jq -r '.total_count // 0' "$tmp/pg"); runs=$(jq -c '.check_runs // []' "$tmp/pg")
      [ "$(jq 'length' <<<"$runs")" -gt 0 ] || break
      jq -c --argjson a "$runs" '. + $a' "$tmp/runs" > "$tmp/r2" && mv "$tmp/r2" "$tmp/runs"
      got=$(jq 'length' "$tmp/runs")
      [ "$got" -lt "$total" ] || break
      page=$((page + 1))
    done
    rc=0; ghj "$tmp/st" GET "repos/$slug/commits/$sha/status" || rc=$?
    if [ "$rc" != 0 ]; then log "unverifiable $p status rc $rc (HTTP ${GH_REST_STATUS:-000})"; rm -rf "$tmp"; return 75; fi
    its=$(items_of "$tmp/runs" "$tmp/st")
    kind=$(jq -r --arg re "$PASS_RE" '
      if length == 0 then "none"
      elif any(.[]; .status == "completed" and ((.conclusion // "") | test($re) | not)) then "red"
      elif all(.[]; .status == "completed") then "green"
      else "pending" end' <<<"$its")
    elapsed=$(( (NOW - $(jq -r '.opened' <<<"$j")) / 60 ))
    verdict=pending; reason=""
    case "$kind" in
      red) verdict=red ;;
      green) verdict=green ;;
      none)
        if [ "$elapsed" -ge "$TIMEOUT_MIN" ]; then verdict=no-checks; reason="no check or status after $elapsed min"
        elif [ "$elapsed" -ge "$GRACE_MIN" ]; then
          rc=0; ghj "$tmp/wf" GET "repos/$slug/actions/workflows?per_page=1" || rc=$?
          if [ "$rc" = 75 ]; then log "unverifiable $p workflows rc 75"; rm -rf "$tmp"; return 75; fi
          wf=$(jq -r '.total_count // 0' "$tmp/wf" 2>/dev/null); [ "$rc" = 44 ] && wf=0
          [ "${wf:-0}" = 0 ] && { verdict=no-checks; reason="the repo has no workflows and no status after $elapsed min"; }
        fi ;;
      pending)
        if [ "$elapsed" -ge "$TIMEOUT_MIN" ]; then
          names=$(jq -r '[.[] | select(.status != "completed") | .name] | join(", ")' <<<"$its")
          verdict=red; reason="timeout after $TIMEOUT_MIN min, still running: $names"
        fi ;;
    esac
  fi
  if [ "$verdict" = pending ]; then rm -rf "$tmp"; log "pending $p PR #$pr ${sha:0:12} ($(jq 'length' <<<"$its") checks, $elapsed min)"; return 0; fi
  fails=$(jq -r --arg re "$PASS_RE" '[.[] | select(.status == "completed" and ((.conclusion // "") | test($re) | not)) | .name] | join(", ")' <<<"$its")
  err=""
  [ -n "$fails" ] && err=$(first_error "$slug" "$its")
  rm -rf "$tmp"
  j=$(jq -c --arg v "$verdict" --arg r "$reason" --arg fl "$fails" --arg e "$err" --argjson at "$NOW" \
    '.state = $v | .reason = $r | .failing = $fl | .first_error = $e | .verdict_at = $at' <<<"$j")
  # The row first: a verdict that is not published is not recorded.
  row=$(row_of "$j")
  if ! swr "onboard.$p.canary" "$row"; then log "row-write-failed $p $verdict (state unchanged, retried next tick)"; return 2; fi
  local grc=0
  gate=$(srd "onboard.$p.canary_gate") || { grc=$?; gate=""; }
  if [ "$verdict" = green ]; then
    if [ "$grc" != 0 ] && [ "$grc" != 2 ]; then
      # Unreadable: maybe held. Owe the release; finish retries it on a readable tick.
      j=$(jq -c '.release_owed = true' <<<"$j"); log "release-owed $p: gate row unreadable rc $grc (retried next tick)"
    elif [ "$gate" = held ]; then
      if swr "onboard.$p.canary_gate" released; then log "released $p"; held_resolved "$p" "green canary"; else j=$(jq -c '.release_owed = true' <<<"$j"); log "release-write-failed $p (held, retried next tick)"; fi
    fi
  else
    if [ "$(jq -r '.mode' <<<"$j")" = hold ] || [ "$gate" = held ]; then
      msg="The project stays held: no ticket builds. Fix the repo's CI, then run bin/onboard-canary.sh --start $p, or release it with bin/onboard-canary.sh --override $p <reason>."
    else
      msg="Weekly canary: alerted, not paused."
    fi
    if [ "$verdict" = no-checks ]; then
      alert "onboard-canary:$p:${sha:0:12}" "onboard-canary $p: no checks on the canary PR $(jq -r '.url' <<<"$j") (${sha:0:12}): $reason. $msg"
    else
      alert "onboard-canary:$p:${sha:0:12}" "onboard-canary $p: the canary PR $(jq -r '.url' <<<"$j") is RED on ${sha:0:12}. Failing checks: ${fails:-none}.${reason:+ $reason.} First error: ${err:--}. $msg"
    fi
  fi
  save "$p" "$j"
  log "verdict $p $verdict PR #$pr ${sha:0:12}${fails:+ failing: $fails}${reason:+ ($reason)}"
  finish "$p"
  return 0
}

# held_watch <p> — a held project is never held silently. Past HELD_HOURS with
# no override row: the alert onboard-canary:<p>:held (lane-alert keeps it open
# and reminds; it is never re-sent). It never releases. A held gate with no
# held_at row starts the clock now. Any read failure: one log line, no write.
held_watch() {
  local p="$1" gate rc=0 at h
  gate=$(srd "onboard.$p.canary_gate") || rc=$?
  if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then log "unverifiable $p gate row rc $rc (held-watch skipped)"; return 0; fi
  [ "$gate" = held ] || return 0
  rc=0; srd "onboard.$p.canary_override" >/dev/null || rc=$?
  [ "$rc" = 0 ] && return 0
  rc=0; at=$(srd "onboard.$p.canary_held_at") || rc=$?
  if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then log "unverifiable $p held_at row rc $rc (held-watch skipped)"; return 0; fi
  if ! [[ "$at" =~ ^[0-9]+$ ]]; then
    swr "onboard.$p.canary_held_at" "$NOW" && log "held-clock $p started" || log "held-at-write-failed $p"
    return 0
  fi
  h=$(( (NOW - at) / 3600 ))
  [ "$h" -ge "$HELD_HOURS" ] || return 0
  alert "onboard-canary:$p:held" "onboard-canary $p: held for $h h (since $(iso "$at")), no ticket of $p builds. Canary: $(oc_status_line "$p"). Fix the repo's CI and run bin/onboard-canary.sh --start $p, or release it with bin/onboard-canary.sh --override $p <reason>."
  log "held-alert $p ${h}h"
}

# adopt — a pending row with no hub file (a --hold run off the hub), and the
# held_watch bound for every fleet project.
# project-loop-ok: adopt reads one to three settings rows per project and starts no project work; the canary work per tick is the pending files only (0-2 most ticks), and --weekly opens one PR per project once a week, about 7 REST calls each
adopt() {
  local p row slug
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    held_watch "$p"
    [ ! -f "$(sfile "$p")" ] || continue
    row=$(srd "onboard.$p.canary") || continue
    [ "$(jq -r '.state // empty' <<<"$row" 2>/dev/null)" = pending ] || continue
    slug=$(slug_of "$p") || continue
    save "$p" "$(jq -c --arg p "$p" --arg s "$slug" \
      '{project:$p, slug:$s, state, pr, url:("https://github.com/" + $s + "/pull/" + (.pr|tostring)), sha, branch:"", opened, mode, closed:false}' <<<"$row")"
    log "adopt $p PR #$(jq -r '.pr' <<<"$row")"
  done < <("$SELF/fleet-conf.sh" --projects 2>/dev/null)
}

oc_tick() {
  local f p rc out=0
  adopt
  for f in "$SDIR"/*.json; do
    [ -f "$f" ] || continue
    p=$(basename "$f" .json)
    rc=0; tick_one "$p" || rc=$?
    case "$rc" in 2) out=2 ;; 75) [ "$out" = 0 ] && out=75 ;; esac
  done
  return "$out"
}

oc_weekly() {
  local p n=0 skip
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if skip=$(srd "onboard.$p.canary_skip"); then log "weekly-skip $p ($skip)"; continue; fi
    if [ "$(jq -r '.state' "$(sfile "$p")" 2>/dev/null)" = pending ]; then log "weekly-skip $p (pending)"; continue; fi
    oc_start "$p" >/dev/null || true
    n=$((n + 1))
  done < <("$SELF/fleet-conf.sh" --projects 2>/dev/null)
  log "weekly started $n"
}

oc_status_line() { # <p> <gate> <state> <sha12> <pr-url> <at>
  local p="$1" gate j at url
  gate=$(srd "onboard.$p.canary_gate") || gate="-"
  if [ -f "$(sfile "$p")" ]; then j=$(cat "$(sfile "$p")"); else j=$(srd "onboard.$p.canary") || j='{}'; fi
  url=$(jq -r '.url // (if .pr then "#\(.pr)" else "-" end)' <<<"$j" 2>/dev/null)
  at=$(jq -r '.verdict_at // .at // .opened // empty' <<<"$j" 2>/dev/null)
  printf '%s %s %s %s %s %s\n' "$p" "$gate" "$(jq -r '.state // "-"' <<<"$j" 2>/dev/null)" \
    "$(jq -r '(.sha // "-") | .[0:12]' <<<"$j" 2>/dev/null)" "${url:--}" "$( [ -n "$at" ] && iso "$at" || echo -)"
}

oc_status() {
  local p f
  if [ $# -gt 0 ]; then for p in "$@"; do oc_status_line "$p"; done; return 0; fi
  for f in "$SDIR"/*.json; do [ -f "$f" ] && oc_status_line "$(basename "$f" .json)"; done
  return 0
}

oc_override() { # <p> <reason>
  local p="$1" r
  r=$(printf '%s' "${2:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -n "$r" ] || { echo "onboard-canary: --override needs a non-empty reason" >&2; return 64; }
  swr "onboard.$p.canary_override" "$r" || { echo "onboard-canary: could not write onboard.$p.canary_override" >&2; return 2; }
  swr "onboard.$p.canary_gate" released || { echo "onboard-canary: could not write onboard.$p.canary_gate=released" >&2; return 2; }
  log "override $p ($r)"
  held_resolved "$p" "override: $r"
  echo "canary: $p released by override: $r"
}

usage() { sed -n '/^# Verbs:/,/^# Records/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//' >&2; exit 64; }
PROJ_RE='^[a-z0-9][a-z0-9_-]{0,39}$'
need_p() { [[ "${1:-}" =~ $PROJ_RE ]] || { echo "onboard-canary: bad project name '${1:-}'" >&2; exit 64; }; }

ONBOARD_CANARY_LIB_ONLY="${ONBOARD_CANARY_LIB_ONLY:-}"
[ "$ONBOARD_CANARY_LIB_ONLY" = 1 ] && return 0 2>/dev/null

VERB="${1:-}"; [ $# -gt 0 ] && shift
case "$VERB" in
  --status) for a in "$@"; do need_p "$a"; done; oc_status "$@"; exit $? ;;
  --override) need_p "${1:-}"; oc_override "$1" "${2:-}"; exit $? ;;
  --hold|--start|--tick|--weekly) ;;
  *) usage ;;
esac
if [ ! -x "$JC" ]; then log "not-configured (no jobs client at $JC)"; echo "canary: OWED: not configured (no jobs client)"; exit 2; fi
if ! command -v gh_rest >/dev/null 2>&1; then log "not-configured (no bin/lib/gh-rest.sh)"; echo "canary: OWED: not configured (no gh-rest lib)"; exit 2; fi
case "$VERB" in
  --hold) need_p "${1:-}"; oc_hold "$1"; exit $? ;;
  --start)
    [ $# -gt 0 ] || usage
    rc=0; for a in "$@"; do need_p "$a"; oc_start "$a" || rc=1; done; exit "$rc" ;;
  --tick)
    command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit onboard-canary
    oc_tick; exit $? ;;
  --weekly)
    command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit onboard-canary
    oc_weekly; exit 0 ;;
esac
