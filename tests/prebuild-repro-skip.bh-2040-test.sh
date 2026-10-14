#!/bin/bash
# tests/prebuild-repro-skip.bh-2040-test.sh — the repro gate's thread fetch and
# `[no-repro]` skip classifier (BH-2040, order 2 of #2004).
#
# WHAT THIS SUITE PINS:
#   A  — bin/prebuild-repro.sh run for real in a scratch HARNESS with the REAL
#        "$DIR/bin/lib/prebuild-repro/thread.sh" and
#        "$DIR/bin/lib/prebuild-repro/classify.sh", stubbed curl/gh underneath.
#        drive.sh and stop.sh are canned (no spend, no post).
#   F  — pr_fetch_thread alone: normalization per source, rc 1 on every read
#        failure, rc 3 when the project is not wired, truncation past 100.
#   R  — the operator's RESUME requirement: the harness's own comments carry
#        `harness: true`, so pr_ledger_key does not move on them.
#   N  — classifier negatives that must never skip.
#   M  — D1 mutants of classify.sh that the A cases must catch.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prebuild-repro-skip.bh-2040-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

REG="$T/lanes.json"
bash "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 \
  || bad "setup: bin/lanes-build.sh --to could not compose the registry"
export LANE_REGISTRY="$REG" LANE_GATE_NOW=""
export HARNESS_PR_AUTHORS="operator app/cromford" HARNESS_SELF_APPS="cromford"
TOKEN="tok-fixture-SECRET-2040"; export TOKEN
unset REPRO_GATE REPRO_GATE_MAX_USD GH_FAIL CURL_FAIL 2>/dev/null

# mkh <name> — a scratch HARNESS: shipped runner, lib and the two stages under
# test; canned drive/stop; fleet-conf, token, gh and curl stubs. Fixtures are
# read from $FX, which each case points at its own directory.
mkh() {
  local h="$T/$1"
  mkdir -p "$h/bin/lib" "$h/logs" "$h/state" "$h/flags" "$h/env" "$h/fakebin"
  cp -p "$DIR/bin/prebuild-repro.sh" "$DIR/bin/kind-gate.sh" "$h/bin/"
  cp -p "$DIR/bin/lib/prebuild-repro.sh" "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/gh-rest.sh" \
        "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/harness-self.sh" "$h/bin/lib/"
  cp -rp "$DIR/bin/lib/prebuild-repro" "$h/bin/lib/"
  cp -p "$DIR/bin/lib/prebuild-repro/thread.sh" "$DIR/bin/lib/prebuild-repro/classify.sh" "$h/bin/lib/prebuild-repro/"
  printf '%s\n' 'pr_drive() { touch "$HARNESS/drove"; printf "REPRODUCED\tx\n"; }' > "$h/bin/lib/prebuild-repro/drive.sh"
  printf '%s\n' 'pr_stop() { touch "$HARNESS/stopped"; return 0; }' > "$h/bin/lib/prebuild-repro/stop.sh"
  printf '#!/bin/bash\necho "$TOKEN"\n' > "$h/bin/internal-token-for.sh"
  cat > "$h/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1:$2" in
  ghp:repo) echo example-org/x ;; ghp:board_prefix|ghp:prod) echo - ;;
  app:prod|project-3:prod) echo https://app.example ;; app:board_prefix|project-3:board_prefix) echo /api/board ;;
  app:repo|project-3:repo) echo acme/app ;;
  *) exit 1 ;;
esac
SH
  # gh: only what gh_rest sends (`api -i -X GET <path> -F k=v ...`).
  cat > "$h/fakebin/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$FX/gh.log"
p=""; page=1
while [ $# -gt 0 ]; do
  case "$1" in
    api|-i) ;;
    -X|-H) shift ;;
    -F|-f) case "$2" in page=*) page="${2#page=}" ;; esac; shift ;;
    *) [ -z "$p" ] && p="$1" ;;
  esac
  shift
