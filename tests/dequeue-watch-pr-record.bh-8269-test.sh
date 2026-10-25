#!/bin/bash
# tests/dequeue-watch-pr-record.bh-8269-test.sh — BH-8269: the dequeue-watch
# lane reads the fleet's own PR record (bin/lib/ph-pr-record.sh) before GitHub
# for the per-PR pulls/<n> read in dqw_gather_pr, and the decisions do not
# change. Every B case runs the SHIPPED bin/dequeue-watch.sh from a `cp -rs`
# scratch harness (the scaffold of tests/dequeue-watch.bh-3719-test.sh), with
# the seam tests/fixtures/dequeue-watch/pr-record.bh-8269.sh: fixture.sh plus a
# file-backed fake of GET/PUT /api/pr-records. Three dequeued PRs per case, each
# case with its own PR numbers, its own fixture dir and its own logs.
#
#   B0 no record: 3 pulls reads, 3 why=no-row, 3 write-backs (the baseline)
#   B1 (AT1) all 3 in the record, no pulls fixture: 0 pulls reads, same decisions
#   B2 (AT2) one PR missing: exactly 1 pulls read, 1 PRR_MISS, 1 PUT
#   B2b the next tick reads the written-back row: 0 pulls reads
#   B3a age 900 = hit   B3b age 901 = stale miss   B4 knob 0 = no record GET
#   B5 mergeable_state null = no-field miss, GitHub's dirty -> textual-conflict
#   B6 the record GET fails = unreadable miss, same decisions
#   B7 the record head is past the payload's head = stale-event, 0 reads
#   B8 a miss whose GitHub read fails = pull unread, skipped
#   U1/U2 ph_prr_miss writes to the caller's log, never a path
#   U3 a non-string head_sha in the row = no-field miss, GitHub read
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/dequeue-watch-pr-record.bh-8269-test.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
FX="$DIR/tests/fixtures/dequeue-watch"
SEAM="$FX/pr-record.bh-8269.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $CASE: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

NOW=$(date -u +%s)   # the one clock read; payload ages are offsets from it
SLUG=example-org/cromford
HEAD=b49a1b832b0d294ee7a46325ac2ace79dc50d235
OTHER=0123456789abcdef0123456789abcdef01234567
H="$T/h"; F="$T/fix"; LOG="$H/logs/dequeue-watch.log"; REQ="$F/requests.log"
CASE=setup

mkdir -p "$H" "$T/shim"
cp -rs "$DIR/bin" "$H/bin"
cp -rs "$DIR/catalog" "$H/catalog"
for s in lane-alert lead-verdict needs-human-hold box-for agent-call; do
  rm -f "$H/bin/$s.sh"
  {
    echo '#!/bin/bash'
    echo 'printf "SCRIPT %s %s\n" "$(basename "$0")" "$*" >> "$DQW_FIX_DIR/requests.log"'
  } > "$H/bin/$s.sh"
done
echo 'echo box-2' >> "$H/bin/box-for.sh"
echo 'printf "%s\n" "${AGENT_ANSWER:-semantic-test}" > "$5"' >> "$H/bin/agent-call.sh"
cat > "$T/shim/gh" <<'EOF'
#!/bin/bash
printf 'gh %s\n' "$*" >> "$DQW_FIX_DIR/requests.log"
case "$1 $2" in
  "api --paginate")
    n=$(printf '%s' "$3" | sed -n 's#.*/issues/\([0-9]*\)/comments.*#\1#p')
    [ -r "$DQW_FIX_DIR/comments-$n.json" ] && exec cat "$DQW_FIX_DIR/comments-$n.json" ;;
  "run view") [ -r "$DQW_FIX_DIR/log-$3.txt" ] && exec cat "$DQW_FIX_DIR/log-$3.txt" ;;
esac
exit 1
EOF
chmod +x "$T/shim/gh" "$H/bin/"{lane-alert,lead-verdict,needs-human-hold,box-for,agent-call}.sh

