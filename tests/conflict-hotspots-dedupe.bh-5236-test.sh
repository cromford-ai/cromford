#!/bin/bash
# tests/conflict-hotspots-dedupe.bh-5236-test.sh — BH-5236: bin/conflict-hotspots.sh
# counts each sync merge once, skips mergify and stale refs, and prints its
# dates under both GNU and BSD `date`.
#
# Driven, not grepped: every case runs the shipped bin/conflict-hotspots.sh (and
# D6 the shipped bin/conflict-hotspots-fleet.sh) against fixture repos built
# here with real `git merge`, the tests/conflict-hotspots.bh-4986-test.sh way.
#   D1 one conflicted sync merge reachable from 4 refs counts once, owned by
#      the real branch, with --include-mergify.
#   D2 two refs with the same tip sha: one tip replay.
#   D3 mergify/* refs are skipped by default and counted in the footer; the
#      fleet lane's footer() sed still reads the keys it stores.
#   D4 a local ref the remote no longer has is skipped (one ls-remote);
#      --no-remote-check scans it; a remote that cannot be listed is rc 4.
#   D5 the ISO labels print under a GNU-form and a BSD-form `date`.
#   D6 the fleet lane's fetch prunes a branch deleted on origin.
#   D7 names that only look like mergify (mergifyish, feat/mergify/x,
#      ticket/mergify-fix) are scanned.
#
# The clock is a fixed epoch: every commit date is derived from NOW and the CLI
# is always called with --now "$NOW".
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/conflict-hotspots-dedupe.bh-5236-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
CLI="$DIR/bin/conflict-hotspots.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

NOW=1791335073
mkdir -p "$T/tmp"
export TMPDIR="$T/tmp"

# at <days-ago> <git args...>: run git in $R with both dates pinned.
at() {
  local d=$1; shift
  GIT_AUTHOR_DATE="@$((NOW - d*86400)) +0000" GIT_COMMITTER_DATE="@$((NOW - d*86400)) +0000" \
    git -C "$R" "$@" >/dev/null 2>&1
}
newrepo() {
  R=$1
  git init -q -b main "$R"
  git -C "$R" config user.name fixture
  git -C "$R" config user.email fixture@example.invalid
  git -C "$R" config commit.gpgsign false
}
SYNC="Merge remote-tracking branch 'origin/main' into HEAD"
run() { OUT=$("$CLI" "$@" 2>"$T/err"); RC=$?; }
row() { printf '%s\n' "$OUT" | awk -F'\t' -v p="$1" '$1 == p'; }
field() { row "$1" | cut -f"$2"; }
foot() { printf '%s\n' "$OUT" | sed -n '/^# ref=/{s/.* '"$1"'=\([^ ]*\).*/\1/p;q}'; }
# tipconflict <name> <days-ago>: a branch off base that edits cold.txt, which
# main also edited at d8, so its tip conflicts with main as it stood then.
tipconflict() {
  at "$2" checkout -q -b "$1" base; echo "$1" >> "$R/cold.txt"; at "$2" commit -q -am "$1 edits cold"
  at "$2" checkout -q main
}
# mainbase: hot.txt and cold.txt at d10 (tagged base), main edits both at d8.
mainbase() {
  echo hot > "$R/hot.txt"; echo cold > "$R/cold.txt"; at 10 add -A; at 10 commit -q -m base
  git -C "$R" tag base
  echo M >> "$R/hot.txt"; at 8 commit -q -am "main edits hot"
  echo M >> "$R/cold.txt"; at 8 commit -q -am "main edits cold"
}

# --- fixture 1: one sync merge X, reachable from four refs ------------------
newrepo "$T/r1"
mainbase
at 9 checkout -q -b A base; echo A >> "$R/hot.txt"; at 9 commit -q -am "A edits hot"
at 7 merge -q main
printf 'hot\nA\nM\n' > "$R/hot.txt"; at 7 add hot.txt; at 7 commit -q -m "$SYNC"
X=$(git -C "$R" rev-parse HEAD)
git -C "$R" update-ref refs/remotes/origin/ticket/a "$X"
# extra <ref> <file>: one commit on top of X, under ref.
extra() {
  at 6 checkout -q --detach "$X"; echo "$1" > "$R/$2"; at 6 add -A; at 6 commit -q -m "$1"
  git -C "$R" update-ref "refs/remotes/origin/$1" "$(git -C "$R" rev-parse HEAD)"
}
extra ticket/a-r2 r2.txt
extra mergify/merge-queue/q1 q1.txt
extra mergify/merge-queue/q2 q2.txt
at 6 checkout -q main
for b in ticket/mergify-fix mergifyish feat/mergify/x; do
  tipconflict "$b" 6
  git -C "$R" update-ref "refs/remotes/origin/$b" "$(git -C "$R" rev-parse "refs/heads/$b")"
  git -C "$R" branch -q -D "$b"
