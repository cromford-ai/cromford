#!/bin/bash
# tests/blocked-resolver-record-rows.bh-2317-test.sh — BH-2317: the resolver's
# per-ticket record (state/blocked-resolver/<p>/<ck>.json) mirrors its counters
# and its outcome into ledgers(kind=br_record), and br_load restores them when
# the file is gone — so a wiped hub does not run an ABANDONED ladder again and
# tell the client a second time. Also the resolver's re-offer: the blocked row
# is cleared instead of ssh-ing to the owning box, and since BH-2674 the row is
# the only re-offer: no ssh fallback when the DB is down.
#
#   B1  the writers mirror the row: status = outcome (or `open`), detail =
#       the counters, through a REAL tick (the #1634 no-key ladder)
#   B2  the DB down: the file is written, the tick is unchanged, no row
#   B3  br_load with the file gone and the row there: the restored shape
#   B4  a REAL tick on a wiped state dir with the row ABANDONED: nothing is
#       spent, nothing pages, nothing is enqueued — and the control (no row)
#       runs the ladder again, which is the bug
#   B5  the DB down and the file gone: today's zero shape
#   B6  the file present wins over the row (the operator's un-park)
#   B7  a key with no row costs ONE ledger read per tick, not one per br_load
#   A9r/A10r  the box re-offer: row cleared and no ssh; DB down = no ssh
#             either, BR_ENQUEUE_WHY named and the re-offer fails (rc 1)
#
# Run from anywhere: tests/blocked-resolver-record-rows.bh-2317-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
fx_br_harness "$DIR" "$T" || exit 1
[ -d "$DIR/bin/lib/br" ] || exit 1   # impact: this suite runs when bin/lib/br/ changes
mkdir -p "$H/bin/lib" && cp "$DIR/bin/lib/comment-mark.sh" "$H/bin/lib/" || exit 1

# ── the jobs client: queue verbs recorded, ledgers on disk ──────────────────
# rc 0 row, rc 2 no row, rc 1 when $T/db-down exists; every ledger READ is
# counted in $T/ledger-reads.log so B7 can count them.
DB="$T/db"
cat > "$H/bin/jobs-client.sh" <<JC
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
_db() { printf '%s/%s--%s' "$DB" "\$1" "\$(printf '%s' "\$2" | tr -c 'A-Za-z0-9._-' _)"; }
job_ledger_row() { printf '%s %s\n' "\$1" "\$2" >> "$T/ledger-reads.log"
  [ -e "$T/db-down" ] && return 1; [ -f "\$(_db "\$1" "\$2")" ] || return 2; cat "\$(_db "\$1" "\$2")"; }
job_ledger_get() { local r; r=\$(job_ledger_row "\$@") || return \$?; printf '%s' "\$r" | jq -r .status; }
job_ledger_put() {
  [ -e "$T/db-down" ] && return 1
  local f d="\${4:-}"; f=\$(_db "\$1" "\$2"); mkdir -p "$DB"
  [ -z "\$d" ] && [ -f "\$f" ] && d=\$(jq -r .detail "\$f")
  jq -nc --arg s "\$3" --arg d "\$d" '{status:\$s,detail:\$d}' > "\$f"
}
JC
row()    { cat "$DB/$1--$(printf '%s' "$2" | tr -c 'A-Za-z0-9._-' _)" 2>/dev/null; }
rowst()  { row "$@" | jq -r .status 2>/dev/null; }
rowdet() { row "$1" "$2" | jq -r ".detail | fromjson | .$3" 2>/dev/null; }