# ── fixture writers ───────────────────────────────────────────────────────────
rest() { mkdir -p "$F/rest"; cat > "$F/rest/$(printf '%s' "$1" | tr '/?&=' '____')"; }   # rest <path> < body
unrest() { rm -f "$F/rest/$(printf '%s' "$1" | tr '/?&=' '____')"; }
list_prs() {
  local l
  for l in merge-queue dequeued; do
    printf '%s\n' "$@" | jq -sc 'map({number: ., pull_request: {url: "x"}, labels: [{name: "merge-queue"}, {name: "dequeued"}]})' \
      | rest "repos/$SLUG/issues?labels=$l&state=open&per_page=100"
  done
}
payload() {    # payload <num> <payload-file> <age_s>
  local at; at=$(date -u -d "@$((NOW - $3))" +%FT%TZ)
  jq -n --rawfile b "$2" --arg at "$at" --argjson n "$1" \
    '[{id: (9000 + $n), user: {login: "mergify[bot]"}, body: $b, created_at: $at, updated_at: $at}]' > "$F/comments-$1.json"
  jq -n --rawfile b "$2" '{body: $b}' | rest "repos/$SLUG/issues/comments/$((9000 + $1))"
}
pull() {       # pull <num> [mergeable_state] — GitHub's answer for pulls/<num>
  jq -nc --arg h "$HEAD" --arg r "ticket/bh-9$1" --arg m "${2:-clean}" '{head: {sha: $h, ref: $r}, mergeable_state: $m}' \
    | rest "repos/$SLUG/pulls/$1"
}
unpull() { unrest "repos/$SLUG/pulls/$1"; }
# rec <num> [age_s] [mergeable_state|null] [head_sha JSON] — the record row for <num>.
rec() {
  mkdir -p "$F/records"
  jq -nc --arg r "${SLUG,,}" --argjson n "$1" --argjson m "$( [ "${3:-clean}" = null ] && echo null || jq -nc --arg m "${3:-clean}" '$m')" \
    --argjson h "${4:-\"$HEAD\"}" --arg ref "ticket/bh-9$1" \
    '{repo: $r, number: $n, state: "open", head_sha: $h, head_ref: $ref, mergeable_state: $m}' > "$F/records/$1.json"
  echo "${2:-0}" > "$F/records/$1.age"
}

base() {       # base <case> <n1> <n2> <n3> — three PRs, each a batch of one failing on run 5001
  CASE="$1"; shift
  P1=$1 P2=$2 P3=$3
  local d n
  for d in "$F" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/tmp"; do scratch_rm "$d" || exit 1; done
  mkdir -p "$F/rest" "$H/state/merge-conductor" "$H/logs"
  : > "$REQ"
  printf 'proj %s https://example.invalid - 5 box-2\n' "$SLUG" > "$H/fleet.conf"
  list_prs "$@"
  for n in "$@"; do
    payload "$n" "$FX/payload-dequeued-batch1.md" 120
    pull "$n"
    rest "repos/$SLUG/pulls/$n/files?per_page=100" < "$FX/pr-files-101.json"
  done
  rest "repos/$SLUG/actions/runs?event=push&per_page=100" < "$FX/runs-batch1.json"
  cp "$FX/log-rule-break.txt" "$F/log-5001.txt"
  jq -n --arg c "$(base64 -w0 < "$FX/sources-lib-root.txt")" '{content: $c, encoding: "base64"}' \
    | rest "repos/$SLUG/contents/tests/lib-root-literal-ratchet.bh-2613-test.sh?ref=main"
  echo MERGE > "$F/verdict"
  echo '{"statuses":[{"context":"lead-verdict","state":"success"}]}' | rest "repos/$SLUG/commits/$HEAD/status"
}

SUMRE='^[0-9-]+T[0-9:]+Z (tick |off$|disabled$|locked$|gh-budget$|lib-missing )'
lastsum() { grep -E "$SUMRE" "$LOG" 2>/dev/null | tail -1; }
cnt() { grep -cF -- "$1" "$REQ" 2>/dev/null || true; }
cntlog() { grep -cF -- "$1" "$LOG" 2>/dev/null || true; }
# pulls_reads [num] — the R1 reads: REST GET repos/<slug>/pulls/<n>, never /files.
pulls_reads() { grep -cE "^REST GET repos/$SLUG/pulls/${1:-[0-9]+}\$" "$REQ" 2>/dev/null || true; }
misses() { grep -cE '^[0-9TZ:-]+ PRR_MISS [^ ]+#[0-9]+ why=(no-row|stale|no-field|unreadable)( field=[a-z_]+)?$' "$LOG" 2>/dev/null || true; }
# decisions — the summary counts, the claims (pr as P1/P2/P3) and the WOULD_ lines.
decisions() {
  {
    lastsum | sed -E 's/^[^ ]+ //'
    grep -F 'JOBS POST /api/dequeue-watch/actions/claim ' "$REQ" | sed 's/^JOBS POST [^ ]* //' \
      | jq -c --argjson a "$P1" --argjson b "$P2" '{pr: (if .pr == $a then "P1" elif .pr == $b then "P2" else "P3" end), head, class, action}' | sort
    grep -F 'WOULD_' "$LOG" | sed -E 's/^[^ ]+ [^ ]+ //'
  } | sed -E "s/#$P1\b/#P1/g; s/#$P2\b/#P2/g; s/#$P3\b/#P3/g"
}
run_lane() {
  env -i PATH="$T/shim:$PATH" HOME="$T" HARNESS="$H" JOBS_URL= HARNESS_SECRET=test-secret-fixture \
    HARNESS_TEST_SANDBOX=1 DEQUEUE_WATCH_FIXTURE="$SEAM" DQW_FIX_DIR="$F" DEQUEUE_WATCH_ACT=1 "$@" \
    bash "$H/bin/dequeue-watch.sh" > "$T/lane.out" 2> "$T/lane.err"
  RC=$?
  [ "$RC" = 0 ] && ok || bad "the lane exited $RC: $(head -c 600 "$T/lane.err")"
}
eq() { [ "$2" = "$3" ] && ok || bad "$1: got '$2', wanted '$3'"; }
has() { grep -qE -- "$2" "$LOG" 2>/dev/null && ok || bad "$1: no /$2/ in the lane log: $(tail -5 "$LOG" 2>/dev/null | tr '\n' '|')"; }

