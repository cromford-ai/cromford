#!/bin/bash
# tests/gate-prs-fingerprint-test.sh — the GitHub-Issues gate fingerprint
# (bin/triage-gate.sh) carries the OPEN harness PRs (number, head sha, state)
# next to the issue list, and bin/gate-diff.sh reads them, so a merge, close or
# rebase wakes the tick. (2026-09-12: the project-5 gate fingerprinted issue
# threads only; PRs merged by hand closed no issue, and "gate no-change (63
# tickets)" repeated 06:21Z-14:49Z.)
#
# TEST-CHANGE (BH-782). Two things moved and both are pinned below rather than
# quietly dropped:
#   * the two reads are REST now (bin/lib/gh-rest.sh), so the shim answers
#     `gh api -i` with a status line, a blank line and a REST-shaped body, and
#     the suite asserts the REST paths rather than the `gh pr list` argv;
#   * `mergeStateStatus` LEFT the fingerprint. REST list responses do not carry
#     it and buying it back costs one GET /pulls/{n} per open PR per tick. Case
#     3 is therefore INVERTED — a bare check flip no longer wakes the tick — and
#     that is the declared, intended knock-on, not a regression. Everything a
#     session could act on (merge, close, rebase, new comment, state change)
#     still wakes it, and cases 2/4/5 are the proof.
# Run from anywhere: tests/gate-prs-fingerprint-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin" "$T/state" "$T/flags" "$T/logs" "$T/env" "$T/fakebin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }

# p is an issue-driven project through the generic fleet.conf arm (prefix "-").
cat > "$T/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1 ${2:-}" in "p board_prefix") echo "-" ;; "p repo") echo "o/r" ;; *) exit 1 ;; esac
SH
chmod +x "$T/bin/fleet-conf.sh"

# The REST shim: peel the flags, find the path, answer status line + blank line
# + body. $T/prfail makes the PULLS route a 403, which is the fail-open case.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
[ "${1:-}" = api ] || exit 1
shift
P=""
while [ $# -gt 0 ]; do
  case "$1" in
    -i) shift ;;
    -X|-f|-F|-H) shift 2 ;;
    -*) shift ;;
    *) P="$1"; shift; break ;;
  esac
done
ST=200; BODY=""
case "$P" in
  repos/o/r/issues*) BODY=$(cat "$T/issues.json") ;;
  repos/o/r/pulls*)  if [ -f "$T/prfail" ]; then ST=403; BODY='{"message":"forbidden"}';
                     else BODY=$(cat "$T/prs.json"); fi ;;
  *) exit 1 ;;
esac
printf 'HTTP/2.0 %s\r\n' "$ST"
printf '\r\n'
[ -n "$BODY" ] && printf '%s\n' "$BODY"
case "$ST" in 2*) exit 0 ;; *) exit 1 ;; esac
SH
chmod +x "$T/fakebin/gh"

