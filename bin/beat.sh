#!/bin/bash
# alert-writer: by-design — it is the sink bin/alert-line.sh calls; routing its writes through the helper would recurse
# beat.sh '<json>' — post one status beat to the console. Never fails the caller.
#
# BEAT_STRICT=1 is an opt-in, per call, and it changes only the final POST: the
# caller then learns whether the console actually took the beat (rc 1 = it did
# not, rc 2 = this box has no console configured). Every caller that does not
# set it still cannot be failed by a beat, on any path.
#
# Alert quarantine (the operator, 2026-08-06: "triage problems before I even get alerted
# — the alerts are just noise since I just ask you to fix it"): a fleet_alert
# beat no longer goes straight to the console/Telegram. It is queued locally in
# state/alert-quarantine.jsonl; the hub's alert-triage lane collects every box's
# queue, investigates, FIXES what is fixable, and escalates only what needs the operator
# — those escalations carry "triaged":true and pass straight through here.
# Safety valve: alert-flush.sh force-escalates anything still queued after 45
# minutes, so a dead triage lane can never silence a real fire. Kill switch:
# the settings row switch.alert-quarantine-disabled[.<box>] (or
# flags/alert-quarantine-disabled when no row) restores the old direct path.
#
# Pre-emptive remediation (the operator, 2026-08-25): seven alert classes paged in one
# round and FOUR of them were mechanically self-clearing — a Fly machine Fly had
# already purged, PRs already closed/superseded, a build whose RESULT was a
# terminal BUILD_DEFERRED the close-out sweep has no handler for. Those never
# needed a human, only a query. Every alert lane converges on this file, so this
# is where the question gets asked: before an untriaged fleet_alert is
# quarantined (or posted), a per-namespace handler under bin/remediations/ gets
# ONE chance, once per akey per 6h, to prove the condition is already settled.
#
# Tier-2 LLM remediator (the operator, 2026-08-25): the static handlers cover four
# namespaces. Everything else — and everything a handler failed open on — still
# reaches a human untried. So when tier 1 does not settle an alert, an LLM
# remediator gets ONE bounded attempt (bin/remediate-agent.sh) before the page
# goes out, and unlike a handler it may try to FIX rather than only verify.
# OPT-IN: tier 2 runs only where flags/remediation-agent-enabled exists — a hub
# pilot, not a fleet default. Both tiers share the one 6h attempt per akey, and
# tier 2 additionally carries a daily run cap so an alert storm cannot become
# unbounded LLM spend.
#
# FAIL OPEN is the load-bearing property. Anything other than a clean exit 0
# (remediated) or 10 (terminal end state) — no handler, crash, timeout, non-zero
# — leaves the alert on exactly the path it takes today. Neither tier can
# swallow an alert it did not prove settled, and a tier-2 REMEDIATED/TERMINAL is
# only honoured when the agent quoted the condition check it re-ran. When tier 2
# escalates, the alert still pages — carrying the agent's one-line diagnosis, so
# the page arrives enriched instead of merely late. Kill switch:
# flags/remediation-disabled kills BOTH tiers. Full contract:
# docs/ALERT-REMEDIATION.md.
set -u
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
[ -n "$BIN" ] || BIN="$H/bin"
set -a; . $HENV/global.env 2>/dev/null; set +a
# Below the env load, so lane-gate.sh fills its LANE_GATE_* defaults after global.env.
# shellcheck source=lib/lane-switch.sh
. "$BIN/lib/lane-switch.sh" 2>/dev/null || true
command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "$H/flags/$1" ]; }   # no lib: the file, as before

PAYLOAD="${1:-}"
[ -n "$PAYLOAD" ] || exit 0

