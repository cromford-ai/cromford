#!/bin/bash
# tests/prebuild-repro-stop.bh-2043-test.sh — the repro gate's stop stage
# (BH-2043, BH-2004.4): a bug we could not see gets ONE board comment, the
# ticket goes to the client, and the build stops. docs/repro-gate/stop.md.
#
# WHAT THIS SUITE PINS:
#   C1-C6 — bin/prebuild-repro.sh run for real in a scratch HARNESS with the
#        real lane-gate, kind-gate, contract lib and the SHIPPED stop.sh. Only
#        the thread and drive stages are stubbed, plus the network edges:
#        jobs-client.sh (a file-backed ledger), fleet-conf.sh,
#        internal-token-for.sh, and curl/gh on PATH.
#   C1b/C3b — the `# >>> prebuild repro (BH-2004)` block lifted from the
#        flattened pipeline and executed against the same harness shape.
#   T-* — comment text, the size cap, failure classification, the turn flip,
#        the negatives, a side-effect-free source and no token in any log.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prebuild-repro-stop.bh-2043-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

REG="$T/lanes.json"
bash "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 \
  || bad "setup: bin/lanes-build.sh --to could not compose the registry"
export LANE_REGISTRY="$REG"
export LANE_GATE_NOW=""
TOKEN="tok-fixture-SECRET-5150"
export TOKEN
BUGMETA='{"title":"Totals are wrong","labels":[{"name":"bug"}],"body":""}'

# mkh <name> — a scratch HARNESS: the shipped runner, contract lib, stages,
# lane gate, kind gate and gh-rest lib; stubbed thread/drive stages; stubbed
# network edges. Every edge appends to $h/order.log so ordering is checkable.
mkh() {
  local h="$T/$1"
  mkdir -p "$h/bin/lib" "$h/logs" "$h/state" "$h/flags" "$h/fakebin"
  cp -p "$DIR/bin/prebuild-repro.sh" "$DIR/bin/kind-gate.sh" "$h/bin/"
  cp -p "$DIR/bin/lib/prebuild-repro.sh" "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/gh-rest.sh" "$h/bin/lib/"
  cp -rp "$DIR/bin/lib/prebuild-repro" "$h/bin/lib/"
  # shellcheck disable=SC2016
  printf '%s\n' 'pr_fetch_thread() { printf "%s" "$THREAD_JSON"; }' > "$h/bin/lib/prebuild-repro/thread.sh"
  # shellcheck disable=SC2016
  cat > "$h/bin/lib/prebuild-repro/drive.sh" <<'SH'
pr_drive() {
  if [ "${NO_MD:-0}" != 1 ]; then
    printf 'REPRO_ROLE: %s\nREPRO_URL: %s\nREPRO_STEPS: %s\nREPRO_OBSERVED: %s\n' \
      "${ROLE:-account manager}" "https://app.example/clients/77" "${STEPS:-opened the client, read the totals row}" \
      "${OBSERVED:-Totals row read 1,240.00, matching the three invoices}" > "$3/prebuild-repro.md"
  fi
  printf '%s\tnothing-wrong\n' "${VERDICT:-NOT_REPRODUCED}"
}
SH
  cat > "$h/bin/jobs-client.sh" <<SH
#!/bin/bash
# bin/lib/lane-gate.sh sources the real client as a library: be inert there.
[ "\${BASH_SOURCE[0]}" != "\$0" ] && return 0
H="$h"
echo "ledger \$*" >> "\$H/order.log"
[ "\${LEDGER_DOWN:-0}" = 1 ] && exit 1
[ "\${LEDGER_GET_DOWN:-0}" = 1 ] && [ "\$1" = ledger-get ] && exit 1
f="\$H/ledger/\$(printf '%s' "\$2/\$3" | sha256sum | cut -c1-16)"
case "\$1" in
  ledger-get) [ -f "\$f" ] || { echo; exit 2; }; cat "\$f"; echo; exit 0 ;;
  ledger-put)
    printf 'put %s %s argc=%s\n' "\$3" "\$4" "\$#" >> "\$H/ledger.puts"
    [ "\${LEDGER_PUT_DOWN:-0}" = 1 ] && exit 1
    [ -n "\${LEDGER_PUT_FAIL_STATUS:-}" ] && [ "\$4" = "\$LEDGER_PUT_FAIL_STATUS" ] && exit 1
    mkdir -p "\$H/ledger"; printf '%s' "\$4" > "\$f"; exit 0 ;;
