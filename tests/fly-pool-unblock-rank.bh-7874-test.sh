#!/bin/bash
# tests/fly-pool-unblock-rank.bh-7874-test.sh — the pool builds first the
# tickets that unblock the most open work (BH-7874).
#
# 2026-10-21: example-org/project-6 had 201 open ai-build tickets. TK-1219 alone
# blocked 17 of them, but hotfix_first walked the plain rows in age order, so
# TK-1219 waited behind 60 older leaf rows. bin/lib/pool-unblock-rank.sh counts,
# per ticket, the open issues that name it in a Blocked-by:/Needs: line,
# directly or through a chain, and hotfix_first orders its last group by it.
#
#   U1  counts of the six-ticket fixture: A=3 B=1, the rest 0
#   U2  a cycle (A<->B) ends and counts both
#   U3  a 1,000-issue listing ranks in < 5 s with the right hub count
#   U4  parity of pur_edges with te_edges_from_text over 12 body shapes
#   U5  near misses, a pull request row and a self-edge give no edge
#   P1  pur_prime reads 3 pages for 250 issues; hotfix_first reads none
#   P2  an unreadable page: PUR_FILE empty, one `off (...)` line, age order
#   P3  POOL_UNBLOCK_RANK=0: 0 reads, age order
#   P4  one rankable row: 0 reads
#   O1  F (hot), A, B, then C, D, E by age (the REPRO; red before BH-7874)
#   O2  equal counts keep age order
#   O3  RB/RR and dispatch-now rows stay ahead of a count-17 row
#   O4  no pur_order: the pre-change hotfix_first output, byte for byte
#   O5  a corrupt job file: every input file printed exactly once
#   L1  the log line names the top keys with counts
#   L2  the `pool <p>:` tick line is untouched
#   W1  bin/fly-pool.sh sources the lib and primes once, before the REAP
#   S1  the rank and the hold cache share one listing page per tick
#
# No case calls GitHub: pool_rest_read is a stub, and a `gh` on PATH logs any
# call and fails. G1 asserts that log is empty.
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

. "$(dirname "$0")/lib/scratch.sh" || exit 1
LIB="$DIR/bin/lib/pool-unblock-rank.sh"
[ -r "$LIB" ] && ok || bad "bin/lib/pool-unblock-rank.sh is missing"

# The three ordering helpers, verbatim from the pool script, as the sibling
# suites cut them.
FN="$T/fn.sh"
sed -n '/^job_is_hot() {/,/^}/p; /^job_is_now() {/,/^}/p; /^hotfix_first() {/,/^}/p' "$DIR/bin/fly-pool.sh" > "$FN"
[ "$(grep -c '() {' "$FN")" = 3 ] && ok || bad "could not extract the three helpers from bin/fly-pool.sh"

# A gh that must never run.
mkdir -p "$T/bin"
printf '#!/bin/bash\necho "gh $*" >> "%s/gh-calls.log"\nexit 1\n' "$T" > "$T/bin/gh"
chmod +x "$T/bin/gh"
: > "$T/gh-calls.log"
export PATH="$T/bin:$PATH"

# issue <n> <body> — one listing row.
issue() { jq -nc --argjson n "$1" --arg b "$2" '{number:$n, body:$b}'; }
listing() { jq -sc '.'; }   # rows on stdin -> one JSON array

# The six-ticket fixture: A=#1 blocks #2 (B) and #3 (C); B blocks #4 (D);
# E=#5 blocks nothing; F=#6 is the hotfix.
SIX=$( { issue 1 "Build A"; issue 2 "Blocked-by: #1"; issue 3 "**Blocked-by:** #1"
         issue 4 "Blocked by #2"; issue 5 "Leaf E"; issue 6 "Hot F"; } | listing)

lib_run() { # lib_run <script> — bash with the lib and the helpers sourced
  bash -c '. "$1" 2>/dev/null; . "$2"; shift 2; eval "$1"' _ "$LIB" "$FN" "$1"
}

echo "--- U1: counts of the six-ticket fixture"
OUT=$(printf '%s' "$SIX" | lib_run 'pur_edges | pur_counts')
[ "$OUT" = "$(printf '1\t3\n2\t1')" ] && ok || bad "U1 counts: '$OUT'"