# ── ALERT STATE MACHINE (the operator, 2026-09-15: "the alerts topic is noise") ─────
# Every alert in the fleet converges here — a lane's own fleet_alert, a
# deterministic checker's beat, and poll-commands.sh re-beating each new
# ALERTS.log line as kind:"alert" — so this is where a repeat stops being a
# page. bin/lib/alert-state.sh keys the condition (explicit .alertid, else a
# normalised hash of .line), counts repeats against state/alerts/<id>.json and
# answers fire / remind / suppress. Contract: docs/ALERTS-STATE-MACHINE.md.
#
# This is deliberately BEFORE the remediation tiers below: a suppressed repeat
# is the same condition we already looked at, and letting it consume a 6h
# remediation attempt would push the real next incident past the throttle.
#
# NEVER applied to "triaged":true. Those are conclusions addressed to a human —
# the medic's escalation whose akey is its permanent address, alert-triage's,
# and this file's own digest — already deduped by the console on that key. A
# second dedupe here could only swallow them.
#
# FAIL OPEN, in every direction: no library, no jq, no python3, the flag
# flags/alert-state-off or ALERT_STATE_ENABLED=0, and the beat takes exactly the
# path it took before this block existed.
# shellcheck source=bin/lib/alert-state.sh
. "$BIN/lib/alert-state.sh" 2>/dev/null || true
if command -v alert_state_note >/dev/null 2>&1 && alert_state_enabled \
   && grep -qE '"kind":"(fleet_)?alert"' <<<"$PAYLOAD" \
   && ! grep -q '"triaged":true' <<<"$PAYLOAD" \
   && command -v jq >/dev/null 2>&1; then
  AS_LINE=$(jq -r '.line // ""' <<<"$PAYLOAD" 2>/dev/null)
  # A NOTICE IS NOT AN ALERT (BH-2337). A success or recovery line
  # (fleet-propagate N/N, HOTFIX seen, main GREEN again, an admin-covered repo)
  # arrives here as poll-commands.sh's re-beat of its ALERTS.log line. It keeps
  # that line and is never noted or sent: noting it is what upserts a row. A
  # retraction is exempt — it closes a row, it does not open one.
  if ! grep -q '"resolved":true' <<<"$PAYLOAD" && alert_state_logonly "$AS_LINE"; then
    as_log "log-only :: $AS_LINE"
    exit 0
  fi
  AS_STATE=$(jq -r '.alertstate // ""' <<<"$PAYLOAD" 2>/dev/null)
  AS_ID=$(jq -r '.alertid // ""' <<<"$PAYLOAD" 2>/dev/null)
  AS_SEV=$(alert_state_route "$AS_LINE" "$(jq -r '.severity // ""' <<<"$PAYLOAD" 2>/dev/null)")
  # .alertstate means bin/lane-alert.sh already ran the state machine for this
  # line. Counting it twice would halve every reminder interval; only the
  # severity routing below still applies.
  if [ -z "$AS_STATE" ] && grep -q '"resolved":true' <<<"$PAYLOAD"; then
    # A RETRACTION CLOSES THE ROW ITS ALERT OPENED (BH-4054). It is never
    # noted (noting is what upserts a row, so a resolve would open one), and
    # it rides the channel the condition was opened on, not a fresh routing of
    # its "all clear" text. A resolve of nothing open is silent.
    [ -n "$AS_ID" ] || AS_ID=$(alert_state_key "$AS_LINE")
    read -r AS_D AS_N AS_RSEV < <(alert_state_resolve "$AS_ID")
    if [ "${AS_D:-}" != resolve ]; then
      as_log "resolve-silent id=$AS_ID :: $AS_LINE"
      exit 0
    fi
    AS_SEV="${AS_RSEV:-critical}"
    AS_P=$(jq -c '.alertstate = "resolve"' <<<"$PAYLOAD" 2>/dev/null) && [ -n "$AS_P" ] && PAYLOAD="$AS_P"
    as_log "resolve id=$AS_ID n=$AS_N sev=$AS_SEV :: $AS_LINE"
  elif [ -z "$AS_STATE" ]; then
    [ -n "$AS_ID" ] || AS_ID=$(alert_state_key "$AS_LINE")
    # The project rides along (BH-1070): with the alerts row on it is what
    # routes the condition to a project's Telegram topic, and a row that
    # carries no project lands every alert about a project in General.
    read -r AS_D AS_N < <(alert_state_note "$AS_ID" "$AS_SEV" "$AS_LINE" \
      "$(jq -r '.project // ""' <<<"$PAYLOAD" 2>/dev/null)")
    case "$AS_D" in
      suppress)
        as_log "still firing id=$AS_ID n=$AS_N sev=$AS_SEV :: $AS_LINE"
        exit 0 ;;
      remind)
        AS_P=$(jq -c --arg n "$AS_N" '.line = ((.line // "") + " (still firing, n=" + $n + ")")' \
                 <<<"$PAYLOAD" 2>/dev/null) && [ -n "$AS_P" ] && PAYLOAD="$AS_P" ;;
    esac
    # THE DECISION RIDES THE BEAT (V1 alert hygiene). The console pings a
    # still-open row only when alertstate is fire or remind
    # (cromford-console src/alert-ping.js): with alerts keyed on their
    # condition, that is what makes a persistent condition re-page at
    # ALERT_REMINDER_S instead of exactly once. Best effort: a jq failure leaves
    # the payload as it was, which is the pre-V1 console behaviour.
    case "$AS_D" in fire|remind)
      AS_P=$(jq -c --arg s "$AS_D" '.alertstate = $s' <<<"$PAYLOAD" 2>/dev/null) && [ -n "$AS_P" ] && PAYLOAD="$AS_P" ;;
    esac
    as_log "$AS_D id=$AS_ID n=$AS_N sev=$AS_SEV :: $AS_LINE"
  fi
  case "$AS_SEV" in
    # info never leaves the box. The ALERTS.log line its emitter wrote is still
    # there, and logs/alerts-state.log records that we chose not to send.
    info) as_log "info-only id=$AS_ID :: $AS_LINE"; exit 0 ;;
    # warn waits for the digest cadence and arrives folded into one message.
    warn) alert_state_batch_warn "$PAYLOAD" && { as_log "batched id=$AS_ID :: $AS_LINE"; exit 0; } ;;
  esac
