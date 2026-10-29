#!/bin/bash
# bin/main-red-breaker.sh — BH-8706: the main-red breaker hub lane, every 5 min.
# Usage: bin/main-red-breaker.sh [--explain] [owner/repo ...]
#
# WHY. bin/main-red-detector.sh raises flags/main-red-<owner>-<repo> and pages
# once, and bin/lib/main-red-gate.sh stops every harness lane from merging or
# labelling a NEW PR `merge-queue`. A PR that already carries `merge-queue`
# still lands through Mergify on the red main, nobody files the fix, and
# nothing resumes the queue (project-6-os 2026-10-27: hours of stalled merges
# after #2763 and #2889 + #2897). This lane closes those three gaps. It reads
# the detector's flag as the only source of truth and never writes or removes
# it.
#
# PER REPO, each tick (the fleet.conf slugs plus $HARNESS_REPO, or the args):
#   FLAG UP, pause. Mergify repos only (mc_queue_provider): every open PR with
#     the exact label `merge-queue`, without `fix-main-red` and without the
#     pause label, gets the pause label (MAIN_RED_BREAKER_PAUSE_LABEL). The
#     non-hotfix queue_rules of config/mergify/template.yml carry
#     `-label=merge-queue-paused` in their queue_conditions, so Mergify
#     dequeues the PR whatever queued it (the label rule or the `@mergifyio
#     queue` command, docs/MERGIFY.md). A repo whose .mergify.yml does not
#     carry that condition ignores the label, so it gets no label and one
#     `does not exclude` line per episode, and its ticket says the queue is NOT
#     paused (pause_hook). The ledger row main_red_breaker <slug>
#     is written `pausing` BEFORE the first label POST: a row that does not
#     write labels nothing, so no label is ever on a PR without a resumable
#     row. It goes `paused` after the POSTs, with every PR whose POST answered
#     2xx. A list that hits MAIN_RED_BREAKER_MAX_PRS logs `pause: capped`.
#     A GitHub-native-queue repo has no label hook: one line per episode.
#   FLAG UP WITH sha= AND since=, file. One `ai-build` + `hotfix` issue per
#     episode (key <slug>@<since>) on the repo's GitHub Issues: the ledger row
#     main_red_hotfix first (rc 2 = a miss, any other rc = file nothing), then
#     the body marker in the open `hotfix` issues, then the POST. The row is
#     written only from a 201 that carries .html_url. A failed create warns
#     once per episode and retries next tick. A sha-less (pr-pair-suspected)
#     flag pauses and files nothing. A project with an in-app board (fleet.conf
#     column 4 is not `-`) gets one log line and no ticket.
#   FLAG GONE AND THE ROW SAYS pausing OR paused, resume. DELETE the pause
#     label from every open PR that carries it (404 = already gone = ok). Then
#     RE-QUEUE each PR the row lists or the label was on: Mergify stamps
#     `dequeued` on a PR that leaves the queue and does not take it back by
#     itself, so the label removal alone resumes nothing. mc_requeue_mergify
#     removes `dequeued` and posts `@mergifyio requeue`. It is called without
#     mc_requeued_record, so a pause costs no PR its one BH-636 requeue. One
#     `qpaused <slug>#<n> <head>` conductor mark first, so the conductor holds
#     the PR one tick while Mergify takes it back (bin/merge-conductor.d/
#     bh-8706-queue-paused.sh). A PR that is closed, lost `merge-queue` or
#     answered rc 0/2/3/4 is done (state/main-red-breaker/<key>.rq-<n>); rc 1
#     retries next tick. The row goes `resumed` only when every DELETE
#     answered ok, every PR is done AND a re-read shows 0 labelled PRs.
#   No flag and no pausing/paused row: one ledger read, no GitHub read.
#
# NO PAGE. The detector already sent the one --critical alert. This lane only
# warns on its own failure to file (lane-alert --id main-red-breaker-file:<key>).
#
# OUTPUTS. logs/main-red-breaker.log, one line per action and one summary line
# per tick. state/main-red-breaker/ holds the once-per-episode notes.
# OFF: flags/lane-off-main-red-breaker (bin/harness-ctl.sh off main-red-breaker).
# Registry: catalog/lanes.d/main-red-breaker.json. Cron:
# cron/lanes/777-main-red-breaker.cron. Suite: tests/main-red-breaker.bh-8706-test.sh.
set -uo pipefail
H="${HARNESS:-/root/harness}"

