#!/bin/bash
# bin/lib/cost-row.sh — the ONE writer for a logs/cost.csv row, and the tags
# that say WHICH run, job, ticket and PR a row belongs to (cost fixes 1/2/7,
# 2026-09-14).
#
# WHY THIS FILE EXISTS. cost_append lived inside bin/agent-call.sh, so a lane
# that called `claude` directly could not reuse it and shipped either no row at
# all (greenfield, orchestrate) or a hand-rolled one that drifted (box-chat's
# row carried tokens but an EMPTY cost_usd for as long as it existed). A second
# copy of a ledger writer is a second place for the ledger to be wrong, so the
# function moved here and every caller — agent-call.sh, claude-cost.sh —
# sources it. tests/cost-append-test.sh extracts it from THIS file now.
#
# THE ROW. 26 columns; the first 16 are byte-identical to what agent-call.sh has
# always written, so every existing reader keeps working:
#
#   ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,
#   cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,
#   session_id,row_source,result_usd,ticket,job_id,pr,run_id,note,lane_id,
#   guard_fp
#
#   session_id  the claude --session-id the call ran under, i.e. the exact
#               transcript this row was priced from. Without it a row is a
#               number nobody can re-derive.
#   row_source  transcript | result | none — WHERE the token counts came from.
#               `transcript` is the per-message sum out of the session jsonl and
#               is the number to trust; `result` is the CLI's own .usage from
#               the --output-format json envelope (only the last turn, as this
#               wave measured); `none` is a row whose call died before either
#               existed, which is still a row (rc, duration, who paid) rather
#               than a call that never happened.
#               BH-3602, an --advisor call on the envelope path: executor rows
#               `result-net-advisor` (total minus the advisor's modelUsage
#               share), `result-incl-advisor` (total holds it, no advisor row),
#               `result-adv-unverified` (could not be split, total kept); the
#               advisor row `result-modelusage` (that share, session-wide).
#               `killed` (BH-3990): the context meter stopped a call that had
#               already started; the tokens are whatever the transcript held
#               (blank when it could not be read). `refused`: stopped BEFORE
#               any vendor call, zeros. `unbilled`: a failed canary that
#               bought nothing. `settled`: the triage no-signal settle (BH-2604).
#   result_usd  the envelope's .total_cost_usd, kept beside cost_usd so the two
#               readings stay comparable instead of one silently replacing the
#               other. agent-call.sh logs one line when they differ by >20%.
#   ticket/job_id/pr/run_id  the attribution tags, from COST_KEY/COST_JOB/
#               COST_PR/COST_RUN_ID (see cost_row_tags).
#   note        free text about how this row came to be, empty on almost every
#               row. Today it carries exactly one thing:
#               `cliff-routed:grok:<projected>><cliff>` on the row the rung
#               BELOW grok wrote after a call was routed past the xAI 200K cliff
#               (BH-656) — so "this lane paid claude instead of a doubled grok"
#               is a fact in the ledger rather than an inference from an absence.
#
#   lane_id     (BH-2303) the LANE this call was spent by: $AGENT_CALL_LANE when
#               the lane says so, else the lane the pre-call gate resolved
#               (bin/lib/llm-gate.sh). It is what a lane's LLM_USD_CAP_DAY sums,
#               so three lanes that share stage=review stop sharing one cap.
#
#   guard_fp    (K3, BH-2537) the pre-call guard's input fingerprint, from
#               $COST_GUARD_FP (see cost_row_guard_fp). bin/agent-call.sh sets
#               it on every row it writes (BH-2666), and a refused row carries
#               $CG_FP (bin/lib/llm-gate.sh); every other writer leaves it empty.
#
# APPEND-ONLY, AT THE END: a reader that slices by position keeps reading the
# same field. The four `$NF` readers that did NOT (run-build's COST_LINE,
# run-triage's summary, run-product's spend line, builder-direct's per-build
# cost) were moved to $13 in the same wave — $NF is a position that moves, and
# every one of them meant cost_usd.

# The canonical header. Readers that need the names (bin/cost-rollup.sh's
# fleet-cost.csv, bin/jobs-client.sh's push) carry their own copy on purpose —
# a box whose header upgrade has not run yet must not make them guess.
COST_ROW_HDR="ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note,lane_id,guard_fp"

