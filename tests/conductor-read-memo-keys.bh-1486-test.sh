#!/bin/bash
# tests/conductor-read-memo-keys.bh-1486-test.sh — the BH-1486 follow-up: what
# the read memo's keys must cover, and what a tick must be able to say it spent.
#
# tests/conductor-read-memo.bh-1486-test.sh pins the memo MECHANISM (one
# stack-parent read per tick, terminal answers only, the TTL, the cadence hold).
# This file pins three things that mechanism does not, each of which was a live
# hole on main before it existed:
#
#   1. TWO BRANCHES, TWO MEMO FILES. tick_memo_file and read_memo_file named
#      themselves with mc_safe_name alone, which maps everything outside
#      [A-Za-z0-9._-] to `_` — so `ticket/x_y` and `ticket/x/y`, two branches
#      that can both exist in one repo, shared one file. A stacked child would
#      be served the OTHER branch's parent state, and the stacked arm ACTS on
#      that answer by retargeting the PR.
#
#   2. THE SCAN MEMO'S KEY COVERS THE SCANNER AND THE BASE. mc_iron_law_scan is
#      its own grep PLUS every CHECK-HIT bin/checks-run.sh finds, and checks-run
#      reads checks/*/check.sh — so deploying a check moved nothing in the old
#      (head, updated_at, attempts) key, and a PR parked in READY went on
#      replaying the count the old catalog produced. A PR's `.diff` is
#      merge-base(base, head)..head, so the base tip belongs in the key for the
#      same reason. An unknown component turns the memo OFF rather than matching
#      as a wildcard.
#
#   3. THE TICK LINE SAYS WHAT THE TICK SPENT. `READ-MEMO … stack_hits=` counts
#      memo HITS, which judges the memo and not the bill: a hit on a read GitHub
#      would have answered 304 saves a round trip and no quota. BH-1486's
#      acceptance is counted calls per tick, so the TICK line carries
#      `reads= counted= cached=` from the ETag counter file the project subshell
#      already arms.
#
# Driven where it can be: section 4 runs bin/merge-conductor.sh itself against a
# stubbed `gh` that logs every invocation. No clock dependency, no network, no
# real git, no sleep. Everything under $T.
# Run from anywhere: tests/conductor-read-memo-keys.bh-1486-test.sh (0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H1=aaaaaaaa1111
BASESHA=1111111111111111111111111111111111111111
BASE2=2222222222222222222222222222222222222222

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" \
         "$T/h/builds" "$T/h/env" "$T/h/checks" "$T/fakebin"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/gh-budget.sh" "$DIR/bin/lib/gh-rest.sh" "$T/h/bin/lib/"
[ -r "$DIR/bin/lib/gh-rest-etag.sh" ] && cp "$DIR/bin/lib/gh-rest-etag.sh" "$T/h/bin/lib/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
cp "$DIR/bin/checks-run.sh" "$T/h/bin/" 2>/dev/null
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init

# The conductor's own helpers are defined in the script, not the lib, so they
# are read out of the copy under test — never redefined here, or this suite
# would be pinning itself.
# shellcheck source=/dev/null
MC_HELPERS=$(sed -n '/^tick_memo_file() {/,/^}/p; /^read_memo_dir()/p; /^read_memo_file()/p; /^read_memo_get() {/,/^}/p; /^read_memo_put() {/,/^}/p; /^scanner_fp() {/,/^}/p; /^scan_memo_fp() {/,/^}/p' "$T/h/bin/lib/mc/locks.sh")
eval "$MC_HELPERS" 2>/dev/null
MC_H="$T/h"

# ============================================================================
# 1. Two branches that mc_safe_name flattens together must get two files.
# ============================================================================
type tick_memo_file >/dev/null 2>&1 && ok \
  || bad "1: tick_memo_file could not be read out of bin/lib/mc/locks.sh"
export MC_TICK_ID=tick-one
A=$(tick_memo_file stack 'example-org/demo-os#ticket/x_y')
B=$(tick_memo_file stack 'example-org/demo-os#ticket/x/y')
[ -n "$A" ] && [ -n "$B" ] && ok || bad "1: tick_memo_file printed nothing"
[ "$A" != "$B" ] && ok \
  || bad "1: ticket/x_y and ticket/x/y must not share a tick memo file — a stacked child would be served the other branch's parent state and retargeted onto it (both: $A)"
# read_memo_file is keyed on `<slug>#<PR number>` and needs no digest — a
# number cannot collide under mc_safe_name — but two different PRs must still
# get two files, which is the property that would break if anyone gave it one.
[ "$(read_memo_file scan 'example-org/demo-os#41')" != "$(read_memo_file scan 'example-org/demo-os#42')" ] && ok \
  || bad "1: two PRs must not share a read-memo file"
