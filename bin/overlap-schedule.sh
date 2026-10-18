#!/bin/bash
# bin/overlap-schedule.sh <project> [--key <KEY>] [--hot-for <list> <KEY>]
#
# WHAT ORDER SHOULD THIS PROJECT'S READY TICKETS LAUNCH IN, given what each one
# has already said it will touch?
#
# THE NUMBER THIS EXISTS FOR (BH-475, 2026-09-16). 9 of the 17 cromford
# builds the ledger shows as `planning` in 24h actually ended
# `BUILD_DEFERRED file overlap — CONFLICT with <sibling>` after a 0-minute wait,
# on the same handful of shared files (docs/MERGE-CONDUCTOR.md, docs/EVENTS.md,
# docs/BUILD-CONCURRENCY.md, tests/arch-contract-test.sh). Every one of those
# deferrals was bought AFTER a plan session was paid for, and the requeue costs
# a fresh plan. The overlap was knowable before any of that: bin/run-preplan.sh
# had already written both plans' planned-files.txt.
#
# So the question is asked across the WHOLE pre-planned backlog, once, before
# the tick launches anything — and the answer is an ORDER, not a veto. Waves are
# a greedy graph colouring: wave 1 is an independent set, so everything in it
# can build at the same time without any two of them meeting at merge.
#
# IT IS ADVICE, NOT A GATE, and that distinction is the whole safety argument:
#   - nothing here locks, claims, queues or waits. Locks in this harness are
#     dedupe (the operator, 2026-09-13) and this adds none.
#   - the launch-time defer (bin/conflict-check.sh + bin/plan-overlap.sh inside
#     bin/run-build.sh) is UNCHANGED and stays the backstop. This only moves the
#     common case in front of the money.
#   - every failure path prints NOTHING and exits 0. No candidates, no python3,
#     an unreadable list, a dead classifier: the tick then carries no schedule
#     and behaves exactly as it did before this script existed. A missed overlap
#     costs one rebase, which is what today costs; a fabricated one costs a
#     client's ticket a tick of delay for a reason nobody can see.
#
# OUTPUT (stdout, full mode):
#   WAVE 1: AB-1 AB-3 AB-5
#   WAVE 2: AB-2 AB-4
#   STACK: AB-3 base=ticket/ab-7 (overlaps open PR #11 on code/c.ts)
#   HELD: AB-5 overlaps in-flight AB-9 on code/e.ts
#   HELD: TK-1.2 waits for sibling TK-1.1 on code/f.ts (SIBLING_SERIAL)
#   UNPLANNED: AB-8
#   HOT-FILES:
#   code/shared.ts :: AB-1 AB-2 AB-6
# HELD names a ticket whose plan collides with a build running RIGHT NOW (a
# claim in state/claims/, a live build dir, or a `claimed` row in the jobs
# ledger). A SIBLING_SERIAL HELD names a part of a split ticket that waits for
# a sibling part, by bin/sibling-serial.sh's rule (BH-6374). STACK names a WAVE 1 key whose plan overlaps exactly one OPEN harness
# PR and nothing in flight (BH-1174): it launches on that PR's branch with
# STACK_BASE=<base> instead of on the default branch, where bin/overlap-guard.sh
# would defer it until the PR merged. UNPLANNED names a ready ticket with no pre-plan file list yet: it
# cannot be placed, and it stays launchable — the repo's standing rule for this
# question is "no plan data -> cannot judge -> allow" (bin/conflict-check.sh).
#
# MODES:
#   --key <KEY>              one line, this key's verdict, for a triage shard's
#                            prompt. Nothing at all for a key the schedule never
#                            saw. A stacked WAVE 1 key answers
#                            `<K> STACK base=<branch> (overlaps open PR #<n> on <file>)`.
#   --hot-for <list> <KEY>   for the files in <list>, the ones other planned
#                            tickets also name, phrased for the reviewer's
#                            context in bin/run-build.sh.
#
# ONE DEFERRAL RULE, NOT TWO (BH-475 review). bin/overlap-guard.sh has answered
# the same question at LAUNCH time since 2026-09-15 (#366), and it exempts
# `package.json package-lock.json *.md` and honours a Jaccard threshold because
# the merge conductor union-resolves those classes deterministically
# (docs/SCHEDULER.md). A schedule that defers on exactly the paths the guard
# waves through would put two contradictory rules in one tick prompt — so
# OVERLAP_IGNORE and OVERLAP_THRESHOLD are read HERE from the same
# bin/lib/scheduler-conf.sh the guard reads, defaults included. They govern
# COLLISIONS only: the HOT-FILES report still counts every planned path,
# because "should this change live in a per-ticket file?" is a fair question
# about a shared doc even when the conductor can merge it.
#
# KNOBS (env, or env/global.env, resolved by bin/lib/preplan-lib.sh):
#   OVERLAP_SCHEDULE=0 / flags/overlap-schedule-off   kill switch (see above)
#   OVERLAP_HOT_MIN=3                how many planned tickets make a file hot
#   OVERLAP_SNAPSHOT_MAX_AGE=600     seconds a candidate snapshot, and the open-PR
#                                    cache the STACK verdict reads, stay usable
#   STACKED_BUILDS=0 / flags/stacked-builds-off   no STACK verdict (the same
#                                    switch bin/lib/rb/gates.sh honours)
#   OVERLAP_CLAIM_TTL_MIN=360        minutes a claim from ANOTHER box, and its
#                                    heartbeat, may sit with no open PR before
#                                    this schedule releases it (BH-3951; 0 = off;
#                                    settings row lib.overlap-claim-ttl.*)
# KNOBS SHARED WITH bin/overlap-guard.sh (env, or flags/scheduler.conf, via
# bin/lib/scheduler-conf.sh):
#   OVERLAP_IGNORE='package.json package-lock.json *.md'   never a collision
#   OVERLAP_THRESHOLD=0              Jaccard below which a hit is not a collision
#   READ_MOSTLY_*                    the read-mostly set (bin/lib/read-mostly.sh):
#                                    never a collision, marked (read-mostly) in
#                                    HOT-FILES
set -uo pipefail
PROJECT="${1:-}"
[ -n "$PROJECT" ] || { echo "usage: overlap-schedule.sh <project> [--key <KEY>] [--hot-for <list> <KEY>]" >&2; exit 2; }
shift
HARNESS="${HARNESS:-/root/harness}"
HERE="$(cd "$(dirname "$0")" && pwd)"

