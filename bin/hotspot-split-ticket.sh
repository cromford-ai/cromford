#!/bin/bash
# bin/hotspot-split-ticket.sh [--dry-run] [--hotspots <json>]
# BH-6739 (BH-6543.2): a file that collides too often files its own split
# ticket, once. Hub only, weekly (cron/lanes/732-hotspot-split-ticket.cron).
# No LLM call.
#
# One run, for this deployment's repo (HARNESS_REPO, bin/lib/deployment.sh):
#   1. Dedupe lock locks/hotspot-split-ticket.lock: held = `skip: already
#      running`, exit 0.
#   2. Threshold: settings row hotspots.split_threshold. No row = 10. A value
#      that is not a whole number in 1..10000 STOPS the run (never clamped).
#   3. Max age: settings row hotspots.split_max_age_days. No row = 14. A value
#      that is not a whole number in 1..365 STOPS the run.
#   4. Input: GET /api/conflict-hotspots?project=<repo>&limit=10, the stored
#      output of `bin/conflict-hotspots.sh --ref origin/main --top 10` that the
#      box which owns the checkout PUTs weekly (bin/conflict-hotspots-fleet.sh).
#      The hub runs no git scan. --hotspots <json> reads a saved copy of that
#      answer instead (operator and test seam). The run STOPS when the stored
#      run is absent, names another repo, or its last_ok_at is older than the
#      max age (HOTSPOT_SPLIT_NOW, epoch seconds, pins the clock for tests).
#   5. A row with conflicts >= threshold is a candidate unless its path matches
#      a glob in catalog/list-files.tsv (`listed`; a `*` never crosses a `/`,
#      the bin/list-file-lint.sh rule).
#   6. GET /api/hotspot-tickets: a path with a row already has its ticket
#      (`recorded`). Then one contents read on main per candidate: 404 =
#      `gone` (it already left git), not filed; any other failure counts
#      `failed` and that path is not filed this run. One open-issue list: an
#      open issue whose body holds the marker
#      `<!-- harness-hotspot-split: <path> -->` is reused (`reused`).
#   7. Else ONE ai-build issue "Split <path>: <k> conflicts in <days> days",
#      body from prompts/hotspot-split-ticket.md, then PUT the row (`written`).
#      A failed create writes no row; a failed row write leaves the issue open,
#      and its marker stops a second issue next run. Both count `failed`.
#
# STOP (file nothing, one summary line with stopped=<why>, ONE warn alert,
# exit 0): threshold or max age unreadable or bad, measurement unreadable,
# never measured, repo mismatch, stale, bad output, no list catalog, ticket
# rows unreadable or truncated, issue list unknown or at its 1000 cap.
# A run with failed>0 sends the warn alert naming the paths; a clean run
# resolves it. --dry-run logs `would: file …` and writes nothing (no issue,
# row or alert).
#
# Summary line (logs/hotspot-split-ticket.log):
#   <ts> hotspot-split-ticket repo=<slug> ref=<sha12> threshold=<t> rows=<n>
#     over=<n> listed=<n> gone=<n> recorded=<n> filed=<n> reused=<n>
#     written=<n> failed=<n> dry_run=<0|1>[ stopped=<why>]
#
# Registry: catalog/lanes.d/hotspot-split-ticket.json (no knobs).
# OFF: flags/lane-off-hotspot-split-ticket (bin/harness-ctl.sh off hotspot-split-ticket).
# Doc: docs/notes/2026-10-15-BH-6739-hotspot-split-ticket.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
LANE=hotspot-split-ticket
TOP=10
ISSUE_CAP=1000
DRY=0; HOTSPOTS=""
usage() { echo "usage: hotspot-split-ticket.sh [--dry-run] [--hotspots <json>]" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --hotspots) [ $# -ge 2 ] || usage; HOTSPOTS=$2; shift 2 ;;
    *) usage ;;
  esac
