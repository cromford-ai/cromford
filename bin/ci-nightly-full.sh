#!/bin/bash
# gh-identity: app-token
# bin/ci-nightly-full.sh dispatch|collect — one FULL harness-ci run on main a
# day, and its red filed as a map gap (BH-4970, slice 3 of BH-4964). Hub only.
#
# WHY. A merge-queue batch runs the suites its diff can reach (BH-4968), so a
# suite the map does not connect to a changed file stops running on that
# change. Nothing then notices until something else breaks. A daily full run of
# main is the net under the map: when it is red, a suite failed that no batch
# picked, and the ticket says which changed files the map missed for it.
#
# dispatch (cron 17 * * * *). OFF unless CI_NIGHTLY_FULL_DISPATCH=1 (BH-6838:
# the nightly workflow runs the corpus on main each day, and a red dispatch run
# can freeze merges; bin/lib/main-red-queue-dispatch.sh still self-dispatches
# when a freeze needs it). On, it acts at the first tick where the UTC hour is
# >= CI_NIGHTLY_FULL_HOUR (default 3), once per UTC date. In order, each skip a
# log line `dispatch: skip <reason>`:
#   dispatch-off (the knob is not 1: no claim dir, no gh call); before-hour; already-dispatched (<date>/run.json exists); automerge-disabled
#   (flags/automerge-disabled); gh-budget-low (bin/lib/gh-budget.sh);
#   merge-armed (an open PR labelled merge-queue: the full run never competes
#   with a batch for runners) or merge-armed-unknown (that read failed, so no
#   dispatch); claim-held (another tick holds today's mkdir claim).
# Then `gh workflow run harness-ci.yml --ref main` (a workflow_dispatch run is
# FULL in bin/ci-plan.sh) and state/ci-nightly-full/<date>/run.json
# {date, sha, dispatched_at, run_id}. gh never returns the run id, so up to 3
# reads of the workflow's dispatch runs look for it; a run_id still null is
# resolved by collect. A failed dispatch (rc 75 included) removes the claim and
# writes ONE ALERTS line per date; the next hourly tick retries. A claim dir
# with no run.json older than 10 minutes (a tick killed mid-dispatch) is
# reclaimed.
#
# collect (cron 41 * * * *). For each of the last CI_NIGHTLY_FULL_LOOKBACK_DAYS
# dates (default 3) with run.json and no done/lost marker:
#   success   -> state/ci-nightly-full/last_green_sha, done
#   cancelled / skipped / neutral -> done, no ticket (not a red)
#   any other completed conclusion -> red: the failed suites are the
#     `--- tests/<x> rc=<n != 0>` lines of the failed shard jobs' logs (at most
#     CI_NIGHTLY_FULL_MAX_LOGS of them); the changed files are
#     last_green_sha..sha (fallback sha~20..sha, said in the body); for each
#     suite, the missed files are the changed files whose
#     `bin/test-impact.sh select --changed <file> --map-only` at the red sha's
#     own tree does not contain it. One issue with the marker below, labelled
#     ai-build, or a comment on the open one (never a label). `ticketed` and
#     `done` are written only after gh returns the URL; a failed filing is one
#     ALERTS line per date and the next collect retries.
#   not completed -> pending. A run_id never found 6h after dispatch -> lost,
#     one ALERTS line.
#
# Knobs (settings rows via lane_env_apply, code default as fallback):
#   CI_NIGHTLY_FULL_HOUR [3]  CI_NIGHTLY_FULL_LOOKBACK_DAYS [3]
#   CI_NIGHTLY_FULL_MAX_LOGS [8]  CI_NIGHTLY_FULL_DISPATCH [0]
# Kill switch: bin/harness-ctl.sh off ci-nightly-full (flags/lane-off-ci-nightly-full)
# Tests: tests/ci-nightly-full.bh-4964-test.sh
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
# >>> lane gate (BH-1165)
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
# :17 dispatch and :41 collect are two modes: the mode is the one-run key
# (BH-7422).
LANE_RUN_KEY=${1:-none}
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit ci-nightly-full
if [ -f "$HENV/global.env" ]; then set -a; # shellcheck disable=SC1091
  . "$HENV/global.env"; set +a; fi
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply ci-nightly-full
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"; [ -n "$BIN" ] || BIN="$H/bin"
for _L in gh-budget.sh gh-app-auth.sh; do
  # shellcheck source=/dev/null
  if [ -r "$BIN/lib/$_L" ]; then . "$BIN/lib/$_L"; elif [ -r "$H/bin/lib/$_L" ]; then . "$H/bin/lib/$_L"; fi