# >>> cost_append (tests/cost-append-test.sh runs this function)
# Appends $1 to $COST. Reads $COST and $HARNESS from the caller, unchanged from
# when this lived in agent-call.sh.
cost_append() {
  local row="$1"
  if command -v flock >/dev/null 2>&1; then
    # 75 means ONLY "the lock was not acquired". The first version exited 0
    # there, so the subshell reported success having appended nothing and the
    # `&& return 0` swallowed the row before the unlocked fall-through could run
    # — a guard written to prevent losing a cost row introduced a new way to
    # lose one, silently, reporting success. A distinct code rather than a bare
    # nonzero so the fall-through fires for a missing lock and NOT for a failed
    # append: retrying a write that already partly happened would duplicate the
    # row, and an inflated ledger is its own kind of wrong number.
    ( flock -w 10 9 || exit 75
      # ONE-TIME HEADER UPGRADE, now with six generations behind it: a
      # 13-column file predates billing_mode, a 14-column one predates
      # auth_fp/auth_account, a 16-column one predates session_id/row_source/
      # result_usd and the attribution tags, a 23-column one predates `note`
      # (BH-656, the cliff-route decision), a 24-column one predates lane_id
      # (BH-2303) and a 25-column one predates guard_fp (BH-2537). Each gets exactly the columns it
      # is missing appended to the HEADER only — old rows stay untouched and
      # parse with the new names empty, which is the honest reading of a row
      # written before the box could say which session or ticket it belonged
      # to. The reverse is safe too: a legacy 13-field row under the 24-column
      # header parses billing_mode empty and takes the legacy path, which is
      # why upgrading breaks nothing.
      #
      # Done under a lock, with the append inside it, because the rewrite
      # replaces the file's inode — a concurrent appender holding the old
      # descriptor would write into an orphaned file and lose the row.
      local _add=""
      case "$(head -1 "$COST" 2>/dev/null | awk -F, '{print NF}')" in
        13) _add=",billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note,lane_id,guard_fp" ;;
        14) _add=",auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note,lane_id,guard_fp" ;;
        16) _add=",session_id,row_source,result_usd,ticket,job_id,pr,run_id,note,lane_id,guard_fp" ;;
        23) _add=",note,lane_id,guard_fp" ;;
        24) _add=",lane_id,guard_fp" ;;
        25) _add=",guard_fp" ;;
      esac
      if [ -n "$_add" ]; then
        # cost.csv is +a once the box is armed, and the upgrade replaces the
        # inode — so release, rewrite, rearm, under harden-state.lock taken
        # AFTER the sidecar lock above (arm-all takes only harden-state.lock,
        # so this order cannot invert).
        #
        # A `{ } 8>` GROUP, never `exec 8>`: a failed `exec` redirection kills
        # this subshell with rc 1, which cost_append reads as "the locked path
        # already appended" and THE ROW IS LOST — the exact bug this function's
        # comments above exist about. A failed group redirect only skips the
        # upgrade; the append below still lands. The upgrade re-runs on the next
        # call, because it is keyed on the width it finds.
        mkdir -p "$HARNESS/locks" 2>/dev/null
        {
          flock -w 10 8 || true
          [ -x "$HARNESS/bin/harden-state.sh" ] && "$HARNESS/bin/harden-state.sh" --release "$COST"
          { head -1 "$COST" | sed "s/\$/$_add/"; tail -n +2 "$COST"; } > "$COST.up" \
            && mv "$COST.up" "$COST"
          [ -x "$HARNESS/bin/harden-state.sh" ] && "$HARNESS/bin/harden-state.sh" --rearm "$COST"
        } 8>"$HARNESS/locks/harden-state.lock"
      fi
      printf '%s\n' "$row" >> "$COST"
    ) 9>"$HARNESS/locks/cost-header.lock" 2>/dev/null
    local rc=$?
    [ "$rc" -eq 0 ] && return 0
    # Anything other than "lock not acquired" already ran the append path; do
    # not write a second time.
    [ "$rc" -eq 75 ] || return 0
  fi
  # Unlocked fall-through. Residual, accepted: if another process is mid-rewrite
  # this can land on the orphaned inode and be lost. That window is once per box,
  # for one header upgrade — losing the row unconditionally, as the bug above
  # did, is strictly worse than a narrow race.
  printf '%s\n' "$row" >> "$COST"
}
# <<< cost_append

# cost_csv_field <value> — one bare CSV field. Commas become spaces and quotes
# and newlines are dropped rather than escaped: every reader of this file splits
# on "," with awk or csv.reader, and a quoted field with an embedded comma reads
# correctly in one of those and not the other. A ticket key or a PR url has no
# business carrying either, so the safe thing is to make sure it cannot.
cost_csv_field() {
  printf '%s' "${1:-}" | tr -d '\r\n"' | tr ',' ' ' | cut -c1-200
}

# cost_row_tags — "ticket,job_id,pr,run_id" for the current call.
#
# COST_* is the explicit form a caller sets; the fallbacks are the variables the
# harness ALREADY exports, so a build lane gets its ticket and job tagged with
# no call-site change at all (bin/run-build.sh exports HARNESS_TICKET at line 80
# and JOB_ID when its claim succeeds). AGENT_CALL_TICKET / AGENT_CALL_PR (BH-2537)
# sit between the two for ticket and fill pr: the call's own ticket beats the
# lane's ambient one.
cost_row_tags() {
  printf '%s,%s,%s,%s' \
    "$(cost_csv_field "${COST_KEY:-${AGENT_CALL_TICKET:-${HARNESS_TICKET:-}}}")" \
    "$(cost_csv_field "${COST_JOB:-${JOB_ID:-}}")" \
    "$(cost_csv_field "${COST_PR:-${AGENT_CALL_PR:-}}")" \
    "$(cost_csv_field "${COST_RUN_ID:-}")"
}

# cost_row_lane — the lane_id field for the current call (BH-2303): the lane
# the caller named, else the lane the pre-call gate resolved, else empty.
cost_row_lane() {
  cost_csv_field "${AGENT_CALL_LANE:-${LLM_GATE_LANE:-}}"
}

# cost_row_guard_fp — the guard_fp field for the current call (BH-2537): the
# pre-call guard's input fingerprint from $COST_GUARD_FP, else empty.
cost_row_guard_fp() { cost_csv_field "${COST_GUARD_FP:-}"; }

