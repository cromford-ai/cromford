#!/bin/bash
# bin/lib/mc-prequeue.d/status.sh — the `prequeue-verdict` commit status
# (BH-5441, #5429 child 4). Sourced by bin/lib/mc-prequeue.sh's hook loop,
# never executed.
#
# pq_gate calls pq_status_gate on every answer it decides: a red publishes
# `failure`, a proceed publishes `success` with the reason in the description,
# and a hold, rebase or defer publishes nothing: none of them enqueues this
# tick. The TTL arm (mc_vs_ttl_republish) and the rebind arm
# (mc_rebind_publish) call pq_status_ensure, which publishes `success` only
# on a head that has no prequeue-verdict status and no red cache entry. It never
# overwrites a failure.
#
# The POST is vs_publish (bin/lib/verdict-status.sh) under
# LEAD_VERDICT_CONTEXT=prequeue-verdict. This file does not load it: the
# conductor does (merge-conductor-lib.sh). Without vs_publish every function
# here publishes nothing. Nothing here prints to stdout, because the callers
# read pq_gate's stdout.

PQ_STATUS_CONTEXT=prequeue-verdict

# pq_status_publish <slug> <head> <success|failure> <desc> [url] [sfx]
#   One POST per (head, state[, sfx]): the `pqst <slug> <head> <state>[ <sfx>]`
#   attempt line is written only after a 2xx. A failed POST writes no line and
#   one log line, so the next tick retries. rc 0 published or already
#   published, rc 1 not. sfx is `carry <main>` for a carried verdict (BH-8769),
#   so a head that got success on one main posts once more for the next.
pq_status_publish() {
  local slug="${1:-}" head="${2:-}" state="${3:-}" desc="${4:-}" url="${5:-}" sfx="${6:-}" err ak
  ak="pqst $slug $head $state${sfx:+ $sfx}"
  declare -F vs_publish >/dev/null || return 1
  mc_attempt_has "$ak" 2>/dev/null && return 0
  if err=$(LEAD_VERDICT_CONTEXT=$PQ_STATUS_CONTEXT vs_publish "$slug" "$head" "$state" "$desc" "$url" 2>&1 >/dev/null); then
    mc_attempt_put "$ak"
    mc_log "$slug@${head:0:12} PQ_STATUS_PUBLISHED $PQ_STATUS_CONTEXT=$state ($desc)"
    return 0
  fi
  mc_log "$slug@${head:0:12} $PQ_STATUS_CONTEXT=$state NOT published: $(head -1 <<<"${err:-vs_publish failed}") — retried next tick"
  return 1
}

# pq_status_gate <slug> <head> <url> [off] — the status for the answer pq_gate
#   just decided (PQ_VERDICT, PQ_PATH, PQ_MAIN, PQ_SUITES, _pq_wf, PQ_OFF_WHY).
#   The off text is PQ_OFF_WHY when pq_hotfix_skip set it, else `gate off`. An
#   entry carried from an older main (its `.reuse` sidecar, impact-reuse.sh)
#   names both mains (BH-8769). Always rc 0.
pq_status_gate() {
  local slug="${1:-}" head="${2:-}" url="${3:-}" off="${4:-}" desc="" st f3 m12="${PQ_MAIN:0:12}" sfx="" vm=""
  case "${PQ_VERDICT:-}" in
    red)
      [ -n "${PQ_PATH:-}" ] && [ -r "$PQ_PATH.why" ] && desc=$(head -n1 "$PQ_PATH.why" 2>/dev/null)
      pq_status_publish "$slug" "$head" failure "${desc:-suites: ${PQ_SUITES:-}}" "$url" ;;
    proceed)
      if [ "$off" = off ]; then desc="${PQ_OFF_WHY:-gate off}"
      else
        read -r st _ f3 _ <<<"$(pq_cache_get "${PQ_PATH:-}")"
        case "$st" in
          green|no-selection|conflict)
            desc="$st on main $m12"
            [ -n "${PQ_PATH:-}" ] && [ -r "$PQ_PATH.reuse" ] && vm=$(sed -n '1s/.* main=\([0-9a-f]*\) .*/\1/p' "$PQ_PATH.reuse" 2>/dev/null)
            if [[ "$vm" =~ ^[0-9a-f]{40}$ ]] && [[ "${PQ_MAIN:-}" =~ ^[0-9a-f]{40}$ ]]; then
              desc="$st on main ${vm:0:12}, carried to main $m12"; sfx="carry $PQ_MAIN"
            fi ;;
          could-not-run) desc="could-not-run (${f3:-unknown}): enqueued without it" ;;
          red) desc="could-not-run (red without suites): enqueued without it" ;;
          *)
            if [ "${_pq_wf:-}" = no ] || ! declare -F pq_resolve >/dev/null; then desc="no pre-queue workflow"
            elif [ "${_pq_wf:-}" = unknown ]; then desc="could-not-run (workflow probe unreadable): enqueued without it"
            else desc="proceed on main $m12"; fi ;;
        esac
      fi
      pq_status_publish "$slug" "$head" success "$desc" "$url" "$sfx" ;;
  esac
  return 0
}

# pq_status_ensure <slug> <head> <url> <why> — success on a head that has no
#   prequeue-verdict status and no red cache entry (any PR number, any main,
#   any fp). Any other answer, an unread status included, publishes nothing.
#   Always rc 0.
pq_status_ensure() {
  local slug="${1:-}" head="${2:-}" url="${3:-}" why="${4:-}" f st cur
  declare -F vs_publish >/dev/null && [ -n "${MC_STATE_DIR:-}" ] && [[ "$head" =~ ^[0-9a-f]{40}$ ]] || return 0
  for f in "$MC_STATE_DIR/prequeue/${slug//\//_}_"*"_${head}_"*; do
    case "$f" in *.why|*.fail|*.timing|*.tmp.*) continue ;; esac
    read -r st _ <<<"$(pq_cache_get "$f")"
    [ "$st" = red ] && return 0
  done
  cur=$(mc_vs_state_on "$slug" "$head" "$PQ_STATUS_CONTEXT" 2>/dev/null) || return 0
  [ "$cur" = absent ] || return 0
  pq_status_publish "$slug" "$head" success "no red pre-queue verdict on this head: $why" "$url" || true
  return 0
}
