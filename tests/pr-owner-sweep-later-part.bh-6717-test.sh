#!/bin/bash
# tests/pr-owner-sweep-later-part.bh-6717-test.sh — bin/pr-owner-sweep.sh's
# close-duplicate arm counts a merged PR of the same key as "already shipped"
# only when it merged AFTER this PR was opened (BH-6717).
#
# WHY THIS EXISTS (2026-10-14). #6328 (ticket/bh-6173-r2, a later part of
# BH-6173) was opened two hours after #6195 (ticket/bh-6173) merged. The sweep
# closed it as a duplicate of #6195, because the ORPHAN arm took ANY merged PR
# of the key as proof. A PR opened after its key merged is new work, not a
# leftover. The MERGED_DUP column already used the time rule; this pins the
# ORPHAN arm to the same one.
#
# DRIVEN, NOT GREPPED: the real script runs with gh, curl and ssh as PATH shims,
# and the close is asserted against the recorded gh argv.
# Run from anywhere: tests/pr-owner-sweep-later-part.bh-6717-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state/merge-conductor" "$H/locks" "$H/flags" \
         "$H/env" "$H/fixture" "$T/fakebin"
export HARNESS="$H"
SLUG=example-org/project-5
scratch_install_closure bin/pr-owner-sweep.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
scratch_install_closure bin/lib/hub-box.sh "$H" >/dev/null || exit 1
echo box-hub > "$H/state/box-name"; export HUB_BOX_NAME=box-hub
cp "$DIR/bin/alert-line.sh" "$H/bin/"
ln -sf "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"
export FLEET_CONF="$DIR/fleet.conf"
printf 'HARNESS_SECRET=fixture-secret\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
printf 'GH_ADMIN_TOKEN=fixture-admintok\n' > "$H/env/github-admin.env"
export GH_TOKEN=fixture-defaulttok
export GH_BUDGET_TTL_S=0

printf '#!/bin/bash\nprintf "%%s\\n" box-project-5-1\n' > "$H/bin/box-for.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$HARNESS/alerts-called.log"\n' > "$H/bin/lane-alert.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/beat.sh"
chmod +x "$H/bin/box-for.sh" "$H/bin/lane-alert.sh" "$H/bin/beat.sh"

# gh shim: the same read and REST-write shapes as tests/pr-owner-sweep-test.sh.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HARNESS/gh-calls.log"
case "$1 $2" in
  "api rate_limit")
    now=$(date -u +%s)
    printf '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":%s},"graphql":{"remaining":4000,"limit":5000,"reset":%s}}}\n' "$now" "$now"
    exit 0 ;;
  "api repos/"*) echo 1234; exit 0 ;;
esac
case "$*" in
  # The open list carries latestReviews, as gh writes it when asked (po_dup_guard, BH-6929).
  *"pr list"*"--state open"*)   jq 'map(.latestReviews //= [])' "$HARNESS/fixture/open.json" ;;
  *"pr list"*"--state merged"*) cat "$HARNESS/fixture/merged.json" ;;
  # A comment's body travels as a file (-F body=@<file>); its text is logged with the call.
  *"api -i -X POST repos/"*"/comments"*|*"api -i -X PATCH repos/"*"/pulls/"*|*"api -i -X POST repos/"*"/labels"*)
    bf=$(printf '%s\n' "$@" | sed -n 's/^body=@//p')
    printf '%s :: %s\n' "$*" "$( [ -n "$bf" ] && tr '\n' ' ' < "$bf")" >> "$HARNESS/gh-writes.log"
    case "$*" in *"-X PATCH"*) touch "$HARNESS/closed-$(sed -nE 's#.*/pulls/([0-9]+).*#\1#p' <<<"$*")" ;; esac
    printf 'HTTP/1.1 200 OK\r\n\r\n{}\n' ;;
  # The guards' reads answer clean: po_dup_guard (events, comments, compare) and
  # po_done_close_guard (an empty file list, main's sha), BH-6929 / BH-6815.
  *"api -i -X GET repos/"*"/issues/"*"/events"*|*"api -i -X GET repos/"*"/issues/"*"/comments"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n' ;;
  *"api -i -X GET repos/"*"/compare/"*) printf 'HTTP/1.1 200 OK\r\n\r\n{"status":"diverged"}\n' ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n' ;;
  *"api -i -X GET repos/"*"/commits/HEAD"*) printf 'HTTP/1.1 200 OK\r\n\r\n{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n' ;;
  *"api -i -X GET repos/"*"/pulls/"*)
    n=$(sed -nE 's#.*/pulls/([0-9]+).*#\1#p' <<<"$*")
    if [ -f "$HARNESS/closed-$n" ]; then printf 'HTTP/1.1 200 OK\r\n\r\n{"state":"closed","merged_at":null}\n'
    else printf 'HTTP/1.1 200 OK\r\n\r\n{"state":"open","merged_at":null}\n'; fi ;;
  *) exit 1 ;;