done
# shellcheck source=bin/lib/deployment.sh
. "$BIN/lib/deployment.sh" || exit 1
# automerge-disabled is the pause flag, not a lane_switch switch: read it the
# way merge-sweep and split-watchdog do, through flag_active (the pause_flags
# row, then the file). With the worker unreachable it answers from the file.
# shellcheck source=bin/jobs-client.sh
. "$BIN/jobs-client.sh" 2>/dev/null || true
paused() { command -v flag_active >/dev/null 2>&1 && flag_active automerge-disabled; }
R="$HARNESS_REPO"
REPO_DIR="${REPOS_ROOT:-/root/repos}/${R#*/}"

SUB="${1:-}"
NOW="${NOW:-$(date +%s)}"
LOG="$H/logs/ci-nightly-full.log"
S="$H/state/ci-nightly-full"
mkdir -p "$(dirname "$LOG")" "$S" 2>/dev/null
MARK="<!-- harness-full-red -->"
TITLE="Daily full CI run is red on main"
log() { echo "$(date -u -d "@$NOW" '+%Y-%m-%d %H:%M:%SZ') $*" >> "$LOG"; }
knob() { # knob <ENV> <default> <min> <max> — an integer in range; anything else is logged and the default used
  local v="${!1:-}"
  [ -n "$v" ] || { printf '%s' "$2"; return 0; }
  case "$v" in *[!0-9]*) v=-1 ;; esac
  if [ "$v" -lt "$3" ] || [ "$v" -gt "$4" ]; then
    log "knob $1='${!1}' is not an integer in $3..$4; using the default $2"; v="$2"
  fi
  printf '%s' "$v"
}
HOUR_AT=$(knob CI_NIGHTLY_FULL_HOUR 3 0 23)
LOOKBACK=$(knob CI_NIGHTLY_FULL_LOOKBACK_DAYS 3 1 14)
MAX_LOGS=$(knob CI_NIGHTLY_FULL_MAX_LOGS 8 1 30)
DISPATCH_ON=$(knob CI_NIGHTLY_FULL_DISPATCH 0 0 1)
POLL_SLEEP="${CNF_POLL_SLEEP:-10}"; case "$POLL_SLEEP" in ''|*[!0-9]*) POLL_SLEEP=10 ;; esac
iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }
alert_once() { # alert_once <date> <kind> <message> — one ALERTS line per date per kind
  local m="$S/alerted-$1-$2"
  [ -e "$m" ] && return 0
  : > "$m"
  ALERT_LINE_STAMP="$(date -u -d "@$NOW" '+%Y-%m-%d %H:%M:%SZ')" HARNESS="$H" "$H/bin/alert-line.sh" "ci-nightly-full: $3" >/dev/null 2>&1 || true
}
budget_low() { command -v gh_budget_low >/dev/null 2>&1 && gh_budget_low ci-nightly-full; }
auth() { command -v gh_default_auth_for_slug >/dev/null 2>&1 && gh_default_auth_for_slug "$R" >/dev/null 2>&1; return 0; }

# resolve_run <sha> <dispatched_at-iso> — the oldest dispatch run of
# harness-ci.yml on main for that sha created no earlier than 60s before the
# dispatch. Prints the id, rc 1 when none is visible.
resolve_run() {
  local raw since id
  [ -n "$2" ] || return 1
  since=$(iso $(( $(date -u -d "$2" +%s 2>/dev/null || echo 0) - 60 )))
  raw=$(gh api "repos/$R/actions/workflows/harness-ci.yml/runs?event=workflow_dispatch&branch=main&per_page=20" 2>/dev/null) || return 1
  id=$(jq -r --arg s "$1" --arg t "$since" \
    '[.workflow_runs[]? | select(.head_sha == $s and .created_at >= $t)] | sort_by(.created_at) | .[0].id // empty' <<<"$raw" 2>/dev/null)
  case "$id" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$id"
}
set_run_id() { # set_run_id <run.json> <id> — atomically
  jq --argjson r "$2" '.run_id = $r' "$1" > "$1.tmp" && mv -f "$1.tmp" "$1"
}

