#!/bin/bash
# tests/gh-shim-cache.bh-8066-test.sh — BH-8066: the gh PATH shim
# (bin/gh-ledger/gh) is a read-through cache for `gh api` GETs, through
# bin/lib/gh-cache.sh.
#
# WHAT IS PINNED. On 2026-10-22 the fleet made 286,509 REST calls in 24 hours
# for 193 merged PRs, and two thirds of them re-read state that did not change.
# So a repeat GET inside GH_CACHE_TTL_S is answered from state/gh-cache/ with no
# request, a GET past the TTL is a conditional request (If-None-Match), a wake
# row that names the object drops its entries, and the ledger row says how the
# call was served (column 15: cache | 304 | 200 | -).
#
# Sections: E eligibility, S storage + retention, C the cache cycle, W wakes,
# R gh_rest through the cache, K knobs + identity, L ledger column 15,
# N the pass-through calls that never see the cache, F a missing lib.
#
# Nothing touches the network. The real `gh` is a stub that prints the gh
# 2.101 trace shape under GH_DEBUG=api (with `< Etag:` and `< Cache-Control:`
# lines) and the `-i` header block on stdout; the jobs worker is a fixture
# jobs-client.sh that defines `_jobs_req` and `wake_cursor_get`. The cache clock
# is pinned through GH_CACHE_NOW.
#
# Run from anywhere: bash tests/gh-shim-cache.bh-8066-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ── the install: the shim and every lib it sources, plus gh_rest's closure ──
scratch_install_closure bin/gh-ledger/gh "$T/inst" >/dev/null || { echo "FAIL: closure install"; exit 1; }
scratch_install_closure bin/lib/gh-rest.sh "$T/inst" >/dev/null || { echo "FAIL: gh-rest closure install"; exit 1; }
SHIMDIR="$T/inst/bin/gh-ledger"
LIB="$T/inst/bin/lib/gh-cache.sh"

T0=1792699200   # determinism: ok pinned cache clock (2026-10-22T20:00:00Z)
export HARNESS="$T/h"
mkdir -p "$T/h/logs" "$T/h/flags" "$T/h/state" "$T/h/bin/lib/jobs" "$T/tmp" "$T/real" "$T/lane" "$T/resp"
export TMPDIR="$T/tmp"
export GH_STUB_DIR="$T"
export HARNESS_SECRET=fixture-secret-bh8066
unset GH_TOKEN GITHUB_TOKEN GH_DEBUG HARNESS_LANE HARNESS_LANE_PROJECT PROJECT GH_LEDGER_OFF \
  GH_LEDGER_DEPTH GH_LEDGER_BY_CALLER GH_CACHE_TTL_S GH_CACHE_WAKE_GRACE_S GH_CACHE_NOW GH_ETAG
LED="$T/h/state/gh-rest-ledger"
CACHE="$T/h/state/gh-cache"

# ── the real `gh` ───────────────────────────────────────────────────────────
# The response is read from $T/resp/{status,etag,cc,body,redirect}. A request
# whose If-None-Match equals the current ETag answers 304, as GitHub does.
# `api rate_limit` is the shim's own trace-format probe and is not recorded.
cat > "$T/real/gh" <<'STUB'
#!/bin/bash
S="$GH_STUB_DIR"
[ "$*" = "api rate_limit" ] || printf '%s\n' "$*" >> "$S/real-calls.txt"
st=$(cat "$S/resp/status" 2>/dev/null); st="${st:-200}"
etag=$(cat "$S/resp/etag" 2>/dev/null)
cc=$(cat "$S/resp/cc" 2>/dev/null)
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
if [ -n "$etag" ] && [ "$inm" = "$etag" ] && [ "$st" = 200 ]; then st=304; fi
txt=OK; case "$st" in 304) txt="Not Modified" ;; 404) txt="Not Found" ;; 500) txt="Server Error" ;; esac
if [ "${GH_DEBUG:-}" = api ]; then
  {
    if [ -e "$S/resp/redirect" ]; then
      printf '* Request at 2026-10-22 20:00:00.000000 +0000 UTC m=+0.010000000\n* Request to https://api.github.com/%s\n> GET /%s HTTP/1.1\n> Host: api.github.com\n\n< HTTP/2.0 301 Moved Permanently\n< Location: https://api.github.com/%s\n\n* Request took 10ms\n' "$ep" "$ep" "$ep"
    fi
    printf '* Request at 2026-10-22 20:00:00.100000 +0000 UTC m=+0.020000000\n* Request to https://api.github.com/%s\n> GET /%s HTTP/1.1\n> Host: api.github.com\n' "$ep" "$ep"
    [ -n "$inm" ] && printf '> If-None-Match: %s\n' "$inm"
    printf '\n'
    if [ "$st" != 000 ]; then
      printf '< HTTP/2.0 %s %s\n' "$st" "$txt"
      [ -n "$cc" ] && printf '< Cache-Control: %s\n' "$cc"
      [ -n "$etag" ] && printf '< Etag: %s\n' "$etag"
      printf '< X-Ratelimit-Limit: 6600\n< X-Ratelimit-Remaining: 6000\n< X-Ratelimit-Reset: 1792702800\n< X-Ratelimit-Resource: core\n< X-Ratelimit-Used: 600\n\n'
      printf '* Request took 20ms\n'
    fi
  } >&2
