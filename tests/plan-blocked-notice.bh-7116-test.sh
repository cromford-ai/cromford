#!/bin/bash
# tests/plan-blocked-notice.bh-7116-test.sh — BH-7116 part 1: a pool build that
# ends PLAN_BLOCKED posts the plan's blocked section on the ticket before the
# machine is reaped, and the hub's build record gets plan.md from the ledger
# when the machine is already gone.
#
# On 2026-10-16 eight tickets went PLAN_BLOCKED 2-4 times each and no reason
# reached any of them: plan.md lived only on the reaped pool machine, and
# bin/board-closeout.sh refuses every non-PR result.
#
#   E1-E5  pb_excerpt: the three section shapes, the 40-line / 3000-byte cap,
#          and no scrubber -> nothing (fail closed)
#   N1-N9  pb_notice: one POST with the quoted reason and the builder-direct
#          marker on the RESULT; the negatives; the dedup token; a failed POST
#          leaves no marker; the marked line through bin/lib/rt/staging.sh
#   W1-W3  the `plan-blocked notice` region of bin/lib/rb/gates.sh, extracted
#          by its markers and run inside a function as _job_finish runs it
#   H1-H5  pb_hub_copy: the row-sourced hub dir gets plan.md from the ledger
#
# Run from anywhere (exit 0 = pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$H/logs" "$H/state" "$H/builds" "$H/flags" "$T/fakebin" "$T/srv"
export HARNESS="$H" FLEET_CONF="$DIR/fleet.conf"
for L in bin/lib/plan-blocked.sh bin/transcript-scrub.sh bin/fleet-conf.sh bin/jobs-client.sh; do
  [ -f "$DIR/$L" ] || { bad "setup: $L is not in the tree"; continue; }
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
for L in $(cd "$DIR" && printf '%s ' bin/lib/jobs/*.sh); do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
printf 'HARNESS_SECRET=fixture-secret-7116\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"

# gh: the REST wire shape bin/lib/gh-rest.sh reads. Every call is recorded; a
# comment POST also keeps its body (it travels by file, -F body=@<file>).
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
case "$*" in
  *"-X POST repos/"*"/issues/"*"/comments"*)
    f=""; prev=""
    for a in "$@"; do [ "$prev" = -F ] && case "$a" in body=@*) f="${a#body=@}" ;; esac; prev="$a"; done
    n=$(grep -c . "$POST_SINK" 2>/dev/null); n=$(( ${n:-0} + 1 ))
    cp "$f" "$POST_DIR/post-$n.txt" 2>/dev/null
    printf '%s\n' "$*" >> "$POST_SINK"
    st="${GH_POST_STATUS:-201}"
    printf 'HTTP/2.0 %s X\r\nx-stub: 1\r\n\r\n{"id":%s}\n' "$st" "$n"
    case "$st" in 2*) exit 0 ;; *) exit 1 ;; esac ;;
  *"-X GET repos/"*"/issues/"*"/comments"*)
    # The thread pb_notice reads before a second notice (BH-7719).
    printf 'HTTP/2.0 200 X\r\nx-stub: 1\r\n\r\n%s\n' "$(cat "$SRV/thread.json" 2>/dev/null || echo '[]')"
    exit 0 ;;
esac
exit 1
SH
# curl: the jobs worker. A tiny ledger store (so the comment-mark ROW path is
# real), the artifact feed and the transcript index + body pb_hub_copy reads.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"; M=GET; BODY=""; prev=""
for a in "$@"; do
  [ "$prev" = -X ] && M="$a"
  [ "$prev" = --data-binary ] && BODY="$a"
  prev="$a"
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}" 2>/dev/null) ;; esac
printf '%s %s\n' "$M" "$URL" >> "$SRV/req.log"
case "$M $URL" in
  "PUT "*/api/ledger)
    k=$(printf '%s' "$BODY" | jq -r '"kind="+(.kind|@uri)+"&key="+(.key|@uri)')
    grep -vF "$k	" "$SRV/ledger.tsv" > "$SRV/ledger.tmp" 2>/dev/null; mv -f "$SRV/ledger.tmp" "$SRV/ledger.tsv"
    printf '%s\t%s\n' "$k" "$(printf '%s' "$BODY" | jq -c '{status, detail: (.detail // "")}')" >> "$SRV/ledger.tsv"
    printf '{"ok":true}\n200' ;;
  "GET "*/api/ledger\?*)
    q="${URL#*\?}"; row=$(grep -F "$q	" "$SRV/ledger.tsv" 2>/dev/null | head -1 | cut -f2)
    if [ -n "$row" ]; then printf '{"ledger":%s}\n200' "$row"; else printf '{"error":"no row"}\n404'; fi ;;
  "GET "*/api/artifacts\?*)  printf '%s\n200' "$(cat "$SRV/feed.json" 2>/dev/null || echo '{"artifacts":[]}')" ;;
  "GET "*/transcripts)       printf '%s\n200' "$(cat "$SRV/transcripts.json" 2>/dev/null || echo '{"transcripts":[]}')" ;;
  "GET "*/transcript\?*)     printf '%s\n200' "$(cat "$SRV/transcript.json" 2>/dev/null || echo '{}')" ;;
  *) printf '{"ok":true}\n200' ;;
