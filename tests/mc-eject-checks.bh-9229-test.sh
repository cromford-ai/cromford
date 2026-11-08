#!/bin/bash
# tests/mc-eject-checks.bh-9229-test.sh — BH-9229: a Mergify dequeue in the
# CURRENT comment format (a `**Reason**` bold paragraph, the cause in the
# payload JSON's `dequeue_reason`) names its failing checks, and the resolver
# sends a queue-ejected-twice park with named checks to the fix round.
#
# THE INCIDENT (2026-11-08). #9189 left the queue twice (BATCH_MAX at 488caf3,
# CHECKS_FAILED at 082b296). The PARKED row read `1 unknown (no Mergify dequeue
# reason) on 488caf37; 2 unknown (...) on 082b2964`, and the resolver took
# `regen`, which cannot fix a red check.
#
# THE FIXTURE. tests/fixtures/bh-9229/pr9189-mergify-comments.json holds the
# three mergify[bot] comments of #9189 (ids 6696874499, 6711807239,
# 6715131096): id, created_at and body copied verbatim from
# `gh api repos/example-org/cromford/issues/9189/comments`; the user object
# is the mergify[bot] login those comments carry.
#
# Driven, not grepped. bin/lib/mc-eject-cause.sh, bin/lib/mc-failed-batch.sh
# and the fragment are sourced as they are; the queue.sh functions and the
# resolver's two marked blocks are extracted VERBATIM (the bh-6000 helpers).
# No network: every comments read is a stub over the fixture.
#   P1-P9  ec_classify on payload bodies
#   Q1-Q8  mc_dequeue_reason and the mc_dequeue_surface guard
#   R1-R10 the resolver's ladder block, its brief block, brec_checks, and the
#          ec_cause -> ec_record -> ec_summary -> brec_checks round trip
# Run from anywhere: tests/mc-eject-checks.bh-9229-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }

FX="$DIR/tests/fixtures/bh-9229/pr9189-mergify-comments.json"
FRAG="$DIR/bin/blocked-resolver.d/bh-9229-eject-checks.sh"
SLUG=example-org/cromford
URL="https://github.com/$SLUG/pull/9189"
H1=488caf37a1b2c3d4e5f60718293a4b5c6d7e8f90   # first ejection (488caf3 in the comment)
H2=082b2964a1b2c3d4e5f60718293a4b5c6d7e8f90   # second ejection (082b296 in the comment)
NAMES2="Pure-logic gate fixtures, Tests, traced (shard 7/9)"
TAB=$'\t'

fnx() { # fnx <file> <name> — one function, verbatim
  awk -v n="$2" '!f && $0 ~ "^"n"\\(\\)[[:space:]]*\\{" {f=1; print; if ($0 ~ /\}[[:space:]]*$/) exit; next} f {print} f && /^}/ {exit}' "$1"
}
blk() { awk -v b="$2" 'index($0, "# >>> " b) {f=1; next} index($0, "# <<< " b) {exit} f' "$1"; }
body_of() { jq -r --argjson id "$1" '.[] | select(.id == $id) | .body' "$FX"; }

{ for f in mc_mergify_names_review mc_mergify_payload_dequeue mc_dequeue_reason mc_dequeue_surface; do
    fnx "$DIR/bin/lib/mc/queue.sh" "$f"; done
  fnx "$DIR/bin/lib/mc/classify.sh" mc_handoff_id
  fnx "$DIR/bin/lib/mc/queue.sh" mc_eject_runs_file
  fnx "$DIR/bin/lib/br/ladder.sh" br_eject_runs; } > "$T/fns.sh"
for f in mc_mergify_payload_dequeue mc_dequeue_reason mc_dequeue_surface br_eject_runs; do
  grep -qE "^$f\(\)[[:space:]]*\{" "$T/fns.sh" && ok || bad "could not extract $f"
done
BR="$DIR/bin/blocked-resolver.sh"
blk "$BR" "ejected twice: fix round first" > "$T/ladder.sh"
blk "$BR" "eject runs brief" > "$T/brief.sh"
for b in ladder brief; do [ -s "$T/$b.sh" ] && ok || bad "could not extract the resolver's $b block"; done
body_of 6715131096 > "$T/b-checks.md"
body_of 6711807239 > "$T/b-batchmax.md"
[ -s "$T/b-checks.md" ] && [ -s "$T/b-batchmax.md" ] && ok || bad "the #9189 fixture bodies are missing"

