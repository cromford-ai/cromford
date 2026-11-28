#!/bin/bash
# tests/gh-cache-sweep.bh-9417-test.sh — BH-9453 (BH-9417.3): the missed-webhook
# sweep of the gh shim cache. bin/gh-cache-sweep.sh reads each registry repo's
# open PRs and updated issues, drops the cache entries of what changed, and
# writes a per-repo stamp; ghc_sweep_covers (bin/lib/gh-cache-sweep.sh) reads
# the stamp, and ghc_main (bin/lib/gh-cache.sh) serves an n-<N> entry past
# GH_CACHE_EVENT_MAX_S, and a repo list or search entry past GH_CACHE_TTL_S,
# only while a fresh sweep vouches for it.
#
# Sections: S1 a change with no wake, S2 a PR entry 2 hours old, S3 a failed
# read, S4 nothing changed, S6 a fetch during a sweep, S7 all repos unreadable, S11 the first sweep, S12 inside the period, S13 the
# knob is off, K the change rule, KR an issues window too big, KN the knob
# fallbacks, C the coverage rule, R1-R6 lists and search through the shim.
#
# Nothing touches the network. The real `gh` is a counting stub that serves
# repos/o/<r>/… and search/issues from fixture files; any other endpoint logs
# UNSTUBBED and exits 99. The jobs worker is a fixture jobs-client.sh that
# answers GET /api/wakes from wakes.json. The clock is GH_CACHE_NOW.
#
# Run from anywhere: bash tests/gh-cache-sweep.bh-9417-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

scratch_install_closure bin/gh-cache-sweep.sh "$T/inst" >/dev/null || { echo "FAIL: closure install (sweep)"; exit 1; }
scratch_install_closure bin/gh-ledger/gh "$T/inst" >/dev/null || { echo "FAIL: closure install (shim)"; exit 1; }
SWEEP="$T/inst/bin/gh-cache-sweep.sh"
SHIMDIR="$T/inst/bin/gh-ledger"
LIB="$T/inst/bin/lib/gh-cache.sh"
[ -x "$SWEEP" ] && [ -r "$T/inst/bin/lib/gh-cache-sweep.sh" ] && ok || bad "0: bin/gh-cache-sweep.sh and bin/lib/gh-cache-sweep.sh must install"

T0=1792699200   # determinism: ok pinned cache clock (2026-10-22T20:00:00Z), a whole minute
export HARNESS="$T/h"
export HARNESS_ENV_DIR="$T/h/env"
mkdir -p "$T/h/logs" "$T/h/state" "$T/h/env" "$T/h/bin/lib/jobs" "$T/tmp" "$T/real" "$T/lane" "$T/resp" "$T/fx" "$T/st"
export TMPDIR="$T/tmp"
export GH_STUB_DIR="$T"
export HARNESS_SECRET=fixture-secret-bh9453
unset GH_TOKEN GITHUB_TOKEN GH_DEBUG HARNESS_LANE HARNESS_LANE_PROJECT PROJECT GH_LEDGER_OFF \
  GH_LEDGER_DEPTH GH_LEDGER_BY_CALLER GH_CACHE_TTL_S GH_CACHE_WAKE_GRACE_S GH_CACHE_EVENT_MAX_S \
  GH_CACHE_NOW GH_ETAG GH_CACHE_SWEEP GH_CACHE_SWEEP_PERIOD_S GH_CACHE_SWEEP_OVERLAP_S GH_CACHE_SWEEP_MAX_PAGES GH_CACHE_SWEEP_TRUST_PERIODS
LED="$T/h/state/gh-rest-ledger"
CACHE="$T/h/state/gh-cache"
SD="$T/h/state/gh-cache-sweep"
SLOG="$T/h/logs/gh-cache-sweep.log"

# ── the registry: p1 = o/r, p2 = o/r2, p3 = O/R (the same repo) ─────────────
cat > "$T/h/bin/fleet-conf.sh" <<'FC'
#!/bin/bash
case "$1" in
  --projects) printf 'p1\np2\np3\n' ;;
  p1) echo o/r ;;
  p2) echo o/r2 ;;
  p3) echo O/R ;;
  *) exit 1 ;;
esac
FC
chmod +x "$T/h/bin/fleet-conf.sh"