# The #1634 shape (tests/br-rebuild-outcome-test.sh 9a): a park whose ticket key
# cannot be derived, refused three times and then ABANDONED. Its gh stub.
cat > "$T/fakebin/gh" <<EOF2
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
case "\$*" in
  *"-i -X "*) GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"pr close"*) printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"issue comment"*|*"pr comment"*) printf '%s\n' "\$*" >> "$T/comments.txt"; exit 0 ;;
  *"--json state"*) cat "$T/prstate" 2>/dev/null || echo OPEN ;;
  *"/pulls/"*) _h=\$(<"$T/prhead"); _b=\$(<"$T/prbranch"); echo "\${_h:-null} \${_b:-null}" ;;
  *"--json headRefOid,headRefName"*) echo "\$(cat "$T/prhead") \$(cat "$T/prbranch")" ;;
  *"--json headRefName"*) cat "$T/prbranch" ;;
  *"--json headRefOid"*)  cat "$T/prhead" ;;
  *"--json title"*)       cat "$T/prtitle" 2>/dev/null ;;
  *"pr list"*) : ;;
  *) echo "" ;;
esac
exit 0
EOF2
chmod +x "$T/fakebin/gh"
nokey_setup() {
  scratch_rm "$H/state/blocked-resolver"; scratch_rm "$DB"; rm -f "$T/db-down"
  : > "$T/prtitle"; : > "$T/mergedprs"; : > "$T/comments.txt"; : > "$T/comment-bodies.txt"
  touch "$H/flags/fly-pool-tproj"
  : > "$H/state/merge-conductor/pr-state.tsv"
  printf 'feature/x' > "$T/prbranch"; : > "$T/prhead"; echo OPEN > "$T/prstate"
  SPENT o-tproj-1634
  ROW "o/tproj#1634" "conflict-unresolvable: CONFLICT (content): src/a.ts" "https://github.com/o/tproj/pull/1634"
  : > "$T/queue.txt"; : > "$T/closed.txt"; : > "$T/lane-alert.txt"; : > "$H/logs/ALERTS.log"
}
K=tproj/o-tproj-1634

# ── B1 — the writers mirror the row ──────────────────────────────────────────
nokey_setup
RUN
[ "$(rowst br_record $K)" = open ] && ok || bad "B1: a record with no outcome must mirror status open (got '$(rowst br_record $K)')"
[ "$(rowdet br_record $K rebuilds)" = 1 ] && ok || bad "B1: the row must carry rebuilds=1 after one refusal: $(row br_record $K)"
[ "$(rowdet br_record $K mechanicals)" = 1 ] && [ "$(rowdet br_record $K fixrounds)" = 1 ] && ok \
  || bad "B1: the row must carry every counter the record holds: $(row br_record $K)"
RUN; RUN
[ "$(STATEJSON o-tproj-1634 | jq -r .outcome)" = ABANDONED ] && ok || bad "B1: fixture — the third refusal must ABANDON"
[ "$(rowst br_record $K)" = ABANDONED ] && ok || bad "B1: the ABANDONED outcome must reach the row (got '$(rowst br_record $K)')"
[ "$(rowdet br_record $K rebuilds)" = 3 ] && ok || bad "B1: the row must carry rebuilds=3: $(row br_record $K)"
[ -n "$(rowdet br_record $K first_seen)" ] && ok || bad "B1: the row must carry first_seen"

# ── B4 — a wiped state dir, the row ABANDONED: the ladder does not run again ──
# The conductor still names the park (ROW again): a wiped hub whose record is
# gone would otherwise meet it as a brand-new park with every counter at zero.
ALERTS0=$(grep -c 'ABANDONED tproj/o-tproj-1634' "$H/logs/ALERTS.log")
scratch_rm "$H/state/blocked-resolver"
ROW "o/tproj#1634" "conflict-unresolvable: CONFLICT (content): src/a.ts" "https://github.com/o/tproj/pull/1634"
: > "$T/lane-alert.txt"; : > "$T/queue.txt"; : > "$T/closed.txt"; : > "$T/comments.txt"; : > "$T/ledger-reads.log"
RUN
[ "$(STATEJSON o-tproj-1634 | jq -s '(.[0].attempts // []) | length')" = 0 ] && ok \
  || bad "B4: a wiped hub must spend NO rung on an ABANDONED ticket: $(STATEJSON o-tproj-1634 | jq -c '.attempts')"
[ ! -s "$T/lane-alert.txt" ] && ok || bad "B4: a wiped hub must not page again for an ABANDONED ticket: $(cat "$T/lane-alert.txt")"
[ "$(grep -c 'ABANDONED tproj/o-tproj-1634' "$H/logs/ALERTS.log")" = "$ALERTS0" ] && ok \
  || bad "B4: a wiped hub must not write a second ABANDONED line"
