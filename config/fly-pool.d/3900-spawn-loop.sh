# >>> machines rows (BH-1035)
# Advisory row liveness before launch (BH-1056): a row that says a key is live
# but has no local file here still spawns, because the file is the truth this
# tick owns. Log-only. ONE list per tick, read before the loop.
LIVE_ROWS=""
if [ "$MROWS" = 1 ] && command -v machines_list >/dev/null 2>&1; then
  LIVE_ROWS=$(machines_list "$P" live 2>/dev/null || true)
fi
# <<< machines rows

LAUNCHED=0
HOT_LAUNCHED=0
TICK_KEYS=" "
# Malformed entries quarantined this tick: paged ONCE after the loop, however
# many there are, so a bad producer is one alert and not one per file.
QUAR=()
# BH-7421: the budget clock starts at the row walk, not at the lock: a long reap
# phase must not leave the walk no time. The first row is always decided. Rows
# walk oldest first, so a slow head row can use the budget on every tick; the
# budget stops the tick, it does not reorder the queue.
# The bulk read only when a row can spawn this tick: a free budget slot or a
# hotfix exemption. A full pool makes no PR read, as before the bulk read.
if [ "$BUDGET" -gt 0 ] 2>/dev/null || [ "${HOTFIX_EXTRA:-0}" -gt 0 ] 2>/dev/null; then
  pool_pr_bulk_prime
else
  say "PR bulk read: off (no free slot and no hotfix this tick)"