esac
exit 1
SH
  cat > "$h/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "${BOARD:-app}:$2" in
  app:prod) echo https://app.example ;; app:board_prefix) echo /api/board ;; app:repo) echo acme/app ;;
  gh:prod) echo - ;; gh:board_prefix) echo - ;; gh:repo) echo acme/widgets ;;
  *) exit 1 ;;
esac
SH
  printf '#!/bin/bash\necho "$TOKEN"\n' > "$h/bin/internal-token-for.sh"
  printf '#!/bin/bash\ntouch "%s/agent-called"\n' "$h" > "$h/bin/agent-call.sh"
  cat > "$h/fakebin/curl" <<SH
#!/bin/bash
H="$h"
url=""; body=""
while [ \$# -gt 0 ]; do
  case "\$1" in -d) body="\$2"; shift ;; -H|-X|--max-time) shift ;; http*) url="\$1" ;; esac
  shift
done
n=\$(( \$(wc -l < "\$H/curl.log" 2>/dev/null || echo 0) + 1 ))
echo "POST \$url" >> "\$H/curl.log"; echo "curl \$url" >> "\$H/order.log"
printf '%s' "\$body" > "\$H/curl-body.\$n"
case "\${CURL_MODE:-ok}:\$url" in
  ok:*/comments|turn500:*/comments) printf '{"comment":{"id":"c9"}}' ;;
  ok:*/turn) printf '{"ok":true}' ;;
  errjson:*) printf '{"error":"x"}' ;;
  *) printf '<html><body>500 Internal Server Error</body></html>' ;;
esac
SH
  cat > "$h/fakebin/gh" <<SH
#!/bin/bash
H="$h"
echo "\$*" >> "\$H/gh.log"; echo "gh \$*" >> "\$H/order.log"
inc=0
for a in "\$@"; do
  case "\$a" in -i) inc=1 ;; body=@*) cp "\${a#body=@}" "\$H/gh-body.\$(wc -l < "\$H/gh.log")" ;; esac
done
if [ "\${GH_MODE:-ok}" = ok ]; then
  [ "\$inc" = 1 ] && printf 'HTTP/1.1 201 Created\r\n\r\n'
  printf '{"id":9}\n'
else
  [ "\$inc" = 1 ] && printf 'HTTP/1.1 500 Internal Server Error\r\n\r\n'
  printf '{"message":"boom"}\n'; exit 1
fi
SH
  chmod +x "$h/bin/"*.sh "$h/fakebin/"*
  printf '%s' "$h"
}
meta() { mkdir -p "$1"; printf '%s\n' "$BUGMETA" > "$1/ticket-meta.json"; }
# run <harness> <build> — the runner as run-build calls it; sets RC.
run() { meta "$2"; PATH="$1/fakebin:$PATH" HARNESS="$1" bash "$1/bin/prebuild-repro.sh" p 42 BH-7 "$2" > "$2/runner.out" 2>&1; RC=$?; }
rline() { sed -n "s/^$2: //p" "$1/prebuild-repro.txt" 2>/dev/null; }
cnt() { local n; n=$(grep -c "$2" "$1" 2>/dev/null) || true; printf '%s' "${n:-0}"; }
# lstat <harness> <thread> — the ledger status for the key this thread gives.
lstat() {
  local k
  k=$(export HARNESS="$1"; . "$1/bin/lib/prebuild-repro.sh"; pr_ledger_key p BH-7 "$2")
  cat "$1/ledger/$(printf '%s' "repro_gate/$k" | sha256sum | cut -c1-16)" 2>/dev/null
}
bodyof() { jq -r '.body // empty' "$1" 2>/dev/null; }
export THREAD_JSON
TH1='{"body":"Totals are wrong on the client page","comments":[{"id":"c1","createdAt":"2026-09-20T00:00:00Z","body":"still wrong"}]}'
TH3='{"body":"Totals are wrong on the client page","comments":[{"id":"c1","createdAt":"2026-09-20T00:00:00Z","body":"still wrong"},{"id":"c2","createdAt":"2026-09-21T00:00:00Z","body":"any news?"}]}'