# >>> lane gate (BH-1165): exits 0 on flags/all-off or flags/lane-off-main-red-breaker.
# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit main-red-breaker
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    main-red-breaker
# shellcheck source=bin/lib/env-path.sh
. "$H/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "$H/env"; }
HENV=$(harness_env_dir)
if [ -f "$HENV/global.env" ]; then set -a
  # shellcheck disable=SC1091
  . "$HENV/global.env" 2>/dev/null; set +a; fi
# Again below the env load: global.env re-assigns what the row exported.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    main-red-breaker
export HARNESS="$H"
# shellcheck disable=SC1091
{
  . "$H/bin/lib/hub-box.sh" 2>/dev/null || true
  . "$H/bin/jobs-client.sh" 2>/dev/null || true
  . "$H/bin/lib/gh-rest-list.sh" 2>/dev/null || true
  . "$H/bin/lib/gh-app-auth.sh" 2>/dev/null || true
  . "$H/bin/lib/main-red-label.sh" 2>/dev/null || true
  . "$H/bin/lib/merge-conductor-lib.sh" 2>/dev/null || true
  . "$H/bin/lib/tracker.sh" 2>/dev/null || true
}
# The suite's seam: a file that redefines gh_rest, the ledger verbs and the
# provider as recorders. Sandbox only, and settable:false in the registry.
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${MAIN_RED_BREAKER_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$MAIN_RED_BREAKER_FIXTURE"
fi
for f in is_hub_box local_box_name gh_rest _gh_rest_list gh_rest_issue_list job_ledger_row job_ledger_put \
         mc_queue_provider main_red_label_resolve tracker_load; do
  command -v "$f" >/dev/null 2>&1 || { echo "main-red-breaker: $f is missing (bin/lib/)" >&2; exit 1; }
done
# PR labels and the hotfix issue live on GitHub for every repo this lane walks,
# so the issue writes go through the github-issues tracker adapter (BH-7919).
tracker_load github-issues || { echo "main-red-breaker: tracker_load github-issues failed (bin/lib/tracker/)" >&2; exit 1; }

EXPLAIN=0; ARGS=()
for a in "$@"; do
  case "$a" in
    --explain) EXPLAIN=1 ;;
    -h|--help) sed -n '2,3p' "$0"; exit 0 ;;
    */*) ARGS+=("$a") ;;
    *) echo "main-red-breaker: unknown argument '$a'" >&2; exit 2 ;;
  esac
done

is_hub_box "$(local_box_name)" || exit 0

ST="$H/state/main-red-breaker"
LOG="$H/logs/main-red-breaker.log"
mkdir -p "$H/logs" "$H/locks" "$ST" 2>/dev/null
log() { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*" >> "$LOG"; }
exec 9>"$H/locks/main-red-breaker.lock" || exit 0
flock -n 9 || { log "another main-red-breaker tick holds the lock, skipping"; exit 0; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/mrbk-XXXXXX") || exit 1
trap 'case "$TMP" in */mrbk-?*) rm -rf "$TMP" ;; esac' EXIT

# kint <value> <default> <min> <max> — an int knob, the default when invalid or out of range.
kint() {
  case "$1" in ''|*[!0-9]*) printf '%s' "$2"; return ;; esac
  [ "${#1}" -le 6 ] && [ "$((10#$1))" -ge "$3" ] && [ "$((10#$1))" -le "$4" ] \
    && printf '%s' "$((10#$1))" || printf '%s' "$2"
}
# Each fallback below is the seed of its settings row lane.main-red-breaker.<env lowercased>
# (worker/jobs/schema.d/202610290144-bh-8706-main-red-breaker-knobs.sql).
MAX_PRS=$(kint "${MAIN_RED_BREAKER_MAX_PRS:-50}" 50 1 500)                 # ...main_red_breaker_max_prs
MAX_JOBS=$(kint "${MAIN_RED_BREAKER_MAX_JOBS:-5}" 5 1 50)                  # ...main_red_breaker_max_jobs
MAX_ANN=$(kint "${MAIN_RED_BREAKER_MAX_ANNOTATIONS:-10}" 10 0 100)         # ...main_red_breaker_max_annotations
MAX_SUS=$(kint "${MAIN_RED_BREAKER_MAX_SUSPECTS:-20}" 20 1 250)            # ...main_red_breaker_max_suspects
FILE_ON=$(kint "${MAIN_RED_BREAKER_TICKETS:-1}" 1 0 1)                        # ...main_red_breaker_tickets
PAUSE="${MAIN_RED_BREAKER_PAUSE_LABEL:-merge-queue-paused}"               # ...main_red_breaker_pause_label
[[ "$PAUSE" =~ ^[A-Za-z0-9._-]+$ ]] || PAUSE=merge-queue-paused
TLABELS="${MAIN_RED_BREAKER_TICKET_LABELS:-ai-build,hotfix}"              # ...main_red_breaker_ticket_labels
[[ "$TLABELS" =~ ^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$ ]] || TLABELS=ai-build,hotfix
QLABEL=merge-queue
FIXLABEL=$(main_red_label_resolve "$H" 2>/dev/null); FIXLABEL=${FIXLABEL:-fix-main-red}