MODE=full; TKEY=""; HOTLIST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --key)     MODE=key;    TKEY="${2:-}"; shift 2 || exit 2 ;;
    --hot-for) MODE=hotfor; HOTLIST="${2:-}"; TKEY="${3:-}"; shift 3 || exit 2 ;;
    *) echo "overlap-schedule.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

# BH-6979: with scheduler.mode=enforce and a usable ready set, the scheduler
# owns the launch order, so a triage shard's --key verdict is not sent: no
# line. The shard reads the ready set in its SOP (bin/lib/rt/scope.sh). Not
# enforced, or a set that is not usable: today's verdict.
if [ "$MODE" = key ] && [ -r "$HERE/lib/sched-gate.sh" ]; then
  # shellcheck source=bin/lib/sched-gate.sh
  . "$HERE/lib/sched-gate.sh" 2>/dev/null
  command -v sched_enforced >/dev/null 2>&1 && sched_enforced "$PROJECT" && sched_ready_load "$PROJECT" && exit 0
fi

# shellcheck source=bin/lib/preplan-lib.sh
[ -r "$HERE/lib/preplan-lib.sh" ] && . "$HERE/lib/preplan-lib.sh" 2>/dev/null
command -v overlap_schedule >/dev/null 2>&1 || exit 0   # no lib, no switch, no opinion
[ "$(overlap_schedule "$HARNESS")" = 1 ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# The guard's two knobs, from the guard's own resolver. Absent lib = the
# documented defaults, which is what bin/overlap-guard.sh itself falls back to.
# shellcheck source=bin/lib/scheduler-conf.sh
[ -r "$HERE/lib/scheduler-conf.sh" ] && . "$HERE/lib/scheduler-conf.sh" 2>/dev/null
if command -v sched_conf >/dev/null 2>&1; then
  # The scheduler rows once, into this shell (BH-2478): each sched_* below runs in `$( )`.
  command -v conf_rows_preload >/dev/null 2>&1 && conf_rows_preload scheduler "$HARNESS"
  IGNORE=$(sched_conf OVERLAP_IGNORE 'package.json package-lock.json *.md' "$HARNESS")
  THRESH=$(sched_frac OVERLAP_THRESHOLD 0 "$HARNESS")
else
  IGNORE='package.json package-lock.json *.md'
  THRESH=0
fi

# READ-MOSTLY PATHS (BH-6299): a path this project's builds plan but almost
# never edit is not a collision, the same as an OVERLAP_IGNORE path. The set
# comes from bin/lib/read-mostly.sh, the one rule bin/overlap-guard.sh reads
# too. Absent lib or no history = empty set = today's rule.
# shellcheck source=bin/lib/read-mostly.sh
[ -r "$HERE/lib/read-mostly.sh" ] && . "$HERE/lib/read-mostly.sh" 2>/dev/null
RM=""
command -v read_mostly_list >/dev/null 2>&1 && RM=$(read_mostly_list "$PROJECT" "$HARNESS" | tr '\n' ' ')

HOT_MIN=$(_preplan_env "$HARNESS" OVERLAP_HOT_MIN 3)
case "$HOT_MIN" in ''|*[!0-9]*) HOT_MIN=3 ;; esac
# Floored at 2 the way preplan_parallel floors at 1, and for the same reason: an
# unreadable or nonsensical knob must never read as "everything qualifies". A
# file one ticket names is not shared with anybody, so 0 and 1 have no meaning
# here — they would print the whole planned file set as a hot-file report.
[ "$HOT_MIN" -lt 2 ] && HOT_MIN=2
MAX_AGE=$(_preplan_env "$HARNESS" OVERLAP_SNAPSHOT_MAX_AGE 600)
case "$MAX_AGE" in ''|*[!0-9]*) MAX_AGE=600 ;; esac

ROWS=$(mktemp) || exit 0
CAND=$(mktemp) || exit 0
trap 'rm -f "$ROWS" "$CAND"' EXIT

# ── the candidate set ────────────────────────────────────────────────────────
# The snapshot bin/preplan-tick.sh writes every 2 minutes, while it is young
# enough to still be true. A snapshot that is too old is NOT "no candidates" —
# it is an unanswered question, and the live classifier is asked instead.
SNAP="$HARNESS/state/preplan-candidates/$PROJECT.tsv"
FRESH=0
if [ -f "$SNAP" ]; then
  AGE=$(python3 -c 'import os,sys,time; print(int(time.time()-os.path.getmtime(sys.argv[1])))' "$SNAP" 2>/dev/null) || AGE=""
  case "$AGE" in ''|*[!0-9]*) AGE="" ;; esac
  [ -n "$AGE" ] && [ "$AGE" -le "$MAX_AGE" ] && FRESH=1
fi
if [ "$FRESH" = 1 ]; then
  cat "$SNAP" > "$CAND" 2>/dev/null