esac
SH
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"
case "$URL" in
  */api/jobs*)  printf '{"jobs":[]}\n200\n' ;;
  */api/queue*) printf '{"queue":[]}\n200\n' ;;
  *)            printf '{"ok":true}\n200\n' ;;
esac
SH
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$HARNESS/ssh-calls.log"\ncat >/dev/null\nexit 0\n' > "$T/fakebin/ssh"
chmod +x "$T/fakebin/gh" "$T/fakebin/curl" "$T/fakebin/ssh"
export PATH="$T/fakebin:$PATH"

AGO() { date -u -d "@$(( $(date +%s) - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }
HR=3600; D=86400

# open_pr <createdAt-json-fragment>: the one open PR, #6328, a later part of BH-6173.
open_pr() {
  cat > "$H/fixture/open.json" <<JSON
[{"number":6328,"title":"BH-6173: AC3 CPU sampler","headRefName":"ticket/bh-6173-r2","author":{"login":"operator"},
  "labels":[],"body":"","mergeable":"MERGEABLE","updatedAt":"$(AGO $((10*HR)))",$1"url":"https://github.com/$SLUG/pull/6328","isDraft":false}]
JSON
}
merged_pr() {  # <number> <mergedAt>
  printf '{"number":%s,"title":"BH-6173: AC3 CPU sampler","headRefName":"ticket/bh-6173","author":{"login":"operator"},"url":"https://github.com/%s/pull/%s","mergedAt":"%s"}' "$1" "$SLUG" "$1" "$2"
}
reset() {
  scratch_rm "$H/state/pr-owners"; scratch_rm "$H/state/gh-budget"; scratch_rm "$H/logs"; scratch_rm "$H/locks"; scratch_rm "$H/flags"
  mkdir -p "$H/state/pr-owners" "$H/state/gh-budget" "$H/logs" "$H/locks" "$H/flags"
  rm -f "$H/gh-calls.log" "$H/gh-writes.log" "$H/ssh-calls.log" "$H/alerts-called.log" "$H"/closed-*
  : > "$H/state/merge-conductor/pr-state.tsv"
}
run()     { "$H/bin/pr-owner-sweep.sh" --repo "$SLUG" --explain 2>/dev/null; }
writes()  { cat "$H/gh-writes.log" 2>/dev/null; }
summary() { grep -o "$SLUG: open=.*" "$H/logs/pr-owner-sweep.log" 2>/dev/null | tail -1; }
row()     { awk -F'\t' '$1=="6328" {print $2"/"$3}' <<<"$1"; }

# ---------- L1: opened AFTER the key merged -> not a duplicate --------------
reset
open_pr "\"createdAt\":\"$(AGO $((10*HR)))\","
echo "[$(merged_pr 6195 "$(AGO $((12*HR)))")]" > "$H/fixture/merged.json"
OUT=$(run)
[ "$(row "$OUT")" = "ORPHAN/handback:BH-6173" ] && ok \
  || bad "L1: #6328 opened 2h after #6195 merged must be handed back, not closed: '$(row "$OUT")'"
grep -q "PATCH repos/$SLUG/pulls/6328" <<<"$(writes)" && bad "L1: #6328 must not be closed: $(writes)" || ok
grep -qi 'already' <<<"$(grep "repos/$SLUG/issues/6328/comments" <<<"$(writes)")" \
  && bad "L1: #6328 must get no 'already shipped' comment: $(writes)" || ok
# L5 (first half): the spared PR is named on the summary line.
grep -q 'spared-later=#6328\( \|$\)' <<<"$(summary)" && ok \
  || bad "L5: the summary must list the spared PR as spared-later=#6328: $(summary)"

# ---------- L1b: createdAt == mergedAt -> not "after", no close ------------
reset
SAME=$(AGO $((10*HR)))
open_pr "\"createdAt\":\"$SAME\","
echo "[$(merged_pr 6195 "$SAME")]" > "$H/fixture/merged.json"
OUT=$(run)
case "$(row "$OUT")" in
  ORPHAN/close-duplicate:*) bad "L1b: a merge at the same second as createdAt is not after it: '$(row "$OUT")'" ;;
  '') bad "L1b: #6328 was not classified at all: $OUT" ;;
  *) ok ;;
