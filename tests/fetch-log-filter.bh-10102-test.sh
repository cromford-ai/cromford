#!/bin/bash
# tests/fetch-log-filter.bh-10102-test.sh — bin/fetch-log.sh reads a 5 MiB
# window from a knob, takes optional match/since/until filters, and fits its
# beat to a safe response size with the left-out counts and the exact call that
# gets them (BH-10102). A RUNNER_EXHAUSTED alert 4 h back in a 31 MB ALERTS.log
# was out of reach of the old 16,000-byte tail.
#
# The clock is pinned: FETCH_LOG_NOW (epoch) is the script's "now" for 6h/24h
# inputs, and every fixture line is stamped relative to the same NOW. Fixture
# logs are built at run time; nothing large is committed. No network: the
# scratch HARNESS has no jobs client, so the knob read falls to env/fallback.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
export HARNESS="$T"
mkdir -p "$T/logs" "$T/tmpd"
export TMPDIR="$T/tmpd"
printf 'alpha-os Org/alpha https://alpha.example /api/board 2 box-alpha\n' > "$T/fleet.conf"
export FLEET_CONF="$T/fleet.conf"
NOW=1795608000            # 2026-11-25T12:00:00Z
export FETCH_LOG_NOW=$NOW
unset FETCH_LOG_TAIL_BYTES FETCH_LOG_RESPONSE_BYTES

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# fl <project> <which> <cid> [match] [since] [until] — the beat on stdout
fl() { "$DIR/bin/fetch-log.sh" "$@" 2>/dev/null; }
st() { date -u -d "@$(( NOW - $1 ))" '+%Y-%m-%d %H:%M:%S'; }   # st <secs ago>
lines() { local n; n=$(wc -l < "$1"); [ -s "$1" ] && [ "$(tail -c1 "$1" | od -An -c | tr -d ' ')" != '\n' ] && n=$((n+1)); echo "$n"; }
RESP_DEFAULT=$(jq -r '.libs[]|select(.id=="fetch-log")|.knobs[]|select(.env=="FETCH_LOG_RESPONSE_BYTES")|.default' "$DIR/catalog/lanes.d/_lib.fetch-log.json")
TAIL_DEFAULT=$(jq -r '.libs[]|select(.id=="fetch-log")|.knobs[]|select(.env=="FETCH_LOG_TAIL_BYTES")|.default' "$DIR/catalog/lanes.d/_lib.fetch-log.json")

# ── K: the knobs ─────────────────────────────────────────────────────────────
printf '%s x\n' "$(st 10)" > "$T/logs/pipeline-health.log"
OUT=$(fl hub pipeline k1)
[ "$(jq -r .tail_max_bytes <<<"$OUT")" = 5242880 ] && [ "$(jq -r .response_max_bytes <<<"$OUT")" = 98304 ] \
  && ok || bad "K1: no row, no env -> 5242880/98304 (got $(jq -c '[.tail_max_bytes,.response_max_bytes]' <<<"$OUT"))"
[ "$TAIL_DEFAULT" = "$(jq -r .tail_max_bytes <<<"$OUT")" ] && [ "$RESP_DEFAULT" = "$(jq -r .response_max_bytes <<<"$OUT")" ] \
  && ok || bad "K2: the registry defaults ($TAIL_DEFAULT/$RESP_DEFAULT) must equal the code fallbacks"
OUT=$(FETCH_LOG_TAIL_BYTES=99999999 fl hub pipeline k3)
[ "$(jq -r .tail_max_bytes <<<"$OUT")" = 16777216 ] && ok || bad "K3: 99999999 must stop at the 16777216 ceiling (got $(jq -r .tail_max_bytes <<<"$OUT"))"
OUT=$(FETCH_LOG_TAIL_BYTES=abc FETCH_LOG_RESPONSE_BYTES=12x fl hub pipeline k3b)
[ "$(jq -r .tail_max_bytes <<<"$OUT")" = 5242880 ] && [ "$(jq -r .response_max_bytes <<<"$OUT")" = 98304 ] \
  && ok || bad "K3: a value that is not a number is the fallback"