# BH-4080: HARNESS_REPO's default lives in the deployment defaults home.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$(dirname "${BASH_SOURCE[0]}")/lib/deployment.sh}" || exit 1

# The repo list: fleet.conf column 2 (the detector reads the same rows) plus the
# harness repo, or the arguments.
if [ "${#ARGS[@]}" -gt 0 ]; then
  REPOS=$(printf '%s\n' "${ARGS[@]}")
else
  REPOS=$( { awk '$1!~/^#/ && NF>=2 && $0!~/redirect/ {print $2}' "$H/fleet.conf" 2>/dev/null; echo "${HARNESS_REPO:-}"; } \
           | grep -E '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' | awk '!seen[$0]++' )
fi

fget() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }
skey() { printf '%s' "$1" | sha256sum | cut -c1-16; }
# board_col <slug> — fleet.conf column 4 of the row whose column 2 is <slug>; empty when no row.
board_col() { awk -v s="$1" '$1!~/^#/ && NF>=4 && $2==s {print $4; exit}' "$H/fleet.conf" 2>/dev/null; }

# list_prs <slug> <label> <jq-extra> <out> — open PRs carrying <label> exactly,
# filtered by <jq-extra>, at most MAX_PRS. rc is the list read's rc.
list_prs() {
  local f
  f="select(.pull_request != null and .state == \"open\" and ((.labels // []) | map(.name) | index(\"$2\")) != null) $3"
  _gh_rest_list "$1" issues "$MAX_PRS" "$f" -f state=open -f "labels=$2" > "$4"
}

# ── pause ───────────────────────────────────────────────────────────────────
# pause_hook <slug> — sets HOOK: yes when the repo's default-branch .mergify.yml
# carries `-label=$PAUSE` (config/mergify/template.yml puts it in each
# non-hotfix queue's queue_conditions), no when the file reads without it or
# answers 404, unknown when the read fails. A repo whose .mergify.yml is not
# rendered from the template (example-org/project-6, or a repo before its
# bin/mergify-sync.sh apply PR merges) ignores the label: the label there
# pauses nothing, so the lane does not write it and the ticket does not say so.
pause_hook() {
  local rc=0 b64 yml
  HOOK=unknown
  gh_rest GET "repos/$1/contents/.mergify.yml" > "$TMP/mfy.json" || rc=$?
  case "$rc" in 0) ;; 44) HOOK=no; return 0 ;; *) return 0 ;; esac
  b64=$(jq -r '.content // empty' "$TMP/mfy.json" 2>/dev/null)
  [ -n "$b64" ] || return 0
  yml=$(printf '%s' "$b64" | tr -d '\n\r ' | base64 -d 2>/dev/null) || yml=""
  [ -n "$yml" ] || return 0
  if grep -qE -- "^[[:space:]]*-[[:space:]]*\"?-label[[:space:]]*=[[:space:]]*${PAUSE//./\\.}\"?[[:space:]]*(#.*)?$" <<<"$yml"; then
    HOOK=yes
  else
    HOOK=no
  fi
}

