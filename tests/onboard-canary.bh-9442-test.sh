#!/bin/bash
# tests/onboard-canary.bh-9442-test.sh — BH-9442: bin/onboard-canary.sh, the
# onboarding canary. A new repo builds no ticket until a no-op PR is green in
# the repo's own CI.
#
# The REAL script runs from a scratch harness ($T/h/bin) with the real
# bin/lib/gh-rest.sh, a `gh` fake on PATH that serves fixture JSON by method and
# path and logs any unknown path, a file-backed jobs client, a fleet-conf stub
# and a lane-alert stub. No network, no clock (ONBOARD_CANARY_NOW).
#
#   D-a..D-t  the decision rule and the first error line, one project per case
#             (D-l2: past the grace with workflows present stays pending)
#   S1        --start opens the branch, the marker commit and the PR once; a
#             second --start reuses the pending canary; an open canary PR on
#             GitHub is reused
#   R1        --hold, --tick to green: row green + same sha, gate released, the
#             gate fragment admits, --status prints green with the sha, the PR
#             is closed and its branch deleted (never merged)
#   R2        --hold, --tick to no-checks: gate stays held, the gate defers,
#             --override releases it and the gate admits
#   O1        --override with an empty reason is refused, the gate stays held
#   A1        a red canary ticked twice writes exactly 1 alert, naming the check
#   W1        --weekly red on a project with no gate row: alert, gate row absent
#   W2        --weekly skips a project with a canary_skip row and a pending one
#   N1        a new head sha on the PR is recorded and stays pending
#   X1..X4    exit codes: 0 / 75 (5xx, state unchanged) / 2 (no jobs client) /
#             1 (PR create refused: no state file, one start alert)
#   X5        a failed verdict row write: rc 2, the state file stays pending
#   K1        the timeout knob ONBOARD_CANARY_TIMEOUT_MIN=1 is what the timeout uses
#   AD1       a pending row with no hub file is adopted by the tick
#   RO1       a green verdict whose gate read fails never drops the release:
#             release_owed stays set while the read fails, the next readable
#             tick releases (lead review of #9490: never held forever silently)
#   HW1..HW6  the hold bound: a project held past ONBOARD_CANARY_HELD_ALERT_HOURS
#             (default 24) gets one alert, id onboard-canary:<p>:held; under the
#             bound, with an override, or on a gate read failure: no alert and
#             no release; a hold with no held_at row starts the clock; the knob
#             sets the bound; a release resolves the held alert
#   E1        onboard-run.sh `ready` prints the canary line and stays rc 0
#             (also with the script absent or failing)
#   RV1       bin/review-prs.sh's PR list drops a harness/onboard-canary-* head
#   E2        the load-project.sh block prints `== onboarding canary ==` and
#             keeps rc 0 when the canary fails
#   M1        the shipped bin/onboard-canary.sh is executable (git mode 100755):
#             cron, load-project.sh and the `ready` arm (`[ -x ]`) run it directly
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/onboard-canary.bh-9442-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
[ -f "$DIR/bin/onboard-canary.sh" ] || { echo "FAIL: bin/onboard-canary.sh is missing"; exit 1; }

H="$T/h"; FX="$T/fx"; ROWS="$T/rows"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state/onboard-canary" "$FX" "$ROWS" "$T/stub"
cp "$DIR/bin/onboard-canary.sh" "$H/bin/"
# scratch-closure-allow: gh-rest.sh alone, on purpose: the closure of bin/onboard-canary.sh brings lane-gate.sh, gh-app-auth.sh and the gh-rest etag cache and quota ledger, which would read live knobs and carry cache state between cases
cp "$DIR/bin/lib/gh-rest.sh" "$H/bin/lib/"
: > "$T/projects"; : > "$T/alerts.log"; : > "$T/unknown.log"; : > "$T/gh-calls.log"

cat > "$H/bin/jobs-client.sh" <<EOF
#!/bin/bash
# file-backed settings; ROWS/.set-rc forces the setting-set rc, ROWS/.get-rc.<key> one key's read rc
case "\$1" in
  setting-get) [ -f "$ROWS/.get-rc.\$2" ] && exit "\$(cat "$ROWS/.get-rc.\$2")"
    [ -f "$ROWS/\$2" ] || { echo; exit 2; }; cat "$ROWS/\$2"; echo ;;
  setting-set) [ -f "$ROWS/.set-rc" ] && exit "\$(cat "$ROWS/.set-rc")"; printf '%s' "\$3" > "$ROWS/\$2" ;;
  *) exit 2 ;;
