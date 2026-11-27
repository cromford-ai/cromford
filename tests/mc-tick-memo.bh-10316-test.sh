#!/bin/bash
# tests/mc-tick-memo.bh-10316-test.sh — BH-10316 (slice 3 of BH-10257): the
# merge conductor keeps its GitHub reads of a PR's review list and of
# `pulls/<n>` for the rest of ONE tick (bin/lib/mc/tick-memo.sh, loaded by the
# fragment bin/merge-conductor.d/bh-10316-tick-memo.sh).
#
# THE WHOLE TICK (W). bin/merge-conductor.sh against a stub `gh`, the world of
# tests/conductor-review-block-park.bh-9260-test.sh: one PR seeded READY on its
# head, approved, CI green, a clean merge state. The tick runs every step of the
# visit (the verdict read, the block gate with its CHANGES_REQUESTED check, the
# READY arm). The stub counts every review-list read and every `pulls/42` read.
#   W1  MC_TICK_MEMO=0 (the read of today): the counts of the visit (every
#       call before the merge) are printed; the review list is read 2+ times
#   W2  MC_TICK_MEMO=1: the review list is read 1 time and `pulls/42` 2 times
#       (the list's read, then the state guard's live read), and the tick
#       decides the same as with the knob off
#   W3  a second tick reads GitHub again (no entry lives past its tick)
#   W4  the memo dir is gone after the tick; nothing under state/ or flags/
#   W5  one TICK-MEMO line per tick with the hit and miss counts
#   W6  a conductor write between two steps: the merge. The read of `pulls/42`
#       after the merge goes to GitHub, and the row settles MERGED
#   W7  a failed review read: no merge, the same reads as with the knob off
#   W8  the state guard reads live: a base retargeted after the first read of
#       the tick is seen, and the merge is refused
#   W9  the block gate reads live: a CHANGES_REQUESTED posted after the re-queue
#       check's read of the tick is seen, and the merge is refused
#
# THE HELPERS (U), the fragment sourced alone with a stub `gh`:
#   U1  a failed read (rc != 0) is not stored: the next call reads GitHub
#   U2  an unparseable body is not stored
#   U3  a good read is stored: the next call makes no GitHub call
#   U4  a write through gh_rest (POST a label) clears that PR's entries
#   U5  a write through gh (`pr merge`, `pr edit`, `api -X POST`) clears them
#   U6  a write to another PR keeps this PR's entries
#   U7  the review entry is bound to the head: another head reads GitHub
#   U8  a `pulls/<n>` answer at a new head clears the PR's review entries
#   U9  MC_TICK_MEMO=0, or no memo dir: every call reads GitHub
#   U10 the knob file exists and its default is 1
#   U11 a forget during a read in flight: the answer is not stored
#   U12 a review list cut at the paged reader's 1000-row stop is rc 75
#   U13 one review entry per head
#   U14 a wrapped write keeps rc, GH_REST_STATUS and stdout; a hit is 200/memo
#       with no stale quota values
#   U15 with no gh function, gh is not wrapped (gh_rest's timeout bound holds)
#
# GitHub is a PATH stub; nothing reads the network.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc-tick-memo.bh-10316-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# shellcheck source=tests/lib/gh-list-bridge.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
FRAG="$DIR/bin/merge-conductor.d/bh-10316-tick-memo.sh"
[ -f "$FRAG" ] || { echo "FAIL: bin/merge-conductor.d/bh-10316-tick-memo.sh is missing (BH-10316)"; exit 1; }
[ -f "$DIR/bin/lib/mc/tick-memo.sh" ] || { echo "FAIL: bin/lib/mc/tick-memo.sh is missing (BH-10316)"; exit 1; }
[ -f "$DIR/bin/merge-conductor.sh" ] || exit 1   # impact: this suite drives the whole tick
[ -f "$DIR/bin/lib/block-gate.sh" ] || exit 1    # impact: bg_read, bg_cr_standing (the review reads)
[ -f "$DIR/bin/lib/mc/classify.sh" ] || exit 1   # impact: mc_rest_pr_json (the pulls read)
[ -f "$DIR/bin/lib/mc/block-ci.sh" ] || exit 1   # impact: _mc_bci_head_review_body

SLUG=example-org/demo-os
NUM=42
KEY="$SLUG#$NUM"
PRURL="https://github.com/$SLUG/pull/$NUM"
H1=a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0
H2=b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0e1
cnt() { local c=0; [ -f "$1" ] && c=$(grep -cE "$2" "$1"); echo "${c:-0}"; }

# ============================================================================
# U. THE HELPERS, sourced alone
# ============================================================================
echo "U: the memo helpers"
U="$T/u"; mkdir -p "$U/bin" "$U/tmp"
# The unit stub: reviews and pulls answers from files; $U/fail-<what> fails the
# read (a 502 with -i, rc 1 without); $U/junk-<what> answers a body that is not
# JSON. Every call goes to $U/calls.
cat > "$U/bin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$U/calls"
case "$*" in
  *" -i -X POST "*|*" -i -X PATCH "*|*" -i -X DELETE "*|*" -i -X PUT "*)
    printf 'HTTP/1.1 %s Done\r\n\r\n%s' "$(cat "$U/write-status" 2>/dev/null || echo 201)" '{"written":true}'; exit 0 ;;
  *" -X POST "*|*" -X PATCH "*|*" -X DELETE "*|*" -X PUT "*|"pr "*|"issue "*) exit 0 ;;