# ── B0: no record -> today's reads, a miss and a write-back each ──────────────
base B0 701 702 703
run_lane
eq "pulls reads" "$(pulls_reads)" 3
eq "PRR_MISS lines" "$(misses)" 3
has "no-row line" "^[0-9TZ:-]+ PRR_MISS $SLUG#702 why=no-row\$"
eq "write-back PUTs" "$(cnt 'JOBS PUT /api/pr-records')" 3
eq "write-back of 702" "$(jq -r 'select(.number == 702) | "\(.source) \(.fields.head_sha) \(.fields.mergeable_state)"' "$F/records/puts.jsonl" 2>/dev/null)" "github $HEAD clean"
lastsum | grep -q ' dequeued=3 recorded=3 ' && ok || bad "summary '$(lastsum)' should say dequeued=3 recorded=3"
D0=$(decisions)
[ "$(grep -c '"class"' <<<"$D0")" = 3 ] && ok || bad "the baseline holds $(grep -c '"class"' <<<"$D0") claims, wanted 3: $D0"
L0=$(cnt 'issues?labels='); C0=$(cnt '/issues/comments/'); FI0=$(cnt '/files?per_page=100')

# ── B1 (AT1): every PR in the record, GitHub has no pulls answer ──────────────
base B1 711 712 713
for n in 711 712 713; do rec "$n"; unpull "$n"; done
run_lane
eq "pulls reads" "$(pulls_reads)" 0
eq "PRR_MISS lines" "$(misses)" 0
eq "record GETs" "$(cnt 'JOBS GET /api/pr-records?repo=example-org/cromford&number=')" 3
eq "write-back PUTs" "$(cnt 'JOBS PUT /api/pr-records')" 0
eq "decisions" "$(decisions)" "$D0"
eq "list reads" "$(cnt 'issues?labels=')" "$L0"
eq "payload comment reads" "$(cnt '/issues/comments/')" "$C0"
eq "files reads" "$(cnt '/files?per_page=100')" "$FI0"

# ── B2 (AT2): one PR missing from the record ──────────────────────────────────
base B2 721 722 723
rec 721; rec 723; unpull 721; unpull 723
run_lane
eq "pulls reads" "$(pulls_reads)" 1
eq "pulls/722 reads" "$(pulls_reads 722)" 1
eq "PRR_MISS lines" "$(misses)" 1
has "722 no-row" "^[0-9TZ:-]+ PRR_MISS $SLUG#722 why=no-row\$"
eq "write-back PUTs" "$(cnt 'JOBS PUT /api/pr-records')" 1
eq "write-back of 722" "$(jq -r '"\(.number) \(.source) \(.fields.head_sha)"' "$F/records/puts.jsonl" 2>/dev/null)" "722 github $HEAD"
eq "decisions" "$(decisions)" "$D0"

# ── B2b: the next tick reads what the write-back stored ───────────────────────
CASE=B2b
: > "$REQ"
run_lane
eq "pulls/722 reads on the next tick" "$(pulls_reads 722)" 0
eq "PRR_MISS lines over two ticks" "$(misses)" 1

# ── B3: the age edge ──────────────────────────────────────────────────────────
base B3a 731 732 733
for n in 731 732 733; do rec "$n" 900; unpull "$n"; done
run_lane
eq "pulls reads at age 900" "$(pulls_reads)" 0
eq "PRR_MISS lines at age 900" "$(misses)" 0
eq "decisions" "$(decisions)" "$D0"

base B3b 741 742 743
rec 741; rec 742 901; rec 743
run_lane
eq "pulls reads" "$(pulls_reads)" 1
eq "pulls/742 reads at age 901" "$(pulls_reads 742)" 1
has "742 stale" "^[0-9TZ:-]+ PRR_MISS $SLUG#742 why=stale\$"
eq "decisions" "$(decisions)" "$D0"

