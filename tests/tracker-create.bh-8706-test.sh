#!/bin/bash
# tests/tracker-create.bh-8706-test.sh — BH-8706: tracker_create, the issue
# create verb of the tracker contract (bin/lib/tracker.sh), and its github-issues
# adapter trk_gh_create (bin/lib/tracker/github-issues.sh). bin/main-red-breaker.sh
# files its hotfix ticket through it (BH-7919: no direct issue-API call outside
# bin/lib/tracker/).
#
#   C1  201 with a url: rc 0, <out> holds GitHub's answer, GH_REST_STATUS stays 201
#   C2  a 422 GitHub answered on purpose: rc 1
#   C3  a 5xx and a rate limit: rc 75 (retry later, never "absent")
#   C4  a bad slug, an unreadable payload, no <out>: rc 1, nothing sent
#   C5  TRK_DRY=1: rc 0, one DRYRUN line, nothing sent; TRK_LOG gets the line
#   C6  an adapter with no create (board): rc 1, one stderr line, nothing sent
#
# gh_rest is a recording fake defined before the adapter loads, so the
# adapter's guarded source of bin/lib/gh-rest.sh is skipped: 0 network calls.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/tracker-create.bh-8706-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

CALLS="$T/calls"; : > "$CALLS"
# FAKE_ST is the HTTP status the next call answers; the rc is gh_rest's own
# table (2xx 0, 404 44, everything else 75).
FAKE_ST=201
gh_rest() {
  printf '%s\n' "$*" >> "$CALLS"
  GH_REST_STATUS=$FAKE_ST; GH_REST_REASON=
  [ "$FAKE_ST" = 429 ] && GH_REST_REASON=rate-limit
  case "$FAKE_ST" in
    2??) printf '{"number":9001,"html_url":"https://github.com/example-owner/example-repo/issues/9001"}\n'; return 0 ;;
    404) return 44 ;;
    *) return 75 ;;
  esac
}
# shellcheck source=bin/lib/tracker.sh
. "$DIR/bin/lib/tracker.sh" || { echo "FAIL: bin/lib/tracker.sh did not source"; exit 1; }
tracker_load github-issues || { echo "FAIL: tracker_load github-issues"; exit 1; }
[ "$TRK_ADAPTER" = github-issues ] && ok || bad "the github-issues adapter is loaded (TRK_ADAPTER=$TRK_ADAPTER)"

PAY="$T/issue.json"; OUT="$T/created.json"
jq -n '{title:"HOTFIX: x", body:"b", labels:["ai-build","hotfix"]}' > "$PAY"
export TRK_SLUG=example-owner/example-repo

# ── C1 201 ────────────────────────────────────────────────────────────────────
FAKE_ST=201; rc=0; tracker_create "$PAY" "$OUT" || rc=$?
[ "$rc" = 0 ] && ok || bad "C1 rc 0 on a 201 (got $rc)"
[ "$(jq -r .html_url "$OUT")" = https://github.com/example-owner/example-repo/issues/9001 ] && ok || bad "C1 <out> holds the url ($(cat "$OUT"))"
[ "$GH_REST_STATUS" = 201 ] && ok || bad "C1 GH_REST_STATUS stays set for the caller (got ${GH_REST_STATUS:-})"
[ "$(cat "$CALLS")" = "POST repos/example-owner/example-repo/issues --input $PAY" ] && ok || bad "C1 one POST with --input ($(cat "$CALLS"))"

# ── C2 422 ────────────────────────────────────────────────────────────────────
: > "$CALLS"; FAKE_ST=422; rc=0; tracker_create "$PAY" "$OUT" || rc=$?
[ "$rc" = 1 ] && ok || bad "C2 rc 1 on a 422 (got $rc)"
[ "$(grep -c . "$CALLS")" = 1 ] && ok || bad "C2 one call"

# ── C3 5xx and a rate limit ───────────────────────────────────────────────────
for st in 502 429; do
  FAKE_ST=$st; rc=0; tracker_create "$PAY" "$OUT" || rc=$?
  [ "$rc" = 75 ] && ok || bad "C3 rc 75 on a $st (got $rc)"
done

# ── C4 refused before any call ────────────────────────────────────────────────
: > "$CALLS"; FAKE_ST=201
rc=0; TRK_SLUG="not a slug" tracker_create "$PAY" "$OUT" || rc=$?
[ "$rc" = 1 ] && ok || bad "C4 a bad slug is rc 1 (got $rc)"
rc=0; tracker_create "$T/no-such.json" "$OUT" || rc=$?
[ "$rc" = 1 ] && ok || bad "C4 an unreadable payload is rc 1 (got $rc)"
rc=0; tracker_create "$PAY" "" || rc=$?
[ "$rc" = 1 ] && ok || bad "C4 no <out> is rc 1 (got $rc)"
[ ! -s "$CALLS" ] && ok || bad "C4 nothing sent ($(cat "$CALLS"))"

# ── C5 dry run ────────────────────────────────────────────────────────────────
: > "$CALLS"; L="$T/trk.log"
o=$(TRK_DRY=1 TRK_LOG="$L" tracker_create "$PAY" "$OUT"); rc=$?
[ "$rc" = 0 ] && ok || bad "C5 rc 0 on a dry run (got $rc)"
[ "$o" = "DRYRUN gh api -X POST repos/example-owner/example-repo/issues --input $PAY" ] && ok || bad "C5 one DRYRUN line (got '$o')"
[ "$(cat "$L")" = "gh api -X POST repos/example-owner/example-repo/issues --input $PAY" ] && ok || bad "C5 TRK_LOG gets the line ($(cat "$L"))"
[ ! -s "$CALLS" ] && ok || bad "C5 nothing sent ($(cat "$CALLS"))"

# ── C6 an adapter with no create ──────────────────────────────────────────────
: > "$CALLS"
e=$( TRK_ADAPTER=board; tracker_create "$PAY" "$OUT" 2>&1 >/dev/null ); rc=$( TRK_ADAPTER=board; tracker_create "$PAY" "$OUT" >/dev/null 2>&1; echo $? )
[ "$rc" = 1 ] && ok || bad "C6 board has no create: rc 1 (got $rc)"
grep -q '^tracker: no adapter loaded for create' <<<"$e" && ok || bad "C6 one stderr line (got '$e')"
[ ! -s "$CALLS" ] && ok || bad "C6 nothing sent ($(cat "$CALLS"))"

echo "tracker-create.bh-8706: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