esac
w=pull; case "$*" in *"/reviews"*) w=reviews ;; esac
n=$(sed -E 's#.*/pulls/([0-9]+).*#\1#' <<<"$*")
hdr=0; case "$*" in *" -i "*) hdr=1 ;; esac
# slow-<what>: the read says it is in flight, then waits (bounded) until the
# test's other worker has forgotten the PR.
if [ -e "$U/slow-$w" ]; then
  : > "$U/in-flight"
  for _ in $(seq 1 200); do [ -e "$U/forgot" ] && break; sleep 0.05; done
fi
if [ -e "$U/fail-$w" ]; then
  [ "$hdr" = 1 ] && { printf 'HTTP/1.1 502 Bad\r\n\r\n{"message":"bad gateway"}'; exit 0; }
  echo "HTTP 502" >&2; exit 1
fi
[ "$hdr" = 1 ] && printf 'HTTP/1.1 200 OK\r\n\r\n'
if [ -e "$U/junk-$w" ]; then printf 'not json'; exit 0; fi
if [ "$w" = reviews ] && [ -e "$U/many-reviews" ]; then jq -nc '[range(100) | {id:., state:"COMMENTED"}]'
elif [ "$w" = reviews ]; then cat "$U/reviews-$n.json" 2>/dev/null || echo '[]'
else jq -nc --argjson n "$n" --arg h "$(cat "$U/head-$n" 2>/dev/null || echo "$H1")" \
  '{number:$n, state:"open", merged_at:null, draft:false, head:{sha:$h, ref:"b"}, base:{ref:"main"}, user:{login:"operator"}, labels:[], mergeable:true, mergeable_state:"clean"}'
