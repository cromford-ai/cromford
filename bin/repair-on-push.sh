#!/bin/bash
# bin/repair-on-push.sh — REPAIR ON PUSH (BH-6963, wave 1 of BH-6542). A push to
# a repo's default branch is a `push` wake row (worker/jobs core.js wakeOf,
# event `push.<before>..<after>`). Every minute this hub lane reads the push
# wakes above its own cursor, reads the paths each push changed ONCE
# (GET compare/<before>...<after>), and for every open harness PR of that repo
# (the pr_state view) whose own files intersect them, it runs the conductor's
# mc_rebase at once, under the conductor's PR lock. A PR that shares no file
# with the push is left alone: a moved head costs a re-review.
#
# THE CURSOR, NOT A CLAIM. POST /api/wakes/claim marks every row it returns as
# taken, so a wake this lane could not finish (budget spent, a read failed)
# would be gone. The lane reads GET /api/wakes?since=<cursor>&kind=push and
# keeps its own watermark in wake_cursors (box `repair-on-push`, PUT is
# MAX-monotonic). The cursor never passes a wake that is not complete. When
# every listed wake completed and the list came back under its limit, the
# cursor moves to the table's max id (read BEFORE the list), so the stale-cursor
# check (bin/doorbell-coverage-check.sh) never flags this box.
# The first tick with no cursor row plants it at max id and does nothing else.
#
# DEDUPE. Before a rebase, one GET compare/<after>...<pr head>: `ahead` or
# `identical` means the PR already contains the push, `reason=current`. So a
# wake read again after a crash or a budget cap never rebases a PR twice.
#
# REFUSES: a draft, a PR whose base is not the project's BASE_BRANCH, a PR in
# REPAIR_PUSH_SKIP_STATES (QUEUED: a push ejects it from the merge queue), a PR
# with a running detached conductor rebase, a PR whose lock the conductor
# holds, a repo no fleet project owns, a wake with no compare range.
#
# Knobs (catalog/lanes.d/repair-on-push.json, settings rows
# lane.repair-on-push.<env>): REPAIR_PUSH_BUDGET (mc_rebase calls per tick,
# default 8), REPAIR_PUSH_WAKES (push wakes read per tick, default 20),
# REPAIR_PUSH_SKIP_STATES. Off: flags/lane-off-repair-on-push, all-off,
# automerge-disabled.
#
# ONE LINE PER DECISION -> logs/repair-on-push.log:
#   REPAIR pr=<n|-> files=<k> action=rebase|skip reason=<r> repo=<slug> wake=<id>[ rc=<rc>]
# A conflict is a log line, not an alert: the conductor classes the PR
# NEEDS_REBASE and bin/blocked-resolver.sh owns it from there.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$HARNESS/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$HARNESS}/env"; }
HENV=$(harness_env_dir "$HARNESS")
LANE=repair-on-push
LOG="$HARNESS/logs/repair-on-push.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
say() { mkdir -p "$HARNESS/logs" 2>/dev/null; echo "$(STAMP) [repair-on-push] $1" >> "$LOG"; }

# shellcheck source=bin/lib/lane-gate.sh
. "$HARNESS/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit repair-on-push
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply repair-on-push
# shellcheck source=bin/jobs-client.sh
. "$HARNESS/bin/jobs-client.sh" 2>/dev/null || { say "jobs-client did not load — nothing to do"; exit 0; }
# A fleet that has stopped merging must not push branches.
command -v flag_active >/dev/null 2>&1 || { say "flag_active missing — nothing to do"; exit 0; }
flag_active automerge-disabled && exit 0
command -v jq >/dev/null 2>&1 || { say "jq missing — nothing to do"; exit 0; }
command -v gh >/dev/null 2>&1 || { say "gh missing — nothing to do"; exit 0; }

# DEDUPE, NEVER A QUEUE: a tick that finds the previous one running exits.
mkdir -p "$HARNESS/locks" 2>/dev/null
exec 8>"$HARNESS/locks/repair-on-push.lock" || exit 0
flock -n 8 || exit 0

knob() { # knob <ENV> <default> — digits only, else the default with one line
  local v=""
  command -v lane_knob >/dev/null 2>&1 && v=$(lane_knob "$LANE" "$1")
  case "$v" in ''|*[!0-9]*) [ -n "$v" ] && say "$1='$v' is not a number — using $2"; v="$2" ;; esac
  printf '%s' "$v"
}
BUDGET=$(knob REPAIR_PUSH_BUDGET 8)
NWAKES=$(knob REPAIR_PUSH_WAKES 20)
[ "$NWAKES" -ge 1 ] || NWAKES=1
SKIP_STATES=""
command -v lane_knob >/dev/null 2>&1 && SKIP_STATES=$(lane_knob "$LANE" REPAIR_PUSH_SKIP_STATES)
[ -n "$SKIP_STATES" ] || SKIP_STATES='QUEUED REBASING BLOCKED_HUMAN MERGED CLOSED ABANDONED'