elif [ -x "$HERE/preplan-candidates.sh" ]; then
  "$HERE/preplan-candidates.sh" "$PROJECT" > "$CAND" 2>/dev/null || :
  # ONE LIVE CALL PER TICK, NOT ONE PER SHARD. The triage tick asks this script
  # once for the whole graph and then once more per shard (`--key`), and a box
  # running PREPLAN_SPECULATIVE=0 never writes a snapshot at all — so without
  # this, a 10-shard tick on a stale snapshot would buy 22 GitHub requests for
  # one answer. The first caller that has to ask live publishes what it got, and
  # its siblings in the same tick read the file.
  #
  # ONLY A NON-EMPTY RESULT IS PUBLISHED. An empty answer here is almost always
  # a dead token or a rate limit, not an empty backlog, and stamping it would
  # freeze that outage into a FRESH-and-empty snapshot for the whole max-age
  # window — the schedule would then silently say nothing while looking healthy.
  # bin/preplan-tick.sh does write an empty one, and that is right for the owner
  # of the file: it is the classifier's own tick and its silence IS the answer.
  if [ -s "$CAND" ]; then
    STMP=$(mktemp 2>/dev/null) && cat "$CAND" > "$STMP" 2>/dev/null \
      && mkdir -p "$HARNESS/state/preplan-candidates" 2>/dev/null \
      && mv -f "$STMP" "$SNAP" 2>/dev/null
    [ -e "${STMP:-}" ] && rm -f "$STMP"
  fi
fi

# ── who is in flight ─────────────────────────────────────────────────────────
# The same three sets bin/plan-overlap.sh consults, for the same reason: a
# sibling that is about to collide is often not on this box at all.
INFLIGHT=$(mktemp) || exit 0
UNJUDGED=$(mktemp) || exit 0
CLAIMED=$(mktemp) || exit 0
SEEN=$(mktemp) || exit 0
FCD=$(mktemp -d) || exit 0
trap 'rm -f "$ROWS" "$CAND" "$INFLIGHT" "$UNJUDGED" "$CLAIMED" "$SEEN"; rm -rf "$FCD"' EXIT

emit() { # emit <key> <class> <list-file>
  awk -v k="$1" -v c="$2" 'BEGIN{FS="\n"} {print k "\t" c "\t" $0}' "$3" 2>/dev/null >> "$ROWS"
}

# 0. THE LEDGER FIRST, because it is what says a claim file is still true.
# bin/plan-overlap.sh:live() — a claim on disk is in flight only while the jobs
# ledger still lists that key as claimed, AND ONLY WHEN THE LEDGER ANSWERED AT
# ALL. A build killed without its EXIT trap (kill -9, OOM, reboot) leaves its
# claim behind until some later run-build.sh prunes it >240 min on, and for that
# whole window a HELD verdict — the one hard stop in the tick prompt — would
# name a build that is not running. An outage is NOT an answer: with no ledger
# the claim file is trusted exactly as it was, or a worker blip would switch the
# gate off. Read once here and reused by source 3 below, so this costs the same
# single queue_list call it always did.
LEDGER=0
if [ -r "$HERE/jobs-client.sh" ]; then
  # shellcheck source=/dev/null
  . "$HERE/jobs-client.sh" 2>/dev/null || :
fi
# The fleet's job_claims rows (BH-2524), read as source 2b below. A missing lib
# is an outage, and an outage reads source 1's claim files (BH-5002).
if [ -r "$HERE/lib/file-claims.sh" ]; then
  # shellcheck source=bin/lib/file-claims.sh
  . "$HERE/lib/file-claims.sh" 2>/dev/null || :
fi
if command -v queue_list >/dev/null 2>&1; then
  if LROWS=$(queue_list "$PROJECT" claimed 2>/dev/null); then
    LEDGER=1
    printf '%s\n' "$LROWS" | awk -F'\t' 'NF>1 && $2!="" {print $2}' | sort -u > "$CLAIMED"
  fi
fi
# live <key> -> rc 0 unless something says this build is over.
#
# THE BUILD-KEY FLOCK IS ASKED FIRST, and it is the only signal here that DIES
# WITH THE PROCESS (#1014 review 2). bin/run-build.sh holds
# locks/build-key-<project>-<KEY>.lock for the build's whole life, so a running
# build still holds it and a killed one does not — the kernel releases it
# whatever the build was doing. That matters because NOT EVERY BUILD HAS A
# LEDGER ROW: every direct `setsid run-build.sh` launch (a triage session,
# bin/orphan-reconcile.sh, bin/blocked-resolver.sh, a medic relaunch) runs
# without one, and for those keys the ledger answers "not claimed" for the same
# reason it answers that about a corpse. Asking the ledger alone would call a
# live build dead and hand its files to a sibling.
#
# Then the ledger, which is the only thing that can see ANOTHER box, and only
# when it answered at all: an outage is not an answer, so with no reply the
# artifact is trusted exactly as it was before any of this.
# bin/preplan-tick.sh reads the same lock through the same preplan_held.
live() { # live <key>
  command -v preplan_held >/dev/null 2>&1     && preplan_held "$HARNESS/locks/build-key-$PROJECT-$1.lock" && return 0
  [ "$LEDGER" = 1 ] || return 0
  grep -qxF "$1" "$CLAIMED"
}

# 2b is ASKED here, before 1 (BH-5002), and read below after 2: the same
# DB-first rule as bin/plan-overlap.sh. rc 0 means the worker answered, and
# job_claims is then the claims source, so source 1 is skipped and a claim the
# worker no longer lists stops holding anything even when its file lingers.
# rc != 0 is no answer: source 1 is read exactly as before, and that is logged
# to logs/file-claims-fallback.log only, never stderr (the tick stamps stderr
# into the project log, and the outage output stays byte for byte today's).
FC_OK=0
if command -v fclaim_list_dir >/dev/null 2>&1 && fclaim_list_dir "$PROJECT" "$FCD"; then
  FC_OK=1
