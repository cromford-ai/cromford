#!/bin/bash
# tests/stranded-watch-push-rejected.bh-7946-test.sh — the stranded-ticket watch
# does not hold a ticket for a human when the pool's push was refused on the
# ticket's OWN branch (BH-7946).
#
# THE INCIDENT. BH-7519 and TK-1556: a pool build finished, its push leased on
# "new" was refused because another writer had created ticket/<key>, the reap
# wrote a push-rejected terminal, and the watch re-offered the ticket three
# times into that terminal and then wrote hold:waiting-on-human.
#
#   S1  a push-rejected terminal whose reason says branch-check=own: no hold,
#       no queue row, ONE ALERTS line naming the branch, the head and RETRY;
#       the next run adds no line
#   S2  branch-check=foreign with the re-offer count at max: the hold is placed
#       and its text names the branch, the head, the foreign commit, Recover:
#   S3  the reason cannot be read (no terminal file, no row): the hold as
#       today, and its text names the head and Recover:
#   S4  a legacy reason with no branch-check token (the BH-7519 and TK-1556
#       shape): not held, one alert
#   S5  a last result that is not push-rejected: today's hold, byte for byte
#   S6  the S1 alert marker is older than the window: alerted again, once
#   S7  foreign below the max: re-offered with a queue row, as today
#   S8  branch-check=unreadable (no-merge-base), open-pr and absent at max:
#       each is held (1 hold, no not-held alert); ancestor is not held
#   S4b the S4 alert says "branch not checked", never "no foreign commits"
#
# The rig is tests/stranded-watch.bh-5967-test.sh's: the real
# bin/orphan-reconcile.sh --stranded against a scratch HARNESS, fake gh and
# curl, and stubs of needs-human-hold.sh and alert-line.sh that record argv.
# Run from anywhere (exit 0 = pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
# ONE clock read for the file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/env" \
         "$H/prompts" "$H/builds" "$H/fixture" "$T/fakebin"
export HARNESS="$H"
P=project-5
for L in bin/orphan-reconcile.sh bin/jobs-client.sh bin/lib/preplan-lib.sh bin/lib/gh-budget.sh bin/lib/hold.sh \
         bin/lib/closeout-overdue.sh bin/lib/gh-rest.sh bin/lib/gh-rest-var.sh bin/lib/gh-rest-list.sh bin/fleet-conf.sh \
         bin/lib/pool-state-rows.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
for L in $(cd "$DIR" && printf '%s ' bin/lib/jobs/*.sh); do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
export FLEET_CONF="$DIR/fleet.conf"
echo 'setsid /root/harness/bin/run-build.sh project-5 <issue-number> TK-<issue-number> > x' > "$H/prompts/$P.md"
printf 'HARNESS_SECRET=fixture-secret\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$*" >> "$HARNESS/launches.log"' > "$H/bin/run-build.sh"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$*" >> "$HARNESS/alerts-called.log"' > "$H/bin/lane-alert.sh"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$*" >> "$HARNESS/needs-human.log"' 'exit 0' > "$H/bin/needs-human-hold.sh"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$*" >> "$HARNESS/alert-lines.log"' 'exit 0' > "$H/bin/alert-line.sh"
chmod +x "$H/bin/"*.sh

# gh: the open board, the all-states list, the (empty) PR list.
cat > "$T/fakebin/gh" <<'SH'
ARGS="$*"
SEND() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "$2"; exit 0; }
PAGE=$(printf '%s' "$ARGS" | sed -nE 's/.*page=([0-9]+).*/\1/p'); PAGE="${PAGE:-1}"
[ "$PAGE" = 1 ] || SEND 200 '[]'
case "$ARGS" in
  "api repos/example-org/project-5 -q .id") echo 1; exit 0 ;;
  *"api rate_limit"*) exit 1 ;;
  *"/issues/"*"/comments"*) SEND 200 '[]' ;;
  *"/pulls"*) SEND 200 '[]' ;;
  *"/issues"*"state=all"*)
    SEND 200 "$(jq -c '[ .[] | {number, state:"open", closed_at:null} ]' "$HARNESS/fixture/open.json")" ;;
  *"/issues"*)
    SEND 200 "$(jq -c '[ .[] | {number, title, body, comments:0, updated_at:.updatedAt} ]' "$HARNESS/fixture/open.json")" ;;
  *) exit 1 ;;