fi
EOF
chmod +x "$U/bin/gh"
echo '[{"id":1,"state":"APPROVED","commit_id":"'"$H1"'","user":{"login":"x","type":"User"},"submitted_at":"2026-11-08T00:00:00Z"}]' > "$U/reviews-42.json"
echo '[]' > "$U/reviews-43.json"
# ulib <snippet>: a fresh bash with the conductor's gh wrapper (gh-limit-logger.sh),
# gh-rest.sh, the fragment, a memo dir, the stub.
ulib() {
  ( cd "$U" && env -u MC_TICK_MEMO PATH="$U/bin:$PATH" U="$U" H1="$H1" TMPDIR="$U/tmp" GH_ETAG=0 HARNESS="$U" bash -c '
      mc_log() { :; }
      . "'"$DIR"'/bin/lib/gh-limit-logger.sh"
      . "'"$DIR"'/bin/lib/gh-rest.sh"
      . "'"$FRAG"'"
      MC_TICK_ID=u1; mc_tm_arm
      '"$1" 2>"$U/err" )
}
ucalls() { grep -E "${1:-.}" "$U/calls" 2>/dev/null | grep -vcE -- '-X (POST|PUT|PATCH|DELETE)'; }   # reads only
reviews_twice='f=$(mktemp); mc_tm_reviews "$f" example-org/demo-os 42 '"$H1"'; echo "rc=$?"; mc_tm_reviews "$f" example-org/demo-os 42 '"$H1"'; echo "rc=$?"; rm -f "$f"'
pull_twice='f=$(mktemp); mc_tm_pull "$f" example-org/demo-os 42; echo "rc=$?"; mc_tm_pull "$f" example-org/demo-os 42; echo "rc=$?"; rm -f "$f"'

# U1 a failed read is not stored.
: > "$U/calls"; touch "$U/fail-reviews" "$U/fail-pull"
out=$(ulib "$reviews_twice; $pull_twice")
eq "U1 a failed reviews read: both calls fail" "$(grep -c 'rc=[1-9]' <<<"$out")" 4
eq "U1 a failed reviews read is not stored: 2 GitHub reads" "$(ucalls '/pulls/42/reviews')" 2
eq "U1 a failed pulls read is not stored: 2 GitHub reads" "$(ucalls '/pulls/42( |$)')" 2
rm -f "$U/fail-reviews" "$U/fail-pull"

# U2 an unparseable body is not stored.
: > "$U/calls"; touch "$U/junk-reviews" "$U/junk-pull"
ulib "$reviews_twice; $pull_twice" >/dev/null
eq "U2 a reviews body that is not JSON is not stored: 2 reads" "$(ucalls '/pulls/42/reviews')" 2
eq "U2 a pulls body that is not JSON is not stored: 2 reads" "$(ucalls '/pulls/42( |$)')" 2
rm -f "$U/junk-reviews" "$U/junk-pull"

# U3 a good read is stored.
: > "$U/calls"
out=$(ulib "$reviews_twice; $pull_twice; f=\$(mktemp); mc_tm_reviews \"\$f\" example-org/demo-os 42 $H1; jq -r '.[0].id' \"\$f\"; rm -f \"\$f\"")
eq "U3 both reviews calls answer rc 0" "$(grep -c 'rc=0' <<<"$out")" 4
eq "U3 a good reviews read is stored: 1 GitHub read for 3 calls" "$(ucalls '/pulls/42/reviews')" 1
eq "U3 a good pulls read is stored: 1 GitHub read for 2 calls" "$(ucalls '/pulls/42( |$)')" 1
eq "U3 the memo answers the whole list" "$(tail -1 <<<"$out")" 1

# U4 a write through gh_rest clears the PR's entries.
for w in "POST repos/example-org/demo-os/issues/42/labels -f labels[]=merge-queue" \
         "DELETE repos/example-org/demo-os/issues/42/labels/merge-queue" \
         "POST repos/example-org/demo-os/issues/42/comments -f body=x" \
         "POST repos/example-org/demo-os/pulls/42/reviews -f event=COMMENT" \
         "PUT repos/example-org/demo-os/pulls/42/merge"; do
  : > "$U/calls"
  ulib "f=\$(mktemp); mc_tm_reviews \"\$f\" example-org/demo-os 42 $H1; mc_tm_pull \"\$f\" example-org/demo-os 42
        gh_rest $w >/dev/null
        mc_tm_reviews \"\$f\" example-org/demo-os 42 $H1; mc_tm_pull \"\$f\" example-org/demo-os 42; rm -f \"\$f\"" >/dev/null
  eq "U4 gh_rest ${w%% -f*}: the next reviews call reads GitHub" "$(ucalls '/pulls/42/reviews( |\?|$)')" 2
  eq "U4 gh_rest ${w%% -f*}: the next pulls call reads GitHub" "$(ucalls '/pulls/42( |$)')" 2
done

# U5 a write through gh clears the PR's entries.
for w in "pr merge $PRURL --squash" "pr edit 42 -R $SLUG --add-label merge-queue" \
         "pr comment $PRURL --body x" "api -X POST repos/$SLUG/issues/42/comments -f body=x" \
         "api repos/$SLUG/issues/42/labels -f labels[]=x" "api -X PATCH repos/$SLUG/pulls/42 -f base=main"; do
  : > "$U/calls"
  ulib "f=\$(mktemp); mc_tm_reviews \"\$f\" example-org/demo-os 42 $H1
        gh $w >/dev/null
        mc_tm_reviews \"\$f\" example-org/demo-os 42 $H1; rm -f \"\$f\"" >/dev/null
  eq "U5 gh ${w%% -*}: the next reviews call reads GitHub" "$(ucalls '/pulls/42/reviews')" 2
done
# A write the memo cannot bind to one PR clears every entry.
: > "$U/calls"
ulib "f=\$(mktemp); mc_tm_reviews \"\$f\" example-org/demo-os 42 $H1; gh pr merge 42 --squash >/dev/null
      mc_tm_reviews \"\$f\" example-org/demo-os 42 $H1; rm -f \"\$f\"" >/dev/null
eq "U5 gh pr merge with no repo: every entry goes, the next call reads GitHub" "$(ucalls '/pulls/42/reviews')" 2
# A read through gh keeps the entries.
: > "$U/calls"
ulib "f=\$(mktemp); mc_tm_reviews \"\$f\" example-org/demo-os 42 $H1; gh pr view $PRURL --json state >/dev/null
      gh api repos/$SLUG/issues/42/comments --paginate >/dev/null
      mc_tm_reviews \"\$f\" example-org/demo-os 42 $H1; rm -f \"\$f\"" >/dev/null
eq "U5 a gh read keeps the entry: 1 reviews read" "$(ucalls '/pulls/42/reviews')" 1

# U6 a write to another PR keeps this PR's entries.
: > "$U/calls"
ulib "f=\$(mktemp); mc_tm_reviews \"\$f\" example-org/demo-os 42 $H1
      gh_rest POST repos/example-org/demo-os/issues/43/labels -f labels[]=x >/dev/null; gh pr merge https://github.com/$SLUG/pull/43 >/dev/null
      mc_tm_reviews \"\$f\" example-org/demo-os 42 $H1; rm -f \"\$f\"" >/dev/null
eq "U6 a write to #43 keeps #42's entry: 1 reviews read" "$(ucalls '/pulls/42/reviews')" 1

# U7 the review entry is bound to the head.
: > "$U/calls"
ulib "f=\$(mktemp); mc_tm_reviews \"\$f\" example-org/demo-os 42 $H1; mc_tm_reviews \"\$f\" example-org/demo-os 42 $H2
      mc_tm_reviews \"\$f\" example-org/demo-os 42 $H2; rm -f \"\$f\"" >/dev/null
eq "U7 another head reads GitHub, then is kept: 2 reviews reads" "$(ucalls '/pulls/42/reviews')" 2

# U8 a pulls answer at a new head clears the PR's review entries.
: > "$U/calls"; echo "$H1" > "$U/head-42"
ulib "f=\$(mktemp); mc_tm_pull \"\$f\" example-org/demo-os 42; mc_tm_reviews \"\$f\" example-org/demo-os 42 -
      mc_tm_note_head example-org/demo-os 42 $H1; mc_tm_reviews \"\$f\" example-org/demo-os 42 -
      mc_tm_note_head example-org/demo-os 42 $H2; mc_tm_reviews \"\$f\" example-org/demo-os 42 -
      mc_tm_pull \"\$f\" example-org/demo-os 42; rm -f \"\$f\"" >/dev/null
eq "U8 a live head equal to the PR's head keeps, a new head clears: 2 reviews reads" "$(ucalls '/pulls/42/reviews')" 2
eq "U8 a new head clears the pulls entry too: 2 pulls reads" "$(ucalls '/pulls/42( |$)')" 2
# A pulls answer at a new head (the memo was cleared by a write in between, so
# the read is live) drops the review entry of the old head.
: > "$U/calls"
ulib "f=\$(mktemp); mc_tm_pull \"\$f\" example-org/demo-os 42; mc_tm_reviews \"\$f\" example-org/demo-os 42 -
      echo $H2 > \"\$U/head-42\"; rm -f \"\$_mc_tm_dir\"/*/pull; mc_tm_pull \"\$f\" example-org/demo-os 42
      mc_tm_reviews \"\$f\" example-org/demo-os 42 -; rm -f \"\$f\"" >/dev/null
eq "U8 a pulls answer at a new head clears the reviews entry: 2 reviews reads" "$(ucalls '/pulls/42/reviews')" 2
rm -f "$U/head-42"

# U9 the knob off, and no memo dir.
: > "$U/calls"
( cd "$U" && PATH="$U/bin:$PATH" U="$U" TMPDIR="$U/tmp" GH_ETAG=0 HARNESS="$U" MC_TICK_MEMO=0 bash -c '
    mc_log() { :; }; . "'"$DIR"'/bin/lib/gh-rest.sh"; . "'"$FRAG"'"; MC_TICK_ID=u1; mc_tm_arm
    '"$reviews_twice; $pull_twice" ) >/dev/null 2>&1
eq "U9 MC_TICK_MEMO=0: 2 reviews reads" "$(ucalls '/pulls/42/reviews')" 2
eq "U9 MC_TICK_MEMO=0: 2 pulls reads" "$(ucalls '/pulls/42( |$)')" 2
: > "$U/calls"
( cd "$U" && PATH="$U/bin:$PATH" U="$U" TMPDIR="$U/tmp" GH_ETAG=0 HARNESS="$U" bash -c '
    mc_log() { :; }; . "'"$DIR"'/bin/lib/gh-rest.sh"; . "'"$FRAG"'"
    '"$reviews_twice; $pull_twice" ) >/dev/null 2>&1
eq "U9 not armed (no memo dir): 2 reviews reads" "$(ucalls '/pulls/42/reviews')" 2
eq "U9 not armed (no memo dir): 2 pulls reads" "$(ucalls '/pulls/42( |$)')" 2

# U11 a forget that lands while a read is in flight (another worker's write to
# this PR, a restack of a stacked child): the answer of that read is not
# stored, so the next call reads GitHub again.
for w in reviews pull; do
  : > "$U/calls"; touch "$U/slow-$w"
  if [ "$w" = reviews ]; then call="mc_tm_reviews \"\$f\" example-org/demo-os 42 $H1"; pat='/pulls/42/reviews'
  else call="mc_tm_pull \"\$f\" example-org/demo-os 42"; pat='/pulls/42( |$)'; fi
  rm -f "$U/in-flight" "$U/forgot"
  ulib "f=\$(mktemp); ( for _ in \$(seq 1 200); do [ -e \"\$U/in-flight\" ] && break; sleep 0.05; done
        mc_tm_forget example-org/demo-os 42; : > \"\$U/forgot\" ) & $call; wait; rm -f \"\$U/slow-$w\"; $call; rm -f \"\$f\"" >/dev/null
  eq "U11 $w: a forget during the read keeps its answer out: 2 GitHub reads" "$(ucalls "$pat")" 2
  rm -f "$U/slow-$w" "$U/in-flight" "$U/forgot"
done

# U12 a review list the paged reader cut at its ten-page stop (1000 rows, the
# last page full) is unreadable (75), never a whole list: the newest reviews
# would be missing. Nothing is stored.
: > "$U/calls"; touch "$U/many-reviews"
out=$(ulib "f=\$(mktemp); mc_tm_reviews \"\$f\" example-org/demo-os 42 $H1; echo \"rc=\$?\"; mc_tm_reviews \"\$f\" example-org/demo-os 42 $H1; echo \"rc=\$?\"; rm -f \"\$f\"")
eq "U12 1000 rows at the page stop: rc 75 both times" "$(grep -c 'rc=75' <<<"$out")" 2
eq "U12 not stored: 20 page reads for 2 calls" "$(ucalls '/pulls/42/reviews')" 20
rm -f "$U/many-reviews"

# U13 one review entry per head: a read at head H2 does not replace the entry
# of H1, and each head gets its own list back.
: > "$U/calls"
echo '[{"id":1,"state":"APPROVED"}]' > "$U/reviews-42.json"
out=$(ulib "f=\$(mktemp); mc_tm_reviews \"\$f\" example-org/demo-os 42 $H1
      echo '[{\"id\":2,\"state\":\"CHANGES_REQUESTED\"}]' > \"\$U/reviews-42.json\"
      mc_tm_reviews \"\$f\" example-org/demo-os 42 $H2; jq -r '.[0].id' \"\$f\"
      mc_tm_reviews \"\$f\" example-org/demo-os 42 $H1; jq -r '.[0].id' \"\$f\"; rm -f \"\$f\"")
eq "U13 two heads: 2 GitHub reads for 3 calls" "$(ucalls '/pulls/42/reviews')" 2
eq "U13 each head gets its own list (H2 then H1)" "$(tr '\n' ' ' <<<"$out")" "2 1 "
echo '[{"id":1,"state":"APPROVED","commit_id":"'"$H1"'","user":{"login":"x","type":"User"},"submitted_at":"2026-11-08T00:00:00Z"}]' > "$U/reviews-42.json"

# U14 the wraps keep gh_rest's contract: a write keeps its rc, GH_REST_STATUS
# and stdout; a memo hit sets GH_REST_STATUS 200 and GH_REST_REASON memo and
# leaves no quota value of an earlier call behind.
out=$(ulib "gh_rest POST repos/example-org/demo-os/issues/42/labels -f labels[]=x > \"\$U/w.out\"; echo \"rc=\$? st=\$GH_REST_STATUS\"; cat \"\$U/w.out\"; echo")
eq "U14 a wrapped 201 write: rc 0, GH_REST_STATUS 201" "$(head -1 <<<"$out")" "rc=0 st=201"
eq "U14 a wrapped write keeps stdout" "$(sed -n 2p <<<"$out")" '{"written":true}'
echo 422 > "$U/write-status"
out=$(ulib "gh_rest POST repos/example-org/demo-os/issues/42/labels -f labels[]=x >/dev/null; echo \"rc=\$? st=\$GH_REST_STATUS\"")
eq "U14 a wrapped 422 write: rc 75, GH_REST_STATUS 422" "$out" "rc=75 st=422"
rm -f "$U/write-status"
for w in pull reviews; do
  if [ "$w" = reviews ]; then call="mc_tm_reviews \"\$f\" example-org/demo-os 42 $H1"; else call="mc_tm_pull \"\$f\" example-org/demo-os 42"; fi
  out=$(ulib "f=\$(mktemp); $call; GH_REST_STATUS=503; GH_REST_REASON=x; GH_REST_QUOTA_REMAINING=7; GH_REST_QUOTA_LIMIT=9; GH_REST_MESSAGE=m
        $call; echo \"rc=\$? \$GH_REST_STATUS \$GH_REST_REASON [\$GH_REST_QUOTA_REMAINING\$GH_REST_QUOTA_LIMIT\$GH_REST_MESSAGE]\"; rm -f \"\$f\"")
  eq "U14 a $w memo hit: 200 memo and no stale quota or message" "$out" "rc=0 200 memo []"
done

# U15 gh is wrapped only when it is already a function: with no gh-limit-logger
# there is no gh function, so gh_rest's GH_REST_TIMEOUT_S bound stays on.
out=$( cd "$U" && PATH="$U/bin:$PATH" U="$U" TMPDIR="$U/tmp" GH_ETAG=0 HARNESS="$U" bash -c '
    unset -f gh   # the suite exports a gh function (gh-list-bridge.sh); this case has none
    mc_log() { :; }; . "'"$DIR"'/bin/lib/gh-rest.sh"; . "'"$FRAG"'"; MC_TICK_ID=u1; mc_tm_arm
    declare -F gh >/dev/null && echo gh-function || echo no-gh-function
    declare -F _mc_tm_gh_rest >/dev/null && echo gh_rest-wrapped' 2>/dev/null | tr '\n' ' ')
eq "U15 no logger: gh stays the binary (the timeout bound holds), gh_rest is wrapped" "$out" "no-gh-function gh_rest-wrapped "

# U10 the knob file.
KF="$DIR/catalog/lanes.d/merge-conductor.knobs.d/MC_TICK_MEMO.json"
[ -f "$KF" ] && ok "U10 the knob file exists" || bad "U10 $KF is missing"
eq "U10 MC_TICK_MEMO default is 1" "$(jq -r .default "$KF" 2>/dev/null)" 1
eq "U10 MC_TICK_MEMO zero_means off" "$(jq -r .zero_means "$KF" 2>/dev/null)" off

# ============================================================================
# W. THE WHOLE TICK
# ============================================================================
echo "W: the whole tick"
export HARNESS="$T/h"
( fx_mc_harness "$DIR" "$T" && fx_conductor_tick "$DIR" "$T" ) || { echo "FAIL: fixture setup"; exit 1; }
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$T" > "$T/h/bin/lane-alert.sh"; chmod +x "$T/h/bin/lane-alert.sh"
( cd "$DIR" && scratch_install_closure bin/merge-conductor.sh "$T/h" ) >/dev/null || { echo "FAIL: closure install"; exit 1; }
for s in bin/merge-conductor.d/bh-10316-tick-memo.sh bin/merge-conductor.d/bh-9260-review-block-park.sh bin/lib/block-gate.sh; do
  ( cd "$DIR" && scratch_install_closure "$s" "$T/h" ) >/dev/null || { echo "FAIL: closure install $s"; exit 1; }
done
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
REC="$T/h/builds/demo-os-TK-21-202611070001"; mkdir -p "$REC"
echo "PR_CREATED $PRURL" > "$REC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
echo "$H1" > "$REC/reviewed-sha"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
case "$M $URL" in
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  "GET "*/api/settings/lead_pr_authors) printf '{"setting":{"key":"lead_pr_authors","value":"lead-fixture-bot"}}\n200\n' ;;
  "GET "*/api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
# The tick stub. The review list ($T/reviews.json) and the PR object answer every
# shape the conductor asks in: `-i` (gh_rest, a status line first), `-q` (the
# filter is applied, as gh does) or plain JSON. Every call -> $T/gh-calls.txt.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
HS=\$(cat "$T/head")
q=""; prev=""; for a in "\$@"; do [ "\$prev" = -q ] && q="\$a"; prev="\$a"; done
hdr=0; case " \$* " in *" -i "*) hdr=1 ;; esac
emit() { if [ "\$hdr" = 1 ]; then restpr --raw 200 "\$1"; elif [ -n "\$q" ]; then jq -r "\$q" <<<"\$1"; else printf '%s\n' "\$1"; fi; }
# flip-base: every PR-object read after the first answers base "release" (a
# person retargets the PR during the tick). flip-cr: every review-list read
# after the first also holds a CHANGES_REQUESTED by the owner on the head.
BASE=main
if [ -e "$T/flip-base" ]; then
  case "\$*" in *"repos/$SLUG/pulls/$NUM"|*"repos/$SLUG/pulls/$NUM "*)
    case "\$*" in *v3.diff*) ;; *) echo x >> "$T/pr-reads" ;; esac ;; esac
  [ "\$(wc -l < "$T/pr-reads" 2>/dev/null || echo 0)" -ge 2 ] && BASE=release
