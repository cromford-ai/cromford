#!/bin/bash
# SCALE-PLAN wave 4b — deploy train with AUTOMATIC rollback (the operator, 2026-07-28).
# Active only for projects with a VERSION_URL (returns {"sha": "..."}). Merges
# enqueue via deploy-request.sh; the train departs at most once per ~15 min
# window (cron */15): one hook fire for the whole batch, then verify the
# version endpoint serves origin/main HEAD. On FAILED verify: automatic
# rollback = a revert PR of the batch's merge commits, landed through the
# merge queue (the sanctioned gate — never a direct push to main), then the
# hook again. One beat either way on failure; silent success.
# usage: deploy-train.sh <project>
set -uo pipefail
PROJECT="${1:?project}"
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
set -a; . "$HENV/global.env" 2>/dev/null; . "$HENV/$PROJECT.env" 2>/dev/null; set +a

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-deploy-train
# (or its project row) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off deploy-train <project>.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit deploy-train "$PROJECT"
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    deploy-train "$PROJECT"
# VERSION_URL is the whole gate. DEPLOY_HOOK_URL is optional since 2026-09-12:
# a project on Vercel's git integration deploys on the push itself, and firing
# a hook there only buys a second build of the same sha (project-5).
[ -n "${VERSION_URL:-}" ] || exit 0
# DEPLOY_ROLLBACK=off (2026-09-12): a failed verify ALERTS and leaves the batch
# queued for the next departure instead of opening a revert PR. The automatic
# revert is the operator's 2026-07-28 policy for the OS fleet; a product repo whose
# main can go red on a repo-walking test (project-5 #374/#377: Vercel kept the
# last good deploy, nothing paged for an hour) wants the page, not the revert.
ROLLBACK="${DEPLOY_ROLLBACK:-on}"
# >>> deployment slug (BH-4080): the repo is fleet.conf's column 2. A project
# with no row gets no guessed slug: one log line and the lane stops.
SLUG=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null || true)
[ -n "$SLUG" ] || { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$PROJECT] deploy-train: no repo slug in fleet.conf — refusing" >> "$HARNESS/logs/deploy-train.log"; exit 1; }
# <<< deployment slug
DQ="$HARNESS/state/deploy-queue/$PROJECT"; mkdir -p "$DQ"
LOG="$HARNESS/logs/deploy-train.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
REPO_DIR="${DEPLOY_TRAIN_REPO_DIR:-/root/repos/$PROJECT}"
# The coordination client, sourced HERE rather than after the lock (where it sat
# until BH-1026.1) because the deploy-queue block below and the self-sourced
# departure both need it. Fail-open, exactly as before: an absent or broken
# client leaves every branch on its file path.
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh" 2>/dev/null

