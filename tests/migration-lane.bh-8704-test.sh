#!/bin/bash
# tests/migration-lane.bh-8704-test.sh — BH-8704: the hub migration lane
# (bin/migration-lane.sh + bin/lib/migration-lane.sh), select, gates, switches and dispatch.
# The fixture (scratch harness, jobs worker, seams, newp/mkpr/run) is
# tests/lib/migration-lane.bh-8704.sh. The suite is split in two so each file
# ends well inside the fixture worker's 180 s life.
#
#   E1  3 ready PRs -> 1 batch PR, 1 CI target, apply order a b c, merges a b c
#   B1  a PR that conflicts with main is dropped, the others land
#   B2  two members add the same file with the same bytes: both kept
#   S1  gate passes: box APPROVE, box BLOCK on an OLD head, a comment-only CONCURRENTLY
#   S2  ci pending / none -> skipped
#   S3  no lead MERGE -> skipped
#   S4  lead MERGE + box BLOCK on the head -> skipped, no merge
#   S5  CHANGES_REQUESTED -> skipped     S6  human BLOCK comment -> skipped
#   S7  CONCURRENTLY (upper, lower) and mk:concurrent-index -> skipped, 1 comment,
#       1 warn alert each; a second tick posts 0 more
#   S11 the S7 comment's promise holds: once production lists the concurrent
#       file applied with the staged checksum, the next tick merges the PR; a
#       file applied under another checksum stays refused (no second comment)
#   S8  conductor row hold / none / clear for another head -> skipped; box rc 2 -> skipped
#   S9  7 ready -> 6 in the batch; a batch_max row of 2 -> 2
#   S10 a non-migration PR: no call on it after the files read; a draft: skipped
#   L1  flags/lane-off-migration, flags/automerge-disabled[-<p>] -> 0 seam calls
#   L3  H and HARNESS empty -> ml_tick refuses, no /logs or /state path
#   X   every exit path releases the lease; 0 gh calls and only 127.0.0.1 curls
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/migration-lane.bh-8704-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# shellcheck source=tests/lib/migration-lane.bh-8704.sh
. "$(dirname "$0")/lib/migration-lane.bh-8704.sh" || exit 1
# The entry point under test (the fixture installs it into $H; this suite names it).
[ -x "$DIR/bin/migration-lane.sh" ] && [ -r "$DIR/bin/lib/migration-lane.sh" ] || { echo "setup: $DIR/bin/migration-lane.sh missing"; exit 1; }

# ============================================================================
echo "E1: 3 ready PRs -> one batch, one CI, apply in order, 3 merges"
newp e1
mkpr 13 prisma/sql/20261028120000_c.sql "CREATE TABLE c (id int);"
mkpr 12 prisma/sql/20261028110000_b.sql "CREATE TABLE b (id int);"
mkpr 11 prisma/sql/20261028100000_a.sql "CREATE TABLE a (id int);"
run "$P"
[ "$(calls pr_create)" = 1 ] && ok "E1 exactly one batch PR" || bad "E1 pr_create $(calls pr_create): $(cat "$C/run.out")"
BT=$(grep '^ci ' "$C/calls" | awk '{print $2}' | grep -vxF -e "$HEAD_11" -e "$HEAD_12" -e "$HEAD_13" | sort -u)
[ "$(printf '%s\n' "$BT" | grep -c .)" = 1 ] && ok "E1 one CI target sha (the batch head)" || bad "E1 CI targets: $BT"
[ "$(tr '\n' ' ' < "$C/apply-order" 2>/dev/null)" = "20261028100000_a.sql 20261028110000_b.sql 20261028120000_c.sql " ] \
  && ok "E1 apply order a b c" || bad "E1 apply order: $(cat "$C/apply-order" 2>/dev/null)"
