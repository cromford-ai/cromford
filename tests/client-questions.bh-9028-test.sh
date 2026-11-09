#!/bin/bash
# tests/client-questions.bh-9028-test.sh — BH-9028: every question the fleet
# writes to a client carries a recommended answer, reasons and the default for
# no reply.
#
#   C1-C3   pb_notice (bin/lib/plan-blocked.sh): a plan with a client-questions
#           block posts the four-part questions; a block with a question that
#           lacks `recommended` is refused (rc 5, logged, 0 POSTs); a legacy
#           plan with no block still posts the excerpt quote
#   C4-C9   cq_check (bin/lib/client-questions.sh): the post/refuse/no-block
#           decision table
#   C10-C12 bin/client-questions.sh as shipped: render, refuse, usage, scrub
#   C13     every prompts/*.md carries the TEMPLATE.md rule block byte for byte,
#           and rules/CLAUDE.md carries the one-line rule
#   C14     the JSON example the rule block teaches passes cq_check
#
# Run from anywhere (exit 0 = pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$H/logs" "$H/state" "$H/builds" "$T/fakebin" "$T/srv"
export HARNESS="$H" FLEET_CONF="$DIR/fleet.conf"
for L in bin/lib/plan-blocked.sh bin/lib/client-questions.sh bin/client-questions.sh \
         bin/transcript-scrub.sh bin/fleet-conf.sh bin/jobs-client.sh; do
  [ -f "$DIR/$L" ] || { bad "setup: $L is not in the tree"; continue; }
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
for L in $(cd "$DIR" && printf '%s ' bin/lib/jobs/*.sh); do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
printf 'HARNESS_SECRET=fixture-secret-9028\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"

# gh: the REST wire shape bin/lib/gh-rest.sh reads. A comment POST keeps its body.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
case "$*" in
  *"-X POST repos/"*"/issues/"*"/comments"*)
    f=""; prev=""
    for a in "$@"; do [ "$prev" = -F ] && case "$a" in body=@*) f="${a#body=@}" ;; esac; prev="$a"; done
    n=$(grep -c . "$POST_SINK" 2>/dev/null); n=$(( ${n:-0} + 1 ))
    cp "$f" "$POST_DIR/post-$n.txt" 2>/dev/null
    printf '%s\n' "$*" >> "$POST_SINK"
    printf 'HTTP/2.0 201 X\r\nx-stub: 1\r\n\r\n{"id":%s}\n' "$n"
    exit 0 ;;
  *"-X GET repos/"*"/issues/"*"/comments"*)
    printf 'HTTP/2.0 200 X\r\nx-stub: 1\r\n\r\n[]\n'; exit 0 ;;
esac
exit 1
SH
# curl: the jobs worker ledger (a tiny store, so the comment-mark row path is real).
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"; M=GET; BODY=""; prev=""
for a in "$@"; do
  [ "$prev" = -X ] && M="$a"
  [ "$prev" = --data-binary ] && BODY="$a"
  prev="$a"
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}" 2>/dev/null) ;; esac
printf '%s %s\n' "$M" "$URL" >> "$SRV/req.log"
case "$M $URL" in
  "PUT "*/api/ledger)
    k=$(printf '%s' "$BODY" | jq -r '"kind="+(.kind|@uri)+"&key="+(.key|@uri)')
    grep -vF "$k	" "$SRV/ledger.tsv" > "$SRV/ledger.tmp" 2>/dev/null; mv -f "$SRV/ledger.tmp" "$SRV/ledger.tsv"
    printf '%s\t%s\n' "$k" "$(printf '%s' "$BODY" | jq -c '{status, detail: (.detail // "")}')" >> "$SRV/ledger.tsv"
    printf '{"ok":true}\n200' ;;
  "GET "*/api/ledger\?*)
    q="${URL#*\?}"; row=$(grep -F "$q	" "$SRV/ledger.tsv" 2>/dev/null | head -1 | cut -f2)
    if [ -n "$row" ]; then printf '{"ledger":%s}\n200' "$row"; else printf '{"error":"no row"}\n404'; fi ;;
  *) printf '{"ok":true}\n200' ;;