# >>> deploy queue rows (BH-1026.1)
# With `deploy_queue_rows` on, the batch is `deploy_queue` ROWS and every member
# is CLAIMED before the hook fires — the cross-box guard the per-box flock below
# never was. Off, unreachable, or a list that did not answer: the `ls -tr "$DQ"`
# path below, byte for byte. THE FILE DIR IS NOT GONE — bin/deploy-request.sh
# writes it in every mode, and this lane still reads it in every one of those
# three cases.
#
# rc 1 from the list is "the worker did not answer", NEVER "nothing queued"
# (D9/D11): it falls back to the files, which is where the merges actually are.
DQ_ROWS=no; ROWS=""; BDIRS=""
STALE="${DEPLOY_CLAIM_STALE_MIN:-30}"
case "$STALE" in ''|*[!0-9]*) STALE=30 ;; esac
DQ_ON=no
if command -v deploy_queue_rows_on >/dev/null 2>&1 && deploy_queue_rows_on; then
  DQ_ON=yes
  # ADOPT FIRST. A request written while the worker was down left a file and no
  # row; a rows-mode train that read only rows would strand that merge until
  # somebody turned the knob back off. The put is idempotent, so a file that
  # already has a row writes nothing.
  DQ_ADOPTED=ok
  for f in "$DQ"/*; do
    [ -f "$f" ] || continue
    deploy_queue_put "$PROJECT" "$(cut -d' ' -f1 "$f")" "$(cut -d' ' -f2 "$f")" >/dev/null \
      || { DQ_ADOPTED=no; break; }
  done
  if [ "$DQ_ADOPTED" != ok ]; then
    echo "$(STAMP) [$PROJECT] deploy_queue_rows is on but a queued file could not be adopted as a row — this departure reads the file dir" >> "$LOG"
  elif ROWS=$(deploy_queue_list "$PROJECT" queued); then
    DQ_ROWS=yes
    # A claim whose train died leaves `claimed` + departed_at NULL and nothing
    # will ever close it. Past DEPLOY_CLAIM_STALE_MIN it joins the batch; the
    # claim below re-takes it with the same threshold. rc 1 here is tolerated —
    # the queued rows are still a real batch.
    if [ "$STALE" -gt 0 ]; then
      STALE_ROWS=$(deploy_queue_list "$PROJECT" claimed "$STALE") || STALE_ROWS=""
      [ -n "$STALE_ROWS" ] && ROWS="${ROWS:+$ROWS
}$STALE_ROWS"
    fi
  else
    echo "$(STAMP) [$PROJECT] deploy_queue_rows is on but the worker did not answer the queued read — this departure reads the file dir" >> "$LOG"
  fi
fi
# HOLD (BH-3154): any `held` row stops this project's train for the tick — the
# queued rows, the file dir and the self-source alike. A departure ships
# origin/main HEAD, so leaving only the held sha out of the batch would still
# ship its code. Before the flock and every claim, so a held tick writes one
# log line and nothing else.
#
# WHEN IT IS READ. The worker accepts a HOLD only while the settings row is on,
# and a settings read that did NOT answer resolves the knob OFF (an outage is
# never cached, and the env fallback defaults to 0) — so the very boxes that can
# have holds are the ones that fall to the file dir in an outage. The knob seen
# on therefore leaves a box-local marker, state/deploy-hold-armed/<project>, and
# the held list is read when the knob is on, when the settings read did not
# answer, or when the marker is there. Only a box that answered OFF with no
# marker makes no held read (today's rows-off behaviour, byte for byte).
#
# AN UNANSWERED HELD LIST IS NEVER "NOTHING HELD" (D9/D11): with the knob on or
# the marker there it departs nothing (fail closed). Only a box that never saw
# the knob on reads the file dir through it, since it cannot hold anything.
# The marker goes only when the knob answers off AND the held list answers
# empty, so turning the knob off never silently drops a hold that exists.
HOLD_MARK="$HARNESS/state/deploy-hold-armed/$PROJECT"
DQR_UNREAD=no
if [ "$DQ_ON" = no ] && command -v deploy_queue_rows_on >/dev/null 2>&1 \
   && [ "${_DQR_SET:-0}" != 1 ]; then
  DQR_UNREAD=yes
fi
if [ "$DQ_ON" = yes ]; then
  mkdir -p "${HOLD_MARK%/*}" && : > "$HOLD_MARK"
fi
if [ "$DQ_ON" = yes ] || [ "$DQR_UNREAD" = yes ] || [ -e "$HOLD_MARK" ]; then
  if ! HELD=$(deploy_queue_list "$PROJECT" held); then
    if [ "$DQ_ON" = yes ] || [ -e "$HOLD_MARK" ]; then
      echo "$(STAMP) [$PROJECT] deploy hold: the held list did not answer — departing nothing this tick (fail closed)" >> "$LOG"
      exit 0
    fi
    echo "$(STAMP) [$PROJECT] deploy hold: the settings and held reads did not answer and this box has never seen deploy_queue_rows on — no hold can exist, this departure reads the file dir" >> "$LOG"
    HELD=""
  fi
  if [ -n "$HELD" ]; then
    mkdir -p "${HOLD_MARK%/*}" && : > "$HOLD_MARK"
    H8=$(cut -f2 <<<"$HELD" | cut -c1-8 | paste -sd' ')
    echo "$(STAMP) [$PROJECT] deploy hold: $H8 held — the train departs nothing and does not self-source this tick" >> "$LOG"
    # Knob answered OFF with a hold still there: the hold is kept (it was
    # accepted as a promise not to depart), and said ONCE per held set rather
    # than once per tick.
    if [ "$DQ_ON" = no ] && [ "$DQR_UNREAD" = no ] \
       && [ "$(cat "$HOLD_MARK.knob-off" 2>/dev/null)" != "$H8" ]; then
      "$HARNESS/bin/alert-line.sh" --id "deploy-hold-knob-off-$PROJECT" --project "$PROJECT" \
        "[$PROJECT] DEPLOY HOLD: deploy_queue_rows is off but $H8 is still held — the train departs nothing until an operator UNHOLDs it in the console DEPLOY QUEUE table"
      printf '%s' "$H8" > "$HOLD_MARK.knob-off"
    fi
    exit 0
  fi
  if [ "$DQ_ON" = no ] && [ "$DQR_UNREAD" = no ]; then rm -f "$HOLD_MARK" "$HOLD_MARK.knob-off"; fi
fi
# <<< deploy queue rows (BH-1026.1)

# Self-sourced departure (2026-09-12): only merges made by THIS box's sweep
# enqueue here, so a merge armed by a session's watcher that turned the
# production build red (project-5 #432, prod stuck on the previous sha for
# an hour) never got a train and never paged. With an empty queue, compare
# what production serves against origin/main: if main is ahead of it and
# has been for longer than SELF_SOURCE_MIN_AGE_MIN, enqueue the head as a
# self-sourced merge and depart — the verify/alert below is then the same
# one every enqueued merge gets. Ancestry, never equality: production a
# commit AHEAD of what git knows is not stale.
if { [ "$DQ_ROWS" = yes ] && [ -z "$ROWS" ]; } \
   || { [ "$DQ_ROWS" = no ] && ! ls -A "$DQ" 2>/dev/null | grep -q .; }; then
  LIVE0=$(curl -s --max-time 15 ${VERSION_AUTH:+-H "$VERSION_AUTH"} "$VERSION_URL" | jq -r '.sha // .commit // empty' 2>/dev/null)
  [ -n "$LIVE0" ] || exit 0
  (cd "$REPO_DIR" && git fetch -q origin 2>/dev/null) || exit 0
  HEAD0=$(cd "$REPO_DIR" && git rev-parse origin/main 2>/dev/null) || exit 0
  [ "$LIVE0" = "$HEAD0" ] && exit 0
  (cd "$REPO_DIR" && git merge-base --is-ancestor "$HEAD0" "$LIVE0" 2>/dev/null) && exit 0
  HEAD_AGE_MIN=$(( ( $(date +%s) - $(cd "$REPO_DIR" && git log -1 --format=%ct "$HEAD0") ) / 60 ))
  [ "$HEAD_AGE_MIN" -ge "${SELF_SOURCE_MIN_AGE_MIN:-20}" ] || exit 0
  printf '%s %s\n' "$HEAD0" "self-sourced" > "$DQ/$(date -u +%s)-${HEAD0:0:8}"
  echo "$(STAMP) [$PROJECT] self-sourced: production serves ${LIVE0:0:8}, origin/main is ${HEAD0:0:8} (${HEAD_AGE_MIN}m old) and nothing was enqueued — departing on it" >> "$LOG"
  # The row for the departure this lane just invented. A sha that already
  # departed `done` is RE-OPENED by the put, which is the whole reason the
  # writer contract is re-open rather than insert-or-ignore.
  if [ "$DQ_ROWS" = yes ]; then
    if deploy_queue_put "$PROJECT" "$HEAD0" self-sourced >/dev/null; then
      ROWS=$(deploy_queue_list "$PROJECT" queued) || { DQ_ROWS=no; ROWS=""; }
    else
      echo "$(STAMP) [$PROJECT] self-sourced ${HEAD0:0:8}: the deploy_queue row could not be written — this departure reads the file dir" >> "$LOG"
      DQ_ROWS=no; ROWS=""
    fi
  fi
fi
exec 7>"$HARNESS/locks/deploy-train-$PROJECT.lock"; flock -n 7 || exit 0

# >>> main-ci gate (BH-6746)
# With DEPLOY_MAIN_CI_GATE=1 the departure sha is origin/main HEAD only when its
# `main-ci` commit status is success (bin/lib/deploy-main-ci.sh). Red, no status
# yet (MAIN_CI_WAIT, bounded by DEPLOY_MAIN_CI_WAIT_MIN) and past the bound
# (MAIN_CI_UNKNOWN) depart nothing: one log line and exit 0, before any claim,
# so the batch is offered again next tick. On green, TARGET is pinned to the
# gated sha, and a queued sha that is not its ancestor stays queued. Off (the
# default): this block does nothing.
TARGET_PIN=""
if [ "${DEPLOY_MAIN_CI_GATE:-0}" = 1 ]; then
  # shellcheck source=bin/lib/deploy-main-ci.sh
  . "$(dirname "${BASH_SOURCE[0]}")/lib/deploy-main-ci.sh" 2>/dev/null && command -v dmc_decide >/dev/null 2>&1 \
    || { echo "$(STAMP) [$PROJECT] main-ci gate is on but bin/lib/deploy-main-ci.sh did not load — not departing (fail closed)" >> "$LOG"; exit 0; }
  (cd "$REPO_DIR" && git fetch -q origin 2>/dev/null)
  GATE_SHA=$(cd "$REPO_DIR" && git rev-parse -q --verify 'origin/main^{commit}' 2>/dev/null) \
    || { echo "$(STAMP) [$PROJECT] main-ci gate: origin/main could not be read — not departing" >> "$LOG"; exit 0; }
  # shellcheck source=bin/lib/gh-app-auth.sh
  [ -r "$HARNESS/bin/lib/gh-app-auth.sh" ] && . "$HARNESS/bin/lib/gh-app-auth.sh"
  command -v gh_default_auth_for_project >/dev/null 2>&1 && { gh_default_auth_for_project "$PROJECT" || true; }
  DMC_RC=0; dmc_decide "$PROJECT" "$SLUG" "$GATE_SHA" || DMC_RC=$?
  echo "$(STAMP) [$PROJECT] $DMC_LINE" >> "$LOG"
  [ "$DMC_RC" = 0 ] || exit 0
  TARGET_PIN="$GATE_SHA"
fi
# dmc_in_gate <sha> — rc 0 when <sha> ships with the gated TARGET_PIN (always,
# with the gate off). A sha that is not its ancestor stays queued, said once.
dmc_in_gate() {
  [ -n "$TARGET_PIN" ] || return 0
  (cd "$REPO_DIR" && git merge-base --is-ancestor "$1" "$TARGET_PIN" 2>/dev/null) && return 0
  echo "$(STAMP) [$PROJECT] ${1:0:8} is not in the gated ${TARGET_PIN:0:8} — left queued" >> "$LOG"
  return 1
}
# <<< main-ci gate

# N is digits only (BSD wc pads with spaces) because it is also handed to jq as
# a NUMBER below, and " 1" is not one — an unparseable count would cost the
# whole ledger row rather than the padding.
BATCH=""
if [ "$DQ_ROWS" = yes ]; then
  if [ -n "$TARGET_PIN" ]; then
    ROWS=$(while IFS= read -r row; do
      [ -n "$row" ] && dmc_in_gate "$(cut -f2 <<<"$row")" && printf '%s\n' "$row"
    done <<<"$ROWS")
  fi
  SHAS=$(cut -f2 <<<"$ROWS"); BDIRS=$(cut -f4 <<<"$ROWS")
  # CLAIM EVERY MEMBER BEFORE THE HOOK. The flock above is per BOX; this is what
  # stops a second box's train from firing a second deploy hook for the same
  # shas. rc 9 (somebody else has it) and rc 2 (the row went away) drop that sha
  # from this batch and cost nothing else.
  #
  # rc 1 is a worker outage MID-CLAIM, and half a batch is not a batch (D12):
  # release what was already taken, say so, and depart NOTHING this tick. The
  # rows that could not be released sit `claimed` and are re-offered by age.
  DQ_KEPT=""; DQ_KEPT_BD=""; DQ_LOST=0; DQ_I=0
  while read -r sha; do
    DQ_I=$((DQ_I+1)); [ -n "$sha" ] || continue
    bd=$(sed -n "${DQ_I}p" <<<"$BDIRS")
    deploy_queue_claim "$PROJECT" "$sha" "$STALE" >/dev/null; CRC=$?
    case "$CRC" in
      0) DQ_KEPT="${DQ_KEPT:+$DQ_KEPT
}$sha"; DQ_KEPT_BD="${DQ_KEPT_BD:+$DQ_KEPT_BD
}$bd" ;;
      9|2) DQ_LOST=$((DQ_LOST+1))
           echo "$(STAMP) [$PROJECT] ${sha:0:8} is claimed elsewhere (rc=$CRC) — left out of this departure" >> "$LOG" ;;
      *) echo "$(STAMP) [$PROJECT] the worker stopped answering mid-claim (rc=$CRC) — releasing what this train took and departing nothing; the rest is re-offered after ${STALE}m" >> "$LOG"
         while read -r k; do
           [ -n "$k" ] && deploy_queue_depart "$PROJECT" "$k" queued "worker outage mid-claim" >/dev/null
         done <<<"$DQ_KEPT"
         exit 0 ;;
    esac
  done <<<"$SHAS"
  SHAS="$DQ_KEPT"; BDIRS="$DQ_KEPT_BD"
  if [ -z "$SHAS" ]; then
    echo "$(STAMP) [$PROJECT] nothing to depart ($DQ_LOST row(s) claimed elsewhere)" >> "$LOG"
    exit 0
  fi
  N=$(wc -l <<<"$SHAS"); N=$(tr -dc 0-9 <<<"$N"); N="${N:-0}"
else
  BATCH=$(ls -tr "$DQ")
  if [ -n "$TARGET_PIN" ]; then
    BATCH=$(while IFS= read -r f; do
      [ -n "$f" ] && dmc_in_gate "$(cut -d' ' -f1 "$DQ/$f")" && printf '%s\n' "$f"
    done <<<"$BATCH")
    [ -n "$BATCH" ] || { echo "$(STAMP) [$PROJECT] nothing to depart: no queued merge is in the gated ${TARGET_PIN:0:8}" >> "$LOG"; exit 0; }
  fi
  N=$(wc -l <<<"$BATCH"); N=$(tr -dc 0-9 <<<"$N"); N="${N:-0}"
  SHAS=$(while read -r f; do cut -d' ' -f1 "$DQ/$f"; done <<<"$BATCH")
fi
echo "$(STAMP) [$PROJECT] train departing: $N merge(s): $(tr '\n' ' ' <<<"$SHAS")" >> "$LOG"

# ── the departure's DURABLE record (2026-09-12) ──────────────────────────────
# Until now the only proof that production ever served a merged sha was the
# VERIFIED line a few dozen lines below, written to logs/deploy-train.log on
# THIS box. Nothing else could read it: DORA's lead time therefore stopped at
# "merged", deployment frequency counted merges (which overcounts, since a
# train carries a batch), and the train's own success rate was unqueryable —
# a train that stopped departing looked exactly like a fleet that stopped
# merging. Both terminal branches now write a `deploy` ledger row.
#
# FAIL-OPEN, like every other ledger write in this fleet. A worker outage, a
# box with no jobs-client.sh, a jq that chokes: each costs the ROW and changes
# nothing about what the train does. Verifying a deploy is the job; recording
# it is bookkeeping, and bookkeeping may never gate the job. (The client itself
# is sourced further up, beside the deploy-queue block that also needs it.)
# >>> gh default auth
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$HARNESS/bin/lib/gh-app-auth.sh" ] && . "$HARNESS/bin/lib/gh-app-auth.sh"   # App token per repo (#425); unarmed box untouched
# shellcheck source=bin/lib/gh-limit-logger.sh
[ -r "$HARNESS/bin/lib/gh-limit-logger.sh" ] && . "$HARNESS/bin/lib/gh-limit-logger.sh"   # #469's rate-limit identity line; absent = today
# THE DEFAULT IDENTITY FOR THE WHOLE DEPARTURE (BH-470, #424). The train's reads
# (`gh pr list`, the batch's PR lookups) used to run on the fleet PAT even though
# the rollback push below already asked for an App token. Keyed on the project,
# which is what this lane is invoked with; the `gh_auth_for "$SLUG"` before the
# rollback push stays, because on a box that predates #469 it is the ONLY arming
# and once #469 lands it is a cache hit for the same repo.
if command -v gh_default_auth_for_project >/dev/null 2>&1; then
  gh_default_auth_for_project "$PROJECT" || true
fi
# <<< gh default auth
DEPARTED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ'); DEPARTED_S=$(date +%s)
# The PR urls this departure carries. deploy-request.sh enqueues
# "<merge-sha> <build-dir>", and a build dir's RESULT is where run-build.sh
# writes "PR_CREATED <url>" — so this is the one place the shas can be turned
# back into the PRs the metrics side is keyed on. Best effort and CAPPED (the
# ledger detail column is 4000 chars): a merge-queue or self-sourced departure
# has no build dir to read and records its shas alone rather than nothing.
if [ "$DQ_ROWS" = yes ]; then
  DEP_PRS=$(while read -r bd; do
      [ -n "$bd" ] && [ "$bd" != "-" ] && [ -f "$bd/RESULT" ] && grep -ohE \
        'https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]+' "$bd/RESULT" 2>/dev/null | head -1
    done <<<"$BDIRS" | sort -u | head -20)
else
  DEP_PRS=$(while read -r f; do
      bd=$(cut -d' ' -f2 "$DQ/$f" 2>/dev/null)
      [ -n "$bd" ] && [ -f "$bd/RESULT" ] && grep -ohE \
        'https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]+' "$bd/RESULT" 2>/dev/null | head -1
    done <<<"$BATCH" | sort -u | head -20)
fi
# deploy_record <verified|failed> <extra-json>
deploy_record() {
  type job_ledger_put >/dev/null 2>&1 || return 0
  local detail extra="${2:-}"
  [ -n "$extra" ] || extra='{}'
  detail=$(jq -nc --arg p "$PROJECT" --arg sha "$TARGET" --arg dep "$DEPARTED_AT" \
    --arg url "${VERSION_URL:-}" --argjson w "$(( $(date +%s) - DEPARTED_S ))" \
    --argjson n "$N" --arg shas "$SHAS" --arg prs "$DEP_PRS" --argjson x "$extra" \
    '{project:$p, sha:$sha, departure:$dep, prod_url:$url, waited_s:$w, merges:$n,
      shas:($shas|split("\n")|map(select(length>0))[0:20]),
      prs:($prs|split("\n")|map(select(length>0))[0:20])} + $x' 2>/dev/null) || return 0
  job_ledger_put deploy "$SLUG@$TARGET" "$1" "$detail" >/dev/null 2>&1 || true
}

# train_wait — ONE poll interval, but in ≤5s slices, returning EARLY when the
# deploy wake class (bin/lib/wake-class-deploy.sh, BH-1062) has written
# state/deploy-wake-<project> to say production is serving a new sha. The file
# is CONSUMED here, so a stale one left by a finished train costs the next train
# exactly one early curl and nothing else. TRAIN_POLLS/TRAIN_POLL_SECS keep
# their defaults, and TRAIN_POLL_SECS=0 still falls straight through.
train_wait() {
  local total="${TRAIN_POLL_SECS:-20}" left step wake="$HARNESS/state/deploy-wake-$PROJECT"
  case "$total" in ''|*[!0-9]*) total=20 ;; esac
  left=$total
  while :; do
    [ -f "$wake" ] && { rm -f "$wake"; return 0; }
    [ "$left" -gt 0 ] || return 0
    step=$left; [ "$step" -gt 5 ] && step=5
    sleep "$step"; left=$(( left - step ))
  done
}

(cd "$REPO_DIR" && git fetch -q origin)
TARGET=${TARGET_PIN:-$(cd "$REPO_DIR" && git rev-parse origin/main)}
[ -n "${DEPLOY_HOOK_URL:-}" ] && curl -s --max-time 20 -X POST "$DEPLOY_HOOK_URL" >/dev/null 2>&1

DEPLOYED=no
for i in $(seq 1 "${TRAIN_POLLS:-40}"); do   # up to ~13 min (test hooks: TRAIN_POLLS / TRAIN_POLL_SECS)
  train_wait
  LIVE=$(curl -s --max-time 15 ${VERSION_AUTH:+-H "$VERSION_AUTH"} "$VERSION_URL" | jq -r '.sha // .commit // empty' 2>/dev/null)
  [ -n "$LIVE" ] || continue
  # Success = production serves TARGET or any DESCENDANT of it (2026-07-28
  # near-miss: a PR merged mid-window, Vercel skipped to the newer build, and
  # strict equality would have rolled back two healthy merges). Every queued
  # sha is an ancestor of TARGET by construction, so ancestry of TARGET
  # covers the whole batch.
  if [ "$LIVE" = "$TARGET" ]; then DEPLOYED=yes; break; fi
  (cd "$REPO_DIR" && git fetch -q origin 2>/dev/null; git merge-base --is-ancestor "$TARGET" "$LIVE" 2>/dev/null) && { DEPLOYED=yes; TARGET="$LIVE"; break; }
done

if [ "$DEPLOYED" = yes ]; then
  # `done` is stamped ONLY here, after the version endpoint served TARGET or a
  # descendant of it — never by a timeout, never optimistically. A stamp that
  # fails (the worker went down during the poll) leaves the row `claimed`: the
  # deploy DID happen, so the file still goes, and the age re-offer will
  # re-verify the sha by ancestry and close it.
  if [ "$DQ_ROWS" = yes ]; then
    while read -r sha; do
      [ -n "$sha" ] || continue
      deploy_queue_depart "$PROJECT" "$sha" done "VERIFIED live at ${TARGET:0:8}" >/dev/null \
        || echo "$(STAMP) [$PROJECT] ${sha:0:8} deployed but its deploy_queue row could not be stamped done — re-offered after ${STALE}m and re-verified then" >> "$LOG"
    done <<<"$SHAS"
    # Matched by CONTENT, not by list position: this batch came from rows, and
    # the file beside a row is the same request.
    for f in "$DQ"/*; do
      [ -f "$f" ] || continue
      grep -qxF "$(cut -d' ' -f1 "$f")" <<<"$SHAS" && rm -f "$f"
    done
  else
    while read -r f; do rm -f "$DQ/$f"; done <<<"$BATCH"
  fi
  echo "$(STAMP) [$PROJECT] train VERIFIED live at ${TARGET:0:8} ($N merges)" >> "$LOG"
  # Keyed on the sha production was verified to be SERVING (which may be a
  # descendant of the batch's target — see the ancestry note above), so a
  # re-departure on the same sha upserts one row instead of inventing a second
  # deployment, and `verified_at` is the instant a user could see the change.
  deploy_record verified "$(jq -nc --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '{verified_at:$at}' 2>/dev/null || echo '{}')"
  # Migrations ride the train (the operator, 2026-07-30): the freshly-verified bundle may
  # carry new migration files — apply them NOW instead of waiting for the */15
  # cron. Closes the deployed-code-vs-missing-schema window (project-3 TK-18 class).
  # apply-migrations is idempotent + flocked; failures still alert on their own.
  [ -x "$HARNESS/bin/apply-migrations.sh" ] && "$HARNESS/bin/apply-migrations.sh" "$PROJECT" >> "$LOG" 2>&1 || true
  exit 0