echo "--- U2: a cycle ends and counts both"
CYC=$( { issue 1 "Blocked-by: #2"; issue 2 "Blocked-by: #1"; } | listing)
OUT=$(printf '%s' "$CYC" | timeout 5 bash -c '. "$1" 2>/dev/null; pur_edges | pur_counts' _ "$LIB"); RC=$?
[ "$RC" = 0 ] && ok || bad "U2 rc $RC"
[ "$OUT" = "$(printf '1\t1\n2\t1')" ] && ok || bad "U2 counts: '$OUT'"

echo "--- U3: 1,000 issues rank in < 5 s"
# Issues 1-999 in chains of 10 (k is blocked by k-1 inside its chain). Issue
# 1000 is the hub: every chain head and 100 more issues name it, 200 in all.
jq -nc '[range(1;1001) | . as $k |
  {number:$k, body:(
    if $k == 1000 then "hub"
    elif ($k % 10) == 1 then "Blocked-by: #1000"
    elif ($k % 10) == 2 then "Blocked-by: #\($k - 1)\nNeeds: #1000 first"
    else "Blocked-by: #\($k - 1)" end)}]' > "$T/u3.json"
T0=$(date +%s%N)
OUT=$(lib_run 'pur_edges | pur_counts' < "$T/u3.json")
T1=$(date +%s%N); MS=$(( (T1 - T0) / 1000000 ))
[ "$MS" -lt 5000 ] && ok || bad "U3 took ${MS} ms"
echo "U3: 1000 issues ranked in ${MS} ms"
[ "$(awk -F'\t' '$1==1000 {print $2}' <<<"$OUT")" = 999 ] && ok || bad "U3 hub count: $(head -3 <<<"$OUT")"
[ "$(awk -F'\t' '$1==1 {print $2}' <<<"$OUT")" = 9 ] && ok || bad "U3 chain head #1 count: $(awk -F'\t' '$1==1' <<<"$OUT")"
[ "$(head -1 <<<"$OUT" | cut -f1)" = 1000 ] && ok || bad "U3 the hub does not rank first"

echo "--- U4: parity with te_edges_from_text"
# shellcheck source=bin/lib/ticket-edges.sh
. "$DIR/bin/lib/ticket-edges.sh" 2>/dev/null || bad "U4 cannot source bin/lib/ticket-edges.sh"
BODIES=(
  "Blocked-by: #12"
  "**Blocked-by:** #12, #13 (hard)"
  "> blocked by #12"
  "- Needs: #12 and #14"
  "BLOCKED-BY: #12"
  $'Blocked-by: #12\r'
  "Not blocked by #12"
  "Blocked-byline #12"
  "Needsmore #12"
  "See #12"
  "Blocked-by: TK-1219"
  $'intro text\n## Blocked-by: #21 #22\n* needs #23 then #24\nnothing #25'
)
i=0
for b in "${BODIES[@]}"; do
  i=$((i + 1))
  printf '%s\n' "$b" > "$T/u4-$i.md"
  WANT=$(te_edges_from_text "$T/u4-$i.md" 900 | cut -f1 | sort -n | tr '\n' ' ')
  GOT=$(issue 900 "$b" | listing | lib_run 'pur_edges' | cut -f2 | sort -n | tr '\n' ' ')
  [ "$GOT" = "$WANT" ] && ok || bad "U4 body $i '$b': pur_edges '$GOT' te '$WANT'"
done

echo "--- U5: near misses, a PR row and a self-edge give no edge"
for b in "Not blocked by #12" "Blocked-byline #12" "Needsmore #12" "See #12" \
         "DEPENDS: #12 soft" "Blocked-by: TK-1219" "Blocked-by: #900"; do
  GOT=$(issue 900 "$b" | listing | lib_run 'pur_edges')
  [ -z "$GOT" ] && ok || bad "U5 '$b' gave an edge: '$GOT'"
done
GOT=$(jq -nc '[{number:901, body:"Blocked-by: #12", pull_request:{url:"x"}}]' | lib_run 'pur_edges')
[ -z "$GOT" ] && ok || bad "U5 a pull request row gave an edge: '$GOT'"
GOT=$(issue 902 $'Blocked-by: #12\r' | listing | lib_run 'pur_edges')
[ "$GOT" = "$(printf '902\t12')" ] && ok || bad "U5 a CRLF body: '$GOT'"