esac
SH
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH" GH_SINK="$T/gh.log" POST_SINK="$T/posts.log" POST_DIR="$T" SRV="$T/srv"
export GH_TOKEN_LIVE_FILE="$T/no-such-token"
unset GH_TOKEN 2>/dev/null

# shellcheck source=/dev/null
. "$H/bin/jobs-client.sh" 2>/dev/null
# shellcheck source=bin/lib/plan-blocked.sh
. "$H/bin/lib/plan-blocked.sh" 2>/dev/null && command -v pb_notice >/dev/null 2>&1 && ok \
  || bad "bin/lib/plan-blocked.sh does not load or defines no pb_notice"
# shellcheck source=bin/lib/client-questions.sh
. "$H/bin/lib/client-questions.sh" 2>/dev/null && command -v cq_check >/dev/null 2>&1 && ok \
  || bad "bin/lib/client-questions.sh does not load or defines no cq_check"

nposts() { local n; n=$(grep -c . "$POST_SINK" 2>/dev/null); echo "${n:-0}"; }
P=cromford; K=BH-9028
B="$H/builds/$P-$K-202611040000"
seed() { # seed <plan-text>
  scratch_rm "$B"; mkdir -p "$B"
  printf 'PLAN_BLOCKED %s/plan.md\nBUILD_DIR: %s\n' "$B" "$B" > "$B/RESULT"
  printf '%s' "$1" > "$B/plan.md"
}
reset_all() { : > "$POST_SINK"; : > "$GH_SINK"; : > "$SRV/ledger.tsv"; scratch_rm "$H/state"; mkdir -p "$H/state"; rm -f "$T"/post-*.txt; }
fence() { printf '```client-questions\n%s\n```\n' "$1"; }

Q2='[{"question": "Which fee field does the rep edit?", "recommended": "The per-client fee field.", "reasons": ["It is the field the invoice reads.", "The rep already edits it."], "default": "we build it on the per-client fee field."},
 {"question": "Does the fee show on the client portal?", "recommended": "No, keep it internal.", "reasons": ["Clients asked not to see it."], "default": "If we do not hear from you, we keep it internal."}]'
Q2BAD='[{"question": "Which fee field does the rep edit?", "recommended": "The per-client fee field.", "reasons": ["It is the field the invoice reads."], "default": "we build it on the per-client fee field."},
 {"question": "Does the fee show on the client portal?", "reasons": ["Clients asked not to see it."], "default": "we keep it internal."}]'
PLANOK="BLOCKED-NEEDS-CLARIFICATION

## Open questions

$(fence "$Q2")
## Tasks
none yet
"
PLANBAD="BLOCKED-NEEDS-CLARIFICATION

$(fence "$Q2BAD")"

# four_part <body-file> <n> — every line that opens a question ("**<i>. ") is
# followed by Recommended:, a non-empty Why:, and the no-reply default; exactly <n> questions.
four_part() {
  awk -v want="$2" '
    { L[NR] = $0 }
    END {
      q = 0
      for (i = 1; i <= NR; i++) if (L[i] ~ /^\*\*[0-9]+\. .+\*\*$/) {
        q++
        if (L[i+1] !~ /^Recommended: [^[:space:]]/) { print "line after q" q " is not Recommended: [" L[i+1] "]"; bad = 1 }
        if (L[i+2] !~ /^Why: [^[:space:]]/)        { print "2nd line after q" q " is not a Why: reason [" L[i+2] "]"; bad = 1 }
        if (L[i+3] !~ /^If we do not hear from you/) { print "3rd line after q" q " is not the default [" L[i+3] "]"; bad = 1 }
      }
      if (q != want) { print "found " q " questions, want " want; bad = 1 }
      exit bad
    }' "$1"
}