fi

REM_WINDOW=21600      # one remediation attempt per akey per 6h — SHARED by both tiers
REM_AGENT_BOUND=360   # outer bound on tier 2; agent-call's own timeout is 300s

# rem_log <akey> <who> <exit> <verdict> <summary> — one tab-separated line.
rem_log() {
  printf '%s\t%s\t%s\texit=%s\t%s\t%s\n' \
    "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$1" "$2" "$3" "$4" "$5" \
    >> "$H/logs/remediation.log" 2>/dev/null
}

# rem_try <payload> — 0 = settled, suppress the alert; non-zero = fail open.
# Called inside a subshell so that even a set -u abort in here can only fail
# open; nothing in this function may return 0 without a handler verdict.
rem_try() {
  local payload="$1" akey line rest f1 f2 rdir handler agent out rc last now verdict s

  [ -f "$H/flags/remediation-disabled" ] && return 1
  command -v jq >/dev/null 2>&1 || return 1
  akey=$(jq -r '.akey // ""' <<<"$payload" 2>/dev/null) || return 1
  [ -n "$akey" ] || return 1

  # An akey field becomes a FILENAME. Namespaces are code-authored, but the tail
  # of an akey carries machine ids, project names and PR refs, so refuse
  # outright anything that is not [A-Za-z0-9_-] rather than sanitising it.
  f1=${akey%%:*}
  case "$akey" in *:*) rest=${akey#*:}; f2=${rest%%:*} ;; *) f2="" ;; esac
  case "$f1" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  case "$f2" in *[!A-Za-z0-9_-]*) f2="" ;; esac

  # Most specific first: <f1>-<f2>.sh, then <f1>.sh. No handler is no longer
  # the end of the road — tier 2 covers every namespace — but with tier 2 off it
  # still costs no throttle budget: a namespace nobody wrote a handler for must
  # not burn the one attempt the namespace next door might want.
  rdir="$BIN/remediations"
  handler=""
  [ -n "$f2" ] && [ -x "$rdir/$f1-$f2.sh" ] && handler="$rdir/$f1-$f2.sh"
  [ -z "$handler" ] && [ -x "$rdir/$f1.sh" ] && handler="$rdir/$f1.sh"

  # TIER 2, opt-in. The flag is created by hand on the pilot box; the fleet
  # default is absent, which is exactly today's behaviour.
  agent=""
  [ -f "$H/flags/remediation-agent-enabled" ] && [ -x "$BIN/remediate-agent.sh" ] \
    && agent="$BIN/remediate-agent.sh"

  # Nothing to try at either tier: today's path, no claim, no log line.
  [ -n "$handler" ] || [ -n "$agent" ] || return 1

  # Claim the attempt BEFORE running it, under the same flock the quarantine
  # file uses. Recording first means a handler that hangs or dies cannot be
  # re-run every tick for the rest of the window.
  mkdir -p "$H/state" "$H/logs" 2>/dev/null
  s="$H/state/remediation-attempts.tsv"
  touch "$s" 2>/dev/null || return 1
  now=$(date -u +%s)
  ( exec 7>"$s.lock"; flock -w 5 7 || exit 1
    last=$(awk -F'\t' -v k="$akey" '$2==k{t=$1} END{print t+0}' "$s" 2>/dev/null)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    [ $(( now - last )) -lt "$REM_WINDOW" ] && exit 1
    awk -F'\t' -v c=$(( now - REM_WINDOW * 2 )) '($1+0) >= c' "$s" 2>/dev/null > "$s.tmp"
    printf '%s\t%s\n' "$now" "$akey" >> "$s.tmp"
    mv -f "$s.tmp" "$s"
  ) || return 1

  line=$(jq -r '.line // ""' <<<"$payload" 2>/dev/null)

  # ---- TIER 1: the static handler ------------------------------------------
  if [ -n "$handler" ]; then
    out=$(timeout 60 "$handler" "$akey" "$line" "$payload" </dev/null 2>/dev/null); rc=$?
    # One line, bounded: a handler's summary is evidence, not a transcript, and
    # this log is read by humans. Handlers never print secrets; truncate anyway.
    out=$(head -1 <<<"$out" | tr -d '\t\r' | cut -c1-300)
    case "$rc" in
      0)   verdict=REMEDIATED ;;
      10)  verdict=TERMINAL ;;
      124) verdict=FAILOPEN-timeout ;;
      *)   verdict=FAILOPEN ;;
    esac
    rem_log "$akey" "${handler##*/}" "$rc" "$verdict" "$out"
    if [ "$rc" = 0 ] || [ "$rc" = 10 ]; then return 0; fi
  fi

  # ---- TIER 2: one bounded LLM attempt -------------------------------------
  # Reached when tier 1 had no handler for the namespace, or had one and failed
  # open. Same argv and same exit-code contract as a handler, so the difference
  # between the tiers lives in remediate-agent.sh and not in this hook.
  #
  # The outer bound is this box's, not the agent's: agent-call.sh already bounds
  # the model call at 300s, and this is the guarantee a cron lane calling beat.sh
  # gets even when that bound is the thing that fails.
  [ -n "$agent" ] || return 1
  out=$(timeout "$REM_AGENT_BOUND" "$agent" "$akey" "$line" "$payload" </dev/null 2>/dev/null); rc=$?
  out=$(head -1 <<<"$out" | tr -d '\t\r' | cut -c1-300)
  case "$rc" in
    0)   verdict=REMEDIATED ;;
    10)  verdict=TERMINAL ;;
    124) verdict=FAILOPEN-timeout ;;
    *)   verdict=FAILOPEN ;;
  esac
  # Logged here as well as inside the wrapper on purpose: the wrapper's own line
  # carries the transcript path, but a wrapper killed at the bound above never
  # writes one. This line is the record that the attempt happened at all.
  rem_log "$akey" "tier2-dispatch" "$rc" "$verdict" "$out"
  if [ "$rc" = 0 ] || [ "$rc" = 10 ]; then return 0; fi

  # Hand the diagnosis back for the page. A file, because rem_try runs in a
  # subshell and a variable set in here dies with it.
  if [ -n "$out" ] && [ -n "${REM_DIAG_FILE:-}" ]; then
    printf '%s\n' "$out" > "$REM_DIAG_FILE" 2>/dev/null
  fi
  return 1
}