# ── the real `gh`: a counting stub ─────────────────────────────────────────
# repos/o/<n>/pulls?… and issues?… (a list) answer fx/o_<n>.<pulls|issues>.<page>.json
# (page 1 when the query has no page=); a missing page file is UNSTUBBED. Any
# other repos/o/… or search/issues… endpoint answers {"ep":"<ep>","v":<ver>}.
# The ETag is the file's sha1 (or e-<ver>-<ep>); a matching If-None-Match is a
# 304. resp/fail holds `<rc75|403> <substring>`: an endpoint holding the
# substring fails that way.
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
file=""
case "$ep" in
  rate_limit|search/issues*) ;;
  repos/o/*/pulls\?*|repos/o/*/issues\?*)
    r="${ep#repos/o/}"; r="${r%%/*}"; kind="${ep#repos/o/"$r"/}"; kind="${kind%%\?*}"
    pg=1; case "$ep" in *[?\&]page=*) pg="${ep##*page=}"; pg="${pg%%&*}" ;; esac
    file="$S/fx/o_$r.$kind.$pg.json"
    [ -r "$file" ] || { printf 'UNSTUBBED %s\n' "$*" >> "$S/unstubbed.txt"; exit 99; } ;;
  repos/o/*) ;;
  *) printf 'UNSTUBBED %s\n' "$*" >> "$S/unstubbed.txt"; exit 99 ;;
esac
st=200
if [ -r "$S/resp/fail" ] && [ "$ep" != rate_limit ]; then
  read -r fm fs < "$S/resp/fail"
  case "$ep" in *"$fs"*)
    [ "$fm" = rc75 ] && { printf 'gh: rate limited\n' >&2; exit 75; }
    st="$fm" ;;
  esac
fi
ver=$(cat "$S/resp/ver" 2>/dev/null); ver="${ver:-1}"
if [ -n "$file" ]; then etag="\"f-$(sha1sum "$file" | cut -c1-16)\""
else etag="\"e-$ver-$(printf '%s' "$ep" | tr '/?=&:+' '______')\""
fi
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
  200) if [ -n "$file" ]; then cat "$file"; else printf '{"ep":"%s","v":%s}' "$ep" "$ver"; fi; exit 0 ;;
  304) printf 'gh: HTTP 304\n' >&2; exit 1 ;;
  *) printf '{"message":"fixture %s"}' "$st"; printf 'gh: fixture %s (HTTP %s)\n' "$st" "$st" >&2; exit 1 ;;
esac
STUB
chmod +x "$T/real/gh"
printf '#!/bin/bash\ngh "$@"\nexit $?\n' > "$T/lane/my-lane.sh"; chmod +x "$T/lane/my-lane.sh"

# The jobs worker, as a fixture client: GET /api/wakes?since=<n> answers the
# rows of wakes.json with id > n.
cat > "$T/h/bin/jobs-client.sh" <<'JC'
#!/bin/bash
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$GH_STUB_DIR/jobs-calls.txt"
  case "$2" in
    "/api/wakes?since="*)   # determinism: ok clock-rolling-window since= is a wake id watermark, not a time window
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

# ── fixture state: st/o_<n>.prs (`N updated head`), st/o_<n>.iss (`N updated`)
head_of() { printf '%04x%04xbeef%028x' "$1" "${2:-1}" "$1"; }   # head_of <N> [version] — 40 hex, unique in its first 12
upd() { printf '2026-10-%02dT00:00:00Z' "$1"; }
prs() { # prs <repo> <from> <to> — open PRs from..to, updated day 1, head version 1
  local n; : > "$T/st/o_$1.prs"
  for n in $(seq "$2" "$3"); do printf '%s %s %s\n' "$n" "$(upd 1)" "$(head_of "$n")" >> "$T/st/o_$1.prs"; done
}
setpr() { # setpr <repo> <N> <updated> <head> — change or add one open PR
  awk -v n="$2" '$1 != n' "$T/st/o_$1.prs" > "$T/st/x"; printf '%s %s %s\n' "$2" "$3" "$4" >> "$T/st/x"; sort -n "$T/st/x" > "$T/st/o_$1.prs"
}
delpr() { awk -v n="$2" '$1 != n' "$T/st/o_$1.prs" > "$T/st/x"; mv "$T/st/x" "$T/st/o_$1.prs"; }
iss() { printf '%s %s\n' "$2" "$3" >> "$T/st/o_$1.iss"; }   # iss <repo> <N> <updated> — one issues row
publish() { # writes every fixture page from st/: 100 rows a page, an empty page after a full one
  local f r
  rm -f "$T/fx"/*.json
  for f in "$T"/st/o_*.prs; do
    r=$(basename "$f" .prs); r="${r#o_}"
    awk -v d="$T/fx" -v r="$r" -v kind=pulls '{ printf "{\"number\":%s,\"updated_at\":\"%s\",\"head\":{\"sha\":\"%s\"}}\n", $1, $2, $3 }' "$f" | pages "$r" pulls
    if [ -r "$T/st/o_$r.iss" ]; then
      awk '{ printf "{\"number\":%s,\"updated_at\":\"%s\"}\n", $1, $2 }' "$T/st/o_$r.iss" | pages "$r" issues
    else printf '[]' > "$T/fx/o_$r.issues.1.json"
    fi
  done
}
pages() { # pages <repo> <kind> — JSON objects on stdin, one a line, into page files
  local n=0 p=1 out
  out="$T/fx/o_$1.$2.1.json"; printf '[' > "$out"
  while IFS= read -r l; do
    if [ "$n" = 100 ]; then printf ']' >> "$out"; p=$((p + 1)); n=0; out="$T/fx/o_$1.$2.$p.json"; printf '[' > "$out"; fi
    [ "$n" = 0 ] || printf ',' >> "$out"
    printf '%s' "$l" >> "$out"; n=$((n + 1))
  done
  printf ']' >> "$out"
  [ "$n" = 100 ] && printf '[]' > "$T/fx/o_$1.$2.$((p + 1)).json"
  return 0
}

P0="$SHIMDIR:$T/real:/usr/bin:/bin"
NOWV=$T0
sweep() { # sweep [project…] — one run of the lane at clock NOWV, shim first on PATH
  env PATH="$P0" GH_CACHE_NOW="$NOWV" "$SWEEP" "$@" > /dev/null 2> "$T/sweep.err"
  echo $? > "$T/src"
}
run() { # run <args…> — one gh call through a lane script at NOWV
  env PATH="$P0" GH_CACHE_NOW="$NOWV" "$T/lane/my-lane.sh" "$@" > "$T/out" 2> "$T/err"
  echo $? > "$T/rc"
}
calls() { local n; n=$(grep -c . "$T/real-calls.txt" 2>/dev/null); echo "${n:-0}"; }
newcalls() { tail -n +"$(( $1 + 1 ))" "$T/real-calls.txt" 2>/dev/null; }
jcalls() { local n; n=$(grep -c "api/wakes?since" "$T/jobs-calls.txt" 2>/dev/null); echo "${n:-0}"; }
lastserved() { cat "$LED"/*.tsv 2>/dev/null | tail -n 1 | awk -F'\t' '{print $15}'; }
lastlog() { tail -n 1 "$SLOG" 2>/dev/null | cut -d' ' -f3-; }
seed() { local e; mkdir -p "$CACHE"; for e in "$@"; do printf 'fixture\n' > "$CACHE/$e"; done; }   # seed <entry name…>
have() { [ -f "$CACHE/$1" ]; }
gone() { [ ! -e "$CACHE/$1" ]; }
reset() { # reset [event max] — no state, no fixtures, clock T0
  local p
  for p in "$T/h/state" "$T/h/logs" "$T/fx" "$T/st"; do [ -e "$p" ] && scratch_rm "$p"; done
  mkdir -p "$T/h/state" "$T/h/logs" "$T/fx" "$T/st"
  rm -f "$T/real-calls.txt" "$T/jobs-calls.txt" "$T/wakes.json" "$T/unstubbed.txt" "$T/resp/fail" "$T/resp/ver"
  NOWV=$T0
  unset GH_CACHE_SWEEP GH_CACHE_SWEEP_PERIOD_S GH_CACHE_SWEEP_OVERLAP_S GH_CACHE_SWEEP_MAX_PAGES GH_CACHE_SWEEP_TRUST_PERIODS
  export GH_CACHE_SWEEP=1   # the lane ships off (default 0); the sections that exercise it switch it on
  mkdir -p "$CACHE"; printf '100 0\n' > "$CACHE/.wakes"
  export GH_CACHE_TTL_S=60 GH_CACHE_WAKE_GRACE_S=5 GH_CACHE_EVENT_MAX_S="${1:-300}"
}
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }

# ══ S1: a PR changes with no wake; one sweep drops that PR's entries only ═══
reset
prs r 10 20; prs r2 1 3; publish
sweep
H12=$(head_of 12); H13=$(head_of 13); N12=$(head_of 12 2)
seed "o__r~n-12~a" "o__r~n-12~b" "o__r~s-${H12:0:12}~a" "o__r~s-${N12:0:12}~a" "o__r~r~a" \
     "o__r~n-13~a" "o__r~s-${H13:0:12}~a" "o__r2~n-12~a" "o__r2~r~a" "o__r~n-120~a"
setpr r 12 "$(upd 2)" "$N12"; publish
NOWV=$((T0 + 900)); sweep
gone "o__r~n-12~a" && gone "o__r~n-12~b" && gone "o__r~s-${H12:0:12}~a" && gone "o__r~s-${N12:0:12}~a" && gone "o__r~r~a" \
  && ok || bad "S1a: PR 12's n-12, old and new head s- entries and the o/r lists are dropped: $(ls "$CACHE" | tr '\n' ' ')"
have "o__r~n-13~a" && have "o__r~s-${H13:0:12}~a" && have "o__r2~n-12~a" && have "o__r2~r~a" && have "o__r~n-120~a" \
  && ok || bad "S1b: PR 13, PR 120 and every o/r2 entry stay: $(ls "$CACHE" | tr '\n' ' ')"
[[ "$(lastlog)" =~ ^repos=2\ rows=[0-9]+\ changed=1\ unreadable=0\ requests=4\  ]] && ok || bad "S1c: the log line, got '$(lastlog)'"
[ "$(cat "$CACHE/.rdrop.o__r" 2>/dev/null)" = "$((T0 + 900))" ] && [ ! -e "$CACHE/.rdrop.o__r2" ] && ok \
  || bad "S1d: the list drop writes .rdrop.o__r only, got '$(cat "$CACHE/.rdrop.o__r" 2>/dev/null)' / $(ls -a "$CACHE" | grep rdrop | tr '\n' ' ')"
[ "$(cat "$SD/o__r.stamp")" = "v3 $((T0 + 900)) $T0 900 $T0 $((T0 + 900)) 2" ] && ok || bad "S1e: the stamp keeps the chain start, base = the previous end, got '$(cat "$SD/o__r.stamp" 2>/dev/null)'"
grep -q "^p	12	$(upd 2)	$N12\$" "$SD/o__r.tsv" && ok || bad "S1f: the record holds PR 12's new row"

# ══ S2: a PR entry 2 hours old ═══════════════════════════════════════════════
reset 300
prs r 10 20; prs r2 1 3; publish
sweep
NOWV=$((T0 + 100)); run api repos/o/r/pulls/12/files
NOWV=$((T0 + 7200)); sweep
B=$(calls); NOWV=$((T0 + 7300)); run api repos/o/r/pulls/12/files
[ "$(calls)" = "$B" ] && [ "$(lastserved)" = cache ] && [ "$(cat "$T/out")" = '{"ep":"repos/o/r/pulls/12/files","v":1}' ] && ok \
  || bad "S2a: fresh stamp: a 7200 s old PR entry is served cache with 0 requests, got $(( $(calls) - B )) requests, served $(lastserved)"
B=$(calls); NOWV=$((T0 + 7200 + 1800)); run api repos/o/r/pulls/12/files
[ "$(calls)" = $((B + 1)) ] && newcalls "$B" | grep -qF 'If-None-Match: "e-1-repos_o_r_pulls_12_files"' && [ "$(lastserved)" = 304 ] && ok \
  || bad "S2b: a stamp 2 periods old: a conditional request, got $(( $(calls) - B )) requests, served $(lastserved)"
# S2c (lead review BLOCK 1): the bare PR read repos/<slug>/pulls/<N> carries
# mergeable_state, which GitHub changes with no updated_at or head change (a
# merge to main). A sweep never vouches for it: past GH_CACHE_EVENT_MAX_S it
# is a conditional request even with a fresh stamp; inside it, cache.
reset 300
prs r 10 20; prs r2 1 3; publish
sweep
NOWV=$((T0 + 100)); run api repos/o/r/pulls/12; run api 'repos/o/r/pulls/12?x=1'
NOWV=$((T0 + 7200)); sweep
B=$(calls); NOWV=$((T0 + 7300)); run api repos/o/r/pulls/12
[ "$(calls)" = $((B + 1)) ] && newcalls "$B" | grep -qF 'If-None-Match: "e-1-repos_o_r_pulls_12"' && [ "$(lastserved)" = 304 ] && ok \
  || bad "S2c: fresh stamp: a bare pulls/12 entry past the event max is a conditional request, got $(( $(calls) - B )) requests, served $(lastserved)"
B=$(calls); NOWV=$((T0 + 7300 + 200)); run api repos/o/r/pulls/12
[ "$(calls)" = "$B" ] && [ "$(lastserved)" = cache ] && ok \
  || bad "S2d: a bare pulls/12 entry inside the event max is served cache, got $(( $(calls) - B )) requests, served $(lastserved)"
B=$(calls); NOWV=$((T0 + 7300)); run api 'repos/o/r/pulls/12?x=1'
[ "$(calls)" = $((B + 1)) ] && [ "$(lastserved)" = 304 ] && ok \
  || bad "S2e: a bare pulls/12 read with a query string is not vouched for either, served $(lastserved)"

# ══ S3: a failed read writes nothing and drops nothing ═══════════════════════
for mode in rc75 403; do
  reset
  prs r 1 150; prs r2 1 3; publish
  sweep
  cp "$SD/o__r.tsv" "$T/rec.before"; cp "$SD/o__r.stamp" "$T/stamp.before"
  seed "o__r~n-12~a" "o__r~r~a" "o__r~s-$(head_of 12 | cut -c1-12)~a"
  setpr r 12 "$(upd 3)" "$(head_of 12 2)"; publish
  printf '%s %s\n' "$mode" "repos/o/r/pulls?state=open&per_page=100&page=2" > "$T/resp/fail"
  NOWV=$((T0 + 900)); sweep
  cmp -s "$SD/o__r.tsv" "$T/rec.before" && cmp -s "$SD/o__r.stamp" "$T/stamp.before" && ok \
    || bad "S3a.$mode: the record and stamp bytes are unchanged"
  have "o__r~n-12~a" && have "o__r~r~a" && have "o__r~s-$(head_of 12 | cut -c1-12)~a" && [ ! -e "$CACHE/.rdrop.o__r" ] && ok \
    || bad "S3b.$mode: every entry stays: $(ls -a "$CACHE" | tr '\n' ' ')"
  [[ "$(lastlog)" =~ ^repos=2\ .*\ changed=0\ unreadable=1\  ]] && ok || bad "S3c.$mode: the log line, got '$(lastlog)'"
  grep -q "repo=o/r unreadable .*page=2" "$SLOG" && ok || bad "S3d.$mode: the unreadable line names the page, got: $(cat "$SLOG")"
  [ "$(cut -d' ' -f2 "$SD/o__r2.stamp")" = $((T0 + 900)) ] && ok || bad "S3e.$mode: o/r2 is still swept, got '$(cat "$SD/o__r2.stamp")'"
  rm -f "$T/resp/fail"
  NOWV=$((T0 + 1800)); sweep
  gone "o__r~n-12~a" && gone "o__r~r~a" && ok || bad "S3f.$mode: the next run finds the change and drops"
done

# ══ S4: two sweeps, nothing changed ═════════════════════════════════════════
reset
prs r 1 150; prs r2 1 3
for n in 1 2 3 4 5; do iss r "$n" "$(upd 1)"; done
publish
sweep
seed "o__r~n-1~a" "o__r~n-77~a" "o__r~r~a" "o__r2~n-2~a" "o__r2~r~a"
B=$(calls); NOWV=$((T0 + 900)); sweep
have "o__r~n-1~a" && have "o__r~n-77~a" && have "o__r~r~a" && have "o__r2~n-2~a" && have "o__r2~r~a" \
  && [ -z "$(ls -A "$CACHE" | grep rdrop)" ] && ok || bad "S4a: 0 drops, got: $(ls -A "$CACHE" | tr '\n' ' ')"
SINCE=$(iso $((T0 - 120)))
EXP="api -i -X GET repos/o/r/pulls?state=open&per_page=100&page=1|api -i -X GET repos/o/r/pulls?state=open&per_page=100&page=2|api -i -X GET repos/o/r/issues?state=all&sort=updated&direction=desc&since=$SINCE&per_page=100&page=1|api -i -X GET repos/o/r2/pulls?state=open&per_page=100&page=1|api -i -X GET repos/o/r2/issues?state=all&sort=updated&direction=desc&since=$SINCE&per_page=100&page=1|"
GOT=$(newcalls "$B" | sed 's/ -H If-None-Match: .*//' | tr '\n' '|')
[ "$GOT" = "$EXP" ] && ok || bad "S4b: the second sweep's requests, got '$GOT'"
[[ "$(lastlog)" =~ changed=0\ unreadable=0\ requests=5\  ]] && ok || bad "S4c: the log line, got '$(lastlog)'"
[ "$(calls)" = $((B + 5)) ] && ok || bad "S4d: 5 requests, got $(( $(calls) - B ))"

