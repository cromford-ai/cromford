#!/bin/bash
# bin/main-red-pr-pair.sh [--explain] [owner/repo ...] — two open PRs, one cause.
#
# THE SILENCE THIS KILLS (2026-09-17). Main was red for nine hours. Every open
# PR inherited it, every lane got a "Harness CI failure" alert about its own
# branch, and each one spent its round debugging an innocent diff. The streak
# half of this signal — bin/main-red-detector.sh — needs two consecutive red
# runs on MAIN itself, which it only gets once somebody merges into a red main.
# The PRs know first: two of them failing the SAME job with the SAME first error
# is a repo-level fact hours before main's own history says so.
#
# This is a SEPARATE script from bin/main-red-detector.sh on purpose. It shares
# none of its state: its own lock, its own log, its own alert ids, and — with
# ONE narrow exception below — it writes no flags/main-red-* either. The merge
# freeze stays bound to the detector's own evidence wherever the detector HAS
# evidence, because two PRs failing alike can also be one shared flake, and a
# freeze is expensive to be wrong about.
#
# THE EXCEPTION, AND WHY IT IS NARROW (BH-1451). On 2026-09-22 main went red
# during a merge burst. The detector could not see it — every run on main was
# still in flight, so it decided NOTHING for 15+ minutes — and this lane raised
# its pair alert at 12:40Z and, writing no flag, could not stop a merge. Five
# more PRs landed on the red main. So when a pair fires AND the detector's own
# verdict file says it has no decision, this lane raises the SAME
# flags/main-red-<owner>-<repo> the merge lanes already read, marked
# `reason=pr-pair-suspected` and `owner=main-red-pr-pair`, and clears it again
# when a COMPLETE look finds no pair. It raises nothing when:
#   - state/main-red/<slug>.verdict says decision=red (already frozen) or
#     decision=green (the detector has looked, and this lane does not overrule
#     it — that is the shared-flake case this lane was built without a freeze for)
#   - the verdict file is ABSENT. Fail OPEN: a hub running an older detector, or
#     the minutes between a deploy and the next detector tick, must not be able
#     to freeze a repo on a pair alone
#   - MAIN_RED_PAIR_FREEZE=0, or the flag is already there whoever owns it
# and it clears ONLY a flag whose body says this lane raised it. A detector-owned
# or hand-written freeze outlives every tick of this lane.
#
#   a (job, first error) shared by >= 2 open PRs, runs within the window
#                        -> ONE --severity critical alert naming the job AND
#                           the first error, held open by a marker file, plus
#                           the suspected freeze above when — and only when —
#                           the detector has no verdict of its own
#   the same pair next tick -> one log line, no second send
#   the pair is gone     -> ONE --resolve on the same id, marker removed, and
#                           a suspected freeze THIS LANE raised is lifted
#   we could not look    -> (no token, PR list unreadable, not JSON, a head's
#                           runs unreadable, the grouping step failed) one log
#                           line, nothing recorded, EXISTING MARKERS LEFT ALONE
#                           and NO resolve swept this tick. "We could not look"
#                           is not "it is fixed" — and that holds for a PARTIAL
#                           look too: one head we could not read is enough to
#                           make "no pair here" an unearned claim.
#
# COST. One PR list per repo per tick. Per head sha: at most one runs read, one
# jobs read and one job-log read per tick, and NONE AT ALL once that head has a
# verdict — the verdict is written to
# state/main-red/pr-errors/<owner>-<repo>/<head>.tsv and a head sha is immutable,
# so a row that exists is terminal by construction and is never asked again.
# A head has a verdict only when EVERY required run on it has completed and the
# reads that describe the failure actually succeeded. Any of these writes
# nothing and is asked again next tick:
#   - a required run still queued or in progress (recording "did not fail" for a
#     run still in flight would blind the signal for the life of that head);
#   - the runs list, the jobs list or the job log unreadable (a 5xx or a rate
#     limit is a transient fact about GitHub, never a verdict about the head).
# Rows are pruned by age only (MAIN_RED_PAIR_LEDGER_DAYS).
# Two edges of that rule, decided on purpose:
#   - a head with NO required run at all (an empty runs list, or only SKIP_RE
#     workflows — a PR based outside main/ticket/** gets no Harness CI run) is a
#     terminal '-' once its PR has been quiet for MAIN_RED_PAIR_WINDOW_S. It can
#     be part of no pair, and left as "no verdict" it would block every resolve
#     in the repo for as long as it stayed open. Quiet for less than a window
#     it is still asked again: the run may simply not have been scheduled yet.
#   - a RE-RUN of the same run id (a flake re-run to green) flips a conclusion
#     on the same head, and this ledger does NOT see it: the failure row stands
#     for LEDGER_DAYS, and a pair it holds open resolves when its PRs merge or
#     rebase to a new head, not when somebody re-runs a job. Bounded cost (no
#     read at all for a head with a row) was chosen over that edge.
#
# Knobs (env/global.env, documented fallbacks in brackets):
#   MAIN_RED_PAIR=0 or flags/main-red-pr-pair-off   kill switch (or the `switch.main-red-pr-pair-off` settings row)
#   MAIN_RED_PAIR_REPOS    [$HARNESS_REPO]  repos this reads. The harness's own
#                          PRs are the population that inherits a red main.
#   MAIN_RED_PAIR_MAX_PRS  [15]   open PRs read per tick, newest-updated first.
#                          A cap that bites is LOGGED, never silent, and while
#                          it bites an open pair resolves only once every PR it
#                          names has left the open list (a head that was not
#                          read this tick is not a head that went green).
#   MAIN_RED_PAIR_WINDOW_S [3600] how close two PRs' runs must be to be one fact
#   MAIN_RED_PAIR_LEDGER_DAYS [14] how long a head's verdict is kept on disk
#   MAIN_RED_PAIR_FREEZE   [1]    the suspected freeze above. 0 = this lane
#                          alerts exactly as it did before BH-1451 and writes
#                          no flag; a freeze it already raised is still cleared,
#                          so the switch cannot strand one
#   MAIN_RED_ERR_RE        [(^|[^A-Za-z])(FAIL|Error|error:|fatal|No such file|
#                           unbound variable|not found|exit code [1-9])]
#                          what counts as an error line in a job log that has
#                          no ##[error] line. A log with one uses its last
#                          ##[error] (or the line before a generic "Process
#                          completed with exit code N."), and marker lines
#                          (##[...], the echoed Run step script) are never
#                          the first error (BH-5988)
#   MAIN_RED_SKIP_RE       [(e2e|nightly|smoke|publish|deploy)]  workflow names
#                          or paths that are NOT required checks
#                          (case-insensitive). bin/main-red-detector.sh reads
#                          this lane's settings row for the same knob (BH-3769)
#   HARNESS_REPO           [example-org/cromford]
#
#   --explain   print the groups this tick would alert on, and the ledger rows
#               it would record, then exit. READ-ONLY: takes no lock, writes no
#               ledger row, prunes nothing, creates no state directory, writes
#               no marker, raises and clears no freeze, sends nothing, resolves
#               nothing. An operator's dry run costs the lane nothing, so it
#               can be run next to a live tick (and a shell-local
#               MAIN_RED_ERR_RE stays in that shell).
set -uo pipefail
H="${HARNESS:-/root/harness}"

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-main-red-pr-pair
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off main-red-pr-pair.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit main-red-pr-pair
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    main-red-pr-pair
export HARNESS="$H"
EXPLAIN=0; ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --explain) EXPLAIN=1 ;;
    -h|--help) sed -n '2,110p' "$0"; exit 0 ;;
    -*) echo "main-red-pr-pair.sh: unknown flag $1" >&2; exit 2 ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done

STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
LOG="$H/logs/main-red-pr-pair.log"
# EXPLAIN CREATES NOTHING but the log dir log() writes into: locks/ is the
# lane's, and a dry run that mkdirs it has already changed the tree it was
# asked to only describe. state/main-red/ is made only where a file is written.
if [ "$EXPLAIN" = 1 ]; then mkdir -p "$H/logs" 2>/dev/null
else mkdir -p "$H/logs" "$H/locks" 2>/dev/null; fi
log() { echo "$(STAMP) $*" >> "$LOG"; [ "$EXPLAIN" = 1 ] && echo "$*"; return 0; }

# env lives in /etc/harness/env on a real box and in $H/env in a fixture tree;
# the resolver is the only thing that knows which. bin/main-red-detector.sh
# still reads $H/env directly because it predates the port and is on
# tests/env-path-allowlist.d/port-a.txt — a new script does not get that.
# shellcheck source=bin/lib/env-path.sh
. "$H/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "$H/env"; }
HENV=$(harness_env_dir)
if [ -f "$HENV/global.env" ]; then set -a
  # shellcheck disable=SC1091
  . "$HENV/global.env" 2>/dev/null; set +a; fi
# AND AGAIN, BELOW THE ENV LOAD (BH-1165 review). `set -a; . env/global.env`
# re-assigns every name it carries, so the call above lost each knob the box's
# env file also sets — the settings row was gone, the page went on reporting
# `source: settings`, and nothing errored: the exact shape this ticket exists to
# end. The call above still earns its place: the knobs this lane reads BEFORE
# this line have no other way to see a row. Applying twice is idempotent (the
# settings cache is already warm) and section 16 of tests/lanes-registry-test.sh
# is the ordering.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    main-red-pr-pair
# THE FREEZE HAS TO LEAVE THIS BOX (BH-945, and BH-1451 for this lane). Only the
# hub runs this lane, and a flag that is a local file freezes nothing: a box
# asking flag_active main-red-<slug> gets "no row" and merges straight through.
# Sourced AFTER global.env so HARNESS_SECRET is in scope, guarded and fail-open
# exactly as bin/main-red-detector.sh does it — a tree with no client publishes
# nothing and behaves as it did.
# shellcheck source=/dev/null
[ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh"
# The verdict, the head ledger and the pair marks are rows (BH-4156). Without
# the lib mrs_on says "no DB here" and today's files stay the record.
# shellcheck source=bin/lib/main-red-state.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/main-red-state.sh" 2>/dev/null || mrs_on() { return 1; }
[ "${MAIN_RED_PAIR:-1}" = 0 ] && exit 0
command -v lane_switch >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/lib/lane-switch.sh" 2>/dev/null || lane_switch() { [ -e "${HARNESS:-${H:-/root/harness}}/flags/$1" ]; }
lane_switch main-red-pr-pair-off file && exit 0
command -v gh >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# BH-4080: HARNESS_REPO's default lives in the deployment defaults home.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$(dirname "${BASH_SOURCE[0]}")/lib/deployment.sh}" || exit 0
ERR_RE="${MAIN_RED_ERR_RE:-(^|[^A-Za-z])(FAIL|Error|error:|fatal|No such file|unbound variable|not found|exit code [1-9])}"
SKIP_RE="${MAIN_RED_SKIP_RE:-(e2e|nightly|smoke|publish|deploy)}"
PAIR_MAX="${MAIN_RED_PAIR_MAX_PRS:-15}";       case "$PAIR_MAX"    in ''|*[!0-9]*) PAIR_MAX=15 ;; esac
PAIR_WINDOW="${MAIN_RED_PAIR_WINDOW_S:-3600}"; case "$PAIR_WINDOW" in ''|*[!0-9]*) PAIR_WINDOW=3600 ;; esac
LEDGER_DAYS="${MAIN_RED_PAIR_LEDGER_DAYS:-14}"; case "$LEDGER_DAYS" in ''|*[!0-9]*) LEDGER_DAYS=14 ;; esac
PAIR_FREEZE="${MAIN_RED_PAIR_FREEZE:-1}"   # only the literal 0 disarms, as MAIN_RED_PAIR
# THE WAY OUT NAMES THE REAL LABEL (BH-1985). The alert below tells an operator
# to land the fix as a PR carrying the main-red label, and the merge lanes
# exempt whatever bin/lib/main-red-label.sh resolves, so the text reads the same
# resolver once here. The lib is in the same bin/ tree this script syncs with
# (it landed on main before this read did), so without it the default is the
# honest answer. Not an env read: a bare ${X:-} here would make this lane look
# like it owns a knob the lib owns (tests/lanes-registry-test.sh section 7).
if [ -r "$(dirname "${BASH_SOURCE[0]}")/lib/main-red-label.sh" ]; then
  # shellcheck source=bin/lib/main-red-label.sh
  . "$(dirname "${BASH_SOURCE[0]}")/lib/main-red-label.sh"
  main_red_label_prime "$H"
  MRP_LABEL=$(main_red_label_resolve "$H")