esac
EOF
cat > "$H/bin/fleet-conf.sh" <<EOF
#!/bin/bash
[ "\$1" = --projects ] && { cat "$T/projects"; exit 0; }
[ "\$2" = repo ] && { echo "Test/\$1"; exit 0; }
exit 1
EOF
cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/alerts.log"
EOF
# The gh fake: fixture file FX/<key> (key = "<METHOD> <path>" with every other
# char as _), FX/<key>.status the HTTP status (default 200). No fixture: the
# call is logged to unknown.log and fails like a network error.
cat > "$T/stub/gh" <<EOF
#!/bin/bash
[ "\$1" = api ] || { echo "UNKNOWN \$*" >> "$T/unknown.log"; exit 1; }
shift; m=GET
while [ \$# -gt 0 ]; do case "\$1" in -i) shift ;; -X) m="\$2"; shift 2 ;; *) break ;; esac; done
p="\$1"; shift
echo "\$m \$p \$*" >> "$T/gh-calls.log"
k=\$(printf '%s %s' "\$m" "\$p" | tr -c 'A-Za-z0-9._-' '_')
if [ ! -f "$FX/\$k" ] && [ ! -f "$FX/\$k.status" ]; then echo "UNKNOWN \$m \$p" >> "$T/unknown.log"; exit 1; fi
st=200; [ -f "$FX/\$k.status" ] && st=\$(cat "$FX/\$k.status")
printf 'HTTP/1.1 %s X\r\nContent-Type: application/json\r\n\r\n' "\$st"
[ -f "$FX/\$k" ] && cat "$FX/\$k"
case "\$st" in 2*) exit 0 ;; *) exit 1 ;; esac
EOF
chmod +x "$H/bin/"*.sh "$T/stub/gh"

NOW=1800000000
fxk() { printf '%s %s' "$1" "$2" | tr -c 'A-Za-z0-9._-' '_'; }
fx() { # fx <METHOD> <path> <body> [status]
  local k; k=$(fxk "$1" "$2")
  printf '%s' "$3" > "$FX/$k"
  if [ -n "${4:-}" ]; then printf '%s' "$4" > "$FX/$k.status"; else rm -f "$FX/$k.status"; fi
}
oc() { # oc <args...> — sets OUT and RC
  OUT=$(cd "$T" && env -u BUILDER_EXEC HARNESS="$H" ONBOARD_CANARY_NOW="${CNOW:-$NOW}" PATH="$T/stub:$PATH" \
    ${OC_ENV[@]+"${OC_ENV[@]}"} bash "$H/bin/onboard-canary.sh" "$@" 2>&1); RC=$?
}
OC_ENV=()
sha_of() { printf '%040d' "$1" | tr 0 a | sed "s/^a/$1/" | cut -c1-40; }
st() { jq -r ".$2" "$H/state/onboard-canary/$1.json" 2>/dev/null; }
row() { jq -r ".$2" "$ROWS/onboard.$1.canary" 2>/dev/null; }
# A --resolve line closes an alert; it is not one.
nalerts() { grep -v -- '--resolve' "$T/alerts.log" | grep -c -- "--id onboard-canary:$1:"; }

# seed <p> <sha> <opened-min-ago> [mode] — a pending canary and its PR fixtures.
seed() {
  local p="$1" sha="$2" ago="$3" mode="${4:-hold}"
  jq -nc --arg p "$p" --arg sha "$sha" --argjson o $((NOW - ago * 60)) --arg m "$mode" \
    '{project:$p, slug:("Test/" + $p), state:"pending", pr:1, url:("https://github.com/Test/" + $p + "/pull/1"), sha:$sha, branch:"harness/onboard-canary-x", opened:$o, mode:$m, closed:false}' \
    > "$H/state/onboard-canary/$p.json"
  fx GET "repos/Test/$p/pulls/1" "$(jq -nc --arg s "$sha" '{state:"open", head:{sha:$s, ref:"harness/onboard-canary-x"}}')"
  fx PATCH "repos/Test/$p/pulls/1" '{"state":"closed"}'
  fx DELETE "repos/Test/$p/git/refs/heads/harness/onboard-canary-x" '' 204
  fx GET "repos/Test/$p/commits/$sha/status" '{"state":"pending","statuses":[]}'
  fx GET "repos/Test/$p/actions/workflows?per_page=1" '{"total_count":1,"workflows":[{}]}'
}
runs() { # runs <p> <sha> <json array of check runs> [page] [total]
  local n; n=$(jq 'length' <<<"$3")
  fx GET "repos/Test/$1/commits/$2/check-runs?per_page=100&page=${4:-1}" \
    "$(jq -nc --argjson r "$3" --argjson t "${5:-$n}" '{total_count:$t, check_runs:$r}')"
}
cr() { # cr <name> <status> <conclusion|null> [title] [summary] [id]
  jq -nc --arg n "$1" --arg s "$2" --arg c "$3" --arg t "${4:-}" --arg su "${5:-}" --argjson id "${6:-1}" \
    '{id:$id, name:$n, status:$s, conclusion:(if $c == "null" then null else $c end), details_url:("https://ci.test/" + $n), output:{title:(if $t == "" then null else $t end), summary:(if $su == "" then null else $su end)}}'
}
case_verdict() { # case_verdict <label> <p> <want-state>
  oc --tick
  local got; got=$(st "$2" state)
  [ "$got" = "$3" ] && ok || bad "$1 want $3, got '$got' (rc=$RC out=$OUT)"
}

