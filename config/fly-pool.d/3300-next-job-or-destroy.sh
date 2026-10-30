next_job_or_destroy() { # hand this machine the next queued job, or destroy it
  # Reads the REAP loop's own variables (MID, MSTATE, KEY, MF) the way PR_ALERT
  # below reads $KEY — this is the loop's tail, lifted out so BOTH terminal
  # paths can reach it: a reaped RESULT and a reaped BUILD_DEFERRED. A deferral
  # leaves a machine that did nothing at all, so it is the one most worth
  # handing straight on rather than paying ~5 min to spawn its replacement.
  # ---- machine reuse within a burst (2026-08-13) ---------------------------
  # A spawn costs ~5 min (boot + harness sync + env + warm-up). If another job
  # is already queued for this project, hand it to the machine we just reaped
  # instead of destroying it: the runner's idle loop (fly/builder-runner.sh)
  # waits up to 10 min for a new job.json. Reset order matters — clear the
  # canonical RESULT FIRST (or the next tick would reap the OLD result under
  # the NEW key), kill QA strays, then land job.json atomically via tmp+mv.
  # env bundle, harness sync, and the preview snapshot stay: same project,
  # same machine. Everything job-scoped (branch, build dir) is re-derived by
  # run-build.sh per job. Any reuse failure falls back to destroy; the job
  # stays queued for a normal spawn next tick.
  REUSED=0
  # ---- no reuse of a default-token machine (the operator, 2026-09-15 "no reuse") ----
  # The Claude account rides with the MACHINE (see below), so a machine that
  # booted with the default project-6 token would keep spending project-6 on
  # every job it is handed, however many max accounts have headroom. While
  # account routing is armed, such a machine is destroyed at reap instead: the
  # queued job spawns fresh next tick and takes a max lease (~1-2 min of boot
  # per job is the price). A machine that already carries a lease is still
  # reused, and so is every machine when routing is not armed — then there is
  # no better token to boot into. POOL_REUSE_DEFAULT_TOKEN=1 restores the old
  # behaviour for a rollback without touching the routing itself.
  REUSE_OK=1
  if [ "$MSTATE" = "started" ] && [ -z "${MACCT:-}" ] && [ "${POOL_REUSE_DEFAULT_TOKEN:-0}" != 1 ] \
     && command -v pool_account_armed >/dev/null 2>&1 && pool_account_armed >/dev/null 2>&1; then
    REUSE_OK=0
    say "$MID shipped the default token and account routing is armed — destroying instead of reusing (the next spawn takes a max lease)"
  fi
  # ...and no reuse under a lane-failure hold: the next job would meet the same
  # exhausted lane on this machine (2026-09-23). Guarded, because the routing
  # suite sources this function alone.
  if [ "$REUSE_OK" = 1 ] && command -v pool_spawn_held >/dev/null 2>&1 && pool_spawn_held >/dev/null; then
    REUSE_OK=0
    say "$MID: project spawn hold is on (runner lane failed) — destroying instead of reusing"
  fi
  # ...and never reuse the machine whose own account the reap just cooled: its
  # token IS that account. The next spawn takes a fresh lease (BH-1853).
  if [ "$REUSE_OK" = 1 ] && [ "${ACOOLED:-}" = 1 ]; then
    REUSE_OK=0
    say "$MID: its account ${MACCT:-?} just ran out — destroying instead of reusing (the next spawn re-leases)"
  fi
  # ...and never reuse a machine whose GitHub token answered 401 (BH-5025.2).
  if [ "$REUSE_OK" = 1 ] && [ "${TOKFAIL:-0}" = 1 ]; then
    REUSE_OK=0
    say "$MID: its GitHub token answered 401 — destroying instead of reusing"
  fi
  # ...and never reuse a machine whose last build deferred because a build slot
  # was still held on it after the runner's own cleanup (BH-5021). The runner
  # preflight and the BUILDER_EXEC slot gate are the only writers of that
  # wording; the plain box `all N slots busy` does not match. `${LOCAL:-}`
  # because the suites that source this function alone set no LOCAL.
  if [ "$REUSE_OK" = 1 ] && [ -n "${LOCAL:-}" ] && [ -r "${LOCAL:-}/RESULT" ]; then
    case "$(head -1 "$LOCAL/RESULT" 2>/dev/null)" in
      BUILD_DEFERRED*"slot held on this machine"*)
        REUSE_OK=0
        say "$MID: its build deferred on a build slot still held on the machine — destroying instead of reusing" ;;
    esac
  fi
  # ...and never reuse a machine that holds a read token for its ticket's spec
  # repos (BH-6576): the next ticket did not ask for that access.
  if [ "$REUSE_OK" = 1 ] && command -v spec_repos_machine_has >/dev/null 2>&1 && spec_repos_machine_has "$MF"; then
    REUSE_OK=0
    say "$MID carries a read token for $KEY's spec repos — destroying instead of reusing"
  fi
  # ...and never reuse a machine that ran a console preview row (BH-8030): the
  # hub pushed it the Pages token for that row alone.
  case "${KEY:-}" in
    CP-*) if [ "$REUSE_OK" = 1 ]; then
            REUSE_OK=0
            say "$MID ran console preview row $KEY — destroying instead of reusing"
          fi ;;
  esac
  if [ "$MSTATE" = "started" ] && [ "$REUSE_OK" = 1 ]; then
    # Hotfix jobs first when the helper is there, today's mtime order when it is
    # not. The fallback is not defensive noise: tests/pool-account-routing-test.sh
    # extracts THIS FUNCTION ALONE and sources it with nothing else from the
    # file, so a hard dependency on a helper defined 250 lines up makes the reuse
    # loop find no jobs at all and destroy a machine that had work waiting.
    NJLIST=$(ls -tr "$QDIR"/*.json 2>/dev/null)
    command -v hotfix_first >/dev/null 2>&1 && NJLIST=$(hotfix_first $NJLIST)
    for NJ in $NJLIST; do
      # THE TICK BUDGET ENDS THIS SEARCH TOO (hub incident 2026-10-19). Each row
      # below can cost an issue read (spec_repos_load, 5-20 s) BEFORE the spawn
      # gate that knows the budget, so 156 queued rows ran a tick 25 minutes past
      # its 600 s budget with the pool lock held. A spent budget leaves REUSED=0:
      # the machine is destroyed below exactly as when no row fits, and every row
      # stays queued. `command -v` because tests/pool-account-routing-test.sh
      # sources this function alone; POOL_TICK_T0 unset means no budget applies.
      if [ -n "${POOL_TICK_T0:-}" ] && command -v pool_tick_budget_spent >/dev/null 2>&1 && pool_tick_budget_spent; then
        say "$MID: tick budget of ${POOL_TICK_BUDGET_S:-600}s spent — the reuse search stops, the machine is destroyed and its rows stay queued"
        break
      fi
      case "$NJ" in *.failed.json) continue;; esac
      [ -f "$NJ" ] || continue
      NKEY=$(jq -r '.key // ""' "$NJ"); NTICKET=$(jq -r '.ticket_id // ""' "$NJ"); NATT=$(jq -r '.attempt // 0' "$NJ")
      NDEF=$(jq -r '.deferrals // 0' "$NJ" 2>/dev/null); case "$NDEF" in ''|*[!0-9]*) NDEF=0 ;; esac
      NDTH=$(jq -r '.deaths // 0' "$NJ" 2>/dev/null); case "$NDTH" in ''|*[!0-9]*) NDTH=0 ;; esac
      NSB=$(jq -r '.stack_base // ""' "$NJ" 2>/dev/null); case "$NSB" in *[!A-Za-z0-9._/-]*) NSB="" ;; esac
      NHF=$(jq -r '.hotfix // false' "$NJ" 2>/dev/null); case "$NHF" in true) NHF=true ;; *) NHF=false ;; esac
      NFS=$(jq -r '.fresh_spawn // false' "$NJ" 2>/dev/null); case "$NFS" in true) ;; *) NFS=false ;; esac
      [ -n "$NKEY" ] || continue
      # never the key we just reaped (the runner detects new work partly by
      # key change), never a key already running elsewhere in the pool
      [ "$NKEY" = "$KEY" ] && continue
      # ...and never a console preview row (BH-8030): its token is pushed at
      # spawn, so it takes a fresh machine.
      case "$NKEY" in CP-*) continue ;; esac
      # pool_key_live (BH-5001) reads the claim too; the bare grep is the
      # fallback for the suites that source this function alone.
      if command -v pool_key_live >/dev/null 2>&1; then pool_key_live "$NKEY" && continue
      else grep -ls "\"key\": *\"$NKEY\"" "$POOL"/*.json >/dev/null 2>&1 && continue; fi
      # ...and never a hotfix that already deferred on a reused machine: its
      # next attempt is a fresh spawn (BH-5025.2). Before pool_spawn_decision,
      # so a skipped row neither records a spawn nor takes a claim.
      if [ "$NHF" = true ] && [ "$NFS" = true ] && [ "${POOL_HOTFIX_FRESH_AFTER_DEFER:-1}" != 0 ]; then
        say "$NKEY: hotfix deferred on a reused machine last time — left for a fresh spawn (POOL_HOTFIX_FRESH_AFTER_DEFER)"
        continue
      fi
      # ...and never a ticket whose body declares spec repos (BH-6576): this
      # machine has no read token for them. A fresh spawn mints one.
      # The read uses the token the spawn gates read this repo with: the hub's
      # default PAT can 404 on a project repo (see pool_slug_token_arm).
      SPEC_REPOS=""
      if command -v spec_repos_load >/dev/null 2>&1; then
        command -v pool_slug_token_arm >/dev/null 2>&1 && pool_slug_token_arm
        SPEC_REPOS_GH_TOKEN="${POOL_SLUG_TOK:-}" spec_repos_load "${POOL_SLUG:-}" "$NTICKET" 2>>"${LOG:-/dev/null}"
        if [ -n "$SPEC_REPOS" ]; then
          say "$NKEY declares spec repos — left for a fresh spawn"
          continue
        fi
      fi
      # ...and never a row the spawn gate would refuse (BH-1075, review round 1).
      # THIS HANDOFF IS A BUILD, metered exactly like a spawned one — it just
      # skips the ~5 minutes of boot. Without this line every gate in
      # pool_spawn_decision (HOLD, an open PR, a push-rejected terminal, the
      # per-key cap) applies to a machine the pool SPAWNS and to nothing else,
      # so a held or terminal row still reaches a builder through the back door.
      # Guarded with `command -v` for the reason the hotfix_first fallback above
      # states: tests/pool-account-routing-test.sh extracts THIS FUNCTION alone
      # and sources it with nothing else from this file, and a hard dependency
      # on a helper defined 1000 lines up would make the reuse loop find no jobs
      # at all and destroy a machine that had work waiting.
      # ...and never a job the dispatch mode holds (BH-6350): the spawn loop's
      # one tick line names it, so nothing is said here.
      if command -v dm_job_admit >/dev/null 2>&1 && ! dm_job_admit "$NJ"; then continue; fi
      # BH-7519: a handoff starts a build, which is a spend, so it needs the
      # project lease like a spawn does. Before the cap record and the claim:
      # nothing is taken yet, so a lost lease leaves every row queued, and
      # REUSED=0 destroys the machine (destroy_machine fences too; the sweep
      # retries it).
      if command -v pp_fence_ok >/dev/null 2>&1 && ! pp_fence_ok; then
        say "$MID: the project lease is lost — no handoff of $NKEY, the rows stay queued"
        break
      fi
      if command -v pool_spawn_decision >/dev/null 2>&1; then
        if ! pool_spawn_decision "$NJ" "$NKEY" "$NTICKET"; then
          # BH-7421: the gate answered "budget spent" (it said so once already):
          # end the search like the main walk does, no more rows are read.
          [ -n "${_POOL_BUDGET_SAID:-}" ] && break
          continue
        fi
        # AND IT COUNTS (review round 2, Important-2). The gate above CHECKS the
        # per-key cap on this path and, until this line, nothing ever RECORDED
        # against it: only spawn_one appended to .spawns. A key whose builds
        # keep deferring on a non-push reason is requeued by the reap and handed
        # to the next reaped machine, build after build, with the ledger frozen
        # — so "at most N pool builds per key per 24h regardless of outcome"
        # counted cold spawns only, while this path is a BUILD metered exactly
        # like one (the comment four lines up says so). Recorded HERE, before
        # the mexec that starts it, on spawn_one's own rule: every entry counts
        # regardless of outcome, because a cap that only counts the attempts
        # that worked cannot bound a loop of attempts that do not. RB-* and RR-*
        # rows are exempt from the cap on both paths, so they record nothing here.
        # NHANDOFFTS (BH-1279) carries the recorded line onto $MF below, exactly
        # as SPAWNCAPTS does in spawn_one, so a REFUSED claim on THIS machine's
        # next reap can be un-recorded too.
        NHANDOFFTS=""
        case "$NKEY" in RB-*|RR-*|LR-*|CP-*|FXR-*-*) ;; *) command -v pool_spawn_cap_record >/dev/null 2>&1 && NHANDOFFTS=$(pool_spawn_cap_record "$NKEY" "$MID"); esac
      fi
      # THE CLAIM COMES BEFORE THE HANDOFF (BH-1026.3), for the same reason it
      # comes before a spawn: this is a BUILD, metered exactly like a spawned one
      # (the comment 30 lines up says so), so the row's compare-and-swap is what
      # stops two machines taking one key. It passes the MACHINE — unlike the
      # spawn path, the id is known before the push, and a claimed row that names
      # the machine is what makes "is this key building, and where" answerable
      # without an ssh. A refusal moves to the next queued job rather than
      # destroying this machine: another job may still be waiting for it.
      # `command -v` guarded like every other helper in this function — two
      # suites source it alone.
      if [ "${ROWS_ONLY:-0}" = 1 ] && command -v queue_claim >/dev/null 2>&1; then
        if ! queue_claim "$P" fly "$NKEY" "$MID" >/dev/null 2>&1; then
          say "$NKEY: the queue row refused this claim — not handing it to $MID"
          continue
        fi
      fi
      # AND EVERY EXIT BELOW HANDS IT BACK. The claim is won from here on, and
      # under the flag $NJ lives in this tick's scratch directory — it vanishes
      # with the tick, so the ROW is the only thing that can re-offer this key.
      # Left claimed, it is a build in flight that nothing is running until
      # bin/jobs-watchdog.sh's 6h stale-claim sweep. Written inline rather than
      # through pool_unclaim because tests/pool-account-routing-test.sh and
      # tests/hotfix-cap-exempt-test.sh source THIS FUNCTION ALONE.
      # pkill patterns are bracketed so they don't match mexec's own shell.
      # NO BUILD SLOT RIDES INTO THE NEXT JOB (BH-5021): bin/pool-slot-clean.sh
      # kills whatever still holds a build-slot lock and answers one SLOTCLEAN
      # line. `held` means the kill did not free it, so the machine is destroyed
      # instead of reused, on the same path as a cleanup that failed. An empty
      # answer, or `absent` from a machine whose tarball predates the script,
      # reuses as before: the runner's own preflight is the backstop there.
      SLOTANS=""
      if ! SLOTANS=$(mexec "$MID" "rm -f /run/harness/RESULT; rm -rf /run/harness/preplan; rm -f /run/harness/test-reroute-*; pkill -f '[p]laywright' 2>/dev/null; pkill -f '[c]hromium' 2>/dev/null; if [ -x /data/harness/bin/pool-slot-clean.sh ]; then /data/harness/bin/pool-slot-clean.sh 2>/dev/null; else echo 'SLOTCLEAN absent'; fi; true"); then
        [ "${ROWS_ONLY:-0}" = 1 ] && command -v queue_release >/dev/null 2>&1 \
          && { queue_release "$P" "$NKEY" "machine $MID could not be cleaned for the handoff" >/dev/null 2>&1 || true; }
        break
      fi
      SLOTANS=$(grep -m1 '^SLOTCLEAN ' <<<"$SLOTANS" | tr -d '\r')
      case "$SLOTANS" in
        "SLOTCLEAN held"*)
          say "$MID: build slot still held after cleanup (${SLOTANS#SLOTCLEAN held }) — destroying instead of reusing"
          [ "${ROWS_ONLY:-0}" = 1 ] && command -v queue_release >/dev/null 2>&1 \
            && { queue_release "$P" "$NKEY" "machine $MID still held a build slot after cleanup" >/dev/null 2>&1 || true; }
          # ...and the handoff recorded above never started a build.
          [ -n "${NHANDOFFTS:-}" ] && command -v pool_spawn_cap_unrecord >/dev/null 2>&1 \
            && pool_spawn_cap_unrecord "$NKEY" "$NHANDOFFTS"
          break ;;
        "SLOTCLEAN ok cleaned="*)
          say "$MID: killed a stray build-slot holder before the handoff (${SLOTANS#SLOTCLEAN ok }) — reusing" ;;
      esac
      # >>> pool testhost route refresh
      # BH-8335: the route this machine booted with was cut for its first job.
      # A fresh one (a new app-scoped SSH token) outlives the next job.
      # Fail-soft, like the spawn's.
      if command -v ptr_build >/dev/null 2>&1; then
        TRDIR=$(mktemp -d /dev/shm/pool-tr.XXXX 2>/dev/null) || TRDIR=""
        if [ -n "$TRDIR" ]; then
          chmod 700 "$TRDIR"
          TRERR=$(ptr_build "$TRDIR" "$NKEY" 2>&1 >/dev/null); TRRC=$?
          if [ "$TRRC" = 0 ]; then
            ptr_push "$MID" "$TRDIR" && say "$NKEY: testhost route refreshed on $MID (expires $(ptr_expires "$TRDIR"))"
          elif [ "$TRRC" != 3 ]; then
            say "$NKEY: ${TRERR:-testhost route: not shipped (rc $TRRC)} — $MID keeps the route it has"
          fi
          rm -rf "$TRDIR"
        fi
      fi
      # <<< pool testhost route refresh
      if mput "$MID" "$NJ" /run/harness/job.json.next \
         && mexec "$MID" "mv /run/harness/job.json.next /run/harness/job.json" >/dev/null; then
        rm -f "$NJ"
        # The token rides with the MACHINE, not with the job: a reused machine keeps
        # the credential it booted with, so dropping its expiry here would make the
        # tick blind to a rotation that is due — which is exactly the long-running
        # machine this whole change is about.
        # The Claude account rides with the MACHINE too, and for a stronger reason
        # than the GitHub token: the account's token is already in the bundle on
        # the machine's tmpfs and its lease is already counted, so dropping the
        # name here would leave a lease nothing can attribute and a reap that
        # cannot cool the account down when it refuses.
        jq -nc --arg m "$MID" --arg k "$NKEY" --arg t "$NTICKET" --argjson a "$NATT" --argjson d "$NDEF" --argjson x "$NDTH" --arg ts "$(STAMP)" --arg prev "$KEY" --arg sb "$NSB" --arg hf "$NHF" --arg ge "${GHEXP:-}" --arg gr "${GHROT:-}" --arg aa "${MACCT:-}" --arg sct "${NHANDOFFTS:-}" \
          '{machine:$m,key:$k,ticket_id:$t,attempt:$a,deferrals:$d,deaths:$x,spawned_at:$ts,reused_from:$prev}
           + (if $sb == "" then {} else {stack_base:$sb} end)
           + (if $hf == "true" then {hotfix:true} else {} end)
           + (if $ge == "" then {} else {gh_token_expires_at:$ge} end)
           + (if $gr == "" then {} else {gh_token_rotated_at:$gr} end)
           + (if $aa == "" then {} else {auth_account:$aa} end)
           + (if $sct == "" then {} else {spawn_cap_ts:$sct} end)' > "$MF"
        # >>> machines rows (BH-1035)
        # Record the reuse in the machine registry. Guarded because this
        # function is sourced alone by some pool tests.
        #
        # THE IMAGE FIELD IS EMPTY HERE ON PURPOSE (issue §4). `IMAGE` is first
        # assigned ~900 lines down, in the SPAWN half of the tick, and this
        # function runs from the REAP loop above it — under `set -u` naming it
        # here killed the whole tick with `IMAGE: unbound variable`, after the
        # queue file was consumed and the machine json rewritten but before the
        # reuse was pushed, logged or beaten. A reused machine is still running
        # the image it booted with, which the row already carries from its
        # spawn, so the empty string is the honest value, not a placeholder.
        command -v machines_row >/dev/null 2>&1 && machines_row machine_put "$P" "$APP" "$MID" pool "$NKEY" "$NTICKET" "${MACCT:-}" "" started
        # <<< machines rows
        push_preplan "$MID" "$NKEY"
        push_reroute "$MID" "$NKEY"
        push_build_note "$MID" "$NKEY"
        push_bake_evidence "$MID"
        # Flag-off only: under the flag this claim ran above the push, as a gate.
        [ "${ROWS_ONLY:-0}" = 1 ] || \
          { command -v queue_claim >/dev/null 2>&1 && queue_claim "$P" fly "$NKEY" >/dev/null 2>&1; }
        say "reused $MID for $NKEY (was $KEY)"
        "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$P" --arg k "$NKEY" '{kind:"build",project:$p,ticket_key:$k,stage:"pool_reused"}')" >/dev/null 2>&1 || true
        REUSED=1
      else
        say "reuse push FAILED to $MID for $NKEY — destroying, job stays queued"
        # ...and under the flag "stays queued" is only true if the row goes back.
        [ "${ROWS_ONLY:-0}" = 1 ] && command -v queue_release >/dev/null 2>&1 \
          && { queue_release "$P" "$NKEY" "reuse push to $MID failed" >/dev/null 2>&1 || true; }
      fi
      break
    done
  fi
  # BH-7519: on a lane-run machine the reap's results (the parked
  # state/remote-results record, the build dir, the closed queue row's files) exist
  # only here until a write-back carries them home. Post them before the machine
  # is destroyed or handed on: a machine that stops hard after this point has
  # already left the result with the hub. No-op on the hub; fail-open (the final
  # write-back retries).
  command -v pp_checkpoint >/dev/null 2>&1 && pp_checkpoint "$P" "reap ${KEY:-?}"
  if [ "$REUSED" = 0 ]; then
    # `command -v` because tests/pool-account-routing-test.sh and
    # tests/hotfix-cap-exempt-test.sh source THIS FUNCTION ALONE, with nothing
    # else from the file: a hard dependency on a helper defined 200 lines up is
    # the same trap the hotfix fallback above exists for.
    if command -v destroy_machine >/dev/null 2>&1; then destroy_machine "$MID" "reaped after $KEY"; else timeout 60 "$FLY" machine destroy "$MID" -a "$APP" --force >/dev/null 2>&1; fi
    # The file goes whatever the destroy answered: a reaped RESULT must still
    # close its row and free its account. The machine is not lost — the sweep
    # re-lists the app every tick and destroys it once it stops.
    rm -f "$MF" "$POOL/.$MID.snapmt" "$POOL/.$MID.puterr"
    # >>> machines rows (BH-1035)
    # Close the registry row using the actual destroy outcome. `command -v` for
    # the same reason the destroy above has it: the two suites that source THIS
    # FUNCTION ALONE define none of the helpers, and an unguarded call there is
    # a `command not found` on stderr of a path that is meant to be silent.
    command -v machines_row_close >/dev/null 2>&1 && machines_row_close "$MID"
    # <<< machines rows
    # The machine is gone, so its account is free — released HERE rather than left
    # to the TTL, because an account that still looks busy is an account the next
    # launch ranks worse than it is. A reused machine keeps its lease: it is still
    # building, just something else.
    command -v pool_account_release >/dev/null 2>&1 && pool_account_release "$MID"
  fi
  # THE STAMP IS THE LAST STEP (BH-7429). A record stamped reaped is a record the
  # next tick cannot read; stamped earlier, a tick that died before the end left a
  # finished build with no record and a stopped machine ssh cannot reach, and the
  # BH-2643 row path requeued it.
  if [ "${RECSTAMP:-0}" = 1 ]; then
    RECSTAMP=0
    pool_record_reaped "$P" "$KEY" "$MID" "${RECINFO%%$'\t'*}" \
      || say "build record for $KEY not stamped reaped — the unread retention rule deletes it"
  fi
}