esac
SH
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH" GH_SINK="$T/gh.log" POST_SINK="$T/posts.log" POST_DIR="$T" SRV="$T/srv"
# No live token file on this box: gh_token_live must answer "none" and leave the env alone.
export GH_TOKEN_LIVE_FILE="$T/no-such-token"
unset GH_TOKEN 2>/dev/null

LOADED=0
# shellcheck source=/dev/null
. "$H/bin/jobs-client.sh" 2>/dev/null
# shellcheck source=bin/lib/plan-blocked.sh
. "$H/bin/lib/plan-blocked.sh" 2>/dev/null && command -v pb_excerpt >/dev/null 2>&1 && LOADED=1
[ "$LOADED" = 1 ] && ok || bad "bin/lib/plan-blocked.sh does not load or defines no pb_excerpt"

nposts() { local n; n=$(grep -c . "$POST_SINK" 2>/dev/null); echo "${n:-0}"; }
P=cromford; K=BH-7116
B="$H/builds/$P-$K-202610161918"
seed() { # seed <result-line> <plan-text>
  scratch_rm "$B"; mkdir -p "$B"
  printf '%s\nBUILD_DIR: %s\n' "$1" "$B" > "$B/RESULT"
  printf '%s' "$2" > "$B/plan.md"
}
reset_all() { : > "$POST_SINK"; : > "$GH_SINK"; : > "$SRV/ledger.tsv"; scratch_rm "$H/state"; mkdir -p "$H/state"; }

# ══ E: pb_excerpt ═══════════════════════════════════════════════════════════
printf 'BLOCKED: which column holds the fee?\nThe ticket names two fee fields.\nThe thread does not say which one.\n\n## Scope\nScope text that must not show.\n' > "$T/e1.md"
E=$(pb_excerpt "$T/e1.md" 2>/dev/null)
[ "$(printf '%s\n' "$E" | grep -c .)" = 3 ] && ok || bad "E1: the excerpt is the 3 reason lines, got: [$E]"
grep -q '^which column holds the fee?$' <<<"$E" && ok || bad "E1: the marker is cut off line 1: [$E]"
grep -q 'Scope' <<<"$E" && bad "E1: the excerpt stops at the first ## heading: [$E]" || ok

printf 'BLOCKED-NEEDS-CLARIFICATION\n\n## Scope\nScope words.\n\n## Open questions\n- Q1: does the rep set the fee?\n- Q2: is the fee per client?\n\n## Tasks\nTask words.\n' > "$T/e2.md"
E=$(pb_excerpt "$T/e2.md" 2>/dev/null)
grep -q 'Q1: does the rep set the fee?' <<<"$E" && grep -q 'Q2: is the fee per client?' <<<"$E" && ok \
  || bad "E2: the Open questions section is the excerpt: [$E]"
