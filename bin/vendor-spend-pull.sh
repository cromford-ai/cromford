#!/bin/bash
# bin/vendor-spend-pull.sh — the NON-Anthropic half of the bill, pulled by API
# into the same D1 cost DB every other cost number already lives in.
#
# WHY (2026-09-14, cost fix 5). Anthropic spend is instrumented to the call
# (agent-call.sh -> logs/cost.csv -> cost_rows), and the extra-usage meter
# watches the subscription. Everything else we pay for lives in a vendor
# dashboard nobody opens: xAI runs fleet triage on a wallet that gets topped up
# $100 at a time, OpenRouter is the tier-3 survival lane with per-app key
# budgets, codex rides a ChatGPT subscription, and the Fly pool IS the compute
# bill. cost.csv already carries model-priced ESTIMATES for the grok/openrouter
# rows (bin/cost-rollup.sh METERED_VENDORS) — an estimate is not the invoice,
# and nothing anywhere compared the two.
#
# WHAT THIS IS AND IS NOT. One row per (vendor, ts), each carrying its OWN
# honesty:
#   kind=metered    the vendor told us a dollar figure. OpenRouter only, today.
#   kind=computed   we derived it — from our own cost rows, or from machine
#                   seconds times a price table. Useful, not the bill.
#   status=ok                  we got an answer
#   status=no-spend-endpoint   the vendor has no readable spend API (PROBED, not
#                              assumed — see the per-vendor blocks below)
#   status=auth-failed         401/403: the key is wrong, missing or descoped
#   status=error               anything else (timeout, 5xx, unparseable body)
# A vendor we cannot price writes a row with an EMPTY usd and a note saying
# why. Never a zero, and never a number we made up: a fabricated $0 for a lane
# that really spends is the exact failure this file exists to end, and it would
# be invisible forever because $0 is what "nothing happened" also looks like.
#
# PROBE RESULTS, 2026-09-14 (re-probe before trusting these; vendors ship APIs):
#   openrouter  GET /api/v1/credits -> 200 {total_credits,total_usage}. METERED.
#               Requires a MANAGEMENT key (OPENROUTER_PROVISIONING_KEY). An
#               inference OPENROUTER_API_KEY answers 403 "Only management keys
#               can fetch credits for an account" (probed 2026-09-16 after the
#               0916 key split). GET /api/v1/keys with the same provisioning
#               key -> 200, per-key usage/limit — the per-app budgets the hub
#               PATCHes.
#   xai         no billing/usage route. /v1/billing/usage, /v1/usage,
#               /v1/credits all 404; management-api.x.ai 404s at nginx.
#               /v1/api-key answers 200 and is used as the AUTH probe only.
#   fireworks   /v1/accounts 200, but /v1/accounts/<id>/{usage,billing,invoices}
#               all 404. Auth probe only.
#   codex       /v1/organization/costs needs an ADMIN key (sk-admin-...). This
#               fleet has none — codex authenticates with the ChatGPT
#               subscription — so there is nothing to read. The branch is
#               written anyway and arms itself the day OPENAI_ADMIN_KEY lands.
#   fly         GraphQL has no billing: `billables` and `invoices` are both
#               "doesn't exist on type 'Organization'". So machine-seconds x
#               guest size x catalog/fly-prices.json, from the Machines API.
#
# THE WINDOW. Each vendor's row covers (previous row's window_end, now]. That
# makes the series differenceable: OpenRouter reports a CUMULATIVE total_usage,
# so the window's spend is this reading minus the last one, and the first
# reading ever is a BASELINE row with an empty usd rather than a first-day
# spike of everything the account ever spent.
#
# KILL SWITCHES, all documented in docs/COST.md:
#   VENDOR_SPEND=0 in env/global.env, or the switch vendor-spend-off
#     read through lane_switch (BH-2438): the settings row
#     switch.vendor-spend-off[.<box>], else flags/vendor-spend-off -> whole script
#   VENDOR_SKIP='xai,fly'                                        -> per vendor
# KNOBS: VENDOR_BALANCE_FLOOR_USD (default 20), VENDOR_SPEND_FAIL_STREAK (3),
#   VENDOR_WINDOW_MAX_SECS (21600), VENDOR_HTTP_TIMEOUT (25), FLY_PRICES.
#
# usage: vendor-spend-pull.sh [--vendor <name>] [--dry-run]
# Output: logs/vendor-spend.csv (write-ahead mirror) + the vendor_spend table
# via bin/jobs-client.sh metric_vendor_spend. Never fails the caller.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")

# global.env is sourced HERE because cron does not, and every knob above lives
# in it. The same +u dance bin/extra-usage-track.sh needed: under `set -u` an
# unbound reference anywhere inside global.env is fatal regardless of -e and the
# 2>/dev/null swallows the message, which would kill this poller silently — in
# the one script whose job is noticing money.
# shellcheck source=/dev/null
set -a +u; . "$HENV/global.env" 2>/dev/null; set +a -u

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-vendor-spend-pull
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off vendor-spend-pull.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit vendor-spend-pull
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    vendor-spend-pull

