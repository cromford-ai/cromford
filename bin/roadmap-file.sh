#!/bin/bash
# bin/roadmap-file.sh — BH-7267 (BH-7243.4): file an approved roadmap wave's
# slices as `ai-build` GitHub issues. A hub lane, every 5 minutes
# (cron/lanes/743-roadmap-file.cron).
#
# WHY. An operator approves a `draft` wave in the console
# (POST /api/roadmap/waves/approve). This lane turns each slice of the draft
# into one GitHub issue and links each issue to the wave's source ideas in
# roadmap_links, so the build queue picks the slices up and the roadmap board
# can show them. Routes: worker/jobs/src/routes/roadmap-wave-file.js.
#
# ONE TICK:
#   1. lane_gate_or_exit / lane_env_apply roadmap-file. flock -n
#      locks/roadmap-file.lock.
#   2. Up to ROADMAP_FILE_MAX_PER_TICK times: POST /api/roadmap/waves/file-claim
#      {box}. {wave:null} ends the tick. The claim moves the wave
#      approved -> filing.
#   3. A project with a board_api_prefix (an in-app board, not GitHub Issues):
#      file-done {status:approved, error:"board not GitHub Issues"}, one warn
#      alert, no GitHub call.
#   4. For slice k = 1..n: ONE search for the body marker
#      `<!-- harness-roadmap-slice: <wave_id>/<k> -->`. A result whose body
#      holds that exact line and that is not a PR is reused (a crashed run
#      created it). Else ONE create with the label ai-build; the body ends with
#      the marker. `Blocked-by: #<n>` lines map the slice's blocked_by
#      positions through this run's slice -> issue map; a position that is not
#      earlier than k, or has no issue, is skipped and logged. Then
#      POST /api/roadmap/waves/filed {id, slice, repo, issue}.
#      A search or create that fails: file-done {status:approved,
#      error:"slice k: http <status>"}, one warn alert, next wave. A rate limit
#      (rc 75, reason rate-limit) also ends the tick. A failed `filed` write:
#      file-done approved with that error, next wave.
#   5. Every slice linked: file-done {status:filed}. A 409 there: one warn
#      alert, the wave stays `filing` and the reclaim path heals it.
#   6. One line in logs/roadmap-file.log for a tick that did work:
#      <ts> waves=<n> filed=<n> created=<n> reused=<n> failed=<n>
#
# --dry-run: the claim is sent with dry_run:true (no write), one wave only, the
# marker searches run, and each would-be issue JSON is printed on stdout. No
# POST to GitHub and no write route.
#
# The lane writes nothing under flags/. Its alerts carry the stable id
# roadmap-file:<wave_id>, so a retried wave does not add a second alert.
#
# OFF: flags/lane-off-roadmap-file or bin/harness-ctl.sh off roadmap-file.
# Registry: catalog/lanes.d/roadmap-file.json.
#
# gh-rest: no-graphql
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
  . "$SELF/lib/gh-rest.sh" 2>/dev/null || true
}
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$SELF/lib/deployment.sh}" 2>/dev/null || exit 0
command -v _jobs_req >/dev/null 2>&1 && command -v gh_rest >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || exit 0
# Through bin/gh-rest-shim when it is installed, else gh api direct.
if [ -x "$SELF/gh-rest-shim" ]; then gh() { "$SELF/gh-rest-shim" "$@"; }; fi

LOG="$H/logs/roadmap-file.log"
mkdir -p "$H/logs" "$H/locks" 2>/dev/null
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }
# knob <name> <value> <default> <lo> <hi>: an integer in range, else one warn line and the default.
knob() {
  if [[ $2 =~ ^[0-9]+$ ]] && [ "$2" -ge "$4" ] && [ "$2" -le "$5" ]; then printf '%s' "$2"; return; fi
  log "warn: $1=$2 is not an integer in $4..$5; using the default $3"
  printf '%s' "$3"
}
# rest <out-file> <method> <path> [args...]: one gh_rest call into a file (never
# a $( ), so GH_REST_STATUS survives); RC is its rc.
rest() { RC=0; gh_rest "$2" "$3" "${@:4}" > "$1" 2>/dev/null || RC=$?; }