# and the same key is still the same file, or the memo never hits at all
[ "$A" = "$(tick_memo_file stack 'example-org/demo-os#ticket/x_y')" ] && ok \
  || bad "1: one key must name one file — a digest that is not stable is a memo that never hits"
# the KIND still separates: a `ci` answer must never be read as a `scan` one
[ "$(read_memo_file ci 'example-org/demo-os#41')" != "$(read_memo_file scan 'example-org/demo-os#41')" ] && ok \
  || bad "1: two kinds of answer for one PR must stay in two files"
[ "$(tick_memo_file stack 'k')" != "$(tick_memo_file other 'k')" ] && ok \
  || bad "1: the tick memo's kind must separate too"

# ============================================================================
# 2. scanner_fp moves when the SCANNER moves, and not otherwise.
# ============================================================================
type scanner_fp >/dev/null 2>&1 && ok || bad "2: scanner_fp is not defined"
FP0=$(scanner_fp)
[ -n "$FP0" ] && ok || bad "2: scanner_fp printed nothing"
[ "$FP0" = "$(scanner_fp)" ] && ok || bad "2: scanner_fp must be stable when nothing moved (it is a cache key)"
mkdir -p "$T/h/checks/new-law"
printf '#!/bin/bash\n# a check deployed to the hub\nexit 0\n' > "$T/h/checks/new-law/check.sh"
chmod +x "$T/h/checks/new-law/check.sh"
FP1=$(scanner_fp)
[ "$FP1" != "$FP0" ] && ok \
  || bad "2: ADDING a check to the catalog must move the fingerprint — otherwise a PR parked in READY never runs the new check (both: $FP0)"
printf '#!/bin/bash\n# edited\nexit 1\n' > "$T/h/checks/new-law/check.sh"
FP2=$(scanner_fp)
[ "$FP2" != "$FP1" ] && ok || bad "2: EDITING a check must move the fingerprint (both: $FP1)"
rm -rf "$T/h/checks/new-law"
[ "$(scanner_fp)" = "$FP0" ] && ok \
  || bad "2: removing the check again must return the original fingerprint"

# ============================================================================
# 3. scan_memo_fp: every component present, or the memo is OFF.
# ============================================================================
type scan_memo_fp >/dev/null 2>&1 && ok || bad "3: scan_memo_fp is not defined"
K1=$(scan_memo_fp 0 "$FP0" "$BASESHA") && ok || bad "3: a complete fingerprint must succeed"
[ -n "$K1" ] && ok || bad "3: a complete fingerprint must print something"
K2=$(scan_memo_fp 1 "$FP0" "$BASESHA")
[ "$K2" != "$K1" ] && ok || bad "3: a moved attempts count must move the fingerprint"
K3=$(scan_memo_fp 0 "$FP1" "$BASESHA")
[ "$K3" != "$K1" ] && ok || bad "3: a moved SCANNER must move the fingerprint"
K4=$(scan_memo_fp 0 "$FP0" "$BASE2")
[ "$K4" != "$K1" ] && ok \
  || bad "3: a moved BASE must move the fingerprint when the tick could read it"
# THE SCANNER IS MANDATORY, THE BASE IS NOT. A scanner we cannot identify might
# be a NEWER one, and replaying past it is the unsafe direction. A stale base
# can only make the count too HIGH — moving the merge base forward removes
# added lines from a patch, it never introduces one — so it parks a PR that
# would now pass, which is fail-safe, and it costs the memo nothing to carry a
# shared `nobase` token on the ticks that could not read it.
scan_memo_fp 0 "" "$BASESHA" >/dev/null 2>&1 && bad "3: an unreadable SCANNER must refuse (rc 1) — replaying past a check that may be newer is the unsafe direction" || ok
scan_memo_fp "" "$FP0" "$BASESHA" >/dev/null 2>&1 && bad "3: an unreadable attempts count must refuse" || ok
NB1=$(scan_memo_fp 0 "$FP0" "") && ok || bad "3: an unreadable base must NOT turn the memo off — that would kill it on every box with MC_LAND_REBASE=0"
NB2=$(scan_memo_fp 0 "$FP0" -)
[ -n "$NB1" ] && [ "$NB1" = "$NB2" ] && ok \
  || bad "3: an empty base and the tsv '-' placeholder are the same unknown and must build the same token ('$NB1' vs '$NB2')"
[ "$NB1" != "$K1" ] && ok || bad "3: an unknown base must not build the SAME token as a known one"
[ "$(scan_memo_fp 0 "$FP1" "")" != "$NB1" ] && ok \
  || bad "3: the scanner must still separate two tokens that share an unknown base"
