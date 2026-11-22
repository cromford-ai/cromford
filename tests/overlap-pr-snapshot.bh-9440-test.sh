#!/bin/bash
# tests/overlap-pr-snapshot.bh-9440-test.sh — BH-9440 C1: `bin/overlap-guard.sh
# --refresh <project>` writes the hub PR snapshot (state/overlap-guard/<p>-prs.json)
# with EVERY open PR and its files, through the REST seam.
#
# THE GAP. The snapshot was written only when the guard ran a launch check, and
# the pool path never ran one on the hub, so sibling-serial noted `prs=unread`
# every tick. The guard's own list was harness-authored only, so a client's PR
# on a file owned nothing.
#
#   S1  a non-harness PR (author client-dev) on src/a.ts is in the snapshot, and
#       the guard DEFERs a ticket that plans src/a.ts against it
#   S1b a second refresh with the same head sha reads no PR file list again
#   S2  a failed read keeps the old snapshot byte for byte, and two failed
#       refreshes on one day write ONE alert line
#   S3  101 open PRs: page 2 is read, all 101 rows are written
#   S3b 31 open PRs at the default knobs: all 31 are in the snapshot, and the
#       31st (oldest) PR's file still DEFERs an overlapping build
#   S3c more open PRs than OVERLAP_REFRESH_PR_LIMIT: the snapshot is marked
#       incomplete and the guard DEFERs a ticket on an untouched file; a
#       complete refresh lifts the marker
#   S4  sibling-serial check notes prs=unread before a refresh, and not after
#   S5  every gh call went to the fake (0 network calls), with no token set
#
# A fake gh on PATH answers from fixture files (og_fake_gh below).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# og_fake_gh <dir> — write a fake `gh` into <dir>/fakebin that answers the REST
# seam's `gh api -i -X GET <path> ...` from files under <dir>/gh/, logs every call
# to <dir>/gh.log, and answers 502 while <dir>/gh-fail exists. No network.
og_fake_gh() {
  local d="$1"
  mkdir -p "$d/fakebin" "$d/gh"; : > "$d/gh.log"
  cat > "$d/fakebin/gh" <<FGH
#!/bin/bash
echo "\$*" >> "$d/gh.log"
[ -e "$d/gh-fail" ] && { printf 'HTTP/1.1 502 Bad Gateway\r\n\r\n{"message":"bad gateway"}\n'; exit 1; }
path=""; page=1
for a in "\$@"; do case "\$a" in repos/*) path="\$a" ;; page=*) page="\${a#page=}" ;; esac; done
case "\$path" in
  repos/*/*/pulls) f="$d/gh/pulls.\$page" ;;
  repos/*/*/pulls/*/files) n="\${path%/files}"; n="\${n##*/}"; f="$d/gh/files.\$n" ;;
  repos/*/*/commits) f="$d/gh/commits" ;;
  repos/*/*/commits/*) f="$d/gh/commit.\${path##*/}" ;;
  *) printf 'HTTP/1.1 404 Not Found\r\n\r\n{"message":"Not Found"}\n'; exit 1 ;;
esac
printf 'HTTP/1.1 200 OK\r\n\r\n'
if [ -s "\$f" ]; then cat "\$f"; else echo '[]'; fi
exit 0
FGH
  chmod +x "$d/fakebin/gh"
}
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
clear_boundary 86400 60
unset GH_TOKEN GITHUB_TOKEN
export GH_ETAG=0

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/flags" "$H/plans" "$H/env" "$H/state/build-queue/demo" "$H/builds"
: > "$H/env/global.env"
printf 'demo example-org/demo https://demo.example /api/board 0 local -\n' > "$H/fleet.conf"
export HARNESS="$H" FLEET_CONF="$H/fleet.conf"
# The alert stub first: the closure install never clobbers a file.
printf '#!/bin/bash\nwhile [ "${1#--}" != "$1" ]; do shift 2; done\necho "$*" >> "%s/logs/ALERTS.log"\nexit 0\n' "$H" > "$H/bin/alert-line.sh"
printf '_jobs_req() { echo '"'"'{"jobs":[]}'"'"'; }\n' > "$H/bin/jobs-client.sh"
chmod +x "$H/bin/alert-line.sh"
for L in bin/overlap-guard.sh bin/sibling-serial.sh bin/fleet-conf.sh bin/lib/gh-rest-list.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
# No credential ladder in a test: it would look for real tokens on this box.
rm -f "$H/bin/lib/gh-repo-token.sh"
og_fake_gh "$T"
export PATH="$T/fakebin:$PATH"
CF="$H/state/overlap-guard/demo-prs.json"
G="$H/bin/overlap-guard.sh"

