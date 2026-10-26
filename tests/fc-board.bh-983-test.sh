#!/bin/bash
# tests/fc-board.bh-983-test.sh — bin/lib/fc-board.sh, the in-app board lane of
# the child filer (fc_file_board, BH-983).
#
# Drives byte copies of the repo's filer contract (bin/lib/file-children.sh),
# the board module and bin/run-rollout.sh out of a scratch checkout ($T/co),
# against a scratch harness ($T/h) whose fleet.conf carries ONE in-app row with
# column 4 = /api/accounting/requests-board. A `curl` stub on PATH (the
# tests/sweep-stale-builds-test.sh pattern) logs every argv line to $T/curl.log,
# keeps every --data-binary body, and plays the board. No network, no real board.
#
#   A1  capability advertised, 3 rollout waves: ordered creates under col 4,
#       parentId/dependsOn/priority, 3 idempotency keys, comment then move
#   A2  no capability, rollout: refusal string, zero writes (six shapes)
#   A3  probe curl error, rollout: same refusal, zero writes
#   A4  no capability, decompose: files anyway, no parentId/dependsOn keys
#   A4b capability, decompose, integer ids: `after` normalisation, ids untyped
#   A5  create fails on child 2 of 3: rc 1, record holds child 1, no park
#   A5b resume of A5: only children 2 and 3 created, ids from the sidecar
#   A5c 2xx create without an id, recorded key without a sidecar id, bad record
#   A6  dry run: every curl printed, nothing sent, bodies on disk
#   A7  the token appears in no build-dir file
#   A8  a failed move or comment is a WARN, rc 0
#   A9  the real bin/run-rollout.sh through file_children, with and without the module
#   A10 bash -n / shellcheck -S error on the module
#   A11 this ticket's branch touches none of the eight do-not-touch files
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

MOD_SRC="$DIR/bin/lib/fc-board.sh"
TOKEN=tok-FIXTURE-SENTINEL-983

mkdir -p "$T/co/bin/lib" "$T/co-nomod/bin/lib" "$T/h/bin" "$T/h/env" "$T/stub"
for d in co co-nomod; do
  cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/run-rollout.sh" "$T/$d/bin/"
  cp "$DIR/bin/lib/file-children.sh" "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/internal-token.sh" "$T/$d/bin/lib/"
done
# run-rollout.sh reads fleet.conf through $HARNESS/bin/fleet-conf.sh. $T/h/bin/lib
# holds NO lane module, so the module beside the copied library is the only one.
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
cp "$MOD_SRC" "$T/co/bin/lib/" 2>/dev/null || echo "note: $MOD_SRC does not exist"
mkdir -p "$T/co/bin/lib/tracker" && cp "$DIR/bin/lib/tracker.sh" "$T/co/bin/lib/" && cp "$DIR/bin/lib/tracker/board.sh" "$T/co/bin/lib/tracker/"
# BH-7919: the board base and token come from tracker_context, which resolves
# them through bin/lib/board-creds.sh and bin/internal-token-for.sh.
scratch_install_closure bin/lib/board-creds.sh "$T/co" >/dev/null || exit 1
scratch_install_closure bin/internal-token-for.sh "$T/co" >/dev/null || exit 1
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset>
ledger-os  example-org/ledger-os  https://ledger.example  /api/accounting/requests-board  3
CONF
cat > "$T/h/env/ledger-os.env" <<CONF
LEDGER_API_BASE=https://ledger.example
LEDGER_INTERNAL_API_TOKEN=$TOKEN
CONF
BASE="https://ledger.example/api/accounting/requests-board"

# The board. The create answer is keyed by the Idempotency-Key's position, so a
# resume that re-creates only child 2 gets child 2's id, and the header itself
# is exercised.
cat > "$T/stub/curl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$CURL_LOG"
seq=$(wc -l < "$CURL_LOG" | tr -d ' ')
method=GET; url=""; data=""; k=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift ;;
    --data-binary) data="$2"; shift ;;
    -H) case "$2" in Idempotency-Key:*) k="${2##*-}" ;; esac; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