# pause <slug> <since> — sets PAUSED_N and HOOK. rc 1: the repo was not read (skip it).
pause() {
  local slug="$1" since="$2" prov rc nums n ok=() prev keep
  PAUSED_N=0; HOOK=no
  prov=$(mc_queue_provider "$slug" 2>/dev/null)
  if [ "$prov" != mergify ]; then
    if [ "$(cat "$ST/$(skey "$slug").noprov" 2>/dev/null)" != "$since" ]; then
      log "$slug: pause: provider=${prov:-none} — not paused (no label hook)"
      [ "$EXPLAIN" = 1 ] || printf '%s' "$since" > "$ST/$(skey "$slug").noprov"
    fi
    return 0
  fi
  pause_hook "$slug"
  if [ "$HOOK" = no ]; then
    if [ "$(cat "$ST/$(skey "$slug").nohook" 2>/dev/null)" != "$since" ]; then
      log "$slug: pause: $slug's .mergify.yml does not exclude $PAUSE — not paused (the label would do nothing)"
      [ "$EXPLAIN" = 1 ] || printf '%s' "$since" > "$ST/$(skey "$slug").nohook"
    fi
    return 0
  fi
  # HOOK=unknown (the .mergify.yml read failed): the labels still go on. On a
  # templated repo they pause the queue; on any other repo they do nothing.
  # The ticket body says the pause is unknown, never that the queue is paused.
  [ "$HOOK" = unknown ] && log "$slug: pause: the .mergify.yml read failed (http=${GH_REST_STATUS:-000}) — labels go on, the pause is unconfirmed"
  rc=0
  list_prs "$slug" "$QLABEL" "| select((.labels | map(.name)) as \$l | (\$l | index(\"$FIXLABEL\")) == null and (\$l | index(\"$PAUSE\")) == null) | .number" \
    "$TMP/q.json" || rc=$?
  if [ "$rc" != 0 ]; then
    log "$slug: pause: the merge-queue list did not read (rc=$rc http=${GH_REST_STATUS:-000} reason=${GH_REST_REASON:--}) — nothing paused, retry next tick"
    return 1
  fi
  nums=$(jq -r '.[]' "$TMP/q.json" 2>/dev/null)
  # Every PR this episode paused so far (a pausing or paused row of this since).
  prev=$(printf '%s' "$ROW" | jq -r 'select(.status=="paused" or .status=="pausing") | .detail | fromjson? | select(.since=="'"$since"'") | .paused[]?' 2>/dev/null)
  # THE ROW BEFORE THE LABELS (BH-8706 review). Resume is driven by this row;
  # a label written under no row would never come off. No row, no label.
  if [ -n "$nums" ] && [ "$EXPLAIN" != 1 ]; then
    keep=$(printf '%s\n' $prev | grep -E '^[0-9]+$' | sort -n -u | jq -Rsc 'split("\n") | map(select(length>0) | tonumber)')
    if ! job_ledger_put main_red_breaker "$slug" pausing \
         "$(jq -nc --arg s "$since" --argjson p "${keep:-[]}" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '{since:$s, paused:$p, at:$at}')" >/dev/null 2>&1; then
      log "$slug: pause: the main_red_breaker pausing row did not write — nothing labelled, retry next tick"
      return 1
    fi
    ROWST=pausing
  fi
  for n in $nums; do
    if [ "$EXPLAIN" = 1 ]; then log "$slug: WOULD PAUSE #$n"; continue; fi
    rc=0; TRK_SLUG="$slug" tracker_label_add "$n" "$PAUSE" || rc=$?
    if [ "$rc" = 0 ]; then ok+=("$n")
    else log "$slug: pause: #$n label POST failed (rc=$rc http=${GH_REST_STATUS:-000}) — not counted, retry next tick"; fi
  done
  PAUSED_N=${#ok[@]}
  [ "$(printf '%s\n' "$nums" | grep -c .)" -ge "$MAX_PRS" ] && log "$slug: pause: capped at $MAX_PRS, the rest next tick"
  [ "$EXPLAIN" = 1 ] && return 0
  # The row after the labels. It carries every PR this episode paused so far.
  # A failed write leaves the pausing row, which resume reads the same way.
  if [ "$PAUSED_N" -gt 0 ] || [ "$ROWST" != paused ] || [ -z "$(printf '%s' "$ROW" | jq -r '.detail | fromjson? | select(.since=="'"$since"'") | .since' 2>/dev/null)" ]; then
    keep=$(printf '%s\n' $prev ${ok[@]+"${ok[@]}"} | grep -E '^[0-9]+$' | sort -n -u | jq -Rsc 'split("\n") | map(select(length>0) | tonumber)')
    job_ledger_put main_red_breaker "$slug" paused \
      "$(jq -nc --arg s "$since" --argjson p "${keep:-[]}" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '{since:$s, paused:$p, at:$at}')" >/dev/null 2>&1 \
      || log "$slug: pause: the main_red_breaker paused row did not write — the pausing row stands, the next tick writes it"
  fi
  [ "$PAUSED_N" -gt 0 ] && log "$slug: paused $PAUSED_N PR(s): ${ok[*]}"
  return 0
}

# ── file ────────────────────────────────────────────────────────────────────
# compose <slug> <flag> <out-body> — writes the issue body, sets TITLE_JOB.
compose() {
  local slug="$1" flag="$2" out="$3" run sha wf path job runid rc green
  run=$(fget "$flag" run); sha=$(fget "$flag" sha); wf=$(fget "$flag" workflow)
  path=$(fget "$flag" path); job=$(fget "$flag" job)
  TITLE_JOB="$job"
  {
    echo "Main on \`$slug\` is red since $(fget "$flag" since) (workflow \`${wf:-unknown}\`, sha \`${sha:0:12}\`, reason \`$(fget "$flag" reason)\`)."
    case "$HOOK" in
      yes) echo "Merges for this repo are frozen and its Mergify queue is paused until main is green." ;;
      unknown) echo "New enqueues for this repo are frozen until main is green. The Mergify queue pause is unconfirmed: the \`.mergify.yml\` read failed." ;;
      *) echo "New enqueues for this repo are frozen until main is green. Its merge queue is NOT paused: PRs already queued can still merge. $(
           [ "$(mc_queue_provider "$slug" 2>/dev/null)" = mergify ] && echo "\`.mergify.yml\` does not exclude \`$PAUSE\`." || echo "The repo has no Mergify queue to pause.")" ;;
    esac
    echo "Land the fix as a PR labelled \`$FIXLABEL\`."
    echo
    echo "## Failing checks"
  } > "$out"
  : > "$TMP/joburls"
  runid=""
  [[ "$run" =~ /actions/runs/([0-9]+) ]] && runid="${BASH_REMATCH[1]}"
  rc=1
  if [ -n "$runid" ]; then
    rc=0; gh_rest GET "repos/$slug/actions/runs/$runid/jobs?filter=latest&per_page=100" > "$TMP/jobs.json" || rc=$?
  fi
  if [ "$rc" = 0 ] && jq -e '.jobs | type == "array"' "$TMP/jobs.json" >/dev/null 2>&1; then
    jq -c --argjson m "$MAX_JOBS" '[.jobs[] | select(.conclusion == "failure")][:$m][]' "$TMP/jobs.json" > "$TMP/failed.jsonl"
    if [ ! -s "$TMP/failed.jsonl" ]; then
      echo "- no failed job in run $runid (the flag says: ${job:-unknown})" >> "$out"
    fi
    local first=1 jid jname jurl steps
    while IFS= read -r j; do
      jid=$(jq -r '.id' <<< "$j"); jname=$(jq -r '.name' <<< "$j"); jurl=$(jq -r '.html_url // ""' <<< "$j")
      [ "$first" = 1 ] && TITLE_JOB="$jname"; first=0
      steps=$(jq -r '[.steps[]? | select(.conclusion == "failure") | .name] | join(", ")' <<< "$j")
      echo "- **$jname**${steps:+ (failed step: $steps)} — $jurl" >> "$out"
      [ -n "$jurl" ] && echo "$jurl" >> "$TMP/joburls"
      if [ "$MAX_ANN" -gt 0 ]; then
        rc=0; gh_rest GET "repos/$slug/check-runs/$jid/annotations" > "$TMP/ann.json" || rc=$?
        if [ "$rc" = 0 ]; then
          jq -r --argjson m "$MAX_ANN" '[.[]? | select(.annotation_level == "failure")][:$m][] | "  - `\(.path // ""):\(.start_line // "")` \(.message // "" | gsub("\n"; " ") | .[0:300])"' \
            "$TMP/ann.json" >> "$out" 2>/dev/null
        else
          echo "  - annotations: unknown — the read answered rc=$rc http=${GH_REST_STATUS:-000}" >> "$out"
        fi
      fi
    done < "$TMP/failed.jsonl"
  else
    echo "Failing checks: unknown — the jobs of run ${runid:-<none in the flag>} did not read (rc=$rc http=${GH_REST_STATUS:-000}). The flag says: ${job:-unknown}." >> "$out"
  fi
  { echo; echo "## Suspect merges"; } >> "$out"
  green=""; rc=1
  if [ -n "$path" ] && [ -n "$sha" ]; then
    rc=0; gh_rest GET "repos/$slug/actions/workflows/$(basename "$path")/runs?branch=main&status=success&per_page=1" > "$TMP/green.json" || rc=$?
    [ "$rc" = 0 ] && green=$(jq -r '.workflow_runs[0].head_sha // empty' "$TMP/green.json" 2>/dev/null)
  fi
  if [ -z "$green" ]; then
    echo "Suspect merges: unknown — no green run of \`${path:-?}\` on main was found (rc=$rc http=${GH_REST_STATUS:-000})." >> "$out"
  else
    rc=0; gh_rest GET "repos/$slug/compare/$green...$sha" > "$TMP/cmp.json" || rc=$?
    if [ "$rc" != 0 ] || ! jq -e '.commits | type == "array"' "$TMP/cmp.json" >/dev/null 2>&1; then
      echo "Suspect merges: unknown — the compare ${green:0:12}...${sha:0:12} did not read (rc=$rc http=${GH_REST_STATUS:-000})." >> "$out"
    else
      echo "Merges since the last green \`${green:0:12}\` of this workflow, oldest first:" >> "$out"
      jq -r --argjson m "$MAX_SUS" --arg s "$slug" '[.commits[] | (.commit.message | split("\n")[0]) as $t
          | ($t | capture("^Merge pull request #(?<n>[0-9]+)") // ($t | capture("\\(#(?<n>[0-9]+)\\)$")) // null) as $c
          | select($c != null) | "- #\($c.n) \($t) — https://github.com/\($s)/pull/\($c.n) (`\(.sha[0:12])`)"]
        | if length == 0 then ["- none: no PR merge between the two shas"] else .[:$m] end | .[]' "$TMP/cmp.json" >> "$out"
    fi
  fi
  {
    echo; echo "## Logs"
    echo "- run: ${run:-unknown}"
    sed 's/^/- job: /' "$TMP/joburls"
    [ "$slug" = "${HARNESS_REPO:-}" ] && echo "- bisect lane: logs/main-red-bisect.log on the hub"
    echo
    echo "PR-Labels: $FIXLABEL"
    echo
    echo "<!-- main-red-breaker: $slug@$(fget "$flag" since) -->"
    echo "Filed by bin/main-red-breaker.sh (BH-8706)"
  } >> "$out"
}