fi
prjson() {
  if [ -f "$T/merged" ]; then st=closed; ma='"2026-11-08T05:00:00Z"'; mc='"cccccccc3333"'; else st=open; ma=null; mc=null; fi
  echo "{\"number\":$NUM,\"html_url\":\"$PRURL\",\"title\":\"t\",\"body\":\"\",\"state\":\"\$st\",\"merged\":\$([ -f "$T/merged" ] && echo true || echo false),\"merged_at\":\$ma,\"merge_commit_sha\":\$mc,\"mergeable\":true,\"mergeable_state\":\"clean\",\"draft\":false,\"head\":{\"sha\":\"\$HS\",\"ref\":\"ticket/TK-21\",\"repo\":{\"full_name\":\"$SLUG\"}},\"base\":{\"ref\":\"\$BASE\",\"repo\":{\"full_name\":\"$SLUG\"}},\"user\":{\"login\":\"operator\",\"type\":\"User\"},\"labels\":[],\"created_at\":\"2026-11-07T00:00:00Z\",\"updated_at\":\"2026-11-07T00:00:00Z\",\"closed_at\":null}"
}
case "\$*" in
  *"pr merge $PRURL --squash --match-head-commit \$HS"*)
    printf '%s\n' "\$*" >> "$T/gh-merges.txt"; touch "$T/merged"; exit 0 ;;
  *"pr comment"*) printf '%s\n' "\$*" >> "$T/gh-writes.txt"; exit 0 ;;
  *"pr merge"*|*"api -X PATCH"*|*"api -i -X PATCH repos/"*|*"api -i -X POST repos/"*|*"api -i -X DELETE repos/"*\\
  |*"pr edit"*|*"issue close"*|*"issue comment"*|*"pr review"*)
    printf '%s\n' "\$*" >> "$T/gh-writes.txt"
    case "\$*" in *"api -i -X"*) restpr --raw 500 '{"message":"refused"}'; exit 0 ;; esac
    exit 1 ;;
  *"repos/$SLUG/git/ref/heads/main"*)
    restpr --raw 200 "{\"ref\":\"refs/heads/main\",\"object\":{\"sha\":\"\$(printf 'f%.0s' {1..40})\"}}"; exit 0 ;;
  *"api -i -X GET repos/$SLUG/pulls?state=open"*)
    restpr --raw 200 "[\$(prjson)]"; exit 0 ;;
  *"repos/$SLUG/issues/$NUM/comments"*) emit '[]'; exit 0 ;;
  *"repos/$SLUG/pulls/$NUM/files"*) if [ "\$hdr" = 1 ]; then restpr --raw 200 '[{"filename":"src/x.ts"}]'; else echo '[[{"filename":"src/x.ts"}]]'; fi; exit 0 ;;
  *"repos/$SLUG/pulls/$NUM/reviews/"*) restpr --raw 404 '{"message":"Not Found"}'; exit 0 ;;
  *"repos/$SLUG/pulls/$NUM/reviews"*)
    if [ -e "$T/fail-reviews" ]; then [ "\$hdr" = 1 ] && { restpr --raw 502 '{"message":"x"}'; exit 0; }; echo "HTTP 502" >&2; exit 1; fi
    rj=\$(cat "$T/reviews.json")
    if [ -e "$T/flip-cr" ]; then
      case "\$*" in *page=2*) ;; *) echo x >> "$T/rv-reads" ;; esac
      [ "\$(wc -l < "$T/rv-reads")" -ge 2 ] && rj=\$(jq -c --arg h "\$HS" '. + [{id:7002, state:"CHANGES_REQUESTED", commit_id:\$h, user:{login:"operator", type:"User"}, author_association:"OWNER", submitted_at:"2026-11-07T13:00:00Z", html_url:"$PRURL#pullrequestreview-7002", body:"stop"}]' <<<"\$rj")
    fi
    emit "\$rj"; exit 0 ;;
  *"repos/$SLUG/pulls/$NUM/commits"*) if [ "\$hdr" = 1 ]; then restpr --raw 200 '[]'; else cat "$T/headtime" 2>/dev/null; fi; exit 0 ;;
  *"v3.diff"*) restpr --diff '+++ b/src/x.ts
