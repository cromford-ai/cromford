#!/bin/bash
# BH-479: the relay/ledger staging stage of bin/run-triage.sh, to be moved here
# verbatim by BH-479.1; defines functions only, nothing runs on source.
rt_stage() {
# ── STAGING RUNS BEFORE THE GATE (2026-09-11, project-3 TK-139) ───────────────────
# Everything from here down to the gate call moves finished work from the relay
# directory and the ledger onto this box's disk. It used to sit AFTER the gate's
# SKIP exit, so a finished build could only be brought onto the box on a tick
# the gate had already decided to pay for on other grounds. On 2026-09-11 an
# project-3 pool result landed at 01:40Z and the 01:16 / 01:26 / 01:36 / 01:46 ticks
# each exited `rc=skip :: gate queue-unchanged` without once looking at it: the
# PR was open and the client's ticket said nothing.
#
# Staging is deterministic, cheap and makes no model call. A COST gate has no
# business standing in front of it — and there is a second reason to do it
# first: a staged dir is itself one of the inputs the gate hashes, so doing the
# work is also what tells the gate there is something to talk about.
#
# It needs nothing the gate produces: $HARNESS, $PROJECT, $LOG and the client
# sourced above are the whole dependency, and the per-project flock is already
# held, so two ticks of one project still cannot stage one result twice.

# Remote-result jsons -> build dirs the sweep SOP already handles (2026-08-15).
# The gate fires on state/remote-results/$PROJECT/*.json, but no prompt ever
# mentioned that directory and nothing mechanical consumed it — on hub-local
# projects the ingest writes ONLY the json (no build dir), so the session
# swept build dirs, found nothing, left the json, and the gate re-fired every
# tick for hours (project-1, 18 owed tickets starved behind ~$0.40 no-op runs).
# Convert each json into builds/$PROJECT-<KEY>-remote<ts>/RESULT and archive it;
# the session's existing results-sweep then posts the close-out and COMMENTED-
# marks the dir. RESULT_UNVERIFIED first lines still match no handler — by design.
RRDIR="$HARNESS/state/remote-results/$PROJECT"
# WHAT IDENTIFIES A RESULT, now that "the ticket it belongs to" has been shown
# not to (project-3 TK-139). Each path has a name for the build it is staging, and
# the names are NOT the same across paths: bin/run-build.sh's row carries the
# machine's own <project>-<key>-<ts>, while bin/fly-pool.sh's relay json carries
# the hub's copy, pool-<project>-<key>-<ts>. So each guard tests its own path's
# name first — the ledger guard its JOB_ID, the relay guard its build name —
# and both fall back to the CROSS-PATH identity for a staging the OTHER made.
RR_BDNAME() { case "${1:-}" in "") return 1 ;; *) basename "$1" ;; esac; }
# THE CROSS-PATH IDENTITY IS THE MACHINE'S BUILD DIR (BH-1041), and every staged
# dir writes it as its own `BUILT_AS:` line so the other path can find it.
#
# It used to be the RESULT LINE, on the reasoning that both doors carry `head -1`
# of the one file the build wrote. They do not, and three things routinely make
# them differ: bin/fly-pool.sh parks the hub json with `head -c 200`, the reap's
# pr-verify gate rewrites word 1 to RESULT_UNVERIFIED / RESULT_MALFORMED, and a
# builder that posts its own close-out appends `| CLOSED-OUT: …` to the line
# AFTER its row was written. Each divergence staged the build a second time and
# put a second close-out comment on one client's ticket. The line also collapsed
# two genuinely different builds of one ticket whenever they ended in the same
# sentence, which is the opposite mistake.
#
# The machine's build dir has neither failure. It is `basename $BUILD` on the
# builder, written to the ledger row's detail.build_dir by bin/run-build.sh and
# onto the RESULT as `BUILD_DIR:` by fly/builder-runner.sh — from where the two
# relay senders copy it into the json's `machine_build_dir`. It is unique per
# build and no gate rewrites it.
#
# A row or json that carries no such name (a builder older than 2026-09-10, a
# sender older than this change) simply has no cross-path guard: it falls back
# to its OWN path's identity, which is this loop exactly as it behaved before
# the line test existed.
# ...and the path to reach it, for the COMMENTED mark. A bare name lives under
# builds/ (that is where the pool's own fallback scp puts it); an absolute path
# is left alone. The old `[ -d "$bd" ]` was relative to the caller's cwd, which
# no build dir has ever been under.
RR_BDPATH() { case "${1:-}" in "") return 1 ;; /*) printf '%s' "$1" ;;
  *) printf '%s' "$HARNESS/builds/$1" ;; esac; }
# ...and whether the machine that built it ALREADY posted the client's close-out
# (W2-B, 2026-09-14). A builder with the direct path armed comments on the board
# and moves the status itself, then marks its own RESULT line to say so — the
# one thing the relay json, the ledger feed and the hub's ingest all spell
# identically. A staged dir whose result carries that marker is therefore STAGED
# FOR THE RECORD AND MARKED COMMENTED: the work is genuinely handled, and a
# second close-out from a session here lands a second comment on a CLIENT's
# ticket, which is the one mistake in this file with no undo.
#
# bin/lib/builder-direct.sh owns the marker so there is one definition of it. A
# box without the lib (a half-synced tree) simply never applies the guard, which
# is this loop exactly as it behaves today.
# shellcheck source=bin/lib/builder-direct.sh
[ -r "$HARNESS/bin/lib/builder-direct.sh" ] && . "$HARNESS/bin/lib/builder-direct.sh"
# THE CURSOR IS ALSO LEDGER ROWS (BH-7803). bin/lib/rr-cursor.sh writes each
# .handled marker and the .since watermark as a `ledgers` row too, and reads the
# row when the file is gone, so a rebuilt box stages nothing twice. The files
# are still written and read first. A tree without the lib gets file-only shims
# that do exactly what this file did before.
# shellcheck source=bin/lib/rr-cursor.sh
if ! { [ -r "$HARNESS/bin/lib/rr-cursor.sh" ] && . "$HARNESS/bin/lib/rr-cursor.sh"; } \
   && ! { [ -r "$(dirname "${BASH_SOURCE[0]}")/../rr-cursor.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/../rr-cursor.sh"; }; then
  echo "$STAMP [$PROJECT] rr-cursor: bin/lib/rr-cursor.sh not found — the cursor is file-only this tick" >> "$LOG"
  rrc_job_handled() { [ -f "$RRDIR/.handled/$2.job" ]; }
  rrc_job_mark() { : > "$RRDIR/.handled/$2.job"; }
  rrc_since_get() { cat "$RRDIR/.since" 2>/dev/null | tr -dc '0-9A-Za-z:.-'; }
  rrc_since_put() { printf '%s' "$2" > "$RRDIR/.since"; }
  rrc_json_consume() { case "$3" in
    empty|badjson) mv -f "$2" "$RRDIR/.handled/$(basename "$2").$3" ;;
    *) mv -f "$2" "$RRDIR/.handled/$(basename "$2")" ;; esac; }
fi
RR_CLOSED_OUT() { # RR_CLOSED_OUT <result-line> <staged-dir>
  command -v bd_closed_out >/dev/null 2>&1 || return 0
  bd_closed_out "${1:-}" || return 0
  : > "${2:?}/COMMENTED" 2>/dev/null || true
  return 0
}
# WHAT A STAGED RESULT OWES NOBODY (pool doctor, 2026-09-24). Two shapes of
# RESULT-without-COMMENTED never get a close-out from a session, and every
# consumer that reads that pair as "close-out owed" wedged on them:
# bin/triage-gate.sh step 3 held the board diff behind them and
# bin/orphan-reconcile.sh skipped their tickets as awaiting-closeout. The
# account-exhaustion loop of 2026-09-23 left ~250 + ~45 of them on
# box-small and cromford saw no board-changed session for 16h.
#   * BUILD_DEFERRED — the SOP's answer is "nothing", and bin/fly-pool.sh
#     already marks its OWN copy of a deferral with DEFERRED for exactly this
#     reason. The ledger and relay copies now carry the same sentinel, plus
#     COMMENTED, because no session will ever write it.
#   * an older `QUEUED_FLY <KEY>` stub on this box — the routing half of a pool
#     handoff. Once a result for KEY is staged here the stub has been answered,
#     whatever the answer was; bin/queued-fly-relayed.sh only knew the RELAYED
#     pool-* shape, which the ledger path never makes. A stub NEWER than the
#     staged RESULT is a later handoff and is left alone, as is every other key.
RR_NO_CLOSEOUT() { # RR_NO_CLOSEOUT <result-line> <staged-dir> <key>
  local line="${1:-}" dest="${2:?}" key="${3:-}" stub
  case "$line" in
    BUILD_DEFERRED*)
      : > "$dest/DEFERRED" 2>/dev/null
      printf 'staged BUILD_DEFERRED owes no close-out (SOP: BUILD_DEFERRED -> nothing)\n' > "$dest/COMMENTED" 2>/dev/null ;;
  esac
  case "$key" in ''|*[!A-Za-z0-9_-]*) return 0 ;; esac
  for stub in "$HARNESS/builds/$PROJECT-$key-"*/; do
    stub="${stub%/}"
    case "$stub" in "$dest"|*-remote*) continue ;; esac
    [ -f "$stub/RESULT" ] && [ ! -f "$stub/COMMENTED" ] || continue
    [ "$(awk 'NR==1 && $1=="QUEUED_FLY" {print $2}' "$stub/RESULT" 2>/dev/null)" = "$key" ] || continue
    [ "$stub/RESULT" -nt "$dest/RESULT" ] && continue
    printf 'QUEUED_FLY stub answered by %s\n' "$(basename "$dest")" > "$stub/COMMENTED" 2>/dev/null
  done
  return 0
}
# ONE LINE PER PROJECT PER TAG PER DAY. Both loops below have a condition worth
# paging about that then repeats on every tick — a row that keeps failing to
# stage, a result consumed without proof — and at six ticks an hour that is 144
# identical lines a day, which is how a channel stops being read. The per-row
# detail still goes to the project log every time; only the paging is bounded.
# Same per-day flag shape bin/jobs-client.sh uses for its own outage line.
#
# THE TAG IS AN ARGUMENT (BH-1284) so two unrelated conditions cannot silence
# each other: a relay json consumed at 00:05 must not eat the day's alert for a
# ledger row that fails to stage at 00:10. The default is the ledger staging
# tag this function was written for, so that caller is unchanged.
#
# CHASING A MISSING CLOSE-OUT? The page is deduped per PROJECT per TAG per UTC
# DAY, not per row (BH-1957). Only the FIRST failing row of the day reaches
# ALERTS.log; a second row failing the same day, for any ticket, is written to
# logs/<project>.log only. No ALERTS line for your key proves nothing — grep
# logs/<project>.log for it.
RR_ALERT() { # RR_ALERT <line> [flag-tag]
  local flag="$HARNESS/flags/alerted-${2:-ledger-stage}-$PROJECT-$(date -u +%Y%m%d)"
  echo "$STAMP [$PROJECT] $1" >> "$LOG"
  [ -f "$flag" ] && return 0
  mkdir -p "$HARNESS/flags" 2>/dev/null && touch "$flag" 2>/dev/null
  echo "$STAMP [$PROJECT] $1" >> "$ALERTS"
  return 0
}
# A STAGED-DIR NAME NOTHING ELSE HOLDS (BH-1284). The name carries a UTC stamp
# at SECOND resolution and the two loops below stage within seconds of each
# other, so two stagings in one second used to resolve to one `mkdir -p` into
# the SAME directory — the second silently overwriting the first's RESULT. That
# is a lost close-out when the two are different builds, and for a year it was
# also what made tests/fly-lane-db-test.sh §4b pass: the duplicate it asserts
# against landed on top of the original and the directory count stayed at one.
# The timestamp stays, because a staged dir is also this box's history of when
# work arrived; the collision does not.
RR_DEST() { # RR_DEST <key>
  local base d n=2
  base="$HARNESS/builds/$PROJECT-$1-remote$(date -u +%Y%m%d%H%M%S)"
  d="$base"
  while [ -e "$d" ] && [ "$n" -le 99 ]; do d="$base-$n"; n=$((n+1)); done
  printf '%s' "$d"
}
# WHICH PATH STAGED WHAT IS ALREADY ON DISK FOR A TICKET (BH-1284). Each loop
# stamps its own marker into the RESULT it writes — the relay loop a
# `BUILD_DIR:` line, the ledger loop a `JOB_ID:` line — so "has the OTHER path
# staged something for this ticket" is a question about those two lines and
# nothing else. Deliberately not a question about the dir NAME: the name is a
# timestamp, and a timestamp is not an identity.
RR_KEY_HAS_ANY() { ls "$HARNESS/builds/$PROJECT-$1-remote"*/RESULT >/dev/null 2>&1; }
RR_KEY_HAS_MARK() { # RR_KEY_HAS_MARK <key> <marker>
  grep -l "^$2: " "$HARNESS/builds/$PROJECT-$1-remote"*/RESULT >/dev/null 2>&1
}
if ls "$RRDIR"/*.json >/dev/null 2>&1; then
  mkdir -p "$RRDIR/.handled"
  for RRF in "$RRDIR"/*.json; do
    RRKEY=$(jq -r '.key // ""' "$RRF" 2>/dev/null)
    [ -n "$RRKEY" ] || { rrc_json_consume "$PROJECT" "$RRF" badjson; continue; }
    # THE RECIPROCAL GUARD (2026-09-10). The ledger loop below skips a key this
    # loop has already staged; without the same test here the two paths race in
    # the other direction. The artifact row lands the moment the build ends and
    # the relay json arrives a tick later, so a result staged from the ledger on
    # one tick would be staged AGAIN from the json on the next — two build dirs
    # for one build, and two close-out comments on a client's ticket. The json
    # is consumed rather than left, and its own build dir is marked COMMENTED,
    # so the custody checks see the work as handled exactly once.
    #
    # KEYED ON THE BUILD, NOT THE TICKET (2026-09-11, project-3 TK-139). The test
    # used to be "does ANY builds/<project>-<KEY>-remote* dir exist", and a
    # ticket is built more than once as a matter of course — a deferral, a fix
    # round, a re-queue. One older dir therefore ate every later result for that
    # ticket and this loop reported it as a duplicate it had handled.
    RRBD0=$(jq -r '.build_dir // ""' "$RRF" 2>/dev/null)
    RRBDN=$(RR_BDNAME "$RRBD0") || RRBDN=""
    RRMBD=$(jq -r '.machine_build_dir // ""' "$RRF" 2>/dev/null)
    RRRES=$(jq -r '.result // ""' "$RRF" 2>/dev/null | head -1)
    RRSTAGED=0
    [ -n "$RRBDN" ] && grep -qxF "BUILD_DIR: $RRBDN" \
      "$HARNESS/builds/$PROJECT-$RRKEY-remote"*/RESULT 2>/dev/null && RRSTAGED=1
    # ...and the build the MACHINE ran, which is what a dir staged from the
    # LEDGER is named after. Guarded on non-empty: an older sender's absent
    # field must not match an absent BUILT_AS: line and eat a real result.
    [ "$RRSTAGED" = 0 ] && [ -n "$RRMBD" ] && grep -qxF "BUILT_AS: $RRMBD" \
      "$HARNESS/builds/$PROJECT-$RRKEY-remote"*/RESULT 2>/dev/null && RRSTAGED=1
    # A JSON WITH NO CROSS-PATH IDENTITY IS NOT PROOF OF A NEW BUILD (BH-1284).
    # `machine_build_dir` is empty on every json whose builder or sender predates
    # BH-1041, and for those the guard above cannot fire at all — so the loop
    # staged a second dir for a build the LEDGER had already staged seconds
    # earlier and a second close-out comment landed on a client's ticket. The
    # hub's builds/ carries ~20 such pairs from one drain on 2026-09-17: the same
    # ticket, the same PR, four seconds apart, one dir with `BUILD_DIR:` and one
    # with `JOB_ID:`.
    #
    # What is still decidable without that identity is which path staged what,
    # because each stamps its own marker. If the relay path has staged something
    # for this ticket already and none of those dirs is this json's build, this
    # json IS a new build and must be staged — that is project-3 TK-139 and
    # tests/fly-lane-db-test.sh §4f. If every dir for the ticket came from the
    # LEDGER, this json is the relay copy of one of them and staging it posts the
    # second comment.
    #
    # It is a choice between two bad outcomes and the asymmetry decides it: a
    # duplicate close-out on a client's ticket has no undo, a consumed result
    # does — the ledger already staged the close-out this json carries. It fires
    # only for senders older than BH-1041, it pages once a day, and the project
    # log names the ticket every time, so a genuinely stranded result is visible
    # rather than silent.
    #
    # AND IT NEEDS POSITIVE PROOF (BH-1301). The test used to be "this ticket has
    # SOME staged dir and none of them is mine", which is also true when no dir
    # carries EITHER marker — and the hub makes exactly those: until BH-1301
    # bin/review-rescue.sh rewrote a rescued RESULT down to three lines and
    # dropped every provenance line it had. So a ticket whose only history was a
    # rescued dir consumed the next result it saw and posted no close-out at all.
    # Consuming is only justified by a dir that says the LEDGER staged this
    # ticket, so that is what is asked for now.
    if [ "$RRSTAGED" = 0 ] && [ -z "$RRMBD" ] && RR_KEY_HAS_ANY "$RRKEY"; then
      if RR_KEY_HAS_MARK "$RRKEY" JOB_ID; then
        if RR_KEY_HAS_MARK "$RRKEY" BUILD_DIR; then
          # BOTH paths have staged this ticket before, and this json names no
          # build: it is either a third build or the relay copy of one of the
          # two, and nothing on disk can tell. Staging is the half with an undo
          # — a duplicate dir is visible, a consumed result is not — so it
          # stages, and unlike before it says so every tick and pages once a day
          # under its own tag (BH-1301).
          RR_ALERT "relay json $RRKEY (build ${RRBDN:-?}) carries no cross-path identity and this ticket has been staged by BOTH paths before — staged anyway; if it is the other path's copy of one build, this is the second close-out (BH-1301)" relay-bypass
        else
          RRSTAGED=1
          RR_ALERT "relay json for $RRKEY carries no cross-path identity (sender older than BH-1041) and this ticket is already staged from the ledger — consumed rather than posting a second close-out; if that was a NEW build its close-out is in the ledger row, not here" relay-consume
        fi
      elif ! RR_KEY_HAS_MARK "$RRKEY" BUILD_DIR; then
        echo "$STAMP [$PROJECT] relay json for $RRKEY carries no cross-path identity and no staged dir for this ticket carries either path's marker — staged, not consumed: nothing here says the ledger ever staged this build (BH-1301)" >> "$LOG"
      fi
    fi
    if [ "$RRSTAGED" = 1 ]; then
      RRBP=$(RR_BDPATH "$RRBD0") && [ -d "$RRBP" ] && touch "$RRBP/COMMENTED" 2>/dev/null
      rrc_json_consume "$PROJECT" "$RRF" duplicate "$RRBDN"
      echo "$STAMP [$PROJECT] relay json for $RRKEY (build ${RRBDN:-?}) is already staged — consumed, not staged twice" >> "$LOG"
      continue
    fi
    RRDEST=$(RR_DEST "$RRKEY")
    mkdir -p "$RRDEST"
    jq -r '.result // ""' "$RRF" > "$RRDEST/RESULT"
    [ -s "$RRDEST/RESULT" ] || { rmdir "$RRDEST" 2>/dev/null; rrc_json_consume "$PROJECT" "$RRF" empty "$RRBDN"; continue; }
    jq -r '"TICKET_ID: \(.ticket_id // "")\nSOURCE: remote (\(.source // "fly"))\nINGESTED: \(.ingested_at // "")"' "$RRF" >> "$RRDEST/RESULT"
    # THE PROVENANCE LINE (2026-09-11), and this loop's own re-entry guard.
    # Until now the only identity a staged dir carried was its own NAME, and the
    # name is keyed on the ticket — which is exactly why the guard above could
    # not tell two builds of one ticket apart.
    [ -n "$RRBDN" ] && printf 'BUILD_DIR: %s\n' "$RRBDN" >> "$RRDEST/RESULT"
    # ...and the cross-path one, for the ledger loop below to find. A json with
    # neither identity is staged on its own and says so: it is the only shape
    # left that two paths could stage twice, and it is worth being able to read
    # that in the project log rather than guessing at it from two dirs.
    if [ -n "$RRMBD" ]; then
      printf 'BUILT_AS: %s\n' "$RRMBD" >> "$RRDEST/RESULT"
    else
      echo "$STAMP [$PROJECT] relay json for $RRKEY has no cross-path identity on this json (older sender) — staged on its own" >> "$LOG"
    fi
    RR_CLOSED_OUT "$RRRES" "$RRDEST"
    RR_NO_CLOSEOUT "$RRRES" "$RRDEST" "$RRKEY"
    # The reap's own pool-* dir is handled THROUGH this staged copy — mark it
    # so the un-commented check doesn't double-count one piece of work forever.
    RRBP=$(RR_BDPATH "$RRBD0") && [ -d "$RRBP" ] && touch "$RRBP/COMMENTED" 2>/dev/null
    rrc_json_consume "$PROJECT" "$RRF" staged "$RRBDN"
    echo "$STAMP [$PROJECT] remote-result $RRKEY staged as $(basename "$RRDEST") for the sweep" >> "$LOG"
  done