fi
if [ "$inc" = 1 ] && [ "$st" != 000 ]; then
  printf 'HTTP/2.0 %s %s\r\n' "$st" "$txt"
  [ -n "$cc" ] && printf 'Cache-Control: %s\r\n' "$cc"
  [ -n "$etag" ] && printf 'Etag: %s\r\n' "$etag"
  printf 'X-Ratelimit-Limit: 6600\r\nX-Ratelimit-Remaining: 6000\r\nX-Ratelimit-Reset: 1792702800\r\nX-Ratelimit-Resource: core\r\nX-Ratelimit-Used: 600\r\n\r\n'
fi
case "$st" in
  200) cat "$S/resp/body" 2>/dev/null; exit 0 ;;
  304) printf 'gh: HTTP 304\n' >&2; exit 1 ;;
  000) printf 'error connecting to api.github.com\n' >&2; exit 1 ;;
  *) printf '{"message":"fixture %s"}' "$st"; printf 'gh: fixture %s (HTTP %s)\n' "$st" "$st" >&2; exit 1 ;;
esac
STUB
chmod +x "$T/real/gh"

# A lane that calls gh by name, so the shim's parent is a script.
printf '#!/bin/bash\ngh "$@"\nexit $?\n' > "$T/lane/my-lane.sh"; chmod +x "$T/lane/my-lane.sh"