else
  MRP_LABEL=fix-main-red
fi

if [ "${#ARGS[@]}" -gt 0 ]; then
  REPOS=$(printf '%s\n' "${ARGS[@]}")
else
  REPOS=$(printf '%s\n' ${MAIN_RED_PAIR_REPOS:-$HARNESS_REPO})
fi

# DEDUPE, NEVER A QUEUE: two overlapping ticks would both see the same pair and
# both send. Its OWN lock — sharing the detector's would make each lane able to
# silence the other. Held means somebody is already doing this work, so say so
# and leave.
# --explain SENDS NOTHING, so it has nothing to dedupe against: taking the lock
# made a dry run and the */10 tick silence each other in whichever order they
# arrived, and opening it truncated the file the running tick was holding.
if [ "$EXPLAIN" != 1 ] && command -v flock >/dev/null 2>&1; then
  exec 8>"$H/locks/main-red-pr-pair.lock"
  flock -n 8 || { log "another main-red-pr-pair tick holds the lock — skipping this one"; exit 0; }
fi

# shellcheck source=bin/lib/gh-repo-token.sh
[ -r "$H/bin/lib/gh-repo-token.sh" ] && . "$H/bin/lib/gh-repo-token.sh" 2>/dev/null
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$H/bin/lib/gh-app-auth.sh" ] && . "$H/bin/lib/gh-app-auth.sh"
# shellcheck source=bin/lib/gh-pr-list.sh
for _P in "$(dirname "$0")/lib/gh-pr-list.sh" "$H/bin/lib/gh-pr-list.sh"; do
  [ -r "$_P" ] && { . "$_P" 2>/dev/null; break; }
done

# The FIRST error line of one job's log. "Harness CI is red" sends a reader to a
# four-job run page; "tests/lib/scratch.sh: No such file" tells them in the
# alert itself whether it is their diff. Timestamps are stripped, whitespace
# collapsed, 200 chars kept.
#
# WHAT IS READ (BH-5988). The runner's own lines decide first:
#   - the LAST ##[error] line wins. A continue-on-error step writes one and the
#     job goes on, so the first one can name a step that did not fail the job;
#     in a fail-fast job the last one is the step that did.
#   - a generic "##[error]Process completed with exit code N." reads as the line
#     before it in the same step (the step's own last word), or as
#     "Run <step>: Process completed ..." when that step printed nothing.
#   - any other ##[error] (an ::error:: annotation) is read as written.
#   - ERR_RE applies only to a log with no ##[error] line at all.
# Marker lines are NEVER the first error: ##[group], ##[endgroup], ##[notice],
# ##[warning] and the rest are skipped, and so is everything inside a
# "##[group]Run ..." block (the echoed step script, shell:, env:, with:).
# Before this, at 2026-10-11 01:11:01Z, #5978 and #5987 both read
# "##[group]Run FAIL=0" (the header of the "bash -n every script" step) and
# paged a false "main is probably red" while main was green.
#
# The two failure modes are DIFFERENT facts and get different exit codes, because
# one is terminal and the other is not:
#   rc 1  we could not read the log (5xx, rate limit, gh too old). Says nothing
#         about the head — the caller writes no row and asks again next tick.
#   rc 2  the log read fine and nothing in it is error-shaped. An immutable log
#         will not grow an error line later, so that IS a verdict: the caller
#         records "(unavailable)", which groups with nothing.
first_error_of_job() { # first_error_of_job <owner/repo> <job-id>
  local slug="$1" jid="${2:-}" tmp out
  [ -n "$jid" ] || return 1
  tmp=$(mktemp "${TMPDIR:-/tmp}/main-red-joblog.XXXXXX") || return 1
  # --allow-escape-sequences OR NOTHING EVER GROUPS. Actions job logs are full
  # of ANSI colour, and gh refuses to write a response containing terminal
  # escapes to a non-tty without this flag ("the response contains terminal
  # escape sequences"). Without it every real read failed, every first error
  # read "(unavailable)", and "(unavailable)" is the one value that groups with
  # nothing — a lane that could never fire. Verified against a real failing job
  # on 2026-09-18. The bare retry is for a gh too old to know the flag.
  if ! gh api --allow-escape-sequences "repos/$slug/actions/jobs/$jid/logs" > "$tmp" 2>/dev/null; then
    gh api "repos/$slug/actions/jobs/$jid/logs" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; } # escape-flag-exempt: bare retry for a gh too old to know the flag (the flagged read on the line above failed)
  fi
  head -c 2000000 "$tmp" > "$tmp.b" 2>/dev/null
  out=$(awk -v re="$ERR_RE" '
    BEGIN { ESC = sprintf("%c", 27) }
    { line = $0
      sub(/\r$/, "", line)
      gsub(ESC "\\[[0-9;]*[a-zA-Z]", "", line)    # the colour the flag let through
      gsub(/[\001-\010\013\014\016-\037\177]/, "", line)
      sub(/^[0-9-]+T[0-9:.]+Z[ \t]*/, "", line)
      if (index(line, "##[group]Run ") == 1) { inrun = 1; step = substr(line, 14); prev = ""; next }
      if (index(line, "##[endgroup]") == 1) { inrun = 0; next }
      if (index(line, "##[group]") == 1) next
      if (inrun) next                             # the echoed script, shell:, env:, with:
      if (index(line, "##[error]") == 1) {
        msg = substr(line, 10); sub(/^[ \t]+/, "", msg)
        if (msg ~ /^Process completed with exit code [0-9]+\.?$/)
          msg = (prev != "") ? prev : "Run " step ": " msg
        last = msg; next }
      if (index(line, "##[") == 1) next           # notice, warning, debug, command
      if (line ~ /^[ \t]*$/) next
      prev = line
      if (first == "" && line ~ re) first = line }
    END { out = (last != "") ? last : first
          if (out == "") exit
          gsub(/[\t ]+/, " ", out); sub(/^ /, "", out); print substr(out, 1, 200) }' "$tmp.b" 2>/dev/null)
  rm -f "$tmp" "$tmp.b"
  [ -n "$out" ] || return 2
  printf '%s\n' "$out"
}

