#!/bin/bash
# tests/reconcile-prs-closed-unmerged-test.sh — a closed-unmerged PR is
# `pr_closed`, never `pr_merged` (BH-866).
#
# THE DEFECT THIS PINS. bin/reconcile-prs.sh had ONE list. Its CLOSED arm and
# its MERGED arm both did `MERGED=$(jq '. + [$b]')`, and the only thing sent to
# the console was `{"merged":[...]}`. The comment above the CLOSED arm says
# "must ALSO clear its console row … No ship beat for these: nothing shipped" —
# so the intent was always "clear the row", but the payload said "this shipped".
# project-4 #1579 (auto-closed when its base branch was deleted) and #1541 (closed by
# a human as superseded) both landed in the console as merged/deployed rows for
# work that never shipped a line.
#
# The fix classifies off the MERGE FACT (`mergedAt` / gh's MERGED), never off
# `state == CLOSED`, and gives a closed-unmerged PR its own terminal: reported
# under `closed`, ledgered `merge=<url> closed`, logged `pr_closed`, no ship
# beat, no deploy gate — and the ticket is launchable again.
#
# Driven, not grepped: the real script runs end to end against a gh stub whose
# state/closedAt/mergedAt triple is the only input that changes, and the
# assertions are on the recorded POST body, the recorded ledger PUT, the beats
# file and the log.
# Run from anywhere: tests/reconcile-prs-closed-unmerged-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# An ISO-8601 stamp <n> seconds in the past, without GNU date. The settle window
# (MC_CLOSED_SETTLE) is the one thing in this lane that reads a clock, so every
# closure here is deliberately far outside it.
ago() { python3 -c 'import sys,time;print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time()-int(sys.argv[1]))))' "$1"; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/locks" "$H/env" "$H/builds" "$T/fakebin"
cp "$DIR/bin/reconcile-prs.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" "$H/bin/"
cp "$DIR/bin/jobs-client.sh" "$H/bin/"
# Same shape for the client itself: it is a shim over bin/lib/jobs/ (BH-1194).
mkdir -p "$H/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-pr-list.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-etag.sh" "$H/bin/lib/"
# The lib is a shim over bin/lib/mc/ (BH-477/BH-680): it resolves its modules off
# BASH_SOURCE and `exit 1`s the CALLER when one is missing — so a fixture that
# copies the lib without the modules kills reconcile-prs.sh before it runs a line.
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
# BH-1583: the lane runs only on the reconcile owner and reads its knobs with no
# literal; this fixture box is armed as the owner (tests/lib/reconcile-fixture.sh).
. "$(dirname "$0")/lib/reconcile-fixture.sh" || exit 1
rcfx_arm "$H" "$DIR" || exit 1
printf 'demo-os Example/demo-os https://demo.example /api/board 2 box-a\n' > "$H/fleet.conf"
printf 'CONSOLE_URL=https://console.example\nHARNESS_SECRET=shh\nJOBS_URL=https://jobs.example\n' > "$H/env/global.env"
# demo-os owns its deploys, so a merged row reaches the deploy gate and a closed
# one must be seen NOT to.
printf 'DEPLOY_HOOK_URL=https://hook.example/demo-os\n' > "$H/env/demo-os.env"

printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nexec "$@"\n' > "$T/fakebin/setsid"; chmod +x "$T/fakebin/setsid"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/beats.txt"\nexit 0\n' "$T" > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
printf '#!/bin/bash\nprintf "%%s\\t%%s\\t%%s\\n" "$1" "$2" "$3" >> "%s/deploys.txt"\nexit 0\n' "$T" > "$H/bin/deploy-request.sh"; chmod +x "$H/bin/deploy-request.sh"

# ── the four rows the console says are unmerged ──────────────────────────────
#   TK-9  CLOSED, never merged   -> pr_closed
#   TK-10 MERGED                 -> merged, ship beat, deploy gate
#   TK-11 OPEN                   -> neither list, still unmerged
#   TK-12 gh answers nothing     -> neither list (absent is not an outcome)
UNMERGED='{"builds":[{"bkey":"demo-os-TK-9-202609180001","pr_url":"https://github.com/Example/demo-os/pull/9"},
           {"bkey":"demo-os-TK-10-202609180002","pr_url":"https://github.com/Example/demo-os/pull/10"},
           {"bkey":"demo-os-TK-11-202609180003","pr_url":"https://github.com/Example/demo-os/pull/11"},
           {"bkey":"demo-os-TK-12-202609180004","pr_url":"https://github.com/Example/demo-os/pull/12"}]}'