done
fixture_ok=1
[ "$(git -C "$R" for-each-ref refs/remotes/origin/ | wc -l)" -eq 7 ] || fixture_ok=0
[ "$(git -C "$R" rev-list --merges --all | wc -l)" -eq 1 ] || fixture_ok=0
check "fixture 1 built as designed" '[ "$fixture_ok" = 1 ]'

# D1
run -C "$T/r1" --ref main --now "$NOW" --include-mergify
check "D1 rc 0 (rc=$RC: $(head -c 300 "$T/err"))" '[ "$RC" = 0 ]'
check "D1 hot.txt conflicts=1 (row: $(row hot.txt))" '[ "$(field hot.txt 2)" = 1 ]'
check "D1 hot.txt prs = ticket/a" '[ "$(field hot.txt 4)" = ticket/a ]'
check "D1 conflicted_syncs=1 sync_merges=1" '[ "$(foot conflicted_syncs)" = 1 ] && [ "$(foot sync_merges)" = 1 ]'
check "D1 all 7 refs scanned" '[ "$(foot branches_scanned)" = 7 ] && [ "$(foot branches_mergify_skipped)" = 0 ]'
check "D1 rule table: q1 scanned with the flag, owns nothing" '[ -z "$(printf "%s\n" "$OUT" | grep "mergify/merge-queue")" ]'

# D3
run -C "$T/r1" --ref main --now "$NOW"
check "D3 rc 0 (rc=$RC)" '[ "$RC" = 0 ]'
check "D3 no mergify/ id in any row" '! printf "%s\n" "$OUT" | awk -F"\t" "NR>1 && !/^#/" | cut -f4 | tr "," "\n" | grep -q "^mergify/"'
check "D3 branches_mergify_skipped=2" '[ "$(foot branches_mergify_skipped)" = 2 ]'
check "D3 branches_scanned=5" '[ "$(foot branches_scanned)" = 5 ]'
check "D3 hot.txt still 1, ticket/a" '[ "$(field hot.txt 2)" = 1 ] && [ "$(field hot.txt 4)" = ticket/a ]'
check "D3 no remote: remote_check=off" '[ "$(foot remote_check)" = off ]'
# The fleet lane's own footer() reads, over this output.
printf '%s\n' "$OUT" > "$T/out"
ffoot() { sed -n '/^# ref=/{s/.* '"$1"'=\([^ ]*\).*/\1/p;q}' "$T/out"; }
check "D3 fleet footer(): pr_merges=0 sync_merges=1 merge_tree_errors=0" \
  '[ "$(ffoot pr_merges)" = 0 ] && [ "$(ffoot sync_merges)" = 1 ] && [ "$(ffoot merge_tree_errors)" = 0 ]'
check "D3 new keys are at the end of the footer" 'printf "%s\n" "$OUT" | tail -n 1 | grep -Eq " merge_tree_errors=0 branches_mergify_skipped=2 remote_check=off branches_stale_skipped=0$"'
run -C "$T/r1" --ref main --now "$NOW" --markdown
check "D3 markdown names the mergify skip" 'grep -q "Skipped 2 mergify/ refs" <<<"$OUT"'
# An explicit mergify prefix still scans its refs (name loses the prefix).
run -C "$T/r1" --ref main --now "$NOW" --branches refs/remotes/origin/mergify/
check "D3 explicit mergify prefix scans 2" '[ "$(foot branches_scanned)" = 2 ] && [ "$(foot branches_mergify_skipped)" = 0 ]'

# D7: look-alike names are scanned and conflict at their tips.
run -C "$T/r1" --ref main --now "$NOW"
check "D7 cold.txt names the three look-alikes (row: $(row cold.txt))" \
  '[ "$(field cold.txt 4)" = "feat/mergify/x,mergifyish,ticket/mergify-fix" ] && [ "$(field cold.txt 2)" = 3 ]'

