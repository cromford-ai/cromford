#!/bin/bash
# bin/pr-url-reconcile.sh — RE-LINK A BUILD RECORD TO THE PR IT ACTUALLY OPENED,
# AND PAGE WHEN THERE IS NONE. Hub cron lane, every 10 minutes at :03 — three
# minutes ahead of bin/merge-sweep.sh's tick, so a record relinked here enters the
# sweep's very next walk.
#
# THE DEFECT (BH-848, 2026-09-18). `gh pr create` is GraphQL, the pool's App
# installation token's GraphQL budget is chronically exhausted, and a build whose
# create died writes `PR_CREATE_FAILED` as line 1 of its RESULT. The PR gets
# opened moments later by another path — but bin/merge-sweep.sh:443 and
# bin/pipeline-health.sh walk ONLY records whose line 1 reads `PR_CREATED
# https://`, so nothing on the hub ever re-links the record. Ten CI-green,
# VERDICT: APPROVE cromford PRs were invisible to the sweep in one day and
# the only symptom was that merges had flatlined. Nobody was told.
#
# WHAT IT DOES, per record whose line 1 is PR_CREATE_FAILED (or BH-765's spelling
# of the same failed create, `RESULT_MALFORMED PR_CREATED …`) and which has no PR
# of its own: resolve the OPEN PR on the branch THE BUILD ITSELF NAMED over REST
# (a different budget from the create that failed), and
#   200 + a PR   -> line 1 becomes `PR_CREATED <url> | RECONCILED …`, the original
#                   line is kept as `RECONCILED_FROM:`, one `PR: <url>` line is
#                   appended, and a terminal marker stops the record being asked
#                   about again.
#   200 + []     -> nothing is written. If the record's review says APPROVE, the
#                   branch is read ONCE MORE with state=all before anything is
#                   said: a PR that was opened by hand and has since MERGED owes
#                   nothing, and telling an operator to "open it by hand" would
#                   be wrong advice about a PR that is already in main. Merged ->
#                   one log line. Closed unmerged, or no PR at all -> ONE ALERTS
#                   line naming the command that fixes it, in its own words.
#   anything else-> UNKNOWN. No write, no alert, one log line. A 403 is not "no
#                   PR" — that conflation is what BH-709 cost.
#
# THE STATE=ALL READ IS THE SECOND READ, NEVER THE FIRST. `.[0]` of a state=all
# list can be a closed PR, and linking a record to a closed PR is the mislink
# this lane exists to prevent. The link decision is made on state=open only.
#
# WHY LINE 1 IS REWRITTEN AND NOT JUST APPENDED TO. The ticket asks for `PR:
# <url>` appended, and appending alone would leave the sweep exactly as blind as
# the issue describes, because the sweep never reads past line 1. So line 1 is
# rewritten to the shape every reader already understands and the original is
# preserved verbatim one line down — nothing is lost and nothing has to change in
# the sweep.
#
# WHAT IT NEVER DOES: touch a record whose line 1 already says `PR_CREATED` (a
# correct link is never overwritten), or rewrite a `PR:` line that disagrees with
# the branch — that one gets its own alert and a human.
#
# THE BRANCH COMES FROM THE RECORD, NOT FROM ITS NAME (review round 2). A rebuild
# runs on `ticket/<key>-rN` (bin/run-build.sh's taken-name bump, and
# bin/blocked-resolver.sh after it closes the stale PR on the stem) while the
# build dir carries no suffix. Deriving `ticket/<key>` from the dir name would ask
# about the STEM for an r2 record: stem PR still open -> the r2 record gets linked
# to the r1 PR (the mislink this lane exists to kill); stem PR closed by the
# resolver -> `[]`, then an alert telling a human to open a PR on the wrong branch
# while the r2's real open PR is never linked. So the branch is read from the
# record's own pipeline.log — every pool record ships it (fly/builder-runner.sh
# `# >>> result assemble`, bin/fly-results-ingest.sh pulls it) and
# bin/run-build.sh writes `pr create failed and no open PR exists on <BRANCH>:`
# into it — and the stem is the fallback only when the record carries no
# branch of its own. A branch read off the log is accepted only when it IS this
# key's stem or `<stem>-rN`; a parent's `STACKED on ticket/…` name never is.
#
# TERMINAL MARKERS, so a settled record stops costing REST reads every tick:
#   .pr-url-reconciled           linked (or its PR is MERGED — nothing owed, and
#                                nothing about a merged PR can change)
#   .pr-url-reconcile-mislinked  `PR:` disagrees with the branch; a human edit is
#                                the only exit, and removing the marker re-arms it
#   .pr-url-reconcile-alerted    "APPROVE, no PR" was paged ONCE. Deliberately NOT
#                                terminal: a PR opened by hand later must link,
#                                and one opened by hand and MERGED still gets the
#                                state=all read, which seals the record with
#                                .pr-url-reconciled instead of costing a read a tick
#   .pr-url-reconcile-mislink-alerted
#                                the mislink page's OWN memory. Not terminal, and
#                                not shared with the line above, so a record paged
#                                for a missing PR still gets paged for a mislink.
# A BLOCK-verdict record with no PR stays re-readable too: a resolver fix round
# can open its PR later, and that PR must link.
#
# A RECORD THAT ALREADY CARRIES THE RIGHT `PR:` LINE STILL NEEDS LINE 1. A hand
# backfill (and an older reading of this lane) appended `PR: <url>` and left line
# 1 saying the create failed — and the sweep never reads past line 1, so that
# record is exactly as invisible as an unlinked one. It takes the same rewrite;
# the `PR:` line is already there and is not appended twice.
#
# ORDER OF SIDE EFFECTS: write, THEN mark. A crash between them re-links the same
# url next tick (idempotent); a marker without a link would be a silent loss. The
# ALERTS line is written before its marker for the same reason.
#
# KNOBS (env/global.env, flag-file twins — docs/verification-map/settings-knobs.md):
#   PR_URL_RECONCILE=0 | flags/pr-url-reconcile-off   the lane does nothing
#     The switch is the settings row switch.<name>.<box> or switch.<name> for
#     <name> = pr-url-reconcile-off (1 = off), read by lane_switch in
#     bin/lib/lane-switch.sh; the flag file decides only when neither row exists.
#   PR_URL_RECONCILE_MAX                              records asked about per tick (50)
#   PR_URL_RECONCILE_DEADLINE_SECS                    wall-clock budget per tick (240)
#   PR_URL_RECONCILE_DISPATCH_SPREAD_SECS             --dispatch start window (120)
# Both caps report what they did NOT get to (`unwalked=`), never drop it silently.
#
# RUN MODES (BH-6894, docs/notes/2026-10-15-BH-6894-pr-url-reconcile-per-project.md):
#   (no flag)      the fleet run: every project's records, one process, an
#                  exclusive locks/pr-url-reconcile.lock. Today's run.
#   --project <p>  only <p>'s records (builds/<p>-*, pool-<p>-*, fly-<p>-*).
#                  Lock locks/pr-url-reconcile-<p>.lock (the runner's, when
#                  bin/project-lane-run.sh started it), plus a SHARED lock on
#                  locks/pr-url-reconcile.lock, so a fleet run and a project
#                  run never overlap. The caps count per project run. The
#                  summary line ends ` project=<p>`.
#   --dispatch     pl_dispatch (bin/lib/project-lanes.sh): one `--project <p>`
#                  run per project, on the hub or as lane_runs rows when
#                  lane_placement.pr-url-reconcile is fly. Takes no lock.
set -uo pipefail
# BH-6894: argv first, before anything is sourced.
PUR_DISPATCH=""; PUR_PROJECT=""; PUR_PROJECT_SET=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dispatch) PUR_DISPATCH=1; shift ;;
    --project) PUR_PROJECT="${2:-}"; PUR_PROJECT_SET=1; shift 2 || shift ;;
    --project=*) PUR_PROJECT="${1#--project=}"; PUR_PROJECT_SET=1; shift ;;
    *) shift ;;
  esac