grep -qE 'Scope words|Task words' <<<"$E" && bad "E2: only that section: [$E]" || ok

printf '# **BLOCKED**\n\nThe plan cannot start: the spec repo is not readable.\nAsk for access first.\n' > "$T/e3.md"
E=$(pb_excerpt "$T/e3.md" 2>/dev/null)
[ "$(head -1 <<<"$E")" = "The plan cannot start: the spec repo is not readable." ] && ok \
  || bad "E3: the top of the plan, marker-only line and leading blank dropped: [$E]"
grep -q 'BLOCKED' <<<"$E" && bad "E3: the marker-only line is dropped: [$E]" || ok

{ printf 'BLOCKED: a long one\n'; for i in $(seq 1 59); do printf 'line %02d %s\n' "$i" "$(printf 'x%.0s' $(seq 1 90))"; done; } > "$T/e4.md"
E=$(pb_excerpt "$T/e4.md" 2>/dev/null)
EL=$(printf '%s\n' "$E" | grep -c .); EB=$(printf '%s' "$E" | LC_ALL=C wc -c)
[ -n "$E" ] && [ "$EL" -le 40 ] && [ "$EB" -le 3000 ] && ok || bad "E4: capped at 40 lines and 3000 bytes (lines $EL, bytes $EB)"
ELAST="${E##*$'\n'}"
grep -vqE '^(a long one|line [0-9]{2} x{90})$' <<<"$E" && bad "E4: the cut is on a line end: ${ELAST:0:60}" || ok

mv "$H/bin/transcript-scrub.sh" "$T/scrub.away"
E=$(pb_excerpt "$T/e1.md" 2>/dev/null)
[ -z "$E" ] && ok || bad "E5: FAIL CLOSED: no scrubber, no excerpt: [$E]"
mv "$T/scrub.away" "$H/bin/transcript-scrub.sh"
# A secret the env knows never reaches the excerpt.
printf 'BLOCKED: the key fixture-secret-7116 was in the plan\n' > "$T/e6.md"
E=$(pb_excerpt "$T/e6.md" 2>/dev/null)
grep -q 'fixture-secret-7116' <<<"$E" && bad "E5: the excerpt is scrubbed: [$E]" || ok

# ══ N: pb_notice ════════════════════════════════════════════════════════════
PLAN1=$'BLOCKED: which column holds the fee?\nThe ticket names two fee fields.\n\n## Scope\nx\n'
reset_all; seed "PLAN_BLOCKED $B/plan.md" "$PLAN1"
pb_notice "$H" "$P" 7116 "$K" "$B" >> "$T/notice.log" 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "N1: rc 0 on a posted notice (rc $RC): $(tail -3 "$T/notice.log")"
[ "$(nposts)" = 1 ] && ok || bad "N1: THE POINT: exactly one comment POST (got $(nposts)): $(cat "$GH_SINK")"
grep -q -- '-X POST repos/example-org/cromford/issues/7116/comments' "$POST_SINK" && ok || bad "N1: the POST goes to the ticket's issue: $(cat "$POST_SINK")"
grep -qx '> which column holds the fee?' "$T/post-1.txt" 2>/dev/null && ok || bad "N1: the body quotes the reason: $(cat "$T/post-1.txt" 2>/dev/null)"
grep -q 'Reply here with the answer' "$T/post-1.txt" 2>/dev/null && ok || bad "N1: the body asks for the answer: $(cat "$T/post-1.txt" 2>/dev/null)"
L1=$(head -1 "$B/RESULT")
case "$L1" in "PLAN_BLOCKED $B/plan.md | CLOSED-OUT: "*"example-org/cromford#7116"*) ok ;; *) bad "N1: RESULT line 1 carries the builder-direct marker: $L1" ;; esac
[ "$(sed -n 2p "$B/RESULT")" = "BUILD_DIR: $B" ] && ok || bad "N1: the lines after line 1 are kept: $(cat "$B/RESULT")"
grep -q 'plan-blocked notice posted' "$T/notice.log" && ok || bad "N1: the log says posted: $(tail -2 "$T/notice.log")"