# mrp_row_stale <row-file> — rc 0 when column 2 (the first error) starts "##[".
mrp_row_stale() { awk -F'\t' 'NR==1 { exit !(index($2, "##[") == 1) } END { if (NR==0) exit 1 }' "$1" 2>/dev/null; }

# What ONE open PR's head failed on, as "job \t first error \t run created_at".
# "-" in every column means the head's required workflows FINISHED and none of
# them failed.
#
# rc 1 = THERE IS NO VERDICT YET, and nothing is recorded, so the next tick asks
# again. Three ways to get there, and all three used to be written to the ledger
# as if they were answers:
#   - a required run is still queued or in progress. "Some run finished and it
#     was green" is not "the head is green": the one still running is exactly the
#     one that can go red, and the row would never be revisited (head shas are
#     immutable, so the ledger never asks twice).
#   - the runs list or the jobs list could not be read.
#   - the failing job's log could not be read (rc 1 from first_error_of_job; rc 2
#     means it read fine and held no error line, which IS terminal).
# A transient 5xx or a rate limit must cost one tick, never the life of a head.
#
# The one exception is a head with NO required run at all: pending 0 AND done 0.
# That is permanent for a PR based outside main/ticket/** (harness-ci.yml never
# runs on it), so "no verdict" would mean one runs read per tick for the life
# of the PR and unknown>0 on every tick — no marker in the repo could resolve
# while it stayed open. Once the PR has been quiet for PAIR_WINDOW seconds it
# is terminal '-' (it groups with nothing); younger than that it is asked again,
# because the run may simply not have been scheduled yet.
pr_head_error() { # pr_head_error <owner/repo> <head-sha> <pr-updated-at>
  local slug="$1" head="$2" updated="${3:-}" runs pending_n done_n worst rid rtime jobline job jid err frc upd_s
  runs=$(gh api -X GET "repos/$slug/actions/runs" -f head_sha="$head" -f per_page=20 \
    -q '[.workflow_runs[]? | {n:.name, p:.path, s:.status, c:.conclusion, t:.created_at, u:.html_url, id:.id}]' 2>/dev/null) \
    || return 1
  [ -n "$runs" ] || return 1
  pending_n=$(jq -r --arg re "$SKIP_RE" '
      [ .[]? | select(.s!="completed")
             | select((((.n // "") | test($re; "i")) or ((.p // "") | test($re; "i"))) | not) ] | length' <<<"$runs" 2>/dev/null) \
    || return 1
  [ "${pending_n:-0}" -eq 0 ] || return 1
  done_n=$(jq -r --arg re "$SKIP_RE" '
      [ .[]? | select(.s=="completed")
             | select((((.n // "") | test($re; "i")) or ((.p // "") | test($re; "i"))) | not) ] | length' <<<"$runs" 2>/dev/null) \
    || return 1
  if [ "${done_n:-0}" -eq 0 ]; then
    [ -n "$updated" ] || return 1
    upd_s=$(date -u -d "$updated" +%s 2>/dev/null) || return 1
    [ $(( $(date -u +%s) - upd_s )) -gt "$PAIR_WINDOW" ] || return 1
    printf '%s\t%s\t%s\n' "-" "-" "-"; return 0
  fi
  worst=$(jq -r --arg re "$SKIP_RE" '
      [ .[]? | select(.s=="completed")
             | select(.c=="failure" or .c=="timed_out" or .c=="startup_failure")
             | select((((.n // "") | test($re; "i")) or ((.p // "") | test($re; "i"))) | not) ]
      | sort_by(.t // "") | reverse | .[0] // empty | "\(.id)\t\(.t)"' <<<"$runs" 2>/dev/null) || return 1
  if [ -z "$worst" ]; then printf '%s\t%s\t%s\n' "-" "-" "-"; return 0; fi
  IFS=$'\t' read -r rid rtime <<<"$worst"
  jobline=$(gh api "repos/$slug/actions/runs/$rid/jobs" \
    -q '[.jobs[]? | select(.conclusion=="failure") | "\(.name)\t\(.id)"][0] // ""' 2>/dev/null) || return 1
  IFS=$'\t' read -r job jid <<<"$jobline"
  # The read SUCCEEDED and named no failing job: a run that failed without one
  # (startup failure, every job cancelled). Terminal — it groups with nothing,
  # but it is an answer, so it is recorded and never paid for twice.
  [ -n "$job" ] || { printf '%s\t%s\t%s\n' "(no failing job)" "(unavailable)" "$rtime"; return 0; }
  err=$(first_error_of_job "$slug" "$jid"); frc=$?
  case "$frc" in
    0) ;;
    2) err="(unavailable)" ;;
    *) return 1 ;;
  esac
  printf '%s\t%s\t%s\n' "$job" "$err" "$rtime"
}

# mrp_publish <flag-basename> on|off <why> — the pause_flags row every OTHER box
# reads, written after the file and never before it (bin/main-red-detector.sh's
# rule at mr_publish): the hub is correct even if the PUT dies. The `.published`
# marker is the detector's, on purpose — its own green tick republishes OFF for
# a clear whose PUT died, and that self-heal covers a freeze raised here too.
# The marker is the ledgers row main_red_published/<name> (BH-4156), with the
# detector's file fallback (bin/main-red-detector.sh mr_mark) where the row
# cannot be written.
mrp_publish() {
  local n="$1" onoff="$2" mark="$H/state/main-red/$1.published" rc=2
  command -v flag_set >/dev/null 2>&1 || return 0
  if flag_set "$n" "$onoff" "${3:-}" >/dev/null 2>&1; then
    if mrs_on; then mrs_published_set "$n" "$onoff"; rc=$?; fi
    if [ "$rc" = 0 ]; then rm -f "$mark"; return 0; fi
    [ "$rc" = 2 ] || log "$n: published marker row not written — state/main-red/$n.published holds it until a write lands"
    if [ "$onoff" = on ]; then mkdir -p "$H/state/main-red" 2>/dev/null; : > "$mark"; else rm -f "$mark"; fi
    return 0
  fi
  log "$n: could not be published to the coordination DB — the hub file is authoritative, boxes see it on the next successful publish"
  return 1
}

# mrp_suspect_freeze <slug> <dashed> <job> <err> <prs> — the BH-1451 exception,
# called once per repo per tick and only when a group actually fired. Sets
# MRP_FROZE=1 when a freeze is in force for this repo when it returns, which is
# what lets the alert text say so without claiming a freeze that does not exist.
# Order is FILE -> ROW -> (the caller's) ALERT, so no alert can describe a
# freeze that was never raised.
MRP_FROZE=0
mrp_suspect_freeze() {
  local slug="$1" dashed="$2" job="$3" err="$4" prs="$5" flag verdict dec vrow vrc
  MRP_FROZE=0
  flag="$H/flags/main-red-$dashed"
  if [ "$PAIR_FREEZE" = 0 ]; then
    log "$slug: MAIN_RED_PAIR_FREEZE=0 — this pair alerts and freezes nothing"
    return 0
  fi
  if [ -f "$flag" ]; then
    MRP_FROZE=1
    log "$slug: flags/main-red-$dashed is already up — merges are held, nothing rewritten here"
    return 0
  fi
  # The verdict is the main_red_verdicts row (BH-4156). The file decides only
  # where there is no row store (no DB here, or a worker that answers 404
  # because it predates the route). An unreadable row is not a decision.
  vrc=2
  if mrs_on; then vrow=$(mrs_verdict_get "$slug"); vrc=$?; fi
  case "$vrc" in
    0) dec=$(cut -f1 <<<"$vrow") ;;
    3) log "$slug: bin/main-red-detector.sh has never looked at this repo — there is no verdict row to read, and an absent verdict is not a decision, so this pair alerts and freezes nothing"
       return 0 ;;
    2) verdict="$H/state/main-red/$dashed.verdict"
       if [ ! -f "$verdict" ]; then
         log "$slug: bin/main-red-detector.sh has never looked at this repo here — there is no $dashed.verdict to read, and an absent verdict is not a decision, so this pair alerts and freezes nothing"
         return 0
       fi
       dec=$(sed -n 's/^decision=//p' "$verdict" | head -1) ;;
    *) log "$slug: the detector's verdict row is unreadable — an unreadable verdict is not a decision, so this pair alerts and freezes nothing"
       return 0 ;;
  esac
  if [ "$dec" != none ]; then
    log "$slug: the detector's own verdict is decision=${dec:-(unset)} — it HAS looked, so this pair alerts and freezes nothing"
    return 0
  fi
  mkdir -p "$H/flags" 2>/dev/null
  # reason= FIRST: bin/merge-conductor.sh logs only `head -c 200` of this body,
  # and the field that says why merges are frozen has to survive that cut.
  { echo "reason=pr-pair-suspected"; echo "owner=main-red-pr-pair"; echo "job=$job";
    echo "first_error=$err"; echo "prs=$prs"; echo "since=$(STAMP)"; echo "detected=$(STAMP)"; } > "$flag"
  MRP_FROZE=1
  mrp_publish "main-red-$dashed" on "$prs fail \"$job\" alike and bin/main-red-detector.sh has no verdict"
  log "$slug: FREEZE main-red-$dashed raised (reason=pr-pair-suspected, job=\"$job\", prs=$prs) — every merge lane holds until it is gone"
}

# mrp_resolve_freeze <slug> <dashed> — lift ONLY what this lane raised, and only
# on a tick that saw no pair at all. `owner=` is what makes that decidable: a
# detector-owned or hand-written freeze is never touched here.
mrp_resolve_freeze() {
  local slug="$1" dashed="$2" flag="$H/flags/main-red-$dashed"
  [ -f "$flag" ] || return 0
  grep -q '^owner=main-red-pr-pair$' "$flag" 2>/dev/null || return 0
  rm -f "$flag"
  mrp_publish "main-red-$dashed" off "no open PR pair shares a failure any more"
  log "$slug: FREEZE main-red-$dashed cleared — this lane raised it and no pair fires now"
}

pr_pair_signal() { # pr_pair_signal <owner/repo>
  local slug="$1" dashed ledger marks wledger list n rows num head upd f rowfile groups grc
  local hash cnt prs job err text id marker seen unknown=0 capped=0 still froze=0
  local rowmode=0 scratch="" krc h j e ra pmode=file ptmp="" prc mprs
  type harness_pr_list >/dev/null 2>&1 || {
    log "$slug: bin/lib/gh-pr-list.sh is not readable — no PR-pair signal this tick"; return 0; }
  if command -v gh_repo_use_token >/dev/null 2>&1; then
    gh_repo_use_token "$slug" || { log "$slug: no token can see this repo — no PR-pair signal this tick"; return 0; }
  fi
  # After the PAT probe on purpose, exactly as bin/main-red-detector.sh does it
  # (#425): armed, the App token wins; unarmed, the probe's export stands. Every
  # gh read below this line is App-authenticated where the App is configured,
  # which is what tests/gh-app-ratchet-test.sh counts.
  command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$slug" || true
  dashed=$(echo "$slug" | tr '/' '-')
  ledger="$H/state/main-red/pr-errors/$dashed"; marks="$H/state/main-red/pairs/$dashed"
  list=$(harness_pr_list "$slug" open number,headRefOid,updatedAt 100 2>/dev/null) \
    || { log "$slug: open PR list unreadable — no PR-pair signal this tick"; return 0; }
  n=$(jq 'length' <<<"$list" 2>/dev/null) \
    || { log "$slug: open PR list unreadable (not JSON) — no PR-pair signal this tick"; return 0; }
  # THE HEAD LEDGER IS ROWS (BH-4156): main_red_pr_errors, one read for every
  # head this tick looks at. The rows are laid out as today's <head>.tsv files
  # in a scratch dir that dies with the tick, so the loop below reads them the
  # way it read the ledger dir, and each fresh verdict is PUT as a row. With no
  # row store (no DB here, or a worker that answers 404) the ledger dir is the
  # record, as before. An unreadable read is "we could not look": no signal.
  if mrs_on; then
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/main-red-rows.XXXXXX") || {
      log "$slug: no scratch dir for the head rows — no PR-pair signal this tick"; return 0; }
    # shellcheck disable=SC2046 # one word per head sha; a sha holds no space
    mrs_pr_errors_get "$slug" "$scratch/known.tsv" $(jq -r --argjson cap "$PAIR_MAX" \
      'sort_by(.updatedAt // "") | reverse | .[0:$cap][] | .headRefOid // empty' <<<"$list" 2>/dev/null)
    krc=$?
    case "$krc" in
      0) rowmode=1; mkdir -p "$scratch/ledger"
         while IFS=$'\t' read -r h j e ra; do
           [[ "$h" =~ ^[A-Za-z0-9._-]+$ ]] && printf '%s\t%s\t%s\n' "$j" "$e" "$ra" > "$scratch/ledger/$h.tsv"
         done < "$scratch/known.tsv"
         ledger="$scratch/ledger" ;;
      2) rm -rf "$scratch"; scratch="" ;;
      *) rm -rf "$scratch"
         log "$slug: the PR head rows are unreadable — no PR-pair signal this tick"; return 0 ;;
    esac
  fi
  # A ROW IS TERMINAL FOR $LEDGER_DAYS and the cron lane trusts it, so explain
  # writes its fresh verdicts to a scratch dir that dies with the process and
  # prunes nothing. Rows that already exist are READ, so the explain output is
  # what the lane would actually say.
  wledger="$ledger"
  if [ "$EXPLAIN" = 1 ]; then
    wledger=$(mktemp -d "${TMPDIR:-/tmp}/main-red-explain.XXXXXX") || {
      [ -n "$scratch" ] && rm -rf "$scratch"
      log "$slug: no scratch dir for --explain — no PR-pair signal this tick"; return 0; }
  elif [ "$rowmode" = 1 ]; then
    mrs_pr_errors_prune "$slug" "$LEDGER_DAYS" || log "$slug: the head rows older than $LEDGER_DAYS day(s) were not pruned this tick"
    # The file ledger this replaced: each file in the ledger window becomes its
    # row before it goes, so a head whose run logs expired keeps its verdict.
    # The route is write-once, so a re-run imports nothing twice. A file whose
    # PUT failed stays for the next tick.
    for f in "$H/state/main-red/pr-errors/$dashed"/*.tsv; do
      [ -f "$f" ] || continue
      h="${f##*/}"; h="${h%.tsv}"
      if [ -s "$f" ] && [[ "$h" =~ ^[A-Za-z0-9._-]+$ ]] && [ ! -e "$scratch/ledger/$h.tsv" ] \
         && ! mrp_row_stale "$f" && [ -z "$(find "$f" -mtime +"$LEDGER_DAYS" 2>/dev/null)" ]; then
        IFS=$'\t' read -r j e ra < "$f"
        if ! mrs_pr_error_put "$slug" "$h" "$j" "$e" "$ra"; then
          log "$slug: the legacy head file for ${h:0:8} was not imported as a row — it is kept for the next tick"
          continue
        fi
        cp "$f" "$scratch/ledger/$h.tsv"
      fi
      rm -f "$f"
    done
    rmdir "$H/state/main-red/pr-errors/$dashed" "$H/state/main-red/pr-errors" 2>/dev/null
  else
    mkdir -p "$ledger" 2>/dev/null
    find "$ledger" -type f -name '*.tsv' -mtime +"$LEDGER_DAYS" -delete 2>/dev/null
  fi
  # ZERO OPEN PRs IS AN ANSWER, not a missing one — the unreadable cases already
  # returned above with a log line. Falling straight through to the resolve
  # sweep with no groups is what closes an alert whose last PR merged; an early
  # return here would leave that marker open until somebody opened a PR again.
  [ "$n" -gt "$PAIR_MAX" ] && { capped=1; log "$slug: $n open PRs — capped at the $PAIR_MAX most recently updated for the PR-pair signal, the rest are not read this tick"; }
  rowfile=$(mktemp "${TMPDIR:-/tmp}/main-red-pairs.XXXXXX") || {
    [ "$wledger" = "$ledger" ] || rm -rf "$wledger"; [ -n "$scratch" ] && rm -rf "$scratch"; return 0; }
  if [ "${n:-0}" -gt 0 ]; then
    rows=$(jq -r --argjson cap "$PAIR_MAX" 'sort_by(.updatedAt // "") | reverse | .[0:$cap][]
                                            | "\(.number)\t\(.headRefOid // "")\t\(.updatedAt // "")"' <<<"$list" 2>/dev/null)
    while IFS=$'\t' read -r num head upd; do
      [ -n "$head" ] || continue
      f="$ledger/$head.tsv"
      # A ROW THE OLD PARSER WROTE IS NOT A VERDICT (BH-5988). Before this
      # ticket the first error could be a log marker line ("##[group]Run
      # FAIL=0"), and that row grouped every failure of its job. The new parser
      # never returns a line that starts with "##[", so such a row is asked
      # again once, and the fresh row replaces it.
      if [ ! -s "$f" ] || mrp_row_stale "$f"; then
        f="$wledger/$head.tsv"
        pr_head_error "$slug" "$head" "$upd" > "$f" || rm -f "$f"
        [ "$EXPLAIN" = 1 ] && [ -s "$f" ] && echo "WOULD RECORD $slug $head :: $(cat "$f")"
        if [ "$rowmode" = 1 ] && [ "$EXPLAIN" != 1 ] && [ -s "$f" ]; then
          IFS=$'\t' read -r j e ra < "$f"
          mrs_pr_error_put "$slug" "$head" "$j" "$e" "$ra" \
            || log "$slug: the row for head ${head:0:8} was not written — that head is read again next tick"
        fi
      fi
      # A head with no verdict is not a head with no failure. Count it: the
      # resolve sweep below may not claim "the shared cause is gone" on a look
      # that did not cover every open PR.
      if [ -s "$f" ]; then printf '%s\t%s\n' "$num" "$(cat "$f")" >> "$rowfile"
      else unknown=$((unknown + 1)); fi
    done <<<"$rows"
  fi
  groups=$(python3 - "$PAIR_WINDOW" "$rowfile" <<'PYEOF' 2>/dev/null
import hashlib, sys
from datetime import datetime, timezone
window = int(sys.argv[1])
def epoch(s):
    # GitHub stamps are UTC and the Z says so. strptime alone builds a NAIVE
    # datetime, and .timestamp() then reads it as LOCAL time — on a hub with a
    # DST-observing TZ two runs straddling the transition land an hour apart and
    # the window throws a real pair away.
    try: return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except Exception: return None
by = {}
for line in open(sys.argv[2]):
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 4: continue
    num, job, err, when = parts[0], parts[1], parts[2], parts[3]
    # "-" is a finished, green head. "(unavailable)" is a log that held no error
    # line. Neither is an error two PRs can be said to SHARE.
    if job in ("-", "(no failing job)") or err in ("-", "(unavailable)"): continue
    t = epoch(when)
    if t is None: continue
    by.setdefault((job, err), {})[num] = t
for (job, err), prs in sorted(by.items()):
    if len(prs) < 2: continue
    # The window is a CLUSTER test, not a spread test. Asking whether the
    # oldest and newest run in the whole group are within the window throws the
    # signal away the moment one stale PR shares the failure: on 2026-09-18
    # three open PRs failed the same job with the same first error, two of them
    # eighteen seconds apart, and a twelve-hour-old third made the group read as
    # unrelated. Widest run of PRs that fits inside one window, >= 2 of them.
    items = sorted(prs.items(), key=lambda kv: kv[1])
    best, i = [], 0
    for j in range(len(items)):
        while items[j][1] - items[i][1] > window:
            i += 1
        if j - i + 1 > len(best):
            best = items[i:j + 1]
    if len(best) < 2: continue
    h = hashlib.sha1(("%s|%s" % (job, err)).encode("utf-8")).hexdigest()[:12]
    nums = ", ".join("#" + n for n in sorted((n for n, _ in best),
                                             key=lambda k: int(k) if k.isdigit() else 0))
    print("\t".join([h, str(len(best)), nums, job, err]))
PYEOF
)
  grc=$?
  rm -f "$rowfile"
  [ "$wledger" = "$ledger" ] || rm -rf "$wledger"
  [ -n "$scratch" ] && rm -rf "$scratch"
  if [ "$grc" -ne 0 ]; then
    log "$slug: the grouping step failed (python3 exit $grc) — no PR-pair verdict this tick, open pairs left alone"
    groups=""; unknown=$((unknown + 1))
  fi
  # THE PAIR MARKS ARE ROWS (BH-4156): main_red_pairs, one open row per pair.
  # The open rows are read once here. With no row store the marker files under
  # pairs/<owner>-<repo>/ are the record, as before. An unreadable read (or a
  # truncated one) is "we could not look": no send, no freeze, no resolve.
  if [ "$EXPLAIN" != 1 ]; then
    ptmp=$(mktemp -d "${TMPDIR:-/tmp}/main-red-open.XXXXXX") || {
      log "$slug: no scratch dir for the pair rows — no pair alert this tick"; return 0; }
    prc=2
    if mrs_on; then mrs_pairs_open "$slug" "$ptmp/open.tsv"; prc=$?; fi
    case "$prc" in
      0) pmode=row
         # A marker file from before the rows is opened as its row, then removed.
         for marker in "$marks"/*; do
           [ -f "$marker" ] || continue
           hash=$(basename "$marker")
           awk -F'\t' -v h="$hash" '$1==h {f=1} END {exit !f}' "$ptmp/open.tsv" && { rm -f "$marker"; continue; }
           if mrs_pair_open "$slug" "$hash" "$(sed -n 's/^job=//p' "$marker" | head -1)" \
                "$(sed -n 's/^first_error=//p' "$marker" | head -1)" "$(sed -n 's/^prs=//p' "$marker" | head -1)" </dev/null; then
             rm -f "$marker"
           fi
         done
         rmdir "$marks" "$H/state/main-red/pairs" 2>/dev/null
         mrs_pairs_open "$slug" "$ptmp/open.tsv" || {
           rm -rf "$ptmp"; log "$slug: the open pair rows are unreadable — no pair alert, freeze or resolve this tick"; return 0; } ;;
      2) mkdir -p "$marks" 2>/dev/null ;;
      *) rm -rf "$ptmp"
         log "$slug: the open pair rows are unreadable — no pair alert, freeze or resolve this tick"; return 0 ;;
    esac
  fi
  seen=" "
  while IFS=$'\t' read -r hash cnt prs job err; do
    [ -n "$hash" ] || continue
    seen="$seen$hash "
    marker="$marks/$hash"
    id="main-red-prs:$dashed:$hash"
    text="$slug: $cnt open PRs ($prs) fail job \"$job\" with the same first error — main is probably red, so check the shared cause before debugging either diff. first error: \"$err\""
    if [ "$EXPLAIN" = 1 ]; then echo "WOULD ALERT $id :: $text"; continue; fi
    # THE FREEZE BEFORE THE ALERT THAT DESCRIBES IT (BH-1451). Once per repo per
    # tick, on the FIRST group — it is the repo that is frozen, not the group —
    # and before any send, so the sentence below can only claim a freeze that is
    # already on disk. A tick whose pair is still open from last tick raises
    # nothing new and still tells the truth: the flag is there.
    if [ "$froze" = 0 ]; then mrp_suspect_freeze "$slug" "$dashed" "$job" "$err" "$prs"; froze=1; fi
    [ "$MRP_FROZE" = 1 ] && text="$text Merges for $slug are held while flags/main-red-$dashed exists — land the fix as a PR labelled $MRP_LABEL."
    if { [ "$pmode" = row ] && awk -F'\t' -v h="$hash" '$1==h {f=1} END {exit !f}' "$ptmp/open.tsv"; } \
       || { [ "$pmode" = file ] && [ -f "$marker" ]; }; then
      log "$slug: $cnt open PRs ($prs) still fail \"$job\" the same way — alert $id already open, no second send"
      continue
    fi
    # Marker BEFORE the send would let a send that never happened read as one
    # that did. Send first: lane-alert.sh dedupes on --id in state/alerts/, so a
    # marker that fails to write costs one suppressed repeat, not a lost page.
    "$H/bin/lane-alert.sh" --severity critical --id "$id" main-red "$text" >/dev/null 2>&1
    if [ "$pmode" = row ]; then
      mrs_pair_open "$slug" "$hash" "$job" "$err" "$prs" </dev/null \
        || log "$slug: the row for pair $hash was not written — the next tick sends again, and lane-alert.sh dedupes on --id"
    else
      { echo "job=$job"; echo "first_error=$err"; echo "prs=$prs"; echo "detected=$(STAMP)"; } > "$marker"
    fi
    log "ALERT(pair) $text"
  done <<<"$groups"
  [ "$EXPLAIN" = 1 ] && return 0
  # A RESOLVE IS A CLAIM — "the shared cause is gone" — and only a complete look
  # earns it. The unreadable-PR-list case already returned above, but a list that
  # loaded while a head's runs came back 5xx (or while a rebased head's runs are
  # still in flight) leaves that PR out of the grouping, and the group it was
  # holding open would read as gone. Then the next tick reads fine and pages a
  # SECOND time on the same condition. Skip the sweep; the marker costs nothing
  # standing, and a real fix resolves on the next complete tick.
  if [ "$unknown" -gt 0 ]; then
    log "$slug: $unknown open PR head(s) have no verdict this tick (runs still in flight, or a read that failed) — open pairs left alone rather than called fixed"
    rm -rf "$ptmp"; return 0
  fi
  # AND THE FREEZE COMES DOWN ON THE SAME EVIDENCE AS A RESOLVE (BH-1451): a
  # COMPLETE look that found no pair at all. While the cap bites the look is
  # partial by construction — heads past it were never read — so a freeze waits
  # for a tick that saw every open PR, exactly as the marker sweep below does.
  if [ "$seen" = " " ] && [ "$capped" != 1 ]; then mrp_resolve_freeze "$slug" "$dashed"; fi
  # One "hash<TAB>job<TAB>prs" line per open pair, from the rows or the files.
  if [ "$pmode" = row ]; then cut -f1,2,4 "$ptmp/open.tsv" > "$ptmp/sweep.tsv"
  else
    for marker in "$marks"/*; do
      [ -f "$marker" ] || continue
      printf '%s\t%s\t%s\n' "$(basename "$marker")" "$(sed -n 's/^job=//p' "$marker" | head -1)" \
        "$(sed -n 's/^prs=//p' "$marker" | head -1)"
    done > "$ptmp/sweep.tsv"
  fi
  while IFS=$'\t' read -r -u 3 hash job mprs; do
    [ -n "$hash" ] || continue
    case "$seen" in *" $hash "*) continue ;; esac
    # THE CAP IS A PARTIAL LOOK TOO. Heads past it were never read, so a pair
    # whose PRs merely fell out of the newest-$PAIR_MAX window (any other PR
    # getting updated pushes them out) is absent from the grouping without
    # having gone green — and would page a second time when they drift back
    # in. While the cap bites, resolve only a marker whose PRs have ALL left
    # the open list (the full list is in hand, up to 100); otherwise say so.
    if [ "$capped" = 1 ]; then
      still=""
      for num in $(tr -d '#,' <<<"$mprs"); do
        jq -e --argjson n "$num" 'any(.[]?; .number==$n)' <<<"$list" >/dev/null 2>&1 && still="$still #$num"
      done
      if [ -n "$still" ]; then
        log "$slug: pair $hash (\"$job\") left open — the cap left$still unread this tick, and unread is not green"
        continue
      fi
    fi
    "$H/bin/lane-alert.sh" --resolve --id "main-red-prs:$dashed:$hash" main-red \
      "$slug: no open PR still fails \"$job\" with that first error — the shared cause is gone." >/dev/null 2>&1
    if [ "$pmode" = row ]; then
      mrs_pair_resolve "$slug" "$hash" \
        || log "$slug: the row for pair $hash was not stamped resolved — the next tick resolves it again"
    else
      rm -f "$marks/$hash"
    fi
    log "ALERT(pair-resolve) $slug: \"$job\" no longer shared by two open PRs"
  done 3< "$ptmp/sweep.tsv"
  rm -rf "$ptmp"
}

for SLUG in $REPOS; do
  [ -n "$SLUG" ] && [ "$SLUG" != "-" ] || continue
  # >>> project hold
  # IS THIS REPO'S PROJECT HELD (BH-1465)? The loop walks repository slugs, so
  # the fleet project has to be resolved first — one local fleet.conf read, no
  # GitHub call — and a slug no project claims runs unchanged, because "we could
  # not tell" is never read as "it is held". The check sits above
  # pr_pair_signal, which is where this lane's gh calls start.
  P=$("$H/bin/project-of.sh" --repo "$SLUG" 2>/dev/null || true)
  if [ -n "$P" ] \
     && command -v lane_project_held >/dev/null 2>&1 && lane_project_held main-red-pr-pair "$P"; then
    log "$SLUG ($P) held: flags/$LANE_HELD_FLAG is set — no PR pair was read for it this tick"
    continue
  fi
  # <<< project hold
  pr_pair_signal "$SLUG"
  command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
done
command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
exit 0