# ══ S5: the shim cache never answers the sweep's own reads ═══════════════════
# A lane stored the same pulls page 10 s before the sweep; the page then changed.
reset
prs r 10 20; prs r2 1 3; publish
sweep
seed "o__r~n-12~a"
NOWV=$((T0 + 890)); run api -i -X GET 'repos/o/r/pulls?state=open&per_page=100&page=1'
ls "$CACHE" | grep -q '^o__r~r~' && ok || bad "S5a: the lane's page is in the shim cache"
setpr r 12 "$(upd 2)" "$(head_of 12 2)"; publish
NOWV=$((T0 + 900)); sweep
gone "o__r~n-12~a" && [[ "$(lastlog)" =~ changed=1\  ]] && ok || bad "S5b: the sweep reads GitHub, not the shim cache, and sees PR 12 change, got '$(lastlog)'"

# ══ S6: a fetch made while a sweep was still reading (no wake) ═══════════════
# Sweep A2 starts at T0+900 and reads PR 12's change. A lane fetch at T0+900
# is stored after A2's drop. The next clean sweep B must not vouch for it: B
# compared with A2's record, which already held the change.
reset 300
prs r 10 20; prs r2 1 3; publish
sweep
setpr r 12 "$(upd 2)" "$(head_of 12 2)"; publish
NOWV=$((T0 + 900)); sweep
[[ "$(lastlog)" =~ changed=1\  ]] && ok || bad "S6a: sweep A2 sees PR 12 change, got '$(lastlog)'"
NOWV=$((T0 + 900)); run api repos/o/r/pulls/12/files
NOWV=$((T0 + 1800)); sweep
[[ "$(lastlog)" =~ changed=0\  ]] && [ "$(cut -d' ' -f5 "$SD/o__r.stamp")" = $((T0 + 900)) ] && ok \
  || bad "S6b: sweep B sees no change, base = A2's end, got '$(lastlog)' / '$(cat "$SD/o__r.stamp")'"
