#!/bin/bash
# tests/merge-conductor-e2e-red-hold.bh-9071-test.sh — BH-9071: the merge
# conductor does not add `merge-queue` to a READY Mergify PR while an
# end-to-end check on its head commit is red, and waits while one runs.
#
# The hold is bin/merge-conductor.d/bh-9071-e2e-red-hold.sh, called once in
# pr_worker's READY arm right after the production-red hold.
#
# Part A (unit) sources the fragment with its seams stubbed:
#   U1  red shard                         -> held, e2e-red, one line, one comment, marks
#   U2  no knob row and no env            -> on
#   U3  red on page 2; PLAYWRIGHT; project regex `^Smoke QA$`
#   U4  queued / in_progress              -> held, e2e-running, no comment
#   U5  near-miss names (Unit, smoke, deploy) red -> go on
#   U6  red superseded by a newer green re-run -> go on
#   U7  cancelled/skipped/neutral/timed_out, 0 runs -> go on
#   U8  fix-main-red -> go on, no read; fix-main-red-later / Fix-Main-Red -> gated
#   U9  provider github, QUEUE=0, PREV=QUEUED, MC_E2E_RED_HOLD=0 -> go on, no read
#   U10 mc_e2e_check_re row overrides; empty row -> fallback; bad regex -> fallback + one line/hour
#   U11 comment POST fails -> no e2eredcmt mark; the next call posts once
#   U12 the marks round-trip through the real bin/lib/mc/locks.sh
#   U13 read failure / bad JSON / short pages -> e2e-unread, held, no comment
#   U14 observe mode -> one WOULD line, 0 POSTs
# Part B (whole tick) drives the WHOLE bin/merge-conductor.sh in a scratch tree
# (the fixture of tests/merge-conductor-prod-red-hold.bh-8781-test.sh part B,
# copied, plus a per-head check-runs route):
#   M1  red shard: no label, one HELD line, one comment naming the shard
#   M2  a second tick on the same head: no new comment, no new HELD line
#   M3  running: no label, no comment; then green: the label goes on
#   M4  red on head A, then head B green: labelled; head B red: one new comment
#   M5  fix-main-red with a red shard: labelled, no check-runs read
#   M6  no end-to-end check at all: labelled
#   M7  two READY PRs, one red, one green: one held, one labelled, one comment
#   RED the M1 tick with the fragment absent: labelled (the fragment holds)
#   B0  every request went to a .test host; no workflow dispatch or rerun
# Run: HARNESS_TEST_SANDBOX=1 bash tests/merge-conductor-e2e-red-hold.bh-9071-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: merge-conductor-e2e-red-hold: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
FRAG="$DIR/bin/merge-conductor.d/bh-9071-e2e-red-hold.sh"
for SRC in "$FRAG" "$DIR/bin/merge-conductor.sh" "$DIR/bin/lib/e2e-paths.sh" "$DIR/bin/lib/mc/locks.sh"; do
  [ -r "$SRC" ] && ok || bad "missing $SRC"
done
grep -q 'command -v mc_e2e_red_hold >/dev/null 2>&1 && mc_e2e_red_hold; then return 0; fi' "$DIR/bin/merge-conductor.sh" \
  && ok || bad "the driver has no mc_e2e_red_hold call site"