done
mkdir -p "$H/logs" "$H/locks" 2>/dev/null
LOG="$H/logs/$LANE.log"
log() { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*" >> "$LOG"; }

# shellcheck source=bin/lib/lane-gate.sh
. "$H/bin/lib/lane-gate.sh" || exit 0
lane_gate_or_exit hotspot-split-ticket
lane_env_apply hotspot-split-ticket
# shellcheck source=bin/jobs-client.sh
. "$H/bin/jobs-client.sh" || exit 0
# shellcheck source=bin/lib/deployment.sh
. "$H/bin/lib/deployment.sh" || exit 0
# shellcheck source=bin/lib/gh-rest.sh
. "$H/bin/lib/gh-rest.sh" || exit 0
# shellcheck source=bin/lib/gh-rest-list.sh
. "$H/bin/lib/gh-rest-list.sh" || exit 0
# shellcheck source=bin/lib/gh-repo-token.sh
[ -r "$H/bin/lib/gh-repo-token.sh" ] && . "$H/bin/lib/gh-repo-token.sh"
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$H/bin/lib/gh-app-auth.sh" ] && . "$H/bin/lib/gh-app-auth.sh"

exec 9>"$H/locks/$LANE.lock"
if ! flock -n 9; then log "skip: already running"; exit 0; fi

SLUG="$HARNESS_REPO"
PROJECT="${SLUG#*/}"
W=$(mktemp -d "${TMPDIR:-/tmp}/$LANE.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT

REF=-; THR=-; ROWS=0; OVER=0; LISTED=0; GONE=0; RECORDED=0; FILED=0; REUSED=0; WRITTEN=0; NFAIL=0; FAILED_PATHS=""
alert() { [ "$DRY" = 1 ] || "$H/bin/lane-alert.sh" "$@" >/dev/null 2>&1 || true; }
summary() {
  local s="hotspot-split-ticket repo=$SLUG ref=$REF threshold=$THR rows=$ROWS over=$OVER listed=$LISTED gone=$GONE"
  s="$s recorded=$RECORDED filed=$FILED reused=$REUSED written=$WRITTEN failed=$NFAIL dry_run=$DRY${1:+ stopped=$1}"
  log "$s"; echo "$s"
}
# stop <why> <detail> — file nothing more, one summary line, one warn alert.
stop() {
  log "stop: $1: $2"
  summary "$1"
  alert --severity warn --id "$LANE" "$LANE" "Hotspot split tickets did not run ($1): $2. Nothing was filed. See logs/$LANE.log."
  exit 0
}

# ── 2. threshold ─────────────────────────────────────────────────────────────
rc=0; v=$(setting_get hotspots.split_threshold) || rc=$?
case "$rc" in
  0) ;;
  2) v=10 ;;
  *) stop threshold-unreadable "the settings row hotspots.split_threshold could not be read" ;;
esac
if ! [[ "$v" =~ ^[0-9]+$ ]] || [ "${#v}" -gt 5 ] || [ "$v" -lt 1 ] || [ "$v" -gt 10000 ]; then
  stop threshold "hotspots.split_threshold='$(printf '%s' "$v" | tr -cd '[:print:]' | cut -c1-40)' is not a whole number in 1..10000"
fi
THR=$v

# ── 3. max age ───────────────────────────────────────────────────────────────
rc=0; v=$(setting_get hotspots.split_max_age_days) || rc=$?
case "$rc" in
  0) ;;
  2) v=14 ;;
  *) stop max-age "the settings row hotspots.split_max_age_days could not be read" ;;
esac
if ! [[ "$v" =~ ^[0-9]{1,3}$ ]] || [ "$v" -lt 1 ] || [ "$v" -gt 365 ]; then
  stop max-age "hotspots.split_max_age_days='$(printf '%s' "$v" | tr -cd '[:print:]' | cut -c1-40)' is not a whole number in 1..365"
fi
MAXAGE=$v

# ── 4. the stored measurement ────────────────────────────────────────────────
if [ -n "$HOTSPOTS" ]; then
  [ -r "$HOTSPOTS" ] || stop measure-unreadable "$HOTSPOTS cannot be read"
  cp "$HOTSPOTS" "$W/hot.json"
else
  rc=0; _jobs_req GET "/api/conflict-hotspots?project=$PROJECT&limit=$TOP" > "$W/hot.json" || rc=$?
  [ "$rc" = 0 ] || stop measure-unreadable "GET /api/conflict-hotspots failed (http=${JOBS_HTTP:-none})"