+const a = 1;
' ;;
  *"repos/$SLUG/pulls/$NUM"|*"repos/$SLUG/pulls/$NUM "*)
    if [ "\$hdr" = 1 ]; then
      if [ -f "$T/merged" ]; then restpr MERGED "\$HS" ticket/TK-21 "\$BASE" "" MERGEABLE CLEAN operator cccccccc3333
      else restpr OPEN "\$HS" ticket/TK-21 "\$BASE" "" MERGEABLE CLEAN operator; fi
    else emit "\$(prjson)"; fi ;;
  *"--json state,headRefOid,baseRefName"*) [ -f "$T/merged" ] && echo "MERGED \$HS main" || echo "OPEN \$HS main" ;;
  *"--json state,headRefOid"*)             [ -f "$T/merged" ] && echo "MERGED \$HS" || echo "OPEN \$HS" ;;
  *"pr view"*"--json state"*)              [ -f "$T/merged" ] && echo MERGED || echo OPEN ;;
  *"pr view"*"--json mergeCommit"*) echo "cccccccc3333" ;;
  *"pr list -R $SLUG --state open"*)
    echo "[{\"number\":$NUM,\"url\":\"$PRURL\",\"headRefOid\":\"\$HS\",\"headRefName\":\"ticket/TK-21\",\"isDraft\":false,\"mergeStateStatus\":\"CLEAN\",\"mergeable\":\"MERGEABLE\",\"state\":\"OPEN\",\"labels\":[],\"baseRefName\":\"main\"}]" ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha=\$HS"*) printf 'completed|success\n' ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

