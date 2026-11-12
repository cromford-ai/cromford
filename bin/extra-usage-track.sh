#!/bin/bash
# bin/extra-usage-track.sh <box-id> — EVERY box, every 15 minutes: poll the
# Anthropic OAuth usage endpoint for EVERY subscription account whose login this
# box holds, and log whether we're inside the plan's included credits or burning
# EXTRA USAGE (cash at API rates).
#
# PER-ACCOUNT, NOT PER-BOX (2026-09-14). This used to poll exactly one login —
# the box's own /root/.claude — on the doctrine that "the account each box
# reports IS the account it bills". That held until the hub: its lanes run on
# the CLAUDE_CODE_OAUTH_TOKEN setup-token, which bills operator@example.com, while
# its stored login is operator@example.com. So the hub polled the wrong account's
# meter for two weeks while the one that mattered read $23.8K of $35K monthly
# extra usage and nothing anywhere said so. A box may hold more than one login;
# the unit of a meter is an ACCOUNT, so the unit of a poll is a login.
#
#   EXTRA_USAGE_LOGINS='label=/path/to/config-dir,label=/path/to/other'
#
# is the override. With it unset the list comes from catalog/cost-accounts.json
# (every account whose login.box is THIS box), and with no entry there it falls
# back to this box's own /root/.claude labelled by the box id — byte-identical
# to what every box did before this change. Each login is refreshed
# (bin/oauth-refresh.sh, per directory) before it is read.
#
# WHAT THE METER CAN AND CANNOT SAY. Only a FULL login (a .credentials.json with
# a refreshToken) can read this endpoint; a setup-token (sk-ant-oat01…) answers
# 429 permanently and a 1-year box token has no login at all. Those boxes now
# record a row with status=no-login instead of nothing, because a silent absence
# and a quiet week are the same number and must not read the same. And the
# dollar meter only MOVES once the account is past its weekly credits: before
# that, spend is subscription credits and the meter honestly reads $0. A $0
# reading is not "no spend" — see state=credits-covered in bin/cost-reconcile.sh.
#
# Why (2026-08-24, the operator): "can we track when it's extra usage stuff or part of
# the credits — that's where it makes a difference." Included usage is sunk
# subscription cost; overage is an invoice. The endpoint exposes both the
# limit utilization (5h session + weekly) and the extra-usage dollar meter,
# so the cash/covered split is directly observable.
#
# Output per login: logs/extra-usage[-<label>].csv (one row per poll; the box's
# OWN login keeps the unsuffixed path every other reader already knows) and one
# extra_usage_snapshots row in the harness-jobs DB. ALERTs:
#   - once per weekly window when the account ENTERS overage
#     (weekly 100% + extra usage enabled = every call now bills cash)
#   - once per day when same-day cash delta exceeds $EXTRA_USAGE_DAY_ALERT (default 1300)
#   - every 6h while the account is at >=98% of its extra-usage cap, or has hit
#     its spend limit (folded in from the project-6 stopgap, 2026-09-14)
#   - once per outage when the meter itself has stopped (no reading for
#     EXTRA_USAGE_STALE_HOURS, default 2; BH-9068)
#   - once per day when EXTRA_USAGE_ERROR_STREAK (default 3) polls in a row
#     came back status=error (BH-3985)
#   - once per day when the meter has not moved for 12h while the account was
#     in overage the whole time (the only state in which it moves) and its
#     priced cost rows billed more than EXTRA_USAGE_FLAT_MIN_USD (default 5)
#     over those 12h (BH-3985)
#
# Kill: EXTRA_USAGE_TRACK=0 in env/global.env, or the settings row
# switch.extra-usage-track-off[.<box>] (with no row, flags/extra-usage-track-off).
set -uo pipefail
# Box id from argv (the cron line passes it, like watchdog-ping.sh), falling
# back to the hostname so a cron line that forgets the argument still produces
# an attributable row rather than an anonymous one.
BOX="${1:-$(hostname -s 2>/dev/null || echo unknown)}"
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
# global.env is sourced HERE because cron does not. Every box's cron invokes it
# directly with no BASH_ENV and no `. env/global.env`, so before this line an
# EXTRA_USAGE_DAY_ALERT set in an env file reached nothing — the value would sit
# in a config file looking authoritative while the running script used the code
# default. Every other env-reading script in bin/ already does this; this one was
# the gap. Same shape as the inert billing_mode column: config that cannot
# possibly take effect, and nothing anywhere reports that it didn't.
# `+u` around the source, and it is NOT cosmetic. Under `set -u` an unbound
# reference anywhere inside global.env is FATAL regardless of -e, and the
# 2>/dev/null swallows the message: the tracker would exit non-zero with no CSV
# row, no log line and no alert. The hourly meter just stops, and the headline
# overage number goes quietly stale -- a silent death in the one script whose
# job is noticing money. Verified: a fixture global.env containing BAD=$UNSET_VAR
# kills the old form (rc=127, zero output) and is survived by this one.
set -a +u; . "$HENV/global.env" 2>/dev/null; set +a -u

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-extra-usage-track
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off extra-usage-track.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit extra-usage-track
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    extra-usage-track
# BH-2433: the kill switch below is read through lane_switch, so a settings
# row switch.<name>[.<box>] settles it before the file does.
# shellcheck source=lib/lane-switch.sh
. "${HARNESS:-/root/harness}/bin/lib/lane-switch.sh" 2>/dev/null || true
command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "${HARNESS:-/root/harness}/flags/$1" ]; }   # no lib: the file, as before
# The kill switch, read AFTER global.env so it can live there. Off means the
# fleet is spending blind, which is why it is one line and not a policy.
[ "${EXTRA_USAGE_TRACK:-1}" = "0" ] && exit 0
lane_switch extra-usage-track-off file && exit 0
# DEFAULT 1300, NOT 100 (2026-08-24). Normal orchestrator burn is ~$600-670/day,
# so a $100/day alert fired every single day: the alarm that always rings is not
# an alarm, and the real anomaly arrives into a mailbox nobody reads any more.
# 1300 is ~2x normal, which is a genuine anomaly rather than a Tuesday.
THRESH="${EXTRA_USAGE_DAY_ALERT:-1300}"
CAP_PCT="${EXTRA_USAGE_CAP_ALERT_PCT:-98}"
CAP_DEDUPE_S="${EXTRA_USAGE_CAP_ALERT_DEDUPE_S:-21600}"
ACCOUNTS_FILE="${COST_ACCOUNTS_FILE:-$H/catalog/cost-accounts.json}"
# The box's OWN login. A login at this path keeps every legacy file name
# (logs/extra-usage.csv, state/extra-usage-last.json, the alert markers), so
# bin/cost-rollup.sh and bin/quota-poll.sh read exactly what they read before.
DEFAULT_DIR="${CLAUDE_CONFIG_DIR:-/root/.claude}"
# 11 columns since 2026-09-14: extra_limit_usd + extra_pct (the cap alert reads
# them) and status (ok | no-login | error) are APPENDED, so every existing
# reader's column positions are untouched — logs/extra-usage.csv is parsed by
# name in cost-rollup.sh and by position 6 here.
HDR='ts,session_pct,weekly_pct,weekly_resets_at,extra_enabled,extra_used_usd,spend_limit_reached,in_overage,extra_limit_usd,extra_pct,status'
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
mkdir -p "$H/state" "$H/logs" "$H/flags" 2>/dev/null

