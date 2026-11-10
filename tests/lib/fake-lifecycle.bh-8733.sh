# shellcheck shell=bash
# tests/lib/fake-lifecycle.bh-8733.sh — BH-8733: a local fake of the jobs
# worker seam for the ticket lifecycle (BH-8731). Sourced, never run.
#
# It replaces _jobs_req (bin/lib/jobs/req.sh), the one transport every
# lifecycle read and write goes through, with a store of JSON rows under
# $LF_DIR. 0 network calls. The REAL bin/lib/jobs/lifecycle.sh stays the
# client (lifecycle_transition), so its body and rc map are what the suite
# drives.
#   POST /api/lifecycle/transition   the route's 400s (reason, pr, question
#       only with plan_blocked and at most 2000 UTF-16 units), 404 no_row, and
#       the legality and owner answer of the REAL lifecycleCheck
#       (worker/jobs/src/lib/lifecycle.js, run through node), so the table is
#       never copied here. 409 body {error, current, to}; 200 body {ok, from, to}.
#   GET /api/queue?project=&key=&limit=1   {queue:[row]} or {queue:[]}.
# Any other method or path is UNIMPLEMENTED: one line on stderr and in
# $LF_DIR/unimpl.log, and rc 97 (the "throw on an unimplemented method").
# A 400 answers rc 1 (the transport's map) and is logged in $LF_DIR/400.log.
# $LF_DIR/rc, when it holds a number, is the rc of every request (an outage).
#
#   lf_init <dir>                               a fresh store
#   lf_row <project> <key> [phase] [question]   a build_queue row (phase NULL when absent or "")
#   lf_get <project> <key> <field>              a field of a row ("null" when NULL, "norow" with no row)
#   lf_events                                   one line per accepted move: project key from to actor pr reason
#   lf_calls [pattern]                          the count of requests (matching the pattern)

LF_LIFECYCLE_JS="${LF_LIFECYCLE_JS:-$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)/worker/jobs/src/lib/lifecycle.js}"

lf_init() {
  LF_DIR="$1"; mkdir -p "$LF_DIR/rows"
  : > "$LF_DIR/req.log"; : > "$LF_DIR/events.log"; : > "$LF_DIR/unimpl.log"; : > "$LF_DIR/400.log"; rm -f "$LF_DIR/rc"
}
_lf_file() { printf '%s/rows/%s__%s.json' "$LF_DIR" "$1" "$2"; }
lf_row() {
  jq -nc --arg p "$1" --arg k "$2" --arg ph "${3-}" --arg q "${4-}" --arg hasq "${4+1}" \
    '{project:$p, ticket_key:$k, status:"queued",
      phase:(if $ph != "" then $ph else null end),
      phase_at:(if $ph != "" then "2026-11-01T16:00:00Z" else null end),
      phase_actor:null, question:(if $hasq == "1" then $q else null end)}' > "$(_lf_file "$1" "$2")"
}
lf_get() {
  local f; f=$(_lf_file "$1" "$2"); [ -f "$f" ] || { echo norow; return 0; }
  jq -r --arg f "$3" 'if .[$f] == null then "null" else .[$f] end' "$f"
}
lf_events() { cat "$LF_DIR/events.log"; }
lf_calls() { local c; c=$(grep -c -- "${1:-.}" "$LF_DIR/req.log" 2>/dev/null); echo "${c:-0}"; }

# _lf_check <from> <to> <actor> -> the JSON of the real lifecycleCheck
_lf_check() {
  node --input-type=module -e '
    const { pathToFileURL } = await import("node:url");
    const m = await import(pathToFileURL(process.argv[1]).href);
    console.log(JSON.stringify(m.lifecycleCheck(process.argv[2], process.argv[3], process.argv[4])));
  ' "$LF_LIFECYCLE_JS" "$1" "$2" "$3"
}

_lf_transition() {
  local b="$1" p k to a f from cur chk ok err
  if ! jq -e '(.reason | type == "string" and length > 0 and length <= 500)
      and ((.pr // null) == null or ((.pr | type) == "number" and .pr > 0))
      and ((.question // null) == null or ((.question | type) == "string" and (.question | length) <= 2000 and .to_phase == "plan_blocked"))' \
      <<<"$b" >/dev/null 2>&1; then
    printf '400 %s\n' "$b" >> "$LF_DIR/400.log"; return 1
  fi
  p=$(jq -r '.project' <<<"$b"); k=$(jq -r '.ticket_key' <<<"$b"); to=$(jq -r '.to_phase' <<<"$b"); a=$(jq -r '.actor' <<<"$b")
  f=$(_lf_file "$p" "$k")
  [ -f "$f" ] || { printf '{"error":"no_row","project":"%s","ticket_key":"%s"}' "$p" "$k"; return 2; }
  from=$(jq -r '.phase // ""' "$f")
  if [ -z "$from" ]; then cur=null; else cur=$(jq -nc --arg v "$from" '$v'); fi
  chk=$(_lf_check "$from" "$to" "$a") || { echo "fake-lifecycle: node could not run lifecycleCheck" >&2; return 97; }
  ok=$(jq -r '.ok' <<<"$chk")
  if [ "$ok" != true ]; then
    err=$(jq -r '.error' <<<"$chk")
    printf '{"error":"%s","current":%s,"to":"%s"}' "$err" "$cur" "$to"; return 9
  fi
  jq -c --arg to "$to" --arg a "$a" --argjson b "$b" \
    '.phase=$to | .phase_at="2026-11-01T17:00:00Z" | .phase_actor=$a | .question=($b.question // null)' \
    "$f" > "$f.new" && mv "$f.new" "$f"
  printf '%s %s %s %s %s %s %s\n' "$p" "$k" "${from:-null}" "$to" "$a" "$(jq -r '.pr // "-"' <<<"$b")" "$(jq -r '.reason' <<<"$b")" >> "$LF_DIR/events.log"
  printf '{"ok":true,"project":"%s","ticket_key":"%s","from":%s,"to":"%s","event_id":1}' "$p" "$k" "$cur" "$to"
  return 0
}

_lf_qparam() { # _lf_qparam <query> <name> -> the url-decoded value
  local kv v
  for kv in ${1//&/ }; do
    case "$kv" in "$2="*) v="${kv#*=}"; v="${v//+/ }"; printf '%b' "${v//%/\\x}"; return 0 ;; esac
  done
}
_lf_queue() {
  local q="${1#*\?}" p k f
  p=$(_lf_qparam "$q" project); k=$(_lf_qparam "$q" key); f=$(_lf_file "$p" "$k")
  if [ -n "$p" ] && [ -n "$k" ] && [ -f "$f" ]; then jq -c '{queue:[.], as_of:"2026-11-01T17:00:00Z"}' "$f"
  else printf '{"queue":[],"as_of":"2026-11-01T17:00:00Z"}'; fi
  return 0
}

_jobs_req() {
  local m="${1:-}" path="${2:-}" body="${3:-}" rc
  printf '%s %s %s\n' "$m" "$path" "$body" >> "$LF_DIR/req.log"
  rc=$(cat "$LF_DIR/rc" 2>/dev/null)
  [ -n "$rc" ] && return "$rc"
  case "$m $path" in
    "POST /api/lifecycle/transition") _lf_transition "$body"; return $? ;;
    "GET /api/queue?"*) _lf_queue "$path"; return $? ;;
  esac
  printf 'UNIMPLEMENTED %s %s\n' "$m" "$path" | tee -a "$LF_DIR/unimpl.log" >&2
  return 97
}