# N2: the neighbours never post and never touch the RESULT.
for RL in "PLAN_MALFORMED $B/plan.md" "PLAN_STALE $B/plan.md" "PLAN_BLOCKED_X $B/plan.md" \
          "RESULT_UNVERIFIED PLAN_BLOCKED $B/plan.md" "REVIEW_BLOCKED $B/review.md" \
          "PR_CREATED https://github.com/example-org/cromford/pull/9 (PLAN_BLOCKED fix)" \
          "PLAN_BLOCKED $B/plan.md | CLOSED-OUT: the builder posted the board close-out on example-org/cromford#7116"; do
  reset_all; seed "$RL" "$PLAN1"; cp "$B/RESULT" "$T/before"
  pb_notice "$H" "$P" 7116 "$K" "$B" >/dev/null 2>&1; RC=$?
  [ "$RC" = 4 ] && [ "$(nposts)" = 0 ] && cmp -s "$T/before" "$B/RESULT" && ok \
    || bad "N2: '$RL' must be a no-op (rc $RC, posts $(nposts), RESULT $(head -1 "$B/RESULT"))"
done

# N3: an empty plan posts nothing and marks nothing.
reset_all; seed "PLAN_BLOCKED $B/plan.md" ""
pb_notice "$H" "$P" 7116 "$K" "$B" >/dev/null 2>&1; RC=$?
[ "$RC" = 1 ] && [ "$(nposts)" = 0 ] && ! grep -q CLOSED-OUT "$B/RESULT" && ok || bad "N3: empty plan -> rc 1, no POST, no marker (rc $RC, posts $(nposts))"

# N4: the same reason twice is ONE comment, also from a machine with no state
# (the ledger row answers); the second RESULT is still marked.
reset_all; seed "PLAN_BLOCKED $B/plan.md" "$PLAN1"
pb_notice "$H" "$P" 7116 "$K" "$B" >/dev/null 2>&1
scratch_rm "$H/state"; mkdir -p "$H/state"; seed "PLAN_BLOCKED $B/plan.md" "$PLAN1"
pb_notice "$H" "$P" 7116 "$K" "$B" >/dev/null 2>&1; RC=$?
[ "$(nposts)" = 1 ] && ok || bad "N4: THE POINT: one comment per reason, not one per re-offer (posts $(nposts))"
[ "$RC" = 0 ] && grep -q 'CLOSED-OUT: .*the same block reason is already on example-org/cromford#7116' "$B/RESULT" && ok \
  || bad "N4: the second run marks the RESULT with the already-on note (rc $RC): $(head -1 "$B/RESULT")"

# N5: a refused POST leaves the RESULT unmarked, rc 1, and never says posted.
reset_all; seed "PLAN_BLOCKED $B/plan.md" "$PLAN1"; : > "$T/notice.log"
GH_POST_STATUS=422 pb_notice "$H" "$P" 7116 "$K" "$B" >> "$T/notice.log" 2>&1; RC=$?
[ "$RC" = 1 ] && ! grep -q CLOSED-OUT "$B/RESULT" && ok || bad "N5: a 422 -> rc 1, no marker (rc $RC): $(head -1 "$B/RESULT")"
grep -q 'notice posted' "$T/notice.log" && bad "N5: a failed POST must not log posted: $(cat "$T/notice.log")" || ok

# N6: a stale file for ANOTHER reason does not suppress this one.
reset_all; seed "PLAN_BLOCKED $B/plan.md" "$PLAN1"
mkdir -p "$H/state/plan-blocked/$P"; : > "$H/state/plan-blocked/$P/$K.0123456789abcdef"
pb_notice "$H" "$P" 7116 "$K" "$B" >/dev/null 2>&1
[ "$(nposts)" = 1 ] && ok || bad "N6: a stale other-reason file must not suppress the post (posts $(nposts))"