# ── WHICH LOGINS DOES THIS BOX HOLD? ────────────────────────────────────────
# Env override first (one box, one operator decision), then the registry, then
# today's behaviour. The fallback is what keeps a box the catalog has never
# heard of polling exactly as it does now instead of polling nothing.
resolve_logins() {
  if [ -n "${EXTRA_USAGE_LOGINS:-}" ]; then printf '%s' "$EXTRA_USAGE_LOGINS"; return 0; fi
  local from_catalog=""
  if [ -r "$ACCOUNTS_FILE" ] && command -v python3 >/dev/null 2>&1; then
    from_catalog=$(EU_BOX="$BOX" python3 - "$ACCOUNTS_FILE" 2>/dev/null <<'PYEOF'
import json, os, sys
box = os.environ.get("EU_BOX", "")
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(0)
out = []
for label, a in sorted((d.get("accounts") or {}).items()):
    login = (a or {}).get("login") or {}
    if login.get("box") == box and login.get("config_dir"):
        out.append("%s=%s" % (label, login["config_dir"]))
print(",".join(out))
PYEOF
)
  fi
  if [ -n "$from_catalog" ]; then printf '%s' "$from_catalog"; return 0; fi
  printf '%s=%s' "$BOX" "$DEFAULT_DIR"
}

# ── ONE ALERT PATH ──────────────────────────────────────────────────────────
# lane-alert.sh appends the ALERTS.log line AND posts the fleet_alert beat the
# 10-min medic reads; without it the line sits in a file nothing polls. Falls
# back to the raw append so an old box still alerts.
#
# EVERY ALERT HERE CARRIES ITS OWN ID (2026-09-15), because this script is where
# the alert state machine came from: see the overage block below for the marker
# bug that put 68 identical lines into one day of ALERTS.log. An id per ACCOUNT
# (not per poll, not per resets_at) is the condition's real name, and a
# condition that ends gets alert_clear — one resolve, once.
alert() { # alert <id> <severity> <text>
  local id="$1" sev="$2"; shift 2
  if [ -x "$H/bin/lane-alert.sh" ]; then
    "$H/bin/lane-alert.sh" --id "$id" --severity "$sev" extra-usage "$*" >/dev/null 2>&1 && return 0
  fi
  echo "$(STAMP) [$BOX] $*" >> "$H/logs/ALERTS.log"
}
# The other half of a state machine. Silent when the id was never firing, so
# calling it on every healthy poll costs nothing and says nothing.
alert_clear() { # alert_clear <id> <text>
  local id="$1"; shift
  [ -x "$H/bin/lane-alert.sh" ] || return 0
  "$H/bin/lane-alert.sh" --resolve --id "$id" extra-usage "$*" >/dev/null 2>&1 || true
}