# ── B4: the knob at 0 -> no record GET at all ─────────────────────────────────
base B4 751 752 753
for n in 751 752 753; do rec "$n"; done
run_lane PR_RECORD_MAX_AGE_S=0
eq "pulls reads with the knob 0" "$(pulls_reads)" 3
eq "stale lines" "$(cntlog ' why=stale')" 3
eq "record GETs" "$(cnt 'JOBS GET /api/pr-records')" 0
eq "decisions" "$(decisions)" "$D0"

# ── B5: mergeable_state null is a miss, never "-" ─────────────────────────────
base B5 761 762 763
rec 761; rec 762 0 null; rec 763; unpull 761; unpull 763
pull 762 dirty
run_lane
eq "pulls reads" "$(pulls_reads)" 1
eq "pulls/762 reads" "$(pulls_reads 762)" 1
has "762 no-field" "^[0-9TZ:-]+ PRR_MISS $SLUG#762 why=no-field field=mergeable_state\$"
eq "762 class" "$(grep -F 'JOBS POST /api/dequeue-watch/actions/claim ' "$REQ" | sed 's/^JOBS POST [^ ]* //' | jq -r 'select(.pr == 762) | .class')" textual-conflict

# ── B6: the record GET fails -> unreadable, today's reads ─────────────────────
base B6 771 772 773
for n in 771 772 773; do rec "$n"; done
touch "$F/records/FAIL"
run_lane
eq "pulls reads" "$(pulls_reads)" 3
eq "unreadable lines" "$(cntlog ' why=unreadable')" 3
eq "decisions" "$(decisions)" "$D0"

# ── B7: the record head is past the dequeued head -> stale-event ──────────────
base B7 781 782 783
for n in 781 782 783; do rec "$n"; unpull "$n"; done
rec 782 0 clean "\"$OTHER\""
run_lane
eq "pulls reads" "$(pulls_reads)" 0
has "782 stale-event" "$SLUG#782 stale-event: left the queue at ${HEAD:0:12}, head is now ${OTHER:0:12}"
lastsum | grep -q ' stale=1 ' && ok || bad "summary '$(lastsum)' should say stale=1"
eq "claims for 782" "$(grep -F 'JOBS POST /api/dequeue-watch/actions/claim ' "$REQ" | grep -c '"pr":782')" 0

# ── B8: a miss whose GitHub read fails -> skipped, as today ───────────────────
base B8 791 792 793
rec 791; rec 793; unpull 792
run_lane
eq "pulls/792 reads" "$(pulls_reads 792)" 1
has "792 skipped" "$SLUG#792 pull unread, skipped"
eq "PRR_MISS lines" "$(misses)" 1
eq "write-back PUTs" "$(cnt 'JOBS PUT /api/pr-records')" 0
lastsum | grep -q ' skipped=1' && ok || bad "summary '$(lastsum)' should say skipped=1"

# ── U3: a non-string head_sha in the row -> no-field miss -> GitHub ───────────
base U3 801 802 803
rec 801; rec 802 0 clean 12345; rec 803; unpull 801; unpull 803
run_lane
eq "pulls/802 reads" "$(pulls_reads 802)" 1
has "802 no-field head_sha" "^[0-9TZ:-]+ PRR_MISS $SLUG#802 why=no-field field=head_sha\$"
eq "decisions" "$(decisions)" "$D0"

# ── U1/U2: ph_prr_miss writes to the caller's log name, never a path ──────────
CASE=U1
U="$T/u"; mkdir -p "$U"
( HARNESS="$U"; unset PH_PRR_LOG; . "$DIR/bin/lib/ph-pr-record.sh"; ph_prr_miss o/r 1 no-row )
eq "default log" "$(grep -c ' PRR_MISS o/r#1 why=no-row$' "$U/logs/pipeline-health.log" 2>/dev/null)" 1
CASE=U2
( HARNESS="$U"; . "$DIR/bin/lib/ph-pr-record.sh"; PH_PRR_LOG=dequeue-watch ph_prr_miss o/r 2 stale )
eq "dequeue-watch log" "$(grep -c ' PRR_MISS o/r#2 why=stale$' "$U/logs/dequeue-watch.log" 2>/dev/null)" 1
( HARNESS="$U"; . "$DIR/bin/lib/ph-pr-record.sh"; PH_PRR_LOG=../x ph_prr_miss o/r 3 stale )
eq "a path in the name falls back" "$(grep -c ' PRR_MISS o/r#3 why=stale$' "$U/logs/pipeline-health.log" 2>/dev/null)" 1
[ -e "$T/x.log" ] && bad "PH_PRR_LOG=../x wrote outside logs/" || ok

echo "dequeue-watch-pr-record: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