printf '%s\n' "$UNMERGED" > "$T/unmerged.json"

# BH-994/BH-1295: reconcile-prs.sh reads PR state through mc_pr_view ->
# gh_rest now, never `gh pr view` (GraphQL) — the same REST body every other
# decision read in the fleet goes through. This stub answers the shape gh_rest
# sends (`gh api -i -X GET repos/<slug>/pulls/<num>`): a status line, a blank
# line, then the pull object. No ETag header is sent, so gh-rest.sh's cache
# never stores anything here — this fixture stays a pure test of
# reconcile-prs.sh's own classification, not of the cache (that is
# tests/gh-rest-etag-test.sh's job). #12 answers nothing at all (dead gh, no
# status line), the same "GitHub said nothing" shape the old stub gave it.
mk_gh() {
  cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
NUM=""
for a in "\$@"; do case "\$a" in repos/*/pulls/*) NUM="\${a##*/}" ;; esac; done
emit() { printf 'HTTP/2.0 200 Status\r\n\r\n%s' "\$1"; }
case "\$NUM" in
  9)  emit '{"state":"closed","closed_at":"$(ago 600)","merged_at":null,"merge_commit_sha":null}' ;;
  10) emit '{"state":"closed","closed_at":"$(ago 600)","merged_at":"$(ago 600)","merge_commit_sha":"deadbeefcafe"}' ;;
  11) emit '{"state":"open","closed_at":null,"merged_at":null,"merge_commit_sha":null}' ;;
  12) exit 1 ;;
  *)  exit 1 ;;
esac
exit 0
EOF
  chmod +x "$T/fakebin/gh"
}

# curl stub: the console lane sends no -w, the jobs client sends
# `-w \n%{http_code}` and needs the status back on its own line.
mk_curl() { # mk_curl <console-reconcile-http-behaviour: ok|refuse-closed>
  cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
MODE="$1"
URL="\${!#}"; BODY=""; WANT_CODE=0; METHOD=GET
while [ \$# -gt 0 ]; do
  case "\$1" in
    --data-binary|--data|-d) BODY="\$2"; shift 2 ;;
    -X) METHOD="\$2"; shift 2 ;;
    -w) WANT_CODE=1; shift 2 ;;
    *) shift ;;
  esac
done
emit() { printf '%s' "\$1"; [ "\$WANT_CODE" = 1 ] && printf '\n%s' "\$2"; printf '\n'; }
case "\$URL" in
  *"/api/builds/unmerged") emit "\$(cat "$T/unmerged.json")" 200 ;;
  *"/api/builds/reconcile")
    printf '%s\n' "\$BODY" >> "$T/reconciled.txt"
    if [ "\$MODE" = refuse-all ]; then
      emit '{"error":"boom"}' 500
    elif [ "\$MODE" = refuse-closed ] && grep -q '"closed"' <<<"\$BODY"; then
      emit '{"error":"unknown field closed"}' 400
    else
      emit '{"ok":true}' 200
    fi ;;
  *"/api/ledger"*)
    printf '%s %s\n' "\$METHOD" "\$BODY" >> "$T/ledger.txt"
    if [ "\$MODE" = ledger-down ]; then emit '{"error":"down"}' 500
    else emit '{"ok":true}' 200; fi ;;
  *) emit '{}' 200 ;;
esac
exit 0
EOF
  chmod +x "$T/fakebin/curl"
}