fi
jq -e 'type == "object"' "$W/hot.json" >/dev/null 2>&1 || stop bad-output "the conflict-hotspots answer is not a JSON object"
jq -e '.run != null' "$W/hot.json" >/dev/null 2>&1 || stop never-measured "conflict-hotspots has no run for $PROJECT"
RUN_REPO=$(jq -r '.run.repo // ""' "$W/hot.json")
[ "$RUN_REPO" = "$SLUG" ] || stop repo-mismatch "the stored run is for '$(printf '%s' "$RUN_REPO" | cut -c1-100)', not $SLUG"
OK_AT=$(jq -r '.run.last_ok_at // ""' "$W/hot.json")
[ -n "$OK_AT" ] || stop never-measured "conflict-hotspots has no good run for $PROJECT"
OK_S=$(date -u -d "$OK_AT" +%s 2>/dev/null) || stop bad-output "last_ok_at='$(printf '%s' "$OK_AT" | cut -c1-40)' is not a time"
NOW_S="${HOTSPOT_SPLIT_NOW:-$(date -u +%s)}"
[ $((NOW_S - OK_S)) -le $((MAXAGE * 86400)) ] || stop stale "the last good measurement is from $OK_AT, older than $MAXAGE days"
REF=$(jq -r '.run.ref_sha // ""' "$W/hot.json" | cut -c1-12); DAYS=$(jq -r '.run.window_days // ""' "$W/hot.json")
[[ "$REF" =~ ^[0-9a-f]{7,12}$ ]] && [[ "$DAYS" =~ ^[0-9]+$ ]] || stop bad-output "the stored run has no ref sha or no window days"
jq -e '(.hotspots | type) == "array"' "$W/hot.json" >/dev/null 2>&1 || stop bad-output "the conflict-hotspots answer has no hotspots array"

# ── list catalog (rsynced from main by bin/harness-sync.sh) ──────────────────
cp "$H/catalog/list-files.tsv" "$W/list.tsv" 2>/dev/null || stop list-catalog "$H/catalog/list-files.tsv is missing"
GLOBS=()
while IFS=$'\t' read -r g _; do
  case "$g" in ''|'#'*) continue ;; esac
  GLOBS+=("$g")
done < "$W/list.tsv"
slashes() { local s="${1//[!\/]/}"; printf '%s' "${#s}"; }
# listed <path> — the bin/list-file-lint.sh match: same number of slashes, so a
# `*` never crosses a `/`, then the glob itself.
listed() {
  local g fs; fs=$(slashes "$1")
  for g in ${GLOBS[@]+"${GLOBS[@]}"}; do
    [ "$(slashes "$g")" = "$fs" ] || continue
    # shellcheck disable=SC2254 # the glob is the pattern on purpose
    case "$1" in $g) return 0 ;; esac
  done
  return 1
}
# present <path> — one contents read on main: rc 0 present, 44 gone, 75 unknown.
present() {
  local enc rc=0
  enc=$(jq -rn --arg p "$1" '$p | split("/") | map(@uri) | join("/")')
  GH_ETAG=0 gh_rest GET "repos/$SLUG/contents/$enc?ref=main" > "$W/contents.out" 2>/dev/null || rc=$?
  return "$rc"
}

# ── 5. candidates ───────────────────────────────────────────────────────────────
# The route orders conflicts desc, rebases desc, file asc; the first TOP rows.
jq -r --argjson top "$TOP" '.hotspots[:$top][] | [.file, (.conflicts | tostring), (.prs // "")] | @tsv' "$W/hot.json" > "$W/rows" \
  || stop bad-output "the hotspots rows cannot be read"
C_PATH=(); C_K=(); C_PRS=()
while IFS=$'\t' read -r p k prs; do
  ROWS=$((ROWS + 1))
  [[ "$k" =~ ^[0-9]{1,9}$ ]] || stop bad-output "row $ROWS has no whole-number conflicts count"
  [ "$k" -ge "$THR" ] || continue
  OVER=$((OVER + 1))
  if listed "$p"; then LISTED=$((LISTED + 1)); log "listed: $p"; continue; fi
  C_PATH+=("$p"); C_K+=("$k"); C_PRS+=("$prs")
