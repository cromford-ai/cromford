#!/bin/bash
# bin/alerts-hygiene-sweep.sh — ONE-SHOT cleanup of the console Alerts screen
# after the V1 alert-hygiene reclassification (docs/ALERTS-STATE-MACHINE.md,
# "V1 alert hygiene"). NOT a lane and NOT on cron: the operator runs it once, by
# hand, on the hub, dry run first.
#
#   bin/alerts-hygiene-sweep.sh                # DRY RUN (default): counts + samples, resolves nothing
#   bin/alerts-hygiene-sweep.sh --check-prs    # also ask GitHub about PR-subject rows (one gh call per distinct PR)
#   bin/alerts-hygiene-sweep.sh --apply [...]  # resolve what the dry run lists, then re-count
#   bin/alerts-hygiene-sweep.sh --from-file F  # classify a saved GET /api/alerts/open body (offline, tests)
#
# WHAT IT RESOLVES — only rows whose class is now decided, each resolved with
# reason v1-<class> so the row says why it closed:
#   retired         the row's project, or a DOWN/SILENT line's box, is one
#                   fleet.conf retires (`# @retired`, bin/fleet-conf.sh --retired)
#   auth-probe-prose  a CLAUDE AUTH DOWN / AUTH PROBE INCONCLUSIVE whose only
#                   evidence was the model's MCP-plugin note (the 2026-09-23..25
#                   false pages; docs/AUTH-PROBE.md)
#   logonly         the line is a NOTICE (alert_state_logonly, BH-2337/BH-2381):
#                   HOTFIX seen/pr_open/merged, the admin-covered GH-token line,
#                   main GREEN again, N/N propagated. beat.sh drops it before it
#                   is noted, so an open row is a leftover from before that rule.
#                   A hotfix FAILURE line (APPLY FAILED, CLOSE-OUT OWED) is not a
#                   notice and is never swept here.
#   reclassified-*  the line now routes to info or warn (alert_state_route): a
#                   status event (account ran out + requeued, pool build
#                   DEFERRED + requeued) or a digest item. Such a line no longer
#                   opens a console row, so an open one is a leftover.
#   dup-dated       a date/hour-stamped akey (alert:<k>:YYYYMMDD, authprobe:<box>:
#                   YYYYMMDD, ...) that is NOT the newest row of its condition.
#                   The newest stays open: it is the live record until the
#                   condition's undated row supersedes it.
#   pr-closed       (--check-prs only) a merge-queue / rebase-train / blocked-
#                   resolver row about a PR GitHub reports MERGED or CLOSED.
# Everything else is left alone. A row it cannot classify is never resolved, and
# each row is counted once, under the first class that matches.
#
# DETERMINISTIC: no LLM anywhere. The classes come from the library the paging
# path uses (bin/lib/alert-state.sh), so the sweep and the router cannot
# disagree about what is an alert.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$BIN/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-$HARNESS}/env"; }
HENV=$(harness_env_dir "$HARNESS")
set -a; . "$HENV/global.env" 2>/dev/null; set +a
# shellcheck source=bin/lib/alert-state.sh
. "$BIN/lib/alert-state.sh" || { echo "alerts-hygiene-sweep: cannot load bin/lib/alert-state.sh" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "alerts-hygiene-sweep: jq is required" >&2; exit 2; }

APPLY=0; CHECK_PRS=0; FROM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --check-prs) CHECK_PRS=1 ;;
    --from-file) FROM="${2:?--from-file needs a path}"; shift ;;
    -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
    *) echo "alerts-hygiene-sweep: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
if [ "$APPLY" = 1 ] && [ -n "$FROM" ]; then
  echo "alerts-hygiene-sweep: --apply resolves live rows; it cannot run on --from-file" >&2; exit 2
fi

fetch_open() {
  if [ -n "$FROM" ]; then cat "$FROM"; return; fi
  if [ -z "${CONSOLE_URL:-}" ] || [ -z "${HARNESS_SECRET:-}" ]; then
    echo "alerts-hygiene-sweep: CONSOLE_URL / HARNESS_SECRET unset" >&2; return 1
  fi
  curl -s --max-time 30 -H "Authorization: Bearer $HARNESS_SECRET" "$CONSOLE_URL/api/alerts/open"
}

RESP=$(fetch_open) || exit 1
if ! jq -e '.alerts | type == "array"' >/dev/null 2>&1 <<<"$RESP"; then
  echo "alerts-hygiene-sweep: /api/alerts/open did not answer an alerts list" >&2; exit 1
fi
BEFORE=$(jq '.alerts | length' <<<"$RESP")
[ "$BEFORE" -ge 500 ] && echo "NOTE: the endpoint returns at most 500 rows; run again after --apply for the rest."

# Retired projects, from the registry only (never a list in this file).
# alert_state_retired_tokens drops any name that is still a live project/box.
RETIRED_PROJECTS=$(alert_state_retired_tokens)

# strip_prefixes <line> — the text the router saw: escalations are prefixed
# "[UNTRIAGED 45m] " by the console path, re-beats carry the ALERTS.log stamp.
strip_prefixes() { as_strip_stamp "$(printf '%s' "$1" | sed -E 's/^\[UNTRIAGED [0-9]+m\] //')"; }