# ── ONE LOGIN ───────────────────────────────────────────────────────────────
poll_login() { # poll_login <label> <config-dir>
  local LABEL="$1" CDIR="$2" SUF CSV MARK ERRF SNAP UNAVAIL ROW RC=0
  case "$CDIR" in "$DEFAULT_DIR") SUF="" ;; *) SUF="-$LABEL" ;; esac
  CSV="$H/logs/extra-usage$SUF.csv"
  MARK="$H/state/extra-usage-alert$SUF.marker"
  # STDERR TO A FILE. The endpoint's refusal arrives on stderr — urllib raises,
  # and the traceback carries the reason. Discarding it left the classifier below
  # with nothing to classify FROM. Per-login, because two logins failing for two
  # different reasons in the same run must not be classified from one file.
  ERRF="$H/state/extra-usage-lasterr$SUF"
  UNAVAIL="$H/state/extra-usage-unavailable$SUF"
  # RAW-RESPONSE SNAPSHOT for account routing (2026-09-06, docs/ACCOUNT-ROUTING.md).
  # bin/quota-poll.sh must NOT poll this account a second time — the usage
  # endpoint's rate limit is per account and a second poller costs this tracker its
  # sample — so it derives state/quota/default.json from the file written below.
  if [ -z "$SUF" ]; then SNAP="${EXTRA_USAGE_SNAPSHOT:-$H/state/extra-usage-last.json}"
  else SNAP="$H/state/extra-usage-last$SUF.json"; fi

  if [ ! -f "$CSV" ]; then echo "$HDR" > "$CSV"
  else
    # An 8-column header from before 2026-09-14 gets the three new names, in
    # place and once: DictReader keys by name, and a header that does not name
    # every column it carries is how a reader silently drops one.
    case "$(head -1 "$CSV" 2>/dev/null)" in *,status) : ;;
      ts,*)
        # logs/extra-usage.csv is +a once the box is armed, and `sed -i` writes
        # a temp file and renames it over the original — EPERM. So release,
        # migrate, rearm, under harden-state.lock. A group redirect, not
        # `exec 8>`, so a missing lock dir skips the wrap instead of killing the
        # function; the mkdir is what keeps it from ever coming to that.
        # Per-login extra-usage-<label>.csv files are out-of-set: those two
        # calls answer rc 2 with one stderr line, once per file ever. Left
        # visible on purpose — a silenced release failure on the real ledger is
        # how this lane would go quiet.
        mkdir -p "$H/locks" 2>/dev/null
        {
          flock -w 10 8 || true
          [ -x "$H/bin/harden-state.sh" ] && "$H"/bin/harden-state.sh --release "$CSV"
          sed -i '1s/$/,extra_limit_usd,extra_pct,status/' "$CSV" 2>/dev/null || true
          [ -x "$H/bin/harden-state.sh" ] && "$H"/bin/harden-state.sh --rearm "$CSV"
        } 8>"$H/locks/harden-state.lock"
        ;;
    esac
  fi

  # KEEP THE FULL LOGIN ALIVE (2026-09-07). credentials.json is the only credential
  # that can read this endpoint, and nothing else on a box ever refreshes it (every
  # lane runs on the env setup-token). Refresh it here when expired/near expiry;
  # see bin/oauth-refresh.sh. Failure is logged there and falls through to the
  # classifier below, which is where a dead login gets reported.
  "$H/bin/oauth-refresh.sh" "$CDIR" "$LABEL" >/dev/null 2>&1 || true

  # THE ENV TOKEN IS A FALLBACK FOR THE BOX'S OWN LOGIN ONLY. For a named extra
  # login it would be an outright lie: CLAUDE_CODE_OAUTH_TOKEN belongs to some
  # other account, and reading its meter under this label is exactly the
  # mislabelling this whole change exists to end.
  local ALLOW_ENV=0
  [ -z "$SUF" ] && ALLOW_ENV=1
  ROW=$(EXTRA_USAGE_CRED_FILE="$CDIR/.credentials.json" EXTRA_USAGE_ALLOW_ENV_TOKEN="$ALLOW_ENV" \
        EXTRA_USAGE_SNAPSHOT="$SNAP" python3 - 2>"$ERRF" <<'PYEOF'
import json, os, urllib.error, urllib.request

# EVERY CREDENTIAL THIS LOGIN HAS, TRIED IN ORDER — not just the first one found.
#
# 2026-08-29: this meter died silently on 2026-08-24T19:58Z and stayed dead for
# five days. The cause was sourcing global.env, which was right, and which also
# put CLAUDE_CODE_OAUTH_TOKEN into the environment, which this code preferred
# unconditionally. That env token answers the usage endpoint HTTP 429 Too Many
# Requests — permanently and deterministically, not transiently: reproduced
# minutes apart while the credentials.json token answered 200 in the same
# second. A tracker with two credentials must not be able to die holding the
# one that doesn't work.
#
# credentials.json first because it is the FULL LOGIN, and a full login's
# accessToken is the only thing that can read this endpoint at all (a
# setup-token gets 429, a box token 403 user:profile). The env token is the
# fallback, not the preference, and only for this box's own login.
cands = []
try:
    tok = json.load(open(os.environ["EXTRA_USAGE_CRED_FILE"]))['claudeAiOauth']['accessToken']
    if tok:
        cands.append(('credentials.json', tok))
except Exception:
    pass
env_tok = os.environ.get('CLAUDE_CODE_OAUTH_TOKEN') if os.environ.get('EXTRA_USAGE_ALLOW_ENV_TOKEN') == '1' else None
if env_tok and not any(t == env_tok for _, t in cands):
    cands.append(('CLAUDE_CODE_OAUTH_TOKEN', env_tok))
if not cands:
    raise SystemExit('NO_TOKEN')

d = None
errs = []
for src, tok in cands:
    req = urllib.request.Request(os.environ.get('OAUTH_USAGE_URL', 'https://api.anthropic.com/api/oauth/usage'),
        headers={'Authorization': f'Bearer {tok}', 'anthropic-beta': 'oauth-2025-04-20'})
    try:
        d = json.loads(urllib.request.urlopen(req, timeout=20).read())
        break
    except urllib.error.HTTPError as e:
        # The vendor's own body after str(e), which keeps the 'HTTP Error NNN'
        # the classifier below matches on (BH-3985: error rows were blank).
        try:
            vb = e.read(1500).decode('utf-8', 'replace')
        except Exception:
            vb = ''
        errs.append(f'{src}: {e} :: ' + ' '.join(vb.split()))
    except Exception as e:
        errs.append(f'{src}: {e}')
if d is None:
    # The classifier below reads THIS run's stderr and nothing else, so every
    # candidate's own refusal has to be on it — otherwise a 429 on the token we
    # happened to try first would name the outcome for a login whose real
    # problem was a 403 on the only token it has.
    raise SystemExit('ALL_TOKENS_FAILED :: ' + ' | '.join(errs))

# Snapshot the raw response for bin/quota-poll.sh (see EXTRA_USAGE_SNAPSHOT
# above). The payload is utilization numbers and reset timestamps — no token, no
# credential — and the write is best-effort: this meter's job is the CSV row and
# the alerts, and a snapshot failure must never cost either of them.
try:
    import tempfile
    _snap = os.environ.get('EXTRA_USAGE_SNAPSHOT') or '/root/harness/state/extra-usage-last.json'
    os.makedirs(os.path.dirname(_snap), exist_ok=True)
    _fd, _tmp = tempfile.mkstemp(dir=os.path.dirname(_snap), prefix='.extra-usage-last.')
    with os.fdopen(_fd, 'w') as _fh:
        json.dump(d, _fh)
    os.chmod(_tmp, 0o600)
    os.replace(_tmp, _snap)
except Exception:
    pass

import datetime
ts = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
five = d.get('five_hour') or {}
week = d.get('seven_day') or {}
ex = d.get('extra_usage') or {}
sess = five.get('utilization') or 0
wk = week.get('utilization') or 0
resets = week.get('resets_at') or ''
enabled = bool(ex.get('is_enabled'))
dec = 10 ** (ex.get('decimal_places') or 2)
used_usd = (ex.get('used_credits') or 0) / dec
limit_usd = (ex.get('monthly_limit') or 0) / dec
ex_pct = ex.get('utilization') or 0
slr = bool(ex.get('spend_limit_reached'))
overage = enabled and wk >= 100 and not slr
print(f"{ts},{sess:.0f},{wk:.0f},{resets},{int(enabled)},{used_usd:.2f},{int(slr)},{int(overage)},{limit_usd:.2f},{ex_pct:.0f},ok")
PYEOF
) || RC=1

  if [ "$RC" != 0 ] || [ -z "$ROW" ]; then
    # A NAMED failure, not a generic one. The 403 is a permanent capability gap
    # (this token can never read this endpoint), while a timeout is transient —
    # collapsing them into "poll failed" is what let 8 boxes look like the one
    # genuinely-absent box.
    #
    # CLASSIFY FROM THIS RUN'S STDERR, AND NOTHING ELSE. The shipped version read
    # $ROW plus a tail of agent-rules.log and could never fire: ROW captures
    # STDOUT, a 403 raises onto STDERR, and the log tail only ever contained
    # these strings because THIS BRANCH writes them. A shared, mutable, sticky
    # log is the wrong evidence twice over — another lane's 403 would misclassify
    # this one, and once fired, its own message would make a later genuine
    # timeout read as a 403.
    local STATUS=no-login WHY
    if grep -qiE 'user:profile|scope requirement|\b403\b|HTTP Error 403' "$ERRF" 2>/dev/null; then
      WHY='token lacks user:profile scope'
      echo "$(STAMP) extra-usage-track[$LABEL]: usage endpoint refused this token (403, needs user:profile) — this account CANNOT self-report overage; caps are the only bound" >> "$H/logs/agent-rules.log"
    elif grep -q 'HTTP Error 429' "$ERRF" 2>/dev/null; then
      # ITS OWN CLASS, and deliberately NOT filed under "transient". A 429 here is
      # what a credential that is not allowed to read this endpoint looks like
      # from the outside — it held for five days straight on one token while
      # another token answered 200 in the same second.
      WHY='usage endpoint answered 429 for every credential on this login'
      echo "$(STAMP) extra-usage-track[$LABEL]: every credential answered 429 — a setup-token cannot read this endpoint; only a full login can" >> "$H/logs/agent-rules.log"
    elif grep -q 'NO_TOKEN' "$ERRF" 2>/dev/null; then
      # THE THIRD NOTHING. A missing credential is a PERMANENT config gap, not a
      # transient failure — the same conflation this branch exists to end.
      WHY="no credential at $CDIR (and no env-token fallback for a named login)"
      echo "$(STAMP) extra-usage-track[$LABEL]: no credential available — this account CANNOT self-report overage until one is provisioned" >> "$H/logs/agent-rules.log"
    else
      STATUS=error; WHY='poll failed (transient?)'
      echo "$(STAMP) extra-usage-track[$LABEL]: usage endpoint poll failed" >> "$H/logs/agent-rules.log"
    fi
    printf '%s\n' "$WHY" > "$UNAVAIL"
    # A ROW, NOT SILENCE (2026-09-14). Six boxes hold a credential that can never
    # read this endpoint, and until now they reported that by writing nothing —
    # indistinguishable in the DB from a box whose cron is dead. The row carries
    # no numbers (a failed poll is not a $0 meter) and says why in one word.
    local FTS ERRBODY; FTS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    ERRBODY=$(err_body "$ERRF")
    echo "$FTS,,,,,,,,,,$STATUS" >> "$CSV"
    push_row "$LABEL" "$FTS" "" "" "" "" "" "" "" "" "" "$STATUS" "$ERRBODY"
    stale_alert "$LABEL" "$CSV" "$UNAVAIL" "$SUF"
    [ "$STATUS" = error ] && error_streak_alert "$LABEL" "$CSV" "$SUF" "$ERRBODY"
    return 0
  fi

  rm -f "$UNAVAIL" 2>/dev/null
  # The incident's stale flag goes with it: a meter that recovered at noon must
  # be able to alert again if it dies at six (BH-9068).
  rm -f "$H/flags/alerted-extra-usage-stale$SUF" 2>/dev/null
  # ...and so does the alert itself: a meter that is reading again is a
  # condition that ENDED, and saying so once is the other half of saying it
  # broke. Silent when it was never down.
  alert_clear "extra-usage-meter-$LABEL" "EXTRA-USAGE METER [$LABEL]: polling again — the account's overage number is live."
  alert_clear "extra-usage-errors-$LABEL" "EXTRA-USAGE METER ERRORS [$LABEL]: the meter answered again."
  echo "$ROW" >> "$CSV"
  flat_local "$LABEL" "$CSV" "$SUF"
  # Only a login that polled ok this run is cross-checked (xcheck_accounts):
  # a meter this box could not read is not a meter it can compare.
  _OK_LABELS="$_OK_LABELS $LABEL"

  local TS SESS WK RESETS ENABLED USED SLR OVERAGE LIMIT EXPCT ST
  IFS=, read -r TS SESS WK RESETS ENABLED USED SLR OVERAGE LIMIT EXPCT ST <<< "$ROW"
  # Push AFTER the CSV, fail-open: the file is still written first and is still
  # what the alert arithmetic below reads, so a worker outage costs a DB row and
  # nothing else.
  push_row "$LABEL" "$TS" "$SESS" "$WK" "$RESETS" "$ENABLED" "$USED" "$SLR" "$OVERAGE" "$LIMIT" "$EXPCT" "$ST"

  local TODAY FIRST DELTA
  TODAY=$(date -u +%F)

  # Alert 1: in overage. ONE alert when it starts, ONE resolve when it ends.
  #
  # THE BUG THIS REPLACES (2026-09-15). The dedupe was a marker keyed
  # `overage:$RESETS`, and resets_at comes back from the endpoint with
  # MICROSECONDS that move on every single poll — 2026-09-17T04:00:00.128234
  # one quarter hour, 2026-09-17T03:59:59.667026 the next. So the grep never
  # matched the marker it had just written, and "once per weekly window" fired
  # every 15 minutes for as long as the account stayed over: 68 identical lines
  # in the 24h that got this state machine written, all about one account in one
  # overage. The id is the ACCOUNT, which is what the condition is actually
  # about; resets_at is printed to the second so the text stops churning too.
  local OVID="extra-usage-overage-$LABEL"
  if [ "$OVERAGE" = "1" ]; then
    alert "$OVID" critical "EXTRA-USAGE [$LABEL]: account is in overage — weekly limit 100%, extra usage enabled, every Claude call bills CASH at API rates until ${RESETS%%.*}. Meter at \$$USED. Options: wait for reset, set a spend cap on the account, or accept the burn."
  else
    alert_clear "$OVID" "EXTRA-USAGE [$LABEL]: out of overage — weekly utilization ${WK}%, meter \$$USED. Calls are back on subscription credits."
  fi

  # Alert 2: at or past the extra-usage CAP (every 6h while it holds). Folded in
  # from /root/orchestrator/bin/project-6-usage-poll.sh, the 2026-09-14 stopgap
  # that read the project-6 meter this script could not. At the cap every lane
  # on the account stops, so this is an outage warning, not a billing note.
  #
  # The 6h re-nag is now the state machine's reminder interval rather than a
  # marker file's mtime. EXTRA_USAGE_CAP_ALERT_DEDUPE_S is passed through as
  # ALERT_REMINDER_S for this one call, so a box that had set it keeps exactly
  # the cadence it configured instead of the setting quietly going inert.
  local CAPID="extra-usage-cap-$LABEL"
  if [ "$SLR" = "1" ] || { [ -n "$EXPCT" ] && [ "${EXPCT%%.*}" -ge "$CAP_PCT" ] 2>/dev/null; }; then
    ALERT_REMINDER_S="$CAP_DEDUPE_S" \
      alert "$CAPID" critical "EXTRA-USAGE CAP [$LABEL]: \$$USED of \$$LIMIT (${EXPCT}%, spend_limit_reached=$SLR). At the cap every lane billing this account stops. Raise the monthly limit at claude.ai/settings/usage, move the lanes, or pause the wave."
  else
    alert_clear "$CAPID" "EXTRA-USAGE CAP [$LABEL]: back under the cap — \$$USED of \$$LIMIT (${EXPCT}%). Lanes on this account are not blocked."
  fi

  # Alert 3: same-day cash delta past threshold (once per day)
  FIRST=$(grep "^$TODAY" "$CSV" | cut -d, -f6 | grep -v '^$' | head -1)
  if [ -n "$FIRST" ] && ! grep -q "delta:$TODAY" "$MARK" 2>/dev/null; then
    DELTA=$(python3 -c "print(f'{$USED - $FIRST:.2f}')")
    if python3 -c "exit(0 if $DELTA > $THRESH else 1)"; then
      echo "delta:$TODAY" >> "$MARK"
      alert "extra-usage-delta-$LABEL-$TODAY" warn "EXTRA-USAGE [$LABEL]: \$$DELTA cash overage billed so far today (meter \$$USED, threshold \$$THRESH/day)."
    fi
  fi

  # Daily INFO line — the burn stays VISIBLE without being alarming. Raising the
  # alert threshold to ~2x normal removes the daily noise, but it would also make
  # a normal $600 day silent, and "no alert" is not the same as "someone looked".
  # This is the seeing half: agent-rules.log, not ALERTS.log, once per day.
  if [ -n "$FIRST" ] && ! grep -q "info:$TODAY" "$MARK" 2>/dev/null; then
    DELTA=$(python3 -c "print(f'{$USED - $FIRST:.2f}')" 2>/dev/null)
    # Only once the day has enough samples to mean anything — a delta computed
    # from a single row is always $0.00 and would read as a free day.
    if [ -n "$DELTA" ] && [ "$(grep -c "^$TODAY" "$CSV")" -ge 3 ]; then
      echo "info:$TODAY" >> "$MARK"
      echo "$(STAMP) extra-usage-track[$LABEL]: \$$DELTA billed so far today (meter \$$USED, alert at \$$THRESH)" >> "$H/logs/agent-rules.log"
    fi
  fi
}