[ -n "$data" ] && cp "${data#@}" "$CURL_BODIES/$seq.json"
if [ "${CURL_NUMERIC_IDS:-}" = 1 ]; then pid=4242; cid="50$k"; else pid='"cmParent01"'; cid="\"cmChild0$k\""; fi
case "$method $url" in
  "GET "*/boards)
    [ "${CURL_PROBE_FAIL:-}" = 1 ] && exit 7
    cat "$CURL_BOARDS" ;;
  "GET "*/tickets/*)
    jq -c --argjson id "$pid" '.ticket.id = $id' "$CURL_PARENT" ;;
  "POST "*/boards/*/tickets)
    [ "$k" = "${CURL_FAIL_CREATE:-x}" ] && exit 22
    if [ "$k" = "${CURL_NO_ID:-x}" ]; then printf '{"ticket":{"key":"LG-10%s"}}\n' "$k"; exit 0; fi
    printf '{"ticket":{"id":%s,"key":"LG-10%s","url":"https://ledger.example/board/LG-10%s"}}\n' "$cid" "$k" "$k" ;;
  "POST "*/comments)
    [ "${CURL_COMMENT_FAIL:-}" = 1 ] && exit 22
    printf '{"ok":true}\n' ;;
  "POST "*/move)
    if [ "${CURL_MOVE_FAIL:-}" = 1 ]; then printf '{"ticket":{"status":"todo"}}\n'
    else printf '{"ticket":{"status":"in_progress"}}\n'; fi ;;
  *) exit 22 ;;
esac
exit 0
SH
chmod +x "$T/stub/curl"

# The parent: a real rollout body (for A9's parse) plus the priority the
# children inherit.
jq -n '{ticket: {id: "cmParent01", key: "LG-9", priority: "high", status: "todo",
  description: "<p>Ship the ledger export.</p>\n\n## Rollout\n\n### Wave 1: Schema\nAdd the export table.\n\n### Wave 2: API\nafter: Schema\nServe the export.\n\n### Wave 3: UI\nafter: Schema, API\nShow it & <b>bold</b>.\n"}}' > "$T/parent.json"
printf '[{"id":"rb-1","capabilities":["dependencies"]}]\n' > "$T/boards-cap.json"
printf '{"boards":[{"id":"rb-1"}]}\n' > "$T/boards-absent.json"
printf '[{"id":"rb-1","capabilities":"dependencies"}]\n' > "$T/boards-string.json"
printf '[{"id":"rb-1","capabilities":["reactions"]},{"id":"rb-2","capabilities":["dependencies"]}]\n' > "$T/boards-second.json"
printf '[{"id":"rb-1","capabilities":null}]\n' > "$T/boards-null.json"
printf '[{"id":"rb-1","capabilities":["dependency","Dependencies "]}]\n' > "$T/boards-near.json"
printf 'not json at all\n' > "$T/boards-garbage.json"

# Shaped exactly as bin/run-rollout.sh emits it (`{"title","body","after":[ints]}`).
ROLLOUT_SPEC='[{"title":"Schema","body":"Add the export table.\n","after":[]},
 {"title":"API","body":"Serve the export.\n","after":[1]},
 {"title":"UI","body":"Show it & <b>bold</b>.\n","after":[1,2]}]'
# Shaped as bin/run-decompose.sh validates it: a contract on child 0, `after`
# as ints or "n:hard" strings, a forward reference to be dropped.
DECOMPOSE_SPEC='[{"title":"Types","body":"The export types.","contract":"src/export/types.ts: ExportRow","after":[2]},
 {"title":"Server","body":"The route.","after":[5]},
 {"title":"Client","body":"The screen.","after":["2:hard","1"]}]'