mkdir -p "$T/tmp"
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x-fixture JOBS_URL=http://worker.test \
                 HARNESS_OPERATOR_LOGIN=operator HARNESS_VERDICT_AUTHORS=app/cromford TMPDIR="$T/tmp" GH_ETAG=0 \
                 MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_TTL_READY=-1 MC_ONLY_PR="$KEY" \
                 env "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) \
             || { echo "  tick rc=$? stderr:"; tail -5 "$T/tick.err"; }; }
MCLOG="$T/h/logs/merge-conductor.log"
ROWS="$T/h/state/merge-conductor/pr-state.tsv"
row_f() { awk -F'\t' -v k="$KEY" -v n="$1" '$1==k {print $n}' "$ROWS" 2>/dev/null; }
# reseed: the PR open and READY on $H1 again, the call record empty; the log
# stays. reset: a fresh tree, then reseed. The actions and merge flags are on.
reseed() {
  rm -f "$T/merged" "$T/tick.err" "$T/fail-reviews" "$T/flip-base" "$T/flip-cr" "$T/pr-reads" "$T/rv-reads" "$T/h/tmp/merge-queue-example-org_demo-os.provider"
  : > "$T/gh-merges.txt"; : > "$T/gh-writes.txt"; : > "$T/gh-calls.txt"
  echo "[{\"id\":7001,\"state\":\"APPROVED\",\"commit_id\":\"$H1\",\"user\":{\"login\":\"operator\",\"type\":\"User\"},\"author_association\":\"OWNER\",\"submitted_at\":\"2026-11-07T12:00:00Z\",\"html_url\":\"$PRURL#pullrequestreview-7001\",\"body\":\"ok\"}]" > "$T/reviews.json"
  echo "$H1" > "$T/head"; printf '%s\n' 2026-11-07T18:40:00Z > "$T/headtime"
  printf '%s\tREADY\t1794099652\t%s\t%s\t-\tclean approved checks green\t%s\n' "$KEY" "$H1" "$H1" "$PRURL" > "$ROWS"
}
reset() {
  for d in "$T/h/state" "$T/h/logs" "$T/h/locks" "$T/tmp"; do scratch_rm "$d"; done
  mkdir -p "$T/h/logs" "$T/h/locks" "$T/h/state/merge-conductor" "$T/tmp"
  touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
  printf 'demo-os %s https://demo.example /api/board 2 box-demo\n' "$SLUG" > "$T/h/fleet.conf"
  : > "$T/alerts.txt"
  reseed
}
# THE VISIT is every call before the merge (the steps that decide it); the
# reads after the merge are the merge's own readback.
visit() { local ml; ml=$(grep -nF "pr merge $PRURL" "$T/gh-calls.txt" 2>/dev/null | head -1 | cut -d: -f1)
  if [ -n "$ml" ]; then head -n "$((ml - 1))" "$T/gh-calls.txt"; else cat "$T/gh-calls.txt"; fi; }