done < "$W/rows"
if [ "${#C_PATH[@]}" = 0 ]; then
  summary; alert --resolve --id "$LANE" "$LANE" "Hotspot split tickets run again."; exit 0
fi

# ── 6. rows, then one open-issue list ────────────────────────────────────────
rc=0; _jobs_req GET "/api/hotspot-tickets?repo=$SLUG" > "$W/tickets.json" || rc=$?
[ "$rc" = 0 ] && jq -e '(.tickets | type) == "array"' "$W/tickets.json" >/dev/null 2>&1 \
  || stop rows-unreadable "GET /api/hotspot-tickets failed (http=${JOBS_HTTP:-none})"
jq -e '.truncated == false' "$W/tickets.json" >/dev/null 2>&1 || stop rows-truncated "GET /api/hotspot-tickets is truncated"
command -v gh_default_auth_for_slug >/dev/null 2>&1 && { gh_default_auth_for_slug "$SLUG" >/dev/null 2>&1 || true; }
ISS="$W/issues.json"; rc=0
gh_rest_issue_list "$SLUG" open "" "$ISSUE_CAP" > "$ISS" || rc=$?
[ "$rc" = 0 ] || stop issue-search "the open-issue list failed (HTTP $GH_REST_STATUS)"
[ "$(jq length "$ISS" 2>/dev/null)" -lt "$ISSUE_CAP" ] 2>/dev/null || stop issue-search "the open-issue list is at its $ISSUE_CAP cap or unreadable"