command -v lane_switch >/dev/null 2>&1 || . "${HARNESS:-/root/harness}/bin/lib/lane-switch.sh" 2>/dev/null || lane_switch() { [ -f "${HARNESS:-/root/harness}/flags/$1" ]; }
HARNESS="$H" lane_switch vendor-spend-off && exit 0
[ "${VENDOR_SPEND:-1}" = "0" ] && exit 0

ONLY=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --vendor) ONLY="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,70p' "$0"; exit 0 ;;
    *) echo "vendor-spend-pull.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

# THE VENDOR BASE URLS ARE ENDPOINT KNOBS (BH-1941): the env, else the registry
# default, never a settings row. All three resolve here, before any call; one
# that cannot is a nonzero exit with nothing fetched.
. "${HARNESS:-/root/harness}/bin/lib/endpoints.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/endpoints.sh" 2>/dev/null
ep_fail() { echo "vendor-spend-pull.sh: no $1 endpoint ($2: no env, no registry default) — nothing fetched" >&2; exit 1; }
OR_BASE=$(endpoint_url openrouter 2>/dev/null)       || ep_fail openrouter ENDPOINT_OPENROUTER
OPENAI_BASE=$(endpoint_url openai 2>/dev/null)       || ep_fail openai ENDPOINT_OPENAI
FLY_BASE=$(endpoint_url fly-machines 2>/dev/null)    || ep_fail fly-machines ENDPOINT_FLY_MACHINES
CSV="$H/logs/vendor-spend.csv"
SDIR="$H/state/vendor-spend"
LOG="$H/logs/agent-rules.log"
PRICES="${FLY_PRICES:-$H/catalog/fly-prices.json}"
FLOOR="${VENDOR_BALANCE_FLOOR_USD:-20}"
STREAK="${VENDOR_SPEND_FAIL_STREAK:-3}"
WMAX="${VENDOR_WINDOW_MAX_SECS:-21600}"
HTTP_TIMEOUT="${VENDOR_HTTP_TIMEOUT:-25}"
mkdir -p "$H/logs" "$H/flags" "$SDIR" 2>/dev/null
NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
say() { echo "$(STAMP) vendor-spend: $*" >> "$LOG" 2>/dev/null; }

CSV_HDR="ts,vendor,window_start,window_end,usd,kind,status,balance_usd,cumulative_usd,note"
# Not under --dry-run: creating the mirror is itself a write, and a dry run that
# leaves a file behind is a dry run whose promise a reader stops believing.
[ "$DRY" = 1 ] || [ -f "$CSV" ] || echo "$CSV_HDR" > "$CSV"

# jobs-client is sourced ONCE, after global.env (which carries HARNESS_SECRET).
# Absent file or absent helper = no push, silently: bin/ syncs as a whole but
# not atomically with every other box, so a newer producer can land beside an
# older client, and "command not found" on stderr every hour is noise in the
# logs this wave exists to make readable. The CSV is written either way.
if [ -f "$H/bin/jobs-client.sh" ]; then
  # shellcheck source=/dev/null
  . "$H/bin/jobs-client.sh"
fi

