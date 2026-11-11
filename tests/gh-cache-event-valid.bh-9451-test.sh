#!/bin/bash
# tests/gh-cache-event-valid.bh-9451-test.sh — BH-9451 (BH-9417.0): the gh shim
# cache (bin/lib/gh-cache.sh under bin/gh-ledger/gh) serves a PR-, ticket- or
# sha-scoped entry past GH_CACHE_TTL_S with 0 requests while the wake feed is
# healthy, up to GH_CACHE_EVENT_MAX_S (or longer when ghc_sweep_covers says a
# sweep re-validated it). Every other case keeps the BH-8066 path.
#
# Sections: A served past the TTL, B past the event max, C wakes drop entries,
# E the feed is down, F the knob is off, G a failed read, K knobs, D the seams,
# W wake rows with and without kind.
#
# Nothing touches the network. The real `gh` is a counting stub that knows
# only repos/o/r/… endpoints: any other endpoint logs UNSTUBBED and exits 99.
# The jobs worker is a fixture jobs-client.sh that answers GET /api/wakes from
# wakes.json (only the rows with id > since). The cache clock is GH_CACHE_NOW.
#
# Run from anywhere: bash tests/gh-cache-event-valid.bh-9451-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

scratch_install_closure bin/gh-ledger/gh "$T/inst" >/dev/null || { echo "FAIL: closure install"; exit 1; }
SHIMDIR="$T/inst/bin/gh-ledger"
for s in gh-cache-scope.sh gh-cache-sweep.sh gh-cache-eligible.sh; do
  [ -r "$T/inst/bin/lib/$s" ] && ok || bad "0: bin/lib/$s must be in the shim's closure"
done

T0=1792699200   # determinism: ok pinned cache clock (2026-10-22T20:00:00Z)
export HARNESS="$T/h"
mkdir -p "$T/h/logs" "$T/h/state" "$T/h/bin/lib/jobs" "$T/tmp" "$T/real" "$T/lane" "$T/resp"
export TMPDIR="$T/tmp"
export GH_STUB_DIR="$T"
export HARNESS_SECRET=fixture-secret-bh9451
unset GH_TOKEN GITHUB_TOKEN GH_DEBUG HARNESS_LANE HARNESS_LANE_PROJECT PROJECT GH_LEDGER_OFF \
  GH_LEDGER_DEPTH GH_LEDGER_BY_CALLER GH_CACHE_TTL_S GH_CACHE_WAKE_GRACE_S GH_CACHE_EVENT_MAX_S \
  GH_CACHE_NOW GH_ETAG
LED="$T/h/state/gh-rest-ledger"
CACHE="$T/h/state/gh-cache"

# ── the real `gh`: a counting stub ─────────────────────────────────────────
# Body and ETag are per endpoint: {"ep":"<ep>","v":<ver>} and "e-<ver>-<ep>".
# A request whose If-None-Match is the current ETag answers 304. resp/status
# (403) or resp/rc75 makes every request fail. `api rate_limit` is the shim's
# own trace-format probe and is not recorded.
cat > "$T/real/gh" <<'STUB'
#!/bin/bash
S="$GH_STUB_DIR"
[ "$*" = "api rate_limit" ] || printf '%s\n' "$*" >> "$S/real-calls.txt"
inm=""; inc=0; ep=""; prev=""
for a in "$@"; do
  case "$prev" in
    -H|--header) case "$a" in If-None-Match:*) inm="${a#If-None-Match: }" ;; esac ;;
    -X|-f|-F|-q|-t|--jq|--template|--method) ;;
    *) case "$a" in -i|--include) inc=1 ;; -*|api) ;; *) [ -z "$ep" ] && ep="$a" ;; esac ;;
  esac
  prev="$a"