[ ! -s "$T/queue.txt" ] && [ ! -s "$T/closed.txt" ] && [ ! -s "$T/comments.txt" ] && ok \
  || bad "B4: a wiped hub must not enqueue, close or comment: $(cat "$T/queue.txt" "$T/closed.txt" "$T/comments.txt")"
[ "$(rowst br_record $K)" = ABANDONED ] && ok || bad "B4: the row must still say ABANDONED after the tick"
grep -qx "br_record $K" "$T/ledger-reads.log" && ok || bad "B4: fixture — the tick must have reached the park and asked for its row"
# B4 control — the same wipe with NO row is the bug the ticket names: the park
# is met as new and a rung is spent on it again. It is what makes the case
# above about the restore rather than about the fixture.
scratch_rm "$H/state/blocked-resolver"; scratch_rm "$DB"
ROW "o/tproj#1634" "conflict-unresolvable: CONFLICT (content): src/a.ts" "https://github.com/o/tproj/pull/1634"
RUN
[ "$(STATEJSON o-tproj-1634 | jq -s '(.[0].attempts // []) | length')" -ge 1 ] 2>/dev/null && ok \
  || bad "B4 control: without the row a wiped hub runs the ladder again: $(STATEJSON o-tproj-1634 | jq -c '.attempts')"

# ── B2 — the DB down: the file is written, no row ───────────────────────────
nokey_setup; touch "$T/db-down"
RUN
[ "$(STATEJSON o-tproj-1634 | jq -r .rebuilds)" = 1 ] && ok || bad "B2: with the DB down the record must still be written"
[ -z "$(row br_record $K)" ] && ok || bad "B2: with the DB down there is no row"
rm -f "$T/db-down"

# ── B3/B5/B6/B7 — br_load, lifted out of the lane ───────────────────────────
fn_body() {
  awk -v P="$2() {" '
    !f && substr($0, 1, length(P)) == P && /\}[[:space:]]*$/ { print; exit }
    substr($0, 1, length(P)) == P    { f=1 }
    f                                { print }
    f && /^\}$/                      { exit }' "$1"
}
# BH-5241: the corpus is the driver plus bin/lib/br/*.sh (tests/lib/br-corpus.sh),
# because the record functions moved out of the driver into bin/lib/br/record.sh.
# shellcheck source=tests/lib/br-corpus.sh
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$DIR" "$T/br-corpus.sh" || exit 1
for fn in br_file br_load; do fn_body "$T/br-corpus.sh" "$fn"; done > "$T/brload.sh"
grep -q '^br_load()' "$T/brload.sh" && ok || bad "B3: could not lift br_load"
bl() { # bl <key> — br_load's answer, with the lane's globals
  ( ST="$T/st"; STAMP() { echo 2026-09-25T00:00:00Z; }; . "$H/bin/jobs-client.sh"; . "$T/brload.sh"
    BR_ROW_MISS="$T/miss"; br_load tproj "$1" )
}
scratch_rm "$DB"; mkdir -p "$DB" "$T/st/tproj"; rm -f "$T/miss"
printf '%s' '{"status":"ABANDONED","detail":"{\"rebuilds\":3,\"fixrounds\":2,\"mechanicals\":1,\"regens\":0,\"adjudications\":1,\"rereviews\":0,\"first_seen\":\"2026-09-01 00:00:00Z\"}"}' \
  > "$DB/br_record--tproj_k1"