reconcile_pass() { # one */10 pass, keeping whatever state the last one left
  : > "$T/reconciled.txt"; : > "$T/ledger.txt"; : > "$T/beats.txt"; : > "$T/deploys.txt"
  : > "$H/logs/reconcile.log"
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" JOBS_RETRIES=0 \
      bash "$H/bin/reconcile-prs.sh" >/dev/null 2>"$T/rec.err" ) || true
  # the deploy gate is launched detached; give it a moment to land
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T/deploys.txt" ] && break; sleep 0.2; done
}
run_reconcile() { # a FRESH box: the once-per-row markers are state that
  # deliberately survives a pass, so they must not leak between cases.
  [ -e "$H/state/reconcile-closed" ] && scratch_rm "$H/state/reconcile-closed"
  reconcile_pass
}
body_field() { jq -r "$1" < <(tail -1 "$T/reconciled.txt") 2>/dev/null; }

# ════════════════════════════════════════════════════════════════════════════
# 1. THE CLASSIFICATION
# ════════════════════════════════════════════════════════════════════════════
mk_gh; mk_curl ok; run_reconcile

[ "$(body_field '.merged // [] | length')" = 1 ] \
  && ok || bad "exactly ONE row merged (TK-10), got: $(cat "$T/reconciled.txt")"
[ "$(body_field '.merged[0] // ""')" = "demo-os-TK-10-202609180002" ] \
  && ok || bad "the merged list must name TK-10: $(cat "$T/reconciled.txt")"
# THE DEFECT ITSELF: a CLOSED, never-merged PR reported as merged.
grep -q 'TK-9' <<<"$(printf '%s' "$(body_field '.merged // [] | @csv')")" \
  && bad "a CLOSED PR with no mergedAt must NEVER enter the merged list — that is how project-4 #1579/#1541 became merged_deployed rows: $(cat "$T/reconciled.txt")" \
  || ok
[ "$(body_field '.closed // [] | length')" = 1 ] \
  && ok || bad "TK-9 must be reported under its own 'closed' list: $(cat "$T/reconciled.txt")"
[ "$(body_field '.closed[0] // ""')" = "demo-os-TK-9-202609180001" ] \
  && ok || bad "the closed list must name TK-9: $(cat "$T/reconciled.txt")"
# OPEN and "gh said nothing" are not terminals of any kind (D11).
grep -q 'TK-11' "$T/reconciled.txt" \
  && bad "an OPEN PR must reach neither list: $(cat "$T/reconciled.txt")" || ok
grep -q 'TK-12' "$T/reconciled.txt" \
  && bad "a PR gh could not answer for must reach neither list — absent is not closed: $(cat "$T/reconciled.txt")" || ok

# ── nothing shipped, so nothing says shipped ────────────────────────────────
grep -q 'shipped:demo-os-TK-10' "$T/beats.txt" \
  && ok || bad "the merged row must still ring the ship beat: $(cat "$T/beats.txt")"
grep -q 'shipped:demo-os-TK-9' "$T/beats.txt" \
  && bad "a closed-unmerged PR must get NO ship beat — nothing shipped: $(cat "$T/beats.txt")" || ok
grep -q 'demo-os' "$T/deploys.txt" && ok || bad "the merged row must still reach the deploy gate: $(cat "$T/deploys.txt")"
[ "$(wc -l < "$T/deploys.txt")" = 1 ] \
  && ok || bad "only the merged row may reach the deploy gate: $(cat "$T/deploys.txt")"

# ── the log says which terminal each row got ────────────────────────────────
grep -q 'pr_closed' "$H/logs/reconcile.log" \
  && ok || bad "the closed-unmerged row must be logged as pr_closed: $(cat "$H/logs/reconcile.log")"
grep -q 'TK-9' <<<"$(grep 'pr_closed' "$H/logs/reconcile.log")" \
  && ok || bad "the pr_closed line must name the row: $(cat "$H/logs/reconcile.log")"
grep -q 'reconciled 1 externally-merged PR(s), 1 closed unmerged (pr_closed)' "$H/logs/reconcile.log" \
  && ok || bad "the summary must count both terminals separately: $(cat "$H/logs/reconcile.log")"

