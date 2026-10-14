#!/bin/bash
# bin/fly-results-ingest.sh <project> | sweep — pull a finished Fly build's RESULT
# + artifacts back to the hub, hand results to the owning watcher, clear builder
# and hub state. Runs on the HUB. Invoked by fly-dispatch.sh when it sees a
# RESULT, and standalone as a cron */2 sweep (`sweep` = all active-job projects).
#
# TRANSPORT (task brief, HARD-WON): pull over Fly's ssh/sftp (`flyctl ssh console
# -C` for RESULT + small text, `flyctl ssh sftp get` for artifacts), NOT tailnet
# ssh. Clear the builder's /run/harness/{RESULT,job.json} via `console -C rm`.
# DB FIRST (BH-2625): RESULT, pipeline.log and evidence.md come from the
# builder's `fly_result` row when there is a usable one (fly_result_db below),
# so a flyctl outage no longer strands a finished build. No row, an unreachable
# worker, or a truncated/unusable row -> the console cat above, unchanged. The
# log line says which: `source=db` or `source=sftp (<why>)`. Every other
# artifact, and the rm, still go over flyctl.
#
# HAND-OFFS to the OWNING watcher box (board writes + merge authority stay there):
# BOOKKEEPING WHEN THE BUILDER ALREADY DELIVERED (W2-B, 2026-09-14). A builder
# with the direct path armed posts its own board close-out and writes its own
# terminal result to the jobs ledger (bin/lib/builder-direct.sh, docs/
# HUB-THINNING-PLAN.md). This script then has nothing to relay: it still pulls
# the artifacts, clears the builder, keeps the idempotent tier-1 merge ROW and
# marks custody RELAYED — and it writes NO state/remote-results json and sends
# NO ssh, because a second copy of a close-out that already landed is a second
# comment on a client's ticket. That missing json is also what ends the
# "remote-result unconsumed >30m" alerts: nothing parks, so nothing goes stale.
# BUILDER_DIRECT=0 / flags/builder-direct-off restores the relay below exactly.
#
# AND A THIRD ANSWER: HELD (BH-1041). Asking the ledger can FAIL, and a failure
# is not "no row". Until now it fell back to the relay, so a worker outage
# pushed a copy of a result whose row existed and the owning box staged the
# build twice. On rc 2 this script now does NOTHING: the builder keeps its
# /run/harness/RESULT and job.json, the hub keeps its active-job row, the fresh
# build dir is removed, and the */2 sweep asks again in two minutes. One line
# per key says so — not one per tick, because the outage outlives the tick.
#
#   - Always: scp the RESULT summary to
#       <box>:/root/harness/state/remote-results/<project>/<KEY>.json so the
#     watcher's next triage pass posts the ticket comment exactly as for a local
#     build.
#   - RESULT PR_CREATED + TIER: 1 + VERDICT APPROVE: also
#       touch <box>:/root/harness/state/merge-queue/<project>/<prnum>
#     so the watcher's own merge-queue cron rebases/lands it with all ITS gates
#     (automerge-disabled, typecheck, deploy hand-off). The builder never merges.
set -uo pipefail

ARG="${1:?usage: fly-results-ingest.sh <project>|sweep}"
# Overridable so this lane can be DRIVEN against a scratch tree — the same change
# bin/run-build.sh, bin/review-prs.sh and bin/merge-sweep.sh took for the same
# reason (docs/DB-COORDINATION-SPEC.md, phase 4). Cron sets nothing, so
# production resolves to exactly the path it always has.
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
# shellcheck source=bin/lib/flag-on.sh
. "$HARNESS/bin/lib/flag-on.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/flag-on.sh" 2>/dev/null || flag_on() { [ -f "$HARNESS/flags/$1-$2" ]; }

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-fly-results-ingest
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off fly-results-ingest.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
# The ONE verdict reader (bin/lib/verdict-parse.sh, BH-1625). Missing, every
# verdict reads unknown — never APPROVE.
. "${HARNESS:-/root/harness}/bin/lib/verdict-parse.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/verdict-parse.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit fly-results-ingest
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    fly-results-ingest
FLYENV="$HENV/fly.env"
STATE_DIR="$HARNESS/state/fly"
BIN="$HARNESS/bin"
DLOG="$HARNESS/logs/fly-dispatch.log"

