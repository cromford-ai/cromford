#!/bin/bash
# bin/mac/mac-burn-push.sh — runs ON OPERATOR'S MAC (launchd, hourly), NOT on boxes.
#
# WHY. The 2026-08-24 cost audit found the Mac is the fleet's single biggest
# token burner (~$9-10K/wk API-list-equivalent: interactive Claude Code sessions
# plus the local subagent team) and it was tracked NOWHERE — the number only
# existed when someone hand-scanned ~/.claude/projects. A burner that big must
# not be invisible next to a fleet whose every lane is instrumented.
#
# WHAT. Scans the local session ledgers (~/.claude/projects/*/*.jsonl), sums
# usage per model over 24h and 7d windows, prices at API list via the repo's
# catalog/model-prices.json (same table the fleet rollup uses, so the numbers
# are comparable), and POSTs one compact JSON to the watchdog KV
# (/api/mac-burn). The console worker passes it through to the dashboard.
#
# HONESTY RULES (the wave's lessons apply here too):
# - A model missing from the price table is counted in `unpriced_models`,
#   never silently $0 — its tokens are still reported.
# - This is NOTIONAL (list-equivalent). Whether it is also cash depends on the
#   Mac account's own overage state, which this script cannot see; the payload
#   says so (`billing: "notional — account overage state untracked"`).
# - A scan error POSTs nothing and logs loudly — a stale KV value is visible
#   via generated_at (the dashboard staleness rule), never overwritten with a
#   plausible zero.
#
# Secrets: reads the watchdog secret from ~/.orgo/.watchdog-secret when it is
# readable, else ~/.orgo/.harness-secret (the Mac's existing copy), and sends it
# in an Authorization header from a curl config on a file descriptor, never in
# the URL or argv (BH-9264). Price table: vendored path first, then the repo checkout.
# Watchdog URL (BH-2091): $WATCHDOG_URL, else catalog/fleet-watchdog.json in
# $MACBURN_CHECKOUT (default ~/cromford) when its origin is the catalog's
# repo. Neither: one "not set" line per UTC day in the log, no scan, no push, rc 0.
set -uo pipefail
LOG="$HOME/.mk-macburn.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
# Test seams (each defaults to the real thing): the test suite injects a
# fixture ledger dir, price table, secret file, and a local URL + stubbed curl.
SECRET_FILE="${MACBURN_SECRET_FILE:-}"
if [ -z "$SECRET_FILE" ]; then
  SECRET_FILE="$HOME/.orgo/.harness-secret"
  [ -r "$HOME/.orgo/.watchdog-secret" ] && SECRET_FILE="$HOME/.orgo/.watchdog-secret"
fi
LEDGER_DIR="${MACBURN_LEDGER_DIR:-$HOME/.claude/projects}"
WATCHDOG_URL="${WATCHDOG_URL-}"
# Always sourced: watchdog_curl (the header transport) lives there too.
. "$(dirname "$0")/../lib/watchdog-url.sh" 2>/dev/null \
  || { echo "$(STAMP) mac-burn: no bin/lib/watchdog-url.sh beside this script — not pushed" >> "$LOG"; exit 1; }
if [ -z "$WATCHDOG_URL" ]; then
  WATCHDOG_URL=$(watchdog_url_carry "${MACBURN_CHECKOUT:-$HOME/cromford}") || WATCHDOG_URL=""
  [ -n "$WATCHDOG_URL" ] || { watchdog_url mac-burn "$HOME" "$LOG" >/dev/null; exit 0; }
fi
WATCHDOG_URL="${WATCHDOG_URL%/}"
[ -r "$SECRET_FILE" ] || { echo "$(STAMP) mac-burn: no secret file — not pushed" >> "$LOG"; exit 1; }
SECRET=$(tr -d '\r\n' < "$SECRET_FILE")

# Price table: prefer a local checkout of cromford; fail loud if absent.
PRICES=""
for c in "$HOME/cromford/catalog/model-prices.json" "$HOME/bh-wt-macburn/catalog/model-prices.json"; do
  [ -r "$c" ] && { PRICES="$c"; break; }
done
[ -n "${MACBURN_PRICES:-}" ] && PRICES="$MACBURN_PRICES"
[ -n "$PRICES" ] || { echo "$(STAMP) mac-burn: no model-prices.json found — not pushed" >> "$LOG"; exit 1; }