esac
SH
# curl: the jobs ledger, the queue (a FAILED row whose reason is
# fixture/qreason-<KEY>), and every POST to /api/queue recorded.
cat > "$T/fakebin/curl" <<'SH'
URL="${!#}"; METHOD=GET; BODY=""
prev=""
for a in "$@"; do
  [ "$prev" = -X ] && METHOD="$a"
  [ "$prev" = --data-binary ] && BODY="$a"
  prev="$a"
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}" 2>/dev/null) ;; esac
case "$METHOD $URL" in
  "POST "*/api/queue*) printf '%s\n' "$BODY" >> "$HARNESS/queue-posts.log"; printf '{"ok":true}\n200\n' ;;
  "GET "*/api/queue*"key="*)
    k=$(printf '%s' "$URL" | sed -nE 's/.*key=([^&]+).*/\1/p')
    jq -nc --arg k "$k" --arg r "$(cat "$HARNESS/fixture/qreason-$k" 2>/dev/null)" \
      '{queue:[{project:"project-5",ticket_key:$k,status:"failed",reason:$r}]}'
    printf '200\n' ;;
  "GET "*/api/queue*) printf '{"queue":[]}\n200\n' ;;
  "GET "*/api/jobs*) printf '%s\n200\n' "$(cat "$HARNESS/fixture/jobs.json")" ;;
  *) printf '{"ok":true}\n200\n' ;;
esac
SH
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"