[ "$(merges)" = "11 12 13" ] && ok "E1 merges in order a b c" || bad "E1 merges: $(merges)"
grep -q "^merge 11 $HEAD_11$" "$C/calls" && ok "E1 merge bound to the staged head" || bad "E1 merge sha: $(grep '^merge' "$C/calls")"
[ "$(lg | grep -cE '#1[123] applied prisma/sql/')" = 3 ] && ok "E1 three #N applied lines" || bad "E1 applied lines: $(lg)"
[ "$(lg | grep -cE '#1[123] merged mergesha1[123]$')" = 3 ] && ok "E1 three #N merged lines" || bad "E1 merged lines: $(lg)"
[ "$(ledger_get migration-lane "batch $P" | cut -d' ' -f1)" = done ] && ok "E1 ledger batch = done" || bad "E1 ledger: $(ledger_get migration-lane "batch $P")"
[ "$(calls 'pr_close 900')" = 1 ] && ok "E1 batch PR closed" || bad "E1 close: $(grep pr_close "$C/calls")"
[ -z "$(git -C "$C/origin.git" for-each-ref refs/heads/migration-lane)" ] && ok "E1 batch branch deleted" || bad "E1 branch left: $(git -C "$C/origin.git" for-each-ref refs/heads/migration-lane)"
grep -q 'Never merge it' "$C/batch-body-900.md" && grep -q '^Parked: ' "$C/batch-body-900.md" && ok "E1 batch body: never merge, parked" || bad "E1 body: $(cat "$C/batch-body-900.md")"
[ "$(grep -c '^comment 1[123] Merged by the migration lane' "$C/calls")" = 3 ] && ok "E1 one comment per member" || bad "E1 member comments: $(grep comment "$C/calls")"
lease_free "$P" && ok "E1 lease released" || bad "E1 lease still held"
[ -z "$(ls "$H/state/migration-lane/$P" | grep '^wt-')" ] && ok "E1 batch worktree removed" || bad "E1 worktree left"
[ "$(calls alert)" = 0 ] && ok "E1 no alert" || bad "E1 alerts: $(cat "$C/alerts")"

# ============================================================================
echo "B1: a PR that conflicts with main is dropped, the others land"
newp b1
mkpr 21 prisma/sql/20261028100000_a.sql "CREATE TABLE a (id int);"
mkpr 22 prisma/sql/20261028110000_b.sql "CREATE TABLE b (id int);" README.md "line one changed by the PR"
mkpr 23 prisma/sql/20261028120000_c.sql "CREATE TABLE c (id int);"
git -C "$C/seed" pull -q "$C/origin.git" main
printf 'line one changed on main\nline two\n' > "$C/seed/README.md"
git -C "$C/seed" commit -qam "main edits readme" && git -C "$C/seed" push -q "$C/origin.git" main
run "$P"
lg | grep -q '#22 dropped: conflicts with main or an earlier member' && ok "B1 #22 dropped" || bad "B1 log: $(lg)"
[ "$(merges)" = "21 23" ] && ok "B1 #21 and #23 merged, no merge for #22" || bad "B1 merges: $(merges)"
grep -q '#22 applied' <<<"$(lg)" && bad "B1 #22 applied" || ok "B1 #22 not applied"

echo "B2: two members add the same file with identical bytes: both kept"
newp b2
mkpr 31 prisma/sql/20261028100000_a.sql "CREATE TABLE a (id int);" docs/shared.md "same bytes"
mkpr 32 prisma/sql/20261028110000_b.sql "CREATE TABLE b (id int);" docs/shared.md "same bytes"
run "$P"
[ "$(merges)" = "31 32" ] && ok "B2 both merged" || bad "B2 merges: $(merges) $(lg)"

# ============================================================================
echo "S1: the gates that must pass"
newp s1
mkpr 41 prisma/sql/20261028100000_a.sql "CREATE TABLE a (id int);"
mkpr 42 prisma/sql/20261028110000_b.sql "-- CONCURRENTLY is not used here
CREATE INDEX b_i ON base (id);"
mkpr 43 prisma/sql/20261028120000_c.sql "CREATE TABLE c (id int);"
echo APPROVE > "$C/box/$HEAD_41"
echo BLOCK > "$C/box/0000000000000000000000000000000000000043"   # a BLOCK on another head
run "$P"
[ "$(merges)" = "41 42 43" ] && ok "S1 box APPROVE, an old-head BLOCK and a comment-only CONCURRENTLY all pass" || bad "S1 merges: $(merges) $(lg)"