done
case "${GH_FAIL:-}" in
  1)  printf 'HTTP/2 502 Bad Gateway\r\n\r\n{"message":"boom"}'; exit 1 ;;
  75) printf 'HTTP/2 403 Forbidden\r\n\r\n{"message":"API rate limit exceeded"}'; exit 1 ;;
  c)  case "$p" in */comments) printf 'HTTP/2 502 Bad Gateway\r\n\r\n{}'; exit 1 ;; esac ;;
  p2) case "$p:$page" in */comments:2) printf 'HTTP/2 502 Bad Gateway\r\n\r\n{}'; exit 1 ;; esac ;;
esac
case "$p" in
  */comments) f="$FX/comments-p$page.json"; [ -f "$f" ] || { printf 'HTTP/2 200 OK\r\n\r\n[]'; exit 0; } ;;
  */issues/*) f="$FX/issue.json" ;;
  *) printf 'HTTP/2 404 Not Found\r\n\r\n{}'; exit 1 ;;
esac
printf 'HTTP/2 200 OK\r\n\r\n'; cat "$f"
SH
  cat > "$h/fakebin/curl" <<'SH'
#!/bin/bash
url=""; for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
echo "GET $url" >> "$FX/curl.log"
[ "${CURL_FAIL:-}" = 1 ] && exit 7
cat "$FX/app-ticket.json"
SH
  chmod +x "$h/bin/"*.sh "$h/fakebin/"*
  printf '%s' "$h"
}
BUG='{"title":"Totals are wrong","labels":[{"name":"bug"}],"body":""}'
# fx <name> — a fresh fixture dir, exported as FX.
fx() { FX="$T/fx-$1"; mkdir -p "$FX"; export FX; }
# ghc <id> <login> <association> <type> <created> <body> — one REST issue comment.
ghc() { jq -nc --argjson id "$1" --arg l "$2" --arg a "$3" --arg t "$4" --arg c "$5" --arg b "$6" \
  '{id:$id, user:{login:$l, type:$t}, author_association:$a, created_at:$c, body:$b}'; }
# ghissue <n comments> <association> <body> — the issue object.
ghissue() { jq -nc --argjson n "$1" --arg a "$2" --arg b "$3" \
  '{number:7, title:"Totals are wrong", body:$b, comments:$n, author_association:$a, user:{login:"client1", type:"User"}, labels:[{name:"bug"}]}' > "$FX/issue.json"; }
# ghcomments <page> <comment json>... — one page of comments.
ghcomments() { local p="$1"; shift; printf '%s\n' "$@" | jq -sc . > "$FX/comments-p$p.json"; }
# appc <id> <created> <isInternal> <author name> <body> — one in-app comment.
appc() { jq -nc --arg id "$1" --arg c "$2" --argjson i "$3" --arg n "$4" --arg b "$5" \
  '{id:$id, createdAt:$c, isInternal:$i, author:{name:$n, userId:("u_" + $n)}, body:$b}'; }
# appticket <reporter userId> <body> <comment json>... — the in-app ticket GET.
appticket() { local r="$1" b="$2"; shift 2
  printf '%s\n' "$@" | jq -sc --arg r "$r" --arg b "$b" \
    '{ticket:{id:"42", number:7, title:"Totals are wrong", description:$b, reporter:{userId:$r}, reporterId:$r}, comments:.}' > "$FX/app-ticket.json"; }

H=$(mkh main)
# run <project> <key> [meta] — the runner as run-build calls it; sets B and RC.
N=0
run() {
  N=$((N+1)); B="$T/b$N"; mkdir -p "$B"; rm -f "$H/drove" "$H/stopped"
  printf '%s\n' "${3:-$BUG}" > "$B/ticket-meta.json"
  PATH="$H/fakebin:$PATH" HARNESS="$H" bash "$H/bin/prebuild-repro.sh" "$1" 7 "$2" "$B" > "$B/runner.out" 2>&1; RC=$?
}
rline() { sed -n "s/^$1: //p" "$B/prebuild-repro.txt" 2>/dev/null; }
drove() { [ -e "$H/drove" ]; }
# is_skip <case> <reason> — the record says skip <reason>, and nothing drove.
is_skip() {
  if [ "$(rline REPRO_GATE)" = skip ] && [ "$(rline REPRO_REASON)" = "$2" ] && ! drove && [ "$RC" = 0 ]; then ok
  else bad "$1: wanted skip $2, got '$(rline REPRO_GATE) $(rline REPRO_REASON) $(rline REPRO_EVIDENCE)' rc=$RC drove=$(drove && echo y || echo n)"; fi
}
# is_run <case> — not skipped: the drive ran and recorded reproduced.
is_run() {
  if [ "$(rline REPRO_GATE)" = reproduced ] && drove; then ok
  else bad "$1: wanted the drive, got '$(rline REPRO_GATE) $(rline REPRO_REASON) $(rline REPRO_EVIDENCE)' drove=$(drove && echo y || echo n)"; fi
}
L() { ( export HARNESS="$H" PATH="$H/fakebin:$PATH"; . "$H/bin/lib/prebuild-repro.sh" && "$@" ); }

T0='2026-09-20T10:00:00Z'; T1='2026-09-21T10:00:00Z'; T2='2026-09-22T10:00:00Z'

# ═══════════════════════════════════════════════════════════════════════════
# A — through the runner
# ═══════════════════════════════════════════════════════════════════════════
# A1 — in-app internal comment `[no-repro]`.
fx a1; appticket u_client "Totals are wrong on the invoice page" \
  "$(appc c1 "$T0" false client1 'I see it every day')" "$(appc c2 "$T1" true the operator '[no-repro]')"
: > "$H/logs/app.log"
run app APP-7
is_skip A1 marker
[ "$(rline REPRO_EVIDENCE)" = - ] && ok || bad "A1: bare marker evidence is '$(rline REPRO_EVIDENCE)', not -"
[ "$(grep -c '^repro=skip reason=marker key=APP-7$' "$H/logs/app.log")" = 1 ] && ok || bad "A1: not exactly one skip log line in logs/app.log"
grep -q 'GET https://app.example/api/board/tickets/7' "$FX/curl.log" 2>/dev/null && ok || bad "A1: the in-app ticket read was not \$PROD\$PREFIX/tickets/<id>: $(cat "$FX/curl.log" 2>/dev/null)"
grep -rq "$TOKEN" "$H/logs" "$B" && bad "A1: the token reached a log or the build dir" || ok

# A1c — `[No-Repro]` from the same principal.
fx a1c; appticket u_client "x" "$(appc c2 "$T1" true the operator '  [No-Repro]')"
run app APP-7; is_skip A1c marker

# A2 — GitHub MEMBER `[no-repro: flaky only on staging]`.
fx a2; ghissue 1 NONE "steps"
ghcomments 1 "$(ghc 11 teammate MEMBER User "$T1" '[no-repro: flaky only on staging]')"
run ghp BH-7; is_skip A2 marker
case "$(rline REPRO_EVIDENCE)" in *"flaky only on staging"*) ok ;; *) bad "A2: evidence '$(rline REPRO_EVIDENCE)'" ;; esac
grep -q 'repos/example-org/x/issues/7$' "$FX/gh.log" 2>/dev/null && grep -q 'repos/example-org/x/issues/7/comments' "$FX/gh.log" \
  && ok || bad "A2: the gh reads were not issue + comments on example-org/x#7: $(cat "$FX/gh.log" 2>/dev/null)"

# A3 — a client (NONE) `[no-repro]` does not skip; the in-app client does not either.
fx a3; ghissue 1 NONE "steps"; ghcomments 1 "$(ghc 12 client1 NONE User "$T1" '[no-repro]')"
run ghp BH-7; is_run A3
fx a3app; appticket u_client "x" "$(appc c3 "$T1" false 'Client Person' '[no-repro]')"
run app APP-7; is_run A3-app
# A3b — CONTRIBUTOR is not a principal (the ticket's list).
fx a3b; ghissue 1 NONE "steps"; ghcomments 1 "$(ghc 13 someone CONTRIBUTOR User "$T1" '[no-repro]')"
run ghp BH-7; is_run A3b

# A4 — a body starting `[no-repro]`: system reporter skips, client reporter does not.
fx a4; appticket system "$(printf '[no-repro]\nsteps: open the invoice')" "$(appc c1 "$T0" false client1 'ok')"
run app APP-7; is_skip A4 marker
fx a4b; appticket u_client "$(printf '[no-repro]\nsteps: open the invoice')" "$(appc c1 "$T0" false client1 'ok')"
run app APP-7; is_run A4b

# A5 — the system actor's cause-proven, evidence quoted; A5b caps it at 300.
fx a5; appticket u_client "x" "$(appc c5 "$T1" false 'project-3 AI Harness' '[no-repro: cause-proven — MessageLog rows all not_configured]')"
run project-3 project-3-7; is_skip A5 cause-proven
[ "$(rline REPRO_EVIDENCE)" = "MessageLog rows all not_configured" ] && ok || bad "A5: evidence '$(rline REPRO_EVIDENCE)'"
fx a5b; appticket u_client "x" "$(appc c5 "$T1" true the operator "[no-repro: cause-proven — $(head -c 500 /dev/zero | tr '\0' q)]")"
run app APP-7; is_skip A5b cause-proven
[ "$(rline REPRO_EVIDENCE | tr -d '\n' | wc -c)" = 300 ] && ok || bad "A5b: evidence is $(rline REPRO_EVIDENCE | tr -d '\n' | wc -c) chars, not 300"

# A8 — principal comments that must not skip.
i=0
for body in 'The rule is that a principal writes `[no-repro]` on its own line.' \
            "$(printf 'like this:\n```\n[no-repro]\n```\nthanks')" \
            '> [no-repro]' '[no-reproduce]' '[norepro]' 'cause-proven — rows empty' \
            'see [no-repro] above' '[no-repro: never closed'; do
  i=$((i+1)); fx "a8-$i"; appticket u_client "x" "$(appc c8 "$T1" true the operator "$body")"
  run app APP-7; is_run "A8.$i ($(head -1 <<<"$body"))"
done

# A9 — a later client comment does not supersede the principal's marker.
fx a9; ghissue 2 NONE "steps"
ghcomments 1 "$(ghc 21 teammate MEMBER User "$T1" '[no-repro]')" "$(ghc 22 client1 NONE User "$T2" 'please do reproduce it')"
run ghp BH-7; is_skip A9 marker

# A12 — labelled bug is evaluated; unlabelled is not-bug and the issue is never read.
fx a12; ghissue 0 NONE "steps"
run ghp BH-7
[ "$(rline REPRO_REASON)" != not-bug ] && [ -s "$FX/gh.log" ] && ok || bad "A12: a bug-labelled issue was not evaluated: $(rline REPRO_GATE) $(rline REPRO_REASON)"
fx a12b; ghissue 0 NONE "steps"
run ghp BH-7 '{"title":"Add a CSV export","labels":[],"body":""}'
[ "$(rline REPRO_REASON)" = not-bug ] && [ ! -s "$FX/gh.log" ] && ok || bad "A12: unlabelled gave '$(rline REPRO_REASON)', gh.log '$(cat "$FX/gh.log" 2>/dev/null)'"

# TR — 150 comments, no marker: run thread-truncated, and the runner drives.
fx tr; ghissue 150 NONE "steps"
ghcomments 1 $(for k in $(seq 1 100); do ghc "$k" client1 NONE User "2026-09-01T00:00:$(printf %02d $((k % 60)))Z" "c$k"; done)
ghcomments 2 $(for k in $(seq 101 150); do ghc "$k" client1 NONE User "2026-09-02T00:00:$(printf %02d $((k % 60)))Z" "c$k"; done)
TH_TR=$(L pr_fetch_thread ghp 7 BH-7)
[ "$(L pr_skip_classify "$TH_TR")" = "$(printf 'run\tthread-truncated\t-')" ] && ok || bad "TR: classify gave '$(L pr_skip_classify "$TH_TR")'"
run ghp BH-7; is_run TR

# ═══════════════════════════════════════════════════════════════════════════
# F — the fetcher alone
# ═══════════════════════════════════════════════════════════════════════════
fx f1; ghissue 2 OWNER "the body"
printf '%s\n' "$(ghc 31 teammate MEMBER User "$T0" 'a')" '{"id":32,"user":{"login":"cromford[bot]","type":"Bot"},"author_association":"NONE","created_at":"2026-09-21T10:00:00Z","body":null}' \
  | jq -sc . > "$FX/comments-p1.json"
out=$(L pr_fetch_thread ghp 7 BH-7); rc=$?
[ "$rc" = 0 ] && ok || bad "F1: rc $rc"
exp='{"source":"gh","truncated":false,"body":"the body","body_principal":true,"comments":[{"id":"31","createdAt":"2026-09-20T10:00:00Z","body":"a","author":"teammate","principal":true,"harness":false},{"id":"32","createdAt":"2026-09-21T10:00:00Z","body":"","author":"cromford[bot]","principal":true,"harness":true}]}'
[ "$(printf '%s' "$out" | jq -cS .)" = "$(printf '%s' "$exp" | jq -cS .)" ] && ok || bad "F1: normalized gh thread is $out"
# The key is also read off the issue number when ticket-id is not numeric.
out=$(L pr_fetch_thread ghp BH-7 BH-7); rc=$?
[ "$rc" = 0 ] && [ -n "$out" ] && ok || bad "F1: a key-form ticket id gave rc $rc"

for m in 1 75 c; do
  out=$(GH_FAIL=$m L pr_fetch_thread ghp 7 BH-7); rc=$?
  [ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "F2: GH_FAIL=$m gave rc $rc and '$out'"
done
fx f2b; printf '"not an object"' > "$FX/issue.json"
out=$(L pr_fetch_thread ghp 7 BH-7); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "F2: a non-object issue gave rc $rc"

FX="$T/fx-tr"; export FX
out=$(L pr_fetch_thread ghp 7 BH-7); rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.truncated')" = true ] && ok || bad "F3: 150 comments gave rc $rc truncated=$(printf '%s' "$out" | jq -r '.truncated' 2>/dev/null)"
printf '%s' "$out" | jq -e 'any(.comments[]; .id == "150")' >/dev/null 2>&1 && ok || bad "F3: the newest comment (page 2) is missing"
out=$(GH_FAIL=p2 L pr_fetch_thread ghp 7 BH-7); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "F3: a failed newest-page read gave rc $rc"

fx f4; appticket system "the body" "$(appc c1 "$T0" false 'Client Person' 'hi')" "$(appc c2 "$T1" true the operator 'ok')"
out=$(L pr_fetch_thread app 7 APP-7); rc=$?
exp='{"source":"app","truncated":false,"body":"the body","body_principal":true,"comments":[{"id":"c1","createdAt":"2026-09-20T10:00:00Z","body":"hi","author":"Client Person","principal":false,"harness":false},{"id":"c2","createdAt":"2026-09-21T10:00:00Z","body":"ok","author":"the operator","principal":true,"harness":false}]}'
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -cS .)" = "$(printf '%s' "$exp" | jq -cS .)" ] && ok || bad "F4: rc $rc, normalized app thread is $out"

out=$(CURL_FAIL=1 L pr_fetch_thread app 7 APP-7); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "F5: curl failure gave rc $rc"
fx f5; printf '{"error":"nope"}' > "$FX/app-ticket.json"
out=$(L pr_fetch_thread app 7 APP-7); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "F5: an error body gave rc $rc and '$out'"

# F6 — through the runner, a failed read is cannot-drive thread-unreadable even
# with a principal marker in the fixture.
fx f6; ghissue 1 NONE "steps"; ghcomments 1 "$(ghc 11 teammate MEMBER User "$T1" '[no-repro]')"
GH_FAIL=1; export GH_FAIL; run ghp BH-7; unset GH_FAIL
[ "$(rline REPRO_GATE)" = cannot-drive ] && [ "$(rline REPRO_REASON)" = thread-unreadable ] && ! drove && ok \
  || bad "F6: a failed read recorded '$(rline REPRO_GATE) $(rline REPRO_REASON)'"
fx f6app; appticket system "[no-repro]" "$(appc c2 "$T1" true the operator '[no-repro]')"
CURL_FAIL=1; export CURL_FAIL; run app APP-7; unset CURL_FAIL
[ "$(rline REPRO_GATE)" = cannot-drive ] && [ "$(rline REPRO_REASON)" = thread-unreadable ] && ok \
  || bad "F6: a failed in-app read recorded '$(rline REPRO_GATE) $(rline REPRO_REASON)'"

# F7 — not wired.
out=$(L pr_fetch_thread nowhere 7 NW-7); rc=$?
[ "$rc" = 3 ] && [ -z "$out" ] && ok || bad "F7: an unknown project gave rc $rc"

# ═══════════════════════════════════════════════════════════════════════════
# R — `harness: true` keeps our own comments out of the ledger key
# ═══════════════════════════════════════════════════════════════════════════
fx r; ghissue 1 NONE "steps"; C0=$(ghc 41 client1 NONE User "$T0" 'totals are off')
ghcomments 1 "$C0"; K0=$(L pr_ledger_key ghp BH-7 "$(L pr_fetch_thread ghp 7 BH-7)")
grep -qE '^ghp/BH-7/[0-9a-f]{64}$' <<<"$K0" && ok || bad "R: base key '$K0'"
key_with() { ghissue 2 NONE "steps"; ghcomments 1 "$C0" "$1"; L pr_ledger_key ghp BH-7 "$(L pr_fetch_thread ghp 7 BH-7)"; }
[ "$(key_with "$(ghc 42 'cromford[bot]' NONE Bot "$T1" 'We could not see it. <!-- harness:repro-stop BH-7 -->')")" = "$K0" ] \
  && ok || bad "R1: the bot's stop comment moved the key"
[ "$(key_with "$(ghc 43 client1 NONE User "$T1" '> We could not see it. <!-- harness:repro-stop BH-7 --> but I can')")" != "$K0" ] \
  && ok || bad "R2: a client quoting the stop marker did not move the key"
[ "$(key_with "$(ghc 44 operator CONTRIBUTOR User "$T1" 'We could not see it. <!-- harness:repro-stop BH-7 -->')")" = "$K0" ] \
  && ok || bad "R3: a PAT-posted stop comment moved the key"
[ "$(key_with "$(ghc 45 operator CONTRIBUTOR User "$T1" 'I can see it too')")" != "$K0" ] \
  && ok || bad "R3: a plain operator comment did not move the key"
[ "$(L pr_fetch_thread ghp 7 BH-7 | jq -c '[.comments[].harness]')" = '[false,false]' ] && ok || bad "R3: harness flags on a plain operator comment"
# R4 — in-app: an internal HUMAN comment (new repro steps) moves the key; the
# internal stop comment does not; a client quoting the marker does.
fx r4; A0=$(appc c1 "$T0" false 'Client Person' 'totals are off')
appticket u_client "steps" "$A0"; KA=$(L pr_ledger_key app APP-7 "$(L pr_fetch_thread app 7 APP-7)")
grep -qE '^app/APP-7/[0-9a-f]{64}$' <<<"$KA" && ok || bad "R4: base key '$KA'"
akey_with() { appticket u_client "steps" "$A0" "$1"; L pr_ledger_key app APP-7 "$(L pr_fetch_thread app 7 APP-7)"; }
[ "$(akey_with "$(appc c2 "$T1" true the operator 'We could not see it. <!-- harness:repro-stop APP-7 -->')")" = "$KA" ] \
  && ok || bad "R4: the internal stop comment moved the key"
[ "$(akey_with "$(appc c3 "$T1" true the operator 'Use the CPA role, open /clients/abc, click Export')")" != "$KA" ] \
  && ok || bad "R4: an internal human comment did not move the key"
[ "$(L pr_fetch_thread app 7 APP-7 | jq -c '[.comments[] | [.principal, .harness]]')" = '[[false,false],[true,false]]' ] \
  && ok || bad "R4: flags on an internal human comment"
[ "$(akey_with "$(appc c4 "$T1" false 'Client Person' '> We could not see it. <!-- harness:repro-stop APP-7 --> but I can')")" != "$KA" ] \
  && ok || bad "R4: a client quoting the stop marker did not move the key"

# ═══════════════════════════════════════════════════════════════════════════
# N — the classifier on its own (bad input, tabs, order)
# ═══════════════════════════════════════════════════════════════════════════
C() { L pr_skip_classify "$1"; }
RUN=$(printf 'run\t-\t-')
[ "$(C '{}')" = "$RUN" ] && ok || bad "N1: '{}' gave '$(C '{}')'"
[ "$(C 'not json {')" = "$RUN" ] && ok || bad "N1: bad JSON gave '$(C 'not json {')'"
[ "$(C '')" = "$RUN" ] && ok || bad "N1: empty input gave '$(C '')'"
[ "$(C '[1,2]')" = "$RUN" ] && ok || bad "N1: an array gave '$(C '[1,2]')'"
th=$(jq -nc '{body:"", body_principal:false, comments:[{id:"1",createdAt:"t1",principal:true,body:"[no-repro: a\tb]"}]}')
[ "$(C "$th")" = "$(printf 'skip\tmarker\ta b')" ] && ok || bad "N2: a tab in evidence was not flattened: '$(C "$th")'"
th=$(jq -nc '{body:"", body_principal:false, comments:[{id:"2",createdAt:"t2",principal:true,body:"[no-repro: newer]"},{id:"1",createdAt:"t1",principal:true,body:"[no-repro: older]"}]}')
[ "$(C "$th")" = "$(printf 'skip\tmarker\tnewer')" ] && ok || bad "N3: the newest principal marker did not win: '$(C "$th")'"
th=$(jq -nc '{body:"[no-repro: body]", body_principal:true, comments:[{id:"1",createdAt:"t1",principal:false,body:"[no-repro: client]"}]}')
[ "$(C "$th")" = "$(printf 'skip\tmarker\tbody')" ] && ok || bad "N4: body marker gave '$(C "$th")'"

# ═══════════════════════════════════════════════════════════════════════════
# M — D1 mutants: each must turn its target case red.
# ═══════════════════════════════════════════════════════════════════════════
REAL_CLASSIFY="$DIR/bin/lib/prebuild-repro/classify.sh"
sed 's/ and \.principal == true//' "$REAL_CLASSIFY" > "$H/bin/lib/prebuild-repro/classify.sh"
cmp -s "$REAL_CLASSIFY" "$H/bin/lib/prebuild-repro/classify.sh" && bad "M1: the sed found no principal filter to remove"
FX="$T/fx-a3"; export FX; run ghp BH-7
[ "$(rline REPRO_GATE)" = skip ] && ok || bad "M1: with the principal filter removed, A3 still did not skip — A3 is not pinning it"
printf '%s\n' "pr_skip_classify() { printf 'run\t-\t-\n'; }" > "$H/bin/lib/prebuild-repro/classify.sh"
FX="$T/fx-a1"; export FX; run app APP-7
[ "$(rline REPRO_GATE)" != skip ] && ok || bad "M2: an always-run classifier still skipped A1"
cp -p "$REAL_CLASSIFY" "$H/bin/lib/prebuild-repro/classify.sh"
run app APP-7; is_skip "M: restored classifier, A1" marker

echo "prebuild-repro-skip (BH-2040): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