# N7: the marked line through the real staging close-out guard and plan.md rewrite.
reset_all; seed "PLAN_BLOCKED cross-repo-read example-org/spec-fixture $B/plan.md" "$PLAN1"
pb_notice "$H" "$P" 7116 "$K" "$B" >/dev/null 2>&1
RREF=$(head -1 "$B/RESULT")
awk 'index($0,"RR_CLOSED_OUT() {")==1{f=1} f{print} f&&/^}/{exit}' "$DIR/bin/lib/rt/staging.sh" > "$T/rr.sh"
SEDL=$(grep -m1 'RBLINE=$(printf .%s. "$RREF" | sed ' "$DIR/bin/lib/rt/staging.sh" | sed -E 's/^[[:space:]]*\*\)[[:space:]]*//; s/[[:space:]]*;;[[:space:]]*$//')
[ -s "$T/rr.sh" ] && [ -n "$SEDL" ] && ok || bad "N7: could not lift RR_CLOSED_OUT / the plan.md sed from bin/lib/rt/staging.sh"
RDEST="$T/staged"; mkdir -p "$RDEST"
OUTL=$( . "$H/bin/lib/builder-direct.sh"; . "$T/rr.sh"; RR_CLOSED_OUT "$RREF" "$RDEST"
        RBRE='plan\.md'; RBFILE=plan.md; eval "$SEDL"; printf '%s' "$RBLINE" )
[ -f "$RDEST/COMMENTED" ] && ok || bad "N7: the staged dir is COMMENTED for a marked line: $RREF"
case "$OUTL" in "PLAN_BLOCKED cross-repo-read example-org/spec-fixture $RDEST/plan.md | CLOSED-OUT: "*) ok ;; *) bad "N7: the path token is rewritten and the marker kept: $OUTL" ;; esac

# N8: a new reason after an answer is a new comment. Since BH-7719 a second
# notice also waits for a human comment after the first one, so the thread
# carries one.
reset_all; seed "PLAN_BLOCKED $B/plan.md" "$PLAN1"
pb_notice "$H" "$P" 7116 "$K" "$B" >/dev/null 2>&1
N8AT=$(( $(cat "$H/state/plan-blocked/$P/$K.last" 2>/dev/null || date -u +%s) + 1 ))
jq -nc --arg c "$(date -u -d "@$N8AT" '+%Y-%m-%dT%H:%M:%SZ')" \
  '[{user:{type:"User",login:"operator"},created_at:$c,updated_at:$c,body:"the fee is in column B"}]' > "$SRV/thread.json"
seed "PLAN_BLOCKED $B/plan.md" $'BLOCKED: the fee table moved to another repo.\n'
pb_notice "$H" "$P" 7116 "$K" "$B" >/dev/null 2>&1
[ "$(nposts)" = 2 ] && ok || bad "N8: a new reason after an answer posts again (posts $(nposts))"
rm -f "$SRV/thread.json"

# N9: an in-app board is not this lane's.
reset_all; seed "PLAN_BLOCKED $B/plan.md" "$PLAN1"
pb_notice "$H" project-3 T1 TK-9 "$B" >/dev/null 2>&1; RC=$?
[ "$RC" = 4 ] && [ "$(nposts)" = 0 ] && ok || bad "N9: in-app board -> rc 4, no POST (rc $RC, posts $(nposts))"

# ══ W: the gates.sh region, as _job_finish runs it ══════════════════════════
awk 'index($0,"# >>> plan-blocked notice")==1{f=1;next}
     index($0,"# <<< plan-blocked notice")==1{exit} f' "$DIR/bin/lib/rb/gates.sh" > "$T/pbn.sh"
