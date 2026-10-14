#!/bin/bash
# tests/queue-risk.bh-5430-test.sh — BH-5430: a break-risk score per queued PR
# routes risky PRs into Mergify's size-1 `solo` queue (the `queue-solo` label).
# The weights, path sets, size limits, threshold and mode are settings rows.
#
#   Q1-Q4, Q10-Q12  bin/lib/queue-risk.sh qr_score / qr_enqueue_step on stubbed
#                   setting_get rows
#   Q13             the rows and the mode are read once per conductor tick
#                   (MC_TICK_ID), shared by every enqueue of that tick; a new
#                   tick reads them again (lead review of a74f4446, NOTE 1)
#   Q14             enforce + a readable PR whose file list is empty: a stale
#                   queue-solo label is removed (NOTE 5)
#   Q5-Q9           the real mc_enqueue_mergify (bin/lib/mc/queue.sh) with a
#                   stub gh on PATH and a scratch cromford.conf carrying
#                   solo_label=queue-solo
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/queue-risk.bh-5430-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

QR_LIB="$DIR/bin/lib/queue-risk.sh"
[ -r "$QR_LIB" ] || { echo "FAIL: $QR_LIB does not exist (BH-5430 not built)"; echo "PASS=0 FAIL=1"; exit 1; }

# The scratch harness root: main's tree as qr_score sees it (new_tests asks it
# whether a test path already exists).
R="$T/r"; mkdir -p "$R/tests" "$R/bin/lib"
touch "$R/tests/old-thing.bh-1-test.sh"
ROWS="$T/rows"; : > "$ROWS"
# setting_get from $ROWS (`key<TAB>value`): no line is rc 2 (no row), the value
# __RC1__ is rc 1 (an outage).
SETTING_STUB='setting_get() { local v; printf "%s\n" "$1" >> "${SETCNT:-/dev/null}"; v=$(awk -F"\t" -v k="$1" '"'"'$1 == k { print $2; f = 1 } END { exit !f }'"'"' "$ROWS") || return 2; [ "$v" = __RC1__ ] && return 1; printf "%s" "$v"; }'
row() { printf '%s\t%s\n' "$1" "$2" >> "$ROWS"; }
# sc <lines> <nfiles> <path>... — qr_score's one output line.
sc() {
  local lines="$1" nf="$2"; shift 2
  printf '%s\n' "$@" > "$T/files"
  ( HARNESS="$R"; unset H; eval "$SETTING_STUB"; . "$QR_LIB"; qr_score "$T/files" "$lines" "$nf" example-org/cromford 41 ) 2>"$T/sc.err"
}
f1() { cut -f1 <<<"$1"; }
froute() { cut -f3 <<<"$1"; }
freasons() { cut -f4 <<<"$1"; }

# ── Q1: bin/lib + a catalog scores >= the threshold and routes solo ─────────
: > "$ROWS"
O=$(sc 40 2 bin/lib/foo.sh catalog/bar.tsv)
[ "$(f1 "$O")" -ge 50 ] 2>/dev/null && [ "$(froute "$O")" = solo ] && ok || bad "Q1 bin/lib + catalog is solo with score >= 50: '$O' $(cat "$T/sc.err")"
[ "$(f1 "$O")" = 55 ] && [ "$(cut -f2 <<<"$O")" = 50 ] && ok || bad "Q1 the fallback score is 30+25=55 over threshold 50: '$O'"
grep -q 'shared_lib:+30(bin/lib/foo.sh)' <<<"$(freasons "$O")" && grep -q 'registry:+25(catalog/bar.tsv)' <<<"$(freasons "$O")" && ok \
  || bad "Q1 the reasons name each signal, its weight and the path: '$(freasons "$O")'"
# one shared-lib edit alone is not enough on its own
O=$(sc 40 1 bin/lib/foo.sh)
[ "$(f1 "$O")" = 30 ] && [ "$(froute "$O")" = batch ] && ok || bad "Q1 bin/lib alone scores 30 and batches: '$O'"
# a signal counts once per PR, not once per file
O=$(sc 40 3 bin/lib/a.sh bin/lib/b.sh bin/lib/c.sh)
[ "$(f1 "$O")" = 30 ] && ok || bad "Q1 three bin/lib files still count shared_lib once: '$O'"