B=$(calls); NOWV=$((T0 + 1850)); run api repos/o/r/pulls/12/files
[ "$(calls)" = $((B + 1)) ] && [ "$(lastserved)" = 304 ] && ok \
  || bad "S6c: an entry fetched during sweep A2 is not vouched for by B: a conditional request, got $(( $(calls) - B )) requests, served $(lastserved)"
# A fetch after A2 finished is vouched for by B.
NOWV=$((T0 + 901)); run api repos/o/r/pulls/13/files
B=$(calls); NOWV=$((T0 + 1850)); run api repos/o/r/pulls/13/files
[ "$(calls)" = "$B" ] && [ "$(lastserved)" = cache ] && ok \
  || bad "S6d: an entry fetched after sweep A2 is served cache, got $(( $(calls) - B )) requests, served $(lastserved)"

# ══ S7: every repo unreadable: no .last-run, the next run tries again ════════
reset
prs r 10 20; prs r2 1 3; publish
printf 'rc75 pulls?state=open\n' > "$T/resp/fail"
sweep
[ ! -e "$SD/.last-run" ] && [[ "$(lastlog)" =~ unreadable=2\  ]] && ok || bad "S7a: all unreadable writes no .last-run, got '$(lastlog)'"
rm -f "$T/resp/fail"
NOWV=$((T0 + 300)); sweep
[ -e "$SD/o__r.stamp" ] && [ -e "$SD/.last-run" ] && ok || bad "S7b: the next run 5 minutes later sweeps"

