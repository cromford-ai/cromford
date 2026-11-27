#!/bin/bash
# bin/quota-poll.sh — hourly, per box: how much headroom does each registered
# account have left? Writes state/quota/<account>.json; bin/account-pick.sh reads
# it. Runbook: docs/ACCOUNT-ROUTING.md.
#
# INERT UNTIL AN ACCOUNT EXISTS. With no env/accounts.d and no
# state/extra-usage-last.json this writes nothing and exits 0 in under a second,
# which is why the cron line is safe to install fleet-wide ahead of any account.
#
# IT NEVER POLLS THE DEFAULT ACCOUNT. bin/extra-usage-track.sh already polls that
# one at :58 and the usage endpoint's rate limit is PER ACCOUNT — a second poller
# costs the tracker its sample (its header says so, and the five-day 429 in its
# comments is what that looks like). So `default.json` is DERIVED from the raw
# response snapshot the tracker writes, and this script only ever calls the
# endpoint for accounts the tracker knows nothing about.
#
# WHAT CAN BE POLLED AT ALL: a claude account with CLAUDE_CONFIG_DIR, i.e. a full
# `claude login`, because only a full login's accessToken can read the usage
# endpoint (a setup-token gets 403 user:profile). Every other account form gets a
# status written honestly rather than a number invented for it:
#   claude + CLAUDE_CODE_OAUTH_TOKEN -> unreadable   (routing uses cooldowns only)
#   codex                            -> unknown      (no quota source exists)
#   grok / openrouter / fireworks    -> unmetered    (metered API, no plan limit)
#
# NO SECRET REACHES DISK OR A LOG. The token goes to the fetcher through the
# environment, the only strings copied out of the response are reset timestamps
# and numbers, and the fetcher's stderr is classified for a REASON, never stored
# verbatim beyond state/quota/.lasterr-<account> (0600).
set -uo pipefail

H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
# global.env is sourced here because cron does not, `+u` around it for the same
# reason extra-usage-track.sh does it: an unbound reference inside a config file
# must not be able to kill the meter that reads it.
set -a +u; . "$HENV/global.env" 2>/dev/null; set +a -u

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-quota-poll
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off quota-poll.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit quota-poll
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    quota-poll

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/account-pick.sh
if [ -r "$HERE/account-pick.sh" ]; then . "$HERE/account-pick.sh"
elif [ -r "$H/bin/account-pick.sh" ]; then . "$H/bin/account-pick.sh"
else echo "quota-poll.sh: account-pick.sh not found beside $0 or in $H/bin" >&2; exit 0; fi

QUOTA_DIR="${QUOTA_DIR:-$H/state/quota}"
LOG="${QUOTA_POLL_LOG:-$H/logs/quota-poll.log}"
FETCH="${OAUTH_USAGE_FETCH:-$HERE/lib/oauth-usage-fetch.py}"
SNAP="${EXTRA_USAGE_SNAPSHOT:-$H/state/extra-usage-last.json}"
# WHOSE METER IS `default`? (BH-1456). The snapshot above is the BOX LOGIN's —
# bin/extra-usage-track.sh writes it for CLAUDE_CONFIG_DIR's account. But the
# `default` CREDENTIAL is env/global.env's CLAUDE_CODE_OAUTH_TOKEN, and on the
# hub those are two different accounts: the login is operator_home@example.com (weekly
# 4%) while the token bills operator@second.example (weekly 100%). So the `default`
# row described an account nothing was spending. The tracker already writes a
# per-login snapshot with a `-<label>` suffix (extra-usage-track.sh poll_login),
# so naming the label here points the derivation at the account that actually
# pays. Unset (every box but the hub) = byte-identical to before, no log row.
DEFAULT_LABEL="${ACCOUNT_DEFAULT_LABEL:-}"
SNAP_SOURCE=extra-usage-track
if [ -n "$DEFAULT_LABEL" ]; then
  LSNAP="$H/state/extra-usage-last-$DEFAULT_LABEL.json"
  if [ -r "$LSNAP" ]; then
    SNAP="$LSNAP"; SNAP_SOURCE="extra-usage-track:$DEFAULT_LABEL"
  else
    SNAP_MISSING="$DEFAULT_LABEL"
  fi