SLUG=example-org/mgfy-os
H1=$(printf 'a%.0s' $(seq 40))
H2=$(printf 'b%.0s' $(seq 40))
H3=$(printf 'c%.0s' $(seq 40))
NOWP=2000000000                       # 2033-05-18 03:33:20Z, the pinned clock
# runs <spec>... — a check-runs page. Each spec is name|status|conclusion|started_at.
runs() {
  printf '%s\n' "$@" | jq -R -s -c '[split("\n")[] | select(length > 0) | split("|")] | to_entries
    | map(.key as $k | .value as $v | {id: (7000 + $k), name: $v[0], status: $v[1],
        conclusion: (($v[2] // "") | if . == "" then null else . end),
        started_at: (($v[3] // "") | if . == "" then "2033-05-18T03:00:00Z" else . end),
        html_url: "https://ci.example.test/run/\(7000 + $k)"})
    | {total_count: length, check_runs: .}'
}

# ============================================================================
# Part A — the fragment, sourced, seams stubbed. Own subshell; exits its fail count.
# ============================================================================
(
  A="$T/a"; FXD="$A/fx"; mkdir -p "$A/h"
  H="$A/h"; HARNESS="$H"
  # The fragment's closure carries bin/lib/e2e-paths.sh, the regex fallback.
  ( cd "$DIR" && scratch_install_closure bin/merge-conductor.d/bh-9071-e2e-red-hold.sh "$H" >/dev/null ) || exit 91
  [ -r "$H/bin/lib/e2e-paths.sh" ] || exit 92
  export MC_E2E_NOW="$NOWP"
  unset MC_E2E_RED_HOLD MC_E2E_CHECK_RE E2E_CHECK_RE MC_MAIN_RED_LABEL
  lane_knob() { [ -f "$FXD/knob.$2.${3:-}" ] && { cat "$FXD/knob.$2.${3:-}"; return 0; }; [ -f "$FXD/knob.$2" ] && cat "$FXD/knob.$2"; return 0; }
  mc_log() { printf '%s\n' "$*" >> "$FXD/log"; }
  mc_attempt_has() { grep -qxF "$1" "$FXD/attempts" 2>/dev/null; }
  mc_attempt_put() { echo "$1" >> "$FXD/attempts"; }
  mc_ready_why() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-}" >> "$FXD/why"; }
  # gh_rest GET <path>: the page named by &page=N from $FXD/cr.N.
  gh_rest() {
    printf '%s %s\n' "$1" "$2" >> "$FXD/reads"
    if [ -e "$FXD/readfail" ]; then GH_REST_STATUS=502; return 75; fi
    local pg="${2##*page=}"; GH_REST_STATUS=200
    if [ -f "$FXD/cr.$pg" ]; then cat "$FXD/cr.$pg"; else echo '{"total_count":0,"check_runs":[]}'; fi
  }
  mc_issue_comment() {
    printf '%s %s\n' "$1" "$2" >> "$FXD/posts"
    printf '%s\n---\n' "$3" >> "$FXD/bodies"
    local rc=0; [ -f "$FXD/post-rc" ] && rc=$(cat "$FXD/post-rc")
    return "$rc"
  }
  # shellcheck source=bin/merge-conductor.d/bh-9071-e2e-red-hold.sh
  . "$FRAG" || exit 90
  F=0; no() { F=$((F+1)); echo "FAIL: merge-conductor-e2e-red-hold: $1"; }
  n() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }
  reset() { scratch_rm "$FXD"; mkdir -p "$FXD"; unset E2E_CHECK_RE; }
  page() { local p="$1"; shift; runs "$@" > "$FXD/cr.$p"; }
  # run [labels] — one hold call on a READY Mergify row, PR #31 at H1.
  run() {
    P="${P_OVR:-mgfy}"; KEY="$SLUG#31"; HEAD="${HEAD_OVR:-$H1}"; NUM=31; URL="https://github.com/$SLUG/pull/31"
    RAWLBL="${1:-}"; QUEUE="${Q_OVR:-1}"; PROVIDER="${PROV_OVR:-mergify}"; PREV="${PREV_OVR:-READY}"
    ACTIONS="${ACT_OVR:-1}"; KILL="${KILL_OVR:-0}"; MERGES="${MRG_OVR:-1}"
    mc_e2e_red_hold
  }
  GREEN=("Unit|completed|success" "Typecheck|completed|success")

  # U1 — a red shard holds, logs once, comments once.
  reset; page 1 "${GREEN[@]}" "E2E (1/4)|completed|success" "E2E (2/4)|completed|failure" "E2E (3/4)|completed|success"
  run; RC=$?
  [ "$RC" = 0 ] || no "U1 a red shard holds (rc $RC)"
  grep -q "^GET repos/$SLUG/commits/$H1/check-runs?filter=latest&per_page=100&page=1$" "$FXD/reads" 2>/dev/null \
    || no "U1 the read is the head's check-runs page 1 (reads: $(cat "$FXD/reads" 2>/dev/null))"
  [ "$(cut -f3,5 "$FXD/why" 2>/dev/null)" = $'e2e-red\tlogged' ] || no "U1 ready-why e2e-red, logged (got '$(cat "$FXD/why" 2>/dev/null)')"
  grep -qxF "$SLUG#31 READY and HELD: end-to-end check(s) E2E (2/4) failed on aaaaaaaa — not queued; a new commit clears it" "$FXD/log" 2>/dev/null \
    || no "U1 the HELD log line (log: $(cat "$FXD/log" 2>/dev/null))"
  [ "$(n "$FXD/posts")" = 1 ] && grep -qxF "$SLUG 31" "$FXD/posts" || no "U1 one comment on the PR (posts $(n "$FXD/posts"))"
  grep -qF 'E2E (2/4) (https://ci.example.test/run/7003)' "$FXD/bodies" 2>/dev/null && grep -qF '`aaaaaaaa`' "$FXD/bodies" \
    && grep -qF "<!-- bh-e2e-red:$H1 -->" "$FXD/bodies" && ! grep -qF 'E2E (1/4)' "$FXD/bodies" \
    || no "U1 the comment names the failed shard, its URL, the head and the marker, and not a green shard (body: $(cat "$FXD/bodies" 2>/dev/null))"
  grep -qxF "e2eredhold $SLUG#31 $H1" "$FXD/attempts" && grep -qxF "e2eredcmt $SLUG#31 $H1" "$FXD/attempts" \
    || no "U1 the e2eredhold and e2eredcmt marks (attempts: $(cat "$FXD/attempts" 2>/dev/null))"
  run; RC=$?
  [ "$RC" = 0 ] && [ "$(n "$FXD/posts")" = 1 ] && [ "$(grep -c 'READY and HELD' "$FXD/log")" = 1 ] \
    || no "U1 a second call: held, no second comment, no second line (posts $(n "$FXD/posts"), log $(n "$FXD/log"))"

  # U2 — on with no row and no env; a 0 row for another project changes nothing.
  reset; page 1 "E2E Tests|completed|failure"; echo 0 > "$FXD/knob.MC_E2E_RED_HOLD.other"
  run; [ "$?" = 0 ] || no "U2 default on: held"

  # U3 — (c) red on page 2 of 130; (d) PLAYWRIGHT; (e) a project regex.
  reset
  P1=(); for i in $(seq 1 100); do P1+=("Unit $i|completed|success"); done
  runs "${P1[@]}" | jq -c '.total_count = 130' > "$FXD/cr.1"
  P2=(); for i in $(seq 1 29); do P2+=("Lint $i|completed|success"); done
  runs "${P2[@]}" "E2E (4/4)|completed|failure" | jq -c '.total_count = 130' > "$FXD/cr.2"
  run; RC=$?
  [ "$RC" = 0 ] && [ "$(n "$FXD/reads")" = 2 ] && grep -q 'E2E (4/4)' "$FXD/log" || no "U3c a red run on page 2 holds (rc $RC, reads $(n "$FXD/reads"))"
  reset; page 1 "${GREEN[@]}" "PLAYWRIGHT|completed|failure"
  run; [ "$?" = 0 ] && grep -q 'PLAYWRIGHT failed' "$FXD/log" || no "U3d PLAYWRIGHT failure holds (case-insensitive)"
  reset; page 1 "${GREEN[@]}" "Smoke QA|completed|failure"; echo '^Smoke QA$' > "$FXD/knob.MC_E2E_CHECK_RE.mgfy"
  run; [ "$?" = 0 ] || no "U3e a project regex ^Smoke QA\$ holds on Smoke QA failure"

  # U4 — running: held, e2e-running, no comment, no hold mark.
  for spec in "E2E Tests|queued|" "e2e-prod|in_progress|"; do
    reset; page 1 "${GREEN[@]}" "$spec" "E2E (1/4)|completed|success"
    run; RC=$?
    [ "$RC" = 0 ] && [ "$(cut -f3 "$FXD/why" 2>/dev/null)" = e2e-running ] && [ "$(n "$FXD/posts")" = 0 ] \
      && ! grep -q '^e2eredhold' "$FXD/attempts" 2>/dev/null && grep -qF "waiting for end-to-end check(s) ${spec%%|*} on aaaaaaaa" "$FXD/why" \
      || no "U4 ${spec%%|*} running: held, e2e-running, no comment (rc $RC, why '$(cat "$FXD/why" 2>/dev/null)', posts $(n "$FXD/posts"))"
  done
  # (b) one red and one running: red wins.
  reset; page 1 "E2E (1/4)|completed|failure" "E2E (2/4)|in_progress|"
  run; [ "$?" = 0 ] && [ "$(cut -f3 "$FXD/why")" = e2e-red ] && [ "$(n "$FXD/posts")" = 1 ] || no "U4b red and running: red wins"

  # U5 — near-miss names are not this gate's business.
  reset; page 1 "Unit|completed|failure" "Typecheck|completed|failure" "Coverage|completed|failure" "Drift|completed|failure" \
    "Mergify Merge Protections|completed|failure" "Bridge npm smoke test|completed|failure" "Deploy Worker to Railway|completed|failure"
  run; RC=$?
  [ "$RC" = 1 ] && [ "$(n "$FXD/log")" = 0 ] && [ "$(n "$FXD/why")" = 0 ] && [ "$(n "$FXD/posts")" = 0 ] || no "U5 near-miss names: go on, silent (rc $RC)"

  # U6 — a red run superseded by a newer green re-run.
  reset; page 1 "E2E Tests|completed|failure|2033-05-18T01:00:00Z" "E2E Tests|completed|success|2033-05-18T02:00:00Z"
  run; [ "$?" = 1 ] && [ "$(n "$FXD/posts")" = 0 ] || no "U6 a newer green re-run supersedes the red one"
  reset; page 1 "E2E Tests|completed|success|2033-05-18T01:00:00Z" "E2E Tests|completed|failure|2033-05-18T02:00:00Z"
  run; [ "$?" = 0 ] || no "U6b a newer red re-run holds"

  # U7 — only `failure` is red; 0 runs is none.
  for c in cancelled skipped neutral timed_out; do
    reset; page 1 "${GREEN[@]}" "E2E Tests|completed|$c"
    run; [ "$?" = 1 ] && [ "$(n "$FXD/posts")" = 0 ] || no "U7 conclusion $c: go on"
  done
  reset; page 1
  run; [ "$?" = 1 ] && [ "$(n "$FXD/reads")" = 1 ] || no "U7 0 runs: go on after one read"

  # U8 — fix-main-red passes with no read; near-miss labels are gated.
  reset; page 1 "E2E Tests|completed|failure"
  run "foo,fix-main-red"; RC=$?; run "foo,fix-main-red"
  [ "$RC" = 1 ] && [ "$(n "$FXD/reads")" = 0 ] && [ "$(n "$FXD/log")" = 1 ] && grep -qxF "e2eredpass $SLUG#31 $H1" "$FXD/attempts" \
    || no "U8 fix-main-red: go on, no read, one pass line (rc $RC, reads $(n "$FXD/reads"), log $(n "$FXD/log"))"
  for l in fix-main-red-later Fix-Main-Red; do
    reset; page 1 "E2E Tests|completed|failure"
    run "$l"; [ "$?" = 0 ] && [ "$(n "$FXD/reads")" = 1 ] || no "U8 label $l is gated"
  done

  # U9 — out of scope: go on with no read.
  for o in PROV_OVR=github PROV_OVR=none Q_OVR=0 PREV_OVR=QUEUED; do
    reset; page 1 "E2E Tests|completed|failure"
    ( export "${o?}"; run ); RC=$?
    [ "$RC" = 1 ] && [ "$(n "$FXD/reads")" = 0 ] || no "U9 $o: go on, no read (rc $RC, reads $(n "$FXD/reads"))"
  done
  reset; page 1 "E2E Tests|completed|failure"; echo 0 > "$FXD/knob.MC_E2E_RED_HOLD.mgfy"
  run; [ "$?" = 1 ] && [ "$(n "$FXD/reads")" = 0 ] || no "U9 MC_E2E_RED_HOLD=0 row: go on, no read"
  reset; page 1 "E2E Tests|completed|failure"
  ( MC_E2E_RED_HOLD=0; run ); [ "$?" = 1 ] && [ "$(n "$FXD/reads")" = 0 ] || no "U9 env MC_E2E_RED_HOLD=0: go on, no read"

  # U10 — the regex knob.
  reset; echo '^Playwright' > "$FXD/knob.MC_E2E_CHECK_RE.mgfy"
  [ "$(mc_e2e_check_re)" = '^Playwright' ] || no "U10 the project row is the regex"
  page 1 "E2E Tests|completed|failure"; run; [ "$?" = 1 ] || no "U10 with ^Playwright, E2E Tests is not E2E-class"
  page 1 "Playwright 1/4|completed|failure"; run; [ "$?" = 0 ] || no "U10 with ^Playwright, Playwright 1/4 is E2E-class"
  reset; : > "$FXD/knob.MC_E2E_CHECK_RE.mgfy"
  # shellcheck source=bin/lib/e2e-paths.sh
  [ "$(mc_e2e_check_re)" = "$(. "$DIR/bin/lib/e2e-paths.sh"; printf '%s' "$E2E_CHECK_RE")" ] || no "U10 an empty row reads the fallback E2E_CHECK_RE ($(mc_e2e_check_re))"
  reset; echo 'e2e(' > "$FXD/knob.MC_E2E_CHECK_RE"
  page 1 "E2E Tests|completed|failure"
  run; RC=$?; run
  [ "$RC" = 0 ] && [ "$(grep -c 'does not compile' "$FXD/log")" = 1 ] && grep -qxF "e2erebad mgfy 2033051803" "$FXD/attempts" \
    || no "U10 a bad regex: the fallback holds, one line for two calls (rc $RC, log: $(cat "$FXD/log"))"
  MC_E2E_NOW=$((NOWP + 3600)) run; [ "$(grep -c 'does not compile' "$FXD/log")" = 2 ] || no "U10 the next hour writes one more line"

  # U11 — a failed POST writes no mark; the next call posts once.
  reset; page 1 "E2E Tests|completed|failure"; echo 75 > "$FXD/post-rc"
  run; RC=$?
  [ "$RC" = 0 ] && [ "$(n "$FXD/posts")" = 1 ] && ! grep -q '^e2eredcmt' "$FXD/attempts" && grep -q 'e2e-red comment NOT posted' "$FXD/log" \
    || no "U11 a failed POST: held, no e2eredcmt mark, one failure line (log: $(cat "$FXD/log"))"
  rm -f "$FXD/post-rc"; run; run
  [ "$(n "$FXD/posts")" = 2 ] && grep -qxF "e2eredcmt $SLUG#31 $H1" "$FXD/attempts" && grep -q 'posted e2e-red comment' "$FXD/log" \
    || no "U11 the next call posts once and marks (posts $(n "$FXD/posts"))"

  # U13 — unread: held, e2e-unread, no comment.
  reset; : > "$FXD/readfail"
  run; RC=$?
  [ "$RC" = 0 ] && [ "$(cut -f3 "$FXD/why")" = e2e-unread ] && [ "$(n "$FXD/posts")" = 0 ] && grep -q 'HTTP 502' "$FXD/why" || no "U13 a failed read: e2e-unread (why '$(cat "$FXD/why" 2>/dev/null)')"
  reset; echo '{not json' > "$FXD/cr.1"
  run; [ "$?" = 0 ] && [ "$(cut -f3 "$FXD/why")" = e2e-unread ] || no "U13 junk JSON: e2e-unread"
  reset; runs "E2E Tests|completed|success" | jq -c '.total_count = 3' > "$FXD/cr.1"
  run; [ "$?" = 0 ] && [ "$(cut -f3 "$FXD/why")" = e2e-unread ] && [ "$(n "$FXD/reads")" = 2 ] || no "U13 short pages (1 of 3): e2e-unread (reads $(n "$FXD/reads"))"
  reset; P1=(); for i in $(seq 1 100); do P1+=("Unit $i|completed|success"); done
  runs "${P1[@]}" | jq -c '.total_count = 250' > "$FXD/cr.1"; cp "$FXD/cr.1" "$FXD/cr.2"
  ( MC_REST_PAGES_MAX=2; run ); [ "$?" = 0 ] && [ "$(cut -f3 "$FXD/why")" = e2e-unread ] && [ "$(n "$FXD/reads")" = 2 ] \
    || no "U13 more pages than MC_REST_PAGES_MAX: e2e-unread after 2 reads (reads $(n "$FXD/reads"))"

  # U14 — observe and kill mode: one WOULD line per head, no POST.
  for o in ACT_OVR=0 KILL_OVR=1 MRG_OVR=0; do
    reset; page 1 "E2E Tests|completed|failure"
    ( export "${o?}"; run; run ); RC=$?
    [ "$RC" = 0 ] && [ "$(n "$FXD/posts")" = 0 ] && [ "$(grep -c "^E2E_RED_COMMENT WOULD $SLUG#31 aaaaaaaa" "$FXD/log")" = 1 ] \
      && ! grep -q '^e2eredcmt' "$FXD/attempts" || no "U14 $o: held, one WOULD line, no POST (log: $(cat "$FXD/log"))"
  done

  echo "part A: $F failed"
  exit "$F"
)
PA=$?; FAIL=$((FAIL + PA))

# U12 — the marks round-trip through the real attempts ledger.
(
  A="$T/u12"; mkdir -p "$A"
  set +u   # the conductor libs run without nounset
  MC_H="$A"; MC_ATTEMPTS="$A/attempts"; MC_STATE_DIR="$A"; export MC_H MC_ATTEMPTS MC_STATE_DIR
  # shellcheck source=bin/lib/mc/locks.sh
  . "$DIR/bin/lib/mc/locks.sh" 2>/dev/null || exit 1
  command -v mc_attempt_put >/dev/null && command -v mc_attempt_has >/dev/null || exit 2
  : > "$MC_ATTEMPTS"
  for m in "e2eredhold $SLUG#31 $H1" "e2eredcmt $SLUG#31 $H1" "e2eredpass $SLUG#31 $H1" "e2eredwould $SLUG#31 $H1" "e2erebad mgfy 2033051803"; do
    mc_attempt_has "$m" && exit 3
    mc_attempt_put "$m"; mc_attempt_has "$m" || exit 4
  done
  mc_attempt_has "e2eredcmt $SLUG#31 $H2" && exit 5
  exit 0
)
RC=$?; [ "$RC" = 0 ] && ok || bad "U12 the attempts round-trip through bin/lib/mc/locks.sh (rc $RC)"

# ============================================================================
# Part B — the WHOLE bin/merge-conductor.sh in a scratch tree.
# ============================================================================
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
# shellcheck source=tests/lib/gh-list-bridge.sh
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/verdict-fixture.sh
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
C="$T/w"; CH="$C/h"; FX="$C/fx"
fx_mc_harness "$DIR" "$C" || exit 1
fx_conductor_tick "$DIR" "$C" || exit 1
( cd "$DIR" && for s in bin/lib/autoenqueue.sh bin/lib/mc-hold-comment.sh bin/lib/gh-repo-token.sh; do scratch_install_closure "$s" "$CH" >/dev/null || exit 1; done ) || exit 1
mkdir -p "$C/fakebin" "$FX"
# The conductor's curl: every call logged; the worker and settings reads 404.
cat > "$C/fakebin/curl" <<EOF
#!/bin/bash
URL=""; out=""; w=""; M=GET
while [ \$# -gt 0 ]; do case "\$1" in
  -o) out="\$2"; shift 2 ;; -w) w="\$2"; shift 2 ;; -X) M="\$2"; shift 2 ;;
  -m|-H|--connect-timeout|--data-binary|-d|--max-time) shift 2 ;;
  -*) shift ;; *) URL="\$1"; shift ;;
