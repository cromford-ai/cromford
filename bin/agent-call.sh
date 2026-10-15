#!/bin/bash
# Unified agent runner + cost instrumentation + failover (cost levers, 2026-07-24).
# usage: agent-call.sh <stage> <project> <model> <timeout-sec> <outfile> <prompt>
#   stage: triage|plan|preplan|preplan-files|execute|review|fix|chat
#          (picks runner via RUNNER_<STAGE>, non-alphanumerics folded to _)
#     chat = bin/box-chat.sh's fallback lane (per-box Mission Control chat).
# Runner per stage: RUNNER_<STAGE> = claude (default) | codex | gemini.
# Failover per stage: RUNNER_<STAGE>_FALLBACK — runs when the primary exits nonzero
#   or isn't installed/authed. Default fallback: claude for codex/gemini primaries,
#   none for claude primaries. (Per-account split, 2026-07-24: project-3+project-2 run
#   execute on the CLIENT's Claude account with codex fallback; project-4+project-1 run
#   execute on codex with claude fallback.)
# Cost: every attempt appends a row to /root/harness/logs/cost.csv:
#   ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account
# billing_mode (metered|subscription|unknown) records whether the row cost CASH
# on THIS box — see bin/billing-mode.sh. auth_fp/auth_account (2026-08-31)
# record WHICH account paid: a sha256 prefix of the credential the attempt
# actually used, resolved live at row-write time (never the raw secret, never
# inferred later — see bin/auth-fingerprint.sh), plus its human label from
# catalog/auth-accounts.json + state/auth-accounts.local.json ("unknown" for
# an unmapped fp). All three are trailing columns and readers are name-keyed
# (csv.DictReader), so old rows simply lack them.
# ACCOUNT ROUTING (2026-09-06, docs/ACCOUNT-ROUTING.md): with ACCOUNT_ROUTING=1
# the claude and codex lanes ask bin/account-pick.sh WHICH of the box's
# registered accounts (env/accounts.d/*.env) has quota headroom, and run the CLI
# with that account's credentials in the CHILD only. One line per pick in
# logs/account-routing.log. Unset/0 (the default) leaves every path below
# byte-identical. rc 76 = no account of the vendor had headroom, so nothing was
# called and nothing was billed (beside 78 = no-tools refusal, 77 = the hub
# runs no agent build work (BH-393, see the block below), 75 = lock, and 79 =
# an argv-only lane refused the prompt OR — since BH-656 — a grok call was
# CLIFF-ROUTED and never issued; the first line of $OUT tells the two apart,
# and 74 = the lane's own spend/pathway gate refused it (BH-1141: disabled
# lane, rung outside LLM_RUNNER_ALLOWED, or the day's LLM_USD_CAP_DAY reached;
# or — since BH-4488 — the build is over its hard budget cap: $OUT's first line
# is then `AGENT_CALL_REFUSED budget-stop budget_stop <stage> <reason> ...`;
# or — since BH-4489 — a day budget cap: `AGENT_CALL_REFUSED budget-stage-day`,
# `budget-project-day` or, inside a build, `budget-cap-unreadable`).
# ALL OF 74..79 MEAN "nothing was called and nothing was billed" and a caller
# must not charge a budget, write a terminal key or drop work for one of them.
# WHICH IS WHY 74 NEVER ESCAPES A LADDER THAT SPENT MONEY (BH-1141 round 2): if
# any rung EXECUTED, this script exits with THAT attempt's rc even when the last
# thing that happened was a refusal of a lower rung. A billed failure reported
# as 74 would be retried at full price by every caller on the next tick.
# THE EGRESS ALLOWLIST (BH-4492): a build-dir call whose stage has an
# egress.stage.<stage>.hosts settings row runs its CLI in its own network
# namespace whose only way out is bin/egress-proxy.py, allowing that row's
# hosts (bin/lib/egress.sh decides). Refusals go to $BUILD/egress.log, one
# line per call to $BUILD/egress-state.txt, and the PR's evidence block lists
# them. It never refuses a call: a box that cannot fence runs it open and alerts.
# RECOVERY BEFORE FALLBACK (2026-09-16, the operator: "if it's stuck for very little it
# falls back; we need recovery procedures. Falling all the way to Fireworks is
# bad but ok as the LAST resort."). Every failed attempt is CLASSIFIED before the
# next rung is chosen — transient | account-exhausted | auth | real-failure — and
# the class decides the recovery: a transient failure retries the SAME runner on
# the SAME account with a doubling backoff, an exhausted/auth account is cooled
# down and the next account of the same vendor is tried until the vendor runs
# out, and only a real failure descends a rung. Descent order is unchanged:
# claude (all accounts) -> Grok tier-2 (LADDER_TIER2_GROK=1) -> RUNNER_*_FALLBACK
# -> OpenRouter anthropic/ -> deepseek-v4-flash -> Fireworks; the rungs below the
# OpenRouter anthropic/ slug are the LAST RESORT and each writes one lane alert.
# STATUS BEFORE BODY (2026-09-17, BH-642): the classification reads the status
# token the vendor named (ladder_http_status) BEFORE any regex — a 429 is
# RUNNER_RATE_LIMITED (retry, same account), a 400/402/403 whose body matches
# LADDER_CREDITS_REGEX is RUNNER_EXHAUSTED (cool down, next account), everything
# else is RUNNER_ERROR and behaves exactly as before. The token rides on every
# failovers.log line and, on a failed stage, in <outfile>.class, so a caller can
# say "ran out of credits" instead of "produced no output".
# Knobs + defaults: docs/ACCOUNT-ROUTING.md ("Failure classes and recovery").
# CONTEXT KILL (2026-09-17, BH-653): the claude lane meters the SESSION's own
# transcript while it runs, and kills the child when cumulative
# `input_tokens + cache_read` crosses the lane's `context_kill_tokens` in
# catalog/context-budgets.json. A lane with no such key is unbounded, exactly as
# before. On a kill: $OUT ends with a `CONTEXT KILL:` truncation marker (a cut
# session must never look like a finished one), rc is forced nonzero, and the
# stop is POLICY — no model escalation, no same-lane retry, no grok/OpenRouter/
# Fireworks re-spend of the context the ceiling just refused. One lane alert,
# keyed on the session. Knobs: CONTEXT_KILL_TOKENS (override the manifest),
# CONTEXT_KILL_POLL_S (default 15), and the kill switch context-kill-off (a
# switch.context-kill-off settings row, else flags/context-kill-off; BH-2432)
# or CONTEXT_KILL=0, which restore the previous foreground invocation verbatim.
# COST_TRANSCRIPT_ROWS=0 (and flags/transcript-cost-off) mint no session id, so
# there is no transcript to meter: the lane then runs UNBOUNDED and says so in
# one ALERTS line per stage per day rather than pretending the ceiling holds.
# CONTEXT_KILL_CLIFF=1 (+ CONTEXT_KILL_CLIFF_MARGIN, default 10000) lowers that
# ceiling to `cliff - margin` when the attempt's model carries `cliff_tokens`
# in catalog/model-prices.json, and labels the stop CLIFF-AVOIDED: instead
# (BH-1384). A model with no cliff — every claude model in today's table — is
# the path above, unchanged.
# Optional env AGENT_SYSTEM_APPEND: extra system prompt (claude --append-system-prompt;
# prepended to the prompt text for codex/gemini, which have no equivalent flag).
set -uo pipefail
# THE LANE NAME IS THIS CALL'S, NEVER A CHILD'S (BH-2303). A lane script exports
# AGENT_CALL_LANE; kept exported, it would reach every vendor CLI this script
# runs (every runner path, not only claude's scrubbed one) and through it any
# `setsid run-build.sh` a triage or responder session starts — so that build's
# calls would be gated by, and stamped to, the lane that happened to launch it.
# `export -n` keeps the value for the gate and the cost row in THIS process and
# stops it at the process boundary.
export -n AGENT_CALL_LANE 2>/dev/null || true
# Codex lane default model (ChatGPT OAuth): the `codex.default` model_routes row
# (BH-1510.1), read by codex_model below when the lane runs. The pin also lives
# in each box's /root/.codex/config.toml (hub-local file, not rendered by the
# harness). Min codex CLI: 0.153.4. Override: CODEX_MODEL (or the older
# CODEX_DEFAULT_MODEL), exactly as before.
STAGE="${1:?stage}"; PROJECT="${2:?project}"; MODEL="${3:?model}"; TO="${4:?timeout}"; OUT="${5:?outfile}"; PROMPT="${6:?prompt}"
# @/path form: a single argv element over 128KB (MAX_ARG_STRLEN) makes execve of
# this script fail E2BIG before a single line runs — no cost row, empty outfile,
# nothing in stderr if the caller redirects it. Big-prompt callers (PR-review
# diffs ride inline) write the prompt to a file and pass @<path> instead.
case "$PROMPT" in
  @/*) PROMPT=$(cat "${PROMPT#@}") || { HARNESS="${HARNESS:-/root/harness}" "${HARNESS:-/root/harness}/bin/alert-line.sh" "[$PROJECT] $STAGE: prompt file unreadable: ${PROMPT#@}"; exit 1; } ;;
esac
# The stage verdict sidecar (BH-642) is written only on a FAILED exit, so it is
# cleared here: a resumed build re-runs a stage into the same outfile, and a
# leftover .class from the attempt that died would be rendered over a good run.
rm -f "$OUT.class" 2>/dev/null
# Overridable so this file can be DRIVEN by a test (tests/agent-call-notools-test.sh
# runs it against a temp HARNESS with a fake CLI on PATH). It was a hard-coded
# absolute, which meant the no-tools contract below could only ever be asserted by
# grepping this file — and a guard whose only proof is a grep is the shape of
# guard this repo keeps finding inert. Default is unchanged.
HARNESS="${HARNESS:-/root/harness}"
# Catalog path (2026-08-27, TK-109 lesson): hub/boxes read the repo checkout;
# fly builders have NO checkout — fly-sync tars catalog/ into $HARNESS. Without
# this sibling fallback every builder stage fell through to the hardcoded tier
# ($10.50/$3.00) and budget-stopped mid-run.
CB_DEFAULT=/root/harness-checkout/catalog/context-budgets.json
[ -r "$CB_DEFAULT" ] || CB_DEFAULT="$HARNESS/catalog/context-budgets.json"
CONTEXT_BUDGETS="${CONTEXT_BUDGETS:-$CB_DEFAULT}"
# DB-first lane caps (phase 1, docs/DB-COORDINATION-SPEC.md). The catalog file
# is the TK-109 hole: fly builders never receive catalog/, so the machines that
# run build lanes are exactly the machines the manifest is missing on. The
# coordination DB is reachable from all of them. Fail-open by construction —
# with the worker absent every helper returns nonzero and the file chain in
# _budget_for below runs byte-identically to before.
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"
# Account attribution (2026-08-31): which credential pays, fingerprinted live
# at row-write time. Repo sibling preferred so the tests drive the checkout's
# copy; $HARNESS/bin is the deployed path. Missing helper degrades to
# none/unknown rather than breaking the call — instrumentation must never be
# able to break the thing it measures.
# shellcheck source=/dev/null
if [ -r "$(dirname "$0")/auth-fingerprint.sh" ]; then . "$(dirname "$0")/auth-fingerprint.sh"
elif [ -r "$HARNESS/bin/auth-fingerprint.sh" ]; then . "$HARNESS/bin/auth-fingerprint.sh"; fi
command -v auth_fp_for_runner  >/dev/null 2>&1 || auth_fp_for_runner()  { echo none; }
command -v auth_account_for_fp >/dev/null 2>&1 || auth_account_for_fp() { echo unknown; }
# THE ROW WRITER IS SHARED (2026-09-14). cost_append, the canonical header and
# the attribution tags moved to bin/lib/cost-row.sh so bin/claude-cost.sh — the
# thin wrapper the raw-claude callers use — writes through the SAME function
# rather than a second copy that drifts. Same sibling-first chain as above; a
# box mid-sync keeps a minimal append rather than losing the row.
# shellcheck source=/dev/null
if   [ -r "$(dirname "$0")/lib/cost-row.sh" ]; then . "$(dirname "$0")/lib/cost-row.sh"
elif [ -r "$HARNESS/bin/lib/cost-row.sh" ];    then . "$HARNESS/bin/lib/cost-row.sh"; fi
command -v cost_append     >/dev/null 2>&1 || cost_append()     { printf '%s\n' "$1" >> "$COST"; }
# THE ROW GOES TO THE TABLE WHERE IT IS MADE (BH-1032). cost_row_emit appends
# through cost_append exactly as before and then offers the same row to the
# harness-jobs cost_rows table, so a cost question is answerable the second the
# call ends rather than at the next */10 mirror tick. A box whose sync has not
# landed the new library falls back to the plain append — the mirror still
# carries every line, so the fallback costs latency, never a row.
command -v cost_row_emit   >/dev/null 2>&1 || cost_row_emit()   { cost_append "$1"; }
command -v cost_csv_field  >/dev/null 2>&1 || cost_csv_field()  { printf '%s' "${1:-}" | tr -d '\r\n"' | tr ',' ' '; }
command -v cost_row_tags   >/dev/null 2>&1 || cost_row_tags()   { printf ',,,'; }
command -v cost_row_lane   >/dev/null 2>&1 || cost_row_lane()   { printf '%s' "${AGENT_CALL_LANE:-${LLM_GATE_LANE:-}}" | tr -d '\r\n",'; }
command -v cost_row_uuid   >/dev/null 2>&1 || cost_row_uuid()   { printf ''; }
command -v cost_row_guard_fp >/dev/null 2>&1 || cost_row_guard_fp() { printf ''; }
# Same stale-library safety for the cost-capture-parity pair (BH-406): a box
# whose sync has not landed the new cost-row.sh prices nothing extra and pages
# nothing extra, i.e. behaves exactly as it did before this shipped.
command -v cost_price_tokens >/dev/null 2>&1 || cost_price_tokens() { printf ''; return 1; }
command -v cost_parity_alert >/dev/null 2>&1 || cost_parity_alert() { return 1; }
# ...and for the write-time pricer (BH-1020). The stub is the IDENTITY — it
# hands back the dollars and the note it was given — so a box whose bin/lib sync
# has not landed writes exactly the row it writes today: blank where the vendor
# reported nothing in dollars, unmarked. Degrading to the old bug beats degrading
# to a made-up number.
command -v cost_row_price   >/dev/null 2>&1 || cost_row_price()   { printf '%s|%s' "${8:-}" "${9:-}"; }
command -v cost_transcript_enabled >/dev/null 2>&1 || cost_transcript_enabled() { return 1; }
# Same stale-library safety for the cliff lookup (BH-656): a box whose sync has
# not landed it answers "no cliff", which is every path below turned off — no
# route, no warn, flat pricing. Exactly the behaviour before this shipped.
command -v cost_model_cliff  >/dev/null 2>&1 || cost_model_cliff()  { return 1; }
# ...and for the canonical account label and the served-model note (BH-3986).
# Under set -u a missing cost_row_auth_account leaves COST_ROW_AUTH_ACCOUNT
# unbound and aborts the row AFTER the paid call; the stub is the rule before
# this shipped (fingerprint, else a pinned name verbatim, else acct:<name>), and
# the note stub adds nothing.
command -v cost_row_auth_account >/dev/null 2>&1 || cost_row_auth_account() {
  COST_ROW_AUTH_ACCOUNT="${1:-unknown}"; COST_ROW_ACCT_FROM=fp
  [ "$COST_ROW_AUTH_ACCOUNT" = unknown ] || return 0
  COST_ROW_ACCT_FROM=none
  if [ "${4:-0}" = 1 ] && [ -n "${2:-}" ]; then COST_ROW_AUTH_ACCOUNT="$2"; COST_ROW_ACCT_FROM=pinned
  elif [ -n "${2:-}" ] && [ "$2" != default ]; then COST_ROW_AUTH_ACCOUNT="acct:$2"; COST_ROW_ACCT_FROM=name; fi
  return 0
}
command -v cost_row_model_note >/dev/null 2>&1 || cost_row_model_note() { :; }
# EVERY AGENT SESSION COMMITS AS THE BOX'S CONFIGURED AUTHOR (BH-1134). The
# GIT_AUTHOR_*/GIT_COMMITTER_* pin beats user.* config and `git -c`, so a model
# that signs its own commits cannot ship them under its own name. Exported here,
# before any runner starts, and over whatever the caller's env carried. Same
# sibling-first chain; a box without the lib gets no pin (the lanes that push an
# agent's commits check the author themselves, and the build lane's squash
# re-authors), never a failed call.
# shellcheck source=/dev/null
if   [ -r "$(dirname "$0")/lib/git-identity.sh" ]; then . "$(dirname "$0")/lib/git-identity.sh"
elif [ -r "$HARNESS/bin/lib/git-identity.sh" ];    then . "$HARNESS/bin/lib/git-identity.sh"; fi
command -v gi_export >/dev/null 2>&1 && { gi_resolve; gi_export; }
declare -A _JOB_CAP_MEMO=()
COST="$HARNESS/logs/cost.csv"
ALERTS="$HARNESS/logs/ALERTS.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

# >>> model routes (BH-1510.1)
# EVERY MODEL THIS FILE PICKS ON ITS OWN IS A model_routes ROW. The stage model
# arrives in argv, chosen by the caller; what this file used to choose itself —
# the claude lane's failover rungs, the codex / grok / fireworks defaults, the
# OpenRouter and Fireworks floors — was a literal here, and is now read through
# bin/lib/model-route.sh. Same sibling-first chain as every library above.
#
# UNLIKE THEM, NO ANSWER IS NEVER A GUESS. A rung whose model has no route (no
# row, no cached answer, or the resolver missing on a half-synced box) is not
# run: it returns rc 75 — this file's "nothing was called, nothing was billed"
# family — and the ladder descends. The resolver writes the one ALERTS line
# naming the role. The argv model itself is never touched by any of this.
#
# ASKED ONLY WHEN IT MATTERS. A claude call that succeeds on the model it was
# given never reads a model ladder: the ladder is resolved on the first failure
# (or a credits cooldown), which is the only time a second rung could run. The
# one read every call does make is its stage.<stage> route, for the runner
# (BH-1765, below the hub-no-build block).
# shellcheck source=bin/lib/model-route.sh
if   [ -r "$(dirname "$0")/lib/model-route.sh" ]; then . "$(dirname "$0")/lib/model-route.sh"
elif [ -r "$HARNESS/bin/lib/model-route.sh" ];    then . "$HARNESS/bin/lib/model-route.sh"; fi

# THE FLEET COOLDOWN SEAM (BH-2356). A model, account or lane cooldown this box
# records is also put as a fleet row, and the model and openrouter readers also
# honour a row another box put. The local state/ files stay the primary record:
# the row is an OR on top of them. A box whose sync has not landed the lib gets
# stubs that answer "unknown" and write nothing, which is the behaviour before it.
# shellcheck source=bin/lib/fleet-cooldown.sh
if   [ -r "$(dirname "$0")/lib/fleet-cooldown.sh" ]; then . "$(dirname "$0")/lib/fleet-cooldown.sh"
elif [ -r "$HARNESS/bin/lib/fleet-cooldown.sh" ];    then . "$HARNESS/bin/lib/fleet-cooldown.sh"; fi
declare -F fcd_live >/dev/null || { fcd_put() { return 0; }; fcd_live() { return 2; }; }
# THE FAST-FAIL COOLDOWN (BH-3224). A listed runner (default grok) that failed
# at once with no usage is not ready until its window ends; the next call after
# it is the reprobe. Knobs are lib.runner-fastfail.* settings rows. A box whose
# sync has not landed the lib gets stubs: nothing is ever cooling, as before.
# shellcheck source=bin/lib/runner-fastfail.sh
if   [ -r "$(dirname "$0")/lib/runner-fastfail.sh" ]; then . "$(dirname "$0")/lib/runner-fastfail.sh"
elif [ -r "$HARNESS/bin/lib/runner-fastfail.sh" ];    then . "$HARNESS/bin/lib/runner-fastfail.sh"; fi
declare -F rff_live >/dev/null || { rff_enabled() { return 1; }; rff_live() { return 1; }; rff_note() { :; }; rff_until() { :; }; rff_detail() { :; }; }

# ac_ladder <role> — the role's ladder for this project, model_ladder's format
# (<position>\t<model>\t<runner> per line). rc 75 when there is none, including
# a box whose sync has not landed the resolver (alerted once a day, here).
ac_ladder() {
  if ! command -v model_ladder >/dev/null 2>&1; then
    local f; f="$HARNESS/flags/alerted-model-route-missing-$(date -u +%Y%m%d)"
    [ -f "$f" ] || { mkdir -p "$HARNESS/flags" 2>/dev/null; touch "$f" 2>/dev/null
      echo "$(STAMP) [$PROJECT] $STAGE: bin/lib/model-route.sh is missing on $(hostname 2>/dev/null) — no rung that needs a model_routes row can run (role $1). Deploy the harness: bin/harness-sync.sh." >> "$ALERTS"; }
    return 75
  fi
  model_ladder "$1" "$PROJECT"
}

# ac_model_for <role> — the role's primary model for this project. rc 75 = none.
ac_model_for() {
  local l; l=$(ac_ladder "$1") || return $?
  l=$(printf '%s\n' "$l" | awk -F'\t' 'NR==1{print $2}')
  [ -n "$l" ] || return 75
  printf '%s' "$l"
}

# The non-claude runners' models: the operator's env override first, exactly as
# before, then the role row. rc 75 = no route (see above).
codex_model()     { [ -n "${CODEX_MODEL:-${CODEX_DEFAULT_MODEL:-}}" ] && { printf '%s' "${CODEX_MODEL:-$CODEX_DEFAULT_MODEL}"; return 0; }; ac_model_for codex.default; }
grok_model()      { [ -n "${GROK_MODEL:-}" ] && { printf '%s' "$GROK_MODEL"; return 0; }; ac_model_for grok.default; }
fireworks_model() { [ -n "${FIREWORKS_MODEL:-}" ] && { printf '%s' "$FIREWORKS_MODEL"; return 0; }; ac_model_for fireworks.default; }

# ac_refused_model <runner> — the model a script-level refusal row names: the
# model that runner's rung would have served (BH-3986: a grok primary's refusal
# said claude-*), else $MODEL. rc 75 when a mapped runner has no route, so the
# row still says $MODEL was only the requested model.
ac_refused_model() {
  local m="" rc=0
  case "${1:-}" in
    codex)     m=$(codex_model 2>/dev/null) || rc=75 ;;
    grok)      m=$(grok_model 2>/dev/null) || rc=75 ;;
    fireworks) m=$(fireworks_model 2>/dev/null) || rc=75 ;;
  esac
  [ -n "$m" ] || { m="$MODEL"; case "${1:-}" in codex|grok|fireworks) rc=75 ;; esac; }
  printf '%s' "$m"
  return "$rc"
}

# ac_refused_row <reason> — the zero-cost row a pre-call refusal leaves, with
# the runner's model and, when that is not what was served, requested_model=.
# The reason stays first: the worker classifies on its refused:<why> prefix.
ac_refused_row() {
  local m q miss=0
  m=$(ac_refused_model "$RUNNER") || miss=1
  q=$(cost_row_model_note "$m" "$MODEL")
  [ -z "$q" ] && [ "$miss" = 1 ] && q="requested_model=$(cost_csv_field "$MODEL")"
  llm_gate_refused_row "$STAGE" "$PROJECT" "$RUNNER" "$m" 74 "$1${q:+;$q}"
}

# model_family <model> — the model id without its trailing version: two rungs of
# one family (an Opus release and the one before it) are a CLI FLOOR, not a
# failover. See THE CLAUDE LADDER in run_attempt.
model_family() { printf '%s' "${1:-}" | sed -E 's/(-[0-9]+)+$//'; }

# The role whose ladder a claude call walks: AGENT_CALL_ROLE when the caller
# names one, else the build stage's own role. Any other stage walks
# claude.ladder (see claude_ladder).
model_role_for_stage() {
  if [ -n "${AGENT_CALL_ROLE:-}" ]; then printf '%s' "$AGENT_CALL_ROLE"; return 0; fi
  case "$STAGE" in
    plan|execute|review|fix|qa) printf 'build.%s' "$STAGE" ;;
    orchestrate) printf 'orchestrate' ;;
  esac
}

# claude_ladder — the claude-lane candidates for this call, one per line,
# starting at $MODEL. The call's own role when its primary IS $MODEL and it names
# a failover rung; otherwise claude.ladder from $MODEL's rung on (a single-model
# role, or a model the caller pinned by env, walks the generic ladder from
# wherever it sits in it); otherwise $MODEL alone. Only the claude-runner rungs:
# a codex or grok rung is the outer ladder's business.
claude_ladder() {
  local role rows
  role=$(model_role_for_stage)
  if [ -n "$role" ] && rows=$(ac_ladder "$role" 2>/dev/null); then
    rows=$(printf '%s\n' "$rows" | awk -F'\t' '$3=="claude"{print $2}')
    # A role that names failover rungs owns its ladder. One that names only
    # its primary inherits claude.ladder's from that model on, as every
    # single-model lane did when the rungs were literals here.
    if [ "$(head -1 <<<"$rows")" = "$MODEL" ] && [ "$(printf '%s\n' "$rows" | wc -l)" -gt 1 ]; then
      printf '%s\n' "$rows"; return 0
    fi
  fi
  if rows=$(ac_ladder claude.ladder 2>/dev/null); then
    rows=$(printf '%s\n' "$rows" | awk -F'\t' -v m="$MODEL" '$3=="claude" && $2==m {on=1} on && $3=="claude" {print $2}')
    [ -n "$rows" ] && { printf '%s\n' "$rows"; return 0; }
  fi
  printf '%s\n' "$MODEL"
}
# <<< model routes

# THE SPEND GATE (BH-1141 phase 2). Sourced AFTER cost-row.sh and after $COST,
# because a refusal writes a row through the same writer every billed row goes
# through. Same sibling-first chain as every library above, and the same stubs
# on a box whose sync has not landed it: `precall` and `runner_ok` both answer
# "allow", `refused_row` writes nothing, and every path below runs exactly as it
# ran before this shipped. A gate that fails closed on its own absence would
# take every lane in the fleet down with one bad rsync.
# shellcheck source=bin/lib/llm-gate.sh
if   [ -r "$(dirname "$0")/lib/llm-gate.sh" ]; then . "$(dirname "$0")/lib/llm-gate.sh"
elif [ -r "$HARNESS/bin/lib/llm-gate.sh" ];    then . "$HARNESS/bin/lib/llm-gate.sh"; fi
command -v llm_gate_precall    >/dev/null 2>&1 || llm_gate_precall()    { return 0; }
command -v llm_gate_runner_ok  >/dev/null 2>&1 || llm_gate_runner_ok()  { return 0; }
command -v llm_gate_refused_row >/dev/null 2>&1 || llm_gate_refused_row() { return 0; }
# THE KILL SWITCHES AS SETTINGS ROWS (BH-2432): cliff-route-off, cliff-refuse-off,
# context-kill-off and agent-call-ledger-off are read with `lane_switch <name>
# file` — switch.<name>[.<box>] first, else flags/<name>, never /api/flags. A box
# whose sync has not landed the lib gets a shim that reads the file exactly as
# before: never `|| exit 1`, because suites copy this script into scratch trees.
# shellcheck source=bin/lib/lane-switch.sh
if   [ -r "$(dirname "$0")/lib/lane-switch.sh" ]; then . "$(dirname "$0")/lib/lane-switch.sh" 2>/dev/null || true
elif [ -r "$HARNESS/bin/lib/lane-switch.sh" ];    then . "$HARNESS/bin/lib/lane-switch.sh" 2>/dev/null || true; fi
command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "$HARNESS/flags/$1" ]; }
# THE OPERATOR KNOBS AS SETTINGS ROWS (BH-1636). llm-gate.sh sources lane-gate.sh,
# so a `lib.agent-call.<env>` row (catalog/lanes.d/_lib.json) is exported here,
# before any of them is read. No row exports nothing, and neither does a box
# without lane-gate.sh or with LANE_GATE_DISABLE=1: the call runs as before.
[ "${LANE_GATE_DISABLE:-0}" = 1 ] || { command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply agent-call; } || true
# THE HEADLESS SESSION PROFILE (P1, bin/lib/session-profile.sh): per-stage cache
# TTL, strict MCP, user plugins off, per-machine prompt sections out of the
# cached prefix. DARK until SESSION_PROFILE_STAGES names a stage (a
# lib.session-profile.* settings row, or env on a canary box). A box whose sync
# has not landed the lib gets the identity stubs: no flag, no env, no file.
# shellcheck source=bin/lib/session-profile.sh
if   [ -r "$(dirname "$0")/lib/session-profile.sh" ]; then . "$(dirname "$0")/lib/session-profile.sh"
elif [ -r "$HARNESS/bin/lib/session-profile.sh" ];    then . "$HARNESS/bin/lib/session-profile.sh"; fi
command -v session_profile_build    >/dev/null 2>&1 || session_profile_build()    { SP_ACTIVE=""; SP_ARGS=(); SP_ENV=(); SP_SETTINGS=""; SP_TTL=""; return 0; }
command -v session_profile_ttl_seen >/dev/null 2>&1 || session_profile_ttl_seen() { return 0; }
[ "${LANE_GATE_DISABLE:-0}" = 1 ] || { command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply session-profile; } || true
# THE PRE-CALL GUARD (K3, bin/lib/call-guard.sh): never pay twice for the same
# work. Knobs are lib.call-guard.* settings rows. A box whose sync has not
# landed the lib gets stubs that never engage: exactly the behaviour before K3.
# shellcheck source=bin/lib/call-guard.sh
if   [ -r "$(dirname "$0")/lib/call-guard.sh" ]; then . "$(dirname "$0")/lib/call-guard.sh"
elif [ -r "$HARNESS/bin/lib/call-guard.sh" ];    then . "$HARNESS/bin/lib/call-guard.sh"; fi
command -v call_guard_precall >/dev/null 2>&1 || call_guard_precall() { CG_STATE=off; return 0; }
command -v call_guard_rung_ok >/dev/null 2>&1 || call_guard_rung_ok() { return 0; }
command -v call_guard_finish  >/dev/null 2>&1 || call_guard_finish()  { return 0; }
CG_STATE=""; CG_REASON=""
# THE LIVE-COST AND TRIPWIRE SEAMS (BH-3481.0). The tripwire alerts only and
# never stops a call (BH-6705): tw_check_build always answers rc 1, so the live
# meter never writes $OUT.tripwire and the lines that read it below are inert.
# A box whose sync has not landed the libs runs with no meter and no check.
# shellcheck source=bin/lib/cost-live.sh
if   [ -r "$(dirname "$0")/lib/cost-live.sh" ]; then . "$(dirname "$0")/lib/cost-live.sh"
elif [ -r "$HARNESS/bin/lib/cost-live.sh" ];    then . "$HARNESS/bin/lib/cost-live.sh"; fi
# shellcheck source=bin/lib/build-tripwire.sh
if   [ -r "$(dirname "$0")/lib/build-tripwire.sh" ]; then . "$(dirname "$0")/lib/build-tripwire.sh"
elif [ -r "$HARNESS/bin/lib/build-tripwire.sh" ];    then . "$HARNESS/bin/lib/build-tripwire.sh"; fi
# THE HARD BUDGET CAPS (BH-4488, BH-4489): budget.stage.<stage>.* and
# budget.project.<project>.day_usd settings rows, every stage. A box whose sync
# has not landed the lib gets a stub that never refuses; the BUDGET_STOP marker
# itself is still honoured inline below, without the lib.
# shellcheck source=bin/lib/budget-stop.sh
if   [ -r "$(dirname "$0")/lib/budget-stop.sh" ]; then . "$(dirname "$0")/lib/budget-stop.sh"
elif [ -r "$HARNESS/bin/lib/budget-stop.sh" ];    then . "$HARNESS/bin/lib/budget-stop.sh"; fi
command -v bs_gate >/dev/null 2>&1 || bs_gate() { return 0; }
# THE EGRESS ALLOWLIST (BH-4492): egress.stage.<stage>.hosts settings rows. A
# box whose sync has not landed the lib runs every stage unfenced, as before.
# shellcheck source=bin/lib/egress.sh
if   [ -r "$(dirname "$0")/lib/egress.sh" ]; then . "$(dirname "$0")/lib/egress.sh"
elif [ -r "$HARNESS/bin/lib/egress.sh" ];    then . "$HARNESS/bin/lib/egress.sh"; fi
command -v eg_begin >/dev/null 2>&1 || eg_begin() { EG_WRAP=(); }
command -v eg_end   >/dev/null 2>&1 || eg_end()   { :; }
command -v cost_live_on            >/dev/null 2>&1 || cost_live_on()            { CL_OFF=absent; return 1; }
command -v cost_live_meter         >/dev/null 2>&1 || cost_live_meter()         { return 0; }
command -v cost_live_boundary_push >/dev/null 2>&1 || cost_live_boundary_push() { return 0; }
[ "${LANE_GATE_DISABLE:-0}" = 1 ] || { command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply call-guard; } || true
# THE KILLS AS SETTINGS ROWS (BH-2538): lib.context-kill.* rows become the
# CONTEXT_KILL_TOKENS_<LANE> env _ctx_kill_row reads. No row exports nothing.
[ "${LANE_GATE_DISABLE:-0}" = 1 ] || { command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply context-kill; } || true
[ "${LANE_GATE_DISABLE:-0}" = 1 ] || { command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply runner-fastfail; } || true
# OWN-ACCOUNT PINS (BH-1657): which Claude account a project is pinned to, by
# label, from the settings row account.<project> (env ACCOUNT_OWN_PROJECTS only
# when this box has no settings answer). Sourced after llm-gate so it reuses the
# lane-gate settings cache that file already loaded. Absent = nothing is pinned,
# which is exactly the behaviour before it shipped.
# shellcheck source=bin/lib/project-account.sh
if   [ -r "$(dirname "$0")/lib/project-account.sh" ]; then . "$(dirname "$0")/lib/project-account.sh"
elif [ -r "$HARNESS/bin/lib/project-account.sh" ];    then . "$HARNESS/bin/lib/project-account.sh"; fi
command -v account_label_for_project >/dev/null 2>&1 || account_label_for_project() { :; }
command -v project_account_exports   >/dev/null 2>&1 || project_account_exports()   { return 1; }
# BH-3559: alias-aware live match and the one-per-window refusal alert. A box
# whose lib predates them keeps the exact-label match and stays silent.
command -v project_account_live_matches >/dev/null 2>&1 || project_account_live_matches() { [ "$(auth_account_for_fp "$(auth_fp_for_runner claude 2>/dev/null)" 2>/dev/null)" = "$1" ]; }
command -v project_account_alert_unavailable >/dev/null 2>&1 || project_account_alert_unavailable() { :; }
command -v project_account_alert_resolve     >/dev/null 2>&1 || project_account_alert_resolve()     { :; }
[ "${LANE_GATE_DISABLE:-0}" = 1 ] || { command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply project-account; } || true
# THE ADVISOR (BH-3491): `--advisor <m>` on the claude rung of the stages in
# AGENT_ADVISOR_STAGES (lib.advisor.* row, registry default "execute fix"), when
# the settings row advisor.<project> / advisor.default names one. Same settings
# cache as the account pin above. Absent lib = no advisor, the call as before.
# shellcheck source=bin/lib/advisor.sh
if   [ -r "$(dirname "$0")/lib/advisor.sh" ]; then . "$(dirname "$0")/lib/advisor.sh"
elif [ -r "$HARNESS/bin/lib/advisor.sh" ];    then . "$HARNESS/bin/lib/advisor.sh"; fi
command -v advisor_for_call       >/dev/null 2>&1 || advisor_for_call()       { :; }
command -v advisor_launch_refused >/dev/null 2>&1 || advisor_launch_refused() { return 1; }
command -v advisor_refused_flag   >/dev/null 2>&1 || advisor_refused_flag()   { return 1; }
[ "${LANE_GATE_DISABLE:-0}" = 1 ] || { command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply advisor; } || true
# ADV_DROPPED: this call's launch refused --advisor once, so no later attempt
# carries it. ADV_ATTEMPT: the advisor the last claude attempt ran with.
ADV_DROPPED=""; ADV_ATTEMPT=""
LLM_GATE_REASON="${LLM_GATE_REASON:-}"
GATE_REFUSED=""
# LAST_ATTEMPT_USD: the last run_attempt's spend, for the BUDGET STOP line (BH-4609).
LAST_ATTEMPT_USD=""
# DID ANY RUNG ACTUALLY EXECUTE, AND WITH WHAT RC (BH-1141 round 2, B1).
# A refusal is only "nothing was called and nothing was billed" for the WHOLE
# CALL when no rung ran at all. On a mixed ladder — the primary RUNS, fails and
# is billed, and every rung below it is then refused — the last thing that
# happened is a refusal, but money was spent, so exiting 74 would tell
# alert-triage, review-autopilot and preplan that this call is free to retry
# next tick. They would re-buy the same billed failure every tick, which is the
# spend loop this ticket exists to close, created by its own fix.
# ANY_RAN is set where the money is spent (run_attempt, after the CLI returns)
# and nowhere else; LAST_RAN_RC is that attempt's rc. The exit below prefers it
# over a trailing 74.
ANY_RAN=""; LAST_RAN_RC=""
# K3: every runner that actually executed, and the class:detail of each failure
# the ladder classified — how call_guard_finish tells a subscription 429 (it
# billed nothing) from a real paid failure.
CG_RAN_RUNNERS=""; LADDER_KINDS=""

# >>> hub-no-build
# THE HUB RUNS NO AGENT BUILD WORK (BH-393; the policy has been
# docs/HUB-THINNING-PLAN.md since 2026-08-24). On 2026-09-15 ten `up10`
# self-improvement lanes were executing on the hub when /root/harness was
# wiped out from under them. A policy whose only enforcement is a paragraph is
# not a control, so here it is as one.
#
# PLACED HERE ON PURPOSE: before the runner is resolved, before the account
# pick, before the phase row is opened and before any run_attempt. Nothing is
# called and nothing is billed — no cost row, no provenance row, no beat. The
# refusal marker goes into $OUT for the same reason the no-tools refusal does:
# a caller that reads $OUT on a nonzero rc must read a refusal, not whatever a
# previous attempt left at that path.
#
# Sibling-first, then the deployed path, then a no-op: a box mid-sync that has
# not received the lib yet behaves EXACTLY as it did before this shipped. A
# guard that fails closed on its own absence would take every build lane in the
# fleet down with one bad rsync.
# shellcheck source=bin/lib/hub-box.sh
for _hb in "$(dirname "$0")/lib/hub-box.sh" "$HARNESS/bin/lib/hub-box.sh"; do
  [ -r "$_hb" ] && { . "$_hb"; break; }
done
command -v hub_no_build_refuse >/dev/null 2>&1 || hub_no_build_refuse() { return 1; }
if hub_no_build_refuse "$STAGE" "${HARNESS_TICKET:-$PROJECT}"; then
  printf 'AGENT_CALL_REFUSED hub-no-build the %s lane does not run on the hub\n' "$STAGE" > "$OUT" 2>/dev/null
  exit 77
fi
# <<< hub-no-build

# The stage name, made safe to paste into a VARIABLE NAME. Every stage until
# 2026-09-16 was a single lowercase word, so this was a plain upcase — and the
# first hyphenated one (`preplan-files`, BH-499) did not produce a wrong runner,
# it killed the script on line 3: `${!RUNNER_PREPLAN-FILES}` is an invalid
# variable name, bash prints that to stderr, and under `set -u` the very next
# line dies on an unbound RUNNER. No cost row, no output file, nothing in a log
# the caller reads. The stage's own spelling is untouched — it is what the cost
# row's `stage` column carries, and that column is what the ledger joins on.
SU=$(printf '%s' "$STAGE" | tr '[:lower:]' '[:upper:]' | tr -c '[:alnum:]_' '_')
# THE RUNNER COMES FROM THE stage.<stage> ROUTE (BH-1765). Per field: an
# operator's RUNNER_<SU> / RUNNER_<SU>_FALLBACK still wins, then the route's
# rung 0 / rung 1 (stage_runner_for, which never alerts and fails open), then
# claude as before, noted once a day in failovers.log so an unrouted stage is
# visible. An env runner that disagrees with a route that exists is one ALERTS
# line per (stage, project) per UTC day: the override is deliberate, but it
# should not be forgotten once the row says something else.
# The read is cached on the box, the "no route" answer included, for
# AGENT_CALL_STAGE_ROUTE_TTL_S (0 = every call asks), and the worker wait is
# capped at AGENT_CALL_STAGE_ROUTE_TIMEOUT_S with no retry (BH-1837): every call
# of every lane pays this read, and uncached it cost up to ~17 s per call with
# the worker down.
RVAR="RUNNER_$SU"; RUNNER="${!RVAR:-}"
FVAR="RUNNER_${SU}_FALLBACK"; FALLBACK="${!FVAR:-}"
_SR_ROUTE=""; _SR_FALLBACK=""
if command -v stage_runner_for >/dev/null 2>&1 \
   && _sr=$(stage_runner_for "$STAGE" "$PROJECT" "${AGENT_CALL_STAGE_ROUTE_TTL_S:-120}" "${AGENT_CALL_STAGE_ROUTE_TIMEOUT_S:-3}" 2>/dev/null); then
  IFS=$'\t' read -r _SR_ROUTE _SR_FALLBACK <<<"$_sr"
fi
_SR_ROLE="stage.$(printf '%s' "$STAGE" | tr '[:upper:]' '[:lower:]')"
_ACDAY=$(date -u +%Y%m%d)
_ACKEY=$(printf '%s-%s' "$SU" "$PROJECT" | tr -c 'A-Za-z0-9._-' '_')
if [ -n "$RUNNER" ] && [ -n "$_SR_ROUTE" ] && [ "$RUNNER" != "$_SR_ROUTE" ]; then
  _f="$HARNESS/flags/alerted-runner-override-$_ACKEY-$_ACDAY"
  [ -f "$_f" ] || { mkdir -p "$HARNESS/flags" 2>/dev/null; touch "$_f" 2>/dev/null
    echo "$(STAMP) [$PROJECT] $STAGE: $RVAR env=$RUNNER overrides route $_SR_ROLE=$_SR_ROUTE — the env value runs. Drop it from env to follow the route, or change the route on the console Model routes page." >> "$ALERTS" 2>/dev/null; }
fi
if [ -z "$RUNNER" ]; then
  RUNNER="$_SR_ROUTE"
  if [ -z "$RUNNER" ]; then
    RUNNER=claude
    _f="$HARNESS/flags/noted-stage-route-none-$_ACKEY-$_ACDAY"
    [ -f "$_f" ] || { mkdir -p "$HARNESS/flags" 2>/dev/null; touch "$_f" 2>/dev/null
      echo "$(STAMP) $STAGE/$PROJECT: no $_SR_ROLE route and no $RVAR — running claude" >> "$HARNESS/logs/failovers.log" 2>/dev/null; }
  fi
fi
[ -z "$FALLBACK" ] && FALLBACK="$_SR_FALLBACK"
[ -z "$FALLBACK" ] && [ "$RUNNER" != "claude" ] && FALLBACK=claude

# --- AGENT_CALL_RUNNERS: the caller names the only lanes it will ACCEPT ------
# (BH-1019, cromford#818.) The ladder's whole design is that SOMETHING
# answers, and for a build stage that is right. For a caller whose gate then
# REFUSES what a lower rung produced, it is a purchase made to be thrown away:
# the merge conductor's head-bound re-review asks for a Claude read of a head,
# and bin/lib/review-provenance.sh rejects a grok/kimi verdict on arrival — so
# #818 bought five fallback-lane reviews of one PR and binned every one of them.
#
# The fix belongs HERE and not at the call site, because the call site cannot
# see which rung will serve: it hands over a prompt and gets an answer back. A
# caller says `AGENT_CALL_RUNNERS=claude` and this script will run the claude
# lane, its same-vendor recovery and nothing else — no grok tier-2, no
# configured fallback, no OpenRouter, no Fireworks. If claude is not available
# at all the call is REFUSED before a single token is bought: rc 2, the marker
# in $OUT, no cost row, no provenance marker, nothing billed anywhere.
#
# A comma- or space-separated list is allowed (`claude,openrouter`) and unset —
# the default everywhere else in the fleet — leaves every path below exactly as
# it was. An allowed-but-unconfigured primary is replaced by the FIRST name in
# the list rather than by the usual `claude` promotion, so the list is the whole
# truth about which vendors this call may reach.
#
# NORMALISED ONCE, HERE. `" claude"` with a leading space used to extract an
# EMPTY first name below, so `runner_ready ""` failed and every call this caller
# made was refused rc 2 — an operator typo that looks exactly like an outage.
# Separators collapse to single commas and the ends are trimmed, so the list is
# the same list however it was spelled.
AGENT_CALL_RUNNERS="${AGENT_CALL_RUNNERS:-}"
if [ -n "$AGENT_CALL_RUNNERS" ]; then
  AGENT_CALL_RUNNERS="${AGENT_CALL_RUNNERS//[[:space:],]/,}"
  while case "$AGENT_CALL_RUNNERS" in *,,*) true ;; *) false ;; esac; do
    AGENT_CALL_RUNNERS="${AGENT_CALL_RUNNERS//,,/,}"
  done
  AGENT_CALL_RUNNERS="${AGENT_CALL_RUNNERS#,}"; AGENT_CALL_RUNNERS="${AGENT_CALL_RUNNERS%,}"
fi
runner_allowed() {
  [ -n "$AGENT_CALL_RUNNERS" ] || return 0
  case ",$AGENT_CALL_RUNNERS," in *",${1:-},"*) return 0 ;; esac
  return 1
}
if [ -n "$AGENT_CALL_RUNNERS" ]; then
  runner_allowed "$RUNNER"   || RUNNER="${AGENT_CALL_RUNNERS%%,*}"
  runner_allowed "$FALLBACK" || FALLBACK=""
fi

# >>> model-runner-match
# THE ARGV MODEL AND THE PRIMARY RUNNER MUST AGREE (BH-1765). A caller that asks
# for a claude model on a stage whose runner is grok used to get grok's route
# model with nothing said. Judged here, at the end of runner selection and
# before the llm-gate precall, the phase row and any rung, and only for the
# primary: fallback rungs, grok tier-2 and cliff routes are later decisions.
# openrouter / fireworks / gemini remap models on purpose, and a model whose
# family is not recognised (an alias, a kimi id) is never judged.
# AGENT_CALL_MODEL_MISMATCH=refuse stops the call, rc 74 (nothing called,
# nothing billed); any other value, unset included, warns and runs as before.
model_runner_family() {
  case "${1:-}" in
    claude-*) echo claude ;;
    grok-*|x-ai/grok*) echo grok ;;
    gpt-*|*codex*) echo codex ;;
    *) echo unknown ;;
  esac
}
_MFAM=$(model_runner_family "$MODEL")
case "$RUNNER" in claude|grok|codex) _MRUN="$RUNNER" ;; *) _MRUN="" ;; esac
if [ "$_MFAM" != unknown ] && [ -n "$_MRUN" ] && [ "$_MFAM" != "$_MRUN" ]; then
  case "$RUNNER" in
    grok)  _MRUNG=$(grok_model 2>/dev/null) ;;
    codex) _MRUNG=$(codex_model 2>/dev/null) ;;
    *)     _MRUNG="$MODEL" ;;
  esac
  _MMSG="MODEL/RUNNER MISMATCH: $STAGE/$PROJECT asked for $MODEL but $RVAR=$RUNNER would run ${_MRUNG:-its route model}"
  _MMODE="${AGENT_CALL_MODEL_MISMATCH:-warn}"; [ "$_MMODE" = refuse ] || _MMODE=warn
  _f="$HARNESS/flags/alerted-model-runner-mismatch-$(printf '%s-%s-%s-%s' "$SU" "$PROJECT" "$RUNNER" "$MODEL" | tr -c 'A-Za-z0-9._-' '_')-$_ACDAY"
  [ -f "$_f" ] || { mkdir -p "$HARNESS/flags" 2>/dev/null; touch "$_f" 2>/dev/null
    echo "$(STAMP) [$PROJECT] $_MMSG (AGENT_CALL_MODEL_MISMATCH=$_MMODE). Pass a $RUNNER-family model, or change $RVAR / the $_SR_ROLE route." >> "$ALERTS" 2>/dev/null; }
  # failovers.log: every REFUSED call gets its line (each one is a real stop
  # with its own refused row). A warned call runs anyway, so its line is once per
  # (stage, runner, model) per UTC day, across projects (BH-1837); the ALERTS
  # line above stays per project.
  _f="$HARNESS/flags/noted-model-runner-mismatch-$(printf '%s-%s-%s' "$SU" "$RUNNER" "$MODEL" | tr -c 'A-Za-z0-9._-' '_')-$_ACDAY"
  if [ "$_MMODE" = refuse ] || [ ! -f "$_f" ]; then
    [ "$_MMODE" = refuse ] || { mkdir -p "$HARNESS/flags" 2>/dev/null; touch "$_f" 2>/dev/null; }
    echo "$(STAMP) [$PROJECT] $STAGE $_MMSG — ${_MMODE}$([ "$_MMODE" = refuse ] && echo ': refused, nothing was called and nothing was billed')" >> "$HARNESS/logs/failovers.log" 2>/dev/null
  fi
  if [ "$_MMODE" = refuse ]; then
    printf 'AGENT_CALL_REFUSED model-runner-mismatch %s %s %s\n' "$STAGE" "$MODEL" "$RUNNER" | tee "$OUT.err" > "$OUT" 2>/dev/null
    llm_gate_refused_row "$STAGE" "$PROJECT" "$RUNNER" "$MODEL" 74 model-runner-mismatch
    exit 74
  fi
fi
# <<< model-runner-match

# NO-TOOLS CONTRACT (AGENT_CALL_NO_TOOLS=1, 2026-08-25, wave E).
#
# Some callers need a call that CANNOT touch the world — the prompt-eval lane
# replays recorded board states, and a session that took the SOP's instructions
# literally would comment on real client tickets and launch real builds with the
# hub's real credentials. Telling the model not to is not a control: the model is
# the thing under test, and a prompt that says "do not act" is exactly what a
# prompt regression could break.
#
# So the restriction is mechanical and it is a CONTRACT, not a hint:
#   * claude lanes run with `--tools ""` (the CLI's documented "disable all
#     tools") and WITHOUT --dangerously-skip-permissions. If the tool ban somehow
#     failed, the honest failure is a call that stalls asking for permission, not
#     one that silently acts on a client's board.
#   * every other runner REFUSES. codex/grok/gemini/openrouter/fireworks have no
#     equivalent flag we have verified, and a lane that cannot guarantee the
#     contract must not run rather than run unguarded.
#   * the survival ladder is disabled for the same reason — a tier-3/4 failover
#     would silently hand the prompt to exactly those unguarded runners.
#
# ⚠️ ENFORCEMENT STATUS: the flag is verified to PARSE on the installed CLI
# (it reaches model resolution, so argv is accepted). That tools are actually
# absent from the session is UNVERIFIED until the first live eval run — see the
# eval lane's bounds in catalog/context-budgets.json. Which is why the env scrub
# in prompt-eval.sh and the prompt envelope both exist: three layers, and only
# one of them is currently proven.
NO_TOOLS="${AGENT_CALL_NO_TOOLS:-0}"

# TOOL ALLOWLIST (AGENT_CALL_TOOLS, BH-4065). The middle ground between the full
# tool set and NO_TOOLS: a comma-separated list of the ONLY built-in tools the
# session gets, e.g. AGENT_CALL_TOOLS=WebSearch for a lane that reads untrusted
# web content. A denylist (AGENT_DISALLOWED_TOOLS) leaves Read, WebFetch, MCP and
# whatever the CLI adds next, and a session reading attacker-written pages with
# those can read /etc/harness and send it out in a URL. So it is the same
# contract as NO_TOOLS, applied to a list instead of to nothing:
#   * claude lanes run with `--tools "<list>"` and `--strict-mcp-config` over an
#     empty server set (MCP tools are not built-ins, so --tools alone would keep
#     them). --dangerously-skip-permissions stays: the listed tools are the ones
#     the caller wants used, and in -p mode a prompt is a stall, not a guard.
#   * every other runner REFUSES (rc 78), and the survival ladder is off.
#   * a value that is not a plain comma list of tool names REFUSES too: a typo
#     that fell back to the full tool set is the failure this exists to stop.
# NO_TOOLS wins when both are set. TOOL_FENCED is "either one is in force".
TOOLS_ALLOW=""; TOOLS_BAD=""
if [ "$NO_TOOLS" != 1 ] && [ -n "${AGENT_CALL_TOOLS:-}" ]; then
  if [[ ${AGENT_CALL_TOOLS} =~ ^[A-Za-z][A-Za-z0-9_]*(,[A-Za-z][A-Za-z0-9_]*)*$ ]]; then
    TOOLS_ALLOW="$AGENT_CALL_TOOLS"
  else
    TOOLS_BAD=1
  fi
fi
TOOL_FENCED=0
{ [ "$NO_TOOLS" = 1 ] || [ -n "$TOOLS_ALLOW" ] || [ -n "$TOOLS_BAD" ]; } && TOOL_FENCED=1

# IS THE OPENROUTER FLOOR KNOWN DEAD? (2026-09-23 pool loop) A key past its own
# spend limit answers every call with a 403 "Key limit exceeded", and a ladder
# that still counts that lane as ready buys a failed rung on every stage that
# reaches it — 398 deferred pool runs in one night, each ending on that 403.
# Two readings, either one is enough:
#   1. the hub canary's record. bin/claude-auth-check.sh marks <box>-openrouter
#      LANE DOWN in state/lane-down/ (and state/claude-auth-down.txt) and clears
#      it the pass the lane answers again. Only the hub runs the canary, so the
#      id is the hub's own lanes' (LANE_DOWN_SELF, default hub); a box with no
#      record reads nothing.
#   2. the key's own headroom, GET /api/v1/key (free, no tokens), cached for
#      OPENROUTER_HEADROOM_TTL_S per key fingerprint so a busy ladder asks once.
#      Down when limit_remaining is below OPENROUTER_HEADROOM_MIN_USD. A key with
#      no limit, an unreadable answer or a failed request is NOT down: the
#      ladder's own classification still catches a real refusal. Only a key of
#      OpenRouter's own shape (sk-or-...) is sent to the vendor: anything else
#      is not a key it could answer about.
# The key travels in a header read from stdin, never in argv.
openrouter_lane_down() {
  local id="${LANE_DOWN_SELF:-hub}-openrouter" ttl min fp f now at v resp
  [ -f "$HARNESS/state/lane-down/$id" ] && return 0
  grep -qxF "$id" "$HARNESS/state/claude-auth-down.txt" 2>/dev/null && return 0
  fcd_live lane openrouter "${LANE_DOWN_SELF:-hub}" && return 0
  ttl="${OPENROUTER_HEADROOM_TTL_S:-600}"; case "$ttl" in ''|*[!0-9]*) ttl=600 ;; esac
  [ "$ttl" = 0 ] && return 1
  min="${OPENROUTER_HEADROOM_MIN_USD:-1}"; case "$min" in ''|*[!0-9.]*) min=1 ;; esac
  case "${OPENROUTER_API_KEY:-}" in sk-or-*) : ;; *) return 1 ;; esac
  fp=$(printf '%s' "$OPENROUTER_API_KEY" | sha256sum 2>/dev/null | cut -c1-12)
  [ -n "$fp" ] || return 1
  f="$HARNESS/state/openrouter-headroom/$fp"; now=$(date -u +%s)
  at=""; v=""
  [ -r "$f" ] && read -r at v < "$f"
  case "$at" in ''|*[!0-9]*) at=0 ;; esac
  if [ -z "$v" ] || [ $(( now - at )) -ge "$ttl" ]; then
    resp=$(printf 'Authorization: Bearer %s\n' "$OPENROUTER_API_KEY" \
      | curl -s -m 10 -H @- "${OPENROUTER_KEY_URL:-https://openrouter.ai/api/v1/key}" 2>/dev/null)
    v=$(printf '%s' "$resp" | jq -r 'if (.data | type) == "object" then (.data.limit_remaining // "unlimited" | tostring) else "unknown" end' 2>/dev/null)
    [ -n "$v" ] || v=unknown
    mkdir -p "${f%/*}" 2>/dev/null && printf '%s %s\n' "$now" "$v" > "$f.$$" 2>/dev/null && mv "$f.$$" "$f" 2>/dev/null
  fi
  case "$v" in ''|unknown|unlimited|null|*[!0-9.-]*) return 1 ;; esac
  awk -v r="$v" -v m="$min" 'BEGIN { exit !(r + 0 < m + 0) }'
}

# NO OPENROUTER WHILE CLAUDE OAUTH WORKS (the operator, 2026-09-24: "No need to use
# OpenRouter if the Claude OAuth is working."). OpenRouter bills per token on top
# of Claude subscriptions that are already paid for, and on 09-21..23 it cost
# ~$1.1K/day as an ordinary fallback while healthy Claude accounts sat idle. So
# as a FALLBACK — the configured RUNNER_<STAGE>_FALLBACK=openrouter arm and the
# tier-3 survival block alike — it is reached only when no Claude account can
# serve this call. A caller that names openrouter as its PRIMARY is not touched.
#   OPENROUTER_FALLBACK=exhausted-only  (default) only when claude is out:
#       claude's account failed on this ladder (exhausted or de-authed, after
#       ladder_recover rotated through every account it could), or the picker
#       says no claude account has headroom (ACCOUNT_ROUTING=1), or there is no
#       claude CLI on this box at all
#   OPENROUTER_FALLBACK=off     never as a fallback (what bin/fly-pool.sh ships
#       to a machine whose hub holds another healthy account)
#   OPENROUTER_FALLBACK=always  the behaviour before this gate
# A skip is ONE failovers.log line per stage, naming why.
_OR_SKIP_NOTED=""
openrouter_fallback_ok() {
  local mode="${OPENROUTER_FALLBACK:-exhausted-only}" why prc=0
  case "$mode" in
    always) return 0 ;;
    off) why="OPENROUTER_FALLBACK=off" ;;
    *)
      case ",$LADDER_ACCOUNT_DEAD_RUNNERS," in *,claude,*) return 0 ;; esac
      command -v claude >/dev/null 2>&1 || return 0
      if [ "${ACCOUNT_ROUTING:-0}" = 1 ] && [ -x "$HARNESS/bin/account-pick.sh" ]; then
        "$HARNESS/bin/account-pick.sh" "$STAGE" claude "$MODEL" >/dev/null 2>&1 || prc=$?
        [ "$prc" = 2 ] && return 0
      fi
      why="a Claude OAuth account can still serve this call (OPENROUTER_FALLBACK=exhausted-only)" ;;
  esac
  if [ -z "$_OR_SKIP_NOTED" ]; then
    _OR_SKIP_NOTED=1
    echo "$(STAMP) [$PROJECT] $STAGE openrouter SKIPPED as a fallback: $why — nothing called, nothing billed; the stage ends on the rungs above (classes: ${LADDER_CLASSES:-none})" >> "$HARNESS/logs/failovers.log"
  fi
  return 1
}

runner_ready() {
  rff_enabled "$1" && rff_live "$HARNESS" "$1" && return 1
  case "$1" in
    codex)  command -v codex >/dev/null && { [ -f "$HOME/.codex/auth.json" ] || [ -n "${CODEX_API_KEY:-}${OPENAI_API_KEY:-}" ]; } ;;
    gemini) command -v gemini >/dev/null && { [ -f "$HOME/.gemini/oauth_creds.json" ] || [ -n "${GEMINI_API_KEY:-}" ]; } ;;
    claude) command -v claude >/dev/null ;;
    openrouter) command -v codex >/dev/null && [ -n "${OPENROUTER_API_KEY:-}" ] && ! openrouter_lane_down ;;
    fireworks) command -v codex >/dev/null && [ -n "${FIREWORKS_API_KEY:-}" ] ;;
    grok) [ -x "$HOME/.grok/bin/grok" ] || command -v grok >/dev/null ;;
    *) return 1 ;;
  esac
}

# PROMPT SIZE GUARD (2026-08-24). No call ships a prompt past the ceiling, and
# an oversized one is NAMED rather than silently sent. xAI doubles the price of
# the WHOLE request past 200K prompt tokens, so a prompt that drifts over the
# cliff costs twice as much with nothing in any log to say why.
#
# HONEST SCOPE, because this guard is easy to over-credit: it bounds the text
# WE assemble. The measured 620K-mean / 3.7M-max grok triage calls are NOT
# assembled prompts — the whole triage assembly is under ~25K tokens (largest
# SOP 17KB, queue head -40, dirs head -20) — they are agentic sessions whose
# accumulated tool results grow the context per call. This guard cannot shrink
# those and does not claim to. It exists so that the assembly can never become
# the problem too, and so that its silence is evidence rather than assumption.
# THE ARGV CEILING, WHICH IS NOT THE SAME THING AS THE PROMPT CEILING
# (2026-09-16, project-5 #1621). prompt_guard above bounds what we ASSEMBLE. This
# bounds what we can pass as a single execve() argument: Linux caps one argv
# element at MAX_ARG_STRLEN = 32 pages = 131072 bytes, and EVERY lane that hands
# the prompt over as `cli ... "$P"` dies there — the codex-backed survival lanes
# (openrouter, fireworks), the codex PRIMARY lane (the execute runner on
# project-4/project-1 and any RUNNER_<STAGE>=codex), grok and gemini.
#
# A 136KB review prompt therefore never ran at all. The whole recorded output of
# the re-review the merge conductor bought for project-5 #1621 was 84 bytes:
#   /root/harness/bin/agent-call.sh: line 872: /usr/bin/timeout: Argument list too long
# — and the fleet read that as "the reviewer had no verdict", parked the PR, and
# closed it to rebuild. bin/review-prs.sh learned the same lesson on the CALLER
# side in 2026-08-14 (project-4 #1181/#1168, 13 silent retries) and switched to
# @file prompts; this is the lane side of it.
#
# `codex exec -` reads the prompt from stdin (its own --help: "If not provided
# as an argument (or if `-` is used), instructions are read from stdin"), which
# has no size limit. Used ONLY above the ceiling, so every prompt that fits in
# argv today is passed byte-for-byte the way it is passed today.
#
# GROK AND GEMINI TAKE THE PROMPT AS ARGV ONLY as far as anyone here has
# verified — neither CLI is installed on the build boxes, so their stdin
# semantics are an assumption, and an assumption is not a transport. Over the
# ceiling those two lanes REFUSE: `PROMPT_TOO_LARGE <bytes> <runner>` into $OUT
# and $OUT.err, rc 79, classified real-failure(prompt_too_large) so the ladder
# descends to a lane that does take stdin. Nothing is truncated and no doomed
# execve is attempted — a truncated review is a verdict on code nobody read.
AGENT_ARGV_MAX="${AGENT_ARGV_MAX:-96000}"
agent_argv_too_big() { [ "${#1}" -ge "${AGENT_ARGV_MAX:-96000}" ]; }

# agent_argv_refuse <runner> <prompt> — what an argv-only lane answers above the
# ceiling instead of attempting an execve that cannot succeed. The marker lands
# in BOTH $OUT and $OUT.err (the ladder scans one, a human reads the other) and
# the rc is 79, which ladder_classify turns into real-failure(prompt_too_large):
# descend a rung, no same-runner retry, no account cooldown — the account is
# fine, the transport is not.
agent_argv_refuse() { # returns 79
  printf 'PROMPT_TOO_LARGE %s %s takes the prompt as argv only (ceiling AGENT_ARGV_MAX=%s); nothing was called and nothing was truncated\n' \
    "${#2}" "$1" "${AGENT_ARGV_MAX:-96000}" | tee "$OUT.err" > "$OUT"
  return 79
}

prompt_guard() { # prompt_guard <text>; echoes possibly-truncated text
  local txt="$1" bytes cap
  cap="${PROMPT_MAX_BYTES:-720000}"        # ~180K tokens, under xAI's 200K cliff
  bytes=${#txt}
  [ "$bytes" -le "$cap" ] && { printf '%s' "$txt"; return 0; }
  local flag="$HARNESS/flags/alerted-prompt-oversize-$(date -u +%Y%m%d)"
  [ -f "$flag" ] || { mkdir -p "$HARNESS/flags"; touch "$flag"
    HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[agent-call] PROMPT OVERSIZE: ${STAGE:-?}/${PROJECT:-?} assembled ${bytes}B (cap ${cap}B) — TRUNCATED oldest-first. Past ~200K tokens xAI bills the whole request double, so this would have cost 2x silently."; }
  # Oldest-first: the tail of a triage prompt is the current scope and the SOP,
  # which is what the turn actually needs. Documented so a lost signal is
  # diagnosable rather than mysterious.
  printf '%s' "${txt: -$cap}"
}

# PROPORTIONAL TO THE JOB, not uniform across jobs that differ 5x. A flat $3
# across every lane truncates precisely the lanes the manifest protects most:
# build-plan/review/fix are declared at 400K ceilings because reading a codebase
# IS the job, and 400K in + output on fable-5 prices well past $3. A
# budget-truncated review carries a verdict on code nobody read, which is worse
# than an expensive one.
#
# Derived from the lane's declared ceiling so the number lives in ONE place —
# the manifest already has it. Priced at input $15/M plus an output allowance of
# 15% of the ceiling at $75/M, rounded up, floored at $3. Generous on purpose:
# a bound that bites normal work is a correctness regression, not a saving.
_budget_for() { # _budget_for <stage> [project] [runner]
  local st="${1:-}" pj="${2:-}" rn="${3:-}" ov cap
  ov="AGENT_CALL_BUDGET_USD_$(printf '%s' "$st" | tr '[:lower:]-' '[:upper:]_')"
  [ -n "${!ov:-}" ] && { printf '%s' "${!ov}"; return; }
  [ -n "${AGENT_CALL_BUDGET_USD:-}" ] && { printf '%s' "$AGENT_CALL_BUDGET_USD"; return; }

  # MAX COST, NOT TARGET COST (the operator 2026-08-27, "I don't want to limit the cost
  # and miss good work"): the dollar bound is a runaway tripwire sized so no
  # legitimate run ever meets it (~10x the largest observed honest stage), and
  # it floors EVERY resolved number below — DB row and manifest derivation
  # alike — so a tightly-derived cap can never kill good work mid-stage. Only
  # an explicit env override above binds verbatim, because that is an operator
  # saying "this exact number, on purpose". Real spend control stays the daily
  # burn ceiling + token ceilings, never this.
  local fl
  case "$st" in
    plan|execute|review|fix|revise|takeover|cost_rows_db) fl=150 ;;
    ideate|prd|mockup|signals|synth|preplan|map) fl=50 ;;
    # Operator-invoked stages that reach the ledger without a cron: naming
    # them here keeps a hand-launched session from being funded by the
    # catch-all. takeover and cost_rows_db adopt/finish a branch (build-shaped
    # money). probe and misc ask one question (confirmation-shaped money).
    # Both pairs now carry a manifest lane — leaving a billed stage unnamed
    # is how context-budget-manifest-test learns to be ignored.
    probe|misc)                                  fl=25 ;;
    *)                                           fl=25 ;;
  esac

  # Coordination DB first, memoized per lane (this runs several times per call
  # and it is a side channel, not the work). job_cap answers ONLY when the
  # catalog actually holds a matching lane — a tier fallback comes back nonzero
  # on purpose, so "nobody sized this lane" still reaches the UNBUDGETED LANE
  # alert below instead of hiding behind a confident-looking number.
  # Phase 7 adds the EXPLICIT flag to the row this reads. A default DB cap keeps
  # the floor above ("max cost, not target cost" — a derived number must never
  # kill good work mid-stage). A row an operator marked explicit=1 binds
  # VERBATIM, the same standing the env override already has, because that is a
  # human saying "this exact number, on purpose" rather than a derivation this
  # code should second-guess. Only a hand-set row can say it: the deploy-time
  # catalog sync never writes that flag.
  #
  # job_cap_row is preferred and job_cap is the fallback, in that order, because
  # bin/ syncs per box and not atomically across the fleet — this script must
  # keep working against a jobs-client.sh that predates phase 7.
  if command -v job_cap_row >/dev/null 2>&1 || command -v job_cap >/dev/null 2>&1; then
    local lane="$st/${pj:-*}/${rn:-*}" dbrow dbcap dbexp
    dbrow="${_JOB_CAP_MEMO[$lane]-}"
    if [ -z "$dbrow" ]; then
      if command -v job_cap_row >/dev/null 2>&1; then
        dbrow=$(job_cap_row "$lane" 2>/dev/null) || dbrow=miss
      else
        dbrow=$(job_cap "$lane" 2>/dev/null) || dbrow=miss
      fi
      _JOB_CAP_MEMO[$lane]="${dbrow:-miss}"
    fi
    if [ -n "$dbrow" ] && [ "$dbrow" != miss ]; then
      dbcap="${dbrow%%$'\t'*}"
      dbexp=""; case "$dbrow" in *$'\t'*) dbexp="${dbrow##*$'\t'}" ;; esac
      if [ "$dbexp" = 1 ]; then
        # VERBATIM — no floor. The row itself carries the operator's reason, so
        # an unusually small bound is explainable from the DB rather than from
        # a guess about which branch of this function produced it.
        awk -v c="$dbcap" 'BEGIN{printf "%.2f", c}'
        return
      fi
      awk -v c="$dbcap" -v f="$fl" 'BEGIN{if (c+0 < f) c=f; printf "%.2f", c}'
      return
    fi
  fi

  # SAME RESOLVER AS THE CEILING JOIN. Selecting by stage alone and taking
  # min() rebuilt "strictest governs" two files from where #87 removed it: for
  # triage that is medic's 80K, so alert-triage — the lane #88 was about — was
  # floored at $3.00 by a ceiling that does not describe it. A lane must never
  # be budgeted against one ceiling and measured against another, so this uses
  # #87's specificity ladder: project (the workload) outweighs runner (the
  # executor), most specific wins, strictest only breaks a genuine tie.
  cap=$(CB="$CONTEXT_BUDGETS"; \
    jq -r --arg s "$st" --arg p "$pj" --arg r "$rn" '
      [ .lanes[]
        | select(.stage == $s)
        | select((.project // $p) == $p) | select((.runner // $r) == $r)
        # SKIP A MALFORMED LANE, do not collapse the resolver. The Python side
        # filters non-numeric ceilings (isinstance check); this port dropped
        # that, so ONE null ceiling made min() yield null and the whole
        # function fall through to "no manifest" — the budget behaving as if
        # the manifest were absent while the ceiling join read the good lane
        # at 400K. That is "budgeted against one ceiling, measured against
        # another", reachable through a manifest authoring slip.
        | select((.ceiling_tokens | type) == "number")
        # PER-RUNNER CEILING, same rule as the Python side: the xAI 200K cliff
        # is a fact about the executor, not the job, so it cannot live in the
        # job ceiling — and it must still bind, because the failover ladder is
        # stage-agnostic and every lane here is grok-reachable. Falls back to
        # the lane ceiling when this runner has no override.
        | { spec: (2 * (if .project then 1 else 0 end) + (if .runner then 1 else 0 end)),
            cap: (if ((.runner_ceilings[$r] // null) | type) == "number"
                  then .runner_ceilings[$r] else .ceiling_tokens end) } ]
      | if length == 0 then empty
        else (max_by(.spec).spec) as $best
             | [ .[] | select(.spec == $best) | .cap ] | min end' "$CB" 2>/dev/null)

  # TWO DIFFERENT NOTHINGS, told apart. "No manifest on this machine" and "the
  # manifest is here and this lane is not in it" want different answers: the
  # first is an environment fact the tier fallback exists for, the second is an
  # UNBUDGETED LANE that should be visible rather than quietly handed a
  # build-tier budget. Real case: execute/anyproj/claude matches nothing,
  # because build-execute pins codex.
  if [ -n "$cap" ] && [ "$cap" != null ]; then
    awk -v c="$cap" -v f="$fl" 'BEGIN{b=c/1e6*15 + (c*0.15)/1e6*75; if (b<f) b=f; printf "%.2f", b}'
    return
  fi
  if [ -r "$CONTEXT_BUDGETS" ]; then
    # Manifest present, lane absent: say so once a day, then fall to the tier
    # so the call still runs. A lane nobody budgeted is a finding, not a crash.
    _UF="$HARNESS/flags/alerted-unbudgeted-lane-$st-$(date -u +%Y%m%d)"
    [ -f "$_UF" ] || { mkdir -p "$HARNESS/flags" 2>/dev/null; touch "$_UF" 2>/dev/null
      HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[agent-call] UNBUDGETED LANE: $st/${pj:-?}/${rn:-?} matches no manifest lane — funded from the stage tier, not from a declared ceiling. Add a lane to catalog/context-budgets.json."; }
  fi
  # NOT the $3 floor. Fly builders never receive catalog/ (fly-sync-harness
  # tars bin/prompts/rules/fleet.conf/fly), so on the very machines that run
  # build lanes the manifest is absent — and flooring there would silently
  # reinstate the truncation this derivation exists to remove. A missing
  # manifest must degrade to the lane's TIER, never to the smallest number.
  printf '%s.00' "$fl"
}

# >>> cliff_route (tests/runner-cliff.bh-656-test.sh drives this block)
# THE 200K CLIFF, AND ROUTING BELOW IT (BH-656). xAI bills the WHOLE request at
# 2x once it exceeds 200,000 tokens. The hub's alert-triage lane runs at a 676K
# median context, so the majority of its grok calls have been billed double —
# and a runner with no cliff at that size is simply cheaper than a doubled grok.
#
# So before a grok attempt is issued, this projects what THIS lane's context
# actually runs at and, past the cliff, skips the call entirely: the ladder
# descends a rung exactly as it does when grok fails, and one line says why.
# Nothing is called, so nothing is billed and no cost row is written.
#
# A CLIFF-ROUTED DESCENT IS A WORKING FAILOVER, not an outage: no vendor failed,
# and the tier-3/3b gates below log it to failovers.log instead of beating and
# ALERTing. (alert-triage triaging its own routing every hour is the failure
# mode that rule exists to prevent.)
#
# Knobs: RUNNER_CLIFF_ROUTE=1 forces it on and 0 (or anything else non-empty)
# off; unset reads `cliff_route` off the lane in catalog/context-budgets.json.
# Kill switch: `lane_switch cliff-route-off file` (settings row
# switch.cliff-route-off[.<box>], else flags/cliff-route-off), which beats the
# env in every form.
# CLIFF_ROUTE_SCAN / _SAMPLE / _MIN_SAMPLES bound and shape the projection.
cliff_route_enabled() { # cliff_route_enabled [runner] ; rc 0 = route
  local rn="${1:-}" on
  lane_switch cliff-route-off file && return 1
  # Garbage is OFF, never on: an operator typo must not start changing which
  # vendor a lane runs on.
  case "${RUNNER_CLIFF_ROUTE:-}" in
    1)  return 0 ;;
    '') : ;;
    *)  return 1 ;;
  esac
  # SAME SPECIFICITY LADDER AS _budget_for AND _ctx_kill_ceiling: project (the
  # workload) outweighs runner (the executor), most specific wins. A lane must
  # not be budgeted against one row and routed by another.
  on=$(jq -r --arg s "$STAGE" --arg p "$PROJECT" --arg r "$rn" '
      [ .lanes[]
        | select(.stage == $s)
        | select((.project // $p) == $p) | select((.runner // $r) == $r)
        | { spec: (2 * (if .project then 1 else 0 end) + (if .runner then 1 else 0 end)),
            on: (.cliff_route == true) } ]
      | if length == 0 then empty
        else (max_by(.spec).spec) as $best
             | [ .[] | select(.spec == $best) | .on ] | any end' \
      "${CONTEXT_BUDGETS:-/nonexistent}" 2>/dev/null)
  [ "$on" = true ]
}

# cliff_projected_context <stage> <project> — what this lane's next call is
# likely to run at, in context tokens, or NOTHING.
#
# THE LANE'S OWN RECENT HISTORY, not the prompt we are about to send: the
# assembled prompt is ~20KB and never crosses anything. What puts a grok session
# past 200K is the agent's own reads during the tool loop, and the only honest
# predictor of that is what this stage has been running at. Median of the last
# few SUCCESSFUL rows, because a median is not moved by one runaway session.
#
# Any runner's rows count. The context is a property of the job, which is the
# manifest's own rule — the runner pin on this lane was removed in 2026-08-25 for
# exactly that reason.
#
# ABSENT IS NOT ZERO, twice over: a blank token count is not a sample, and fewer
# than CLIFF_ROUTE_MIN_SAMPLES rows is no projection at all rather than a median
# of nothing. A box with no history (every fly builder) therefore routes nothing
# and behaves exactly as before.
cliff_projected_context() { # cliff_projected_context <stage> <project>
  local st="${1:-}" pj="${2:-}"
  [ -r "$COST" ] || return 1
  # Bounded read: cost.csv is append-only and grows for the life of the box.
  tail -n "${CLIFF_ROUTE_SCAN:-4000}" "$COST" 2>/dev/null | awk -F, \
    -v st="$st" -v pj="$pj" -v keep="${CLIFF_ROUTE_SAMPLE:-10}" \
    -v min="${CLIFF_ROUTE_MIN_SAMPLES:-3}" '
    $4 == st && $3 == pj && $7 == "0" && $9 ~ /^[0-9]+$/ {
      c = $9 + 0
      if ($11 ~ /^[0-9]+$/) c += $11 + 0
      v[++n] = c
    }
    END {
      if (n < min) exit 0
      lo = n - keep + 1; if (lo < 1) lo = 1
      for (i = lo; i <= n; i++) s[++m] = v[i]
      for (i = 2; i <= m; i++) { x = s[i]; j = i - 1
        while (j > 0 && s[j] > x) { s[j+1] = s[j]; j-- }
        s[j+1] = x }
      printf "%d", s[int((m + 1) / 2)]
    }'
}

# cliff_routed_rc — is the CURRENT rc a cliff route rather than an argv refusal?
# Both answer 79 (see agent_argv_refuse), and they want opposite handling: one
# is a lane that could not carry the prompt, the other is a call we chose not to
# make. The $OUT marker is what tells them apart, so a consumer never has to
# guess from the code alone.
cliff_routed_rc() {
  [ "${RC:-0}" -eq 79 ] || return 1
  head -1 "$OUT" 2>/dev/null | grep -q '^AGENT_CALL_CLIFF_ROUTED'
}

# cliff_routed_runner — WHICH runner was skipped on price, read off the marker
# the route itself wrote (`AGENT_CALL_CLIFF_ROUTED <runner> projected ...`).
# The refusal gates below used the literal `grok` (BH-1039 review r2, N4); it is
# correct today because the grok branch is the only one that cliff-routes, and
# reading it back from the marker keeps it correct when a second one does.
cliff_routed_runner() {
  local r
  r=$(head -1 "$OUT" 2>/dev/null | awk '/^AGENT_CALL_CLIFF_ROUTED/ {print $2}')
  printf '%s' "${r:-grok}"
}

# cliff_next_runner — the rung the ladder would descend to from here. It mirrors
# the two guards below verbatim: a configured fallback that is neither the
# current runner nor grok (tier-2 already tried grok), otherwise the OpenRouter
# survival lane. Naming the rung is what lets the price gate weigh the model
# that rung would ACTUALLY run rather than the stage's argv model.
cliff_next_runner() {
  if [ -n "${FALLBACK:-}" ] && [ "$FALLBACK" != "$RUNNER" ] && [ "$FALLBACK" != grok ]; then
    printf '%s' "$FALLBACK"
  else
    printf '%s' openrouter
  fi
}

# ladder_model_for <runner> — the model THAT RUNNER would actually run for this
# stage. Every rung remaps (BH-1039 review r2, I2): codex runs codex_model (the
# codex.default route), fireworks runs fireworks_model,
# openrouter runs the anthropic/ slug (:1337-1339), and only a `claude` rung runs
# $MODEL itself — which is why a gate that priced $MODEL looked right against a
# claude fallback and was wrong against every other one. It refused a cheap
# fireworks rung and approved a descent onto codex running an opus model.
#
# The remaps here are the SAME expressions the run_attempt branches use; when one
# of those moves, this moves with it or the gate starts pricing a model nobody
# runs.
ladder_model_for() { # ladder_model_for <runner>
  case "${1:-}" in
    codex)     codex_model ;;
    fireworks) fireworks_model ;;
    openrouter)
      case "$MODEL" in
        */*) printf '%s' "$MODEL" ;;
        opus|sonnet|haiku|fable) printf '%s' "~anthropic/claude-$MODEL-latest" ;;
        *) printf '%s' "anthropic/$(printf '%s' "$MODEL" | sed -E 's/-([0-9]+)-([0-9]+)$/-\1.\2/')" ;;
      esac ;;
    *) printf '%s' "$MODEL" ;;
  esac
}

# cliff_refuse_enabled — does THIS lane refuse on a cliff instead of descending?
#
# THE GAP BH-656 LEFT (BH-1039). Routing below the cliff assumed the rung below
# is cheaper. On 2026-09-20 it was not: alert-triage's grok lane cliff-routed and
# the ladder descended to codex's GPT-6 (81 rows, $392) and then to
# Fable 5.1 over OpenRouter at API prices (97 rows, $396) — $793 in 12
# hours against a $39-$61/day baseline. Every descent was a correct failover by
# the rules as written: no vendor had failed. The missing rule is that a lane
# which routed AWAY from its runner ON PRICE must not then buy the same work at
# a hundred times the price. It REFUSES; the caller defers the unit and offers
# it again when the lane can carry it (bin/alert-triage.sh's CLIFF REFUSAL
# block).
#
# The rc is unchanged (79, with the same $OUT marker), so a caller that has
# never heard of this reads exactly what it reads today: a call that did not
# happen. The only difference is that nothing below it was bought first.
#
# Knobs, in the same shape as cliff_route_enabled so the two are read together:
# LADDER_CLIFF_REFUSE=1 forces it on and 0 (or anything else non-empty) off;
# unset reads `cliff_refuse` off the lane in catalog/context-budgets.json.
# Kill switch: `lane_switch cliff-refuse-off file` (settings row
# switch.cliff-refuse-off[.<box>], else flags/cliff-refuse-off), which beats the
# env in every form.
cliff_refuse_enabled() { # cliff_refuse_enabled [runner] ; rc 0 = refuse
  local rn="${1:-}" on
  lane_switch cliff-refuse-off file && return 1
  case "${LADDER_CLIFF_REFUSE:-}" in
    1)  return 0 ;;
    '') : ;;
    *)  return 1 ;;
  esac
  # THE SAME SELECTOR AS cliff_route_enabled, runner term included (BH-1039
  # review, N3). Without the runner term a row pinned to one executor switched
  # refusal on for a different one, so the two halves of one decision — route
  # away, then refuse the rung below — could be read off different rows.
  on=$(jq -r --arg s "$STAGE" --arg p "$PROJECT" --arg r "$rn" '
      [ .lanes[]
        | select(.stage == $s)
        | select((.project // $p) == $p) | select((.runner // $r) == $r)
        | { spec: (2 * (if .project then 1 else 0 end) + (if .runner then 1 else 0 end)),
            on: (.cliff_refuse == true) } ]
      | if length == 0 then empty
        else (max_by(.spec).spec) as $best
             | [ .[] | select(.spec == $best) | .on ] | any end' \
      "${CONTEXT_BUDGETS:-/nonexistent}" 2>/dev/null)
  [ "$on" = true ]
}

# cliff_refuse_costlier <projected-context> — is the rung BELOW actually more
# expensive at this size?  rc 0 = yes, refuse.  rc 1 = no, descend.
#
# THE EXIT PATH (BH-1039 review, B3). A flat refusal has none: a refused call
# writes no cost row, cliff_projected_context is the median of the last ten
# rc-0 rows, so the number that caused the refusal cannot move and the lane
# refuses forever on its own history. Making the decision a PRICE COMPARISON
# gives it one — when the rung below is cheaper the ladder descends exactly as
# BH-656 intended, the call runs, and its row moves the median.
#
# The comparison is like-for-like and deliberately crude: both models priced at
# the SAME projected input size, cliff included (cost_price_tokens applies it),
# output/cache at 0 because the input term is what a 676K-token context is
# about. It answers one question — "is the rung below cheaper than a doubled
# grok at this size" — which is the exact assumption BH-656 made and 2026-09-20
# falsified.
#
# UNKNOWN PRICES REFUSE. This is the one reader in this wave that does not fail
# open, and on purpose: the alternative is to descend on an unpriceable rung,
# which is precisely the $793 shape. Nothing is lost when it refuses — the
# caller re-spools the unit — and the lane's day cap plus the caller's attempt
# cap bound the refusal itself.
cliff_refuse_costlier() { # cliff_refuse_costlier <projected-context> <model-below>
  local proj="${1:-}" bm="${2:-$MODEL}" gm skipped below
  case "$proj" in ''|*[!0-9]*) return 0 ;; esac
  [ -n "$bm" ] || return 0
  command -v cost_price_tokens >/dev/null 2>&1 || return 0
  gm=$(grok_model) || return 0
  skipped=$(cost_price_tokens "$gm" "$proj" 0 0 0) || skipped=""
  below=$(cost_price_tokens "$bm" "$proj" 0 0 0) || below=""
  [ -n "$skipped" ] && [ -n "$below" ] || return 0
  awk -v a="$below" -v b="$skipped" 'BEGIN{ exit !(a + 0 > b + 0) }'
}
# <<< cliff_route

# >>> context_kill (tests/context-kill.bh-653-test.sh drives this block)
# THE CUMULATIVE CONTEXT KILL (BH-653). Every bound this script passes to a
# vendor was measured NOT to fire: `--max-budget-usd` let a $4.67 turn complete
# against a $2.00 cap, and `grok --max-turns 25` ran 56 tool calls — both are
# recorded INERT in catalog/context-budgets.json with their evidence. So the
# enforcement is ours, in the process this script owns and can kill: a sidecar
# meters the session's OWN transcript while the child runs, and when the
# session's cumulative `input_tokens + cache_read` crosses the lane's ceiling
# the child is terminated, $OUT gets a truncation marker as its last line, and
# one lane alert names the lane, the ceiling and the API call count.
#
# UNIT: cumulative over the SESSION, not per request — the same unit the
# manifest's `measured` blocks are stated in. On a --resume the whole session
# counts, because it is one session and it is one context.
#
# Knobs: `context_kill_tokens` per lane in catalog/context-budgets.json (no key
# = unbounded, exactly the old path), CONTEXT_KILL_TOKENS (operator override),
# CONTEXT_KILL_POLL_S (default 15), and the kill switch — `lane_switch
# context-kill-off file` (settings row switch.context-kill-off[.<box>], else
# flags/context-kill-off) or CONTEXT_KILL=0, either of which restores the old
# foreground invocation.
# COST_TRANSCRIPT_ROWS=0 is not a kill switch but it disables the meter all the
# same (no session id, no transcript to read); that case alerts as UNENFORCEABLE.
#
# THE PRICE CLIFF AS A CEILING (BH-1384). CONTEXT_KILL_CLIFF=1 says "bound this
# session under the RUNNER's price cliff rather than at the lane's number, if
# the runner has one": the ceiling becomes min(lane cap, cliff -
# CONTEXT_KILL_CLIFF_MARGIN) and $OUT.cliffcap records that the cliff is what
# lowered it. A model with no `cliff_tokens` in catalog/model-prices.json is
# byte-for-byte the path above — and in today's table that is every claude
# model, so this arms nothing in production until a metered rung has a cliff.
# A lane with NO context_kill_tokens is still unbounded: the cliff LOWERS a
# declared ceiling, it never creates one, because "no key = unbounded" is the
# contract 78 other lanes are running on.
# THE KILL AS A SETTINGS ROW (BH-2538). Every manifest lane's kill is also a
# registered knob (catalog/lanes.d/_lib.context-kill.json), so the console can
# set it: lib.context-kill.context_kill_tokens_<lane>. lib_env_apply exports a
# row, fresh or the box's cached copy in an outage, as the env named below; no
# row and no cache exports nothing, and the manifest's number stands — an outage
# never means "no kill". A row of 0 unarms the lane. The list is an allow-list:
# no other name is ever read indirectly.
_ctx_kill_row() { # _ctx_kill_row <manifest lane> — rc 0 + the row's value, rc 1 when none
  local e v knobs="CONTEXT_KILL_TOKENS_ORCHESTRATOR_TURN CONTEXT_KILL_TOKENS_PROJECT_TRIAGE CONTEXT_KILL_TOKENS_ALERT_TRIAGE CONTEXT_KILL_TOKENS_RESPONDER
    CONTEXT_KILL_TOKENS_ALERTS_MEDIC CONTEXT_KILL_TOKENS_BOX_CHAT CONTEXT_KILL_TOKENS_BUILD_PLAN
    CONTEXT_KILL_TOKENS_BUILD_EXECUTE CONTEXT_KILL_TOKENS_BUILD_REVIEW CONTEXT_KILL_TOKENS_BUILD_FIX
    CONTEXT_KILL_TOKENS_PREPLAN CONTEXT_KILL_TOKENS_PREPLAN_FILES CONTEXT_KILL_TOKENS_DECOMPOSE
    CONTEXT_KILL_TOKENS_PRODUCT_IDEATION CONTEXT_KILL_TOKENS_PROMPT_EVAL CONTEXT_KILL_TOKENS_QA
    CONTEXT_KILL_TOKENS_POSTMERGE_PRODQA CONTEXT_KILL_TOKENS_PREBUILD_REPRO CONTEXT_KILL_TOKENS_PRODUCT_PRD
    CONTEXT_KILL_TOKENS_PRODUCT_MOCKUP CONTEXT_KILL_TOKENS_PRODUCT_REVISE CONTEXT_KILL_TOKENS_PRODUCT_SIGNALS
    CONTEXT_KILL_TOKENS_PRODUCT_SYNTH CONTEXT_KILL_TOKENS_PREPLAN_MAP CONTEXT_KILL_TOKENS_RULE_MINER
    CONTEXT_KILL_TOKENS_TRAP_EVAL CONTEXT_KILL_TOKENS_LEAD_REVIEW CONTEXT_KILL_TOKENS_FEATURE_MAP_DRAFT"
  e="CONTEXT_KILL_TOKENS_$(printf '%s' "${1:-}" | tr 'a-z-' 'A-Z_')"
  case " $(printf '%s' "$knobs" | tr '\n' ' ') " in *" $e "*) ;; *) return 1 ;; esac
  v="${!e:-}"
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$((10#$v))"
}
_ctx_kill_ceiling() { # _ctx_kill_ceiling <stage> [project] [runner] [model]
  local st="${1:-}" pj="${2:-}" rn="${3:-}" md="${4:-}" cap cliff margin want ln c r
  lane_switch context-kill-off file && return 0
  case "${CONTEXT_KILL:-1}" in 0|no|off|false|NO|OFF|FALSE) return 0 ;; esac
  # The operator knob binds verbatim, same standing AGENT_CALL_BUDGET_USD has:
  # a human naming this exact number on purpose.
  [ -n "${CONTEXT_KILL_TOKENS:-}" ] && { printf '%s' "$CONTEXT_KILL_TOKENS"; return 0; }
  # SAME SPECIFICITY LADDER AS _budget_for: project (the workload) outweighs
  # runner (the executor), most specific wins, strictest only breaks a tie. A
  # lane must never be budgeted against one ceiling and killed against another.
  # The most specific MATCHING lane decides first, key or no key, and only then
  # is its number read: a pinned lane that is UNARMED (BH-2538: no measured
  # rows yet, e.g. alerts-medic on stage triage) stays unbounded rather than
  # falling through to the unpinned sibling's number sized for other work. A
  # lane with no context_kill_tokens is never defaulted, which is what makes
  # "no key = unbounded" true instead of aspirational.
  cap=""
  while IFS=$'\t' read -r ln c; do
    [ -n "$ln" ] || continue
    # a settings row for THIS lane wins over its manifest number (BH-2538)
    command -v _ctx_kill_row >/dev/null 2>&1 && r=$(_ctx_kill_row "$ln") && c="$r"
    case "$c" in ''|0|*[!0-9]*) continue ;; esac
    { [ -z "$cap" ] || [ "$c" -lt "$cap" ]; } && cap="$c"
  done < <(jq -r --arg s "$st" --arg p "$pj" --arg r "$rn" '
      [ .lanes[]
        | select(.stage == $s)
        | select((.project // $p) == $p) | select((.runner // $r) == $r)
        | { spec: (2 * (if .project then 1 else 0 end) + (if .runner then 1 else 0 end)),
            lane: .lane, cap: .context_kill_tokens } ]
      | if length == 0 then empty
        else (max_by(.spec).spec) as $best
             | .[] | select(.spec == $best) | "\(.lane)\t\(.cap // "")" end' \
      "${CONTEXT_BUDGETS:-/nonexistent}" 2>/dev/null)
  case "$cap" in ''|null) return 0 ;; esac
  # THE CLIFF, ONLY WHERE IT IS BOTH ASKED FOR AND KNOWN. cost_model_cliff
  # answers rc 1 for a missing table, an unknown model, a null and a non-integer
  # alike — every one of those is "no cliff", never 0, because a 0 here would
  # read as "every request is past the cliff" and floor every session.
  if [ "${CONTEXT_KILL_CLIFF:-}" = 1 ] && [ -n "$md" ] && cliff=$(cost_model_cliff "$md") && [ -n "$cliff" ]; then
    margin="${CONTEXT_KILL_CLIFF_MARGIN:-10000}"
    case "$margin" in ''|*[!0-9]*) margin=10000 ;; esac
    want=$(( cliff - margin ))
    if [ "$want" -lt 1000 ]; then
      # NEVER A SILENT CLAMP. A margin at or past the cliff would otherwise
      # produce a zero or negative ceiling, which kills the session on its first
      # meter read with nothing anywhere saying why.
      echo "$(STAMP) [$PROJECT] $STAGE: CONTEXT_KILL_CLIFF_MARGIN $margin is at or past the $md cliff $cliff — the derived ceiling would be $want, flooring it at 1000 tokens" >> "$HARNESS/logs/failovers.log"
      want=1000
    fi
    # ONLY WHEN THE CLIFF IS WHAT LOWERED IT. A lane cap that is already the
    # smaller number is an ordinary lane-cap kill, and labelling it
    # CLIFF-AVOIDED: would make the alert copy false in one of the two states
    # that render it.
    if [ "$want" -lt "$cap" ]; then
      printf 'cliff=%s ceiling=%s model=%s margin=%s\n' "$cliff" "$want" "$md" "$margin" > "$OUT.cliffcap"
      cap="$want"
    fi
  fi
  printf '%s' "$cap"
}

# The sidecar. It runs beside the child, never in its path: a read that FAILS
# (rc 3 = no transcript yet, rc 4 = no usage yet, or a helper that is simply
# not there) keeps polling and never kills. Fail-open is the right direction
# here — a meter that kills on its own read failure is worse than no meter —
# and the one thing it must not do quietly is nothing, so the first failed read
# of a session writes one line to logs/claude-cost.log.
context_meter() { # context_meter <child-pid> <session-id> <ceiling> <cwd>
  local pid="$1" sid="$2" cap="$3" cwd="$4" line in cr msgs tot said=""
  local errf="$OUT.ctxmeter.err"
  while kill -0 "$pid" 2>/dev/null; do
    sleep "${CONTEXT_KILL_POLL_S:-15}"
    kill -0 "$pid" 2>/dev/null || break
    if ! line=$(eval "${ACCT_EXPORTS:-}"; "$_CTX_TCB" "$sid" --cwd "$cwd" 2>"$errf") || [ -z "$line" ]; then
      [ -n "$said" ] || { said=1
        echo "$(STAMP) [$PROJECT] $STAGE: context meter could not read session $sid — running UNMETERED rather than killing on a failed read ($(head -c 200 "$errf" 2>/dev/null | tr '\n' ' '))" >> "$HARNESS/logs/claude-cost.log"; }
      continue
    fi
    # input|output|cache_read|cache_write|usd|model|messages|files|unpriced
    IFS='|' read -r in _ cr _ _ _ msgs _ _ <<<"$line"
    case "${in}${cr}" in ''|*[!0-9]*) continue ;; esac
    tot=$(( in + cr ))
    [ "$tot" -gt "$cap" ] || continue
    printf 'ceiling=%s total=%s calls=%s session=%s\n' "$cap" "$tot" "${msgs:-0}" "$sid" > "$OUT.ctxkill"
    kill -TERM "$pid" 2>/dev/null
    break
  done
  rm -f "$errf" 2>/dev/null
  return 0
}

# ONE line per kill, and the --id is the session, so two different kills can
# never be merged by the alert state machine and the same kill can never be
# said twice. lane-alert.sh carries it to the medic and the digest; a box that
# does not have it (or whose copy fails) still gets the fact in ALERTS.log.
ctx_kill_alert() { # ctx_kill_alert <model> <ceiling=.. total=.. calls=.. session=..>
  local cm="$1" ck="$2" la line kv _cap="" _tot="" _msgs="" _sid="" _cc="" _cliff=""
  for kv in $ck; do
    case "$kv" in
      ceiling=*) _cap="${kv#*=}" ;; total=*) _tot="${kv#*=}" ;;
      calls=*)   _msgs="${kv#*=}" ;; session=*) _sid="${kv#*=}" ;;
    esac
  done
  # WHICH BOUND FIRED IS THE WHOLE POINT OF THE LINE (BH-1384). A ceiling the
  # price cliff lowered stopped a session to avoid a doubled bill; a lane-cap
  # ceiling stopped one that was simply too big for its lane. The marker is
  # written before the child starts, so the label can never claim an origin the
  # ceiling did not have.
  [ -f "$OUT.cliffcap" ] && { read -r _cc < "$OUT.cliffcap" || true; }
  for kv in $_cc; do case "$kv" in cliff=*) _cliff="${kv#*=}" ;; esac; done
  if [ -n "$_cliff" ]; then
    line="CLIFF-AVOIDED: $STAGE/$PROJECT on $cm stopped at $_tot context tokens against ceiling $_cap, derived from the $_cliff-token price cliff for $cm, after $_msgs API calls (session $_sid) — output truncated, stage fails by policy, no vendor failover"
  else
    line="CONTEXT KILL: $STAGE/$PROJECT on $cm killed at $_tot context tokens against ceiling $_cap after $_msgs API calls (session $_sid) — output truncated, stage fails by policy, no vendor failover"
  fi
  la="$(dirname "$0")/lane-alert.sh"; [ -x "$la" ] || la="$HARNESS/bin/lane-alert.sh"
  if [ -x "$la" ] && "$la" --id "context-kill:$STAGE/$PROJECT/$_sid" --severity warn \
       agent-call "$line" >/dev/null 2>&1; then
    return 0
  fi
  echo "$(STAMP) [agent-call] $line" >> "$ALERTS"
}

# THE REPEAT KILL GOES TO A PERSON (BH-2538). A kill is a runaway backstop, so
# one kill is news and the same work killed again is a pattern no retry fixes:
# every later attempt buys the same session to the same number. The count comes
# from the cost.csv ledger — each killed row's note names the work as
# `tk=<ticket>:fp=<16 hex of the call-guard fingerprint>` — so there is no state
# file. The kill that reaches CONTEXT_KILL_REPEAT_MAX raises ONE critical alert
# (one lane-alert id per piece of work), and ctx_kill_repeat_refuse turns every
# later call for that work into rc 74 before anything is bought.
# THE WORK is what a caller DECLARED: its ticket, or the K3 fingerprint it
# hands the call-guard (AGENT_CALL_FP: a triage shard's ticket + board digest, a
# build's ticket + thread + main, a PR at a head). A call that declares neither
# is not counted: the guard's prompt-sha fallback would fold a lane's identical
# probe prompts into one "work" and stop a healthy lane.
ctx_kill_work() { # sets CK_TK / CK_FP for this call; call BEFORE the guard env is unset
  CK_TK=$(printf '%s' "${AGENT_CALL_TICKET:-${COST_KEY:-${HARNESS_TICKET:-}}}" | tr -dc 'A-Za-z0-9._#-' | cut -c1-64)
  CK_FP=""
  [ -n "${AGENT_CALL_FP:-}" ] && CK_FP=$(printf '%s' "$AGENT_CALL_FP" | sha256sum | cut -c1-16)
  return 0
}
ctx_kill_repeats() { # prints how many kills of this work the ledger holds in the window
  local win since rows
  [ -n "${CK_TK:-}${CK_FP:-}" ] || { printf 0; return 0; }
  win="${CONTEXT_KILL_REPEAT_WINDOW_S:-86400}"; case "$win" in ''|*[!0-9]*) win=86400 ;; esac
  rows="${CONTEXT_KILL_REPEAT_SCAN_ROWS:-50000}"; case "$rows" in ''|*[!0-9]*|0) rows=50000 ;; esac
  since=$(date -u -d "@$(( $(date +%s) - win ))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || { printf 0; return 0; }
  # BOUNDED: cost.csv is never rotated, so only its last $rows rows are read.
  # THE SAME WORK is the same ticket AND the same fingerprint when the call
  # declares both: a ticket whose thread moved (a client answered) is new work.
  tail -n "$rows" "$COST" 2>/dev/null | grep -E '(context-kill|cliff-avoided):ceiling=' | awk -F, \
    -v p="$PROJECT" -v s="$STAGE" -v since="$since" -v tk="${CK_TK:-}" -v fp="${CK_FP:-}" '
    $3 == p && $4 == s && $1 >= since \
      && (tk == "" || index($24, ":tk=" tk ":")) && (fp == "" || index($24, ":fp=" fp)) { n++ }
    END { print n + 0 }'
}
ctx_kill_repeat_max() { # CONTEXT_KILL_REPEAT_MAX, 0 = off; anything not a whole number is the default
  local m="${CONTEXT_KILL_REPEAT_MAX:-2}"
  case "$m" in ''|*[!0-9]*) m=2 ;; esac
  printf '%s' "$((10#$m))"
}
ctx_kill_escalate() { # ctx_kill_escalate <kills> — ONE critical alert per piece of work
  local n="$1" la line
  line="CONTEXT KILL REPEATED: $STAGE/$PROJECT work tk=${CK_TK:--} fp=${CK_FP:--} was context-killed $n times in $(( ${CONTEXT_KILL_REPEAT_WINDOW_S:-86400} / 3600 ))h — auto-retry STOPPED for it (later calls refused rc 74, nothing bought). A person decides: split or re-scope the work, or raise the lane's context_kill_tokens in catalog/context-budgets.json. logs/cost.csv has the killed rows (note context-kill:)."
  la="$(dirname "$0")/lane-alert.sh"; [ -x "$la" ] || la="$HARNESS/bin/lane-alert.sh"
  if [ -x "$la" ] && "$la" --critical --id "context-kill-repeat:$STAGE/$PROJECT/${CK_FP:-$CK_TK}" \
       agent-call "$line" >/dev/null 2>&1; then
    return 0
  fi
  echo "$(STAMP) [agent-call] $line" >> "$ALERTS"
}
ctx_kill_after_kill() { # after a killed attempt's row is written: escalate at the Nth kill
  local max n
  max=$(ctx_kill_repeat_max); [ "$max" -gt 0 ] || return 0
  n=$(ctx_kill_repeats)
  [ "$n" -ge "$max" ] && ctx_kill_escalate "$n"
  return 0
}
ctx_kill_repeat_refuse() { # rc 0 = REFUSE this call: its work already reached the kill count
  local max n
  max=$(ctx_kill_repeat_max); [ "$max" -gt 0 ] || return 1
  n=$(ctx_kill_repeats)
  [ "$n" -ge "$max" ] || return 1
  CK_KILLS="$n"
  return 0
}
# <<< context_kill

mkdir -p "$(dirname "$COST")"
# The canonical header lives in bin/lib/cost-row.sh; the literal here is the
# fallback for a box whose sync has not landed the library yet.
COST_HDR="${COST_ROW_HDR:-ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note,lane_id,guard_fp}"
[ -f "$COST" ] || echo "$COST_HDR" > "$COST"
# THE APPEND ITSELF lives in bin/lib/cost-row.sh (cost_append): a flock, the
# one-time header upgrade for a box whose cost.csv predates billing_mode /
# auth_* / the session+tag columns, and an unlocked fall-through so a lock
# timeout can never be the reason a row is lost. tests/cost-append-test.sh
# drives it directly, extracted from that file.

# ── WHERE THE NUMBERS ON A COST ROW COME FROM (2026-09-14) ───────────────────
# The transcript, when there is one. The CLI's `--output-format json` envelope
# reports `.usage` for ONE turn and is only written when the run survives to
# print it, which is two different holes in the same column: a killed run
# shipped a row with blank tokens and blank dollars (16 of one day's 478 hub
# claude rows; 2,008 of 8,000 all-time), and a surviving run shipped one turn's
# tokens as if it were the session's.
#
# The transcript has neither problem — it is on disk from the first API response
# onward, it carries every turn, and it carries the SUBAGENT turns too (they
# land in the same file with isSidechain:true). bin/transcript-cost.sh
# de-duplicates on the API response id, which matters more than it sounds: the
# CLI writes one JSONL entry per content block and repeats the usage object on
# each, so summing lines reads ~2.2x high (measured on session 4c9ab765:
# 5,378,875 cache_read claimed where the session read 2,400,809).
#
# The envelope's reading is kept beside it in result_usd, and a >20% gap is
# logged once per occurrence — this is how the fleet learns what `.usage`
# actually means instead of assuming.
#
# Fail-soft in every direction: no transcript, no helper, switch off, or a
# non-claude runner all fall back to the envelope exactly as before. This
# function is DELIBERATELY the only place that decision is made, so the test
# can drive it without driving a model call.
#
# Reads  : R_IN R_OUT R_CR R_CW R_USD (the envelope), $PROJECT $STAGE $HARNESS
# Writes : IN OUTT CR CW USD ROW_SRC rmodel PRICE_V_SEEN   (locals of the
#          caller; bash scoping is dynamic, which is what makes the split
#          possible at all). PRICE_V_SEEN (BH-5652) is the version of the price
#          row the transcript priced rmodel from, empty when the row has none.
# >>> cost_row_source (tests/transcript-cost-test.sh runs this function)
cost_row_source() { # cost_row_source <runner> <session-id> <cwd>
  local _runner="$1" _sid="${2:-}" _cwd="${3:-$PWD}" _TCB _TCL _TCM _TCN _TCF _TCU _TCV
  if [ "$_runner" = claude ] && cost_transcript_enabled; then
    _TCB="$(dirname "$0")/transcript-cost.sh"
    [ -x "$_TCB" ] || _TCB="$HARNESS/bin/transcript-cost.sh"
    if [ -n "$_sid" ] && [ -x "$_TCB" ]; then
      _TCL=$(eval "${ACCT_EXPORTS:-}"; "$_TCB" "$_sid" --cwd "$_cwd" --price-version 2>>"$HARNESS/logs/claude-cost.log")
      if [ -n "$_TCL" ]; then
        IFS='|' read -r IN OUTT CR CW USD _TCM _TCN _TCF _TCU _TCV <<<"$_TCL"
        ROW_SRC=transcript
        [ -n "${_TCM:-}" ] && rmodel="$_TCM"
        # The dollars came from a versioned price row; the row says which.
        PRICE_V_SEEN="${_TCV:-}"
        # An UNPRICED model makes cost_usd partial, and a partial number that
        # does not say so is the failure this wave is about. One line per call.
        [ -n "${_TCU:-}" ] && echo "$(STAMP) [$PROJECT] $STAGE: UNPRICED model(s) ${_TCU} in session $_sid — cost_usd is partial" >> "$HARNESS/logs/claude-cost.log"
      fi
    fi
  fi
  if [ "$ROW_SRC" = none ] && [ -n "${R_USD:-}${R_IN:-}" ]; then
    # No transcript reading: the envelope is the row, byte-for-byte what this
    # script wrote before the transcript path existed.
    IN="$R_IN"; OUTT="$R_OUT"; CR="$R_CR"; CW="$R_CW"; USD="$R_USD"; ROW_SRC=result
  fi
  # THE COMPARE. One line per call where the two readings disagree by more than
  # COST_SOURCE_DELTA_PCT (default 20) — the record of what `.usage` covers,
  # built from real traffic rather than from a reading of the CLI docs.
  if [ "$ROW_SRC" = transcript ] && [ -n "${R_USD:-}" ] && [ -n "${USD:-}" ]; then
    awk -v a="$USD" -v b="$R_USD" -v p="${COST_SOURCE_DELTA_PCT:-20}" \
      'BEGIN{ if (b+0 <= 0) exit 1; d=(a-b)/b*100; if (d<0) d=-d; exit !(d > p+0) }' 2>/dev/null \
      && echo "$(STAMP) [$PROJECT] $STAGE $rmodel session=$_sid: transcript \$$USD vs result \$$R_USD ($(awk -v a="$USD" -v b="$R_USD" 'BEGIN{printf "%+.0f%%", (a-b)/b*100}' 2>/dev/null)) — rows use the transcript" >> "$HARNESS/logs/cost-source-delta.log"
  fi
  return 0
}
# <<< cost_row_source

# >>> steer take (BH-5839)
# THE STEP BOUNDARY. Notes a person sent "now" from the ticket page are taken
# here, once, and ride this stage's prompt; a hold note sent to this job
# refuses the stage before anything is called or billed (CC() defers on it).
# Only a CC() call takes (it sets AGENT_CALL_STEER=1): a direct caller inside a
# build does not stop on rc 74, so it must not take a hold or a note.
# A taken note is not yet read. The EXIT trap settles it with this call's rc:
# rc 0 marks it read, any refusal or failure below gives it back as pending.
# Fail-open: no lib, no JOB_ID or no worker answer leaves the prompt as it was.
# steer_take runs in THIS shell (output to a file, not a $( )), so the
# STEER_* it sets survive.
_AC_STEER="${AGENT_CALL_STEER:-0}"; unset AGENT_CALL_STEER
if [ -n "${JOB_ID:-}" ] && [ "$_AC_STEER" = 1 ]; then
  for _st in "$(dirname "$0")/lib/steer.sh" "$HARNESS/bin/lib/steer.sh"; do
    # shellcheck source=bin/lib/steer.sh
    [ -r "$_st" ] && { . "$_st"; break; }
  done
  if command -v steer_take >/dev/null 2>&1 && steer_take "$JOB_ID" > "$OUT.steer" 2>/dev/null; then
    if [ -n "${STEER_HOLD_ID:-}" ]; then
      printf 'AGENT_CALL_REFUSED steer-hold %s %s\n' "$STEER_HOLD_ID" "$STEER_HOLD_TEXT" > "$OUT" 2>/dev/null
      echo "$(STAMP) [$PROJECT] $STAGE refused: hold note #$STEER_HOLD_ID for job $JOB_ID; nothing was called and nothing was billed" >> "$HARNESS/logs/failovers.log" 2>/dev/null
      exit 74
    fi
    if [ -n "${STEER_TAKEN_IDS:-}" ]; then
      trap '_ac_steer_rc=$?; steer_settle "$JOB_ID" "$_ac_steer_rc"' EXIT
      [ -s "$OUT.steer" ] && PROMPT="$PROMPT"$'\n\n'"$(cat "$OUT.steer")"
    fi
  fi
fi
# <<< steer take

# Prompt provenance (the operator, 2026-08-14): keep the exact prompt each stage ran on,
# plus its digest, so a PR can be traced back to the words that produced it and
# two builds can be compared for prompt drift. Kept beside the stage output in
# the build dir; the digest also rides a fleet-wide log.
# Applied BEFORE provenance, so the sha and the byte count describe the prompt
# that actually shipped rather than one that was silently trimmed afterwards.
PROMPT=$(prompt_guard "$PROMPT")

PROV="$HARNESS/logs/prompt-provenance.csv"
[ -f "$PROV" ] || echo "ts,host,project,stage,runner,model,rc,prompt_sha256,prompt_bytes" > "$PROV"
PROMPT_SHA=$(printf '%s' "$PROMPT" | sha256sum | cut -d' ' -f1)
PROMPT_BYTES=$(printf '%s' "$PROMPT" | wc -c)
printf '%s' "$PROMPT" > "$OUT.prompt" 2>/dev/null
printf '%s\n' "$PROMPT_SHA" > "$OUT.promptsha" 2>/dev/null

# >>> choke_guard
# THE CHOKE POINT (BH-1037). Every agent call in the fleet comes through this
# script, and until now the only thing it did BEFORE spending money was assemble
# the prompt. THE LEDGER belongs here, because here is the last place the
# decision is still free: a persisted row keyed (project, stage, promptsha) is
# looked up before the first runner is invoked. Inside the TTL, a recorded `ok`
# or `empty` answer is REPLAYED — the body, the runner/model markers, one log
# line — and nothing is called. The merge conductor re-spawns the same
# head-bound re-review of the same unchanged head whenever a tick finds the job
# gone, and every one of those re-spawns bought the read again.
#
# THE OTHER HALF OF BH-1037 — AGENT_CALL_RUNNERS, the caller's list of lanes it
# will accept — is ALREADY IN THIS SCRIPT, landed ahead of this build by BH-1019
# (#1074): the parse and `runner_allowed` are above, the restricted-primary
# refusal is beside the promotion, and the ladder rungs are gated. This block
# does not reimplement any of it; `bin/lib/merge-conductor-lib.sh`'s re-review
# already passes `AGENT_CALL_RUNNERS=claude` from that build.
#
# PLACED HERE ON PURPOSE, exactly like the hub-no-build block above: after the
# prompt (and therefore the sha) is final, and BEFORE the runner promotion, the
# account pick, the phase row and every run_attempt. A replay opens no phase,
# picks no account, stamps no cooldown and writes no cost or provenance row,
# because none of those things happened.
#
# The sha is of the ASSEMBLED, prompt_guard-truncated text — the prompt that
# actually shipped — so an @file carrier path never perturbs the key.
# OPT-IN, PER CALLER, AND NOT BOX-WIDE (round-2 fix). The first cut defaulted
# this ON for every `review` call on the box, on the premise that "a review's
# deliverable IS its text". That premise holds for exactly one caller.
# bin/run-build.sh's review lenses (bin/lib/rb/review.sh) and
# bin/review-rescue.sh also run stage `review`, and for them BOTH halves are
# false: their prompt names a branch and a build dir but no head sha, so a
# fixed head hashes to the same key as the head that was blocked; and their
# deliverable is the FILE the agentic session writes ($BUILD/review.md), read
# back by the caller, not the transcript this script returns. A box rolled
# mid-fix-round and resumed inside the TTL would replay the pre-fix BLOCK,
# never rewrite review.md, and buy a fix round against findings the fix had
# already answered.
#
# So the caller says so. mc_rereview is the one that can: its prompt carries
# the head sha, inlines that head's diff, and its deliverable IS the text it
# reads back out of $OUT. It exports AGENT_CALL_LEDGER=1 beside
# AGENT_CALL_RUNNERS — the same one-token shape BH-1019 used. An operator who
# wants it wider sets it in the box env; nobody inherits it by accident.
AGENT_CALL_LEDGER="${AGENT_CALL_LEDGER:-0}"
AGENT_CALL_LEDGER_TTL_S="${AGENT_CALL_LEDGER_TTL_S:-1800}"
AGENT_CALL_LEDGER_STAGES="${AGENT_CALL_LEDGER_STAGES:-review}"
# Non-numeric is the default, not an error — the same reading as LADDER_*
# above. A garbage TTL makes `[ x -lt y ]` false forever, which is a cache that
# silently stops caching (or, with the comparison the other way, one that never
# expires). Neither failure says anything out loud, so neither is allowed.
case "$AGENT_CALL_LEDGER_TTL_S" in ''|*[!0-9]*) AGENT_CALL_LEDGER_TTL_S=1800 ;; esac
LEDGER_DIR="$HARNESS/state/agent-call-ledger"
LEDGER_ROW="$LEDGER_DIR/$PROJECT/$STAGE/$PROMPT_SHA.json"
LEDGER_BODY="$LEDGER_DIR/$PROJECT/$STAGE/$PROMPT_SHA.out"
LEDGER_LOG="$HARNESS/logs/agent-call-ledger.log"

# WHICH STAGES MAY BE REPLAYED, and why it is not "all of them". agent-call.sh
# runs AGENTIC sessions: replaying an `execute` would hand back the transcript
# while performing none of the edits, and replaying a `triage` would skip the
# comments and launches the first run made. A review's deliverable IS its text,
# so review is the one stage where a replay is faithful. An operator who wants
# the other reading sets AGENT_CALL_LEDGER_STAGES (`*` = every stage) — no code
# change, which is what "env-resolved" has to mean.
choke_enabled() {
  [ "$AGENT_CALL_LEDGER" = 1 ] || return 1
  lane_switch agent-call-ledger-off file && return 1
  case " $(printf '%s' "$AGENT_CALL_LEDGER_STAGES" | tr ',' ' ') " in
    *" $STAGE "*|*" * "*) return 0 ;;
  esac
  return 1
}

# choke_lookup — called once, below. Either it replays and EXITS, or it returns
# and the script proceeds byte-identically to before this block existed. Every
# gate is a reason to MISS, because a miss costs one more purchase and a wrong
# hit hands a caller an answer to a question it did not ask.
choke_lookup() {
  choke_enabled || return 1
  command -v jq >/dev/null 2>&1 || return 1
  [ -f "$LEDGER_ROW" ] || return 1
  local ts outcome rc runner model age now
  ts=$(jq -r '.ts // ""' "$LEDGER_ROW" 2>/dev/null)
  case "$ts" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s); age=$(( now - ts ))
  [ "$age" -ge 0 ] && [ "$age" -lt "$AGENT_CALL_LEDGER_TTL_S" ] || return 1
  outcome=$(jq -r '.outcome // ""' "$LEDGER_ROW" 2>/dev/null)
  # `failed` rows are recorded and never replayed: a failure is a fact about one
  # attempt, not an answer, and re-serving it would turn one bad minute into a
  # TTL-long outage for every caller that shares the prompt.
  case "$outcome" in ok|empty) : ;; *) return 1 ;; esac
  # A row whose body is gone (a crash between the two writes, or the prune
  # racing a reader) is a MISS. Fail open toward one more purchase, never
  # toward a phantom answer — and never toward reading a blank file as an `ok`.
  [ -f "$LEDGER_BODY" ] || return 1
  if [ "$outcome" = ok ]; then
    grep -q '[^[:space:]]' "$LEDGER_BODY" 2>/dev/null || return 1
  fi
  rc=$(jq -r '.rc // ""' "$LEDGER_ROW" 2>/dev/null)
  case "$rc" in ''|*[!0-9]*) rc=0 ;; esac
  runner=$(jq -r '.runner // ""' "$LEDGER_ROW" 2>/dev/null)
  model=$(jq -r '.model // ""' "$LEDGER_ROW" 2>/dev/null)
  # THE CALLER'S OWN LANE LIST APPLIES TO A REPLAY TOO (BH-1019's knob, read
  # here). A row bought while the ladder was wide open is not an answer to a
  # claude-only ask: mc_review_lane_failure rejects it on provenance, rc 2, no
  # progress — and a hit would hand back the same rejected read on every
  # re-spawn until the TTL lapsed. A miss costs one purchase; this costs the
  # whole window.
  runner_allowed "${runner:-claude}" || return 1
  cat "$LEDGER_BODY" > "$OUT" 2>/dev/null || return 1
  # The markers the replay's readers key on: bin/lib/review-provenance.sh reads
  # the (runner, model) PAIR beside the output file, and it must read the replay
  # exactly as it read the original.
  [ -n "$runner" ] && printf '%s\n' "$runner" > "$OUT.runner" 2>/dev/null
  [ -n "$model" ]  && printf '%s\n' "$model"  > "$OUT.model"  2>/dev/null
  printf '%s %s\n' "$outcome" "$LEDGER_ROW" > "$OUT.replay" 2>/dev/null
  # The sidecars describe a run that did not happen. Leaving an earlier
  # attempt's 429 envelope beside a replayed APPROVE is exactly the misread
  # mc_review_lane_failure was written for. $OUT.account is in the list for the
  # same reason (BH-1090 review): it names the claude account that PAID for an
  # attempt, this exit pays none, and run_attempt's own sweep of it is below a
  # line we never reach. $OUT.envelope joins them (BH-1494): it is grok's raw
  # result document, the file bin/grok-usage.sh prices a row from, and a
  # replayed answer was not bought by the run that wrote it. $OUT.session too
  # (BH-6090): it names the transcript of a session this exit never ran.
  rm -f "$OUT.json" "$OUT.err" "$OUT.events" "$OUT.account" "$OUT.envelope" "$OUT.session" 2>/dev/null
  mkdir -p "$(dirname "$LEDGER_LOG")" 2>/dev/null
  echo "$(STAMP) [$PROJECT] $STAGE: LEDGER HIT $outcome promptsha=$(printf '%s' "$PROMPT_SHA" | cut -c1-12) age=${age}s served-by=${runner:-?}/${model:-?} — replayed, no vendor call" >> "$LEDGER_LOG"
  exit "$rc"
}

# choke_error_envelope -> rc 0 when THIS run's claude branch returned rc 0 with
#   the CLI's own error envelope in $OUT.json. The CLI wraps a vendor error as
#   {"is_error":true,"api_error_status":429,"result":"<the vendor's words>"}
#   and can exit 0, so `.result` — the ERROR TEXT — lands in $OUT and every
#   rc-based reading downstream calls it a successful review. The consumer
#   already defends against exactly this (mc_review_lane_failure reads
#   <out>.json before it reads <out>), and the replay DELETES $OUT.json, which
#   is that defence's only evidence. Recorded `ok`, one 429 becomes a TTL-long
#   stream of "a real review with no verdict": a strike, a park, and
#   blocked-resolver closing a finished PR (project-5 #1621, with a cache in
#   front of it). So it is `failed`, and `failed` never replays.
#
#   $OUT.json belongs to the claude branch alone, so the runner marker gates
#   the read: a stale envelope must never condemn the answer a later rung gave.
choke_error_envelope() {
  local r
  r=$(head -1 "$OUT.runner" 2>/dev/null)
  [ "${r:-claude}" = claude ] || return 1
  [ -s "$OUT.json" ] || return 1
  jq -e '(.is_error == true) or (((.api_error_status // "") | tostring) != "")' \
    "$OUT.json" >/dev/null 2>&1
}

# choke_record <rc> — called on the way out, once, with the stage's real rc.
#   ok      rc 0, no error envelope, and $OUT has a non-whitespace byte
#   empty   rc 0 and $OUT is blank (a `"result":""` completion: billed, and
#           terminal inside the TTL, but never replayed as an `ok`)
#   failed  anything else: a non-zero rc including our own 2/74/75/76/78/79, and
#           an rc-0 claude error envelope (see above)
#
#   `failed` never replays, so a row written for one of the before-billing rcs
#   costs one re-purchase attempt and nothing more — which is the right way
#   round: a call nobody made must not be cached as an answer. BH-1141's whole-
#   call refusal exits BEFORE this runs; a per-rung refusal on a ladder that
#   already spent money reaches here with the BILLED attempt's rc (see the
#   llm-gate-exit block), so the ledger records what actually happened.
# BODY FIRST, ROW LAST. The row is the commit point, so a row that points at a
# body which is not there cannot happen by construction; the reverse (a body
# with no row) is just an orphan the prune collects.
choke_record() {
  local rc="${1:-0}" outcome dir
  choke_enabled || return 0
  command -v jq >/dev/null 2>&1 || return 0
  case "$rc" in ''|*[!0-9]*) rc=1 ;; esac
  if [ "$rc" -ne 0 ]; then outcome=failed
  elif choke_error_envelope; then outcome=failed
  elif grep -q '[^[:space:]]' "$OUT" 2>/dev/null; then outcome=ok
  else outcome=empty; fi
  dir=$(dirname "$LEDGER_ROW")
  mkdir -p "$dir" 2>/dev/null || return 0
  if [ "$outcome" = failed ]; then
    rm -f "$LEDGER_BODY" 2>/dev/null
  else
    cp -f "$OUT" "$LEDGER_BODY.tmp.$$" 2>/dev/null \
      && mv -f "$LEDGER_BODY.tmp.$$" "$LEDGER_BODY" 2>/dev/null \
      || { rm -f "$LEDGER_BODY.tmp.$$" 2>/dev/null; return 0; }
  fi
  jq -nc --argjson ts "$(date +%s)" --arg project "$PROJECT" --arg stage "$STAGE" \
     --arg promptsha "$PROMPT_SHA" --arg outcome "$outcome" --argjson rc "$rc" \
     --arg runner "$(head -1 "$OUT.runner" 2>/dev/null)" \
     --arg model "$(head -1 "$OUT.model" 2>/dev/null)" \
     --argjson bytes "$(stat -c %s "$OUT" 2>/dev/null || echo 0)" \
     --arg host "$(hostname)" \
     '{ts:$ts,project:$project,stage:$stage,promptsha:$promptsha,outcome:$outcome,rc:$rc,runner:$runner,model:$model,bytes:$bytes,host:$host}' \
     > "$LEDGER_ROW.tmp.$$" 2>/dev/null \
     && mv -f "$LEDGER_ROW.tmp.$$" "$LEDGER_ROW" 2>/dev/null \
     || rm -f "$LEDGER_ROW.tmp.$$" 2>/dev/null
  # ONE BOUNDED SWEEP AN HOUR, never one per call: this store grows a file per
  # distinct prompt and nothing else would ever delete one. mtime-based and
  # confined to the ledger directory; a row swept early costs one re-purchase.
  local pf="$LEDGER_DIR/.pruned" pts
  pts=$(stat -c %Y "$pf" 2>/dev/null || echo 0)
  case "$pts" in ''|*[!0-9]*) pts=0 ;; esac
  if [ $(( $(date +%s) - pts )) -ge 3600 ]; then
    touch "$pf" 2>/dev/null
    find "$LEDGER_DIR" -type f ! -name .pruned \
      -mmin "+$(( (AGENT_CALL_LEDGER_TTL_S * 2 + 59) / 60 ))" -delete 2>/dev/null || true
  fi
  return 0
}

choke_lookup || true
# <<< choke_guard

# Machine-wide rules for the non-claude lanes (the operator, 2026-08-14). Claude auto-
# loads ~/.claude/CLAUDE.md; codex/grok/openrouter/gemini load nothing, so every
# failover had been running without the iron laws. Injected here rather than as
# a file because the product repos already own their AGENTS.md — see
# sync-agent-rules.sh. Claude is skipped: it already has these, and duplicating
# them into its system prompt would just burn tokens.
rules_append() { # rules_append <runner> -> full AGENT_SYSTEM_APPEND for that runner
  local runner="$1" rules=""
  # grok CLI now auto-loads ~/.claude/CLAUDE.md into its own system-reminder
  # (verified in project-4 session chat_history 2026-08-25) — injecting the render
  # again put the same rules block in every prompt twice. Skip grok like
  # claude; GROK_RULES_INJECT=1 restores injection if a grok build drops the
  # auto-load.
  if [ "$runner" = "grok" ] && [ "${GROK_RULES_INJECT:-0}" != "1" ]; then
    printf '%s' "${AGENT_SYSTEM_APPEND:-}"; return 0
  fi
  [ "$runner" = "claude" ] && { printf '%s' "${AGENT_SYSTEM_APPEND:-}"; return 0; }
  rules=$("$HARNESS/bin/sync-agent-rules.sh" render 2>/dev/null) || rules=""
  if [ -z "$rules" ]; then
    # Never let a fallback run rule-less and silent about it.
    echo "$(STAMP) [$PROJECT] $STAGE $runner: machine rules unavailable — running WITHOUT ~/.claude/CLAUDE.md" >> "$ALERTS"
    printf '%s' "${AGENT_SYSTEM_APPEND:-}"; return 0
  fi
  if [ -n "${AGENT_SYSTEM_APPEND:-}" ]; then
    printf '%s\n\n%s' "$rules" "$AGENT_SYSTEM_APPEND"
  else
    printf '%s' "$rules"
  fi
}

# >>> codex_seen_model (tests/codex-model-capture-test.sh runs this function)
# codex_seen_model <stderr-file> <events-file> [session-jsonl]
#   The model codex ACTUALLY resolved, or nothing. Sources, in order of trust:
#   the session ledger's top-level "model" key (the CLI's own record), then a
#   `model: <id>` banner at the START of a line in the CLI's stderr/events.
#   Never a bare "model:" inside prose or code. The id must look like one:
#   a family prefix (gpt-, o1/o3/o4, codex-, chatgpt-) — the vendor's actual
#   naming, not an arbitrary word.
codex_seen_model() {
  local err="${1:-}" ev="${2:-}" sf="${3:-}" seen=""
  local rx='^(gpt-|o[0-9]|codex-|chatgpt-)[a-z0-9._-]+$'
  if [ -n "$sf" ] && [ -f "$sf" ]; then
    seen=$(grep -ohE '"model":"[^"]*"' "$sf" 2>/dev/null | head -1 | cut -d'"' -f4)
    [[ "$seen" =~ $rx ]] && { printf '%s' "$seen"; return 0; }
  fi
  seen=$(cat "$err" "$ev" 2>/dev/null | grep -m1 -oE '^model: [a-z0-9._-]+' | cut -d' ' -f2)
  [[ "$seen" =~ $rx ]] && { printf '%s' "$seen"; return 0; }
  return 1
}
# <<< codex_seen_model

# >>> codex_session_id (tests/codex-usage.bh-62-test.sh runs this function)
# codex_session_id <stderr-file>
#   The id codex printed in its own `session id: <uuid>` banner on stderr, or
#   nothing (rc 1). Only the FIRST line-start match counts: the banner precedes
#   the prompt echo, so a prompt carrying the same text cannot spoof it.
#   codex-usage.sh takes it as proof of which session file is this call's
#   (issue #62: without it a concurrent call's newer session was read).
codex_session_id() {
  local sid
  sid=$(grep -m1 -oE '^session id: [0-9A-Fa-f-]{8,}$' "${1:-}" 2>/dev/null | cut -d' ' -f3)
  [ -n "$sid" ] || return 1
  printf '%s' "$sid"
}
# <<< codex_session_id

# ac_participant_resolve — BH-5352: who this box is as a participant machine.
#   Only when HARNESS_PARTICIPANT_TOKEN_FILE is readable: GET
#   /api/participants/whoami with that token (in a 0600 header file, never on
#   argv), then the approved list for its billing_account (whoami does not carry
#   it). Sets AC_PARTICIPANT_STATE = none (no token file) | unresolved (whoami
#   failed) | ok, AC_PARTICIPANT_NAME and AC_PARTICIPANT_BILLING (empty when the
#   list read failed, was truncated or has none). Once per process. Never fails:
#   it runs after the paid call, only to label its row.
AC_PARTICIPANT_STATE=""; AC_PARTICIPANT_NAME=""; AC_PARTICIPANT_BILLING=""
ac_participant_resolve() {
  [ -n "$AC_PARTICIPANT_STATE" ] && return 0
  AC_PARTICIPANT_STATE=none
  local f="${HARNESS_PARTICIPANT_TOKEN_FILE:-}" tok hdr out id name list
  [ -n "$f" ] && [ -r "$f" ] || return 0
  AC_PARTICIPANT_STATE=unresolved
  tok=$(head -1 "$f" 2>/dev/null | tr -d ' \r\n')
  [ -n "$tok" ] && [ -n "${JOBS_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ] || return 0
  hdr=$(umask 077; mktemp "${TMPDIR:-/tmp}/ac-participant-h.XXXXXX" 2>/dev/null) || return 0
  printf 'authorization: Bearer %s\nx-participant-token: %s\n' "$HARNESS_SECRET" "$tok" > "$hdr"
  unset tok
  out=$(curl -sS -m 5 --connect-timeout 3 -w $'\n%{http_code}' -H "@$hdr" "$JOBS_URL/api/participants/whoami" 2>/dev/null) || out=""
  if [ "${out##*$'\n'}" = 200 ]; then
    id=$(printf '%s' "${out%$'\n'*}" | jq -r '.id // empty' 2>/dev/null)
    name=$(printf '%s' "${out%$'\n'*}" | jq -r '.name // empty' 2>/dev/null | tr -cd 'a-z0-9._-' | cut -c1-64)
  fi
  if [ -n "${id:-}" ] && [ -n "${name:-}" ]; then
    AC_PARTICIPANT_STATE=ok; AC_PARTICIPANT_NAME="$name"
    list=$(curl -sS -m 5 --connect-timeout 3 -w $'\n%{http_code}' -H "@$hdr" "$JOBS_URL/api/participants?status=approved" 2>/dev/null) || list=""
    [ "${list##*$'\n'}" = 200 ] && AC_PARTICIPANT_BILLING=$(printf '%s' "${list%$'\n'*}" | jq -r --arg id "$id" \
      'if .truncated == true then empty else ((.participants // [])[] | select(.id == $id) | .billing_account // empty) end' 2>/dev/null | head -1)
    AC_PARTICIPANT_BILLING=$(cost_csv_field "${AC_PARTICIPANT_BILLING:-}" | cut -c1-128)
  fi
  rm -f "$hdr"
  return 0
}

# >>> unbilled row (BH-6175)
# _ac_unbilled — 0 when the attempt in scope (RC, STAGE, ROW_SRC, IN/OUTT/CR/CW,
# USD) failed and bought nothing, so its row is a priced $0 `unbilled` row
# instead of a blank one. A timeout or kill rc (124/137/143) with no readable
# usage may still have been billed, so it stays unknown, except on a canary.
# A budget stop (BUDGET_STOP) spent up to its bound, so it is never $0 even
# when the envelope carries no figure (BH-4609 wants `cost $?` there). A grok
# call's only bill is its session ledger, so a grok call with no ledger is
# unknown, not free (BH-3984 R5).
_ac_unbilled() {
  [ "${RC:-0}" != 0 ] || return 1
  [ -z "${BUDGET_STOP:-}" ] || return 1
  [ "${IN:-0}${OUTT:-0}${CR:-0}${CW:-0}" = 0000 ] || return 1
  case "${USD:-0}" in *[!0.]*|*.*.*|.) return 1 ;; esac
  case "${ROW_SRC:-}" in none|transcript|result) ;; *) return 1 ;; esac
  [ "${STAGE:-}" = canary ] && return 0
  [ "${runner:-}" != grok ] || return 1
  case "$RC" in 124|137|143) return 1 ;; esac
  return 0
}
# <<< unbilled row

# ac_cost_row_write <runner> — price, assemble and emit ONE cost row for the
# attempt whose numbers are in scope (RC, T0/T1, IN/OUTT/CR/CW, USD, SESSION_ID,
# ROW_SRC, rmodel). run_attempt calls it once per attempt; the OpenRouter lane
# also calls it once per model it tried before the last, so every call it made
# has a row (2026-09-23: the floor's refusals had none).
ac_cost_row_write() {
  local runner="$1"
  BMODE=$(eval "$ACCT_EXPORTS"; "$HARNESS/bin/billing-mode.sh" "$runner" 2>/dev/null || echo unknown)
  # WHICH account paid, resolved here for the same reason billing mode is:
  # only the box that made the call, at the moment it made it, can say — the
  # env this reads is the env the attempt just ran with, and accounts get
  # switched. Fail-soft to none/unknown; never the raw secret.
  AUTH_FP=$(eval "$ACCT_EXPORTS"; auth_fp_for_runner "$runner" 2>/dev/null) || AUTH_FP=none
  [ -n "$AUTH_FP" ] || AUTH_FP=none
  AUTH_ACCT=$(auth_account_for_fp "$AUTH_FP" 2>/dev/null) || AUTH_ACCT=unknown
  [ -n "$AUTH_ACCT" ] || AUTH_ACCT=unknown
  # A routed account with no fingerprint label rides the free-text column as
  # the account's canonical label (BH-3986: the picker's label=, else the
  # registry's ACCOUNT_LABEL, else acct:<name>) — only as a FALLBACK: a live
  # fingerprint label stays authoritative (2026-08-31). A pinned own account
  # (BH-1657) rides the column as its label verbatim. bin/lib/cost-row.sh
  # cost_row_auth_account is the one rule; claude-cost.sh calls it too.
  cost_row_auth_account "$AUTH_ACCT" "${ACCT_NAME:-}" "${ACCT_PICK_LABEL:-}" "${ACCT_PINNED:-0}"
  AUTH_ACCT="$COST_ROW_AUTH_ACCOUNT"
  # BH-5352: a participant machine's row names the machine, and the account is
  # the enrollment's billing_account. The note says when either could not be read.
  local _PRN=""
  ac_participant_resolve || true
  unset COST_ROW_PARTICIPANT
  case "$AC_PARTICIPANT_STATE" in
    ok)
      export COST_ROW_PARTICIPANT="$AC_PARTICIPANT_NAME"
      _PRN="participant=$AC_PARTICIPANT_NAME"
      if [ -n "$AC_PARTICIPANT_BILLING" ]; then AUTH_ACCT="$AC_PARTICIPANT_BILLING"
      else _PRN="$_PRN;participant_billing=unresolved"; fi ;;
    unresolved) _PRN="participant=unresolved" ;;
  esac
  # run_id defaults to the BUILD DIR this stage's output lands in — the unit the
  # nightly rollup already joins to a RESULT and a PR, so cost-per-PR stops
  # needing a time window to guess with. COST_RUN_ID overrides.
  _RUNID="${COST_RUN_ID:-}"
  [ -n "$_RUNID" ] || case "$OUT" in */builds/*/*) _RUNID=$(basename "$(dirname "$OUT")") ;; esac
  # PRICE THE ROW BEFORE IT IS ASSEMBLED (BH-1020), for every runner. Until now
  # only the grok branch priced its own tokens, so the codex, openrouter and
  # fireworks lanes wrote rows with real token counts and an empty cost_usd —
  # money the DB mirror, run-build's COST_LINE, builder-direct and
  # cost-reconcile all read as $0.00. This is the one line every one of those
  # rows passes through. A vendor figure already in $USD is never overwritten;
  # a billed row that cannot be priced says so in the note instead of shipping a
  # silent blank. See bin/lib/cost-row.sh for the rules.
  local _PN _ROW_NOTE _RN="${CLIFF_ROUTE_NOTE:-}" _RF=""
  # A caller-named tag for this row (BH-3478: `delta` on a split child's warm
  # pre-plan). Cut to the note's own charset and 64 chars; unset changes nothing.
  local _AN; _AN=$(printf '%s' "${AGENT_CALL_ROW_NOTE:-}" | tr -cd 'a-z0-9=:._-' | cut -c1-64)
  [ -n "$_AN" ] && _RN="${_RN:+$_RN;}$_AN"
  # The routed account's raw name, when the column carries a label it resolved
  # to rather than one the fingerprint proved (BH-3986).
  case "$COST_ROW_ACCT_FROM" in label|registry|name) _RN="${_RN:+$_RN;}acct=$ACCT_NAME" ;; esac
  # A REFUSED CALL COSTS ZERO, AND SAYS SO (2026-09-23 pool loop). OpenRouter
  # answering "Key limit exceeded" bills nothing, and a row with a blank
  # cost_usd reads as "unpriced" — the same shape as a real call nobody could
  # price. When the vendor named a refusal and reported no usage, the row is a
  # priced $0 with the reason in the note. Anything else stays as it was.
  if [ "$runner" = openrouter ] && [ "$RC" -ne 0 ] && [ -z "${USD:-}" ] \
     && [ "${IN:-0}${OUTT:-0}${CR:-0}${CW:-0}" = 0000 ]; then
    _RF=$(ac_refusal_note "$OUT.err")
    [ -n "$_RF" ] && { USD=0; _RN="${_RN:+$_RN;}$_RF"; }
  fi
  # The observed cache TTL (P1) is a fact about this row, like a cliff route:
  # it joins the note, and the pricer charges writes at that TTL's rate.
  [ -n "${CACHE_TTL_SEEN:-}" ] && _RN="${_RN:+$_RN;}cache_ttl=$CACHE_TTL_SEEN"
  [ -n "$_PRN" ] && _RN="${_RN:+$_RN;}$_PRN"
  # A SESSION WE KILLED SAYS SO ON ITS OWN ROW (BH-2309). Until now a context
  # kill's row was rc 143 with a pricing-only note — the same shape as a
  # timeout. The token is read from $OUT.ctxkill alone, never inferred from the
  # rc, so an external TERM is not labelled a kill; only the claude branch
  # writes that marker, and run_attempt clears it at the start of every claude
  # attempt. Same two labels as ctx_kill_alert: which bound fired.
  if [ "$runner" = claude ] && [ -f "$OUT.ctxkill" ]; then
    local _ck="" _kv _kc="" _kt="" _tag=context-kill
    read -r _ck < "$OUT.ctxkill" || true
    for _kv in $_ck; do case "$_kv" in ceiling=*) _kc="${_kv#*=}" ;; total=*) _kt="${_kv#*=}" ;; esac; done
    [ -f "$OUT.cliffcap" ] && _tag=cliff-avoided
    # tk= / fp= name the WORK (BH-2538): ctx_kill_repeats counts on them.
    _RN="${_RN:+$_RN;}$_tag:ceiling=${_kc:-?}:total=${_kt:-?}:tk=${CK_TK:-}:fp=${CK_FP:-}"
    # The meter only fires after billed responses, so this call STARTED
    # (BH-3990): the row keeps whatever usage was read above (blank when none
    # could be) and says killed, never refused-style zeros.
    ROW_SRC=killed
  fi
  # Same for a session the build tripwire stopped (BH-3481): the first word of
  # $OUT.tripwire is the rule that fired. Only the claude branch reads that
  # marker, and run_attempt clears it at the start of every claude attempt.
  if [ "$runner" = claude ] && [ -f "$OUT.tripwire" ]; then
    local _tw=""
    read -r _tw _ < "$OUT.tripwire" || true
    _RN="${_RN:+$_RN;}tripwire:${_tw:-?}"
  fi
  # A CANARY THAT FAILED AND BOUGHT NOTHING SAYS SO (BH-3222). A dead login's
  # refresh attempt exits non-zero with no usage at all; as row_source=none it
  # read as an unpriced call on the Costs page. `unbilled` is the rollup's cue.
  # EVERY STAGE, NOT ONLY CANARY (BH-6175). project-2 wrote 81 such rows on
  # 2026-10-01..10-08 (triage calls with rc 1 and 0 tokens: `<synthetic>`
  # transcripts, codex `none` rows, one rc 127). A blank cost_usd is NULL in
  # D1, and the D1 readers count NULL as unpriced whatever the rollup says, so
  # the row now carries cost_usd 0. _ac_unbilled holds the rule.
  if _ac_unbilled; then
    ROW_SRC=unbilled
    [ -n "${USD:-}" ] || USD=0
  fi
  _PN=$(cost_row_price "$runner" "$rmodel" "$RC" "$IN" "$OUTT" "$CR" "$CW" "$USD" "$_RN" "${CACHE_TTL_SEEN:-}" "${PRICE_V_SEEN:-}")
  USD="${_PN%%|*}"; _ROW_NOTE="${_PN#*|}"
  # The model column is what SERVED (a fallback rung, a grok/codex lane); the
  # model the caller asked for rides the note (BH-3986). Last, after the
  # pricer's own token, so the note's 200-char cut can only ever lose this one.
  local _RQ; _RQ=$(cost_row_model_note "$rmodel" "$MODEL")
  [ -n "$_RQ" ] && _ROW_NOTE="${_ROW_NOTE:+$_ROW_NOTE;}$_RQ"
  ROW="$(date -u '+%Y-%m-%dT%H:%M:%SZ'),$(hostname),$PROJECT,$STAGE,$runner,$rmodel,$RC,$((T1-T0)),$IN,$OUTT,$CR,$CW,$USD,$BMODE,$AUTH_FP,$AUTH_ACCT,$(cost_csv_field "$SESSION_ID"),$ROW_SRC,$R_USD,$(COST_RUN_ID="$_RUNID" AGENT_CALL_TICKET="${ROW_TICKET:-}" AGENT_CALL_PR="${ROW_PR:-}" cost_row_tags),$(cost_csv_field "$_ROW_NOTE"),$(cost_row_lane),$(COST_GUARD_FP="${ROW_FP:-}" cost_row_guard_fp)"
  # FAIL LOUD, NOT SOFT (BH-406). A call that returned SUCCESS and reported no
  # usage at all is real money the ledger cannot see, and until now the only
  # thing that noticed was the hub's rollup — hourly, one line a day, after 217
  # rows had already gone out blank. The box that made the call knows now.
  # Every runner, not only grok: a blank claude or codex row is the same hole.
  # Deduped per runner/model/stage per UTC day inside the function; a failed
  # call (rc != 0) was never billed and never pages.
  cost_parity_alert "$runner" "$rmodel" "$STAGE" "$RC" "$IN" "$OUTT" || true
  cost_row_emit "$ROW"
  # Per-build attribution (2026-08-15, cost-per-PR): when this call's output
  # lands in a build dir, tee the same row there — the reap already fetches
  # cost.csv, so pool builds carry their own bill home and the nightly rollup
  # joins build -> RESULT -> PR without any time-window guessing.
  case "$OUT" in
    */builds/*/*)
      BCOST="$(dirname "$OUT")/cost.csv"
      [ -f "$BCOST" ] || head -1 "$COST" > "$BCOST" 2>/dev/null
      echo "$ROW" >> "$BCOST" ;;
  esac
  # After the row is in the ledger and, for a build call, in its cost.csv
  # (BH-3481.0). A stub today; see bin/lib/cost-live.sh.
  cost_live_boundary_push
}

# >>> openrouter kill row (BH-3983)
# A TERM/HUP/INT while codex is talking to OpenRouter used to kill this script
# before ac_cost_row_write ran, so the tokens OpenRouter billed had no row
# (an outer timeout, lane-reaper.sh, a Fly stop, a tripwire's parent kill).
# Armed only around that one call: everywhere else the default disposition
# stands. SIGKILL cannot be trapped; that gap stays. The handler runs in
# run_attempt's dynamic scope, so the T0/IN/OUTT/CR/CW/USD/rmodel it reads and
# writes are that attempt's locals, the same set the per-model write uses.
_AC_OR_INFLIGHT=0; _AC_OR_PID=""
_ac_or_arm()    { _AC_OR_INFLIGHT=1; trap '_ac_or_killed TERM' TERM; trap '_ac_or_killed HUP' HUP; trap '_ac_or_killed INT' INT; }
_ac_or_disarm() { _AC_OR_INFLIGHT=0; _AC_OR_PID=""; trap - TERM HUP INT; }
_ac_or_killed() { # _ac_or_killed <TERM|HUP|INT>
  local sig="$1" n=15 lsig
  case "$sig" in HUP) n=1 ;; INT) n=2 ;; esac
  trap - TERM HUP INT                      # a second signal takes the default path
  [ "${_AC_OR_INFLIGHT:-0}" = 1 ] || exit $((128+n))
  _AC_OR_INFLIGHT=0
  # The codex child: stop it and reap it so its session ledger is final.
  [ -n "${_AC_OR_PID:-}" ] && { kill -TERM "$_AC_OR_PID" 2>/dev/null; wait "$_AC_OR_PID" 2>/dev/null; }
  RC=$((128+n)); T1=$(date +%s)
  lsig=$(printf '%s' "$sig" | tr 'A-Z' 'a-z')
  CU_LINE=$("$HARNESS/bin/codex-usage.sh" "${T0:-}" "" "$(codex_session_id "${OUT:-}.err")" || true)
  IFS='|' read -r IN OUTT CR CW <<<"${CU_LINE// /|}"
  # ac_cost_row_write cuts the caller note to [a-z0-9=:._-], so '.' is the join.
  AGENT_CALL_ROW_NOTE="${AGENT_CALL_ROW_NOTE:+$AGENT_CALL_ROW_NOTE.}killed:sig=$lsig"
  ac_cost_row_write openrouter
  # exit fires _phase_finish (EXIT trap), which closes the job phase with this row in it.
  [ -n "${USD:-}" ] && PHASE_USD=$(awk -v a="${PHASE_USD:-0}" -v b="$USD" 'BEGIN{printf "%.6f", a+b}' 2>/dev/null)
  exit $((128+n))
}
# <<< openrouter kill row

# ADVISOR SPEND ONCE ON THE ENVELOPE PATH (BH-3602). With no transcript the
# executor row is the envelope's total_cost_usd, and if that total already
# holds the advisor's iterations the advisor row would bill them a second time.
# The envelope says which: modelUsage is session-wide, sums to total_cost_usd,
# and keys each model, so an advisor-family key present means the total
# includes it, and that key's costUSD is exactly the share to move.
#
# _ADV_ENV_SAME_FAMILY is the one case modelUsage cannot decide: a Fable main
# with a fable advisor merges both under one key. The probe that should have
# settled it (build BH-3602, advisor-envelope-probe.txt, CLI 2.1.284, 2026-09-30)
# launched with --advisor fable and the CLI never consulted the advisor: total
# $0.111731 = the opus modelUsage key = the executor transcript, advisor $0.
# So it is `unverified`, not guessed. A fact about the CLI's accounting, not a
# tunable: change it only with a probe that shows advisor iterations.
_ADV_ENV_SAME_FAMILY=unverified
_adv_fam() { case "${1:-}" in *fable*) echo fable ;; *opus*) echo opus ;; *sonnet*) echo sonnet ;; *haiku*) echo haiku ;; esac; }
# ac_advisor_envelope_split — runs before the executor row is written, and only
# changes anything on an attempt that ran with --advisor AND priced its executor
# row from the envelope (ROW_SRC=result). Writes the caller's USD/ROW_SRC
# (dynamic scope, as cost_row_source does) and ADV_ENV_MODE/ADV_ENV_LINE for
# ac_advisor_row_write:
#   result-net-advisor     executor = total - advisor key's costUSD; the advisor
#                          row carries that key (split, row source
#                          result-modelusage), even if its transcript read would
#                          work, so the two rows come from one source
#   result-incl-advisor    same family and the total includes it: no advisor row
#   result-adv-unverified  the envelope cannot be split (no modelUsage, it does
#                          not add up to the total, two advisor-family keys, or
#                          the same-family case unproven); executor keeps the
#                          total, advisor row as before, one delta-log line when
#                          unreadable
# An advisor-family key that is absent means the total excludes the advisor:
# nothing changes and both rows stay `result`.
ac_advisor_envelope_split() {
  ADV_ENV_MODE=""; ADV_ENV_LINE=""
  [ -n "${ADV_ATTEMPT:-}" ] && [ "${ROW_SRC:-}" = result ] && [ -r "$OUT.json" ] || return 0
  awk -v t="${R_USD:-}" 'BEGIN{exit !(t ~ /^[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$/)}' || return 0
  local _ef _af _im _mu _s _rest _why=""
  _ef=$(_adv_fam "${rmodel:-}"); _af=$(_adv_fam "$ADV_ATTEMPT")
  _im=$(jq -r '[.usage.iterations[]? | select(.type == "advisor_message") | .model // empty][0] // ""' "$OUT.json" 2>/dev/null)
  [ -n "$_im" ] && [ -n "$(_adv_fam "$_im")" ] && _af=$(_adv_fam "$_im")
  # "<sum of costUSD>|none" | "<sum>|many" | "<sum>|in|out|cr|cw|costUSD|key"
  _mu=$(jq -r --arg af "$_af" --arg im "$_im" '
    if (.modelUsage | type) != "object" or (.modelUsage | length) == 0 then "nomu" else
      ([.modelUsage[] | .costUSD // 0] | add) as $s
      | [.modelUsage | to_entries[] | select($af != "" and (.key | contains($af)))] as $k
      | ($k | map(select(.key == $im))) as $x
      | (if ($x | length) == 1 then $x else $k end) as $k
      | ($s | tostring) + "|" + (if ($k | length) == 0 then "none" elif ($k | length) > 1 then "many"
          else ($k[0] | [.value.inputTokens // 0, .value.outputTokens // 0, .value.cacheReadInputTokens // 0,
                         .value.cacheCreationInputTokens // 0, .value.costUSD // 0, .key] | map(tostring) | join("|")) end)
    end' "$OUT.json" 2>/dev/null)
  if [ -z "$_mu" ] || [ "$_mu" = nomu ]; then
    _why="no modelUsage in the envelope"
  else
    _s="${_mu%%|*}"; _rest="${_mu#*|}"
    # A parse sanity bound, not a business threshold: the keys must add up to
    # the total (0.5%, or 1e-6 for a near-zero call) before either is trusted.
    if awk -v s="$_s" -v t="$R_USD" 'BEGIN{d=s-t; if(d<0)d=-d; b=t*0.005; if(b<1e-6)b=1e-6; exit !(d > b)}'; then
      _why="total \$$R_USD vs modelUsage \$$_s"
    elif [ "$_rest" = many ]; then
      _why="more than one $_af key in modelUsage"
    elif [ -z "$_af" ]; then
      _why="advisor $ADV_ATTEMPT is no known family"
    fi
  fi
  if [ -n "$_why" ]; then
    ROW_SRC=result-adv-unverified
    echo "$(STAMP) [$PROJECT] $STAGE session=${SESSION_ID:-}: advisor split unreadable ($_why) — executor row keeps the envelope total" >> "$HARNESS/logs/cost-source-delta.log"
    return 0
  fi
  if [ "$_ef" = "$_af" ]; then
    case "$_ADV_ENV_SAME_FAMILY" in
      includes) ROW_SRC=result-incl-advisor; ADV_ENV_MODE=skip ;;
      excludes) ;;
      *) ROW_SRC=result-adv-unverified ;;
    esac
    return 0
  fi
  [ "$_rest" = none ] && return 0
  ADV_ENV_LINE="$_rest"; ADV_ENV_MODE=split; ROW_SRC=result-net-advisor
  USD=$(awk -v t="$R_USD" -v a="$(cut -d'|' -f5 <<<"$_rest")" 'BEGIN{d=t-a; if(d<0)d=0; printf "%.6f", d}')
  return 0
}

# ac_advisor_row_write — THE ADVISOR'S OWN ROW (BH-3491). The advisor's tokens
# are reported in usage.iterations[] (type advisor_message, its own model) and
# never in the top-level usage the executor row is priced from, so without this
# row advisor spend is invisible to the ledger and the caps. One row per attempt
# that ran with --advisor, stage `<stage>-advisor`, same session id, priced at
# the advisor's model. The transcript first (every turn); the envelope when there
# is no transcript (one turn only). No advisor iterations = no row: the advisor
# was never consulted, and a $0 row would read as an unpriced call. Sets ADV_USD.
ac_advisor_row_write() {
  ADV_USD=""
  [ -n "${ADV_ATTEMPT:-}" ] || return 0
  # BH-3602: the executor row already holds the advisor's dollars (skip), or
  # it was netted of them and this row carries exactly that share (split).
  [ "${ADV_ENV_MODE:-}" = skip ] && return 0
  local _TCB _TCL _trc=3 _TCM _TCN _TCF _TCU
  local STAGE="$STAGE-advisor" rmodel="" IN="" OUTT="" CR="" CW="" USD="" ROW_SRC=none R_USD="" CACHE_TTL_SEEN="" PRICE_V_SEEN="" CLIFF_ROUTE_NOTE="advisor"
  if [ "${ADV_ENV_MODE:-}" = split ]; then
    IFS='|' read -r IN OUTT CR CW USD rmodel <<<"$ADV_ENV_LINE"
    R_USD="$USD"; ROW_SRC=result-modelusage
    ac_cost_row_write claude
    ADV_USD="$USD"
    return 0
  fi
  _TCB="$(dirname "$0")/transcript-cost.sh"; [ -x "$_TCB" ] || _TCB="$HARNESS/bin/transcript-cost.sh"
  if [ -n "${SESSION_ID:-}" ] && [ -x "$_TCB" ] && cost_transcript_enabled; then
    _TCL=$(eval "${ACCT_EXPORTS:-}"; "$_TCB" "$SESSION_ID" --advisor --cwd "$PWD" --price-version 2>>"$HARNESS/logs/claude-cost.log"); _trc=$?
  fi
  if [ "$_trc" = 0 ] && [ -n "$_TCL" ]; then
    IFS='|' read -r IN OUTT CR CW USD _TCM _TCN _TCF _TCU PRICE_V_SEEN <<<"$_TCL"
    rmodel="$_TCM"; ROW_SRC=transcript
    [ -n "${_TCU:-}" ] && echo "$(STAMP) [$PROJECT] $STAGE: UNPRICED model(s) ${_TCU} in session $SESSION_ID — cost_usd is partial" >> "$HARNESS/logs/claude-cost.log"
  elif [ "$_trc" = 4 ]; then
    return 0
  else
    _TCL=$(jq -r '[.usage.iterations[]? | select(.type == "advisor_message")] as $a
      | if ($a | length) == 0 then empty else
        [($a | map(.input_tokens // 0) | add), ($a | map(.output_tokens // 0) | add),
         ($a | map(.cache_read_input_tokens // 0) | add), ($a | map(.cache_creation_input_tokens // 0) | add),
         ($a | max_by(.output_tokens // 0) | .model // "unknown")] | map(tostring) | join("|") end' "$OUT.json" 2>/dev/null)
    [ -n "$_TCL" ] || return 0
    IFS='|' read -r IN OUTT CR CW rmodel <<<"$_TCL"
    ROW_SRC=result
  fi
  ac_cost_row_write claude
  ADV_USD="$USD"
}

# ac_refusal_note <err-file> — `refused:<why>` when the vendor's own text names
# a refusal (nothing was served, nothing billed), else nothing.
ac_refusal_note() {
  local f="${1:-}" st
  [ -r "$f" ] || return 0
  if grep -qiE 'key limit exceeded' "$f" 2>/dev/null; then printf 'refused:key_limit'; return 0; fi
  if grep -qiE "$LADDER_CREDITS_REGEX" "$f" 2>/dev/null; then printf 'refused:credits'; return 0; fi
  st=$(ladder_http_status "$f")
  case "$st" in
    401|403) printf 'refused:auth' ;;
    402)     printf 'refused:credits' ;;
    429)     printf 'refused:rate_limited' ;;
  esac
  return 0
}

run_attempt() { # run_attempt <runner> ; sets RC, writes $OUT, appends cost row
  local runner="$1" T0 T1 IN="" OUTT="" CR="" CW="" USD="" rmodel="$MODEL"
  # Row provenance (2026-09-14). SESSION_ID is minted BEFORE the call so the
  # transcript path is known even when the run dies; ROW_SRC says where the
  # numbers on the row came from; R_* keep the CLI envelope's own reading so
  # the two stay comparable instead of one silently replacing the other.
  local SESSION_ID="" ROW_SRC=none R_IN="" R_OUT="" R_CR="" R_CW="" R_USD="" CACHE_TTL_SEEN="" PRICE_V_SEEN=""
  T0=$(date +%s); RC=1; ADV_ATTEMPT=""; ADV_USD=""; ADV_ENV_MODE=""; ADV_ENV_LINE=""
  # THE ACCOUNT SIDECAR IS THIS ATTEMPT'S, NEVER THE LAST ONE'S (BH-1090
  # review). $OUT is keyed on (PR, head) by the merge conductor, so a re-spawn
  # lands on the same path; the claude arm below writes $OUT.account only when
  # an account was actually chosen, and every early return (no headroom,
  # runners-restricted, a non-claude lane) would otherwise leave the previous
  # attempt's account on disk for the caller's lane-down marker to believe.
  # $OUT.session (BH-6090) the same way: a codex answer is never read with an
  # earlier claude attempt's transcript.
  rm -f "$OUT.account" "$OUT.session" 2>/dev/null
  # Attempts are numbered PER STAGE, not per phase row: the survival ladder can
  # call this function five times (same lane retry, Grok, configured fallback,
  # OpenRouter, Fireworks) inside one phase, each overwriting $OUT and $OUT.json. The
  # transcript of attempt 1 is exactly the evidence for why attempts 2-5 had to
  # happen, so the number is what keeps them from collapsing into one row.
  ATTEMPT_N=$(( ${ATTEMPT_N:-0} + 1 ))
  # One beat at the stage boundary (phase 3), not a loop: the parent that owns
  # the row (run-build.sh, run-triage.sh, orc-job.sh) beats on a timer, and this
  # is the cheap belt-and-braces for the case where the parent's beater died
  # with the same signal that killed the stage. Two API calls per STAGE, never
  # one per token.
  [ -n "${JOB_ID:-}" ] && command -v job_heartbeat >/dev/null 2>&1 \
    && job_heartbeat "$JOB_ID" "$STAGE/$runner" >/dev/null 2>&1 || true
  # The no-tools contract, enforced before a single token is spent. Refusing is
  # the whole point: a lane that cannot mechanically guarantee "no tools" must
  # not run this call at all. Loud (ALERTS + rc 78), never silent.
  if [ "$NO_TOOLS" = 1 ] && [ "$runner" != "claude" ]; then
    mkdir -p "$(dirname "$ALERTS")" 2>/dev/null
    echo "$(STAMP) [$PROJECT] $STAGE REFUSED on runner '$runner': AGENT_CALL_NO_TOOLS=1 and only the claude lane has a verified tool-disable flag. Nothing was called and nothing was billed." >> "$ALERTS"
    printf 'AGENT_CALL_REFUSED no-tools contract cannot be enforced on runner %s\n' "$runner" > "$OUT" 2>/dev/null
    RC=78
    return 78
  fi
  # The allowlist, the same way (BH-4065): a bad list, or any runner but claude.
  if [ -n "$TOOLS_BAD" ] || { [ -n "$TOOLS_ALLOW" ] && [ "$runner" != "claude" ]; }; then
    if [ -n "$TOOLS_BAD" ]; then
      HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$PROJECT] $STAGE REFUSED: AGENT_CALL_TOOLS is not a comma-separated list of tool names, and a session never falls back to the full tool set. Nothing was called and nothing was billed."
    else
      HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$PROJECT] $STAGE REFUSED on runner '$runner': AGENT_CALL_TOOLS=$TOOLS_ALLOW and only the claude lane has a verified tool allowlist flag. Nothing was called and nothing was billed."
    fi
    printf 'AGENT_CALL_REFUSED tool allowlist cannot be enforced on runner %s\n' "$runner" > "$OUT" 2>/dev/null
    RC=78
    return 78
  fi
  # >>> llm-gate-runner
  # THE PER-RUNG GATE (BH-1141 phase 2), in the ONE place every rung of the
  # ladder passes through. `runner_allowed` is per LANE, where the caller-side
  # AGENT_CALL_RUNNERS (BH-1019) is per CALL SITE: a lane operator sets it once
  # in a settings row and every call the lane makes obeys it, including the
  # descents the call site cannot see coming. On 2026-09-20 alert-triage
  # descended grok-cliff -> codex -> Fable-over-OpenRouter and spent $793 in
  # twelve hours; every one of those rungs would have been refused here.
  #
  # A REFUSED RUNG IS NOT A FAILED ONE. The zero-cost row goes into the ledger
  # so the descent that did NOT happen is a fact rather than an absence, and
  # GATE_REFUSED tells ladder_classify to descend without a same-vendor retry —
  # retrying a rung the lane is not allowed to reach is pure waste.
  #
  # THE MARKER IS WRITTEN ONLY WHEN NOTHING HAS RUN YET (round 2, B1). $OUT and
  # $OUT.err belong to the attempt that was BILLED: on a mixed ladder the
  # primary ran, failed and left the vendor's error text there, and teeing a
  # refusal over it destroys the only evidence of why the call died — the caller
  # then reads "fireworks was refused" for a claude death it paid for. When no
  # rung has run, the files hold nothing this call produced and the marker is
  # exactly what a caller reading them on a nonzero rc must find.
  GATE_REFUSED=""
  if ! llm_gate_runner_ok "$STAGE" "$PROJECT" "$runner"; then
    if [ -z "${ANY_RAN:-}" ]; then
      printf 'AGENT_CALL_REFUSED llm-gate %s\n' "${LLM_GATE_REASON:-runner-not-allowed}" | tee "$OUT.err" > "$OUT" 2>/dev/null
    fi
    echo "$(STAMP) [$PROJECT] $STAGE GATE REFUSED rung '$runner': ${LLM_GATE_REASON:-runner-not-allowed} — nothing was called and nothing was billed on this rung${ANY_RAN:+ (an earlier rung DID run and was billed; its rc and its output stand)}" >> "$HARNESS/logs/failovers.log"
    AGENT_CALL_TICKET="${ROW_TICKET:-}" AGENT_CALL_PR="${ROW_PR:-}" CG_FP="${ROW_FP:-}" \
      llm_gate_refused_row "$STAGE" "$PROJECT" "$runner" "$rmodel" 74 "${LLM_GATE_REASON:-runner-not-allowed}"
    GATE_REFUSED=1
    RC=74
    return 74
  fi
  # <<< llm-gate-runner
  # >>> call-guard-rung (K3)
  # THE METERED HALF OF FAIL-CLOSED, per rung. When the call-guard counter could
  # not be read, a subscription primary still runs (liveness), but a metered
  # rung below it must not: a failed flat-rate call descending into unguarded
  # cash is the exact loop the guard exists to stop. Same shape as the gate
  # above — refused, not failed; marker only when nothing has run yet.
  if ! call_guard_rung_ok "$runner"; then
    if [ -z "${ANY_RAN:-}" ]; then
      printf 'AGENT_CALL_REFUSED call-guard counter-unreadable metered %s\n' "$runner" | tee "$OUT.err" > "$OUT" 2>/dev/null
    fi
    echo "$(STAMP) [$PROJECT] $STAGE CALL-GUARD REFUSED rung '$runner': the call-guard counter is unreadable and this rung is metered (fail-closed) — nothing was called and nothing was billed on this rung${ANY_RAN:+ (an earlier rung DID run and was billed; its rc and its output stand)}" >> "$HARNESS/logs/failovers.log"
    AGENT_CALL_TICKET="${ROW_TICKET:-}" AGENT_CALL_PR="${ROW_PR:-}" CG_FP="${ROW_FP:-}" \
      llm_gate_refused_row "$STAGE" "$PROJECT" "$runner" "$rmodel" 74 "call-guard:counter-unreadable"
    GATE_REFUSED=1
    RC=74
    return 74
  fi
  # <<< call-guard-rung
  # >>> rung-model (BH-1510.1)
  # THE MODEL A NON-CLAUDE RUNG RUNS COMES FROM ITS ROUTE, and a rung with no
  # route is not run. Asked here — after the gate, before an account is picked
  # or a fence is built — so a rung that cannot run costs nothing to refuse. The
  # marker follows the gate's rule: written only when nothing has run yet, so a
  # billed primary's error text is never overwritten by a refusal below it.
  local RUNG_MODEL="" RUNG_ROLE=""
  case "$runner" in
    codex)     RUNG_ROLE=codex.default;     RUNG_MODEL=$(codex_model) ;;
    grok)      RUNG_ROLE=grok.default;      RUNG_MODEL=$(grok_model) ;;
    fireworks) RUNG_ROLE=fireworks.default; RUNG_MODEL=$(fireworks_model) ;;
  esac
  if [ -n "$RUNG_ROLE" ] && [ -z "$RUNG_MODEL" ]; then
    [ -z "${ANY_RAN:-}" ] && printf 'AGENT_CALL_NO_MODEL_ROUTE %s\n' "$RUNG_ROLE" | tee "$OUT.err" > "$OUT" 2>/dev/null
    echo "$(STAMP) [$PROJECT] $STAGE NO MODEL ROUTE for rung '$runner' (role $RUNG_ROLE, no env override) — nothing was called and nothing was billed on this rung; descending" >> "$HARNESS/logs/failovers.log"
    RC=75
    return 75
  fi
  # <<< rung-model
  # ACCOUNT ROUTING (2026-09-06, docs/ACCOUNT-ROUTING.md). OFF unless
  # ACCOUNT_ROUTING=1: ACCT_EXPORTS stays "" and every `eval "$ACCT_EXPORTS"`
  # below is a no-op, so the CLI runs with exactly the env it runs with today.
  # The pick's exports are applied inside SUBSHELLS only — the child, and the
  # two command substitutions that resolve billing mode and the auth
  # fingerprint, because those read the LIVE env and would otherwise attribute
  # a routed call to the default account.
  ACCT_NAME=""; ACCT_EXPORTS=""; ACCT_PINNED=0; ACCT_PICK_LABEL=""
  # >>> own-account pin (BH-1657)
  # A PROJECT PINNED TO ITS OWN CLAUDE ACCOUNT RUNS ITS CLAUDE RUNG ON THAT
  # ACCOUNT AND NO OTHER, whatever ACCOUNT_ROUTING says and whatever box this is:
  # every hub lane that works a project's PR reaches Claude through here. The
  # picker is never asked, so the shared project-6/max accounts are never in play.
  #   (a) <env dir>/accounts.d/<label>.env has the token: run on it, with a box
  #       ANTHROPIC_API_KEY unset so it cannot outrank the pinned OAuth token.
  #   (b) no file, but the live token's fp already maps to the label, or to an
  #       alias of it in catalog/account-aliases.json (BH-3559): a Fly builder,
  #       whose bundle carries the pinned token (pool_account_lease), or the
  #       owning box, whose overlay names its own token claude:<x>-dedicated.
  #   (c) anything else fails CLOSED: nothing is called, rc 76, the rung
  #       descends to the non-claude ladder. Never the box's default credential.
  # Only the claude runner is pinned; codex keeps its routing below.
  local _pin=""
  [ "$runner" = claude ] && _pin=$(account_label_for_project "$PROJECT" 2>/dev/null)
  if [ -n "$_pin" ]; then
    local _pex="" _prc2=0
    ACCT_PINNED=1; ACCT_NAME="$_pin"
    _pex=$(project_account_exports "$PROJECT" 2>/dev/null) || _prc2=$?
    if [ "$_prc2" -eq 0 ] && [ -n "$_pex" ]; then
      ACCT_EXPORTS="unset ANTHROPIC_API_KEY"$'\n'"$_pex"
    elif project_account_live_matches "$_pin"; then
      [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && ACCT_EXPORTS="unset ANTHROPIC_API_KEY"
    else
      echo "$(STAMP) [$PROJECT] $STAGE claude: pinned account $_pin for $PROJECT has no token on this box, not falling back to shared accounts, descending" >> "$HARNESS/logs/failovers.log"
      echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ'),$PROJECT,$STAGE,$MODEL,$_pin,pinned_unavailable" >> "$HARNESS/logs/account-routing.log"
      project_account_alert_unavailable "$PROJECT" "$_pin" agent-call
      [ -z "${ANY_RAN:-}" ] && printf 'AGENT_CALL_NO_HEADROOM pinned account %s has no token on this box\n' "$_pin" > "$OUT" 2>/dev/null
      RC=76
      return 76
    fi
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ'),$PROJECT,$STAGE,$MODEL,$_pin,pinned" >> "$HARNESS/logs/account-routing.log"
    project_account_alert_resolve "$PROJECT"
  # <<< own-account pin
  elif [ "${ACCOUNT_ROUTING:-0}" = 1 ] && { [ "$runner" = claude ] || [ "$runner" = codex ]; } \
     && [ -x "$HARNESS/bin/account-pick.sh" ]; then
    local _pick _prc=0 _pk=""
    # Sticky per BUILD, so a build's later stages keep the warm prompt cache.
    case "$OUT" in */builds/*/*) _pk=$(basename "$(dirname "$OUT")") ;; esac
    _pick=$(ACCOUNT_PIN_KEY="$_pk" "$HARNESS/bin/account-pick.sh" "$STAGE" "$runner" "$MODEL" 2>/dev/null) || _prc=$?
    if [ "$_prc" -eq 2 ]; then
      # No headroom anywhere: step down the ladder NOW rather than buy a call
      # that is going to fail. No cost row, because nothing was called.
      echo "$(STAMP) [$PROJECT] $STAGE $runner: no $runner account with quota headroom — stepping down the ladder without a call" >> "$HARNESS/logs/failovers.log"
      echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ'),$PROJECT,$STAGE,$MODEL,-,no_headroom" >> "$HARNESS/logs/account-routing.log"
      # Marker like the no-tools refusal above: if every later rung is also
      # unavailable the caller reads $OUT, and a stale $OUT from an earlier
      # attempt at this path would read as a real answer.
      printf 'AGENT_CALL_NO_HEADROOM no %s account with quota headroom\n' "$runner" > "$OUT" 2>/dev/null
      RC=76
      return 76
    elif [ "$_prc" -eq 0 ]; then
      ACCT_NAME=$(sed -n 's/^name=//p' <<<"$_pick" | head -1)
      ACCT_PICK_LABEL=$(sed -n 's/^label=//p' <<<"$_pick" | head -1)
      ACCT_EXPORTS=$(grep -E '^(export|unset) ' <<<"$_pick")
      echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ'),$PROJECT,$STAGE,$MODEL,$ACCT_NAME,$(sed -n 's/^reason=//p' <<<"$_pick" | head -1)" >> "$HARNESS/logs/account-routing.log"
    fi  # any other rc: the pick itself broke — run exactly as today, on the default credentials
  fi
  # ACT-TIME FENCE FOR THE NON-CLAUDE LANES (SDLC item 8, 2026-09-06).
  #
  # The iron-law guard below is a Claude Code PreToolUse hook, so it fences the
  # claude branch and nothing else — while project-4 and project-1 run EXECUTE on
  # codex with --dangerously-bypass-approvals-and-sandbox. On those two projects
  # the five iron laws are prompt-only at the stage that writes code. This is
  # the runner-agnostic half: bin/lane-shims/ goes on the front of PATH (each
  # shim asks the SAME classifier and then execs the real binary), and
  # bin/lane-fence.sh points git at a hooks dir whose pre-push refuses main and
  # then chains to the repo's own hook. Both read HARNESS_LANE, so a leak into
  # an unfenced session is inert exactly like the hook's own lane fence.
  #
  # Same two doctrines as the hook: a MISSING fence is an ALERT and never a
  # silent ungated lane, and the fence never refuses the CALL — a fence that
  # fails closed takes the lane down with it.
  local -a FENCE_ENV=(); local _FENCE_PATH="" _kv
  if [ "$runner" != claude ] && [ "${LANE_FENCE:-1}" != 0 ]; then
    case " ${IRON_LAW_LANES:-plan execute review fix qa triage} " in
      *" $STAGE "*)
        if [ -x "$HARNESS/bin/lane-shims/_fence.sh" ]; then
          # Prepend ONCE. A fenced session that calls agent-call.sh itself (or a
          # resumed lane inheriting the env) already carries the dir; a second
          # copy makes _fence.sh's single strip leave one behind, the real
          # binary resolves back to the shim, and every shimmed command —
          # git, npm, everything — exits 127. Already there is already fenced.
          case ":$PATH:" in
            *":$HARNESS/bin/lane-shims:"*) _FENCE_PATH="" ;;
            *) _FENCE_PATH="$HARNESS/bin/lane-shims:" ;;
          esac
          FENCE_ENV=(HARNESS="$HARNESS" HARNESS_LANE="$STAGE" HARNESS_LANE_PROJECT="$PROJECT" \
                     HARNESS_LANE_WT="$PWD" LANE_FENCE="${LANE_FENCE:-1}")
          # The hooks half is best-effort on top: no git repo here, or a hooks
          # dir this box cannot write, leaves the PATH shims doing their job.
          while IFS= read -r _kv; do
            [ -n "$_kv" ] && FENCE_ENV+=("$_kv")
          done < <("$HARNESS/bin/lane-fence.sh" hooks-env "$PWD" 2>/dev/null)
        else
          echo "$(STAMP) [$PROJECT] $STAGE: act-time lane fence MISSING at $HARNESS/bin/lane-shims/_fence.sh — this $runner lane is running UNGUARDED (merge/push/deploy/prod-write are prompt-only here). Deploy the harness: bin/harness-sync.sh." >> "$ALERTS"
        fi ;;
    esac
  fi
  # THE EGRESS ALLOWLIST (BH-4492). A build-dir call whose stage has an
  # egress.stage.<stage>.hosts row runs its CLI inside its own network
  # namespace (EG_WRAP, right after "$TO" on every runner line below), where
  # the only way out is bin/egress-proxy.py allowing that row's hosts. Refusals
  # land in $BUILD/egress.log, one line per call in $BUILD/egress-state.txt.
  # Empty EG_WRAP (no row, not a build, or a box that cannot fence — the last
  # one alerts) leaves every argv exactly as it was.
  local -a EG_WRAP=()
  eg_begin "$STAGE" "$OUT" "$runner"
  case "$runner" in
    claude)
      # Fable stages retry once as opus-5 before the lane fails (the operator 2026-08-04):
      # fable-specific credit exhaustion should degrade to opus, not to codex.
      # An account-wide cap makes the opus retry fail fast, so nothing is lost.
      #
      # Credit-exhaustion cooldown (the operator 2026-08-07): when fable fails with
      # "out of usage credits", stamp a cooldown and go STRAIGHT to opus for the
      # next MODEL_COOLDOWN_SECS (default 6h) — the exhausted pool was being
      # re-probed on every run, a wasted fast-fail each time. The first call
      # after the cooldown expires tries fable again (that IS the 6h probe);
      # success clears the stamp, another credit failure re-stamps it.
      # THE CLAUDE LADDER IS A model_routes ROW (BH-1510.1). BH-1507 carried it
      # as three literals — the Opus rung, the Opus CLI floor behind it, and
      # the review lane's Fable tail. It is now the call's role ladder (see
      # claude_ladder: the build stage's role, AGENT_CALL_ROLE, or
      # claude.ladder), resolved on the first failure. Two rules decide how
      # far down it a call may walk, and they are #1523's, unchanged:
      #   - ON A CLI REFUSAL (THE CLI FLOOR below), the next rung serves,
      #     whatever it is, with one ALERTS line per box per model per day.
      #   - ON AN ORDINARY FAILURE, the next rung serves only when it is a
      #     different model FAMILY (Fable -> Opus, the review lane's Opus ->
      #     Fable). An older release of the SAME family (Opus 5.5 -> Opus 5)
      #     is a CLI floor: an ordinary 5.5 failure is not a reason to buy the
      #     same work again on 5, so that rung is reached ONLY on the refusal.
      local CLI_FLOOR_HIT=0 _cliv _ci=0 _cnext _ladder
      local ARGS cm _guard CANDIDATES=("$MODEL") CLADDER_DONE=""
      # claude_ladder_fill — CANDIDATES becomes the resolved ladder, once. A
      # role with no route leaves it as ($MODEL): no failover rung is guessed.
      claude_ladder_fill() {
        [ -n "$CLADDER_DONE" ] && return 0
        CLADDER_DONE=1
        _ladder=$(claude_ladder 2>/dev/null)
        [ -n "$_ladder" ] && mapfile -t CANDIDATES <<<"$_ladder"
        [ "${#CANDIDATES[@]}" -gt 0 ] || CANDIDATES=("$MODEL")
        return 0
      }
      # The fable cooldown is keyed to the ACCOUNT when routing picked one:
      # account A running out of fable credits must not send account B straight
      # to opus for six hours, which is the exact loss routing exists to avoid.
      # `default` is treated as no suffix, so a box that turns routing on keeps
      # the cooldown state it already had. Path unchanged when routing is off.
      local _cdk=""; [ -n "${ACCT_NAME:-}" ] && [ "$ACCT_NAME" != default ] && _cdk="-$ACCT_NAME"
      local CDFILE="$HARNESS/state/model-cooldown-$MODEL$_cdk" CDNOW CDAT
      # A Fable model inside its credits cooldown starts one rung down — the
      # stamp is only ever written for a Fable rung with a rung behind it. The
      # cooldown is this box's stamp in its window OR a live fleet row for the
      # same key (BH-2356), `<model>/<account>` there where the file has a dash.
      local _cdhot=""
      case "$MODEL" in
        claude-fable-*)
          if [ -f "$CDFILE" ]; then
            CDNOW=$(date +%s); CDAT=$(cat "$CDFILE" 2>/dev/null || echo 0)
            case "$CDAT" in ''|*[!0-9]*) CDAT=0;; esac
            [ $(( CDNOW - CDAT )) -lt "${MODEL_COOLDOWN_SECS:-21600}" ] && _cdhot=1
          fi
          [ -z "$_cdhot" ] && fcd_live model claude "$MODEL${_cdk:+/$ACCT_NAME}" && _cdhot=1
          if [ -n "$_cdhot" ]; then
            claude_ladder_fill
            [ "${#CANDIDATES[@]}" -gt 1 ] && [ "$(model_family "${CANDIDATES[1]}")" != "$(model_family "$MODEL")" ] && _ci=1
          fi ;;
      esac
      # An index, not `for cm in "${CANDIDATES[@]}"`: the ladder is filled
      # lazily on the first failure, and a for-list is fixed when it starts.
      while [ "$_ci" -lt "${#CANDIDATES[@]}" ]; do
        cm="${CANDIDATES[$_ci]}"; _ci=$((_ci+1))
        rmodel="$cm"
        CACHE_TTL_SEEN=""; PRICE_V_SEEN=""
        # ONE SESSION ID PER ATTEMPT, minted up front. The survival ladder can
        # run this loop twice (fable, then opus) and each run is its own
        # session and its own row, so a single id for the attempt would price
        # the retry with the first try's transcript. Minted BEFORE the call
        # because that is the whole point: a run killed by the timeout, by the
        # OOM killer or by a kill -9 never writes a result envelope, and until
        # now those rows shipped with blank tokens and blank dollars (16 of one
        # day's 478 hub claude rows; 2,008 of 8,000 all-time). The transcript is
        # on disk either way — it just has to be findable.
        SESSION_ID=""
        cost_transcript_enabled && SESSION_ID=$(cost_row_uuid)
        # PER-CALL DOLLAR BOUND. The orchestrator got this in #75; every claude
        # lane routed through here had none — including alert-triage, which
        # runs claude PRIMARY on the hub and therefore bills an account that is
        # in overage, i.e. cash at API rates with nothing bounding a single
        # call. A bound that exists on one caller and not on the shared path is
        # a bound most of the fleet does not have.
        #
        # UNVERIFIED under subscription OAuth, exactly as in #75, and checked
        # the same way rather than assumed: the cost row this call writes is
        # compared against the budget below, and a call that outspends it
        # without the CLI reporting a stop proves the flag inert.
        if [ "$NO_TOOLS" = 1 ]; then
          # `--tools ""` is the CLI's documented "disable all tools", and
          # --dangerously-skip-permissions is deliberately DROPPED here: with no
          # tools there is nothing to permit, and if the ban ever failed to take
          # effect the safe failure is a call that stalls on a permission prompt
          # rather than one that silently acts with the hub's credentials.
          ARGS=(-p --tools "" --model "$cm" --output-format json
                --max-budget-usd "$(_budget_for "$STAGE" "$PROJECT" "$runner")")
        elif [ -n "$TOOLS_ALLOW" ]; then
          # The allowlist (BH-4065): only these built-ins, and no MCP server.
          ARGS=(-p --dangerously-skip-permissions --tools "$TOOLS_ALLOW"
                --strict-mcp-config --mcp-config '{"mcpServers":{}}'
                --model "$cm" --output-format json
                --max-budget-usd "$(_budget_for "$STAGE" "$PROJECT" "$runner")")
        else
          ARGS=(-p --dangerously-skip-permissions --model "$cm" --output-format json
                --max-budget-usd "$(_budget_for "$STAGE" "$PROJECT" "$runner")")
        fi
        # RESUME A STUCK SESSION RATHER THAN BUY A COLD ONE (2026-09-16). The
        # ladder sets LADDER_RESUME_SID when it is retrying THIS runner after a
        # timeout: the work the killed window already did is on disk, and
        # --resume is what picks it back up. --session-id and --resume are
        # mutually exclusive (one mints an id, the other adopts one), so it is
        # one or the other. A CLI without --resume simply starts fresh — the
        # retry still happens, it just pays for the context again.
        if [ -n "${LADDER_RESUME_SID:-}" ] && claude_supports_resume; then
          SESSION_ID="$LADDER_RESUME_SID"; ARGS+=(--resume "$SESSION_ID")
        elif [ -n "$SESSION_ID" ]; then
          ARGS+=(--session-id "$SESSION_ID")
        fi
        # THE ADVISOR (BH-3491), resolved per attempt because the ladder changes
        # the main model and a Fable main pairs only with a Fable advisor. The
        # consult line rides the ONE --append-system-prompt, and only on an
        # attempt that carries the flag: PROMPT (and so PROMPT_SHA, the call-guard
        # fingerprint) is never touched.
        local _adv="" _append="${AGENT_SYSTEM_APPEND:-}"
        [ "$TOOL_FENCED" != 1 ] && [ -z "$ADV_DROPPED" ] && _adv=$(advisor_for_call "$STAGE" "$PROJECT" "$cm")
        ADV_ATTEMPT="$_adv"
        if [ -n "$_adv" ]; then
          ARGS+=(--advisor "$_adv")
          _append="${_append:+$_append$'\n\n'}$ADVISOR_CONSULT_LINE"
        fi
        [ -n "$_append" ] && ARGS+=(--append-system-prompt "$_append")
        # THE SESSION PROFILE (P1). Built per ATTEMPT, from this call's stage:
        # its argv words go on here (before --settings and the variadic
        # --disallowedTools, so --mcp-config's variadic ends at the next flag),
        # its TTL env rides the `env` in front of claude below, and its plugin
        # override joins the settings merge BEFORE the guard, which stays last.
        # Unprofiled stage = all three empty = the invocation as it was.
        # The config dir the CHILD runs under: ACCT_EXPORTS (account routing)
        # is only ever eval'd in a subshell, so it is resolved in one here too
        # — otherwise a routed call's profile reads the default account's
        # plugins and MCP servers instead of the routed account's.
        local SP_ACTIVE="" SP_SETTINGS="" SP_TTL="" _SP_CDIR=""; local -a SP_ARGS=() SP_ENV=()
        _SP_CDIR=$( eval "$ACCT_EXPORTS" 2>/dev/null; printf '%s' "${CLAUDE_CONFIG_DIR:-}" )
        session_profile_build "$STAGE" "$PWD" "$_SP_CDIR"
        # Under the allowlist the profile's MCP pair is dropped: its servers
        # are the ones the allowlist's empty set exists to keep out.
        if [ -n "$TOOLS_ALLOW" ] && [ "${#SP_ARGS[@]}" -gt 0 ]; then
          local -a _spk=(); local _i
          for ((_i = 0; _i < ${#SP_ARGS[@]}; _i++)); do
            case "${SP_ARGS[$_i]}" in
              --strict-mcp-config) ;;
              --mcp-config) _i=$((_i + 1)) ;;
              *) _spk+=("${SP_ARGS[$_i]}") ;;
            esac
          done
          SP_ARGS=(${_spk[@]+"${_spk[@]}"})
        fi
        [ "${#SP_ARGS[@]}" -gt 0 ] && ARGS+=("${SP_ARGS[@]}")
        # SETTINGS COMPOSITION. Three lanes want a --settings file and the flag
        # takes ONE value, so they are collected and merged here rather than
        # appended one after another (a second --settings REPLACES the first —
        # appending would have silently dropped the red-squigglies hook the day
        # the guard below shipped). Deep object merge, guard LAST so it wins any
        # key collision.
        #
        #   1. Red-squigglies pilot (the operator 2026-08-23, project-4 first): per-edit lint
        #      + debounced background typecheck fed straight back into the
        #      execute loop via a PostToolUse hook. Gated per-project by
        #      EDIT_FEEDBACK=1 in env/<project>.env (envbundle carries it to fly
        #      builders too).
        #   2. PER-CALL TOOL POLICY (2026-08-25, tier-2 remediator): AGENT_SETTINGS
        #      is a caller-owned policy file; this lane only carries it.
        #   3. ACT-TIME IRON-LAW GUARD (2026-08-29) — see below.
        local _sets=() _settings=""
        [ "${EDIT_FEEDBACK:-}" = "1" ] && [ "$STAGE" = "execute" ] && [ -f "$HARNESS/bin/edit-feedback-settings.json" ] \
          && _sets+=("$HARNESS/bin/edit-feedback-settings.json")
        [ -n "${AGENT_SETTINGS:-}" ] && [ -f "${AGENT_SETTINGS:-}" ] && _sets+=("$AGENT_SETTINGS")
        #   4. SESSION PROFILE plugin override (P1): enabledPlugins:false for
        #      every plugin the session would load. Before the guard, but AFTER
        #      AGENT_SETTINGS — so on a profiled stage a plugin the box's
        #      settings enable stays OFF even when a caller's policy file
        #      deliberately re-enables it (the later file wins). That is the
        #      profile's contract; a caller that needs a plugin sets
        #      SESSION_PROFILE_PLUGINS_OFF=0 or leaves its stage unprofiled.
        [ -n "${SP_SETTINGS:-}" ] && [ -f "$SP_SETTINGS" ] && _sets+=("$SP_SETTINGS")
        # ACT-TIME IRON-LAW GUARD (SDLC item 1, 2026-08-29). A PreToolUse hook
        # that mechanically DENIES the five irreversible families on the build
        # and triage lanes — merging a PR, pushing main, prisma at a live DB, a
        # raw client writing prod, a Vercel deploy/promote — at the moment the
        # agent reaches for them instead of at review time. HARNESS_LANE is the
        # marker the hook fences on; the orchestrator, box-chat, greenfield and
        # every merge-lane script never come through here with a guarded stage,
        # so they keep the authority they are supposed to have. The first three
        # are not unmarked, though: each arms the SAME hook from its own launcher
        # through bin/iron-law-arm.sh, which puts them in the guard's family-6
        # set (destructive filesystem verbs) while leaving families 1-5 alone.
        #
        # HARNESS_LANE_WT is this call's working directory, which the guard reads
        # into its allow-list: a lane legitimately blows away the worktree it
        # owns, and $HARNESS/builds being a protected root must not stop it.
        #
        # A MISSING guard is an ALERT, never a silent ungated lane: the failure
        # mode this must not have is the fleet quietly running unguarded while
        # everyone believes otherwise. It does not refuse the call — a guard
        # that fails closed takes every build lane down with it.
        case " ${IRON_LAW_LANES:-plan execute review fix qa triage} " in
          *" $STAGE "*)
            if [ -x "$HARNESS/bin/iron-law-guard.sh" ]; then
              export HARNESS HARNESS_LANE="$STAGE" HARNESS_LANE_PROJECT="$PROJECT" HARNESS_LANE_WT="$PWD"
              mkdir -p "$HARNESS/state" 2>/dev/null
              _guard="$HARNESS/state/iron-law-guard-settings.json"
              # 30s, not 10: a hook the CLI KILLS on its timeout runs the
              # command UNGUARDED, so the ceiling sits well above anything the
              # guard's own bounded read and classifier can take.
              jq -n --arg c "$HARNESS/bin/iron-law-guard.sh" \
                '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:$c,timeout:30}]}]}}' \
                > "$_guard.tmp.$$" 2>/dev/null \
                && mv -f "$_guard.tmp.$$" "$_guard" 2>/dev/null && _sets+=("$_guard")
            else
              echo "$(STAMP) [$PROJECT] $STAGE: act-time iron-law guard MISSING at $HARNESS/bin/iron-law-guard.sh — this lane is running UNGUARDED (merge/push/deploy/prod-write are prompt-only here). Deploy the harness: bin/harness-sync.sh." >> "$ALERTS"
            fi ;;
        esac
        if [ "${#_sets[@]}" -eq 1 ]; then
          _settings="${_sets[0]}"
        elif [ "${#_sets[@]}" -gt 1 ]; then
          # Atomic write (temp + rename) because claude must never read a
          # half-written settings file, and keyed on the INPUT LIST because
          # parallel builds share this box: two calls that name the same inputs
          # write byte-identical content, and two that do not get separate
          # files. A fixed per-stage path would let one build's policy land in
          # another build's session.
          _settings="$HARNESS/state/agent-settings-$STAGE-$(printf '%s' "${_sets[*]}" | cksum | cut -d' ' -f1).json"
          if jq -s 'reduce .[] as $x ({}; . * $x)' "${_sets[@]}" > "$_settings.tmp.$$" 2>/dev/null \
             && [ -s "$_settings.tmp.$$" ] && mv -f "$_settings.tmp.$$" "$_settings" 2>/dev/null; then :
          else
            # Merge failed: fall back to the LAST file rather than to none. The
            # guard is appended last precisely so the fallback keeps it.
            rm -f "$_settings.tmp.$$" 2>/dev/null
            _settings="${_sets[${#_sets[@]}-1]}"
            echo "$(STAMP) [$PROJECT] $STAGE: could not merge ${#_sets[@]} settings files — running with $(basename "$_settings") only." >> "$ALERTS"
          fi
        fi
        [ -n "$_settings" ] && ARGS+=(--settings "$_settings")
        # AGENT_DISALLOWED_TOOLS is a NEWLINE-separated list of permission specs
        # handed to --disallowedTools.
        #
        # Newline-separated, not space-separated, because a spec is
        # `Bash(gh pr merge:*)` — it contains spaces, and word-splitting one
        # would silently deny `Bash(gh` and permit the rest. Passed as ONE
        # variadic flag (repeating a variadic flag replaces rather than
        # accumulates) and LAST, so the variadic cannot swallow another flag.
        if [ -n "${AGENT_DISALLOWED_TOOLS:-}" ]; then
          local _dt=() _spec
          while IFS= read -r _spec; do [ -n "$_spec" ] && _dt+=("$_spec"); done <<<"$AGENT_DISALLOWED_TOOLS"
          [ "${#_dt[@]}" -gt 0 ] && ARGS+=(--disallowedTools "${_dt[@]}")
        fi
        # Prompt rides STDIN: a >128KB prompt as an argv element fails execve
        # with E2BIG before any model runs (review sweeps died on big PR diffs,
        # 2026-08-05). printf is a bash builtin, so it has no argv ceiling.
        # CONTEXT KILL ARMING (BH-653). Two conditions, both required: the lane
        # declares a ceiling, and the meter can actually read this attempt's
        # session — which needs a minted session id AND the transcript reader.
        # The ceiling is resolved FIRST and the enforceability checked second,
        # because the interesting state is "the manifest says this lane is
        # bounded and on this box it is not", and that state is invisible if a
        # missing session id makes us skip the lookup entirely.
        # The marker file is removed before EVERY attempt so a kill on the fable
        # try can never be read as a kill on the opus one. The same is true of
        # the cliff marker, which is per-model: the fable rung may have a cliff
        # where the opus rung has none (BH-1384).
        rm -f "$OUT.ctxkill" "$OUT.cliffcap" "$OUT.tripwire"
        local _CAP="" _CPID="" _MPID="" _CTXF="" _CTXWHY="" _CL="" _LPID=""
        _CAP=$(_ctx_kill_ceiling "$STAGE" "$PROJECT" "$runner" "$cm")
        if [ -n "$_CAP" ]; then
          _CTX_TCB="$(dirname "$0")/transcript-cost.sh"
          [ -x "$_CTX_TCB" ] || _CTX_TCB="$HARNESS/bin/transcript-cost.sh"
          if [ ! -x "$_CTX_TCB" ]; then
            _CTXWHY="bin/transcript-cost.sh is not executable on this box"
          elif [ -z "$SESSION_ID" ]; then
            # No id was minted, so the CLI writes a transcript we cannot name.
            # The reason is nameable and an operator can act on it, so it goes
            # in the line rather than "unenforceable, good luck".
            _CTXWHY="this attempt has no session id (COST_TRANSCRIPT_ROWS=0, or flags/transcript-cost-off, turns transcript rows off — and the meter reads the transcript)"
          fi
          if [ -n "$_CTXWHY" ]; then
            # DECLARED BUT UNENFORCEABLE is a fact an operator has to be told:
            # the manifest says this lane is bounded and on this box it is not.
            # Once per stage per day — the same shape as the inert-flag files,
            # so a busy lane reports the condition instead of paging on it.
            _CTXF="$HARNESS/flags/alerted-ctxkill-unenforceable-$STAGE-$(date -u +%Y%m%d)"
            [ -f "$_CTXF" ] || { mkdir -p "$HARNESS/flags" 2>/dev/null; touch "$_CTXF" 2>/dev/null
              echo "$(STAMP) [agent-call] CONTEXT KILL UNENFORCEABLE: $STAGE/$PROJECT declares context_kill_tokens $_CAP but $_CTXWHY — the session runs UNBOUNDED." >> "$ALERTS"; }
            _CAP=""
            # No ceiling means no kill, so a cliff marker for this attempt would
            # describe a bound that is not in force.
            rm -f "$OUT.cliffcap"
          fi
        fi
        # `env -u AGENT_CALL_RUNNERS` (BH-1019): the lane restriction belongs to
        # THIS call, not to the session it starts. Inherited, it would silently
        # restrict any agent-call.sh the reviewer itself shells out to. The
        # same holds for AGENT_CALL_ROLE (BH-1510.1): the ladder is this call's.
        # The three ceiling variables are unset for exactly the same reason
        # (BH-1384): a caller that bounds ITS session must not bound every
        # session that session starts — the responder's act playbook may
        # `setsid run-build.sh`, and a setsid child inherits the environment.
        # Live cost (BH-3481.0) needs the CLI backgrounded too, so its meter can
        # run beside it. cost_live_on is a stub that answers off today.
        cost_live_on && _CL=1
        if [ -n "$_CAP" ] || [ -n "$_CL" ]; then
          # Same invocation, backgrounded so the meter can watch it. $! is the
          # pipeline's last element — the subshell, which execs into timeout, so
          # a TERM to it is forwarded to the whole process group the CLI runs in
          # (and --kill-after=120 still SIGKILLs a CLI that ignores it).
          printf '%s' "$PROMPT" | ( eval "$ACCT_EXPORTS"; exec timeout --kill-after=120 "$TO" ${EG_WRAP[@]+"${EG_WRAP[@]}"} env -u AGENT_CALL_RUNNERS -u AGENT_CALL_ROLE -u CONTEXT_KILL_TOKENS -u CONTEXT_KILL_CLIFF -u CONTEXT_KILL_CLIFF_MARGIN IS_SANDBOX=1 ${SP_ENV[@]+"${SP_ENV[@]}"} claude "${ARGS[@]}" ) > "$OUT.json" 2> "$OUT.err" &
          _CPID=$!
          if [ -n "$_CAP" ]; then
            context_meter "$_CPID" "$SESSION_ID" "$_CAP" "$PWD" &
            _MPID=$!
          fi
          # The live meter needs a session to read, like the context meter.
          if [ -n "$_CL" ] && [ -n "$SESSION_ID" ]; then
            cost_live_meter "$_CPID" "$SESSION_ID" "$PWD" &
            _LPID=$!
          fi
          wait "$_CPID"; RC=$?
          [ -n "$_MPID" ] && { kill "$_MPID" 2>/dev/null; wait "$_MPID" 2>/dev/null; }
          [ -n "$_LPID" ] && { kill "$_LPID" 2>/dev/null; wait "$_LPID" 2>/dev/null; }
        else
          printf '%s' "$PROMPT" | ( eval "$ACCT_EXPORTS"; exec timeout --kill-after=120 "$TO" ${EG_WRAP[@]+"${EG_WRAP[@]}"} env -u AGENT_CALL_RUNNERS -u AGENT_CALL_ROLE -u CONTEXT_KILL_TOKENS -u CONTEXT_KILL_CLIFF -u CONTEXT_KILL_CLIFF_MARGIN IS_SANDBOX=1 ${SP_ENV[@]+"${SP_ENV[@]}"} claude "${ARGS[@]}" ) > "$OUT.json" 2> "$OUT.err"
          RC=$?
        fi
        if jq -e '.result' "$OUT.json" >/dev/null 2>&1; then
          jq -r '.result' "$OUT.json" > "$OUT"
          # The CLI envelope's own reading, kept under R_* rather than written
          # straight onto the row. It is the FALLBACK now, not the source: what
          # `.usage` actually covers was never verified, and this wave's
          # measurement says it is one turn — hub claude rows read ~$383 for a
          # day the transcripts price near $700 after de-duplication.
          R_IN=$(jq -r '.usage.input_tokens // ""' "$OUT.json"); R_OUT=$(jq -r '.usage.output_tokens // ""' "$OUT.json")
          R_CR=$(jq -r '.usage.cache_read_input_tokens // ""' "$OUT.json"); R_CW=$(jq -r '.usage.cache_creation_input_tokens // ""' "$OUT.json")
          R_USD=$(jq -r '.total_cost_usd // ""' "$OUT.json")
          # A session id the CLI reports beats the one we asked for: if a future
          # release ignores --session-id, the row must follow the CLI rather
          # than point at a file that does not exist.
          _SJ=$(jq -r '.session_id // ""' "$OUT.json" 2>/dev/null)
          [ -n "$_SJ" ] && SESSION_ID="$_SJ"
          # The TTL the cache writes ACTUALLY used (P1), from the envelope's
          # own ephemeral_5m/1h split — observed, never the one requested. It
          # rides the row's note as cache_ttl=<5m|1h|mixed> so a reader that
          # re-prices the row from tokens charges the right write rate.
          CACHE_TTL_SEEN=$(session_profile_ttl_seen "$OUT.json")
        else
          cat "$OUT.json" "$OUT.err" > "$OUT" 2>/dev/null
        fi
        # THE ADVISOR IS FAIL-OPEN (BH-3491). A CLI that refuses --advisor at
        # launch (old CLI, a pairing or allowlist it rejects, no Fable consent)
        # ran no API turn and billed nothing, so the same model runs again at
        # once without it. Once per call (ADV_DROPPED), and a per-account day
        # flag keeps later calls from launching into the same refusal. One warn
        # line (the digest, not a page) per account.
        if [ "$RC" -ne 0 ] && [ -n "$ADV_ATTEMPT" ] && advisor_launch_refused "$OUT.json" "$OUT.err"; then
          local _advf _adverr
          _advf=$(advisor_refused_flag "${ACCT_NAME:-default}" "$ADV_ATTEMPT") \
            && { mkdir -p "$HARNESS/flags" 2>/dev/null; touch "$_advf" 2>/dev/null; }
          _adverr=$( { jq -r 'select(.is_error == true) | .result // empty' "$OUT.json" 2>/dev/null; cat "$OUT.err" 2>/dev/null; } \
            | grep -m1 -i advisor | tr -d '\r' | cut -c1-200)
          echo "$(STAMP) [$PROJECT] $STAGE claude: $cm refused --advisor $ADV_ATTEMPT at launch ($_adverr) — retrying without the advisor" >> "$HARNESS/logs/failovers.log"
          HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" --severity warn --id "advisor-refused-${ACCT_NAME:-default}" --project "$PROJECT" \
            "[agent-call] $STAGE/$PROJECT: claude refused --advisor $ADV_ATTEMPT at launch ($_adverr); retried without the advisor. Advisor off for this account on this box until 00:00Z." >/dev/null 2>&1 || true
          ADV_DROPPED=1; ADV_ATTEMPT=""; _ci=$((_ci-1))
          continue
        fi
        # THE MARKER FILE IS AUTHORITATIVE, not the rc and not the clock. A CLI
        # that catches the TERM and prints a well-formed envelope exits 0, and
        # without this a session we cut in half would be handed to the caller as
        # a finished one — which is the failure this ticket exists to prevent.
        # Written onto $OUT after BOTH extraction branches, so `tail -1 "$OUT"`
        # (what alert-triage.sh logs) is the truncation notice either way.
        if [ -f "$OUT.ctxkill" ]; then
          [ "$RC" -eq 0 ] && RC=143
          local _CK=""; read -r _CK < "$OUT.ctxkill" || true
          printf '\nCONTEXT KILL: %s/%s session stopped by the harness at its context ceiling (%s) — output above is TRUNCATED\n' \
            "$STAGE" "$PROJECT" "$_CK" >> "$OUT"
          ctx_kill_alert "$cm" "$_CK"
          # The $OUT marker above keeps saying CONTEXT KILL: whichever bound
          # fired — it is the truncation notice every downstream reader matches
          # on (bin/review-autopilot.sh, alert-triage's `tail -1`), and the
          # WHICH-bound question is answered by the alert and this line.
          if [ -f "$OUT.cliffcap" ]; then
            local _CC=""; read -r _CC < "$OUT.cliffcap" || true
            echo "$(STAMP) [$PROJECT] $STAGE claude: CLIFF-AVOIDED: $cm stopped at its cliff-derived context ceiling ($_CK; $_CC) — policy stop, no model escalation and no vendor failover" >> "$HARNESS/logs/failovers.log"
          else
            echo "$(STAMP) [$PROJECT] $STAGE claude: $cm stopped at its lane context ceiling ($_CK) — policy stop, no model escalation and no vendor failover" >> "$HARNESS/logs/failovers.log"
          fi
          break
        fi
        # THE BUILD TRIPWIRE (BH-3481) stops a session the same way, checked
        # after the context kill so a session both fired on reads as the kill.
        # The marker is authoritative over the rc for the same reason. Nothing
        # writes it yet: the tripwire lib is a stub.
        if [ -f "$OUT.tripwire" ]; then
          [ "$RC" -eq 0 ] && RC=143
          local _TW=""; read -r _TW < "$OUT.tripwire" || true
          printf '\nTRIPWIRE: %s/%s session stopped by the harness build tripwire (%s) — output above is TRUNCATED\n' \
            "$STAGE" "$PROJECT" "$_TW" >> "$OUT"
          echo "$(STAMP) [$PROJECT] $STAGE claude: $cm stopped by the build tripwire ($_TW) — policy stop, no model escalation and no vendor failover" >> "$HARNESS/logs/failovers.log"
          break
        fi
        if [ "$RC" -eq 0 ]; then
          # A fable success after (or during) a cooldown clears it — credits are back.
          if [ "$cm" = "$MODEL" ] && [ -f "$CDFILE" ]; then
            rm -f "$CDFILE"
            echo "$(STAMP) [$PROJECT] $STAGE claude: $MODEL serving again — cooldown cleared" >> "$HARNESS/logs/failovers.log"
          fi
          break
        fi
        # A kill is not a model problem: escalating fable -> opus after a
        # SIGKILL just buys the same killed run at a higher rate.
        if { [ "$RC" -eq 137 ] || [ "$RC" -eq 143 ]; } && [ $(( $(date +%s) - T0 )) -lt $(( $(printf '%s' "$TO" | tr -cd '0-9') * 9 / 10 )) ]; then
          echo "$(STAMP) [$PROJECT] $STAGE claude: $cm killed (rc=$RC) — not escalating models on a kill" >> "$HARNESS/logs/failovers.log"
          break
        fi
        # A TIMEOUT is not a model problem either (2026-09-16): the window ran
        # out, the model never answered, and buying the same stuck run again at
        # the opus rate answers nothing. The ladder's transient recovery retries
        # this runner instead, resuming the session when the CLI can.
        if [ "$RC" -eq 124 ]; then
          echo "$(STAMP) [$PROJECT] $STAGE claude: $cm timed out (rc=124) — not escalating models on a timeout" >> "$HARNESS/logs/failovers.log"
          break
        fi
        # THE CLI FLOOR (BH-1507): this CLI does not know the model. That is
        # not the model failing and not the build failing — the next candidate
        # serves, and ONE line per box per model per day says which CLI version
        # needs bin/cli-update.sh.
        #
        # WHAT A STALE CLI ACTUALLY SAYS, in the mode this file runs it
        # (`-p --output-format json`; reproduced on 2.1.267 and 2.1.278): rc 1,
        # an envelope with is_error:true, api_error_status:400 and a .result of
        # "API Error: 400 Claude Code 2.1.267 does not support this model;
        # version 2.1.280 or newer is required. …", plus a stderr line tagged
        # [claude-code:unrecognized_model]. "isn't described by this version's
        # model catalog" is the TEXT-mode warning only; both are matched. The
        # envelope is read from its is_error .result, never from $OUT on its
        # own, because on a failed run $OUT can be the model's prose — a session
        # that quoted this pattern must not read as a floor. The stderr tag is
        # NOT a key: it can ride along with a model the API does serve.
        #
        # AND THE ENVELOPE MUST CARRY THE 400 (#1523 review, F5). A session
        # that ran, failed and quoted this sentence in its own .result is
        # is_error:true too; only the CLI's refusal is an API 400.
        local _flre="does not support this model; version [0-9.]+ or newer is required|described by this version's model catalog"
        if { jq -e --arg re "$_flre" '.is_error == true and ((.api_error_status // 0) | tostring) == "400" and ((.result // "") | test($re; "i"))' "$OUT.json" >/dev/null 2>&1 \
             || { ! jq -e . "$OUT.json" >/dev/null 2>&1 && grep -qiE "$_flre" "$OUT.json" 2>/dev/null; } \
             || grep -qiE "$_flre" "$OUT.err" 2>/dev/null; }; then
          CLI_FLOOR_HIT=1
          _cliv=$(cat "$OUT.json" "$OUT.err" 2>/dev/null | grep -oE 'Claude Code [0-9]+(\.[0-9]+)+' | head -1 | grep -oE '[0-9]+(\.[0-9]+)+')
          [ -n "$_cliv" ] || _cliv=$(timeout 10 claude --version 2>/dev/null | head -1 | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)
          local _next="" _then _flf
          claude_ladder_fill
          # The rung after this one in the RESOLVED ladder: claude_ladder always
          # starts at $MODEL and the loop walks it in order, so _ci already
          # points past cm.
          _next="${CANDIDATES[$_ci]:-}"
          if [ -n "$_next" ]; then _then="failing over to $_next"; else _then="no model left on this CLI, the ladder takes it"; fi
          # Once per box per refused model per day: a stale box refuses on every
          # call, and every ALERTS line is a family alert-triage may pay to read.
          _flf="$HARNESS/flags/alerted-cli-floor-$cm-${_cliv:-unknown}-$(date -u +%Y%m%d)"
          [ -f "$_flf" ] || { mkdir -p "$HARNESS/flags" 2>/dev/null; touch "$_flf" 2>/dev/null
            echo "$(STAMP) [$PROJECT] $STAGE CLI FLOOR: claude ${_cliv:-unknown} on $(hostname 2>/dev/null) does not support $cm — $_then. Run bin/cli-update.sh on this box (catalog/cli-min-versions.json names the floor). Once per box per day; every refusal is in logs/failovers.log." >> "$ALERTS"; }
          echo "$(STAMP) [$PROJECT] $STAGE claude: $cm unsupported by claude ${_cliv:-unknown} — ${_next:+retrying as $_next}$([ -n "$_next" ] || echo 'no candidate left')" >> "$HARNESS/logs/failovers.log"
          continue
        fi
        # AN ORDINARY FAILURE. The next rung of the resolved ladder serves only
        # when it is another model family; an older release of this one is the
        # CLI floor above, reached on a refusal alone.
        claude_ladder_fill
        _cnext="${CANDIDATES[$_ci]:-}"
        if [ -z "$_cnext" ] || [ "$(model_family "$_cnext")" = "$(model_family "$cm")" ]; then
          break
        fi
        if [ "$cm" = "$MODEL" ] && [[ "$MODEL" == claude-fable-* ]] && grep -qi "usage credits" "$OUT" 2>/dev/null; then
          date +%s > "$CDFILE"
          local _mcs="${MODEL_COOLDOWN_SECS:-21600}"; case "$_mcs" in ''|*[!0-9]*) _mcs=21600 ;; esac
          fcd_put model claude "$MODEL${_cdk:+/$ACCT_NAME}" "$(( $(date +%s) + _mcs ))" "$(date +%s)" "out of usage credits"
          echo "$(STAMP) [$PROJECT] $STAGE claude: $MODEL out of usage credits — cooling down $(( ${MODEL_COOLDOWN_SECS:-21600} / 3600 ))h, serving $_cnext directly" >> "$HARNESS/logs/failovers.log"
        else
          echo "$(STAMP) [$PROJECT] $STAGE claude: $cm failed rc=$RC — retrying as $_cnext" >> "$HARNESS/logs/failovers.log"
        fi
      done
      # Account that paid (or would have paid) for this claude attempt. The
      # merge conductor's lane-down marker is per-account (BH-1090); the empty
      # account means "default". Written for successes and claude-side failures
      # alike, but NOT for refusals that never invoked a claude account
      # (hub-no-build, no-tools, runners-restricted before account-pick).
      printf '%s\n' "${ACCT_NAME:-default}" > "$OUT.account" 2>/dev/null
      # The session's own file, so a caller can read every assistant message
      # (`.result` is the last one only; BH-6090). Only with a session id.
      [ -n "$SESSION_ID" ] && printf '%s\t%s\n' "$SESSION_ID" \
        "$(eval "${ACCT_EXPORTS:-}"; printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")" > "$OUT.session" 2>/dev/null
      # The id the ladder resumes with when this attempt turns out to be stuck.
      LADDER_LAST_SESSION="$SESSION_ID"
      ;;
    codex)
      local P="$PROMPT" SYS; SYS=$(rules_append "$runner"); [ -n "$SYS" ] && P="$SYS"$'\n\n'"$P"
      # Default pin (2026-09-06, GPT-6 bump): the ChatGPT-account default drifted
      # to ~z-ai/glm-latest on 2026-08-20, so "pin nothing" stopped tracking
      # OpenAI's best model. The astra slug is the only gpt-6 slug this auth mode
      # accepts (gpt-6 / gpt-6-codex / -pro / -mini / -astra-pro all 400).
      # Needs codex CLI >= 0.153.4 (the metadata for the slug ships with the
      # CLI; an older CLI is the project-9 lesson from the Fable 5.1 bump).
      # CODEX_MODEL in env/global.env still overrides; the default is the
      # codex.default route (resolved above, as RUNG_MODEL).
      rmodel="$RUNG_MODEL"
      # --skip-git-repo-check (BH-2307), as the openrouter and fireworks codex
      # rungs below already pass it: a caller whose cwd is not a git checkout
      # (the orchestrator's survival turn, /root/orchestrator) must not be refused
      # by codex's trusted-directory check. A worktree caller is unaffected.
      local CARGS=(exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check --output-last-message "$OUT" -m "$rmodel")
      : > "$OUT"
      # Over the argv ceiling the prompt goes on STDIN (`-`), exactly as the
      # openrouter and fireworks lanes below do it and for the same reason: this
      # is the PRIMARY lane for execute on project-4/project-1, and a review-sized
      # prompt as one argv element is E2BIG before any model runs (BH-495).
      # Under the ceiling, argv byte-for-byte as before.
      if agent_argv_too_big "$P"; then
        printf '%s' "$P" | ( eval "$ACCT_EXPORTS"; exec timeout --kill-after=120 "$TO" ${EG_WRAP[@]+"${EG_WRAP[@]}"} env "${FENCE_ENV[@]}" PATH="$_FENCE_PATH$PATH" \
          codex "${CARGS[@]}" - ) > "$OUT.events" 2> "$OUT.err"
      else
        ( eval "$ACCT_EXPORTS"; exec timeout --kill-after=120 "$TO" ${EG_WRAP[@]+"${EG_WRAP[@]}"} env "${FENCE_ENV[@]}" PATH="$_FENCE_PATH$PATH" \
          codex "${CARGS[@]}" "$P" ) > "$OUT.events" 2> "$OUT.err"
      fi
      RC=$?
      [ -s "$OUT" ] || cat "$OUT.events" "$OUT.err" > "$OUT" 2>/dev/null
      # Record the ACTUAL model codex resolved (its default moves with CLI
      # updates). It prints 'model: <name>' on STDERR — the old grep read only
      # the stdout events file and never matched, so 188 rows shipped under the
      # codex placeholder label, priced at the wrong model (the GPT-5.2 / 5.6 Sol
      # mixup).
      # The old unanchored grep read ANY "model: <word>" in the transcript —
      # including the agent's own prose and code ("model: string", "model:
      # schema", "model: await") — and 9 project-4 rows in one week shipped under
      # those names, which no price table carries, so the fleet's biggest
      # execute runs counted as $0 (2026-09-10). codex_seen_model() anchors on
      # the CLI's own banner line and the session ledger's "model" key, and
      # refuses anything that is not shaped like a model id.
      local seen; seen=$(codex_seen_model "$OUT.err" "$OUT.events" "$(eval "$ACCT_EXPORTS"; find "${CODEX_HOME:-$HOME/.codex}/sessions" -name "*.jsonl" -newermt "@$T0" 2>/dev/null | head -1)")
      [ -n "$seen" ] && rmodel="$seen"
      # Tokens from codex's OWN session ledger. The CLI reports none through the
      # wrapper, so these rows shipped with every count blank: correct for CASH
      # (this lane is flat-rate ChatGPT Pro, so cash really is $0) and wrong for
      # everything else — volume, notional lane comparison, and cost-per-PR all
      # read the busiest runner in the fleet as weightless. Same capture the
      # openrouter/fireworks lanes use, same '|' split for the same reason.
      CU_LINE=$(eval "$ACCT_EXPORTS"; "$HARNESS/bin/codex-usage.sh" "$T0" "" "$(codex_session_id "$OUT.err")" || true)
      IFS='|' read -r IN OUTT CR CW <<<"${CU_LINE// /|}"
      ;;
    openrouter)
      # Tier-3 survival lane (the operator, 2026-08-02): codex CLI against OpenRouter —
      # independent billing; engaging this lane means both primaries failed.
      local P="$PROMPT" SYS; SYS=$(rules_append "$runner"); [ -n "$SYS" ] && P="$SYS"$'\n\n'"$P"
      # Model = the stage's OWN model, via OpenRouter's anthropic/ slugs
      # (the operator, 2026-08-02: never substitute deepseek — keep the phase model).
      case "$MODEL" in
        */*) rmodel="$MODEL" ;;
        opus|sonnet|haiku|fable) rmodel="~anthropic/claude-$MODEL-latest" ;;
        *) rmodel="anthropic/$(printf '%s' "$MODEL" | sed -E 's/-([0-9]+)-([0-9]+)$/-\1.\2/')" ;;
      esac
      : > "$OUT"
      # -c values are TOML (strings need inner quotes); wire_api must be
      # "responses" on codex >=0.146; stdin MUST be closed or codex blocks
      # reading it (all three learned live, 2026-08-02).
      # Phase model first; deepseek-v4-flash is the LAST-RESORT floor — the one
      # provider-independent rung if Anthropic itself is the outage (the operator 2026-08-03:
      # when deepseek is used at all, it is flash, never chat).
      # model_reasoning_effort=minimal (2026-08-07): OpenRouter rotates the
      # anthropic/ slugs across Bedrock/Vertex/Azure/direct MID-LOOP, and a
      # thinking block signed by one provider 400s ("Invalid signature") when
      # replayed to another — the rung never once contributed. Minimal effort
      # keeps thinking blocks out of the transcript entirely. This is the
      # tier-3 floor: degraded reasoning beats a structurally dead rung.
      # The floor is the openrouter.floor route (BH-1510.1). No route, no floor:
      # the stage model's slug is still tried, and nothing is guessed below it.
      local orm orfloor _ori=0; local -a ORC ORMS=("$rmodel")
      orfloor=$(ac_model_for openrouter.floor) && [ "$orfloor" != "$rmodel" ] && ORMS+=("$orfloor")
      for orm in "${ORMS[@]}"; do
        rmodel="$orm"; _ori=$((_ori+1))
        # Below the anthropic/ slug is the last resort. It stays allowed — it is
        # the one rung that survives Anthropic itself being the outage — but it
        # never happens silently (2026-09-16).
        [ "$_ori" -gt 1 ] && ladder_last_resort "openrouter/$orm"
        ORC=(codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check
          --output-last-message "$OUT"
          -c 'model_providers.openrouter.name="OpenRouter"'
          -c 'model_providers.openrouter.base_url="https://openrouter.ai/api/v1"'
          -c 'model_providers.openrouter.env_key="OPENROUTER_API_KEY"'
          -c 'model_providers.openrouter.wire_api="responses"'
          -c 'model_provider="openrouter"'
          -c 'model_reasoning_effort="minimal"'
          -c 'model_providers.openrouter.stream_max_retries=0'
          -c 'model_providers.openrouter.request_max_retries=0'
          -m "$rmodel")
        # Retries off (BH-3983): codex's own `Reconnecting... n/5` loop re-sends
        # billed requests and only the last one reaches its ledger, so only that
        # one got a row (four 2026-09-16 plan-run.txt.err files). The ladder owns
        # retrying now, and every try gets its own row.
        # Over the argv ceiling the prompt goes on STDIN (`-`), which is the one
        # way a review-sized prompt reaches this lane at all. Under it, argv and
        # a closed stdin exactly as before — codex blocks reading stdin when it
        # is neither closed nor a prompt (learned live, 2026-08-02).
        # A kill mid-call still writes this rung's row (BH-3983, the block after
        # ac_cost_row_write). Background + wait, not a foreground call: bash
        # defers a trapped signal until a foreground child returns, so a TERM to
        # this pid alone would sit for up to $TO; `wait` returns at once.
        _ac_or_arm
        if agent_argv_too_big "$P"; then
          printf '%s' "$P" | timeout --kill-after=120 "$TO" ${EG_WRAP[@]+"${EG_WRAP[@]}"} env "${FENCE_ENV[@]}" PATH="$_FENCE_PATH$PATH" \
            "${ORC[@]}" - > "$OUT.events" 2> "$OUT.err" &
        else
          timeout --kill-after=120 "$TO" ${EG_WRAP[@]+"${EG_WRAP[@]}"} env "${FENCE_ENV[@]}" PATH="$_FENCE_PATH$PATH" \
            "${ORC[@]}" "$P" </dev/null > "$OUT.events" 2> "$OUT.err" &
        fi
        _AC_OR_PID=$!
        wait "$_AC_OR_PID"; RC=$?
        _ac_or_disarm
        [ -s "$OUT" ] || cat "$OUT.events" "$OUT.err" > "$OUT" 2>/dev/null
        # Tokens from codex's own ledger. Without this the row ships with every
        # count blank, row_cost has nothing to multiply, and a metered lane
        # prices at $0.00 — the bug that hid ~82 hub runs of real spend.
        # Fail-soft: a miss leaves the fields exactly as blank as they are today.
        # NOT $OUT.events: that file is the agent's final message as PLAIN TEXT,
        # never JSON, so passing it could only ever find nothing. Confirmed on a
        # real hub run. The tokens live in codex's session ledger, which
        # codex-usage finds by the session id in this rung's own stderr banner
        # (issue #62), falling back to mtime only when no banner was printed.
        # Split on '|', NOT on spaces. codex-usage.sh prints absent cache fields
        # as EMPTY columns ("1234 56  4096" = cache_read absent, cache_write
        # 4096), and bash collapses runs of IFS *whitespace* into one delimiter
        # — so a space-split slides cache_write into cache_read and prices at
        # the wrong rate, silently. IFS=' ' does NOT help: space is still IFS
        # whitespace and behaves exactly like the default. Substituting a
        # non-whitespace delimiter first is what actually preserves the columns.
        CU_LINE=$("$HARNESS/bin/codex-usage.sh" "$T0" "" "$(codex_session_id "$OUT.err")" || true)
        IFS='|' read -r IN OUTT CR CW <<<"${CU_LINE// /|}"
        [ "$RC" -eq 0 ] && break
        # The vendor's own words ride the line (2026-09-23): "failed rc=1" was
        # all 398 deferred runs left behind, and the 403 that explained every
        # one of them was only ever in an $OUT.err the next rung overwrote.
        echo "$(STAMP) [$PROJECT] $STAGE openrouter: $rmodel failed rc=$RC — $(tail -c 300 "$OUT.err" 2>/dev/null | tr '\n\r' '  ')" >> "$HARNESS/logs/failovers.log"
        # ONE ROW PER MODEL TRIED. run_attempt's own tail writes the row for the
        # LAST model; every model before it gets its row here, before the next
        # one overwrites the numbers, and the next one starts its clock fresh.
        if [ "$_ori" -lt "${#ORMS[@]}" ]; then
          T1=$(date +%s)
          ac_cost_row_write openrouter
          [ -n "${USD:-}" ] && PHASE_USD=$(awk -v a="${PHASE_USD:-0}" -v b="$USD" 'BEGIN{printf "%.6f", a+b}' 2>/dev/null)
          IN=""; OUTT=""; CR=""; CW=""; USD=""; T0=$(date +%s)
        fi
      done
      ;;
    fireworks)
      # Direct-vendor open-model lane (the operator, 2026-08-19): codex CLI against
      # Fireworks.ai — a FOURTH billing pool, and independent of OpenRouter's
      # routing/pre-auth headroom (the Aug-16/17 'No output generated' outage
      # class). Fireworks serves open models only — no anthropic/ slugs — so
      # unlike tier-3 this rung does NOT preserve the stage model: it trades
      # model fidelity for vendor independence. Single provider, so the
      # thinking-signature rotation that forced minimal effort on OpenRouter
      # doesn't apply here.
      local P="$PROMPT" SYS; SYS=$(rules_append "$runner"); [ -n "$SYS" ] && P="$SYS"$'\n\n'"$P"
      : > "$OUT"
      # Same codex gotchas as the openrouter lane: -c values are TOML, stdin
      # must be closed. wire_api="responses" — Fireworks serves the Responses
      # API natively (probed live 2026-08-19). Codex defaults web_search to
      # cached, which Fireworks rejects when Codex's client-executed tools are
      # present, so this provider must disable the server-executed search tool.
      # Ladder: FIREWORKS_MODEL, else the fireworks.default route (a
      # coding-tuned, tool-capable open model), then the fireworks.floor route
      # (flash, never chat/pro — same rule as the openrouter lane). BH-1510.1:
      # both are rows now; no floor route means no floor rung, never a guess.
      local fwm fwfloor _fwi=0; local -a FWC FWMS=("$RUNG_MODEL")
      fwfloor=$(ac_model_for fireworks.floor) && [ "$fwfloor" != "$RUNG_MODEL" ] && FWMS+=("$fwfloor")
      for fwm in "${FWMS[@]}"; do
        rmodel="$fwm"; _fwi=$((_fwi+1))
        [ "$_fwi" -gt 1 ] && ladder_last_resort "fireworks/${fwm##*/}"
        FWC=(codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check
          --output-last-message "$OUT"
          -c 'model_providers.fireworks.name="Fireworks"'
          -c 'model_providers.fireworks.base_url="https://api.fireworks.ai/inference/v1"'
          -c 'model_providers.fireworks.env_key="FIREWORKS_API_KEY"'
          -c 'model_providers.fireworks.wire_api="responses"'
          -c 'model_provider="fireworks"'
          -c 'web_search="disabled"'
          -m "$rmodel")
        # Same argv ceiling as the openrouter lane above, same reason: this rung
        # is the floor of the survival ladder, and a rung that E2BIGs on every
        # review-sized prompt is not a rung.
        if agent_argv_too_big "$P"; then
          printf '%s' "$P" | timeout --kill-after=120 "$TO" ${EG_WRAP[@]+"${EG_WRAP[@]}"} env "${FENCE_ENV[@]}" PATH="$_FENCE_PATH$PATH" \
            "${FWC[@]}" - > "$OUT.events" 2> "$OUT.err"
        else
          timeout --kill-after=120 "$TO" ${EG_WRAP[@]+"${EG_WRAP[@]}"} env "${FENCE_ENV[@]}" PATH="$_FENCE_PATH$PATH" \
            "${FWC[@]}" "$P" </dev/null > "$OUT.events" 2> "$OUT.err"
        fi
        RC=$?
        [ -s "$OUT" ] || cat "$OUT.events" "$OUT.err" > "$OUT" 2>/dev/null
        # Tokens from codex's own ledger. Without this the row ships with every
        # count blank, row_cost has nothing to multiply, and a metered lane
        # prices at $0.00 — the bug that hid ~82 hub runs of real spend.
        # Fail-soft: a miss leaves the fields exactly as blank as they are today.
        # NOT $OUT.events: that file is the agent's final message as PLAIN TEXT,
        # never JSON, so passing it could only ever find nothing. Confirmed on a
        # real hub run. The tokens live in codex's session ledger, which
        # codex-usage finds by the session id in this rung's own stderr banner
        # (issue #62), falling back to mtime only when no banner was printed.
        # Split on '|', NOT on spaces. codex-usage.sh prints absent cache fields
        # as EMPTY columns ("1234 56  4096" = cache_read absent, cache_write
        # 4096), and bash collapses runs of IFS *whitespace* into one delimiter
        # — so a space-split slides cache_write into cache_read and prices at
        # the wrong rate, silently. IFS=' ' does NOT help: space is still IFS
        # whitespace and behaves exactly like the default. Substituting a
        # non-whitespace delimiter first is what actually preserves the columns.
        CU_LINE=$("$HARNESS/bin/codex-usage.sh" "$T0" "" "$(codex_session_id "$OUT.err")" || true)
        IFS='|' read -r IN OUTT CR CW <<<"${CU_LINE// /|}"
        [ "$RC" -eq 0 ] && break
        echo "$(STAMP) [$PROJECT] $STAGE fireworks: $rmodel failed rc=$RC" >> "$HARNESS/logs/failovers.log"
      done
      ;;
    grok)
      # THE CLIFF ROUTE (BH-656), FIRST — before the CLI is built, before a
      # single token is spent. Both grok rungs reach this branch (the primary
      # runner and the tier-2 fallback), so one block covers every path a grok
      # call can arrive on. The rc is 79 with a marker as $OUT's first line:
      # nothing was called, no cost row, no provenance row, no .runner marker —
      # the same shape as the rc 76 "no account with headroom" return above.
      local _cliff _proj
      _cliff=$(cost_model_cliff "$RUNG_MODEL") || _cliff=""
      if [ -n "$_cliff" ] && cliff_route_enabled grok; then
        _proj=$(cliff_projected_context "$STAGE" "$PROJECT") || _proj=""
        if [ -n "$_proj" ] && [ "$_proj" -gt "$_cliff" ] 2>/dev/null; then
          echo "$(STAMP) [$PROJECT] $STAGE grok: CLIFF ROUTE — projected context $_proj (median of the last ${CLIFF_ROUTE_SAMPLE:-10} successful $STAGE/$PROJECT rows) is past the $RUNG_MODEL cliff $_cliff; nothing called, descending to the next rung" >> "$HARNESS/logs/failovers.log"
          printf 'AGENT_CALL_CLIFF_ROUTED grok projected %s > cliff %s\n' "$_proj" "$_cliff" > "$OUT"
          # The decision rides onto the row the SERVING rung writes, so the
          # ledger can tell "routed away from a doubled grok" from "grok was
          # never in this lane's ladder".
          CLIFF_ROUTE_NOTE="cliff-routed:grok:${_proj}>${_cliff}"
          RC=79
          eg_end cancelled
          return 79
        fi
      fi
      # TOOL-LOOP BOUND (2026-08-24). Hub triage measured ~480K mean input
      # tokens per call against a ~17KB composed prompt: the bytes are the
      # agent's OWN reads during the run, accumulating across the tool loop and
      # re-sent on every iteration. `--max-turns` bounds that loop.
      #
      # ⚠️ SEMANTICS UNVERIFIED. The CLI documents -p as "single-turn prompt and
      # exits", yet these sessions reach 620K input — so "agent turns" is almost
      # certainly tool-loop iterations, which is the bound we want. Almost
      # certainly is not verified, and a flag that silently bounds nothing is
      # the failure this wave exists to end. The cost ledger settles it: if mean
      # input per grok call does not fall after this deploys, the flag is inert
      # and runner_input_stats_7d will show it. Cheap to set, and its effect is
      # measured rather than assumed.
      #
      # 25 is deliberately generous — the healthy lane (medic) runs at 30K/call,
      # so a bound that bites normal work would be a correctness regression, not
      # a saving.
      # xAI's native Grok Build CLI (2026-08-03, replaces the codex provider
      # override — codex >=0.143 sends a `namespace` tool xAI's API 422s on).
      # Auth: device-auth OAuth as operator@example.com -> SuperGrok subscription pool.
      # XAI_API_KEY is UNSET for the call: if present the CLI silently prefers
      # it and bills the API wallet instead of the subscription.
      local P="$PROMPT" SYS; SYS=$(rules_append "$runner"); [ -n "$SYS" ] && P="$SYS"$'\n\n'"$P"
      rmodel="$RUNG_MODEL"
      # GROK_EFFORT (2026-08-16, project-4 triage pilot): the stagebench that
      # justified routing triage here ran grok at --reasoning-effort high;
      # production must match what was measured. Unset = CLI default.
      # GROK_BILLING=api keeps XAI_API_KEY in the env (metered wallet, exact
      # dollars — the project-4 triage pilot). Default: unset the key so the CLI
      # prefers subscription auth. Subscription auth.json CANNOT be shared
      # across busy boxes: xAI rotates the token family on refresh, so the
      # most active copy strands the others (hub's died after redirect's
      # refreshed, 2026-08-15 19:04 — the whole project-10-grok incident).
      local GROK_ENV=(env)
      [ "${GROK_BILLING:-}" = "api" ] || GROK_ENV=(env -u XAI_API_KEY -u GROK_CODE_XAI_API_KEY)
      # GROK_OUTPUT_JSON (BH-1494, default 0) — OPT-IN envelope capture. At 1
      # the CLI is asked for `--output-format json`, its result document is kept
      # beside the answer at $OUT.envelope, and grok-usage.sh prices the row
      # from THAT (one parse, the vendor's own dollars) instead of guessing
      # which file in ~/.grok belongs to this call. 1.0.40 accepts the flag
      # (checked on the Mac, 2026-09-22), but which envelope field carries the
      # ANSWER TEXT is documented nowhere this fleet can reach — docs.x.ai 404s
      # and x.ai/cli 403s from a box — so the default stays 0 and every existing
      # grok call is byte for byte what it was. Flip it once a probe on a 1.0.40
      # box confirms `.result`.
      local GROK_FMT=() _GJSON=0 _GRAW="$OUT"
      if [ "${GROK_OUTPUT_JSON:-0}" = 1 ]; then
        _GJSON=1; _GRAW="$OUT.envelope"; GROK_FMT=(--output-format json)
        # TRUNCATE $OUT HERE, BECAUSE THE CALL NO LONGER DOES. At knob 0 the
        # redirect below is `> "$OUT"`, which empties the file whatever the CLI
        # then writes; at knob 1 stdout goes to the envelope instead and $OUT is
        # only rewritten when that envelope has content. $OUT is keyed on
        # (PR, head) and the survival ladder reuses the path across attempts, so
        # without this an empty envelope (CLI exits 0, prints nothing) leaves an
        # EARLIER attempt's answer sitting there, the `[ -s "$OUT" ]` guard
        # below sees a non-empty file, and a stale answer ships as this call's
        # with rc 0 — no error anywhere to read.
        : > "$OUT"; rm -f "$OUT.envelope"
      fi
      # -p is the only prompt transport this CLI is known to take here, so over
      # the argv ceiling the lane refuses rather than E2BIGs (BH-495).
      if agent_argv_too_big "$P"; then
        agent_argv_refuse grok "$P"; RC=$?
      else
        timeout --kill-after=120 "$TO" ${EG_WRAP[@]+"${EG_WRAP[@]}"} "${GROK_ENV[@]}" "${FENCE_ENV[@]}" \
          PATH="$_FENCE_PATH$HOME/.grok/bin:$PATH" \
          grok --always-approve ${GROK_FMT[@]+"${GROK_FMT[@]}"} \
            ${GROK_EFFORT:+--reasoning-effort "$GROK_EFFORT"} \
            --max-turns "${GROK_MAX_TURNS:-25}" \
            -m "$rmodel" -p "$P" </dev/null > "$_GRAW" 2> "$OUT.err"
        RC=$?
      fi
      # The answer text, out of the envelope. `.result` is the spelling Claude
      # Code's envelope uses and the key set xAI prints matches it — but it is a
      # guess, so a miss passes the RAW envelope through rather than leaving an
      # empty $OUT, which the caller would classify as an empty answer.
      if [ "$_GJSON" = 1 ] && [ -s "$OUT.envelope" ]; then
        jq -r 'if type=="object" and (.result|type)=="string" then .result else empty end' \
          "$OUT.envelope" > "$OUT.result" 2>/dev/null
        if [ -s "$OUT.result" ]; then
          mv -f "$OUT.result" "$OUT"
        else
          rm -f "$OUT.result"; cat "$OUT.envelope" > "$OUT" 2>/dev/null
          echo "$(STAMP) [$PROJECT] $STAGE grok envelope had no .result — raw envelope passed through to $OUT" >> "$HARNESS/logs/$PROJECT.log"
        fi
      fi
      [ -s "$OUT" ] || cat "$OUT.err" > "$OUT" 2>/dev/null
      # REAL USAGE, FROM THE CLI'S OWN LEDGER — and no assumption about where
      # that ledger is or what it calls its keys. bin/grok-usage.sh walks
      # ~/.grok for any file touched since this call started and recurses each
      # line for a dict carrying an input+output token pair; costUsdTicks
      # (1e-10 USD) is read when it is there and never required.
      #
      # Both of those were assumptions in the version this replaces, and both
      # were wrong in production (BH-406, 217 blank rows in 24h): the ledger
      # path had already moved once, and a session billed against the SuperGrok
      # subscription pool reports no ticks at all — so requiring the ticks key
      # threw away a perfectly good token count and shipped the row blank.
      #
      # FAIL LOUD, NOT SOFT. A miss still leaves the fields blank, but the row
      # now says so (row_source stays `none`) and cost_parity_alert below pages
      # on the first such call instead of leaving it to the hub's daily rollup.
      local _GU GROK_LINE _GP
      _GU="$(dirname "$0")/grok-usage.sh"; [ -x "$_GU" ] || _GU="$HARNESS/bin/grok-usage.sh"
      # With an envelope in hand the reader takes it as the FIRST source: it
      # belongs to this call by construction, where the walk's newest-file rule
      # is only a good guess (see the concurrency limitation in its header).
      if [ "$_GJSON" = 1 ] && [ -s "$OUT.envelope" ]; then
        GROK_LINE=$("$_GU" --envelope "$OUT.envelope" "$T0" 2>/dev/null || true)
      else
        GROK_LINE=$("$_GU" "$T0" 2>/dev/null || true)
      fi
      # Split on '|', NOT on spaces, for the same reason as the codex lanes
      # above: absent fields print EMPTY, bash collapses runs of IFS whitespace
      # into one delimiter, and a space-split therefore slides cache_write into
      # cache_read and drops the dollars out of USD — silently.
      IFS='|' read -r IN OUTT CR CW USD <<<"${GROK_LINE// /|}"
      # WARN AT THE CLIFF (BH-656). The same ledger, read as the per-call SERIES
      # (--calls) rather than the session total: the records are cumulative, so
      # a call's own context is the delta between consecutive records, and the
      # FIRST delta past the cliff is the call where xAI started billing this
      # session double. One line, to the lane's own log, naming the call number
      # and the context — a number nobody could get from the cost row, because
      # the row is a session figure.
      #
      # Nothing here can block the row: no cliff means no read at all, and a
      # failed read means no line.
      if [ -n "${_cliff:-}" ]; then
        local _cl
        _cl=$("$_GU" --calls "$T0" 2>/dev/null | tr ' ' '|' | awk -F'|' \
          -v cliff="$_cliff" -v stamp="$(STAMP)" -v st="$STAGE" -v pj="$PROJECT" -v m="$rmodel" '
          { ctx = $2 + 0; if ($4 ~ /^[0-9]+$/) ctx += $4 + 0
            d = ctx - prev; prev = ctx
            if (d > cliff + 0) {
              printf "%s [agent-call] CLIFF: %s/%s grok call %s context %d crossed the %s cliff %s — every request from here is billed 2x by xAI\n", \
                stamp, st, pj, $1, d, m, cliff
              exit } }')
        [ -n "$_cl" ] && printf '%s\n' "$_cl" >> "$HARNESS/logs/$PROJECT.log"
      fi
      if [ -n "$IN$OUTT" ]; then
        # Something was actually read, so the row can say where its numbers came
        # from instead of reading `none` whether it was priced or missed.
        ROW_SRC=ledger
        # The vendor's own dollar figure (costUsdTicks) stays in result_usd
        # beside ours, so the two readings remain comparable.
        R_USD="$USD"
        # cost_usd is the fleet's price of the tokens, ticks or no ticks
        # (BH-3984): one pricer for every runner's recorded cost. Rows that
        # kept the ticks recorded 169 grok calls at $41 against a $770
        # reprice. Only a model the table cannot price keeps the vendor's
        # figure, and with no ticks either it stays blank for cost_row_price.
        _GP=$(cost_price_tokens "$rmodel" "$IN" "$OUTT" "$CR" "$CW") || _GP=""
        [ -n "$_GP" ] && USD="$_GP"
      fi
      ;;
    gemini)
      local P="$PROMPT" SYS; SYS=$(rules_append "$runner"); [ -n "$SYS" ] && P="$SYS"$'\n\n'"$P"
      rmodel="${GEMINI_MODEL:-gemini-default}"
      # Same as the grok lane above: -p is argv, so over the ceiling this lane
      # refuses with a readable marker instead of a doomed execve (BH-495).
      if agent_argv_too_big "$P"; then
        agent_argv_refuse gemini "$P"; RC=$?
      else
        timeout --kill-after=120 "$TO" ${EG_WRAP[@]+"${EG_WRAP[@]}"} env "${FENCE_ENV[@]}" PATH="$_FENCE_PATH$PATH" \
          gemini -y ${GEMINI_MODEL:+-m "$GEMINI_MODEL"} -p "$P" > "$OUT" 2> "$OUT.err"
        RC=$?
      fi
      [ -s "$OUT" ] || cat "$OUT.err" > "$OUT" 2>/dev/null
      ;;
  esac
  eg_end
  T1=$(date +%s)
  # >>> llm-gate-ran
  # THE ONE PLACE A RUNG HAS ACTUALLY EXECUTED (BH-1141 round 2, B1). Every
  # path that returns above this line returned without invoking a vendor CLI —
  # the no-tools refusal (78), the gate (74), no account with headroom (76), a
  # cliff route (79) — so this is where "money may have been spent" becomes
  # true, and $RC is final for the attempt from here to the end of the function.
  # The 74..79 case below is belt and braces for the one rc that reaches here
  # without a call: an argv-only lane's own refusal (79).
  case "$RC" in
    74|75|76|77|78|79) : ;;
    *) ANY_RAN=1; LAST_RAN_RC="$RC"; CG_RAN_RUNNERS="${CG_RAN_RUNNERS:+$CG_RAN_RUNNERS }$runner" ;;
  esac
  # <<< llm-gate-ran
  # Budget stop is POLICY, not an outage (2026-08-27, TK-109 +$424 lesson):
  # when the envelope says the run stopped on its --max-budget-usd bound, a
  # retry on another vendor re-spends the same context uncached. Detected
  # structurally here; the ladder below refuses to engage on it.
  BUDGET_STOP=""
  _TRS=$(jq -r '.terminal_reason // .subtype // .stop_reason // empty' "$OUT.json" 2>/dev/null)
  case "$_TRS" in *budget*|*Budget*|*BUDGET*) BUDGET_STOP=1 ;; esac
  # A CONTEXT KILL is OUR bound, and it is policy for the same reason a budget
  # stop is: the ladder's every rung re-buys the context the kill just stopped,
  # uncached and at API price. BUDGET_STOP is what the ladder, tier-2 grok,
  # tier-3 OpenRouter and tier-3b Fireworks already read, so the stop reuses it
  # rather than adding a fifth condition to four lines that must agree.
  CTX_STOP=""
  [ -f "$OUT.ctxkill" ] && { CTX_STOP=1; BUDGET_STOP=1; }
  # A TRIPWIRE stop (BH-3481) is policy too, and rides BUDGET_STOP for the same
  # reason. Its own flag keeps the log lines from calling it a context kill.
  # Claude only: that branch clears the marker before every attempt, so for any
  # other runner a $OUT.tripwire on disk is a stale one.
  TW_STOP=""
  [ "$runner" = claude ] && [ -f "$OUT.tripwire" ] && { TW_STOP=1; BUDGET_STOP=1; }
  # An EXTERNAL KILL is not a vendor failure (2026-08-27, after the false hub
  # "CLAUDE AUTH DOWN"): rc 137/143 is SIGKILL/SIGTERM — the OS, an operator or a
  # parent turn ending killed us. The vendor never answered, so there is nothing
  # to route around; failing that over re-buys the whole context on OpenRouter at
  # API price, uncached. That is the same money shape as the TK-109 cluster, just
  # with a different trigger. `timeout --kill-after` also lands on 137/143, but
  # only after the full window elapsed, so a kill well inside the window is the
  # only thing classified here. The ladder below refuses to engage on it.
  # ...and a context kill is NOT an external one, even though it lands on the
  # same rc 143 well inside the window. KILL_STOP buys one retry on the same
  # lane, which is precisely the re-spend the ceiling just refused.
  KILL_STOP=""
  if [ -z "$CTX_STOP$TW_STOP" ] && { [ "$RC" -eq 137 ] || [ "$RC" -eq 143 ]; }; then
    local _tos _el; _tos=$(printf '%s' "$TO" | tr -cd '0-9'); _el=$((T1-T0))
    if [ -n "$_tos" ] && [ "$_el" -lt $(( _tos * 9 / 10 )) ]; then
      KILL_STOP=1
      echo "$(STAMP) $PROJECT $STAGE $runner rc=$RC killed after ${_el}s of ${_tos}s; mem_avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null)kB load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)" >> "$HARNESS/logs/kills.log"
    fi
  fi
  # Where the numbers on this row come from: the transcript when there is one,
  # the CLI envelope otherwise. See cost_row_source above — it sets IN/OUTT/CR/
  # CW/USD/ROW_SRC/rmodel in this scope.
  cost_row_source "$runner" "$SESSION_ID" "$PWD"
  # Billing mode is derived HERE, where the box's credential env is live. The
  # hub cannot reconstruct it later: the same runner is flat-rate on one box and
  # per-token on another, and only the box that made the call can tell.
  # THE BOUND CHECKS ITSELF, same shape as #75. A call that cost more than the
  # budget while the CLI never said it stopped is proof the flag did nothing on
  # this account — reported once a day, naming what to believe instead.
  if [ "$runner" = claude ] && [ -n "${USD:-}" ]; then
    _B=$(_budget_for "$STAGE" "$PROJECT" "$runner")
    # READ THE ENVELOPE STRUCTURALLY, NOT THE ANSWER TEXT.
    #
    # The first version grepped "$OUT" — which on the SUCCESS path is
    # `jq -r '.result'`, i.e. only the model's answer. The CLI's stop signal
    # lives in the envelope ($OUT.json) or on stderr ($OUT.err), and those are
    # merged into $OUT only on the FAILURE branch. So whenever the CLI stopped
    # gracefully AND returned a result, the grep could not match BY
    # CONSTRUCTION, and the detector fired "treat the bound as absent" about a
    # bound that had just worked.
    #
    # That is #83's bug two files over: the thing that would tell you was
    # looking at the wrong stream. A bound has THREE questions, not two — is it
    # present, is it enforced, and is the check looking where the answer is.
    #
    # Structural rather than prose: .subtype/.stop_reason are fields, and a CLI
    # release can reword a sentence without renaming a field.
    _STOP=$(jq -r '.subtype // .stop_reason // empty' "$OUT.json" 2>/dev/null)
    case "$_STOP" in *budget*|*Budget*|*BUDGET*) _STOP=hit ;; *) _STOP="" ;; esac
    [ -z "$_STOP" ] && grep -qiE 'max.?budget[^.]{0,40}(exceed|exhaust|reach|limit|stop)' \
        "$OUT.err" "$OUT.json" 2>/dev/null && _STOP=hit
    # A session WE cut short is no evidence about the vendor's flag: it never
    # got to the end of the work, so "it outspent the cap and did not stop" is
    # a sentence about our own kill. Counting it would page about the wrong
    # thing and put a second line in ALERTS for one event.
    [ -n "${CTX_STOP:-}${TW_STOP:-}" ] && _STOP=hit
    if awk -v c="$USD" -v b="$_B" 'BEGIN{exit !(c+0 > b+0)}' 2>/dev/null && [ -z "$_STOP" ]; then
      # PER-STAGE flag: ~29 callers share this path, so a single daily flag let
      # the first lane to trip it silence every other lane for the day.
      _BF="$HARNESS/flags/alerted-agentcall-budget-inert-$STAGE-$(date -u +%Y%m%d)"
      [ -f "$_BF" ] || { mkdir -p "$HARNESS/flags"; touch "$_BF"
        HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[agent-call] BUDGET FLAG INERT: $STAGE/$PROJECT cost \$$USD against --max-budget-usd \$$_B and the envelope reported no budget stop. The per-call dollar bound is NOT enforced on this account — treat it as absent."; }
    fi
  fi
  # After the budget check above, which must see the gross envelope total.
  [ "$runner" = claude ] && ac_advisor_envelope_split
  ac_cost_row_write "$runner"
  [ "$runner" = claude ] && ac_advisor_row_write
  # After the cost row, so the ledger always has the attempt. A kill or a policy
  # stop is ours, not the vendor's, so it is no evidence either way (BH-3224).
  [ -z "${KILL_STOP:-}${BUDGET_STOP:-}${CTX_STOP:-}" ] && rff_note "$HARNESS" "$runner" "$RC" "$((T1-T0))" "$IN" "$OUTT"
  [ "$runner" = claude ] && [ -f "$OUT.ctxkill" ] && ctx_kill_after_kill
  echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ'),$(hostname),$PROJECT,$STAGE,$runner,$rmodel,$RC,$PROMPT_SHA,$PROMPT_BYTES" >> "$PROV"
  # Judge-provenance marker (2026-08-03): record which lane actually served this
  # stage (last attempt wins). Merge gates read it — a verdict authored by a
  # fallback/survival runner must never auto-merge.
  #
  # AND THE MODEL, FOR EVERY LANE (2026-09-16). This write used to live inside
  # the claude branch alone, so a stage that laddered down left the CLAUDE
  # attempt's model sitting beside the fallback's runner word — on project-5
  # #1624 a grok review carried a Claude model id in its .model file. Judge
  # provenance is now decided from the (runner, model) PAIR
  # (bin/lib/review-provenance.sh: the tier-3 lane runs the stage's own Claude
  # model through OpenRouter and that IS a Claude read), so the pair has to be
  # written by the same attempt, in the same place, under the same
  # last-attempt-wins rule as the runner word.
  echo "$runner" > "$OUT.runner"
  echo "$rmodel" > "$OUT.model"
  # Coordination spend (phase 1): this stage's dollars go onto the job row as a
  # DELTA (the worker sums; a read-modify-write from the box would lose one of
  # two stages finishing together), and a budget stop is recorded as a
  # stage_event so the class that cost $424 on TK-109 is queryable fleet-wide
  # instead of living in one box's ALERTS tail. Best-effort, gates nothing:
  # JOB_ID is exported by run-build.sh/run-triage.sh only when the claim
  # succeeded, and every helper is fail-open.
  # Phase 5: which lane actually served this attempt, and what the STAGE has
  # cost across all of its attempts. Both are recorded on the phase row when the
  # stage ends — the failover ladder can hand a stage to three vendors, and a
  # phase that named only the first would attribute the failure to the wrong one.
  PHASE_RUNNER="$runner"; PHASE_MODEL="$rmodel"
  # The advisor's dollars (BH-3491) are this stage's spend too, so the caps see them.
  local _SPEND="${USD:-}"
  [ -n "${ADV_USD:-}" ] && _SPEND=$(awk -v a="${_SPEND:-0}" -v b="$ADV_USD" 'BEGIN{printf "%.6f", a+b}' 2>/dev/null)
  # The top-level BUDGET STOP line runs after this function returns, where
  # USD (local here) is out of scope (BH-4609).
  LAST_ATTEMPT_USD="${_SPEND:-}"
  [ -n "$_SPEND" ] && PHASE_USD=$(awk -v a="${PHASE_USD:-0}" -v b="$_SPEND" 'BEGIN{printf "%.6f", a+b}' 2>/dev/null)
  if [ -n "${JOB_ID:-}" ] && command -v job_update >/dev/null 2>&1; then
    command -v job_heartbeat >/dev/null 2>&1 && job_heartbeat "$JOB_ID" "$STAGE/$runner done" >/dev/null 2>&1
    [ -n "$_SPEND" ] && job_update "$JOB_ID" "stage=$STAGE" "spend_delta=$_SPEND"
    [ -n "${BUDGET_STOP:-}" ] && job_event "$JOB_ID" "$STAGE" BUDGET_STOP "$runner rc=$RC cost \$${USD:-?}"
    true
  fi
  # --- The conversation itself (2026-08-29) ------------------------------------
  # Every row in the jobs ledger is one headless agent session, and until now the
  # console could say what that session COST and what rc it died on while being
  # unable to say a single word about what it was doing. This pushes the
  # rendered, scrubbed transcript of THIS attempt so a reader can click the job
  # and read it.
  #
  # Here rather than in the phase-close trap because the trap runs once and $OUT
  # is overwritten by every attempt: by the time the trap fires, the session that
  # explains a failover has already been replaced by the one that succeeded.
  #
  # Fail-open to the point of being invisible: a separate process, stdout and
  # stderr discarded, `|| true` on the end, and the script itself exits 0 no
  # matter what. It cannot change RC and it cannot change what this function
  # returns. JOB_PHASE_ID is passed explicitly because job_phase_open sets it as
  # a plain shell variable in THIS process, not an exported one.
  if [ -n "${JOB_ID:-}" ] && [ -r "$HARNESS/bin/transcript-push.sh" ]; then
    JOB_PHASE_ID="${JOB_PHASE_ID:-}" \
      bash "$HARNESS/bin/transcript-push.sh" "$STAGE" "$runner" "$rmodel" "$OUT" "$ATTEMPT_N" \
      >/dev/null 2>&1 || true
  fi
}

# =============================================================================
# FAILURE CLASSES + SAME-VENDOR RECOVERY (2026-09-16)
# =============================================================================
# the operator: "if it's stuck for very little it falls back; we need recovery
# procedures. Falling all the way to Fireworks is bad but ok as the LAST
# resort." The ladder below used to read one thing off a failed attempt — the
# exit code — and answer every kind of failure the same way: change vendor. A
# 30-second network blip, an account that ran out of weekly quota, an expired
# login and an agent that genuinely could not do the job all bought the next
# rung down, which is how a stage with a healthy second Claude account ended up
# answering from an open model.
#
# So every failure is CLASSIFIED first, and the class picks the recovery:
#   transient        (timeout/kill, 5xx, overloaded, 429/rate limit, network)
#                    -> retry the SAME runner on the SAME account, doubling
#                       backoff, LADDER_SAME_RETRIES times. A timeout resumes
#                       the same session id when the CLI supports --resume.
#   account-exhausted (usage/weekly/session limit, out of credits, spend limit)
#   auth             (401/403, on hold, suspended, not logged in)
#                    -> cool THIS account down so account-pick.sh skips it for
#                       the window, then retry on the next account of the SAME
#                       vendor, until the vendor has no account left.
#   real-failure     -> no recovery: the vendor answered and the answer failed.
#                       Descend a rung (the claude lane's own fable->opus retry
#                       still happens inside run_attempt).
# Each classification writes one failovers.log line carrying the class, so the
# reason a stage descended is in the log rather than inferred from exit codes.
#
# The regexes are knobs, and deliberately narrow: they are the vendors' OWN
# error text. A failed agent run echoes back every file it read, and this repo's
# own sources talk about rate limits — a loose pattern cools an account down and
# re-buys a stage for a failure that had nothing to do with quota (the lesson
# already paid for in tests/account-routing-test.sh case 11).
LADDER_SAME_RETRIES="${LADDER_SAME_RETRIES:-2}"
LADDER_BACKOFF_SECS="${LADDER_BACKOFF_SECS:-60}"
# Non-numeric is the default, not an error: `[ x -ge y ]` on a garbage value is
# false, and a false retry bound is an unbounded loop that buys calls forever.
case "$LADDER_SAME_RETRIES" in ''|*[!0-9]*) LADDER_SAME_RETRIES=2 ;; esac
case "$LADDER_BACKOFF_SECS" in ''|*[!0-9]*) LADDER_BACKOFF_SECS=60 ;; esac
# ACCOUNT_EXHAUST_REGEX is the pre-existing knob and is ADDITIVE: it is OR'd
# with this lane's vocabulary rather than replacing it (BH-1090). One knob
# cannot mean two things on one box — the merge conductor already ORs it
# (mc_lane_account_fact), so a box that set it to WIDEN what counts as
# exhaustion was silently NARROWING the ladder's list to that one phrase.
# The DEFAULT gains the wordings the old one missed — "session limit" and
# "weekly limit" are what the CLI actually prints — and loses the 429/rate-limit
# strings, which are transient (a retry) rather than exhaustion (an account
# change); they moved to LADDER_TRANSIENT_REGEX below.
_LADDER_EXHAUST_BUILTIN="${LADDER_EXHAUST_REGEX:-usage credits|usage limit|session limit|weekly limit|out of credits|credit balance|spend limit|hit your [a-z0-9 -]*limit|quota exceeded|limit reached}"
LADDER_EXHAUST_REGEX="${ACCOUNT_EXHAUST_REGEX:-}${ACCOUNT_EXHAUST_REGEX:+|}${_LADDER_EXHAUST_BUILTIN}"
LADDER_TRANSIENT_REGEX="${LADDER_TRANSIENT_REGEX:-rate_limit_error|rate.?limit(ed)? (exceeded|reached|hit)|too many requests|\b429\b|\b529\b|overloaded|internal server error|bad gateway|service unavailable|gateway time|(http|status|code|error)[ :]*5[0-9][0-9]\b|temporarily unavailable|timed out|connection (reset|refused|closed)|socket hang up|network error|ECONNRESET|ETIMEDOUT|EAI_AGAIN}"
LADDER_AUTH_REGEX="${LADDER_AUTH_REGEX:-\b401\b|\b403\b|unauthorized|forbidden|authentication_error|invalid api key|invalid [a-z ]*token|on hold|suspended|not logged in|please (re-?)?login|setup-token}"
# CREDITS IS NOT AUTH, AND A 429 IS NOT EXHAUSTION (BH-642). An account that has
# run out of MONEY answers with a status and credit words — Anthropic's own
# "Credit balance is too low" (a 400 invalid_request_error), OpenRouter's
# "Insufficient credits" (402), and the ticket's 403. Read by regex alone, that
# text hit \b403\b in LADDER_AUTH_REGEX first and was logged as a credential
# problem; and a 429 whose body says "rate limit reached" hit `limit reached` in
# LADDER_EXHAUST_REGEX first and cooled an account down for six hours over a
# blip. So ladder_classify reads the vendor's STATUS TOKEN first (see
# ladder_http_status) and only consults this list for the credit statuses. It is
# a knob like every other regex here, and just as deliberately narrow.
#
# `key limit exceeded` is OpenRouter's 403 for a key past its own spend limit
# (2026-09-23 pool loop). Without it that 403 read as auth, so a dead floor was
# reported as a credential problem on every one of 398 deferred runs.
LADDER_CREDITS_REGEX="${LADDER_CREDITS_REGEX:-insufficient[ _](credits|quota|funds|balance)|out[ _]of[ _]credits|credit balance( is)? too low|credits? (exhausted|depleted)|billing_error|payment required|quota exceeded|key limit exceeded}"
LADDER_CLASSES=""       # every class this stage has seen, in order, deduped
# WHICH RUNNERS RAN OUT, AND WHEN THE ACCOUNT COMES BACK (2026-09-23 pool loop).
# LADDER_CLASSES says an account was exhausted somewhere on the ladder, not
# whose. The fly pool's hub reap cools the Claude account the machine leased
# from the stage verdict line alone, so the line has to say "claude ran out",
# not "someone did": an OpenRouter key at its limit is no reason to park a
# healthy Claude account. The reset is the CLI's own "resets <when>" text,
# parsed once where the text is (it is overwritten by the next rung).
LADDER_EXHAUSTED_RUNNERS=""; LADDER_RESETS_AT=""
# ...and the runners whose ACCOUNT failed (exhausted or de-authed), which is what
# openrouter_fallback_ok reads: "no claude account can serve" is exactly claude
# being on this list after ladder_recover spent every account it could rotate to.
LADDER_ACCOUNT_DEAD_RUNNERS=""
LADDER_CLASS=""; LADDER_CLASS_DETAIL=""; LADDER_LAST_SESSION=""; LADDER_RESUME_SID=""

# Does the installed claude CLI take --resume? Probed once, cached, and never
# fatal: a CLI without it starts a fresh session instead of resuming one.
_CLAUDE_RESUME_OK=""
claude_supports_resume() {
  if [ -z "$_CLAUDE_RESUME_OK" ]; then
    if claude --help 2>/dev/null | grep -q -- '--resume'; then _CLAUDE_RESUME_OK=1; else _CLAUDE_RESUME_OK=0; fi
  fi
  [ "$_CLAUDE_RESUME_OK" = 1 ]
}

# WHICH FILE CARRIES THE VENDOR'S OWN ERROR TEXT. On the codex-driven lanes a
# failed run's $OUT is the events stream plus stderr — i.e. every file the agent
# read — so classifying off it would read the agent's reading material as a
# vendor error. The CLI's own 429/usage text lands on stderr.
ladder_scan_file() {
  case "$1" in codex|openrouter|fireworks) printf '%s\n' "$OUT.err" ;; *) printf '%s\n' "$OUT" ;; esac
}

# ladder_http_status <file> — the first status the VENDOR itself named, or "".
# Anchored on the vendor's own prefixes ("API Error: 403", "HTTP 503",
# "status_code: 429", `"code":402`) so three digits sitting loose in a model's
# answer are not read as a wire status. Empty means "the vendor named no
# status", which is the honest answer for a CLI that just printed prose.
ladder_http_status() {
  grep -oiE '(API Error|HTTP|status(_code)?|"code")[": ]+[0-9]{3}\b' "$1" 2>/dev/null \
    | grep -oE '[0-9]{3}$' | head -1
}

# ladder_token [class] [detail] — the three names the ticket routes on, derived
# from the internal class. The internal names stay: ladder_recover branches on
# them and two suites grep them.
ladder_token() {
  local c="${1:-$LADDER_CLASS}" d="${2:-$LADDER_CLASS_DETAIL}"
  case "$c" in
    ok)                printf 'RUNNER_OK' ;;
    account-exhausted) printf 'RUNNER_EXHAUSTED' ;;
    transient)         if [ "$d" = rate_limited ]; then printf 'RUNNER_RATE_LIMITED'; else printf 'RUNNER_ERROR'; fi ;;
    *)                 printf 'RUNNER_ERROR' ;;
  esac
}

# ladder_resets_at <file> — the epoch the vendor said this account comes back,
# or nothing. Two shapes: the CLI's prose ("You've hit your weekly limit ·
# resets Sep 25, 5pm (UTC)", "resets 3am (America/Los_Angeles)") and the older
# "usage limit reached|<epoch>". A time with no date that has already passed
# today is tomorrow's; any other past or unparseable answer is nothing, and the
# caller falls back to its normal cooldown window.
ladder_resets_at() {
  local f="${1:-}" e txt tz when now
  [ -r "$f" ] || return 0
  e=$(grep -oE 'limit reached\|[0-9]{10}' "$f" 2>/dev/null | head -1 | grep -oE '[0-9]{10}$')
  if [ -z "$e" ]; then
    txt=$(grep -oiE 'resets (at )?[^"\\|]{1,60}' "$f" 2>/dev/null | head -1)
    [ -n "$txt" ] || return 0
    tz=$(printf '%s' "$txt" | sed -n 's/.*(\([A-Za-z0-9_/+-]*\)).*/\1/p')
    when=$(printf '%s' "$txt" | sed -E 's/^[Rr][Ee][Ss][Ee][Tt][Ss] ([Aa][Tt] )?//; s/\(.*//; s/,//g; s/[. ]+$//')
    [ -n "$when" ] || return 0
    e=$(TZ="${tz:-UTC}" date -d "$when" +%s 2>/dev/null) || return 0
    now=$(date -u +%s)
    if [ "$e" -le "$now" ]; then
      grep -qiE '[a-z]{3,} [0-9]|[0-9]{4}-[0-9]{2}' <<<"$when" && return 0
      e=$(( e + 86400 ))
    fi
  fi
  case "$e" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$e"
}

ladder_classify() { # ladder_classify <runner> ; sets LADDER_CLASS / LADDER_CLASS_DETAIL
  _ladder_classify "$@"
  case "$LADDER_CLASS" in
    account-exhausted|auth)
      case ",$LADDER_ACCOUNT_DEAD_RUNNERS," in
        *",$1,"*) : ;;
        *) LADDER_ACCOUNT_DEAD_RUNNERS="${LADDER_ACCOUNT_DEAD_RUNNERS:+$LADDER_ACCOUNT_DEAD_RUNNERS,}$1" ;;
      esac ;;
  esac
  if [ "$LADDER_CLASS" = account-exhausted ]; then
    case ",$LADDER_EXHAUSTED_RUNNERS," in
      *",$1,"*) : ;;
      *) LADDER_EXHAUSTED_RUNNERS="${LADDER_EXHAUSTED_RUNNERS:+$LADDER_EXHAUSTED_RUNNERS,}$1" ;;
    esac
    local r; r=$(ladder_resets_at "$(ladder_scan_file "$1")")
    [ -n "$r" ] && LADDER_RESETS_AT="$r"
  fi
  return 0
}

_ladder_classify() {
  local runner="$1" f status; f=$(ladder_scan_file "$runner")
  LADDER_CLASS=""; LADDER_CLASS_DETAIL=""
  if [ "$RC" -eq 0 ]; then LADDER_CLASS=ok; return 0; fi
  # THE GATE REFUSED THIS RUNG (BH-1141). Nothing about the account or the
  # vendor is wrong and nothing was called, so a same-vendor retry or an account
  # cooldown would both be answers to a question nobody asked: descend, and let
  # the next rung meet the same gate. Read off the variable rather than off the
  # rc alone: rc 2 is the BH-1019 refusal (which exits before ever reaching the
  # ladder) and rc 74 could arrive from a box mid-sync, so the variable is the
  # fact and the rc is only a hint.
  if [ -n "${GATE_REFUSED:-}" ]; then
    LADDER_CLASS=real-failure; LADDER_CLASS_DETAIL=gate_refused; return 0
  fi
  # Structural cases first — these are OUR exit codes, not the vendor's text.
  case "$RC" in
    76) LADDER_CLASS=account-exhausted; LADDER_CLASS_DETAIL=no_headroom; return 0 ;;
    75|78) LADDER_CLASS=real-failure; LADDER_CLASS_DETAIL=refused; return 0 ;;
    # An argv-only lane refused a prompt it cannot carry (agent_argv_refuse).
    # Nothing about the account or the vendor is wrong, so retrying either is
    # pure waste: descend to a lane that takes the prompt on stdin.
    # ...and the SAME code with a cliff-route marker on $OUT means we chose not
    # to call. Not a failure of anything: no retry, no cooldown, descend.
    79) if cliff_routed_rc; then LADDER_CLASS=routed; LADDER_CLASS_DETAIL=cliff
        else LADDER_CLASS=real-failure; LADDER_CLASS_DETAIL=prompt_too_large; fi
        return 0 ;;
  esac
  if [ -n "${BUDGET_STOP:-}" ]; then LADDER_CLASS=real-failure; LADDER_CLASS_DETAIL=budget_stop; return 0; fi
  if [ -n "${KILL_STOP:-}" ]; then LADDER_CLASS=transient; LADDER_CLASS_DETAIL=killed; return 0; fi
  # "Stuck for very little": the window elapsed and the vendor never answered.
  # 124 is GNU timeout's own code; 137/143 reach here only when the FULL window
  # ran out, because a kill well inside it already set KILL_STOP above.
  case "$RC" in
    124|137|143) LADDER_CLASS=transient; LADDER_CLASS_DETAIL=timeout; return 0 ;;
  esac
  # STATUS BEFORE BODY. A status the vendor named itself decides the two classes
  # the regex ladder used to get backwards; everything else falls through to the
  # unchanged exhaust -> auth -> transient order below.
  status=$(ladder_http_status "$f")
  case "$status" in
    429) LADDER_CLASS=transient; LADDER_CLASS_DETAIL=rate_limited; return 0 ;;
    400|402|403)
      # Anthropic prices a low credit balance as a 400 invalid_request_error,
      # OpenRouter as a 402, and the ticket names 403 — so the status set is
      # wide and the WORDS are what make it exhaustion. A 403 with no credit
      # words is still auth, which is what it has always been.
      if grep -qiE "$LADDER_CREDITS_REGEX" "$f" 2>/dev/null; then
        LADDER_CLASS=account-exhausted; LADDER_CLASS_DETAIL=credits; return 0; fi ;;
  esac
  if grep -qiE "$LADDER_EXHAUST_REGEX" "$f" 2>/dev/null; then
    LADDER_CLASS=account-exhausted; LADDER_CLASS_DETAIL=quota; return 0; fi
  if grep -qiE "$LADDER_AUTH_REGEX" "$f" 2>/dev/null; then
    LADDER_CLASS=auth; LADDER_CLASS_DETAIL=credential; return 0; fi
  if grep -qiE "$LADDER_TRANSIENT_REGEX" "$f" 2>/dev/null; then
    LADDER_CLASS=transient; LADDER_CLASS_DETAIL=vendor; return 0; fi
  LADDER_CLASS=real-failure; LADDER_CLASS_DETAIL=agent
  return 0
}

ladder_note() { # ladder_note <runner> <what the ladder is doing about it>
  LADDER_KINDS="${LADDER_KINDS:+$LADDER_KINDS }$LADDER_CLASS:${LADDER_CLASS_DETAIL:-}"
  case " $LADDER_CLASSES " in
    *" $LADDER_CLASS "*) : ;;
    *) LADDER_CLASSES="${LADDER_CLASSES:+$LADDER_CLASSES }$LADDER_CLASS" ;;
  esac
  echo "$(STAMP) [$PROJECT] $STAGE $1: class=$LADDER_CLASS${LADDER_CLASS_DETAIL:+($LADDER_CLASS_DETAIL)} token=$(ladder_token) rc=$RC acct=${ACCT_NAME:-default} — $2" \
    >> "$HARNESS/logs/failovers.log"
}

# ladder_exit_token — the token for the STAGE, not for its last rung. A ladder
# that burned because every Claude account was out of credits and then found no
# other vendor ends on a real-failure, and reporting that would hide the thing
# that actually happened — which is exactly how two waves were lost silently.
ladder_exit_token() {
  case " $LADDER_CLASSES " in *" account-exhausted "*) printf 'RUNNER_EXHAUSTED'; return 0 ;; esac
  ladder_token
}

# The rungs BELOW the OpenRouter anthropic/ slug stay allowed — they are the one
# thing that still answers when Anthropic itself is the outage — but a stage
# that ends up there has stopped being the thing we asked for, so it is never
# silent: one line, naming the rung and the classes that got us here.
ladder_last_resort() { # ladder_last_resort <runner/model label>
  mkdir -p "$(dirname "$ALERTS")" 2>/dev/null
  echo "$(STAMP) [$PROJECT] LAST RESORT: $STAGE $PROJECT fell to $1 after ${LADDER_CLASSES:-unclassified}" >> "$ALERTS"
}

# ac_cooldown_write <file> <epoch> — the later cooldown stamp wins (BH-1853):
# a write no later than the stamp already there is skipped, file and mtime
# untouched, so a routine stamp never shortens a reset-dated cooldown. A
# non-numeric old stamp counts as 0. This script execs the picker rather than
# sourcing it, so it cannot reuse the picker's own writer.
ac_cooldown_write() {
  local old
  old=$(cat "$1" 2>/dev/null); case "$old" in ''|*[!0-9]*) old=0 ;; esac
  [ "$2" -gt "$old" ] || return 0
  printf '%s\n' "$2" > "$1"
}

# RECOVERY ON THE SAME VENDOR, BEFORE ANY VENDOR CHANGE. Returns when the stage
# succeeded or when nothing on this vendor is left to try; the caller then walks
# its rungs exactly as before.
ladder_recover() { # ladder_recover <runner>
  local runner="$1" tries=0 backoff="$LADDER_BACKOFF_SECS" tried=" " acct _acnow _acwin
  while [ "$RC" -ne 0 ]; do
    ladder_classify "$runner"
    # A budget stop is policy and a kill is the OS: both are terminal for the
    # ladder (the blocks below own the alerting), so recovery never re-buys one.
    if [ -n "${BUDGET_STOP:-}" ]; then ladder_note "$runner" "budget stop is policy — no retry, no vendor change"; return 0; fi
    if [ -n "${KILL_STOP:-}" ]; then ladder_note "$runner" "external kill — the kill lane owns this, no vendor change"; return 0; fi
    case "$LADDER_CLASS" in
      transient)
        if [ "$tries" -ge "$LADDER_SAME_RETRIES" ]; then
          ladder_note "$runner" "$tries same-runner retries spent — descending a rung"; return 0
        fi
        tries=$(( tries + 1 ))
        ladder_note "$runner" "retry $tries/$LADDER_SAME_RETRIES on the SAME runner+account after ${backoff}s"
        [ "$backoff" -gt 0 ] && sleep "$backoff"
        # A timeout resumes the session it got stuck in; every other transient
        # starts clean, because there is no half-finished session to pick up.
        [ "$LADDER_CLASS_DETAIL" = timeout ] && LADDER_RESUME_SID="${LADDER_LAST_SESSION:-}"
        run_attempt "$runner"
        LADDER_RESUME_SID=""
        backoff=$(( backoff * 2 ))
        ;;
      account-exhausted|auth)
        # rc 76 is the picker itself saying no account of this vendor has
        # headroom left — the vendor is out, so the rung is.
        # A PINNED OWN ACCOUNT NEVER ROTATES (BH-1657). Its refusal is the
        # project's account saying no; the next claude account would be a shared
        # project-6/max one, which is exactly what the pin forbids. No cooldown
        # stamp either: the shared accounts' state is not this account's.
        if [ "${ACCT_PINNED:-0}" = 1 ]; then
          if [ "$RC" -eq 76 ]; then
            ladder_note "$runner" "pinned account $ACCT_NAME has no token on this box, no fallback to shared claude accounts, descending a rung"
          else
            ladder_note "$runner" "pinned account $ACCT_NAME refused ($LADDER_CLASS), no fallback to shared claude accounts, descending a rung"
          fi
          return 0
        fi
        if [ "$RC" -eq 76 ]; then ladder_note "$runner" "no $runner account left with headroom — descending a rung"; return 0; fi
        if [ "${ACCOUNT_ROUTING:-0}" != 1 ] || [ -z "${ACCT_NAME:-}" ]; then
          ladder_note "$runner" "no account routing on this box, so no account to rotate to — descending a rung"; return 0
        fi
        acct="$ACCT_NAME"
        # Belt to the picker's braces: if the cooldown did not take, the next
        # pick returns the same account and this would loop forever.
        case "$tried" in *" $acct "*) ladder_note "$runner" "the picker returned $acct again — descending a rung"; return 0 ;; esac
        tried="$tried$acct "
        # Keyed by VENDOR and account: `default` is one name claude and codex
        # both answer to, and an unscoped stamp took the healthy vendor down
        # with the exhausted one (2026-09-18). $runner IS the vendor here — the
        # ACCOUNT_ROUTING/ACCT_NAME gate above returns for every other lane.
        # >>> overage cooldown (BH-1456)
        # AN OVERAGE ACCOUNT GETS MINUTES, NOT SIX HOURS. The full window is the
        # right answer for "this subscription is spent until it resets". It is
        # the wrong answer for an account that is billing extra usage with its
        # spend limit intact: that account CAN still pay, so whatever it just
        # refused us for was probably transient, and parking it for six hours
        # parks the only account on this box that has budget left. The picker
        # answers the billing question (`--overage-ok`, rc only) because this
        # script EXECS the picker rather than sourcing it.
        #
        # An `auth` class never takes the short path: a de-authed account is not
        # a transient refusal, and neither is a spend limit that was reached —
        # account_overage_ok says no to both.
        if [ "$LADDER_CLASS" = account-exhausted ] \
           && "$HARNESS/bin/account-pick.sh" --overage-ok "$acct" >/dev/null 2>&1; then
          OVC="${ACCOUNT_OVERAGE_COOLDOWN_SECS:-900}"
          # The excerpt is the POINT of this note: an overage account refusing us
          # is the interesting failure on this box, and "cooled down" without the
          # runner's own words is a line nobody can act on. Tail-bounded and
          # newline-flattened so one note stays one line.
          ladder_note "$runner" "WARN overage account $acct refused: $(tail -c 300 "$(ladder_scan_file "$runner")" 2>/dev/null | tr '\n' ' ') — short cooldown ${OVC}s"
          # Backdated stamp, so account_cooling / cooldowns_json / the quota-poll
          # sweep all keep their single window (see account_cooldown_stamp_short).
          WIN="${ACCOUNT_COOLDOWN_SECS:-${MODEL_COOLDOWN_SECS:-21600}}"
          case "$OVC" in ''|*[!0-9]*) OVC="$WIN" ;; esac
          case "$WIN" in ''|*[!0-9]*) WIN=21600 ;; esac
          if [ "$OVC" -ge "$WIN" ]; then BACK=0; else BACK=$(( WIN - OVC )); fi
          _acnow=$(date -u +%s)
          mkdir -p "$HARNESS/state/quota/cooldown/$runner" 2>/dev/null \
            && ac_cooldown_write "$HARNESS/state/quota/cooldown/$runner/$acct" "$(( _acnow - BACK ))"
          # The fleet row carries the same effective window the backdated stamp
          # encodes; the contract keeps the later until, so it never shortens a
          # full-window row another box put (BH-2356).
          fcd_put account "$runner" "$acct" "$(( _acnow - BACK + WIN ))" "$_acnow" "$LADDER_CLASS overage"
          ladder_note "$runner" "account $runner/$acct cooled down ${OVC}s — retrying on the next $runner account with headroom"
        else
        _acnow=$(date +%s)
        mkdir -p "$HARNESS/state/quota/cooldown/$runner" 2>/dev/null && ac_cooldown_write "$HARNESS/state/quota/cooldown/$runner/$acct" "$_acnow"
        _acwin="${ACCOUNT_COOLDOWN_SECS:-${MODEL_COOLDOWN_SECS:-21600}}"; case "$_acwin" in ''|*[!0-9]*) _acwin=21600 ;; esac
        fcd_put account "$runner" "$acct" "$(( _acnow + _acwin ))" "$_acnow" "$LADDER_CLASS"
        ladder_note "$runner" "account $runner/$acct cooled down $(( ${ACCOUNT_COOLDOWN_SECS:-${MODEL_COOLDOWN_SECS:-21600}} / 3600 ))h — retrying on the next $runner account with headroom"
        fi
        # <<< overage cooldown
        run_attempt "$runner"
        ;;
      routed)
        ladder_note "$runner" "cliff-routed — no retry, descending a rung"; return 0 ;;
      *)
        # THE GATE, NOT THE VENDOR (BH-1141 round 2, N3). The default note says
        # "the vendor answered and the answer failed", which is false for a rung
        # the lane's own control refused: no vendor was asked anything. The
        # ladder's decisions are read off this log, and a false line in it is
        # worse than no line.
        if [ "${LADDER_CLASS_DETAIL:-}" = gate_refused ]; then
          ladder_note "$runner" "the lane's own control refused this rung (${LLM_GATE_REASON:-runner-not-allowed}) — nothing was called, no same-vendor retry, descending a rung"; return 0
        fi
        ladder_note "$runner" "the vendor answered and the answer failed — no same-vendor retry, descending a rung"; return 0 ;;
    esac
  done
  return 0
}

# >>> llm-gate-precall
# THE WHOLE-CALL GATE (BH-1141 phase 2): may this LANE make a model call at all,
# right now. Placed here on purpose — after the runner is resolved so the row
# can name the rung that would have run, and BEFORE the phase row is opened and
# before any run_attempt, so a refused call opens no phase, spawns no child,
# buys nothing and leaves the ladder untouched.
#
# Two ceilings, both read from D1 `cost_rows` and never from this box's own
# logs/cost.csv: the LANE's dollars for the UTC day, and this (lane, project)'s.
# Unset is unlimited, so a fleet with no settings rows behaves byte-for-byte as
# it did before this landed, and an unreachable worker ALLOWS the call and says
# so once an hour in logs/lane-gate.log.
# A fly-pool call inside a build whose launch gate passed (its dir holds
# ADMITTED) and whose ticket has not ended (no RESULT) is mid-ticket: the day
# dollar cap does not stop it (BH-5526). The launch gate checked only the
# fly-pool lane's cap, so every other lane (postmerge-qa, prebuild-repro, ...)
# checks its own cap here. replan-check runs as fly-pool on an ENDED build, so
# the RESULT test is what refuses it. A plain shell var, not exported, so no
# child session inherits it.
unset LLM_GATE_IN_TICKET; LLM_GATE_IN_TICKET=0
if [ "${AGENT_CALL_LANE:-}" = fly-pool ]; then
  case "$OUT" in
    */builds/*/*)
      if command -v bs_admitted >/dev/null 2>&1; then bs_admitted "$(dirname "$OUT")" && LLM_GATE_IN_TICKET=1
      else [ -f "$(dirname "$OUT")/ADMITTED" ] && [ ! -e "$(dirname "$OUT")/RESULT" ] && LLM_GATE_IN_TICKET=1; fi ;;
  esac
fi
if ! llm_gate_precall "$STAGE" "$PROJECT"; then
  # The marker goes to BOTH files, exactly as the per-rung refusal writes it: a
  # caller that reads $OUT.err on a nonzero rc must read the refusal and not
  # whatever an earlier call left in that file.
  printf 'AGENT_CALL_REFUSED llm-gate %s\n' "${LLM_GATE_REASON:-gated}" | tee "$OUT.err" > "$OUT" 2>/dev/null
  echo "$(STAMP) [$PROJECT] $STAGE GATE REFUSED before the call: ${LLM_GATE_REASON:-gated} — nothing was called and nothing was billed. Change it with bin/harness-ctl.sh set <lane> LLM_USD_CAP_DAY <n> (or LLM_LANE_ENABLED 1), or turn the gate off with LLM_GATE_DISABLE=1. NOTE: the hub triage lanes carry a SECOND, older daily dollar cap in catalog/lane-caps.conf (BH-1039, read from this box's own logs/cost.csv and checked by the lane script before it even fetches its queue) — the LOWER of the two is what an operator actually gets, so raising this knob alone may change nothing." >> "$HARNESS/logs/failovers.log"
  llm_gate_refused_row "$STAGE" "$PROJECT" "$RUNNER" "$MODEL" 74 "${LLM_GATE_REASON:-gated}"
  # rc 74, NOT 2 (round-1 review, I3). rc 2 is also a vendor CLI's own generic
  # error, so a caller cannot tell a refusal from a death by it —
  # bin/review-autopilot.sh read rc 2 as "It DIED: billed", charged its daily
  # cap and wrote a terminal key, which is #1141's own "refusals
  # indistinguishable from billed failures" reappearing inside the fix for it.
  # 74 joins 75..79, the family every caller already reads as before-billing.
  exit 74
fi
# <<< llm-gate-precall

# A RESTRICTED CALL WHOSE LANE IS NOT THERE IS REFUSED, NOT PROMOTED (BH-1019).
# The promotion below is the right default — something must answer — and it is
# exactly what a caller with a provenance gate must not get: `claude` missing
# would hand a review to openrouter, and the gate would bin it after paying for
# it. Refused here, ahead of the phase row and every attempt: rc 2, the marker
# as the first line of $OUT (which is what a caller's lane-failure check reads),
# no cost row, no provenance marker, nothing billed.
# A COOLING PRIMARY IS NAMED AS COOLING (BH-3224): it is installed, it just
# failed at once with no usage, so "not installed/authed" would be false here.
_RFF_COOL=""
rff_enabled "$RUNNER" && rff_live "$HARNESS" "$RUNNER" && _RFF_COOL=1
if [ -n "$AGENT_CALL_RUNNERS" ] && ! runner_ready "$RUNNER"; then
  if [ -n "$_RFF_COOL" ]; then
    printf 'AGENT_CALL_REFUSED runners-restricted %s is cooling down after instant failures until %s and this caller allows only: %s\n' \
      "$RUNNER" "$(rff_until "$HARNESS" "$RUNNER")" "$AGENT_CALL_RUNNERS" > "$OUT" 2>/dev/null
    echo "$(STAMP) [$PROJECT] $STAGE refused: the caller restricted the lanes to '$AGENT_CALL_RUNNERS' and $RUNNER is cooling down after instant failures ($(rff_detail "$HARNESS" "$RUNNER"), no usage) until $(rff_until "$HARNESS" "$RUNNER") — nothing was called and nothing was billed" >> "$HARNESS/logs/failovers.log"
    exit 2
  fi
  printf 'AGENT_CALL_REFUSED runners-restricted %s is not available and this caller allows only: %s\n' \
    "$RUNNER" "$AGENT_CALL_RUNNERS" > "$OUT" 2>/dev/null
  echo "$(STAMP) [$PROJECT] $STAGE refused: the caller restricted the lanes to '$AGENT_CALL_RUNNERS' and $RUNNER is not installed/authed on this box — nothing was called and nothing was billed" >> "$HARNESS/logs/failovers.log"
  exit 2
fi

# A cooling primary -> its fallback (or claude), one failovers.log line and no
# ALERTS line: the ladder is doing what it was told, nothing is broken here.
if [ -n "$_RFF_COOL" ]; then
  SUB="${FALLBACK:-claude}"
  echo "$(STAMP) [$PROJECT] $STAGE $RUNNER skipped: failed instantly ($(rff_detail "$HARNESS" "$RUNNER"), no usage) — cooling down until $(rff_until "$HARNESS" "$RUNNER"), using $SUB" >> "$HARNESS/logs/failovers.log"
  RUNNER="$SUB"; FALLBACK=""
fi

# Primary not usable at all -> promote fallback (or claude) to primary.
if ! runner_ready "$RUNNER"; then
  SUB="${FALLBACK:-claude}"
  FLAG="$HARNESS/flags/alerted-runner-$RUNNER-$(date -u +%Y%m%d)"
  [ -f "$FLAG" ] || { echo "$(STAMP) [$PROJECT] runner '$RUNNER' for $STAGE not installed/authed — using $SUB" >> "$ALERTS"; touch "$FLAG"; }
  RUNNER="$SUB"; FALLBACK=""
fi

# >>> call-guard (K3)
# cg_nothing_billed <rc> — rc 0 when a FAILED call cost nothing: every runner
# that ran is a SUBSCRIPTION lane, and every failure the ladder classified was
# the account (quota / credits / no headroom), its credential, or a named 429
# rate limit. Such a call settles `unbilled`, so a subscription outage can never
# use up a head's slots (the #1621 shape: a 429 twice, then rc 74 on a head
# nobody read). A timeout, a vendor error and a real failure still count.
cg_nothing_billed() {
  local rc="${1:-1}" r k
  [ "$rc" != 0 ] && [ -n "${CG_RAN_RUNNERS:-}" ] || return 1
  for r in $CG_RAN_RUNNERS; do
    command -v call_guard_metered >/dev/null 2>&1 && call_guard_metered "$r" && return 1
  done
  ladder_classify "${PHASE_RUNNER:-$RUNNER}" >/dev/null 2>&1
  for k in ${LADDER_KINDS:-} "$LADDER_CLASS:${LADDER_CLASS_DETAIL:-}"; do
    case "$k" in
      account-exhausted:*|auth:*|transient:rate_limited) : ;;
      *) return 1 ;;
    esac
  done
  return 0
}
cg_finish() { # cg_finish <rc>
  local nb=""
  [ "${CG_STATE:-}" = allowed ] || return 0
  cg_nothing_billed "${1:-1}" && nb=1
  call_guard_finish "${1:-1}" "${ANY_RAN:-}" "$OUT" "$nb"
}
# NEVER PAY TWICE FOR THE SAME WORK. The last moment before money can move: the
# prompt ledger has had its chance to replay (a replay is free and never
# reaches here), the lane's own gate has had its say, and the primary runner is
# final. bin/lib/call-guard.sh claims a slot for (project, guard stage,
# fingerprint) on the harness-jobs counter; at the stage's ceiling the call is
# REFUSED rc 74 — this file's "the lane's own gate refused it, nothing was
# called and nothing was billed", which every caller already defers on. No
# phase row, no account pick, no cost row but the zero-cost refused one.
# Metered runners fail CLOSED on an unreadable counter; subscription runners
# fail open (call_guard_rung_ok carries the metered half down the ladder).
#
# THE REPEAT-KILL STOP (BH-2538) runs first, so a refused call never claims a
# guard slot: this work was context-killed CONTEXT_KILL_REPEAT_MAX times in the
# window, a person has been told, and buying the same session again is waste.
# >>> budget-stop precall (BH-4488, BH-4489)
# THE BUDGET STOP comes next, for every stage and every scope (bin/lib/budget-
# stop.sh's header has the table). A build dir holding BUDGET_STOP is over its
# hard cap and stays stopped — honoured inline, so a box without the lib still
# refuses. Otherwise bs_gate evaluates the build-stage, stage-day and
# project-day caps and the tightest one decides:
#   rc 1  build-stage: the marker is tripped (terminal; CC() ends the build);
#   rc 2  stage-day / project-day: refused for the day, nothing terminal;
#   rc 3  a day cap or its spend is unreadable inside a build: refused (fail
#         closed); CC() defers the build. Outside a build the lib fails open.
# A build dir that holds ADMITTED and no RESULT (its launch gate passed and the
# ticket has not ended, BH-5526) never gets rc 2 or 3 for a call of the build's
# own lane: the day scopes allow it and note the overrun once (bs_admitted).
# Before the call, always: nothing here runs during a call or signals one.
BS_LINE=""; BS_REFUSE=""; _BSRC=0
case "$OUT" in
  */builds/*/*)
    if [ -f "$(dirname "$OUT")/BUDGET_STOP" ]; then
      BS_LINE=$(head -1 "$(dirname "$OUT")/BUDGET_STOP" 2>/dev/null | tr -d '\r')
      [ -n "$BS_LINE" ] || BS_LINE="budget_stop $STAGE marker-present"
      _BSRC=1
    fi ;;
esac
[ "$_BSRC" = 0 ] && { bs_gate "$PROJECT" "$STAGE" "$OUT"; _BSRC=$?; }
case "$_BSRC" in
  1)
    printf 'AGENT_CALL_REFUSED budget-stop %s\n' "$(printf '%s' "$BS_LINE" | cut -c1-300)" \
      | tee "$OUT.err" > "$OUT" 2>/dev/null
    echo "$(STAMP) [$PROJECT] $STAGE BUDGET-STOP REFUSED before the call ($BS_LINE; $(dirname "$OUT")/BUDGET_STOP) — nothing called, nothing billed. Caps: settings rows budget.stage.<stage>.max_calls / max_usd / max_tokens." >> "$HARNESS/logs/failovers.log"
    ac_refused_row "budget-stop:$(printf '%s' "$BS_LINE" | awk '{print $3}')"
    exit 74 ;;
  2|3)
    printf 'AGENT_CALL_REFUSED %s\n' "$(printf '%s' "$BS_REFUSE" | cut -c1-400)" | tee "$OUT.err" > "$OUT" 2>/dev/null
    echo "$(STAMP) [$PROJECT] $STAGE BUDGET REFUSED before the call ($BS_REFUSE) — nothing called, nothing billed. Caps: settings rows budget.stage.<stage>.day_usd / day_calls, budget.project.<project>.day_usd; they reset at 00:00Z." >> "$HARNESS/logs/failovers.log"
    ac_refused_row "${BS_REFUSE%% *}"
    exit 74 ;;
esac
# <<< budget-stop precall
ctx_kill_work
if ctx_kill_repeat_refuse; then
  printf 'AGENT_CALL_REFUSED context-kill repeat %s kills=%s tk=%s fp=%s\n' "$STAGE" "$CK_KILLS" "${CK_TK:--}" "${CK_FP:--}" \
    | tee "$OUT.err" > "$OUT" 2>/dev/null
  echo "$(STAMP) [$PROJECT] $STAGE CONTEXT-KILL REPEAT REFUSED before the call (tk=${CK_TK:--} fp=${CK_FP:--}, $CK_KILLS kills in the window) — nothing called, nothing billed; the CONTEXT KILL REPEATED alert went to a person. Knob: lib.agent-call.context_kill_repeat_max (0 = off)." >> "$HARNESS/logs/failovers.log"
  ac_refused_row context-kill-repeat
  exit 74
fi
if ! call_guard_precall "$STAGE" "$PROJECT" "$RUNNER" "$PROMPT_SHA"; then
  case "$CG_REASON" in
    call-guard:repeat)
      printf 'AGENT_CALL_REFUSED call-guard repeat %s paid=%s/%s fp=%s\n' "$CG_STAGE" "${CG_COUNT:-?}" "$CG_MAX" "$CG_FP" ;;
    *)
      printf 'AGENT_CALL_REFUSED call-guard counter-unreadable metered %s\n' "$RUNNER" ;;
  esac | tee "$OUT.err" > "$OUT" 2>/dev/null
  echo "$(STAMP) [$PROJECT] $STAGE CALL-GUARD REFUSED before the call ($CG_REASON, guard stage $CG_STAGE, fp $CG_FP) — nothing was called and nothing was billed. logs/call-guard.log has the detail; knobs are lib.call-guard.* (CALL_GUARD=0 turns it off)." >> "$HARNESS/logs/failovers.log"
  ac_refused_row "$CG_REASON"
  exit 74
fi
# THE GUARD'S PER-CALL ENV STOPS HERE (K3 review, B1). AGENT_CALL_FP,
# _GUARD_STAGE, _TICKET and _GUARD_FORCE describe THIS call to THIS script; the
# guard has captured them (CG_STAGE / CG_FP) above. Left exported, every runner
# branch below would hand them to the vendor session, and a triage session that
# setsid-launches bin/run-build.sh would pass the shard's key to plan and
# execute, which would then share the triage shard's slots and be refused.
# ...but THIS call's own cost row still names them (BH-2537). ROW_TICKET/_PR/_FP
# are plain shell vars, never exported, so the row and the in-ladder refusals
# carry the ticket, the PR and the guard's fp while no vendor session sees them.
# ROW_FP is the guard's fp exactly as call_guard_fp computes it, not hashed, and
# it is written even when the guard is off for this stage (CG_FP then empty).
ROW_TICKET="${AGENT_CALL_TICKET:-}"; ROW_PR="${AGENT_CALL_PR:-}"; ROW_FP="${CG_FP:-}"
[ -z "$ROW_FP" ] && command -v call_guard_fp >/dev/null 2>&1 && ROW_FP=$(call_guard_fp "$PROMPT_SHA")
unset AGENT_CALL_FP AGENT_CALL_GUARD_STAGE AGENT_CALL_TICKET AGENT_CALL_GUARD_FORCE AGENT_CALL_PR
# <<< call-guard

# --- Phase row for this stage (phase 5, docs/DB-COORDINATION-SPEC.md) ---------
# ONE row per stage, opened here and closed on exit with the stage's REAL rc and
# its whole bill. It answers the question a failed job could not: which phase
# died, on which runner, having spent what.
#
# It is a CHILD of the claim run-build.sh/run-triage.sh already opened (JOB_ID is
# exported by them), never a claim of its own — this call cannot 409, cannot
# block, and cannot make a stage wait for permission it was already granted. No
# JOB_ID (an unclaimed lane, or a worker that failed open) means no phase and no
# behaviour change whatsoever.
#
# The close runs from an EXIT trap rather than the last line: this script has
# four survival lanes and a `set -u` slip anywhere in them would otherwise leave
# a phase reading `running` forever, which is precisely the silence the row
# exists to end. A trap's return value does not alter the exit status, so the
# stage's rc still reaches the caller untouched.
PHASE_USD=0; PHASE_RUNNER=""; PHASE_MODEL=""
# Account routing state for the run below (see the hook in run_attempt). Empty
# = not routed, and `eval ""` is a no-op everywhere it is consumed.
ACCT_NAME=""; ACCT_EXPORTS=""; ACCT_PINNED=0; ACCT_PICK_LABEL=""
# The cliff-route decision for this RUN, not this attempt: it is set by the grok
# attempt that was skipped and read by the row the rung BELOW it writes, so it
# deliberately survives across attempts (run_attempt resets ACCT_NAME; this must
# not be reset with it).
CLIFF_ROUTE_NOTE=""
_phase_finish() {
  local rc=$? note
  [ -n "${JOB_PHASE_ID:-}" ] || return 0
  # The row's runner/model columns are what this stage was ASKED to run; the
  # note is what actually served it, which the failover ladder can change twice.
  # Keeping both means a phase can say "asked for the stage model, answered by
  # the survival lane" instead of quietly rewriting history to the winner.
  note="served by ${PHASE_RUNNER:-$RUNNER}${PHASE_MODEL:+/$PHASE_MODEL}"
  # The stop MARKERS ride on the phase, because "failed" and "stopped on its own
  # budget bound" are different events with different responses, and telling
  # them apart after the fact used to mean grepping one box's ALERTS log.
  [ -n "${KILL_STOP:-}" ]   && note="KILL_STOP $note"
  [ -n "${BUDGET_STOP:-}" ] && note="BUDGET_STOP $note"
  # --- Phase 7: record the stage's declared artifact BEFORE closing the phase --
  # The caller (bin/run-build.sh) declares what this stage is supposed to leave
  # behind; this script does not know what a plan or a verdict IS, and does not
  # need to — it records the file if the file actually materialized and is not
  # empty, and records nothing at all otherwise. That "nothing at all" is the
  # point: an outcome contract on this phase then refuses the `done` close, and
  # the row says the stage produced no artifact instead of claiming success.
  # Recorded BEFORE the close because the close is what the contract is checked
  # on; after it, the row would already read done.
  if [ -n "${AGENT_CALL_ARTIFACT_KIND:-}" ] && [ -s "${AGENT_CALL_ARTIFACT_FILE:-/nonexistent}" ] \
     && command -v job_artifact_put >/dev/null 2>&1; then
    job_artifact_put "$AGENT_CALL_ARTIFACT_KIND" "$AGENT_CALL_ARTIFACT_FILE" \
      "$(jq -nc --arg s "$STAGE" --argjson b "$(stat -c %s "$AGENT_CALL_ARTIFACT_FILE" 2>/dev/null || echo 0)" \
          '{stage:$s,bytes:$b}' 2>/dev/null)" >/dev/null 2>&1 || true
  fi
  job_phase_close "$rc" "${PHASE_USD:-}" "$note" >/dev/null 2>&1 || true
  return 0
}
if [ -n "${JOB_ID:-}" ] && command -v job_phase_open >/dev/null 2>&1; then
  job_phase_open "$STAGE" "$RUNNER" "$MODEL" >/dev/null 2>&1 || true
  # BH-5839: this trap replaces the steer take's, so it settles the taken notes
  # too, with the same rc (the `( exit )` hands it to _phase_finish's $?).
  [ -n "${JOB_PHASE_ID:-}" ] && trap '_ac_steer_rc=$?; ( exit "$_ac_steer_rc" ); _phase_finish
    [ -z "${STEER_TAKEN_IDS:-}" ] || steer_settle "$JOB_ID" "$_ac_steer_rc"' EXIT
fi

run_attempt "$RUNNER"

# RECOVERY BEFORE FALLBACK (2026-09-16). Everything this vendor can still do
# for us happens here, before a single rung is descended: a transient failure is
# retried on the same runner and account with a doubling backoff, and an
# exhausted or de-authed account is cooled down (so account-pick.sh skips it for
# the window) and the next account of the SAME vendor is tried — until the
# vendor has none left. This supersedes the 2026-09-06 single-shot account
# retry: same cooldown, same picker, but it no longer stops after one account
# and it no longer treats a 30-second blip as a reason to change vendor.
ladder_recover "$RUNNER"

# THE CLIFF REFUSAL (BH-1039). The primary routed away from its runner ON PRICE.
# For a lane that declares `cliff_refuse`, the ladder stops here rather than
# buying the same work on a rung that costs ~100x — no tier-2, no configured
# fallback, no survival lane, nothing billed. The caller sees rc 79 with the
# marker already on $OUT, exactly as it does for any cliff route, and defers.
#
# failovers.log, not ALERTS: nothing failed, and paging every ten minutes about
# a working price guard would have alert-triage triaging its own routing. The
# CALLER is what escalates, once, after its own attempt cap.
cliff_refuse_gate() { # cliff_refuse_gate <where> ; rc 0 = refuse and exit 79
  local where="$1" cr nr nm gm
  cr=$(cliff_routed_runner); nr=$(cliff_next_runner); nm=$(ladder_model_for "$nr")
  gm=$(grok_model) || gm=grok
  cliff_refuse_enabled "$cr" || return 1
  _RPROJ=$(cliff_projected_context "$STAGE" "$PROJECT") || _RPROJ=""
  if cliff_refuse_costlier "$_RPROJ" "$nm"; then
    echo "$(STAMP) [$PROJECT] $STAGE CLIFF REFUSE ($where) — $cr was skipped on price and the rung below ($nr running $nm) at the projected ${_RPROJ:-unknown} tokens prices ABOVE a doubled $gm; nothing called, nothing billed, rc 79 returned for the caller to defer. Turn it off with LADDER_CLIFF_REFUSE=0, a switch.cliff-refuse-off=1 settings row or flags/cliff-refuse-off, or drop cliff_refuse from the lane in catalog/context-budgets.json." >> "$HARNESS/logs/failovers.log"
    return 0
  fi
  # NOT TAKEN, and said out loud: the rung below is cheaper at this size, so
  # this is BH-656's descent working as designed — and the row it writes is
  # what lets the projection move again.
  echo "$(STAMP) [$PROJECT] $STAGE CLIFF REFUSE NOT TAKEN ($where) — the rung below ($nr running $nm) at the projected ${_RPROJ:-unknown} tokens is no dearer than a doubled $gm; descending as BH-656 intended" >> "$HARNESS/logs/failovers.log"
  return 1
}
if [ "$RC" -ne 0 ] && cliff_routed_rc && cliff_refuse_gate primary; then
  cg_finish "$RC"
  exit "$RC"
fi

# Killed from outside: ONE retry on the same lane (same account, same prompt —
# the cheapest possible re-try, and usually cache-warm), then stop. Never a
# cross-vendor hop: a kill says nothing about the vendor.
if [ "$RC" -ne 0 ] && [ -n "${KILL_STOP:-}" ]; then
  echo "$(STAMP) [$PROJECT] $STAGE $RUNNER was killed from outside (rc=$RC) — one retry on the SAME lane; no cross-vendor failover on a kill" >> "$HARNESS/logs/failovers.log"
  run_attempt "$RUNNER"
fi

# Tier-2 fallback (the operator, 2026-08-30): Grok is the first provider fallback after
# the primary runner. A successful failover is routine and stays in
# failovers.log; only exhausting Grok advances to the configured fallback and
# loud survival tiers. Downstream review/verify gates and the .runner marker
# still apply.
# LADDER_TIER2_GROK=0 removes this rung entirely (claude -> configured fallback
# -> OpenRouter): a box that does not want a third vendor in the middle of its
# descent says so once in env/global.env. Default 1 — the rung as it shipped.
if [ "$RC" -ne 0 ] && [ "${LADDER_TIER2_GROK:-1}" = 1 ] && [ -z "${BUDGET_STOP:-}" ] && [ -z "${KILL_STOP:-}" ] && [ "$TOOL_FENCED" != 1 ] && [ "$RUNNER" != "grok" ] && runner_allowed grok && runner_ready grok; then
  echo "$(STAMP) [$PROJECT] $STAGE tier-2: engaging Grok fallback" >> "$HARNESS/logs/failovers.log"
  run_attempt grok
  # Grok gets the same recovery the primary got: a blip on the fallback vendor
  # is not a reason to walk further down either.
  ladder_recover grok
  if [ "$RC" -ne 0 ]; then
    if cliff_routed_rc; then
      # "Grok failed too" would be false here, and a false line in the log the
      # ladder's decisions are read from is worse than no line.
      echo "$(STAMP) [$PROJECT] $STAGE tier-2 Grok cliff-routed (rc=79) — nothing called" >> "$HARNESS/logs/failovers.log"
      # ...AND THE SAME PRICE GATE APPLIES HERE (BH-1039 review r2, I3). The
      # refusal above covers only the PRIMARY's cliff, so a lane whose primary
      # FAILS and whose tier-2 grok then cliff-routes walked straight on to the
      # configured fallback and OpenRouter with cliff_refuse on — the 2026-09-20
      # ladder, one rung later. `continuing down the ladder` was the line it
      # wrote while it did.
      if cliff_refuse_gate tier-2; then
        cg_finish "$RC"
        exit "$RC"
      fi
      echo "$(STAMP) [$PROJECT] $STAGE tier-2: continuing down the ladder" >> "$HARNESS/logs/failovers.log"
    elif [ -n "${GATE_REFUSED:-}" ]; then
      # "Grok failed too" is false about a rung nothing asked (BH-1141 r2, B1).
      echo "$(STAMP) [$PROJECT] $STAGE tier-2 Grok refused by the lane's own control (${LLM_GATE_REASON:-runner-not-allowed}) — nothing called, nothing billed" >> "$HARNESS/logs/failovers.log"
    else
      echo "$(STAMP) [$PROJECT] $STAGE tier-2 Grok failed too (see $OUT.err)" >> "$HARNESS/logs/failovers.log"
    fi
  fi
fi

# CLAUDE IN OPENROUTER'S PLACE (BH-1853). A non-claude primary whose OpenRouter
# rung (configured fallback or tier-3) the gate refused had nothing left after
# grok: the stage failed with no claude attempt while claude could serve. So
# claude takes that rung, through the configured-fallback arm below. If claude
# runs out too, tier-3 reaches OpenRouter through the unchanged gate:
# primary -> grok tier-2 -> claude (all accounts) -> OpenRouter only if claude is out.
if [ "$RC" -ne 0 ] && [ -z "${KILL_STOP:-}" ] && [ -z "${BUDGET_STOP:-}" ] && [ "$TOOL_FENCED" != 1 ] \
   && [ "$RUNNER" != claude ] && [ "$RUNNER" != openrouter ] && { [ -z "$FALLBACK" ] || [ "$FALLBACK" = openrouter ]; } \
   && runner_allowed openrouter && runner_ready openrouter && runner_allowed claude && runner_ready claude \
   && ! openrouter_fallback_ok; then
  FALLBACK=claude
  echo "$(STAMP) [$PROJECT] $STAGE on $RUNNER exited rc=$RC — claude in place of openrouter: the OpenRouter fallback is gated while a Claude account can serve" >> "$HARNESS/logs/failovers.log"
fi

# Failover: Grok failed (or was unavailable) -> one retry on an explicitly
# configured fallback runner. Post-checks downstream (empty-diff, adversarial
# review) still gate correctness, so a retry on a partially-touched worktree is
# safe. A configured Grok fallback is skipped here because tier-2 already tried it.
# Per the operator 2026-07-27: a WORKING failover is routine, not an alert. It logs
# quietly; ALERTS (-> Telegram) fires only when the fallback also fails or no
# fallback exists — i.e. the stage is actually stuck.
if [ "$RC" -ne 0 ] && [ -n "${KILL_STOP:-}" ]; then
  echo "$(STAMP) [$PROJECT] $STAGE KILLED: ${PHASE_RUNNER:-$RUNNER} was killed from outside (rc=$RC) — not an auth, credit or vendor failure, so lower fallback and survival lanes are NOT engaged (re-buying a killed run on another vendor is pure cost). Forensics in $HARNESS/logs/kills.log." >> "$ALERTS"
elif [ "$RC" -ne 0 ] && [ -n "${BUDGET_STOP:-}" ]; then
  if [ -n "${CTX_STOP:-}" ]; then
    # The CONTEXT KILL line already said this, with the ceiling, the total and
    # the call count in it. One event, one ALERTS line — the record of the
    # policy stop goes to failovers.log, where the rest of the ladder's
    # decisions are. Same label as the alert: the summary of a stop must not
    # name a different bound than the stop itself did (BH-1384).
    if [ -f "$OUT.cliffcap" ]; then
      echo "$(STAMP) [$PROJECT] $STAGE CLIFF-AVOIDED: ${PHASE_RUNNER:-$RUNNER} stopped under its model's price cliff ($(cat "$OUT.cliffcap" 2>/dev/null)) — stage fails by policy; lower fallback/survival lanes NOT engaged. The cliff lives in catalog/model-prices.json (cliff_tokens); the lane ceiling it was clamped against lives in catalog/context-budgets.json (context_kill_tokens)." >> "$HARNESS/logs/failovers.log"
    else
      echo "$(STAMP) [$PROJECT] $STAGE CONTEXT KILL: ${PHASE_RUNNER:-$RUNNER} stopped at its lane context ceiling — stage fails by policy; lower fallback/survival lanes NOT engaged. Ceilings live in catalog/context-budgets.json (context_kill_tokens)." >> "$HARNESS/logs/failovers.log"
    fi
  elif [ -n "${TW_STOP:-}" ]; then
    # The tripwire lib owns the one alert for a trip; this is the ladder's record.
    echo "$(STAMP) [$PROJECT] $STAGE TRIPWIRE: ${PHASE_RUNNER:-$RUNNER} stopped by the build tripwire ($(head -1 "$OUT.tripwire" 2>/dev/null)) — stage fails by policy; lower fallback/survival lanes NOT engaged." >> "$HARNESS/logs/failovers.log"
  else
    # The stopped attempt's own envelope figure; run_attempt's last spend when
    # the runner wrote no envelope; else an honest `?` (BH-4609).
    _BS_USD=$(jq -r '.total_cost_usd // empty' "$OUT.json" 2>/dev/null)
    [[ ${_BS_USD:-} =~ ^[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]] || _BS_USD="${LAST_ATTEMPT_USD:-}"
    [[ ${_BS_USD:-} =~ ^[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]] || _BS_USD='?'
    echo "$(STAMP) [$PROJECT] $STAGE BUDGET STOP: ${PHASE_RUNNER:-$RUNNER} hit its configured bound (cost \$${_BS_USD}) — stage fails by policy; lower fallback/survival lanes NOT engaged. If the cap is wrong, fix the lane in catalog/context-budgets.json." >> "$ALERTS"
  fi
elif [ "$RC" -ne 0 ] && [ "$TOOL_FENCED" != 1 ] && [ -n "$FALLBACK" ] && [ "$FALLBACK" != "$RUNNER" ] && [ "$FALLBACK" != "grok" ] && runner_ready "$FALLBACK" \
     && { [ "$FALLBACK" != openrouter ] || openrouter_fallback_ok; }; then
  PRIMARY="$RUNNER"; PRC="$RC"
  echo "$(STAMP) [$PROJECT] $STAGE on $PRIMARY exited rc=$PRC — failing over to $FALLBACK (see $OUT.err)" >> "$HARNESS/logs/failovers.log"
  run_attempt "$FALLBACK"
  ladder_recover "$FALLBACK"
  if [ "$RC" -ne 0 ]; then
    echo "$(STAMP) [$PROJECT] $STAGE: $PRIMARY rc=$PRC AND configured fallback $FALLBACK rc=$RC (see $OUT.err)" >> "$HARNESS/logs/failovers.log"
  fi
elif [ "$RC" -ne 0 ]; then
  echo "$(STAMP) [$PROJECT] $STAGE: $RUNNER rc=$RC, no usable configured fallback (see $OUT.err)" >> "$HARNESS/logs/failovers.log"
fi

# Tier-3 survival lane (2026-08-02): after the primary, Grok tier-2 and any
# configured fallback fail (or are unavailable), alert LOUDLY, then try OpenRouter.
# Downstream review/verify gates still apply to anything it produces.
if [ "$RC" -ne 0 ] && [ -z "${BUDGET_STOP:-}" ] && [ -z "${KILL_STOP:-}" ] && [ "$TOOL_FENCED" != 1 ] && [ "$RUNNER" != "openrouter" ] && [ "${FALLBACK:-}" != "openrouter" ] && runner_allowed openrouter && runner_ready openrouter \
   && openrouter_fallback_ok; then
  # A CLIFF ROUTE IS NOT AN EXHAUSTED LADDER (BH-656): no vendor failed, we
  # chose a cheaper rung on purpose, and paging hourly about a working failover
  # would have alert-triage triaging its own routing. Logged, not alerted — and
  # a survival lane that then FAILS still alerts below, exactly as today.
  if cliff_routed_rc; then
    echo "$(STAMP) [$PROJECT] $STAGE tier-3: cliff-routed onto the OpenRouter survival lane after ${LADDER_CLASSES:-routed} — no vendor failed on this rung, routine failover, not a page" >> "$HARNESS/logs/failovers.log"
  elif ! llm_gate_runner_ok "$STAGE" "$PROJECT" openrouter || ! call_guard_rung_ok openrouter; then
    # ASK THE GATE BEFORE PAGING (BH-1141 round 2, B1). This block alerts and
    # beats BEFORE run_attempt, so on a lane pinned to one runner it woke
    # Telegram with "check account credits/limits" for a rung the very next line
    # then refused — twice per failure, on a */2 lane, fed straight back into
    # alert-triage, which is itself an LLM lane. The attempt below still runs:
    # it is what writes the refused row and the failovers line, so the descent
    # that did not happen stays a fact in the ledger.
    echo "$(STAMP) [$PROJECT] $STAGE tier-3: the lane's own control refuses the OpenRouter rung (${LLM_GATE_REASON:-runner-not-allowed}) — descending without a page; the refusal and its zero-cost row are the record" >> "$HARNESS/logs/failovers.log"
  else
    "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" --arg akey "tier3:$PROJECT:$STAGE:$(date -u +%Y%m%d%H)" \
      --arg l "SURVIVAL LANE: $STAGE on $PROJECT exhausted its primary runners and Grok tier-2 (failed or unavailable; rc=$RC) — attempting on OpenRouter with the stage model ($MODEL, anthropic/ slug). Check account credits/limits." \
      '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1 || true
    echo "$(STAMP) [$PROJECT] $STAGE tier-3: engaging OpenRouter survival lane" >> "$ALERTS"
  fi
  run_attempt openrouter
  # ...and the failure line is a page only if something actually failed. A rung
  # the gate refused did not fail (BH-1141 round 2, B1); its record is the
  # refused row and the failovers line run_attempt just wrote.
  if [ "$RC" -ne 0 ] && [ -z "${GATE_REFUSED:-}" ]; then
    echo "$(STAMP) [$PROJECT] $STAGE tier-3 failed too (see $OUT.err)" >> "$ALERTS"
  fi
fi

# Tier-3b (the operator, 2026-08-19): Fireworks.ai — direct vendor for the open-model
# floor, independent of OpenRouter's routing AND its pre-auth headroom failure
# mode. Engages only after OpenRouter also failed; the stage model is not
# preserved (open models only). Downstream review gates + the .runner marker
# still keep anything it produces from auto-merging.
if [ "$RC" -ne 0 ] && [ -z "${BUDGET_STOP:-}" ] && [ -z "${KILL_STOP:-}" ] && [ "$TOOL_FENCED" != 1 ] && [ "$RUNNER" != "fireworks" ] && [ "${FALLBACK:-}" != "fireworks" ] && runner_allowed fireworks && runner_ready fireworks; then
  # Same reading as tier-3 above: routed here rather than driven here by a
  # failure. (Reached only when tier-3 was itself unavailable — if OpenRouter
  # ran and failed, RC is ITS rc and this is a real page again.)
  if cliff_routed_rc; then
    echo "$(STAMP) [$PROJECT] $STAGE tier-3b: cliff-routed onto the Fireworks survival lane after ${LADDER_CLASSES:-routed} — no vendor failed on this rung, routine failover, not a page" >> "$HARNESS/logs/failovers.log"
  elif ! llm_gate_runner_ok "$STAGE" "$PROJECT" fireworks || ! call_guard_rung_ok fireworks; then
    # Same reading as tier-3 (BH-1141 round 2, B1): the gate is asked before the
    # page, so a rung this lane may not reach wakes nobody. LAST RESORT is not
    # written either — the lane did not fall to Fireworks, it was refused it.
    echo "$(STAMP) [$PROJECT] $STAGE tier-3b: the lane's own control refuses the Fireworks rung (${LLM_GATE_REASON:-runner-not-allowed}) — descending without a page; the refusal and its zero-cost row are the record" >> "$HARNESS/logs/failovers.log"
  else
    "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" --arg akey "tier3b:$PROJECT:$STAGE:$(date -u +%Y%m%d%H)" \
      --arg l "SURVIVAL LANE: $STAGE on $PROJECT failed on OpenRouter too (rc=$RC) — attempting on Fireworks.ai (open model — stage model NOT preserved). Check OpenRouter credits/limits." \
      '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1 || true
    ladder_last_resort fireworks
    echo "$(STAMP) [$PROJECT] $STAGE tier-3b: engaging Fireworks survival lane" >> "$ALERTS"
  fi
  run_attempt fireworks
  if [ "$RC" -ne 0 ] && [ -z "${GATE_REFUSED:-}" ]; then
    echo "$(STAMP) [$PROJECT] $STAGE tier-3b failed too (see $OUT.err)" >> "$ALERTS"
  fi
fi

# >>> llm-gate-exit
# THE EXIT BELONGS TO THE LAST RUNG THAT RAN (BH-1141 round 2, B1). RC is the
# LAST attempt's, and on a mixed ladder the last attempt is a refusal while the
# billed one is two rungs up. Exiting 74 there says "nothing was called and
# nothing was billed" about a call that ran claude, failed and paid for it — and
# every caller this ticket taught about 74 (bin/alert-triage.sh re-spools the
# family, bin/review-autopilot.sh writes no key and charges no cap,
# preplan_rc_billed does not count the attempt) would buy that same failure
# again on the next tick, for ever, at full price.
#
# So 74 survives to the exit only when NOTHING ran. Otherwise the stage exits
# with the rc of the attempt that was actually billed, which is what it would
# have exited with before any of the lower rungs were refused, and GATE_REFUSED
# is cleared so the reporting below says DEAD (a vendor did die) rather than
# GATED (nothing was called).
if [ "$RC" -eq 74 ] && [ -n "${ANY_RAN:-}" ]; then
  echo "$(STAMP) [$PROJECT] $STAGE the last rung was refused by the lane's own control (${LLM_GATE_REASON:-runner-not-allowed}), but ${PHASE_RUNNER:-$RUNNER} RAN and was billed (rc=${LAST_RAN_RC:-?}) — exiting with the billed attempt's rc, not the refusal's 74" >> "$HARNESS/logs/failovers.log"
  RC="${LAST_RAN_RC:-$RC}"
  GATE_REFUSED=""
fi
# <<< llm-gate-exit

if [ "$RC" -ne 0 ]; then
  if cliff_routed_rc; then
    # "Every available lane failed" would be a lie about a lane that was never
    # called. This one names the knob that fixes it, because the fix is config.
    echo "$(STAMP) [$PROJECT] $STAGE STUCK: Grok was cliff-routed (projected context past the $(grok_model 2>/dev/null || echo grok) cliff) and no lane below it was available — nothing ran and nothing was billed. Set $FVAR to a runner with no cliff at this size, or turn routing off (RUNNER_CLIFF_ROUTE=0 / a switch.cliff-route-off=1 settings row / flags/cliff-route-off)." >> "$ALERTS"
  elif [ -n "${GATE_REFUSED:-}" ]; then
    # "Every available lane failed" would be a lie about a lane that was never
    # called. failovers.log, not ALERTS: a working spend control is not a page,
    # and the refused rows in the ledger are the durable record.
    echo "$(STAMP) [$PROJECT] $STAGE GATED: the last rung tried was refused by the lane's own control (${LLM_GATE_REASON:-runner-not-allowed}) — nothing was called and nothing was billed. Widen LLM_RUNNER_ALLOWED for this lane, or leave it and let the caller defer." >> "$HARNESS/logs/failovers.log"
  elif [ "${AGENT_CALL_DEAD_ALERT:-1}" = 0 ]; then
    # The caller owns the page for this call (BH-3222: oauth-refresh's canary on
    # a dead login paged DEAD every 15 minutes for logins nothing routes to). Same
    # line, failovers.log, so the record is kept and nobody is paged.
    echo "$(STAMP) [$PROJECT] $STAGE DEAD: every available lane failed (see $OUT.err)" >> "$HARNESS/logs/failovers.log"
  else
    echo "$(STAMP) [$PROJECT] $STAGE DEAD: every available lane failed (see $OUT.err)" >> "$ALERTS"
  fi
  # THE STAGE'S VERDICT, IN ONE LINE THE CALLER CAN RENDER (BH-642). A stage
  # that produced nothing because its accounts were out of credits used to
  # reach bin/run-build.sh as an empty outfile and nothing else, and got
  # reported as "plan session produced no output (model limit/failure?)" —
  # indistinguishable from a model that ran and said nothing. Written only on a
  # non-zero exit, after every rung, so `seen=` carries the whole ladder rather
  # than its last step — including a cliff-routed STUCK, whose verdict is the
  # routed class and not silence.
  ladder_classify "${PHASE_RUNNER:-$RUNNER}"
  # `exhausted=` and `resets_at=` are appended only when there is something to
  # say, so every line that had nothing to say is byte-identical to before.
  printf '%s class=%s%s seen=%s runner=%s rc=%s%s%s\n' \
    "$(ladder_exit_token)" "$LADDER_CLASS" "${LADDER_CLASS_DETAIL:+($LADDER_CLASS_DETAIL)}" \
    "$(printf '%s' "${LADDER_CLASSES:-$LADDER_CLASS}" | tr ' ' ',')" \
    "${PHASE_RUNNER:-$RUNNER}" "$RC" \
    "${LADDER_EXHAUSTED_RUNNERS:+ exhausted=$LADDER_EXHAUSTED_RUNNERS}" \
    "${LADDER_RESETS_AT:+ resets_at=$LADDER_RESETS_AT}" > "$OUT.class" 2>/dev/null
fi
# The ledger's write half: the stage's real rc, the body it actually produced,
# and the lane that served it. Last thing before the exit so nothing after it
# can change what was recorded (BH-1037).
choke_record "$RC"
# K3: settle the call-guard claim with what actually happened (ok / empty /
# failed count as paid, unbilled frees the slot). Once, after the stage rc is final.
cg_finish "$RC"
exit "$RC"
