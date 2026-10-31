spawn_one() { # spawn_one <job-file> <key> <ticket-id> <attempt> <deferrals> <deaths> [stack-base]
  local JF="$1" KEY="$2" TICKET="$3" ATT="$4" SDEF="$5" SDTH="$6" SSB="${7:-}"
  # BH-7505: a spawn spends a machine, so it runs only under a lease this run
  # still holds (a lane-run machine's, or a hub tick's that a Fly run could
  # contest). Before the queue claim: nothing is claimed, so nothing to hand back.
  if command -v pp_fence_ok >/dev/null 2>&1 && ! pp_fence_ok; then
    say "$KEY: the project lease is lost — no machine spawned, the job stays queued"
    return 1
  fi
  # Every spawn that reaches a machine counts against the per-key cap (BH-1075)
  # — except a REBASE row, which pool_spawn_decision exempts from the cap
  # entirely (its key carries the head it is rebasing, so a repeat is a new key;
  # bin/merge-conductor.sh owns that lane's timeout). A ledger nothing ever
  # reads would be one file per rebase left in state/pool.
  #
  # INFRASTRUCTURE FAILURES NEVER COUNT (BH-4859). The cap exists to bound a
  # loop of BUILDS. An env bundle that fails records nothing (it runs before the
  # record), and every exit below where no build ever reached the machine (no
  # machine id, harness sync failed, env/job push failed) takes its entry back
  # out with pool_spawn_cap_unrecord. Before this, every bundle failure bought a
  # machine and spent a cap slot, so a flaky bundler could cap a key that never
  # built once. SPAWNCAPTS also rides onto the machine json as
  # spawn_cap_ts (BH-1279), so a reap that learns the claim was REFUSED by a
  # concurrency rule removes exactly this entry too.
  # THE CLAIM COMES BEFORE THE MACHINE (BH-1026.3). With the rows as the queue,
  # the compare-and-swap on the row IS the dedupe for this spend, so it has to
  # happen before `fly machine run` — a claim taken after the spawn would have
  # already bought the machine it is deciding about, and a 409 would then have to
  # destroy one. rc 9 (someone else has it), rc 2 (no `queued` row for this key
  # any more) and rc 1 (an outage after a successful list) are all the same
  # answer to this function: one line, no machine. It also sits above
  # pool_spawn_cap_record deliberately — a spawn that never happened must not
  # spend a slot of the per-key cap (BH-1279's lesson, without needing the
  # un-record).
  local CRC=0
  if [ "${ROWS_ONLY:-0}" = 1 ] && command -v queue_claim >/dev/null 2>&1; then
    queue_claim "$P" fly "$KEY" >/dev/null 2>&1 || CRC=$?
    if [ "$CRC" != 0 ]; then
      say "$KEY: the queue row refused this claim (rc $CRC) — no machine spawned, re-offered next tick"
      return 1
    fi
  fi
  # BUNDLE BEFORE SPAWN (BH-4859). The bundle takes only $P and an outdir and
  # never reads $MID, so nothing it needs comes from the machine. Running it
  # first makes "can this spawn be used at all?" the check before paying for a
  # machine: a failure here buys nothing, records nothing, and hands the row
  # back with the bundler's own reason. The dir holds secrets, so every exit
  # from here to the push below removes it.
  local TMP EB_ERR="" EB_RC=0 EB_WHY
  TMP=$(mktemp -d /dev/shm/pool.XXXX); chmod 700 "$TMP"
  # PULL OR PUSH (BH-7430), decided before the bundle: a push answer runs the
  # bundler below exactly as before. See the `machine pull` block above.
  local PULL=0 PULL_TAG="" PULL_NOTE="" PULL_ARGS=() PULL_SECRET=""
  if [ "${POOL_PULL_ON:-0}" = 1 ] && pool_pull_decide "$KEY" "$JF" "$TMP"; then PULL=1; PULL_TAG="pull, "; fi
  # --pool (BH-4798): a box with no PAT is a WARN here, not a dead spawn, because
  # the token block below swaps the line for an App token. Its stderr is captured
  # ($LOG is the capture fd inside the substitution) so a failure can be named;
  # on success it (a WARN, paths and slugs only) goes to the pool log next to our
  # own line, and on failure only the filtered reason does.
  if [ "$PULL" = 1 ]; then
    pool_pull_skeleton "$TMP"
  else
  EB_ERR=$(exec 3>&1; LOG=/dev/fd/3
           "$HARNESS/bin/fly-envbundle.sh" "$P" "$TMP" --pool >/dev/null 2>>"$LOG") || EB_RC=$?
  fi
  if [ "$EB_RC" = 0 ]; then
    [ -z "$EB_ERR" ] || printf '%s\n' "$EB_ERR" >> "$LOG"
  else
    EB_WHY=$(pool_bundle_reason "$EB_RC" "$EB_ERR")
    rm -rf "$TMP"
    say "env bundle FAILED for $KEY: $EB_WHY — no machine spawned, job stays queued"
    command -v ptn_note >/dev/null 2>&1 && ptn_note "$P" "$EB_WHY"
    pool_unclaim "$KEY" "env bundle failed: $EB_WHY"; return 1
  fi
  local SPAWNCAPTS=""
  case "$KEY" in RB-*|RR-*|LR-*|CP-*|FXR-*-*) ;; *) SPAWNCAPTS=$(pool_spawn_cap_record "$KEY") ;; esac
  # A CONSOLE PREVIEW ROW CARRIES THE PAGES TOKEN (BH-8030). Its machine
  # uploads the preview, so the hub's cloudflare.env (the token and account
  # lines only) goes to /run/harness-env/cloudflare.env, mode 0600, on the push
  # path only (pool_pull_decide sends a CP- row there: a pull seed can end up in
  # the machine config). No token on the hub: the row is FAILED before any
  # machine is bought, and the console preview lane reads that as the box's.
  if [[ "$KEY" == CP-* ]]; then
    grep -E '^(export[[:space:]]+)?CLOUDFLARE_(API_TOKEN|ACCOUNT_ID)=' "$HENV/cloudflare.env" 2>/dev/null > "$TMP/cloudflare.env"
    if ! grep -qE '^(export[[:space:]]+)?CLOUDFLARE_API_TOKEN=.' "$TMP/cloudflare.env"; then
      rm -rf "$TMP"; rm -f "$JF"
      QROW failed "$KEY" "console preview: no CLOUDFLARE_API_TOKEN in the hub env/cloudflare.env; no machine spawned"
      say "$KEY: no Cloudflare token on the hub — console preview row FAILED, no machine spawned"
      return 1
    fi
  fi
  local MID TB SYNC_OK OK SNAP_SRC SNAP_MT MEXP="" MINST="" MAPP=hub SHF=false
  # `hotfix` is read off the JOB FILE rather than passed as an argument: the
  # spawn call's argument list is pinned by tests/no-serialize-test.sh (it is the
  # proof that spawns still run in the background), and a flag the file already
  # carries needs no eighth positional to travel.
  # READ IT HERE, at the top: the dispatch `mv` further down DELETES the job
  # file, so asking the question beside the jq that uses it answered false for
  # every hotfix the pool ever spawned — and the machine json is where the reap
  # reads the flag back to put it on the deferral and death requeues.
  job_is_hot "$JF" && SHF=true
  # SETUP BEFORE LAUNCH (BH-7215). A new machine waits WARMUP_WAIT_S for its
  # job and then exits. The steps below (spec repos, App token mint, account
  # lease, OpenRouter check, label overlay, harness tarball) need no machine, so
  # they run BEFORE `fly machine run`: on project-6-os they took about 12
  # minutes, and the machine had exited when the first push came (#7174). Only
  # the steps that need the machine (row stamp, lease rebind, tarball copy,
  # pushes) run after the launch. Every exit before the launch removes $TMP.
  local SETUP_T LEASE_ID=""; SETUP_T=$(date +%s)
  # SPEC REPOS (BH-6576): the repos this ticket's body names on a `Spec-repo:`
  # line. The swap block below adds them to the read-only token; the machine
  # json records them, so next_job_or_destroy never hands this machine on.
  SPEC_REPOS=""
  command -v spec_repos_load >/dev/null 2>&1 \
    && SPEC_REPOS_GH_TOKEN="${POOL_SLUG_TOK:-}" spec_repos_load "$POOL_SLUG" "$TICKET" 2>>"$LOG"
  [ -n "$SPEC_REPOS" ] && say "$KEY declares spec repos $SPEC_REPOS (read-only)"
  # PER-MACHINE GITHUB CREDENTIAL (2026-09-14). fly-envbundle.sh puts the owning
  # box's PAT in the bundle as GH_TOKEN, which is how a builder pushes and opens
  # its PR. That PAT is the fleet's whole GitHub identity, it never expires, and
  # every pool machine that ever booted got a copy of it — with 4000 builders that
  # is 4000 live copies of one credential sharing one 5000/h rate bucket. So the
  # machine gets its OWN token instead: scoped to this project's repo, dead in an
  # hour, and useless to anyone who finds it on a destroyed machine's rootfs.
  # The PAT line is REPLACED rather than appended to, because a second GH_TOKEN=
  # later in the file is what the builder's `set -a; . global.env` would actually
  # use — an append would silently keep the PAT.
  # Unarmed (no env/github-app.env, GH_APP_TOKENS=0, flags/gh-app-tokens-off) this
  # whole block is skipped and the bundle ships exactly the bytes it ships today.
  #
  # AND IT MUST OUTLIVE THE BUILD (2026-09-14, TK-680/681/682). The cache hands a
  # token out until 5 minutes before it dies, which is right for a lane that spends
  # it in seconds and wrong for a 40-75 minute build: three of them were spawned on
  # a 47-minute-old token and their pre-PR push was rejected an hour after the mint.
  # --min-life is the ask — a cached token with less than POOL_GH_TOKEN_MIN_LIFE
  # left is re-minted rather than shipped.
  #
  # The same token is ALSO written to /run/harness-env/gh-token, which is the file
  # rotate_gh_token replaces under a live build and fly/gh-credential.sh and
  # bin/lib/gh-token-live.sh read at call time. The GH_TOKEN= line in global.env is
  # unchanged and still the fallback, so everything that never learns about the file
  # keeps working exactly as it does today.
  #
  # NO CREDENTIAL, NO MACHINE (BH-4798). A --pool bundle may arrive with no PAT
  # (fly-envbundle.sh lets it through only when armed, i.e. only into this block).
  # If the mint then answers nothing too, the builder would have no GitHub
  # credential and fail at push 40+ minutes later, so the spawn is refused now.
  # BEFORE THE LAUNCH (BH-7215): this block runs before `fly machine run`, so
  # it names the KEY (there is no machine id yet), it pushes nothing, and its
  # refusals buy no machine. The read-only token file it writes is pushed in
  # the push phase below.
  # >>> pool gh credential swap
  if command -v gh_auth_armed >/dev/null 2>&1 && gh_auth_armed && [ -x "$HARNESS/bin/gh-token.sh" ]; then
    PSLUG=$(sed -n 's/^REPO_SLUG=//p' "$TMP/$P.env" 2>/dev/null | head -n 1)
    # gh-token.sh's stderr is kept for ONE line: `hub-retry`, which says the
    # profile could not mint and the hub App answered (#1590 review B2).
    # pool_gh_answered logs it and names the App that actually answered.
    MTOK=""; MAPP=hub
    if [ -n "$PSLUG" ]; then
      MTOK=$(pool_gh_token --min-life "$POOL_GH_TOKEN_MIN_LIFE" "$PSLUG" 2>"$TMP/ghtok.err") || MTOK=""
      MAPP=$(pool_gh_answered "$TMP/ghtok.err"); rm -f "$TMP/ghtok.err"
    fi
    if [ -n "$MTOK" ]; then
      # THE BUCKET TRAVELS WITH THE TOKEN (BH-1578). A builder has no token cache
      # to look its installation up in, so the #1484 ledger there would file every
      # call under the flat `app`; GH_TOKEN_INSTALLATION_ID names the bucket this
      # token spends. A cache miss ships no line, never a guessed one. The same
      # --min-life as the mint, so a stale profile row can never answer for a
      # token the hub App minted.
      MINST=$(pool_gh_token --min-life "$POOL_GH_TOKEN_MIN_LIFE" --installation-id "$PSLUG" 2>/dev/null) || MINST=""
      case "$MINST" in *[!0-9]*) MINST="" ;; esac
      ( umask 077
        grep -v '^GH_TOKEN=' "$TMP/global.env" 2>/dev/null | grep -v '^GH_TOKEN_INSTALLATION_ID=' > "$TMP/global.env.new"
        printf 'GH_TOKEN=%s\n' "$MTOK" >> "$TMP/global.env.new"
        [ -n "$MINST" ] && printf 'GH_TOKEN_INSTALLATION_ID=%s\n' "$MINST" >> "$TMP/global.env.new"
        printf '%s\n' "$MTOK" > "$TMP/gh-token" )
      if [ -s "$TMP/global.env.new" ]; then
        mv "$TMP/global.env.new" "$TMP/global.env"
        # Recorded on the machine json below so the tick can decide about rotation
        # from a local file rather than a second API call. Empty when the answer was
        # the PAT, and an empty expiry is what tells rotate_gh_token to stay out.
        MEXP=$(pool_gh_token --min-life "$POOL_GH_TOKEN_MIN_LIFE" --expires-at "$PSLUG" 2>/dev/null) || MEXP=""
        say "$KEY gets a repo-scoped App token for $PSLUG from the $MAPP App (expires ${MEXP:-?}) instead of the fleet PAT"
        # EXTRA READ REPOS (BH-5910). The token above sees one repo. When
        # lane.fly-pool.<project>.extra_read_repos names more, a SECOND token reads
        # them (contents+metadata read); fly/gh-credential.sh answers it for those
        # repos only. No token: the machine still ships, and the plan stage stops
        # a build that needs the repo (PLAN_BLOCKED cross-repo-read).
        # SPEC REPOS (BH-6576): the ticket's own `Spec-repo:` repos join the
        # knob's list, the project slug and the knob's own repos dropped. Empty
        # for every other ticket, so the list and the mint are the knob's alone.
        XREAD_SPEC=""
        [ -n "${SPEC_REPOS:-}" ] && command -v spec_repos_extra >/dev/null 2>&1 \
          && XREAD_SPEC=$(spec_repos_extra "${EXTRA_READ_REPOS:-}" "$SPEC_REPOS" "$PSLUG")
        XREAD_SRC="${EXTRA_READ_REPOS:-}"
        [ -n "$XREAD_SPEC" ] && XREAD_SRC="${XREAD_SRC:+$XREAD_SRC,}$XREAD_SPEC"
        if [ -n "$MEXP" ] && [ -n "$XREAD_SRC" ]; then
          XTOK=$(pool_gh_token --extra-read "$XREAD_SRC" --min-life "$POOL_GH_TOKEN_MIN_LIFE" "$PSLUG" 2>"$TMP/xread.err") || XTOK=""
          XMISS=""
          while IFS= read -r XLINE; do
            XREPO=$(printf '%s' "$XLINE" | sed -n 's/.*EXTRA_READ_REPO_MISSING \([^ ]*\).*/\1/p')
            [ -n "$XREPO" ] || continue
            XMISS="$XMISS $XREPO"
            say "$KEY: ${XLINE#gh-token: } — not readable on this machine"
            # ALERTS first, then the flag; one per project per repo per UTC day (D21).
            find "$HARNESS/flags" -maxdepth 1 -name 'alerted-extra-read-missing-*' -mmin +2880 -delete 2>/dev/null
            XFLAG="$HARNESS/flags/alerted-extra-read-missing-$P-$(printf '%s' "$XREPO" | tr -c 'A-Za-z0-9._-' '-')-$(date -u +%Y%m%d)"
            if [ ! -f "$XFLAG" ]; then
              # A repo the knob does not name came from the ticket's Spec-repo line.
              if [[ ",${XREAD_SPEC,,}," == *",${XREPO,,},"* ]]; then
                HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] EXTRA_READ_REPO_MISSING $XREPO — ticket $KEY declares it as Spec-repo, but the pool App cannot read it. Install the builders App on $XREPO (same owner as $PSLUG)."
              else
                HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] EXTRA_READ_REPO_MISSING $XREPO — lane.fly-pool.$P.extra_read_repos names it, but the pool App cannot read it, so pool/$P builds cannot read it. Install the builders App on $XREPO (same owner as $PSLUG), or remove it from the setting."
              fi
              touch "$XFLAG" 2>/dev/null
            fi
          done < "$TMP/xread.err"
          rm -f "$TMP/xread.err"
          # The list the builder sources (global.env is `. `-loaded as root) is
          # NEVER the raw row: only owner/repo words, the project and the missing
          # repos dropped, deduped, sorted and capped as gh-token.sh mints them,
          # joined by commas. A space-separated row or a `$(...)` word cannot
          # reach the builder's shell.
          XLIST=""; XSEEN=" "; XN=0
          IFS=$', \t\n' read -r -d '' -a XWORDS <<< "$XREAD_SRC" || true
          while IFS= read -r XW; do
            [[ "$XW" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || continue
            [ "${XW,,}" = "${PSLUG,,}" ] && continue
            case "$XSEEN" in *" ${XW,,} "*) continue ;; esac
            XSEEN="$XSEEN${XW,,} "; XN=$((XN + 1))
            [ "$XN" -le 10 ] || continue
            case " ${XMISS,,} " in *" ${XW,,} "*) continue ;; esac
            XLIST="${XLIST:+$XLIST,}$XW"
          done < <(printf '%s\n' ${XWORDS[@]+"${XWORDS[@]}"} | sort -f)
          [ -n "$XLIST" ] || XTOK=""
          if [ -n "$XTOK" ]; then
            ( umask 077
              grep -v '^GH_EXTRA_READ_TOKEN=' "$TMP/global.env" 2>/dev/null | grep -v '^GH_EXTRA_READ_REPOS=' > "$TMP/global.env.new"
              printf 'GH_EXTRA_READ_TOKEN=%s\nGH_EXTRA_READ_REPOS=%s\n' "$XTOK" "$XLIST" >> "$TMP/global.env.new"
              printf '%s\n' "$XTOK" > "$TMP/gh-token-read" )
            if [ -s "$TMP/global.env.new" ] && grep -q '^GH_TOKEN=' "$TMP/global.env.new"; then
              mv "$TMP/global.env.new" "$TMP/global.env"
              # The file stays in $TMP: the push phase after the launch sends
              # it (BH-7215), and `rm -rf "$TMP"` removes it on every exit.
              say "$KEY gets a read-only token for the extra repos of $PSLUG ($XLIST; left out:${XMISS:- none})"
            else
              rm -f "$TMP/global.env.new" "$TMP/gh-token-read"
              say "$KEY: read-only token bundle write failed — no extra repos on this machine"
            fi
          else
            grep -v '^GH_EXTRA_READ_TOKEN=' "$TMP/global.env" 2>/dev/null | grep -v '^GH_EXTRA_READ_REPOS=' > "$TMP/global.env.x" \
              && mv "$TMP/global.env.x" "$TMP/global.env" && chmod 600 "$TMP/global.env" 2>/dev/null
            say "$KEY: no read-only token for $XREAD_SRC — the machine ships with the $PSLUG token only"
          fi
          XTOK=""; XMISS=""; XLIST=""; XWORDS=()
        fi
        XREAD_SRC=""; XREAD_SPEC=""
      else
        rm -f "$TMP/global.env.new" "$TMP/gh-token"
        if ! grep -q '^GH_TOKEN=' "$TMP/global.env" 2>/dev/null; then
          say "$KEY: token swap produced an empty bundle and the bundle carries no PAT — no machine spawned, job stays queued"
          MTOK=""; rm -rf "$TMP"
          # This runs before the launch (BH-7215), so no machine exists to
          # destroy. Nothing was built, so it does not count against the cap
          # (BH-4859). ${SPAWNCAPTS:-}: this block is lifted by its markers into
          # tests/fly-envbundle-pool-nopat.bh-4798-test.sh under set -u, and an
          # empty ts is already a no-op in pool_spawn_cap_unrecord.
          pool_spawn_cap_unrecord "$KEY" "${SPAWNCAPTS:-}"
          pool_unclaim "$KEY" "no GitHub credential for $KEY"; return 1
        fi
        say "$KEY token swap produced an empty bundle — shipping the PAT"
      fi
    elif ! grep -q '^GH_TOKEN=' "$TMP/global.env" 2>/dev/null; then
      say "$KEY: no App token for ${PSLUG:-unknown repo} and the bundle carries no PAT — no machine spawned, job stays queued"
      rm -rf "$TMP"
      # Before the launch (BH-7215): no machine to destroy, no cap slot spent (BH-4859).
      pool_spawn_cap_unrecord "$KEY" "${SPAWNCAPTS:-}"
      pool_unclaim "$KEY" "no GitHub credential for $KEY"; return 1
    else
      say "$KEY: no App token for ${PSLUG:-unknown repo} — shipping the PAT"
    fi
    MTOK=""
  fi
  # <<< pool gh credential swap
  # >>> pool testhost route
  # THE TEST-HOST ROUTE (BH-8335). The selection gate runs the build's suites
  # on the Fly test host through bin/remote-gate.sh, which needs a Fly
  # credential the image does not carry. ptr_build mints one for THIS machine
  # into $TMP/testhost.env: a Fly SSH token scoped to the test-host app only,
  # for ptr_hours hours (never an org-wide `flyctl ssh issue` cert, lead BLOCK
  # #4386), and the push phase sends it with the other secrets. Knob
  # lane.fly-pool[.<project>].pool_testhost_route (1 = on, fleet default 0). It
  # never refuses a spawn: a failure is one line, and the gate records
  # could-not-run as before.
  # Before the launch (BH-7215). A pull spawn ships no route (its seed is the
  # machine config); the gate names that miss on the machine.
  if [ "$PULL" != 1 ] && command -v ptr_build >/dev/null 2>&1; then
    TRERR=$(ptr_build "$TMP" "$KEY" 2>&1 >/dev/null); TRRC=$?
    case "$TRRC" in
      0|3) ;;
      *) say "$KEY: ${TRERR:-testhost route: not shipped (rc $TRRC)} — the selection gate will record could-not-run" ;;
    esac
  fi
  # <<< pool testhost route
  # PER-MACHINE CLAUDE ACCOUNT (2026-09-14). Exactly the swap above, one
  # credential over: the bundle's CLAUDE_CODE_OAUTH_TOKEN is the owning box's
  # project-6 setup-token and every machine in the pool got the same one, so a
  # 20-machine burst was 20 heavy sessions on one account (fly/account-capacity.conf
  # says ~4) and every cost row those machines wrote was attributed to that one
  # account. bin/lib/pool-account.sh leases one of env/accounts.d's max accounts to
  # THIS machine, replaces the token line, and drops an fp->label overlay beside
  # the bundle so the machine's own cost rows carry the account name.
  #
  # It cannot refuse a launch: unarmed, saturated or broken, it answers `default`
  # and the bundle ships exactly the bytes it ships today.
  # BEFORE THE LAUNCH (BH-7215): there is no machine id yet, so the lease is
  # taken under a pre-launch id and pool_account_rebind moves it to the machine
  # id right after `fly machine run`. Every reap path then frees it by machine
  # id, as before.
  MACCT=""
  LEASE_ID="pre-$(printf '%s' "$KEY" | tr -c 'A-Za-z0-9._-' '-')-$(date +%s)-$BASHPID"
  LEASE_ID="${LEASE_ID:0:64}"
  if command -v pool_account_lease >/dev/null 2>&1; then
    PALINE=$(pool_account_lease "$P" "$KEY" "$TMP/global.env" "$LEASE_ID" 2>/dev/null)
    PANAME=""; PAREASON=""; PALEASES=""; PAFIVE=""
    for KV in $PALINE; do
      case "$KV" in
        name=*)   PANAME="${KV#name=}" ;;
        reason=*) PAREASON="${KV#reason=}" ;;
        leases=*) PALEASES="${KV#leases=}" ;;
        five_h=*) PAFIVE="${KV#five_h=}" ;;
      esac
    done
    if [ -n "$PANAME" ] && [ "$PANAME" != default ]; then
      MACCT="$PANAME"
      say "$KEY gets account $MACCT (5h ${PAFIVE:-?}%, leases ${PALEASES:-?}) instead of the default token"
      # NO OPENROUTER WHILE CLAUDE OAUTH WORKS (the operator, 2026-09-24). A machine
      # carries ONE leased token and no account routing, so when that account
      # runs out, agent-call's "exhausted-only" reading is true ON THE MACHINE —
      # its only account is gone — and it would descend to OpenRouter while the
      # hub holds healthy accounts. Every attributable OpenRouter dollar on
      # 09-21..23 (~$1.1K/day) came from pool machines this way. So when the hub
      # has another account that could serve, the machine is told
      # OPENROUTER_FALLBACK=off: the stage ends RUNNER_EXHAUSTED, the reap cools
      # this account (F2), requeues without charging the ticket (F3), and the
      # next machine leases a healthy one. Replaced, never appended: the bundle
      # already carries the hub's own OPENROUTER_* lines.
      if command -v pool_account_others_ok >/dev/null 2>&1 && pool_account_others_ok "$MACCT"; then
        { grep -v '^OPENROUTER_FALLBACK=' "$TMP/global.env" 2>/dev/null; printf 'OPENROUTER_FALLBACK=off\n'; } > "$TMP/global.env.or" \
          && mv "$TMP/global.env.or" "$TMP/global.env" && chmod 600 "$TMP/global.env" 2>/dev/null
        say "$KEY: another claude account can serve, so OpenRouter is off on this machine (OPENROUTER_FALLBACK=off)"
      fi
    else
      say "$KEY ships the default project-6 token (${PAREASON:-no answer})"
    fi
  fi
  # THE DEFAULT TOKEN STILL NEEDS A LABEL (2026-09-16). The lease path writes
  # TMP/auth-accounts.local.json for the leased account. The default path
  # (all_unreadable / saturated / unarmed) ships the hub's project-6 token
  # and, until now, no overlay — so every cost row landed auth_account=unknown,
  # cost-reconcile never fetched those pool rows (box=pool-* is not in
  # boxes.cost_rows; unknown is not in auth_accounts), and the 1h window then
  # substituted jobs.spent_usd. 00:50Z 1h: meter $19.35, labelled rows $11.45,
  # jobs $73.71, gap -340%. 24h: $2538 of pool claude on fp 52bec8da8a5d sat
  # unlabelled against a $4211 meter. The hub overlay already maps that fp to
  # claude:operator@example.com; copy it when the lease did not write one. A
  # missing hub overlay is the unarmed box and stays a no-op.
  if [ ! -s "$TMP/auth-accounts.local.json" ] && [ -s "$HARNESS/state/auth-accounts.local.json" ]; then
    cp "$HARNESS/state/auth-accounts.local.json" "$TMP/auth-accounts.local.json" 2>/dev/null || true
  fi
  # Volume-less pool machines never receive the dispatcher's harness sync, so
  # without this push /data/harness/bin/run-build.sh does not exist and the
  # runner dies No-such-file after a clean clone+install (TK-143, 2026-08-13).
  # Include catalog/ as in fly-sync-harness.sh: transcript pricing needs the
  # model price table on this fresh rootfs or every measured call costs $0.
  # Built here, before the launch (BH-7215): it is local work, and the machine
  # should not wait for it.
  # The pull path ships no tarball: the machine fetches the pinned sha.
  if [ "$PULL" = 1 ]; then
    TB=""
    if ! pool_pull_args "$TMP"; then
      say "seed staging FAILED for $KEY — no machine spawned, job stays queued"
      rm -rf "$TMP"
      command -v pool_account_release >/dev/null 2>&1 && pool_account_release "$LEASE_ID"
      pool_spawn_cap_unrecord "$KEY" "$SPAWNCAPTS"
      pool_unclaim "$KEY" "seed staging failed for $KEY"; return 1
    fi
  else
  TB=$(mktemp /tmp/poolsync-XXXX.tgz)
  # shellcheck source=bin/lib/harness-tarball.sh
  . "$HARNESS/bin/lib/harness-tarball.sh" \
    || say "bin/lib/harness-tarball.sh missing under $HARNESS — $KEY ships no harness tree"
  harness_tarball "$TB" /root/harness-checkout bin prompts rules catalog fleet.conf fly
  [ $? = 2 ] && say "no git HEAD in /root/harness-checkout — $KEY ships with no HARNESS_COMMIT stamp, so its box reports no harness commit"
  fi
  # BH-7215: the machine waits WARMUP_WAIT_S for its job (lane knob
  # lane.fly-pool.<project>.warmup_wait_s), then exits 0.
  local WW="${WARMUP_WAIT_S:-1800}"; case "$WW" in ''|*[!0-9]*|0) WW=1800 ;; esac
  say "$KEY: setup before launch took $(( $(date +%s) - SETUP_T ))s"
  # BH-7519: the fence at the top of this function is minutes old (the setup
  # above took about 12 on project-6-os). Ask again right before the spend. A
  # lost lease buys no machine and hands the claim back, as a launch with no
  # machine id does.
  if command -v pp_fence_ok >/dev/null 2>&1; then
    pp_fence_ok; local FRC=$?
    if [ "$FRC" = 99 ]; then
      say "$KEY: the project lease was lost during setup — no machine spawned, job stays queued"
      rm -rf "$TMP"; rm -f "$TB"
      command -v pool_account_release >/dev/null 2>&1 && pool_account_release "$LEASE_ID"
      pool_spawn_cap_unrecord "$KEY" "$SPAWNCAPTS"
      pool_unclaim "$KEY" "project lease lost before the launch of $KEY"; return 1
    fi
  fi
  # Parse the id off the "Machine ID:" line ONLY — the first bare 14-hex run in
  # the output is the image's sha256 digest when IMAGE carries one, and treating
  # that as the id orphans the real machine (2026-08-12, pool-project-3).
  # BH-8318: rows lane.fly-pool.<project>.vm_size / .vm_memory_mb; the literals
  # are their documented fallback (no lib, no row, or a refused row).
  local PVM_SIZE=performance-8x PVM_MEM=16384 PVM_WHY=""
  command -v pool_vm_resolve >/dev/null 2>&1 && { pool_vm_resolve || say "$KEY: VM size row refused ($PVM_WHY) — launching performance-8x/16384"; }
  # flyctl's stderr goes to a file in $TMP (removed with it on every exit), so a
  # failed launch logs why. /dev/null when $TMP is gone, so the call still runs.
  local FLYERR=/dev/null; [ -d "${TMP:-}" ] && FLYERR="$TMP/fly-run.err"
  MID=$(timeout 180 "$FLY" machine run "$IMAGE" -a "$APP" --detach --vm-size "$PVM_SIZE" --vm-memory "$PVM_MEM" \
        -e PROJECT="$P" -e POOL_MODE=1 -e HARNESS_CHECKOUT=/data/harness -e WARMUP_WAIT_S="$WW" ${PULL_ARGS[@]+"${PULL_ARGS[@]}"} 2>"$FLYERR" | grep -i 'machine id' | grep -oE "[0-9a-f]{14}" | head -1)
  # EVERY EXIT FROM HERE DOWN HANDS THE ROW BACK (see pool_unclaim): the claim is
  # already won, and under the flag a claim nobody releases is a key stranded in
  # flight for the stale-claim sweep's six hours.
  [ -n "$MID" ] || { say "machine run FAILED for $KEY — job stays queued$(fly_err_reason "$FLYERR")"
                     rm -rf "$TMP"; rm -f "$TB"
                     command -v pool_account_release >/dev/null 2>&1 && pool_account_release "$LEASE_ID"
                     pool_spawn_cap_unrecord "$KEY" "$SPAWNCAPTS"
                     pool_unclaim "$KEY" "fly machine run produced no machine for $KEY"; return 1; }
  local LAUNCH_T; LAUNCH_T=$(date +%s)
  # BH-5001: the claim above was won before the machine existed; name it now,
  # so "is this key building, and where" is answerable from the row on any hub.
  # Fail-open: the build goes ahead, and the reap and parity lanes own the rest.
  # On the pull path the machine stamps its own row (POOL_CLAIM_MACHINE).
  if [ "$PULL" != 1 ] && [ "${ROWS_ONLY:-0}" = 1 ] && command -v psr_claim_machine >/dev/null 2>&1; then
    psr_claim_machine "$P" "$KEY" "$MID" || say "$KEY: the claimed row could not be stamped with machine $MID (http=${JOBS_HTTP:-none}) — the build goes ahead"
  fi
  if [ -n "$MACCT" ] && command -v pool_account_rebind >/dev/null 2>&1; then
    pool_account_rebind "$LEASE_ID" "$MID" "$MACCT" "$P" "$KEY" \
      || say "$MID: the account lease could not move from $LEASE_ID to the machine id — the pre-launch row frees at its TTL"
  fi
  if [ "$PULL" = 1 ]; then
    # Everything the machine needs was in the launch: nothing waits, nothing pushes.
    OK=1
    pool_pull_landed "$MID" "$KEY" "$TMP"
  else
  sleep 20   # boot + entrypoint
  # The tarball was built before the launch (BH-7215); only the copy is here.
  SYNC_OK=1
  local SYNCERR=/dev/null; [ -d "${TMP:-}" ] && SYNCERR="$TMP/fly-sftp.err"
  timeout 120 "$FLY" ssh sftp put -a "$APP" --machine "$MID" "$TB" /run/harness/.hsync.tgz >/dev/null 2>"$SYNCERR" || SYNC_OK=0
  if [ "$SYNC_OK" = 1 ]; then
    mexec "$MID" "mkdir -p /data/harness && tar xzf /run/harness/.hsync.tgz -C /data/harness && mkdir -p /data/harness/logs /data/harness/state /data/harness/locks /data/harness/builds && rm -f /run/harness/.hsync.tgz" >/dev/null || SYNC_OK=0
  fi
  rm -f "$TB"
  if [ "$SYNC_OK" != 1 ]; then
    say "harness sync FAILED to $MID for $KEY — destroying, job stays queued$(fly_err_reason "$SYNCERR")"
    # BH-8780: before rm -rf "$TMP", so the stderr file is still there.
    command -v pss_note >/dev/null 2>&1 && pss_note fail "$P" "$KEY" "$MID" "$(fly_err_reason "$SYNCERR" | sed 's/^ :: //')"
    destroy_machine "$MID" "harness sync failed for $KEY"; rm -rf "$TMP"
    # The lease was taken before the launch (BH-7215), so this exit frees it too.
    command -v pool_account_release >/dev/null 2>&1 && pool_account_release "$MID"
    pool_spawn_cap_unrecord "$KEY" "$SPAWNCAPTS"
    pool_unclaim "$KEY" "harness sync to $MID failed"; return 1
  fi
  OK=1
  # BH-8780: a push-path sync passed, so the tunnel works: the streak ends.
  command -v pss_note >/dev/null 2>&1 && pss_note ok "$P" "$KEY" "$MID"
  if [ -s "$TMP/gh-token-read" ]; then
    mput "$MID" "$TMP/gh-token-read" /run/harness-env/gh-token-read \
      || say "$MID: gh-token-read push FAILED — git answers the project token for the extra repos"
  fi
  mput "$MID" "$TMP/global.env" /run/harness-env/global.env || OK=0
  # BH-7215: launch→first push seconds, on pass and fail.
  pool_warmup_note "$MID" "$KEY" "$LAUNCH_T" "$(date +%s)" "$WW"
  mput "$MID" "$TMP/$P.env" "/run/harness-env/$P.env" || OK=0
  # A failed overlay push costs ATTRIBUTION, never the build: the machine then
  # writes its cost rows under an unlabelled fingerprint.
  if [ -s "$TMP/auth-accounts.local.json" ]; then
    mput "$MID" "$TMP/auth-accounts.local.json" /data/harness/state/auth-accounts.local.json \
      || say "$MID: account label overlay push FAILED — its cost rows will land unlabelled"
  fi
  # Only written when the swap happened, so an unarmed box pushes exactly the two
  # files it pushes today and the builder finds no file to prefer.
  if [ -s "$TMP/gh-token" ]; then mput "$MID" "$TMP/gh-token" /run/harness-env/gh-token || OK=0; fi
  # >>> pool testhost route push
  # BH-8335: before job.json, so the runner starts with it. A failed push costs
  # the selection gate, never the build (OK stays).
  if [ -s "$TMP/testhost.env" ] && command -v ptr_push >/dev/null 2>&1 && ptr_push "$MID" "$TMP"; then
    say "$KEY: testhost route shipped to $MID (expires $(ptr_expires "$TMP"))"
  fi
  # <<< pool testhost route push
  # This tick's model-route answers (BH-1572, pool_mr_bundle below), before the
  # job file the runner starts on. A failed push costs the outage cover, never
  # the build: the machine resolves its own ladders, as it did before.
  if [ -s "${POOL_MR_BUNDLE:-}" ]; then
    mput "$MID" "$POOL_MR_BUNDLE" /run/harness-env/model-routes.tsv \
      || say "$MID: model-routes bundle push FAILED — it resolves its own ladders at job start"
  fi
  if [ -s "$TMP/cloudflare.env" ]; then mput "$MID" "$TMP/cloudflare.env" /run/harness-env/cloudflare.env || OK=0; fi
  mput "$MID" "$JF" /run/harness/job.json || OK=0
  fi
  rm -rf "$TMP"
  if [ "$OK" = 1 ]; then
    # Seed the fresh machine with the current preview snapshot so wait-preview
    # has state from minute zero; the REAP tick refreshes it on mtime change.
    # A pull machine got all of this in its seed (pool_pull_landed).
    if [ "$PULL" != 1 ]; then
    SNAP_SRC="$HARNESS/state/vercel-deploys/$P.json"
    if [ -s "$SNAP_SRC" ] && mput "$MID" "$SNAP_SRC" "/data/harness/state/vercel-deploys/$P.json"; then
      stat -c %Y "$SNAP_SRC" > "$POOL/.$MID.snapmt" 2>/dev/null || true
    fi
    push_preplan "$MID" "$KEY"
    push_reroute "$MID" "$KEY"
    push_build_note "$MID" "$KEY"
    push_bake_evidence "$MID"
    fi
    mv "$JF" "$QDIR/.$KEY.dispatched" 2>/dev/null; rm -f "$QDIR/.$KEY.dispatched"
    # `deaths` rides from the job file onto the machine json: the REAP pass
    # reads it back off $MF, so dropping it here would reset the count and the
    # blocked-resolver would never see a job die twice.
    # `auth_account` is the NAME of the leased account and never its token: the
    # reap reads it back to attribute the build and to cool the account down when
    # it refused, and the console reads it to say which account paid for this
    # machine. Absent = this machine shipped the project-6 token.
    # `hotfix` ($SHF) was read off the job file at the top of this function,
    # before the dispatch `mv` removed it.
    # `spawn_cap_ts` ($SPAWNCAPTS, BH-1279) is the exact line pool_spawn_cap_record
    # appended to this key's .spawns log above. Absent for a RB-* key, which the
    # cap never charges in the first place.
    # `spec_repos` (BH-6576) names the repos this machine's read-only token was
    # asked for by the ticket's `Spec-repo:` line. Absent for every other ticket;
    # next_job_or_destroy never reuses a machine that carries it.
    jq -nc --arg m "$MID" --arg k "$KEY" --arg t "$TICKET" --argjson a "$ATT" --argjson d "$SDEF" --argjson x "$SDTH" --arg ts "$(STAMP)" --arg sb "$SSB" --arg hf "$SHF" --arg ge "$MEXP" --arg aa "$MACCT" --arg sct "$SPAWNCAPTS" --arg sr "${SPEC_REPOS:-}" \
      '{machine:$m,key:$k,ticket_id:$t,attempt:$a,deferrals:$d,deaths:$x,spawned_at:$ts}
       + (if $sb == "" then {} else {stack_base:$sb} end)
       + (if $hf == "true" then {hotfix:true} else {} end)
       + (if $ge == "" then {} else {gh_token_expires_at:$ge} end)
       + (if $aa == "" then {} else {auth_account:$aa} end)
       + (if $sct == "" then {} else {spawn_cap_ts:$sct} end)
       + (if $sr == "" then {} else {spec_repos:$sr} end)' > "$POOL/$MID.json"
    # >>> machines rows (BH-1035)
    # Record the spawn in the machine registry, after the json the pool itself
    # reads. Fail-open: a broken worker does not stop the pool from running the
    # build on this machine. IMAGE/MACCT come from the enclosing scope — no new
    # positional, because tests/no-serialize-test.sh pins this argument list.
    machines_row machine_put "$P" "$APP" "$MID" pool "$KEY" "$TICKET" "${MACCT:-}" "$IMAGE" spawned
    # <<< machines rows
    # BH-7505: on a lane-run machine the record above exists only on this
    # machine until a write-back carries it home. Post it NOW, so a machine that
    # stops after this spawn leaves the hub with a record of the build machine,
    # not an untracked one. Fail-open: the final write-back retries.
    command -v pp_checkpoint >/dev/null 2>&1 && pp_checkpoint "$P" "$MID"
    # Bookkeeping: rc 2 (no such queued row) is the common case — the
    # dispatcher already claimed it when it materialised the file. Only on the
    # FLAG-OFF path: under the flag this claim already happened at the top of
    # this function, and it was a gate there rather than a `|| true`.
    [ "${ROWS_ONLY:-0}" = 1 ] || \
      { command -v queue_claim >/dev/null 2>&1 && queue_claim "$P" fly "$KEY" >/dev/null 2>&1; }
    # The live count is the DIRECTORY, and with spawns running concurrently it is
    # the only honest answer: this subshell cannot see its siblings' increments.
    say "spawned $MID for $KEY (${PULL_TAG}live=$(ls "$POOL" 2>/dev/null | wc -l | tr -d ' ')/$CAPTXT, budget $BUDGET this tick)"
    "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$P" --arg k "$KEY" '{kind:"build",project:$p,ticket_key:$k,stage:"pool_spawned"}')" >/dev/null 2>&1 || true
  else
    say "env/job push FAILED to $MID — destroying, job stays queued"
    destroy_machine "$MID" "env/job push failed for $KEY"
    rm -f "$POOL/.$MID.puterr"
    # The lease was taken before the push; a machine that never got its job must
    # not keep an account busy until the TTL.
    command -v pool_account_release >/dev/null 2>&1 && pool_account_release "$MID"
    # No build reached this machine, so it does not count against the cap (BH-4859).
    pool_spawn_cap_unrecord "$KEY" "$SPAWNCAPTS"
    # ...and neither must it keep the QUEUE ROW busy (BH-1026.3).
    pool_unclaim "$KEY" "env/job push to $MID failed"
    return 1
  fi
  return 0
}

