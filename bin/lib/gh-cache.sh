#!/bin/bash
# bin/lib/gh-cache.sh — BH-8066: the read-through cache under the gh PATH shim
# (bin/gh-ledger/gh). Sourced by the shim, never executed.
#
# WHY. Over the 24 hours before 2026-10-22 20:00Z the fleet made 286,509 REST
# calls for 193 merged PRs (1,484 per PR), and two thirds of them re-read state
# that did not change. The App installation ran at ~9,500/h against a 6,900 cap.
# Every lane reaches GitHub through the shim, so the shim answers a repeat
# `gh api` GET from disk and asks GitHub only when the answer can have changed.
#
# THE CYCLE, per eligible call (ghc_main):
#   an entry younger than GH_CACHE_TTL_S   replayed, 0 requests (served `cache`)
#                                          — after the wake check below
#   an entry past the TTL                  one request with If-None-Match: a
#                                          304 replays the entry and resets its
#                                          fetch time (served `304`); a 200
#                                          replaces it (served `200`)
#   no entry                               one request, the caller's own
#                                          If-None-Match removed, so the answer
#                                          is a body this cache can keep
#   anything but 200/304                   printed as gh gave it; the entry goes
#
# ELIGIBLE (ghc_eligible): `gh api` with method GET (none, or an explicit GET),
# fields only with an explicit GET, none of --input/--paginate/--slurp/
# --verbose/--cache, one endpoint that is not graphql, has no {owner}/{repo}/
# {branch} placeholder (they resolve from the cwd) and is not rate_limit, an
# artifact zip, a job log or an installation token. Any flag this file does not
# know makes the call ineligible.
#
# STORED (ghc_store) only when: status 200, rc 0, gh printed nothing on stderr,
# exactly one HTTP request, an ETag of the form (W/)"…", no Cache-Control
# no-store, at most GH_ETAG_MAX_BYTES of output (the gh-rest-etag.sh cap).
#
# THE ENTRY is state/gh-cache/<repo>~<obj>~<sha1>. <repo> is owner__name
# lowercased (`_` for a non-repo endpoint), <obj> is n-<N> (pulls/issues),
# s-<sha12> (commits/statuses) or r. The key is sha1(GET, the identity
# gh_quota_bucket names, the argv without If-None-Match), so the output flags
# (--jq, -i, …) and the token's bucket are part of it. Line 1 is
# `v1<TAB>fetched<TAB>etag<TAB>rc<TAB>status`; every byte after it is gh's stdout.
#
# THE WAKE CHECK (ghc_wake_sync). A hit older than GH_CACHE_WAKE_GRACE_S asks
# the hub's wakes (GET /api/wakes?since=<watermark>, through the jobs client) at
# most once per grace per box. A wake drops <repo>~r~* and the object's entries.
# A worker that cannot be reached leaves the cache TTL-only and writes one line
# to logs/gh-cache.log, retried after GH_CACHE_TTL_S.
#
# A WRITE ON THIS BOX (ghc_note_write). A `gh api` POST/PATCH/PUT/DELETE to
# repos/<o>/<r>/… drops the same entries a wake for that object would, before
# it runs: a lane that writes and then reads never waits on the webhook.
#
# Knobs: GH_CACHE_TTL_S (lib.gh-ledger.gh_cache_ttl_s, 0 = off),
# GH_CACHE_WAKE_GRACE_S (lib.gh-ledger.gh_cache_wake_grace_s); GH_CACHE_NOW is
# the clock seam for tests.
#
# THE SHIM PROVIDES, and this file calls back into: _ghl_run_capture
# <trace|hdr> <out> <err> <args…> (run the real gh, stdout and the filtered
# stderr to files, the trace records to $_ghl_rec), and gh_quota_bucket (from
# bin/lib/gh-rest-ledger.sh, loaded by the shim first).
#
# No `set -e`, no `exit`, no side effect at source time. Every failure returns
# non-zero BEFORE the request, and the shim then runs the call as it always did.
if [ -n "${GH_CACHE_LIB:-}" ]; then return 0 2>/dev/null; fi
GH_CACHE_LIB=1