# ══ D: the decision rule ════════════════════════════════════════════════════
S=$(sha_of 1)
# green
seed d-a "$S" 3; runs d-a "$S" "[$(cr build completed success),$(cr test completed success)]"
case_verdict D-a d-a green
seed d-b "$S" 3; runs d-b "$S" "[$(cr a completed success),$(cr b completed skipped),$(cr c completed neutral)]"
case_verdict D-b d-b green
seed d-c "$S" 3; runs d-c "$S" '[]'
fx GET "repos/Test/d-c/commits/$S/status" '{"state":"success","statuses":[{"context":"ci/legacy","state":"success","target_url":"https://ci.test/l"}]}'
case_verdict D-c d-c green
seed d-d "$S" 3
runs d-d "$S" "[$(cr p1 completed success)]" 1 2; runs d-d "$S" "[$(cr p2 completed success)]" 2 2
case_verdict D-d d-d green
grep -q "check-runs?per_page=100&page=2" "$T/gh-calls.log" && ok || bad "D-d page 2 was never read"
# red
seed d-e "$S" 3; runs d-e "$S" "[$(cr 'E2E Tests' completed failure 'Playwright failed'),$(cr lint completed success)]"
case_verdict D-e d-e red
[ "$(st d-e failing)" = "E2E Tests" ] && ok || bad "D-e failing want 'E2E Tests', got '$(st d-e failing)'"
seed d-f "$S" 3; runs d-f "$S" "[$(cr slow completed timed_out x)]"; case_verdict D-f d-f red
seed d-g "$S" 3; runs d-g "$S" "[$(cr gone completed cancelled x)]"; case_verdict D-g d-g red
seed d-h "$S" 3; runs d-h "$S" "[$(cr ok completed success)]"
fx GET "repos/Test/d-h/commits/$S/status" '{"state":"error","statuses":[{"context":"vercel","state":"error","description":"Deployment failed","target_url":"https://v.test"}]}'
case_verdict D-h d-h red
[ "$(st d-h failing)" = vercel ] && [ "$(st d-h first_error)" = "Deployment failed" ] && ok || bad "D-h want vercel / Deployment failed, got '$(st d-h failing)' / '$(st d-h first_error)'"
seed d-i "$S" 3; runs d-i "$S" "[$(cr bad completed failure x),$(cr long in_progress null)]"; case_verdict D-i d-i red
# pending, near misses
seed d-j "$S" 3; runs d-j "$S" "[$(cr a completed success),$(cr b in_progress null)]"; case_verdict D-j d-j pending
seed d-k "$S" 3; runs d-k "$S" "[$(cr q queued null)]"; case_verdict D-k d-k pending
seed d-l "$S" 3; runs d-l "$S" '[]'; case_verdict D-l d-l pending
# past the grace, 0 checks yet, but the repo has workflows: still pending (the workflows read decides)
seed d-l2 "$S" 11; runs d-l2 "$S" '[]'; case_verdict D-l2 d-l2 pending
grep -q 'GET repos/Test/d-l2/actions/workflows' "$T/gh-calls.log" && ok || bad "D-l2 the workflows list was never read"
# no-checks
seed d-m "$S" 11; runs d-m "$S" '[]'; fx GET "repos/Test/d-m/actions/workflows?per_page=1" '{"total_count":0,"workflows":[]}'
case_verdict D-m d-m no-checks
seed d-n "$S" 61; runs d-n "$S" '[]'; case_verdict D-n d-n no-checks
# timeout
seed d-o "$S" 61; runs d-o "$S" "[$(cr ok completed success),$(cr 'Playwright E2E' in_progress null)]"
case_verdict D-o d-o red
grep -q "timeout after 60 min, still running: Playwright E2E" <<<"$(st d-o reason)" && ok || bad "D-o reason '$(st d-o reason)'"
grep -- "--id onboard-canary:d-o:" "$T/alerts.log" | grep -q 'still running: Playwright E2E' && ok || bad "D-o the alert must name the running check"
# first error line
seed d-p "$S" 3; runs d-p "$S" "[$(cr t completed failure 'Type error in app.ts' 'ignored')]"; case_verdict D-p d-p red
[ "$(st d-p first_error)" = "Type error in app.ts" ] && ok || bad "D-p first_error '$(st d-p first_error)'"
seed d-q "$S" 3; runs d-q "$S" "[$(cr t completed failure '' $'\n  \nline one\nline two')]"; case_verdict D-q d-q red
[ "$(st d-q first_error)" = "line one" ] && ok || bad "D-q first_error '$(st d-q first_error)'"
seed d-r "$S" 3; runs d-r "$S" "[$(cr t completed failure '' '' 77)]"
fx GET "repos/Test/d-r/check-runs/77/annotations" '[{"annotation_level":"warning","message":"w"},{"annotation_level":"failure","message":"expect(page).toHaveTitle failed"}]'
case_verdict D-r d-r red
[ "$(st d-r first_error)" = "expect(page).toHaveTitle failed" ] && ok || bad "D-r first_error '$(st d-r first_error)'"
seed d-s "$S" 3; runs d-s "$S" "[$(cr t completed failure '' '' 78)]"
fx GET "repos/Test/d-s/check-runs/78/annotations" '[]'
case_verdict D-s d-s red
[ "$(st d-s first_error)" = "conclusion=failure https://ci.test/t" ] && ok || bad "D-s first_error '$(st d-s first_error)'"
LONG=$(printf 'x%.0s' $(seq 1 500))
seed d-t "$S" 3; runs d-t "$S" "[$(cr t completed failure "$LONG")]"; case_verdict D-t d-t red
[ "$(st d-t first_error | wc -c)" = 201 ] && ok || bad "D-t first_error length $(st d-t first_error | wc -c) (want 200 + newline)"

# ══ A1: one alert per red, naming the check and the first error ═════════════
oc --tick; oc --tick
[ "$(nalerts d-e)" = 1 ] && ok || bad "A1 want 1 alert for d-e, got $(nalerts d-e)"
grep -- "--id onboard-canary:d-e:$(cut -c1-12 <<<"$S")" "$T/alerts.log" | grep -q 'Failing checks: E2E Tests\..*First error: Playwright failed' \
  && ok || bad "A1 alert text: $(grep -- 'onboard-canary:d-e' "$T/alerts.log")"
