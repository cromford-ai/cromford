#!/bin/bash
# bin/merge-queue-reconcile.sh — BH-5670 (BH-5008 child 4): corrects a merge
# queue stage that a dropped webhook left wrong, from Mergify's own answer.
# Hub only, every 2 min (cron/lanes/728-merge-queue-reconcile.cron).
#
# One run:
#   1. GET /api/merge-queue/reconcile: the repos with an active queue row and
#      the per-tick repo cap (settings row merge_queue_reconcile_repos, 10).
#      The worker does not answer: `jobs-unreachable`, rc 1, no Mergify call.
#      No active repo: `idle`, rc 0, no Mergify call.
#   2. MERGIFY_API_TOKEN unset or not token-shaped: `not-configured`, rc 0,
#      nothing sent.
#   3. Per repo, up to the cap: GET $MERGIFY_API_URL/repos/<slug>/merge-queue/status,
#      20 s timeout, the bearer on curl's stdin (never argv). A non-2xx, a curl
#      error or a body that is not a JSON object is one log line and no answer
#      for that repo. Repos past the cap are logged by name as deferred; the
#      list is rotated by the 2-minute tick, so a deferred repo is first on a
#      later tick.
#      Each answer is also kept, whole, in
#      state/merge-queue-status/<owner>_<repo>.json with `fetched_at` (epoch)
#      added: tmp + mv, so a reader never sees half a file, and a failed read
#      leaves the last good file as it was. The merge conductor reads it for
#      queue presence (BH-8417, bin/merge-conductor.d/bh-8417-repo-truth.sh).
#   4. POST the answers to /api/merge-queue/reconcile, which writes the
#      corrective rows. A failed POST is `post-failed`, rc 1.
# No lock: every write is idempotent, so an overlapping run is harmless.
#
# Summary line (logs/merge-queue-reconcile.log): <ts> jobs-unreachable http=<c>
#   | <ts> idle active=0 mergify_calls=0 | <ts> not-configured active=<n>
#   | <ts> active=<n> called=<m> ok=<k> failed=<f> deferred=<d>[ (<slugs>)]
#     written=<w> eta_set=<e>
#
# Env: MERGIFY_API_TOKEN (env/global.env, hub only), MERGIFY_API_URL (the
# documented default is Mergify's v1 API). Test seam, honoured only under
# HARNESS_TEST_SANDBOX=1: MQR_NOW (epoch seconds) replaces the rotation clock.
#
# OFF: flags/lane-off-merge-queue-reconcile (bin/harness-ctl.sh off
# merge-queue-reconcile, read by lane_gate_or_exit).
# Registry: catalog/lanes.d/merge-queue-reconcile.json.
# Doc: docs/notes/2026-10-10-BH-5670-merge-queue-reconcile.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }

# shellcheck disable=SC1091
{
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
  . "$SELF/jobs-client.sh" 2>/dev/null || true
}

command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit merge-queue-reconcile
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply merge-queue-reconcile

mkdir -p "$H/logs" 2>/dev/null
LOG="$H/logs/merge-queue-reconcile.log"
summary() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$1" >> "$LOG"; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/mqr.XXXXXX") || { summary "mktemp-failed"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

command -v _jobs_req >/dev/null 2>&1 || { summary "jobs-unreachable http=none (jobs-client did not load)"; exit 1; }
if ! _jobs_req GET /api/merge-queue/reconcile > "$TMP/active.json"; then
  summary "jobs-unreachable http=${JOBS_HTTP:-none}"; exit 1
fi
N=$(jq -r '.repos | length' "$TMP/active.json" 2>/dev/null)
[[ "$N" =~ ^[0-9]+$ ]] || { summary "jobs-unreachable http=${JOBS_HTTP:-none} (no repos list)"; exit 1; }
[ "$N" -eq 0 ] && { summary "idle active=0 mergify_calls=0"; exit 0; }

if [ -z "${MERGIFY_API_TOKEN:-}" ] || ! [[ "$MERGIFY_API_TOKEN" =~ ^[A-Za-z0-9._~+/=-]+$ ]]; then
  summary "not-configured active=$N"; exit 0
fi
BASE="${MERGIFY_API_URL:-https://api.mergify.com/v1}"

CAP=$(jq -r '.cap' "$TMP/active.json")
[[ "$CAP" =~ ^[1-9][0-9]{0,8}$ ]] || CAP=10
NOW=$(date -u +%s)
[ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ "${MQR_NOW:-}" =~ ^[0-9]+$ ]] && NOW=$MQR_NOW
mapfile -t REPOS < <(jq -r '.repos[].repo' "$TMP/active.json")
OFF=$(( (NOW / 120) % N ))
ORDER=("${REPOS[@]:OFF}" "${REPOS[@]:0:OFF}")
CALL=("${ORDER[@]:0:CAP}")
DEFER=("${ORDER[@]:CAP}")

called=0; okn=0; failed=0
: > "$TMP/answers.jsonl"
for slug in "${CALL[@]}"; do
  if ! [[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || [[ "/$slug/" == */./* || "/$slug/" == */../* ]]; then
    printf '%s %s skipped: not an owner/name slug\n' "$(date -u +%FT%TZ)" "${slug:0:100}" >> "$LOG"
    failed=$((failed + 1)); continue
  fi
  called=$((called + 1))
  code=$(printf 'header = "Authorization: Bearer %s"\n' "$MERGIFY_API_TOKEN" \
    | curl -sS -K - --max-time 20 -o "$TMP/m.json" -w '%{http_code}' "$BASE/repos/$slug/merge-queue/status" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 0 ] && [[ "$code" =~ ^2[0-9][0-9]$ ]] && jq -e 'type == "object"' "$TMP/m.json" >/dev/null 2>&1; then
    jq -c --arg r "$slug" '{repo: $r, status: .}' "$TMP/m.json" >> "$TMP/answers.jsonl"
    okn=$((okn + 1))
    SF="$H/state/merge-queue-status/${slug//\//_}.json"
    mkdir -p "${SF%/*}" 2>/dev/null
    jq -c --argjson t "$NOW" '. + {fetched_at: $t}' "$TMP/m.json" > "$SF.tmp.$$" 2>/dev/null \
      && mv -f "$SF.tmp.$$" "$SF" 2>/dev/null || rm -f "$SF.tmp.$$"
  else
    printf '%s %s mergify http=%s rc=%s\n' "$(date -u +%FT%TZ)" "$slug" "${code:-000}" "$rc" >> "$LOG"
    failed=$((failed + 1))
  fi
  rm -f "$TMP/m.json"
done

DEFERRED="deferred=${#DEFER[@]}"
[ "${#DEFER[@]}" -gt 0 ] && DEFERRED="$DEFERRED (${DEFER[*]})"
LINE="active=$N called=$called ok=$okn failed=$failed $DEFERRED"
[ "$okn" -eq 0 ] && { summary "$LINE written=0 eta_set=0"; exit 0; }

BODY=$(jq -sc '{answers: .}' "$TMP/answers.jsonl")
if ! _jobs_req POST /api/merge-queue/reconcile "$BODY" > "$TMP/post.json"; then
  summary "$LINE post-failed http=${JOBS_HTTP:-none}"; exit 1
fi
summary "$LINE $(jq -r '"written=\(.written) eta_set=\(.eta_set)" + (if (.unknown_codes | length) > 0 then " unknown_codes=\(.unknown_codes | join(","))" else "" end)' "$TMP/post.json")"
exit 0