# ── Push the poll to the harness-jobs metrics ledger (2026-08-29) ────────────
# jobs-client is sourced per call rather than at the top because global.env
# (already sourced above) is what carries HARNESS_SECRET. `command -v` before
# the call, not just `|| true`: bin/ syncs as a whole but not atomically with
# every other box, so a NEWER producer can land beside an OLDER jobs-client.sh
# that has no metric_* helper — and a missing function is "command not found"
# on stderr every quarter hour, which is noise in exactly the logs this wave
# exists to make readable.
push_row() { # push_row <label> <ts> <sess> <wk> <resets> <enabled> <usd> <slr> <overage> <limit> <pct> <status> [error_body]
  [ -f "$H/bin/jobs-client.sh" ] || return 0
  ( # shellcheck source=/dev/null
    . "$H/bin/jobs-client.sh"
    command -v metric_extra_usage >/dev/null 2>&1 || exit 0
    metric_extra_usage "$@" ) >/dev/null 2>&1 || true
}

# ── FAIL LOUD, ONCE THE METER IS ACTUALLY STALE ─────────────────────────────
# Everything on the failure path writes to agent-rules.log, which is a run log:
# 120 hourly failures went into it between 2026-08-24 and 2026-08-29 and not one
# of them reached anybody. A question asked into your own run log is
# indistinguishable from silence.
#
# NOT one alert per failed poll — that is the noise that gets an alert channel
# ignored, and a single blip is genuinely not news. The alarm is on the thing
# that matters: the METER HAS STOPPED. One ALERTS line per outage per label,
# once the last SUCCESSFUL row is older than EXTRA_USAGE_STALE_HOURS (BH-9068).
# The flag has no date in its name: an outage that runs past 00:00Z is still one
# incident. The first ok poll removes it, so the next outage alerts again.
stale_alert() { # stale_alert <label> <csv> <unavail-file> <suffix>
  local LABEL="$1" CSV="$2" UNAVAIL="$3" SUF="$4" STALE_H SFLAG LASTTS LASTEPOCH NOWEPOCH AGE_H=99999
  # Knob row: EXTRA_USAGE_STALE_HOURS in catalog/lanes.d/extra-usage-track.json.
  # 2 is its documented fallback; 0 or junk falls back to it.
  IFS=$'\t' read -r STALE_H _ <<< "$(xc_knob "${EXTRA_USAGE_STALE_HOURS:-}" 2)"
  [ "$STALE_H" -ge 1 ] 2>/dev/null || STALE_H=2
  SFLAG="$H/flags/alerted-extra-usage-stale$SUF"
  [ -f "$SFLAG" ] && return 0
  # The last row with a METER READING on it, not the last row: since 2026-09-14
  # a failed poll writes a row too, and measuring staleness from those would
  # make a permanently dead login look freshly polled forever.
  LASTTS=$(awk -F, 'NR>1 && $6 != "" {t=$1} END{print t}' "$CSV" 2>/dev/null)
  if [ -n "$LASTTS" ]; then
    # `date`, NOT python3. The staleness check runs on the failure path, and on
    # that path the most likely reason the poll failed is that the interpreter it
    # used could not run — measuring "how long has this been broken" with the
    # broken thing gives 99999 hours and a daily alert on a meter that is fine.
    LASTEPOCH=$(date -u -d "$LASTTS" +%s 2>/dev/null || echo "")
    # EXTRA_USAGE_NOW_EPOCH is a test seam: it pins the clock for the age only.
    NOWEPOCH="${EXTRA_USAGE_NOW_EPOCH:-$(date -u +%s)}"
    [ -n "$LASTEPOCH" ] && AGE_H=$(( (NOWEPOCH - LASTEPOCH) / 3600 ))
  fi
  case "$AGE_H" in ''|*[!0-9]*) AGE_H=99999 ;; esac
  [ "$AGE_H" -ge "$STALE_H" ] || return 0
  # The flag is written only after the alert went out: a failed alert call leaves
  # no flag, so the next poll tries again.
  alert "extra-usage-meter-$LABEL" critical "EXTRA-USAGE METER DOWN [$LABEL]: no successful poll for ${AGE_H}h (reason: $(tr -d '\n' < "$UNAVAIL" 2>/dev/null)). The credits-vs-cash overage number is going stale — nothing is watching the bill on this account. Fix: bin/extra-usage-track.sh $BOX by hand and read $(basename "$UNAVAIL" | sed 's/unavailable/lasterr/')." \
    && touch "$SFLAG" 2>/dev/null
  return 0
}