done
if [ -n "$PUR_DISPATCH" ] && [ -n "$PUR_PROJECT_SET" ]; then
  echo "pr-url-reconcile: --dispatch and --project are exclusive" >&2
  exit 2
fi
HARNESS="${HARNESS:-/root/harness}"
# The env dir is RESOLVED, never spelled (tests/env-path-test.sh): on a pool
# machine it is a tmpfs, on a box /etc/harness/env, and $HARNESS/env is a compat
# symlink for one release.
# shellcheck source=bin/lib/env-path.sh
. "$HARNESS/bin/lib/env-path.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }
HENV=$(harness_env_dir "$HARNESS")
# shellcheck disable=SC1091
set -a; . "$HENV/global.env" 2>/dev/null; set +a

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-pr-url-reconcile
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off pr-url-reconcile.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
# The ONE verdict reader (bin/lib/verdict-parse.sh, BH-1625). Missing, every
# verdict reads unknown — never APPROVE.
. "${HARNESS:-/root/harness}/bin/lib/verdict-parse.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/verdict-parse.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit pr-url-reconcile
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    pr-url-reconcile

LOG="$HARNESS/logs/pr-url-reconcile.log"
ALERTS="$HARNESS/logs/ALERTS.log"
mkdir -p "$HARNESS/logs" "$HARNESS/locks" 2>/dev/null

# shellcheck source=lib/lane-switch.sh
. "$(dirname "$0")/lib/lane-switch.sh" || exit 1
lane_switch pr-url-reconcile-off && exit 0
[ "${PR_URL_RECONCILE:-1}" = 0 ] && exit 0

# ONE clock read for the whole tick.
NOW=$(date -u +%s)
NOW_ISO=$(date -u -d "@$NOW" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ')
STAMP() { date -u -d "@$NOW" '+%Y-%m-%d %H:%M:%SZ' 2>/dev/null || printf '%s' "$NOW_ISO"; }
say() { printf '%s [pr-url-reconcile] %s\n' "$(STAMP)" "$*" >> "$LOG"; }

# >>> run mode (BH-6894)
# The per-project runner (pl_dispatch, pl_lock_take) needs $H.
H="$HARNESS"
if [ -r "$HARNESS/bin/lib/project-lanes.sh" ]; then # shellcheck source=bin/lib/project-lanes.sh
  . "$HARNESS/bin/lib/project-lanes.sh"; fi
PUR_MODE=fleet
if [ -n "$PUR_PROJECT_SET" ]; then
  case "$PUR_PROJECT" in
    ''|.*|*[!A-Za-z0-9._-]*) PUR_NOTP=1 ;;
    *) case $'\n'"$("$HARNESS/bin/fleet-conf.sh" --projects 2>/dev/null)"$'\n' in
         *$'\n'"$PUR_PROJECT"$'\n'*) PUR_NOTP=0 ;;
         *) PUR_NOTP=1 ;;
       esac ;;
  esac
  if [ "$PUR_NOTP" = 1 ]; then
    say "--project '$PUR_PROJECT' is not a project in fleet.conf — no run"
    exit 2
  fi
  # bin/project-lane-run.sh already holds the project lock on PL_LOCK_FD. A
  # run started by hand takes the same lock, so the two never overlap.
  if [ "${PL_LANE:-}" = pr-url-reconcile ] && [ "${PL_PROJECT:-}" = "$PUR_PROJECT" ] \
     && [ -n "${PL_LOCK_FD:-}" ] && { : >&"$PL_LOCK_FD"; } 2>/dev/null; then
    :
  elif command -v pl_lock_take >/dev/null 2>&1; then
    pl_lock_take pr-url-reconcile "$PUR_PROJECT" 9 || {
      say "a run of $PUR_PROJECT is still live (locks/pr-url-reconcile-$PUR_PROJECT.lock held) — exiting"; exit 0; }
  else
    exec 9>"$HARNESS/locks/pr-url-reconcile-$PUR_PROJECT.lock"
    flock -n 9 || {
      say "a run of $PUR_PROJECT is still live (locks/pr-url-reconcile-$PUR_PROJECT.lock held) — exiting"; exit 0; }
  fi
  # SHARED on fd 8, never fd 9: fd 9 is the runner's project lock, and
  # `exec 9>` would release it. A fleet run holds this file exclusive.
  exec 8>"$HARNESS/locks/pr-url-reconcile.lock"
  flock -s -n 8 || {
    say "project $PUR_PROJECT: a fleet run holds locks/pr-url-reconcile.lock — exiting"; exit 0; }
  PUR_MODE=project
elif [ -n "$PUR_DISPATCH" ]; then
  PUR_SPREAD="${PR_URL_RECONCILE_DISPATCH_SPREAD_SECS:-120}"
  case "$PUR_SPREAD" in
    ''|*[!0-9]*) say "PR_URL_RECONCILE_DISPATCH_SPREAD_SECS='$PUR_SPREAD' is not a whole number — using 120"
       PUR_SPREAD=120 ;;
  esac
  if command -v pl_dispatch >/dev/null 2>&1; then
    # No lock here: a dispatcher holding the fleet lock would make every
    # project run that starts at offset 0 skip.
    say "$(pl_dispatch pr-url-reconcile "$PUR_SPREAD" "$HARNESS/bin/pr-url-reconcile.sh" --project)"
    exit 0
  fi
  say "project-lanes.sh not loaded — this tick walks every project in one process"
fi
if [ "$PUR_MODE" = fleet ]; then
  # DEDUPE, NEVER A QUEUE: if a tick is still running, this one has nothing to add.
  exec 9>"$HARNESS/locks/pr-url-reconcile.lock"
  flock -n 9 || exit 0
fi
# <<< run mode

# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$HARNESS/bin/lib/gh-app-auth.sh" ] && . "$HARNESS/bin/lib/gh-app-auth.sh"   # per-repo App token (#425)
# shellcheck source=bin/lib/gh-pr-create.sh
[ -r "$HARNESS/bin/lib/gh-pr-create.sh" ] && . "$HARNESS/bin/lib/gh-pr-create.sh" # gh_pr_rest_read: status before body
# shellcheck source=bin/lib/result-pr-url.sh
[ -r "$HARNESS/bin/lib/result-pr-url.sh" ] && . "$HARNESS/bin/lib/result-pr-url.sh"
# THE LEDGER HALF OF THE LINK (BH-858), guarded the way every other lib here is:
# a box whose harness sync has not landed the client does exactly what it did
# before — re-links the record and stops there.
# shellcheck source=bin/jobs-client.sh
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"
command -v gh_pr_rest_read >/dev/null 2>&1 || {
  say "bin/lib/gh-pr-create.sh is missing — this lane cannot read GitHub over REST and did nothing"; exit 0; }
command -v jq >/dev/null 2>&1 || { say "jq is missing — nothing walked"; exit 0; }

MAX="${PR_URL_RECONCILE_MAX:-50}"
DEADLINE="${PR_URL_RECONCILE_DEADLINE_SECS:-240}"