# cost_row_auth_account <fp_label> <acct_name> <label_hint> [pinned] — the ONE
# place a cost row's auth_account is decided (BH-3986). Until now the hub wrote
# `acct:max1` and the pool `max1@example.com` for the same account, so the
# console showed one account as two. The canonical spelling is the registry's
# ACCOUNT_LABEL, the value the pool overlay already writes.
#   1. a live fingerprint label wins (2026-08-31)            -> from=fp
#   2. a pinned own account rides verbatim (BH-1657)          -> from=pinned
#   3. no account, or `default`                               -> unknown, from=none
#   4. the picker's label= line                               -> from=label
#   5. accounts.d/<name>.env's ACCOUNT_LABEL, grep-read only  -> from=registry
#   6. acct:<name>, an account with no label                  -> from=name
# Sets COST_ROW_AUTH_ACCOUNT and COST_ROW_ACCT_FROM and prints nothing, so call
# it directly, never inside $( ). The registry file holds tokens: it is never
# sourced, and a name that fails the picker's own name rule builds no path.
cost_row_auth_account() {
  local fp="${1:-}" name="${2:-}" hint="${3:-}" pinned="${4:-0}" dir="" root lbl=""
  COST_ROW_AUTH_ACCOUNT=unknown; COST_ROW_ACCT_FROM=none
  if [ -n "$fp" ] && [ "$fp" != unknown ]; then
    COST_ROW_AUTH_ACCOUNT="$fp"; COST_ROW_ACCT_FROM=fp; return 0
  fi
  if [ "$pinned" = 1 ] && [ -n "$name" ]; then
    COST_ROW_AUTH_ACCOUNT="$name"; COST_ROW_ACCT_FROM=pinned; return 0
  fi
  { [ -z "$name" ] || [ "$name" = default ]; } && return 0
  lbl=$(printf '%s' "$hint" | tr -d ',\r\n"' | cut -c1-128)
  if [ -n "$lbl" ]; then
    COST_ROW_AUTH_ACCOUNT="$lbl"; COST_ROW_ACCT_FROM=label; return 0
  fi
  if grep -qE '^[a-z0-9][a-z0-9._-]{0,39}$' <<<"$name"; then
    root=$(_cost_row_root)
    if [ -n "${ACCOUNTS_DIR:-}" ]; then dir="$ACCOUNTS_DIR"
    elif [ -n "$root" ] && command -v harness_env_dir >/dev/null 2>&1; then dir="$(harness_env_dir "$root")/accounts.d"
    elif [ -n "$root" ]; then dir="$root/env/accounts.d"; fi
    if [ -n "$dir" ] && [ -r "$dir/$name.env" ]; then
      lbl=$(grep -m1 '^ACCOUNT_LABEL=' "$dir/$name.env" 2>/dev/null | cut -d= -f2-)
      case "$lbl" in \"*\") lbl="${lbl#\"}"; lbl="${lbl%\"}" ;; \'*\') lbl="${lbl#\'}"; lbl="${lbl%\'}" ;; esac
      lbl=$(printf '%s' "$lbl" | tr -d ',\r\n"' | cut -c1-128)
      if [ -n "$lbl" ]; then
        COST_ROW_AUTH_ACCOUNT="$lbl"; COST_ROW_ACCT_FROM=registry; return 0
      fi
    fi
  fi
  COST_ROW_AUTH_ACCOUNT="acct:$name"; COST_ROW_ACCT_FROM=name
  return 0
}

# cost_row_model_note <served> <requested> — `requested_model=<requested>` when
# the row's model is not the one the caller asked for (a ladder fallback, a
# grok/codex rung, a refusal on a non-claude primary), else nothing (BH-3986).
cost_row_model_note() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ "$1" != "$2" ] || return 0
  printf 'requested_model=%s' "$(cost_csv_field "$2" | tr -d ';')"
}

# cost_transcript_enabled — the kill switch for transcript-derived rows.
#
# OFF does not mean "no row": both callers fall back to the CLI's own .usage
# envelope, which is exactly the behaviour before this wave. So the switch turns
# off a NUMBER, never a ledger entry.
#   COST_TRANSCRIPT_ROWS=0            (env/global.env, per box)
#   $HARNESS/flags/transcript-cost-off (a file, for a box you cannot restart)
# _cost_row_root — the root, "" when neither HARNESS nor H is set (BH-2649).
# With none, the switches below read as an unreadable flags dir and nothing is
# written.
_cost_row_root() { printf '%s' "${HARNESS:-${H:-}}"; }

# cost_row_allowed_projects — the projects whose rows the cron cost-rows mirror
# may send (BH-3982): bin/fleet-conf.sh --projects, then the words of
# $COST_ROWS_LANE_PROJECTS (lane-named rows such as `fleet` or `medic`), one per
# line. FAIL-OPEN: no fleet-conf.sh, or a registry that lists nothing, prints
# NOTHING, and an empty list means the caller filters nothing.
cost_row_allowed_projects() {
  local _f="" _c _root _p=""
  _root=$(_cost_row_root)
  for _c in "$(dirname "${BASH_SOURCE[0]}")/../fleet-conf.sh" ${_root:+"$_root/bin/fleet-conf.sh"}; do
    [ -f "$_c" ] && { _f="$_c"; break; }
  done
  [ -n "$_f" ] || return 0
  _p=$(bash "$_f" --projects 2>/dev/null)
  [ -n "$(printf '%s' "$_p" | tr -d '[:space:]')" ] || return 0
  printf '%s\n' $_p ${COST_ROWS_LANE_PROJECTS:-fleet alert-triage responder medic rule-miner greenfield trap-eval}
}

cost_transcript_enabled() {
  [ -n "$(_cost_row_root)" ] && [ -f "$(_cost_row_root)/flags/transcript-cost-off" ] && return 1
  case "${COST_TRANSCRIPT_ROWS:-1}" in 0|no|off|false|NO|OFF|FALSE) return 1 ;; esac
  return 0
}