fi
# BH-7706: the reads every row shares, once, before the budget clock starts.
PDC_ON=0; command -v pdc_prime >/dev/null 2>&1 && { pdc_prime; PDC_ON=1; }
# pool_walk_spawn <hot> <jf> <key> <ticket> <attempt> <deaths> <stack-base> —
# a row the decision let through: its machine, in the background.
pool_walk_spawn() {
  local JF_HOT="$1" JF="$2" KEY="$3" TICKET="$4" ATT="$5" SDTH="$6" SSB="$7" SDEF
  # A release in the gate rewrote the file (BH-5967): the machine carries the
  # reset count, not the one read above.
  SDEF=$(jq -r '.deferrals // 0' "$JF" 2>/dev/null); case "$SDEF" in ''|*[!0-9]*) SDEF=0 ;; esac
  # SAY THE LINE THIS EXCEEDED. The WIP gate's exemption announces itself in
  # bin/run-build.sh; the pool's did not, and the tick line above only ever
  # reported the BUDGET — so a machine past the cap read as a cap that had never
  # been reached. One line, only when the exemption is actually spent.
  [ "$JF_HOT" = 1 ] && say "hotfix $KEY: pool at cap $CAPTXT (budget spent) — exceeding it by one machine"
  pool_pull_prime
  pool_mr_bundle
  spawn_one "$JF" "$KEY" "$TICKET" "$ATT" "$SDEF" "$SDTH" "$SSB" &
  if [ "$JF_HOT" = 1 ]; then HOT_LAUNCHED=$((HOT_LAUNCHED+1)); else LAUNCHED=$((LAUNCHED+1)); fi
}
PDC_SEEN=0; PDC_FIRST=0
# BH-7643: RB rows spawned this tick, the limit, and the keys past it.
_POOL_RB_N=0; _POOL_RB_WAIT=""; _POOL_RB_MAX=0
command -v pool_rb_max_per_tick >/dev/null 2>&1 && _POOL_RB_MAX=$(pool_rb_max_per_tick)
POOL_TICK_T0=$(date +%s)
for JF in $(hotfix_first $(ls -tr "$QDIR"/*.json 2>/dev/null)); do
  case "$JF" in *.failed.json) continue;; esac
  # BH-7475: the same stop rule at each queued row; the tail below still waits.
  command -v pts_stop_due >/dev/null 2>&1 && pts_stop_due && { PDC_STOP=stop; break; }
  # BH-7706: a slot is held from the start of a row's decision to its verdict
  # (PDC_PEND_PLAIN, PDC_PEND_HOT). With every budget slot held, a row first
  # waits for the pending verdicts, so the rule below reads what a serial walk
  # would: a skipped row's slot goes to the next row, and a hotfix spends the
  # exemption only when the budget is really spent. A hotfix never waits for
  # an exemption: HOTFIX_EXTRA is the count of hotfix rows, so one is free.
  while [ "$PDC_ON" = 1 ] && [ "$PDC_PEND_PLAIN" -gt 0 ] && [ $((LAUNCHED + PDC_PEND_PLAIN)) -ge "$BUDGET" ]; do pdc_collect || break; done
  # A hotfix spends a FREE BUDGET SLOT first and the exemption only when the
  # pool is genuinely at cap — `LAUNCHED -ge BUDGET` is the whole of that
  # sentence. Taking the exemption while the budget still had room is a machine
  # past a cap the pool never reached: cap 2, one live, one hotfix + one plain
  # queued would end the tick at THREE machines, and the plain row that rode the
  # freed budget slot is exactly the build the cap was there to refuse.
  # Hotfix files beyond the exemption are ordinary rows and take their turn on
  # the budget like any other, so a project that files six emergencies does not
  # get six free machines on top of six more.
  JF_HOT=0
  if [ "$LAUNCHED" -ge "$BUDGET" ] && [ $((HOT_LAUNCHED + ${PDC_PEND_HOT:-0})) -lt "$HOTFIX_EXTRA" ] && job_is_hot "$JF"; then JF_HOT=1; fi
  if [ "$JF_HOT" = 0 ]; then
    [ "$LAUNCHED" -lt "$BUDGET" ] || break
  fi
  PDC_SEEN=$((PDC_SEEN + 1))
  KEY=$(jq -r '.key // ""' "$JF"); TICKET=$(jq -r '.ticket_id // ""' "$JF"); ATT=$(jq -r '.attempt // 0' "$JF")
  SDEF=$(jq -r '.deferrals // 0' "$JF" 2>/dev/null); case "$SDEF" in ''|*[!0-9]*) SDEF=0 ;; esac
  SDTH=$(jq -r '.deaths // 0' "$JF" 2>/dev/null); case "$SDTH" in ''|*[!0-9]*) SDTH=0 ;; esac
  SSB=$(jq -r '.stack_base // ""' "$JF" 2>/dev/null); case "$SSB" in *[!A-Za-z0-9._/-]*) SSB="" ;; esac
  # Partial-data guard (2026-08-15): a queue entry with no key spawned a machine
  # "for " that idled to death (project-2 d897350c). Validate at the handoff; a bad
  # payload is quarantined loudly, never half-consumed.
  if [ -z "$KEY" ] || [ "$KEY" = "null" ] || [ -z "$TICKET" ] || [ "$TICKET" = "null" ]; then
    mv -f "$JF" "$JF.bad"
    [ -n "$KEY" ] && [ "$KEY" != null ] && QROW failed "$KEY" "malformed queue entry quarantined"
    QUAR+=("$(basename "$JF") (key='$KEY' ticket='$TICKET')")
    continue
  fi
  # skip jobs already running in the pool
  grep -ls "\"key\": *\"$KEY\"" "$POOL"/*.json >/dev/null 2>&1 && continue
  # >>> machines rows (BH-1035)
  # advisory: a live row with no matching file still spawns; log-only, no
  # `continue`. The row is not the gate this slice — it only says out loud that
  # it disagrees with the files, so the disagreement is countable before
  # anything starts trusting it.
  if [ "$MROWS" = 1 ] && [ -n "${LIVE_ROWS:-}" ]; then
    LIVE_ROW=$(printf "%s\n" "$LIVE_ROWS" | awk -F"\t" -v k="$KEY" '$5==k {print $1; exit}')
    [ -n "$LIVE_ROW" ] && say "row says $KEY is live on $LIVE_ROW and no file says so — spawning anyway this cycle (BH-1035 advisory; the row becomes the gate next slice)"
  fi
  # <<< machines rows
  # ...and jobs already launched by THIS tick. The pool json a sibling subshell
  # will write does not exist yet, so the guard above cannot see it: two queue
  # files for one key (a requeue racing its own leftover) would otherwise get two
  # machines. This is the dedupe the parallelism made necessary.
  case "$TICK_KEYS" in *" $KEY "*) continue ;; esac
  TICK_KEYS="$TICK_KEYS$KEY "
  # Dispatch mode (BH-6350): a held job stays queued; LAUNCHED is untouched.
  if command -v dm_job_admit >/dev/null 2>&1 && ! dm_job_admit "$JF"; then
    DM_HELD="${DM_HELD:+$DM_HELD }$KEY"; continue
  fi
  # BH-7643: an RB row past pool_rb_max_per_tick stays queued for the next
  # tick. `continue`, not `break`: the ticket rows behind it still get the
  # budget. Then a closed or merged PR closes the row and takes no slot.
  case "$KEY" in
    RB-*)
      if [ "$_POOL_RB_MAX" -gt 0 ] && [ "$_POOL_RB_N" -ge "$_POOL_RB_MAX" ]; then
        _POOL_RB_WAIT="${_POOL_RB_WAIT:+$_POOL_RB_WAIT }$KEY"; continue
      fi
      command -v pool_rb_close_if_pr_closed >/dev/null 2>&1 \
        && pool_rb_close_if_pr_closed "$JF" "$KEY" "$TICKET" && continue
      _POOL_RB_N=$((_POOL_RB_N + 1)) ;;
  esac
  # Spawn-decision gate: HOLD, open PR, terminal state, per-key cap (BH-1075).
  # BH-7706: in a background worker (bin/lib/pool-decide.sh). The tick budget
  # is checked here before each row after the first, as pool_spawn_decision
  # does in a serial walk; workers already started finish and spawn.
  if [ "$PDC_ON" = 1 ]; then
    case "$KEY" in
      RB-*|RR-*|LR-*|CP-*|FXR-*-*) ;;
      *) if [ "$PDC_BUDGET_N" -ge 1 ] && pool_tick_budget_spent; then
           [ -n "${_POOL_BUDGET_SAID:-}" ] || say "tick budget of ${POOL_TICK_BUDGET_S:-600}s spent for $P: no more rows are decided this tick, the lock is released at the end"
           _POOL_BUDGET_SAID=1; PDC_STOP=budget; PDC_SEEN=$((PDC_SEEN - 1)); break
         fi ;;
    esac
    pdc_start "$JF_HOT" "$JF" "$KEY" "$TICKET" "$ATT" "$SDTH" "$SSB"
    # The first counted row is decided alone, as the serial walk did: the
    # budget, the stop rule and its PR-unreadable state apply from row 2 on.
    if [ "$PDC_BUDGET_N" = 1 ] && [ "$PDC_FIRST" = 0 ]; then PDC_FIRST=1; pdc_drain; fi
    while [ "${#_PDC_PID[@]}" -ge "$PDC_PAR" ]; do pdc_collect || break; done
    continue
  fi
  if ! pool_spawn_decision "$JF" "$KEY" "$TICKET"; then
    # BH-7421: a spent tick budget ends the walk, so the lock is released.
    [ -n "${_POOL_BUDGET_SAID:-}" ] && break
    continue
  fi
  pool_walk_spawn "$JF_HOT" "$JF" "$KEY" "$TICKET" "$ATT" "$SDTH" "$SSB"
done
# BH-7706: every verdict still out, then one line with what the walk did.
if [ "$PDC_ON" = 1 ]; then
  pdc_drain
  PDC_LEFT=$((PDC_Q - PDC_SEEN)); [ "$PDC_LEFT" -ge 0 ] || PDC_LEFT=0
  [ "$PDC_LEFT" -gt 0 ] && [ -z "$PDC_STOP" ] && PDC_STOP=cap
  pdc_walk_line "$PDC_LEFT"
  pdc_cleanup
fi
if [ -n "$_POOL_RB_WAIT" ]; then
  say "rebase rows: $(wc -w <<<"$_POOL_RB_WAIT" | tr -d ' ') past pool_rb_max_per_tick=$_POOL_RB_MAX wait for the next tick ($_POOL_RB_WAIT)"
fi
# One hold-cache line per tick (BH-6549), only when a GitHub-issue row reached
# the HOLD gate. NOT "pool $P: ..." (tests/pool-autoscale-test.sh reads that).
[ "$_PHC_GATED" = 1 ] && say "hold cache: hits=$_PHC_HITS misses=$_PHC_MISSES bad=$_PHC_BAD listing=${_POOL_HOLD_LIST:-none} read_s=$_PHC_READ_S ttl_s=$_PHC_TTL"
# BH-7942: batched = rows read from the listing's issue object (no issue GET).
[ "$_PHC_GATED" = 1 ] && say "hold reads: batched=$_PHR_BATCHED retries=$_PHR_RETRIES retry_ok=$_PHR_RETRY_OK retry_off=$_PHR_RETRY_OFF timeout_s=$POOL_HOLD_READ_TIMEOUT_S"
if [ -n "$DM_HELD" ]; then
  DM_N=$(printf '%s' "$DM_HELD" | wc -w | tr -d ' ')
  say "DISPATCH-MODE hotfix-only: held $DM_N queued job(s) ($DM_HELD) — they stay queued; allow-list: $(dm_allow_text)"
fi
if [ "${#QUAR[@]}" = 1 ]; then
  HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] QUARANTINED malformed queue entry ${QUAR[0]} — find its producer"
elif [ "${#QUAR[@]}" -gt 1 ]; then
  _QJ=$(printf '%s; ' "${QUAR[@]}")
  HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] QUARANTINED ${#QUAR[@]} malformed queue entries: ${_QJ%; } — find their producer"
fi
# The tick owns its spawns: it does not exit until every one of them has either a
# machine with a job on it or a destroyed machine and a job still queued. Cron's
# next tick then sees a settled pool rather than half-pushed machines.
wait
[ -n "$POOL_MR_BUNDLE" ] && rm -f "$POOL_MR_BUNDLE"
exit 0