# The jobs worker, as a fixture client: 0 network. wakes.json is the answer to
# GET /api/wakes?since=; a wakes.down file makes that read fail.
cat > "$T/h/bin/jobs-client.sh" <<'JC'
#!/bin/bash
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$GH_STUB_DIR/jobs-calls.txt"
  case "$2" in
    "/api/wakes?since="*) [ -e "$GH_STUB_DIR/wakes.down" ] && return 1
                          cat "$GH_STUB_DIR/wakes.json" 2>/dev/null || printf '{"wakes":[]}'; return 0 ;;
  esac
  return 1
}
wake_cursor_get() {
  printf 'CURSOR %s\n' "$1" >> "$GH_STUB_DIR/jobs-calls.txt"
  [ -e "$GH_STUB_DIR/hub-cursor" ] || return 2
  cat "$GH_STUB_DIR/hub-cursor"
}
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
rows() { cat "$LED"/*.tsv 2>/dev/null; }
lastrow() { rows | tail -n 1; }
rcol() { lastrow | awk -F'\t' -v c="$1" '{print $c}'; }
entries() { find "$CACHE" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | grep -c . || true; }
setresp() { # setresp <status> <etag> [cache-control]
  printf '%s' "$1" > "$T/resp/status"; printf '%s' "$2" > "$T/resp/etag"; printf '%s' "${3:-}" > "$T/resp/cc"
}
reset() {
  for p in "$LED" "$CACHE"; do [ -e "$p" ] && scratch_rm "$p"; done
  rm -f "$T/real-calls.txt" "$T/jobs-calls.txt" "$T/wakes.json" "$T/wakes.down" "$T/hub-cursor" \
    "$T/resp/redirect" "$T/h/flags/gh-ledger-off" "$T/h/logs/gh-cache.log"
  setresp 200 '"fixture-etag-1"'
  printf '{"number":12,"state":"open"}' > "$T/resp/body"
  NOWV=$T0
  # A watermark and a sync long ago: the wake check is armed but not seeded.
  mkdir -p "$CACHE"; printf '100 0\n' > "$CACHE/.wakes"
  export GH_CACHE_TTL_S=60 GH_CACHE_WAKE_GRACE_S=5
}

[ -r "$LIB" ] && ok || bad "0: bin/lib/gh-cache.sh must exist and be in the shim's closure"

# ══ E. eligibility (ghc_eligible) ═══════════════════════════════════════════
elig() { ( . "$REPO/bin/lib/gh-cache.sh" 2>/dev/null && ghc_eligible "$@" ) >/dev/null 2>&1; }
e_yes() { local n="$1"; shift; elig "$@" && ok || bad "$n: must be eligible: $*"; }
e_no()  { local n="$1"; shift; elig "$@" && bad "$n: must NOT be eligible: $*" || ok; }
e_yes E1 api repos/o/r/pulls/12
e_yes E2 api -X GET repos/o/r/pulls -f state=open
e_yes E3 api --method=GET repos/o/r/issues/5 --jq .state
e_yes E4 api -i -X GET repos/o/r/pulls/1 -H 'If-None-Match: "x"'
e_yes E4b api -XGET repos/o/r/pulls/1
e_no  E5 api repos/o/r/issues/5/comments -f body=x
e_no  E5b api -X GET repos/o/r/issues -F body=@file
e_no  E6 api -X POST repos/o/r/issues
e_no  E7 api -XPATCH repos/o/r/pulls/1
e_no  E7b api --method DELETE repos/o/r/pulls/1
e_no  E8 api rate_limit
e_no  E8b api '/rate_limit?x=1'
e_no  E9 api repos/o/r/actions/artifacts/77/zip
e_no  E9b api repos/o/r/actions/jobs/9/logs
e_no  E9c api installation/token
e_no  E9d api https://api.github.com/app/installations/5/access_tokens/installation/token
e_no  E10 api --paginate repos/o/r/pulls
e_no  E10b api --slurp repos/o/r/pulls
e_no  E10c api --verbose repos/o/r/pulls
e_no  E11 api 'repos/{owner}/{repo}/pulls'
e_no  E12 api graphql -f query=x
e_no  E12b pr view 12
e_no  E12c api --input - repos/o/r
e_no  E12d api --cache 1h repos/o/r/pulls/1
e_no  E12e api --unknown-flag repos/o/r/pulls/1
e_no  E12f api
# E4: the If-None-Match pair is not part of the key.
KEYS=$( . "$REPO/bin/lib/gh-cache.sh" 2>/dev/null || exit 0
  ghc_eligible api -i -X GET repos/o/r/pulls/1 -H 'If-None-Match: "x"' && a=$(ghc_key app-1 "${GHC_ARGV[@]}")
  ghc_eligible api -i -X GET repos/o/r/pulls/1 && b=$(ghc_key app-1 "${GHC_ARGV[@]}")
  ghc_eligible api -i -X GET repos/o/r/pulls/1 && c=$(ghc_key pat-default "${GHC_ARGV[@]}")
  printf '%s %s %s' "${a:-}" "${b:-}" "${c:-}")
read -r KA KB KC <<<"$KEYS"
[ -n "${KA:-}" ] && [ "$KA" = "${KB:-}" ] && ok || bad "E4k: the If-None-Match pair must not change the key, got '$KEYS'"
[ -n "${KC:-}" ] && [ "$KA" != "$KC" ] && ok || bad "K2a: the identity is part of the key, got '$KEYS'"
# The tag that names an entry for the wake drop.
TAGS=$( . "$REPO/bin/lib/gh-cache.sh" 2>/dev/null || exit 0
  for e in repos/O/R/pulls/12 /repos/o/r/issues/5/comments 'repos/o/r/pulls?state=open' \
           repos/o/r/commits/ABCDEF0123456789abcdef0123456789abcdef01/status https://api.github.com/repos/o/r user; do
    printf '%s ' "$(ghc_tag "$e")"
  done)
[ "$TAGS" = "o__r~n-12 o__r~n-5 o__r~r o__r~s-abcdef012345 o__r~r _~r " ] && ok || bad "E13: ghc_tag, got '$TAGS'"

# ══ C. the cache cycle, through the shim ════════════════════════════════════
# C1 (the REPRO): two GETs inside the TTL make ONE request, byte-identical,
# for a body with no trailing newline, a blank-line ending and UTF-8.
reset
i=0
for body in '{"n":1}' $'{"n":2}\n\n' $'{"name":"caf\xc3\xa9 \xe2\x9c\x93 \xe6\x97\xa5\xe6\x9c\xac"}\n'; do
  i=$((i + 1))
  printf '%s' "$body" > "$T/resp/body"
  before=$(calls)
  run api "repos/o/r/pulls/2$i"; cp "$T/out" "$T/out1"; rc1=$(cat "$T/rc")
  NOWV=$((T0 + 1)) run api "repos/o/r/pulls/2$i"; rc2=$(cat "$T/rc")
  NOWV=$T0
  [ $(( $(calls) - before )) = 1 ] && ok || bad "C1.$i: two GETs inside the TTL must make 1 real call, got $(( $(calls) - before ))"
  cmp -s "$T/out1" "$T/out" && cmp -s "$T/out" "$T/resp/body" && ok || bad "C1.$i: the replay must be byte-identical: $(od -c "$T/out" | head -3)"
  [ "$rc1 $rc2" = "0 0" ] && ok || bad "C1.$i: rc must be 0 both times, got '$rc1 $rc2'"
  [ -z "$(cat "$T/err")" ] && ok || bad "C1.$i: no stderr on a hit, got: $(cat "$T/err")"
done

# C2: past the TTL, If-None-Match is sent; a 304 replays the stored body and
# resets the fetch time.
reset
run api repos/o/r/pulls/12; cp "$T/out" "$T/out1"
NOWV=$((T0 + 61)) run api repos/o/r/pulls/12
[ "$(calls)" = 2 ] && ok || bad "C2a: a GET past the TTL is a request, got $(calls)"
tail -n 1 "$T/real-calls.txt" | grep -qF 'If-None-Match: "fixture-etag-1"' && ok \
  || bad "C2b: the request past the TTL must carry If-None-Match, got: $(tail -n 1 "$T/real-calls.txt")"
cmp -s "$T/out" "$T/out1" && [ "$(cat "$T/rc")" = 0 ] && ok || bad "C2c: a 304 must replay the stored body with rc 0, got rc $(cat "$T/rc"): $(cat "$T/out")"
[ -z "$(cat "$T/err")" ] && ok || bad "C2d: gh's own 304 stderr must not reach the caller, got: $(cat "$T/err")"
NOWV=$((T0 + 61 + 30)) run api repos/o/r/pulls/12
[ "$(calls)" = 2 ] && ok || bad "C2e: a 304 resets the fetch time, so a GET 30s later is a hit, got $(calls) calls"

# C3: a POST is never cached.
reset
run api -X POST repos/o/r/issues; run api -X POST repos/o/r/issues
[ "$(calls)" = 2 ] && [ "$(entries)" = 0 ] && ok || bad "C3: 2 POSTs must make 2 calls and no entry, got $(calls) calls, $(entries) entries"

# C4: an `-i` replay keeps the header block and injects X-Gh-Cache-Served.
reset
run api -i repos/o/r/pulls/12; cp "$T/out" "$T/out1"
NOWV=$((T0 + 2)) run api -i repos/o/r/pulls/12
{ head -n 1 "$T/out1"; printf 'X-Gh-Cache-Served: cache\r\n'; tail -n +2 "$T/out1"; } > "$T/want"
[ "$(calls)" = 1 ] && cmp -s "$T/out" "$T/want" && ok || bad "C4: -i replay = the stored block plus the marker line, got $(calls) calls: $(od -c "$T/out" | head -4)"

# C5: GH_CACHE_TTL_S=0 makes every GET a request.
reset
GH_CACHE_TTL_S=0 run api repos/o/r/pulls/12; GH_CACHE_TTL_S=0 run api repos/o/r/pulls/12
[ "$(calls)" = 2 ] && [ "$(entries)" = 0 ] && ok || bad "C5: TTL 0 = off, got $(calls) calls, $(entries) entries"

# C6: a 200 with a new ETag replaces the entry.
reset
run api repos/o/r/pulls/12
setresp 200 '"fixture-etag-2"'; printf '{"number":12,"state":"closed"}' > "$T/resp/body"
NOWV=$((T0 + 61)) run api repos/o/r/pulls/12
NOWV=$((T0 + 62)) run api repos/o/r/pulls/12
[ "$(calls)" = 2 ] && [ "$(cat "$T/out")" = '{"number":12,"state":"closed"}' ] && [ "$(entries)" = 1 ] && ok \
  || bad "C6: the new 200 must replace the entry, got $(calls) calls, $(entries) entries, out $(cat "$T/out")"

# C7: the ledger rows: 200 1 200, then cache 0 cache, then 304 0 304.
reset
run api repos/o/r/pulls/12
r1="$(rcol 6) $(rcol 7) $(rcol 15) $(rcol 12)"
NOWV=$((T0 + 1)) run api repos/o/r/pulls/12
r2="$(rcol 6) $(rcol 7) $(rcol 15) $(rcol 5)"
NOWV=$((T0 + 61)) run api repos/o/r/pulls/12
r3="$(rcol 6) $(rcol 7) $(rcol 15)"
[ "$r1" = "200 1 200 gh" ] && ok || bad "C7a: the first fetch row must be '200 1 200 gh', got '$r1'"
[ "$r2" = "cache 0 cache repos/o/r/pulls/N" ] && ok || bad "C7b: a hit's row must be 'cache 0 cache <class>', got '$r2'"
[ "$r3" = "304 0 304" ] && ok || bad "C7c: the 304 row must be '304 0 304', got '$r3'"
[ "$(rows | grep -c .)" = 3 ] && ok || bad "C7d: one row per call, got $(rows | grep -c .)"

# ══ S. storage rules and retention ══════════════════════════════════════════
reset; run api repos/o/r/pulls/12
[ "$(entries)" = 1 ] && ok || bad "S1: 200 + Etag \"a\" is stored, got $(entries)"
reset; setresp 200 'W/"fixture-weak"'; run api repos/o/r/pulls/12
[ "$(entries)" = 1 ] && ok || bad "S2: 200 + a weak ETag is stored, got $(entries)"
reset; setresp 200 ''; run api repos/o/r/pulls/12; NOWV=$((T0 + 1)) run api repos/o/r/pulls/12
[ "$(entries)" = 0 ] && [ "$(calls)" = 2 ] && ok || bad "S3: a 200 with no ETag is never stored, got $(entries) entries, $(calls) calls"
reset; setresp 200 '"fixture-etag-1"' 'private, no-store'; run api repos/o/r/pulls/12
[ "$(entries)" = 0 ] && ok || bad "S4: Cache-Control no-store is never stored, got $(entries)"
for st in 404 500 000; do
  reset; run api repos/o/r/pulls/12
  setresp "$st" ''
  NOWV=$((T0 + 61)) run api repos/o/r/pulls/12
  [ "$(entries)" = 0 ] && ok || bad "S5.$st: a $st deletes the entry, got $(entries)"
  [ "$st" = 000 ] || { grep -q "fixture $st" "$T/out" && ok || bad "S5.$st: gh's own output passes through, got $(cat "$T/out")"; }
  [ "$(cat "$T/rc")" = 1 ] && ok || bad "S5.$st: gh's rc passes through, got $(cat "$T/rc")"
done
reset; : > "$T/resp/redirect"; run api repos/o/r/pulls/12
[ "$(entries)" = 0 ] && ok || bad "S6: a response after a redirect (two requests) is never stored, got $(entries)"
cmp -s "$T/out" "$T/resp/body" && ok || bad "S6b: the redirect answer still reaches the caller"
# S7: retention — an entry older than GH_ETAG_TTL_H goes on the next store.
reset
printf 'v1\t1000000000\t"x"\t0\t200\nold' > "$CACHE/o__r~n-99~0000000000000000000000000000000000000000"
touch -d '@1000000000' "$CACHE/o__r~n-99~0000000000000000000000000000000000000000"
run api repos/o/r/pulls/12
[ ! -e "$CACHE/o__r~n-99~0000000000000000000000000000000000000000" ] && [ "$(entries)" = 1 ] && ok \
  || bad "S7: the sweep must remove an entry past GH_ETAG_TTL_H after a store, got $(ls "$CACHE")"

# ══ W. wake invalidation ════════════════════════════════════════════════════
# W1: a wake row naming the PR makes the next GET a request.
reset
run api repos/o/r/pulls/12
printf '{"wakes":[{"id":101,"repo":"O/R","kind":"pr","key":"12"}]}' > "$T/wakes.json"
NOWV=$((T0 + 10)) run api repos/o/r/pulls/12
[ "$(calls)" = 2 ] && ok || bad "W1a: a pr wake for 12 must drop the pulls/12 entry, got $(calls) calls"
grep -q '^GET /api/wakes?since=100$' "$T/jobs-calls.txt" && ok || bad "W1b: the read is since the watermark, got: $(cat "$T/jobs-calls.txt" 2>/dev/null)"
[ "$(cut -d' ' -f1 "$CACHE/.wakes")" = 101 ] && ok || bad "W1c: the watermark moves to the last id, got $(cat "$CACHE/.wakes")"

# W2: a wake for PR 13 keeps pulls/12 and drops the repo's list.
reset
run api repos/o/r/pulls/12
run api -X GET repos/o/r/pulls -f state=open
printf '{"wakes":[{"id":101,"repo":"O/R","kind":"pr","key":"13"}]}' > "$T/wakes.json"
NOWV=$((T0 + 10)) run api repos/o/r/pulls/12
[ "$(calls)" = 2 ] && ok || bad "W2a: a wake for PR 13 keeps the pulls/12 entry, got $(calls) calls"
NOWV=$((T0 + 10)) run api -X GET repos/o/r/pulls -f state=open
[ "$(calls)" = 3 ] && ok || bad "W2b: a wake on the repo drops its list entries, got $(calls) calls"
[ "$(jcalls)" = 1 ] && ok || bad "W2c: one sync per GH_CACHE_WAKE_GRACE_S, got $(jcalls)"

# W3: a checks wake with a 40-hex key drops the commit's status entry.
reset
SHA=abcdef0123456789abcdef0123456789abcdef01
run api "repos/o/r/commits/$SHA/status"
printf '{"wakes":[{"id":101,"repo":"O/R","kind":"checks","key":"%s"}]}' "$SHA" > "$T/wakes.json"
NOWV=$((T0 + 10)) run api "repos/o/r/commits/$SHA/status"
[ "$(calls)" = 2 ] && ok || bad "W3: a checks wake drops the sha's entries, got $(calls) calls"

# W4: an unreachable worker serves from the TTL and logs exactly 1 line over 3 hits.
reset
run api repos/o/r/pulls/12
: > "$T/wakes.down"
for a in 10 20 30; do NOWV=$((T0 + a)) run api repos/o/r/pulls/12; done
[ "$(calls)" = 1 ] && ok || bad "W4a: unreachable = TTL only, the hits are served, got $(calls) calls"
[ "$(grep -c . "$T/h/logs/gh-cache.log" 2>/dev/null || echo 0)" = 1 ] && ok \
  || bad "W4b: exactly 1 log line over 3 hits, got: $(cat "$T/h/logs/gh-cache.log" 2>/dev/null)"
grep -q 'wakes unreachable' "$T/h/logs/gh-cache.log" 2>/dev/null && ok || bad "W4c: the line says unreachable"
[ ! -e "$T/h/logs/ALERTS.log" ] && ok || bad "W4d: no ALERTS line, got: $(cat "$T/h/logs/ALERTS.log")"
# The retry after GH_CACHE_TTL_S, with the worker still down: one more read,
# no second line. The entry is refreshed by a 304 first, so the call is a hit.
NOWV=$((T0 + 65)) run api repos/o/r/pulls/12
NOWV=$((T0 + 75)) run api repos/o/r/pulls/12
[ "$(jcalls)" = 2 ] && [ "$(grep -c . "$T/h/logs/gh-cache.log")" = 1 ] && ok \
  || bad "W4f: a retry that fails again reads once and logs nothing new, got $(jcalls) reads: $(cat "$T/h/logs/gh-cache.log")"
# The next retry finds the worker back: one more line, stamp gone.
rm -f "$T/wakes.down"
NOWV=$((T0 + 130)) run api repos/o/r/pulls/12
NOWV=$((T0 + 140)) run api repos/o/r/pulls/12
grep -q 'wakes reachable again' "$T/h/logs/gh-cache.log" && [ ! -e "$CACHE/.wake-down" ] && ok \
  || bad "W4e: a sync that works again logs once and removes the down stamp, got: $(cat "$T/h/logs/gh-cache.log")"

# W5: a hit younger than the grace makes 0 wake reads.
reset
run api repos/o/r/pulls/12
NOWV=$((T0 + 3)) run api repos/o/r/pulls/12
[ "$(jcalls)" = 0 ] && [ "$(calls)" = 1 ] && ok || bad "W5: a hit inside the grace reads no wakes, got $(jcalls) reads, $(calls) calls"

# W6: a held .wakes.lock makes the hit a conditional request.
reset
run api repos/o/r/pulls/12
exec 9>>"$CACHE/.wakes.lock"; flock -n 9
NOWV=$((T0 + 10)) run api repos/o/r/pulls/12
exec 9>&-
[ "$(calls)" = 2 ] && tail -n 1 "$T/real-calls.txt" | grep -qF 'If-None-Match: "fixture-etag-1"' && ok \
  || bad "W6: a busy lock makes the hit conditional, got $(calls) calls: $(tail -n 1 "$T/real-calls.txt")"
cmp -s "$T/out" "$T/resp/body" && ok || bad "W6b: and the 304 replays the body"

# W7: a wake on O/R2 leaves the o__r entries; key 12 leaves n-120.
reset
run api repos/o/r/pulls/120
run api repos/o/r/pulls/1
printf '{"wakes":[{"id":101,"repo":"O/R2","kind":"issue","key":"5"},{"id":102,"repo":"O/R","kind":"pr","key":"12"}]}' > "$T/wakes.json"
NOWV=$((T0 + 10)) run api repos/o/r/pulls/120
NOWV=$((T0 + 10)) run api repos/o/r/pulls/1
[ "$(calls)" = 2 ] && ok || bad "W7: wakes for O/R2 and PR 12 must keep n-120 and n-1, got $(calls) calls"

# W8: no watermark: seed from the hub's wake cursor and drop every entry once.
reset
rm -f "$CACHE/.wakes"
run api repos/o/r/pulls/12
printf '500\n' > "$T/hub-cursor"
NOWV=$((T0 + 10)) run api repos/o/r/pulls/12
[ "$(calls)" = 2 ] && ok || bad "W8a: the first sync drops every entry, got $(calls) calls"
grep -q '^CURSOR fixture-hub$' "$T/jobs-calls.txt" && grep -q '^GET /api/wakes?since=500$' "$T/jobs-calls.txt" && ok \
  || bad "W8b: the seed reads the hub cursor, then wakes since it, got: $(cat "$T/jobs-calls.txt")"
[ "$(cut -d' ' -f1 "$CACHE/.wakes")" = 500 ] && ok || bad "W8c: the watermark is the hub cursor, got $(cat "$CACHE/.wakes" 2>/dev/null)"
# No hub cursor: a seed failure is unreachable (TTL only), never a read since 0.
reset
rm -f "$CACHE/.wakes"
run api repos/o/r/pulls/12
NOWV=$((T0 + 10)) run api repos/o/r/pulls/12
[ "$(calls)" = 1 ] && [ "$(jcalls)" = 0 ] && grep -q 'wakes unreachable' "$T/h/logs/gh-cache.log" && ok \
  || bad "W8d: no hub cursor = TTL only, got $(calls) calls, $(jcalls) reads"

# W9: a write on this box drops what it changes, before the webhook arrives.
reset
run api repos/o/r/pulls/12
run api repos/o/r/pulls/13
run api -X GET repos/o/r/pulls -f state=open
run api -X PATCH repos/o/r/pulls/12 -f state=closed
NOWV=$((T0 + 1)) run api repos/o/r/pulls/12
[ "$(calls)" = 5 ] && ok || bad "W9a: a PATCH of pulls/12 drops its entry, got $(calls) calls"
NOWV=$((T0 + 1)) run api repos/o/r/pulls/13
[ "$(calls)" = 5 ] && ok || bad "W9b: and keeps pulls/13, got $(calls) calls"
NOWV=$((T0 + 1)) run api -X GET repos/o/r/pulls -f state=open
[ "$(calls)" = 6 ] && ok || bad "W9c: and drops the repo's lists, got $(calls) calls"
run api repos/o/r/issues/13/comments -f body=x          # a body with no method is a POST
NOWV=$((T0 + 1)) run api repos/o/r/pulls/13
[ "$(calls)" = 8 ] && ok || bad "W9d: a POST to issues/13/comments drops the n-13 entries, got $(calls) calls"
# gh_rest's own write (`api -i -X PUT`) goes through the same check.
run api repos/o/r/pulls/12
GH_LEDGER_BY_CALLER=1 run api -i -X PUT repos/o/r/pulls/12/merge
NOWV=$((T0 + 1)) run api repos/o/r/pulls/12
[ "$(calls)" = 11 ] && ok || bad "W9e: gh_rest's PUT …/pulls/12/merge drops the pulls/12 entry, got $(calls) calls"
[ "$(jcalls)" = 0 ] && ok || bad "W9f: none of this read the wakes, got $(jcalls)"

# ══ R. gh_rest through the cache ════════════════════════════════════════════
grest() { # grest <out> — one gh_rest GET repos/o/r/pulls/1 at NOWV, shim first on PATH
  ( export PATH="$P0" GH_CACHE_NOW="$NOWV"
    # shellcheck source=bin/lib/gh-rest.sh
    . "$T/inst/bin/lib/gh-rest.sh"
    gh_rest GET repos/o/r/pulls/1 > "$1"; echo "$? $GH_REST_STATUS" > "$1.rc" )
}
reset
grest "$T/r1"
QF=$(ls "$LED"/.quota-* 2>/dev/null | head -n 1)
[ -n "$QF" ] && printf '1 6600 1792702800 1\n' > "$QF"   # a sentinel only a persist would overwrite
NOWV=$((T0 + 1)) grest "$T/r2"
[ "$(calls)" = 1 ] && ok || bad "R1a: two gh_rest reads make 1 real call, got $(calls)"
cmp -s "$T/r1" "$T/r2" && [ "$(cat "$T/r1")" = '{"number":12,"state":"open"}' ] && ok || bad "R1b: both print the same body, got '$(cat "$T/r1")' vs '$(cat "$T/r2")'"
[ "$(cat "$T/r2.rc")" = "0 200" ] && ok || bad "R1c: the replay is a 200 to gh_rest, got $(cat "$T/r2.rc")"
[ "$(rcol 6) $(rcol 7) $(rcol 12) $(rcol 15)" = "cache 0 rest cache" ] && ok || bad "R1d: gh_rest's row for the hit is 'cache 0 rest cache', got '$(lastrow)'"
[ "$(rows | grep -c .)" = 2 ] && ok || bad "R1e: one row per gh_rest call (the shim writes none), got $(rows | grep -c .)"
[ -n "$QF" ] && [ "$(cat "$QF")" = "1 6600 1792702800 1" ] && ok || bad "R2: a replay must not persist its stale quota headers, got '$(cat "$QF" 2>/dev/null)'"
# R3: gh_rest's own If-None-Match is not sent when the shim has no entry.
reset
GH_CACHE_TTL_S=0 grest "$T/r1"                    # seeds gh_rest's own ETag store only
[ "$(entries)" = 0 ] && ok || bad "R3a: TTL 0 stores nothing"
grest "$T/r2"
[ "$(calls)" = 2 ] && ! grep -q 'If-None-Match' <<<"$(tail -n 1 "$T/real-calls.txt")" && ok \
  || bad "R3b: with no shim entry, gh_rest's If-None-Match is removed, got: $(tail -n 1 "$T/real-calls.txt")"
[ "$(entries)" = 1 ] && cmp -s "$T/r2" "$T/r1" && ok || bad "R3c: that 200 seeds the shim's entry, got $(entries)"
NOWV=$((T0 + 61)) grest "$T/r3"
[ "$(rcol 6) $(rcol 7) $(rcol 15)" = "304 0 304" ] && cmp -s "$T/r3" "$T/r1" && ok \
  || bad "R3d: past the TTL gh_rest's row says 304 and the body is replayed, got '$(lastrow)'"

# ══ K. knobs ════════════════════════════════════════════════════════════════
reset
unset GH_CACHE_TTL_S GH_CACHE_WAKE_GRACE_S
printf '0 5 %s\n' "$T0" > "$CACHE/.knobs"
run api repos/o/r/pulls/12; run api repos/o/r/pulls/12
[ "$(calls)" = 2 ] && ok || bad "K1a: a .knobs file that says ttl 0 turns the cache off, got $(calls)"
GH_CACHE_TTL_S=60 run api repos/o/r/pulls/12; GH_CACHE_TTL_S=60 run api repos/o/r/pulls/12
[ "$(calls)" = 3 ] && ok || bad "K1b: an env value wins over the file, got $(calls)"
# A stale .knobs with no lane-gate on the box: the code fallbacks (60 / 5).
printf '0 5 1\n' > "$CACHE/.knobs"
NOWV=$((T0 + 1)) run api repos/o/r/pulls/12
[ "$(calls)" = 3 ] && ok || bad "K1c: a stale .knobs file is not trusted; the fallback TTL is 60, got $(calls)"
# K2: one argv, two identities, two entries.
reset
run api repos/o/r/pulls/12
GH_TOKEN=ghp_fixture_bh8066 run api repos/o/r/pulls/12
[ "$(calls)" = 2 ] && [ "$(entries)" = 2 ] && ok || bad "K2b: pat-default and pat-<sha> never share an entry, got $(calls) calls, $(entries) entries"

# ══ L. ledger column 15 ═════════════════════════════════════════════════════
reset
L1=$( . "$T/inst/bin/lib/gh-rest-ledger.sh"
  for st in 000 200 304 cache 404; do gh_ledger_append gh GET repos/o/r "$st" 0; done
  cat "$LED"/*.tsv | awk -F'\t' '{printf "%s ", $15}')
[ "$L1" = "- 200 304 cache 200 " ] && ok || bad "L1: column 15 is derived from the status, got '$L1'"

# ══ N. the calls the cache never sees ═══════════════════════════════════════
reset
run api repos/o/r/pulls/12
GH_LEDGER_DEPTH=1 run api repos/o/r/pulls/12
GH_DEBUG=1 run api repos/o/r/pulls/12
touch "$T/h/flags/gh-ledger-off"; run api repos/o/r/pulls/12; rm -f "$T/h/flags/gh-ledger-off"
run pr view 12; run pr view 12
[ "$(calls)" = 6 ] && ok || bad "N1: a nested call, a caller's GH_DEBUG, the kill switch and gh pr view are never served from the cache, got $(calls)"

# ══ F. a missing lib ════════════════════════════════════════════════════════
reset
scratch_install_closure bin/gh-ledger/gh "$T/inst2" >/dev/null
rm -f "$T/inst2/bin/lib/gh-cache.sh"
env PATH="$T/inst2/bin/gh-ledger:$T/real:/usr/bin:/bin" GH_CACHE_NOW="$T0" "$T/lane/my-lane.sh" api repos/o/r/pulls/12 > "$T/out1" 2>/dev/null
env PATH="$T/inst2/bin/gh-ledger:$T/real:/usr/bin:/bin" GH_CACHE_NOW="$T0" "$T/lane/my-lane.sh" api repos/o/r/pulls/12 > "$T/out2" 2>/dev/null
[ "$(calls)" = 2 ] && cmp -s "$T/out1" "$T/out2" && cmp -s "$T/out1" "$T/resp/body" && ok \
  || bad "F1: no lib = no cache, unchanged output, got $(calls) calls"

echo "gh-shim-cache.bh-8066: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