fi

# --- Remote results PULLED, not pushed (2026-09-10) ---------------------------
# The loop above consumes results that arrived as FILES, pushed onto this box
# over scp by bin/fly-pool.sh / bin/fly-results-ingest.sh. That push is the last
# reason a fly machine or the hub needs a path INTO a watcher box, and when it
# fails the whole close-out strands (TK-124 sat a day until a medic
# hand-delivered it). This loop asks the ledger for the same facts instead.
#
# ONLY BUILDS FROM ANOTHER BOX. bin/run-build.sh records a `result` artifact on
# every box, including this one — uniform on purpose, so nothing about the row
# is fly-specific. Staging our OWN builds here would post a second close-out for
# a build whose dir is already sitting in builds/ waiting for the sweep, so the
# box column is checked and it is the whole guard.
#
# IDEMPOTENT ON THE JOB ID: one marker file per job, in the same .handled
# directory the file path already uses. A row is read many times (the feed is a
# window, not a queue) and must be staged exactly once.
#
# Fail-open and silent: no client, no worker, no rows, and everything below
# behaves exactly as it did before this block existed.
if command -v job_artifact_feed >/dev/null 2>&1; then
  mkdir -p "$RRDIR/.handled"
  MYBOX="${JOBS_BOX:-}"
  # THE WATERMARK, and why a box-local .handled marker was not enough. The feed
  # is a WINDOW (newest 50), not a queue, so every tick re-reads the same rows
  # and the markers are all that stop a re-stage. Markers live on this box: a
  # rebuilt or restored box has none, and its first tick would stage up to fifty
  # close-outs for tickets that were closed out weeks ago — a client watching
  # fifty comments arrive at once. The watermark is the durable half: ask only
  # for rows newer than the last one seen, so an empty .handled directory
  # replays nothing rather than everything.
  # The file first, else the project's rr-since row (BH-7803): a rebuilt box
  # with no file still asks only for rows newer than the last one staged.
  RRSINCE=$(rrc_since_get "$PROJECT")
  RRMAX="$RRSINCE"
  # ANY failure in this pass freezes the watermark for the WHOLE pass. Advancing
  # per row is not enough and the reason is worth stating: the feed is ordered
  # newest-first, so a NEWER row that this box deliberately skips would carry the
  # watermark past an OLDER row that failed to stage — burying it for ever. The
  # rows that did succeed are protected by their own .handled markers, so
  # re-reading them next tick costs one comparison and stages nothing twice.
  RRFAILED=0
  # The newest row this project HAS, as opposed to the newest one this box is
  # DONE with. See the write below the loop for why those must not be the same
  # number.
  RRSEEN=""
  # The alert this loop pages through — ONE LINE PER PROJECT PER DAY while a row
  # keeps failing, because freezing the watermark is what makes the row retry and
  # the SAME failure therefore comes back every tick. It is defined at the top of
  # this file now (BH-1284) so the relay loop above can page through it too,
  # under its own tag; `RR_ALERT <line>` here is unchanged.
  while IFS="$(printf '\t')" read -r RJOB RREF RBOX RTID RTS RDET; do
    [ -n "${RJOB:-}" ] && [ -n "${RREF:-}" ] || continue
    case "$RRSEEN" in "") RRSEEN="$RTS" ;; *) [ "$RTS" \> "$RRSEEN" ] && RRSEEN="$RTS" ;; esac
    # THE WATERMARK ADVANCES ONLY FOR A ROW THIS TICK IS DONE WITH — either
    # deliberately skipped or successfully staged. It used to advance at the top
    # of the loop for every row, which was right for the skips (a row this box
    # will always skip must not be re-read for ever) and WRONG for a staging
    # failure: a row whose mkdir or RESULT write failed would be marked past and
    # never seen again, and the close-out it carried would be lost silently.
    RR_DONE() { case "$RRMAX" in "") RRMAX="$RTS" ;; *) [ "$RTS" \> "$RRMAX" ] && RRMAX="$RTS" ;; esac; }
    [ -n "$MYBOX" ] && [ "$RBOX" = "$MYBOX" ] && { RR_DONE; continue; }
    rrc_job_handled "$PROJECT" "$RJOB" && { RR_DONE; continue; }
    RKEY=$(printf '%s' "${RDET:-}" | jq -r '.key // ""' 2>/dev/null)
    [ -n "$RKEY" ] || RKEY="$RJOB"
    # KEYED ON THE JOB, NOT THE TICKET (2026-09-11, project-3 TK-139). A dir already
    # staged from the FILE path means the scp made it after all and this row is
    # a duplicate of work in hand — but "a dir for this key" was far too coarse.
    # TK-139 had an earlier attempt that day (a BUILD_DEFERRED, COMMENTED long
    # since) still sitting in builds/, so the real build's result row was marked
    # `.handled` and skipped FOR EVER. The PR was open; the ticket never heard.
    #
    # Two identities, because the two paths name the same build differently.
    # JOB_ID is this loop's own and is always present. The cross-path one is the
    # MACHINE'S build dir (BH-1041): this row carries it as detail.build_dir,
    # the relay json carries the same string as machine_build_dir, and whichever
    # path stages first writes it into the staged RESULT as `BUILT_AS:`. Without
    # that half, a result the relay staged a tick ago is staged a second time
    # from its row: two close-out comments on one client ticket.
    #
    # NOT the result line, which is what this used to compare. The hub json
    # truncates it at 200 bytes, the pool's pr-verify gate rewrites its first
    # word and a builder's own close-out appends to it — so equal text meant
    # "sometimes the same build", and different text meant nothing at all.
    #
    # Deliberately NOT the .handled/<key>.json markers: those belong to the
    # relay path, they are keyed on the ticket, and reading them here would put
    # the ticket-keyed blocking straight back.
    RBDIR=$(printf '%s' "${RDET:-}" | jq -r '.build_dir // ""' 2>/dev/null)
    RSTAGED=0
    grep -qxF "JOB_ID: $RJOB" "$HARNESS/builds/$PROJECT-$RKEY-remote"*/RESULT 2>/dev/null && RSTAGED=1
    [ "$RSTAGED" = 0 ] && [ -n "$RBDIR" ] && grep -qxF "BUILT_AS: $RBDIR" \
      "$HARNESS/builds/$PROJECT-$RKEY-remote"*/RESULT 2>/dev/null && RSTAGED=1
    # THE SAME FALLBACK, THE SAME WAY ROUND (BH-1284). A row whose builder
    # predates BH-1041 carries no detail.build_dir, so the cross-path half of the
    # guard above cannot fire and this loop stages a second dir for a build the
    # RELAY json staged seconds earlier — which is the order the hub's 2026-09-17
    # pairs actually landed in: the relay dir at 22:08:17, the ledger dir at
    # 22:08:21, same ticket, same PR, two close-out comments.
    #
    # The marker each path stamps is what is left to read. If the ledger path has
    # staged something for this ticket already and none of those rows is this
    # job, this row IS a different build and must be staged — project-3 TK-139, and
    # §4e asserts it (its row carries a build_dir, so this fallback never runs
    # for it). If every dir for the ticket came from the RELAY, this row is the
    # ledger copy of one of them.
    #
    # AND THE SAME POSITIVE PROOF (BH-1301): only a dir that says the RELAY
    # staged this ticket justifies skipping this row. A ticket whose dirs carry
    # neither marker — a rescued RESULT, before BH-1301 taught the rescue to keep
    # its provenance — proves nothing, and skipping there loses the close-out for
    # good: nothing re-reads a row with a `.handled` marker.
    if [ "$RSTAGED" = 0 ] && [ -z "$RBDIR" ] && RR_KEY_HAS_ANY "$RKEY"; then
      if RR_KEY_HAS_MARK "$RKEY" BUILD_DIR; then
        if RR_KEY_HAS_MARK "$RKEY" JOB_ID; then
          # Undecidable, same as the relay loop above: stage (the reversible
          # outcome), log it every tick, page once a day under `relay-bypass`.
          RR_ALERT "ledger result $RKEY (job $RJOB) carries no cross-path identity and this ticket has been staged by BOTH paths before — staged anyway; if it is the other path's copy of one build, this is the second close-out (BH-1301)" relay-bypass
        else
          RSTAGED=1
          RR_ALERT "ledger result $RKEY (job $RJOB) carries no cross-path identity (builder older than BH-1041) and this ticket is already staged from the relay — skipped rather than posting a second close-out; if that was a NEW build its close-out is in the relay json, not here" relay-consume
        fi
      elif ! RR_KEY_HAS_MARK "$RKEY" JOB_ID; then
        echo "$STAMP [$PROJECT] ledger result $RKEY (job $RJOB) carries no cross-path identity and no staged dir for this ticket carries either path's marker — staged, not consumed: nothing here says the relay ever staged this build (BH-1301)" >> "$LOG"
      fi
    fi
    if [ "$RSTAGED" = 1 ]; then
      rrc_job_mark "$PROJECT" "$RJOB" "$RKEY" consumed; RR_DONE; continue
    fi
    RDEST=$(RR_DEST "$RKEY")
    # EVERY WRITE IS CHECKED, and a failed one leaves the row untouched: no
    # .handled marker and no watermark advance, so the next tick tries again.
    # A full disk is the ordinary way this fails, and it is exactly the moment a
    # silently-dropped close-out would be hardest to notice.
    if ! mkdir -p "$RDEST" 2>/dev/null; then
      RR_ALERT "could not create $RDEST for ledger result $RKEY (job $RJOB) — left unstaged for the next tick"
      RRFAILED=1; continue
    fi
    # THE FILE THE LINE NAMES (BH-531), fetched before the RESULT is written.
    # A blocked result is a POINTER — `PLAN_BLOCKED <build dir>/plan.md` — and on
    # a pool build that path belongs to a machine that was destroyed at reap. The
    # builder pushes the body to the ledger as a transcript row; this is the half
    # that brings it down, writes it beside the staged RESULT and points line 1
    # at the local copy, so the sweep's existing "quote the plan's questions"
    # path works with no change at all.
    #
    # ORDER MATTERS: the file lands on disk first and the path is rewritten only
    # after it is there, non-empty. A RESULT naming a staged file that does not
    # exist is therefore impossible by construction — which is the failure this
    # whole ticket is about, and it must not be reintroduced one layer down.
    RBLINE="$RREF"; RBFILE=""; RBRE=""; RBSRC=""
    case "$RREF" in
      "PLAN_BLOCKED "*)     RBFILE=plan.md;           RBRE='plan\.md';           RBSRC=plan_md ;;
      "REVIEW_BLOCKED "*)   RBFILE=review.md;         RBRE='review\.md';         RBSRC=review_md ;;
      "DECOMPOSE_FAILED "*) RBFILE=decompose-run.txt; RBRE='decompose-run\.txt'; RBSRC=decompose_run ;;
    esac
    if [ -n "$RBFILE" ] && command -v job_transcript_get_source >/dev/null 2>&1; then
      if job_transcript_get_source "$RJOB" "$RBSRC" > "$RDEST/$RBFILE.tmp" 2>/dev/null \
         && [ -s "$RDEST/$RBFILE.tmp" ] \
         && { [ "${JOBS_TRANSCRIPT_TRUNCATED:-0}" = 1 ] \
                && printf '[tail only: the ledger keeps the last %s bytes of this file]\n\n' "${TRANSCRIPT_MAX_BYTES:-150000}"
              cat "$RDEST/$RBFILE.tmp"; } > "$RDEST/$RBFILE" 2>/dev/null \
         && [ -s "$RDEST/$RBFILE" ]; then
        rm -f "$RDEST/$RBFILE.tmp"
        # ONE PATH TOKEN, anchored at both ends. `[^ ]*/` forces a real directory
        # separator in front — without it `…/preplan.md` matches `plan\.md` and
        # the line is rewritten to name a file this box never wrote — and
        # `\( \|$\)` forces the token to END there, so `decompose-run.txt` in the
        # middle of a sentence is still substituted but nothing longer is. The
        # verdict word at the head of the line is never touched, which is what
        # bin/pipeline-health.sh and bin/queued-fly-relayed.sh read.
        case "$RDEST" in
          *[\#\&\\]*) ;;
          *) RBLINE=$(printf '%s' "$RREF" | sed "s#[^ ]*/$RBRE\( \|\$\)#$RDEST/$RBFILE\1#g") || RBLINE="$RREF" ;;
        esac
        [ -n "$RBLINE" ] || RBLINE="$RREF"
      else
        # NOT AN ALERT. Every box in the fleet runs builders on a bin/ older than
        # this change for as long as propagation takes, and each of their blocked
        # results would page. The close-out still stages with the builder's own
        # line — today's behaviour exactly — and the log says the sweep will have
        # nothing to quote.
        rm -f "$RDEST/$RBFILE.tmp" "$RDEST/$RBFILE"
        echo "$STAMP [$PROJECT] ledger result $RKEY (job $RJOB): no $RBSRC body on file — staged with the builder's own path; the sweep cannot quote it" >> "$LOG"
      fi
    fi
    if ! {
      printf '%s\n' "$RBLINE"
      printf 'TICKET_ID: %s\n' "${RTID#-}"
      printf 'SOURCE: remote (ledger, built on %s)\n' "${RBOX:-?}"
      printf 'JOB_ID: %s\n' "$RJOB"
      # The MACHINE's own build dir — the cross-path identity the relay loop
      # above looks for when its json arrives a tick later (BH-1041).
      [ -n "$RBDIR" ] && printf 'BUILT_AS: %s\n' "$RBDIR"
      # The builder's own sentence, kept verbatim. It is no longer a duplicate
      # test — BUILT_AS: is — but a rewritten line loses what the build actually
      # concluded, and the sweep quotes this when it explains a blocked result
      # (BH-531). Readers of it are unaffected by the identity change.
      [ "$RBLINE" = "$RREF" ] || printf 'ORIGINAL_RESULT: %s\n' "$RREF"
    } > "$RDEST/RESULT" 2>/dev/null; then
      # Remove the half-made dir: a build dir with no RESULT is invisible to the
      # sweep but WOULD match the already-staged guard above, so leaving it would
      # make the next tick skip the row it just failed to write.
      case "$RDEST" in "$HARNESS/builds/"*) rm -rf "$RDEST" 2>/dev/null ;; esac
      RR_ALERT "could not write RESULT for ledger result $RKEY (job $RJOB) — left unstaged for the next tick"
      RRFAILED=1; continue
    fi
    RR_CLOSED_OUT "$RREF" "$RDEST"
    RR_NO_CLOSEOUT "$RREF" "$RDEST" "$RKEY"
    rrc_job_mark "$PROJECT" "$RJOB" "$RKEY" "$(basename "$RDEST")"
    RR_DONE
    echo "$STAMP [$PROJECT] remote-result $RKEY pulled from the ledger (built on ${RBOX:-?}) staged as $(basename "$RDEST") for the sweep" >> "$LOG"
  done <<RRFEED