# HOW LONG A HELD RESULT MAY STAY HELD (BH-1041, round-1 fix).
# The hold below leaves the finished RESULT on the builder. The builder does not
# wait for ever: fly/builder-runner.sh idles IDLE_TIMEOUT=600s after a job cycle
# and then exits 0, which stops the machine and takes its tmpfs — and once the
# machine is `stopped` with an active-job row, bin/fly-dispatch.sh step (2) reads
# that as "builder died mid-build" and requeues, then `.failed`s the ticket on
# attempt 2. So the hold MUST expire before the autostop does, and on expiry the
# hub relays exactly as an rc-1 read would.
#
# THE ARITHMETIC IS THE WHOLE POINT. The flag is stamped by the first sweep after
# the RESULT appears, so it can already be up to one sweep (120s) behind the
# builder's idle clock, and the expiry is noticed by the first sweep at or after
# the cap, up to another 120s later. 240 + 240 = 480s, which leaves two minutes
# of the builder's ten before it walks. Raising this above ~350 re-opens the bug.
#
# RELAYING ON EXPIRY IS SAFE, WHICH IS WHY EXPIRY IS THE ANSWER. Since BH-1041
# the staged copy carries `BUILT_AS: <machine build dir>` and the owning box
# drops a relay whose build it already staged from the ledger row, so the worst
# case of a relay that turns out to have been redundant is a no-op on the box —
# against a ticket marked `.failed` and a paged fleet if the hold is unbounded.
RELAY_HOLD_MAX_S="${RELAY_HOLD_MAX_S:-240}"

STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
say()   { echo "$(STAMP) [fly-ingest/${1:-}] ${2:-}" | tee -a "$DLOG" >&2; }

# Which url on a pool record is that record's OWN pr (BH-848). Guarded: an older
# hub keeps the first-url grep at the parse block below.
# shellcheck source=bin/lib/result-pr-url.sh
[ -r "$HARNESS/bin/lib/result-pr-url.sh" ] && . "$HARNESS/bin/lib/result-pr-url.sh"

command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 1; }
[ -f "$FLYENV" ] || { echo "$FLYENV missing — hub-only" >&2; exit 0; }
FLY=$(command -v fly || command -v flyctl || true)
[ -n "$FLY" ] || { echo "flyctl not installed" >&2; exit 1; }
set -a; . "$FLYENV"; set +a

# shellcheck source=/dev/null
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"
# shellcheck source=bin/lib/builder-direct.sh
[ -r "$HARNESS/bin/lib/builder-direct.sh" ] && . "$HARNESS/bin/lib/builder-direct.sh"

tok_var() { echo "FLY_API_TOKEN_$(echo "$1" | tr '[:lower:].-' '[:upper:]__')"; }

# THE REGISTRY ANSWERS THIS (2026-09-11). This was one of nine copies of the
# same table across bin/ — a box that moved had to be found in all nine, and
# until fleet.conf grew a `tailnet_ip` column it genuinely could not answer.
# Unknown prints nothing and returns 1: callers fail closed rather than ssh
# to `root@`, which hangs instead of erroring.
owning_box_ip() {
  "$HARNESS/bin/fleet-conf.sh" --tailnet-ip "$1" 2>/dev/null
}

beat() { "$BIN/beat.sh" "$1" >/dev/null 2>&1 || true; }