_ghc_libdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
# The shared TTL + count sweep (_gh_etag_sweep). A box without it keeps entries
# until the next drop or 200; correctness does not depend on it.
# shellcheck source=bin/lib/gh-rest-etag.sh
[ -r "$_ghc_libdir/gh-rest-etag.sh" ] && . "$_ghc_libdir/gh-rest-etag.sh" 2>/dev/null

_ghc_home() { local h="${HARNESS:-${H:-}}"; [ -n "$h" ] || return 1; printf '%s' "$h"; }
ghc_now() { case "${GH_CACHE_NOW:-}" in ''|*[!0-9]*) date -u +%s ;; *) printf '%s' "$GH_CACHE_NOW" ;; esac; }
_ghc_log() {
  local h; h=$(_ghc_home) || return 0
  mkdir -p "$h/logs" 2>/dev/null
  printf '%s gh-cache: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$1" >> "$h/logs/gh-cache.log" 2>/dev/null
  return 0
}
_ghc_sha1() {
  if command -v sha1sum >/dev/null 2>&1; then sha1sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 1 | awk '{print $1}'
  else return 1
  fi
}

# _ghc_parse <gh args…> — one pass over a `gh api` argv. Sets GHC_ENDPOINT (the
# last positional), GHC_NPOS (how many), GHC_METHOD (the -X value, or empty),
# GHC_BODY (1 when fields or --input send a body), GHC_INCLUDE (1 for -i),
# GHC_ODD (1 for a flag the cache must not serve: --input, --paginate,
# --slurp, --verbose, --cache, `--`, a value read from a file, a flag with no
# value, anything unknown) and GHC_ARGV (the argv with every If-None-Match
# header removed). rc 1 when argv[1] is not `api`.
_ghc_parse() {
  local a v val
  GHC_ARGV=(); GHC_ENDPOINT=""; GHC_NPOS=0; GHC_METHOD=""; GHC_BODY=0; GHC_INCLUDE=0; GHC_ODD=0
  [ "${1:-}" = api ] || return 1
  GHC_ARGV=(api); shift
  while [ $# -gt 0 ]; do
    a="$1"; shift
    case "$a" in
      -X|--method|-H|--header|-f|--raw-field|-F|--field|-q|--jq|-t|--template|-p|--preview|--hostname|--input|--cache)
        [ $# -gt 0 ] || { GHC_ODD=1; continue; }
        val="$1"; shift ;;
      --method=*|--header=*|--raw-field=*|--field=*|--jq=*|--template=*|--preview=*|--hostname=*|--input=*|--cache=*)
        val="${a#*=}"; a="${a%%=*}" ;;
      -X?*|-H?*|-f?*|-F?*|-q?*|-t?*|-p?*)
        val="${a:2}"; a="${a:0:2}" ;;
      -i|--include) GHC_INCLUDE=1; GHC_ARGV+=("$a"); continue ;;
      --silent|--allow-escape-sequences) GHC_ARGV+=("$a"); continue ;;
      -*) GHC_ODD=1; continue ;;
      *) GHC_NPOS=$((GHC_NPOS + 1)); GHC_ENDPOINT="$a"; GHC_ARGV+=("$a"); continue ;;
    esac
    case "$a" in
      -X|--method) GHC_METHOD="$val" ;;
      -f|--raw-field) GHC_BODY=1 ;;
      -F|--field) GHC_BODY=1; case "$val" in *=@*) GHC_ODD=1 ;; esac ;;   # a value read from a file or stdin
      --input) GHC_BODY=1; GHC_ODD=1 ;;
      --cache) GHC_ODD=1 ;;
      -H|--header)
        v=$(printf '%s' "$val" | tr 'A-Z' 'a-z')
        case "$v" in "if-none-match:"*) continue ;; esac ;;
    esac
    GHC_ARGV+=("$a" "$val")
  done
  return 0
}