fi
POLL_MIN_SECS="${ACCOUNT_POLL_MIN_SECS:-3000}"
STAGGER="${ACCOUNT_POLL_STAGGER_SECS:-90}"
PIN_TTL="${ACCOUNT_PIN_TTL_SECS:-604800}"
COOLDOWN_SECS="${ACCOUNT_COOLDOWN_SECS:-${MODEL_COOLDOWN_SECS:-21600}}"
NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

mkdir -p "$QUOTA_DIR" 2>/dev/null && chmod 700 "$QUOTA_DIR" 2>/dev/null
mkdir -p "$(dirname "$LOG")" 2>/dev/null
# `ts account status [reason]` — the optional third slot is the classified
# reason (403 scope gap vs 429 vs transient). It is what an operator tailing
# this log needs; dropping it left every error line reading just "error".
qlog() { printf '%s %s %s%s\n' "$NOW" "$1" "$2" "${3:+ $3}" >> "$LOG" 2>/dev/null || true; }

# Atomic + 0600: account-pick.sh must never read a half-written file, and the
# json is state about an account even though it holds no secret.
write_json() { # <account> <json-on-stdin>
  local f="$QUOTA_DIR/$1.json" t="$QUOTA_DIR/.$1.tmp.$$"
  cat > "$t" 2>/dev/null || return 1
  jq -e . "$t" >/dev/null 2>&1 || { rm -f "$t"; return 1; }
  chmod 600 "$t" 2>/dev/null
  mv -f "$t" "$f" 2>/dev/null
}