# fly_result_db <project> <key> <since> <builddir> (BH-2625)
#   The builder's `fly_result` row (fly/builder-runner.sh fly_result_put) as
#   RESULT, pipeline.log and evidence.md in <builddir>, without flyctl.
#   rc 0 -> wrote them
#   rc 1 -> could not ask: no jobs client here, or a read failed
#   rc 2 -> not asked: no <since> to bound the read by
#   rc 3 -> answered, no row for this key since <since>
#   rc 4 -> a row, but unusable: not JSON, another key, truncated, empty result,
#           or its result's line 1 is not its ref. Nothing written.
#   rc 5 -> a usable row that could not be written to disk. Nothing left.
#   <since> is THIS attempt's enqueue time, so an older build's row of the same
#   key is never read as this one's.
fly_result_db() {
  local p="$1" key="$2" since="$3" bd="$4" feed job detail ref rc
  command -v job_artifact_feed >/dev/null 2>&1 && command -v job_artifact_detail >/dev/null 2>&1 \
    && command -v job_artifacts >/dev/null 2>&1 || return 1
  [ -n "$since" ] || return 2
  feed=$(job_artifact_feed fly_result "$p" "$since" 20) || return 1
  job=$(printf '%s\n' "$feed" | awk -F'\t' -v k="\"key\":\"$key\"" 'NF>=6 && index($6, k) {print $1; exit}')
  [ -n "$job" ] || return 3
  detail=$(job_artifact_detail fly_result "$job"); rc=$?
  case "$rc" in 0) ;; 3) return 3 ;; *) return 1 ;; esac
  ref=$(job_artifacts "$job") || return 1
  ref=$(printf '%s\n' "$ref" | awk -F'\t' '$1=="fly_result" {print $2; exit}')
  printf '%s' "$detail" | jq -e --arg k "$key" --arg r "$ref" '
    .key == $k and .truncated == false and (.result // "") != ""
    and ((.result | split("\n")[0] | gsub("^[ \t\r]+|[ \t\r]+$"; "")) == $r)' >/dev/null 2>&1 || return 4
  if printf '%s' "$detail" | jq -j '.result' > "$bd/RESULT" \
     && printf '%s' "$detail" | jq -r '.pipeline_tail // "" | select(. != "")' > "$bd/pipeline.log" \
     && printf '%s' "$detail" | jq -j '.evidence // ""' > "$bd/evidence.md"; then
    [ -s "$bd/pipeline.log" ] || rm -f "$bd/pipeline.log"
    [ -s "$bd/evidence.md" ] || rm -f "$bd/evidence.md"
    return 0
  fi
  rm -f "$bd/RESULT" "$bd/pipeline.log" "$bd/evidence.md"
  return 5
}

