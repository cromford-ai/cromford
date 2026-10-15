#!/bin/bash
# bin/staff/dispatcher-collect.sh — Dispatcher's collector. bin/staff.sh runs
# it at step 6 of `staff.sh tick dispatcher` and claims what it prints.
# Deterministic: no model call, no gh call. Its only writes are its page
# markers and the page itself.
#
# It reads the declarations in catalog/staff-feeds.d/<id>.json, one per file:
#   {"id","kind":"feed","lane","max_age_h","probe":{"path","at"},"note"}
#   {"id","kind":"output","project","window_h","probe":{"path","at"},"note"}
# A probe is `GET <path>` on the jobs worker, then the jq expression <at> on
# the answer: the time of the newest success (feed) or output record
# (output). It must answer ONE ISO time or epoch (s or ms). null or "" =
# never. Anything else, or a failed GET, is UNREADABLE: one log line, that
# declaration is skipped, and it is never read as "never".
#
#   dead-feed           L = the feed's probe time. Fires when L is never, or
#                       now - L > max_age_h hours.
#   post-deploy-output  D = the newest VERIFIED deploy of the output's
#                       project (D1 ledgers kind deploy, bin/deploy-train.sh)
#                       inside DSP_DEPLOY_LOOKBACK_H; its time is
#                       detail.verified_at // detail.departure // created_at.
#                       O = the output's probe time. Fires when now - D >=
#                       window_h hours and O is never or O < D. It reads the
#                       OUTPUT, never a lane rc: a zero-work success is not
#                       output.
# A post-deploy finding also pages ONCE per (output, deploy): bin/lane-alert.sh
# --id staff-dispatcher-postdeploy-<id>-<D epoch> --severity DSP_PAGE_SEVERITY,
# then the marker state/staff/dispatcher/paged/<id>.<D epoch>. The deploy is in
# the alert id, so lane-alert never suppresses a new deploy's page as a repeat
# of the last one. Markers older than DSP_DEPLOY_LOOKBACK_H are deleted: a
# marker is never older than its deploy, and a deploy past the lookback is
# never checked again.
#
# The item holds the check, the id and a time, and no hour count: the claim
# fingerprints the item, so one outage is one finding. Output is sorted by
# (check, id), so the same reads print the same bytes.
#
# rc 0: lines or none (some probes may be unreadable). rc 1: every probe
# unreadable, the deploy ledger unreadable with an output declared, or jq or
# the jobs client missing; nothing printed, nothing paged.
#
# Knobs: catalog/lanes.d/_lib.staff-dispatcher.json, applied with
# lib_env_apply staff-dispatcher. Out of range is one warn line in
# logs/staff.log and the default, never a clamp.
# Note: docs/notes/2026-10-14-BH-5566-dispatcher.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
BIN="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
{
  . "$BIN/lib/lane-gate.sh" 2>/dev/null || true
  . "$BIN/jobs-client.sh" 2>/dev/null || true
}
# The suite's seam. Sandbox only, and settable:false in the registry.
NOW_S=""
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ]; then
  # shellcheck disable=SC1090
  [ -n "${DSP_FIXTURE:-}" ] && . "$DSP_FIXTURE"
  [[ ${DSP_NOW:-} =~ ^[0-9]+$ ]] && NOW_S=$DSP_NOW
fi
[ -n "$NOW_S" ] || NOW_S=$(date -u +%s)
command -v jq >/dev/null 2>&1 && command -v _jobs_req >/dev/null 2>&1 || exit 1
command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply staff-dispatcher

log()  { mkdir -p "$H/logs" 2>/dev/null; printf '%s agent=dispatcher %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$H/logs/staff.log" 2>/dev/null; }
warn() { log "warn: $*"; }
# knob_int <name> <value> <default> <min> <max>
knob_int() {
  local v=$2
  if [[ $v =~ ^[0-9]+$ ]] && [ "$((10#$v))" -ge "$4" ] && [ "$((10#$v))" -le "$5" ]; then
    printf '%s' "$((10#$v))"
  else
    warn "$1=$v is outside $4..$5; using the default $3"
    printf '%s' "$3"
  fi
}
LOOKBACK=$(knob_int DSP_DEPLOY_LOOKBACK_H "${DSP_DEPLOY_LOOKBACK_H:-72}" 72 1 2160)
ROWS=$(knob_int DSP_DEPLOY_ROWS "${DSP_DEPLOY_ROWS:-500}" 500 1 1000)
SEV="${DSP_PAGE_SEVERITY:-critical}"
case "$SEV" in
  critical|warn|info|off) ;;
  *) warn "DSP_PAGE_SEVERITY=$SEV is not critical, warn, info or off; using the default critical"; SEV=critical ;;