# pr_row <n> <ref> <login> <sha> — one REST pulls-list item
pr_row() { jq -nc --argjson n "$1" --arg r "$2" --arg a "$3" --arg s "$4" \
  '{number:$n, html_url:("https://github.com/example-org/demo/pull/"+($n|tostring)), draft:false,
    user:{login:$a}, head:{ref:$r, sha:$s}}'; }
files() { local n="$1"; shift; jq -nc --args '[$ARGS.positional[] | {filename: .}]' "$@" > "$T/gh/files.$n"; }
reset() { for _p in "$H/state/overlap-guard" "$T/gh" "$T/gh-fail"; do [ -e "$_p" ] && scratch_rm "$_p"; done; mkdir -p "$T/gh"; : > "$T/gh.log"; : > "$H/logs/ALERTS.log"; : > "$H/logs/overlap-guard.log"; }
refresh() { OUT=$(OVERLAP_MAIN_RECENT_MIN=0 "$G" --refresh demo 2>/dev/null); RC=$?; }

# ── S1: a non-harness PR is an owner ──────────────────────────────────────
reset
{ pr_row 7 client/feature client-dev aaaaaaa1; pr_row 8 ticket/bh-1 operator bbbbbbb2; } | jq -s -c . > "$T/gh/pulls.1"
files 7 src/a.ts; files 8 src/c.ts
refresh
[ "$RC" = 0 ] && [ "$OUT" = "REFRESH demo ok prs=2 main=0" ] && ok || bad "S1: the refresh answers ok (rc $RC, out '$OUT')"
[ "$(jq -r '.[] | select(.number == 7) | .author + " " + .headRefName + " " + (.files[0].path)' "$CF" 2>/dev/null)" = "client-dev client/feature src/a.ts" ] && ok \
  || bad "S1: THE GAP: the client's PR #7 and its file are in the snapshot: $(cat "$CF" 2>/dev/null)"
mkdir -p "$H/plans/demo-BH-50"; printf 'src/a.ts\n' > "$H/plans/demo-BH-50/planned-files.txt"
GOUT=$("$G" demo BH-50 2>/dev/null); GRC=$?
[ "$GRC" = 1 ] && grep -q '^DEFER BH-50 vs PR#7 ' <<<"$GOUT" && ok \
  || bad "S1: the guard DEFERs BH-50 against the non-harness PR #7 (rc $GRC, out '$GOUT')"
mkdir -p "$H/plans/demo-BH-51"; printf 'src/z.ts\n' > "$H/plans/demo-BH-51/planned-files.txt"
GOUT=$("$G" demo BH-51 2>/dev/null); GRC=$?
[ "$GRC" = 0 ] && ok || bad "S1: a ticket on another file launches (rc $GRC, out '$GOUT')"

# ── S1b: the same head sha reads no file list again ───────────────────────
: > "$T/gh.log"; touch -d '10 minutes ago' "$CF"
refresh
[ "$RC" = 0 ] && ! grep -q '/files' "$T/gh.log" && ok || bad "S1b: an unchanged head sha costs no file read (gh.log: $(tr '\n' '|' < "$T/gh.log"))"
# A new head sha reads the PR's files again, and the old cache entry goes.
{ pr_row 7 client/feature client-dev ccccccc3; pr_row 8 ticket/bh-1 operator bbbbbbb2; } | jq -s -c . > "$T/gh/pulls.1"
files 7 src/a.ts src/d.ts
refresh
[ "$(jq -r '.[] | select(.number == 7) | [.files[].path] | join(",")' "$CF")" = "src/a.ts,src/d.ts" ] && ok || bad "S1b: a moved head is read again: $(cat "$CF")"
[ -e "$H/state/overlap-guard/demo-files/7.aaaaaaa1" ] && bad "S1b: the old head's file list is pruned" || ok

