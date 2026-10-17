#!/bin/bash
# tests/hold-parse-shared.bh-6297-test.sh — one HOLD/RESUME reading for the
# fastpath, triage, the conductor and the hold-push guard (BH-6297).
#
# #5239 sat 4 h 27 min on 2026-10-12: a decision comment said the Cloud PRs
# "are on HOLD here" in its fourth line, and the fastpath read the capital word
# as a HOLD on the ticket. A comment now holds only when its FIRST non-blank
# line starts with HOLD (bin/lib/hold.sh HOLD_COMMENT_RE), and the fastpath
# decides condition 12 through hold_classify instead of its own walk.
#
#   H1  prose HOLD is not a hold: hold_classify clear, the fastpath launches
#   H2  a first-line HOLD is a hold: held hold:comment, "HOLD in comment"
#   H3  recency: HOLD then RESUME clear, RESUME then HOLD held; and the four
#       readers (hold_classify, to_hold_verdict, hold_push_verdict, the
#       fastpath) give the same class for every thread here
#   H4  a hotfix declined for a HOLD writes ONE ALERTS line quoting the line
#   H5  no hold lib on the box: the fallback walk uses the first-line rule
# Run from anywhere: bash tests/hold-parse-shared.bh-6297-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
command -v flock   >/dev/null || { echo "flock missing — skipping"; exit 0; }

# #5239's decision comment, the deciding lines verbatim.
C5239=$'Decision (the operator, 2026-10-12): remove the Cloud code from this ticket.\n- Step 4: the open Cloud PRs #4761 (operator view) and #4792 (go-live) are on HOLD here.'
ISSUE='{"state":"open","labels":[{"name":"ai-build"}],"title":"x","body":""}'

# thread <body>... -> a REST comments array, oldest first, people only.
thread() {
  local i=0 b out='[]'
  for b in "$@"; do
    i=$((i+1))
    out=$(jq -c --arg b "$b" --arg at "2026-10-12T1$i:00:00Z" --argjson id "$((6000+i))" \
          '. + [{id:$id, body:$b, created_at:$at, user:{type:"User"}}]' <<<"$out")
  done
  printf '%s' "$out"
}
classify() { ( . "$DIR/bin/lib/hold.sh"; hold_classify "$ISSUE" "$1" ); }

# ---------- H1/H2/H3 through hold_classify (triage's reader) -----------------
# NOT HELD: a HOLD word anywhere but the start of the first non-blank line.
NOT_HELD=(
  "$C5239"
  "Please HOLD this"
  "> HOLD"
  "- HOLD"
  "HOLD-free comment"
  "HOLDING pattern"
  "hold: lowercase"
  '`HOLD` in a code span'
  "(HOLD) in a comment"
  "RESUME — the HOLD above is withdrawn"
)
for c in "${NOT_HELD[@]}"; do
  v=$(classify "$(thread "$c")"); rc=$?
  [ "$rc" = 0 ] && case "$v" in "clear	"*) true ;; *) false ;; esac && ok \
    || bad "H1: '$c' must be clear, got rc=$rc '$v'"
done
# HELD: the first non-blank line starts with the capital word.
HELD=(
  "HOLD"
  "HOLD — waiting on client"
  "HOLD: not yet"
  $'\n\n  HOLD this until #12 merges'
  $'HOLD: x\r\nmore'
)
for c in "${HELD[@]}"; do
  v=$(classify "$(thread "$c")"); rc=$?
  first=$(printf '%s' "$c" | sed -n '/[^[:space:]]/{p;q}' | tr -d '\r' | sed 's/^[[:space:]]*//')
  [ "$rc" = 1 ] && case "$v" in "held	hold:comment "*"$first"*) true ;; *) false ;; esac && ok \
    || bad "H2: '$c' must be held hold:comment quoting '$first', got rc=$rc '$v'"
done
v=$(classify "$(thread "HOLD: x" "RESUME — go")"); rc=$?
[ "$rc" = 0 ] && case "$v" in "clear	lifted-by-comment "*) true ;; *) false ;; esac && ok \
  || bad "H3: HOLD then RESUME must be clear, got rc=$rc '$v'"
v=$(classify "$(thread "RESUME — go" "HOLD: x")"); rc=$?
[ "$rc" = 1 ] && ok || bad "H3: RESUME then HOLD must be held, got rc=$rc '$v'"
v=$(classify "$(thread "HOLD: x" "$C5239")"); rc=$?
[ "$rc" = 1 ] && ok || bad "H3: HOLD then a prose-only comment stays held, got rc=$rc '$v'"