REM_DIAG_FILE=""
if grep -q '"kind":"fleet_alert"' <<<"$PAYLOAD" \
   && ! grep -q '"triaged":true' <<<"$PAYLOAD" \
   && ! grep -q '"resolved":true' <<<"$PAYLOAD"; then
  # A resolved:true beat is a RETRACTION, not an alert — remediating it would
  # suppress the very notice that the condition cleared.
  REM_DIAG_FILE=$(mktemp 2>/dev/null) || REM_DIAG_FILE=""
  if ( rem_try "$PAYLOAD" ) 2>/dev/null; then
    [ -n "$REM_DIAG_FILE" ] && rm -f "$REM_DIAG_FILE" 2>/dev/null
    exit 0
  fi
  # ENRICHMENT. The alert is going to page either way; this only decides whether
  # it arrives with the remediator's one-line diagnosis attached. So every step
  # is guarded and every failure leaves PAYLOAD exactly as it arrived — an
  # enrichment bug must never be able to cost a page.
  if [ -n "$REM_DIAG_FILE" ] && [ -s "$REM_DIAG_FILE" ]; then
    REM_DIAG=$(head -1 "$REM_DIAG_FILE" 2>/dev/null | tr -d '\t\r' | cut -c1-200)
    if [ -n "${REM_DIAG:-}" ]; then
      REM_ENRICHED=$(jq -c --arg d "$REM_DIAG" \
        '.line = ((.line // "") + " [remediator tried: " + $d + "]")' <<<"$PAYLOAD" 2>/dev/null) || REM_ENRICHED=""
      [ -n "${REM_ENRICHED:-}" ] && PAYLOAD="$REM_ENRICHED"
    fi
  fi
  [ -n "$REM_DIAG_FILE" ] && rm -f "$REM_DIAG_FILE" 2>/dev/null