# shellcheck source=bin/lib/gh-repo-token.sh
[ -r "$HARNESS/bin/lib/gh-repo-token.sh" ] && . "$HARNESS/bin/lib/gh-repo-token.sh" 2>/dev/null
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$HARNESS/bin/lib/gh-app-auth.sh" ] && . "$HARNESS/bin/lib/gh-app-auth.sh"
# shellcheck source=bin/lib/builds-of-record.sh
[ -r "$HARNESS/bin/lib/builds-of-record.sh" ] && . "$HARNESS/bin/lib/builds-of-record.sh" 2>/dev/null
# shellcheck source=bin/lib/merge-conductor-lib.sh
if [ -r "$HARNESS/bin/lib/merge-conductor-lib.sh" ]; then
  . "$HARNESS/bin/lib/merge-conductor-lib.sh" 2>/dev/null
else
  say "bin/lib/merge-conductor-lib.sh missing — nothing to do"; exit 0
fi
for f in mc_rebase mc_pr_lock; do
  type "$f" >/dev/null 2>&1 || { say "$f not available — nothing to do"; exit 0; }
done
MC_RB_DIR="${MC_RB_DIR:-$HARNESS/state/merge-conductor/rebase}"
MC_LOG="$LOG"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/repair-on-push.XXXXXX") || { say "mktemp failed — nothing to do"; exit 0; }
trap 'rm -rf "$TMP"; type mc_git_auth_clear >/dev/null 2>&1 && mc_git_auth_clear' EXIT

# The cursor. max id first, so a wake written during this tick stays above it.
MAX=$(_jobs_req GET "/api/wakes/cursor?all=1" | jq -er '.max_id | select(type == "number") | floor' 2>/dev/null)
case "$MAX" in ''|*[!0-9]*) say "worker unreachable (wake cursor) — nothing done"; exit 0 ;; esac
CUR=$(wake_cursor_get "$LANE") || { say "worker unreachable (cursor read) — nothing done"; exit 0; }
if [ -z "$CUR" ]; then
  if wake_cursor_put "$LANE" "$MAX"; then say "first tick — cursor planted at $MAX, no repair"
  else say "first tick — cursor PUT failed, retrying next tick"; fi
  exit 0
fi

if ! _jobs_req GET "/api/wakes?since=$CUR&kind=push&limit=$NWAKES" > "$TMP/wakes.json" \
   || ! jq -e '(.wakes | type) == "array"' "$TMP/wakes.json" >/dev/null 2>&1; then
  say "worker unreachable (wake list) — cursor stays at $CUR"; exit 0
fi
jq -r '.wakes[] | [(.id|tostring), (.repo // "-"), (.key // "-"), (.event // "-")] | @tsv' \
  "$TMP/wakes.json" > "$TMP/wakes.tsv" 2>/dev/null
NREAD=$(grep -c . "$TMP/wakes.tsv")
[ "$NREAD" -gt 0 ] || { [ "$MAX" -gt "$CUR" ] && wake_cursor_put "$LANE" "$MAX"; exit 0; }

# project <TAB> lower-case slug, for every fleet project.
for p in $("$HARNESS/bin/fleet-conf.sh" --projects 2>/dev/null); do
  s=$("$HARNESS/bin/fleet-conf.sh" "$p" repo 2>/dev/null)
  [ -n "$s" ] && printf '%s\t%s\n' "$p" "$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')"
done > "$TMP/projects.tsv"

base_branch() { # env/<project>.env's BASE_BRANCH, else main. Read, never sourced.
  local b
  b=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}BASE_BRANCH=//p' \
      "$HENV/$1.env" 2>/dev/null | tr -d "\"' " | tail -1)
  printf '%s\n' "${b:-main}"
}

# rebase_running <slug> <num> — a detached conductor rebase for this PR is
# running. A finished job file stays behind with status done, so the file
# alone is not the answer (bin/rebase-train-ahead.sh conductor_holds).
rebase_running() {
  local f
  for f in "$MC_RB_DIR/${1//\//_}_$2"_*.json; do
    [ -f "$f" ] || continue
    if type mc_rb_state >/dev/null 2>&1; then [ "$(mc_rb_state "$f")" = running ] && return 0
    else [ "$(jq -r '.status // ""' "$f" 2>/dev/null)" = running ] && return 0; fi
  done
  return 1
}