# fcb <build> <kind> [VAR=value …] — file_children through the real dispatch.
# FC_ERROR (a variable, not a file) is written to $T/fc_error.txt.
fcb() {
  local b="$1" kind="$2"; shift 2
  : > "$T/curl.log"; rm -rf "$T/bodies"; mkdir -p "$T/bodies" "$b"
  env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/stub:$PATH" \
    CURL_LOG="$T/curl.log" CURL_BODIES="$T/bodies" CURL_PARENT="$T/parent.json" \
    CURL_BOARDS="$T/boards-cap.json" "$@" \
    bash -c '. "$1/bin/lib/file-children.sh" || exit 9
      file_children ledger-os cmParent01 LG-9 "$2" "$2/children.json" --kind "$3"; rc=$?
      printf "%s" "${FC_ERROR:-}" > "$4/fc_error.txt"; exit $rc' _ "$T/co" "$b" "$kind" "$T"
}
creates() { grep -c -- "-X POST .*$BASE/boards/rb-1/tickets\$" "$T/curl.log"; }
writes()  { grep -cE -- '-X POST .*/(tickets|comments|move)$' "$T/curl.log"; }
body_of() { # body_of <n-th create> -> the JSON it sent
  local seq; seq=$(grep -n -- "/boards/rb-1/tickets\$" "$T/curl.log" | sed -n "${1}p" | cut -d: -f1)
  cat "$T/bodies/$seq.json" 2>/dev/null
}

# --- A1 ------------------------------------------------------------------
B1="$T/b1"; mkdir -p "$B1"; printf '%s\n' "$ROLLOUT_SPEC" > "$B1/children.json"
OUT=$(fcb "$B1" rollout 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "A1 rc=$RC: $OUT $(cat "$T/fc_error.txt") $(cat "$B1/pipeline.log" 2>/dev/null)"
[ "$(creates)" = 3 ] && ok || bad "A1 three creates at $BASE/boards/rb-1/tickets, got $(creates): $(cat "$T/curl.log")"
[ "$(grep -o 'Idempotency-Key: [^ ]*' "$T/curl.log" | tr '\n' ' ')" = "Idempotency-Key: rollout-LG-9-1 Idempotency-Key: rollout-LG-9-2 Idempotency-Key: rollout-LG-9-3 " ] \
  && ok || bad "A1 three distinct idempotency keys in order: $(grep -o 'Idempotency-Key: [^ ]*' "$T/curl.log")"
[ "$(body_of 3 | jq -c '[.parentId, .dependsOn, .priority]')" = '["cmParent01",["cmChild01","cmChild02"],"high"]' ] \
  && ok || bad "A1 child 3 carries parentId, both earlier ids and the priority: $(body_of 3)"
[ "$(body_of 1 | jq -c '[.parentId, .dependsOn]')" = '["cmParent01",[]]' ] && ok || bad "A1 child 1: $(body_of 1)"
[ "$(body_of 1 | jq -r .title)" = "LG-9.1: Schema" ] && ok || bad "A1 title: $(body_of 1 | jq -r .title)"
D3=$(body_of 3 | jq -r .description)
for s in 'Part of #LG-9' 'Order: 3 of 3' 'Blocked-by: LG-101 (hard), LG-102 (hard)' 'Show it &amp; &lt;b&gt;bold&lt;/b&gt;.'; do
  case "$D3" in *"$s"*) ok ;; *) bad "A1 child 3 description lacks '$s': $D3" ;; esac
done
case "$D3" in *"<b>"*) bad "A1 child body HTML was injected unescaped" ;; *) ok ;; esac
# Order: the three creates, then the comment, then the move — nothing else writes.
[ "$(grep -oE -- '-X POST .*/(tickets|comments|move)$' "$T/curl.log" | sed -E 's#.*/##')" = "$(printf 'tickets\ntickets\ntickets\ncomments\nmove')" ] \
  && ok || bad "A1 write order: $(cat "$T/curl.log")"
grep -q -- "-X POST .*$BASE/tickets/cmParent01/comments\$" "$T/curl.log" && ok || bad "A1 comment on the master"
CSEQ=$(grep -n -- '/comments$' "$T/curl.log" | cut -d: -f1)
CB=$(jq -r .body "$T/bodies/$CSEQ.json" 2>/dev/null)
for k in 1 2 3; do
  case "$CB" in *"<a href=\"https://ledger.example/board/LG-10$k\">LG-10$k</a>"*) ok ;; *) bad "A1 comment links LG-10$k: $CB" ;; esac