# ---- pool fixtures -------------------------------------------------------
# mkpool <case> — a harness tree with the six queued job files, mtimes in the
# age order B < D < C < A < E < F (F is hot, so its age does not matter).
mkpool() {
  local c="$1" k n age
  H="$T/$c/h"; Q="$H/state/build-queue/tproj"
  mkdir -p "$Q" "$H/state/pool/tproj" "$H/state/dispatch-now/tproj" "$H/logs"
  age=1000
  for k in B:2 D:4 C:3 A:1 E:5 F:6; do
    n=${k#*:}; k=${k%%:*}
    if [ "$k" = F ]; then
      printf '{"project":"tproj","ticket_id":"%s","key":"%s","hotfix": true}\n' "$n" "$k" > "$Q/$k.json"
    else
      printf '{"project":"tproj","ticket_id":"%s","key":"%s"}\n' "$n" "$k" > "$Q/$k.json"
    fi
    touch -d "@$age" "$Q/$k.json"; age=$((age + 10))
  done
}
# pool_run <case-dir> <script> — the pool's tick shell, cut down: say, the
# stub REST read, and the knobs from the environment.
pool_run() {
  HARNESS="$H" P=tproj HOTFIX_ON=1 QDIR="$Q" PDIR="$H/state/pool/tproj" LOG="$H/logs/fly-pool.log" \
  POOL_SLUG="example-org/fixture" STUB="$T/$1/pages" CALLS="$T/$1/calls.log" \
  bash -c '
    . "$1" 2>/dev/null; . "$2"; shift 2
    say() { echo "[pool/$P] $*" >> "$LOG"; }
    pool_slug_token_arm() { return 0; }
    pool_rest_read() { # answers from $STUB/<page>.code and $STUB/<page>.json
      local pg; echo "$1" >> "$CALLS"
      pg=$(sed -n "s/.*[?&]page=\([0-9]*\).*/\1/p" <<<"$1")
      printf "%s\n" "$(cat "$STUB/$pg.code" 2>/dev/null || echo 404)"
      cat "$STUB/$pg.json" 2>/dev/null
    }
    eval "$1"' _ "$LIB" "$FN" "$2"
}
age_list() { ls -tr "$Q"/*.json; }
names() { xargs -n1 basename | sed 's/\.json$//' | tr '\n' ' '; }
page() { # page <case> <n> <code> — page n answers <code> with stdin as body
  mkdir -p "$T/$1/pages"; echo "$3" > "$T/$1/pages/$2.code"; cat > "$T/$1/pages/$2.json"
}

echo "--- O1: F, A, B, then C, D, E by age (REPRO)"
mkpool o1; printf '%s' "$SIX" | page o1 1 200
OUT=$(pool_run o1 'pur_prime; hotfix_first $(ls -tr "$QDIR"/*.json)' | names)
[ "$OUT" = "F A B D C E " ] && ok || bad "O1 order: '$OUT' (want F A B D C E: rank, then age B<D<C<A<E)"
echo "O1: $OUT"

echo "--- L1/L2: the log line"
grep -qE '\[pool/tproj\] unblock rank tproj: issues=6 pages=1 read=[0-9.]+s rank=[0-9.]+s listing=ok top5: A=3 B=1$' "$H/logs/fly-pool.log" \
  && ok || bad "L1 log: $(cat "$H/logs/fly-pool.log" 2>/dev/null)"
[ "$(grep -E 'pool tproj:' "$H/logs/fly-pool.log" | grep -c unblock)" = 0 ] && ok || bad "L2 a pool tick line names unblock"

echo "--- P1: 3 pages for 250 issues, then no read from hotfix_first"
mkpool p1
jq -nc '[range(1;101) | {number:(. + 100), body:"Blocked-by: #1"}]' | page p1 1 200
jq -nc '[range(1;101) | {number:(. + 200), body:"Blocked-by: #2"}]' | page p1 2 200
jq -nc '[range(1;51)  | {number:(. + 300), body:"Blocked-by: #3"}]' | page p1 3 200
OUT=$(pool_run p1 'pur_prime; echo "file=$PUR_FILE" >&2; : > "$CALLS.after"; cp "$CALLS" "$CALLS.prime"
  hotfix_first $(ls -tr "$QDIR"/*.json) >/dev/null; hotfix_first $(ls -tr "$QDIR"/*.json)' 2>"$T/p1.err" | names)
[ "$(wc -l < "$T/p1/calls.log.prime")" = 3 ] && ok || bad "P1 prime reads: $(cat "$T/p1/calls.log.prime")"
[ "$(wc -l < "$T/p1/calls.log")" = 3 ] && ok || bad "P1 hotfix_first made reads: $(cat "$T/p1/calls.log")"
! grep -qv '^repos/example-org/fixture/issues?state=open&labels=ai-build&per_page=100&page=[123]$' "$T/p1/calls.log" \
  && ok || bad "P1 a read outside the repo's listing: $(cat "$T/p1/calls.log")"
[ -s "$H/state/pool/tproj/unblock-rank.tsv" ] && ok || bad "P1 no unblock-rank.tsv"
grep -q "file=$H/state/pool/tproj/unblock-rank.tsv" "$T/p1.err" && ok || bad "P1 PUR_FILE: $(cat "$T/p1.err")"
# A=#1 has 100 waiting, B=#2 100, C=#3 50: A, B (age B before A), C.
[ "$OUT" = "F B A C D E " ] && ok || bad "P1 order: '$OUT'"
grep -q 'issues=250 pages=3 .* top5: B=100 A=100 C=50$' "$H/logs/fly-pool.log" && ok || bad "P1 log: $(cat "$H/logs/fly-pool.log")"

echo "--- P2: page 2 answers 502"
mkpool p2
jq -nc '[range(1;101) | {number:(. + 100), body:"Blocked-by: #5"}]' | page p2 1 200
echo '{"message":"bad gateway"}' | page p2 2 502
# A cache from an older tick must not be used.
printf '5\t99\n' > "$H/state/pool/tproj/unblock-rank.tsv"
OUT=$(pool_run p2 'pur_prime; echo "file=[$PUR_FILE]" >&2; hotfix_first $(ls -tr "$QDIR"/*.json)' 2>"$T/p2.err" | names)
grep -q 'file=\[\]' "$T/p2.err" && ok || bad "P2 PUR_FILE: $(cat "$T/p2.err")"
grep -q 'unblock rank tproj: off (listing unreadable: 502)' "$H/logs/fly-pool.log" && ok || bad "P2 log: $(cat "$H/logs/fly-pool.log")"
[ "$OUT" = "F B D C A E " ] && ok || bad "P2 order is not age order: '$OUT'"
echo 'not json' | page p2 2 200
: > "$H/logs/fly-pool.log"
OUT=$(pool_run p2 'pur_prime; hotfix_first $(ls -tr "$QDIR"/*.json)' | names)
grep -q 'unblock rank tproj: off (listing unreadable: body)' "$H/logs/fly-pool.log" && ok || bad "P2 bad body log: $(cat "$H/logs/fly-pool.log")"
[ "$OUT" = "F B D C A E " ] && ok || bad "P2 bad body order: '$OUT'"

echo "--- P3: POOL_UNBLOCK_RANK=0"
mkpool p3; printf '%s' "$SIX" | page p3 1 200
OUT=$(POOL_UNBLOCK_RANK=0 pool_run p3 'pur_prime; hotfix_first $(ls -tr "$QDIR"/*.json)' | names)
[ ! -s "$T/p3/calls.log" ] && ok || bad "P3 reads with the knob off: $(cat "$T/p3/calls.log")"
[ "$OUT" = "F B D C A E " ] && ok || bad "P3 order: '$OUT'"
OUT=$(POOL_UNBLOCK_RANK=yes pool_run p3 'pur_prime; hotfix_first $(ls -tr "$QDIR"/*.json)' | names)
grep -q 'POOL_UNBLOCK_RANK=yes is not 0 or 1 — using 1' "$H/logs/fly-pool.log" && ok || bad "P3 bad knob line: $(cat "$H/logs/fly-pool.log")"
[ "$OUT" = "F A B D C E " ] && ok || bad "P3 bad knob falls back to on: '$OUT'"

echo "--- P4: one rankable row"
mkpool p4; printf '%s' "$SIX" | page p4 1 200
rm -f "$Q"/[BCDE].json
printf '{"key":"RB-9-fixture","ticket_id":"9"}\n' > "$Q/RB-9-fixture.json"
printf '{"key":"A","ticket_id":"1"}\n' > "$Q/A.failed.json"
OUT=$(pool_run p4 'pur_prime; echo "file=[$PUR_FILE]" >&2' 2>"$T/p4.err")
[ ! -s "$T/p4/calls.log" ] && ok || bad "P4 reads with one rankable row: $(cat "$T/p4/calls.log")"
grep -q 'file=\[\]' "$T/p4.err" && ok || bad "P4 PUR_FILE: $(cat "$T/p4.err")"

echo "--- O2: equal counts keep age order"
mkpool o2
{ issue 1 "x"; issue 2 "x"; issue 3 "x"; issue 4 "x"; issue 5 "x"; issue 6 "x"
  issue 11 "Blocked-by: #3"; issue 12 "Blocked-by: #3"; issue 13 "Blocked-by: #5"; issue 14 "Blocked-by: #5"; } | listing | page o2 1 200
OUT=$(pool_run o2 'pur_prime; hotfix_first $(ls -tr "$QDIR"/*.json)' | names)
# C=#3 and E=#5 both count 2; C is older than E.
[ "$OUT" = "F C E B D A " ] && ok || bad "O2 order: '$OUT'"

echo "--- O3: RB/RR and dispatch-now rows stay ahead of a count-17 row"
mkpool o3
jq -nc '[range(1;18) | {number:(. + 100), body:"Blocked-by: #5"}]' | page o3 1 200
printf '{"key":"RB-9-fixture"}\n' > "$Q/RB-9-fixture.json"
printf '{"key":"RR-8-fixture"}\n' > "$Q/RR-8-fixture.json"
touch -d @2000 "$Q/RB-9-fixture.json"; touch -d @2010 "$Q/RR-8-fixture.json"
touch "$H/state/dispatch-now/tproj/D"
OUT=$(pool_run o3 'pur_prime; hotfix_first $(ls -tr "$QDIR"/*.json)' | names)
[ "$OUT" = "F RB-9-fixture RR-8-fixture D E B C A " ] && ok || bad "O3 order: '$OUT'"

echo "--- O4: no pur_order is the pre-change order, byte for byte"
# The pre-change helpers, copied from bin/fly-pool.sh at 3b1153e2 (comments
# dropped). A fixed copy, never origin/main: main moves (D60).
OLD="$T/old.sh"
cat > "$OLD" <<'EOF'
job_is_hot() {
  [ "$HOTFIX_ON" = 1 ] || return 1
  grep -q '"hotfix": *true' "${1:-/dev/null}" 2>/dev/null
}
job_is_now() {
  local k
  k=$(basename "${1:-}" .json)
  [ -n "$k" ] && [ -e "$HARNESS/state/dispatch-now/$P/$k" ]
}
hotfix_first() {
  local f
  for f in "$@"; do job_is_hot "$f" && printf '%s\n' "$f"; done
  for f in "$@"; do case "${f##*/}" in RB-*|RR-*) job_is_hot "$f" || printf '%s\n' "$f" ;; esac; done
  for f in "$@"; do case "${f##*/}" in RB-*|RR-*) continue ;; esac; job_is_hot "$f" || ! job_is_now "$f" || printf '%s\n' "$f"; done
  for f in "$@"; do case "${f##*/}" in RB-*|RR-*) continue ;; esac; job_is_hot "$f" || job_is_now "$f" || printf '%s\n' "$f"; done
}
EOF
WANT=$(HARNESS="$H" P=tproj HOTFIX_ON=1 bash -c '. "$1"; shift; hotfix_first "$@"' _ "$OLD" $(age_list) | od -c)
GOT=$(HARNESS="$H" P=tproj HOTFIX_ON=1 PUR_FILE="$H/state/pool/tproj/unblock-rank.tsv" \
  bash -c '. "$1" 2>/dev/null; . "$2"; unset -f pur_order; shift 2; hotfix_first "$@"' _ "$LIB" "$FN" $(age_list) | od -c)