fi

# A departure that never arrived, recorded BEFORE the two rollback modes split,
# so an alert-only project and a reverting one leave the same evidence. Three
# outcomes, not two: "verified", "failed", and (the silent one this closes)
# "no row at all", which is a train that never ran. A `failed` row deliberately
# carries no verified_at — the metrics side must not be able to read one.
FAIL_REASON="production still not serving ${TARGET:0:8} after ${TRAIN_POLLS:-40} polls (live=${LIVE:-none})"
deploy_record failed "$(jq -nc --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg live "${LIVE:-}" \
  --arg r "$FAIL_REASON" \
  '{failed_at:$at, live:$live, reason:$r}' 2>/dev/null || echo '{}')"

# THE BATCH GOES BACK ON THE QUEUE, in both failure modes, exactly as both keep
# their files. This runs before the rollback split on purpose: a train killed
# during the revert leaves rows the next tick can re-offer, which is what
# "Keep queue entries so the next train retries" means for the row store.
if [ "$DQ_ROWS" = yes ]; then
  while read -r sha; do
    [ -n "$sha" ] || continue
    deploy_queue_depart "$PROJECT" "$sha" queued "production still not serving ${TARGET:0:8} (live=${LIVE:-none})" >/dev/null \
      || echo "$(STAMP) [$PROJECT] ${sha:0:8} could not be released back to queued — re-offered after ${STALE}m" >> "$LOG"
  done <<<"$SHAS"