# ══ S11: the first sweep ═════════════════════════════════════════════════════
reset
prs r 10 20; prs r2 1 3; publish
seed "o__r~n-12~a" "o__r~r~a"
sweep
have "o__r~n-12~a" && have "o__r~r~a" && ok || bad "S11a: the first sweep drops nothing"
[ "$(grep -c 'issues' "$T/real-calls.txt")" = 0 ] && ok || bad "S11b: the first sweep reads no issues window"
[ "$(cat "$SD/o__r.stamp")" = "v3 $T0 $T0 900 $T0 $T0 2" ] && ok || bad "S11c: stamp v3 <start> <chain=end> <period> <base=end> <end> <trust_periods>, got '$(cat "$SD/o__r.stamp" 2>/dev/null)'"
NOWV=$((T0 + 900)); sweep
S11=$( . "$LIB" >/dev/null 2>&1 || exit 1; export GH_CACHE_NOW=$((T0 + 950))
  ghc_sweep_covers "$CACHE" o__r~n-12 $((T0 - 10)) && printf y || printf n
  ghc_sweep_covers "$CACHE" o__r~n-12 $((T0 + 10)) && printf y || printf n)
[ "$S11" = ny ] && ok || bad "S11d: an entry fetched before the first sweep is never covered, one after is, got '$S11'"

# ══ S12: inside the period; S13: the knob is off ═════════════════════════════
reset
prs r 10 20; prs r2 1 3; publish
sweep
cp "$SD/o__r.stamp" "$T/stamp.before"; cp "$SD/.last-run" "$T/last.before"
B=$(calls); NOWV=$((T0 + 899)); sweep
[ "$(calls)" = "$B" ] && cmp -s "$SD/o__r.stamp" "$T/stamp.before" && cmp -s "$SD/.last-run" "$T/last.before" && ok \
  || bad "S12a: a run inside the period makes 0 requests and writes nothing, got $(( $(calls) - B )) requests"
NOWV=$((T0 + 900 + 30)); sweep
[ "$(calls)" -gt "$B" ] && ok || bad "S12b: a run one period later sweeps"
reset
prs r 10 20; prs r2 1 3; publish
GH_CACHE_SWEEP=0 sweep
[ "$(calls)" = 0 ] && [ ! -e "$SD" ] && [ "$(cat "$T/src")" = 0 ] && ok || bad "S13: GH_CACHE_SWEEP=0: 0 requests and no state, got $(calls) requests"
# S13b: the default is off. With GH_CACHE_SWEEP unset the lane exits 0 with no
# GitHub call and no stamp, so ghc_sweep_covers answers rc 1 (the shim as on main).
reset
prs r 10 20; prs r2 1 3; publish
unset GH_CACHE_SWEEP
sweep
[ "$(calls)" = 0 ] && [ ! -e "$SD/o__r.stamp" ] && [ ! -e "$SD" ] && [ "$(cat "$T/src")" = 0 ] && ok \
  || bad "S13b: GH_CACHE_SWEEP unset = off: 0 requests and no stamp, got $(calls) requests"
S13C=$( . "$LIB" >/dev/null 2>&1 || exit 1; export GH_CACHE_NOW=$((T0 + 100)); ghc_sweep_covers "$CACHE" o__r~n-12 $((T0 - 10)) && printf y || printf n)
[ "$S13C" = n ] && ok || bad "S13c: with the lane off, ghc_sweep_covers answers rc 1, got '$S13C'"
KDEF=$(jq -r .default "$(dirname "$0")/../catalog/lanes.d/gh-cache-sweep.knobs.d/GH_CACHE_SWEEP.json" 2>/dev/null)
[ "$KDEF" = 0 ] && ok || bad "S13d: the knob file default is 0 (off), got '$KDEF'"
export GH_CACHE_SWEEP=1
reset
sweep nope
[ "$(calls)" = 0 ] && [ ! -e "$SD" ] && grep -q "registry unreadable" "$SLOG" && ok || bad "S14: an unknown project: no request, no state, one log line"

# ══ K: the change rule, through real sweeps ═════════════════════════════════
reset
prs r 1 150; prs r2 1 3
iss r 7 "$(upd 1)"; publish
sweep
seed o__r~n-5~a "o__r~s-$(head_of 5 | cut -c1-12)~a" o__r~n-7~a o__r~n-9~a o__r~n-140~a o__r~n-150~a o__r~n-151~a \
     o__r~n-160~a o__r~n-170~a o__r~r~a o__r2~n-5~a o__r~n-15~a
setpr r 5 "$(upd 1)" "$(head_of 5 2)"            # a force-push in the same updated_at second
setpr r 140 "$(upd 4)" "$(head_of 140)"          # a change on page 2
delpr r 150; iss r 150 "$(upd 4)"                # closed
delpr r 15                                       # closed, and no issues row in the window
setpr r 151 "$(upd 4)" "$(head_of 151)"          # a new PR
iss r 160 "$(upd 4)"                             # an issue that changed
iss r 170 "$(upd 4)"                             # an issue that changed
publish
NOWV=$((T0 + 900)); sweep
for e in o__r~n-5~a "o__r~s-$(head_of 5 | cut -c1-12)~a" o__r~n-140~a o__r~n-150~a o__r~n-151~a o__r~n-160~a o__r~n-170~a o__r~n-15~a o__r~r~a; do
  gone "$e" && ok || bad "K1: $e must be dropped"
done
have o__r~n-7~a && have o__r~n-9~a && have o__r2~n-5~a && ok || bad "K2: PR 7 (an issues row with its recorded updated_at), PR 9 and o/r2 stay"
[[ "$(lastlog)" =~ changed=7\  ]] && ok || bad "K3: changed=7, got '$(lastlog)'"
# The same window again (the overlap): the recorded rows change nothing.
seed o__r~n-160~a o__r~n-170~a o__r~r~a
NOWV=$((T0 + 1800)); sweep
have o__r~n-160~a && have o__r~n-170~a && have o__r~r~a && ok || bad "K4: issues rows the overlap returns again with the recorded updated_at drop nothing"
[[ "$(lastlog)" =~ changed=0\  ]] && ok || bad "K5: changed=0, got '$(lastlog)'"
# The window starts at the previous sweep start minus the overlap.
grep -qF "since=$(iso $((T0 + 900 - 120)))&" "$T/real-calls.txt" && ok || bad "K6: the issues window starts at prev start - 120"