# ═══════════════════════════════════════════════════════════════════════════
# C1 — NOT_REPRODUCED on an in-app board: one comment, one turn, rc 10.
# ═══════════════════════════════════════════════════════════════════════════
H=$(mkh main); B="$T/c1"
THREAD_JSON="$TH1" BOARD=app CURL_MODE=ok run "$H" "$B"
[ "$RC" = 10 ] && ok || bad "C1: runner rc $RC, not 10 ($(tr '\n' '|' < "$B/runner.out"))"
[ "$(cnt "$H/curl.log" '^POST https://app.example/api/board/tickets/42/comments$')" = 1 ] && ok || bad "C1: comment POSTs: $(cat "$H/curl.log" 2>/dev/null | tr '\n' '|')"
[ "$(cnt "$H/curl.log" '^POST https://app.example/api/board/tickets/42/turn$')" = 1 ] && ok || bad "C1: turn POSTs: $(cat "$H/curl.log" 2>/dev/null | tr '\n' '|')"
tb=$(grep -l '"to"' "$H"/curl-body.* 2>/dev/null | head -1)
[ -n "$tb" ] && [ "$(jq -r '.to' "$tb" 2>/dev/null)" = client ] && ok || bad "C1: the turn body is not {\"to\":\"client\"}"
[ "$(grep -n '/turn$' "$H/curl.log" | cut -d: -f1)" = 2 ] && ok || bad "C1: the turn was not sent after the comment"
[ "$(rline "$B" REPRO_GATE)" = stop ] && ok || bad "C1: record gate '$(rline "$B" REPRO_GATE)'"
[ "$(lstat "$H" "$TH1")" = not_reproduced ] && ok || bad "C1: ledger ends '$(lstat "$H" "$TH1")'"
C1BODY=$(bodyof "$H/curl-body.1")

# C1b — the run-build block, verbatim, with the real runner and stop.
RB=$(rb_all "$DIR" "$T/run-build.all.sh")
marked() { awk -v s="$1" -v e="$2" 'index($0,s){f=1;next} index($0,e){f=0} f' "$3"; }
marked '# >>> prebuild repro (BH-2004)' '# <<< prebuild repro' "$RB" > "$T/hook.sh"
[ -s "$T/hook.sh" ] && ok || bad "C1b: the prebuild repro block is missing from bin/run-build.sh"
{ echo 'RESULT() { printf "%s\n" "$*" >> "$BUILD/result.txt"; }'
  cat "$T/hook.sh"
  echo 'touch "$BUILD/PLAN_REACHED"'
} > "$T/hookrun.sh"
# block_run <harness> <build> — sets RC.
block_run() {
  meta "$2"
  ( PATH="$1/fakebin:$PATH" HARNESS="$1" BUILD="$2" PROJECT=p TICKET=42 KEY=BH-7 bash "$T/hookrun.sh" ) > "$2/hook.out" 2>&1
  RC=$?
}
HB=$(mkh block1); B="$T/c1b"
THREAD_JSON="$TH1" BOARD=app CURL_MODE=ok block_run "$HB" "$B"
[ "$RC" = 3 ] && ok || bad "C1b: block rc $RC, not 3 ($(tr '\n' '|' < "$B/hook.out"))"
grep -q '^BUILD_DEFERRED repro NOT_REPRODUCED' "$B/result.txt" 2>/dev/null && ok || bad "C1b: RESULT is '$(cat "$B/result.txt" 2>/dev/null)'"
[ -e "$B/COMMENTED" ] && ok || bad "C1b: COMMENTED not written"
[ ! -e "$B/PLAN_REACHED" ] && ok || bad "C1b: the plan stage was reached after a stop"
[ "$(cnt "$HB/curl.log" '/tickets/42/comments$')" = 1 ] && ok || bad "C1b: $(cnt "$HB/curl.log" '/comments$') comment POSTs"