# ---------- the fastpath fixture ---------------------------------------------
H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/env" "$H/prompts" \
         "$H/builds" "$H/fixture" "$T/fakebin"
export HARNESS="$H"
P=project-5
for s in bin/launch-fastpath.sh bin/jobs-client.sh bin/alert-line.sh bin/fleet-conf.sh \
         bin/lib/ticket-ownership.sh bin/lib/hold-push.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "cannot install $s"; exit 1; }
done
cat > "$H/fleet.conf" <<'CONF'
project-5 example-org/project-5 https://project-5.example - 9 box-ts 192.0.2.9
CONF
export FLEET_CONF="$H/fleet.conf"
printf '%s\n' '  `setsid /root/harness/bin/run-build.sh project-5 <issue-number> TK-<issue-number> > /root/harness/logs/project-5.ts-<issue-number>-build.out 2>&1 &`' \
  > "$H/prompts/$P.md"
printf 'HARNESS_SECRET=fixture-secret\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
cat > "$H/bin/run-build.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HARNESS/launches.log"
SH
chmod +x "$H/bin/run-build.sh"

# gh shim: `gh api -i …` is the REST contract the fastpath and gh_rest read
# (status line, blank line, body); a bare `gh api …` is hold_check's read
# (the body alone). Fixtures are REST-shaped issue objects with the thread in
# fixture/comments-<n>.json.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
ARGS="$*"
case "$ARGS" in *" -i "*|*"api -i"*) HDR=1 ;; *) HDR=0 ;; esac
SEND() { if [ "$HDR" = 1 ]; then printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "$2"; else printf '%s\n' "$2"; fi; exit 0; }
PAGE=$(printf '%s' "$ARGS" | sed -nE 's/.*[?&]page=([0-9]+).*/\1/p'); PAGE="${PAGE:-1}"
case "$ARGS" in
  *"api rate_limit"*) exit 1 ;;
  *"/issues/"*"/comments"*)
    n=$(printf '%s' "$ARGS" | sed -nE 's#.*/issues/([0-9]+)/comments.*#\1#p')
    [ "$PAGE" = 1 ] || SEND 200 '[]'
    SEND 200 "$(cat "$HARNESS/fixture/comments-$n.json" 2>/dev/null || echo '[]')" ;;
  *"/issues/"*)
    n=$(printf '%s' "$ARGS" | sed -nE 's#.*/issues/([0-9]+).*#\1#p')
    [ -f "$HARNESS/fixture/issue-$n.json" ] || { [ "$HDR" = 1 ] && SEND 404 '{"message":"Not Found"}'; exit 1; }
    SEND 200 "$(cat "$HARNESS/fixture/issue-$n.json")" ;;
  *"/issues"*) [ "$PAGE" = 1 ] || SEND 200 '[]'; SEND 200 '[]' ;;
  *"/pulls"*)  [ "$PAGE" = 1 ] || SEND 200 '[]'; SEND 200 "$(cat "$HARNESS/fixture/prs.json")" ;;
  *"api repos/"*) echo 12345 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"
case "$URL" in
  */api/jobs*)  printf '{"jobs":[]}\n200\n' ;;
  */api/queue*) printf '{"queue":[]}\n200\n' ;;
  */api/flags/*|*/api/settings*) printf '{"error":"not found"}\n404\n' ;;
  *)            printf '{"ok":true}\n200\n' ;;
esac
SH
chmod +x "$T/fakebin/curl"
printf '#!/bin/bash\nexec "$@"\n' > "$T/fakebin/setsid"
chmod +x "$T/fakebin/setsid"
export PATH="$T/fakebin:$PATH"

BODY_OK=$'## Scope\nBuild the thing.\n\n## Acceptance tests\n- it works\n'
LAB='[{"name":"ai-build"}]'
LAB_HF='[{"name":"ai-build"},{"name":"hotfix"}]'
mkissue() { # mkissue <n> <labels-json> <comments-json>
  jq -n --argjson n "$1" --argjson lb "$2" --arg b "$BODY_OK" --argjson c "$(jq 'length' <<<"$3")" \
    '{number:$n,state:"open",title:("TK-" + ($n|tostring) + " fixture"),body:$b,labels:$lb,comments:$c}' \
    > "$H/fixture/issue-$1.json"
  printf '%s' "$3" > "$H/fixture/comments-$1.json"
}
reset() {
  scratch_rm "$H/state"; scratch_rm "$H/locks"; scratch_rm "$H/logs"; scratch_rm "$H/builds"
  mkdir -p "$H/state" "$H/locks" "$H/logs" "$H/builds"
  rm -f "$H/launches.log" "$H/fixture"/issue-*.json "$H/fixture"/comments-*.json
  echo '[]' > "$H/fixture/prs.json"
}
run() { OUT=$("$H/bin/launch-fastpath.sh" "$P" "$@" 2>/dev/null); RC=$?; }
reason() { grep -F "FASTPATH-DECLINED $1 ::" "$H/logs/$P.log" 2>/dev/null | tail -1 | sed 's/.*:: //'; }
launched() { grep -q "^project-5 $1 TK-$1\$" "$H/launches.log" 2>/dev/null; }
nalerts() { local n; n=$(grep -c 'fastpath: hotfix' "$H/logs/ALERTS.log" 2>/dev/null); echo "${n:-0}"; }

