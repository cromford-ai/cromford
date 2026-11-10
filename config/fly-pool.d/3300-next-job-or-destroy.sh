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
  # ...and never reuse a machine at or past its soft cap (BH-9065). The cap is
  # the machine's own uptime, so its next build would cap on its first agent
  # call, do no work and spend one of that key's POOL_SPAWN_CAP_PER_KEY spawns.
  # A CAPPED RESULT says so outright; otherwise the age is now minus booted_at
  # (MBOOT, read by the reap loop; the first spawned_at of this machine).
  # POOL_MACHINE_SOFT_CAP_S is the knob (fallback 7200, 0 = off), as in
  # pool_job_stamp below.
  if [ "$REUSE_OK" = 1 ]; then
    NCAP="${POOL_MACHINE_SOFT_CAP_S:-7200}"; [[ "$NCAP" =~ ^[0-9]+$ ]] || NCAP=7200
    NCAPPED=0
    if [ -n "${LOCAL:-}" ] && [ -r "${LOCAL:-}/RESULT" ]; then
      case "$(head -1 "$LOCAL/RESULT" 2>/dev/null)" in CAPPED*) NCAPPED=1 ;; esac
    fi
    if [ "$NCAPPED" = 0 ] && [ "$NCAP" -gt 0 ] && [ -n "${MBOOT:-}" ]; then
      NBOOT=$(date -u -d "$MBOOT" +%s 2>/dev/null) || NBOOT=""
      if [ -n "$NBOOT" ] && [ $(( $(date -u +%s) - NBOOT )) -ge "$NCAP" ]; then NCAPPED=1; fi
    fi
    if [ "$NCAPPED" = 1 ]; then
      REUSE_OK=0
      say "$MID is at its soft cap (${NCAP}s) — destroying instead of reusing (the next job takes a fresh machine)"
    fi
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
      # ...and never a job of the other machine class (BH-9065): a lead review
      # must not hold a performance-8x, and a build must not land on a
      # shared-cpu machine. The reap loop read the class (MVCLASS) before it
      # removed $MF; a suite that sources this function alone has only $MF. A
      # machine json with no vm_class (`none`) was spawned before the classes:
      # it keeps the reuse rule it was spawned under and takes any job, so the
      # deploy does not destroy the machines already running. Every machine
      # spawn_one launches from now on carries a class.
      if command -v pool_vm_class_for >/dev/null 2>&1; then
        NVKIND=$(pool_vm_job_kind "$NKEY" "$NJ")
        NMCLASS="${MVCLASS:-}"
        [ -n "$NMCLASS" ] || NMCLASS=$(jq -r '.vm_class // "none"' "$MF" 2>/dev/null)
        [ -n "$NMCLASS" ] || NMCLASS=none
        [ "$NMCLASS" = none ] || [ "$(pool_vm_class_for "$NVKIND")" = "$NMCLASS" ] || continue
      fi
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
      # A CLEAN BUILD ROOT FOR THE NEXT JOB (BH-8896): every build dir that is
      # not the next key's moves to /data/harness/builds.prev/ (one generation,
      # emptied first). FXR-1465 was reused on a machine that held TK-3496's
      # dir, and its record took that dir as the newest one. The next key's own
      # dir stays, so a same-key retry still resumes. The prefix is quoted into
      # the machine's shell, so a key or project that is not [A-Za-z0-9._-]+
      # is never handed the machine. `BUILDSASIDE failed` destroys it; no
      # BUILDSASIDE line (a stub) reuses as before.
      if ! grep -qE '^[A-Za-z0-9._-]+$' <<<"$P" || ! grep -qE '^[A-Za-z0-9._-]+$' <<<"$NKEY"; then
        say "$NKEY: the key is not [A-Za-z0-9._-]+ — not handing it to $MID"
        [ "${ROWS_ONLY:-0}" = 1 ] && command -v queue_release >/dev/null 2>&1 \
          && { queue_release "$P" "$NKEY" "the key cannot be quoted for machine $MID" >/dev/null 2>&1 || true; }
        [ -n "${NHANDOFFTS:-}" ] && command -v pool_spawn_cap_unrecord >/dev/null 2>&1 \
          && pool_spawn_cap_unrecord "$NKEY" "$NHANDOFFTS"
        break
      fi
      # shellcheck disable=SC2016  # expanded by the machine's shell, not here
      BUILDSASIDE='b=/data/harness/builds; pv=/data/harness/builds.prev; n=0; f=0; rm -rf "$pv" && mkdir -p "$pv" || f=1; if [ "$f" = 0 ]; then for d in "$b"/*; do [ -e "$d" ] || continue; case "${d##*/}" in "$keep"*) continue ;; esac; if mv "$d" "$pv"/; then n=$((n+1)); else f=1; break; fi; done; fi; if [ "$f" = 0 ]; then echo "BUILDSASIDE ok moved=$n"; else echo "BUILDSASIDE failed"; fi; '
      SLOTANS=""
      if ! SLOTANS=$(mexec "$MID" "keep='$P-$NKEY-'; ${BUILDSASIDE}rm -f /run/harness/RESULT; rm -rf /run/harness/preplan; rm -f /run/harness/test-reroute-*; pkill -f '[p]laywright' 2>/dev/null; pkill -f '[c]hromium' 2>/dev/null; if [ -x /data/harness/bin/pool-slot-clean.sh ]; then /data/harness/bin/pool-slot-clean.sh 2>/dev/null; else echo 'SLOTCLEAN absent'; fi; true"); then
        [ "${ROWS_ONLY:-0}" = 1 ] && command -v queue_release >/dev/null 2>&1 \
          && { queue_release "$P" "$NKEY" "machine $MID could not be cleaned for the handoff" >/dev/null 2>&1 || true; }
        break
      fi
      ASIDEANS=$(grep -m1 '^BUILDSASIDE ' <<<"$SLOTANS" | tr -d '\r')
      case "$ASIDEANS" in
        "BUILDSASIDE failed"*)
          say "$MID: the previous job's build dirs could not be moved aside — destroying instead of reusing"
          [ "${ROWS_ONLY:-0}" = 1 ] && command -v queue_release >/dev/null 2>&1 \
            && { queue_release "$P" "$NKEY" "machine $MID could not move the previous build dirs aside" >/dev/null 2>&1 || true; }
          [ -n "${NHANDOFFTS:-}" ] && command -v pool_spawn_cap_unrecord >/dev/null 2>&1 \
            && pool_spawn_cap_unrecord "$NKEY" "$NHANDOFFTS"
          break ;;
        "BUILDSASIDE ok moved=0") ;;
        "BUILDSASIDE ok moved="*)
          say "$MID: moved ${ASIDEANS#BUILDSASIDE ok moved=} build dir(s) of earlier jobs to builds.prev before the handoff to $NKEY" ;;
      esac
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
      # Guarded like pool_vm_class_for above: with no stamp helper the plain job
      # file is pushed, never an empty path that turns a reuse into a destroy.
      NJPUSH="$NJ"
      command -v pool_job_stamp_path >/dev/null 2>&1 && NJPUSH=$(pool_job_stamp_path "$NJ" "${NVKIND:-build}")
      if mput "$MID" "$NJPUSH" /run/harness/job.json.next \
         && mexec "$MID" "mv /run/harness/job.json.next /run/harness/job.json" >/dev/null; then
        [ "$NJPUSH" = "$NJ" ] || pool_job_stamp_done "$NJ" "$NJPUSH"
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
        # BH-9065: the guest rides with the MACHINE too (MVGUEST, read by the
        # reap loop before it removed $MF). Unreadable gives {}: compute.
        NVG="${MVGUEST:-}"
        [ -n "$NVG" ] || NVG=$(jq -c '{vm_class,vm_size,vm_mem} | with_entries(select(.value != null))' "$MF" 2>/dev/null) || NVG=""
        [ -n "$NVG" ] || NVG='{}'
        jq -nc --arg m "$MID" --arg k "$NKEY" --arg t "$NTICKET" --argjson a "$NATT" --argjson d "$NDEF" --argjson x "$NDTH" --arg ts "$(STAMP)" --arg prev "$KEY" --arg sb "$NSB" --arg hf "$NHF" --arg ge "${GHEXP:-}" --arg gr "${GHROT:-}" --arg aa "${MACCT:-}" --arg sct "${NHANDOFFTS:-}" \
          --argjson vg "$NVG" --arg bt "${MBOOT:-}" \
          '{machine:$m,key:$k,ticket_id:$t,attempt:$a,deferrals:$d,deaths:$x,spawned_at:$ts,reused_from:$prev} + $vg
           + (if $sb == "" then {} else {stack_base:$sb} end)
           + (if $hf == "true" then {hotfix:true} else {} end)
           + (if $ge == "" then {} else {gh_token_expires_at:$ge} end)
           + (if $gr == "" then {} else {gh_token_rotated_at:$gr} end)
           + (if $aa == "" then {} else {auth_account:$aa} end)
           + (if $sct == "" then {} else {spawn_cap_ts:$sct} end)
           + (if $bt == "" then {} else {booted_at:$bt} end)' > "$MF"
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
        # >>> lifecycle phase: reused (BH-8733)
        command -v pool_phase_set >/dev/null 2>&1 && { pool_phase_set "$P" "$NKEY" building "machine $MID reused" || true; }
        # <<< lifecycle phase: reused
        "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$P" --arg k "$NKEY" '{kind:"build",project:$p,ticket_key:$k,stage:"pool_reused"}')" >/dev/null 2>&1 || true
        REUSED=1
      else
        [ "$NJPUSH" = "$NJ" ] || pool_job_stamp_done "$NJ" "$NJPUSH"
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
    rm -f "$MF" "$POOL/.$MID.snapmt" "$POOL/.$MID.sgprimemt" "$POOL/.$MID.puterr"
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