# --- fixture 2: two refs, one tip sha ---------------------------------------
newrepo "$T/r2"
mainbase
tipconflict T 6
git -C "$R" update-ref refs/remotes/origin/t1 "$(git -C "$R" rev-parse T)"
git -C "$R" update-ref refs/remotes/origin/t2 "$(git -C "$R" rev-parse T)"
# D2
run -C "$T/r2" --ref main --now "$NOW"
check "D2 rc 0 (rc=$RC)" '[ "$RC" = 0 ]'
check "D2 branches_scanned=2 branches_conflicted=1" '[ "$(foot branches_scanned)" = 2 ] && [ "$(foot branches_conflicted)" = 1 ]'
check "D2 cold.txt conflicts=1 prs=t1 (row: $(row cold.txt))" '[ "$(field cold.txt 2)" = 1 ] && [ "$(field cold.txt 4)" = t1 ]'

# --- fixture 4: a remote, a stale local ref ---------------------------------
newrepo "$T/r4"
mainbase
for b in live feat/x gone; do tipconflict "$b" 6; done
git init -q --bare "$T/o4.git"
git -C "$R" push -q "$T/o4.git" main live feat/x >/dev/null 2>&1
git -C "$R" remote add origin "$T/o4.git"
git -C "$R" fetch -q origin >/dev/null 2>&1
git -C "$R" update-ref refs/remotes/origin/gone "$(git -C "$R" rev-parse refs/heads/gone)"
check "fixture 4: origin has live and feat/x, not gone" \
  '[ "$(git ls-remote --heads "$T/o4.git" | awk "{print \$2}" | tr "\n" " ")" = "refs/heads/feat/x refs/heads/live refs/heads/main " ]'
# D4
run -C "$T/r4"  --now "$NOW"
check "D4 rc 0 (rc=$RC: $(head -c 300 "$T/err"))" '[ "$RC" = 0 ]'
check "D4 cold.txt = feat/x,live (row: $(row cold.txt))" '[ "$(field cold.txt 4)" = "feat/x,live" ]'
check "D4 remote_check=on branches_stale_skipped=1" '[ "$(foot remote_check)" = on ] && [ "$(foot branches_stale_skipped)" = 1 ]'
check "D4 branches_scanned=2" '[ "$(foot branches_scanned)" = 2 ]'
run -C "$T/r4" --now "$NOW" --markdown
check "D4 markdown names the stale skip" 'grep -q "Skipped 1 local refs that origin no longer has" <<<"$OUT"'
run -C "$T/r4" --now "$NOW" --no-remote-check
check "D4 --no-remote-check scans gone" '[ "$(field cold.txt 4)" = "feat/x,gone,live" ] && [ "$(foot remote_check)" = off ] && [ "$(foot branches_stale_skipped)" = 0 ]'
run -C "$T/r4" --now "$NOW" --branches refs/heads/
check "D4 --branches refs/heads/: remote_check=off, gone scanned" '[ "$RC" = 0 ] && [ "$(foot remote_check)" = off ] && [ "$(field cold.txt 4)" = "feat/x,gone,live" ]'
run -C "$T/r4" --now "$NOW" --branches refs/remotes/nosuch/
check "D4 unconfigured remote prefix: rc 0, remote_check=off" '[ "$RC" = 0 ] && [ "$(foot remote_check)" = off ]'
git -C "$R" remote set-url origin "$T/missing.git"
run -C "$T/r4" --now "$NOW"
check "D4 unlistable remote: rc 4 (rc=$RC)" '[ "$RC" = 4 ]'
check "D4 unlistable remote: empty stdout" '[ -z "$OUT" ]'
check "D4 unlistable remote: stderr names --no-remote-check" 'grep -q -- "--no-remote-check" "$T/err"'
run -C "$T/r4" --now "$NOW" --no-remote-check
check "D4 unlistable remote + --no-remote-check: rc 0" '[ "$RC" = 0 ] && [ "$(foot remote_check)" = off ]'
# A remote with no branches at all: every ref is stale, not an error.
git init -q --bare "$T/empty.git"
git -C "$R" remote set-url origin "$T/empty.git"
run -C "$T/r4" --ref main --now "$NOW"
check "D4 empty remote: rc 0, all 3 stale" '[ "$RC" = 0 ] && [ "$(foot branches_stale_skipped)" = 3 ] && [ "$(foot branches_scanned)" = 0 ]'