[ "$(nalerts d-a)" = 0 ] && ok || bad "A1 a green canary must not alert"
[ "$(row d-e state)" = red ] && [ "$(row d-e sha)" = "$S" ] && ok || bad "A1 row: $(cat "$ROWS/onboard.d-e.canary" 2>/dev/null)"
[ "$(wc -c < "$ROWS/onboard.d-e.canary")" -le 256 ] && ok || bad "A1 the row must fit the 256-char settings value"

# ══ S1: start opens once, then reuses ═══════════════════════════════════════
P=s1; SH=$(sha_of 2); BS=$(sha_of 3)
fx GET "repos/Test/$P/pulls?state=open&per_page=100" '[{"number":5,"head":{"ref":"feature/x","sha":"f"}}]'
fx GET "repos/Test/$P" '{"default_branch":"main"}'
fx GET "repos/Test/$P/git/ref/heads/main" "{\"object\":{\"sha\":\"$BS\"}}"
fx POST "repos/Test/$P/git/refs" '{}' 201
fx GET "repos/Test/$P/contents/.harness/onboard-canary.md?ref=harness/onboard-canary-202701150800" '{"message":"Not Found"}' 404
fx PUT "repos/Test/$P/contents/.harness/onboard-canary.md" "{\"commit\":{\"sha\":\"$SH\"}}" 201
fx POST "repos/Test/$P/pulls" "{\"number\":9,\"html_url\":\"https://github.com/Test/$P/pull/9\",\"head\":{\"sha\":\"$SH\",\"ref\":\"harness/onboard-canary-202701150800\"}}" 201
: > "$T/gh-calls.log"
oc --start "$P"
if [ "$RC" = 0 ] && [ "$(st $P state)" = pending ] && [ "$(st $P pr)" = 9 ] && [ "$(st $P sha)" = "$SH" ] && [ "$(st $P mode)" = weekly ] \
   && [ "$(row $P state)" = pending ] && grep -q "POST repos/Test/$P/git/refs -f ref=refs/heads/harness/onboard-canary-202701150800 -f sha=$BS" "$T/gh-calls.log" \
   && [ "$(grep -c "POST repos/Test/$P/pulls" "$T/gh-calls.log")" = 1 ]; then ok
else bad "S1 start: rc=$RC out=$OUT state=$(cat "$H/state/onboard-canary/$P.json" 2>/dev/null) calls=$(cat "$T/gh-calls.log")"; fi
grep -q 'title=\[harness\] onboarding canary, do not merge' "$T/gh-calls.log" && ok || bad "S1 PR title"
: > "$T/gh-calls.log"; oc --start "$P"
[ "$RC" = 0 ] && [ ! -s "$T/gh-calls.log" ] && grep -q reused <<<"$OUT" && ok || bad "S1 a second start must reuse with 0 calls: $OUT / $(cat "$T/gh-calls.log")"
P=s1b
fx GET "repos/Test/$P/pulls?state=open&per_page=100" "[{\"number\":4,\"html_url\":\"https://github.com/Test/$P/pull/4\",\"created_at\":\"2027-01-15T07:50:00Z\",\"head\":{\"ref\":\"harness/onboard-canary-202701140000\",\"sha\":\"$SH\"}}]"
: > "$T/gh-calls.log"; oc --start "$P"
[ "$RC" = 0 ] && [ "$(st $P pr)" = 4 ] && ! grep -q POST "$T/gh-calls.log" && ok || bad "S1 an open canary PR on GitHub must be reused: $OUT / $(cat "$T/gh-calls.log")"
rm -f "$H/state/onboard-canary/s1.json" "$H/state/onboard-canary/s1b.json"