# >>> pool stage hand-off and soft cap (BH-9065)
# The hub half of bin/lib/pool-stage.sh. A build key is one of three job kinds
# to the pool: `build` (the whole pipeline on one machine, as before),
# `plan` (only when row lane.fly-pool.<p>.vm_class maps plan=model: the
# machine plans, publishes the plan and answers PLANNED) and `execute` (the
# re-offer after a PLANNED: a compute machine that adopts the published plan).
# pool_vm_job_kind (bin/lib/pool-vm-size.sh) decides it; spawn_one and the
# reuse hand-off both stamp the job file with pool_job_stamp before the push.
#
# pool_job_stamp <job-file> <kind>: adds `stage:"plan"` for a plan job, and
# `soft_cap_s` (POOL_MACHINE_SOFT_CAP_S, row
# lane.fly-pool.<p>.pool_machine_soft_cap_s, fallback 7200 s, 0 = off) for every
# build kind. A machine whose job carries no soft_cap_s is never capped, so a
# machine spawned before this knob existed runs as it always did.
# THE QUEUE FILE IS NEVER REWRITTEN: the stamp goes on a private copy (mktemp
# under ${TMPDIR:-/tmp}), and the function prints the path to push: the copy, or
# the job file itself when there is nothing to stamp or the stamp failed. rc 0
# always. The caller removes the copy after the push (pool_job_stamp_done).
pool_job_stamp() {
  local jf="${1:-}" kind="${2:-build}" cap stamped
  [ -s "$jf" ] || { printf '%s\n' "$jf"; return 0; }
  case "$kind" in build|plan|execute) ;; *) printf '%s\n' "$jf"; return 0 ;; esac
  # 7200 is the documented fallback of the POOL_MACHINE_SOFT_CAP_S knob
  # (catalog/lanes.d/fly-pool.knobs.d/POOL_MACHINE_SOFT_CAP_S.json).
  cap="${POOL_MACHINE_SOFT_CAP_S:-7200}"; [[ "$cap" =~ ^[0-9]+$ ]] || cap=7200
  # Nothing to add or drop: the job file is pushed as it is.
  if [ "$kind" = build ] && [ "$cap" = 0 ] && [ "$(jq -r 'has("stage") or has("soft_cap_s")' "$jf" 2>/dev/null)" = false ]; then
    printf '%s\n' "$jf"; return 0
  fi
  stamped=$(mktemp "${TMPDIR:-/tmp}/pool-job-stamp.XXXXXX" 2>/dev/null) || { printf '%s\n' "$jf"; return 0; }
  if jq -c --arg k "$kind" --argjson c "$cap" \
       '(if $k == "plan" then .stage = "plan" elif $k == "execute" then .stage = "execute" else del(.stage) end)
        | (if $c > 0 then .soft_cap_s = $c else del(.soft_cap_s) end)' "$jf" > "$stamped" 2>/dev/null && [ -s "$stamped" ]; then
    printf '%s\n' "$stamped"
  else
    rm -f "$stamped"; printf '%s\n' "$jf"
  fi
  return 0
}