esac; done
printf '%s %s\n' "\$M" "\$URL" >> "$C/curl-all.log"
body='{"error":"not found"}'; code=404
case "\$M \$URL" in "PUT "*|"POST "*) body='{"ok":true}'; code=200 ;; esac
if [ -n "\$out" ]; then printf '%s' "\$body" > "\$out"; else printf '%s' "\$body"; fi
case "\$w" in '') ;; \$'\n'*) printf '\n%s' "\$code" ;; *) printf '%s' "\$code" ;; esac
exit 0
EOF
chmod +x "$C/fakebin/curl"
cat > "$CH/bin/lib/ticket-ownership.sh" <<'EOF2'
to_lane_hold() { return 1; }
to_lane_lead_fence() { TO_LEAD_CLEARED=0; return 1; }
EOF2
printf 'pdg_hold() { return 1; }\n' > "$CH/bin/lib/pr-dep-gate.sh"
install_frag() { ( cd "$DIR" && scratch_install_closure bin/merge-conductor.d/bh-9071-e2e-red-hold.sh "$CH" >/dev/null ); }
install_frag || bad "setup: cannot install the fragment"
printf 'mgfy %s - - 2 box-m\n' "$SLUG" > "$CH/fleet.conf"
: > "$CH/env/global.env"
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$CH/bin/$s.sh"; chmod +x "$CH/bin/$s.sh"; done
U="https://github.com/$SLUG/pull"
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
# The fake gh. Per PR <n>: $FX/head.<n> is its head, $FX/lbl.<n> its labels csv.
# Per head <sha>: $FX/cr.<sha> is its check-runs page (none = the one Build +
# Unit tests success run the other conductor suites serve). Every call is logged.
cat > "$C/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$FX/gh-all.log"
num=""; [[ "\$*" =~ repos/$SLUG/(pulls|issues)/([0-9]+) ]] && num="\${BASH_REMATCH[2]}"
HD=""; [ -n "\$num" ] && HD=\$(cat "$FX/head.\$num" 2>/dev/null)
LB=""; [ -n "\$num" ] && LB=\$(cat "$FX/lbl.\$num" 2>/dev/null)
case "\$*" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"actions/runs?head_sha="*) restpr --raw 200 '{"workflow_runs":[{"id":1,"name":"CI","status":"completed","conclusion":"success","run_started_at":"2026-09-29T10:00:00Z"}]}' ;;
  *"check-runs?check_name="*) restpr --raw 200 '{"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-09-23T10:00:00Z"}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*)
    [[ "\$*" =~ /commits/([0-9a-f]+)/check-runs ]] && sha="\${BASH_REMATCH[1]}"
    if [ -f "$FX/cr.\$sha" ]; then restpr --raw 200 "\$(cat "$FX/cr.\$sha")"
    else restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-09-23T10:00:00Z"}]}'; fi ;;
  *"/comments -f body=@mergifyio queue"*) printf '%s\n' "\$num" >> "$FX/queue-posts.txt"; restpr --raw 201 '{"id":901}' ;;
  *"api -X POST repos/$SLUG/issues/"*"/labels"*|*"api -i -X POST repos/$SLUG/issues/"*"/labels"*) printf '%s %s\n' "\$num" "\$*" >> "$FX/label-posts.txt"; restpr --raw 200 '[]' ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$FX/merges.txt"; exit 0 ;;
  *"/pulls/"*"/merge"|*"/pulls/"*"/merge "*) printf '%s\n' "\$*" >> "$FX/merges.txt"; restpr --raw 200 '{"merged":true}' ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*)
    printf '%s\n' "\$num" >> "$FX/comment-posts.txt"
    for a in "\$@"; do case "\$a" in body=@*) { cat "\${a#body=@}"; printf '\n---\n'; } >> "$FX/comment-bodies.txt" ;; esac; done
    restpr --raw 201 '{"id":1}' ;;
  *"api -i -X GET repos/$SLUG/issues/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[{"filename":"src/a.ts","status":"modified"}]' ;;
  *"api -i -X GET repos/$SLUG/pulls/"[0-9]*) restpr OPEN "\$HD" "ticket/mg-\$num" main "\$LB" MERGEABLE CLEAN operator "" "" ;;
  *"api -i -X GET repos/"*"/pulls -f state="*) restpr --raw 200 '[]' ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
  *"pr list -R $SLUG --state open"*) cat "$C/list.json" ;;
  *"pr list"*"--state closed"*) : ;;