# REST shapes, not GraphQL ones: lowercase state, head.sha, updated_at.
mkpr() { # mkpr <head-sha>
  jq -nc --arg s "$1" '[{number:40, state:"open", merged_at:null,
    title:"t", body:"", draft:false, html_url:"https://github.com/o/r/pull/40",
    head:{sha:$s, ref:"feat"}, base:{ref:"main"},
    user:{login:"operator", type:"User"},
    created_at:"2026-09-01T00:00:00Z", updated_at:"2026-09-02T00:00:00Z",
    closed_at:null, labels:[]}]'
}
echo '[{"number":7,"state":"open","title":"Add sort","comments":2,"updated_at":"x"}]' > "$T/issues.json"
mkpr aaaa1111 > "$T/prs.json"
gate() { ( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt"; : > "$T/gh.txt"; "$DIR/bin/triage-gate.sh" p "$@" 2>"$T/err.txt" ); }

# 1. --seed writes both lists, mapped to the field names the gate stores;
#    exactly one issue read + one PR read.
OUT=$(gate --seed)
grep -q "^SEEDED" <<<"$OUT" && [ "$(jq -r '.prs[0].number' "$T/state/p.gate.json")" = 40 ] \
  && [ "$(jq -r '.prs[0].headRefOid' "$T/state/p.gate.json")" = aaaa1111 ] \
  && [ "$(jq -r '.prs[0].state' "$T/state/p.gate.json")" = OPEN ] \
  && [ "$(jq -r '.issues[0].number' "$T/state/p.gate.json")" = 7 ] \
  && [ "$(jq -r '.issues[0].state' "$T/state/p.gate.json")" = OPEN ] \
  && ok || bad "seed did not carry prs: $OUT $(cat "$T/state/p.gate.json" 2>/dev/null) err=$(cat "$T/err.txt")"
# TEST-CHANGE (BH-8497): the issue list is the open set (one page here: a
# short page ends it) and no closed read, so still one issue read, now state=open.
[ "$(grep -c 'repos/o/r/pulls' "$T/gh.txt")" = 1 ] \
  && [ "$(grep -c 'repos/o/r/issues' "$T/gh.txt")" = 1 ] \
  && [ "$(grep -c 'repos/o/r/issues .*state=open' "$T/gh.txt")" = 1 ] \
  && ! grep -q 'repos/o/r/issues .*state=\(closed\|all\)' "$T/gh.txt" \
  && ok || bad "expected one PR read and one open-issue page, no closed or all-states read: $(cat "$T/gh.txt")"
# ...and nothing GraphQL-backed was used for either.
! grep -qE '(^| )(pr|issue|run) ' "$T/gh.txt" && ok || bad "the gate reached for a GraphQL call: $(cat "$T/gh.txt")"
# 2. nothing moved: SKIP
OUT=$(gate); grep -q "^SKIP no-change" <<<"$OUT" && ok || bad "unchanged issues+prs should SKIP: $OUT"
# 3. NEGATIVE (BH-782 A1): the field that only ever churned is gone, so a bare
#    check flip no longer buys a session. Same PR, same head, same state.
OUT=$(gate); grep -q "^SKIP no-change" <<<"$OUT" && ok \
  || bad "a mergeState-only churn must no longer wake the tick: $OUT"
# 3b. ...but a new COMMENT on an issue still does (the wake signal that matters).
echo '[{"number":7,"state":"open","title":"Add sort","comments":3,"updated_at":"x"}]' > "$T/issues.json"
OUT=$(gate); grep -q "^RUN board-changed" <<<"$OUT" && ok || bad "a new comment must wake the tick: $OUT"
echo '[{"number":7,"state":"open","title":"Add sort","comments":2,"updated_at":"x"}]' > "$T/issues.json"
# 4. the PR merged (left the open list): RUN, diff says REMOVED with the hint
gate --seed >/dev/null
echo '[]' > "$T/prs.json"
OUT=$(gate); grep -q "^RUN board-changed" <<<"$OUT" && ok || bad "a merge must wake the tick: $OUT"
D=$(HARNESS="$T" "$DIR/bin/gate-diff.sh" p)
grep -q 'board prs: REMOVED 40 (PR #40 is no longer open — merged or closed; check the issue it was built for and its Blocked-by children)' <<<"$D" \
  && ok || bad "diff did not describe the merge: $D"
# 5. a rebase (new head, same everything else): RUN
mkpr bbbb2222 > "$T/prs.json"
gate --seed >/dev/null
mkpr cccc3333 > "$T/prs.json"
OUT=$(gate); grep -q "^RUN board-changed" <<<"$OUT" && ok || bad "a new head must wake the tick: $OUT"
D=$(HARNESS="$T" "$DIR/bin/gate-diff.sh" p)
grep -q 'CHANGED 40 (open PR #40: head: bbbb2222 -> cccc3333)' <<<"$D" && ok || bad "diff did not name the head move: $D"
# 6. the pr list is a 403: fail-open — the whole fetch fails, so the tick RUNs.
# Substituting prs:[] for the unreadable list was the first shape of this and it
# is not a fail-open: see case 6b.
touch "$T/prfail"
OUT=$(gate); grep -q "^RUN" <<<"$OUT" && ok || bad "a 403 pr list must fail open: $OUT"
! grep -q "^SKIP" <<<"$OUT" && ok || bad "a 403 pr list must never SKIP: $OUT"
rm -f "$T/prfail"
# 6b. THE CASE THAT MAKES 6 TRUE RATHER THAN USUALLY-TRUE (BH-782 review r2): a
# board whose open-PR list is GENUINELY empty. A substituted prs:[] is
# byte-identical to the stored fingerprint there, and the tick SKIPs off a read
# it never made — on the one file whose subject is "an unreadable answer must
# not read as a fact".
echo '[]' > "$T/prs.json"
OUT=$(gate --seed); grep -q "^SEEDED" <<<"$OUT" && ok || bad "6b: seed on a zero-PR board: $OUT"
touch "$T/prfail"
OUT=$(gate)
! grep -q "^SKIP" <<<"$OUT" && ok || bad "6b: a 403 on a zero-open-PR board must never SKIP: $OUT"
grep -q "^RUN" <<<"$OUT" && ok || bad "6b: a 403 on a zero-open-PR board must RUN: $OUT"
rm -f "$T/prfail"
mkpr aaaa1111 > "$T/prs.json"
gate --seed >/dev/null
# 7. the issue list fails: the whole fetch fails as before (RUN gate-fetch-failed)
echo 'not json' > "$T/issues.json"
OUT=$(gate); grep -q "^RUN gate-fetch-failed" <<<"$OUT" && ok || bad "a broken issue list must still fail open: $OUT"

echo "gate-prs-fingerprint: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