do_dispatch() {
  local today hour dir n sha rc what id i
  today=$(date -u -d "@$NOW" +%F); hour=$(date -u -d "@$NOW" +%H); hour=$((10#$hour))
  dir="$S/$today"
  # BH-6838: off by default. The nightly workflow (harness-nightly.yml) runs
  # the corpus on main each day, and a red dispatch run of harness-ci.yml can
  # freeze merges. First gate: no claim dir, no gh call.
  [ "$DISPATCH_ON" = 1 ] || { log "dispatch: skip dispatch-off (CI_NIGHTLY_FULL_DISPATCH=$DISPATCH_ON)"; return 0; }
  [ "$hour" -lt "$HOUR_AT" ] && { log "dispatch: skip before-hour ($hour < $HOUR_AT)"; return 0; }
  [ -f "$dir/run.json" ] && { log "dispatch: skip already-dispatched $today"; return 0; }
  paused && { log "dispatch: skip automerge-disabled"; return 0; }
  auth
  budget_low && { log "dispatch: skip gh-budget-low"; return 0; }
  n=$(gh api "repos/$R/issues?state=open&labels=merge-queue&per_page=100" \
        --jq '[.[] | select(.pull_request != null)] | length' 2>/dev/null) || n=""
  case "$n" in
    ''|*[!0-9]*) log "dispatch: skip merge-armed-unknown (the merge-queue read failed)"; return 0 ;;
    0) ;;
    *) log "dispatch: skip merge-armed ($n open PR(s) labelled merge-queue)"; return 0 ;;
  esac
  # A dir with no run.json is a tick that died between the claim and the
  # dispatch. Fresh, it is another tick in flight; older than 10 minutes, it is
  # nobody's, and holding it would cost the day.
  if [ -d "$dir" ] && [ ! -f "$dir/run.json" ] && [ $(( NOW - $(stat -c %Y "$dir" 2>/dev/null || echo "$NOW") )) -gt 600 ]; then
    rm -rf "$dir"
  fi
  mkdir "$dir" 2>/dev/null || { log "dispatch: skip claim-held"; return 0; }
  rc=0; what=""
  sha=$(gh api "repos/$R/commits/main" --jq .sha 2>/dev/null) || { rc=$?; what="main sha read"; }
  if [ "$rc" = 0 ] && ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then rc=1; what="main sha read answered '${sha:0:40}'"; fi
  if [ "$rc" = 0 ]; then
    gh workflow run harness-ci.yml --ref main -R "$R" >/dev/null 2>&1 || { rc=$?; what="gh workflow run harness-ci.yml"; }
  fi
  if [ "$rc" != 0 ]; then
    rm -rf "$dir"
    alert_once "$today" dispatch "dispatch failed rc=$rc ($what); claim removed, next tick retries"
    log "dispatch: failed rc=$rc ($what); claim removed"
    return 1
  fi
  jq -n --arg d "$today" --arg s "$sha" --arg t "$(iso "$NOW")" \
    '{date: $d, sha: $s, dispatched_at: $t, run_id: null}' > "$dir/run.json.tmp" && mv -f "$dir/run.json.tmp" "$dir/run.json"
  id=""
  for i in 1 2 3; do
    id=$(resolve_run "$sha" "$(iso "$NOW")") && break
    id=""
    [ "$i" -lt 3 ] && sleep "$POLL_SLEEP"
  done
  [ -n "$id" ] && set_run_id "$dir/run.json" "$id"
  log "dispatch: dispatched sha=$sha run_id=${id:-pending}"
  return 0
}