# ── METER vs COST ROWS (BH-1915, BH-167.2) ─────────────────────────────────
# The meter says what the vendor billed; cost_rows say what our own lanes
# recorded spending. The worker lines the two up per account
# (GET /api/metrics/account-usage, contract in worker/jobs/src/lib/account-usage.js)
# and this reads that answer for each login polled ok THIS run. One alert per
# account when the gap is over the knob, one resolve when it is back within.
#
# Knobs are read here, after lane_env_apply, so a settings row reaches them.
# Integers only (the registry types them int); anything else falls back to the
# default and the rejected value is named in the per-run log line.
xc_knob() { # xc_knob <raw> <default> -> "<value>\t<source>"
  local raw="$1" def="$2"
  if [ -z "$raw" ]; then printf '%s\t%s' "$def" "code default"; return; fi
  case "$raw" in
    ''|*[!0-9]*) printf '%s\t%s' "$def" "code default (rejected '$raw' from env/settings)" ;;
    *) printf '%s\t%s' "$((10#$raw))" "env/settings" ;;
  esac
}
IFS=$'\t' read -r XC_GAP XC_GAP_SRC <<< "$(xc_knob "${EXTRA_USAGE_XCHECK_GAP_PCT:-}" 10)"
IFS=$'\t' read -r XC_MIN XC_MIN_SRC <<< "$(xc_knob "${EXTRA_USAGE_XCHECK_MIN_USD:-}" 1)"