# ghc_eligible <gh args…> — rc 0 when the call may be served from the cache.
# Leaves _ghc_parse's GHC_ENDPOINT, GHC_ARGV and GHC_INCLUDE set.
ghc_eligible() {
  local bare
  _ghc_parse "$@" || return 1
  [ "$GHC_ODD" = 0 ] && [ "$GHC_NPOS" = 1 ] || return 1
  if [ -n "$GHC_METHOD" ]; then [ "$GHC_METHOD" = GET ] || return 1
  else [ "$GHC_BODY" = 0 ] || return 1   # gh sends fields with no method as a POST
  fi
  case "$GHC_ENDPOINT" in *'{owner}'*|*'{repo}'*|*'{branch}'*) return 1 ;; esac
  bare=$(_ghc_bare "$GHC_ENDPOINT")
  case "${bare%%\?*}" in
    graphql|rate_limit) return 1 ;;
    *actions/artifacts/*/zip*|*actions/jobs/*/logs*|*installation/token*) return 1 ;;
  esac
  return 0
}

# ghc_note_write <cache dir> <gh args…> — a `gh api` write (an explicit method
# other than GET, or a body with no method) to repos/<o>/<r>/… drops that
# repo's list entries and the object's entries BEFORE it runs, so a lane that
# writes and then reads on this box never reads its own stale entry. Every
# other call is left alone.
ghc_note_write() {
  local dir="${1:-}" tag
  shift
  [ -d "$dir" ] || return 0
  _ghc_parse "$@" || return 0
  [ "$GHC_NPOS" = 1 ] || return 0
  if [ -n "$GHC_METHOD" ]; then [ "$GHC_METHOD" != GET ] || return 0
  else [ "$GHC_BODY" = 1 ] || return 0
  fi
  tag=$(ghc_tag "$GHC_ENDPOINT")
  case "$tag" in _~*) return 0 ;; esac
  ghc_drop "$dir/${tag%%~*}~r~*"
  case "$tag" in *~r) ;; *) ghc_drop "$dir/$tag~*" ;; esac
  return 0
}

# _ghc_bare <endpoint> — no https://<host>/ prefix, no leading `/`.
_ghc_bare() {
  local e="${1:-}"
  case "$e" in http://*|https://*) e="${e#*://}"; case "$e" in */*) e="${e#*/}" ;; *) e="" ;; esac ;; esac
  printf '%s' "${e#/}"
}

# ghc_key <identity> <argv…> — the sha1 that names an entry.
ghc_key() {
  local id="${1:-}"; shift
  { printf 'GET\0%s\0' "$id"; printf '%s\0' "$@"; } | _ghc_sha1
}

# _ghc_repo_tag <owner/name[/…]> — `owner__name`, lowercased, one character
# class, so the shim's endpoint and the worker's wake row name a repo alike.
_ghc_repo_tag() {
  local r o n
  r=$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')
  o="${r%%/*}"; n="${r#*/}"; n="${n%%/*}"
  [ -n "$o" ] && [ -n "$n" ] && [ "$o" != "$r" ] || return 1
  printf '%s__%s' "$o" "$n" | tr -c 'a-z0-9._-' '_'
}

# ghc_tag <endpoint> — `<repo>~<obj>`, the part of the name a wake drops by.
ghc_tag() {
  local e repo obj="r" rest seg prev="" i
  e=$(_ghc_bare "${1:-}"); e="${e%%\?*}"
  e=$(printf '%s' "$e" | tr 'A-Z' 'a-z')
  case "$e" in repos/*/*) repo=$(_ghc_repo_tag "${e#repos/}") || repo="" ;; *) repo="" ;; esac
  if [ -z "$repo" ]; then printf '_~r'; return 0; fi
  rest="${e#repos/*/*/}"; [ "$rest" = "$e" ] && rest=""
  IFS=/ read -r -a seg <<<"$rest"
  for i in "${seg[@]+"${seg[@]}"}"; do
    case "$prev" in
      pulls|issues) case "$i" in ''|*[!0-9]*) ;; *) obj="n-$((10#$i))"; break ;; esac ;;
      commits|statuses) if [[ "$i" =~ ^[0-9a-f]{7,40}$ ]]; then obj="s-${i:0:12}"; break; fi ;;
    esac
    prev="$i"
  done
  printf '%s~%s' "$repo" "$obj"
}

