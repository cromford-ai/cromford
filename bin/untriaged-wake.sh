#!/bin/bash
# bin/untriaged-wake.sh — the deterministic doorbell for tickets GitHub never
# rings about (BH-2754, Ask 2 of #2751). Cron: */10 on the hub.
#
# Until this lane the only producer of a `wakes` row was the GitHub webhook, so
# an open `ai-build` issue that nobody touched was never looked at: 145 sat
# untriaged on 2026-09-26. Each tick, for every GitHub-Issues project in
# fleet.conf, this posts one nudge to POST /api/wakes/nudge per:
#
#   UNTRIAGED <n>            open ai-build, 0 comments, created more than
#                            UNTRIAGED_WAKE_AFTER_MIN ago.     dedupe untriaged:<n>
#   UNBLOCKED <n> <lastdep>  a child the REAL bin/unblocked-children.sh releases
#                            after a close inside the last
#                            UNTRIAGED_WAKE_LOOKBACK_MIN.      dedupe unblocked:<n>:<lastdep>
#
# A Jira or Linear project (bin/lib/trk-lane.sh) gets only the UNTRIAGED class,
# read through the tracker contract (ut_trk_untriaged): key CRO-12, dedupe
# untriaged:cro-12, posted after every GitHub row.
#
# bin/wake-loop.sh reads the row like any kind=issue wake and launches a scoped
# triage. The worker's UNIQUE(repo,kind,key,minute) with minute
# 'nudge:<dedupe>' is the only once-only store: this lane keeps no watermark
# and recomputes from GitHub every tick, so re-posting is harmless.
#
# NO MODEL. The lane's own side effect is the POST. Its call into the real
# bin/unblocked-children.sh can write to a board, though: with revdep on, that
# script runs bin/decompose-parent-close.sh --cooled, which closes a decomposed
# master whose children have all closed and comments on it, with the same
# cooling and markers as wake-loop's own call. The dep-verify class, whose
# one-time "Building this now" comment would promise a build for a child this
# lane then refuses to wake, is switched off for the call (DEP_VERIFY=0), so it
# never reaches bin/dep-verify.sh or posts that comment. A nudge is counted
# only on a 2xx that says inserted:1; any other answer (404 before the worker
# deploy, 401, a transport failure) is `could-not-run <code>`, stops the posting
# and leaves the rest for the next tick. A failed GitHub read is could-not-run
# for that project, never "no candidates" (D9). Always exit 0; one log line per
# run in logs/untriaged-wake.log. At most UNTRIAGED_WAKE_MAX posts per run, and
# what the cap left is counted and named (D12/D21).
#
# gh-rest: no-graphql
set -uo pipefail
# HARNESS is overridable so tests/untriaged-wake.bh-2754-test.sh can drive the
# SHIPPED script against a scratch tree; cron sets it nowhere.
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
set -a; . "$HENV/global.env" 2>/dev/null; set +a

# >>> lane gate — flags/all-off and flags/lane-off-untriaged-wake stop the lane
# BEFORE any GitHub read; lane_env_apply then puts this lane's settings rows
# into the ${KNOB:-default} reads below. Both fail OPEN. Below the env load
# (a row must beat global.env) and above every read (a stop must stop all of it).
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off untriaged-wake.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit untriaged-wake
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    untriaged-wake

mkdir -p "$H/logs" 2>/dev/null
LOG="$H/logs/untriaged-wake.log"
say() { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') untriaged-wake $*" >> "$LOG"; }

# bin/jobs-client.sh `exit`s when a module is missing, which would end this
# lane with no log line, so it is proved loadable in a child shell first.
# shellcheck source=bin/lib/untriaged-lib.sh
. "$H/bin/lib/untriaged-lib.sh" 2>/dev/null
# shellcheck source=bin/lib/gh-rest.sh
. "$H/bin/lib/gh-rest.sh" 2>/dev/null
# Jira and Linear read through the tracker contract (BH-8451).
# shellcheck source=bin/lib/trk-lane.sh
. "$H/bin/lib/trk-lane.sh" 2>/dev/null
# shellcheck source=bin/lib/untriaged-board-read.sh
. "$H/bin/lib/untriaged-board-read.sh" 2>/dev/null
if bash -c '. "$1"' _ "$H/bin/jobs-client.sh" >/dev/null 2>&1; then
  # shellcheck source=bin/jobs-client.sh
  . "$H/bin/jobs-client.sh" >/dev/null 2>&1
fi
for f in ut_gh_projects ut_open_issues gh_rest _gh_rest_list _jobs_req trk_lane_kind ut_trk_untriaged; do
  declare -F "$f" >/dev/null || { say "could-not-run lib"; exit 0; }
done
# Whichever token can SEE the repo, as bin/unblocked-children.sh does: the hub's
# default PAT 404s on example-org/project-5. Absent lib = plain gh.
# shellcheck source=bin/lib/gh-repo-token.sh
[ -r "$H/bin/lib/gh-repo-token.sh" ] && . "$H/bin/lib/gh-repo-token.sh" 2>/dev/null

AFTER="${UNTRIAGED_WAKE_AFTER_MIN:-30}"
LOOK="${UNTRIAGED_WAKE_LOOKBACK_MIN:-60}"
MAX="${UNTRIAGED_WAKE_MAX:-25}"
# The clock is a test seam (epoch), not a knob: it is never a settings row.
NOW="${UNTRIAGED_WAKE_NOW-}"; [ -n "$NOW" ] || NOW=$(date -u +%s)
for v in AFTER LOOK MAX NOW; do
  case "${!v}" in ''|*[!0-9]*) say "could-not-run knob $v"; exit 0 ;; esac