# file_ticket <slug> <flag> — at most one issue per <slug>@<since>.
file_ticket() {
  local slug="$1" flag="$2" since key rc url num w
  since=$(fget "$flag" since); key="$slug@$since"
  rc=0; job_ledger_row main_red_hotfix "$key" > /dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 0 ;;
    2) ;;
    *) log "$slug: ticket: the main_red_hotfix row did not read (rc=$rc) — nothing filed this tick"; return 0 ;;
  esac
  rc=0; gh_rest_issue_list "$slug" open hotfix 1000 > "$TMP/hot.json" || rc=$?
  if [ "$rc" != 0 ]; then
    log "$slug: ticket: the open hotfix issues did not read (rc=$rc http=${GH_REST_STATUS:-000}) — nothing filed this tick"; return 0
  fi
  jq -c --arg m "<!-- main-red-breaker: $key -->" '[.[] | select((.body // "") | contains($m))][0] // empty | {issue:.number, url:.html_url}' \
    "$TMP/hot.json" > "$TMP/hit.json" 2>/dev/null
  if [ -s "$TMP/hit.json" ]; then
    [ "$EXPLAIN" = 1 ] && { log "$slug: WOULD RECORD the existing ticket $(jq -r .url "$TMP/hit.json")"; return 0; }
    job_ledger_put main_red_hotfix "$key" filed "$(cat "$TMP/hit.json")" >/dev/null 2>&1
    log "$slug: ticket: already open $(jq -r .url "$TMP/hit.json") — row written, nothing posted"
    return 0
  fi
  compose "$slug" "$flag" "$TMP/body.md"
  jq -n --arg t "HOTFIX: $slug main is red — $(fget "$flag" workflow) / ${TITLE_JOB:-unknown job}" \
        --rawfile b "$TMP/body.md" --arg l "$TLABELS" '{title:$t, body:$b, labels:($l | split(","))}' > "$TMP/issue.json"
  if [ "$EXPLAIN" = 1 ]; then log "$slug: WOULD FILE \"$(jq -r .title "$TMP/issue.json")\""; return 0; fi
  rc=0; TRK_SLUG="$slug" tracker_create "$TMP/issue.json" "$TMP/created.json" || rc=$?
  url=$(jq -r '.html_url // empty' "$TMP/created.json" 2>/dev/null); num=$(jq -r '.number // empty' "$TMP/created.json" 2>/dev/null)
  if [ "$rc" = 0 ] && [ "${GH_REST_STATUS:-}" = 201 ] && [ -n "$url" ]; then
    job_ledger_put main_red_hotfix "$key" filed "$(jq -nc --arg u "$url" --arg n "$num" '{issue:($n|tonumber? // $n), url:$u}')" >/dev/null 2>&1 \
      || log "$slug: ticket: the main_red_hotfix row did not write — the marker search finds the issue next tick"
    log "$slug: ticket: filed $url"
    return 0
  fi
  log "$slug: ticket: the create failed (rc=$rc http=${GH_REST_STATUS:-000}) — retry next tick"
  w="$ST/$(skey "$key").warned"
  if [ ! -f "$w" ]; then
    "$H/bin/lane-alert.sh" --severity warn --id "main-red-breaker-file:$key" main-red-breaker \
      "main-red-breaker: could not file the hotfix ticket for $slug (red since $since, http ${GH_REST_STATUS:-000}). Merges stay paused. The lane retries every tick." >/dev/null 2>&1
    echo "$key" > "$w"
  fi
  return 0
}