# classify <head> <body-file> [VAR=val...] — ec_classify with the libs the
# conductor has loaded (queue.sh functions, mc-failed-batch.sh).
classify() {
  local h="$1" b="$2"; shift 2
  env "$@" T="$T" DIR="$DIR" bash -c '
    . "$T/fns.sh"; . "$DIR/bin/lib/mc-failed-batch.sh"; . "$DIR/bin/lib/mc-eject-cause.sh"
    ec_classify "$1" < "$2"' _ "$h" "$b"
}

# --- P. ec_classify on payload bodies ---------------------------------------------
[ "$(classify "$H2" "$T/b-checks.md")" = "checks${TAB}$NAMES2" ] && ok \
  || bad "P1 CHECKS_FAILED names both checks: [$(classify "$H2" "$T/b-checks.md")]"
[ "$(classify "$H1" "$T/b-batchmax.md")" = "checks${TAB}Pure-logic gate fixtures" ] && ok \
  || bad "P2 BATCH_MAX names its check: [$(classify "$H1" "$T/b-batchmax.md")]"
OUT=$(classify "$H1" "$T/b-batchmax.md" MC_FAILED_BATCH_CODES=CHECKS_FAILED)
[[ "$OUT" != checks* ]] && ok || bad "P3 a code the knob leaves out is not read from the payload: [$OUT]"
OUT=$(classify aaaaaaa1bbbbbbbb "$T/b-checks.md")
[[ "$OUT" == unknown* ]] && ok || bad "P4 a body for another head stays unknown: [$OUT]"
OUT=$(classify "$H2" "$DIR/tests/fixtures/dequeue-watch/payload-waiting.md")
[ -z "$OUT" ] && ok || bad "P5 a waiting payload goes down the old path (nothing): [$OUT]"
# pl <json> — a #9189 CHECKS_FAILED body with its payload JSON replaced.
pl() { awk -v j="$1" 'p == 1 { print j; p = 2; next } /-\*- Mergify Payload -\*-/ { p = 1 } { print }' "$T/b-checks.md"; }
pl '{"state": "waiting", "dequeue_reason": {"code": "CHECKS_FAILED", "checks": ["A"]}}' > "$T/b-wait.md"
OUT=$(classify "$H2" "$T/b-wait.md")
[[ "$OUT" != checks* ]] && ok || bad "P5b a payload that is not a dequeue is not read, whatever its code: [$OUT]"
pl '{"state": "dequeued", "dequeue_reason": {"code": "CHECKS_FAILED", "checks": []}}' > "$T/b-empty.md"
OUT=$(classify "$H2" "$T/b-empty.md")
[[ "$OUT" != checks* ]] && ok || bad "P6 CHECKS_FAILED with no checks is not read from the payload: [$OUT]"
pl '{"state": "dequeued", "dequeue_reason": {"code": "PR_DEQUEUED", "checks": ["A"]}}' > "$T/b-pr.md"
OUT=$(classify "$H2" "$T/b-pr.md")
[[ "$OUT" != checks* ]] && ok || bad "P7 PR_DEQUEUED is not a checks cause: [$OUT]"
pl '{"state": "dequeued", "dequeue_reason": {"code": "CHECKS_FAILED", "checks": [{"name": "A"}]}}' > "$T/b-obj.md"
[ "$(classify "$H2" "$T/b-obj.md")" = "checks${TAB}A" ] && ok \
  || bad "P8 checks as objects: [$(classify "$H2" "$T/b-obj.md")]"
pl '{"state": "dequeued", "dequeue_reason": {"code": "CHECKS_FAILED", "checks": ["A"' > "$T/b-bad.md"
OUT=$(classify "$H2" "$T/b-bad.md")
[[ "$OUT" != checks* ]] && ok || bad "P9 malformed payload JSON goes down the old path: [$OUT]"
# P1b: the old `## Reason` path is still the answer for a body with no payload code.
printf '%s\n' '- 🚫 **Left the queue** at `082b2964`' '' '## Reason' '' 'The pull request conflicts with the base branch' > "$T/b-old.md"
[[ "$(classify "$H2" "$T/b-old.md")" == conflict* ]] && ok || bad "P1b a ## Reason body still classifies: [$(classify "$H2" "$T/b-old.md")]"