esac
exit 0
EOF
chmod +x "$C/fakebin/gh"
printf '#!/bin/bash\nexit 0\n' > "$C/fakebin/flock"; chmod +x "$C/fakebin/flock"
touch "$CH/flags/merge-conductor-actions" "$CH/flags/merge-conductor-merge"
# pr <num> <head> [labels-csv] — one open READY-able PR with its approved build record.
pr() {
  local num="$1" head="$2" lb="${3:-}" rec="$CH/builds/pool-mgfy-MG-$1-203305180001"
  echo "$head" > "$FX/head.$num"; printf '%s' "$lb" > "$FX/lbl.$num"
  mkdir -p "$rec"; echo "PR_CREATED $U/$num" > "$rec/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$rec/review.md"
  echo "$head" > "$rec/reviewed-sha"; : > "$rec/pipeline.log"
  echo "$num" >> "$FX/prs"
  relist
}
relist() {
  local num out='[]' head lb
  for num in $(sort -un "$FX/prs"); do
    head=$(cat "$FX/head.$num"); lb=$(cat "$FX/lbl.$num")
    out=$(jq -c --arg u "$U/$num" --arg h "$head" --argjson n "$num" --arg l "$lb" \
      '. + [{number:$n,url:$u,headRefOid:$h,headRefName:"ticket/mg-\($n)",baseRefName:"main",isDraft:false,mergeStateStatus:"CLEAN",mergeable:"MERGEABLE",state:"OPEN",isInMergeQueue:false,
             labels:($l | split(",") | map(select(length > 0)) | map({name:.}))}]' <<<"$out")
  done
  printf '%s\n' "$out" > "$C/list.json"
}
# cr <sha> <spec>... — the check-runs page of a head.
cr() { local s="$1"; shift; runs "$@" > "$FX/cr.$s"; }
# fresh — a clean slate: state, logs, fixture answers and the build records.
fresh() {
  scratch_rm "$CH/state"; scratch_rm "$FX"; scratch_rm "$CH/builds"; mkdir -p "$CH/state" "$FX" "$CH/builds"
  : > "$CH/logs/merge-conductor.log"; : > "$CH/logs/ALERTS.log"; : > "$FX/prs"; echo '[]' > "$C/list.json"
}
tick() {
  ( cd "$C" && env PATH="$C/fakebin:$PATH" HARNESS="$CH" HARNESS_ENV_DIR= HARNESS_SECRET=fixture-secret JOBS_URL=http://worker.test JOBS_RETRIES=0 GH_TOKEN=pat-fixture \
    MC_MERGE_BUDGET=5 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MAIN_RED_DETECT=0 \
    MC_E2E_NOW="$NOWP" "$@" bash "$CH/bin/merge-conductor.sh" >/dev/null 2>"$C/tick.err" ) || { echo "tick rc=$? stderr:"; tail -5 "$C/tick.err"; }
}
n() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }
labelled() { if [ -f "$FX/label-posts.txt" ]; then grep -c "^${1:-31} " "$FX/label-posts.txt"; else echo 0; fi; }
cposts() { if [ -f "$FX/comment-posts.txt" ]; then grep -cx "${1:-31}" "$FX/comment-posts.txt"; else echo 0; fi; }
held() { grep -c "#${1:-31} READY and HELD: end-to-end" "$CH/logs/merge-conductor.log"; }
crreads() { grep -c "commits/${1:-$H1}/check-runs?filter=latest" "$FX/gh-all.log" 2>/dev/null || true; }
clog() { grep -E "#${1:-31}" "$CH/logs/merge-conductor.log" | tail -"${2:-6}"; }
RED_SHARDS=("Build + Unit tests|completed|success" "E2E (1/4)|completed|success" "E2E (2/4)|completed|failure")