# --- D5: GNU-form and BSD-form date ------------------------------------------
REALDATE=$(command -v date)
WANT_SINCE=$("$REALDATE" -u -d "@$((NOW - 30*86400))" +%Y-%m-%dT%H:%M:%SZ)
WANT_UNTIL=$("$REALDATE" -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)
mkdir -p "$T/gnu" "$T/bsd"
cat > "$T/gnu/date" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gnu.log"
for a in "\$@"; do [ "\$a" = -r ] && exit 1; done
exec "$REALDATE" "\$@"
EOF
cat > "$T/bsd/date" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/bsd.log"
args=()
while [ \$# -gt 0 ]; do
  case "\$1" in
    -d) exit 1 ;;
    -r) args+=(-d "@\$2"); shift 2 ;;
    *)  args+=("\$1"); shift ;;
  esac
done
exec "$REALDATE" "\${args[@]}"
EOF
chmod +x "$T/gnu/date" "$T/bsd/date"
OUT=$(PATH="$T/gnu:$PATH" "$CLI" -C "$T/r2" --ref main --now "$NOW" 2>"$T/err"); RC=$?
check "D5 GNU date: rc 0, since/until (got $(foot since) $(foot until))" '[ "$RC" = 0 ] && [ "$(foot since)" = "$WANT_SINCE" ] && [ "$(foot until)" = "$WANT_UNTIL" ]'
check "D5 GNU date was called with -d" 'grep -q -- "-d @" "$T/gnu.log"'
OUT=$(PATH="$T/bsd:$PATH" "$CLI" -C "$T/r2" --ref main --now "$NOW" 2>"$T/err"); RC=$?
check "D5 BSD date: rc 0, since/until (got $(foot since) $(foot until))" '[ "$RC" = 0 ] && [ "$(foot since)" = "$WANT_SINCE" ] && [ "$(foot until)" = "$WANT_UNTIL" ]'
check "D5 BSD date: the -r fallback ran" 'grep -q -- "-r $NOW" "$T/bsd.log"'

# --- D6: the fleet lane's fetch prunes -------------------------------------
H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/locks" "$H/state" "$H/env" "$T/fakebin"
: > "$H/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/lane-alert.sh"
# No jobs API here: --dry-run sends nothing, and every other request fails.
printf '#!/bin/bash\nexit 22\n' > "$T/fakebin/curl"
chmod +x "$H/bin/lane-alert.sh" "$T/fakebin/curl"
scratch_install_closure bin/conflict-hotspots-fleet.sh "$H" >/dev/null || bad "closure: conflict-hotspots-fleet.sh"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || bad "closure: jobs-client.sh"
# The scripts the lane EXECUTES (the closure follows what it sources).
cp "$DIR/bin/conflict-hotspots.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$H/bin/"
printf 'alpha  example-org/alpha  https://alpha.invalid  -  0  box-a  -\n' > "$H/fleet.conf"
newrepo "$T/src6"
mainbase
tipconflict doomed 6
git clone -q --bare "$T/src6" "$T/o6.git"
mkdir -p "$T/repos"
git clone -q "$T/o6.git" "$T/repos/alpha"
check "fixture 6: the checkout has origin/doomed" '[ -n "$(git -C "$T/repos/alpha" for-each-ref refs/remotes/origin/doomed)" ]'
git -C "$T/o6.git" branch -q -D doomed
env PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" BOX_NAME=box-a \
  HARNESS_SECRET=s JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 JOBS_RETRY_SLEEP=0 JOBS_TIMEOUT=5 JOBS_ALERT=0 \
  JOBS_BOX=box-a LANE_GATE_CACHE_S=0 \
  bash "$H/bin/conflict-hotspots-fleet.sh" --dry-run --project alpha >"$T/lane.out" 2>"$T/lane.err"; LRC=$?
check "D6 lane rc 0 (rc=$LRC: $(head -c 300 "$T/lane.err"))" '[ "$LRC" = 0 ]'
check "D6 lane measured alpha ($(head -c 200 "$T/lane.out"))" 'jq -e "select(.project == \"alpha\") | .status == \"ok\"" "$T/lane.out" >/dev/null'
check "D6 origin/doomed pruned from the checkout" '[ -z "$(git -C "$T/repos/alpha" for-each-ref refs/remotes/origin/doomed)" ]'

echo "conflict-hotspots-dedupe.bh-5236: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