# ══ C1: pb_notice posts the four-part questions ═════════════════════════════
reset_all; seed "$PLANOK"; : > "$T/notice.log"
pb_notice "$H" "$P" 9028 "$K" "$B" >> "$T/notice.log" 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "C1: rc 0 on a posted notice (rc $RC): $(tail -3 "$T/notice.log")"
[ "$(nposts)" = 1 ] && ok || bad "C1: exactly one comment POST (got $(nposts))"
if [ -s "$T/post-1.txt" ]; then
  W=$(four_part "$T/post-1.txt" 2) && ok || bad "C1: THE POINT: each question has Recommended / Why / default after it: $W :: $(cat "$T/post-1.txt")"
  grep -q '^If we do not hear from you, we build it on the per-client fee field\.$' "$T/post-1.txt" && ok \
    || bad "C1: a bare default gets the no-reply prefix: $(cat "$T/post-1.txt")"
  grep -q '^> ' "$T/post-1.txt" && bad "C1: the questions are rendered, not quoted as an excerpt: $(cat "$T/post-1.txt")" || ok
  grep -q '"recommended"' "$T/post-1.txt" && bad "C1: no raw JSON in the comment: $(cat "$T/post-1.txt")" || ok
else
  bad "C1: no comment body was posted"
fi
L1=$(head -1 "$B/RESULT")
case "$L1" in "PLAN_BLOCKED $B/plan.md | CLOSED-OUT: "*"example-org/cromford#9028"*) ok ;; *) bad "C1: RESULT line 1 carries the builder-direct marker: $L1" ;; esac
grep -q 'plan-blocked notice posted' "$T/notice.log" && ok || bad "C1: the log says posted: $(tail -2 "$T/notice.log")"

# ══ C2: a question with no recommended answer is refused ════════════════════
reset_all; seed "$PLANBAD"; : > "$T/notice.log"; cp "$B/RESULT" "$T/before"
pb_notice "$H" "$P" 9028 "$K" "$B" >> "$T/notice.log" 2>&1; RC=$?
[ "$RC" = 5 ] && ok || bad "C2: rc 5 on a refused block (rc $RC): $(cat "$T/notice.log")"
[ "$(nposts)" = 0 ] && ok || bad "C2: THE POINT: no comment with bare questions (posts $(nposts)): $(cat "$T"/post-*.txt 2>/dev/null)"
grep -q 'plan-blocked notice refused' "$T/notice.log" && grep -q 'question 2 has no recommended answer' "$T/notice.log" && ok \
  || bad "C2: the log names the refusal and its reason: $(cat "$T/notice.log")"
grep -q 'notice posted' "$T/notice.log" && bad "C2: a refusal never logs posted" || ok
[ -z "$(ls -A "$H/state/plan-blocked/$P" 2>/dev/null)" ] && ok || bad "C2: no comment-mark file: $(ls "$H/state/plan-blocked/$P")"
cmp -s "$T/before" "$B/RESULT" && ok || bad "C2: RESULT unchanged: $(head -1 "$B/RESULT")"
# The lib not loaded and a block in the plan: refused too, never the raw excerpt.
reset_all; seed "$PLANOK"; mv "$H/bin/lib/client-questions.sh" "$T/cq.away"
( unset -f cq_block cq_check cq_render; pb_notice "$H" "$P" 9028 "$K" "$B" ) > "$T/notice.log" 2>&1; RC=$?
mv "$T/cq.away" "$H/bin/lib/client-questions.sh"
[ "$RC" = 5 ] && [ "$(nposts)" = 0 ] && grep -q 'client-questions.sh is not loaded' "$T/notice.log" && ok \
  || bad "C2: no lib + a block -> rc 5, 0 POSTs (rc $RC, posts $(nposts)): $(cat "$T/notice.log")"

# ══ C3: a legacy plan with no block keeps the excerpt quote ═════════════════
reset_all; seed $'BLOCKED: which column holds the fee?\nThe ticket names two fee fields.\n\n## Scope\nx\n'
pb_notice "$H" "$P" 9028 "$K" "$B" > "$T/notice.log" 2>&1; RC=$?
[ "$RC" = 0 ] && [ "$(nposts)" = 1 ] && grep -qx '> which column holds the fee?' "$T/post-1.txt" 2>/dev/null && ok \
  || bad "C3: legacy plan -> the excerpt quote (rc $RC, posts $(nposts)): $(cat "$T/post-1.txt" 2>/dev/null)"
for FN in client-question json; do
  reset_all; seed "BLOCKED: which column holds the fee?