# M1 — red shard on the head: held, one line, one comment naming the shard.
fresh; pr 31 "$H1"; cr "$H1" "${RED_SHARDS[@]}"; tick
[ "$(labelled)" = 0 ] && [ "$(n "$FX/queue-posts.txt")" = 0 ] && [ "$(n "$FX/merges.txt")" = 0 ] && ok \
  || bad "M1 a red shard: no label, no queue command, no merge (labels $(labelled); log: $(clog))"
[ "$(held)" = 1 ] && ok || bad "M1 one HELD line (got $(held); log: $(clog))"
[ "$(cposts)" = 1 ] && grep -qF 'E2E (2/4) (https://ci.example.test/run/7002)' "$FX/comment-bodies.txt" 2>/dev/null && ok \
  || bad "M1 exactly one comment POST naming the shard (posts $(cposts); body $(cat "$FX/comment-bodies.txt" 2>/dev/null))"
[ "$(crreads)" -ge 1 ] && ok || bad "M1 the head's check runs were read"
[ "$(cut -f3 "$CH/state/merge-conductor/ready-why/"*31 2>/dev/null)" = e2e-red ] && ok || bad "M1 the ready-why kind is e2e-red"

# M2 — a second tick on the same head: no new comment, no new line.
tick
[ "$(labelled)" = 0 ] && [ "$(cposts)" = 1 ] && [ "$(held)" = 1 ] && ok \
  || bad "M2 a second tick: still no label ($(labelled)), one comment ($(cposts)), one HELD line ($(held))"