echo "S2-S6: the gates that must exclude"
newp s2
mkpr 51 prisma/sql/20261028100000_a.sql "CREATE TABLE a (id int);"       # ci pending
mkpr 52 prisma/sql/20261028100100_b.sql "CREATE TABLE b (id int);"       # ci none
mkpr 53 prisma/sql/20261028100200_c.sql "CREATE TABLE c (id int);"       # no lead MERGE
mkpr 54 prisma/sql/20261028100300_d.sql "CREATE TABLE d (id int);"       # lead MERGE + box BLOCK
mkpr 55 prisma/sql/20261028100400_e.sql "CREATE TABLE e (id int);"       # CHANGES_REQUESTED
mkpr 56 prisma/sql/20261028100500_f.sql "CREATE TABLE f (id int);"       # human BLOCK comment
mkpr 57 prisma/sql/20261028100600_g.sql "CREATE TABLE g (id int);"       # the control: lands
echo pending > "$C/ci/$HEAD_51"; echo none > "$C/ci/$HEAD_52"
touch "$C/nolead/53"; echo BLOCK > "$C/box/$HEAD_54"; touch "$C/cr/55"
printf 'https://example.invalid/c/1\tsomeone\t2026-10-28T00:00:00Z\t1' > "$C/block/56"
run "$P"
for n in 51 52 53 54 55 56; do grep -q "^merge $n " "$C/calls" && bad "S2 #$n merged"; done
[ "$(merges)" = 57 ] && ok "S2 only the control #57 merged" || bad "S2 merges: $(merges)"
lg | grep -q '#51 skipped: ci pending' && lg | grep -q '#52 skipped: ci none' && ok "S2 ci pending and none skipped" || bad "S2 ci: $(lg)"
lg | grep -q '#53 skipped: no lead or human MERGE' && ok "S3 no lead MERGE skipped" || bad "S3: $(lg)"
lg | grep -q '#54 skipped: box BLOCK' && ok "S4 lead MERGE + box BLOCK skipped" || bad "S4: $(lg)"
lg | grep -q '#55 skipped: CHANGES_REQUESTED standing' && ok "S5 CHANGES_REQUESTED skipped" || bad "S5: $(lg)"
lg | grep -q '#56 skipped: human or lead BLOCK' && ok "S6 BLOCK comment skipped" || bad "S6: $(lg)"

echo "S7: concurrent-index migrations are refused and reported once"
newp s7
mkpr 61 prisma/sql/20261028100000_a.sql "CREATE INDEX CONCURRENTLY a_i ON base (id);"
mkpr 62 prisma/sql/20261028100100_b.sql "create index concurrently b_i on base (id);"
mkpr 63 prisma/sql/20261028100200_c.sql "-- mk:concurrent-index
CREATE INDEX c_i ON base (id);"
run "$P"
for n in 61 62 63; do
  lg | grep -q "#$n skipped: concurrent index" && [ "$(grep -c "^comment $n " "$C/calls")" = 1 ] \
    && [ "$(grep -c "^alert warn migration-lane-$P-$n-concurrent" "$C/calls")" = 1 ] \
    && ok "S7 #$n refused, 1 comment, 1 warn alert" || bad "S7 #$n: $(lg | grep "#$n"); $(grep "$n" "$C/calls")"
done
[ "$(calls pr_create)" = 0 ] && ok "S7 no batch" || bad "S7 batch formed"
grep -q 'npm run db:apply' "$C/comments" && ok "S7 the comment names the operator step" || bad "S7 comment text"
run "$P"
[ "$(calls comment)" = 3 ] && [ "$(calls alert)" = 3 ] && ok "S7 a second tick posts 0 more" || bad "S7 second tick: $(calls comment) comments $(calls alert) alerts"

