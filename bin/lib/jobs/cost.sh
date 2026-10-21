#!/bin/bash
# shellcheck shell=bash
# bin/lib/jobs/cost.sh — BH-1194: the metrics ledger — daily burn, non-Anthropic vendor spend, per-PR costs, the cost-row sweep, extra usage, runner-CLI versions, PR outcomes and CI flakes. Sourced by bin/jobs-client.sh (JC_MODULES), never run.

# --- Metrics ledger (2026-08-29) ---------------------------------------------
# the operator: "move things to the database instead of files". Four measurement series
# that only ever existed as CSVs on the hub's disk now also land as rows.
#
# THE CSV IS STILL WRITTEN FIRST AND IS STILL THE FALLBACK. Every one of these
# helpers is fail-open like the rest of this file: rc 1, no output, one line in
# jobs-client.log. A metrics script that died because a side channel blinked
# would be a worse outage than the one this whole wave exists to fix — the point
# is to be able to SEE the numbers from somewhere other than one box, not to
# make the measuring depend on the seeing.

# metric_burn <day> <api_calls> <fresh_in> <output> <cache_read> <cache_write> <usd> <peak> <avg>
#   Upsert on the DAY, which is carried in the row and never taken from a clock
#   at the far end. That is the whole bug this series had on the file side.
metric_burn() {
  local day="${1:-}" body
  [ -n "$day" ] || return 1
  body=$(jq -nc --arg d "$day" --arg a "${2:-}" --arg i "${3:-}" --arg o "${4:-}" \
    --arg cr "${5:-}" --arg cw "${6:-}" --arg u "${7:-}" --arg pk "${8:-}" --arg av "${9:-}" \
    --arg box "$JOBS_BOX" \
    '{day:$d,api_calls:$a,fresh_in:$i,output:$o,cache_read:$cr,cache_write:$cw,
      usd_equiv:$u,peak_cache_read:$pk,avg_cache_read:$av,actor:$box}' 2>/dev/null) || return 1
  _jobs_req POST /api/metrics/burn "$body" >/dev/null
}

# --- Non-Anthropic vendor spend (2026-09-14, cost fix 5) ---------------------
# bin/vendor-spend-pull.sh, hourly on the hub. One row per (vendor, ts): what a
# vendor's own API said we spent, or what we computed when it has no API to ask
# — xAI, Fireworks and Fly publish no billing endpoint at all (all three
# probed), so `kind` carries whether the number is the bill or our arithmetic
# and `status` carries whether we got an answer. logs/vendor-spend.csv stays the
# write-ahead copy, exactly like every other series here.
#
# metric_vendor_spend <vendor> <ts> <window_start> <window_end> <usd> <kind> \
#                     <status> <balance_usd> <cumulative_usd> <note> [raw-json]
#   Upsert on (vendor, ts), both carried in the row: a re-push after a failure
#   must be a no-op. EVERY numeric argument may be EMPTY and empty means "not
#   measured" all the way down to the column — an unmeasured vendor that lands
#   as 0.00 is a vendor nobody will ever notice we stopped watching.
metric_vendor_spend() {
  local vendor="${1:-}" ts="${2:-}" body
  [ -n "$vendor" ] && [ -n "$ts" ] || return 1
  body=$(jq -nc --arg v "$vendor" --arg t "$ts" --arg ws "${3:-}" --arg we "${4:-}" \
    --arg u "${5:-}" --arg k "${6:-}" --arg st "${7:-}" --arg b "${8:-}" \
    --arg c "${9:-}" --arg n "${10:-}" --arg raw "${11:-}" --arg box "$JOBS_BOX" \
    '{vendor:$v,ts:$t,window_start:$ws,window_end:$we,usd:$u,kind:$k,status:$st,
      balance_usd:$b,cumulative_usd:$c,note:$n,raw:$raw,actor:$box}' 2>/dev/null) || return 1
  _jobs_req POST /api/metrics/vendor-spend "$body" >/dev/null
}