# M3 — running: no label, no comment; then green: labelled.
fresh; pr 31 "$H1"; cr "$H1" "Build + Unit tests|completed|success" "E2E Tests|in_progress|"; tick
[ "$(labelled)" = 0 ] && [ "$(cposts)" = 0 ] && [ "$(cut -f3 "$CH/state/merge-conductor/ready-why/"*31 2>/dev/null)" = e2e-running ] && ok \
  || bad "M3 running: no label ($(labelled)), no comment ($(cposts)), e2e-running (log: $(clog))"
cr "$H1" "Build + Unit tests|completed|success" "E2E Tests|completed|success"; tick
[ "$(labelled)" = 1 ] && [ "$(cposts)" = 0 ] && ok || bad "M3 green on the next tick: labelled ($(labelled); log: $(clog))"

# M4 — red on head A; head B green clears it; head B red posts one new comment.
fresh; pr 31 "$H1"; cr "$H1" "${RED_SHARDS[@]}"; tick
[ "$(labelled)" = 0 ] && [ "$(cposts)" = 1 ] && ok || bad "M4 head A red: held, one comment"
pr 31 "$H2"; cr "$H2" "Build + Unit tests|completed|success" "E2E (2/4)|completed|success"; tick
[ "$(labelled)" = 1 ] && [ "$(cposts)" = 1 ] && ok || bad "M4 head B green: labelled, no new comment (labels $(labelled), posts $(cposts); log: $(clog))"
fresh; pr 31 "$H1"; cr "$H1" "${RED_SHARDS[@]}"; tick
pr 31 "$H3"; cr "$H3" "${RED_SHARDS[@]}"; tick
[ "$(labelled)" = 0 ] && [ "$(cposts)" = 2 ] && grep -qF '`cccccccc`' "$FX/comment-bodies.txt" && ok \
  || bad "M4 head B red: one new comment for B (posts $(cposts); log: $(clog))"