# ── A METER THAT FAILS OR FREEZES IS NEWS (BH-3985) ─────────────────────────
# stale_alert only fires hours after the last READING, so a meter that answered
# `error` all afternoon and a meter stuck on one value while the account kept
# spending both stayed quiet. Each of these says so once per day per label
# (a per-day flag, touched only when the alert went
# out), and resolves once when the meter reads again / moves again.
IFS=$'\t' read -r EU_STREAK EU_STREAK_SRC <<< "$(xc_knob "${EXTRA_USAGE_ERROR_STREAK:-}" 3)"
if [ "$EU_STREAK" -lt 1 ]; then EU_STREAK=3; EU_STREAK_SRC="code default (rejected '${EXTRA_USAGE_ERROR_STREAK:-}' from env/settings)"; fi
IFS=$'\t' read -r EU_FLAT_MIN EU_FLAT_MIN_SRC <<< "$(xc_knob "${EXTRA_USAGE_FLAT_MIN_USD:-}" 5)"
EU_FLAT_S=43200   # 12h: the account-usage window the priced-row sum comes from

# The vendor's answer from this run's stderr, as one line with every credential
# scrubbed out of it: it goes into a DB row and an alert. sed, not python3: on
# this path python3 may be the thing that broke.
err_body() { # err_body <stderr-file>
  local line
  line=$(grep -E 'ALL_TOKENS_FAILED ::|NO_TOKEN' "$1" 2>/dev/null | tail -1)
  [ -n "$line" ] || line=$(grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -1)
  printf '%s' "$line" | tr '\r\n\t' '   ' \
    | sed -E 's/([Bb]earer)[[:space:]]+[^[:space:]"]+/\1 [redacted]/g; s/sk-ant-[A-Za-z0-9_-]+/sk-ant-[redacted]/g' \
    | cut -c1-1500
}