# ══ R1: hold -> tick green -> released -> the gate admits ═══════════════════
gate_run() { # gate_run <p> — the real fragment; sets GRC
  rm -rf "$T/gb"; mkdir -p "$T/gb"
  ( cd "$T" && env -u BUILDER_EXEC -u RESUME_BUILD HARNESS="$H" BUILD="$T/gb" PROJECT="$1" KEY=K-1 bash -u -c '
    STAMP() { echo t; }; RESULT() { echo "RESULT $1"; }
    . "'"$DIR"'/bin/lib/rb/gates.d/onboard-canary.sh"; echo ADMITTED' ) > "$T/gate.out" 2>&1; GRC=$?
}
startfx() { # startfx <p> <head-sha> — the GitHub side of one fresh canary PR #3
  local p="$1"
  fx GET "repos/Test/$p/pulls?state=open&per_page=100" '[]'
  fx GET "repos/Test/$p" '{"default_branch":"main"}'
  fx GET "repos/Test/$p/git/ref/heads/main" "{\"object\":{\"sha\":\"$BS\"}}"
  fx POST "repos/Test/$p/git/refs" '{}' 201
  fx GET "repos/Test/$p/contents/.harness/onboard-canary.md?ref=harness/onboard-canary-202701150800" '' 404
  fx PUT "repos/Test/$p/contents/.harness/onboard-canary.md" "{\"commit\":{\"sha\":\"$2\"}}" 201
  fx POST "repos/Test/$p/pulls" "{\"number\":3,\"html_url\":\"https://github.com/Test/$p/pull/3\",\"head\":{\"sha\":\"$2\",\"ref\":\"harness/onboard-canary-202701150800\"}}" 201
  fx GET "repos/Test/$p/pulls/3" "{\"state\":\"open\",\"head\":{\"sha\":\"$2\",\"ref\":\"harness/onboard-canary-202701150800\"}}"
  fx PATCH "repos/Test/$p/pulls/3" '{"state":"closed"}'
  fx DELETE "repos/Test/$p/git/refs/heads/harness/onboard-canary-202701150800" '' 204
  fx GET "repos/Test/$p/commits/$2/status" '{"state":"pending","statuses":[]}'
  fx GET "repos/Test/$p/actions/workflows?per_page=1" '{"total_count":0}'
}
P=r1; SR=$(sha_of 4); startfx "$P" "$SR"
oc --hold "$P"
[ "$RC" = 0 ] && [ "$(cat "$ROWS/onboard.$P.canary_gate")" = held ] && [ "$(st $P mode)" = hold ] \
  && grep -qx "canary: held, PR https://github.com/Test/$P/pull/3, tickets wait for green" <<<"$OUT" && ok || bad "R1 hold: rc=$RC out=$OUT"
gate_run "$P"; [ "$GRC" = 3 ] && grep -q 'RESULT BUILD_DEFERRED onboard-canary held: pending' "$T/gate.out" && ok || bad "R1 a held pending project must defer: $(cat "$T/gate.out")"
runs "$P" "$SR" "[$(cr build completed success)]"
: > "$T/gh-calls.log"; oc --tick
if [ "$(row $P state)" = green ] && [ "$(row $P sha)" = "$SR" ] && [ "$(cat "$ROWS/onboard.$P.canary_gate")" = released ]; then ok
else bad "R1 green: row=$(cat "$ROWS/onboard.$P.canary" 2>/dev/null) gate=$(cat "$ROWS/onboard.$P.canary_gate")"; fi
grep -q "PATCH repos/Test/$P/pulls/3 -f state=closed" "$T/gh-calls.log" && grep -q "DELETE repos/Test/$P/git/refs/heads/harness/onboard-canary-202701150800" "$T/gh-calls.log" \
  && [ "$(st $P closed)" = true ] && ok || bad "R1 the PR must be closed and the branch deleted: $(cat "$T/gh-calls.log")"
grep -q 'pulls/[0-9]*/merge' "$T/gh-calls.log" && bad "R1 the canary must never merge" || ok
gate_run "$P"; [ "$GRC" = 0 ] && grep -q ADMITTED "$T/gate.out" && ok || bad "R1 released must admit: $(cat "$T/gate.out")"
oc --status "$P"
[ "$OUT" = "$P released green $(cut -c1-12 <<<"$SR") https://github.com/Test/$P/pull/3 $(date -u -d "@$NOW" +%FT%TZ)" ] && ok || bad "R1 status line: '$OUT'"
[ "$(nalerts $P)" = 0 ] && ok || bad "R1 green must not alert"
[ "$(cat "$ROWS/onboard.$P.canary_held_at" 2>/dev/null)" = "$NOW" ] && ok || bad "R1 --hold must start the hold clock: held_at='$(cat "$ROWS/onboard.$P.canary_held_at" 2>/dev/null)'"
grep -q -- "--resolve --id onboard-canary:$P:held" "$T/alerts.log" && ok || bad "R1 the release must resolve the held alert"

# ══ R2 + O1: no workflows -> no-checks, held; override releases ═════════════
P=r2; SR=$(sha_of 5); startfx "$P" "$SR"; runs "$P" "$SR" '[]'
oc --hold "$P"
CNOW=$((NOW + 11 * 60)) oc --tick
[ "$(st $P state)" = no-checks ] && [ "$(cat "$ROWS/onboard.$P.canary_gate")" = held ] && ok || bad "R2 want no-checks + held: $(st $P state) $(cat "$ROWS/onboard.$P.canary_gate")"
grep -- "--id onboard-canary:$P:" "$T/alerts.log" | grep -q 'no checks' && ok || bad "R2 the alert must say no checks"
gate_run "$P"; [ "$GRC" = 3 ] && grep -q 'held: no-checks' "$T/gate.out" && ok || bad "R2 no-checks must defer: $(cat "$T/gate.out")"
oc --override "$P" "  "
[ "$RC" = 64 ] && [ "$(cat "$ROWS/onboard.$P.canary_gate")" = held ] && [ ! -f "$ROWS/onboard.$P.canary_override" ] && ok || bad "O1 empty override must be refused: rc=$RC"
gate_run "$P"; [ "$GRC" = 3 ] && ok || bad "O1 still deferred after a refused override"
oc --override "$P" "static site, no CI, accepted"
[ "$RC" = 0 ] && [ "$(cat "$ROWS/onboard.$P.canary_gate")" = released ] && ok || bad "R2 override: rc=$RC out=$OUT"
gate_run "$P"; [ "$GRC" = 0 ] && ok || bad "R2 override must admit: $(cat "$T/gate.out")"

# ══ W1 / W2: the weekly run ═════════════════════════════════════════════════
P=w1; SR=$(sha_of 6); startfx "$P" "$SR"; runs "$P" "$SR" "[$(cr 'E2E Tests' completed failure boom)]"
printf 'w1\nw2skip\nd-j\n' > "$T/projects"
echo "archived" > "$ROWS/onboard.w2skip.canary_skip"
: > "$T/gh-calls.log"; oc --weekly
[ "$(st w1 state)" = pending ] && [ "$(st w1 mode)" = weekly ] && ok || bad "W1 weekly start: $(cat "$H/state/onboard-canary/w1.json" 2>/dev/null)"
! grep -q 'Test/w2skip' "$T/gh-calls.log" && ! grep -q 'Test/d-j' "$T/gh-calls.log" && ok || bad "W2 skip row and pending must be skipped: $(cat "$T/gh-calls.log")"
grep -q 'weekly-skip w2skip (archived)' "$H/logs/onboard-canary.log" && grep -q 'weekly-skip d-j (pending)' "$H/logs/onboard-canary.log" && ok || bad "W2 skip log lines"
oc --tick
[ "$(st w1 state)" = red ] && [ "$(nalerts w1)" = 1 ] && [ ! -e "$ROWS/onboard.w1.canary_gate" ] && ok || bad "W1 weekly red: alert, no gate row: $(st w1 state) $(nalerts w1) $(ls "$ROWS")"
grep -- "--id onboard-canary:w1:" "$T/alerts.log" | grep -q 'alerted, not paused' && ok || bad "W1 alert text"
P=w3; SR=$(sha_of 7); startfx "$P" "$SR"; runs "$P" "$SR" "[$(cr b completed success)]"
oc --start "$P"; oc --tick
[ "$(st w3 state)" = green ] && [ ! -e "$ROWS/onboard.w3.canary_gate" ] && ok || bad "W1 a weekly green must not write a gate row"

# ══ N1: a new head sha stays pending ════════════════════════════════════════
P=n1; SR=$(sha_of 8); seed "$P" "$SR" 3
fx GET "repos/Test/$P/pulls/1" "{\"state\":\"open\",\"head\":{\"sha\":\"$(sha_of 9)\",\"ref\":\"harness/onboard-canary-x\"}}"
oc --tick
[ "$(st $P state)" = pending ] && [ "$(st $P sha)" = "$(sha_of 9)" ] && ok || bad "N1 new head: $(st $P state) $(st $P sha)"

# ══ X: exit codes ═══════════════════════════════════════════════════════════
rm -f "$H/state/onboard-canary/"*.json; : > "$T/projects"
P=x1; SR=$(sha_of 1); seed "$P" "$SR" 3; runs "$P" "$SR" "[$(cr a completed success)]"
oc --tick; [ "$RC" = 0 ] && [ "$(st $P state)" = green ] && ok || bad "X1 rc 0 want, got $RC"
P=x2; seed "$P" "$SR" 3; fx GET "repos/Test/$P/pulls/1" '{"message":"oops"}' 502
B4=$(cat "$H/state/onboard-canary/$P.json")
oc --tick; [ "$RC" = 75 ] && [ "$(cat "$H/state/onboard-canary/$P.json")" = "$B4" ] && [ "$(nalerts $P)" = 0 ] && ok || bad "X2 a 5xx: rc 75 and state unchanged, got rc=$RC"
rm -f "$H/state/onboard-canary/x2.json"
P=x3; seed "$P" "$SR" 3; runs "$P" "$SR" "[$(cr a completed success)]"; B4=$(cat "$H/state/onboard-canary/$P.json")
OC_ENV=(ONBOARD_CANARY_JOBS_CLIENT="$T/none.sh"); oc --tick; OC_ENV=()
[ "$RC" = 2 ] && [ "$(cat "$H/state/onboard-canary/$P.json")" = "$B4" ] && grep -q 'not-configured' "$H/logs/onboard-canary.log" && ok || bad "X3 no jobs client: rc 2, no change; got $RC"
P=x5; seed "$P" "$SR" 3; runs "$P" "$SR" "[$(cr a completed failure z)]"; rm -f "$H/state/onboard-canary/x3.json"
echo 1 > "$ROWS/.set-rc"; oc --tick; rm -f "$ROWS/.set-rc"
[ "$RC" = 2 ] && [ "$(st $P state)" = pending ] && [ "$(nalerts $P)" = 0 ] && ok || bad "X5 a failed row write: rc 2, pending, no alert; got rc=$RC $(st $P state)"
P=x4; startfx "$P" "$SR"; fx POST "repos/Test/$P/pulls" '{"message":"Validation Failed"}' 422
: > "$T/gh-calls.log"; oc --start "$P"
[ "$RC" = 1 ] && [ ! -f "$H/state/onboard-canary/$P.json" ] && [ "$(grep -c -- "--id onboard-canary:$P:start" "$T/alerts.log")" = 1 ] \
  && grep -q "DELETE repos/Test/$P/git/refs/heads/harness/onboard-canary-202701150800" "$T/gh-calls.log" && ok || bad "X4 refused PR: rc=$RC out=$OUT"

# ══ K1: the timeout knob ════════════════════════════════════════════════════
rm -f "$H/state/onboard-canary/"*.json
P=k1; seed "$P" "$SR" 2; runs "$P" "$SR" "[$(cr slow in_progress null)]"
oc --tick; [ "$(st $P state)" = pending ] && ok || bad "K1 at the default, 2 min is pending"
OC_ENV=(ONBOARD_CANARY_TIMEOUT_MIN=1); oc --tick; OC_ENV=()
[ "$(st $P state)" = red ] && grep -q 'timeout after 1 min' <<<"$(st $P reason)" && ok || bad "K1 the knob must set the timeout: $(st $P state) $(st $P reason)"

# ══ AD1: a pending row with no hub file is adopted ══════════════════════════
P=ad1; SR=$(sha_of 2)
seed "$P" "$SR" 3; rm -f "$H/state/onboard-canary/$P.json"
printf '{"state":"pending","pr":1,"sha":"%s","opened":%s,"at":1,"mode":"hold"}' "$SR" $((NOW - 180)) > "$ROWS/onboard.$P.canary"
echo "$P" > "$T/projects"; runs "$P" "$SR" "[$(cr a completed success)]"
oc --tick
[ "$(st $P state)" = green ] && [ "$(st $P branch)" = harness/onboard-canary-x ] && ok || bad "AD1 adopt: $(cat "$H/state/onboard-canary/$P.json" 2>/dev/null)"

# ══ RO1: a green verdict never drops the release on a read failure ══════════
P=ro1; SR=$(sha_of 3); seed "$P" "$SR" 3; runs "$P" "$SR" "[$(cr a completed success)]"
echo held > "$ROWS/onboard.$P.canary_gate"
echo 1 > "$ROWS/.get-rc.onboard.$P.canary_gate"
oc --tick
[ "$(st $P state)" = green ] && [ "$(cat "$ROWS/onboard.$P.canary_gate")" = held ] && [ "$(st $P release_owed)" = true ] \
  && ok || bad "RO1 an unreadable gate on green must owe the release: state=$(st $P state) owed=$(st $P release_owed) gate=$(cat "$ROWS/onboard.$P.canary_gate")"
oc --tick
[ "$(st $P release_owed)" = true ] && [ "$(cat "$ROWS/onboard.$P.canary_gate")" = held ] && ok || bad "RO1 a second unreadable tick must keep the release owed: owed=$(st $P release_owed)"
rm -f "$ROWS/.get-rc.onboard.$P.canary_gate"
oc --tick
[ "$(cat "$ROWS/onboard.$P.canary_gate")" = released ] && [ "$(st $P release_owed)" = false ] && ok || bad "RO1 a readable tick must release: gate=$(cat "$ROWS/onboard.$P.canary_gate") owed=$(st $P release_owed)"

# ══ HW: a held project is never held silently ═══════════════════════════════
rm -f "$H/state/onboard-canary/"*.json
nheld() { grep -v -- '--resolve' "$T/alerts.log" | grep -c -- "--id onboard-canary:$1:held"; }
printf 'hw1\nhw2\nhw3\nhw4\nhw5\n' > "$T/projects"
for q in hw1 hw2 hw3 hw4 hw5; do echo held > "$ROWS/onboard.$q.canary_gate"; done
echo $((NOW - 25 * 3600)) > "$ROWS/onboard.hw1.canary_held_at"      # past the bound
echo $((NOW - 3600)) > "$ROWS/onboard.hw2.canary_held_at"           # under it
echo $((NOW - 25 * 3600)) > "$ROWS/onboard.hw3.canary_held_at"
echo "no CI, accepted" > "$ROWS/onboard.hw3.canary_override"        # admitted by override
                                                                    # hw4: no held_at row
echo $((NOW - 25 * 3600)) > "$ROWS/onboard.hw5.canary_held_at"
echo 1 > "$ROWS/.get-rc.onboard.hw5.canary_gate"                    # gate unreadable
oc --tick
[ "$(nheld hw1)" = 1 ] && grep -- "--id onboard-canary:hw1:held" "$T/alerts.log" | grep -q 'held for 25 h' && ok || bad "HW1 past the bound: want 1 held alert, got $(nheld hw1): $(grep hw1 "$T/alerts.log")"
[ "$(nheld hw2)" = 0 ] && ok || bad "HW2 under the bound must not alert"
[ "$(nheld hw3)" = 0 ] && ok || bad "HW3 an override must not alert"
[ "$(cat "$ROWS/onboard.hw4.canary_held_at" 2>/dev/null)" = "$NOW" ] && [ "$(nheld hw4)" = 0 ] && ok || bad "HW4 a hold with no held_at must start the clock: '$(cat "$ROWS/onboard.hw4.canary_held_at" 2>/dev/null)'"
[ "$(nheld hw5)" = 0 ] && [ "$(cat "$ROWS/onboard.hw5.canary_gate")" = held ] && grep -q 'unverifiable hw5 gate row' "$H/logs/onboard-canary.log" && ok || bad "HW5 a gate read failure: no alert, no release, one log line"
rm -f "$ROWS/.get-rc.onboard.hw5.canary_gate"
OC_ENV=(ONBOARD_CANARY_HELD_ALERT_HOURS=1); oc --tick; OC_ENV=()
[ "$(nheld hw2)" = 1 ] && ok || bad "HW6 the knob ONBOARD_CANARY_HELD_ALERT_HOURS=1 must set the bound: got $(nheld hw2)"
for q in hw1 hw2 hw3 hw4 hw5; do [ "$(cat "$ROWS/onboard.$q.canary_gate")" = held ] || bad "HW the bound must never release $q"; done
oc --override hw1 "accepted after the held alert"
grep -q -- "--resolve --id onboard-canary:hw1:held" "$T/alerts.log" && ok || bad "HW1 an override must resolve the held alert"
: > "$T/projects"

[ ! -s "$T/unknown.log" ] && ok || bad "every gh call must hit a fixture: $(sort -u "$T/unknown.log" | head -5)"

# ══ E1: the onboarding runner's ready station ═══════════════════════════════
E="$T/e1"; mkdir -p "$E/bin"
ready() { ( ONBOARD_RUN_LIB_ONLY=1 HARNESS="$E" . "$DIR/bin/onboard-run.sh"; ROOT="$E"; PROJECT=e1-proj; _obr_station ready ) 2>&1; }
printf '#!/bin/bash\necho "canary: held, PR https://github.com/Test/e1/pull/3, tickets wait for green"\n' > "$E/bin/onboard-canary.sh"; chmod +x "$E/bin/onboard-canary.sh"
O=$(ready); R=$?
[ "$R" = 0 ] && grep -qx 'ready: every earlier station is done' <<<"$O" && grep -qx 'canary: held, PR https://github.com/Test/e1/pull/3, tickets wait for green' <<<"$O" && ok || bad "E1 ready: rc=$R $O"
printf '#!/bin/bash\necho "$*" > %s/e1.args\nexit 1\n' "$T" > "$E/bin/onboard-canary.sh"
O=$(ready); R=$?
[ "$R" = 0 ] && grep -q 'canary: OWED' <<<"$O" && [ "$(cat "$T/e1.args")" = "--hold e1-proj" ] && ok || bad "E1 a failing canary must keep ready rc 0: rc=$R $O"
rm -f "$E/bin/onboard-canary.sh"
O=$(ready); R=$?
[ "$R" = 0 ] && grep -q 'canary: OWED' <<<"$O" && ok || bad "E1 an absent canary must keep ready rc 0: rc=$R $O"

# ══ E2: the load-project.sh block ═══════════════════════════════════════════
LP="$DIR/bin/load-project.sh"
[ "$(grep -c '^# >>> onboarding canary' "$LP")" = 1 ] && [ "$(grep -c '^# <<< onboarding canary' "$LP")" = 1 ] && ok || bad "E2 markers"
lb=$(grep -n '^# >>> onboarding canary' "$LP" | cut -d: -f1); qa=$(grep -n '^# <<< browser QA' "$LP" | cut -d: -f1)
[ "${lb:-0}" -gt "${qa:-999999}" ] && ok || bad "E2 the block must sit after browser QA ($lb vs $qa)"
sed -n '/^# >>> onboarding canary/,/^# <<< onboarding canary/p' "$LP" > "$T/lp-block.sh"
L="$T/lp"; mkdir -p "$L/bin"
printf '#!/bin/bash\ncase "$1" in --hold) echo "canary: OWED: boom"; exit 1 ;; --status) echo "$2 held red abc - -"; exit 0 ;; esac\n' > "$L/bin/onboard-canary.sh"
chmod +x "$L/bin/onboard-canary.sh"
O=$(cd "$L" && PROJECT=e2-proj bash "$T/lp-block.sh" 2>&1); R=$?
[ "$R" = 0 ] && grep -qx '== onboarding canary ==' <<<"$O" && grep -q '^OWED: the onboarding canary did not start for e2-proj' <<<"$O" \
  && grep -qx 'e2-proj held red abc - -' <<<"$O" && ok || bad "E2 block: rc=$R $O"

# ══ RV1: the review lane never reads a canary PR ════════════════════════════
# The PR list line of bin/review-prs.sh, run as written over a fixture list: the
# canary head is dropped, a ticket PR and a hand PR stay.
RPL=$(grep -n '^PRS=$(jq -r ' "$DIR/bin/review-prs.sh")
[ "$(grep -c '^PRS=$(jq -r ' "$DIR/bin/review-prs.sh")" = 1 ] && ok || bad "RV1 want one PRS= list line in review-prs.sh"
cat > "$T/rp-list.json" <<'JSON'
[{"number":1,"draft":false,"head":{"ref":"ticket/bh-1","sha":"a"},"user":{"login":"bot"},"title":"t1"},
 {"number":2,"draft":false,"head":{"ref":"harness/onboard-canary-202701150800","sha":"b"},"user":{"login":"bot"},"title":"[harness] onboarding canary, do not merge"},
 {"number":3,"draft":false,"head":{"ref":"feature/x","sha":"c"},"user":{"login":"human"},"title":"t3"}]
JSON
O=$(RP_LISTF="$T/rp-list.json"; eval "${RPL#*:}"; printf '%s' "$PRS" | cut -f1 | tr '\n' ' ')
[ "$O" = "1 3 " ] && ok || bad "RV1 review-prs must drop the canary PR: got '$O'"

# M1: every caller runs the file directly; the copies above get chmod +x, so
# this is the only case that sees the shipped mode.
[ -x "$DIR/bin/onboard-canary.sh" ] && ok || bad "M1 bin/onboard-canary.sh is not executable"
if git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
  M1MODE=$(git -C "$DIR" ls-files -s bin/onboard-canary.sh | cut -d' ' -f1)
  [ "$M1MODE" = 100755 ] && ok || bad "M1 git mode of bin/onboard-canary.sh is '$M1MODE', want 100755"
fi

echo "onboard-canary (BH-9442): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