# ══ KR: an issues window over the page cap restarts the chain ════════════════
reset
prs r 1 5; prs r2 1 3
for n in $(seq 1 100); do iss r "$n" "$(upd 2)"; done
publish
GH_CACHE_SWEEP_MAX_PAGES=1 sweep
seed o__r~n-5~a o__r~r~a
setpr r 5 "$(upd 3)" "$(head_of 5 2)"; publish
NOWV=$((T0 + 900)); GH_CACHE_SWEEP_MAX_PAGES=1 sweep
have o__r~n-5~a && have o__r~r~a && ok || bad "KR1: a restart drops nothing"
[ "$(cat "$SD/o__r.stamp")" = "v3 $((T0 + 900)) $((T0 + 900)) 900 $((T0 + 900)) $((T0 + 900)) 2" ] && ok || bad "KR2: a restart starts a new chain, got '$(cat "$SD/o__r.stamp")'"
grep -q "chain restarts" "$SLOG" && ok || bad "KR3: one log line says the chain restarts"
# A pulls list over the cap is unreadable: no record, no stamp.
reset
prs r 1 200; prs r2 1 3; publish
GH_CACHE_SWEEP_MAX_PAGES=2 sweep
[ ! -e "$SD/o__r.stamp" ] && [ -e "$SD/o__r2.stamp" ] && [[ "$(lastlog)" =~ unreadable=1\  ]] && grep -q "repo=o/r unreadable reason=max-pages" "$SLOG" && ok \
  || bad "KR4: a pulls list over the page cap is unreadable, got '$(lastlog)'"

# ══ KN: the knob fallbacks ═══════════════════════════════════════════════════
reset
prs r 10 20; prs r2 1 3; publish
GH_CACHE_SWEEP_PERIOD_S=abc GH_CACHE_SWEEP_OVERLAP_S=x GH_CACHE_SWEEP_MAX_PAGES=-1 GH_CACHE_SWEEP_TRUST_PERIODS=y sweep
[[ "$(lastlog)" =~ period=900\ overlap=120\ max_pages=20\ trust_periods=2$ ]] && [ "$(cut -d' ' -f7 "$SD/o__r.stamp")" = 2 ] && ok \
  || bad "KN1: non-numeric knobs fall back to 900/120/20/2, got '$(lastlog)' / '$(cat "$SD/o__r.stamp")'"
B=$(calls); NOWV=$((T0 + 840)); GH_CACHE_SWEEP_PERIOD_S=abc sweep
[ "$(calls)" = "$B" ] && ok || bad "KN2: a bad period is 900: 840 s later nothing runs"
NOWV=$((T0 + 900)); GH_CACHE_SWEEP_OVERLAP_S=30 GH_CACHE_SWEEP_PERIOD_S=60 GH_CACHE_SWEEP_TRUST_PERIODS=3 sweep
[ "$(cut -d' ' -f7 "$SD/o__r.stamp")" = 3 ] && ok || bad "KN4: the trust knob is written into the stamp, got '$(cat "$SD/o__r.stamp")'"
reset; prs r 10 20; prs r2 1 3; publish
GH_CACHE_SWEEP_TRUST_PERIODS=0 sweep
[ "$(cut -d' ' -f7 "$SD/o__r.stamp")" = 1 ] && ok || bad "KN5: a trust knob under 1 is 1, got '$(cat "$SD/o__r.stamp")'"
reset; prs r 10 20; prs r2 1 3; publish; sweep
NOWV=$((T0 + 900)); GH_CACHE_SWEEP_OVERLAP_S=30 GH_CACHE_SWEEP_PERIOD_S=60 sweep
grep -qF "since=$(iso $((T0 - 30)))&" "$T/real-calls.txt" && [[ "$(lastlog)" =~ period=300\ overlap=30\  ]] && ok \
  || bad "KN3: the overlap knob sets the window, a period under 300 is 300, got '$(lastlog)'"