fi

# 1. every non-empty claim this box has published, that is still live, read
#    only when job_claims did not answer
#
# SEEN IS WRITTEN BEFORE THE LIVENESS CHECK, exactly as bin/plan-overlap.sh
# does it, and that ordering IS the fix (#1014 review). A build killed without
# its EXIT trap leaves TWO artifacts — this claim file AND its build directory,
# no RESULT, touched inside the 4h window — so filtering only the claim file
# lets source 2 below re-add the very same key from its leftovers and the HELD
# comes straight back. A key whose claim the ledger has settled is DONE being
# judged; its build dir is not a second opinion about it. An empty claim file
# is seeded too, for the same reason and the same way plan-overlap seeds it.
if [ "$FC_OK" = 0 ]; then
  { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) FILE_CLAIMS_FALLBACK $PROJECT overlap-schedule: job_claims unreadable, read state/claims/$PROJECT" \
      >> "$HARNESS/logs/file-claims-fallback.log"; } 2>/dev/null || :
  for F in "$HARNESS/state/claims/$PROJECT"/*; do
    [ -f "$F" ] || continue
    K=$(basename "$F")
    grep -qxF "$K" "$SEEN" 2>/dev/null && continue
    printf '%s\n' "$K" >> "$SEEN"
    [ -s "$F" ] || continue
    grep -qxF "$K" "$INFLIGHT" 2>/dev/null && continue
    live "$K" || continue
    printf '%s\n' "$K" >> "$INFLIGHT"
    emit "$K" inflight "$F"
  done
fi
# 2. live build dirs — no RESULT, touched inside the 4h window bin/conflict-check.sh uses
for D in "$HARNESS/builds/$PROJECT"-*; do
  [ -d "$D" ] || continue
  [ -f "$D/RESULT" ] && continue
  [ -s "$D/planned-files.txt" ] || continue
  [ -n "$(find "$D" -maxdepth 1 -mmin -240 -print -quit 2>/dev/null)" ] || continue
  K=$(jq -r '.key // .ticket_key // empty' "$D/ticket-meta.json" 2>/dev/null)
  [ -n "$K" ] || K=$(basename "$D" | sed -E "s/^${PROJECT}-//; s/-[0-9]+$//")
  [ -n "$K" ] || continue
  # A key source 1 already decided — live or dead — is not re-judged here.
  grep -qxF "$K" "$SEEN" 2>/dev/null && continue
  printf '%s\n' "$K" >> "$SEEN"
  grep -qxF "$K" "$INFLIGHT" 2>/dev/null && continue
  printf '%s\n' "$K" >> "$INFLIGHT"
  emit "$K" inflight "$D/planned-files.txt"
done
# 2b. every box's job_claims row, through fclaim_list_dir (BH-2524), as fetched
#    above: a build running on any box, Fly pool builds included, with its file
#    list. No tie-break here — this is advice about what to launch next, and a
#    candidate that collides with ANY running build waits for it. A key answered
#    here is INFLIGHT, so source 3 no longer calls it unjudged. With no answer
#    nothing is read here; source 1 was read instead.
if [ "$FC_OK" = 1 ]; then
  for F in "$FCD"/*; do
    [ -f "$F" ] || continue
    K=$(basename "$F")
    grep -qxF "$K" "$SEEN" 2>/dev/null && continue
    grep -qxF "$K" "$INFLIGHT" 2>/dev/null && continue
    printf '%s\n' "$K" >> "$SEEN"
    printf '%s\n' "$K" >> "$INFLIGHT"
    [ -s "$F" ] && emit "$K" inflight "$F"
  done
fi
# 3. rows the jobs ledger says are CLAIMED somewhere. A claimed key whose plan
#    list never reached this box is UNJUDGED and said out loud on stderr — never
#    silently treated as disjoint, and never reported as an overlap either.
#    The rows are the ones read in source 0 — one call, two readers.
if [ "$LEDGER" = 1 ]; then
  while IFS= read -r K; do
    [ -n "$K" ] || continue
    grep -qxF "$K" "$INFLIGHT" 2>/dev/null && continue
    printf '%s\n' "$K" >> "$INFLIGHT"
    L="$HARNESS/plans/$PROJECT-$K/planned-files.txt"
    if [ -s "$L" ]; then emit "$K" inflight "$L"; else printf '%s\n' "$K" >> "$UNJUDGED"; fi
  done < "$CLAIMED"
fi
# 3b. A DEAD CLAIM FROM ANOTHER HARNESS IS RELEASED FOR THIS SCHEDULE (BH-3951).
#    An UNJUDGED key is in INFLIGHT, so the candidate loop below skips it, and a
#    claim whose build died on another box kept its ticket out of every schedule
#    for good. One bin/lib/claim-age.sh read per run, only when there IS an
#    unjudged key, gives each claim's age and heartbeat. A key is released HERE
#    ONLY when the claim and its heartbeat (updated_at) are both older than
#    OVERLAP_CLAIM_TTL_MIN, the claim is not this box's, and a clean
#    open_pr_for_key read says no open PR exists. Every unreadable answer (no
#    ledger rows, an unparseable stamp, no slug, PR read rc 2) keeps it
#    UNJUDGED. Nothing is written to the ledger and nothing is locked: the
#    release is recomputed every run. --key judges only its own key, and an
#    unjudged key has no file list, so its release only changes its own verdict.
#    The noclobber marker makes the warn alert once per (key, claimed_at).
AGES=""; TTL=0; ME="${JOBS_BOX:-$(hostname)}"; SLUG=""; SLUG_READ=0
if [ -s "$UNJUDGED" ] && [ "$MODE" != hotfor ] && [ -r "$HERE/lib/claim-age.sh" ]; then
  # shellcheck source=bin/lib/claim-age.sh
  . "$HERE/lib/claim-age.sh" 2>/dev/null
  command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply overlap-claim-ttl >/dev/null 2>&1
  TTL=$(_preplan_env "$HARNESS" OVERLAP_CLAIM_TTL_MIN 360)
  case "$TTL" in ''|*[!0-9]*) TTL=360 ;; esac
  command -v claim_ages >/dev/null 2>&1 && { AGES=$(claim_ages "$PROJECT" 2>/dev/null) || AGES=""; }
fi
no_open_pr() { # no_open_pr <key> -> rc 0 only on a clean "no open PR" answer
  local rc=0
  if [ "$SLUG_READ" = 0 ]; then
    SLUG_READ=1
    SLUG=$(FLEET_CONF="${FLEET_CONF:-$HARNESS/fleet.conf}" "$HERE/fleet-conf.sh" "$PROJECT" repo 2>/dev/null) || SLUG=""
    # shellcheck source=bin/lib/open-pr-precheck.sh
    [ -r "$HERE/lib/open-pr-precheck.sh" ] && . "$HERE/lib/open-pr-precheck.sh" 2>/dev/null
  fi
  [ -n "$SLUG" ] && command -v open_pr_for_key >/dev/null 2>&1 || return 1
  open_pr_for_key "$SLUG" "$1" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 1 ]
}
while IFS= read -r K; do
  [ -n "$K" ] || continue
  BOX=""; CAT=""; UAT=""; AGE=""; SUF=""
  [ -n "$AGES" ] && IFS=$'\t' read -r _ BOX CAT UAT AGE < <(awk -F'\t' -v k="$K" '$1 == k {print; exit}' <<<"$AGES")
  case "$AGE" in ''|*[!0-9]*) AGE="" ;; *) SUF=" (age ${AGE}m by $BOX)" ;; esac
  if [ -n "$AGE" ] && [ "$TTL" -gt 0 ] && { [ "$MODE" = full ] || [ "$K" = "$TKEY" ]; } \
     && [ "$BOX" != "-" ] && [ "$BOX" != "$ME" ] && [ "$AGE" -ge "$TTL" ] \
     && UAGE=$(claim_age_min "$UAT") && [ "$UAGE" -ge "$TTL" ] && no_open_pr "$K"; then
    { grep -vxF "$K" "$INFLIGHT" || :; } > "$INFLIGHT.new" 2>/dev/null && mv -f "$INFLIGHT.new" "$INFLIGHT"
    LINE="OVERLAP_RELEASED $K claim by $BOX ${AGE}m, no PR, no heartbeat"
    echo "$LINE" >&2
    MD="$HARNESS/state/overlap-released/$PROJECT"
    case "$K" in
      *[!A-Za-z0-9._-]*) ;;   # not a safe file name: released, but no marker and so no alert
      *) M="$MD/$K.$(printf '%s' "$CAT" | tr -cd '0-9A-Za-z')"
         # Only the run that CREATED the marker alerts; no marker, no alert.
         if mkdir -p "$MD" 2>/dev/null && ( set -C; : > "$M" ) 2>/dev/null && [ -x "$HERE/lane-alert.sh" ]; then
           "$HERE/lane-alert.sh" --id "overlap-released-$PROJECT-$K" --severity warn overlap-schedule "$LINE" >/dev/null 2>&1 || :
         fi ;;
    esac
    continue
  fi
  echo "OVERLAP_UNJUDGED $K — claimed on another box for $PROJECT${SUF}, no plan file list here; it is not judged and never HELD" >&2
done < "$UNJUDGED"
# A release marker outlives its claim only while the ledger still lists the key
# as claimed. Pruned in full mode, and only when the ledger answered.
if [ "$MODE" = full ] && [ "$LEDGER" = 1 ]; then
  for M in "$HARNESS/state/overlap-released/$PROJECT"/*; do
    [ -f "$M" ] || continue
    K=$(basename "$M"); K="${K%.*}"
    grep -qxF "$K" "$CLAIMED" 2>/dev/null || rm -f "$M"
  done
fi

# 4. OPEN harness PRs, for the STACK verdict (BH-1174). Read-only, from the cache
#    bin/overlap-guard.sh already writes atomically — no GitHub call is made
#    here. Used only while it is younger than OVERLAP_SNAPSHOT_MAX_AGE and the
#    stacked-builds kill switch is off (read the way overlap-guard.sh reads it,
#    and bin/lib/rb/gates.sh ignores STACK_BASE under the same switch). Absent,
#    stale or unparseable is NO ROWS, so the output is today's: a STACK line is
#    never built from missing data. Rows: number<TAB>branch<TAB>path, drafts
#    dropped as the guard drops them, and a branch that could not be pasted
#    into a launch line safely never reaches the python pass. The rows are read
#    with the switch off too, for the sibling rule below; the python pass then
#    builds no STACK line from them.
PRS=$(mktemp) || exit 0
SIB=$(mktemp) || exit 0
SIBP=$(mktemp) || exit 0
trap 'rm -f "$ROWS" "$CAND" "$INFLIGHT" "$UNJUDGED" "$CLAIMED" "$SEEN" "$PRS" "$SIB" "$SIBP"; rm -rf "$FCD"' EXIT
PRC="$HARNESS/state/overlap-guard/$PROJECT-prs.json"
STACK_ON=1
case "$(_preplan_env "$HARNESS" STACKED_BUILDS 1)" in 0) STACK_ON=0 ;; esac
# lane_switch is always in scope here: bin/lib/preplan-lib.sh (required above)
# sources bin/lib/lane-switch.sh or defines the flags/<name> fallback itself.
HARNESS="$HARNESS" lane_switch stacked-builds-off file && STACK_ON=0
if [ -s "$PRC" ] && command -v jq >/dev/null 2>&1; then
  PAGE=$(python3 -c 'import os,sys,time; print(int(time.time()-os.path.getmtime(sys.argv[1])))' "$PRC" 2>/dev/null) || PAGE=""
  case "$PAGE" in ''|*[!0-9]*) PAGE="" ;; esac
  if [ -n "$PAGE" ] && [ "$PAGE" -le "$MAX_AGE" ]; then
    jq -r '.[]? | select((.isDraft // false) | not)
           | (.number|tostring) as $n | (.headRefName // "") as $b
           | (.files // [])[] | (.path // .filename // empty) | [$n, $b, .] | @tsv' \
      "$PRC" 2>/dev/null \
      | awk -F'\t' '$2 ~ /^[A-Za-z0-9._\/-]+$/ && index($2, "..") == 0 && $3 != ""' > "$PRS" 2>/dev/null \
      || : > "$PRS"
  fi
fi

# ── the candidates that are not already building ─────────────────────────────
while IFS=$'\t' read -r K TID WHY; do
  [ -n "${K:-}" ] || continue
  case "${WHY:-}" in queued|child|child-building|ahead|blocked) ;; *) continue ;; esac
  grep -qxF "$K" "$INFLIGHT" 2>/dev/null && continue    # it is building, not waiting
  L="$HARNESS/plans/$PROJECT-$K/planned-files.txt"
  if [ -s "$L" ]; then emit "$K" "$WHY" "$L"; else printf '%s\t%s\t\n' "$K" "$WHY" >> "$ROWS"; fi
done < "$CAND"

# --hot-for: the caller's own list is the truth for its key, because the build
# that asks is the one holding it, and its claim file and its candidate row are
# both copies of the same thing.
if [ "$MODE" = hotfor ]; then
  [ -s "$HOTLIST" ] && [ -n "$TKEY" ] || exit 0
  # TWO TICKETS IS A HOT FILE FOR THE BUILD THAT ASKS (BH-475 review).
  # OVERLAP_HOT_MIN thresholds the whole-backlog report, where a file three
  # tickets name is the one worth a paragraph. This mode answers a different
  # question for one build's reviewer — "is anybody else planning to edit this
  # file?" — and the answer at one other ticket is already actionable, is the
  # most common case, and is what the ticket asked for ("shared with #a #b").
  HOT_MIN=2
  FILT=$(mktemp) || exit 0
  grep -v "^$(printf '%s' "$TKEY" | sed 's/[].[^$\\*/]/\\&/g')	" "$ROWS" > "$FILT" 2>/dev/null
  mv -f "$FILT" "$ROWS" 2>/dev/null || rm -f "$FILT"
  emit "$TKEY" hotfor "$HOTLIST"