# ── Q2: docs-only scores 0 and batches ──────────────────────────────────────
O=$(sc 10 1 docs/a.md)
[ "$(f1 "$O")" = 0 ] && [ "$(froute "$O")" = batch ] && ok || bad "Q2 docs/a.md alone is score 0, batch: '$O'"
O=$(sc 10 2 docs/b.md docs/c.md)
[ "$(f1 "$O")" = 0 ] && [ "$(froute "$O")" = batch ] && ok || bad "Q2 docs/b.md + docs/c.md is score 0, batch: '$O'"

# ── Q3: the rows drive it ───────────────────────────────────────────────────
: > "$ROWS"; row queue_risk.threshold 60
O=$(sc 40 2 bin/lib/foo.sh catalog/bar.tsv)
[ "$(froute "$O")" = batch ] && [ "$(cut -f2 <<<"$O")" = 60 ] && ok || bad "Q3 threshold row 60 batches the Q1 PR: '$O'"
: > "$ROWS"; row queue_risk.globs.registry 'docs/*'; row queue_risk.weight.registry 60
O=$(sc 10 1 docs/a.md)
[ "$(froute "$O")" = solo ] && [ "$(f1 "$O")" = 60 ] && grep -q 'registry:+60(docs/a.md)' <<<"$O" && ok \
  || bad "Q3 a registry glob row of docs/* weighted 60 routes docs solo: '$O'"
: > "$ROWS"; row queue_risk.weight.shared_lib 0; row queue_risk.weight.registry 0
O=$(sc 40 2 bin/lib/foo.sh catalog/bar.tsv)
[ "$(froute "$O")" = batch ] && [ "$(f1 "$O")" = 0 ] && ok || bad "Q3 zeroed weights batch the Q1 PR: '$O'"
grep -q 'shared_lib' <<<"$(freasons "$O")" && bad "Q3 a zero-weight signal is not a reason: '$O'" || ok
# the size limits are rows too
: > "$ROWS"; row queue_risk.size_lines 10
O=$(sc 20 1 docs/a.md)
[ "$(f1 "$O")" = 15 ] && grep -q 'size:+15(20 lines)' <<<"$O" && ok || bad "Q3 size_lines row 10 makes 20 lines a size hit: '$O'"
: > "$ROWS"
O=$(sc 1200 16 docs/a.md)
[ "$(f1 "$O")" = 40 ] && grep -q 'size:+30(1200 lines)' <<<"$O" && grep -q 'size_files:+10(16 files)' <<<"$O" && ok \
  || bad "Q3 1200 lines counts size twice and 16 files adds size_files: '$O'"

# ── Q4: an unreadable row uses the fallback and says so ─────────────────────
: > "$ROWS"; row queue_risk.weight.schema abc
O=$(sc 10 1 worker/jobs/schema.sql)
[ "$(f1 "$O")" = 40 ] && grep -q 'schema:+40' <<<"$O" && grep -q 'rows-unreadable' <<<"$(freasons "$O")" && ok \
  || bad "Q4 a non-integer weight row falls back to 40 and flags rows-unreadable: '$O'"
: > "$ROWS"; row queue_risk.weight.schema __RC1__
O=$(sc 10 1 worker/jobs/schema.sql)
[ "$(f1 "$O")" = 40 ] && grep -q 'rows-unreadable' <<<"$O" && ok || bad "Q4 a setting_get rc 1 falls back and flags rows-unreadable: '$O'"
: > "$ROWS"
O=$(sc 10 1 worker/jobs/schema.sql)
grep -q 'rows-unreadable' <<<"$O" && bad "Q4 no rows at all (rc 2) is NOT unreadable: '$O'" || ok
# an empty or missing file list: unknown risk keeps today's routing, never solo
: > "$T/empty"
O=$( ( HARNESS="$R"; eval "$SETTING_STUB"; . "$QR_LIB"; qr_score "$T/empty" 10 0 example-org/cromford 41 ) )
[ "$O" = $'-\t50\tbatch\tfiles-unavailable' ] && ok || bad "Q4 an empty file list is '-, batch, files-unavailable': '$O'"
O=$( ( HARNESS="$R"; eval "$SETTING_STUB"; . "$QR_LIB"; qr_score "$T/nonexistent" 10 0 example-org/cromford 41 ); echo "rc=$?")
grep -q $'^-\t50\tbatch\tfiles-unavailable' <<<"$O" && grep -q 'rc=0' <<<"$O" && ok || bad "Q4 a missing file list is batch, rc 0: '$O'"