echo "S11: the concurrent-index comment tells the truth about the next tick"
newp s11
mkpr 64 prisma/sql/20261028100000_a.sql "CREATE INDEX CONCURRENTLY a_i ON base (id);"
mkpr 65 prisma/sql/20261028100100_b.sql "CREATE INDEX CONCURRENTLY b_i ON base (id);"
run "$P"
[ "$(calls merge)" = 0 ] && [ "$(calls pr_create)" = 0 ] && ok "S11 tick 1: refused, no batch" || bad "S11 tick 1: $(merges) $(lg)"
grep -qF 'the lane merges this PR' "$C/comments" && ok "S11 the comment says the lane merges it after the operator step" || bad "S11 comment: $(cat "$C/comments")"
# The operator applies #64's file as staged. #65's file is in production under other bytes.
SA=$(git -C "$C/w-64" show HEAD:prisma/sql/20261028100000_a.sql | sha256sum | cut -d' ' -f1)
grep -qF "${HEAD_64:0:12}" "$C/comments" && grep -qF 'migrations/status' "$C/comments" && ok "S11 the comment names the head and the status proof" || bad "S11 comment detail: $(cat "$C/comments")"
jq --arg s "$SA" '.applied += [{filename: "20261028100000_a.sql", checksum: $s}, {filename: "20261028100100_b.sql", checksum: "deadbeef"}]' "$C/status.json" > "$C/st.t" && mv "$C/st.t" "$C/status.json"
run "$P"
[ "$(merges)" = 64 ] && grep -q "^merge 64 $HEAD_64$" "$C/calls" && ok "S11 tick 2: the applied PR merges at its head, as the comment says" || bad "S11 tick 2 merges: $(merges) $(lg | tail -6)"
grep -q 20261028100000_a "$C/apply-order" 2>/dev/null && bad "S11 the lane ran the concurrent file" || ok "S11 the lane did not run the concurrent file itself"
lg | grep -q '#65 skipped: concurrent index' && ok "S11 another checksum in production stays refused" || bad "S11 #65: $(lg | grep '#65')"
[ "$(grep -c '^comment 65 ' "$C/calls")" = 1 ] && [ "$(grep -c '^comment 64 The migration lane will not' "$C/calls")" = 1 ] && ok "S11 no second operator comment on the same head" || bad "S11 comments: $(grep '^comment' "$C/calls")"

echo "S8: conductor verdict and an unreadable box verdict"
newp s8
mkpr 71 prisma/sql/20261028100000_a.sql "CREATE TABLE a (id int);"
NOCV=1 mkpr 72 prisma/sql/20261028100100_b.sql "CREATE TABLE b (id int);"
mkpr 73 prisma/sql/20261028100200_c.sql "CREATE TABLE c (id int);"
mkpr 74 prisma/sql/20261028100300_d.sql "CREATE TABLE d (id int);"
mkpr 75 prisma/sql/20261028100400_e.sql "CREATE TABLE e (id int);"
ledger_put mc-merge-verdict "$(SLUG)#71" hold "$HEAD_71 iron-law hit"
ledger_put mc-merge-verdict "$(SLUG)#73" clear "0123456789abcdef0123456789abcdef01234567 clean"
echo rc2 > "$C/box/$HEAD_74"
run "$P"
[ "$(merges)" = 75 ] && ok "S8 only #75 merged" || bad "S8 merges: $(merges) $(lg)"
lg | grep -q '#71 skipped: no conductor clear verdict' && ok "S8 conductor hold skipped" || bad "S8 hold: $(lg)"
lg | grep -q '#72 skipped: no conductor clear verdict' && ok "S8 no clear row skipped" || bad "S8 none: $(lg)"
lg | grep -q '#73 skipped: no conductor clear verdict' && ok "S8 clear row for another head skipped" || bad "S8 other head: $(lg)"
lg | grep -q '#74 skipped: box verdict unreadable' && ok "S8 box rc 2 skipped" || bad "S8 rc2: $(lg)"