# --- Q. mc_dequeue_reason and the surface guard -----------------------------------
# dqr <comments-file> [rc] — mc_dequeue_reason over a stubbed comments read.
dqr() {
  T="$T" CF="$1" RRC="${2:-0}" bash -c '
    . "$T/fns.sh"
    mc_num_of_url() { grep -oE "[0-9]+$" <<<"$1"; }
    gh_rest_issue_comments() { cat "$CF"; }
    gh_rest() { printf "{}"; }
    mc_rest_var() { [ "$RRC" = 0 ] || return 1; local __v="$1"; shift; local __o; __o=$("$@") || return 1; printf -v "$__v" "%s" "$__o"; }
    mc_dequeue_reason "'"$SLUG"'" "'"$URL"'" "'"$H2"'"'
}
[ "$(dqr "$FX")" = "checks-failed:Pure-logic gate fixtures,Tests, traced (shard 7/9)" ] && ok \
  || bad "Q1 the #9189 CHECKS_FAILED comment: [$(dqr "$FX")]"
jq '[.[] | select(.id != 6715131096)]' "$FX" > "$T/c-q2.json"
[ -z "$(dqr "$T/c-q2.json")" ] && ok || bad "Q2 BATCH_MAX newest answers nothing: [$(dqr "$T/c-q2.json")]"
REV=$(jq -Rs . < <(cat "$T/b-checks.md"; printf '%s\n' '' '## Reason' '' '> - `github-review-approved`'))
jq --argjson b "$REV" '[.[] | select(.id == 6715131096) | .body = $b]' "$FX" > "$T/c-q3.json"
[ "$(dqr "$T/c-q3.json")" = github-review-approved ] && ok || bad "Q3 the review token is answered first: [$(dqr "$T/c-q3.json")]"
jq '. + [{id: 6715131097, user: {login: "mergify[bot]"}, created_at: "2026-11-08T02:00:00Z", body: "Queue requested — the merge queue status continues below."}]' "$FX" > "$T/c-q4.json"
[ -z "$(dqr "$T/c-q4.json")" ] && ok || bad "Q4 only the newest mergify comment counts: [$(dqr "$T/c-q4.json")]"
[ -z "$(dqr "$FX" 1)" ] && ok || bad "Q5 a failed comments read answers nothing: [$(dqr "$FX" 1)]"
jq '[.[] | select(.id == 6715131096) | .user.login = "operator"]' "$FX" > "$T/c-q6.json"
[ -z "$(dqr "$T/c-q6.json")" ] && ok || bad "Q6 a human quoting the payload is not read: [$(dqr "$T/c-q6.json")]"

mkdir -p "$T/sh/bin"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/beats"\n' "$T" > "$T/sh/bin/beat.sh"; chmod +x "$T/sh/bin/beat.sh"
surface() { # surface <reason>
  T="$T" bash -c '
    . "$T/fns.sh"; MC_H="$T/sh"
    mc_attempt_has() { grep -qxF "$1" "$T/att" 2>/dev/null; }
    mc_attempt_put() { printf "%s\n" "$1" >> "$T/att"; }
    mc_log() { printf "%s\n" "$*" >> "$T/slog"; }
    mc_slug_of_url() { local u="${1#https://github.com/}"; printf "%s" "${u%/pull/*}"; }
    mc_num_of_url() { printf "%s" "${1##*/}"; }
    prr_write() { printf "%s\n" "$*" >> "$T/writes"; }
    mc_dequeue_surface "'"$SLUG#9189"'" "'"$URL"'" "'"$H2"'" "$1" 1' _ "$1"
}
: > "$T/att"; : > "$T/slog"; : > "$T/writes"; : > "$T/beats"
surface "checks-failed:A,B"
[ ! -s "$T/writes" ] && [ ! -s "$T/beats" ] && [ ! -s "$T/slog" ] && ok \
  || bad "Q7 a checks-failed token posts nothing: writes=[$(cat "$T/writes")] beats=[$(cat "$T/beats")] log=[$(cat "$T/slog")]"
grep -q dequeue-surfaced "$T/att" && bad "Q8 a checks-failed token writes no dequeue-surfaced mark" || ok
surface github-review-approved
[ "$(grep -c . "$T/writes")" = 1 ] && [ "$(grep -c . "$T/beats")" = 1 ] && ok \
  || bad "Q8 the review token still posts once: writes=[$(cat "$T/writes")] beats=[$(cat "$T/beats")]"