# ── credentials ──────────────────────────────────────────────────────────────
# Read by NAME out of env/*.env, never sourced into the environment and never
# printed. global.env first so it keeps winning, then every other env file in
# name order — so a vendor key that arrives in its own file (env/openrouter.env
# already holds OPENROUTER_PROVISIONING_KEY) is found without this script
# carrying a list of filenames that would go stale the next time one is added.
# TRIMMED, NOT SQUEEZED. Leading/trailing whitespace and a stray CR go; an
# INTERNAL space stays. A Fly token is literally "FlyV1 fm2_..." with a space in
# the middle of it, and deleting that space is a 401 that looks exactly like a
# revoked key — which is how the fly row read auth-failed against a token that
# was fine (probed 2026-09-14: same token, space preserved, HTTP 200/20 apps).
# The vendor whose spend went unmeasured because of a credential reader is the
# precise failure this whole table exists to make impossible, so the tests pin
# an internal space reaching the Authorization header intact.
env_get() { # env_get <VAR_NAME> -> prints the value, or nothing
  local want="$1" f val
  case "$want" in *[!A-Z0-9_]*) return 1 ;; esac
  for f in "$HENV/global.env" "$HENV"/*.env; do
    [ -r "$f" ] || continue
    val=$(sed -n "s/^\(export \)\{0,1\}$want=//p" "$f" 2>/dev/null | head -1 \
      | tr -d "\"'" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$val" ] && { printf '%s' "$val"; return 0; }
  done
  return 1
}

# ── http ─────────────────────────────────────────────────────────────────────
# `curl` unqualified so a test can put a stub in front of it on PATH. Prints the
# HTTP status and nothing else; the body lands in <outfile>. A transport failure
# is 000, which the callers classify as `error` rather than as auth — a timeout
# and a revoked key are different facts and the alert text differs.
api_get() { # api_get <url> <bearer> <outfile> -> prints status
  local url="$1" tok="$2" out="$3" code
  : > "$out"
  code=$(curl -sS -m "$HTTP_TIMEOUT" --connect-timeout 5 \
    -H "Authorization: Bearer $tok" -o "$out" -w '%{http_code}' "$url" 2>/dev/null)
  case "$code" in ''|*[!0-9]*) code=000 ;; esac
  printf '%s' "$code"
}

# ── the local mirror is also the memory ──────────────────────────────────────
# The previous row for a vendor is where the window starts and, for a cumulative
# meter, what this reading is differenced against. Read from the CSV rather than
# from a separate state file so there is exactly ONE record of what we last saw:
# a marker that can disagree with the mirror is a marker that eventually does.
# THE LAST ROW THAT ACTUALLY MEASURED SOMETHING, not simply the last row. A
# failed poll must NOT advance the window: if it did, whatever was spent while
# the vendor API was down would fall into a window no row ever covers and be
# lost for good. So a failure leaves the window open and the next good poll
# covers the whole gap (clamped by VENDOR_WINDOW_MAX_SECS).
# A row ADVANCED the window if it measured anything at all — a usd for the
# window, or a cumulative reading a later poll can difference against. A
# baseline row (cumulative, no usd yet) counts; a 401 does not.
prev_window_end() { # prev_window_end <vendor>
  awk -F, -v v="$1" 'NR>1 && $2==v && ($5!="" || $9!="") {val=$4} END{print val}' \
    "$CSV" 2>/dev/null
}
prev_cumulative() { # prev_cumulative <vendor>
  awk -F, -v v="$1" 'NR>1 && $2==v && $9!="" {val=$9} END{print val}' "$CSV" 2>/dev/null
}

csv_cell() { printf '%s' "${1:-}" | tr -d '\r\n' | tr ',' ';'; }

# ── raw payload: scrubbed, compacted, capped at 8KB ──────────────────────────
# The bodies we store are usage numbers, but they also carry key LABELS
# (OpenRouter labels a key with a truncated form of the key itself, xAI prints
# a redacted_api_key), and a
# vendor could widen a field at any time. So the redaction happens here, on
# everything, before the text can reach a log, a row or a PR — never on the
# assumption that this particular vendor happens to be careful today.
scrub_raw() { # scrub_raw <file> -> prints <=8KB of redacted JSON
  python3 - "$1" <<'PY' 2>/dev/null
import json, re, sys
try:
    body = open(sys.argv[1], 'rb').read(200000).decode('utf-8', 'replace')
except Exception:
    sys.exit(0)
# Anything that looks like a credential, whatever vendor shape it wears.
body = re.sub(r'\b(sk|xai|fw|or|ghp|ghs|gho|sk-or-v1|sk-admin)[-_][A-Za-z0-9_\-]{6,}',
              '<redacted>', body)
body = re.sub(r'\bFlyV1[A-Za-z0-9._\-]{6,}', '<redacted>', body)
body = re.sub(r'\bfo1_[A-Za-z0-9_\-]{6,}', '<redacted>', body)
try:
    body = json.dumps(json.loads(body), separators=(',', ':'))
except Exception:
    pass
sys.stdout.write(body[:8192])
PY
}

# ── alerting ─────────────────────────────────────────────────────────────────
# ONE path (bin/lane-alert.sh): ALERTS.log plus a fleet_alert beat, so the
# 10-min medic sees it. A line written only into ALERTS.log sat unread for 10.5h
# once already; a question asked into your own run log is silence.
alert() { # alert <text>
  if [ -x "$H/bin/lane-alert.sh" ]; then
    "$H/bin/lane-alert.sh" vendor-spend "$*" >/dev/null 2>&1 || true
  else
    echo "$(STAMP) [orchestrator/vendor-spend] $*" >> "$H/logs/ALERTS.log" 2>/dev/null
  fi
}

# THREE CONSECUTIVE FAILURES, not one. A single blip on a vendor API is not
# news, and an alarm that rings on every transient is the alarm nobody reads.
# The streak counter resets on any answered poll, and the "already told you"
# marker goes with it — a vendor that recovers at noon must be able to alert
# again if it dies at six.
note_outcome() { # note_outcome <vendor> <status> <note>
  local v="$1" st="$2" detail="$3" n
  local f="$SDIR/fail-$v" m="$SDIR/alerted-$v"
  case "$st" in
    auth-failed|error)
      n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 ))
      case "$n" in ''|*[!0-9]*) n=1 ;; esac
      echo "$n" > "$f"
      if [ "$n" -ge "$STREAK" ] && [ ! -f "$m" ]; then
        touch "$m" 2>/dev/null
        alert "VENDOR SPEND: $v has failed $n consecutive polls (status=$st, $detail). That vendor's real spend is unmeasured until this is fixed — check the key name in env/ and re-run bin/vendor-spend-pull.sh --vendor $v."
      fi
      ;;
    *) rm -f "$f" "$m" 2>/dev/null ;;
  esac
}

# A readable balance below the floor is the one number worth waking someone for:
# OpenRouter and the xAI wallet both stop serving at zero, and the tier-3
# survival lane going dark during an Anthropic outage is the outage. Once a day
# per vendor, because the balance does not recover on its own.
balance_check() { # balance_check <vendor> <balance>
  local v="$1" bal="$2" f
  f="$SDIR/floor-$v-$(date -u +%Y%m%d)"
  [ -n "$bal" ] || return 0
  [ -f "$f" ] && return 0
  python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) < float(sys.argv[2]) else 1)" \
    "$bal" "$FLOOR" 2>/dev/null || return 0
  touch "$f" 2>/dev/null
  alert "VENDOR BALANCE LOW: $v has \$$bal left, under the \$$FLOOR floor (VENDOR_BALANCE_FLOOR_USD). Top it up before the lane starts refusing calls."
}

# ── the row ──────────────────────────────────────────────────────────────────
emit_row() { # emit_row <vendor> <ws> <we> <usd> <kind> <status> <balance> <cumulative> <note> [rawfile]
  local v="$1" ws="$2" we="$3" usd="$4" kind="$5" st="$6" bal="$7" cum="$8" note="$9" rawf="${10:-}"
  local raw="" line
  [ -n "$rawf" ] && [ -s "$rawf" ] && raw=$(scrub_raw "$rawf")
  line=$(printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s' \
    "$NOW" "$v" "$ws" "$we" "$usd" "$kind" "$st" "$bal" "$cum" "$(csv_cell "$note")")
  if [ "$DRY" = 1 ]; then
    echo "$line"
  else
    echo "$line" >> "$CSV"
    # THE CSV FIRST, THEN THE DB, fail-open in that order. The mirror is what the
    # next run differences against, so a worker outage must cost a row in D1 and
    # never the series itself.
    command -v metric_vendor_spend >/dev/null 2>&1 && \
      metric_vendor_spend "$v" "$NOW" "$ws" "$we" "$usd" "$kind" "$st" "$bal" "$cum" "$note" "$raw" >/dev/null 2>&1 || true
  fi
  say "$v $st kind=$kind usd=${usd:-n/a} balance=${bal:-n/a} ($note)"
  # A DRY RUN DOES NOT ALERT AND DOES NOT TOUCH THE STREAK STATE. Both of these
  # are writes, and the marker files they set are SUPPRESSORS: a human running
  # --dry-run to see what the poller would say could silence the hourly job's
  # real balance alert for the rest of the day, or push a vendor one tick closer
  # to a failure alarm on evidence nobody published. --dry-run prints; that is all.
  [ "$DRY" = 1 ] && return 0
  note_outcome "$v" "$st" "$note"
  balance_check "$v" "$bal"
}

# The window this poll covers. Clamped: a box that was down for two days must
# not publish one row claiming two days of Fly compute it sampled once, and a
# double-fire inside a minute must not publish a window of zero seconds.
window_start_for() { # window_start_for <vendor> -> prints an ISO instant
  local v="$1" prev floor_ts first_ts now_s
  prev=$(prev_window_end "$v")
  now_s=$(date -u +%s)
  floor_ts=$(date -u -d "@$(( now_s - WMAX ))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
  # A first-ever poll has nothing to difference against, so it covers ONE
  # cadence rather than the whole clamp — a fresh box must not publish six hours
  # of Fly compute it sampled once and call it an hour's bill.
  first_ts=$(date -u -d "@$(( now_s - ${VENDOR_WINDOW_DEFAULT_SECS:-3600} ))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
  if [ -z "$prev" ]; then
    printf '%s' "${first_ts:-$NOW}"
  elif [ -z "$floor_ts" ]; then
    printf '%s' "$prev"
  elif [ "$prev" \< "$floor_ts" ]; then
    printf '%s' "$floor_ts"
  else
    printf '%s' "$prev"
  fi
}

# ── our own cost rows, as the fallback estimate ──────────────────────────
# For a vendor with no spend endpoint, the honest second-best is what WE
# recorded spending through that vendor's runner in the same window. It is a
# model-priced estimate (bin/cost-rollup.sh prices these rows at retail), which
# is why every row derived this way is kind=computed and says so in its note.
#
# PRICED AND UNPRICED ROWS ARE COUNTED SEPARATELY, and that distinction is the
# whole point. cost.csv carries an EMPTY cost_usd for any call whose model has
# no catalog price — every fireworks row on this box today is one (probed
# 2026-09-14: 7 rows in the window, all unpriced). Summing those with
# `float(x or 0)` publishes $0.0000 for calls that really cost money, which is
# the exact fabrication this whole table exists to end: $0 is also what "nothing
# happened" looks like, so nobody ever goes back and checks.
#   prints: <total|empty> <priced-rows> <unpriced-rows>
# and an unreadable cost.csv prints nothing at all, which the caller separates
# from "readable, but nothing in it we can price".
cost_rows_usd() { # cost_rows_usd <runner> <window-start> <window-end>
  python3 - "$H/logs/cost.csv" "$1" "$2" "$3" <<'PY' 2>/dev/null
import csv, sys
path, runner, ws, we = sys.argv[1:5]
total = 0.0
priced = unpriced = 0
try:
    with open(path, newline='') as fh:
        for r in csv.DictReader(fh):
            if (r.get('runner') or '').strip() != runner:
                continue
            ts = (r.get('ts') or '').strip()
            if not ts or ts <= ws or ts > we:
                continue
            cell = (r.get('cost_usd') or '').strip()
            if not cell:
                unpriced += 1
                continue
            try:
                total += float(cell)
            except ValueError:
                unpriced += 1
                continue
            priced += 1
except OSError:
    sys.exit(0)
print(f'{total:.4f} {priced} {unpriced}')
PY
}

# ═════════════════════════════════════════════════════════════════════════════
# openrouter — the one vendor that answers with a real dollar figure
# ═════════════════════════════════════════════════════════════════════════════
poll_openrouter() {
  local key ws code body raw usd cum bal prev note keys pk pcode
  # GET /api/v1/credits is a MANAGEMENT endpoint. An inference
  # OPENROUTER_API_KEY answers HTTP 403 "Only management keys can fetch
  # credits for an account" (probed 2026-09-16 on the hub after the 0916
  # key split left OPENROUTER_API_KEY as the scoped inference key). The
  # provisioning key is the management key. Fall back to the inference
  # key so a box that has not been given one still tries, and the
  # auth-failed row names the HTTP code instead of going silent.
  key=$(env_get OPENROUTER_PROVISIONING_KEY) || key=$(env_get OPENROUTER_API_KEY) || {
    emit_row openrouter "$NOW" "$NOW" "" computed no-spend-endpoint "" "" \
      "no key on this box (OPENROUTER_PROVISIONING_KEY and OPENROUTER_API_KEY unset in env/)"; return; }
  ws=$(window_start_for openrouter)
  body=$(mktemp); raw=$(mktemp); keys=$(mktemp)
  code=$(api_get "$OR_BASE/api/v1/credits" "$key" "$body")
  case "$code" in
    401|403) emit_row openrouter "$ws" "$NOW" "" metered auth-failed "" "" \
               "GET /api/v1/credits answered HTTP $code" "$body"
             rm -f "$body" "$raw" "$keys"; return ;;
    2*) : ;;
    *)  emit_row openrouter "$ws" "$NOW" "" metered error "" "" \
          "GET /api/v1/credits answered HTTP $code" "$body"
        rm -f "$body" "$raw" "$keys"; return ;;
  esac
  # total_usage is CUMULATIVE for the life of the account, so the window's spend
  # is a DIFFERENCE. Printing the cumulative as the window's usd would report
  # $6,868 of spend every hour, forever.
  read -r cum bal <<<"$(python3 - "$body" <<'PY' 2>/dev/null
import json, sys
d = (json.load(open(sys.argv[1])) or {}).get('data') or {}
u, c = d.get('total_usage'), d.get('total_credits')
if u is None:
    sys.exit(1)
print(f"{float(u):.6f}", f"{float(c) - float(u):.6f}" if c is not None else "")
PY
)"
  [ -n "${cum:-}" ] || { emit_row openrouter "$ws" "$NOW" "" metered error "" "" \
      "GET /api/v1/credits answered HTTP $code with no total_usage" "$body"
      rm -f "$body" "$raw" "$keys"; return; }
  prev=$(prev_cumulative openrouter)
  usd=""; note="credits endpoint, cumulative differenced against the last reading"
  if [ -n "$prev" ]; then
    # argv, not interpolation: a value spliced into the program text is a value
    # that can end the string literal it was meant to sit inside.
    usd=$(python3 -c "import sys;print(f'{max(0.0, float(sys.argv[1]) - float(sys.argv[2])):.4f}')" "$cum" "$prev" 2>/dev/null)
  else
    note="BASELINE: first reading, no prior cumulative to difference against"
  fi
  # Per-key usage rides along in raw when the PROVISIONING key is present — the
  # per-app budgets the hub PATCHes are the only place an openrouter overspend
  # is attributable to a project, and they are unreadable with the inference key.
  pk=$(env_get OPENROUTER_PROVISIONING_KEY) && {
    pcode=$(api_get "$OR_BASE/api/v1/keys?limit=100" "$pk" "$keys")
    [ "${pcode:0:1}" = 2 ] || : > "$keys"
  }
  python3 - "$body" "$keys" > "$raw" <<'PY' 2>/dev/null
import json, sys
out = {}
try:
    out['credits'] = (json.load(open(sys.argv[1])) or {}).get('data') or {}
except Exception:
    pass
try:
    rows = (json.load(open(sys.argv[2])) or {}).get('data') or []
    # Priciest first and capped: raw is 8KB, and the tail nobody reads is the
    # right thing to lose rather than the keys the spend actually came from.
    rows.sort(key=lambda r: -(r.get('usage') or 0))
    out['keys'] = [{'name': r.get('name'), 'usage': r.get('usage'),
                    'limit': r.get('limit'), 'limit_remaining': r.get('limit_remaining'),
                    'disabled': r.get('disabled')} for r in rows[:25]]
    out['keys_total'] = len(rows)
except Exception:
    pass
print(json.dumps(out, separators=(',', ':')))
PY
  [ -s "$raw" ] || cp "$body" "$raw"
  emit_row openrouter "$ws" "$NOW" "$usd" metered ok "$bal" "$cum" "$note" "$raw"
  rm -f "$body" "$raw" "$keys"
}

# ═════════════════════════════════════════════════════════════════════════════
# A vendor with no spend API: probe that the key still WORKS, then fall back to
# our own cost rows. Shared by xai and fireworks, which differ only in which
# endpoint answers and which runner column carries their rows.
# ═════════════════════════════════════════════════════════════════════════════
poll_metered_estimate() { # <vendor> <key-var> <auth-probe-url> <runner> <why-no-endpoint>
  local v="$1" keyvar="$2" probe="$3" runner="$4" why="$5"
  local key ws code body usd n
  key=$(env_get "$keyvar") || {
    emit_row "$v" "$NOW" "$NOW" "" computed no-spend-endpoint "" "" \
      "no key on this box ($keyvar unset in env/)"; return; }
  ws=$(window_start_for "$v")
  body=$(mktemp)
  code=$(api_get "$probe" "$key" "$body")
  case "$code" in
    401|403) emit_row "$v" "$ws" "$NOW" "" computed auth-failed "" "" \
               "auth probe $probe answered HTTP $code" "$body"
             rm -f "$body"; return ;;
    2*) : ;;
    *)  emit_row "$v" "$ws" "$NOW" "" computed error "" "" \
          "auth probe $probe answered HTTP $code" "$body"
        rm -f "$body"; return ;;
  esac
  local priced unpriced
  read -r usd priced unpriced <<<"$(cost_rows_usd "$runner" "$ws" "$NOW")"
  if [ -z "${usd:-}" ]; then
    emit_row "$v" "$ws" "$NOW" "" computed no-spend-endpoint "" "" \
      "$why; and logs/cost.csv is unreadable, so there is no estimate either"
  elif [ "${priced:-0}" = 0 ] && [ "${unpriced:-0}" != 0 ]; then
    # Rows exist and not one of them carries a price. Publishing the 0.0000 this
    # sums to would report "$v cost nothing this hour" about calls that really
    # ran. Empty usd, and the note names the reason so it is fixable.
    emit_row "$v" "$ws" "$NOW" "" computed no-spend-endpoint "" "" \
      "$why; and all $unpriced logs/cost.csv rows with runner=$runner in this window are UNPRICED (no catalog price for the model), so there is no estimate — NOT \$0"
  elif [ "${unpriced:-0}" != 0 ]; then
    emit_row "$v" "$ws" "$NOW" "$usd" computed no-spend-endpoint "" "" \
      "$why — ESTIMATE from $priced logs/cost.csv rows with runner=$runner priced at retail; a FLOOR, not the total: $unpriced more rows in this window are unpriced"
  elif [ "${priced:-0}" = 0 ]; then
    emit_row "$v" "$ws" "$NOW" "$usd" computed no-spend-endpoint "" "" \
      "$why — no logs/cost.csv rows with runner=$runner in this window, so nothing was spent through this box's own calls"
  else
    emit_row "$v" "$ws" "$NOW" "$usd" computed no-spend-endpoint "" "" \
      "$why — ESTIMATE from $priced logs/cost.csv rows with runner=$runner priced at retail; not the invoice"
  fi
  rm -f "$body"
}

# ═════════════════════════════════════════════════════════════════════════════
# codex / OpenAI — the branch that is written but cannot fire yet
# ═════════════════════════════════════════════════════════════════════════════
# /v1/organization/costs is admin-key-only. This fleet's codex lanes authenticate
# with the ChatGPT subscription, so there IS no key that can read it and the row
# says exactly that instead of reporting a confident $0. cost.csv's codex rows
# are deliberately NOT turned into a dollar figure here: cost-rollup classifies
# codex as unknown-billing on purpose ("the same runner is flat-rate on one box
# and per-token on another"), so pricing them would invent cash that was never
# billed. The notional total goes in raw, where it is labelled as notional.
poll_codex() {
  local key ws code body raw usd n start
  ws=$(window_start_for codex)
  if key=$(env_get OPENAI_ADMIN_KEY); then
    body=$(mktemp)
    start=$(date -u -d "$ws" +%s 2>/dev/null || echo "")  # determinism: ok date-empty-stamp window_start_for always prints first_ts, $NOW or a non-empty prev/floor_ts
    code=$(api_get "$OPENAI_BASE/v1/organization/costs?start_time=${start:-0}&limit=180" "$key" "$body")
    case "$code" in
      2*) usd=$(python3 - "$body" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1])) or {}
tot = 0.0
for b in d.get('data') or []:
    for r in b.get('results') or []:
        tot += float((r.get('amount') or {}).get('value') or 0)
print(f'{tot:.4f}')
PY
)
          emit_row codex "$ws" "$NOW" "${usd:-}" metered ok "" "" \
            "GET /v1/organization/costs with OPENAI_ADMIN_KEY" "$body" ;;
      401|403) emit_row codex "$ws" "$NOW" "" metered auth-failed "" "" \
            "OPENAI_ADMIN_KEY rejected by /v1/organization/costs (HTTP $code)" "$body" ;;
      *) emit_row codex "$ws" "$NOW" "" metered error "" "" \
            "/v1/organization/costs answered HTTP $code" "$body" ;;
    esac
    rm -f "$body"; return
  fi
  raw=$(mktemp)
  read -r usd n <<<"$(cost_rows_usd codex "$ws" "$NOW")"
  python3 -c "import json,sys;print(json.dumps({'notional_usd_from_cost_rows':sys.argv[1] or None,'rows':sys.argv[2] or 0,'why':'notional retail price of the tokens, NOT cash: codex bills through a ChatGPT subscription here'},separators=(',',':')))" \
    "${usd:-}" "${n:-0}" > "$raw" 2>/dev/null
  emit_row codex "$ws" "$NOW" "" computed no-spend-endpoint "" "" \
    "/v1/organization/costs needs an admin key; this fleet has ChatGPT-subscription auth only (set OPENAI_ADMIN_KEY to arm). Notional token cost is in raw" "$raw"
  rm -f "$raw"
}

# ═════════════════════════════════════════════════════════════════════════════
# fly — the compute bill, computed
# ═════════════════════════════════════════════════════════════════════════════
# Fly publishes no billing API (probed: `billables` and `invoices` are both
# undefined fields on Organization). So: every app in the org, every machine's
# guest size, and the seconds each machine was actually RUNNING inside the
# window, priced from catalog/fly-prices.json. Machine-seconds come from the
# machines' own event log where it reaches back into the window, and from the
# current state where it does not — a machine created and destroyed entirely
# inside one window is invisible to both, which is a KNOWN undercount and is
# named in the row's note rather than left for a reader to discover.
poll_fly() {
  local tok org ws apps raw out
  tok=$(env_get FLY_API_TOKEN) || {
    emit_row fly "$NOW" "$NOW" "" computed no-spend-endpoint "" "" \
      "no key on this box (FLY_API_TOKEN unset in env/)"; return; }
  org=$(env_get FLY_ORG) || {
    emit_row fly "$NOW" "$NOW" "" computed error "" "" \
      "FLY_ORG unset in env/: no Fly org to read (never defaults to personal)"; return; }
  ws=$(window_start_for fly)
  apps=$(mktemp); raw=$(mktemp)
  local code
  code=$(api_get "$FLY_BASE/v1/apps?org_slug=$org" "$tok" "$apps")
  case "$code" in
    401|403) emit_row fly "$ws" "$NOW" "" computed auth-failed "" "" \
               "GET /v1/apps?org_slug=$org answered HTTP $code" "$apps"
             rm -f "$apps" "$raw"; return ;;
    2*) : ;;
    *)  emit_row fly "$ws" "$NOW" "" computed error "" "" \
          "GET /v1/apps?org_slug=$org answered HTTP $code" "$apps"
        rm -f "$apps" "$raw"; return ;;
  esac
  # One machines call per app, and one volumes call per app that HAS volumes
  # (the apps listing carries volume_count, so an app with none costs nothing to
  # skip). Twenty-odd requests an hour against an API we already drive per build.
  local machdir; machdir=$(mktemp -d)
  local app names
  names=$(python3 -c "import json,sys;print('\n'.join(a.get('name','') for a in (json.load(open(sys.argv[1])) or {}).get('apps') or [] if a.get('name')))" "$apps" 2>/dev/null)
  while read -r app; do
    [ -n "$app" ] || continue
    api_get "$FLY_BASE/v1/apps/$app/machines" "$tok" "$machdir/$app.machines" >/dev/null
    if python3 -c "import json,sys;a=[x for x in (json.load(open(sys.argv[1])) or {}).get('apps') or [] if x.get('name')==sys.argv[2]];sys.exit(0 if a and (a[0].get('volume_count') or 0)>0 else 1)" "$apps" "$app" 2>/dev/null; then
      api_get "$FLY_BASE/v1/apps/$app/volumes" "$tok" "$machdir/$app.volumes" >/dev/null
    fi
  done <<< "$names"

  out=$(FLY_WS="$ws" FLY_WE="$NOW" python3 - "$PRICES" "$machdir" <<'PY' 2>/dev/null
import json, os, sys, glob, datetime

prices_path, machdir = sys.argv[1], sys.argv[2]
# THE FALLBACK IS THE SAME SHAPE AS THE FILE and is used only when the catalog
# is missing or unparseable — and a row priced from it says so, so a stale or
# absent catalog is visible instead of silently assumed.
FALLBACK = {"seconds_per_month": 2628000,
            "cpu_usd_per_core_month": {"shared": 2.0, "performance": 31.0},
            "memory_usd_per_gb_month": 5.0, "volume_usd_per_gb_month": 0.15}
src = "catalog"
try:
    P = json.load(open(prices_path))
    for k in FALLBACK:
        if k not in P:
            raise KeyError(k)
except Exception:
    P, src = FALLBACK, "code fallback (catalog/fly-prices.json missing or unparseable)"

SPM = float(P["seconds_per_month"])
def cpu_rate(kind):
    tbl = P["cpu_usd_per_core_month"]
    return float(tbl.get(kind, tbl.get("shared", 2.0))) / SPM
MEM_RATE = float(P["memory_usd_per_gb_month"]) / SPM
VOL_RATE = float(P["volume_usd_per_gb_month"]) / SPM

def epoch(s):
    return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=datetime.timezone.utc).timestamp()

WS, WE = epoch(os.environ["FLY_WS"]), epoch(os.environ["FLY_WE"])
WIN = max(0.0, WE - WS)

def running_seconds(m):
    """Seconds this machine was in a BILLABLE running state inside the window.

    Fly's event log is newest-first and is not guaranteed to reach back past the
    window, so the reconstruction walks it forward and, when the earliest event
    is inside the window, treats the state before it as the complement of what
    that event produced. With no events at all we fall back to the machine's
    CURRENT state, which is right for a long-lived machine and wrong for one
    that churned unobserved — the direction of that error is UNDER-counting,
    and it is named in the row's note.
    """
    evs = sorted(m.get("events") or [], key=lambda e: e.get("timestamp") or 0)
    marks = []
    for e in evs:
        ts = (e.get("timestamp") or 0) / 1000.0
        st = (e.get("status") or "").lower()
        typ = (e.get("type") or "").lower()
        if typ == "start" or st == "started":
            marks.append((ts, True))
        elif typ in ("exit", "stop", "destroy") or st in ("stopped", "suspended", "destroyed", "failed"):
            marks.append((ts, False))
    if not marks:
        return WIN if (m.get("state") or "") == "started" else 0.0
    # State entering the window: the complement of the first mark we can see, or
    # the first mark itself when the log predates the window.
    before = [x for x in marks if x[0] <= WS]
    running = before[-1][1] if before else (not marks[0][1])
    total, cur = 0.0, WS
    for ts, up in marks:
        if ts <= WS or ts > WE:
            continue
        if running and not up:
            total += ts - cur
        if up and not running:
            cur = ts
        running = up
    if running:
        total += WE - cur
    return max(0.0, min(total, WIN))

apps, grand, mach_n, run_n = [], 0.0, 0, 0
for path in sorted(glob.glob(os.path.join(machdir, "*.machines"))):
    app = os.path.basename(path)[: -len(".machines")]
    try:
        machines = json.load(open(path))
    except Exception:
        machines = []
    if not isinstance(machines, list):
        machines = []
    cpu_s = mem_s = usd = 0.0
    for m in machines:
        mach_n += 1
        if (m.get("state") or "") == "started":
            run_n += 1
        g = ((m.get("config") or {}).get("guest")) or {}
        secs = running_seconds(m)
        cpus = float(g.get("cpus") or 0)
        gb = float(g.get("memory_mb") or 0) / 1024.0
        cpu_s += secs * cpus
        mem_s += secs * gb
        usd += secs * cpus * cpu_rate((g.get("cpu_kind") or "shared").lower()) + secs * gb * MEM_RATE
    vol_gb = 0.0
    vpath = os.path.join(machdir, app + ".volumes")
    if os.path.exists(vpath):
        try:
            vol_gb = sum(float(v.get("size_gb") or 0) for v in (json.load(open(vpath)) or []))
        except Exception:
            vol_gb = 0.0
    usd += vol_gb * VOL_RATE * WIN
    grand += usd
    if usd > 0 or machines:
        apps.append({"app": app, "machines": len(machines), "cpu_seconds": round(cpu_s, 1),
                     "gb_seconds": round(mem_s, 1), "volume_gb": vol_gb, "usd": round(usd, 6)})
apps.sort(key=lambda a: -a["usd"])
raw = {"price_source": src, "window_seconds": round(WIN), "machines": mach_n,
       "running_now": run_n, "apps": apps[:40]}
print(json.dumps({"usd": round(grand, 4), "machines": mach_n, "running": run_n,
                  "src": src, "raw": raw}, separators=(',', ':')))
PY
)
  if [ -z "$out" ]; then
    emit_row fly "$ws" "$NOW" "" computed error "" "" \
      "the machines listing parsed to nothing — no per-app JSON to price" "$apps"
  else
    local usd nm nr psrc
    usd=$(printf '%s' "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)['usd'])" 2>/dev/null)
    nm=$(printf '%s' "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)['machines'])" 2>/dev/null)
    nr=$(printf '%s' "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)['running'])" 2>/dev/null)
    psrc=$(printf '%s' "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)['src'])" 2>/dev/null)
    printf '%s' "$out" | python3 -c "import json,sys;print(json.dumps(json.load(sys.stdin)['raw'],separators=(',',':')))" > "$raw" 2>/dev/null
    emit_row fly "$ws" "$NOW" "$usd" computed ok "" "" \
      "machine-seconds x guest size priced from $psrc; $nm machines in org $org ($nr running now). Undercounts a machine created AND destroyed inside one window" "$raw"
  fi
  rm -rf "$machdir"; rm -f "$apps" "$raw"
}

# ═════════════════════════════════════════════════════════════════════════════
VENDORS="openrouter xai fireworks codex fly"
skipped() { # skipped <vendor>
  case ",${VENDOR_SKIP:-}," in *",$1,"*) return 0 ;; esac
  return 1
}
RAN=0
for V in $VENDORS; do
  [ -n "$ONLY" ] && [ "$ONLY" != "$V" ] && continue
  if skipped "$V"; then say "$V skipped (VENDOR_SKIP)"; continue; fi
  RAN=$((RAN+1))
  case "$V" in
    openrouter) poll_openrouter ;;
    xai)        poll_metered_estimate xai XAI_API_KEY "https://api.x.ai/v1/api-key" grok \
                  "xAI exposes no billing/usage route (/v1/billing/usage, /v1/usage and /v1/credits all 404 as of 2026-09-14)" ;;
    fireworks)  poll_metered_estimate fireworks FIREWORKS_API_KEY "https://api.fireworks.ai/v1/accounts" fireworks \
                  "Fireworks answers /v1/accounts but 404s every usage/billing/invoices route under it (probed 2026-09-14)" ;;
    codex)      poll_codex ;;
    fly)        poll_fly ;;
  esac
done
[ -n "$ONLY" ] && [ "$RAN" = 0 ] && { echo "vendor-spend-pull.sh: unknown vendor '$ONLY' (have: $VENDORS)" >&2; exit 2; }
exit 0
