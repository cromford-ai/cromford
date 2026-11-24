# shellcheck shell=bash
# tests/lib/parks-fake.bh-9075.sh — a LOCAL fake of the jobs worker's parks
# routes (worker/jobs/src/routes/parks.js) and of POST /api/lane-wakes/take,
# for the BH-9075 shell suites. Sourced; defines _jobs_req only. 0 network
# calls: the "table" is a JSON array in $PARKS_FAKE_DB.
#
# The contract it keeps is the route's own (the worker suite
# worker/jobs/test/parks.bh-9075.test.js pins the real one):
#   PUT  /api/parks {rows}          upsert by (project, ck); a row older than the
#                                   stored one loses; `-` keeps a stored text value
#   GET  /api/parks/changed?...     updated_at > ts, or (= ts and ck > ck) for the
#                                   keyset token; ORDER BY updated_at, ck; LIMIT
#   POST /api/parks/prune           a dry run that counts nothing
#   POST /api/lane-wakes/take       {taken:[], webhook_max_id:$PARKS_FAKE_WAKE_MAX|null}
#   any other path                  404
#
# Env:
#   PARKS_FAKE_DB         the table file (created as [] when missing)
#   PARKS_FAKE_CALLS      one line per request: `<METHOD> <path>`
#   PARKS_FAKE_BODIES     one line per request body (optional)
#   PARKS_FAKE_FAIL       noanswer | 500 | badjson | nonext | 400 (unset = none)
#   PARKS_FAKE_FAIL_PATH  a glob the path must match for the failure (default *)
#   PARKS_FAKE_WAKE_MAX   the take's webhook_max_id (unset or `null` = null)
#   PARKS_FAKE_HOTFIX_MAX the hotfix list cap (default 50)

_jobs_req() {
  local method="$1" path="$2" body="${3:-}" db="${PARKS_FAKE_DB:?}" out q
  JOBS_HTTP=""
  [ -f "$db" ] || printf '[]' > "$db"
  [ -n "${PARKS_FAKE_CALLS:-}" ] && printf '%s %s\n' "$method" "$path" >> "$PARKS_FAKE_CALLS"
  [ -n "${PARKS_FAKE_BODIES:-}" ] && printf '%s\n' "$body" >> "$PARKS_FAKE_BODIES"
  if [ -n "${PARKS_FAKE_FAIL:-}" ]; then
    # shellcheck disable=SC2254
    case "$path" in
      ${PARKS_FAKE_FAIL_PATH:-*})
        case "$PARKS_FAKE_FAIL" in
          noanswer) return 1 ;;
          500) JOBS_HTTP=500; return 1 ;;
          400) JOBS_HTTP=400; return 1 ;;
          badjson) JOBS_HTTP=200; printf '{"rows":[{"project":'; return 0 ;;
          nonext) JOBS_HTTP=200; printf '{"rows":[],"truncated":false,"hotfix":[],"upserted":"x","as_of":1}'; return 0 ;;
        esac ;;
    esac
  fi
  case "$method $path" in
    "PUT /api/parks")
      out=$(jq -c --slurpfile db "$db" '
        def keep($new; $old): if $new == "-" or $new == null then $old else $new end;
        if (.rows | type) != "array" or (.rows | length) < 1 or (.rows | length) > 100
           or any(.rows[]; (.project | test("^[a-z0-9._-]{1,64}$") | not)
                   or (.ck | test("^[A-Za-z0-9._-]{1,200}$") | not)
                   or ([.state] | inside(["parked","hotfix","done"]) | not)
                   or ((.updated_at | type) != "number") or .updated_at <= 0)
        then {status: 400}
        else reduce .rows[] as $r ({t: $db[0], n: 0};
          (.t | map(.project == $r.project and .ck == $r.ck) | index(true)) as $i
          | if $i == null then .t += [$r] | .n += 1
            elif $r.updated_at >= .t[$i].updated_at then
              .t[$i] = (.t[$i] as $o | $o + {
                source: keep($r.source; $o.source), head: keep($r.head; $o.head),
                reason: keep($r.reason; $o.reason), url: keep($r.url; $o.url),
                rec: keep($r.rec; $o.rec), ticket: keep($r.ticket; $o.ticket),
                state: $r.state, updated_at: $r.updated_at, writer: $r.writer,
                parked_at: ($r.parked_at // $o.parked_at)}) | .n += 1
            else . end)
        end' <<<"$body" 2>/dev/null) || { JOBS_HTTP=400; return 1; }
      if [ "$(jq -r '.status // 200' <<<"$out")" = 400 ]; then JOBS_HTTP=400; return 1; fi
      jq -c '.t' <<<"$out" > "$db.tmp" && mv -f "$db.tmp" "$db"
      JOBS_HTTP=200; jq -c '{upserted: .n, as_of: 1}' <<<"$out" ;;
    "GET /api/parks/changed?"*)
      q="${path#*\?}"
      out=$(jq -c --arg q "$q" --argjson hmax "${PARKS_FAKE_HOTFIX_MAX:-50}" '
        . as $db
        | ($q | split("&") | map(split("=") | {(.[0]): (.[1] // "")}) | add) as $a
        | ($a.since | split(":")) as $s | ($s[0] | tonumber) as $ts | ($s[1] // null) as $ck
        | (($a.limit // "1000") | if . == "" then 1000 else tonumber end) as $lim
        | ([ $db[] | select(.project == $a.project
              and (.updated_at > $ts or ($ck != null and .updated_at == $ts and .ck > $ck))) ]
           | sort_by(.updated_at, .ck) | .[:$lim]) as $rows
        | {rows: $rows,
           next: (if ($rows | length) > 0 then "\($rows[-1].updated_at):\($rows[-1].ck)" else $a.since end),
           truncated: (($rows | length) == $lim), as_of: 1}
        + (if $a.hotfix == "1" then {hotfix: ([ $db[] | select(.project == $a.project and .state == "hotfix") ]
             | sort_by(.updated_at) | .[:$hmax])} else {} end)' "$db" 2>/dev/null) || { JOBS_HTTP=500; return 1; }
      JOBS_HTTP=200; printf '%s' "$out" ;;
    "POST /api/parks/prune")
      JOBS_HTTP=200; printf '{"run_id":1,"dry_run":true,"counted":0,"removed":0,"backlog":false}' ;;
    "POST /api/lane-wakes/take")
      JOBS_HTTP=200; printf '{"taken":[],"webhook_max_id":%s,"as_of":1}' "${PARKS_FAKE_WAKE_MAX:-null}" ;;
    *) JOBS_HTTP=404; return 2 ;;
  esac
  return 0
}