\`\`\`$FN
$Q2BAD
\`\`\`
"
  pb_notice "$H" "$P" 9028 "$K" "$B" > "$T/notice.log" 2>&1; RC=$?
  [ "$RC" = 0 ] && [ "$(nposts)" = 1 ] && ok || bad "C3: a \`\`\`$FN fence is not a client-questions block (rc $RC, posts $(nposts))"
done

# ══ C4-C9: the cq_check decision table ══════════════════════════════════════
# chk <case> <want-rc> <want-reason-or-empty> <plan-text>
chk() {
  local f="$T/chk.md" rc err
  printf '%s' "$4" > "$f"
  err=$(cq_check "$f" 2>&1 >/dev/null); rc=$?
  if [ "$rc" = "$2" ] && { [ -z "$3" ] || grep -qF -- "$3" <<<"$err"; }; then ok
  else bad "$1: want rc $2 '$3', got rc $rc '$err'"; fi
}
one() { # one <json-objects> -> a plan whose block is the array of them
  printf 'BLOCKED\n```client-questions\n[%s]\n```\n' "$1"
}
FULL='"question": "Fixture q?", "recommended": "Fixture a.", "reasons": ["r1"], "default": "we build a."'
chk C4a 0 "" "$(fence "$Q2")"
chk C4b 0 "" "$(one '{"question": "Fixture q?", "recommended": "Fixture a.", "reasons": ["r1", "r2", "r3"], "default": "we build a."}')"
chk C4c 5 "question 1 has no recommended answer" "$(one '{"question": "Fixture q?", "recommended": "", "reasons": ["r1"], "default": "d"}')"
chk C4d 5 "question 1 has no recommended answer" "$(one '{"question": "Fixture q?", "recommended": "   ", "reasons": ["r1"], "default": "d"}')"
chk C4e 5 "question 1 has no recommended answer" "$(one '{"question": "Fixture q?", "Recommended": "Fixture a.", "reasons": ["r1"], "default": "d"}')"
chk C4f 5 "question 2 has no recommended answer" "$(fence "$Q2BAD")"
chk C5a 5 "question 1 has no reason" "$(one '{"question": "Fixture q?", "recommended": "a", "reasons": [], "default": "d"}')"
chk C5b 5 "question 1 has no reason" "$(one '{"question": "Fixture q?", "recommended": "a", "reasons": ["  "], "default": "d"}')"
chk C5c 5 "question 1 has no reason" "$(one '{"question": "Fixture q?", "recommended": "a", "default": "d"}')"
chk C5d 5 "question 1 has no reason" "$(one '{"question": "Fixture q?", "recommended": "a", "reasons": "r1", "default": "d"}')"
chk C6a 5 "question 1 has no default for no reply" "$(one '{"question": "Fixture q?", "recommended": "a", "reasons": ["r1"]}')"
chk C6b 5 "question 1 has no question text" "$(one '{"question": 7, "recommended": "a", "reasons": ["r1"], "default": "d"}')"
chk C6c 5 "question 2 is not an object" "$(one "{$FULL}, \"fixture\"")"
chk C7a 5 "is not a JSON array" "$(fence "{$FULL}")"
chk C7b 5 "has no questions" "$(fence '[]')"
chk C7c 5 "is not valid JSON" "$(fence "[{$FULL}")"
chk C7d 5 "is not valid JSON" "$(fence '')"
chk C8a 5 "no closing fence" "$(printf 'BLOCKED\n```client-questions\n[{%s}]\n' "$FULL")"
chk C8b 3 "" "BLOCKED: which column holds the fee?"
chk C8c 3 "" "$(printf 'BLOCKED\n```client-question\n[]\n```\n')"
chk C8d 3 "" "$(printf 'BLOCKED\n```json\n[]\n```\n')"
chk C8e 3 "" "$(printf 'BLOCKED\nWe use a ```client-questions block inline.\n')"
chk C9 0 "" "$(fence "$Q2"; fence '[]')"
err=$(cq_check "$T/no-such-plan.md" 2>&1); rc=$?
[ "$rc" = 3 ] && ok || bad "C8f: no plan file -> rc 3 (rc $rc '$err')"