# metric_vendor_spend_list [vendor] [since] [limit] — newest first, as TSV
#   (ts, vendor, usd, kind, status, balance_usd, note). `raw` is deliberately
#   NOT in the TSV: it is up to 8KB of vendor payload per row and this is the
#   readout a human runs, not a dump.
metric_vendor_spend_list() {
  local vendor="${1:-}" since="${2:-}" limit="${3:-200}" resp q
  q="?limit=$limit"
  [ -n "$vendor" ] && q="$q&vendor=$vendor"
  [ -n "$since" ] && q="$q&since=$since"
  resp=$(_jobs_req GET "/api/metrics/vendor-spend$q") || return 1
  printf '%s' "$resp" | jq -r '.vendor_spend[]? |
    [.ts,.vendor,(.usd//"" ),.kind,.status,(.balance_usd//""),(.note//"")] | @tsv' 2>/dev/null
}

# The CSV -> JSON step is its OWN function so the here-doc that carries the
# python is a plain command redirection and not a command substitution wearing
# one — `$(python3 - <<'EOF' ) ... EOF` closes the substitution on the first
# line and the here-doc never terminates.
_metric_pr_costs_json() { # _metric_pr_costs_json <csv>
  python3 - "$1" <<'PYEOF'
import csv, json, sys
# python's csv reader, so an embedded comma inside stage_breakdown/build_dirs is
# parsed rather than split, and the header is mapped by NAME — a column added to
# the rollup later cannot silently shift the mapping.
rows = []
keys = ["pr_url", "cost_usd", "input_toks", "output_toks",
        "cache_read", "cache_write", "stage_breakdown", "build_dirs"]
with open(sys.argv[1], newline="") as fh:
    rd = csv.DictReader(fh)
    # The account columns (2026-09-02) ride along ONLY when the file has them.
    # A rollup from before they existed keeps sending the eight it has, and
    # the worker leaves the two DB columns alone for a row that omits them.
    keys += [k for k in ("auth_account", "account_breakdown") if k in (rd.fieldnames or [])]
    for r in rd:
        if not (r.get("pr_url") or "").strip():
            continue
        rows.append({k: (r.get(k) or "") for k in keys})
# 2000 is the worker's per-request cap. cost-rollup writes the file priciest
# first, so a file that ever outgrows it loses the cheap tail nobody reads
# rather than the rows the readout is made of.
print(json.dumps({"rows": rows[:2000]}))
PYEOF
}

# metric_pr_costs <csv-file>
#   The whole cost-per-pr sweep in ONE request. bin/cost-rollup.sh rebuilds that
#   file from scratch each run, so the natural unit is the file, not the row, and
#   219 sequential curls from a cron script would make the side channel the work.
metric_pr_costs() {
  local csv="${1:-}" body
  [ -s "$csv" ] || return 1
  body=$(_metric_pr_costs_json "$csv" 2>/dev/null) || return 1
  [ -n "$body" ] || return 1
  _jobs_req POST /api/metrics/pr-costs "$body" >/dev/null
}

# ── model_prices: the fleet's one price table (BH-1032) ──────────────────────
# model_prices_put <prices-json> [source]
#   Upserts every model in a catalog/model-prices.json-shaped file into the
#   table. WHOLE-TABLE UPSERT, never a replace: a refresh that fetched fewer
#   models than last time must not un-price the ones it missed.
#   rc 0 on a 2xx, 1 otherwise. The caller owns the retry; this is a mirror of a
#   file that has already been written.
model_prices_put() {
  local f="${1:-}" src="${2:-openrouter}" body
  [ -s "$f" ] || return 1
  body=$(mktemp "${TMPDIR:-/tmp}/model-prices.XXXXXX") || return 1
  python3 - "$f" "$src" > "$body" <<'PYEOF' || { rm -f "$body"; return 1; }
import json, sys
t = json.load(open(sys.argv[1]))
# `if isinstance(...)`, never `t.get("per_token") or t`: an EMPTY per_token is
# falsy, so the `or` fell through to the envelope itself and pushed a row called
# "per_token". A table with no models has to come out as no rows (rc 1), or the
# "empty is not pass" guard below is a guard that never fires.
_p = t.get("per_token")
per = _p if isinstance(_p, dict) else (t if not isinstance(_p, dict) and "per_token" not in t else {})
RATES = ("prompt", "completion", "cache_read", "cache_write")
rows = []
for model, r in per.items():
    if not isinstance(r, dict):
        continue
    # A row with no rate at all is not a price, it is an envelope key that
    # wandered in. Skipping it is what keeps `updated_at`/`source` out of a
    # flat-shaped table.
    if not any(isinstance(r.get(k), (int, float)) and not isinstance(r.get(k), bool) for k in RATES):
        continue
    rows.append({"model": model, "slug": r.get("slug"),
                 "prompt": r.get("prompt"), "completion": r.get("completion"),
                 "cache_read": r.get("cache_read"), "cache_write": r.get("cache_write"),
                 "cliff_tokens": r.get("cliff_tokens")})
if not rows:
    sys.exit(1)
json.dump({"source": sys.argv[2], "rows": rows}, sys.stdout)
PYEOF
  _jobs_req_file POST /api/model-prices "$body" >/dev/null 2>&1
  local rc=$?
  rm -f "$body"
  return $rc
}

# price_fly_put <fly-prices-json> [source]
#   (BH-5652) Mirrors catalog/fly-prices.json into the price_fly table. The
#   whole file goes in the body; the worker keeps the numbers (top level and one
#   level down, as dotted keys) and bumps a key's version only when its value
#   changes. A file with no number in it is refused here (rc 1) before any
#   request: an empty mirror is not a seed. rc 0 on a 2xx, 1 otherwise.
price_fly_put() {
  local f="${1:-}" src="${2:-catalog}" body
  [ -s "$f" ] || return 1
  body=$(mktemp "${TMPDIR:-/tmp}/fly-prices.XXXXXX") || return 1
  python3 - "$f" "$src" > "$body" <<'PYEOF' || { rm -f "$body"; return 1; }
import json, sys
t = json.load(open(sys.argv[1]))
if not isinstance(t, dict):
    sys.exit(1)
num = lambda v: isinstance(v, (int, float)) and not isinstance(v, bool)
if not any(num(v) or (isinstance(v, dict) and any(num(w) for w in v.values())) for v in t.values()):
    sys.exit(1)
json.dump({"source": sys.argv[2], "prices": t}, sys.stdout)
PYEOF
  _jobs_req_file POST /api/fly-prices "$body" >/dev/null 2>&1
  local rc=$?
  rm -f "$body"
  return $rc
}

# model_slugs_put <model-slugs-json> [source]
#   (BH-5652) Mirrors catalog/model-slugs.json ({model: slug}) into the
#   model_slugs table. Only non-empty string values travel; a file with none is
#   refused here (rc 1). rc 0 on a 2xx, 1 otherwise.
model_slugs_put() {
  local f="${1:-}" src="${2:-catalog}" body
  [ -s "$f" ] || return 1
  body=$(mktemp "${TMPDIR:-/tmp}/model-slugs.XXXXXX") || return 1
  python3 - "$f" "$src" > "$body" <<'PYEOF' || { rm -f "$body"; return 1; }
import json, sys
t = json.load(open(sys.argv[1]))
if not isinstance(t, dict):
    sys.exit(1)
slugs = {k: v for k, v in t.items() if isinstance(v, str) and v}
if not slugs:
    sys.exit(1)
json.dump({"source": sys.argv[2], "slugs": slugs}, sys.stdout)
PYEOF
  _jobs_req_file POST /api/model-slugs "$body" >/dev/null 2>&1
  local rc=$?
  rm -f "$body"
  return $rc
}

# model_prices_get <out-file>
#   Writes the table to <out-file> in catalog/model-prices.json's own shape, so
#   it IS the file every reader already prefers. rc 0 only when the body parsed
#   and carried at least MODEL_PRICES_MIN (default 5) models: EMPTY IS NOT PASS
#   — overwriting a good local table with an empty one would make every row in
#   the fleet price at nothing, which reads identically to a free fleet.
model_prices_get() {
  local out="${1:-}" resp min="${MODEL_PRICES_MIN:-5}"
  [ -n "$out" ] || return 1
  resp=$(_jobs_req GET /api/model-prices 2>/dev/null) || return 1
  printf '%s' "$resp" | python3 -c '
import json, sys
try:
    b = json.load(sys.stdin)
except Exception:
    sys.exit(1)
per = b.get("per_token")
if not isinstance(per, dict) or len(per) < int(sys.argv[1]):
    sys.exit(1)
json.dump(b, open(sys.argv[2], "w"), indent=2)
' "$min" "$out.tmp.$$" || { rm -f "$out.tmp.$$"; return 1; }
  mv -f "$out.tmp.$$" "$out"
}

# model_prices_versions_merge <prices-json>
#   (BH-5652) Writes each model's D1 price `version` into <prices-json>, the
#   hub's own state/model-prices.json. The hub WRITES that file from OpenRouter
#   and pushes it (model_prices_put), so it never pulls the table back and its
#   rows had no version: every hub cost row lacked `price_v:`. Run after a good
#   push. A model gets the D1 version only when its four rates equal the D1
#   row's; otherwise any version key it has is dropped, because a version that
#   names other rates is worse than none. rc 0 when the file was rewritten, 1
#   otherwise (the file is then left as it was).
model_prices_versions_merge() {
  local f="${1:-}" resp
  [ -s "$f" ] || return 1
  resp=$(_jobs_req GET /api/model-prices 2>/dev/null) || return 1
  printf '%s' "$resp" | python3 -c '
import json, sys
try:
    db = json.load(sys.stdin).get("per_token")
    t = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
per = t.get("per_token") if isinstance(t, dict) else None
if not isinstance(db, dict) or not isinstance(per, dict):
    sys.exit(1)
RATES = ("prompt", "completion", "cache_read", "cache_write")
for m, r in per.items():
    if not isinstance(r, dict):
        continue
    r.pop("version", None)
    d = db.get(m)
    if not isinstance(d, dict):
        continue
    v = d.get("version")
    if isinstance(v, int) and not isinstance(v, bool) and v > 0 \
       and all(r.get(k) == d.get(k) for k in RATES):
        r["version"] = v
json.dump(t, open(sys.argv[2], "w"), indent=2)
' "$f" "$f.tmp.$$" || { rm -f "$f.tmp.$$"; return 1; }
  mv -f "$f.tmp.$$" "$f"
}

# model_price_source_set <model> <vendor-direct|openrouter>
#                        [prompt completion [cache_read [cache_write [cliff_tokens]]]]
#   (BH-1613, BH-1754) Marks one model_prices row's price source. vendor-direct
#   makes the daily refresh price that model at the vendor's own rate: the rates
#   given here, stored on the row in D1, or the committed catalog row when the
#   row has none. Rates are per token and only go with vendor-direct; a cache
#   rate given as "" is stored empty, and the refresh then takes that rate (and
#   an unset cliff) from the catalog row. Marking vendor-direct with no rates keeps
#   any rates already stored. openrouter clears the mark AND the stored rates.
#   Every argument is checked here and a bad one answers rc 2 with no request
#   sent. rc 0 on a 2xx, 1 otherwise (including 404: the model has no row in
#   model_prices).
model_price_source_set() {
  local model="${1:-}" ps="${2:-}" usage="usage: model-price-source <model> <vendor-direct|openrouter> [prompt completion [cache_read [cache_write [cliff_tokens]]]]"
  if [ -z "$model" ] || { [ "$ps" != vendor-direct ] && [ "$ps" != openrouter ]; } \
     || [ "$#" = 3 ] || [ "$#" -gt 7 ] || { [ "$#" -gt 2 ] && [ "$ps" != vendor-direct ]; }; then
    echo "$usage" >&2
    return 2
  fi
  local body
  body=$(jq -nc --arg m "$model" --arg p "$ps" '{model:$m, price_source:$p}')
  if [ "$#" -gt 2 ]; then
    body=$(jq -nce --argjson b "$body" --args '
      def rate: tonumber | if . > 0 then . else error("not > 0") end;
      def opt: if . == "" then null else rate end;
      $ARGS.positional as $a
      | $b + {vendor: ({prompt: ($a[0] | rate), completion: ($a[1] | rate)}
          + (if ($a | length) > 2 then {cache_read: ($a[2] | opt)} else {} end)
          + (if ($a | length) > 3 then {cache_write: ($a[3] | opt)} else {} end)
          + (if ($a | length) > 4 then {cliff_tokens: ($a[4] | opt
              | if . == null or . == floor then . else error("not an integer") end)} else {} end))}' \
      "${@:3}" 2>/dev/null) || { echo "$usage (rates must be numbers > 0)" >&2; return 2; }
  fi
  _jobs_req PUT /api/model-prices/source "$body" || return 1
}

# ── Raw cost rows (2026-09-02) ───────────────────────────────────────────────
# logs/cost.csv on every box STAYS the write-ahead source of truth: agent-call.sh
# appends a row per attempt and nothing here changes that. This mirrors the rows
# into the worker's cost_rows table so a question like "what did account X
# spend this week, fleet-wide" is one SQL query instead of nine ssh sessions.
#
# _metric_cost_rows_chunk <csv> <from-line> <max-rows> <box> <out-json>
#   Reads cost.csv from file line <from-line>+1 (the header is line 1, so a
#   cursor of 0 means "nothing pushed yet"), maps up to <max-rows> data rows
#   onto the CANONICAL 23-column header from bin/lib/cost-row.sh and writes the
#   request body to <out-json>. Prints the line number of the LAST line it
#   consumed, or nothing when there is nothing left. The mapping is by POSITION,
#   not by the file's own header, because a 13- or 14-column file (pre-#173)
#   names fewer columns than its rows may carry after an upgrade; the trailing
#   fields a short row lacks go out as null. Header lines, blank lines and rows
#   of an impossible width are skipped but still advance the cursor.
#
#   THE WIDTH CEILING IS THE TOLERANCE (2026-09-14, widened again in BH-1032
#   when `note` joined the list). It was `len(f) > 16:
#   continue`, and the transcript wave appends seven columns — session_id,
#   row_source, result_usd and the ticket/job/pr/run tags — so on the day the
#   boxes sync, EVERY new row would have been skipped here while the cursor
#   marched past it. Silently: a skipped row still advances, so the DB mirror
#   would have gone quiet with no failure to alert on. The ceiling now tracks
#   the canonical width, and a row wider still is a box running ahead of this
#   client rather than a corrupt line, so its KNOWN columns are taken and the
#   rest dropped instead of the whole row.
#   row_hash is sha256 of the raw line: byte-identical rows collapse onto one
#   PK exactly the way `sort -u` collapses them in fleet-cost.csv.
_metric_cost_rows_chunk() {
  python3 - "$1" "$2" "$3" "$4" "$5" <<'PYEOF'
import csv, hashlib, itertools, json, os, sys
path, start, limit, box, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5]
allow = set(os.environ.get("COST_ROWS_ALLOW", "").split())
drop_log = os.environ.get("COST_ROWS_DROP_LOG", "")
# The 26 names (guard_fp, BH-2537) bin/lib/cost-row.sh writes (COST_ROW_HDR), in order (lane_id, BH-2303). Not read from
# the live file on purpose: the file's header lags its rows on a box whose
# upgrade has not run, and the DB columns are fixed either way.
#
# `note` was MISSING here until BH-1032 (2026-09-20) while agent-call.sh had
# been writing it since BH-656 — so the one column that says "this lane paid
# claude instead of a doubled grok" was truncated away on the mirror's own
# `f[:len(COLS)]` line, silently, on every row. The list is the header's width
# or rows lose columns; that is the whole reason it is a literal.
COLS = ["ts", "host", "project", "stage", "runner", "model", "rc", "duration_s",
        "input_toks", "output_toks", "cache_read", "cache_write", "cost_usd",
        "billing_mode", "auth_fp", "auth_account",
        "session_id", "row_source", "result_usd", "ticket", "job_id", "pr",
        "run_id", "note", "lane_id", "guard_fp"]
rows, last = [], start
with open(path, newline="", errors="replace") as fh:
    for n, line in enumerate(itertools.islice(fh, start, None), start + 1):
        raw = line.rstrip("\r\n")
        last = n
        if not raw.strip() or raw.startswith("ts,host,"):
            continue
        f = next(csv.reader([raw]))
        if len(f) < 13:
            continue
        # BH-3223: a test fixture row is skipped like a blank line — the
        # cursor still moves past it, so it never reaches the DB and never
        # wedges the mirror.
        # BH-3982: with $COST_ROWS_ALLOW set, a row whose project is not one
        # of its words (exact, case-sensitive) is skipped the same way and
        # its project appended to $COST_ROWS_DROP_LOG. Unset: no filter.
        if f[2] == "testproj":
            continue
        if allow and f[2] not in allow:
            if drop_log:
                try:
                    with open(drop_log, "a") as dl:
                        dl.write(f[2] + "\n")
                except OSError:
                    pass
            continue
        f = (f + [None] * len(COLS))[:len(COLS)]
        r = dict(zip(COLS, f))
        r["line_no"] = n
        r["row_hash"] = hashlib.sha256(raw.encode("utf-8", "replace")).hexdigest()
        # The verbatim line rides along (BH-1032), so a reader can re-emit the
        # row exactly as the box wrote it instead of reconstructing it from
        # REAL/INTEGER columns — which is the difference between a fleet file
        # that equals the boxes' files and one that only sums the same.
        r["raw"] = raw
        rows.append(r)
        if len(rows) >= limit:
            break
if last <= start:
    sys.exit(0)
# A chunk that consumed only header/blank/odd lines has nothing to send; the
# body file stays empty and the caller just advances the cursor past them.
if rows:
    with open(out, "w") as fh:
        json.dump({"box": box, "rows": rows}, fh)
print(last, len(rows))
PYEOF
}

# metric_cost_rows <csv> <cursor-file> [box]
#   Pushes every row after the cursor, <=2000 per request, looping until the
#   file is caught up. The cursor (a file line number) advances ONLY after a
#   2xx, so a run that dies mid-way resumes from the last chunk that landed,
#   and the PK (box, row_hash) makes re-sending that chunk a no-op. A cursor
#   past the end of the file means the file was rotated or truncated: it resets
#   to 0 and the whole file is re-offered, which the PK also absorbs.
#   The body goes through _jobs_req_file: 2000 rows is ~400KB, well past what
#   an argv element may carry.
#   Prints "<rows-pushed> <cursor> <inserted>" on success (rc 0, "0 <cursor> 0"
#   when there was nothing new); rc 1 on the first failed request, cursor left
#   where the last success put it.
#   <inserted> (2026-09-14) is how many of those rows the worker reported as
#   NEW; rows-pushed minus it is the dup count. The worker has always answered
#   {accepted, inserted} and this function threw the body away, so the one
#   number that proves the (box, row_hash) PK absorbed a re-push was unreadable
#   from bash — and the pool-machine lane needs exactly that: a reap whose rows
#   all come back dup is a reap saying the dying machine's own loop had already
#   landed its bill (see bin/cost-rows-push.sh --box / --verify).
metric_cost_rows() {
  local csv="${1:-}" cur="${2:-}" box="${3:-$JOBS_BOX}" from last n body pushed=0 lines resp ins inserted=0
  [ -s "$csv" ] && [ -n "$cur" ] || return 1
  from=$(tr -dc '0-9' < "$cur" 2>/dev/null); from="${from:-0}"
  lines=$(wc -l < "$csv" 2>/dev/null | tr -dc '0-9'); lines="${lines:-0}"
  if [ "$from" -gt "$lines" ]; then
    _jobs_log "cost-rows cursor $from is past the end of $csv ($lines lines) — file rotated? resetting to 0"
    from=0
  fi
  body=$(mktemp "${TMPDIR:-/tmp}/cost-rows.XXXXXX") || return 1
  # The answer goes to a FILE, not a command substitution: $(_jobs_req_file ...)
  # would run the request in a subshell and $JOBS_HTTP — which the caller logs
  # to tell a 500 from an outage — would never make it back out.
  resp=$(mktemp "${TMPDIR:-/tmp}/cost-rows-resp.XXXXXX") || { rm -f "$body"; return 1; }
  while :; do
    read -r last n < <(_metric_cost_rows_chunk "$csv" "$from" 2000 "$box" "$body" 2>/dev/null) || last=""
    [ -n "${last:-}" ] && [ "$last" -gt "$from" ] 2>/dev/null || break
    if [ "${n:-0}" -gt 0 ] && [ -s "$body" ]; then
      _jobs_req_file POST /api/metrics/cost-rows "$body" > "$resp" || { rm -f "$body" "$resp"; return 1; }
      pushed=$((pushed + n))
      # sed, not jq: this runs on Fly pool machines as well as on every box, and
      # the count is an accounting detail that must never be the reason a push
      # fails. An unparseable body simply adds nothing.
      ins=$(sed -n 's/.*"inserted":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$resp" | head -1)
      inserted=$((inserted + ${ins:-0}))
    fi
    from=$last
    # Atomic: a cursor file that is half a number is a cursor that re-pushes
    # from 0 next run. Harmless with the PK, but not what "resumable" means.
    printf '%s\n' "$from" > "$cur.tmp.$$" && mv -f "$cur.tmp.$$" "$cur"
    : > "$body"
  done
  rm -f "$body" "$resp"
  echo "$pushed $from $inserted"
}

# metric_extra_usage <box> <ts> <session_pct> <weekly_pct> <resets_at> <enabled> <used_usd> <slr> <overage> [limit_usd] [extra_pct] [status] [error_body]
#   One row per poll. The box is passed EXPLICITLY rather than defaulted to
#   $JOBS_BOX: this series is per subscription ACCOUNT, and the ACCOUNT LABEL is
#   what the caller knows (a box may hold two logins — see
#   bin/extra-usage-track.sh), so the caller's own idea of who it is outranks a
#   name resolved from a file.
#
#   The last three are optional and additive (2026-09-14): the extra-usage CAP
#   the meter is measured against, its utilization, and status — ok | no-login |
#   error. A FAILED poll posts a row too, with empty numbers and a status: a
#   login that cannot read its meter and a box whose cron is dead were the same
#   absence in this table, and only one of them is fixable by provisioning a
#   login. An older client that sends nine arguments binds them NULL and keeps
#   working unchanged.
#
#   error_body (BH-3985) is what the vendor answered on a failed poll, scrubbed
#   of credentials by the caller. Empty on an ok poll.
metric_extra_usage() {
  local box="${1:-}" ts="${2:-}" body
  [ -n "$box" ] && [ -n "$ts" ] || return 1
  body=$(jq -nc --arg b "$box" --arg t "$ts" --arg s "${3:-}" --arg w "${4:-}" \
    --arg r "${5:-}" --arg e "${6:-}" --arg u "${7:-}" --arg l "${8:-}" --arg o "${9:-}" \
    --arg lim "${10:-}" --arg p "${11:-}" --arg st "${12:-}" --arg eb "${13:-}" \
    '{box:$b,ts:$t,session_pct:$s,weekly_pct:$w,weekly_resets_at:$r,
      extra_enabled:$e,extra_used_usd:$u,spend_limit_reached:$l,in_overage:$o,
      extra_limit_usd:$lim,extra_pct:$p,status:$st,error_body:$eb}' 2>/dev/null) || return 1
  _jobs_req POST /api/metrics/extra-usage "$body" >/dev/null
}

# --- runner-CLI versions (2026-09-06, bin/cli-update.sh + bin/cli-version-check.sh)
# Every daily update on every box and every hub sweep lands its before/after
# versions here, so "which box is behind" is one query and a model bump can be
# checked against the fleet before it strands a box (the project-9 2.1.250 week).
# logs/cli-versions.csv on the box stays the write-ahead copy.
#
# metric_cli_version <box> <cli> <before> <after> <method> <ok> <at> [path] [note] [source]
#   One row. source is "update" (the box's own daily run) or "check" (the hub's
#   ssh sweep, where before == after == what it observed).
metric_cli_version() {
  local box="${1:-}" cli="${2:-}" at="${7:-}" body
  [ -n "$box" ] && [ -n "$cli" ] && [ -n "$at" ] || return 1
  body=$(jq -nc --arg b "$box" --arg c "$cli" --arg vb "${3:-}" --arg va "${4:-}" --arg m "${5:-}"     --arg ok "${6:-}" --arg t "$at" --arg p "${8:-}" --arg n "${9:-}" --arg s "${10:-update}"     '{rows:[{box:$b,cli:$c,version_before:$vb,version_after:$va,method:$m,ok:$ok,at:$t,path:$p,note:$n,source:$s}]}' 2>/dev/null) || return 1
  _jobs_req POST /api/metrics/cli-versions "$body" >/dev/null
}

# metric_cli_versions <rows-json-file>
#   A batch: the file is the request body, {"rows":[{box,cli,version_before,
#   version_after,method,ok,at,path,note,source}, ...]} — the hub's sweep sends
#   the whole fleet in one request. Idempotent at the far end: the PK is
#   (box, cli, at, source), so a resend after a failure inserts nothing twice.
metric_cli_versions() {
  local file="${1:-}"
  [ -s "$file" ] || return 1
  _jobs_req_file POST /api/metrics/cli-versions "$file" >/dev/null
}

# metric_cli_versions_list [limit] [box] — newest rows first, as TSV
#   (at, box, cli, version_before, version_after, method, ok, source).
metric_cli_versions_list() {
  local limit="${1:-200}" box="${2:-}" resp q
  case "$limit" in ''|*[!0-9]*) limit=200 ;; esac
  q="/api/metrics/cli-versions?limit=$limit"
  [ -n "$box" ] && q="$q&box=$(printf '%s' "$box" | tr -dc 'A-Za-z0-9._-')"
  resp=$(_jobs_req GET "$q") || return $?
  printf '%s' "$resp" | jq -r '.cli_versions[]? | [ .at, .box, .cli, (.version_before // "-"), (.version_after // "-"), (.method // "-"), (.ok // "-"), (.source // "-") ] | @tsv' 2>/dev/null
}

# metric_outcomes <repo> <pr> <outcome> <day> <evidence> [repairs]
#   One finding. bin/outcome-metrics.sh emits a handful a week, so per-row is the
#   honest unit here — and a partial push leaves the rows it did land, which for
#   an upsert keyed on (repo, pr, outcome) is exactly recoverable on the next run.
#
#   `repairs` (SDLC item 3) is the repair-round count the BUILD recorded for this
#   PR, carried onto the outcome so the question "do builds that had to be fixed
#   twice get reverted more often" is one query instead of a join across two
#   ledgers. APPENDED and optional: an older client omits it, the worker binds
#   NULL and its COALESCE keeps whatever a newer push already wrote, so a repo
#   that has not synced bin/ cannot blank a count.
metric_outcomes() {
  local repo="${1:-}" pr="${2:-}" outcome="${3:-}" day="${4:-}" evidence="${5:-}" repairs="${6:-}" body
  [ -n "$repo" ] && [ -n "$pr" ] && [ -n "$outcome" ] || return 1
  case "$repairs" in ''|*[!0-9]*) repairs="" ;; esac
  body=$(jq -nc --arg r "$repo" --arg p "$pr" --arg o "$outcome" --arg d "$day" --arg e "$evidence" \
    --arg rp "$repairs" \
    '{repo:$r,pr:$p,outcome:$o}
     + (if $d == "" then {} else {day:$d} end)
     + (if $e == "" then {} else {evidence:$e} end)
     + (if $rp == "" then {} else {repairs:($rp|tonumber)} end)' 2>/dev/null) || return 1
  _jobs_req POST /api/metrics/outcomes "$body" >/dev/null
}

# metric_outcomes_list [limit] — read the outcome findings back out of the
#   metrics ledger as TSV (repo, pr, outcome, day, repairs). The write side above
#   is what bin/outcome-metrics.sh pushes; this is the read bin/review-tighten.sh
#   measures from, DB-first with logs/outcome-metrics.csv as its own fallback.
#   repairs is APPENDED (SDLC item 3) and prints "-" on a row written before the
#   column existed, so a reader of the first four fields is unchanged.
metric_outcomes_list() {
  local limit="${1:-1000}" resp
  case "$limit" in ''|*[!0-9]*) limit=1000 ;; esac
  resp=$(_jobs_req GET "/api/metrics/outcomes?limit=$limit") || return $?
  printf '%s' "$resp" | jq -r '.outcomes[]? | [ .repo, .pr, .outcome, (.day // "-"),
    (if (.repairs // null) == null then "-" else (.repairs|tostring) end) ] | @tsv' 2>/dev/null
}

# --- Flaky CI (2026-09-12) ---------------------------------------------------
# metric_flake <repo> <workflow> <test> <head> [day] [kind]
#   One classified RED. The key is (repo, workflow, test, head) — the HEAD, not
#   the run — because a head that was re-run nine times is one piece of evidence
#   about one test, and a run-keyed ledger would let a single bad afternoon
#   quarantine a healthy test. Re-running bin/flaky-detect.sh over the same
#   window therefore upserts the identical keys and changes no count.
#
#   `kind` is flake | red, and both belong here: flaky reds OVER ALL reds is the
#   measure anyone acts on, and a denominator kept in a different table is a
#   denominator that stops matching its numerator. Defaults to flake so a caller
#   that only knows about flakes cannot accidentally write a red as one.
metric_flake() {
  local repo="${1:-}" wf="${2:-}" test="${3:-}" head="${4:-}" day="${5:-}" kind="${6:-flake}" body
  [ -n "$repo" ] && [ -n "$wf" ] && [ -n "$test" ] && [ -n "$head" ] || return 1
  case "$kind" in flake|red) ;; *) kind=flake ;; esac
  body=$(jq -nc --arg r "$repo" --arg w "$wf" --arg t "$test" --arg h "$head" \
    --arg d "$day" --arg k "$kind" \
    '{repo:$r,workflow:$w,test:$t,head:$h,kind:$k}
     + (if $d == "" then {} else {day:$d} end)' 2>/dev/null) || return 1
  _jobs_req PUT /api/metrics/flakes "$body" >/dev/null
}

# metric_flakes_list [limit] [repo] [since] — newest first, as TSV
#   (day, repo, workflow, test, head, kind). This is the read bin/lib/flaky.sh
#   builds its known-flake set from, bin/flaky-quarantine.sh proposes from, and
#   bin/pipeline-health.sh measures the 7d rate from. Field ORDER is contract:
#   three consumers read it positionally.
metric_flakes_list() {
  local limit="${1:-1000}" repo="${2:-}" since="${3:-}" q resp
  case "$limit" in ''|*[!0-9]*) limit=1000 ;; esac
  q="/api/metrics/flakes?limit=$limit"
  [ -n "$repo" ] && q="$q&repo=$(printf '%s' "$repo" | tr -dc 'A-Za-z0-9._/-')"
  [ -n "$since" ] && q="$q&since=$(printf '%s' "$since" | tr -dc '0-9-')"
  resp=$(_jobs_req GET "$q") || return $?
  printf '%s' "$resp" | jq -r '.flakes[]? | [ (.day // "-"), .repo, .workflow, .test, .head, (.kind // "flake") ] | @tsv' 2>/dev/null
}

# --- BH-2517: CI health (flaky_quarantine*, ci_health in worker/jobs/schema.sql)
# The worker routes below are sibling slices of BH-2517 and are NOT deployed
# yet: until they land every call here gets a 404 and returns non-zero. The
# quarantine wire shapes:
#   PUT /api/metrics/flakes/quarantine body {repo, test, active: 0|1, reason, actor}
#     answers {ok, row, changed}
#   GET /api/metrics/flakes/quarantine?repo=&active=1
#     answers {rows:[{repo,test,active,actor,reason,updated_at}], truncated}
#   GET /api/metrics/flakes/quarantine/changes?repo=&test=&limit=
#     answers {changes:[{id,repo,test,before_active,after_active,actor,reason,at}]}
#
# metric_flake_quarantine_list <repo> — the active quarantine set for one repo,
#   one test name per line from .rows[].test (a row with no test is skipped).
#   The repo is cut to [A-Za-z0-9._/-]; an empty result is rc 1 with no request,
#   never an unscoped fleet-wide list. A transport failure or 404 is non-zero
#   with no output, and a caller must read that as "unknown", an empty set that
#   forgives no extra reds, never as "nothing quarantined".
metric_flake_quarantine_list() {
  local repo="${1:-}" resp
  repo=$(printf '%s' "$repo" | tr -dc 'A-Za-z0-9._/-')
  [ -n "$repo" ] || return 1
  resp=$(_jobs_req GET "/api/metrics/flakes/quarantine?repo=$repo&active=1") || return $?
  printf '%s' "$resp" | jq -r '.rows[]?.test // empty' 2>/dev/null
}

# metric_flake_quarantine_rows <repo> — EVERY quarantine row for one repo, active
#   or not (no active filter), as TSV: test, active (1|0), actor, updated_at,
#   reason (BH-3686). Tabs and newlines in reason become spaces, and an empty
#   actor, updated_at or reason prints as `-` so a tab-IFS read keeps its
#   columns. A row with no test, or an active that is not true/false/1/0, is
#   dropped. The repo is cut as in metric_flake_quarantine_list. A transport
#   failure, a body that is not JSON, or one with no .rows array is non-zero
#   with NO output: "unknown", never "empty".
metric_flake_quarantine_rows() {
  local repo="${1:-}" resp out
  repo=$(printf '%s' "$repo" | tr -dc 'A-Za-z0-9._/-')
  [ -n "$repo" ] || return 1
  resp=$(_jobs_req GET "/api/metrics/flakes/quarantine?repo=$repo") || return $?
  out=$(printf '%s' "$resp" | jq -er '
    if (.rows | type) == "array" then . else error("no rows") end
    | .rows[]
    | select((.test // "") != "")
    | (if .active == true or .active == 1 then "1" elif .active == false or .active == 0 then "0" else empty end) as $a
    | [ .test, $a,
        ((.actor // "") | if . == "" then "-" else . end),
        ((.updated_at // "") | if . == "" then "-" else . end),
        ((.reason // "") | gsub("[\t\r\n]"; " ") | if . == "" then "-" else . end) ]
    | @tsv' 2>/dev/null)
  # -e is rc 4 on no output at all: an empty .rows is an answer, not a failure.
  case $? in 0|4) ;; *) return 1 ;; esac
  [ -z "$out" ] || printf '%s\n' "$out"
}

# metric_flake_quarantine_put <repo> <test> <active 0|1> <reason> <actor> —
#   set one quarantine row through the PUT shape above. Repo (cut as above),
#   test and actor must be non-empty and active 0 or 1, else rc 1 with no
#   request. Prints nothing; the rc is _jobs_req's.
metric_flake_quarantine_put() {
  local repo="${1:-}" test="${2:-}" active="${3:-}" reason="${4:-}" actor="${5:-}" body
  repo=$(printf '%s' "$repo" | tr -dc 'A-Za-z0-9._/-')
  [ -n "$repo" ] && [ -n "$test" ] && [ -n "$actor" ] || return 1
  case "$active" in 0|1) ;; *) return 1 ;; esac
  body=$(jq -nc --arg r "$repo" --arg t "$test" --arg a "$active" --arg w "$reason" --arg c "$actor" \
    '{repo:$r,test:$t,active:($a|tonumber),reason:$w,actor:$c}' 2>/dev/null) || return 1
  _jobs_req PUT /api/metrics/flakes/quarantine "$body" >/dev/null
}

# ci_health_put <repo> <metric> <payload-json> — upsert the newest snapshot for
#   (repo, metric). The ci-health wire shapes:
#   PUT /api/ci-health body {repo, metric: 'minutes'|'runners', payload: object, box}
#   GET /api/ci-health?repo= answers {rows:[{repo,metric,payload,box,as_of}], as_of}
#   box is $(hostname). A payload that is not JSON fails jq, so nothing is sent
#   and rc is 1. Non-zero on any failure (404 before the route lands included);
#   callers treat the write as best-effort.
ci_health_put() {
  local repo="${1:-}" metric="${2:-}" payload="${3:-}" body
  [ -n "$repo" ] && [ -n "$metric" ] && [ -n "$payload" ] || return 1
  body=$(jq -nc --arg r "$repo" --arg m "$metric" --argjson p "$payload" --arg b "$(hostname 2>/dev/null)" \
    '{repo:$r,metric:$m,payload:$p,box:$b}' 2>/dev/null) || return 1
  _jobs_req PUT /api/ci-health "$body" >/dev/null
}


# --- K3: the pre-call guard's counter (worker/jobs/src/routes/call-guard.js) -
# bin/lib/call-guard.sh asks BEFORE bin/agent-call.sh spends anything: how many
# paid calls has this (project, stage, fingerprint) had inside the window? The
# worker records the call and answers allowed:true, or refuses it (allowed:
# false, a 200 — an ANSWER). Unlike the rest of this file, the caller does NOT
# treat an outage as "carry on": for a metered runner an unreadable counter
# refuses the call (bin/lib/call-guard.sh decides that, not this transport).
#
# call_guard_claim <project> <stage> <fp> <call-id> <max> <window-s> [runner]
#   rc 0 and the answer JSON on stdout when the worker ANSWERED (read
#   .allowed); rc 1 and nothing when it did not (transport, non-2xx, a 404 from
#   a worker that has no such route, or a body that is not the answer).
#   rc 2 when the worker answered 404 "unknown endpoint": the route is NOT
#   DEPLOYED there (a box synced ahead of the worker). The guard reads that as
#   `unconfigured`, never as an outage (K3 review: deploy order).
#   [force] = 1 records the call as paid even at the ceiling
#   (AGENT_CALL_GUARD_FORCE, for hand-run paths).
call_guard_claim() {
  local body resp rc f
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ] && [ -n "${4:-}" ] || return 1
  body=$(jq -nc --arg p "$1" --arg s "$2" --arg f "$3" --arg c "$4" \
    --arg m "${5:-0}" --arg w "${6:-86400}" --arg r "${7:-}" --arg b "$JOBS_BOX" --arg fo "${8:-0}" \
    '{project:$p,stage:$s,fp:$f,call_id:$c,max:($m|tonumber? // 0),
      window_s:($w|tonumber? // 86400),runner:$r,box:$b,force:($fo=="1")}' 2>/dev/null) || return 1
  # Not inside $( ): JOBS_HTTP / JOBS_BODY are set in THIS shell by _jobs_req,
  # and the 404-vs-outage call below needs them.
  f=$(mktemp "${TMPDIR:-/tmp}/cg-claim.XXXXXX") || return 1
  _jobs_req POST /api/call-guard/claim "$body" > "$f"; rc=$?
  resp=$(cat "$f" 2>/dev/null); rm -f "$f"
  if [ "$rc" -ne 0 ]; then
    [ "$rc" = 2 ] && [ "$JOBS_HTTP" = 404 ] \
      && printf '%s' "$JOBS_BODY" | jq -e '.worker == "harness-jobs"' >/dev/null 2>&1 && return 2
    return 1
  fi
  printf '%s' "$resp" | jq -e '(.allowed|type) == "boolean"' >/dev/null 2>&1 || return 1
  printf '%s' "$resp"
}

# call_guard_settle <call-id> <ok|empty|failed|unbilled>
#   rc 0 when the worker answered. A lost settle leaves the row `claimed`, which
#   COUNTS as paid: the conservative way round.
call_guard_settle() {
  local body
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  body=$(jq -nc --arg c "$1" --arg o "$2" '{call_id:$c,outcome:$o}' 2>/dev/null) || return 1
  _jobs_req POST /api/call-guard/settle "$body" >/dev/null
}

# call_guard_reset <project> <stage> <fp> [reason] — an operator's "this work
#   may be bought again": the key's paid rows stop counting, and the worker
#   writes an audit row naming this box and the reason. rc 0 + the answer JSON.
call_guard_reset() {
  local q
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ] || return 1
  q="project=$(jq -rn --arg v "$1" '$v|@uri')&stage=$(jq -rn --arg v "$2" '$v|@uri')&fp=$(jq -rn --arg v "$3" '$v|@uri')"
  q="$q&actor=$(jq -rn --arg v "$JOBS_BOX" '$v|@uri')&reason=$(jq -rn --arg v "${4:-manual reset}" '$v|@uri')"
  _jobs_req DELETE "/api/call-guard?$q"
}

# call_guard_list [project] [stage] [hours] [fp] — the per-fingerprint roll-up, for
# an operator (`bin/jobs-client.sh call-guard ...`); [fp] (BH-7792) is one key's row.
call_guard_list() {
  local q="hours=${3:-24}"
  [ -n "${1:-}" ] && q="$q&project=$(jq -rn --arg v "$1" '$v|@uri')"
  [ -n "${2:-}" ] && q="$q&stage=$(jq -rn --arg v "$2" '$v|@uri')"
  [ -n "${4:-}" ] && q="$q&fp=$(jq -rn --arg v "$4" '$v|@uri')"
  _jobs_req GET "/api/call-guard?$q"
}