# failed_suites <run_id> <out> — `<suite> <rc>` lines from the failed shard
# jobs' logs; notes (unreadable logs, a cap that bit) go to <out>.notes.
failed_suites() {
  local id="$1" out="$2" raw jobs total jid name lg
  : > "$out"; : > "$out.notes"
  raw=$(gh api "repos/$R/actions/runs/$id/jobs?per_page=100&filter=latest" 2>/dev/null) \
    || { echo "The run's job list could not be read." >> "$out.notes"; return 0; }
  jobs=$(jq -r '.jobs[]? | select((.name // "") | contains("shard")) | select(.conclusion != "success") | "\(.id)\t\(.name)"' <<<"$raw" 2>/dev/null)
  total=$(printf '%s\n' "$jobs" | grep -c .)
  [ "$total" -gt "$MAX_LOGS" ] && echo "$(( total - MAX_LOGS )) more failed shard job(s) were not read (cap CI_NIGHTLY_FULL_MAX_LOGS=$MAX_LOGS)." >> "$out.notes"
  while IFS=$'\t' read -r jid name; do
    [ -n "$jid" ] || continue
    if lg=$(gh api --allow-escape-sequences "repos/$R/actions/jobs/$jid/logs" 2>/dev/null); then
      printf '%s\n' "$lg" | sed -n 's/^\([0-9TZ:.-]* \)\{0,1\}--- \(tests\/[^ ]*\) rc=\([1-9][0-9]*\).*/\2 \3/p' >> "$out"
    else
      echo "Job $name: log unreadable." >> "$out.notes"
    fi
  done < <(head -n "$MAX_LOGS" <<<"$jobs")
  LC_ALL=C sort -u -o "$out" "$out"
}