done
[ "$*" = "api rate_limit" ] && ep=rate_limit
case "$ep" in
  rate_limit|repos/o/r/*) ;;
  *) printf 'UNSTUBBED %s\n' "$*" >> "$S/unstubbed.txt"; exit 99 ;;
esac
[ -e "$S/resp/rc75" ] && [ "$ep" != rate_limit ] && { printf 'gh: rate limited\n' >&2; exit 75; }
st=$(cat "$S/resp/status" 2>/dev/null); st="${st:-200}"
ver=$(cat "$S/resp/ver" 2>/dev/null); ver="${ver:-1}"
etag="\"e-$ver-$(printf '%s' "$ep" | tr '/?=&' '____')\""
if [ "$inm" = "$etag" ] && [ "$st" = 200 ]; then st=304; fi
txt=OK; case "$st" in 304) txt="Not Modified" ;; 403) txt="Forbidden" ;; esac
if [ "${GH_DEBUG:-}" = api ]; then
  {
    printf '* Request at 2026-10-22 20:00:00.100000 +0000 UTC m=+0.020000000\n* Request to https://api.github.com/%s\n> GET /%s HTTP/1.1\n> Host: api.github.com\n' "$ep" "$ep"
    [ -n "$inm" ] && printf '> If-None-Match: %s\n' "$inm"
    printf '\n< HTTP/2.0 %s %s\n' "$st" "$txt"
    [ "$st" = 403 ] || printf '< Etag: %s\n' "$etag"
    printf '< X-Ratelimit-Limit: 6600\n< X-Ratelimit-Remaining: 6000\n< X-Ratelimit-Reset: 1792702800\n< X-Ratelimit-Resource: core\n< X-Ratelimit-Used: 600\n\n'
    printf '* Request took 20ms\n'
  } >&2
fi
if [ "$inc" = 1 ]; then
  printf 'HTTP/2.0 %s %s\r\n' "$st" "$txt"
  [ "$st" = 403 ] || printf 'Etag: %s\r\n' "$etag"
  printf 'X-Ratelimit-Limit: 6600\r\nX-Ratelimit-Remaining: 6000\r\nX-Ratelimit-Reset: 1792702800\r\nX-Ratelimit-Resource: core\r\nX-Ratelimit-Used: 600\r\n\r\n'
fi
case "$st" in
  200) printf '{"ep":"%s","v":%s}' "$ep" "$ver"; exit 0 ;;
  304) printf 'gh: HTTP 304\n' >&2; exit 1 ;;
  *) printf '{"message":"fixture %s"}' "$st"; printf 'gh: fixture %s (HTTP %s)\n' "$st" "$st" >&2; exit 1 ;;
esac
STUB
chmod +x "$T/real/gh"
printf '#!/bin/bash\ngh "$@"\nexit $?\n' > "$T/lane/my-lane.sh"; chmod +x "$T/lane/my-lane.sh"

# The jobs worker, as a fixture client. wakes.json holds every wake; the answer
# to GET /api/wakes?since=<n> is the rows with id > n. wakes.down fails it.
cat > "$T/h/bin/jobs-client.sh" <<'JC'
#!/bin/bash
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$GH_STUB_DIR/jobs-calls.txt"
  case "$2" in
    "/api/wakes?since="*)   # determinism: ok clock-rolling-window since= is a wake id watermark, not a time window
      [ -e "$GH_STUB_DIR/wakes.down" ] && return 1
      local since="${2#*since=}"
      if [ -r "$GH_STUB_DIR/wakes.json" ]; then
        jq -c --argjson s "$since" '.wakes |= map(select(.id > $s))' "$GH_STUB_DIR/wakes.json"
      else printf '{"wakes":[]}'
      fi
      return 0 ;;
  esac
  return 1
}
wake_cursor_get() { return 2; }
hub_box_name() { printf 'fixture-hub'; }
JC
: > "$T/h/bin/lib/jobs/req.sh"

P0="$SHIMDIR:$T/real:/usr/bin:/bin"
NOWV=$T0
run() { # run <args…> — at cache clock NOWV, through a lane script, shim first on PATH
  env PATH="$P0" GH_CACHE_NOW="$NOWV" "$T/lane/my-lane.sh" "$@" > "$T/out" 2> "$T/err"
  echo $? > "$T/rc"
}
calls() { local n; n=$(grep -c . "$T/real-calls.txt" 2>/dev/null); echo "${n:-0}"; }
jcalls() { local n; n=$(grep -c "api/wakes?since" "$T/jobs-calls.txt" 2>/dev/null); echo "${n:-0}"; }
nrows() { local n; n=$(cat "$LED"/*.tsv 2>/dev/null | grep -c .); echo "${n:-0}"; }
rows_from() { cat "$LED"/*.tsv 2>/dev/null | tail -n +"$1"; }   # rows_from <first row number>
lastserved() { cat "$LED"/*.tsv 2>/dev/null | tail -n 1 | awk -F'\t' '{print $15}'; }
newcalls() { tail -n +"$(( $1 + 1 ))" "$T/real-calls.txt" 2>/dev/null; }   # newcalls <calls before>
reset() { # reset [event max] — a fresh cache, ledger and feed; the wake check armed, not seeded
  for p in "$LED" "$CACHE"; do [ -e "$p" ] && scratch_rm "$p"; done
  rm -f "$T/real-calls.txt" "$T/jobs-calls.txt" "$T/wakes.json" "$T/wakes.down" "$T/unstubbed.txt" \
    "$T/resp/status" "$T/resp/rc75" "$T/resp/ver" "$T/h/logs/gh-cache.log"
  NOWV=$T0
  mkdir -p "$CACHE"; printf '100 0\n' > "$CACHE/.wakes"
  export GH_CACHE_TTL_S=60 GH_CACHE_WAKE_GRACE_S=5 GH_CACHE_EVENT_MAX_S="${1:-7200}"
}
head_of() { printf '%02xbeef%034x' "$1" "$1"; }   # a 40-hex head sha, unique in its first 12
tick() { # tick — every PR path for PRs 1..20 at NOWV; bodies checked against the stub's
  local n ep
  for n in $(seq 1 20); do
    for ep in "repos/o/r/pulls/$n" "repos/o/r/pulls/$n/reviews" "repos/o/r/issues/$n/comments" \
              "repos/o/r/pulls/$n/files" "repos/o/r/commits/$(head_of "$n")/status"; do
      run api "$ep"
      [ "$(cat "$T/out")" = "{\"ep\":\"$ep\",\"v\":1}" ] && [ "$(cat "$T/rc")" = 0 ] || TICK_BAD="$TICK_BAD $ep@$NOWV"
    done
  done
}

# ══ A. served past the TTL ══════════════════════════════════════════════════
# A1 (the REPRO): 20 PRs, 12 ticks over 6600 s. Tick 1 makes 100 requests;
# ticks 2..12 make 0, and every ledger row after tick 1 says served=cache.
reset 7200
TICK_BAD=""
tick
[ "$(calls)" = 100 ] && ok || bad "A1a: tick 1 must make 100 requests, got $(calls)"
R1=$(nrows)
for k in $(seq 1 11); do NOWV=$((T0 + k * 600)); tick; done
[ "$(calls)" = 100 ] && ok || bad "A1b: ticks 2..12 must make 0 requests, got $(( $(calls) - 100 )): $(newcalls 100 | head -n 3)"
[ -z "$TICK_BAD" ] && ok || bad "A1c: every replay must equal the stored body with rc 0, bad:$(printf '%s' "$TICK_BAD" | cut -c1-300)"
NR=$(rows_from $((R1 + 1)) | grep -c .)
NC=$(rows_from $((R1 + 1)) | awk -F'\t' '$15 == "cache"' | grep -c .)
[ "$NR" = 1100 ] && [ "$NC" = 1100 ] && ok || bad "A1d: 1100 ledger rows after tick 1, all served=cache, got $NR rows, $NC cache"
[ ! -e "$T/unstubbed.txt" ] && ok || bad "A1e: no unstubbed endpoint, got: $(cat "$T/unstubbed.txt")"
# The wake feed was read: one read per tick past the grace.
[ "$(jcalls)" = 11 ] && ok || bad "A1f: one wake read per tick after tick 1, got $(jcalls)"

# ══ C. wakes drop entries (continues A1's cache) ════════════════════════════
# C1: a wake for PR 7 at tick 13: PR 7's four n-7 paths are read again once,
# by the first caller (no If-None-Match); a second read in the tick is cache.
printf '{"wakes":[{"id":101,"repo":"O/R","kind":"pr","key":"7"}]}' > "$T/wakes.json"
NOWV=$((T0 + 7200))
B=$(calls); TICK_BAD=""
tick
[ "$(calls)" = $((B + 4)) ] && ok || bad "C1a: a wake for PR 7 makes exactly 4 requests, got $(( $(calls) - B )): $(newcalls "$B")"
[ "$(newcalls "$B" | LC_ALL=C sort | tr '\n' ' ')" = "api repos/o/r/issues/7/comments api repos/o/r/pulls/7 api repos/o/r/pulls/7/files api repos/o/r/pulls/7/reviews " ] \
  && ok || bad "C1b: the 4 requests are PR 7's own paths, unconditional, got: $(newcalls "$B" | tr '\n' '|')"
[ -z "$TICK_BAD" ] && ok || bad "C1c: tick 13 bodies, bad:$TICK_BAD"
B=$(calls)
run api repos/o/r/pulls/7/reviews
[ "$(calls)" = "$B" ] && [ "$(lastserved)" = cache ] && ok || bad "C1d: a second read of PR 7 in the tick is cache, got $(( $(calls) - B )) requests, served $(lastserved)"
# C3: a checks wake for PR 7's head re-reads its status once, and nothing else.
printf '{"wakes":[{"id":101,"repo":"O/R","kind":"pr","key":"7"},{"id":102,"repo":"O/R","kind":"checks","key":"%s"}]}' "$(head_of 7)" > "$T/wakes.json"
# The entries are 7210 s old here, so the max is raised past that for this tick.
NOWV=$((T0 + 7210)); export GH_CACHE_EVENT_MAX_S=7300
B=$(calls); TICK_BAD=""
tick
[ "$(newcalls "$B" | tr '\n' ' ')" = "api repos/o/r/commits/$(head_of 7)/status " ] && ok \
  || bad "C3: a checks wake re-reads only PR 7's head status, got: $(newcalls "$B" | tr '\n' '|')"

# C2: a wake for PR 7 drops pulls/7, never pulls/70.
reset 7200
run api repos/o/r/pulls/7; run api repos/o/r/pulls/70
printf '{"wakes":[{"id":101,"repo":"O/R","kind":"pr","key":"7"}]}' > "$T/wakes.json"
NOWV=$((T0 + 100)) run api repos/o/r/pulls/70
[ "$(calls)" = 2 ] && [ "$(lastserved)" = cache ] && ok || bad "C2a: pulls/70 survives a wake for PR 7, got $(calls) calls, served $(lastserved)"
NOWV=$((T0 + 100)) run api repos/o/r/pulls/7
[ "$(calls)" = 3 ] && [ "$(lastserved)" = 200 ] && ok || bad "C2b: pulls/7 is read again after its wake, got $(calls) calls, served $(lastserved)"

# A2: an entry whose age equals the event max is served cache.
reset 300
run api repos/o/r/pulls/12
NOWV=$((T0 + 300)) run api repos/o/r/pulls/12
[ "$(calls)" = 1 ] && [ "$(lastserved)" = cache ] && ok || bad "A2: age == GH_CACHE_EVENT_MAX_S is served cache, got $(calls) calls, served $(lastserved)"
# A3: issues/N is event-validated too.
reset 300
run api repos/o/r/issues/5
NOWV=$((T0 + 200)) run api repos/o/r/issues/5
[ "$(calls)" = 1 ] && [ "$(lastserved)" = cache ] && ok || bad "A3: issues/5 past the TTL is served cache, got $(calls) calls, served $(lastserved)"
# A4: a list (the `r` tag) is not event-validated: a conditional request.
reset 7200
run api 'repos/o/r/pulls?state=open'
NOWV=$((T0 + 61)) run api 'repos/o/r/pulls?state=open'
[ "$(calls)" = 2 ] && tail -n 1 "$T/real-calls.txt" | grep -qF 'If-None-Match:' && [ "$(lastserved)" = 304 ] && ok \
  || bad "A4: an r-tag entry past the TTL is a conditional request, got $(calls) calls, served $(lastserved)"

# ══ B. past the event max ═══════════════════════════════════════════════════
# B1: age 301 with max 300: one request with If-None-Match, a 304 is served 304.
reset 300
run api repos/o/r/pulls/12
NOWV=$((T0 + 301)) run api repos/o/r/pulls/12
[ "$(calls)" = 2 ] && tail -n 1 "$T/real-calls.txt" | grep -qF 'If-None-Match: "e-1-repos_o_r_pulls_12"' && ok \
  || bad "B1a: past the event max is a conditional request, got $(calls) calls: $(tail -n 1 "$T/real-calls.txt")"
[ "$(lastserved)" = 304 ] && [ "$(cat "$T/out")" = '{"ep":"repos/o/r/pulls/12","v":1}' ] && ok || bad "B1b: the 304 is served 304 with the body, got $(lastserved): $(cat "$T/out")"
B1_RESULT="$(calls) $(lastserved)"
# B2: a sweep seam that covers the entry serves it cache past the max.
scratch_install_closure bin/gh-ledger/gh "$T/inst3" >/dev/null
printf '#!/bin/bash\nghc_sweep_covers() { printf "%%s %%s %%s\\n" "$1" "$2" "$3" >> "$GH_STUB_DIR/sweep-asks.txt"; return 0; }\n' \
  > "$T/inst3/bin/lib/gh-cache-sweep.sh"
reset 300; rm -f "$T/sweep-asks.txt"
run api repos/o/r/pulls/12
env PATH="$T/inst3/bin/gh-ledger:$T/real:/usr/bin:/bin" GH_CACHE_NOW="$((T0 + 301))" "$T/lane/my-lane.sh" api repos/o/r/pulls/12 > "$T/out" 2>/dev/null
[ "$(calls)" = 1 ] && [ "$(lastserved)" = cache ] && ok || bad "B2a: a sweep that covers the entry serves it cache, got $(calls) calls, served $(lastserved)"
grep -q "^$CACHE o__r~n-12 $T0\$" "$T/sweep-asks.txt" 2>/dev/null && ok || bad "B2b: the sweep seam is asked with <dir> <tag> <fetched>, got: $(cat "$T/sweep-asks.txt" 2>/dev/null)"

# ══ E. the feed is down ═════════════════════════════════════════════════════
reset 7200
run api repos/o/r/pulls/12
: > "$T/wakes.down"
for a in 61 130 200; do NOWV=$((T0 + a)) run api repos/o/r/pulls/12; done
[ "$(calls)" = 4 ] && [ "$(grep -c 'If-None-Match' "$T/real-calls.txt")" = 3 ] && ok \
  || bad "E1: feed down = the TTL rule, 3 conditional requests, got $(calls) calls: $(cat "$T/real-calls.txt" | tr '\n' '|')"
[ "$(grep -c 'wakes unreachable' "$T/h/logs/gh-cache.log" 2>/dev/null)" = 1 ] && [ "$(grep -c . "$T/h/logs/gh-cache.log")" = 1 ] && ok \
  || bad "E2: exactly 1 'wakes unreachable' line, got: $(cat "$T/h/logs/gh-cache.log" 2>/dev/null)"
# E3: a busy sync lock past the TTL: a conditional request, never a serve.
reset 7200
run api repos/o/r/pulls/12
exec 9>>"$CACHE/.wakes.lock"; flock -n 9
NOWV=$((T0 + 61)) run api repos/o/r/pulls/12
exec 9>&-
[ "$(calls)" = 2 ] && [ "$(lastserved)" = 304 ] && ok || bad "E3: a busy lock past the TTL is a conditional request, got $(calls) calls, served $(lastserved)"

# ══ F. the knob is off: today's sequence ════════════════════════════════════
reset 0
run api repos/o/r/pulls/12
NOWV=$((T0 + 61)) run api repos/o/r/pulls/12
[ "$(calls)" = 2 ] && [ "$(lastserved)" = 304 ] && ok || bad "F1a: GH_CACHE_EVENT_MAX_S=0 past the TTL is a conditional request, got $(calls) calls, served $(lastserved)"
[ "$(jcalls)" = 0 ] && ok || bad "F1b: with the knob off no wake read happens past the TTL, got $(jcalls)"

# ══ G. a failed read ════════════════════════════════════════════════════════
for mode in 403 rc75; do
  reset 300
  run api repos/o/r/pulls/12
  if [ "$mode" = 403 ]; then printf 403 > "$T/resp/status"; else : > "$T/resp/rc75"; fi
  NOWV=$((T0 + 301)) run api repos/o/r/pulls/12
  [ "$(cat "$T/rc")" != 0 ] && ok || bad "G1.$mode: the caller gets the failure, got rc $(cat "$T/rc")"
  [ "$(find "$CACHE" -maxdepth 1 -type f -name 'o__r~n-12~*' | grep -c .)" = 0 ] && ok || bad "G1.$mode: the entry is dropped"
  rm -f "$T/resp/status" "$T/resp/rc75"
  B=$(calls)
  NOWV=$((T0 + 302)) run api repos/o/r/pulls/12
  [ "$(calls)" = $((B + 1)) ] && [ "$(lastserved)" = 200 ] && ok || bad "G1.$mode: the next read is a request, got $(( $(calls) - B )), served $(lastserved)"
done

# ══ K. knobs ════════════════════════════════════════════════════════════════
knob() { # knob <.knobs line|-> [env value|-] — prints GHC_EVENT_MAX
  ( unset GH_CACHE_EVENT_MAX_S GH_CACHE_TTL_S GH_CACHE_WAKE_GRACE_S
    mkdir -p "$T/kdir"; rm -f "$T/kdir/.knobs"
    [ "$1" = - ] || printf '%s\n' "$1" > "$T/kdir/.knobs"
    [ "${2:--}" = - ] || export GH_CACHE_EVENT_MAX_S="$2"
    export GH_CACHE_NOW=$((T0 + 1))
    . "$T/inst/bin/lib/gh-cache.sh" >/dev/null 2>&1 || exit 1
    ghc_knobs "$T/kdir"; printf '%s' "${GHC_EVENT_MAX:-unset}" )
}
[ "$(knob "60 5 $T0")" = 300 ] && ok || bad "K1: a 3-field .knobs gives the fallback 300, got $(knob "60 5 $T0")"
[ "$(knob "60 5 $T0 900")" = 900 ] && ok || bad "K2: a 4th .knobs field 900 gives 900, got $(knob "60 5 $T0 900")"
[ "$(knob "60 5 $T0 900" 42)" = 42 ] && ok || bad "K3: an env value wins over .knobs, got $(knob "60 5 $T0 900" 42)"
[ "$(knob - abc)" = 300 ] && [ "$(knob "60 5 $T0 x9")" = 300 ] && ok || bad "K4: a non-numeric value gives 300, got $(knob - abc) / $(knob "60 5 $T0 x9")"
[ "$(knob "60 5 $T0 0")" = 0 ] && ok || bad "K4b: 0 in .knobs is off, got $(knob "60 5 $T0 0")"
FRAG="$REPO/catalog/lanes.d/_lib.gh-ledger.knobs.d/GH_CACHE_EVENT_MAX_S.json"
[ "$(jq -r '[.env, .read_in, .type, .default, .min, .zero_means, .required] | map(tostring) | join(" ")' "$FRAG" 2>/dev/null)" \
  = "GH_CACHE_EVENT_MAX_S bin/lib/gh-cache.sh int 300 0 off false" ] && ok || bad "K5: the knob fragment, got $(cat "$FRAG" 2>/dev/null)"
# K6: the 4-field .knobs line a resolve writes is read back by the 3-field
# reader of older code (read -r ft fg fa _), field 3 stays the timestamp.
( read -r ft fg fa _ <<<"60 5 $T0 900"; [ "$fa" = "$T0" ] ) && ok || bad "K6: field 3 of a 4-field .knobs is the timestamp"

# ══ D. the seams: each default answers as today ═════════════════════════════
LIB="$T/inst/bin/lib/gh-cache.sh"
D1=$( . "$LIB" >/dev/null 2>&1 || exit 1
  for p in graphql rate_limit 'rate_limit?x=1' repos/o/r/actions/artifacts/77/zip repos/o/r/actions/jobs/9/logs \
           installation/token 'repos/o/r/pulls/1?per_page=5' repos/o/r/pulls/1; do
    ghc_path_ok "$p" && printf 'y' || printf 'n'
  done)
[ "$D1" = nnnnnnyy ] && ok || bad "D1: ghc_path_ok refuses today's list, got '$D1'"
# ghc_eligible asks ghc_path_ok: a refusing override makes a plain GET ineligible.
D1b=$( . "$LIB" >/dev/null 2>&1 || exit 1; ghc_path_ok() { return 1; }; ghc_eligible api repos/o/r/pulls/1 && printf y || printf n)
[ "$D1b" = n ] && ok || bad "D1b: ghc_eligible must ask ghc_path_ok, got '$D1b'"
mkd() { rm -rf "$T/dd"; mkdir -p "$T/dd"; for e in o__r~r~a o__r~n-7~a o__r~n-7~b o__r~n-70~a o__r~s-abcdef012345~a o__r2~n-7~a; do : > "$T/dd/$e"; done; }
lsd() { ls "$T/dd" | LC_ALL=C sort | tr '\n' ' '; }
mkd; ( . "$LIB" >/dev/null 2>&1; ghc_wake_drop "$T/dd" o__r pr 7 )
[ "$(lsd)" = "o__r2~n-7~a o__r~n-70~a o__r~s-abcdef012345~a " ] && ok || bad "D2a: ghc_wake_drop pr 7, got '$(lsd)'"
mkd; ( . "$LIB" >/dev/null 2>&1; ghc_wake_drop "$T/dd" o__r checks ABCDEF0123456789abcdef0123456789abcdef01 )
[ "$(lsd)" = "o__r2~n-7~a o__r~n-70~a o__r~n-7~a o__r~n-7~b " ] && ok || bad "D2b: ghc_wake_drop by sha, got '$(lsd)'"
mkd; ( . "$LIB" >/dev/null 2>&1; ghc_note_write "$T/dd" api -X PATCH repos/o/r/issues/7 -f state=closed )
[ "$(lsd)" = "o__r2~n-7~a o__r~n-70~a o__r~s-abcdef012345~a " ] && ok || bad "D3a: ghc_note_write drops the same set, got '$(lsd)'"
D3b=$( . "$LIB" >/dev/null 2>&1; ghc_wake_drop() { printf '%s|' "$2" "$3" "$4"; }; ghc_note_write "$T/dd" api -X PATCH repos/o/r/pulls/7 -f x=y
  ghc_note_write "$T/dd" api -X POST repos/o/r/statuses/ABCDEF0123456789abcdef0123456789abcdef01 -f x=y; ghc_note_write "$T/dd" api -X POST repos/o/r/labels -f x=y)
[ "$D3b" = "o__r|write|7|o__r|write|abcdef012345|o__r|write||" ] && ok || bad "D3b: ghc_note_write goes through ghc_wake_drop, got '$D3b'"
D4=$( . "$LIB" >/dev/null 2>&1; printf '%s ' "$(ghc_tag repos/o/r/pulls/9/reviews)"
  ghc_scope_tag() { [ "$1" = repos/o/r/labels/x ] && printf 'o__r~n-9'; }
  printf '%s %s' "$(ghc_tag https://api.github.com/repos/o/r/labels/x)" "$(ghc_tag repos/o/r/pulls/3)")
[ "$D4" = "o__r~n-9 o__r~n-9 o__r~n-3" ] && ok || bad "D4: ghc_tag asks ghc_scope_tag first with the bare endpoint, got '$D4'"
# D5: with the three seam files gone, tick 1 and B1 give the same results.
scratch_install_closure bin/gh-ledger/gh "$T/inst2" >/dev/null
rm -f "$T/inst2/bin/lib/gh-cache-scope.sh" "$T/inst2/bin/lib/gh-cache-sweep.sh" "$T/inst2/bin/lib/gh-cache-eligible.sh"
P0="$T/inst2/bin/gh-ledger:$T/real:/usr/bin:/bin"
reset 7200; TICK_BAD=""
tick; NOWV=$((T0 + 600)); tick
[ "$(calls)" = 100 ] && [ -z "$TICK_BAD" ] && ok || bad "D5a: no seam files: tick 1 + tick 2 make 100 requests, got $(calls) bad:$TICK_BAD"
reset 300
run api repos/o/r/pulls/12
NOWV=$((T0 + 301)) run api repos/o/r/pulls/12
[ "$(calls) $(lastserved)" = "$B1_RESULT" ] && ok || bad "D5b: no seam files: B1 gives '$B1_RESULT', got '$(calls) $(lastserved)'"
D5c=$( . "$T/inst2/bin/lib/gh-cache.sh" >/dev/null 2>&1; ghc_eligible api graphql && printf y || printf n; ghc_eligible api repos/o/r/pulls/1 && printf y || printf n)
[ "$D5c" = ny ] && ok || bad "D5c: no seam files: the inline ghc_path_ok refuses graphql, got '$D5c'"
P0="$SHIMDIR:$T/real:/usr/bin:/bin"

# ══ W. wake rows with and without kind ══════════════════════════════════════
reset 7200
run api repos/o/r/pulls/7; run api repos/o/r/pulls/9; run api repos/o/r/pulls/11
printf '{"wakes":[{"id":101,"repo":"O/R","key":"7"},{"id":102,"repo":"O/R","kind":"","key":"9"}]}' > "$T/wakes.json"
NOWV=$((T0 + 100)) run api repos/o/r/pulls/7
NOWV=$((T0 + 100)) run api repos/o/r/pulls/9
NOWV=$((T0 + 100)) run api repos/o/r/pulls/11
[ "$(newcalls 3 | tr '\n' ' ')" = "api repos/o/r/pulls/7 api repos/o/r/pulls/9 " ] && ok \
  || bad "W2: wake rows with no kind or an empty kind still drop their PR, got: $(newcalls 3 | tr '\n' '|')"
[ "$(cut -d' ' -f1 "$CACHE/.wakes")" = 102 ] && ok || bad "W2b: the watermark moves to 102, got $(cat "$CACHE/.wakes")"
# W1: ghc_wake_sync passes kind through to ghc_wake_drop.
W1=$( . "$LIB" >/dev/null 2>&1; ghc_wake_drop() { printf '%s|' "$2" "$3" "$4" >> "$T/w1.txt"; }
  rm -f "$T/w1.txt"; mkdir -p "$T/w1"; printf '200 0\n' > "$T/w1/.wakes"
  printf '{"wakes":[{"id":201,"repo":"O/R","kind":"checks","key":"ABC1234"},{"id":202,"repo":"O/R","key":"5"}]}' > "$T/wakes.json"
  GHC_TTL=60; GHC_GRACE=5; ghc_wake_sync "$T/w1" "$T0"; cat "$T/w1.txt")
[ "$W1" = "o__r|checks|ABC1234|o__r|-|5|" ] && ok || bad "W1: wake rows reach ghc_wake_drop as repo|kind|key, got '$W1'"

[ ! -e "$T/unstubbed.txt" ] && ok || bad "Z: no unstubbed endpoint over the suite, got: $(cat "$T/unstubbed.txt")"
echo "gh-cache-event-valid.bh-9451: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