# ── Q11: prior culprit verdicts, capped at 2x; a prequeue-red park ──────────
# mc_attempt_count stub: the count of `<kind> <key> …` lines in $T/attempts.
ATT="$T/attempts"
ATT_STUB='mc_attempt_count() { awk -v k="$1" -v key="$2" '"'"'$1 == k && $2 == key { c++ } END { print c + 0 }'"'"' "$ATT" 2>/dev/null || echo 0; }'
sca() {
  printf '%s\n' "$@" > "$T/files"
  ( HARNESS="$R"; eval "$SETTING_STUB"; eval "$ATT_STUB"; . "$QR_LIB"; qr_score "$T/files" 10 1 example-org/cromford 41 )
}
: > "$ROWS"
printf 'bejculprit example-org/cromford#41 %s\n' aaaa bbbb > "$ATT"
O=$(sca docs/a.md)
[ "$(f1 "$O")" = 50 ] && [ "$(froute "$O")" = solo ] && grep -q 'ejected_before:+50(2 culprit verdicts)' <<<"$O" && ok \
  || bad "Q11 two prior culprit verdicts score 25x2 = 50 and go solo: '$O'"
printf 'bejculprit example-org/cromford#41 cccc\n' >> "$ATT"
O=$(sca docs/a.md)
[ "$(f1 "$O")" = 50 ] && ok || bad "Q11 a third verdict is capped at 2x (50): '$O'"
printf 'bejculprit example-org/cromford#99 dddd\n' > "$ATT"
O=$(sca docs/a.md)
[ "$(f1 "$O")" = 0 ] && ok || bad "Q11 another PR's culprit verdict does not count: '$O'"
printf 'pqred example-org/cromford#41 aaaa mmmm\npqred example-org/cromford#41 bbbb mmmm\n' > "$ATT"
O=$(sca docs/a.md)
[ "$(f1 "$O")" = 20 ] && grep -q 'prequeue_red:+20' <<<"$O" && ok || bad "Q11 a prior prequeue-red park adds 20 once: '$O'"
# without mc_attempt_count the history is unread, and the reason says so
O=$(sc 10 1 docs/a.md)
[ "$(f1 "$O")" = 0 ] && grep -q 'history-unread' <<<"$O" && ok || bad "Q11 no attempt ledger reader reads as history-unread, 0: '$O'"

# ── Q12: an added test file counts new_tests, a modified one does not ───────
: > "$ROWS"
O=$(sc 10 1 tests/new-thing.bh-9999-test.sh)
[ "$(f1 "$O")" = 10 ] && grep -q 'new_tests:+10(tests/new-thing.bh-9999-test.sh)' <<<"$O" && ok \
  || bad "Q12 a test path absent from \$HARNESS counts new_tests:+10: '$O'"
O=$(sc 10 1 tests/old-thing.bh-1-test.sh)
[ "$(f1 "$O")" = 0 ] && ok || bad "Q12 a test file main already has does not count: '$O'"
O=$(sc 10 1 tests/lib/new-helper.sh)
[ "$(f1 "$O")" = 0 ] && ok || bad "Q12 a non-test-shaped path under tests/ does not count: '$O'"

# ── Q13 (BH-6011): schema.sql is not in git, so a schema PR names a fragment ──
: > "$ROWS"
O=$(sc 10 1 worker/jobs/schema.d/0100-x.sql)
[ "$(f1 "$O")" = 40 ] && grep -q 'schema:+40' <<<"$O" && ok || bad "Q13 a schema.d fragment alone must be a schema hit (+40): '$O'"