# N `error` rows at the END of the CSV. A no-login or ok row ends the streak:
# no-login is a credential gap stale_alert already owns.
error_streak_alert() { # error_streak_alert <label> <csv> <suffix> <error-body>
  local LABEL="$1" CSV="$2" SUF="$3" EB="$4" N SINCE EFLAG
  IFS=$'\t' read -r N SINCE <<< "$(awk -F, 'NR>1 { if ($11 == "error") { if (n == 0) f = $1; n++ } else n = 0 }
                                             END { printf "%d\t%s", n, (n ? f : "") }' "$CSV" 2>/dev/null)"
  case "$N" in ''|*[!0-9]*) return 0 ;; esac
  [ "$N" -ge "$EU_STREAK" ] || return 0
  EFLAG="$H/flags/alerted-extra-usage-errors$SUF-$(date -u +%Y%m%d)"
  [ -f "$EFLAG" ] && return 0
  alert "extra-usage-errors-$LABEL" warn "EXTRA-USAGE METER ERRORS [$LABEL]: $N failed polls in a row (status=error) since $SINCE. Last vendor answer: ${EB:0:300}. Read $H/state/extra-usage-lasterr$SUF and run bin/extra-usage-track.sh $BOX by hand." \
    && touch "$EFLAG" 2>/dev/null
  return 0
}

# Step 1 of the flat check, local and offline: has this login's meter held one
# value across the last 12h of READINGS (failed polls carry no value) while
# every one of those readings was IN OVERAGE (col 8: extra enabled, weekly
# >= 100%, spend limit not reached)? The meter only moves past the weekly
# credits, so a still meter inside them is the normal state, not a failure:
# the same doctrine as cost-anchored's fully_overage. Flat logins queue for
# flat_accounts, which asks the worker what the account billed over those 12h.
# A meter that moved, or one that is still only because it is not in overage,
# resolves a firing flat alert here; the latter says so in the run log.
_FLAT=""
flat_local() { # flat_local <label> <csv> <suffix>
  local LABEL="$1" CSV="$2" SUF="$3" OUT V SINCE AGE
  OUT=$(EU_FLAT_S="$EU_FLAT_S" python3 - "$CSV" 2>/dev/null <<'PYEOF'
import csv, datetime, os, sys
rows = []
with open(sys.argv[1]) as f:
    for r in csv.reader(f):
        if len(r) < 6 or r[0] == "ts" or r[5] == "":
            continue
        try:
            ov = len(r) > 7 and r[7].strip() == "1"
            rows.append((datetime.datetime.strptime(r[0], "%Y-%m-%dT%H:%M:%SZ"), float(r[5]), r[0], ov))
        except ValueError:
            continue
if not rows:
    raise SystemExit(0)
rows.sort()
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
need = int(os.environ["EU_FLAT_S"])
value, since = rows[-1][1], rows[-1][2]
start = rows[-1][0]
ostart = osince = None
inov = True
for t, v, raw, ov in reversed(rows):
    if abs(v - value) > 1e-9:
        break
    start, since = t, raw
    inov = inov and ov
    if inov:
        ostart, osince = t, raw
age = (now - start).total_seconds()
if age < need:
    raise SystemExit(0)
oage = (now - ostart).total_seconds() if ostart is not None else 0
if oage >= need:
    print("flat|%.2f|%s|%d" % (value, osince, oage // 3600))
else:
    print("credits|%.2f|%s|%d" % (value, since, age // 3600))
PYEOF
)
  case "$OUT" in
    flat\|*) _FLAT="$_FLAT $LABEL|$SUF|${OUT#flat|}" ;;
    credits\|*)
      IFS='|' read -r _ V SINCE AGE <<< "$OUT"
      echo "$(STAMP) extra-usage-track flat[$LABEL]: meter flat at \$$V since $SINCE (${AGE}h), no alert: not in overage for the last 12h (inside weekly credits, extra usage off or spend limit reached), the meter is not expected to move" >> "$H/logs/agent-rules.log"
      alert_clear "extra-usage-flat-$LABEL" "EXTRA-USAGE METER FLAT [$LABEL]: the account is not in overage, so a still meter is expected." ;;
    *) alert_clear "extra-usage-flat-$LABEL" "EXTRA-USAGE METER FLAT [$LABEL]: the meter is moving again." ;;
  esac
}

# Step 2: one account-usage read for every flat login. Fires only on a numeric
# usd over the knob; a failed read, a missing label or usd null (nothing priced)
# never fires and never clears, and the run log says which (absent is not $0).
flat_accounts() {
  [ -n "${_FLAT// /}" ] || return 0
  local BODY RC ITEM LABEL SUF V SINCE AGE USD FFLAG WHY
  BODY=$( [ -f "$H/bin/jobs-client.sh" ] || exit 1
          # shellcheck source=/dev/null
          . "$H/bin/jobs-client.sh"
          command -v _jobs_req >/dev/null 2>&1 || exit 1
          _jobs_req GET "/api/metrics/account-usage?window=12h" ) 2>/dev/null
  RC=$?
  if [ "$RC" != 0 ] || ! printf '%s' "$BODY" | jq -e 'type=="object" and (.accounts|type=="array")' >/dev/null 2>&1; then
    WHY="account-usage read unusable ($([ "$RC" != 0 ] && echo "rc=$RC" || echo "no accounts key"))"
    BODY=""
  fi
  for ITEM in $_FLAT; do
    IFS='|' read -r LABEL SUF V SINCE AGE <<< "$ITEM"
    if [ -n "$BODY" ]; then
      USD=$(printf '%s' "$BODY" | jq -r --arg l "$LABEL" '
        [.accounts[] | select(.meter.label == $l)] as $m
        | if ($m | length) == 0 then "absent"
          elif ($m[0].usd | type) == "number" then ($m[0].usd | tostring)
          else "null" end' 2>/dev/null)
      case "$USD" in
        absent|'') WHY="label not in the account-usage answer" ;;
        null) WHY="no priced rows billed this account in 12h" ;;
        *) if printf '%s' "$USD" | jq -e --argjson min "$EU_FLAT_MIN" '. > $min' >/dev/null 2>&1; then WHY=""
           else WHY="\$$USD of priced rows in 12h is not over \$$EU_FLAT_MIN"; fi ;;
      esac
    fi
    if [ -n "$WHY" ]; then
      echo "$(STAMP) extra-usage-track flat[$LABEL]: meter flat at \$$V since $SINCE (${AGE}h), no alert: $WHY" >> "$H/logs/agent-rules.log"
      continue
    fi
    FFLAG="$H/flags/alerted-extra-usage-flat$SUF-$(date -u +%Y%m%d)"
    [ -f "$FFLAG" ] && continue
    alert "extra-usage-flat-$LABEL" warn "EXTRA-USAGE METER FLAT [$LABEL]: meter stuck at \$$V since $SINCE (${AGE}h) while cost rows billed \$$(printf '%.2f' "$USD") to this account in the last 12h. The meter may be failing silently." \
      && touch "$FFLAG" 2>/dev/null
  done
  return 0
}