ingest_one() {
  local p="$1"
  local active="$STATE_DIR/$p-active.json"
  # >>> rows-only (BH-1026.3)
  # THE CLAIM IS WHAT SAYS A BUILD IS IN FLIGHT, and with the flag on the ROW
  # holds it. <p>-active.json is the write-through cache, so it can be gone
  # (a reaper, bin/fly-trial-kill.sh, a medic) while the row is still `claimed`
  # — and without this the finished RESULT on the builder would never be
  # collected, the builder would idle-autostop with it, and the dispatcher would
  # read that as died-mid-build and requeue a build that had already succeeded.
  local rows_only=0 row_key=""
  command -v build_queue_rows_only_on >/dev/null 2>&1 && build_queue_rows_only_on && rows_only=1
  if [ ! -f "$active" ]; then
    [ "$rows_only" = 1 ] && command -v build_queue_active_key >/dev/null 2>&1 || return 0
    row_key=$(build_queue_active_key "$p" 2>/dev/null | head -1 | cut -f1)
    [ -n "$row_key" ] || return 0
  fi
  # <<< rows-only
  local sf="$STATE_DIR/$p.json"; [ -f "$sf" ] || return 0

  local tv; tv=$(tok_var "$p")
  local APP; APP=$(jq -r '.app // ""' "$sf")
  local FLY_ACCESS_TOKEN="${!tv:-}"
  [ -n "$APP" ] && [ -n "$FLY_ACCESS_TOKEN" ] || { say "$p" "missing app/$tv"; return 0; }
  export FLY_ACCESS_TOKEN

  bssh() { "$FLY" ssh console -a "$APP" -C "/bin/sh -c $(printf '%q' "$1")" 2>>"$DLOG"; }

  # SINCE bounds the fly_result read to THIS attempt: the active file's mtime
  # (the queue file's, kept by the mv that claimed it), else the claimed row's
  # enqueued_at. Neither -> empty -> no DB read (rc 2), sftp as before.
  local key ticket since="" qrow
  if [ -f "$active" ]; then
    key=$(jq -r '.key // ""' "$active"); ticket=$(jq -r '.ticket_id // ""' "$active")
    since=$(date -u -d "@$(stat -c %Y "$active" 2>/dev/null)" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || since=""
  else
    # No cache, so the row is the only thing that knows which build this is. The
    # ticket id comes off the same claimed row — an ingest that lost it stages a
    # close-out nothing can post.
    key="$row_key"
    qrow=$(queue_list "$p" claimed fly 2>/dev/null | awk -F'\t' -v k="$key" '$2==k {print $3 "\t" $8; exit}')
    ticket="${qrow%%$'\t'*}"; since="${qrow#*$'\t'}"
    [ "$qrow" = "${qrow#*$'\t'}" ] && since=""
    case "${ticket:-}" in -) ticket="" ;; esac
    case "${since:-}" in -) since="" ;; esac
  fi
  local ts; ts=$(date -u +%Y%m%d%H%M%S)
  local builddir="$HARNESS/builds/fly-$p-$key-$ts"
  mkdir -p "$builddir"

  # --- RESULT: the builder's fly_result row first, flyctl second (BH-2625) ----
  local src=db why="" frc
  fly_result_db "$p" "$key" "$since" "$builddir"; frc=$?
  if [ "$frc" != 0 ]; then
    src=sftp
    case "$frc" in
      1) why="worker unreachable" ;;
      2) why="no enqueue time to bound the DB read" ;;
      3) why="no fly_result row" ;;
      4) why="row truncated or unusable" ;;
      *) why="db copy could not be written (rc $frc)" ;;
    esac
    # RESULT present?
    grep -q yes <<<"$(bssh "[ -f /run/harness/RESULT ] && echo yes || echo no")" || { rmdir "$builddir" 2>/dev/null || true; return 0; }
    # --- pull RESULT (small text) via console cat -----------------------------
    bssh "cat /run/harness/RESULT" > "$builddir/RESULT" 2>>"$DLOG"
    [ -s "$builddir/RESULT" ] || { say "$p" "RESULT empty after pull for $key — leaving builder state; retry next tick"; rm -f "$builddir/RESULT"; rmdir "$builddir" 2>/dev/null || true; return 0; }
  fi
  local rline; rline=$(head -1 "$builddir/RESULT")
  # READ BEFORE THE DECISION, because the decision needs it: BUILD_DIR: is the
  # dir the MACHINE built in, which is this build's identity in the ledger row
  # (bin/run-build.sh detail.build_dir) and the only name the two paths spell
  # the same. The artifact pulls below use the same value.
  local remote_bdir
  remote_bdir=$(grep -oE '^BUILD_DIR: .*' "$builddir/RESULT" | sed 's/^BUILD_DIR: //' | head -1)

  # >>> relay decision (BH-1041)
  # DECIDED BEFORE ANYTHING IS SPENT OR CLEARED, because one of the three
  # answers is "do nothing at all" and every line below this block — the
  # artifact pulls, the `rm` on the builder, the hand-off — is a thing that
  # cannot be taken back once the ledger turns out to be unreachable.
  #
  # TWO PROBES, AND THEY ANSWER DIFFERENT QUESTIONS. The marker on the RESULT
  # line says the builder posted the BOARD close-out — the thing a second relay
  # would duplicate in front of a client — and it is a CACHE: present, the
  # ledger is not asked at all. The ledger read-back says the terminal result is
  # already a row the owning box can pull, which is what makes the push
  # redundant. Neither is assumed.
  #
  # THREE OUTCOMES (bd_result_in_ledger's own contract):
  #   0  delivered -> bookkeeping below, no json, no ssh.
  #   1  answered, no row -> the relay this script has always done.
  #   2  could not ask -> HELD. Nothing is pulled, nothing is cleared, nothing
  #      is pushed, and the sweep re-asks. An unreadable ledger is not "absent"
  #      and it is not "delivered" either.
  #
  # A HUB WITH NO JOBS CLIENT IS NOT AN OUTAGE. It can never ask, so deferring
  # there would defer for ever: it relays, byte for byte as it always has. The
  # same is true of the kill flag — BUILDER_DIRECT=0 gives back today's path
  # whole, which is the only thing that makes it useful to a medic.
  local delivered=0 deferred=0
  if command -v builder_direct_on >/dev/null 2>&1 && [ "$(builder_direct_on "$HARNESS")" = 1 ]; then
    if bd_closed_out "$rline"; then
      delivered=1
    elif command -v bd_result_in_ledger >/dev/null 2>&1 \
         && command -v job_artifact_feed >/dev/null 2>&1; then
      bd_result_in_ledger "$p" "$key" "$rline" "${remote_bdir:-}"
      case "$?" in
        0) delivered=1 ;;
        1) ;;
        *) deferred=1 ;;
      esac
    fi
  fi
  # THE HOLD IS BOUNDED BY THE BUILDER'S AUTOSTOP, not by the outage. The flag's
  # first line is the epoch second the hold began; once it is RELAY_HOLD_MAX_S
  # old the hub stops waiting and relays, because a builder that walks with the
  # RESULT still on it costs the ticket a requeue and then a `.failed` — the
  # exact outcome this ticket exists to prevent. A flag whose first line is not
  # an epoch (one written by an older hub, before this field existed) reads as
  # "no clock": it is re-stamped below and the bound starts from now rather than
  # never expiring.
  local dflag="$STATE_DIR/$p-$key.relay-deferred"
  local held_since held_for now_s
  now_s=$(date -u +%s)
  held_since=$(head -1 "$dflag" 2>/dev/null)
  # STRICT, not `tr -dc '0-9'`: a flag written by an older hub holds the human
  # stamp, and squeezing its digits out would read "2026-09-21 06:53:06Z" as the
  # epoch 20260921065306 — a hold that can never expire. Anything that is not a
  # whole number is "no clock": re-stamped below, bounded from now.
  case "$held_since" in ''|*[!0-9]*) held_since="" ;; esac
  if [ "$deferred" = 1 ] && [ -n "$held_since" ]; then
    held_for=$(( now_s - held_since ))
    if [ "$held_for" -ge "$RELAY_HOLD_MAX_S" ]; then
      deferred=0
      say "$p" "$key has been held ${held_for}s (cap ${RELAY_HOLD_MAX_S}s) and the ledger still cannot be asked — relaying now rather than letting the builder autostop with the result on it. The box drops a relay it already staged (BUILT_AS)."
      HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[fly-ingest/$p] HOLD EXPIRED — $key was held ${held_for}s on builder app $APP waiting for the jobs ledger; relaying over ssh now so the builder's 600s idle autostop cannot take the result (which dispatch would read as died-mid-build and requeue). The ledger is still unreadable: check worker/jobs + HARNESS_SECRET."
    fi
  fi
  if [ "$deferred" = 1 ]; then
    # The dir made two lines up is the ONLY thing this tick created; remove it
    # so the next tick's `ls builds/fly-$p-$key-*` sees nothing half-made, and
    # so bin/pipeline-health.sh does not count a record with no close-out.
    rm -f "$builddir/RESULT" "$builddir/pipeline.log" "$builddir/evidence.md"; rmdir "$builddir" 2>/dev/null || true
    # THE FLAG IS WRITTEN BEFORE THE LINE IS SAID. A crash between them costs
    # one repeated log line; the other order costs a deferral nobody can see.
    # Line 1 is the epoch the bound above measures from; line 2 is for the human
    # who cats the file.
    if [ -z "$held_since" ]; then
      printf '%s\n%s\n' "$now_s" "$(STAMP)" > "$dflag" 2>/dev/null || true
      say "$p" "$key is held on the builder: the jobs ledger could not be asked whether its result already landed, so nothing was relayed and nothing was cleared. The sweep re-asks every 2 minutes, and the hold gives up and relays after ${RELAY_HOLD_MAX_S}s."
      HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[fly-ingest/$p] LEDGER UNREADABLE — $key's result is finished on builder app $APP and is being HELD there: nothing relayed, builder RESULT/job.json kept, hub active-job row kept, and the */2 sweep re-asks until the ledger answers. Check worker/jobs + HARNESS_SECRET. (One line per key; the hold expires after ${RELAY_HOLD_MAX_S}s and relays anyway, so it cannot outlive the builder's 600s idle autostop.)"
    fi
    return 0
  fi
  # <<< relay decision

  say "$p" "ingesting $key source=$src${why:+ ($why)}: $rline"

  # A DB-written file is replaced only by a NON-EMPTY sftp copy (BH-2625): with
  # flyctl up the hub keeps the full pipeline.log its greps read today, and with
  # flyctl down a failed pull cannot clobber the row's copy.
  fr_get() { # fr_get <remote-path> <local-path>
    if [ "$src" = db ] && [ -e "$2" ]; then
      local tmp="${2%/*}/.${2##*/}.sftp" grc
      "$FLY" ssh sftp get -a "$APP" "$1" "$tmp" >>"$DLOG" 2>&1; grc=$?
      if [ -s "$tmp" ]; then mv -f "$tmp" "$2"; else rm -f "$tmp"; fi
      return "$grc"
    fi
    "$FLY" ssh sftp get -a "$APP" "$1" "$2" >>"$DLOG" 2>&1
  }

  # --- pull artifacts named by RESULT ARTIFACT: lines + the build dir tree -----
  # The runner writes ARTIFACT: <fullpath> lines and BUILD_DIR: <basename>. Pull
  # each named artifact; also pull pipeline.log/cost rows if present in the dir.
  # remote_bdir was read above the relay decision, which needs the same value.
  while read -r a; do
    [ -n "$a" ] || continue
    local base; base=$(basename "$a")
    fr_get "$a" "$builddir/$base" || \
      say "$p" "artifact pull failed: $a"
  done < <(grep -oE '^ARTIFACT: .*' "$builddir/RESULT" | sed 's/^ARTIFACT: //')
  # cost rows (agent-call.sh appends to a per-build cost file if present), plus
  # e2e.md — the browser-smoke record bin/merge-sweep.sh refuses to merge over.
  # It has to make the trip: the sweep runs on the HUB and reads hub build dirs,
  # so a FAIL left on the builder is a FAIL the merge gate cannot see.
  if [ -n "$remote_bdir" ]; then
    # Same list as bin/fly-pool.sh:180 and for the same reason (2026-09-12,
    # TK-419/TK-290): merge-sweep.sh:291 reads an absent e2e.md as "never ran"
    # and merges, :332 falls back to the record's reviewed-sha, and the
    # head-bound/refuter evidence is unreadable on the hub unless it makes the
    # trip. sftp get of an absent file is a no-op swallowed by `|| true`.
    for extra in pipeline.log cost.csv gh-stderr.log e2e.md evidence.md changed-files.txt \
                 security-review-run.txt refute-review.md \
                 reviewed-sha headbound-outcome headbound-review.md headbound-review-run.txt \
                 harness-suite-head.txt execute-transcript.md stop-reason.txt; do
      fr_get "/data/harness/builds/$remote_bdir/$extra" "$builddir/$extra" || true
    done
  fi

  # --- metrics row ------------------------------------------------------------
  # No direct call here: bin/metrics-collect.sh runs hourly, walks builds/*/ with
  # a RESULT (idempotent via state/metrics-seen.txt), and will pick up this
  # fly-<project>-<key>-<ts> dir on its next pass. The `fly-` prefix is the
  # comparison tag. (Follow-up: metrics-collect's project regex matches
  # `<name>-os` at start-of-string only, so it currently derives an empty project
  # for fly-prefixed dirs — widen that regex when adopting the trial.)

  # --- parse tier / verdict / PR ----------------------------------------------
  local tier pr_url verdict
  tier=$(grep -oE '^TIER: [12]' "$builddir/RESULT" | grep -oE '[12]' | head -1)
  # The record's OWN pr, never the first url on it: a failed create folded the
  # STACKED note's PARENT url into line 1 and this grep published it as `PR:`
  # (BH-848). No lib on this hub yet = the grep it always did.
  if command -v result_own_pr_url >/dev/null 2>&1; then
    pr_url=$(result_own_pr_url "$builddir/RESULT" || true)
  else
    pr_url=$(grep -oE 'https://github.com/[^ ]+/pull/[0-9]+' "$builddir/RESULT" | head -1)
  fi
  verdict=$(verdict_parse -L "$builddir/review.md" 2>/dev/null) || verdict=""

  # --- clear the builder's RESULT + job (rm via console) ----------------------
  bssh "rm -f /run/harness/RESULT /run/harness/job.json" >/dev/null 2>&1 || \
    say "$p" "could not clear builder RESULT/job (will be overwritten next push anyway)"

  # --- hand-off to the owning watcher box -------------------------------------
  # BOOKKEEPING ONLY when the builder already delivered: no json, no ssh, no
  # second close-out. The tier-1 merge ROW below still runs (it is idempotent on
  # project+pr, so the builder having written it makes this a duplicate and
  # never a second merge), and the RELAYED stamp still moves custody for
  # bin/queued-fly-relayed.sh and bin/pipeline-health.sh.
  local box=""
  if [ "$delivered" = 1 ]; then
    touch "$builddir/RELAYED" 2>/dev/null || true
    say "$p" "$key was delivered by its builder (board close-out + ledger row) — bookkeeping only, nothing relayed"
  else
    box=$(owning_box_ip "$p") || box=""
    # 1) always drop the RESULT summary so the triage session posts the comment.
    # machine_build_dir IS THE CROSS-PATH IDENTITY (BH-1041). The box dedupes
    # this json against the ledger row for the same build, and the only name the
    # two spell identically is the dir the MACHINE built in: the row's
    # detail.build_dir (bin/run-build.sh) and this RESULT's BUILD_DIR: line
    # (fly/builder-runner.sh) are both `basename $BUILD` on the builder. The
    # result LINE is not that name — it is truncated, rewritten and appended to
    # on the way here. `build_dir` above stays what it is: the HUB's own copy.
    local rr_payload
    rr_payload=$(jq -nc --arg k "$key" --arg t "$ticket" --arg r "$rline" \
      --arg pr "${pr_url:-}" --arg tier "${tier:-}" --arg bd "$(basename "$builddir")" --arg ts "$(STAMP)" \
      --arg mbd "${remote_bdir:-}" \
      '{key:$k,ticket_id:$t,result:$r,pr_url:$pr,tier:$tier,build_dir:$bd,machine_build_dir:$mbd,ingested_at:$ts,source:"fly"}')
    if [ "$box" = "local" ]; then
      mkdir -p "$HARNESS/state/remote-results/$p"
      printf '%s\n' "$rr_payload" > "$HARNESS/state/remote-results/$p/$key.json"
    elif [ -n "$box" ]; then
      # NOTE: no -n here — the payload rides stdin into cat (medic 2026-07-31:
      # -n nulled stdin and the box received an EMPTY result file).
      ssh -o BatchMode=yes -o ConnectTimeout=15 "root@$box" \
        "mkdir -p /root/harness/state/remote-results/$p; cat > /root/harness/state/remote-results/$p/$key.json" \
        <<<"$rr_payload" || say "$p" "could not scp remote-result to $box for $key"
    fi

    # 1b) ship review.md + plan.md to the box's OWN build dir too. A summary line
    # alone cannot feed a fix pass: the TK-101/102 deadlock (2026-08-05) was four
    # terminal tickets whose review verdicts were hub-only, unreachable from the
    # box that needed to relay the findings.
    if [ -n "$box" ] && [ "$box" != "local" ]; then
      local bdname; bdname=$(basename "$builddir")
      # The head-bound files ride along: bin/merge-queue.sh runs ON THE BOX and
      # parks a PR whose head is not the reviewed sha (its hb_sha/hb_blocked
      # pair), and a fix pass cannot relay findings it cannot read.
      for art in review.md plan.md security-review.md refute-review.md headbound-review.md \
                 reviewed-sha headbound-outcome; do
        [ -s "$builddir/$art" ] || continue
        ssh -o BatchMode=yes -o ConnectTimeout=15 "root@$box" \
          "mkdir -p /root/harness/builds/$bdname; cat > /root/harness/builds/$bdname/$art" \
          < "$builddir/$art" 2>>"$DLOG" || say "$p" "artifact ship to box failed: $art ($key)"
      done
    fi

  fi

  # 2) tier-1 APPROVE PR -> the merge-queue ROW (watcher lands it). The ROW runs
  # on every path including the bookkeeping one; only the ssh touch is skipped
  # there, because an empty $box is the fail-closed shape this block already has.
  if [ "${tier:-}" = "1" ] && [ -n "$pr_url" ] && [ "${verdict:-}" = "APPROVE" ]; then
    local prnum; prnum=$(grep -oE '[0-9]+$' <<<"$pr_url")
    if [ -n "$prnum" ]; then
      # THE ROW FIRST (2026-09-10). The ssh touch below reaches into the owning
      # box to create a filename; when the box is unreachable a tier-1 APPROVE
      # is dropped with one log line. bin/merge-queue.sh materialises queued
      # rows on its own box, so the row alone carries it once that is deployed
      # everywhere; the touch stays for one release.
      command -v merge_queue_put >/dev/null 2>&1 \
        && merge_queue_put "$p" "$prnum" "" "tier-1 APPROVE from fly build $key" >/dev/null 2>&1
      if [ "$box" = "local" ]; then
        mkdir -p "$HARNESS/state/merge-queue/$p"; touch "$HARNESS/state/merge-queue/$p/$prnum"
      elif [ -n "$box" ]; then
        ssh -n -o BatchMode=yes -o ConnectTimeout=15 "root@$box" \
          "mkdir -p /root/harness/state/merge-queue/$p; touch /root/harness/state/merge-queue/$p/$prnum" \
          || say "$p" "could not enqueue PR #$prnum on $box merge-queue"
      fi
      say "$p" "tier-1 APPROVE — PR #$prnum enqueued for ${box:-the owning box (row only, this result was delivered by its builder)}"
    fi
  fi

  # --- clear hub active-job state ---------------------------------------------
  rm -f "$active"
  # ...and the CLAIM, which under the flag is the state the next tick reads.
  # Clearing the file and leaving the row `claimed` would hold the key in flight
  # for the 6h bin/jobs-watchdog.sh sweep. This order is deliberate: `done` is
  # written only after the RESULT has been pulled, and a failed close leaves a
  # claimed row the watchdog sweeps — never a second build.
  if [ "$rows_only" = 1 ] && command -v queue_done >/dev/null 2>&1; then
    queue_done "$p" "$key" done "$rline" >/dev/null 2>&1 || \
      say "$p" "$key: the queue row could not be closed done — the watchdog sweeps the claim"
  fi
  # ...and the deferral flag, if this key was ever held. Removed on ANY
  # non-deferred completion — delivered or relayed — so the NEXT outage on this
  # key says its one line instead of being silenced by a stale flag (BH-1041).
  rm -f "$STATE_DIR/$p-$key.relay-deferred"

  # --- standard build beat ----------------------------------------------------
  beat "$(jq -nc --arg p "$p" --arg k "$key" --arg r "$rline" --arg pr "${pr_url:-}" \
    --arg tier "${tier:-}" \
    '{kind:"build",project:$p,ticket_key:$k,stage:"fly_ingested",detail:$r,pr_url:$pr,tier:(if $tier=="" then null else ($tier|tonumber) end),host:("builder-"+$p)}')"
  say "$p" "ingested $key -> $(basename "$builddir") (tier=${tier:-?} pr=${pr_url:-none})"
}