# an empty fingerprint must turn the memo off at BOTH ends, or an "off" memo
# would still store and still replay
read_memo_put scan 'example-org/demo-os#41' "$H1" 2026-09-22T10:00:00Z "" 3
read_memo_get scan 'example-org/demo-os#41' "$H1" 2026-09-22T10:00:00Z "" >/dev/null 2>&1 \
  && bad "3: an empty fingerprint must never store and never replay" || ok
# the real token round-trips: stored under K1, replayed under K1, missed under K3
read_memo_put scan 'example-org/demo-os#41' "$H1" 2026-09-22T10:00:00Z "$K1" 3
[ "$(read_memo_get scan 'example-org/demo-os#41' "$H1" 2026-09-22T10:00:00Z "$K1")" = 3 ] && ok \
  || bad "3: a scan stored under the full fingerprint must replay under it — read_memo_put used to refuse any non-numeric fingerprint SILENTLY, which is a memo that never hits"
read_memo_get scan 'example-org/demo-os#41' "$H1" 2026-09-22T10:00:00Z "$K3" >/dev/null 2>&1 \
  && bad "3: a scan stored before a check was deployed must MISS after it" || ok
# AND THE nobase TOKEN MUST ROUND-TRIP TOO. read_memo_put screens the
# fingerprint against a charset and refuses a bad one SILENTLY, on the put side
# only — so a token it will not store is a memo that stores nothing and hits
# nothing, and looks in review exactly like a memo that is simply cold. The
# hex-only charset did that to `nobase`, on every box whose base read is
# degraded, and only an assertion that actually stores and replays that token
# can see it.
read_memo_put scan 'example-org/demo-os#44' "$H1" 2026-09-22T10:00:00Z "$NB1" 2
[ "$(read_memo_get scan 'example-org/demo-os#44' "$H1" 2026-09-22T10:00:00Z "$NB1")" = 2 ] && ok \
  || bad "3: a scan keyed with an unknown base must STORE and REPLAY — read_memo_put refusing the token silently is a memo that never hits"

# ============================================================================
# The driven fixture: one PR, approved and CI-green, in observe mode.
# ============================================================================
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
case "$M $URL" in
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
# mk_git <sha> — the ONLY git this fixture runs is the land trigger's
# ls-remote, which is what gives the scan memo's key its base tip. Everything
# else goes to the real git, so a stray call cannot pass by accident. It is a
# function because section 6 moves the base between two ticks.
mk_git() {
  cat > "$T/fakebin/git" <<EOF
#!/bin/bash
for a in "\$@"; do
  if [ "\$a" = ls-remote ]; then printf '%s\trefs/heads/main\n' "$1"; exit 0; fi
done
exec /usr/bin/git "\$@"
EOF
  chmod +x "$T/fakebin/git"
}
mk_git "$BASESHA"
REC="$T/h/builds/demo-os-TK-43-202609220001"; mkdir -p "$REC"
echo "PR_CREATED https://github.com/example-org/demo-os/pull/43" > "$REC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
echo "$H1" > "$REC/reviewed-sha"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"pr merge"*|*"api -X PATCH"*|*"api -i -X PATCH"*|*"api -i -X POST"*|*"api -i -X DELETE"*|*"pr edit"*|*"pr review"*)
    exit 1 ;;
  *"/pulls/43/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/43"*"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/43"*)
    restpr OPEN "$H1" ticket/TK-43 main "" MERGEABLE CLEAN app/cromford "" ;;
  *"api -i -X GET repos/example-org/demo-os/pulls -f state=all"*) restpr --raw 200 '[]' ;;
  *"pr list -R example-org/demo-os --state open"*)
    cat <<J
[{"number":43,"url":"https://github.com/example-org/demo-os/pull/43","headRefOid":"$H1","headRefName":"ticket/TK-43","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"main","updatedAt":"2026-09-22T10:00:00Z"}]
J
    ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) printf 'completed|success\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
TICK() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x GH_TOKEN=stubtoken \
             env MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 "$@" \
             bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) \
          || { echo "tick rc=$? stderr:"; head -3 "$T/tick.err"; }; }