# --- R. the resolver --------------------------------------------------------------
SD="$T/state"; mkdir -p "$SD"
# rec <lines...> — write the #9189 eject-cause record with the real writer.
rec() {
  scratch_rm "$SD/eject-cause"
  local l
  for l in "$@"; do
    IFS='|' read -r h o c d <<<"$l"
    MC_STATE_DIR="$SD" DIR="$DIR" bash -c '. "$DIR/bin/lib/mc-eject-cause.sh"; mc_now() { printf 1762560000; }
      ec_record "'"$SLUG"'" 9189 "$1" "$2" "$3" "$4"' _ "$h" "$o" "$c" "$d"
  done
}
# ladder <reason> <action> [VAR=val...] — the verbatim ladder block.
ladder() {
  local r="$1" a="$2"; shift 2
  env FIXN=0 FRAG_ON=1 ROWHEAD="$H2" "$@" T="$T" SD="$SD" FRAG="$FRAG" bash -c '
    set -uo pipefail
    MC_H="$T/h"; MC_STATE_DIR="$SD"
    say() { printf "%s\n" "$*" >> "$T/rlog"; }
    br_num() { [ "$2" = fixrounds ] && printf "%s" "$FIXN" || printf 0; }
    br_fix_cap() { printf 1; }
    mc_slug_of_url() { local u="${1#https://github.com/}"; printf "%s" "${u%/pull/*}"; }
    mc_num_of_url() { printf "%s" "${1##*/}"; }
    mc_row_field() { [ "$2" = 4 ] && printf "%s" "$ROWHEAD"; }
    . "$T/fns.sh"
    [ "$FRAG_ON" = 1 ] && . "$FRAG"
    p=cromford; rkey=BH-9035; reason="$1"; action="$2"; ladder_action="$2"; st="{}"; url="'"$URL"'"; rowhead=""
    . "$T/ladder.sh"
    printf "%s\n" "$action"' _ "$r" "$a"
}
rec "$H1|first|checks|Pure-logic gate fixtures" "$H2|again|checks|A, B"
: > "$T/rlog"
[ "$(ladder queue-ejected-twice mechanical)" = fix-round ] && [ "$(ladder queue-ejected-twice regen)" = fix-round ] && ok \
  || bad "R1 named checks send mechanical and regen to the fix round: $(ladder queue-ejected-twice mechanical) $(ladder queue-ejected-twice regen)"
grep -q 'the eject cause names failing checks (A, B)' "$T/rlog" && ok || bad "R2 the say line names the checks: $(cat "$T/rlog")"
rec "$H2|first|unknown|no Mergify dequeue reason"
[ "$(ladder queue-ejected-twice mechanical)" = mechanical ] && [ "$(ladder queue-ejected-twice regen)" = regen ] && ok \
  || bad "R3 an unknown cause keeps the ladder"
r4=""
for c in conflict timeout review head-moved other; do
  rec "$H2|first|$c|x"
  [ "$(ladder queue-ejected-twice mechanical)" = mechanical ] || r4="$r4 $c"
done
[ -z "$r4" ] && ok || bad "R4 these causes moved the ladder:$r4"
rec "$H1|first|checks|A, B"
[ "$(ladder queue-ejected-twice mechanical)" = mechanical ] && ok || bad "R5 a checks record for an older head keeps the ladder"
rec "$H2|first|checks|A, B" "$H2|again|unknown|no Mergify dequeue reason"
[ "$(ladder queue-ejected-twice mechanical)" = mechanical ] && ok || bad "R5 a newer unknown line for the head wins"
rec "$H2|first|checks|A, B"
[ "$(ladder queue-ejected-twice mechanical FIXN=1)" = mechanical ] && ok || bad "R6 fix rounds spent keep the ladder"
[ "$(ladder red-twice mechanical)" = mechanical ] && ok || bad "R6 another reason keeps its ladder"
[ "$(ladder queue-ejected-twice rebuild-fresh)" = rebuild-fresh ] && ok || bad "R6 a rebuild-fresh rung is not moved"
[ "$(ladder queue-ejected-twice mechanical ROWHEAD="${H2:0:12}")" = fix-round ] && ok || bad "R1 a short row head still matches"
[ "$(ladder queue-ejected-twice mechanical FRAG_ON=0)" = mechanical ] && ok || bad "R8 with the fragment off the ladder is unchanged"