AUTH_PROSE_RE=$(alert_cfg ALERTS_SWEEP_AUTH_PROSE_RE '(AUTH PROBE INCONCLUSIVE|AUTH DOWN).*(MCP server|plugin:vercel)')
PR_SUBJECT_RE=$(alert_cfg ALERTS_PR_SUBJECT_RE '^mq-|Merge queue: #|\[rebase-train\]|\[blocked-resolver\] ESCALATED')

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT
: > "$WORK/class.tsv"   # id \t class \t line
: > "$WORK/dated.tsv"   # id \t condition \t line
: > "$WORK/prs.tsv"     # id \t akey \t line

while IFS=$'\t' read -r ID AKEY PROJ LINE; do
  [ -n "$ID" ] || continue
  TXT=$(strip_prefixes "$LINE")
  case " $RETIRED_PROJECTS " in
    *" $PROJ "*) [ -n "$PROJ" ] && { printf '%s\tretired\t%s\n' "$ID" "$LINE" >> "$WORK/class.tsv"; continue; } ;;
  esac
  # The 2026-09-23..25 false auth pages: an AUTH DOWN / AUTH PROBE INCONCLUSIVE
  # whose only "evidence" was the model's note about an MCP plugin. The probe no
  # longer reads prose (docs/AUTH-PROBE.md), so no new ones fire; the open ones
  # are the incident's leftovers. Knob: ALERTS_SWEEP_AUTH_PROSE_RE.
  # ONLY after the box's canary has answered cleanly (review of #2291): a box
  # still listed in state/claude-auth-down.txt may genuinely be down, and a row
  # whose box cannot be named is left alone.
  if grep -qE "$AUTH_PROSE_RE" <<<"$TXT"; then
    ABOX=$(printf '%s' "$TXT" | sed -nE 's/.*\[auth\] ([A-Za-z0-9_.-]+) (CLAUDE AUTH DOWN|AUTH PROBE INCONCLUSIVE).*/\1/p; s/.*(CLAUDE AUTH DOWN|AUTH PROBE INCONCLUSIVE) on ([A-Za-z0-9_.-]+) box.*/\2/p' | head -1)
    if [ -n "$ABOX" ] && ! grep -qxF "$ABOX" "$HARNESS/state/claude-auth-down.txt" 2>/dev/null; then
      printf '%s\tauth-probe-prose\t%s\n' "$ID" "$LINE" >> "$WORK/class.tsv"
    fi
    continue
  fi
  if alert_state_logonly "$TXT"; then
    printf '%s\tlogonly\t%s\n' "$ID" "$LINE" >> "$WORK/class.tsv"; continue
  fi
  SEV=$(alert_state_route "$TXT" "")
  case "$SEV" in
    info|warn) printf '%s\treclassified-%s\t%s\n' "$ID" "$SEV" "$LINE" >> "$WORK/class.tsv"; continue ;;
  esac
  if [[ "$AKEY" =~ ^(.+):(20[0-9]{6})([0-9]{2})?$ ]]; then
    G="${BASH_REMATCH[1]}"
    # alert:<hash> hashed the LINE, so one condition split on prose; group
    # those on the state machine's condition id instead.
    case "$G" in alert:*) G="alert:$(alert_state_key "$TXT")" ;; esac
    printf '%s\t%s\t%s\n' "$ID" "$G" "$LINE" >> "$WORK/dated.tsv"
  fi
  if [ "$CHECK_PRS" = 1 ] && grep -qE "$PR_SUBJECT_RE" <<<"$(printf '%s\n%s\n' "$AKEY" "$TXT")"; then
    printf '%s\t%s\t%s\n' "$ID" "$AKEY" "$LINE" >> "$WORK/prs.tsv"
  fi