# cost_row_uuid — a v4-shaped uuid for --session-id. uuidgen where it exists,
# /proc/sys/kernel/random/uuid on every Linux box, python3 last. Empty if all
# three are missing, and the caller then simply does not pass --session-id.
cost_row_uuid() {
  local u=""
  if command -v uuidgen >/dev/null 2>&1; then u=$(uuidgen 2>/dev/null)
  elif [ -r /proc/sys/kernel/random/uuid ]; then u=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
  elif command -v python3 >/dev/null 2>&1; then u=$(python3 -c 'import uuid;print(uuid.uuid4())' 2>/dev/null); fi
  u=$(printf '%s' "$u" | tr 'A-Z' 'a-z' | tr -dc '0-9a-f-')
  case "$u" in
    ????????-????-????-????-????????????) printf '%s' "$u" ;;
    *) printf '' ;;
  esac
}

# ── COST-CAPTURE PARITY (BH-406, 2026-09-15) ─────────────────────────────────
# Two functions the runner branches share: one prices a row the vendor did not
# price, the other says out loud that a row could not be priced at all. Both are
# additive and fenced by their own markers; tests/cost-grok-usage-test.sh
# extracts and runs them, and bin/agent-call.sh stubs them out when a box's sync
# has not landed this file yet.

# >>> cost_price_tokens (tests/cost-grok-usage-test.sh runs this function)
# cost_price_tokens <model> <in> <out> <cache_read> <cache_write> [cache_ttl]
#
# [cache_ttl] (P1, 2026-09-24): `1h` prices the cache write at the ONE-HOUR
# rate — the row's `cache_write_1h` when the table carries one, else 2x the
# prompt rate (Anthropic's published 1h multiplier; the table's `cache_write`
# is the 5-minute 1.25x rate), the SAME derivation bin/transcript-cost.sh uses
# so the two pricers cannot disagree. Anything else (5m, mixed, empty) prices
# at the table's `cache_write`, exactly as before: a caller that says nothing
# gets today's number.
#
# Dollars from catalog/model-prices.json, printed to 6dp — or NOTHING.
#
# The formula is cost-rollup.sh's row_cost(), component for component, on
# purpose: the hub prices any row that reaches it with blank dollars, and a call
# site that used a different formula would make the same call cost two amounts
# depending on who read it.
#
# EMPTY, NEVER ZERO, in all three failure shapes — no table, no row for this
# model, no counts to multiply. A zero would read as "this call was free", which
# is exactly the lie the blank cost column tells today, and the rollup would
# then skip the row instead of pricing it from the tokens.
#
# MODEL_PRICES, when set, is used AS GIVEN and is never fallen back from: an
# explicit override that silently reads a different table is how a fixture run
# ends up asserting production rates. Unset, the chain is the one
# bin/transcript-cost.sh uses (the hub's live state/model-prices.json first
# where it exists, then the repo checkout, then $HARNESS/catalog, which is all a
# fly builder has).
_cost_prices_table() {
  local _c _r
  # MODEL_PRICES as given, never fallen back from — see the note above. An
  # unreadable override resolves to NOTHING rather than quietly to the catalog.
  if [ -n "${MODEL_PRICES:-}" ]; then
    [ -r "$MODEL_PRICES" ] && printf '%s' "$MODEL_PRICES"
    return 0
  fi
  # The root inline, not _cost_row_root: this block is extracted and run alone.
  _r="${HARNESS:-${H:-}}"
  for _c in ${_r:+"$_r/state/model-prices.json"} \
            "$(dirname "${BASH_SOURCE[0]}")/../../catalog/model-prices.json" \
            /root/harness-checkout/catalog/model-prices.json \
            ${_r:+"$_r/catalog/model-prices.json"}; do
    [ -r "$_c" ] && { printf '%s' "$_c"; return 0; }
  done
  return 0
}

# cost_model_cliff <model> — the model's PER-REQUEST price cliff in context
# tokens, or nothing (rc 1).
#
# xAI bills the whole request at 2x once it exceeds 200,000 tokens, and that is
# a fact about the RUNNER, not about any lane — so it lives beside the rate, in
# catalog/model-prices.json (`cliff_tokens`), and a runner with no cliff simply
# has no key. Missing table, unknown model, null or non-integer all answer
# NOTHING: a zero here would read as "every request is past the cliff".
#
# Read through the same table resolver cost_price_tokens uses, because a box
# that prices from one table and routes from another is two different answers to
# one question (bin/update-model-prices.sh carries the key into the live table
# for exactly this reason).
cost_model_cliff() {
  local _m="${1:-}" _t _v
  [ -n "$_m" ] || return 1
  _t=$(_cost_prices_table)
  [ -n "$_t" ] && [ -r "$_t" ] || return 1
  _v=$(jq -r --arg m "$_m" '(.per_token // .)[$m] | .cliff_tokens | numbers' "$_t" 2>/dev/null) || return 1
  case "$_v" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$_v"
}