# ═══════════════════════════════════════════════════════════════════════════
# C2 — the same thread again: the ledger says delivered, so rc 10, no post.
# ═══════════════════════════════════════════════════════════════════════════
B="$T/c2"; before=$(cnt "$H/curl.log" .)
THREAD_JSON="$TH1" BOARD=app CURL_MODE=ok run "$H" "$B"
[ "$RC" = 10 ] && ok || bad "C2: rc $RC, not 10"
[ "$(cnt "$H/curl.log" .)" = "$before" ] && ok || bad "C2: $(( $(cnt "$H/curl.log" .) - before )) new curl calls on a delivered thread"
# ...and an already_fixed verdict on the same delivered key is still terminal.
B="$T/c2b"; THREAD_JSON="$TH1" VERDICT=ALREADY_FIXED BOARD=app run "$H" "$B"
[ "$RC" = 10 ] && [ "$(cnt "$H/curl.log" .)" = "$before" ] && ok || bad "C2: ALREADY_FIXED on a delivered key rc $RC, curl $(cnt "$H/curl.log" .)"

# ═══════════════════════════════════════════════════════════════════════════
# C3 — a fresh thread and a 500: rc 11, ledger left _uncommented, one ALERT.
# ═══════════════════════════════════════════════════════════════════════════
B="$T/c3"; : > "$H/order.log"; : > "$H/ledger.puts"; before=$(cnt "$H/curl.log" .)
THREAD_JSON="$TH3" BOARD=app CURL_MODE=500 run "$H" "$B"
[ "$RC" = 11 ] && ok || bad "C3: rc $RC, not 11"
[ "$(lstat "$H" "$TH3")" = not_reproduced_uncommented ] && ok || bad "C3: ledger '$(lstat "$H" "$TH3")'"
first_put=$(grep -n '^ledger ledger-put' "$H/order.log" | head -1 | cut -d: -f1)
first_curl=$(grep -n '^curl ' "$H/order.log" | head -1 | cut -d: -f1)
[ -n "$first_put" ] && [ -n "$first_curl" ] && [ "$first_put" -lt "$first_curl" ] && ok || bad "C3: put line $first_put, curl line $first_curl (write must precede send)"
grep -q '^put p/BH-7/[0-9a-f]* not_reproduced_uncommented argc=4$' "$H/ledger.puts" && ok || bad "C3: the _uncommented put carried a detail arg or is missing: $(tr '\n' '|' < "$H/ledger.puts")"
[ "$(cnt "$H/logs/ALERTS.log" .)" = 1 ] && ok || bad "C3: ALERTS.log has $(cnt "$H/logs/ALERTS.log" .) lines"
grep -q '\[p\] prebuild-repro: BH-7 NOT_REPRODUCED comment POST failed' "$H/logs/ALERTS.log" 2>/dev/null && ok || bad "C3: ALERT line: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
[ "$(cnt "$H/curl.log" '/turn$')" = 1 ] && ok || bad "C3: a turn was sent for a comment that failed"
# C3b — the block on a 500: no COMMENTED, record deleted, the failure RESULT.
HB=$(mkh block3); B="$T/c3b"
THREAD_JSON="$TH3" BOARD=app CURL_MODE=500 block_run "$HB" "$B"
grep -q '^BUILD_DEFERRED repro NOT_REPRODUCED but the board comment failed' "$B/result.txt" 2>/dev/null && ok || bad "C3b: RESULT is '$(cat "$B/result.txt" 2>/dev/null)'"
[ ! -e "$B/COMMENTED" ] && [ ! -e "$B/prebuild-repro.txt" ] && ok || bad "C3b: COMMENTED or the record survived a failed comment"

# ═══════════════════════════════════════════════════════════════════════════
# C4 — the next offer after C3 posts exactly once.
# ═══════════════════════════════════════════════════════════════════════════
B="$T/c4"; before=$(cnt "$H/curl.log" '/comments$')
THREAD_JSON="$TH3" BOARD=app CURL_MODE=ok run "$H" "$B"
[ "$RC" = 10 ] && ok || bad "C4: rc $RC, not 10"
[ "$(( $(cnt "$H/curl.log" '/comments$') - before ))" = 1 ] && ok || bad "C4: $(( $(cnt "$H/curl.log" '/comments$') - before )) comment POSTs on the retry"
[ "$(lstat "$H" "$TH3")" = not_reproduced ] && ok || bad "C4: ledger '$(lstat "$H" "$TH3")'"