echo "S9: batch_max"
newp s9
for i in 1 2 3 4 5 6 7; do mkpr "8$i" "prisma/sql/2026102810000${i}_m$i.sql" "CREATE TABLE m$i (id int);"; done
run "$P"
[ "$(calls pr_create)" = 1 ] && [ "$(merges)" = "81 82 83 84 85 86" ] && ok "S9 7 ready -> 6 in the batch (default)" || bad "S9 merges: $(merges)"
newp s9b
for i in 1 2 3; do mkpr "9$i" "prisma/sql/2026102810000${i}_n$i.sql" "CREATE TABLE n$i (id int);"; done
setting "lane.migration.$P.batch_max" 2
run "$P"
[ "$(merges)" = "91 92" ] && ok "S9 a batch_max row of 2 -> 2 in the batch" || bad "S9b merges: $(merges) $(cat "$C/run.out")"

echo "S10: a non-migration PR and a draft"
newp s10
mkpr 101 src/app.ts "export const x = 1;"
mkpr 102 prisma/sql/20261028100000_a.sql "CREATE TABLE a (id int);" --draft
mkpr 103 prisma/sql/20261028100100_b.sql "CREATE TABLE b (id int);"
run "$P"
[ -z "$(grep -E '^(ci|lead|box|block|cr|merge|comment|pr_head) 101( |$)' "$C/calls")" ] && grep -q '^pr_files 101' "$C/calls" \
  && ok "S10 the non-migration PR: files read, nothing else" || bad "S10 #101 calls: $(grep 101 "$C/calls")"
grep -q '^pr_files 102' "$C/calls" && bad "S10 the draft was read" || ok "S10 the draft is not read"
[ "$(merges)" = 103 ] && ok "S10 only #103 merged" || bad "S10 merges: $(merges)"

echo "X1: an incomplete PR list forms no batch"
newp x1
mkpr 111 prisma/sql/20261028100000_a.sql "CREATE TABLE a (id int);"
touch "$C/list_fail"
run "$P"
[ "$(calls pr_create)" = 0 ] && lg | grep -q 'incomplete PR list' && ok "X1 no batch from a partial list" || bad "X1: $(lg)"
lease_free "$P" && ok "X1 lease released" || bad "X1 lease held"

# ============================================================================
echo "L1: the switches"
newp l1
mkpr 121 prisma/sql/20261028100000_a.sql "CREATE TABLE a (id int);"
touch "$H/flags/lane-off-migration"
LGD=0 run "$P"
rm -f "$H/flags/lane-off-migration"
[ ! -s "$C/calls" ] && ok "L1 lane-off-migration: 0 seam calls" || bad "L1 calls: $(cat "$C/calls")"
touch "$H/flags/automerge-disabled"; run "$P"; rm -f "$H/flags/automerge-disabled"
[ ! -s "$C/calls" ] && ok "L1 automerge-disabled: 0 seam calls" || bad "L1 automerge calls: $(cat "$C/calls")"
touch "$H/flags/automerge-disabled-$P"; run "$P"; rm -f "$H/flags/automerge-disabled-$P"
[ ! -s "$C/calls" ] && lg | grep -q "skipped: flags/automerge-disabled-$P" && ok "L1 automerge-disabled-<p>: skipped" || bad "L1 project flag: $(cat "$C/calls")"

echo "L3: an empty harness root is refused, not read as /"
L3OUT=$(cd "$T" && env -u HARNESS H="" bash -c '. "$1/bin/lib/migration-lane.sh"; P=mk-l3; ml_tick; echo "rc=$?"' _ "$DIR" 2>&1)
grep -q 'HARNESS and H are empty; refusing to run' <<<"$L3OUT" && grep -q 'rc=0' <<<"$L3OUT" && ok "L3 ml_tick refuses with H empty" || bad "L3: $L3OUT"
[ ! -e /logs/migration-lane.log ] && ok "L3 no /logs file" || bad "L3 wrote /logs/migration-lane.log"

echo "X: no vendor call"
[ ! -s "$T/gh.log" ] && ok "X 0 gh calls" || bad "X gh calls: $(head -3 "$T/gh.log")"
OFFBOX=$(grep -vE '^https?://127\.0\.0\.1:' "$T/curl-hosts.log")
[ -n "$OFFBOX" ] && bad "X a curl left 127.0.0.1: $(grep -vE '127\.0\.0\.1' "$T/curl-hosts.log" | head -3)" || ok "X every curl went to 127.0.0.1"

echo "migration-lane.bh-8704: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