# gh's own stderr lands in a file this lane can quote, not /dev/null: an auth or
# network failure used to log only `HTTP none`, which says nothing about why.
# gh never prints a token on stderr; what THIS read wrote rides the UNKNOWN log line.
#
# ONLY THE BYTES THIS READ WROTE (review round 3). The file is append-only and
# shared by every record and every tick, so `tail -n 1` quotes whatever failure
# happened last — including some other record's, when the read that just failed
# wrote nothing at all. A misattributed reason is worse than a bare `HTTP none`.
# Same idiom as bin/run-build.sh's `# >>> pr create call`: mark the end, read
# forward from it.
export _GPC_STDERR="$HARNESS/logs/pr-url-reconcile.stderr.log"
stderr_at() { # the current end of the stderr log, in bytes
  local n; n=$(wc -c < "$_GPC_STDERR" 2>/dev/null | tr -d ' '); printf '%s' "${n:-0}"
}
stderr_since() { # stderr_since <byte offset> -> the last line written after it
  tail -c "+$(( ${1:-0} + 1 ))" "$_GPC_STDERR" 2>/dev/null | tr -d '\r' | tr '\t' ' ' \
    | grep -v '^[[:space:]]*$' | tail -n 1 | cut -c1-200
}

# The project buckets come from the REGISTRY, longest name first, so a record
# named cromford-console-… never buckets as cromford (the sweep_order
# rule in bin/merge-sweep.sh).
PROJECTS=$("$HARNESS/bin/fleet-conf.sh" --projects 2>/dev/null \
  | awk 'NF {print length($0) "\t" $0}' | sort -k1,1nr -k2,2 | cut -f2- | tr '\n' ' ')