fi

if [ "$ROLLBACK" != on ]; then
  # Alert-only: the batch stays queued and the next departure re-verifies — a
  # slow build clears itself, a red build pages again every departure until
  # someone fixes main.
  # How long the oldest member has been waiting: the filename's epoch prefix in
  # files mode, the row's enqueued_at in rows mode.
  if [ "$DQ_ROWS" = yes ]; then
    FIRST_S=$(date -u -d "$(head -1 <<<"$ROWS" | cut -f6)" +%s 2>/dev/null)
    [ -n "$FIRST_S" ] || FIRST_S=$(date +%s)
    AGE_MIN=$(( ( $(date +%s) - FIRST_S ) / 60 ))
  else
    FIRST=$(head -1 <<<"$BATCH"); AGE_MIN=$(( ( $(date +%s) - ${FIRST%%-*} ) / 60 ))
  fi
  echo "$(STAMP) [$PROJECT] train FAILED verify (live=${LIVE:-none} target=${TARGET:0:8}; oldest merge queued ${AGE_MIN}m) — DEPLOY_ROLLBACK=off, alerting, batch left queued" >> "$LOG"
  "$HARNESS/bin/alert-line.sh" "[$PROJECT] DEPLOY TRAIN: production is NOT serving ${TARGET:0:8} ${AGE_MIN}m after the merge (live=${LIVE:-none}) — the Vercel production build is red or the domain is pinned; $N merge(s) waiting: $(tr '\n' ' ' <<<"$SHAS")"
  "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" --arg akey "deploy-stale:$PROJECT:${TARGET:0:8}" \
    --arg l "DEPLOY TRAIN: $PROJECT production is NOT serving ${TARGET:0:8} ${AGE_MIN}m after the merge (live=${LIVE:-none}) — Vercel build red or domain pinned; check that project on Vercel" \
    '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1
  exit 0