# ── body ─────────────────────────────────────────────────────────────────────
TPL="$H/prompts/hotspot-split-ticket.md"
[ -r "$TPL" ] || stop template "$TPL is missing"
# frag_example <path> — <dir>/<stem>.d/<ticket-key>-<name>.<ext>
frag_example() {
  local p="$1" d b stem ext=""
  d=$(dirname "$p"); b=$(basename "$p"); stem=$b
  case "$b" in ?*.*) stem=${b%.*}; ext=".${b##*.}" ;; esac
  [ "$d" = . ] && d="" || d="$d/"
  printf '%s%s.d/<ticket-key>-<name>%s, joined into %s by a build step' "$d" "$stem" "$ext" "$p"
}
pr_list() {
  local id n=0 extra=0
  local -a ids
  IFS=, read -r -a ids <<< "$1"
  for id in ${ids[@]+"${ids[@]}"}; do
    [ -n "$id" ] || continue
    n=$((n + 1)); [ "$n" -le 50 ] || { extra=$((extra + 1)); continue; }
    if [[ "$id" =~ ^#([0-9]+)$ ]]; then printf -- '- [#%s](https://github.com/%s/pull/%s)\n' "${BASH_REMATCH[1]}" "$SLUG" "${BASH_REMATCH[1]}"
    else printf -- '- `%s`\n' "$id"; fi
  done
  [ "$n" -gt 0 ] || printf -- '- none recorded\n'
  [ "$extra" = 0 ] || printf -- '- and %s more\n' "$extra"
}
LIST_EXAMPLES=$(awk -F'\t' '!/^#/ && NF >= 2 && $1 != "" { printf "- `%s`: `%s`\n", $1, $2 }' "$W/list.tsv")
# render <out> — the template with every {{KEY}} replaced by ENVIRON["HS_KEY"].
# ENVIRON and index(), never sed or gsub: a path can hold `/`, `&`, `|` or `\`.
render() {
  awk '{
    line = $0; out = ""
    while ((i = index(line, "{{")) > 0) {
      j = index(substr(line, i + 2), "}}")
      if (j == 0) break
      key = substr(line, i + 2, j - 1)
      out = out substr(line, 1, i - 1) (("HS_" key) in ENVIRON ? ENVIRON["HS_" key] : substr(line, i, j + 3))
      line = substr(line, i + j + 3)
    }
    print out line
  }' "$TPL" > "$1"
}

# ── 7. file, then write the row ──────────────────────────────────────────────
for idx in "${!C_PATH[@]}"; do
  p=${C_PATH[$idx]}; k=${C_K[$idx]}
  mark="<!-- harness-hotspot-split: $p -->"
  hit=$(jq -r --arg p "$p" '[.tickets[] | select(.path == $p) | .issue][0] // empty' "$W/tickets.json")
  if [ -n "$hit" ]; then RECORDED=$((RECORDED + 1)); log "recorded: $p #$hit"; continue; fi
  rc=0; present "$p" || rc=$?
  case "$rc" in
    0) ;;
    44) GONE=$((GONE + 1)); log "gone: $p"; continue ;;
    *) NFAIL=$((NFAIL + 1)); FAILED_PATHS="$FAILED_PATHS $p"
       log "contents read failed (HTTP $GH_REST_STATUS): $p; not filed this run"; continue ;;
  esac
  N=$(jq -r --arg m "$mark" '[.[] | select((.body // "") | contains($m)) | .number][0] // empty' "$ISS")
  title="Split $p: $k conflicts in $DAYS days"
  if [ -n "$N" ]; then
    REUSED=$((REUSED + 1)); log "reusing #$N for $p (open issue with its marker)"
  else
    B="$W/body.$idx"
    HS_MARKER=$mark HS_PATH=$p HS_CONFLICTS=$k HS_DAYS=$DAYS HS_REF=$REF HS_THRESHOLD=$THR \
      HS_PR_LIST=$(pr_list "${C_PRS[$idx]}") HS_FRAGMENT_EXAMPLE=$(frag_example "$p") HS_LIST_EXAMPLES=$LIST_EXAMPLES \
      render "$B"
    if [ "$DRY" = 1 ]; then log "would: file '$title' (ai-build)"; continue; fi
    OUT="$W/created.$idx"; rc=0
    gh_rest POST "repos/$SLUG/issues" -f "title=$title" -F "body=@$B" -f 'labels[]=ai-build' > "$OUT" || rc=$?
    N=$(jq -r '.number // empty' "$OUT" 2>/dev/null)
    if [ "$rc" != 0 ] || ! [[ "$N" =~ ^[1-9][0-9]*$ ]]; then
      NFAIL=$((NFAIL + 1)); FAILED_PATHS="$FAILED_PATHS $p"
      log "create failed (HTTP $GH_REST_STATUS): $p; no row without an issue"; continue
    fi
    FILED=$((FILED + 1)); log "filed #$N: $title"
    if ! jq -e '[.labels[]?.name] | index("ai-build")' "$OUT" >/dev/null 2>&1; then
      if ! gh_rest POST "repos/$SLUG/issues/$N/labels" -f 'labels[]=ai-build' > /dev/null; then
        NFAIL=$((NFAIL + 1)); FAILED_PATHS="$FAILED_PATHS $p"
        log "label failed (HTTP $GH_REST_STATUS): #$N has no ai-build label"
      fi
    fi
  fi
  [ "$DRY" = 1 ] && { log "would: write the row $p #$N"; continue; }
  body=$(jq -nc --arg r "$SLUG" --arg p "$p" --argjson n "$N" '{repo: $r, path: $p, issue: $n, actor: "hotspot-split-ticket"}')
  rc=0; _jobs_req PUT /api/hotspot-tickets "$body" > "$W/put.json" || rc=$?
  case "$rc" in
    0) WRITTEN=$((WRITTEN + 1)); log "recorded #$N for $p (http=$JOBS_HTTP)" ;;
    9) NFAIL=$((NFAIL + 1)); FAILED_PATHS="$FAILED_PATHS $p"
       log "row conflict: $p already records #$(jq -r '.row.issue // "?"' "$W/put.json" 2>/dev/null), not #$N" ;;
    *) NFAIL=$((NFAIL + 1)); FAILED_PATHS="$FAILED_PATHS $p"
       log "row write failed (http=${JOBS_HTTP:-none}): $p; #$N stays open and its marker stops a refile next run" ;;
  esac
done

summary
if [ "$NFAIL" -gt 0 ]; then
  alert --severity warn --id "$LANE" "$LANE" "Hotspot split tickets: $NFAIL path(s) failed:$FAILED_PATHS. See logs/$LANE.log."
else
  alert --resolve --id "$LANE" "$LANE" "Hotspot split tickets run again."
fi
exit 0