# ═══════════════════════════════════════════════════════════════════════════
# C5 — a GitHub-issues project: one issue comment through gh, no turn.
# ═══════════════════════════════════════════════════════════════════════════
H5=$(mkh gh); B="$T/c5"
THREAD_JSON="$TH1" BOARD=gh run "$H5" "$B"
[ "$RC" = 10 ] && ok || bad "C5: rc $RC, not 10 ($(tr '\n' '|' < "$B/runner.out"))"
[ "$(cnt "$H5/gh.log" .)" = 1 ] && ok || bad "C5: gh ran $(cnt "$H5/gh.log" .) times"
grep -q 'repos/acme/widgets/issues/42/comments' "$H5/gh.log" 2>/dev/null && grep -q 'body=@' "$H5/gh.log" && ok || bad "C5: gh argv '$(cat "$H5/gh.log" 2>/dev/null)'"
grep -q -- '-i' "$H5/gh.log" 2>/dev/null && ok || bad "C5: the call did not go through gh_rest (no -i)"
! grep -q labels "$H5/gh.log" 2>/dev/null && ok || bad "C5: gh touched labels"
[ ! -e "$H5/curl.log" ] && ok || bad "C5: curl ran on a GitHub project: $(cat "$H5/curl.log")"
[ "$(lstat "$H5" "$TH1")" = not_reproduced ] && ok || bad "C5: ledger '$(lstat "$H5" "$TH1")'"
C5BODY=$(cat "$H5/gh-body.1" 2>/dev/null)
# C5f — no gh-rest.sh on the box: no raw gh call, a failed send (rc 11, one
# ALERT, ledger left _uncommented) so the next offer retries.
H5f=$(mkh ghf); rm -f "$H5f/bin/lib/gh-rest.sh"; B="$T/c5f"
THREAD_JSON="$TH1" BOARD=gh run "$H5f" "$B"
[ "$RC" = 11 ] && [ ! -e "$H5f/gh.log" ] && [ "$(cnt "$H5f/logs/ALERTS.log" .)" = 1 ] && [ "$(lstat "$H5f" "$TH1")" = not_reproduced_uncommented ] && ok \
  || bad "C5f: rc $RC gh '$(cat "$H5f/gh.log" 2>/dev/null)' alerts $(cnt "$H5f/logs/ALERTS.log" .) ledger '$(lstat "$H5f" "$TH1")'"
# C5x — gh answers 500: rc 11, one ALERT, ledger left _uncommented.
H5x=$(mkh ghx); B="$T/c5x"
THREAD_JSON="$TH1" BOARD=gh GH_MODE=fail run "$H5x" "$B"
[ "$RC" = 11 ] && [ "$(cnt "$H5x/logs/ALERTS.log" .)" = 1 ] && [ "$(lstat "$H5x" "$TH1")" = not_reproduced_uncommented ] && ok \
  || bad "C5x: rc $RC alerts $(cnt "$H5x/logs/ALERTS.log" .) ledger '$(lstat "$H5x" "$TH1")'"

# ═══════════════════════════════════════════════════════════════════════════
# C6 — the ledger is down: never stop blind. rc 0, nothing sent.
# ═══════════════════════════════════════════════════════════════════════════
H6=$(mkh down); B="$T/c6"
THREAD_JSON="$TH1" BOARD=app LEDGER_DOWN=1 run "$H6" "$B"
[ "$RC" = 0 ] && ok || bad "C6: rc $RC, not 0"
[ ! -e "$H6/curl.log" ] && [ ! -e "$H6/gh.log" ] && ok || bad "C6: something was sent with the ledger down"
[ "$(rline "$B" REPRO_GATE)" != stop ] && ok || bad "C6: the record says stop"
# C6g — only the READ is down: the outage branch alone must stop the send and the write.
H6g=$(mkh getdown); B="$T/c6g"
THREAD_JSON="$TH1" BOARD=app LEDGER_GET_DOWN=1 run "$H6g" "$B"
[ "$RC" = 0 ] && [ ! -e "$H6g/curl.log" ] && [ ! -e "$H6g/ledger.puts" ] && ok || bad "C6g: rc $RC, curl $(cnt "$H6g/curl.log" .), puts $(cnt "$H6g/ledger.puts" .) with the ledger read down"
# C6p — the ledger reads but the pre-send put fails: no post, build.
H6p=$(mkh putdown); B="$T/c6p"
THREAD_JSON="$TH1" BOARD=app LEDGER_PUT_DOWN=1 run "$H6p" "$B"
[ "$RC" = 0 ] && [ ! -e "$H6p/curl.log" ] && ok || bad "C6p: rc $RC, curl $(cnt "$H6p/curl.log" .) with the pre-send put failing"
# C6d — delivered, then the final put fails: still rc 10 (a retry would double it), one log line.
H6d=$(mkh putafter); B="$T/c6d"
THREAD_JSON="$TH1" BOARD=app LEDGER_PUT_FAIL_STATUS=not_reproduced run "$H6d" "$B"
[ "$RC" = 10 ] && [ "$(cnt "$H6d/curl.log" '/comments$')" = 1 ] && [ "$(cnt "$B/pipeline.log" 'ledger')" = 1 ] && ok \
  || bad "C6d: rc $RC comments $(cnt "$H6d/curl.log" '/comments$') log $(cnt "$B/pipeline.log" 'ledger')"