ISO() { date -u -d "@$(( NOW - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }
SHA=4f1c2a9e8d7b6c5a4f3e2d1c0b9a8f7e6d5c4b3a
RSHA=c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2
# one <n> <queue reason> [<terminal reason>] — the board is ONE stranded ticket,
# TK-<n>; its queue row ended 150 min ago with <queue reason>, and when given,
# state/pool/project-5/TK-<n>.terminal carries <terminal reason>.
one() {
  scratch_rm "$H/state"; scratch_rm "$H/logs"; scratch_rm "$H/builds"
  mkdir -p "$H/state" "$H/logs" "$H/builds"
  rm -f "$H/launches.log" "$H/queue-posts.log" "$H/needs-human.log" "$H/alert-lines.log" "$H/fixture/qreason-"*
  N="$1"; K="TK-$1"
  printf '[{"number":%s,"title":"%s stranded","body":"## Scope","comments":[],"updatedAt":"%s"}]\n' "$N" "$K" "$(ISO 86400)" > "$H/fixture/open.json"
  printf '{"jobs":[{"id":"build-project-5-%s-0","ticket_id":"%s","kind":"build","status":"failed","updated_at":"%s","meta":"{\\"ticket_id\\":\\"%s\\"}"}]}\n' \
    "$K" "$K" "$(ISO 9000)" "$N" > "$H/fixture/jobs.json"
  printf '%s' "$2" > "$H/fixture/qreason-$K"
  if [ -n "${3:-}" ]; then
    mkdir -p "$H/state/pool/$P"
    jq -nc --arg r "$3" --arg b "ticket/ts-$N" --arg s "$SHA" '{branch:$b,head_sha:$s,reason:$r,created_at:"2026-10-21T15:41:00Z"}' > "$H/state/pool/$P/$K.terminal"
  fi
}
at_max() { mkdir -p "$H/state/stranded-watch/$P"; printf '%s\n' "$NOW" "$NOW" "$NOW" > "$H/state/stranded-watch/$P/$K.reoffers"; }
watch() { "$H/bin/orphan-reconcile.sh" --stranded "$P" 2>/dev/null; }
forget() { rm -f "$H/state/orphan-reconcile/$P/$K.enqueued"; }
n() { local c; c=$(grep -c . "$1" 2>/dev/null); echo "${c:-0}"; }
QR() { printf 'push to ticket/ts-%s rejected at %s — terminal, not respawned (state/pool/project-5/TK-%s.terminal)' "$1" "$SHA" "$1"; }

# ── S1: own branch — not held, one alert, and only once ───────────────────
one 1 "$(QR 1)" "BUILD_DEFERRED push of ticket/TK-1 rejected at $SHA branch-check=own remote=$RSHA commits=2"
at_max
watch
[ "$(n "$H/needs-human.log")" = 0 ] && ok || bad "S1 THE POINT: no hold for a push rejected on the ticket's own branch: $(cat "$H/needs-human.log")"
[ "$(n "$H/queue-posts.log")" = 0 ] && ok || bad "S1 no queue row (a re-offer runs into the same terminal): $(cat "$H/queue-posts.log")"
[ "$(n "$H/alert-lines.log")" = 1 ] && ok || bad "S1 exactly one alert line: $(cat "$H/alert-lines.log" 2>/dev/null)"
grep -q "^--project project-5 \[stranded/project-5\] TK-1: push to ticket/TK-1 rejected at $SHA with no foreign commits — not held (BH-7946). Recover: comment RETRY on #1; the next pool build resumes ticket/TK-1 from its head$" "$H/alert-lines.log" && ok \
  || bad "S1 the alert names the branch, the head and RETRY: $(cat "$H/alert-lines.log" 2>/dev/null)"
grep -q 'stranded: TK-1 (issue #1) push-rejected on its own branch ticket/TK-1' "$H/logs/$P.log" && ok || bad "S1 the log line: $(grep 'stranded:' "$H/logs/$P.log")"
grep -q 'skipped=TK-1:push-rejected-own' "$H/logs/$P.log" && ok || bad "S1 the summary skips TK-1:push-rejected-own: $(grep 'stranded-watch:' "$H/logs/$P.log")"
[ ! -e "$H/state/stranded-watch/$P/$K.needs-human" ] && ok || bad "S1 no NEEDS_HUMAN marker"
forget; watch
[ "$(n "$H/alert-lines.log")" = 1 ] && ok || bad "S1 the second run adds no alert line: $(cat "$H/alert-lines.log")"
[ "$(n "$H/needs-human.log")" = 0 ] && ok || bad "S1 the second run places no hold either"

# ── S6: the marker is older than the window — alerted again, once ─────────
printf '%s\n' "$(( NOW - 25 * 3600 ))" > "$H/state/stranded-push-rejected/$P/TK-1.alerted"
forget; watch
[ "$(n "$H/alert-lines.log")" = 2 ] && ok || bad "S6 a stale marker alerts again: $(n "$H/alert-lines.log") line(s)"
forget; watch
[ "$(n "$H/alert-lines.log")" = 2 ] && ok || bad "S6 ...and only once: $(n "$H/alert-lines.log") line(s)"

# ── S2: foreign at max — held, and the hold says how to recover ───────────
FIRST=a1b2c3d4e5f60718293a4b5c6d7e8f9011223344
one 2 "$(QR 2)" "BUILD_DEFERRED push of ticket/TK-2 rejected at $SHA branch-check=foreign remote=$RSHA first=$FIRST by Other Person"
at_max
watch
[ "$(n "$H/needs-human.log")" = 1 ] && ok || bad "S2 a foreign branch is still held: $(n "$H/needs-human.log")"
grep -qF "Branch ticket/TK-2 head $SHA: first=$FIRST by Other Person. Recover: if the branch is this ticket's work, open a PR from ticket/TK-2; otherwise move that work to another branch and comment RESUME." "$H/needs-human.log" && ok \
  || bad "S2 the hold names the branch, its head, the foreign commit and Recover: $(cat "$H/needs-human.log")"
[ "$(n "$H/alert-lines.log")" = 0 ] && ok || bad "S2 no not-held alert for a foreign branch"

# ── S3: the reason cannot be read — held as today, with the head ──────────
one 3 "$(QR 3)"
at_max
watch
[ "$(n "$H/needs-human.log")" = 1 ] && ok || bad "S3 an unreadable reason keeps the hold: $(n "$H/needs-human.log")"
grep -qF "Branch ticket/TK-3 head $SHA. Recover:" "$H/needs-human.log" && ok || bad "S3 the hold names the head and Recover: $(cat "$H/needs-human.log")"

# ── S4: the legacy reason (no branch-check token) — not held ──────────────
one 4 "terminal: push to ticket/TK-4 rejected at $SHA, head unchanged — not respawned until the branch moves or a RETRY comment (state/pool/project-5/TK-4.terminal)" \
  "BUILD_DEFERRED push of ticket/TK-4 rejected at $SHA"
at_max
watch
[ "$(n "$H/needs-human.log")" = 0 ] && ok || bad "S4 the BH-7519 shape is not held: $(cat "$H/needs-human.log")"
[ "$(n "$H/alert-lines.log")" = 1 ] && grep -q "TK-4: push to ticket/TK-4 rejected at $SHA" "$H/alert-lines.log" && ok \
  || bad "S4 one alert line: $(cat "$H/alert-lines.log" 2>/dev/null)"

grep -q "branch not checked" "$H/alert-lines.log" && ! grep -q "no foreign commits" "$H/alert-lines.log" && ok \
  || bad "S4b the legacy alert says the branch was not checked: $(cat "$H/alert-lines.log" 2>/dev/null)"

# ── S5: not a push-rejected result — today's hold, byte for byte ──────────
one 5 "died 3 times"
at_max
watch
[ "$(cut -d' ' -f4- "$H/needs-human.log")" = "the stranded-ticket watch re-offered TK-5 3 times in 24h and no PR came of it. Last result: failed: died 3 times. Read the newest build record for TK-5 and decide; RESUME re-offers it. stranded-watch" ] && ok \
  || bad "S5 the hold text is unchanged: $(cat "$H/needs-human.log")"
[ "$(n "$H/alert-lines.log")" = 0 ] && ok || bad "S5 no alert line"

# ── S7: foreign below the max — re-offered as today ───────────────────────
one 7 "$(QR 7)" "BUILD_DEFERRED push of ticket/TK-7 rejected at $SHA branch-check=foreign remote=$RSHA first=$FIRST by Other Person"
watch
[ "$(n "$H/queue-posts.log")" = 1 ] && grep -q '"key":"TK-7"' "$H/queue-posts.log" && ok || bad "S7 a foreign branch below the max is re-offered: $(cat "$H/queue-posts.log" 2>/dev/null)"
[ "$(n "$H/needs-human.log")" = 0 ] && [ "$(n "$H/alert-lines.log")" = 0 ] && ok || bad "S7 no hold and no alert below the max"

# ── S8: a verdict that is not own/ancestor keeps the hold ────────────────
i=80
for V in "unreadable remote=$RSHA no-merge-base" "unreadable remote=none ls-remote" "open-pr remote=$RSHA" "absent remote=none"; do
  i=$((i + 1))
  one "$i" "$(QR "$i")" "BUILD_DEFERRED push of ticket/ts-$i rejected at $SHA branch-check=$V"
  at_max
  watch
  [ "$(n "$H/needs-human.log")" = 1 ] && ok || bad "S8 branch-check=$V at max is held: $(n "$H/needs-human.log") hold(s)"
  [ "$(n "$H/alert-lines.log")" = 0 ] && ok || bad "S8 branch-check=$V: no not-held alert: $(cat "$H/alert-lines.log" 2>/dev/null)"
done
one 89 "$(QR 89)" "BUILD_DEFERRED push of ticket/TK-89 rejected at $SHA branch-check=ancestor remote=$RSHA"
at_max
watch
[ "$(n "$H/needs-human.log")" = 0 ] && [ "$(n "$H/alert-lines.log")" = 1 ] && ok \
  || bad "S8 branch-check=ancestor is not held, one alert: holds=$(n "$H/needs-human.log") alerts=$(n "$H/alert-lines.log")"

echo "stranded-watch-push-rejected.bh-7946: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