# ghc_read <entry> — line 1 into GHC_E_AT GHC_E_ETAG GHC_E_RC GHC_E_ST. rc 1 when
# the file is missing or its line 1 is not one this file wrote.
ghc_read() {
  local v="" at="" etag="" rc="" st=""
  GHC_E_AT=; GHC_E_ETAG=; GHC_E_RC=; GHC_E_ST=
  [ -f "${1:-}" ] || return 1
  IFS=$'\t' read -r v at etag rc st < "$1" 2>/dev/null || return 1
  [ "$v" = v1 ] || return 1
  case "$at" in ''|*[!0-9]*) return 1 ;; esac
  case "$rc" in ''|*[!0-9]*) return 1 ;; esac
  [[ "$etag" =~ ^(W/)?\"[^\"]*\"$ ]] || return 1
  GHC_E_AT=$at; GHC_E_ETAG=$etag; GHC_E_RC=$rc; GHC_E_ST=$st
  return 0
}

# ghc_store <entry> <out> <fetched> <etag> <rc> — tmp + mv in the same dir.
ghc_store() {
  local f="$1" tmp
  tmp="${f%/*}/_tmp.${f##*~}.${BASHPID:-$$}"
  { printf 'v1\t%s\t%s\t%s\t200\n' "$3" "$4" "$5" && cat "$2"; } > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$f" 2>/dev/null && return 0
  rm -f "$tmp" 2>/dev/null
  return 1
}

# ghc_touch <entry> <copy> <fetched> — a 304: the same body, a new fetch time.
ghc_touch() {
  ghc_read "$2" || return 1
  local tmp="${1%/*}/_tmp.${1##*~}.${BASHPID:-$$}"
  { printf 'v1\t%s\t%s\t%s\t%s\n' "$3" "$GHC_E_ETAG" "$GHC_E_RC" "$GHC_E_ST" && tail -n +2 "$2"; } > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$1" 2>/dev/null && return 0
  rm -f "$tmp" 2>/dev/null
  return 1
}

# ghc_drop <glob…> — remove the entries each glob names (expanded HERE, so the
# caller passes it quoted); a glob that matches nothing is a no-op.
ghc_drop() {
  local g f
  for g in "$@"; do
    for f in $g; do [ -f "$f" ] && rm -f "$f" 2>/dev/null; done   # unquoted on purpose: $g is the glob
  done
  return 0
}

# ghc_replay <entry> <served> <include 0|1> — the stored stdout, byte for byte.
# An `-i` answer gets `X-Gh-Cache-Served: <served>` after its status line, with
# that line's own ending, so gh_rest can tell a replay from a live answer.
ghc_replay() {
  local l
  if [ "${3:-0}" = 1 ]; then
    l=$(tail -n +2 "$1" | head -n 1)
    case "$l" in
      HTTP/*)
        tail -n +2 "$1" | head -n 1
        if [[ "$l" == *$'\r' ]]; then printf 'X-Gh-Cache-Served: %s\r\n' "$2"; else printf 'X-Gh-Cache-Served: %s\n' "$2"; fi
        tail -n +3 "$1"
        return 0 ;;
    esac
  fi
  tail -n +2 "$1"
}

# ghc_knobs <cache dir> — GHC_TTL and GHC_GRACE. An env value wins; then
# <dir>/.knobs while it is younger than the lane gate's settings cache window;
# then a resolve through lib_env_apply gh-ledger in a subshell (lane-gate.sh on
# a half-synced bin/ ends that subshell, never this process), written to .knobs.
ghc_knobs() {
  local dir="${1:-}" t="${GH_CACHE_TTL_S:-}" g="${GH_CACHE_WAKE_GRACE_S:-}" ft="" fg="" fa="" now win h v
  if [ -z "$t" ] || [ -z "$g" ]; then
    now=$(ghc_now)
    win="${LANE_GATE_CACHE_S:-60}"   # the lane gate's own settings cache window (bin/lib/lane-gate.sh)
    case "$win" in ''|*[!0-9]*) win=60 ;; esac
    [ -r "$dir/.knobs" ] && read -r ft fg fa _ < "$dir/.knobs" 2>/dev/null
    case "${fa:-}" in ''|*[!0-9]*) fa="" ;; esac
    if [ -z "$fa" ] || [ $((now - fa)) -ge "$win" ] || [ $((now - fa)) -lt 0 ]; then
      ft=""; fg=""
      h=$(_ghc_home) || h=""
      if [ -n "$h" ] && [ -r "$h/bin/lib/lane-gate.sh" ]; then
        v=$(
          unset GH_CACHE_TTL_S GH_CACHE_WAKE_GRACE_S
          # shellcheck source=bin/lib/lane-gate.sh
          { . "$h/bin/lib/lane-gate.sh" && command -v lib_env_apply && lib_env_apply gh-ledger; } >/dev/null 2>&1
          printf '%s %s' "${GH_CACHE_TTL_S:-}" "${GH_CACHE_WAKE_GRACE_S:-}"
        ) 2>/dev/null || v=""
        read -r ft fg <<<"$v"
        { printf '%s %s %s\n' "${ft:--}" "${fg:--}" "$now" > "$dir/.knobs.$$" && mv -f "$dir/.knobs.$$" "$dir/.knobs"; } 2>/dev/null
        rm -f "$dir/.knobs.$$" 2>/dev/null
      fi
    fi
    [ -n "$t" ] || t="$ft"
    [ -n "$g" ] || g="$fg"
  fi
  case "$t" in ''|*[!0-9]*) t=60 ;; esac   # fallback for the settings row lib.gh-ledger.gh_cache_ttl_s
  case "$g" in ''|*[!0-9]*) g=5 ;; esac    # fallback for the settings row lib.gh-ledger.gh_cache_wake_grace_s
  GHC_TTL=$((10#$t)); GHC_GRACE=$((10#$g))
  return 0
}

# _ghc_wakes_fetch <watermark|""> — runs in a SUBSHELL (jobs-client.sh exits the
# shell that sources it when its modules are missing). Prints `OK <wm>` and the
# wakes JSON, or `ERR <why>`. With no watermark, the seed is the hub's wake
# cursor (the one bin/wake-loop.sh seeds from).
_ghc_wakes_fetch() {
  local h wm="${1:-}" jc
  h=$(_ghc_home) || { echo "ERR no harness root"; return 1; }
  jc="$h/bin/jobs-client.sh"
  [ -r "$jc" ] && [ -r "$h/bin/lib/jobs/req.sh" ] || { echo "ERR no jobs client"; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "ERR no jq"; return 1; }
  # shellcheck source=bin/jobs-client.sh
  . "$jc" >/dev/null 2>&1 || { echo "ERR jobs client did not load"; return 1; }
  [ -n "${HARNESS_SECRET:-}" ] || { echo "ERR no HARNESS_SECRET"; return 1; }
  if [ -z "$wm" ]; then
    command -v hub_box_name >/dev/null 2>&1 || . "$_ghc_libdir/hub-box.sh" >/dev/null 2>&1
    command -v hub_box_name >/dev/null 2>&1 && command -v wake_cursor_get >/dev/null 2>&1 \
      || { echo "ERR no wake cursor reader"; return 1; }
    wm=$(JOBS_ALERT=0 wake_cursor_get "$(hub_box_name)" 2>/dev/null) || { echo "ERR hub cursor unreadable"; return 1; }
    case "$wm" in ''|*[!0-9]*) echo "ERR no hub cursor to seed from"; return 1 ;; esac
  fi
  local body
  # No retry: this read sits in front of a caller's gh call, and a failure
  # only means TTL-only until the next try.
  body=$(JOBS_ALERT=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 _jobs_req GET "/api/wakes?since=$wm" 2>/dev/null) \
    || { echo "ERR GET /api/wakes http=${JOBS_HTTP:-none}"; return 1; }
  printf '%s' "$body" | jq -e '.wakes | type == "array"' >/dev/null 2>&1 || { echo "ERR unparseable wakes answer"; return 1; }
  printf 'OK %s\n%s\n' "$wm" "$body"
  return 0
}

# ghc_wake_sync <cache dir> <now> — rc 0: serve (entries a wake named are gone);
# rc 2: the sync lock is busy, so make the call conditional.
ghc_wake_sync() {
  local dir="$1" now="$2" wm="" last="" down="" lfd out head seeded=0 id repo key max
  [ -r "$dir/.wakes" ] && read -r wm last _ < "$dir/.wakes" 2>/dev/null
  case "${wm:-}" in *[!0-9]*) wm="" ;; esac
  case "${last:-}" in ''|*[!0-9]*) last=0 ;; esac
  [ $((now - last)) -ge 0 ] && [ $((now - last)) -lt "$GHC_GRACE" ] && return 0
  if [ -r "$dir/.wake-down" ]; then
    read -r down _ < "$dir/.wake-down" 2>/dev/null
    case "${down:-}" in ''|*[!0-9]*) down=0 ;; esac
    [ $((now - down)) -ge 0 ] && [ $((now - down)) -lt "$GHC_TTL" ] && return 0
  fi
  command -v flock >/dev/null 2>&1 || return 2
  exec {lfd}>>"$dir/.wakes.lock" || return 2
  if ! flock -n "$lfd"; then exec {lfd}>&-; return 2; fi
  out=$( _ghc_wakes_fetch "$wm" ) || out="${out:-ERR jobs client failed}"
  head="${out%%$'\n'*}"
  case "$head" in
    "OK "*)
      if [ -z "$wm" ]; then seeded=1; wm="${head#OK }"; fi
      [ "$seeded" = 1 ] && ghc_drop "$dir/*~*~*"
      max="$wm"
      while IFS=$'\t' read -r id repo key; do
        case "$id" in ''|*[!0-9]*) continue ;; esac
        if repo=$(_ghc_repo_tag "$repo"); then
          ghc_drop "$dir/$repo~r~*"
          key=$(printf '%s' "$key" | tr 'A-Z' 'a-z')
          if [[ "$key" =~ ^[0-9]{1,9}$ ]]; then ghc_drop "$dir/$repo~n-$((10#$key))~*"
          elif [[ "$key" =~ ^[0-9a-f]{7,64}$ ]]; then ghc_drop "$dir/$repo~s-${key:0:12}~*"
          fi
        fi
        [ "$id" -gt "$max" ] && max=$id
      done < <(printf '%s' "${out#*$'\n'}" | jq -r '.wakes[] | [(.id|tostring), (.repo // ""), (.key // "" | tostring)] | @tsv' 2>/dev/null)
      { printf '%s %s\n' "$max" "$now" > "$dir/.wakes.$$" && mv -f "$dir/.wakes.$$" "$dir/.wakes"; } 2>/dev/null
      rm -f "$dir/.wakes.$$" 2>/dev/null
      if [ -e "$dir/.wake-down" ]; then
        rm -f "$dir/.wake-down" 2>/dev/null
        _ghc_log "wakes reachable again — webhook invalidation is back on"
      fi ;;
    *)
      [ -e "$dir/.wake-down" ] || _ghc_log "wakes unreachable (${head#ERR }) — TTL only"
      printf '%s\n' "$now" > "$dir/.wake-down" 2>/dev/null ;;
  esac
  exec {lfd}>&-
  return 0
}

# _ghc_hdr_info <out> — status, etag, cache-control from an `-i` header block.
_ghc_hdr_info() {
  awk '
    NR == 1 { line = $0; sub(/\r$/, "", line); if (line ~ /^HTTP\/[0-9.]+ [0-9][0-9][0-9]/) { split(line, a, " "); st = a[2] }; next }
    /^\r?$/ { exit }
    { line = $0; sub(/\r$/, "", line); k = line; sub(/:.*/, "", k); k = tolower(k); v = line; sub(/^[^:]*:[ \t]*/, "", v)
      if (k == "etag") et = v; else if (k == "cache-control") cc = v }
    END { printf "1\037%s\037%s\037%s", (st == "" ? "000" : st), et, cc }' "$1" 2>/dev/null
}