done
MSEQ=$(grep -n -- "$BASE/tickets/cmParent01/move\$" "$T/curl.log" | cut -d: -f1)
[ "$(jq -r .toStatus "$T/bodies/$MSEQ.json" 2>/dev/null)" = in_progress ] && ok || bad "A1 move to in_progress"
[ "$(cat "$B1/children.txt" 2>/dev/null)" = "$(printf 'LG-101\nLG-102\nLG-103')" ] && ok || bad "A1 children.txt: $(cat "$B1/children.txt" 2>/dev/null)"
[ "$(grep -c '/api/board' "$T/curl.log")" = 0 ] && ok || bad "A1 the hardcoded /api/board was called"
grep -q "$BASE/boards\$" "$T/curl.log" && ok || bad "A1 probe under column 4"

# --- A2 / A3 -------------------------------------------------------------
refused() { # refused <label> [VAR=value …]
  local label="$1" b="$T/b-$1"; shift
  scratch_rm "$b"; mkdir -p "$b"; printf '%s\n' "$ROLLOUT_SPEC" > "$b/children.json"
  fcb "$b" rollout "$@" >/dev/null 2>&1; local rc=$?
  [ "$rc" != 0 ] && ok || bad "$label: rc 0 without the capability"
  grep -q 'ROLLOUT_FAILED board lacks dependencies' "$b/pipeline.log" 2>/dev/null && ok || bad "$label: refusal not in pipeline.log: $(cat "$b/pipeline.log" 2>/dev/null)"
  [ "$(cat "$T/fc_error.txt")" = 'ROLLOUT_FAILED board lacks dependencies' ] && ok || bad "$label: FC_ERROR '$(cat "$T/fc_error.txt")'"
  [ "$(writes)" = 0 ] && ok || bad "$label: $(writes) writes (create/comment/move) on a refusal"
  [ ! -e "$b/children.txt" ] && ok || bad "$label: children.txt written on a refusal"
}
refused A2-absent  CURL_BOARDS="$T/boards-absent.json"
refused A2-string  CURL_BOARDS="$T/boards-string.json"
refused A2-second  CURL_BOARDS="$T/boards-second.json"
refused A2-null    CURL_BOARDS="$T/boards-null.json"
refused A2-near    CURL_BOARDS="$T/boards-near.json"
refused A2-garbage CURL_BOARDS="$T/boards-garbage.json"
refused A3-probe   CURL_PROBE_FAIL=1

# --- A4 ------------------------------------------------------------------
B4="$T/b4"; mkdir -p "$B4"; printf '%s\n' "$DECOMPOSE_SPEC" > "$B4/children.json"
fcb "$B4" decompose CURL_BOARDS="$T/boards-absent.json" >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "A4 decompose without the capability must file (rc=$RC): $(cat "$T/fc_error.txt")"
[ "$(creates)" = 3 ] && ok || bad "A4 three creates, got $(creates)"
for n in 1 2 3; do
  [ "$(body_of $n | jq 'has("parentId") or has("dependsOn")')" = false ] && ok || bad "A4 child $n carries dependency fields: $(body_of $n)"
done
[ "$(grep -o 'Idempotency-Key: [^ ]*' "$T/curl.log" | tr '\n' ' ')" = "Idempotency-Key: decompose-LG-9-1 Idempotency-Key: decompose-LG-9-2 Idempotency-Key: decompose-LG-9-3 " ] \
  && ok || bad "A4 idempotency keys: $(grep -o 'Idempotency-Key: [^ ]*' "$T/curl.log")"
[ "$(body_of 1 | jq -r .title)" = "LG-9.0: contract — Types" ] && ok || bad "A4 contract title: $(body_of 1 | jq -r .title)"
grep -q 'WARN' "$B4/pipeline.log" && ok || bad "A4 no WARN for a board without the capability"
case "$(body_of 2 | jq -r .description)" in *'Blocked-by: LG-101 (hard)'*'DEPENDS: LG-101 hard'*) ok ;; *) bad "A4 sibling footer: $(body_of 2 | jq -r .description)" ;; esac