cost_price_tokens() {
  local _m="${1:-}" _i="${2:-}" _o="${3:-}" _cr="${4:-}" _cw="${5:-}" _ttl="${6:-}" _t="" _rates
  [ -n "$_m" ] || { printf ''; return 1; }
  # Absent is not zero: with nothing to multiply there is no price to state.
  [ -n "$_i$_o$_cr$_cw" ] || { printf ''; return 1; }
  _t=$(_cost_prices_table)
  [ -n "$_t" ] && [ -r "$_t" ] || { printf ''; return 1; }
  # `.per_token // .` so a flat table (the shape several fixtures and older
  # copies use) reads the same as the catalog's. A null rate for one component
  # is that component at 0, not an unpriced row: xAI publishes no cache-write
  # rate and the rest of the row is still real money.
  _rates=$(jq -r --arg m "$_m" \
    '(.per_token // .)[$m] // empty | [(.prompt//0),(.completion//0),(.cache_read//0),(.cache_write//0),((.cliff_tokens | numbers) // ""),((.cache_write_1h | numbers) // "")] | @tsv' \
    "$_t" 2>/dev/null) || _rates=""
  [ -n "$_rates" ] || { printf ''; return 1; }
  # THE CLIFF (BH-656). Past it the vendor bills the WHOLE request at 2x, so a
  # row priced flat understates it by exactly half — which is how the majority
  # of one lane's grok calls were logged at half what they cost. STRICTLY
  # greater, because xAI's word is "exceeding"; the unit is input + cache_read,
  # the same unit catalog/context-budgets.json states every ceiling in. A model
  # with no cliff_tokens has an empty p[5] and is never touched.
  awk -v r="$_rates" -v i="$_i" -v o="$_o" -v cr="$_cr" -v cw="$_cw" -v ttl="$_ttl" \
    'BEGIN{ split(r, p, "\t");
            w = p[4];
            if (ttl == "1h") w = (p[6] != "") ? p[6] : ((p[1]+0 > 0) ? p[1]*2 : p[4]*1.6);
            t = i*p[1] + o*p[2] + cr*p[3] + cw*w;
            if (p[5] != "" && (i+0)+(cr+0) > p[5]+0) t *= 2;
            printf "%.6f", t }'
}

# cost_price_version <model> — the model's price `version` in the table
# _cost_prices_table picks, or nothing (rc 1).
#
# BH-5652: model_prices bumps a row's version on every rate change and writes a
# price_audit row for it, and GET /api/model-prices carries it into each box's
# state/model-prices.json. cost_row_price writes it on the row as `price_v:<n>`,
# so a cost can be traced to the exact rates it was multiplied by. A table with
# no version key (the committed catalog, every older fixture) answers NOTHING:
# a guessed version is worse than none. Only a positive integer is a version.
cost_price_version() {
  local _m="${1:-}" _t _v
  [ -n "$_m" ] || return 1
  _t=$(_cost_prices_table)
  [ -n "$_t" ] && [ -r "$_t" ] || return 1
  _v=$(jq -r --arg m "$_m" '(.per_token // .)[$m] | objects | .version | numbers' "$_t" 2>/dev/null) || return 1
  case "$_v" in ''|0|*[!0-9]*) return 1 ;; esac
  printf '%s' "$_v"
}