# K4: a settings row wins over the fallback (the row the seed fragment inserts).
mkdir -p "$T/state"
jq -nc --argjson fa "$NOW" '{fetched_at:$fa,values:{"lib.fetch-log.fetch_log_tail_bytes":"2097152"},seeded:{}}' > "$T/state/settings-cache.json"
OUT=$(LANE_GATE_NOW=$NOW fl hub pipeline k4)
[ "$(jq -r .tail_max_bytes <<<"$OUT")" = 2097152 ] && ok || bad "K4: an operator row 2097152 must be the window (got $(jq -r .tail_max_bytes <<<"$OUT"))"
rm -rf "$T/state"
grep -q "lib.fetch-log.fetch_log_tail_bytes','5242880'" "$DIR"/worker/jobs/schema.d/*bh-10102*.sql \
  && grep -q "lib.fetch-log.fetch_log_response_bytes','98304'" "$DIR"/worker/jobs/schema.d/*bh-10102*.sql \
  && ok || bad "K5: the seed fragment must carry both rows at the default values"

# ── T: a 6 MiB log of every which reads a 5 MiB window ──────────────────────
mk6() { awk -v n=6291456 'BEGIN{ s=sprintf("%0100d",0); i=0; b=0;
  while (b < n) { l=sprintf("2026-11-25 11:%02d:%02dZ line-%07d %s", int(i/60)%60, i%60, i, s); print l; b+=length(l)+1; i++ } }' | head -c 6291456 > "$1"; }
mk6 "$T/logs/w6.src"
for W in triage alerts pipeline cost decisions; do
  P=hub; [ "$W" = triage ] && P=alpha-os
  F=$("$DIR/bin/fetch-log.sh" --path "$W" "$P")
  cp "$T/logs/w6.src" "$F"
  OUT=$(fl "$P" "$W" "t-$W")
  [ "$(jq -r .bytes <<<"$OUT")" = 6291456 ] && [ "$(jq -r .window_bytes <<<"$OUT")" -le 5242880 ] \
    && [ "$(jq -r .window_bytes <<<"$OUT")" -gt 5242000 ] \
    && [ "$(jq -r .tail_max_bytes <<<"$OUT")" = 5242880 ] && [ "$(jq -r .truncated <<<"$OUT")" = true ] \
    && ok || bad "T1 $W: a 6 MiB log must read a ~5 MiB window (got $(jq -c '[.bytes,.window_bytes,.tail_max_bytes,.truncated]' <<<"$OUT"))"
  FL1=$(jq -j .content <<<"$OUT" | head -1)
  grep -qE '^2026-11-25 11:[0-9]{2}:[0-9]{2}Z line-[0-9]{7} 0{100}$' <<<"$FL1" \
    && ok || bad "T2 $W: the first content line must be whole"
  rm -f "$F"
done
# T3: the window edge with a small knob: the first line of the window is whole
printf 'aaaa\nbbbb\ncccc\n' > "$T/logs/ALERTS.log"
OUT=$(FETCH_LOG_TAIL_BYTES=7 fl hub alerts t3)   # env is not clamped up to the row min
[ "$(jq -j .content <<<"$OUT")" = "cccc" ] && [ "$(jq -r .truncated <<<"$OUT")" = true ] \
  && ok || bad "T3: a window starting mid-line drops the partial line (got $(jq -c .content <<<"$OUT"))"
# T4: one line longer than the window is its last window bytes, line_cut true;
# with no knob the same 20,000-byte line (once over the old 16,000 cap) is whole.
head -c 20000 /dev/zero | tr '\0' 'x' > "$T/logs/ALERTS.log"
OUT=$(FETCH_LOG_TAIL_BYTES=16000 fl hub alerts t4)
[ "$(jq -j .content <<<"$OUT" | wc -c)" = 16000 ] && [ "$(jq -r .line_cut <<<"$OUT")" = true ] && [ "$(jq -r .truncated <<<"$OUT")" = true ] \
  && ok || bad "T4: a 20000-byte line in a 16000 window is cut to 16000 bytes (got $(jq -c 'del(.content)' <<<"$OUT"))"
OUT=$(fl hub alerts t4b)
[ "$(jq -j .content <<<"$OUT" | wc -c)" = 20000 ] && [ "$(jq -r .truncated <<<"$OUT")" = false ] && [ "$(jq -r .line_cut <<<"$OUT")" = false ] \
  && ok || bad "T4b: with the 5 MiB default a 20000-byte file comes back whole"

# ── A: a 30 MB ALERTS.log over 48 h ─────────────────────────────────────────
# One line a second, ~200 bytes, plus 6 RUNNER_EXHAUSTED lines of ~1 KB (4 in
# the last 24 h, 2 older), each naming the account the way the pool alert does.
PAD=$(printf '%0900d' 0)
# date -f stamps every second in one process (mawk has no strftime).
seq $((NOW-48*3600)) $((NOW-1)) | sed 's/^/@/' | date -u -f - '+%s %Y-%m-%d %H:%M:%SZ' \
| awk -v now="$NOW" -v pad="$(printf '%0170d' 0)" -v big="$PAD" '
  BEGIN { ex[now-2*3600-23*60]=1; ex[now-5*3600]=1; ex[now-9*3600]=1; ex[now-20*3600]=1; ex[now-30*3600]=1; ex[now-40*3600]=1 }
  { t=$1; s=$2 " " $3
    if (t in ex) printf "%s [pool/project-5] BH-%d: the RUNNER LANE failed, not the ticket (BUILD_DEFERRED plan session ended RUNNER_EXHAUSTED class=account-exhausted(quota) seen=account-exhausted runner=claude rc=1 exhausted=claude resets_at=1795700000 account=max3) %s\n", s, t%10000, big
    else printf "%s [pool/project-5] tick %d ok %s\n", s, t, pad }' > "$T/logs/ALERTS.log"
AF="$T/logs/ALERTS.log"
ASIZE=$(wc -c < "$AF"); ALINES=$(lines "$AF")
[ "$ASIZE" -gt 30000000 ] && ok || bad "fixture: ALERTS.log must be over 30 MB (is $ASIZE)"

S0=$SECONDS
A1=$(fl hub alerts a1)
[ "$(jq -r .truncated <<<"$A1")" = true ] && ok || bad "A1: truncated must be true"
[ "$(jq -j .content <<<"$A1" | tail -1)" = "$(tail -1 "$AF")" ] && ok || bad "A1: the newest file line must be the last content line"
[ "${#A1}" -le 98304 ] && ok || bad "A1: the beat is ${#A1} bytes, over 98304"
RB=$(jq -r .returned_bytes <<<"$A1"); OB=$(jq -r .omitted_bytes <<<"$A1")
RL=$(jq -r .returned_lines <<<"$A1"); OL=$(jq -r .omitted_lines <<<"$A1")
[ $((RB + OB)) -eq "$ASIZE" ] && ok || bad "A1: returned_bytes+omitted_bytes ($RB+$OB) must equal the file size $ASIZE"
[ $((RL + OL)) -eq "$ALINES" ] && ok || bad "A1: returned_lines+omitted_lines ($RL+$OL) must equal the file lines $ALINES"
[ "$(jq -j .content <<<"$A1" | wc -c)" -eq "$RB" ] && ok || bad "A1: returned_bytes must be the real content size"
[ "$(jq -j .content <<<"$A1" | head -1 | cut -c1-4)" = 2026 ] && ok || bad "A1: the first content line must be whole"
grep -q "fetch_log id=a1 project=hub which=alerts -> ok ${ASIZE}b truncated=true missing=false returned=${RB}b omitted=${OB}b filter=0" "$T/logs/console-commands.log" \
  && ok || bad "A1: the journal line must carry returned= and omitted=: $(tail -1 "$T/logs/console-commands.log")"

A2=$(fl hub alerts a2 RUNNER_EXHAUSTED 24h)
WANT=$(awk -v s="$(st 86400 | tr ' ' T)" '{ k=$1 "T" substr($2,1,8) } k >= s' "$AF" | grep -F RUNNER_EXHAUSTED)
[ "$(printf '%s\n' "$WANT" | grep -c .)" = 4 ] && ok || bad "A2 fixture: 4 RUNNER_EXHAUSTED lines in the last 24 h"
[ "$(jq -j .content <<<"$A2")" = "$WANT" ] && ok || bad "A2: match+since must return exactly the 4 lines, whole, newest last"
[ "$(jq -j .content <<<"$A2" | grep -c 'runner=claude rc=1 exhausted=claude resets_at=1795700000 account=max3')" = 4 ] \
  && ok || bad "A2: each line must hold the whole runner value and the account label"
[ "$(jq -r .truncated <<<"$A2")" = false ] && [ "$(jq -r .more <<<"$A2")" = null ] && ok || bad "A2: nothing left out -> truncated false, more null"
[ "$(jq -r .filter.match <<<"$A2")" = RUNNER_EXHAUSTED ] && [ "$(jq -r .filter.since <<<"$A2")" = "$(st 86400 | tr ' ' T)" ] \
  && ok || bad "A2: the filter echo must hold match and the normalized since"
grep -q 'RUNNER_EXHAUSTED' "$T/logs/console-commands.log" && bad "A2: the match text reached the journal" || ok
grep -q "id=a2 .* filter=1" "$T/logs/console-commands.log" && ok || bad "A2: the journal must say filter=1"

A3=$(fl hub alerts a3 '' 6h)
SINCE6=$(st 21600 | tr ' ' T)
MINK=$(jq -j .content <<<"$A3" | awk '{print $1 "T" substr($2,1,8)}' | sort | head -1)
[ -n "$MINK" ] && [[ ! "$MINK" < "$SINCE6" ]] && ok || bad "A3: every line must be at or after $SINCE6 (oldest $MINK)"
[ "$(jq -r .more.since <<<"$A3")" = "$SINCE6" ] && ok || bad "A3: the more call must keep since=$SINCE6"
[ "$(jq -r .matched_lines <<<"$A3")" = 21600 ] && ok || bad "A3: 6 h of one line a second is 21600 matched lines (got $(jq -r .matched_lines <<<"$A3"))"
# Reported, not gated (D50): bcx_run bounds each read with timeout 30.
echo "fetch-log-filter: three reads of a $ASIZE-byte log took $((SECONDS - S0)) s"

# A3b: the near miss on a small log — one second before since is OUT
{ printf '%s old\n' "$(st 25200)"; printf '%s miss\n' "$(st 21601)"; printf '%s edge\n' "$(st 21600)"; printf '%s new\n' "$(st 3600)"; } > "$T/logs/pipeline-health.log"
OUT=$(fl hub pipeline a3b '' 6h)
[ "$(jq -j .content <<<"$OUT" | awk '{print $3}' | tr '\n' ,)" = "edge,new," ] && ok || bad "A3b: since=6h must keep edge,new only (got $(jq -c .content <<<"$OUT"))"

# ── R: the more call returns the left-out lines, no gap, no duplicate ───────
MORE_U=$(jq -r .more.until <<<"$A1")
[ "$(jq -r .more.match <<<"$A1")" = null ] && [ "$(jq -r .more.since <<<"$A1")" = null ] && [ "$MORE_U" != null ] \
  && ok || bad "R1: the no-filter more call is until=<first returned stamp> (got $(jq -c .more <<<"$A1"))"
R1=$(fl hub alerts r1 '' '' "$MORE_U")
FIRST=$(jq -j .content <<<"$A1" | head -1)
PREV=$(grep -n -F -x -- "$FIRST" "$AF" | head -1 | cut -d: -f1); PREV=$((PREV - 1))
[ "$(jq -j .content <<<"$R1" | tail -1)" = "$(sed -n "${PREV}p" "$AF")" ] && ok || bad "R1: the more call's newest line must be the line just before the first returned line"
grep -qxF -- "$FIRST" <<<"$(jq -j .content <<<"$R1")" && bad "R1: the more call returned a line the first call already returned" || ok
[ "$(jq -r .filter.until <<<"$R1")" = "$MORE_U" ] && ok || bad "R1: the until echo"

# R2: twenty lines share each second, so the response cut lands inside a second.
seq 0 1999 | awk -v pad="$(printf '%01000d' 0)" '{ printf "2026-11-25 10:%02d:%02dZ r%04d %s\n", int($1/20/60)%60, int($1/20)%60, $1, pad }' > "$T/logs/decisions.log"
R2=$(fl hub decisions r2)
FIRST=$(jq -j .content <<<"$R2" | head -1 | awk '{print $3}')
N=${FIRST#r}; N=$((10#$N))
[ $((N % 20)) -eq 0 ] && ok || bad "R2: the returned part must start on a second boundary (starts at $FIRST)"
R2B=$(fl hub decisions r2b '' '' "$(jq -r .more.until <<<"$R2")")
PN=$(jq -j .content <<<"$R2B" | tail -1 | awk '{print $3}'); PN=${PN#r}; PN=$((10#$PN))
[ "$PN" -eq $((N - 1)) ] && ok || bad "R2: the more call must end at r$((N-1)), the line before the first returned (got r$PN)"
[ "$(jq -r .boundary_split <<<"$R2")" = false ] && ok || bad "R2: no boundary split when the cut could move"
# R3: the fitted beat passes to a beat.sh as ONE argv string (no E2BIG).
printf '#!/bin/bash\nprintf "%%s" "$1" | wc -c > "%s/argv-len"\n' "$T" > "$T/beat-stub.sh"; chmod +x "$T/beat-stub.sh"
"$T/beat-stub.sh" "$A1"; RC=$?
[ "$RC" = 0 ] && [ "$(cat "$T/argv-len")" = "${#A1}" ] && ok || bad "R3: the A1 beat must pass as one argv (rc=$RC)"
# R4: the log grows during the call (alert-line.sh appends to ALERTS.log all
# the time). A PATH shim on tail appends 30 lines the first time it runs, which
# is after the key pass. The beat and its more call must still leave no gap.
R4D="$T/r4"; mkdir -p "$R4D/bin"
R4L="$T/logs/decisions.log"
seq 0 1999 | awk '{ printf "2026-11-25 00:%02d:%02dZ g%04d growing-log-line\n", int($1/60)%60, $1%60, $1 }' > "$R4L"
cp "$R4L" "$R4D/before"
REAL_TAIL=$(command -v tail)
cat > "$R4D/bin/tail" <<EOF
#!/bin/bash
if [ ! -e "$R4D/appended" ]; then : > "$R4D/appended"
  for i in \$(seq 2000 2029); do printf '2026-11-25 01:%02d:%02dZ g%04d growing-log-line\n' \$(( (i/60)%60 )) \$((i%60)) "\$i" >> "$R4L"; done
fi
exec "$REAL_TAIL" "\$@"
EOF
chmod +x "$R4D/bin/tail"
R4=$(PATH="$R4D/bin:$PATH" FETCH_LOG_TAIL_BYTES=50000 FETCH_LOG_RESPONSE_BYTES=8192 fl hub decisions r4)
[ -e "$R4D/appended" ] && [ "$(lines "$R4L")" = 2030 ] && ok || bad "R4: the tail shim must have appended 30 lines (fixture did not grow)"
R4FIRST=$(jq -j .content <<<"$R4" | head -1 | awk '{print $3}'); R4FN=${R4FIRST#g}; R4FN=$((10#${R4FN:-0}))
R4LAST=$(jq -j .content <<<"$R4" | tail -1 | awk '{print $3}')
[ "$R4LAST" = g1999 ] && ok || bad "R4: the snapshot ends at the last line present when the call started (got $R4LAST)"
[ "$(jq -r .omitted_lines <<<"$R4")" = "$R4FN" ] && ok || bad "R4: omitted_lines must be the $R4FN lines before $R4FIRST (got $(jq -r .omitted_lines <<<"$R4"))"
[ "$(jq -r .bytes <<<"$R4")" = "$(wc -c < "$R4D/before")" ] && ok || bad "R4: bytes must be the size at the start of the call"
R4B=$(fl hub decisions r4b '' '' "$(jq -r .more.until <<<"$R4")")
R4PN=$(jq -j .content <<<"$R4B" | tail -1 | awk '{print $3}'); R4PN=${R4PN#g}; R4PN=$((10#${R4PN:-0}))
[ "$R4PN" -eq $((R4FN - 1)) ] && ok || bad "R4: the more call must end at g$((R4FN-1)), the line before the first returned $R4FIRST (got g$R4PN)"

# ── F: the line timestamp rule (since=2026-11-25T09:00:00) ──────────────────
cat > "$T/logs/cost.csv" <<'EOF'
preamble before any stamp
2026-11-25 08:00:00Z f-early
f-cont-early continuation after 08:00
2026-11-25 08:59:59Z f-nearmiss
x 2026-11-25 10:00:00Z f-midline
25/11/2026 10:00 f-otherformat
2026-11-25 09:37:12Z RUNNER_EXHAUSTED f-space
2026-11-25T09:37:12Z,f-tform
[2026-11-25 10:00] f-bracket
f-cont-late continuation after 10:00
2026-11-25 11:00:00Z f-at-until
2026-11-25 10:59:59Z f-before-until
EOF
fids() { jq -j .content <<<"$1" | grep -o 'f-[a-z-]*' | tr '\n' ,; }
OUT=$(fl hub cost f1 '' 2026-11-25T09:00:00)
# IN: space, T and bracket stamps, and a continuation after 10:00. OUT: the
# preamble, 08:00 and its continuation, 08:59:59 (near miss), and the mid-line
# stamp and the other date format, which inherit 08:59:59.
[ "$(fids "$OUT")" = "f-space,f-tform,f-bracket,f-cont-late,f-at-until,f-before-until," ] \
  && ok || bad "F1-F6: since keeps the stamped-in lines and their continuations (got $(fids "$OUT"))"
# A line with the stamp later in the line, or another date format, carries the
# key of the line before it (here 08:59:59), so it is OUT under a 09:00 since
# when it comes right after an old line:
printf '2026-11-25 08:59:59Z old\nx 2026-11-25 10:00:00Z f-midline\n25/11/2026 10:00 f-otherformat\n' > "$T/logs/cost.csv"
OUT=$(fl hub cost f7 '' 2026-11-25T09:00:00)
[ "$(fids "$OUT")" = "" ] && ok || bad "F7: a mid-line stamp or another format is not a stamp (got $(fids "$OUT"))"
cat > "$T/logs/cost.csv" <<'EOF'
preamble before any stamp
2026-11-25 10:59:59Z f-before-until
2026-11-25 11:00:00Z f-at-until
EOF
OUT=$(fl hub cost f8 '' '' 2026-11-25T11:00:00)
[ "$(jq -j .content <<<"$OUT")" = "$(printf 'preamble before any stamp\n2026-11-25 10:59:59Z f-before-until')" ] \
  && ok || bad "F8-F10: until is exclusive; lines before the first stamp are in with until only (got $(jq -c .content <<<"$OUT"))"
OUT=$(fl hub cost f9 '' 2026-11-25T00:00:00)
[ "$(fids "$OUT")" = "f-before-until,f-at-until," ] && ok || bad "F9: lines before the first stamp are out with since set"

# ── M: match ────────────────────────────────────────────────────────────────
cat > "$T/logs/pipeline-health.log" <<'EOF'
2026-11-25 09:00:00Z RUNNER_EXHAUSTED class=account-exhausted(quota) m-1
2026-11-25 09:01:00Z RUNNER_ERROR class=auth m-2
2026-11-25 09:02:00Z runner_exhausted lower m-3
2026-11-25 09:03:00Z -v dash line m-4
2026-11-25 09:04:00Z class=account-exhaustedXquotaX m-5
EOF
mids() { jq -j .content <<<"$1" | grep -o 'm-[0-9]' | tr '\n' ,; }
OUT=$(fl hub pipeline m1 'class=account-exhausted(quota)'); [ "$(mids "$OUT")" = "m-1," ] && ok || bad "M1: a fixed string matches its literal text with the parens (got $(mids "$OUT"))"
OUT=$(fl hub pipeline m2 RUNNER_EXHAUSTED); [ "$(mids "$OUT")" = "m-1," ] && ok || bad "M2: case-sensitive fixed match (got $(mids "$OUT"))"
OUT=$(fl hub pipeline m3 '/RUNNER_(EXHAUSTED|ERROR)/'); [ "$(mids "$OUT")" = "m-1,m-2," ] && ok || bad "M3: /…/ is an ERE (got $(mids "$OUT"))"
OUT=$(fl hub pipeline m4 '/a\1/'); [ "$(jq -r .error <<<"$OUT")" = bad_match ] && ok || bad "M4: a back-reference is refused (got $OUT)"
OUT=$(fl hub pipeline m5 "$(printf 'RUNNER\nX')"); [ "$(jq -r .error <<<"$OUT")" = bad_match ] && ok || bad "M5: a newline is refused"
OUT=$(fl hub pipeline m5b "$(printf 'RUN\tNER')"); [ "$(jq -r .error <<<"$OUT")" = bad_match ] && ok || bad "M5: a control char is refused"
OUT=$(fl hub pipeline m6 '-v'); [ "$(mids "$OUT")" = "m-4," ] && ok || bad "M6: a match that starts with - is a pattern, not a grep flag (got $(mids "$OUT"))"
OUT=$(fl hub pipeline m6b '/(/'); [ "$(jq -r .error <<<"$OUT")" = bad_match ] && ok || bad "M6b: an ERE that does not compile is refused"
OUT=$(fl hub pipeline m6c 'nothing-matches-this'); [ "$(jq -j .content <<<"$OUT")" = "" ] && [ "$(jq -r .error <<<"$OUT")" = null ] \
  && [ "$(jq -r .matched_lines <<<"$OUT")" = 0 ] && ok || bad "M6c: no match is an empty result, not an error"

# ── V: since/until input ───────────────────────────────────────────────────
for V in 6h 90m 2d 30s 2026-11-25 2026-11-25T09:37 '2026-11-25 09:37:00Z' 2026-11-25T09:37:00.5Z; do
  OUT=$(fl hub pipeline v-ok "" "$V")
  [ "$(jq -r .error <<<"$OUT")" = null ] && [ "$(jq -r .filter.since <<<"$OUT")" != null ] && ok || bad "V: since '$V' must be accepted (got $OUT)"
done
[ "$(jq -r .filter.since <<<"$(fl hub pipeline v6h '' 6h)")" = 2026-11-25T06:00:00 ] && ok || bad "V: 6h is NOW-6h"
[ "$(jq -r .filter.since <<<"$(fl hub pipeline vd '' 2026-11-25)")" = 2026-11-25T00:00:00 ] && ok || bad "V: a bare date is midnight UTC"
for V in '6 h' 6w -6h 2026-13-40 now '$(id)' 2026-02-30 '2026-11-25T09:37+02:00'; do
  OUT=$(fl hub pipeline v-bad "" "$V")
  [ "$(jq -r .error <<<"$OUT")" = bad_since ] && [ "$(jq -j .content <<<"$OUT")" = "" ] && ok || bad "V: since '$V' must be refused bad_since (got $OUT)"
done
OUT=$(fl hub pipeline v-bu "" "" "yesterday"); [ "$(jq -r .error <<<"$OUT")" = bad_until ] && ok || bad "V: a bad until is refused bad_until"
grep -q 'REFUSED: bad since' "$T/logs/console-commands.log" && ok || bad "V: a refusal writes one journal line"

# ── S: the response fit ─────────────────────────────────────────────────────
seq 1 300 | awk -v pad="$(printf '%0990d' 0)" '{ printf "2026-11-25 10:%02d:%02dZ hit%03d %s\n", int($1/60), $1%60, $1, pad }' > "$T/logs/pipeline-health.log"
OUT=$(fl hub pipeline s1 hit)
MB=$(jq -r .matched_bytes <<<"$OUT"); RB=$(jq -r .returned_bytes <<<"$OUT")
[ "${#OUT}" -le 98304 ] && [ "$MB" = "$(wc -c < "$T/logs/pipeline-health.log")" ] && [ "$(jq -r .omitted_bytes <<<"$OUT")" = $((MB - RB)) ] \
  && ok || bad "S1: a 300 KB result fits 98304 with omitted = matched - returned (got $(jq -c '[.matched_bytes,.returned_bytes,.omitted_bytes]' <<<"$OUT") len ${#OUT})"
[ "$(jq -r .omitted_lines <<<"$OUT")" = $((300 - $(jq -r .returned_lines <<<"$OUT"))) ] && [ "$(jq -r .truncated <<<"$OUT")" = true ] \
  && ok || bad "S2: omitted_lines = matched_lines - returned_lines, truncated true"
[ "$(jq -r .more.match <<<"$OUT")" = hit ] && [ "$(jq -r .more.which <<<"$OUT")" = pipeline ] && [ "$(jq -r .more.project <<<"$OUT")" = hub ] \
  && ok || bad "S2: the more call keeps the match, which and project"
OUT=$(FETCH_LOG_RESPONSE_BYTES=20000 fl hub pipeline s2b hit)
[ "${#OUT}" -le 20000 ] && [ "${#OUT}" -gt 15000 ] && [ "$(jq -r .response_max_bytes <<<"$OUT")" = 20000 ] \
  && ok || bad "S2b: the response knob sets the beat size (len ${#OUT})"
# S3: the window applies to the filtered result.
awk 'BEGIN{ pad=sprintf("%0990d",0); for (i=0;i<2100;i++) printf "2026-11-25 %02d:%02d:%02dZ keep%04d %s\nnoise %s\n", 8+int(i/3600), int(i/60)%60, i%60, i, pad, pad }' > "$T/logs/pipeline-health.log"
OUT=$(FETCH_LOG_TAIL_BYTES=1048576 fl hub pipeline s3 keep)
[ "$(jq -r .matched_bytes <<<"$OUT")" -gt 2000000 ] && [ "$(jq -r .window_bytes <<<"$OUT")" -le 1048576 ] \
  && [ "$(jq -r .window_bytes <<<"$OUT")" -gt 1040000 ] && [ "$(jq -j .content <<<"$OUT" | tail -1 | awk '{print $3}')" = keep2099 ] \
  && ok || bad "S3: a 2 MB match set keeps the newest 1 MiB (got $(jq -c '[.matched_bytes,.window_bytes]' <<<"$OUT"))"
# S4: one line larger than the budget is shipped as its last bytes.
{ printf '2026-11-25 10:00:00Z small\n'; printf '2026-11-25 10:00:01Z '; head -c 200000 /dev/zero | tr '\0' 'z'; printf 'END\n'; } > "$T/logs/pipeline-health.log"
OUT=$(fl hub pipeline s4)
[ "$(jq -r .line_cut <<<"$OUT")" = true ] && [ "${#OUT}" -le 98304 ] && grep -q 'zzzEND$' <<<"$(jq -j .content <<<"$OUT" | tail -1)" \
  && ok || bad "S4: a 200 KB newest line is cut to its last bytes with line_cut true (len ${#OUT})"

# ── missing file, no timestamps ─────────────────────────────────────────────
rm -f "$T/logs/cost.csv"
OUT=$(fl hub cost e0 x 6h); RC=$?
[ "$RC" = 0 ] && [ "$(jq -r .missing <<<"$OUT")" = true ] && [ "$(jq -j .content <<<"$OUT")" = "" ] && [ "$(jq -r .truncated <<<"$OUT")" = false ] \
  && ok || bad "missing log with a filter is empty+missing, rc 0"
seq 1 30000 | sed 's/^/plain line with no stamp /' > "$T/logs/cost.csv"
OUT=$(fl hub cost nots)
[ "$(jq -r .more.until <<<"$OUT")" = null ] && grep -q 'no timestamp' <<<"$(jq -r .more.note <<<"$OUT")" && [ "$(jq -r .truncated <<<"$OUT")" = true ] \
  && ok || bad "a log with no stamps says the left-out part cannot be addressed by time (got $(jq -c .more <<<"$OUT"))"

# ── P1: the production entry point, bcx_run ────────────────────────────────
mkdir -p "$T/bin"
cp "$DIR/bin/fetch-log.sh" "$DIR/bin/fleet-conf.sh" "$T/bin/"
printf '2026-11-25 09:00:00Z RUNNER_EXHAUSTED one\n2026-11-25 09:01:00Z other\n2026-11-25 09:02:00Z RUNNER_EXHAUSTED two\n' > "$T/logs/ALERTS.log"
. "$DIR/bin/lib/box-cmd-exec.sh" || exit 1
bcx_run fetch_log hub '{"project":"hub","which":"alerts","match":"RUNNER_EXHAUSTED"}' p1
[ "$BCX_OK" = 1 ] && [ "$(jq -j .content <<<"$BCX_BODY")" = "$(printf '2026-11-25 09:00:00Z RUNNER_EXHAUSTED one\n2026-11-25 09:02:00Z RUNNER_EXHAUSTED two')" ] \
  && ok || bad "P1: bcx_run fetch_log with match returns only matching lines (ok=$BCX_OK body=$BCX_BODY)"
bcx_run fetch_log hub '{"which":"alerts","since":"2026-11-25T09:01:00","until":"2026-11-25T09:02:00"}' p1b
[ "$(jq -j .content <<<"$BCX_BODY")" = "2026-11-25 09:01:00Z other" ] && ok || bad "P1b: bcx_run passes since and until (body=$BCX_BODY)"
bcx_run fetch_log hub '{"which":"alerts","match":null}' p1c
[ "$BCX_OK" = 1 ] && [ "$(jq -r .filter.match <<<"$BCX_BODY")" = null ] && [ "$(jq -j .content <<<"$BCX_BODY" | grep -c .)" = 3 ] \
  && ok || bad "P1c: a null match is no filter"
bcx_run fetch_log hub '{"which":"alerts","since":"$(id)"}' p1d
[ "$BCX_OK" = 1 ] && [ "$(jq -r .error <<<"$BCX_BODY")" = bad_since ] && ok || bad "P1d: a bad since through bcx_run is the bad_since envelope (body=$BCX_BODY)"

# ── E1: no temp file is left behind ─────────────────────────────────────────
# (harness-lanes-<uid> is the lane registry's own stamp cache, not a temp file.)
LEFT=$(ls -A "$T/tmpd" | grep -v '^harness-lanes-')
[ -z "$LEFT" ] && ok || bad "E1: temp files left behind: $(tr '\n' ' ' <<<"$LEFT")"

echo "fetch-log-filter: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