alert() { # alert <wave_id> <text>
  "$H/bin/lane-alert.sh" --id "roadmap-file:$1" --severity warn roadmap-file "$2" >/dev/null 2>&1 \
    || log "$1: the warn alert could not be sent"
}
# done_approved <wave_id> <error>: the wave goes back to approved with the error.
done_approved() {
  local body resp rc
  body=$(jq -nc --arg id "$1" --arg e "${2:0:500}" '{id:$id, status:"approved", error:$e}')
  resp=$(_jobs_req POST /api/roadmap/waves/file-done "$body"); rc=$?
  [ "$rc" = 0 ] || log "$1: file-done approved failed (http ${JOBS_HTTP:-none}): ${resp:0:200}"
}
# fail_wave <wave_id> <error>: approved + error, one warn alert, failed+=1.
fail_wave() {
  log "$1: $2"
  done_approved "$1" "$2"
  alert "$1" "wave $1 was not filed: $2"
  FAILED=$((FAILED + 1))
}

# issue_json <slice-json> <wave_id> <k> <out>: the create payload. Blocked-by
# lines come from MAP (this run's slice -> issue numbers).
issue_json() {
  local s="$1" wid="$2" k="$3" out="$4" p blocked="" pos
  pos=$(jq -r '.blocked_by // [] | .[] | tostring' <<<"$s" 2>/dev/null)
  for p in $pos; do
    if [[ $p =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -lt "$k" ] && [ -n "${MAP[$p]:-}" ]; then
      blocked+="Blocked-by: #${MAP[$p]}"$'\n'
    else
      log "$wid: slice $k: blocked_by $p is not an earlier slice with an issue; skipped"
    fi
  done
  jq -n --argjson s "$s" --arg wid "$wid" --arg k "$k" --arg blocked "${blocked%$'\n'}" '
    def items($a): if (($a // []) | length) == 0 then ["- none"] else [($a // [])[] | "- \(.)"] end;
    ($s.title // "" | tostring) as $t
    | {title: (if ($t | length) > 256 then $t[0:250] + "…" else $t end),
       labels: ["ai-build"],
       body: ([($s.body // "" | tostring), "",
               "## Acceptance tests"] + items($s.acceptance_tests) + ["",
               "## Spec refs"] + items($s.spec_refs) + ["",
               "## Files"] + items($s.files) + ["",
               "## Seam files"] + items($s.seam_files) + [""]
              + (if $blocked == "" then [] else [$blocked, ""] end)
              + ["Part of roadmap wave \($wid)",
                 "<!-- harness-roadmap-slice: \($wid)/\($k) -->"] | join("\n"))}' > "$out"
}

# file_wave <claim-json>: file one claimed wave. rc 2 = end the tick.
file_wave() {
  local c="$1" wid repo prefix n k s marker f found num body resp rc
  wid=$(jq -r '.wave.id' <<<"$c"); repo=$(jq -r '.repo // ""' <<<"$c"); prefix=$(jq -r '.board_api_prefix // ""' <<<"$c")
  WAVES=$((WAVES + 1))
  if [ -n "$prefix" ]; then
    [ "$DRY" = 1 ] && { echo "wave $wid: board not GitHub Issues; nothing to file"; return 0; }
    fail_wave "$wid" "board not GitHub Issues"; return 0
  fi
  if ! [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    [ "$DRY" = 1 ] && { echo "wave $wid: project has no GitHub repo"; return 0; }
    fail_wave "$wid" "project has no GitHub repo"; return 0
  fi
  n=$(jq -r '.wave.draft.slices // [] | length' <<<"$c" 2>/dev/null)
  if ! [[ $n =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ]; then
    [ "$DRY" = 1 ] && { echo "wave $wid: draft has no slices"; return 0; }
    fail_wave "$wid" "draft has no slices"; return 0
  fi
  MAP=()
  for ((k = 1; k <= n; k++)); do
    s=$(jq -c --argjson i "$((k - 1))" '.wave.draft.slices[$i]' <<<"$c")
    marker="<!-- harness-roadmap-slice: $wid/$k -->"
    f="$TMPD/search.$k.json"
    rest "$f" GET search/issues -f "q=repo:$repo in:body \"harness-roadmap-slice: $wid/$k\""
    if [ "$RC" != 0 ]; then
      [ "$DRY" = 1 ] && { echo "wave $wid: slice $k: search http ${GH_REST_STATUS:-000}"; return 2; }
      fail_wave "$wid" "slice $k: http ${GH_REST_STATUS:-000}"
      [ "$RC" = 75 ] && [ "${GH_REST_REASON:-}" = rate-limit ] && return 2
      return 0
    fi
    # The exact marker line, never a substring: `.../12 -->` is not slice 1.
    found=$(jq -r --arg mk "$marker" '[.items // [] | .[]
      | select(has("pull_request") | not)
      | select((.body // "") | split("\n") | map(sub("\r$"; "")) | index($mk) != null)
      | .number] | first // empty' "$f" 2>/dev/null)
    if [[ $found =~ ^[0-9]+$ ]]; then
      num=$found; REUSED=$((REUSED + 1))
      [ "$DRY" = 1 ] && echo "wave $wid: slice $k: reuses #$num"
    else
      body="$TMPD/issue.$k.json"
      issue_json "$s" "$wid" "$k" "$body" || { fail_wave "$wid" "slice $k: the issue body could not be built"; return 0; }
      if [ "$DRY" = 1 ]; then jq -c . "$body"; continue; fi
      f="$TMPD/create.$k.json"
      rest "$f" POST "repos/$repo/issues" --input "$body"
      num=$(jq -r '.number // empty' "$f" 2>/dev/null)
      if [ "$RC" != 0 ] || ! [[ $num =~ ^[0-9]+$ ]]; then
        fail_wave "$wid" "slice $k: http ${GH_REST_STATUS:-000}"
        [ "$RC" = 75 ] && [ "${GH_REST_REASON:-}" = rate-limit ] && return 2
        return 0
      fi
      CREATED=$((CREATED + 1))
    fi
    MAP[$k]=$num
    [ "$DRY" = 1 ] && continue
    resp=$(_jobs_req POST /api/roadmap/waves/filed "$(jq -nc --arg id "$wid" --argjson k "$k" --arg r "$repo" --argjson n "$num" '{id:$id, slice:$k, repo:$r, issue:$n}')"); rc=$?
    if [ "$rc" != 0 ]; then
      fail_wave "$wid" "slice $k: the link write for #$num failed (http ${JOBS_HTTP:-none})"
      return 0
    fi
  done
  [ "$DRY" = 1 ] && return 0
  resp=$(_jobs_req POST /api/roadmap/waves/file-done "$(jq -nc --arg id "$wid" '{id:$id, status:"filed"}')"); rc=$?
  if [ "$rc" = 0 ]; then
    FILED=$((FILED + 1))
  else
    log "$wid: file-done filed failed (http ${JOBS_HTTP:-none}): ${resp:0:200}; the wave stays filing"
    alert "$wid" "wave $wid: every slice has an issue, but file-done filed answered http ${JOBS_HTTP:-none}; it stays filing"
    FAILED=$((FAILED + 1))
  fi
  return 0
}

tick() {
  command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit roadmap-file
  command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply roadmap-file
  exec 9>"$H/locks/roadmap-file.lock" || exit 0
  flock -n 9 || exit 0
  mkdir -p "$H/state/roadmap-file" 2>/dev/null
  TMPD=$(mktemp -d "$H/state/roadmap-file/tick.XXXXXX") || exit 0
  # shellcheck disable=SC2064
  trap "case '$TMPD' in '$H/state/roadmap-file/'?*) rm -rf '$TMPD' ;; esac" EXIT

  local max box i c rc claim
  max=$(knob ROADMAP_FILE_MAX_PER_TICK "${ROADMAP_FILE_MAX_PER_TICK:-3}" 3 1 20)
  [ "$DRY" = 1 ] && max=1
  box="$JOBS_BOX"  # the jobs client sets it (bin/lib/jobs/req.sh); the script exits above without the client
  WAVES=0; FILED=0; CREATED=0; REUSED=0; FAILED=0
  for ((i = 0; i < max; i++)); do
    if [ "$DRY" = 1 ]; then claim=$(jq -nc --arg b "$box" '{box:$b, dry_run:true}')
    else claim=$(jq -nc --arg b "$box" '{box:$b}'); fi
    c=$(_jobs_req POST /api/roadmap/waves/file-claim "$claim"); rc=$?
    if [ "$rc" != 0 ] || ! jq -e 'has("wave")' <<<"$c" >/dev/null 2>&1; then
      log "file-claim failed (http ${JOBS_HTTP:-none}); no wave this tick"
      break
    fi
    jq -e '.wave | type == "object"' <<<"$c" >/dev/null 2>&1 || break
    rc=0; file_wave "$c" || rc=$?
    [ "$rc" = 2 ] && break
  done
  if [ "$DRY" != 1 ] && [ "$WAVES" != 0 ]; then
    log "waves=$WAVES filed=$FILED created=$CREATED reused=$REUSED failed=$FAILED"
  fi
}

case "${1:-}" in
  '') DRY=0; tick ;;
  --dry-run) DRY=1; tick ;;
  *) echo "usage: roadmap-file.sh [--dry-run]" >&2; exit 2 ;;
esac
exit 0
