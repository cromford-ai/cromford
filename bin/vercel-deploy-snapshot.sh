#!/bin/bash
# bin/vercel-deploy-snapshot.sh — hub cron (*/10): read-only Vercel deploy-state
# relay (the operator go: 2026-08-13, after the project-2 stale-prod incident).
#
# The watcher boxes hold NO Vercel credentials — any token grants the whole team
# (deploys + every project's env secrets), which is exactly what must not sit on
# a build box. Instead the hub polls the Vercel API and PUSHES a compact
# snapshot to each box over the existing hub->watcher ssh direction:
#   state/vercel-deploy-status.json
#     { generated_at, projects: { <project>: { domain, serving: {id,sha,age_h},
#       latest_ready: {id,sha,created}, domain_behind,
#       newest_prod: {id,state,sha,created_ms} | null,
#       prod_red: {since,sha,id} | null } } }
# prod_red (BH-8781) is set while the newest production deploy is ERROR; the
# merge conductor holds the project's READY PRs while it is set
# (bin/merge-conductor.d/bh-8781-prod-red-hold.sh), and the transition to red
# pages one person through page_critical.
# domain_behind=true means new READY production builds are NOT reaching the
# domain (the paused-promotion state after an Instant Rollback / manual pin) —
# a watcher seeing that should ALERT and park its deploy queue, never retry-loop.
# Vercel ACTIONS (promote/resume/env) stay hub-side: boxes write an ALERTS line
# asking the hub for help.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-vercel-deploy-snapshot
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off vercel-deploy-snapshot.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit vercel-deploy-snapshot
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    vercel-deploy-snapshot
# The page on a red production deploy (BH-8781). Both optional: a tree without
# page-critical.sh records the red state and pages nothing; deployment.sh names
# the operator (HARNESS_GIT_EMAIL) in the page line.
# shellcheck source=bin/lib/page-critical.sh
. "$HARNESS/bin/lib/page-critical.sh" 2>/dev/null || page_critical() { return 0; }
# shellcheck source=bin/lib/deployment.sh
. "$HARNESS/bin/lib/deployment.sh" 2>/dev/null || HARNESS_GIT_EMAIL=operator
CONF="$HARNESS/vercel.conf"
OUT="$HARNESS/state/vercel-deploy-status.json"
LOG="$HARNESS/logs/vercel-snapshot.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

# Token comes from the hub's device-flow CLI auth; never echoed, never shipped.
# Access tokens expire ~9h and only a CLI invocation runs the refresh-token
# flow (2026-08-14 empty-snapshot incident: every API call 403'd invalidToken
# after 22:02Z expiry). Nudge the CLI when expiry is <20min out or past.
# VERCEL_CLI_AUTH is a test seam (BH-8545); the cron does not set it.
VERCEL_CLI_AUTH="${VERCEL_CLI_AUTH:-/root/.local/share/com.vercel.cli/auth.json}"
EXP=$(jq -r '.expiresAt // 0' "$VERCEL_CLI_AUTH" 2>/dev/null || echo 0)
if [ "${EXP:-0}" -lt $(( $(date -u +%s) + 1200 )) ]; then
  (cd /tmp && timeout 60 npx -y vercel@latest whoami >/dev/null 2>&1)
fi
TOK=""
for f in "$VERCEL_CLI_AUTH" /root/.vercel/auth.json; do
  [ -s "$f" ] && TOK=$(jq -r '.token // empty' "$f" 2>/dev/null) && [ -n "$TOK" ] && break
done
if [ -z "$TOK" ]; then
  echo "$(STAMP) [vercel-snapshot] Vercel CLI auth missing/expired on hub — snapshot skipped" >> "$HARNESS/logs/ALERTS.log"
  exit 0
fi

api() { curl -sf --max-time 20 -H "Authorization: Bearer $TOK" "https://api.vercel.com$1"; }