[ "$GOT" = "$WANT" ] && ok || bad "O4 output differs from the pre-change function"
GOT=$(HARNESS="$H" P=tproj HOTFIX_ON=1 bash -c '. "$1"; shift; hotfix_first "$@"' _ "$FN" | wc -c)
[ "$GOT" = 0 ] && ok || bad "O4 no input printed '$GOT'"

echo "--- O5: a corrupt job file is printed exactly once"
mkpool o5; printf '%s' "$SIX" | page o5 1 200
echo 'not json {' > "$Q/C.json"; touch -d @1020 "$Q/C.json"
OUT=$(pool_run o5 'pur_prime; hotfix_first $(ls -tr "$QDIR"/*.json)' | names)
[ "$OUT" = "F A B D C E " ] && ok || bad "O5 order: '$OUT'"
OUT=$(pool_run o5 'pur_prime; hotfix_first $(ls -tr "$QDIR"/*.json) "$QDIR/gone.json"' | names)
[ "$OUT" = "F A B D C E gone " ] && ok || bad "O5 a missing file: '$OUT'"
# A counts file that is not ours: the input order, every file once.
printf 'garbage\n\n\t\n' > "$T/bad.tsv"
OUT=$(PUR_FILE="$T/bad.tsv" pool_run o5 'hotfix_first $(ls -tr "$QDIR"/*.json)' | names)
[ "$OUT" = "F B D C A E " ] && ok || bad "O5 a garbage counts file: '$OUT'"