# "-" for an empty akey/project: tab is IFS whitespace, so an empty middle field
# would collapse and shift every column after it.
done < <(jq -r '.alerts[] | [(.id|tostring), ((.akey // "") | if . == "" then "-" else . end),
                               ((.project // "") | if . == "" then "-" else . end),
                               ((.line // "") | gsub("[\t\n\r]"; " "))] | @tsv' <<<"$RESP")

# dup-dated: every row of a dated condition except the newest (highest id).
if [ -s "$WORK/dated.tsv" ]; then
  sort -t$'\t' -k2,2 -k1,1nr "$WORK/dated.tsv" \
    | awk -F'\t' '$2 == g { print $1 "\tdup-dated\t" $3; next } { g = $2 }' >> "$WORK/class.tsv"
fi

# pr-closed: one GitHub question per distinct PR, asked only with --check-prs.
if [ "$CHECK_PRS" = 1 ] && [ -s "$WORK/prs.tsv" ]; then
  # shellcheck source=bin/lib/gh-app-auth.sh
  [ -r "$BIN/lib/gh-app-auth.sh" ] && . "$BIN/lib/gh-app-auth.sh"
  # REST, not `gh pr view` (BH-1585: GraphQL is the bucket nobody watched).
  # gh_rest_pr_state keeps "GitHub said closed" (rc 0) apart from "we could not
  # look" (44/75); only rc 0 with a state can settle a row.
  # shellcheck source=bin/lib/gh-rest.sh
  . "$BIN/lib/gh-rest.sh" 2>/dev/null || { echo "alerts-hygiene-sweep: cannot load bin/lib/gh-rest.sh" >&2; exit 2; }
  # shellcheck source=bin/lib/gh-rest-var.sh
  . "$BIN/lib/gh-rest-var.sh" 2>/dev/null || { echo "alerts-hygiene-sweep: cannot load bin/lib/gh-rest-var.sh" >&2; exit 2; }
  declare -A ST=()
  while IFS=$'\t' read -r ID AKEY LINE; do
    cut -f1 "$WORK/class.tsv" | grep -qx "$ID" && continue
    URL=$(grep -oiE 'github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' <<<"$LINE" | head -1)
    if [ -z "$URL" ] && [[ "$AKEY" =~ ^mq-[a-z-]+:([a-z0-9-]+):([0-9]+)$ ]]; then
      NUM="${BASH_REMATCH[2]}"
      SLUG=$("$BIN/fleet-conf.sh" "${BASH_REMATCH[1]}" repo 2>/dev/null)
      [ -n "$SLUG" ] && [ "$SLUG" != "-" ] && URL="github.com/$SLUG/pull/$NUM"
    fi
    [ -n "$URL" ] || continue
    if [ -z "${ST[$URL]+x}" ]; then
      command -v gh_auth_for_url >/dev/null 2>&1 && { gh_auth_for_url "https://$URL" || true; }
      PRSTATE=""
      if [[ "$URL" =~ github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([0-9]+)$ ]] \
         && gh_rest_pr_state_var PRSTATE "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" 2>/dev/null; then
        PRSTATE=$(printf '%s' "$PRSTATE" | tr '[:lower:]' '[:upper:]')
      else
        PRSTATE=""
      fi
      ST[$URL]=$PRSTATE
    fi
    PST="${ST[$URL]}"
    # A MERGE of an unreviewed head (mq-headbound) or a failing typecheck (mq-tc)
    # means that code reached main: not settled, worse. Only a close without
    # merge ends those — the same rule as bin/alerts-groom.sh rule 1.
    case "$AKEY" in mq-headbound:*|mq-tc:*) [ "$PST" = MERGED ] && PST="" ;; esac
    case "$PST" in MERGED|CLOSED) printf '%s\tpr-closed\t%s\n' "$ID" "$LINE" >> "$WORK/class.tsv" ;; esac
  done < "$WORK/prs.tsv"
fi

TOTAL=$(cut -f1 "$WORK/class.tsv" | sort -u | grep -c .)
echo "open before: $BEFORE"
echo "to resolve: $TOTAL"
cut -f2 "$WORK/class.tsv" | sort | uniq -c | sort -rn | sed 's/^ */  /'
echo "open after (projected): $((BEFORE - TOTAL))"
for C in $(cut -f2 "$WORK/class.tsv" | sort -u); do
  echo "sample [$C]:"
  awk -F'\t' -v c="$C" '$2 == c { print "  #" $1 "  " substr($3, 1, 150) }' "$WORK/class.tsv" | head -3
done

if [ "$APPLY" = 0 ]; then
  echo "DRY RUN — nothing resolved. Re-run with --apply to resolve the rows above."
  exit 0
fi

# Resolve class by class so each row records WHY (resolved_reason v1-<class>),
# 100 ids per request (the worker binds 100 parameters per statement).
RES=0
for C in $(cut -f2 "$WORK/class.tsv" | sort -u); do
  awk -F'\t' -v c="$C" '$2 == c { print $1 }' "$WORK/class.tsv" | sort -un > "$WORK/ids-$C"
  split -l 100 "$WORK/ids-$C" "$WORK/chunk-$C-"
  for F in "$WORK"/chunk-"$C"-*; do
    [ -s "$F" ] || continue
    BODY=$(jq -nc --argjson ids "$(jq -Rn '[inputs | tonumber]' < "$F")" --arg r "v1-$C" '{ids: $ids, reason: $r}')
    N=$(curl -s --max-time 30 -X POST -H "Authorization: Bearer $HARNESS_SECRET" -H 'Content-Type: application/json' \
          -d "$BODY" "$CONSOLE_URL/api/alerts/resolve" | jq -r '.resolved // 0' 2>/dev/null)
    case "$N" in ''|*[!0-9]*) N=0 ;; esac
    RES=$((RES + N))
  done
done
AFTER=$(fetch_open | jq '.alerts | length' 2>/dev/null)
echo "resolved: $RES"
echo "open after (measured): ${AFTER:-unknown}"
mkdir -p "$HARNESS/logs" 2>/dev/null
echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') v1 hygiene sweep: before=$BEFORE resolved=$RES after=${AFTER:-unknown}" \
  >> "$HARNESS/logs/alerts-groom.log" 2>/dev/null || true