# ── the seeds: every queue_risk.* row in schema.sql equals the lib's fallback ─
SEEDS=$(grep -o "('queue_risk\.[a-z_.]*','[^']*'" "$DIR/worker/jobs/schema.sql" | sed "s/^('//; s/','/\t/; s/'$//")
[ "$(grep -c . <<<"$SEEDS")" = 22 ] && ok || bad "seeds: 22 queue_risk.* rows (11 weights, 6 globs, threshold, 3 size limits, mode): $(grep -c . <<<"$SEEDS")"
DRIFT=$( ( . "$QR_LIB"
  while IFS=$'\t' read -r k v; do
    case "$k" in
      queue_risk.weight.*) d="QR_W_DEFAULT_${k#queue_risk.weight.}" ;;
      queue_risk.globs.*) d="QR_GLOBS_DEFAULT_${k#queue_risk.globs.}" ;;
      queue_risk.threshold) d=QR_THRESHOLD_DEFAULT ;;
      queue_risk.size_lines) d=QR_SIZE_LINES_DEFAULT ;;
      queue_risk.size_lines_big) d=QR_SIZE_LINES_BIG_DEFAULT ;;
      queue_risk.size_files) d=QR_SIZE_FILES_DEFAULT ;;
      queue_risk.mode) [ "$v" = shadow ] || echo "mode seed '$v' (want shadow: the back-test routed 76% solo)"; continue ;;
      *) echo "unknown seed $k"; continue ;;
    esac
    [ "${!d-__unset}" = "$v" ] || echo "$k seed '$v' != $d '${!d-__unset}'"
  done <<<"$SEEDS" ) )
[ -z "$DRIFT" ] && ok || bad "seeds: each seed equals the lib's documented fallback: $DRIFT"

# ── the root (D43): an empty root is refused, never a /root/harness default ──
O=$( ( unset HARNESS H; eval "$SETTING_STUB"; . "$QR_LIB"; qr_enqueue_step example-org/cromford 41 "$(printf 'a%.0s' {1..40})" ); echo "rc=$?")
[ "$O" = rc=0 ] && ok || bad "D43 an empty root is a silent rc 0: '$O'"

# ============================================================================
# Q5-Q10: through the real mc_enqueue_mergify
# ============================================================================
SLUG=example-org/cromford
HEAD1=aaaaaaaa11111111111111111111111111111111
HEAD2=bbbbbbbb22222222222222222222222222222222
H="$T/h"; mkdir -p "$H/bin" "$H/logs" "$H/state/merge-conductor" "$H/config/mergify/repos" "$H/tests" "$T/tmp" "$T/fakebin"
G="$T/gh"; mkdir -p "$G"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
# The stub gh: the PR read ($G/labels, $G/title, $G/adds; $G/pr-500 and
# $G/pr-75 force a failed read), its files ($G/files, one per line), the
# status POST, the label POST and the label DELETE. Every call is logged.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$G/calls"
case "\$*" in
  *"-X GET repos/"*"/pulls/"*"/files"*)
    restpr --raw 200 "\$(jq -R -s -c 'split("\n") | map(select(length > 0)) | map({filename: ., additions: 1, deletions: 0})' < "$G/files")" ;;
  *"-X GET repos/"*"/pulls/"[0-9]*)
    [ -f "$G/pr-500" ] && { restpr --raw 500 '{"message":"boom"}'; exit 0; }
    [ -f "$G/pr-75" ] && { restpr --raw 403 '{"message":"API rate limit exceeded"}'; exit 0; }
    restpr --raw 200 "\$(jq -nc --arg t "\$(cat "$G/title" 2>/dev/null || echo 'BH-1: a change')" --arg l "\$(cat "$G/labels" 2>/dev/null)" \
      --argjson a "\$(cat "$G/adds" 2>/dev/null || echo 40)" --argjson n "\$(grep -c . "$G/files")" \
      '{title:\$t, head:{ref:"ticket/bh-1", sha:"x"}, additions:\$a, deletions:0, changed_files:\$n,
        labels:(if \$l == "" then [] else (\$l | split(",") | map({name:.})) end)}')" ;;
  *"-X POST repos/"*"/statuses/"*) restpr --raw 201 '{"id":1}' ;;
  *"-X POST repos/"*"/labels"*) exit 0 ;;
  *"-X DELETE repos/"*"/labels/"*) exit 0 ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