# ── resume ──────────────────────────────────────────────────────────────────
# requeue_one <slug> <n> <mark> — put one paused PR back in the Mergify queue.
# rc 0: done (the mark is written), rc 1: retry next tick.
requeue_one() {
  local slug="$1" n="$2" mark="$3" rc st head url has out
  [ -f "$mark" ] && return 0
  rc=0; gh_rest GET "repos/$slug/pulls/$n" > "$TMP/pr.json" || rc=$?
  if [ "$rc" != 0 ]; then
    log "$slug: resume: #$n did not read (rc=$rc http=${GH_REST_STATUS:-000}) — retry next tick"; return 1
  fi
  st=$(jq -r '.state // empty' "$TMP/pr.json" 2>/dev/null); head=$(jq -r '.head.sha // empty' "$TMP/pr.json" 2>/dev/null)
  url=$(jq -r '.html_url // empty' "$TMP/pr.json" 2>/dev/null)
  has=$(jq -r --arg l "$QLABEL" '[.labels[]?.name] | index($l) != null' "$TMP/pr.json" 2>/dev/null)
  if [ "$st" != open ] || [ "$has" != true ] || [ -z "$head" ] || [ -z "$url" ]; then
    log "$slug: resume: #$n not re-queued (state=${st:-?}, $QLABEL=${has:-?}) — nothing to put back"
    echo "-" > "$mark"; return 0
  fi
  if [ "$EXPLAIN" = 1 ]; then log "$slug: WOULD REQUEUE #$n on ${head:0:8}"; return 0; fi
  if ! command -v mc_requeue_mergify >/dev/null 2>&1; then
    log "$slug: resume: #$n not re-queued — mc_requeue_mergify is not loaded; retry next tick"; return 1
  fi
  # The conductor's grace mark (bin/merge-conductor.d/bh-8706-queue-paused.sh):
  # Mergify takes the PR back in ~40-60 s, and a conductor read in that window
  # must not count the PR as ejected.
  command -v mc_attempt_put >/dev/null 2>&1 && { mc_attempt_has "qpaused $slug#$n $head" 2>/dev/null || mc_attempt_put "qpaused $slug#$n $head"; }
  out=$(mc_requeue_mergify "$slug" "$url" "$head" 2>/dev/null); rc=$?
  case "$rc" in
    0|2|3) log "$slug: resume: #$n re-queued on ${head:0:8} (rc=$rc: 0 witnessed, 2 merged, 3 asked and not witnessed yet)"
           echo "$head" > "$mark"; return 0 ;;
    4)     log "$slug: resume: #$n not re-queued — a human lead verdict is required: ${out:-no reason}"
           echo "$head" > "$mark"; return 0 ;;
    *)     log "$slug: resume: #$n re-queue refused (rc=$rc: ${out:-no reason}) — retry next tick"; return 1 ;;
  esac
}