# ══ C: ghc_sweep_covers, every row of the rule ══════════════════════════════
CD="$T/cc/state/gh-cache"; CS="$T/cc/state/gh-cache-sweep"
S=$((T0 + 1000))
cov() { # cov <stamp line|-> <tag> <fetched> <now> [.rdrop.o__r] [.rdrop._all] — prints y or n
  rm -rf "$T/cc"; mkdir -p "$CD" "$CS"
  [ "$1" = - ] || printf '%s\n' "$1" > "$CS/o__r.stamp"
  [ -z "${5:-}" ] || printf '%s\n' "$5" > "$CD/.rdrop.o__r"
  [ -z "${6:-}" ] || printf '%s\n' "$6" > "$CD/.rdrop._all"
  ( . "$LIB" >/dev/null 2>&1 || exit 1; export GH_CACHE_NOW="$4"; ghc_sweep_covers "$CD" "$2" "$3" ) && printf y || printf n
}
GOOD="v3 $S $T0 900 $T0 $((S + 5)) 2"
crow() { local want="$1" name="$2"; shift 2; [ "$(cov "$@")" = "$want" ] && ok || bad "C.$name: want $want, got $(cov "$@")"; }
crow y n-covered "$GOOD" o__r~n-12 $((S - 10)) $((S + 100))
crow y r-no-rdrop "$GOOD" o__r~r $((S - 10)) $((S + 100))
crow y r-old-rdrop "$GOOD" o__r~r $((S - 10)) $((S + 100)) $((S - 20)) $((S - 30))
crow y edge-1799 "$GOOD" o__r~n-12 $((S - 10)) $((S + 1799))
crow n no-stamp - o__r~n-12 $((S - 10)) $((S + 100))
crow n start-eq-fetched "$GOOD" o__r~n-12 "$S" $((S + 100))
crow n start-lt-fetched "$GOOD" o__r~n-12 $((S + 5)) $((S + 100))
crow n edge-2-periods "$GOOD" o__r~n-12 $((S - 10)) $((S + 1800))
crow n chain-after-fetch "v3 $S $((S - 5)) 900 $T0 $((S + 5)) 2" o__r~n-12 $((S - 10)) $((S + 100))
crow y base-before-fetch "v3 $S $T0 900 $((S - 11)) $((S + 5)) 2" o__r~n-12 $((S - 10)) $((S + 100))
crow n base-after-fetch "v3 $S $T0 900 $((S - 5)) $((S + 5)) 2" o__r~n-12 $((S - 10)) $((S + 100))
crow n base-eq-fetched "v3 $S $T0 900 $((S - 10)) $((S + 5)) 2" o__r~n-12 $((S - 10)) $((S + 100))
crow n r-base-after-fetch "v3 $S $T0 900 $((S - 5)) $((S + 5)) 2" o__r~r $((S - 10)) $((S + 100))
crow n stamp-v1 "v1 $S $T0 900" o__r~n-12 $((S - 10)) $((S + 100))
crow n search-no-repo "$GOOD" _~r $((S - 10)) $((S + 100))
crow n rdrop-eq-fetched "$GOOD" o__r~r $((S - 10)) $((S + 100)) $((S - 10))
crow n rdrop-all-after "$GOOD" o__r~r $((S - 10)) $((S + 100)) "" $((S - 5))
crow n rdrop-empty "$GOOD" o__r~r $((S - 10)) $((S + 100)) " "
crow n stamp-v0 "v0 $S $T0 900 $T0 $S" o__r~n-12 $((S - 10)) $((S + 100))
crow n stamp-6-fields-v3 "v3 $S $T0 900 $T0 $S" o__r~n-12 $((S - 10)) $((S + 100))
crow n stamp-8-fields "v3 $S $T0 900 $T0 $S 2 9" o__r~n-12 $((S - 10)) $((S + 100))
crow n stamp-non-number "v3 $S x 900 $T0 $S 2" o__r~n-12 $((S - 10)) $((S + 100))
crow n stamp-base-non-number "v3 $S $T0 900 x $S 2" o__r~n-12 $((S - 10)) $((S + 100))
crow n stamp-period-0 "v3 $S $T0 0 $T0 $S 2" o__r~n-12 $((S - 10)) $((S + 100))
# BH-9453 fix round: the trust window is <trust_periods> x <period>, from the stamp (knob GH_CACHE_SWEEP_TRUST_PERIODS).
crow n stamp-v2-old-format "v2 $S $T0 900 $T0 $((S + 5))" o__r~n-12 $((S - 10)) $((S + 100))
crow y trust-3-edge-2699 "v3 $S $T0 900 $T0 $((S + 5)) 3" o__r~n-12 $((S - 10)) $((S + 2699))
crow n trust-3-edge-2700 "v3 $S $T0 900 $T0 $((S + 5)) 3" o__r~n-12 $((S - 10)) $((S + 2700))
crow n trust-1-edge-900 "v3 $S $T0 900 $T0 $((S + 5)) 1" o__r~n-12 $((S - 10)) $((S + 900))
crow n stamp-trust-0 "v3 $S $T0 900 $T0 $((S + 5)) 0" o__r~n-12 $((S - 10)) $((S + 100))
crow n stamp-trust-non-number "v3 $S $T0 900 $T0 $((S + 5)) x" o__r~n-12 $((S - 10)) $((S + 100))
# BLOCK 1: the bare PR read (GHC_LPATH, set by ghc_main) is never covered; a PR sub-path is.
CLP=$( for lp in repos/o/r/pulls/12 'repos/o/r/pulls/12?x=1' repos/o/r/pulls/12/files repos/o/r/issues/12; do
  rm -rf "$T/cc"; mkdir -p "$CD" "$CS"; printf '%s\n' "$GOOD" > "$CS/o__r.stamp"
  ( . "$LIB" >/dev/null 2>&1 || exit 1; export GH_CACHE_NOW=$((S + 100)); GHC_LPATH="$lp"; ghc_sweep_covers "$CD" o__r~n-12 $((S - 10)) ) && printf y || printf n
done )
[ "$CLP" = nnyy ] && ok || bad "C.lpath: bare pulls/12 (with or without a query) n, pulls/12/files and issues/12 y, got '$CLP'"
crow n now-before-start "$GOOD" o__r~n-12 $((S - 10)) $((S - 1))
crow n other-repo "$GOOD" o__r3~n-12 $((S - 10)) $((S + 100))
crow n repo-with-slash "$GOOD" ../o__r~n-12 $((S - 10)) $((S + 100))
crow n sha-tag "$GOOD" o__r~s-abcdef012345 $((S - 10)) $((S + 100))
crow n fetched-not-number "$GOOD" o__r~n-12 abc $((S + 100))
# A repo part that is `_` or holds `/` is refused even with a good stamp at the path it names.
CBAD=$( rm -rf "$T/cc"; mkdir -p "$CD" "$CS"; printf '%s\n' "$GOOD" > "$CS/_.stamp"; printf '%s\n' "$GOOD" > "$T/cc/state/o__r.stamp"
  . "$LIB" >/dev/null 2>&1 || exit 1; export GH_CACHE_NOW=$((S + 100))
  ghc_sweep_covers "$CD" _~r $((S - 10)) && printf y || printf n
  ghc_sweep_covers "$CD" ../o__r~n-12 $((S - 10)) && printf y || printf n)
[ "$CBAD" = nn ] && ok || bad "C.bad-repo-with-stamp: want nn, got '$CBAD'"
# The default seam (no gh-cache-sweep.sh) never covers.
C0=$( _ghc_libdir=/nonexistent; ghc_sweep_covers() { return 1; }; ghc_sweep_covers "$CD" o__r~n-12 1 && printf y || printf n)
[ "$C0" = n ] && ok || bad "C.default: the inline default is rc 1"

# ══ R: lists and search through the shim ═══════════════════════════════════
# rsetup <endpoint> — a list entry fetched at T0+100, a clean sweep at T0+7200.
rsetup() {
  reset 300
  prs r 10 20; prs r2 1 3; publish
  sweep
  NOWV=$((T0 + 100)); run api "$1"
  NOWV=$((T0 + 7200)); sweep
}
# R1: a fresh stamp serves a 7200 s old pulls list entry with 0 requests.
rsetup 'repos/o/r/pulls?state=open'
B=$(calls); NOWV=$((T0 + 7300)); run api 'repos/o/r/pulls?state=open'
[ "$(calls)" = "$B" ] && [ "$(lastserved)" = cache ] && cmp -s "$T/out" "$T/fx/o_r.pulls.1.json" && ok \
  || bad "R1: fresh stamp: the list is served cache, got $(( $(calls) - B )) requests, served $(lastserved)"