$(job_artifact_feed result "$PROJECT" "$RRSINCE" 50 2>/dev/null)
RRFEED
  # Written AFTER the loop, only when it advanced, and only when EVERY row in
  # the pass was accounted for: a crash mid-loop or a single failed staging
  # leaves the old watermark, the rows are re-read next tick, and the .handled
  # markers stop the duplicates. The two guards cover each other's failure.
  [ "$RRFAILED" = 0 ] && [ -n "$RRMAX" ] && [ "$RRMAX" != "$RRSINCE" ] \
    && rrc_since_put "$PROJECT" "$RRMAX"
  # A ROW THE GATE CAN SEE (2026-09-11, project-3 TK-139). bin/triage-gate.sh's queue
  # brake hashes FILES — READY-QUEUE.log, the queue dir, the build dirs — and
  # holds a 45-minute skip window over them. While results arrived by scp, a
  # finished build changed one of those files by accident. As a row it changes
  # none of them: the pool result landed at 01:40Z and four ticks in a row
  # exited `gate queue-unchanged` with the PR open. This file is the row made
  # visible to a gate that can only read files.
  #
  # RRSEEN, not RRMAX: the watermark advances only for rows this box ACCOUNTED
  # FOR, so a row whose staging failed would leave it frozen — and a failed
  # staging is exactly when the gate most needs to open. The question this file
  # answers is "what is the newest result row for this project", which is true
  # whoever built it and whether or not the staging above worked.
  [ -n "$RRSEEN" ] && [ "$RRSEEN" != "$(cat "$HARNESS/state/$PROJECT.result-rows" 2>/dev/null)" ] && {
    mkdir -p "$HARNESS/state" 2>/dev/null
    printf '%s\n' "$RRSEEN" > "$HARNESS/state/$PROJECT.result-rows" 2>/dev/null
  }
fi
}