esac

DECL_DIR="$H/catalog/staff-feeds.d"
PAGED="$H/state/staff/dispatcher/paged"
[ -d "$PAGED" ] && find "$PAGED" -maxdepth 1 -type f -mmin +"$((LOOKBACK * 60))" -delete 2>/dev/null

# tsec: one probe or ledger time -> epoch seconds; error when it is not a time.
JQ_TS='def tsec:
  if type == "number" then (if . < 0 then error("neg") elif . > 1e12 then . / 1000 else . end | floor)
  elif type == "string" and test("^[0-9]+(\\.[0-9]+)?$") then (tonumber | tsec)
  elif type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|\\+00:00)?$")
    then (.[0:10] + "T" + .[11:19] + "Z" | fromdateiso8601)
  else error("not a time") end;'

# ═════ declarations ══════════════════════════════════════════════════════════
TMP=$(mktemp -d "${TMPDIR:-/tmp}/dsp-collect.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/decls"
for f in "$DECL_DIR"/*.json; do
  [ -e "$f" ] || continue
  name=$(basename "$f" .json)
  why=$(jq -r --arg n "$name" '
    if type != "object" then "not an object"
    elif (.id | type) != "string" or (.id | test("^[a-z][a-z0-9-]{1,47}$") | not) then "id"
    elif .id != $n then "the file name is not <id>.json"
    elif .kind != "feed" and .kind != "output" then "kind"
    elif (if .kind == "feed" then .max_age_h else .window_h end) as $w
         | ($w | type) != "number" or $w != ($w | floor) or $w < 1 or $w > 2160 then "window"
    elif .kind == "output" and ((.project | type) != "string" or (.project | test("^[a-z0-9][a-z0-9-]{0,47}$") | not)) then "project"
    elif (.probe.path | type) != "string" or (.probe.path | test("^/api/[^[:space:]]*$") | not)
         or (.probe.path | contains("..")) then "probe.path"
    elif (.probe.at | type) != "string" or (.probe.at | length) < 1 or (.probe.at | length) > 200 then "probe.at"
    else "" end' "$f" 2>/dev/null) || why="not JSON"
  if [ -z "$why" ]; then
    jrc=0; jq -n "null | [($(jq -r .probe.at "$f"))]" >/dev/null 2>&1 || jrc=$?
    [ "$jrc" = 3 ] && why="probe.at is not a jq expression"
  fi
  if [ -n "$why" ]; then log "dispatcher: declaration $name.json invalid ($why); skipped"; continue; fi
  jq -c '{id, kind, project: (.project // ""), w: (if .kind == "feed" then .max_age_h else .window_h end),
          path: .probe.path, at: .probe.at}' "$f" >> "$TMP/decls"
done
[ -s "$TMP/decls" ] || exit 0

# ═════ the deploy ledger, once, only when an output is declared ═════════════
if jq -e 'select(.kind == "output")' "$TMP/decls" >/dev/null 2>&1; then
  _jobs_req GET "/api/ledger?kind=deploy&limit=$ROWS" > "$TMP/ledger" 2>/dev/null || exit 1
  jq -e '.ledgers | type == "array"' "$TMP/ledger" >/dev/null 2>&1 || exit 1
fi

# ═════ probes and the two checks ═════════════════════════════════════════════
URL="${CONSOLE_URL:-}"; URL="${URL%/}/staff/dispatcher"
OBS=$(date -u -d "@$NOW_S" +%Y-%m-%dT%H:%M:%SZ) || exit 1
READ=0; UNREAD=0
: > "$TMP/found"; : > "$TMP/pages"
while IFS= read -r d; do
  id=$(jq -r .id <<<"$d"); path=$(jq -r .path <<<"$d"); at=$(jq -r .at <<<"$d")
  if ! _jobs_req GET "$path" > "$TMP/ans" 2>/dev/null; then
    log "dispatcher: probe $id unreadable (GET failed)"; UNREAD=$((UNREAD+1)); continue
  fi
  # never | <epoch>; anything else is unreadable.
  t=$(jq -r "$JQ_TS [($at)] | if length != 1 then error(\"values\")
        elif .[0] == null or .[0] == \"\" then \"never\" else (.[0] | tsec | tostring) end" "$TMP/ans" 2>/dev/null)
  if ! [[ $t =~ ^(never|[0-9]+)$ ]]; then
    log "dispatcher: probe $id unreadable (not a time)"; UNREAD=$((UNREAD+1)); continue
  fi
  READ=$((READ+1))
  jq -c --arg t "$t" --argjson now "$NOW_S" --argjson lb "$LOOKBACK" --arg url "$URL" --arg obs "$OBS" \
    --slurpfile led <(cat "$TMP/ledger" 2>/dev/null || echo '{"ledgers":[]}') "$JQ_TS"'
    . as $d | ($t | if . == "never" then null else tonumber end) as $o
    | def out($check; $item; $title):
        {item: $item, title: $title, source: {kind: "staff-feed", url: $url, labels: []},
         observedAt: $obs, class: $check};
    if $d.kind == "feed" then
      if $o == null then
        out("dead-feed"; {check: "dead-feed", feed: $d.id, last_success: "never"};
            "Dead feed: \($d.id) has no success on record; its window is \($d.w) h")
      elif $now - $o > $d.w * 3600 then
        out("dead-feed"; {check: "dead-feed", feed: $d.id, last_success: ($o | todate)};
            "Dead feed: \($d.id) last succeeded \((($now - $o) / 3600) | floor) h ago (\($o | todate)); its window is \($d.w) h")
      else empty end
    else
      [ $led[0].ledgers[]? | objects | select(.status == "verified")
        | (.detail | if type == "string" then (try fromjson catch {}) elif type == "object" then . else {} end) as $x
        | select(($x | type) == "object" and $x.project == $d.project)
        | (try ([$x.verified_at, $x.departure, .created_at] | map(select(. != null and . != "")) | .[0] | tsec) catch null)
        | select(. != null and $now - . <= $lb * 3600) ] | max as $dep
      | if $dep != null and $now - $dep >= $d.w * 3600 and ($o == null or $o < $dep) then
          out("post-deploy-output"; {check: "post-deploy-output", output: $d.id, deployed_at: ($dep | todate)};
              "No output after deploy: \($d.id) (\($d.project)) made no output in the \($d.w) h since the \($dep | todate) deploy")
          + {dep: $dep}
        else empty end
    end' <<<"$d" > "$TMP/one" 2>/dev/null || { log "dispatcher: check $id failed; skipped"; continue; }
  [ -s "$TMP/one" ] || continue
  dep=$(jq -r '.dep // empty' "$TMP/one")
  [ -n "$dep" ] && printf '%s\t%s\t%s\n' "$id" "$dep" "$(jq -r .title "$TMP/one")" >> "$TMP/pages"
  printf '%s\t%s\t%s\n' "$(jq -r .class "$TMP/one")" "$id" "$(jq -c 'del(.dep)' "$TMP/one")" >> "$TMP/found"
done < "$TMP/decls"

[ "$READ" -gt 0 ] || exit 1

# ═════ pages: lane-alert first, then the marker ══════════════════════════════
if [ "$SEV" != off ]; then
  while IFS=$'\t' read -r id dep title; do
    [ -e "$PAGED/$id.$dep" ] && continue
    "$H/bin/lane-alert.sh" --id "staff-dispatcher-postdeploy-$id-$dep" --severity "$SEV" staff "$title" >/dev/null 2>&1
    log "dispatcher: paged $id deploy $(date -u -d "@$dep" +%Y-%m-%dT%H:%M:%SZ) severity $SEV"
    { mkdir -p "$PAGED" && touch "$PAGED/$id.$dep"; } 2>/dev/null \
      || warn "cannot write the page marker $PAGED/$id.$dep; lane-alert's open-id dedupe stops a repeat"
  done < "$TMP/pages"
fi

LC_ALL=C sort -t$'\t' -k1,1 -k2,2 "$TMP/found" | cut -f3-
exit 0