# C6c — no board config at all: a failed comment, rc 11 and one ALERT.
H6c=$(mkh noconf); B="$T/c6c"
THREAD_JSON="$TH1" BOARD=none run "$H6c" "$B"
[ "$RC" = 11 ] && [ "$(cnt "$H6c/logs/ALERTS.log" .)" = 1 ] && [ ! -e "$H6c/curl.log" ] && ok || bad "C6c: rc $RC alerts $(cnt "$H6c/logs/ALERTS.log" .)"

# ═══════════════════════════════════════════════════════════════════════════
# T — text, cap, error body, turn failure, negatives, source, secrets.
# ═══════════════════════════════════════════════════════════════════════════
# text_ok <label> <body> <lead>
text_ok() {
  local l="$1" b="$2"
  case "$b" in *"$3"*) ok ;; *) bad "T-text $l: lead '$3' missing" ;; esac
  case "$b" in *"account manager"*) ok ;; *) bad "T-text $l: role missing" ;; esac
  case "$b" in *"https://app.example/clients/77"*) ok ;; *) bad "T-text $l: URL missing" ;; esac
  case "$b" in *"Totals row read 1,240.00, matching the three invoices"*) ok ;; *) bad "T-text $l: observed text missing" ;; esac
  case "$b" in *"opened the client, read the totals row"*) ok ;; *) bad "T-text $l: steps missing" ;; esac
  grep -qi screenshot <<<"$b" && ok || bad "T-text $l: no screenshot ask"
  grep -q '—' <<<"$b" && bad "T-text $l: em dash in the comment" || ok
  grep -qiE 'fixed it|we fixed|is fixed|working on' <<<"$b" && bad "T-text $l: a fix or progress claim" || ok
}
NR_LEAD="We tried to reproduce this before building a fix, and we couldn't see the problem."
AF_LEAD="We tried this before building and it looks like it already works."
text_ok app-nr "$C1BODY" "$NR_LEAD"
grep -q '<blockquote>' <<<"$C1BODY" && ok || bad "T-text app-nr: observed not in a blockquote"
text_ok gh-nr "$C5BODY" "$NR_LEAD"
grep -q '^> Totals row read' <<<"$C5BODY" && ok || bad "T-text gh-nr: observed not in a > quote"
Ht=$(mkh taf); THREAD_JSON="$TH1" BOARD=app VERDICT=ALREADY_FIXED run "$Ht" "$T/taf"
text_ok app-af "$(bodyof "$Ht/curl-body.1")" "$AF_LEAD"
[ "$(lstat "$Ht" "$TH1")" = already_fixed ] && ok || bad "T-text app-af: ledger '$(lstat "$Ht" "$TH1")'"
Ht=$(mkh tafg); THREAD_JSON="$TH1" BOARD=gh VERDICT=ALREADY_FIXED run "$Ht" "$T/tafg"
text_ok gh-af "$(cat "$Ht/gh-body.1" 2>/dev/null)" "$AF_LEAD"
# Model-supplied values are escaped in HTML.
Ht=$(mkh tesc); THREAD_JSON="$TH1" BOARD=app OBSERVED='<script>x()</script> & more' run "$Ht" "$T/tesc"
b=$(bodyof "$Ht/curl-body.1")
case "$b" in *'&lt;script&gt;x()&lt;/script&gt; &amp; more'*) ok ;; *) bad "T-text esc: observed not escaped" ;; esac
case "$b" in *'<script>'*) bad "T-text esc: raw <script> in the body" ;; *) ok ;; esac
# No prebuild-repro.md: every field is "not recorded", the ask is still there.
Ht=$(mkh tnomd); THREAD_JSON="$TH1" BOARD=app NO_MD=1 run "$Ht" "$T/tnomd"
b=$(bodyof "$Ht/curl-body.1")
[ "$RC" = 10 ] && [ "$(grep -o 'not recorded' <<<"$b" | wc -l)" = 4 ] && grep -qi screenshot <<<"$b" && ok \
  || bad "T-text nomd: rc $RC, 'not recorded' x$(printf '%s' "$b" | grep -o 'not recorded' | wc -l)"