fi

[ -s "$ROWS" ] || exit 0

# SIBLING PARTS (BH-6374): bin/sibling-serial.sh's rule over the same three
# files. Each line names a part (TK-184, or TK-142.2) that must wait for a
# sibling (TK-183, or TK-142.1); the python pass turns it into a HELD line. The
# parts map (`parts`, from this box's DECOMPOSED records) is what makes a board
# key a part. Missing script or no line = today's output.
if [ "$MODE" != hotfor ] && [ -x "$HERE/sibling-serial.sh" ]; then
  HARNESS="$HARNESS" "$HERE/sibling-serial.sh" parts "$PROJECT" > "$SIBP" 2>/dev/null || : > "$SIBP"
  IGNORE="$IGNORE" RM="$RM" STACK_ON="$STACK_ON" \
    "$HERE/sibling-serial.sh" decide "$ROWS" "$INFLIGHT" "$PRS" "$SIBP" > "$SIB" 2>/dev/null || : > "$SIB"
fi

# ── the graph, in one python pass ────────────────────────────────────────────
# ONE PASS, not N² awk forks: on a 100-ticket backlog the pairwise comparison is
# 5000 pairs, and 5000 process spawns per triage tick is a cost nobody asked for.
# THE OVERLAP RULE IS bin/lib/dep-verify-lib.sh:dep_overlap's, transcribed for
# the same reason that one says out loud — two plans conflict when any planned
# path of one equals, or is a path-prefix of, a planned path of the other, with
# one prune in front: an entry that another entry OF THE SAME LIST names a file
# under is dropped (the TK-667 `prisma/migrations/manual` + the .sql under it),
# because the bare directory is where the file lives, not a second claim. A
# directory that appears ALONE still contains everything under it.
# tests/overlap-schedule-test.sh case 8 pins this EQUAL to dep_overlap rather
# than merely similar: a fourth spelling of the rule is a wave that disagrees
# with the gate it feeds. On top of it sit the launch guard's two knobs —
# OVERLAP_IGNORE drops the auto-resolvable paths before any comparison, and
# OVERLAP_THRESHOLD is the same Jaccard bar bin/overlap-guard.sh:judge applies —
# so the tick's two rules agree on which files are worth a delay (case 8b).
MODE="$MODE" TKEY="$TKEY" HOT_MIN="$HOT_MIN" IGNORE="$IGNORE" THRESH="$THRESH" RM="$RM" STACK_ON="$STACK_ON" \
python3 - "$ROWS" "$PRS" "$SIB" <<'PYEOF'
import fnmatch, os, re, sys