# OVERAGE IS A READING, AND IT WAS BEING THROWN AWAY (BH-1456). The endpoint
# reports an `extra_usage` object — is the account billing extra usage, has it
# hit its spend limit, what percent of that limit is spent — and this function
# used to emit only five_hour/seven_day/per_model. So no quota json could say
# "overage is on", and bin/account-pick.sh parked an account at weekly 100% that
# was serving every request perfectly well. It is carried through verbatim,
# renaming only `utilization` to `pct` the way the two windows above are.
# ABSENT IS NOT FALSE: a response with no extra_usage object produces `null`,
# not `{is_enabled:false}` — "we have no reading" and "overage is off" are
# different facts and the classifier branches on the difference.
#
# The endpoint's shape -> ours. per_model keys are every top-level
# `seven_day_<family>` object that carries a utilization, prefix stripped;
# seven_day_oauth_apps is excluded by name (it meters third-party apps, not a
# model). A family we guessed wrong simply does not appear, which is visible in
# quota-status.sh rather than silently wrong in the gate.
normalize() { # <account> <vendor> <source> <polled_at> ; raw json on stdin
  jq --arg a "$1" --arg v "$2" --arg s "$3" --arg t "$4" '
    def q(x): if (x|type) == "object" and (x.utilization != null)
              then {pct: x.utilization, resets_at: (x.resets_at // null)} else null end;
    { account: $a, vendor: $v, status: "ok", source: $s, polled_at: $t,
      five_hour: q(.five_hour), seven_day: q(.seven_day),
      extra_usage: (if (.extra_usage|type) == "object"
                    then {is_enabled:          (.extra_usage.is_enabled          // false),
                          spend_limit_reached: (.extra_usage.spend_limit_reached // false),
                          disabled_reason:     (.extra_usage.disabled_reason     // null),
                          user_disabled:       (.extra_usage.user_disabled       // false),
                          monthly_limit:       (.extra_usage.monthly_limit       // null),
                          used_credits:        (.extra_usage.used_credits        // null),
                          pct:                 (.extra_usage.utilization         // null)}
                    else null end),
      per_model: ( [ to_entries[]
                     | select(.key | startswith("seven_day_"))
                     | select(.key != "seven_day_oauth_apps")
                     | select((.value | type) == "object" and .value.utilization != null)
                     | {key: (.key | sub("^seven_day_"; "")),
                        value: {pct: .value.utilization, resets_at: (.value.resets_at // null)}} ]
                   | from_entries ) }' 2>/dev/null
}

status_json() { # <account> <vendor> <status> [error]
  jq -n --arg a "$1" --arg v "$2" --arg s "$3" --arg t "$NOW" --arg e "${4:-}" \
    '{account:$a, vendor:$v, status:$s, source:"none", polled_at:$t,
      five_hour:null, seven_day:null, per_model:{}, extra_usage:null}
     + (if $e == "" then {} else {error:$e} end)' 2>/dev/null
}

json_age_secs() { # <account> -> seconds since polled_at, or a very large number
  local f="$QUOTA_DIR/$1.json" p e
  [ -r "$f" ] || { echo 999999999; return 0; }
  p=$(jq -r '.polled_at // ""' "$f" 2>/dev/null)
  [ -n "$p" ] || { echo 999999999; return 0; }
  e=$(date -u -d "$p" +%s 2>/dev/null) || e=0
  case "$e" in ''|*[!0-9]*) echo 999999999; return 0 ;; esac
  echo $(( $(date -u +%s) - e ))
}

# ── the registered accounts ──────────────────────────────────────────────────
accounts_load
POLLED=0
for A in "${ACCOUNT_NAMES[@]+"${ACCOUNT_NAMES[@]}"}"; do
  V="${ACCT_VENDOR[$A]}"
  CDIR=""; [ "$V" = claude ] && CDIR=$(account_cred_get "$A" CLAUDE_CONFIG_DIR || true)
  if [ -z "$CDIR" ]; then
    # Not pollable. The status is rewritten every run so polled_at stays honest
    # about when we last looked, rather than aging into "stale" and reading as a
    # poller that stopped.
    case "$V" in
      claude) ST=unreadable ;;
      codex)  ST=unknown ;;
      *)      ST=unmetered ;;
    esac
    status_json "$A" "$V" "$ST" | write_json "$A" && qlog "$A" "$ST" || qlog "$A" "write_failed"
    continue
  fi
  # Rate guard: one poll per account per ACCOUNT_POLL_MIN_SECS, so a manual run
  # beside the cron tick cannot double the rate against a per-account limit.
  AGE=$(json_age_secs "$A")
  if [ "$AGE" -lt "$POLL_MIN_SECS" ]; then qlog "$A" "skip_fresh(${AGE}s)"; continue; fi
  # Stagger between the accounts that actually call out.
  [ "$POLLED" -gt 0 ] && sleep "$STAGGER"
  POLLED=$(( POLLED + 1 ))
  # Refresh an expired/near-expiry login first (2026-09-07): routed accounts run
  # on their own CLAUDE_CONFIG_DIR and nothing else keeps that file alive.
  "$H/bin/oauth-refresh.sh" "$CDIR" "$A" >/dev/null 2>&1 || true
  TOK=$(jq -r '.claudeAiOauth.accessToken // empty' "$CDIR/.credentials.json" 2>/dev/null)
  if [ -z "$TOK" ]; then
    status_json "$A" "$V" error "no accessToken in $CDIR/.credentials.json" | write_json "$A"
    qlog "$A" "error" "no_credentials_file"; continue
  fi
  ERRF="$QUOTA_DIR/.lasterr-$A"
  RAW=$(OAUTH_USAGE_TOKEN="$TOK" "$FETCH" 2>"$ERRF")
  RC=$?
  chmod 600 "$ERRF" 2>/dev/null
  if [ "$RC" -ne 0 ] || [ -z "$RAW" ]; then
    # Classify the REASON the way extra-usage-track.sh does — a permanent
    # capability gap and a transient timeout need different answers, and
    # collapsing them into "poll failed" is what bought that meter five silent
    # days. Reason text only; the fetcher never echoes the token.
    if grep -qiE 'user:profile|scope requirement|HTTP Error 403|\b403\b' "$ERRF" 2>/dev/null; then
      E="token lacks user:profile scope"
    elif grep -q 'HTTP Error 429' "$ERRF" 2>/dev/null; then
      E="usage endpoint answered 429"
    elif grep -q 'NO_TOKEN' "$ERRF" 2>/dev/null; then
      E="no token available"
    else
      E="poll failed (transient?)"
    fi
    status_json "$A" "$V" error "$E" | write_json "$A"
    qlog "$A" "error" "$E"; continue
  fi
  if printf '%s' "$RAW" | normalize "$A" "$V" oauth-usage "$NOW" | write_json "$A"; then
    qlog "$A" "ok"
  else
    status_json "$A" "$V" error "unparseable response" | write_json "$A"
    qlog "$A" "error" "unparseable_response"
  fi
done

# ── the implicit `default` account, derived not polled ───────────────────────
# polled_at is the snapshot's mtime: that is when the numbers were actually read,
# which is the only honest answer for a file another script wrote.
# A label that names a snapshot this box does not have is an operator error
# worth exactly one row per run — it means the hub's ACCOUNT_DEFAULT_LABEL and
# its EXTRA_USAGE_LOGINS disagree — and then the plain derivation stands rather
# than the `default` row going blank.
[ -n "${SNAP_MISSING:-}" ] && qlog default "fallback" "label_snapshot_missing:$SNAP_MISSING"
if [ -r "$SNAP" ]; then
  SNAP_TS=$(date -u -d "@$(stat -c %Y "$SNAP" 2>/dev/null || echo 0)" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "$NOW")
  if normalize default claude "$SNAP_SOURCE" "$SNAP_TS" < "$SNAP" | write_json default; then
    qlog default "ok"
  else
    status_json default claude unreadable | write_json default; qlog default "unreadable" "snapshot_unparseable"
  fi
elif [ -f "$QUOTA_DIR/default.json" ]; then
  # The tracker stopped or never worked on this box (8 of 9 boxes get 403). Say
  # so rather than leaving yesterday's numbers looking current.
  status_json default claude unreadable | write_json default; qlog default "unreadable" "no_snapshot"
fi

# ── housekeeping ─────────────────────────────────────────────────────────────
# Pins expire so a build directory that vanished months ago cannot keep steering
# traffic; cooldown stamps are inert once expired and are swept at 2x the window.
[ -d "$QUOTA_DIR/pins" ] && find "$QUOTA_DIR/pins" -type f -mmin "+$(( PIN_TTL / 60 ))" -delete 2>/dev/null
[ -d "$QUOTA_DIR/cooldown" ] && find "$QUOTA_DIR/cooldown" -type f -mmin "+$(( COOLDOWN_SECS / 30 ))" -delete 2>/dev/null

# ── rules parity for alternate claude config dirs ────────────────────────────
# The CLI reads CLAUDE.md, RTK.md and settings.json from CLAUDE_CONFIG_DIR, so an
# account whose dir lacks them runs the fleet's builds WITHOUT the machine rules
# and without the rtk hook — the same gap the codex/grok lanes had before
# sync-agent-rules.sh. docs/ACCOUNT-ROUTING.md says to symlink them; this is the
# check that the operator did. One ALERTS line per account per day, never a loop.
for A in "${ACCOUNT_NAMES[@]+"${ACCOUNT_NAMES[@]}"}"; do
  [ "${ACCT_VENDOR[$A]}" = claude ] || continue
  CDIR=$(account_cred_get "$A" CLAUDE_CONFIG_DIR || true); [ -n "$CDIR" ] || continue
  MISS=""
  for F in CLAUDE.md RTK.md settings.json; do
    [ -e "$CDIR/$F" ] || MISS="$MISS $F"
  done
  [ -n "$MISS" ] || continue
  FLAG="$H/flags/alerted-account-rules-$A-$(date -u +%Y%m%d)"
  [ -f "$FLAG" ] && continue
  mkdir -p "$H/flags" 2>/dev/null && touch "$FLAG" 2>/dev/null
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [quota-poll] ACCOUNT $A HAS NO MACHINE RULES: $CDIR is missing$MISS. Every build routed to this account runs without rules/CLAUDE.md and without the rtk hook. Fix: symlink them from /root/.claude (docs/ACCOUNT-ROUTING.md), or set ACCOUNT_ENABLED=0 in env/accounts.d/$A.env." >> "$H/logs/ALERTS.log"
done

exit 0