# ── the jobs ledger learns the PR is over ───────────────────────────────────
LROW=$(grep -F 'https://github.com/Example/demo-os/pull/9' "$T/ledger.txt" | head -1)
[ -n "$LROW" ] && ok || bad "the closed PR must be ledgered so the ticket is launchable again: $(cat "$T/ledger.txt")"
LBODY=${LROW#PUT }
[ "$(jq -r '.kind // ""' <<<"$LBODY" 2>/dev/null)" = merge ] \
  && ok || bad "the ledger row keeps kind=merge (what closeout_terminal and pr-owner-sweep already read), got: $LBODY"
[ "$(jq -r '.status // ""' <<<"$LBODY" 2>/dev/null)" = closed ] \
  && ok || bad "the ledger status for a closed-unmerged PR is 'closed', got: $LBODY"
grep -q '"status":"closed"' <<<"$(grep -F 'https://github.com/Example/demo-os/pull/10' "$T/ledger.txt")" \
  && bad "the MERGED PR must never be ledgered closed: $(cat "$T/ledger.txt")" || ok

# ════════════════════════════════════════════════════════════════════════════
# 2. A CONSOLE THAT DOES NOT KNOW THE `closed` KEY YET
# The console repo is not in this one. Until it learns the field, a POST it
# refuses must not take the MERGED rows down with it.
# ════════════════════════════════════════════════════════════════════════════
mk_curl refuse-closed; run_reconcile
[ "$(wc -l < "$T/reconciled.txt")" = 2 ] \
  && ok || bad "a refused POST must be retried once without the closed list, got $(wc -l < "$T/reconciled.txt") POST(s): $(cat "$T/reconciled.txt")"
RETRY=$(tail -1 "$T/reconciled.txt")
[ "$(jq -r '.merged[0] // ""' <<<"$RETRY" 2>/dev/null)" = "demo-os-TK-10-202609180002" ] \
  && ok || bad "the retry must still carry the merged row: $RETRY"
jq -e 'has("closed")' <<<"$RETRY" >/dev/null 2>&1 \
  && bad "the retry must drop the field the console refused: $RETRY" || ok
grep -qi 'console refused closed list' "$H/logs/reconcile.log" \
  && ok || bad "a refused field must be said out loud, not swallowed: $(cat "$H/logs/reconcile.log")"
# The ledger row is written BEFORE the console is told, so it survives a refusal.
grep -F 'https://github.com/Example/demo-os/pull/9' "$T/ledger.txt" | grep -q '"status":"closed"' \
  && ok || bad "the ledger row must be written before the POST, so a console refusal does not lose it: $(cat "$T/ledger.txt")"

# ════════════════════════════════════════════════════════════════════════════
# 3. NO JOBS CLIENT ON THIS BOX — fail open, exactly as the lane does today
# ════════════════════════════════════════════════════════════════════════════
mv "$H/bin/jobs-client.sh" "$T/jobs-client-parked.sh"
mk_curl ok; run_reconcile
[ "$(body_field '.closed[0] // ""')" = "demo-os-TK-9-202609180001" ] \
  && ok || bad "with no jobs-client the closed list must still be reported: $(cat "$T/reconciled.txt")"
[ -s "$T/ledger.txt" ] \
  && bad "with no jobs-client there is nothing to PUT — it must not be attempted: $(cat "$T/ledger.txt")" || ok
grep -q 'pr_closed' "$H/logs/reconcile.log" \
  && ok || bad "the log line does not depend on the ledger: $(cat "$H/logs/reconcile.log")"
mv "$T/jobs-client-parked.sh" "$H/bin/jobs-client.sh"

# ════════════════════════════════════════════════════════════════════════════
# 4. A MERGED PR IS ALWAYS ALSO CLOSED — the merge fact wins
# ════════════════════════════════════════════════════════════════════════════
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf 'HTTP/2.0 200 Status\r\n\r\n{"state":"closed","closed_at":"$(ago 600)","merged_at":"$(ago 600)","merge_commit_sha":"deadbeefcafe"}'
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '{"builds":[{"bkey":"demo-os-TK-13-202609180005","pr_url":"https://github.com/Example/demo-os/pull/13"}]}\n' > "$T/unmerged.json"
mk_curl ok; run_reconcile
[ "$(body_field '.merged[0] // ""')" = "demo-os-TK-13-202609180005" ] \
  && ok || bad "a row gh reports CLOSED but with a mergedAt is MERGED — the merge fact decides: $(cat "$T/reconciled.txt")"
[ "$(body_field '.closed // [] | length')" = 0 ] \
  && ok || bad "...and it must not be double-reported as closed: $(cat "$T/reconciled.txt")"

# ════════════════════════════════════════════════════════════════════════════
# 5. THE ROW SURVIVES EVERY PASS UNTIL THE CONSOLE LEARNS `closed` — SAY IT ONCE
# `/api/builds/reconcile` lives in the console repo and does not know the key
# yet (the human step in the PR body). Until it does, this row comes back on
# every */10 pass forever: the ledger PUT is idempotent and must keep going, but
# an unguarded log line is a reconcile.log that grows without end for a PR that
# closed once.
# ════════════════════════════════════════════════════════════════════════════
printf '%s\n' "$UNMERGED" > "$T/unmerged.json"
mk_gh; mk_curl ok
run_reconcile
[ "$(grep -c 'cleared CLOSED (unmerged) PR row demo-os-TK-9' "$H/logs/reconcile.log")" = 1 ] \
  && ok || bad "the first pass says it: $(cat "$H/logs/reconcile.log")"
reconcile_pass    # the console still lists the row; the marker survives
[ "$(grep -c 'cleared CLOSED (unmerged) PR row demo-os-TK-9' "$H/logs/reconcile.log")" = 0 ] \
  && ok || bad "a row that is still listed every 10 minutes must be logged ONCE, not once per pass: $(cat "$H/logs/reconcile.log")"
[ "$(body_field '.closed[0] // ""')" = "demo-os-TK-9-202609180001" ] \
  && ok || bad "...and it must STILL be reported to the console on every pass — the log guard is a log guard, not a terminal: $(cat "$T/reconciled.txt")"
grep -q '"status":"closed"' <<<"$(grep -F 'https://github.com/Example/demo-os/pull/9' "$T/ledger.txt")" \
  && bad "the row is already ledgered closed — re-PUTting it every 10 minutes forever buys nothing: $(cat "$T/ledger.txt")" || ok

# ...and a PUT that FAILED is retried next pass, because the marker is only
# written once the row is actually IN the ledger. A guard that marked the row
# on attempt would turn one bad minute into a row nothing ever records.
mk_curl ledger-down; run_reconcile
grep -F 'https://github.com/Example/demo-os/pull/9' "$T/ledger.txt" | grep -q '"status":"closed"' \
  && ok || bad "the PUT is attempted while the ledger is down: $(cat "$T/ledger.txt")"
mk_curl ok; reconcile_pass
grep -F 'https://github.com/Example/demo-os/pull/9' "$T/ledger.txt" | grep -q '"status":"closed"' \
  && ok || bad "a PUT that could not land must be retried on the next pass — the marker belongs to the ledgered row, not to the attempt: $(cat "$T/ledger.txt")"

# ════════════════════════════════════════════════════════════════════════════
# 6. A CONSOLE THAT IS SIMPLY DOWN IS NOT A CONSOLE REFUSING `closed`
# With nothing in the closed list there is no field to drop, so a 500 (or an
# expired secret) must not log "console refused closed list" and must not
# re-POST the identical merged-only payload.
# ════════════════════════════════════════════════════════════════════════════
printf '{"builds":[{"bkey":"demo-os-TK-10-202609180002","pr_url":"https://github.com/Example/demo-os/pull/10"}]}\n' > "$T/unmerged.json"
mk_gh; mk_curl refuse-all; run_reconcile
[ "$(wc -l < "$T/reconciled.txt")" = 1 ] \
  && ok || bad "nothing was dropped, so there is nothing to retry — one POST: $(cat "$T/reconciled.txt")"
grep -qi 'console refused closed list' "$H/logs/reconcile.log" \
  && bad "a 500 with an empty closed list is an outage, not a refused field: $(cat "$H/logs/reconcile.log")" || ok

echo "reconcile-prs-closed-unmerged: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