after() { local ml; ml=$(grep -nF "pr merge $PRURL" "$T/gh-calls.txt" 2>/dev/null | head -1 | cut -d: -f1)
  [ -n "$ml" ] && tail -n +"$((ml + 1))" "$T/gh-calls.txt"; }
rvf() { grep -E "repos/$SLUG/pulls/$NUM/reviews([?]| |\$)" | grep -vcE -- '-X (POST|PUT|PATCH|DELETE)'; }
plf() { grep -E "repos/$SLUG/pulls/$NUM( |\$)" | grep -vE 'v3\.diff' | grep -vcE -- '-X (POST|PUT|PATCH|DELETE)'; }
rv() { visit | rvf; }
pl() { visit | plf; }
skel() { grep -oE "$KEY (WOULD merge|MERGE_REFUSED [a-z-]+|[A-Z_]+ -> [A-Z_]+)" "$MCLOG" 2>/dev/null | sort -u | tr '\n' ' '; }

# W1 the knob off: the read of today.
reset; run_tick MC_TICK_MEMO=0
R0=$(rv); P0=$(pl); S0=$(skel); ROW0=$(row_f 2)
echo "  info W1 MC_TICK_MEMO=0, one keyed tick, 1 READY PR, the visit before the merge: reviews read $R0 time(s), pulls/$NUM $P0 time(s); decision: ${S0:-none}"
visit | grep -E "repos/$SLUG/pulls/$NUM(/reviews)?([?]| |\$)" | grep -v 'v3\.diff' | cut -c1-110 | sed 's/^/  info W1   /'
[ "$R0" -ge 2 ] && ok "W1 the knob off reads the review list at least 2 times in the visit ($R0)" \
  || bad "W1 setup: the knob off read the review list $R0 time(s): $(tail -3 "$MCLOG" 2>/dev/null)"
[ "$P0" -ge 1 ] && ok "W1 the knob off reads pulls/$NUM ($P0)" || bad "W1 setup: no pulls/$NUM read"
[ -s "$T/gh-merges.txt" ] && ok "W1 setup: the tick merged" || bad "W1 setup: no merge: $(grep "$KEY" "$MCLOG" 2>/dev/null | tail -3)"
grep -q "TICK-MEMO" "$MCLOG" 2>/dev/null && bad "W1 the knob off logs no TICK-MEMO line" || ok "W1 the knob off logs no TICK-MEMO line"