# gh_status <file> — the HTTP status gh printed for a failed call, else empty.
gh_status() { grep -o 'HTTP [0-9][0-9][0-9]' "$1" 2>/dev/null | head -1 | cut -c6-; }

rc_reason() {
  case "$1" in 0) echo pushed ;; 1) echo conflict ;; 2) echo gate-red ;; 3) echo lease ;;
    4) echo setup ;; 5) echo rebind-failed ;; 6) echo pool-queued ;; 7) echo pool-down ;;
    8) echo tmp-full ;; *) echo "rc-$1" ;; esac
}

USED=0; NWAKE=0; STOPPED=""; LASTDONE="$CUR"
: > "$TMP/done"
while IFS=$'\t' read -r WID REPO AFTER EVENT; do
  NWAKE=$((NWAKE+1))
  line() { say "REPAIR pr=$1 files=$2 action=$3 reason=$4 repo=$REPO wake=$WID${5:+ rc=$5}"; }
  LREPO=$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')
  P=$(awk -F'\t' -v s="$LREPO" '$2==s {print $1; exit}' "$TMP/projects.tsv")
  COMPLETE=1
  if [ -z "$P" ]; then
    line - 0 skip unowned-repo
  elif ! [[ "$EVENT" =~ ^push\.([0-9a-f]{40})\.\.([0-9a-f]{40})$ ]] || [ "${BASH_REMATCH[2]}" != "$AFTER" ]; then
    line - 0 skip no-range
  else
    B="${BASH_REMATCH[1]}"; A="${BASH_REMATCH[2]}"
    SLUG=$("$HARNESS/bin/fleet-conf.sh" "$P" repo 2>/dev/null)
    BASE=$(base_branch "$P")
    type gh_repo_use_token >/dev/null 2>&1 && gh_repo_use_token "$SLUG" >/dev/null 2>&1
    command -v gh_auth_for >/dev/null 2>&1 && { gh_auth_for "$SLUG" || true; }
    # The changed paths of the push, read once.
    if ! gh api "repos/$SLUG/compare/$B...$A" > "$TMP/compare.json" 2> "$TMP/gh.err"; then
      case "$(gh_status "$TMP/gh.err")" in
        # A sha a force push removed: nothing left to compare, the wake is done.
        404|422) line - 0 skip compare-gone; LASTDONE="$WID"; wake_cursor_put "$LANE" "$WID" >/dev/null; continue ;;
        *) say "wake=$WID compare $B...$A unreadable ($(head -c 120 "$TMP/gh.err" | tr '\n' ' ')) — tick stopped, cursor stays at $LASTDONE"
           STOPPED=1; break ;;
      esac
    fi
    jq -r '.files[]?.filename // empty' "$TMP/compare.json" | LC_ALL=C sort -u > "$TMP/merged"
    TRUNC=""; [ "$(grep -c . "$TMP/merged")" -ge 300 ] && TRUNC=" truncated=1"
    say "wake=$WID repo=$SLUG range=${B:0:8}..${A:0:8} files=$(grep -c . "$TMP/merged")$TRUNC"

    # The open harness PRs of the repo, once per tick.
    PRS="$TMP/prs.${P}"
    if [ ! -e "$PRS" ]; then
      OUT=$(pr_state_page 500 "" "$SLUG"); RC=$?
      case "$RC" in
        0) printf '%s' "$OUT" | jq -r --arg skip " $SKIP_STATES " '.rows[]
             | (.state // "-") as $s | select($skip | contains(" " + $s + " ") | not)
             | [(.number|tostring), (.state // "-")] | @tsv' 2>/dev/null | sort -n -k1,1 -u > "$PRS"
           [ "$(printf '%s' "$OUT" | jq -r '.rows | length' 2>/dev/null)" -ge 500 ] \
             && say "repo=$SLUG pr_state page is full (500 rows) — older open PRs are not read this tick" ;;
        2) : > "$PRS" ;;
        *) say "wake=$WID pr_state unreadable for $SLUG — tick stopped, cursor stays at $LASTDONE"; STOPPED=1; break ;;
      esac
    fi
    # PR number -> local build dir, from the builds of record, once per project.
    BORS="$TMP/bor.${P}"
    if [ ! -e "$BORS" ]; then
      { command -v bor_list >/dev/null 2>&1 && bor_list "$P" 2>/dev/null; } | awk -F'\t' -v s="$LREPO" '
        { u = tolower($6)
          if (match(u, /github\.com\/[^\/]+\/[^\/]+\/pull\/[0-9]+/)) {
            m = substr(u, RSTART + 11, RLENGTH - 11); n = m; sub(/.*\/pull\//, "", n); sub(/\/pull\/.*/, "", m)
            if (m == s && !(n in seen)) { seen[n] = 1; print n "\t" $2 }
          } }' > "$BORS"
    fi

    while IFS=$'\t' read -r N _ST; do
      [ -n "$N" ] || continue
      # This PR's own files: the build's changed-files.txt, else one GET.
      : > "$TMP/prfiles"
      BD=$(awk -F'\t' -v n="$N" '$1==n {print $2; exit}' "$BORS")
      if [ -n "$BD" ]; then
        LD=$(bor_local_dir "$BD" 2>/dev/null) || LD="$HARNESS/builds/$BD"
        [ -s "$LD/changed-files.txt" ] && LC_ALL=C sort -u "$LD/changed-files.txt" > "$TMP/prfiles"
      fi
      if [ ! -s "$TMP/prfiles" ]; then
        if ! gh api --paginate "repos/$SLUG/pulls/$N/files" --jq '.[].filename' > "$TMP/prfiles.raw" 2>/dev/null; then
          line "$N" 0 skip files-unreadable; COMPLETE=0; continue
        fi
        LC_ALL=C sort -u "$TMP/prfiles.raw" > "$TMP/prfiles"
      fi
      K=$(LC_ALL=C comm -12 "$TMP/prfiles" "$TMP/merged" | grep -c .)
      if [ "$K" -eq 0 ]; then line "$N" 0 skip no-overlap; continue; fi
      if grep -qx "$SLUG#$N" "$TMP/done"; then line "$N" "$K" skip done-this-tick; continue; fi
      if [ "$USED" -ge "$BUDGET" ]; then line "$N" "$K" skip budget; COMPLETE=0; continue; fi
      FACTS=$(gh api "repos/$SLUG/pulls/$N" --jq '[.state, (.draft|tostring), .base.ref, .head.ref, .head.sha, .html_url] | @tsv' 2>/dev/null)
      IFS=$'\t' read -r PST DRAFT PBASE BR HEAD URL <<< "$FACTS"
      if [ -z "${HEAD:-}" ]; then line "$N" "$K" skip pr-unreadable; COMPLETE=0; continue; fi
      if [ "$PST" != open ]; then line "$N" "$K" skip closed; continue; fi
      if [ "$DRAFT" = true ]; then line "$N" "$K" skip draft; continue; fi
      if [ "$PBASE" != "$BASE" ]; then line "$N" "$K" skip base; continue; fi
      CST=$(gh api "repos/$SLUG/compare/$A...$HEAD" --jq .status 2>/dev/null)
      case "$CST" in
        ahead|identical) line "$N" "$K" skip current; continue ;;
        behind|diverged) : ;;
        *) line "$N" "$K" skip compare-unreadable; COMPLETE=0; continue ;;
      esac
      if rebase_running "$SLUG" "$N"; then line "$N" "$K" skip rebasing; COMPLETE=0; continue; fi
      exec 9>"$(mc_pr_lock "$P" "$N")" || { line "$N" "$K" skip locked; COMPLETE=0; continue; }
      if ! flock -n 9; then exec 9>&-; line "$N" "$K" skip locked; COMPLETE=0; continue; fi
      mc_rebase "$SLUG" "$P" "$BR" "$HEAD" "$URL" > "$TMP/rebase.out" 2>/dev/null; RC=$?
      exec 9>&-
      USED=$((USED+1))
      echo "$SLUG#$N" >> "$TMP/done"
      # Every answer completes the PR for this wake, a failure included: rc 3
      # is also a HOLD, and retrying it would keep the cursor below it for as
      # long as the hold lasts. The 30-minute conductor tick is the backstop.
      line "$N" "$K" rebase "$(rc_reason "$RC")" "$RC"
    done < "$PRS"
  fi
  if [ "$COMPLETE" = 1 ]; then
    LASTDONE="$WID"; wake_cursor_put "$LANE" "$WID" >/dev/null
  else
    say "wake=$WID left for next tick (cursor stays at $LASTDONE)"; STOPPED=1; break
  fi
done < "$TMP/wakes.tsv"

if [ -z "$STOPPED" ] && [ "$NREAD" -lt "$NWAKES" ] && [ "$MAX" -gt "$LASTDONE" ]; then
  wake_cursor_put "$LANE" "$MAX" >/dev/null && LASTDONE="$MAX"
fi
say "tick wakes=$NWAKE rebased=$USED budget=$BUDGET cursor=$LASTDONE (rebased = mc_rebase calls, not successes)"
exit 0