project_of() { # project_of <record dirname> -> the project, or nothing
  local b="${1#pool-}" p
  b="${b#fly-}"
  for p in $PROJECTS; do
    case "$b" in "$p-"*) printf '%s\n' "$p"; return 0 ;; esac
  done
  return 1
}
key_of() { # key_of <record dirname> <project> -> BH-800
  local b="${1#pool-}"
  b="${b#fly-}"; b="${b#"$2"-}"
  printf '%s\n' "$(sed -E 's/-[0-9]{12,}$//' <<<"$b")"
}
branch_of() { # branch_of <record dir> <key> [project] -> the branch this build pushed
  # >>> branch from the job row (BH-1033; tests/ready-queue-rows-test.sh drives this)
  # THE BUILD WROTE THIS DOWN. bin/run-build.sh records the branch it is about
  # to push as a `branch` artifact on its own job row, at the moment it settles
  # the name — before the push, before the PR, before anything can go wrong.
  # Everything below this block is a SCRAPE of a log the build happened to
  # leave, and a scrape that misses does not fail: it silently returns the STEM,
  # and this lane then asks GitHub about `ticket/bh-800` when the build actually
  # pushed `ticket/bh-800-r2` — a different branch, someone else's PR, and a
  # record relinked to it (the mislinked-PR risk this slice closes).
  #
  # The row is asked FIRST and the scrape is left exactly as it is: no row, an
  # outage, or a build that predates the artifact all fall through to it, which
  # is today's behaviour byte for byte.
  local d="$1" stem b proj="${3:-}" job rc
  stem="ticket/$(tr '[:upper:]' '[:lower:]' <<<"$2")"
  if command -v job_for_record >/dev/null 2>&1 && command -v job_artifacts >/dev/null 2>&1; then
    job=$(job_for_record "$proj" "$(basename "$d")" 2>/dev/null); rc=$?
    if [ "$rc" = 0 ] && [ -n "$job" ]; then
      b=$(job_artifacts "$job" 2>/dev/null | awk -F'\t' '$1=="branch" && $2!="" {print $2; exit}')
      # ONLY A BRANCH THIS LANE WOULD HAVE GUESSED ANYWAY. A row carrying
      # something that is not a ticket branch is not a licence to go ask GitHub
      # about an arbitrary ref — it falls through to the scrape.
      case "$b" in
        ticket/*) printf '%s\n' "$b"; return 0 ;;
      esac
    fi
  fi
  # <<< branch from the job row
  b=$(sed -nE 's/.* pr create failed and no open PR exists on ([^ :]+):.*/\1/p' "$d/pipeline.log" 2>/dev/null | tail -n 1)
  [ -n "$b" ] || b=$(grep -oE "(^|[^A-Za-z0-9/_.-])$stem(-r[0-9]+)?([^A-Za-z0-9_.-]|$)" "$d/pipeline.log" 2>/dev/null \
                    | grep -oE "$stem(-r[0-9]+)?" | tail -n 1)
  case "$b" in "$stem"|"$stem"-r[0-9]*) printf '%s\n' "$b"; return 0 ;; esac
  printf '%s\n' "$stem"; return 1   # rc 1 = no branch of its own on record, the caller says so
}
slug_of() { # slug_of <project> -> owner/repo, or nothing
  local p="$1" s
  s=$("$HARNESS/bin/fleet-conf.sh" "$p" repo 2>/dev/null || true)
  [ -n "$s" ] && [ "$s" != "-" ] && { printf '%s\n' "$s"; return 0; }
  s=$(git -C "/root/repos/$p" remote get-url origin 2>/dev/null \
      | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
  [ -n "$s" ] && { printf '%s\n' "$s"; return 0; }
  return 1
}
verdict_of() { # verdict_of <record dir> -> APPROVE | BLOCK | (nothing)
  # ANCHORED, in the final block, through the one shared reader
  # (bin/lib/verdict-parse.sh, BH-1625). A findings paragraph that quotes
  # `VERDICT: APPROVE` is not a judgement. This is the same read
  # bin/review-rescue.sh's backfill makes, and the two have to agree —
  # verdict_handoff predicts what the backfill will do. Unknown prints nothing.
  local v
  v=$(verdict_parse -L "$1/review.md" 2>/dev/null) || return 0
  printf '%s\n' "$v"
}
alert() { # alert <record dir> <akey> <line> [dedupe marker]
  # THE DEDUPE MARKER IS AN ARGUMENT (review round 3). .pr-url-reconcile-alerted
  # is the "we already paged about this record's MISSING PR" flag, and every
  # family that hangs off it silences every other one: a record paged once for
  # "APPROVE, no PR" was then immune to the mislink page, which is a page a
  # terminal marker was about to seal in for good. A family that needs its own
  # memory names its own file.
  local d="$1" akey="$2" line="$3" mark="${4:-.pr-url-reconcile-alerted}"
  printf '%s %s\n' "$(STAMP)" "$line" >> "$ALERTS"
  touch "$d/$mark"
  [ -x "$HARNESS/bin/beat.sh" ] && "$HARNESS/bin/beat.sh" \
    "$(jq -nc --arg akey "$akey" --arg l "$line" \
       '{kind:"fleet_alert",project:"fleet",akey:$akey,line:$l}')" >/dev/null 2>&1 || true
}

# WRITE, THEN MARK. tmp + mv so a reader never sees half a record; the marker is
# touched only after the rewrite landed, because a marker without a link is a
# record made terminal and invisible in the same breath.
relink() { # relink <record dir> <original line 1> <url> <append-a-PR-line 0|1> [extra line]; rc 1 = nothing written
  local d="$1" l1="$2" url="$3" addpr="$4" extra="${5:-}" tmp="$1/RESULT.reconcile.$$"
  {
    printf 'PR_CREATED %s | RECONCILED %s by pr-url-reconcile: the create had failed on the builder\n' "$url" "$NOW_ISO"
    tail -n +2 "$d/RESULT"
    if [ -n "$extra" ]; then printf '%s\n' "$extra"; fi
    printf 'RECONCILED_FROM: %s\n' "$l1"
    if [ "$addpr" = 1 ]; then printf 'PR: %s\n' "$url"; fi
  } > "$tmp" && mv "$tmp" "$d/RESULT" || { rm -f "$tmp"; return 1; }
  touch "$d/.pr-url-reconciled"
  return 0
}

# --- THE LEDGER'S HALF OF THE LINK (BH-858) -----------------------------------
# Re-linking the RECORD makes the build visible to bin/merge-sweep.sh, which
# reads files. It does nothing for the lanes that ask the LEDGER:
# `/api/verdict?pr=` resolves through the `pr_url` artifact, and a build whose
# create died never wrote one. So the PR is invisible to the conductor and the
# merge queue, and the verdict its reviewer wrote is bound to no PR anybody can
# look up.
#
# After the relink, for that record: bind `pr_url` on the job that wrote it, then
# ask whether that job owns a verdict at all. It does -> nothing more is owed
# (a provisional row counts: bin/review-rescue.sh's backfill settles those, and
# handing it to re-review would buy a Fable read for a judgement the ledger
# already holds). It does not -> RECORD the hand-off and let the conductor's
# existing HEAD_MOVED path buy the review under its own budget, daily cap,
# CI-green debounce and per-(PR, head) dedupe. THIS LANE SPAWNS NOTHING: a
# metered review bought from a cron lane with none of those five guards is how a
# dedupe-before-spend rule turns into a bill.
#
# THE PAGE IS THE LAST RESORT, AND IT HAS TO BE TRUE. "This PR owes a verdict and
# nothing can produce one" is only said when nothing can: never about a PR that
# has since merged or closed, and never about a record whose own review.md ends
# APPROVE with a job row to hang it on, because bin/review-rescue.sh's backfill
# settles exactly that shape at tier 2 on its next tick.
#
# ORDER: relink, then ledger, then log or alert, then MARK. Any rc 1 stops BEFORE
# the marker, so the record stays owed and the next tick retries it — an outage
# is not "no verdict" (D11), and a marker without the work is a record lost in
# silence.
conductor_armed() {
  # The same read the conductor's own mc_rereview_allowed makes at the decision
  # point (bin/lib/merge-conductor-lib.sh), so this lane can never claim a
  # hand-off the conductor would refuse.
  [ -e "$HARNESS/flags/merge-conductor-actions" ] || return 1
  [ "${MC_REREVIEW_ON_MOVE:-1}" != 0 ] || return 1
}
# A DIFFERENT MARKER from alert()'s. .pr-url-reconcile-alerted is the "we already
# paged about this record's missing PR" flag; reusing it here would silence the
# mislink page, or be silenced by it.
valert() { # valert <record dir> <line>
  printf '%s %s\n' "$(STAMP)" "$2" >> "$ALERTS"
  [ -x "$HARNESS/bin/beat.sh" ] && "$HARNESS/bin/beat.sh" \
    "$(jq -nc --arg akey "prurlreconcile:verdict:$(basename "$1")" --arg l "$2" \
       '{kind:"fleet_alert",project:"fleet",akey:$akey,line:$l}')" >/dev/null 2>&1 || true
}
# ONE REST read, and ONLY on the path that is about to page. The first-tick path
# reads state=open before it links anything, so only a record relinked on an
# EARLIER tick can be sitting on a PR that has since merged or been closed by
# hand — and "this PR owes a verdict" is the wrong thing to say about a PR that
# is already in main. An outage answers rc 1 here: UNKNOWN is never "finished".
pr_finished() { # pr_finished <project> <pr url> -> rc 0 only if GitHub says merged/closed
  local proj="$1" url="$2" slug num out code st
  num="${url##*/}"
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  slug=$(slug_of "$proj") || return 1
  command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$slug" || true
  out=$(gh_pr_rest_read "repos/$slug/pulls/$num")
  code=$(head -n 1 <<<"$out")
  [ "$code" = 200 ] || return 1
  st=$(jq -r 'if type == "object" then (if .merged_at then "merged" else (.state // "") end) else "" end' \
       2>/dev/null <<<"$(tail -n +2 <<<"$out")")
  [ "$st" = merged ] || [ "$st" = closed ]
}
verdict_handoff() { # verdict_handoff <record dir> <project> <key> <branch> <url> <relinked-earlier 0|1>
  local d="$1" proj="$2" key="$3" branch="$4" url="$5" recon="${6:-0}" bd job state rc
  bd=$(basename "$d")
  [ -f "$d/.verdict-handoff-done" ] && return 0
  command -v job_for_record >/dev/null 2>&1 || return 0
  job=$(job_for_record "$proj" "$bd"); rc=$?
  if [ "$rc" = 1 ]; then
    say "$bd: the ledger did not answer which job wrote this record — nothing marked, the next tick retries"
    return 0
  fi
  state=""
  if [ -n "$job" ]; then
    job_artifact_put pr_url "$url" \
      "$(jq -nc --arg r "$bd" --arg b "$branch" '{record:$r,branch:$b,source:"pr-url-reconcile"}')" \
      "$job" >/dev/null 2>&1 \
      || { say "$bd: could not bind pr_url $url on job $job — nothing marked, the next tick retries"; return 0; }
    state=$(job_verdict_state "$job"); rc=$?
    if [ "$rc" = 1 ]; then
      say "$bd: pr_url $url bound to job $job, but the ledger would not say whether it owns a verdict — nothing marked, the next tick retries"
      return 0
    fi
    [ "$rc" = 0 ] || state=""
  fi
  # No job row, or a job with no verdict artifact, both mean the same thing here:
  # nobody has a judgement bound to this PR.
  if [ -n "$state" ]; then
    say "$bd: job $job already carries a verdict for $url (${state%%	*}) — nothing more owed"
  elif [ "$recon" = 1 ] && pr_finished "$proj" "$url"; then
    say "$bd: $url is merged or closed — no verdict is owed on it, nothing handed off and nothing paged"
  elif conductor_armed; then
    say "$bd: $url (job ${job:-none}, branch $branch) carries no verdict — handed to the merge conductor's head-bound re-review path"
  elif [ -n "$job" ] && [ "$(verdict_of "$d")" = APPROVE ]; then
    # NOT A PAGE. The conductor is unarmed, but this record's own review.md ends
    # in a real APPROVE and a job row owns it, which is exactly the shape
    # bin/review-rescue.sh's verdict_backfill settles at tier 2 on its next tick.
    # "Nothing can produce one" would be a false sentence about a record that
    # carries a judgement, and a page nobody needs to act on.
    say "$bd: $url (job $job) carries no ledger verdict and the conductor is not armed — review.md ends APPROVE, so bin/review-rescue.sh's backfill settles it; not paged"
  else
    valert "$d" "[pr-url-reconcile] $proj/$key: $url owes a verdict and nothing can produce one — the merge conductor is not armed (flags/merge-conductor-actions absent, or MC_REREVIEW_ON_MOVE=0), so no lane will re-review it. Record $bd, job ${job:-none}, branch $branch. Arm the conductor, or review the PR by hand."
    ALERTED=$((ALERTED+1))
  fi
  touch "$d/.verdict-handoff-done"
}

# The base the fix command needs: a stacked child's base is its PARENT's branch,
# not main, and an operator who pastes `--base main` onto a stacked head opens a
# PR carrying the parent's commits. Line 1 is where the stack note lives.
base_of() { # base_of <RESULT line 1> -> the base branch
  local b
  b=$(sed -nE 's#.*STACKED on ([^ )]+).*#\1#p' <<<"${1:-}" | head -n 1)
  printf '%s\n' "${b:-main}"
}

# --- A STACKED CHILD WHOSE PARENT MERGED AND TOOK ITS BASE WITH IT (BH-1904) --
# TK-3128: the record said `STACKED on <parent branch>`, no PR existed on the
# child branch, and the page above told a human to `gh pr create --base <parent
# branch>`. The parent had merged and its branch was deleted, so that base did
# not exist any more. The human rebased the child onto main and opened the PR by
# hand (project-5 #3298). This arm does that step instead, and only in exactly
# that shape: the parent PR is MERGED and its branch answers an explicit 404.
#
#   rc 0 linked: rebased `--onto <base> <parent's pre-merge head>`, pushed with a
#        lease, the PR opened against the project base, the record re-linked
#   rc 1 given up and paged ONCE (conflict, parent rewritten, 3 failed tries),
#        or given up on an earlier tick. No other page is sent
#   rc 2 not this arm's case: the caller pages exactly as before
#   rc 3 UNKNOWN or not done this tick (a failed read, a refused lease, a failed
#        create under the 3-try ceiling). One log line, nothing paged
#
# The git work is #1670's mc_restack, called and never re-implemented. It is
# gated on the conductor's own switch (conductor_armed), because the pushed head
# needs the conductor's moved-head rebind or re-review before it can merge.
#
# MARKERS, one per record:
#   .pr-url-reconcile-restacked      the sha this arm pushed. Written BEFORE the
#                                    create, so a failed create retries only the
#                                    create: a second rebase of an already
#                                    rebased branch would answer rc 6, a false page
#   .pr-url-reconcile-restack-tries  failed tries so far; the 3rd pages and stops
#   .pr-url-reconcile-restack-gaveup terminal for this arm, and the page's dedupe
# A crash between the push and the first marker is covered by the compare reads
# in step 5: a child already sitting on the base is not rebased a second time.
restack_try() { # restack_try <record dir> <what failed> <page text>; rc 1 = paged and gave up, rc 3 = next tick
  local d="$1" why="$2" page="$3" n
  n=$(cat "$d/.pr-url-reconcile-restack-tries" 2>/dev/null); case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$((n+1)); printf '%s\n' "$n" > "$d/.pr-url-reconcile-restack-tries"
  if [ "$n" -lt 3 ]; then
    say "$(basename "$d"): restack try $n of 3 did not finish: $why. Retried next tick, nothing paged"
    return 3
  fi
  alert "$d" "prurlreconcile:restack:$(basename "$d")" "$page (last: $why)" .pr-url-reconcile-restack-gaveup
  ALERTED=$((ALERTED+1))
  say "$(basename "$d"): restack failed 3 times ($why). Alerted and given up"
  return 1
}
restack_orphan() { # restack_orphan <record dir> <project> <key> <slug> <branch> <RESULT line 1>
  local d="$1" proj="$2" key="$3" slug="$4" br="$5" l1="$6"
  local bd pbr purl pn base out code body merged href phead chead new st behind rc m libok title bf url why mk tjob
  bd=$(basename "$d"); mk="$d/.pr-url-reconcile-restacked"
  # 1. Stacked, with a parent PR this record can name. Anything else pages as before.
  case "$l1" in *"STACKED on "*) ;; *) return 2 ;; esac
  pbr=$(base_of "$l1")
  command -v result_parent_pr_url >/dev/null 2>&1 || return 2
  purl=$(result_parent_pr_url "$d/RESULT") || return 2
  pn="${purl##*/}"; case "$pn" in ''|*[!0-9]*) return 2 ;; esac
  # 2. Given up and paged on an earlier tick: terminal, not one read more.
  if [ -f "$d/.pr-url-reconcile-restack-gaveup" ]; then
    say "$bd: the restack of $br was given up and paged earlier. Nothing more from this lane"
    return 1
  fi
  if ! conductor_armed; then
    say "$bd: would restack $br if parent $purl merged and deleted $pbr, but the merge conductor is not armed (flags/merge-conductor-actions absent, or MC_REREVIEW_ON_MOVE=0). Paged as before"
    return 2
  fi
  if ! command -v mc_restack >/dev/null 2>&1; then
    # The lib exits on a missing module, so every module is checked first.
    libok=1
    for m in log locks classify queue rebase settle; do [ -r "$HARNESS/bin/lib/mc/$m.sh" ] || libok=0; done
    [ "$libok" = 1 ] && [ -r "$HARNESS/bin/lib/merge-conductor-lib.sh" ] \
      && . "$HARNESS/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
  fi
  if ! command -v mc_restack >/dev/null 2>&1 || ! command -v mc_project_base >/dev/null 2>&1; then
    say "$bd: cannot restack $br: bin/lib/merge-conductor-lib.sh (mc_restack) is not on this box. Paged as before"
    return 2
  fi
  base=$(mc_project_base "$proj")
  # 3. The parent: merged, from the branch the note names, with a real head sha.
  out=$(gh_pr_rest_read "repos/$slug/pulls/$pn"); code=$(head -n 1 <<<"$out"); body=$(tail -n +2 <<<"$out")
  if [ "$code" != 200 ]; then
    say "$bd: reading parent $purl answered HTTP ${code:-none}. UNKNOWN, nothing restacked and nothing alerted"
    return 3
  fi
  IFS=$'\t' read -r merged href phead < <(jq -r 'if type == "object" then [(.merged_at // ""), (.head.ref // ""), (.head.sha // "")] | map(if . == "" then "-" else . end) | @tsv else "-\t-\t-" end' 2>/dev/null <<<"$body")
  if [ "${merged:--}" = - ]; then
    say "$bd: parent $purl is not merged. Not restacked, paged as before"
    return 2
  fi
  if [ "$href" != "$pbr" ]; then
    say "$bd: parent $purl was cut from ${href:-?}, not $pbr as line 1 says. Not restacked, paged as before"
    return 2
  fi
  if ! [[ "$phead" =~ ^[0-9a-f]{40}$ ]]; then
    say "$bd: parent $purl reports no usable head sha ($phead). UNKNOWN, nothing restacked"
    return 3
  fi
  # Only an explicit 404 is "the branch is gone" (D11). A live branch is not the
  # ticket's case: the base still exists and the page's command still works.
  out=$(gh_pr_rest_read "repos/$slug/branches/${pbr//\//%2F}"); code=$(head -n 1 <<<"$out")
  case "$code" in
    404) ;;
    200) say "$bd: parent $purl merged but $pbr still exists. Not restacked, paged as before"; return 2 ;;
    *)   say "$bd: reading branch $pbr answered HTTP ${code:-none}. UNKNOWN, nothing restacked and nothing alerted"; return 3 ;;
  esac
  out=$(gh_pr_rest_read "repos/$slug/branches/${br//\//%2F}"); code=$(head -n 1 <<<"$out")
  case "$code" in
    200) chead=$(jq -r '.commit.sha // empty' 2>/dev/null <<<"$(tail -n +2 <<<"$out")") ;;
    404) say "$bd: $br was never pushed, so there is nothing to restack. Paged as before"; return 2 ;;
    *)   say "$bd: reading branch $br answered HTTP ${code:-none}. UNKNOWN, nothing restacked and nothing alerted"; return 3 ;;
  esac
  if ! [[ "$chead" =~ ^[0-9a-f]{40}$ ]]; then
    say "$bd: branch $br reports no usable head sha. UNKNOWN, nothing restacked"
    return 3
  fi
  # 4. Already pushed by this arm on an earlier tick, and the branch has not
  # moved since: only the create is owed.
  new=""
  if [ -s "$mk" ]; then
    if [ "$(head -n 1 "$mk")" = "$chead" ]; then new="$chead"; else rm -f "$mk"; fi
  fi
  # 5. The crash window: pushed, but the marker never landed. A parent head in
  # the child's history is the ordinary restack; one that is not, on a child
  # that already contains the base's tip, was rebased by an earlier tick.
  if [ -z "$new" ]; then
    out=$(gh_pr_rest_read "repos/$slug/compare/$phead...$chead"); code=$(head -n 1 <<<"$out")
    [ "$code" = 200 ] || { say "$bd: comparing $br with the parent head answered HTTP ${code:-none}. UNKNOWN, nothing restacked"; return 3; }
    st=$(jq -r '.status // empty' 2>/dev/null <<<"$(tail -n +2 <<<"$out")")
    case "$st" in
      ahead|identical) ;;
      *)
        out=$(gh_pr_rest_read "repos/$slug/compare/$base...$chead"); code=$(head -n 1 <<<"$out")
        [ "$code" = 200 ] || { say "$bd: comparing $br with $base answered HTTP ${code:-none}. UNKNOWN, nothing restacked"; return 3; }
        behind=$(jq -r '.behind_by // empty' 2>/dev/null <<<"$(tail -n +2 <<<"$out")")
        if [ "$behind" = 0 ]; then
          new="$chead"; printf '%s\n' "$new" > "$mk"
          say "$bd: $br already sits on $base (${chead:0:8}); an earlier tick pushed it. Not rebased again"
        fi ;;
    esac
  fi
  if [ -z "$new" ]; then
    rc=0; out=$(mc_restack "$slug" "$proj" "$br" "$chead" "$phead" "$base" "record $bd") || rc=$?
    case "$rc" in
      0)
        new="$out"
        if ! [[ "$new" =~ ^[0-9a-f]{40}$ ]]; then
          say "$bd: mc_restack answered rc 0 with no sha. UNKNOWN, nothing created"
          return 3
        fi
        # WRITE BEFORE CREATE: the push happened, and the next tick must know it.
        printf '%s\n' "$new" > "$mk"
        say "$bd: restacked $br onto $base (${phead:0:8}..${chead:0:8} -> ${new:0:8}) after parent $purl merged" ;;
      1)
        alert "$d" "prurlreconcile:restack:$bd" \
          "[pr-url-reconcile] $proj/$key: stacked on $pbr, parent $purl merged and its branch is gone; rebase --onto $base ${phead:0:8} conflicts in: $(tr '\n' ' ' <<<"$out" | sed 's/ *$//') (record $bd). Nothing pushed. bin/blocked-resolver.sh rebuilds it after its 90-minute floor, or resolve by hand: git rebase --onto origin/$base $phead on $br, then gh pr create --head $br --base $base -R $slug" \
          .pr-url-reconcile-restack-gaveup
        ALERTED=$((ALERTED+1)); say "$bd: restacking $br conflicts. Alerted and given up"
        return 1 ;;
      6)
        alert "$d" "prurlreconcile:restack:$bd" \
          "[pr-url-reconcile] $proj/$key: stacked on $pbr, parent $purl merged and its branch is gone; parent head ${phead:0:8} is not in $br's history (the parent was rewritten after the child was cut) (record $bd). Nothing pushed. bin/blocked-resolver.sh rebuilds it after its 90-minute floor; no person rebases it" \
          .pr-url-reconcile-restack-gaveup
        ALERTED=$((ALERTED+1)); say "$bd: parent head ${phead:0:8} is not in $br's history. Alerted and given up"
        return 1 ;;
      *)
        restack_try "$d" "mc_restack rc $rc (3 = the branch moved or the push lease was refused, 4 = setup; logs/merge-conductor.log says which)" \
          "[pr-url-reconcile] $proj/$key: stacked on $pbr, parent $purl merged and its branch is gone; restacking $br onto $base failed 3 times (record $bd). Given up here. bin/blocked-resolver.sh rebuilds it after its 90-minute floor, or by hand: git rebase --onto origin/$base $phead on $br, then gh pr create --head $br --base $base -R $slug"
        return $? ;;
    esac
  fi
  # 6. Open the PR against the base. The body is the build's own plus one note,
  # written to a scratch file: pr-body.md itself is never edited.
  title=$(jq -r '.title // empty' "$d/ticket-meta.json" 2>/dev/null)
  [ -n "$title" ] || title="restacked onto $base after parent #$pn merged"
  # >>> pr trailers (BH-3987)
  bf="$d/pr-body.restack.$$"
  {
    if [ -s "$d/pr-body.md" ]; then cat "$d/pr-body.md"; else printf '%s\n' "$key: opened by pr-url-reconcile after the builder's create failed."; fi
    printf '\nRestacked by pr-url-reconcile: the parent %s merged and deleted `%s`, so this branch was rebased --onto %s %s and the PR opened against %s.\n' \
      "$purl" "$pbr" "$base" "${phead:0:8}" "$base"
  } > "$bf"
  # THE PR SAYS WHO BUILT IT: the build's own job, never this lane's. The apply
  # runs after the note, so the old block that came with pr-body.md is dropped
  # and the new one lands last. JOB_ID is blanked because bin/orc-job.sh exports
  # THIS lane's claim under that name.
  [ -r "${HARNESS:-}/bin/lib/pr-trailers.sh" ] && . "$HARNESS/bin/lib/pr-trailers.sh"
  if command -v pr_trailers_apply >/dev/null 2>&1; then
    tjob=$(pr_trailers_read "$d/pr-body.md" 2>/dev/null | cut -f1)
    case "$tjob" in ""|none) tjob=$(JOB_ID='' pr_trailers_job_for "$d") ;; esac
    pr_trailers_apply "$bf" "$tjob" "$key" || say "$bd: pr trailers: could not write $bf — PR opened without trailers"
  fi
  url=$(_gpc_rung_create "$slug" "${slug%%/*}" "$br" "$base" "$key: $title" "$bf" "$d/pipeline.log" pr-url-reconcile rest "")
  rm -f "$bf"
  # <<< pr trailers
  if [ -z "$url" ]; then
    why=$(tail -n 1 "$d/pipeline.log" 2>/dev/null | sed -E 's/^[0-9-]+ [0-9:]+Z //' | cut -c1-200)
    restack_try "$d" "the create against $base failed: ${why:-no reason logged}" \
      "[pr-url-reconcile] $proj/$key: stacked on $pbr, parent $purl merged and its branch is gone; $br was restacked onto $base (${new:0:8}) but opening its PR failed 3 times (record $bd). Given up here. Open it by hand: gh pr create --head $br --base $base -R $slug"
    return $?
  fi
  relink "$d" "$l1" "$url" 1 "RESTACKED: $purl $phead -> $new onto $base" \
    || { say "$bd: opened $url but could not rewrite the RESULT. The next tick links it off the open PR"; return 3; }
  rm -f "$d/.pr-url-reconcile-restack-tries"
  say "$bd: opened $url for $br against $base after the restack, and linked line 1 to it"
  verdict_handoff "$d" "$proj" "$key" "$br" "$url"
  return 0
}