if [ "$ARG" = "sweep" ]; then
  [ -d "$STATE_DIR" ] || exit 0
  SWEPT=" "
  for af in "$STATE_DIR"/*-active.json; do
    [ -f "$af" ] || continue
    p=$(basename "$af" -active.json)
    SWEPT="$SWEPT$p "
    ingest_one "$p" || say "$p" "ingest_one returned nonzero"
  done
  # THE SWEEP'S OWN LIST IS THE CACHE (BH-1026.3), and under the flag a project
  # whose claim lives only in a row has no `<p>-active.json` for this glob to
  # find — so it would never be swept at all. Every PROVISIONED project is
  # offered instead, and ingest_one decides: with no active file and no claimed
  # row it returns immediately, which is one row read per quiet project per tick.
  #
  # EXCEPT A POOL PROJECT, which this widened list would otherwise reach for the
  # first time. bin/fly-dispatch.sh stands its dispatcher down entirely for one
  # (`flags/fly-pool-<p>`, dispatch_project's first lines) because the pool owns
  # that queue — and the pool CLAIMS rows, so without this skip every pool
  # project with a claimed row would answer build_queue_active_key and get an
  # `fly ssh console` against the single-machine BUILDER app every two minutes.
  # That is flyctl spend on a lane this box does not run, and worse: if that
  # builder app still holds a leftover RESULT, the ingest would stage a close-out
  # under the pool's key and close the pool's claimed row `done` against another
  # build's result. bin/fly-pool.sh's own reap is what ingests a pool machine.
  if command -v build_queue_rows_only_on >/dev/null 2>&1 && build_queue_rows_only_on; then
    for sf in "$STATE_DIR"/*.json; do
      [ -f "$sf" ] || continue
      p=$(basename "$sf" .json)
      case "$p" in *-active) continue;; esac
      case "$SWEPT" in *" $p "*) continue ;; esac
      flag_on fly-pool "$p" && continue
      ingest_one "$p" || say "$p" "ingest_one returned nonzero"
    done
  fi
else
  ingest_one "$ARG"
fi