# _ghc_trace_info <rec> — request count, then the LAST request's status, etag
# and cache-control, from the shim's trace records (fields 3, 9, 10).
_ghc_trace_info() {
  awk -F'\037' 'NF >= 3 { n++; st = $3; et = $9; cc = $10 } END { printf "%d\037%s\037%s\037%s", n, (st == "" ? "000" : st), et, cc }' "$1" 2>/dev/null
}

# ghc_main <trace|hdr> <gh args…> — rc 1: not handled, nothing was run, the
# shim runs the call as before (a write first drops what it changes). rc 0:
# handled; GHC_RC is the exit code, GHC_SERVED is cache | 304 | 200, GHC_LPATH
# is the endpoint for a ledger row.
ghc_main() {
  local mode="${1:-}"; shift
  local h dir now key tag f work age ws=1 inm="" info n st et cc rc
  GHC_RC=0; GHC_SERVED=""; GHC_LPATH=""
  h=$(_ghc_home) || return 1
  dir="$h/state/gh-cache"
  if ! ghc_eligible "$@"; then ghc_note_write "$dir" "$@"; return 1; fi
  command -v gh_quota_bucket >/dev/null 2>&1 && command -v _ghl_run_capture >/dev/null 2>&1 || return 1
  mkdir -p "$dir" 2>/dev/null || return 1
  ghc_knobs "$dir"
  [ "$GHC_TTL" -gt 0 ] || return 1
  now=$(ghc_now)
  key=$(ghc_key "$(gh_quota_bucket)" "${GHC_ARGV[@]}") || return 1
  [ -n "$key" ] || return 1
  tag=$(ghc_tag "$GHC_ENDPOINT")
  f="$dir/$tag~$key"
  work=$(mktemp -d "${TMPDIR:-/tmp}/gh-cache.XXXXXX" 2>/dev/null) || return 1
  GHC_LPATH=$(_ghc_bare "$GHC_ENDPOINT")
  if ghc_read "$f"; then
    age=$((now - GHC_E_AT))
    if [ "$age" -ge 0 ] && [ "$age" -le "$GHC_TTL" ]; then
      ws=0
      [ "$age" -gt "$GHC_GRACE" ] && { ghc_wake_sync "$dir" "$now"; ws=$?; }
      if [ "$ws" = 0 ] && cp "$f" "$work/e" 2>/dev/null && ghc_read "$work/e"; then
        ghc_replay "$work/e" cache "$GHC_INCLUDE"
        GHC_RC=$GHC_E_RC; GHC_SERVED=cache
        rm -rf "$work"
        return 0
      fi
    fi
    # Past the TTL, or the sync lock was busy: a conditional request, against a
    # private copy so a drop or sweep in the meantime cannot lose the body.
    if [ "$ws" != 0 ] && cp "$f" "$work/e" 2>/dev/null && ghc_read "$work/e"; then inm="$GHC_E_ETAG"; fi
  fi
  rc=0
  if [ -n "$inm" ]; then
    _ghl_run_capture "$mode" "$work/out" "$work/err" "${GHC_ARGV[@]}" -H "If-None-Match: $inm" || rc=$?
  else
    _ghl_run_capture "$mode" "$work/out" "$work/err" "${GHC_ARGV[@]}" || rc=$?
  fi
  if [ "$mode" = hdr ]; then info=$(_ghc_hdr_info "$work/out"); else info=$(_ghc_trace_info "${_ghl_rec:-/dev/null}"); fi
  IFS=$'\037' read -r n st et cc <<<"$info"
  if [ "$st" = 304 ] && [ -n "$inm" ]; then
    ghc_replay "$work/e" 304 "$GHC_INCLUDE"
    ghc_touch "$f" "$work/e" "$now"
    GHC_RC=$GHC_E_RC; GHC_SERVED=304
    rm -rf "$work"
    return 0
  fi
  cat "$work/out" 2>/dev/null
  cat "$work/err" >&2 2>/dev/null
  GHC_RC=$rc; GHC_SERVED=200
  cc=$(printf '%s' "${cc:-}" | tr 'A-Z' 'a-z')
  if [ "$st" = 200 ] && [ "$rc" = 0 ] && [ "${n:-0}" = 1 ] && [ ! -s "$work/err" ] \
     && [[ "${et:-}" =~ ^(W/)?\"[^\"$'\t']*\"$ ]] && [[ "$cc" != *no-store* ]] \
     && [ "$(wc -c < "$work/out" | tr -d ' ')" -le "${GH_ETAG_MAX_BYTES:-1048576}" ]; then
    if ghc_store "$f" "$work/out" "$now" "$et" "$rc"; then
      command -v _gh_etag_sweep >/dev/null 2>&1 && _gh_etag_sweep "$dir" >/dev/null 2>&1
    fi
  else
    rm -f "$f" 2>/dev/null
  fi
  rm -rf "$work"
  return 0
}