MODE = os.environ.get("MODE") or "full"
TKEY = os.environ.get("TKEY") or ""
HOT_MIN = int(os.environ.get("HOT_MIN") or 3)
IGNORE = (os.environ.get("IGNORE") or "").split()
try:
    THRESH = float(os.environ.get("THRESH") or 0)
except ValueError:
    THRESH = 0.0

# The classes this schedule can place. There is deliberately NO rank table here
# any more: bin/preplan-candidates.sh already emits its rows in priority order
# (hot queue lines, then hotfix rows, then the plain queue, then child /
# child-building / ahead / blocked), and a hotfix is marked ONLY by being
# emitted first — its class field stays `ahead`. Re-sorting by (class, ticket
# number) here discarded that and could hand an emergency ticket WAVE 2 behind
# an ordinary one. Two mechanisms for one ordering is how a rule comes to bind
# where nobody meant it, so the classifier's row order IS the order (sortkey
# below) and this list only says which classes are schedulable at all.
READY = ("queued", "child", "child-building", "ahead")

def norm(p):
    p = p.strip().rstrip("/")
    if p.startswith("./"):
        p = p[2:]
    return p

lists, cls, seen = {}, {}, {}
try:
    fh = open(sys.argv[1])
except Exception:
    sys.exit(0)