# ══ C10-C12: bin/client-questions.sh as shipped ═════════════════════════════
CLI="$H/bin/client-questions.sh"
printf '%s' "$PLANOK" > "$T/ok.md"
OUT=$("$CLI" render "$T/ok.md" 2>"$T/cli.err"); RC=$?
printf '%s\n' "$OUT" > "$T/render.txt"
[ "$RC" = 0 ] && ok || bad "C10: render rc 0 (rc $RC): $(cat "$T/cli.err")"
W=$(four_part "$T/render.txt" 2) && ok || bad "C10: render shape: $W :: $OUT"
[ "$(grep -c . "$T/render.txt")" = 8 ] && ok || bad "C10: 2 x 4 lines: $OUT"
grep -qx '\*\*1\. Which fee field does the rep edit?\*\*' "$T/render.txt" && ok || bad "C10: question 1 line: $OUT"
grep -qx 'Recommended: The per-client fee field\.' "$T/render.txt" && ok || bad "C10: recommended line: $OUT"
grep -qx 'Why: It is the field the invoice reads\. The rep already edits it\.' "$T/render.txt" && ok || bad "C10: reasons joined on one line: $OUT"
grep -qx 'If we do not hear from you, we keep it internal\.' "$T/render.txt" && ok || bad "C10: a default with the prefix is not prefixed twice: $OUT"
fence '[{"question": "Fixture\nwith a newline?", "recommended": "  A  ", "reasons": ["", "r1"], "default": "If we do not hear from you by Friday, we build A."},
 {"question": "Fixture two?", "recommended": "B", "reasons": ["r2"], "default": "We build option A."},
 {"question": "Fixture three?", "recommended": "C", "reasons": ["r3"], "default": "QA builds it."}]' > "$T/edge.md"
OUT=$("$CLI" render "$T/edge.md" 2>"$T/cli.err"); RC=$?
printf '%s\n' "$OUT" > "$T/render.txt"
[ "$RC" = 0 ] && four_part "$T/render.txt" 3 >/dev/null && ok || bad "C10: edge render shape (rc $RC): $OUT"
grep -qx '\*\*1\. Fixture with a newline?\*\*' "$T/render.txt" && ok || bad "C10: a newline in a field renders on one line: $OUT"
grep -qx 'Recommended: A' "$T/render.txt" && ok || bad "C10: fields are trimmed: $OUT"
grep -qx 'Why: r1' "$T/render.txt" && ok || bad "C10: blank reasons are dropped: $OUT"
grep -qx 'If we do not hear from you by Friday, we build A\.' "$T/render.txt" && ok || bad "C10: a dated default is kept as written: $OUT"
grep -qx 'If we do not hear from you, we build option A\.' "$T/render.txt" && ok || bad "C10: 'We build' becomes ', we build': $OUT"
grep -qx 'If we do not hear from you, QA builds it\.' "$T/render.txt" && ok || bad "C10: an acronym keeps its case: $OUT"
OUT=$("$CLI" check "$T/ok.md" 2>&1); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "C10: check rc 0, silent (rc $RC '$OUT')"

printf '%s' "$PLANBAD" > "$T/bad.md"
OUT=$("$CLI" render "$T/bad.md" 2>"$T/cli.err"); RC=$?
[ "$RC" = 5 ] && [ -z "$OUT" ] && grep -q '^client-questions: question 2 has no recommended answer' "$T/cli.err" && ok \
  || bad "C11: a bad block -> rc 5, nothing on stdout, the reason on stderr (rc $RC '$OUT' $(cat "$T/cli.err"))"
printf 'BLOCKED: which column?\n' > "$T/none.md"
"$CLI" render "$T/none.md" >/dev/null 2>&1; RC=$?
[ "$RC" = 3 ] && ok || bad "C11: no block -> rc 3 (rc $RC)"
"$CLI" >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "C11: no argument -> rc 2 (rc $RC)"
"$CLI" frobnicate "$T/ok.md" >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "C11: unknown command -> rc 2 (rc $RC)"

fence '[{"question": "Is fixture-secret-9028 the key?", "recommended": "Yes", "reasons": ["r1"], "default": "we use it."}]' > "$T/sec.md"
OUT=$("$CLI" render "$T/sec.md" 2>&1); RC=$?
[ "$RC" = 0 ] && ! grep -q 'fixture-secret-9028' <<<"$OUT" && grep -q 'REDACTED' <<<"$OUT" && ok \
  || bad "C12: the render is scrubbed (rc $RC): $OUT"