# cost_price_version_token <version> — `price_v:<n>` for a positive integer,
# nothing (rc 1) for anything else. The ONE rule for the note token, shared by
# cost_row_price and bin/claude-cost.sh, so a row priced by the transcript and
# a row priced here cannot disagree on what a version looks like.
cost_price_version_token() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$((10#$1))" -gt 0 ] 2>/dev/null || return 1
  printf 'price_v:%s' "$((10#$1))"
}
# <<< cost_price_tokens

# >>> cost_parity_alert (tests/cost-grok-usage-test.sh runs this function)
# cost_parity_alert <runner> <model> <stage> <rc> <in> <out>
#
# One ALERTS line when a call SUCCEEDED and reported no usage at all. Returns 0
# if it wrote the line, 1 otherwise.
#
# WHY IT IS AT THE CALL SITE. Until now the only detector was the hub's rollup,
# hourly, one line a day, reading a fleet-wide CSV — which is how 217 grok rows
# went out blank before anybody saw the shape. The box that made the call knows
# immediately; this is the first call paging instead of the 217th.
#
# THE GATE IS NARROW, deliberately. rc must be 0: a failed call was never
# billed, and paging on vendor outages would bury the one line that means money
# is going unmeasured. Both token counts must be empty: a row with tokens and no
# dollars is the ROLLUP's bucket (it prices from the table), not this one.
#
# ONE LINE PER runner/model/stage PER UTC DAY, like every other daily alert in
# this repo. The line is appended BEFORE the flag is touched, so a crash between
# the two costs a duplicate line tomorrow's reader can ignore rather than a
# page nobody ever gets.
cost_parity_alert() {
  local _r="${1:-}" _m="${2:-}" _s="${3:-}" _rc="${4:-}" _i="${5:-}" _o="${6:-}"
  [ "$_rc" = 0 ] || return 1
  [ -z "$_i" ] && [ -z "$_o" ] || return 1
  local _h _ms _rs _ss _flag
  # No root: not alerted (rc 1), and no flag or ALERTS line anywhere.
  # The root inline, not _cost_row_root: this block is extracted and run alone.
  _h="${HARNESS:-${H:-}}"; [ -n "$_h" ] || return 1
  # A model string can carry a '/' (x-ai/<model>) and a flag name is a path.
  _ms=$(printf '%s' "$_m" | tr -c 'A-Za-z0-9._-' '_')
  _rs=$(printf '%s' "$_r" | tr -c 'A-Za-z0-9._-' '_')
  _ss=$(printf '%s' "$_s" | tr -c 'A-Za-z0-9._-' '_')
  _flag="$_h/flags/alerted-cost-parity-$_rs-$_ms-$_ss-$(date -u +%Y%m%d)"
  [ -f "$_flag" ] && return 1
  mkdir -p "$_h/logs" "$_h/flags" 2>/dev/null
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [cost-parity] UNPRICED $_r $_m $_s priced=0 rc=0: the call succeeded and reported no usage, so this spend reads as \$0.00 on every cost view. Fix that runner's usage capture (bin/grok-usage.sh, bin/codex-usage.sh) and check the CLI's ledger has not moved again. Family note: docs/COST.md#cost-capture-parity." >> "$_h/logs/ALERTS.log" || return 1
  touch "$_flag" 2>/dev/null
  return 0
}
# <<< cost_parity_alert

# >>> cost_row_price (tests/cost-row-priced-test.sh runs this function)
# cost_row_price <runner> <model> <rc> <in> <out> <cache_read> <cache_write> <usd> <note> [cache_ttl]
#
# [cache_ttl] goes to cost_price_tokens unchanged (P1): the TTL the session's
# writes were OBSERVED to use. Absent = today's 5-minute pricing.
#
# Prints "<usd>|<note>" — the dollars this row should carry and the note column
# it should carry them with. Always rc 0; it can refuse to price, never fail.
#
# WHY IT IS ONE FUNCTION AND NOT A LINE IN EACH BRANCH (BH-1020). run_attempt
# captures tokens for the codex-driven lanes and only the grok branch ever
# priced them — bin/agent-call.sh:1195 (codex), :1266 (openrouter) and :1332
# (fireworks) each read the counts out of the CLI's own ledger and no line after
# them assigns USD. So the row was assembled with an empty cost_usd whenever the
# vendor HAD reported, cost_rows-push.sh mirrored that blank into the DB, and
# 1,987 rows / about $3.5K in three days read as $0.00 everywhere that does not
# go through bin/cost-rollup.sh (which prices a blank row from its tokens and is
# therefore the only reader that was ever right). Four branches meant four
# places to forget; the call site is one line every runner's row passes through.
#
# The dollars are NOTIONAL, which is what this column has always meant:
# cost-rollup.sh:433 says row_cost() is "what the call would cost at retail",
# and cash_of() zeroes a subscription row from billing_mode. So a flat-rate
# codex row now carrying a retail figure does not move any cash view — it gives
# volume, lane comparison and cost-per-PR the number they were always reading.
#
# THE RULES, IN ORDER:
#   1. a dollar figure already on the row is FINAL. claude's transcript and
#      envelope dollars are what the session actually said. The transcript's
#      dollars come from the same versioned table, so $11 is the version
#      bin/transcript-cost.sh --price-version read for the row's model; it rides
#      the note as `price_v:<n>` (BH-5652). Envelope and vendor dollars have none. The grok writers
#      hand in cost_price_tokens' own figure (BH-3984) and keep the vendor's
#      ticks in result_usd, so a grok row only arrives here with the vendor's
#      dollars when the table cannot price its model.
#   2. any token count present -> price it. A price we get is the answer; a
#      price we cannot get (no table, or no row for this model) leaves cost_usd
#      EMPTY and says `UNPRICED:no-price:<model>` — the model to add, named.
#   3. no counts at all on an rc-0 call -> the call was billed and reported
#      nothing: `UNPRICED:no-usage`, the same gate cost_parity_alert pages on.
#   4. no counts on a FAILED call -> nothing changes. It was never billed, which
#      is the reading the rollup's unpriced_pairs already applies.
#
# EMPTY IS NEVER ZERO, the same contract cost_price_tokens states: a 0 here
# would read as "this call was free", and the rollup would then skip the row
# instead of pricing it from the tokens later.
#
# $1 is the runner. It is in the signature for symmetry with cost_parity_alert
# and is deliberately not read: what a row costs is a fact about the model and
# the counts, never about which lane made the call.
cost_row_price() {
  local _m="${2:-}" _rc="${3:-}" _i="${4:-}" _o="${5:-}" _cr="${6:-}" _cw="${7:-}" \
        _usd="${8:-}" _note="${9:-}" _ttl="${10:-}" _pv="${11:-}" _p="" _tok=""
  if [ -n "$_usd" ]; then
    if [ -n "$_pv" ] && command -v cost_price_version_token >/dev/null 2>&1; then
      _tok=$(cost_price_version_token "$_pv") && _note="${_note:+$_note;}$_tok"
    fi
    printf '%s|%s' "$_usd" "$_note"; return 0
  fi
  if [ -n "$_i$_o$_cr$_cw" ]; then
    # BH-5652: the table is resolved ONCE and the price and its version are both
    # read from that one path, so a sync's `mv` between the two reads cannot
    # pair one table's dollars with another table's version. An empty answer
    # (an unreadable MODEL_PRICES override) keeps today's path: UNPRICED below.
    local _tbl _v=""
    _tbl=$(_cost_prices_table)
    if [ -n "$_tbl" ]; then
      _p=$(MODEL_PRICES="$_tbl" cost_price_tokens "$_m" "$_i" "$_o" "$_cr" "$_cw" "$_ttl") || _p=""
      # Guarded: an older extracted copy of the pricer has no version reader.
      if [ -n "$_p" ] && command -v cost_price_version >/dev/null 2>&1; then
        _v=$(MODEL_PRICES="$_tbl" cost_price_version "$_m") || _v=""
      fi
    fi
    if [ -n "$_p" ]; then
      [ -n "$_v" ] && _note="${_note:+$_note;}price_v:$_v"
      printf '%s|%s' "$_p" "$_note"; return 0
    fi
    # An existing note (today: `cliff-routed:grok:…`, BH-656) is a fact about
    # this row and keeps its place; the marker joins it with ';'.
    printf '|%s' "${_note:+$_note;}UNPRICED:no-price:$_m"; return 0
  fi
  if [ "$_rc" = 0 ]; then
    printf '|%s' "${_note:+$_note;}UNPRICED:no-usage"; return 0
  fi
  printf '|%s' "$_note"
}
# <<< cost_row_price

# ── COST ROWS AT THE SOURCE (BH-1032, 2026-09-20) ────────────────────────────
# Until now a row reached the DB only through bin/cost-rows-push.sh, a */10 cron
# that tails logs/cost.csv behind a line cursor. That lane works, and it stays —
# but it means every cost question is up to ten minutes behind the call, a pool
# machine that dies inside its window takes its rows with it (its rootfs is the
# only copy until the reap), and the FILE is the differencing baseline for a
# table that is supposed to be the fleet's ledger. The row is now written where
# it is made, and the cron becomes the backstop rather than the only path.
#
# THE CSV IS STILL WRITTEN FIRST, AND IS STILL THE TRUTH. cost_row_emit appends
# through cost_append (unchanged, locked, header-upgrading) and only then
# offers the row to the worker. That order is the write-ahead contract: a worker
# outage, a missing client, a 500 — none of them can cost a row, because the row
# is already on disk and the */10 mirror will carry it. Nothing here ever
# returns non-zero to its caller: agent-call.sh must not fail a build because a
# side-channel POST did.
#
# IDEMPOTENT BY CONSTRUCTION. The body carries the SAME (box, row_hash) the
# mirror would compute — sha256 of the verbatim line, under the same box id —
# so when the cron later reaches this line the worker's ON CONFLICT absorbs it
# and reports it as a dup. The two writers are one row. (Since BH-3220 the
# conflict also fills a NULL lane_id / guard_fp from the later push, and only
# that; an identical re-push still counts as a dup.)

# cost_row_box_id — the box identity a cost row is filed under.
#
# ONE RESOLVER, because two of them was a latent double-home: this function is
# what bin/cost-rows-push.sh resolves with, so the at-source row and the mirror
# row land on the same PK instead of splitting one call across two box keys.
#
# $COST_ROWS_BOX LEADS BECAUSE A POOL MACHINE SAYS ITS OWN NAME (BH-1032
# review). fly/entrypoint.sh exports it as the machine id the reap files the
# same rows under, and fly/builder-runner.sh's flush passes it to
# bin/cost-rows-push.sh as argv[1]. Until this line, a Fly machine's at-source
# row resolved through state/box-id instead: the two agree today ONLY because a
# pool rootfs happens to carry no state/box-id, and the day one appears — or the
# day the env id stops matching — one call becomes two PK rows under two box
# keys and every fleet total doubles for the pool. The explicit id wins, once,
# here, for both writers.
#
# AND AFTER THAT IT IS bin/lib/box-id.sh, WHICH NEVER GUESSES (BH-1043).
# This used to end `|| _b=$(hostname -s)`. Every Orgo box answers the image
# default "orgo-desktop", so a box whose state/box-id had not landed yet filed
# its rows under a name that is not a box — a PHANTOM in every metrics table,
# silently merging however many machines were in that state, reported as a
# success. `box` is half the PK of every row this file writes, so the honest
# answer with no declared identity is NOTHING: cost_row_emit's `[ -n "$_box" ]
# || return 0` then keeps the row in logs/cost.csv (the truth) and posts
# nothing, and bin/cost-rows-push.sh's box_id_require alerts once a day and
# sends every held row the first tick after state/box-id lands. Held, not lost.
#
# box_id_get is SOURCED, not reimplemented: a second copy of the chain is the
# drift this function exists to prevent. The literal read below is only for a
# box whose sync has not landed bin/lib/box-id.sh yet, and it guesses nothing
# either.
cost_row_box_id() {
  local _h _b="" _p
  _h=$(_cost_row_root)
  [ -n "${COST_ROWS_BOX:-}" ] && _b=$(printf '%s' "$COST_ROWS_BOX" | tr -dc 'A-Za-z0-9._-')
  if [ -z "$_b" ]; then
    if ! command -v box_id_get >/dev/null 2>&1; then
      for _p in "$(dirname "${BASH_SOURCE[0]}")/box-id.sh" ${_h:+"$_h/bin/lib/box-id.sh"}; do
        # shellcheck source=bin/lib/box-id.sh
        # shellcheck source=/dev/null
        [ -r "$_p" ] && { . "$_p"; break; }
      done
    fi
    if command -v box_id_get >/dev/null 2>&1; then
      _b=$(box_id_get) || _b=""
    else
      _b=$(printf '%s' "${BOX_ID:-}" | tr -dc 'A-Za-z0-9._-')
      # Readability tested BEFORE the redirect: `2>/dev/null` on tr does not
      # suppress the SHELL's error for a failed `<`, which would print on every
      # agent call made on a box with no state/box-id.
      [ -n "$_b" ] || [ -z "$_h" ] || { [ -r "$_h/state/box-id" ] && _b=$(tr -dc 'A-Za-z0-9._-' < "$_h/state/box-id" 2>/dev/null); }
    fi
  fi
  printf '%s' "$_b"
}

# cost_row_at_source_enabled — the kill switch for the at-source write.
# OFF does not mean "no DB row": the */10 mirror still carries every line. So
# the switch turns off a LATENCY, never a ledger entry, which is why it can be
# a switch that needs no restart.
#   COST_ROW_AT_SOURCE=0                 (env/global.env, per box)
#   switch.cost-row-at-source-off[.<box>] (a settings row, BH-2433), which
#                                        wins; with no row, the file
#   flags/cost-row-at-source-off         answers, exactly as before
# lane-switch.sh loads on the first read, not when this lib is sourced.
cost_row_at_source_enabled() {
  if ! command -v lane_switch >/dev/null 2>&1; then
    local _p _r; _r=$(_cost_row_root)
    for _p in "$(dirname "${BASH_SOURCE[0]}")/lane-switch.sh" ${_r:+"$_r/bin/lib/lane-switch.sh"}; do
      # shellcheck source=bin/lib/lane-switch.sh
      [ -r "$_p" ] && { . "$_p" 2>/dev/null || true; break; }
    done
    # no lib: the file, as before; no root, no file (the switch is off)
    command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -n "$(_cost_row_root)" ] && [ -f "$(_cost_row_root)/flags/$1" ]; }
  fi
  lane_switch cost-row-at-source-off file >/dev/null && return 1
  case "${COST_ROW_AT_SOURCE:-1}" in 0|no|off|false|NO|OFF|FALSE) return 1 ;; esac
  return 0
}