resume() {
  local slug="$1" rc nums n bad=0 left since listed todo
  since=$(printf '%s' "$ROW" | jq -r '.detail | fromjson? | .since // empty' 2>/dev/null)
  listed=$(printf '%s' "$ROW" | jq -r '.detail | fromjson? | .paused[]?' 2>/dev/null)
  rc=0; list_prs "$slug" "$PAUSE" "| .number" "$TMP/p.json" || rc=$?
  if [ "$rc" != 0 ]; then
    log "$slug: resume: the $PAUSE list did not read (rc=$rc http=${GH_REST_STATUS:-000}) — retry next tick"; return 0
  fi
  nums=$(jq -r '.[]' "$TMP/p.json" 2>/dev/null)
  for n in $nums; do
    if [ "$EXPLAIN" = 1 ]; then log "$slug: WOULD RESUME #$n"; continue; fi
    rc=0; TRK_SLUG="$slug" tracker_label_remove "$n" "$PAUSE" || rc=$?
    case "$rc" in 0|44) ;; *) bad=1; log "$slug: resume: #$n label DELETE failed (rc=$rc http=${GH_REST_STATUS:-000}) — retry next tick" ;; esac
  done
  [ "$bad" = 0 ] || return 0
  # Every PR the row lists or the label was on goes back in the queue.
  todo=$(printf '%s\n' $listed $nums | grep -E '^[0-9]+$' | sort -n -u)
  for n in $todo; do
    requeue_one "$slug" "$n" "$ST/$(skey "$slug@${since:-unknown}").rq-$n" || bad=1
  done
  [ "$EXPLAIN" = 1 ] && return 0
  [ "$bad" = 0 ] || return 0
  rc=0; list_prs "$slug" "$PAUSE" "| .number" "$TMP/p2.json" || rc=$?
  left=$(jq 'length' "$TMP/p2.json" 2>/dev/null)
  if [ "$rc" != 0 ] || [ "$left" != 0 ]; then
    log "$slug: resume: ${left:-?} PR(s) still carry $PAUSE after the DELETEs (rc=$rc) — retry next tick"; return 0
  fi
  if job_ledger_put main_red_breaker "$slug" resumed \
       "$(jq -nc --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --argjson n "$(printf '%s\n' "$todo" | grep -c .)" '{resumed:$n, at:$at}')" >/dev/null 2>&1; then
    log "$slug: resumed ($(printf '%s\n' "$todo" | grep -c .) PR(s) unpaused and re-queued)"
  else
    log "$slug: resume: labels removed but the main_red_breaker row did not write — retry next tick"
  fi
}