for idx, line in enumerate(fh):
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 3:
        continue
    k, c, p = parts[0], parts[1], norm(parts[2])
    if not k:
        continue
    cls.setdefault(k, c)
    seen.setdefault(k, idx)
    entry = lists.setdefault(k, set())
    # bin/planned-files-cheap.sh writes which tier produced a list as its first
    # line. Counted as a path it makes every cheap list overlap every other one
    # (dep_norm drops it for exactly this reason).
    if not p or p.upper().startswith("SOURCE:"):
        continue
    entry.add(p)

def prune(files):
    fs = sorted(files)
    return [p for p in fs if not any(q.startswith(p + "/") for q in fs)]

P = {k: prune(v) for k, v in lists.items()}

# The guard's exemption, applied exactly as bin/overlap-guard.sh:prune applies
# it — `case "$f" in $g|*/$g)`, i.e. the whole path matches the glob or the path
# ends in /<glob>. COLLISIONS ONLY: P (the reporting set) keeps every path, PC
# is what the graph compares.
# A read-mostly path (bin/lib/read-mostly.sh) is exempt the same way, by exact
# path, as bin/overlap-guard.sh:prune exempts it.
READ_MOSTLY = set(norm(x) for x in (os.environ.get("RM") or "").split())

def ignored(p):
    if p in READ_MOSTLY:
        return True
    for g in IGNORE:
        if fnmatch.fnmatchcase(p, g) or fnmatch.fnmatchcase(p, "*/" + g):
            return True
    return False

PC = {k: [p for p in v if not ignored(p)] for k, v in P.items()}

# The guard's judge(), transcribed: count the hits over A's pruned entries,
# union = |A| + |B| - hits, and a Jaccard below OVERLAP_THRESHOLD is not a
# collision. At the default threshold of 0 any single hit collides, which is
# what this script did before it shared the knob.
# B= compares against a list that is not a candidate (an open PR's files), and
# exact=True is the guard's OVERLAP_EXACT=1: whole files only, no prefix rule.
def collide(a, b=None, B=None, exact=False):
    A = PC.get(a, ())
    if B is None:
        B = PC.get(b, ())
    hits, first = 0, None
    for p in A:
        for q in B:
            if q == p or (not exact and (q.startswith(p + "/") or p.startswith(q + "/"))):
                hits += 1
                if first is None:
                    first = p if p == q else "%s ~ %s" % (p, q)
                break
    if not hits:
        return None
    union = len(A) + len(B) - hits
    if union < 1:
        union = 1
    if THRESH > 0 and float(hits) / union < THRESH:
        return None
    return first

# THE CLASSIFIER'S ROW ORDER, and nothing else (see READY above). A key this
# schedule somehow saw without a candidate row sorts last rather than first —
# an unknown priority is not the top one.
def sortkey(k):
    return (seen.get(k, 1 << 30), k)

inflight = sorted([k for k, c in cls.items() if c == "inflight"], key=lambda k: k)
cands = sorted([k for k, c in cls.items() if c in READY], key=sortkey)
STACK_ON = (os.environ.get("STACK_ON") or "1") != "0"

# SIBLING PARTS (BH-6374): bin/sibling-serial.sh decide's verdicts. A part that
# must wait for a sibling is HELD before any wave is built, and leaves the waves
# and UNPLANNED. A verdict that is only an open sibling PR (`stackable`) is not
# held while stacked builds are on: the STACK logic below places it on that PR's
# branch, and it is held after all if no STACK line comes of it.
sib_why, sib_stack = {}, {}
try:
    with open(sys.argv[3]) as fh3:
        for line in fh3:
            m = re.match(r"^SIBLING_SERIAL (\S+) waits for (\S+) on (.+?)(?: stackable base=(\S+))?$", line.rstrip("\n"))
            if not m or m.group(1) not in cls:
                continue
            if m.group(4) and STACK_ON:
                sib_stack[m.group(1)] = (m.group(2), m.group(3))
            else:
                sib_why[m.group(1)] = (m.group(2), m.group(3))
except Exception:
    sib_why, sib_stack = {}, {}
cands = [k for k in cands if k not in sib_why]
unplanned = [k for k in cands if not P.get(k)]
placeable = [k for k in cands if P.get(k)]