# ---------- H1/H2/H3 through bin/launch-fastpath.sh --------------------------
reset
mkissue 101 "$LAB" "$(thread "$C5239")"
mkissue 102 "$LAB" "$(thread "Please HOLD this")"
mkissue 103 "$LAB" "$(thread "> HOLD")"
mkissue 104 "$LAB" "$(thread "HOLD-free comment")"
mkissue 105 "$LAB" "$(thread "HOLD — x")"
mkissue 106 "$LAB" "$(thread "HOLD")"
mkissue 107 "$LAB" "$(thread $'\n  HOLD this')"
mkissue 108 "$LAB" "$(thread "HOLD: x" "RESUME — go")"
mkissue 109 "$LAB" "$(thread "RESUME — go" "HOLD: x")"
run 101 102 103 104 105 106 107 108 109
for k in 101 102 103 104; do
  launched "$k" && ok || bad "H1 fastpath: #$k (prose HOLD) must launch, declined '$(reason "$k")'"
done
for k in 105 106 107; do
  [ "$(reason "$k")" = "HOLD in comment" ] && ok || bad "H2 fastpath: #$k must decline 'HOLD in comment', got '$(reason "$k")'"
done
launched 108 && ok || bad "H3 fastpath: HOLD then RESUME must launch, declined '$(reason 108)'"
[ "$(reason 109)" = "HOLD in comment" ] && ok || bad "H3 fastpath: RESUME then HOLD must decline, got '$(reason 109)'"
[ "$RC" = 1 ] && ok || bad "H2 fastpath: a declined key keeps rc 1, got $RC"
[ "$(printf '%s\n' "$OUT" | sort | tr '\n' ' ')" = "105 106 107 109 " ] && ok \
  || bad "H2 fastpath: stdout must be exactly the declined keys, got '$OUT'"
# The bot filter now applies here too: a bot's HOLD line holds nothing.
reset
mkissue 110 "$LAB" '[{"id":1,"body":"HOLD: from a bot","created_at":"2026-10-12T10:00:00Z","user":{"type":"Bot"}}]'
mkissue 111 "$LAB" "$(thread "Taken by: the operator")"
run 110 111
launched 110 && ok || bad "H3 fastpath: a bot's HOLD must not hold (hold_classify's reading), declined '$(reason 110)'"
[ "$(reason 111)" = "human fix in progress" ] && ok || bad "H3 fastpath: a human-fix marker must decline, got '$(reason 111)'"

# ---------- H3-agree: the four readers give one class -------------------------
reset
AGREE=( "$C5239" "Please HOLD this" "HOLD — x" "HOLD" $'\n  HOLD this' )
i=200
for c in "${AGREE[@]}" "H3A" "H3B"; do
  i=$((i+1))
  case "$c" in
    H3A) th=$(thread "HOLD: x" "RESUME — go") ;;
    H3B) th=$(thread "RESUME — go" "HOLD: x") ;;
    *)   th=$(thread "$c") ;;
  esac
  mkissue "$i" "$LAB" "$th"
  ij=$(cat "$H/fixture/issue-$i.json")
  a=$( ( . "$DIR/bin/lib/hold.sh"; hold_classify "$ij" "$th" ) | cut -f1)
  b=$( ( . "$H/bin/lib/ticket-ownership.sh"; to_hold_verdict example-org/project-5 "$i" ) | cut -f1)
  cc=$( ( . "$H/bin/lib/hold-push.sh"; hold_push_verdict "$P" "example-org/project-5#$i" ticket/ts-$i ) | cut -f1)
  run "$i"
  if launched "$i"; then d=clear; else d=held; fi
  [ -n "$a" ] && [ "$a" = "$b" ] && [ "$a" = "$cc" ] && [ "$a" = "$d" ] && ok \
    || bad "H3-agree #$i: hold_classify=$a to_hold_verdict=$b hold_push_verdict=$cc fastpath=$d"
done