# project-loop-ok: the loop walks repo slugs (fleet.conf plus $HARNESS_REPO, which is no fleet project), not projects; a green repo costs one keyed ledger read and no GitHub read, and a red one (0-2 at a time) is capped at MAIN_RED_BREAKER_MAX_PRS writes, so one bounded */5 pass needs no per-project runner.
RED=0; SEEN=0
for SLUG in $REPOS; do
  SEEN=$((SEEN+1))
  FLAG="$H/flags/main-red-$(printf '%s' "$SLUG" | tr '/' '-')"
  rc=0; ROW=$(job_ledger_row main_red_breaker "$SLUG" 2>/dev/null) || rc=$?
  case "$rc" in
    0) ROWST=$(printf '%s' "$ROW" | jq -r '.status // empty' 2>/dev/null) ;;
    2) ROW=""; ROWST="" ;;
    *) log "$SLUG: the main_red_breaker row did not read (rc=$rc) — repo skipped this tick"; continue ;;
  esac
  if [ ! -f "$FLAG" ]; then
    case "$ROWST" in pausing|paused) ;; *) continue ;; esac
    if command -v gh_default_auth_for_slug >/dev/null 2>&1 && ! gh_default_auth_for_slug "$SLUG"; then
      log "$SLUG: no identity for $SLUG — not resumed"; continue
    fi
    resume "$SLUG"
    continue
  fi
  RED=$((RED+1))
  if command -v gh_default_auth_for_slug >/dev/null 2>&1 && ! gh_default_auth_for_slug "$SLUG"; then
    log "$SLUG: no identity for $SLUG — nothing paused or filed"; continue
  fi
  SINCE=$(fget "$FLAG" since); SHA=$(fget "$FLAG" sha)
  pause "$SLUG" "${SINCE:-unknown}" || continue
  if [ "$FILE_ON" != 1 ]; then continue; fi
  if [ -z "$SHA" ] || [ -z "$SINCE" ]; then
    log "$SLUG: ticket: the flag has no judged sha yet ($(fget "$FLAG" reason)) — paused, nothing filed"
    continue
  fi
  b=$(board_col "$SLUG")
  if [ -n "$b" ] && [ "$b" != "-" ]; then
    log "$SLUG: ticket: not filed — $(awk -v s="$SLUG" '$1!~/^#/ && $2==s {print $1; exit}' "$H/fleet.conf" 2>/dev/null) uses an in-app board"
    continue
  fi
  file_ticket "$SLUG" "$FLAG"
done
log "tick: $SEEN repo(s), $RED red repo(s)$([ "$EXPLAIN" = 1 ] && echo ' (explain: nothing written)')"
exit 0