NOW=$(date -u +%s)
SNAP='{}'
FAILED=""
# PRODUCTION RED (BH-8781). The previous snapshot carries the red streak from
# run to run: .projects[<p>].prod_red = {since, sha, id} while the newest
# production deploy is red, null once the newest finished one is READY.
PREV=$(jq -c '.projects // {} | if type == "object" then . else {} end' "$OUT" 2>/dev/null) || PREV='{}'
[ -n "$PREV" ] || PREV='{}'
# The page TTL: one page per project per this many seconds.
# fallback 86400: settings row lane.vercel-deploy-snapshot.prod_red_repage_s (catalog/lanes.d/vercel-deploy-snapshot.knobs.d/PROD_RED_REPAGE_S.json)
REPAGE_S="${PROD_RED_REPAGE_S:-86400}"
case "$REPAGE_S" in ''|*[!0-9]*|0*) REPAGE_S=86400 ;; esac
# prod_red_next <newest-json, or "" when the read failed> <previous project json>
#   -> {newest_prod, prod_red}. ERROR is red (the streak keeps its first since);
#   READY or no production deploy is green; any other state (BUILDING, QUEUED,
#   CANCELED) leaves production as it was; a failed read carries both keys.
prod_red_next() {
  jq -nc --arg n "$1" --argjson pv "${2:-null}" '
    ($pv // {}) as $pv
    | if $n == "" then {newest_prod: ($pv.newest_prod // null), prod_red: ($pv.prod_red // null)}
      else ($n | fromjson) as $d
      | if ($d | type) != "object" or $d == {} then {newest_prod: null, prod_red: null}
        else ($d.state // $d.readyState // "") as $st
        | (($d.createdAt // $d.created // 0) | if type == "number" then . else 0 end) as $c
        | (($d.meta.githubCommitSha // "") | .[0:8]) as $sha
        | {newest_prod: {id: ($d.uid // ""), state: $st, sha: $sha, created_ms: $c},
           prod_red: (if $st == "ERROR" then
                        {since: ($pv.prod_red.since // (($c / 1000) | floor | todate)), sha: $sha, id: ($d.uid // "")}
                      elif $st == "READY" then null
                      else ($pv.prod_red // null) end)}
        end
      end' 2>/dev/null
}
REDNEW=""
# Per-project preview files (2026-08-13): wait-preview.sh resolves QA preview
# URLs from these now that the GitHub Deployments API 403s the fleet PAT.
# fly-pool.sh mputs the per-project file onto live pool machines each tick.
PREVDIR="$HARNESS/state/vercel-deploys"
mkdir -p "$PREVDIR"
while read -r p team pid domain; do
  case "$p" in ''|'#'*) continue;; esac
  # Recent PREVIEW deployments for the project: {sha,url,state,createdAt}.
  # Same auth pattern as the rest of this script (hub CLI token, read-only);
  # the snapshot carries deployment metadata ONLY — never a token.
  PREVIEWS=$(api "/v6/deployments?projectId=$pid&teamId=$team&target=preview&limit=30" \
    | jq -c '[.deployments[]?
        | {sha: (.meta.githubCommitSha // ""),
           url: (if (.url // "") == "" then "" else "https://" + .url end),
           state: (.state // .readyState // ""),
           createdAt: (.created // .createdAt // 0)}
        | select(.sha != "" and .url != "")]' 2>/dev/null) || PREVIEWS='[]'
  [ -n "$PREVIEWS" ] || { PREVIEWS='[]'; FAILED="$FAILED $p:previews"; }
  jq -nc --arg ts "$(STAMP)" --arg p "$p" --argjson prevs "$PREVIEWS" \
    '{generated_at:$ts, project:$p, previews:$prevs}' > "$PREVDIR/$p.json.tmp" \
    && mv "$PREVDIR/$p.json.tmp" "$PREVDIR/$p.json"
  # What the prod domain actually serves right now.
  ALIAS=$(api "/v4/aliases/$domain?teamId=$team") || { FAILED="$FAILED $p:alias"; continue; }
  SID=$(echo "$ALIAS" | jq -r '.deploymentId // .deployment.id // empty')
  SDEP=$(api "/v13/deployments/$SID?teamId=$team" 2>/dev/null)
  SSHA=$(echo "$SDEP" | jq -r '.gitSource.sha // .meta.githubCommitSha // ""' | cut -c1-8)
  SCREATED=$(echo "$SDEP" | jq -r '.createdAt // 0')
  # Newest READY production build for the project.
  LATEST=$(api "/v6/deployments?projectId=$pid&teamId=$team&target=production&state=READY&limit=1" | jq -c '.deployments[0] // {}') || LATEST='{}'
  LID=$(echo "$LATEST" | jq -r '.uid // ""')
  LSHA=$(echo "$LATEST" | jq -r '.meta.githubCommitSha // ""' | cut -c1-8)
  LCREATED=$(echo "$LATEST" | jq -r '.createdAt // 0')
  # The NEWEST production deploy, any state (BH-8781): ERROR here is a red prod.
  NEWEST=$(api "/v6/deployments?projectId=$pid&teamId=$team&target=production&limit=1" | jq -c '.deployments[0] // {}' 2>/dev/null) || NEWEST=""
  [ -n "$NEWEST" ] || FAILED="$FAILED $p:newest"
  PPREV=$(jq -c --arg p "$p" '.[$p] // null' <<<"$PREV" 2>/dev/null) || PPREV=null
  RED=$(prod_red_next "$NEWEST" "${PPREV:-null}") && [ -n "$RED" ] || RED='{"newest_prod":null,"prod_red":null}'
  # The transition to red: no red record before, one now.
  if [ "$(jq -r '.prod_red != null' <<<"$RED")" = true ] && [ "$(jq -r '(.prod_red // null) == null' <<<"${PPREV:-null}" 2>/dev/null)" != false ]; then
    REDNEW="$REDNEW $p"
  fi
  BEHIND=false
  [ -n "$LID" ] && [ -n "$SID" ] && [ "$LID" != "$SID" ] && [ "$LCREATED" -gt "$SCREATED" ] && BEHIND=true
  AGE_H=$(( (NOW - SCREATED/1000) / 3600 ))
  # previews ride in the combined snapshot too: the existing hub->watcher push
  # is one file, and wait-preview.sh falls back to .projects[<p>].previews there.
  SNAP=$(echo "$SNAP" | jq -c --arg p "$p" --arg d "$domain" --arg sid "$SID" --arg ssha "$SSHA" \
    --argjson sage "$AGE_H" --arg lid "$LID" --arg lsha "$LSHA" --argjson lc "$LCREATED" --argjson b "$BEHIND" \
    --argjson prevs "$PREVIEWS" --argjson red "$RED" \
    '.[$p] = {domain:$d, serving:{id:$sid, sha:$ssha, age_h:$sage}, latest_ready:{id:$lid, sha:$lsha, created_ms:$lc}, domain_behind:$b, previews:$prevs} + $red')
done < "$CONF"

FINAL=$(jq -nc --arg ts "$(STAMP)" --argjson pr "$SNAP" '{generated_at:$ts, projects:$pr}')
mkdir -p "$(dirname "$OUT")"
printf '%s\n' "$FINAL" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

# Page ONE person per project on the transition to red (BH-8781), AFTER the
# record is written: a crash between the two loses a page, never storms, since
# the next run's PREV already carries the red record. page_critical dedupes on
# prodred:<p> for REPAGE_S and stamps before it sends.
for p in $REDNEW; do
  IFS=$'\t' read -r rsince rsha rid < <(jq -r --arg p "$p" '.projects[$p].prod_red | [.since, .sha, .id] | @tsv' <<<"$FINAL")
  PAGE_LANE=prod-red page_critical "$REPAGE_S" "prodred:$p" \
    "PROD RED $p: the newest production deploy failed (Vercel $rid, commit $rsha, since $rsince). The merge queue for $p holds every READY PR until a production deploy is READY. Owner: $HARNESS_GIT_EMAIL. To merge the fix through the hold, label its PR with the main-red label (fix-main-red by default) or hotfix." \
    "$p" </dev/null >/dev/null 2>&1 || true
done

# Push to the watcher boxes (hub->watcher is the only allowed ssh direction).
# The targets are the boxes that own vercel.conf's projects, read from fleet.conf
# through bin/box-for.sh (BH-4080: no literal hostnames), each once. `local` is
# the hub, which just wrote its own copy above.
# The ssh HOST is bin/box-host.sh's answer, the fleet.conf tailnet IP (BH-8545:
# the project-1 box's tailnet name pointed at a dead device, so every push to
# `root@<name>` timed out and its snapshot froze). PUSHED still names boxes.
#
# FAIL STREAK (BH-8545). One file per box, state/vercel-snapshot-push-fail/<box>,
# holds the count of failed pushes in a row; a success deletes it. When the
# count reaches VERCEL_PUSH_FAIL_STREAK exactly, ONE ALERTS line names the box,
# the host and the first ssh error line. The next line needs a new streak.
# fallback 3: settings row lane.vercel-deploy-snapshot.vercel_push_fail_streak (catalog/lanes.d/vercel-deploy-snapshot.json)
STREAK_N="${VERCEL_PUSH_FAIL_STREAK:-3}"
case "$STREAK_N" in ''|*[!0-9]*|0*) STREAK_N=3 ;; esac
# The ssh error in that line is cut to this many characters.
# fallback 200: settings row lane.vercel-deploy-snapshot.vercel_push_err_chars (catalog/lanes.d/vercel-deploy-snapshot.json)
ERR_CHARS="${VERCEL_PUSH_ERR_CHARS:-200}"
case "$ERR_CHARS" in ''|*[!0-9]*|0*) ERR_CHARS=200 ;; esac
# The streak dir is classed box-local in catalog/state-paths.json: only the hub
# runs this lane, a count is about this hub's ssh path, and losing it on a hub
# move only delays one alert by a streak. One file per box, deleted on success.
STREAK_DIR="$HARNESS/state/vercel-snapshot-push-fail"
mkdir -p "$STREAK_DIR" 2>/dev/null
# The ssh stderr of one push is per-run scratch: a temp file, never state/.
PUSH_ERR=$(mktemp "${TMPDIR:-/tmp}/vercel-push-err.XXXXXX" 2>/dev/null) || PUSH_ERR=/dev/null
trap '[ "$PUSH_ERR" = /dev/null ] || rm -f "$PUSH_ERR"' EXIT
PUSHED=""
TARGETS=""
while read -r p _; do
  case "$p" in ''|'#'*) continue;; esac
  b=$("$HARNESS/bin/box-for.sh" "$p" 2>/dev/null) || { FAILED="$FAILED box-for:$p"; continue; }
  [ -n "$b" ] && [ "$b" != local ] || continue
  case " $TARGETS " in *" $b "*) ;; *) TARGETS="$TARGETS $b" ;; esac
done < "$CONF"
for h in $TARGETS; do
  host=$("$HARNESS/bin/box-host.sh" "$h" 2>/dev/null) && [ -n "$host" ] || host="$h"
  timeout 25 ssh -o ConnectTimeout=8 -o BatchMode=yes "root@$host" \
      "cat > /root/harness/state/.vercel-deploy-status.json.tmp && mv /root/harness/state/.vercel-deploy-status.json.tmp /root/harness/state/vercel-deploy-status.json" \
      < "$OUT" 2>"$PUSH_ERR"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    PUSHED="$PUSHED $h"
    rm -f "$STREAK_DIR/$h"
    continue
  fi
  FAILED="$FAILED push:$h@$host"
  n=$(cat "$STREAK_DIR/$h" 2>/dev/null) || n=0
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$((10#$n + 1))
  printf '%s\n' "$n" > "$STREAK_DIR/.$h.tmp" 2>/dev/null && mv "$STREAK_DIR/.$h.tmp" "$STREAK_DIR/$h" 2>/dev/null || continue
  [ "$n" -eq "$STREAK_N" ] || continue
  err=$(head -1 "$PUSH_ERR" 2>/dev/null | tr -d '\r' | cut -c1-"$ERR_CHARS")
  [ -n "$err" ] || err="no ssh output (rc $rc)"
  "$HARNESS/bin/alert-line.sh" --id "vercel-snapshot-push-$h" \
    "[vercel-snapshot] push to $h failed $n runs in a row: host $host: $err" >/dev/null 2>&1 || true
done

BEHINDLIST=$(echo "$FINAL" | jq -r '[.projects | to_entries[] | select(.value.domain_behind) | .key] | join(",")')
REDLIST=$(echo "$FINAL" | jq -r '[.projects | to_entries[] | select(.value.prod_red != null) | .key] | join(",")')
echo "$(STAMP) pushed:${PUSHED:- none} behind:[${BEHINDLIST}] prodred:[${REDLIST}]${FAILED:+ FAILED:$FAILED}" >> "$LOG"