[ -s "$T/pbn.sh" ] && ok || bad "W: no '# >>> plan-blocked notice' region in bin/lib/rb/gates.sh"
{ printf 'pbnfn() {\n  local r="$1"\n'; cat "$T/pbn.sh"; printf '}\n'; } > "$T/pbnfn.sh"
MARK=$(grep -n '^# >>> plan-blocked notice$' "$DIR/bin/lib/rb/gates.sh" | head -1 | cut -d: -f1)
PREV=$(grep -n '^# <<< blocking artifact body$' "$DIR/bin/lib/rb/gates.sh" | head -1 | cut -d: -f1)
ROWL=$(grep -n 'THE RESULT AS A ROW' "$DIR/bin/lib/rb/gates.sh" | head -1 | cut -d: -f1)
[ -n "$MARK" ] && [ -n "$PREV" ] && [ -n "$ROWL" ] && [ "$PREV" -lt "$MARK" ] && [ "$MARK" -lt "$ROWL" ] && ok \
  || bad "W: the region sits after the blocking-artifact body and before the result row (prev '$PREV' mark '$MARK' row '$ROWL')"
wdrive() { # wdrive <harness> <extra-env>
  ( export BUILD="$B" HARNESS="$1"
    bash -c 'set -uo pipefail; PROJECT=cromford; KEY=BH-7116; TICKET=7116
      '"$2"'
      . "'"$T"'/pbnfn.sh"; pbnfn "$(head -c 300 "$BUILD/RESULT")"' ) >/dev/null 2>&1
  echo $?
}
reset_all; seed "PLAN_BLOCKED $B/plan.md" "$PLAN1"
RC=$(wdrive "$H" 'BUILDER_EXEC=1; BUILDER_DIRECT_ON=1')
[ "$RC" = 0 ] && [ "$(nposts)" = 1 ] && ok || bad "W1: THE POINT: a builder's PLAN_BLOCKED posts one comment from _job_finish (rc $RC, posts $(nposts))"
grep -q CLOSED-OUT "$B/RESULT" && ok || bad "W1: and marks its RESULT: $(head -1 "$B/RESULT")"
grep -q 'plan-blocked notice posted' "$B/pipeline.log" 2>/dev/null && ok || bad "W1: the build record says so: $(cat "$B/pipeline.log" 2>/dev/null)"
reset_all; seed "PLAN_BLOCKED $B/plan.md" "$PLAN1"
RC=$(wdrive "$H" 'BUILDER_EXEC=1; BUILDER_DIRECT_ON=0')
[ "$RC" = 0 ] && [ "$(nposts)" = 0 ] && ! grep -q CLOSED-OUT "$B/RESULT" && ok || bad "W2: BUILDER_DIRECT_ON=0 -> no comment (rc $RC, posts $(nposts))"
reset_all; seed "PLAN_BLOCKED $B/plan.md" "$PLAN1"
RC=$(wdrive "$H" 'unset BUILDER_EXEC; BUILDER_DIRECT_ON=1')
[ "$RC" = 0 ] && [ "$(nposts)" = 0 ] && ok || bad "W3: a watcher build (no BUILDER_EXEC) -> no comment (rc $RC, posts $(nposts))"
H2="$T/h2"; mkdir -p "$H2/bin/lib"
printf 'pb_notice() { echo called >> "%s/called"; return 1; }\n' "$T" > "$H2/bin/lib/plan-blocked.sh"
reset_all; seed "PLAN_BLOCKED $B/plan.md" "$PLAN1"
RC=$(wdrive "$H2" 'BUILDER_EXEC=1; BUILDER_DIRECT_ON=1')
[ "$RC" = 0 ] && [ -s "$T/called" ] && ok || bad "W3: a failing pb_notice never changes the trap's rc (rc $RC, called: $(cat "$T/called" 2>/dev/null))"

# ══ H: pb_hub_copy ══════════════════════════════════════════════════════════
LOC="$H/builds/pool-$P-BH-1-202610161930"
hub_seed() { scratch_rm "$LOC"; mkdir -p "$LOC"; printf '%s\n' "$1" > "$LOC/RESULT"; }
cat > "$SRV/feed.json" <<'JSON'
{"artifacts":[{"job_id":"build-cromford-BH-1-fixture","artifact_ref":"PLAN_BLOCKED /data/harness/builds/cromford-BH-1-x/plan.md","box":"pool-fixture","ticket_id":"BH-1","updated_at":"2026-10-16T13:27:06Z","detail":"{\"build_dir\":\"cromford-BH-1-x\",\"key\":\"BH-1\",\"job_status\":\"parked\"}"}]}
JSON
printf '{"transcripts":[{"phase_id":0,"attempt":1,"stage":"plan","runner":"pipeline","source":"plan_md","bytes":40}]}\n' > "$SRV/transcripts.json"
jq -nc --arg b $'BLOCKED: which column holds the fee?\nbody line two\n' '{transcript:{body:$b,truncated:0}}' > "$SRV/transcript.json"
hub_seed "PLAN_BLOCKED /data/harness/builds/cromford-BH-1-x/plan.md"
OUTH=$(pb_hub_copy "$H" "$P" "$LOC" 2>&1)
[ "$(cat "$LOC/plan.md" 2>/dev/null)" = $'BLOCKED: which column holds the fee?\nbody line two' ] && ok \
  || bad "H1: THE POINT: the row-sourced hub dir gets plan.md from the ledger ($OUTH): $(cat "$LOC/plan.md" 2>/dev/null)"
[ "$(head -1 "$LOC/RESULT")" = "PLAN_BLOCKED /data/harness/builds/cromford-BH-1-x/plan.md" ] && ok || bad "H1: the RESULT is never rewritten: $(head -1 "$LOC/RESULT")"
printf 'already here\n' > "$LOC/plan.md"
pb_hub_copy "$H" "$P" "$LOC" >/dev/null 2>&1
[ "$(cat "$LOC/plan.md")" = "already here" ] && ok || bad "H2: a plan.md that is already there is kept: $(cat "$LOC/plan.md")"
hub_seed "PR_CREATED https://github.com/example-org/cromford/pull/9"; : > "$SRV/req.log"
pb_hub_copy "$H" "$P" "$LOC" >/dev/null 2>&1
[ ! -e "$LOC/plan.md" ] && ! grep -q transcript "$SRV/req.log" && ok || bad "H3: PR_CREATED -> no fetch, no file: $(cat "$SRV/req.log")"
echo '{"transcript":{"body":"","truncated":0}}' > "$SRV/transcript.json"
hub_seed "PLAN_BLOCKED /data/harness/builds/cromford-BH-1-x/plan.md"
pb_hub_copy "$H" "$P" "$LOC" >/dev/null 2>&1
[ ! -e "$LOC/plan.md" ] && [ ! -e "$LOC/plan.md.tmp" ] && ok || bad "H4: an empty ledger answer leaves no plan.md and no .tmp: $(ls "$LOC")"
# H5: the reap calls it after it assembles the RESULT line.
RL=$(grep -n 'RLINE=$(head -1 "$LOCAL/RESULT")' "$DIR/bin/fly-pool.sh" | head -1 | cut -d: -f1)
CL=$(grep -n 'pb_hub_copy "$HARNESS" "$P" "$LOCAL"' "$DIR/bin/fly-pool.sh" | head -1 | cut -d: -f1)
[ -n "$RL" ] && [ -n "$CL" ] && [ "$CL" -gt "$RL" ] && [ "$((CL - RL))" -le 6 ] && ok \
  || bad "H5: bin/fly-pool.sh calls pb_hub_copy right after the reap's RLINE (RLINE line '$RL', call line '$CL')"
grep -q '^\. "\$HARNESS/bin/lib/plan-blocked.sh"' "$DIR/bin/fly-pool.sh" && ok || bad "H5: bin/fly-pool.sh sources bin/lib/plan-blocked.sh"

[ -n "${PB_DEBUG:-}" ] && { cat "$T/post-1.txt"; head -1 "$B/RESULT"; cat "$T/notice.log"; }
echo "plan-blocked-notice (BH-7116): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