OUT=$(bl k1)
[ "$(jq -r .outcome <<<"$OUT")" = ABANDONED ] && ok || bad "B3: the file gone, br_load must restore the outcome: $OUT"
[ "$(jq -r .rebuilds <<<"$OUT")" = 3 ] && [ "$(jq -r .fixrounds <<<"$OUT")" = 2 ] && ok || bad "B3: br_load must restore the counters: $OUT"
[ "$(jq -r .restored <<<"$OUT")" = ledger ] && ok || bad "B3: a restored record must say restored:ledger: $OUT"
[ "$(jq -r .first_seen <<<"$OUT")" = "2026-09-01 00:00:00Z" ] && ok || bad "B3: first_seen comes from the row: $OUT"
[ "$(jq -c .attempts <<<"$OUT")" = '[]' ] && [ "$(jq -r .rkey <<<"$OUT")" = k1 ] && ok || bad "B3: the restored shape is br_load's fresh shape: $OUT"
printf '%s' '{"status":"open","detail":"{\"rebuilds\":1}"}' > "$DB/br_record--tproj_k2"
[ "$(bl k2 | jq -r .outcome)" = "" ] && ok || bad "B3: status open restores as an empty outcome"
# B5 — the DB down and the file gone: the zero shape
touch "$T/db-down"
OUT=$(bl k1)
[ "$(jq -r .outcome <<<"$OUT")" = "" ] && [ "$(jq -r .rebuilds <<<"$OUT")" = 0 ] && [ "$(jq -r '.restored // "none"' <<<"$OUT")" = none ] && ok \
  || bad "B5: an outage must give today's zero shape: $OUT"
rm -f "$T/db-down"
# B6 — the file wins
printf '%s\n' '{"project":"tproj","rkey":"k1","rebuilds":3,"outcome":"","attempts":[]}' > "$T/st/tproj/k1.json"
[ "$(bl k1 | jq -r .outcome)" = "" ] && ok || bad "B6: a record file on disk must win over the row (the operator's un-park)"
# B7 — a key with no row: one read, however many loads
rm -f "$T/miss"; : > "$T/ledger-reads.log"
( ST="$T/st"; STAMP() { echo x; }; . "$H/bin/jobs-client.sh"; . "$T/brload.sh"; BR_ROW_MISS="$T/miss"
  for i in 1 2 3 4 5; do x=$(br_load tproj nokey); done )
[ "$(grep -c 'br_record tproj/nokey' "$T/ledger-reads.log")" = 1 ] && ok \
  || bad "B7: a key with no row must be read once per tick, got $(grep -c 'br_record tproj/nokey' "$T/ledger-reads.log")"

# ── A9r/A10r — the resolver's re-offer of a box project ─────────────────────
reoffer() {
  scratch_rm "$H/state/blocked-resolver"; rm -f "$H/flags/fly-pool-tproj"
  : > "$T/ssh.txt"; : > "$T/queue.txt"
  printf 'ticket/TK-9' > "$T/prbranch"; printf 'TK-9: a thing' > "$T/prtitle"
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$T/prhead"
  ROW "o/tproj#11" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/11"
  RUN
}
scratch_rm "$DB"; rm -f "$T/db-down"
reoffer
[ "$(rowst commented 'blocked tproj TK-9')" = cleared ] && ok \
  || bad "A9r: the resolver's re-offer must clear the blocked row: $(row commented 'blocked tproj TK-9'); $(grep 'TK-9' "$H/logs/blocked-resolver.log" | tail -3)"
grep -q 'blocked-commented' "$T/ssh.txt" && bad "A9r: a re-offer the DB took must not ssh to the box: $(cat "$T/ssh.txt")" || ok
grep -q 'cleared row commented' "$H/logs/blocked-resolver.log" && ok || bad "A9r: the success line must name the row"
scratch_rm "$DB"; touch "$T/db-down"; : > "$H/logs/blocked-resolver.log"
reoffer
[ -s "$T/ssh.txt" ] && bad "A10r: with the DB down the re-offer must NOT ssh to the box (BH-2674): $(cat "$T/ssh.txt")" || ok
grep -q 'the jobs DB did not take the cleared row for TK-9' "$H/logs/blocked-resolver.log" && ok \
  || bad "A10r: the failed re-offer must name BR_ENQUEUE_WHY: $(grep TK-9 "$H/logs/blocked-resolver.log" | tail -3)"
grep -q 'cleared row commented' "$H/logs/blocked-resolver.log" && bad "A10r: an unwritten row is not a success line" || ok
rm -f "$T/db-down"

echo "blocked-resolver-record-rows.bh-2317-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