WALKED=0; LINKED=0; ALERTED=0; SKIPPED=0; UNWALKED=0

# records — the record dirs to walk, newest first. A project run lists only
# its own three prefixes; an empty list walks nothing (a bare `ls -1dt` would
# list the cwd).
records() {
  local -a ds=()
  if [ "$PUR_MODE" = project ]; then
    shopt -s nullglob
    ds=("$HARNESS"/builds/{"$PUR_PROJECT"-,pool-"$PUR_PROJECT"-,fly-"$PUR_PROJECT"-}*/)
    shopt -u nullglob
    [ "${#ds[@]}" -gt 0 ] || return 0
    ls -1dt "${ds[@]}" 2>/dev/null
  else
    ls -1dt "$HARNESS"/builds/*/ 2>/dev/null
  fi
}

while IFS= read -r D; do
  D="${D%/}"
  # A project run walks only records that bucket to its project: `pa-x-…`
  # matches the `pa-` glob, but project_of (longest name first) says pa-x.
  if [ "$PUR_MODE" = project ] && [ "$(project_of "$(basename "$D")")" != "$PUR_PROJECT" ]; then
    continue
  fi
  [ -f "$D/RESULT" ] || continue
  L1=$(head -n 1 "$D/RESULT")
  # ONLY a failed create, or a record THIS LANE relinked on an earlier tick that
  # still owes the ledger half (BH-858) — that second arm is what makes a worker
  # outage safe: an outage marks nothing, and the record comes back round. A
  # correct link the builder made is never overwritten, and a PLAN_BLOCKED or
  # BUILD_DEFERRED record is not a build that owes a PR.
  # BOTH WORDS FOR A FAILED CREATE (BH-614). `RESULT_MALFORMED PR_CREATED …` is
  # what bin/fly-pool.sh's url-shape gate writes when an older pool image claimed
  # a PR and field 2 was not a url — the same failed create, a different speller.
  # The re-link keeps the original as `RECONCILED_FROM:` exactly as for the
  # ratchet's line, and base_of reads the STACKED note off either shape. It can
  # never fall into the RECONCILED arm below: that pattern anchors on `PR_CREATED `
  # at position 1, and this line starts with `RESULT_MALFORMED `.
  RECON=0
  case "$L1" in
    PR_CREATE_FAILED*|"RESULT_MALFORMED PR_CREATED"*) ;;
    "PR_CREATED "*" | RECONCILED "*)
      # No ledger client on this box: byte-identical to today, not even walked.
      command -v job_for_record >/dev/null 2>&1 || continue
      [ -f "$D/.verdict-handoff-done" ] && { SKIPPED=$((SKIPPED+1)); continue; }
      RECON=1 ;;
    *) continue ;;
  esac
  # Terminal: this record has been linked, and a linked record is never re-asked
  # about its LINK. The RECONCILED arm above is past that question already.
  [ "$RECON" = 1 ] || [ ! -f "$D/.pr-url-reconciled" ] || { SKIPPED=$((SKIPPED+1)); continue; }
  # bin/blocked-resolver.sh ran its whole ladder on this build and closed it out.
  [ -f "$D/.blocked-resolver-abandoned" ] && { SKIPPED=$((SKIPPED+1)); continue; }
  # Terminal: its `PR:` line disagrees with the branch and a human was paged.
  # Nothing this lane can read will change that; the marker is what a human
  # removes after fixing the line, and that re-arms the record.
  [ -f "$D/.pr-url-reconcile-mislinked" ] && { SKIPPED=$((SKIPPED+1)); continue; }
  # bin/blocked-resolver.sh replaced this record with a fresh build of the same
  # ticket (BH-614). Re-linking a retired record to a hand-opened PR would hand
  # the merge sweep a second PR for one ticket, against the rebuild's own.
  # Unconditional on purpose, RECON arm included: the resolver only ever offers a
  # `PR_CREATE_FAILED` / `RESULT_MALFORMED PR_CREATED` line 1, so a record it
  # superseded is normally never a RECON one — and on the one race where it is
  # (the mark lands after this lane rewrote line 1), the rebuild owns the ticket
  # and buying the retired PR a verdict hand-off is the wrong spend.
  [ -f "$D/.blocked-resolver-superseded" ] && { SKIPPED=$((SKIPPED+1)); continue; }

  if [ "$WALKED" -ge "$MAX" ] || [ "$SECONDS" -ge "$DEADLINE" ]; then
    UNWALKED=$((UNWALKED+1)); continue
  fi

  BD=$(basename "$D")
  PROJ=$(project_of "$BD") || { SKIPPED=$((SKIPPED+1)); say "$BD: names no project in fleet.conf — skipped"; continue; }
  KEY=$(key_of "$BD" "$PROJ")
  BRANCH=$(branch_of "$D" "$KEY" "$PROJ") \
    || say "$BD: the record names no branch of its own (no pipeline.log, or none that is this key's) — asking the stem $BRANCH"
  case "$BRANCH" in *-r[0-9]*) say "$BD: the record names $BRANCH as its branch (a rebuild) — asking about that, not the stem" ;; esac
  if [ "$RECON" = 1 ]; then
    # Already linked on the record; this walk owes the LEDGER only. The url is in
    # line 1, where this lane wrote it, so the branch is never resolved over
    # GitHub — the one GitHub read left on this arm is pr_finished's, and only on
    # the path that would otherwise page. branch_of reads the record's own
    # pipeline.log and costs nothing; the name only rides the hand-off's words.
    WALKED=$((WALKED+1))
    RURL=$(awk '{print $2}' <<<"$L1")
    case "$RURL" in
      https://*) verdict_handoff "$D" "$PROJ" "$KEY" "$BRANCH" "$RURL" 1 ;;
      *) say "$BD: line 1 says RECONCILED but names no url — left alone" ;;
    esac
    continue
  fi
  SLUG=$(slug_of "$PROJ") || { SKIPPED=$((SKIPPED+1)); say "$BD: no repo slug for $PROJ — skipped"; continue; }
  OWNER="${SLUG%%/*}"

  WALKED=$((WALKED+1))
  command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG" || true
  ERR_AT=$(stderr_at)
  OUT=$(gh_pr_rest_read "repos/$SLUG/pulls?head=$OWNER:$BRANCH&state=open")
  CODE=$(head -n 1 <<<"$OUT"); BODY=$(tail -n +2 <<<"$OUT")

  if [ "$CODE" != 200 ]; then
    # D11: an outage is UNKNOWN. Not "no PR", not a reason to write anything.
    WHY=""; [ -n "$CODE" ] || WHY=$(stderr_since "$ERR_AT")
    say "$BD: reading $BRANCH on $SLUG answered HTTP ${CODE:-none} — UNKNOWN, nothing written and nothing alerted${WHY:+ (gh said: $WHY)}"
    continue
  fi

  URL=$(jq -r 'if type == "array" and length > 0 then (.[0].html_url // empty) else empty end' 2>/dev/null <<<"$BODY")

  if [ -z "$URL" ]; then
    # An affirmative "there is no OPEN PR on that branch".
    VERDICT=$(verdict_of "$D")
    if [ "$VERDICT" != APPROVE ]; then
      say "$BD: no open PR on $BRANCH (verdict ${VERDICT:-none}) — nothing owed, nothing written"
      continue
    fi
    # AN ALREADY-PAGED RECORD STILL TAKES THE state=all READ (review round 4). It
    # was paged for "APPROVE, no PR"; a PR an operator then opened by hand and
    # MERGED shows up only on that read, and short-circuiting ahead of it left
    # the record costing one REST read a tick forever, counted against MAX, with
    # nothing left to learn. It is never paged a second time.
    PAGED=0; [ -f "$D/.pr-url-reconcile-alerted" ] && PAGED=1
    # BEFORE PAGING, ASK WHETHER THE PR IS SIMPLY FINISHED. The twelve records
    # this ticket describes were backfilled by hand and several of those PRs are
    # merged; "open it by hand" would be advice about a PR already in main. Only
    # the open read decides the link — this one decides the WORDS.
    ALLOUT=$(gh_pr_rest_read "repos/$SLUG/pulls?head=$OWNER:$BRANCH&state=all")
    ALLCODE=$(head -n 1 <<<"$ALLOUT")
    PAST=""; PASTURL=""
    if [ "$ALLCODE" = 200 ]; then
      PAST=$(jq -r 'if type == "array" and length > 0 then (if .[0].merged_at then "merged" else (.[0].state // "closed") end) else empty end' \
             2>/dev/null <<<"$(tail -n +2 <<<"$ALLOUT")")
      PASTURL=$(jq -r 'if type == "array" and length > 0 then (.[0].html_url // empty) else empty end' \
                2>/dev/null <<<"$(tail -n +2 <<<"$ALLOUT")")
    fi
    if [ "$PAST" = merged ]; then
      # Terminal. Nothing is owed and nothing about a merged PR can change, so
      # this record must not cost two REST reads a tick at the head of the walk.
      touch "$D/.pr-url-reconciled"
      say "$BD: no OPEN PR on $BRANCH, but ${PASTURL:-its PR} is merged — nothing owed, nothing written, marked terminal"
      continue
    fi
    if [ "$PAST" = open ]; then
      # A PR opened between the two reads. Paging for it would be a page about a
      # PR that exists; the next tick's state=open read links it.
      say "$BD: ${PASTURL:-a PR} on $BRANCH is open as of the second read — not alerted, the next tick links it"
      continue
    fi
    # BH-1904: a stacked child whose parent merged and deleted its branch is
    # restacked onto the base and its PR opened here, instead of a page naming
    # a base that no longer exists. rc 2 = not that case: the page below, as before.
    RSRC=0; restack_orphan "$D" "$PROJ" "$KEY" "$SLUG" "$BRANCH" "$L1" || RSRC=$?
    case "$RSRC" in
      0) LINKED=$((LINKED+1)); continue ;;
      1|3) continue ;;
    esac
    if [ "$PAGED" = 1 ]; then
      say "$BD: no open PR on $BRANCH and already paged for it (${PASTURL:-no PR on record}${PAST:+, $PAST}) — nothing owed, nothing written, still re-readable"
      continue
    fi
    FIXBASE=$(base_of "$L1")
    if [ "$PAST" = closed ]; then
      alert "$D" "prurlreconcile:none:$BD" \
        "[pr-url-reconcile] $PROJ/$KEY: review says APPROVE but the only PR on $BRANCH (${PASTURL:-unknown url}) is CLOSED without merging (record $BD) — reopen it, or open a new one: gh pr create --head $BRANCH --base $FIXBASE -R $SLUG"
      say "$BD: APPROVE with a closed, unmerged PR on $BRANCH — alerted"
    else
      alert "$D" "prurlreconcile:none:$BD" \
        "[pr-url-reconcile] $PROJ/$KEY: review says APPROVE but GitHub says no open PR on $BRANCH (record $BD) — open it by hand: gh pr create --head $BRANCH --base $FIXBASE -R $SLUG"
      say "$BD: APPROVE with no open PR on $BRANCH — alerted"
    fi
    ALERTED=$((ALERTED+1))
    continue
  fi

  EXISTING=""
  command -v result_own_pr_url >/dev/null 2>&1 && EXISTING=$(result_own_pr_url "$D/RESULT" || true)
  if [ -n "$EXISTING" ] && [ "$EXISTING" = "$URL" ]; then
    # The `PR:` line is right and line 1 is still the failure — the shape a hand
    # backfill leaves. Marking it terminal without rewriting line 1 would freeze
    # it out of the sweep for good, so it takes the same rewrite as any other
    # record, minus the second `PR:` line it already has.
    relink "$D" "$L1" "$URL" 0 \
      || { say "$BD: could not rewrite the RESULT — nothing written"; continue; }
    LINKED=$((LINKED+1))
    say "$BD: already carried PR: $URL — linked line 1 to it so the sweep can see it"
    verdict_handoff "$D" "$PROJ" "$KEY" "$BRANCH" "$URL"
    continue
  fi
  if [ -n "$EXISTING" ]; then
    # NEVER OVERWRITE. Two answers disagree; a human decides which is right.
    # THE PAGE REMEMBERS ITSELF, not alert()'s shared flag (review round 3). The
    # mislink marker below is TERMINAL, so gating the page on
    # .pr-url-reconcile-alerted — which alert() touches for "APPROVE, no PR" and
    # "closed unmerged" too — meant a record paged once for anything else left
    # this lane for good with nobody ever told it was mislinked, and the only
    # written record of the exit was inside the page that never happened.
    if [ ! -f "$D/.pr-url-reconcile-mislink-alerted" ]; then
      alert "$D" "prurlreconcile:mislink:$BD" \
        "[pr-url-reconcile] $PROJ/$KEY: record $BD carries PR: $EXISTING but $BRANCH resolves to $URL — mislinked, left untouched; fix the PR: line by hand, then rm $D/.pr-url-reconcile-mislinked to re-arm" \
        .pr-url-reconcile-mislink-alerted
      ALERTED=$((ALERTED+1))
    fi
    # Alert, THEN mark (same order as the link): a human edit is the only exit.
    # Removing the terminal marker re-arms one read and does not page again —
    # the page's own marker is what remembers, and it outlives the re-arm.
    touch "$D/.pr-url-reconcile-mislinked"
    say "$BD: carries PR: $EXISTING but $BRANCH resolves to $URL — left untouched, marked mislinked"
    continue
  fi

  relink "$D" "$L1" "$URL" 1 \
    || { say "$BD: could not rewrite the RESULT — nothing written"; continue; }
  LINKED=$((LINKED+1))
  say "$BD: linked $BRANCH to $URL (line 1 rewritten so the sweep can see it)"
  verdict_handoff "$D" "$PROJ" "$KEY" "$BRANCH" "$URL"
done < <(records)

say "tick: walked=$WALKED links=$LINKED alerts=$ALERTED skipped=$SKIPPED unwalked=$UNWALKED cap=$MAX deadline=${DEADLINE}s${PUR_PROJECT_SET:+ project=$PUR_PROJECT}"
# BH-1295: this lane's reads go through gh_pr_rest_read (bin/lib/gh-pr-create.sh),
# a separate contract from gh_rest with no ETag cache of its own — this lane
# sources neither gh-rest.sh nor gh-rest-etag.sh, so the guard below is a
# permanent no-op today, not a transient one. It costs nothing to leave in
# place so the log line already exists the day that read is pointed at
# gh_rest instead of being one more line to add then.
command -v gh_rest_etag_report >/dev/null 2>&1 && gh_rest_etag_report pr-url-reconcile
exit 0
