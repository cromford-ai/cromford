#!/bin/bash
# bin/lane-probe.sh <claude|codex|openrouter|fireworks|grok> [--endpoint]
# bin/lane-probe.sh --endpoint <lane>
# Deterministic runner-lane canary probe. Exists so the hub's auth-check can ssh
# "lane-probe.sh X" instead of shipping fragile nested-quoted one-liners (project-3
# false-alarm, 2026-08-02).
#   default     one inference through agent-call.sh (stage canary, the lane
#               pinned with AGENT_CALL_RUNNERS, so it writes a cost row and no
#               other rung can answer for it); prints the tail of the answer.
#   --endpoint  BH-2560 (BH-2549.2): line 1 is `cred_probe <lane>` (ALIVE,
#               DEAD, INCONCLUSIVE, DEGRADED or NO_ENDPOINT, see
#               bin/lib/cred-probe.sh). Only when cred_inference_claim says rc 0
#               does it also print an `INFERENCE` line, run the default probe
#               below it and cred_inference_record the outcome. Claim rc 1
#               (already spent today) or 2 (store unreachable) spends nothing.
#               Exits 0 whatever the verdict: the verdict is the text.
set -uo pipefail
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir /root/harness)
set -a; . $HENV/global.env 2>/dev/null; set +a
cd /tmp
H="${HARNESS:-/root/harness}"
MODE=probe
[ "${1:-}" = --endpoint ] && { MODE=endpoint; shift; }
LANE="${1:?lane}"
[ "${2:-}" = --endpoint ] && MODE=endpoint
case "$LANE" in
  claude|codex|openrouter|fireworks|grok) ;;
  *) echo "lane-probe.sh: unknown lane '$LANE'" >&2; exit 64 ;;
esac
# >>> model-route (BH-1510.2): probe the SAME model the lane runs — model_routes
# role `<lane>.default` (codex.default, openrouter.default, fireworks.default,
# grok.default), with the lane's own env var still winning when set. claude is
# role `auth.canary` (AUTH_CANARY_MODEL wins), the rung bin/claude-auth-check.sh's
# own ladder starts on. When that route cannot be read (a box synced before the
# worker schema applied), claude falls back to role `triage`, and
# bin/lib/model-route.sh wrote its ALERTS line naming auth.canary. No route =
# rc 75 and no probe: a canary of a guessed model would report on the guess.
# bin/lib/model-route.sh alerted the role.
. "${HARNESS:-/root/harness}/bin/lib/lane-model.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/lane-model.sh"
case "$LANE" in
  claude)     PROBE_MODEL=$(lane_model AUTH_CANARY_MODEL auth.canary) \
                || PROBE_MODEL=$(lane_model AUTH_CANARY_MODEL triage) ;;
  codex)      PROBE_MODEL=$(lane_model CODEX_MODEL codex.default) ;;
  openrouter) PROBE_MODEL=$(lane_model OPENROUTER_MODEL openrouter.default) ;;
  fireworks)  PROBE_MODEL=$(lane_model FIREWORKS_MODEL fireworks.default) ;;
  grok)       PROBE_MODEL=$(lane_model GROK_MODEL grok.default) ;;
  *)          PROBE_MODEL="" ;;
esac || { echo "no model route for the $LANE lane (rc 75) — not probed"; exit 75; }
# <<< model-route
AC="$H/bin/agent-call.sh"
[ -x "$AC" ] || AC="$(dirname "${BASH_SOURCE[0]}")/agent-call.sh"

# infer: one inference on this lane, through agent-call. Its rc is agent-call's
# (74..79 = refused, nothing was called and nothing was billed). The vendor
# flags the old per-lane CLI arms carried (the openrouter/fireworks provider
# config, fireworks' web_search="disabled", grok's GROK_BILLING switch) are
# agent-call's own, so the canary probes exactly the path a build takes.
# ACCOUNT_ROUTING=0: the canary proves the credential in THIS env, not whichever
# registered account account-pick would prefer. CANARY_FP is set by --endpoint
# only: the day fp canary:<lane>:<account fp>:<UTC day>, so a second probe of
# the day is a ledger replay (BH-9125). Default mode (bin/lane-reprobe.sh) never
# sets it: a reprobe needs fresh evidence, not the stored answer of the day.
CANARY_FP=""
infer() {
  local OUTF rc
  if [ "$LANE" = codex ]; then
    # Report the CLI version first: a new codex model can need a newer CLI than
    # the box has (the Fable 5.1 lesson — project-9 sat on an old CLI and every
    # lane fell over). A --version read, not an inference. The version line
    # must never contain the word "ok" (auth-check greps for it).
    echo "codex-cli-version=$(codex --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"
  fi
  OUTF=$(mktemp)
  # llm-site: lane-probe
  AGENT_CALL_FP="$CANARY_FP" AGENT_CALL_RUNNERS="$LANE" AGENT_CALL_LANE=claude-auth-check ACCOUNT_ROUTING=0 "$AC" canary fleet "$PROBE_MODEL" 120 "$OUTF" "Reply with exactly: ok" </dev/null >/dev/null 2>&1
  rc=$?
  tail -5 "$OUTF"
  rm -f "$OUTF" "$OUTF".*
  return "$rc"
}

if [ "$MODE" = probe ]; then infer; exit $?; fi

# --endpoint. A box mid-sync with no contract lib yet behaves as the contract's
# own stub does (NO_ENDPOINT, claim 0): exactly the probe it ran before.
CRED_PROBE_LIB="${CRED_PROBE_LIB:-$H/bin/lib/cred-probe.sh}"
# shellcheck source=bin/lib/cred-probe.sh
if ! . "$CRED_PROBE_LIB" 2>/dev/null || ! command -v cred_probe >/dev/null 2>&1; then
  cred_probe() { echo NO_ENDPOINT; return 4; }
  cred_account_fp() { return 1; }
  cred_inference_claim() { return 0; }
  cred_inference_record() { return 0; }
fi
EP=$(cred_probe "$LANE" 2>/dev/null | head -1)
echo "${EP:-INCONCLUSIVE cred_probe printed nothing}"
FP=$(cred_account_fp "$LANE" 2>/dev/null) || FP=""
cred_inference_claim "$LANE" "$FP" || exit 0
[ -n "$FP" ] && CANARY_FP="canary:$LANE:$FP:$(date -u +%F)"
echo INFERENCE
ANS=$(infer); RC=$?
[ -n "$ANS" ] && printf '%s\n' "$ANS"
# A refusal bought nothing, so there is nothing to record. A terminal ledger
# row (BH-9064) gives back its stored rc with the AGENT_CALL_REFUSED line.
[ "$RC" -ge 74 ] && [ "$RC" -le 79 ] && exit 0
grep -q '^AGENT_CALL_REFUSED' <<<"$ANS" && exit 0
# codex's version line is not part of the answer.
REPLY=$(grep -v '^codex-cli-version=' <<<"$ANS")
if grep -qiE '\bok\b' <<<"$REPLY"; then V=ok
elif [ -z "${REPLY//[[:space:]]/}" ]; then V=empty
else V=down; fi
cred_inference_record "$LANE" "$FP" "$V" >/dev/null 2>&1 || true
exit 0
