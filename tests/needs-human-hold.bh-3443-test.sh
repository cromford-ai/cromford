#!/bin/bash
# tests/needs-human-hold.bh-3443-test.sh — bin/needs-human-hold.sh, the placer
# (BH-3443 T1.2). Drives the real script in a scratch root against a stateful gh
# stub: the marker is posted once per (ticket, fp), verified by re-reading the
# thread through bin/lib/hold.sh, and the one console ask goes out only after.
#   §P  places: one POST, the marker shape, one alert; P2/P3 mask tokens, not words
#   §D  the same fp three times is one comment and one alert; a new fp is a new one
#   §V  a POST that did not land, or failed, is rc 1 with one could-not-place alert
#   §U  an unreadable issue is rc 75, nothing posted
#   §K  the kill switch   §B  not an issues board   §S  already stopped   §A  argv
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export HARNESS_TEST_SANDBOX=1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

NOW=$(date -u +%s)
H="$T/h"
mkdir -p "$H/bin/lib/needs-human" "$H/logs" "$H/flags" "$H/state" "$T/fakebin"
cp "$DIR/bin/needs-human-hold.sh" "$H/bin/"
cp "$DIR/bin/lib/hold.sh" "$DIR/bin/lib/needs-human.sh" "$DIR/bin/lib/lane-switch.sh" \
   "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/gh-app-auth.sh" "$H/bin/lib/"