# M5 — fix-main-red with a red shard: labelled, no check-runs read by the gate.
fresh; pr 31 "$H1" fix-main-red; cr "$H1" "${RED_SHARDS[@]}"; tick
[ "$(labelled)" = 1 ] && [ "$(held)" = 0 ] && [ "$(cposts)" = 0 ] && [ "$(crreads)" = 0 ] && ok \
  || bad "M5 fix-main-red: labelled ($(labelled)), not held, no gate read ($(crreads)); log: $(clog)"

# M6 — no end-to-end check at all: labelled.
fresh; pr 31 "$H1"; cr "$H1" "Build + Unit tests|completed|success" "Lint|completed|success"; tick
[ "$(labelled)" = 1 ] && [ "$(held)" = 0 ] && ok || bad "M6 no E2E check: labelled ($(labelled); log: $(clog))"

# M7 — two READY PRs in one tick: the red one is held, the green one labelled.
fresh; pr 31 "$H1"; pr 32 "$H2"; cr "$H1" "${RED_SHARDS[@]}"; cr "$H2" "Build + Unit tests|completed|success" "E2E (2/4)|completed|success"; tick
[ "$(labelled 31)" = 0 ] && [ "$(labelled 32)" = 1 ] && [ "$(n "$FX/comment-posts.txt")" = 1 ] && [ "$(cposts 31)" = 1 ] && ok \
  || bad "M7 one held, one labelled, one comment (31: $(labelled 31), 32: $(labelled 32), comments $(n "$FX/comment-posts.txt"); log: $(clog 3))"

# B0 — no workflow dispatch or rerun anywhere in part B.
if grep -qE 'dispatches|/rerun' "$FX/gh-all.log" 2>/dev/null; then bad "B0 a workflow dispatch or rerun was requested"; else ok; fi

# RED — the M1 tick with the fragment absent: labelled.
scratch_rm "$CH/bin/merge-conductor.d"
fresh; pr 31 "$H1"; cr "$H1" "${RED_SHARDS[@]}"; tick
[ "$(labelled)" = 1 ] && [ "$(held)" = 0 ] && ok || bad "RED without the fragment the M1 PR is labelled (labels $(labelled))"
install_frag || bad "setup: cannot install the fragment"

# B0 — every conductor curl went to a .test host.
OUT=$(awk '{print $2}' "$C/curl-all.log" 2>/dev/null | grep -vE '^https?://[a-z0-9.-]+\.test(/|$)' || true)
[ -z "$OUT" ] && ok || bad "B0 a curl left the fixture hosts: $OUT"

echo "merge-conductor-e2e-red-hold.bh-9071: part B $PASS passed; $FAIL failed in all (part A counted above)"
[ "$FAIL" -eq 0 ]