esac

# ---------- L2: opened BEFORE the key merged -> a real leftover -------------
reset
open_pr "\"createdAt\":\"$(AGO $((2*D)))\","
echo "[$(merged_pr 6195 "$(AGO $((12*HR)))")]" > "$H/fixture/merged.json"
OUT=$(run)
[ "$(row "$OUT")" = "ORPHAN/close-duplicate:6195" ] && ok \
  || bad "L2: #6328 opened before #6195 merged is a leftover: '$(row "$OUT")'"
grep -q "PATCH repos/$SLUG/pulls/6328" <<<"$(writes)" && ok || bad "L2: the leftover must be closed: $(writes)"
# L5 (second half): nothing spared -> `-`.
grep -q 'spared-later=-\( \|$\)' <<<"$(summary)" && ok \
  || bad "L5: with nothing spared the summary must say spared-later=-: $(summary)"

# ---------- L3: no createdAt -> nothing proves the merge came after ---------
reset
open_pr ""
echo "[$(merged_pr 6195 "$(AGO $((12*HR)))")]" > "$H/fixture/merged.json"
OUT=$(run)
case "$(row "$OUT")" in
  ORPHAN/close-duplicate:*) bad "L3: an unreadable createdAt must close nothing: '$(row "$OUT")'" ;;
  '') bad "L3: #6328 was not classified at all: $OUT" ;;
  *) ok ;;
esac
grep -q "PATCH repos/$SLUG/pulls/6328" <<<"$(writes)" && bad "L3: #6328 must not be closed: $(writes)" || ok
grep -q 'spared-later=#6328' <<<"$(summary)" && bad "L3: an unreadable createdAt is not spared on time order: $(summary)" || ok

# ---------- L4: two merges after createdAt -> the newest one, in any order --
for ORDER in old-first new-first; do
  reset
  open_pr "\"createdAt\":\"$(AGO $((4*D)))\","
  A=$(merged_pr 6100 "$(AGO $((3*D)))"); B=$(merged_pr 6195 "$(AGO $((12*HR)))")
  if [ "$ORDER" = old-first ]; then echo "[$A,$B]"; else echo "[$B,$A]"; fi > "$H/fixture/merged.json"
  OUT=$(run)
  [ "$(row "$OUT")" = "ORPHAN/close-duplicate:6195" ] && ok \
    || bad "L4 ($ORDER): the dup must be the newest merge after createdAt, #6195: '$(row "$OUT")'"
done
# …and a merge from BEFORE createdAt never wins over one after it.
reset
open_pr "\"createdAt\":\"$(AGO $((2*D)))\","
echo "[$(merged_pr 6100 "$(AGO $((3*D)))"),$(merged_pr 6195 "$(AGO $((12*HR)))")]" > "$H/fixture/merged.json"
OUT=$(run)
[ "$(row "$OUT")" = "ORPHAN/close-duplicate:6195" ] && ok \
  || bad "L4: created 2d ago, merges at 3d and 12h: the dup is #6195: '$(row "$OUT")'"

# ---------- L4b: two merges both after createdAt -> the newest, #6200 ------
reset
open_pr "\"createdAt\":\"$(AGO $((2*D)))\","
echo "[$(merged_pr 6195 "$(AGO $((1*D)))"),$(merged_pr 6200 "$(AGO $((12*HR)))")]" > "$H/fixture/merged.json"
OUT=$(run)
[ "$(row "$OUT")" = "ORPHAN/close-duplicate:6200" ] && ok \
  || bad "L4b: merges at 1d (#6195, listed first) and 12h (#6200): the dup is the newest, #6200: '$(row "$OUT")'"

echo "pr-owner-sweep-later-part: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