# >>> cost_row_emit (tests/cost-row-at-source-test.sh runs this function)
# cost_row_emit <row> — append the row to $COST, then offer it to cost_rows.
#
# ALWAYS returns 0. The file write is the contract; the DB write is best effort.
#
# NEVER FROM A TEST (BH-3223). The row is still appended, but nothing is POSTed
# when HARNESS_TEST_SANDBOX=1 or when the row's project is the test fixture
# `testproj` (_cost_row_emit_body exits 1 for it): ~750 stub-runner rows from
# suites run on Fly pool machines had landed in the production cost_rows table.
#
# FLEET PROJECTS ONLY (BH-3982). A row whose project is not in
# cost_row_allowed_projects (fleet.conf plus the lane names) is appended but not
# POSTed; the */10 mirror counts and logs the drop. An empty list filters nothing.
cost_row_emit() {
  local row="$1"
  cost_append "$row"
  [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && return 0
  cost_row_at_source_enabled || return 0
  command -v _jobs_req_file >/dev/null 2>&1 || return 0
  local _box _ln _body
  _box=$(cost_row_box_id)
  [ -n "$_box" ] || return 0
  # BH-3982: only fleet projects and lane names reach cost_rows. An empty list
  # (no fleet-conf.sh, unreadable fleet.conf, or a lib that predates
  # cost_row_allowed_projects) means do not filter: fail-open, never a lost row.
  local _allow=""
  command -v cost_row_allowed_projects >/dev/null 2>&1 \
    && _allow=$(cost_row_allowed_projects 2>/dev/null | tr '\n' ' ')
  # line_no is the row's position in the file, the trail back to the source
  # line — read straight after the append. A concurrent appender can make it
  # off by one; that is accepted and stated, because the PK is the HASH and
  # line_no is a pointer, not an identity. The mirror will later push its own
  # reading of the same line; ON CONFLICT keeps the first row and only fills a
  # NULL lane_id / guard_fp from the later one (BH-3220).
  _ln=$(wc -l < "$COST" 2>/dev/null | tr -dc '0-9'); _ln="${_ln:-0}"
  _body=$(mktemp "${TMPDIR:-/tmp}/cost-row-emit.XXXXXX") || return 0
  if COST_ROWS_ALLOW="$_allow" _cost_row_emit_body "$row" "$_box" "$_ln" > "$_body" 2>/dev/null && [ -s "$_body" ]; then
    # Silent on every outcome. A failed side-channel POST is not an event: the
    # row is on disk and the */10 mirror is the backstop, so logging here would
    # put one line per agent call into a log during any worker blip.
    _jobs_req_file POST /api/metrics/cost-rows "$_body" >/dev/null 2>&1 || true
  fi
  rm -f "$_body"
  return 0
}

# _cost_row_emit_body <row> <box> <line-no> — the one-row request body.
# The column list and the hash are _metric_cost_rows_chunk's, deliberately: two
# writers of one PK must compute it the same way or the dedupe is a coin flip.
# COLS must equal COST_ROW_HDR and the mirror's list, name for name (BH-3220:
# this one stopped at `note`, so every row it posted landed without lane_id and
# guard_fp, first, and the mirror's full row lost the PK race).
# tests/cost-row-emit-cols-parity.bh-3220-test.sh pins all three.
# `raw` rides along so a reader can re-emit the line verbatim (see
# bin/lib/cost-rows-read.sh). `participant` rides along from COST_ROW_PARTICIPANT
# when it is a valid participant name (BH-5352).
_cost_row_emit_body() {
  python3 - "$1" "$2" "$3" <<'PYEOF'
import csv, hashlib, json, os, re, sys
raw, box, line_no = sys.argv[1], sys.argv[2], sys.argv[3]
COLS = ["ts", "host", "project", "stage", "runner", "model", "rc", "duration_s",
        "input_toks", "output_toks", "cache_read", "cache_write", "cost_usd",
        "billing_mode", "auth_fp", "auth_account",
        "session_id", "row_source", "result_usd", "ticket", "job_id", "pr",
        "run_id", "note", "lane_id", "guard_fp"]
raw = raw.rstrip("\r\n")
if not raw.strip():
    sys.exit(1)
f = next(csv.reader([raw]))
if len(f) < 13:
    sys.exit(1)
f = (f + [None] * len(COLS))[:len(COLS)]
r = dict(zip(COLS, f))
# BH-3223: the test fixture project never reaches the DB.
if r["project"] == "testproj":
    sys.exit(1)
# BH-3982: a project outside fleet.conf + the lane list never reaches the DB.
# Unset or empty COST_ROWS_ALLOW (a direct caller) filters nothing.
allow = os.environ.get("COST_ROWS_ALLOW", "").split()
if allow and r["project"] not in allow:
    sys.exit(1)
r["line_no"] = int(line_no or 0)
r["row_hash"] = hashlib.sha256(raw.encode("utf-8", "replace")).hexdigest()
r["raw"] = raw
# BH-5352: the participant machine that spent the call (bin/agent-call.sh sets
# it), a JSON key only: COLS, the header and the mirror stay as they are.
part = os.environ.get("COST_ROW_PARTICIPANT", "")
if re.fullmatch(r"[a-z0-9._-]{1,64}", part):
    r["participant"] = part
json.dump({"box": box, "rows": [r]}, sys.stdout)
PYEOF
}
# <<< cost_row_emit
