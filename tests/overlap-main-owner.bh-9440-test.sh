#!/bin/bash
# tests/overlap-main-owner.bh-9440-test.sh — BH-9440 C2: a recent commit on the
# default branch owns its files. `bin/overlap-guard.sh --refresh` adds one
# main@<sha12> row per non-merge commit younger than OVERLAP_MAIN_RECENT_MIN
# (settings row, default 60), and the guard judges it like an open PR.
#
#   M1  a commit 10 min ago on src/b.ts, knob unset (default 60): the guard
#       DEFERs a ticket that plans src/b.ts `vs main@<sha12>`
#   M2  the same commit 90 min ago: LAUNCH
#   M3  OVERLAP_MAIN_RECENT_MIN=0: no main row, no commit read, LAUNCH
#   M4  a main@ row never holds a sibling part in bin/sibling-serial.sh
#   M5  a merge commit (two parents) is not a row: its files came from a PR
#
# A fake gh on PATH answers from fixture files (og_fake_gh below).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
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
unset GH_TOKEN GITHUB_TOKEN OVERLAP_MAIN_RECENT_MIN
export GH_ETAG=0
# ONE clock read for the file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/flags" "$H/plans" "$H/env" "$H/state/build-queue/demo" "$H/builds"
: > "$H/env/global.env"
printf 'demo example-org/demo https://demo.example /api/board 0 local -\n' > "$H/fleet.conf"
export HARNESS="$H" FLEET_CONF="$H/fleet.conf"
printf '#!/bin/bash\nwhile [ "${1#--}" != "$1" ]; do shift 2; done\necho "$*" >> "%s/logs/ALERTS.log"\nexit 0\n' "$H" > "$H/bin/alert-line.sh"
printf '_jobs_req() { echo '"'"'{"jobs":[]}'"'"'; }\n' > "$H/bin/jobs-client.sh"
chmod +x "$H/bin/alert-line.sh"
for L in bin/overlap-guard.sh bin/sibling-serial.sh bin/fleet-conf.sh bin/lib/gh-rest-list.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
rm -f "$H/bin/lib/gh-repo-token.sh"
og_fake_gh "$T"
export PATH="$T/fakebin:$PATH"
CF="$H/state/overlap-guard/demo-prs.json"
G="$H/bin/overlap-guard.sh"
SHA=0123456789abcdef0123456789abcdef01234567
MSHA=fedcba9876543210fedcba9876543210fedcba98

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
# commit_row <sha> <age-min> [parents] — one REST commits-list item
commit_row() { jq -nc --arg s "$1" --arg d "$(iso $((NOW - $2 * 60)))" --argjson p "${3:-1}" \
  '{sha:$s, parents:[range(0;$p) | {sha:"p"}], commit:{committer:{date:$d}, author:{date:$d}}}'; }
reset() { for _p in "$H/state/overlap-guard" "$T/gh"; do [ -e "$_p" ] && scratch_rm "$_p"; done; mkdir -p "$T/gh"; : > "$T/gh.log"; : > "$H/logs/overlap-guard.log"; }
plan() { mkdir -p "$H/plans/demo-$1"; printf '%s\n' "$2" > "$H/plans/demo-$1/planned-files.txt"; }
plan BH-60 src/b.ts

# ── M1: a commit 10 min ago owns src/b.ts (knob unset: 60) ────────────────
reset
commit_row "$SHA" 10 | jq -s -c . > "$T/gh/commits"
printf '{"sha":"%s","files":[{"filename":"src/b.ts"}]}\n' "$SHA" > "$T/gh/commit.$SHA"
OUT=$("$G" --refresh demo 2>/dev/null)
[ "$OUT" = "REFRESH demo ok prs=0 main=1" ] && ok || bad "M1: one main row (out '$OUT')"
[ "$(jq -r '.[] | select(.number == 0) | .headRefName + " " + .files[0].path' "$CF" 2>/dev/null)" = "main@${SHA:0:12} src/b.ts" ] && ok \
  || bad "M1: the snapshot holds main@${SHA:0:12} on src/b.ts: $(cat "$CF" 2>/dev/null)"
