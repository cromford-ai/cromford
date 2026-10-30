# >>> pool listing (BH-660)
# ONE LISTING PER TICK, and it answers two questions the script used to ask one
# machine at a time or not at all: "is this tracked machine still alive" (a
# `machine status` call per machine, which is where a machine Fly no longer
# returns has to error CLEANLY for the job to be requeued) and "what else is
# sitting in this app" (nothing asked that before — a machine with no tracking
# file was invisible for ever).
#
# FAIL-OPEN, because an unusable listing is not an empty pool. A `[]` answer
# beside tracking files is AMBIGUOUS — it is also what every existing pool
# fixture's flyctl stub returns while a live machine is on file — and reading it
# as "everything is gone" would requeue every running build on one flaky call.
# Unusable means: fall back to the per-machine `machine status` this loop has
# always used, and skip the sweep entirely rather than sweep on a guess.
LISTING=""; LIST_OK=0; LIST_WHY=""
if [ -n "${POOL_APP:-}" ]; then
  LISTING=$(mktemp "${TMPDIR:-/tmp}/pool-listing.XXXXXX") || LISTING=""
fi
if [ -n "$LISTING" ]; then
  trap 'rm -f -- "$FLY" "$LISTING" "$LISTING.err" "$LISTING.rows"; [ -n "${RQ:-}" ] && rm -rf -- "$RQ"; command -v pp_release >/dev/null 2>&1 && pp_release; true' EXIT
  if timeout 30 "$FLY" machines list -a "$APP" --json > "$LISTING" 2>"$LISTING.err"; then
    if jq -e 'type=="array"' "$LISTING" >/dev/null 2>&1; then
      LIST_OK=1
    else
      LIST_WHY="flyctl did not print a machine array: $(head -c 120 "$LISTING" 2>/dev/null | tr '\n\r\t' '   ')"
    fi
  else
    LIST_WHY=$(head -1 "$LISTING.err" 2>/dev/null | cut -c1-120)
    [ -n "$LIST_WHY" ] || LIST_WHY="machines list exited non-zero with no error text"
  fi
  if [ "$LIST_OK" = 1 ] && [ "$(jq -r 'length' "$LISTING" 2>/dev/null)" = 0 ] \
     && ls "$POOL"/*.json >/dev/null 2>&1; then
    LIST_OK=0; LIST_WHY=empty-with-tracked
  fi
  if [ "$LIST_OK" = 0 ]; then
    say "machines list unusable (${LIST_WHY:-no answer}) — liveness falls back to machine status, sweep skipped"
    # A listing that fails every tick is a sweep that is silently dark, which is
    # the exact failure this change exists to end. Once per project per day.
    LAF="$HARNESS/flags/alerted-pool-listing-$P-$(date -u +%Y%m%d)"
    if [ ! -f "$LAF" ]; then
      mkdir -p "$HARNESS/flags" 2>/dev/null && touch "$LAF" 2>/dev/null
      HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] machines list for $APP unusable (${LIST_WHY:-no answer}) — dead-machine sweep skipped; stopped machines are not being reclaimed until it answers"
    fi
  fi
fi
# <<< pool listing

# Per-key spawn cap for this tick (BH-1075). LOADED BEFORE THE REAP, not beside
# the spawn loop where it started (review round 2, Important-1): the reap's
# reuse handoff (next_job_or_destroy) runs the same pool_spawn_decision, and
# with POOL_SPAWN_CAP still unset there the handoff judged every row against the
# hardcoded fallback 2/86400 whatever the operator had put in D1 — so a cap
# raised to 5 refused a row at 2, deleted its queue file and PAGED
# POOL_DEFER_TO_HUMAN for a key under the operator's own cap, and a cap lowered
# to 1 was honoured by the spawn loop and ignored by the handoff. One knob, one
# answer, both paths.
pool_spawn_cap_load
# BH-5001: ONE read of this project's pool_* rows for the whole tick, in this
# shell so every reader below (and every $( ... ) under it) shares it. No
# answer is one line, and every reader then uses its state/pool/ file.
if command -v psr_on >/dev/null 2>&1 && psr_on; then
  psr_load "$P" "$(( $(date +%s) - ${POOL_SPAWN_CAP_WINDOW:-86400} ))" || psr_fallback_note "$P" "pool-state read"
fi

# Results this hub PARKED on an earlier tick because the ledger could not be
# asked. Re-asked here, once per tick, before anything is reaped — a deferral
# that nothing re-asks is a stranded close-out (BH-1041).
pool_relay_retry
# Finished builds no reap path took custody of (BH-5006), right after the retry.
pool_custody_sweep
  # >>> machines rows (BH-1035)
  # Refresh the machine registry with this tick listing before the reap mutates
  # any state. Fail-open: a broken worker leaves the file lifecycle unchanged.
  # INSIDE the listing block and BEFORE the REAP on purpose: a machine the reap
  # destroys this tick has to end `destroyed`, and an observe running after it
  # would re-stamp the row live with a listing read before the destroy.
  # `LIST_OK=0` — rc≠0, non-array, empty-beside-tracked — sends nothing at all,
  # because an unusable listing is not an empty pool.
  if [ "$LIST_OK" = 1 ]; then
    machines_row machines_observe "$P" "$APP" "$LISTING"
  fi
  # <<< machines rows

# BH-7874: one open-issue listing per tick ranks the queue by the open work
# each ticket unblocks. Both hotfix_first callers read its file; fail-open.
command -v pur_prime >/dev/null 2>&1 && { pur_prime || PUR_FILE=""; }

# ---------- REAP ----------
# BH-7429: read each finished machine's build record from the jobs API before
# any ssh. Lane knob POOL_RECORD_READ (default 0; project-6-os is seeded 1).
# lane_knob reads the env value of the same name, so nothing is assigned first.
POOL_RECORD_READ=$( { command -v lane_knob && command -v pool_record_get; } >/dev/null 2>&1 \
  && lane_knob fly-pool POOL_RECORD_READ "$P")
[ "$POOL_RECORD_READ" = 1 ] || POOL_RECORD_READ=0
REAPED_IDS=" "   # machines this tick's REAP owns; the sweep below never touches one
for MF in "$POOL"/*.json; do
  [ -f "$MF" ] || continue
  # BH-7475: a replaced code file or a tick past its max age stops at this row.
  command -v pts_stop_due >/dev/null 2>&1 && pts_stop_due && break
  MID=$(jq -r '.machine' "$MF"); KEY=$(jq -r '.key' "$MF"); TICKET=$(jq -r '.ticket_id' "$MF")
  # Claimed for the whole tick, not just while the file exists: the reap DELETES
  # the file on every terminal path, and without this the sweep would see the
  # machine it just destroyed, still in the listing this tick read before the
  # reap ran, and destroy it a second time.
  REAPED_IDS="$REAPED_IDS$MID "
  ATT=$(jq -r '.attempt // 0' "$MF"); BD=$(jq -r '.build_dir // ""' "$MF")
  # DEATHS ARE COUNTED, NOT INFERRED (2026-09-13). `attempt` is whatever the
  # ENQUEUER put on the row: bin/blocked-resolver.sh and the 09-13 rebuild wave
  # both enqueue at attempt>=1, and the old rule (NEXT=ATT+1 >= 2) then read the
  # FIRST death of a brand-new build as its second and parked a ticket that had
  # never failed once. `deaths` is written here and nowhere else, so it counts
  # only deaths this loop actually OBSERVED. Absent (a machine json from before
  # this change) = 0, which costs at most one extra attempt and never an
  # unearned park.
  DTHS=$(jq -r '.deaths // 0' "$MF" 2>/dev/null); case "$DTHS" in ''|*[!0-9]*) DTHS=0 ;; esac
  # DEATHS AND STAND-DOWNS ARE DIFFERENT COUNTERS (2026-09-11). `attempt` is
  # deaths — the liveness path below parks on it at 2 ("died twice"). Spending
  # it on deferrals made ONE real death after two refusals read as two deaths
  # and parked a ticket that had never actually failed. `deferrals` rides
  # beside it through the pool json, the queue file and the row's meta.
  DEFC=$(jq -r '.deferrals // 0' "$MF" 2>/dev/null); case "$DEFC" in ''|*[!0-9]*) DEFC=0 ;; esac
  # The parent branch a STACKED child build is being cut from (2026-09-14).
  # It rides the machine json for exactly the reason `deferrals` does: the
  # requeue paths below rebuild the queue entry from these fields, and a base
  # dropped here would silently retry the child against main — which is the
  # chain wait this whole lane exists to remove. Absent = no field, as before.
  SBASE=$(jq -r '.stack_base // ""' "$MF" 2>/dev/null)
  case "$SBASE" in *[!A-Za-z0-9._/-]*) SBASE="" ;; esac
  SBMETA=""; [ -n "$SBASE" ] && SBMETA=$(jq -nc --arg sb "$SBASE" '{stack_base:$sb}' 2>/dev/null)
  # The hotfix flag rides the machine json for exactly the reason `stack_base`
  # does (#368): every requeue path below rebuilds the queue entry from these
  # fields, and a flag dropped here is an emergency that quietly stops being one
  # — the next tick would defer it for the cap it was exempt from a minute ago.
  MHF=$(jq -r '.hotfix // false' "$MF" 2>/dev/null); case "$MHF" in true) MHF=true ;; *) MHF=false ;; esac
  # The key this machine ran before, when it was handed this job by a reuse
  # (BH-5025.2). Absent = a fresh spawn.
  MREUSED=$(jq -r '.reused_from // ""' "$MF" 2>/dev/null); [ "$MREUSED" = null ] && MREUSED=""
  # The exact line spawn_one (or the reuse handoff) appended to this key's
  # .spawns log when it recorded THIS machine against the per-key cap
  # (BH-1279). Read back here so the BUILD_DEFERRED REFUSED arm below can
  # remove exactly this one entry — never a different spawn's — when the claim
  # this machine tried never ran at all. Absent on a machine json predating
  # this change, or a rebase (never recorded in the first place): the arm
  # below then un-records nothing, which is the same "no worse than before"
  # behaviour every other absent field on this json degrades to.
  SPAWNCAPTS=$(jq -r '.spawn_cap_ts // ""' "$MF" 2>/dev/null)
  # When this machine took this key (spawn or reuse handoff). The pool-result
  # row below is only this machine's answer if it was written after it.
  SPAT=$(jq -r '.spawned_at // ""' "$MF" 2>/dev/null)
  # When the App token this machine is carrying dies, and when it was last
  # replaced (2026-09-14). Absent = this machine shipped the PAT, or its record
  # predates the change: rotate_gh_token leaves both alone.
  GHEXP=$(jq -r '.gh_token_expires_at // ""' "$MF" 2>/dev/null)
  GHROT=$(jq -r '.gh_token_rotated_at // ""' "$MF" 2>/dev/null)
  # The max account this machine is spending, by NAME (2026-09-14). Absent = it
  # shipped the project-6 token, and every account path below then no-ops.
  MACCT=$(jq -r '.auth_account // ""' "$MF" 2>/dev/null)
  case "$MACCT" in null|*[!a-z0-9._-]*) MACCT="" ;; esac
  # 1 once the reap below has cooled MACCT and read the cooldown back (BH-1853).
  ACOOLED=""
  # 1 once the reap below has read a token-401 deferral (BH-5025.2). Reset per
  # machine: next_job_or_destroy reads it, and it must never reach the next one.
  TOKFAIL=0
  # 1 once the record arm below took this machine's result from the build record
  # (BH-7429): next_job_or_destroy stamps it reaped as its last step.
  RECSTAMP=0
  # The tick's own listing answers this for every machine at once when it is
  # usable, and a machine ABSENT from it reads as the empty string — exactly what
  # an errored `machine status` yields today, so the dead path below is reached
  # by the same route it always was. No listing, no guessing: ask Fly per machine.
  if [ "$LIST_OK" = 1 ]; then
    MSTATE=$(jq -r --arg m "$MID" '.[] | select(.id==$m) | .state // ""' "$LISTING" 2>/dev/null | head -1)
  else
    MSTATE=$(timeout 30 "$FLY" machine status "$MID" -a "$APP" 2>/dev/null | grep -oE "State: [a-z]+" | cut -d' ' -f2)
  fi
  # /run/harness/RESULT is the runner's CANONICAL result — it exists even when
  # run-build never produced a build dir (BUILD_ERROR/DEFERRED paths). Reading
  # only the build-dir glob made those failures silent (TK-143, 2026-08-13).
  # THE RECORD BEFORE THE SSH (BH-7429). The runner posted its build record
  # (bin/lib/pool-record.sh); when it is this machine's from this run, the
  # result and every file come from it, and this machine costs no ssh call. A
  # miss, a record of another machine or run, or an unreadable worker is the
  # ssh path below, exactly as before. Never for an RB- rebase.
  RES=""; RES_FROM_RECORD=0; RECSTAGE=""; RECINFO=""
  if [ "$POOL_RECORD_READ" = 1 ] && [ "${KEY#RB-}" = "$KEY" ] \
     && RECSTAGE=$(mktemp -d "${TMPDIR:-/tmp}/pool-record.XXXXXX"); then
    RECINFO=$(pool_record_get "$P" "$KEY" "$MID" "$SPAT" "$RECSTAGE"); RECRC=$?
    if [ "$RECRC" = 0 ]; then
      RES=$(head -1 "$RECSTAGE/RESULT"); RES_FROM_RECORD=1
    else
      rm -rf "$RECSTAGE"; RECSTAGE=""
      [ "$RECRC" = 1 ] && say "build record for $KEY unreadable (machine $MID) — the reap reads it over ssh"
    fi
  fi
  [ "$RES_FROM_RECORD" = 1 ] || RES=$(mexec "$MID" "head -1 /run/harness/RESULT 2>/dev/null")
  # GATE (2026-08-30, MEDIC 4467): mexec stdout is not proof of a RESULT — a
  # flyctl ssh-console panic prints "Oops"/goroutine noise on stdout, and this
  # loop then reaped and force-destroyed a machine mid-build. Anything without
  # a canonical RESULT prefix is a mexec MISS: leave the machine alone.
  if [ -n "$RES" ] && ! "$HARNESS/bin/result-prefix-ok.sh" "$RES"; then
    echo "[fly-pool] $MID: mexec returned non-RESULT stdout (mexec miss, not a build result) — skipping reap" >&2
    RES=""
  fi
  # THE ROW BEFORE THE MACHINE STATE (BH-2643). A machine that answered `job
  # done` and idled out to autostop is `stopped`, and ssh cannot reach it, so
  # RES is empty and the liveness path below used to count a death — two of
  # those parked a ticket that had only ever deferred. The runner also writes
  # its result to a pool-result row (bin/lib/pool-result-row.sh); for a machine
  # that is not started, that row is read here, and only this machine's row
  # from this run counts. Every row pool_result_row_get accepts (rc 0: a
  # canonical RESULT prefix, this machine, this run) IS the result and takes
  # the same path below as an ssh-read one (BH-7719): a BUILD_DEFERRED goes
  # through the deferral arm, a PLAN_BLOCKED is held by its `done` queue row,
  # a PR_CREATED is verified and relayed. A requeue only re-ran the same plan
  # into the same answer. rc 1 (unreadable) and rc 2 (no row, a stale row, a
  # row of another machine) are never read as a result: those are deaths.
  # An RB- rebase row carries the whole RESULT (BH-7656): a rebase word in it is
  # the finished rebase, and the whole text becomes $LOCAL/RESULT for the
  # rebase arm below. Any other word in an RB- row is a miss, and its dead arm
  # fails the row as it always did.
  ROW_RLINE=""; RES_FROM_ROW=0; RBROWF=""
  if [ -z "$RES" ] && command -v pool_result_row_get >/dev/null 2>&1; then
    case "$KEY" in
      RB-*)
        case "$MSTATE" in
          ""|stopped|destroyed|failed|suspended)
            RBROWF=$(mktemp)
            ROW_RLINE=$(pool_result_row_get "$P" "$KEY" "$MID" "$SPAT" "$RBROWF"); ROWRC=$?
            [ "$ROWRC" = 0 ] || ROW_RLINE=""
            [ "$ROWRC" = 1 ] && say "pool-result row for $KEY unreadable (machine $MID state=${MSTATE:-gone}) — reaped as it always was"
            case "${ROW_RLINE%% *}" in
              REBASED|CONFLICT|GATE_RED|REBASE_LEASE_REJECTED|REBASE_SETUP_FAILED)
                RES="$ROW_RLINE"; RES_FROM_ROW=1
                say "result for $KEY taken from the pool-result row (machine $MID state=${MSTATE:-gone}, unreachable)" ;;
              *) ROW_RLINE=""; rm -f "$RBROWF"; RBROWF="" ;;
            esac ;;
        esac ;;
      RR-*|LR-*|FXR-*-*) ;;
      # A CP- console preview row carries the whole RESULT too (BH-8030); only a
      # CPV_ word in it is the finished job.
      CP-*)
        case "$MSTATE" in
          ""|stopped|destroyed|failed|suspended)
            RBROWF=$(mktemp)
            ROW_RLINE=$(pool_result_row_get "$P" "$KEY" "$MID" "$SPAT" "$RBROWF"); ROWRC=$?
            [ "$ROWRC" = 0 ] || ROW_RLINE=""
            [ "$ROWRC" = 1 ] && say "pool-result row for $KEY unreadable (machine $MID state=${MSTATE:-gone}) — reaped as it always was"
            case "${ROW_RLINE%% *}" in
              CPV_*)
                RES="$ROW_RLINE"; RES_FROM_ROW=1
                say "result for $KEY taken from the pool-result row (machine $MID state=${MSTATE:-gone}, unreachable)" ;;
              *) ROW_RLINE=""; rm -f "$RBROWF"; RBROWF="" ;;
            esac ;;
        esac ;;
      *)
        case "$MSTATE" in
          ""|stopped|destroyed|failed|suspended)
            ROW_RLINE=$(pool_result_row_get "$P" "$KEY" "$MID" "$SPAT"); ROWRC=$?
            [ "$ROWRC" = 0 ] || ROW_RLINE=""
            [ "$ROWRC" = 1 ] && say "pool-result row for $KEY unreadable (machine $MID state=${MSTATE:-gone}) — reaped as it always was"
            if [ -n "$ROW_RLINE" ]; then
              RES="$ROW_RLINE"; RES_FROM_ROW=1
              say "result for $KEY taken from the pool-result row (machine $MID state=${MSTATE:-gone}, unreachable)"
            fi ;;
        esac ;;
    esac
  fi
  if [ -n "$RES" ]; then
    LOCAL="$HARNESS/builds/pool-$P-$KEY-$(date -u +%Y%m%d%H%M)"; mkdir -p "$LOCAL"
    if [ "$RES_FROM_ROW" = 1 ]; then
      # Nothing on the machine can be fetched: the RESULT is the row's (the
      # whole text for an RB- row, else its first line).
      if [ -n "$RBROWF" ] && [ -s "$RBROWF" ]; then cp "$RBROWF" "$LOCAL/RESULT"; else echo "$RES" > "$LOCAL/RESULT"; fi
      [ -z "$RBROWF" ] || rm -f "$RBROWF"
      echo "pool-result row" > "$LOCAL/result-source"
      # The machine's Fly seconds, ended at its stop time (BH-7719). Braced and
      # "|| true", as the record arm below, so the cost-row suite's pins (B3a,
      # B3c) still name the ssh arm's pair.
      pool_fly_cost_row || true
      push_pool_cost_rows "$LOCAL" "pool-${P}-${MID}"
      case "$(head -1 "$LOCAL/RESULT")" in
        PLAN_BLOCKED*) say "held $KEY: PLAN_BLOCKED from the pool-result row — not requeued; the stranded watch re-offers it only after a person answers" ;;
      esac
    elif [ "$RES_FROM_RECORD" = 1 ]; then
      # The same files the ssh arm below fetches, from the record. A file too
      # big for a D1 row was skipped by the machine: it is fetched over ssh
      # while the machine is up, and named as absent when it is not.
      RECSUM=$(pool_record_install "$RECSTAGE" "$LOCAL" "$MID" "$MSTATE" "$RECINFO") \
        || say "build record for $KEY: a staged file could not be moved into $LOCAL"
      read -r RECN RECM RECABS <<<"$RECSUM"
      say "record for $KEY taken from the jobs API (${RECN:-0} files, ${RECM:-0} skipped${RECABS:+; not on the hub: $RECABS})"
      # The bill, as the ssh arm below does. Written with "|| true" and braces so
      # the cost-row suite's one-call-above-the-push pin (B3a, B3c) still names
      # the ssh arm's pair, the first full-form push line in this file.
      pool_fly_cost_row || true
      push_pool_cost_rows "$LOCAL" "pool-${P}-${MID}"
      [ -s "$LOCAL/RESULT" ] || echo "$RES" > "$LOCAL/RESULT"
      echo "build record" > "$LOCAL/result-source"
      RECSTAMP=1
    else
      [ "$POOL_RECORD_READ" = 1 ] && [ "${KEY#RB-}" = "$KEY" ] \
        && say "no build record for $KEY from $MID — its files are pulled over ssh"
      # THE BUILD'S OWN DIRECTORY, NEVER THE FIRST ONE ON DISK (2026-09-13, project-5
      # TK-493/#520). A reused pool machine holds every build it has run; `ls | head -1`
      # picked the alphabetically-first one, so #520's record carried TK-291's
      # review.md and pipeline.log — a BLOCK the ledger's APPROVE contradicted, and
      # the sweep parked it. RESULT names the directory (BUILD_DIR:);
      # the listing is only the fallback for a RESULT that predates that line.
      RB=$(printf '%s\n' "$RES" | sed -n 's/^BUILD_DIR: //p' | head -1)
      if [ -n "$RB" ]; then RB="/data/harness/builds/${RB##*/}"
      else RB=$(mexec "$MID" 'ls -dt /data/harness/builds/* 2>/dev/null | head -1'); fi
      # THE RELAY IS THE MERGE GATE'S EYES (2026-09-12, project-5 TK-419/TK-290).
      # Everything downstream — bin/merge-sweep.sh, the conductor, an operator
      # reading a park — runs on the HUB and reads HUB build dirs. An artifact
      # left on the machine is an artifact the gate cannot see, and two of these
      # are safety holes rather than conveniences:
      #   e2e.md      — merge-sweep.sh:291 treats an ABSENT e2e.md as "the stage
      #                 never ran" and merges. A pool build whose E2E FAILED was
      #                 therefore merging silently.
      #   reviewed-sha — merge-sweep.sh:332's documented fallback when the ledger
      #                 has no row, and mc_rebase's record rebind (which only
      #                 writes the file when it already exists). Both were no-ops
      #                 for every pool build.
      # The rest are the head-bound and refuter evidence: the findings that caused
      # a demotion, the suite re-run the re-review was told outranks everything,
      # and headbound-outcome — the one word that tells a reader whether a
      # reviewer said BLOCK or nobody answered at all.
      # The loop is [ -s ]-guarded, so an absent file costs one mexec and writes
      # nothing.
      # merged-review2.md and harness-suite-fix.txt join them 2026-09-12, when the
      # three lenses started running together: under LENSES_PARALLEL=1 the one
      # re-review that adjudicates all of them writes merged-review2.md, and the
      # suite re-run the re-reviewer is told outranks every claim goes to
      # harness-suite-fix.txt. Without these two, a pool build's fanned-back
      # verdicts would arrive on the hub with their reasoning left on the machine.
      # gate.txt and gate-run.tail.txt are the pre-PR selection gate's record: on
      # the hub they are the only place a pool build's could-not-run says why.
      # This list is pinned equal to POOL_RECORD_FILES (bin/lib/pool-record.sh,
      # BH-7429) by tests/pool-record-lib.bh-7429-test.sh: the machine's build
      # record carries the same names, and tests grep this file for them.
      for A in plan.md review.md security-review.md security-review-run.txt refute-review.md \
               merged-review2.md harness-suite-fix.txt \
               qa.md e2e.md evidence.md changed-files.txt \
               reviewed-sha headbound-outcome headbound-review.md headbound-review-run.txt harness-suite-head.txt \
               pipeline.log cost.csv validate.txt red.txt green.txt mutation-check.txt context.json gh-stderr.log \
               execute-transcript.md stop-reason.txt ticket-meta.json gate.txt gate-run.tail.txt; do
        T=$(mktemp); if mexec "$MID" "base64 -w0 $RB/$A 2>/dev/null" > "$T" && [ -s "$T" ]; then base64 -d "$T" > "$LOCAL/$A" 2>/dev/null; fi; rm -f "$T"
      done
      # The machine's bill, under the machine's own box id. Before the RESULT is
      # assembled and long before the machine is reused or destroyed: from here on
      # every path leads to next_job_or_destroy, and a destroyed machine's rows
      # would have nowhere left to come from. Covers the deferral path too — a
      # deferred build still paid for whatever stages it ran. The machine's own
      # Fly seconds for this job join them first, as one infra row (BH-4019).
      pool_fly_cost_row
      push_pool_cost_rows "$LOCAL" "pool-$P-$MID"
      # THE MACHINE'S FAILOVERS.LOG COMES HOME TOO (2026-09-23 pool loop). The
      # ladder's class notes and the vendor's own error text are written there
      # and nowhere else, so a machine destroyed after a failed stage took the
      # only evidence of WHY with it. Tail-bounded: a reused machine's log holds
      # every job it ran.
      T=$(mktemp); if mexec "$MID" "tail -c $POOL_RELAY_FAILOVERS_BYTES /data/harness/logs/failovers.log 2>/dev/null | base64 -w0" > "$T" && [ -s "$T" ]; then base64 -d "$T" > "$LOCAL/failovers.log" 2>/dev/null; fi; rm -f "$T"
      # Full canonical RESULT (rline + TIER + PR lines), not just the head-1.
      T=$(mktemp); if mexec "$MID" "base64 -w0 /run/harness/RESULT 2>/dev/null" > "$T" && [ -s "$T" ]; then base64 -d "$T" > "$LOCAL/RESULT" 2>/dev/null; fi; rm -f "$T"
      [ -s "$LOCAL/RESULT" ] || echo "$RES" > "$LOCAL/RESULT"
    fi
    RLINE=$(head -1 "$LOCAL/RESULT")
    # BH-7116: a row-sourced PLAN_BLOCKED gets plan.md from the ledger.
    command -v pb_hub_copy >/dev/null 2>&1 && { PBH=$(pb_hub_copy "$HARNESS" "$P" "$LOCAL" 2>/dev/null); [ -z "$PBH" ] || say "$KEY: $PBH"; }
    # DID THE ACCOUNT REFUSE? (2026-09-14; re-read 2026-09-23) A pool machine
    # cannot cool its own account down: bin/agent-call.sh's cooldown is fenced on
    # ACCOUNT_ROUTING + ACCT_NAME, and neither rides the bundle. So the hub
    # decides here, while it still knows which account the machine leased.
    #
    # It used to grep the machine's failovers.log for usage-limit words. That
    # matched 0 times, ever: the CLI prints "You've hit your weekly limit", and
    # the ladder's own notes in that file carry the class, never the vendor's
    # text. The stage's verdict line is the one place the fact is always stated:
    # RUNNER_EXHAUSTED (or seen=...account-exhausted) is in the RESULT, and
    # `exhausted=` names the runners that ran out — so an OpenRouter key at its
    # limit does not park a healthy Claude account. A line from an older image
    # with no `exhausted=` is read the way it always meant: this account.
    # `resets_at=` is the CLI's own reset time; the cooldown then lasts until it.
    # And the ticket's pin to this account goes, or its next launch would be
    # steered straight back to it.
    if [ -n "$MACCT" ] && command -v pool_account_cooldown >/dev/null 2>&1; then
      case "$RLINE" in
        *RUNNER_EXHAUSTED*|*seen=*account-exhausted*)
          XRUN=$(printf '%s\n' "$RLINE" | sed -n 's/.* exhausted=\([a-z0-9,._-]*\).*/\1/p' | head -1)
          case ",${XRUN:-claude}," in
            *,claude,*)
              XRESET=$(printf '%s\n' "$RLINE" | sed -n 's/.* resets_at=\([0-9][0-9]*\).*/\1/p' | head -1)
              pool_account_cooldown "$MACCT" "pool-$P-$KEY" "$XRESET"
              # Verified, not assumed: pool_account_cooldown answers 0 even
              # when its write failed, and the hold decision below trusts this.
              command -v account_cooling >/dev/null 2>&1 && account_cooling claude "$MACCT" && ACOOLED=1
              command -v pool_account_unpin >/dev/null 2>&1 && pool_account_unpin "$P" "$KEY" "$MACCT"
              say "account $MACCT ran out on $MID during $KEY — cooled down on the hub${XRESET:+ until $(date -u -d "@$XRESET" '+%Y-%m-%d %H:%MZ' 2>/dev/null || echo "$XRESET")} and unpinned; the next launches skip it" ;;
          esac ;;
      esac
    fi
    # >>> pool console preview reap
    # --- A CONSOLE PREVIEW IS NOT A BUILD (BH-8030) ---------------------------
    # A CP-<pr>-<head8>-<job> machine ran the console preview lane's build and
    # Pages upload (bin/lib/console-preview-job.sh). Its RESULT line 1 closes
    # the row `done`, and the hub lane (bin/console-preview-deploy.sh) reads it
    # there: QA, the comment and the state file are the lane's. There is no PR
    # to verify and no board close-out. A CPV_ word on any other key, or any
    # other word on a CP key (a stand-down excepted: the BUILD_DEFERRED arm
    # below owns it), is a RESULT nobody can apply: the row is FAILED, and the
    # build path never sees it.
    CPK=0; case "$KEY" in CP-*) CPK=1 ;; esac
    CPW=0; case "$RLINE" in CPV_*) CPW=1 ;; esac
    if [ "$CPW" = 1 ] || { [ "$CPK" = 1 ] && [[ "$RLINE" != BUILD_DEFERRED* ]]; }; then
      : > "$LOCAL/COMMENTED"
      if [ "$CPW" = 1 ] && [ "$CPK" = 1 ]; then
        QROW done "$KEY" "$(head -1 "$LOCAL/RESULT" | head -c 400)"
        say "reaped console preview $KEY from $MID: $(head -1 "$LOCAL/RESULT" | head -c 120)"
      else
        QROW failed "$KEY" "console preview RESULT and row key do not match; row FAILED, not requeued"
        HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: the RESULT ($(head -c 80 "$LOCAL/RESULT" | tr '\n' ' ')) and the row key do not match — a CPV_ word belongs to a CP- row and a CP- row answers only a CPV_ word. The queue row is FAILED and NOT requeued, and the RESULT is never read as a build. The RESULT is at $LOCAL/RESULT"
        say "console preview $KEY: RESULT/key mismatch — row failed, RESULT at $LOCAL/RESULT"
      fi
      next_job_or_destroy
      continue
    fi
    # <<< pool console preview reap
    # >>> pool rereview reap
    # --- A RE-REVIEW IS NOT A BUILD EITHER (BH-7635) --------------------------
    # An RR-<pr>-<head8> machine ran the conductor's head-bound re-review
    # (bin/lib/rereview-job.sh). Its RESULT goes to mc_pool_rereview_apply,
    # which writes the hub job file headbound_review reads; nothing here posts,
    # and there is no PR to verify and no board close-out. A REREVIEW word on
    # any other key, or any other word on an RR key (a stand-down excepted: the
    # BUILD_DEFERRED arm below owns it), is a RESULT nobody can apply, so the
    # row is FAILED and the build path never sees it. rc 127 is seeded, as in
    # the rebase reap, so a box without the lib takes the refusal path.
    RRK=0; case "$KEY" in RR-*) RRK=1 ;; esac
    RRW=0; case "$RLINE" in REREVIEWED*|REREVIEW_*) RRW=1 ;; esac
    if [ "$RRW" = 1 ] || { [ "$RRK" = 1 ] && [[ "$RLINE" != BUILD_DEFERRED* ]]; }; then
      : > "$LOCAL/COMMENTED"
      if [ "$RRW" = 1 ] && [ "$RRK" = 1 ]; then
        RRRC=127
        fp_mc_lib_load || true
        command -v mc_pool_rereview_apply >/dev/null 2>&1 \
          && { mc_pool_rereview_apply "$P" "$KEY" "$LOCAL/RESULT"; RRRC=$?; }
        if [ "$RRRC" = 0 ]; then
          QROW done "$KEY" "$(head -1 "$LOCAL/RESULT" | head -c 200)"
          say "pool rereview RESULT reaped for $KEY from $MID: $(head -1 "$LOCAL/RESULT" | head -c 80) — job file written"
          "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$P" --arg k "$KEY" --arg r "$(head -1 "$LOCAL/RESULT" | head -c 120)" '{kind:"build",project:$p,ticket_key:$k,stage:"pool_rereview",detail:$r}')" >/dev/null 2>&1 || true
        else
          # Left CLAIMED, as a refused rebase apply is: nothing re-materialises a
          # claimed row, so the read is not bought twice while someone looks.
          HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: pool rereview RESULT reaped ($(head -c 80 "$LOCAL/RESULT" | tr '\n' ' ')) but mc_pool_rereview_apply answered rc=$RRRC — the queue row stays CLAIMED, no hub re-review job file was written, and nothing retries this on its own. The RESULT is at $LOCAL/RESULT"
          say "rereview $KEY: apply refused rc=$RRRC — row left claimed, RESULT at $LOCAL/RESULT"
        fi
      else
        RRREC="no hub job file was marked"
        fp_mc_lib_load || true
        case "$KEY" in
          RR-*) command -v mc_pool_rereview_fail >/dev/null 2>&1 \
                  && mc_pool_rereview_fail "$P" "$KEY" "the pool machine answered a RESULT that is not a re-review" \
                  && RRREC="the hub re-review job file is marked lane-failed, so the conductor retries the read with no strike on the PR" ;;
          RB-*) command -v mc_pool_rebase_fail >/dev/null 2>&1 \
                  && mc_pool_rebase_fail "$P" "$KEY" "the pool machine answered a re-review RESULT to a rebase job" \
                  && RRREC="the hub rebase job file is marked failed" ;;
        esac
        QROW failed "$KEY" "re-review RESULT and row key do not match; row FAILED, not requeued"
        HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: the RESULT ($(head -c 80 "$LOCAL/RESULT" | tr '\n' ' ')) and the row key do not match — a re-review word belongs to an RR- row and an RR- row answers only a re-review word. The queue row is FAILED and NOT requeued, and the RESULT is never read as a build; $RRREC. The RESULT is at $LOCAL/RESULT"
        say "rereview $KEY: RESULT/key mismatch — row failed, RESULT at $LOCAL/RESULT"
      fi
      next_job_or_destroy
      continue
    fi
    # <<< pool rereview reap
    # >>> pool leadreview reap
    # --- A LEAD REVIEW IS NOT A BUILD EITHER (BH-8027) ------------------------
    # An LR-<pr>-<head8> machine ran bin/lead-review.sh item, which posted its
    # own result to /api/lead-reviews. Nothing is applied here: LEAD_REVIEWED
    # closes the row done, LEAD_REVIEW_SETUP_FAILED closes it failed, and the
    # box's next tick decides again (bin/lib/lead-pool.sh). A lead-review word
    # on another key, or another word on an LR key (BUILD_DEFERRED excepted:
    # its arm below owns it), is a RESULT nobody can apply: the row is FAILED.
    LRK=0; case "$KEY" in LR-*) LRK=1 ;; esac
    LRW=0; case "$RLINE" in LEAD_REVIEWED*|LEAD_REVIEW_*) LRW=1 ;; esac
    if [ "$LRW" = 1 ] || { [ "$LRK" = 1 ] && [[ "$RLINE" != BUILD_DEFERRED* ]]; }; then
      : > "$LOCAL/COMMENTED"
      if [ "$LRW" = 1 ] && [ "$LRK" = 1 ]; then
        case "$RLINE" in
          LEAD_REVIEWED*) QROW done "$KEY" "${RLINE:0:200}" ;;
          *) QROW failed "$KEY" "${RLINE:0:200}" ;;
        esac
        say "pool lead review reaped for $KEY from $MID: ${RLINE:0:80} — the machine posted its own result"
        "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$P" --arg k "$KEY" --arg r "${RLINE:0:120}" '{kind:"build",project:$p,ticket_key:$k,stage:"pool_leadreview",detail:$r}')" >/dev/null 2>&1 || true
      else
        LRREC="nothing on the hub was marked"
        case "$KEY" in
          RB-*) fp_mc_lib_load || true
                command -v mc_pool_rebase_fail >/dev/null 2>&1 \
                  && mc_pool_rebase_fail "$P" "$KEY" "the pool machine answered a lead-review RESULT to a rebase job" \
                  && LRREC="the hub rebase job file is marked failed" ;;
        esac
        QROW failed "$KEY" "lead-review RESULT and row key do not match; row FAILED, not requeued"
        HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: the RESULT ($(head -c 80 "$LOCAL/RESULT" | tr '\n' ' ')) and the row key do not match — a lead-review word belongs to an LR- row and an LR- row answers only a lead-review word. The queue row is FAILED and NOT requeued, and the RESULT is never read as a build; $LRREC. The RESULT is at $LOCAL/RESULT"
        say "leadreview $KEY: RESULT/key mismatch — row failed, RESULT at $LOCAL/RESULT"
      fi
      next_job_or_destroy
      continue
    fi
    # <<< pool leadreview reap
    # >>> pool fixround reap
    # --- A FIX ROUND IS NOT A BUILD EITHER (BH-8065) --------------------------
    # An FXR-<id>-<ck8> machine ran bin/fix-round-claim.sh --run-pool, which
    # posted its own finish to /api/fix-rounds/finish as the claiming box.
    # Nothing is applied here: FIX_ROUND_FINISHED and FIX_ROUND_SKIPPED close
    # the row done, FIX_ROUND_SETUP_FAILED closes it failed. A fix-round word on
    # another key, or another word on an FXR key (BUILD_DEFERRED excepted: its
    # arm below owns it), is a RESULT nobody can apply: the row is FAILED.
    FXK=0; case "$KEY" in FXR-*-*) FXK=1 ;; esac
    FXW=0; case "$RLINE" in FIX_ROUND_*) FXW=1 ;; esac
    if [ "$FXW" = 1 ] || { [ "$FXK" = 1 ] && [[ "$RLINE" != BUILD_DEFERRED* ]]; }; then
      : > "$LOCAL/COMMENTED"
      if [ "$FXW" = 1 ] && [ "$FXK" = 1 ]; then
        case "$RLINE" in
          FIX_ROUND_FINISHED*|FIX_ROUND_SKIPPED*) QROW done "$KEY" "${RLINE:0:200}" ;;
          *) QROW failed "$KEY" "${RLINE:0:200}" ;;
        esac
        say "pool fix round reaped for $KEY from $MID: ${RLINE:0:80} — the machine posted its own finish"
        "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$P" --arg k "$KEY" --arg r "${RLINE:0:120}" '{kind:"build",project:$p,ticket_key:$k,stage:"pool_fixround",detail:$r}')" >/dev/null 2>&1 || true
      else
        FXREC="nothing on the hub was marked"
        case "$KEY" in
          RB-*) fp_mc_lib_load || true
                command -v mc_pool_rebase_fail >/dev/null 2>&1 \
                  && mc_pool_rebase_fail "$P" "$KEY" "the pool machine answered a fix-round RESULT to a rebase job" \
                  && FXREC="the hub rebase job file is marked failed" ;;
        esac
        QROW failed "$KEY" "fix-round RESULT and row key do not match; row FAILED, not requeued"
        HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: the RESULT ($(head -c 80 "$LOCAL/RESULT" | tr '\n' ' ')) and the row key do not match — a fix-round word belongs to an FXR- row and an FXR- row answers only a fix-round word. The queue row is FAILED and NOT requeued, and the RESULT is never read as a build; $FXREC. The RESULT is at $LOCAL/RESULT"
        say "fixround $KEY: RESULT/key mismatch — row failed, RESULT at $LOCAL/RESULT"
      fi
      next_job_or_destroy
      continue
    fi
    # <<< pool fixround reap
    # >>> pool rebase reap
    # --- A REBASE IS NOT A BUILD (BH-486.2, #542) -----------------------------
    # Under REBASE_ON_POOL the machine this loop just reaped ran a rebase, not a
    # build: there is no PR to verify against GitHub, no result the owning box
    # owes a client a comment for, and nothing for the merge queue. The five
    # first words are bin/lib/rebase-job.sh's vocabulary and nothing else on
    # this branch; everything below it is the build path, untouched.
    #
    # The apply is the hub's half — it writes the rebase job file and the ledger
    # row and attempts the approval rebind. It either did that (rc 0) or it did
    # not, and "did not" includes the function not being here at all: rc 127 is
    # seeded before the call so a half-synced box takes the refusal path rather
    # than falling through to the build one.
    case "$RLINE" in
      REBASED*|CONFLICT*|GATE_RED*|REBASE_*)
        RBRC=127
        fp_mc_lib_load || true
        command -v mc_pool_rebase_apply >/dev/null 2>&1 \
          && { mc_pool_rebase_apply "$P" "$KEY" "$LOCAL/RESULT"; RBRC=$?; }
        # This directory owes no board close-out — there is no ticket to comment
        # on — and without the sentinel three sweeps read it as one that does:
        # bin/pipeline-health.sh check 4 ("uncommented result >1h", forever),
        # bin/triage-gate.sh's results-sweep gate (it globs builds/pool-<p>-*)
        # and bin/orphan-reconcile.sh's UNSWEPT loop, which would each hand a
        # REBASED dir to a session to close out "ticket <pr>".
        # DEFERRED would claim the build stood down and RELAYED that custody
        # moved to a box; both are false. Stamped on BOTH paths: on the refused
        # one the ALERTS line below is the page, and check 4 paging the same
        # directory an hour later is the same fact a second time.
        : > "$LOCAL/COMMENTED"
        if [ "$RBRC" = 0 ]; then
          : > "$LOCAL/REBASE"
          QROW done "$KEY" "$(head -c 200 "$LOCAL/RESULT")"
          RBTIM=$(sed -n 's/^TIMINGS: //p' "$LOCAL/RESULT" 2>/dev/null | head -1)
          say "reaped rebase $KEY from $MID: $(head -c 80 "$LOCAL/RESULT" | tr '\n' ' ')${RBTIM:+ timings: $RBTIM}"
          "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$P" --arg k "$KEY" --arg r "$(head -c 120 "$LOCAL/RESULT")" '{kind:"build",project:$p,ticket_key:$k,stage:"pool_rebase",detail:$r}')" >/dev/null 2>&1 || true
        else
          # The row is left CLAIMED on purpose: nothing re-materialises a claimed
          # row, so the rebase does not silently run twice while someone reads
          # this line. Nothing requeues it either — bin/jobs-watchdog.sh sweeps
          # only the triage/preplan/pr-* classes — so this is manual cleanup, and
          # the line says where the evidence is. No beat either: a rebase that
          # did not apply is not a finished anything.
          HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: pool rebase RESULT reaped ($(head -c 80 "$LOCAL/RESULT" | tr '\n' ' ')) but mc_pool_rebase_apply answered rc=$RBRC — the queue row stays CLAIMED, no hub-side rebase job file was written, and nothing retries this on its own. The RESULT is at $LOCAL/RESULT"
          say "rebase $KEY: apply refused rc=$RBRC — row left claimed, RESULT at $LOCAL/RESULT"
        fi
        next_job_or_destroy
        continue ;;
    esac
    # <<< pool rebase reap
    # A push reported rejected whose push in fact landed (BH-6821): the hub
    # opens the PR and RLINE becomes PR_CREATED, which the gate below verifies.
    command -v ppr_reap_landed >/dev/null 2>&1 && { ppr_reap_landed || true; }
    # --- A DEFERRAL IS NOT A RESULT (2026-09-11, the pool-cap refusal class) --
    # bin/run-build.sh writes BUILD_DEFERRED + exit 3 for "not now, not a
    # failure" — a busy slot, a key already building, a file overlap, or a
    # ledger claim REFUSED by a concurrency rule. On a normal box that is
    # harmless: nothing closes the queue row and the next tick re-offers the
    # ticket. Here it was fatal, because the reap below files ANY reaped RESULT
    # as `done` — so a build that never started was recorded as a finished one
    # and the ticket was never offered again. That is how project-5 TK-268 and
    # TK-270 each burned three machines today, and project-4 TK-1515/1566/1571/1576
    # one apiece: every pool machine boots as box `pool-<project>`, so the
    # `box * build 1` rule counted the whole pool as one box and refused every
    # claim after the first.
    #
    # So a deferral is REQUEUED, not closed, and it says so where the hub can
    # see it — the run-build ALERT line is written on the machine's own
    # ALERTS.log and dies with the machine. The build dir stays for audit; the
    # relay does not run, because there is no result to hand anyone and a
    # close-out sweep has nothing to close.
    if [ "${RLINE#BUILD_DEFERRED}" != "$RLINE" ]; then
      # A CLAIM REFUSED BY THE DB NEVER RAN (BH-1279). "BUILD_DEFERRED REFUSED
      # <scope> :: <reason>" is job_open's rc=9 shape (bin/lib/jobs/jobs.sh) —
      # a phase-6 concurrency rule, a pause flag, or a stale retry (job-retry's
      # own REFUSED) — and run-build.sh writes it before anything else runs.
      # This machine's spawn already counted against POOL_SPAWN_CAP_PER_KEY
      # (spawn_one records unconditionally, BH-1075), and for every OTHER
      # BUILD_DEFERRED shape that is correct: a busy slot, this key already
      # building, a file overlap, a push rejected downstream all mean the
      # machine genuinely ran for a while. A refused claim never did, so
      # counting it the same way turned one fleet-wide concurrency-rule
      # refusal into per-key POOL_DEFER_TO_HUMAN parking within two ticks (17
      # keys, 2026-09-21). Un-record ONLY this shape; the deferral bookkeeping
      # below (deferrals, requeue) is unchanged either way.
      # A LANE FAILURE NEVER RAN THE TICKET EITHER (2026-09-23): the same
      # un-record, for the same reason — see POOL_LANE_FAIL_HOLD_S. Only while
      # the hold is armed: with it off, the per-key cap is the one thing left
      # that bounds a lane failure's respawns, so it keeps counting.
      # A DIRTY MACHINE NEVER RAN THE TICKET EITHER (BH-5021): a build slot was
      # still held on it after the runner's cleanup, so the machine was at
      # fault, not the ticket. Un-recorded and uncounted like a lane failure,
      # but no project hold: one dirty machine is not a lane outage, and
      # next_job_or_destroy destroys it rather than reusing it.
      LANEFAIL=0; pool_lane_failure "$RLINE" && LANEFAIL=1
      DIRTYSLOT=0; case "$RLINE" in BUILD_DEFERRED*"slot held on this machine"*) DIRTYSLOT=1 ;; esac
      # A DEAD TOKEN IS NOT THE TICKET (BH-5025.2): requeued with the deferral
      # count unchanged and no hold, and the machine is destroyed, not reused.
      # The spawn stays on the per-key cap, which bounds a broken hub mint. A
      # lane failure wins, so its hold is never weakened.
      pool_token_failure "$RLINE" && [ "$LANEFAIL" = 0 ] && TOKFAIL=1
      # A HOTFIX THAT DEFERRED ON A REUSED MACHINE gets a fresh one next time
      # (BH-5025.2): `fresh_spawn` rides the queue file and the row meta, and the
      # reuse handoff in next_job_or_destroy skips it.
      DFS=false
      [ "$MHF" = true ] && [ -n "$MREUSED" ] && [ "$LANEFAIL" = 0 ] && [ "${POOL_HOTFIX_FRESH_AFTER_DEFER:-1}" != 0 ] && DFS=true
      # AN OVERLAP OR After: WAIT NEVER RAN THE TICKET EITHER (BH-5912): the
      # machine stood down before a plan, on a sibling's build. Counting it let
      # a key behind a chain of siblings spend its whole cap on stand-downs.
      # The cap does not bound this loop; `deferrals` below still advances, so
      # DEFER_MAX and then the resolver's capped rebuild ladder do.
      if [[ "$RLINE" == "BUILD_DEFERRED REFUSED "* ]] || [ "$DIRTYSLOT" = 1 ] \
         || pool_overlap_deferral "$RLINE" \
         || { [ "$LANEFAIL" = 1 ] && [ "$POOL_LANE_FAIL_HOLD_S" -gt 0 ]; }; then
        pool_spawn_cap_unrecord "$KEY" "$SPAWNCAPTS"
      fi
      # >>> push-rejected terminal (BH-1075)
      if [[ "$RLINE" == "BUILD_DEFERRED push of ticket/"* ]] && [[ "$RLINE" == *"rejected"* ]]; then
        # A remote that diverged from the built head is requeued ONCE from the
        # remote head instead (BH-6821, bin/lib/pool-push-rejected.sh).
        if command -v ppr_reap_diverged >/dev/null 2>&1 && ppr_reap_diverged; then
          next_job_or_destroy
          continue
        fi
        BR=$(pool_key_branch "$KEY")
        HEADSHA=$(branch_head_rest "$BR")
        pool_terminal_write "$KEY" "$BR" "${HEADSHA:-unknown}" "$RLINE" "$TICKET"
        : > "$LOCAL/TERMINAL"
        : > "$LOCAL/COMMENTED"
        # AND THE ROW CLOSES (review round 2, Important-3). A terminal that left
        # its row `claimed` was a row nothing could act on: the watchdog requeues
        # it on a TTL, the gate refuses it, and the ledger never says what
        # happened. `failed` with the reason is what the terminal file already
        # records, in the one place a human or bin/blocked-resolver.sh looks.
        QROW failed "$KEY" "push to ticket/$(printf '%s' "$KEY" | tr '[:upper:]' '[:lower:]') rejected at ${HEADSHA:-unknown} — terminal, not respawned (state/pool/$P/$KEY.terminal)"
        say "terminal $KEY: push rejected at ${HEADSHA:-unknown} — not requeued"
        command -v ppr_terminal_note >/dev/null 2>&1 && ppr_terminal_note
        next_job_or_destroy
        continue
      fi
      # <<< push-rejected terminal
      # The stand-down this deferral advances — `deferrals`, never `attempt`.
      # The pool json carries what the queue file said when the machine was
      # spawned; when that was lost, the deferral build dirs for this key are
      # the honest floor — one per reaped deferral, including this one.
      # A lane failure advances nothing, and the floor below does not count one
      # either — otherwise the first ordinary deferral after a lane outage would
      # be charged for every lane failure that preceded it.
      DNEXT=$((DEFC+1))
      DSEEN=0
      for DRF in "$HARNESS/builds/pool-$P-$KEY-"*/RESULT; do
        [ -f "$DRF" ] || continue
        DRL=$(head -1 "$DRF" 2>/dev/null)
        case "$DRL" in
          BUILD_DEFERRED*"slot held on this machine"*) ;;
          BUILD_DEFERRED*) pool_lane_failure "$DRL" || pool_token_failure "$DRL" || DSEEN=$((DSEEN+1)) ;;
        esac
      done
      [ "$DSEEN" -gt "$DNEXT" ] && DNEXT="$DSEEN"
      { [ "$LANEFAIL" = 1 ] || [ "$DIRTYSLOT" = 1 ]; } && DNEXT="$DEFC"
      [ "$TOKFAIL" = 1 ] && DNEXT="$DEFC"
      DWHY=$(head -c 120 "$LOCAL/RESULT" | tr '\n' ' ')
      # THE BLOCKER THIS STAND-DOWN NAMES (BH-5967), read off the whole first
      # line: the `After:` clause can sit past the 120 characters DWHY keeps.
      DAFTER=""
      command -v defer_after_key >/dev/null 2>&1 && DAFTER=$(defer_after_key "$RLINE") || DAFTER=""
      DMETA=$(jq -nc --argjson d "$DNEXT" --argjson x "$DTHS" --arg sb "$SBASE" --arg hf "$MHF" --arg fs "$DFS" --arg af "$DAFTER" '{deferrals:$d,deaths:$x} + (if $sb == "" then {} else {stack_base:$sb} end) + (if $hf == "true" then {hotfix:true} else {} end) + (if $fs == "true" then {fresh_spawn:true} else {} end) + (if $af == "" then {} else {after:$af} end)')
      # The sentinel is what tells this dir from a build that owes the board a
      # close-out: it has a RESULT and will never have a COMMENTED, so without
      # it bin/pipeline-health.sh pages "uncommented result >1h" for a build
      # that never ran, forever.
      : > "$LOCAL/DEFERRED"
      # A REBASE IS NEVER REQUEUED, IT IS FAILED (BH-542). Both arms below
      # rebuild the queue FILE out of the machine json, and that json carries no
      # `rebase` object — so a requeued RB- row arrives at the next machine as
      # {ticket_id:"21",key:"RB-21-…"}, which the pool dispatches as an ordinary
      # BUILD of "ticket 21" of this project, with a PR and a board comment
      # nobody asked for. That is the same failure bin/fly-dispatch.sh REFUSES a
      # row for; manufacturing it here would walk straight around it.
      #
      # The reason string deliberately contains neither `died N times` nor
      # `deferred N times`: those two are br_from_queue's triggers
      # (bin/blocked-resolver.sh:613-614) and either one would have the resolver
      # rebuild "ticket <pr>" from scratch. No `$QDIR/$KEY.failed.json` either —
      # br_from_queue turns EVERY such file into a pool-died-twice rebuild.
      # Nothing in this pool retries. What DOES recover the PR is the hub job
      # file: mc_pool_rebase_fail marks it `failed` below, so the conductor's
      # failed/stale arm parks the PR in NEEDS_REBASE on its next tick instead
      # of reading a `pool` file as `running` for MC_REBASE_POOL_TIMEOUT_SECS
      # (BH-986 — that claim used to say "re-enqueues on its next tick", which
      # overstated the recovery by up to 90 minutes).
      #
      # COMMENTED because this dir owes the board no close-out (the same
      # reasoning the rebase reap block above states); DEFERRED is already
      # stamped. No `pool_deferred` beat: a rebase is not a build that stood
      # down, and the console would read it as one.
      case "$KEY" in
        RB-*)
          : > "$LOCAL/COMMENTED"
          # The hub job file first: a `pool` file left alone reads as `running`
          # to mc_rb_state until MC_REBASE_POOL_TIMEOUT_SECS, and the ALERTS
          # text below says which of the two recoveries this PR actually gets.
          # `command -v` guarded like the apply above — a half-synced box
          # defines neither, and a missing function must never read as done.
          RBREC="no hub rebase job file could be marked failed, so recovery waits for the pool timeout (MC_REBASE_POOL_TIMEOUT_SECS, default 5400s) to fail the job, and then the NEEDS_REBASE TTL (MC_TTL_NEEDS_REBASE, default 1800s) before a fresh rebase can be queued"
          fp_mc_lib_load || true
          if command -v mc_pool_rebase_fail >/dev/null 2>&1 \
             && mc_pool_rebase_fail "$P" "$KEY" "the pool machine answered BUILD_DEFERRED before the rebase ran"; then
            RBREC="the hub rebase job file for this PR is marked failed, so bin/merge-conductor.sh parks the PR back in NEEDS_REBASE on its next tick; the NEEDS_REBASE TTL (MC_TTL_NEEDS_REBASE, default 1800s) is then what forgets this head's attempt and lets a later tick queue a fresh rebase"
          fi
          # The row reason is a CONSTANT: the runner's own text belongs in the
          # ALERTS line and the log, not in the ledger row (BH-986). It also
          # cannot contain `died N times` / `deferred N times` — br_from_queue
          # pattern-matches those anywhere in a reason and would rebuild ticket
          # $TICKET, which is exactly what this arm exists to prevent.
          QROW failed "$KEY" "rebase machine stood down before the job ran; row FAILED, not requeued"
          HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: rebase machine answered BUILD_DEFERRED ($DWHY) — the queue row is FAILED and NOT requeued, because the requeue rebuilds the queue file without the rebase object and the next machine would run an ordinary BUILD of ticket $TICKET. $RBREC. Evidence: $LOCAL"
          say "rebase $KEY: deferred ($DWHY) — row failed, not requeued"
          next_job_or_destroy
          continue ;;
        RR-*)
          # A RE-REVIEW ROW STANDS DOWN THE SAME WAY (BH-7635): the requeue would
          # lose the rereview object too. The hub job file goes lane-failed, not
          # failed: the machine stood down, which says nothing about the PR.
          : > "$LOCAL/COMMENTED"
          RRREC="no hub re-review job file could be marked lane-failed, so the conductor finds no job for this head and decides again on a later tick"
          fp_mc_lib_load || true
          if command -v mc_pool_rereview_fail >/dev/null 2>&1 \
             && mc_pool_rereview_fail "$P" "$KEY" "the pool machine answered BUILD_DEFERRED before the re-review ran"; then
            RRREC="the hub re-review job file for this head is marked lane-failed, so the conductor retries the read on its next tick with no strike on the PR (MC_RR_LANEFAIL_MAX)"
          fi
          QROW failed "$KEY" "re-review machine stood down before the job ran; row FAILED, not requeued"
          HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: re-review machine answered BUILD_DEFERRED ($DWHY) — the queue row is FAILED and NOT requeued, because the requeue rebuilds the queue file without the rereview object and the next machine would run an ordinary BUILD of ticket $TICKET. $RRREC. Evidence: $LOCAL"
          say "rereview $KEY: deferred ($DWHY) — row failed, not requeued"
          next_job_or_destroy
          continue ;;
        LR-*)
          # A LEAD-REVIEW ROW STANDS DOWN THE SAME WAY (BH-8027): the requeue
          # would lose the leadreview object. The box's next tick puts it again.
          : > "$LOCAL/COMMENTED"
          QROW failed "$KEY" "lead-review machine stood down before the job ran; row FAILED, not requeued"
          HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: lead-review machine answered BUILD_DEFERRED ($DWHY) — the queue row is FAILED and NOT requeued, because the requeue rebuilds the queue file without the leadreview object and the next machine would run an ordinary BUILD of ticket $TICKET. The lead-review tick queues the head again (bin/lib/lead-pool.sh). Evidence: $LOCAL"
          say "leadreview $KEY: deferred ($DWHY) — row failed, not requeued"
          next_job_or_destroy
          continue ;;
        CP-*)
          # A CONSOLE PREVIEW ROW STANDS DOWN THE SAME WAY (BH-8030): the
          # requeue would lose the console_preview object. The hub lane reads
          # the failed row as the box's fault and queues a new row.
          : > "$LOCAL/COMMENTED"
          QROW failed "$KEY" "console preview machine stood down before the job ran; row FAILED, not requeued"
          say "console preview $KEY: deferred ($DWHY) — row failed, not requeued; the hub lane queues a new row"
          next_job_or_destroy
          continue ;;
        FXR-*-*)
          # A FIX-ROUND ROW STANDS DOWN THE SAME WAY (BH-8065): the requeue
          # would lose the fixround object. The fix row stays claimed by the
          # box, and the box's stale re-offer finishes it setup-blocked.
          : > "$LOCAL/COMMENTED"
          QROW failed "$KEY" "fix-round machine stood down before the job ran; row FAILED, not requeued"
          HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: fix-round machine answered BUILD_DEFERRED ($DWHY) — the queue row is FAILED and NOT requeued, because the requeue rebuilds the queue file without the fixround object and the next machine would run an ordinary BUILD of ticket $TICKET. The project box's stale re-offer finishes the fix row setup-blocked (bin/lib/fix-round-pool.sh). Evidence: $LOCAL"
          say "fixround $KEY: deferred ($DWHY) — row failed, not requeued"
          next_job_or_destroy
          continue ;;
      esac
      if [ "$LANEFAIL" = 1 ]; then
        if QROW requeue "$KEY" "$DWHY" "$ATT" "$DMETA" "$TICKET"; then
        jq -nc --arg t "$TICKET" --arg k "$KEY" --argjson a "$ATT" --argjson d "$DNEXT" --argjson x "$DTHS" --arg ts "$(STAMP)" --arg sb "$SBASE" --arg hf "$MHF" '{ticket_id:$t,key:$k,attempt:$a,deferrals:$d,deaths:$x,enqueued_at:$ts} + (if $sb == "" then {} else {stack_base:$sb} end) + (if $hf == "true" then {hotfix:true} else {} end)' > "$QDIR/$KEY.json"
        # ONE ACCOUNT OUT IS NOT THE LANE OUT (BH-1853). When the reap just
        # cooled this machine's account and another account can take the next
        # lease, holding the whole project would only park healthy machines.
        # This machine is destroyed below (its token is the exhausted account)
        # and the next spawn re-leases. Anything else holds, exactly as before.
        if [ "${ACOOLED:-}" = 1 ] && command -v pool_account_others_ok >/dev/null 2>&1 && pool_account_others_ok "$MACCT"; then
          HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: account $MACCT ran out ($DWHY). It is cooled on the hub and another account can serve, so there is no project hold: the ticket is requeued with its deferral count unchanged ($DNEXT), $MID is destroyed rather than reused, and the next spawn takes a fresh lease. Evidence: $LOCAL"
        elif pool_spawn_hold_set "$KEY: $DWHY"; then
          HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: the RUNNER LANE failed, not the ticket ($DWHY). The ticket is requeued with its deferral count unchanged ($DNEXT), and this project's pool spawns and reuses NOTHING for ${POOL_LANE_FAIL_HOLD_S}s (state/pool/$P/_spawn-hold — remove it to lift the hold early; with pool_state_rows on, run bin/pool-state.sh lift-hold $P, which lifts the file and the row). Evidence: $LOCAL"
        fi
        say "LANE FAILURE $KEY: $DWHY — requeued, deferrals unchanged ($DNEXT); project spawn hold $(pool_spawn_held >/dev/null && echo on || echo off)"
        else
          # No project hold for an abandoned ticket's failure: its lines would
          # say the ticket was requeued. The next ticket that hits the lane sets it.
          say "LANE FAILURE $KEY: $DWHY — abandoned by an operator, not requeued"
        fi
      elif [ "$TOKFAIL" = 1 ]; then
        # Before the DEFER_MAX arm, so a dead token can never park a ticket.
        if QROW requeue "$KEY" "$DWHY" "$ATT" "$DMETA" "$TICKET"; then
        jq -nc --arg t "$TICKET" --arg k "$KEY" --argjson a "$ATT" --argjson d "$DNEXT" --argjson x "$DTHS" --arg ts "$(STAMP)" --arg sb "$SBASE" --arg hf "$MHF" --arg fs "$DFS" '{ticket_id:$t,key:$k,attempt:$a,deferrals:$d,deaths:$x,enqueued_at:$ts} + (if $sb == "" then {} else {stack_base:$sb} end) + (if $hf == "true" then {hotfix:true} else {} end) + (if $fs == "true" then {fresh_spawn:true} else {} end)' > "$QDIR/$KEY.json"
        HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: $MID's GitHub token answered 401 (trigger-actor events read). The ticket is requeued with its deferral count unchanged ($DNEXT) and $MID is destroyed rather than reused; the per-key spawn cap still counts this spawn. Evidence: $LOCAL"
        say "TOKEN-401 $KEY: $DWHY — requeued, deferrals unchanged ($DNEXT), $MID destroyed"
        else
          say "TOKEN-401 $KEY: $DWHY — abandoned by an operator, not requeued"
        fi
      # A WAIT IS NOT PARKED BY ITS COUNT, UNTIL IT CHURNS (review of
      # 22e7719c5): after three releases for the same blocker in 24 h the gate
      # keeps the count, and a stand-down at or over the cap then parks here
      # like any other, with its one alert.
      elif [ "$DNEXT" -ge "$DEFER_MAX" ] && { [ -z "$DAFTER" ] || pool_after_churned "$KEY" "$DAFTER"; }; then
        QROW failed "$KEY" "deferred $DNEXT times ($DWHY) — parked for the blocked-resolver"
        HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: pool build DEFERRED ($DWHY) — deferred $DNEXT times now, so the queue row is FAILED. This pool will not re-offer it; bin/blocked-resolver.sh picks the row up on its next tick and rebuilds the ticket fresh against current main (3 tries, then an ABANDONED outcome record). Evidence: $LOCAL"
        say "DEFERRED $KEY x$DNEXT — parked for the blocked-resolver"
      else
        # A WAIT ON A NAMED BLOCKER NEVER PARKS (BH-5967). The row stays queued
        # with `after` in it, past JOBS_QUEUE_DEFER_MAX too, and the spawn gate
        # (pool_after_gate) holds it with no machine until that blocker is done.
        if QROW requeue "$KEY" "$DWHY" "$ATT" "$DMETA" "$TICKET"; then
        jq -nc --arg t "$TICKET" --arg k "$KEY" --argjson a "$ATT" --argjson d "$DNEXT" --argjson x "$DTHS" --arg ts "$(STAMP)" --arg sb "$SBASE" --arg hf "$MHF" --arg fs "$DFS" --arg af "$DAFTER" '{ticket_id:$t,key:$k,attempt:$a,deferrals:$d,deaths:$x,enqueued_at:$ts} + (if $sb == "" then {} else {stack_base:$sb} end) + (if $hf == "true" then {hotfix:true} else {} end) + (if $fs == "true" then {fresh_spawn:true} else {} end) + (if $af == "" then {} else {after:$af} end)' > "$QDIR/$KEY.json"
        if [ -n "$DAFTER" ]; then
          say "DEFERRED $KEY: waits for $DAFTER (stand-down $DNEXT) — row stays queued, held until $DAFTER is done"
          pool_after_loop_alert "$KEY" "$DAFTER" "$DNEXT" "$DWHY"
        else
        HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: pool build DEFERRED ($DWHY) — requeued attempt $DNEXT"
        say "DEFERRED $KEY: $DWHY — requeued attempt $DNEXT"
        fi
        else
          say "DEFERRED $KEY: $DWHY — abandoned by an operator, not requeued"
        fi
      fi
      # The beat says DEFERRED. Beating this as a pool_result would put a build
      # that never ran on the console as one that finished.
      "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$P" --arg k "$KEY" --arg r "$DWHY" '{kind:"build",project:$p,ticket_key:$k,stage:"pool_deferred",detail:$r}')" >/dev/null 2>&1 || true
      next_job_or_destroy
      continue
    fi
    # --- GATE: PR_CREATED is verified against GitHub before the handoff -------
    # (2026-08-14) Stale-RESULT class: a builder writes PR_CREATED and dies (the
    # TK-143/TK-82 branch-collision family) — the reap then hands the watcher a
    # RESULT naming a PR whose push actually rejected, and the board gets a
    # comment linking a PR that does not exist. GitHub is the truth, not the
    # runner's last words: the URL must resolve to an OPEN or MERGED PR, or the
    # first line is rewritten RESULT_UNVERIFIED (which no close-out handler
    # matches) and ONE ALERTS line names it for the alert medic.
    # (BH-709, 2026-09-17) A FAILED READ IS NOT A STATE. The read is REST and
    # answers the status code first — gh_rest_pr_state, the library sourced
    # above — and only an affirmative 404, with the repo itself provably visible
    # to the same token, may be read as "no such PR". Everything else is
    # UNKNOWN: the RESULT is left exactly as the builder wrote it and ONE alert
    # says we could not read it. ONE READ PER TICK (BH-781): 75 means "skip this
    # tick, leave state as it is", and the next */2 reap is the retry.
    # >>> pr verify gate (BH-709)
    # (BH-765, 2026-09-18) A CLAIM WITH NO URL IS A BUILDER DEFECT, and the
    # bare `PR_CREATED` with nothing after it is the same defect as
    # `PR_CREATED  | SIZE: …` — both enter here, and the shape check below
    # decides them from the line alone.
    if [ "${RLINE#PR_CREATED }" != "$RLINE" ] || [ "$RLINE" = "PR_CREATED" ]; then
      PRURL=$(echo "$RLINE" | awk '{print $2}')
      # >>> pr url shape (BH-765)
      # THE ALERT MUST NAME THE RIGHT CULPRIT. Four project-5 builds reaped a
      # RESULT whose first line was `PR_CREATED  | SIZE: 614 product lines … |
      # STACKED on ticket/TK-2212`: the claim was there, the URL was not, so
      # field 2 came out as the literal `|`, the read could not be made at all,
      # and the gate then blamed a gh token that was working perfectly. The
      # shape of field 2 is knowable from the line, before any credential is
      # involved.
      # `RESULT_MALFORMED` starts with `RESULT_`, so it matches neither the
      # `PR_CREATED *` readers (bin/blocked-resolver.sh) nor the
      # `PR_CREATED http*` ones (bin/board-closeout.sh) — the same argument #749
      # makes for PR_CREATE_FAILED and BH-709 for RESULT_UNVERIFIED — and the
      # alert names the build record for the medic.
      if ! [[ "$PRURL" =~ ^https://github\.com/[^/]+/[^/]+/pull/[0-9]+$ ]]; then
        # printf, not sed: RESULT lines legitimately carry '|'.
        { printf 'RESULT_MALFORMED %s\n' "$RLINE"; tail -n +2 "$LOCAL/RESULT"; } > "$LOCAL/RESULT.new" \
          && mv "$LOCAL/RESULT.new" "$LOCAL/RESULT"
        HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: reaped RESULT claims PR_CREATED but field 2 is '$PRURL', not a PR URL — the BUILDER wrote a url-less claim (bin/run-build.sh's result ratchet refuses these since #749; this machine's image predates it or wrote RESULT another way) — rewritten RESULT_MALFORMED. No gh call was made: this is not a token or visibility problem. The build record is at $LOCAL"
        say "MALFORMED $KEY: PR_CREATED with no PR URL in field 2 ('$PRURL') — rewritten RESULT_MALFORMED, no credential involved"
      else
      # <<< pr url shape
      # (2026-09-11) The hub's default gh PAT does not reach every repo the pool
      # builds for (example-org/project-5 and project-7 404 on it), so this check
# rewrote six REAL PRs as RESULT_UNVERIFIED in one evening.
      # (BH-765) Which credential to verify with is not this file's question:
      # bin/lib/gh-repo-token.sh answers it for the whole fleet — the App
      # installation token first when this box is armed, then the default PAT,
      # then the org-admin one — and the by-hand read of the admin env file that
      # used to live here is gone. With the lib absent (a stripped box) nothing
      # is armed and the read falls back to the ambient gh auth, which is what
      # this gate did before 2026-09-11. Only the WORDS app/default/admin/none
      # are ever logged, never the value.
      _VSLUG=$(sed -E 's|https://github.com/([^/]+/[^/]+)/pull/.*|\1|' <<<"$PRURL")
      _VNUM=$(sed -E 's|.*/pull/([0-9]+)$|\1|' <<<"$PRURL")
      _VWHICH=default
      # >>> PR_CREATED verify
      # THE CREDENTIAL IS ARMED FOR THE WHOLE BLOCK (BH-781). The library reads
      # the AMBIENT gh auth, so capturing a token and resetting it immediately —
      # what this gate did while it passed the value to its own reader — would
      # leave every read on the wrong identity. use_token BEFORE token_for, and
      # that order is load-bearing: the seam caches its verdict in the CALLER's
      # shell and `$(gh_repo_token_for …)` is a subshell, so asked in this order
      # the name is a cache hit and the whole gate costs one probe per slug.
      if command -v gh_repo_use_token >/dev/null 2>&1; then
        gh_repo_use_token "$_VSLUG" || true
        _VWHICH=$(gh_repo_token_for "$_VSLUG")
      fi
      # Only ever asked on a path that is about to WRITE an alert: composing the
      # sentence costs a probe of the rungs the ladder did not need, and the
      # point of BH-765 is to stop spending requests nobody reads.
      _vtried() { command -v gh_repo_tried_words >/dev/null 2>&1 && printf ' (%s)' "$(gh_repo_tried_words "$_VSLUG")"; }
      _VRELABEL=""; _VWHY=""
      if [ "$_VWHICH" = none ]; then
        # No identity can see the repo, so there is no read to make: a 404 from
        # a credential that cannot see the repo is the 2026-09-12 shape and may
        # never be read as "no such PR". Fail open — the RESULT stands.
        HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] repo $_VSLUG is INVISIBLE to the default gh token$(_vtried) — $KEY's PR_CREATED ($PRURL) could NOT be verified and is left as-is, NOT relabeled (2026-09-12 shape)"
        say "UNVERIFIABLE $KEY: no identity can see $_VSLUG — RESULT left as PR_CREATED"
      elif ! command -v gh_rest_pr_state >/dev/null 2>&1; then
        # A box whose sync has not landed bin/lib/gh-rest.sh. There is no read,
        # so there is no answer: this is rc 75 by another route, and it takes
        # the rc-75 treatment — RESULT untouched, one alert, next tick retries.
        HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: PR_CREATED ($PRURL) could NOT be verified — bin/lib/gh-rest.sh is not on this box, so there is no REST reader to ask. The RESULT is left as-is, NOT relabeled; the next reap retries. The build record is at $LOCAL"
        say "UNVERIFIABLE $KEY: bin/lib/gh-rest.sh absent — RESULT left as PR_CREATED"
      else
        # A PLAIN COMMAND WITH `> file`, never `$( )`: GH_REST_STATUS is set in
        # the shell that CALLS the helper, and a command substitution takes it
        # to the subshell's grave. BH-781 is the build that got this wrong and
        # made every alert say "HTTP 000" for a 403 the library had classified.
        _VOUT=$(mktemp "${TMPDIR:-/tmp}/pool-prstate.XXXXXX") || _VOUT=""
        if [ -z "$_VOUT" ]; then
          # EVERY unverifiable path writes exactly one ALERTS line, including
          # this one: a `say` goes to the pool log nobody greps, and a box that
          # cannot mktemp leaves every PR_CREATED unverified in silence. The
          # status is set by hand because no request was made — 000 with a
          # reason is what the library itself writes when it never reached the
          # wire, so the line reads the same as any other skip.
          GH_REST_STATUS=000; GH_REST_REASON=no-tmp
          gh_rest_alert "$P" "$KEY PR_CREATED" "$PRURL"
          say "UNVERIFIABLE $KEY: no temp file for the PR read — RESULT left as PR_CREATED"
        else
        gh_rest_pr_state "$_VSLUG" "$_VNUM" > "$_VOUT"; _VRC=$?
        _VSTATE=$(cat "$_VOUT" 2>/dev/null); rm -f "$_VOUT"
        case "$_VRC" in
          0)
            case "$_VSTATE" in
              open|merged) ;;   # verified: RESULT untouched, nothing logged
              closed) _VRELABEL="a CLOSED, unmerged PR"; _VWHY="CLOSED" ;;
              *) _VUNREADABLE=1 ;;
            esac ;;
          44)
            # "No such PR" and "this token cannot see the repo" are different
            # facts (2026-09-12): the second relabeled six REAL PRs as
            # RESULT_UNVERIFIED on 2026-09-11 with an alert that blamed a
            # builder death. So a 404 is only believed once the same identity
            # has answered 2xx for the REPO — and that probe reads its own
            # status too, so a rate-limited probe cannot pass for a visible one.
            gh_rest GET "repos/$_VSLUG" > /dev/null; _PRC=$?
            case "$_PRC" in
              0)  _VRELABEL="no such PR (REST 404, repo visible to the $_VWHICH token)"; _VWHY="ABSENT 404" ;;
              44) HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] repo $_VSLUG is INVISIBLE to the $_VWHICH gh token$(_vtried) — $KEY's PR_CREATED ($PRURL) could NOT be verified and is left as-is, NOT relabeled; fix that token's access to the repo (2026-09-12 shape)"
                  say "UNVERIFIABLE $KEY: repo $_VSLUG invisible to the $_VWHICH gh token — RESULT left as PR_CREATED" ;;
              *)  gh_rest_alert "$P" "$KEY PR_CREATED repo-probe" "$PRURL"
                  say "UNVERIFIABLE $KEY: the repo probe for $_VSLUG answered HTTP $GH_REST_STATUS — RESULT left as PR_CREATED" ;;
            esac ;;
          *) _VUNREADABLE=1 ;;
        esac
        if [ "${_VUNREADABLE:-0}" = 1 ]; then
          # ONE line, naming the HTTP status the library classified and WHICH
          # identity answered. Never the words "no such PR", never a relaunch,
          # never a requeue change: the RESULT is byte-identical.
          gh_rest_alert "$P" "$KEY PR_CREATED" "$PRURL"
          say "UNVERIFIABLE $KEY: HTTP $GH_REST_STATUS reading $PRURL with the $_VWHICH token — RESULT left as PR_CREATED"
          _VUNREADABLE=0
        fi
        fi
      fi
      if [ -n "$_VRELABEL" ]; then
        # printf, not sed: RESULT lines legitimately carry '|' (QA/migration
        # gate notes), which breaks any sed delimiter choice.
        { printf 'RESULT_UNVERIFIED %s\n' "$RLINE"; tail -n +2 "$LOCAL/RESULT"; } > "$LOCAL/RESULT.new" \
          && mv "$LOCAL/RESULT.new" "$LOCAL/RESULT"
        HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: reaped RESULT claims PR_CREATED but GitHub answers $_VRELABEL at '$PRURL' — rewritten RESULT_UNVERIFIED (stale RESULT after a builder death?); the alert medic (bin/alerts-medic.sh) owns this line; the build record is at $LOCAL"
        say "UNVERIFIED $KEY: PR_CREATED did not check out against GitHub ($PRURL -> $_VWHY)"
      fi
      command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
      # <<< PR_CREATED verify
      fi   # end: field 2 is a PR URL
    fi
    # <<< pr verify gate
    # The row this key was claimed under is CLOSED HERE, before the machine is
    # reused or destroyed and before any relay is attempted: a row left
    # `claimed` can never be queued again, and one left `queued` would be
    # materialised into a second build of work that has just finished.
    # >>> reap row close (BH-614)
    # ...but a build that opened NO PR is not finished work, and `done` is the
    # queue saying it was. Both failed-create words close the row FAILED: the
    # ratchet's own PR_CREATE_FAILED and the RESULT_MALFORMED the shape gate
    # above writes for an older image's url-less claim. RESULT_UNVERIFIED keeps
    # closing `done` — that is a PR nobody could READ, which the alert medic
    # owns, not a create that failed. bin/blocked-resolver.sh deliberately does
    # NOT read this row: the RECORD is its intake, behind a 90-minute floor that
    # is bin/pr-url-reconcile.sh's window to prove the PR did open after all.
    case "$(head -1 "$LOCAL/RESULT")" in
      PR_CREATE_FAILED*|"RESULT_MALFORMED PR_CREATED"*) QROW failed "$KEY" "$(head -c 200 "$LOCAL/RESULT")" ;;
      *)                                                QROW done   "$KEY" "$(head -c 200 "$LOCAL/RESULT")" ;;
    esac
    # <<< reap row close
    say "reaped $KEY from $MID: $(head -c 80 "$LOCAL/RESULT")"
    beat_json=$(jq -nc --arg p "$P" --arg k "$KEY" --arg r "$(head -c 120 "$LOCAL/RESULT")" '{kind:"build",project:$p,ticket_key:$k,stage:"pool_result",detail:$r}')
    "$HARNESS/bin/beat.sh" "$beat_json" >/dev/null 2>&1 || true
    command -v ppr_after_reap >/dev/null 2>&1 && { ppr_after_reap || true; }
    mkdir -p "$HARNESS/state/remote-results/$P"
    # machine_build_dir IS THE CROSS-PATH IDENTITY (BH-1041) — the dir the
    # MACHINE built in, which is also what this build's ledger row is named
    # after. `result` here is truncated at 200 bytes and `build_dir` is the
    # hub's own path, so neither could ever be compared with the row.
    MBDIR=$(grep -oE '^BUILD_DIR: .*' "$LOCAL/RESULT" | sed 's/^BUILD_DIR: //' | head -1)
    jq -nc --arg k "$KEY" --arg t "$TICKET" --arg d "$LOCAL" --arg r "$(head -c 200 "$LOCAL/RESULT")" \
      --arg mbd "${MBDIR:-}" \
      '{key:$k,ticket_id:$t,build_dir:$d,result:$r,machine_build_dir:$mbd}' > "$HARNESS/state/remote-results/$P/$KEY.json"
    # BH-7519: the reap park. On a lane-run machine this record and the build
    # dir are only here until a write-back carries them home, and the run-end
    # write-back is not reached by a machine that stops hard. Post it now.
    command -v pp_checkpoint >/dev/null 2>&1 && pp_checkpoint "$P" "reap park $KEY"
    # ---- relay to the owning box (2026-08-16, TK-124 stranding) --------------
    # Only project-1 triage runs on the hub, so a non-local project's result
    # parked in the hub's state/remote-results strands forever (PR #318 sat a
    # day until the medic hand-delivered it). Same hand-off fly-results-ingest
    # has had all along: json in the ingest shape + RESULT/review/plan into the
    # box's own build dir, tier-1 APPROVE onto the box merge-queue. On success
    # the hub json is removed (the box copy is live) and the hub dir is stamped
    # RELAYED so pipeline-health's close-out checks know custody moved; on any
    # failure the hub json stays for hand delivery and ONE ALERTS line says so.
    # THE ADDRESS COMES FROM THE REGISTRY (2026-09-11). This was a four-entry
    # case table, one of nine copies across bin/ — a box that moved had to be
    # found in all nine. fleet.conf carries `tailnet_ip` now. Unknown fails
    # CLOSED: no address, no ssh, because an empty target is `root@` and that
    # hangs rather than errors.
    RBOX=$("$HARNESS/bin/fleet-conf.sh" --tailnet-ip "$P" 2>/dev/null) || RBOX=""
    # The record's OWN pr, never the first url on it: a failed create folded the
    # STACKED note's PARENT url into line 1 and this grep relayed it as the
    # build's PR (BH-848). No lib on this hub yet = the grep it always did.
    if command -v result_own_pr_url >/dev/null 2>&1; then
      RPR=$(result_own_pr_url "$LOCAL/RESULT" || true)
    else
      RPR=$(grep -oE 'https://github.com/[^ ]+/pull/[0-9]+' "$LOCAL/RESULT" | head -1)
    fi
    RTIER=$(grep -oE '^TIER: [12]' "$LOCAL/RESULT" | grep -oE '[12]' | head -1)
    RVERDICT=$(verdict_parse -L "$LOCAL/review.md" 2>/dev/null) || RVERDICT=""

    # ---- ROW FIRST, ssh ONLY IF THE ROW IS NOT THERE (2026-09-11) -----------
    # The box already PULLS this result: bin/run-triage.sh's ledger staging loop
    # reads the `result` artifact and stages the same build dir, with the
    # one-dir guard that stops it and the ssh push both landing. So both paths
    # have been running and the guard has been deduping them. This makes the
    # ssh push what it should be — a fallback for the case where the ledger did
    # not take the result.
    #
    # READ BACK, do not assume. The artifact is written by run-build.sh ON THE
    # MACHINE, not here, so "the row exists" is something this reap can only
    # learn by asking. A write we did not make and did not verify is exactly
    # the kind of assumption that would silently strand a close-out.
    # THREE OUTCOMES, NOT TWO, and they are genuinely different failures:
    #   FEED_OK=0   the ledger could not be read at all — say nothing about what
    #               it contains. Unknown is not "absent".
    #   RES_ROW=0   the ledger answered and this build's result is NOT in it.
    #   RES_ROW=1   the result is there and the box will pull it.
    # Collapsing the first two into one message sends a human to look for a
    # missing row when the real fault is a dead worker, or the reverse — and
    # until BH-1041 it also sent the same ssh push for both, which is the
    # duplicate close-out this ticket removes. bin/lib/builder-direct.sh's
    # bd_result_in_ledger is the one place the three answers are decided now;
    # this reap and the hub's ingest read the same rc.
    #
    # FEED_ASKABLE separates "the ledger blinked" from "this hub has no jobs
    # client at all". The second can never answer, so deferring on it would
    # defer for ever: it pushes over ssh exactly as this reap always has.
    FEED_OK=0; RES_ROW=0; FEED_ASKABLE=0
    if command -v job_artifact_feed >/dev/null 2>&1 \
       && command -v bd_result_in_ledger >/dev/null 2>&1; then
      FEED_ASKABLE=1
      # MBDIR (the machine's own build dir, read off the RESULT above) is what
      # makes this "is THIS BUILD's row there", not "is a row for this ticket
      # key there" — a second build of a key whose first build has a row would
      # otherwise read as delivered and never be relayed (BH-1041 round-1).
      bd_result_in_ledger "$P" "$KEY" "$(head -1 "$LOCAL/RESULT")" "${MBDIR:-}"
      case "$?" in
        0) FEED_OK=1; RES_ROW=1 ;;
        1) FEED_OK=1 ;;
        *) ;;
      esac
    fi

    # The tier-1 APPROVE hand-off is a ROW too (#224). Its failure counts as the
    # ledger not having taken this result: a merge that never gets queued is
    # invisible, which is the one outcome worth an ssh for.
    # The tier-1 APPROVE hand-off is a ROW too (#224). A FAILED merge row is its
    # own fault and its own remedy: the RESULT is still in the ledger and the box
    # will still pull it, so re-pushing the whole result over ssh would be a
    # duplicate of work that is already travelling. Only the merge-queue touch
    # is missing, so only the merge-queue touch is sent.
    RPRNUM=""; MQ_NEEDED=0; MQ_ROW=0
    if [ "${RTIER:-}" = "1" ] && [ "${RVERDICT:-}" = "APPROVE" ] && [ -n "$RPR" ]; then
      RPRNUM=$(grep -oE '[0-9]+$' <<<"$RPR")
      if [ -n "$RPRNUM" ]; then
        MQ_NEEDED=1
        if command -v merge_queue_put >/dev/null 2>&1 \
           && merge_queue_put "$P" "$RPRNUM" "" "tier-1 APPROVE from pool build $KEY" >/dev/null 2>&1; then
          MQ_ROW=1
          say "tier-1 APPROVE $KEY -> merge_queue row for #$RPRNUM (no ssh touch)"
        fi
      fi
    fi

    # ONE ALERT PER PROJECT PER DAY, PER REASON. The dated flag carries the
    # reason so a merge-row failure cannot silence a dead ledger, or the other
    # way round — they are different outages with different remedies.
    PR_ALERT() { # PR_ALERT <reason-slug> <line>
      local f="$HARNESS/flags/alerted-pool-relay-$1-$P-$(date -u +%Y%m%d)"
      say "$KEY: $2"
      [ -f "$f" ] && return 0
      mkdir -p "$HARNESS/flags" 2>/dev/null && touch "$f" 2>/dev/null
      HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $2"
      return 0
    }

    # The merge-queue touch failed twice (mq_touch). Its own reason slug, so the
    # mergerow flag of the same day cannot swallow it; PR_ALERT's say line puts
    # every affected key, rc included, in fly-pool.log after the flag is set.
    MQT_RC=0
    MQ_TOUCH_FAILED() {
      PR_ALERT mergetouch "MERGE-QUEUE TOUCH FAILED — the tier-1 APPROVE for #$RPRNUM ($KEY) is queued NOWHERE: the merge_queue row failed and the ssh touch to $RBOX failed rc=$MQT_RC after one retry. Deliver it by hand: ssh root@$RBOX touch /root/harness/state/merge-queue/$P/$RPRNUM. (One alert per project per day; every affected key is in fly-pool.log.)"
    }

    RELAY_MODE=none
    if [ "$FEED_OK" = 0 ] && [ "$FEED_ASKABLE" = 1 ]; then
      RELAY_MODE=defer
      PR_ALERT unreadable "LEDGER UNREADABLE — the coordination DB did not answer, so nothing was pushed for $KEY: the result is held hub-side in $LOCAL + state/remote-results/$P/$KEY.json, re-asked every pool tick, and nothing goes to the box until the ledger answers. Pushing on an unknown is how one build became two close-out comments on a client's ticket. Check worker/jobs + HARNESS_SECRET. (One alert per project per day; every affected key is in fly-pool.log.)"
    elif [ "$FEED_OK" = 0 ]; then
      RELAY_MODE=full
      PR_ALERT unreadable "LEDGER UNREADABLE — this hub has no jobs client at all, so the result for $KEY was pushed to ${RBOX:-no box} over ssh instead. Results are NOT lost; the row path is. Check that bin/jobs-client.sh and bin/lib/builder-direct.sh are synced onto this box. (One alert per project per day; every affected key is in fly-pool.log.)"
    elif [ "$RES_ROW" = 0 ]; then
      RELAY_MODE=full
      PR_ALERT noresultrow "NO RESULT ROW — the ledger answered but carries no result for $KEY, so it was pushed to ${RBOX:-no box} over ssh instead. The build's own run-build.sh did not record its result artifact. (One alert per project per day; every affected key is in fly-pool.log.)"
    elif [ "$MQ_NEEDED" = 1 ] && [ "$MQ_ROW" = 0 ]; then
      # The result travels by row; ONLY the merge enqueue needs a hand.
      RELAY_MODE=touch
      PR_ALERT mergerow "MERGE-QUEUE ROW FAILED — the result for $KEY is in the ledger and the box will pull it, but the tier-1 APPROVE for #$RPRNUM could not be enqueued as a row, so only the merge-queue touch went over ssh. (One alert per project per day; every affected key is in fly-pool.log.)"
    fi

    if [ "$RELAY_MODE" = none ]; then
      # Custody moved through the LEDGER. The hub json stays where it is: nothing
      # was pushed, so nothing has provably arrived, and deleting the hub-side
      # copy on the strength of a row the box has not read yet would throw away
      # the only other copy. RELAYED still marks custody for the close-out
      # checks (bin/queued-fly-relayed.sh).
      touch "$LOCAL/RELAYED"
      say "result $KEY is in the ledger (tier=${RTIER:-?} verdict=${RVERDICT:-?}) — no ssh push; the box pulls it"
    elif [ "$RELAY_MODE" = defer ]; then
      # ---- HELD: THE LEDGER COULD NOT BE ASKED (BH-1041) ---------------------
      # NOTHING is pushed and NOTHING is stamped. RELAYED would say custody
      # moved, and it has not. The hub json written above stays where it is —
      # it and this dir are the whole record until the ledger answers — and
      # pool_relay_retry re-asks at the top of every tick.
      touch "$LOCAL/RELAY_DEFERRED"
      say "$KEY held hub-side: the ledger could not be asked whether its result is already a row, so nothing was pushed. Re-asked every tick; the record is at $LOCAL"
      # The merge enqueue needs no ledger, so it still rides: a tier-1 APPROVE
      # whose #224 row failed would otherwise wait out the whole outage.
      if [ "$MQ_NEEDED" = 1 ] && [ "$MQ_ROW" = 0 ] && [ -n "$RPRNUM" ] && [ -n "$RBOX" ]; then
        mq_touch "$RBOX" "$P" "$RPRNUM"; MQT_RC=$?
        [ "$MQT_RC" = 0 ] || MQ_TOUCH_FAILED
      fi
    elif [ -n "$RBOX" ]; then
      # The merge-queue touch rides BOTH fallbacks, and only when the row did
      # not take it: a successful #224 row needs no filename.
      if [ "$MQ_NEEDED" = 1 ] && [ "$MQ_ROW" = 0 ] && [ -n "$RPRNUM" ]; then
        mq_touch "$RBOX" "$P" "$RPRNUM"; MQT_RC=$?
        [ "$MQT_RC" = 0 ] || MQ_TOUCH_FAILED
      fi

      if [ "$RELAY_MODE" = touch ]; then
        # The RESULT is travelling by row, so the hub json stays exactly as it
        # does on the row path and custody is still the ledger's.
        touch "$LOCAL/RELAYED"
        if [ "$MQT_RC" = 0 ]; then
          say "merge-queue touch for #$RPRNUM sent to $RBOX; the result itself travels by row"
        else
          say "merge-queue touch for #$RPRNUM to $RBOX FAILED rc=$MQT_RC; the result itself travels by row"
        fi
      else
        # ---- FULL FALLBACK: the ledger has no usable result for this build ---
        # The push, the hub-json removal, the RELAYED stamp and the failure
        # alert all live in pool_push_full, so the deferral retry above does
        # exactly what this reap does rather than a near-copy of it.
        pool_push_full "$P" "$KEY" "$TICKET" "$LOCAL" "$RBOX" "${RPR:-}" "${RTIER:-}"
      fi
    else
      # No row AND no address: the result stays hub-side and says so loudly.
      # This is the fail-closed end of the registry lookup — never `root@`.
      HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: the ssh fallback is needed ($RELAY_MODE) and $P has no tailnet_ip in fleet.conf — parked hub-side in state/remote-results/$P/$KEY.json + $LOCAL for hand delivery"
      say "$KEY needs the $RELAY_MODE fallback and there is no tailnet_ip for $P — parked hub-side"
    fi
    next_job_or_destroy
    continue
  fi
  # liveness: machine gone or heartbeat stale -> requeue
  DEAD=0
  # `failed` and `suspended` are deaths too (BH-660). They used to fall through
  # to the heartbeat probe, whose mexec cannot reach a machine that is not
  # started: HB came back empty, DEAD stayed 0, and the file and the machine both
  # survived the tick — for ever, tick after tick, with the job never requeued.
  case "$MSTATE" in ""|stopped|destroyed|failed|suspended) DEAD=1 ;; esac
  if [ "$DEAD" = 0 ]; then
    HB=$(mexec "$MID" 'now=$(date +%s); h=$(stat -c %Y /run/harness/heartbeat 2>/dev/null || echo 0); echo $((now-h))' | tr -dc '0-9')
    [ -n "$HB" ] && [ "$HB" -gt 900 ] && DEAD=1
  fi
  # BH-7107: a HOLD or a closed issue cancels this live build once the verdict
  # has stood POOL_INFLIGHT_HOLD_GRACE_S, and releases its slot.
  if [ "$DEAD" = 0 ] && command -v pool_inflight_hold_step >/dev/null 2>&1 && pool_inflight_hold_step; then continue; fi
  if [ "$DEAD" = 0 ]; then
    # A live machine may be most of the way through its token's hour — replace it
    # before the push that would otherwise be rejected, not after.
    rotate_gh_token "$MID" "$MF"
    # Preview-snapshot refresh (2026-08-13): wait-preview.sh on the machine
    # resolves QA preview URLs from state/vercel-deploys/<project>.json (the
    # Deployments API 403s the fleet PAT). One mput per live machine per tick,
    # and only when the hub copy's mtime moved — tracked in a dotfile sidecar
    # (invisible to this loop's *.json glob).
    SNAP_SRC="$HARNESS/state/vercel-deploys/$P.json"
    if [ -s "$SNAP_SRC" ]; then
      SNAP_MT=$(stat -c %Y "$SNAP_SRC" 2>/dev/null || echo 0)
      LAST_MT=$(cat "$POOL/.$MID.snapmt" 2>/dev/null || echo 0)
      if [ "$SNAP_MT" != "$LAST_MT" ]; then
        mput "$MID" "$SNAP_SRC" "/data/harness/state/vercel-deploys/$P.json" \
          && echo "$SNAP_MT" > "$POOL/.$MID.snapmt"
      fi
    fi
  fi
  if [ "$DEAD" = 1 ]; then
    NEXT=$((ATT+1))
    # The park is decided on DNEXT (deaths this loop has OBSERVED, including
    # this one), never on NEXT (the enqueuer's attempt number). `attempt` is
    # still carried forward untouched so every existing reader — the dispatcher,
    # the ledger, bin/jobs-watchdog.sh — sees exactly what it always did.
    DNEXT=$((DTHS+1))
    # The disposition is named here because an RB- key is NOT requeued (the arm
    # below): announcing a requeue that never happens is how a log stops being
    # evidence. Every other key reads byte-for-byte the line it always did.
    DDISP="requeue attempt=$NEXT deaths=$DNEXT"
    case "$KEY" in RB-*) DDISP="rebase row FAILED, not requeued" ;; RR-*) DDISP="re-review row FAILED, not requeued" ;; CP-*) DDISP="console preview row FAILED, not requeued" ;; LR-*) DDISP="lead-review row FAILED, not requeued" ;; FXR-*-*) DDISP="fix-round row FAILED, not requeued" ;; esac
    # A JOB THAT FINISHED NEVER GETS HERE (BH-2643, BH-7719): a not-started
    # machine whose own pool-result row carries a result was reaped from that
    # row above. What reaches this line has no result at all.
    DWORD="died"; DKIND="dead machine"
    say "machine $MID for $KEY dead (state=${MSTATE:-gone}) attempt=$ATT deaths=$DTHS -> $DDISP"
    destroy_machine "$MID" "$DKIND for $KEY (state=${MSTATE:-gone})"
    # The dead machine's Fly seconds too (BH-7719): nothing else bills them.
    # A temp dir stands in for the build dir; ledger.tsv keeps it to one row.
    # Its own name, not $LOCAL: $LOCAL is a $HARNESS build dir everywhere else.
    if DCOST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pool-dead-cost.XXXXXX" 2>/dev/null); then
      LOCAL="$DCOST_DIR"
      pool_fly_cost_row || true
      push_pool_cost_rows "$LOCAL" "pool-${P}-${MID}"
      case "$DCOST_DIR" in */pool-dead-cost.*) rm -rf -- "$DCOST_DIR" ;; esac
    else
      say "fly cost row: skipped:no-temp-dir $MID $KEY"
    fi
    LOCAL=""
    # Same rule as next_job_or_destroy: the row is closed and the job requeued
    # whatever the destroy answered, and the sweep is what recovers the machine.
    rm -f "$MF" "$POOL/.$MID.snapmt" "$POOL/.$MID.puterr"
    # >>> machines rows (BH-1035)
    # Close the registry row using the actual destroy outcome.
    machines_row_close "$MID"
    # <<< machines rows
    command -v pool_account_release >/dev/null 2>&1 && pool_account_release "$MID"
    # A DEAD REBASE IS FAILED, NEVER REQUEUED (BH-542) — the same reasoning the
    # deferral arm above states, for the same reason: both branches below
    # rebuild the queue file from the machine json, which carries no `rebase`,
    # so the next machine would run an ordinary BUILD of ticket $TICKET (= the
    # PR number). This runs BEFORE the `DNEXT -ge 2` park, so no
    # `$QDIR/$KEY.failed.json` is written at either death count —
    # br_from_queue turns every one of those into a pool-died-twice rebuild of
    # the same ticket. The reason matches neither `died N times` nor
    # `deferred N times`, br_from_queue's two row triggers. The machine is
    # already destroyed and its file removed, exactly as for any other key.
    # Recovery is the hub job file, not this pool: mc_pool_rebase_fail marks it
    # `failed` so the conductor parks the PR in NEEDS_REBASE on its next tick
    # (BH-986 — the old text promised a re-enqueue that could not happen for up
    # to MC_REBASE_POOL_TIMEOUT_SECS).
    case "$KEY" in
      RB-*)
        RBREC="no hub rebase job file could be marked failed, so recovery waits for the pool timeout (MC_REBASE_POOL_TIMEOUT_SECS, default 5400s) to fail the job, and then the NEEDS_REBASE TTL (MC_TTL_NEEDS_REBASE, default 1800s) before a fresh rebase can be queued"
        fp_mc_lib_load || true
        if command -v mc_pool_rebase_fail >/dev/null 2>&1 \
           && mc_pool_rebase_fail "$P" "$KEY" "the pool machine died (state=${MSTATE:-gone}) with no RESULT"; then
          RBREC="the hub rebase job file for this PR is marked failed, so bin/merge-conductor.sh parks the PR back in NEEDS_REBASE on its next tick; the NEEDS_REBASE TTL (MC_TTL_NEEDS_REBASE, default 1800s) is then what forgets this head's attempt and lets a later tick queue a fresh rebase"
        fi
        QROW failed "$KEY" "rebase machine $MID died (state=${MSTATE:-gone}); row FAILED, not requeued"
        HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: rebase machine $MID died (state=${MSTATE:-gone}) with no RESULT — the queue row is FAILED and NOT requeued, because a requeue rebuilds the queue file from the machine json, which carries no rebase object, and the next machine would run an ordinary BUILD of ticket $TICKET. $RBREC; nothing here retries."
        continue ;;
      RR-*)
        # A DEAD RE-REVIEW is failed and never requeued, for the reason above;
        # its hub job file goes lane-failed (BH-7635): a dead machine is our
        # outage, so the PR loses no strike and the conductor retries the read.
        RRREC="no hub re-review job file could be marked lane-failed, so the conductor finds no job for this head and decides again on a later tick"
        fp_mc_lib_load || true
        if command -v mc_pool_rereview_fail >/dev/null 2>&1 \
           && mc_pool_rereview_fail "$P" "$KEY" "the pool machine died (state=${MSTATE:-gone}) with no RESULT"; then
          RRREC="the hub re-review job file for this head is marked lane-failed, so the conductor retries the read on its next tick with no strike on the PR (MC_RR_LANEFAIL_MAX)"
        fi
        QROW failed "$KEY" "re-review machine $MID died (state=${MSTATE:-gone}); row FAILED, not requeued"
        HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: re-review machine $MID died (state=${MSTATE:-gone}) with no RESULT — the queue row is FAILED and NOT requeued, because a requeue rebuilds the queue file from the machine json, which carries no rereview object, and the next machine would run an ordinary BUILD of ticket $TICKET. $RRREC; nothing here retries."
        continue ;;
      LR-*)
        # A DEAD LEAD REVIEW is failed and never requeued, for the reason above
        # (BH-8027). Its claim stops beating, and the lead-review tick queues
        # the head again (bin/lib/lead-pool.sh, at most LRP_RETRY_MAX times).
        QROW failed "$KEY" "lead-review machine $MID died (state=${MSTATE:-gone}); row FAILED, not requeued"
        HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: lead-review machine $MID died (state=${MSTATE:-gone}) with no RESULT — the queue row is FAILED and NOT requeued, because a requeue rebuilds the queue file from the machine json, which carries no leadreview object, and the next machine would run an ordinary BUILD of ticket $TICKET. The lead-review tick queues the head again."
        continue ;;
      CP-*)
        # A DEAD CONSOLE PREVIEW is failed and never requeued (BH-8030), for
        # the reason above. The hub lane reads the failed row as the box's
        # fault, alerts once, and queues a new row on its next tick.
        QROW failed "$KEY" "console preview machine $MID died (state=${MSTATE:-gone}); row FAILED, not requeued"
        continue ;;
      FXR-*-*)
        # A DEAD FIX ROUND is failed and never requeued (BH-8065), for the
        # reason above. The fix row stays claimed by the project box, and its
        # stale re-offer finishes it setup-blocked (bin/lib/fix-round-pool.sh).
        QROW failed "$KEY" "fix-round machine $MID died (state=${MSTATE:-gone}); row FAILED, not requeued"
        HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: fix-round machine $MID died (state=${MSTATE:-gone}) with no RESULT — the queue row is FAILED and NOT requeued, because a requeue rebuilds the queue file from the machine json, which carries no fixround object, and the next machine would run an ordinary BUILD of ticket $TICKET. The project box's stale re-offer finishes the fix row setup-blocked."
        continue ;;
    esac
    if [ "$DNEXT" -ge 2 ]; then
      QROW failed "$KEY" "died $DNEXT times (state=${MSTATE:-gone}) — parked for the blocked-resolver"
      # THE ROW ON THE LINE ABOVE IS THE PARK (BH-1026.3). Under the flag $QDIR
      # is this tick's scratch directory, so a sidecar written here would vanish
      # with it — and it is not needed: br_from_queue reads the `died N times`
      # reason the QROW just wrote, and bin/healthcheck.sh counts the same rows.
      # REDUNDANT BY CONSTRUCTION TODAY, and deliberately kept: ROWS_ONLY=1 can
      # only be true when $QDIR is the temp dir, so this is belt and braces
      # against a later change that points $QDIR back at state/build-queue/<p>/
      # and silently starts writing parks into it again.
      [ "${ROWS_ONLY:-0}" = 1 ] || \
        jq -nc --arg t "$TICKET" --arg k "$KEY" --argjson a "$NEXT" --argjson d "$DEFC" --argjson x "$DNEXT" --arg ts "$(STAMP)" --arg sb "$SBASE" --arg hf "$MHF" '{ticket_id:$t,key:$k,attempt:$a,deferrals:$d,deaths:$x,enqueued_at:$ts} + (if $sb == "" then {} else {stack_base:$sb} end) + (if $hf == "true" then {hotfix:true} else {} end)' > "$QDIR/$KEY.failed.json"
      "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$P" --arg akey "pool-fail:$P:$KEY" --arg l "Pool build $KEY died $DNEXT times — row FAILED, handed to bin/blocked-resolver.sh for a fresh rebuild against current main." '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1 || true
    else
      if QROW requeue "$KEY" "machine ${MID} $DWORD (state=${MSTATE:-gone})" "$NEXT" "$(jq -nc --argjson d "$DEFC" --argjson x "$DNEXT" --arg sb "$SBASE" --arg hf "$MHF" '{deferrals:$d,deaths:$x} + (if $sb == "" then {} else {stack_base:$sb} end) + (if $hf == "true" then {hotfix:true} else {} end)')" "$TICKET"; then
      jq -nc --arg t "$TICKET" --arg k "$KEY" --argjson a "$NEXT" --argjson d "$DEFC" --argjson x "$DNEXT" --arg ts "$(STAMP)" --arg sb "$SBASE" --arg hf "$MHF" '{ticket_id:$t,key:$k,attempt:$a,deferrals:$d,deaths:$x,enqueued_at:$ts} + (if $sb == "" then {} else {stack_base:$sb} end) + (if $hf == "true" then {hotfix:true} else {} end)' > "$QDIR/$KEY.json"
      else
        say "$KEY: machine ${MID} died (state=${MSTATE:-gone}) — abandoned by an operator, not requeued"
      fi
    fi
  fi
done
# BH-7475: a stop in the REAP walk ends the tick here. Unvisited machines keep
# their files for the next tick; the sweep and the spawn walk wait for it too.
if [ -n "${PTS_STOP:-}" ]; then wait; exit 0; fi