# THE BUILD'S MODEL ROUTES, RESOLVED ONCE PER TICK (BH-1572). A fresh machine's
# route cache is empty, so a worker blip at its job start used to defer its build
# (no route, no guessed model). This box resolves the build's roles for $P once,
# before the first spawn of the tick, and every machine the tick spawns gets the
# answers with its env bundle (bin/lib/model-route.sh model_routes_bundle, which
# bounds the asking and stamps each ladder with when it was resolved). Once per
# tick and not per spawn: the spawns run concurrently, and N machines asking the
# worker the same seventeen questions at once is N-1 times too many. In its own
# subshell, so the resolver never changes this script's shell. Fail-open: no
# file means no bundle, and a machine without one behaves exactly as before.
POOL_MR_BUNDLE=""
pool_mr_bundle() {
  [ -z "$POOL_MR_BUNDLE" ] || return 0
  POOL_MR_BUNDLE=$(mktemp "${TMPDIR:-/tmp}/pool-mr.XXXXXX" 2>/dev/null) || { POOL_MR_BUNDLE=""; return 0; }
  ( . "$HARNESS/bin/lib/model-route.sh" 2>/dev/null && model_routes_bundle "$P" "$POOL_MR_BUNDLE" ) >/dev/null 2>&1
  if [ -s "$POOL_MR_BUNDLE" ]; then
    say "model routes: bundling $(cut -f1 "$POOL_MR_BUNDLE" | sort -u | wc -l | tr -d ' ') resolved ladder(s) for this tick's spawns"
  else
    say "model routes: nothing to bundle this tick — spawned machines resolve their own ladders"
  fi
}

# The launch loop itself is pure bookkeeping — jq reads and a flock-free dedupe —
# so it costs nothing to run to the end of the budget before anything waits.