# pool_job_stamp_path <job-file> <kind>: the path to push, one line; the job
# file itself when pool_job_stamp is absent or prints nothing.
pool_job_stamp_path() {
  local out=""
  command -v pool_job_stamp >/dev/null 2>&1 && out=$(pool_job_stamp "$1" "$2")
  printf '%s\n' "${out:-$1}"
}

# pool_job_stamp_done <job-file> <pushed-path>: removes the stamped copy, never
# the job file.
pool_job_stamp_done() {
  [ -n "${2:-}" ] && [ "$2" != "${1:-}" ] || return 0
  case "$2" in "${TMPDIR:-/tmp}"/pool-job-stamp.*) rm -f -- "$2" ;; esac
  return 0
}

# pool_stage_reoffer: the reap's arm for PLANNED / CAPPED on a build key. Reads
# the reap loop's own variables. rc 0 = handled (the caller hands the machine
# on and continues), rc 1 = not this arm's RESULT.
#
# Neither answer is a verdict, so no counter moves: `attempt`, `deferrals` and
# `deaths` are carried as they were, and the CI-repair, EXECUTE_EMPTY and
# abandon counters are never read or written here. PLANNED takes back the plan
# machine's per-key spawn-cap entry, so a hand-off pair counts once. CAPPED
# keeps it: a build that is capped again and again is still bounded by
# POOL_SPAWN_CAP_PER_KEY. The row's reason names the cap, never GATE_RED or
# EXECUTE_EMPTY.
pool_stage_reoffer() {
  local word stage="" brief="" meta why
  case "$RLINE" in
    "PLANNED stage=plan"*) word=PLANNED; stage=execute ;;
    # A cap after the plan re-offers as execute: pool-stage.sh published the
    # plan, so the next machine adopts it. A cap during the plan re-plans.
    "CAPPED stage=plan "*) word=CAPPED ;;
    "CAPPED stage="*)      word=CAPPED; stage=execute ;;
    *) return 1 ;;
  esac
  case "$KEY" in RB-*|RR-*|LR-*|CP-*|FXR-*) return 1 ;; esac
  # The dir owes the board no close-out: the next machine's build does.
  : > "$LOCAL/DEFERRED"; : > "$LOCAL/COMMENTED"
  if [ "$word" = CAPPED ]; then
    # The brief the capped machine wrote: brief.md is in POOL_RECORD_FILES
    # (bin/lib/pool-record.sh), so the record path and the ssh arm both bring
    # it into $LOCAL. It rides the row meta (4000 chars in the worker), so it
    # is cut to POOL_CAP_BRIEF_BYTES (row lane.fly-pool.<p>.pool_cap_brief_bytes;
    # 1500 is that knob's documented fallback). No brief: re-offered without one.
    local bb="${POOL_CAP_BRIEF_BYTES:-1500}"; [[ "$bb" =~ ^[0-9]+$ ]] || bb=1500
    brief=$(head -c "$bb" "$LOCAL/brief.md" 2>/dev/null)
    why="cap: $(head -1 "$LOCAL/RESULT" | head -c 100)"
  else
    command -v pool_spawn_cap_unrecord >/dev/null 2>&1 && pool_spawn_cap_unrecord "$KEY" "${SPAWNCAPTS:-}"
    why="stage hand-off: plan done on $MID, re-offered as execute"
  fi
  meta=$(jq -nc --argjson d "${DEFC:-0}" --argjson x "${DTHS:-0}" --arg sb "${SBASE:-}" --arg hf "${MHF:-false}" \
           --arg st "$stage" --arg br "$brief" --arg w "$word" --arg fs "$([ "$word" = CAPPED ] && echo true)" \
    '{deferrals:$d,deaths:$x,reoffer:$w}
     + (if $sb == "" then {} else {stack_base:$sb} end)
     + (if $hf == "true" then {hotfix:true} else {} end)
     + (if $st == "" then {} else {stage:$st} end)
     + (if $br == "" then {} else {cap_brief:$br} end)
     + (if $fs == "true" then {fresh_spawn:true} else {} end)')
  if QROW requeue "$KEY" "$why" "$ATT" "$meta" "$TICKET"; then
    # The queue file comes from the same row -> job.json mapping the rows-only
    # materialise uses (bin/lib/queue-row-job.sh knows `stage` and `cap_brief`),
    # so the re-offer writes no second copy of that format. Flag-off ticks do
    # not source the lib at the head, so it is sourced here.
    command -v queue_row_job_file >/dev/null 2>&1 \
      || . "$HARNESS/bin/lib/queue-row-job.sh" 2>/dev/null \
      || . "$(dirname "${BASH_SOURCE[0]}")/lib/queue-row-job.sh" 2>/dev/null || true
    if ! command -v queue_row_job_file >/dev/null 2>&1; then
      say "$word $KEY: bin/lib/queue-row-job.sh is missing — the row is requeued, the queue file is not written"
    elif ! QRJ_TAG="pool/$P" queue_row_job_file "$P" "$QDIR/$KEY.json" "$KEY" "$TICKET" "${ATT:-0}" "$meta" >/dev/null; then
      say "$word $KEY: the queue file was not written (queue_row_job_file failed) — the row is requeued"
    fi
    say "$word $KEY on $MID: $why — requeued, attempt $ATT, deferrals ${DEFC:-0} and deaths ${DTHS:-0} unchanged"
    "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$P" --arg k "$KEY" --arg r "$(head -c 120 "$LOCAL/RESULT")" --arg s "pool_$(printf '%s' "$word" | tr '[:upper:]' '[:lower:]')" '{kind:"build",project:$p,ticket_key:$k,stage:$s,detail:$r}')" >/dev/null 2>&1 || true
  else
    say "$word $KEY on $MID: abandoned by an operator, not requeued"
  fi
  return 0
}
# <<< pool stage hand-off and soft cap