mv "$H/bin/transcript-scrub.sh" "$T/scrub.away"
OUT=$("$CLI" render "$T/ok.md" 2>/dev/null); RC=$?
mv "$T/scrub.away" "$H/bin/transcript-scrub.sh"
[ "$RC" = 5 ] && [ -z "$OUT" ] && ok || bad "C12: FAIL CLOSED: no scrubber -> rc 5, nothing printed (rc $RC '$OUT')"

# ══ C13: the rule block in every prompts/*.md ═══════════════════════════════
BEGIN_M='<!-- client-questions:begin (BH-9028) -->'; END_M='<!-- client-questions:end -->'
block_of() { awk -v b="$BEGIN_M" -v e="$END_M" '$0 == b { on = 1 } on { print } on && $0 == e { exit }' "$1"; }
# prompts_ok <prompts-dir> — rc 0 when every *.md has "Recommended" and the TEMPLATE.md block.
prompts_ok() {
  local d="$1" ref f rc=0
  ref=$(block_of "$d/TEMPLATE.md")
  [ -n "$ref" ] && grep -qxF "$END_M" <<<"$ref" || { echo "TEMPLATE.md has no closed client-questions block"; return 1; }
  [ -z "$(grep -L Recommended "$d"/*.md)" ] || { echo "no Recommended in: $(grep -L Recommended "$d"/*.md | tr '\n' ' ')"; rc=1; }
  for f in "$d"/*.md; do
    [ "$(block_of "$f")" = "$ref" ] || { echo "block differs in $(basename "$f")"; rc=1; }
  done
  return "$rc"
}
W=$(prompts_ok "$DIR/prompts") && ok || bad "C13: THE POINT: every prompts/*.md carries the rule block: $W"
[ "$(ls "$DIR"/prompts/*.md | wc -l)" -ge 40 ] && ok || bad "C13: the prompt set is the full prompts/*.md set"
grep -qF 'Recommended: <the answer we recommend>' "$DIR/prompts/TEMPLATE.md" && grep -qF 'If we do not hear from you' "$DIR/prompts/TEMPLATE.md" \
  && grep -qF 'bin/client-questions.sh render' "$DIR/prompts/TEMPLATE.md" && ok || bad "C13: the block names the four parts and the CLI"
mkdir -p "$T/p1" "$T/p2"
cp "$DIR"/prompts/*.md "$T/p1/"; cp "$DIR"/prompts/*.md "$T/p2/"
awk -v b="$BEGIN_M" -v e="$END_M" '$0 == b { on = 1 } !on { print } on && $0 == e { on = 0 }' "$DIR/prompts/project-3.md" > "$T/p1/project-3.md"
sed -i 's/one line each:/one line each, please:/' "$T/p2/project-21.md"
prompts_ok "$T/p1" >/dev/null && bad "C13: the checker goes red on a deleted block" || ok
prompts_ok "$T/p2" >/dev/null && bad "C13: the checker goes red on one changed word" || ok
grep -q 'Every client question carries a recommendation' "$DIR/rules/CLAUDE.md" && ok || bad "C13: rules/CLAUDE.md carries the one-line rule"
grep -q 'Every client question carries a recommendation' "$DIR/rules/topics/02-board-triage.md" && ok || bad "C13: the topic file carries the rule"

# ══ C14: the example the rule block teaches is the format the reader takes ══
EX=$(block_of "$DIR/prompts/TEMPLATE.md" | sed -n 's/^`\(\[{.*}\]\)`$/\1/p')
[ -n "$EX" ] && ok || bad "C14: the rule block holds a one-line JSON example"
printf 'BLOCKED-NEEDS-CLARIFICATION\n```client-questions\n%s\n```\n' "$EX" > "$T/ex.md"
err=$(cq_check "$T/ex.md" 2>&1); rc=$?
[ -n "$EX" ] && [ "$rc" = 0 ] && ok || bad "C14: the prompt's example passes cq_check (rc $rc '$err')"

echo "client-questions (BH-9028): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