calls() { grep -cF -- "$1" "$T/gh-calls.txt" 2>/dev/null || true; }
state_of() { awk -F'\t' -v k="$1" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv"; }
rm -f "$T/h/state/merge-conductor/read-memo"/* 2>/dev/null
rm -rf "$T/h/state/merge-conductor" "$T/h/logs"; mkdir -p "$T/h/logs"; : > "$T/gh-calls.txt"
unset MC_TICK_ID

# ============================================================================
# 4. The TICK line carries what the tick spent, and the numbers add up.
# ============================================================================
TICK
[ "$(state_of 'example-org/demo-os#43')" = READY ] && ok \
  || bad "4: #43 must classify READY in observe mode, or this tick read nothing worth counting (got '$(state_of 'example-org/demo-os#43')')"
TL=$(grep -o 'TICK demo-os .*' "$T/h/logs/merge-conductor.log" 2>/dev/null | tail -1)
[ -n "$TL" ] && ok || bad "4: no TICK line for demo-os"
case "$TL" in
  *" reads="*" counted="*" cached="*) ok ;;
  *) bad "4: the TICK line must carry reads=N counted=M cached=K (got '$TL')" ;;
esac
RDS=$(printf '%s' "$TL" | sed -n 's/.* reads=\([0-9][0-9]*\) .*/\1/p')
CNT=$(printf '%s' "$TL" | sed -n 's/.* counted=\([0-9][0-9]*\) .*/\1/p')
CCH=$(printf '%s' "$TL" | sed -n 's/.* cached=\([0-9][0-9]*\).*/\1/p')
[ -n "$RDS" ] && [ -n "$CNT" ] && [ -n "$CCH" ] && ok \
  || bad "4: all three must be numbers (reads='$RDS' counted='$CNT' cached='$CCH')"
[ "${RDS:-0}" -gt 0 ] && ok \
  || bad "4: a tick that read a PR must report more than zero reads — a counter that always says 0 proves nothing (got $RDS)"
[ "${RDS:-0}" = "$(( ${CNT:-0} + ${CCH:-0} ))" ] && ok \
  || bad "4: reads must be counted + cached (got $RDS vs $CNT + $CCH)"
[ "$(jq -r '.reads' "$T/h/state/merge-conductor/tick-demo-os.json" 2>/dev/null)" = "$RDS" ] && ok \
  || bad "4: tick-demo-os.json must carry the same reads value as the log line"
# the existing READ-MEMO line is NOT replaced: it answers a different question
grep -q 'READ-MEMO tick=' "$T/h/logs/merge-conductor.log" && ok \
  || bad "4: the READ-MEMO hit line must still be logged — this adds a counter, it does not take one away"

# ============================================================================
# 5. A check deployed between two ticks makes the parked PR read its diff again.
# ============================================================================
D1=$(calls v3.diff)
[ "$D1" = 1 ] && ok || bad "5: the first tick must read the diff once (got $D1)"
TICK
[ "$(calls v3.diff)" = 1 ] && ok \
  || bad "5: a second tick with nothing moved must replay the scan, not re-read the patch (total: $(calls v3.diff))"
mkdir -p "$T/h/checks/new-law"
printf '#!/bin/bash\n# a check deployed to the hub between two ticks\nexit 0\n' > "$T/h/checks/new-law/check.sh"
chmod +x "$T/h/checks/new-law/check.sh"
TICK
[ "$(calls v3.diff)" = 2 ] && ok \
  || bad "5: a CHECK DEPLOYED to the catalog must make a PR parked in READY scan its diff again — head, updatedAt and base all stood still, and on main nothing in the key moved (total diff reads: $(calls v3.diff))"
[ "$(state_of 'example-org/demo-os#43')" = READY ] && ok \
  || bad "5: the re-scanned tick must reach the same verdict (got '$(state_of 'example-org/demo-os#43')')"

# ============================================================================
# 6. The project base moving makes the parked PR read its diff again.
#
#    The base tip is the key's third component, and unlike the scanner it is
#    advisory: a stale base can only make the count too HIGH (moving the merge
#    base forward removes added lines from a patch, it never adds one), so it
#    parks a PR that would now pass. Advisory is not the same as ignored,
#    though — when the tick CAN read the base, a move must be seen, and this is
#    the case that says so end to end rather than at the fingerprint.
# ============================================================================
rm -rf "$T/h/checks/new-law"
TICK
BEFORE=$(calls v3.diff)
TICK
[ "$(calls v3.diff)" = "$BEFORE" ] && ok \
  || bad "6: the tick after the catalog went back to normal must settle, not re-read (got $(calls v3.diff) vs $BEFORE)"
mk_git "$BASE2"
TICK
[ "$(calls v3.diff)" = $((BEFORE + 1)) ] && ok \
  || bad "6: the project BASE moving must make a parked PR read its diff again — its merge base moved, so the patch it is scanning is not the patch that was scanned (total: $(calls v3.diff), expected $((BEFORE + 1)))"
[ "$(state_of 'example-org/demo-os#43')" = READY ] && ok \
  || bad "6: the re-scanned tick must reach the same verdict (got '$(state_of 'example-org/demo-os#43')')"
# and it settles again on the new base
TICK
[ "$(calls v3.diff)" = $((BEFORE + 1)) ] && ok \
  || bad "6: the tick after the base move must replay, not read a third time (total: $(calls v3.diff))"

echo "conductor-read-memo-keys.bh-1486-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