# build_body <date> <sha> <run_url> <run_id> <body-file>
build_body() {
  local d="$1" sha="$2" url="$3" id="$4" body="$5" tmp lg base range why ch n tree map suite rc f missed unread sel
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/ci-nightly-full.XXXXXX") || return 1
  failed_suites "$id" "$tmp/failed"
  git -C "$REPO_DIR" fetch -q origin main 2>/dev/null
  lg=$(cat "$S/last_green_sha" 2>/dev/null)
  why=""
  if [ -z "$lg" ]; then why="no recorded green run"
  elif ! git -C "$REPO_DIR" merge-base --is-ancestor "$lg" "$sha" 2>/dev/null; then why="the last green ${lg:0:12} is not an ancestor of ${sha:0:12}"
  fi
  if [ -z "$why" ]; then base="$lg"; range="${lg:0:12}..${sha:0:12} (the last green full run to this one)"
  elif base=$(git -C "$REPO_DIR" rev-parse -q --verify "$sha~20^{commit}" 2>/dev/null); then
    range="sha~20..sha (${base:0:12}..${sha:0:12}), because $why"
  else
    base=$(git -C "$REPO_DIR" rev-list --max-parents=0 "$sha" 2>/dev/null | tail -1)
    if [ -n "$base" ]; then range="sha~20..sha is not there (fewer than 20 commits), so the root ${base:0:12}..${sha:0:12}, because $why"
    else range="sha~20..sha was wanted ($why), but ${sha:0:12} could not be read from $REPO_DIR"; fi
  fi
  : > "$tmp/changed"
  if [ -n "$base" ] && git -C "$REPO_DIR" diff --name-only --no-renames "$base" "$sha" > "$tmp/changed.all" 2>/dev/null; then
    n=$(grep -c . "$tmp/changed.all"); head -200 "$tmp/changed.all" > "$tmp/changed"
  else
    n=""; echo "The changed files of that range could not be read from $REPO_DIR." >> "$tmp/failed.notes"
  fi
  [ -n "$n" ] && [ "$n" -gt 200 ] && echo "The range changed $n files; only the first 200 were checked against the map." >> "$tmp/failed.notes"
  # The map in force at the red sha: that tree's own bin/test-impact.sh, built
  # once (--map) and asked once per changed file. A pick of kind `full` is the
  # corpus fallback, not the map connecting the file, so it never counts.
  tree="$tmp/tree"; map="$tmp/map"; mkdir -p "$tree"
  if [ -s "$tmp/failed" ] && [ -s "$tmp/changed" ] \
     && git -C "$REPO_DIR" archive "$sha" 2>/dev/null | tar -x -C "$tree" 2>/dev/null \
     && [ -x "$tree/bin/test-impact.sh" ] \
     && "$tree/bin/test-impact.sh" map --root "$tree" --out "$map" >/dev/null 2>&1 && [ -s "$map" ]; then
    while IFS= read -r f; do
      printf '%s\n' "$f" > "$tmp/one"
      if sel=$("$tree/bin/test-impact.sh" select --root "$tree" --map "$map" --changed "$tmp/one" --map-only --why 2>/dev/null); then
        printf '%s\n' "$sel" | awk -F'\t' -v f="$f" 'NF >= 2 && $2 != "full" { print f "\t" $1 }'
      else
        printf '%s\t%s\n' "$f" "!unreadable"
      fi
    done < "$tmp/changed" | LC_ALL=C sort -u > "$tmp/picks"
  else
    : > "$tmp/picks"
    [ -s "$tmp/failed" ] && [ -s "$tmp/changed" ] && echo "The map could not be built at ${sha:0:12}, so no changed file could be checked against it." >> "$tmp/failed.notes"
  fi
  {
    printf '%s\n' "$MARK"
    printf 'The daily full CI run on main (%s) failed on `%s`.\n\n' "$d" "$sha"
    printf 'Run: %s\n\n' "$url"
    printf 'Range: %s.\n\n' "$range"
    if [ -s "$tmp/failed" ]; then
      printf 'Failing suites, and the changed files whose map selection does not reach them:\n'
      while read -r suite rc; do
        missed=""; unread=""
        while IFS= read -r f; do
          [ -n "$f" ] || continue
          if grep -qxF "$f"$'\t!unreadable' "$tmp/picks"; then unread="$unread${unread:+, }\`$f\`"
          elif ! grep -qxF "$f"$'\t'"$suite" "$tmp/picks"; then missed="$missed${missed:+, }\`$f\`"
          fi
        done < "$tmp/changed"
        if [ ! -s "$tmp/picks" ]; then printf -- '- `%s` (rc %s): the map was not read\n' "$suite" "$rc"
        elif [ -n "$missed" ]; then printf -- '- `%s` (rc %s): missed: %s\n' "$suite" "$rc" "$missed"
        else printf -- '- `%s` (rc %s): every changed file selects it: the red is not a map gap\n' "$suite" "$rc"
        fi
        [ -z "$unread" ] || printf '  map unreadable for: %s\n' "$unread"
      done < "$tmp/failed"
      printf '\n'
    else
      printf 'No failing suite could be read from the shard logs; open the run.\n\n'
    fi
    [ -s "$tmp/failed.notes" ] && { cat "$tmp/failed.notes"; printf '\n'; }
    printf 'A merge-queue batch runs only the suites its diff can reach (BH-4968), so a suite listed with missed files did not run in the batch that merged them.\n'
    printf 'Fix the map (bin/test-impact.sh / catalog), not the selection rule.\n'
  } > "$body"
  rm -rf "$tmp"
}

# file_red <date> <body-file> — prints the URL gh returned; rc 1 on any refusal.
file_red() {
  local d="$1" body="$2" open num resp new lab url
  open=$(gh api --paginate "repos/$R/issues?state=open&per_page=100" \
           --jq ".[] | select(.pull_request == null) | select((.body // \"\") | contains(\"$MARK\")) | .number" 2>/dev/null) \
    || { echo "could not list the open issues of $R"; return 1; }
  num=$(printf '%s\n' "$open" | grep -E '^[0-9]+$' | head -1)
  if [ -n "$num" ]; then
    # A comment never adds or re-adds ai-build: a ticket a person unlabelled stays so.
    url=$(gh api -X POST "repos/$R/issues/$num/comments" -F "body=@$body" --jq '.html_url // empty' 2>/dev/null) \
      || { echo "could not comment on #$num"; return 1; }
    [ -n "$url" ] || { echo "the comment on #$num returned no URL"; return 1; }
    printf '%s\n' "$url"; return 0
  fi
  # GitHub drops labels on create, silently, for a caller without push access,
  # so the answer is read back and a dropped label is added once.
  resp=$(gh api -X POST "repos/$R/issues" -f "title=$TITLE" -F "body=@$body" -f 'labels[]=ai-build' \
           --jq '"\(.number) \([.labels[]?.name] | index("ai-build") != null) \(.html_url // "")"' 2>/dev/null) \
    || { echo "could not open an issue on $R"; return 1; }
  read -r new lab url <<<"$resp"
  case "$new" in ''|*[!0-9]*) echo "the create answered '$resp'"; return 1 ;; esac
  [ -n "$url" ] || { echo "the create of #$new returned no URL"; return 1; }
  if [ "$lab" != true ]; then
    gh api -X POST "repos/$R/issues/$new/labels" -f 'labels[]=ai-build' >/dev/null 2>&1 \
      || { echo "opened #$new but could not label it ai-build"; return 1; }
  fi
  printf '%s\n' "$url"
}