# --- A4b -----------------------------------------------------------------
B4b="$T/b4b"; mkdir -p "$B4b"; printf '%s\n' "$DECOMPOSE_SPEC" > "$B4b/children.json"
fcb "$B4b" decompose CURL_NUMERIC_IDS=1 >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "A4b rc=$RC: $(cat "$T/fc_error.txt")"
[ "$(body_of 3 | jq -c '[.parentId, .dependsOn]')" = '[4242,[501,502]]' ] && ok || bad "A4b child 3 ('2:hard', contract first, ints untouched): $(body_of 3)"
[ "$(body_of 2 | jq -c .dependsOn)" = '[501]' ] && ok || bad "A4b child 2's forward reference must be dropped, the contract kept: $(body_of 2)"
[ "$(body_of 1 | jq -c .dependsOn)" = '[]' ] && ok || bad "A4b the contract's after is ignored: $(body_of 1)"
grep -q "dropped 'after: 5'" "$B4b/pipeline.log" && ok || bad "A4b forward reference not logged"
grep -q '2	LG-102	502' "$B4b/children-board.tsv" && ok || bad "A4b sidecar: $(cat "$B4b/children-board.tsv" 2>/dev/null)"

# --- A5 / A5b ------------------------------------------------------------
B5="$T/b5"; mkdir -p "$B5"; printf '%s\n' "$ROLLOUT_SPEC" > "$B5/children.json"
fcb "$B5" rollout CURL_FAIL_CREATE=2 >/dev/null 2>&1; RC=$?
[ "$RC" != 0 ] && ok || bad "A5 a failed create returned 0"
[ "$(cat "$B5/children.txt" 2>/dev/null)" = LG-101 ] && ok || bad "A5 children.txt must hold exactly child 1: $(cat "$B5/children.txt" 2>/dev/null)"
grep -qE -- '/(comments|move)$' "$T/curl.log" && bad "A5 parked after a failed create" || ok
case "$(cat "$T/fc_error.txt")" in *'child 2 of 3'*) ok ;; *) bad "A5 FC_ERROR: $(cat "$T/fc_error.txt")" ;; esac
[ "$(creates)" = 2 ] && ok || bad "A5 stops at child 2 ($(creates) creates)"
fcb "$B5" rollout >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "A5b resume rc=$RC: $(cat "$T/fc_error.txt")"
[ "$(grep -o 'Idempotency-Key: [^ ]*' "$T/curl.log" | tr '\n' ' ')" = "Idempotency-Key: rollout-LG-9-2 Idempotency-Key: rollout-LG-9-3 " ] \
  && ok || bad "A5b only children 2 and 3 created: $(grep -o 'Idempotency-Key: [^ ]*' "$T/curl.log")"
[ "$(body_of 2 | jq -c .dependsOn)" = '["cmChild01","cmChild02"]' ] && ok || bad "A5b child 3 dependsOn from the sidecar: $(body_of 2)"
[ "$(cat "$B5/children.txt")" = "$(printf 'LG-101\nLG-102\nLG-103')" ] && ok || bad "A5b record: $(cat "$B5/children.txt")"
grep -q -- '/move$' "$T/curl.log" && ok || bad "A5b the completed resume parks the master"

# --- A5c -----------------------------------------------------------------
B5c="$T/b5c"; mkdir -p "$B5c"; printf '%s\n' "$ROLLOUT_SPEC" > "$B5c/children.json"
fcb "$B5c" rollout CURL_NO_ID=1 >/dev/null 2>&1; RC=$?
[ "$RC" != 0 ] && ok || bad "A5c a 2xx create without an id is not a success"
[ ! -s "$B5c/children.txt" ] && ok || bad "A5c recorded a child the board gave no id for"
[ "$(creates)" = 1 ] && ok || bad "A5c kept creating after a create without an id"
scratch_rm "$B5c"; mkdir -p "$B5c"; printf '%s\n' "$ROLLOUT_SPEC" > "$B5c/children.json"; printf 'LG-101\n' > "$B5c/children.txt"
fcb "$B5c" rollout >/dev/null 2>&1; RC=$?
[ "$RC" != 0 ] && ok || bad "A5c a recorded key without a sidecar id must refuse"
[ "$(writes)" = 0 ] && ok || bad "A5c re-created around a key it cannot resolve"
case "$(cat "$T/fc_error.txt")" in *'LG-101'*) ok ;; *) bad "A5c FC_ERROR: $(cat "$T/fc_error.txt")" ;; esac
printf 'LG-101 \n' > "$B5c/children.txt"
fcb "$B5c" rollout >/dev/null 2>&1; RC=$?
[ "$RC" != 0 ] && [ "$(writes)" = 0 ] && ok || bad "A5c a malformed record line must refuse with zero writes"
[ "$(cat "$B5c/children.txt")" = 'LG-101 ' ] && ok || bad "A5c the malformed record was rewritten"