# ---------- H4 the hotfix HOLD alert -----------------------------------------
reset
mkissue 301 "$LAB_HF" "$(thread "HOLD: wait")"
run 301; RC1=$RC; OUT1=$OUT
[ "$(nalerts)" = 1 ] && ok || bad "H4: a held hotfix must write one ALERTS line, got $(nalerts): $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep 'fastpath: hotfix' "$H/logs/ALERTS.log" 2>/dev/null | grep -q 'HOLD: wait' && ok \
  || bad "H4: the ALERTS line must quote the HOLD line: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep 'fastpath: hotfix' "$H/logs/ALERTS.log" 2>/dev/null | grep -q 'TK-301' && ok \
  || bad "H4: the ALERTS line must name the key"
run 301
[ "$(nalerts)" = 1 ] && ok || bad "H4: a second run must not write a second line, got $(nalerts)"
[ "$RC1" = 1 ] && [ "$OUT1" = 301 ] && [ "$RC" = 1 ] && [ "$OUT" = 301 ] && ok \
  || bad "H4: the alert must not change rc/stdout: rc1=$RC1 out1='$OUT1' rc2=$RC out2='$OUT'"
[ "$(reason 301)" = "HOLD in comment" ] && ok || bad "H4: the decline reason is unchanged, got '$(reason 301)'"
# no hotfix label: no alert, same rc and stdout
reset
mkissue 302 "$LAB" "$(thread "HOLD: wait")"
run 302
[ "$(nalerts)" = 0 ] && ok || bad "H4: no hotfix label must write no alert, got $(nalerts)"
[ "$RC" = 1 ] && [ "$OUT" = 302 ] && ok || bad "H4: rc/stdout without the label: rc=$RC out='$OUT'"
# hotfix declined for an open PR, not a HOLD: no alert
reset
mkissue 303 "$LAB_HF" "$(thread "looks good")"
echo '[{"number":9303,"title":"TK-303 the fix","body":"","head":{"ref":"ticket/TK-303"},"draft":false}]' > "$H/fixture/prs.json"
run 303
starts() { case "$1" in "$2"*) return 0 ;; *) return 1 ;; esac; }
starts "$(reason 303)" "open PR #9303" && ok || bad "H4: fixture check, #303 must decline on the open PR, got '$(reason 303)'"
[ "$(nalerts)" = 0 ] && ok || bad "H4: a non-HOLD decline must write no alert, got $(nalerts)"
# hotfix held by a comment but declined EARLIER (condition 9, the issue is
# closed): the HOLD did not decide this decline, so no alert. TEST-CHANGE
# (BH-7117): this fixture used condition 11 (no spec body), and BH-7117 exempts
# a hotfix from condition 11, so a hotfix can no longer decline there.
reset
mkissue 305 "$LAB_HF" "$(thread "HOLD: wait")"
jq '.state = "closed"' "$H/fixture/issue-305.json" > "$T/i305" && mv "$T/i305" "$H/fixture/issue-305.json"
run 305
[ "$(reason 305)" = "issue not open" ] && ok || bad "H4: fixture check, #305 must decline as not open, got '$(reason 305)'"
[ "$(nalerts)" = 0 ] && ok || bad "H4: a decline the HOLD did not decide must write no alert, got $(nalerts)"
# hotfix launched: no alert
reset
mkissue 304 "$LAB_HF" "$(thread "$C5239")"
run 304
launched 304 && ok || bad "H4: a prose-only hotfix must launch, declined '$(reason 304)'"
[ "$(nalerts)" = 0 ] && ok || bad "H4: a launch must write no alert, got $(nalerts)"
# a new HOLD line on the same ticket alerts again (dedupe is per line)
reset
mkissue 301 "$LAB_HF" "$(thread "HOLD: wait")"
run 301
mkissue 301 "$LAB_HF" "$(thread "HOLD: wait" "HOLD: still waiting")"
run 301
[ "$(nalerts)" = 2 ] && ok || bad "H4: a new HOLD line must alert again, got $(nalerts)"

# ---------- H5 no hold lib: the fallback walk reads the first line ------------
reset
mv "$H/bin/lib/hold.sh" "$T/hold-away.sh"
mkissue 501 "$LAB" "$(thread "$C5239")"
mkissue 502 "$LAB" "$(thread "HOLD: x")"
run 501 502
launched 501 && ok || bad "H5: without the lib a prose HOLD must still launch, declined '$(reason 501)'"
[ "$(reason 502)" = "HOLD in comment" ] && ok || bad "H5: without the lib a first-line HOLD declines, got '$(reason 502)'"
mv "$T/hold-away.sh" "$H/bin/lib/hold.sh"

echo "hold-parse-shared: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