do_collect() {
  local i d dir pend="" id sha at raw st concl url body out
  for (( i = 0; i < LOOKBACK; i++ )); do
    d=$(date -u -d "@$(( NOW - i * 86400 ))" +%F); dir="$S/$d"
    [ -f "$dir/run.json" ] && [ ! -e "$dir/done" ] && [ ! -e "$dir/lost" ] && pend="$pend $d"
  done
  [ -n "$pend" ] || return 0
  auth
  budget_low && { log "collect: skip gh-budget-low"; return 0; }
  for d in $pend; do
    dir="$S/$d"
    id=$(jq -r '.run_id // empty' "$dir/run.json" 2>/dev/null)
    sha=$(jq -r '.sha // empty' "$dir/run.json" 2>/dev/null)
    at=$(jq -r '.dispatched_at // empty' "$dir/run.json" 2>/dev/null)
    if [ -z "$id" ]; then
      if id=$(resolve_run "$sha" "$at"); then set_run_id "$dir/run.json" "$id"
      else
        id=""
        if [ -n "$at" ] && [ $(( NOW - $(date -u -d "$at" +%s 2>/dev/null || echo "$NOW") )) -gt 21600 ]; then
          : > "$dir/lost"
          alert_once "$d" lost "the full run dispatched $at for ${sha:0:12} was never found among the dispatch runs of harness-ci.yml; marked lost"
          log "collect $d: lost"
        else
          log "collect $d: pending (run id not visible yet)"
        fi
        continue
      fi
    fi
    raw=$(gh api "repos/$R/actions/runs/$id" 2>/dev/null) || { log "collect $d: pending (run $id read failed)"; continue; }
    st=$(jq -r '.status // empty' <<<"$raw" 2>/dev/null)
    concl=$(jq -r '.conclusion // empty' <<<"$raw" 2>/dev/null)
    url=$(jq -r '.html_url // empty' <<<"$raw" 2>/dev/null)
    [ "$st" = completed ] || { log "collect $d: pending (run $id ${st:-unknown})"; continue; }
    case "$concl" in
      success)
        printf '%s\n' "$sha" > "$S/last_green_sha.tmp" && mv -f "$S/last_green_sha.tmp" "$S/last_green_sha"
        : > "$dir/done"; log "collect $d: green sha=$sha" ;;
      cancelled|skipped|neutral)
        : > "$dir/done"; log "collect $d: $concl (run $id; not a red, no ticket)" ;;
      *)
        body=$(mktemp "${TMPDIR:-/tmp}/ci-nightly-full-body.XXXXXX") || { log "collect $d: red filing-failed (no temp file)"; continue; }
        build_body "$d" "$sha" "${url:-run $id}" "$id" "$body"
        if out=$(file_red "$d" "$body"); then
          printf '%s\n' "$out" > "$dir/ticketed.tmp" && mv -f "$dir/ticketed.tmp" "$dir/ticketed"
          : > "$dir/done"
          log "collect $d: red ticketed #$(printf '%s' "$out" | sed -E 's#.*/issues/([0-9]+).*#\1#')"
        else
          alert_once "$d" filing "the full run of $d (${sha:0:12}) is red and could not be filed: $out; the next collect retries"
          log "collect $d: red filing-failed ($out)"
        fi
        rm -f "$body" ;;
    esac
  done
  return 0
}

case "$SUB" in
  dispatch) do_dispatch ;;
  collect)  do_collect ;;
  *) echo "usage: $0 dispatch|collect" >&2; exit 2 ;;
esac