done
SINCE=$((NOW - LOOK * 60))
SINCE_ISO=$(date -u -d "@$SINCE" '+%Y-%m-%dT%H:%M:%SZ')

W=$(mktemp -d "${TMPDIR:-/tmp}/untriaged-wake.XXXXXX") || { say "could-not-run mktemp"; exit 0; }
trap 'rm -rf "$W"' EXIT
CAND="$W/cand"; : > "$CAND"   # <rank>\t<order>\t<slug>\t<key>\t<reason>\t<dedupe>
SEEN=0; FAILS=""; NOTES=""

PROJECTS=$(ut_gh_projects) || { say "could-not-run fleet-conf"; exit 0; }
while read -r -u 3 project slug; do
  [ -n "$slug" ] || continue
  # JIRA AND LINEAR (BH-8451). Column 4 says `-` for them too, so the reads
  # below would list the code repo's GitHub issues as their tickets. Their
  # UNTRIAGED candidates come from the tracker contract, keyed by the tracker's
  # own key (CRO-12), rank 2: after every GitHub row, so a worker that still
  # refuses a string key stops the posting only once every GitHub nudge is
  # out. No closed read and no UNBLOCKED class (no Blocked-by convention there).
  trk_lane_kind "$H" "$project"
  case "$TRK_LANE_KIND" in
    jira|linear)
      if ! ut_trk_untriaged "$project" "$((AFTER * 60))" "$NOW" > "$W/trk"; then
        FAILS="$FAILS could-not-run trk@$project"; continue
      fi
      SEEN=$((SEEN + $(grep -c . "$W/trk")))
      while IFS=$'\t' read -r k _ ts _; do
        [ -n "$k" ] && [ -n "$ts" ] || continue
        c=$(date -u -d "$ts" +%s 2>/dev/null) || continue
        printf '2\t%s\t%s\t%s\tuntriaged\tuntriaged:%s\n' "$c" "$slug" "$k" "$(printf '%s' "$k" | tr '[:upper:]' '[:lower:]')"
      done < "$W/trk" >> "$CAND"
      continue ;;
  esac
  if command -v gh_repo_use_token >/dev/null 2>&1 && ! gh_repo_use_token "$slug"; then
    FAILS="$FAILS could-not-run token@$project"; continue
  fi
  if ! ut_open_issues "$slug" > "$W/open"; then
    FAILS="$FAILS could-not-run ${GH_REST_STATUS:-75}@$project"; continue
  fi
  [ "${UT_OPEN_ISSUES_CAPPED-0}" = 1 ] && NOTES="$NOTES capped@$project"
  SEEN=$((SEEN + $(jq 'length' "$W/open")))
  jq -r --argjson cut "$((NOW - AFTER * 60))" --arg s "$slug" '
    .[] | select(.comments == 0)
    | ((.created_at // "") | try fromdateiso8601 catch null) as $c
    | select($c != null and $c < $cut)
    | [0, $c, $s, .number, "untriaged", "untriaged:\(.number)"] | @tsv' "$W/open" >> "$CAND"

  # The closed read. `since` filters on updated_at, which is never before
  # closed_at, so it is a superset and closed_at is filtered here. No label:
  # a decomposed parent has lost ai-build and is still somebody's blocker.
  if ! _gh_rest_list "$slug" issues 300 'select(.pull_request == null) | {number, closed_at}' \
         -f state=closed -f "since=$SINCE_ISO" > "$W/closed"; then
    FAILS="$FAILS could-not-run ${GH_REST_STATUS:-75}@$project"; continue
  fi
  [ "$(jq 'length' "$W/closed")" -ge 300 ] && NOTES="$NOTES capped-closed@$project"
  jq -r --argjson since "$SINCE" '
    .[] | ((.closed_at // "") | try fromdateiso8601 catch null) as $c
    | select($c != null and $c >= $since) | "\(.number)\t\($c)"' "$W/closed" > "$W/closures"
  [ -s "$W/closures" ] || continue
  # The call wake-loop.sh makes on the hub, with REVDEP_TAKE=0 so the owning
  # box's state/wake-closed-<project> is never consumed from here. DEP_VERIFY=0
  # is the one difference: the soft lines are dropped below, so asking for their
  # verdict would only post a "Building this now" comment on a child nothing
  # wakes. The script's own global.env load can still turn it back on if a box
  # sets DEP_VERIFY=1 explicitly there (the template leaves it commented out).
  awk -F'\t' '{printf "board issues: CHANGED %s \"\" (state: open -> closed)\n", $1}' "$W/closures" \
    | DEP_VERIFY=0 REVDEP_TAKE=0 GH_ISSUES_REPO="$slug" "$H/bin/unblocked-children.sh" "$project" 2>/dev/null \
    > "$W/unblocked"
  # Only the two forms that say every blocker is CLOSED. The dep-verified soft
  # forms release a child whose blocker is still OPEN, and STACKABLE is a stack
  # on an open parent; neither is "its last dep closed".
  sed -nE -e 's/^board issues: UNBLOCKED ([0-9]+) .*\(Blocked-by (#[0-9, #]+) is now CLOSED .*/\1\t\2/p' \
          -e 's/^board issues: UNBLOCKED ([0-9]+) .*\(every blocker it names — (#[0-9, #]+) — is CLOSED.*/\1\t\2/p' \
    "$W/unblocked" | while IFS=$'\t' read -r child deps; do
      # lastdep = the named blocker that closed LATEST in this window; when none
      # of them is in it (the state-release form), the highest number named.
      last=$(printf '%s\n' "$deps" | grep -oE '[0-9]+' | awk -F'\t' '
        NR==FNR { at[$1]=$2; next }
        { if ($1 in at) { if (!have || at[$1] > best || (at[$1] == best && $1+0 > pick+0)) { best=at[$1]; pick=$1; have=1 } }
          if ($1+0 > hi+0) hi=$1 }
        END { print (have ? pick : hi) }' "$W/closures" -)
      printf '1\t%s\t%s\t%s\tunblocked\tunblocked:%s:%s\n' "$child" "$slug" "$child" "$child" "$last"
    done >> "$CAND"
done 3<<< "$PROJECTS"

# Untriaged first, then unblocked, oldest first; one row per (slug, key, reason).
sort -t$'\t' -k1,1n -k2,2n -k4,4n "$CAND" | awk -F'\t' '!seen[$3 FS $4 FS $5]++' > "$W/queue"
TOTAL=$(grep -c . "$W/queue")
NUDGED=0; ALREADY=0; POSTED=0
if [ "$TOTAL" -gt 0 ] && [ "$MAX" -gt 0 ]; then
  if [ -z "${HARNESS_SECRET:-}" ] || [ -z "${JOBS_URL-}" ]; then
    FAILS="$FAILS could-not-run not-configured"
  else
    while IFS=$'\t' read -r -u 4 _ _ slug key reason dedupe; do
      [ "$POSTED" -lt "$MAX" ] || break
      # A GitHub key is a number; a Jira/Linear key (CRO-12) is a string.
      ka=--argjson; case "$key" in ''|*[!0-9]*) ka=--arg ;; esac
      body=$(jq -nc --arg r "$slug" "$ka" k "$key" --arg why "$reason" --arg d "$dedupe" \
               '{repo:$r, key:$k, reason:$why, dedupe:$d}')
      # A plain call into a file, never $( ): JOBS_HTTP must survive it.
      rc=0; _jobs_req POST /api/wakes/nudge "$body" > "$W/resp" 2>/dev/null || rc=$?
      ins=""
      [ "$rc" = 0 ] && ins=$(jq -r '.inserted // empty' "$W/resp" 2>/dev/null)
      case "$rc:$ins" in
        0:1) NUDGED=$((NUDGED + 1)) ;;
        0:0) ALREADY=$((ALREADY + 1)) ;;
        0:*) FAILS="$FAILS could-not-run bad-answer"; break ;;
        *)   FAILS="$FAILS could-not-run ${JOBS_HTTP:-transport}"; break ;;
      esac
      POSTED=$((POSTED + 1))
    done 4< "$W/queue"
  fi
fi

LEFT=$((TOTAL - POSTED))
NAMES=""
if [ "$LEFT" -gt 0 ]; then
  NAMES=$(tail -n "$LEFT" "$W/queue" | awk -F'\t' 'NR<=50 {printf "%s%s%s", (NR>1?" ":""), ($4 ~ /^[0-9]+$/ ? "#" : ""), $4}
    END { if (NR > 50) printf " +%d more", NR-50 }')
  NAMES=" ($NAMES)"
fi
say "seen=$SEEN candidates=$TOTAL nudged=$NUDGED already=$ALREADY left=$LEFT$NAMES$NOTES$FAILS"
exit 0