GOUT=$("$G" demo BH-60 2>/dev/null); GRC=$?
[ "$GRC" = 1 ] && grep -q "^DEFER BH-60 vs main@${SHA:0:12} " <<<"$GOUT" && ok \
  || bad "M1: THE GAP: a recent main commit on src/b.ts holds BH-60 (rc $GRC, out '$GOUT')"

# ── M2: the same commit 90 min ago is not an owner ────────────────────────
reset
commit_row "$SHA" 90 | jq -s -c . > "$T/gh/commits"
printf '{"sha":"%s","files":[{"filename":"src/b.ts"}]}\n' "$SHA" > "$T/gh/commit.$SHA"
OUT=$("$G" --refresh demo 2>/dev/null)
[ "$OUT" = "REFRESH demo ok prs=0 main=0" ] && ok || bad "M2: a 90-min-old commit is not a row (out '$OUT')"
GOUT=$("$G" demo BH-60 2>/dev/null); GRC=$?
[ "$GRC" = 0 ] && ok || bad "M2: BH-60 launches (rc $GRC, out '$GOUT')"

# ── M3: the knob at 0 turns the main rows off ─────────────────────────────
reset
commit_row "$SHA" 10 | jq -s -c . > "$T/gh/commits"
printf '{"sha":"%s","files":[{"filename":"src/b.ts"}]}\n' "$SHA" > "$T/gh/commit.$SHA"
OUT=$(OVERLAP_MAIN_RECENT_MIN=0 "$G" --refresh demo 2>/dev/null)
[ "$OUT" = "REFRESH demo ok prs=0 main=0" ] && ok || bad "M3: knob 0 gives no main row (out '$OUT')"
grep -q '/commits' "$T/gh.log" && bad "M3: knob 0 reads no commit: $(grep commits "$T/gh.log")" || ok
GOUT=$("$G" demo BH-60 2>/dev/null); GRC=$?
[ "$GRC" = 0 ] && ok || bad "M3: BH-60 launches (rc $GRC, out '$GOUT')"

# ── M4: a main@ row never holds a sibling part ────────────────────────────
reset
commit_row "$SHA" 10 | jq -s -c . > "$T/gh/commits"
printf '{"sha":"%s","files":[{"filename":"src/x/board.tsx"}]}\n' "$SHA" > "$T/gh/commit.$SHA"
"$G" --refresh demo >/dev/null 2>&1
plan TK-142.2 src/x/board.tsx
jq -nc '{ticket_id:"1422",key:"TK-142.2",attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-10-13T02:30:00Z"}' > "$H/state/build-queue/demo/TK-142.2.json"
SOUT=$("$H/bin/sibling-serial.sh" check demo TK-142.2 2>/dev/null); SRC=$?
[ "$SRC" = 0 ] && [ -z "$SOUT" ] && ok || bad "M4: a main@ row is not a sibling's PR (rc $SRC, out '$SOUT')"
rm -f "$H/state/build-queue/demo/TK-142.2.json"

# ── M5: a merge commit is not a row ───────────────────────────────────────
reset
{ commit_row "$MSHA" 5 2; commit_row "$SHA" 10; } | jq -s -c . > "$T/gh/commits"
printf '{"sha":"%s","files":[{"filename":"src/b.ts"}]}\n' "$SHA" > "$T/gh/commit.$SHA"
printf '{"sha":"%s","files":[{"filename":"src/m.ts"}]}\n' "$MSHA" > "$T/gh/commit.$MSHA"
OUT=$("$G" --refresh demo 2>/dev/null)
[ "$OUT" = "REFRESH demo ok prs=0 main=1" ] && ok || bad "M5: only the non-merge commit is a row (out '$OUT')"
grep -q "commits/$MSHA" "$T/gh.log" && bad "M5: the merge commit's files are not read" || ok

[ -z "${GH_TOKEN:-}" ] && [ "$(command -v gh)" = "$T/fakebin/gh" ] && ok || bad "no token, and gh is the fake"

echo "overlap-main-owner.bh-9440: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