# T-cap
Ht=$(mkh tcap); big=$(head -c 4000 /dev/zero | tr '\0' a); bigs=$(head -c 4000 /dev/zero | tr '\0' s)
THREAD_JSON="$TH1" BOARD=app OBSERVED="$big" STEPS="$bigs" run "$Ht" "$T/tcap"
b=$(bodyof "$Ht/curl-body.1")
[ "$RC" = 10 ] && [ "${#b}" -le 5000 ] && [ "${#b}" -gt 3000 ] && ok || bad "T-cap: rc $RC, body ${#b} chars"
grep -qi screenshot <<<"$b" && ok || bad "T-cap: the ask was cut"
# T-err — a 200 that is not a comment object.
Ht=$(mkh terr); THREAD_JSON="$TH1" BOARD=app CURL_MODE=errjson run "$Ht" "$T/terr"
[ "$RC" = 11 ] && [ "$(cnt "$Ht/curl.log" '/turn$')" = 0 ] && ok || bad "T-err: rc $RC, turns $(cnt "$Ht/curl.log" '/turn$')"
# T-turn — the turn 500s: still rc 10, one turn call, one log line in each log.
Ht=$(mkh tturn); B="$T/tturn"; THREAD_JSON="$TH1" BOARD=app CURL_MODE=turn500 run "$Ht" "$B"
[ "$RC" = 10 ] && ok || bad "T-turn: rc $RC, not 10"
[ "$(cnt "$Ht/curl.log" '/turn$')" = 1 ] && ok || bad "T-turn: $(cnt "$Ht/curl.log" '/turn$') turn calls"
[ "$(cnt "$B/pipeline.log" 'turn')" = 1 ] && [ "$(cnt "$Ht/logs/p.log" 'turn')" = 1 ] && ok || bad "T-turn: log lines $(cnt "$B/pipeline.log" turn)/$(cnt "$Ht/logs/p.log" turn)"
[ "$(lstat "$Ht" "$TH1")" = not_reproduced ] && ok || bad "T-turn: ledger '$(lstat "$Ht" "$TH1")'"
# T-neg — direct calls with a verdict that is not a stop.
Hn=$(mkh tneg); mkdir -p "$T/tnegb"
for v in REPRODUCED not_reproduced CANNOT_DRIVE ''; do
  ( export HARNESS="$Hn" PATH="$Hn/fakebin:$PATH" BOARD=app; . "$Hn/bin/lib/prebuild-repro.sh"; pr_stop p 42 BH-7 "$T/tnegb" "$TH1" "$v" ); rc=$?
  [ "$rc" = 0 ] && ok || bad "T-neg: verdict '$v' rc $rc"
done
[ ! -e "$Hn/order.log" ] && ok || bad "T-neg: a non-stop verdict touched the ledger or the network: $(tr '\n' '|' < "$Hn/order.log")"
# T-src — sourcing the stage is side-effect free.
mkdir -p "$T/tsrc"
out=$(cd "$T/tsrc" && env -i PATH="$Hn/fakebin:$PATH" HARNESS="$Hn" bash -c ". '$Hn/bin/lib/prebuild-repro/stop.sh'; command -v pr_stop >/dev/null && echo DEFINED")
[ "$out" = DEFINED ] && [ -z "$(ls -A "$T/tsrc")" ] && [ ! -e "$Hn/order.log" ] && ok || bad "T-src: '$out', files: $(ls -A "$T/tsrc")"
# T-secret — the token is in no log any case wrote.
leak=$(grep -rlF "$TOKEN" "$T"/*/logs "$T"/*/pipeline.log "$T"/*/runner.out "$T"/*/hook.out "$T"/*/prebuild-repro.out 2>/dev/null)
[ -z "$leak" ] && ok || bad "T-secret: token found in $leak"

echo "prebuild-repro-stop: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