CONF="$H/config/mergify/repos/cromford.conf"
# conf <with|without> — the committed conf minus queue_mode (the partition
# block stays out of this suite's call log), with or without solo_label=.
conf() {
  grep -vE '^(queue_mode|scope_default_capacity|solo_label)=' "$DIR/config/mergify/repos/cromford.conf" > "$CONF"
  [ "$1" = with ] && echo 'solo_label=queue-solo' >> "$CONF"
  return 0
}
U41="https://github.com/$SLUG/pull/41"
JOBS="$T/jobs"
ereset() { rm -f "$G"/* "$JOBS"; scratch_rm "$H/state/merge-conductor/pr-files"; : > "$H/logs/merge-conductor.log"; : > "$ATT"; printf 'docs/a.md\n' > "$G/files"; }
LIBROOT="$DIR"
# enq <head> — the real conductor lib, the real mc_enqueue_mergify. The
# witness/command reads are replaced (this pins the risk block's order and
# writes, not Mergify's answers); setting_get answers from $ROWS and _jobs_req
# records the record POST in $JOBS.
enq() { local head="$1"; (
  export PATH="$T/fakebin:$PATH" HARNESS="$H" TMPDIR="$T/tmp" GH_APP_TOKENS=0
  . "$LIBROOT/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
  mc_mergify_command() { return 0; }
  mc_queue_state() { printf 'queued'; }
  mc_mergify_witness() { return 0; }
  eval "$SETTING_STUB"; eval "$ATT_STUB"
  _jobs_req() { printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$JOBS"; return 0; }
  MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 mc_enqueue_mergify "$SLUG" "$U41" "$head"
) 2>"$T/enq.err"; }
qlog() { grep 'QRISK' "$H/logs/merge-conductor.log"; }
lineof() { grep -n -F -- "$1" "$G/calls" 2>/dev/null | head -1 | cut -d: -f1; }
ncalls() { grep -c . "$G/calls" 2>/dev/null || echo 0; }

# ── Q5: bin/lib + catalog, enforce: queue-solo BEFORE merge-queue ───────────
conf with; ereset; : > "$ROWS"; row queue_risk.mode enforce
printf 'bin/lib/foo.sh\ncatalog/bar.tsv\n' > "$G/files"
OUT=$(enq "$HEAD1"); RC=$?
[ "$RC" = 0 ] && ok || bad "Q5 the enqueue rc is unchanged (rc $RC, out $OUT, err $(cat "$T/enq.err"))"
S=$(lineof 'labels[]=queue-solo'); M=$(lineof 'labels[]=merge-queue')
[ -n "$S" ] && [ -n "$M" ] && [ "$S" -lt "$M" ] && ok || bad "Q5 queue-solo is POSTed before merge-queue (solo line ${S:-none}, merge-queue line ${M:-none}): $(cat "$G/calls")"
[ "$(qlog | grep -c .)" = 1 ] && qlog | grep -q "QRISK $SLUG#41@${HEAD1:0:12} score=55 threshold=50 route=solo mode=enforce reasons=" && ok \
  || bad "Q5 exactly one QRISK line, route=solo mode=enforce: $(cat "$H/logs/merge-conductor.log")"
grep -q '^POST /api/queue-risk ' "$JOBS" 2>/dev/null && ok || bad "Q5 the score is recorded at /api/queue-risk: $(cat "$JOBS" 2>/dev/null)"
J=$(sed -n 's|^POST /api/queue-risk ||p' "$JOBS" 2>/dev/null | head -1)
[ "$(jq -c '[.repo, .pr, .head_sha, .score, .threshold, .route, .mode]' <<<"$J" 2>/dev/null)" = "[\"$SLUG\",41,\"$HEAD1\",55,50,\"solo\",\"enforce\"]" ] \
  && jq -e '.reasons | test("shared_lib:\\+30")' <<<"$J" >/dev/null 2>&1 && ok || bad "Q5 the record body: $J"

# ── Q6: two docs-only PRs batch ─────────────────────────────────────────────
for h in "$HEAD1" "$HEAD2"; do
  ereset; printf 'docs/b.md\ndocs/c.md\n' > "$G/files"
  enq "$h" >/dev/null
  grep -q 'labels\[\]=queue-solo' "$G/calls" && bad "Q6 a docs-only PR never gets queue-solo: $(cat "$G/calls")" || ok
  grep -q 'labels\[\]=merge-queue' "$G/calls" && ok || bad "Q6 a docs-only PR still gets merge-queue"
  qlog | grep -q "QRISK $SLUG#41@${h:0:12} score=0 threshold=50 route=batch mode=enforce" && ok || bad "Q6 the QRISK line says route=batch: $(qlog)"
done

# ── Q7: a row change re-routes on the next enqueue ──────────────────────────
ereset; : > "$ROWS"; row queue_risk.mode enforce; row queue_risk.threshold 50
printf 'bin/lib/foo.sh\ncatalog/bar.tsv\n' > "$G/files"
enq "$HEAD1" >/dev/null
grep -q 'labels\[\]=queue-solo' "$G/calls" && ok || bad "Q7 the first enqueue at threshold 50 POSTs queue-solo: $(cat "$G/calls")"
: > "$ROWS"; row queue_risk.mode enforce; row queue_risk.threshold 90
rm -f "$G/calls"; : > "$H/logs/merge-conductor.log"; echo queue-solo > "$G/labels"
enq "$HEAD1" >/dev/null
grep -q -- '-X DELETE repos/example-org/cromford/issues/41/labels/queue-solo' "$G/calls" && ok \
  || bad "Q7 the second enqueue at threshold 90 DELETEs the stale queue-solo: $(cat "$G/calls")"
grep -q 'labels\[\]=queue-solo' "$G/calls" && bad "Q7 no queue-solo POST at threshold 90" || ok
qlog | grep -q 'score=55 threshold=90 route=batch mode=enforce' && ok || bad "Q7 the second QRISK line says route=batch: $(qlog)"
# a batch-route PR without the label: no DELETE (nothing to remove)
ereset; printf 'docs/a.md\n' > "$G/files"
enq "$HEAD1" >/dev/null
grep -q -- '-X DELETE' "$G/calls" && bad "Q7 no DELETE when the PR carries no queue-solo: $(cat "$G/calls")" || ok

# ── Q8: shadow logs only, off reads nothing, a bogus mode is off ────────────
ereset; : > "$ROWS"; row queue_risk.mode shadow
printf 'bin/lib/foo.sh\ncatalog/bar.tsv\n' > "$G/files"
enq "$HEAD1" >/dev/null
qlog | grep -q 'route=solo mode=shadow (would route solo)' && ok || bad "Q8 shadow says it would route solo: $(qlog)"
grep -q 'labels\[\]=queue-solo' "$G/calls" && bad "Q8 shadow writes no label: $(cat "$G/calls")" || ok
grep -q '^POST /api/queue-risk' "$JOBS" 2>/dev/null && ok || bad "Q8 shadow still records the score"
# shadow with a stale label: shadow never writes a label, not even a DELETE
ereset; echo queue-solo > "$G/labels"; printf 'docs/a.md\n' > "$G/files"
enq "$HEAD1" >/dev/null
grep -q -- '-X DELETE' "$G/calls" && bad "Q8 shadow never DELETEs a label: $(cat "$G/calls")" || ok
ereset; : > "$ROWS"; row queue_risk.mode off
enq "$HEAD1" >/dev/null; RC=$?
N_OFF=$(ncalls)
[ "$RC" = 0 ] && ! grep -q . <<<"$(qlog)" && ok || bad "Q8 mode off logs no QRISK line (rc $RC): $(qlog)"
[ -s "$JOBS" ] && bad "Q8 mode off records nothing: $(cat "$JOBS")" || ok
ereset; : > "$ROWS"; row queue_risk.mode bogus
enq "$HEAD1" >/dev/null; RC=$?
[ "$RC" = 0 ] && ! grep -q . <<<"$(qlog)" && grep -q "queue_risk.mode 'bogus' is not off|shadow|enforce" "$H/logs/merge-conductor.log" && ok \
  || bad "Q8 a bogus mode is off with one log line (rc $RC): $(cat "$H/logs/merge-conductor.log")"
# no row at all is shadow
ereset; : > "$ROWS"; printf 'bin/lib/foo.sh\ncatalog/bar.tsv\n' > "$G/files"
enq "$HEAD1" >/dev/null
qlog | grep -q 'mode=shadow (would route solo)' && ! grep -q 'labels\[\]=queue-solo' "$G/calls" && ok || bad "Q8 no mode row is shadow: $(qlog)"

# ── Q9: an unreadable PR batches; no solo_label= costs zero gh calls ────────
for fail in pr-500 pr-75; do
  ereset; : > "$ROWS"; row queue_risk.mode enforce
  printf 'bin/lib/foo.sh\ncatalog/bar.tsv\n' > "$G/files"; touch "$G/$fail"
  enq "$HEAD1" >/dev/null; RC=$?
  [ "$RC" = 0 ] && ok || bad "Q9 $fail: the enqueue rc is unchanged (rc $RC, err $(cat "$T/enq.err"))"
  qlog | grep -q 'score=- threshold=50 route=batch mode=enforce reasons=files-unavailable' && ok || bad "Q9 $fail: route batch, files-unavailable: $(qlog)"
  grep -qE 'labels\[\]=queue-solo|-X DELETE' "$G/calls" && bad "Q9 $fail: no label write: $(cat "$G/calls")" || ok
  grep -q 'labels\[\]=merge-queue' "$G/calls" && ok || bad "Q9 $fail: the PR still gets merge-queue"
done
# no solo_label= in the conf: no extra gh call against the block deleted
MUT="$T/mut"; mkdir -p "$MUT/bin"
cp -r "$DIR/bin/lib" "$MUT/bin/lib"
grep -q '^  # >>> queue risk (BH-5430)' "$MUT/bin/lib/mc/queue.sh" && ok || bad "Q9 the marked block is in bin/lib/mc/queue.sh"
sed -i '/# >>> queue risk (BH-5430)/,/# <<< queue risk (BH-5430)/d' "$MUT/bin/lib/mc/queue.sh"
conf without; ereset; : > "$ROWS"; row queue_risk.mode enforce
enq "$HEAD1" >/dev/null; N_NOSOLO=$(ncalls)
! grep -q . <<<"$(qlog)" && ok || bad "Q9 no solo_label= logs no QRISK line: $(qlog)"
ereset
LIBROOT="$MUT" enq "$HEAD1" >/dev/null; N_MUT=$(ncalls)
[ "$N_NOSOLO" = "$N_MUT" ] && [ "$N_MUT" -gt 0 ] && ok || bad "Q9 no solo_label= makes zero extra gh calls ($N_NOSOLO vs $N_MUT with the block deleted)"
[ "$N_OFF" = "$N_MUT" ] && ok || bad "Q8 mode off makes zero extra gh calls ($N_OFF vs $N_MUT with the block deleted)"
# the mutation proves the QRISK line comes from the block: deleted, Q5 goes red
conf with; ereset; : > "$ROWS"; row queue_risk.mode enforce; printf 'bin/lib/foo.sh\ncatalog/bar.tsv\n' > "$G/files"
LIBROOT="$MUT" enq "$HEAD1" >/dev/null
! grep -q . <<<"$(qlog)" && ! grep -q 'labels\[\]=queue-solo' "$G/calls" && ok || bad "Q9 with the block deleted there is no QRISK line and no queue-solo"
LIBROOT="$DIR"

# ── Q10: fix-main-red and a train are skipped, with a reason ────────────────
conf with
ereset; : > "$ROWS"; row queue_risk.mode enforce; printf 'bin/lib/foo.sh\ncatalog/bar.tsv\n' > "$G/files"; echo fix-main-red > "$G/labels"
enq "$HEAD1" >/dev/null
qlog | grep -q 'score=- threshold=50 route=batch mode=enforce reasons=fix-main-red' && ok || bad "Q10 a fix-main-red PR is skipped: $(qlog)"
grep -qE 'labels\[\]=queue-solo|-X DELETE' "$G/calls" && bad "Q10 fix-main-red: no label write" || ok
ereset; : > "$ROWS"; row queue_risk.mode enforce; printf 'bin/lib/foo.sh\ncatalog/bar.tsv\n' > "$G/files"
echo 'batch(cromford): land 3 approved siblings as one train' > "$G/title"
enq "$HEAD1" >/dev/null
qlog | grep -q 'route=batch mode=enforce reasons=train' && ok || bad "Q10 a train PR is skipped: $(qlog)"
grep -qE 'labels\[\]=queue-solo|-X DELETE' "$G/calls" && bad "Q10 train: no label write" || ok

# ── size comes from the PR object's additions + deletions ───────────────────
ereset; : > "$ROWS"; row queue_risk.mode shadow; echo 450 > "$G/adds"
enq "$HEAD1" >/dev/null
qlog | grep -q 'score=15 .*size:+15(450 lines)' && ok || bad "size: the PR's 450 added lines are a size hit: $(qlog)"

# ── Q13: the rows are read once per conductor tick ──────────────────────────
conf with; : > "$ROWS"; row queue_risk.mode shadow; SETCNT="$T/setcnt"; export SETCNT
ereset; : > "$SETCNT"; printf 'bin/lib/foo.sh\n' > "$G/files"
MC_TICK_ID=qr-tick-1 enq "$HEAD1" >/dev/null
N1=$(grep -c . "$SETCNT")
ereset; : > "$SETCNT"; printf 'bin/lib/foo.sh\n' > "$G/files"
MC_TICK_ID=qr-tick-1 enq "$HEAD2" >/dev/null
N2=$(grep -c . "$SETCNT")
ereset; : > "$SETCNT"; printf 'bin/lib/foo.sh\n' > "$G/files"
MC_TICK_ID=qr-tick-2 enq "$HEAD1" >/dev/null
N3=$(grep -c . "$SETCNT")
[ "$N1" -ge 22 ] && ok || bad "Q13 the first enqueue of a tick reads the 21 rows and the mode ($N1 reads)"
[ "$N2" = 0 ] && ok || bad "Q13 a second enqueue in the same tick reads no row ($N2 reads: $(sort "$SETCNT" | uniq -c | head -5 | tr '\n' ' '))"
[ "$N3" = "$N1" ] && ok || bad "Q13 a new tick reads the rows again ($N3 reads, want $N1)"
qlog | grep -q "QRISK $SLUG#41@${HEAD1:0:12} score=30 threshold=50 route=batch mode=shadow" && ok || bad "Q13 the cached rows still score: $(qlog)"
unset SETCNT

# ── Q14: enforce, a readable PR with no file list, a stale queue-solo ────────
ereset; : > "$ROWS"; row queue_risk.mode enforce; echo queue-solo > "$G/labels"; : > "$G/files"
enq "$HEAD1" >/dev/null
qlog | grep -q 'route=batch mode=enforce reasons=files-unavailable' && ok || bad "Q14 files-unavailable routes batch: $(qlog)"
grep -q -- '-X DELETE repos/example-org/cromford/issues/41/labels/queue-solo' "$G/calls" && ok \
  || bad "Q14 the stale queue-solo is removed, so the PR does not go solo on an unread file list: $(cat "$G/calls")"
grep -q 'labels\[\]=queue-solo' "$G/calls" && bad "Q14 no queue-solo POST" || ok

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