fi

if grep -q '"kind":"fleet_alert"' <<<"$PAYLOAD" \
   && ! grep -q '"triaged":true' <<<"$PAYLOAD" \
   && ! lane_switch alert-quarantine-disabled file; then
  Q="$H/state/alert-quarantine.jsonl"
  mkdir -p "$H/state"
  QTS=$(date -u +%s)
  ( exec 7>"$Q.lock"; flock 7
    printf '%s\t%s\n' "$QTS" "$PAYLOAD" >> "$Q"
  ) 2>/dev/null
  # THE FILE APPEND IS FIRST AND UNCONDITIONAL (BH-1070). The row is where the
  # hub's triage lane will look, but the local queue is what alert-flush.sh
  # force-escalates after 45 minutes, and an alert that exists in neither place
  # because a network call came first is an alert nobody ever sees.
  #
  # Marking the row is therefore best-effort and happens OUTSIDE the flock (a
  # lock held across a network call blocks every sibling beat). Only a
  # confirmed mark stamps the queued payload "dbrow":true — that stamp is what
  # tells alert-flush.sh the DB pass owns this entry, so inventing it on a
  # failed mark would drop the alert from both paths. A 409 means the row is
  # not `new` any more (someone else moved it); no stamp, no retry.
  if [ -n "${AS_ID:-}" ] && ! grep -q '"resolved":true' <<<"$PAYLOAD" \
     && command -v alerts_db_on >/dev/null 2>&1 && alerts_db_on; then
    QRC=0; alert_state_set "$AS_ID" quarantined beat >/dev/null 2>&1 || QRC=$?
    if [ "$QRC" -eq 0 ]; then
      QNEW=$(jq -c '.dbrow=true' <<<"$PAYLOAD" 2>/dev/null) || QNEW=""
      if [ -n "$QNEW" ]; then
        ( exec 7>"$Q.lock"; flock 7
          # The payload reaches awk through the ENVIRONMENT, never -v: -v
          # unescapes backslashes, and these lines are JSON. The LAST exact
          # TS+payload match is the line this call appended.
          QT="$QTS" QP="$PAYLOAD" QN="$QNEW" awk '
            BEGIN { target = ENVIRON["QT"] "\t" ENVIRON["QP"]
                    stamped = ENVIRON["QT"] "\t" ENVIRON["QN"] }
            { line[NR] = $0; if ($0 == target) last = NR }
            END { for (i = 1; i <= NR; i++) print (i == last ? stamped : line[i]) }
          ' "$Q" > "$Q.tmp" 2>/dev/null && mv -f "$Q.tmp" "$Q" 2>/dev/null
        ) 2>/dev/null
      fi
    else
      command -v as_log >/dev/null 2>&1 && as_log "quarantine-mark id=$AS_ID rc=$QRC"
    fi
  fi
  exit 0
fi

if [ -z "${CONSOLE_URL:-}" ] || [ -z "${HARNESS_SECRET:-}" ]; then
  [ "${BEAT_STRICT:-}" = 1 ] && exit 2
  exit 0
fi
# The status code is read, not discarded, so strict callers can tell a delivered
# beat from a 500. Body still goes to /dev/null; nothing here prints.
CODE=$(curl -s --max-time 15 -o /dev/null -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $HARNESS_SECRET" -H 'Content-Type: application/json' \
  -d "$PAYLOAD" "$CONSOLE_URL/api/beat" 2>/dev/null)
CRC=$?
[ "${BEAT_STRICT:-}" = 1 ] || exit 0
[ "$CRC" = 0 ] || exit 1
case "$CODE" in 2??) exit 0 ;; *) exit 1 ;; esac