# HELD is produced ONLY from a positive comparison of two non-empty real file
# lists. Missing data never holds a ticket: that is the difference between this
# being a scheduler and it being an outage.
held, held_why = [], {}
rest = []
for k in placeable:
    hit = None
    for o in inflight:
        c = collide(k, o)
        if c:
            hit = (o, c)
            break
    if hit:
        held.append(k)
        held_why[k] = hit
    else:
        rest.append(k)

waves = []
wave_of, wave_why = {}, {}
for k in rest:
    for i, w in enumerate(waves):
        clash = None
        for m in w:
            c = collide(k, m)
            if c:
                clash = (m, c)
                break
        if clash is None:
            w.append(k)
            wave_of[k] = i + 1
            break
        if k not in wave_why:
            wave_why[k] = clash
    else:
        waves.append([k])
        wave_of[k] = len(waves)

# STACK (BH-1174): a wave-1 key whose plan overlaps exactly ONE open harness PR
# builds on that PR's branch (the stacked-child flow, STACK_BASE) instead of on
# the default branch, where bin/overlap-guard.sh would defer it every tick until
# the PR merged. Only wave 1: a later wave overlaps a candidate with no branch
# yet, and a HELD key is in no wave at all. The PR lists are compared the way the
# guard compares them (OVERLAP_EXACT=1: whole files only, so a planned directory
# that merely contains a PR's file is not a parent), with the same prune and
# OVERLAP_IGNORE. A PR on the key's own branch is its own repair round, skipped
# as the guard skips it. Two colliding PRs is no verdict: one ticket cannot sit
# on two parents, and the launch guard settles it exactly as it did before.
pr_files = {}
try:
    with open(sys.argv[2]) as fh2:
        for line in fh2:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 3 or not parts[0] or not parts[1]:
                continue
            pr_files.setdefault((parts[0], parts[1]), set()).add(norm(parts[2]))
except Exception:
    pr_files = {}
pr_lists = {}
for pk, fs in pr_files.items():
    pl = [p for p in prune(fs) if p and not ignored(p)]
    if pl:
        pr_lists[pk] = pl

stack = {}
if STACK_ON and pr_lists and waves:
    for k in waves[0]:
        lk = k.lower()
        hits = []
        for (num, br), pl in sorted(pr_lists.items(), key=lambda r: (int(r[0][0]) if r[0][0].isdigit() else 1 << 30, r[0][1])):
            if lk in br.lower():
                continue
            c = collide(k, B=pl, exact=True)
            if c:
                hits.append((num, br, c))
        if len(hits) == 1:
            stack[k] = hits[0]

# A stackable sibling the STACK pass did not place is held after all.
late = [k for w in waves for k in w if k in sib_stack and k not in stack]
if late:
    for k in late:
        sib_why[k] = sib_stack[k]
    waves = [w2 for w2 in ([k for k in w if k not in late] for w in waves) if w2]
    wave_of = {}
    for i, w in enumerate(waves):
        for k in w:
            wave_of[k] = i + 1
    stack = {k: v for k, v in stack.items() if waves and k in waves[0]}

def stack_verdict(k):
    num, br, f = stack[k]
    return "base=%s (overlaps open PR #%s on %s)" % (br, num, f)

# HOT FILES: exact paths, over every list this schedule can see — the ready
# candidates, the `blocked` ones (planned but not schedulable), and the builds
# in flight. A file two tickets both plan to edit is the thing the reviewer can
# still do something about.
counts = {}
for k, files in P.items():
    for f in files:
        counts.setdefault(f, set()).add(k)
hot = sorted(((f, sorted(ks, key=sortkey)) for f, ks in counts.items() if len(ks) >= HOT_MIN),
             key=lambda r: (-len(r[1]), r[0]))

def held_line(k):
    if k in sib_why:
        o, c = sib_why[k]
        return "HELD: %s waits for sibling %s on %s (SIBLING_SERIAL)" % (k, o, c)
    o, c = held_why[k]
    return "HELD: %s overlaps in-flight %s on %s" % (k, o, c)

if MODE == "key":
    if TKEY in held_why or TKEY in sib_why:
        print(held_line(TKEY))
    elif TKEY in wave_of:
        n = wave_of[TKEY]
        if TKEY in stack:
            print("%s STACK %s" % (TKEY, stack_verdict(TKEY)))
        elif n == 1:
            print("%s WAVE 1 (shares no planned file with an in-flight build)" % TKEY)
        else:
            m, c = wave_why.get(TKEY, ("?", "?"))
            print("%s WAVE %d (overlaps %s on %s)" % (TKEY, n, m, c))
    elif TKEY in unplanned:
        print("%s UNPLANNED (no pre-plan file list yet — this schedule does not judge it)" % TKEY)
    elif cls.get(TKEY) == "inflight":
        print("%s IN-FLIGHT (already building)" % TKEY)
    sys.exit(0)

if MODE == "hotfor":
    mine = set(P.get(TKEY, ()))
    for f, ks in hot:
        if f not in mine:
            continue
        others = [k for k in ks if k != TKEY]
        if not others:
            continue
        print("this ticket touches %s, shared with %s — consider moving the change to a per-ticket file"
              % (f, " ".join(others)))
    sys.exit(0)

for i, w in enumerate(waves):
    print("WAVE %d: %s" % (i + 1, " ".join(w)))
for k in (waves[0] if waves else ()):
    if k in stack:
        print("STACK: %s %s" % (k, stack_verdict(k)))
for k in held:
    print(held_line(k))
for k in sorted(sib_why, key=sortkey):
    print(held_line(k))
if unplanned:
    print("UNPLANNED: %s" % " ".join(unplanned))
if hot:
    print("HOT-FILES:")
    for f, ks in hot:
        print("%s :: %s%s" % (f, " ".join(ks), " (read-mostly)" if f in READ_MOSTLY else ""))
PYEOF
exit 0