# R2: a stale stamp, or no stamp: a conditional request (the TTL rule).
B=$(calls); NOWV=$((T0 + 7200 + 1800)); run api 'repos/o/r/pulls?state=open'
[ "$(calls)" = $((B + 1)) ] && newcalls "$B" | grep -qF 'If-None-Match:' && [ "$(lastserved)" = 304 ] && ok \
  || bad "R2a: stale stamp: a conditional request, got $(( $(calls) - B )) requests, served $(lastserved)"
rsetup 'repos/o/r/pulls?state=open'
rm -f "$SD/o__r.stamp"
B=$(calls); NOWV=$((T0 + 7300)); run api 'repos/o/r/pulls?state=open'
[ "$(calls)" = $((B + 1)) ] && newcalls "$B" | grep -qF 'If-None-Match:' && [ "$(lastserved)" = 304 ] && ok \
  || bad "R2b: no stamp: a conditional request, got $(( $(calls) - B )) requests, served $(lastserved)"
# R2c: an r entry is never served on its age alone: 200 s old, inside the
# event max, with no stamp, is still a conditional request.
rsetup 'repos/o/r/pulls?state=open'
rm -f "$SD/o__r.stamp"
B=$(calls); NOWV=$((T0 + 300)); run api 'repos/o/r/pulls?state=open'
[ "$(calls)" = $((B + 1)) ] && [ "$(lastserved)" = 304 ] && ok || bad "R2c: an r entry inside the event max with no stamp is conditional, served $(lastserved)"
# R3: search/issues follows the same two rules once a scope seam tags it o__r~r.
SQ='search/issues?q=repo:o/r+is:pr+is:open'
scratch_install_closure bin/gh-ledger/gh "$T/inst3" >/dev/null
printf '#!/bin/bash\nghc_scope_tag() { case "$1" in search/issues\\?q=repo:o/r+*) printf "o__r~r" ;; esac; }\nghc_wake_drop() { ghc_drop "$1/$2~r~*"; }\n' > "$T/inst3/bin/lib/gh-cache-scope.sh"
P0="$T/inst3/bin/gh-ledger:$T/real:/usr/bin:/bin"
rsetup "$SQ"
ls "$CACHE" | grep -q '^o__r~r~' && ok || bad "R3a: the scope seam stores the search under o__r~r"
B=$(calls); NOWV=$((T0 + 7300)); run api "$SQ"
[ "$(calls)" = "$B" ] && [ "$(lastserved)" = cache ] && ok || bad "R3b: fresh stamp: the search is served cache, got $(( $(calls) - B )) requests, served $(lastserved)"
B=$(calls); NOWV=$((T0 + 7200 + 1800)); run api "$SQ"
[ "$(calls)" = $((B + 1)) ] && [ "$(lastserved)" = 304 ] && ok || bad "R3c: stale stamp: the search is conditional, served $(lastserved)"
P0="$SHIMDIR:$T/real:/usr/bin:/bin"
rsetup "$SQ"
ls "$CACHE" | grep -q '^_~r~' && ok || bad "R3d: the default seam stores the search under _~r"
B=$(calls); NOWV=$((T0 + 7300)); run api "$SQ"
[ "$(calls)" = $((B + 1)) ] && [ "$(lastserved)" = 304 ] && ok || bad "R3e: a _~r search past the TTL is never served, served $(lastserved)"
# R4: GH_CACHE_EVENT_MAX_S=0: an r entry past the TTL is conditional, 0 wake reads.
rsetup 'repos/o/r/pulls?state=open'
export GH_CACHE_EVENT_MAX_S=0; rm -f "$T/jobs-calls.txt"
B=$(calls); NOWV=$((T0 + 7300)); run api 'repos/o/r/pulls?state=open'
[ "$(calls)" = $((B + 1)) ] && [ "$(lastserved)" = 304 ] && [ "$(jcalls)" = 0 ] && ok \
  || bad "R4: knob off: a conditional request and 0 wake reads, served $(lastserved), $(jcalls) wake reads"
# R5: a list drop at or after the fetch makes the entry conditional; a wake drops it.
rsetup 'repos/o/r/pulls?state=open'
printf '%s\n' $((T0 + 100)) > "$CACHE/.rdrop.o__r"
B=$(calls); NOWV=$((T0 + 7300)); run api 'repos/o/r/pulls?state=open'
[ "$(calls)" = $((B + 1)) ] && [ "$(lastserved)" = 304 ] && ok || bad "R5a: fetched <= .rdrop.o__r: conditional, served $(lastserved)"
rm -f "$CACHE/.rdrop.o__r"
printf '{"wakes":[{"id":101,"repo":"O/R","kind":"pr","key":"12"}]}' > "$T/wakes.json"
B=$(calls); NOWV=$((T0 + 7400)); run api 'repos/o/r/pulls?state=open'
[ "$(calls)" = $((B + 1)) ] && ! grep -qF 'If-None-Match' <<<"$(newcalls "$B")" && [ "$(lastserved)" = 200 ] && ok \
  || bad "R5b: a wake drops the list: an unconditional request, got: $(newcalls "$B" | tr '\n' '|') served $(lastserved)"
[ "$(cat "$CACHE/.rdrop.o__r" 2>/dev/null)" = $((T0 + 7400)) ] && ok || bad "R5c: the wake's list drop writes .rdrop.o__r, got '$(cat "$CACHE/.rdrop.o__r" 2>/dev/null)'"
# R5d: the seed drop (*~*~*) writes .rdrop._all.
R5D=$( . "$LIB" >/dev/null 2>&1 || exit 1; mkdir -p "$T/sd"; : > "$T/sd/o__r~r~x"; export GH_CACHE_NOW=4242; ghc_drop "$T/sd/*~*~*"; cat "$T/sd/.rdrop._all"; ls "$T/sd" | grep -c '~')
[ "$R5D" = "$(printf '4242\n0')" ] && ok || bad "R5d: the seed drop writes .rdrop._all and removes the entries, got '$R5D'"
# R6: an r entry that is not a pulls/issues list or a search is never served past the TTL.
rsetup 'repos/o/r/branches/main'
B=$(calls); NOWV=$((T0 + 7300)); run api 'repos/o/r/branches/main'
[ "$(calls)" = $((B + 1)) ] && [ "$(lastserved)" = 304 ] && ok || bad "R6: a branch read with a fresh stamp is conditional, served $(lastserved)"

[ ! -e "$T/unstubbed.txt" ] && ok || bad "Z: no unstubbed endpoint over the suite, got: $(cat "$T/unstubbed.txt")"
echo "gh-cache-sweep.bh-9417: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