cp "$DIR"/bin/lib/needs-human/*.sh "$H/bin/lib/needs-human/"
ln -s "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"
printf 'bp o/r - - 2 box-bp 100.0.0.9\ninapp o/inapp https://inapp.test /api/internal 3 box-ia 100.0.0.8\n' > "$T/fleet.conf"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/calls.alert"\nexit 0\n' "$T" > "$H/bin/alert-line.sh"
chmod +x "$H/bin/"*.sh

# THE STATEFUL gh. Every call is recorded. The issue and its thread are files;
# a POST appends its body to the thread as a Bot comment (the App's identity)
# unless POST_DROP=1 (accepted, never visible) or POST_FAIL=1 (refused).
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls.gh"
case "\$*" in
  *"-X POST repos/o/r/issues/7/comments"*)
    body=\$(jq -r '.body')
    printf '%s\n' "\$body" >> "$T/posts.txt"; printf -- '---\n' >> "$T/posts.txt"
    [ "\${POST_FAIL:-}" = 1 ] && { echo "HTTP 502" >&2; exit 1; }
    [ "\${POST_DROP:-}" = 1 ] && { echo '{"id":1}'; exit 0; }
    n=\$(jq length "$T/comments.json")
    jq -c --arg b "\$body" --arg c "\$(date -u -d "@\$(( $NOW + n ))" '+%Y-%m-%dT%H:%M:%SZ')" \
      '. + [{body:\$b, created_at:\$c, user:{type:"Bot"}}]' "$T/comments.json" > "$T/c.tmp" && mv "$T/c.tmp" "$T/comments.json"
    echo '{"id":2}' ;;
  *"repos/o/r/issues/7/comments"*) cat "$T/comments.json" ;;
  *"repos/o/r/issues/7"*)
    [ "\${ISSUE_FAIL:-}" = 1 ] && { echo "API rate limit exceeded" >&2; exit 1; }
    cat "$T/issue.json" ;;
  *) echo "unexpected gh \$*" >&2; exit 1 ;;
esac
EOF
printf '#!/bin/bash\nexit 7\n' > "$T/fakebin/curl"
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"
export GH_TOKEN="" FLEET_CONF="$T/fleet.conf" LANE_GATE_DISABLE=1

ACT='run vs_publish probe from the hub'
FP=abc123def456
RESET() { # RESET [labels csv]
  jq -nc --arg l "${1:-ai-build}" '{number:7, state:"open", title:"BP-7: a thing", body:"## Scope",
        labels:($l | split(",") | map({name:.}))}' > "$T/issue.json"
  echo '[]' > "$T/comments.json"
  rm -f "$T/calls.gh" "$T/calls.alert" "$T/posts.txt" "$H/logs/needs-human.log"
}
PLACE() { HARNESS="$H" bash "$H/bin/needs-human-hold.sh" "$@" 2>"$T/err"; }
posts() { cat "$T/posts.txt" 2>/dev/null | grep -c '^---$'; }
alerts() { cat "$T/calls.alert" 2>/dev/null | grep -c .; }

# ── §P: places ─────────────────────────────────────────────────────────────
RESET
PLACE bp 7 "$FP" "$ACT" review; RC=$?
[ "$RC" = 0 ] && ok || bad "P1: rc $RC, want 0 ($(cat "$T/err"))"
[ "$(posts)" = 1 ] && ok || bad "P1: want exactly 1 POST, got $(posts)"
BODY=$(sed '/^---$/,$d' "$T/posts.txt" 2>/dev/null)
[ "$(head -1 <<<"$BODY")" = "NEEDS-HUMAN: $ACT" ] && ok || bad "P1: body line 1 is not the marker: '$(head -1 <<<"$BODY")'"
grep -qF "<!-- nh-fp:$FP -->" <<<"$BODY" && ok || bad "P1: the body must carry the hidden nh-fp tag"
grep -q 'HUMAN-STEP-DONE:' <<<"$BODY" && ok || bad "P1: the body must say how to release it"
grep -q '^HUMAN-STEP-DONE:' <<<"$BODY" && bad "P1: HUMAN-STEP-DONE: must never open a line of our own comment" || ok
grep -q 'HOLD' <<<"$BODY" && bad "P1: no capital HOLD in the marker comment" || ok
[ "$(alerts)" = 1 ] && ok || bad "P1: want exactly 1 alert, got $(alerts)"
[ "$(cat "$T/calls.alert" 2>/dev/null)" = "--project bp [needs-human] bp#7 needs a human: $ACT — https://github.com/o/r/issues/7" ] && ok \
  || bad "P1: the alert text: '$(cat "$T/calls.alert" 2>/dev/null)'"
grep -q 'placed' "$H/logs/needs-human.log" 2>/dev/null && ok || bad "P1: the log must say placed"
# P2: a token in the action is masked in the comment and the alert.
RESET
TOK="gh""p_$(printf 'a%.0s' $(seq 1 36))"
PLACE bp 7 "$FP" "set $TOK in the env" review; RC=$?
[ "$RC" = 0 ] && ok || bad "P2: rc $RC ($(cat "$T/err"))"
grep -qsF "$TOK" "$T/posts.txt" "$T/calls.alert" && bad "P2: the raw token reached a comment or an alert" || ok
grep -qsF '[masked]' "$T/posts.txt" && grep -qsF '[masked]' "$T/calls.alert" && ok || bad "P2: both must say [masked]"
# P3: the other GitHub token shapes are masked too, and a word that merely
# contains a prefix ("task-list", "risk-free") is left as it was.
RESET
TOK2="gh""s_$(printf 'b%.0s' $(seq 1 36))"; TOK3="github""_pat_$(printf 'c%.0s' $(seq 1 40))"
PLACE bp 7 "$FP" "rotate $TOK2 and $TOK3, then rerun the task-list check risk-free" review; RC=$?
[ "$RC" = 0 ] && ok || bad "P3: rc $RC ($(cat "$T/err"))"
grep -qsF -e "$TOK2" -e "$TOK3" "$T/posts.txt" "$T/calls.alert" && bad "P3: a ghs_/github_pat_ token reached a comment or an alert" || ok
grep -qsF 'the task-list check risk-free' "$T/posts.txt" && ok || bad "P3: ordinary words were mangled: $(head -1 "$T/posts.txt" 2>/dev/null)"

# ── §D: dedupe on the fp ───────────────────────────────────────────────────
RESET
for i in 1 2 3; do PLACE bp 7 "$FP" "$ACT" review; RC=$?; [ "$RC" = 0 ] || bad "D: run $i rc $RC"; done
[ "$(posts)" = 1 ] && ok || bad "D: three runs on one fp must post once, got $(posts)"
[ "$(alerts)" = 1 ] && ok || bad "D: …and alert once, got $(alerts)"
[ "$(grep -c "already held for nh-fp:$FP" "$H/logs/needs-human.log")" = 2 ] && ok \
  || bad "D: runs 2 and 3 must log already held: $(cat "$H/logs/needs-human.log")"
PLACE bp 7 fff000fff000 "$ACT" review; RC=$?
[ "$RC" = 0 ] && [ "$(posts)" = 2 ] && [ "$(alerts)" = 2 ] && ok \
  || bad "D: a new fp is a new marker and a new alert (rc $RC posts $(posts) alerts $(alerts))"

# ── §V: the verify ─────────────────────────────────────────────────────────
RESET
POST_DROP=1 PLACE bp 7 "$FP" "$ACT" review; RC=$?
[ "$RC" = 1 ] && ok || bad "V1: a POST the thread never shows must be rc 1, got $RC"
[ "$(cat "$T/calls.alert" 2>/dev/null)" = "--project bp [needs-human] could not place hold on bp#7" ] && ok \
  || bad "V1: one could-not-place alert, got '$(cat "$T/calls.alert" 2>/dev/null)'"
RESET
POST_FAIL=1 PLACE bp 7 "$FP" "$ACT" review; RC=$?
[ "$RC" = 1 ] && [ "$(cat "$T/calls.alert" 2>/dev/null)" = "--project bp [needs-human] could not place hold on bp#7" ] && ok \
  || bad "V2: a failed POST is rc 1 with one could-not-place alert (rc $RC, '$(cat "$T/calls.alert" 2>/dev/null)')"

# ── §U: unreadable ─────────────────────────────────────────────────────────
RESET
ISSUE_FAIL=1 PLACE bp 7 "$FP" "$ACT" review; RC=$?
[ "$RC" = 75 ] && [ "$(posts)" = 0 ] && [ "$(alerts)" = 0 ] && ok \
  || bad "U: an unreadable issue is rc 75, nothing posted, no alert (rc $RC posts $(posts) alerts $(alerts))"

# ── §K: the kill switch ────────────────────────────────────────────────────
RESET
touch "$H/flags/needs-human-hold-off"
PLACE bp 7 "$FP" "$ACT" review; RC=$?
rm -f "$H/flags/needs-human-hold-off"
[ "$RC" = 0 ] && [ ! -e "$T/calls.gh" ] && ok || bad "K: switch on must be rc 0 with no gh call (rc $RC, gh: $(cat "$T/calls.gh" 2>/dev/null))"
grep -q 'switch needs-human-hold-off is on' "$T/err" && ok || bad "K: it must say the switch is on: $(cat "$T/err")"

# ── §B: not an issues board ────────────────────────────────────────────────
for p in inapp zz; do
  RESET
  PLACE "$p" 7 "$FP" "$ACT" review; RC=$?
  [ "$RC" = 0 ] && [ ! -e "$T/calls.gh" ] && grep -q 'not an issues board' "$T/err" && ok \
    || bad "B: $p must be rc 0, no gh call, 'not an issues board' (rc $RC, $(cat "$T/err"))"
done

# ── §S: already stopped ────────────────────────────────────────────────────
RESET ai-build,hold
PLACE bp 7 "$FP" "$ACT" review; RC=$?
[ "$RC" = 0 ] && [ "$(posts)" = 0 ] && grep -q 'already stopped' "$T/err" && ok \
  || bad "S: a hold-labelled issue gets no marker (rc $RC posts $(posts): $(cat "$T/err"))"

# ── §A: argv ───────────────────────────────────────────────────────────────
RESET
PLACE bp 7 "$FP" "$ACT"; RC=$?
[ "$RC" = 2 ] && ok || bad "A: 4 args must be rc 2, got $RC"
PLACE bp 7 NOTHEX "$ACT" review; RC=$?
[ "$RC" = 2 ] && ok || bad "A: a non-hex fp must be rc 2, got $RC"
PLACE bp seven "$FP" "$ACT" review; RC=$?
[ "$RC" = 2 ] && [ ! -e "$T/calls.gh" ] && ok || bad "A: a non-numeric issue must be rc 2 with no gh call, got $RC"

echo "needs-human-hold.bh-3443: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