echo "--- W1: the pool script wires the lib in"
grep -q 'lib/pool-unblock-rank.sh' "$DIR/bin/fly-pool.sh" && ok || bad "W1 bin/fly-pool.sh does not source the lib"
[ "$(grep -c '^command -v pur_prime ' "$DIR/bin/fly-pool.sh")" = 1 ] && ok || bad "W1 pur_prime is not called exactly once"
awk '/^command -v pur_prime / {p = NR} /^# ---------- REAP ----------$/ {r = NR} END {exit !(p && r && p < r)}' "$DIR/bin/fly-pool.sh" \
  && ok || bad "W1 pur_prime does not run before the REAP"
bash -n "$DIR/bin/fly-pool.sh" && bash -n "$LIB" && ok || bad "W1 bash -n"

echo "--- S1: the rank and the hold cache share one listing"
mkpool s1; printf '%s' "$SIX" | page s1 1 200
sed -n '/^declare -A _POOL_AI_LIST_PAGE=/p; /^pool_ai_listing_page() {/,/^}/p' "$DIR/bin/fly-pool.sh" > "$T/pal.sh"
[ "$(grep -c '^pool_ai_listing_page() {' "$T/pal.sh")" = 1 ] && ok || bad "S1 could not extract pool_ai_listing_page"
OUT=$(pool_run s1 '. '"$T/pal.sh"'; pur_prime; pool_ai_listing_page 1; echo "${_PAL_OUT%%$'"'"'\n'"'"'*}"' 2>&1)
[ "$OUT" = 200 ] && ok || bad "S1 the kept page: '$OUT'"
[ "$(wc -l < "$T/s1/calls.log")" = 1 ] && ok || bad "S1 two reads of page 1: $(cat "$T/s1/calls.log")"
grep -q 'top5: A=3 B=1$' "$H/logs/fly-pool.log" && ok || bad "S1 rank through the shared reader: $(cat "$H/logs/fly-pool.log")"
# A failed page is not kept: the next reader asks again.
mkpool s2; echo '{}' | page s2 1 502
OUT=$(pool_run s2 '. '"$T/pal.sh"'; pur_prime; pool_ai_listing_page 1; echo "${_PAL_OUT%%$'"'"'\n'"'"'*}"' 2>&1)
[ "$(wc -l < "$T/s2/calls.log")" = 2 ] && ok || bad "S1 a 502 page was kept: $(cat "$T/s2/calls.log")"

echo "--- G1: no case called gh"
[ ! -s "$T/gh-calls.log" ] && ok || bad "G1 gh was called: $(cat "$T/gh-calls.log")"

echo "fly-pool-unblock-rank: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
