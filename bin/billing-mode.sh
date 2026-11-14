#!/bin/bash
# bin/billing-mode.sh <runner> [project] — does a call on this runner cost CASH on this box?
#
# Prints one of: metered | subscription | unknown
#
# WHY THIS EXISTS. Every cost row is priced at API-equivalent and summed as
# `cost_7d`, which the dashboard shows as spend. That number is wrong in both
# directions at once: ~$1,940/7d of Claude SUBSCRIPTION compute is counted as
# though it were money, while real metered CASH on fireworks and openrouter
# shows as $0.00. Same ledger, two different kinds of number, added together.
#
# The API-equivalent figure is still worth having — it is what the work WOULD
# cost at retail, which is the right number for comparing lanes. It is just not
# the invoice. So the row records which kind it is, and the roll-up keeps them
# apart instead of the reader guessing.
#
# The answer depends on the BOX, not just the runner: the same `claude` runner
# is flat-rate on a subscription box and per-token on the project-10 api-key box. So
# this reads the credential environment, and must be called where that env is
# live — at row-write time in agent-call.sh, never retroactively on the hub.
#
# Deliberately conservative: an unrecognised runner is `unknown`, not a guess in
# either direction. Guessing `subscription` would hide real cash; guessing
# `metered` would invent spend that was never billed. The roll-up counts unknown
# toward notional and flags the count, so it shows up as a question rather than
# as a number somebody trusts.
#
# THE PROJECT (BH-9676). With runner `claude` and a second argument, a project
# whose settings row claude_auth.<project> is `api-key` bills its own Anthropic
# key per token, whatever else this box's env holds: agent-call unsets the
# OAuth token for that call. Any other answer (no row, `oauth`, a bad row)
# falls through to the env rule below. No second argument: nothing new is
# sourced and every answer is the env rule, as before.
set -uo pipefail
RUNNER="${1:-}"
PROJECT="${2:-}"

if [ "$RUNNER" = claude ] && [ -n "$PROJECT" ]; then
  _bm_mode=$( . "$(dirname "$0")/lib/claude-auth.sh" >/dev/null 2>&1 || exit 1; claude_auth_mode "$PROJECT" 2>/dev/null ) || _bm_mode=""
  [ "$_bm_mode" = api-key ] && { echo metered; exit 0; }
fi

case "$RUNNER" in
  claude)
    # An API key with no OAuth token means this box bills per token (the project-10
    # api-key box). With the OAuth token present, calls ride the flat-rate
    # subscription and cost nothing at the margin — until the account tips into
    # overage, which is ACCOUNT-level and handled separately in the roll-up
    # (logs/extra-usage.csv), because no per-row signal can see it.
    if [ -n "${ANTHROPIC_API_KEY:-}" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
      echo metered
    else
      echo subscription
    fi ;;
  codex)
    # ChatGPT Pro, flat. CODEX_API_KEY/OPENAI_API_KEY exist on some boxes as a
    # fallback credential but the lane runs on the subscription auth
    # (~/.codex/auth.json); calling this metered would invent spend.
    echo subscription ;;
  grok)
    # SuperGrok subscription pool by default. GROK_BILLING=api is the documented
    # switch to the xAI API wallet — the flip that cost $460 in two days in
    # August, which is exactly why billing mode is a recorded field now and not
    # a thing anyone infers later.
    if [ "${GROK_BILLING:-}" = api ]; then echo metered; else echo subscription; fi ;;
  openrouter|fireworks)
    # No subscription tier exists for these; every call is billed per token.
    echo metered ;;
  gemini)
    # Same shape as claude: agent-call accepts gemini via EITHER an OAuth creds
    # file or GEMINI_API_KEY, so "gemini" alone does not mean cash. An OAuth
    # gemini box billed at API rates would overstate spend — the direction that
    # matters, since this whole wave exists because a number was overstated.
    # Latent today (no RUNNER_*=gemini in the fleet) and correct anyway.
    if [ -n "${GEMINI_API_KEY:-}" ] && [ ! -f "$HOME/.gemini/oauth_creds.json" ]; then
      echo metered
    else
      echo subscription
    fi ;;
  *)
    echo unknown ;;
esac