# --- A6 ------------------------------------------------------------------
B6="$T/b6"; mkdir -p "$B6"; printf '%s\n' "$ROLLOUT_SPEC" > "$B6/children.json"
OUT=$(fcb "$B6" rollout FILE_CHILDREN_DRY_RUN=1 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "A6 dry run rc=$RC: $(cat "$T/fc_error.txt")"
[ ! -s "$T/curl.log" ] && ok || bad "A6 the dry run sent: $(cat "$T/curl.log")"
[ "$(grep -c '^curl ' "$B6/decompose-board.log" 2>/dev/null)" = 7 ] && ok || bad "A6 7 printed curls (probe, parent, 3 creates, comment, move): $(cat "$B6/decompose-board.log" 2>/dev/null)"
[ "$(printf '%s\n' "$OUT" | grep -c '^DRYRUN curl ')" = 7 ] && ok || bad "A6 7 curls on stdout: $OUT"
for n in 1 2 3; do [ -s "$B6/children/child-$n.html" ] && ok || bad "A6 child-$n.html not written"; done
[ ! -e "$B6/children.txt" ] && ok || bad "A6 the dry run wrote children.txt"
grep -q "Authorization: Bearer \$LEDGER_INTERNAL_API_TOKEN" "$B6/decompose-board.log" && ok || bad "A6 the print must name the token variable"
grep -q "$BASE/boards/{boardId}/tickets" "$B6/decompose-board.log" && ok || bad "A6 the printed create URL"
grep -q -- "-H 'Idempotency-Key: rollout-LG-9-3' --data-binary @" "$B6/decompose-board.log" && ok || bad "A6 the printed create carries its Idempotency-Key header"

# --- A7 ------------------------------------------------------------------
LEAK=$(grep -rl -- "$TOKEN" "$B1" "$B5" "$B6" "$B4" 2>/dev/null)
[ -z "$LEAK" ] && ok || bad "A7 the token reached: $LEAK"
[ -s "$B1/pipeline.log" ] && [ -s "$B1/children-board.tsv" ] && [ -s "$B1/decompose-board.log" ] && ok || bad "A7 grep ran over empty files"

# --- A8 ------------------------------------------------------------------
for f in MOVE COMMENT; do
  B8="$T/b8-$f"; mkdir -p "$B8"; printf '%s\n' "$ROLLOUT_SPEC" > "$B8/children.json"
  fcb "$B8" rollout "CURL_${f}_FAIL=1" >/dev/null 2>&1; RC=$?
  [ "$RC" = 0 ] && ok || bad "A8 a failed $f demoted the result (rc=$RC)"
  [ "$(wc -l < "$B8/children.txt")" = 3 ] && ok || bad "A8 $f: children.txt"
  lc=$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]')
  grep -q "WARN.*$lc" "$B8/pipeline.log" && ok || bad "A8 no WARN naming the $lc: $(cat "$B8/pipeline.log")"
done