# ── S2: a failed read keeps the old snapshot, one alert per day ───────────
cp "$CF" "$T/before.json"; touch -d '10 minutes ago' "$CF"
touch "$T/gh-fail"
refresh
[ "$RC" = 0 ] && grep -q '^REFRESH demo failed' <<<"$OUT" && ok || bad "S2: a failed read says so, rc 0 (rc $RC, out '$OUT')"
refresh
cmp -s "$CF" "$T/before.json" && ok || bad "S2: the old snapshot is kept byte for byte: $(cat "$CF" 2>/dev/null)"
[ "$(grep -c 'snapshot refresh failed' "$H/logs/ALERTS.log")" = 1 ] && ok \
  || bad "S2: two failed refreshes on one day write ONE alert line: $(cat "$H/logs/ALERTS.log")"
grep 'snapshot refresh failed' "$H/logs/ALERTS.log" | grep -q 'HTTP 502' && ok || bad "S2: the alert names the HTTP status: $(cat "$H/logs/ALERTS.log")"

# ── S3: 101 PRs, page 2 is read ───────────────────────────────────────────
reset
for i in $(seq 1 100); do pr_row "$((1000 + i))" "feat/$i" someone "abc$i"; done | jq -s -c . > "$T/gh/pulls.1"
pr_row 2001 feat/last someone abc2001 | jq -s -c . > "$T/gh/pulls.2"
files 2001 src/last.ts
OUT=$(OVERLAP_PR_LIMIT=150 OVERLAP_MAIN_RECENT_MIN=0 "$G" --refresh demo 2>/dev/null)
[ "$OUT" = "REFRESH demo ok prs=101 main=0" ] && ok || bad "S3: 101 PRs refreshed (out '$OUT')"
grep -q 'repos/example-org/demo/pulls .*page=2' "$T/gh.log" && ok || bad "S3: page 2 was read: $(grep -c . "$T/gh.log") calls"
[ "$(jq 'length' "$CF")" = 101 ] && [ "$(jq -r '.[] | select(.number == 2001) | .files[0].path' "$CF")" = src/last.ts ] && ok \
  || bad "S3: the page-2 PR is in the snapshot ($(jq length "$CF") rows)"

# ── S3b: 31 PRs at the default knobs, the oldest still owns its file ─────
reset
for i in $(seq 1 31); do pr_row "$((3100 - i))" "feat/old-$i" "author$i" "def$i"; files "$((3100 - i))" "src/p$i.ts"; done \
  | jq -s -c . > "$T/gh/pulls.1"
OUT=$(env -u OVERLAP_PR_LIMIT -u OVERLAP_REFRESH_PR_LIMIT OVERLAP_MAIN_RECENT_MIN=0 "$G" --refresh demo 2>/dev/null)
[ "$OUT" = "REFRESH demo ok prs=31 main=0" ] && ok || bad "S3b: 31 PRs refreshed at the default knobs (out '$OUT')"
[ "$(jq -r '.[] | select(.number == 3069) | .files[0].path' "$CF")" = src/p31.ts ] && ok \
  || bad "S3b: THE CUT: the 31st PR #3069 is in the snapshot ($(jq length "$CF") rows)"
[ -e "$H/state/overlap-guard/demo-prs.incomplete" ] && bad "S3b: a complete read writes no incomplete marker" || ok
mkdir -p "$H/plans/demo-BH-60"; printf 'src/p31.ts\n' > "$H/plans/demo-BH-60/planned-files.txt"
GOUT=$("$G" demo BH-60 2>/dev/null); GRC=$?
[ "$GRC" = 1 ] && grep -q '^DEFER BH-60 vs PR#3069 ' <<<"$GOUT" && ok \
  || bad "S3b: the 31st PR's file DEFERs an overlapping build (rc $GRC, out '$GOUT')"