fi
echo "$(STAMP) [$PROJECT] train FAILED verify (live=$LIVE target=${TARGET:0:8}) — initiating automatic rollback" >> "$LOG"
# Automatic rollback: revert the batch's merge commits via a PR through the
# merge queue. Never a direct push to main.
RB=rollback/$(date -u +%Y%m%d%H%M)
WT=$(mktemp -d /tmp/dt-XXXX); OK=no
(cd "$REPO_DIR" && git worktree add -f "$WT" origin/main >/dev/null 2>&1)
if (cd "$WT" && git checkout -qB "$RB"); then
  OK=yes
  while read -r s; do (cd "$WT" && git revert --no-edit "$s" >/dev/null 2>&1) || OK=partial; done <<<"$(tac <<<"$SHAS")"
fi
command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG" || true
if [ "$OK" = yes ] && (cd "$WT" && git push -q origin "$RB"); then
  PRBODY="Automatic rollback (deploy train, per the operator 2026-07-28): production failed to serve ${TARGET:0:8} after the batch below merged. Reverting to restore last known-good.

Reverted: $(tr '\n' ' ' <<<"$SHAS")

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
  # >>> pr trailers (BH-3987)
  # The lane opened it. The body goes through a file so the block can be
  # applied; with no file, the same create reads the plain body from stdin.
  PRBF="$WT.prbody"
  { printf '%s\n' "$PRBODY" > "$PRBF"; } 2>/dev/null || { rm -f "$PRBF"; PRBF=""; }
  [ -r "${HARNESS:-}/bin/lib/pr-trailers.sh" ] && . "$HARNESS/bin/lib/pr-trailers.sh"
  if [ -n "$PRBF" ] && command -v pr_trailers_apply >/dev/null 2>&1; then
    pr_trailers_apply "$PRBF" lane:deploy-train none \
      || echo "$(STAMP) [$PROJECT] pr trailers: could not write $PRBF — PR opened without trailers" >> "$LOG"
  elif [ -z "$PRBF" ]; then
    echo "$(STAMP) [$PROJECT] pr trailers: could not write $WT.prbody — PR opened without trailers" >> "$LOG"
  fi
  PRURL=$(cd "$WT" && gh pr create -R "$SLUG" -B main -H "$RB" \
    -t "Rollback: revert failed deploy batch ($(date -u '+%b %d %H:%M'))" \
    --body-file "${PRBF:--}" <<<"$PRBODY" 2>/dev/null)
  [ -z "$PRBF" ] || rm -f "$PRBF"
  # <<< pr trailers
  NUM=$(grep -oE '[0-9]+$' <<<"$PRURL")
  if [ -n "$NUM" ]; then
    mkdir -p "$HARNESS/state/merge-queue/$PROJECT"; touch "$HARNESS/state/merge-queue/$PROJECT/$NUM"
    "$HARNESS/bin/merge-queue.sh" "$PROJECT" >/dev/null 2>&1
    # The hook is optional (see the VERSION_URL gate above): a bare
    # "$DEPLOY_HOOK_URL" here died on `set -u` before the beat and the log line.
    [ -n "${DEPLOY_HOOK_URL:-}" ] && { sleep 10; curl -s --max-time 20 -X POST "$DEPLOY_HOOK_URL" >/dev/null 2>&1; }
    "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" --arg akey "rollback:$PROJECT:$(date -u +%Y%m%d%H%M)" \
      --arg l "DEPLOY TRAIN: $PROJECT failed to serve ${TARGET:0:8} — automatic rollback PR $PRURL enqueued${DEPLOY_HOOK_URL:+ and redeploy fired}. Investigate the batch before re-landing." \
      '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1
    echo "$(STAMP) [$PROJECT] rollback PR $PRURL enqueued${DEPLOY_HOOK_URL:+ + hook re-fired}" >> "$LOG"
    # >>> rollback reopens the ticket (BH-4915): every reverted merge's ticket
    # gets one comment naming this PR and leaves done, once per merge sha, and
    # a deploy_rollback ledger row flags it in the daily digest. Never changes
    # the train's outcome.
    RBM="$WT.members"
    if [ "$DQ_ROWS" = yes ]; then
      paste <(printf '%s\n' "$SHAS") <(printf '%s\n' "$BDIRS") > "$RBM" 2>/dev/null
    else
      while read -r f; do
        [ -n "$f" ] && awk -v OFS='\t' 'NR==1{print $1, $2}' "$DQ/$f" 2>/dev/null
      done <<<"$BATCH" > "$RBM"
    fi
    [ -x "$HARNESS/bin/deploy-rollback-board.sh" ] \
      && "$HARNESS/bin/deploy-rollback-board.sh" "$PROJECT" "$PRURL" "$FAIL_REASON" "$RBM" >> "$LOG" 2>&1 || true
    rm -f "$RBM"
    # <<< rollback reopens the ticket
  fi
else
  "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" --arg akey "rollback-fail:$PROJECT:$(date -u +%Y%m%d%H%M)" \
    --arg l "DEPLOY TRAIN: $PROJECT failed verify AND automatic revert could not be prepared cleanly ($OK) — human needed. Target ${TARGET:0:8}." \
    '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1
  echo "$(STAMP) [$PROJECT] rollback prep failed ($OK) — escalated" >> "$LOG"
fi
(cd "$REPO_DIR" && git worktree remove -f "$WT" >/dev/null 2>&1); rm -rf "$WT"
command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
# Keep queue entries so the next train (or a human) retries with full context.
exit 0