# W2 the knob on.
reset; run_tick
R1=$(rv); P1=$(pl); S1=$(skel)
echo "  info W2 MC_TICK_MEMO=1, the same visit: reviews read $R1 time(s), pulls/$NUM $P1 time(s); decision: ${S1:-none}"
eq "W2 MC_TICK_MEMO=1: the review list is read 1 time in the visit (was $R0)" "$R1" 1
# 2, not 1: the open list's read, then the state guard reads live (BH-10316
# review: a step that decides a merge never acts on an earlier read of the tick).
eq "W2 MC_TICK_MEMO=1: pulls/$NUM is read 2 times in the visit (was $P0): the list, then the live state guard" "$P1" 2
eq "W2 the same decision as with the knob off" "$S1" "$S0"
eq "W2 the same row state as with the knob off" "$(row_f 2)" "$ROW0"

# W6 a write between two steps: the merge. The read after it goes to GitHub.
A=$(after | plf)
[ "${A:-0}" -ge 1 ] && ok "W6 pulls/$NUM is read from GitHub after the merge ($A)" \
  || bad "W6 no pulls/$NUM read after the merge: $(after | head -5)"
eq "W6 the row settles MERGED" "$(row_f 2)" MERGED

# W3 a second tick reads GitHub again.
reseed; run_tick
eq "W3 the next tick reads the review list again (1)" "$(rv)" 1
eq "W3 the next tick reads pulls/$NUM again (2)" "$(pl)" 2

# W4 the memo dir is gone; nothing in state/ or flags/.
left=$(find "$T/tmp" -maxdepth 1 -name 'mc-tick-memo.*' 2>/dev/null | head -3)
[ -z "$left" ] && ok "W4 the memo dir is gone after the tick" || bad "W4 memo dir left: $left"
inst=$(find "$T/h/state" "$T/h/flags" -name '*tick-memo*' 2>/dev/null | head -3)
[ -z "$inst" ] && ok "W4 nothing of the memo under state/ or flags/" || bad "W4 memo files under state/flags: $inst"

# W5 one TICK-MEMO line per tick.
eq "W5 two ticks with the knob on: 2 TICK-MEMO lines" "$(cnt "$MCLOG" 'TICK-MEMO tick=[^ ]+ hits=[0-9]+ misses=[0-9]+$')" 2
hits=$(grep -oE 'TICK-MEMO tick=[^ ]+ hits=[0-9]+' "$MCLOG" | tail -1 | grep -oE '[0-9]+$')
[ "${hits:-0}" -ge 1 ] && ok "W5 the line counts the hits ($hits)" || bad "W5 no hits counted: $(grep TICK-MEMO "$MCLOG")"

# W7 a failed review read: the block gate refuses as before (U1 pins that the
# failure is not stored), and the knob off reads the same number of times.
reset; touch "$T/fail-reviews"; run_tick MC_TICK_MEMO=0
RF0=$(rv)
reset; touch "$T/fail-reviews"; run_tick
RF=$(rv)
[ "$RF" -ge 1 ] && ok "W7 a failed review read: the tick asked GitHub ($RF)" || bad "W7 a failed review read was never asked"
eq "W7 a failed review read: the same number of reads as with the knob off" "$RF" "$RF0"
[ -s "$T/gh-merges.txt" ] && bad "W7 a tick that could not read the reviews merged" || ok "W7 no merge on unread reviews"

# W8 the pre-merge state guard reads live. The PR object is read early in the
# tick (the open list); a person then retargets the PR to `release`. The guard
# must see `release` and refuse; a guard that read the memo would merge the PR
# into the new base.
reset; touch "$T/flip-base"; run_tick
[ -s "$T/gh-merges.txt" ] && bad "W8 merged over a base retargeted during the tick: $(cat "$T/gh-merges.txt")" || ok "W8 no merge after a retarget during the tick"
grep -qE "$KEY MERGE_REFUSED: GitHub says this PR is based on release" "$MCLOG" 2>/dev/null \
  && ok "W8 the state guard read the new base live and refused" \
  || bad "W8 the guard did not see the retarget: $(grep "$KEY" "$MCLOG" 2>/dev/null | tail -3)"

# W9 the block gate reads live. A Mergify repo, a READY row with a crdequeue
# line, so the re-queue CR check reads the review list early in the visit
# (no CR). A person then posts CHANGES_REQUESTED. The block gate must see it
# and refuse; a gate that read the memo would let the row go on.
reset; touch "$T/flip-cr"; mkdir -p "$T/h/tmp"; echo mergify > "$T/h/tmp/merge-queue-example-org_demo-os.provider"
echo "crdequeue $KEY $H1" >> "$T/h/state/merge-conductor/attempts.txt"
# The pre-queue gate's verdict is off: it needs a main checkout this world has
# not, and it is not what W9 is about.
run_tick MC_PREQUEUE_GATE=0 MC_PREQUEUE_FALLBACK=0
RW=$(wc -l < "$T/rv-reads" 2>/dev/null | tr -d ' ')
[ "${RW:-0}" -ge 2 ] && ok "W9 setup: the review list was read early and again ($RW)" \
  || bad "W9 setup: review reads ${RW:-0}: $(grep "$KEY" "$MCLOG" 2>/dev/null | tail -3)"
grep -qE "$KEY MERGE_REFUSED block-gate" "$MCLOG" 2>/dev/null \
  && ok "W9 the block gate read the new CHANGES_REQUESTED live and refused" \
  || bad "W9 the gate missed the CHANGES_REQUESTED: $(grep "$KEY" "$MCLOG" 2>/dev/null | tail -3)"

echo "mc-tick-memo.bh-10316: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