# ── S3c: past the cap, the snapshot is incomplete and the guard fails closed
touch -d '10 minutes ago' "$CF"
OUT=$(OVERLAP_REFRESH_PR_LIMIT=30 OVERLAP_MAIN_RECENT_MIN=0 "$G" --refresh demo 2>/dev/null)
[ "$OUT" = "REFRESH demo incomplete prs=30 main=0" ] && ok || bad "S3c: a cut list says incomplete (out '$OUT')"
[ -s "$H/state/overlap-guard/demo-prs.incomplete" ] && ok || bad "S3c: the incomplete marker is written"
[ "$(grep -c 'snapshot is INCOMPLETE' "$H/logs/ALERTS.log")" = 1 ] && ok || bad "S3c: one alert names the cut: $(cat "$H/logs/ALERTS.log")"
mkdir -p "$H/plans/demo-BH-61"; printf 'src/untouched.ts\n' > "$H/plans/demo-BH-61/planned-files.txt"
GOUT=$("$G" demo BH-61 2>/dev/null); GRC=$?
[ "$GRC" = 1 ] && grep -q '^DEFER BH-61 open-PR snapshot incomplete' <<<"$GOUT" && ok \
  || bad "S3c: FAIL CLOSED: an incomplete snapshot DEFERs, never 'no overlap' (rc $GRC, out '$GOUT')"
touch -d '10 minutes ago' "$CF"
OUT=$(OVERLAP_MAIN_RECENT_MIN=0 "$G" --refresh demo 2>/dev/null)
[ "$OUT" = "REFRESH demo ok prs=31 main=0" ] && [ ! -e "$H/state/overlap-guard/demo-prs.incomplete" ] && ok \
  || bad "S3c: a complete refresh deletes the marker (out '$OUT')"
GOUT=$("$G" demo BH-61 2>/dev/null); GRC=$?
[ "$GRC" = 0 ] && ok || bad "S3c: after a complete refresh BH-61 launches (rc $GRC, out '$GOUT')"

# ── S4: sibling-serial reads the refreshed snapshot ───────────────────────
reset
mkdir -p "$H/plans/demo-TK-142.2"; printf 'src/x/board.tsx\n' > "$H/plans/demo-TK-142.2/planned-files.txt"
jq -nc '{ticket_id:"1422",key:"TK-142.2",attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-10-13T02:30:00Z"}' > "$H/state/build-queue/demo/TK-142.2.json"
"$H/bin/sibling-serial.sh" check demo TK-142.2 >/dev/null 2>"$T/err-before"
grep -q 'TK-142.2 prs=unread' "$T/err-before" && ok || bad "S4: before a refresh the check notes prs=unread: $(cat "$T/err-before")"
pr_row 9 client/other client-dev ddddddd4 | jq -s -c . > "$T/gh/pulls.1"; files 9 src/other.ts
refresh
"$H/bin/sibling-serial.sh" check demo TK-142.2 >/dev/null 2>"$T/err-after"; SRC=$?
[ "$SRC" = 0 ] && ! grep -q 'prs=unread' "$T/err-after" && ok || bad "S4: THE GAP: after a refresh no prs=unread (rc $SRC): $(cat "$T/err-after")"

# ── S5: no call left this box ─────────────────────────────────────────────
[ "$(command -v gh)" = "$T/fakebin/gh" ] && ok || bad "S5: gh resolves to the fake ($(command -v gh))"
[ -z "${GH_TOKEN:-}" ] && ok || bad "S5: no token in the test"
grep -qv '^api -i -X GET repos/example-org/demo/' "$T/gh.log" && bad "S5: a call that is not a REST GET on the fixture repo: $(grep -v '^api -i -X GET repos/example-org/demo/' "$T/gh.log" | head -3)" || ok

echo "overlap-pr-snapshot.bh-9440: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