brief() { # brief [head]
  T="$T" SD="$SD" FRAG="$FRAG" BH="${1:-$H2}" bash -c '
    set -uo pipefail
    MC_H="$T/h"; MC_STATE_DIR="$SD"
    mc_slug_of_url() { local u="${1#https://github.com/}"; printf "%s" "${u%/pull/*}"; }
    mc_num_of_url() { printf "%s" "${1##*/}"; }
    . "$T/fns.sh"; . "$FRAG"
    brief=""; reason=queue-ejected-twice; url="'"$URL"'"; ejruns=""; head="$BH"
    . "$T/brief.sh"
    printf "%s" "$brief"'
}
B=$(brief)
grep -qF 'THE MERGE QUEUE NAMED THESE FAILING CHECKS ON THIS HEAD: A, B.' <<<"$B" && ok || bad "R7 the brief names the checks: [$B]"
rec "$H2|first|unknown|no Mergify dequeue reason"
[ -z "$(brief)" ] && ok || bad "R7 an unknown record adds nothing to the brief: [$(brief)]"

# R9. brec_checks reads one local file and writes nothing.
rec "$H2|first|checks|A, B"
before=$(ls -la "$SD/eject-cause")
r9() { T="$T" FRAG="$FRAG" bash -c '. "$FRAG"; brec_checks "$@" >/dev/null' _ "$@"; }
MC_STATE_DIR="" r9 "$URL" "$H2"; a=$?
MC_STATE_DIR="$SD" r9 "https://example.invalid/x" "$H2"; b=$?
MC_STATE_DIR="$SD" r9 "https://github.com/$SLUG/pull/9188" "$H2"; c=$?
MC_STATE_DIR="$SD" r9 "$URL" "$H2"; d=$?
[ "$a$b$c$d" = 1110 ] && ok || bad "R9 rc no-state/bad-url/no-file/good = $a$b$c$d (want 1110)"
[ "$(ls -la "$SD/eject-cause")" = "$before" ] && ok || bad "R9 brec_checks wrote into the record dir"
# The driver does not source mc-eject-cause.sh: the fragment loads it itself.
OUT=$(MC_STATE_DIR="$SD" FRAG="$FRAG" bash -c '. "$FRAG"; command -v _ec_find >/dev/null && echo preloaded; brec_checks "$1" "$2"' _ "$URL" "$H2")
[ "$OUT" = "A, B" ] && ok || bad "R9 brec_checks loads the eject-cause lib on first use: [$OUT]"

# R10. the round trip: ec_cause over the #9189 comments -> ec_record -> ec_summary.
scratch_rm "$SD/eject-cause"
OUT=$(MC_STATE_DIR="$SD" T="$T" DIR="$DIR" FX="$FX" FRAG="$FRAG" bash -c '
  . "$T/fns.sh"; . "$DIR/bin/lib/mc-failed-batch.sh"; . "$DIR/bin/lib/mc-eject-cause.sh"; . "$FRAG"
  mc_now() { printf 1762560000; }
  gh_rest_issue_comments() { cat "$FX"; }
  mc_rest_var() { local __v="$1"; shift; local __o; __o=$("$@") || return 1; printf -v "$__v" "%s" "$__o"; }
  s="'"$SLUG"'"; u="'"$URL"'"
  for x in "'"$H1"' first" "'"$H2"' again"; do
    set -- $x; c=$(ec_cause mergify "$s" "$u" "$1"); tb=$(printf "\t"); ec_record "$s" 9189 "$1" "$2" "${c%%"$tb"*}" "${c#*"$tb"}"
  done
  printf "%s\n" "$(ec_summary "$s" 9189)"; brec_checks "$u" "'"$H2"'"')
SUM=$(sed -n 1p <<<"$OUT"); BRC=$(sed -n 2p <<<"$OUT")
[[ "$SUM" == *"2 checks ($NAMES2) on 082b2964"* ]] && [[ "$SUM" == *"1 checks (Pure-logic gate fixtures) on 488caf37"* ]] && ok \
  || bad "R10 the PARKED summary names the checks: [$SUM]"
[[ "$SUM" != *unknown* ]] && ok || bad "R10 the PARKED summary has no unknown: [$SUM]"
[ "$BRC" = "$NAMES2" ] && ok || bad "R10 brec_checks reads the same names: [$BRC]"

echo "mc-eject-checks.bh-9229: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