# --- A9 ------------------------------------------------------------------
rollout() { # rollout <checkout> <build> [VAR=value …]
  local co="$1" b="$2"; shift 2
  : > "$T/curl.log"; rm -rf "$T/bodies" "$b"; mkdir -p "$T/bodies" "$b"
  env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/stub:$PATH" \
    CURL_LOG="$T/curl.log" CURL_BODIES="$T/bodies" CURL_PARENT="$T/parent.json" \
    CURL_BOARDS="$T/boards-cap.json" "$@" "$co/bin/run-rollout.sh" ledger-os cmParent01 LG-9 "$b" >/dev/null 2>&1
}
rollout "$T/co" "$T/b9"
[ "$(tail -1 "$T/b9/rollout-run.txt" 2>/dev/null)" = 'RESULT "ROLLOUT_FILED 3"' ] && ok || bad "A9 run-rollout.sh: $(cat "$T/b9/rollout-run.txt" 2>/dev/null) $(cat "$T/b9/pipeline.log" 2>/dev/null)"
[ "$(creates)" = 3 ] && ok || bad "A9 three creates through run-rollout.sh, got $(creates)"
[ "$(body_of 3 | jq -c .dependsOn)" = '["cmChild01","cmChild02"]' ] && ok || bad "A9 wave 3 after: Schema, API → $(body_of 3)"
# The dry run documented in docs/verification-map/fc-board.md, as written: the
# only call sent is run-rollout.sh's own GET of the parent, and because nothing
# is on the record, its RESULT counts 0 of 3.
rollout "$T/co" "$T/b9d" FILE_CHILDREN_DRY_RUN=1
[ "$(grep -c . "$T/curl.log")" = 1 ] && ! grep -q -- '-X POST' "$T/curl.log" && ok || bad "A9 dry run sent more than the parent read: $(cat "$T/curl.log")"
[ "$(grep -c '^curl ' "$T/b9d/decompose-board.log" 2>/dev/null)" = 7 ] && ok || bad "A9 dry run printed: $(cat "$T/b9d/decompose-board.log" 2>/dev/null)"
[ ! -e "$T/b9d/children.txt" ] && [ "$(tail -1 "$T/b9d/rollout-run.txt")" = 'RESULT "ROLLOUT_FAILED filed 0 of 3 waves"' ] && ok || bad "A9 dry run record/result: $(cat "$T/b9d/rollout-run.txt")"
rollout "$T/co-nomod" "$T/b9n"
[ "$(tail -1 "$T/b9n/rollout-run.txt" 2>/dev/null)" = 'RESULT "ROLLOUT_FAILED filer unavailable"' ] && ok || bad "A9 without the module: $(cat "$T/b9n/rollout-run.txt" 2>/dev/null)"

# --- A10 -----------------------------------------------------------------
bash -n "$MOD_SRC" 2>/dev/null && ok || bad "A10 bash -n bin/lib/fc-board.sh"
if command -v shellcheck >/dev/null 2>&1; then
  SC=$(shellcheck -S error "$MOD_SRC" 2>&1) && ok || bad "A10 shellcheck -S error: $SC"
else
  echo "note: shellcheck absent — A10 shellcheck assertion did not run (CI runs it)"
fi

# --- A11 -----------------------------------------------------------------
# This arm judges BH-983's OWN slice; on any other branch it stays inert, so it
# bites only when the diff touches the ticket's spec or its module.
A11BASE=$(cd "$DIR" && git merge-base origin/main HEAD 2>/dev/null || git merge-base main HEAD 2>/dev/null)
if [ -n "$A11BASE" ]; then
  # pr-scoped: ok slice-gated: inert unless this branch carries BH-983's own slice
  TOUCHED=$(cd "$DIR" && git diff --name-only "$A11BASE"...HEAD 2>/dev/null; cd "$DIR" && git diff --name-only 2>/dev/null)
  # Own spec ONLY (not the module): a later PR that edits bin/lib/fc-board.sh
  # for its own ticket must not be judged by BH-983's forbidden list. And never
  # on a Mergify merge-queue batch, whose diff carries sibling PRs' files.
  A11REF="${GITHUB_HEAD_REF:-$(cd "$DIR" && git rev-parse --abbrev-ref HEAD 2>/dev/null)}"
  case "$A11REF" in mergify/merge-queue/*) TOUCHED="" ;; esac
  if ! grep -qE '^\.harness/specs/BH-983/' <<<"$(printf '%s\n' "$TOUCHED")"; then
    echo "note: this branch is not BH-983's slice — A11 is inert here"
  else
    HIT=$(printf '%s\n' "$TOUCHED" | grep -xE 'bin/lib/(file-children|fc-issues)\.sh|bin/(run-decompose|run-rollout|run-build|triage-gate|run-triage|decompose-parent-close)\.sh')
    [ -z "$HIT" ] && ok || bad "A11 this ticket may not touch: $HIT"
  fi
else
  echo "note: no merge base against main — A11 did not run"
fi

echo "fc-board.bh-983: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