xcheck_accounts() {
  local W BODY RC TMP LABEL LINE ALL_READ=1 _l w _s rows meter gp unp
  TMP=$(mktemp "$H/state/.xcheck.XXXXXX" 2>/dev/null) || return 0
  for W in 5h 7d; do
    BODY=$( [ -f "$H/bin/jobs-client.sh" ] || exit 1
            # shellcheck source=/dev/null
            . "$H/bin/jobs-client.sh"
            command -v _jobs_req >/dev/null 2>&1 || exit 1
            _jobs_req GET "/api/metrics/account-usage?window=$W" ) 2>/dev/null
    RC=$?
    if [ "$RC" != 0 ] || ! printf '%s' "$BODY" | jq -e 'type=="object" and has("accounts") and (.accounts|type=="array")' >/dev/null 2>&1; then
      # A failed read is not "no gap": it neither fires nor clears.
      ALL_READ=0
      echo "$(STAMP) extra-usage-track xcheck[$W]: account-usage read unusable ($([ "$RC" != 0 ] && echo "rc=$RC" || echo "no accounts key")) — no fire, no clear" >> "$H/logs/agent-rules.log"
      continue
    fi
    # One row per eligible account: comparable, meter delta at or over the
    # floor, and a numeric gap (a null gap is skipped, never 0).
    printf '%s' "$BODY" | jq -r --arg w "$W" --argjson gap "$XC_GAP" --argjson min "$XC_MIN" '
      .accounts[]
      | select((.meter.label | type) == "string")
      | .cross_check as $c
      | select($c.state == "comparable")
      | select(($c.meter_delta_usd | type) == "number" and $c.meter_delta_usd >= $min)
      | select(($c.gap_pct | type) == "number" and ($c.rows_usd | type) == "number")
      | [.meter.label, $w, (if $c.gap_pct > $gap then "over" else "within" end),
         $c.rows_usd, $c.meter_delta_usd, $c.gap_pct, ($c.unpriced_in_span // 0)] | @tsv' >> "$TMP" 2>/dev/null
  done
  # Only labels this box polled ok: another box's login is that box's to judge.
  for LABEL in $_OK_LABELS; do
    # FIRE from the first over window (5h before 7d); otherwise CLEAR only when
    # both reads succeeded (the window that failed may be the one over) and a
    # window showed the account within. Anything else says nothing.
    LINE=$(awk -F'\t' -v l="$LABEL" '$1==l && $3=="over" {print; exit}' "$TMP")
    if [ -n "$LINE" ]; then
      IFS=$'\t' read -r _l w _s rows meter gp unp <<< "$LINE"
      alert "account-usage-gap-$LABEL" warn "ACCOUNT USAGE [$LABEL]: cost rows say \$$(printf '%.2f' "$rows") over $w, the meter moved \$$(printf '%.2f' "$meter") (gap $(printf '%.1f' "$gp")%, threshold $XC_GAP%); $unp unpriced rows in span."
      continue
    fi
    [ "$ALL_READ" = 1 ] || continue
    LINE=$(awk -F'\t' -v l="$LABEL" '$1==l && $3=="within" {print; exit}' "$TMP")
    [ -n "$LINE" ] || continue
    IFS=$'\t' read -r _l w _s rows meter gp unp <<< "$LINE"
    alert_clear "account-usage-gap-$LABEL" "ACCOUNT USAGE [$LABEL]: cost rows and the meter agree again (gap $(printf '%.1f' "$gp")% in $w, threshold $XC_GAP%)."
  done
  rm -f "$TMP"
}

_OK_LABELS=""
LOGINS=$(resolve_logins)
IFS=',' read -r -a _PAIRS <<< "$LOGINS"
for _P in "${_PAIRS[@]}"; do
  case "$_P" in *=*) : ;; *) continue ;; esac
  _LABEL=$(printf '%s' "${_P%%=*}" | tr -dc 'A-Za-z0-9._-')
  _DIR="${_P#*=}"
  [ -n "$_LABEL" ] && [ -n "$_DIR" ] || continue
  poll_login "$_LABEL" "$_DIR"
done

# Written even when no login polled ok, so "why did nothing fire" is answerable
# from the box.
_OKL="${_OK_LABELS# }"
echo "$(STAMP) extra-usage-track xcheck: gap threshold $XC_GAP% ($XC_GAP_SRC), meter floor \$$XC_MIN ($XC_MIN_SRC), ok logins: ${_OKL:-none}" >> "$H/logs/agent-rules.log"
[ -n "${_OK_LABELS// /}" ] && xcheck_accounts
echo "$(STAMP) extra-usage-track loud: error streak $EU_STREAK ($EU_STREAK_SRC), flat min \$$EU_FLAT_MIN ($EU_FLAT_MIN_SRC) over 12h" >> "$H/logs/agent-rules.log"
flat_accounts

# The EFFECTIVE threshold, logged every run. Setting a config value and assuming
# it arrived is exactly how the previous default stayed live: this line is what
# turns "we set it to 1300" into something checkable from the box, and it names
# where the value came from so a dead env file is visible rather than inferred.
_TSRC="code default"
[ -n "${EXTRA_USAGE_DAY_ALERT:-}" ] && _TSRC="env/global.env"
echo "$(STAMP) extra-usage-track: day-alert threshold \$$THRESH ($_TSRC), logins: $(printf '%s' "$LOGINS" | tr ',' ' ' | sed 's/=[^ ]*//g')" >> "$H/logs/agent-rules.log"
exit 0
