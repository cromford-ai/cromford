#!/bin/bash
# tests/lib/linear-stub.bh-7920.sh — Linear's GraphQL API and the jobs-worker
# settings route, played from fixture files (BH-7920). Sourced by
# tests/tracker-list-filters.bh-7920-test.sh and
# tests/triage-intake-linear.bh-7920-test.sh. No network.
#
#   linear_stub_setup <scratch root> <fixture dir>
#                         writes $root/lstub/curl and $root/lstub/gh, exports
#                         what they read (LS_STATE, LS_FIX, the jobs client
#                         env) and puts $root/lstub first on PATH
#   linear_set <key> <value>   one settings row (200)
#   linear_unset <key>         drop a row (the worker answers 404, no row)
#   linear_settings_down       every settings GET answers 500
#   linear_req_count [<op>]    Linear requests so far (all, or one operation)
#   linear_settings_count      settings GETs so far
#   linear_req_of <op>         the newest request body for that operation
#   linear_reset_log           forget the requests counted so far
#
# THE ANSWERS. TrkIssues serves $LS_STATE/issues.json when it exists, else
# $LS_FIX/issues.json, whatever the filter says: the server-side filter is
# checked by reading the request, and what the list keeps is the contract's
# own check. TrkIssue serves issue-<identifier>.json the same way (state copy
# first), else not-found.json. Any other operation is a 400.
#
# THE KEY rides on curl's argv. The stub compares it to LS_KEY_EXPECT, notes
# `badauth` when it differs, and never writes argv or a header anywhere.

linear_stub_setup() {
  local root="$1" fix="$2"
  mkdir -p "$root/lstub" "$root/ls" || return 1
  export LS_STATE="$root/ls" LS_FIX="$fix"
  export HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.example JOBS_RETRIES=0 JOBS_TIMEOUT=5
  case ":$PATH:" in *":$root/lstub:"*) ;; *) export PATH="$root/lstub:$PATH" ;; esac
  cat > "$root/lstub/curl" <<'SH'
#!/bin/bash
S="$LS_STATE"; F="$LS_FIX"; m=GET; url=""; data=""; out=""; fmt=""; auth=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m="$2"; shift ;;
    --data-binary|-d) data="${2#@}"; shift ;;
    -o) out="$2"; shift ;;
    -w) fmt="$2"; shift ;;
    -m|--max-time|--connect-timeout|-u) shift ;;
    -H) case "$2" in Authorization:*) auth="${2#Authorization: }" ;; esac; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
emit() { # emit <code> <body>
  if [ -n "$out" ]; then printf '%s' "$2" > "$out"; else printf '%s' "$2"; fi
  [ -n "$fmt" ] && printf '%s' "$fmt" | sed "s/%{http_code}/$1/g"
  exit 0
}
fx() { if [ -r "$S/$1" ]; then cat "$S/$1"; elif [ -r "$F/$1" ]; then cat "$F/$1"; else return 1; fi; }
case "$url" in
  https://jobs.example/api/settings/*)
    key="${url##*/}"; echo "$key" >> "$S/settings.log"
    [ -e "$S/settings-down" ] && emit 500 '{"error":"down"}'
    f="$S/setting-$key"
    [ -r "$f" ] && emit "$(head -1 "$f")" "$(sed -n '2,$p' "$f")"
    emit 404 '{"error":"no such setting"}' ;;
  https://jobs.example/*) emit 404 '{}' ;;
esac
n=$(( $(cat "$S/seq" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$S/seq"
op=$(jq -r '.query // ""' "$data" 2>/dev/null | sed -nE '1s/^(query|mutation) ([A-Za-z]+).*/\2/p')
printf '%s %s %s %s\n' "$n" "$m" "$url" "${op:-none}" >> "$S/reqs"
[ -n "$data" ] && [ -r "$data" ] && cp "$data" "$S/req-$n.json"
[ "$auth" = "${LS_KEY_EXPECT:-}" ] || echo "badauth $n" >> "$S/authbad"
case "$op" in
  TrkIssues) emit 200 "$(fx issues.json)" ;;
  TrkIssue)
    id=$(jq -r '.variables.id // ""' "$data")
    case "$id" in *[!A-Za-z0-9-]*|'') emit 200 "$(fx not-found.json)" ;; esac
    b=$(fx "issue-$id.json") && emit 200 "$b"
    emit 200 "$(fx not-found.json)" ;;
esac
emit 400 '{"errors":[{"message":"unknown operation","extensions":{"code":"GRAPHQL_VALIDATION_FAILED"}}]}'
SH
  cat > "$root/lstub/gh" <<'SH'
#!/bin/bash
echo "gh $*" >> "$LS_STATE/gh.log"
exit 1
SH
  chmod +x "$root/lstub/curl" "$root/lstub/gh"
}

linear_set() {
  jq -n --arg k "$1" --arg v "$2" '{setting:{key:$k,value:$v}}' | { echo 200; cat; } > "$LS_STATE/setting-$1"
}
linear_unset() { rm -f "$LS_STATE/setting-$1"; }
linear_settings_down() { : > "$LS_STATE/settings-down"; }
linear_req_count() {
  if [ -n "${1:-}" ]; then cat "$LS_STATE/reqs" 2>/dev/null | awk -v o="$1" '$4 == o' | grep -c .
  else cat "$LS_STATE/reqs" 2>/dev/null | grep -c .; fi
}
linear_settings_count() { cat "$LS_STATE/settings.log" 2>/dev/null | grep -c .; }
linear_req_of() {
  local n
  n=$(awk -v o="$1" '$4 == o {k=$1} END {print k}' "$LS_STATE/reqs" 2>/dev/null)
  [ -n "$n" ] && cat "$LS_STATE/req-$n.json"
}
linear_reset_log() { rm -f "$LS_STATE/reqs" "$LS_STATE/settings.log" "$LS_STATE/gh.log" "$LS_STATE"/req-*.json; }