# THE SCAN'S OWN STDERR GOES TO THE LOG, NOT TO CRON (2026-09-16). An
# unreadable price table used to raise a twelve-line JSONDecodeError traceback
# out of this heredoc: the `|| exit 1` below was right, nothing was pushed, but
# the WHY landed on the cron's stderr where nobody reads it (and in the CI
# suite it looked like a test dying). One named line, in the same log as every
# other outcome.
PAYLOAD=$(python3 - "$PRICES" "$LEDGER_DIR" 2>>"$LOG" <<'PY'
import json, os, glob, sys, time, datetime
try:
    prices = json.load(open(sys.argv[1]))["per_token"]
except Exception as e:
    sys.stderr.write('mac-burn: unreadable price table %s (%s: %s) — nothing pushed\n'
                     % (sys.argv[1], type(e).__name__, e))
    sys.exit(1)
now = datetime.datetime.now(datetime.timezone.utc)
cut7  = (now - datetime.timedelta(days=7)).strftime('%Y-%m-%dT%H:%M:%S')
cut24 = (now - datetime.timedelta(hours=24)).strftime('%Y-%m-%dT%H:%M:%S')
mt_cut = time.time() - 8*86400  # only files touched within the 7d window (+1d slack)
models = {}   # model -> {w: [in,out,cr,cw,cost,calls] for w in (24h,7d)}
for fp in glob.glob(os.path.join(os.path.expanduser(sys.argv[2]), '*', '*.jsonl')):
    try:
        if os.path.getmtime(fp) < mt_cut: continue
    except OSError: continue
    try:
        f = open(fp, errors='ignore')
    except OSError: continue
    with f:
        for line in f:
            if '"usage"' not in line or '"timestamp"' not in line: continue
            try: o = json.loads(line)
            except Exception: continue
            ts = (o.get('timestamp') or '')[:19]
            if ts < cut7: continue
            m = o.get('message') or {}
            u = m.get('usage') or {}
            model = m.get('model') or ''
            if not u or not model or model == '<synthetic>': continue
            ent = models.setdefault(model, {'24h':[0,0,0,0,0.0,0], '7d':[0,0,0,0,0.0,0]})
            i=u.get('input_tokens') or 0; ou=u.get('output_tokens') or 0
            cr=u.get('cache_read_input_tokens') or 0; cw=u.get('cache_creation_input_tokens') or 0
            p = prices.get(model)
            c = (i*(p.get('prompt') or 0)+ou*(p.get('completion') or 0)
                 +cr*(p.get('cache_read') or 0)+cw*(p.get('cache_write') or 0)) if p else 0.0
            for w, cutw in (('7d', cut7), ('24h', cut24)):
                if ts >= cutw:
                    t = ent[w]
                    t[0]+=i; t[1]+=ou; t[2]+=cr; t[3]+=cw; t[4]+=c; t[5]+=1
unpriced = sorted(m for m in models if m not in prices)
out = {
  'generated_at': now.strftime('%Y-%m-%dT%H:%M:%SZ'),
  'host': 'mac-operator',
  # Notional by construction; the Mac account's overage state is untracked, so
  # whether any of this is ALSO cash is unknown — stated, not guessed.
  'billing': 'notional — account overage state untracked',
  'unpriced_models': unpriced,
  # The caveat RIDES THE NUMBER (review finding, PR #70): a consumer rendering
  # cost_7d alone must see the lower-bound marker, not reconstruct it from two
  # other fields. Same rule as fleet_cash_7d_total_note in the hub rollup.
  'cost_is_lower_bound': bool(unpriced),
  'note': ('cost excludes %d unpriced model(s): %s — tokens still reported in '
           'by_model_7d; the cost figures are a LOWER BOUND' % (len(unpriced), ', '.join(unpriced))) if unpriced else None,
  'cost_24h': round(sum(v['24h'][4] for v in models.values()), 2),
  'cost_7d':  round(sum(v['7d'][4]  for v in models.values()), 2),
  'calls_24h': sum(v['24h'][5] for v in models.values()),
  'calls_7d':  sum(v['7d'][5]  for v in models.values()),
  'by_model_7d': {m: {'calls': v['7d'][5], 'in': v['7d'][0], 'out': v['7d'][1],
                      'cache_read': v['7d'][2], 'cache_write': v['7d'][3],
                      'cost': round(v['7d'][4], 2)} for m, v in models.items()},
}
print(json.dumps(out))
PY
) || { echo "$(STAMP) mac-burn: scan FAILED — nothing pushed (stale KV stays visible via generated_at)" >> "$LOG"; exit 1; }

if watchdog_curl "$SECRET" -sf -m 30 -X POST -H 'Content-Type: application/json' \
     --data-binary "$PAYLOAD" \
     "$WATCHDOG_URL/api/mac-burn" >/dev/null; then
  echo "$(STAMP) mac-burn: pushed ($(printf '%s' "$PAYLOAD" | wc -c | tr -d ' ')b, 24h=$(printf '%s' "$PAYLOAD" | python3 -c 'import sys,json;print(json.load(sys.stdin)["cost_24h"])'))" >> "$LOG"
else
  echo "$(STAMP) mac-burn: push FAILED — dashboard value will go stale" >> "$LOG"
  exit 1
fi
